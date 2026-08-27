# Permissions

The job authenticates as the Automation Account's managed identity. There is no
certificate, no client secret, and nothing to rotate or store.

## The six roles

Microsoft Graph **application** roles, granted to the managed identity's service
principal.

| Role | Needed for | Read or write |
| --- | --- | --- |
| `User.Read.All` | Reading the guest list and its properties | Read |
| `AuditLog.Read.All` | Reading `signInActivity` | Read |
| `GroupMember.Read.All` | Reading the exclusion group, and each actioned account's memberships | Read |
| `RoleManagement.Read.Directory` | Finding guests that hold a directory role, so they can be skipped | Read |
| `User.EnableDisableAccount.All` | Disabling an account | Write |
| `User.DeleteRestore.All` | Deleting an account | Write |

Grant them with:

```powershell
./deploy/Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "<object-id>" -ReadOnly
```

`-ReadOnly` grants the four read roles only. Drop it when you are ready to let the job
change accounts. Splitting the grant in two is the strongest safety rail in the whole
design: with read-only roles the job physically cannot delete anything, whatever its
parameters say.

The script is safe to re-run. Roles already granted are reported and skipped.

## Why not the obvious roles

`User.ReadWrite.All` would cover both write operations in one grant. `Directory.ReadWrite.All`
would cover everything.

Neither is used, because both grant far more than this job needs. `User.ReadWrite.All`
allows editing every attribute of every user in the tenant, including members. The two
granular roles allow exactly two operations, on any user, and nothing else. If this
identity is ever compromised, that difference is the whole blast radius.

`User.EnableDisableAccount.All` and `User.DeleteRestore.All` are both generally available.
If your tenant cannot see them as application roles, the grant script warns and carries
on, and the job then fails on the write calls rather than doing something unexpected.

## `AuditLog.Read.All` is load-bearing

This is the one to understand.

`signInActivity` is only returned when the caller holds `AuditLog.Read.All` **as well as**
`User.Read.All`. Without it, Graph does not error. It returns the user objects with
`signInActivity` **null**.

A null sign-in date means "never signed in", so the clock falls back to the creation date.
Every guest in the tenant then looks years stale, and every guest becomes a delete
candidate. Nothing in the decision logic can tell that case apart from a genuinely
abandoned directory.

The job guards against it explicitly: if no guest in a directory of ten or more has any
sign-in timestamp, the run aborts and changes nothing. See `Test-SignInDataUsable` in the
runbook, and the tests that cover it in `tests/Orchestration.Tests.ps1`.

If you take one permission away from this identity to see what breaks, do not pick this
one.

## Why the job reads directory roles

A guest should never hold a directory role. If one does, deleting it needs a privileged
role on the app, which this identity deliberately does not have, so the delete would fail
anyway.

More importantly, a guest holding an admin role is something a person should look at, not
something a scheduled job should quietly remove. The job skips those accounts and logs
them.

The read fails closed. If `RoleManagement.Read.Directory` is missing, the job stops rather
than continuing without the ability to tell whether a candidate is an administrator.
Guessing is not acceptable for a delete.

## Other fail-closed behaviour

The exclusion group read fails closed for the same reason. If the group cannot be read —
wrong ID, missing permission, deleted group — the job stops. Treating it as an empty set
would silently drop every exception somebody set up, and the next run would action all of
them.

## The Blob report sink

Only needed if `-ReportSink` includes `Blob`.

- **Storage Blob Data Contributor** on the target storage account, granted to the same
  managed identity. This is an Azure RBAC role, not a Graph role.
- `Az.Accounts` and `Az.Storage` imported into the Automation Account.

The report holds real names and email addresses, so treat the container as confidential:
private access only, and a retention policy that matches whatever rule covers personal
data where you are.

## The Teams report sink

No permission. It posts to an incoming webhook.

A webhook URL is a secret — anyone holding it can post to that channel. Keep it in the
Automation Account variable `StaleGuest-TeamsWebhookUrl`, which the runbook reads on its
own. Never put it in the repository or pass it on a command line that gets logged.

## Who can grant these

Granting a Graph application role needs **Global Administrator** or **Privileged Role
Administrator**. Deploying the runbook needs **Contributor** on the Automation Account.

These are usually two different people, which is why the permission grant is a separate
script from the deployment rather than a stage inside it.

## Checking what is actually granted

```powershell
Connect-MgGraph -Scopes "Application.Read.All"
$identityId = "<managed-identity-object-id>"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identityId -All |
    ForEach-Object {
        $roleId = $_.AppRoleId
        ($graphSp.AppRoles | Where-Object { $_.Id -eq $roleId }).Value
    } | Sort-Object
```

The `Verify` stage of the deployment script does this check by name and reports anything
missing.

## Taking it away

To stop the job changing anything, remove the two write role assignments. It keeps
reporting and loses the ability to act. That is a better emergency stop than editing a
parameter, because it does not depend on anybody remembering which mode the schedule is
in.
