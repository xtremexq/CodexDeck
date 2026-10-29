$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Refuses([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};Assert $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-claude-defaults-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'deck/claude'))
try{
    $defaultsPath=Get-DeckClaudeDefaultsPath $fixture
    $instructionsPath=Get-DeckClaudeGlobalInstructionsPath $fixture
    $codexRulesPath=Join-Path $fixture 'deck/global-rules.md'
    [IO.File]::WriteAllText($codexRulesPath,'Codex-only instructions.')
    Write-DeckClaudeTextAtomically $instructionsPath 'Claude-only instructions.'
    $defaultSettings=[pscustomobject]@{
        model='claude-sonnet-default'
        env=[pscustomobject]@{DECK_GLOBAL='global'}
        permissions=[pscustomobject]@{allow=@('Read','Glob');deny=@('Write')}
        project=[pscustomobject]@{preserve='global';override='global'}
    }
    Write-DeckClaudeTextAtomically $defaultsPath (ConvertTo-Json -InputObject $defaultSettings -Depth 100)
    Assert ((Get-DeckClaudeDefaultSettings $fixture).model -eq 'claude-sonnet-default') 'Claude global settings were not read.'
    Assert ([IO.File]::ReadAllText($instructionsPath) -eq 'Claude-only instructions.' -and [IO.File]::ReadAllText($codexRulesPath) -eq 'Codex-only instructions.') 'Claude defaults changed or reused Codex Global Rules.'

    $account=[pscustomobject]@{
        model='claude-opus-account'
        env=[pscustomobject]@{DECK_ACCOUNT='account'}
        permissions=[pscustomobject]@{allow=@('Read');deny=@()}
        project=[pscustomobject]@{override='account'}
    }
    $session=[pscustomobject]@{env=[pscustomobject]@{DECK_SESSION='session'};permissions=[pscustomobject]@{deny=@('Delete')};project=[pscustomobject]@{override='session'}}
    $merged=Merge-DeckClaudeSettings $defaultSettings $account $session
    Assert ($merged.model -eq 'claude-opus-account') 'Account settings did not override global defaults.'
    Assert ($merged.env.DECK_GLOBAL -eq 'global' -and $merged.env.DECK_ACCOUNT -eq 'account' -and $merged.env.DECK_SESSION -eq 'session') 'Nested Claude env defaults did not merge.'
    Assert (($merged.permissions.allow -join ',') -eq 'Read,Glob' -and ($merged.permissions.deny -join ',') -eq 'Write,Delete') 'Claude settings arrays did not combine according to native precedence.'
    Assert ($merged.project.preserve -eq 'global' -and $merged.project.override -eq 'session') 'Nested Claude defaults did not preserve unspecified settings.'

    $argumentResult=Get-DeckClaudeSettingsArgument @('--print','--settings','{"model":"claude-haiku-session"}','--verbose')
    Assert ($argumentResult.Found -and $argumentResult.Settings.model -eq 'claude-haiku-session' -and ($argumentResult.Arguments -join ' ') -eq '--print --verbose') 'Inline Claude session settings were not parsed while preserving other args.'
    $sessionFile=Join-Path $fixture 'session-settings.json'
    [IO.File]::WriteAllText($sessionFile,'{"model":"claude-file-session"}')
    $argumentResult=Get-DeckClaudeSettingsArgument @('--settings',$sessionFile)
    Assert ($argumentResult.Settings.model -eq 'claude-file-session') 'Claude session settings file was not read.'
    Refuses {Get-DeckClaudeSettingsArgument @('--settings','{}','--settings','{}')} 'Multiple Claude --settings overrides were accepted.'
    Refuses {Get-DeckClaudeSettingsArgument @('--settings','[]')} 'Non-object Claude session settings were accepted.'
    Refuses {Read-DeckClaudeSettingsFile $codexRulesPath} 'Non-JSON instructions were accepted as Claude settings.'
    Assert (-not (Test-DeckClaudeSessionLaunch @('auth','status')) -and (Test-DeckClaudeSessionLaunch @('--print','hello')) -and -not (Test-DeckClaudeSessionLaunch @('--help'))) 'Claude defaults would be applied to admin/help commands.'
    Refuses {Assert-DeckClaudeDefaultsNoSecrets ([pscustomobject]@{env=[pscustomobject]@{ANTHROPIC_API_KEY='synthetic'}})} 'Claude global defaults accepted a credential-like environment value.'
    Refuses {Assert-DeckClaudeDefaultsNoSecrets ([pscustomobject]@{env=[pscustomobject]@{GITHUB_TOKEN='synthetic'}})} 'Claude global defaults accepted a token credential.'
    Refuses {Assert-DeckClaudeDefaultsNoSecrets ([pscustomobject]@{env=[pscustomobject]@{AWS_SECRET_ACCESS_KEY='synthetic'}})} 'Claude global defaults accepted a secret key.'
    Refuses {Assert-DeckClaudeDefaultsNoSecrets ([pscustomobject]@{env=[pscustomobject]@{GOOGLE_APPLICATION_CREDENTIALS='synthetic'}})} 'Claude global defaults accepted a credential file path.'
    Refuses {Assert-DeckClaudeDefaultsNoSecrets ([pscustomobject]@{env=@('not','an','object')})} 'Claude global defaults accepted a non-object env section.'

    $savedBefore=[IO.File]::ReadAllText($defaultsPath)
    Write-DeckClaudeTextAtomically $defaultsPath '{"model":"new-default"}'
    Assert ((Get-DeckClaudeDefaultSettings $fixture).model -eq 'new-default') 'Atomic Claude defaults save failed.'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $defaultsPath) -Filter 'default-settings.json.bak-deck-*' -File).Count -eq 1) 'Claude defaults save did not preserve a backup.'
    Assert ($savedBefore -match 'claude-sonnet-default') 'Claude default settings fixture was not initialized.'

    $editor=Show-DeckClaudeDefaults $fixture -TestUI
    Assert ($editor.Dialog.Title -match 'Claude Global Defaults' -and $editor.Settings -and $editor.Instructions) 'Claude defaults WPF editor did not render its controls.'
    $editor.Instructions.Text='Saved from the Claude defaults editor.'
    $editor.SaveInstructions.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ([IO.File]::ReadAllText($instructionsPath) -eq 'Saved from the Claude defaults editor.' -and -not $editor.Error.Text) "Claude instructions editor did not save cleanly: $($editor.Error.Text)"
    $editor.Settings.Text='{"model":"claude-haiku-ui","env":{"ANTHROPIC_API_KEY":"synthetic"}}'
    $editor.SaveSettings.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($editor.Error.Text -match 'cannot store credentials' -and (Get-DeckClaudeDefaultSettings $fixture).model -eq 'new-default') "Claude settings editor failed to block credentials or preserved rejected data: error=$($editor.Error.Text); model=$((Get-DeckClaudeDefaultSettings $fixture).model)"
    $editor.Settings.Text='{"model":"claude-haiku-ui"}'
    $editor.SaveSettings.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ((Get-DeckClaudeDefaultSettings $fixture).model -eq 'claude-haiku-ui' -and -not $editor.Error.Text) 'Claude settings editor did not save a valid settings object.'
    $editor.Instructions.Text='Stale editor change.'
    [IO.File]::WriteAllText($instructionsPath,'External editor change.')
    $editor.SaveInstructions.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($editor.Error.Text -match 'changed in another editor' -and [IO.File]::ReadAllText($instructionsPath) -eq 'External editor change.') 'Claude instructions editor overwrote an external edit.'
    Write-DeckClaudeTextAtomically $defaultsPath 'invalid JSON'
    Refuses {Read-DeckClaudeSettingsFile $defaultsPath} 'Invalid saved Claude JSON was read as valid settings.'
    'PASS: separate Claude global instructions/settings, layered settings precedence, session overrides, credentials guard and backup-safe saves.'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\') -and (Split-Path $resolved -Leaf) -like 'deck-claude-defaults-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
