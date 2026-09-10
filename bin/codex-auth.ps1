[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Account,

    [switch]$NewAccount,
    [string]$InheritFrom,
    [switch]$Pool,
    [string[]]$PoolAccounts,
    [ValidateSet('Ordered','Best')][string]$PoolMode = 'Ordered',
    [string]$UseAccount,
    [string]$Source,
    [string[]]$Targets,
    [string[]]$Resources,
    [switch]$Best,
    [switch]$History,
    [switch]$GlobalRules,
    [string]$RenameTo,
    [ValidateSet('Off','Ordered','Best')]
    [string]$Failover = 'Off',
    [string[]]$FailoverAccounts,

    [Alias('Delete')]
    [switch]$Del,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CodexArgs
)

$accountsRoot = Join-Path $HOME ".codex-loop\accounts"
$defaultConfigPath = Join-Path $HOME ".codex\config.toml"
$ErrorActionPreference = 'Stop'
if($GlobalRules){
    $rulesSuite=Split-Path -Parent $accountsRoot
    . (Join-Path $rulesSuite 'Deck.GlobalRules.ps1')
    Open-DeckGlobalRules $rulesSuite
    exit 0
}

function Remove-CodexAccount {
    param([string]$Name)
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
    $deckCore = Join-Path (Split-Path $root -Parent) 'Deck.Core.ps1'
    if (Test-Path -LiteralPath $deckCore) {
        . $deckCore
        if (@(Get-DeckSessions (Join-Path (Split-Path $root -Parent) 'deck') | Where-Object Account -eq $Name).Count) {
            throw 'This account has a connected terminal. Close its Codex sessions before deleting it.'
        }
    }
    if (Get-Command Assert-DeckEntryUnreferenced -ErrorAction SilentlyContinue) { Assert-DeckEntryUnreferenced (Split-Path -Parent $accountsRoot) $Name }
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
    Write-Host "Removed $Name from codex-auth. Recoverable at: $destination"
}

function Get-AccountDirectories {
    if (-not (Test-Path -LiteralPath $accountsRoot -PathType Container)) {
        return @()
    }

    return @(Get-DeckEntryNames (Split-Path -Parent $accountsRoot) | ForEach-Object { Get-Item -LiteralPath (Join-Path $accountsRoot $_) })
}

function Normalize-AccountName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Name -match '^\d+$') {
        return "account$Name"
    }

    return $Name
}

function Normalize-Newlines {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return ($Text -replace "`r`n", "`n" -replace "`r", "`n")
}

function Trim-TrailingNewlines {
    param([AllowNull()][string]$Text)

    return (Normalize-Newlines $Text).TrimEnd([char[]]"`n")
}

function Read-TextFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path

    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-TableBlock {
    param(
        [string]$Config,
        [string]$Header
    )

    $normalized = Normalize-Newlines $Config

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $escapedHeader = [regex]::Escape($Header)
    $match = [regex]::Match($normalized, "(?ms)^$escapedHeader\s*\n.*?(?=^\[|\z)")

    if ($match.Success) {
        return (Trim-TrailingNewlines $match.Value)
    }

    return $null
}

function Get-SettingLine {
    param(
        [string]$Config,
        [string]$Key
    )

    $normalized = Normalize-Newlines $Config

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $pattern = "(?m)^" + [regex]::Escape($Key) + "\s*=.*$"
    $match = [regex]::Match($normalized, $pattern)

    if ($match.Success) {
        return $match.Value.Trim()
    }

    return $null
}

function Upsert-KeyValueLine {
    param(
        [string]$Text,
        [string]$Key,
        [string]$ValueLine
    )

    $normalized = Normalize-Newlines $Text
    $pattern = "(?m)^" + [regex]::Escape($Key) + "\s*=.*$"

    if ([regex]::IsMatch($normalized, $pattern)) {
        return [regex]::Replace($normalized, $pattern, $ValueLine, 1)
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "$ValueLine`n"
    }

    return "$(Trim-TrailingNewlines $normalized)`n$ValueLine`n"
}

function Upsert-TopLevelSetting {
    param(
        [string]$Config,
        [string]$Key,
        [string]$ValueLine
    )

    $normalized = Normalize-Newlines $Config
    $pattern = "(?m)^" + [regex]::Escape($Key) + "\s*=.*$"

    if ([regex]::IsMatch($normalized, $pattern)) {
        return [regex]::Replace($normalized, $pattern, $ValueLine, 1)
    }

    $tableMatch = [regex]::Match($normalized, "(?m)^\[")

    if ($tableMatch.Success) {
        return $normalized.Insert($tableMatch.Index, "$ValueLine`n")
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "$ValueLine`n"
    }

    return "$(Trim-TrailingNewlines $normalized)`n$ValueLine`n"
}

function Upsert-TableBlock {
    param(
        [string]$Config,
        [string]$Header,
        [string]$Block
    )

    $normalized = Normalize-Newlines $Config
    $replacement = "$(Trim-TrailingNewlines $Block)`n"
    $escapedHeader = [regex]::Escape($Header)
    $pattern = "(?ms)^$escapedHeader\s*\n.*?(?=^\[|\z)"

    if ([regex]::IsMatch($normalized, $pattern)) {
        return [regex]::Replace($normalized, $pattern, $replacement, 1)
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $replacement
    }

    return "$(Trim-TrailingNewlines $normalized)`n`n$replacement"
}

function Upsert-TableSetting {
    param(
        [string]$Config,
        [string]$Header,
        [string]$Key,
        [string]$ValueLine
    )

    $normalized = Normalize-Newlines $Config

    if ([string]::IsNullOrWhiteSpace($ValueLine)) {
        return $normalized
    }

    $block = Get-TableBlock -Config $normalized -Header $Header

    if (-not $block) {
        return Upsert-TableBlock -Config $normalized -Header $Header -Block "$Header`n$ValueLine"
    }

    $parts = (Normalize-Newlines $block) -split "`n", 2
    $body = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    $updatedBody = Upsert-KeyValueLine -Text $body -Key $Key -ValueLine $ValueLine

    if ([string]::IsNullOrWhiteSpace($updatedBody)) {
        return Upsert-TableBlock -Config $normalized -Header $Header -Block $Header
    }

    return Upsert-TableBlock `
        -Config $normalized `
        -Header $Header `
        -Block "$Header`n$(Trim-TrailingNewlines $updatedBody)"
}

function Add-MissingProjectBlocks {
    param(
        [string]$Config,
        [string]$DefaultConfig
    )

    $normalized = Normalize-Newlines $Config
    $defaultNormalized = Normalize-Newlines $DefaultConfig
    $defaultProjectBlocks = [regex]::Matches(
        $defaultNormalized,
        "(?ms)^\[projects\.[^\n]+\]\s*\n.*?(?=^\[|\z)"
    )

    if ($defaultProjectBlocks.Count -eq 0) {
        return $normalized
    }

    $knownHeaders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($headerMatch in [regex]::Matches($normalized, "(?m)^\[projects\.[^\n]+\]")) {
        [void]$knownHeaders.Add($headerMatch.Value.Trim())
    }

    $blocksToAppend = New-Object System.Collections.Generic.List[string]

    foreach ($projectBlock in $defaultProjectBlocks) {
        $block = Trim-TrailingNewlines $projectBlock.Value
        $headerMatch = [regex]::Match($block, "(?m)^\[projects\.[^\n]+\]")

        if (-not $headerMatch.Success) {
            continue
        }

        $header = $headerMatch.Value.Trim()

        if ($knownHeaders.Contains($header)) {
            continue
        }

        $blocksToAppend.Add($block)
        [void]$knownHeaders.Add($header)
    }

    if ($blocksToAppend.Count -eq 0) {
        return $normalized
    }

    $appendedBlocks = ($blocksToAppend.ToArray() -join "`n`n")

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "$appendedBlocks`n"
    }

    return "$(Trim-TrailingNewlines $normalized)`n`n$appendedBlocks`n"
}

function Ensure-AccountConfig {
    param([string]$AccountDir)

    $defaultConfig = Read-TextFile $defaultConfigPath

    if ([string]::IsNullOrWhiteSpace($defaultConfig)) {
        return
    }

    $accountConfigPath = Join-Path $AccountDir "config.toml"
    $accountConfig = Read-TextFile $accountConfigPath
    $defaultCanonical = "$(Trim-TrailingNewlines $defaultConfig)`n"

    if ([string]::IsNullOrWhiteSpace($accountConfig)) {
        Write-TextFile -Path $accountConfigPath -Content $defaultCanonical
        return
    }

    $original = "$(Trim-TrailingNewlines $accountConfig)`n"

    if ($original -eq $defaultCanonical) {
        return
    }

    $updated = $original
    $defaultNormalized = Normalize-Newlines $defaultConfig
    $wslSetupMatch = [regex]::Match($defaultNormalized, "(?m)^windows_wsl_setup_acknowledged\s*=.*$")

    if ($wslSetupMatch.Success) {
        $updated = Upsert-TopLevelSetting `
            -Config $updated `
            -Key "windows_wsl_setup_acknowledged" `
            -ValueLine $wslSetupMatch.Value.Trim()
    }

    $windowsBlock = Get-TableBlock -Config $defaultConfig -Header "[windows]"

    if ($windowsBlock) {
        $updated = Upsert-TableBlock -Config $updated -Header "[windows]" -Block $windowsBlock
    }

    $defaultFeaturesBlock = Get-TableBlock -Config $defaultConfig -Header "[features]"

    if ($defaultFeaturesBlock) {
        foreach ($featureKey in @("apps", "tool_suggest")) {
            $featureValueLine = Get-SettingLine -Config $defaultFeaturesBlock -Key $featureKey

            if ($featureValueLine) {
                $updated = Upsert-TableSetting `
                    -Config $updated `
                    -Header "[features]" `
                    -Key $featureKey `
                    -ValueLine $featureValueLine
            }
        }
    }

    $updated = Add-MissingProjectBlocks -Config $updated -DefaultConfig $defaultConfig
    $updated = "$(Trim-TrailingNewlines $updated)`n"

    if ($updated -eq $original) {
        return
    }

    $backupPath = "$accountConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $accountConfigPath -Destination $backupPath -Force
    Write-TextFile -Path $accountConfigPath -Content $updated
}

function Ensure-FreeAccountDefaults {
    param([string]$AccountDir)
    $authPath = Join-Path $AccountDir 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) { return }
    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
        $plan = $null
        foreach ($token in @($auth.tokens.id_token, $auth.tokens.access_token)) {
            if (-not $token -or $token.Split('.').Count -lt 2) { continue }
            $segment = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
            $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json
            $plan = $claims.'https://api.openai.com/auth'.chatgpt_plan_type
            if ($plan) { break }
        }
    } catch { return }
    if ($plan -ne 'free') { return }
    $path = Join-Path $AccountDir 'config.toml'
    $config = Normalize-Newlines (Read-TextFile $path)
    $top = ($config -split '(?m)^\[', 2)[0]
    $prefix = ''
    if ($top -notmatch '(?m)^model\s*=') { $prefix += "model = `"gpt-5.6-terra`"`n" }
    if ($top -notmatch '(?m)^model_reasoning_effort\s*=') { $prefix += "model_reasoning_effort = `"medium`"`n" }
    if ($prefix) { Write-TextFile -Path $path -Content ($prefix + $config) }
}

function Ensure-AccountInstructions {
    param([string]$AccountDir)
    $path = Join-Path $AccountDir 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $links = @(& fsutil hardlink list $path 2>$null)
    if ($LASTEXITCODE -eq 0 -and @($links | Where-Object { $_ -match '[\\/]AGENTS\.shared\.md$' }).Count) {
        $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        Copy-Item -LiteralPath $path -Destination $temporary
        [IO.File]::Replace($temporary, $path, [NullString]::Value)
    }
}

function Get-AccountBootstrapSource {
    param([string]$ExcludePath)

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($candidate in @(
        [pscustomobject]@{
            Path = (Join-Path $HOME ".codex")
            Label = "default profile"
        },
        [pscustomobject]@{
            Path = (Join-Path $accountsRoot "account1")
            Label = "account1"
        }
    )) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Container)) {
            continue
        }

        if ($ExcludePath -and $candidate.Path -eq $ExcludePath) {
            continue
        }

        if ($seenPaths.Add($candidate.Path)) {
            $candidates.Add($candidate)
        }
    }

    foreach ($directory in Get-AccountDirectories) {
        if ($ExcludePath -and $directory.FullName -eq $ExcludePath) {
            continue
        }

        if ($seenPaths.Add($directory.FullName)) {
            $candidates.Add([pscustomobject]@{
                Path = $directory.FullName
                Label = $directory.Name
            })
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0]
}

function Copy-BootstrapItem {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return
    }

    $destinationPath = Join-Path $DestinationRoot $RelativePath

    if (Test-Path -LiteralPath $destinationPath) {
        return
    }

    $destinationParent = Split-Path -Parent $destinationPath

    if ($destinationParent -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function Initialize-AccountDirectory {
    param(
        [string]$AccountName,
        [string]$AccountDir
    )

    if (Test-Path -LiteralPath $AccountDir -PathType Leaf) {
        throw "Expected directory path at '$AccountDir' but found a file."
    }

    if (Test-Path -LiteralPath $AccountDir -PathType Container) {
        if($NewAccount){throw 'That account already exists. Choose another name in Deck.'}
        if($InheritFrom){throw '-InheritFrom only applies when creating a new account.'}
        return [pscustomobject]@{
            Created = $false
            Source = $null
            SkipConfigSync = $false
        }
    }

    if(-not ('DeckAccountDirectory' -as [type])){
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class DeckAccountDirectory { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateDirectory(string path, IntPtr security); }'
    }
    if(-not [DeckAccountDirectory]::CreateDirectory($AccountDir,[IntPtr]::Zero)){
        $errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if($errorCode -eq 183 -and -not $NewAccount){return [pscustomobject]@{Created=$false;Source=$null;SkipConfigSync=$false}}
        throw 'The account directory could not be created exclusively. It may already exist; nothing was overwritten.'
    }

    foreach ($relativeDirectory in @("log", "memories", "sessions", "tmp", ".tmp")) {
        New-Item -ItemType Directory -Path (Join-Path $AccountDir $relativeDirectory) -Force | Out-Null
    }

    $bootstrapSource = $null
    if ($InheritFrom) {
        $sourceDir = if ($InheritFrom -eq 'default') { Split-Path -Parent $defaultConfigPath } else { Get-DeckEntryDirectory (Split-Path -Parent $accountsRoot) (Normalize-AccountName $InheritFrom) }
        $bootstrapSource = [pscustomobject]@{Path=$sourceDir; Label=$InheritFrom}
        foreach ($relativePath in @('config.toml','AGENTS.md','rules','skills','.personality_migration')) { Copy-BootstrapItem $sourceDir $AccountDir $relativePath }
    }
    return [pscustomobject]@{Created=$true; Source=$bootstrapSource; SkipConfigSync=$true}

}

function Show-Usage {
    Write-Host "Usage: codex-auth [dashboard|status|accountN|N|list] [codex args...]"
    Write-Host "  codex-auth          Interactive account dashboard"
    Write-Host "  codex-auth status   Cached dashboard snapshot (no network)"
    Write-Host "  codex-auth -Best    Launch the recommended fresh account"
    Write-Host "  codex-auth pool -Pool -PoolAccounts '*'  Configure the pooled environment"
    Write-Host "  codex-auth pool -UseAccount account2   Choose a starting member"
    Write-Host "  codex-auth share -Source pool -Targets account1,account2 -Resources skills,memories,mcp:github"
    Write-Host "  codex-auth unshare -Targets account1 -Resources skills   Restore private resources"
    Write-Host "  codex-auth sharing   Show explicit sharing"
    Write-Host "  codex-auth new-name -InheritFrom account1   Explicit one-time copy"
    Write-Host "  codex-auth -History [filter]   Browse/resume local sessions"
    Write-Host "  codex-auth -GlobalRules       Edit rules for every account and pool"
    Write-Host "  codex-auth old -RenameTo new  Rename an inactive account"
    Write-Host "  codex-auth -Failover Ordered -FailoverAccounts account1,account2"
    Write-Host "  codex-auth -Failover Best -FailoverAccounts account1,account2"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  codex-auth account1"
    Write-Host "  codex-auth 2 login status"
    Write-Host "  codex-auth account3 --help"
    Write-Host "  codex-auth list"
    Write-Host "  codex-auth account3 -del   (remove account; keep a recovery copy)"
}

function Show-Accounts {
    $directories = Get-AccountDirectories

    if ($directories.Count -eq 0) {
        Write-Host "No accounts found under $accountsRoot"
        return
    }

    foreach ($directory in $directories) {
        $hasAuth = Test-Path -LiteralPath (Join-Path $directory.FullName "auth.json") -PathType Leaf
        $marker = if (Get-DeckPoolEntry (Split-Path -Parent $accountsRoot) $directory.Name) { "POOL" } elseif ($hasAuth) { "*" } else { "-" }
        Write-Host ("{0} {1}" -f $marker, $directory.Name)
    }

    Write-Host ""
    Write-Host "* = auth.json present"
}

function Use-CodexNodePath {
    $preferred = @($env:NVM_HOME, $env:NVM_SYMLINK) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $expandedPath = @($env:Path -split ';') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($preferred + $expandedPath)) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        if ($seen.Add($entry)) {
            $ordered.Add($entry)
        }
    }

    if ($ordered.Count -gt 0) {
        $env:Path = ($ordered -join ';')
    }
}

function ConvertTo-DeckWindowsArgument([AllowEmptyString()][string]$Value) {
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$quoted.Append(('\' * ($slashes * 2 + 1)))
            [void]$quoted.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$quoted.Append(('\' * $slashes)); $slashes = 0 }
        [void]$quoted.Append($character)
    }
    if ($slashes) { [void]$quoted.Append(('\' * ($slashes * 2))) }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-DeckCodex([string[]]$Arguments) {
    $resolved = Get-Command codex -ErrorAction Stop | Select-Object -First 1
    if ($resolved.CommandType -ne 'ExternalScript' -or -not (Test-Path -LiteralPath $resolved.Source -PathType Leaf)) {
        # Nonstandard installations retain the ordinary PowerShell resolution
        # path. This also keeps function-based test harnesses supported. The
        # Windows npm launcher normally takes the isolated path below.
        & $resolved @Arguments
        return
    }
    $launcher = $resolved
    if (-not ('CodexDeckNativeProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexDeckNativeProcess {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static int Run(string applicationName, string commandLine) {
        STARTUPINFO startup = new STARTUPINFO();
        startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION process;
        const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
        if (!CreateProcess(applicationName, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
                true, CREATE_NEW_PROCESS_GROUP, IntPtr.Zero, null, ref startup, out process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not start Codex.");
        }
        try {
            if (WaitForSingleObject(process.hProcess, 0xFFFFFFFF) == 0xFFFFFFFF) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not wait for Codex.");
            }
            uint exitCode;
            if (!GetExitCodeProcess(process.hProcess, out exitCode)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the Codex exit code.");
            }
            return unchecked((int)exitCode);
        } finally {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
    }
}
'@
    }
    # Codex and its local-command descendants get their own console process
    # group. This prevents a control event in that tree from cancelling the
    # outer dashboard PowerShell that is synchronously waiting for the session.
    $powerShell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $commandParts = @($powerShell,'-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher.Source) + @($Arguments)
    $commandLine = ($commandParts | ForEach-Object { ConvertTo-DeckWindowsArgument ([string]$_) }) -join ' '
    $global:LASTEXITCODE = [CodexDeckNativeProcess]::Run($powerShell, $commandLine)
}

function Write-DeckSessionExit([string]$DeckRoot, [string]$Environment, [int]$ExitCode, $StartedAt, [bool]$ProxyExitedEarly, $ProxyExitCode, [string]$ActiveAccount) {
    try {
        [void][IO.Directory]::CreateDirectory($DeckRoot)
        $path = Join-Path $DeckRoot 'session-exits.jsonl'
        $entry = [ordered]@{
            At = [DateTimeOffset]::Now.ToString('o')
            StartedAt = $StartedAt.ToString('o')
            Environment = $Environment
            ActiveAccount = $ActiveAccount
            ExitCode = $ExitCode
            ProxyExitedEarly = $ProxyExitedEarly
            ProxyExitCode = $ProxyExitCode
        }
        [IO.File]::AppendAllText($path, (($entry | ConvertTo-Json -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false))
        if ((Get-Item -LiteralPath $path).Length -gt 262144) {
            $tail = @(Get-Content -LiteralPath $path -Tail 200)
            [IO.File]::WriteAllLines($path, $tail, [Text.UTF8Encoding]::new($false))
        }
    } catch {
        # Diagnostics must never prevent the account session from closing.
    }
}

$runtimeRoot = Split-Path -Parent $accountsRoot
$environmentModule = Join-Path $runtimeRoot 'Deck.Environments.ps1'
if (-not (Test-Path -LiteralPath $environmentModule)) { $environmentModule = Join-Path $PSScriptRoot '../suite/Deck.Environments.ps1' }
. $environmentModule
if ($Pool -or $Account -in @('share','unshare','sharing')) {
    if ($Best -or $History -or $RenameTo -or $Del -or $NewAccount -or $CodexArgs -or $InheritFrom -or $UseAccount -or $PSBoundParameters.ContainsKey('Failover')) { throw 'Do not combine environment management with launch actions.' }
    . (Join-Path $runtimeRoot 'Deck.Core.ps1')
    if ($Pool) {
        if (-not $Account) { $Account='pool' }
        $members = @($(if ($PoolAccounts) { $PoolAccounts -join ',' } else { '*' }) -split ',' | ForEach-Object { Normalize-AccountName $_.Trim() })
        Set-DeckPoolEntry $runtimeRoot $Account $members $PoolMode
    } elseif ($Account -eq 'sharing') {
        foreach ($name in Get-DeckEntryNames $runtimeRoot) {
            foreach ($binding in (Get-DeckSharing $runtimeRoot $name).Bindings) { Write-Output ("{0} <- {1}: {2}" -f $name,$binding.Source,$binding.Resource) }
        }
    } else {
        $targetNames=@(($Targets -join ',') -split ',' | ForEach-Object { Normalize-AccountName $_.Trim() })
        $resourceNames=@(($Resources -join ',') -split ',' | ForEach-Object { $_.Trim() })
        Set-DeckResourceSharing $runtimeRoot (Normalize-AccountName $Source) $targetNames $resourceNames -Detach:($Account -eq 'unshare')
    }
    exit 0
}
if ($PoolAccounts -or $Source -or $Targets -or $Resources) { throw 'Use -Pool to configure membership, or share/unshare to configure resources.' }
$poolEntry = $null
$failoverChoice = $null
if (-not $History -and $Account -and $Account -notin @('help','--help','-h','list','--list','-l','status','dashboard')) { $poolEntry = Get-DeckPoolEntry $runtimeRoot (Normalize-AccountName $Account) }
if ($UseAccount -and -not $poolEntry) { throw '-UseAccount requires a pooled entry.' }
if ($poolEntry -and ($Best -or $NewAccount -or $InheritFrom -or $FailoverAccounts)) { throw 'Use -UseAccount to select a member of this pooled entry.' }
if ($Failover -ne 'Off' -and -not $poolEntry) {
    if ($Best -or $History -or $RenameTo -or $Del -or $NewAccount) { throw 'Do not combine failover with other account actions.' }
    $runtimeRoot = Split-Path -Parent $accountsRoot
    . (Join-Path $runtimeRoot 'Deck.Failover.ps1')
    $failoverChoice = Resolve-DeckFailoverPool $runtimeRoot ($FailoverAccounts -join ',') $Failover $Account
    $Account = $failoverChoice.Account
} elseif ($FailoverAccounts -and -not $poolEntry) { throw '-FailoverAccounts requires -Failover Ordered or Best.' }
if ($Best -or $History -or $RenameTo) {
    if (@($Best.IsPresent,$History.IsPresent,[bool]$RenameTo | Where-Object { $_ }).Count -ne 1 -or $Del -or $NewAccount) { throw 'Choose only one maintenance action.' }
    $runtimeRoot = Split-Path -Parent $accountsRoot
    . (Join-Path $runtimeRoot 'Deck.Core.ps1')
    . (Join-Path $runtimeRoot 'Deck.Terminal.ps1')
    if ($RenameTo) {
        if ($CodexArgs) { throw 'Rename does not accept Codex arguments.' }
        Rename-DeckAccount $runtimeRoot (Normalize-AccountName $Account) (Normalize-AccountName $RenameTo)
        exit 0
    }
    if ($History) {
        if ($CodexArgs) { throw 'History does not accept Codex arguments.' }
        Show-DeckHistoryBrowser $runtimeRoot $PSCommandPath $Account
        exit 0
    }
    if ($Account) { throw '-Best chooses the account; omit an explicit account name.' }
    $names = @(Get-AccountDirectories | ForEach-Object Name)
    $choice = @(Get-DeckRecommendations $names (Get-DeckTerminalCache (Join-Path $runtimeRoot 'deck'))) | Select-Object -First 1
    if (-not $choice) { throw 'No fresh usable account. Refresh usage in codex-auth first.' }
    $Account = $choice.Account
    Write-Host ($Account+': '+$choice.Reason)
}
if ($Del) {
    if ($CodexArgs) { throw '-del cannot be combined with Codex arguments.' }
    Remove-CodexAccount -Name (Normalize-AccountName $Account)
    exit 0
}

if ($Account -in @("help", "--help", "-h")) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Account) -or $Account -in @('dashboard', 'status')) {
    $terminalRoot = Split-Path -Parent $accountsRoot
    $panel = Join-Path $terminalRoot 'Deck.Terminal.ps1'
    if (-not (Test-Path -LiteralPath $panel)) {
        $terminalRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../suite'))
        $panel = Join-Path $terminalRoot 'Deck.Terminal.ps1'
    }
    if (-not (Test-Path -LiteralPath $panel)) { throw 'Dashboard missing. Reinstall Codex Deck.' }
    . $panel
    # Runtime data always belongs to the installed accounts root.
    $runtimeRoot = Split-Path -Parent $accountsRoot
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'Deck.Core.ps1'))) { throw 'Codex Deck core missing. Run Install-CodexDeck.ps1 first.' }
    Show-DeckTerminal -SuiteRoot $runtimeRoot -AuthScript $PSCommandPath -Snapshot:($Account -eq 'status')
    exit 0
}

if ($Account -in @("list", "--list", "-l")) {
    Show-Usage
    Write-Host ""
    Show-Accounts
    exit 0
}

$accountName = Normalize-AccountName -Name $Account
if ($accountName -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $accountName -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$') {
    throw 'Account names must start with a letter and contain at most 40 letters, numbers, underscores or hyphens.'
}
$accountDir = Join-Path $accountsRoot $accountName
if (-not $poolEntry -and (Test-Path -LiteralPath (Join-Path $accountDir 'auth.json')) -and $Failover -eq 'Off' -and -not $PSBoundParameters.ContainsKey('Failover')) {
    $runtimeRoot = Split-Path -Parent $accountsRoot
    $failoverModule = Join-Path $runtimeRoot 'Deck.Failover.ps1'
    if (Test-Path -LiteralPath $failoverModule) {
        . (Join-Path $runtimeRoot 'Deck.Core.ps1')
        . $failoverModule
        $launchSettings = Get-DeckSettings (Join-Path $runtimeRoot 'deck')
        if (Test-DeckAutomaticFailover $launchSettings $false $CodexArgs ([bool]$NewAccount)) {
            $Failover=$launchSettings.FailoverMode
            $failoverChoice=Resolve-DeckFailoverPool $runtimeRoot $launchSettings.FailoverAccounts $Failover $accountName
        }
    }
}


[void][IO.Directory]::CreateDirectory($accountsRoot)
$bootstrapResult = Initialize-AccountDirectory -AccountName $accountName -AccountDir $accountDir
$accountDir = Get-DeckEntryDirectory $runtimeRoot $accountName

if ($bootstrapResult.Created) {
    if ($bootstrapResult.Source) {
        Write-Host ("Created {0} from {1}." -f $accountName, $bootstrapResult.Source.Label)
    } else {
        Write-Host ("Created {0}." -f $accountName)
    }
}

Ensure-AccountInstructions -AccountDir $accountDir
Ensure-FreeAccountDefaults -AccountDir $accountDir
$commandsModule = Join-Path $runtimeRoot 'Deck.Commands.ps1'
if (Test-Path -LiteralPath $commandsModule) {
    . $commandsModule
    Remove-DeckLegacyCommandSkills $accountDir | Out-Null
}
Use-CodexNodePath
$sharedArgs = @(Get-DeckSharedArguments $runtimeRoot $accountName)
$globalRuleArgs=@()
if(Test-Path -LiteralPath (Join-Path $runtimeRoot 'Deck.GlobalRules.ps1')){
    . (Join-Path $runtimeRoot 'Deck.GlobalRules.ps1')
    if(-not $CodexArgs -or $CodexArgs[0] -notin @('login','logout','mcp','mcp-server','completion','features','debug','app-server','--help','-h','--version','-V')){
        $globalRuleArgs=@(Get-DeckGlobalRuleArguments $runtimeRoot $accountDir (@($sharedArgs)+@($CodexArgs)))
    }
}
if ($poolEntry -and $CodexArgs -and $CodexArgs[0] -in @('login','logout')) { throw 'Pooled environments do not own logins. Sign in to a member account instead.' }
$codexConversation = -not $CodexArgs -or $CodexArgs[0] -notin @('login','logout','mcp','mcp-server','completion','features','debug','app-server','cloud','apply','sandbox','doctor','update','--help','-h','--version','-V')
$poolConversation = $poolEntry -and $codexConversation
if ($poolEntry -and -not $poolConversation -and $Failover -ne 'Off') { throw 'Rotation applies to conversations, not administrative commands.' }
if ($poolConversation) {
    . (Join-Path $runtimeRoot 'Deck.Core.ps1')
    . (Join-Path $runtimeRoot 'Deck.Terminal.ps1')
    . (Join-Path $runtimeRoot 'Deck.Failover.ps1')
    $members = @(Resolve-DeckEntryPool $runtimeRoot $poolEntry)
    $initial = Normalize-AccountName $UseAccount
    if ($initial -and $initial -notin $members) { throw 'The selected account is not in this pool.' }
    $rotationDisabled = $PSBoundParameters.ContainsKey('Failover') -and $Failover -eq 'Off'
    $poolMode = if ($rotationDisabled) { 'Ordered' } elseif ($PSBoundParameters.ContainsKey('Failover')) { $Failover } else { $poolEntry.Mode }
    $failoverChoice = Resolve-DeckFailoverPool $runtimeRoot ($members -join ',') $poolMode $initial
    $Failover = if ($rotationDisabled) { 'Off' } else { $poolMode }
}
$routeMode = if ($Failover -eq 'Off') { 'Ordered' } else { $Failover }
$automaticFailover = $Failover -ne 'Off'
if ($codexConversation -and -not $poolEntry -and -not $failoverChoice -and (Test-Path -LiteralPath (Join-Path $accountDir 'auth.json') -PathType Leaf)) {
    . (Join-Path $runtimeRoot 'Deck.Failover.ps1')
    # Ordinary sessions keep their own CODEX_HOME/history, but route through a
    # manual-only set so !account can switch to any other signed-in profile.
    $failoverChoice = Resolve-DeckFailoverPool $runtimeRoot '*' Ordered $accountName
}
$useRoutingProxy = $codexConversation -and $failoverChoice -and @($failoverChoice.Pool).Count
$originalCodexHome = $env:CODEX_HOME
$originalDeckSessionUrl = $env:CODEX_DECK_SESSION_URL
$env:CODEX_HOME = $accountDir
$deckSession = $null
try {
    $suiteRoot = Split-Path -Parent $accountsRoot
    $deckCore = Join-Path $suiteRoot 'Deck.Core.ps1'
    if (Test-Path -LiteralPath $deckCore) {
        . $deckCore
        $deckRoot = Join-Path $suiteRoot 'deck'
        $deckSession = Register-DeckSession $deckRoot $accountName (Get-Location).Path
        if ((Get-DeckSettings $deckRoot).AutoStart) { Start-DeckCompanion $suiteRoot }
    }
} catch { Write-Warning "Codex Deck could not attach: $($_.Exception.Message)" }
$failoverProxy = $null
$failoverSessions = @()
$codexExitCode = -1
$codexStartedAt = [DateTimeOffset]::Now
try {
    if ($useRoutingProxy) {
        $environmentMembers = if ($poolConversation) { @($members) } else { @() }
        $failoverProxy = Start-DeckFailover -SuiteRoot $suiteRoot -Pool $failoverChoice.Pool -Mode $routeMode -Account $failoverChoice.Account -Environment $accountName -EnvironmentPool $environmentMembers -Automatic:$automaticFailover
        if ($automaticFailover -or $poolConversation) {
            foreach ($poolAccount in $failoverChoice.Pool) {
                $failoverSessions += Register-DeckSession (Join-Path $suiteRoot 'deck') $poolAccount (Get-Location).Path
            }
        }
        $env:CODEX_DECK_SESSION_URL = $failoverProxy.BaseUrl
        $launchArgs = @($sharedArgs) + @($CodexArgs) + @($globalRuleArgs) + @(Get-DeckFailoverArguments $failoverProxy.BaseUrl -NoAccountAuth:([bool]$poolEntry))
        $launchArgs=@(ConvertTo-DeckCodexArguments $launchArgs)
        Invoke-DeckCodex $launchArgs
        $codexExitCode = $LASTEXITCODE
    } else {
        $launchArgs=@(ConvertTo-DeckCodexArguments (@($sharedArgs)+@($CodexArgs)+@($globalRuleArgs)))
        Invoke-DeckCodex $launchArgs
        $codexExitCode = $LASTEXITCODE
    }
} finally {
    $env:CODEX_HOME = $originalCodexHome
    $env:CODEX_DECK_SESSION_URL = $originalDeckSessionUrl
    $proxyExitedEarly = $false
    $proxyExitCode = $null
    $activeAccount = $accountName
    if ($failoverProxy) {
        $proxyExitedEarly = $failoverProxy.Process.HasExited
        if ($proxyExitedEarly) { $proxyExitCode = $failoverProxy.Process.ExitCode }
        else {
            try { $activeAccount = [string](Invoke-RestMethod -Uri ($failoverProxy.BaseUrl + '/_deck/account') -Method Get -TimeoutSec 2).failover.active } catch {}
        }
        if ($failoverProxy.InputWriter) { $failoverProxy.InputWriter.Dispose() }
        else { $failoverProxy.Process.StandardInput.Close() }
        if (-not $failoverProxy.Process.WaitForExit(2000)) { $failoverProxy.Process.Kill() }
        $failoverProxy.Process.Dispose()
    }
    Write-DeckSessionExit (Join-Path $suiteRoot 'deck') $accountName $codexExitCode $codexStartedAt $proxyExitedEarly $proxyExitCode $activeAccount
    foreach ($marker in $failoverSessions) { Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue }
    if ($deckSession -and (Test-Path -LiteralPath $deckSession)) {
        Remove-Item -LiteralPath $deckSession -ErrorAction SilentlyContinue
    }
}
# Login may have identified a newly created account's plan for the first time.
Ensure-FreeAccountDefaults -AccountDir $accountDir
exit $codexExitCode
