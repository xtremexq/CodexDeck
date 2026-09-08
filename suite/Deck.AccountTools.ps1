# Shared account recommendations, local history and account maintenance.
function Get-DeckRecommendations($Names, $Cache, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
    $ranked = foreach ($name in $Names) {
        $row = $Cache[$name]
        if (-not $row -or $row.Error -or $row.Status -ne 'available') { continue }
        try {
            $age = ($Now - [DateTimeOffset]$row.CheckedAt).TotalSeconds
            if (-not $row.CheckedAt -or $age -lt -60 -or $age -gt 300) { continue }
            $windows = @($row.Windows)
            if (-not $windows.Count) { continue }
            $invalid = @($windows | Where-Object {
                $null -eq $_.RemainingPct -or [double]$_.RemainingPct -le 0 -or
                [double]$_.RemainingPct -gt 100 -or $_.Dead -or
                ($_.ResetsAtUnix -and [long]$_.ResetsAtUnix -le $Now.ToUnixTimeSeconds())
            })
            if ($invalid.Count) { continue }
            $floor = ($windows | ForEach-Object { [double]$_.RemainingPct } | Measure-Object -Minimum).Minimum
            $average = ($windows | ForEach-Object { [double]$_.RemainingPct } | Measure-Object -Average).Average
            $reset = ($windows | Where-Object { $_.ResetsAtUnix } | ForEach-Object { [long]$_.ResetsAtUnix } | Measure-Object -Minimum).Minimum
            if (-not $reset) { $reset = [long]::MaxValue }
            [pscustomobject]@{ Account=$name; Score=$floor; Average=$average; Reset=$reset
                Reason=('Lowest remaining window: {0:0.#}%; checked {1:0}s ago. Ties use average quota, then earliest reset.' -f $floor,$age) }
        } catch { continue }
    }
    $ranked | Sort-Object @{Expression='Score';Descending=$true},@{Expression='Average';Descending=$true},Reset,Account
}

function Get-DeckHistoryFiles([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $rootItem = Get-Item -LiteralPath $Directory
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) { Get-DeckHistoryFiles $item.FullName }
        elseif ($item.Name -like 'rollout-*.jsonl') { $item }
    }
}
function Get-DeckSessionHistory([string]$SuiteRoot, [string]$Filter = '') {
    # Compile the bounded scan: a PowerShell loop per character stalls on large histories.
    if (-not ('DeckSessionHeader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class DeckSessionHeader {
    public static string Read(string path) {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(stream)) {
            var line = new StringBuilder();
            for (int i = 0; i < 1048576; i++) {
                int c = reader.Read();
                if (c < 0 || c == 10) return line.ToString();
                line.Append((char)c);
            }
            return null;
        }
    }
}
'@
    }
    $accounts = Join-Path $SuiteRoot 'accounts'
    if (-not (Test-Path -LiteralPath $accounts)) { return }
    if ((Get-Item -LiteralPath $accounts).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    $seen = @{}
    $rows = foreach ($account in Get-ChildItem -LiteralPath $accounts -Directory) {
        if ($account.Name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or ($account.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        foreach ($file in Get-DeckHistoryFiles (Join-Path $account.FullName 'sessions')) {
            $reader = $null
            try {
                $header = [DeckSessionHeader]::Read($file.FullName)
                if (-not $header) { continue }
                $entry = $header | ConvertFrom-Json
                $meta = $entry.payload
                if ($entry.type -ne 'session_meta' -or $meta.id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { continue }
                $identity = $account.Name+'/'+$meta.id
                if ($seen[$identity]) { continue }; $seen[$identity] = $true
                $row = [pscustomobject]@{Account=$account.Name; Id=[string]$meta.id; Folder=[string]$meta.cwd
                    Provider=[string]$meta.model_provider; UpdatedAt=$file.LastWriteTimeUtc; Path=$file.FullName}
                if (-not $Filter -or ($row.Account+' '+$row.Id+' '+$row.Folder+' '+$row.Provider).IndexOf($Filter,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $row }
            } catch { } finally { if ($reader) { $reader.Dispose() } }
        }
    }
    $rows | Sort-Object UpdatedAt -Descending
}

function Format-DeckResetCredits($Record, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
    $credits = $Record.ResetCredits
    if (-not $credits -or $credits.Status -ne 'available') { return 'Not reported' }
    $active = @($credits.Items | Where-Object {
        $_.Status -eq 'available' -and ($null -eq $_.ExpiresAtUnix -or [long]$_.ExpiresAtUnix -gt $Now.ToUnixTimeSeconds())
    })
    $next = $active | Where-Object { $null -ne $_.ExpiresAtUnix } | Sort-Object ExpiresAtUnix | Select-Object -First 1
    $text = '{0} available' -f $active.Count
    if ($next) { $text += ' / next expires '+[DateTimeOffset]::FromUnixTimeSeconds([long]$next.ExpiresAtUnix).ToLocalTime().ToString('MMM dd yyyy HH:mm') }
    elseif ($active.Count) { $text += ' / expiry not reported' }
    if ($credits.CheckedAt) {
        try { if (($Now-[DateTimeOffset]$credits.CheckedAt).TotalMinutes -gt 5) { $text += ' (cached; refresh)' } } catch { $text += ' (refresh needed)' }
    }
    return $text
}

function Get-DeckMaintenanceMutexName {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return "Local\CodexDeck-$sid"
}

function Rename-DeckAccount([string]$SuiteRoot, [string]$OldName, [string]$NewName) {
    foreach ($name in @($OldName,$NewName)) {
        if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$') { throw 'Use 1-40 letters, numbers, underscores or hyphens, starting with a letter; reserved device names are not allowed.' }
    }
    if ($OldName -eq $NewName) { throw 'Choose a different name (case-only renames are not supported).' }
    $created = $false
    $guard = [Threading.Mutex]::new($true,(Get-DeckMaintenanceMutexName),[ref]$created)
    try {
        if (-not $created) { throw 'Quit desktop Deck and its tray scheduler before renaming, so saved state cannot be overwritten.' }
        $accounts = Get-Item -LiteralPath (Join-Path $SuiteRoot 'accounts')
        $old = Get-Item -LiteralPath (Join-Path $accounts.FullName $OldName)
        $target = [IO.Path]::GetFullPath((Join-Path $accounts.FullName $NewName))
        if (($accounts.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $old.PSIsContainer -or $old.Parent.FullName -ne $accounts.FullName -or [IO.Path]::GetDirectoryName($target) -ne $accounts.FullName) { throw 'Account paths must be real directories inside the accounts root.' }
        if (Test-Path -LiteralPath $target) { throw 'That account name already exists.' }
        $deck = Join-Path $SuiteRoot 'deck'
        if (@(Get-DeckSessions $deck | Where-Object Account -eq $OldName).Count -or
            ($env:CODEX_HOME -and [IO.Path]::GetFullPath($env:CODEX_HOME).TrimEnd('\') -eq $old.FullName)) { throw 'Close this account''s connected terminals before renaming.' }
        $changes = @(); $originals = @{}
        foreach ($file in 'settings.json','pins.json','warmup.json','cache.json','terminal-cache.json') {
            $path = Join-Path $deck $file
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing linked state files.' }
            $originals[$path] = [IO.File]::ReadAllBytes($path)
            $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
            if ($file -eq 'settings.json') {
                if ($value.PSObject.Properties['FailoverAccounts']) { $value.FailoverAccounts = (@($value.FailoverAccounts -split ',' | ForEach-Object { if ($_.Trim() -eq $OldName) { $NewName } else { $_.Trim() } }) -join ',') }
                if ($value.PSObject.Properties['WarmupAccounts']) { $value.WarmupAccounts = (@($value.WarmupAccounts -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { if ($_ -eq $OldName) { $NewName } else { $_ } }) -join ',') }
            } elseif ($file -eq 'pins.json') {
                $value = @($value | ForEach-Object { if ($_ -eq $OldName) { $NewName } else { $_ } })
            } else {
                $value = @(Expand-DeckCheckRecords $value)
                foreach ($row in $value) { if ($row.Account -eq $OldName) { $row.Account = $NewName } }
            }
            $changes += @{Path=$path;Value=$value}
        }
        # Both absolute move targets were checked above. Roll back state and directory on failure.
        Move-Item -LiteralPath $old.FullName -Destination $target -ErrorAction Stop
        try { foreach ($change in $changes) { Write-DeckJson $change.Path $change.Value } }
        catch {
            foreach ($path in $originals.Keys) { [IO.File]::WriteAllBytes($path,$originals[$path]) }
            Move-Item -LiteralPath $target -Destination $old.FullName -ErrorAction Stop
            throw
        }
        return "Renamed $OldName to $NewName. Pins, warm-up selection and cached records updated."
    } finally { if ($created) { $guard.ReleaseMutex() }; $guard.Dispose() }
}
