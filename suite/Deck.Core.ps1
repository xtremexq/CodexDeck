function Get-DeckModelNames($Values) {
    $names=foreach($value in $Values){
        if($value -is [array]){Get-DeckModelNames $value}
        elseif($value -is [string] -and $value -match '^gpt-[a-zA-Z0-9.-]+$'){$value}
    }
    $names | Select-Object -Unique
}
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
        AutoStart=$true; AutoCheck=$false; PollMinutes=10; MinimumGapSeconds=20
        AlwaysOnTop=$false; OpacityPercent=100; FontSize=12; Width=660; Height=540
        ShowEmail=$true; ShowPlan=$true; ShowQuota=$true; ShowResets=$true
        ShowSessionCount=$false; ShowUptime=$false; ShowProcessIds=$false
        ShowFolder=$false; ShowSource=$false; ShowCheckedAt=$false; ShowCredits=$false
        ShowWarmup=$false; MaskEmail=$false; Compact=$false; CloseToTray=$true
        ShowModel=$false; AccountPickerUsage=$false
        ViewMode='Widget'; WidgetShowEmail=$false; WidgetShowResets=$true; WidgetAutoHeight=$true
        WidgetWidth=350; WidgetHeight=340
        WarmupEnabled=$false; WarmupAccounts=''; WarmupModel='gpt-5.6-luna'
        WarmupGraceSeconds=60; WarmupMaxDelayMinutes=30
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
    return $profile
}
function Get-DeckNextCheck($Settings, $Record, [DateTimeOffset]$CheckedAt) {
    if($Record.Status -eq 'error'){return $CheckedAt.AddMinutes([Math]::Max(20,$Settings.PollMinutes))}
    $next=$CheckedAt.AddMinutes($Settings.PollMinutes)
    if($Settings.WarmupEnabled -and $Record.PlanType -in @('plus','pro','team','business','enterprise','edu') -and $Record.Account -in @($Settings.WarmupAccounts -split '[,;\s]+')){
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
    $settings.Width = [Math]::Min(1200, [Math]::Max(560, $settings.Width))
    $settings.Height = [Math]::Min(1000, [Math]::Max(260, $settings.Height))
    $settings.OpacityPercent = [Math]::Min(100, [Math]::Max(50, $settings.OpacityPercent))
    $settings.WidgetWidth = [Math]::Min(600, [Math]::Max(300, $settings.WidgetWidth))
    $settings.WidgetHeight = [Math]::Min(800, [Math]::Max(180, $settings.WidgetHeight))
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
function Start-DeckCompanion([string]$SuiteRoot) {
    $scriptPath = Join-Path $SuiteRoot 'Codex-Deck.ps1'
    if (Test-Path -LiteralPath $scriptPath) {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Attach') | Out-Null
    }
}
function Test-DeckWarmup($Settings, $Record, $PreviousReset, $History, [long]$Now) {
    if (-not $Settings.WarmupEnabled -or -not $Settings.AutoCheck) { return $false }
    if ($Record.PlanType -notin @('plus','pro','team','business','enterprise','edu')) { return $false }
    $selected = @($Settings.WarmupAccounts -split '[,;\s]+' | Where-Object { $_ })
    if ($selected -notcontains $Record.Account) { return $false }
    if ($Record.Status -ne 'available' -or $Record.Error -or -not $PreviousReset) { return $false }
    if ($Now -lt ([long]$PreviousReset + $Settings.WarmupGraceSeconds) -or
        $Now -gt ([long]$PreviousReset + 60 * $Settings.WarmupMaxDelayMinutes)) { return $false }
    $window = @($Record.Windows | Where-Object DurationSeconds -eq 18000)
    if ($window.Count -ne 1 -or $null -eq $window[0].UsedPct -or $window[0].UsedPct -ne 0) { return $false }
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
& `$exe.Source exec --ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check --sandbox read-only -c 'approval_policy="never"' -c 'project_doc_max_bytes=0' -c 'model_reasoning_effort="low"' -m '$Model' 'Hi. Reply only with hi. Do not use tools or read files.'
exit `$LASTEXITCODE
"@
}
