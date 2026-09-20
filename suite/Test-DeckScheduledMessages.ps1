$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.ScheduledMessages.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}

$cases=@{
    '10m'=600; '600s'=600; '600m'=36000; '6h'=21600; '1h30m'=5400; '2d3h4m5s'=183845
}
foreach($entry in $cases.GetEnumerator()){
    Assert ((ConvertFrom-DeckMessageDuration $entry.Key).TotalSeconds -eq $entry.Value) "Duration failed: $($entry.Key)"
}
foreach($invalid in @('','0s','10','1.5h','5x','-1m','1y')){
    $failed=$false;try{ConvertFrom-DeckMessageDuration $invalid | Out-Null}catch{$failed=$true}
    Assert $failed "Invalid duration accepted: $invalid"
}

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-message-test-'+[guid]::NewGuid().ToString('N'))
$suiteRoot=Join-Path $fixture '.codex-loop'
$accountDir=Join-Path $suiteRoot 'accounts/account2'
$folder=Join-Path $fixture 'project'
[void][IO.Directory]::CreateDirectory($accountDir)
[void][IO.Directory]::CreateDirectory($folder)
foreach($name in @('Deck.DelayedMessageWorker.ps1','Deck.ScheduledMessageWorker.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $suiteRoot $name)}
$threadId=[guid]::NewGuid().ToString()
$message="go on `"exactly`"`nnext line Ω"
$oldHome=$env:CODEX_HOME
try{
    $due=[DateTimeOffset]::UtcNow.AddSeconds(-1)
    $job=New-DeckMessageJobData delayed account2 $accountDir $folder $threadId $message $due $due.AddMinutes(5)
    $jobPath=Write-DeckMessageJob $suiteRoot delayed $job
    $global:queueArguments=$null
    function global:codex{$global:queueArguments=@($args);$global:LASTEXITCODE=0}
    Invoke-DeckDelayedMessageJob $suiteRoot $job.JobId
    Assert (-not (Test-Path -LiteralPath $jobPath)) 'Delayed job was not purged after delivery.'
    Assert (($global:queueArguments -join '|') -eq ('queue|--thread|'+$threadId+'|--message|'+$message)) "Delayed delivery changed the thread or message: $($global:queueArguments | ConvertTo-Json -Compress)"
    Assert ($env:CODEX_HOME -eq $oldHome) 'Delayed delivery did not restore CODEX_HOME.'
    Remove-Item Function:\codex -Force -ErrorAction SilentlyContinue
    Remove-Variable queueArguments -Scope Global -ErrorAction SilentlyContinue

    $fakeBin=Join-Path $fixture 'bin'
    $entry=Join-Path $fakeBin 'node_modules/@openai/codex/bin/codex.js'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $entry))
    [IO.File]::WriteAllText((Join-Path $fakeBin 'codex.ps1'),'throw "The npm shim must not run."',[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($entry,"const fs=require('fs');fs.writeFileSync(process.env.DECK_MESSAGE_TEST_CAPTURE,JSON.stringify({args:process.argv.slice(2),home:process.env.CODEX_HOME}),'utf8');",[Text.UTF8Encoding]::new($false))
    $capture=Join-Path $fixture 'queue.json'
    $oldPath=$env:PATH
    $env:PATH=$fakeBin+';'+$oldPath
    $env:DECK_MESSAGE_TEST_CAPTURE=$capture
    try{
        Assert ((Get-Command codex).Source -eq (Join-Path $fakeBin 'codex.ps1')) "Native queue test resolved a different Codex launcher: $((Get-Command codex).Source)"
        $job=New-DeckMessageJobData delayed account2 $accountDir $folder $threadId $message $due $due.AddMinutes(5)
        [void](Write-DeckMessageJob $suiteRoot delayed $job)
        Invoke-DeckDelayedMessageJob $suiteRoot $job.JobId
        $queued=[IO.File]::ReadAllText($capture,[Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert (($queued.args -join '|') -eq ('queue|--thread|'+$threadId+'|--message|'+$message)) 'Native Codex queue changed a quoted or Unicode message.'
        Assert ($queued.home -eq $accountDir) 'Native Codex queue used the wrong account home.'
    }finally{$env:PATH=$oldPath}

    $authScript=Join-Path $fixture 'codex-auth-mock.ps1'
    $capture=Join-Path $fixture 'resume.json'
    $mock=@'
[CmdletBinding(PositionalBinding=$false)]
param([string]$Account,[string]$Failover,[switch]$Resume,[string]$ResumePromptEnvironment,[Parameter(ValueFromRemainingArguments=$true)][string[]]$CodexArgs)
$prompt=[Environment]::GetEnvironmentVariable($ResumePromptEnvironment,'Process')
[IO.File]::WriteAllText($env:DECK_MESSAGE_TEST_CAPTURE,([ordered]@{Account=$Account;Failover=$Failover;Resume=$Resume.IsPresent;Prompt=$prompt;Args=@($CodexArgs)}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
    [IO.File]::WriteAllText($authScript,$mock,[Text.UTF8Encoding]::new($true))
    $script:registered=$null;$script:unregistered=@()
    function New-ScheduledTaskTrigger{param([switch]$Once,[datetime]$At)[pscustomobject]@{At=$At;EndBoundary=''}}
    function New-ScheduledTaskAction{param($Execute,$Argument,$WorkingDirectory)[pscustomobject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory}}
    function New-ScheduledTaskPrincipal{param($UserId,$LogonType,$RunLevel)[pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
    function New-ScheduledTaskSettingsSet{param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,$DeleteExpiredTaskAfter,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)[pscustomobject]@{StartWhenAvailable=$StartWhenAvailable;MultipleInstances=$MultipleInstances;ExecutionTimeLimit=$ExecutionTimeLimit;DeleteExpiredTaskAfter=$DeleteExpiredTaskAfter}}
    function Register-ScheduledTask{param($TaskName,$Action,$Trigger,$Settings,$Principal,$Description,[switch]$Force)$script:registered=[pscustomobject]@{TaskName=$TaskName;Action=$Action;Trigger=$Trigger;Settings=$Settings;Principal=$Principal;Description=$Description}}
    function Unregister-ScheduledTask{param($TaskName,[switch]$Confirm,$ErrorAction)$script:unregistered+=@($TaskName)}
    $scheduled=Register-DeckScheduledMessage $suiteRoot account2 $accountDir $folder $threadId $message (ConvertFrom-DeckMessageDuration '10m') $authScript
    Assert ($script:registered.TaskName -eq $scheduled.TaskName) 'Scheduled task was not registered under its unique name.'
    Assert ($script:registered.Action.Argument -notmatch [regex]::Escape($message)) 'Message leaked into Scheduled Task arguments.'
    Assert ($script:registered.Action.Argument -match '-NoExit' -and $script:registered.Principal.LogonType -eq 'Interactive') 'Scheduled task is not a visible interactive PowerShell terminal.'
    $env:DECK_MESSAGE_TEST_CAPTURE=$capture
    Push-Location $fixture
    try{Invoke-DeckScheduledMessageJob $suiteRoot $scheduled.JobId}finally{Pop-Location}
    $record=[IO.File]::ReadAllText($capture,[Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($record.Account -eq 'account2' -and $record.Failover -eq 'Off' -and $record.Resume) 'Scheduled worker did not launch the owning account resume path.'
    Assert (($record.Args -join '|') -eq $threadId -and $record.Prompt -eq $message) "Scheduled worker changed the conversation ID or message: $($record | ConvertTo-Json -Compress)"
    Assert ($scheduled.TaskName -in $script:unregistered) 'Scheduled worker did not purge its task.'
    $scheduledDirectory=Join-Path $suiteRoot 'deck/scheduled-messages'
    Assert (-not @(Get-ChildItem -LiteralPath $scheduledDirectory -File -ErrorAction SilentlyContinue).Count) 'Scheduled worker left a job payload behind.'
}finally{
    $env:CODEX_HOME=$oldHome
    Remove-Item Env:DECK_MESSAGE_TEST_CAPTURE -ErrorAction SilentlyContinue
    Remove-Item Function:\codex -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
'PASS: duration parsing, exact delayed queueing, private task payloads, visible scheduled resume, and self-purging jobs.'
