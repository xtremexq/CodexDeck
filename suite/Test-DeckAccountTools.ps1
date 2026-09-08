$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
# Isolate the GUI ownership guard from the user's running desktop.
$script:testMutexName = 'Local\DeckAccountToolsTest-'+[guid]::NewGuid().ToString('N')
function Get-DeckMaintenanceMutexName { $script:testMutexName }
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$now=[DateTimeOffset]::UtcNow
function New-Record($primary,$weekly){[pscustomobject]@{Status='available';CheckedAt=$now.ToString('o');Windows=@(@{RemainingPct=$primary;ResetsAtUnix=$now.AddHours(1).ToUnixTimeSeconds()},@{RemainingPct=$weekly;ResetsAtUnix=$now.AddDays(1).ToUnixTimeSeconds()})}}
$cache=@{a=(New-Record 95 5);b=(New-Record 70 80);c=(New-Record 100 0);old=(New-Record 100 100);unknown=(New-Record $null 100)}
$cache.old.CheckedAt=$now.AddMinutes(-6).ToString('o')
$choices=@(Get-DeckRecommendations @('a','b','c','old','unknown') $cache $now)
Assert ($choices.Count -eq 2 -and $choices[0].Account -eq 'b') 'Recommendation ignored limiting window or accepted stale/unknown/exhausted usage'
$cache.b.Windows[0].ResetsAtUnix=1
Assert ((@(Get-DeckRecommendations @('b') $cache $now)).Count -eq 0) 'Passed reset was recommended'
Assert ((Format-DeckResetCredits @{} $now) -eq 'Not reported') 'Missing credits shown as zero'
$credits=@{ResetCredits=@{Status='available';CheckedAt=$now.ToString('o');Items=@(@{Status='available';ExpiresAtUnix=$now.AddDays(1).ToUnixTimeSeconds()},@{Status='available';ExpiresAtUnix=1},@{Status='redeemed';ExpiresAtUnix=$null})}}
Assert ((Format-DeckResetCredits $credits $now) -match '^1 available / next expires') 'Expired/redeemed reset credits counted'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-account-tools-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/old/sessions/2026/09/08'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'deck'))
$id='11111111-2222-3333-4444-555555555555'
$path=Join-Path $fixture 'accounts/old/sessions/2026/09/08/rollout-example.jsonl'
$line=@{type='session_meta';payload=@{id=$id;cwd='C:\Projects\example';model_provider='custom'}} | ConvertTo-Json -Depth 5 -Compress
[IO.File]::WriteAllText($path,$line+"`n"+'{"type":"response_item","payload":"PRIVATE TEST CONTENT"}')
[IO.File]::WriteAllText((Join-Path (Split-Path $path) 'rollout-broken.jsonl'),'invalid')
$rows=@(Get-DeckSessionHistory $fixture 'custom')
Assert ($rows.Count -eq 1 -and $rows[0].Id -eq $id -and ($rows | ConvertTo-Json) -notmatch 'PRIVATE TEST CONTENT') 'History failed provider search, metadata parsing or privacy'
Assert (@(Get-DeckSessionHistory $fixture 'missing').Count -eq 0) 'History filter ignored'
$large=@{type='session_meta';payload=@{id=$id;cwd='C:\Projects\example';model_provider='custom';instructions=('x'*100000)}} | ConvertTo-Json -Compress
[IO.File]::WriteAllText($path,$large+"`n"+'{"type":"response_item","payload":"PRIVATE TEST CONTENT"}')
Assert (@(Get-DeckSessionHistory $fixture).Count -eq 1) 'Large metadata header was silently dropped'
$lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try { Assert (@(Get-DeckSessionHistory $fixture).Count -eq 1) 'Active session could not be read' } finally { $lock.Dispose() }

Write-DeckJson (Join-Path $fixture 'deck/settings.json') @{WarmupAccounts='old,other';DefaultFolder='unchanged'}
Write-DeckJson (Join-Path $fixture 'deck/pins.json') @('old','other')
Write-DeckJson (Join-Path $fixture 'deck/warmup.json') @(@{Account='old';Reset=123})
Write-DeckJson (Join-Path $fixture 'deck/cache.json') @(@{Account='old';Status='available'})
foreach($bad in @('../escape','CON','old')){
    $failed=$false;try{Rename-DeckAccount $fixture 'old' $bad | Out-Null}catch{$failed=$true};Assert $failed 'Unsafe rename accepted'
}
$held = [Threading.Mutex]::new($true,$script:testMutexName)
try {
    $failed=$false;try{Rename-DeckAccount $fixture 'old' 'renamed' | Out-Null}catch{$failed=$true}
    Assert $failed 'Desktop ownership guard ignored'
} finally { $held.ReleaseMutex(); $held.Dispose() }
Rename-DeckAccount $fixture 'old' 'renamed' | Out-Null
Assert (Test-Path (Join-Path $fixture 'accounts/renamed/sessions/2026/09/08/rollout-example.jsonl')) 'Rename lost session data'
Assert ((Read-DeckJson (Join-Path $fixture 'deck/settings.json')).WarmupAccounts -eq 'renamed,other') 'Warm-up selection not renamed'
Assert ('renamed' -in (Read-DeckJson (Join-Path $fixture 'deck/pins.json'))) 'Pin not renamed'
Assert ((Read-DeckJson (Join-Path $fixture 'deck/cache.json')).Account -eq 'renamed') 'Cache not renamed'
Assert ((@(Get-DeckSessionHistory $fixture))[0].Account -eq 'renamed') 'History retained old profile identity'
$session=Register-DeckSession (Join-Path $fixture 'deck') 'renamed' $fixture
$failed=$false;try{Rename-DeckAccount $fixture 'renamed' 'busy' | Out-Null}catch{$failed=$true};Assert $failed 'Connected account renamed'
Remove-Item -LiteralPath $session
# A failed state write must restore both the folder and every previous state file.
function Write-DeckJson { throw 'Synthetic state write failure' }
$failed=$false;try{Rename-DeckAccount $fixture 'renamed' 'rolledback' | Out-Null}catch{$failed=$true}
Assert ($failed -and (Test-Path (Join-Path $fixture 'accounts/renamed')) -and -not (Test-Path (Join-Path $fixture 'accounts/rolledback'))) 'Rename rollback lost folder'
Assert ((Read-DeckJson (Join-Path $fixture 'deck/settings.json')).WarmupAccounts -eq 'renamed,other') 'Rename rollback lost settings'
'PASS: recommendation freshness/exhaustion, reset-credit expiry, metadata-only history, rename validation/state migration/active-session guard/rollback.'
