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
function Resolve-DeckHarnessScopedAccountName([string]$SuiteRoot,[string]$Account,[string]$Harness) {
    Assert-DeckEntryName $Account
    [void](Get-DeckHarness $Harness)
    if($Harness -eq 'Codex'){return $Account}
    $prefix=$Harness.ToLowerInvariant()+'-'
    if($Account.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $Account}
    $plainPath=Join-Path $SuiteRoot "accounts/$Account"
    if(Test-Path -LiteralPath $plainPath -PathType Container){
        if((Get-DeckAccountIdentity $SuiteRoot $Account).Harness -eq $Harness){return $Account}
    }
    $scoped=$prefix+$Account
    Assert-DeckEntryName $scoped
    return $scoped
}
function Test-DeckHarnessEnabled($Settings,[string]$Harness) {
    [void](Get-DeckHarness $Harness)
    return $Harness -eq 'Codex' -or [bool]$Settings[('Harness'+$Harness+'Enabled')]
}
function Get-DeckHarnessFullPermissionArguments($Settings,[string]$Harness) {
    [void](Get-DeckHarness $Harness)
    if(-not [bool]$Settings[('Harness'+$Harness+'FullPermissions')]){return @()}
    switch($Harness){
        'Codex' {@('--dangerously-bypass-approvals-and-sandbox')}
        'Claude' {@('--dangerously-skip-permissions')}
        'Antigravity' {@('--dangerously-skip-permissions')}
        'OpenCode' {@('--auto')}
    }
}
function Test-DeckHarnessInteractiveSession([string]$Harness,[string[]]$Arguments) {
    if(-not $Arguments.Count){return $true}
    $first=[string]$Arguments[0]
    switch($Harness){
        'Codex' {return $first -notin @('login','logout','mcp','mcp-server','completion','features','debug','app-server','cloud','apply','sandbox','doctor','update','--help','-h','--version','-V')}
        'Claude' {return $first -notin @('login','logout') -and (Test-DeckClaudeSessionLaunch $Arguments)}
        'Antigravity' {return $first -notin @('login','logout','auth','update','install','uninstall','--help','-h','--version','-V')}
        'OpenCode' {return $first -notin @('login','logout','auth','agent','agents','mcp','models','upgrade','uninstall','serve','web','attach','github','export','import','--help','-h','--version','-v')}
    }
    return $false
}
function Get-DeckHarnessSessionArguments($Settings,[string]$Harness,[string[]]$Arguments) {
    $result=@($Arguments)
    if(-not (Test-DeckHarnessInteractiveSession $Harness $result)){return $result}
    $permissionArgs=@(Get-DeckHarnessFullPermissionArguments $Settings $Harness)
    if(-not $permissionArgs.Count){return $result}
    # A native per-invocation mode is an intentional override of the Deck default.
    $modeFlags=switch($Harness){
        'Codex' {@('--dangerously-bypass-approvals-and-sandbox','--yolo','--sandbox','-s','--ask-for-approval','-a')}
        'Claude' {@('--dangerously-skip-permissions','--permission-mode')}
        'Antigravity' {@('--dangerously-skip-permissions')}
        'OpenCode' {@('--auto')}
    }
    foreach($argument in $result){
        if($argument -in $modeFlags -or @($modeFlags | Where-Object {$argument.StartsWith($_+'=',[StringComparison]::Ordinal)}).Count){return $result}
    }
    return @($permissionArgs)+$result
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
function Test-DeckAntigravityHeadlessPrompt([string[]]$Arguments) {
    $argsList=@($Arguments | ForEach-Object {[string]$_})
    $hasPrompt=$false
    for($index=0;$index -lt $argsList.Count;$index++){
        if($argsList[$index] -in @('-p','--print','--prompt')){
            if($index+1 -lt $argsList.Count -and -not [string]::IsNullOrWhiteSpace($argsList[$index+1])){$hasPrompt=$true}
            break
        }
    }
    if(-not $hasPrompt -or $argsList -contains '--continue' -or $argsList -contains '-c' -or $argsList -contains '--conversation' -or $argsList -contains '--input-format' -or $argsList -contains '--prompt-interactive'){return $false}
    return $true
}
function Resolve-DeckAntigravityFailoverPool([string]$SuiteRoot,[string]$Pool,[string]$StartAccount='',[switch]$AllowUnsigned,[switch]$RequireStartCredential) {
    $tokens=@($Pool -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})
    if(-not $Pool -or $tokens.Count -gt 200 -or @($tokens | Sort-Object -Unique).Count -ne $tokens.Count -or (@($tokens | Where-Object {$_ -eq '*'}).Count -gt 0 -and $tokens.Count -ne 1)){throw 'Choose * or 1-200 distinct Antigravity accounts.'}
    $dynamic=$tokens.Count -eq 1 -and $tokens[0] -eq '*'
    if($dynamic){
        if(-not (Get-Command Get-DeckEntryNames -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'Deck.Environments.ps1')}
        $names=@(Get-DeckEntryNames $SuiteRoot | Where-Object {
            try{$identity=Get-DeckAccountIdentity $SuiteRoot $_; $identity.Harness -eq 'Antigravity' -and (Test-DeckAntigravityFileAccount $identity)}catch{$false}
        })
    }else{
        $names=@($tokens | ForEach-Object {
            $candidate=[string]$_
            if($candidate -match '^\d+$'){$candidate='account'+$candidate}
            Assert-DeckEntryName $candidate
            if(-not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$candidate") -PathType Container)){$candidate=Resolve-DeckHarnessScopedAccountName $SuiteRoot $candidate 'Antigravity'}
            elseif((Get-DeckAccountIdentity $SuiteRoot $candidate).Harness -ne 'Antigravity'){
                $scoped=Resolve-DeckHarnessScopedAccountName $SuiteRoot $candidate 'Antigravity'
                if($scoped -eq $candidate -or -not (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$scoped") -PathType Container)){throw 'Antigravity failover only accepts AGY accounts.'}
                $candidate=$scoped
            }
            $identity=Get-DeckAccountIdentity $SuiteRoot $candidate
            if($identity.Harness -ne 'Antigravity' -or -not (Test-DeckAntigravityFileAccount $identity)){throw 'Antigravity failover only accepts isolated Antigravity file-profile accounts.'}
            $candidate
        })
    }
    $eligible=[Collections.Generic.List[string]]::new()
    foreach($name in $names){
        $identity=Get-DeckAccountIdentity $SuiteRoot $name
        if($identity.Harness -ne 'Antigravity' -or -not (Test-DeckAntigravityFileAccount $identity)){continue}
        $directory=Get-DeckEntryDirectory $SuiteRoot $name
        $tokenPath=Join-Path $directory 'antigravity/profile/.gemini/antigravity-cli/antigravity-oauth-token'
        Assert-DeckHarnessPath $directory $tokenPath
        $hasCredential=$false
        if(Test-Path -LiteralPath $tokenPath -PathType Leaf){$tokenItem=Get-Item -LiteralPath $tokenPath -Force;if(-not ($tokenItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){$hasCredential=$tokenItem.Length -gt 0}}
        if($hasCredential -or $AllowUnsigned){$eligible.Add($name)}
        elseif(-not $dynamic){throw "Antigravity failover account $name has no saved isolated credential."}
    }
    if(-not $dynamic -and -not $eligible.Count){throw 'Antigravity failover needs at least one isolated account with saved credentials.'}
    if($StartAccount){
        $startIdentity=Get-DeckAccountIdentity $SuiteRoot $StartAccount
        if($startIdentity.Harness -ne 'Antigravity' -or -not (Test-DeckAntigravityFileAccount $startIdentity)){throw 'AGY failover cannot use an account from another harness or a Windows runner profile.'}
        $eligibleNames=@($eligible)
        $startDirectory=Get-DeckEntryDirectory $SuiteRoot $StartAccount
        $startToken=Join-Path $startDirectory 'antigravity/profile/.gemini/antigravity-cli/antigravity-oauth-token'
        Assert-DeckHarnessPath $startDirectory $startToken
        $startHasCredential=$false
        if(Test-Path -LiteralPath $startToken -PathType Leaf){$startItem=Get-Item -LiteralPath $startToken -Force;$startHasCredential=-not ($startItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $startItem.Length -gt 0}
        if(-not $startHasCredential -and $RequireStartCredential){throw 'The starting Antigravity account needs a saved isolated credential before failover can run.'}
        if(-not $startHasCredential){return @()}
        $eligible=[Collections.Generic.List[string]]::new();$eligible.Add($StartAccount);foreach($name in $eligibleNames){if($name -ne $StartAccount){$eligible.Add($name)}}
    }
    return @($eligible | Select-Object -Unique)
}
function Get-DeckAntigravityMachineArguments([string[]]$Arguments) {
    $format='text';$clean=[Collections.Generic.List[string]]::new()
    for($index=0;$index -lt $Arguments.Count;$index++){
        $argument=[string]$Arguments[$index]
        if($argument -eq '--output-format'){
            if($index+1 -ge $Arguments.Count){throw 'Missing value for --output-format.'}
            $format=[string]$Arguments[++$index]
        }elseif($argument.StartsWith('--output-format=',[StringComparison]::Ordinal)){$format=$argument.Substring('--output-format='.Length)}
        else{$clean.Add($argument)}
    }
    if($format -notin @('text','json','stream-json')){throw 'AGY output format must be text, json, or stream-json.'}
    $clean.Add('--output-format');$clean.Add('stream-json')
    return @{Arguments=$clean.ToArray();RequestedFormat=$format}
}
function Read-DeckAntigravityStream([string]$StandardOutput) {
    $events=[Collections.Generic.List[object]]::new();$result=$null;$toolExecuted=$false
    foreach($line in ($StandardOutput -split "`r?`n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})){
        try{$event=$line | ConvertFrom-Json -ErrorAction Stop}catch{continue}
        $events.Add($event)
        if($event.event -eq 'result' -and $event.result){$result=$event.result}
        if($event.event -eq 'step_update' -and $event.step_update){
            if($event.step_update.step_type -eq 'tool' -or $event.step_update.PSObject.Properties['subagent_info']){$toolExecuted=$true}
        }
    }
    return @{Events=$events.ToArray();Result=$result;ToolExecuted=$toolExecuted}
}
function Test-DeckAntigravityProviderFailure([int]$ExitCode,[string]$StandardError,[bool]$ToolExecuted) {
    if($ExitCode -eq 0 -or $ToolExecuted){return $false}
    $match=[regex]::Match($StandardError,'(?m)^AGY_ERROR:\s*(\{[^\r\n]*\})\s*$')
    if(-not $match.Success){return $false}
    try{$errorRecord=$match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop}catch{return $false}
    $status=[string]$(if($errorRecord.canonical_status){$errorRecord.canonical_status}else{$errorRecord.status})
    $status=$status.ToUpperInvariant()
    $code=0;try{$code=[int]$errorRecord.error_code}catch{}
    if($status -eq 'RESOURCE_EXHAUSTED' -and ($code -eq 0 -or $code -in @(8,429))){return $true}
    $retryable=$errorRecord.PSObject.Properties['retryable'] -and [bool]$errorRecord.retryable
    if(-not $retryable){return $false}
    return $status -in @('UNAVAILABLE','INTERNAL','DEADLINE_EXCEEDED','ABORTED','UNKNOWN') -and ($code -eq 0 -or $code -in @(4,8,10,13,14,408,429,500,502,503,504))
}
function Write-DeckAntigravityCapturedResult($Captured,$Parsed,[string]$RequestedFormat) {
    $result=$Parsed.Result
    if($RequestedFormat -eq 'stream-json' -or -not $result){if($Captured.StandardOutput){[Console]::Out.Write($Captured.StandardOutput)}}
    elseif($RequestedFormat -eq 'json'){[Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 100 -Compress))}
    elseif($result.response){[Console]::Out.Write([string]$result.response)}
    if($Captured.StandardError){[Console]::Error.Write($Captured.StandardError)}
    $effectiveExit=[int]$Captured.ExitCode
    if($effectiveExit -eq 0 -and $result -and $result.status -ne 'SUCCESS'){$effectiveExit=1}
    $global:LASTEXITCODE=$effectiveExit
}
function Assert-DeckAntigravityFileSupport([string]$Executable) {
    if(-not ('DeckAntigravityIsolation' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Deck.Antigravity.Isolation.cs')}
    $file=Get-Item -LiteralPath $Executable -ErrorAction Stop
    $cacheKey=([IO.Path]::GetFullPath($Executable).ToLowerInvariant()+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks)
    if($script:DeckAntigravitySupportCache -and $script:DeckAntigravitySupportCache.ContainsKey($cacheKey)){return}
    if(-not [DeckAntigravityIsolation]::SupportsFileIsolation($Executable)){
        throw 'This AGY binary does not pass the isolated file-login compatibility check. Update AGY, choose a compatible native binary, or configure the Windows runner fallback. No login was launched.'
    }
    if(-not $script:DeckAntigravitySupportCache){$script:DeckAntigravitySupportCache=@{}}
    $script:DeckAntigravitySupportCache[$cacheKey]=$true
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
    $sessionArguments=@(Get-DeckHarnessSessionArguments $preferences $identity.Harness $Arguments)
    $directory=Get-DeckEntryDirectory $SuiteRoot $Account
    $environment=@{}; $remove=@(); $argsList=@($sessionArguments);$claudeContextPolicy=$null
    if($identity.Harness -eq 'Claude'){
        $claudeProfile=Join-Path $directory 'claude'
        $environment.CLAUDE_CONFIG_DIR=$claudeProfile
        $environment.USERPROFILE=$claudeProfile
        $environment.HOME=$claudeProfile
        $environment.APPDATA=Join-Path $claudeProfile 'AppData/Roaming'
        $environment.LOCALAPPDATA=Join-Path $claudeProfile 'AppData/Local'
        $remove=@('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_PROFILE','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL','CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_PROFILE','AWS_BEARER_TOKEN_BEDROCK','ANTHROPIC_BEDROCK_BASE_URL','ANTHROPIC_VERTEX_PROJECT_ID','ANTHROPIC_VERTEX_REGION','GOOGLE_APPLICATION_CREDENTIALS','CLOUD_ML_REGION','CLOUD_ML_PROJECT_ID','CLAUDE_CODE_DISABLE_CLAUDE_MDS','CLAUDE_CODE_DISABLE_AUTO_MEMORY')
        if($argsList -and $argsList[0] -eq 'login'){$argsList=@('auth','login')+@($argsList | Select-Object -Skip 1)}
        if($argsList -and $argsList[0] -eq 'logout'){$argsList=@('auth','logout')+@($argsList | Select-Object -Skip 1)}
        if(Test-DeckClaudeSessionLaunch $argsList){
            $claudeContextPolicy=Get-DeckClaudeContextPolicy $SuiteRoot
            if(-not $claudeContextPolicy.AutoMemoryEnabled){$environment.CLAUDE_CODE_DISABLE_AUTO_MEMORY='1';$remove=@($remove | Where-Object {$_ -ne 'CLAUDE_CODE_DISABLE_AUTO_MEMORY'})}
            if(@($claudeContextPolicy.SettingSources).Count -lt 3){
                $cleanSources=[Collections.Generic.List[string]]::new()
                for($i=0;$i -lt $argsList.Count;$i++){
                    if($argsList[$i] -eq '--setting-sources'){if($i+1 -lt $argsList.Count){$i++};continue}
                    if(([string]$argsList[$i]).StartsWith('--setting-sources=',[StringComparison]::Ordinal)){continue}
                    $cleanSources.Add([string]$argsList[$i])
                }
                $argsList=$cleanSources.ToArray()+@('--setting-sources',(@($claudeContextPolicy.SettingSources) -join ','))
            }
            if(-not $claudeContextPolicy.SkillsAndCommandsEnabled -and $argsList -notcontains '--disable-slash-commands'){$argsList+=@('--disable-slash-commands')}
            if(-not $claudeContextPolicy.McpEnabled){
                $cleanMcp=[Collections.Generic.List[string]]::new()
                for($i=0;$i -lt $argsList.Count;$i++){
                    if($argsList[$i] -eq '--mcp-config'){if($i+1 -lt $argsList.Count){$i++};continue}
                    if(([string]$argsList[$i]).StartsWith('--mcp-config=',[StringComparison]::Ordinal) -or $argsList[$i] -eq '--strict-mcp-config'){continue}
                    $cleanMcp.Add([string]$argsList[$i])
                }
                $argsList=$cleanMcp.ToArray()+@('--strict-mcp-config')
            }
            if($claudeContextPolicy.SafeMode -and $argsList -notcontains '--safe-mode'){$argsList+=@('--safe-mode')}
        }
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
    $claudeDefaults=$null;$claudeSessionSettings=$null;$claudeSettingsWereExplicit=$false
    if($identity.Harness -eq 'Claude' -and (Test-DeckClaudeSessionLaunch $argsList)){
        $claudeDefaults=Get-DeckClaudeDefaultSettings $SuiteRoot
        if(@($claudeDefaults.PSObject.Properties).Count){
            $explicitSettings=Get-DeckClaudeSettingsArgument $argsList
            $claudeSessionSettings=$explicitSettings.Settings
            $claudeSettingsWereExplicit=$explicitSettings.Found
            if($explicitSettings.Found){$argsList=@($explicitSettings.Arguments)}
        }else{$claudeDefaults=$null}
    }else{$claudeDefaults=$null}
    foreach($key in $environment.Keys){if($key -notin @('SSH_CONNECTION','AGY_ADC_AUTH','CLAUDE_CODE_DISABLE_AUTO_MEMORY')){Assert-DeckHarnessPath $directory $environment[$key]}}
    $instructionsPath=$null
    if($identity.Harness -eq 'Claude' -and (Test-DeckClaudeSessionLaunch $argsList)){
        $candidate=Get-DeckClaudeGlobalInstructionsPath $SuiteRoot
        if((Test-Path -LiteralPath $candidate -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($candidate))){$instructionsPath=$candidate}
    }
    return @{Identity=$identity;Executable=(Resolve-DeckHarnessExecutable $preferences $identity.Harness);Environment=$environment;Remove=$remove;Arguments=$argsList;Directory=$directory;ClaudeDefaults=$claudeDefaults;ClaudeSessionSettings=$claudeSessionSettings;ClaudeSettingsWereExplicit=$claudeSettingsWereExplicit;ClaudeGlobalInstructionsPath=$instructionsPath;ClaudeContextPolicy=$claudeContextPolicy}
}

function Get-DeckClaudeAuthStatus([string]$SuiteRoot,[string]$Account) {
    if((Get-DeckAccountIdentity $SuiteRoot $Account).Harness -ne 'Claude'){throw 'Authentication status checks require a Claude account.'}
    $launch=Get-DeckHarnessLaunch $SuiteRoot $Account @('auth','status')
    foreach($key in @('USERPROFILE','APPDATA','LOCALAPPDATA')){if($launch.Environment[$key]){[void][IO.Directory]::CreateDirectory($launch.Environment[$key])}}
    $previous=@{}
    try{
        foreach($key in @($launch.Environment.Keys)+@($launch.Remove)){
            $previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process')
            [Environment]::SetEnvironmentVariable($key,$launch.Environment[$key],'Process')
        }
        $statusArguments=@($launch.Arguments)
        $output=@(& $launch.Executable @statusArguments 2>&1)
        $exitCode=$LASTEXITCODE
    }finally{
        foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
    }
    $raw=($output | ForEach-Object {[string]$_}) -join "`n"
    try{$status=$raw | ConvertFrom-Json -ErrorAction Stop}catch{throw 'Claude auth status did not return valid JSON.'}
    if($exitCode -notin @(0,1)){throw "Claude auth status failed (exit $exitCode)."}
    if($status.PSObject.Properties['configDirectory'] -and $status.configDirectory){
        $expected=[IO.Path]::GetFullPath([string]$launch.Environment.CLAUDE_CONFIG_DIR).TrimEnd('\')
        $reported=[IO.Path]::GetFullPath([string]$status.configDirectory).TrimEnd('\')
        if(-not [string]::Equals($expected,$reported,[StringComparison]::OrdinalIgnoreCase)){throw 'Claude reported a different config directory. Check stopped to protect account isolation.'}
    }
    if(-not $status.PSObject.Properties['loggedIn']){throw 'Claude auth status did not include a login state.'}
    $record=[pscustomobject]@{LoggedIn=[bool]$status.loggedIn;AuthMethod=if($status.authMethod){[string]$status.authMethod}else{$null};CheckedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    $cachePath=Join-Path $SuiteRoot 'deck/claude-auth-checks.json'
    $cache=Read-DeckEnvironmentJson $cachePath
    if(-not (Test-DeckClaudeJsonObject $cache)){$cache=[pscustomobject]@{}}
    $cache | Add-Member -MemberType NoteProperty -Name $Account -Value $record -Force
    Write-DeckEnvironmentJson $cachePath $cache
    return $record
}

function Clear-DeckClaudeAuthStatus([string]$SuiteRoot,[string]$Account) {
    $cachePath=Join-Path $SuiteRoot 'deck/claude-auth-checks.json'
    $cache=Read-DeckEnvironmentJson $cachePath
    if(-not (Test-DeckClaudeJsonObject $cache) -or -not $cache.PSObject.Properties[$Account]){return}
    $cache.PSObject.Properties.Remove($Account)
    if(@($cache.PSObject.Properties).Count){Write-DeckEnvironmentJson $cachePath $cache}else{Remove-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue}
}

function Get-DeckAntigravityAuthStatus([string]$SuiteRoot,[string]$Account) {
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    if($identity.Harness -ne 'Antigravity'){throw 'Antigravity auth checks require an Antigravity account.'}
    $checkedAt=[DateTimeOffset]::UtcNow.ToString('o')
    if(-not (Test-DeckAntigravityFileAccount $identity)){
        $record=[pscustomobject]@{CredentialsPresent=$null;Mode='Windows runner';Status='Runner profile';CheckedAt=$checkedAt}
        $cachePath=Join-Path $SuiteRoot 'deck/antigravity-auth-checks.json'
        $cache=Read-DeckEnvironmentJson $cachePath
        if(-not (Test-DeckAntigravityJsonObject $cache)){$cache=[pscustomobject]@{}}
        $cache | Add-Member NoteProperty $Account $record -Force
        Write-DeckEnvironmentJson $cachePath $cache
        return $record
    }
    $directory=Get-DeckEntryDirectory $SuiteRoot $Account
    $tokenPath=Join-Path $directory 'antigravity/profile/.gemini/antigravity-cli/antigravity-oauth-token'
    Assert-DeckHarnessPath $directory $tokenPath
    $present=$false
    if(Test-Path -LiteralPath $tokenPath){
        $item=Get-Item -LiteralPath $tokenPath -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Antigravity credentials must be a regular file inside this isolated account.'}
        $present=$item.Length -gt 0
    }
    $record=[pscustomobject]@{CredentialsPresent=$present;Mode='Isolated file profile';Status=if($present){'Credentials stored'}else{'Sign-in required'};CheckedAt=$checkedAt}
    $cachePath=Join-Path $SuiteRoot 'deck/antigravity-auth-checks.json'
    $cache=Read-DeckEnvironmentJson $cachePath
    if(-not (Test-DeckAntigravityJsonObject $cache)){$cache=[pscustomobject]@{}}
    $cache | Add-Member NoteProperty $Account $record -Force
    Write-DeckEnvironmentJson $cachePath $cache
    return $record
}

function Clear-DeckAntigravityAuthStatus([string]$SuiteRoot,[string]$Account) {
    $cachePath=Join-Path $SuiteRoot 'deck/antigravity-auth-checks.json'
    $cache=Read-DeckEnvironmentJson $cachePath
    if(-not (Test-DeckAntigravityJsonObject $cache) -or -not $cache.PSObject.Properties[$Account]){return}
    $cache.PSObject.Properties.Remove($Account)
    if(@($cache.PSObject.Properties).Count){Write-DeckEnvironmentJson $cachePath $cache}else{Remove-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue}
}

function New-DeckClaudeSessionArguments([string]$SuiteRoot,[string]$Account,$Launch) {
    $arguments=[Collections.Generic.List[string]]::new();foreach($argument in $Launch.Arguments){$arguments.Add([string]$argument)}
    $temporaryFiles=[Collections.Generic.List[string]]::new()
    try{
        if($Launch.ClaudeDefaults){
            $settingsPath=Get-DeckHarnessConfigPath $SuiteRoot $Account
            $accountSettings=Read-DeckClaudeSettingsFile $settingsPath 'Claude account settings'
            $settings=Merge-DeckClaudeSettings $Launch.ClaudeDefaults $accountSettings $Launch.ClaudeSessionSettings
            if($Launch.ClaudeContextPolicy){$settings=Merge-DeckClaudeSettingsValue $settings (Get-DeckClaudeContextSettings $Launch.ClaudeContextPolicy)}
            $settingsFile=Join-Path $Launch.Environment.CLAUDE_CONFIG_DIR ('.codexdeck-settings-'+[guid]::NewGuid().ToString('N')+'.json')
            Assert-DeckHarnessPath $Launch.Directory $settingsFile
            $temporaryFiles.Add($settingsFile)
            [IO.File]::WriteAllText($settingsFile,(ConvertTo-Json -InputObject $settings -Compress -Depth 100),[Text.UTF8Encoding]::new($false))
            $arguments.Insert(0,$settingsFile);$arguments.Insert(0,'--settings')
        }
        $hasGlobalInstructions=$Launch.ClaudeGlobalInstructionsPath -and (Test-Path -LiteralPath $Launch.ClaudeGlobalInstructionsPath -PathType Leaf)
        $promptFlags=@('--append-system-prompt','--append-system-prompt-file')
        $promptSections=[Collections.Generic.List[string]]::new()
        if($hasGlobalInstructions){
            $globalItem=Get-Item -LiteralPath $Launch.ClaudeGlobalInstructionsPath -Force
            if($globalItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Claude global instructions must be a regular file.'}
            $globalInstructions=[IO.File]::ReadAllText($Launch.ClaudeGlobalInstructionsPath)
            if(-not [string]::IsNullOrWhiteSpace($globalInstructions)){$promptSections.Add($globalInstructions.Trim())}
        }
        $clean=[Collections.Generic.List[string]]::new()
        for($i=0;$i -lt $arguments.Count;$i++){
            $argument=$arguments[$i]
            if($argument -in $promptFlags){
                if($i+1 -ge $arguments.Count){throw "Missing value for $argument."}
                $i++;$value=$arguments[$i]
                if($argument -eq '--append-system-prompt-file'){
                    if(-not (Test-Path -LiteralPath $value -PathType Leaf)){throw "Claude system prompt file not found: $value"}
                    $item=Get-Item -LiteralPath $value -Force
                    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Claude system prompt files must be regular files.'}
                    $promptSections.Add([IO.File]::ReadAllText($value).Trim())
                }else{$promptSections.Add([string]$value)}
            }elseif($argument.StartsWith('--append-system-prompt=',[StringComparison]::Ordinal)){$promptSections.Add($argument.Substring('--append-system-prompt='.Length))}
            elseif($argument.StartsWith('--append-system-prompt-file=',[StringComparison]::Ordinal)){
                $path=$argument.Substring('--append-system-prompt-file='.Length)
                if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Claude system prompt file not found: $path"}
                $item=Get-Item -LiteralPath $path -Force
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Claude system prompt files must be regular files.'}
                $promptSections.Add([IO.File]::ReadAllText($path).Trim())
            }else{$clean.Add($argument)}
        }
        if(@($promptSections | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}).Count){
            $promptFile=Join-Path $Launch.Environment.CLAUDE_CONFIG_DIR ('.codexdeck-prompt-'+[guid]::NewGuid().ToString('N')+'.md')
            Assert-DeckHarnessPath $Launch.Directory $promptFile
            $temporaryFiles.Add($promptFile)
            [IO.File]::WriteAllText($promptFile,($promptSections -join "`n`n"),[Text.UTF8Encoding]::new($false))
            $clean.Add('--append-system-prompt-file');$clean.Add($promptFile)
        }
        return @{Arguments=$clean.ToArray();TemporaryFiles=$temporaryFiles.ToArray()}
    }catch{
        foreach($temporaryFile in $temporaryFiles){if(Test-Path -LiteralPath $temporaryFile -PathType Leaf){[IO.File]::Delete($temporaryFile)}}
        throw
    }
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

function Invoke-DeckHarnessProcess([string]$Executable,[string[]]$Arguments,[switch]$CaptureOutput) {
    if([IO.Path]::GetExtension($Executable) -ne '.exe'){
        if($CaptureOutput){throw 'Captured headless output requires the native executable.'}
        & $Executable @Arguments
        $global:LASTEXITCODE=$LASTEXITCODE
        return
    }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Executable; $info.UseShellExecute=$false
    $info.Arguments=(@($Arguments | ForEach-Object {ConvertTo-DeckHarnessArgument ([string]$_)}) -join ' ')
    if($CaptureOutput){$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)}
    $process=[Diagnostics.Process]::Start($info)
    try{
        if($CaptureOutput){
            $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
            $process.WaitForExit();$stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=$stderrTask.GetAwaiter().GetResult()
            $global:LASTEXITCODE=$process.ExitCode
            return @{ExitCode=$process.ExitCode;StandardOutput=$stdout;StandardError=$stderr}
        }
        $process.WaitForExit();$global:LASTEXITCODE=$process.ExitCode
    }finally{$process.Dispose()}
}
function Invoke-DeckHarnessInstallerScript([string]$Path,[string[]]$Arguments,[string]$Label) {
    $powershell=Join-Path $PSHOME 'powershell.exe'
    if(-not (Test-Path -LiteralPath $powershell -PathType Leaf)){$powershell='powershell.exe'}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$powershell
    $script="`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue'; & '"+$Path.Replace("'","''")+"'"
    foreach($argument in $Arguments){$script+=' '''+([string]$argument).Replace("'","''")+''''}
    $script+='; exit $LASTEXITCODE'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $info.Arguments=(@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) | ForEach-Object {ConvertTo-DeckHarnessArgument ([string]$_)}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    [void]$info.EnvironmentVariables.Remove('PSModulePath')
    $process=[Diagnostics.Process]::Start($info)
    try{
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout=$stdoutTask.GetAwaiter().GetResult()
        $stderr=$stderrTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){
            $detail=(($stderr+' '+$stdout) -split "`r?`n" | Where-Object {$_} | Select-Object -First 1)
            throw "$Label failed (exit $($process.ExitCode))$(if($detail){': '+$detail.Trim()}else{'.'})"
        }
        foreach($line in ($stdout -split "`r?`n" | Where-Object {$_})){Write-Output $line}
    }finally{$process.Dispose()}
}
function Invoke-DeckHarnessAccountOnce([string]$SuiteRoot,[string]$Account,[string[]]$Arguments,[switch]$ConfigureRunner,[switch]$CaptureHeadlessOutput) {
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
    $claudeTemporaryFiles=@()
    try{
        if($identity.Harness -eq 'Antigravity' -and -not (Test-DeckAntigravityFileAccount $identity)){
            if($CaptureHeadlessOutput){throw 'Headless failover requires isolated Antigravity file profiles, not a Windows runner profile.'}
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
        if(Test-DeckAntigravityFileAccount $identity){
            Assert-DeckAntigravityFileSupport $launch.Executable
            if(-not (Get-Command Sync-DeckAntigravityProfile -ErrorAction SilentlyContinue)){
                $defaultsModule=Join-Path $PSScriptRoot 'Deck.AntigravityDefaults.ps1'
                if(Test-Path -LiteralPath $defaultsModule){. $defaultsModule}
            }
            if(Get-Command Sync-DeckAntigravityProfile -ErrorAction SilentlyContinue){Sync-DeckAntigravityProfile $SuiteRoot $Account}
        }
        foreach($key in @($launch.Environment.Keys)+@($launch.Remove)){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$launch.Environment[$key],'Process')}
        if(Test-DeckAntigravityFileAccount $identity){
            foreach($key in @('USERPROFILE','APPDATA','LOCALAPPDATA')){[void][IO.Directory]::CreateDirectory($launch.Environment[$key])}
        }
        if($identity.Harness -eq 'Claude'){
            foreach($key in @('USERPROFILE','APPDATA','LOCALAPPDATA')){[void][IO.Directory]::CreateDirectory($launch.Environment[$key])}
            if(Get-Command Sync-DeckClaudeNativeDefaults -ErrorAction SilentlyContinue){[void](Sync-DeckClaudeNativeDefaults $SuiteRoot $Account)}
        }
        $configPath=Get-DeckHarnessConfigPath $SuiteRoot $Account
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $configPath))
        if(-not (Test-Path -LiteralPath $configPath)){Write-DeckEnvironmentJson $configPath ([pscustomobject]@{})}
        if($identity.Harness -eq 'Claude'){
            $config=Read-DeckEnvironmentJson $configPath
            if($config -isnot [System.Management.Automation.PSCustomObject]){throw 'Claude settings must contain a JSON object.'}
            $config | Add-Member NoteProperty forceLoginMethod 'claudeai' -Force
            Write-DeckEnvironmentJson $configPath $config
        }
        $nativeArguments=@($launch.Arguments)
        if($identity.Harness -eq 'Claude'){
            $claudeLaunch=New-DeckClaudeSessionArguments $SuiteRoot $Account $launch
            $nativeArguments=@($claudeLaunch.Arguments)
            $claudeTemporaryFiles=@($claudeLaunch.TemporaryFiles)
        }
        $captured=$null
        if($CaptureHeadlessOutput){$captured=Invoke-DeckHarnessProcess $launch.Executable $nativeArguments -CaptureOutput}
        else{Invoke-DeckHarnessProcess $launch.Executable $nativeArguments}
        if($identity.Harness -eq 'Claude' -and $launch.Arguments.Count -ge 2 -and $launch.Arguments[0] -eq 'auth' -and $launch.Arguments[1] -in @('login','logout')){Clear-DeckClaudeAuthStatus $SuiteRoot $Account}
        if($identity.Harness -eq 'Antigravity' -and $Arguments -contains 'login'){Clear-DeckAntigravityAuthStatus $SuiteRoot $Account}
        if($CaptureHeadlessOutput){return $captured}
    }finally{
        foreach($temporaryFile in $claudeTemporaryFiles){if(Test-Path -LiteralPath $temporaryFile -PathType Leaf){[IO.File]::Delete($temporaryFile)}}
        foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
        if(Test-Path -LiteralPath $session){[IO.File]::Delete($session)}
    }
}
function Invoke-DeckHarnessAccount([string]$SuiteRoot,[string]$Account,[string[]]$Arguments,[switch]$ConfigureRunner,[switch]$EnableHeadlessFailover,[string]$FailoverPool,[switch]$RequireFailoverPool) {
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    if($identity.Harness -ne 'Antigravity' -or -not (Test-DeckAntigravityHeadlessPrompt $Arguments) -or $ConfigureRunner){
        Invoke-DeckHarnessAccountOnce $SuiteRoot $Account $Arguments -ConfigureRunner:$ConfigureRunner
        return
    }
    if(-not $EnableHeadlessFailover){Invoke-DeckHarnessAccountOnce $SuiteRoot $Account $Arguments;return}
    if(-not (Test-DeckAntigravityFileAccount $identity)){
        if($RequireFailoverPool){throw 'AGY headless failover requires isolated file profiles; Windows runner accounts cannot be retried.'}
        Invoke-DeckHarnessAccountOnce $SuiteRoot $Account $Arguments
        return
    }
    if(-not $FailoverPool){$FailoverPool=[string](Get-DeckSettings (Join-Path $SuiteRoot 'deck')).HarnessAntigravityFailoverAccounts}
    $pool=@(Resolve-DeckAntigravityFailoverPool $SuiteRoot $FailoverPool $Account -RequireStartCredential:$RequireFailoverPool)
    if($pool.Count -le 1){Invoke-DeckHarnessAccountOnce $SuiteRoot $Account $Arguments;return}
    $machine=Get-DeckAntigravityMachineArguments $Arguments
    for($index=0;$index -lt $pool.Count;$index++){
        $candidate=$pool[$index]
        $captured=Invoke-DeckHarnessAccountOnce $SuiteRoot $candidate $machine.Arguments -CaptureHeadlessOutput
        $parsed=Read-DeckAntigravityStream ([string]$captured.StandardOutput)
        $effectiveExit=[int]$captured.ExitCode
        if($effectiveExit -eq 0 -and $parsed.Result -and $parsed.Result.status -ne 'SUCCESS'){$effectiveExit=1}
        $canRetry=$index -lt ($pool.Count-1) -and (Test-DeckAntigravityProviderFailure $effectiveExit ([string]$captured.StandardError) ([bool]$parsed.ToolExecuted))
        if($canRetry){[Console]::Error.WriteLine(("[Codex Deck] AGY profile {0} returned a quota/provider error before any tools ran; retrying with {1}." -f $candidate,$pool[$index+1]));continue}
        Write-DeckAntigravityCapturedResult $captured $parsed $machine.RequestedFormat
        return
    }
}
function Install-DeckHarness([string]$Harness) {
    $ErrorActionPreference='Stop'
    switch($Harness){
        'Codex' {& npm.cmd install -g '@openai/codex@latest'; if($LASTEXITCODE){throw 'Codex CLI installation failed.'}}
        'OpenCode' {& npm.cmd install -g 'opencode-ai@latest'; if($LASTEXITCODE){throw 'OpenCode installation failed.'}}
        'Claude' {
            $uri='https://claude.ai/install.ps1'
            $temporary=Join-Path ([IO.Path]::GetTempPath()) ('deck-harness-'+[guid]::NewGuid().ToString('N')+'.ps1')
            try{
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $temporary
                if((Get-Item -LiteralPath $temporary).Length -lt 32){throw "$Harness installer download was empty or incomplete."}
                # Run installers in a noninteractive child so `exit` in their script
                # cannot terminate Deck's worker. The settings UI monitors that worker
                # asynchronously and enforces a timeout.
                $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
                Invoke-DeckHarnessInstallerScript $temporary @() $Harness
            }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
        }
        'Antigravity' {
            $preferences=Get-DeckSettings (Join-Path $PSScriptRoot 'deck')
            $override=[string]$preferences.HarnessAntigravityPath
            $existing=$null
            if($override){
                if(-not (Test-Path -LiteralPath $override -PathType Leaf)){throw 'The configured Antigravity executable path does not exist.'}
                $existing=$override
            }else{
                $local=Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe'
                $shared=Join-Path ([Environment]::GetFolderPath('CommonDocuments') | Split-Path -Parent) 'CodexDeck/harnesses/agy.exe'
                if(Test-Path -LiteralPath $local -PathType Leaf){$existing=$local}
                elseif(Test-Path -LiteralPath $shared -PathType Leaf){$existing=$shared}
                else{
                    $command=Get-Command agy.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                    if($command){$existing=$command.Source}
                }
            }
            if($existing){
                # Google's bootstrap installer intentionally leaves an existing
                # CLI alone. Use its supported updater for upgrades instead.
                $LASTEXITCODE=0
                & $existing update
                if($LASTEXITCODE){throw "Antigravity update failed (exit $LASTEXITCODE)."}
            }else{
                $temporary=Join-Path ([IO.Path]::GetTempPath()) ('deck-harness-'+[guid]::NewGuid().ToString('N')+'.ps1')
                try{
                    Invoke-WebRequest -UseBasicParsing -Uri 'https://antigravity.google/cli/install.ps1' -OutFile $temporary
                    if((Get-Item -LiteralPath $temporary).Length -lt 32){throw 'Antigravity installer download was empty or incomplete.'}
                    $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
                    Invoke-DeckHarnessInstallerScript $temporary @('--skip-path','--skip-aliases') 'Antigravity installation'
                }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
            }
        }
        default {throw 'Unknown harness.'}
    }
    # Installers may update the user's PATH after this worker started.
    $env:PATH=[Environment]::GetEnvironmentVariable('Path','User')+';'+[Environment]::GetEnvironmentVariable('Path','Machine')+';'+$env:PATH
    if($Harness -eq 'Antigravity' -and -not (Get-DeckSettings (Join-Path $PSScriptRoot 'deck')).HarnessAntigravityPath){
        # Keep a binary readable by separate runner users. Do not overwrite GeminiLoop's install.
        $installed=Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe'
        if(-not (Test-Path -LiteralPath $installed -PathType Leaf)){
            $installed=Join-Path ([Environment]::GetFolderPath('CommonDocuments') | Split-Path -Parent) 'CodexDeck/harnesses/agy.exe'
        }
        $shared=Join-Path ([Environment]::GetFolderPath('CommonDocuments') | Split-Path -Parent) 'CodexDeck/harnesses/agy.exe'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $shared))
        if([IO.Path]::GetFullPath($installed) -ne [IO.Path]::GetFullPath($shared)){Copy-Item -LiteralPath $installed -Destination $shared -Force}
    }
    $executable=Resolve-DeckHarnessExecutable (Get-DeckDefaults) $Harness
    Write-Output "Installed / updated $Harness at $executable"
}
