# Contributing

Bug reports and pull requests are welcome. This tool deletes accounts, so the bar for
changes to the decision logic is high.

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester -Path ./tests
```

No tenant and no Azure subscription needed. Every Graph call is mocked. The tests run on
Windows, macOS, and Linux.

Also run the analyzer:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

It should report nothing. Every excluded rule in that settings file carries the reason it
is excluded. If you need to add one, add the reason too.

## If you change the decision logic

`Get-GuestLastActivity` and `Get-GuestStaleAction` decide whether an account lives or dies.
A change there needs a test.

Test with synthetic dates, not a real tenant. A guest account you create today is zero days
old, so no live tenant can exercise a 90 or 120 day boundary. That is why these tests
matter more than a tenant run does.

Cover the boundary itself and one day either side. Several bugs found during development
were exactly one day out.

Keep those two functions free of Graph calls. That separation is what makes them testable.

## Things that are deliberate

Please do not "simplify" these without reading why they exist:

- **All three sign-in timestamps are read, and the latest wins.** A guest who only opens a
  shared file registers a non-interactive sign-in and no interactive one. Reading
  `lastSignInDateTime` alone deletes people who are actively using their access.
- **Delete is checked before disable.** This is what makes the job safe to introduce to a
  neglected directory, or to run after a gap.
- **There is no state store.** A disabled account cannot sign in, so its clock is frozen
  and the count keeps rising by itself. Everything recomputes from Entra each run, which is
  what makes the job idempotent.
- **Property reads index into dictionaries rather than calling `.Contains()`.** A nested
  Graph object can arrive as `Dictionary[string,object]`, where `.Contains()` throws even
  after a cast to `IDictionary`.
- **The guest query sends no `$count` and no `ConsistencyLevel` header.** Verified
  unnecessary against a live tenant. `signInActivity` cannot be filtered server side at
  all — Graph answers with `400 Filter not supported` — which is why the aging is done in
  memory.
- **Fail-closed reads.** If the exclusion group or the directory role list cannot be read,
  the job stops. Returning an empty set would silently drop every exception an
  administrator set up.
- **The job log lists at most 500 accounts.** Azure Automation caps the size of a single
  output record, and a first run can have thousands of candidates.

## Style

- Follow the surrounding code.
- Comments say **why**, not what. If a line looks odd, the comment should explain the
  failure it prevents.
- Write documentation and commit messages in short, plain sentences and active voice. Most
  people deploying this are not PowerShell specialists.
- Anything that changes a tenant supports `-WhatIf`.

## What not to include

Never commit a tenant identifier, a domain name, a group object ID, a real user principal
name, or a run report. `.gitignore` covers the obvious cases. Check your diff.
