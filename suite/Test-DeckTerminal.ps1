$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.Terminal.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
Assert ((Format-DeckTerminalQuota $null) -match '\?') 'Unknown quota shown as zero'
Assert ((Format-DeckTerminalQuota @{RemainingPct=72}) -eq '[#######---]  72%') 'Quota bar incorrect'
$resetAt=[DateTimeOffset]::Now.AddHours(3).ToUnixTimeSeconds()
Assert ((Format-DeckTerminalReset @{ResetsAtUnix=$resetAt}) -match ([DateTimeOffset]::FromUnixTimeSeconds($resetAt).ToLocalTime().ToString('MMM dd HH:mm'))) 'Primary reset formatter incorrect'
$weeklyReset=[DateTimeOffset]::Now.AddDays(4).ToUnixTimeSeconds()
$limited=@{Status='available';Windows=@(
    @{Label='5-hour';DurationSeconds=18000;RemainingPct=47;ResetsAtUnix=$resetAt},
    @{Label='Weekly';DurationSeconds=604800;RemainingPct=0;ResetsAtUnix=$weeklyReset}
)}
Assert ((Get-DeckTerminalResetWindow $limited $limited.Windows[0]).ResetsAtUnix -eq $weeklyReset) 'Exhausted weekly reset did not replace healthy primary reset'
Assert ((Get-DeckTerminalHealth $limited) -eq 'Exhausted') 'Current weekly exhaustion not detected'
$limited.Windows[0].ResetsAtUnix=1
Assert ((Get-DeckTerminalHealth $limited) -eq 'Exhausted') 'Expired primary window hid current weekly exhaustion'
Assert ((ConvertTo-DeckTerminalText "abc$([char]27)[2J`nfoo" 8).Length -le 8) 'Text not bounded'
Assert ((ConvertTo-DeckTerminalText "a$([char]27)b") -eq 'a b') 'Terminal control character not stripped'
Assert ((Get-DeckTerminalHealth @{Status='available';Error='failed'}) -eq 'Check failed') 'Error hidden by cached ready status'
Assert ((Get-DeckTerminalHealth @{Status='available';Windows=@(@{RemainingPct=90;ResetsAtUnix=1})}) -eq 'Reset passed') 'Expired quota shown as current'
$names = @(1..40 | ForEach-Object { "account$_" })
$profiles = @{}; foreach ($name in $names) { $profiles[$name] = @{PlanType='plus';Email='person@example.com';Model='default';Effort='default'} }
$frame = @(Get-DeckTerminalFrame $names @{} $profiles @() @{} 39 100 25 '' 'Ready')
Assert (($frame.Text -join "`n") -match '> account40') 'Selection not paged into view'
Assert (($frame.Text -join "`n") -match 'E memories') 'Per-account memories shortcut missing'
Assert (($frame.Text -join "`n") -match 'I instructions') 'Per-account instructions shortcut missing'
Assert (($frame.Text -join "`n") -match 'K skills') 'Per-account skills shortcut missing'
Assert (($frame.Text -join "`n") -match 'C compact \[ \] 70%') 'Auto-compact shortcut or default threshold missing'
Assert (($frame.Text -join "`n") -notmatch 'person@example.com') 'Email not masked by default'
Assert ($frame.Count -le 24) 'Frame overflows terminal height'
$empty = @(Get-DeckTerminalFrame @() @{} @{} @() @{} 0 60 25 '' 'Ready')
$compactFrame = @(Get-DeckTerminalFrame $names @{} $profiles @() @{} 0 100 25 '' 'Ready' $true $null @{} $true 72)
Assert (($compactFrame.Text -join "`n") -match 'C compact \[x\] 72%') 'Auto-compact selected state or configured threshold missing'
Assert (($empty.Text -join "`n") -match 'No matching accounts') 'Missing empty state'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('deck-terminal-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'deck'))
$memoryRoot=Join-Path $fixture 'accounts/account1/memories';[void][IO.Directory]::CreateDirectory($memoryRoot)
$instructionsPath=Get-DeckAccountInstructionsPath $fixture account1
Assert ($instructionsPath -eq (Join-Path $fixture 'accounts/account1/AGENTS.md')) 'Account instructions path incorrect'
$skillsPath=Get-DeckSkillsDirectory $fixture account1 -Create
Assert ((Test-Path -LiteralPath $skillsPath -PathType Container) -and $skillsPath -eq (Join-Path $fixture 'accounts/account1/skills')) 'Skills directory path incorrect'
[IO.File]::WriteAllText((Join-Path $fixture 'accounts/account1/auth.json'),'{}',[Text.UTF8Encoding]::new($false))
$checkQueue=[Collections.Generic.Queue[string]]::new()
$checkProfiles=@{account1=@{PlanType='plus'};pool=@{PlanType='pool'}}
$queued=Add-DeckTerminalCheckQueue @('account1','pool') $checkProfiles @{} $checkQueue (Join-Path $fixture 'accounts')
Assert ($queued -eq 1 -and $checkQueue.Count -eq 1 -and $checkQueue.Peek() -eq 'account1') 'Dashboard all-check did not queue exactly the signed-in accounts'
Assert ((Add-DeckTerminalCheckQueue @('account1') $checkProfiles @{} $checkQueue (Join-Path $fixture 'accounts')) -eq 0) 'Dashboard all-check queued a duplicate account'
Assert ((Get-DeckMemoryPath $memoryRoot 'project/notes.md').StartsWith($memoryRoot,[StringComparison]::OrdinalIgnoreCase)) 'Nested memory path was not accepted'
foreach($unsafeMemory in @('../outside.md','C:\outside.md','notes.exe','con.md')){
    $rejected=$false;try{[void](Get-DeckMemoryPath $memoryRoot $unsafeMemory)}catch{$rejected=$true}
    Assert $rejected "Unsafe memory path accepted: $unsafeMemory"
}
foreach($file in 'Deck.Core.ps1','Deck.AccountTools.ps1'){Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $fixture $file)}
Write-DeckJson (Join-Path $fixture 'deck/cache.json') @(@{Account='account1';CheckedAt='2026-01-01T00:00:00Z';Status='available'})
Write-DeckJson (Join-Path $fixture 'deck/terminal-cache.json') @(@{Account='account1';CheckedAt='2026-01-02T00:00:00Z';Status='blocked'})
Assert ((Get-DeckTerminalCache (Join-Path $fixture 'deck')).account1.Status -eq 'blocked') 'Newest cache not selected'
Write-DeckJson (Join-Path $fixture 'deck/cache.json') @(@{Account='account1';CheckedAt='2026-01-02T12:00:00-03:00';Status='available'})
Assert ((Get-DeckTerminalCache (Join-Path $fixture 'deck')).account1.Status -eq 'available') 'Cache timestamps with different offsets were compared as text'
$terminalAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Deck.Terminal.ps1'),[ref]$null,[ref]$null)
$dashboard=$terminalAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-DeckTerminal'},$true).Extent.Text
Assert ($dashboard -notmatch '\$attempted|TotalMinutes\s+-lt\s+5') 'Opening the terminal dashboard still schedules automatic usage checks'
Assert ($dashboard -match 'Auto-compact enabled for account and pool launches') 'Dashboard does not advertise pool auto-compact support'
Assert ($dashboard -notmatch 'Auto-compact needs an individual account') 'Dashboard still blocks pool auto-compact launches'
Assert ($dashboard -match '\$queueAll=\$CheckAll\.IsPresent' -and $dashboard -match 'Add-DeckTerminalCheckQueue') 'Dashboard -a startup does not reuse the A shortcut queue'
$snapshot = @(Show-DeckTerminal -SuiteRoot $fixture -AuthScript 'unused' -Snapshot)
Assert (($snapshot -join "`n") -match 'CODEX / DECK') 'Snapshot did not render'
'PASS: terminal quota, sanitization, cache merge, paging, masking, empty state and snapshot.'

$freeCache = @{account1=@{Status='available';Windows=@(@{Label='30-day';DurationSeconds=2592000;RemainingPct=42;ResetsAtUnix=$resetAt})}}
$freeFrame = @(Get-DeckTerminalFrame @('account1') $freeCache $profiles @() @{} 0 140 25 '' 'Ready')
$freeText=$freeFrame.Text -join "`n"
Assert ($freeText -match '42%') 'Free plan quota missing'
Assert ($freeText -match 'STATE\s+NEXT RESET' -and $freeText -match [regex]::Escape([DateTimeOffset]::FromUnixTimeSeconds($resetAt).ToLocalTime().ToString('MMM dd HH:mm'))) 'Primary reset column missing after state'
$limited.Windows[0].ResetsAtUnix=$resetAt
$limitedFrame = @(Get-DeckTerminalFrame @('account1') @{account1=$limited} $profiles @() @{} 0 140 25 '' 'Ready')
Assert (($limitedFrame.Text -join "`n") -match [regex]::Escape([DateTimeOffset]::FromUnixTimeSeconds($weeklyReset).ToLocalTime().ToString('MMM dd HH:mm'))) 'Exhausted row did not show its blocking weekly reset'
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
