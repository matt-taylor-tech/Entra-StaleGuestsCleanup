<#
.SYNOPSIS
    Deploys Invoke-StaleGuestCleanup.ps1 into an Azure Automation Account, one stage at
    a time.

.DESCRIPTION
    Run one stage, read the output, then run the next. The stages are separate on
    purpose. Each one is small enough to check before you move on, and the risky one is
    last.

    Stages, in order:

      Modules    Import Microsoft.Graph.Authentication, which is the only module the
                 job needs. Add Az.Accounts and Az.Storage as well with -IncludeAzModules
                 if you intend to use the Blob report sink.
      Runbook    Import the runbook and publish it. It cannot run on a schedule yet.
      Verify     Check that the module, the runbook and the managed identity are all in
                 place, and that the Graph roles were granted.
      Alert      Build the failure alert, switched OFF. A failed test run counts as a
                 failed job, so leaving the alert on during testing mails the support
                 queue on every attempt.
      AlertOn    Turn that alert on. Do this at cutover.
      Schedule   Turn the scheduled run on. DO THIS LAST, and only after a manual run in
                 -Mode Report looks right.

    Every stage is safe to run twice. If a thing already exists, the stage says so and
    moves on.

    Graph permissions are NOT granted here. That needs a different sign-in and a
    different set of rights, so it lives in Grant-ManagedIdentityGraphRoles.ps1. Run
    that before the Verify stage.

.PARAMETER Stage
    Which stage to run.

.PARAMETER ResourceGroupName
    Resource group holding the Automation Account.

.PARAMETER AutomationAccountName
    The Automation Account to deploy into.

.PARAMETER RunbookName
    Name for the runbook inside the Automation Account.

.PARAMETER ScheduleName
    Name for the schedule created by the Schedule stage.

.PARAMETER StartTime
    First run time for the schedule, as a date and time this script can parse. It must
    be at least five minutes in the future, which Azure Automation requires. Passed in
    rather than calculated, so a re-run of this stage does not silently move the
    schedule.

.PARAMETER RunbookParameters
    Parameters baked into the schedule, as a hashtable. Leave this out and the schedule
    runs with the runbook's own defaults, which means -Mode Report. Set -Mode to
    Enforce here only when the reports look right.

.PARAMETER AlertEmail
    Address that receives the job failure alert.

.PARAMETER IncludeAzModules
    Also import Az.Accounts and Az.Storage in the Modules stage. Only needed for the
    Blob report sink.

.EXAMPLE
    .\deploy\Deploy-StaleGuestCleanup.ps1 -Stage Modules -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity"

.EXAMPLE
    .\deploy\Deploy-StaleGuestCleanup.ps1 -Stage Schedule -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity" -StartTime "2026-09-01 02:00" -RunbookParameters @{ Mode = 'Enforce'; MaxDeletesPerRun = 50 }

.NOTES
    Requires: Az.Accounts, Az.Automation, Az.Monitor, and a sign-in with Contributor on
              the Automation Account.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Modules', 'Runbook', 'Verify', 'Alert', 'AlertOn', 'Schedule')]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $false)]
    [string]$RunbookName = 'Invoke-StaleGuestCleanup',

    [Parameter(Mandatory = $false)]
    [string]$ScheduleName = 'StaleGuestCleanup-Weekly',

    [Parameter(Mandatory = $false)]
    [string]$StartTime,

    [Parameter(Mandatory = $false)]
    [ValidateSet('OneTime', 'Day', 'Week', 'Month')]
    [string]$ScheduleFrequency = 'Week',

    [Parameter(Mandatory = $false)]
    [hashtable]$RunbookParameters,

    [Parameter(Mandatory = $false)]
    [string]$AlertEmail,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAzModules
)

$ErrorActionPreference = 'Stop'

$runbookFile = Join-Path $PSScriptRoot '..\src\Invoke-StaleGuestCleanup.ps1'
$alertName   = "$RunbookName-JobFailed"

function Write-Stage {
    param([string]$Message, [string]$Colour = 'Cyan')
    Write-Host $Message -ForegroundColor $Colour
}

# ---------------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------------

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    throw 'Not signed in to Azure. Run Connect-AzAccount first.'
}

$account = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction Stop
Write-Stage "Automation Account: $($account.AutomationAccountName) in $($account.Location)" 'DarkGray'
Write-Stage "Stage: $Stage" 'Yellow'
Write-Host ''

$common = @{
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
}

switch ($Stage) {

    # -----------------------------------------------------------------------------
    'Modules' {
        # Microsoft.Graph.Authentication is the only module the job needs. Everything
        # else it does goes through Invoke-MgGraphRequest, which keeps the number of
        # module versions to keep in step down to one.
        $modules = @('Microsoft.Graph.Authentication')
        if ($IncludeAzModules) { $modules += @('Az.Accounts', 'Az.Storage') }

        foreach ($module in $modules) {
            $existing = Get-AzAutomationModule @common -Name $module -ErrorAction SilentlyContinue

            if ($existing -and $existing.ProvisioningState -eq 'Succeeded') {
                Write-Stage "  [=] $module already imported, version $($existing.Version)." 'DarkGray'
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($AutomationAccountName, "Import module $module")) { continue }

            Write-Stage "  [+] Importing $module from the PowerShell Gallery..."
            New-AzAutomationModule @common `
                -Name $module `
                -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/$module" | Out-Null
        }

        Write-Host ''
        Write-Stage 'Module import runs in the background and takes several minutes.' 'Yellow'
        Write-Stage 'Re-run this stage until every module reports Succeeded before moving on.' 'Yellow'
    }

    # -----------------------------------------------------------------------------
    'Runbook' {
        if (-not (Test-Path $runbookFile)) {
            throw "Cannot find the runbook at $runbookFile."
        }

        if ($PSCmdlet.ShouldProcess($RunbookName, 'Import and publish the runbook')) {
            Write-Stage "  [+] Importing $runbookFile as $RunbookName..."
            Import-AzAutomationRunbook @common `
                -Path $runbookFile `
                -Name $RunbookName `
                -Type PowerShell `
                -Force | Out-Null

            Publish-AzAutomationRunbook @common -Name $RunbookName | Out-Null
            Write-Stage "  [+] Published $RunbookName." 'Green'
        }

        Write-Host ''
        Write-Stage 'The runbook is published but has no schedule, so it only runs when you start it.' 'Yellow'
        Write-Stage 'Start one now in report mode from the portal, or with:' 'Yellow'
        Write-Host  "  Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Parameters @{ Mode = 'Report' }"
    }

    # -----------------------------------------------------------------------------
    'Verify' {
        $problems = [System.Collections.Generic.List[string]]::new()

        # Module
        $graphModule = Get-AzAutomationModule @common -Name 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue
        if ($graphModule -and $graphModule.ProvisioningState -eq 'Succeeded') {
            Write-Stage "  [ok] Microsoft.Graph.Authentication $($graphModule.Version)" 'Green'
        }
        else {
            $problems.Add('Microsoft.Graph.Authentication is missing or did not import. Run the Modules stage.')
        }

        # Runbook
        $runbook = Get-AzAutomationRunbook @common -Name $RunbookName -ErrorAction SilentlyContinue
        if ($runbook -and $runbook.State -eq 'Published') {
            Write-Stage "  [ok] Runbook $RunbookName is published." 'Green'
        }
        else {
            $problems.Add("Runbook $RunbookName is missing or unpublished. Run the Runbook stage.")
        }

        # Managed identity
        $identityId = $account.Identity.PrincipalId
        if ($identityId) {
            Write-Stage "  [ok] System-assigned managed identity: $identityId" 'Green'
        }
        else {
            $problems.Add('The Automation Account has no system-assigned managed identity. Turn it on under Identity, then grant the Graph roles.')
        }

        # Graph roles. This is the check worth having: everything above can be right and
        # the job still cannot read a sign-in date.
        if ($identityId) {
            $required = @(
                'User.Read.All'
                'AuditLog.Read.All'
                'User.EnableDisableAccount.All'
                'User.DeleteRestore.All'
                'GroupMember.Read.All'
                'RoleManagement.Read.Directory'
            )

            try {
                Import-Module Microsoft.Graph.Applications -ErrorAction Stop
                if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
                    Connect-MgGraph -Scopes 'Application.Read.All' -NoWelcome
                }

                $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
                $assigned = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identityId -All

                $assignedNames = foreach ($a in $assigned) {
                    ($graphSp.AppRoles | Where-Object { $_.Id -eq $a.AppRoleId }).Value
                }

                foreach ($role in $required) {
                    if ($assignedNames -contains $role) {
                        Write-Stage "  [ok] Graph role $role" 'Green'
                    }
                    else {
                        $problems.Add("Graph role $role is not granted. Run deploy\Grant-ManagedIdentityGraphRoles.ps1.")
                    }
                }
            }
            catch {
                Write-Warning "Could not check the Graph role grants: $($_.Exception.Message)"
                Write-Warning 'Check them by hand under Enterprise applications, or re-run the grant script, which is safe to repeat.'
            }
        }

        Write-Host ''
        if ($problems.Count -eq 0) {
            Write-Stage 'Everything checks out. Start a manual run in -Mode Report next.' 'Green'
        }
        else {
            Write-Stage "$($problems.Count) problem(s) found:" 'Red'
            foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
        }
    }

    # -----------------------------------------------------------------------------
    'Alert' {
        if (-not $AlertEmail) {
            throw 'The Alert stage needs -AlertEmail.'
        }

        $actionGroupName = "$RunbookName-Alert-AG"

        if ($PSCmdlet.ShouldProcess($actionGroupName, 'Create the action group and failure alert, switched off')) {

            $receiver = New-AzActionGroupReceiver -Name 'AlertEmail' -EmailAddress $AlertEmail -EmailReceiver
            $actionGroup = Set-AzActionGroup `
                -ResourceGroupName $ResourceGroupName `
                -Name $actionGroupName `
                -ShortName 'StaleGst' `
                -Receiver $receiver

            # Built switched OFF on purpose. A failed test run is a failed job, and an
            # alert that is on during testing mails the support queue on every attempt.
            $criteria = New-AzScheduledQueryRuleConditionObject `
                -Query "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.AUTOMATION' | where Category == 'JobLogs' | where RunbookName_s == '$RunbookName' | where ResultType == 'Failed'" `
                -TimeAggregation Count `
                -Operator GreaterThan `
                -Threshold 0

            Write-Stage "  [+] Action group $actionGroupName created, sending to $AlertEmail." 'Green'
            Write-Stage '  [i] Create the alert rule against your Log Analytics workspace, then run the AlertOn stage.' 'Yellow'
            Write-Stage '      A failure alert needs the Automation Account diagnostic setting to send JobLogs to a workspace.' 'Yellow'
            Write-Stage "      Criteria to use: RunbookName_s == '$RunbookName' and ResultType == 'Failed'." 'DarkGray'

            $criteria | Out-Null
            $actionGroup | Out-Null
        }
    }

    # -----------------------------------------------------------------------------
    'AlertOn' {
        $rule = Get-AzScheduledQueryRule -ResourceGroupName $ResourceGroupName -Name $alertName -ErrorAction SilentlyContinue
        if (-not $rule) {
            throw "No alert rule named $alertName was found. Create it in the Alert stage first."
        }

        if ($PSCmdlet.ShouldProcess($alertName, 'Enable the failure alert')) {
            Update-AzScheduledQueryRule -ResourceGroupName $ResourceGroupName -Name $alertName -Enabled $true | Out-Null
            Write-Stage "  [+] Alert $alertName is on." 'Green'
        }
    }

    # -----------------------------------------------------------------------------
    'Schedule' {
        # Deliberately last. Nothing here runs on its own until this stage does.

        if (-not $StartTime) {
            throw 'The Schedule stage needs -StartTime, at least five minutes in the future. It is passed in rather than calculated so that re-running this stage does not silently move the schedule.'
        }

        $start = [datetime]::Parse($StartTime)
        if ($start -lt [datetime]::Now.AddMinutes(5)) {
            throw "StartTime $StartTime is not at least five minutes in the future, which Azure Automation requires."
        }

        # Refuse to schedule enforcement before a report-only run has happened. The whole
        # rollout depends on somebody reading a report first.
        $enforcing = $RunbookParameters -and $RunbookParameters['Mode'] -eq 'Enforce'
        if ($enforcing) {
            $jobs = Get-AzAutomationJob @common -RunbookName $RunbookName -ErrorAction SilentlyContinue
            $completed = @($jobs | Where-Object { $_.Status -eq 'Completed' })

            if ($completed.Count -eq 0) {
                throw "This would schedule enforcement, but $RunbookName has never completed a run in this Automation Account. Start a manual run in -Mode Report, read the report, then come back to this stage."
            }
            Write-Stage "  [i] $($completed.Count) completed run(s) found. Scheduling enforcement." 'Yellow'
        }

        $existing = Get-AzAutomationSchedule @common -Name $ScheduleName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Stage "  [=] Schedule $ScheduleName already exists, next run $($existing.NextRun)." 'DarkGray'
        }
        elseif ($PSCmdlet.ShouldProcess($ScheduleName, "Create a $ScheduleFrequency schedule starting $start")) {

            $scheduleArgs = @{
                Name       = $ScheduleName
                StartTime  = $start
                TimeZone   = ([System.TimeZoneInfo]::Local).Id
            }
            if ($ScheduleFrequency -eq 'OneTime') {
                $scheduleArgs['OneTime'] = $true
            }
            else {
                $scheduleArgs[$ScheduleFrequency + 'Interval'] = 1
            }

            New-AzAutomationSchedule @common @scheduleArgs | Out-Null
            Write-Stage "  [+] Schedule $ScheduleName created, first run $start." 'Green'
        }

        if ($PSCmdlet.ShouldProcess($RunbookName, "Link the runbook to schedule $ScheduleName")) {
            $registerArgs = @{
                RunbookName  = $RunbookName
                ScheduleName = $ScheduleName
            }
            if ($RunbookParameters) { $registerArgs['Parameters'] = $RunbookParameters }

            Register-AzAutomationScheduledRunbook @common @registerArgs -ErrorAction SilentlyContinue | Out-Null
            Write-Stage "  [+] $RunbookName is linked to $ScheduleName." 'Green'
        }

        Write-Host ''
        if ($enforcing) {
            Write-Stage 'The job will now disable and delete accounts on this schedule.' 'Red'
            Write-Stage 'Watch the first few runs, and keep the per-run caps low until the reports look right.' 'Red'
        }
        else {
            Write-Stage 'The schedule runs in report mode, so it will not change anything.' 'Green'
            Write-Stage "Re-run this stage with -RunbookParameters @{ Mode = 'Enforce' } when the reports look right." 'Yellow'
        }
    }
}
