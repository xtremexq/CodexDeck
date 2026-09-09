# Dot-sourced in the Settings dialog. Actions apply independently of general preferences.
. (Join-Path $suite 'Deck.Terminal.ps1')
$environmentTab=[Windows.Controls.TabItem]::new(); $environmentTab.Header='Environments'
$environmentPanel=[Windows.Controls.StackPanel]::new(); $environmentPanel.Margin='2,0,12,0'
$environmentScroll=[Windows.Controls.ScrollViewer]::new(); $environmentScroll.VerticalScrollBarVisibility='Auto'; $environmentScroll.Content=$environmentPanel
$environmentTab.Content=$environmentScroll; [void]$tabs.Items.Add($environmentTab)
[void]$environmentPanel.Children.Add((New-DeckText 'Isolated by default. Share by choice.' '#EDF1F7' 18))
$environmentHelp=New-DeckText 'A pool owns its own tools, memory and chats while using member account quota. Sharing below is separate: choose exactly which resources other entries receive. Close recipient terminals before applying changes.' '#929CA4'
$environmentHelp.Margin='0,8,0,16'; [void]$environmentPanel.Children.Add($environmentHelp)
function Add-DeckEnvironmentLabel([string]$Text) { $label=New-DeckText $Text; $label.Margin='0,10,0,5'; [void]$environmentPanel.Children.Add($label) }
Add-DeckEnvironmentLabel 'Pooled environment name'
$poolNameBox=[Windows.Controls.TextBox]::new(); $poolNameBox.Text='pool'; [void]$environmentPanel.Children.Add($poolNameBox)
$poolAll=[Windows.Controls.CheckBox]::new(); $poolAll.Content='Use all signed-in accounts (including future accounts)'; $poolAll.IsChecked=$true; $poolAll.Margin='0,10,0,6'; [void]$environmentPanel.Children.Add($poolAll)
$poolMemberList=[Windows.Controls.ListBox]::new(); $poolMemberList.SelectionMode='Multiple'; $poolMemberList.Height=110; [void]$environmentPanel.Children.Add($poolMemberList)
$environmentNames=if($SmokeTest){@('pool','account1','account2')}else{@(Get-DeckEntryNames $suite)}
$environmentCache=Get-DeckTerminalCache $root
foreach ($entryName in $environmentNames) {
    if (($SmokeTest -and $entryName -eq 'pool') -or (-not $SmokeTest -and (Get-DeckPoolEntry $suite $entryName))) { continue }
    $item=[Windows.Controls.ListBoxItem]::new(); $item.Tag=$entryName
    $usage=$environmentCache[$entryName]
    $quota=@($usage.Windows | ForEach-Object { $_.Label+': '+(Format-DeckTerminalQuota $_) }) -join ' / '
    $item.Content=$entryName+' | '+(Get-DeckTerminalHealth $usage)+' | '+$quota
    [void]$poolMemberList.Items.Add($item)
}
Add-DeckEnvironmentLabel 'Rotation after an explicit quota rejection'
$poolModeBox=[Windows.Controls.ComboBox]::new(); [void]$poolModeBox.Items.Add('Ordered'); [void]$poolModeBox.Items.Add('Best'); $poolModeBox.SelectedIndex=0; [void]$environmentPanel.Children.Add($poolModeBox)
$poolSaveButton=[Windows.Controls.Button]::new(); $poolSaveButton.Content='Save pooled environment'; $poolSaveButton.Margin='0,10,0,14'; [void]$environmentPanel.Children.Add($poolSaveButton)
Add-DeckEnvironmentLabel 'Resource owner'
$shareSourceBox=[Windows.Controls.ComboBox]::new(); foreach ($entryName in $environmentNames) { [void]$shareSourceBox.Items.Add($entryName) }; $shareSourceBox.SelectedIndex=0; [void]$environmentPanel.Children.Add($shareSourceBox)
Add-DeckEnvironmentLabel 'Recipients (select any entries; new accounts stay isolated)'
$shareTargetList=[Windows.Controls.ListBox]::new(); $shareTargetList.SelectionMode='Multiple'; $shareTargetList.Height=110
foreach ($entryName in $environmentNames) { [void]$shareTargetList.Items.Add($entryName) }; [void]$environmentPanel.Children.Add($shareTargetList)
Add-DeckEnvironmentLabel 'Resources to share / unshare'
$shareResourceList=[Windows.Controls.ListBox]::new(); $shareResourceList.SelectionMode='Multiple'; $shareResourceList.Height=140
foreach ($resourceName in @('skills','memories','rules','prompts','AGENTS.md')) { [void]$shareResourceList.Items.Add($resourceName) }; [void]$environmentPanel.Children.Add($shareResourceList)
$loadResourcesButton=[Windows.Controls.Button]::new(); $loadResourcesButton.Content='Browse source skills and MCP servers'; $loadResourcesButton.Margin='0,6,0,0'; [void]$environmentPanel.Children.Add($loadResourcesButton)
Add-DeckEnvironmentLabel 'Individual skills or MCP servers (optional, comma-separated)'
$shareSpecificBox=[Windows.Controls.TextBox]::new(); $shareSpecificBox.ToolTip='Examples: skills/browser-harness, mcp:github'; [void]$environmentPanel.Children.Add($shareSpecificBox)
$shareExplanation=New-DeckText 'Folders share live edits in both directions. Instructions update from their owner at launch. MCP definitions load at launch; OAuth sign-ins remain separate. Unshare restores each recipient''s previous private resource. Whole config, credentials, chats and databases are not shareable.' '#929CA4'
$shareExplanation.Margin='0,8,0,10'; [void]$environmentPanel.Children.Add($shareExplanation)
$sharingActions=[Windows.Controls.WrapPanel]::new(); [void]$environmentPanel.Children.Add($sharingActions)
$shareApplyButton=[Windows.Controls.Button]::new(); $shareApplyButton.Content='Share selected'; [void]$sharingActions.Children.Add($shareApplyButton)
$shareRemoveButton=[Windows.Controls.Button]::new(); $shareRemoveButton.Content='Unshare / restore private'; [void]$sharingActions.Children.Add($shareRemoveButton)
$shareInspectButton=[Windows.Controls.Button]::new(); $shareInspectButton.Content='Show current sharing'; [void]$sharingActions.Children.Add($shareInspectButton)
$environmentStatus=New-DeckText '' '#A9E8D5'; $environmentStatus.Margin='0,12,0,0'; [void]$environmentPanel.Children.Add($environmentStatus)
$loadResourcesButton.Add_Click({
    try {
        if ($SmokeTest) { throw 'Preview only.' }
        $available=@(Get-DeckAvailableResources $suite ([string]$shareSourceBox.SelectedItem))
        $shareResourceList.Items.Clear(); foreach ($resourceName in $available) { [void]$shareResourceList.Items.Add($resourceName) }
        $environmentStatus.Text='Select whole folders or individual items. MCP discovery reads configuration only.'
    } catch { $environmentStatus.Text=$_.Exception.Message }
})
$loadPoolSettings={
    try {
        if ($SmokeTest) { return }
        $entry=Get-DeckPoolEntry $suite $poolNameBox.Text
        if ($entry) {
            $poolAll.IsChecked=($entry.Accounts -contains '*'); $poolModeBox.SelectedItem=$entry.Mode
            foreach ($item in $poolMemberList.Items) { $item.IsSelected=$item.Tag -in $entry.Accounts }
        }
    } catch { $environmentStatus.Text=$_.Exception.Message }
}
$poolNameBox.Add_LostFocus($loadPoolSettings); & $loadPoolSettings
$poolSaveButton.Add_Click({
    try {
        if ($SmokeTest) { throw 'Preview only.' }
        $members=if ($poolAll.IsChecked) { @('*') } else { @($poolMemberList.SelectedItems | ForEach-Object Tag) }
        $environmentStatus.Text=Set-DeckPoolEntry $suite $poolNameBox.Text $members ([string]$poolModeBox.SelectedItem)
        if ($poolNameBox.Text -notin @($shareSourceBox.Items)) { [void]$shareSourceBox.Items.Add($poolNameBox.Text); [void]$shareTargetList.Items.Add($poolNameBox.Text) }
        $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker; $script:lastRender=''
    } catch { $environmentStatus.Text=$_.Exception.Message }
})
$changeSharing={
    param($sender,$eventArgs)
    try {
        if ($SmokeTest) { throw 'Preview only.' }
        $resources=@($shareResourceList.SelectedItems | ForEach-Object { [string]$_ })+@($shareSpecificBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $recipients=@($shareTargetList.SelectedItems | ForEach-Object { [string]$_ })
        $environmentStatus.Text=(Set-DeckResourceSharing $suite ([string]$shareSourceBox.SelectedItem) $recipients $resources -Detach:($sender -eq $shareRemoveButton)) -join "`n"
    } catch { $environmentStatus.Text=$_.Exception.Message }
}
$shareApplyButton.Add_Click($changeSharing); $shareRemoveButton.Add_Click($changeSharing)
$shareInspectButton.Add_Click({
    try {
        $lines=@(foreach ($entryName in Get-DeckEntryNames $suite) { foreach ($binding in (Get-DeckSharing $suite $entryName).Bindings) { "$entryName <- $($binding.Source): $($binding.Resource)" } })
        $environmentStatus.Text=if ($lines.Count) { $lines -join "`n" } else { 'No Deck-managed resource sharing is configured.' }
    } catch { $environmentStatus.Text=$_.Exception.Message }
})
