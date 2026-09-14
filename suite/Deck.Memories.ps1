param([switch]$DeckMemoryEdit,[string]$DeckMemorySuiteRoot=$PSScriptRoot,[string]$DeckMemoryAccount)

function Get-DeckMemoryPath([string]$MemoryRoot,[string]$RelativePath) {
    if([string]::IsNullOrWhiteSpace($RelativePath)){throw 'Choose a memory file.'}
    $relative=$RelativePath.Trim().Replace('/','\')
    if([IO.Path]::IsPathRooted($relative)){throw 'Memory files must use a relative path.'}
    foreach($part in $relative.Split('\')){
        if([string]::IsNullOrWhiteSpace($part) -or $part -in @('.','..') -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            [IO.Path]::GetFileNameWithoutExtension($part) -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$'){throw 'Invalid memory file path.'}
    }
    if([IO.Path]::GetExtension($relative).ToLowerInvariant() -notin @('.md','.txt','.json','.jsonl','.yaml','.yml','.toml')){
        throw 'Choose a Markdown, text, JSON, YAML or TOML memory file.'
    }
    $root=[IO.Path]::GetFullPath($MemoryRoot).TrimEnd('\')
    $path=[IO.Path]::GetFullPath((Join-Path $root $relative))
    if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Memory file escaped its account directory.'}
    $parent=Split-Path -Parent $path
    while($parent -and $parent -ne $root){
        if((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked folders inside memories are not supported.'}
        $parent=Split-Path -Parent $parent
    }
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked memory files are not supported.'}
    return $path
}

function Get-DeckMemoryFileNames([string]$MemoryRoot) {
    if(-not (Test-Path -LiteralPath $MemoryRoot -PathType Container)){return}
    $root=[IO.Path]::GetFullPath($MemoryRoot).TrimEnd('\')
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while($pending.Count){
        $directory=$pending.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if($item.PSIsContainer){$pending.Push($item.FullName);continue}
            if($item.Extension.ToLowerInvariant() -in @('.md','.txt','.json','.jsonl','.yaml','.yml','.toml')){
                $item.FullName.Substring($root.Length+1).Replace('\','/')
            }
        }
    }
}

function Show-DeckMemories([string]$SuiteRoot,[string]$Account,$Owner=$null,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    if(-not (Get-Command Get-DeckEntryDirectory -ErrorAction SilentlyContinue)){
        . (Join-Path $SuiteRoot 'Deck.Environments.ps1')
    }
    $accountDirectory=Get-DeckEntryDirectory $SuiteRoot $Account
    $memoryRoot=Join-Path $accountDirectory 'memories'
    if(Test-Path -LiteralPath $memoryRoot -PathType Leaf){throw 'Expected the memories path to be a directory.'}
    [void][IO.Directory]::CreateDirectory($memoryRoot)
    $shared=[bool]((Get-Item -LiteralPath $memoryRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)

    $dialog=[Windows.Window]::new();$dialog.Title="Codex Deck / $Account Memories";$dialog.Width=780;$dialog.Height=570
    $dialog.Background='#101315';$dialog.Foreground='#EAF0FA';$dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new()
    $note.Text=if($shared){"Memory files for $Account. This directory is shared; saved edits are live for its owner and every recipient."}else{"Memory files for $Account. Select a UTF-8 text file, or type a relative name to create one."}
    $note.TextWrapping='Wrap';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)

    $toolbar=[Windows.Controls.Grid]::new();$toolbar.Margin='0,0,0,12'
    foreach($width in @('*','Auto','Auto')){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$toolbar.ColumnDefinitions.Add($column)}
    $selector=[Windows.Controls.ComboBox]::new();$selector.IsEditable=$true;$selector.MinHeight=32;$selector.Margin='0,0,8,0';$selector.Background='#192232';$selector.Foreground='#EAF0FA'
    $names=@(Get-DeckMemoryFileNames $memoryRoot | Sort-Object)
    foreach($name in $names){[void]$selector.Items.Add($name)}
    $selector.Text=if($names.Count){$names[0]}else{'memory.md'}
    [void]$toolbar.Children.Add($selector)
    $open=[Windows.Controls.Button]::new();$open.Content='Open file';$open.Padding='12,7';$open.Margin='0,0,8,0';[Windows.Controls.Grid]::SetColumn($open,1);[void]$toolbar.Children.Add($open)
    $openFolder=[Windows.Controls.Button]::new();$openFolder.Content='Open folder';$openFolder.Padding='12,7';[Windows.Controls.Grid]::SetColumn($openFolder,2);[void]$toolbar.Children.Add($openFolder)
    [Windows.Controls.DockPanel]::SetDock($toolbar,'Top');[void]$dock.Children.Add($toolbar)

    $save=[Windows.Controls.Button]::new();$save.Content='Save file';$save.Padding='12,8';$save.Margin='0,12,0,0'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom');[void]$dock.Children.Add($save)
    $status=[Windows.Controls.TextBlock]::new();$status.Foreground='#9BB5D9';$status.TextWrapping='Wrap';$status.Margin='0,8,0,0'
    [Windows.Controls.DockPanel]::SetDock($status,'Bottom');[void]$dock.Children.Add($status)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap';$errorText.Margin='0,8,0,0'
    [Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $editor=[Windows.Controls.TextBox]::new();$editor.AcceptsReturn=$true;$editor.AcceptsTab=$true;$editor.TextWrapping='Wrap';$editor.VerticalScrollBarVisibility='Auto';$editor.HorizontalScrollBarVisibility='Auto';$editor.FontFamily='Consolas';$editor.FontSize=14;$editor.Background='#192232';$editor.Foreground='#EAF0FA';[void]$dock.Children.Add($editor)

    $state=@{Path=$null;Exists=$false;Text=''}
    $resolveMemoryPath=${function:Get-DeckMemoryPath}
    $loadFile={
        try{
            $errorText.Text=''
            if($state.Path -and $editor.Text -cne $state.Text){
                $discard=[Windows.MessageBox]::Show($dialog,'Discard unsaved changes and open another memory file?','Codex Deck',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
                if($discard -ne [Windows.MessageBoxResult]::Yes){return}
            }
            $path=& $resolveMemoryPath $memoryRoot $selector.Text
            $exists=Test-Path -LiteralPath $path -PathType Leaf
            if($exists -and (Get-Item -LiteralPath $path).Length -gt 2097152){throw 'Memory files larger than 2 MB must be opened in another editor.'}
            $text=if($exists){[IO.File]::ReadAllText($path)}else{''}
            $state.Path=$path;$state.Exists=$exists;$state.Text=$text;$editor.Text=$text
            $relative=$path.Substring($memoryRoot.TrimEnd('\').Length+1).Replace('\','/')
            $selector.Text=$relative
            $status.Text=if($exists){"Opened $relative"}else{"New file: $relative (save to create it)"}
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure()
    $open.Add_Click($loadFile)
    $openFolder.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+$memoryRoot+'"') | Out-Null}.GetNewClosure())
    $save.Add_Click({
        try{
            $errorText.Text=''
            $path=& $resolveMemoryPath $memoryRoot $selector.Text
            if(-not $state.Path -or $path -ne $state.Path){throw 'Open this file before saving it.'}
            $exists=Test-Path -LiteralPath $path -PathType Leaf
            $current=if($exists){[IO.File]::ReadAllText($path)}else{''}
            if($exists -ne [bool]$state.Exists -or ($exists -and $current -cne $state.Text)){throw 'This memory changed in another editor. Open it again before saving.'}
            $parent=Split-Path -Parent $path;[void][IO.Directory]::CreateDirectory($parent)
            [void](& $resolveMemoryPath $memoryRoot $selector.Text)
            $temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
            try{
                [IO.File]::WriteAllText($temporary,$editor.Text,[Text.UTF8Encoding]::new($false))
                if($exists){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
            }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
            $state.Exists=$true;$state.Text=$editor.Text
            $relative=$path.Substring($memoryRoot.TrimEnd('\').Length+1).Replace('\','/')
            if(-not $selector.Items.Contains($relative)){[void]$selector.Items.Add($relative)}
            $status.Text="Saved $relative"
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $dialog.Add_Closing({param($sender,$eventArgs)
        if($state.Path -and $editor.Text -cne $state.Text){
            $discard=[Windows.MessageBox]::Show($dialog,'Close without saving this memory file?','Codex Deck',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
            if($discard -ne [Windows.MessageBoxResult]::Yes){$eventArgs.Cancel=$true}
        }
    }.GetNewClosure())
    & $loadFile
    if($TestUI){return @{Dialog=$dialog;Selector=$selector;Editor=$editor;Open=$open;OpenFolder=$openFolder;Save=$save;Status=$status;Error=$errorText;MemoryRoot=$memoryRoot;Shared=$shared}}
    [void]$dialog.ShowDialog()
}

function Open-DeckMemories([string]$SuiteRoot,[string]$Account) {
    if($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){throw 'Choose an account or pool first.'}
    $scriptPath=Join-Path $SuiteRoot 'Deck.Memories.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Memories editor missing. Reinstall Codex Deck.'}
    $arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$scriptPath+'" -DeckMemoryEdit -DeckMemorySuiteRoot "'+$SuiteRoot+'" -DeckMemoryAccount '+$Account
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments | Out-Null
}

if($DeckMemoryEdit){Show-DeckMemories $DeckMemorySuiteRoot $DeckMemoryAccount}
