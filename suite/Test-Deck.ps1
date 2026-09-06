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
Assert (-not $settings.AlwaysOnTop) 'Always on top must default off'
Assert ($settings.ViewMode -eq 'Widget') 'Widget must be default'
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
$settings.WarmupAccounts='account5'; $settings.AutoCheck=$false
Assert (-not (Test-DeckWarmup $settings $record ($now-90) $null $now)) 'Disabled checks warmed'
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
foreach($file in @('Deck.Core.ps1','Codex-Deck.ps1','../.local/bin/codex-auth.ps1')){
    $tokens=$null; $errors=$null
    $path=Join-Path $PSScriptRoot $file
    if(-not (Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot '../bin/codex-auth.ps1'}
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Parse failed: $file / $errors"
}
'PASS: defaults, PID identity/cleanup, paid-only warm-up, reset grace/expiry, deduplication, cooldown, opt-in, throttles, injection guards, worker execution, script parsing.'
"Synthetic test state: $fixture"
