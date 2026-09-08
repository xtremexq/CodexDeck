$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.Terminal.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
Assert ((Format-DeckTerminalQuota $null) -match '\?') 'Unknown quota shown as zero'
Assert ((Format-DeckTerminalQuota @{RemainingPct=72}) -eq '[#######---]  72%') 'Quota bar incorrect'
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
Copy-Item (Join-Path $PSScriptRoot 'Deck.Core.ps1') (Join-Path $fixture 'Deck.Core.ps1')
Write-DeckJson (Join-Path $fixture 'deck/cache.json') @(@{Account='account1';CheckedAt='2026-01-01T00:00:00Z';Status='available'})
Write-DeckJson (Join-Path $fixture 'deck/terminal-cache.json') @(@{Account='account1';CheckedAt='2026-01-02T00:00:00Z';Status='blocked'})
Assert ((Get-DeckTerminalCache (Join-Path $fixture 'deck')).account1.Status -eq 'blocked') 'Newest cache not selected'
$snapshot = @(Show-DeckTerminal -SuiteRoot $fixture -AuthScript 'unused' -Snapshot)
Assert (($snapshot -join "`n") -match 'CODEX / DECK') 'Snapshot did not render'
'PASS: terminal quota, sanitization, cache merge, paging, masking, empty state and snapshot.'

$freeCache = @{account1=@{Status='available';Windows=@(@{Label='30-day';DurationSeconds=2592000;RemainingPct=42})}}
$freeFrame = @(Get-DeckTerminalFrame @('account1') $freeCache $profiles @() @{} 0 110 25 '' 'Ready')
Assert (($freeFrame.Text -join "`n") -match '42%') 'Free plan quota missing'
'PASS: free plan primary quota.'
