param([switch]$KeepOnFailure)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
try{$occupied=Invoke-RestMethod 'http://127.0.0.1:5147/health' -TimeoutSec 1}catch{}
if($occupied){throw 'Port 5147 is already in use; stop the existing service before this isolated test.'}
$fixture=Join-Path $env:TEMP ('deck-router-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$core=(Join-Path $PSScriptRoot 'Deck.Core.ps1').Replace("'","''")
[IO.File]::WriteAllText((Join-Path $fixture 'Deck.Core.ps1'),(". '$core'"),[Text.UTF8Encoding]::new($true))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deck.RouterSupervisor.ps1') -Destination $fixture
function Wait-Ready {
    $until=[DateTimeOffset]::UtcNow.AddSeconds(25)
    do{Start-Sleep -Milliseconds 300;$status=Get-DeckRouterStatus $fixture;if($status.Ready){return $status}}while([DateTimeOffset]::UtcNow -lt $until)
    throw 'Isolated router server did not become ready.'
}
$passed=$false
try{
    Install-DeckRouter $fixture (Join-Path $PSScriptRoot 'router-source') -EnableAtLogin:$false | Out-Null
    $status=Wait-Ready
    $first=Read-DeckJson (Join-Path $status.Paths.Data 'runtime.json')
    $proof=('s'*64);$headers=@{Origin=('chrome-extension://'+('a'*32))}
    $pending=Invoke-RestMethod 'http://127.0.0.1:5147/pair' -Method Post -ContentType 'application/json' -Headers $headers -Body (@{secret=$proof}|ConvertTo-Json -Compress)
    $headers.Authorization='Bearer '+$proof
    $waiting=Invoke-RestMethod ('http://127.0.0.1:5147/pair/'+$pending.id) -Headers $headers
    if($waiting.status -ne 'pending'){throw 'Pairing must wait for approval.'}
    Approve-DeckRouterPairing $fixture $pending.id $pending.code
    $paired=Invoke-RestMethod ('http://127.0.0.1:5147/pair/'+$pending.id) -Headers $headers
    if($paired.status -ne 'approved' -or -not $paired.token -or $paired.bridgeKey -notmatch '^aid_'){throw 'Pairing did not produce scoped bridge and owner keys.'}
    Stop-Process -Id $first.pid -Force
    Start-Sleep -Seconds 4
    $status=Wait-Ready
    $second=Read-DeckJson (Join-Path $status.Paths.Data 'runtime.json')
    if($first.pid -eq $second.pid){throw 'Server was not restarted.'}
    $ownerHeaders=@{Authorization=('Bearer '+$paired.token)}
    $state=Invoke-RestMethod 'http://127.0.0.1:5147/admin/state' -Headers $ownerHeaders
    if($state.config.clients.Count -ne 1){throw 'Pairing and settings did not survive restart.'}
    Stop-DeckRouter $fixture
    foreach($log in @('server-output.log','server-error.log')){if([IO.File]::ReadAllText((Join-Path $status.Paths.Root $log)).Contains($paired.token)){throw 'Owner key leaked into managed server logs.'}}
    Stop-DeckRouter $fixture
    if((Get-DeckRouterStatus $fixture).Enabled){throw 'Stop did not disable service.'}
    $passed=$true
    'PASS: isolated install, supervisor, pairing approval, process restart, persistent pairing, private logs and stop. No live Deck state or startup registry was changed.'
}finally{
    Stop-DeckRouter $fixture
    $resolved=[IO.Path]::GetFullPath($fixture);$expected=[IO.Path]::GetFullPath($env:TEMP)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup escaped the temporary directory.'}
    if(-not $passed -and $KeepOnFailure){Write-Host ('Diagnostics retained: '+$resolved)}else{Remove-Item -LiteralPath $resolved -Recurse -Force}
}
