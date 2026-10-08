$ErrorActionPreference = 'Stop'
$spec = [Console]::In.ReadToEnd() | ConvertFrom-Json
function Literal([string]$value) { return "'" + $value.Replace("'", "''") + "'" }
$command = '& ' + (Literal $spec.script) + ' -Account ' + (Literal $spec.account)
if ($spec.action -eq 'create') {
    $command += ' -NewAccount -Harness ' + (Literal $spec.harness) + ' -Provider ' + (Literal $spec.provider)
} elseif ($spec.action -eq 'login') {
    $command += ' login'
} else {
    if ($spec.pool) { $command += ' -Pool' }
    if ($spec.harness -eq 'Codex') { $command += ' -Failover ' + (Literal $spec.failover) }
}
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -WindowStyle Normal | Out-Null
