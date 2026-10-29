param(
    [switch]$AntigravityDefaultsEdit,
    [string]$AntigravityDefaultsSuiteRoot=$PSScriptRoot
)

function Get-DeckAntigravityDefaultsPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/antigravity/default-settings.json'
}

function Get-DeckAntigravityGlobalRulesPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/antigravity/global-rules.md'
}

function Test-DeckAntigravityJsonObject($Value) {
    return $Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [Collections.IDictionary]
}

function Read-DeckAntigravityJsonFile([string]$Path,[string]$Label) {
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{}}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "$Label must be a regular file."}
    try{$value=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop}catch{throw "$Label contains invalid JSON: $($_.Exception.Message)"}
    if(-not (Test-DeckAntigravityJsonObject $value)){throw "$Label must contain a JSON object."}
    return $value
}

function Assert-DeckAntigravityNoSecrets($Value,[string]$Path='settings') {
    if(Test-DeckAntigravityJsonObject $Value){
        foreach($property in $Value.PSObject.Properties){
            if($property.Name -match '(?i)(API.?KEY|AUTH.?TOKEN|OAUTH.?TOKEN|ACCESS.?TOKEN|REFRESH.?TOKEN|SECRET|PRIVATE.?KEY|PASSWORD|CREDENTIAL|BEARER.?TOKEN|(^|_)TOKEN($|_))' -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){
                throw "Antigravity global defaults cannot store credentials at $Path.$($property.Name). Put credentials in the individual account or Windows credential store instead."
            }
            Assert-DeckAntigravityNoSecrets $property.Value ($Path+'.'+$property.Name)
        }
    }elseif($Value -is [array]){
        for($i=0;$i -lt $Value.Count;$i++){Assert-DeckAntigravityNoSecrets $Value[$i] ($Path+'['+$i+']')}
    }
}

function Merge-DeckAntigravitySettings($Base,$Override) {
    if((Test-DeckAntigravityJsonObject $Base) -and (Test-DeckAntigravityJsonObject $Override)){
        $merged=[ordered]@{}
        foreach($property in $Base.PSObject.Properties){
            $overrideProperty=$Override.PSObject.Properties[$property.Name]
            if($overrideProperty){$merged[$property.Name]=Merge-DeckAntigravitySettings $property.Value $overrideProperty.Value}
            else{$merged[$property.Name]=$property.Value}
        }
        foreach($property in $Override.PSObject.Properties){if(-not $Base.PSObject.Properties[$property.Name]){$merged[$property.Name]=$property.Value}}
        return [pscustomobject]$merged
    }
    return $Override
}

function ConvertTo-DeckAntigravityJson([object]$Value) {
    return ConvertTo-Json -InputObject $Value -Compress -Depth 100
}

function Write-DeckAntigravityFile([string]$Path,[string]$Text,[string]$Label) {
    $directory=Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    if(Test-Path -LiteralPath $Path){
        $item=Get-Item -LiteralPath $Path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "$Label must be a regular file."}
    }
    $temporary=Join-Path $directory ('.antigravity-deck-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path){$backup=$Path+'.bak-deck-'+[guid]::NewGuid().ToString('N');[IO.File]::Replace($temporary,$Path,$backup)}
        else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}

function Get-DeckAntigravityEffectiveOverrides($Current,$LastApplied,$Overrides) {
    $result=[ordered]@{}
    foreach($property in $Overrides.PSObject.Properties){$result[$property.Name]=$property.Value}
    foreach($property in $Current.PSObject.Properties){
        $old=$LastApplied.PSObject.Properties[$property.Name]
        if(-not $old -or (ConvertTo-DeckAntigravityJson $old.Value) -cne (ConvertTo-DeckAntigravityJson $property.Value)){$result[$property.Name]=$property.Value}
    }
    foreach($property in $LastApplied.PSObject.Properties){
        if(-not $Current.PSObject.Properties[$property.Name]){$result.Remove($property.Name)}
    }
    return [pscustomobject]$result
}

function Sync-DeckAntigravityProfile([string]$SuiteRoot,[string]$Account) {
    $identity=Get-DeckAccountIdentity $SuiteRoot $Account
    if($identity.Harness -ne 'Antigravity' -or -not (Test-DeckAntigravityFileAccount $identity)){return}
    $accountDirectory=Get-DeckEntryDirectory $SuiteRoot $Account
    $profile=Join-Path $accountDirectory 'antigravity/profile'
    $gemini=Join-Path $profile '.gemini'
    foreach($path in @($profile,$gemini)){Assert-DeckHarnessPath $accountDirectory $path}

    $rulesSource=Get-DeckAntigravityGlobalRulesPath $SuiteRoot
    $rulesTarget=Join-Path $gemini 'antigravity-cli/rules/codexdeck-global.md'
    Assert-DeckHarnessPath $accountDirectory $rulesTarget
    $rules=if(Test-Path -LiteralPath $rulesSource -PathType Leaf){[IO.File]::ReadAllText($rulesSource).Trim()}else{''}
    if($rules){
        $renderedRules="---`ntrigger: always_on`ndescription: Shared Codex Deck instructions for isolated Antigravity accounts.`n---`n`n"+$rules+"`n"
        if([Text.Encoding]::UTF8.GetByteCount($renderedRules) -gt 24000){throw 'The generated Antigravity global rule must stay within the documented 24,000-byte file limit.'}
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $rulesTarget))
        Write-DeckAntigravityFile $rulesTarget $renderedRules 'Antigravity global rules'
    }elseif(Test-Path -LiteralPath $rulesTarget -PathType Leaf){
        $item=Get-Item -LiteralPath $rulesTarget -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Antigravity global rule target must be a regular file.'}
        [IO.File]::Delete($rulesTarget)
    }

    $settingsPath=Get-DeckHarnessConfigPath $SuiteRoot $Account
    $overridesPath=Join-Path $accountDirectory 'antigravity/account-settings.json'
    $statePath=Join-Path $accountDirectory 'antigravity/deck-settings-state.json'
    foreach($path in @($settingsPath,$overridesPath,$statePath)){Assert-DeckHarnessPath $accountDirectory $path}
    $current=Read-DeckAntigravityJsonFile $settingsPath 'Antigravity account settings'
    $overrides=Read-DeckAntigravityJsonFile $overridesPath 'Antigravity account setting overrides'
    $state=Read-DeckAntigravityJsonFile $statePath 'Antigravity settings sync state'
    $lastApplied=$state.LastEffective
    if($lastApplied -and (Test-DeckAntigravityJsonObject $lastApplied)){$overrides=Get-DeckAntigravityEffectiveOverrides $current $lastApplied $overrides}
    elseif(@($current.PSObject.Properties).Count -and -not @($overrides.PSObject.Properties).Count){$overrides=$current}
    $defaults=Read-DeckAntigravityJsonFile (Get-DeckAntigravityDefaultsPath $SuiteRoot) 'Antigravity global settings defaults'
    $defaults.PSObject.Properties.Remove('modelProvider')
    $overrides.PSObject.Properties.Remove('modelProvider')
    Assert-DeckAntigravityNoSecrets $defaults
    $effective=Merge-DeckAntigravitySettings $defaults $overrides
    $json=ConvertTo-Json -InputObject $effective -Depth 100
    $oldJson=if(Test-Path -LiteralPath $settingsPath -PathType Leaf){[IO.File]::ReadAllText($settingsPath).Trim()}else{''}
    if($oldJson -cne $json.Trim()){Write-DeckAntigravityFile $settingsPath $json 'Antigravity account settings'}
    Write-DeckAntigravityFile $overridesPath (ConvertTo-Json -InputObject $overrides -Depth 100) 'Antigravity account setting overrides'
    Write-DeckAntigravityFile $statePath (ConvertTo-Json -InputObject @{LastEffective=$effective} -Depth 100) 'Antigravity settings sync state'
}

function Show-DeckAntigravityDefaults([string]$SuiteRoot,$Owner=$null,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    $rulesPath=Get-DeckAntigravityGlobalRulesPath $SuiteRoot
    $settingsPath=Get-DeckAntigravityDefaultsPath $SuiteRoot
    $initialRules=if(Test-Path -LiteralPath $rulesPath -PathType Leaf){[IO.File]::ReadAllText($rulesPath)}else{''}
    $initialSettings=Read-DeckAntigravityJsonFile $settingsPath 'Antigravity global settings defaults'
    $initialSettingsText=ConvertTo-Json -InputObject $initialSettings -Depth 100
    $state=@{
        RulesExists=Test-Path -LiteralPath $rulesPath -PathType Leaf
        RulesText=$initialRules
        SettingsExists=Test-Path -LiteralPath $settingsPath -PathType Leaf
        SettingsText=if(Test-Path -LiteralPath $settingsPath -PathType Leaf){[IO.File]::ReadAllText($settingsPath)}else{''}
    }
    $dialog=[Windows.Window]::new();$dialog.Title='Codex Deck / Antigravity Global Defaults';$dialog.Width=820;$dialog.Height=650;$dialog.MinWidth=640;$dialog.MinHeight=460
    $dialog.Background='#101315';$dialog.Foreground='#EAF0FA';$dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='Applies to isolated Antigravity accounts created by Deck. Rules are copied into each profile as a native always-on Antigravity rule. Settings defaults are merged under account-specific settings on the next launch. This is separate from Codex Global Rules and Claude Global Defaults. Do not store credentials here.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $buttons=[Windows.Controls.WrapPanel]::new();$buttons.HorizontalAlignment='Right';$buttons.Margin='0,12,0,0';[Windows.Controls.DockPanel]::SetDock($buttons,'Bottom');[void]$dock.Children.Add($buttons)
    $saveRules=[Windows.Controls.Button]::new();$saveRules.Content='Save global rules';$saveRules.Padding='12,8';$saveRules.Margin='0,0,8,0';[void]$buttons.Children.Add($saveRules)
    $saveSettings=[Windows.Controls.Button]::new();$saveSettings.Content='Save settings defaults';$saveSettings.Padding='12,8';[void]$buttons.Children.Add($saveSettings)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap';$errorText.Margin='0,0,0,8';[Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $tabs=[Windows.Controls.TabControl]::new();[void]$dock.Children.Add($tabs)
    $rulesTab=[Windows.Controls.TabItem]::new();$rulesTab.Header='Global rules'
    $rulesEditor=[Windows.Controls.TextBox]::new();$rulesEditor.Text=$initialRules;$rulesEditor.AcceptsReturn=$true;$rulesEditor.AcceptsTab=$true;$rulesEditor.TextWrapping='Wrap';$rulesEditor.VerticalScrollBarVisibility='Auto';$rulesEditor.HorizontalScrollBarVisibility='Auto';$rulesEditor.FontFamily='Consolas';$rulesEditor.FontSize=14;$rulesEditor.Background='#192232';$rulesEditor.Foreground='#EAF0FA';$rulesTab.Content=$rulesEditor;[void]$tabs.Items.Add($rulesTab)
    $settingsTab=[Windows.Controls.TabItem]::new();$settingsTab.Header='Settings defaults'
    $settingsEditor=[Windows.Controls.TextBox]::new();$settingsEditor.Text=$initialSettingsText;$settingsEditor.AcceptsReturn=$true;$settingsEditor.AcceptsTab=$true;$settingsEditor.TextWrapping='NoWrap';$settingsEditor.VerticalScrollBarVisibility='Auto';$settingsEditor.HorizontalScrollBarVisibility='Auto';$settingsEditor.FontFamily='Consolas';$settingsEditor.FontSize=14;$settingsEditor.Background='#192232';$settingsEditor.Foreground='#EAF0FA';$settingsTab.Content=$settingsEditor;[void]$tabs.Items.Add($settingsTab)
    $write={param([string]$Path,[string]$Text,[string]$Label) Write-DeckAntigravityFile $Path $Text $Label}.GetNewClosure()
    $saveRules.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $rulesPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($rulesPath)}else{''}
            if($currentExists -ne [bool]$state.RulesExists -or ($currentExists -and $current -cne $state.RulesText)){throw 'Antigravity global rules changed in another editor. Reopen before saving.'}
            $header="---`ntrigger: always_on`ndescription: Shared Codex Deck instructions for isolated Antigravity accounts.`n---`n`n"
            if([Text.Encoding]::UTF8.GetByteCount($header+$rulesEditor.Text+"`n") -gt 24000){throw 'Antigravity global rules must stay within the documented 24,000-byte file limit.'}
            if($rulesEditor.Text -cne $state.RulesText){& $write $rulesPath $rulesEditor.Text 'Antigravity global rules';$state.RulesExists=$true;$state.RulesText=$rulesEditor.Text}
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $saveSettings.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $settingsPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($settingsPath)}else{''}
            if($currentExists -ne [bool]$state.SettingsExists -or ($currentExists -and $current -cne $state.SettingsText)){throw 'Antigravity global settings defaults changed in another editor. Reopen before saving.'}
            $value=$settingsEditor.Text | ConvertFrom-Json -ErrorAction Stop
            if(-not (Test-DeckAntigravityJsonObject $value)){throw 'Antigravity global settings defaults must be a JSON object.'}
            Assert-DeckAntigravityNoSecrets $value
            $json=ConvertTo-Json -InputObject $value -Depth 100
            & $write $settingsPath $json 'Antigravity global settings defaults'
            $state.SettingsExists=$true;$state.SettingsText=$json
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Rules=$rulesEditor;Settings=$settingsEditor;SaveRules=$saveRules;SaveSettings=$saveSettings;Error=$errorText;Paths=@{Rules=$rulesPath;Settings=$settingsPath}}}
    [void]$dialog.ShowDialog()
}

function Open-DeckAntigravityDefaults([string]$SuiteRoot,$Owner=$null) {
    $scriptPath=Join-Path $SuiteRoot 'Deck.AntigravityDefaults.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Antigravity defaults editor missing. Reinstall Codex Deck.'}
    if($Owner){return Show-DeckAntigravityDefaults $SuiteRoot $Owner}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+$scriptPath+'" -AntigravityDefaultsEdit -AntigravityDefaultsSuiteRoot "'+$SuiteRoot+'"') | Out-Null
}

if($AntigravityDefaultsEdit){Show-DeckAntigravityDefaults $AntigravityDefaultsSuiteRoot}
