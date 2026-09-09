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
    $cache = @{}
    foreach ($file in 'cache.json','terminal-cache.json') {
        foreach ($row in @(Expand-DeckTerminalRecords (Read-DeckJson (Join-Path $Root $file)))) {
            $old = $cache[$row.Account]
            if (-not $old -or [string]$row.CheckedAt -gt [string]$old.CheckedAt) { $cache[$row.Account] = $row }
        }
    }
    return $cache
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
function Get-DeckTerminalHealth($Record) {
    if (-not $Record) { return 'Not checked' }
    if ($Record.Error -or $Record.Status -eq 'error') { return 'Check failed' }
    if (@($Record.Windows | Where-Object { $_.ResetsAtUnix -and [long]$_.ResetsAtUnix -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }).Count) { return 'Reset passed' }
    if (@($Record.Windows | Where-Object { $_.Dead -or ($null -ne $_.RemainingPct -and $_.RemainingPct -le 0) }).Count) { return 'Exhausted' }
    if ($Record.Status -ne 'available') { return 'Unavailable' }
    return 'Ready'
}
function Get-DeckTerminalFrame($Names, $Cache, $Profiles, $Sessions, $Tasks, [int]$Selected, [int]$Width, [int]$Height, [string]$Filter, [string]$Notice, [bool]$Mask = $true, $WarmupSettings = $null, $WarmupHistory = @{}) {
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
        Add-Line ('{0} {1,-18} {2,-9} {3,-18} {4,-18} {5,-14} {6}' -f $marker,(ConvertTo-DeckTerminalText $name 18),(ConvertTo-DeckTerminalText $profile.PlanType 9),(Format-DeckTerminalQuota $five),(Format-DeckTerminalQuota $week),(ConvertTo-DeckTerminalText $state 14),(Format-DeckTerminalReset $five)) $color $bg
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
        Add-Line ('  AUTO WARM-UP: '+$(if($WarmupSettings.WarmupEnabled){'ON'}else{'PAUSED'})+' | '+$warmState) 'Yellow'
    }
    Add-Line '  WARMUP   U run now  T daily times  W select account  P pause/resume' 'DarkMagenta'
    Add-Line ('  ' + $Notice) 'Yellow'
    Add-Line '  NAVIGATE Up/Down select  Enter launch  / search  B best  Q quit' 'Gray'
    Add-Line '  MANAGE   R refresh  A all  H history  F2 rename  L login  N new' 'DarkGray'
    Add-Line '  DISPLAY  D desktop Deck  S settings  G global rules  M mask email' 'DarkGray'
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
function Show-DeckTerminal {
    param([string]$SuiteRoot, [string]$AuthScript, [switch]$Snapshot)
    . (Join-Path $SuiteRoot 'Deck.Core.ps1')
    $root = Join-Path $SuiteRoot 'deck'
    $accountRoot = Join-Path $SuiteRoot 'accounts'
    $warmSettings=Get-DeckSettings $root
    $cache = Get-DeckTerminalCache $root
    $profiles = @{}; $tasks = @{}; $attempted = @{}; $pending = [Collections.Generic.Queue[string]]::new()
    $selected = 0; $filter = ''; $notice = 'Ready. Fresh checks start automatically for missing or stale usage.'; $mask = $true
    $interactive = -not $Snapshot -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    if (-not $interactive) { $notice = 'Cached snapshot. Run codex-auth in a terminal for live checks and actions.' }
    if($interactive -and $warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}
    $oldColor = [Console]::ForegroundColor; $oldBackground = [Console]::BackgroundColor
    $oldCursor = $true
    if ($interactive) { $oldCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
    try {
        do {
            $warmSettings=Get-DeckSettings $root
            $warmHistory=@{}; foreach($entry in @(Read-DeckJson (Join-Path $root 'warmup.json'))){if($entry.Account){$warmHistory[$entry.Account]=$entry}}
            # Merge fresh scheduler results without starting a second warm-up executor.
            foreach($entry in (Get-DeckTerminalCache $root).Values){if(-not $cache[$entry.Account] -or [string]$entry.CheckedAt -gt [string]$cache[$entry.Account].CheckedAt){$cache[$entry.Account]=$entry}}
            $names = if (Get-Command Get-DeckEntryNames -ErrorAction SilentlyContinue) { @(Get-DeckEntryNames $SuiteRoot) } else { @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object Name) }
            foreach ($name in $names) {
                if (-not $profiles.ContainsKey($name)) { $profiles[$name] = Get-DeckProfile $SuiteRoot $name }
                if ($interactive -and -not $attempted.ContainsKey($name)) {
                    $attempted[$name] = $true
                    $fresh = $false
                    try { $fresh = $cache[$name].CheckedAt -and ([DateTimeOffset]::UtcNow - [DateTimeOffset]$cache[$name].CheckedAt).TotalMinutes -lt 5 } catch {}
                    if (-not $fresh -and (Test-Path -LiteralPath (Join-Path $accountRoot "$name/auth.json"))) { $pending.Enqueue($name) }
                }
            }
            foreach ($name in @($tasks.Keys)) {
                $task = $tasks[$name]
                if (-not $task.Process.HasExited -and ([DateTimeOffset]::UtcNow - $task.Started).TotalSeconds -lt 90) { continue }
                try {
                    if (-not $task.Process.HasExited) { throw 'Usage check timed out.' }
                    if ($task.Process.ExitCode -ne 0) { throw 'Usage check failed. Use codex-check for diagnostics.' }
                    $result = @(Expand-DeckTerminalRecords ($task.Out.Result | ConvertFrom-Json) | Where-Object Account -eq $name)
                    if ($result.Count -ne 1) { throw 'Usage check returned no matching account.' }
                    $result[0] | Add-Member NoteProperty CheckedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
                    $cache[$name] = $result[0]
                    # Separate from Deck's writer; merge both caches when reading.
                    $saved = Get-DeckTerminalCache $root
                    $saved[$name] = $result[0]
                    Write-DeckJson (Join-Path $root 'terminal-cache.json') @($saved.Values)
                    $notice = "$name refreshed."
                } catch {
                    $notice = "$name : $($_.Exception.Message)"
                    if (-not $cache[$name]) { $cache[$name] = [pscustomobject]@{Account=$name;Status='error';Windows=@()} }
                    $cache[$name] | Add-Member NoteProperty Error 'Last refresh failed; displayed usage is cached.' -Force
                }
                finally { Stop-DeckTask $task; $task.Process.Dispose(); $tasks.Remove($name) }
            }
            while ($interactive -and $pending.Count -and $tasks.Count -lt 3) {
                $name = $pending.Dequeue()
                if ($tasks.ContainsKey($name) -or $name -notin $names -or $profiles[$name].PlanType -eq 'pool') { continue }
                try { $tasks[$name] = Start-DeckTask (Get-DeckCheckCode $SuiteRoot $name) 'check' $name }
                catch { $notice = "Could not start check for $name." }
            }
            $visible = @($names | Where-Object { -not $filter -or $_.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $selected = [Math]::Max(0,[Math]::Min($selected,$visible.Count - 1))
            $sessions = @(Get-DeckSessions $root)
            $width = 110; $height = [Math]::Max(25,$visible.Count + 18)
            if ($interactive) { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight }
            $frame = @(Get-DeckTerminalFrame $visible $cache $profiles $sessions $tasks $selected $width $height $filter $notice $mask $warmSettings $warmHistory)
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
                                $profiles.Remove($name); $cache=Get-DeckTerminalCache $root; $attempted.Remove($name)
                            }
                        } catch { $notice=$_.Exception.Message }
                        finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                    }
                }
                'M' { $mask = -not $mask }
                'R' { if ($name -and -not $tasks.ContainsKey($name) -and -not $pending.Contains($name)) { $pending.Enqueue($name); $notice = "Queued $name." } }
                'A' { foreach ($item in $names) { if (-not $tasks.ContainsKey($item) -and -not $pending.Contains($item)) { $pending.Enqueue($item) } }; $notice = 'All accounts queued (three checks at a time).' }
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
                            $notice='Daily warm-up: '+$(if($warmSettings.WarmupTimedEnabled){$warmSettings.WarmupTimes+' (local)'}else{'off'})
                        }
                    } catch { $notice=$_.Exception.Message }
                    finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                }
                'W' {
                    try{$warmSettings=Set-DeckWarmupControl $root $name; if($warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}; $notice='Warm-up selection saved. The tray scheduler continues after this dashboard closes.'}catch{$notice=$_.Exception.Message}
                }
                'P' {
                    try{$warmSettings=Set-DeckWarmupControl $root -Pause; if($warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}; $notice='Warm-up '+$(if($warmSettings.WarmupEnabled){'resumed in tray.'}else{'paused; in-flight requests may finish.'})}catch{$notice=$_.Exception.Message}
                }
                'G' { Open-DeckGlobalRules $SuiteRoot; $notice='Global Rules editor opened.' }
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
                                if ($action -in @('L','N')) { $arguments += 'login' }
                                & powershell.exe @arguments
                                $notice = "$name returned (exit $LASTEXITCODE)."
                                $profiles.Remove($name); $attempted.Remove($name)
                                if (-not $pending.Contains($name)) { $pending.Enqueue($name) }
                            }
                        } catch { $notice = $_.Exception.Message }
                        finally { [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
                    }
                }
            }
        } while ($true)
    } finally {
        foreach ($task in $tasks.Values) { Stop-DeckTask $task; $task.Process.Dispose() }
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
                    while (-not $task.Process.HasExited) {
                        if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Usage check timed out.' }
                        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Escape') { throw 'Check cancelled.' }
                        Start-Sleep -Milliseconds 100
                    }
                    if ($task.Process.ExitCode -ne 0) { throw 'Usage check failed.' }
                    $row=@(Expand-DeckTerminalRecords ($task.Out.Result | ConvertFrom-Json) | Where-Object Account -eq $name)
                    if ($row.Count -ne 1) { throw 'No matching usage result.' }
                    $row[0] | Add-Member NoteProperty CheckedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
                    $cache[$name]=$row[0]
                    Write-DeckJson (Join-Path $SuiteRoot 'deck/terminal-cache.json') @($cache.Values)
                    $notice="$name refreshed."
                } catch { $notice=$_.Exception.Message }
                finally { if ($task) { Stop-DeckTask $task; $task.Process.Dispose() } }
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
