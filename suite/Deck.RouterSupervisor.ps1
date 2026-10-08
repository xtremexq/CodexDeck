param([Parameter(Mandatory=$true)][Alias('SuiteRoot')][string]$RouterSuiteRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RouterSuiteRoot 'Deck.Core.ps1')
$paths=Get-DeckRouterPaths $RouterSuiteRoot
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$created=$false;$mutex=[Threading.Mutex]::new($true,('Local\DeckRouter-'+$sid+'-'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($RouterSuiteRoot))).Replace('/','_')),[ref]$created)
if(-not $created){$mutex.Dispose();exit}
$process=Get-Process -Id $PID
Write-DeckJson (Join-Path $paths.Root 'supervisor.json') @{Pid=$PID;StartTicks=$process.StartTime.ToUniversalTime().Ticks}
$node=Get-Command node.exe -ErrorAction Stop
$env:AIDECK_DATA_DIR=$paths.Data;$env:AIDECK_MANAGED='1';$env:AIDECK_PORT='5147';$env:AIDECK_DECK_ROOT=$RouterSuiteRoot
$env:AIDECK_DECK_SCRIPT=Join-Path $HOME '.local/bin/codex-auth.ps1'
if(-not (Test-Path -LiteralPath $env:AIDECK_DECK_SCRIPT)){$env:AIDECK_DECK_SCRIPT=Join-Path (Split-Path $RouterSuiteRoot -Parent) 'bin/codex-auth.ps1'}
$child=$null
try{
    while((Read-DeckJson $paths.Service).Enabled){
        # Own exactly this child. Never stop a process merely because it uses the port.
        $entry=Join-Path $paths.App 'server/index.mjs'
        $child=Start-Process -FilePath $node.Source -ArgumentList ('"'+$entry+'"') -WorkingDirectory $paths.App -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $paths.Root 'server-output.log') -RedirectStandardError (Join-Path $paths.Root 'server-error.log')
        while(-not $child.HasExited -and (Read-DeckJson $paths.Service).Enabled){Start-Sleep -Milliseconds 500;$child.Refresh()}
        if(-not $child.HasExited){$child.Kill();$child.WaitForExit()}
        $child.Dispose();$child=$null
        if((Read-DeckJson $paths.Service).Enabled){Start-Sleep -Seconds 3}
    }
}finally{
    if($child){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    Remove-Item -LiteralPath (Join-Path $paths.Root 'supervisor.json') -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex();$mutex.Dispose()
}
