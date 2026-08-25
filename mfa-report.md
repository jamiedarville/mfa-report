# Task
Write a read-only PowerShell 7 script that produces a single consolidated report of every
user in an Entra ID tenant who is still enabled for SMS or Voice authentication, across
ALL configuration surfaces — not just the Authentication Methods Policy.

# Why this is non-trivial
Three configuration surfaces independently determine SMS/Voice eligibility:

1. Authentication Methods Policy (Entra ID > Authentication methods > Policies) — AMP
2. Legacy per-user MFA (Entra ID > Users > Per-user MFA > service settings)
3. Legacy SSPR authentication methods (Entra ID > Users > Password reset > Authentication methods)

A method can be enabled in one and unconfigured/disabled in another. Per Microsoft's
retirement doc, users enabled for SMS/Voice in AMP *or in legacy MFA settings* are in
scope for the Sept 1, 2026 auto-enablement of passkeys. An AMP-only audit undercounts.

Microsoft's own script (github.com/microsoft/entra-sms-voice-usage-analyzer,
Get-SmsVoicePolicyUsers.ps1) reads only the AMP policy object and resolves its scope
groups. Treat it as prior art to extend, not as a solution. Do not assume it covers
legacy state.

# Required output
One row per user, CSV + console summary. Minimum columns:

- UserPrincipalName, DisplayName, ObjectId, AccountEnabled
- InAmpSmsScope (bool), InAmpVoiceScope (bool)  — resolved through include/exclude
  targets, with group membership expanded and exclusions applied correctly
- AmpScopeReason (e.g. "All users", "Group: <name>", "Excluded by group: <name>")
- LegacyPerUserMfaState (disabled / enabled / enforced)
- RegisteredMethods (actual methods the user has registered)
- HasPhishResistantMethod (bool) — passkey/FIDO2/WHfB registered
- OnlyPhoneMethods (bool) — the highest-risk cohort; blocked at sign-in after Feb 1, 2027
- InScopeForSep2026 (bool) — union of AMP scope and legacy enablement
- Sources (which of the three surfaces flagged this user)

Also emit a summary block: total in scope, count by source, count with no
phishing-resistant fallback, and the overlap/delta between AMP-only and the union.

# Technical constraints
- Microsoft Graph PowerShell SDK. Support both delegated (interactive) and app-only
  (client credentials / certificate) auth. Parameterise TenantId.
- Read-only. No writes, no PATCH, no policy modification anywhere in the script.
- State the exact Graph scopes required and the minimum Entra role.
- Handle paging and 429 throttling with retry/backoff. Assume a tenant of 10,000+ users
  where per-user API calls are the bottleneck — prefer bulk/report endpoints over
  per-user loops, and say explicitly where a per-user call is unavoidable.
- Use the same paged-Graph pattern as a `signInActivity` bulk pull (batching, $select,
  nextLink handling, output buffering).
- PowerShell 7, cross-platform, no MSOnline or AzureAD module dependency (both retired).

# Accuracy requirements — important
For each of the three surfaces, identify the specific Graph endpoint and API version
(v1.0 vs beta) that exposes it, and state the confidence level. Candidate endpoints to
evaluate — verify each against current documentation rather than assuming:

- /policies/authenticationMethodsPolicy (AMP configurations for sms, voice)
- /users/{id}/authentication/requirements (per-user MFA state)
- /reports/authenticationMethods/userRegistrationDetails (registered methods)

If any surface has no supported API — particularly the legacy SSPR authentication
methods settings — say so explicitly, explain what the gap means for report
completeness, and propose the best available workaround (portal export, inference from
adjacent data, or documented limitation). Do NOT invent an endpoint to close the gap.
Flag any beta-only dependency as a stability risk.

# Deliverable
Commented script, a short README covering prerequisites/permissions/usage, and a
"Known limitations" section listing every place the report may be incomplete and why.