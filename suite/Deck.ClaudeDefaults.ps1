param(
    [switch]$ClaudeDefaultsEdit,
    [string]$ClaudeDefaultsSuiteRoot=$PSScriptRoot
)

function Get-DeckClaudeDefaultsPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/claude/default-settings.json'
}

function Get-DeckClaudeGlobalInstructionsPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/claude/global-instructions.md'
}

function Test-DeckClaudeJsonObject($Value) {
    return $Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [Collections.IDictionary]
}

function Read-DeckClaudeSettingsFile([string]$Path,[string]$Label='Claude settings') {
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{}}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "$Label must be a regular file."}
    try{$value=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop}catch{throw "$Label contains invalid JSON: $($_.Exception.Message)"}
    if(-not (Test-DeckClaudeJsonObject $value)){throw "$Label must contain a JSON object."}
    return $value
}

function Get-DeckClaudeDefaultSettings([string]$SuiteRoot) {
    return Read-DeckClaudeSettingsFile (Get-DeckClaudeDefaultsPath $SuiteRoot) 'Claude global defaults'
}

function Merge-DeckClaudeSettingsValue($Base,$Override,[string]$Key='') {
    if((Test-DeckClaudeJsonObject $Base) -and (Test-DeckClaudeJsonObject $Override)){
        $merged=[ordered]@{}
        foreach($property in $Base.PSObject.Properties){
            $overrideProperty=$Override.PSObject.Properties[$property.Name]
            if($overrideProperty){$merged[$property.Name]=Merge-DeckClaudeSettingsValue $property.Value $overrideProperty.Value $property.Name}
            else{$merged[$property.Name]=$property.Value}
        }
        foreach($property in $Override.PSObject.Properties){if(-not $Base.PSObject.Properties[$property.Name]){$merged[$property.Name]=$property.Value}}
        return [pscustomobject]$merged
    }
    if($Base -is [array] -and $Override -is [array]){
        if($Key -in @('fallbackModel','modelPicker')){return ,$Override}
        $items=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($item in @($Base)+@($Override)){
            $signature=ConvertTo-Json -InputObject $item -Compress -Depth 100
            if($seen.Add($signature)){$items.Add($item)}
        }
        return ,$items.ToArray()
    }
    return $Override
}

function Merge-DeckClaudeSettings($Defaults,$AccountSettings,$SessionSettings=$null) {
    $merged=if(Test-DeckClaudeJsonObject $Defaults){$Defaults}else{[pscustomobject]@{}}
    if(Test-DeckClaudeJsonObject $AccountSettings){$merged=Merge-DeckClaudeSettingsValue $merged $AccountSettings}
    if(Test-DeckClaudeJsonObject $SessionSettings){$merged=Merge-DeckClaudeSettingsValue $merged $SessionSettings}
    return $merged
}

function Get-DeckClaudeSettingsArgument([string[]]$Arguments) {
    $clean=[Collections.Generic.List[string]]::new();$settings=$null;$found=$false
    for($i=0;$i -lt $Arguments.Count;$i++){
        $argument=[string]$Arguments[$i]
        if($argument -eq '--settings'){
            if($found -or $i+1 -ge $Arguments.Count){throw 'Use one Claude --settings value per launch.'}
            $found=$true;$i++;$value=[string]$Arguments[$i]
        }elseif($argument.StartsWith('--settings=',[StringComparison]::Ordinal)){
            if($found){throw 'Use one Claude --settings value per launch.'}
            $found=$true;$value=$argument.Substring('--settings='.Length)
        }else{$clean.Add($argument);continue}
        if(-not $value.TrimStart().StartsWith('{',[StringComparison]::Ordinal) -and (Test-Path -LiteralPath $value -PathType Leaf)){$settings=Read-DeckClaudeSettingsFile ([IO.Path]::GetFullPath($value)) 'Claude session settings'}
        else{
            try{$settings=$value | ConvertFrom-Json -ErrorAction Stop}catch{throw 'Claude --settings must be a JSON object or a readable JSON file.'}
            if(-not (Test-DeckClaudeJsonObject $settings)){throw 'Claude --settings must contain a JSON object.'}
        }
    }
    return @{Found=$found;Settings=$settings;Arguments=$clean.ToArray()}
}

function Test-DeckClaudeSessionLaunch([string[]]$Arguments) {
    if(-not $Arguments.Count){return $true}
    if($Arguments[0] -match '^(?i:auth|doctor|update|mcp|plugin|plugins|agents|attach|logs|daemon|gateway|install|uninstall|version)$'){return $false}
    if($Arguments[0] -in @('--help','-h','--version','-v')){return $false}
    return $true
}

function Assert-DeckClaudeDefaultsNoSecrets($Settings) {
    if(-not $Settings.PSObject.Properties['env']){return}
    $environment=$Settings.env
    if(-not (Test-DeckClaudeJsonObject $environment)){throw 'Claude global defaults env must be a JSON object.'}
    foreach($property in $environment.PSObject.Properties){
        if($property.Name -match '(?i)(API.?KEY|AUTH.?TOKEN|OAUTH.?TOKEN|ACCESS.?TOKEN|REFRESH.?TOKEN|SECRET|PRIVATE.?KEY|ACCESS.?KEY|PASSWORD|CREDENTIAL|SESSION.?TOKEN|BEARER.?TOKEN|(^|_)TOKEN($|_))' -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){
            throw "Claude global defaults cannot store credentials in env.$($property.Name). Put credentials in the individual Claude account instead."
        }
    }
}

function Write-DeckClaudeTextAtomically([string]$Path,[string]$Text) {
    $directory=Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    if(Test-Path -LiteralPath $Path){
        $item=Get-Item -LiteralPath $Path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Claude defaults must be regular files.'}
    }
    $temporary=Join-Path $directory ('.claude-deck-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path){
            $backup=$Path+'.bak-deck-'+[guid]::NewGuid().ToString('N')
            [IO.File]::Replace($temporary,$Path,$backup)
        }else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}

function Show-DeckClaudeDefaults([string]$SuiteRoot,$Owner=$null,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    $instructionsPath=Get-DeckClaudeGlobalInstructionsPath $SuiteRoot
    $settingsPath=Get-DeckClaudeDefaultsPath $SuiteRoot
    $initialInstructions=if(Test-Path -LiteralPath $instructionsPath -PathType Leaf){[IO.File]::ReadAllText($instructionsPath)}else{''}
    $initialSettings=Read-DeckClaudeSettingsFile $settingsPath 'Claude global defaults'
    $initialSettingsText=ConvertTo-Json -InputObject $initialSettings -Depth 100
    $state=@{
        InstructionsExists=Test-Path -LiteralPath $instructionsPath -PathType Leaf
        InstructionsText=$initialInstructions
        SettingsExists=Test-Path -LiteralPath $settingsPath -PathType Leaf
        SettingsText=if(Test-Path -LiteralPath $settingsPath -PathType Leaf){[IO.File]::ReadAllText($settingsPath)}else{''}
    }
    $dialog=[Windows.Window]::new();$dialog.Title='Codex Deck / Claude Global Defaults';$dialog.Width=820;$dialog.Height=650;$dialog.MinWidth=640;$dialog.MinHeight=460
    $dialog.Background='#101315';$dialog.Foreground='#EAF0FA';$dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='Applies to every isolated Claude account. Instructions are appended to Claude sessions. Account settings override these defaults; explicit session settings override account settings. Deck passes merged settings with --settings, so those keys override project settings for that session. Managed Claude settings remain authoritative. This is separate from Codex Global Rules. Do not store credentials here.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $buttons=[Windows.Controls.WrapPanel]::new();$buttons.HorizontalAlignment='Right';$buttons.Margin='0,12,0,0';[Windows.Controls.DockPanel]::SetDock($buttons,'Bottom');[void]$dock.Children.Add($buttons)
    $saveInstructions=[Windows.Controls.Button]::new();$saveInstructions.Content='Save instructions';$saveInstructions.Padding='12,8';$saveInstructions.Margin='0,0,8,0';[void]$buttons.Children.Add($saveInstructions)
    $saveSettings=[Windows.Controls.Button]::new();$saveSettings.Content='Save settings defaults';$saveSettings.Padding='12,8';[void]$buttons.Children.Add($saveSettings)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap';$errorText.Margin='0,0,0,8';[Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $tabs=[Windows.Controls.TabControl]::new();[void]$dock.Children.Add($tabs)
    $instructionsTab=[Windows.Controls.TabItem]::new();$instructionsTab.Header='Global instructions'
    $instructionsEditor=[Windows.Controls.TextBox]::new();$instructionsEditor.Text=$initialInstructions;$instructionsEditor.AcceptsReturn=$true;$instructionsEditor.AcceptsTab=$true;$instructionsEditor.TextWrapping='Wrap';$instructionsEditor.VerticalScrollBarVisibility='Auto';$instructionsEditor.HorizontalScrollBarVisibility='Auto';$instructionsEditor.FontFamily='Consolas';$instructionsEditor.FontSize=14;$instructionsEditor.Background='#192232';$instructionsEditor.Foreground='#EAF0FA';$instructionsTab.Content=$instructionsEditor;[void]$tabs.Items.Add($instructionsTab)
    $settingsTab=[Windows.Controls.TabItem]::new();$settingsTab.Header='Global settings defaults'
    $settingsEditor=[Windows.Controls.TextBox]::new();$settingsEditor.Text=$initialSettingsText;$settingsEditor.AcceptsReturn=$true;$settingsEditor.AcceptsTab=$true;$settingsEditor.TextWrapping='NoWrap';$settingsEditor.VerticalScrollBarVisibility='Auto';$settingsEditor.HorizontalScrollBarVisibility='Auto';$settingsEditor.FontFamily='Consolas';$settingsEditor.FontSize=14;$settingsEditor.Background='#192232';$settingsEditor.Foreground='#EAF0FA';$settingsTab.Content=$settingsEditor;[void]$tabs.Items.Add($settingsTab)
    $writeText={
        param([string]$Path,[string]$Text)
        $directory=Split-Path -Parent $Path
        [void][IO.Directory]::CreateDirectory($directory)
        if(Test-Path -LiteralPath $Path){
            $item=Get-Item -LiteralPath $Path -Force
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Claude defaults must be regular files.'}
        }
        $temporary=Join-Path $directory ('.claude-deck-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($false))
            if(Test-Path -LiteralPath $Path){$backup=$Path+'.bak-deck-'+[guid]::NewGuid().ToString('N');[IO.File]::Replace($temporary,$Path,$backup)}
            else{[IO.File]::Move($temporary,$Path)}
        }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
    }.GetNewClosure()
    $validateSettings={
        param($Settings)
        if(-not $Settings.PSObject.Properties['env']){return}
        $environment=$Settings.env
        if(-not ($environment -is [System.Management.Automation.PSCustomObject] -or $environment -is [Collections.IDictionary])){throw 'Claude global defaults env must be a JSON object.'}
        foreach($property in $environment.PSObject.Properties){
            if($property.Name -match '(?i)(API.?KEY|AUTH.?TOKEN|OAUTH.?TOKEN|ACCESS.?TOKEN|REFRESH.?TOKEN|SECRET|PRIVATE.?KEY|ACCESS.?KEY|PASSWORD|CREDENTIAL|SESSION.?TOKEN|BEARER.?TOKEN|(^|_)TOKEN($|_))' -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){
                throw "Claude global defaults cannot store credentials in env.$($property.Name). Put credentials in the individual Claude account instead."
            }
        }
    }.GetNewClosure()
    $saveInstructions.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $instructionsPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($instructionsPath)}else{''}
            if($currentExists -ne [bool]$state.InstructionsExists -or ($currentExists -and $current -cne $state.InstructionsText)){throw 'Claude global instructions changed in another editor. Reopen before saving.'}
            if($instructionsEditor.Text -cne $state.InstructionsText){& $writeText $instructionsPath $instructionsEditor.Text;$state.InstructionsExists=$true;$state.InstructionsText=$instructionsEditor.Text}
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $saveSettings.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $settingsPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($settingsPath)}else{''}
            if($currentExists -ne [bool]$state.SettingsExists -or ($currentExists -and $current -cne $state.SettingsText)){throw 'Claude global settings changed in another editor. Reopen before saving.'}
            $value=$settingsEditor.Text | ConvertFrom-Json -ErrorAction Stop
            if(-not ($value -is [System.Management.Automation.PSCustomObject] -or $value -is [Collections.IDictionary])){throw 'Claude global settings defaults must be a JSON object.'}
            & $validateSettings $value
            $json=ConvertTo-Json -InputObject $value -Depth 100
            & $writeText $settingsPath $json
            $state.SettingsExists=$true;$state.SettingsText=$json
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Instructions=$instructionsEditor;Settings=$settingsEditor;SaveInstructions=$saveInstructions;SaveSettings=$saveSettings;Error=$errorText;Paths=@{Instructions=$instructionsPath;Settings=$settingsPath}}}
    [void]$dialog.ShowDialog()
}

function Open-DeckClaudeDefaults([string]$SuiteRoot,$Owner=$null) {
    $scriptPath=Join-Path $SuiteRoot 'Deck.ClaudeDefaults.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Claude defaults editor missing. Reinstall Codex Deck.'}
    if($Owner){return Show-DeckClaudeDefaults $SuiteRoot $Owner}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+$scriptPath+'" -ClaudeDefaultsEdit -ClaudeDefaultsSuiteRoot "'+$SuiteRoot+'"') | Out-Null
}

if($ClaudeDefaultsEdit){Show-DeckClaudeDefaults $ClaudeDefaultsSuiteRoot}
