function ConvertFrom-DeckMessageDuration([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Provide a duration such as 10m, 600s, or 6h.' }
    $text=$Value.Trim().ToLowerInvariant()
    $matches=[regex]::Matches($text,'([0-9]+)([smhd])')
    if(-not $matches.Count -or (($matches | ForEach-Object Value) -join '') -ne $text){throw "Invalid duration '$Value'. Use whole numbers followed by s, m, h, or d."}
    [decimal]$seconds=0
    foreach($match in $matches){
        [decimal]$amount=0
        if(-not [decimal]::TryParse($match.Groups[1].Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$amount)){throw 'Duration is too large.'}
        $factor=switch($match.Groups[2].Value){'s'{1};'m'{60};'h'{3600};'d'{86400}}
        $seconds += $amount*$factor
        if($seconds -gt 31536000){throw 'Duration cannot exceed 365 days.'}
    }
    if($seconds -lt 1){throw 'Duration must be at least one second.'}
    return [TimeSpan]::FromSeconds([double]$seconds)
}

function ConvertTo-DeckMessageArgument([AllowEmptyString()][string]$Value) {
    if($null -eq $Value){$Value=''}
    if($Value.Length -gt 0 -and $Value -notmatch '[\s"]'){return $Value}
    $quoted=[Text.StringBuilder]::new(); [void]$quoted.Append('"'); $slashes=0
    foreach($character in $Value.ToCharArray()){
        if($character -eq '\'){$slashes++;continue}
        if($character -eq '"'){
            [void]$quoted.Append(('\'*($slashes*2+1)));[void]$quoted.Append('"');$slashes=0;continue
        }
        if($slashes){[void]$quoted.Append(('\'*$slashes));$slashes=0}
        [void]$quoted.Append($character)
    }
    if($slashes){[void]$quoted.Append(('\'*($slashes*2)))}
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Assert-DeckMessageJobId([string]$JobId) {
    if($JobId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid scheduled message job ID.'}
}

function Get-DeckMessageJobDirectory([string]$SuiteRoot,[ValidateSet('delayed','scheduled')][string]$Kind) {
    $directory=Join-Path $SuiteRoot ('deck/'+$Kind+'-messages')
    if(-not (Test-Path -LiteralPath $directory)){[void][IO.Directory]::CreateDirectory($directory)}
    $item=Get-Item -LiteralPath $directory -ErrorAction Stop
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Scheduled message storage must be a real directory.'}
    return $item.FullName
}

function Write-DeckMessageJob([string]$SuiteRoot,[ValidateSet('delayed','scheduled')][string]$Kind,[hashtable]$Job) {
    Assert-DeckMessageJobId ([string]$Job.JobId)
    $directory=Get-DeckMessageJobDirectory $SuiteRoot $Kind
    $path=Join-Path $directory ($Job.JobId+'.json')
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($Job | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -ErrorAction Stop
    }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    return $path
}

function Read-DeckMessageJob([string]$Path,[ValidateSet('delayed','scheduled')][string]$Kind,[string]$ExpectedJobId) {
    Assert-DeckMessageJobId $ExpectedJobId
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1048576){throw 'Invalid scheduled message job file.'}
    $job=[IO.File]::ReadAllText($item.FullName,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if(-not $job -or $job.Schema -ne 1 -or $job.Kind -ne $Kind -or $job.JobId -ne $ExpectedJobId){throw 'Scheduled message job metadata does not match.'}
    if($job.OwnerAccount -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){throw 'Scheduled message owner is invalid.'}
    $thread=[guid]::Empty
    if(-not [guid]::TryParse([string]$job.ThreadId,[ref]$thread)){throw 'Scheduled message thread ID is invalid.'}
    if([string]::IsNullOrWhiteSpace([string]$job.Message) -or ([string]$job.Message).Length -gt 200000){throw 'Scheduled message is empty or too large.'}
    [void][DateTimeOffset]::Parse([string]$job.DueAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    [void][DateTimeOffset]::Parse([string]$job.ExpiresAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    return $job
}

function New-DeckMessageJobData {
    param(
        [ValidateSet('delayed','scheduled')][string]$Kind,
        [string]$OwnerAccount,
        [string]$CodexHome,
        [string]$Folder,
        [string]$ThreadId,
        [string]$Message,
        [DateTimeOffset]$DueAt,
        [DateTimeOffset]$ExpiresAt,
        [string]$AuthScript,
        [string]$TaskName
    )
    if($OwnerAccount -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){throw 'This session does not have a valid owning account.'}
    $thread=[guid]::Empty
    if(-not [guid]::TryParse($ThreadId,[ref]$thread)){throw 'Codex did not expose a valid CODEX_THREAD_ID to this local command.'}
    if([string]::IsNullOrWhiteSpace($Message)){throw 'Provide a message after the duration.'}
    if($Message.Length -gt 200000){throw 'Messages are limited to 200,000 characters.'}
    $jobId=[guid]::NewGuid().ToString('N')
    $job=[ordered]@{
        Schema=1; Kind=$Kind; JobId=$jobId; OwnerAccount=$OwnerAccount
        CodexHome=[IO.Path]::GetFullPath($CodexHome); Folder=[IO.Path]::GetFullPath($Folder)
        ThreadId=$thread.ToString(); Message=$Message
        CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); DueAtUtc=$DueAt.ToUniversalTime().ToString('o')
        ExpiresAtUtc=$ExpiresAt.ToUniversalTime().ToString('o')
    }
    if($AuthScript){$job.AuthScript=[IO.Path]::GetFullPath($AuthScript)}
    if($TaskName){$job.TaskName=$TaskName}
    return $job
}

function Start-DeckDelayedMessage {
    param([string]$SuiteRoot,[string]$OwnerAccount,[string]$CodexHome,[string]$Folder,[string]$ThreadId,[string]$Message,[TimeSpan]$Delay)
    $worker=Join-Path $SuiteRoot 'Deck.DelayedMessageWorker.ps1'
    if(-not (Test-Path -LiteralPath $worker -PathType Leaf)){throw 'Delayed-message worker is not installed. Reinstall Codex Deck.'}
    $due=[DateTimeOffset]::Now.Add($Delay)
    $job=New-DeckMessageJobData delayed $OwnerAccount $CodexHome $Folder $ThreadId $Message $due $due.AddDays(1)
    $path=Write-DeckMessageJob $SuiteRoot delayed $job
    try{
        $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,'-JobId',$job.JobId)
        $argumentLine=($arguments | ForEach-Object {ConvertTo-DeckMessageArgument ([string]$_)}) -join ' '
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
        if(-not $process){throw 'The delayed-message timer did not start.'}
        if($process -is [IDisposable]){$process.Dispose()}
    }catch{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue;throw}
    return [pscustomobject]@{JobId=$job.JobId;DueAt=$due;ThreadId=$job.ThreadId}
}

function Invoke-DeckMessageQueue([string]$ThreadId,[string]$Message) {
    $command=Get-Command codex -ErrorAction Stop | Select-Object -First 1
    $arguments=@('queue','--thread',$ThreadId,'--message',$Message)
    $executable=$null
    if($command.CommandType -in @('ExternalScript','Application') -and $command.Source){
        $entry=Join-Path (Split-Path -Parent $command.Source) 'node_modules/@openai/codex/bin/codex.js'
        if(Test-Path -LiteralPath $entry -PathType Leaf){
            $localNode=Join-Path (Split-Path -Parent $command.Source) 'node.exe'
            $executable=if(Test-Path -LiteralPath $localNode -PathType Leaf){$localNode}else{(Get-Command node.exe -ErrorAction Stop).Source}
            $arguments=@($entry)+$arguments
        }elseif([IO.Path]::GetExtension($command.Source) -eq '.exe'){$executable=$command.Source}
    }
    if($executable){
        $startInfo=[Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName=$executable
        $startInfo.Arguments=($arguments | ForEach-Object {ConvertTo-DeckMessageArgument ([string]$_)}) -join ' '
        $startInfo.UseShellExecute=$false
        $startInfo.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($startInfo)
        try{
            $process.WaitForExit()
            if($process.ExitCode -ne 0){throw "Codex queue exited with code $($process.ExitCode)."}
        }finally{$process.Dispose()}
    }else{
        & $command @arguments
        if($LASTEXITCODE -ne 0){throw "Codex queue exited with code $LASTEXITCODE."}
    }
}

function Invoke-DeckDelayedMessageJob([string]$SuiteRoot,[string]$JobId) {
    Assert-DeckMessageJobId $JobId
    $path=Join-Path (Get-DeckMessageJobDirectory $SuiteRoot delayed) ($JobId+'.json')
    try{
        $job=Read-DeckMessageJob $path delayed $JobId
        $due=[DateTimeOffset]::Parse([string]$job.DueAtUtc)
        $expires=[DateTimeOffset]::Parse([string]$job.ExpiresAtUtc)
        while([DateTimeOffset]::UtcNow -lt $due.ToUniversalTime()){
            $remaining=$due.ToUniversalTime()-[DateTimeOffset]::UtcNow
            $milliseconds=[Math]::Max(1,[Math]::Min(3600000,[int][Math]::Ceiling($remaining.TotalMilliseconds)))
            Start-Sleep -Milliseconds $milliseconds
        }
        if([DateTimeOffset]::UtcNow -gt $expires.ToUniversalTime()){throw 'The delayed message expired before delivery.'}
        if(-not (Test-Path -LiteralPath $job.CodexHome -PathType Container)){throw 'The owning Codex account no longer exists.'}
        $savedHome=$env:CODEX_HOME
        try{
            $env:CODEX_HOME=[string]$job.CodexHome
            Invoke-DeckMessageQueue ([string]$job.ThreadId) ([string]$job.Message)
        }finally{$env:CODEX_HOME=$savedHome}
    }finally{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
}

function Register-DeckScheduledMessage {
    param([string]$SuiteRoot,[string]$OwnerAccount,[string]$CodexHome,[string]$Folder,[string]$ThreadId,[string]$Message,[TimeSpan]$Delay,[string]$AuthScript)
    if($env:OS -ne 'Windows_NT'){throw 'Scheduled messages require Windows Task Scheduler.'}
    $worker=Join-Path $SuiteRoot 'Deck.ScheduledMessageWorker.ps1'
    if(-not (Test-Path -LiteralPath $worker -PathType Leaf)){throw 'Scheduled-message worker is not installed. Reinstall Codex Deck.'}
    if(-not (Test-Path -LiteralPath $AuthScript -PathType Leaf)){throw 'codex-auth is not installed.'}
    $due=[DateTimeOffset]::Now.Add($Delay)
    $jobId=[guid]::NewGuid().ToString('N')
    $taskName='CodexDeck Scheduled Message '+$jobId
    $job=New-DeckMessageJobData scheduled $OwnerAccount $CodexHome $Folder $ThreadId $Message $due $due.AddDays(7) $AuthScript $taskName
    $job.JobId=$jobId
    $path=Write-DeckMessageJob $SuiteRoot scheduled $job
    try{
        $trigger=New-ScheduledTaskTrigger -Once -At $due.LocalDateTime
        $trigger.EndBoundary=$due.AddDays(7).LocalDateTime.ToString('s')
        $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments=@('-NoLogo','-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File',$worker,'-JobId',$jobId)
        $argumentLine=($arguments | ForEach-Object {ConvertTo-DeckMessageArgument ([string]$_)}) -join ' '
        $action=New-ScheduledTaskAction -Execute $powerShell -Argument $argumentLine -WorkingDirectory $SuiteRoot
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal=New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -DeleteExpiredTaskAfter (New-TimeSpan -Days 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Opens the owning Codex Deck account, resumes one conversation, submits its saved message, and removes itself.' -Force | Out-Null
    }catch{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue;throw}
    return [pscustomobject]@{JobId=$jobId;TaskName=$taskName;DueAt=$due;ThreadId=$job.ThreadId}
}

function Invoke-DeckScheduledMessageJob([string]$SuiteRoot,[string]$JobId) {
    Assert-DeckMessageJobId $JobId
    $directory=Get-DeckMessageJobDirectory $SuiteRoot scheduled
    $path=Join-Path $directory ($JobId+'.json')
    $claimed=Join-Path $directory ($JobId+'.running')
    Move-Item -LiteralPath $path -Destination $claimed -ErrorAction Stop
    $job=$null
    try{
        $job=Read-DeckMessageJob $claimed scheduled $JobId
        Unregister-ScheduledTask -TaskName ([string]$job.TaskName) -Confirm:$false -ErrorAction SilentlyContinue
        $expires=[DateTimeOffset]::Parse([string]$job.ExpiresAtUtc)
        if([DateTimeOffset]::UtcNow -gt $expires.ToUniversalTime()){throw 'This scheduled message expired before Windows could run it.'}
        $accountDir=Get-Item -LiteralPath ([string]$job.CodexHome) -ErrorAction Stop
        if(-not $accountDir.PSIsContainer -or $accountDir.Name -ne $job.OwnerAccount -or $accountDir.Parent.Name -ne 'accounts'){throw 'The scheduled message owner no longer matches its account directory.'}
        if(-not (Test-Path -LiteralPath $job.Folder -PathType Container)){throw "The conversation folder no longer exists: $($job.Folder)"}
        if(-not (Test-Path -LiteralPath $job.AuthScript -PathType Leaf)){throw 'codex-auth is no longer installed at the saved path.'}
        $messageVariable='CODEX_DECK_SCHEDULED_PROMPT_'+$JobId.ToUpperInvariant()
        $oldMessage=[Environment]::GetEnvironmentVariable($messageVariable,'Process')
        try{
            [Environment]::SetEnvironmentVariable($messageVariable,[string]$job.Message,'Process')
            Set-Location -LiteralPath ([string]$job.Folder)
            Remove-Item -LiteralPath $claimed -Force -ErrorAction Stop
            Write-Host ("Resuming {0} conversation {1}..." -f $job.OwnerAccount,$job.ThreadId)
            & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File ([string]$job.AuthScript) -Account ([string]$job.OwnerAccount) -Failover Off -Resume -ResumePromptEnvironment $messageVariable ([string]$job.ThreadId)
        }finally{[Environment]::SetEnvironmentVariable($messageVariable,$oldMessage,'Process')}
    }finally{
        if($job -and $job.TaskName){Unregister-ScheduledTask -TaskName ([string]$job.TaskName) -Confirm:$false -ErrorAction SilentlyContinue}
        Remove-Item -LiteralPath $claimed -Force -ErrorAction SilentlyContinue
    }
}
