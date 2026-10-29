[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgyArgs
)

$ErrorActionPreference = 'Stop'
$previousHarness = $env:CODEXDECK_DEFAULT_HARNESS
try {
    $env:CODEXDECK_DEFAULT_HARNESS = 'Antigravity'
    & (Join-Path $PSScriptRoot 'codex-auth.ps1') @AgyArgs
    if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
    exit 0
} finally {
    if ($null -eq $previousHarness) {
        Remove-Item Env:\CODEXDECK_DEFAULT_HARNESS -ErrorAction SilentlyContinue
    } else {
        $env:CODEXDECK_DEFAULT_HARNESS = $previousHarness
    }
}
