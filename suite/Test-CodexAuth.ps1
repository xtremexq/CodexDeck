$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot '../.local/bin/codex-auth.ps1'
if (-not (Test-Path -LiteralPath $sourcePath)) { $sourcePath=Join-Path $PSScriptRoot '../bin/codex-auth.ps1' }
$tokens=$null; $errors=$null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$sourceText=[IO.File]::ReadAllText($sourcePath)
$checkAllParameter=$ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -eq 'CheckAll'} | Select-Object -First 1
if(-not $checkAllParameter -or $checkAllParameter.Extent.Text -notmatch "Alias\('a'\)" -or $sourceText -notmatch 'Show-DeckTerminal[^\r\n]+-CheckAll:\$CheckAll'){throw 'codex-auth -a is not wired to the dashboard all-check action'}
$savedErrorPreference=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    $invalidCheckAll=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sourcePath -a status 2>&1
    $invalidCheckAllExit=$LASTEXITCODE
} finally { $ErrorActionPreference=$savedErrorPreference }
if($invalidCheckAllExit -eq 0 -or ($invalidCheckAll -join "`n") -notmatch 'only works with the plain codex-auth dashboard command'){throw 'codex-auth -a accepted a non-plain command'}
foreach ($name in 'Initialize-AccountDirectory','Remove-CodexAccount','Get-AccountDirectories','Find-DeckConversationOwner','Normalize-AccountName','Ensure-FreeAccountDefaults','Read-TextFile','Write-TextFile','Normalize-Newlines','ConvertTo-DeckWindowsArgument','Invoke-DeckCodex','Write-DeckSessionExit','Get-DeckSessionRoutingArguments','ConvertFrom-DeckTomlScalar','Get-DeckTomlTopLevelValue','Get-DeckCodexArgumentSetting','Get-DeckNativeAutoCompactConfiguration','Open-DeckLaunchInspector') {
    $definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $PSScriptRoot 'Deck.Failover.ps1')
. (Join-Path $PSScriptRoot 'Deck.Environments.ps1')
$script:openedInspectors=@()
function Open-DeckInspector([string]$SuiteRoot,[string]$Mode,[switch]$Companion,[string]$SessionPath) {$script:openedInspectors += [pscustomobject]@{Mode=$Mode;Companion=[bool]$Companion;SessionPath=$SessionPath}; return 'http://127.0.0.1/test'}
$suiteRoot='C:\synthetic-suite'; $deckInteractiveConversation=$true; $deckSession='C:\synthetic-suite\deck\sessions\live.json'
$failoverProxy=[pscustomobject]@{ContextUrl='http://127.0.0.1:12345/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/_deck/context'}
$deckSettings=[pscustomobject]@{TrajectoryEnabled=$true;ContextManagerEnabled=$true;EfficiencyAnalyticsEnabled=$true}
Open-DeckLaunchInspector
if($script:openedInspectors.Count -ne 1 -or $script:openedInspectors[0].Mode -ne 'Trajectory' -or -not $script:openedInspectors[0].Companion -or $script:openedInspectors[0].SessionPath -ne $deckSession){throw 'Context-managed interactive launch did not open its exact-session compact companion'}
$deckSettings=[pscustomobject]@{TrajectoryEnabled=$true;ContextManagerEnabled=$false;EfficiencyAnalyticsEnabled=$true}
Open-DeckLaunchInspector
if($script:openedInspectors.Count -ne 2 -or $script:openedInspectors[1].Mode -ne 'Trajectory' -or $script:openedInspectors[1].Companion){throw 'Interactive launch did not fall back to full Trajectory while keeping Efficiency independent'}
$deckSettings=[pscustomobject]@{TrajectoryEnabled=$false;ContextManagerEnabled=$false;EfficiencyAnalyticsEnabled=$true}
Open-DeckLaunchInspector
if($script:openedInspectors.Count -ne 3 -or $script:openedInspectors[2].Mode -ne 'Efficiency' -or $script:openedInspectors[2].Companion){throw 'Standalone Efficiency analytics did not open for an interactive launch'}
$deckInteractiveConversation=$false
Open-DeckLaunchInspector
if($script:openedInspectors.Count -ne 3){throw 'Non-interactive launch opened the inspector'}
if(([regex]::Matches($sourceText,'(?m)^\s*Open-DeckLaunchInspector\s*$')).Count -ne 3){throw 'Inspector opener must run once in each mutually exclusive conversation launch path'}
$syntheticProxy=@{BaseUrl='http://127.0.0.1:12345/capability'}
$ordinaryRoute=@(Get-DeckSessionRoutingArguments $syntheticProxy $false)
$pooledRoute=@(Get-DeckSessionRoutingArguments $syntheticProxy $true)
if($ordinaryRoute -notcontains 'model_provider="openai"' -or $ordinaryRoute -contains 'model_provider="deck_failover"'){throw 'Ordinary auto-compact routing would open a different conversation history'}
if($pooledRoute -notcontains 'model_provider="deck_failover"' -or $pooledRoute -contains 'model_provider="openai"'){throw 'Pooled auto-compact routing lost its login-less provider'}
if ((ConvertTo-DeckWindowsArgument '') -ne '""' -or
    (ConvertTo-DeckWindowsArgument 'plain') -ne 'plain' -or
    (ConvertTo-DeckWindowsArgument 'two words') -ne '"two words"' -or
    (ConvertTo-DeckWindowsArgument 'model_provider="openai"') -ne '"model_provider=\"openai\""' -or
    (ConvertTo-DeckWindowsArgument 'C:\path with space\') -ne '"C:\path with space\\"') {
    throw 'Windows Codex argument quoting failed.'
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-auth-test-' + [guid]::NewGuid().ToString('N'))
$accountsRoot = Join-Path $fixture 'accounts'
New-Item -ItemType Directory -Path (Join-Path $accountsRoot 'account1') -Force | Out-Null
$conversationId=[guid]::NewGuid().ToString('D')
$conversationDirectory=Join-Path $accountsRoot 'account1/sessions/2026/09/21'
[void][IO.Directory]::CreateDirectory($conversationDirectory)
[IO.File]::WriteAllText((Join-Path $conversationDirectory "rollout-2026-09-21T00-00-00-$conversationId.jsonl"),'{}')
$nativeModel='test-native-model'
[IO.File]::WriteAllText((Join-Path $accountsRoot 'account1/config.toml'),("model = `"{0}`"" -f $nativeModel))
[IO.File]::WriteAllText((Join-Path $accountsRoot 'account1/models_cache.json'),(@{models=@(@{slug=$nativeModel;context_window=200000;effective_context_window_percent=90;visibility='list';priority=1})}|ConvertTo-Json -Depth 5))
$nativeCompact=Get-DeckNativeAutoCompactConfiguration (Join-Path $accountsRoot 'account1') @() 70
if($nativeCompact.TokenLimit -ne 54000 -or $nativeCompact.EffectiveContextWindow -ne 180000 -or $nativeCompact.Arguments -notcontains 'model_auto_compact_token_limit=54000' -or $nativeCompact.Arguments -notcontains 'model_auto_compact_token_limit_scope="total"'){throw 'Native auto-compact did not translate 70% free into 30% of the effective model context'}
$nativeOverride=Get-DeckNativeAutoCompactConfiguration (Join-Path $accountsRoot 'account1') @('-c','model_context_window=100000') 70
if($nativeOverride.TokenLimit -ne 27000){throw 'Native auto-compact ignored the per-launch context-window override'}
$conversation=Find-DeckConversationOwner $conversationId
if($conversation.Account -ne 'account1' -or $conversation.Id -ne $conversationId){throw 'Conversation lookup did not return its owning account'}
$missingConversationRejected=$false
try{Find-DeckConversationOwner ([guid]::NewGuid().ToString('D')) | Out-Null}catch{$missingConversationRejected=$true}
if(-not $missingConversationRejected){throw 'Conversation lookup accepted an unknown ID'}
$mockLauncher=Join-Path $fixture 'codex.ps1'
$mockResult=Join-Path $fixture 'codex-arguments.json'
[IO.File]::WriteAllText($mockLauncher, '[IO.File]::WriteAllText($env:CODEX_DECK_TEST_ARGUMENTS,($args | ConvertTo-Json -Compress)); exit 23', [Text.UTF8Encoding]::new($false))
$oldPath=$env:PATH; $oldResult=$env:CODEX_DECK_TEST_ARGUMENTS
try {
    $env:PATH=$fixture+';'+$oldPath
    $env:CODEX_DECK_TEST_ARGUMENTS=$mockResult
    Invoke-DeckCodex @('two words','model_provider="openai"','C:\path with space\')
    $isolatedExit=$LASTEXITCODE
} finally { $env:PATH=$oldPath; $env:CODEX_DECK_TEST_ARGUMENTS=$oldResult }
$isolatedArguments=Get-Content -LiteralPath $mockResult -Raw | ConvertFrom-Json
if($isolatedExit -ne 23 -or ($isolatedArguments -join '|') -ne 'two words|model_provider="openai"|C:\path with space\'){throw ('Isolated Codex launch lost arguments or exit status: exit={0}; args={1}' -f $isolatedExit,($isolatedArguments -join '|'))}
$nodeCapture=Join-Path $fixture 'codex-node-arguments.json'
$nodeDirectory=Join-Path $fixture 'node_modules/@openai/codex/bin'
[void][IO.Directory]::CreateDirectory($nodeDirectory)
$nodeScript=Join-Path $nodeDirectory 'codex.js'
[IO.File]::WriteAllText($nodeScript,'require("node:fs").writeFileSync(process.env.CODEX_DECK_TEST_ARGUMENTS,JSON.stringify(process.argv.slice(2)));process.exit(23);',[Text.UTF8Encoding]::new($false))
$oldPath=$env:PATH; $oldResult=$env:CODEX_DECK_TEST_ARGUMENTS
try {
    $env:PATH=$fixture+';'+$oldPath
    $env:CODEX_DECK_TEST_ARGUMENTS=$nodeCapture
    $config='developer_instructions="Global Rules (Codex Deck): keep going."'
    Invoke-DeckCodex @('-c',$config,'--remote','ws://127.0.0.1:12345')
    $isolatedExit=$LASTEXITCODE
} finally { $env:PATH=$oldPath; $env:CODEX_DECK_TEST_ARGUMENTS=$oldResult }
$nodeArguments=Get-Content -LiteralPath $nodeCapture -Raw | ConvertFrom-Json
if($isolatedExit -ne 23 -or ($nodeArguments -join '|') -ne ('-c|'+$config+'|--remote|ws://127.0.0.1:12345')){throw ('Codex native arguments were split or changed: exit={0}; args={1}' -f $isolatedExit,($nodeArguments -join '|'))}
$global:LASTEXITCODE=0
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $accountsRoot 'account1/marker.ps1')
foreach ($name in @('..', '../outside', 'C:\Windows', 'missing')) {
    $failed=$false
    try { Remove-CodexAccount $name } catch { $failed=$true }
    if (-not $failed) { throw "Unsafe/nonexistent target accepted: $name" }
}
Remove-CodexAccount (Normalize-AccountName '1')
if (Test-Path -LiteralPath (Join-Path $accountsRoot 'account1')) { throw 'Account not removed' }
$archive = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'deleted-accounts') -Directory)
if ($archive.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $archive[0].FullName 'marker.ps1'))) { throw 'Recovery copy missing' }
$NewAccount=$true
$existing=Join-Path $accountsRoot 'existing'
[void][IO.Directory]::CreateDirectory($existing)
[IO.File]::WriteAllText((Join-Path $existing 'auth.json'),'synthetic sentinel')
$refused=$false; try{Initialize-AccountDirectory 'EXISTING' (Join-Path $accountsRoot 'EXISTING')}catch{$refused=$true}
if(-not $refused -or [IO.File]::ReadAllText((Join-Path $existing 'auth.json')) -ne 'synthetic sentinel'){throw 'New account overwrote or accepted an existing case-insensitive name'}
$NewAccount=$false
$newAccount = Join-Path $accountsRoot 'account2'
New-Item -ItemType Directory -Path $newAccount | Out-Null
Ensure-FreeAccountDefaults $newAccount
if (Test-Path -LiteralPath (Join-Path $newAccount 'config.toml')) { throw 'Unauthenticated account assumed free' }
foreach ($plan in 'plus','free') {
    $claims = @{ 'https://api.openai.com/auth' = @{ chatgpt_plan_type=$plan } } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
    Write-TextFile (Join-Path $newAccount 'auth.json') (@{tokens=@{id_token="header.$payload.signature"}} | ConvertTo-Json)
    Ensure-FreeAccountDefaults $newAccount
    $config = Read-TextFile (Join-Path $newAccount 'config.toml')
    if ($plan -eq 'plus' -and $config) { throw 'Paid account received free defaults' }
    if ($plan -eq 'free' -and ($config -notmatch 'model = "gpt-5.6-terra"' -or $config -notmatch 'model_reasoning_effort = "medium"')) { throw 'New free account defaults missing' }
}
$before=Read-TextFile (Join-Path $newAccount 'config.toml')
Ensure-FreeAccountDefaults $newAccount
if ((Read-TextFile (Join-Path $newAccount 'config.toml')) -ne $before) { throw 'Defaults not idempotent' }
$started=[DateTimeOffset]::Now.AddMinutes(-1)
Write-DeckSessionExit (Join-Path $fixture 'deck') 'account2' 17 $started $true 9 'account7'
$exitRecord=(Get-Content -LiteralPath (Join-Path $fixture 'deck/session-exits.jsonl') -Raw | ConvertFrom-Json)
if($exitRecord.Environment -ne 'account2' -or $exitRecord.ActiveAccount -ne 'account7' -or $exitRecord.ExitCode -ne 17 -or -not $exitRecord.ProxyExitedEarly -or $exitRecord.ProxyExitCode -ne 9){throw 'Session exit diagnostics incomplete'}
Write-Output "PASS: conversation ownership, removal, recovery, traversal, quoting, routing identity, exit diagnostics, missing targets, and plan-aware new-account defaults. Fixture: $fixture"
