param([string]$InstallHome = $HOME, [switch]$SkipPath)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Codex Deck requires Windows and Windows PowerShell 5.1 with WPF.' }
$suiteRoot = Join-Path $InstallHome '.codex-loop'
$binRoot = Join-Path $InstallHome '.local/bin'
$files = @('Codex-Deck.ps1','Deck.Core.ps1','Deck.Commands.ps1','Deck.WarmupWorker.ps1','Deck.GlobalRules.ps1','Deck.GlobalRules.cjs','Deck.Environments.ps1','Deck.EnvironmentSettings.ps1','Deck.AccountTools.ps1','Deck.Failover.ps1','Deck.Failover.cjs','Deck.Terminal.ps1','Deck.Backup.ps1','Deck.Crypto.cs','Deck.SettingsExtras.ps1','Deck.Theme.xaml','Run-CodexLoopUsage.cmd',
    'Test-Deck.ps1','Test-DeckCommands.ps1','Test-DeckEnvironments.ps1','Test-DeckEnvironmentLaunch.ps1','Test-DeckAccountTools.ps1','Test-DeckFailover.ps1','Test-DeckScheduler.ps1','Test-DeckBackup.ps1','Test-CodexAuth.ps1','Test-CodexLoopUsage.ps1',
    'deck/assets/codex-deck.png','deck/assets/codex-deck.ico')
$wrappers = @('codex-auth.ps1','codex-auth.cmd','codex-check.cmd','codex-deck.cmd','codex-deck-session.ps1','codex-deck-session.cmd','account.cmd','pool.cmd','usage.cmd','check.cmd')
# Validate the complete payload before changing an existing installation.
foreach ($name in $files) { if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot "suite/$name") -PathType Leaf)) { throw "Missing suite file: $name" } }
foreach ($name in $wrappers) { if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot "bin/$name") -PathType Leaf)) { throw "Missing command: $name" } }
foreach ($group in @(@('suite',$suiteRoot,$files), @('bin',$binRoot,$wrappers))) {
    foreach ($name in $group[2]) {
        $target = Join-Path $group[1] $name
        [void][IO.Directory]::CreateDirectory((Split-Path $target))
        # Unchanged assets may be held open by the running desktop companion.
        $source = Join-Path $PSScriptRoot ($group[0]+'/'+$name)
        if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $target).Hash) { continue }
        if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination ($target+'.bak-install-'+[guid]::NewGuid().ToString('N')) }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ($group[0]+'/'+$name)) -Destination $target -Force
    }
}
[void][IO.Directory]::CreateDirectory((Join-Path $suiteRoot 'accounts'))
. (Join-Path $suiteRoot 'Deck.Environments.ps1')
if (-not (Test-Path -LiteralPath (Join-Path $suiteRoot 'accounts/pool'))) { Set-DeckPoolEntry $suiteRoot 'pool' @('*') Ordered | Write-Host }
. (Join-Path $suiteRoot 'Deck.Commands.ps1')
Remove-DeckLegacyCommandSkills $suiteRoot | Out-Null
Remove-DeckLegacyCommandSkillsForAccounts $suiteRoot | Out-Null
. (Join-Path $suiteRoot 'Deck.Core.ps1')
$warmupSettings=Get-DeckSettings (Join-Path $suiteRoot 'deck')
Sync-DeckWarmupStartup $suiteRoot $warmupSettings
if (!$SkipPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($binRoot -notin @($userPath -split ';')) { [Environment]::SetEnvironmentVariable('Path',(@($binRoot,$userPath) -join ';'),'User') }
}
Write-Host 'Codex Deck installed. Open a new terminal and run codex-auth for the terminal dashboard or codex-deck. Codex CLI must be installed separately.'
