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
$plans=@{account1='free';account2='plus'}
foreach($name in $plans.Keys){
    $payload=ConvertTo-Json -Compress @{ 'https://api.openai.com/auth'=@{chatgpt_plan_type=$plans[$name]} }
    $token='synthetic.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')+'.synthetic'
    [IO.File]::WriteAllText((Join-Path $fixture "accounts/$name/auth.json"),(ConvertTo-Json -Compress @{tokens=@{access_token=$token;account_id='synthetic'}}))
}
$choice=Resolve-DeckFailoverPool $fixture '1, 2' 'Ordered'
if ($choice.Account -ne 'account1' -or ($choice.Pool -join ',') -ne 'account1,account2') { throw 'Pool order/normalization failed.' }
if(((Resolve-DeckFailoverPool $fixture '*' Ordered).Pool -join ',') -ne 'account1,account2'){throw 'All-account failover membership failed.'}
if(((Resolve-DeckFailoverPool $fixture '*free' Ordered).Pool -join ',') -ne 'account1'){throw 'Free-account failover membership failed.'}
if(((Resolve-DeckFailoverPool $fixture '*paid' Ordered account1).Pool -join ',') -ne 'account1,account2'){throw 'Paid-account failover membership did not retain the starting account first.'}
foreach ($bad in '', '1,1','account1,ACCOUNT1','../outside','missing','1,') {
    $failed=$false; try { Resolve-DeckFailoverPool $fixture $bad Ordered | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Invalid pool accepted.' }
}
$savedEncoding=[Console]::OutputEncoding
try {
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($true)
    $proxy=Start-DeckFailover -SuiteRoot $fixture -Pool $choice.Pool -Mode Ordered -Account $choice.Account -Environment pool -EnvironmentPool $choice.Pool
} finally { [Console]::OutputEncoding=$savedEncoding }
try {
    $argsList=@(Get-DeckFailoverArguments $proxy.BaseUrl)
    if ($argsList -notcontains 'model_provider="openai"' -or $argsList -notcontains ('openai_base_url="'+$proxy.BaseUrl+'"')) { throw 'Failover must retain the native history provider and route through the proxy.' }
    $poolArgs=@(Get-DeckFailoverArguments $proxy.BaseUrl -NoAccountAuth)
    if ($poolArgs -notcontains 'model_providers.deck_failover.requires_openai_auth=false' -or $poolArgs -notcontains 'model_providers.deck_failover.supports_websockets=false') { throw 'Pool authentication/transport overrides missing.' }
    if (Test-Path (Join-Path $fixture 'accounts/account1/config.toml')) { throw 'Proxy wrote account configuration.' }
    $oldSessionUrl=$env:CODEX_DECK_SESSION_URL
    try {
        $env:CODEX_DECK_SESSION_URL=$proxy.BaseUrl
        $status=(& (Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1') account -Json) | ConvertFrom-Json
        if(-not $status.environment.pooled -or $status.environment.name -ne 'pool' -or $status.failover.active -ne 'account1' -or $status.failover.automatic -ne $true){throw 'Session account status failed.'}
        $status=(& (Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1') account -UseAccount account2 -Json) | ConvertFrom-Json
        if($status.failover.active -ne 'account2'){throw 'Manual session account switch failed.'}
        $status=(& (Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1') pool account1 -Json) | ConvertFrom-Json
        if($status.failover.active -ne 'account1'){throw 'Direct current-pool selection failed.'}
        $mockBin=Join-Path $fixture 'mock-bin'
        [void][IO.Directory]::CreateDirectory($mockBin)
        [IO.File]::WriteAllText((Join-Path $mockBin 'codex-check.cmd'),"@echo off`r`necho MOCK-CHECK %*`r`n")
        $oldPath=$env:PATH
        try {
            $env:PATH=$mockBin+';'+$oldPath
            $usage=(& (Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1') usage) -join "`n"
            if($usage -notmatch 'MOCK-CHECK -Account account1 -NoColor'){throw 'Session usage did not target the active route.'}
        } finally { $env:PATH=$oldPath }
    } finally { $env:CODEX_DECK_SESSION_URL=$oldSessionUrl }
} finally {
    $proxy.Process.StandardInput.Close()
    if (-not $proxy.Process.WaitForExit(3000)) { $proxy.Process.Kill(); throw 'Proxy survived parent pipe closure.' }
    $proxy.Process.Dispose()
}
Write-Output 'PASS: failover pool validation, session account control, temporary overrides and parent-lifetime cleanup.'

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
