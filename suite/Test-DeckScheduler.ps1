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
function Complete-DeckScheduleRepair {}
function Start-DeckScheduleRepair {$script:scheduleRepairStarts++}
function Start-DeckTask($code,$kind,$account){
    $script:started+= $account
    $process=[pscustomobject]@{HasExited=$false;ExitCode=0}; $process | Add-Member ScriptMethod Dispose {}
    $output=if($kind -eq 'Warm-up'){'{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}'+"`n"+'{"type":"turn.completed"}'}else{ConvertTo-Json -InputObject @(@{Account=$account;Status='available';Windows=@()}) -Compress}
    return @{Kind=$kind;Account=$account;Started=[DateTimeOffset]::UtcNow;Process=$process;Out=@{Result=$output}}
}
$root=Join-Path $env:TEMP ('deck-scheduler-'+[guid]::NewGuid().ToString('N'))
$suite=$PSScriptRoot; $settings=Get-DeckDefaults; $tasks=@{}; $manualChecks=@{}; $nextCheck=@{}
$cache=@{}; $history=@{}; $resets=@{}; $batchAccounts=@(); $batchUntil=[DateTimeOffset]::MinValue
$StatusButton=[pscustomobject]@{IsEnabled=$true}
$allProfiles=$false; $widget=$false; $started=@(); $scheduleRepairStarts=0
Invoke-DeckTick; Assert ($started.Count -eq 0) 'Disabled auto-check started a request'
Assert ($scheduleRepairStarts -eq 1) 'Initial background schedule repair was not requested'
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
Assert ($batchAccounts.Count -eq 0 -and $batchUntil -gt [DateTimeOffset]::UtcNow -and -not $StatusButton.IsEnabled) 'Full-list cooldown must begin after completion'
$settings.AutoCheck=$false; $manualChecks.account1=[DateTimeOffset]::UtcNow
Invoke-DeckTick; Assert ($tasks.ContainsKey('account1')) 'Single check blocked by list cooldown or auto-check off'
$old=$cache.account1; $tasks.account1.Process.HasExited=$true; $tasks.account1.Process.ExitCode=1
Invoke-DeckTick
Assert ([object]::ReferenceEquals($old,$cache.account1) -and $cache.account1.Error -and $nextCheck.account1 -gt [DateTimeOffset]::UtcNow.AddMinutes(19)) 'Failure lost previous quota or ignored backoff'
'PASS: concurrent scheduler, eight-worker cap, no duplicates, polling, list cooldown, single-account bypass and failure retention. No network or terminals.'

# Automatic warm-up belongs exclusively to the short-lived headless worker. The
# GUI must not become a second executor merely because the setting is enabled.
$tasks=@{}; $started=@(); $manualChecks=@{}; $nextCheck=@{}; $allProfiles=$false
$settings.AutoCheck=$false; $settings.WarmupEnabled=$true; $settings.WarmupAccounts='account3'
Invoke-DeckTick
Assert ($started.Count -eq 0 -and $tasks.Count -eq 0) 'GUI duplicated the headless automatic warm-up worker'
'PASS: GUI checks remain separate from the headless warm-up worker.'
