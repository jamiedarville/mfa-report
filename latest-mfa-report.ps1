<#
.SYNOPSIS
    Identifies users whose MFA still depends on phone-based methods (SMS / voice),
    including those enabled via the LEGACY per-user MFA surface.

.DESCRIPTION
    Read-only. Answers two questions that are frequently conflated:

      1. LEGACY ENABLEMENT  - is the user enabled/enforced in the legacy per-user MFA
                              surface (Entra ID > Users > Per-user MFA)?
      2. PHONE DEPENDENCY   - does the user have a phone method registered, and is it
                              their ONLY MFA method (i.e. blocked at sign-in after
                              Feb 1 2027)?

    Deliberately scoped. This script does NOT evaluate Authentication Methods Policy
    (AMP) include/exclude scope. See "KNOWN LIMITATIONS" at the bottom.

.NOTES
    Requires only Microsoft.Graph.Authentication. All calls go through
    Invoke-MgGraphRequest so no beta SDK module install is needed.

    Interactive delegated auth, same pattern as the existing tenant MFA report.
    Minimum Entra role: Global Reader, Security Reader, or Authentication Policy
    Administrator.
#>

[CmdletBinding()]
param(
    [string] $TenantId,

    # Skip the per-user legacy MFA state lookup (stage 2). Much faster; you lose the
    # legacy enablement column but keep the phone-dependency analysis.
    [switch] $SkipLegacyStateLookup,

    # Include accounts where AccountEnabled = false.
    [switch] $IncludeDisabledAccounts,

    [string] $OutputPath = (Join-Path $env:USERPROFILE "Downloads")
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Method classification
# ---------------------------------------------------------------------------
# methodsRegistered values from userRegistrationDetails. Classified by pattern
# rather than a fixed list so that new method names do not silently fall through.
# Anything unmatched is surfaced in the UnclassifiedMethods column - it is never
# quietly counted as "no MFA".

$PhonePattern  = '(?i)(mobilephone|alternatemobilephone|officephone|^sms$|voice)'
$NonMfaPattern = '(?i)(^password$|^email$|securityquestion)'   # not second factors
$StrongPattern = '(?i)(fido|passkey|windowshello|authenticator|onetimepasscode|oath|certificate|temporaryaccesspass|platformcredential)'

$PhoneDefaults = @('mobilePhone','alternateMobilePhone','officePhone')

function Split-Methods {
    param([string[]] $Methods)

    $phone = @(); $strong = @(); $other = @(); $unknown = @()

    foreach ($m in $Methods) {
        if     ($m -match $PhonePattern)  { $phone   += $m }
        elseif ($m -match $StrongPattern) { $strong  += $m }
        elseif ($m -match $NonMfaPattern) { $other   += $m }
        else                              { $unknown += $m }
    }

    [PSCustomObject]@{
        Phone        = $phone
        NonPhoneMfa  = $strong
        NotSecondFactor = $other
        Unclassified = $unknown
    }
}

# ---------------------------------------------------------------------------
# Graph helper - paging + 429 handling
# ---------------------------------------------------------------------------
function Invoke-GraphWithRetry {
    param(
        [string] $Uri,
        [string] $Method = 'GET',
        $Body,
        [int]    $MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $splat = @{ Uri = $Uri; Method = $Method; OutputType = 'PSObject' }
            if ($Body) {
                $splat.Body        = ($Body | ConvertTo-Json -Depth 10)
                $splat.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @splat
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 429 -or $status -ge 500) {
                $wait = [int]($_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds)
                if (-not $wait -or $wait -le 0) { $wait = [math]::Pow(2, $attempt) }
                Write-Verbose "HTTP $status - backing off $wait seconds (attempt $attempt/$MaxAttempts)"
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
    throw "Giving up on $Uri after $MaxAttempts attempts."
}

function Get-GraphPaged {
    param([string] $Uri)

    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0

    while ($next) {
        $page++
        $resp = Invoke-GraphWithRetry -Uri $next
        if ($resp.value) { $all.AddRange(@($resp.value)) }
        Write-Progress -Activity "Paging Graph" -Status "$Uri - page $page, $($all.Count) records" -Id 1
        $next = $resp.'@odata.nextLink'
    }
    Write-Progress -Activity "Paging Graph" -Id 1 -Completed
    return $all
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
# AuditLog.Read.All  -> userRegistrationDetails report
# User.Read.All      -> account enabled / UPN / userType
# UserAuthenticationMethod.Read.All -> per-user legacy MFA state (see caveat below)
$Scopes = @(
    "AuditLog.Read.All",
    "User.Read.All",
    "UserAuthenticationMethod.Read.All"
)

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
if ($TenantId) { Connect-MgGraph -Scopes $Scopes -TenantId $TenantId -NoWelcome }
else           { Connect-MgGraph -Scopes $Scopes -NoWelcome }

$ctx = Get-MgContext
Write-Host "  Tenant : $($ctx.TenantId)" -ForegroundColor DarkGray
Write-Host "  Account: $($ctx.Account)"  -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# STAGE 1 - bulk registration details (one paged call, not one call per user)
# ---------------------------------------------------------------------------
Write-Host "`n[1/3] Pulling authentication method registration details..." -ForegroundColor Cyan

$regUri  = "https://graph.microsoft.com/beta/reports/authenticationMethods/userRegistrationDetails"
$regData = Get-GraphPaged -Uri $regUri
Write-Host "      $($regData.Count) registration records." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# STAGE 2 - account metadata (bulk, for enabled/type filtering)
# ---------------------------------------------------------------------------
Write-Host "[2/3] Pulling account metadata..." -ForegroundColor Cyan

$userUri = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName,displayName,accountEnabled,userType,department,jobTitle&`$top=999"
$userData = Get-GraphPaged -Uri $userUri

$userMap = @{}
foreach ($u in $userData) { $userMap[$u.id] = $u }
Write-Host "      $($userData.Count) directory accounts." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Narrow to phone-dependent candidates BEFORE the expensive per-user stage
# ---------------------------------------------------------------------------
$candidates = [System.Collections.Generic.List[object]]::new()

foreach ($r in $regData) {

    $split = Split-Methods -Methods @($r.methodsRegistered)
    if ($split.Phone.Count -eq 0) { continue }        # no phone method = out of scope

    $acct = $userMap[$r.id]
    if (-not $acct) { continue }                       # deleted / not in directory scope
    if (-not $IncludeDisabledAccounts -and -not $acct.accountEnabled) { continue }

    $candidates.Add([PSCustomObject]@{
        Reg   = $r
        Acct  = $acct
        Split = $split
    })
}

Write-Host "      $($candidates.Count) accounts have at least one phone method registered." -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# STAGE 3 - legacy per-user MFA state, via $batch (20 per request)
# ---------------------------------------------------------------------------
$legacyState = @{}
$legacyLookupFailed = $false

if ($SkipLegacyStateLookup) {
    Write-Host "[3/3] Legacy per-user MFA state lookup SKIPPED by parameter." -ForegroundColor DarkYellow
}
else {
    Write-Host "[3/3] Reading legacy per-user MFA state (batched)..." -ForegroundColor Cyan

    $ids       = $candidates.Reg.id
    $batchSize = 20
    $done      = 0

    for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {

        $chunk = $ids[$i..([math]::Min($i + $batchSize - 1, $ids.Count - 1))]

        $requests = @()
        $n = 0
        foreach ($id in $chunk) {
            $n++
            $requests += @{
                id     = "$n"
                method = "GET"
                url    = "/users/$id/authentication/requirements"
            }
        }

        try {
            $resp = Invoke-GraphWithRetry `
                        -Uri    "https://graph.microsoft.com/beta/`$batch" `
                        -Method "POST" `
                        -Body   @{ requests = $requests }
        }
        catch {
            Write-Warning "Batch starting at index $i failed: $($_.Exception.Message)"
            $legacyLookupFailed = $true
            continue
        }

        foreach ($r in $resp.responses) {
            $idx = [int]$r.id - 1
            $uid = $chunk[$idx]

            if ($r.status -eq 200) {
                $legacyState[$uid] = $r.body.perUserMfaState
            }
            elseif ($r.status -eq 403) {
                $legacyState[$uid] = "AccessDenied"
                $legacyLookupFailed = $true
            }
            else {
                $legacyState[$uid] = "Error:$($r.status)"
            }
        }

        $done += $chunk.Count
        Write-Progress -Activity "Legacy per-user MFA state" `
                       -Status "$done / $($ids.Count)" `
                       -PercentComplete (($done / $ids.Count) * 100) -Id 2
    }
    Write-Progress -Activity "Legacy per-user MFA state" -Id 2 -Completed

    if ($legacyLookupFailed) {
        Write-Warning "One or more legacy state lookups were denied or errored."
        Write-Warning "The perUserMfaState read may require additional consent. Rows show the failure reason rather than a state."
    }
}

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
Write-Host "`nBuilding report..." -ForegroundColor Cyan

$Report = foreach ($c in $candidates) {

    $r     = $c.Reg
    $acct  = $c.Acct
    $split = $c.Split

    $state = if ($SkipLegacyStateLookup) { "NotChecked" }
             elseif ($legacyState.ContainsKey($r.id)) { $legacyState[$r.id] }
             else { "NotRetrieved" }

    $legacyEnabled = $state -in @('enabled','enforced')
    $phoneOnly     = ($split.NonPhoneMfa.Count -eq 0 -and $split.Unclassified.Count -eq 0)
    $defaultPhone  = $r.defaultMfaMethod -in $PhoneDefaults

    # Priority for remediation:
    #   CRITICAL - phone is the only MFA method: blocking prompt after Feb 1 2027
    #   HIGH     - legacy per-user MFA enabled AND phone is the default method
    #   MEDIUM   - legacy per-user MFA enabled, but a non-phone method exists
    #   LOW      - phone registered as a secondary method only
    $priority =
        if     ($phoneOnly)                    { "CRITICAL" }
        elseif ($legacyEnabled -and $defaultPhone) { "HIGH" }
        elseif ($legacyEnabled)                { "MEDIUM" }
        else                                   { "LOW" }

    [PSCustomObject]@{
        DisplayName           = $acct.displayName
        UPN                   = $acct.userPrincipalName
        ObjectId              = $r.id
        AccountEnabled        = $acct.accountEnabled
        UserType              = $acct.userType
        Department            = $acct.department
        JobTitle              = $acct.jobTitle

        LegacyPerUserMfaState = $state
        LegacyMfaEnabled      = $legacyEnabled

        PhoneMethods          = ($split.Phone -join '; ')
        NonPhoneMfaMethods    = ($split.NonPhoneMfa -join '; ')
        UnclassifiedMethods   = ($split.Unclassified -join '; ')
        DefaultMfaMethod      = $r.defaultMfaMethod
        DefaultIsPhone        = $defaultPhone

        PhoneOnly             = $phoneOnly
        IsMfaRegistered       = $r.isMfaRegistered
        IsMfaCapable          = $r.isMfaCapable
        # Registered but not capable = the registered method is NOT allowed by the
        # Authentication Methods Policy. Worth investigating separately.
        RegisteredNotCapable  = ($r.isMfaRegistered -eq $true -and $r.isMfaCapable -eq $false)
        IsAdmin               = $r.isAdmin
        IsSsprRegistered      = $r.isSsprRegistered

        RemediationPriority   = $priority
        LastUpdated           = $r.lastUpdatedDateTime
    }
}

$Report = $Report | Sort-Object @{ E = {
    switch ($_.RemediationPriority) { "CRITICAL" {0} "HIGH" {1} "MEDIUM" {2} default {3} }
}}, UPN

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$critical = @($Report | Where-Object PhoneOnly)
$legacyOn = @($Report | Where-Object LegacyMfaEnabled)
$admins   = @($critical | Where-Object IsAdmin)
$notCap   = @($Report | Where-Object RegisteredNotCapable)

Write-Host "`n===== SUMMARY =====" -ForegroundColor Green
Write-Host ("  Accounts with a phone method registered : {0}" -f $Report.Count)
Write-Host ("  Phone is their ONLY MFA method          : {0}" -f $critical.Count) -ForegroundColor Red
Write-Host ("    ...of which hold an admin role        : {0}" -f $admins.Count)   -ForegroundColor Red
Write-Host ("  Enabled/enforced in LEGACY per-user MFA : {0}" -f $legacyOn.Count) -ForegroundColor Yellow
Write-Host ("  Phone set as default MFA method         : {0}" -f @($Report | Where-Object DefaultIsPhone).Count)
Write-Host ("  Registered but not policy-capable       : {0}" -f $notCap.Count)

Write-Host "`n  Legacy per-user MFA state breakdown:" -ForegroundColor Cyan
$Report | Group-Object LegacyPerUserMfaState | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ("    {0,-15} {1}" -f $_.Name, $_.Count) }

Write-Host "`n  The $($critical.Count) CRITICAL accounts face a blocking passkey" -ForegroundColor Red
Write-Host "  registration prompt after Feb 1 2027. No opt-out exists." -ForegroundColor Red

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$date = Get-Date -Format "ddMMMyyyy"
$file = Join-Path $OutputPath "LegacyPhoneMFA-$date.csv"
$Report | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV exported to: $file" -ForegroundColor Green

$criticalFile = Join-Path $OutputPath "LegacyPhoneMFA-CRITICAL-$date.csv"
$critical | Export-Csv -Path $criticalFile -NoTypeInformation -Encoding UTF8
Write-Host "Critical-only CSV: $criticalFile" -ForegroundColor Green


<#
KNOWN LIMITATIONS
=================

1. AMP SCOPE IS NOT EVALUATED.
   This script does not read Authentication Methods Policy include/exclude targets.
   A user can be in AMP SMS scope with no phone number registered - they will not
   appear here. Conversely a user here may be excluded from SMS in AMP. To close
   that gap, cross-reference against Get-SmsVoicePolicyUsers.ps1
   (github.com/microsoft/entra-sms-voice-usage-analyzer), which covers AMP scope
   and nothing else.

2. LEGACY SSPR AUTHENTICATION METHODS ARE NOT READABLE.
   The legacy SSPR blade settings (Entra ID > Users > Password reset >
   Authentication methods) have no documented Graph surface. isSsprRegistered is
   included as a proxy but is not equivalent. If SSPR method configuration matters
   to your scope decision, it must be captured from the portal manually.

3. perUserMfaState IS BETA-ONLY.
   /beta/users/{id}/authentication/requirements has no v1.0 equivalent and is
   subject to change. There is no bulk endpoint - $batch at 20/request is the
   fastest supported approach. Batching is applied only to accounts that already
   have a phone method registered, which is what keeps this tractable at scale.

4. REGISTRATION IS NOT THE SAME AS ELIGIBILITY.
   A registered mobile number can serve SMS or voice depending on policy and the
   user's default method. methodsRegistered does not distinguish the two.
   DefaultMfaMethod is the closest available signal for which one is actually in use.

5. REPORT DATA LAG.
   userRegistrationDetails is a reporting endpoint and is not real-time. Check the
   LastUpdated column before treating any row as current.

6. LICENSING.
   The authentication methods activity report requires Entra ID P1 or above.
#>