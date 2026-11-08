#Requires -Version 7.4
<#
.SYNOPSIS
    Fault-inject the public raw-REST preview offline, including crash/resume and help contracts.
.DESCRIPTION
    Extracts actual functions from the script AST without executing its authentication/main body.
    Every HTTP request is replaced with a local queue; child integration runs always use MockGraph.
    No credentials, token acquisition, SDK connection or real tenant request is performed.
    Uses temporary synthetic fixtures only. Passing this suite is NOT live validation.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$tool=Join-Path $root 'Remove-AnyoneLink.ps1';$pwsh=(Get-Process -Id $PID).Path
$passed=0;$failed=0
function Check($ok,$name){if($ok){$script:passed++;Write-Host "PASS $name"}else{$script:failed++;Write-Host "FAIL $name"}}
$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$null,[ref]$parseErrors)
Check (@($parseErrors).Count -eq 0) 'public preview parses cleanly'
$functions=@('Get-NoteProp','Get-HttpFailureInfo','Get-HttpStatusFromError','New-GraphFailure','Get-RetryDelay','Wait-GraphRetry','Invoke-Graph','Get-PermissionFresh','Test-PermissionAllowlisted','Add-MutationJournal','Remove-PermissionSafe','Assert-RunBudget','Write-DurableJson','Add-RequestReceipt','Assert-ItemPresent','Confirm-PermissionGone','Assert-TokenRoles')
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
 if($fn.Name -in $functions){. ([scriptblock]::Create($fn.Extent.Text))}
}
function Write-Log {param($Msg,$Level)}
function Get-GraphToken {param($S) return 'OFFLINE_FAKE_TOKEN'}
function Start-Sleep {param($Seconds) $script:waits+=,[double]$Seconds}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('public-reliability-'+[guid]::NewGuid());$null=[IO.Directory]::CreateDirectory($temp)
$MockGraph=$false;$ScriptVersion='offline-only';$MaxReadRetries=3;$MaxVerificationPolls=3;$MaxRunSeconds=300
$RequestTimeoutSeconds=2;$MaxRetryDelaySeconds=60;$MaxDeleteRetries=1;$S=@{LastActivity=[datetime]::UtcNow};$runId='offline'
$script:CurrentKey='d1|i1|p1';$script:CurrentPhase='offline'
function Reset-Fixture($q){
 $script:queue=[Collections.Generic.Queue[object]]::new();foreach($v in $q){$script:queue.Enqueue($v)}
 $script:calls=@();$script:waits=@();$script:runStarted=[datetime]::UtcNow;$script:runDeadline=$script:runStarted.AddSeconds(300);$script:runClock=[Diagnostics.Stopwatch]::StartNew()
 $script:journalFile=Join-Path $temp ([guid]::NewGuid().ToString()+'.journal.jsonl')
 $script:requestReceiptFile=Join-Path $temp ([guid]::NewGuid().ToString()+'.requests.jsonl')
}
function Invoke-WebRequest {
 param($Method,$Uri,$Headers,[switch]$SkipHttpErrorCheck,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,$ErrorAction)
 $script:calls+=,[pscustomobject]@{Method=$Method;Uri=$Uri;Connect=$ConnectionTimeoutSeconds;Operation=$OperationTimeoutSeconds}
 if(!$script:queue.Count){throw 'OFFLINE_QUEUE_EXHAUSTED_NO_NETWORK_ALLOWED'}
 $v=$script:queue.Dequeue();if($v -is [Exception]){throw $v};return $v
}
function Response($status,$body='',$retry=''){$h=@{};if($retry -ne ''){$h['Retry-After']=@($retry)};return [pscustomobject]@{StatusCode=$status;Content=$body;Headers=$h}}
function Delete-Count {return @($script:calls|Where-Object Method -eq 'DELETE').Count}
function Expect-Throw($code,$name){$threw=$false;try{& $code}catch{$threw=$true};Check $threw $name}
$perm='{"id":"p1","link":{"scope":"anonymous","type":"edit"}}';$item='{"id":"i1"}'
Reset-Fixture @([TimeoutException]::new('FAKE_SENSITIVE_BODY'),(Response 200 $perm));$x=Get-PermissionFresh 'd1' 'i1' 'p1'
Check ($x.id -eq 'p1' -and $calls.Count -eq 2 -and $waits.Count -eq 1) 'transport GET timeout recovers within explicit read retry budget'
$receipts=Get-Content $requestReceiptFile -Raw
Check ($receipts -notmatch 'FAKE_SENSITIVE_BODY|OFFLINE_FAKE_TOKEN|Authorization|https://') 'durable request receipts suppress raw exception/body/auth/URI'
Check (($receipts -split "`n"|Where-Object {$_}).Count -eq 4) 'intent and response/exception receipt per request attempt'
Check ($calls[0].Connect -eq 2 -and $calls[0].Operation -eq 2) 'both HTTP timeout controls are passed to real transport boundary'
Reset-Fixture @([TimeoutException]::new('offline'),[TimeoutException]::new('offline'),[TimeoutException]::new('offline'),[TimeoutException]::new('offline'))
Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'read timeout exhaustion pauses'
Check ($calls.Count -eq 4 -and (Delete-Count) -eq 0 -and ($waits -join ',') -eq '2,4,8') 'exactly four GET attempts and bounded exponential delays; no mutation'
Reset-Fixture @([TimeoutException]::new('offline'),(Response 404),[TimeoutException]::new('offline'),(Response 200 $item))
Confirm-PermissionGone 'd1' 'i1' 'p1'
Check ($calls.Count -eq 4 -and (Delete-Count) -eq 0) 'both permission and item verification timeouts recover with READ retries'
Reset-Fixture @((Response 200 $perm),(Response 204),(Response 200 $perm),(Response 404),(Response 200 $item))
$x=Remove-PermissionSafe 'd1' 'i1' 'p1';Confirm-PermissionGone 'd1' 'i1' 'p1'
Check ((Delete-Count) -eq 1 -and $waits.Count -eq 1) 'acknowledged DELETE204 plus replica lag uses reads, never mutation replay'
Reset-Fixture @((Response 200 $perm),(Response 204),(Response 200 $perm),(Response 200 $perm),(Response 200 $perm),(Response 200 $perm))
$x=Remove-PermissionSafe 'd1' 'i1' 'p1';Expect-Throw {Confirm-PermissionGone 'd1' 'i1' 'p1'} 'confirmed DELETE still present after bounded polls pauses'
Check ((Delete-Count) -eq 1) 'confirmed mutation remains single despite verification exhaustion'
Reset-Fixture @((Response 200 $perm),[TimeoutException]::new('offline'),(Response 404),(Response 200 $item))
$x=Remove-PermissionSafe 'd1' 'i1' 'p1'
Check ($x.Recovered -and (Delete-Count) -eq 1) 'DELETE timeout applied reconciles permission404 and matching item200'
Reset-Fixture @((Response 200 $perm),[TimeoutException]::new('offline'),(Response 200 $perm),(Response 200 $item))
Expect-Throw {Remove-PermissionSafe 'd1' 'i1' 'p1'} 'DELETE timeout not-applied/present conservatively pauses'
Check ((Delete-Count) -eq 1) 'ambiguous timeout is never automatically resent even when a replica remains present'
Reset-Fixture @((Response 200 $perm),[TimeoutException]::new('offline'),[TimeoutException]::new('offline'),[TimeoutException]::new('offline'),[TimeoutException]::new('offline'),[TimeoutException]::new('offline'))
Expect-Throw {Remove-PermissionSafe 'd1' 'i1' 'p1'} 'DELETE timeout unknown after GET exhaustion pauses'
Check ((Delete-Count) -eq 1) 'unknown server state never permits a second DELETE'
Reset-Fixture @((Response 200 $perm),(Response 429 '' '7'),(Response 200 $perm),(Response 200 $item),(Response 200 $perm),(Response 204))
$x=Remove-PermissionSafe 'd1' 'i1' 'p1'
Check ((Delete-Count) -eq 2 -and $waits[0] -eq 7 -and ($calls.Method -join ',') -eq 'GET,DELETE,GET,GET,GET,DELETE') 'DELETE429 honors RetryAfter before reconciliation and retries only after item check + fresh shape'
foreach($status in @(408,429,500,502,503,504)){
 Reset-Fixture @((Response $status '' '0'),(Response 200 $perm));$x=Get-PermissionFresh 'd1' 'i1' 'p1'
 Check ($calls.Count -eq 2 -and $x.id -eq 'p1') "transient GET$status recovers"
}
foreach($status in @(400,401,403,405)){
 Reset-Fixture @((Response $status));Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} "permanent GET$status stops"
 Check ($calls.Count -eq 1 -and (Delete-Count) -eq 0) "GET$status has no retry or mutation"
}
Reset-Fixture @((Response 200 $perm),(Response 403));Expect-Throw {Remove-PermissionSafe 'd1' 'i1' 'p1'} 'DELETE403 stops immediately'
Check ($calls.Count -eq 2) 'no read or mutation after authorization denial'
Reset-Fixture @((Response 429 '' '999'));Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'excessive RetryAfter pauses'
Check ($waits.Count -eq 0 -and $calls.Count -eq 1) 'server backoff never shortened to fit client budget'
Reset-Fixture @((Response 429 '' '-1'));Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'negative RetryAfter rejected'
Reset-Fixture @((Response 429 '' 'not-a-date'));Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'invalid RetryAfter rejected'
$seconds=Get-RetryDelay ([DateTimeOffset]::UtcNow.AddSeconds(20).ToString('r')) 1
Check ($seconds -ge 18 -and $seconds -le 21) 'HTTP-date RetryAfter supported'
Reset-Fixture @((Response 404),(Response 200 '{"id":"WRONG"}'));Expect-Throw {Confirm-PermissionGone 'd1' 'i1' 'p1'} 'missing permission plus WRONG item cannot become verified'
Reset-Fixture @((Response 404),(Response 404));Expect-Throw {Confirm-PermissionGone 'd1' 'i1' 'p1'} 'item404 is not proof item retained'
Reset-Fixture @((Response 200 '{malformed'));Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'malformed200 is not absence or transient retry'
Check ($calls.Count -eq 1) 'malformed JSON does not get silently retried'
Reset-Fixture @((Response 200 $perm));$script:journalFile=$temp
Expect-Throw {Remove-PermissionSafe 'd1' 'i1' 'p1'} 'failed durable intent persistence stops'
Check ((Delete-Count) -eq 0) 'no DELETE before its intent can be durably recorded'
Reset-Fixture @();$script:runStarted=[datetime]::UtcNow.AddSeconds(120)
Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'wall/elapsed discontinuity pauses without assumed root cause'
Check ($calls.Count -eq 0) 'clock guard stops before network'
Reset-Fixture @();$script:runDeadline=[datetime]::UtcNow.AddSeconds(-1)
Expect-Throw {Get-PermissionFresh 'd1' 'i1' 'p1'} 'expired run budget stops before network'
# Integration: same public main, synthetic one-row or many-row input, child always MockGraph.
$sample=Import-Csv (Join-Path $root 'mocks/sample_input.csv')|Select-Object -First 1
$csv=Join-Path $temp 'one.csv';$sample|Export-Csv $csv -NoTypeInformation
$fixture=Join-Path $temp 'empty.json';'{}'|Set-Content $fixture
$key=$sample.DriveId+'|'+$sample.ItemId+'|'+$sample.LinkId
function New-RunFolder {$folder=Join-Path $temp ([guid]::NewGuid().ToString());$null=[IO.Directory]::CreateDirectory($folder);return $folder}
function Run-Mock($folder,$extra=@(),$inputPath=$csv,$map=''){
 $args=@('-NoProfile','-File',$tool,'-MockGraph','-InputCsv',$inputPath,'-OutputFolder',$folder,'-NonInteractive')+$extra
 if($map){$args+=@('-MockPermissionsPath',$map)}
 & $pwsh @args *> (Join-Path $temp 'last-child.log');return $LASTEXITCODE
}
function Write-CrashJournal($folder,[bool]$withResponse,[bool]$withVerified=$false){
 (Get-FileHash $csv -Algorithm SHA256).Hash|Set-Content (Join-Path $folder 'input_sha256.txt')
 @{SchemaVersion=2;MockGraph=$true;TenantId='';ClientId=''}|ConvertTo-Json|Set-Content (Join-Path $folder 'execution_context.json')
 $entries=@(@{Key=$key;Event='ATTEMPT';Status=0})
 if($withResponse){$entries+=@{Key=$key;Event='RESPONSE';Status=204}}
 if($withVerified){$entries+=@{Key=$key;Event='VERIFIED';Status=404;ItemStatus=200;VerifiedItemId=$sample.ItemId}}
 $entries|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content (Join-Path $folder 'mutation_journal.jsonl')
}
foreach($responseRecorded in @($false,$true)){
 $out=New-RunFolder;Write-CrashJournal $out $responseRecorded
 $code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false') $csv $fixture
 $summary=Get-Content (Join-Path $out 'summary.json') -Raw|ConvertFrom-Json
 $journal=@(Get-Content (Join-Path $out 'mutation_journal.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
 Check ($code -eq 0 -and $summary.AlreadyAbsent -eq 1 -and $summary.ExecutionComplete) "crash after DELETE intent/response=$responseRecorded reconciles exact absent permission plus item"
 Check (@($journal|Where-Object Event -eq 'ATTEMPT').Count -eq 1) 'crash recovery sends no new DELETE intent'
}
$out=New-RunFolder;Write-CrashJournal $out $true $true
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false')
$summary=Get-Content (Join-Path $out 'summary.json') -Raw|ConvertFrom-Json
Check ($code -eq 0 -and $summary.ResumedCompleted -eq 1 -and $summary.Processed -eq 0) 'crash after VERIFIED but before done.txt skips journal-proven key'
$out=New-RunFolder;Write-CrashJournal $out $true
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false')
$summary=Get-Content (Join-Path $out 'summary.json') -Raw|ConvertFrom-Json
Check ($code -eq 1 -and $summary.Paused -and $summary.DeletedVerified -eq 0) 'present permission after prior DELETE204 pauses, never replays confirmed mutation'
$out=New-RunFolder;Write-CrashJournal $out $true
$code=Run-Mock $out @('-Execute','-Confirm:$false')
Check ($code -eq 2) 'existing journal requires explicit Resume'
$out=New-RunFolder;(Get-FileHash $csv -Algorithm SHA256).Hash|Set-Content (Join-Path $out 'input_sha256.txt');'{"Key":'|Set-Content (Join-Path $out 'mutation_journal.jsonl')
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false')
Check ($code -eq 2) 'truncated journal fails input validation before any auth/mutation'
$out=New-RunFolder;$code=Run-Mock $out @('-Execute','-Confirm:$false','-ExpectedInputSha256',('0'*64))
Check ($code -eq 2 -and -not(Test-Path (Join-Path $out 'mutation_journal.jsonl'))) 'independently approved hash mismatch stops before mutation'
$out=New-RunFolder;$dupe=Join-Path $temp 'duplicate.csv';@($sample,$sample)|Export-Csv $dupe -NoTypeInformation
$code=Run-Mock $out @('-Execute','-Confirm:$false') $dupe
Check ($code -eq 2) 'duplicate exact input keys rejected'
# A sizeable synthetic prior cohort proves restart exclusion is set-based, not a one-row special case.
$out=New-RunFolder;$manyCsv=Join-Path $temp 'many.csv';$many=@();$proofs=@()
foreach($i in 1..173){$many+=[pscustomobject]@{DriveId='fixture-drive';ItemId="item-$i";LinkId="permission-$i";Scope='anonymous';LinkType='edit'};$proofs+=@{Key="fixture-drive|item-$i|permission-$i";Event='VERIFIED';Status=404;ItemStatus=200;VerifiedItemId="item-$i"}}
$many|Export-Csv $manyCsv -NoTypeInformation
(Get-FileHash $manyCsv -Algorithm SHA256).Hash|Set-Content (Join-Path $out 'input_sha256.txt')
@{SchemaVersion=2;MockGraph=$true;TenantId='';ClientId=''}|ConvertTo-Json|Set-Content (Join-Path $out 'execution_context.json')
$proofs|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content (Join-Path $out 'mutation_journal.jsonl')
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false') $manyCsv
$summary=Get-Content (Join-Path $out 'summary.json') -Raw|ConvertFrom-Json
Check ($code -eq 0 -and $summary.ResumedCompleted -eq 173 -and $summary.Processed -eq 0) 'all173 synthetic prior VERIFIED keys excluded; no substitutes'
Check (-not(Test-Path (Join-Path $out 'request_receipts.jsonl'))) 'fully checkpointed cohort needs no new request'
$out=New-RunFolder;$lock=[IO.FileStream]::new((Join-Path $out 'execution.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{$code=Run-Mock $out @('-Execute','-Confirm:$false')}finally{$lock.Dispose()}
Check ($code -eq 2) 'concurrent executor cannot acquire same output journal'
# A legacy/moved journal without identity context cannot provide trusted skip proof.
$out=New-RunFolder;Write-CrashJournal $out $true $true
[IO.File]::Delete((Join-Path $out 'execution_context.json'))
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false')
$summary=Get-Content (Join-Path $out 'summary.json') -Raw|ConvertFrom-Json
Check ($code -eq 1 -and $summary.ResumedCompleted -eq 0 -and $summary.DeletedVerified -eq 0) 'missing context forces read reconciliation, never a trusted skip or mutation replay'
$out=New-RunFolder
@{SchemaVersion=2;MockGraph=$false;TenantId='contoso.onmicrosoft.com';ClientId='00000000-0000-0000-0000-000000000000'}|ConvertTo-Json|Set-Content (Join-Path $out 'execution_context.json')
$code=Run-Mock $out @('-Execute','-Confirm:$false')
Check ($code -eq 2) 'mock/live identity context mismatch blocks reuse before authentication'
$out=New-RunFolder;Write-CrashJournal $out $false
@{Key=$key;Event='RESPONSE';Status=0}|ConvertTo-Json -Compress|Add-Content (Join-Path $out 'mutation_journal.jsonl')
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false') $csv $fixture
$summary=Get-Content (Join-Path $out 'summary.json') -Raw|ConvertFrom-Json
Check ($code -eq 0 -and $summary.HistoricalFailureResponses -eq 1 -and $summary.CurrentRunErrors -eq 0 -and $summary.AlreadyAbsent -eq 1) 'recovered historical failure remains distinct from current errors and verified outcome'
$out=New-RunFolder;Write-CrashJournal $out $true
[IO.File]::Delete((Join-Path $out 'input_sha256.txt'))
$code=Run-Mock $out @('-Execute','-Resume','-Confirm:$false') $csv $fixture
Check ($code -eq 2) 'missing original hash anchor cannot silently bind prior execution evidence to a new input'
# Token role tests use a SYNTHETIC unsigned payload only; there is no request/token acquisition.
$AllowedPermissionIds=@('883ea226-0bf2-4a8f-9f9d-92c9162a727d');$DeniedPermissionIds=@('a82116e5-55eb-4c41-a434-62fe8a61c773','0c0bf378-bf22-4481-8f81-9e89a9b4960a')
function Fake-Jwt($role){$payload=(@{roles=@($role)}|ConvertTo-Json -Compress);$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_');return 'offline.'+$encoded+'.unsigned'}
Expect-Throw {Assert-TokenRoles (Fake-Jwt 'Files.ReadWrite.All')} 'a narrower Sites.Selected allowlist does not silently accept Files.ReadWrite.All'
$threw=$false;try{Assert-TokenRoles (Fake-Jwt 'Sites.Selected')}catch{$threw=$true}
Check (-not $threw) 'explicitly allowed Sites.Selected role is accepted without any grant change'
Expect-Throw {Assert-TokenRoles (Fake-Jwt 'Sites.FullControl.All')} 'canonical denied role wins over allowlist'

# Help must describe every declared parameter, plus examples/recovery/evidence/restore limits.
$raw=Get-Content $tool -Raw
foreach($parameter in $ast.ParamBlock.Parameters){$name=$parameter.Name.VariablePath.UserPath;Check ($raw -match ('(?m)^\.PARAMETER '+[regex]::Escape($name)+'\s*$')) "complete help section for $name"}
foreach($section in @('SYNOPSIS','DESCRIPTION','INPUTS','OUTPUTS','NOTES','LINK','EXAMPLE')){Check ($raw -match ('(?m)^\.'+$section+'\s*$')) "help includes $section"}
Check ($raw -match 'OFFLINE-TESTED ONLY' -and $raw -match 'distinct SDK') 'help does not claim private SDK results validate public REST'
Check ($raw -match 'RESTORE LIMIT' -and $raw -match 'not guaranteed recoverable') 'help explains sharing URL undo limit'
Write-Host "Public reliability assertions: passed=$passed failed=$failed; offline artifacts=$temp"
if($failed){exit 1};exit 0
