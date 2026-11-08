#Requires -Version 7.4
<#
.SYNOPSIS
Offline regression tests: extract functions without running auth/main; substitute ALL
HTTP calls with local response queues. Integration invocations ALWAYS use MockGraph.
No tenant/client/cert credentials are supplied or read. No Pester/install required.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$tool=Join-Path $root 'Remove-AnyoneLink.ps1'
$pwsh=(Get-Process -Id $PID).Path
$failed=0;$passed=0
function Check($ok,$name){if($ok){$script:passed++;Write-Host "PASS $name"}else{$script:failed++;Write-Host "FAIL $name"}}
$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$null,[ref]$null)
$names=@('Get-NoteProp','Get-HttpFailureInfo','Get-HttpStatusFromError','New-GraphFailure','Get-RetryDelay','Wait-GraphRetry','Invoke-Graph','Get-PermissionFresh','Test-PermissionAllowlisted','Add-MutationJournal','Remove-PermissionSafe','Assert-RunBudget','Write-DurableJson','Add-RequestReceipt','Assert-ItemPresent','Confirm-PermissionGone')
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
 if($fn.Name -in $names){. ([scriptblock]::Create($fn.Extent.Text))}
}
function Write-Log {param($Msg,$Level)}
function Get-GraphToken {param($S) return 'OFFLINE_FAKE_TOKEN'}
function Start-Sleep {param($Seconds) $script:waits+=,[double]$Seconds}
$MockGraph=$false;$MaxReadRetries=3;$MaxVerificationPolls=3;$MaxRunSeconds=300;$runStarted=[datetime]::UtcNow;$runClock=[Diagnostics.Stopwatch]::StartNew();$script:CurrentKey='';$script:CurrentPhase='offline';$ScriptVersion='offline-test';$RequestTimeoutSeconds=2;$MaxRetryDelaySeconds=60;$MaxDeleteRetries=1
$S=@{LastActivity=[datetime]::UtcNow};$runDeadline=[datetime]::UtcNow.AddMinutes(5);$runId='offline'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('removal-offline-'+[guid]::NewGuid())
New-Item -ItemType Directory $temp | Out-Null
$journalFile=Join-Path $temp 'journal.jsonl'
$requestReceiptFile=Join-Path $temp 'requests.jsonl'
function Reset-Queue($q){$script:queue=[Collections.Generic.Queue[object]]::new();foreach($v in $q){$script:queue.Enqueue($v)};$script:calls=@();$script:waits=@()}
function Invoke-WebRequest {
 param($Method,$Uri,$Headers,[switch]$SkipHttpErrorCheck,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,$ErrorAction)
 $script:calls+=,$Method
 if($script:queue.Count -eq 0){throw 'Offline response queue exhausted; network forbidden'}
 $v=$script:queue.Dequeue()
 if($v -is [Exception]){throw $v}
 return $v
}
function Response($status,$body='',$retry=''){
 $h=@{};if($retry -ne ''){$h['Retry-After']=@($retry)}
 return [pscustomobject]@{StatusCode=$status;Content=$body;Headers=$h}
}
$perm='{"id":"p1","link":{"scope":"anonymous","type":"edit"},"roles":["write"]}'
Reset-Queue @((Response 204));$x=Invoke-Graph DELETE 'https://graph.microsoft.com/v1.0/offline'
Check ($x.StatusCode -eq 204 -and $calls.Count -eq 1) '204 success is not absence/exception and DELETE sent once'
Reset-Queue @((Response 404));$x=Invoke-Graph GET 'https://graph.microsoft.com/v1.0/offline'
Check ($null -eq $x) 'explicit GET404 alone means absent'
Reset-Queue @((Response 200));$threw=$false;try{$null=Invoke-Graph GET 'https://graph.microsoft.com/v1.0/offline'}catch{$threw=$true}
Check $threw 'empty200 fails closed, never absent'
Reset-Queue @((Response 429 '' '0'),(Response 200 $perm));$x=Invoke-Graph GET 'https://graph.microsoft.com/v1.0/offline'
Check ($x.id -eq 'p1' -and $calls.Count -eq 2 -and $waits.Count -eq 1) 'GET429 honors RetryAfter and finite retry'
Reset-Queue @((Response 429 '' '999'));$threw=$false;try{$null=Invoke-Graph GET 'https://graph.microsoft.com/v1.0/offline'}catch{$threw=$true}
Check ($threw -and $calls.Count -eq 1 -and $waits.Count -eq 0) 'excessive RetryAfter stops instead of shortening server delay'
$future=[DateTimeOffset]::UtcNow.AddSeconds(20).ToString('r');$seconds=Get-RetryDelay $future 1
Check ($seconds -ge 18 -and $seconds -le 21) 'HTTP-date RetryAfter decoded'
$nested=[Exception]::new('offline',[Net.Http.HttpRequestException]::new('offline',$null,[Net.HttpStatusCode]::Forbidden))
Check ((Get-HttpStatusFromError $nested) -eq 403) 'nested exception HTTP status is unwrapped safely'
$e=New-GraphFailure 429 '12' 'offline';$info=Get-HttpFailureInfo $e
Check ($info.StatusCode -eq 429 -and $info.RetryAfter -eq '12') 'structured status and RetryAfter survive terminating throw'
Reset-Queue @((Response 401));$status=0;try{$null=Invoke-Graph GET 'https://graph.microsoft.com/v1.0/offline'}catch{$status=Get-HttpStatusFromError $_}
Check ($status -eq 401 -and $calls.Count -eq 1) 'authorization401 terminates without retry'
Reset-Queue @((Response 200 $perm),[TimeoutException]::new('offline'),(Response 404),(Response 200 '{"id":"i1"}'))
$x=Remove-PermissionSafe 'd1' 'i1' 'p1'
Check ($x.Recovered -and @($calls | Where-Object {$_ -eq 'DELETE'}).Count -eq 1) 'ambiguous timeout verified absent before any replay; only one DELETE'
Reset-Queue @((Response 200 $perm),(Response 429 '' '0'),(Response 200 $perm),(Response 200 '{"id":"i1"}'),(Response 200 $perm),(Response 204))
$x=Remove-PermissionSafe 'd1' 'i1' 'p1'
Check ($x.StatusCode -eq 204 -and ($calls -join ',') -eq 'GET,DELETE,GET,GET,GET,DELETE') 'mutation429 retry has verification AND full fresh allowlist first'
Reset-Queue @((Response 200 $perm),[TimeoutException]::new('offline'),(Response 200 $perm),(Response 200 '{"id":"i1"}'))
$threw=$false;try{$null=Remove-PermissionSafe 'd1' 'i1' 'p1'}catch{$threw=$true}
Check ($threw -and @($calls | Where-Object {$_ -eq 'DELETE'}).Count -eq 1) 'timeout with permission still present stops; no blind retry'
$x=('{"id":"p1","link":{"scope":"anonymous","type":"view"},"roles":["write"]}' | ConvertFrom-Json)
Check (-not (Test-PermissionAllowlisted $x 'p1').Ok) 'view link plus write role does not bypass strict edit guard'
# Integration checks in child processes avoid touching any real authentication.
function Run-Mock($folder,$extra=@(),$mockPath=''){
 $args=@('-NoProfile','-File',$tool,'-MockGraph','-InputCsv',(Join-Path $root 'mocks/sample_input.csv'),'-OutputFolder',$folder,'-NonInteractive')+$extra
 if($mockPath){$args+=@('-MockPermissionsPath',$mockPath)}
 if(Test-Path (Join-Path $folder 'mutation_journal.jsonl')){$args+='-Resume'}
 & $pwsh @args *> (Join-Path $temp 'last_integration.log')
 return $LASTEXITCODE
}
$out=Join-Path $temp 'execute';$code=Run-Mock $out @('-Execute','-Confirm:$false')
$summary=Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
Check ($code -eq 0 -and $summary.DeletedVerified -eq 2 -and $summary.Skipped -eq 1 -and $summary.Processed -eq 3) 'mock204 verification and truthful per-row final counts'
$code=Run-Mock $out @('-Execute','-Confirm:$false')
$summary=Get-Content (Join-Path $out 'summary.json') -Raw | ConvertFrom-Json
Check ($code -eq 0 -and $summary.ResumedCompleted -eq 2 -and $summary.DeletedVerified -eq 0) 'restart skips exactly verified checkpoints; no completed DELETE replay'
$dry=Join-Path $temp 'dry';$code=Run-Mock $dry
$summary=Get-Content (Join-Path $dry 'summary.json') -Raw | ConvertFrom-Json
Check ($summary.WouldDelete -eq 2 -and $summary.Processed -eq 3 -and -not(Test-Path (Join-Path $dry 'done.txt'))) 'dry-run progress includes skipped rows but creates no mutation checkpoints'
$map=Get-Content (Join-Path $root 'mocks/permissions.json') -Raw | ConvertFrom-Json
$map.aAAAAA1 | Add-Member '__mockGetStatus' 403
$fault=Join-Path $temp 'fault.json';$map | ConvertTo-Json -Depth 8 | Set-Content $fault
$auth=Join-Path $temp 'auth';$code=Run-Mock $auth @() $fault
$summary=Get-Content (Join-Path $auth 'summary.json') -Raw | ConvertFrom-Json
Check ($code -eq 1 -and $summary.Paused -and $summary.Processed -eq 1 -and $summary.Remaining -eq 2 -and $summary.Errors -eq 1) 'main auth403 stops cohort with nonzero exit and honest remaining/error counts'
$pending=Join-Path $temp 'pending';New-Item -ItemType Directory $pending | Out-Null
@{Key='b!MOCKDRIVEID|01ITEMEDIT000000000000000000000001|aAAAAA1';Event='ATTEMPT'} | ConvertTo-Json -Compress | Set-Content (Join-Path $pending 'mutation_journal.jsonl')
# Derive key from fixture rather than relying on its drive name.
$first=Import-Csv (Join-Path $root 'mocks/sample_input.csv') | Select-Object -First 1
@{Key=($first.DriveId+'|'+$first.ItemId+'|'+$first.LinkId);Event='ATTEMPT'} | ConvertTo-Json -Compress | Set-Content (Join-Path $pending 'mutation_journal.jsonl')
(Get-FileHash (Join-Path $root 'mocks/sample_input.csv') -Algorithm SHA256).Hash|Set-Content (Join-Path $pending 'input_sha256.txt')
$code=Run-Mock $pending @('-Execute','-Confirm:$false')
$summary=Get-Content (Join-Path $pending 'summary.json') -Raw | ConvertFrom-Json
Check ($code -eq 1 -and $summary.DeletedVerified -eq 0 -and $summary.Errors -eq 1) 'restart with unresolved mutation refuses deletion pending operator review'
Write-Host "Offline safety assertions: passed=$passed failed=$failed; artifacts=$temp"
if($failed){exit 1};exit 0
