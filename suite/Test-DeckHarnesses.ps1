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
            foreach(var key in new[]{"CLAUDE_CONFIG_DIR","ANTHROPIC_API_KEY","XDG_DATA_HOME","XDG_CONFIG_HOME","OPENCODE_CONFIG_DIR","OPENCODE_CONFIG_CONTENT","USERPROFILE","SSH_CONNECTION","AGY_ADC_AUTH","GEMINI_API_KEY"})
                output.WriteLine(key+"="+Convert.ToBase64String(Encoding.UTF8.GetBytes(Environment.GetEnvironmentVariable(key)??"")));
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
    $nativeArguments=@('auth','status','quote "preserved"','space Ω','C:\trailing\','')
    Invoke-DeckHarnessAccount $fixture claudeA $nativeArguments
    Assert ($LASTEXITCODE -eq 17) 'Native exit code lost'
    $records=@{};$capturedArgs=@()
    foreach($line in [IO.File]::ReadAllLines($env:DECK_TEST_CAPTURE)){
        $parts=$line.Split('=',2);$value=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
        if($parts[0] -eq 'arg'){$capturedArgs+=,$value}else{$records[$parts[0]]=$value}
    }
    Assert (($capturedArgs | ConvertTo-Json -Compress) -ceq ($nativeArguments | ConvertTo-Json -Compress)) 'Native arguments changed (quotes, Unicode, spaces, empty or trailing slash)'
    Assert (-not $records.ANTHROPIC_API_KEY) 'Claude inherited API authentication'
    Assert ($records.CLAUDE_CONFIG_DIR -eq (Join-Path $fixture 'accounts/claudeA/claude')) 'Wrong Claude credential directory'
    Assert ($env:ANTHROPIC_API_KEY -eq 'synthetic-inherited-key') 'Parent credentials were changed'
    Assert (@(Get-DeckSessions (Join-Path $fixture 'deck')).Count -eq 0) 'Native session was not cleaned up'
    Assert ((Read-DeckEnvironmentJson (Get-DeckHarnessConfigPath $fixture claudeA)).forceLoginMethod -eq 'claudeai') 'Claude subscription login was not enforced'
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
        function Invoke-WebRequest($Uri,$OutFile,[switch]$UseBasicParsing){[IO.File]::WriteAllText($OutFile,'exit 7')}
        Refuses {Install-DeckHarness Claude} 'Official installer failure was ignored'
        function Invoke-WebRequest($Uri,$OutFile,[switch]$UseBasicParsing){[IO.File]::WriteAllText($OutFile,'exit 0')}
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
    foreach($file in @('Deck.Core.ps1','Deck.Harnesses.ps1','Deck.Antigravity.Isolation.cs','Deck.Environments.ps1','Deck.AccountTools.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $fixture}
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
    'PASS: harness defaults, primary providers, native login commands, credential isolation, Windows arguments, exit codes, session cleanup, pools, links, real wrapper and encrypted backups.'
}finally{
    [Environment]::SetEnvironmentVariable('DECK_TEST_CAPTURE',$previousCapture,'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY',$previousKey,'Process')
    if($password){$password.Dispose()}
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\') -and (Split-Path $resolved -Leaf) -like 'deck-harness-test-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
