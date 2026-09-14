$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Storage.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-storage-'+[guid]::NewGuid().ToString('N'))
try{
    foreach($name in @('account1','account2','account3')){[void][IO.Directory]::CreateDirectory((Join-Path $fixture "accounts/$name"))}
    $payload=New-Object byte[] 131072;for($i=0;$i -lt $payload.Length;$i++){$payload[$i]=[byte]($i%251)}
    foreach($name in @('account1','account2')){
        $account=Join-Path $fixture "accounts/$name"
        foreach($relative in @('.sandbox-bin/codex.exe','plugins/cache/vendor/example/1.0/asset.bin','.tmp/plugins/.git/objects/pack/pack-example.pack')){
            $path=Join-Path $account $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllBytes($path,$payload)
        }
        [IO.File]::WriteAllText((Join-Path $account 'auth.json'),'{"kept":true}')
        [IO.File]::WriteAllText((Join-Path $account 'config.toml'),'model = "kept"')
    }
    $different=Join-Path $fixture 'accounts/account2/plugins/cache/vendor/example/1.0/different.bin'
    $otherPayload=New-Object byte[] 131072;for($i=0;$i -lt $otherPayload.Length;$i++){$otherPayload[$i]=[byte](250-($i%251))};[IO.File]::WriteAllBytes($different,$otherPayload)
    $staleBackup=Join-Path $fixture 'accounts/account1/.tmp/plugins-backup-old/repo'
    $staleClone=Join-Path $fixture 'accounts/account2/.tmp/plugins-clone-old'
    $freshClone=Join-Path $fixture 'accounts/account2/.tmp/plugins-clone-fresh'
    $orphanBackup=Join-Path $fixture 'accounts/account3/.tmp/plugins-backup-kept/repo'
    foreach($path in @($staleBackup,$staleClone,$freshClone,$orphanBackup)){[void][IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllText((Join-Path $path 'payload.txt'),'temporary')}
    foreach($path in @((Split-Path -Parent $staleBackup),$staleClone,(Split-Path -Parent $orphanBackup))){(Get-Item $path).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-2)}
    [IO.File]::SetAttributes((Join-Path $staleBackup 'payload.txt'),[IO.FileAttributes]::ReadOnly)
    [IO.File]::SetAttributes((Join-Path $fixture 'accounts/account2/plugins/cache/vendor/example/1.0/asset.bin'),[IO.FileAttributes]::ReadOnly)

    $result=Invoke-DeckStorageMaintenance $fixture -MinimumAgeHours 1 -MinimumCacheBytes 65536 -SkipProcessCheck
    Assert ($result.Status -eq 'complete') ('Maintenance failed: '+($result.Errors -join '; '))
    Assert ($result.DirectoriesRemoved -eq 2) 'Maintenance did not remove exactly the safe stale plugin directories.'
    Assert (-not (Test-Path -LiteralPath (Split-Path -Parent $staleBackup))) 'Stale plugin backup remains.'
    Assert (-not (Test-Path -LiteralPath $staleClone)) 'Stale plugin clone remains.'
    Assert (Test-Path -LiteralPath $freshClone) 'Fresh plugin clone was removed.'
    Assert (Test-Path -LiteralPath (Split-Path -Parent $orphanBackup)) 'Only recovery copy for a missing current plugin tree was removed.'
    Assert ($result.FilesLinked -ge 3 -and $result.LinkedBytes -ge (3*$payload.Length)) 'Identical managed storage was not deduplicated.'
    Initialize-DeckStorageNative
    foreach($relative in @('.sandbox-bin/codex.exe','plugins/cache/vendor/example/1.0/asset.bin','.tmp/plugins/.git/objects/pack/pack-example.pack')){
        $first=Join-Path $fixture "accounts/account1/$relative";$second=Join-Path $fixture "accounts/account2/$relative"
        Assert ([DeckStorageNative]::FileId($first) -eq [DeckStorageNative]::FileId($second)) "Managed file was not hard-linked: $relative"
        Assert ((Get-FileHash $first).Hash -eq (Get-FileHash $second).Hash) "Managed file content changed: $relative"
    }
    Assert ([DeckStorageNative]::FileId($different) -ne [DeckStorageNative]::FileId((Join-Path $fixture 'accounts/account1/plugins/cache/vendor/example/1.0/asset.bin'))) 'Different cache contents were linked.'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account1/auth.json')) -eq '{"kept":true}') 'Authentication data changed.'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'accounts/account2/config.toml')) -eq 'model = "kept"') 'Account configuration changed.'
    Assert (Test-Path -LiteralPath (Join-Path $fixture 'deck/storage-maintenance.json')) 'Maintenance report was not saved.'
    $second=Invoke-DeckStorageMaintenance $fixture -MinimumAgeHours 1 -MinimumCacheBytes 65536 -SkipProcessCheck
    Assert ($second.Status -eq 'complete') ('Second maintenance pass failed: '+($second.Errors -join '; '))
    Assert ($second.FilesLinked -eq 0 -and $second.LinkedBytes -eq 0) 'Already deduplicated files were processed again.'
    'PASS: stale plugin workspaces are safely reaped and identical managed runtimes/caches share disk blocks without merging account state.'
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
