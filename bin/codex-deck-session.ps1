[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('account','pool','usage','delay','schedule','context','autocompact')]
    [string]$Command = 'account',

    [Parameter(Position = 1)]
    [string]$Selection,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$MessageParts,

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
if($Command -eq 'autocompact'){
    if($requested -or $MessageParts -or $Json){throw '!autocompact does not accept arguments.'}
    if(-not $env:CODEX_HOME){throw 'This command must run inside a managed codex-auth conversation.'}
    $accountDir=Get-Item -LiteralPath $env:CODEX_HOME -ErrorAction Stop
    if(-not $accountDir.PSIsContainer -or $accountDir.Parent.Name -ne 'accounts'){throw 'This command must run inside a managed codex-auth conversation.'}
    $compactUrl=[string]$env:CODEX_DECK_COMPACT_URL
    if($compactUrl -notmatch '^http://127\.0\.0\.1:[0-9]+/[a-f0-9]{64}/compact$'){
        $sessionPath=[string]$env:CODEX_DECK_SESSION_PATH
        if($sessionPath){
            $sessionRoot=[IO.Path]::GetFullPath((Join-Path $accountDir.Parent.Parent.FullName 'deck/sessions'))
            $sessionFull=[IO.Path]::GetFullPath($sessionPath)
            if([IO.Path]::GetDirectoryName($sessionFull) -eq $sessionRoot -and (Test-Path -LiteralPath $sessionFull -PathType Leaf)){
                try{
                    $marker=Get-Content -LiteralPath $sessionFull -Raw | ConvertFrom-Json
                    $ownerProcess=Get-Process -Id ([int]$marker.ProcessId) -ErrorAction Stop
                    try{$sameProcess=$ownerProcess.StartTime.ToUniversalTime().Ticks -eq [long]$marker.ProcessStartTicks}
                    finally{$ownerProcess.Dispose()}
                    if($sameProcess -and $marker.Account -eq $accountDir.Name){$compactUrl=[string]$marker.CompactUrl}
                }catch{}
            }
        }
    }
    if($compactUrl -notmatch '^http://127\.0\.0\.1:[0-9]+/[a-f0-9]{64}/compact$'){throw 'This conversation has no attached compaction control. Resume it in a new managed Codex Deck terminal.'}
    try{[void](Invoke-RestMethod -Uri $compactUrl -Method Post -TimeoutSec 35)}
    catch{
        $detail=$_.Exception.Message
        if($_.ErrorDetails.Message){$detail=$_.ErrorDetails.Message}
        if($_.Exception.Response -and $_.Exception.Response -is [System.Net.WebResponse]){
            try{
                $reader=[IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                try{$responseText=$reader.ReadToEnd()}finally{$reader.Dispose()}
                if($responseText){$detail=$responseText}
            }catch{}
        }
        throw "Compaction request failed: $detail"
    }
    Write-Output 'Compaction requested for this conversation.'
    exit 0
}
$status = Invoke-DeckSessionAccount

if($Command -eq 'context'){
    if($requested -or $MessageParts -or $Json){throw '!context does not accept arguments.'}
    $sessionPath=[string]$env:CODEX_DECK_SESSION_PATH
    if(-not $sessionPath -or -not $env:CODEX_HOME){throw 'This terminal has no attached live context session.'}
    $accountDir=Get-Item -LiteralPath $env:CODEX_HOME -ErrorAction Stop
    if(-not $accountDir.PSIsContainer -or $accountDir.Parent.Name -ne 'accounts'){throw 'This command must run inside a managed codex-auth conversation.'}
    $suiteRoot=$accountDir.Parent.Parent.FullName
    $sessionRoot=[IO.Path]::GetFullPath((Join-Path $suiteRoot 'deck/sessions'))
    $sessionFull=[IO.Path]::GetFullPath($sessionPath)
    if([IO.Path]::GetDirectoryName($sessionFull) -ne $sessionRoot){throw 'The attached live context session path is invalid.'}
    $core=Join-Path $suiteRoot 'Deck.Core.ps1'
    if(-not (Test-Path -LiteralPath $core -PathType Leaf)){throw 'Live context support is not installed. Reinstall Codex Deck.'}
    . $core
    $marker=Read-DeckJson $sessionFull
    if(-not $marker -or $marker.Account -ne [string]$status.environment.name -or $marker.ContextUrl -ne ($env:CODEX_DECK_SESSION_URL+'/_deck/context')){throw 'The live context route does not match this terminal.'}
    $contextUrl=Open-DeckInspector $suiteRoot 'Trajectory' -Companion -SessionPath $sessionFull -NoOpen
    $presenceUrl=$contextUrl.Replace('/context?live=','/api/context/presence?id=')
    $presence=Invoke-RestMethod -Uri $presenceUrl -Method Get -TimeoutSec 2
    if($presence.open){Write-Output 'Codex Deck Live Context is already open for this terminal.'}
    else{[void](Open-DeckInspector $suiteRoot 'Trajectory' -Companion -SessionPath $sessionFull);Write-Output 'Codex Deck Live Context opened for this terminal.'}
    exit 0
}

if($Command -in @('delay','schedule')){
    if($UseAccount -or $Json){throw "$Command does not accept account-selection or JSON options."}
    $message=(@($MessageParts) -join ' ')
    if([string]::IsNullOrWhiteSpace($Selection) -or [string]::IsNullOrWhiteSpace($message)){throw "Usage: !$Command <duration> <message>"}
    if(-not $env:CODEX_HOME){throw 'Codex did not expose the owning CODEX_HOME to this local command.'}
    $accountDir=Get-Item -LiteralPath $env:CODEX_HOME -ErrorAction Stop
    if(-not $accountDir.PSIsContainer -or $accountDir.Parent.Name -ne 'accounts'){throw 'This command must run inside a managed codex-auth conversation.'}
    $owner=$accountDir.Name
    if([string]$status.environment.name -ne $owner){throw 'The live session owner does not match CODEX_HOME.'}
    $suiteRoot=$accountDir.Parent.Parent.FullName
    $module=Join-Path $suiteRoot 'Deck.ScheduledMessages.ps1'
    if(-not (Test-Path -LiteralPath $module -PathType Leaf)){$module=Join-Path $PSScriptRoot '../suite/Deck.ScheduledMessages.ps1'}
    if(-not (Test-Path -LiteralPath $module -PathType Leaf)){throw 'Scheduled-message support is not installed. Reinstall Codex Deck.'}
    . $module
    $duration=ConvertFrom-DeckMessageDuration $Selection
    $threadId=[string]$env:CODEX_THREAD_ID
    if($Command -eq 'delay'){
        $result=Start-DeckDelayedMessage $suiteRoot $owner $accountDir.FullName (Get-Location).Path $threadId $message $duration
        Write-Output ("Delayed message set for {0}. It will be queued into this live conversation." -f $result.DueAt.ToString('g'))
    }else{
        $authScript=Join-Path $PSScriptRoot 'codex-auth.ps1'
        $result=Register-DeckScheduledMessage $suiteRoot $owner $accountDir.FullName (Get-Location).Path $threadId $message $duration $authScript
        Write-Output ("Scheduled message set for {0}. Windows task: {1}" -f $result.DueAt.ToString('g'),$result.TaskName)
    }
    exit 0
}

if($MessageParts){throw "$Command accepts at most one selection."}

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
