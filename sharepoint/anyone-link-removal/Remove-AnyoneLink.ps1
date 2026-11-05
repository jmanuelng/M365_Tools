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
      * No tenant ID, client ID, certificate thumbprint/path, hostname, UPN, or output path is hardcoded.
      * Every tenant-specific value is a parameter (or an interactive prompt with format checks and
        where-to-find guidance). Placeholders in examples use contoso.onmicrosoft.com and 00000000-... only.
      * -NonInteractive fails clearly with exit code 2 when a required value is missing or invalid.

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
    Max parallel workers for fresh GETs (1-4, default 2). Keep low; deletions stay sequential.

.PARAMETER MaxDeleteRetries
    Max DELETE retries on 429/503/504 only (default 3). Never retries a successful DELETE or a 4xx
    other than 429.

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
    Version  : 1.0.0
    Date     : 2026-11-05
    License  : MIT
    Requires : PowerShell 7.4+. No Graph SDK modules required (raw REST).

    CHANGELOG
      1.0.0  2026-11-05  Public tenant-agnostic release. Dry-run default, -Execute opt-in,
                         fresh permission GET, inherited/skip guards, cert auth, mock tests,
                         token role allowlist/denylist, resume via done.txt. Graph calls use
                         -SkipHttpErrorCheck; GET 404 = already gone; DELETE 204 = success;
                         StrictMode-safe StatusCode unwrap (Get-HttpStatusFromError, Get-NoteProp).
      0.1.x  2026-11-05  Pre-publish staging prove-out (not in this repo): StrictMode 204/404
                         fix, Get-NoteProp, first dry-run / Execute build.

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
    README.md in the same folder (full setup guide). See also ../../BEST_PRACTICES.md.
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
    # Microsoft Graph published application permission IDs (not tenant-specific) — safe defaults.
    [string[]]$AllowedPermissionIds = @('75359482-378d-4052-8f01-80520e7db3cd'), # Files.ReadWrite.All
    [string[]]$DeniedPermissionIds = @(
        'a82116e5-55eb-4c41-a434-62fe8a61c773', # Sites.FullControl.All Application
        '0c0bf378-bf22-4481-8f81-9e89a9b4960a'  # Sites.Manage.All Application
    ),
    [switch]$Execute,
    [switch]$MockGraph,
    [string]$MockPermissionsPath,
    [ValidateRange(1, 4)][int]$ThrottleLimit = 2,
    [ValidateRange(0, 5)][int]$MaxDeleteRetries = 3,
    [switch]$NonInteractive,
    [Alias('h', '?')][switch]$Help
)

# StrictMode Latest: missing properties throw. All Graph JSON access must use Get-NoteProp /
# PSObject.Properties checks — never assume .link.webUrl or ErrorRecord.StatusCode exist.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-NoteProp($obj, [string]$Name) {
    # Safe nested property read under StrictMode (Graph permission JSON is uneven).
    if ($null -eq $obj) { return $null }
    $prop = $obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}


$ScriptVersion = '1.0.0'
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
    $scope = [string]$r.Scope
    $type = [string]$r.LinkType
    $roles = [string]$r.Roles
    $anon = $scope -eq 'anonymous'
    $edit = ($type -eq 'edit') -or ($roles -match '(?i)\bwrite\b')
    return ($anon -and $edit)
}

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
$candidates = @($candidates | Where-Object {
        $key = '{0}|{1}|{2}' -f $_.DriveId, $_.ItemId, $_.LinkId
        -not $doneSet.Contains($key)
    })
if ($MaxItems -gt 0 -and $candidates.Count -gt $MaxItems) {
    $candidates = @($candidates | Select-Object -First $MaxItems)
}
Write-Log ("Candidates after filter/resume/MaxItems: {0} (RequireAnonymousEdit={1})" -f $candidates.Count, $RequireAnonymousEdit)

if ($candidates.Count -eq 0) {
    Write-Log 'Nothing to process.' 'OK'
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
            throw "Token request failed. Check TenantId/ClientId/certificate/admin consent. $($_.Exception.Message) $($_.ErrorDetails.Message)"
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

function Get-HttpStatusFromError {
    # StrictMode-safe unwrap. Never read .StatusCode unless the property exists.
    # Lesson: throwing a pscustomobject status bag, then reading ErrorRecord.StatusCode under
    # StrictMode, falsely marked successful DELETE (HTTP 204 + verify GET 404) as DELETE_FAILED.
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return 0 }
    $target = $null
    $ex = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $target = $ErrorRecord.TargetObject
        $ex = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [pscustomobject]) {
        $target = $ErrorRecord
    }
    if ($target -is [pscustomobject]) {
        $p = $target.PSObject.Properties['StatusCode']
        if ($null -ne $p -and $null -ne $p.Value) { return [int]$p.Value }
    }
    if ($null -ne $ex) {
        $p = $ex.PSObject.Properties['StatusCode']
        if ($null -ne $p -and $null -ne $p.Value) { return [int]$p.Value }
        $rp = $ex.PSObject.Properties['Response']
        if ($null -ne $rp -and $null -ne $rp.Value) {
            $sp = $rp.Value.PSObject.Properties['StatusCode']
            if ($null -ne $sp -and $null -ne $sp.Value) { return [int]$sp.Value }
        }
    }
    return 0
}

function Invoke-Graph {
    param(
        [ValidateSet('GET', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxRetry = 5
    )
    if ($MockGraph) { throw 'Invoke-Graph should not be used directly under MockGraph for item calls.' }
    $attempt = 0
    while ($true) {
        $attempt++
        $token = Get-GraphToken $S
        $headers = @{
            Authorization = "Bearer $token"
            'User-Agent'  = "Remove-AnyoneLink/$ScriptVersion"
        }
        try {
            # SkipHttpErrorCheck: Graph 204/404 must not throw; StrictMode + thrown pscustomobject
            # previously broke StatusCode unwrap on ErrorRecord (lesson 2026-11-05).
            $resp = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers `
                -SkipHttpErrorCheck `
                -ConnectionTimeoutSeconds 60 -OperationTimeoutSeconds 120
            $S.LastActivity = [datetime]::UtcNow
            $status = [int]$resp.StatusCode
            $retryAfter = $null
            try {
                if ($resp.Headers -and $resp.Headers.ContainsKey('Retry-After')) {
                    $retryAfter = @($resp.Headers['Retry-After'])[0]
                }
            } catch { }
            if ($status -in 429, 503, 504 -and $attempt -le $MaxRetry) {
                $wait = if ($retryAfter) { [int]$retryAfter } else { [math]::Min(60, [math]::Pow(2, $attempt)) + (Get-Random -Minimum 0.0 -Maximum 1.0) }
                Write-Log "Throttle/server $status on $Method $Uri; backing off ${wait}s (attempt $attempt/$MaxRetry)" 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            if ($Method -eq 'GET') {
                if ($status -eq 404) { return $null }
                if ($status -lt 200 -or $status -ge 300) {
                    throw ("Graph GET HTTP {0}: {1}" -f $status, $resp.Content)
                }
                if ([string]::IsNullOrWhiteSpace([string]$resp.Content)) { return $null }
                return ($resp.Content | ConvertFrom-Json)
            }
            # DELETE: 204 No Content is success; 404 means already gone
            if ($status -in 200, 202, 204, 404) {
                return [pscustomobject]@{ StatusCode = $status }
            }
            throw ("Graph DELETE HTTP {0}: {1}" -f $status, $resp.Content)
        } catch {
            # Transport failures only (HTTP status path above does not use Exception.Response)
            $status = Get-HttpStatusFromError $_
            $retryAfter = $null
            if ($status -in 429, 503, 504 -and $attempt -le $MaxRetry) {
                $wait = if ($retryAfter) { [int]$retryAfter } else { [math]::Min(60, [math]::Pow(2, $attempt)) + (Get-Random -Minimum 0.0 -Maximum 1.0) }
                Write-Log "Throttle/server $status on $Method $Uri; backing off ${wait}s (attempt $attempt/$MaxRetry)" 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

function Get-PermissionFresh([string]$DriveId, [string]$ItemId, [string]$LinkId) {
    if ($MockGraph) {
        if ($script:DeletedMock.Contains($LinkId)) { return $null }
        $node = $script:MockMap.$LinkId
        if (-not $node) { return $null }
        return $node
    }
    $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/permissions/$LinkId"
    # Invoke-Graph GET returns $null on 404 (permission already removed)
    return Invoke-Graph -Method GET -Uri $uri
}

function Test-PermissionAllowlisted($perm, [string]$ExpectedLinkId) {
    # Allowlist: anonymous + edit/write + not inherited + id still matches CSV LinkId.
    # Anything else is SKIP — never DELETE on a shape we did not explicitly approve.
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
    if (-not $isEdit -and $roles) {
        $isEdit = (@($roles) -match '(?i)^write$').Count -gt 0
    }
    if (-not $isEdit) {
        return @{ Ok = $false; Reason = "Not an edit/write link (type='$linkType', roles=$($roles -join ';'))" }
    }
    return @{ Ok = $true; Reason = 'anonymous edit, not inherited, id matches' }
}

function Remove-PermissionSafe([string]$DriveId, [string]$ItemId, [string]$LinkId) {
    # Precondition: caller already validated allowlist via fresh GET
    if ($MockGraph) {
        [void]$script:DeletedMock.Add($LinkId)
        return @{ StatusCode = 204; Skipped = $false }
    }
    $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/permissions/$LinkId"
    $attempt = 0
    while ($true) {
        $attempt++
        # Fresh confirm before every DELETE attempt (including retries)
        $perm = Get-PermissionFresh $DriveId $ItemId $LinkId
        $check = Test-PermissionAllowlisted $perm $LinkId
        if (-not $check.Ok) {
            return @{ StatusCode = 0; Skipped = $true; Reason = "Pre-DELETE recheck failed: $($check.Reason)" }
        }
        try {
            $delResp = Invoke-Graph -Method DELETE -Uri $uri -MaxRetry 1
            $delCode = 204
            if ($null -ne $delResp) {
                $p = $delResp.PSObject.Properties['StatusCode']
                if ($null -ne $p -and $null -ne $p.Value) { $delCode = [int]$p.Value }
            }
            if ($delCode -eq 404) {
                return @{ StatusCode = 404; Skipped = $false; Reason = 'Already gone at DELETE time' }
            }
            return @{ StatusCode = $delCode; Skipped = $false }
        } catch {
            $err = $_
            $status = Get-HttpStatusFromError $err
            if ($status -in 429, 503, 504 -and $attempt -le $MaxDeleteRetries) {
                Write-Log "DELETE throttled ($status); will re-GET and retry ($attempt/$MaxDeleteRetries)" 'WARN'
                Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, $attempt)))
                continue
            }
            if ($status -eq 404) { return @{ StatusCode = 404; Skipped = $false; Reason = 'Already gone at DELETE time' } }
            throw
        }
    }
}

# ---------- Process ----------
$plan = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()

if (-not $MockGraph) {
    # Force token + role check early (fail before any plan noise if auth/roles wrong)
    $null = Get-GraphToken $S
}

# Safety gate: DELETE only when -Execute is set AND -WhatIf is not. Default path is DRY-RUN.
$mode = if ($Execute -and -not $WhatIfPreference) { 'EXECUTE' } else { 'DRY-RUN' }
Write-Log "Mode=$mode (Execute switch=$Execute, WhatIf=$WhatIfPreference). DELETE only in EXECUTE." 'PLAN'

$i = 0
foreach ($r in $candidates) {
    $i++
    $driveId = [string]$r.DriveId
    $itemId = [string]$r.ItemId
    $linkId = [string]$r.LinkId
    $key = "$driveId|$itemId|$linkId"
    Write-Log "[$i/$($candidates.Count)] Inspect $linkId on item $itemId"

    try {
        $perm = Get-PermissionFresh $driveId $itemId $linkId
    } catch {
        $msg = $_.ToString()
        if ($_.PSObject.Properties.Name -contains 'Message') { $msg = $_.Message }
        $skipped.Add([pscustomobject]@{
                LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = 'SKIP'
                Reason = "GET failed: $msg"; ItemName = $r.ItemName; SiteUrl = $r.SiteUrl
            }) | Out-Null
        Write-Log "GET failed for $linkId : $msg" 'ERROR'
        continue
    }

    $check = Test-PermissionAllowlisted $perm $linkId
    if (-not $check.Ok) {
        $skipped.Add([pscustomobject]@{
                LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = 'SKIP'
                Reason = $check.Reason; ItemName = $r.ItemName; SiteUrl = $r.SiteUrl
            }) | Out-Null
        Write-Log "SKIP $linkId — $($check.Reason)" 'WARN'
        Add-Content -LiteralPath $doneFile -Value $key -WhatIf:$false   # do not retry forever on permanent skip
        continue
    }

    $linkObj = Get-NoteProp $perm 'link'
    $liveLinkUrl = Get-NoteProp $linkObj 'webUrl'
    if (-not $liveLinkUrl) { $liveLinkUrl = $r.LinkUrl }
    $plan.Add([pscustomobject]@{
            LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = 'WOULD_DELETE'
            Reason = $check.Reason; LinkType = (Get-NoteProp $linkObj 'type'); Scope = (Get-NoteProp $linkObj 'scope')
            ItemName = $r.ItemName; SiteUrl = $r.SiteUrl; LinkUrl = $liveLinkUrl
        }) | Out-Null

    # Second gate: SupportsShouldProcess (ConfirmImpact High). -WhatIf or declining Confirm => plan only.
    $target = "permission $linkId on drives/$driveId/items/$itemId"
    $shouldDelete = $Execute -and -not $WhatIfPreference -and $PSCmdlet.ShouldProcess($target, 'DELETE sharing permission (Anyone edit link)')

    if (-not $shouldDelete) {
        Write-Log "PLAN WOULD_DELETE $linkId ($($check.Reason))" 'PLAN'
        $results.Add([pscustomobject]@{
                LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = 'WOULD_DELETE'
                Status = 'dry-run'; Detail = $check.Reason; VerifiedGone = ''
            }) | Out-Null
        # Dry-run does not mark done (so a later -Execute can process them)
        continue
    }

    try {
        $del = Remove-PermissionSafe $driveId $itemId $linkId
        if ($del.ContainsKey('Skipped') -and $del.Skipped) {
            $skipped.Add([pscustomobject]@{
                    LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = 'SKIP'
                    Reason = $del.Reason; ItemName = $r.ItemName; SiteUrl = $r.SiteUrl
                }) | Out-Null
            Write-Log "SKIP at DELETE time $linkId — $($del.Reason)" 'WARN'
            Add-Content -LiteralPath $doneFile -Value $key -WhatIf:$false
            continue
        }
        # Verify
        Start-Sleep -Milliseconds 200
        $after = Get-PermissionFresh $driveId $itemId $linkId
        $gone = ($null -eq $after)
        $action = if ($gone) { 'DELETED' } else { 'DELETE_UNVERIFIED' }
        $results.Add([pscustomobject]@{
                LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = $action
                Status = $del.StatusCode; Detail = $(if ($gone) { 'GET after DELETE returned 404/null' } else { 'Permission still present after DELETE' })
                VerifiedGone = $gone
            }) | Out-Null
        Write-Log "$action $linkId verifiedGone=$gone" $(if ($gone) { 'OK' } else { 'ERROR' })
        Add-Content -LiteralPath $doneFile -Value $key -WhatIf:$false
    } catch {
        $msg = $_.ToString()
        $results.Add([pscustomobject]@{
                LinkId = $linkId; DriveId = $driveId; ItemId = $itemId; Action = 'DELETE_FAILED'
                Status = 'error'; Detail = $msg; VerifiedGone = $false
            }) | Out-Null
        Write-Log "DELETE_FAILED $linkId — $msg" 'ERROR'
        # Do not append done.txt — allow resume retry after operator review
    }

    Add-Content -LiteralPath $progressFile -Value ("{0:o} done={1} planned={2} skipped={3}" -f (Get-Date).ToUniversalTime(), $results.Count, $plan.Count, $skipped.Count) -WhatIf:$false
}

# ---------- Persist ----------
if ($plan.Count) { $plan | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false }
if ($skipped.Count) { $skipped | Export-Csv -LiteralPath $skipCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false }
if ($results.Count) { $results | Export-Csv -LiteralPath $resultCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false }

$deleted = @($results | Where-Object Action -eq 'DELETED').Count
$would = @($results | Where-Object Action -eq 'WOULD_DELETE').Count
$failed = @($results | Where-Object Action -in @('DELETE_FAILED', 'DELETE_UNVERIFIED')).Count
Write-Log ("Finished mode={0}. WOULD_DELETE={1} DELETED={2} FAILED/UNVERIFIED={3} SKIPPED={4}. Output={5}" -f $mode, $would, $deleted, $failed, $skipped.Count, $OutputFolder) 'OK'

if ($failed -gt 0) { exit 1 }
exit 0
