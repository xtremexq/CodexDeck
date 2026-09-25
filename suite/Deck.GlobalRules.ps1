param([switch]$Edit,[string]$SuiteRoot=$PSScriptRoot)
function Get-DeckDefaultGlobalRuleBase([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'Deck.DefaultGlobalRules.md'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Default Global Rules are missing. Reinstall Codex Deck.'}
    return [IO.File]::ReadAllText($path).Trim()
}
function Get-DeckGlobalRuleText([string]$SuiteRoot,[string]$AccountDirectory) {
    $path=Join-Path $SuiteRoot 'deck/global-rules.md'
    $base=Get-DeckDefaultGlobalRuleBase $SuiteRoot
    $hasSaved=Test-Path -LiteralPath $path -PathType Leaf
    $raw=if($hasSaved){[IO.File]::ReadAllText($path).Trim()}else{$base}
    $normalized=$raw -replace "`r`n","`n"
    $oldBase='Usage efficiency: Except when more context or feedback is genuinely needed to understand the task, avoid unnecessary model/tool round trips. Batch independent read-only checks, related edits, and proportionate verification into coherent passes. Do not repeatedly alternate tiny command, inspection, edit, and test steps when a safe batch is possible.'
    $oldDebug='Debug swarms: Use the debug-swarm skill only when the user explicitly requests a debug swarm or parallel independent Codex CLI workers; never infer it because parallel work could help. Follow its account, foreground/background, isolation, evidence, and reporting rules.'
    $oldBrowser='Browser Harness: For browser automation or live browser debugging, use the installed Browser Harness. Run `harness` to start its local services, `harness status` to verify them, and `browser-harness --doctor` when the CLI or browser connection needs diagnosis.'
    $debug='Debug swarms: Use the debug-swarm skill only when the user explicitly requests a debug swarm or parallel independent Codex CLI workers; never infer it because parallel work could help. Follow its account, foreground/background, isolation, evidence, and reporting rules.'
    $browser='Browser Harness: For authenticated browser automation or live browser debugging (when credentials/access are needed), use the installed Browser Harness. Run `harness` to start its local services, `harness status` to verify them, and `browser-harness --doctor` when the CLI or browser connection needs diagnosis.'
    $stock=-not $hasSaved
    if($hasSaved){
        foreach($candidateBase in @(@($oldBase,$base) | Select-Object -Unique)){
            foreach($legacy in @($candidateBase,(@($candidateBase,$oldDebug) -join "`n`n"),(@($candidateBase,$oldBrowser) -join "`n`n"),(@($candidateBase,$browser) -join "`n`n"),(@($candidateBase,$oldDebug,$oldBrowser) -join "`n`n"),(@($candidateBase,$oldDebug,$browser) -join "`n`n"),(@($candidateBase,$browser,$oldDebug) -join "`n`n"))){
                if($normalized -ceq $legacy){$stock=$true;break}
            }
            if($stock){break}
        }
    }
    if(-not $stock){return $raw}
    $sections=@($base)
    if($AccountDirectory -and (Test-Path -LiteralPath (Join-Path $AccountDirectory 'skills/debug-swarm/SKILL.md') -PathType Leaf)){$sections+=$debug}
    if($AccountDirectory -and (Test-Path -LiteralPath (Join-Path $AccountDirectory 'skills/browser-harness/SKILL.md') -PathType Leaf)){$sections+=$browser}
    return $sections -join "`n`n"
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
    $original=Get-DeckGlobalRuleText $SuiteRoot ''
    $originalExists=Test-Path -LiteralPath $path -PathType Leaf
    $originalFileText=if($originalExists){[IO.File]::ReadAllText($path)}else{''}
    $dialog=[Windows.Window]::new(); $dialog.Title='Codex Deck / Global Rules'; $dialog.Width=720; $dialog.Height=520
    $dialog.Background='#101315'; $dialog.Foreground='#EAF0FA'; $dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='Applies to Deck and codex-auth conversations. Leave blank to disable all Global Rules.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12'
    [Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $save=[Windows.Controls.Button]::new();$save.Content='Save rules';$save.Padding='12,8';$save.Margin='0,12,0,0'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom');[void]$dock.Children.Add($save)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap'
    [Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $editor=[Windows.Controls.TextBox]::new();$editor.Text=$original;$editor.AcceptsReturn=$true;$editor.AcceptsTab=$true;$editor.TextWrapping='Wrap';$editor.VerticalScrollBarVisibility='Auto';$editor.FontFamily='Consolas';$editor.FontSize=14;$editor.Background='#192232';$editor.Foreground='#EAF0FA';[void]$dock.Children.Add($editor)
    $save.Add_Click({
        try{
            $currentExists=Test-Path -LiteralPath $path -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($path)}else{''}
            if($currentExists -ne $originalExists -or $current -cne $originalFileText){throw 'Rules changed in another editor. Reopen this editor before saving.'}
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
