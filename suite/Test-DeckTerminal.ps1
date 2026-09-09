$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.Terminal.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
Assert ((Format-DeckTerminalQuota $null) -match '\?') 'Unknown quota shown as zero'
Assert ((Format-DeckTerminalQuota @{RemainingPct=72}) -eq '[#######---]  72%') 'Quota bar incorrect'
$resetAt=[DateTimeOffset]::Now.AddHours(3).ToUnixTimeSeconds()
Assert ((Format-DeckTerminalReset @{ResetsAtUnix=$resetAt}) -match ([DateTimeOffset]::FromUnixTimeSeconds($resetAt).ToLocalTime().ToString('MMM dd HH:mm'))) 'Primary reset formatter incorrect'
Assert ((ConvertTo-DeckTerminalText "abc$([char]27)[2J`nfoo" 8).Length -le 8) 'Text not bounded'
Assert ((ConvertTo-DeckTerminalText "a$([char]27)b") -eq 'a b') 'Terminal control character not stripped'
Assert ((Get-DeckTerminalHealth @{Status='available';Error='failed'}) -eq 'Check failed') 'Error hidden by cached ready status'
Assert ((Get-DeckTerminalHealth @{Status='available';Windows=@(@{RemainingPct=90;ResetsAtUnix=1})}) -eq 'Reset passed') 'Expired quota shown as current'
$names = @(1..40 | ForEach-Object { "account$_" })
$profiles = @{}; foreach ($name in $names) { $profiles[$name] = @{PlanType='plus';Email='person@example.com';Model='default';Effort='default'} }
$frame = @(Get-DeckTerminalFrame $names @{} $profiles @() @{} 39 100 25 '' 'Ready')
Assert (($frame.Text -join "`n") -match '> account40') 'Selection not paged into view'
Assert (($frame.Text -join "`n") -notmatch 'person@example.com') 'Email not masked by default'
Assert ($frame.Count -le 24) 'Frame overflows terminal height'
$empty = @(Get-DeckTerminalFrame @() @{} @{} @() @{} 0 60 25 '' 'Ready')
Assert (($empty.Text -join "`n") -match 'No matching accounts') 'Missing empty state'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('deck-terminal-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'deck'))
foreach($file in 'Deck.Core.ps1','Deck.AccountTools.ps1'){Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $fixture $file)}
Write-DeckJson (Join-Path $fixture 'deck/cache.json') @(@{Account='account1';CheckedAt='2026-01-01T00:00:00Z';Status='available'})
Write-DeckJson (Join-Path $fixture 'deck/terminal-cache.json') @(@{Account='account1';CheckedAt='2026-01-02T00:00:00Z';Status='blocked'})
Assert ((Get-DeckTerminalCache (Join-Path $fixture 'deck')).account1.Status -eq 'blocked') 'Newest cache not selected'
$snapshot = @(Show-DeckTerminal -SuiteRoot $fixture -AuthScript 'unused' -Snapshot)
Assert (($snapshot -join "`n") -match 'CODEX / DECK') 'Snapshot did not render'
'PASS: terminal quota, sanitization, cache merge, paging, masking, empty state and snapshot.'

$freeCache = @{account1=@{Status='available';Windows=@(@{Label='30-day';DurationSeconds=2592000;RemainingPct=42;ResetsAtUnix=$resetAt})}}
$freeFrame = @(Get-DeckTerminalFrame @('account1') $freeCache $profiles @() @{} 0 140 25 '' 'Ready')
$freeText=$freeFrame.Text -join "`n"
Assert ($freeText -match '42%') 'Free plan quota missing'
Assert ($freeText -match 'STATE\s+NEXT RESET' -and $freeText -match [regex]::Escape([DateTimeOffset]::FromUnixTimeSeconds($resetAt).ToLocalTime().ToString('MMM dd HH:mm'))) 'Primary reset column missing after state'
'PASS: free plan primary quota.'

$settings=Set-DeckWarmupControl (Join-Path $fixture 'deck') 'account1'
Assert ($settings.WarmupEnabled -and $settings.WarmupAccounts -eq 'account1') 'Terminal selection did not opt in'
$settings=Set-DeckWarmupControl (Join-Path $fixture 'deck') -Pause
Assert (-not $settings.WarmupEnabled -and $settings.WarmupAccounts -eq 'account1') 'Pause lost account selection'
$frame=@(Get-DeckTerminalFrame $names @{} $profiles @() @{} 39 100 25 '' 'Ready' $true $settings @{})
Assert ($frame.Count -le 24 -and ($frame.Text -join "`n") -match 'AUTO WARM-UP: PAUSED') 'Warm-up state missing or overflowing'
Assert (Test-Path (Join-Path $fixture 'deck/warmup-settings-changed.json')) 'Scheduler was not signaled'
'PASS: shared warm-up selection, pause, scheduler signal and compact status.'

Assert (($frame.Text -join "`n") -notmatch 'Sessions:') 'Empty sessions line shown'
Assert (@($frame | Where-Object { $_.Text -match 'NAVIGATE|MANAGE|WARMUP' -and $_.Color -eq 'Cyan' }).Count -eq 0) 'Shortcut groups still cyan'
