# End-to-end launcher tests with synthetic credentials and an inert Codex function.
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-env-launch-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
foreach ($file in @('Deck.Core.ps1','Deck.AccountTools.ps1','Deck.Environments.ps1','Deck.Terminal.ps1','Deck.Failover.ps1','Deck.Failover.cjs')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $fixture }
. (Join-Path $fixture 'Deck.Environments.ps1')
foreach ($name in @('account1','account2')) {
    $dir=Join-Path $fixture "accounts/$name"; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'auth.json'),'{"tokens":{"access_token":"synthetic","account_id":"synthetic"}}')
}
Set-DeckPoolEntry $fixture pool @('*') Ordered | Out-Null
$source=Join-Path $PSScriptRoot '../bin/codex-auth.ps1'
if (-not (Test-Path -LiteralPath $source)) { $source=Join-Path $PSScriptRoot '../.local/bin/codex-auth.ps1' }
$launcher=[IO.File]::ReadAllText($source)
$accountAssignment='$accountsRoot = '''+(Join-Path $fixture 'accounts').Replace("'","''")+''''
$defaultAssignment='$defaultConfigPath = '''+(Join-Path $fixture 'default.toml').Replace("'","''")+''''
$launcher=[regex]::Replace($launcher,'(?m)^\$accountsRoot =.*$', [Text.RegularExpressions.MatchEvaluator]{param($m) $accountAssignment})
$launcher=[regex]::Replace($launcher,'(?m)^\$defaultConfigPath =.*$', [Text.RegularExpressions.MatchEvaluator]{param($m) $defaultAssignment})
[IO.File]::WriteAllText((Join-Path $fixture 'codex-auth.ps1'),$launcher,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $fixture 'default.toml'),'model = "must-not-inherit"')
$harness=@'
param([string]$Name,[string]$Member,[string]$Action,[string]$Inherit)
function global:codex {
    [pscustomobject]@{Environment=$env:CODEX_HOME; Arguments=@($args); HasAuth=(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'auth.json'))} | ConvertTo-Json -Compress -Depth 5
    $global:LASTEXITCODE=0
}
$arguments=@{Account=$Name}
if ($Member) { $arguments.UseAccount=$Member }
if ($Inherit) { $arguments.InheritFrom=$Inherit }
if ($Action) { $arguments.CodexArgs=@($Action) }
& (Join-Path $PSScriptRoot 'codex-auth.ps1') @arguments
exit $LASTEXITCODE
'@
$harnessPath=Join-Path $fixture 'launch.ps1'; [IO.File]::WriteAllText($harnessPath,$harness,[Text.UTF8Encoding]::new($true))
foreach ($member in @('','account1','account2')) {
    $launchParams=@('-Name','pool','-Action','hello');if($member){$launchParams+=@('-Member',$member)}
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath @launchParams
    if ($LASTEXITCODE -ne 0) { throw 'Pooled launch failed.' }
    $expectedMember=if($member){$member}else{'account1'}
    if (-not ($output -join ' ').Contains('active: '+$expectedMember)) { throw 'Requested/default quota member was not selected.' }
    $record=($output | Where-Object { $_ -like '{"Environment":*' }) | ConvertFrom-Json
    if ($record.Environment -ne (Join-Path $fixture 'accounts/pool') -or $record.HasAuth -or -not ($record.Arguments -join ' ').Contains('requires_openai_auth=false')) { throw 'Pool did not retain its independent environment/authentication.' }
}
$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath -Name newaccount -Action login
if ($LASTEXITCODE -ne 0) { throw 'New isolated account failed.' }
foreach ($file in @('config.toml','skills','AGENTS.md','auth.json')) { if (Test-Path -LiteralPath (Join-Path $fixture "accounts/newaccount/$file")) { throw 'New account inherited resources or credentials.' } }
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'accounts/newaccount') -PathType Container)) { throw 'New account was not created.' }
$instructions=Join-Path $fixture 'accounts/AGENTS.shared.md'
[IO.File]::WriteAllText($instructions,'legacy shared instructions')
[void](New-Item -ItemType HardLink -Path (Join-Path $fixture 'accounts/account1/AGENTS.md') -Target $instructions)
$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath -Name account1 -Action mcp
if ($LASTEXITCODE -ne 0) { throw 'Legacy account launch failed.' }
[IO.File]::WriteAllText($instructions,'changed shared instructions')
if ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account1/AGENTS.md')) -ne 'legacy shared instructions') { throw 'Legacy shared instructions were not detached.' }
$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath -Name inherited -Inherit account1 -Action login
if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $fixture 'accounts/inherited/auth.json')) -or [IO.File]::ReadAllText((Join-Path $fixture 'accounts/inherited/AGENTS.md')) -ne 'legacy shared instructions') { throw 'Explicit inheritance failed or copied credentials.' }
$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath -Name pool -Action mcp
if ($LASTEXITCODE -ne 0 -or ($output -join ' ').Contains('model_provider')) { throw 'Pooled MCP administration incorrectly started rotation.' }
if (@(Get-ChildItem -LiteralPath (Join-Path $fixture 'deck/sessions') -File -ErrorAction SilentlyContinue).Count) { throw 'Launch left connected session markers.' }
'PASS: real launcher keeps one pooled home across chosen members, needs no owner login, supports administration, and creates isolated accounts.'
