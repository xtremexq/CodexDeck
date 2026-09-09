function Test-DeckAutomaticFailover($Settings, [bool]$ExplicitMode, [string[]]$Arguments, [bool]$CreatingAccount = $false) {
    if ($ExplicitMode -or $CreatingAccount -or -not $Settings.FailoverEnabled) { return $false }
    if (-not $Arguments) { return $true }
    if ($Arguments -contains '--help' -or $Arguments -contains '-h' -or $Arguments -contains '--version' -or $Arguments -contains '-V') { return $false }
    return $Arguments[0] -in @('resume','fork','exec') -or $Arguments[0].StartsWith('-')
}
function Resolve-DeckFailoverPool([string]$SuiteRoot, [string]$Pool, [string]$Mode, [string]$StartAccount = '') {
    $names = @($Pool -split ',' | ForEach-Object { $_.Trim() } | ForEach-Object { if ($_ -match '^\d+$') { 'account'+$_ } else { $_ } })
    if (-not $Pool -or $names.Count -gt 200 -or @($names | Sort-Object -Unique).Count -ne $names.Count) { throw 'Failover needs 1-200 distinct accounts, separated by commas.' }
    if ($StartAccount) {
        if ($StartAccount -match '^\d+$') { $StartAccount='account'+$StartAccount }
        $names=@($StartAccount)+@($names | Where-Object { $_ -ne $StartAccount })
        if ($names.Count -gt 200) { throw 'Starting account plus fallback pool cannot exceed 200 accounts.' }
    }
    foreach ($name in $names) {
        if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$' -or
            -not (Test-Path -LiteralPath (Join-Path $SuiteRoot ('accounts/'+$name+'/auth.json')) -PathType Leaf)) { throw 'Every failover account must already exist and be logged in.' }
    }
    $initial = $names[0]
    if ($Mode -eq 'Best' -and -not $StartAccount) {
        . (Join-Path $SuiteRoot 'Deck.Core.ps1')
        . (Join-Path $SuiteRoot 'Deck.Terminal.ps1')
        $choice = @(Get-DeckRecommendations $names (Get-DeckTerminalCache (Join-Path $SuiteRoot 'deck'))) | Select-Object -First 1
        if (-not $choice) { throw 'No fresh usable pool account. Refresh usage in the dashboard first.' }
        $initial = $choice.Account
    }
    return @{ Pool=$names; Account=$initial }
}
function Start-DeckFailover([string]$SuiteRoot, [string[]]$Pool, [string]$Mode, [string]$Account) {
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $scriptPath = Join-Path $SuiteRoot 'Deck.Failover.cjs'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'Failover proxy missing. Reinstall Codex Deck.' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$node; $info.Arguments='"'+$scriptPath+'"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        # Write BOM-free UTF-8 regardless of the host console encoding.
        $writer = [IO.StreamWriter]::new($process.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false))
        $writer.WriteLine((@{ root=$SuiteRoot; pool=@($Pool); mode=$Mode; owner=$Account } | ConvertTo-Json -Compress))
        $writer.Flush()
        $ready = $process.StandardOutput.ReadLineAsync()
        if (-not $ready.Wait(10000) -or -not $ready.Result) { throw 'Failover proxy did not become ready.' }
        $result = $ready.Result | ConvertFrom-Json
        if ($result.baseUrl -notmatch '^http://127\.0\.0\.1:[0-9]+/[a-f0-9]{64}$' -or $result.account -ne $Account) { throw 'Invalid proxy startup response.' }
        return @{ Process=$process; BaseUrl=$result.baseUrl }
    } catch {
        if ($process.Id -and -not $process.HasExited) { $process.Kill() }
        $process.Dispose(); throw
    }
}
function Get-DeckFailoverArguments([string]$BaseUrl, [switch]$NoAccountAuth) {
    # CLI overrides are temporary; the account's config.toml is never rewritten for routing.
    @('-c','model_provider="deck_failover"',
      '-c','model_providers.deck_failover.name="Deck Failover"',
      '-c',('model_providers.deck_failover.base_url="'+$BaseUrl+'"'),
      '-c','model_providers.deck_failover.wire_api="responses"',
      '-c',('model_providers.deck_failover.requires_openai_auth='+$(if ($NoAccountAuth) { 'false' } else { 'true' })),
      '-c','model_providers.deck_failover.supports_websockets=false',
      '-c','model_providers.deck_failover.request_max_retries=0',
      '-c','model_providers.deck_failover.stream_max_retries=0')
}
