# Deployment

Everything runs in Azure. There is no pipeline and no build step: two scripts put the
runbook into an Automation Account and set up its schedule and alerting.

Nothing changes an account until step 5. Up to that point the managed identity holds
read-only Graph roles, so the job physically cannot disable or delete anything, whatever
its parameters say.

## What you need first

- An Azure Automation Account with a **system-assigned managed identity** turned on
  (Automation Account > Identity > System assigned > On). You do not need to note the
  object ID — the scripts read it from the account.
- A sign-in with **Contributor** on the Automation Account, for the deployment.
- A sign-in that can grant app roles — **Global Administrator** or **Privileged Role
  Administrator** — for step 1. Usually a different person.
- `Az.Accounts`, `Az.Automation`, `Az.Monitor`, and `Microsoft.Graph.Applications` on the
  machine you deploy from.

Build and test against a development tenant first, not the tenant you care about.

## 1. Grant the read-only permissions

```powershell
Connect-AzAccount
./deploy/Grant-ManagedIdentityGraphRoles.ps1 `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" -ReadOnly
```

Name the Automation Account and the script finds its managed identity itself.

`-ReadOnly` grants the four read roles and neither write role. That is a better first
position than trusting a parameter default: the job can report, and cannot act.

If the account has no managed identity the script says so and stops. If you would rather
name an identity directly — for a host that is not an Automation Account — pass
`-ManagedIdentityObjectId` instead.

Grants take a few minutes to reach the Automation sandbox.

## 2. Deploy

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage All `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -AlertEmail "<address>"
```

One command. It imports `Microsoft.Graph.Authentication`, waits for the import to finish,
publishes the runbook, creates the failure alert (switched off), then checks the module,
the runbook, the managed identity, every Graph role by name, the alert, and the last run
status.

**Give `-AlertEmail`.** It is optional only so the command still works without it, and in
that case `All` says loudly that alerting is missing. A scheduled job that deletes
accounts needs somebody watching for failed runs, and step 7 refuses to schedule
enforcement until an alert exists and is on.

Module import takes several minutes, and the stage waits rather than making you poll.

Expect the two write roles to be reported as not granted. That is correct at this point.

Add `-IncludeAzModules` only if you intend to use the `Blob` report sink.

`All` deliberately excludes the schedule and the alert. Neither is a thing to switch on
without reading a report first.

### About the runbook runtime

The runbook is imported as type **`PowerShell72`**. This matters: in Azure Automation the
type named `PowerShell` is Windows PowerShell **5.1**, where a current
`Microsoft.Graph.Authentication` will not load. A 5.1 runbook imports and publishes
without complaint, then fails on its first Graph call in a way that reads like a missing
module. The `Verify` stage checks the type and says so plainly.

If your Automation Account uses **runtime environments**, assign a PowerShell 7.4
environment to the runbook in the portal after step 2. The `Az.Automation` module has no
parameter for that, so it cannot be scripted here.

## 3. First run, in report mode

```powershell
Start-AzAutomationRunbook -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -Name "Invoke-StaleGuestCleanup" -Parameters @{ Mode = 'Report' }
```

Read the job output. Check, in this order:

1. **Does the log say some guests have a recorded sign-in?** The line reads
   `N of M guests have a recorded sign-in`. If N is 0 the job aborts, and the cause is
   almost always that `AuditLog.Read.All` has not propagated yet. Wait and run again.
2. **How many candidates are there?** On a directory that has never been cleaned this can
   be thousands, because invitations nobody accepted are aged from their creation date.
3. **Read the list.** Look for anyone who must not be removed: a customer contact, a
   supplier, an account tied to a live project.

## 4. Set up the exclusions

Create a group, put the accounts that must never be touched into it, and store its object
ID as an Automation variable. The runbook reads that variable on its own.

```powershell
New-AzAutomationVariable -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -Name "StaleGuest-ExcludeGroupId" -Value "<group-object-id>" -Encrypted $false

Set the variable even if you also pass `-ExcludeGroupId` on the schedule. A schedule
parameter covers that schedule only, so a run started by hand from the portal would
apply no exclusions at all. The variable covers every run.
```

Use a group rather than a parameter list, so adding an exception later needs no
redeployment and no developer. For whole domains, use `-ExcludeDomains`.

Re-run step 3 and confirm the excluded accounts have dropped off the candidate list.

## 5. Grant the write permissions

Only when a report looks right.

```powershell
./deploy/Grant-ManagedIdentityGraphRoles.ps1 `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
```

Same command as step 1, without `-ReadOnly`. This adds
`User.EnableDisableAccount.All` and `User.DeleteRestore.All`. From here the mode
parameter is what stands between a report and a deletion.

Prove it once with `-WhatIf` before the first enforcing run.

## 6. Switch failure alerting on

Step 2 already created the alert if you passed `-AlertEmail`. If you did not, create it
now:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Alert `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" -AlertEmail "<address>"
```

This creates an action group and a metric alert on the Automation Account's own
`TotalJob` metric, filtered to this runbook and to failed jobs. **No Log Analytics
workspace, no diagnostic setting, and no query language** — the Automation Account emits
that metric on its own.

The alert is created **switched off**. A failed test run is a failed job, so an alert left
on during testing mails the address on every attempt. Switch it on at cutover:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage AlertOn `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>"
```

The runbook throws on any account operation that fails, and on either abort condition, so
all of those become a failed job and reach this alert.

## 7. Schedule it

Runs every 15 days by default, which is what the 90 and 120 day thresholds need. Start in
report mode, so the schedule itself is proved before it can change anything:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Schedule `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -StartTime "2026-09-01 02:00"
```

`-StartTime` is passed in rather than calculated, so re-running the stage does not
silently move the schedule. Azure Automation needs it at least five minutes ahead.

Change the cadence with `-ScheduleIntervalDays`.

### Check the cadence against the thresholds

This one catches people out, and the Schedule stage checks it for you.

The job is blind between runs. It only sees an account at the moment it runs. So the
question is always: when the job wakes up, what number does it see?

An account is disabled at the first run that sees it at `DisableAfterDays` or more. That
run sees an age anywhere in a window one interval wide. **If that run is the one that goes
missing**, the next run sees the same age plus another interval — which may already be
past `DeleteAfterDays`. The account is then deleted having never been disabled, because
delete is checked before disable.

So the gap needs room for two runs, not one:

```text
DeleteAfterDays - DisableAfterDays  >=  ScheduleIntervalDays * 2
```

The shipped defaults satisfy the rule: a 90 to 120 day window is 30 days, and runs are 15
days apart, so 30 >= 2 x 15. Every account gets two chances to be disabled.

Move to a 30-day schedule without changing the thresholds and the gap becomes one interval
instead of two, which breaks it. Nudging the delete threshold up a little does not fix
that. On a 30-day schedule:

| Delete at | Gap | If one run is missed |
| --- | --- | --- |
| 120 | 30 | ~100% of accounts skip disable |
| 125 | 35 | ~83% skip disable |
| 135 | 45 | ~50% skip disable |
| 150 | 60 | none — rule satisfied |

So if you do want a 30-day cadence, move the delete threshold out to match:
`-ScheduleIntervalDays 30 -RunbookParameters @{ DeleteAfterDays = 150 }`. Gap 60 = 2 x 30.

The default goes the other way on purpose. Running fortnightly keeps the 90 and 120 day
thresholds people actually asked for, and clears a backlog twice as fast. A run with
nothing to do finishes quietly, so the extra run costs little.

What the stage does:

- **Gap narrower than one interval:** refuses to run. Some accounts would skip the disable
  stage even with no run missed.
- **Gap narrower than two intervals:** warns, prints the share of accounts exposed to a
  missed run, and gives both fixes with the numbers filled in.
- **Gap at or above two intervals:** confirms it is fine.

Set either with `-RunbookParameters` and `-ScheduleIntervalDays`.

### Then switch to enforcement

Let one cycle run in report mode. Then:

```powershell
./deploy/Deploy-StaleGuestCleanup.ps1 -Stage Schedule `
    -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -StartTime "2026-10-01 02:00" `
    -RunbookParameters @{ Mode = 'Enforce'; DeleteAfterDays = 150; MaxDeletesPerRun = 50 }
```

The Schedule stage refuses to schedule enforcement unless **both** of these hold:

- the runbook has completed at least one run in that Automation Account, so somebody has
  had a report to read, and
- a failure alert exists **and is switched on**, so a failed run reaches a person.

Both checks are deliberate. `-SkipAlertCheck` overrides the second one, and is only for a
tenant where failed Automation jobs already reach somebody another way.

## 8. Draining a backlog

Do the arithmetic before you trust the schedule to clear a backlog.

At 50 deletes per run every 30 days, the job removes about **600 accounts a year**. A
backlog of two thousand takes over three years. The Schedule stage prints this figure so
it is not a surprise.

If that is too slow, **start the runbook by hand between scheduled runs** to work through
the backlog. Each manual run is still capped, still reports, and still needs someone to
look at it. That is better than raising the cap, which removes the safety net permanently
to solve a one-off problem.

Once the backlog is clear, the steady-state volume is small and 50 per run is generous.

## Local testing

The runbook also runs on a workstation, against a development tenant:

```powershell
Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","GroupMember.Read.All","RoleManagement.Read.Directory"
./src/Invoke-StaleGuestCleanup.ps1 -Mode Report
```

A guest you create today is zero days old, so no live tenant can exercise the 90 or 120
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

- **Stop the schedule.** `Set-AzAutomationSchedule -IsEnabled $false`. Nothing runs until
  it is re-enabled.
- **Back to report-only.** Re-register the schedule with `Mode = 'Report'`.
- **Take the write permissions away.** Remove the two write app role assignments from the
  managed identity. The job then cannot change anything regardless of its parameters, and
  does not depend on anyone remembering which mode the schedule is in. This is the best
  emergency stop.
- **Restore a deleted account.** Entra keeps a deleted user restorable for **30 days**:
  Entra admin centre > Users > Deleted users > Restore. After 30 days it is gone, and the
  run report is the only record of what the account had access to. That is why memberships
  are read before the delete.
