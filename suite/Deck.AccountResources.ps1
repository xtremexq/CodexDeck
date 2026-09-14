param(
    [switch]$DeckInstructionsEdit,
    [string]$DeckInstructionsSuiteRoot=$PSScriptRoot,
    [string]$DeckInstructionsAccount
)

function Import-DeckEnvironmentCommands([string]$SuiteRoot) {
    if(-not (Get-Command Get-DeckEntryDirectory -ErrorAction SilentlyContinue)){
        . (Join-Path $SuiteRoot 'Deck.Environments.ps1')
    }
}

function Get-DeckAccountInstructionsPath([string]$SuiteRoot,[string]$Account) {
    Import-DeckEnvironmentCommands $SuiteRoot
    $accountDirectory=Get-DeckEntryDirectory $SuiteRoot $Account
    $path=Join-Path $accountDirectory 'AGENTS.md'
    if(Test-Path -LiteralPath $path){
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Expected AGENTS.md to be a regular file.'}
    }
    return $path
}

function Get-DeckSkillsDirectory([string]$SuiteRoot,[string]$Account,[switch]$Create) {
    Import-DeckEnvironmentCommands $SuiteRoot
    $accountDirectory=Get-DeckEntryDirectory $SuiteRoot $Account
    $path=Join-Path $accountDirectory 'skills'
    if(Test-Path -LiteralPath $path){
        $item=Get-Item -LiteralPath $path -Force
        if(-not $item.PSIsContainer){throw 'Expected the skills path to be a directory.'}
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
            $binding=@((Get-DeckSharing $SuiteRoot $Account).Bindings | Where-Object Resource -eq 'skills' | Select-Object -First 1)
            if(-not $binding.Count){throw 'The skills directory is an unexpected link.'}
            Assert-DeckResourceLink $SuiteRoot $accountDirectory $binding[0]
        }
    }elseif($Create){
        [void][IO.Directory]::CreateDirectory($path)
    }
    return $path
}

function Show-DeckAccountInstructions([string]$SuiteRoot,[string]$Account,$Owner=$null,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    $path=Get-DeckAccountInstructionsPath $SuiteRoot $Account
    $accountDirectory=Split-Path -Parent $path
    $exists=Test-Path -LiteralPath $path -PathType Leaf
    $original=if($exists){[IO.File]::ReadAllText($path)}else{''}
    $sharing=Get-DeckSharing $SuiteRoot $Account
    $binding=@($sharing.Bindings | Where-Object Resource -eq 'AGENTS.md' | Select-Object -First 1)
    $sharedSource=if($binding.Count){[string]$binding[0].Source}else{''}
    $overridePath=Join-Path $accountDirectory 'AGENTS.override.md'
    $overrideActive=(Test-Path -LiteralPath $overridePath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($overridePath))

    $dialog=[Windows.Window]::new();$dialog.Title="Codex Deck / $Account Instructions";$dialog.Width=760;$dialog.Height=550
    $dialog.Background='#101315';$dialog.Foreground='#EAF0FA';$dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new()
    if($sharedSource){
        $note.Text="$Account receives AGENTS.md from $sharedSource. This copy is read-only here; select $sharedSource in the dashboard to edit the source."
    }else{
        $note.Text="Global instructions for $Account in every working folder. Project and nested AGENTS.md files can add or override guidance. Changes load in new Codex sessions."
    }
    if($overrideActive){$note.Text+=' A non-empty AGENTS.override.md currently takes precedence over this file.'}
    $note.TextWrapping='Wrap';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)

    $save=[Windows.Controls.Button]::new();$save.Content='Save instructions';$save.Padding='12,8';$save.Margin='0,12,0,0';$save.IsEnabled=-not [bool]$sharedSource
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom');[void]$dock.Children.Add($save)
    $status=[Windows.Controls.TextBlock]::new();$status.Foreground='#9BB5D9';$status.TextWrapping='Wrap';$status.Margin='0,8,0,0'
    $status.Text=if($sharedSource){"Read-only shared copy from $sharedSource."}elseif($exists){'Loaded AGENTS.md.'}else{'AGENTS.md does not exist yet; save to create it.'}
    [Windows.Controls.DockPanel]::SetDock($status,'Bottom');[void]$dock.Children.Add($status)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap';$errorText.Margin='0,8,0,0'
    [Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $editor=[Windows.Controls.TextBox]::new();$editor.Text=$original;$editor.IsReadOnly=[bool]$sharedSource;$editor.AcceptsReturn=$true;$editor.AcceptsTab=$true;$editor.TextWrapping='Wrap';$editor.VerticalScrollBarVisibility='Auto';$editor.HorizontalScrollBarVisibility='Auto';$editor.FontFamily='Consolas';$editor.FontSize=14;$editor.Background='#192232';$editor.Foreground='#EAF0FA';[void]$dock.Children.Add($editor)

    $state=@{Exists=$exists;Text=$original}
    $save.Add_Click({
        try{
            $errorText.Text=''
            if($sharedSource){throw "Edit the source account, $sharedSource, instead."}
            $currentExists=Test-Path -LiteralPath $path -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($path)}else{''}
            if($currentExists -ne [bool]$state.Exists -or ($currentExists -and $current -cne $state.Text)){throw 'AGENTS.md changed in another editor. Reopen this editor before saving.'}
            if($editor.Text -ceq $state.Text){$status.Text='No changes to save.';return}
            $temporary=Join-Path $accountDirectory ('.AGENTS.'+[guid]::NewGuid().ToString('N')+'.tmp')
            try{
                [IO.File]::WriteAllText($temporary,$editor.Text,[Text.UTF8Encoding]::new($false))
                if($currentExists){
                    $backup=$path+'.bak-deck-'+[guid]::NewGuid().ToString('N')
                    [IO.File]::Replace($temporary,$path,$backup)
                }else{[IO.File]::Move($temporary,$path)}
            }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
            $state.Exists=$true;$state.Text=$editor.Text;$status.Text='Saved AGENTS.md. Start a new Codex session to load it.'
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $dialog.Add_Closing({param($sender,$eventArgs)
        if(-not $sharedSource -and $editor.Text -cne $state.Text){
            $discard=[Windows.MessageBox]::Show($dialog,'Close without saving these account instructions?','Codex Deck',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
            if($discard -ne [Windows.MessageBoxResult]::Yes){$eventArgs.Cancel=$true}
        }
    }.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Editor=$editor;Save=$save;Status=$status;Error=$errorText;Path=$path;SharedSource=$sharedSource;OverrideActive=$overrideActive}}
    [void]$dialog.ShowDialog()
}

function Open-DeckAccountInstructions([string]$SuiteRoot,[string]$Account) {
    [void](Get-DeckAccountInstructionsPath $SuiteRoot $Account)
    $scriptPath=Join-Path $SuiteRoot 'Deck.AccountResources.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Account instructions editor missing. Reinstall Codex Deck.'}
    $process=Start-DeckBackgroundPowerShell $scriptPath @('-DeckInstructionsEdit','-DeckInstructionsSuiteRoot',$SuiteRoot,'-DeckInstructionsAccount',$Account) -Sta
    $process.Dispose()
}

function Open-DeckSkillsFolder([string]$SuiteRoot,[string]$Account) {
    $path=Get-DeckSkillsDirectory $SuiteRoot $Account -Create
    Start-Process explorer.exe -ArgumentList ('"'+$path+'"') | Out-Null
}

if($DeckInstructionsEdit){Show-DeckAccountInstructions $DeckInstructionsSuiteRoot $DeckInstructionsAccount}
