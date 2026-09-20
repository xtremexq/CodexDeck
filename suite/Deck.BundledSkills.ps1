# Deck-provided skills are stored once under <suite>/skills and exposed to
# account and pool CODEX_HOME directories through verified junctions.
function Assert-DeckBundledSkillName([string]$Name) {
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$' -and $Name -notmatch '^[a-z0-9]$') { throw 'Invalid Deck skill name.' }
}

function Get-DeckBundledSkillCatalogRoot([string]$SuiteRoot) {
    $root=Join-Path $SuiteRoot 'skills'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $item=Get-Item -LiteralPath $root -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The Deck skill catalog must be a real directory.' }
    return $item.FullName
}

function Get-DeckBundledSkills([string]$SuiteRoot) {
    $root=Get-DeckBundledSkillCatalogRoot $SuiteRoot
    if (-not $root) { return @() }
    $skills=@()
    foreach($directory in Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name) {
        $manifestPath=Join-Path $directory.FullName '.codexdeck.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        Assert-DeckBundledSkillName $directory.Name
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Deck skill $($directory.Name) cannot be a linked directory." }
        $skillPath=Join-Path $directory.FullName 'SKILL.md'
        foreach($path in @($manifestPath,$skillPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Deck skill $($directory.Name) is incomplete." }
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Deck skill $($directory.Name) contains linked metadata." }
        }
        $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -ErrorAction Stop
        if ($manifest.Version -ne 1 -or $manifest.Name -cne $directory.Name -or
            [string]::IsNullOrWhiteSpace([string]$manifest.DisplayName) -or
            [string]::IsNullOrWhiteSpace([string]$manifest.Description) -or
            $manifest.DefaultEnabled -isnot [bool]) { throw "Deck skill $($directory.Name) has invalid catalog metadata." }
        $skills += [pscustomobject]@{
            Name=$directory.Name
            DisplayName=[string]$manifest.DisplayName
            Description=[string]$manifest.Description
            DefaultEnabled=[bool]$manifest.DefaultEnabled
            Path=$directory.FullName
        }
    }
    return $skills
}

function Get-DeckBundledSkillState([string]$SuiteRoot,[string]$Entry) {
    $directory=Get-DeckEntryDirectory $SuiteRoot $Entry
    $path=Join-Path $directory '.codexdeck-skills.json'
    $state=Read-DeckEnvironmentJson $path
    if (-not $state) { return [pscustomobject]@{Version=1;Overrides=@()} }
    if ($state.Version -ne 1) { throw 'Unsupported Deck skill settings.' }
    $seen=@{}
    foreach($override in @($state.Overrides)) {
        Assert-DeckBundledSkillName ([string]$override.Name)
        if ($override.Enabled -isnot [bool] -or $seen.ContainsKey([string]$override.Name)) { throw 'Invalid Deck skill override.' }
        $seen[[string]$override.Name]=$true
    }
    return [pscustomobject]@{Version=1;Overrides=@($state.Overrides)}
}

function Test-DeckBundledSkillDesired([string]$SuiteRoot,[string]$Entry,$Skill) {
    $state=Get-DeckBundledSkillState $SuiteRoot $Entry
    $override=@($state.Overrides | Where-Object Name -CEQ $Skill.Name | Select-Object -First 1)
    if ($override.Count) { return [bool]$override[0].Enabled }
    return [bool]$Skill.DefaultEnabled
}

function Test-DeckBundledSkillLink([string]$Target,[string]$Source) {
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { return $false }
    $item=Get-Item -LiteralPath $Target -Force
    if ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1) { return $false }
    return [IO.Path]::GetFullPath([string]@($item.Target)[0]).TrimEnd('\') -eq [IO.Path]::GetFullPath($Source).TrimEnd('\')
}

function Get-DeckBundledSkillStatus([string]$SuiteRoot,[string]$Entry,$Skill) {
    $directory=Get-DeckEntryDirectory $SuiteRoot $Entry
    $target=Join-Path $directory ('skills/'+$Skill.Name)
    $desired=Test-DeckBundledSkillDesired $SuiteRoot $Entry $Skill
    $managed=Test-DeckBundledSkillLink $target $Skill.Path
    $exists=Test-Path -LiteralPath $target
    $binding=@((Get-DeckSharing $SuiteRoot $Entry).Bindings | Where-Object { $_.Resource -in @('skills','skills/'+$Skill.Name) } | Select-Object -First 1)
    $blocked=''
    if($binding.Count){$blocked="Managed through resource sharing from $($binding[0].Source)."}
    elseif($exists -and -not $managed){$blocked='A user-owned skill with this name already exists.'}
    return [pscustomobject]@{
        Name=$Skill.Name;Desired=$desired;Active=$managed;Exists=[bool]$exists
        Blocked=[bool]$blocked;BlockedReason=$blocked;Target=$target
    }
}

function Set-DeckBundledSkillEnabled([string]$SuiteRoot,[string]$Entry,[string]$SkillName,[bool]$Enabled,[switch]$ValidateOnly) {
    Assert-DeckBundledSkillName $SkillName
    $skill=@(Get-DeckBundledSkills $SuiteRoot | Where-Object Name -CEQ $SkillName | Select-Object -First 1)
    if (-not $skill.Count) { throw "Unknown Deck skill: $SkillName" }
    $skill=$skill[0]
    $directory=Get-DeckEntryDirectory $SuiteRoot $Entry
    $status=Get-DeckBundledSkillStatus $SuiteRoot $Entry $skill
    if ($status.Blocked) { throw "$Entry / ${SkillName}: $($status.BlockedReason) Deck did not change it." }
    $skillsDirectory=Join-Path $directory 'skills'
    if (Test-Path -LiteralPath $skillsDirectory) {
        $skillsItem=Get-Item -LiteralPath $skillsDirectory -Force
        if (-not $skillsItem.PSIsContainer -or ($skillsItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "$Entry has a shared or invalid skills directory. Manage Deck skills on its source environment." }
    }
    if ($ValidateOnly) { return }

    $state=Get-DeckBundledSkillState $SuiteRoot $Entry
    $overrides=@($state.Overrides | Where-Object Name -CNE $SkillName)
    $overrides+=@([pscustomobject]@{Name=$SkillName;Enabled=$Enabled})
    $updated=[pscustomobject]@{Version=1;Overrides=@($overrides | Sort-Object Name)}
    $statePath=Join-Path $directory '.codexdeck-skills.json'
    $created=$false; $removed=$false
    try {
        if ($Enabled -and -not $status.Active) {
            [void][IO.Directory]::CreateDirectory($skillsDirectory)
            [void](New-Item -ItemType Junction -Path $status.Target -Target $skill.Path)
            $created=$true
        } elseif (-not $Enabled -and $status.Active) {
            [IO.Directory]::Delete($status.Target)
            $removed=$true
        }
        Write-DeckEnvironmentJson $statePath $updated
    } catch {
        if ($created -and (Test-DeckBundledSkillLink $status.Target $skill.Path)) { [IO.Directory]::Delete($status.Target) }
        elseif ($removed -and -not (Test-Path -LiteralPath $status.Target)) { [void](New-Item -ItemType Junction -Path $status.Target -Target $skill.Path) }
        throw
    }
    return "${Entry}: Deck skill $SkillName $(if($Enabled){'enabled'}else{'disabled'}). Start a new Codex session to apply it."
}

function Sync-DeckBundledSkills([string]$SuiteRoot,[string]$Entry) {
    $directory=Get-DeckEntryDirectory $SuiteRoot $Entry
    $skillsDirectory=Join-Path $directory 'skills'
    if (Test-Path -LiteralPath $skillsDirectory) {
        $skillsItem=Get-Item -LiteralPath $skillsDirectory -Force
        if (-not $skillsItem.PSIsContainer -or ($skillsItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return "${Entry}: skipped Deck skills because the whole skills directory is shared or invalid."
        }
    }
    $messages=@()
    foreach($skill in Get-DeckBundledSkills $SuiteRoot) {
        $status=Get-DeckBundledSkillStatus $SuiteRoot $Entry $skill
        if ($status.Blocked) {
            if($status.Desired){$messages+="$Entry / $($skill.Name): $($status.BlockedReason)"}
            continue
        }
        if ($status.Desired -and -not $status.Active) {
            [void][IO.Directory]::CreateDirectory($skillsDirectory)
            [void](New-Item -ItemType Junction -Path $status.Target -Target $skill.Path)
        } elseif (-not $status.Desired -and $status.Active) {
            [IO.Directory]::Delete($status.Target)
        }
    }
    return $messages
}

function Sync-DeckBundledSkillsForAllEntries([string]$SuiteRoot) {
    foreach($entry in Get-DeckEntryNames $SuiteRoot) {
        try { Sync-DeckBundledSkills $SuiteRoot $entry }
        catch { "${entry}: $($_.Exception.Message)" }
    }
}
