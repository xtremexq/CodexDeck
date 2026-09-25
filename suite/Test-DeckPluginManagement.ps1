$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-plugin-test-'+[guid]::NewGuid().ToString('N'))
$plugin=Join-Path $fixture 'source-plugin'
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/account1'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/account2'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'skills'))
    foreach($name in @('sample-first','sample-second')){
        $directory=Join-Path $plugin "skills/$name"; [void][IO.Directory]::CreateDirectory($directory)
        $description=if($name -eq 'sample-first'){'First imported workflow.'}else{'Second imported workflow.'}
        [IO.File]::WriteAllText((Join-Path $directory 'SKILL.md'),("---`nname: {0}`ndescription: {1}`n---`n`n# {0}" -f $name,$description),[Text.UTF8Encoding]::new($false))
    }
    . (Join-Path $PSScriptRoot 'Deck.Environments.ps1')
    . (Join-Path $PSScriptRoot 'Deck.BundledSkills.ps1')
    . (Join-Path $PSScriptRoot 'Deck.PluginManagement.ps1')
    $imported=@(Import-DeckPluginSkills $fixture 'sample@market' '1.0.0' $plugin)
    Assert ($imported.Count -eq 2) 'Plugin skills were not imported.'
    $catalog=@(Get-DeckBundledSkills $fixture)
    Assert (($catalog.Name -join '|') -eq 'sample-first|sample-second') 'Imported plugin skills are missing from the Deck catalog.'
    Assert (Test-Path -LiteralPath (Join-Path $fixture 'accounts/account1/skills/sample-first/SKILL.md') -PathType Leaf) 'Imported plugin skill was not linked into an account.'
    $receipt=Get-DeckPluginSkillReceipt $fixture 'sample-first'
    Assert ($receipt.pluginId -eq 'sample@market' -and $receipt.version -eq '1.0.0') 'Plugin ownership receipt is incomplete.'

    $sourceSkill=Join-Path $plugin 'skills/sample-first/SKILL.md'
    [IO.File]::AppendAllText($sourceSkill,"`nUpdated upstream.",[Text.UTF8Encoding]::new($false))
    Import-DeckPluginSkills $fixture 'sample@market' '1.1.0' $plugin | Out-Null
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'skills/sample-first/SKILL.md')).Contains('Updated upstream.')) 'Clean plugin skill did not update.'

    $installedSkill=Join-Path $fixture 'skills/sample-first/SKILL.md'
    [IO.File]::AppendAllText($installedSkill,"`nLocal edit.",[Text.UTF8Encoding]::new($false))
    $blocked=$false
    try{Import-DeckPluginSkills $fixture 'sample@market' '1.2.0' $plugin | Out-Null}catch{$blocked=$_.Exception.Message -match 'local edits'}
    Assert $blocked 'Plugin update overwrote a locally edited skill.'
    Assert ([IO.File]::ReadAllText($installedSkill).Contains('Local edit.')) 'Rejected update changed the local skill.'
    'PASS: plugin skills import once, join the managed catalog, update safely, sync to accounts, and preserve local edits.'
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $target=[IO.Path]::GetFullPath($fixture).TrimEnd('\')
    if(-not $target.StartsWith($tempRoot+'\deck-plugin-test-',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($target) -cne $tempRoot){throw 'Unsafe plugin test cleanup target.'}
    if(Test-Path -LiteralPath $target){
        foreach($link in Get-ChildItem -LiteralPath (Join-Path $target 'accounts') -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object LinkType -eq 'Junction'){[IO.Directory]::Delete($link.FullName)}
        [IO.Directory]::Delete($target,$true)
    }
}
