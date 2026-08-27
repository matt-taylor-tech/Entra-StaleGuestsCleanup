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

    Run this ONCE per environment, by hand, as an account that can grant app roles
    (Global Administrator or Privileged Role Administrator). It is not part of the job.

    Safe to run twice. A role that is already granted is reported and skipped.

.PARAMETER ManagedIdentityObjectId
    The Object (principal) ID of the Automation Account's managed identity.
    Find it under: Automation Account > Identity > System assigned > Object (principal) ID.

    Note this is the Object ID, not the Application (client) ID. The two are not
    interchangeable, and using the wrong one grants roles to something else.

.PARAMETER ReadOnly
    Grant only the read roles. The job can then run in -Mode Report but cannot change
    anything. Use this to prove the reporting before you allow enforcement.

.EXAMPLE
    .\deploy\Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "00000000-1111-2222-3333-444444444444" -ReadOnly

    Grant the read roles first, so a report-only run can be proved safely.

.EXAMPLE
    .\deploy\Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "00000000-1111-2222-3333-444444444444"

    Grant everything, including the two write roles.

.NOTES
    Requires: Microsoft.Graph.Applications module, and an interactive sign-in holding
              AppRoleAssignment.ReadWrite.All and Application.Read.All.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
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

Import-Module Microsoft.Graph.Applications -ErrorAction Stop

Write-Host 'Connecting to Microsoft Graph (interactive)...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All' -NoWelcome

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSp) {
    throw 'Could not find the Microsoft Graph service principal in this tenant.'
}

# Confirm the target really is a service principal before granting anything to it. A
# mistyped ID, or the Application ID used instead of the Object ID, fails here rather
# than silently granting roles to the wrong principal.
try {
    $targetSp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId -ErrorAction Stop
}
catch {
    throw "No service principal found with object ID $ManagedIdentityObjectId. Check that you used the Object (principal) ID from the Automation Account's Identity blade, not the Application (client) ID."
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
    Write-Host 'The write roles were not granted. Run this again without -ReadOnly when you are' -ForegroundColor Yellow
    Write-Host 'ready to let the job disable and delete accounts.' -ForegroundColor Yellow
}

Disconnect-MgGraph | Out-Null
