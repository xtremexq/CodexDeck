param([switch]$Edit,[string]$SuiteRoot=$PSScriptRoot)
function Get-DeckGlobalRuleArguments([string]$SuiteRoot,[string]$AccountDirectory,[string[]]$Arguments) {
    $rulesPath=Join-Path $SuiteRoot 'deck/global-rules.md'
    if(-not (Test-Path -LiteralPath $rulesPath) -or [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($rulesPath))){return}
    $command=Get-Command codex -ErrorAction Stop
    $prefix=@(); $executable=$command.Source
    if([IO.Path]::GetExtension($executable) -ne '.exe'){
        $entry=Join-Path (Split-Path -Parent $executable) 'node_modules/@openai/codex/bin/codex.js'
        if(-not (Test-Path -LiteralPath $entry)){throw 'Global Rules requires the native Codex executable or official npm installation on PATH.'}
        $executable=(Get-Command node.exe -ErrorAction Stop).Source; $prefix=@($entry)
    }
    $request=@{rulesPath=$rulesPath;executable=$executable;prefix=@($prefix);args=@($Arguments);cwd=(Get-Location).Path;codexHome=$AccountDirectory}
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
    $original=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{''}
    $dialog=[Windows.Window]::new(); $dialog.Title='Codex Deck / Global Rules'; $dialog.Width=720; $dialog.Height=520
    $dialog.Background='#101315'; $dialog.Foreground='#EAF0FA'; $dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='Applies to conversations launched through Deck or codex-auth, with any account or pool, in any folder. Leave blank to disable.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12'
    [Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $save=[Windows.Controls.Button]::new();$save.Content='Save rules';$save.Padding='12,8';$save.Margin='0,12,0,0'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom');[void]$dock.Children.Add($save)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap'
    [Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $editor=[Windows.Controls.TextBox]::new();$editor.Text=$original;$editor.AcceptsReturn=$true;$editor.AcceptsTab=$true;$editor.TextWrapping='Wrap';$editor.VerticalScrollBarVisibility='Auto';$editor.FontFamily='Consolas';$editor.FontSize=14;$editor.Background='#192232';$editor.Foreground='#EAF0FA';[void]$dock.Children.Add($editor)
    $save.Add_Click({
        try{
            $current=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{''}
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
