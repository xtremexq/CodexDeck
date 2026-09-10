[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('account','pool','usage')]
    [string]$Command = 'account',

    [Parameter(Position = 1)]
    [string]$Selection,

    [string]$UseAccount,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Get-DeckSessionUri {
    $sessionUrl = $env:CODEX_DECK_SESSION_URL
    if ($sessionUrl -notmatch '^http://127\.0\.0\.1:[0-9]+/[a-f0-9]{64}$') {
        throw 'This Codex session is not using a Codex Deck failover pool.'
    }
    return $sessionUrl + '/_deck/account'
}

function Invoke-DeckSessionAccount([string]$Account) {
    if ($Account -and ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $Account -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$')) {
        throw 'Choose an account name reported by this session.'
    }
    try {
        if ($Account) {
            $body = @{account=$Account} | ConvertTo-Json -Compress
            return Invoke-RestMethod -Uri (Get-DeckSessionUri) -Method Post -ContentType 'application/json' -Body $body
        }
        return Invoke-RestMethod -Uri (Get-DeckSessionUri) -Method Get
    } catch {
        $message = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            try { $message = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
        }
        throw $message
    }
}

function Resolve-DeckAccountChoice([string]$Choice, [string[]]$Names) {
    if ([string]::IsNullOrWhiteSpace($Choice)) { return $null }
    $value = $Choice.Trim()
    if ($value -match '^\d+$') {
        $index = [int]$value
        if ($index -ge 1 -and $index -le $Names.Count) { return $Names[$index - 1] }
    }
    return $Names | Where-Object { $_ -eq $value } | Select-Object -First 1
}

function Write-DeckAccountList([object]$Status, [string[]]$Names, [string]$Title) {
    if (-not $Names.Count) { throw "$Title has no accounts available to this session." }
    Write-Output ''
    Write-Output $Title
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $name = $Names[$i]
        $labels = @()
        if ($name -eq $Status.failover.active) { $labels += 'active' }
        if ($name -in @($Status.failover.unavailable)) { $labels += 'quota rejected' }
        Write-Output ('  [{0}] {1}{2}' -f ($i + 1),$name,$(if ($labels.Count) { ' ('+($labels -join ', ')+')' } else { '' }))
    }
}

function Write-DeckSessionStatus([object]$Status) {
    $pooled = if ($Status.environment.pooled) { 'pooled' } else { 'ordinary' }
    $rotation = if ($Status.failover.automatic -eq $false) { 'Off (manual switching available)' } else { [string]$Status.failover.mode }
    Write-Output ("Environment: {0} ({1})" -f $Status.environment.name,$pooled)
    Write-Output ("Rotation: {0}" -f $rotation)
    Write-Output ("Active: {0}" -f $Status.failover.active)
    Write-Output 'Failover accounts:'
    foreach ($name in @($Status.failover.accounts)) {
        $labels = @()
        if ($name -eq $Status.failover.active) { $labels += 'active' }
        if ($name -in @($Status.failover.unavailable)) { $labels += 'quota rejected' }
        Write-Output ('  {0}{1}' -f $name,$(if ($labels.Count) { ' ('+($labels -join ', ')+')' } else { '' }))
    }
    if ($Status.environment.pooled) {
        Write-Output ("Current pool ({0}):" -f $Status.environment.name)
        foreach ($name in @($Status.environment.accounts)) { Write-Output ("  $name") }
    }
}

$requested = if ($UseAccount) { $UseAccount } else { $Selection }
$status = Invoke-DeckSessionAccount

if ($Command -eq 'usage') {
    if ($requested) { throw 'Usage does not accept an account selection; switch with !account or !pool first.' }
    $checker = Get-Command codex-check.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $checker) { $checker = Get-Command codex-check -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $checker) { throw "Could not find 'codex-check' in PATH." }
    $arguments = @('-Account',[string]$status.failover.active)
    if ($Json) { $arguments += '-Json' } else { $arguments += '-NoColor' }
    & $checker.Source @arguments
    exit $LASTEXITCODE
}

if ($requested) {
    $names = if ($Command -eq 'pool') { @($status.environment.accounts) } else { @($status.failover.accounts) }
    if ($Command -eq 'pool' -and -not $status.environment.pooled) { throw 'This is not a pooled environment. Use !account for an ordinary failover session.' }
    $selected = Resolve-DeckAccountChoice $requested $names
    if (-not $selected) { throw 'Choose an account from this session.' }
    $status = Invoke-DeckSessionAccount $selected
} elseif (-not $Json) {
    if ($Command -eq 'pool') {
        if (-not $status.environment.pooled) { throw 'This is not a pooled environment. Use !account for an ordinary failover session.' }
        Write-DeckAccountList $status @($status.environment.accounts) ("Current pool: {0}" -f $status.environment.name)
        Write-Output ''
        Write-Output 'Switch with: !pool <number-or-name>'
    } else {
        Write-Output ("Active account: {0}" -f $status.failover.active)
        Write-Output 'Account sources:'
        $accountListTitle = if ($status.failover.automatic -eq $false) { 'Session accounts' } else { 'Failover accounts' }
        Write-Output ("  [1] {0}" -f $accountListTitle)
        Write-DeckAccountList $status @($status.failover.accounts) $accountListTitle
        if ($status.environment.pooled) {
            Write-Output ''
            Write-Output ("  [2] Current pool ({0})" -f $status.environment.name)
            Write-DeckAccountList $status @($status.environment.accounts) ("Current pool: {0}" -f $status.environment.name)
        }
        Write-Output ''
        Write-Output 'Switch with: !account <number-or-name>'
        if ($status.environment.pooled) { Write-Output 'Pool shortcut: !pool <pool-number-or-name>' }
    }
    exit 0
}

if ($Json) {
    $status | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
Write-DeckSessionStatus $status
