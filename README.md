# Entra stale guest cleanup

An Azure Automation runbook that finds dormant Microsoft Entra ID guest accounts,
disables them after one threshold, and deletes them after a second, longer one.

Guest accounts collect in every tenant and nobody removes them. Each dormant guest is a
live identity that can still hold access to Teams, groups, and shared files. This job
ages them out on a schedule you set, and writes down what it did.

Defaults to **report-only**. It changes nothing until you ask it to.

## How it decides

A guest is stale when it has not signed in for `DisableAfterDays`. A guest that has
never signed in at all is aged from its creation date instead, which is how invitations
that were never accepted get cleaned up.

```text
                    signed in at least once?
                     /                    \
                   yes                     no
                    |                       |
        clock runs from the         clock runs from
        latest sign-in date         createdDateTime
                    \                     /
                     \                   /
              inactive >= DeleteAfterDays  -> delete
              inactive >= DisableAfterDays -> disable
                              otherwise    -> leave alone
```

Three points worth knowing, because they are the ones that catch people out:

**All three sign-in timestamps are read, and the most recent wins.** A guest who opens a
shared file registers a *non-interactive* sign-in and no interactive one. Aging on
`lastSignInDateTime` alone would delete guests who are actively using their access.

**Delete is checked before disable.** An account already past the delete threshold is
deleted even if this job never disabled it. That is what makes the job safe to introduce
to a directory that has never been cleaned, or to run after a gap.

**There is no database.** A disabled account cannot sign in, so its last activity date is
frozen and the inactive count keeps rising on its own. Every run recomputes the whole
picture from Entra, so the job is idempotent: a missed run or a double run causes no
drift, and there is no state to get out of step.

## Before you run it on a real directory

**A directory that has never been cleaned has a large first run.** Invitations that were
never accepted are aged from their creation date, so on a tenant with years of
accumulated guests, most of them qualify at once. Run in report mode, read the report,
and keep the per-run caps low. The caps exist so the backlog drains over weeks instead
of in one run.

**Pick your own thresholds, and write down whose decision they are.** The 90 and 120 day
defaults are a starting point, not a recommendation. A guest account is somebody's
customer or supplier contact.

**A deleted Entra user is restorable for 30 days.** That is the recovery path if this job
removes something it should not have. After 30 days it is gone.

## Safety rails

| Rail | What it does |
| --- | --- |
| `-Mode Report` (default) | Evaluates everything, changes nothing |
| `-WhatIf` | Standard PowerShell dry run, works in enforce mode too |
| `-MaxDisablesPerRun` / `-MaxDeletesPerRun` | Caps one run. Most stale accounts go first, so repeated runs drain the backlog oldest first |
| `-AbortIfCandidatesExceed` | Stops the run and changes nothing when the candidate count is unexpectedly high |
| Null sign-in data guard | If *no* guest in a sizeable directory has a sign-in date, the job aborts instead of treating the whole directory as stale. This is what happens if `AuditLog.Read.All` is ever removed, and without the guard it would be a mass deletion |
| Directory role check | A guest holding any directory role is skipped and logged |
| Missing data check | A guest with no sign-in history *and* no creation date is never actioned |
| `-ExcludeGroupId` | Members of that group are never touched, nested groups included |
| `-ExcludeDomains` / `-ExcludeUpn` | Leave named domains or accounts alone |

Excluded accounts do not count towards the abort ceiling, so a large and correctly
excluded partner domain cannot block every run.

## Quick start

```powershell
# 1. Grant the managed identity read-only Graph roles first.
./deploy/Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "<object-id>" -ReadOnly

# 2. Deploy the module and the runbook.
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Modules -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Runbook -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Verify  -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"

# 3. Run it once by hand, in report mode. Read the output.
Start-AzAutomationRunbook -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -Name "Invoke-StaleGuestCleanup" -Parameters @{ Mode = 'Report' }
```

Only after a report you are happy with: grant the two write roles by re-running the
grant script without `-ReadOnly`, then set the schedule. Full walkthrough in
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

It also runs on a workstation, which is the easiest way to try it:

```powershell
Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","GroupMember.Read.All","RoleManagement.Read.Directory"
./src/Invoke-StaleGuestCleanup.ps1 -Mode Report
```

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `DisableAfterDays` | 90 | Inactive days before an account is disabled |
| `DeleteAfterDays` | 120 | Inactive days before it is deleted. Must be at least `DisableAfterDays` |
| `Mode` | `Report` | `Report` or `Enforce` |
| `MaxDisablesPerRun` | 50 | Per-run cap |
| `MaxDeletesPerRun` | 50 | Per-run cap |
| `AbortIfCandidatesExceed` | 500 | Abort ceiling on total candidates |
| `ExcludeGroupId` | none | Group whose members are never touched |
| `ExcludeDomains` | none | Domains to leave alone |
| `ExcludeUpn` | none | Individual accounts to leave alone |
| `ReportSink` | `JobLog` | Any of `JobLog`, `Blob`, `Teams`, `None` |
| `StorageAccountName` | none | Required by the `Blob` sink |
| `ContainerName` | `stale-guest-reports` | Container for the `Blob` sink |
| `TeamsWebhookUrl` | none | Required by the `Teams` sink. Prefer the Automation variable |
| `SkipGroupMemberships` | off | Skip the membership lookup on actioned accounts |
| `ManagedIdentityClientId` | none | Only for a user-assigned managed identity |

`ExcludeGroupId` and `TeamsWebhookUrl` are also read from the Automation Account
variables `StaleGuest-ExcludeGroupId` and `StaleGuest-TeamsWebhookUrl`, so they can be
changed without republishing. A parameter passed on the command line always wins.

## Permissions

Six Graph application roles on the managed identity. They are the narrowest that do the
job, and deliberately not `User.ReadWrite.All` or `Directory.ReadWrite.All`.

| Role | Why |
| --- | --- |
| `User.Read.All` | Read the guest list |
| `AuditLog.Read.All` | Read `signInActivity`. Without it the property is null and every guest looks stale |
| `User.EnableDisableAccount.All` | Disable an account |
| `User.DeleteRestore.All` | Delete an account |
| `GroupMember.Read.All` | Read memberships for the audit record, and read the exclusion group |
| `RoleManagement.Read.Directory` | Find guests holding a directory role, so they can be skipped |

`deploy/Grant-ManagedIdentityGraphRoles.ps1` grants them, and `-ReadOnly` grants only
the four read roles so you can prove the reporting before allowing any change. Detail in
[docs/PERMISSIONS.md](docs/PERMISSIONS.md).

No secret is involved anywhere. Authentication is the Automation Account's managed
identity.

## Repository layout

```text
src/Invoke-StaleGuestCleanup.ps1            the runbook, one file
deploy/Grant-ManagedIdentityGraphRoles.ps1  run once, grants the Graph roles
deploy/Deploy-StaleGuestCleanup.ps1         staged, idempotent deployment
tests/StaleGuestLogic.Tests.ps1             the decision logic
tests/Orchestration.Tests.ps1               the safety rails, with Graph mocked
docs/                                       deployment, operations, permissions
examples/config.example.psd1                a settings record to copy and edit
```

The runbook is one file because Azure Automation publishes one file. The decision logic
inside it is kept free of Graph calls so the tests can reach it.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester -Path ./tests
```

66 tests, no tenant needed. They matter more than a live test does: a guest you create
today is zero days old, so no tenant run can exercise a 90 or 120 day boundary.
Synthetic dates can. The orchestration tests mock the Graph layer and cover the caps,
the abort ceiling, the null-data guard, and the report-only gate.

## Requirements

- PowerShell 7.2 or later
- `Microsoft.Graph.Authentication` — the only required module
- `Az.Accounts` and `Az.Storage` — only for the `Blob` report sink
- An Azure Automation Account with a managed identity, or any host that can sign in to
  Graph

## Licence

MIT. See [LICENSE](LICENSE).

This is offered as-is. Read the code before you point it at a directory you care about:
it deletes accounts.
