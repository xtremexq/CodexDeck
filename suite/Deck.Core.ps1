function Get-DeckModelNames($Values) {
    $names=foreach($value in $Values){
        if($value -is [array]){Get-DeckModelNames $value}
        elseif($value -is [string] -and $value -match '^gpt-[a-zA-Z0-9.-]+$'){$value}
    }
    $names | Select-Object -Unique
}
. (Join-Path $PSScriptRoot 'Deck.AccountTools.ps1')
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.GlobalRules.ps1')){. (Join-Path $PSScriptRoot 'Deck.GlobalRules.ps1')}
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.Environments.ps1')) { . (Join-Path $PSScriptRoot 'Deck.Environments.ps1') }
# Codex Deck - local state and scheduling. No credentials are written to Deck state.
function Get-DeckDueAccounts($Automatic, $Manual, $NextCheck, [DateTimeOffset]$Now) {
    $manualDue=@($Manual.Keys | Where-Object { $Manual[$_] -le $Now } | Sort-Object { $Manual[$_] })
    $manualDue
    $Automatic | Select-Object -Unique | Where-Object {
        -not $Manual.ContainsKey($_) -and (-not $NextCheck[$_] -or $NextCheck[$_] -le $Now)
    } | Sort-Object { if($NextCheck[$_]){$NextCheck[$_]}else{[DateTimeOffset]::MinValue} }
}
function Get-DeckDefaults {
    return [ordered]@{
        DefaultFolder=$HOME; AlwaysAskFolder=$false
        AutoStart=$false; AutoCheck=$false; PollMinutes=10; MinimumGapSeconds=20
        AlwaysOnTop=$false; OpacityPercent=100; FontSize=12; Width=476; Height=0
        ShowEmail=$true; ShowPlan=$true; ShowQuota=$true; ShowResets=$true; ShowResetCredits=$true
        ShowSessionCount=$false; ShowUptime=$false; ShowProcessIds=$false
        ShowFolder=$false; ShowSource=$false; ShowCheckedAt=$false; ShowCredits=$false
        ShowWarmup=$true; MaskEmail=$false; Compact=$false; CloseToTray=$true
        ShowModel=$false; AccountPickerUsage=$false
        ViewMode='Widget'; WidgetOneLine=$true; WidgetShowEmail=$false; WidgetShowResets=$true; WidgetAutoHeight=$true
        WidgetWidth=238; WidgetHeight=0
        WarmupEnabled=$false; WarmupAllPaid=$false; WarmupAccounts=''; WarmupModel='gpt-5.6-luna'
        WarmupGraceSeconds=60; WarmupMaxDelayMinutes=30
        WarmupResetEnabled=$true; WarmupTimedEnabled=$false; WarmupTimes=''
        WarmupStartAtLogin=$true
        FailoverEnabled=$false; FailoverMode='Ordered'; FailoverAccounts=''
    }
}
function Get-DeckProfile([string]$SuiteRoot,[string]$Account) {
    if($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){return}
    $folder=Join-Path $SuiteRoot "accounts/$Account"
    $profile=@{Email=$null; PlanType=$null; Model='Codex default'; Effort='default'}
    $auth=Read-DeckJson (Join-Path $folder 'auth.json')
    foreach($token in @($auth.tokens.id_token,$auth.tokens.access_token)){
        try{
            if(-not $token){continue}
            $part=$token.Split('.')[1].Replace('-','+').Replace('_','/')
            $part=$part.PadRight($part.Length+(4-$part.Length%4)%4,'=')
            $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
            if(-not $profile.PlanType){$profile.PlanType=$claims.'https://api.openai.com/auth'.chatgpt_plan_type}
            if(-not $profile.Email){$profile.Email=$claims.email}
            if(-not $profile.Email){$profile.Email=$claims.'https://api.openai.com/profile'.email}
        }catch{}
    }
    $configPath=Join-Path $folder 'config.toml'
    if(Test-Path -LiteralPath $configPath){
        $top=([IO.File]::ReadAllText($configPath) -split '(?m)^\[',2)[0]
        if($top -match '(?m)^model\s*=\s*"([^"]+)"'){$profile.Model=$Matches[1]}
        if($top -match '(?m)^model_reasoning_effort\s*=\s*"([^"]+)"'){$profile.Effort=$Matches[1]}
    }
    if ((Get-Command Get-DeckPoolEntry -ErrorAction SilentlyContinue) -and (Get-DeckPoolEntry $SuiteRoot $Account)) { $profile.PlanType='pool'; $profile.Email='Shared environment / selectable quota accounts' }
    return $profile
}
function Get-DeckNextCheck($Settings, $Record, [DateTimeOffset]$CheckedAt) {
    if($Record.Status -eq 'error'){return $CheckedAt.AddMinutes([Math]::Max(20,$Settings.PollMinutes))}
    $next=$CheckedAt.AddMinutes($Settings.PollMinutes)
    if($Settings.WarmupEnabled -and $Record.PlanType -in @('plus','pro','team','business','enterprise','edu') -and ($Settings.WarmupAllPaid -or $Record.Account -in @($Settings.WarmupAccounts -split '[,;\s]+'))){
        $five=$Record.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
        if($five.ResetsAtUnix){
            $target=[DateTimeOffset]::FromUnixTimeSeconds([long]$five.ResetsAtUnix).AddSeconds($Settings.WarmupGraceSeconds)
            if($target -gt $CheckedAt -and $target -lt $next){$next=$target}
            elseif($target -le $CheckedAt -and $CheckedAt -le $target.AddMinutes($Settings.WarmupMaxDelayMinutes)){$next=$CheckedAt.AddSeconds(60)}
        }
    }
    return $next
}
function Read-DeckJson([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { }
    }
}
function Expand-DeckCheckRecords($Value) {
    foreach ($entry in $Value) {
        if ($null -eq $entry) { continue }
        # Windows PowerShell can serialize an extended array as { value, Count }.
        if ($entry -is [array]) { Expand-DeckCheckRecords $entry }
        elseif ($entry.PSObject.Properties['value'] -and $entry.value -is [array]) { Expand-DeckCheckRecords $entry.value }
        elseif ($entry.Account -is [string] -and $entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { $entry }
    }
}
function Write-DeckJson([string]$Path, $Value) {
    $dir = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $temp = Join-Path $dir ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Get-DeckSettings([string]$Root) {
    $settings = Get-DeckDefaults
    $saved = Read-DeckJson (Join-Path $Root 'settings.json')
    if ($saved) {
        foreach ($key in @($settings.Keys)) {
            if ($null -ne $saved.$key -and $saved.$key.GetType() -eq $settings[$key].GetType()) { $settings[$key] = $saved.$key }
        }
    }
    $settings.PollMinutes = [Math]::Min(120, [Math]::Max(5, $settings.PollMinutes))
    $settings.MinimumGapSeconds = [Math]::Min(300, [Math]::Max(15, $settings.MinimumGapSeconds))
    $settings.WarmupGraceSeconds = [Math]::Min(600, [Math]::Max(60, $settings.WarmupGraceSeconds))
    $settings.WarmupMaxDelayMinutes = [Math]::Min(60, [Math]::Max(5, $settings.WarmupMaxDelayMinutes))
    $settings.FontSize = [Math]::Min(20, [Math]::Max(10, $settings.FontSize))
    $settings.Width = [Math]::Min(1200, [Math]::Max(476, $settings.Width))
    $settings.Height = [Math]::Min(1000, [Math]::Max(0, $settings.Height))
    $settings.OpacityPercent = [Math]::Min(100, [Math]::Max(50, $settings.OpacityPercent))
    $settings.WidgetWidth = [Math]::Min(600, [Math]::Max(238, $settings.WidgetWidth))
    $settings.WidgetHeight = [Math]::Min(800, [Math]::Max(0, $settings.WidgetHeight))
    if ($settings.FailoverMode -notin @('Ordered','Best')) { $settings.FailoverMode='Ordered' }
    if ($settings.ViewMode -notin @('Panel','Widget','Tray')) { $settings.ViewMode='Widget' }
    return $settings
}
function Register-DeckSession([string]$Root, [string]$Account, [string]$Folder) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { throw 'Invalid session account.' }
    $proc = Get-Process -Id $PID
    $path = Join-Path $Root ('sessions/' + [guid]::NewGuid().ToString('N') + '.json')
    Write-DeckJson $path ([ordered]@{ Account=$Account; ProcessId=$PID; ProcessStartTicks=$proc.StartTime.ToUniversalTime().Ticks; StartedAt=[DateTimeOffset]::Now.ToString('o'); Folder=$Folder })
    return $path
}
function Get-DeckSessions([string]$Root) {
    $dir = Join-Path $Root 'sessions'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
        $entry = Read-DeckJson $file.FullName
        $valid = $false
        if ($entry -and $entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') {
            try {
                $proc = Get-Process -Id $entry.ProcessId -ErrorAction Stop
                $valid = $proc.StartTime.ToUniversalTime().Ticks -eq $entry.ProcessStartTicks
            } catch { }
        }
        if ($valid) { $entry }
        else { Remove-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue }
    }
}
function Start-DeckCompanion([string]$SuiteRoot, [switch]$OpenSettings) {
    $scriptPath = Join-Path $SuiteRoot 'Codex-Deck.ps1'
    if (Test-Path -LiteralPath $scriptPath) {
        $launchMode=if($OpenSettings){' -OpenSettings'}else{' -Attach'}
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $scriptPath + '"'+$launchMode) | Out-Null
    }
}
function Test-DeckWarmup($Settings, $Record, $PreviousReset, $History, [long]$Now) {
    if (-not $Settings.WarmupEnabled -or $Settings.WarmupResetEnabled -eq $false) { return $false }
    if ($Record.PlanType -notin @('plus','pro','team','business','enterprise','edu')) { return $false }
    $selected = @($Settings.WarmupAccounts -split '[,;\s]+' | Where-Object { $_ })
    if (-not $Settings.WarmupAllPaid -and $selected -notcontains $Record.Account) { return $false }
    if ($Record.Status -ne 'available' -or $Record.Error -or -not $PreviousReset) { return $false }
    if ($Now -lt ([long]$PreviousReset + $Settings.WarmupGraceSeconds) -or
        $Now -gt ([long]$PreviousReset + 60 * $Settings.WarmupMaxDelayMinutes)) { return $false }
    $window = @($Record.Windows | Where-Object DurationSeconds -eq 18000)
    if ($window.Count -ne 1 -or $null -eq $window[0].UsedPct -or $window[0].UsedPct -ne 0) { return $false }
    if (@($Record.Windows | Where-Object { $_.Dead -or ($null -ne $_.UsedPct -and $_.UsedPct -ge 99.5) }).Count) { return $false }
    # A successful real request already started a new window; don't add another.
    if ($History -and ($History.Reset -eq $PreviousReset -or $Now - [long]$History.AttemptAt -lt 14400)) { return $false }
    return $true
}
function Start-DeckTask([string]$Code, [string]$Kind, [string]$Account) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process = [Diagnostics.Process]::Start($info)
    return @{ Process=$process; Out=$process.StandardOutput.ReadToEndAsync(); Err=$process.StandardError.ReadToEndAsync(); Kind=$Kind; Account=$Account; Started=[DateTimeOffset]::UtcNow }
}
function Stop-DeckTask($Task) {
    if ($Task -and -not $Task.Process.HasExited) {
        # Kill only the process tree we spawned, never account terminals.
        & taskkill.exe /PID $Task.Process.Id /T /F 2>$null | Out-Null
    }
}
function Get-DeckModelsCode([string]$SuiteRoot, [string]$Account) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { throw 'Invalid account.' }
    $path=(Join-Path $SuiteRoot 'Run-CodexLoopUsage.cmd').Replace("'", "''")
    $accountPath=(Join-Path $SuiteRoot "accounts/$Account").Replace("'", "''")
    return @"
`$ErrorActionPreference='Stop'
`$source=[IO.File]::ReadAllText('$path')
`$body=(`$source -split '(?m)^__POWERSHELL__\r?\n',2)[1]
. ([scriptblock]::Create(`$body.Substring(0,`$body.IndexOf('if (-not (Test-Path -LiteralPath `$AccountsRoot))'))))
`$models=@(Invoke-CodexRateLimitRead -CodexHome '$accountPath' -ListModels | ForEach-Object model)
ConvertTo-Json -InputObject `$models
"@
}
function Get-DeckCheckCode([string]$SuiteRoot, [string]$Account) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { throw 'Invalid account.' }
    $path = (Join-Path $SuiteRoot 'Run-CodexLoopUsage.cmd').Replace("'", "''")
    $accounts = (Join-Path $SuiteRoot 'accounts').Replace("'", "''")
    return "`$ErrorActionPreference='Stop'; `$text=[IO.File]::ReadAllText('$path'); `$body=(`$text -split '(?m)^__POWERSHELL__\r?`$')[1]; & ([scriptblock]::Create(`$body)) -AccountsRoot '$accounts' -Account '$Account' -Json"
}
function Get-DeckWarmupCode([string]$SuiteRoot, [string]$Account, [string]$Model) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $Model -notmatch '^gpt-[a-zA-Z0-9.-]+$') { throw 'Invalid warm-up account or model.' }
    $accountPath = (Join-Path $SuiteRoot "accounts/$Account").Replace("'", "''")
    $workPath = (Join-Path $SuiteRoot 'deck/empty-workspace').Replace("'", "''")
    return @"
`$ErrorActionPreference='Stop'
`$env:CODEX_HOME='$accountPath'
Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
[void][IO.Directory]::CreateDirectory('$workPath')
Set-Location -LiteralPath '$workPath'
`$exe = Get-Command codex.cmd -ErrorAction SilentlyContinue
if (-not `$exe) { `$exe = Get-Command codex -ErrorAction Stop }
`$ErrorActionPreference='Continue'
& `$exe.Source exec --json --ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check --sandbox read-only -c 'approval_policy="never"' -c 'project_doc_max_bytes=0' -c 'model_reasoning_effort="low"' -m '$Model' 'Hi. Reply only with hi. Do not use tools or read files.'
exit `$LASTEXITCODE
"@
}

function Move-DeckAccountToRecovery {
    param([string]$SuiteRoot, [string]$Name)
    $accountsRoot=Join-Path $SuiteRoot 'accounts'
    # Only an existing direct child may be removed, including old typo names.
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.', '..') -or
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Deletion requires a single account folder name.'
    }
    $root = (Get-Item -LiteralPath $accountsRoot).FullName.TrimEnd('\')
    if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing deletion through a linked accounts root.'
    }
    $target = Get-Item -LiteralPath (Join-Path $root $Name) -ErrorAction Stop
    if (-not $target.PSIsContainer -or $target.Parent.FullName -ne $root -or
        ($target.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Deletion target must be a real account directory directly inside accounts.'
    }
    if ($env:CODEX_HOME -and [IO.Path]::GetFullPath($env:CODEX_HOME).TrimEnd('\') -eq $target.FullName) {
        throw 'This account is the active CODEX_HOME. Switch accounts before deleting it.'
    }
    if (@(Get-DeckSessions (Join-Path $SuiteRoot 'deck') | Where-Object Account -eq $Name).Count) {
        throw 'This account has a connected terminal. Close its Codex sessions before deleting it.'
    }
    $archiveRoot = Join-Path (Split-Path $root -Parent) 'deleted-accounts'
    if (-not (Test-Path -LiteralPath $archiveRoot)) {
        New-Item -ItemType Directory -Path $archiveRoot | Out-Null
    }
    $archive = Get-Item -LiteralPath $archiveRoot
    if (-not $archive.PSIsContainer -or ($archive.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Recovery directory must be a real directory.'
    }
    $destination = Join-Path $archive.FullName ("{0}-{1}-{2}" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($destination)) -ne $archive.FullName) {
        throw 'Recovery destination escaped the recovery directory.'
    }
    Move-Item -LiteralPath $target.FullName -Destination $destination -ErrorAction Stop

}


function Get-DeckQuotaColor($Quota) {
    if($null -eq $Quota.RemainingPct){return '#929CA4'}
    if($Quota.Dead -or $Quota.RemainingPct -le 0){return '#F17D8D'}
    if($Quota.RemainingPct -le 20){return '#DCB675'}
    return '#69DEC0'
}
function Get-DeckHealth($Record) {
    if(-not $Record){return 'Not checked'}
    $current=@($Record.Windows | Where-Object { -not $_.ResetsAtUnix -or [long]$_.ResetsAtUnix -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() })
    if(@($current | Where-Object { $_.Dead -or ($null -ne $_.RemainingPct -and $_.RemainingPct -le 0) }).Count){return 'Exhausted'}
    if(@($Record.Windows).Count -gt $current.Count){return 'Reset passed'}
    if(@($current | Where-Object { $null -ne $_.RemainingPct -and $_.RemainingPct -le 20 }).Count){return 'Low'}
    if($Record.Status -eq 'available'){return 'Ready'}
    if($Record.Status -eq 'blocked'){return 'Limit reached'}
    return 'Unavailable'
}

# Shared controls and status for the desktop and terminal. One desktop/tray process owns execution.
function Test-DeckWarmupSelected($Settings, [string]$Account) {
    return $Settings.WarmupAllPaid -or $Account -in @($Settings.WarmupAccounts -split '[,;\s]+')
}
function Get-DeckWarmupStatus($Settings, $Record, $History, [long]$Now = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) {
    if ($History -and $Now - [long]$History.AttemptAt -lt 14400) { return $History.Outcome }
    if (-not (Test-DeckWarmupSelected $Settings $Record.Account)) { return 'Not selected' }
    if (-not $Settings.WarmupEnabled) { return 'Paused' }
    if ($Settings.WarmupTimedEnabled -and -not $Settings.WarmupResetEnabled) { return 'Daily ' + $Settings.WarmupTimes + ' (local)' }
    if ($Record.PlanType -and $Record.PlanType -notin @('plus','pro','team','business','enterprise','edu')) { return 'Paid plans only' }
    if ($History -and $Now - [long]$History.AttemptAt -lt 14400) { return $History.Outcome }
    if (-not $Record.CheckedAt -or $Record.Error -or $Record.Status -ne 'available') { return 'Waiting for fresh quota' }
    if (@($Record.Windows | Where-Object { $_.Dead -or ($null -ne $_.UsedPct -and $_.UsedPct -ge 99.5) }).Count) { return 'Waiting for quota reset' }
    $five=$Record.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
    if (-not $five.ResetsAtUnix) { return 'Waiting for reset data' }
    $reset=Get-DeckWarmupReset $Record $five.ResetsAtUnix $Now
    $due=[long]$reset + $Settings.WarmupGraceSeconds
    if ($due -gt $Now) { return 'Reset check ' + [DateTimeOffset]::FromUnixTimeSeconds($due).ToLocalTime().ToString('MMM dd HH:mm') }
    if ($Now -gt ([long]$reset + 60*$Settings.WarmupMaxDelayMinutes)) { return 'Reset window missed' }
    return 'Verifying empty window'
}
function Set-DeckWarmupControl([string]$Root, [string]$Account, [switch]$Pause) {
    $current=Get-DeckSettings $Root
    if ($Pause) { $current.WarmupEnabled=-not $current.WarmupEnabled }
    else {
        if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { throw 'Select an account first.' }
        if ($current.WarmupAllPaid) { throw 'All paid accounts is enabled. Change the selection in Deck settings first.' }
        $selected=@($current.WarmupAccounts -split '[,;\s]+' | Where-Object { $_ })
        if ($Account -in $selected) { $selected=@($selected | Where-Object { $_ -ne $Account }) }
        else { $selected+= $Account; $current.WarmupEnabled=$true }
        $current.WarmupAccounts=$selected -join ','
    }
    Write-DeckJson (Join-Path $Root 'settings.json') $current
    Write-DeckJson (Join-Path $Root 'warmup-settings-changed.json') @{At=[DateTimeOffset]::UtcNow.ToString('o')}
    if (Test-Path -LiteralPath (Join-Path (Split-Path $Root -Parent) 'Codex-Deck.ps1')) { Sync-DeckWarmupStartup (Split-Path $Root -Parent) $current }
    return $current
}
function Start-DeckWarmupScheduler([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'Codex-Deck.ps1'
    if (Test-Path -LiteralPath $path) {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+$path+'" -Attach -Background') | Out-Null
    }
}

function ConvertTo-DeckWarmupTimes([string]$Times) {
    $values=@($Times -split '[,;\s]+' | Where-Object { $_ })
    foreach($value in $values){if($value -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$'){throw 'Use local 24-hour times, for example 08:00, 13:30, 19:00.'}}
    return (@($values | Sort-Object -Unique) -join ', ')
}
function Get-DeckDueWarmupTimes([string]$Times, [DateTimeOffset]$Now) {
    # Five-minute catch-up covers brief sleep/restart. Keys use local dates, so a
    # repeated daylight-saving hour never fires the same daily slot twice.
    foreach($time in @((ConvertTo-DeckWarmupTimes $Times) -split ', ' | Where-Object {$_})){
        foreach($day in @($Now.Date,$Now.Date.AddDays(-1))){
            $at=$day.Add([TimeSpan]::Parse($time))
            $age=($Now.DateTime-$at).TotalSeconds
            if($age -ge 0 -and $age -lt 300){$at.ToString('yyyyMMdd-HHmm')}
        }
    }
}
function Get-DeckWarmupReply([string]$Output) {
    $reply=''; $completed=$false; $failed=$false
    foreach($line in ($Output -split '\r?\n')){
        try{$event=$line | ConvertFrom-Json -ErrorAction Stop}catch{continue}
        if($event.type -eq 'item.completed' -and $event.item.type -eq 'agent_message' -and $event.item.text){$reply=[string]$event.item.text}
        if($event.type -eq 'turn.completed'){$completed=$true}
        if($event.type -in @('turn.failed','error')){$failed=$true}
    }
    if($completed -and -not $failed -and -not [string]::IsNullOrWhiteSpace($reply)){return $reply.Substring(0,[Math]::Min(500,$reply.Length))}
}
function Request-DeckWarmup([string]$SuiteRoot, [string]$Account, [switch]$NoStart) {
    if($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or -not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$Account/auth.json"))){throw 'Select a signed-in account.'}
    $path=Join-Path $SuiteRoot "deck/warmup-requests/$Account.json"
    if(-not (Test-Path -LiteralPath $path)){Write-DeckJson $path @{Account=$Account;Mode='Manual';At=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}}
    if(-not $NoStart){Start-DeckWarmupScheduler $SuiteRoot}
}
function Set-DeckWarmupTimes([string]$SuiteRoot, [string]$Times) {
    $root=Join-Path $SuiteRoot 'deck'; $settings=Get-DeckSettings $root
    $settings.WarmupTimes=ConvertTo-DeckWarmupTimes $Times
    $settings.WarmupTimedEnabled=[bool]$settings.WarmupTimes
    if($settings.WarmupTimedEnabled){$settings.WarmupEnabled=$true}
    Write-DeckJson (Join-Path $root 'settings.json') $settings
    Write-DeckJson (Join-Path $root 'warmup-settings-changed.json') @{At=[DateTimeOffset]::UtcNow.ToString('o')}
    Sync-DeckWarmupStartup $SuiteRoot $settings
    if($settings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}
    return $settings
}
function Sync-DeckWarmupStartup([string]$SuiteRoot, $Settings) {
    # Per-user startup requires no elevation and never starts a visible console.
    $path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if($Settings.WarmupEnabled -and $Settings.WarmupStartAtLogin){
        if(-not (Test-Path $path)){[void](New-Item -Path $path)}
        $command='powershell.exe -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "'+(Join-Path $SuiteRoot 'Codex-Deck.ps1')+'" -Attach -Background'
        [void](New-ItemProperty -Path $path -Name 'CodexDeckWarmup' -Value $command -PropertyType String -Force)
    }elseif(Test-Path $path){Remove-ItemProperty -Path $path -Name 'CodexDeckWarmup' -ErrorAction SilentlyContinue}
}

function Add-DeckTimedWarmups([string]$SuiteRoot, $Settings, $Accounts, $Cache, [DateTimeOffset]$Now) {
    if(-not $Settings.WarmupEnabled -or -not $Settings.WarmupTimedEnabled){return}
    $root=Join-Path $SuiteRoot 'deck'; $ledger=@{}
    foreach($entry in @(Read-DeckJson (Join-Path $root 'warmup-schedule.json'))){
        if($entry.Key -and $Now.ToUnixTimeSeconds()-[long]$entry.At -lt 172800){$ledger[$entry.Key]=$entry}
    }
    $dirty=$false
    foreach($slot in @(Get-DeckDueWarmupTimes $Settings.WarmupTimes $Now)){
        foreach($account in $Accounts){
            if(-not (Test-DeckWarmupSelected $Settings $account)){continue}
            $plan=$Cache[$account].PlanType
            if(-not $plan){$plan=(Get-DeckProfile $SuiteRoot $account).PlanType}
            if($plan -notin @('plus','pro','team','business','enterprise','edu')){continue}
            if(-not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$account/auth.json"))){continue}
            $key="$slot/$account"; if($ledger.ContainsKey($key)){continue}
            $request=Join-Path $root "warmup-requests/$account.json"
            if(-not (Test-Path -LiteralPath $request)){Write-DeckJson $request @{Account=$account;Mode='Timed';At=$Now.ToUnixTimeSeconds();Slot=$slot}}
            $ledger[$key]=@{Key=$key;At=$Now.ToUnixTimeSeconds()}; $dirty=$true
        }
    }
    if($dirty){Write-DeckJson (Join-Path $root 'warmup-schedule.json') @($ledger.Values)}
}
function Invoke-DeckQueuedWarmups([string]$SuiteRoot, $Settings, $Tasks, $History, [long]$Now) {
    $root=Join-Path $SuiteRoot 'deck'
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'warmup-requests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)){
        if($Tasks.Count -ge 8){break}
        $request=Read-DeckJson $file.FullName; $account=[string]$request.Account
        if($account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $request.Mode -notin @('Manual','Timed')){Remove-Item -LiteralPath $file.FullName; continue}
        if($Tasks.ContainsKey($account)){continue}
        $expired=$Now-[long]$request.At -gt $(if($request.Mode -eq 'Timed'){300}else{3600})
        $paused=$request.Mode -eq 'Timed' -and (-not $Settings.WarmupEnabled -or -not $Settings.WarmupTimedEnabled -or -not (Test-DeckWarmupSelected $Settings $account))
        $recent=$History[$account] -and $Now-[long]$History[$account].AttemptAt -lt 30
        if($expired -or $paused -or $recent -or -not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$account/auth.json"))){Remove-Item -LiteralPath $file.FullName; continue}
        $History[$account]=[pscustomobject]@{Account=$account;Reset=0;AttemptAt=$Now;Mode=$request.Mode;Outcome='Sending / waiting for reply';Reply=''}
        Write-DeckJson (Join-Path $root 'warmup.json') @($History.Values)
        Remove-Item -LiteralPath $file.FullName
        try{$Tasks[$account]=Start-DeckTask (Get-DeckWarmupCode $SuiteRoot $account $Settings.WarmupModel) 'Warm-up' $account}
        catch{$History[$account].Outcome='Failed to start'; Write-DeckJson (Join-Path $root 'warmup.json') @($History.Values)}
    }
}

function Get-DeckWarmupReset($Record, $PreviousReset, [long]$Now) {
    if ($PreviousReset -and [long]$PreviousReset -le $Now -and $Now - [long]$PreviousReset -le 3600) { return [long]$PreviousReset }
    $five=$Record.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
    # A full, freshly reported empty window also permits discovery after starting Deck.
    # The inferred start must be in the past; future/incomplete data is never eligible.
    if ($five.ResetsAtUnix -and $null -ne $five.UsedPct -and $five.UsedPct -eq 0) {
        $start=[long]$five.ResetsAtUnix - 18000
        if ($start -gt 0 -and $start -le $Now -and $Now-$start -le 300) { return $start }
    }
    return $PreviousReset
}
