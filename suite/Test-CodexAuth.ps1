$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot '../.local/bin/codex-auth.ps1'
if (-not (Test-Path -LiteralPath $sourcePath)) { $sourcePath=Join-Path $PSScriptRoot '../bin/codex-auth.ps1' }
$tokens=$null; $errors=$null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
foreach ($name in 'Initialize-AccountDirectory','Remove-CodexAccount','Normalize-AccountName','Ensure-FreeAccountDefaults','Read-TextFile','Write-TextFile','Normalize-Newlines','ConvertTo-DeckWindowsArgument','Invoke-DeckCodex','Write-DeckSessionExit') {
    $definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
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
Write-Output "PASS: removal, recovery, traversal, quoting, exit diagnostics, missing targets, and plan-aware new-account defaults. Fixture: $fixture"
