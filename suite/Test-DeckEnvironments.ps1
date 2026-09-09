# Synthetic environment regression tests. Never touches installed account state.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.Terminal.ps1')
. (Join-Path $PSScriptRoot 'Deck.Failover.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert $failed $Message }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-environments-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
foreach ($name in @('account1','account2','account3')) {
    $dir=Join-Path $fixture "accounts/$name"
    [void][IO.Directory]::CreateDirectory((Join-Path $dir 'skills/example'))
    [void][IO.Directory]::CreateDirectory((Join-Path $dir 'memories'))
    [IO.File]::WriteAllText((Join-Path $dir 'auth.json'),'{"tokens":{"access_token":"synthetic","account_id":"synthetic"}}')
    [IO.File]::WriteAllText((Join-Path $dir 'skills/example/SKILL.md'),"private $name")
    [IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'),"instructions $name")
}
Set-DeckPoolEntry $fixture pool @('*') Ordered | Out-Null
Assert ((Get-DeckEntryNames $fixture)[0] -eq 'pool') 'Pool was not first.'
Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'accounts/pool/auth.json'))) 'Pool owns credentials.'
Assert (@(Resolve-DeckEntryPool $fixture (Get-DeckPoolEntry $fixture pool)).Count -eq 3) 'Wildcard membership failed.'
foreach($pair in @(@('account1','free'),@('account2','plus'))){
    $payload=ConvertTo-Json -Compress @{ 'https://api.openai.com/auth'=@{chatgpt_plan_type=$pair[1]} }
    $token='synthetic.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')+'.synthetic'
    Write-DeckEnvironmentJson (Join-Path $fixture "accounts/$($pair[0])/auth.json") @{tokens=@{access_token=$token;account_id='synthetic'}}
}
Set-DeckPoolEntry $fixture freepool @('*free') Ordered | Out-Null
Set-DeckPoolEntry $fixture paidpool @('*paid') Ordered | Out-Null
Assert ((Resolve-DeckEntryPool $fixture (Get-DeckPoolEntry $fixture freepool)) -eq 'account1') 'Free membership includes other/unknown plans.'
Assert ((Resolve-DeckEntryPool $fixture (Get-DeckPoolEntry $fixture paidpool)) -eq 'account2') 'Paid membership includes other/unknown plans.'
Set-DeckPoolEntry $fixture preview @('*paid') Ordered -ValidateOnly
Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'accounts/preview'))) 'Validation created a pooled environment.'
Set-DeckResourceSharing $fixture account1 @('account2') @('memories') -ValidateOnly
Assert (@((Get-DeckSharing $fixture account2).Bindings).Count -eq 0) 'Validation applied sharing.'
Set-DeckPoolEntry $fixture selected @('account2') Best | Out-Null
Assert ((Resolve-DeckEntryPool $fixture (Get-DeckPoolEntry $fixture selected)) -eq 'account2') 'Selected membership failed.'
Reject { Set-DeckPoolEntry $fixture account1 @('*') Ordered } 'Ordinary account converted to pool.'
Reject { Set-DeckPoolEntry $fixture bad @('pool') Ordered } 'Nested pool accepted.'
Reject { Set-DeckPoolEntry $fixture bad @('account1','ACCOUNT1') Ordered } 'Duplicate membership accepted.'
Assert (@(Get-DeckSharedArguments $fixture account3).Count -eq 0) 'Isolation not default.'
Set-DeckResourceSharing $fixture account1 @('account2') @('skills/example','AGENTS.md','memories') | Out-Null
Assert ((Get-Item -LiteralPath (Join-Path $fixture 'accounts/account2/skills/example')).LinkType -eq 'Junction') 'Skill not linked.'
[IO.File]::WriteAllText((Join-Path $fixture 'accounts/account2/skills/example/SKILL.md'),'shared edit')
Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account1/skills/example/SKILL.md')) -eq 'shared edit') 'Live edits not shared.'
Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account3/skills/example/SKILL.md')) -eq 'private account3') 'Unselected account changed.'
[IO.File]::WriteAllText((Join-Path $fixture 'accounts/account1/AGENTS.md'),'new instructions')
[void](Get-DeckSharedArguments $fixture account2)
Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account2/AGENTS.md')) -eq 'new instructions') 'Instructions did not refresh.'
Reject { Set-DeckResourceSharing $fixture account2 @('account3') @('skills/example') } 'Chained sharing accepted.'
Reject { Set-DeckResourceSharing $fixture account1 @('account2') @('skills') } 'Overlapping sharing accepted.'
Reject { Assert-DeckEntryUnreferenced $fixture account1 } 'Resource owner could be deleted.'
Reject { Assert-DeckEntryUnreferenced $fixture account2 } 'Consumer could be renamed.'
foreach ($bad in @('auth.json','config.toml','sessions','state_5.sqlite','../outside','skills/../outside','plugins')) {
    Reject { Set-DeckResourceSharing $fixture account1 @('account3') @($bad) } "Unsafe resource accepted: $bad"
}
Set-DeckResourceSharing $fixture '' @('account2') @('skills/example','AGENTS.md','memories') -Detach | Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account2/skills/example/SKILL.md')) -eq 'private account2') 'Unshare did not restore private skill.'
Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account2/AGENTS.md')) -eq 'instructions account2') 'Unshare did not restore instructions.'
Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account1/skills/example/SKILL.md')) -eq 'shared edit') 'Unshare changed owner data.'
Set-DeckResourceSharing $fixture account1 @('*') @('memories') | Out-Null
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/later'))
Assert (@((Get-DeckSharing $fixture later).Bindings).Count -eq 0) 'Future account inherited sharing.'
Assert (@(Get-DeckFailoverArguments 'http://127.0.0.1:1234/example' -NoAccountAuth) -contains 'model_providers.deck_failover.requires_openai_auth=false') 'Pool still needs owner auth.'
# Exercise MCP configuration parsing with the installed CLI, without contacting a server.
if (Get-Command codex -ErrorAction SilentlyContinue) {
    $config='[mcp_servers.example]' + "`n" + 'command = "synthetic-mcp"' + "`n" + 'args = ["hello world", "a\\b"]' + "`n" + 'enabled = false' + "`n"
    [IO.File]::WriteAllText((Join-Path $fixture 'accounts/account1/config.toml'),$config)
    $definition=Get-DeckMcpDefinition (Join-Path $fixture 'accounts/account1') example
    Assert ($definition.command -eq 'synthetic-mcp') 'MCP command not read.'
    Set-DeckResourceSharing $fixture account1 @('account3') @('mcp:example') | Out-Null
    $arguments=@(Get-DeckSharedArguments $fixture account3)
    Assert (($arguments -join ' ') -match 'mcp_servers.example=') 'MCP override missing.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'accounts/account3/config.toml'))) 'MCP sharing rewrote recipient config.'
    $savedHome=$env:CODEX_HOME; $savedErrors=$ErrorActionPreference
    try {
        $env:CODEX_HOME=Join-Path $fixture 'accounts/account3'; $ErrorActionPreference='Continue'
        $arguments=@(ConvertTo-DeckCodexArguments $arguments)
        $parsedOutput=& codex @arguments mcp get example --json 2>$null
        $ErrorActionPreference=$savedErrors
        Assert ($LASTEXITCODE -eq 0) 'Codex rejected shared MCP override.'
        $parsed=($parsedOutput -join "`n") | ConvertFrom-Json
        Assert ($parsed.transport.command -eq 'synthetic-mcp' -and $parsed.transport.args[0] -eq 'hello world') 'MCP override quoting changed values.'
    } finally { $env:CODEX_HOME=$savedHome; $ErrorActionPreference=$savedErrors }
}
Write-Output 'PASS: pooled membership, ordering, default isolation, live resource sharing, private restoration, instructions, MCP overrides and path guards.'
