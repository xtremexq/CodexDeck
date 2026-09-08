$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Failover.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-failover-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deck.Failover.cjs') -Destination $fixture
foreach ($name in 'account1','account2') {
    $dir=Join-Path $fixture ('accounts/'+$name)
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'auth.json'),'{"tokens":{"access_token":"synthetic","account_id":"synthetic"}}')
}
$choice=Resolve-DeckFailoverPool $fixture '1, 2' 'Ordered'
if ($choice.Account -ne 'account1' -or ($choice.Pool -join ',') -ne 'account1,account2') { throw 'Pool order/normalization failed.' }
foreach ($bad in '', '1,1','account1,ACCOUNT1','../outside','missing','1,') {
    $failed=$false; try { Resolve-DeckFailoverPool $fixture $bad Ordered | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Invalid pool accepted.' }
}
$proxy=Start-DeckFailover $fixture $choice.Pool Ordered $choice.Account
try {
    $argsList=@(Get-DeckFailoverArguments $proxy.BaseUrl)
    if ($argsList -notcontains 'model_providers.deck_failover.stream_max_retries=0' -or $argsList -notcontains 'model_providers.deck_failover.supports_websockets=false') { throw 'Transport safety overrides missing.' }
    if (Test-Path (Join-Path $fixture 'accounts/account1/config.toml')) { throw 'Proxy wrote account configuration.' }
} finally {
    $proxy.Process.StandardInput.Close()
    if (-not $proxy.Process.WaitForExit(3000)) { $proxy.Process.Kill(); throw 'Proxy survived parent pipe closure.' }
    $proxy.Process.Dispose()
}
Write-Output 'PASS: failover pool validation, PowerShell launch, temporary overrides and parent-lifetime cleanup.'

$enabled=@{FailoverEnabled=$true}
if (-not (Test-DeckAutomaticFailover $enabled $false @())) { throw 'Saved default not applied.' }
foreach ($argsList in @(@('login'),@('logout'),@('--help'),@('mcp','list'))) {
    if (Test-DeckAutomaticFailover $enabled $false $argsList) { throw 'Administrative command inherited failover.' }
}
if (Test-DeckAutomaticFailover $enabled $true @()) { throw 'Explicit Off ignored.' }
if (Test-DeckAutomaticFailover $enabled $false @() $true) { throw 'New-account login inherited failover.' }
$choice=Resolve-DeckFailoverPool $fixture 'account1' Best account2
if (($choice.Pool -join ',') -ne 'account2,account1' -or $choice.Account -ne 'account2') { throw 'Explicit primary account not preserved.' }
Write-Output 'PASS: saved default, per-launch override, administrative exclusions and explicit primary account.'
