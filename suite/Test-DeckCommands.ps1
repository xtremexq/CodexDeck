$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Commands.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-commands-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $pool=Join-Path $fixture 'accounts/pool'
    [void][IO.Directory]::CreateDirectory((Join-Path $pool 'skills'))
    foreach($name in @('account','pool','check','usage')){
        $target=Join-Path $pool "skills/$name"
        [void][IO.Directory]::CreateDirectory($target)
        [IO.File]::WriteAllText((Join-Path $target '.codexdeck-managed'),'codexdeck-command-skill-v1')
        [IO.File]::WriteAllText((Join-Path $target 'SKILL.md'),'legacy')
    }
    $custom=Join-Path $fixture 'accounts/custom'
    [void][IO.Directory]::CreateDirectory((Join-Path $custom 'skills/account'))
    [IO.File]::WriteAllText((Join-Path $custom 'skills/account/SKILL.md'),'user-owned')
    Remove-DeckLegacyCommandSkillsForAccounts $fixture | Out-Null
    foreach($name in @('account','pool','check','usage')){
        if(Test-Path -LiteralPath (Join-Path $pool "skills/$name")){throw "Legacy AI-backed command skill was not removed: $name"}
    }
    if([IO.File]::ReadAllText((Join-Path $custom 'skills/account/SKILL.md')) -ne 'user-owned'){throw 'An unmanaged same-name skill was removed.'}
    foreach($name in @('account','pool','usage','check')){
        $wrapper=Join-Path $PSScriptRoot "../bin/$name.cmd"
        if(-not (Test-Path -LiteralPath $wrapper -PathType Leaf)){throw "Missing local shell command: $name"}
    }
    if([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1')) -match '\bRead-Host\b'){
        throw 'Local shell commands must not wait for interactive stdin inside the Codex TUI.'
    }
    Write-Output 'PASS: local shell commands are packaged and legacy AI-backed command skills are removed without touching unmanaged skills.'
} finally {
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
