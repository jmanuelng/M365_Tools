#Requires -Version 7.4
<#
.SYNOPSIS
    Local syntax + mock behavior + privacy scrub tests for Remove-AnyoneLink.ps1 (no tenant auth).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Script = Join-Path $Root 'Remove-AnyoneLink.ps1'
$Grant = Join-Path $Root 'Grant-SitesSelectedWrite.ps1'
$MockCsv = Join-Path $Root 'mocks/sample_input.csv'
$Failed = 0

function Assert-True($cond, $msg) {
    if (-not $cond) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:Failed++ }
    else { Write-Host "PASS: $msg" -ForegroundColor Green }
}
function Get-ExitCode {
    if (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue) {
        return [int]$global:LASTEXITCODE
    }
    return 0
}

Write-Host "=== Parse ===" -ForegroundColor Cyan
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errs)
Assert-True ($null -eq $errs -or $errs.Count -eq 0) 'Remove-AnyoneLink parser reports zero errors'
$errsG = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Grant, [ref]$null, [ref]$errsG)
Assert-True ($null -eq $errsG -or $errsG.Count -eq 0) 'Grant-SitesSelectedWrite parser reports zero errors'

Write-Host "=== Help / version contract ===" -ForegroundColor Cyan
& $Script -Help | Out-Null
Assert-True ((Get-ExitCode) -eq 0) '-Help exits cleanly'
$raw = Get-Content -LiteralPath $Script -Raw
Assert-True ($raw -match 'TENANT-AGNOSTIC / PUBLISH-SAFE CONTRACT') 'comment-based help states publish-safe contract'
Assert-True ($raw -match "ScriptVersion = '1\.0\.0'") 'ScriptVersion is 1.0.0'

Write-Host "=== Mock dry-run (default: no DELETE) ===" -ForegroundColor Cyan
$out1 = Join-Path $Root 'output/test_dryrun'
if (Test-Path $out1) { Remove-Item -Recurse -Force $out1 }
& $Script -MockGraph -InputCsv $MockCsv -OutputFolder $out1 -NonInteractive | Out-Null
$code1 = (Get-ExitCode)
Assert-True ($code1 -eq 0) "dry-run exit 0 (got $code1)"
Assert-True (Test-Path (Join-Path $out1 'would_delete.csv')) 'would_delete.csv written'
Assert-True (Test-Path (Join-Path $out1 'skipped.csv')) 'skipped.csv written (view/org/inherited)'
$results1 = Import-Csv (Join-Path $out1 'removal_results.csv')
Assert-True (@($results1 | Where-Object Action -eq 'DELETED').Count -eq 0) 'dry-run produced zero DELETED rows'
Assert-True (@($results1 | Where-Object Action -eq 'WOULD_DELETE').Count -ge 1) 'dry-run planned at least one WOULD_DELETE'
$log1 = Get-ChildItem $out1 -Filter 'run_*.log' | Select-Object -First 1
Assert-True ($null -ne $log1) 'run log exists'
Assert-True ((Get-Content $log1.FullName -Raw) -match 'MockGraph enabled') 'log notes MockGraph'

Write-Host "=== Mock -Execute -Confirm:`$false ===" -ForegroundColor Cyan
$out2 = Join-Path $Root 'output/test_execute'
if (Test-Path $out2) { Remove-Item -Recurse -Force $out2 }
& $Script -MockGraph -InputCsv $MockCsv -OutputFolder $out2 -NonInteractive -Execute -Confirm:$false | Out-Null
$code2 = (Get-ExitCode)
Assert-True ($code2 -eq 0) "execute mock exit 0 (got $code2)"
$results2 = Import-Csv (Join-Path $out2 'removal_results.csv')
$deleted = @($results2 | Where-Object Action -eq 'DELETED')
Assert-True ($deleted.Count -ge 1) 'execute mock deleted at least one allowlisted link'
Assert-True (@($deleted | Where-Object { $_.VerifiedGone -eq 'True' -or $_.VerifiedGone -eq $true }).Count -eq $deleted.Count) 'all DELETED rows verified gone'
$skip2 = Import-Csv (Join-Path $out2 'skipped.csv')
Assert-True (@($skip2 | Where-Object Reason -match 'inherited').Count -ge 1) 'inherited permission skipped'
$allInput = Import-Csv $MockCsv
$preFilteredOut = @($allInput | Where-Object { -not ( ($_.Scope -eq 'anonymous') -and ( ($_.LinkType -eq 'edit') -or ($_.Roles -match 'write') ) ) })
Assert-True ($preFilteredOut.Count -ge 2) 'sample CSV includes non-anonymous-edit rows filtered before processing'
Assert-True (@($results2 | Where-Object LinkId -in @($preFilteredOut.LinkId)).Count -eq 0) 'filtered non-targets never deleted'

Write-Host "=== -WhatIf with -Execute still dry ===" -ForegroundColor Cyan
$out3 = Join-Path $Root 'output/test_whatif'
if (Test-Path $out3) { Remove-Item -Recurse -Force $out3 }
& $Script -MockGraph -InputCsv $MockCsv -OutputFolder $out3 -NonInteractive -Execute -WhatIf | Out-Null
$results3 = Import-Csv (Join-Path $out3 'removal_results.csv')
Assert-True (@($results3 | Where-Object Action -eq 'DELETED').Count -eq 0) '-WhatIf blocks DELETE even with -Execute'

Write-Host "=== NonInteractive missing InputCsv fails clear ===" -ForegroundColor Cyan
$out4 = Join-Path $Root 'output/test_missing'
& pwsh -NoProfile -File $Script -NonInteractive -OutputFolder $out4 2>$null | Out-Null
$code4 = (Get-ExitCode)
Assert-True ($code4 -eq 2) "missing params NonInteractive exit 2 (got $code4)"

Write-Host "=== Scrub: no private tenant markers in PUBLIC folder ===" -ForegroundColor Cyan
# Needles as separate strings so this file does not self-match one big regex.
$needles = @(
    'onecontact', 'ocontact', '2816154e', '38678b0e', 'manuel.nieto',
    'OCI-SPO-', '/workspace/shared/forge/secrets', 'pilot_sites_selected'
)
$bad = [System.Collections.Generic.List[string]]::new()
$product = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            $_.FullName -notmatch '[\\/]output[\\/]' -and
            $_.FullName -notmatch '[\\/]tests[\\/]' -and
            $_.Name -notmatch '\.log$'
        }
)
foreach ($f in $product) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    foreach ($n in $needles) {
        if ($text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            [void]$bad.Add("$($f.Name) contains $n")
        }
    }
    if ($text -match 'canc[uú]n') { [void]$bad.Add("$($f.Name) contains cancun marker") }
}
Assert-True ($bad.Count -eq 0) $(if ($bad.Count -eq 0) { 'no private markers in public folder' } else { 'private markers: ' + ($bad -join ' | ') })

if ($Failed -gt 0) {
    Write-Host "`n$Failed test(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nAll local tests PASSED" -ForegroundColor Green
exit 0
