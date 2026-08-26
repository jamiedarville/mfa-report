---
name: phone-mfa-report
description: Produce the tenant report of users who can still sign in with SMS or a phone call, flagged Legacy vs Modern, in plain-English columns for a non-technical reader. Use when the user asks who is still on SMS or voice, who gets blocked by the Feb 2027 retirement, who is phone-only, which admins are exposed, or asks to run the MFA report or refresh it.
allowed-tools: Bash, Read, Write
---

# SMS / voice MFA report

**Goal:** one CSV in `output/`, readable by someone who does not know what Entra is,
listing every user who can still authenticate with a phone.

## Inputs

- **TenantId** — optional. Only needed if the signed-in account has access to more
  than one tenant.
- **Scope of run** — full, or `-SkipLegacyStateLookup`. Default to full. Skipping
  turns the `MFA Type` column into "Unknown" for every row, which removes the main
  thing the report exists to answer, so only skip if the user asks for speed.
- **`-IncludeTechnicalColumns`** — off by default. Adds raw Graph values prefixed
  with `_` for troubleshooting. Do not add these to a report meant for a
  non-technical audience.

Do not ask about `-OutputPath`. It is `./output`.

## Tools

- `execution/latest-mfa-report.ps1` — three stages: registration details filtered
  server-side to phone holders, a department/job-title lookup, then batched per-user
  MFA state.

## Steps

1. Confirm the module is present:
   `pwsh -c "Get-Module -ListAvailable Microsoft.Graph.Authentication"`
   If absent, tell the user the install command — do not install it silently.
2. Check the signed-in account holds **Global Reader** — the only single role that
   covers both the registration report and per-user MFA state. Authentication
   Policy Administrator covers only stage 3 (stage 1 hard-fails under it);
   Security/Reports Reader covers only stage 1 (MFA Type comes back Unknown).
3. Tell the user a browser window will open, and that the run consumes tenant-wide
   Graph quota. Get a go-ahead before starting.
4. Run `pwsh ./execution/latest-mfa-report.ps1 -OutputPath ./output`.
5. **Check the exit code.** Non-zero means partial data — the script says so and
   names the count. Do not present a non-zero run as a finished report.
6. **Read the warning stream before the CSV.** Denied lookups mean `MFA Type` is
   unreliable. Unrecognised method names mean the vocabulary in the script is stale
   and some users may be wrongly marked as having no backup method.
7. Check `Data As Of`. The source refreshes roughly every 36 hours; if it is stale
   by more than a couple of days, surface that before anyone acts on it.
8. Report the summary block — counts only.

## Outputs

- `output/SMS-Voice-MFA-Users-<yyyy-MM-dd>.csv`

Sensitive. Hand over the path, not the contents. Never paste rows, names, or the
admin subset into chat, a Sheet, mail, or a channel — see Deliverables in CLAUDE.md.

## The columns

Written for a non-technical reader. Sort by `Priority` and work down.

| Column | Means |
| --- | --- |
| `Priority` | `1 - Urgent`: at risk **and** an administrator. `2 - High`: no durable non-phone backup (includes temporary-pass-only and unrecognised-method rows). `3 - Medium`: signs in with SMS/voice by default but has a backup — regardless of Legacy/Modern. `4 - Low`: on legacy per-user MFA, non-phone default. `5 - Monitor`: phone is a spare. |
| `MFA Type` | **Legacy** = still governed by the old per-user MFA surface. **Modern** = governed by the Authentication Methods Policy. |
| `Phone Can Receive` | "Text message or phone call" if a mobile is registered; "Phone call only" for office/alternate numbers, which cannot receive SMS. |
| `Currently Signs In With` | Their actual default method. The only field that reliably separates SMS from voice. |
| `Has Non-Phone Backup` | Four values: `Yes` / `No` / `Temporary pass only` (a TAP expires — not a real backup) / `Unknown - method not recognised` (verify with IT before trusting the row). "No" and "Temporary pass only" are the cohort that gets blocked after 1 Feb 2027. |
| `Backup Methods` | Every registered non-phone method, labelled `(temporary)` or `(unrecognised)` where applicable — never blank when the backup answer is not "No". |
| `After 1 Feb 2027` | Plain-English outcome for that user. |
| `Action Needed` | What to tell them to do. Says "No action needed yet" only when the legacy state was actually confirmed. |
| `Data As Of` | When Microsoft last refreshed the source report. |

`MFA Type` describes **governance, not the method**. A user can be Modern and still
be entirely on SMS. If someone reads "Modern" as "safe", correct them.

## Edge cases

- **`MFA Type` is "Unknown - permission denied" everywhere** — the signed-in account
  lacks `Policy.Read.All` or the right role. Re-run under Global Reader or
  Authentication Policy Administrator. Do not report "Unknown" as "Modern".
- **Someone asks where the disabled accounts are** — Microsoft excludes disabled and
  soft-deleted users from `userRegistrationDetails` at source. They cannot appear.
  There is no parameter for it; a separate `/users` pull is the only route.
- **Server-side filter rejected (HTTP 400)** — the script falls back to a full
  tenant scan automatically and warns. Result is identical, run is slower. Any
  other stage-1 failure (throttle exhaustion, missing consent, licensing) is NOT
  a filter problem and now surfaces as itself — read the actual error.
- **"lookups throttled - retrying (sweep N/4)"** — normal. Graph throttles `$batch`
  sub-requests individually; the script re-batches them with backoff. Only users
  still throttled after the final sweep count as failures.
- **Run exceeds 15 minutes** — look for a per-user loop that bypassed the stage-1
  filter. This is a code regression, not slowness.
- **Counts swing sharply run over run** — suspect a classification bug before
  believing the tenant changed that much.
- **User asks for AMP scope** — this script does not evaluate Authentication Methods
  Policy include/exclude targets, so it can undercount and overcount in opposite
  directions. Point at `mfa-report.md` and Microsoft's
  `entra-sms-voice-usage-analyzer` for that surface.
- **User asks about SSPR method configuration** — legacy SSPR authentication methods
  have no documented Graph surface. Portal export only. Do not infer.

## Learnings

Append-only. Record throttling behaviour, consent quirks, and any method name that
turned up in the unclassified warning.

- The report endpoint is GA in `v1.0`; only `/authentication/requirements`
  (per-user MFA state) still requires `beta`.
- `userRegistrationDetails` has no `defaultMfaMethod` property. The real fields are
  `userPreferredMethodForSecondaryAuthentication` and, when
  `isSystemPreferredAuthenticationMethodEnabled` is true,
  `systemPreferredAuthenticationMethods`.
- The only single role covering all stages is Global Reader: APA cannot read
  `userRegistrationDetails` (delegated roles for it are Reports Reader, Security
  Reader, Security Administrator, Global Reader), and none of those except Global
  Reader can read `/authentication/requirements`.
- Graph throttles `$batch` sub-requests individually — a 429 arrives inside an
  HTTP 200 envelope with its own `Retry-After`, and Microsoft's guidance is to
  re-batch just the failed items. Envelope-level retry never sees these.
- PS7 `Export-Csv -Encoding UTF8` writes no BOM; Excel then garbles accented
  names. `utf8BOM` is required for anything a non-technical reader will open.
