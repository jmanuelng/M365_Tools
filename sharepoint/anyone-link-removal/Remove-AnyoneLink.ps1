<#
.SYNOPSIS
    Review or remove exact non-inherited Anyone-edit sharing permissions; verify the item remains.
.DESCRIPTION
    Reads an approved inventory-compatible CSV and operates sequentially on exact DriveId|ItemId|LinkId
    keys. Dry-run is the DEFAULT: live GETs validate candidates, but only Execute plus ShouldProcess
    permits DELETE. WhatIf always remains read-only. A current permission must have the exact ID,
    link.scope=anonymous, link.type=edit and no inheritedFrom. A write role alone cannot bypass this gate.

    CONTROL FLOW: validate input/hash/context and acquire an exclusive output lock; load the durable
    journal; exclude only modern VERIFIED keys; authenticate with an existing dedicated certificate app;
    fresh-GET each remaining permission; obtain ShouldProcess approval; recheck immediately before
    DELETE; verify exact permission404 AND underlying item200 with matching ID; fsync VERIFIED before
    updating human-readable progress. Changed targets are never substituted. No audit search is refreshed
    and the absence of recent audit activity is NOT proof a link was never used.

    RECOVERY: transient GET timeouts/throttling have bounded retries and Retry-After handling in ALL
    phases. A DELETE intent is durable before the call; acknowledged deletion is NEVER replayed.
    An ambiguous timeout is reconciled with reads and then pauses if still present; only explicit
    429/503/504 can use the configured mutation retry after reconciliation and a fresh shape guard.
    Crash/restart requires Resume with the same input/context. Unresolved present permissions, malformed
    journals, auth/permanent errors, changed shapes, missing/wrong items or budgets fail closed.

    SUCCESS IS EVIDENCE, not a response code: DELETE204 alone is not a completed removal. Only exact
    permission404 plus matching item200 yields a terminal VERIFIED checkpoint. Plans, skips, errors,
    historical failures, prior verified keys and current-run outcomes are reported separately.
    Completed means the invocation processed its candidates; ExecutionComplete excludes dry-run/skips.
    Neither flag authorizes another batch. Outputs are private runtime evidence; do not publish them.

    RESTORE LIMIT: removes the sharing permission, NOT the file or independent grants. The identical
    sharing URL is not guaranteed recoverable. An owner may create a replacement link outside this tool.
    Review recipient impact and recovery expectations BEFORE approving the exact CSV.

    TENANT-AGNOSTIC / PUBLISH-SAFE CONTRACT:
    All tenant/app identities, certificate/input/output paths and options are parameters. This public
    raw-REST preview is OFFLINE-TESTED ONLY, not live-tenant validated. Results from any distinct SDK
    executor do not validate this transport. Test in a nonproduction tenant before an approved pilot.
    Requires pre-existing certificate auth/consent/site grants; never provisions or widens privileges.

.PARAMETER TenantId
    Target directory GUID or primary domain; no default. Required for live requests; prompted with
    validation unless NonInteractive. Must identify the tenant whose exact CSV was approved. Bound
    to OutputFolder for resume; never inferred from a certificate.

.PARAMETER ClientId
    Dedicated removal app GUID; no default. Required live; prompted unless NonInteractive. Never
    reuse the read-only inventory registration or widen its privileges. Bound with TenantId and
    MockGraph to the output context.

.PARAMETER CertificateThumbprint
    Windows certificate-store thumbprint, exactly40 hexadecimal characters after whitespace removal;
    no default. Thumbprint parameter set only; searches CurrentUser then LocalMachine. Requires
    private key and unexpired certificate. Do not combine with CertificatePath/CertificatePassword.

.PARAMETER CertificatePath
    PFX file path with private key; no default, Path parameter set. Any OS; must exist and contain
    an unexpired private-key certificate. Prompted if omitted in an interactive live run. Never use
    a secret path from another environment.

.PARAMETER CertificatePassword
    SecureString for CertificatePath; no default. Interactive omission prompts securely;
    NonInteractive omission tries an empty password. No plaintext password argument is supported.
    Converted only in memory to open an ephemeral-key certificate; never logged.

.PARAMETER InputCsv
    Existing nonempty CSV path; no default live, mocks/sample_input.csv under MockGraph. Required
    columns: DriveId,ItemId,LinkId; candidate filtering also uses Scope and LinkType/Roles. Blank or
    duplicate exact keys fail input validation. Every byte is SHA256-bound to OutputFolder;
    edit/reorder requires a new review and folder.

.PARAMETER OutputFolder
    Local receipt/checkpoint folder; default ./AnyoneLinkRemoval_<yyyyMMdd> under the current
    directory. Created if needed and exclusively locked for the run. Treat as sensitive: operational
    keys, URLs in plans, logs and results are private runtime data, never publication assets. Reuse
    ONLY with same input bytes, tenant, client and mode; preserve all files for recovery.

.PARAMETER MaxItems
    Integer0..Int32.MaxValue; default0 means all remaining candidates. Applied AFTER anonymous-edit
    filtering and verified resume exclusions. It limits this invocation, not an approval grant;
    changing it does not authorize another cohort. Prefer a separately approved pilot CSV.

.PARAMETER RequireAnonymousEdit
    Boolean, default true. Filters CSV rows to anonymous edit/write candidates before requests.
    False disables ONLY the CSV convenience filter for testing; it NEVER relaxes the live exact-ID,
    anonymous, type=edit and non-inherited guard.

.PARAMETER AllowedPermissionIds
    String array of allowed Graph APPLICATION permission GUIDs or role names. Default
    Files.ReadWrite.All (75359482-378d-4052-8f01-80520e7db3cd). For an already-granted site-scoped
    app include Sites.Selected (883ea226-0bf2-4a8f-9f9d-92c9162a727d). Checks issued token roles;
    grants nothing and never performs consent. DeniedPermissionIds always wins.

.PARAMETER DeniedPermissionIds
    Additional denied Graph application GUIDs. Canonical Sites.FullControl.All and Sites.Manage.All
    remain denied even if an empty list is supplied. Detected by canonical GUID or mapped token role
    name; auth fails closed without a request retry or privilege escalation.

.PARAMETER Execute
    Switch, default false. Enables the mutation path only AFTER live shape validation AND
    ShouldProcess approval. WhatIf still forbids DELETE. Confirm:false suppresses prompts but is not
    user approval; obtain explicit exact-scope approval outside the script first.

.PARAMETER MockGraph
    Switch, default false. Local simulation only: no token endpoint or Graph request. Permissions
    come from MockPermissionsPath, mock deleted IDs are in-memory, and mock item existence returns
    the requested ID. Output context cannot be reused for a live run; mocks are not tenant
    validation.

.PARAMETER MockPermissionsPath
    JSON fixture path; default <script-directory>/mocks/permissions.json. Used only with MockGraph
    and must exist. Fixture IDs and optional offline fault markers never become live credentials or
    targets.

.PARAMETER ThrottleLimit
    Compatibility integer1..4; default2. RESERVED, ignored for concurrency: all operations remain
    SEQUENTIAL. Batch size is logical scope, not parallelism; do not use this knob to increase write
    rate.

.PARAMETER MaxDeleteRetries
    Integer0..5; default1 additional attempt, only after explicit429/503/504. There is NO transport-
    level DELETE retry. Server delay is honored BEFORE reconciliation; exact permission and item
    reads plus fresh allowlist check precede a retry. Timeout/transport0 never auto-resends;
    acknowledged200/202/204/404 never retries.

.PARAMETER MaxReadRetries
    Integer0..8; default3 additional GET attempts (four total per GET phase).
    Transient0/408/429/500/502/503/504 recover with bounded backoff. Applies to prechecks,
    permission verification and item verification; auth/permanent errors and malformed200 never
    retry as absence.

.PARAMETER MaxVerificationPolls
    Integer0..6; default3 additional reads while a post-DELETE exact permission still returns200.
    Initial verification always occurs; each extra poll backs off and retains the shape guard.
    Polling can reconcile replica lag but NEVER permits a confirmed DELETE replay.

.PARAMETER ExpectedInputSha256
    Optional exactly64 hexadecimal characters; no default. When supplied, the CSV must match this
    independently reviewed hash BEFORE auth/requests. Strongly recommended with Execute and Resume.
    The hash certifies bytes, not authorization; keep the reviewed list and approval separately.

.PARAMETER Resume
    Switch, default false. REQUIRED when OutputFolder already has a mutation journal. Same immutable
    input/context only. Modern VERIFIED entries skip exact keys; incomplete or legacy entries are
    reconciled with permission404 plus item200 matching ID. If an unresolved permission remains
    present, pause for operator review; never reset the journal to force a retry.

.PARAMETER RequestTimeoutSeconds
    Integer1..120; default30. Passed to both connection and operation timeouts on each Graph data
    request. Token acquisition has its own30/60-second bounds. OS/network stalls can exceed these
    cooperative limits; use a separate finite, suspend-aware process watchdog.

.PARAMETER MaxRetryDelaySeconds
    Integer0..300; default60. Maximum permitted wait for server Retry-After (integer seconds or
    HTTP-date) or exponential fallback. Invalid, negative, excessive or unaffordable delays PAUSE;
    the script never shortens a server delay. Zero permits only an explicit zero-delay server retry.

.PARAMETER MaxRunSeconds
    Integer1..86400; default3600. Cooperative whole-invocation budget from initialization, including
    prompts, auth, requests and waits. UTC wall time and Stopwatch are compared; >60-second
    divergence or exhausted budget pauses. Not a hard cancellation timer and not a substitute for a
    suspend-aware external supervisor.

.PARAMETER NonInteractive
    Switch, default false. Never prompts for missing values, certificate choice or password.
    Missing/invalid required input exits2; does not bypass ShouldProcess or grant deletion approval.
    Supply explicit values and existing auth setup; no automatic sign-in/consent flow.

.PARAMETER Help
    Switch with aliases h and ?; default false. Display full comment-based help and return before
    output initialization, authentication or Graph requests. Common WhatIf/Confirm parameters retain
    standard PowerShell semantics.

.INPUTS
    None. No pipeline input is accepted; targets come only from InputCsv.
.OUTPUTS
    Timestamped local-offset console logs and Write-Progress; no success objects on the pipeline.
    OutputFolder contains input_sha256.txt, execution_context.json, mutation_journal.jsonl (authority),
    request_receipts.jsonl, done.txt (compatibility projection), summary.json (atomic projection),
    progress.txt, incremental result/plan/skip CSVs and run logs. Receipts retain key/phase/status and
    structural exception type only, never tokens, auth bodies or raw service exceptions.
.EXAMPLE
    ./Remove-AnyoneLink.ps1 -MockGraph -InputCsv ./mocks/sample_input.csv -OutputFolder ./mock-review
    Entirely local dry-run; no auth or tenant traffic. Do not reuse this folder for live work.
.EXAMPLE
    $auth = @{ TenantId='contoso.onmicrosoft.com'; ClientId='00000000-0000-0000-0000-000000000000';
               CertificatePath='./removal.pfx'; CertificatePassword=(Read-Host 'PFX password' -AsSecureString) }
    ./Remove-AnyoneLink.ps1 @auth -InputCsv ./reviewed-pilot.csv -OutputFolder ./pilot-review -MaxItems 5
    Live GET-only review. Replace placeholders with an already authorized dedicated application.
.EXAMPLE
    $approvedHash = Read-Host 'Independently reviewed exact CSV SHA256'
    ./Remove-AnyoneLink.ps1 @auth -InputCsv ./reviewed-pilot.csv -OutputFolder ./pilot-execution `
        -ExpectedInputSha256 $approvedHash -Execute -Confirm
    AFTER explicit exact-scope approval, confirm each mutation. The separately defined auth splat is
    reused from the previous example; it is not a request to grant consent or to reuse an inventory app.
.EXAMPLE
    ./Remove-AnyoneLink.ps1 @auth -InputCsv ./reviewed-pilot.csv -OutputFolder ./pilot-execution `
        -ExpectedInputSha256 $approvedHash -Execute -Resume -NonInteractive -Confirm:$false
    Continue the SAME previously approved cohort. Skip verified keys; reconcile incomplete intents with
    reads. Confirm:false is suitable only after explicit prior approval, not a substitute for approval.
.EXAMPLE
    ./Remove-AnyoneLink.ps1 @auth -InputCsv ./reviewed-pilot.csv -OutputFolder ./pilot-execution `
        -ExpectedInputSha256 $approvedHash -Resume
    Read-only reconciliation after an uncertain mutation: same folder/input, WITHOUT Execute.
    A permission404 plus matching item200 can be observed, but dry-run does not add VERIFIED checkpoints.
    A still-present unresolved permission pauses; preserve receipts and investigate, never clear state.
.EXAMPLE
    ./Remove-AnyoneLink.ps1 @auth -InputCsv ./reviewed-pilot.csv -OutputFolder ./whatif-review -Execute -WhatIf
    Live reads/plan only. WhatIf forbids DELETE and never creates mutation checkpoints.
.NOTES
    Name: Remove-AnyoneLink.ps1; Version:1.1.0-preview.2; Date:2026-11-08; License:MIT.
    Requires PowerShell7.4+; no Graph SDK needed. Sequential raw REST, no hidden DELETE retries.
    Exit0: invocation finished (inspect mode/outcomes); exit1: paused/request/persistence failure;
    exit2: input/context/resume validation failure. A killed process may have no final summary:
    durable receipts, not a stale progress snapshot or exit code alone, decide recovery.
    Use an independent finite watchdog including suspension where supported. UTC/Stopwatch observations
    can reveal a discrepancy but cannot establish its cause. No background job is launched by this tool.
    CHANGELOG:1.1.0-preview.2 (2026-11-08): bounded timeout recovery, item-retention verification,
    fsynced request/mutation receipts, explicit Resume/context/hash gates, clock guard and complete help.
    Prior1.1.0-preview.1 (2026-11-07): guarded transport/progress preview;1.0.0 (2026-11-05): initial tool.
    SOURCES: Microsoft Learn permission-delete and Graph throttling (links below), checked2026-11-08.
    Documentation/API checks are not tenant tests; this version has offline evidence only.
.LINK
    https://learn.microsoft.com/graph/api/permission-delete?view=graph-rest-1.0
.LINK
    https://learn.microsoft.com/graph/throttling
.LINK
    README.md and docs/SAFETY_AND_PROGRESS.md
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
    [ValidateRange(0, 8)][int]$MaxReadRetries = 3,
    [ValidateRange(0, 6)][int]$MaxVerificationPolls = 3,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedInputSha256,
    [switch]$Resume,
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


$ScriptVersion = '1.1.0-preview.2'
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
$requestReceiptFile = Join-Path $OutputFolder 'request_receipts.jsonl'
$script:CurrentKey = ''; $script:CurrentPhase = 'initialization'
# A second process cannot share an output journal. The outer finally releases this lock even on exit.
try { $outputLock = [IO.FileStream]::new((Join-Path $OutputFolder 'execution.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
catch { Fail-Input 'OutputFolder is locked by another executor; stop rather than overlap.' }
try {

$runId = [guid]::NewGuid().ToString()
$runStarted = [datetime]::UtcNow
$runDeadline = $runStarted.AddSeconds($MaxRunSeconds)
$runClock = [Diagnostics.Stopwatch]::StartNew()


function Write-Log([string]$Msg, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f ([DateTimeOffset]::Now.ToString('o')), $Level, $Msg
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
if ($ExpectedInputSha256 -and $inputHash -ine $ExpectedInputSha256) { Fail-Input 'Input CSV does not match the explicitly approved SHA256.' }
# Resolve identity before resume can skip work: a checkpoint must never be reused for a different app/tenant.
if (-not $MockGraph) {
    $TenantId = Get-Value $TenantId 'TenantId' "($GuidRx)|($DomainRx)" 'Dedicated removal tenant.' 'GUID or domain'
    $ClientId = Get-Value $ClientId 'ClientId' $GuidRx 'Dedicated removal application.' 'GUID'
}
# A missing original hash is not permission to bind an old mutation journal to a new CSV.
if ((Test-Path $journalFile) -or (Test-Path $doneFile)) {
    if (-not (Test-Path (Join-Path $OutputFolder 'input_sha256.txt'))) { Fail-Input 'Existing execution evidence lacks its original input hash; preserve evidence and reconcile independently.' }
}
$contextFile = Join-Path $OutputFolder 'execution_context.json'
$contextWasMissing = -not (Test-Path $contextFile)
$context = @{SchemaVersion=2;MockGraph=[bool]$MockGraph;TenantId=$TenantId;ClientId=$ClientId}
if (Test-Path $contextFile) {
    $savedContext = Get-Content $contextFile -Raw | ConvertFrom-Json
    if ($savedContext.MockGraph -ne [bool]$MockGraph -or $savedContext.TenantId -ine $TenantId -or $savedContext.ClientId -ine $ClientId) { Fail-Input 'OutputFolder execution identity/mode changed; use a separate folder.' }
} else { $context | ConvertTo-Json | Set-Content $contextFile -WhatIf:$false }

$manifestFile = Join-Path $OutputFolder 'input_sha256.txt'
if (Test-Path $manifestFile) {
    if ((Get-Content $manifestFile -Raw).Trim() -ne $inputHash) { Fail-Input 'OutputFolder belongs to a different input hash; use a new folder.' }
} else { Set-Content -LiteralPath $manifestFile -Value $inputHash -WhatIf:$false }
$candidates = @($rows)
if ($RequireAnonymousEdit) {
    $candidates = @($candidates | Where-Object { Test-IsAnonymousEdit $_ })
}
# The durable journal is authoritative; done.txt is only a compatibility projection.
# Legacy checkpoints lacking item200 proof OR their original execution context are re-read, never trusted/replayed.
$doneSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pendingMutations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$confirmedMutations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$historicalFailureResponses = 0
if (Test-Path $journalFile) {
    if (-not $Resume) { Fail-Input 'Existing mutation journal requires -Resume with the same input and output folder.' }
    foreach ($line in [IO.File]::ReadLines($journalFile)) {
        try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { Fail-Input 'Malformed/truncated journal; preserve it and reconcile manually. Never reset it to retry.' }
        if (-not $inputKeys.Contains([string]$j.Key)) { Fail-Input 'Journal key is outside the hash-bound input.' }
        if ($j.Event -eq 'ATTEMPT') { [void]$pendingMutations.Add($j.Key) }
        elseif ($j.Event -eq 'RESPONSE') {
            if ([int]$j.Status -in @(200,202,204,404)) { [void]$confirmedMutations.Add($j.Key) }
            else { $historicalFailureResponses++ }
        } elseif ($j.Event -eq 'VERIFIED') {
            if (-not $contextWasMissing -and (Get-NoteProp $j 'ItemStatus') -eq 200 -and (Get-NoteProp $j 'VerifiedItemId') -ceq $j.Key.Split('|')[1] -and [int]$j.Status -eq 404) {
                [void]$doneSet.Add($j.Key); [void]$pendingMutations.Remove($j.Key)
            } else { [void]$pendingMutations.Add($j.Key) }
        }
    }
}
if (Test-Path $doneFile) {
    foreach ($key in [IO.File]::ReadLines($doneFile)) {
        if (-not $inputKeys.Contains($key)) { Fail-Input 'Legacy done key is not in the immutable input.' }
        if (-not $doneSet.Contains($key)) { [void]$pendingMutations.Add($key) }
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
    @{RunId=$runId;Mode='NO_PENDING';Total=0;Processed=0;Remaining=0;ResumedCompleted=$resumedCount;EligibleChecked=0;WouldDelete=0;DeletedVerified=0;AlreadyAbsent=0;Skipped=0;Errors=0;CurrentRunErrors=0;HistoricalFailureResponses=$historicalFailureResponses;AggregateVerified=$resumedCount;UnresolvedProcessed=0;Paused=$false;Completed=$true;ExecutionComplete=([bool]$Execute -and -not $WhatIfPreference -and $resumedCount -gt 0);UpdatedUtc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $summaryFile -WhatIf:$false
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
        if ($roles -contains $a -or ($a -eq '75359482-378d-4052-8f01-80520e7db3cd' -and $roles -contains 'Files.ReadWrite.All')) {
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
    $status = 0; $retry = $null; $safeReason = ''
    while ($queue.Count -gt 0 -and $seen.Count -lt 16) {
        $obj = $queue.Dequeue()
        if ($null -eq $obj -or -not $seen.Add($obj)) { continue }
        foreach ($name in @('StatusCode','ResponseStatusCode')) {
            $v = Get-NoteProp $obj $name
            if ($null -ne $v) { try { $status = [int]$v } catch {} }
        }
        $data = Get-NoteProp $obj 'Data'
        if ($data -and $data.Contains('SafeReason')) { $safeReason = [string]$data['SafeReason'] }
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
    return @{ StatusCode=$status; RetryAfter=$retry; SafeReason=$safeReason }
}
function Get-HttpStatusFromError($ErrorRecord) { return (Get-HttpFailureInfo $ErrorRecord).StatusCode }
function New-GraphFailure([int]$Status,[string]$RetryAfter,[string]$Kind) {
    $ex = [InvalidOperationException]::new("Graph $Kind HTTP $Status; paused/error, not success.")
    $ex.Data['StatusCode'] = $Status
    $ex.Data['SafeReason'] = $Kind # Internal reason only; never copy raw service error text into this field.
    if ($RetryAfter) { $ex.Data['RetryAfter'] = $RetryAfter }
    return $ex
}
function Assert-RunBudget {
    # Stopwatch is useful elapsed evidence, NOT a suspend-aware external watchdog. Compare UTC too;
    # a large clock discontinuity pauses rather than inventing a cause or extending the run silently.
    $wall = ([datetime]::UtcNow-$runStarted).TotalSeconds
    $elapsed = $runClock.Elapsed.TotalSeconds
    if ([math]::Abs($wall-$elapsed) -gt 60) { throw (New-GraphFailure 0 '' 'clock discontinuity; external supervision required') }
    if ([math]::Max($wall,$elapsed) -ge $MaxRunSeconds -or [datetime]::UtcNow -ge $runDeadline) { throw (New-GraphFailure 0 '' 'run budget exhausted') }
}
function Write-DurableJson([string]$Path,$Entry) {
    # WriteThrough + Flush(true) makes intent precede the network request on durable storage.
    # Failure here is fatal: losing a receipt must never fall through to another DELETE.
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Entry | ConvertTo-Json -Depth 6 -Compress)+[Environment]::NewLine)
    $fs = [IO.FileStream]::new($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try { $fs.Write($bytes,0,$bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}
function Add-RequestReceipt([string]$Method,[string]$Event,[int]$Status=0,[string]$ExceptionType='') {
    # Exact keys/phase/status are sufficient for recovery. No URI, token, headers/body or raw exception text.
    Write-DurableJson $requestReceiptFile @{SchemaVersion=2;RunId=$runId;Key=$script:CurrentKey;Phase=$script:CurrentPhase;Method=$Method;Event=$Event;Status=$Status;ExceptionType=$ExceptionType;Utc=[DateTimeOffset]::UtcNow.ToString('o')}
}
function Get-RetryDelay([string]$RetryAfter,[int]$Attempt) {
    if ($RetryAfter) {
        $seconds = 0
        if ([int]::TryParse($RetryAfter,[ref]$seconds)) { if ($seconds -lt 0) { throw (New-GraphFailure 429 '' 'negative Retry-After') }; return $seconds }
        $date = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($RetryAfter,[ref]$date)) { return [math]::Max(0,[math]::Ceiling(($date-[DateTimeOffset]::UtcNow).TotalSeconds)) }
        throw (New-GraphFailure 429 '' 'invalid Retry-After')
    }
    return [math]::Min(30,[math]::Pow(2,$Attempt))
}
function Wait-GraphRetry([string]$RetryAfter,[int]$Attempt) {
    Assert-RunBudget
    $seconds = Get-RetryDelay $RetryAfter $Attempt
    # Never shorten a server Retry-After to fit our budget: stop instead.
    if ($seconds -gt $MaxRetryDelaySeconds -or [datetime]::UtcNow.AddSeconds($seconds+$RequestTimeoutSeconds) -ge $runDeadline) {
        throw (New-GraphFailure 429 $RetryAfter 'retry budget exceeded')
    }
    Write-Log "Phase=$script:CurrentPhase backoff=${seconds}s; next operation rechecks current state, never blind DELETE replay." 'WARN'
    Start-Sleep -Seconds $seconds
}
function Invoke-Graph {
    param([ValidateSet('GET','DELETE')][string]$Method,[Parameter(Mandatory)][string]$Uri,[int]$MaxRetry=$MaxReadRetries)
    if ($MockGraph) { throw 'Transport is unavailable under MockGraph.' }
    $attempt = 0
    while ($true) {
        Assert-RunBudget
        $attempt++
        $token = Get-GraphToken $S
        $headers = @{ Authorization="Bearer $token"; 'User-Agent'="Remove-AnyoneLink/$ScriptVersion" }
        Add-RequestReceipt $Method 'INTENT'
        try {
            $resp = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers -SkipHttpErrorCheck `
                -ConnectionTimeoutSeconds $RequestTimeoutSeconds -OperationTimeoutSeconds $RequestTimeoutSeconds -ErrorAction Stop
        } catch {
            # DELETE has NO transport-layer retries. Only the caller may consider a new
            # mutation, after verifying absence/shape and applying the retry policy.
            $info = Get-HttpFailureInfo $_
            Add-RequestReceipt $Method 'EXCEPTION' $info.StatusCode $_.Exception.GetType().FullName
            if ($Method -eq 'GET' -and $info.StatusCode -in @(0,408,429,500,502,503,504) -and $attempt -le $MaxRetry) {
                Wait-GraphRetry $info.RetryAfter $attempt; continue
            }
            throw
        }
        $S.LastActivity = [datetime]::UtcNow
        $status = [int]$resp.StatusCode; $retry = $null
        Add-RequestReceipt $Method 'RESPONSE' $status
        try { $retry = [string](@($resp.Headers['Retry-After'])[0]) } catch {}
        if ($Method -eq 'GET' -and $status -in @(408,429,500,502,503,504) -and $attempt -le $MaxRetry) {
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

function Get-PermissionFresh([string]$DriveId, [string]$ItemId, [string]$LinkId, [string]$Phase='permission-precheck') {
    $script:CurrentKey = "$DriveId|$ItemId|$LinkId"; $script:CurrentPhase = $Phase
    if ($MockGraph) {
        if ($script:DeletedMock.Contains($LinkId)) { return $null }
        $node = Get-NoteProp $script:MockMap $LinkId
        if (-not $node) { return $null }
        # Reserved fixture fault, reachable ONLY under MockGraph; never live transport.
        $fault = Get-NoteProp $node '__mockGetStatus'
        if ($fault) { throw (New-GraphFailure ([int]$fault) '' 'offline fixture GET') }
        return $node
    }
    $uri = ("https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/permissions/{2}" -f [uri]::EscapeDataString($DriveId),[uri]::EscapeDataString($ItemId),[uri]::EscapeDataString($LinkId))
    # Invoke-Graph GET returns $null on 404 (permission already removed)
    return Invoke-Graph -Method GET -Uri $uri
}

function Test-PermissionAllowlisted($perm, [string]$ExpectedLinkId) {
    if (-not $perm) { return @{ Ok = $false; Reason = 'Permission not found (already removed or wrong id)' } }
    $liveId = [string](Get-NoteProp $perm 'id')
    if ($liveId -cne $ExpectedLinkId) { return @{ Ok = $false; Reason = "Permission id mismatch live='$liveId' expected='$ExpectedLinkId'" } }
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

function Add-MutationJournal([string]$Key,[string]$Event,[int]$Status=0,[string]$VerifiedItemId='') {
    $entry = @{SchemaVersion=2;Key=$Key;Event=$Event;Status=$Status;Utc=[DateTimeOffset]::UtcNow.ToString('o');RunId=$runId}
    if ($Event -eq 'VERIFIED') { $entry.ItemStatus=200; $entry.VerifiedItemId=$VerifiedItemId }
    Write-DurableJson $journalFile $entry
}
function Assert-ItemPresent([string]$DriveId,[string]$ItemId) {
    $script:CurrentPhase = 'item-verification'
    if ($MockGraph) {
        # The mock models item existence separately from deleted permissions, not as another deletion.
        return [pscustomobject]@{id=$ItemId}
    }
    $uri = 'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}?$select=id' -f [uri]::EscapeDataString($DriveId),[uri]::EscapeDataString($ItemId)
    $item = Invoke-Graph -Method GET -Uri $uri
    if ($null -eq $item -or (Get-NoteProp $item 'id') -cne $ItemId) { throw (New-GraphFailure 0 '' 'underlying item is not200 with matching ID') }
    return $item
}
function Confirm-PermissionGone([string]$DriveId,[string]$ItemId,[string]$LinkId) {
    for ($poll=0; $poll -le $MaxVerificationPolls; $poll++) {
        $after = Get-PermissionFresh $DriveId $ItemId $LinkId 'permission-verification'
        if ($null -eq $after) { $null=Assert-ItemPresent $DriveId $ItemId; return }
        $shape = Test-PermissionAllowlisted $after $LinkId
        if (-not $shape.Ok) { throw (New-GraphFailure 0 '' 'post-mutation shape changed; no replay') }
        if ($poll -lt $MaxVerificationPolls) { Wait-GraphRetry '' ($poll+1) }
    }
    throw (New-GraphFailure 0 '' 'permission still present after bounded verification; no replay')
}
function Remove-PermissionSafe([string]$DriveId,[string]$ItemId,[string]$LinkId) {
    $key = "$DriveId|$ItemId|$LinkId"
    $uri = ("https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/permissions/{2}" -f [uri]::EscapeDataString($DriveId),[uri]::EscapeDataString($ItemId),[uri]::EscapeDataString($LinkId))
    $attempt = 0
    while ($true) {
        $attempt++
        $perm = Get-PermissionFresh $DriveId $ItemId $LinkId 'immediate-predelete-check'
        if ($null -eq $perm) { return @{StatusCode=404;Skipped=$false;AlreadyAbsent=$true} }
        $check = Test-PermissionAllowlisted $perm $LinkId
        if (-not $check.Ok) { return @{StatusCode=0;Skipped=$true;Reason="Pre-DELETE recheck failed: $($check.Reason)"} }
        # Journal is written outside the transport catch: persistence failure MUST NOT be retried as a network error.
        Add-MutationJournal $key 'ATTEMPT'
        $script:CurrentKey=$key; $script:CurrentPhase='delete-exact-permission'; $del=$null; $transportError=$null
        try {
            if ($MockGraph) { [void]$script:DeletedMock.Add($LinkId); $del=[pscustomobject]@{StatusCode=204} }
            else { $del=Invoke-Graph -Method DELETE -Uri $uri -MaxRetry 0 }
        } catch { $transportError=$_ }
        if ($null -eq $transportError) {
            Add-MutationJournal $key 'RESPONSE' ([int]$del.StatusCode)
            # The caller verifies permission404 AND matching item200. Acknowledged deletion never reaches retry code.
            return @{StatusCode=[int]$del.StatusCode;Skipped=$false;AlreadyAbsent=($del.StatusCode -eq 404)}
        }
        $info=Get-HttpFailureInfo $transportError
        Add-MutationJournal $key 'RESPONSE' $info.StatusCode
        # Authorization and permanent errors stop immediately; retries never grant privileges or change membership.
        if ($info.StatusCode -notin @(0,408,429,500,502,503,504)) { throw (New-GraphFailure $info.StatusCode '' 'permanent DELETE failure') }
        # Retry-After constrains the NEXT request, including reconciliation GET, not only a second DELETE.
        Wait-GraphRetry $info.RetryAfter $attempt
        $after=Get-PermissionFresh $DriveId $ItemId $LinkId 'uncertain-delete-reconciliation'
        $null=Assert-ItemPresent $DriveId $ItemId
        if ($null -eq $after) { return @{StatusCode=$info.StatusCode;Skipped=$false;AlreadyAbsent=$false;Recovered=$true} }
        $check=Test-PermissionAllowlisted $after $LinkId
        if (-not $check.Ok) { throw (New-GraphFailure 0 '' 'ambiguous DELETE; shape changed') }
        # A transport timeout remains ambiguous even with a present replica: conservatively pause, never auto-resend.
        # Only explicit throttling/unavailable responses can use the configured retry count after reconciliation.
        if ($info.StatusCode -in @(429,503,504) -and $attempt -le $MaxDeleteRetries) { continue }
        throw (New-GraphFailure $info.StatusCode '' 'ambiguous DELETE; operator reconciliation required')
    }
}

# ---------- Incremental processing, durable checkpoints, truthful final counts ----------
$plan = [Collections.Generic.List[object]]::new()
$skipped = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
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
        HistoricalFailureResponses=$historicalFailureResponses;CurrentRunErrors=$failed
        UnresolvedProcessed=@($results | Where-Object Action -eq 'ERROR').Count
        AggregateVerified=($resumedCount+@($results | Where-Object {$_.Action -in @('DELETED','ALREADY_ABSENT') -and $_.VerifiedGone -eq $true}).Count)
        WallElapsedSeconds=([datetime]::UtcNow-$runStarted).TotalSeconds;StopwatchElapsedSeconds=$runClock.Elapsed.TotalSeconds
        ExecutionComplete=($mode -eq 'EXECUTE' -and -not $paused -and $processed -eq $candidates.Count -and @($results | Where-Object Action -in @('SKIP','ERROR','WOULD_DELETE')).Count -eq 0)

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
        Assert-RunBudget
        $driveId=[string]$r.DriveId; $itemId=[string]$r.ItemId; $linkId=[string]$r.LinkId
        $key="$driveId|$itemId|$linkId"
        Write-Log "[$($processed+1)/$($candidates.Count)] GET exact permission $linkId; checking current shape."
        $row=[pscustomobject]@{RunId=$runId;LinkId=$linkId;DriveId=$driveId;ItemId=$itemId;Action='';Status='';Detail='';VerifiedGone=''}
        try {
            $perm=Get-PermissionFresh $driveId $itemId $linkId 'candidate-precheck'
            if ($null -eq $perm) {
                $null=Assert-ItemPresent $driveId $itemId
                $row.Action='ALREADY_ABSENT';$row.Status=404;$row.Detail='Exact permission404 and matching item200; no DELETE required';$row.VerifiedGone=$true
                if ($mode -eq 'EXECUTE') {
                    Add-MutationJournal $key 'VERIFIED' 404 $itemId
                    # Compatibility projection follows the authoritative fsynced proof.
                    Add-Content $doneFile $key -WhatIf:$false -ErrorAction Stop
                }
                Save-Row $row;continue
            }
            if($pendingMutations.Contains($key)) {
                $priorReason=if($confirmedMutations.Contains($key)){'previous acknowledged DELETE still present; never replay; operator review required'}else{'unresolved previous mutation: permission still present; operator review required'}
                throw (New-GraphFailure 0 '' $priorReason)
            }
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
            Confirm-PermissionGone $driveId $itemId $linkId
            $row.Action=if($del.AlreadyAbsent){'ALREADY_ABSENT'}else{'DELETED'}
            $row.Status=$del.StatusCode;$row.Detail='Exact permission404 and matching underlying item200';$row.VerifiedGone=$true
            Add-MutationJournal $key 'VERIFIED' 404 $itemId
            # Checkpoint only confirmed terminal state; changed/inherited/error are never done.
            Add-Content $doneFile $key -WhatIf:$false -ErrorAction Stop
            Save-Row $row
            Write-Log "$($row.Action) $linkId; HTTP=$($row.Status), verified permission404/item200." 'OK'
        } catch {
            $failureInfo=Get-HttpFailureInfo $_; $status=$failureInfo.StatusCode
            $failed++;$paused=$true
            $row.Action='ERROR';$row.Status=$status
            $row.Detail=if($status -in @(401,403)){'Authorization failure: stop; do not add privileges automatically'}else{'Request/mutation/checkpoint failure: stop; inspect journal before any retry'}
            if ($failureInfo.SafeReason) { $row.Detail += '; SafePauseReason='+$failureInfo.SafeReason }
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
} finally { $outputLock.Dispose() }
