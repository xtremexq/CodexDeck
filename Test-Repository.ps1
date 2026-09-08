$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $tracked = @(git ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0 -or !$tracked.Count) { throw 'Run from a Git checkout with staged/tracked files.' }
    foreach ($path in $tracked) {
        if ($path -match '(^|/)(accounts|deleted-accounts|runs|sessions)/|(^|/)(auth\.json|config\.toml|\.env)(\.|$)|\.(log|pem|key|pfx|p12)$|\.bak') { throw "Private/generated path tracked: $path" }
        if ($path -match '/deck/' -and $path -notmatch '^suite/deck/assets/codex-deck\.(png|ico)$') { throw "Runtime Deck file tracked: $path" }
        if ($path -match '\.(png|ico)$') { continue }
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $path))
        if ($text -match '(?i)[A-Z]:\\Users\\(?!Public\b|example\b)[^\s\\]+|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|\bsk-[A-Za-z0-9_-]{32,}') { throw "Potential private content: $path" }
        if ($path -match '\.(cmd|bat)$' -and [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $path))[0] -eq 239) { throw "Batch launcher must not have a UTF-8 BOM: $path" }
        if ($path -match '\.ps1$') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $path))
            if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "PowerShell UTF-8 BOM missing: $path" }
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$null,[ref]$parseErrors)
            if ($parseErrors.Count) { throw "PowerShell parse failure: $path" }
        }
    }
    foreach ($path in @('suite/accounts/example/auth.json','suite/deleted-accounts/example/auth.json','suite/deck/settings.json','suite/deck/cache.json','.env','private.key','dist/release.zip')) {
        git check-ignore -q -- $path
        if ($LASTEXITCODE -ne 0) { throw "Private/generated path is not ignored: $path" }
    }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'Whitespace check failed' }
    'PASS: tracked paths, sensitive-content patterns, encodings, parsing, ignores and whitespace.'
} finally { Pop-Location }
