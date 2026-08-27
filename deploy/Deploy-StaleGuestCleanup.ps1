<#
.SYNOPSIS
    Deploys Invoke-StaleGuestCleanup.ps1 into an Azure Automation Account.

.DESCRIPTION
    Everything is Azure. There is no build step and no pipeline: this script imports the
    runbook straight into an Automation Account and sets up its schedule and alerting.

    Start with -Stage All. It does every step that cannot change a guest account:

        Modules    Import Microsoft.Graph.Authentication, then wait for it to finish.
        Runbook    Import the runbook and publish it.
        Verify     Check the module, the runbook, the managed identity, and each Graph
                   role by name.

    The two stages that change how the job behaves are deliberately not in All, and have
    to be asked for one at a time:

        Alert      Create the job failure alert, switched OFF.
        AlertOn    Switch that alert on. Do this at cutover.
        Schedule   Turn the recurring run on. DO THIS LAST, and only after a manual run
                   in -Mode Report looks right.

    Every stage is safe to run twice. If a thing already exists, the stage says so and
    moves on.

    Graph permissions are NOT granted here. That needs a different sign-in and different
    rights, so it lives in Grant-ManagedIdentityGraphRoles.ps1. Run that first.

.PARAMETER Stage
    Which stage to run. Start with All.

.PARAMETER ResourceGroupName
    Resource group holding the Automation Account.

.PARAMETER AutomationAccountName
    The Automation Account to deploy into.

.PARAMETER RunbookName
    Name for the runbook inside the Automation Account.

.PARAMETER ScheduleName
    Name for the schedule created by the Schedule stage.

.PARAMETER StartTime
    First run time for the schedule. Must be at least five minutes in the future, which
    Azure Automation requires. Passed in rather than calculated, so re-running the stage
    does not silently move the schedule.

.PARAMETER ScheduleIntervalDays
    Days between runs. Defaults to 15.

    Check this against your thresholds. The rule is:

        DeleteAfterDays - DisableAfterDays  >=  ScheduleIntervalDays * 2

    The job only sees an account at the moment it runs. An account is disabled at the
    first run that sees it at DisableAfterDays or more, and that run sees an age anywhere
    in a window one interval wide. If that run is missed, the next one sees the age plus
    another interval, which can already be past DeleteAfterDays. So the gap needs room
    for two runs, not one.

    The stage checks this and prints the two ways to fix a gap that is too narrow: widen
    DeleteAfterDays, or shorten the interval.

.PARAMETER RunbookParameters
    Parameters baked into the schedule, as a hashtable. Leave this out and the schedule
    runs with the runbook's own defaults, which means -Mode Report.

.PARAMETER AlertEmail
    Address that receives the job failure alert.

.PARAMETER IncludeAzModules
    Also import Az.Accounts and Az.Storage. Only needed for the Blob report sink.

.EXAMPLE
    .\deploy\Deploy-StaleGuestCleanup.ps1 -Stage All -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity"

    The whole safe setup in one command.

.EXAMPLE
    .\deploy\Deploy-StaleGuestCleanup.ps1 -Stage Alert -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity" -AlertEmail "support@example.com"

.EXAMPLE
    .\deploy\Deploy-StaleGuestCleanup.ps1 -Stage Schedule -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity" -StartTime "2026-09-01 02:00" -RunbookParameters @{ Mode = 'Enforce' }

.NOTES
    Requires: Az.Accounts, Az.Automation, Az.Monitor, and a sign-in with Contributor on
              the Automation Account.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('All', 'Modules', 'Runbook', 'Verify', 'Alert', 'AlertOn', 'Schedule')]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $false)]
    [string]$RunbookName = 'Invoke-StaleGuestCleanup',

    [Parameter(Mandatory = $false)]
    [string]$ScheduleName = 'StaleGuestCleanup-Fortnightly',

    [Parameter(Mandatory = $false)]
    [string]$StartTime,

    # 15, not 30, so the shipped defaults satisfy the rule below on their own:
    # the 90 to 120 day disable window is 30 days, which is two 15-day intervals, so
    # every account gets two chances to be disabled before it can be deleted.
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$ScheduleIntervalDays = 15,

    [Parameter(Mandatory = $false)]
    [hashtable]$RunbookParameters,

    [Parameter(Mandatory = $false)]
    [string]$AlertEmail,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAzModules
)

$ErrorActionPreference = 'Stop'

$runbookFile     = Join-Path $PSScriptRoot '..\src\Invoke-StaleGuestCleanup.ps1'
$alertName       = "$RunbookName-JobFailed"
$actionGroupName = "$RunbookName-Alert"

function Write-Stage {
    param([string]$Message, [string]$Colour = 'Cyan')
    Write-Host $Message -ForegroundColor $Colour
}

# ---------------------------------------------------------------------------------
# Shared setup
# ---------------------------------------------------------------------------------

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    throw 'Not signed in to Azure. Run Connect-AzAccount first.'
}

$account = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction Stop

$subscriptionId    = (Get-AzContext).Subscription.Id
$automationResource = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"

Write-Stage "Automation Account: $($account.AutomationAccountName) in $($account.Location)" 'DarkGray'
Write-Stage "Stage: $Stage" 'Yellow'
Write-Host ''

$common = @{
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
}

# ---------------------------------------------------------------------------------
# Stage bodies, as functions so the All stage can call them in order
# ---------------------------------------------------------------------------------

function Invoke-ModulesStage {
    param([switch]$Wait)

    # Microsoft.Graph.Authentication is the only module the job needs. Everything else
    # goes through Invoke-MgGraphRequest, which keeps the number of module versions to
    # hold in step down to one.
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

    if (-not $Wait) {
        Write-Host ''
        Write-Stage 'Module import runs in the background and takes several minutes.' 'Yellow'
        Write-Stage 'Re-run this stage until every module reports Succeeded before moving on.' 'Yellow'
        return
    }

    # Import is asynchronous. Poll, so the All stage does not run Verify against a module
    # that has not finished importing and report a false problem.
    $deadline = (Get-Date).AddMinutes(20)
    foreach ($module in $modules) {
        Write-Stage "  [.] Waiting for $module to finish importing..." 'DarkGray'

        while ((Get-Date) -lt $deadline) {
            $state = (Get-AzAutomationModule @common -Name $module -ErrorAction SilentlyContinue).ProvisioningState

            if ($state -eq 'Succeeded') {
                Write-Stage "  [+] $module imported." 'Green'
                break
            }
            if ($state -eq 'Failed') {
                throw "Import of $module failed. Check the module in the portal for the reason."
            }
            Start-Sleep -Seconds 20
        }

        $final = (Get-AzAutomationModule @common -Name $module -ErrorAction SilentlyContinue).ProvisioningState
        if ($final -ne 'Succeeded') {
            throw "Import of $module did not finish within 20 minutes. It is still running. Re-run -Stage Modules to check on it."
        }
    }
}

function Invoke-RunbookStage {
    if (-not (Test-Path $runbookFile)) {
        throw "Cannot find the runbook at $runbookFile."
    }

    if (-not $PSCmdlet.ShouldProcess($RunbookName, 'Import and publish the runbook')) { return }

    Write-Stage "  [+] Importing $RunbookName..."
    Import-AzAutomationRunbook @common `
        -Path $runbookFile `
        -Name $RunbookName `
        -Type PowerShell `
        -Force | Out-Null

    Publish-AzAutomationRunbook @common -Name $RunbookName | Out-Null
    Write-Stage "  [+] Published $RunbookName." 'Green'
}

function Invoke-VerifyStage {
    $problems = [System.Collections.Generic.List[string]]::new()

    $graphModule = Get-AzAutomationModule @common -Name 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue
    if ($graphModule -and $graphModule.ProvisioningState -eq 'Succeeded') {
        Write-Stage "  [ok] Microsoft.Graph.Authentication $($graphModule.Version)" 'Green'
    }
    else {
        $problems.Add('Microsoft.Graph.Authentication is missing or did not import. Run -Stage Modules.')
    }

    $runbook = Get-AzAutomationRunbook @common -Name $RunbookName -ErrorAction SilentlyContinue
    if ($runbook -and $runbook.State -eq 'Published') {
        Write-Stage "  [ok] Runbook $RunbookName is published." 'Green'
    }
    else {
        $problems.Add("Runbook $RunbookName is missing or unpublished. Run -Stage Runbook.")
    }

    $identityId = $account.Identity.PrincipalId
    if ($identityId) {
        Write-Stage "  [ok] Managed identity: $identityId" 'Green'
    }
    else {
        $problems.Add('The Automation Account has no system-assigned managed identity. Turn it on under Identity, then grant the Graph roles.')
    }

    # The check that matters. Everything above can be right and the job still cannot read
    # a sign-in date.
    if ($identityId) {
        $readRoles  = @('User.Read.All', 'AuditLog.Read.All', 'GroupMember.Read.All', 'RoleManagement.Read.Directory')
        $writeRoles = @('User.EnableDisableAccount.All', 'User.DeleteRestore.All')

        try {
            Import-Module Microsoft.Graph.Applications -ErrorAction Stop
            if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
                Connect-MgGraph -Scopes 'Application.Read.All' -NoWelcome
            }

            $graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
            $assigned = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identityId -All

            $assignedNames = foreach ($a in $assigned) {
                ($graphSp.AppRoles | Where-Object { $_.Id -eq $a.AppRoleId }).Value
            }

            foreach ($role in $readRoles) {
                if ($assignedNames -contains $role) {
                    Write-Stage "  [ok] Graph role $role" 'Green'
                }
                else {
                    $problems.Add("Graph role $role is not granted. Run deploy\Grant-ManagedIdentityGraphRoles.ps1.")
                }
            }

            $missingWrite = @($writeRoles | Where-Object { $assignedNames -notcontains $_ })
            if ($missingWrite.Count -eq 0) {
                Write-Stage '  [ok] Both write roles granted. The job can disable and delete accounts.' 'Yellow'
            }
            else {
                Write-Stage "  [i]  Write roles not granted: $($missingWrite -join ', ')" 'DarkGray'
                Write-Stage '       This is correct until a report looks right. The job can only report.' 'DarkGray'
            }
        }
        catch {
            Write-Warning "Could not check the Graph role grants: $($_.Exception.Message)"
            Write-Warning 'Re-run the grant script, which is safe to repeat, or check under Enterprise applications.'
        }
    }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Stage 'Everything checks out.' 'Green'
        return $true
    }

    Write-Stage "$($problems.Count) problem(s) found:" 'Red'
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    return $false
}

function Set-FailureActionGroup {
    <#
        Creates or updates the action group that a failure notification goes to, and
        returns its resource ID.

        Az.Monitor renamed these cmdlets at version 5. Both spellings are handled, so this
        works whether the machine has a current module or an older one.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$EmailAddress,
        [Parameter(Mandatory = $true)] [string]$ResourceGroup
    )

    if (Get-Command New-AzActionGroupEmailReceiverObject -ErrorAction SilentlyContinue) {
        # Az.Monitor 5.0 and later.
        $receiver = New-AzActionGroupEmailReceiverObject -Name 'FailureEmail' -EmailAddress $EmailAddress

        New-AzActionGroup `
            -Name $Name `
            -ResourceGroupName $ResourceGroup `
            -GroupShortName 'StaleGuest' `
            -Location 'Global' `
            -EmailReceiver $receiver `
            -Enabled `
            -ErrorAction Stop | Out-Null
    }
    elseif (Get-Command New-AzActionGroupReceiver -ErrorAction SilentlyContinue) {
        # Az.Monitor 4.x and earlier.
        $receiver = New-AzActionGroupReceiver -Name 'FailureEmail' -EmailAddress $EmailAddress -EmailReceiver

        Set-AzActionGroup `
            -Name $Name `
            -ResourceGroupName $ResourceGroup `
            -ShortName 'StaleGuest' `
            -Receiver $receiver `
            -ErrorAction Stop | Out-Null
    }
    else {
        throw 'Could not find an action group cmdlet in Az.Monitor. Install or update the Az.Monitor module.'
    }

    $group = Get-AzActionGroup -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop
    return $group.Id
}

function Set-JobFailureAlert {
    <#
        Creates or updates the job failure alert. Add-AzMetricAlertRuleV2 is a
        create-or-update call, so the same definition is used to create the rule switched
        off and later to switch it on. That keeps one definition rather than two that can
        drift apart.

        This is a metric alert on the Automation Account's own TotalJob metric, filtered
        to this runbook and to failed jobs. It needs no Log Analytics workspace, no
        diagnostic setting, and no query language, because the Automation Account emits
        that metric on its own.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$ActionGroupId,
        [Parameter(Mandatory = $false)] [switch]$Enabled
    )

    $statusDim  = New-AzMetricAlertRuleV2DimensionSelection -DimensionName 'Status'  -ValueOnly 'Failed'
    $runbookDim = New-AzMetricAlertRuleV2DimensionSelection -DimensionName 'Runbook' -ValueOnly $RunbookName

    $criteria = New-AzMetricAlertRuleV2Criteria `
        -MetricName 'TotalJob' `
        -DimensionSelection $statusDim, $runbookDim `
        -TimeAggregation Total `
        -Operator GreaterThan `
        -Threshold 0

    $ruleArgs = @{
        Name              = $alertName
        ResourceGroupName = $ResourceGroupName
        WindowSize        = '01:00:00'
        Frequency         = '00:05:00'
        TargetResourceId  = $automationResource
        Condition         = $criteria
        ActionGroupId     = $ActionGroupId
        Severity          = 2
        Description       = "The $RunbookName runbook reported a failed job."
        ErrorAction       = 'Stop'
    }

    # Built switched OFF unless asked otherwise. A failed test run is a failed job, and an
    # alert left on during testing mails the address on every attempt.
    if (-not $Enabled) { $ruleArgs['DisableRule'] = $true }

    Add-AzMetricAlertRuleV2 @ruleArgs | Out-Null
}

function Invoke-AlertStage {
    if (-not $AlertEmail) {
        throw 'The Alert stage needs -AlertEmail.'
    }

    Import-Module Az.Monitor -ErrorAction Stop

    if (-not $PSCmdlet.ShouldProcess($alertName, "Create the failure alert for $RunbookName, switched off")) { return }

    $groupId = Set-FailureActionGroup -Name $actionGroupName -EmailAddress $AlertEmail -ResourceGroup $ResourceGroupName
    Write-Stage "  [+] Action group $actionGroupName sends to $AlertEmail." 'Green'

    Set-JobFailureAlert -ActionGroupId $groupId
    Write-Stage "  [+] Alert $alertName created, currently OFF." 'Green'
    Write-Stage '  [i] It watches the TotalJob metric for a failed job on this runbook.' 'DarkGray'
    Write-Stage '  [i] Run -Stage AlertOn at cutover to switch it on.' 'Yellow'
}

function Invoke-AlertOnStage {
    Import-Module Az.Monitor -ErrorAction Stop

    $rule = Get-AzMetricAlertRuleV2 -ResourceGroupName $ResourceGroupName -Name $alertName -ErrorAction SilentlyContinue
    if (-not $rule) {
        throw "No alert rule named $alertName was found. Run -Stage Alert first, with -AlertEmail."
    }

    if ($rule.Enabled) {
        Write-Stage "  [=] Alert $alertName is already on." 'DarkGray'
        return
    }

    $group = Get-AzActionGroup -ResourceGroupName $ResourceGroupName -Name $actionGroupName -ErrorAction SilentlyContinue
    if (-not $group) {
        throw "The action group $actionGroupName is missing, so an enabled alert would notify nobody. Re-run -Stage Alert with -AlertEmail."
    }

    if ($PSCmdlet.ShouldProcess($alertName, 'Switch the failure alert on')) {
        Set-JobFailureAlert -ActionGroupId $group.Id -Enabled
        Write-Stage "  [+] Alert $alertName is on." 'Green'
    }
}
function Invoke-ScheduleStage {
    # Deliberately last. Nothing runs on its own until this stage does.

    if (-not $StartTime) {
        throw 'The Schedule stage needs -StartTime, at least five minutes in the future. It is passed in rather than calculated so that re-running this stage does not silently move the schedule.'
    }

    $start = [datetime]::Parse($StartTime)
    if ($start -lt [datetime]::Now.AddMinutes(5)) {
        throw "StartTime $StartTime is not at least five minutes in the future, which Azure Automation requires."
    }

    # Check the cadence against the thresholds. If the interval is wider than the gap
    # between disable and delete, an account can cross both thresholds between two runs
    # and be deleted having never been disabled.
    $disableAt = if ($RunbookParameters -and $RunbookParameters['DisableAfterDays']) { [int]$RunbookParameters['DisableAfterDays'] } else { 90 }
    $deleteAt  = if ($RunbookParameters -and $RunbookParameters['DeleteAfterDays'])  { [int]$RunbookParameters['DeleteAfterDays'] }  else { 120 }
    $gap = $deleteAt - $disableAt

    # An account is disabled at the first run that sees it at DisableAfterDays or more.
    # That run sees an age somewhere in [disableAt, disableAt + interval). If that run is
    # the one that goes missing, the next run sees that age plus one interval. So the
    # gap has to be at least two intervals wide for every account to get a second chance.
    $safeGap = $ScheduleIntervalDays * 2

    if ($gap -lt $ScheduleIntervalDays) {
        throw "The disable window is $gap days ($disableAt to $deleteAt) but runs are $ScheduleIntervalDays days apart. Some accounts would cross both thresholds between two consecutive runs and be deleted without ever being disabled, even with no run missed. Set DeleteAfterDays to at least $($disableAt + $safeGap), or set -ScheduleIntervalDays to $([math]::Floor($gap / 2)) or less."
    }

    if ($gap -lt $safeGap) {
        # Share of accounts that would skip the disable stage if one run were missed.
        $exposed = [math]::Round(100.0 * ($safeGap - $gap) / $ScheduleIntervalDays)

        Write-Stage "  [!] The disable window is $gap days and runs are $ScheduleIntervalDays days apart." 'Yellow'
        Write-Stage "      Every account gets only one chance to be disabled. If a single run is missed," 'Yellow'
        Write-Stage "      about $exposed% of accounts would be deleted without ever being disabled." 'Yellow'
        Write-Stage '      Two ways to close that:' 'Yellow'
        Write-Stage "        DeleteAfterDays      = $($disableAt + $safeGap)   (keeps the $ScheduleIntervalDays day schedule)" 'Yellow'
        Write-Stage "        ScheduleIntervalDays = $([math]::Floor($gap / 2))    (keeps the $deleteAt day delete)" 'Yellow'
        Write-Host ''
    }
    else {
        Write-Stage "  [ok] Disable window $gap days, runs $ScheduleIntervalDays days apart. Every account gets at least two chances to be disabled." 'Green'
    }

    # Refuse to schedule enforcement before a run has ever completed. The whole rollout
    # depends on somebody reading a report first.
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
    elseif ($PSCmdlet.ShouldProcess($ScheduleName, "Create a schedule running every $ScheduleIntervalDays days from $start")) {
        New-AzAutomationSchedule @common `
            -Name $ScheduleName `
            -StartTime $start `
            -DayInterval $ScheduleIntervalDays `
            -TimeZone ([System.TimeZoneInfo]::Local).Id | Out-Null

        Write-Stage "  [+] Schedule $ScheduleName created. Every $ScheduleIntervalDays days, first run $start." 'Green'
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
        $capPerRun = if ($RunbookParameters['MaxDeletesPerRun']) { [int]$RunbookParameters['MaxDeletesPerRun'] } else { 50 }
        Write-Stage 'The job will now disable and delete accounts on this schedule.' 'Red'
        Write-Stage "At $capPerRun deletes per run every $ScheduleIntervalDays days, a backlog drains at about $([math]::Round($capPerRun * (365.0 / $ScheduleIntervalDays))) accounts a year." 'Yellow'
        Write-Stage 'If that is slower than your backlog, start the runbook by hand between scheduled' 'Yellow'
        Write-Stage 'runs to work through it, rather than raising the cap and losing the safety net.' 'Yellow'
    }
    else {
        Write-Stage 'The schedule runs in report mode, so it will not change anything.' 'Green'
        Write-Stage "Re-run this stage with -RunbookParameters @{ Mode = 'Enforce' } when the reports look right." 'Yellow'
    }
}

# ---------------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------------

switch ($Stage) {

    'All' {
        Write-Stage '=== Modules ===' 'Cyan'
        Invoke-ModulesStage -Wait
        Write-Host ''

        Write-Stage '=== Runbook ===' 'Cyan'
        Invoke-RunbookStage
        Write-Host ''

        Write-Stage '=== Verify ===' 'Cyan'
        $ok = Invoke-VerifyStage
        Write-Host ''

        if ($ok) {
            Write-Stage 'Setup is done. Nothing runs on its own yet, and nothing can change an account' 'Green'
            Write-Stage 'while the managed identity holds read-only Graph roles.' 'Green'
            Write-Host ''
            Write-Stage 'Next: start one run by hand and read the output.' 'Yellow'
            Write-Host "  Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Parameters @{ Mode = 'Report' }"
        }
        else {
            Write-Stage 'Fix the problems above, then run -Stage All again. It is safe to repeat.' 'Red'
        }
    }

    'Modules'  { Invoke-ModulesStage }
    'Runbook'  {
        Invoke-RunbookStage
        Write-Host ''
        Write-Stage 'The runbook is published but has no schedule, so it only runs when you start it.' 'Yellow'
    }
    'Verify'   { Invoke-VerifyStage | Out-Null }
    'Alert'    { Invoke-AlertStage }
    'AlertOn'  { Invoke-AlertOnStage }
    'Schedule' { Invoke-ScheduleStage }
}
