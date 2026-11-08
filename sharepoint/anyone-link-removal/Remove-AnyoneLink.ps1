<#
.SYNOPSIS
    Removes "Anyone" (anonymous) edit sharing-link permissions from SharePoint Online / OneDrive drive items via Microsoft Graph.

.DESCRIPTION
    Remove-AnyoneLink.ps1 reads a CSV produced by Get-AnyoneLinkInventory.ps1 (or a compatible filtered
    candidate list), re-checks each permission live against Microsoft Graph, and optionally deletes only
    those permissions that still match the exact allowlisted shape:

      * link.scope  = anonymous
      * link.type   = edit   (or roles contain "write")
      * inheritedFrom is absent / null  (inherited permissions cannot be deleted)
      * permission id still equals the CSV LinkId on that DriveId + ItemId

    SAFETY DEFAULTS (this script will NOT mutate a tenant unless you opt in):
      * Dry-run is the default. No DELETE is sent unless -Execute is passed AND ShouldProcess confirms
        (or -Confirm:$false is used with -Execute in a carefully controlled automation).
      * -WhatIf is honored (SupportsShouldProcess). Combining -WhatIf with -Execute still performs no DELETE.
      * -MockGraph never calls login.microsoftonline.com or graph.microsoft.com; it exercises logic locally.
      * Blind mutation retries are forbidden. DELETE is retried only on 429/503/504 with Retry-After,
        and only after a fresh GET still confirms the same allowlisted permission is present.
      * The inventory / read-only Entra app must NOT be reused. Use a dedicated write app (see README).

    Authentication is app-only (client credentials) with a CERTIFICATE, same pattern as the inventory tool.
    Application permission recommended for tenant-wide drive-item permission delete (least privileged per
    Microsoft Graph permission-delete docs): Files.ReadWrite.All
    (manifest ID 75359482-378d-4052-8f01-80520e7db3cd). Higher privileged Sites.ReadWrite.All is NOT
    requested by default. For a site-scoped pilot, Sites.Selected + per-site write is preferred.

    TENANT-AGNOSTIC / PUBLISH-SAFE CONTRACT:
      * Tenant/client IDs, certificates, input and output are parameters, never tenant-specific constants.
      * Examples use placeholders only. -NonInteractive fails missing/invalid input with exit2.

    Required values you omit as parameters are prompted for (with validation and where-to-find hints),
    unless -NonInteractive is set (then missing values fail immediately with exit code 2).

.PARAMETER TenantId
    Directory (tenant) ID GUID, or the tenant primary domain (contoso.onmicrosoft.com).

.PARAMETER ClientId
    Application (client) ID GUID of the DEDICATED removal app registration (not the read-only inventory app).

.PARAMETER CertificateThumbprint
    40-hex thumbprint of a cert with private key in the Windows store (CurrentUser then LocalMachine).

.PARAMETER CertificatePath
    Path to a .pfx containing the certificate and private key (any OS).

.PARAMETER CertificatePassword
    SecureString password for the .pfx. Prompted if omitted (Enter for none).

.PARAMETER InputCsv
    Path to a CSV with at least: LinkId, DriveId, ItemId, Scope, LinkType (or Roles). Compatible with
    anyone_links.csv from Get-AnyoneLinkInventory.ps1.

.PARAMETER OutputFolder
    Folder for logs, results, checkpoints. Default: .\AnyoneLinkRemoval_<yyyyMMdd>. Reuse to resume.

.PARAMETER MaxItems
    Process at most N candidate rows after filters (0 = all). Use for a pilot of a few links.

.PARAMETER RequireAnonymousEdit
    Default:$true. Only process Scope=anonymous and edit/write links. Turn off only for advanced tests.

.PARAMETER AllowedPermissionIds
    Allowlist of Microsoft Graph APPLICATION permission GUIDs expected in the access-token "roles" claim.
    Default: Files.ReadWrite.All (75359482-378d-4052-8f01-80520e7db3cd).
    Add Sites.Selected (883ea226-0bf2-4a8f-9f9d-92c9162a727d) for a site-scoped pilot app.
    The script FAILS if the token contains a denied high-privilege role (see -DeniedPermissionIds).

.PARAMETER DeniedPermissionIds
    Roles that must not appear on the token. Default includes Sites.FullControl.All and
    Sites.Manage.All application IDs.

.PARAMETER Execute
    Opt-in to perform DELETE calls after fresh validation. Without -Execute the script only plans
    (dry-run) and writes would_delete / skipped results.

.PARAMETER MockGraph
    Local simulation using mocks/permissions.json. No network, no tenant auth. For syntax and logic tests.

.PARAMETER MockPermissionsPath
    Override path to mock permissions JSON (default: <scriptDir>/mocks/permissions.json).

.PARAMETER ThrottleLimit
    Reserved compatibility parameter; the implementation is SEQUENTIAL, not parallel.

.PARAMETER MaxDeleteRetries
    Max DELETE retries on 429/503/504 only (default 1). Never retries a successful DELETE or a 4xx
    other than 429. Ambiguous mutation is verified before any retry.

.PARAMETER RequestTimeoutSeconds
    Per-request connection/operation timeout (default30). OS/HTTP stacks can exceed it;
    use an external process watchdog for a hard wall-clock bound. Never replay pending mutations.
.PARAMETER MaxRetryDelaySeconds
    Maximum accepted server backoff (default60); longer/invalid Retry-After stops instead
    of retrying earlier than the server permits. Supports seconds and HTTP-date values.
.PARAMETER MaxRunSeconds
    Cooperative run budget (default3600); checked between requests and waits, not an
    independent timer. In-flight OS calls need an external supervisor for hard cancellation.
.PARAMETER NonInteractive
    Never prompt. Missing/invalid required values fail with exit code 2.

.PARAMETER Help
    Show full help and exit.

.EXAMPLE
    .\Remove-AnyoneLink.ps1 -InputCsv .\candidates.csv -MockGraph
    Local dry-run against mock Graph payloads (no network).

.EXAMPLE
    .\Remove-AnyoneLink.ps1 -TenantId contoso.onmicrosoft.com -ClientId 00000000-0000-0000-0000-000000000000 `
        -CertificatePath ./removal.pfx -InputCsv .\candidates.csv -MaxItems 5
    Live dry-run (GET only) for five candidates. No DELETE.

.EXAMPLE
    .\Remove-AnyoneLink.ps1 ... -InputCsv .\pilot5.csv -MaxItems 5 -Execute -Confirm
    Live pilot deletion with interactive ShouldProcess confirmation per batch.

.EXAMPLE
    .\Remove-AnyoneLink.ps1 ... -NonInteractive -Execute -Confirm:$false
    Unattended deletion ONLY when every required parameter is present. Prefer a tiny -MaxItems pilot first.

.NOTES
    Name     : Remove-AnyoneLink.ps1
    Version  : 1.1.0-preview.1
    Date     : 2026-11-07
    License  : MIT
    Requires : PowerShell 7.4+. No Graph SDK modules required (raw REST).
    Validation: Offline mock tests only for this preview; validate in a test tenant before use.

    CHANGELOG
      1.1.0-preview.1  2026-11-07  Bounded/status-safe transport; no inner DELETE retry;
                                 verify ambiguous mutations before any retry; durable journal;
                                 incremental CSV/checkpoints, every-row progress/final counts;
                                 input hash binding, fail-closed auth/errors, strict edit shape.
      1.0.0          2026-11-05  Initial public dry-run/Execute tool and safety gates.

    SOURCES
      Microsoft Learn - Remove access (permission-delete):
        https://learn.microsoft.com/graph/api/permission-delete?view=graph-rest-1.0
        Retrieved/verified 2026-11-05: only non-inherited permissions; app least privileged
        Files.ReadWrite.All; higher Sites.ReadWrite.All.
      Microsoft Learn - permission resource:
        https://learn.microsoft.com/graph/api/resources/permission?view=graph-rest-1.0
      Microsoft Learn - sharingLink resource:
        https://learn.microsoft.com/graph/api/resources/sharinglink?view=graph-rest-1.0
      Microsoft Learn - Sites.Selected overview:
        https://learn.microsoft.com/graph/permissions-selected-overview
      Merill graphpermissions - Files.ReadWrite.All:
        https://graphpermissions.merill.net/permission/Files.ReadWrite.All
        App ID 75359482-378d-4052-8f01-80520e7db3cd (verified 2026-11-05).
      Sibling inventory tool patterns: M365_Tools/sharepoint/anyone-link-inventory + BEST_PRACTICES.md

.LINK
    README.md and docs/SAFETY_AND_PROGRESS.md in this folder; ../../BEST_PRACTICES.md.
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Path')]
param(
    [string]$TenantId,
    [string]$ClientId,
    [Parameter(ParameterSetName = 'Thumbprint')][string]$CertificateThumbprint,
    [Parameter(ParameterSetName = 'Path')][string]$CertificatePath,
    [Parameter(ParameterSetName = 'Path')][securestring]$CertificatePassword,
    [string]$InputCsv,
    [string]$OutputFolder = (Join-Path (Get-Location) "AnyoneLinkRemoval_$(Get-Date -Format yyyyMMdd)"),
    [ValidateRange(0, [int]::MaxValue)][int]$MaxItems = 0,
    [bool]$RequireAnonymousEdit = $true,
    # Microsoft Graph published application permission IDs, not tenant/app IDs.
    [string[]]$AllowedPermissionIds = @('75359482-378d-4052-8f01-80520e7db3cd'), # Files.ReadWrite.All
    [string[]]$DeniedPermissionIds = @(
        'a82116e5-55eb-4c41-a434-62fe8a61c773', # Sites.FullControl.All Application
        '0c0bf378-bf22-4481-8f81-9e89a9b4960a'  # Sites.Manage.All Application
    ),
    [switch]$Execute,
    [switch]$MockGraph,
    [string]$MockPermissionsPath,
    [ValidateRange(1, 4)][int]$ThrottleLimit = 2,
    [ValidateRange(0, 5)][int]$MaxDeleteRetries = 1,
    [ValidateRange(1, 120)][int]$RequestTimeoutSeconds = 30,
    [ValidateRange(0, 300)][int]$MaxRetryDelaySeconds = 60,
    [ValidateRange(1, 86400)][int]$MaxRunSeconds = 3600,
    [switch]$NonInteractive,
    [Alias('h', '?')][switch]$Help
)

# Never assume optional nested JSON or ErrorRecord properties exist.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-NoteProp($obj, [string]$Name) {
    if ($null -eq $obj) { return $null }
    $prop = $obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}


$ScriptVersion = '1.1.0-preview.1'
$ScriptDir = Split-Path -Parent $PSCommandPath

# Canonical denied application permission IDs (Microsoft Graph permissions reference, verified 2026-11-05)
$DeniedPermissionIds = @(
    'a82116e5-55eb-4c41-a434-62fe8a61c773', # Sites.FullControl.All Application
    '0c0bf378-bf22-4481-8f81-9e89a9b4960a'  # Sites.Manage.All Application
) + @($DeniedPermissionIds | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' }) | Select-Object -Unique

if ($Help) { Get-Help $PSCommandPath -Full; return }

$noParams = $PSBoundParameters.Count -eq 0
if ($noParams) {
    Write-Host @"

  =====================================================================
   Remove-AnyoneLink.ps1  v$ScriptVersion
   Removes Anyone (anonymous) EDIT sharing-link permissions via Graph.
  ---------------------------------------------------------------------
   SAFETY: dry-run by default. No DELETE unless -Execute (+ ShouldProcess).
   Do NOT reuse the read-only inventory app. Use a dedicated Entra app.
   Recommended app permission: Files.ReadWrite.All
     manifest ID 75359482-378d-4052-8f01-80520e7db3cd
   Pilot first: -MaxItems 5, dry-run, then -Execute on the same short list.
   Local logic test (no network):  -MockGraph -InputCsv .\mocks\sample_input.csv
   Full help:  Get-Help .\Remove-AnyoneLink.ps1 -Full   (or -Help)
  =====================================================================

"@ -ForegroundColor Cyan
}

$GuidRx = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$DomainRx = '^(?=.{4,253}$)([a-zA-Z0-9-]{1,63}\.)+[a-zA-Z]{2,63}$'
$ThumbRx = '^[0-9a-fA-F]{40}$'

function Fail-Input([string]$msg) {
    Write-Host "INPUT ERROR: $msg" -ForegroundColor Red
    Write-Host "Run with -Help for details." -ForegroundColor Yellow
    exit 2
}

function Get-Value([string]$Current, [string]$Name, [string]$Rx, [string]$Hint, [string]$FormatText) {
    if ($Current) {
        if ($Current -notmatch $Rx) { Fail-Input "-$Name '$Current' is not a valid $FormatText. $Hint" }
        return $Current
    }
    if ($NonInteractive) { Fail-Input "-$Name is required with -NonInteractive. $Hint" }
    for ($i = 1; $i -le 3; $i++) {
        Write-Host "$Name - $Hint" -ForegroundColor DarkGray
        $v = (Read-Host "Enter $Name ($FormatText)").Trim()
        if ($v -match $Rx) { return $v }
        Write-Host "  '$v' is not a valid $FormatText. Try again ($i/3)." -ForegroundColor Yellow
    }
    Fail-Input "No valid $Name after 3 attempts."
}

# ---------- Output folder + logging (always; needed for mock too) ----------
try {
    $OutputFolder = [IO.Path]::GetFullPath($OutputFolder)
    New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null
} catch { Fail-Input "Cannot create output folder '$OutputFolder': $($_.Exception.Message)" }

$doneFile = Join-Path $OutputFolder 'done.txt'
$logFile = Join-Path $OutputFolder ("run_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$resultCsv = Join-Path $OutputFolder 'removal_results.csv'
$planCsv = Join-Path $OutputFolder 'would_delete.csv'
$skipCsv = Join-Path $OutputFolder 'skipped.csv'
$progressFile = Join-Path $OutputFolder 'progress.txt'
$summaryFile = Join-Path $OutputFolder 'summary.json'
$journalFile = Join-Path $OutputFolder 'mutation_journal.jsonl'
$runId = [guid]::NewGuid().ToString()
$runStarted = [datetime]::UtcNow
$runDeadline = $runStarted.AddSeconds($MaxRunSeconds)


function Write-Log([string]$Msg, [string]$Level = 'INFO') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Msg
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; PLAN = 'Cyan' }[$Level]
    if (-not $color) { $color = 'Gray' }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $logFile -Value $line -WhatIf:$false } catch { }
}

Write-Log "Remove-AnyoneLink v$ScriptVersion starting. Execute=$Execute MockGraph=$MockGraph WhatIf=$WhatIfPreference"

# ---------- Input CSV ----------
if (-not $InputCsv) {
    if ($MockGraph) {
        $InputCsv = Join-Path $ScriptDir 'mocks/sample_input.csv'
    } elseif ($NonInteractive) {
        Fail-Input '-InputCsv is required with -NonInteractive.'
    } else {
        $InputCsv = (Read-Host 'Path to candidate CSV (inventory anyone_links.csv or filtered list)').Trim('"', "'", ' ')
    }
}
if (-not (Test-Path -LiteralPath $InputCsv -PathType Leaf)) { Fail-Input "Input CSV not found: $InputCsv" }

$requiredCols = @('LinkId', 'DriveId', 'ItemId')
$rows = @(Import-Csv -LiteralPath $InputCsv)
if ($rows.Count -eq 0) { Fail-Input "Input CSV is empty: $InputCsv" }
$cols = @($rows[0].PSObject.Properties.Name)
foreach ($c in $requiredCols) {
    if ($c -notin $cols) { Fail-Input "Input CSV missing required column '$c'. Expected inventory schema (see docs/IMPORT_SCHEMA.md)." }
}

function Test-IsAnonymousEdit($r) {
    $scope = [string](Get-NoteProp $r 'Scope')
    $type = [string](Get-NoteProp $r 'LinkType')
    $roles = [string](Get-NoteProp $r 'Roles')
    $anon = $scope -eq 'anonymous'
    $edit = ($type -eq 'edit') -or ($roles -match '(?i)\bwrite\b')
    return ($anon -and $edit)
}

# Reject ambiguous/blank targets rather than silently widening or repeating a cohort.
$inputKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($r in $rows) {
    foreach ($c in $requiredCols) { if ([string]::IsNullOrWhiteSpace([string]$r.$c)) { Fail-Input "Blank required target column '$c'." } }
    if (-not $inputKeys.Add(('{0}|{1}|{2}' -f $r.DriveId,$r.ItemId,$r.LinkId))) { Fail-Input 'Duplicate DriveId|ItemId|LinkId target.' }
}
$inputHash = (Get-FileHash -LiteralPath $InputCsv -Algorithm SHA256).Hash
$manifestFile = Join-Path $OutputFolder 'input_sha256.txt'
if (Test-Path $manifestFile) {
    if ((Get-Content $manifestFile -Raw).Trim() -ne $inputHash) { Fail-Input 'OutputFolder belongs to a different input hash; use a new folder.' }
} else { Set-Content -LiteralPath $manifestFile -Value $inputHash -WhatIf:$false }
$candidates = @($rows)
if ($RequireAnonymousEdit) {
    $candidates = @($candidates | Where-Object { Test-IsAnonymousEdit $_ })
}
# Resume: skip ids already in done.txt (format: DriveId|ItemId|LinkId)
$doneSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $doneFile) {
    Get-Content -LiteralPath $doneFile | ForEach-Object {
        $t = $_.Trim(); if ($t) { [void]$doneSet.Add($t) }
    }
}
$beforeResume = $candidates.Count
$candidates = @($candidates | Where-Object {
        $key = '{0}|{1}|{2}' -f $_.DriveId, $_.ItemId, $_.LinkId
        -not $doneSet.Contains($key)
    })
$resumedCount = $beforeResume - $candidates.Count
if ($MaxItems -gt 0 -and $candidates.Count -gt $MaxItems) {
    $candidates = @($candidates | Select-Object -First $MaxItems)
}
Write-Log ("Candidates after filter/resume/MaxItems: {0} (RequireAnonymousEdit={1})" -f $candidates.Count, $RequireAnonymousEdit)

if ($candidates.Count -eq 0) {
    Write-Log 'Nothing to process; zero pending targets (not a new deletion).' 'OK'
    @{RunId=$runId;Mode='NO_PENDING';Total=0;Processed=0;Remaining=0;ResumedCompleted=$resumedCount;EligibleChecked=0;WouldDelete=0;DeletedVerified=0;AlreadyAbsent=0;Skipped=0;Errors=0;Paused=$false;Completed=$true;UpdatedUtc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $summaryFile -WhatIf:$false
    exit 0
}

# ---------- Auth (skipped for MockGraph) ----------
$script:MockMap = $null
$script:DeletedMock = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$Cert = $null
if ($MockGraph) {
    if (-not $MockPermissionsPath) { $MockPermissionsPath = Join-Path $ScriptDir 'mocks/permissions.json' }
    if (-not (Test-Path -LiteralPath $MockPermissionsPath)) { Fail-Input "Mock permissions file not found: $MockPermissionsPath" }
    $script:MockMap = Get-Content -LiteralPath $MockPermissionsPath -Raw | ConvertFrom-Json
    Write-Log "MockGraph enabled. No tenant authentication. Permissions: $MockPermissionsPath" 'WARN'
} else {
    $TenantId = Get-Value $TenantId 'TenantId' "($GuidRx)|($DomainRx)" 'Entra admin center > Overview > Tenant ID, or <name>.onmicrosoft.com.' 'GUID or domain'
    $ClientId = Get-Value $ClientId 'ClientId' $GuidRx 'Entra admin center > App registrations > DEDICATED removal app > Application (client) ID.' 'GUID'

    if (-not $CertificateThumbprint -and -not $CertificatePath) {
        if ($NonInteractive) { Fail-Input 'Provide -CertificateThumbprint or -CertificatePath with -NonInteractive.' }
        $choice = if ($IsWindows) { Read-Host 'Certificate: [T]humbprint from Windows store or [P]fx file path? (T/P)' } else { 'P' }
        if ($choice -match '^[Tt]') {
            $CertificateThumbprint = Get-Value '' 'CertificateThumbprint' $ThumbRx 'certmgr > Personal > Thumbprint.' '40 hex characters'
        } else {
            $CertificatePath = (Read-Host 'Path to the .pfx file').Trim('"', "'", ' ')
        }
    }

    try {
        if ($CertificateThumbprint) {
            $CertificateThumbprint = $CertificateThumbprint -replace '[\s\u200e]', ''
            if ($CertificateThumbprint -notmatch $ThumbRx) { Fail-Input '-CertificateThumbprint must be 40 hex characters.' }
            if (-not $IsWindows) { Fail-Input '-CertificateThumbprint requires Windows. Use -CertificatePath.' }
            $Cert = Get-ChildItem "Cert:\CurrentUser\My\$CertificateThumbprint", "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $Cert) { Fail-Input "Certificate $CertificateThumbprint not found in store." }
        } else {
            if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) { Fail-Input "Certificate file not found: $CertificatePath" }
            if (-not $CertificatePassword) {
                if ($NonInteractive) { $CertificatePassword = [securestring]::new() }
                else { $CertificatePassword = Read-Host 'PFX password (Enter if none)' -AsSecureString }
            }
            $pw = [Net.NetworkCredential]::new('', $CertificatePassword).Password
            $Cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path -LiteralPath $CertificatePath).Path, $pw,
                [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
            $pw = $null
        }
        if (-not $Cert.HasPrivateKey) { Fail-Input 'Certificate has no private key.' }
        if ($Cert.NotAfter -lt (Get-Date)) { Fail-Input "Certificate expired on $($Cert.NotAfter)." }
    } catch [System.Security.Cryptography.CryptographicException] {
        Fail-Input "Cannot open certificate: $($_.Exception.Message)"
    }
}

# ---------- Graph helpers ----------
$S = [hashtable]::Synchronized(@{
        Token = $null; Exp = [datetime]::MinValue; Tenant = $TenantId; Client = $ClientId; Cert = $Cert
        Lock = [object]::new(); LastActivity = [datetime]::UtcNow
    })

function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function Get-GraphToken($S) {
    if ($MockGraph) { return 'mock-token' }
    if ($S.Token -and [datetime]::UtcNow -lt $S.Exp) { return $S.Token }
    [Threading.Monitor]::Enter($S.Lock)
    try {
        if ($S.Token -and [datetime]::UtcNow -lt $S.Exp) { return $S.Token }
        $aud = "https://login.microsoftonline.com/$($S.Tenant)/oauth2/v2.0/token"
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $h = ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes((@{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-B64Url $S.Cert.GetCertHash()) } | ConvertTo-Json -Compress)))
        $p = ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes((@{ aud = $aud; iss = $S.Client; sub = $S.Client; jti = [guid]::NewGuid().ToString(); nbf = $now; exp = $now + 600 } | ConvertTo-Json -Compress)))
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($S.Cert)
        $sig = ConvertTo-B64Url ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$h.$p"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
        try {
            $r = Invoke-RestMethod -Method POST -Uri $aud -ConnectionTimeoutSeconds 30 -OperationTimeoutSeconds 60 -Body @{
                client_id = $S.Client; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = "$h.$p.$sig"
            }
        } catch {
            throw "Token acquisition failed; check tenant/client/certificate/admin consent. Type=$($_.Exception.GetType().Name). Raw service response suppressed."
        }
        $S.Token = $r.access_token; $S.Exp = [datetime]::UtcNow.AddMinutes(45)
        Assert-TokenRoles $S.Token
        return $S.Token
    } finally { [Threading.Monitor]::Exit($S.Lock) }
}

function Assert-TokenRoles([string]$jwt) {
    # Decode payload (no signature verify here; TLS + token endpoint already authenticated the app).
    $parts = $jwt.Split('.')
    if ($parts.Count -lt 2) { throw 'Access token is not a JWT; cannot verify roles allowlist.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $roles = @()
    if ($json.PSObject.Properties.Name -contains 'roles' -and $json.roles) { $roles = @($json.roles) }
    Write-Log ("Token roles claim: {0}" -f ($(if ($roles) { $roles -join ', ' } else { '(none)' })))
    foreach ($d in $DeniedPermissionIds) {
        if ($roles -contains $d) { throw "Token contains DENIED application permission id $d. Refusing to continue." }
    }
    $allowedHit = $false
    foreach ($a in $AllowedPermissionIds) {
        # Allow either GUID in roles OR well-known role name strings Graph sometimes emits
        if ($roles -contains $a -or $roles -contains 'Files.ReadWrite.All' -or ($a -eq '75359482-378d-4052-8f01-80520e7db3cd' -and $roles -contains 'Files.ReadWrite.All')) {
            $allowedHit = $true
        }
        if ($roles -contains 'Sites.Selected' -and $AllowedPermissionIds -contains '883ea226-0bf2-4a8f-9f9d-92c9162a727d') { $allowedHit = $true }
        if ($roles -contains $a) { $allowedHit = $true }
    }
    # Graph app-only tokens typically carry role NAMES not GUIDs
    $nameMap = @{
        'Files.ReadWrite.All' = '75359482-378d-4052-8f01-80520e7db3cd'
        'Sites.ReadWrite.All' = '9492366f-7969-46a4-8d15-ed1a20078fff'
        'Sites.Selected'      = '883ea226-0bf2-4a8f-9f9d-92c9162a727d'
        'Sites.FullControl.All' = 'a82116e5-55eb-4c41-a434-62fe8a61c773'
        'Sites.Manage.All'    = '0c0bf378-bf22-4481-8f81-9e89a9b4960a'
    }
    foreach ($n in $roles) {
        if ($nameMap.ContainsKey($n) -and $DeniedPermissionIds -contains $nameMap[$n]) {
            throw "Token contains DENIED role '$n'. Refusing to continue."
        }
        if ($nameMap.ContainsKey($n) -and $AllowedPermissionIds -contains $nameMap[$n]) { $allowedHit = $true }
        if ($AllowedPermissionIds -contains $n) { $allowedHit = $true }
    }
    if (-not $allowedHit) {
        throw ("Token roles do not include any AllowedPermissionIds ({0}). Got: {1}" -f ($AllowedPermissionIds -join ', '), ($roles -join ', '))
    }
}

function Get-HttpFailureInfo($ErrorRecord) {
    # Inspect only documented status/header locations, never stringify request/auth bodies.
    $queue = [Collections.Generic.Queue[object]]::new()
    $seen = [Collections.Generic.HashSet[object]]::new()
    if ($null -ne $ErrorRecord) { $queue.Enqueue($ErrorRecord) }
    $status = 0; $retry = $null
    while ($queue.Count -gt 0 -and $seen.Count -lt 16) {
        $obj = $queue.Dequeue()
        if ($null -eq $obj -or -not $seen.Add($obj)) { continue }
        foreach ($name in @('StatusCode','ResponseStatusCode')) {
            $v = Get-NoteProp $obj $name
            if ($null -ne $v) { try { $status = [int]$v } catch {} }
        }
        $data = Get-NoteProp $obj 'Data'
        if ($data -and $data.Contains('StatusCode')) { $status = [int]$data['StatusCode'] }
        if ($data -and $data.Contains('RetryAfter')) { $retry = $data['RetryAfter'] }
        $headers = Get-NoteProp $obj 'Headers'
        if ($headers) {
            try { $v = @($headers['Retry-After']); if ($v.Count -and $v[0]) { $retry = [string]$v[0] } } catch {}
        }
        foreach ($name in @('Exception','InnerException','Response','TargetObject')) {
            $v = Get-NoteProp $obj $name
            if ($null -ne $v) { $queue.Enqueue($v) }
        }
    }
    return @{ StatusCode=$status; RetryAfter=$retry }
}
function Get-HttpStatusFromError($ErrorRecord) { return (Get-HttpFailureInfo $ErrorRecord).StatusCode }
function New-GraphFailure([int]$Status,[string]$RetryAfter,[string]$Kind) {
    $ex = [InvalidOperationException]::new("Graph $Kind HTTP $Status; paused/error, not success.")
    $ex.Data['StatusCode'] = $Status
    if ($RetryAfter) { $ex.Data['RetryAfter'] = $RetryAfter }
    return $ex
}
function Get-RetryDelay([string]$RetryAfter,[int]$Attempt) {
    if ($RetryAfter) {
        $seconds = 0
        if ([int]::TryParse($RetryAfter,[ref]$seconds)) { return [math]::Max(0,$seconds) }
        $date = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($RetryAfter,[ref]$date)) { return [math]::Max(0,[math]::Ceiling(($date-[DateTimeOffset]::UtcNow).TotalSeconds)) }
        throw (New-GraphFailure 429 '' 'invalid Retry-After')
    }
    return [math]::Min(30,[math]::Pow(2,$Attempt))
}
function Wait-GraphRetry([string]$RetryAfter,[int]$Attempt) {
    $seconds = Get-RetryDelay $RetryAfter $Attempt
    # Never shorten a server Retry-After to fit our budget: stop instead.
    if ($seconds -gt $MaxRetryDelaySeconds -or [datetime]::UtcNow.AddSeconds($seconds+$RequestTimeoutSeconds) -ge $runDeadline) {
        throw (New-GraphFailure 429 $RetryAfter 'retry budget exceeded')
    }
    Write-Log "Backing off ${seconds}s; next operation rechecks current state." 'WARN'
    Start-Sleep -Seconds $seconds
}
function Invoke-Graph {
    param([ValidateSet('GET','DELETE')][string]$Method,[Parameter(Mandatory)][string]$Uri,[int]$MaxRetry=2)
    if ($MockGraph) { throw 'Transport is unavailable under MockGraph.' }
    $attempt = 0
    while ($true) {
        if ([datetime]::UtcNow -ge $runDeadline) { throw (New-GraphFailure 0 '' 'run time budget exceeded') }
        $attempt++
        $token = Get-GraphToken $S
        $headers = @{ Authorization="Bearer $token"; 'User-Agent'="Remove-AnyoneLink/$ScriptVersion" }
        try {
            $resp = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers -SkipHttpErrorCheck `
                -ConnectionTimeoutSeconds $RequestTimeoutSeconds -OperationTimeoutSeconds $RequestTimeoutSeconds -ErrorAction Stop
        } catch {
            # DELETE has NO transport-layer retries. Only the caller may consider a new
            # mutation, after verifying absence/shape and applying the retry policy.
            $info = Get-HttpFailureInfo $_
            if ($Method -eq 'GET' -and $info.StatusCode -in @(429,503,504) -and $attempt -le $MaxRetry) {
                Wait-GraphRetry $info.RetryAfter $attempt; continue
            }
            throw
        }
        $S.LastActivity = [datetime]::UtcNow
        $status = [int]$resp.StatusCode; $retry = $null
        try { $retry = [string](@($resp.Headers['Retry-After'])[0]) } catch {}
        if ($Method -eq 'GET' -and $status -in @(429,503,504) -and $attempt -le $MaxRetry) {
            Wait-GraphRetry $retry $attempt; continue
        }
        if ($Method -eq 'GET') {
            if ($status -eq 404) { return $null }
            # Only explicit404 means absent. Empty/malformed200 is NOT absence.
            if ($status -ne 200 -or [string]::IsNullOrWhiteSpace([string]$resp.Content)) { throw (New-GraphFailure $status $retry 'GET') }
            return ($resp.Content | ConvertFrom-Json -ErrorAction Stop)
        }
        if ($status -in @(200,202,204,404)) { return [pscustomobject]@{StatusCode=$status} }
        throw (New-GraphFailure $status $retry 'DELETE')
    }
}

function Get-PermissionFresh([string]$DriveId, [string]$ItemId, [string]$LinkId) {
    if ($MockGraph) {
        if ($script:DeletedMock.Contains($LinkId)) { return $null }
        $node = Get-NoteProp $script:MockMap $LinkId
        if (-not $node) { return $null }
        # Reserved fixture fault, reachable ONLY under MockGraph; never live transport.
        $fault = Get-NoteProp $node '__mockGetStatus'
        if ($fault) { throw (New-GraphFailure ([int]$fault) '' 'offline fixture GET') }
        return $node
    }
    $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/permissions/$LinkId"
    # Invoke-Graph GET returns $null on 404 (permission already removed)
    return Invoke-Graph -Method GET -Uri $uri
}

function Test-PermissionAllowlisted($perm, [string]$ExpectedLinkId) {
    if (-not $perm) { return @{ Ok = $false; Reason = 'Permission not found (already removed or wrong id)' } }
    $liveId = [string](Get-NoteProp $perm 'id')
    if ($liveId -ne $ExpectedLinkId) { return @{ Ok = $false; Reason = "Permission id mismatch live='$liveId' expected='$ExpectedLinkId'" } }
    $inherited = Get-NoteProp $perm 'inheritedFrom'
    if ($null -ne $inherited) {
        return @{ Ok = $false; Reason = 'Permission is inherited; Graph refuses delete of inherited permissions' }
    }
    $link = Get-NoteProp $perm 'link'
    if ($null -eq $link) {
        return @{ Ok = $false; Reason = 'Not a link permission (no link facet)' }
    }
    $scope = [string](Get-NoteProp $link 'scope')
    if ($scope -ne 'anonymous') {
        return @{ Ok = $false; Reason = "Scope is '$scope', not anonymous" }
    }
    $linkType = [string](Get-NoteProp $link 'type')
    $isEdit = ($linkType -eq 'edit')
    $roles = Get-NoteProp $perm 'roles'
    # Fail closed: write role alone must not make a view/unknown link deletable.
    if (-not $isEdit) {
        return @{ Ok = $false; Reason = "Not an edit/write link (type='$linkType', roles=$($roles -join ';'))" }
    }
    return @{ Ok = $true; Reason = 'anonymous edit, not inherited, id matches' }
}

function Add-MutationJournal([string]$Key,[string]$Event,[int]$Status=0) {
    $entry = @{Key=$Key;Event=$Event;Status=$Status;Utc=[datetime]::UtcNow.ToString('o');RunId=$runId}
    $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $journalFile -WhatIf:$false -ErrorAction Stop
}
function Remove-PermissionSafe([string]$DriveId,[string]$ItemId,[string]$LinkId) {
    $key = "$DriveId|$ItemId|$LinkId"
    $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/permissions/$LinkId"
    $attempt = 0
    while ($true) {
        $attempt++
        $perm = Get-PermissionFresh $DriveId $ItemId $LinkId
        if ($null -eq $perm) { return @{StatusCode=404;Skipped=$false;AlreadyAbsent=$true} }
        $check = Test-PermissionAllowlisted $perm $LinkId
        if (-not $check.Ok) { return @{StatusCode=0;Skipped=$true;Reason="Pre-DELETE recheck failed: $($check.Reason)"} }
        # Durable ATTEMPT BEFORE mutation. A crash/timeout must never trigger blind replay.
        Add-MutationJournal $key 'ATTEMPT'
        try {
            if ($MockGraph) {
                [void]$script:DeletedMock.Add($LinkId); $del = [pscustomobject]@{StatusCode=204}
            } else { $del = Invoke-Graph -Method DELETE -Uri $uri -MaxRetry 0 }
            Add-MutationJournal $key 'RESPONSE' ([int]$del.StatusCode)
            return @{StatusCode=[int]$del.StatusCode;Skipped=$false;AlreadyAbsent=($del.StatusCode -eq 404)}
        } catch {
            $err = $_; $info = Get-HttpFailureInfo $err
            # Timeout/503/429 can follow a successful mutation: GET FIRST, even when
            # no retry will be permitted. A failed verification never authorizes retry.
            try { $after = Get-PermissionFresh $DriveId $ItemId $LinkId }
            catch { throw (New-GraphFailure $info.StatusCode $info.RetryAfter 'ambiguous DELETE; verification failed') }
            if ($null -eq $after) {
                return @{StatusCode=$info.StatusCode;Skipped=$false;AlreadyAbsent=$false;Recovered=$true}
            }
            if ($info.StatusCode -in @(429,503,504) -and $attempt -le $MaxDeleteRetries) {
                Wait-GraphRetry $info.RetryAfter $attempt
                continue # next iteration performs a fresh full allowlist check
            }
            throw $err # includes auth401/403 and ambiguous transport0: stop, no retry
        }
    }
}

# ---------- Incremental processing, durable checkpoints, truthful final counts ----------
$plan = [Collections.Generic.List[object]]::new()
$skipped = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$pendingMutations = [Collections.Generic.HashSet[string]]::new()
if (Test-Path $journalFile) {
    foreach ($line in Get-Content $journalFile) {
        $j = $line | ConvertFrom-Json -ErrorAction Stop
        if ($j.Event -eq 'ATTEMPT') { [void]$pendingMutations.Add($j.Key) }
        elseif ($j.Event -eq 'VERIFIED') { [void]$pendingMutations.Remove($j.Key) }
    }
}
$mode = if ($Execute -and -not $WhatIfPreference) { 'EXECUTE' } else { 'DRY-RUN' }
$processed=0; $failed=0; $paused=$false; $fatal=$null
function Save-Row($row) {
    $row | Export-Csv -LiteralPath $resultCsv -Append -NoTypeInformation -Encoding utf8 -WhatIf:$false -ErrorAction Stop
    $results.Add($row)
}
function Save-Progress {
    $summary = [ordered]@{
        RunId=$runId;Mode=$mode;InputSHA256=$inputHash;Total=$candidates.Count;Processed=$processed;Remaining=($candidates.Count-$processed)
        ResumedCompleted=$resumedCount;EligibleChecked=$plan.Count
        WouldDelete=@($results | Where-Object Action -eq 'WOULD_DELETE').Count
        DeletedVerified=@($results | Where-Object Action -eq 'DELETED').Count
        AlreadyAbsent=@($results | Where-Object Action -eq 'ALREADY_ABSENT').Count
        Skipped=@($results | Where-Object Action -eq 'SKIP').Count;Errors=$failed
        Paused=$paused;Completed=($processed -eq $candidates.Count -and -not $paused)
        UpdatedUtc=[datetime]::UtcNow.ToString('o');StartedUtc=$runStarted.ToString('o')
    }
    $summary | ConvertTo-Json | Set-Content ($summaryFile+'.tmp') -WhatIf:$false -ErrorAction Stop
    Move-Item ($summaryFile+'.tmp') $summaryFile -Force -WhatIf:$false -ErrorAction Stop
    $line = "Processed=$processed/$($candidates.Count) DeletedVerified=$($summary.DeletedVerified) AlreadyAbsent=$($summary.AlreadyAbsent) WouldDelete=$($summary.WouldDelete) Skipped=$($summary.Skipped) Errors=$failed Remaining=$($summary.Remaining)"
    Add-Content $progressFile -Value ($summary.UpdatedUtc+' '+$line) -WhatIf:$false -ErrorAction Stop
    Write-Progress -Activity "Sharing permission $mode (sequential)" -Status $line -PercentComplete $(if($candidates.Count){100*$processed/$candidates.Count}else{100})
    Write-Log $line
}
try {
    if (-not $MockGraph) { $null=Get-GraphToken $S }
    Write-Log "Mode=$mode; requests sequential (ThrottleLimit is reserved, not active parallelism). No DELETE in dry-run/WhatIf."
    Save-Progress
    foreach ($r in $candidates) {
        if ([datetime]::UtcNow -ge $runDeadline) { $paused=$true; $failed++; break }
        $driveId=[string]$r.DriveId; $itemId=[string]$r.ItemId; $linkId=[string]$r.LinkId
        $key="$driveId|$itemId|$linkId"
        Write-Log "[$($processed+1)/$($candidates.Count)] GET exact permission $linkId; checking current shape."
        $row=[pscustomobject]@{RunId=$runId;LinkId=$linkId;DriveId=$driveId;ItemId=$itemId;Action='';Status='';Detail='';VerifiedGone=''}
        try {
            $perm=Get-PermissionFresh $driveId $itemId $linkId
            if ($null -eq $perm) {
                $row.Action='ALREADY_ABSENT';$row.Status=404;$row.Detail='Exact permission404, no DELETE required';$row.VerifiedGone=$true
                if ($mode -eq 'EXECUTE') {
                    Add-Content $doneFile $key -WhatIf:$false -ErrorAction Stop
                    if($pendingMutations.Contains($key)){Add-MutationJournal $key 'VERIFIED' 404}
                }
                Save-Row $row;continue
            }
            if($pendingMutations.Contains($key)) { throw (New-GraphFailure 0 '' 'unresolved previous mutation: permission still present; operator review required') }
            $check=Test-PermissionAllowlisted $perm $linkId
            if(-not $check.Ok){
                $row.Action='SKIP';$row.Detail=$check.Reason
                $row | Select-Object LinkId,DriveId,ItemId,Action,@{n='Reason';e={$_.Detail}} | Export-Csv $skipCsv -Append -NoTypeInformation -WhatIf:$false -ErrorAction Stop
                $skipped.Add($row);Save-Row $row;continue
            }
            $linkObj=Get-NoteProp $perm 'link'
            $planRow=[pscustomobject]@{LinkId=$linkId;DriveId=$driveId;ItemId=$itemId;Action='WOULD_DELETE';Reason=$check.Reason;LinkType=(Get-NoteProp $linkObj 'type');Scope=(Get-NoteProp $linkObj 'scope');ItemName=(Get-NoteProp $r 'ItemName');SiteUrl=(Get-NoteProp $r 'SiteUrl');LinkUrl=(Get-NoteProp $linkObj 'webUrl')}
            $plan.Add($planRow);$planRow | Export-Csv $planCsv -Append -NoTypeInformation -Encoding utf8 -WhatIf:$false -ErrorAction Stop
            # Approval semantics unchanged: explicit Execute AND ShouldProcess; WhatIf never mutates.
            if(-not ($Execute -and -not $WhatIfPreference -and $PSCmdlet.ShouldProcess("permission $linkId on drive/item $driveId/$itemId",'DELETE Anyone edit sharing permission'))){
                $row.Action='WOULD_DELETE';$row.Status='dry-run';$row.Detail=$check.Reason;Save-Row $row;continue
            }
            $del=Remove-PermissionSafe $driveId $itemId $linkId
            if($del.Skipped){$row.Action='SKIP';$row.Detail=$del.Reason;Save-Row $row;continue}
            # Explicit404 only. Never infer successful removal from empty200/transport error.
            $after=Get-PermissionFresh $driveId $itemId $linkId
            if($null -ne $after){throw (New-GraphFailure 0 '' 'DELETE response received but permission still present')}
            $row.Action=if($del.AlreadyAbsent){'ALREADY_ABSENT'}else{'DELETED'}
            $row.Status=$del.StatusCode;$row.Detail='Exact GET verification returned404';$row.VerifiedGone=$true
            Add-MutationJournal $key 'VERIFIED' 404
            # Checkpoint only confirmed terminal state; changed/inherited/error are never done.
            Add-Content $doneFile $key -WhatIf:$false -ErrorAction Stop
            Save-Row $row
            Write-Log "$($row.Action) $linkId; HTTP=$($row.Status), verified absent404." 'OK'
        } catch {
            $status=Get-HttpStatusFromError $_
            $failed++;$paused=$true
            $row.Action='ERROR';$row.Status=$status
            $row.Detail=if($status -in @(401,403)){'Authorization failure: stop; do not add privileges automatically'}else{'Request/mutation/checkpoint failure: stop; inspect journal before any retry'}
            # Deliberately omit raw exception/body/token/URL strings from logs.
            Save-Row $row;Write-Log "$($row.Detail) HTTP=$status Type=$($_.Exception.GetType().Name)" 'ERROR'
        } finally {
            $processed++;Save-Progress # runs even on continue/skip/error: no silent dry-run stall
        }
        if($paused){break}
    }
} catch {
    $failed++;$paused=$true;$fatal=$_.Exception.GetType().Name
    Write-Log "Fatal initialization/persistence failure Type=$fatal; stopped. No success inferred." 'ERROR'
} finally {
    Save-Progress
    Write-Progress -Activity "Sharing permission $mode (sequential)" -Completed
    $label=if($paused){'PAUSED/INCOMPLETE'}else{'FINISHED'}
    Write-Log "$label mode=$mode; inspect summary.json, incremental CSVs, done.txt and mutation_journal.jsonl. No further batch is authorized by this result." $(if($failed){'ERROR'}else{'OK'})
}
if($failed -gt 0 -or $paused){exit 1}
exit 0
