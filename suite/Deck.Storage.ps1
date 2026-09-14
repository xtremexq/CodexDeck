param(
    [switch]$DeckStorageMaintenance,
    [string]$DeckStorageSuiteRoot=$PSScriptRoot,
    [switch]$DeckStorageReportOnly
)

function Initialize-DeckStorageNative {
    if('DeckStorageNative' -as [type]){return}
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DeckStorageNative {
    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandle(IntPtr handle, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CreateHardLinkW(string newName, string existingName, IntPtr security);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool MoveFileExW(string existingName, string newName, uint flags);

    public static string FileId(string path) {
        IntPtr handle=CreateFileW(path,0,7,IntPtr.Zero,3,0x80,IntPtr.Zero);
        if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            BY_HANDLE_FILE_INFORMATION info;
            if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info.VolumeSerialNumber.ToString("x8")+":"+info.FileIndexHigh.ToString("x8")+info.FileIndexLow.ToString("x8");
        } finally { CloseHandle(handle); }
    }

    public static void CreateHardLink(string newName,string existingName) {
        if(!CreateHardLinkW(newName,existingName,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void MoveReplace(string existingName,string newName) {
        const uint MOVEFILE_REPLACE_EXISTING=0x1;
        const uint MOVEFILE_WRITE_THROUGH=0x8;
        if(!MoveFileExW(existingName,newName,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}

function Get-DeckStorageTreeFiles([string]$Path,[long]$MinimumBytes=0) {
    if(-not (Test-Path -LiteralPath $Path -PathType Container)){return}
    $root=Get-Item -LiteralPath $Path -Force
    if($root.Attributes -band [IO.FileAttributes]::ReparsePoint){return}
    $pending=[Collections.Generic.Stack[IO.DirectoryInfo]]::new();$pending.Push($root)
    while($pending.Count){
        $directory=$pending.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if($item.PSIsContainer){$pending.Push($item);continue}
            if($item.Length -ge $MinimumBytes){$item}
        }
    }
}

function Get-DeckStorageTreeBytes([string]$Path) {
    [long]$bytes=0
    foreach($file in @(Get-DeckStorageTreeFiles $Path)){$bytes+=[long]$file.Length}
    return $bytes
}

function Remove-DeckStorageTree([string]$Path) {
    foreach($file in @(Get-DeckStorageTreeFiles $Path)){
        if($file.Attributes -band [IO.FileAttributes]::ReadOnly){
            [IO.File]::SetAttributes($file.FullName,($file.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        }
    }
    $root=Get-Item -LiteralPath $Path -Force
    if($root.Attributes -band [IO.FileAttributes]::ReadOnly){
        [IO.File]::SetAttributes($root.FullName,($root.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
    }
    [IO.Directory]::Delete($Path,$true)
}

function Test-DeckCodexProcessRunning {
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)){
        if($process.Name -match '^codex(?:-[^\\]+)?\.exe$'){return $true}
        if($process.Name -eq 'node.exe' -and [string]$process.CommandLine -match '(?i)(?:@openai[\\/]codex|codex(?:\.js|\.cmd))'){return $true}
    }
    return $false
}

function Get-DeckActiveAccountNames([string]$SuiteRoot) {
    $accountsRoot=[IO.Path]::GetFullPath((Join-Path $SuiteRoot 'accounts')).TrimEnd('\')
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if($env:CODEX_HOME){
        try{
            $activePath=[IO.Path]::GetFullPath($env:CODEX_HOME).TrimEnd('\')
            if((Split-Path -Parent $activePath) -eq $accountsRoot){[void]$names.Add((Split-Path -Leaf $activePath))}
        }catch{}
    }
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $SuiteRoot 'deck/sessions') -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        try{
            $session=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json
            if($session.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -and (Get-Process -Id ([int]$session.ProcessId) -ErrorAction SilentlyContinue)){
                [void]$names.Add([string]$session.Account)
            }
        }catch{}
    }
    return @($names)
}

function Get-DeckStorageState([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'deck/storage-maintenance.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{return [IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{return $null}
}

function Write-DeckStorageState([string]$SuiteRoot,$State) {
    $directory=Join-Path $SuiteRoot 'deck';[void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory 'storage-maintenance.json';$temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($State|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}

function Test-DeckStorageMaintenanceDue([string]$SuiteRoot,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    $state=Get-DeckStorageState $SuiteRoot
    if(-not $state -or -not $state.AttemptedAt){return $true}
    try{
        $age=($Now-[DateTimeOffset]$state.AttemptedAt).TotalHours
        return $age -ge $(if($state.Status -in @('skipped-running','complete-active-skipped','complete-with-errors','failed')){6}else{168})
    }catch{return $true}
}

function Get-DeckManagedStorageFiles([string]$SuiteRoot,[long]$MinimumCacheBytes=1048576,[string[]]$ExcludeAccounts=@()) {
    $accountsRoot=Join-Path $SuiteRoot 'accounts'
    foreach($account in @(Get-ChildItem -LiteralPath $accountsRoot -Directory -Force -ErrorAction SilentlyContinue)){
        if($account.Name -in $ExcludeAccounts){continue}
        foreach($file in @(Get-DeckStorageTreeFiles (Join-Path $account.FullName '.sandbox-bin') 1)){
            [pscustomobject]@{File=$file;Kind='sandbox-runtime'}
        }
        foreach($file in @(Get-DeckStorageTreeFiles (Join-Path $account.FullName 'plugins/cache') $MinimumCacheBytes)){
            [pscustomobject]@{File=$file;Kind='plugin-install-cache'}
        }
        foreach($file in @(Get-DeckStorageTreeFiles (Join-Path $account.FullName '.tmp/plugins') $MinimumCacheBytes)){
            [pscustomobject]@{File=$file;Kind='plugin-curated-repo'}
        }
    }
}

function Invoke-DeckStorageMaintenance(
    [string]$SuiteRoot,
    [int]$MinimumAgeHours=24,
    [long]$MinimumCacheBytes=1048576,
    [switch]$ReportOnly,
    [switch]$SkipProcessCheck
) {
    $accountsRoot=Join-Path $SuiteRoot 'accounts'
    if(-not (Test-Path -LiteralPath $accountsRoot -PathType Container)){throw 'Codex Deck accounts directory is missing.'}
    $started=[DateTimeOffset]::UtcNow
    $result=[ordered]@{Status='complete';AttemptedAt=$started.ToString('o');CompletedAt=$null;AccountsSkipped=@();DirectoriesRemoved=0;RemovedBytes=[long]0;FilesLinked=0;LinkedBytes=[long]0;Errors=@()}
    $codexRunning=-not $SkipProcessCheck -and (Test-DeckCodexProcessRunning)
    $activeAccounts=if($codexRunning){@(Get-DeckActiveAccountNames $SuiteRoot)}else{@()}
    if($codexRunning -and -not $activeAccounts.Count){
        $result.Status='skipped-running';$result.CompletedAt=[DateTimeOffset]::UtcNow.ToString('o')
        if(-not $ReportOnly){Write-DeckStorageState $SuiteRoot $result}
        return [pscustomobject]$result
    }
    $result.AccountsSkipped=@($activeAccounts|Sort-Object)
    $lockPath=Join-Path $SuiteRoot 'deck/storage-maintenance.lock';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath))
    $lock=$null
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{
        $result.Status='skipped-busy';$result.Errors=@($_.Exception.Message);$result.CompletedAt=[DateTimeOffset]::UtcNow.ToString('o')
        return [pscustomobject]$result
    }
    try{
        $cutoff=[DateTime]::UtcNow.AddHours(-[Math]::Max(1,$MinimumAgeHours))
        foreach($account in @(Get-ChildItem -LiteralPath $accountsRoot -Directory -Force -ErrorAction SilentlyContinue)){
            if($account.Name -in $activeAccounts){continue}
            $tempRoot=Join-Path $account.FullName '.tmp'
            $currentPlugins=Join-Path $tempRoot 'plugins'
            foreach($directory in @(Get-ChildItem -LiteralPath $tempRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '^plugins-(?:backup|clone)-[A-Za-z0-9]+$' -and $_.LastWriteTimeUtc -lt $cutoff})){
                if($directory.Name -like 'plugins-backup-*' -and -not (Test-Path -LiteralPath $currentPlugins -PathType Container)){continue}
                try{
                    [long]$bytes=Get-DeckStorageTreeBytes $directory.FullName
                    if(-not $ReportOnly){Remove-DeckStorageTree $directory.FullName}
                    $result.DirectoriesRemoved++;$result.RemovedBytes+=$bytes
                }catch{$result.Errors+=@($directory.FullName+': '+$_.Exception.Message)}
            }
        }
        $candidates=@(Get-DeckManagedStorageFiles $SuiteRoot $MinimumCacheBytes $activeAccounts)
        if($candidates.Count){Initialize-DeckStorageNative}
        foreach($lengthGroup in @($candidates|Group-Object {$_.Kind+':'+$_.File.Length}|Where-Object Count -gt 1)){
            $identities=@{}
            foreach($candidate in $lengthGroup.Group){
                try{$identity=[DeckStorageNative]::FileId($candidate.File.FullName)}catch{$result.Errors+=@($candidate.File.FullName+': '+$_.Exception.Message);continue}
                if(-not $identities.ContainsKey($identity)){$identities[$identity]=[Collections.Generic.List[object]]::new()}
                $identities[$identity].Add($candidate)
            }
            if($identities.Count -lt 2){continue}
            $hashes=@{}
            foreach($identity in $identities.Keys){
                $identityFiles=$identities[$identity]
                $candidate=$identityFiles[0]
                try{$hash=(Get-FileHash -LiteralPath $candidate.File.FullName -Algorithm SHA256).Hash}catch{$result.Errors+=@($candidate.File.FullName+': '+$_.Exception.Message);continue}
                if(-not $hashes.ContainsKey($hash)){$hashes[$hash]=[Collections.Generic.List[object]]::new()}
                $hashes[$hash].Add([pscustomobject]@{Identity=$identity;Files=$identityFiles})
            }
            foreach($same in @($hashes.Values|Where-Object Count -gt 1)){
                $canonical=$same[0].Files[0].File.FullName
                $canonicalId=$same[0].Identity
                foreach($duplicateIdentity in @($same|Select-Object -Skip 1)){
                    $identityReplaced=$true
                    foreach($duplicate in @($duplicateIdentity.Files)){
                        $path=$duplicate.File.FullName
                        try{
                            if(-not $ReportOnly){
                                $targetAttributes=[IO.File]::GetAttributes($path)
                                $targetRestored=$false
                                if($targetAttributes -band [IO.FileAttributes]::ReadOnly){
                                    [IO.File]::SetAttributes($path,($targetAttributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
                                }
                                $temporary=$path+'.deck-link-'+[guid]::NewGuid().ToString('N')+'.tmp'
                                try{
                                    [DeckStorageNative]::CreateHardLink($temporary,$canonical)
                                    [DeckStorageNative]::MoveReplace($temporary,$path)
                                    if([DeckStorageNative]::FileId($path) -ne $canonicalId){throw 'Hard-link replacement did not retain the canonical file identity.'}
                                }finally{
                                    if(Test-Path -LiteralPath $temporary){
                                        $canonicalAttributes=[IO.File]::GetAttributes($canonical)
                                        try{
                                            $temporaryAttributes=[IO.File]::GetAttributes($temporary)
                                            if($temporaryAttributes -band [IO.FileAttributes]::ReadOnly){
                                                [IO.File]::SetAttributes($temporary,($temporaryAttributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
                                            }
                                            [IO.File]::Delete($temporary)
                                        }finally{[IO.File]::SetAttributes($canonical,$canonicalAttributes)}
                                    }
                                    if((Test-Path -LiteralPath $path) -and [DeckStorageNative]::FileId($path) -ne $canonicalId){
                                        [IO.File]::SetAttributes($path,$targetAttributes);$targetRestored=$true
                                    }
                                }
                            }
                            $result.FilesLinked++
                        }catch{$identityReplaced=$false;$result.Errors+=@($path+': '+$_.Exception.Message)}
                    }
                    if($identityReplaced){
                        $result.LinkedBytes+=[long]$duplicateIdentity.Files[0].File.Length
                    }elseif($ReportOnly){
                        $result.LinkedBytes+=[long]$duplicateIdentity.Files[0].File.Length
                    }
                }
            }
        }
        if($result.Errors.Count){$result.Status='complete-with-errors'}elseif($activeAccounts.Count){$result.Status='complete-active-skipped'}
        if($ReportOnly){$result.Status='report-only'}
        $result.CompletedAt=[DateTimeOffset]::UtcNow.ToString('o')
        if(-not $ReportOnly){Write-DeckStorageState $SuiteRoot $result}
        return [pscustomobject]$result
    }finally{if($lock){$lock.Dispose()}}
}

function Start-DeckStorageMaintenance([string]$SuiteRoot,[switch]$Force) {
    if(-not $Force -and -not (Test-DeckStorageMaintenanceDue $SuiteRoot)){return $null}
    $scriptPath=Join-Path $SuiteRoot 'Deck.Storage.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){return $null}
    $process=Start-DeckBackgroundPowerShell $scriptPath @('-DeckStorageMaintenance','-DeckStorageSuiteRoot',$SuiteRoot)
    return $process
}

if($DeckStorageMaintenance){
    try{Invoke-DeckStorageMaintenance $DeckStorageSuiteRoot -ReportOnly:$DeckStorageReportOnly|ConvertTo-Json -Depth 8}catch{
        $failed=[pscustomobject]@{Status='failed';AttemptedAt=[DateTimeOffset]::UtcNow.ToString('o');CompletedAt=[DateTimeOffset]::UtcNow.ToString('o');AccountsSkipped=@();DirectoriesRemoved=0;RemovedBytes=[long]0;FilesLinked=0;LinkedBytes=[long]0;Errors=@($_.Exception.Message)}
        if(-not $DeckStorageReportOnly){Write-DeckStorageState $DeckStorageSuiteRoot $failed}
        $failed|ConvertTo-Json -Depth 8
        exit 1
    }
}
