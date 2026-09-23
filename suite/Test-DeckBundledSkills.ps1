$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-skills-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/account1'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/account2'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'skills') -Destination (Join-Path $fixture 'skills') -Recurse
. (Join-Path $PSScriptRoot 'Deck.Environments.ps1')
. (Join-Path $PSScriptRoot 'Deck.BundledSkills.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};if(-not $failed){throw $Message}}
try {
    $catalog=@(Get-DeckBundledSkills $fixture)
    Assert ($catalog.Count -eq 4 -and @($catalog | Where-Object Name -eq 'debug-swarm').Count -eq 1 -and @($catalog | Where-Object { $_.Name -in @('ui-design','anti-ui-slop','ui-radar') }).Count -eq 3) 'Deck skill catalog was not discovered.'
    $invocationPolicy=[IO.File]::ReadAllText((Join-Path $fixture 'skills/debug-swarm/agents/openai.yaml'))
    Assert ($invocationPolicy -match '(?m)^\s*allow_implicit_invocation:\s*false\s*$') 'Debug Swarm must require explicit user invocation.'
    $skillInstructions=[IO.File]::ReadAllText((Join-Path $fixture 'skills/debug-swarm/SKILL.md'))
    Assert ($skillInstructions -match 'Foreground[^\r\n]*desktop-visible terminal window or tab') 'Debug Swarm must define foreground workers as desktop-visible terminals.'
    Assert ($skillInstructions -match 'tool-attached PTY is headless[^\r\n]*never satisfies a foreground request') 'Debug Swarm must reject headless tool PTYs for foreground requests.'
    Assert ($skillInstructions -match 'wt\.exe -w new new-tab' -and $skillInstructions -match 'normal visible desktop process') 'Debug Swarm must document a visible Windows foreground launch.'

    Sync-DeckBundledSkills $fixture account1 | Out-Null
    $debugSkill=@($catalog | Where-Object Name -eq 'debug-swarm')[0]
    $status=Get-DeckBundledSkillStatus $fixture account1 $debugSkill
    Assert ($status.Desired -and $status.Active -and -not $status.Blocked) 'Default Deck skill was not activated.'
    Assert (Test-Path -LiteralPath (Join-Path $fixture 'accounts/account1/skills/debug-swarm/SKILL.md') -PathType Leaf) 'Activated Deck skill is unavailable to CODEX_HOME.'

    Set-DeckBundledSkillEnabled $fixture account1 debug-swarm $false | Out-Null
    $status=Get-DeckBundledSkillStatus $fixture account1 $debugSkill
    Assert (-not $status.Desired -and -not $status.Active -and -not (Test-Path -LiteralPath $status.Target)) 'Per-entry disable did not remove the managed link.'
    Sync-DeckBundledSkills $fixture account1 | Out-Null
    Assert (-not (Test-Path -LiteralPath $status.Target)) 'Launch synchronization ignored a disabled override.'

    Set-DeckBundledSkillEnabled $fixture account1 debug-swarm $true | Out-Null
    Assert ((Get-DeckBundledSkillStatus $fixture account1 $debugSkill).Active) 'Re-enabling a Deck skill failed.'

    $private=Join-Path $fixture 'accounts/account2/skills/debug-swarm'
    [void][IO.Directory]::CreateDirectory($private)
    [IO.File]::WriteAllText((Join-Path $private 'SKILL.md'),'user owned',[Text.UTF8Encoding]::new($false))
    $messages=@(Sync-DeckBundledSkills $fixture account2)
    Assert ($messages.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $private 'SKILL.md')) -eq 'user owned') 'A user-owned same-name skill was overwritten or not reported.'
    Reject {Set-DeckBundledSkillEnabled $fixture account2 debug-swarm $true | Out-Null} 'Settings replaced a user-owned skill.'

    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/future'))
    Sync-DeckBundledSkills $fixture future | Out-Null
    Assert ((Get-DeckBundledSkillStatus $fixture future $debugSkill).Active) 'A future account did not receive the globally enabled skill.'
    'PASS: Deck skills are global by default, configurable per entry, launch-synchronized, and preserve user-owned collisions.'
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $target=[IO.Path]::GetFullPath($fixture).TrimEnd('\')
    if(-not $target.StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove a non-temporary test fixture.'}
    if(Test-Path -LiteralPath $target){
        foreach($link in Get-ChildItem -LiteralPath (Join-Path $target 'accounts') -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object LinkType -eq 'Junction'){
            [IO.Directory]::Delete($link.FullName)
        }
        [IO.Directory]::Delete($target,$true)
    }
}
