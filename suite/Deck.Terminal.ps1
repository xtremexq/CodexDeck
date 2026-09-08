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
function Get-DeckTerminalHealth($Record) {
    if (-not $Record) { return 'Not checked' }
    if ($Record.Error -or $Record.Status -eq 'error') { return 'Check failed' }
    if (@($Record.Windows | Where-Object { $_.ResetsAtUnix -and [long]$_.ResetsAtUnix -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }).Count) { return 'Reset passed' }
    if (@($Record.Windows | Where-Object { $_.Dead -or ($null -ne $_.RemainingPct -and $_.RemainingPct -le 0) }).Count) { return 'Exhausted' }
    if ($Record.Status -ne 'available') { return 'Unavailable' }
    return 'Ready'
}
function Get-DeckTerminalFrame($Names, $Cache, $Profiles, $Sessions, $Tasks, [int]$Selected, [int]$Width, [int]$Height, [string]$Filter, [string]$Notice, [bool]$Mask = $true) {
    $lines = [Collections.Generic.List[object]]::new()
    function Add-Line([string]$Text, [string]$Color = 'Gray', [string]$Background = 'Black') {
        $lines.Add(@{ Text = (ConvertTo-DeckTerminalText $Text ([Math]::Max(1,$Width - 1))); Color = $Color; Background = $Background })
    }
    Add-Line '  CODEX / DECK                                      ACCOUNT CONTROL' 'Cyan'
    Add-Line ('  {0} accounts   /   {1} connected sessions   /   {2} checking' -f $Names.Count, @($Sessions).Count, $Tasks.Count) 'DarkGray'
    Add-Line '  Usage remaining  |  cached instantly, fresh checks in background' 'DarkGray'
    Add-Line ('  Filter: {0}' -f $(if ($Filter) { $Filter } else { 'all accounts  (/ to search)' })) 'Cyan'
    Add-Line ('  {0,-18} {1,-9} {2,-18} {3,-18} {4}' -f 'ACCOUNT','PLAN','PRIMARY','WEEKLY','STATE') 'DarkGray'
    $pageSize = [Math]::Max(1, $Height - 15)
    $start = [int]([Math]::Floor($Selected / $pageSize) * $pageSize)
    for ($i = $start; $i -lt [Math]::Min($Names.Count, $start + $pageSize); $i++) {
        $name = $Names[$i]; $row = $Cache[$name]; $profile = $Profiles[$name]
        $five = $row.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
        if (-not $five) { $five = $row.Windows | Where-Object DurationSeconds -ne 604800 | Select-Object -First 1 }
        $week = $row.Windows | Where-Object DurationSeconds -eq 604800 | Select-Object -First 1
        $state = Get-DeckTerminalHealth $row
        if ($Tasks.ContainsKey($name)) { $state = 'Checking...' }
        $marker = if ($i -eq $Selected) { '>' } else { ' ' }
        $color = if ($state -eq 'Ready') { 'Green' } elseif ($state -in @('Check failed','Exhausted')) { 'Yellow' } else { 'Gray' }
        $bg = if ($i -eq $Selected) { 'DarkBlue' } else { 'Black' }
        Add-Line ('{0} {1,-18} {2,-9} {3,-18} {4,-18} {5}' -f $marker,(ConvertTo-DeckTerminalText $name 18),(ConvertTo-DeckTerminalText $profile.PlanType 9),(Format-DeckTerminalQuota $five),(Format-DeckTerminalQuota $week),$state) $color $bg
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
        Add-Line ('  Window resets (primary = 5H or plan window): ' + ($resets -join '  /  ')) 'DarkGray'
        $connected = @($Sessions | Where-Object Account -eq $name)
        Add-Line ('  Sessions: ' + (($connected | ForEach-Object { '{0} @ {1}' -f $_.ProcessId,$_.Folder }) -join ' | ')) 'DarkGray'
    }
    Add-Line ('  ' + $Notice) 'Yellow'
    Add-Line '  Up/Down select  Enter launch  R refresh  A refresh all  / search' 'Cyan'
    Add-Line '  L login  N new account  D desktop Deck  M mask email  Q quit' 'Cyan'
    return $lines.ToArray()
}
function Read-DeckTerminalInput([string]$Prompt) {
    [Console]::Write($Prompt + ': ')
    $value = ''
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape') { return '' }
        if ($key.Key -eq 'Enter') { [Console]::WriteLine(); return $value }
        if ($key.Key -eq 'Backspace' -and $value.Length) {
            $value = $value.Substring(0,$value.Length - 1)
            [Console]::Write("`b `b")
        } elseif (-not [char]::IsControl($key.KeyChar) -and $value.Length -lt 40) {
            $value += $key.KeyChar; [Console]::Write($key.KeyChar)
        }
    }
}
function Show-DeckTerminal {
    param([string]$SuiteRoot, [string]$AuthScript, [switch]$Snapshot)
    . (Join-Path $SuiteRoot 'Deck.Core.ps1')
    $root = Join-Path $SuiteRoot 'deck'
    $accountRoot = Join-Path $SuiteRoot 'accounts'
    $cache = Get-DeckTerminalCache $root
    $profiles = @{}; $tasks = @{}; $attempted = @{}; $pending = [Collections.Generic.Queue[string]]::new()
    $selected = 0; $filter = ''; $notice = 'Ready. Fresh checks start automatically for missing or stale usage.'; $mask = $true
    $interactive = -not $Snapshot -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    if (-not $interactive) { $notice = 'Cached snapshot. Run codex-auth in a terminal for live checks and actions.' }
    $oldColor = [Console]::ForegroundColor; $oldBackground = [Console]::BackgroundColor
    $oldCursor = $true
    if ($interactive) { $oldCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
    try {
        do {
            $names = @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' } | Sort-Object @{Expression={ if ($_.Name -match '^account(\d+)$') { [int]$Matches[1] } else { [int]::MaxValue } }},Name | ForEach-Object Name)
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
                if ($tasks.ContainsKey($name) -or $name -notin $names) { continue }
                try { $tasks[$name] = Start-DeckTask (Get-DeckCheckCode $SuiteRoot $name) 'check' $name }
                catch { $notice = "Could not start check for $name." }
            }
            $visible = @($names | Where-Object { -not $filter -or $_.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $selected = [Math]::Max(0,[Math]::Min($selected,$visible.Count - 1))
            $sessions = @(Get-DeckSessions $root)
            $width = 110; $height = [Math]::Max(25,$visible.Count + 15)
            if ($interactive) { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight }
            $frame = @(Get-DeckTerminalFrame $visible $cache $profiles $sessions $tasks $selected $width $height $filter $notice $mask)
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
            switch ($key.Key) {
                'Q' { return }
                'Escape' { if ($filter) { $filter = ''; $selected = 0 } else { return } }
                'UpArrow' { $selected = [Math]::Max(0,$selected - 1) }
                'DownArrow' { $selected = [Math]::Min($visible.Count - 1,$selected + 1) }
                'Home' { $selected = 0 }
                'End' { $selected = [Math]::Max(0,$visible.Count - 1) }
                'PageUp' { $selected = [Math]::Max(0,$selected - [Math]::Max(1,$height - 15)) }
                'PageDown' { $selected = [Math]::Min($visible.Count - 1,$selected + [Math]::Max(1,$height - 15)) }
                'M' { $mask = -not $mask }
                'R' { if ($name -and -not $tasks.ContainsKey($name) -and -not $pending.Contains($name)) { $pending.Enqueue($name); $notice = "Queued $name." } }
                'A' { foreach ($item in $names) { if (-not $tasks.ContainsKey($item) -and -not $pending.Contains($item)) { $pending.Enqueue($item) } }; $notice = 'All accounts queued (three checks at a time).' }
                'D' { Start-DeckCompanion $SuiteRoot; $notice = 'Desktop Deck opened; use its settings for scheduling and warm-up.' }
                default {
                    if ($key.KeyChar -eq '/') {
                        [Console]::CursorVisible = $true; Clear-Host
                        $filter = Read-DeckTerminalInput 'Find account (empty = all)'; $selected = 0
                        [Console]::CursorVisible = $false; Clear-Host; $lastFrame = ''
                    } elseif ($key.Key -in @('Enter','L','N')) {
                        [Console]::CursorVisible = $true; Clear-Host
                        try {
                            if ($key.Key -eq 'N') {
                                $name = Read-DeckTerminalInput 'New account name or number (empty cancels)'
                                if ($name -match '^\d+$') { $name = "account$name" }
                                if ($name -and ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$')) { throw 'Invalid account name.' }
                                if ($name -and (Test-Path -LiteralPath (Join-Path $accountRoot $name))) { throw 'That account already exists.' }
                            }
                            if ($name) {
                                [void][IO.Directory]::CreateDirectory($accountRoot)
                                $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$AuthScript,$name)
                                if ($key.Key -in @('L','N')) { $arguments += 'login' }
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
