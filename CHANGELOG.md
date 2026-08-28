# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
