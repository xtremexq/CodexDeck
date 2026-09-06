@echo off
setlocal
set "__SELF=%~f0"
set "__TMPFILE=%TEMP%\Run-CodexLoopUsage-%RANDOM%%RANDOM%.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$self = $env:__SELF; $tmp = $env:__TMPFILE; $marker = '__POWERSHELL__'; $content = Get-Content -LiteralPath $self; $start = [Array]::IndexOf($content, $marker); if ($start -lt 0) { throw 'Embedded PowerShell marker not found.' }; Set-Content -LiteralPath $tmp -Value $content[($start + 1)..($content.Length - 1)] -Encoding UTF8"
if errorlevel 1 (
    exit /b %errorlevel%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%__TMPFILE%" %*
set "EXITCODE=%ERRORLEVEL%"

del "%__TMPFILE%" >nul 2>nul
exit /b %EXITCODE%

__POWERSHELL__
param(
    [string]$AccountsRoot = (Join-Path $HOME ".codex-loop\accounts"),
    [string[]]$Account,
    [switch]$Json,
    [switch]$NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Esc = [char]27
$script:Ansi = @{
    Reset  = "$($script:Esc)[0m"
    Bold   = "$($script:Esc)[1m"
    Gray   = "$($script:Esc)[90m"
    Red    = "$($script:Esc)[91m"
    Green  = "$($script:Esc)[92m"
    Yellow = "$($script:Esc)[93m"
    White  = "$($script:Esc)[97m"
    Cyan   = "$($script:Esc)[96m"
    Blue   = "$($script:Esc)[94m"
}
if ($NoColor -or [Console]::IsOutputRedirected -or $null -ne [Environment]::GetEnvironmentVariable('NO_COLOR')) {
    $script:Ansi = @{}
}
$script:CodexExecutable = $null

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-AccountSortIndex {
    param([string]$Name)

    if ($Name -match '^account(\d+)$') {
        return [int]$Matches[1]
    }

    return [int]::MaxValue
}

function Get-CodexExecutable {
    if ($null -ne $script:CodexExecutable) {
        return $script:CodexExecutable
    }

    $command = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command codex -ErrorAction SilentlyContinue
    }
    if (-not $command) {
        throw "Could not find 'codex' in PATH."
    }

    $script:CodexExecutable = $command.Source
    return $script:CodexExecutable
}

function Convert-Base64UrlToString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
        1 { throw "Invalid base64url string." }
    }

    $bytes = [Convert]::FromBase64String($normalized)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-JwtPayload {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $parts = $Token -split '\.'
    if ($parts.Length -lt 2) {
        return $null
    }

    try {
        return (Convert-Base64UrlToString -Value $parts[1]) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-AccountMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

    $authPath = Join-Path $CodexHome "auth.json"
    $email = $null

    if (Test-Path -LiteralPath $authPath) {
        try {
            $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
            $tokens = Get-PropertyValue -Object $auth -Name "tokens"

            $accessPayload = Get-JwtPayload -Token ([string](Get-PropertyValue -Object $tokens -Name "access_token" -Default ""))
            $idPayload = Get-JwtPayload -Token ([string](Get-PropertyValue -Object $tokens -Name "id_token" -Default ""))
            $profile = Get-PropertyValue -Object $accessPayload -Name "https://api.openai.com/profile"
            $email = [string](Get-PropertyValue -Object $profile -Name "email" -Default "")
            if ([string]::IsNullOrWhiteSpace($email)) {
                $email = [string](Get-PropertyValue -Object $accessPayload -Name "email" -Default "")
            }
            if ([string]::IsNullOrWhiteSpace($email)) {
                $email = [string](Get-PropertyValue -Object $idPayload -Name "email" -Default "")
            }
        }
        catch {
        }
    }

    if ([string]::IsNullOrWhiteSpace($email)) {
        $email = $null
    }

    return [PSCustomObject]@{
        Email = $email
    }
}

function Write-JsonRpcLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [object]$Payload
    )

    $line = $Payload | ConvertTo-Json -Compress -Depth 20
    $Process.StandardInput.WriteLine($line)
    $Process.StandardInput.Flush()
}

function Read-JsonRpcLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [int]$TimeoutSeconds = 20
    )

    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutSeconds * 1000)) {
        throw "Timed out waiting for Codex app-server response."
    }

    $line = $task.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        $stderr = if ($Process.HasExited) { $script:StderrTask.GetAwaiter().GetResult() } else { "" }
        if ([string]::IsNullOrWhiteSpace($stderr)) {
            throw "Codex app-server returned no response."
        }
        throw "Codex app-server returned no response. STDERR: $stderr"
    }

    return $line | ConvertFrom-Json
}

function Read-JsonRpcResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [int]$Id,

        [int]$TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remaining -le 0) {
            break
        }

        $message = Read-JsonRpcLine -Process $Process -TimeoutSeconds $remaining
        $idProperty = $message.PSObject.Properties["id"]
        if ($null -eq $idProperty) {
            continue
        }

        if ([int]$idProperty.Value -eq $Id) {
            $errorProperty = $message.PSObject.Properties["error"]
            if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
                $errorPayload = $errorProperty.Value | ConvertTo-Json -Compress -Depth 20
                throw "Codex app-server returned JSON-RPC error for id ${Id}: $errorPayload"
            }
            return $message
        }
    }

    throw "Timed out waiting for Codex app-server response id ${Id}."
}

function Invoke-CodexRateLimitRead {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome, [switch]$ListModels
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CodexExecutable
    $startInfo.Arguments = "app-server"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables["CODEX_HOME"] = $CodexHome

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw "Failed to start codex app-server."
        }

        $script:StderrTask = $process.StandardError.ReadToEndAsync()

        Write-JsonRpcLine -Process $process -Payload @{
            method = "initialize"
            id = 1
            params = @{
                clientInfo = @{
                    name = "codex_loop_usage"
                    title = "Codex Loop Usage"
                    version = "0.2.0"
                }
                capabilities = @{
                    experimentalApi = $true
                }
            }
        }
        $null = Read-JsonRpcResponse -Process $process -Id 1

        Write-JsonRpcLine -Process $process -Payload @{
            method = "initialized"
            params = @{}
        }

        if ($ListModels) {
            $models=@(); $cursor=$null; $requestId=10
            do {
                Write-JsonRpcLine -Process $process -Payload @{method='model/list';id=$requestId;params=@{limit=100;cursor=$cursor}}
                $response=Read-JsonRpcResponse -Process $process -Id $requestId
                if(Get-PropertyValue $response 'error'){throw (Get-PropertyValue $response 'error').message}
                $models+=@($response.result.data); $cursor=$response.result.nextCursor; $requestId++
            } while($cursor)
            return $models
        }

        Write-JsonRpcLine -Process $process -Payload @{
            method = "account/read"
            id = 2
            params = @{
                refreshToken = $true
            }
        }
        $accountResponse = Read-JsonRpcResponse -Process $process -Id 2

        Write-JsonRpcLine -Process $process -Payload @{
            method = "account/rateLimits/read"
            id = 3
            params = $null
        }
        $limitsResponse = Read-JsonRpcResponse -Process $process -Id 3

        return [PSCustomObject]@{
            AccountResponse = $accountResponse.result
            LimitsResponse  = $limitsResponse.result
        }
    }
    finally {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
        }
        catch {
        }
        $process.Dispose()
    }
}

function Invoke-UsageReadViaHttp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

    $authPath = Join-Path $CodexHome "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) {
        throw "Missing auth.json."
    }

    $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    $tokens = Get-PropertyValue -Object $auth -Name "tokens"
    $accessToken = [string](Get-PropertyValue -Object $tokens -Name "access_token" -Default "")
    $accountId = [string](Get-PropertyValue -Object $tokens -Name "account_id" -Default "")

    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Missing access token in auth.json."
    }
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        throw "Missing account_id in auth.json."
    }

    $headers = @{
        Authorization        = "Bearer $accessToken"
        "ChatGPT-Account-Id" = $accountId
        "User-Agent"         = "codex-cli"
        "Cache-Control"      = "no-cache"
    }

    return Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" -Headers $headers -Method Get -TimeoutSec 20
}

function Convert-ResetTimestamp {
    param([Nullable[long]]$UnixSeconds)

    if ($null -eq $UnixSeconds) {
        return $null
    }

    return [DateTimeOffset]::FromUnixTimeSeconds($UnixSeconds).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz")
}

function Get-RemainingPercent {
    param([AllowNull()][Nullable[double]]$UsedPercent)

    if ($null -eq $UsedPercent) {
        return $null
    }

    $remaining = 100 - $UsedPercent
    if ($remaining -lt 0) {
        $remaining = 0
    }

    return [int][Math]::Round($remaining, 0, [MidpointRounding]::AwayFromZero)
}

function Convert-UsageWindow {
    param([object]$Window, [string]$Slot, [switch]$Rpc)
    if ($null -eq $Window) { return }
    $used = Get-PropertyValue $Window $(if ($Rpc) { "usedPercent" } else { "used_percent" })
    $duration = Get-PropertyValue $Window $(if ($Rpc) { "windowDurationMins" } else { "limit_window_seconds" })
    $reset = Get-PropertyValue $Window $(if ($Rpc) { "resetsAt" } else { "reset_at" })
    if ($null -ne $duration -and $Rpc) { $duration = [double]$duration * 60 }
    if ($null -ne $used -and ([double]::IsNaN([double]$used) -or [double]$used -lt 0 -or [double]$used -gt 100)) {
        throw "Invalid usage percentage in $Slot window."
    }
    if ($null -ne $duration -and $duration -le 0) { throw "Invalid window duration." }
    if ($null -ne $reset -and $reset -le 0) { $reset = $null }
    $label = switch ($duration) {
        18000 { "5H"; break }
        604800 { "Weekly"; break }
        2592000 { "30-day"; break }
        $null { "$Slot (duration unknown)"; break }
        default {
            if ($duration % 86400 -eq 0) { "$($duration / 86400)-day" }
            elseif ($duration % 3600 -eq 0) { "$($duration / 3600)H" }
            else { "$($duration / 60)-minute" }
        }
    }
    [pscustomobject]@{
        Slot = $Slot
        Label = $label
        DurationSeconds = $duration
        UsedPct = $used
        RemainingPct = if ($null -eq $used) { $null } else { [Math]::Round(100 - [double]$used, 2) }
        Dead = ($null -ne $used -and $used -ge 100)
        ResetsAtUnix = $reset
        ResetsAt = Convert-ResetTimestamp $reset
    }
}

function New-UsageRecord {
    param([string]$AccountName, [string]$Email, [string]$PlanType,
        [object[]]$Windows, [object]$Allowed, [object]$LimitReached,
        [object]$Credits, [object]$SpendControlReached, [object]$ReachedType,
        [object]$AdditionalLimits, [object]$ModelUsage, [string]$Source)
    $blocked = $Allowed -eq $false -or $LimitReached -eq $true -or $SpendControlReached -eq $true -or
        -not [string]::IsNullOrWhiteSpace([string]$ReachedType) -or @($Windows | Where-Object Dead).Count -gt 0
    $unknown = $Windows.Count -eq 0 -or @($Windows | Where-Object {
        $null -eq $_.UsedPct -or $null -eq $_.DurationSeconds -or
        ($null -eq $_.ResetsAtUnix -and $_.UsedPct -gt 0) -or
        ($null -ne $_.ResetsAtUnix -and $_.ResetsAtUnix -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }).Count -gt 0
    $status = if ($blocked) { "blocked" } elseif ($unknown) { "unknown" } else { "available" }
    $record = [ordered]@{
        Account = $AccountName; Email = $Email; PlanType = $PlanType
        Status = $status; Allowed = $Allowed; LimitReached = $LimitReached
        Windows = @($Windows); Credits = $Credits
        CreditsUnlimited = Get-PropertyValue $Credits "unlimited"
        SpendControlReached = $SpendControlReached; RateLimitReachedType = $ReachedType
        AdditionalLimits = $AdditionalLimits; ModelUsage = $ModelUsage
        Source = $Source; CheckedAt = [DateTimeOffset]::Now.ToString("o"); FallbackReason = $null
        Error = $null
    }
    # Preserve legacy JSON fields, but populate them only for matching durations.
    foreach ($entry in @(@("FiveHour", 18000), @("Weekly", 604800))) {
        $window = $Windows | Where-Object DurationSeconds -eq $entry[1] | Select-Object -First 1
        foreach ($field in @("UsedPct", "RemainingPct", "Dead", "ResetsAt", "ResetsAtUnix")) {
            $record["$($entry[0])$field"] = Get-PropertyValue $window $field
        }
    }
    [pscustomobject]$record
}

function Convert-HttpUsageToRecord {
    param([string]$AccountName, [string]$Email, [object]$Usage)
    $rate = Get-PropertyValue $Usage "rate_limit"
    if ($null -eq $rate) { throw "Usage response has no Codex rate limit." }
    $windows = @(
        Convert-UsageWindow (Get-PropertyValue $rate "primary_window") "primary"
        Convert-UsageWindow (Get-PropertyValue $rate "secondary_window") "secondary"
    )
    New-UsageRecord -AccountName $AccountName -Email $Email -PlanType (Get-PropertyValue $Usage "plan_type") `
        -Windows $windows -Allowed (Get-PropertyValue $rate "allowed") -LimitReached (Get-PropertyValue $rate "limit_reached") `
        -Credits (Get-PropertyValue $Usage "credits") -SpendControlReached (Get-PropertyValue (Get-PropertyValue $Usage "spend_control") "reached") `
        -ReachedType (Get-PropertyValue (Get-PropertyValue $Usage "rate_limit_reached_type") "type") `
        -AdditionalLimits (Get-PropertyValue $Usage "additional_rate_limits") -ModelUsage (Get-PropertyValue $Usage "model_usage") -Source "http"
}

function Convert-RpcUsageToRecord {
    param([string]$AccountName, [string]$Email, [object]$RpcResult)
    $limits = Get-PropertyValue $RpcResult "LimitsResponse"
    $byId = Get-PropertyValue $limits "rateLimitsByLimitId"
    $snapshot = Get-PropertyValue $byId "codex"
    if ($null -eq $snapshot -and $null -eq $byId) {
        $snapshot = Get-PropertyValue $limits "rateLimits"
        $id = Get-PropertyValue $snapshot "limitId"
        if ($id -and $id -ne "codex") { $snapshot = $null }
    }
    if ($null -eq $snapshot) { throw "App-server response has no Codex rate limit." }
    $info = Get-PropertyValue (Get-PropertyValue $RpcResult "AccountResponse") "account"
    $accountEmail = Get-PropertyValue $info "email"
    if ($accountEmail) { $Email = $accountEmail }
    $plan = Get-PropertyValue $snapshot "planType"
    if (-not $plan) { $plan = Get-PropertyValue $info "planType" }
    $windows = @(
        Convert-UsageWindow (Get-PropertyValue $snapshot "primary") "primary" -Rpc
        Convert-UsageWindow (Get-PropertyValue $snapshot "secondary") "secondary" -Rpc
    )
    New-UsageRecord -AccountName $AccountName -Email $Email -PlanType $plan -Windows $windows `
        -Credits (Get-PropertyValue $snapshot "credits") -SpendControlReached (Get-PropertyValue $snapshot "spendControlReached") `
        -ReachedType (Get-PropertyValue $snapshot "rateLimitReachedType") -AdditionalLimits $byId -Source "app-server"
}

function Colorize {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string[]]$Styles
    )

    $prefix = ""
    foreach ($style in $Styles) {
        $token = Get-PropertyValue -Object $script:Ansi -Name $style -Default ""
        if (-not [string]::IsNullOrEmpty($token)) {
            $prefix += $token
        }
    }

    if ([string]::IsNullOrEmpty($prefix)) {
        return $Text
    }

    return "$prefix$Text$($script:Ansi.Reset)"
}

function Write-Line {
    param([string]$Text = "")

    [Console]::WriteLine($Text)
}

function ConvertTo-DisplayText {
    param([AllowNull()][object]$Value)
    # Account metadata and server errors must not inject terminal controls.
    return ([string]$Value -replace '[\x00-\x1f\x7f-\x9f]', ' ').Trim()
}

function Get-ReportWidth {
    try {
        if (-not [Console]::IsOutputRedirected -and [Console]::WindowWidth -ge 40) {
            return [Math]::Min(160, [Console]::WindowWidth - 1)
        }
    } catch {}
    return 120
}

function Write-ReportParts {
    param([string[]]$Parts, [int]$Width, [string]$Indent = '  ')
    $line = $Indent
    $length = $Indent.Length
    foreach ($part in $Parts) {
        $plain = $part -replace '\x1b\[[0-9;]*m', ''
        $separator = if ($length -gt $Indent.Length) { '  ' } else { '' }
        if ($length + $separator.Length + $plain.Length -gt $Width -and $length -gt $Indent.Length) {
            Write-Line $line
            $line = $Indent
            $length = $Indent.Length
            $separator = ''
        }
        $line += $separator + $part
        $length += $separator.Length + $plain.Length
    }
    if ($length -gt $Indent.Length) { Write-Line $line }
}

function Format-ResetDetail {
    param([object]$Window, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Window.ResetsAtUnix) { return 'reset not reported' }
    $reset = [DateTimeOffset]::FromUnixTimeSeconds($Window.ResetsAtUnix).ToLocalTime()
    $delta = $reset - $Now
    if ($delta.TotalSeconds -le 0) { return 'reset passed - refresh needed' }
    $countdown = if ($delta.TotalDays -ge 1) {
        '{0}d {1}h' -f [Math]::Floor($delta.TotalDays), $delta.Hours
    } elseif ($delta.TotalHours -ge 1) {
        '{0}h {1}m' -f [Math]::Floor($delta.TotalHours), $delta.Minutes
    } elseif ($delta.TotalMinutes -ge 1) {
        '{0}m' -f [Math]::Floor($delta.TotalMinutes)
    } else { '<1m' }
    $date = if ($reset.Date -eq $Now.LocalDateTime.Date) {
        'today ' + $reset.ToString('HH:mm')
    } elseif ($reset.Date -eq $Now.LocalDateTime.Date.AddDays(1)) {
        'tomorrow ' + $reset.ToString('HH:mm')
    } elseif ($reset.Year -ne $Now.Year) {
        $reset.ToString('dd MMM yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    } else {
        $reset.ToString('ddd dd MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
    return "in $countdown ($date)"
}

function Format-QuotaBadge {
    param([object]$Window, [string]$State)
    $label = ConvertTo-DisplayText $Window.Label
    if ($null -eq $Window.RemainingPct) { return Colorize "$label ? left" @('Yellow') }
    $remaining = [double]$Window.RemainingPct
    $percent = $remaining.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    # Tiny nonzero balances stay visibly nonzero; unknown data never gets a bar.
    $filled = if ($remaining -le 0) { 0 } else { [Math]::Min(8, [Math]::Max(1, [Math]::Floor($remaining * 8 / 100))) }
    $bar = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * (8 - $filled))
    $color = if ($Window.Dead) { 'Red' } elseif ($State -eq 'blocked') { 'Gray' } elseif ($State -eq 'unknown') { 'Yellow' } else { 'Green' }
    return Colorize ("{0} [{1}] {2}% left" -f $label, $bar, $percent) @($color)
}

function Write-PrettyReport {
    param([object[]]$Rows)
    $now = [DateTimeOffset]::Now
    $width = Get-ReportWidth
    Write-Line ''
    Write-Line ((Colorize '  CODEX DECK' @('Bold', 'White')) + (Colorize ' / ACCOUNT LIMITS' @('Cyan')) +
        (Colorize ("  {0}  UTC{1}" -f $now.ToString('dd MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture), $now.ToString('zzz')) @('Gray')))
    $states = @(
        @{Key='available'; Label='ALIVE'; Color='Green'},
        @{Key='blocked'; Label='DEAD'; Color='Red'},
        @{Key='unknown'; Label='UNKNOWN'; Color='Yellow'},
        @{Key='error'; Label='ERRORS'; Color='Red'}
    )
    $summary = @((Colorize ("{0} checked" -f $Rows.Count) @('White')))
    foreach ($state in $states) {
        $count = @($Rows | Where-Object Status -eq $state.Key).Count
        $summary += Colorize ("{0} {1}" -f $count, $state.Label.ToLowerInvariant()) @($state.Color)
    }
    $plans = @($Rows | Where-Object { $_.Status -ne 'error' } | Group-Object PlanType | Sort-Object Name | ForEach-Object {
        '{0} {1}' -f $_.Count, $(if ($_.Name) { ConvertTo-DisplayText $_.Name } else { 'unknown plan' })
    })
    Write-ReportParts -Parts $summary -Width $width
    if ($plans.Count) { Write-Line (Colorize ('  ' + ($plans -join ' / ')) @('Gray')) }
    foreach ($state in $states) {
        $group = @($Rows | Where-Object Status -eq $state.Key | Sort-Object @{Expression={Get-AccountSortIndex $_.Account}}, Account)
        if (-not $group.Count) { continue }
        Write-Line ''
        $title = '  {0} / {1} ' -f $state.Label, $group.Count
        Write-Line ((Colorize $title @('Bold', $state.Color)) + (Colorize ([string][char]0x2500 * [Math]::Max(0, $width - $title.Length)) @('Gray')))
        foreach ($row in $group) {
            $identity = ConvertTo-DisplayText $row.Account
            $email = ConvertTo-DisplayText $row.Email
            $plan = ConvertTo-DisplayText $row.PlanType
            if (-not $plan) { $plan = '?' }
            $badge = if ($state.Key -eq 'error') { 'ERROR' } else { $state.Label }
            $parts = @(
                (Colorize ("{0,-10}" -f $identity) @('Bold', 'White')),
                (Colorize ("[{0}]" -f $plan.ToUpperInvariant()) @('Cyan')),
                (Colorize $badge @('Bold', $state.Color))
            )
            if ($email) { $parts += Colorize $email @('White') }
            foreach ($window in $row.Windows) { $parts += Format-QuotaBadge $window $state.Key }
            Write-ReportParts -Parts $parts -Width $width
            $detailColor = if ($state.Key -eq 'available') { 'Blue' } elseif ($state.Key -eq 'unknown') { 'Yellow' } else { 'Gray' }
            $details = @()
            if ($state.Key -eq 'error') {
                $details += ConvertTo-DisplayText $row.Error
            } else {
                foreach ($window in $row.Windows) {
                    $details += '{0} resets {1}' -f (ConvertTo-DisplayText $window.Label), (Format-ResetDetail $window $now)
                }
                if (-not $row.Windows.Count) { $details += 'No quota windows reported' }
                if ($row.SpendControlReached) { $details += 'Spend control reached' }
                elseif ($row.RateLimitReachedType -and ($row.RateLimitReachedType -ne 'rate_limit_reached' -or -not @($row.Windows | Where-Object Dead).Count)) { $details += 'Limit: ' + (ConvertTo-DisplayText $row.RateLimitReachedType) }
                elseif ($state.Key -eq 'blocked' -and -not @($row.Windows | Where-Object Dead).Count) { $details += 'Server denied access' }
                if ($state.Key -eq 'unknown') { $details += 'Quota data incomplete or stale' }
                if ($row.Source -eq 'app-server') { $details += 'via fallback' }
            }
            # Wrap long errors/details at word boundaries, without dropping information.
            $words = (($details -join ' / ') -split ' ' | Where-Object { $_ })
            $detailLines = @()
            $line = ''
            foreach ($word in $words) {
                if ($line.Length + $word.Length + 1 -gt $width - 4 -and $line) {
                    $detailLines += $line; $line = ''
                }
                if ($line) { $line += ' ' }
                $line += $word
            }
            if ($line) { $detailLines += $line }
            foreach ($detail in $detailLines) { Write-Line (Colorize ('    ' + $detail) @($detailColor)) }
        }
    }
    Write-Line ''
    Write-Line (Colorize '  Bars = quota left. Any exhausted window blocks the account.' @('Gray'))
    Write-Line (Colorize '  Resets use local time; model-specific limits may differ.' @('Gray'))
    Write-Line ''
}

if (-not (Test-Path -LiteralPath $AccountsRoot)) {
    throw "Accounts root not found: $AccountsRoot"
}

$accountDirs = Get-ChildItem -LiteralPath $AccountsRoot -Directory |
    Sort-Object @{ Expression = { Get-AccountSortIndex $_.Name } }, Name

if ($Account) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Account) {
        foreach ($part in ($name -split ",")) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $null = $wanted.Add($trimmed)
            }
        }
    }
    $accountDirs = @($accountDirs | Where-Object { $wanted.Contains($_.Name) })
}

if (@($accountDirs).Count -eq 0) { throw "No matching accounts found." }

$results = foreach ($dir in $accountDirs) {
    $httpError = $null
    $metadata = Get-AccountMetadata -CodexHome $dir.FullName

    try {
        $usage = Invoke-UsageReadViaHttp -CodexHome $dir.FullName
        $record = Convert-HttpUsageToRecord -AccountName $dir.Name -Email $metadata.Email -Usage $usage
        if ($record.Status -eq "unknown") { throw "HTTP returned incomplete or stale quota data." }
        $record
        continue
    }
    catch {
        $httpError = $_.Exception.Message
    }

    try {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'auth.json') -PathType Leaf)) {
            throw "No login credentials. Use codex-auth with a valid account name to log in."
        }
        $rpcResult = Invoke-CodexRateLimitRead -CodexHome $dir.FullName
        $record = Convert-RpcUsageToRecord -AccountName $dir.Name -Email $metadata.Email -RpcResult $rpcResult
        $record.FallbackReason = $httpError
        $record
    }
    catch {
        [PSCustomObject][ordered]@{
            Status               = "error"
            Windows              = @()
            Account              = $dir.Name
            Email                = $metadata.Email
            PlanType             = $null
            FiveHourUsedPct      = $null
            FiveHourRemainingPct = $null
            FiveHourDead         = $null
            FiveHourResetsAt     = $null
            FiveHourResetsAtUnix = $null
            WeeklyUsedPct        = $null
            WeeklyRemainingPct   = $null
            WeeklyDead           = $null
            WeeklyResetsAt       = $null
            WeeklyResetsAtUnix   = $null
            CreditsUnlimited     = $null
            Source               = $null
            Error                = "HTTP failed: $httpError | fallback failed: $($_.Exception.Message)"
        }
    }
}

if ($Json) {
    ConvertTo-Json -InputObject @($results) -Depth 20
}
else {
    Write-PrettyReport -Rows @($results)
}
