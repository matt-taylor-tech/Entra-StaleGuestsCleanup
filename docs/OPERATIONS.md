# Operations

Day-to-day running of the stale guest cleanup job.

## What it does on each run

1. Reads every guest account in the tenant, with its sign-in activity.
2. Checks that the sign-in data is usable at all. If no guest in a sizeable directory has
   a sign-in date, it aborts.
3. Works out how long each guest has been inactive.
4. Applies the exclusions.
5. Decides: delete, disable, or leave alone.
6. Skips the deletes if the delete candidate count is above its ceiling, and skips the
   disables if the disable candidate count is above its own. Each ceiling gates only its
   own action.
7. Applies the per-run caps, most stale accounts first.
8. Acts, unless the mode is `Report`.
9. Writes the report.

The job holds no state between runs. Everything is recomputed from Entra each time, so a
missed run or a double run causes no drift.

## Reading a report

The summary block gives the shape of the run:

```text
Mode:               Enforce
Thresholds:         disable at 90 days, delete at 120 days
Guests read:        1840
Excluded:           41
Disable candidates: 12  (applied 12, deferred 0)
Delete candidates:  380 (applied 50, deferred 330)
Failures:           0
```

Then one line per account, as comma-separated values with a header:

```text
Action,InactiveDays,Basis,Outcome,Company,UserPrincipalName
Delete,412,NeverSignedIn,"Report only, not applied","Partner Co",someone@partner.com
```

Separate lines rather than a formatted table, because Azure Automation caps the size of a
single output record and a first run can have thousands of candidates. For the same reason
the job log lists at most **500 accounts** and then says how many it left out. Add `Blob`
to `-ReportSink` when you need the full list, which is also the audit trail that outlives
the job history.

Disables and deletes get separate shares of that 500, and disables go first. A single
combined list put every delete ahead of every disable, so on a large backlog the handful
of disabled accounts never appeared — and those are the ones most likely to produce a
"I have lost access" call.

In **report mode every actionable row reads `Report only, not applied`**, including rows
beyond the per-run cap. Nothing was attempted, so nothing was deferred. Instead the log
states how many runs the current caps would need to clear what it found.

The columns worth reading:

| Column | What to look for |
| --- | --- |
| `Basis` | `LastSignIn` means the guest signed in at least once. `NeverSignedIn` means the clock ran from the creation date. `Indeterminate` means there was not enough data and the account was left alone |
| `InactiveDays` | How the decision was reached. Cross-check it against `LastActivityDate` |
| `Action` | What was decided |
| `Outcome` | What actually happened. One of `Deleted`, `Disabled`, `Disabled while waiting to be deleted`, `Report only, not applied`, `Deferred by the per-run cap`, `Not deleted, delete ceiling reached`, `Not disabled, disable ceiling reached`, `Skipped by WhatIf`, or a failure message |
| `Memberships` | Groups and Teams the account belonged to. Read before the delete, because afterwards there is nothing to read. This is the record of what access was removed |
| `Reason` | Why. Includes the exclusion reason when an account was skipped |

`Outcome` and `Action` are separate on purpose. `Action` is what the rules decided;
`Outcome` is what the run actually did. A row saying `Delete` / `Deferred by the per-run
cap` has not been deleted.

## Normal things that are not faults

**Large deferred counts on early runs.** Expected on a directory that has never been
cleaned. The caps are doing their job. Each run drains 50, oldest first.

**A guest with `Basis = NeverSignedIn` and a recent creation date.** Correct. It is an
invitation nobody accepted yet, and it is not old enough to act on.

**`Memberships: none` on a deleted account.** Common. Most stale guests were invited for
a single shared file and never joined a group.

**A warning that a call was throttled, followed by a wait.** Normal. Graph limits writes
to `/users`, and the job waits and retries up to four times, honouring Graph's own
Retry-After when it sends one. Only a call that still fails after those attempts is
reported as a failure.

## Things that need attention

### The run aborted with "not one of N guests has a recorded sign-in"

The guard fired. `signInActivity` came back null for every guest, which means the data is
missing, not that every guest is stale. Without the guard the whole directory would have
become a delete candidate.

Almost always one of:

- `AuditLog.Read.All` was removed from the managed identity, or never propagated.
- A tenant-wide Graph problem.

Fix the permission, then re-run in report mode. **No account was changed.**

### The run aborted with "above the ceiling"

More delete candidates than `AbortIfDeleteCandidatesExceed`, or more disable candidates
than `AbortIfDisableCandidatesExceed`. Only the action that hit its ceiling was skipped.
A frozen delete does not stop the disables, so accounts waiting to be deleted are still
disabled and the access is gone. Read the summary: it names whichever ceiling was hit.

Check, in this order:

1. Were the thresholds changed by mistake? A `DisableAfterDays` of 9 instead of 90 does
   exactly this.
2. Did an exclusion disappear? A deleted exclusion group, or a variable that got cleared,
   puts everything it protected back on the list.
3. Is it genuine? On a first enforcing run against an old directory, it usually is.

If it is genuine, raise the ceiling deliberately and leave the per-run caps low. Do not
raise the ceiling to make an unexplained number go away.

### Failures on individual accounts

The run finishes the other accounts, then fails at the end so the alert fires. Each
failure is in the report with the Graph error.

Common causes:

- **`Insufficient privileges`** — the account holds a directory role the job cannot touch,
  or a write role is missing from the managed identity.
- **`Request_ResourceNotFound`** — somebody deleted the account between the read and the
  write. Harmless.
- **Throttling** — Graph returned 429. Re-run; the job is idempotent.

## Recovering a deleted account

Entra keeps a deleted user restorable for **30 days**.

Entra admin centre > Users > Deleted users > select > Restore. Or:

```powershell
Restore-MgDirectoryDeletedItem -DirectoryObjectId "<object-id>"
```

Restoring brings the account back with its group memberships. It does **not** restore
sharing links that were tied to the identity, so check the access the run report recorded
for that account.

After 30 days the account is gone and the run report is the only record it existed. That
is the reason the `Blob` report sink exists: Azure Automation prunes job history, and job
history is not an audit trail.

If a restored account is still stale, it will be a candidate again on the next run. Put it
in the exclusion group.

## Monitoring

A metric alert on the Automation Account watches the `TotalJob` metric for a failed job
on this runbook, and emails the address given at deployment. It needs no Log Analytics
workspace and no diagnostic setting.

This is not optional in practice. `-Stage Verify` reports a missing alert as a problem,
and `-Stage Schedule` refuses to schedule enforcement unless the alert exists and is
switched on. Nobody reads Automation job history for pleasure, so a failed run has to
reach a person.

The runbook throws, and so produces a failed job, when:

- an account operation fails,
- the sign-in data is unusable,
- either candidate count is above its own abort ceiling.

## Sizing the delete cap

Size `MaxDeletesPerRun` against how fast accounts **age in**, not just against the backlog
you can see today. This is the trap:

- The cap limits how many you remove per run.
- Accounts keep crossing the delete threshold between runs.
- If the cap is below that inflow, the queue **grows** every run.
- A growing queue eventually crosses the delete ceiling, and then deletes freeze entirely.

Worked example from a real tenant of about 1,100 guests, a fortnightly schedule and a cap
of 50: the queue never fell below 340 for a year, grew through two months when a large
cohort aged in, and peaked at 668 against a ceiling of 700. Thirty-two of headroom. Raising
the cap to 150 kept the queue under 270 throughout and removed the collision.

Two things worth knowing before you reach for a bigger number:

- **Above a certain point a larger cap buys no time.** The finish date is governed by when
  the last account crosses the threshold, not by how fast you delete. Past that point a
  bigger cap only shrinks the standing queue.
- **The queue is not an exposure.** Anything waiting to be deleted has already been
  disabled, so the access is gone. A long deletion tail is untidy, not risky.

So all three reach the alert. A run that finds nothing to do completes quietly.

### What the alert does not catch

A failure alert only fires when a job runs and fails. It cannot tell you that **no job ran
at all** — a disabled schedule, an expired schedule, or a deleted link produces silence,
not a failure.

Nothing in Azure reports that cleanly without more moving parts than it is worth here. The
practical check is to look at the run history now and then:

```powershell
Get-AzAutomationJob -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -RunbookName "Invoke-StaleGuestCleanup" |
    Sort-Object LastModifiedTime -Descending |
    Select-Object -First 5 JobId, Status, StartTime, EndTime
```

If the newest run is older than your interval plus a few days, the schedule has stopped.
Confirm it with:

```powershell
Get-AzAutomationSchedule -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" |
    Select-Object Name, IsEnabled, NextRun, ExpiryTime
```

Worth adding to whatever quarterly review already exists, rather than building a second
alert for it.

## Routine changes

**Change the thresholds.** Re-register the schedule with new `-RunbookParameters`. Run
once in report mode at the new numbers first, to see what changed.

**Add an exception.** Add the account to the exclusion group. No redeployment, no
developer. This is why the exclusion is a group.

**Raise the caps.** Only after several clean runs. Every raise makes the next mistake
bigger.

**Pause everything.** Disable the schedule:

```powershell
Set-AzAutomationSchedule -ResourceGroupName "<rg>" -AutomationAccountName "<aa>" `
    -Name "StaleGuestCleanup-Fortnightly" -IsEnabled $false
```

**Stop it changing anything, permanently.** Remove the two write app roles from the
managed identity. Then no parameter can make it act.

## Reviewing it

Worth doing once a quarter:

- Read one full report end to end, not just the summary.
- Check the exclusion group still reflects reality. Exclusions get added and never
  removed.
- Check the deferred count is falling. If it is not, the caps are lower than the rate new
  accounts go stale.
- Confirm the thresholds still match whatever written rule they came from. If there is no
  written rule, that is the thing to fix.
