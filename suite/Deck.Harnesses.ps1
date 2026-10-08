# Account identity belongs to a harness. Request routing is a separate capability.
function Get-DeckHarnessCatalog {
    @(
        [pscustomobject]@{Id='Codex';Name='Codex CLI';Command='codex';Providers=@('ChatGPT');Docs='https://developers.openai.com/codex/cli/';Settings='config.toml';Help='codex --help; codex login; codex login status; codex resume. Deck adds account pools, failover, usage checks and compaction.'}
        [pscustomobject]@{Id='Antigravity';Name='Antigravity';Command='agy';Providers=@('Gemini');Docs='https://antigravity.google/docs/cli/install';Settings='settings.json';Help='agy --help; /help; /config; /model; /usage; /resume; /logout. New accounts use an isolated profile and the native remote/SSH file-token path, without separate Windows users or binary patches. Login prints a URL; complete Google sign-in and paste the returned code in the terminal. Deck checks binary compatibility before launch. Configure runner remains an optional Windows-user fallback; existing runner accounts keep that mode.'}
        [pscustomobject]@{Id='Claude';Name='Claude Code';Command='claude';Providers=@('Claude');Docs='https://code.claude.com/docs/en/overview';Settings='settings.json';Help='claude --help; claude auth login; claude auth status; /help; /config; /model; /resume. Deck isolates settings, credentials and history with CLAUDE_CONFIG_DIR. Use a Claude subscription sign-in.'}
        [pscustomobject]@{Id='OpenCode';Name='OpenCode';Command='opencode';Providers=@('ChatGPT','Claude','Gemini','Custom');Docs='https://opencode.ai/docs/';Settings='opencode.json';Help='opencode --help; opencode auth login; opencode auth list; /connect; /models; opencode --continue. Select the provider shown on your Deck account in the native login picker. Deck isolates credentials, config, cache and history with XDG directories. OpenCode supports additional providers inside a session.'}
    )
}
function Get-DeckHarness([string]$Id) {
    $item=Get-DeckHarnessCatalog | Where-Object Id -eq $Id | Select-Object -First 1
    if(-not $item){throw "Unknown harness: $Id"}; return $item
}
function Get-DeckAccountIdentity([string]$SuiteRoot,[string]$Account) {
    Assert-DeckEntryName $Account
    if(Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$Account")){[void](Get-DeckEntryDirectory $SuiteRoot $Account)}
    $value=Read-DeckEnvironmentJson (Join-Path $SuiteRoot "accounts/$Account/deck-account.json")
    if(-not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$Account/deck-account.json"))){return [pscustomobject]@{Version=1;Harness='Codex';Provider='ChatGPT'}}
    if($value -isnot [System.Management.Automation.PSCustomObject]){throw "Invalid account metadata for $Account."}
    $harness=Get-DeckHarness $value.Harness
    if($value.Version -ne 1 -or $value.Provider -notin $harness.Providers){throw "Invalid harness/provider metadata for $Account."}
    return $value
}
function Test-DeckCodexAccount([string]$SuiteRoot,[string]$Account) {
    return (Get-DeckAccountIdentity $SuiteRoot $Account).Harness -eq 'Codex'
}
function Test-DeckHarnessEnabled($Settings,[string]$Harness) {
    [void](Get-DeckHarness $Harness)
    return $Harness -eq 'Codex' -or [bool]$Settings[('Harness'+$Harness+'Enabled')]
}
function Resolve-DeckHarnessExecutable($Settings,[string]$Harness) {
    $definition=Get-DeckHarness $Harness
    $override=[string]$Settings[('Harness'+$Harness+'Path')]
    if($override){
        if(-not [IO.Path]::IsPathRooted($override) -or -not (Test-Path -LiteralPath $override -PathType Leaf)){throw "Choose an existing absolute executable path for $($definition.Name)."}
        if($Harness -eq 'Antigravity' -and [IO.Path]::GetExtension($override) -ne '.exe'){throw 'Antigravity runners require the native agy.exe binary.'}
        return $override
    }
    $sharedAgy=Join-Path ([Environment]::GetFolderPath('CommonDocuments') | Split-Path -Parent) 'CodexDeck/harnesses/agy.exe'
    if($Harness -eq 'Antigravity' -and (Test-Path -LiteralPath $sharedAgy -PathType Leaf)){return $sharedAgy}
    $command=Get-Command $definition.Command -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    # Alternate Windows users must launch the native AGY binary, not a personal wrapper.
    if($command -and ($Harness -ne 'Antigravity' -or [IO.Path]::GetExtension($command.Source) -eq '.exe')){return $command.Source}
    $candidates=switch($Harness){
        'Claude' {@((Join-Path $HOME '.local/bin/claude.exe'))}
        'Antigravity' {@((Join-Path ([Environment]::GetFolderPath('CommonDocuments') | Split-Path -Parent) 'GeminiLoop/bin/agy.exe'),(Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe'))}
        default {@()}
    }
    foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}}
    throw "$($definition.Name) is not installed. Use Settings > Harnesses > Install / update, or set its executable path."
}
function Assert-DeckHarnessPath([string]$Directory,[string]$Path) {
    $boundary=[IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $current=[IO.Path]::GetFullPath($Path)
    if(-not $current.StartsWith($boundary+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Harness files must stay inside their account.'}
    while($current -ne $boundary){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -Force -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked native settings and credential directories are not supported.'}
        $current=Split-Path -Parent $current
    }
}
function Test-DeckAntigravityFileAccount($Identity) {
    return $Identity.Harness -eq 'Antigravity' -and -not $Identity.RunnerSid
}
function Assert-DeckAntigravityFileSupport([string]$Executable) {
    if(-not ('DeckAntigravityIsolation' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Deck.Antigravity.Isolation.cs')}
    if(-not [DeckAntigravityIsolation]::SupportsFileIsolation($Executable)){
        throw 'This AGY binary does not pass the isolated file-login compatibility check. Update AGY, choose a compatible native binary, or configure the Windows runner fallback. No login was launched.'
    }
}
function Get-DeckHarnessConfigPath([string]$SuiteRoot,[string]$Account) {
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    $directory=Get-DeckEntryDirectory $SuiteRoot $Account
    $path=switch($identity.Harness){
        'Codex' {Join-Path $directory 'config.toml'}
        'Claude' {Join-Path $directory 'claude/settings.json'}
        'OpenCode' {Join-Path $directory 'opencode/config/opencode/opencode.json'}
        'Antigravity' {
            if(Test-DeckAntigravityFileAccount $identity){Join-Path $directory 'antigravity/profile/.gemini/antigravity-cli/settings.json';break}
            $credentialPath=Join-Path $directory 'runner-credential.clixml'
            if(-not (Test-Path -LiteralPath $credentialPath)){throw 'Configure this Antigravity account runner first: codex-auth <name> -ConfigureRunner.'}
            Assert-DeckHarnessPath $directory $credentialPath
            $credential=Import-Clixml -LiteralPath $credentialPath
            $sid=([Security.Principal.NTAccount]::new($credential.UserName.Replace('.\',$env:COMPUTERNAME+'\'))).Translate([Security.Principal.SecurityIdentifier]).Value
            if(-not $identity.RunnerSid -or $identity.RunnerSid -ne $sid){throw 'Runner credentials do not match this account. Configure its runner again.'}
            $profile=Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows NT/CurrentVersion/ProfileList/$sid" -ErrorAction Stop
            Join-Path ([Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath)) '.gemini/antigravity-cli/settings.json'
        }
    }
    if($identity.Harness -ne 'Antigravity' -or (Test-DeckAntigravityFileAccount $identity)){Assert-DeckHarnessPath $directory $path}
    return $path
}
function New-DeckHarnessAccount([string]$SuiteRoot,[string]$Account,[string]$Harness,[string]$Provider) {
    Assert-DeckEntryName $Account
    if($Account -in @('help','list','status','dashboard','resume','share','unshare','sharing','plugin','skills')){throw 'That name is reserved for a command.'}
    $definition=Get-DeckHarness $Harness
    if(-not $Provider){$Provider=$definition.Providers[0]}
    if($Provider -notin $definition.Providers){throw "$($definition.Name) only accepts: $($definition.Providers -join ', ')."}
    $preferences=Get-DeckSettings (Join-Path $SuiteRoot 'deck')
    if(-not (Test-DeckHarnessEnabled $preferences $Harness)){throw "Enable $($definition.Name) in Settings > Harnesses first."}
    $rootPath=Join-Path $SuiteRoot 'accounts'
    [void][IO.Directory]::CreateDirectory($rootPath)
    if((Get-Item -LiteralPath $rootPath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked accounts roots are not supported.'}
    $directory=Join-Path $rootPath $Account
    if(Test-Path -LiteralPath $directory){throw 'That account already exists.'}
    # CreateDirectory accepts existing directories; use the native exclusive helper.
    if(-not ('DeckAccountDirectory' -as [type])){
        Add-Type 'using System; using System.Runtime.InteropServices; public static class DeckAccountDirectory { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateDirectory(string path, IntPtr security); }'
    }
    if(-not [DeckAccountDirectory]::CreateDirectory($directory,[IntPtr]::Zero)){throw 'Could not create a new account directory exclusively.'}
    try{Write-DeckEnvironmentJson (Join-Path $directory 'deck-account.json') @{Version=1;Harness=$Harness;Provider=$Provider}}
    catch{[IO.Directory]::Delete($directory,$false);throw}
    return $directory
}
function Set-DeckAntigravityRunner([string]$SuiteRoot,[string]$Account) {
    $directory=Get-DeckEntryDirectory $SuiteRoot $Account
    if((Get-DeckAccountIdentity $SuiteRoot $Account).Harness -ne 'Antigravity'){throw 'Runner configuration is only for Antigravity accounts.'}
    Assert-DeckEntryIdle $SuiteRoot $Account
    $credential=$null; $slot=$null
    $manager=Join-Path $HOME '.local/bin/agy-runner-manager.ps1'
    if(Test-Path -LiteralPath $manager){
        Write-Host 'Existing GeminiLoop runners: account1 through account5. Each slot must be assigned to only one Deck account.'
        $slot=Read-Host 'Runner slot (account1..account5), or Enter for an existing Windows user'
        if($slot){
            foreach($other in @(Get-DeckEntryNames $SuiteRoot | Where-Object {$_ -ne $Account})){
                $otherIdentity=Get-DeckAccountIdentity $SuiteRoot $other
                if($otherIdentity.RunnerSlot -eq $slot){throw "Runner slot already belongs to $other."}
            }
            # Keep the third-party manager's variables and strict-mode setting local.
            $credential=& {param($managerPath,$slotName) . $managerPath; Get-AgyRunnerCredential -AccountName $slotName} $manager $slot
        }
    }
    if(-not $credential){$credential=Get-Credential -Message 'Existing Windows runner user (each Gemini account needs a separate Windows identity)'}
    if(-not $credential){throw 'Runner configuration cancelled.'}
    $runnerIdentity=[Security.Principal.NTAccount]::new($credential.UserName.Replace('.\',$env:COMPUTERNAME+'\'))
    $runnerSid=$runnerIdentity.Translate([Security.Principal.SecurityIdentifier]).Value
    if($runnerSid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Use a separate Windows identity to isolate this Gemini login.'}
    foreach($other in @(Get-DeckEntryNames $SuiteRoot | Where-Object {$_ -ne $Account})){
        if((Get-DeckAccountIdentity $SuiteRoot $other).RunnerSid -eq $runnerSid){throw "Windows runner already belongs to $other."}
    }
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    $metadata=@{Version=1;Harness=$identity.Harness;Provider=$identity.Provider;RunnerSid=$runnerSid;RunnerSlot=$slot;WindowsUser=$credential.UserName}
    # Export-Clixml protects the password with Windows DPAPI for this user/machine.
    $credentialPath=Join-Path $directory 'runner-credential.clixml'
    Assert-DeckHarnessPath $directory $credentialPath
    $credential | Export-Clixml -LiteralPath $credentialPath
    Write-DeckEnvironmentJson (Join-Path $directory 'deck-account.json') $metadata
}
function Get-DeckHarnessLaunch([string]$SuiteRoot,[string]$Account,[string[]]$Arguments) {
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    $preferences=Get-DeckSettings (Join-Path $SuiteRoot 'deck')
    if(-not (Test-DeckHarnessEnabled $preferences $identity.Harness)){throw "Enable $($identity.Harness) in Settings > Harnesses first."}
    $definition=Get-DeckHarness $identity.Harness
    $directory=Get-DeckEntryDirectory $SuiteRoot $Account
    $environment=@{}; $remove=@(); $argsList=@($Arguments)
    if($identity.Harness -eq 'Claude'){
        $environment.CLAUDE_CONFIG_DIR=Join-Path $directory 'claude'
        $remove=@('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY')
        if($argsList -and $argsList[0] -eq 'login'){$argsList=@('auth','login')+@($argsList | Select-Object -Skip 1)}
        if($argsList -and $argsList[0] -eq 'logout'){$argsList=@('auth','logout')+@($argsList | Select-Object -Skip 1)}
    }elseif(Test-DeckAntigravityFileAccount $identity){
        $profile=Join-Path $directory 'antigravity/profile'
        $environment.USERPROFILE=$profile; $environment.HOME=$profile
        $environment.APPDATA=Join-Path $profile 'AppData/Roaming'; $environment.LOCALAPPDATA=Join-Path $profile 'AppData/Local'
        $environment.SSH_CONNECTION='127.0.0.1 1234 127.0.0.1 22'
        $environment.AGY_ADC_AUTH='false'
        $remove=@('GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_GEMINI_BASE_URL','GOOGLE_APPLICATION_CREDENTIALS','AGY_GATEWAY_URL','AGY_GATEWAY_API_KEY','AGY_GATEWAY_HEADERS','AGY_PROXY_URL')
        if($argsList -and $argsList[0] -eq 'login'){$argsList=@($argsList | Select-Object -Skip 1)}
        if($argsList -and $argsList[0] -eq 'logout'){throw 'Use /logout inside the Antigravity terminal for this account.'}
    }elseif($identity.Harness -eq 'OpenCode'){
        $environment.XDG_CONFIG_HOME=Join-Path $directory 'opencode/config'
        $environment.XDG_DATA_HOME=Join-Path $directory 'opencode/data'
        $environment.XDG_STATE_HOME=Join-Path $directory 'opencode/state'
        $environment.XDG_CACHE_HOME=Join-Path $directory 'opencode/cache'
        $environment.OPENCODE_CONFIG_DIR=Join-Path $directory 'opencode/config/opencode'
        $remove=@('OPENCODE_CONFIG','OPENCODE_CONFIG_CONTENT','OPENCODE_TEST_HOME')
        if($argsList -and $argsList[0] -in @('login','logout')){$argsList=@('auth',$argsList[0])+@($argsList | Select-Object -Skip 1)}
        if($argsList.Count -eq 2 -and $argsList[0] -eq 'auth' -and $argsList[1] -eq 'login' -and $identity.Provider -ne 'Custom'){
            $providerId=switch($identity.Provider){'ChatGPT'{'openai'} 'Claude'{'anthropic'} 'Gemini'{'google'}}
            $argsList+=@('--provider',$providerId)
        }
    }
    foreach($key in $environment.Keys){if($key -notin @('SSH_CONNECTION','AGY_ADC_AUTH')){Assert-DeckHarnessPath $directory $environment[$key]}}
    return @{Identity=$identity;Executable=(Resolve-DeckHarnessExecutable $preferences $identity.Harness);Environment=$environment;Remove=$remove;Arguments=$argsList;Directory=$directory}
}
function ConvertTo-DeckHarnessArgument([AllowEmptyString()][string]$Value) {
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$quoted.Append(('\' * ($slashes * 2 + 1)))
            [void]$quoted.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$quoted.Append(('\' * $slashes)); $slashes = 0 }
        [void]$quoted.Append($character)
    }
    if ($slashes) { [void]$quoted.Append(('\' * ($slashes * 2))) }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-DeckHarnessProcess([string]$Executable,[string[]]$Arguments) {
    if([IO.Path]::GetExtension($Executable) -ne '.exe'){
        & $Executable @Arguments
        $global:LASTEXITCODE=$LASTEXITCODE
        return
    }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Executable; $info.UseShellExecute=$false
    $info.Arguments=(@($Arguments | ForEach-Object {ConvertTo-DeckHarnessArgument ([string]$_)}) -join ' ')
    $process=[Diagnostics.Process]::Start($info)
    try{$process.WaitForExit();$global:LASTEXITCODE=$process.ExitCode}finally{$process.Dispose()}
}
function Invoke-DeckHarnessAccount([string]$SuiteRoot,[string]$Account,[string[]]$Arguments,[switch]$ConfigureRunner) {
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    if($identity.Harness -eq 'Codex'){throw 'Use the Codex launch path for ChatGPT accounts.'}
    if($identity.Harness -eq 'Antigravity'){
        $credentialPath=Join-Path (Get-DeckEntryDirectory $SuiteRoot $Account) 'runner-credential.clixml'
        if($ConfigureRunner){Set-DeckAntigravityRunner $SuiteRoot $Account}
        if($ConfigureRunner){$global:LASTEXITCODE=0;return}
    }elseif($ConfigureRunner){throw 'Runner configuration is only for Antigravity.'}
    $launch=Get-DeckHarnessLaunch $SuiteRoot $Account $Arguments
    $session=Register-DeckSession (Join-Path $SuiteRoot 'deck') $Account (Get-Location).Path
    $previous=@{}
    try{
        if($identity.Harness -eq 'Antigravity' -and -not (Test-DeckAntigravityFileAccount $identity)){
            if(-not (Test-Path -LiteralPath $credentialPath)){throw 'Restore this account runner: codex-auth <name> -ConfigureRunner.'}
            Assert-DeckHarnessPath $launch.Directory $credentialPath
            $credential=Import-Clixml -LiteralPath $credentialPath
            $identity=Get-DeckAccountIdentity $SuiteRoot $Account
            $sid=([Security.Principal.NTAccount]::new($credential.UserName.Replace('.\',$env:COMPUTERNAME+'\'))).Translate([Security.Principal.SecurityIdentifier]).Value
            if(-not $identity.RunnerSid -or $identity.RunnerSid -ne $sid){throw 'Runner credentials do not match this account. Configure its runner again.'}
            $runnerPath=Join-Path $SuiteRoot 'Deck.AntigravityRunner.ps1'
            $runnerSource=[IO.File]::ReadAllText($runnerPath)
            $nativeHelpers=(Get-Command ConvertTo-DeckHarnessArgument).Definition
            $processHelper=(Get-Command Invoke-DeckHarnessProcess).Definition
            $runnerSource=$runnerSource.Replace('# DECK_NATIVE_HELPERS',('function ConvertTo-DeckHarnessArgument {'+$nativeHelpers+'}'+"`n"+'function Invoke-DeckHarnessProcess {'+$processHelper+'}'))
            # Embed the runner so another Windows user need not read Deck's private install.
            $runnerCode="& {`n"+$runnerSource+"`n} -Executable '"+$launch.Executable.Replace("'","''")+"' -Folder '"+(Get-Location).Path.Replace("'","''")+"' -Arguments @("
            $runnerArgs=@($launch.Arguments)
            if($runnerArgs -and $runnerArgs[0] -eq 'login'){$runnerArgs=@($runnerArgs | Select-Object -Skip 1)}
            $runnerCode+=(@($runnerArgs | ForEach-Object {"'"+$_.Replace("'","''")+"'"}) -join ',')+")"
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runnerCode))
            # A visible terminal is needed for native browser login and interactive use.
            $process=Start-Process powershell.exe -Credential $credential -LoadUserProfile -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WorkingDirectory ([Environment]::GetFolderPath('CommonDocuments')) -PassThru
            try{$process.WaitForExit(); $global:LASTEXITCODE=$process.ExitCode}finally{$process.Dispose()};return
        }
        if(Test-DeckAntigravityFileAccount $identity){Assert-DeckAntigravityFileSupport $launch.Executable}
        foreach($key in @($launch.Environment.Keys)+@($launch.Remove)){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$launch.Environment[$key],'Process')}
        if(Test-DeckAntigravityFileAccount $identity){
            foreach($key in @('USERPROFILE','APPDATA','LOCALAPPDATA')){[void][IO.Directory]::CreateDirectory($launch.Environment[$key])}
        }
        $configPath=Get-DeckHarnessConfigPath $SuiteRoot $Account
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $configPath))
        if(-not (Test-Path -LiteralPath $configPath)){Write-DeckEnvironmentJson $configPath ([pscustomobject]@{})}
        if($identity.Harness -eq 'Claude'){
            $config=Read-DeckEnvironmentJson $configPath
            if($config -isnot [System.Management.Automation.PSCustomObject]){throw 'Claude settings must contain a JSON object.'}
            $config | Add-Member NoteProperty forceLoginMethod 'claudeai' -Force
            Write-DeckEnvironmentJson $configPath $config
        }elseif(Test-DeckAntigravityFileAccount $identity){
            $config=Read-DeckEnvironmentJson $configPath
            if($config -isnot [System.Management.Automation.PSCustomObject]){throw 'Antigravity settings must contain a JSON object.'}
            # API-key provider config must not replace this account's Google login.
            $config.PSObject.Properties.Remove('modelProvider')
            Write-DeckEnvironmentJson $configPath $config
        }
        $nativeArguments=@($launch.Arguments)
        Invoke-DeckHarnessProcess $launch.Executable $nativeArguments
    }finally{
        foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
        if(Test-Path -LiteralPath $session){[IO.File]::Delete($session)}
    }
}
function Install-DeckHarness([string]$Harness) {
    $ErrorActionPreference='Stop'
    switch($Harness){
        'Codex' {& npm.cmd install -g '@openai/codex@latest'; if($LASTEXITCODE){throw 'Codex CLI installation failed.'}}
        'OpenCode' {& npm.cmd install -g 'opencode-ai@latest'; if($LASTEXITCODE){throw 'OpenCode installation failed.'}}
        {$_ -in @('Claude','Antigravity')} {
            $uri=if($Harness -eq 'Claude'){'https://claude.ai/install.ps1'}else{'https://antigravity.google/cli/install.ps1'}
            $temporary=Join-Path ([IO.Path]::GetTempPath()) ('deck-harness-'+[guid]::NewGuid().ToString('N')+'.ps1')
            try{
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $temporary
                $installerCode="`$ErrorActionPreference='Stop'; & '"+$temporary.Replace("'","''")+"'"
                $encodedInstaller=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($installerCode))
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedInstaller
                if($LASTEXITCODE){throw "$Harness installation failed (exit $LASTEXITCODE)."}
            }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
        }
        default {throw 'Unknown harness.'}
    }
    # Installers may update the user's PATH after this worker started.
    $env:PATH=[Environment]::GetEnvironmentVariable('Path','User')+';'+[Environment]::GetEnvironmentVariable('Path','Machine')+';'+$env:PATH
    if($Harness -eq 'Antigravity'){
        # Keep a binary readable by separate runner users. Do not overwrite GeminiLoop's install.
        $installed=Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe'
        if(-not (Test-Path -LiteralPath $installed -PathType Leaf)){
            $installed=(Get-Command agy.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        }
        $shared=Join-Path ([Environment]::GetFolderPath('CommonDocuments') | Split-Path -Parent) 'CodexDeck/harnesses/agy.exe'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $shared))
        Copy-Item -LiteralPath $installed -Destination $shared -Force
    }
    $executable=Resolve-DeckHarnessExecutable (Get-DeckDefaults) $Harness
    Write-Output "Installed / updated $Harness at $executable"
}
