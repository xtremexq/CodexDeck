# AAS discovery uses inert metadata. Only a selected, pinned skill subtree is fetched.
function Assert-DeckCatalogName([string]$Name) {
    Assert-DeckBundledSkillName $Name
}
function Get-DeckCatalogFile([string]$SuiteRoot) {
    $cached=Join-Path $SuiteRoot 'deck/catalog/aas-index.json'
    if(Test-Path -LiteralPath $cached -PathType Leaf){return $cached}
    return Join-Path $SuiteRoot 'skill-catalog/aas-index.json'
}
function Read-DeckAasCatalog([string]$SuiteRoot) {
    $path=Get-DeckCatalogFile $SuiteRoot
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'The AAS catalog is missing. Reinstall Codex Deck.'}
    $stamp=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    if($script:deckAasCatalogCache -and $script:deckAasCatalogCache.Path -ceq $path -and $script:deckAasCatalogCache.Stamp -eq $stamp){return $script:deckAasCatalogCache.Value}
    $catalog=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if($catalog.schema -ne 1 -or $catalog.repository -cne 'sickn33/agentic-awesome-skills' -or
       [string]$catalog.commit -notmatch '^[a-f0-9]{40}$' -or @($catalog.skills).Count -lt 1000){throw 'Invalid AAS catalog.'}
    $script:deckAasCatalogCache=@{Path=$path;Stamp=$stamp;Value=$catalog}
    $script:deckAasSearchIndex=$null
    return $catalog
}
function Search-DeckAasSkills([string]$SuiteRoot,[string]$Query='', [string]$Category='', [string]$Risk='', [int]$Limit=60) {
    $catalog=Read-DeckAasCatalog $SuiteRoot
    $maximum=[Math]::Max(1,[Math]::Min(500,$Limit))
    if(-not $Query.Trim()){
        $count=0
        foreach($skill in $catalog.skills){
            if($Category -and $skill.category -cne $Category){continue}
            if($Risk -and $skill.risk -cne $Risk){continue}
            $skill
            $count++
            if($count -ge $maximum){break}
        }
        return
    }
    if(-not $script:deckAasSearchIndex){
        $index=[System.Collections.Generic.List[object]]::new()
        foreach($skill in $catalog.skills){
            $blob=([string]$skill.id+' '+[string]$skill.name+' '+[string]$skill.description+' '+[string]$skill.category+' '+(@($skill.tags) -join ' ')).ToLowerInvariant()
            $index.Add([pscustomobject]@{Skill=$skill;Text=$blob;Category=[string]$skill.category;Risk=[string]$skill.risk})
        }
        $script:deckAasSearchIndex=$index
    }
    $terms=@($Query.Trim().ToLowerInvariant() -split '\s+' | Where-Object {$_})
    $count=0
    foreach($row in $script:deckAasSearchIndex){
        if($Category -and $row.Category -cne $Category){continue}
        if($Risk -and $row.Risk -cne $Risk){continue}
        $matched=$true
        foreach($term in $terms){if($row.Text.IndexOf($term,[StringComparison]::Ordinal) -lt 0){$matched=$false;break}}
        if(-not $matched){continue}
        $row.Skill
        $count++
        if($count -ge $maximum){break}
    }
}
function Get-DeckAasSkill([string]$SuiteRoot,[string]$Id) {
    $skill=@((Read-DeckAasCatalog $SuiteRoot).skills | Where-Object id -CEQ $Id | Select-Object -First 1)
    if(-not $skill.Count){throw "Unknown AAS skill: $Id"}
    return $skill[0]
}
function ConvertTo-DeckAasCatalog($Raw,[string]$Commit) {
    if($Commit -notmatch '^[a-f0-9]{40}$' -or @($Raw).Count -lt 1000){throw 'The upstream AAS index is incomplete.'}
    $seen=@{}
    $skills=@(foreach($entry in $Raw){
        $id=[string]$entry.id; $path=[string]$entry.path
        if(-not $id -or $seen.ContainsKey($id) -or $path -notmatch '^skills/(?:[a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$' -or $path.Contains('..')){throw 'Unsafe or duplicate AAS catalog entry.'}
        $seen[$id]=$true
        [ordered]@{id=$id;path=$path;name=[string]$entry.name;category=[string]$entry.category;description=[string]$entry.description;risk=[string]$entry.risk;source=[string]$entry.source;tags=@($entry.tags);setupType=[string]$entry.plugin.setup.type;setupSummary=[string]$entry.plugin.setup.summary;license=[string]$entry.license}
    })
    return [ordered]@{schema=1;repository='sickn33/agentic-awesome-skills';commit=$Commit;fetchedAt=[DateTimeOffset]::UtcNow.ToString('o');skills=$skills}
}
function Update-DeckAasCatalog([string]$SuiteRoot) {
    $remote='https://github.com/sickn33/agentic-awesome-skills.git'
    $line=@(& git ls-remote $remote refs/heads/main)
    if($LASTEXITCODE -ne 0 -or -not $line.Count -or $line[0] -notmatch '^([a-f0-9]{40})\s'){throw 'Could not resolve the AAS main commit.'}
    $commit=$Matches[1]
    $uri="https://raw.githubusercontent.com/sickn33/agentic-awesome-skills/$commit/skills_index.json"
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('deck-aas-'+[guid]::NewGuid().ToString('N')+'.json')
    try{
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $temporary -ErrorAction Stop
        $raw=[IO.File]::ReadAllText($temporary) | ConvertFrom-Json -ErrorAction Stop
        $catalog=ConvertTo-DeckAasCatalog $raw $commit
        $path=Join-Path $SuiteRoot 'deck/catalog/aas-index.json'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        Write-DeckEnvironmentJson $path $catalog
        return "AAS catalog updated: $(@($catalog.skills).Count) skills at $commit."
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}
function Get-DeckSkillTreeHash([string]$Directory) {
    if(-not (Test-Path -LiteralPath $Directory -PathType Container)){throw 'Skill directory missing.'}
    $lines=@(foreach($item in Get-ChildItem -LiteralPath $Directory -Recurse -Force -File | Sort-Object FullName){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked skill files are not supported.'}
        if($item.Name -in @('.codexdeck-source.json','.codexdeck.json')){continue}
        $relative=$item.FullName.Substring($Directory.Length).TrimStart('\','/').Replace('\','/')
        "$relative $((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
    })
    $bytes=[Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
}
function Assert-DeckCatalogCleanupPath([string]$Target,[string]$Root,[string]$Prefix) {
    $full=[IO.Path]::GetFullPath($Target).TrimEnd('\')
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if(-not $full.StartsWith($base+'\'+$Prefix,[StringComparison]::OrdinalIgnoreCase) -or
       [IO.Path]::GetDirectoryName($full) -cne $base){throw 'Refusing cleanup outside the catalog staging directory.'}
}
function Get-DeckManagedSkillReceipt([string]$SuiteRoot,[string]$Name) {
    Assert-DeckCatalogName $Name
    $path=Join-Path $SuiteRoot "skills/$Name/.codexdeck-source.json"
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    $receipt=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if($receipt.schema -ne 1 -or $receipt.name -cne $Name -or
       $receipt.repository -notin @('uizze/uizze','sickn33/agentic-awesome-skills') -or
       [string]$receipt.commit -notmatch '^[a-f0-9]{40}$' -or
       [string]$receipt.treeHash -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Invalid managed skill receipt.'}
    return $receipt
}
function Install-DeckCatalogSkill([string]$SuiteRoot,[string]$Name,[string]$Repository,[string]$Path,[string]$Commit,[string]$DisplayName,[string]$Description,[switch]$Update) {
    Assert-DeckCatalogName $Name
    if($Repository -notin @('uizze/uizze','sickn33/agentic-awesome-skills') -or
       $Path -notmatch '^skills/(?:[a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$' -or $Path.Contains('..') -or
       $Commit -notmatch '^[a-f0-9]{40}$'){throw 'Invalid skill source.'}
    $root=Get-DeckBundledSkillCatalogRoot $SuiteRoot
    if(-not $root){[void][IO.Directory]::CreateDirectory((Join-Path $SuiteRoot 'skills'));$root=Get-DeckBundledSkillCatalogRoot $SuiteRoot}
    $target=Join-Path $root $Name
    $existing=Test-Path -LiteralPath $target
    if($existing -and -not $Update){throw "Skill $Name already exists; Deck will not overwrite it."}
    if($Update){
        $receipt=Get-DeckManagedSkillReceipt $SuiteRoot $Name
        if(-not $receipt -or $receipt.repository -cne $Repository -or $receipt.path -cne $Path){throw 'This skill is not owned by the selected catalog source.'}
        if((Get-DeckSkillTreeHash $target) -cne [string]$receipt.treeHash){throw 'The installed skill has local edits. Preserve them before updating.'}
        if($receipt.commit -ceq $Commit){return "$Name is already current at $Commit."}
    }
    $checkout=Join-Path ([IO.Path]::GetTempPath()) ('deck-skill-git-'+[guid]::NewGuid().ToString('N'))
    $stage=Join-Path $root ('.stage-'+[guid]::NewGuid().ToString('N'))
    $backup=$null
    try{
        & git clone --quiet --depth 1 --filter=blob:none --no-checkout "https://github.com/$Repository.git" $checkout
        if($LASTEXITCODE -ne 0){throw 'Could not clone the skill source.'}
        $head=(& git -C $checkout rev-parse HEAD | Select-Object -First 1)
        if($head -cne $Commit){& git -C $checkout fetch --quiet --depth 1 origin $Commit;if($LASTEXITCODE -ne 0){throw 'Could not fetch the pinned skill revision.'}}
        $patterns=@($Path)
        if($Repository -eq 'uizze/uizze' -and $Name -eq 'ui-radar'){$patterns+='LICENSE'}
        & git -C $checkout sparse-checkout set --no-cone @patterns
        if($LASTEXITCODE -ne 0){throw 'Could not select the skill files.'}
        & git -C $checkout checkout --quiet $Commit
        if($LASTEXITCODE -ne 0 -or (& git -C $checkout rev-parse HEAD | Select-Object -First 1) -cne $Commit){throw 'Skill revision verification failed.'}
        $source=Join-Path $checkout $Path
        if(-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)){throw 'Selected source has no SKILL.md.'}
        $files=@(Get-ChildItem -LiteralPath $source -Recurse -Force)
        if($files.Count -gt 600 -or (@($files | Where-Object {-not $_.PSIsContainer} | Measure-Object Length -Sum)[0].Sum) -gt 25000000){throw 'Skill package exceeds Deck limits.'}
        foreach($file in $files){if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Skill package contains a link.'}}
        Copy-Item -LiteralPath $source -Destination $stage -Recurse
        if($Repository -eq 'uizze/uizze' -and $Name -eq 'ui-radar'){
            $license=Join-Path $checkout 'LICENSE'
            if(-not (Test-Path -LiteralPath $license -PathType Leaf)){throw 'UIZZE root license is missing.'}
            Copy-Item -LiteralPath $license -Destination (Join-Path $stage 'LICENSE')
        }
        $manifest=[ordered]@{Version=1;Name=$Name;DisplayName=$DisplayName;Description=$Description;DefaultEnabled=$true}
        [IO.File]::WriteAllText((Join-Path $stage '.codexdeck.json'),(ConvertTo-Json -Compress -InputObject $manifest),[Text.UTF8Encoding]::new($false))
        $receipt=[ordered]@{schema=1;name=$Name;repository=$Repository;path=$Path;commit=$Commit;treeHash=(Get-DeckSkillTreeHash $stage);installedAt=[DateTimeOffset]::UtcNow.ToString('o')}
        [IO.File]::WriteAllText((Join-Path $stage '.codexdeck-source.json'),(ConvertTo-Json -Compress -InputObject $receipt),[Text.UTF8Encoding]::new($false))
        if($Update){
            $backupRoot=Join-Path $SuiteRoot 'deck/skill-backups'
            [void][IO.Directory]::CreateDirectory($backupRoot)
            $backup=Join-Path $backupRoot ($Name+'-'+[guid]::NewGuid().ToString('N'))
            if(-not [IO.Path]::GetFullPath($backup).StartsWith([IO.Path]::GetFullPath($backupRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid backup path.'}
            Move-Item -LiteralPath $target -Destination $backup
        }
        try{Move-Item -LiteralPath $stage -Destination $target}catch{if($backup -and -not (Test-Path -LiteralPath $target)){Move-Item -LiteralPath $backup -Destination $target};throw}
        foreach($warning in @(Sync-DeckBundledSkillsForAllEntries $SuiteRoot)){if($warning){Write-Warning $warning}}
        return "$Name installed from $Repository at $Commit. Available in new Codex sessions."
    }finally{
        if(Test-Path -LiteralPath $stage){Assert-DeckCatalogCleanupPath $stage $root '.stage-';Remove-Item -LiteralPath $stage -Recurse -Force}
        if(Test-Path -LiteralPath $checkout){Assert-DeckCatalogCleanupPath $checkout ([IO.Path]::GetTempPath()) 'deck-skill-git-';Remove-Item -LiteralPath $checkout -Recurse -Force}
    }
}
function Install-DeckAasSkill([string]$SuiteRoot,[string]$Id,[switch]$Update) {
    Assert-DeckCatalogName $Id
    $catalog=Read-DeckAasCatalog $SuiteRoot
    $entry=Get-DeckAasSkill $SuiteRoot $Id
    return Install-DeckCatalogSkill $SuiteRoot $Id $catalog.repository ([string]$entry.path) ([string]$catalog.commit) ([string]$entry.name) ([string]$entry.description) -Update:$Update
}
function Update-DeckUizzeSkill([string]$SuiteRoot,[string]$Name) {
    $receipt=Get-DeckManagedSkillReceipt $SuiteRoot $Name
    if(-not $receipt -or $receipt.repository -cne 'uizze/uizze'){throw 'This is not a managed UIZZE skill.'}
    $line=@(& git ls-remote 'https://github.com/uizze/uizze.git' refs/heads/main)
    if($LASTEXITCODE -ne 0 -or -not $line.Count -or $line[0] -notmatch '^([a-f0-9]{40})\s'){throw 'Could not resolve the UIZZE main commit.'}
    $commit=$Matches[1]
    $manifest=[IO.File]::ReadAllText((Join-Path $SuiteRoot "skills/$Name/.codexdeck.json")) | ConvertFrom-Json
    return Install-DeckCatalogSkill $SuiteRoot $Name 'uizze/uizze' ([string]$receipt.path) $commit ([string]$manifest.DisplayName) ([string]$manifest.Description) -Update
}
