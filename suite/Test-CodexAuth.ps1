$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot '../.local/bin/codex-auth.ps1'
if (-not (Test-Path -LiteralPath $sourcePath)) { $sourcePath=Join-Path $PSScriptRoot '../bin/codex-auth.ps1' }
$tokens=$null; $errors=$null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
foreach ($name in 'Remove-CodexAccount','Normalize-AccountName','Ensure-FreeAccountDefaults','Read-TextFile','Write-TextFile','Normalize-Newlines') {
    $definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-auth-test-' + [guid]::NewGuid().ToString('N'))
$accountsRoot = Join-Path $fixture 'accounts'
New-Item -ItemType Directory -Path (Join-Path $accountsRoot 'account1') -Force | Out-Null
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
Write-Output "PASS: removal, recovery, traversal, missing targets, and plan-aware new-account defaults. Fixture: $fixture"
