param([string]$Version = '1.1.0', [string]$Ref = 'HEAD')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected a numeric major.minor.patch version.' }
Push-Location $PSScriptRoot
try {
    & ./Test-Repository.ps1
    [void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'dist'))
    $archive = Join-Path $PSScriptRoot "dist/CodexDeck-$Version.zip"
    if (Test-Path -LiteralPath $archive) { throw 'Release archive exists; choose a new version or move the old artifact.' }
    # Only committed files can enter the release. Never archive the working tree.
    git archive --format=zip "--output=$archive" $Ref
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'dist/SHA256SUMS.txt'), "$hash  CodexDeck-$Version.zip`n", [Text.UTF8Encoding]::new($false))
    Write-Output $archive
} finally { Pop-Location }
