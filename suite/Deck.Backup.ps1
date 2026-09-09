# Encrypted, versioned configuration backup. Runtime databases and logs are not portable configuration.
function Initialize-DeckCrypto {
    if(-not ('DeckCrypto' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Deck.Crypto.cs')}
}
function Get-DeckPasswordKey([Security.SecureString]$Password,[byte[]]$Salt) {
    Initialize-DeckCrypto
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
    $chars=New-Object char[] $Password.Length; $bytes=$null
    try {
        [Runtime.InteropServices.Marshal]::Copy($ptr,$chars,0,$chars.Length)
        $bytes=[Text.Encoding]::UTF8.GetBytes($chars)
        return ,([DeckCrypto]::Derive($bytes,$Salt))
    } finally {
        [Array]::Clear($chars,0,$chars.Length); if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
    }
}
function Test-DeckBackupPath([string]$Path) {
    return $Path -cmatch '^(accounts/[a-zA-Z][a-zA-Z0-9_-]{0,39}/(auth\.json|config\.toml|AGENTS\.md|deck-entry\.json)|deck/(settings|views|pins|warmup)\.json|accounts/AGENTS\.shared\.md|defaults/config\.toml)$'
}
function Export-DeckBackup([string]$SuiteRoot,[string]$DefaultsPath,[string]$Path,[Security.SecureString]$Password) {
    if($Password.Length -lt 12){throw 'Use a password with at least 12 characters.'}
    if(Test-Path -LiteralPath $Path){throw 'That backup file already exists. Choose a new filename.'}
    Initialize-DeckCrypto
    $files=@(); $accounts=@(); $total=0
    foreach($dir in @(Get-ChildItem -LiteralPath (Join-Path $SuiteRoot 'accounts') -Directory -ErrorAction SilentlyContinue)){
        if($dir.Name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){continue}
        if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked account folders cannot be exported.'}
        $accounts+= $dir.Name
        foreach($name in @('auth.json','config.toml','AGENTS.md','deck-entry.json')){if(Test-Path -LiteralPath (Join-Path $dir.FullName $name)){$files+= "accounts/$($dir.Name)/$name"}}
    }
    if(Test-Path -LiteralPath (Join-Path $SuiteRoot 'accounts/AGENTS.shared.md')){$files+='accounts/AGENTS.shared.md'}
    foreach($name in @('settings','views','pins','warmup')){if(Test-Path -LiteralPath (Join-Path $SuiteRoot "deck/$name.json")){$files+="deck/$name.json"}}
    if(Test-Path -LiteralPath $DefaultsPath){$files+='defaults/config.toml'}
    $entries=foreach($name in $files){
        $source=if($name -eq 'defaults/config.toml'){$DefaultsPath}else{Join-Path $SuiteRoot $name}
        $info=Get-Item -LiteralPath $source
        if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $name -notmatch '/AGENTS\.md$'){throw 'Linked configuration files cannot be exported.'}
        $total+=$info.Length; if($total -gt 16777216){throw 'Configuration backup exceeds the 16 MB limit.'}
        $data=[IO.File]::ReadAllBytes($source)
        try{[ordered]@{Path=$name;Data=[Convert]::ToBase64String($data)}}finally{[Array]::Clear($data,0,$data.Length)}
    }
    $plain=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Depth 8 -Compress -InputObject @{Version=1;Created=[DateTimeOffset]::UtcNow.ToString('o');Accounts=@($accounts);Files=@($entries)}))
    $salt=[DeckCrypto]::Random(16); $nonce=[DeckCrypto]::Random(12); $tag=New-Object byte[] 16; $key=$null
    try {
        $key=Get-DeckPasswordKey $Password $salt
        $cipher=[DeckCrypto]::Transform($true,$key,$nonce,$plain,$tag,[Text.Encoding]::ASCII.GetBytes('CodexDeck/1/AES-256-GCM/PBKDF2-SHA256/600000'))
        $envelope=@{Format='CodexDeck';Version=1;Cipher='AES-256-GCM';Kdf='PBKDF2-SHA256';Iterations=600000;Salt=[Convert]::ToBase64String($salt);Nonce=[Convert]::ToBase64String($nonce);Tag=[Convert]::ToBase64String($tag);Data=[Convert]::ToBase64String($cipher)}
        # CreateNew refuses races and accidental overwrites. Only ciphertext reaches disk.
        $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$encoded=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress $envelope)); $stream.Write($encoded,0,$encoded.Length)}finally{$stream.Dispose()}
        return $accounts.Count
    } finally {if($key){[Array]::Clear($key,0,$key.Length)}; [Array]::Clear($plain,0,$plain.Length)}
}
function Read-DeckBackup([string]$Path,[Security.SecureString]$Password) {
    Initialize-DeckCrypto
    if((Get-Item -LiteralPath $Path).Length -gt 33554432){throw 'Backup exceeds the 32 MB file limit.'}
    $envelope=[IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if($envelope.Format -cne 'CodexDeck' -or $envelope.Version -ne 1 -or $envelope.Cipher -cne 'AES-256-GCM' -or $envelope.Kdf -cne 'PBKDF2-SHA256' -or $envelope.Iterations -ne 600000){throw 'Unsupported backup format.'}
    $salt=[Convert]::FromBase64String($envelope.Salt); $nonce=[Convert]::FromBase64String($envelope.Nonce); $tag=[Convert]::FromBase64String($envelope.Tag)
    if($salt.Length -ne 16 -or $nonce.Length -ne 12 -or $tag.Length -ne 16){throw 'Invalid backup header.'}
    $key=$null; $plain=$null
    try {
        $key=Get-DeckPasswordKey $Password $salt
        try{$plain=[DeckCrypto]::Transform($false,$key,$nonce,[Convert]::FromBase64String($envelope.Data),$tag,[Text.Encoding]::ASCII.GetBytes('CodexDeck/1/AES-256-GCM/PBKDF2-SHA256/600000'))}catch{throw 'Wrong password or damaged backup. Nothing was restored.'}
        $manifest=[Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        if($manifest.Version -ne 1 -or $null -eq $manifest.Accounts -or $null -eq $manifest.Files){throw 'Invalid backup manifest.'}
        $seen=@{}; $names=@{}; $total=0
        foreach($name in $manifest.Accounts){if($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $names.ContainsKey($name)){throw 'Invalid or duplicate account name.'}; $names[$name]=$true}
        foreach($entry in $manifest.Files){
            if(-not (Test-DeckBackupPath $entry.Path) -or $seen.ContainsKey($entry.Path)){throw 'Invalid or duplicate backup path.'}
            if($entry.Path -match '^accounts/([^/]+)/' -and -not $names.ContainsKey($Matches[1])){throw 'Undeclared account in backup.'}
            $seen[$entry.Path]=$true; $data=[Convert]::FromBase64String($entry.Data); $total+=$data.Length; [Array]::Clear($data,0,$data.Length)
            if($total -gt 16777216){throw 'Expanded backup exceeds the configuration size limit.'}
        }
        return $manifest
    }finally{if($key){[Array]::Clear($key,0,$key.Length)}; if($plain){[Array]::Clear($plain,0,$plain.Length)}}
}
function Import-DeckBackup([string]$SuiteRoot,[string]$DefaultsPath,$Manifest,[switch]$RestorePreferences) {
    # Validate again at the mutation boundary, including all destination ancestors.
    $base=[IO.Path]::GetFullPath($SuiteRoot); $accountRoot=Join-Path $base 'accounts'
    foreach($name in $Manifest.Accounts){
        if($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){throw 'Invalid account name.'}
        if(Test-Path -LiteralPath (Join-Path $accountRoot $name)){throw "Account '$name' already exists. Import into a Deck without that account, or rename the existing account first."}
    }
    $targets=@(); $seen=@{}
    foreach($entry in $Manifest.Files){
        if(-not (Test-DeckBackupPath $entry.Path) -or $seen.ContainsKey($entry.Path)){throw 'Invalid backup path.'}; $seen[$entry.Path]=$true
        if($entry.Path -match '^accounts/([^/]+)/' -and $Matches[1] -notin $Manifest.Accounts){throw 'Undeclared account.'}
        if(-not $RestorePreferences -and ($entry.Path -notlike 'accounts/*' -or $entry.Path -eq 'accounts/AGENTS.shared.md')){continue}
        $target=if($entry.Path -eq 'defaults/config.toml'){[IO.Path]::GetFullPath($DefaultsPath)}else{Join-Path $base $entry.Path}
        for($ancestor=$target;$ancestor;$ancestor=Split-Path -Parent $ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -Force -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Restore destinations cannot contain links.'}}}
        $targets+=@{Path=$target;Data=[Convert]::FromBase64String($entry.Data)}
    }
    $created=@(); $written=@(); $previous=@{}
    try {
        foreach($name in $Manifest.Accounts){$dir=Join-Path $accountRoot $name; for($ancestor=$dir;$ancestor;$ancestor=Split-Path -Parent $ancestor){if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -Force -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Restore destinations cannot contain links.'}}; [void][IO.Directory]::CreateDirectory($dir); $created+=$dir}
        foreach($item in $targets){
            [void][IO.Directory]::CreateDirectory((Split-Path $item.Path))
            if(Test-Path -LiteralPath $item.Path){$previous[$item.Path]=[IO.File]::ReadAllBytes($item.Path)}
            $written+=$item.Path; [IO.File]::WriteAllBytes($item.Path,$item.Data)
        }
    }catch{
        foreach($path in $written){if($previous.ContainsKey($path)){[IO.File]::WriteAllBytes($path,$previous[$path])}else{Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
        foreach($dir in $created){if((Get-ChildItem -LiteralPath $dir -Force | Measure-Object).Count -eq 0){Remove-Item -LiteralPath $dir -Force}}
        throw
    }finally{foreach($item in $targets){[Array]::Clear($item.Data,0,$item.Data.Length)}; foreach($data in $previous.Values){[Array]::Clear($data,0,$data.Length)}}
    return @($Manifest.Accounts).Count
}
