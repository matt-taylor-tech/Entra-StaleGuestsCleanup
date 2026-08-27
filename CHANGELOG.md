# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
