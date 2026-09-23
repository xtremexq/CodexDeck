$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-catalog-test-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'skill-catalog'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'skills'))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'skill-catalog/aas-index.json') -Destination (Join-Path $fixture 'skill-catalog/aas-index.json')
    . (Join-Path $PSScriptRoot 'Deck.Environments.ps1')
    . (Join-Path $PSScriptRoot 'Deck.BundledSkills.ps1')
    . (Join-Path $PSScriptRoot 'Deck.SkillCatalog.ps1')
    $catalog=Read-DeckAasCatalog $fixture
    if($catalog.skills.Count -lt 2000){throw 'Bundled catalog is incomplete.'}
    $found=@(Search-DeckAasSkills $fixture 'brainstorming' '' '' 60)
    if(-not @($found | Where-Object id -eq 'brainstorming').Count){throw 'Catalog search missed an exact ID.'}
    $skill=Get-DeckAasSkill $fixture 'brainstorming'
    if($skill.path -notmatch '^skills/' -or -not $skill.description){throw 'Catalog detail is incomplete.'}
    $filtered=@(Search-DeckAasSkills $fixture 'brainstorming' '__no_such_category__' '' 60)
    if($filtered.Count){throw 'Catalog category filter failed.'}
    $invalid=$false
    try{Assert-DeckCatalogName '../unsafe'}catch{$invalid=$true}
    if(-not $invalid){throw 'Unsafe install name was accepted.'}
    Assert-DeckCatalogName 'android_ui_verification'
    if((Get-DeckAasSkill $fixture 'android_ui_verification').path -cne 'skills/android_ui_verification'){throw 'Underscore catalog skill was not available.'}
    $path=Join-Path $fixture 'skills/sample'
    [void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'SKILL.md'),'safe',[Text.UTF8Encoding]::new($false))
    $first=Get-DeckSkillTreeHash $path
    [IO.File]::WriteAllText((Join-Path $path 'SKILL.md'),'changed',[Text.UTF8Encoding]::new($false))
    if((Get-DeckSkillTreeHash $path) -ceq $first){throw 'Managed skill edit detection failed.'}
    'PASS: pinned AAS catalog search, filtering, identity validation and skill edit detection.'
}finally{
    $root=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $target=[IO.Path]::GetFullPath($fixture).TrimEnd('\')
    if(-not $target.StartsWith($root+'\deck-catalog-test-',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($target) -cne $root){throw 'Unsafe test cleanup target.'}
    if(Test-Path -LiteralPath $target){[IO.Directory]::Delete($target,$true)}
}
