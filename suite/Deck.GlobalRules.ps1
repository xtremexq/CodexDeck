param([switch]$Edit,[string]$SuiteRoot=$PSScriptRoot)
function Get-DeckDefaultGlobalRuleBase([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'Deck.DefaultGlobalRules.md'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Default Global Rules are missing. Reinstall Codex Deck.'}
    return [IO.File]::ReadAllText($path).Trim()
}
function Get-DeckGlobalRuleText([string]$SuiteRoot,[string]$AccountDirectory) {
    $path=Join-Path $SuiteRoot 'deck/global-rules.md'
    $base=Get-DeckDefaultGlobalRuleBase $SuiteRoot
    $debug='Debug swarms: Use the debug-swarm skill only when the user explicitly requests a debug swarm or parallel independent Codex CLI workers; never infer it because parallel work could help. Follow its account, foreground/background, isolation, evidence, and reporting rules.'
    $browser='Browser Harness: For browser automation or live browser debugging, use the installed Browser Harness. Run `harness` to start its local services, `harness status` to verify them, and `browser-harness --doctor` when the CLI or browser connection needs diagnosis.'
    $raw=if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::ReadAllText($path).Trim()}else{$base}
    $normalized=$raw -replace "`r`n","`n"
    foreach($legacy in @($base,(@($base,$debug) -join "`n`n"),(@($base,$browser) -join "`n`n"),(@($base,$debug,$browser) -join "`n`n"))){
        if($normalized -ceq ($legacy -replace "`r`n","`n")){$raw=$base;break}
    }
    if(-not $raw){return ''}
    if($AccountDirectory -and (Test-Path -LiteralPath (Join-Path $AccountDirectory 'skills/debug-swarm/SKILL.md') -PathType Leaf)){$raw+="`n`n"+$debug}
    $settings=if(Get-Command Get-DeckSettings -ErrorAction SilentlyContinue){Get-DeckSettings (Join-Path $SuiteRoot 'deck')}else{$null}
    if($AccountDirectory -and $settings -and $settings.BrowserHarnessEnabled -and
       (Test-Path -LiteralPath (Join-Path $AccountDirectory 'skills/browser-harness/SKILL.md') -PathType Leaf) -and
       (Get-Command Get-DeckIntegrationStatus -ErrorAction SilentlyContinue) -and (Get-DeckIntegrationStatus $SuiteRoot browser_harness).Valid){
        if(Get-Command harness -ErrorAction SilentlyContinue){$raw+="`n`n"+$browser}
        else{$raw+="`n`nBrowser Harness: For browser automation or live browser debugging, use the installed Browser Harness. Use ``browser-harness --doctor`` when the CLI or browser connection needs diagnosis."}
    }
    return $raw
}
function Get-DeckGlobalRuleArguments([string]$SuiteRoot,[string]$AccountDirectory,[string[]]$Arguments,[string[]]$AdditionalSections=@()) {
    $rulesPath=Join-Path $SuiteRoot 'deck/global-rules.md'
    $rulesText=Get-DeckGlobalRuleText $SuiteRoot $AccountDirectory
    $hasRules=-not [string]::IsNullOrWhiteSpace($rulesText)
    if(-not $hasRules -and -not @($AdditionalSections | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}).Count){return}
    $command=Get-Command codex -ErrorAction Stop
    $prefix=@(); $executable=$command.Source
    if([IO.Path]::GetExtension($executable) -ne '.exe'){
        $entry=Join-Path (Split-Path -Parent $executable) 'node_modules/@openai/codex/bin/codex.js'
        if(-not (Test-Path -LiteralPath $entry)){throw 'Global Rules requires the native Codex executable or official npm installation on PATH.'}
        $executable=(Get-Command node.exe -ErrorAction Stop).Source; $prefix=@($entry)
    }
    $request=@{rulesPath=$rulesPath;rulesText=$rulesText;sections=@($AdditionalSections | Where-Object {-not [string]::IsNullOrWhiteSpace($_)});executable=$executable;prefix=@($prefix);args=@($Arguments);cwd=(Get-Location).Path;codexHome=$AccountDirectory}
    $previousEncoding=$OutputEncoding
    try {
        $OutputEncoding=[Text.UTF8Encoding]::new($false)
        $result=($request | ConvertTo-Json -Compress -Depth 5) | & node.exe (Join-Path $SuiteRoot 'Deck.GlobalRules.cjs')
        if($LASTEXITCODE -ne 0){throw 'Global Rules could not be loaded; launch stopped so your instructions are not silently omitted.'}
        @((($result -join "`n") | ConvertFrom-Json))
    } finally {$OutputEncoding=$previousEncoding}
}
function Show-DeckGlobalRules([string]$SuiteRoot,$Owner=$null,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    $path=Join-Path $SuiteRoot 'deck/global-rules.md'
    $original=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{Get-DeckDefaultGlobalRuleBase $SuiteRoot}
    $dialog=[Windows.Window]::new(); $dialog.Title='Codex Deck / Global Rules'; $dialog.Width=720; $dialog.Height=520
    $dialog.Background='#101315'; $dialog.Foreground='#EAF0FA'; $dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='Applies to Deck and codex-auth conversations. Debug Swarm and Browser Harness rules are added only when enabled and available for the account. Leave blank to disable all Global Rules.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12'
    [Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $save=[Windows.Controls.Button]::new();$save.Content='Save rules';$save.Padding='12,8';$save.Margin='0,12,0,0'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom');[void]$dock.Children.Add($save)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap'
    [Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $editor=[Windows.Controls.TextBox]::new();$editor.Text=$original;$editor.AcceptsReturn=$true;$editor.AcceptsTab=$true;$editor.TextWrapping='Wrap';$editor.VerticalScrollBarVisibility='Auto';$editor.FontFamily='Consolas';$editor.FontSize=14;$editor.Background='#192232';$editor.Foreground='#EAF0FA';[void]$dock.Children.Add($editor)
    $save.Add_Click({
        try{
            $current=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{Get-DeckDefaultGlobalRuleBase $SuiteRoot}
            if($current -cne $original){throw 'Rules changed in another editor. Reopen this editor before saving.'}
            if($editor.Text -cne $original){
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination ($path+'.bak-deck-'+[guid]::NewGuid().ToString('N'))}
                [IO.File]::WriteAllText($path,$editor.Text,[Text.UTF8Encoding]::new($false))
            }
            $dialog.Close()
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Editor=$editor;Save=$save;Error=$errorText}}
    [void]$dialog.ShowDialog()
}
function Open-DeckGlobalRules([string]$SuiteRoot){
    $scriptPath=Join-Path $SuiteRoot 'Deck.GlobalRules.ps1'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+$scriptPath+'" -Edit -SuiteRoot "'+$SuiteRoot+'"') | Out-Null
}
if($Edit){Show-DeckGlobalRules $SuiteRoot}
