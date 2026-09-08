# Dot-sourced inside Show-DeckSettings so modal handlers share its lifetime.
$backupTab=[Windows.Controls.TabItem]::new(); $backupTab.Header='Backup'
$backupPanel=[Windows.Controls.StackPanel]::new(); $backupPanel.Margin='2,0,12,0'
$backupScroll=[Windows.Controls.ScrollViewer]::new(); $backupScroll.VerticalScrollBarVisibility='Auto'; $backupScroll.HorizontalScrollBarVisibility='Disabled'; $backupScroll.Content=$backupPanel; $backupTab.Content=$backupScroll; [void]$tabs.Items.Add($backupTab)
[void]$backupPanel.Children.Add((New-DeckText 'Your Deck, safely portable' '#EDF1F7' 18))
$help=New-DeckText 'Includes account sign-ins, account configs and instructions, shared defaults, preferences, pins and warm-up history. Excludes chats, caches, logs and plugins. Keep the password: it cannot be recovered.' '#929CA4'; $help.Margin='0,8,0,16'; [void]$backupPanel.Children.Add($help)
[void]$backupPanel.Children.Add((New-DeckText 'Backup file (.cdeck)'))
$backupPath=[Windows.Controls.TextBox]::new(); $backupPath.Text=Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('CodexDeck-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.cdeck'); $backupPath.Margin='0,6,0,12'; [void]$backupPanel.Children.Add($backupPath)
[void]$backupPanel.Children.Add((New-DeckText 'Password (at least 12 characters for export)'))
$password=[Windows.Controls.PasswordBox]::new(); $password.Margin='0,6,0,12'; [void]$backupPanel.Children.Add($password)
[void]$backupPanel.Children.Add((New-DeckText 'Repeat password for export'))
$repeat=[Windows.Controls.PasswordBox]::new(); $repeat.Margin='0,6,0,14'; [void]$backupPanel.Children.Add($repeat)
$restorePrefs=[Windows.Controls.CheckBox]::new(); $restorePrefs.Content='Also replace Deck preferences and shared defaults on import'; $restorePrefs.Margin='0,0,0,14'; [void]$backupPanel.Children.Add($restorePrefs)
$actions=[Windows.Controls.WrapPanel]::new(); [void]$backupPanel.Children.Add($actions)
$export=[Windows.Controls.Button]::new(); $export.Content='Export encrypted'; [void]$actions.Children.Add($export)
$inspect=[Windows.Controls.Button]::new(); $inspect.Content='Preview import'; [void]$actions.Children.Add($inspect)
$restore=[Windows.Controls.Button]::new(); $restore.Content='Restore accounts'; $restore.Visibility='Collapsed'; [void]$actions.Children.Add($restore)
$backupStatus=New-DeckText '' '#A9E8D5'; $backupStatus.Margin='0,12,0,0'; [void]$backupPanel.Children.Add($backupStatus)
$backupState=@{Manifest=$null}
$invalidate={ $backupState.Manifest=$null; $restore.Visibility='Collapsed' }
$backupPath.Add_TextChanged($invalidate); $password.Add_PasswordChanged($invalidate)
$export.Add_Click({
    try{
        if($password.Password -cne $repeat.Password){throw 'The passwords do not match.'}
        if([IO.Path]::GetExtension($backupPath.Text) -ne '.cdeck'){throw 'Use a .cdeck filename.'}
        Save-DeckView
        $count=Export-DeckBackup $suite (Join-Path $HOME '.codex/config.toml') $backupPath.Text $password.SecurePassword
        $backupStatus.Text="Exported $count accounts. AES-256-GCM / password protected."; $password.Clear(); $repeat.Clear()
    }catch{$backupStatus.Text=$_.Exception.Message}
})
$inspect.Add_Click({
    try{
        $backupState.Manifest=Read-DeckBackup $backupPath.Text $password.SecurePassword
        $names=@($backupState.Manifest.Accounts)
        $conflicts=@($names | Where-Object {Test-Path -LiteralPath (Join-Path $suite "accounts/$_")})
        if($conflicts.Count){throw ('Existing accounts would conflict: '+($conflicts -join ', ')+'. No changes made.')}
        $backupStatus.Text="Verified $($names.Count) accounts: $($names -join ', '). Restore adds these accounts; shared settings change only if selected above."
        $restore.Visibility='Visible'
    }catch{$backupState.Manifest=$null; $restore.Visibility='Collapsed'; $backupStatus.Text=$_.Exception.Message}
})
$restore.Add_Click({
    try{
        if(-not $backupState.Manifest){throw 'Preview the backup first.'}
        if($tasks.Count){throw 'Wait for active checks to finish before importing.'}
        $count=Import-DeckBackup $suite (Join-Path $HOME '.codex/config.toml') $backupState.Manifest -RestorePreferences:([bool]$restorePrefs.IsChecked)
        $backupState.Manifest=$null; $restore.Visibility='Collapsed'; $password.Clear(); $repeat.Clear()
        $script:pins=@(Read-DeckJson (Join-Path $root 'pins.json')); $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker; $script:lastRender=''; Render-Deck
        if($restorePrefs.IsChecked){
            $script:settings=Get-DeckSettings $root; $script:viewStates=@{}; $saved=Read-DeckJson (Join-Path $root 'views.json')
            foreach($mode in @('Panel','Widget')){if($saved.$mode){$viewStates[$mode]=$saved.$mode}}
            $script:history=@{}; foreach($entry in @(Read-DeckJson (Join-Path $root 'warmup.json'))){if($entry.Account){$history[$entry.Account]=$entry}}
            Set-DeckAppearance; Set-DeckMode $settings.ViewMode -Initial
        }
        $script:notice="Restored $count accounts"; $script:lastRender=''; Render-Deck; $dialog.Close()
    }catch{$backupStatus.Text=$_.Exception.Message}
})
$dialog.Add_Closed({$backupState.Manifest=$null; $password.Clear(); $repeat.Clear()}.GetNewClosure())
$aboutTab=[Windows.Controls.TabItem]::new(); $aboutTab.Header='About'; $about=[Windows.Controls.StackPanel]::new(); $about.Margin='4'; $aboutTab.Content=$about; [void]$tabs.Items.Add($aboutTab)
$logo=[Windows.Controls.Image]::new(); $logo.Source=$appIcon; $logo.Width=48; $logo.Height=48; $logo.HorizontalAlignment='Left'; $logo.Margin='0,0,0,14'; [void]$about.Children.Add($logo)
[void]$about.Children.Add((New-DeckText 'Codex Deck' '#EDF1F7' 24))
[void]$about.Children.Add((New-DeckText 'Development build · Windows' '#69DEC0'))
$aboutText=New-DeckText "Manage your Codex accounts in one place.`n`nCheck usage, switch accounts, and schedule warm-ups from the desktop or terminal." '#B5BEC7' 14; $aboutText.Margin='0,18,0,20'; [void]$about.Children.Add($aboutText)
[void]$about.Children.Add((New-DeckText 'Created by xtremexq · Open source · MIT license' '#929CA4'))
$links=[Windows.Controls.WrapPanel]::new(); $links.Margin='0,20,0,20'; [void]$about.Children.Add($links)
foreach($link in @(
    @{Title='GitHub';Url='https://github.com/xtremexq/CodexDeck'},
    @{Title='Releases';Url='https://github.com/xtremexq/CodexDeck/releases'},
    @{Title='Report an issue';Url='https://github.com/xtremexq/CodexDeck/issues'},
    @{Title='License';Url='https://github.com/xtremexq/CodexDeck/blob/main/LICENSE'}
)){
    $button=[Windows.Controls.Button]::new(); $button.Content=$link.Title; $button.Tag=$link.Url
    $button.Add_Click({param($sender,$eventArgs) Start-Process ([string]$sender.Tag)})
    [void]$links.Children.Add($button)
}
[void]$about.Children.Add((New-DeckText 'An independent companion for OpenAI Codex. Not affiliated with or endorsed by OpenAI.' '#737E89'))
