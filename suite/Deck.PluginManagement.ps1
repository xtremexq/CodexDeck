# Codex Deck installs plugins into one private CODEX_HOME, then imports their
# skills into the existing managed catalog. Plugin content remains user-managed
# runtime data and is never added to the Deck release bundle.
function Assert-DeckPluginSelector([string]$Selector) {
    if ([string]::IsNullOrWhiteSpace($Selector) -or $Selector.Length -gt 180 -or
        $Selector -notmatch '^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*@[A-Za-z0-9_-]+$') {
        throw 'Use a plugin selector such as plugin-name@marketplace-name.'
    }
}

function Assert-DeckMarketplaceSource([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Source) -or $Source.Length -gt 1000 -or
        $Source.Contains("`r") -or $Source.Contains("`n") -or $Source.StartsWith('-')) {
        throw 'Enter a local path, owner/repository, or Git URL for the marketplace.'
    }
}

function Get-DeckPluginHome([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'plugin-store'
    [void][IO.Directory]::CreateDirectory($path)
    return (Get-Item -LiteralPath $path).FullName
}

function Get-DeckManagedPluginState([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'deck/managed-plugins.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{Version=1;Marketplaces=@();Plugins=@()}
    }
    $state=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ($state.Version -ne 1) { throw 'Unsupported managed plugin state.' }
    return [pscustomobject]@{Version=1;Marketplaces=@($state.Marketplaces);Plugins=@($state.Plugins)}
}

function Write-DeckManagedPluginState([string]$SuiteRoot,$State) {
    Write-DeckEnvironmentJson (Join-Path $SuiteRoot 'deck/managed-plugins.json') ([ordered]@{
        Version=1
        Marketplaces=@($State.Marketplaces)
        Plugins=@($State.Plugins)
    })
}

function Invoke-DeckPluginCli([string]$SuiteRoot,[string[]]$Arguments) {
    if (-not $Arguments.Count) { throw 'A Codex plugin command is required.' }
    $command=Get-Command codex -ErrorAction Stop | Select-Object -First 1
    $previousHome=$env:CODEX_HOME
    try {
        $env:CODEX_HOME=Get-DeckPluginHome $SuiteRoot
        $output=@(& $command.Source plugin @Arguments)
        $exitCode=$LASTEXITCODE
    } finally {
        $env:CODEX_HOME=$previousHome
    }
    if ($exitCode -ne 0) { throw "Codex plugin command failed with exit code $exitCode." }
    return ($output -join "`n").Trim()
}

function Get-DeckPluginSkillMetadata([string]$SkillDirectory) {
    $name=(Get-Item -LiteralPath $SkillDirectory).Name
    Assert-DeckBundledSkillName $name
    $skillPath=Join-Path $SkillDirectory 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { throw "Plugin skill $name has no SKILL.md." }
    $text=[IO.File]::ReadAllText($skillPath)
    $frontMatter=''
    if ($text -match '(?s)^---\s*\r?\n(?<front>.*?)\r?\n---(?:\r?\n|$)') { $frontMatter=$Matches.front }
    $declaredName=$name
    if ($frontMatter -match '(?m)^name:\s*["'']?(?<value>[^"''\r\n]+)') { $declaredName=$Matches.value.Trim() }
    if ($declaredName -cne $name) { throw "Plugin skill folder '$name' does not match its declared name '$declaredName'." }
    $description='Installed from a Codex plugin.'
    if ($frontMatter -match '(?m)^description:\s*["'']?(?<value>[^\r\n]+)') { $description=$Matches.value.Trim().Trim('"').Trim("'") }
    if ($description.Length -gt 1000) { $description=$description.Substring(0,997)+'...' }
    $displayName=([Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase(($name -replace '[-_]',' ')))
    return [pscustomobject]@{Name=$name;DisplayName=$displayName;Description=$description;Path=$SkillDirectory}
}

function Get-DeckPluginSkillTreeHash([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Plugin skill directory missing.' }
    $lines=@(foreach($item in Get-ChildItem -LiteralPath $Directory -Recurse -Force -File | Sort-Object FullName) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked plugin skill files are not supported.' }
        if ($item.Name -in @('.codexdeck.json','.codexdeck-plugin.json')) { continue }
        $relative=$item.FullName.Substring($Directory.Length).TrimStart('\','/').Replace('\','/')
        "$relative $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
    })
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','') }
    finally { $sha.Dispose() }
}

function Get-DeckPluginSkillReceipt([string]$SuiteRoot,[string]$Name) {
    Assert-DeckBundledSkillName $Name
    $path=Join-Path $SuiteRoot "skills/$Name/.codexdeck-plugin.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $receipt=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.schema -ne 1 -or $receipt.name -cne $Name -or
        [string]$receipt.pluginId -notmatch '^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*@[A-Za-z0-9_-]+$' -or
        [string]$receipt.treeHash -notmatch '^[A-Fa-f0-9]{64}$') { throw "Invalid plugin receipt for $Name." }
    return $receipt
}

function Assert-DeckPluginSkillTree([string]$Directory) {
    $items=@(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
    if ($items.Count -gt 600 -or (@($items | Where-Object {-not $_.PSIsContainer} | Measure-Object Length -Sum)[0].Sum) -gt 25000000) {
        throw 'A plugin skill exceeds Deck limits.'
    }
    foreach($item in $items) { if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A plugin skill contains a link.' } }
}

function Import-DeckPluginSkills([string]$SuiteRoot,[string]$PluginId,[string]$Version,[string]$PluginRoot) {
    Assert-DeckPluginSelector $PluginId
    if (-not (Test-Path -LiteralPath $PluginRoot -PathType Container)) { throw 'Codex did not return an installed plugin directory.' }
    $sourceRoot=Join-Path $PluginRoot 'skills'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Plugin $PluginId does not contain skills." }
    $sources=@(Get-ChildItem -LiteralPath $sourceRoot -Directory -Force | Sort-Object Name)
    if (-not $sources.Count) { throw "Plugin $PluginId does not contain skills." }
    $catalogRoot=Get-DeckBundledSkillCatalogRoot $SuiteRoot
    if (-not $catalogRoot) { [void][IO.Directory]::CreateDirectory((Join-Path $SuiteRoot 'skills')); $catalogRoot=Get-DeckBundledSkillCatalogRoot $SuiteRoot }
    $metadata=@($sources | ForEach-Object { Assert-DeckPluginSkillTree $_.FullName; Get-DeckPluginSkillMetadata $_.FullName })
    foreach($skill in $metadata) {
        $target=Join-Path $catalogRoot $skill.Name
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $receipt=Get-DeckPluginSkillReceipt $SuiteRoot $skill.Name
        if (-not $receipt -or $receipt.pluginId -cne $PluginId) { throw "Skill $($skill.Name) already exists; Deck will not overwrite it." }
        if ((Get-DeckPluginSkillTreeHash $target) -cne [string]$receipt.treeHash) { throw "Skill $($skill.Name) has local edits. Preserve them before updating the plugin." }
    }

    $stage=Join-Path $catalogRoot ('.plugin-stage-'+[guid]::NewGuid().ToString('N'))
    $backupRoot=Join-Path $SuiteRoot ('deck/skill-backups/plugin-'+[guid]::NewGuid().ToString('N'))
    $installed=[Collections.Generic.List[object]]::new()
    $moved=[Collections.Generic.List[object]]::new()
    try {
        [void][IO.Directory]::CreateDirectory($stage)
        foreach($skill in $metadata) {
            $staged=Join-Path $stage $skill.Name
            Copy-Item -LiteralPath $skill.Path -Destination $staged -Recurse
            $manifest=[ordered]@{Version=1;Name=$skill.Name;DisplayName=$skill.DisplayName;Description=$skill.Description;DefaultEnabled=$true;Source='plugin';PluginId=$PluginId}
            [IO.File]::WriteAllText((Join-Path $staged '.codexdeck.json'),(ConvertTo-Json -Compress -InputObject $manifest),[Text.UTF8Encoding]::new($false))
            $hash=Get-DeckPluginSkillTreeHash $staged
            $receipt=[ordered]@{schema=1;name=$skill.Name;pluginId=$PluginId;version=$Version;treeHash=$hash;installedAt=[DateTimeOffset]::UtcNow.ToString('o')}
            [IO.File]::WriteAllText((Join-Path $staged '.codexdeck-plugin.json'),(ConvertTo-Json -Compress -InputObject $receipt),[Text.UTF8Encoding]::new($false))
            $installed.Add([pscustomobject]@{Name=$skill.Name;DisplayName=$skill.DisplayName;Description=$skill.Description;TreeHash=$hash})
        }
        [void][IO.Directory]::CreateDirectory($backupRoot)
        foreach($skill in $metadata) {
            $target=Join-Path $catalogRoot $skill.Name
            $backup=Join-Path $backupRoot $skill.Name
            if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $backup }
            $moved.Add([pscustomobject]@{Target=$target;Backup=$backup;HadBackup=(Test-Path -LiteralPath $backup)})
            Move-Item -LiteralPath (Join-Path $stage $skill.Name) -Destination $target
        }
    } catch {
        foreach($item in @($moved | Select-Object -Last 100)) {
            if (Test-Path -LiteralPath $item.Target) { Remove-Item -LiteralPath $item.Target -Recurse -Force }
            if ($item.HadBackup -and (Test-Path -LiteralPath $item.Backup)) { Move-Item -LiteralPath $item.Backup -Destination $item.Target }
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        if ((Test-Path -LiteralPath $backupRoot) -and -not (Get-ChildItem -LiteralPath $backupRoot -Force | Select-Object -First 1)) { [IO.Directory]::Delete($backupRoot) }
    }
    foreach($warning in @(Sync-DeckBundledSkillsForAllEntries $SuiteRoot)) { if($warning){Write-Warning $warning} }
    return @($installed)
}

function Add-DeckPluginMarketplace([string]$SuiteRoot,[string]$Source,[string[]]$Options=@()) {
    Assert-DeckMarketplaceSource $Source
    $json=Invoke-DeckPluginCli $SuiteRoot (@('marketplace','add',$Source)+@($Options)+@('--json'))
    $result=$json | ConvertFrom-Json -ErrorAction Stop
    if ([string]$result.marketplaceName -notmatch '^[A-Za-z0-9_-]+$') { throw 'Codex returned an invalid marketplace name.' }
    $state=Get-DeckManagedPluginState $SuiteRoot
    $state.Marketplaces=@($state.Marketplaces | Where-Object Name -CNE ([string]$result.marketplaceName)) + @([pscustomobject]@{
        Name=[string]$result.marketplaceName;Source=$Source;AddedAt=[DateTimeOffset]::UtcNow.ToString('o')
    })
    Write-DeckManagedPluginState $SuiteRoot $state
    return "Marketplace $($result.marketplaceName) $(if($result.alreadyAdded){'already available'}else{'added'})."
}

function Add-DeckManagedPlugin([string]$SuiteRoot,[string]$Selector) {
    Assert-DeckPluginSelector $Selector
    $json=Invoke-DeckPluginCli $SuiteRoot @('add',$Selector,'--json')
    $result=$json | ConvertFrom-Json -ErrorAction Stop
    if ([string]$result.pluginId -cne $Selector -or -not $result.installedPath) { throw 'Codex returned an unexpected plugin install result.' }
    $skills=@(Import-DeckPluginSkills $SuiteRoot $Selector ([string]$result.version) ([string]$result.installedPath))
    $state=Get-DeckManagedPluginState $SuiteRoot
    $state.Plugins=@($state.Plugins | Where-Object Id -CNE $Selector) + @([pscustomobject]@{
        Id=$Selector;Name=[string]$result.name;Marketplace=[string]$result.marketplaceName;Version=[string]$result.version
        Skills=@($skills | ForEach-Object Name);InstalledAt=[DateTimeOffset]::UtcNow.ToString('o')
    })
    Write-DeckManagedPluginState $SuiteRoot $state
    return "$Selector $($result.version) installed with $($skills.Count) managed skill$(if($skills.Count -ne 1){'s'}). Start a new Codex session to use them."
}

function Invoke-DeckManagedPluginCommand([string]$SuiteRoot,[string[]]$Arguments) {
    if (-not $Arguments.Count -or $Arguments[0] -in @('help','--help','-h')) {
        return @(
            'Usage:'
            '  codex-auth plugin marketplace add <source> [--ref <ref>] [--sparse <path>]'
            '  codex-auth plugin add <plugin@marketplace>'
            '  codex-auth plugin list'
        ) -join "`n"
    }
    if ($Arguments[0] -eq 'marketplace' -and $Arguments.Count -ge 3 -and $Arguments[1] -eq 'add') {
        return Add-DeckPluginMarketplace $SuiteRoot ([string]$Arguments[2]) $(if($Arguments.Count -gt 3){@($Arguments[3..($Arguments.Count-1)])}else{@()})
    }
    if ($Arguments[0] -eq 'add' -and $Arguments.Count -eq 2) { return Add-DeckManagedPlugin $SuiteRoot ([string]$Arguments[1]) }
    if ($Arguments[0] -eq 'list' -and $Arguments.Count -eq 1) {
        $state=Get-DeckManagedPluginState $SuiteRoot
        if (-not @($state.Plugins).Count) { return 'No Deck-managed plugins are installed.' }
        return (@($state.Plugins | ForEach-Object { "{0} {1} ({2})" -f $_.Id,$_.Version,(@($_.Skills) -join ', ') }) -join "`n")
    }
    throw 'Supported commands are plugin marketplace add, plugin add, and plugin list.'
}

function Get-DeckPluginWorkerCode([string]$SuiteRoot,[ValidateSet('marketplace','plugin')][string]$Mode,[string]$Value) {
    $root=$SuiteRoot.Replace("'","''")
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    $action=if($Mode -eq 'marketplace'){"Add-DeckPluginMarketplace '$root' `$value"}else{"Add-DeckManagedPlugin '$root' `$value"}
    return "`$ErrorActionPreference='Stop'`ntry{. '$root/Deck.Core.ps1'; `$value=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')); $action}catch{[Console]::Error.WriteLine(`$_.Exception.Message);exit 1}"
}
