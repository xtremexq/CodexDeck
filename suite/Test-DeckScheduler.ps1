$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
function Assert($value,$message){if(-not $value){throw $message}}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Codex-Deck.ps1'),[ref]$null,[ref]$null)
$tick=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeckTick'},$true)
Invoke-Expression $tick.Extent.Text
function Get-DeckSessions { [pscustomobject]@{Account='work-main'} }
function Get-DeckAccounts { 'work-main'; 1..12 | ForEach-Object {"account$_"} }
function Update-DeckPicker {}
function Render-Deck {}
function Write-DeckJson {}
function Start-DeckTask($code,$kind,$account){
    $script:started+= $account
    $process=[pscustomobject]@{HasExited=$false;ExitCode=0}; $process | Add-Member ScriptMethod Dispose {}
    $output=if($kind -eq 'Warm-up'){'{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}'+"`n"+'{"type":"turn.completed"}'}else{ConvertTo-Json -InputObject @(@{Account=$account;Status='available';Windows=@()}) -Compress}
    return @{Kind=$kind;Account=$account;Started=[DateTimeOffset]::UtcNow;Process=$process;Out=@{Result=$output}}
}
$root=Join-Path $env:TEMP ('deck-scheduler-'+[guid]::NewGuid().ToString('N'))
$suite=$PSScriptRoot; $settings=Get-DeckDefaults; $tasks=@{}; $manualChecks=@{}; $nextCheck=@{}; $pendingWarm=@{}
$cache=@{}; $history=@{}; $resets=@{}; $batchAccounts=@(); $batchUntil=[DateTimeOffset]::MinValue
$CheckButton=[pscustomobject]@{IsEnabled=$true;Content='Check'}; $allProfiles=$false; $widget=$false; $started=@()
Invoke-DeckTick; Assert ($started.Count -eq 0) 'Disabled auto-check started a request'
$settings.AutoCheck=$true
Invoke-DeckTick; Assert ($started.Count -eq 1 -and $started[0] -eq 'work-main') 'Auto-check missed connected account'
Invoke-DeckTick; Assert ($started.Count -eq 1) 'Duplicate in-flight check'
$tasks['work-main'].Process.HasExited=$true
$tasks['work-main'].Out.IsCompleted=$false
Invoke-DeckTick; Assert ($tasks.ContainsKey('work-main') -and -not $cache.ContainsKey('work-main')) 'UI read unfinished worker output'
$tasks['work-main'].Out.IsCompleted=$true
Invoke-DeckTick; Assert ($tasks.Count -eq 0 -and $cache['work-main'].Status -eq 'available') 'Completion or polling deadline failed'
$allProfiles=$true
Invoke-DeckTick; Assert ($tasks.Count -eq 8) 'Full list must launch eight checks together'
Invoke-DeckTick; Assert ($tasks.Count -eq 8 -and $started.Count -eq 9) 'Concurrency cap or duplicate prevention failed'
foreach($worker in $tasks.Values){$worker.Process.HasExited=$true}
Invoke-DeckTick; Assert ($tasks.Count -eq 4) 'Remaining checks did not start as slots became available'
$batchAccounts=@(Get-DeckAccounts)
foreach($worker in $tasks.Values){$worker.Process.HasExited=$true}
Invoke-DeckTick
Assert ($batchAccounts.Count -eq 0 -and $batchUntil -gt [DateTimeOffset]::UtcNow -and -not $CheckButton.IsEnabled) 'Full-list cooldown must begin after completion'
$settings.AutoCheck=$false; $manualChecks.account1=[DateTimeOffset]::UtcNow
Invoke-DeckTick; Assert ($tasks.ContainsKey('account1')) 'Single check blocked by list cooldown or auto-check off'
$old=$cache.account1; $tasks.account1.Process.HasExited=$true; $tasks.account1.Process.ExitCode=1
Invoke-DeckTick
Assert ([object]::ReferenceEquals($old,$cache.account1) -and $cache.account1.Error -and $nextCheck.account1 -gt [DateTimeOffset]::UtcNow.AddMinutes(19)) 'Failure lost previous quota or ignored backoff'
'PASS: concurrent scheduler, eight-worker cap, no duplicates, polling, list cooldown, single-account bypass and failure retention. No network or terminals.'

# A finished warm-up must refresh even if auto-check was disabled or the account left the visible scope.
$history.account2=[pscustomobject]@{Account='account2';Outcome='attempted / result pending'}
$tasks.account2=Start-DeckTask '' 'Warm-up' 'account2'; $tasks.account2.Process.HasExited=$true
Invoke-DeckTick
Assert ($tasks.account2.Kind -eq 'Check' -and $history.account2.Outcome -eq 'Replied: hi') 'Warm-up did not immediately launch a background usage refresh'
$tasks.account2.Process.HasExited=$true
Invoke-DeckTick
Assert ($cache.account2.CheckedAt -and -not $tasks.ContainsKey('account2')) 'Post-warm-up check did not update saved check data'
'PASS: warm-up completion immediately refreshes account usage without a terminal or auto-check dependency.'

# Warm-up owns its monitoring scope, even with auto-check off and no terminal.
$tasks=@{}; $started=@(); $manualChecks=@{}; $nextCheck=@{}; $allProfiles=$false
$settings.AutoCheck=$false; $settings.WarmupEnabled=$true; $settings.WarmupAccounts='account3'
Invoke-DeckTick
Assert ($started.Count -eq 1 -and $started[0] -eq 'account3') 'Disconnected warm-up selection was not monitored independently'
$nowUnix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$resets.account3=$nowUnix-90
$tasks.account3.Process.HasExited=$true
$tasks.account3.Out.Result=ConvertTo-Json -Depth 5 @{Account='account3';PlanType='plus';Status='available';Windows=@(@{DurationSeconds=18000;UsedPct=0;ResetsAtUnix=$nowUnix+17910})}
Invoke-DeckTick
Assert ($tasks.account3.Kind -eq 'Warm-up' -and $history.account3.AttemptAt) 'Eligible disconnected account did not warm or persist its attempt'
$tasks.account3.Process.HasExited=$true
Invoke-DeckTick
Assert ($history.account3.Outcome -eq 'Replied: hi' -and $tasks.account3.Kind -eq 'Check') 'Warm-up did not complete and refresh'
'PASS: disconnected accounts warm with ordinary auto-check disabled, persist before sending, and refresh afterward.'
