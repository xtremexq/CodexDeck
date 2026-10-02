$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}

# Execute the production worker functions and queue loop with synthetic quota
# responses. Never acquire its live mutex, run Codex, or register Windows tasks.
$workerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Deck.WarmupWorker.ps1'),[ref]$null,[ref]$null)
foreach($name in 'Write-DeckWarmupLog','Invoke-DeckWorkerBatch','Read-DeckResetMap','Save-DeckWorkerState','Invoke-DeckWarmupWorker'){
    $definition=$workerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $definition.Extent.Text
}
$queueLoop=$workerAst.Find({param($node) $node -is [Management.Automation.Language.DoWhileStatementAst]},$true)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-warmup-worker-'+[guid]::NewGuid().ToString('N'))
function New-Fixture([string]$Name){
    $script:SuiteRoot=Join-Path $fixture $Name; $script:root=Join-Path $SuiteRoot 'deck'
    $script:statePath=Join-Path $root 'warmup-worker.json'; $script:logPath=Join-Path $root 'warmup-worker.log'
    $script:settings=Get-DeckDefaults; $settings.WarmupEnabled=$true; $settings.WarmupSchedulingEnabled=$true; $settings.WarmupPlanTypes='all'
    $script:responses=@{}; $script:starts=@(); $script:failChecks=@(); $script:failWarmups=@(); $script:failPostChecks=@(); $script:dynamicReset=$false; $script:enqueueDuringWarmup=$false
    Write-DeckJson (Join-Path $SuiteRoot 'accounts/account1/auth.json') @{}
    Write-DeckJson (Join-Path $root 'settings.json') $settings
}
function New-Quota([string]$Account,[long]$Reset,[double]$Used=0){
    [pscustomobject]@{Account=$Account;PlanType='plus';Status='available';Error=$null;CheckedAt=[DateTimeOffset]::Now.ToString('o');Windows=@([pscustomobject]@{DurationSeconds=18000;UsedPct=$Used;Dead=$false;ResetsAtUnix=$Reset})}
}
function Get-DeckCheckCode($SuiteRoot,$Account){'synthetic check'}
function Get-DeckWarmupCode($SuiteRoot,$Account,$Model){'synthetic warm-up'}
function Sync-DeckWarmupStartup($SuiteRoot,$Settings,$NextRun){$script:scheduledNext=$NextRun}
function Stop-DeckTask($Task){}
function Dispose-DeckTask($Task){}
function Test-DeckTaskReady($Task){$true}
function Start-DeckTask($Code,$Kind,$Account){
    $script:starts+=[pscustomobject]@{Account=$Account;Kind=$Kind}
    $output=''; $failure=''
    if($Kind -eq 'Check'){
        if($Account -in $script:failChecks -or ($Account -in $script:failPostChecks -and @($starts | Where-Object { $_.Account -eq $Account -and $_.Kind -eq 'Warm-up' }).Count)){$failure='Synthetic quota request failed.'}
        else{
            $record=$script:responses[$Account]
            if($script:dynamicReset){
                Start-Sleep -Milliseconds 1100
                $record.Windows[0].ResetsAtUnix=[DateTimeOffset]::Now.ToUnixTimeSeconds()+18000
            }
            $output=ConvertTo-Json -InputObject @($record) -Depth 10 -Compress
        }
    }else{
        if($Account -in $script:failWarmups){$failure='Synthetic model request failed.'}
        else{$output='{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}'+"`n"+'{"type":"turn.completed"}'}
        if($script:enqueueDuringWarmup){$script:enqueueDuringWarmup=$false; Request-DeckWarmup $SuiteRoot account2 -NoStart}
    }
    @{Process=[pscustomobject]@{ExitCode=$(if($failure){1}else{0})};Out=[pscustomobject]@{IsCompleted=$true;Result=$output};Err=[pscustomobject]@{IsCompleted=$true;Result=$failure};Started=[DateTimeOffset]::UtcNow}
}

New-Fixture discovery
$caseStart=[DateTimeOffset]::Now.ToUnixTimeSeconds()
$responses.account1=New-Quota account1 ($caseStart+18000)
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1)
Write-DeckJson $statePath @{NextRun=[DateTimeOffset]::Now.AddDays(1).ToString('o')}
$script:dynamicReset=$true
Invoke-DeckWarmupWorker
$discovered=Read-DeckResetMap; $state=Read-DeckJson $statePath
Assert ($discovered.account1 -ge $caseStart -and $discovered.account1 -le [DateTimeOffset]::Now.ToUnixTimeSeconds()) 'Worker failed to retain a reset discovered after quota checks finished'
Assert (([DateTimeOffset]$state.NextRun).ToUnixTimeSeconds() -eq $discovered.account1+60) 'Discovered reset was not scheduled after grace'
Assert (@($starts | Where-Object Kind -eq 'Warm-up').Count -eq 0) 'Discovery skipped reset grace'

New-Fixture updated-cache
$now=[DateTimeOffset]::Now; $reset=$now.ToUnixTimeSeconds()-90
$responses.account1=New-Quota account1 ($reset+18000)
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1)
Write-DeckJson (Join-Path $root 'warmup-resets.json') @{account1=$reset}
Write-DeckJson $statePath @{NextRun=$now.AddDays(1).ToString('o');SettingsStamp=(Get-DeckWarmupSettingsStamp $settings @('account1'))}
Invoke-DeckWarmupWorker
$state=Read-DeckJson $statePath
Assert ($starts.Count -eq 0 -and ([DateTimeOffset]$state.NextRun) -lt $now.AddMinutes(2)) 'Idle watchdog ignored a newly eligible cached reset'
Write-DeckJson $statePath @{NextRun=$now.AddSeconds(-1).ToString('o');SettingsStamp=$state.SettingsStamp}
Invoke-DeckWarmupWorker
Assert (@($starts | Where-Object Kind -eq 'Warm-up').Count -eq 1) 'Updated cached reset never reached an automatic warm-up'
Assert ((Read-DeckJson $statePath).Warmed -contains 'account1') 'Confirmed warm-up was not recorded'
Write-DeckJson $statePath @{NextRun=$now.AddSeconds(-1).ToString('o');SettingsStamp=$state.SettingsStamp}
Invoke-DeckWarmupWorker
Assert (@($starts | Where-Object Kind -eq 'Warm-up').Count -eq 1) 'Confirmed empty-looking window was warmed twice'

New-Fixture settings-change
$responses.account1=New-Quota account1 ([DateTimeOffset]::Now.AddHours(4).ToUnixTimeSeconds()) 5
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1)
Write-DeckJson $statePath @{NextRun=[DateTimeOffset]::Now.AddHours(4).ToString('o');SettingsStamp='old selection'}
Invoke-DeckWarmupWorker
Assert (@($starts | Where-Object Kind -eq 'Check').Count -eq 1) 'Changed settings were hidden by the previously scheduled run'
$script:starts=@()
Invoke-DeckWarmupWorker
Assert ($starts.Count -eq 0) 'Unchanged future schedule caused needless watchdog requests'

New-Fixture failed-check
$now=[DateTimeOffset]::Now
$responses.account1=New-Quota account1 ($now.AddHours(5).ToUnixTimeSeconds())
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1)
Write-DeckJson (Join-Path $root 'warmup-resets.json') @{account1=($now.ToUnixTimeSeconds()-90)}
$script:failChecks=@('account1')
Invoke-DeckWarmupWorker
$failedCache=Get-DeckUsageCache $root; $state=Read-DeckJson $statePath
Assert (@($starts | Where-Object Kind -eq 'Warm-up').Count -eq 0) 'Failed quota check allowed a reset warm-up using stale data'
Assert ($failedCache.account1.Status -eq 'error' -and $failedCache.account1.Error -match 'Synthetic quota') 'Quota failure was absent from persisted state'
Assert (([DateTimeOffset]$state.NextRun) -ge $now.AddMinutes(19)) 'Quota failure did not back off'

New-Fixture failed-warmup
$now=[DateTimeOffset]::Now
$responses.account1=New-Quota account1 ($now.AddHours(5).ToUnixTimeSeconds())
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1)
Write-DeckJson (Join-Path $root 'warmup-resets.json') @{account1=($now.ToUnixTimeSeconds()-90)}
$script:failWarmups=@('account1')
Invoke-DeckWarmupWorker
$history=ConvertTo-DeckMap (Read-DeckJson (Join-Path $root 'warmup.json'))
Assert ($history.account1.Error -match 'Synthetic model' -and (Get-Content -LiteralPath $logPath -Raw) -match 'warm-up failed for account1') 'Warm-up failure lost its actual error'
Assert ((Read-DeckJson $statePath).Warmed.Count -eq 0) 'Failed warm-up was counted as successful'

New-Fixture failed-refresh
$now=[DateTimeOffset]::Now
$responses.account1=New-Quota account1 ($now.AddHours(5).ToUnixTimeSeconds())
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1)
Write-DeckJson (Join-Path $root 'warmup-resets.json') @{account1=($now.ToUnixTimeSeconds()-90)}
$script:failPostChecks=@('account1')
Invoke-DeckWarmupWorker
$state=Read-DeckJson $statePath; $failedCache=Get-DeckUsageCache $root
Assert ($state.Warmed -contains 'account1') 'A failed quota refresh hid a confirmed assistant reply'
Assert ($failedCache.account1.Status -eq 'error' -and (Get-Content -LiteralPath $logPath -Raw) -match 'quota refresh failed for account1') 'A failed post-warm-up quota refresh kept stale success data'
Assert (([DateTimeOffset]$state.NextRun) -ge $now.AddMinutes(19)) 'Failed quota refresh did not back off'

New-Fixture concurrent-cache
$now=[DateTimeOffset]::Now
$older=New-Quota account1 ($now.AddHours(5).ToUnixTimeSeconds()) 5; $older.CheckedAt=$now.AddMinutes(-2).ToString('o')
$newer=New-Quota account1 ($now.AddHours(2).ToUnixTimeSeconds()) 10; $newer.CheckedAt=$now.ToString('o')
Write-DeckJson (Join-Path $root 'terminal-cache.json') @($newer)
Save-DeckWorkerState @{account1=$older} @{} @{} @() @() 'synthetic merge'
Assert ((Get-DeckUsageCache $root).account1.CheckedAt -eq $newer.CheckedAt) 'Worker overwrote a newer dashboard quota response'
Assert (([DateTimeOffset]$script:scheduledNext).ToUnixTimeSeconds() -eq $newer.Windows[0].ResetsAtUnix+60) 'Worker rescheduled from a stale cache response'

New-Fixture manual-drain
$settings.WarmupEnabled=$false; Write-DeckJson (Join-Path $root 'settings.json') $settings
Write-DeckJson (Join-Path $SuiteRoot 'accounts/account2/auth.json') @{}
$responses.account1=New-Quota account1 ([DateTimeOffset]::Now.AddHours(5).ToUnixTimeSeconds())
$responses.account2=New-Quota account2 ([DateTimeOffset]::Now.AddHours(5).ToUnixTimeSeconds())
Write-DeckJson (Join-Path $root 'cache.json') @($responses.account1,$responses.account2)
Request-DeckWarmup $SuiteRoot account1 -NoStart; $script:enqueueDuringWarmup=$true
Invoke-Expression $queueLoop.Extent.Text
Assert (@($starts | Where-Object Kind -eq 'Warm-up').Count -eq 2) 'Request arriving during an active worker was abandoned'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'warmup-requests') -Filter '*.json').Count -eq 0) 'Worker left a manual request queued after completing'

'PASS: worker schedule reconciliation, reset discovery and grace, deduplication, failure backoff and diagnostics, concurrent cache merge, and manual queue draining.'
