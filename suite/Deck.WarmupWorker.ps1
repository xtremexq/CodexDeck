param([string]$SuiteRoot = $PSScriptRoot)
$ErrorActionPreference='Stop'
. (Join-Path $SuiteRoot 'Deck.Core.ps1')
$root=Join-Path $SuiteRoot 'deck'
$statePath=Join-Path $root 'warmup-worker.json'
$logPath=Join-Path $root 'warmup-worker.log'

function Write-DeckWarmupLog([string]$Message) {
    [void][IO.Directory]::CreateDirectory($root)
    if((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 262144){
        $tail=[IO.File]::ReadAllText($logPath); $tail=$tail.Substring([Math]::Max(0,$tail.Length-131072)); [IO.File]::WriteAllText($logPath,$tail,[Text.UTF8Encoding]::new($false))
    }
    [IO.File]::AppendAllText($logPath,([DateTimeOffset]::Now.ToString('o')+'  '+$Message+"`r`n"),[Text.UTF8Encoding]::new($false))
}
function Invoke-DeckWorkerBatch($Accounts, [ValidateSet('Check','Warm-up')][string]$Kind, [string]$Model) {
    $queue=[Collections.Generic.Queue[string]]::new(); foreach($account in @($Accounts|Select-Object -Unique)){$queue.Enqueue($account)}
    $active=@{}; $results=@{}
    while($queue.Count -or $active.Count){
        while($queue.Count -and $active.Count -lt 8){
            $account=$queue.Dequeue()
            try{$code=if($Kind -eq 'Check'){Get-DeckCheckCode $SuiteRoot $account}else{Get-DeckWarmupCode $SuiteRoot $account $Model}; $active[$account]=Start-DeckTask $code $Kind $account}
            catch{$results[$account]=[pscustomobject]@{Success=$false;Output='';Error=$_.Exception.Message}}
        }
        foreach($account in @($active.Keys)){
            $task=$active[$account]; $timeout=([DateTimeOffset]::UtcNow-$task.Started).TotalSeconds -gt 120
            if($timeout){Stop-DeckTask $task}
            if($task.Process.HasExited -and ($timeout -or ($task.Out.IsCompleted -ne $false -and $task.Err.IsCompleted -ne $false))){
                $results[$account]=[pscustomobject]@{Success=(-not $timeout -and $task.Process.ExitCode -eq 0);Output=$(if($task.Out.IsCompleted){[string]$task.Out.Result}else{''});Error=$(if($timeout){'Timed out'}elseif($task.Err.IsCompleted){[string]$task.Err.Result}else{''})}
                $task.Process.Dispose(); $active.Remove($account)
            }
        }
        if($active.Count){Start-Sleep -Milliseconds 150}
    }
    return $results
}
function Read-DeckResetMap {
    $map=@{}; $saved=Read-DeckJson (Join-Path $root 'warmup-resets.json')
    if($saved){foreach($property in $saved.PSObject.Properties){if($property.Value){$map[$property.Name]=[long]$property.Value}}}
    return $map
}
function Save-DeckWorkerState($Cache,$Resets,$History,$Checked,$Warmed,[string]$Outcome) {
    $latest=ConvertTo-DeckMap (Read-DeckJson (Join-Path $root 'cache.json'))
    foreach($account in @($Cache.Keys)){$latest[$account]=$Cache[$account]}
    Write-DeckJson (Join-Path $root 'cache.json') @(Get-DeckMapValues $latest)
    Write-DeckJson (Join-Path $root 'warmup-resets.json') $Resets
    Write-DeckJson (Join-Path $root 'warmup.json') @(Get-DeckMapValues $History)
    $settings=Get-DeckSettings $root; $accounts=@(Get-DeckWarmupAccounts $SuiteRoot $settings $latest)
    $next=Get-DeckNextWarmupRun $settings $accounts $latest $Resets $History ([DateTimeOffset]::Now) 20
    Write-DeckJson $statePath ([ordered]@{LastRun=[DateTimeOffset]::Now.ToString('o');Outcome=$Outcome;Checked=@($Checked);Warmed=@($Warmed);NextRun=$(if($next){([DateTimeOffset]$next).ToString('o')}else{$null})})
    Write-DeckJson (Join-Path $root 'warmup-state-changed.json') @{At=[DateTimeOffset]::Now.ToString('o')}
    Sync-DeckWarmupStartup $SuiteRoot $settings $next
}

$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $created=$false
$mutex=[Threading.Mutex]::new($true,"Local\CodexDeckWarmup-$sid",[ref]$created)
if(-not $created){$mutex.Dispose(); exit 0}
try{
    $settings=Get-DeckSettings $root
    $cache=ConvertTo-DeckMap (Read-DeckJson (Join-Path $root 'cache.json'))
    $history=ConvertTo-DeckMap (Read-DeckJson (Join-Path $root 'warmup.json'))
    $resets=Read-DeckResetMap
    $accounts=@(Get-DeckWarmupAccounts $SuiteRoot $settings $cache)
    $now=[DateTimeOffset]::Now; $unix=$now.ToUnixTimeSeconds()
    Add-DeckTimedWarmups $SuiteRoot $settings $accounts $cache $now
    $requests=@{}
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'warmup-requests') -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        $request=Read-DeckJson $file.FullName; $account=[string]$request.Account
        $valid=$account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -and (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$account/auth.json")) -and $request.Mode -in @('Manual','Timed')
        if($valid -and $request.Mode -eq 'Timed'){$valid=$settings.WarmupEnabled -and $settings.WarmupTimedEnabled -and (Test-DeckWarmupSelected $settings $account) -and $unix-[long]$request.At -le 300}
        if($valid -and $request.Mode -eq 'Manual'){$valid=$unix-[long]$request.At -le 3600}
        if($valid){$requests[$account]=[pscustomobject]@{Request=$request;Path=$file.FullName}}else{Remove-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue}
    }
    $checked=@(); $changed=@{}
    if($settings.WarmupEnabled -and $accounts.Count){
        $checks=Invoke-DeckWorkerBatch $accounts Check $settings.WarmupModel
        foreach($account in @($accounts)){
            $result=$checks[$account]
            try{
                if(-not $result.Success){throw $(if($result.Error){$result.Error}else{'Quota check failed.'})}
                $records=@(Expand-DeckCheckRecords ($result.Output|ConvertFrom-Json)); if($records.Count -ne 1 -or $records[0].Account -ne $account){throw 'Unexpected quota response.'}
                $record=$records[0]; if($record.Status -eq 'error'){throw $record.Error}; $record|Add-Member NoteProperty CheckedAt ([DateTimeOffset]::Now.ToString('o')) -Force
                $cache[$account]=$record; $changed[$account]=$record; $checked+=$account
            }catch{Write-DeckWarmupLog ("check failed for ${account}: "+$_.Exception.Message)}
        }
    }
    $warmJobs=@{}
    foreach($account in @($requests.Keys)){$warmJobs[$account]=[pscustomobject]@{Mode=[string]$requests[$account].Request.Mode;Reset=0;Path=$requests[$account].Path}}
    foreach($account in @($accounts)){
        $record=$cache[$account]; if(-not $record){continue}
        $previous=Get-DeckWarmupReset $record $resets[$account] $unix
        if(Test-DeckWarmup $settings $record $previous $history[$account] $unix){
            if($warmJobs[$account]){$warmJobs[$account].Reset=$previous}else{$warmJobs[$account]=[pscustomobject]@{Mode='Reset';Reset=$previous;Path=$null}}
        }
        $five=$record.Windows|Where-Object DurationSeconds -eq 18000|Select-Object -First 1
        $confirmed=$history[$account] -and [long]$history[$account].Reset -eq [long]$previous -and [string]$history[$account].Outcome -like 'Replied:*'
        if($five.ResetsAtUnix -and [long]$five.ResetsAtUnix -gt $unix -and (-not $previous -or $five.UsedPct -gt 0 -or $confirmed -or $unix -gt ([long]$previous+60*$settings.WarmupMaxDelayMinutes))){$resets[$account]=[long]$five.ResetsAtUnix}
    }
    foreach($account in @($warmJobs.Keys)){
        $job=$warmJobs[$account]; $history[$account]=[pscustomobject]@{Account=$account;Reset=[long]$job.Reset;AttemptAt=$unix;Mode=$job.Mode;Outcome='Sending / waiting for reply';Reply=''}
        if($job.Path){Remove-Item -LiteralPath $job.Path -ErrorAction SilentlyContinue}
    }
    if($warmJobs.Count){Write-DeckJson (Join-Path $root 'warmup.json') @(Get-DeckMapValues $history)}
    $warmed=@()
    if($warmJobs.Count){
        $runs=Invoke-DeckWorkerBatch @($warmJobs.Keys) 'Warm-up' $settings.WarmupModel
        foreach($account in @($warmJobs.Keys)){
            $result=$runs[$account]; $reply=if($result.Success){Get-DeckWarmupReply $result.Output}else{$null}
            $history[$account].Outcome=if($reply){'Replied: '+$reply}elseif($result.Success){'No assistant reply / unconfirmed'}else{'Request failed'}
            $history[$account].Reply=[string]$reply; $history[$account]|Add-Member NoteProperty CompletedAt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
            if($reply){$warmed+=$account}
        }
        # A successful prompt starts/changes quota state. Refresh those accounts so
        # the following scheduled wake uses the provider's real next reset time.
        $post=Invoke-DeckWorkerBatch @($warmJobs.Keys) Check $settings.WarmupModel
        foreach($account in @($warmJobs.Keys)){
            $result=$post[$account]; if(-not $result.Success){continue}
            try{$records=@(Expand-DeckCheckRecords ($result.Output|ConvertFrom-Json)); if($records.Count -ne 1 -or $records[0].Account -ne $account){continue}; $record=$records[0]; if($record.Status -eq 'error'){continue}; $record|Add-Member NoteProperty CheckedAt ([DateTimeOffset]::Now.ToString('o')) -Force; $cache[$account]=$record; $changed[$account]=$record; $five=$record.Windows|Where-Object DurationSeconds -eq 18000|Select-Object -First 1; if($five.ResetsAtUnix -and [long]$five.ResetsAtUnix -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -and ($history[$account].Outcome -like 'Replied:*' -or $five.UsedPct -gt 0)){$resets[$account]=[long]$five.ResetsAtUnix}}catch{}
        }
    }
    $summary="checked=$($checked.Count); warmed=$($warmed.Count); selected=$($accounts.Count)"
    Save-DeckWorkerState $changed $resets $history $checked $warmed $summary
    Write-DeckWarmupLog $summary
}catch{
    $message=$_.Exception.Message; Write-DeckWarmupLog ('worker failed: '+$message)
    try{Write-DeckJson $statePath ([ordered]@{LastRun=[DateTimeOffset]::Now.ToString('o');Outcome='Failed: '+$message;Checked=@();Warmed=@();NextRun=[DateTimeOffset]::Now.AddMinutes(20).ToString('o')}); Sync-DeckWarmupStartup $SuiteRoot (Get-DeckSettings $root) ([DateTimeOffset]::Now.AddMinutes(20))}catch{}
    exit 1
}finally{
    if($created){$mutex.ReleaseMutex()}; $mutex.Dispose()
}
