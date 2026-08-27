# Deployment

Deploy in stages, in this order. Read the output of each stage before starting the next.
The risky stages are last on purpose.

Nothing in this job changes an account until step 8. Up to that point every run is
report-only, whatever else is configured.

## What you need first

- An Azure Automation Account with a **system-assigned managed identity** turned on
  (Automation Account > Identity > System assigned > On). Note the **Object (principal)
  ID**. It is not the same as the Application (client) ID, and the two are not
  interchangeable.
- A sign-in with **Contributor** on the Automation Account, for the deployment.
- A sign-in that can grant app roles — **Global Administrator** or **Privileged Role
  Administrator** — for the permissions step. This is usually a different person.
- `Az.Accounts`, `Az.Automation`, and `Microsoft.Graph.Applications` on the machine you
  deploy from.

Build and test against a development tenant first, not the tenant you care about.

## 1. Grant the read-only permissions

```powershell
Connect-AzAccount
./deploy/Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "<object-id>" -ReadOnly
```

`-ReadOnly` grants the four read roles and none of the write roles. The job can then
report but physically cannot change an account, whatever mode it is put in. That is a
better first position than trusting a parameter default.

The script checks that the object ID really is a service principal before granting
anything, so a mistyped ID fails here rather than granting roles to something else.

Grants take a few minutes to reach the Automation sandbox.

## 2. Import the module

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Modules `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
```

`Microsoft.Graph.Authentication` is the only module the job needs. Everything else goes
through `Invoke-MgGraphRequest`, which keeps the number of module versions to hold in
step down to one.

Add `-IncludeAzModules` only if you intend to use the `Blob` report sink.

Module import runs in the background and takes several minutes. Re-run this stage until
everything reports `Succeeded`.

If your Automation Account only offers PowerShell 5.1, 7.1, or 7.2, create a **runtime
environment** on PowerShell 7.4 and assign the runbook to it. The job needs 7.2 as a
minimum.

## 3. Publish the runbook

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Runbook `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
```

The runbook is published but has no schedule, so it runs only when you start it.

## 4. Verify

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Verify `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
```

This checks the module, the runbook, the managed identity, and each Graph role by name.
The role check is the one that matters: everything else can be right and the job still
cannot read a sign-in date.

Expect the two write roles to be reported missing at this point. That is correct — you
granted read-only in step 1.

## 5. First run, in report mode

```powershell
Start-AzAutomationRunbook -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -Name "Invoke-StaleGuestCleanup" -Parameters @{ Mode = 'Report' }
```

Then read the job output. Check, in this order:

1. **Does the log say some guests have a recorded sign-in?** The line reads
   `N of M guests have a recorded sign-in`. If N is 0 the job aborts, and the cause is
   almost always that `AuditLog.Read.All` has not propagated yet. Wait and run again.
2. **How many candidates are there?** On a directory that has never been cleaned this
   can be thousands, because invitations that were never accepted are aged from their
   creation date.
3. **Read the list.** Look for anyone who must not be removed: a customer contact, a
   supplier, an account that belongs to a live project.

## 6. Set up the exclusions

Create a group, put the accounts that must never be touched into it, and pass its object
ID. Use a group rather than a parameter list, so adding an exception later needs no
redeployment and no developer.

```powershell
New-AzAutomationVariable -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -Name "StaleGuest-ExcludeGroupId" -Value "<group-object-id>" -Encrypted $false
```

The runbook reads that variable on its own. For whole domains, use `-ExcludeDomains`.

Re-run step 5 and confirm the excluded accounts have dropped off the candidate list.

## 7. Set up failure alerting

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Alert `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" -AlertEmail "<address>"
```

The alert is built **switched off**. A failed test run is a failed job, so an alert left
on during testing mails the address on every attempt.

This needs a diagnostic setting on the Automation Account sending `JobLogs` to a Log
Analytics workspace. Turn the alert on at cutover:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage AlertOn `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
```

## 8. Grant the write permissions

Only when the reports look right.

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Verify -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
./deploy/Grant-ManagedIdentityGraphRoles.ps1 -ManagedIdentityObjectId "<object-id>"
```

This adds `User.EnableDisableAccount.All` and `User.DeleteRestore.All`. From here the job
can change accounts, so the mode parameter becomes the thing standing between a report
and a deletion.

Prove it once with `-WhatIf` before the first enforcing run.

## 9. Schedule it

Start in report mode, so the schedule itself is proved before it can change anything:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Schedule `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -StartTime "2026-09-01 02:00"
```

`-StartTime` is passed in rather than calculated, so re-running the stage does not
silently move the schedule. Azure Automation requires it to be at least five minutes in
the future.

Let one cycle run. Then switch to enforcement, with the caps low:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Schedule `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -StartTime "2026-09-08 02:00" `
    -RunbookParameters @{ Mode = 'Enforce'; MaxDisablesPerRun = 50; MaxDeletesPerRun = 50 }
```

The Schedule stage refuses to schedule enforcement if the runbook has never completed a
run in that Automation Account. The whole rollout depends on somebody having read a
report first, so that check is deliberate.

## 10. Drain the backlog

With the caps at 50, a backlog of two thousand accounts takes about ten weeks of weekly
runs. That is the point: each run is small enough to notice if it is wrong.

Watch the first few runs, then raise the caps if the reports stay clean. Every run logs
how many candidates were deferred, so the report never reads as "everything handled" when
it was not.

## Local testing

The runbook also runs on a workstation, against a development tenant:

```powershell
Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","GroupMember.Read.All","RoleManagement.Read.Directory"
./src/Invoke-StaleGuestCleanup.ps1 -Mode Report
```

A guest you create today is zero days old, so a live tenant cannot exercise the 90 or 120
day boundary. To prove the behaviour end to end, use small thresholds against test
accounts:

```powershell
./src/Invoke-StaleGuestCleanup.ps1 -Mode Enforce -DisableAfterDays 0 -DeleteAfterDays 1 -WhatIf
```

The date logic itself is covered properly by the tests, with synthetic dates:

```powershell
Invoke-Pester -Path ./tests
```

## Rollback

- **Disable the schedule.** `Set-AzAutomationSchedule -IsEnabled $false`. Nothing runs
  until it is re-enabled.
- **Back to report-only.** Re-register the schedule with `Mode = 'Report'`.
- **Take the write permissions away.** Remove the two write app role assignments from the
  managed identity. The job then cannot change anything regardless of its parameters.
- **Restore a deleted account.** Entra keeps a deleted user restorable for **30 days**:
  Entra admin centre > Users > Deleted users > Restore. After 30 days it is gone. The run
  report is then the only record of what the account had access to, which is why the
  memberships are read before the delete.
