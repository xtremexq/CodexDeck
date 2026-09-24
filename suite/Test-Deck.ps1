$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('codex-deck-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$settings=Get-DeckSettings $fixture
Assert ($settings.AutoCompactMode -eq 'Native') 'Auto-compact implementation must default to Codex native'
Assert ($settings.AutoCompactThresholdPercent -eq 55) 'Auto-compact threshold must default to 55%'
Assert (-not $settings.AutoCompactLaunchEnabled) 'Auto-compact launches must default off'
Assert ($settings.ContextOptimizer -eq 'Off' -and -not $settings.CodeGraphEnabled -and $settings.CodeGraphProfile -eq 'core') 'Managed integrations must default to off with the small CodeGraph profile'
Assert (-not $settings.Contains('UizzeMcpEnabled')) 'Paid UIZZE reference search must not appear in Deck settings'
Assert ($settings.AutoCompactHandoffPrompt -match 'DECK_HANDOFF') 'Default handoff prompt must require the checkpoint marker'
Assert ($settings.AutoCompactHandoffPrompt -eq 'Context is nearing the configured limit. At the next safe point, write a visible task-state handoff beginning with DECK_HANDOFF: with what you''re currently doing, objective, work completed, verified findings, decisions and constraints, unresolved questions, and next steps. Be concise while preserving important information. Also list all references, paths, function names, etc. that will "definitely" be useful/necessary for continuing, as to avoid the need for re-investigation.') 'Default handoff prompt is incorrect'
Assert (-not $settings.TrajectoryEnabled -and -not $settings.ContextManagerEnabled -and $settings.EfficiencyAnalyticsEnabled) 'Trajectory/context must remain opt-in and efficiency analytics must default on'
Assert (-not $settings.ContextManagerAutoOpen -and $settings.EfficiencySessionLimit -eq 600) 'Context auto-open must default off and efficiency must analyze 600 sessions by default'
Write-DeckJson (Join-Path $fixture 'settings.json') @{EfficiencySessionLimit=5000;EfficiencyLimitVersion=2}
Assert ((Get-DeckSettings $fixture).EfficiencySessionLimit -eq 5000) 'Efficiency must allow a 5000-session limit'
Remove-Item -LiteralPath (Join-Path $fixture 'settings.json')
$legacySettings=Join-Path $fixture 'settings.json'
Write-DeckJson $legacySettings @{EfficiencySessionLimit=200}
Assert ((Get-DeckSettings $fixture).EfficiencySessionLimit -eq 600) 'The old saved 200-session default was not upgraded'
Write-DeckJson $legacySettings @{EfficiencySessionLimit=200;EfficiencyLimitVersion=2}
Assert ((Get-DeckSettings $fixture).EfficiencySessionLimit -eq 200) 'An explicitly saved new-version limit of 200 was not retained'
Write-DeckJson $legacySettings @{EfficiencySessionLimit=1000;EfficiencyLimitVersion=2}
Assert ((Get-DeckSettings $fixture).EfficiencySessionLimit -eq 600 -and (Get-DeckSettings $fixture).EfficiencyLimitVersion -eq 3) 'The old saved 1000-session default was not upgraded'
Write-DeckJson $legacySettings @{EfficiencySessionLimit=1000;EfficiencyLimitVersion=3}
Assert ((Get-DeckSettings $fixture).EfficiencySessionLimit -eq 1000) 'A newly chosen 1000-session limit was not retained'
Remove-Item -LiteralPath $legacySettings
Assert ((Get-DeckInspectorMarkerId 'C:\synthetic\marker.json') -eq 'bbb109b158ae51aad899ea44') 'Inspector marker IDs must match the Node inspector session identity'
Assert (-not (Test-DeckInspectorHealth ([pscustomobject]@{ok=$true;pid=123}) ([pscustomobject]@{ProcessId=123}) 'expected')) 'A pre-update inspector must be restarted'
Assert (-not (Test-DeckInspectorHealth ([pscustomobject]@{ok=$true;pid=123;version='old'}) ([pscustomobject]@{ProcessId=123}) 'expected')) 'A stale inspector version must be restarted'
Assert (Test-DeckInspectorHealth ([pscustomobject]@{ok=$true;pid=123;version='expected'}) ([pscustomobject]@{ProcessId=123}) 'expected') 'A matching inspector version must be reused'
$launchSuite=Join-Path $fixture 'inspector-launch'
$launchDeck=Join-Path $launchSuite 'deck'
[void][IO.Directory]::CreateDirectory($launchDeck)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deck.Inspector.cjs') -Destination (Join-Path $launchSuite 'Deck.Inspector.cjs')
Write-DeckJson (Join-Path $launchDeck 'settings.json') @{TrajectoryEnabled=$true;ContextManagerEnabled=$true}
$launchHealth=$null
function Get-FileHash { throw 'Get-FileHash is unavailable in this shell.' }
try {
    $launchUrl=Open-DeckInspector $launchSuite 'Trajectory' -NoOpen
    $launchHealth=Invoke-RestMethod -Uri ($launchUrl.Replace('/trajectory','/health')) -TimeoutSec 5
    Assert ($launchHealth.ok -and $launchHealth.version -eq (Get-DeckInspectorVersion (Join-Path $launchSuite 'Deck.Inspector.cjs'))) 'Inspector failed without Get-FileHash'
    $companionUrl=Open-DeckInspector $launchSuite 'Trajectory' -Companion -SessionPath (Join-Path $launchDeck 'sessions/terminal.json') -NoOpen
    Assert ($companionUrl -match '/context\?live=[a-f0-9]{24}$') 'Live Context launcher failed without Get-FileHash'
} finally {
    Remove-Item Function:Get-FileHash -ErrorAction SilentlyContinue
    if($launchHealth -and $launchHealth.pid){Stop-Process -Id $launchHealth.pid -ErrorAction SilentlyContinue}
}
$settings=Set-DeckAutoCompactLaunch $fixture $true
Assert ($settings.AutoCompactLaunchEnabled -and (Get-DeckSettings $fixture).AutoCompactLaunchEnabled) 'Shared auto-compact launch toggle was not persisted'
$settings=Set-DeckAutoCompactLaunch $fixture $false
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
$compactControl='http://127.0.0.1:65534/'+('a'*64)+'/compact'
Set-DeckSessionCompactControl $namedSession $compactControl
Assert ((Read-DeckJson $namedSession).CompactUrl -eq $compactControl) 'Interactive session did not record its compaction control'
Set-DeckSessionCompactControl $namedSession 'http://example.com/compact'
Assert ((Read-DeckJson $namedSession).CompactUrl -eq $compactControl) 'Session accepted a nonlocal compaction control'
$sessionRead=Start-DeckSessionRead $fixture
Assert (@(Complete-DeckSessionRead $sessionRead | Where-Object Account -eq 'work-main').Count -eq 1) 'Background session refresh lost a live session'
Remove-Item -LiteralPath $namedSession
Assert (-not $settings.WarmupEnabled) 'Warm-up must default off'
Assert (-not $settings.WarmupSchedulingEnabled) 'Background warm-up scheduling must default off'
Assert (-not $settings.AlwaysOnTop) 'Always on top must default off'
Assert ($settings.ViewMode -eq 'Widget') 'Widget must be default'
Assert ($settings.DashboardTheme -eq 'Default') 'Terminal dashboard theme must default to the original layout'
Assert ($settings.Width -eq 400 -and $settings.WidgetWidth -eq 238 -and $settings.Height -eq 0 -and $settings.WidgetHeight -eq 0) 'Content-based geometry defaults failed'
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
$record.PlanType='free'; $record.Windows=@([pscustomobject]@{DurationSeconds=2592000;UsedPct=0})
Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'Selected Free account was not eligible on its primary window'
Assert ((Get-DeckWarmupWindow $record).DurationSeconds -eq 2592000) 'Free warm-up did not select its primary allowance window'
Assert (-not (Get-DeckWarmupModel $settings free)) 'Free warm-up forced the paid-plan model'
foreach($plan in 'unknown',''){
    $record.PlanType=$plan
    Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) "Excluded plan accepted: $plan"
}
$record.PlanType='plus'; $record.Windows=@([pscustomobject]@{DurationSeconds=18000;UsedPct=0})
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
$settings.WarmupPlanTypes='paid'
Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'Paid account-type selector missed an unselected Plus account'
$record.PlanType='free'
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) 'Paid account-type selector included Free'
$record.Windows=@([pscustomobject]@{DurationSeconds=2592000;UsedPct=0}); $settings.WarmupPlanTypes='free,paid'
Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'Multi-select scope missed Free'
$settings.WarmupPlanTypes='all'; Assert (Test-DeckWarmup $settings $record ($now-90) $null $now) 'All account types missed Free'
Assert ((ConvertTo-DeckWarmupPlanTypes 'paid,free,free') -eq 'free,paid') 'Warm-up account types were not normalized'
$record.PlanType='plus'; $record.Windows=@([pscustomobject]@{DurationSeconds=18000;UsedPct=0}); $settings.WarmupPlanTypes=''
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
Assert ($code -match '--ignore-user-config' -and $code -match "'--sandbox','read-only'" -and $code -match '--ephemeral' -and $code -match "'-m','gpt-5.6-luna'") 'Paid warm-up isolation or model selection missing'
$freeCode=Get-DeckWarmupCode $PSScriptRoot account2 ''
Assert ($freeCode -notmatch "'-m'") 'Free warm-up forced a configured model'
$failed=$false; try{Get-DeckWarmupCode $PSScriptRoot '../outside' 'gpt-5.6-luna'}catch{$failed=$true}
Assert $failed 'Account injection accepted'
$failed=$false; try{Get-DeckWarmupCode $PSScriptRoot account5 "bad'; echo injected"}catch{$failed=$true}
Assert $failed 'Model injection accepted'
$task=Start-DeckTask "Start-Sleep -Milliseconds 200; 'synthetic worker output'" 'Test' 'account1'
Assert ($task.Process.WaitForExit(10000)) 'Worker did not finish'
Assert ($task.Out.Result.Trim() -eq 'synthetic worker output') 'Worker output lost'
Assert ($task.Job) 'Worker process tree was not assigned to a cleanup job'
Dispose-DeckTask $task
$checkTask=Start-DeckCheckTask "Start-Sleep -Milliseconds 200; 'async check output'" 'account1'
Assert ($checkTask.Launch -and -not $checkTask.Process) 'Check process was launched on the caller thread'
$checkDeadline=[DateTimeOffset]::UtcNow.AddSeconds(10)
while(-not (Test-DeckTaskReady $checkTask) -and [DateTimeOffset]::UtcNow -lt $checkDeadline){Start-Sleep -Milliseconds 20}
Assert ($checkTask.Process -and $checkTask.Process.ExitCode -eq 0 -and $checkTask.Out.Result.Trim() -eq 'async check output') 'Background check launch or output failed'
Dispose-DeckTask $checkTask
$cachePath=Join-Path $fixture 'async-cache.json'
$jsonWrite=Start-DeckJsonWrite $cachePath @([pscustomobject]@{Account='account1';Status='available'})
Assert ($jsonWrite.Handle -and $jsonWrite.Writer) 'Usage cache serialization did not start in a background runspace'
Complete-DeckJsonWrite $jsonWrite
Assert ((Read-DeckJson $cachePath)[0].Account -eq 'account1') 'Background usage cache write lost a record'
$moduleTask=Start-DeckTask 'Get-FileHash -LiteralPath $PSHOME\powershell.exe | Select-Object -ExpandProperty Algorithm' 'Test' ''
Assert ($moduleTask.Process.WaitForExit(10000)) 'Worker module check did not finish'
Assert ($moduleTask.Process.ExitCode -eq 0 -and $moduleTask.Out.Result.Trim() -eq 'SHA256') 'Windows PowerShell worker inherited an incompatible module path'
Dispose-DeckTask $moduleTask
$errorTask=Start-DeckTask "throw 'Synthetic integration failure'" 'Test' ''
Assert ($errorTask.Process.WaitForExit(10000)) 'Worker error check did not finish'
Assert ((Get-DeckTaskFailureMessage $errorTask) -eq 'Synthetic integration failure') 'Worker CLIXML error was not decoded'
Dispose-DeckTask $errorTask
$treeCode='$child=Start-Process powershell.exe -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep -Seconds 30'' -PassThru; [Console]::Out.WriteLine($child.Id)'
$treeTask=Start-DeckTask $treeCode 'Test' 'account1'
Assert ($treeTask.Process.WaitForExit(10000)) 'Process-tree parent did not finish'
$treeDeadline=[DateTimeOffset]::UtcNow.AddSeconds(5)
while(-not $treeTask.Out.IsCompleted -and [DateTimeOffset]::UtcNow -lt $treeDeadline){Start-Sleep -Milliseconds 50}
Assert ($treeTask.Out.IsCompleted) 'Process-tree output did not drain'
$childPid=[int]$treeTask.Out.Result.Trim(); Dispose-DeckTask $treeTask; Start-Sleep -Milliseconds 200
$childAlive=$false; try{$childProcess=Get-Process -Id $childPid -ErrorAction Stop;$childAlive=$true;$childProcess.Dispose()}catch{}
Assert (-not $childAlive) 'Disposing a worker left its child process alive'
$backgroundScript=Join-Path $fixture 'background worker.ps1'; $backgroundResult=Join-Path $fixture 'background-result.json'
[IO.File]::WriteAllText($backgroundScript,'[void](Get-FileHash -LiteralPath $PSHOME\powershell.exe); [IO.File]::WriteAllText($env:CODEX_DECK_BACKGROUND_TEST,($args | ConvertTo-Json -Compress)); exit 0',[Text.UTF8Encoding]::new($false))
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
$moduleScript=Join-Path $fixture 'background-module.ps1'; $moduleResult=Join-Path $fixture 'background-module.txt'
[IO.File]::WriteAllText($moduleScript,'[IO.File]::WriteAllText($args[0],(Get-FileHash -LiteralPath $PSHOME\powershell.exe).Algorithm)',[Text.UTF8Encoding]::new($false))
$previousModulePath=$env:PSModulePath
try {
    $env:PSModulePath='C:\invalid-power-shell-modules'
    $moduleProcess=Start-DeckBackgroundPowerShell $moduleScript @($moduleResult)
    Assert ($moduleProcess.WaitForExit(10000) -and $moduleProcess.ExitCode -eq 0) 'Background PowerShell inherited an incompatible module path'
    $moduleProcess.Dispose()
} finally { $env:PSModulePath=$previousModulePath }
Assert ([IO.File]::ReadAllText($moduleResult) -eq 'SHA256') 'Background PowerShell could not load built-in modules'
$scheduledResult=Join-Path $fixture 'scheduled-background-result.json'
$previousModulePath=$env:PSModulePath
try{
    $env:CODEX_DECK_BACKGROUND_TEST=$scheduledResult
    $env:PSModulePath='C:\invalid-power-shell-modules'
    $vbsInfo=[Diagnostics.ProcessStartInfo]::new()
    $vbsInfo.FileName=Join-Path $env:SystemRoot 'System32\wscript.exe'
    $vbsInfo.Arguments=(@('//B','//Nologo',(Join-Path $PSScriptRoot 'Deck.Background.vbs'),$backgroundScript,'scheduled worker') | ForEach-Object { ConvertTo-DeckProcessArgument ([string]$_) }) -join ' '
    $vbsInfo.UseShellExecute=$false; $vbsInfo.CreateNoWindow=$true; $vbsInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $vbsProcess=[Diagnostics.Process]::Start($vbsInfo)
    Assert ($vbsProcess.WaitForExit(10000) -and $vbsProcess.ExitCode -eq 0) 'Scheduled background launcher did not finish'
    $vbsProcess.Dispose()
}finally{$env:CODEX_DECK_BACKGROUND_TEST=$oldBackgroundResult; $env:PSModulePath=$previousModulePath}
$scheduledArguments=Get-Content -LiteralPath $scheduledResult -Raw | ConvertFrom-Json
Assert (($scheduledArguments -join '|') -eq 'scheduled worker') 'Scheduled background launcher lost arguments'
foreach($file in @('Deck.Core.ps1','Deck.WarmupWorker.ps1','Codex-Deck.ps1','../.local/bin/codex-auth.ps1')){
    $tokens=$null; $errors=$null
    $path=Join-Path $PSScriptRoot $file
    if(-not (Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot '../bin/codex-auth.ps1'}
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Parse failed: $file / $errors"
}
'PASS: defaults, PID identity/cleanup, plan-aware warm-up, reset grace/expiry, deduplication, cooldown, opt-in, throttles, injection guards, worker execution, script parsing.'
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
$fresh=@{PlanType='plus';Windows=@(@{DurationSeconds=18000;UsedPct=0;ResetsAtUnix=$now+17910})}
Assert ((Get-DeckWarmupReset $fresh $null $now) -eq ($now-90)) 'Fresh empty window was not discovered'
Assert ((Get-DeckWarmupReset $fresh ($now-120) $now) -eq ($now-120)) 'Observed reset was replaced by inferred reset'
$fresh.Windows[0].UsedPct=1
Assert ($null -eq (Get-DeckWarmupReset $fresh $null $now)) 'Used window inferred as empty'
$fresh.Windows[0].UsedPct=0; $futureBoundary=$now+18000
$fresh.Windows[0].ResetsAtUnix=$futureBoundary
Assert ((Get-DeckWarmupReset $fresh $futureBoundary $now) -eq $futureBoundary) 'Known future reset was reinterpreted as a fresh window start'
$settings=Get-DeckDefaults; $settings.WarmupEnabled=$true; $settings.WarmupPlanTypes='paid'
$fresh=@{Account='account1';PlanType='plus';Status='available';Windows=@(@{DurationSeconds=18000;UsedPct=0},@{DurationSeconds=604800;UsedPct=100})}
Assert (-not (Test-DeckWarmup $settings $fresh ($now-90) $null $now)) 'Exhausted weekly quota warmed'
$freeFresh=@{PlanType='free';Windows=@(@{DurationSeconds=2592000;UsedPct=0;ResetsAtUnix=$now+2591910})}
Assert ((Get-DeckWarmupReset $freeFresh $null $now) -eq ($now-90)) 'Fresh Free allowance window was not discovered'
$legacySuite=Join-Path $fixture 'legacy-warmup-settings'; [void][IO.Directory]::CreateDirectory($legacySuite)
Write-DeckJson (Join-Path $legacySuite 'settings.json') @{WarmupAllPaid=$true}
Assert ((Get-DeckSettings $legacySuite).WarmupPlanTypes -eq 'paid') 'Legacy all-paid warm-up setting was not migrated'
Write-DeckJson (Join-Path $legacySuite 'settings.json') @{WarmupAllPaid=$true;WarmupPlanTypes='free,paid'}
Assert ((Get-DeckSettings $legacySuite).WarmupPlanTypes -eq 'free,paid') 'Saved warm-up account types did not override the legacy setting'
'PASS: plan-aware window discovery, observed reset preservation, legacy migration and exhausted weekly guard.'

Assert (-not (Get-DeckDefaults).AutoStart) 'Desktop auto-opening must be opt-in'
$scheduleSettings=Get-DeckDefaults; $scheduleSettings.WarmupEnabled=$true; $scheduleSettings.WarmupResetEnabled=$true; $scheduleSettings.WarmupGraceSeconds=60
$scheduleNow=[DateTimeOffset]'2026-09-09T20:00:00-03:00'; $scheduleReset=$scheduleNow.ToUnixTimeSeconds()+600
$scheduleCache=@{account1=[pscustomobject]@{PlanType='plus';Status='available';Error=$null;Windows=@([pscustomobject]@{DurationSeconds=18000;ResetsAtUnix=$scheduleReset})}}
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
