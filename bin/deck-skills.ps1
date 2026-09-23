[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Action='help',
    [Parameter(Position=1)][string]$Skill,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Terms,
    [string]$Category='',
    [string]$Risk=''
)
$ErrorActionPreference='Stop'
$suite=Join-Path $HOME '.codex-loop'
if(-not (Test-Path -LiteralPath (Join-Path $suite 'Deck.SkillCatalog.ps1') -PathType Leaf)){
    # Source checkout use: PowerShell -File bin/deck-skills.ps1 ...
    $suite=Join-Path (Split-Path -Parent $PSScriptRoot) 'suite'
}
. (Join-Path $suite 'Deck.Environments.ps1')
. (Join-Path $suite 'Deck.BundledSkills.ps1')
. (Join-Path $suite 'Deck.SkillCatalog.ps1')
try {
    switch($Action.ToLowerInvariant()) {
        'search' {
            $query=(@($Skill)+@($Terms) | Where-Object {$_}) -join ' '
            $matches=@(Search-DeckAasSkills $suite $query $Category $Risk 80)
            foreach($item in $matches){ '{0,-44} {1,-18} {2,-9} {3}' -f $item.id,$item.category,$item.risk,([string]$item.description).Substring(0,[Math]::Min(92,([string]$item.description).Length)) }
            "Showing $($matches.Count) matches (first 80). Use 'deck-skills show <id>' for details."
        }
        'show' {
            $item=Get-DeckAasSkill $suite $Skill
            "ID: $($item.id)`nDescription: $($item.description)`nCategory: $($item.category)`nRisk: $($item.risk)`nSource: $($item.source)`nLicense: $($item.license)`nSetup: $($item.setupSummary)`nPath: $($item.path)`nCommit: $((Read-DeckAasCatalog $suite).commit)"
        }
        'preview' {
            $item=Get-DeckAasSkill $suite $Skill
            $catalog=Read-DeckAasCatalog $suite
            $uri="https://raw.githubusercontent.com/$($catalog.repository)/$($catalog.commit)/$($item.path)/SKILL.md"
            (Invoke-WebRequest -UseBasicParsing -Uri $uri -ErrorAction Stop).Content
        }
        'install' {Install-DeckAasSkill $suite $Skill}
        'update' {
            $receipt=Get-DeckManagedSkillReceipt $suite $Skill
            if(-not $receipt){throw 'No managed catalog skill with that name is installed.'}
            if($receipt.repository -eq 'uizze/uizze'){Update-DeckUizzeSkill $suite $Skill}
            else{Install-DeckAasSkill $suite $Skill -Update}
        }
        'refresh' {Update-DeckAasCatalog $suite}
        'installed' {
            foreach($item in Get-DeckBundledSkills $suite){
                $receipt=Get-DeckManagedSkillReceipt $suite $item.Name
                $source=if($receipt){"$($receipt.repository) $($receipt.commit.Substring(0,12))"}else{'Codex Deck'}
                '{0,-36} {1}' -f $item.Name,$source
            }
        }
        'enable' {
            if(-not $Skill -or -not $Terms.Count){throw 'Use: deck-skills enable <name> <account-or-pool>'}
            Set-DeckBundledSkillEnabled $suite $Terms[0] $Skill $true
        }
        'disable' {
            if(-not $Skill -or -not $Terms.Count){throw 'Use: deck-skills disable <name> <account-or-pool>'}
            Set-DeckBundledSkillEnabled $suite $Terms[0] $Skill $false
        }
        default {
            @'
Deck Skills
  deck-skills search <terms> [-Category name] [-Risk level]
  deck-skills show <aas-id>
  deck-skills preview <aas-id>
  deck-skills install <aas-id>
  deck-skills refresh
  deck-skills update <installed-name>
  deck-skills installed
  deck-skills enable|disable <name> <account-or-pool>

The AAS catalog is searchable offline. Install only selected skills; Deck links
them into all accounts and pools by default. Per-entry switches apply next session.
These commands also work as: codex-auth skills <command>.
'@
        }
    }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
