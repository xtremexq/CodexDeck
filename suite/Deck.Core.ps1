function Get-DeckModelNames($Values) {
    $names=foreach($value in $Values){
        if($value -is [array]){Get-DeckModelNames $value}
        elseif($value -is [string] -and $value -match '^gpt-[a-zA-Z0-9.-]+$'){$value}
    }
    $names | Select-Object -Unique
}
. (Join-Path $PSScriptRoot 'Deck.AccountTools.ps1')
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.GlobalRules.ps1')){. (Join-Path $PSScriptRoot 'Deck.GlobalRules.ps1')}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.Memories.ps1')){. (Join-Path $PSScriptRoot 'Deck.Memories.ps1')}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.AccountResources.ps1')){. (Join-Path $PSScriptRoot 'Deck.AccountResources.ps1')}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.Storage.ps1')){. (Join-Path $PSScriptRoot 'Deck.Storage.ps1')}
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.Environments.ps1')) { . (Join-Path $PSScriptRoot 'Deck.Environments.ps1') }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Deck.BundledSkills.ps1')) { . (Join-Path $PSScriptRoot 'Deck.BundledSkills.ps1') }
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
        WarmupEnabled=$false; WarmupSchedulingEnabled=$false; WarmupPlanTypes=''; WarmupAccounts=''; WarmupModel='gpt-5.6-luna'
        WarmupGraceSeconds=60; WarmupMaxDelayMinutes=30
        WarmupResetEnabled=$true; WarmupTimedEnabled=$false; WarmupTimes=''
        WarmupStartAtLogin=$true
        FailoverEnabled=$false; FailoverMode='Ordered'; FailoverAccounts=''
        AutoCompactThresholdPercent=70
        AutoCompactHandoffPrompt='Context is nearing the configured limit. At the next safe point, write a visible task-state handoff beginning with DECK_HANDOFF: with what you''re currently doing, objective, work completed, verified findings, decisions and constraints, unresolved questions, and next steps. Be concise while preserving important information.'
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
    if($Settings.WarmupEnabled -and (Test-DeckWarmupSelected $Settings $Record.Account $Record.PlanType)){
        $primary=Get-DeckWarmupWindow $Record
        if($primary.ResetsAtUnix){
            $target=[DateTimeOffset]::FromUnixTimeSeconds([long]$primary.ResetsAtUnix).AddSeconds($Settings.WarmupGraceSeconds)
            if($target -gt $CheckedAt -and $target -lt $next){$next=$target}
            elseif($target -le $CheckedAt -and $CheckedAt -le $target.AddMinutes($Settings.WarmupMaxDelayMinutes)){$next=$CheckedAt.AddSeconds(60)}
        }
    }
    return $next
}
function Read-DeckJson([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $json=[IO.File]::ReadAllText($Path)
            # PowerShell 7.5 started materializing ISO strings as DateTime by
            # default. Deck's state schema stores timestamps as strings and
            # casts them explicitly at use sites, matching Windows PowerShell.
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                return $json | ConvertFrom-Json -DateKind String
            }
            return $json | ConvertFrom-Json
        } catch { }
    }
}
function Expand-DeckCheckRecords($Value) {
    foreach ($entry in $Value) {
        if ($null -eq $entry) { continue }
        # Windows PowerShell can serialize an extended array as { value, Count }.
        if ($entry -is [array]) { Expand-DeckCheckRecords $entry }
        elseif ((($entry -is [Collections.IDictionary] -and $entry.Contains('value')) -or $entry.PSObject.Properties['value']) -and $null -ne $entry.value) { Expand-DeckCheckRecords @($entry.value) }
        elseif ($entry.Account -is [string] -and $entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { $entry }
    }
}
function Get-DeckMapValues($Map) {
    if (-not $Map) { return }
    # Windows PowerShell serializes Hashtable.Values itself as { value, Count }.
    # Enumerating entries first produces an ordinary JSON array instead.
    @($Map.GetEnumerator() | ForEach-Object { $_.Value })
}
function ConvertTo-DeckMap($Value, [string]$KeyProperty = 'Account') {
    $map=@{}
    foreach($entry in @(Expand-DeckCheckRecords $Value)){
        $key=[string]$entry.$KeyProperty
        if($key){$map[$key]=$entry}
    }
    return $map
}
function Get-DeckUsageCheckTicks($Record) {
    try{return ([DateTimeOffset]$Record.CheckedAt).UtcDateTime.Ticks}catch{return [long]0}
}
function Get-DeckUsageCache([string]$Root) {
    $cache=@{}
    foreach($file in 'cache.json','terminal-cache.json'){
        foreach($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $Root $file)))){
            $old=$cache[$entry.Account]
            if(-not $old -or (Get-DeckUsageCheckTicks $entry) -gt (Get-DeckUsageCheckTicks $old)){$cache[$entry.Account]=$entry}
        }
    }
    return $cache
}
function Save-DeckUsageCache([string]$Root, $Records, [string]$FileName = 'cache.json') {
    if($FileName -notin @('cache.json','terminal-cache.json')){throw 'Invalid usage cache file.'}
    $latest=Get-DeckUsageCache $Root
    foreach($entry in @(Get-DeckMapValues $Records)){
        if(-not $entry -or $entry.Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){continue}
        $old=$latest[$entry.Account]
        if(-not $old -or (Get-DeckUsageCheckTicks $entry) -ge (Get-DeckUsageCheckTicks $old)){$latest[$entry.Account]=$entry}
    }
    Write-DeckJson (Join-Path $Root $FileName) @(Get-DeckMapValues $latest)
    return $latest
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
            $candidate=$saved.$key
            if ($null -eq $candidate) { continue }
            if ($candidate.GetType() -eq $settings[$key].GetType()) { $settings[$key] = $candidate; continue }
            # ConvertFrom-Json returns small integers as Int32 in Windows
            # PowerShell and Int64 in newer PowerShell. Accept either without
            # weakening the strict string/boolean type checks.
            if ($settings[$key] -is [int] -and $candidate.GetTypeCode() -in @(
                [TypeCode]::SByte,[TypeCode]::Byte,[TypeCode]::Int16,[TypeCode]::UInt16,
                [TypeCode]::Int32,[TypeCode]::UInt32,[TypeCode]::Int64,[TypeCode]::UInt64)) {
                try { $settings[$key]=[Convert]::ToInt32($candidate) } catch { }
            }
        }
        # WarmupAllPaid was the pre-1.5 boolean selector. Migrate it only when
        # the new multi-select scope has not already been saved.
        if (-not $saved.PSObject.Properties['WarmupPlanTypes'] -and
            $saved.PSObject.Properties['WarmupAllPaid'] -and $saved.WarmupAllPaid -is [bool] -and $saved.WarmupAllPaid) {
            $settings.WarmupPlanTypes='paid'
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
    $settings.AutoCompactThresholdPercent = [Math]::Min(90, [Math]::Max(30, $settings.AutoCompactThresholdPercent))
    if ([string]::IsNullOrWhiteSpace($settings.AutoCompactHandoffPrompt) -or $settings.AutoCompactHandoffPrompt.Length -gt 4000 -or -not $settings.AutoCompactHandoffPrompt.Contains('DECK_HANDOFF')) {
        $settings.AutoCompactHandoffPrompt=(Get-DeckDefaults).AutoCompactHandoffPrompt
    }
    if ($settings.FailoverMode -notin @('Ordered','Best')) { $settings.FailoverMode='Ordered' }
    if ($settings.ViewMode -notin @('Panel','Widget','Tray')) { $settings.ViewMode='Widget' }
    $settings.WarmupPlanTypes=ConvertTo-DeckWarmupPlanTypes $settings.WarmupPlanTypes
    return $settings
}
function Register-DeckSession([string]$Root, [string]$Account, [string]$Folder) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { throw 'Invalid session account.' }
    $proc = Get-Process -Id $PID
    try{$startTicks=$proc.StartTime.ToUniversalTime().Ticks}finally{$proc.Dispose()}
    $path = Join-Path $Root ('sessions/' + [guid]::NewGuid().ToString('N') + '.json')
    Write-DeckJson $path ([ordered]@{ Account=$Account; ProcessId=$PID; ProcessStartTicks=$startTicks; StartedAt=[DateTimeOffset]::Now.ToString('o'); Folder=$Folder })
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
                try{$valid = $proc.StartTime.ToUniversalTime().Ticks -eq $entry.ProcessStartTicks}finally{$proc.Dispose()}
            } catch { }
        }
        if ($valid) { $entry }
        else { Remove-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue }
    }
}
function ConvertTo-DeckProcessArgument([AllowEmptyString()][string]$Value) {
    if ($null -eq $Value) { $Value='' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted=[Text.StringBuilder]::new(); [void]$quoted.Append('"'); $slashes=0
    foreach($character in $Value.ToCharArray()){
        if($character -eq '\'){ $slashes++; continue }
        if($character -eq '"'){
            [void]$quoted.Append(('\' * ($slashes*2+1))); [void]$quoted.Append('"'); $slashes=0; continue
        }
        if($slashes){[void]$quoted.Append(('\' * $slashes)); $slashes=0}
        [void]$quoted.Append($character)
    }
    if($slashes){[void]$quoted.Append(('\' * ($slashes*2)))}
    [void]$quoted.Append('"')
    return $quoted.ToString()
}
function Get-DeckBackgroundPowerShellArguments([string]$ScriptPath, [string[]]$Arguments, [switch]$Sta) {
    $parts=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden')
    if($Sta){$parts+='-STA'}
    $parts+=@('-ExecutionPolicy','Bypass','-File',$ScriptPath)+@($Arguments)
    return (($parts | ForEach-Object { ConvertTo-DeckProcessArgument ([string]$_) }) -join ' ')
}
function Start-DeckBackgroundPowerShell([string]$ScriptPath, [string[]]$Arguments, [switch]$Sta) {
    if(-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)){throw "Background script not found: $ScriptPath"}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=(Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info.Arguments=Get-DeckBackgroundPowerShellArguments $ScriptPath $Arguments -Sta:$Sta
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    return [Diagnostics.Process]::Start($info)
}
function Start-DeckCompanion([string]$SuiteRoot, [switch]$OpenSettings) {
    $scriptPath = Join-Path $SuiteRoot 'Codex-Deck.ps1'
    if (Test-Path -LiteralPath $scriptPath) {
        $launchMode=if($OpenSettings){'-OpenSettings'}else{'-Attach'}
        $process=Start-DeckBackgroundPowerShell $scriptPath @($launchMode) -Sta
        $process.Dispose()
    }
}
function Test-DeckWarmup($Settings, $Record, $PreviousReset, $History, [long]$Now) {
    if (-not $Settings.WarmupEnabled -or $Settings.WarmupResetEnabled -eq $false) { return $false }
    if (-not (Test-DeckWarmupSelected $Settings $Record.Account $Record.PlanType)) { return $false }
    if ($Record.Status -ne 'available' -or $Record.Error -or -not $PreviousReset) { return $false }
    if ($Now -lt ([long]$PreviousReset + $Settings.WarmupGraceSeconds) -or
        $Now -gt ([long]$PreviousReset + 60 * $Settings.WarmupMaxDelayMinutes)) { return $false }
    $window = Get-DeckWarmupWindow $Record
    if (-not $window -or $null -eq $window.UsedPct -or $window.UsedPct -ne 0) { return $false }
    if (@($Record.Windows | Where-Object { $_.Dead -or ($null -ne $_.UsedPct -and $_.UsedPct -ge 99.5) }).Count) { return $false }
    # A confirmed request already started this window. Failed/unconfirmed requests
    # may retry after 90 seconds while the configured reset window remains open.
    if ($History -and [long]$History.Reset -eq [long]$PreviousReset -and [string]$History.Outcome -like 'Replied:*') { return $false }
    if ($History -and $Now - [long]$History.AttemptAt -lt 90) { return $false }
    return $true
}
if(-not ('DeckProcessJob' -as [type])){
    Add-Type @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public sealed class DeckProcessJob : IDisposable {
    const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    IntPtr handle;

    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public Int64 PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public UInt32 LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public UInt32 ActiveProcessLimit;
        public UIntPtr Affinity;
        public UInt32 PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, Int32 infoClass, IntPtr info, UInt32 length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, UInt32 exitCode);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr value);

    public DeckProcessJob(Process process) {
        handle=CreateJobObject(IntPtr.Zero, null);
        if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var limits=new ExtendedLimits();
            limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size=Marshal.SizeOf(typeof(ExtendedLimits));
            IntPtr data=Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits,data,false);
                if(!SetInformationJobObject(handle,9,data,(UInt32)size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(data); }
            if(!AssignProcessToJobObject(handle,process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } catch { Dispose(); throw; }
    }
    public void Terminate() { if(handle!=IntPtr.Zero) TerminateJobObject(handle,1); }
    public void Dispose() {
        IntPtr value=handle; handle=IntPtr.Zero;
        if(value!=IntPtr.Zero) CloseHandle(value);
        GC.SuppressFinalize(this);
    }
    ~DeckProcessJob(){Dispose();}
}
'@
}
function Start-DeckTask([string]$Code, [string]$Kind, [string]$Account) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process = [Diagnostics.Process]::Start($info)
    $job=$null
    try{$job=[DeckProcessJob]::new($process)}catch{}
    return @{ Process=$process; Out=$process.StandardOutput.ReadToEndAsync(); Err=$process.StandardError.ReadToEndAsync(); Job=$job; Kind=$Kind; Account=$Account; Started=[DateTimeOffset]::UtcNow; ExitObservedAt=$null }
}
function Stop-DeckTask($Task) {
    if(-not $Task){return}
    # A job owns the full worker tree, including codex.cmd and its Node child.
    # Native taskkill is only a silent fallback when Windows rejected job nesting.
    if($Task.Job){try{$Task.Job.Terminate()}catch{}; return}
    try{
        if($Task.Process.HasExited){return}
        $info=[Diagnostics.ProcessStartInfo]::new('taskkill.exe',('/PID {0} /T /F' -f $Task.Process.Id))
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $killer=[Diagnostics.Process]::Start($info)
        try{[void]$killer.WaitForExit(3000)}finally{$killer.Dispose()}
    }catch{}
    try{if(-not $Task.Process.HasExited){$Task.Process.Kill(); [void]$Task.Process.WaitForExit(1000)}}catch{}
}
function Test-DeckTaskReady($Task, [int]$DrainGraceSeconds = 2) {
    if(-not $Task){return $false}
    try{if(-not $Task.Process.HasExited){return $false}}catch{return $true}
    $outReady=(-not $Task.Out -or $Task.Out.IsCompleted -ne $false)
    $errReady=(-not $Task.Err -or $Task.Err.IsCompleted -ne $false)
    if($outReady -and $errReady){return $true}
    $now=[DateTimeOffset]::UtcNow
    if(-not $Task.ExitObservedAt){$Task.ExitObservedAt=$now; return $false}
    if(($now-$Task.ExitObservedAt).TotalSeconds -ge $DrainGraceSeconds){Stop-DeckTask $Task}
    return ((-not $Task.Out -or $Task.Out.IsCompleted -ne $false) -and (-not $Task.Err -or $Task.Err.IsCompleted -ne $false))
}
function Dispose-DeckTask($Task) {
    if(-not $Task){return}
    try{if($Task.Job){$Task.Job.Dispose()}}catch{}
    try{$Task.Process.Dispose()}catch{}
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
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or ($Model -and $Model -notmatch '^gpt-[a-zA-Z0-9.-]+$')) { throw 'Invalid warm-up account or model.' }
    $accountPath = (Join-Path $SuiteRoot "accounts/$Account").Replace("'", "''")
    $workPath = (Join-Path $SuiteRoot 'deck/empty-workspace').Replace("'", "''")
    $modelArgument=if($Model){"`$deckArgs+=@('-m','$Model')"}else{''}
    return @"
`$ErrorActionPreference='Stop'
`$env:CODEX_HOME='$accountPath'
Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
[void][IO.Directory]::CreateDirectory('$workPath')
Set-Location -LiteralPath '$workPath'
`$exe = Get-Command codex.cmd -ErrorAction SilentlyContinue
if (-not `$exe) { `$exe = Get-Command codex -ErrorAction Stop }
`$ErrorActionPreference='Continue'
`$deckArgs=@('exec','--json','--ignore-user-config','--ignore-rules','--ephemeral','--skip-git-repo-check','--sandbox','read-only','-c','approval_policy="never"','-c','project_doc_max_bytes=0','-c','model_reasoning_effort="low"')
$modelArgument
`$deckArgs+='Hi. Reply only with hi. Do not use tools or read files.'
& `$exe.Source @deckArgs
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
function ConvertTo-DeckWarmupPlanTypes([string]$Value) {
    $chosen=@($Value -split '[,;\s]+' | ForEach-Object {$_.Trim().ToLowerInvariant()} | Where-Object {$_ -in @('all','free','go','paid')} | Select-Object -Unique)
    if($chosen -contains 'all'){return 'all'}
    return (@('free','go','paid') | Where-Object {$_ -in $chosen}) -join ','
}
function Test-DeckWarmupPlanSupported([string]$PlanType) {
    return $PlanType.ToLowerInvariant() -in @('free','go','plus','pro','team','business','enterprise','edu')
}
function Test-DeckWarmupPlanSelected($Settings, [string]$PlanType) {
    $plan=$PlanType.ToLowerInvariant()
    if(-not (Test-DeckWarmupPlanSupported $plan)){return $false}
    $types=@((ConvertTo-DeckWarmupPlanTypes $Settings.WarmupPlanTypes) -split ',' | Where-Object {$_})
    return $types -contains 'all' -or $types -contains $plan -or ($types -contains 'paid' -and $plan -in @('plus','pro','team','business','enterprise','edu'))
}
function Test-DeckWarmupSelected($Settings, [string]$Account, [string]$PlanType = '') {
    $accountSelected=$Account -in @($Settings.WarmupAccounts -split '[,;\s]+' | Where-Object {$_})
    return $accountSelected -or (Test-DeckWarmupPlanSelected $Settings $PlanType)
}
function Get-DeckWarmupWindow($Record) {
    $plan=([string]$Record.PlanType).ToLowerInvariant()
    if($plan -in @('free','go')){
        # Free/Go expose their primary allowance as a longer window. Do not
        # require the paid-plan 5-hour window for these accounts.
        return $Record.Windows | Where-Object {$_.DurationSeconds -gt 0} | Sort-Object DurationSeconds | Select-Object -First 1
    }
    if($plan -in @('plus','pro','team','business','enterprise','edu')){
        return $Record.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
    }
}
function Get-DeckWarmupModel($Settings, [string]$PlanType) {
    # Free and Go can have a narrower model catalog. Let Codex choose the
    # account's supported default instead of forcing the configured paid model.
    if($PlanType.ToLowerInvariant() -in @('free','go')){return ''}
    return [string]$Settings.WarmupModel
}
function Get-DeckWarmupStatus($Settings, $Record, $History, [long]$Now = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) {
    if ($History -and $Now - [long]$History.AttemptAt -lt 14400) { return $History.Outcome }
    if (-not (Test-DeckWarmupSelected $Settings $Record.Account $Record.PlanType)) { return 'Not selected' }
    if (-not $Settings.WarmupEnabled) { return 'Paused' }
    if (-not $Settings.WarmupSchedulingEnabled) { return 'Background scheduling off' }
    if ($Settings.WarmupTimedEnabled -and -not $Settings.WarmupResetEnabled) { return 'Daily ' + $Settings.WarmupTimes + ' (local)' }
    if ($Record.PlanType -and -not (Test-DeckWarmupPlanSupported $Record.PlanType)) { return 'Unsupported account plan' }
    if ($History -and $Now - [long]$History.AttemptAt -lt 14400) { return $History.Outcome }
    if (-not $Record.CheckedAt -or $Record.Error -or $Record.Status -ne 'available') { return 'Waiting for fresh quota' }
    if (@($Record.Windows | Where-Object { $_.Dead -or ($null -ne $_.UsedPct -and $_.UsedPct -ge 99.5) }).Count) { return 'Waiting for quota reset' }
    $primary=Get-DeckWarmupWindow $Record
    if (-not $primary.ResetsAtUnix) { return 'Waiting for reset data' }
    $reset=Get-DeckWarmupReset $Record $primary.ResetsAtUnix $Now
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
        $plan=[string](Get-DeckProfile (Split-Path $Root -Parent) $Account).PlanType
        if (Test-DeckWarmupPlanSelected $current $plan) { throw 'This account is included by account type. Change the selection in Deck settings first.' }
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
    $path=Join-Path $SuiteRoot 'Deck.WarmupWorker.ps1'
    if (Test-Path -LiteralPath $path) {
        $process=Start-DeckBackgroundPowerShell $path @()
        $process.Dispose()
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
function Get-DeckSignedInAccounts([string]$SuiteRoot) {
    @(Get-ChildItem -LiteralPath (Join-Path $SuiteRoot 'accounts') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'auth.json') -PathType Leaf) } |
        Sort-Object Name | ForEach-Object Name)
}
function Get-DeckWarmupAccounts([string]$SuiteRoot, $Settings, $Cache = @{}) {
    foreach($account in @(Get-DeckSignedInAccounts $SuiteRoot)){
        $plan=[string]$Cache[$account].PlanType
        if(-not $plan){$plan=[string](Get-DeckProfile $SuiteRoot $account).PlanType}
        if((Test-DeckWarmupPlanSupported $plan) -and (Test-DeckWarmupSelected $Settings $account $plan)){$account}
    }
}
function Get-DeckNextWarmupRun($Settings, $Accounts, $Cache, $Resets, $History, [DateTimeOffset]$Now = [DateTimeOffset]::Now, [int]$UnknownDelayMinutes = 1) {
    if(-not $Settings.WarmupEnabled -or -not $Settings.WarmupResetEnabled){return}
    if(-not @($Accounts).Count){return $Now.AddHours(6)}
    $unix=$Now.ToUnixTimeSeconds(); $candidates=@()
    foreach($account in @($Accounts)){
        $record=$Cache[$account]
        $blockedWindows=@($record.Windows | Where-Object { $_.Dead -or ($null -ne $_.UsedPct -and $_.UsedPct -ge 99.5) })
        if($blockedWindows.Count){
            # A reset on one window cannot make the account usable while another
            # quota window is still exhausted. Wake after the last blocking reset.
            $blockingResets=@($blockedWindows | Where-Object { $_.ResetsAtUnix -and [long]$_.ResetsAtUnix -gt $unix } | ForEach-Object { [long]$_.ResetsAtUnix })
            if($blockingResets.Count){$candidates+=[DateTimeOffset]::FromUnixTimeSeconds(($blockingResets|Measure-Object -Maximum).Maximum).AddSeconds($Settings.WarmupGraceSeconds).ToLocalTime()}
            else{$candidates+=$Now.AddMinutes([Math]::Max(20,$UnknownDelayMinutes))}
            continue
        }
        if($record -and ($record.Error -or $record.Status -eq 'error')){$candidates+=$Now.AddMinutes([Math]::Max(20,$UnknownDelayMinutes)); continue}
        $reset=if($Resets[$account]){[long]$Resets[$account]}else{
            $primary=Get-DeckWarmupWindow $record
            if($primary.ResetsAtUnix){[long]$primary.ResetsAtUnix}else{0}
        }
        if(-not $reset){$candidates+=$Now.AddMinutes($UnknownDelayMinutes); continue}
        $due=[DateTimeOffset]::FromUnixTimeSeconds($reset).AddSeconds($Settings.WarmupGraceSeconds).ToLocalTime()
        if($due -gt $Now){$candidates+=$due; continue}
        if($unix -le $reset + 60*$Settings.WarmupMaxDelayMinutes){
            $entry=$History[$account]
            if($entry -and [long]$entry.Reset -eq $reset -and [string]$entry.Outcome -like 'Replied:*'){$candidates+=$Now.AddMinutes([Math]::Max(5,$UnknownDelayMinutes))}
            else{
                $retry=$Now.AddSeconds(60)
                if($entry.AttemptAt){$retryAt=[DateTimeOffset]::FromUnixTimeSeconds([long]$entry.AttemptAt+90).ToLocalTime(); if($retryAt -gt $retry){$retry=$retryAt}}
                $candidates+=$retry
            }
        }else{$candidates+=$Now.AddMinutes([Math]::Max(20,$UnknownDelayMinutes))}
    }
    $candidates | Sort-Object | Select-Object -First 1
}
function Test-DeckWarmupScheduleHealthy([string]$SuiteRoot, $Settings) {
    if($env:OS -ne 'Windows_NT'){return $true}
    $taskName='CodexDeck Warmup Scheduling'
    if(-not $Settings.WarmupEnabled -or -not $Settings.WarmupSchedulingEnabled){
        foreach($disabledTaskName in @($taskName,'CodexDeck Automatic Warm-up')){
            try{if(Get-ScheduledTask -TaskName $disabledTaskName -ErrorAction Stop){return $false}}catch{}
        }
        return $true
    }
    try{
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        if(-not $task){return $false}
        $action=@($task.Actions | Select-Object -First 1)[0]
        $worker=Join-Path $SuiteRoot 'Deck.WarmupWorker.ps1'
        if(-not $action -or [IO.Path]::GetFileName([string]$action.Execute) -ine 'wscript.exe' -or ([string]$action.Arguments).IndexOf($worker,[StringComparison]::OrdinalIgnoreCase) -lt 0){return $false}
        if([string]$task.State -eq 'Running'){return $true}
        $info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        return $info.NextRunTime -and [datetime]$info.NextRunTime -gt [datetime]::Now.AddMinutes(-1)
    }catch{return $false}
}
function Repair-DeckWarmupSchedule([string]$SuiteRoot, $Settings) {
    if(Test-DeckWarmupScheduleHealthy $SuiteRoot $Settings){return $false}
    Sync-DeckWarmupStartup $SuiteRoot $Settings
    return $true
}
function Sync-DeckWarmupStartup([string]$SuiteRoot, $Settings, $NextRun = $null) {
    # Remove the legacy Run entry. Automatic warm-up is a clearly named per-user
    # Scheduled Task whose short-lived worker never attaches to the desktop.
    $runPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if(Test-Path $runPath){Remove-ItemProperty -Path $runPath -Name 'CodexDeckWarmup' -ErrorAction SilentlyContinue}
    if($env:OS -ne 'Windows_NT'){return}
    $taskName='CodexDeck Warmup Scheduling'
    $legacyTaskNames=@('CodexDeck Automatic Warm-up')
    if(-not $Settings.WarmupEnabled -or -not $Settings.WarmupSchedulingEnabled){
        foreach($disabledTaskName in @($taskName)+$legacyTaskNames){Unregister-ScheduledTask -TaskName $disabledTaskName -Confirm:$false -ErrorAction SilentlyContinue}
        return
    }
    $worker=Join-Path $SuiteRoot 'Deck.WarmupWorker.ps1'
    if(-not (Test-Path -LiteralPath $worker -PathType Leaf)){throw 'Warm-up worker is not installed.'}
    $backgroundLauncher=Join-Path $SuiteRoot 'Deck.Background.vbs'
    if(-not (Test-Path -LiteralPath $backgroundLauncher -PathType Leaf)){throw 'Background launcher is not installed.'}
    if($null -eq $NextRun){
        $cache=ConvertTo-DeckMap (Read-DeckJson (Join-Path $SuiteRoot 'deck/cache.json'))
        $history=ConvertTo-DeckMap (Read-DeckJson (Join-Path $SuiteRoot 'deck/warmup.json'))
        $resets=@{}; $saved=Read-DeckJson (Join-Path $SuiteRoot 'deck/warmup-resets.json'); if($saved){foreach($property in $saved.PSObject.Properties){$resets[$property.Name]=[long]$property.Value}}
        $accounts=@(Get-DeckWarmupAccounts $SuiteRoot $Settings $cache)
        $computed=Get-DeckNextWarmupRun $Settings $accounts $cache $resets $history ([DateTimeOffset]::Now) 1
        if($computed){$NextRun=[DateTimeOffset]$computed}
    }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $triggers=@()
    if($Settings.WarmupStartAtLogin){$triggers+=New-ScheduledTaskTrigger -AtLogOn -User $identity}
    foreach($time in @((ConvertTo-DeckWarmupTimes $Settings.WarmupTimes) -split ', ' | Where-Object {$_})){
        if($Settings.WarmupTimedEnabled){$triggers+=New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([TimeSpan]::Parse($time)))}
    }
    if($null -ne $NextRun){
        $at=([DateTimeOffset]$NextRun).ToLocalTime(); if($at -lt [DateTimeOffset]::Now.AddSeconds(15)){$at=[DateTimeOffset]::Now.AddSeconds(15)}
        $triggers+=New-ScheduledTaskTrigger -Once -At $at.LocalDateTime
    }
    # Keep an independent trigger in the task definition. Normally the precise
    # one-shot trigger above is replaced after every worker run. If that update
    # ever fails, this watchdog gives the existing task another chance to repair
    # itself instead of leaving warm-up silently dead until the next sign-in.
    $watchdogInterval=New-TimeSpan -Minutes 15
    $triggers+=New-ScheduledTaskTrigger -Once -At ([datetime]::Now.Add($watchdogInterval)) -RepetitionInterval $watchdogInterval -RepetitionDuration (New-TimeSpan -Days 1)
    if(-not $triggers.Count){$triggers+=New-ScheduledTaskTrigger -Once -At ([datetime]::Now.AddMinutes(1))}
    $scriptHost=Join-Path $env:SystemRoot 'System32\wscript.exe'
    $actionArguments=@('//B','//Nologo',$backgroundLauncher,$worker) | ForEach-Object { ConvertTo-DeckProcessArgument ([string]$_) }
    $action=New-ScheduledTaskAction -Execute $scriptHost -Argument ($actionArguments -join ' ') -WorkingDirectory $SuiteRoot
    # WScript is a GUI-subsystem host and the launcher uses window style 0, so
    # neither it nor the child PowerShell process can flash on the desktop.
    $principal=New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $taskSettings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $taskSettings -Principal $principal -Description 'Checks selected Codex accounts at warm-up times, warms eligible accounts, refreshes quota state, and exits. Managed by Codex Deck.' -Force | Out-Null
    # Only retire the previous task after the replacement was registered. A
    # registration failure must not silently disable an existing schedule.
    foreach($legacyTaskName in $legacyTaskNames){Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction SilentlyContinue}
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
            $plan=$Cache[$account].PlanType
            if(-not $plan){$plan=(Get-DeckProfile $SuiteRoot $account).PlanType}
            if(-not (Test-DeckWarmupPlanSupported $plan) -or -not (Test-DeckWarmupSelected $Settings $account $plan)){continue}
            if(-not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$account/auth.json"))){continue}
            $key="$slot/$account"; if($ledger.ContainsKey($key)){continue}
            $request=Join-Path $root "warmup-requests/$account.json"
            if(-not (Test-Path -LiteralPath $request)){Write-DeckJson $request @{Account=$account;Mode='Timed';At=$Now.ToUnixTimeSeconds();Slot=$slot}}
            $ledger[$key]=@{Key=$key;At=$Now.ToUnixTimeSeconds()}; $dirty=$true
        }
    }
    if($dirty){Write-DeckJson (Join-Path $root 'warmup-schedule.json') @(Get-DeckMapValues $ledger)}
}
function Invoke-DeckQueuedWarmups([string]$SuiteRoot, $Settings, $Tasks, $History, [long]$Now) {
    $root=Join-Path $SuiteRoot 'deck'
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'warmup-requests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)){
        if($Tasks.Count -ge 8){break}
        $request=Read-DeckJson $file.FullName; $account=[string]$request.Account
        if($account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $request.Mode -notin @('Manual','Timed')){Remove-Item -LiteralPath $file.FullName; continue}
        if($Tasks.ContainsKey($account)){continue}
        $expired=$Now-[long]$request.At -gt $(if($request.Mode -eq 'Timed'){300}else{3600})
        $plan=[string](Get-DeckProfile $SuiteRoot $account).PlanType
        $paused=$request.Mode -eq 'Timed' -and (-not $Settings.WarmupEnabled -or -not $Settings.WarmupTimedEnabled -or -not (Test-DeckWarmupSelected $Settings $account $plan))
        $recent=$History[$account] -and $Now-[long]$History[$account].AttemptAt -lt 30
        if($expired -or $paused -or $recent -or -not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$account/auth.json"))){Remove-Item -LiteralPath $file.FullName; continue}
        $History[$account]=[pscustomobject]@{Account=$account;Reset=0;AttemptAt=$Now;Mode=$request.Mode;Outcome='Sending / waiting for reply';Reply=''}
        Write-DeckJson (Join-Path $root 'warmup.json') @(Get-DeckMapValues $History)
        Remove-Item -LiteralPath $file.FullName
        try{$Tasks[$account]=Start-DeckTask (Get-DeckWarmupCode $SuiteRoot $account (Get-DeckWarmupModel $Settings $plan)) 'Warm-up' $account}
        catch{$History[$account].Outcome='Failed to start'; Write-DeckJson (Join-Path $root 'warmup.json') @(Get-DeckMapValues $History)}
    }
}

function Get-DeckWarmupReset($Record, $PreviousReset, [long]$Now) {
    if ($PreviousReset) {
        # A known future boundary is authoritative. Inferring the current window
        # start from its end would make the just-warmed window look new and can
        # send a duplicate warm-up while integer usage still rounds to zero.
        if ([long]$PreviousReset -gt $Now) { return [long]$PreviousReset }
        if ($Now - [long]$PreviousReset -le 3600) { return [long]$PreviousReset }
    }
    $primary=Get-DeckWarmupWindow $Record
    # A full, freshly reported empty window also permits discovery after starting Deck.
    # The inferred start must be in the past; future/incomplete data is never eligible.
    if ($primary.ResetsAtUnix -and $null -ne $primary.UsedPct -and $primary.UsedPct -eq 0) {
        $start=[long]$primary.ResetsAtUnix - [long]$primary.DurationSeconds
        if ($start -gt 0 -and $start -le $Now -and $Now-$start -le 300) { return $start }
    }
    return $PreviousReset
}
