# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-08-28

A line-by-line review of both scripts, with the order of operations checked. Nine of the
findings were confirmed by running code rather than by reading it.

### Fixed

- **The module went into the wrong runtime space.** Azure Automation keeps a separate
  module space per runtime. The module cmdlets default to the 5.1 space, while a
  `PowerShell72` runbook reads the 7.2 space. The import succeeded, Verify reported the
  module present, and the runbook then failed at `Connect-MgGraph` saying it was missing.
  Module operations now pass `-RuntimeVersion` to match the runbook type.
- **Report mode claimed accounts had been deferred.** The per-run caps were applied
  whatever the mode, so a report-only run labelled rows beyond the cap
  "Deferred by the per-run cap" and reported a non-zero deferred count, in a run where
  nothing was attempted. The caps now apply only when the job acts. A report run labels
  every actionable row `Report only, not applied` and states instead how many runs the
  current caps would need to clear the backlog.
- **Disables could be missing from the job log.** Rows were sorted by action, and
  "Delete" sorts after "Disable", so every delete came first and the 500-row limit was
  spent before any disable was printed. On a large backlog the disabled accounts, which
  are the ones most likely to produce a support call, never appeared. Disables and
  deletes now get separate shares of the limit, and disables go first.
- **Verify rejected a valid PowerShell 7.4 runbook.** The runtime test matched `72` or
  `7.`, so a `PowerShell74` runbook was reported as Windows PowerShell 5.1 — while the
  deployment guide tells you to assign a 7.4 runtime environment. It now accepts any
  PowerShell 7 type.
- **`-WhatIf` on `-Stage All` sat in the module wait loop for twenty minutes** and then
  threw, because nothing had been imported for it to wait for. The wait is skipped under
  `-WhatIf`.
- **The retry wrapper relied on dynamic scope.** It took a scriptblock that splatted a
  hashtable belonging to the calling function, which resolved only because the caller
  happened to sit in the scope chain. Called from anywhere else the splat silently
  produced an empty hashtable and the request went out with no method and no URI, raising
  no error. It now takes the method, URI, body and headers as parameters. This path had
  no test coverage at all; `tests/GraphRetry.Tests.ps1` now covers it.
- **Excluded domains did not cover subdomains.** A rule for `partner.com` left
  `someone@eu.partner.com` unprotected. For an exclusion list, matching too little is the
  dangerous direction, because it deletes an account somebody meant to keep. Subdomains
  now match, and a lookalike such as `evilpartner.com` still does not.
- **`Invoke-GraphGetAll` returned an inconsistent shape.** Returning a `List` let
  PowerShell unroll it, so no results came back as `$null` and one result as a bare
  object. It always returns an array now.
- **An Unspecified-Kind DateTime was shifted by the machine's offset.**
  `ToUniversalTime()` treats such a value as local time. Graph values are UTC, so the
  shift could move an account across a threshold by a day depending on the machine. An
  Unspecified Kind is now stamped as UTC rather than converted.
- **The Blob sink failed confusingly on an abort.** `Export-Csv` writes no file for an
  empty input, so the upload then failed with a storage error that hid the real reason for
  the abort. An abort now records the run summary instead.
- **Configuring a report sink without selecting it was silent.** Setting the Teams webhook
  or the storage account while `-ReportSink` does not include that sink now warns.
- **PIM-eligible role holders were not protected.** The role assignment read returns
  active assignments only, so a guest merely *eligible* for an administrator role was
  fair game. Eligible assignments are now included, degrading with a warning on a tenant
  without Entra ID P2 rather than failing the run.

### Changed

- **Failure alerting is part of the deployment, not an afterthought.** `-Stage All`
  creates the alert when `-AlertEmail` is given, and says loudly when it is not.
  `-Stage Verify` reports a missing alert as a problem and prints the last run status.
  `-Stage Schedule` refuses to schedule enforcement unless a failure alert exists and is
  switched on, with `-SkipAlertCheck` as a deliberate override. A scheduled job that
  deletes accounts should not run with nobody watching for failed runs.
- `.gitignore` excludes `.claude/`, so local agent configuration does not follow the
  project into a public repository.

### Notes

Three things were checked and cleared rather than changed: listing
`/roleManagement/directory/roleAssignments` without `$filter` is documented as supported;
`continue` inside the `switch` in `Write-Report` does not skip the remaining sinks; and
the dot-source guard behaves correctly under every invocation style tested
(`pwsh -File`, the call operator, `Invoke-Expression`, `pwsh -Command`, and a scriptblock
built from the file), suppressing the run only when the file is genuinely dot-sourced.

## [1.1.0] - 2026-08-28

Simpler deployment, working failure alerting, and three fixes found by checking
assumptions against a live tenant before the first deploy.

### Added

- `-Stage All` on the deploy script. Imports the module, waits for the import to finish,
  publishes the runbook and verifies every Graph role by name. Setup is two commands.
  It excludes the schedule and the alert on purpose.
- The grant script reads the managed identity from the named Automation Account, so
  nobody has to look up an object ID. `-ManagedIdentityObjectId` still works for a host
  that is not an Automation Account.
- Retry on a throttled Graph call, up to four attempts, honouring Retry-After when Graph
  sends one. A run makes a hundred or more writes, and Graph limits writes to `/users`.
  Without this a single 429 failed an account, failed the job and sent a needless alert.

### Changed

- Failure alerting is now a metric alert on the Automation Account's own `TotalJob`
  metric, filtered to this runbook and to failed jobs. No Log Analytics workspace, no
  diagnostic setting, no query language. Az.Monitor renamed its action group cmdlets at
  version 5, and both spellings are handled.
- The schedule guard requires the disable window to be at least twice the run interval.
  The previous check only warned when the two were equal, so it would have passed a 35
  day window on a 30 day schedule, where about 83% of accounts skip the disable stage
  after one missed run.
- The default schedule interval is 15 days, not 30, so the 90 and 120 day thresholds
  satisfy that rule without further changes.
- The `JobLog` sink writes one line per account as CSV, capped at 500 accounts, rather
  than one formatted table. Azure Automation caps the size of a single output record, so
  a first run with thousands of candidates would have been truncated exactly when the
  report matters most.

### Added for public use

- `SECURITY.md`. How to report a fault that could delete an account it should not, the
  controls that limit the damage, and how to handle a run report, which is personal data.
- `CONTRIBUTING.md`. How to run the tests without a tenant, and a list of the decisions
  that are deliberate, so nobody simplifies away a safeguard without reading why it exists.
- A warning at the top of the README. This tool deletes user accounts, and that should be
  the first thing a stranger reads.
- Requirements now state the platform, the deploy-machine modules, the licence needed for
  `signInActivity`, the cost, and the directory size the job has been tested at.

### Fixed

- Property reads no longer use `.Contains()` on a dictionary. `Invoke-MgGraphRequest`
  returns a `Hashtable` at the top level, but a nested object such as `signInActivity`
  can arrive as a `Dictionary[string,object]`, where `.Contains()` throws "cannot find an
  overload" even after a cast to `IDictionary`. That would have thrown for every guest
  and failed the whole run. Indexing works on both types and is covered by tests.
- The guest query no longer sends `$count=true` or a `ConsistencyLevel` header. Verified
  against a live tenant that the `userType` filter and the `signInActivity` select both
  work as a plain query. The count was never read and needed the header to return
  anything, so the pair only added ways for the call to fail.
- Paths are built with multi-segment `Join-Path` instead of backslash literals. The tests
  and the deploy script could not run on macOS or Linux, because a backslash there becomes
  part of the filename rather than a separator. PowerShell 7 is cross-platform and so is
  the Az module, so deploying from a Mac is a normal thing to want to do.
- The runbook declares `#Requires -Version 7.2`. Someone importing it by hand can easily
  land on Windows PowerShell 5.1, and without this the first symptom is a confusing Graph
  module error rather than a clear statement of the cause.
- The deploy script imports the runbook as type `PowerShell72`. It used to pass
  `PowerShell`, which in Azure Automation means Windows PowerShell 5.1, where a current
  `Microsoft.Graph.Authentication` will not load. The runbook would have imported and
  published without complaint, then failed on its first Graph call. The Verify stage now
  checks the runtime as well as the runbook.
- `Write-Report` accepts an empty row set. Both abort paths call it with no rows, and a
  mandatory `[array]` parameter rejected an empty collection, so an abort died on a
  parameter binding error instead of reporting why it aborted.

## [1.0.0] - 2026-08-27

First working version.

### Added

- `src/Invoke-StaleGuestCleanup.ps1`. An Azure Automation runbook that disables a stale
  Entra ID guest account after one threshold and deletes it after a second, longer one.
  Authenticates with a managed identity, so no secret is involved.
- Aging that reads all three sign-in timestamps and takes the most recent. A guest who
  only ever opens a shared file registers a non-interactive sign-in, so reading
  `lastSignInDateTime` alone would age out guests who are actively using their access.
- Aging from `createdDateTime` for a guest that never signed in, which is how invitations
  nobody accepted get cleaned up.
- Stateless, idempotent operation. A disabled account cannot sign in, so its last
  activity date is frozen and the inactive count keeps rising on its own. Every run
  recomputes from Entra, so a missed run or a double run causes no drift.
- Safety rails: report-only default mode, `-WhatIf`, per-run caps that act on the most
  stale accounts first, an abort ceiling on total candidates, a guard that aborts when no
  guest in a sizeable directory has any sign-in data, a skip for guests holding a
  directory role, and a skip for guests with no usable dates.
- Exclusions by group (nested groups included), by domain, and by user principal name.
  The group read and the directory role read both fail closed, so a missing permission
  stops the run rather than silently dropping every exception.
- Report sinks: `JobLog` (default), `Blob`, `Teams`, and `None`.
- `deploy/Grant-ManagedIdentityGraphRoles.ps1`. Grants the six Graph application roles,
  with `-ReadOnly` to grant the four read roles first so the reporting can be proved
  before the job is able to change anything.
- `deploy/Deploy-StaleGuestCleanup.ps1`. Staged, idempotent deployment. The Schedule
  stage refuses to schedule enforcement until the runbook has completed at least one run,
  so somebody has to read a report first.
- `tests/StaleGuestLogic.Tests.ps1` and `tests/Orchestration.Tests.ps1`. 66 Pester tests
  covering the decision logic with synthetic dates, and the safety rails with the Graph
  layer mocked. No tenant needed.
- Documentation: deployment walkthrough, operations guide, and permissions rationale.

### Notes

- Filtering `signInActivity` server side is not attempted. Microsoft Graph answers such a
  filter on `/users` with `400 Filter not supported`, so the aging is done in memory.
- The 90 and 120 day defaults are a starting point, not a recommendation. Set thresholds
  that match a written rule you own.
