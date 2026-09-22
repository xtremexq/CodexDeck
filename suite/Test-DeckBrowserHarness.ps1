$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-browser-harness-'+[guid]::NewGuid().ToString('N'))
$originalPath=$env:PATH
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'bin'))
foreach($relative in @('accounts/account1','accounts/account2','deck')){[void][IO.Directory]::CreateDirectory((Join-Path $fixture $relative))}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deck.Integrations.json') -Destination $fixture
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deck.DefaultGlobalRules.md') -Destination $fixture
$fake=Join-Path $fixture 'bin/browser-harness.cmd'
[IO.File]::WriteAllText($fake,(@'
@echo off
if "%1"=="--version" (echo browser-harness 0.1.10& exit /b 0)
if "%1"=="skill" (echo ---& echo name: browser-harness& echo description: Test skill& echo ---& echo Test browser skill& exit /b 0)
exit /b 1
'@).Trim()+"`r`n",[Text.Encoding]::ASCII)
$env:PATH=(Join-Path $fixture 'bin')+';'+$originalPath
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.GlobalRules.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    $account1=Join-Path $fixture 'accounts/account1'
    $account2=Join-Path $fixture 'accounts/account2'
    $base=[IO.File]::ReadAllText((Join-Path $fixture 'Deck.DefaultGlobalRules.md')).Trim()
    $status=Get-DeckIntegrationStatus $fixture browser_harness
    Assert ($status.Valid -and $status.Version -eq '0.1.10' -and $status.Executable -eq $fake) 'Existing Browser Harness CLI was not detected.'
    $hash=(Get-FileHash -LiteralPath $fake).Hash
    Assert ((Get-DeckGlobalRuleText $fixture $account1) -eq $base) 'Fresh default Global Rules were not loaded.'
    $debug='Debug swarms: Use the debug-swarm skill only when the user explicitly requests a debug swarm or parallel independent Codex CLI workers; never infer it because parallel work could help. Follow its account, foreground/background, isolation, evidence, and reporting rules.'
    $browser='Browser Harness: For browser automation or live browser debugging, use the installed Browser Harness. Run `harness` to start its local services, `harness status` to verify them, and `browser-harness --doctor` when the CLI or browser connection needs diagnosis.'
    [IO.File]::WriteAllText((Join-Path $fixture 'deck/global-rules.md'),($base+"`n`n"+$debug+"`n`n"+$browser),[Text.UTF8Encoding]::new($false))
    Assert ((Get-DeckGlobalRuleText $fixture $account1) -eq $base) 'Legacy stock rules were not filtered when integrations were unavailable.'
    [void][IO.Directory]::CreateDirectory((Join-Path $account1 'skills/debug-swarm'))
    [IO.File]::WriteAllText((Join-Path $account1 'skills/debug-swarm/SKILL.md'),'debug skill')
    Assert ((Get-DeckGlobalRuleText $fixture $account1) -match 'Debug swarms:' -and (Get-DeckGlobalRuleText $fixture $account1) -notmatch 'Browser Harness:') 'Debug rule did not follow skill availability.'
    [IO.File]::WriteAllText((Join-Path $fixture 'deck/settings.json'),'{"BrowserHarnessEnabled":true}')
    $owned=Join-Path $account2 'skills/browser-harness'
    [void][IO.Directory]::CreateDirectory($owned)
    [IO.File]::WriteAllText((Join-Path $owned 'SKILL.md'),'user owned')
    Sync-DeckBrowserHarnessSkill $fixture $account1 $true
    Sync-DeckBrowserHarnessSkill $fixture $account2 $true
    Assert ((Get-DeckIntegrationStatus $fixture browser_harness).Version -eq '0.1.10' -and (Get-FileHash -LiteralPath $fake).Hash -eq $hash) 'Recognition or skill sync changed the installed CLI.'
    Assert ((Get-Item -LiteralPath (Join-Path $account1 'skills/browser-harness')).LinkType -eq 'Junction') 'Deck did not link the generated skill to a new account.'
    Assert ([IO.File]::ReadAllText((Join-Path $owned 'SKILL.md')) -eq 'user owned') 'Deck replaced a user owned Browser Harness skill.'
    $active=Get-DeckGlobalRuleText $fixture $account1
    Assert ($active -match 'Debug swarms:' -and $active -match 'Browser Harness:' -and $active -match 'Usage efficiency:') 'Enabled default rules are incomplete.'
    Sync-DeckBrowserHarnessSkill $fixture $account1 $false
    Assert (-not (Test-Path -LiteralPath (Join-Path $account1 'skills/browser-harness')) -and (Test-Path -LiteralPath $fake)) 'Disabling removed more than the managed skill link.'
    Assert ((Get-DeckGlobalRuleText $fixture $account1) -notmatch 'Browser Harness:') 'Disabled Browser Harness still appeared in Global Rules.'
    [IO.File]::WriteAllText((Join-Path $fixture 'deck/global-rules.md'),'')
    Assert (-not (Get-DeckGlobalRuleText $fixture $account1)) 'Blank custom rules did not disable Global Rules.'
    Assert (Test-Path -LiteralPath (Join-Path $fixture 'integrations/browser-harness-detection.json')) 'Browser Harness detection was not cached.'
    [IO.File]::AppendAllText($fake,"`r`nrem changed executable`r`n")
    Assert ((Get-DeckIntegrationStatus $fixture browser_harness).Version -eq '0.1.10') 'Changed Browser Harness executable was not rechecked.'
    Assert (([IO.File]::ReadAllText((Join-Path $fixture 'integrations/browser-harness-detection.json')) | ConvertFrom-Json).length -eq (Get-Item -LiteralPath $fake).Length) 'Browser Harness detection cache was not refreshed.'
    'PASS: existing Browser Harness detection, untouched CLI/user skill, managed account link, and conditional Global Rules.'
}finally{
    $env:PATH=$originalPath
    $target=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if(-not $target.StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove a non-temporary fixture.'}
    $link=Join-Path (Join-Path $fixture 'accounts/account1') 'skills/browser-harness'
    if(Test-Path -LiteralPath $link){[IO.Directory]::Delete($link)}
    if(Test-Path -LiteralPath $target){[IO.Directory]::Delete($target,$true)}
}
