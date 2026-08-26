<#
.SYNOPSIS
    Reports every user who can still sign in with SMS or a phone call, in a format
    a non-technical reader can act on.

.DESCRIPTION
    Read-only. One row per user who has a phone number registered as an MFA method.

    Answers, in plain language:
      - Who is still on SMS / voice?
      - Is that user governed by LEGACY per-user MFA, or by the modern
        Authentication Methods Policy?  -> the "MFA Type" column
      - Do they have any non-phone method to fall back on?
      - What happens to them after 1 Feb 2027?

    Deliberately scoped. This script does NOT evaluate Authentication Methods Policy
    (AMP) include/exclude scope. See "KNOWN LIMITATIONS" at the bottom.

.NOTES
    Requires only Microsoft.Graph.Authentication. All calls go through
    Invoke-MgGraphRequest so no beta SDK module install is needed.

    Graph scopes:
      AuditLog.Read.All  -> userRegistrationDetails report
      User.Read.All      -> department / job title
      Policy.Read.All    -> per-user MFA state (/authentication/requirements)

    Minimum Entra role: Global Reader or Authentication Policy Administrator.
    Security Reader is NOT sufficient - it cannot read per-user MFA state.

    Requires Microsoft Entra ID P1 or above.
#>

[CmdletBinding()]
param(
    [string] $TenantId,

    # Skip the per-user legacy MFA state lookup (stage 3). Much faster; the
    # "MFA Type" column becomes "Unknown" for every row.
    [switch] $SkipLegacyStateLookup,

    # Add the raw Graph values as extra columns, for troubleshooting.
    [switch] $IncludeTechnicalColumns,

    # Default to the repo's gitignored output/ directory. Do NOT default this to a
    # user profile path - $env:USERPROFILE is Windows-only and resolves to $null on
    # Linux/macOS, which silently drops the CSV into the current working directory.
    [string] $OutputPath = (Join-Path $PSScriptRoot ".." "output")
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

# Every non-fatal problem increments this. Non-zero => exit 1, so a scheduled run
# fails loudly rather than filing an incomplete snapshot as a success.
$script:FailureCount = 0

# Method names Graph returned that this script does not recognise. Never silently
# ignored - an unknown name could be a second factor, which would wrongly mark
# someone as having no backup method.
$script:UnclassifiedUsers = @()

# ---------------------------------------------------------------------------
# Method vocabulary
# ---------------------------------------------------------------------------
# Values below are the documented methodsRegistered strings from
# userRegistrationDetails (v1.0). Only mobilePhone can receive an SMS; office and
# alternate-mobile numbers are voice-call only. That distinction is the difference
# between "SMS" and "Voice" at the registration level.

$PhoneMethodFriendly = @{
    'mobilePhone'          = 'Text message or phone call'
    'officePhone'          = 'Phone call only'
    'alternateMobilePhone' = 'Phone call only'
}

# Non-phone methods that satisfy MFA. Pattern-matched so a newly introduced name
# containing a known stem still classifies rather than falling through.
$StrongPattern = '(?i)(fido|passkey|windowshello|authenticator|onetimepasscode|oath|certificate|temporaryaccesspass|secureenclave|platformcredential)'

# Registered, but not a second factor on their own.
$NotSecondFactorPattern = '(?i)(^password$|^email$|securityquestion|apppassword)'

# userPreferredMethodForSecondaryAuthentication / systemPreferredAuthenticationMethods
# enum -> plain English. These are the ONLY fields that distinguish SMS from voice.
$PreferredFriendly = @{
    'sms'                  = 'Text message (SMS)'
    'voiceMobile'          = 'Phone call to mobile'
    'voiceAlternateMobile' = 'Phone call to alternate mobile'
    'voiceOffice'          = 'Phone call to office phone'
    'push'                 = 'Microsoft Authenticator app'
    'oath'                 = 'Authenticator code'
    'none'                 = 'Not set'
}
$PhonePreferred = @('sms','voiceMobile','voiceAlternateMobile','voiceOffice')

function Split-Methods {
    param([string[]] $Methods)

    $phone = @(); $strong = @(); $other = @(); $unknown = @()

    foreach ($m in $Methods) {
        if     ($PhoneMethodFriendly.ContainsKey($m))  { $phone   += $m }
        elseif ($m -match $StrongPattern)              { $strong  += $m }
        elseif ($m -match $NotSecondFactorPattern)     { $other   += $m }
        else                                           { $unknown += $m }
    }

    [PSCustomObject]@{
        Phone           = $phone
        NonPhoneMfa     = $strong
        NotSecondFactor = $other
        Unclassified    = $unknown
    }
}

# ---------------------------------------------------------------------------
# Graph helpers - paging + 429 handling
# ---------------------------------------------------------------------------
function Get-GraphStatusCode {
    param($ErrorRecord)

    # Invoke-MgGraphRequest surfaces failures inconsistently across versions: some
    # carry an HttpResponseMessage, some only a status code on the exception, some
    # only the text. Check every shape rather than assuming one.
    $ex = $ErrorRecord.Exception

    foreach ($probe in @(
        { $ex.Response.StatusCode.value__ },
        { [int] $ex.Response.StatusCode },
        { [int] $ex.StatusCode },
        { [int] $ErrorRecord.TargetObject.StatusCode }
    )) {
        try {
            $code = & $probe
            if ($code -is [int] -and $code -ge 100) { return $code }
        } catch { }
    }

    if ($ErrorRecord.ErrorDetails.Message -match '"code"\s*:\s*"TooManyRequests"') { return 429 }
    return 0
}

function Get-RetryAfterSeconds {
    param($ErrorRecord, [int] $Attempt)

    try {
        $delta = $ErrorRecord.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
        if ($delta -and $delta -gt 0) { return [int] $delta }
    } catch { }

    return [int] [math]::Min([math]::Pow(2, $Attempt), 60)
}

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
            $status = Get-GraphStatusCode -ErrorRecord $_
            if ($status -eq 429 -or $status -ge 500) {
                $wait = Get-RetryAfterSeconds -ErrorRecord $_ -Attempt $attempt
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
    param([string] $Uri, [string] $Activity = 'Paging Graph')

    $all  = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0

    while ($next) {
        $page++
        $resp = Invoke-GraphWithRetry -Uri $next
        if ($resp.value) { $all.AddRange(@($resp.value)) }
        Write-Progress -Activity $Activity -Status "page $page, $($all.Count) records" -Id 1
        $next = $resp.'@odata.nextLink'
    }
    Write-Progress -Activity $Activity -Id 1 -Completed
    return $all
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
# Policy.Read.All is the scope that grants /authentication/requirements.
# UserAuthenticationMethod.Read.All does NOT - it covers signInPreferences only.
$Scopes = @(
    "AuditLog.Read.All",
    "User.Read.All",
    "Policy.Read.All"
)

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
if ($TenantId) { Connect-MgGraph -Scopes $Scopes -TenantId $TenantId -NoWelcome }
else           { Connect-MgGraph -Scopes $Scopes -NoWelcome }

$ctx = Get-MgContext
Write-Host "  Tenant : $($ctx.TenantId)" -ForegroundColor DarkGray
Write-Host "  Account: $($ctx.Account)"  -ForegroundColor DarkGray

$missingScopes = @($Scopes | Where-Object { $_ -notin $ctx.Scopes })
if ($missingScopes.Count -gt 0) {
    Write-Warning "Consent was not granted for: $($missingScopes -join ', ')"
    Write-Warning "Columns backed by those scopes will be incomplete."
    $script:FailureCount++
}

# ---------------------------------------------------------------------------
# STAGE 1 - registration details, filtered server-side to phone holders
# ---------------------------------------------------------------------------
# v1.0, not beta: this resource is GA. methodsRegistered supports $filter with
# any/eq, so the tenant-wide scan happens on Microsoft's side, not here.
Write-Host "`n[1/3] Finding users with a phone method registered..." -ForegroundColor Cyan

$phoneFilter = ($PhoneMethodFriendly.Keys | ForEach-Object {
    "methodsRegistered/any(m:m eq '$_')"
}) -join ' or '

$regBase = "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails"

try {
    $regData = Get-GraphPaged -Uri "$regBase`?`$filter=$([uri]::EscapeDataString($phoneFilter))" `
                              -Activity 'Registration details (filtered)'
}
catch {
    # $filter on this report endpoint is not universally available. Fall back to a
    # full pull rather than returning nothing - slower, same result.
    Write-Warning "Server-side filter rejected ($($_.Exception.Message.Trim())). Falling back to a full scan."
    $regData = Get-GraphPaged -Uri $regBase -Activity 'Registration details (full scan)' |
               Where-Object { @($_.methodsRegistered | Where-Object { $PhoneMethodFriendly.ContainsKey($_) }).Count -gt 0 }
}

$regData = @($regData)
Write-Host "      $($regData.Count) users have a phone number registered." -ForegroundColor Yellow

if ($regData.Count -eq 0) {
    Write-Host "Nothing to report." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# STAGE 2 - department / job title only
# ---------------------------------------------------------------------------
# userRegistrationDetails already carries userPrincipalName, userDisplayName and
# userType, so this pull exists purely to attach org context for whoever has to
# chase these people down.
Write-Host "[2/3] Attaching department and job title..." -ForegroundColor Cyan

$userMap = @{}
try {
    $userUri  = "https://graph.microsoft.com/v1.0/users?`$select=id,department,jobTitle&`$top=999"
    $userData = Get-GraphPaged -Uri $userUri -Activity 'Directory accounts'
    foreach ($u in $userData) { $userMap[$u.id] = $u }
    Write-Host "      $($userData.Count) directory accounts." -ForegroundColor DarkGray
}
catch {
    Write-Warning "Could not read directory accounts: $($_.Exception.Message.Trim())"
    Write-Warning "Department and Job Title will be blank."
    $script:FailureCount++
}

# ---------------------------------------------------------------------------
# STAGE 3 - legacy per-user MFA state, via $batch (20 per request)
# ---------------------------------------------------------------------------
$legacyState = @{}

if ($SkipLegacyStateLookup) {
    Write-Host "[3/3] Legacy per-user MFA state lookup SKIPPED by parameter." -ForegroundColor DarkYellow
    Write-Warning "The 'MFA Type' column will read 'Unknown' for every row."
}
else {
    Write-Host "[3/3] Checking which users are on legacy per-user MFA (batched)..." -ForegroundColor Cyan

    $ids       = @($regData | ForEach-Object { $_.id })   # force an array: .Prop on a
    $batchSize = 20                                        # 1-element list returns a scalar
    $done      = 0

    for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {

        $chunk = @($ids[$i..([math]::Min($i + $batchSize - 1, $ids.Count - 1))])

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
            Write-Warning "Batch starting at index $i failed: $($_.Exception.Message.Trim())"
            $script:FailureCount++
            continue
        }

        foreach ($r in $resp.responses) {
            $idx = [int]$r.id - 1
            $uid = $chunk[$idx]

            if ($r.status -eq 200) {
                $legacyState[$uid] = $r.body.perUserMfaState
            }
            else {
                # Every non-200 is partial data, not just 403. A 429 inside a batch
                # returns HTTP 200 on the envelope and would otherwise pass silently.
                $legacyState[$uid] = if ($r.status -eq 403) { "AccessDenied" } else { "Error:$($r.status)" }
                $script:FailureCount++
            }
        }

        $done += $chunk.Count
        Write-Progress -Activity "Legacy per-user MFA state" `
                       -Status "$done / $($ids.Count)" `
                       -PercentComplete (($done / $ids.Count) * 100) -Id 2
    }
    Write-Progress -Activity "Legacy per-user MFA state" -Id 2 -Completed

    $denied = @($legacyState.Values | Where-Object { $_ -eq 'AccessDenied' }).Count
    if ($denied -gt 0) {
        Write-Warning "$denied legacy state lookups were denied."
        Write-Warning "Reading per-user MFA state needs Policy.Read.All plus Global Reader or Authentication Policy Administrator."
    }
}

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
Write-Host "`nBuilding report..." -ForegroundColor Cyan

$Report = foreach ($r in $regData) {

    $split = Split-Methods -Methods @($r.methodsRegistered)
    $acct  = $userMap[$r.id]

    # Which default actually applies depends on whether system-preferred is on.
    $preferredRaw =
        if ($r.isSystemPreferredAuthenticationMethodEnabled -and $r.systemPreferredAuthenticationMethods) {
            @($r.systemPreferredAuthenticationMethods)[0]
        } else {
            $r.userPreferredMethodForSecondaryAuthentication
        }

    $preferred     = if ($preferredRaw -and $PreferredFriendly.ContainsKey($preferredRaw)) {
                         $PreferredFriendly[$preferredRaw]
                     } elseif ($preferredRaw) { $preferredRaw } else { 'Not set' }
    $defaultIsPhone = $preferredRaw -in $PhonePreferred

    $state = if ($SkipLegacyStateLookup)              { "NotChecked" }
             elseif ($legacyState.ContainsKey($r.id)) { $legacyState[$r.id] }
             else                                     { "NotRetrieved" }

    $legacyEnabled = $state -in @('enabled','enforced')

    # The requested column. "Legacy" means the account is still governed by the old
    # per-user MFA surface; "Modern" means it is governed by the Authentication
    # Methods Policy / Conditional Access instead.
    $mfaType = switch ($state) {
        'enabled'      { 'Legacy' }
        'enforced'     { 'Legacy' }
        'disabled'     { 'Modern' }
        'NotChecked'   { 'Unknown - not checked' }
        'AccessDenied' { 'Unknown - permission denied' }
        default        { 'Unknown - lookup failed' }
    }

    # Phone-only means blocked at sign-in after 1 Feb 2027. Unclassified methods count
    # as a possible fallback so nobody is wrongly marked safe or wrongly marked doomed.
    $phoneOnly = ($split.NonPhoneMfa.Count -eq 0 -and $split.Unclassified.Count -eq 0)

    # Only a mobile number can receive an SMS. Office and alternate-mobile numbers
    # are voice-call only, so a user holding just those is not an "SMS user" at all.
    $phoneCapability = if ($split.Phone -contains 'mobilePhone') { 'Text message or phone call' }
                       else                                      { 'Phone call only' }

    if ($split.Unclassified.Count -gt 0) {
        $script:UnclassifiedUsers += "$($r.userPrincipalName): $($split.Unclassified -join ', ')"
    }

    $priority =
        if     ($phoneOnly -and $r.isAdmin)        { '1 - Urgent' }
        elseif ($phoneOnly)                        { '2 - High' }
        elseif ($legacyEnabled -and $defaultIsPhone) { '3 - Medium' }
        elseif ($legacyEnabled)                    { '4 - Low' }
        else                                       { '5 - Monitor' }

    $action =
        if     ($phoneOnly -and $r.isAdmin) { 'Urgent: administrator with no backup method. Set up a passkey or security key now.' }
        elseif ($phoneOnly)                 { 'Set up Microsoft Authenticator or a passkey before 1 Feb 2027.' }
        elseif ($legacyEnabled)             { 'Move off legacy per-user MFA. A backup method is already in place.' }
        else                                { 'No action needed yet. Already has a non-phone method.' }

    $outcome =
        if ($phoneOnly) { 'BLOCKED - forced to set up a passkey before they can sign in' }
        else            { 'Can still sign in using their other method' }

    $row = [ordered]@{
        'Priority'                = $priority
        'Name'                    = $r.userDisplayName
        'Sign-in Name'            = $r.userPrincipalName
        'Department'              = $acct.department
        'Job Title'               = $acct.jobTitle
        'Administrator'           = if ($r.isAdmin) { 'Yes' } else { 'No' }
        'Account Type'            = if ($r.userType -eq 'guest') { 'Guest' } else { 'Staff' }
        'MFA Type'                = $mfaType
        'Phone Can Receive'       = $phoneCapability
        'Currently Signs In With' = $preferred
        'Has Non-Phone Backup'    = if ($phoneOnly) { 'No' } else { 'Yes' }
        'Backup Methods'          = ($split.NonPhoneMfa -join '; ')
        'After 1 Feb 2027'        = $outcome
        'Action Needed'           = $action
        'Data As Of'              = $r.lastUpdatedDateTime
    }

    if ($IncludeTechnicalColumns) {
        $row['_ObjectId']              = $r.id
        $row['_MethodsRegistered']     = (@($r.methodsRegistered) -join '; ')
        $row['_UnclassifiedMethods']   = ($split.Unclassified -join '; ')
        $row['_PerUserMfaState']       = $state
        $row['_PreferredMethodRaw']    = $preferredRaw
        $row['_SystemPreferredOn']     = $r.isSystemPreferredAuthenticationMethodEnabled
        $row['_IsMfaRegistered']       = $r.isMfaRegistered
        $row['_IsMfaCapable']          = $r.isMfaCapable
        $row['_RegisteredNotCapable']  = ($r.isMfaRegistered -eq $true -and $r.isMfaCapable -eq $false)
    }

    [PSCustomObject] $row
}

$Report = $Report | Sort-Object Priority, 'Name'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$blocked = @($Report | Where-Object { $_.'Has Non-Phone Backup' -eq 'No' })
$admins  = @($blocked | Where-Object { $_.Administrator -eq 'Yes' })
$legacy  = @($Report | Where-Object { $_.'MFA Type' -eq 'Legacy' })
$unknown = @($Report | Where-Object { $_.'MFA Type' -like 'Unknown*' })
$onPhone = @($Report | Where-Object { $_.'Currently Signs In With' -match 'Text message|Phone call' })

Write-Host "`n===== SUMMARY =====" -ForegroundColor Green
Write-Host ("  Users with a phone number registered      : {0}" -f $Report.Count)
Write-Host ("  Phone is their ONLY method                : {0}" -f $blocked.Count) -ForegroundColor Red
Write-Host ("    ...of which are administrators          : {0}" -f $admins.Count)  -ForegroundColor Red
Write-Host ("  On LEGACY per-user MFA                    : {0}" -f $legacy.Count)  -ForegroundColor Yellow
Write-Host ("  Sign in with SMS/voice by default         : {0}" -f $onPhone.Count)

if ($unknown.Count -gt 0) {
    Write-Host ("  MFA Type could not be determined          : {0}" -f $unknown.Count) -ForegroundColor DarkYellow
}

if ($script:UnclassifiedUsers.Count -gt 0) {
    Write-Warning "$($script:UnclassifiedUsers.Count) users have an unrecognised method name - the method vocabulary in this script needs updating."
    $script:UnclassifiedUsers | Select-Object -First 5 | ForEach-Object { Write-Warning "  $_" }
    $script:FailureCount++
}

Write-Host "`n  The $($blocked.Count) users with no backup method face a blocking" -ForegroundColor Red
Write-Host "  passkey registration prompt after 1 Feb 2027. No opt-out exists." -ForegroundColor Red

if ($Report.Count -gt 0) {
    $stale = ($Report | Select-Object -First 1).'Data As Of'
    Write-Host "`n  Source report last refreshed: $stale" -ForegroundColor DarkGray
    Write-Host "  Microsoft refreshes this data every ~36 hours." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$date = Get-Date -Format "yyyy-MM-dd"
$file = Join-Path $OutputPath "SMS-Voice-MFA-Users-$date.csv"
$Report | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
Write-Host "`nReport saved to: $file" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Exit status
# ---------------------------------------------------------------------------
# Partial data must be loud. A report built from denied or throttled calls looks
# complete and is wrong - exit non-zero so a scheduler or CI step fails rather
# than filing an incomplete snapshot as a successful run.
if ($script:FailureCount -gt 0) {
    Write-Warning "Completed with $($script:FailureCount) problem(s). Treat this report as INCOMPLETE."
    exit 1
}


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

2. DISABLED AND SOFT-DELETED ACCOUNTS ARE ABSENT.
   Microsoft excludes disabled and recently-deleted users from
   userRegistrationDetails at source. There is no parameter that can include them.
   If disabled accounts matter to your scope decision, they must be pulled from
   /users separately and cross-referenced by hand.

3. LEGACY SSPR AUTHENTICATION METHODS ARE NOT READABLE.
   The legacy SSPR blade settings (Entra ID > Users > Password reset >
   Authentication methods) have no documented Graph surface. If SSPR method
   configuration matters to your scope decision, capture it from the portal.

4. perUserMfaState IS BETA-ONLY.
   /beta/users/{id}/authentication/requirements has no v1.0 equivalent and is
   subject to change. There is no bulk endpoint - $batch at 20/request is the
   fastest supported approach. It runs only against users who already have a phone
   method, which is what keeps this tractable at scale.

5. SMS vs VOICE IS INFERRED, NOT STATED.
   methodsRegistered records that a phone NUMBER exists, not which channel is
   permitted. Only mobilePhone can receive SMS; office and alternate-mobile numbers
   are voice-only - that is the basis of the "Phone Can Receive" column.
   "Currently Signs In With" is exact, because the preferred-method enum does
   distinguish sms from voiceMobile/voiceOffice/voiceAlternateMobile.

6. "MFA TYPE" DESCRIBES GOVERNANCE, NOT THE METHOD.
   Legacy = the account is still carried in the per-user MFA surface
   (perUserMfaState enabled or enforced). Modern = perUserMfaState disabled, so the
   Authentication Methods Policy governs. A user can be Modern and still be on SMS.

7. REPORT DATA LAG.
   userRegistrationDetails refreshes roughly every 36 hours. Check "Data As Of"
   before treating any row as current.

8. LICENSING.
   The authentication methods activity report requires Entra ID P1 or above.
#>
