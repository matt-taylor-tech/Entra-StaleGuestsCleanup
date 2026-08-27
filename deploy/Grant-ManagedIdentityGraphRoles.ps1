<#
.SYNOPSIS
    Grants the Microsoft Graph application roles that Invoke-StaleGuestCleanup needs to
    an Azure Automation Account's managed identity.

.DESCRIPTION
    Assigns these Graph app roles to the managed identity's service principal:

        User.Read.All                    read the guest list
        AuditLog.Read.All                read signInActivity. Without this the property
                                         comes back null and every guest looks stale
        User.EnableDisableAccount.All    disable an account
        User.DeleteRestore.All           delete an account
        GroupMember.Read.All             read memberships for the audit record, and read
                                         the exclusion group
        RoleManagement.Read.Directory    find guests holding a directory role, so the job
                                         can skip them

    These are the narrowest roles that do the job. User.ReadWrite.All and
    Directory.ReadWrite.All would both work and both grant far more than is needed.

    Name the Automation Account and this script finds the managed identity itself. You
    do not have to look up the object ID.

    Run this ONCE per environment, by hand, as an account that can grant app roles
    (Global Administrator or Privileged Role Administrator). It is not part of the job.

    Safe to run twice. A role that is already granted is reported and skipped.

.PARAMETER ResourceGroupName
    Resource group holding the Automation Account.

.PARAMETER AutomationAccountName
    The Automation Account whose managed identity gets the roles. Its object ID is read
    from the account, so there is nothing to copy by hand.

.PARAMETER ManagedIdentityObjectId
    Object (principal) ID of a managed identity, if you would rather name it directly.
    Use this when the identity does not belong to an Automation Account, or when you
    cannot sign in to Azure with Az but can sign in to Graph.

.PARAMETER ReadOnly
    Grant only the read roles. The job can then run in -Mode Report but physically cannot
    change anything, whatever its parameters say. Use this first, prove the reporting,
    then run again without it.

.EXAMPLE
    .\deploy\Grant-ManagedIdentityGraphRoles.ps1 -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity" -ReadOnly

    The usual first step. Finds the managed identity and grants the four read roles.

.EXAMPLE
    .\deploy\Grant-ManagedIdentityGraphRoles.ps1 -ResourceGroupName "rg-automation" -AutomationAccountName "aa-identity"

    Grants everything, including the two write roles. Only do this once a report looks right.

.EXAMPLE
    .\deploy\Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "00000000-1111-2222-3333-444444444444"

    Name the identity directly, for a host that is not an Automation Account.

.NOTES
    Requires: Microsoft.Graph.Applications, and an interactive Graph sign-in holding
              AppRoleAssignment.ReadWrite.All and Application.Read.All.
              Az.Accounts and Az.Automation as well, unless you pass the object ID.
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'FromAutomationAccount')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'FromAutomationAccount')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'FromAutomationAccount')]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true, ParameterSetName = 'FromObjectId')]
    [string]$ManagedIdentityObjectId,

    [Parameter(Mandatory = $false)]
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'

# Well-known Microsoft Graph resource app ID. The same in every tenant.
$graphAppId = '00000003-0000-0000-c000-000000000000'

# Role names are stable across tenants. The IDs are not, so they are resolved from the
# service principal below rather than hardcoded.
$readRoles = @(
    'User.Read.All'
    'AuditLog.Read.All'
    'GroupMember.Read.All'
    'RoleManagement.Read.Directory'
)

$writeRoles = @(
    'User.EnableDisableAccount.All'
    'User.DeleteRestore.All'
)

$rolesToGrant = if ($ReadOnly) { $readRoles } else { $readRoles + $writeRoles }

# ---------------------------------------------------------------------------------
# Find the managed identity
# ---------------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'FromAutomationAccount') {

    Import-Module Az.Automation -ErrorAction Stop

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Write-Host 'Signing in to Azure to read the Automation Account...' -ForegroundColor Cyan
        Connect-AzAccount | Out-Null
    }

    $account = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction Stop

    $ManagedIdentityObjectId = $account.Identity.PrincipalId

    if (-not $ManagedIdentityObjectId) {
        throw "The Automation Account $AutomationAccountName has no system-assigned managed identity. Turn it on first: Automation Account > Identity > System assigned > On. Then run this again."
    }

    Write-Host "Automation Account: $AutomationAccountName" -ForegroundColor DarkGray
    Write-Host "Managed identity:   $ManagedIdentityObjectId (read from the account)" -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------------
# Grant the roles
# ---------------------------------------------------------------------------------

Import-Module Microsoft.Graph.Applications -ErrorAction Stop

if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-Host 'Connecting to Microsoft Graph (interactive)...' -ForegroundColor Cyan
    Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All' -NoWelcome
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSp) {
    throw 'Could not find the Microsoft Graph service principal in this tenant.'
}

# Confirm the target really is a service principal before granting anything to it. A
# mistyped ID, or an Application ID used where an Object ID belongs, fails here rather
# than silently granting roles to the wrong principal.
try {
    $targetSp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId -ErrorAction Stop
}
catch {
    throw "No service principal found with object ID $ManagedIdentityObjectId. If you passed it by hand, check you used the Object (principal) ID from the Automation Account's Identity blade, not the Application (client) ID."
}

Write-Host "Target identity:  $($targetSp.DisplayName)  ($ManagedIdentityObjectId)" -ForegroundColor Yellow
Write-Host "Graph SP:         $($graphSp.Id)" -ForegroundColor Yellow
if ($ReadOnly) {
    Write-Host 'Mode:             read-only roles. The job can report but cannot change anything.' -ForegroundColor Yellow
}
Write-Host ''

$existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId -All

$granted = 0
$skipped = 0

foreach ($roleName in $rolesToGrant) {

    $appRole = $graphSp.AppRoles |
        Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains 'Application' }

    if (-not $appRole) {
        Write-Warning "Role '$roleName' was not found as an application role on the Graph service principal. Skipping it. The job will fail on the calls that need it."
        continue
    }

    $already = $existingAssignments |
        Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }

    if ($already) {
        Write-Host "  [=] $roleName already granted." -ForegroundColor DarkGray
        $skipped++
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($targetSp.DisplayName, "Grant Graph app role $roleName")) {
        continue
    }

    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId -BodyParameter @{
        PrincipalId = $ManagedIdentityObjectId
        ResourceId  = $graphSp.Id
        AppRoleId   = $appRole.Id
    } | Out-Null

    Write-Host "  [+] Granted $roleName" -ForegroundColor Green
    $granted++
}

Write-Host ''
Write-Host "Granted $granted role(s), $skipped already in place." -ForegroundColor Cyan
Write-Host 'App role grants can take a few minutes to reach the Automation sandbox. If the' -ForegroundColor Cyan
Write-Host 'first run reports no sign-in data, wait and run it again before changing anything.' -ForegroundColor Cyan

if ($ReadOnly) {
    Write-Host ''
    Write-Host 'The write roles were not granted, so the job cannot change an account yet.' -ForegroundColor Yellow
    Write-Host 'Run this again without -ReadOnly when a report looks right.' -ForegroundColor Yellow
}
