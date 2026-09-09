$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Backup.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
function Refuses($action,$message){$failed=$false; try{& $action}catch{$failed=$true}; Assert $failed $message}
Initialize-DeckCrypto
# NIST AES-256-GCM all-zero key/nonce/plaintext test vector.
$tag=New-Object byte[] 16
$cipher=[DeckCrypto]::Transform($true,(New-Object byte[] 32),(New-Object byte[] 12),(New-Object byte[] 16),$tag,([byte[]]@()))
Assert (([BitConverter]::ToString($cipher) -replace '-','').ToLowerInvariant() -eq 'cea7403d4d606b6e074ec5d3baf39d18') 'AES-256-GCM ciphertext vector mismatch'
Assert (([BitConverter]::ToString($tag) -replace '-','').ToLowerInvariant() -eq 'd0d1c8a799996bf0265b98b5d48ab919') 'AES-256-GCM authentication vector mismatch'
$testRoot=Join-Path $env:TEMP ('deck-backup-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'source/accounts/example'))
$source=Join-Path $testRoot 'source'; $dest=Join-Path $testRoot 'restored'; $path=Join-Path $testRoot 'test.cdeck'
$password=ConvertTo-SecureString 'Synthetic backup password 42!' -AsPlainText -Force
try{
    [IO.File]::WriteAllText((Join-Path $source 'accounts/example/auth.json'),'{"synthetic":"not-a-real-token"}')
    [IO.File]::WriteAllText((Join-Path $source 'accounts/example/config.toml'),'model = "example"')
    [IO.File]::WriteAllText((Join-Path $source 'accounts/example/history.jsonl'),'excluded chat')
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'accounts/pool'))
    $poolMetadata='{"Version":1,"Kind":"pool","Accounts":["*"],"Mode":"Ordered"}'
    [IO.File]::WriteAllText((Join-Path $source 'accounts/pool/deck-entry.json'),$poolMetadata)
    [IO.File]::WriteAllText((Join-Path $testRoot 'defaults.toml'),'synthetic defaults')
    Assert ((Export-DeckBackup $source (Join-Path $testRoot 'defaults.toml') $path $password) -eq 2) 'Wrong export account count'
    Assert (-not ([IO.File]::ReadAllText($path).Contains('not-a-real-token'))) 'Plaintext credential leaked'
    $manifest=Read-DeckBackup $path $password
    Assert (@($manifest.Files).Count -eq 4) 'Backup included runtime history or missed config'
    Assert ((Import-DeckBackup $dest (Join-Path $testRoot 'restored-defaults.toml') $manifest -RestorePreferences) -eq 2) 'Import failed'
    Assert ([IO.File]::ReadAllText((Join-Path $dest 'accounts/pool/deck-entry.json')) -eq $poolMetadata) 'Pool identity did not round-trip'
    Assert ([IO.File]::ReadAllText((Join-Path $dest 'accounts/example/auth.json')) -eq '{"synthetic":"not-a-real-token"}') 'Credentials did not round-trip'
    Refuses {Import-DeckBackup $dest (Join-Path $testRoot 'restored-defaults.toml') $manifest} 'Import overwrote an existing account'
    Refuses {Read-DeckBackup $path (ConvertTo-SecureString 'Different password' -AsPlainText -Force)} 'Wrong password accepted'
    $envelope=[IO.File]::ReadAllText($path) | ConvertFrom-Json; $bytes=[Convert]::FromBase64String($envelope.Data); $bytes[0]=$bytes[0] -bxor 1; $envelope.Data=[Convert]::ToBase64String($bytes)
    $tampered=Join-Path $testRoot 'tampered.cdeck'; [IO.File]::WriteAllText($tampered,($envelope | ConvertTo-Json))
    Refuses {Read-DeckBackup $tampered $password} 'Tampered ciphertext accepted'
    $manifest.Files[0].Path='accounts/../../escape/auth.json'
    Refuses {Import-DeckBackup (Join-Path $testRoot 'unsafe') (Join-Path $testRoot 'defaults2.toml') $manifest} 'Traversal accepted'
    Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'unsafe'))) 'Invalid import changed filesystem'
    'PASS: AES-GCM known vector, encrypted round-trip, runtime exclusion, collision refusal, wrong password, tampering and traversal. Synthetic data only.'
}finally{
    $password.Dispose()
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\') -and (Split-Path $resolved -Leaf) -like 'deck-backup-test-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
