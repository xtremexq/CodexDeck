function Get-DeckRouterPaths([string]$SuiteRoot) {
    $root=Join-Path $SuiteRoot 'deck/ai-router'
    @{Root=$root;App=(Join-Path $root 'app');Data=(Join-Path $root 'data');Service=(Join-Path $root 'service.json')}
}
function Get-DeckRouterStatus([string]$SuiteRoot) {
    $paths=Get-DeckRouterPaths $SuiteRoot; $service=Read-DeckJson $paths.Service
    $ready=$false
    if($service.Enabled){try{$health=Invoke-RestMethod 'http://127.0.0.1:5147/health' -TimeoutSec 1;$ready=$health.name -eq 'AIDeck Router'}catch{}}
    @{Installed=(Test-Path -LiteralPath (Join-Path $paths.App 'server/index.mjs'));Enabled=[bool]$service.Enabled;Ready=$ready;Pending=@(Read-DeckJson (Join-Path $paths.Data 'pairing.json'));Paths=$paths}
}
function Stop-DeckRouter([string]$SuiteRoot) {
    $paths=Get-DeckRouterPaths $SuiteRoot
    $saved=Read-DeckJson $paths.Service
    Write-DeckJson $paths.Service @{Enabled=$false;StartAtLogin=[bool]$saved.StartAtLogin}
    # The owning supervisor stops its own child after observing this flag.
    $running=Read-DeckJson (Join-Path $paths.Root 'supervisor.json')
    if($running){for($attempt=0;$attempt -lt 40;$attempt++){if(-not (Get-Process -Id $running.Pid -ErrorAction SilentlyContinue)){break};Start-Sleep -Milliseconds 100}}
}
function Install-DeckRouter([string]$SuiteRoot,[string]$SourceRoot,[bool]$EnableAtLogin=$true) {
    $node=Get-Command node.exe -ErrorAction SilentlyContinue
    $npm=Get-Command npm.cmd -ErrorAction SilentlyContinue
    if(-not $node -or -not $npm -or [int]((& $node.Source --version).TrimStart('v').Split('.')[0]) -lt 22){throw 'Install Node.js 22 or newer, reopen Deck, then install the router server.'}
    if(-not $SourceRoot){
        $SourceRoot=Join-Path $SuiteRoot 'router-source'
        if(-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'package.json'))){$SourceRoot=Join-Path (Split-Path (Split-Path $SuiteRoot -Parent) -Parent) 'aideck-router'}
    }
    foreach($file in @('package.json','package-lock.json','server/index.mjs','scripts/protect-key.ps1','ui/index.html')){if(-not (Test-Path -LiteralPath (Join-Path $SourceRoot $file) -PathType Leaf)){throw 'Router source is missing. Run the current Deck installer or choose the aideck-router source folder.'}}
    $paths=Get-DeckRouterPaths $SuiteRoot
    Stop-DeckRouter $SuiteRoot
    [void][IO.Directory]::CreateDirectory($paths.App)
    foreach($file in @('package.json','package-lock.json')){Copy-Item -LiteralPath (Join-Path $SourceRoot $file) -Destination (Join-Path $paths.App $file) -Force}
    foreach($directory in @('server','scripts','ui')){
        $destination=Join-Path $paths.App $directory;[void][IO.Directory]::CreateDirectory($destination)
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $SourceRoot $directory) -File){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name) -Force}
    }
    Push-Location $paths.App
    try{& $npm.Source ci --omit=dev --no-fund --no-audit | Out-Null;if($LASTEXITCODE -ne 0){throw 'Router dependencies could not be installed. Check the npm output and your connection.'}}finally{Pop-Location}
    Set-DeckRouterStartup $SuiteRoot $EnableAtLogin
    Start-DeckRouter $SuiteRoot
    'AI Router server installed and enabled. Open the extension and request pairing.'
}
function Start-DeckRouter([string]$SuiteRoot) {
    $paths=Get-DeckRouterPaths $SuiteRoot
    if(-not (Test-Path -LiteralPath (Join-Path $paths.App 'node_modules/undici/package.json'))){throw 'Install the AI Router server first.'}
    $saved=Read-DeckJson $paths.Service
    Write-DeckJson $paths.Service @{Enabled=$true;StartAtLogin=[bool]$saved.StartAtLogin}
    $existing=Read-DeckJson (Join-Path $paths.Root 'supervisor.json')
    if($existing){$process=Get-Process -Id $existing.Pid -ErrorAction SilentlyContinue;if($process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$existing.StartTicks){return}}
    $helper=(Join-Path $SuiteRoot 'Deck.RouterSupervisor.ps1').Replace("'","''")
    $command="& '$helper' -SuiteRoot '"+$SuiteRoot.Replace("'","''")+"'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $paths.Root 'supervisor-output.log') -RedirectStandardError (Join-Path $paths.Root 'supervisor-error.log') | Out-Null
}
function Set-DeckRouterStartup([string]$SuiteRoot,[bool]$Enabled) {
    $paths=Get-DeckRouterPaths $SuiteRoot;$saved=Read-DeckJson $paths.Service
    Write-DeckJson $paths.Service @{Enabled=[bool]$saved.Enabled;StartAtLogin=$Enabled}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$tag=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($SuiteRoot).ToLowerInvariant())))).Replace('-','').Substring(0,12)}finally{$sha.Dispose()}
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$name='AIDeckRouter-'+$tag
    if($Enabled){
        $helper=(Join-Path $SuiteRoot 'Deck.RouterSupervisor.ps1').Replace("'","''")
        $command="& '$helper' -SuiteRoot '"+$SuiteRoot.Replace("'","''")+"'"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        if(-not (Test-Path -LiteralPath $key)){[void](New-Item -Path $key -Force)}
        Set-ItemProperty -LiteralPath $key -Name $name -Value ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand '+$encoded)
    }elseif(Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue){Remove-ItemProperty -LiteralPath $key -Name $name}
}
function Open-DeckRouterDashboard([string]$SuiteRoot) {
    $status=Get-DeckRouterStatus $SuiteRoot
    if(-not $status.Ready){throw 'Start the AI Router server and wait for Ready.'}
    $url=& node.exe (Join-Path $status.Paths.App 'scripts/desktop.mjs') $status.Paths.Data
    if($LASTEXITCODE -ne 0 -or $url -notmatch '^http://127\.0\.0\.1:5147/#token=[A-Za-z0-9_-]+$'){throw 'Could not open the owner dashboard.'}
    Start-Process ([string]$url)
}
function Approve-DeckRouterPairing([string]$SuiteRoot,[string]$Id,[string]$Code) {
    $paths=Get-DeckRouterPaths $SuiteRoot
    $pending=@(Read-DeckJson (Join-Path $paths.Data 'pairing.json')) | Where-Object {$_.id -eq $Id -and $_.code -ceq $Code -and $_.expires -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}
    if(-not $pending){throw 'Pairing request expired. Request a new code in the extension.'}
    Write-DeckJson (Join-Path $paths.Data 'approvals.json') @{id=$Id;code=$Code}
}
