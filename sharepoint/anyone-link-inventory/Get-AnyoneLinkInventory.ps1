<#
.SYNOPSIS
    Read-only inventory of every "Anyone" (anonymous) sharing link in SharePoint Online and OneDrive for Business.

.DESCRIPTION
    Get-AnyoneLinkInventory.ps1 enumerates every site and document library (drive) in a Microsoft 365 tenant
    through Microsoft Graph, finds every item that has its own (unique) sharing, reads its permissions, and
    writes one CSV row per sharing link. By default only "Anyone" (anonymous) links are reported; use
    -IncludeAllScopes to also report "organization" and "users" (specific people) links.

    THE SCRIPT IS READ-ONLY. It only sends:
      * POST to the Microsoft identity platform token endpoint (to get an app-only access token), and
      * GET requests to Microsoft Graph, some grouped inside POST /$batch calls whose sub-requests are all GET.
    It never creates, changes or deletes a link, file, site or setting.

    Authentication is app-only (client credentials) with a CERTIFICATE. You need an Entra ID app registration
    with the Microsoft Graph APPLICATION permission Sites.Read.All and admin consent. See README.md for a
    complete, step-by-step setup from zero.

    Any required value you do not pass as a parameter is prompted for interactively, with format validation
    and a hint on where to find it. Use -NonInteractive in automation: missing values then fail immediately
    with a clear error instead of prompting.

    How it is fast and safe on large tenants:
      * Delta enumeration with the documented "Prefer: hierarchicalsharing" header, so only the roots of
        unique permission hierarchies carry the "shared" facet. Items that merely inherit site sharing are not
        queried one by one (this cut a 36,000-item library from hours to minutes in testing).
      * Permission reads grouped in JSON $batch calls of 20 requests.
      * Several drives processed in parallel (-ThrottleLimit), smallest drives first.
      * Retry with exponential backoff and jitter, honoring Retry-After on 429/503/504, also inside $batch.
      * Hard per-call timeouts (connect + read), automatic token refresh.
      * Checkpoints: finished drives are recorded, and inside a drive progress is saved every batch, so a
        rerun with the same -OutputFolder resumes where it stopped (even mid-drive).
      * Heartbeat file (progress.txt) updated continuously, and a no-activity watchdog that stops the run
        cleanly if nothing happens for -NoActivityTimeoutMinutes (default 120).

.PARAMETER TenantId
    Directory (tenant) ID as a GUID, or the tenant's primary domain (for example contoso.onmicrosoft.com).
    Find it in the Entra admin center > Overview > Tenant ID.

.PARAMETER ClientId
    Application (client) ID (GUID) of your app registration.
    Find it in Entra admin center > App registrations > your app > Overview.

.PARAMETER CertificateThumbprint
    Thumbprint (40 hex characters) of a certificate with private key in the Windows certificate store
    (Cert:\CurrentUser\My, then Cert:\LocalMachine\My). Windows only. Use this OR -CertificatePath.

.PARAMETER CertificatePath
    Path to a .pfx file containing the certificate and its private key. Works on Windows, macOS and Linux.

.PARAMETER CertificatePassword
    Password of the .pfx file as a SecureString. Prompted for if -CertificatePath is used and it is omitted
    (press Enter for a pfx without password).

.PARAMETER OutputFolder
    Folder for all output. Default: .\AnyoneLinkInventory_<yyyyMMdd>. Reuse the same folder to resume.

.PARAMETER IncludeAllScopes
    Also report "organization" and "users" scoped links, not only "anonymous" (Anyone) links.

.PARAMETER SiteUrlFilter
    Regular expression; only drives whose URL matches are scanned. Useful for a test on one site.

.PARAMETER MaxDrives
    Scan at most this many pending drives (0 = all). Useful for a first test.

.PARAMETER ThrottleLimit
    Drives processed in parallel (1-8, default 4). Lower it if you see many 429 responses.

.PARAMETER NoActivityTimeoutMinutes
    Stop the run if no Graph call has completed for this many minutes (default 120). Rerun to resume.

.PARAMETER NonInteractive
    Never prompt. Missing or invalid required values cause an immediate, explicit error (exit code 2).

.PARAMETER Help
    Show the full help and exit.

.EXAMPLE
    .\Get-AnyoneLinkInventory.ps1
    No parameters: shows the quick-start banner, then prompts for each required value.

.EXAMPLE
    .\Get-AnyoneLinkInventory.ps1 -TenantId contoso.onmicrosoft.com -ClientId 00000000-0000-0000-0000-000000000000 -CertificateThumbprint 0000000000000000000000000000000000000000
    Windows, certificate in the user's certificate store.

.EXAMPLE
    .\Get-AnyoneLinkInventory.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 00000000-0000-0000-0000-000000000000 -CertificatePath ./cert.pfx -SiteUrlFilter '/sites/Finance' -MaxDrives 5
    Small test on one site with a .pfx file (any OS).

.EXAMPLE
    $pw = Read-Host -AsSecureString
    .\Get-AnyoneLinkInventory.ps1 -TenantId ... -ClientId ... -CertificatePath ./cert.pfx -CertificatePassword $pw -NonInteractive -OutputFolder ./scan1
    Unattended run. Run the same command again to resume after an interruption.

.EXAMPLE
    .\Get-AnyoneLinkInventory.ps1 -TenantId ... -ClientId ... -CertificateThumbprint ... -WhatIf
    Lists sites and drives only (drives.csv) without reading any item permissions.

.OUTPUTS
    In -OutputFolder:
      anyone_links.csv   merged result, one row per link
      drives.csv         every drive found, with size and status
      skipped.csv        sites/drives/items that could not be read (403 locked, 404, 423)
      progress.txt       heartbeat, one line per checkpoint
      run_<time>.log     full log including errors
      parts\, state\     per-drive results and checkpoints (used for resume)
    Exit codes: 0 success, 1 runtime error, 2 invalid/missing input, 3 no-activity timeout.

.NOTES
    Name     : Get-AnyoneLinkInventory.ps1
    Version  : 0.4.1
    Date     : 2026-11-04
    License  : MIT
    Requires : PowerShell 7.4+. No PowerShell modules required (raw Graph REST).

    CHANGELOG
      0.4.1  2026-11-04  done.txt also matches drive web URLs (seed a skip list from an earlier run); fixed
                          "Drives done x/y" over-count when done.txt holds drives outside the current filter.
      0.4.0  2026-11-04  Public, tenant-agnostic release. Parameters + validated prompts, -NonInteractive,
                         -Help, quick-start banner. Delta with "Prefer: hierarchicalsharing" so only unique
                         permission roots are queried. Mid-drive checkpoint/resume. Smallest drives first.
                         Heartbeat file and no-activity watchdog. Log file. Thumbprint or .pfx certificate.
      0.3.1  2026-11-03  Hard connect/read timeouts per call (HttpClient.Timeout alone did not cover reading
                         the response body in PowerShell 7.4).
      0.3.0  2026-11-03  Raw REST with own token instead of the Microsoft Graph SDK (the SDK shares one
                         connection per process, so parallel workers serialized). $batch of 20, drive-level
                         parallelism, Retry-After aware backoff, per-drive output and resume.
      0.2.0  2026-11-02  Delta enumeration of drives, CSV output.
      0.1.0  2026-11-02  First version.

    SOURCES (patterns reused and adapted)
      Microsoft Learn - Throttling guidance:   https://learn.microsoft.com/graph/throttling
      Microsoft Learn - JSON batching:         https://learn.microsoft.com/graph/json-batching
      Microsoft Learn - driveItem delta (Prefer headers): https://learn.microsoft.com/graph/api/driveitem-delta
      Microsoft Learn - Scan a hierarchy for sharing changes: https://learn.microsoft.com/onedrive/developer/rest-api/concepts/scan-guidance
      Microsoft Learn - Avoid throttling in SharePoint Online:
        https://learn.microsoft.com/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
      Microsoft Learn - Certificate credentials: https://learn.microsoft.com/entra/identity-platform/certificate-credentials
      Microsoft Learn - ForEach-Object -Parallel: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/foreach-object
      Tony Redmond (Office 365 IT Pros) - Report-SharingOneDriveFiles.PS1:
        https://github.com/12Knocksinna/Office365itpros/blob/master/Report-SharingOneDriveFiles.PS1
      PnP Script Samples - Audit sharing links: https://pnp.github.io/script-samples/spo-audit-sharing-links/README.html

.LINK
    README.md in the same folder (full setup guide).
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
param(
    [string]$TenantId,
    [string]$ClientId,
    [Parameter(ParameterSetName = 'Thumbprint')][string]$CertificateThumbprint,
    [Parameter(ParameterSetName = 'Path')][string]$CertificatePath,
    [Parameter(ParameterSetName = 'Path')][securestring]$CertificatePassword,
    [string]$OutputFolder = (Join-Path (Get-Location) "AnyoneLinkInventory_$(Get-Date -Format yyyyMMdd)"),
    [switch]$IncludeAllScopes,
    [string]$SiteUrlFilter,
    [ValidateRange(0, [int]::MaxValue)][int]$MaxDrives = 0,
    [ValidateRange(1, 8)][int]$ThrottleLimit = 4,
    [ValidateRange(5, 1440)][int]$NoActivityTimeoutMinutes = 120,
    [switch]$NonInteractive,
    [Alias('h', '?')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.4.1'

#region ---------- Help, banner, input ----------
if ($Help) { Get-Help $PSCommandPath -Full; return }

$noParams = $PSBoundParameters.Count -eq 0
if ($noParams) {
    Write-Host @"

  =====================================================================
   Get-AnyoneLinkInventory.ps1  v$ScriptVersion   (READ-ONLY)
   Inventories "Anyone" sharing links in SharePoint Online / OneDrive.
  ---------------------------------------------------------------------
   You need (setup steps in README.md):
     1. Tenant ID or domain        Entra admin center > Overview
     2. App (client) ID            App registrations > your app
        with Graph APPLICATION permission Sites.Read.All + admin consent
     3. Certificate                -CertificateThumbprint (Windows store)
                                   or -CertificatePath (.pfx, any OS)
   Full help:   Get-Help .\Get-AnyoneLinkInventory.ps1 -Full   (or -Help)
   Test first:  add  -SiteUrlFilter '/sites/<one-site>' -MaxDrives 3
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

$TenantId = Get-Value $TenantId 'TenantId' "($GuidRx)|($DomainRx)" 'Entra admin center > Identity > Overview > Tenant ID, or your <name>.onmicrosoft.com domain.' 'GUID or domain'
$ClientId = Get-Value $ClientId 'ClientId' $GuidRx 'Entra admin center > App registrations > your app > Overview > Application (client) ID.' 'GUID'

if (-not $CertificateThumbprint -and -not $CertificatePath) {
    if ($NonInteractive) { Fail-Input 'Provide -CertificateThumbprint or -CertificatePath with -NonInteractive.' }
    $choice = if ($IsWindows) { Read-Host 'Certificate: [T]humbprint from Windows store or [P]fx file path? (T/P)' } else { 'P' }
    if ($choice -match '^[Tt]') {
        $CertificateThumbprint = Get-Value '' 'CertificateThumbprint' $ThumbRx 'certlm.msc / certmgr.msc > Personal > Certificates > your cert > Details > Thumbprint (or the app''s Certificates & secrets page).' '40 hex characters'
    } else {
        $CertificatePath = (Read-Host 'Path to the .pfx file').Trim('"', "'", ' ')
    }
}

#region load certificate
try {
    if ($CertificateThumbprint) {
        $CertificateThumbprint = $CertificateThumbprint -replace '[\s\u200e]', ''
        if ($CertificateThumbprint -notmatch $ThumbRx) { Fail-Input "-CertificateThumbprint must be 40 hex characters." }
        if (-not $IsWindows) { Fail-Input '-CertificateThumbprint uses the Windows certificate store. On macOS/Linux use -CertificatePath with a .pfx file.' }
        $Cert = Get-ChildItem "Cert:\CurrentUser\My\$CertificateThumbprint", "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Cert) { Fail-Input "Certificate $CertificateThumbprint not found in Cert:\CurrentUser\My or Cert:\LocalMachine\My." }
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
    if (-not $Cert.HasPrivateKey) { Fail-Input 'The certificate has no private key. Use the .pfx (not the .cer) or a store certificate with its key.' }
    if ($Cert.NotAfter -lt (Get-Date)) { Fail-Input "The certificate expired on $($Cert.NotAfter). Create a new one (README step 3)." }
} catch [System.Security.Cryptography.CryptographicException] {
    Fail-Input "Cannot open the certificate: $($_.Exception.Message) (wrong password or corrupt file?)"
}
#endregion

#region output folder + logging
try {
    $OutputFolder = [IO.Path]::GetFullPath($OutputFolder)
    $partsDir = Join-Path $OutputFolder 'parts'; $stateDir = Join-Path $OutputFolder 'state'
    New-Item -ItemType Directory -Force -Path $OutputFolder, $partsDir, $stateDir | Out-Null
} catch { Fail-Input "Cannot create output folder '$OutputFolder': $($_.Exception.Message)" }
$doneFile = Join-Path $OutputFolder 'done.txt'
$skipFile = Join-Path $OutputFolder 'skipped.csv'
$progressFile = Join-Path $OutputFolder 'progress.txt'
$logFile = Join-Path $OutputFolder ("run_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$finalCsv = Join-Path $OutputFolder 'anyone_links.csv'

function Write-Log([string]$Msg, [string]$Level = 'INFO') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Msg
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $logFile -Value $line } catch { }
}
Write-Log "Get-AnyoneLinkInventory v$ScriptVersion started. Output: $OutputFolder. Read-only."
Write-Log ("Certificate: subject '{0}', expires {1:yyyy-MM-dd}" -f $Cert.Subject, $Cert.NotAfter)
#endregion
#endregion

#region ---------- Shared state + Graph helpers (also loaded into each parallel runspace) ----------
$S = [hashtable]::Synchronized(@{
        Token = $null; Exp = [datetime]::MinValue; Tenant = $TenantId; Client = $ClientId; Cert = $Cert
        Lock = [object]::new(); LastActivity = [datetime]::UtcNow; Calls = 0; Throttled = 0; Errors = 0
    })

$fn = {
    function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

    # App-only token via signed client assertion (certificate credential). Cached and refreshed after 45 min.
    function Get-GraphToken($S) {
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
                $detail = $_.ErrorDetails.Message
                throw "Token request failed. Check TenantId, ClientId, that the certificate is uploaded to the app, and admin consent. Detail: $($_.Exception.Message) $detail"
            }
            $S.Token = $r.access_token; $S.Exp = [datetime]::UtcNow.AddMinutes(45); return $S.Token
        } finally { [Threading.Monitor]::Exit($S.Lock) }
    }

    # GET (or POST /$batch with GET-only sub-requests). Retries transient errors honoring Retry-After.
    # Returns the response object, or @{__status=<code>} for 403/404/423 (recorded as skipped by the caller).
    function Invoke-Graph($S, [string]$Uri, $BatchBody, [hashtable]$ExtraHeaders) {
        for ($try = 1; $try -le 10; $try++) {
            try {
                $hd = @{ Authorization = "Bearer $(Get-GraphToken $S)" }
                if ($ExtraHeaders) { $hd += $ExtraHeaders }
                if ($BatchBody) {
                    $r = Invoke-RestMethod -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Headers $hd -ConnectionTimeoutSeconds 60 -OperationTimeoutSeconds 120 -ContentType 'application/json' -Body ($BatchBody | ConvertTo-Json -Depth 6 -Compress)
                } else {
                    $r = Invoke-RestMethod -Method GET -Uri $Uri -Headers $hd -ConnectionTimeoutSeconds 60 -OperationTimeoutSeconds 120
                }
                $S.LastActivity = [datetime]::UtcNow; $S.Calls++
                return $r
            } catch {
                $code = $null; $resp = $null
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $resp = $_.Exception.Response; $code = [int]$resp.StatusCode }
                $S.LastActivity = [datetime]::UtcNow
                if ($code -in 403, 404, 423) { return @{ __status = $code } }
                if ($code -eq 401) { $S.Token = $null }
                elseif ($code -and $code -notin 408, 429, 500, 502, 503, 504) {
                    $S.Errors++; throw "Graph HTTP $code on $(if($BatchBody){'$batch'}else{$Uri}): $($_.ErrorDetails.Message)"
                }
                elseif (-not $code -and $_.Exception -isnot [Net.Http.HttpRequestException] -and $_.Exception -isnot [Threading.Tasks.TaskCanceledException] -and $_.Exception -isnot [TimeoutException] -and $_.Exception -isnot [IO.IOException]) {
                    $S.Errors++; throw
                }
                if ($code -eq 429) { $S.Throttled++ }
                $wait = [Math]::Min(300, [Math]::Pow(2, $try) * 2) + (Get-Random -Maximum 3)
                try { $ra = $resp.Headers.RetryAfter.Delta.TotalSeconds; if ($ra) { $wait = [int]$ra + 1 } } catch { }
                Write-Warning "Retry $try/10 (HTTP $code $($_.Exception.Message)) in $wait s"
                Start-Sleep -Seconds $wait
            }
        }
        $S.Errors++; throw "Gave up after 10 retries: $Uri"
    }

    function Get-GraphPages($S, [string]$Uri, $Skipped, [hashtable]$ExtraHeaders) {
        while ($Uri) {
            $r = Invoke-Graph $S $Uri $null $ExtraHeaders
            if ($r -is [hashtable] -and $r.ContainsKey('__status')) { $Skipped.Add([pscustomobject]@{ Status = $r.__status; Uri = $Uri }); return }
            if ($r.PSObject.Properties['value']) { $r.value }
            $Uri = if ($r.PSObject.Properties['@odata.nextLink']) { $r.'@odata.nextLink' } else { $null }
        }
    }
}
. $fn
#endregion

#region ---------- Main ----------
$exitCode = 0
try {
    Write-Log 'Requesting app-only token...'
    [void](Get-GraphToken $S)
    Write-Log 'Token OK.' 'OK'

    # 1. Enumerate sites and drives
    $skipped = [Collections.Generic.List[object]]::new()
    $drives = [Collections.Generic.List[object]]::new()
    Write-Log 'Enumerating sites (getAllSites) and their drives...'
    $siteCount = 0
    foreach ($site in Get-GraphPages $S 'https://graph.microsoft.com/v1.0/sites/getAllSites?$select=id,webUrl&$top=999' $skipped) {
        $siteCount++
        if ($siteCount % 100 -eq 0) { Write-Log "  sites read: $siteCount, drives: $($drives.Count)" }
        foreach ($d in Get-GraphPages $S "https://graph.microsoft.com/v1.0/sites/$($site.id)/drives?`$select=id,name,driveType,webUrl,quota" $skipped) {
            if ($SiteUrlFilter -and $d.webUrl -notmatch $SiteUrlFilter) { continue }
            $used = 0; try { $used = [int64]$d.quota.used } catch { }
            $drives.Add([pscustomobject]@{ Id = $d.id; Name = $d.name; DriveType = $d.driveType; WebUrl = $d.webUrl; SiteUrl = $site.webUrl; UsedBytes = $used })
        }
    }
    if ($skipped.Count) { $skipped | Export-Csv -LiteralPath $skipFile -NoTypeInformation -Append -WhatIf:$false }
    Write-Log "Sites: $siteCount  Drives: $($drives.Count)  Skipped (locked/blocked/not found): $($skipped.Count)"
    $drives | Export-Csv -LiteralPath (Join-Path $OutputFolder 'drives.csv') -NoTypeInformation -WhatIf:$false
    if ($drives.Count -eq 0) { throw 'No drives found. Check SiteUrlFilter and that the app has Sites.Read.All (Application) with admin consent.' }

    if (-not $PSCmdlet.ShouldProcess("$($drives.Count) drives", 'Read items and permissions (read-only)')) {
        Write-Log 'WhatIf: drives.csv written, no permissions read.' 'OK'; return
    }

    # 2. Work list: skip done drives, smallest first
    $done = [Collections.Generic.HashSet[string]]::new()
    # done.txt lines are "<driveId><TAB><driveWebUrl><TAB><links>". A drive counts as done if its id OR its web URL
    # is listed, so a hand-made done.txt with one URL per line (e.g. from an earlier tool) also skips drives.
    if (Test-Path -LiteralPath $doneFile) { Get-Content -LiteralPath $doneFile | ForEach-Object { foreach ($f in ($_ -split "`t")) { if ($f.Trim()) { [void]$done.Add($f.Trim()) } } } }
    $isDone = { param($d) $done.Contains($d.Id) -or ($d.WebUrl -and $done.Contains($d.WebUrl)) }
    $todo = @($drives | Where-Object { -not (& $isDone $_) } | Sort-Object UsedBytes)
    if ($MaxDrives -gt 0) { $todo = @($todo | Select-Object -First $MaxDrives) }
    $alreadyDone = @($drives | Where-Object { & $isDone $_ }).Count
    Write-Log "Already done: $alreadyDone  To scan: $($todo.Count)  Parallel: $ThrottleLimit  Watchdog: $NoActivityTimeoutMinutes min"

    # 3. Scan drives in parallel (as a job so the main thread can run the watchdog)
    $fnText = $fn.ToString()
    $S.LastActivity = [datetime]::UtcNow
    $job = $todo | ForEach-Object -ThrottleLimit $ThrottleLimit -AsJob -Parallel {
        $ErrorActionPreference = 'Stop'
        . ([scriptblock]::Create($using:fnText))
        $S = $using:S; $d = $_; $allScopes = $using:IncludeAllScopes
        $stateDir = $using:stateDir; $partsDir = $using:partsDir
        $key = ($d.Id -replace '[^A-Za-z0-9]', '').Substring(0, [Math]::Min(40, ($d.Id -replace '[^A-Za-z0-9]', '').Length))
        $itemsFile = Join-Path $stateDir "$key.items.json"   # cached list of items to check
        $doneIds = Join-Path $stateDir "$key.doneids.txt"    # item ids already checked (checkpoint)
        $partial = Join-Path $partsDir "$key.partial.csv"
        $final = Join-Path $partsDir "$key.csv"
        $sw = [Diagnostics.Stopwatch]::StartNew(); $skip = [Collections.Generic.List[object]]::new()
        function Lock-Do([scriptblock]$sb) { $m = [Threading.Mutex]::new($false, 'M365Tools_AnyoneLinkInv'); [void]$m.WaitOne(); try { & $sb } finally { $m.ReleaseMutex(); $m.Dispose() } }
        try {
            # 3a. Items with unique sharing (cached so a resume does not re-enumerate)
            if (Test-Path -LiteralPath $itemsFile) {
                $items = @(Get-Content -LiteralPath $itemsFile -Raw | ConvertFrom-Json)
            } else {
                $hdr = @{ Prefer = 'hierarchicalsharing, deltashowsharingchanges' }
                $list = [Collections.Generic.List[object]]::new(); $n = 0
                foreach ($it in Get-GraphPages $S "https://graph.microsoft.com/v1.0/drives/$($d.Id)/root/delta?`$select=id,name,webUrl,shared,deleted&`$top=999" $skip $hdr) {
                    if ($it.PSObject.Properties['deleted'] -and $it.deleted) { continue }
                    $n++
                    if ($it.PSObject.Properties['shared'] -and $it.shared) { $list.Add([pscustomobject]@{ id = $it.id; name = $it.name; webUrl = $it.webUrl }) }
                }
                $items = @($list)
                ConvertTo-Json -InputObject $items -Depth 3 -Compress | Set-Content -LiteralPath "$itemsFile.tmp"
                Move-Item -LiteralPath "$itemsFile.tmp" -Destination $itemsFile -Force
            }
            $checked = [Collections.Generic.HashSet[string]]::new()
            if (Test-Path -LiteralPath $doneIds) { Get-Content -LiteralPath $doneIds | ForEach-Object { [void]$checked.Add($_) } }
            $queue = [Collections.Generic.Queue[object]]::new()
            foreach ($it in $items) { if (-not $checked.Contains($it.id)) { $queue.Enqueue([pscustomobject]@{ Item = $it; Url = "/drives/$($d.Id)/items/$($it.id)/permissions"; Try = 0; Page = 0 }) } }
            $links = 0; $batches = 0

            # 3b. Permissions in $batch of 20
            while ($queue.Count) {
                $chunk = @(); while ($queue.Count -and $chunk.Count -lt 20) { $chunk += $queue.Dequeue() }
                $req = @(for ($k = 0; $k -lt $chunk.Count; $k++) { @{ id = "$k"; method = 'GET'; url = $chunk[$k].Url } })
                $res = Invoke-Graph $S $null @{ requests = $req }
                $rows = [Collections.Generic.List[object]]::new(); $finished = [Collections.Generic.List[string]]::new(); $maxRa = 0
                foreach ($r in $res.responses) {
                    $c = $chunk[[int]$r.id]; $st = [int]$r.status
                    if ($st -eq 200) {
                        foreach ($p in @($r.body.value)) {
                            if (-not ($p.PSObject.Properties['link'] -and $p.link)) { continue }
                            if (-not $allScopes -and $p.link.scope -ne 'anonymous') { continue }
                            if ($p.PSObject.Properties['inheritedFrom'] -and $p.inheritedFrom) { continue }
                            $rows.Add([pscustomobject]@{
                                    LinkId = $p.id; Scope = $p.link.scope; Roles = ($p.roles -join ';'); LinkType = $p.link.type
                                    ExpirationDateTime = $(if ($p.PSObject.Properties['expirationDateTime']) { $p.expirationDateTime })
                                    HasPassword = $(if ($p.PSObject.Properties['hasPassword']) { $p.hasPassword })
                                    LinkUrl = $(if ($p.link.PSObject.Properties['webUrl']) { $p.link.webUrl })
                                    ItemName = $c.Item.name; ItemUrl = $c.Item.webUrl; ItemId = $c.Item.id
                                    DriveName = $d.Name; DriveType = $d.DriveType; DriveId = $d.Id; SiteUrl = $d.SiteUrl
                                })
                        }
                        if ($r.body.PSObject.Properties['@odata.nextLink']) {
                            $queue.Enqueue([pscustomobject]@{ Item = $c.Item; Url = ($r.body.'@odata.nextLink' -replace '^https://graph.microsoft.com/v1.0', ''); Try = 0; Page = $c.Page + 1 })
                        } else { $finished.Add($c.Item.id) }
                    } elseif ($st -in 429, 500, 502, 503, 504 -and $c.Try -lt 8) {
                        if ($st -eq 429) { $S.Throttled++ }
                        $c.Try++; $queue.Enqueue($c); $ra = 10 * $c.Try
                        try { if ($r.headers.'Retry-After') { $ra = [int]$r.headers.'Retry-After' } } catch { }
                        $maxRa = [Math]::Max($maxRa, $ra)
                    } else { $skip.Add([pscustomobject]@{ Status = $st; Uri = $c.Url }); $finished.Add($c.Item.id) }
                }
                # checkpoint: rows first, then ids (a crash between the two can only duplicate rows, never lose them)
                if ($rows.Count) { $rows | Export-Csv -LiteralPath $partial -NoTypeInformation -Append -Encoding utf8; $links += $rows.Count }
                if ($finished.Count) { Add-Content -LiteralPath $doneIds -Value $finished }
                $batches++
                if ($batches % 20 -eq 0) {
                    $line = "{0:yyyy-MM-dd HH:mm:ss}`t{1}`tchecked={2}/{3}`tlinks={4}`tthrottled={5}" -f (Get-Date), $d.WebUrl, ($items.Count - $queue.Count), $items.Count, $links, $S.Throttled
                    Lock-Do { Add-Content -LiteralPath $using:progressFile -Value $line }
                }
                if ($maxRa) { Start-Sleep -Seconds $maxRa }
            }

            # 3c. Finalize drive
            if (Test-Path -LiteralPath $partial) { Move-Item -LiteralPath $partial -Destination $final -Force }
            else { Set-Content -LiteralPath $final -Value '' }
            Lock-Do {
                if ($skip.Count) { $skip | Export-Csv -LiteralPath $using:skipFile -Append -NoTypeInformation }
                Add-Content -LiteralPath $using:doneFile -Value "$($d.Id)`t$($d.WebUrl)`t$links"
                Add-Content -LiteralPath $using:progressFile -Value ("{0:yyyy-MM-dd HH:mm:ss}`t{1}`tDONE`tuniqueItems={2}`tlinks={3}`tseconds={4:N0}" -f (Get-Date), $d.WebUrl, $items.Count, $links, $sw.Elapsed.TotalSeconds)
            }
            Remove-Item -LiteralPath $itemsFile, $doneIds -ErrorAction SilentlyContinue
            "OK`t$($d.WebUrl)`tuniqueItems=$($items.Count)`tlinks=$links`tseconds=$([int]$sw.Elapsed.TotalSeconds)"
        } catch {
            "FAIL`t$($d.WebUrl)`t$($_.Exception.Message)  (checkpoint kept; rerun to resume)"
        }
    }

    # 4. Watchdog loop
    $idleLimit = [timespan]::FromMinutes($NoActivityTimeoutMinutes); $ok = 0; $failed = 0; $lastBeat = Get-Date
    while ($true) {
        foreach ($o in @(Receive-Job $job -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
            if ($o -like 'OK*') { $ok++; Write-Log "($ok/$($todo.Count)) $o" 'OK' } else { $failed++; Write-Log "$o" 'ERROR' }
        }
        if ($job.State -in 'Completed', 'Failed', 'Stopped') { break }
        $idle = [datetime]::UtcNow - $S.LastActivity
        if ($idle -gt $idleLimit) {
            Stop-Job $job
            Write-Log "No Graph activity for $([int]$idle.TotalMinutes) min (limit $NoActivityTimeoutMinutes). Stopped. Progress is saved; rerun the same command to resume." 'ERROR'
            $exitCode = 3; break
        }
        if (((Get-Date) - $lastBeat).TotalMinutes -ge 5) {
            Write-Log ("heartbeat: drives ok={0} failed={1} of {2}; Graph calls={3} throttled={4} idle={5:N0}s" -f $ok, $failed, $todo.Count, $S.Calls, $S.Throttled, $idle.TotalSeconds)
            $lastBeat = Get-Date
        }
        Start-Sleep -Seconds 5
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    # 5. Merge
    $parts = @(Get-ChildItem -LiteralPath $partsDir -Filter '*.csv' | Where-Object { $_.Name -notlike '*.partial.csv' -and $_.Length -gt 0 })
    $allRows = @(foreach ($p in $parts) { Import-Csv -LiteralPath $p.FullName })
    $allRows | Export-Csv -LiteralPath $finalCsv -NoTypeInformation -Encoding utf8
    $doneCount = $alreadyDone + $ok   # drives in scope that are finished (done.txt may hold extra lines)
    Write-Log ("Finished. Drives done {0}/{1} (failed this run: {2}). Links: {3} -> {4}" -f $doneCount, $drives.Count, $failed, $allRows.Count, $finalCsv) 'OK'
    if ($failed -gt 0 -and $exitCode -eq 0) { Write-Log 'Some drives failed. Rerun the same command to retry them (finished drives are skipped).' 'WARN'; $exitCode = 1 }
} catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log "At: $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')" 'ERROR'
    $exitCode = 1
} finally {
    Write-Log "Log file: $logFile"
}
exit $exitCode
#endregion
