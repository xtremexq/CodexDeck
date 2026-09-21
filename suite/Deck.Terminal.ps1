# Terminal administration for Codex Deck. Windows PowerShell 5.1, no extra packages.
function ConvertTo-DeckTerminalText($Value, [int]$Width = 200) {
    $text = ([string]$Value -replace '[\x00-\x1f\x7f-\x9f]', ' ')
    if ($text.Length -gt $Width) { return $text.Substring(0, [Math]::Max(0, $Width - 1)) + '~' }
    return $text
}
function Expand-DeckTerminalRecords($Value) {
    foreach ($entry in $Value) {
        if ($entry -is [array]) { Expand-DeckTerminalRecords $entry }
        elseif ($entry -and $entry.PSObject.Properties['value']) { Expand-DeckTerminalRecords $entry.value }
        elseif ($entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { $entry }
    }
}
function Get-DeckTerminalCache([string]$Root) {
    return Get-DeckUsageCache $Root
}
function Format-DeckTerminalQuota($Window) {
    if (-not $Window -or $null -eq $Window.RemainingPct) { return '[----------]   ?' }
    $pct = [Math]::Min(100, [Math]::Max(0, [double]$Window.RemainingPct))
    $bars = [int][Math]::Floor($pct / 10)
    return '[{0}{1}] {2,3}%' -f ('#' * $bars), ('-' * (10 - $bars)), [int]$pct
}
function Format-DeckTerminalReset($Window) {
    if(-not $Window -or -not $Window.ResetsAtUnix){return '-'}
    $at=[DateTimeOffset]::FromUnixTimeSeconds([long]$Window.ResetsAtUnix).ToLocalTime()
    if($at -le [DateTimeOffset]::Now){return 'due'}
    return $at.ToString('MMM dd HH:mm')
}
function Get-DeckTerminalResetWindow($Record, $PrimaryWindow) {
    if (-not $Record) { return $PrimaryWindow }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $blocking = @($Record.Windows | Where-Object {
        (-not $_.ResetsAtUnix -or [long]$_.ResetsAtUnix -gt $now) -and
        ($_.Dead -or ($null -ne $_.RemainingPct -and [double]$_.RemainingPct -le 0))
    })
    if ($blocking.Count) {
        # When one or more current windows block requests, only their reset can
        # make the account usable. Do not show an earlier, healthy 5-hour reset.
        return @($blocking | Where-Object ResetsAtUnix | Sort-Object { [long]$_.ResetsAtUnix } | Select-Object -First 1)
    }
    if ($PrimaryWindow) { return $PrimaryWindow }
    return @($Record.Windows | Where-Object ResetsAtUnix | Sort-Object { [long]$_.ResetsAtUnix } | Select-Object -First 1)
}
function Get-DeckTerminalHealth($Record) {
    if (-not $Record) { return 'Not checked' }
    if ($Record.Error -or $Record.Status -eq 'error') { return 'Check failed' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $current = @($Record.Windows | Where-Object { -not $_.ResetsAtUnix -or [long]$_.ResetsAtUnix -gt $now })
    if (@($current | Where-Object { $_.Dead -or ($null -ne $_.RemainingPct -and [double]$_.RemainingPct -le 0) }).Count) { return 'Exhausted' }
    if (@($Record.Windows).Count -gt $current.Count) { return 'Reset passed' }
    if ($Record.Status -ne 'available') { return 'Unavailable' }
    return 'Ready'
}
function Get-DeckTerminalFrame($Names, $Cache, $Profiles, $Sessions, $Tasks, [int]$Selected, [int]$Width, [int]$Height, [string]$Filter, [string]$Notice, [bool]$Mask = $true, $WarmupSettings = $null, $WarmupHistory = @{}, [bool]$AutoCompact = $false, [int]$CompactThreshold = 70, [bool]$CompactAdjusting = $false) {
    $lines = [Collections.Generic.List[object]]::new()
    function Add-Line([string]$Text, [string]$Color = 'Gray', [string]$Background = 'Black') {
        $lines.Add(@{ Text = (ConvertTo-DeckTerminalText $Text ([Math]::Max(1,$Width - 1))); Color = $Color; Background = $Background })
    }
    Add-Line '  CODEX / DECK                                      ACCOUNT CONTROL' 'Cyan'
    Add-Line ('  {0} accounts   /   {1} connected sessions   /   {2} checking' -f $Names.Count, @($Sessions).Count, $Tasks.Count) 'DarkGray'
    Add-Line '  Usage remaining  |  cached instantly, fresh checks in background' 'DarkGray'
    Add-Line ('  Filter: {0}' -f $(if ($Filter) { $Filter } else { 'all accounts  (/ to search)' })) 'Cyan'
    Add-Line ('  {0,-18} {1,-9} {2,-18} {3,-18} {4,-14} {5}' -f 'ACCOUNT','PLAN','PRIMARY','WEEKLY','STATE','NEXT RESET') 'DarkGray'
    $pageSize = [Math]::Max(1, $Height - 18)
    $start = [int]([Math]::Floor($Selected / $pageSize) * $pageSize)
    for ($i = $start; $i -lt [Math]::Min($Names.Count, $start + $pageSize); $i++) {
        $name = $Names[$i]; $row = $Cache[$name]; $profile = $Profiles[$name]
        $five = $row.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
        if (-not $five) { $five = $row.Windows | Where-Object DurationSeconds -ne 604800 | Select-Object -First 1 }
        $week = $row.Windows | Where-Object DurationSeconds -eq 604800 | Select-Object -First 1
        $state = Get-DeckTerminalHealth $row
        if ($profile.PlanType -eq 'pool') { $state = 'Pooled session' }
        if ($Tasks.ContainsKey($name)) { $state = 'Checking...' }
        $marker = if ($i -eq $Selected) { '>' } else { ' ' }
        $color = if ($state -eq 'Ready') { 'Green' } elseif ($state -in @('Check failed','Exhausted')) { 'Yellow' } else { 'Gray' }
        $bg = if ($i -eq $Selected) { 'DarkBlue' } else { 'Black' }
        $resetWindow = Get-DeckTerminalResetWindow $row $five
        Add-Line ('{0} {1,-18} {2,-9} {3,-18} {4,-18} {5,-14} {6}' -f $marker,(ConvertTo-DeckTerminalText $name 18),(ConvertTo-DeckTerminalText $profile.PlanType 9),(Format-DeckTerminalQuota $five),(Format-DeckTerminalQuota $week),(ConvertTo-DeckTerminalText $state 14),(Format-DeckTerminalReset $resetWindow)) $color $bg
    }
    if (-not $Names.Count) { Add-Line '  No matching accounts. Press N to create one, or / to change the filter.' 'Yellow' }
    Add-Line ('  -- {0}-{1} of {2} --' -f ([Math]::Min($start + 1,$Names.Count)),([Math]::Min($start + $pageSize,$Names.Count)),$Names.Count) 'DarkGray'
    if ($Names.Count) {
        $name = $Names[$Selected]; $row = $Cache[$name]; $profile = $Profiles[$name]
        $email = [string]$profile.Email
        if ($Mask -and $email) { $email = $email -replace '^(.).*?(@.*)$','$1***$2' }
        Add-Line ('  {0}  |  {1}  |  {2} / {3}' -f $name,$email,$profile.Model,$profile.Effort) 'Cyan'
        $checked = 'never'
        if ($row.CheckedAt) { try { $checked = ([DateTimeOffset]$row.CheckedAt).ToLocalTime().ToString('MMM dd HH:mm:ss') } catch {} }
        Add-Line ('  Last checked: {0}  |  {1}  |  active here: {2}' -f $checked,(Get-DeckTerminalHealth $row),($env:CODEX_HOME -and (Split-Path $env:CODEX_HOME -Leaf) -eq $name)) 'DarkGray'
        $resets = foreach ($window in $row.Windows) {
            if ($window.ResetsAtUnix) { '{0}: {1}' -f $window.Label,([DateTimeOffset]::FromUnixTimeSeconds([long]$window.ResetsAtUnix).ToLocalTime().ToString('MMM dd HH:mm')) }
        }
        Add-Line ('  Window resets (primary = 5H or plan window): ' + ($resets -join '  /  ') + ' | Reset credits: ' + (Format-DeckResetCredits $row)) 'DarkGray'
        $connected = @($Sessions | Where-Object Account -eq $name)
        if ($connected.Count) { Add-Line ('  Sessions: ' + (($connected | ForEach-Object { '{0} @ {1}' -f $_.ProcessId,$_.Folder }) -join ' | ')) 'DarkGray' }
    }
    if ($WarmupSettings) {
        $warmState=if($Names.Count){Get-DeckWarmupStatus $WarmupSettings $(if($Cache[$Names[$Selected]]){$Cache[$Names[$Selected]]}else{@{Account=$Names[$Selected]}}) $WarmupHistory[$Names[$Selected]]}else{'No account selected'}
        $warmMode=if(-not $WarmupSettings.WarmupEnabled){'PAUSED'}elseif($WarmupSettings.WarmupSchedulingEnabled){'SCHEDULED'}else{'UNSCHEDULED'}
        Add-Line ('  AUTO WARM-UP: '+$warmMode+' | '+$warmState) 'Yellow'
    }
    Add-Line '  WARMUP   U run now  T daily times  W select account  P pause/resume' 'DarkMagenta'
    Add-Line ('  ' + $Notice) 'Yellow'
    if($CompactAdjusting){
        Add-Line ('  AUTO-COMPACT FREE CONTEXT  [{0}%]   Up/Down 5%   Enter save   Esc cancel' -f $CompactThreshold) 'White' 'DarkBlue'
    }else{
        Add-Line ('  NAVIGATE Enter launch  / search  B best  Q quit  C compact [{0}] {1}% free (hold C to adjust)' -f $(if($AutoCompact){'x'}else{' '}),$CompactThreshold) 'Gray'
    }
    Add-Line '  MANAGE   R refresh  A all  H history  F2 rename  L login  N new' 'DarkGray'
    Add-Line '  DISPLAY  D desktop  S settings  G global  I instructions  E memories  K skills  M mask' 'DarkGray'
    return $lines.ToArray()
}
function Read-DeckTerminalInput([string]$Prompt, [int]$MaxLength = 40) {
    [Console]::Write($Prompt + ': ')
    $value = ''
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape' -or [int]$key.KeyChar -eq 27) { return '' }
        if ($key.Key -eq 'Enter' -or [int]$key.KeyChar -in @(10,13)) { [Console]::WriteLine(); return $value }
        if (($key.Key -eq 'Backspace' -or [int]$key.KeyChar -eq 8) -and $value.Length) {
            $value = $value.Substring(0,$value.Length - 1)
            [Console]::Write("`b `b")
        } elseif (-not [char]::IsControl($key.KeyChar) -and $value.Length -lt $MaxLength) {
            $value += $key.KeyChar; [Console]::Write($key.KeyChar)
        }
    }
}
function Test-DeckTerminalKeyHold([int]$VirtualKey, [int]$HoldMilliseconds = 450) {
    try {
        if(-not ('CodexDeckNativeKeyboard' -as [type])){
            Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CodexDeckNativeKeyboard {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);
}
'@
        }
        $until=[DateTimeOffset]::UtcNow.AddMilliseconds($HoldMilliseconds)
        while([DateTimeOffset]::UtcNow -lt $until){
            if(([CodexDeckNativeKeyboard]::GetAsyncKeyState($VirtualKey) -band 0x8000) -eq 0){return $false}
            Start-Sleep -Milliseconds 20
        }
        return $true
    }catch{return $false}
}
function Show-DeckTerminal {
    param([string]$SuiteRoot, [string]$AuthScript, [switch]$Snapshot)
    . (Join-Path $SuiteRoot 'Deck.Core.ps1')
    $root = Join-Path $SuiteRoot 'deck'
    $accountRoot = Join-Path $SuiteRoot 'accounts'
    $warmSettings=Get-DeckSettings $root
    $cache = Get-DeckTerminalCache $root
    $profiles = @{}; $tasks = @{}; $pending = [Collections.Generic.Queue[string]]::new()
    $names=@(); $sessions=@(); $warmHistory=@{}; $stateRefreshAt=[DateTimeOffset]::MinValue
    $selected = 0; $filter = ''; $notice = 'Ready. Cached usage is shown; press R or A for fresh checks.'; $mask = $true; $autoCompact = $false
    $compactAdjusting=$false; $compactDraft=[int]$warmSettings.AutoCompactThresholdPercent
    $interactive = -not $Snapshot -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    if (-not $interactive) { $notice = 'Cached snapshot. Run codex-auth in a terminal for live checks and actions.' }
    elseif($warmSettings.WarmupEnabled -and $warmSettings.WarmupSchedulingEnabled){
        try{if(Repair-DeckWarmupSchedule $SuiteRoot $warmSettings){$notice='Repaired the missing automatic warm-up schedule.'}}catch{$notice='Warm-up schedule repair failed: '+$_.Exception.Message}
    }
    $oldColor = [Console]::ForegroundColor; $oldBackground = [Console]::BackgroundColor
    $oldCursor = $true
    if ($interactive) { $oldCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
    try {
        do {
            $loopNow=[DateTimeOffset]::UtcNow
            if($loopNow -ge $stateRefreshAt){
                $warmSettings=Get-DeckSettings $root
                $warmHistory=@{}; foreach($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $root 'warmup.json')))){if($entry.Account){$warmHistory[$entry.Account]=$entry}}
                # Refresh disk-backed state at a human-scale cadence; worker
                # completion remains responsive without reparsing it twice a second.
                foreach($entry in (Get-DeckTerminalCache $root).Values){if(-not $cache[$entry.Account] -or (Get-DeckUsageCheckTicks $entry) -gt (Get-DeckUsageCheckTicks $cache[$entry.Account])){$cache[$entry.Account]=$entry}}
                $names = if (Get-Command Get-DeckEntryNames -ErrorAction SilentlyContinue) { @(Get-DeckEntryNames $SuiteRoot) } else { @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object Name) }
                foreach ($name in $names) {if (-not $profiles.ContainsKey($name)) { $profiles[$name] = Get-DeckProfile $SuiteRoot $name }}
                $sessions=@(Get-DeckSessions $root)
                $stateRefreshAt=$loopNow.AddSeconds(2)
            }
            $terminalCacheDirty=$false
            foreach ($name in @($tasks.Keys)) {
                $task = $tasks[$name]
                $timeout=($loopNow-$task.Started).TotalSeconds -ge 90
                if(-not $timeout -and -not (Test-DeckTaskReady $task)){continue}
                try {
                    if($timeout){Stop-DeckTask $task; throw 'Usage check timed out.'}
                    if ($task.Process.ExitCode -ne 0) { throw 'Usage check failed. Use codex-check for diagnostics.' }
                    $result = @(Expand-DeckTerminalRecords ($task.Out.Result | ConvertFrom-Json) | Where-Object Account -eq $name)
                    if ($result.Count -ne 1) { throw 'Usage check returned no matching account.' }
                    $result[0] | Add-Member NoteProperty CheckedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
                    $cache[$name] = $result[0]
                    $terminalCacheDirty=$true
                    $notice = "$name refreshed."
                } catch {
                    $notice = "$name : $($_.Exception.Message)"
                    if (-not $cache[$name]) { $cache[$name] = [pscustomobject]@{Account=$name;Status='error';Windows=@()} }
                    $cache[$name] | Add-Member NoteProperty Error 'Last refresh failed; displayed usage is cached.' -Force
                }
                finally { Stop-DeckTask $task; Dispose-DeckTask $task; [void]$tasks.Remove($name) }
            }
            if($terminalCacheDirty){$cache=Save-DeckUsageCache $root $cache 'terminal-cache.json'}
            while ($interactive -and $pending.Count -and $tasks.Count -lt 3) {
                $name = $pending.Dequeue()
                if ($tasks.ContainsKey($name) -or $name -notin $names -or $profiles[$name].PlanType -eq 'pool') { continue }
                try { $tasks[$name] = Start-DeckTask (Get-DeckCheckCode $SuiteRoot $name) 'check' $name }
                catch { $notice = "Could not start check for $name." }
            }
            $visible = @($names | Where-Object { -not $filter -or $_.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $selected = [Math]::Max(0,[Math]::Min($selected,$visible.Count - 1))
            $width = 110; $height = [Math]::Max(25,$visible.Count + 18)
            if ($interactive) { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight }
            $compactThreshold=if($compactAdjusting){$compactDraft}else{[int]$warmSettings.AutoCompactThresholdPercent}
            $frame = @(Get-DeckTerminalFrame $visible $cache $profiles $sessions $tasks $selected $width $height $filter $notice $mask $warmSettings $warmHistory $autoCompact $compactThreshold $compactAdjusting)
            if (-not $interactive) { $frame | ForEach-Object { Write-Output $_.Text }; return }
            $signature = "$width/$height/" + (($frame | ForEach-Object { $_.Text + $_.Color + $_.Background }) -join "`n")
            if ($signature -ne $lastFrame) {
            [Console]::SetCursorPosition(0,0)
            for ($line = 0; $line -lt $height - 1; $line++) {
                $text = ''; [Console]::ForegroundColor = 'Gray'; [Console]::BackgroundColor = 'Black'
                if ($line -lt $frame.Count) { $text = $frame[$line].Text; [Console]::ForegroundColor = $frame[$line].Color; [Console]::BackgroundColor = $frame[$line].Background }
                [Console]::Write($text.PadRight([Math]::Max(1,$width - 1)))
                if ($line -lt $height - 2) { [Console]::WriteLine() }
            }
            [Console]::ResetColor()
            $lastFrame = $signature
            }
            $until = [DateTimeOffset]::UtcNow.AddMilliseconds(500)
            while (-not [Console]::KeyAvailable -and [DateTimeOffset]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
            if (-not [Console]::KeyAvailable) { continue }
            $key = [Console]::ReadKey($true)
            $name = if ($visible.Count) { $visible[$selected] } else { $null }
            $action = $key.Key.ToString()
            if (-not [char]::IsControl($key.KeyChar)) { $action = ([string]$key.KeyChar).ToUpperInvariant() }
            elseif ([int]$key.KeyChar -in @(10,13)) { $action = 'Enter' }
            elseif ([int]$key.KeyChar -eq 27) { $action = 'Escape' }
            if($compactAdjusting){
                switch($action){
                    'UpArrow' {$compactDraft=[Math]::Min(90,$compactDraft+5)}
                    'DownArrow' {$compactDraft=[Math]::Max(30,$compactDraft-5)}
                    'Enter' {
                        $warmSettings.AutoCompactThresholdPercent=$compactDraft
                        Write-DeckJson (Join-Path $root 'settings.json') $warmSettings
                        $warmSettings=Get-DeckSettings $root
                        $compactAdjusting=$false
                        $notice="Auto-compact saved at $compactDraft% context remaining."
                    }
                    'Escape' {$compactAdjusting=$false; $notice='Auto-compact threshold unchanged.'}
                    'C' {}
                }
                continue
            }
            switch ($action) {
                'Q' { return }
                'Escape' { if ($filter) { $filter = ''; $selected = 0 } else { return } }
                'UpArrow' { $selected = [Math]::Max(0,$selected - 1) }
                'DownArrow' { $selected = [Math]::Min($visible.Count - 1,$selected + 1) }
                'Home' { $selected = 0 }
                'End' { $selected = [Math]::Max(0,$visible.Count - 1) }
                'PageUp' { $selected = [Math]::Max(0,$selected - [Math]::Max(1,$height - 18)) }
                'PageDown' { $selected = [Math]::Min($visible.Count - 1,$selected + [Math]::Max(1,$height - 18)) }
                'B' {
                    $choice = @(Get-DeckRecommendations $names $cache) | Select-Object -First 1
                    if ($choice) { $filter=''; $selected=[array]::IndexOf($names,$choice.Account); $notice=$choice.Account+': '+$choice.Reason }
                    else { $notice='No fresh usable account. Press A to refresh; unknown/exhausted accounts are excluded.' }
                }
                'H' {
                    [Console]::CursorVisible=$true
                    try { Show-DeckHistoryBrowser $SuiteRoot $AuthScript } catch { $notice=$_.Exception.Message }
                    finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                }
                'F2' {
                    if ($name) {
                        [Console]::CursorVisible=$true; Clear-Host
                        try {
                            if ($tasks.Count -or $pending.Count) { throw 'Wait for queued checks to finish before renaming.' }
                            $newName=Read-DeckTerminalInput ('Rename '+$name+' to (empty cancels)')
                            if ($newName) {
                                $notice=Rename-DeckAccount $SuiteRoot $name $newName
                                [void]$profiles.Remove($name); $cache=Get-DeckTerminalCache $root; $stateRefreshAt=[DateTimeOffset]::MinValue
                            }
                        } catch { $notice=$_.Exception.Message }
                        finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                    }
                }
                'M' { $mask = -not $mask }
                'C' {
                    if(Test-DeckTerminalKeyHold 0x43){
                        $compactDraft=[int]$warmSettings.AutoCompactThresholdPercent
                        $compactAdjusting=$true
                        $notice='Adjust the free-context threshold in 5% steps, then press Enter to save.'
                    }else{
                        $autoCompact = -not $autoCompact
                        $notice = if($autoCompact){'Auto-compact enabled for account and pool launches.'}else{'Auto-compact disabled.'}
                    }
                }
                'R' {
                    if($name -and $profiles[$name].PlanType -ne 'pool' -and (Test-Path -LiteralPath (Join-Path $accountRoot "$name/auth.json")) -and -not $tasks.ContainsKey($name) -and -not $pending.Contains($name)){$pending.Enqueue($name); $notice="Queued $name."}
                    elseif($name){$notice="$name is not signed in or cannot be checked."}
                }
                'A' {
                    $queued=0
                    foreach($item in $names){
                        if($profiles[$item].PlanType -eq 'pool' -or -not (Test-Path -LiteralPath (Join-Path $accountRoot "$item/auth.json"))){continue}
                        if(-not $tasks.ContainsKey($item) -and -not $pending.Contains($item)){$pending.Enqueue($item);$queued++}
                    }
                    $notice=if($queued){"Queued $queued signed-in accounts (three checks at a time)."}else{'No additional signed-in accounts to queue.'}
                }
                'U' {
                    try { Request-DeckWarmup $SuiteRoot $name; $notice='Warm-up queued in background for '+$name+'. Success requires an assistant reply.' } catch { $notice=$_.Exception.Message }
                }
                'T' {
                    [Console]::CursorVisible=$true; Clear-Host
                    try {
                        Write-Host ('Daily warm-up (local time): '+$warmSettings.WarmupTimes)
                        $times=Read-DeckTerminalInput 'Times HH:mm separated by commas; off disables; empty cancels'
                        if($times){
                            if($times -eq 'off'){$times=''}
                            $warmSettings=Set-DeckWarmupTimes $SuiteRoot $times
                            $notice='Daily warm-up: '+$(if($warmSettings.WarmupTimedEnabled){$warmSettings.WarmupTimes+' (local)'}else{'off'})+$(if($warmSettings.WarmupTimedEnabled -and -not $warmSettings.WarmupSchedulingEnabled){'; background scheduling is off in desktop Settings'}else{''})
                        }
                    } catch { $notice=$_.Exception.Message }
                    finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                }
                'W' {
                    try{$warmSettings=Set-DeckWarmupControl $root $name; if($warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}; $notice=if($warmSettings.WarmupSchedulingEnabled){'Warm-up selection saved. Background scheduling is enabled.'}else{'Warm-up selection saved. Enable background scheduling in desktop Settings for automatic runs.'}}catch{$notice=$_.Exception.Message}
                }
                'P' {
                    try{$warmSettings=Set-DeckWarmupControl $root -Pause; if($warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}; $notice='Warm-up '+$(if(-not $warmSettings.WarmupEnabled){'paused; in-flight requests may finish.'}elseif($warmSettings.WarmupSchedulingEnabled){'resumed with background scheduling.'}else{'resumed; background scheduling is off in desktop Settings.'})}catch{$notice=$_.Exception.Message}
                }
                'G' { Open-DeckGlobalRules $SuiteRoot; $notice='Global Rules editor opened.' }
                'I' { if($name){Open-DeckAccountInstructions $SuiteRoot $name;$notice="$name account instructions opened."} }
                'E' { if($name){Open-DeckMemories $SuiteRoot $name;$notice="$name memories editor opened."} }
                'K' { if($name){Open-DeckSkillsFolder $SuiteRoot $name;$notice="$name skills folder opened."} }
                'S' { Start-DeckCompanion $SuiteRoot -OpenSettings; $notice='Desktop Settings opened.' }
                'D' { Start-DeckCompanion $SuiteRoot; $notice = 'Desktop Deck opened; use its settings for scheduling and warm-up.' }
                default {
                    if ($key.KeyChar -eq '/') {
                        [Console]::CursorVisible = $true; Clear-Host
                        $filter = Read-DeckTerminalInput 'Find account (empty = all)'; $selected = 0
                        [Console]::CursorVisible = $false; Clear-Host; $lastFrame = ''
                    } elseif ($action -in @('Enter','L','N')) {
                        [Console]::CursorVisible = $true; Clear-Host
                        try {
                            if ($action -eq 'N') {
                                $name = Read-DeckTerminalInput 'New account name or number (empty cancels)'
                                if ($name -match '^\d+$') { $name = "account$name" }
                                if ($name -and ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$')) { throw 'Invalid account name.' }
                                if ($name -and (Test-Path -LiteralPath (Join-Path $accountRoot $name))) { throw 'That account already exists.' }
                            }
                            if ($name) {
                                [void][IO.Directory]::CreateDirectory($accountRoot)
                                $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$AuthScript,$name)
                                if ($action -eq 'Enter' -and $autoCompact) { $arguments += @('-AutoCompact',(([int]$warmSettings.AutoCompactThresholdPercent).ToString()+'%')) }
                                if ($action -in @('L','N')) { $arguments += 'login' }
                                & powershell.exe @arguments
                                $notice = "$name returned (exit $LASTEXITCODE)."
                                [void]$profiles.Remove($name); $stateRefreshAt=[DateTimeOffset]::MinValue
                            }
                        } catch { $notice = $_.Exception.Message }
                        finally { [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
                    }
                }
            }
        } while ($true)
    } finally {
        foreach ($task in $tasks.Values) { Stop-DeckTask $task; Dispose-DeckTask $task }
        if ($interactive) { [Console]::ForegroundColor = $oldColor; [Console]::BackgroundColor = $oldBackground; [Console]::CursorVisible = $oldCursor; Clear-Host }
    }
}

function Show-DeckPoolPicker([string]$SuiteRoot, [string]$Environment, [string[]]$Members) {
    $selected=0; $notice='Enter selects the starting account. R refreshes it; B selects best fresh quota; Q cancels.'
    $profiles=@{}; foreach ($name in $Members) { $profiles[$name]=Get-DeckProfile $SuiteRoot $name }
    while ($true) {
        $cache=Get-DeckTerminalCache (Join-Path $SuiteRoot 'deck')
        Clear-Host
        Write-Host ("POOL: $Environment | one environment, selectable account usage") -ForegroundColor Cyan
        $frame=Get-DeckTerminalFrame $Members $cache $profiles @() @{} $selected ([Console]::WindowWidth) ([Math]::Max(24,[Console]::WindowHeight-3)) '' $notice
        $frame | Select-Object -SkipLast 3 | ForEach-Object { Write-Host $_.Text -ForegroundColor $_.Color }
        Write-Host 'Up/Down select | Enter use account | R refresh | B best available | Q back'
        $key=[Console]::ReadKey($true)
        switch ($key.Key.ToString()) {
            'Escape' { return $null }
            'Q' { return $null }
            'UpArrow' { $selected=[Math]::Max(0,$selected-1) }
            'DownArrow' { $selected=[Math]::Min($Members.Count-1,$selected+1) }
            'Home' { $selected=0 }
            'End' { $selected=$Members.Count-1 }
            'Enter' {
                if ((Get-DeckTerminalHealth $cache[$Members[$selected]]) -eq 'Exhausted') { $notice='That account is exhausted. Refresh it or select another.' }
                else { return $Members[$selected] }
            }
            'B' {
                $best=@(Get-DeckRecommendations $Members $cache) | Select-Object -First 1
                if ($best) { $selected=[array]::IndexOf($Members,$best.Account); $notice=$best.Reason }
                else { $notice='No fresh available quota. Refresh an account with R.' }
            }
            'R' {
                $task=$null
                try {
                    $name=$Members[$selected]
                    $task=Start-DeckTask (Get-DeckCheckCode $SuiteRoot $name) 'check' $name
                    Write-Host 'Checking usage (Esc cancels)...'
                    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(90)
                    while (-not (Test-DeckTaskReady $task)) {
                        if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Usage check timed out.' }
                        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Escape') { throw 'Check cancelled.' }
                        Start-Sleep -Milliseconds 100
                    }
                    if ($task.Process.ExitCode -ne 0) { throw 'Usage check failed.' }
                    $row=@(Expand-DeckTerminalRecords ($task.Out.Result | ConvertFrom-Json) | Where-Object Account -eq $name)
                    if ($row.Count -ne 1) { throw 'No matching usage result.' }
                    $row[0] | Add-Member NoteProperty CheckedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
                    $cache[$name]=$row[0]
                    $cache=Save-DeckUsageCache (Join-Path $SuiteRoot 'deck') $cache 'terminal-cache.json'
                    $notice="$name refreshed."
                } catch { $notice=$_.Exception.Message }
                finally { if ($task) { Stop-DeckTask $task; Dispose-DeckTask $task } }
            }
        }
    }
}

function Show-DeckHistoryBrowser([string]$SuiteRoot, [string]$AuthScript, [string]$Filter = '') {
    if (-not [Console]::IsOutputRedirected) { Clear-Host; Write-Host 'Loading local session history...' -ForegroundColor Cyan }
    $rows=@(Get-DeckSessionHistory $SuiteRoot $Filter)
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $rows | Select-Object Account,Id,UpdatedAt,Folder,Provider
        return
    }
    $offset=0; $message='Search matches account, folder, provider or session ID. No conversation contents are read.'
    do {
        Clear-Host
        Write-Host 'CODEX DECK / SESSION HISTORY' -ForegroundColor Cyan
        Write-Host (ConvertTo-DeckTerminalText ('Filter: '+$Filter+' | '+$rows.Count+' sessions'))
        $size=[Math]::Max(1,[Console]::WindowHeight-9)
        for($i=$offset; $i -lt [Math]::Min($rows.Count,$offset+$size); $i++) {
            $row=$rows[$i]
            Write-Host (ConvertTo-DeckTerminalText ('{0,3}. {1} | {2} | {3} | {4}' -f ($i+1),$row.Account,$row.UpdatedAt.ToLocalTime().ToString('MMM dd HH:mm'),$row.Folder,$row.Id) ([Math]::Max(1,[Console]::WindowWidth-1)))
        }
        if(-not $rows.Count){Write-Host 'No local sessions match. Only supported rollout metadata is listed.'}
        Write-Host (ConvertTo-DeckTerminalText $message) -ForegroundColor Yellow
        $inputValue=Read-DeckTerminalInput 'Number resumes | N next | P previous | / search | R reload | Q back'
        switch($inputValue.ToUpperInvariant()) {
            'Q' { return }
            'N' { if($offset+$size -lt $rows.Count){$offset+=$size}; continue }
            'P' { $offset=[Math]::Max(0,$offset-$size); continue }
            '/' { $Filter=Read-DeckTerminalInput 'Search (empty = all)'; $rows=@(Get-DeckSessionHistory $SuiteRoot $Filter); $offset=0; continue }
            'R' { $rows=@(Get-DeckSessionHistory $SuiteRoot $Filter); $offset=0; continue }
        }
        $number=0
        if(-not [int]::TryParse($inputValue,[ref]$number) -or $number -lt 1 -or $number -gt $rows.Count){continue}
        $row=$rows[$number-1]
        # Re-read metadata to avoid launching a stale or replaced selection.
        $current=@(Get-DeckSessionHistory $SuiteRoot $row.Id | Where-Object { $_.Account -eq $row.Account -and $_.Id -eq $row.Id }) | Select-Object -First 1
        if(-not $current){$message='Session no longer exists. Reload the list.'; continue}
        if(-not $current.Folder -or -not (Test-Path -LiteralPath $current.Folder -PathType Container)){$message='Original working folder is unavailable; restore it before resuming.'; continue}
        Push-Location -LiteralPath $current.Folder
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AuthScript $current.Account resume $current.Id
            $message='Session returned (exit '+$LASTEXITCODE+').'
        } finally { Pop-Location }
    } while($true)
}
