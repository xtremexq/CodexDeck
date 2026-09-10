function Remove-DeckLegacyCommandSkills([string]$AccountDir) {
    $targetRoot = Join-Path $AccountDir 'skills'
    if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { return }
    $resolvedRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    foreach ($name in @('account','pool','check','usage')) {
        $target = Join-Path $targetRoot $name
        $targetMarker = Join-Path $target '.codexdeck-managed'
        if (-not (Test-Path -LiteralPath $targetMarker -PathType Leaf) -or
            [IO.File]::ReadAllText($targetMarker).Trim() -ne 'codexdeck-command-skill-v1') { continue }
        $resolvedTarget = [IO.Path]::GetFullPath($target)
        if ([IO.Path]::GetDirectoryName($resolvedTarget).TrimEnd('\') -ne $resolvedRoot) {
            throw "Managed command-skill path escaped its skills directory: $name"
        }
        if ((Get-Item -LiteralPath $resolvedTarget).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Managed command-skill path must not be a linked directory: $name"
        }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
        [pscustomobject]@{Name=$name; Status='Removed'; Reason='Legacy AI-backed command skill'}
    }
}

function Remove-DeckLegacyCommandSkillsForAccounts([string]$SuiteRoot) {
    $accountsRoot = Join-Path $SuiteRoot 'accounts'
    foreach ($account in @(Get-ChildItem -LiteralPath $accountsRoot -Directory -ErrorAction SilentlyContinue)) {
        Remove-DeckLegacyCommandSkills $account.FullName
    }
}
