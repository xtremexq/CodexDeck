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
    [switch]$Resume,
    [string]$ResumePrompt,
    [string]$ResumePromptEnvironment,
    [switch]$GlobalRules,
    [string]$RenameTo,
    [ValidateSet('Off','Ordered','Best')]
    [string]$Failover = 'Off',
    [string[]]$FailoverAccounts,
    [switch]$Direct,
    [switch]$AutoCompact,
    [Alias('a')]
    [switch]$CheckAll,

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

function Find-DeckConversationOwner {
    param([string]$ConversationId)

    $parsedId = [guid]::Empty
    if (-not [guid]::TryParseExact($ConversationId, 'D', [ref]$parsedId)) {
        throw 'Resume requires one conversation ID in UUID form.'
    }
    $canonicalId = $parsedId.ToString('D')
    $matches = @(foreach ($directory in Get-AccountDirectories) {
        $sessions = Join-Path $directory.FullName 'sessions'
        if (-not (Test-Path -LiteralPath $sessions -PathType Container)) { continue }
        if (Get-ChildItem -LiteralPath $sessions -Filter ("rollout-*-$canonicalId.jsonl") -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) {
            [pscustomobject]@{ Account=$directory.Name; Id=$canonicalId }
        }
    })
    if (-not $matches.Count) { throw "Conversation '$canonicalId' was not found in any codex-auth account or pool." }
    if ($matches.Count -gt 1) {
        throw ("Conversation '$canonicalId' exists in multiple codex-auth histories: {0}. Resume it with an explicit account." -f (($matches.Account | Sort-Object) -join ', '))
    }
    return $matches[0]
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
    Write-Host "Usage: codex-auth [dashboard|status|resume|accountN|N|list] [codex args...]"
    Write-Host "  codex-auth          Interactive account dashboard"
    Write-Host "  codex-auth -a       Open the dashboard and queue checks for every signed-in account"
    Write-Host "  codex-auth status   Cached dashboard snapshot (no network)"
    Write-Host "  codex-auth -Best    Launch the recommended fresh account"
    Write-Host "  codex-auth pool -Pool -PoolAccounts '*'  Configure the pooled environment"
    Write-Host "  codex-auth pool -UseAccount account2   Choose a starting member"
    Write-Host "  codex-auth share -Source pool -Targets account1,account2 -Resources skills,memories,mcp:github"
    Write-Host "  codex-auth unshare -Targets account1 -Resources skills   Restore private resources"
    Write-Host "  codex-auth sharing   Show explicit sharing"
    Write-Host "  codex-auth new-name -InheritFrom account1   Explicit one-time copy"
    Write-Host "  codex-auth -History [filter]   Browse/resume local sessions"
    Write-Host "  codex-auth account1 -Resume   Open this account's conversation list"
    Write-Host "  codex-auth account1 -Resume <conversation-id>   Resume one conversation"
    Write-Host "  codex-auth resume <conversation-id>   Find its account and resume through Deck"
    Write-Host "  codex-auth -GlobalRules       Edit rules for every account and pool"
    Write-Host "  codex-auth old -RenameTo new  Rename an inactive account"
    Write-Host "  codex-auth -Failover Ordered -FailoverAccounts account1,account2"
    Write-Host "  codex-auth -Failover Best -FailoverAccounts account1,account2"
    Write-Host "  codex-auth account15 -Direct -CodexArgs @('exec',...)  Launch without Deck's local routing proxy"
    Write-Host "  codex-auth account1 -AutoCompact 50%   Use the selected Native/Custom mode at 50% context remaining"
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
    $nativeExecutable = $resolved.CommandType -eq 'Application' -and [IO.Path]::GetExtension($resolved.Source) -eq '.exe'
    if (($resolved.CommandType -ne 'ExternalScript' -and -not $nativeExecutable) -or -not (Test-Path -LiteralPath $resolved.Source -PathType Leaf)) {
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
    # Launch the official npm entry directly. Passing a TOML -c value through
    # codex.ps1 would make Windows PowerShell parse its quotes a second time.
    # Keep a separate console process group so Ctrl+C in Codex cannot cancel
    # the dashboard PowerShell waiting for this session.
    $codexEntry = if ($nativeExecutable) { '' } else { Join-Path (Split-Path -Parent $launcher.Source) 'node_modules/@openai/codex/bin/codex.js' }
    if ($nativeExecutable) {
        $executable = $launcher.Source
        $commandParts = @($executable) + @($Arguments)
    } elseif (Test-Path -LiteralPath $codexEntry -PathType Leaf) {
        $executable = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $commandParts = @($executable,$codexEntry) + @($Arguments)
    } else {
        $executable = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $commandParts = @($executable,'-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher.Source) + @($Arguments)
    }
    $commandLine = ($commandParts | ForEach-Object { ConvertTo-DeckWindowsArgument ([string]$_) }) -join ' '
    $global:LASTEXITCODE = [CodexDeckNativeProcess]::Run($executable, $commandLine)
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

function Get-DeckSessionRoutingArguments($Proxy, [bool]$Pooled) {
    if (-not $Proxy) { return @() }
    # The hosted app-server and its native TUI must use the same provider identity.
    # Ordinary accounts stay on "openai" so Codex reads their normal resume index;
    # only login-less pooled environments use the custom deck_failover provider.
    @(Get-DeckFailoverArguments $Proxy.BaseUrl -NoAccountAuth:$Pooled)
}

function ConvertFrom-DeckTomlScalar([AllowNull()][string]$Value) {
    if ($null -eq $Value) { return $null }
    $trimmed=$Value.Trim()
    if ($trimmed.Length -ge 2 -and (($trimmed[0] -eq '"' -and $trimmed[$trimmed.Length-1] -eq '"') -or ($trimmed[0] -eq "'" -and $trimmed[$trimmed.Length-1] -eq "'"))) {
        return $trimmed.Substring(1,$trimmed.Length-2)
    }
    return $trimmed
}

function Get-DeckTomlTopLevelValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $pattern='^\s*'+[regex]::Escape($Name)+'\s*=\s*(.+?)\s*(?:#.*)?$'
    foreach($line in [IO.File]::ReadAllLines($Path)){
        if($line -match '^\s*\['){break}
        if($line -match $pattern){return ConvertFrom-DeckTomlScalar $Matches[1]}
    }
    return $null
}

function Get-DeckCodexArgumentSetting([string[]]$Arguments, [string]$Name) {
    $value=$null
    # PowerShell 7 treats @($null) as a one-item array here. Consuming the
    # optional auto-compact percentage leaves no native Codex arguments, so
    # handle that valid empty remainder before indexing it.
    if($null -eq $Arguments){return $null}
    for($index=0;$index -lt $Arguments.Count;$index++){
        $argument=[string]$Arguments[$index]
        if($Name -eq 'model'){
            if($argument -in @('-m','--model') -and $index+1 -lt $Arguments.Count){$value=[string]$Arguments[++$index];continue}
            if($argument -match '^--model=(.+)$'){$value=$Matches[1];continue}
        }
        if($argument -in @('-c','--config') -and $index+1 -lt $Arguments.Count){
            $override=[string]$Arguments[++$index]
            if($override -match ('^\s*'+[regex]::Escape($Name)+'\s*=\s*(.+?)\s*$')){$value=ConvertFrom-DeckTomlScalar $Matches[1]}
            continue
        }
        if($argument -match '^--config=(.+)$'){
            $override=$Matches[1]
            if($override -match ('^\s*'+[regex]::Escape($Name)+'\s*=\s*(.+?)\s*$')){$value=ConvertFrom-DeckTomlScalar $Matches[1]}
        }
    }
    return $value
}

function Get-DeckNativeAutoCompactConfiguration([string]$AccountDirectory, [string[]]$Arguments, [int]$FreePercent) {
    if($FreePercent -lt 30 -or $FreePercent -gt 90){throw 'Auto-compact remaining-context threshold must be 30-90%.'}
    $configPath=Join-Path $AccountDirectory 'config.toml'
    $model=Get-DeckCodexArgumentSetting $Arguments 'model'
    if(-not $model){$model=Get-DeckTomlTopLevelValue $configPath 'model'}
    $windowOverride=Get-DeckCodexArgumentSetting $Arguments 'model_context_window'
    if(-not $windowOverride){$windowOverride=Get-DeckTomlTopLevelValue $configPath 'model_context_window'}

    $cachePaths=[Collections.Generic.List[string]]::new()
    foreach($candidate in @((Join-Path $AccountDirectory 'models_cache.json'),(Join-Path $HOME '.codex/models_cache.json'))){
        if($candidate -and -not $cachePaths.Contains($candidate)){$cachePaths.Add($candidate)}
    }
    if(Test-Path -LiteralPath $accountsRoot -PathType Container){
        foreach($directory in Get-AccountDirectories){
            $candidate=Join-Path $directory.FullName 'models_cache.json'
            if(-not $cachePaths.Contains($candidate)){$cachePaths.Add($candidate)}
        }
    }
    $metadata=$null
    foreach($cachePath in $cachePaths){
        if(-not (Test-Path -LiteralPath $cachePath -PathType Leaf)){continue}
        try{$models=@(([IO.File]::ReadAllText($cachePath)|ConvertFrom-Json).models)}catch{continue}
        if(-not $model){
            $default=@($models | Where-Object visibility -eq 'list' | Sort-Object priority | Select-Object -First 1)
            if($default.Count){$model=[string]$default[0].slug}
        }
        $metadata=@($models | Where-Object slug -eq $model | Select-Object -First 1)
        if($metadata.Count){$metadata=$metadata[0];break}
        $metadata=$null
    }
    $contextWindow=0L
    if($windowOverride){
        if(-not [long]::TryParse([string]$windowOverride,[ref]$contextWindow) -or $contextWindow -le 0){throw "Invalid model_context_window for native auto-compact: $windowOverride"}
    }elseif($metadata -and $metadata.context_window){$contextWindow=[long]$metadata.context_window}
    if($contextWindow -le 0){throw "Cannot determine the context window for model '$model'. Launch it once to refresh models_cache.json, or set model_context_window."}
    $effectivePercent=if($metadata -and $metadata.effective_context_window_percent){[int]$metadata.effective_context_window_percent}else{100}
    $effectiveWindow=[long][Math]::Floor($contextWindow*($effectivePercent/100.0))
    $tokenLimit=[long][Math]::Floor($effectiveWindow*((100-$FreePercent)/100.0))
    if($tokenLimit -le 0){throw 'Native auto-compact token threshold resolved to zero.'}
    return [pscustomobject]@{
        Mode='Native'; Model=$model; ContextWindow=$contextWindow; EffectiveContextWindow=$effectiveWindow; TokenLimit=$tokenLimit; FreePercent=$FreePercent
        Arguments=@('-c',("model_auto_compact_token_limit={0}" -f $tokenLimit),'-c','model_auto_compact_token_limit_scope="total"')
    }
}

$runtimeRoot = Split-Path -Parent $accountsRoot
$environmentModule = Join-Path $runtimeRoot 'Deck.Environments.ps1'
if (-not (Test-Path -LiteralPath $environmentModule)) { $environmentModule = Join-Path $PSScriptRoot '../suite/Deck.Environments.ps1' }
. $environmentModule
$bundledSkillsModule = Join-Path $runtimeRoot 'Deck.BundledSkills.ps1'
if (-not (Test-Path -LiteralPath $bundledSkillsModule)) { $bundledSkillsModule = Join-Path $PSScriptRoot '../suite/Deck.BundledSkills.ps1' }
if (Test-Path -LiteralPath $bundledSkillsModule) { . $bundledSkillsModule }
if($CheckAll -and @($PSBoundParameters.Keys | Where-Object {$_ -ne 'CheckAll'}).Count){
    throw '-a only works with the plain codex-auth dashboard command.'
}
$autoCompactThresholdOverride=$null
if($AutoCompact -and $CodexArgs -and [string]$CodexArgs[0] -match '^([0-9]+)%$'){
    $autoCompactThresholdOverride=[int]$Matches[1]
    if($autoCompactThresholdOverride -lt 30 -or $autoCompactThresholdOverride -gt 90){throw 'Auto-compact remaining-context threshold must be 30-90%.'}
    $CodexArgs=if($CodexArgs.Count -gt 1){@($CodexArgs[1..($CodexArgs.Count-1)])}else{@()}
}
if($Account -ieq 'resume'){
    if($Resume -or -not $CodexArgs -or $CodexArgs.Count -ne 1){throw 'Use codex-auth resume <conversation-id>.'}
    $conversation=Find-DeckConversationOwner ([string]$CodexArgs[0])
    $Account=$conversation.Account
    $CodexArgs=@($conversation.Id)
    $Resume=$true
    Write-Host ("Conversation {0} found in {1}." -f $conversation.Id,$conversation.Account)
}
if($ResumePromptEnvironment){
    if(-not $Resume -or $ResumePromptEnvironment -notmatch '^CODEX_DECK_SCHEDULED_PROMPT_[A-F0-9]{32}$'){throw 'Invalid scheduled resume prompt source.'}
    if($PSBoundParameters.ContainsKey('ResumePrompt')){throw 'Choose one resume prompt source.'}
    $ResumePrompt=[Environment]::GetEnvironmentVariable($ResumePromptEnvironment,'Process')
    [Environment]::SetEnvironmentVariable($ResumePromptEnvironment,$null,'Process')
    if($null -eq $ResumePrompt){throw 'The scheduled resume prompt is unavailable.'}
}
if($PSBoundParameters.ContainsKey('ResumePrompt') -and -not $Resume){throw '-ResumePrompt requires -Resume.'}
if($Resume){
    if(-not $Account -or $Best -or $History -or $RenameTo -or $Del -or $NewAccount -or $Pool){throw '-Resume requires one existing account or pool and cannot be combined with account management.'}
    if($CodexArgs -and $CodexArgs.Count -gt 1){throw '-Resume accepts at most one conversation ID.'}
    if($PSBoundParameters.ContainsKey('ResumePrompt') -and -not $CodexArgs){throw '-ResumePrompt requires a conversation ID.'}
    $resumeArguments=@('resume')
    if($CodexArgs){
        if([string]::IsNullOrWhiteSpace([string]$CodexArgs[0])){throw 'Conversation ID cannot be empty.'}
        $resumeArguments += [string]$CodexArgs[0]
        if($PSBoundParameters.ContainsKey('ResumePrompt') -or $ResumePromptEnvironment){$resumeArguments += [string]$ResumePrompt}
    }else{$resumeArguments += '--all'}
    $CodexArgs=$resumeArguments
}
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
if ($Direct -and (-not $Account -or $poolEntry -or $Failover -ne 'Off' -or $Best -or $History -or $RenameTo -or $Del -or $NewAccount)) { throw '-Direct requires one existing account and cannot be combined with rotation or account management.' }
if ($AutoCompact -and (-not $Account -or $Best -or $History -or $RenameTo -or $Del -or $NewAccount)) { throw '-AutoCompact requires an account or pool conversation and cannot be combined with account management.' }
if ($AutoCompact -and $CodexArgs -and $CodexArgs[0] -in @('login','logout','mcp','mcp-server','completion','features','debug','app-server','cloud','apply','sandbox','doctor','update','--help','-h','--version','-V')) { throw '-AutoCompact supports conversations only, not administrative commands.' }
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
    Show-DeckTerminal -SuiteRoot $runtimeRoot -AuthScript $PSCommandPath -Snapshot:($Account -eq 'status') -CheckAll:$CheckAll
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
if($Resume -and -not (Test-Path -LiteralPath $accountDir -PathType Container)){throw "Cannot resume from missing account '$accountName'."}
if (-not $Direct -and -not $poolEntry -and (Test-Path -LiteralPath (Join-Path $accountDir 'auth.json')) -and $Failover -eq 'Off' -and -not $PSBoundParameters.ContainsKey('Failover')) {
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
if(Get-Command Sync-DeckBundledSkills -ErrorAction SilentlyContinue){
    foreach($warning in @(Sync-DeckBundledSkills $runtimeRoot $accountName)){if($warning){Write-Warning $warning}}
}
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
if ($codexConversation -and -not $Direct -and -not $poolEntry -and -not $failoverChoice -and (Test-Path -LiteralPath (Join-Path $accountDir 'auth.json') -PathType Leaf)) {
    . (Join-Path $runtimeRoot 'Deck.Failover.ps1')
    # Ordinary sessions keep their own CODEX_HOME/history, but route through a
    # manual-only set so !account can switch to any other signed-in profile.
    $failoverChoice = Resolve-DeckFailoverPool $runtimeRoot '*' Ordered $accountName
}
$useRoutingProxy = $codexConversation -and $failoverChoice -and @($failoverChoice.Pool).Count
$originalCodexHome = $env:CODEX_HOME
$originalDeckSessionUrl = $env:CODEX_DECK_SESSION_URL
$originalDeckSessionPath = $env:CODEX_DECK_SESSION_PATH
$env:CODEX_HOME = $accountDir
Remove-Item Env:CODEX_DECK_SESSION_PATH -ErrorAction SilentlyContinue
if ($Direct) { Remove-Item Env:CODEX_DECK_SESSION_URL -ErrorAction SilentlyContinue }
$deckSession = $null
$deckSettings = $null
try {
    $suiteRoot = Split-Path -Parent $accountsRoot
    $deckCore = Join-Path $suiteRoot 'Deck.Core.ps1'
    if (Test-Path -LiteralPath $deckCore) {
        . $deckCore
        $deckRoot = Join-Path $suiteRoot 'deck'
        $deckSession = Register-DeckSession $deckRoot $accountName (Get-Location).Path
        $env:CODEX_DECK_SESSION_PATH = $deckSession
        $deckSettings = Get-DeckSettings $deckRoot
        if ($deckSettings.AutoStart) { Start-DeckCompanion $suiteRoot }
    }
} catch { Write-Warning "Codex Deck could not attach: $($_.Exception.Message)" }
$deckInteractiveConversation = $codexConversation -and (-not $CodexArgs -or $CodexArgs[0] -notin @('exec','e'))
if ($deckInteractiveConversation -and $deckSettings -and $deckSettings.AutoCompactLaunchEnabled) { $AutoCompact=$true }
function Open-DeckLaunchInspector {
    if (-not $deckInteractiveConversation -or -not $deckSettings) { return }
    try {
        if($deckSettings.TrajectoryEnabled -and $deckSettings.ContextManagerEnabled -and $deckSettings.ContextManagerAutoOpen -and $failoverProxy -and $failoverProxy.ContextUrl){
            [void](Open-DeckInspector $suiteRoot 'Trajectory' -Companion -SessionPath $deckSession)
            Write-Host 'Codex Deck Live Context companion opened for this conversation.'
        }elseif($deckSettings.TrajectoryEnabled -and -not $deckSettings.ContextManagerEnabled){
            [void](Open-DeckInspector $suiteRoot 'Trajectory')
            Write-Host 'Codex Deck Trajectory opened for this conversation.'
        }elseif(-not $deckSettings.TrajectoryEnabled -and $deckSettings.EfficiencyAnalyticsEnabled){
            [void](Open-DeckInspector $suiteRoot 'Efficiency')
            Write-Host 'Codex Deck Efficiency Analytics opened for this conversation.'
        }
    } catch { Write-Warning "Codex Deck inspector could not open: $($_.Exception.Message)" }
}
$failoverProxy = $null
$failoverSessions = @()
$codexExitCode = -1
$codexStartedAt = [DateTimeOffset]::Now
$deckCustomAutoCompact=$false
$nativeAutoCompactArgs=@()
$compactSettings=$null
$threshold=$null
if($AutoCompact){
    $compactSettings=if($deckSettings){$deckSettings}else{Get-DeckSettings (Join-Path $runtimeRoot 'deck')}
    $threshold=if($null -ne $autoCompactThresholdOverride){$autoCompactThresholdOverride}else{$compactSettings.AutoCompactThresholdPercent}
    $deckCustomAutoCompact=$compactSettings.AutoCompactMode -eq 'Custom'
    if(-not $deckCustomAutoCompact){
        $nativeCompact=Get-DeckNativeAutoCompactConfiguration $accountDir $CodexArgs $threshold
        $nativeAutoCompactArgs=@($nativeCompact.Arguments)
        Write-Host ("Codex native auto-compact ON at {0}% free ({1}% used): {2} tokens for {3}." -f $threshold,(100-$threshold),$nativeCompact.TokenLimit,$nativeCompact.Model)
    }
}
try {
    if ($deckCustomAutoCompact) {
        $clientPath = Join-Path $runtimeRoot 'Deck.AutoCompact.cjs'
        if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) { throw 'Deck.AutoCompact.cjs is missing. Reinstall Codex Deck.' }
        $codexCommand = Get-Command codex -ErrorAction Stop | Select-Object -First 1
        $codexExecutable = $codexCommand.Source
        $codexEntry = ''
        if ([IO.Path]::GetExtension($codexExecutable) -ne '.exe') {
            $codexEntry = Join-Path (Split-Path -Parent $codexExecutable) 'node_modules/@openai/codex/bin/codex.js'
            if (-not (Test-Path -LiteralPath $codexEntry -PathType Leaf)) { throw 'Auto-compact requires the native Codex executable or official npm installation on PATH.' }
            $codexExecutable = (Get-Command node.exe -ErrorAction Stop).Source
        }
        $handoffEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$compactSettings.AutoCompactHandoffPrompt))
        $clientArgs = @($clientPath,'--codex-exe',$codexExecutable,'--threshold',[string]$threshold,'--cwd',(Get-Location).Path,'--handoff-base64',$handoffEncoded)
        if ($codexEntry) { $clientArgs += @('--codex-entry',$codexEntry) }
        if ($CodexArgs) {
            $launchJson = ConvertTo-Json -InputObject ([object[]]@($CodexArgs)) -Compress -Depth 10
            $clientArgs += @('--launch-base64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($launchJson)))
        }
        if ($useRoutingProxy) {
            $environmentMembers = if ($poolConversation) { @($members) } else { @() }
            $failoverProxy = Start-DeckFailover -SuiteRoot $suiteRoot -Pool $failoverChoice.Pool -Mode $routeMode -Account $failoverChoice.Account -Environment $accountName -EnvironmentPool $environmentMembers -Automatic:$automaticFailover -ContextManagerEnabled:$deckSettings.ContextManagerEnabled -ContextManagerProtected:$deckSettings.ContextManagerProtected -AutoCompact:$AutoCompact -AutoCompactMode $compactSettings.AutoCompactMode -AutoCompactFreePercent $threshold
            Set-DeckSessionContext $deckSession $failoverProxy.ContextUrl
            if ($automaticFailover -or $poolConversation) {
                foreach ($poolAccount in $failoverChoice.Pool) {
                    $poolSession=Register-DeckSession (Join-Path $suiteRoot 'deck') $poolAccount (Get-Location).Path
                    Set-DeckSessionContext $poolSession $failoverProxy.ContextUrl
                    $failoverSessions += $poolSession
                }
            }
            $env:CODEX_DECK_SESSION_URL = $failoverProxy.BaseUrl
        }
        Open-DeckLaunchInspector
        $postConfigArgs = @($globalRuleArgs)
        if ($failoverProxy) { $postConfigArgs += @(Get-DeckSessionRoutingArguments $failoverProxy ([bool]$poolEntry)) }
        if ($postConfigArgs.Count) {
            $postConfigJson = ConvertTo-Json -InputObject ([object[]]$postConfigArgs) -Compress -Depth 10
            $clientArgs += @('--post-config-base64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($postConfigJson)))
        }
        if ($CodexArgs -and $CodexArgs[0] -in @('exec','e')) {
            # A one-shot exec has no interactive TUI. Keep its existing worker path.
            $clientArgs += @('--') + @($sharedArgs)
            & node.exe @clientArgs
            $codexExitCode = $LASTEXITCODE
        } else {
            $sidecarPath = Join-Path $runtimeRoot 'Deck.AutoCompact.Sidecar.cjs'
            if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) { throw 'Deck.AutoCompact.Sidecar.cjs is missing. Reinstall Codex Deck.' }
            $serverConfigJson = ConvertTo-Json -InputObject ([object[]](@($sharedArgs) + @($postConfigArgs))) -Compress -Depth 10
            $serverConfigEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serverConfigJson))
            $sidecarArgs = @($sidecarPath,'--codex-exe',$codexExecutable,'--threshold',[string]$threshold,'--cwd',(Get-Location).Path,'--handoff-base64',$handoffEncoded,'--server-config-base64',$serverConfigEncoded)
            if ($codexEntry) { $sidecarArgs += @('--codex-entry',$codexEntry) }
            $nodeExecutable = (Get-Command node.exe -ErrorAction Stop).Source
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $nodeExecutable
            $startInfo.Arguments = ($sidecarArgs | ForEach-Object { ConvertTo-DeckWindowsArgument ([string]$_) }) -join ' '
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $observer = [Diagnostics.Process]::Start($startInfo)
            try {
                $ready = $observer.StandardOutput.ReadLine()
                if ($ready -notmatch '^READY (ws://127\.0\.0\.1:\d+)$') {
                    $detail = if ($ready) { $ready } else { $observer.StandardError.ReadToEnd() }
                    throw "Could not start Deck auto-compact observer: $detail"
                }
                $remoteUrl = $Matches[1]
                $launchArgs = @($sharedArgs) + @($CodexArgs) + @($globalRuleArgs)
                if ($failoverProxy) { $launchArgs += @(Get-DeckSessionRoutingArguments $failoverProxy ([bool]$poolEntry)) }
                $launchArgs += @('--remote',$remoteUrl)
                Invoke-DeckCodex $launchArgs
                $codexExitCode = $LASTEXITCODE
            } finally {
                try { $observer.StandardInput.Close() } catch {}
                if (-not $observer.WaitForExit(3000)) { $observer.Kill(); [void]$observer.WaitForExit(3000) }
                $observerLog = $observer.StandardError.ReadToEnd().Trim()
                if ($observerLog) {
                    if ($observer.ExitCode -ne 0) { Write-Warning $observerLog }
                    else { Write-Host $observerLog }
                }
                $observer.Dispose()
            }
        }
    } elseif ($useRoutingProxy) {
        $environmentMembers = if ($poolConversation) { @($members) } else { @() }
        $failoverProxy = Start-DeckFailover -SuiteRoot $suiteRoot -Pool $failoverChoice.Pool -Mode $routeMode -Account $failoverChoice.Account -Environment $accountName -EnvironmentPool $environmentMembers -Automatic:$automaticFailover -ContextManagerEnabled:$deckSettings.ContextManagerEnabled -ContextManagerProtected:$deckSettings.ContextManagerProtected -AutoCompact:$AutoCompact -AutoCompactMode $compactSettings.AutoCompactMode -AutoCompactFreePercent $threshold
        Set-DeckSessionContext $deckSession $failoverProxy.ContextUrl
        if ($automaticFailover -or $poolConversation) {
            foreach ($poolAccount in $failoverChoice.Pool) {
                $poolSession=Register-DeckSession (Join-Path $suiteRoot 'deck') $poolAccount (Get-Location).Path
                Set-DeckSessionContext $poolSession $failoverProxy.ContextUrl
                $failoverSessions += $poolSession
            }
        }
        $env:CODEX_DECK_SESSION_URL = $failoverProxy.BaseUrl
        Open-DeckLaunchInspector
        $launchArgs = @($sharedArgs) + @($nativeAutoCompactArgs) + @($CodexArgs) + @($globalRuleArgs) + @(Get-DeckSessionRoutingArguments $failoverProxy ([bool]$poolEntry))
        Invoke-DeckCodex $launchArgs
        $codexExitCode = $LASTEXITCODE
    } else {
        Open-DeckLaunchInspector
        $launchArgs=@($sharedArgs)+@($nativeAutoCompactArgs)+@($CodexArgs)+@($globalRuleArgs)
        Invoke-DeckCodex $launchArgs
        $codexExitCode = $LASTEXITCODE
    }
} finally {
    $env:CODEX_HOME = $originalCodexHome
    $env:CODEX_DECK_SESSION_URL = $originalDeckSessionUrl
    $env:CODEX_DECK_SESSION_PATH = $originalDeckSessionPath
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
