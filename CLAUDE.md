# Entra MFA Retirement Audit

<!-- Loaded in full at the start of every session. Keep it to facts that are true
     for ALL work in this repo. Anything that only matters for one part of the
     codebase belongs in .claude/rules/ with a paths: filter. Anything that is a
     multi-step procedure belongs in .claude/skills/. -->

Read-only PowerShell tooling that audits Entra ID authentication posture across a
~22,000 account tenant, to find every user who will be broken or force-migrated by
Microsoft's retirement of SMS and voice MFA.

## The deadlines everything here serves

| Date | What happens |
| --- | --- |
| 1 Sep 2026 | Passkeys become the default experience. Auto-enrollment plus registration-campaign nudges for anyone still on SMS/Voice — in AMP **or** legacy per-user MFA. |
| 30 Oct 2026 | Customer-managed telecom providers become selectable in the Microsoft Security Store. |
| 1 Feb 2027 | Microsoft-provided SMS/Voice delivery retires. Users whose only method is phone get a **blocking** passkey registration prompt. No opt-out. |

The cohort that matters most is *phone-only* users — `PhoneOnly = true` in the report.
They are the ones who get blocked, and admins among them are the priority within that.

## Non-negotiables

**These scripts are read-only.** No `PATCH`, no mutating `POST` (a `$batch` of `GET`s
is fine), no `DELETE`, no policy modification, anywhere. If a change would introduce
one, stop and escalate rather than writing it. This is the property that lets the
tooling run against production identity data at all.

**A generated CSV is a prioritised phishing target list.** It names every account whose
only second factor is a phone number and flags which of those hold admin roles.
Handling of output is a security control, not a convenience question. See Deliverables.

**Never introduce a per-user API loop.** This tooling has a documented history of
regressing from minutes to days that way. Bulk and report endpoints first; `$batch`
where there is no bulk endpoint; a per-user call only where none exists, and say so
explicitly when you write one.

## Architecture

Three layers. You are the middle one.

| Layer | Lives in | What it is |
| --- | --- | --- |
| 1. Procedure | `.claude/skills/` | SOPs. Goals, inputs, steps, edge cases. |
| 2. Orchestration | you | Pick the skill, run the scripts, handle errors, ask when blocked. |
| 3. Execution | `execution/` | Deterministic PowerShell 7. Graph calls, classification, CSV output. |

**Why:** if you do every step yourself, errors compound. 90% accuracy per step is
59% success over five steps. Push complexity into deterministic code so the only
thing you have to be reliably good at is deciding what to run next.

You do not query Graph by hand and eyeball the results. You invoke the
`phone-mfa-report` skill, which tells you to run `execution/latest-mfa-report.ps1`.

## Commands

```powershell
# Prerequisite — one module, not the full SDK
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

# Full run (interactive delegated auth; a browser window opens)
pwsh ./execution/latest-mfa-report.ps1 -OutputPath ./output

# Fast run — skips the per-user legacy-state stage, keeps phone-dependency analysis
pwsh ./execution/latest-mfa-report.ps1 -OutputPath ./output -SkipLegacyStateLookup

# See what every script does without reading them
cat execution/README.md
```

Graph scopes: `AuditLog.Read.All`, `User.Read.All`, `Policy.Read.All`.

Minimum Entra role: **Global Reader or Authentication Policy Administrator**.
Security Reader is *not* sufficient — it cannot read per-user MFA state, and a run
under it silently produces "Unknown" in the MFA Type column for every row. Requires
Entra ID P1 or above for the authentication methods activity report.

`Policy.Read.All` is the scope that grants `/authentication/requirements`.
`UserAuthenticationMethod.Read.All` does **not** — it covers `signInPreferences`
only. Getting this wrong 403s every legacy-state lookup.

## Layout

| Path | Contents |
| --- | --- |
| `.claude/skills/` | Procedures. One directory per skill, `SKILL.md` inside. |
| `.claude/agents/` | Subagents — isolated context, own tool set. |
| `.claude/rules/execution.md` | The script contract. Loads only when you touch `execution/`. |
| `execution/` | Deterministic PowerShell 7 scripts. |
| `execution/README.md` | One-line index of every script. Update it when you add one. |
| `mfa-report.md` | The original spec: what a complete audit would cover. |
| `mfa-challenges.md` | Migration challenges — legacy/AMP gap, SSPR, helpdesk, AAGUIDs. |
| `.tmp/` | All intermediate files. Never committed, always regenerable. |
| `output/` | Generated CSVs. Gitignored. Sensitive. Never committed. |

## Subagents

| Agent | Owns |
| --- | --- |
| `devops-engineer` | How scripts run — scheduling, credentials, artifact handling, alerting, runbooks. Not the Graph logic. |
| `script-reviewer` | Contract compliance of a single file in `execution/`. Reports, does not edit. |

Graph query design, endpoint selection, and MFA policy semantics are **yours**, not
the devops-engineer's. Hand back to it for anything about how a run is executed or
where output lands.

## The task loop

1. **Find the procedure.** Check `.claude/skills/`. If no skill covers the request,
   ask before writing one.
2. **Find the tool.** Check `execution/README.md`. Only write a new script if none
   fits.
3. **Run it.** Write intermediates to `.tmp/`, deliverables to `output/`.
4. **On failure, self-anneal.** Read the error, fix the script, re-test, then append
   what you learned to the skill's Learnings section.
5. **Stop after 3 failed fix attempts.** Report what you tried, what each attempt
   produced, and your best guess at the root cause. Do not keep looping.

A run that completes is not a run that succeeded. Check the warning stream and the
`LastUpdated` column before treating any output as current — see the skill's Edge
cases.

## Ask before you act

- Running a full report against the tenant — it is read-only, but it consumes
  tenant-wide Graph quota that is shared with everyone else's tooling
- Creating a new skill, or overwriting an existing one
- Deleting or overwriting anything outside `.tmp/`
- Anything that would make a script non-read-only
- Sending, uploading, or sharing a generated CSV anywhere

Skills are the instruction set. Preserve and improve them; don't rewrite them on
the fly.

## Deliverables

A deliverable here is a **local CSV in `output/`**, and it stays there.

Do not upload a report to a Sheet, attach it to mail, or post it in a Teams channel.
Do not paste rows into chat. Do not print UPNs to the terminal beyond the aggregate
counts the script already emits. The summary block — counts, not names — is the thing
that is safe to communicate; the row data is not.

Default retention is 30 days. These snapshots go stale within weeks and stay dangerous
indefinitely. If the user wants an artifact somewhere other than `output/`, that is a
`devops-engineer` conversation about scope, encryption, and retention — not a file
copy.
