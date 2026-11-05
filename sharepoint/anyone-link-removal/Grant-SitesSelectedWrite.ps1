<#
.SYNOPSIS
    Grants application Sites.Selected **write** on named SharePoint/OneDrive sites to a target Entra app.

.DESCRIPTION
    Bootstrap helper for Sites.Selected grants used by Anyone-link removal. The **removal**
    app should hold only application **Sites.Selected**.
    Before that app can DELETE drive-item sharing permissions on a OneDrive, an identity that
    already has **Sites.FullControl.All** must create a site permission granting the removal
    app **write** on each target site:

      POST /sites/{site-id}/permissions
      {
        "roles": ["write"],
        "grantedToIdentities": [{
          "application": { "id": "<removal-app-client-id>", "displayName": "..." }
        }]
      }

    CRITICAL SEPARATION OF PRIVILEGE
      * This grant step uses a **human admin / temporary bootstrap** identity with
        Sites.FullControl.All (delegated preferred). See README.md.
      * Do **NOT** add Sites.FullControl.All (or Sites.ReadWrite.All / Sites.Manage.All) to the
        removal app itself without an explicit change-control decision.
      * The removal app certificate (.pfx) is **not** used by this helper. It is used only by
        Remove-AnyoneLink.ps1 after grants exist.

    SAFETY DEFAULTS
      * Dry-run is the default. No POST is sent unless -Execute is passed AND ShouldProcess allows it.
      * -WhatIf is honored (SupportsShouldProcess).
      * -NonInteractive fails fast when required values are missing (exit 2).
      * Without -AccessToken and without a successful Connect-MgGraph session, the script only
        plans (resolves hostname:path shapes) and never calls Graph unless -Execute with a token.

.PARAMETER TenantId
    Directory (tenant) ID GUID. Find it in Entra admin center > Overview > Tenant ID.

.PARAMETER ClientId
    Application (client) ID of the dedicated removal / Sites.Selected app (the app receiving write).

.PARAMETER ApplicationDisplayName
    Optional displayName stored on the site permission. Default:
    AnyoneLinkRemoval-WriteSelected

.PARAMETER SiteUrl
    One or more site web URLs (e.g. https://contoso-my.sharepoint.com/personal/user_contoso_com).

.PARAMETER SiteListPath
    Text file with one site URL per line (# comments and blank lines ignored).

.PARAMETER Role
    Site permission role to grant. Default: write. (read | write | manage | fullcontrol)

.PARAMETER AccessToken
    Optional Bearer token from Graph Explorer or another delegated admin session that already
    holds Sites.FullControl.All. Prefer this over embedding secrets. Never commit tokens.

.PARAMETER UseConnectMgGraph
    Attempt Connect-MgGraph -Scopes Sites.FullControl.All (interactive). Requires
    Microsoft.Graph.Authentication (and Sites cmdlets optional; raw REST is used by default).

.PARAMETER OutputFolder
    Folder for plan/result CSVs and logs.

.PARAMETER Execute
    Opt-in to POST site permissions after resolving site IDs.

.PARAMETER NonInteractive
    Never prompt; missing values fail with exit code 2.

.PARAMETER Help
    Show full help and exit.

.EXAMPLE
    .\Grant-SitesSelectedWrite.ps1 -SiteListPath .\sites.txt
    Dry-run plan only (prompts for ClientId/TenantId unless supplied). No Graph mutation.

.EXAMPLE
    .\Grant-SitesSelectedWrite.ps1 -TenantId 00000000-0000-0000-0000-000000000000 `
      -ClientId 00000000-0000-0000-0000-000000000001 -SiteListPath .\sites.txt
    Dry-run with placeholder IDs; still no POST until -Execute and a delegated token.

.EXAMPLE
    .\Grant-SitesSelectedWrite.ps1 ... -AccessToken $tok -Execute -Confirm
    Live grant using a Graph Explorer / admin-consented delegated token.

.NOTES
    Name     : Grant-SitesSelectedWrite.ps1
    Version  : 1.0.0
    Date     : 2026-11-05
    License  : MIT
    Sources  : https://learn.microsoft.com/graph/api/site-post-permissions?view=graph-rest-1.0
               https://learn.microsoft.com/graph/permissions-selected-overview
               (verified 2026-11-05)

    CHANGELOG
      1.0.0  2026-11-05  Public tenant-agnostic release. Dry-run default, site list,
                         delegated token / Connect-MgGraph path; no cert auth for this helper.
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$ApplicationDisplayName = 'AnyoneLinkRemoval-WriteSelected',
    [string[]]$SiteUrl,
    [string]$SiteListPath,
    [ValidateSet('read', 'write', 'manage', 'fullcontrol')][string]$Role = 'write',
    [string]$AccessToken,
    [switch]$UseConnectMgGraph,
    [string]$OutputFolder = (Join-Path (Get-Location) "SitesSelectedGrant_$(Get-Date -Format yyyyMMdd)"),
    [switch]$Execute,
    [switch]$NonInteractive,
    [Alias('h', '?')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$GraphRoot = 'https://graph.microsoft.com/v1.0'
$GuidRx = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

if ($Help) { Get-Help $PSCommandPath -Full; return }

$noParams = $PSBoundParameters.Count -eq 0
if ($noParams) {
    Write-Host @"

  =====================================================================
   Grant-SitesSelectedWrite.ps1  v$ScriptVersion
   Grants Sites.Selected site-level roles to a target application.
  ---------------------------------------------------------------------
   SAFETY: dry-run by default. No POST unless -Execute (+ ShouldProcess).
   Bootstrap identity needs Sites.FullControl.All (delegated admin).
   Do NOT expand the removal app to FullControl without change control.
   Removal app cert is NOT used here (see Remove-AnyoneLink.ps1).
   See README.md (Sites.Selected section).
   Full help:  Get-Help .\Grant-SitesSelectedWrite.ps1 -Full
  =====================================================================

"@ -ForegroundColor Cyan
}

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

function ConvertTo-SiteResourcePath([string]$WebUrl) {
    # https://host/personal/user -> host:/personal/user  (Graph sites path form)
    $u = [Uri]$WebUrl
    if ($u.Scheme -notin @('https', 'http')) { throw "Site URL must be http(s): $WebUrl" }
    $hostName = $u.Host
    $path = $u.AbsolutePath.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '/') {
        throw "Site URL needs a server-relative path (e.g. /personal/...): $WebUrl"
    }
    return @{ Hostname = $hostName; ServerRelativePath = $path.TrimStart('/'); Resource = "$hostName`:$($path)" }
}

try {
    $OutputFolder = [IO.Path]::GetFullPath($OutputFolder)
    New-Item -ItemType Directory -Force -Path $OutputFolder -WhatIf:$false | Out-Null
} catch { Fail-Input "Cannot create output folder '$OutputFolder': $($_.Exception.Message)" }

$logFile = Join-Path $OutputFolder ("grant_run_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$planCsv = Join-Path $OutputFolder 'would_grant.csv'
$resultCsv = Join-Path $OutputFolder 'grant_results.csv'

function Write-Log([string]$Msg, [string]$Level = 'INFO') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Msg
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; PLAN = 'Cyan' }[$Level]
    if (-not $color) { $color = 'Gray' }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $logFile -Value $line -WhatIf:$false } catch { }
}

Write-Log "Grant-SitesSelectedWrite v$ScriptVersion starting. Execute=$Execute WhatIf=$WhatIfPreference Role=$Role"

# Collect site URLs
$sites = [System.Collections.Generic.List[string]]::new()
foreach ($s in @($SiteUrl)) {
    if ($s) { [void]$sites.Add($s.Trim().TrimEnd('/')) }
}
if ($SiteListPath) {
    if (-not (Test-Path -LiteralPath $SiteListPath -PathType Leaf)) {
        Fail-Input "SiteListPath not found: $SiteListPath"
    }
    Get-Content -LiteralPath $SiteListPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        [void]$sites.Add($line.TrimEnd('/'))
    }
}
if ($sites.Count -eq 0) {
    if ($NonInteractive) {
        Fail-Input 'Provide -SiteUrl and/or -SiteListPath.'
    }
    Write-Host "No sites provided." -ForegroundColor DarkGray
    $raw = (Read-Host 'Site URL (or path to a .txt list)').Trim('"', "'", ' ')
    if (Test-Path -LiteralPath $raw -PathType Leaf) {
        Get-Content -LiteralPath $raw | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line.StartsWith('#')) { return }
            [void]$sites.Add($line.TrimEnd('/'))
        }
    } elseif ($raw) {
        [void]$sites.Add($raw.TrimEnd('/'))
    }
}
$sites = @($sites | Select-Object -Unique)
if ($sites.Count -eq 0) { Fail-Input 'No site URLs to process.' }

$TenantId = Get-Value $TenantId 'TenantId' $GuidRx `
    'Entra admin center > Overview > Tenant ID (verify UI; staging default may be stale).' 'GUID'
$ClientId = Get-Value $ClientId 'ClientId' $GuidRx `
    'Entra > App registrations > your dedicated Sites.Selected / removal app > Application (client) ID.' 'GUID'

Write-Log "Target app ClientId=$ClientId DisplayName=$ApplicationDisplayName TenantId=$TenantId"
Write-Log ("Sites to consider: {0}" -f $sites.Count)

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($web in $sites) {
    try {
        $res = ConvertTo-SiteResourcePath $web
        $plan.Add([pscustomobject]@{
            SiteUrl            = $web
            GraphSiteResource  = $res.Resource
            Hostname           = $res.Hostname
            ServerRelativePath = $res.ServerRelativePath
            SiteId             = ''
            ClientId           = $ClientId
            Role               = $Role
            Action             = 'POST /sites/{id}/permissions'
            Status             = 'planned'
            Detail             = 'Dry-run / unresolved site id'
        }) | Out-Null
    } catch {
        $plan.Add([pscustomobject]@{
            SiteUrl = $web; GraphSiteResource = ''; Hostname = ''; ServerRelativePath = ''
            SiteId = ''; ClientId = $ClientId; Role = $Role; Action = 'POST /sites/{id}/permissions'
            Status = 'invalid_url'; Detail = $_.Exception.Message
        }) | Out-Null
        Write-Log "Invalid site URL skipped: $web :: $($_.Exception.Message)" 'WARN'
    }
}

$plan | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding utf8
Write-Log "Wrote plan: $planCsv" 'PLAN'

function Get-GraphToken {
    if ($AccessToken) {
        Write-Log 'Using -AccessToken (delegated admin / Graph Explorer). Token not logged.' 'WARN'
        return $AccessToken.Trim()
    }
    if ($UseConnectMgGraph) {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
            Fail-Input 'Microsoft.Graph.Authentication module not installed. Install-Module Microsoft.Graph.Authentication, or pass -AccessToken from Graph Explorer.'
        }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Write-Log 'Connecting via Connect-MgGraph -Scopes Sites.FullControl.All (interactive).' 'WARN'
        Connect-MgGraph -TenantId $TenantId -Scopes 'Sites.FullControl.All' -NoWelcome | Out-Null
        $ctx = Get-MgContext
        if (-not $ctx) { Fail-Input 'Connect-MgGraph did not establish a context.' }
        # Prefer Get-MgAccessToken if available (newer SDK); else fail with clear guidance
        if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
            try {
                # MSAL token via Invoke with empty call fails; use REST with Connect session:
                # Microsoft.Graph.Authentication exposes Invoke-MgGraphRequest when connected.
                return '__MGGRAPH_SESSION__'
            } catch {
                Fail-Input "Could not use Connect-MgGraph session: $($_.Exception.Message)"
            }
        }
    }
    return $null
}

function Invoke-GraphJson {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$TokenMode,
        [string]$Bearer,
        [object]$BodyObject
    )
    $headers = @{ 'Accept' = 'application/json' }
    $bodyJson = $null
    if ($null -ne $BodyObject) {
        $bodyJson = $BodyObject | ConvertTo-Json -Depth 8 -Compress
        $headers['Content-Type'] = 'application/json'
    }
    if ($TokenMode -eq '__MGGRAPH_SESSION__') {
        if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        }
        $params = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
        if ($bodyJson) { $params['Body'] = $bodyJson }
        return Invoke-MgGraphRequest @params
    }
    $headers['Authorization'] = "Bearer $Bearer"
    $irm = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($bodyJson) { $irm['Body'] = $bodyJson }
    return Invoke-RestMethod @irm
}

$tokenMode = $null
if ($Execute) {
    $tokenMode = Get-GraphToken
    if (-not $tokenMode) {
        Fail-Input @"
-Execute requires a delegated Sites.FullControl.All token.
  Option A: sign in at https://developer.microsoft.com/graph/graph-explorer (same tenant),
            consent Sites.FullControl.All, copy Access token, pass -AccessToken.
  Option B: -UseConnectMgGraph (Install-Module Microsoft.Graph.Authentication).
Do NOT use the removal app certificate for this grant step.
See README.md.
"@
    }
} else {
    Write-Log 'Dry-run: no token requested; no Graph calls will be made.' 'PLAN'
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($row in $plan) {
    if ($row.Status -eq 'invalid_url') {
        $results.Add($row) | Out-Null
        continue
    }

    $target = "$($row.SiteUrl) role=$Role app=$ClientId"
    if (-not $Execute) {
        Write-Log "PLAN resolve+POST $target (GraphSiteResource=$($row.GraphSiteResource))" 'PLAN'
        $row.Status = 'would_grant'
        $row.Detail = 'Dry-run only; pass -Execute with delegated FullControl token to apply'
        $results.Add($row) | Out-Null
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($target, "Grant Sites.Selected role '$Role' to app $ClientId")) {
        $row.Status = 'skipped_shouldprocess'
        $row.Detail = 'ShouldProcess declined'
        $results.Add($row) | Out-Null
        continue
    }

    try {
        # Resolve site id: GET /sites/{hostname}:/{server-relative-path}
        $resolveUri = "$GraphRoot/sites/$($row.Hostname):/$($row.ServerRelativePath)?`$select=id,webUrl,displayName"
        Write-Log "GET $resolveUri"
        $siteObj = Invoke-GraphJson -Method GET -Uri $resolveUri -TokenMode $tokenMode -Bearer $AccessToken
        $siteId = [string]$siteObj.id
        if (-not $siteId) { throw 'Resolved site object had empty id' }
        $row.SiteId = $siteId

        $body = @{
            roles = @($Role)
            grantedToIdentities = @(
                @{
                    application = @{
                        id          = $ClientId
                        displayName = $ApplicationDisplayName
                    }
                }
            )
        }
        $postUri = "$GraphRoot/sites/$([uri]::EscapeDataString($siteId))/permissions"
        # siteId contains commas; EscapeDataString is wrong for path segments with commas —
        # Graph expects the raw composite id. Use as-is (no escape of commas).
        $postUri = "$GraphRoot/sites/$siteId/permissions"
        Write-Log "POST $postUri roles=[$Role] application.id=$ClientId"
        $perm = Invoke-GraphJson -Method POST -Uri $postUri -TokenMode $tokenMode -Bearer $AccessToken -BodyObject $body
        $row.Status = 'granted'
        $row.Detail = "permission id=$($perm.id)"
        Write-Log "Granted on $($row.SiteUrl) permissionId=$($perm.id)" 'OK'
    } catch {
        $row.Status = 'error'
        $row.Detail = $_.Exception.Message
        Write-Log "FAILED $($row.SiteUrl): $($_.Exception.Message)" 'ERROR'
    }
    $results.Add($row) | Out-Null
}

$results | Export-Csv -LiteralPath $resultCsv -NoTypeInformation -Encoding utf8
Write-Log "Wrote results: $resultCsv" 'OK'
# Refresh plan CSV with final statuses (would_grant / granted / error)
$results | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding utf8
Write-Log "Updated plan/status CSV: $planCsv" 'PLAN'

$granted = @($results | Where-Object Status -eq 'granted').Count
$would = @($results | Where-Object Status -eq 'would_grant').Count
$err = @($results | Where-Object Status -eq 'error').Count
Write-Log "Summary: would_grant=$would granted=$granted errors=$err Execute=$Execute" 'OK'

if ($err -gt 0) { exit 1 }
exit 0
