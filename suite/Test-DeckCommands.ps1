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
    foreach($name in @('account','pool','usage','delay','schedule','check','deck','context','autocompact')){
        $wrapper=Join-Path $PSScriptRoot "../bin/$name.cmd"
        if(-not (Test-Path -LiteralPath $wrapper -PathType Leaf)){throw "Missing local shell command: $name"}
    }
    $savedPath=$env:PATH
    try{
        $env:PATH=(Join-Path $PSScriptRoot '../bin')+[IO.Path]::PathSeparator+$savedPath
        if((Get-Command autocompact -ErrorAction Stop).Name -ne 'autocompact.cmd'){throw 'Deck !autocompact command is unavailable.'}
        if((Get-Command compact -ErrorAction Stop).Name -eq 'compact.cmd'){throw 'Deck must leave the Windows compact command available.'}
    }finally{$env:PATH=$savedPath}
    if([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../bin/deck.cmd')) -notmatch 'codex-deck\.cmd'){
        throw '!deck does not open the desktop companion.'
    }
    if([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1')) -match '\bRead-Host\b'){
        throw 'Local shell commands must not wait for interactive stdin inside the Codex TUI.'
    }
    $accountDir=Join-Path $fixture 'accounts/account1'
    $sessionDir=Join-Path $fixture 'deck/sessions'
    [void][IO.Directory]::CreateDirectory($accountDir)
    [void][IO.Directory]::CreateDirectory($sessionDir)
    $sessionPath=Join-Path $sessionDir 'live.json'
    $process=Get-Process -Id $PID
    try{$startTicks=$process.StartTime.ToUniversalTime().Ticks}finally{$process.Dispose()}
    @{Account='account1';ProcessId=$PID;ProcessStartTicks=$startTicks;CompactUrl=('http://127.0.0.1:65534/'+('a'*64)+'/compact')} | ConvertTo-Json | Set-Content -LiteralPath $sessionPath
    $oldHome=$env:CODEX_HOME; $oldSession=$env:CODEX_DECK_SESSION_PATH; $oldCompact=$env:CODEX_DECK_COMPACT_URL
    try{
        $env:CODEX_HOME=$accountDir; $env:CODEX_DECK_SESSION_PATH=$sessionPath
        Remove-Item Env:CODEX_DECK_COMPACT_URL -ErrorAction SilentlyContinue
        $ErrorActionPreference='Continue'
        $compactOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1') autocompact 2>&1
        if($LASTEXITCODE -eq 0 -or ($compactOutput -join ' ') -notmatch 'Compaction request failed:'){throw 'Compaction command did not discover the attached session marker.'}
        Remove-Item -LiteralPath $sessionPath
        $compactOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../bin/codex-deck-session.ps1') autocompact 2>&1
        if($LASTEXITCODE -eq 0 -or ($compactOutput -join ' ') -notmatch 'no attached compaction control'){throw 'Compaction command accepted a missing session marker.'}
    }finally{$ErrorActionPreference='Stop';$env:CODEX_HOME=$oldHome;$env:CODEX_DECK_SESSION_PATH=$oldSession;$env:CODEX_DECK_COMPACT_URL=$oldCompact}
    Write-Output 'PASS: local shell commands, including delayed and scheduled messages, are packaged and legacy AI-backed command skills are removed without touching unmanaged skills.'
} finally {
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
