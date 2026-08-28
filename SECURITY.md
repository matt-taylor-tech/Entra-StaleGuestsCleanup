# Security

## What this tool can do

This runbook disables and deletes user accounts in a Microsoft Entra ID directory. Treat
it as privileged software. A fault, a wrong parameter, or a stolen credential could remove
accounts.

Read the code before you deploy it. That is not a formality: it is a few hundred lines and
you are giving it the ability to delete identities in your tenant.

## Reporting a vulnerability

Report anything that could cause the job to delete an account it should not, or that
widens the permissions it needs, by opening a
[security advisory](https://github.com/matt-taylor-tech/Entra-StaleGuestsCleanup/security/advisories/new)
rather than a public issue.

Please include the thresholds, the mode, and the parameters in use, and the report row or
log line if you have one. **Do not include real user principal names, email addresses, or
tenant identifiers.** Replace them with placeholders.

## How the design limits the damage

These are deliberate and worth keeping if you fork the project.

- **No secret exists.** Authentication is an Azure managed identity. There is no
  certificate or client secret to leak, and nothing to rotate.
- **Least privilege.** Six narrow Graph application roles rather than
  `User.ReadWrite.All` or `Directory.ReadWrite.All`. See
  [docs/PERMISSIONS.md](docs/PERMISSIONS.md).
- **Write permissions are a separate grant.** `-ReadOnly` on the grant script gives only
  the four read roles. Until you run it again without that switch, the job physically
  cannot change an account whatever its parameters say. This is the strongest control
  available, because it does not depend on anyone remembering which mode a schedule is in.
- **Report-only by default.** `-Mode Enforce` has to be asked for.
- **Per-run caps and an abort ceiling.** A wrong threshold cannot turn into a mass
  deletion in one run.
- **Fails closed on missing data.** If the sign-in data is unusable, or the exclusion group
  or directory role list cannot be read, the job stops rather than acting on an incomplete
  picture. A permission being taken away must never look like "every guest is stale".
- **Guests holding a directory role are skipped**, not deleted quietly.

## Handling the run report

A report contains display names, user principal names, email addresses, and company names
of real people. It is personal data.

- Keep the `Blob` container private, and give it a retention policy that matches the rules
  you are subject to.
- `.gitignore` excludes `*.csv` so a report cannot be committed by accident. Keep that.
- Do not paste a report into an issue, a pull request, or a chat with a third party.

## Recovery

A deleted Entra user is restorable for **30 days**: Entra admin centre > Users > Deleted
users > Restore. After that it is gone.

Restoring returns group memberships. It does not restore sharing links tied to the
identity, which is why the job records each account's memberships in the report *before*
deleting it.
