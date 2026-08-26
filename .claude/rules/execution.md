---
paths:
  - "execution/**/*.ps1"
---

# Script contract

Every file in `execution/` must:

- Be PowerShell 7, cross-platform. No Windows-only assumptions — no `$env:USERPROFILE`,
  no registry, no COM, no backslash path literals. Build paths with `Join-Path`.
- Depend on `Microsoft.Graph.Authentication` only. Call Graph through
  `Invoke-MgGraphRequest`, not the per-workload SDK modules — it avoids a heavy
  install and works identically against `v1.0` and `beta`.
- Open with a comment-based help block stating `.SYNOPSIS`, `.DESCRIPTION`, required
  Graph scopes, and the minimum Entra role.
- Expose a `[CmdletBinding()]` `param()` block. Every input is a parameter with a
  sensible default; nothing is read from a hardcoded constant mid-script.
- Set `$ErrorActionPreference = 'Stop'` at the top.
- Send progress and diagnostics to `Write-Host` / `Write-Verbose` / `Write-Progress`,
  and problems to `Write-Warning`. Keep the pipeline clean — a function that returns
  data must not also write to the success stream for logging.
- **Exit non-zero on partial data, not just on an unhandled exception.** Track a
  failure count or flag and `exit 1` if it is non-zero. A report built from throttled
  or access-denied calls looks complete and is wrong; that is this toolchain's
  characteristic failure and it must be loud.
- Read secrets from `$env:` only — never hardcode, never print, never log a
  credential, thumbprint, or tenant ID.
- Write intermediates to `.tmp/` and deliverables to `output/`, never to the repo root.
  Default `-OutputPath` to `./output`.

## Read-only, enforced

No `PATCH`, no mutating `POST`, no `DELETE`. `POST /$batch` carrying only `GET`
sub-requests is the one permitted `POST`. If you find yourself writing anything else,
stop — that is an escalation, not a code change.

## Scale rules

The tenant is ~22,000 accounts. These are correctness requirements, not optimisations:

- Bulk and report endpoints before per-user calls. `$select` and `$top=999` on
  collection queries.
- Follow `@odata.nextLink` to exhaustion. A silently truncated first page is
  indistinguishable from a small tenant.
- Handle `429` and `5xx` with `Retry-After` where present, exponential backoff where
  not, and a bounded attempt count that throws rather than returning partial data.
- **Narrow the candidate set before any per-user stage.** Filter to accounts that
  actually matter first, then batch — that ordering is what keeps runtime in minutes.
- Where no bulk endpoint exists, use `$batch` at 20 requests per call and say in a
  comment why the per-user call is unavoidable.
- A run should take minutes. If one takes more than 15, treat it as a code regression
  to diagnose, not a capacity problem to wait out.

## Classification must not fail silently

When mapping Graph values into report columns, match by pattern and route anything
unrecognised into an explicit `Unclassified` column. Never let an unknown value fall
through into a benign default — a new method name silently counted as "no phone
method" removes a user from the report who belongs in it.

## Known limitations are part of the script

End every script with a `KNOWN LIMITATIONS` block listing each place the output may be
incomplete and why: surfaces not evaluated, endpoints with no Graph equivalent,
`beta`-only dependencies, and report data lag. If a surface has no supported API, say
so and state the workaround. **Do not invent an endpoint to close a gap.**

Add a one-line entry to `execution/README.md` for every new script.

Use `execution/latest-mfa-report.ps1` as the reference implementation — its
`Invoke-GraphWithRetry`, `Get-GraphPaged`, `Split-Methods`, and `$batch` loop satisfy
the rules above and are the shortest path to a conforming new script.

New scripts should be named `Verb-Noun.ps1` using an approved PowerShell verb.
`latest-mfa-report.ps1` predates this rule and keeps its name.
