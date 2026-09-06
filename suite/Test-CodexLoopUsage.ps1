$ErrorActionPreference = 'Stop'
$source = Get-Content (Join-Path $PSScriptRoot 'Run-CodexLoopUsage.cmd') -Raw
$body = ($source -split '(?m)^__POWERSHELL__\r?\n', 2)[1]
. ([scriptblock]::Create($body.Substring(0, $body.IndexOf('if (-not (Test-Path -LiteralPath $AccountsRoot))'))))
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$future = [DateTimeOffset]::UtcNow.AddDays(8).ToUnixTimeSeconds()
$free = @{ plan_type='free'; rate_limit=@{ allowed=$false; limit_reached=$true; primary_window=@{used_percent=100;limit_window_seconds=2592000;reset_at=$future};secondary_window=$null } }
$http = Convert-HttpUsageToRecord 'test' '' $free
Assert ($http.Status -eq 'blocked') 'Free exhausted HTTP account was not blocked'
Assert ($http.Windows[0].Label -eq '30-day') 'Free window mislabeled'
Assert ($null -eq $http.WeeklyRemainingPct -and $null -eq $http.FiveHourRemainingPct) 'Absent windows fabricated'
$rpc = @{AccountResponse=@{account=@{planType='free'}}; LimitsResponse=@{rateLimitsByLimitId=@{codex=@{primary=@{usedPercent=100;windowDurationMins=43200;resetsAt=$future};secondary=$null}}}}
$fallback = Convert-RpcUsageToRecord 'test' '' $rpc
Assert ($fallback.Status -eq $http.Status -and $fallback.Windows[0].DurationSeconds -eq 2592000) 'Fallback differs for free account'
Assert ($null -eq (Get-RemainingPercent $null)) 'Null usage converted to 100%'
$free.rate_limit.primary_window.used_percent=$null
$free.rate_limit.allowed=$true
$free.rate_limit.limit_reached=$false
$unknown = Convert-HttpUsageToRecord 'test' '' $free
Assert ($unknown.Status -eq 'unknown' -and $null -eq $unknown.Windows[0].RemainingPct) 'Missing usage treated as available'
$free.rate_limit.primary_window.used_percent=99.6
$partial = Convert-HttpUsageToRecord 'test' '' $free
Assert ($partial.Status -eq 'available' -and $partial.Windows[0].RemainingPct -eq 0.4) 'Fractional usage rounded to exhaustion'
$free.rate_limit.allowed=$false
Assert ((Convert-HttpUsageToRecord 'test' '' $free).Status -eq 'blocked') 'Server denial ignored'
$plus = @{plan_type='plus';rate_limit=@{primary_window=@{used_percent=0;limit_window_seconds=18000;reset_at=$future};secondary_window=@{used_percent=100;limit_window_seconds=604800;reset_at=$future}}}
$paid = Convert-HttpUsageToRecord 'test' '' $plus
Assert ($paid.Status -eq 'blocked' -and $paid.FiveHourRemainingPct -eq 100 -and $paid.WeeklyDead) 'Weekly exhaustion ignored'
$plus.rate_limit.secondary_window.used_percent=10
$plus.rate_limit.primary_window.reset_at=1
Assert ((Convert-HttpUsageToRecord 'test' '' $plus).Status -eq 'unknown') 'Stale reset treated as current availability'
$rpc.LimitsResponse.rateLimitsByLimitId=@{other=@{primary=@{usedPercent=0}}}
$thrown=$false
try { Convert-RpcUsageToRecord 'test' '' $rpc | Out-Null } catch { $thrown=$true }
Assert $thrown 'Unrelated bucket accepted as Codex'
Write-Output 'PASS: HTTP/RPC free windows, absent usage, fractional usage, denial, weekly exhaustion, stale resets, bucket selection.'
$now = [DateTimeOffset]::Now
$soon = [pscustomobject]@{ResetsAtUnix=$now.AddHours(2).ToUnixTimeSeconds()}
Assert ((Format-ResetDetail $soon $now) -match '^in 1h 59m|^in 2h 0m') 'Reset countdown incorrect'
Assert ((Format-ResetDetail ([pscustomobject]@{ResetsAtUnix=$null}) $now) -eq 'reset not reported') 'Missing reset fabricated'
Assert ((Format-ResetDetail ([pscustomobject]@{ResetsAtUnix=1}) $now) -match 'refresh needed') 'Expired reset not flagged'
Assert ((ConvertTo-DisplayText ("bad" + [char]27 + "[31m" + [char]10 + "name")) -notmatch '[\x00-\x1f]') 'Terminal control injection'
$script:Ansi=@{}
Assert ((Format-QuotaBadge $partial.Windows[0] 'available') -match '\[\u2588\u2591{7}\] 0.4% left') 'Tiny remaining quota not visible'
Assert ((Format-QuotaBadge $unknown.Windows[0] 'unknown') -eq '30-day ? left') 'Unknown quota rendered as a balance'
$http.Account='account1'; $http.Email='free@example.test'
$paid.Account='account5'; $paid.Email='plus@example.test'
$partial.Account='account12'; $partial.Email='alive@example.test'
$unknown.Account='account20'; $unknown.Email='unknown@example.test'
$errorRow=[pscustomobject]@{Account='account30';Email='';PlanType=$null;Status='error';Windows=@();Error='No login credentials.'}
$writer = [IO.StringWriter]::new()
$original = [Console]::Out
try {
    [Console]::SetOut($writer)
    Write-PrettyReport @($http,$paid,$partial,$unknown,$errorRow)
} finally { [Console]::SetOut($original) }
$report=$writer.ToString()
foreach ($name in @('account1','account5','account12','account20','account30')) {
    Assert (([regex]::Matches($report, "\b$name\b")).Count -eq 1) "Duplicate/missing account: $name"
}
Assert ($report -match 'ALIVE / 1' -and $report -match 'DEAD / 2' -and $report -match 'UNKNOWN / 1' -and $report -match 'ERRORS / 1') 'Section totals incorrect'
Assert ($report -match '\[FREE\]' -and $report -match '\[PLUS\]' -and $report -match 'Weekly \[\u2591{8}\] 0% left') 'Plan/window badges missing'
Assert ($report -notmatch '\x1b') 'Plain report contains ANSI'
Write-Output $report
Write-Output 'PASS: report grouping, plan badges, tiny/unknown balances, reset countdowns, sanitization and plain output.'
