# Synthetic processes only: no installs, network or real provider credentials.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.Failover.ps1')
. (Join-Path $PSScriptRoot 'Deck.Backup.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Refuses([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};Assert $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-harness-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$previousCapture=$env:DECK_TEST_CAPTURE
$previousKey=$env:ANTHROPIC_API_KEY
$previousAuthToken=$env:ANTHROPIC_AUTH_TOKEN
$previousOAuthToken=$env:CLAUDE_CODE_OAUTH_TOKEN
$previousStatusConfig=$env:DECK_TEST_STATUS_CONFIG_DIRECTORY
$previousStatusLoggedIn=$env:DECK_TEST_LOGGED_IN
$claudeCredentialEnvironmentKeys=@('ANTHROPIC_BASE_URL','ANTHROPIC_MODEL','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_PROFILE','AWS_BEARER_TOKEN_BEDROCK','ANTHROPIC_BEDROCK_BASE_URL','ANTHROPIC_VERTEX_PROJECT_ID','ANTHROPIC_VERTEX_REGION','GOOGLE_APPLICATION_CREDENTIALS','CLOUD_ML_REGION','CLOUD_ML_PROJECT_ID')
$previousClaudeCredentialEnvironment=@{}
foreach($key in $claudeCredentialEnvironmentKeys){$previousClaudeCredentialEnvironment[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
$password=$null
try{
    $preferences=Get-DeckDefaults
    Assert (Test-DeckHarnessEnabled $preferences Codex) 'Codex must always be enabled'
    foreach($id in @('Claude','Antigravity','OpenCode')){Assert (-not (Test-DeckHarnessEnabled $preferences $id)) 'Optional harness enabled by default'}
    Refuses {New-DeckHarnessAccount $fixture disabled Claude Claude} 'Disabled harness accepted'
    foreach($id in @('Claude','Antigravity','OpenCode')){$preferences[('Harness'+$id+'Enabled')]=$true}
    $executable=Join-Path $fixture 'fake harness.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class FakeDeckHarness {
    public static int Main(string[] args) {
        using(var output=new StreamWriter(Environment.GetEnvironmentVariable("DECK_TEST_CAPTURE"))) {
            foreach(var arg in args) output.WriteLine("arg="+Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
            foreach(var key in new[]{"CLAUDE_CONFIG_DIR","ANTHROPIC_API_KEY","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_BASE_URL","ANTHROPIC_MODEL","CLAUDE_CODE_OAUTH_TOKEN","AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","AWS_SESSION_TOKEN","AWS_PROFILE","AWS_BEARER_TOKEN_BEDROCK","ANTHROPIC_BEDROCK_BASE_URL","ANTHROPIC_VERTEX_PROJECT_ID","ANTHROPIC_VERTEX_REGION","GOOGLE_APPLICATION_CREDENTIALS","CLOUD_ML_REGION","CLOUD_ML_PROJECT_ID","XDG_DATA_HOME","XDG_CONFIG_HOME","OPENCODE_CONFIG_DIR","OPENCODE_CONFIG_CONTENT","USERPROFILE","HOME","APPDATA","LOCALAPPDATA","SSH_CONNECTION","AGY_ADC_AUTH","GEMINI_API_KEY"})
                output.WriteLine(key+"="+Convert.ToBase64String(Encoding.UTF8.GetBytes(Environment.GetEnvironmentVariable(key)??"")));
        }
        if(args.Length==2 && args[0]=="auth" && args[1]=="status") {
            var directory=Environment.GetEnvironmentVariable("DECK_TEST_STATUS_CONFIG_DIRECTORY") ?? Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") ?? "";
            directory=directory.Replace("\\","\\\\").Replace("\"","\\\"");
            var loggedIn=Environment.GetEnvironmentVariable("DECK_TEST_LOGGED_IN")!="false";
            Console.WriteLine("{\"loggedIn\":"+(loggedIn?"true":"false")+",\"authMethod\":\"claude.ai\",\"configDirectory\":\""+directory+"\"}");
            return loggedIn?0:1;
        }
        return 17;
    }
}
'@ -OutputAssembly $executable -OutputType ConsoleApplication
    foreach($id in @('Codex','Claude','Antigravity','OpenCode')){$preferences[('Harness'+$id+'Path')]=$executable}
    Write-DeckJson (Join-Path $fixture 'deck/settings.json') $preferences
    [void](New-DeckHarnessAccount $fixture legacy Codex ChatGPT)
    [IO.File]::Delete((Join-Path $fixture 'accounts/legacy/deck-account.json'))
    Assert ((Get-DeckAccountIdentity $fixture legacy).Provider -eq 'ChatGPT') 'Legacy identity changed'
    Refuses {New-DeckHarnessAccount $fixture mismatch Claude Gemini} 'Claude accepted Gemini'
    Refuses {New-DeckHarnessAccount $fixture mismatch Antigravity ChatGPT} 'AGY accepted ChatGPT'
    Refuses {New-DeckHarnessAccount $fixture mismatch Codex Claude} 'Codex accepted Claude'
    Refuses {New-DeckHarnessAccount $fixture dashboard Claude Claude} 'Reserved name accepted'
    foreach($item in @(@('claudeA','Claude','Claude'),@('claudeB','Claude','Claude'),@('googleA','Antigravity','Gemini'),@('googleB','Antigravity','Gemini'),@('openA','OpenCode','ChatGPT'),@('openB','OpenCode','Gemini'))){[void](New-DeckHarnessAccount $fixture $item[0] $item[1] $item[2])}
    Refuses {New-DeckHarnessAccount $fixture claudeA Claude Claude} 'Existing account overwritten'
    $a=Get-DeckHarnessLaunch $fixture claudeA @('login')
    $b=Get-DeckHarnessLaunch $fixture claudeB @('logout')
    Assert (($a.Arguments -join '|') -eq 'auth|login') 'Claude login translation failed'
    Assert (($b.Arguments -join '|') -eq 'auth|logout') 'Claude logout translation failed'
    Assert ($a.Environment.CLAUDE_CONFIG_DIR -ne $b.Environment.CLAUDE_CONFIG_DIR) 'Claude accounts share config/credentials'
    $a=Get-DeckHarnessLaunch $fixture openA @('login')
    $b=Get-DeckHarnessLaunch $fixture openB @('login')
    Assert (($a.Arguments -join '|') -eq 'auth|login|--provider|openai') 'OpenCode ChatGPT login did not select OpenAI'
    Assert (($b.Arguments -join '|') -eq 'auth|login|--provider|google') 'OpenCode Gemini login did not select Google'
    Assert ($a.Environment.XDG_DATA_HOME -ne $b.Environment.XDG_DATA_HOME) 'OpenCode credentials/history are shared'
    Assert ($a.Remove -contains 'OPENCODE_CONFIG_CONTENT') 'Inherited OpenCode config can escape isolation'
    $env:DECK_TEST_CAPTURE=Join-Path $fixture 'capture.txt'
    $env:ANTHROPIC_API_KEY='synthetic-inherited-key'
    $env:ANTHROPIC_AUTH_TOKEN='synthetic-inherited-auth-token'
    $env:CLAUDE_CODE_OAUTH_TOKEN='synthetic-inherited-oauth-token'
    foreach($key in $claudeCredentialEnvironmentKeys){[Environment]::SetEnvironmentVariable($key,'synthetic-inherited-'+$key,'Process')}
    $env:DECK_TEST_STATUS_CONFIG_DIRECTORY=$null
    $env:DECK_TEST_LOGGED_IN='true'
    $nativeArguments=@('auth','status','quote "preserved"','space Ω','C:\trailing\','')
    Invoke-DeckHarnessAccount $fixture claudeA $nativeArguments
    Assert ($LASTEXITCODE -eq 17) 'Native exit code lost'
    $records=@{};$capturedArgs=@()
    foreach($line in [IO.File]::ReadAllLines($env:DECK_TEST_CAPTURE)){
        $parts=$line.Split('=',2);$value=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
        if($parts[0] -eq 'arg'){$capturedArgs+=,$value}else{$records[$parts[0]]=$value}
    }
    Assert (($capturedArgs | ConvertTo-Json -Compress) -ceq ($nativeArguments | ConvertTo-Json -Compress)) 'Native arguments changed (quotes, Unicode, spaces, empty or trailing slash)'
    Assert (-not $records.ANTHROPIC_API_KEY -and -not $records.ANTHROPIC_AUTH_TOKEN -and -not $records.CLAUDE_CODE_OAUTH_TOKEN) 'Claude inherited API/OAuth authentication'
    foreach($key in $claudeCredentialEnvironmentKeys){Assert (-not $records[$key]) "Claude inherited external provider/auth environment $key"}
    Assert ($records.CLAUDE_CONFIG_DIR -eq (Join-Path $fixture 'accounts/claudeA/claude')) 'Wrong Claude credential directory'
    Assert ($records.USERPROFILE -eq $records.CLAUDE_CONFIG_DIR -and $records.HOME -eq $records.CLAUDE_CONFIG_DIR) 'Claude home and ~/.claude.json were not isolated with its config directory'
    Assert ($records.APPDATA -eq (Join-Path $records.CLAUDE_CONFIG_DIR 'AppData/Roaming') -and $records.LOCALAPPDATA -eq (Join-Path $records.CLAUDE_CONFIG_DIR 'AppData/Local')) 'Claude application data was not isolated'
    Assert ($env:ANTHROPIC_API_KEY -eq 'synthetic-inherited-key') 'Parent credentials were changed'
    Assert ($env:ANTHROPIC_AUTH_TOKEN -eq 'synthetic-inherited-auth-token' -and $env:CLAUDE_CODE_OAUTH_TOKEN -eq 'synthetic-inherited-oauth-token') 'Parent Claude credentials were changed'
    Assert (@(Get-DeckSessions (Join-Path $fixture 'deck')).Count -eq 0) 'Native session was not cleaned up'
    Assert ((Read-DeckEnvironmentJson (Get-DeckHarnessConfigPath $fixture claudeA)).forceLoginMethod -eq 'claudeai') 'Claude subscription login was not enforced'

    $claudeDefaultsPath=Get-DeckClaudeDefaultsPath $fixture
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $claudeDefaultsPath))
    Write-DeckEnvironmentJson $claudeDefaultsPath ([pscustomobject]@{model='default-sonnet';env=[pscustomobject]@{DECK_GLOBAL='yes'};permissions=[pscustomobject]@{allow=@('Read','Glob');deny=@('Write')};nested=[pscustomobject]@{keep='global';replace='global'}})
    [IO.File]::WriteAllText((Get-DeckClaudeGlobalInstructionsPath $fixture),'Deck-wide Claude instruction.')
    Write-DeckEnvironmentJson (Get-DeckHarnessConfigPath $fixture claudeA) ([pscustomobject]@{env=[pscustomobject]@{DECK_ACCOUNT='yes'};permissions=[pscustomobject]@{allow=@('Read');deny=@()};nested=[pscustomobject]@{replace='account'}})
    $sessionPrompt=Join-Path $fixture 'session-prompt.md';[IO.File]::WriteAllText($sessionPrompt,'Session-only instruction.')
    $sessionLaunch=Get-DeckHarnessLaunch $fixture claudeA @('--settings','{"env":{"DECK_SESSION":"yes"},"permissions":{"deny":["Delete"]},"nested":{"replace":"session"}}','--append-system-prompt-file',$sessionPrompt)
    $prepared=New-DeckClaudeSessionArguments $fixture claudeA $sessionLaunch
    $settingsIndex=[Array]::IndexOf([string[]]$prepared.Arguments,'--settings')
    $mergedSettings=Read-DeckClaudeSettingsFile $prepared.Arguments[$settingsIndex+1] 'generated Claude settings'
    Assert ($mergedSettings.model -eq 'default-sonnet' -and $mergedSettings.env.DECK_GLOBAL -eq 'yes' -and $mergedSettings.env.DECK_ACCOUNT -eq 'yes' -and $mergedSettings.env.DECK_SESSION -eq 'yes') 'Claude global/account/session object settings did not merge by precedence'
    Assert (($mergedSettings.permissions.allow -join ',') -eq 'Read,Glob' -and ($mergedSettings.permissions.deny -join ',') -eq 'Write,Delete') 'Claude account/session arrays did not combine according to native precedence'
    Assert ($mergedSettings.nested.keep -eq 'global' -and $mergedSettings.nested.replace -eq 'session') 'Nested Claude settings did not preserve and override individual values'
    $promptIndex=[Array]::IndexOf([string[]]$prepared.Arguments,'--append-system-prompt-file')
    $mergedPrompt=[IO.File]::ReadAllText($prepared.Arguments[$promptIndex+1])
    Assert ($mergedPrompt -match 'Deck-wide Claude instruction\.' -and $mergedPrompt -match 'Session-only instruction\.') 'Claude global and per-session prompt instructions did not combine'
    foreach($temporaryFile in $prepared.TemporaryFiles){[IO.File]::Delete($temporaryFile)}

    $parentProfile=$env:USERPROFILE;$parentHome=$env:HOME;$parentAppData=$env:APPDATA;$parentLocalAppData=$env:LOCALAPPDATA
    $checked=Get-DeckClaudeAuthStatus $fixture claudeA
    Assert ($checked.LoggedIn -and $checked.AuthMethod -eq 'claude.ai') 'Claude isolated native sign-in check did not parse a signed-in status'
    Assert ((Read-DeckEnvironmentJson (Join-Path $fixture 'deck/claude-auth-checks.json')).claudeA.LoggedIn) 'Claude sign-in check was not cached'
    Assert ((Get-DeckProfile $fixture claudeA).AuthStatus -eq 'Signed in') 'Claude dashboard profile did not show checked sign-in state'
    Assert ($env:USERPROFILE -eq $parentProfile -and $env:HOME -eq $parentHome -and $env:APPDATA -eq $parentAppData -and $env:LOCALAPPDATA -eq $parentLocalAppData) 'Claude sign-in check changed the parent profile environment'
    $env:DECK_TEST_LOGGED_IN='false'
    $needsLogin=Get-DeckClaudeAuthStatus $fixture claudeA
    Assert (-not $needsLogin.LoggedIn -and (Get-DeckProfile $fixture claudeA).AuthStatus -eq 'Sign in required') 'Claude sign-in-required status was not reported'
    $beforeInvalidCheck=(Read-DeckEnvironmentJson (Join-Path $fixture 'deck/claude-auth-checks.json')).claudeA.CheckedAt
    $env:DECK_TEST_STATUS_CONFIG_DIRECTORY=Join-Path $fixture 'accounts/claudeB/claude'
    Refuses {Get-DeckClaudeAuthStatus $fixture claudeA} 'Claude check accepted another account config directory'
    Assert ((Read-DeckEnvironmentJson (Join-Path $fixture 'deck/claude-auth-checks.json')).claudeA.CheckedAt -eq $beforeInvalidCheck) 'Rejected Claude isolation check overwrote valid cached status'
    $env:DECK_TEST_STATUS_CONFIG_DIRECTORY=$null;$env:DECK_TEST_LOGGED_IN='true'

    $claudeSessionLaunch=Get-DeckHarnessLaunch $fixture claudeA @()
    Invoke-DeckHarnessAccount $fixture claudeA @()
    Assert ($LASTEXITCODE -eq 17) 'Claude interactive launch lost native exit code'
    Assert (@(Get-ChildItem -LiteralPath $claudeSessionLaunch.Environment.CLAUDE_CONFIG_DIR -Filter '.codexdeck-*' -File).Count -eq 0) 'Claude temporary defaults/instruction files were not cleaned up after launch'
    Assert (@(Get-DeckSessions (Join-Path $fixture 'deck')).Count -eq 0) 'Claude session was not cleaned up after launch'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'accounts/claudeB/claude'))
    [IO.File]::WriteAllText((Get-DeckHarnessConfigPath $fixture claudeB),'[]')
    Refuses {Invoke-DeckHarnessAccount $fixture claudeB @('login')} 'Non-object Claude settings accepted'
    Assert ($env:ANTHROPIC_API_KEY -eq 'synthetic-inherited-key') 'Failed launch changed parent credentials'
    $a=Get-DeckHarnessLaunch $fixture googleA @('login')
    $b=Get-DeckHarnessLaunch $fixture googleB @()
    Assert ($a.Environment.USERPROFILE -ne $b.Environment.USERPROFILE -and $a.Arguments.Count -eq 0) 'Antigravity file accounts share a profile or did not translate login'
    Assert ($a.Environment.SSH_CONNECTION -and $a.Environment.AGY_ADC_AUTH -eq 'false') 'AGY remote file authentication was not selected'
    $parentProfile=$env:USERPROFILE; $parentSsh=$env:SSH_CONNECTION
    Refuses {Invoke-DeckHarnessAccount $fixture googleB @('login')} 'An incompatible AGY binary was allowed to access authentication'
    Assert ($env:USERPROFILE -eq $parentProfile -and $env:SSH_CONNECTION -eq $parentSsh) 'Rejected AGY launch changed parent environment'
    & {
        function Assert-DeckAntigravityFileSupport($Executable){}
        Invoke-DeckHarnessAccount $fixture googleB @('login')
        $records=@{}
        foreach($line in [IO.File]::ReadAllLines($env:DECK_TEST_CAPTURE)){$parts=$line.Split('=',2);$records[$parts[0]]=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))}
        Assert ($records.USERPROFILE -eq $b.Environment.USERPROFILE -and $records.SSH_CONNECTION -eq $b.Environment.SSH_CONNECTION) 'AGY isolated environment did not reach native process'
        Assert ($LASTEXITCODE -eq 17) 'AGY file launch lost native exit code'
    }
    Assert ($env:USERPROFILE -eq $parentProfile -and $env:SSH_CONNECTION -eq $parentSsh) 'AGY file launch changed parent environment'
    $agyDefaultsPath=Get-DeckAntigravityDefaultsPath $fixture
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $agyDefaultsPath))
    Write-DeckEnvironmentJson $agyDefaultsPath ([pscustomobject]@{model='default-model';nested=[pscustomobject]@{global='global-value';replace='default-value'};modelProvider='must-not-be-copied'})
    [IO.File]::WriteAllText((Get-DeckAntigravityGlobalRulesPath $fixture),'Shared AGY rule.')
    $agySettingsPath=Get-DeckHarnessConfigPath $fixture googleB
    Write-DeckEnvironmentJson $agySettingsPath ([pscustomobject]@{model='account-model';nested=[pscustomobject]@{replace='account-value'};accountOnly=$true})
    Sync-DeckAntigravityProfile $fixture googleB
    $agyEffective=Read-DeckEnvironmentJson $agySettingsPath
    $agyRulesPath=Join-Path $fixture 'accounts/googleB/antigravity/profile/.gemini/antigravity-cli/rules/codexdeck-global.md'
    $agyRules=[IO.File]::ReadAllText($agyRulesPath)
    Assert ($agyEffective.model -eq 'account-model' -and $agyEffective.nested.global -eq 'global-value' -and $agyEffective.nested.replace -eq 'account-value' -and $agyEffective.accountOnly) 'AGY global defaults did not merge under account settings'
    Assert (-not $agyEffective.PSObject.Properties['modelProvider'] -and $agyRules -match 'trigger: always_on' -and $agyRules -match 'Shared AGY rule\.') 'AGY model-provider guard or native global rule sync failed'
    Write-DeckEnvironmentJson $agyDefaultsPath ([pscustomobject]@{model='updated-default';nested=[pscustomobject]@{global='updated-global';replace='updated-default-value';newDefault='new-value'}})
    Sync-DeckAntigravityProfile $fixture googleB
    $agyEffective=Read-DeckEnvironmentJson $agySettingsPath
    Assert ($agyEffective.model -eq 'account-model' -and $agyEffective.nested.global -eq 'updated-global' -and $agyEffective.nested.replace -eq 'account-value' -and $agyEffective.nested.newDefault -eq 'new-value') 'AGY updated defaults overwrote account overrides or failed to reach the account'
    $agyEffective.model='native-account-model';$agyEffective | Add-Member NoteProperty nativeSetting 'preserved' -Force
    Write-DeckEnvironmentJson $agySettingsPath $agyEffective
    Sync-DeckAntigravityProfile $fixture googleB
    $agyEffective=Read-DeckEnvironmentJson $agySettingsPath
    Assert ($agyEffective.model -eq 'native-account-model' -and $agyEffective.nativeSetting -eq 'preserved') 'AGY settings sync did not preserve native account edits'
    Write-DeckEnvironmentJson $agyDefaultsPath ([pscustomobject]@{apiKey='synthetic-secret'})
    Refuses {Sync-DeckAntigravityProfile $fixture googleB} 'AGY global settings accepted a credential field'
    $agyAuth=Join-Path $fixture 'accounts/googleB/antigravity/profile/.gemini/antigravity-cli/antigravity-oauth-token'
    Write-DeckEnvironmentJson $agyAuth @{synthetic='isolated-google-token'}
    foreach($name in @('legacy','claudeA')){Write-DeckEnvironmentJson (Join-Path $fixture "accounts/$name/auth.json") @{tokens=@{access_token='synthetic'}}}
    Assert (((Resolve-DeckFailoverPool $fixture '*' Ordered).Pool -join ',') -eq 'legacy') 'Wildcard failover includes foreign accounts'
    Refuses {Resolve-DeckFailoverPool $fixture 'legacy,claudeA' Ordered} 'Explicit failover includes a Claude account'
    Refuses {Resolve-DeckEntryPool $fixture ([pscustomobject]@{Accounts=@('claudeA')})} 'Pool includes a Claude account'
    Refuses {Get-DeckCheckCode $fixture claudeA} 'Codex usage probe accepted Claude'
    Refuses {Get-DeckModelsCode $fixture claudeA} 'Codex model discovery accepted Claude'
    Refuses {Get-DeckWarmupCode $fixture claudeA} 'Codex warm-up accepted Claude'
    Refuses {Request-DeckWarmup $fixture claudeA -NoStart} 'Codex manual warm-up accepted Claude'
    Assert ((@(Get-DeckSignedInAccounts $fixture) -join ',') -eq 'legacy') 'Warm-up candidates include a foreign account'
    Refuses {Set-DeckAntigravityRunner $fixture claudeA} 'Runner configuration accepted Claude'
    & {
        function Invoke-WebRequest($Uri,$OutFile,[switch]$UseBasicParsing){[IO.File]::WriteAllText($OutFile,"Write-Output 'simulated installer failure'; exit 7")}
        Refuses {Install-DeckHarness Claude} 'Official installer failure was ignored'
        function Invoke-WebRequest($Uri,$OutFile,[switch]$UseBasicParsing){[IO.File]::WriteAllText($OutFile,"Write-Output 'simulated installer success output'; exit 0")}
        function Resolve-DeckHarnessExecutable($Settings,$Harness){return $executable}
        Assert ((Install-DeckHarness Claude) -like 'Installed / updated Claude at *') 'Installer exit stopped the worker before verification'
    }
    $runnerCredential=Join-Path $fixture 'accounts/googleA/runner-credential.clixml'
    $testCredential=[pscredential]::new([Security.Principal.WindowsIdentity]::GetCurrent().Name,(ConvertTo-SecureString 'synthetic-not-a-real-password' -AsPlainText -Force))
    $testCredential | Export-Clixml -LiteralPath $runnerCredential
    Write-DeckEnvironmentJson (Join-Path $fixture 'accounts/googleA/deck-account.json') @{Version=1;Harness='Antigravity';Provider='Gemini';RunnerSid='invalid-synthetic-sid'}
    Refuses {Invoke-DeckHarnessAccount $fixture googleA @('login')} 'Mismatched runner identity was launched'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deck.AntigravityRunner.ps1') -Destination $fixture
    Write-DeckEnvironmentJson (Join-Path $fixture 'accounts/googleA/deck-account.json') @{Version=1;Harness='Antigravity';Provider='Gemini';RunnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
    & {
        $state=@{Code=$null;Disposed=$false}
        function Start-Process {
            param($FilePath,$Credential,[switch]$LoadUserProfile,$ArgumentList,$WorkingDirectory,[switch]$PassThru)
            $state.Code=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $fake=[pscustomobject]@{ExitCode=17;State=$state}
            $fake | Add-Member ScriptMethod WaitForExit {}
            $fake | Add-Member ScriptMethod Dispose {$this.State.Disposed=$true}
            return $fake
        }
        Invoke-DeckHarnessAccount $fixture googleA @('login','quote "preserved"','space Ω','')
        $parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseInput($state.Code,[ref]$null,[ref]$parseErrors)
        Assert (-not $parseErrors -and $state.Code -match 'function Invoke-DeckHarnessProcess' -and $state.Code -match "'quote") 'Embedded Antigravity runner was invalid or lost native arguments'
        Assert ($LASTEXITCODE -eq 17 -and $state.Disposed) 'Antigravity exit status or process cleanup failed'
    }
    Assert (@(Get-DeckSessions (Join-Path $fixture 'deck')).Count -eq 0) 'Antigravity session was not cleaned up'
    Write-DeckEnvironmentJson (Join-Path $fixture 'accounts/openA/deck-account.json') @{Version=1;Harness='Codex';Provider='Gemini'}
    Refuses {Get-DeckAccountIdentity $fixture openA} 'Corrupt provider binding accepted'
    Write-DeckEnvironmentJson (Join-Path $fixture 'accounts/openA/deck-account.json') @{Version=1;Harness='OpenCode';Provider='ChatGPT'}
    $linked=Join-Path $fixture 'accounts/openB/opencode'
    New-Item -ItemType Junction -Path $linked -Target (Join-Path $fixture 'accounts/openA') | Out-Null
    try{Refuses {Get-DeckHarnessLaunch $fixture openB @()} 'Linked credential ancestor accepted'}finally{[IO.Directory]::Delete($linked)}
    foreach($file in @('Deck.Core.ps1','Deck.Harnesses.ps1','Deck.ClaudeDefaults.ps1','Deck.Antigravity.Isolation.cs','Deck.Environments.ps1','Deck.AccountTools.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $fixture}
    $source=Join-Path $PSScriptRoot '../bin/codex-auth.ps1'
    if(-not (Test-Path -LiteralPath $source)){$source=Join-Path $PSScriptRoot '../.local/bin/codex-auth.ps1'}
    $launcher=[IO.File]::ReadAllText($source)
    $assignment='$accountsRoot = '''+(Join-Path $fixture 'accounts').Replace("'","''")+''''
    $launcher=[regex]::Replace($launcher,'(?m)^\$accountsRoot =.*$',[Text.RegularExpressions.MatchEvaluator]{param($m)$assignment})
    [IO.File]::WriteAllText((Join-Path $fixture 'codex-auth.ps1'),$launcher,[Text.UTF8Encoding]::new($true))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'codex-auth.ps1') created -NewAccount -Harness Claude -Provider Claude login
    Assert ($LASTEXITCODE -eq 17) 'Real wrapper lost native login exit status'
    Assert ((Get-DeckAccountIdentity $fixture created).Harness -eq 'Claude') 'Real wrapper did not create the Claude account'
    $ErrorActionPreference='Continue'
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'codex-auth.ps1') created -Harness Codex 2>&1
    $ErrorActionPreference='Stop'
    Assert ($LASTEXITCODE -ne 0) 'Real wrapper rebound existing account to Codex'
    $listCode="& '"+(Join-Path $fixture 'codex-auth.ps1').Replace("'","''")+"' -Account '--list' *> `$null"
    $listEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($listCode))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $listEncoded | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Legacy --list command failed'
    Write-DeckEnvironmentJson (Join-Path $fixture 'accounts/claudeA/claude/.credentials.json') @{synthetic='private-test-token'}
    [IO.File]::WriteAllText((Join-Path $fixture 'accounts/googleA/runner-credential.clixml'),'excluded-synthetic-dpapi')
    $password=ConvertTo-SecureString 'Synthetic harness backup 42!' -AsPlainText -Force
    $archive=Join-Path $fixture 'harnesses.cdeck'
    [void](Export-DeckBackup $fixture (Join-Path $fixture 'absent-default.toml') $archive $password)
    $manifest=Read-DeckBackup $archive $password
    Assert (@($manifest.Files.Path | Where-Object {$_ -like '*runner-credential*'}).Count -eq 0) 'Runner password exported'
    $restored=Join-Path $fixture 'restored'
    [void](Import-DeckBackup $restored (Join-Path $fixture 'restored-default.toml') $manifest)
    Assert ((Get-DeckAccountIdentity $restored claudeA).Harness -eq 'Claude') 'Harness identity lost during backup'
    Assert ((Read-DeckEnvironmentJson (Join-Path $restored 'accounts/claudeA/claude/.credentials.json')).synthetic -eq 'private-test-token') 'Native credentials did not round-trip'
    Assert ((Read-DeckEnvironmentJson (Join-Path $restored 'accounts/googleB/antigravity/profile/.gemini/antigravity-cli/antigravity-oauth-token')).synthetic -eq 'isolated-google-token') 'AGY file credentials did not round-trip'
    'PASS: harness defaults, primary providers, native login commands, credential isolation, AGY shared defaults and account overrides, Windows arguments, exit codes, session cleanup, pools, links, real wrapper and encrypted backups.'
}finally{
    [Environment]::SetEnvironmentVariable('DECK_TEST_CAPTURE',$previousCapture,'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY',$previousKey,'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN',$previousAuthToken,'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN',$previousOAuthToken,'Process')
    [Environment]::SetEnvironmentVariable('DECK_TEST_STATUS_CONFIG_DIRECTORY',$previousStatusConfig,'Process')
    [Environment]::SetEnvironmentVariable('DECK_TEST_LOGGED_IN',$previousStatusLoggedIn,'Process')
    foreach($key in $previousClaudeCredentialEnvironment.Keys){[Environment]::SetEnvironmentVariable($key,$previousClaudeCredentialEnvironment[$key],'Process')}
    if($password){$password.Dispose()}
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\') -and (Split-Path $resolved -Leaf) -like 'deck-harness-test-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
