$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('codex-deck-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$settings=Get-DeckSettings $fixture
$checkNow=[DateTimeOffset]::UtcNow
$manual=@{account7=$checkNow;account8=$checkNow.AddSeconds(60)}
$scheduled=@{account7=$checkNow.AddMinutes(10);account8=$checkNow.AddMinutes(-1)}
$due=@(Get-DeckDueAccounts @('account1','account7','account8','account9') $manual $scheduled $checkNow)
Assert ($due[0] -eq 'account7' -and $due -contains 'account9' -and $due -notcontains 'account8') 'Manual priority, disconnected profile, or refresh cooldown failed'
Assert (@(Get-DeckDueAccounts @() $manual $scheduled $checkNow).Count -eq 1) 'Manual refresh depends on automatic checks'
Assert (-not $settings.AutoCheck) 'Auto-check must default off'
$models=@(Get-DeckModelNames @('gpt-5.6-luna',@('gpt-5.6-sol','gpt-5.6-luna'),'System.Object[]'))
Assert ($models.Count -eq 2 -and $models[1] -eq 'gpt-5.6-sol') 'Nested model list was not flattened'
$namedSession=Register-DeckSession $fixture 'work-main' 'C:\example'
Assert (@(Get-DeckSessions $fixture | Where-Object Account -eq 'work-main').Count -eq 1) 'Custom account session missing'
Remove-Item -LiteralPath $namedSession
Assert (-not $settings.WarmupEnabled) 'Warm-up must default off'
Assert (-not $settings.WarmupSchedulingEnabled) 'Background warm-up scheduling must default off'
Assert (-not $settings.AlwaysOnTop) 'Always on top must default off'
Assert ($settings.ViewMode -eq 'Widget') 'Widget must be default'
Assert ($settings.Width -eq 476 -and $settings.WidgetWidth -eq 238 -and $settings.Height -eq 0 -and $settings.WidgetHeight -eq 0) 'Content-based geometry defaults failed'
$recoverySuite=Join-Path $fixture 'recovery-suite'
$recoveryAccount=Join-Path $recoverySuite 'accounts/account1'
[void][IO.Directory]::CreateDirectory($recoveryAccount)
[IO.File]::WriteAllText((Join-Path $recoveryAccount 'sentinel.txt'),'synthetic recovery test')
$rejected=$false; try{Move-DeckAccountToRecovery $recoverySuite '../outside'}catch{$rejected=$true}
Assert $rejected 'Recovery accepted traversal'
$connectedLease=Register-DeckSession (Join-Path $recoverySuite 'deck') 'account1' 'C:\example'
$refused=$false; try{Move-DeckAccountToRecovery $recoverySuite 'account1'}catch{$refused=$true}
Assert ($refused -and (Test-Path -LiteralPath $recoveryAccount)) 'Connected account deletion was allowed'
Remove-Item -LiteralPath $connectedLease
Move-DeckAccountToRecovery $recoverySuite 'account1'
Assert (-not (Test-Path -LiteralPath $recoveryAccount)) 'Recovery left the account in the picker directory'
$recovered=@(Get-ChildItem -LiteralPath (Join-Path $recoverySuite 'deleted-accounts') -Directory)
Assert ($recovered.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $recovered[0].FullName 'sentinel.txt')) -eq 'synthetic recovery test') 'Recovery lost account content'
$session=Register-DeckSession $fixture 'account12' 'C:\example'
Assert (@(Get-DeckSessions $fixture).Count -eq 1) 'Live wrapper missing'
$entry=Read-DeckJson $session; $entry.ProcessStartTicks=1; Write-DeckJson $session $entry
Assert (@(Get-DeckSessions $fixture).Count -eq 0) 'PID reuse/stale record was accepted'
Assert (-not (Test-Path -LiteralPath $session)) 'Stale lease not removed'
$settings.AutoCheck=$true; $settings.WarmupEnabled=$true; $settings.WarmupAccounts='account5'; $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$record=[pscustomobject]@{Account='account5';PlanType='plus';Status='available';Error=$null;Windows=@([pscustomobject]@{DurationSeconds=18000;UsedPct=0})}
Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'Eligible reset refused'
foreach($plan in 'free','unknown','go',''){
    $record.PlanType=$plan
    Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) "Excluded plan accepted: $plan"
}
$record.PlanType='plus'
foreach($state in 'blocked','unknown','error'){
    $record.Status=$state
    Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) "Bad state accepted: $state"
}
$record.Status='available'
foreach($reset in @($null,($now+60),($now-30),($now-3600))){Assert (-not (Test-DeckWarmup $settings $record $reset $null $now)) 'Invalid reset accepted'}
$record.Windows[0].UsedPct=1
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) 'Already active window warmed'
$record.Windows[0].UsedPct=0
$history=[pscustomobject]@{Reset=($now-90);AttemptAt=($now-10)}
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $history $now)) 'Duplicate warm-up accepted'
$history.Reset=$now-200
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $history $now)) 'Four-hour cooldown ignored'
$settings.WarmupAccounts='account7'
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) 'Unselected account warmed'
$settings.WarmupAllPaid=$true
Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'All paid selector missed unselected paid account'
$record.PlanType='free'
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) 'All paid selector included free account'
$record.PlanType='plus'; $settings.WarmupAllPaid=$false
$settings.WarmupAccounts='account5'; $settings.AutoCheck=$false
Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'Warm-up incorrectly depends on ordinary auto-check'
$settings.AutoCheck=$true
$record.Windows[0] | Add-Member NoteProperty ResetsAtUnix ($now+120)
$next=Get-DeckNextCheck $settings $record ([DateTimeOffset]::FromUnixTimeSeconds($now))
Assert ($next.ToUnixTimeSeconds() -eq ($now+180)) 'Reset check was not scheduled after grace'
$record.Status='error'
$next=Get-DeckNextCheck $settings $record ([DateTimeOffset]::FromUnixTimeSeconds($now))
Assert ($next.ToUnixTimeSeconds() -ge ($now+1200)) 'Reset scheduling bypassed error backoff'
$record.Status='available'
$settings.PollMinutes=1; $settings.MinimumGapSeconds=0
Write-DeckJson (Join-Path $fixture 'settings.json') $settings
$clamped=Get-DeckSettings $fixture
Assert ($clamped.PollMinutes -eq 5 -and $clamped.MinimumGapSeconds -eq 15) 'Request throttles not clamped'
$code=Get-DeckWarmupCode $PSScriptRoot account5 gpt-5.6-luna
Assert ($code -match '--ignore-user-config' -and $code -match '--sandbox read-only' -and $code -match '--ephemeral') 'Warm-up isolation missing'
$failed=$false; try{Get-DeckWarmupCode $PSScriptRoot '../outside' 'gpt-5.6-luna'}catch{$failed=$true}
Assert $failed 'Account injection accepted'
$failed=$false; try{Get-DeckWarmupCode $PSScriptRoot account5 "bad'; echo injected"}catch{$failed=$true}
Assert $failed 'Model injection accepted'
$task=Start-DeckTask "'synthetic worker output'" 'Test' 'account1'
Assert ($task.Process.WaitForExit(10000)) 'Worker did not finish'
Assert ($task.Out.Result.Trim() -eq 'synthetic worker output') 'Worker output lost'
$task.Process.Dispose()
$backgroundScript=Join-Path $fixture 'background worker.ps1'; $backgroundResult=Join-Path $fixture 'background-result.json'
[IO.File]::WriteAllText($backgroundScript,'[IO.File]::WriteAllText($env:CODEX_DECK_BACKGROUND_TEST,($args | ConvertTo-Json -Compress)); exit 0',[Text.UTF8Encoding]::new($false))
$oldBackgroundResult=$env:CODEX_DECK_BACKGROUND_TEST
try{
    $env:CODEX_DECK_BACKGROUND_TEST=$backgroundResult
    $background=Start-DeckBackgroundPowerShell $backgroundScript @('two words','model="quiet"','C:\path with space\')
    Assert (-not $background.StartInfo.UseShellExecute -and $background.StartInfo.CreateNoWindow -and $background.StartInfo.WindowStyle -eq 'Hidden') 'Background PowerShell can create a console window'
    Assert ($background.WaitForExit(10000) -and $background.ExitCode -eq 0) 'Background PowerShell did not finish'
    $background.Dispose()
}finally{$env:CODEX_DECK_BACKGROUND_TEST=$oldBackgroundResult}
$backgroundArguments=Get-Content -LiteralPath $backgroundResult -Raw | ConvertFrom-Json
Assert (($backgroundArguments -join '|') -eq 'two words|model="quiet"|C:\path with space\') 'Background PowerShell lost arguments'
$scheduledResult=Join-Path $fixture 'scheduled-background-result.json'
try{
    $env:CODEX_DECK_BACKGROUND_TEST=$scheduledResult
    $vbsInfo=[Diagnostics.ProcessStartInfo]::new()
    $vbsInfo.FileName=Join-Path $env:SystemRoot 'System32\wscript.exe'
    $vbsInfo.Arguments=(@('//B','//Nologo',(Join-Path $PSScriptRoot 'Deck.Background.vbs'),$backgroundScript,'scheduled worker') | ForEach-Object { ConvertTo-DeckProcessArgument ([string]$_) }) -join ' '
    $vbsInfo.UseShellExecute=$false; $vbsInfo.CreateNoWindow=$true; $vbsInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $vbsProcess=[Diagnostics.Process]::Start($vbsInfo)
    Assert ($vbsProcess.WaitForExit(10000) -and $vbsProcess.ExitCode -eq 0) 'Scheduled background launcher did not finish'
    $vbsProcess.Dispose()
}finally{$env:CODEX_DECK_BACKGROUND_TEST=$oldBackgroundResult}
$scheduledArguments=Get-Content -LiteralPath $scheduledResult -Raw | ConvertFrom-Json
Assert (($scheduledArguments -join '|') -eq 'scheduled worker') 'Scheduled background launcher lost arguments'
foreach($file in @('Deck.Core.ps1','Deck.WarmupWorker.ps1','Codex-Deck.ps1','../.local/bin/codex-auth.ps1')){
    $tokens=$null; $errors=$null
    $path=Join-Path $PSScriptRoot $file
    if(-not (Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot '../bin/codex-auth.ps1'}
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Parse failed: $file / $errors"
}
'PASS: defaults, PID identity/cleanup, paid-only warm-up, reset grace/expiry, deduplication, cooldown, opt-in, throttles, injection guards, worker execution, script parsing.'
"Synthetic test state: $fixture"

$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$healthy=[pscustomobject]@{RemainingPct=80;Dead=$false;ResetsAtUnix=$now+600}
$empty=[pscustomobject]@{RemainingPct=0;Dead=$true;ResetsAtUnix=$now+600}
$low=[pscustomobject]@{RemainingPct=10;Dead=$false;ResetsAtUnix=$now+600}
Assert ((Get-DeckQuotaColor $healthy) -eq '#69DEC0' -and (Get-DeckQuotaColor $empty) -eq '#F17D8D' -and (Get-DeckQuotaColor $low) -eq '#DCB675') 'Quota colors are not independent'
$health=[pscustomobject]@{Status='available';CheckedAt=[DateTimeOffset]::Now.AddDays(-2);Windows=@($healthy,$empty)}
Assert ((Get-DeckHealth $health) -eq 'Exhausted') 'Active exhausted limit hidden'
$empty.ResetsAtUnix=$now-1
Assert ((Get-DeckHealth $health) -eq 'Reset passed') 'Expired quota presented as current exhaustion'
$health.Windows=@($healthy)
Assert ((Get-DeckHealth $health) -eq 'Ready') 'Successful quota was replaced by an age label'
'PASS: independent health colors, reset freshness and connected-account deletion guard.'

$persisted=[pscustomobject]@{Account='account9';Status='available';CheckedAt='2026-09-06T12:00:00Z';Windows=@([pscustomobject]@{RemainingPct=42})}
$cachePath=Join-Path $fixture 'restart-cache.json'
Write-DeckJson $cachePath @($persisted)
$restored=@(Expand-DeckCheckRecords (Read-DeckJson $cachePath))
Assert ($restored.Count -eq 1 -and $restored[0].CheckedAt -eq $persisted.CheckedAt -and $restored[0].Windows[0].RemainingPct -eq 42) 'Restart lost check details'
Write-DeckJson $cachePath @(@{value=@($persisted);Count=1})
$restored=@(Expand-DeckCheckRecords (Read-DeckJson $cachePath))
Assert ($restored.Count -eq 1 -and $restored[0].Account -eq 'account9') 'Legacy array cache not recovered'
$legacyHistory=@(@{Account='account1';Outcome='Replied: hi'},@{value=@(@{Account='account2';Outcome='Request failed'});Count=1})
$historyMap=ConvertTo-DeckMap $legacyHistory
Assert ($historyMap.Count -eq 2 -and $historyMap.account2.Outcome -eq 'Request failed') 'Nested legacy warm-up history not recovered'
$flat=@{account1=$historyMap.account1;account2=$historyMap.account2}; Write-DeckJson $cachePath @(Get-DeckMapValues $flat)
Assert (-not ([IO.File]::ReadAllText($cachePath) -match '"value"\s*:')) 'Hashtable values serialized as a nested wrapper'
'PASS: persisted check details and legacy array-wrapper recovery.'

$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$fresh=@{Windows=@(@{DurationSeconds=18000;UsedPct=0;ResetsAtUnix=$now+17910})}
Assert ((Get-DeckWarmupReset $fresh $null $now) -eq ($now-90)) 'Fresh empty window was not discovered'
Assert ((Get-DeckWarmupReset $fresh ($now-120) $now) -eq ($now-120)) 'Observed reset was replaced by inferred reset'
$fresh.Windows[0].UsedPct=1
Assert ($null -eq (Get-DeckWarmupReset $fresh $null $now)) 'Used window inferred as empty'
$fresh.Windows[0].UsedPct=0; $futureBoundary=$now+18000
$fresh.Windows[0].ResetsAtUnix=$futureBoundary
Assert ((Get-DeckWarmupReset $fresh $futureBoundary $now) -eq $futureBoundary) 'Known future reset was reinterpreted as a fresh window start'
$settings=Get-DeckDefaults; $settings.WarmupEnabled=$true; $settings.WarmupAllPaid=$true
$fresh=@{Account='account1';PlanType='plus';Status='available';Windows=@(@{DurationSeconds=18000;UsedPct=0},@{DurationSeconds=604800;UsedPct=100})}
Assert (-not (Test-DeckWarmup $settings $fresh ($now-90) $null $now)) 'Exhausted weekly quota warmed'
'PASS: fresh-window discovery, observed reset preservation and exhausted weekly guard.'

Assert (-not (Get-DeckDefaults).AutoStart) 'Desktop auto-opening must be opt-in'
$scheduleSettings=Get-DeckDefaults; $scheduleSettings.WarmupEnabled=$true; $scheduleSettings.WarmupResetEnabled=$true; $scheduleSettings.WarmupGraceSeconds=60
$scheduleNow=[DateTimeOffset]'2026-09-09T20:00:00-03:00'; $scheduleReset=$scheduleNow.ToUnixTimeSeconds()+600
$scheduleCache=@{account1=[pscustomobject]@{Status='available';Error=$null;Windows=@([pscustomobject]@{DurationSeconds=18000;ResetsAtUnix=$scheduleReset})}}
$nextWarm=Get-DeckNextWarmupRun $scheduleSettings @('account1') $scheduleCache @{} @{} $scheduleNow
Assert ($nextWarm.ToUnixTimeSeconds() -eq $scheduleReset+60) 'Next reset wake was not scheduled precisely after grace'
$blockedReset=$scheduleReset+604800
$scheduleCache.account1.Status='blocked'; $scheduleCache.account1.Windows+=@([pscustomobject]@{DurationSeconds=604800;UsedPct=100;Dead=$true;ResetsAtUnix=$blockedReset})
$nextBlocked=Get-DeckNextWarmupRun $scheduleSettings @('account1') $scheduleCache @{} @{} $scheduleNow
Assert ($nextBlocked.ToUnixTimeSeconds() -eq $blockedReset+60) 'Exhausted account kept a one-minute warm-up retry loop'
$scheduleCache.account1.Status='available'; $scheduleCache.account1.Windows=@($scheduleCache.account1.Windows | Select-Object -First 1)
$scheduleSettings.WarmupResetEnabled=$false
Assert ($null -eq (Get-DeckNextWarmupRun $scheduleSettings @('account1') $scheduleCache @{} @{} $scheduleNow)) 'Reset-disabled settings created a reset wake'
Assert ((ConvertTo-DeckWarmupTimes '19:00,08:00 08:00') -eq '08:00, 19:00') 'Daily times normalization failed'
$invalid=$false; try{ConvertTo-DeckWarmupTimes '24:00'}catch{$invalid=$true}; Assert $invalid 'Invalid time accepted'
Assert (@(Get-DeckDueWarmupTimes '23:59' ([DateTimeOffset]'2026-09-08T00:01:00-03:00'))[0] -eq '20260907-2359') 'Midnight catch-up failed'
Assert (@(Get-DeckDueWarmupTimes '08:00' ([DateTimeOffset]'2026-09-08T08:05:00-03:00')).Count -eq 0) 'Expired daily slot fired'
$replyEvent='{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}'
Assert (-not (Get-DeckWarmupReply $replyEvent)) 'Incomplete reply counted as success'
Assert ((Get-DeckWarmupReply ($replyEvent+"`n"+'{"type":"turn.completed"}')) -eq 'hi') 'Completed reply missing'
Assert (-not (Get-DeckWarmupReply ($replyEvent+"`n"+'{"type":"turn.failed"}'))) 'Failed turn counted as success'
$queueSuite=Join-Path $env:TEMP ('deck-queue-'+[guid]::NewGuid().ToString('N'))
Write-DeckJson (Join-Path $queueSuite 'accounts/account1/auth.json') @{}
$ws=Get-DeckDefaults; $ws.WarmupEnabled=$true; $ws.WarmupTimedEnabled=$true; $ws.WarmupTimes='08:00'; $ws.WarmupAccounts='account1'
$at=[DateTimeOffset]'2026-09-08T08:01:00-03:00'
Add-DeckTimedWarmups $queueSuite $ws @('account1') @{account1=@{PlanType='plus'}} $at
$queued=Join-Path $queueSuite 'deck/warmup-requests/account1.json'
Assert (Test-Path $queued) 'Daily warm-up not queued'
Remove-Item -LiteralPath $queued
Add-DeckTimedWarmups $queueSuite $ws @('account1') @{account1=@{PlanType='plus'}} $at
Assert (-not (Test-Path $queued)) 'Daily slot repeated after queue consumption'
Request-DeckWarmup $queueSuite 'account1' -NoStart
$ws.WarmupEnabled=$false; $workers=@{}; $warmHistory=@{}
function Start-DeckTask($Code,$Kind,$Account){return @{Kind=$Kind;Account=$Account}}
Invoke-DeckQueuedWarmups $queueSuite $ws $workers $warmHistory ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
Assert ($workers.account1.Kind -eq 'Warm-up' -and $warmHistory.account1.Mode -eq 'Manual') 'Manual warm-up blocked by automatic pause'
'PASS: daily slots, midnight catch-up, persisted deduplication, manual background queue and confirmed replies.'

$scheduledSuite=Join-Path $fixture 'scheduled-suite'; [void][IO.Directory]::CreateDirectory($scheduledSuite)
[IO.File]::WriteAllText((Join-Path $scheduledSuite 'Deck.WarmupWorker.ps1'),'exit 0',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $scheduledSuite 'Deck.Background.vbs'),"' synthetic launcher",[Text.UTF8Encoding]::new($false))
$script:removedTaskNames=@(); $script:registeredTask=$null; $script:failTaskRegistration=$true
function Remove-ItemProperty { [CmdletBinding()]param([string]$Path,[string]$Name); }
function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess=$true)]param([string]$TaskName); $script:removedTaskNames+=$TaskName }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn,[string]$User,[switch]$Daily,[switch]$Once,[datetime]$At,[timespan]$RepetitionDuration,[timespan]$RepetitionInterval); [pscustomobject]@{AtLogOn=$AtLogOn;User=$User;Daily=$Daily;Once=$Once;At=$At;RepetitionDuration=$RepetitionDuration;RepetitionInterval=$RepetitionInterval} }
function New-ScheduledTaskAction { param([string]$Execute,[string]$Argument,[string]$WorkingDirectory); [pscustomobject]@{Execute=$Execute;Argument=$Argument;Arguments=$Argument;WorkingDirectory=$WorkingDirectory} }
function New-ScheduledTaskPrincipal { param([string]$UserId,[string]$LogonType,[string]$RunLevel); [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,[string]$MultipleInstances,[timespan]$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries); [pscustomobject]@{StartWhenAvailable=$StartWhenAvailable} }
function Register-ScheduledTask { param([string]$TaskName,$Action,$Trigger,$Settings,$Principal,[string]$Description,[switch]$Force); if($script:failTaskRegistration){throw 'Synthetic registration failure'}; $script:registeredTask=[pscustomobject]@{TaskName=$TaskName;Action=$Action;Trigger=$Trigger;Principal=$Principal;Description=$Description} }
$script:healthTask=$null; $script:healthNext=[datetime]::Now.AddHours(1)
function Get-ScheduledTask { [CmdletBinding()]param([string]$TaskName); if(-not $script:healthTask){throw 'Synthetic missing task'}; return $script:healthTask }
function Get-ScheduledTaskInfo { [CmdletBinding()]param([string]$TaskName); return [pscustomobject]@{NextRunTime=$script:healthNext} }
$scheduledSettings=Get-DeckDefaults; $scheduledSettings.WarmupEnabled=$true; $scheduledSettings.WarmupSchedulingEnabled=$true; $scheduledSettings.WarmupStartAtLogin=$true
$registrationFailed=$false; try{Sync-DeckWarmupStartup $scheduledSuite $scheduledSettings ([DateTimeOffset]::Now.AddHours(1))}catch{$registrationFailed=$true}
Assert ($registrationFailed -and $removedTaskNames.Count -eq 0) 'Failed task migration removed the working legacy schedule'
$script:failTaskRegistration=$false
Sync-DeckWarmupStartup $scheduledSuite $scheduledSettings ([DateTimeOffset]::Now.AddHours(1))
Assert ($removedTaskNames -contains 'CodexDeck Automatic Warm-up') 'Legacy warm-up task was not removed'
Assert ($registeredTask.TaskName -eq 'CodexDeck Warmup Scheduling') 'Warm-up task does not have a clear identity'
Assert ($registeredTask.Principal.LogonType -eq 'Interactive') 'Warm-up task uses an unexpected principal'
Assert ($registeredTask.Action.Execute -match 'wscript\.exe$' -and $registeredTask.Action.Argument -match '//B' -and $registeredTask.Action.Argument -match 'Deck\.Background\.vbs') 'Scheduled worker bypasses the windowless launcher'
Assert (@($registeredTask.Trigger | Where-Object { $_.RepetitionInterval.TotalMinutes -eq 15 }).Count -eq 1) 'Warm-up task has no persistent watchdog trigger'
$script:healthTask=[pscustomobject]@{State='Ready';Actions=@($registeredTask.Action)}
Assert (Test-DeckWarmupScheduleHealthy $scheduledSuite $scheduledSettings) 'Healthy warm-up task was rejected'
$script:healthTask=$null; Assert (-not (Test-DeckWarmupScheduleHealthy $scheduledSuite $scheduledSettings)) 'Missing warm-up task was accepted'
$script:registeredTask=$null; Assert ((Repair-DeckWarmupSchedule $scheduledSuite $scheduledSettings) -and $registeredTask) 'Missing warm-up task was not repaired'
$script:registeredTask=$null; $script:removedTaskNames=@(); $scheduledSettings.WarmupSchedulingEnabled=$false
$script:healthTask=[pscustomobject]@{State='Ready';Actions=@($registeredTask.Action)}
Assert (-not (Test-DeckWarmupScheduleHealthy $scheduledSuite $scheduledSettings)) 'Opted-out settings treated an existing background task as healthy'
Assert (Repair-DeckWarmupSchedule $scheduledSuite $scheduledSettings) 'Opted-out background task was not repaired by removal'
Assert ($null -eq $registeredTask -and $removedTaskNames -contains 'CodexDeck Warmup Scheduling') 'Opted-out settings retained or recreated the background task'
'PASS: background processes stay console-free, scheduling is explicit, and its task has a clear identity.'
