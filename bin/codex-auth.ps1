[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Account,

    [Alias('Delete')]
    [switch]$Del,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CodexArgs
)

$accountsRoot = Join-Path $HOME ".codex-loop\accounts"
$defaultConfigPath = Join-Path $HOME ".codex\config.toml"
$ErrorActionPreference = 'Stop'

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

    return @(Get-ChildItem -LiteralPath $accountsRoot -Directory | Sort-Object Name)
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

function Ensure-SharedAgentsLink {
    param([string]$AccountDir)

    $sharedAgentsPath = Join-Path $accountsRoot "AGENTS.shared.md"

    if (-not (Test-Path -LiteralPath $sharedAgentsPath -PathType Leaf)) {
        Write-TextFile -Path $sharedAgentsPath -Content ""
    }

    $accountAgentsPath = Join-Path $AccountDir "AGENTS.md"

    if (Test-Path -LiteralPath $accountAgentsPath -PathType Container) {
        throw "Expected file path at '$accountAgentsPath' but found a directory."
    }

    $needsLink = $true

    if (Test-Path -LiteralPath $accountAgentsPath -PathType Leaf) {
        try {
            $sharedResolved = (Resolve-Path -LiteralPath $sharedAgentsPath).Path
            $accountResolved = (Resolve-Path -LiteralPath $accountAgentsPath).Path
            $links = & fsutil hardlink list $sharedResolved 2>$null

            if ($LASTEXITCODE -eq 0) {
                foreach ($link in $links) {
                    $resolvedLink = (Resolve-Path -LiteralPath $link -ErrorAction SilentlyContinue).Path

                    if ($resolvedLink -eq $accountResolved) {
                        $needsLink = $false
                        break
                    }
                }
            }
        } catch {
            $needsLink = $true
        }

        if ($needsLink) {
            Remove-Item -LiteralPath $accountAgentsPath -Force
        }
    }

    if (-not $needsLink) {
        return
    }

    New-Item -ItemType HardLink -Path $accountAgentsPath -Target $sharedAgentsPath | Out-Null
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
        return [pscustomobject]@{
            Created = $false
            Source = $null
            SkipConfigSync = $false
        }
    }

    New-Item -ItemType Directory -Path $AccountDir -Force | Out-Null

    foreach ($relativeDirectory in @("log", "memories", "sessions", "tmp", ".tmp")) {
        New-Item -ItemType Directory -Path (Join-Path $AccountDir $relativeDirectory) -Force | Out-Null
    }

    $bootstrapSource = Get-AccountBootstrapSource -ExcludePath $AccountDir
    $seededFromDefaultConfig = $false

    if ($bootstrapSource) {
        $bootstrapConfigPath = Join-Path $bootstrapSource.Path "config.toml"
        $bootstrapConfig = Read-TextFile $bootstrapConfigPath

        if (-not [string]::IsNullOrWhiteSpace($bootstrapConfig)) {
            Write-TextFile `
                -Path (Join-Path $AccountDir "config.toml") `
                -Content ("$(Trim-TrailingNewlines $bootstrapConfig)`n")

            $resolvedBootstrapConfigPath = (Resolve-Path -LiteralPath $bootstrapConfigPath -ErrorAction SilentlyContinue).Path
            $resolvedDefaultConfigPath = (Resolve-Path -LiteralPath $defaultConfigPath -ErrorAction SilentlyContinue).Path
            $seededFromDefaultConfig = $resolvedBootstrapConfigPath -and $resolvedBootstrapConfigPath -eq $resolvedDefaultConfigPath
        }

        foreach ($relativePath in @(
            ".personality_migration",
            "rules",
            "skills"
        )) {
            Copy-BootstrapItem `
                -SourceRoot $bootstrapSource.Path `
                -DestinationRoot $AccountDir `
                -RelativePath $relativePath
        }
    }

    if (-not $seededFromDefaultConfig) {
        Ensure-AccountConfig -AccountDir $AccountDir
    }

    Ensure-SharedAgentsLink -AccountDir $AccountDir

    return [pscustomobject]@{
        Created = $true
        Source = $bootstrapSource
        SkipConfigSync = $seededFromDefaultConfig
    }
}

function Show-Usage {
    Write-Host "Usage: codex-auth [dashboard|status|accountN|N|list] [codex args...]"
    Write-Host "  codex-auth          Interactive account dashboard"
    Write-Host "  codex-auth status   Cached dashboard snapshot (no network)"
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
        Ensure-AccountConfig -AccountDir $directory.FullName
        Ensure-FreeAccountDefaults -AccountDir $directory.FullName
        Ensure-SharedAgentsLink -AccountDir $directory.FullName
        $hasAuth = Test-Path -LiteralPath (Join-Path $directory.FullName "auth.json") -PathType Leaf
        $marker = if ($hasAuth) { "*" } else { "-" }
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

$bootstrapResult = Initialize-AccountDirectory -AccountName $accountName -AccountDir $accountDir

if ($bootstrapResult.Created) {
    if ($bootstrapResult.Source) {
        Write-Host ("Created {0} from {1}." -f $accountName, $bootstrapResult.Source.Label)
    } else {
        Write-Host ("Created {0}." -f $accountName)
    }
}

if (-not $bootstrapResult.SkipConfigSync) {
    Ensure-AccountConfig -AccountDir $accountDir
}

Ensure-SharedAgentsLink -AccountDir $accountDir
Ensure-FreeAccountDefaults -AccountDir $accountDir
Use-CodexNodePath
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
try {
    & codex @CodexArgs
    $codexExitCode = $LASTEXITCODE
} finally {
    if ($deckSession -and (Test-Path -LiteralPath $deckSession)) {
        Remove-Item -LiteralPath $deckSession -ErrorAction SilentlyContinue
    }
}
# Login may have identified a newly created account's plan for the first time.
Ensure-FreeAccountDefaults -AccountDir $accountDir
exit $codexExitCode
