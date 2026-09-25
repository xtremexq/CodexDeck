# Dot-sourced inside Show-DeckSettings after Deck.EnvironmentSettings.ps1.
$deckSkillState=@{Changes=@{};Controls=@{};Expanders=@{};Page=1;PageSize=5;PageCount=1;SuiteRoot=$suite;SmokeTest=[bool]$SmokeTest}
$deckSkillTab=[Windows.Controls.TabItem]::new(); $deckSkillTab.Header='Skills'
$deckSkillPanel=[Windows.Controls.StackPanel]::new(); $deckSkillPanel.Margin='2,0,12,0'
$deckSkillScroll=[Windows.Controls.ScrollViewer]::new(); $deckSkillScroll.VerticalScrollBarVisibility='Auto'; $deckSkillScroll.HorizontalScrollBarVisibility='Disabled'; $deckSkillScroll.Content=$deckSkillPanel
$deckSkillTab.Content=$deckSkillScroll; [void]$tabs.Items.Add($deckSkillTab)
[void]$deckSkillPanel.Children.Add((New-DeckText 'Deck skills' '#EDF1F7' 18))
$deckSkillHelp=New-DeckText 'Install managed skills once, choose their account access, and customize each account or pool from the same list. User-owned skills are never overwritten.' '#929CA4'
$deckSkillHelp.Margin='0,8,0,16'; [void]$deckSkillPanel.Children.Add($deckSkillHelp)

$pluginSection=[Windows.Controls.Border]::new(); $pluginSection.Background='#171C1F'; $pluginSection.BorderBrush='#303A42'; $pluginSection.BorderThickness='1'; $pluginSection.CornerRadius='7'; $pluginSection.Padding='12'; $pluginSection.Margin='0,0,0,16'; [void]$deckSkillPanel.Children.Add($pluginSection)
$pluginBody=[Windows.Controls.StackPanel]::new(); $pluginSection.Child=$pluginBody
[void]$pluginBody.Children.Add((New-DeckText 'Add skills from a plugin' '#A9E8D5' 14))
$pluginHelp=New-DeckText 'Add a Codex marketplace, then install plugin@marketplace. Deck keeps one runtime copy and adds every plugin skill to the managed list below.' '#929CA4' 11; $pluginHelp.Margin='0,5,0,10'; [void]$pluginBody.Children.Add($pluginHelp)
$pluginMarketplaceLabel=New-DeckText 'Marketplace source' '#A2ADB5' 11; $pluginMarketplaceLabel.Margin='0,0,0,4'; [void]$pluginBody.Children.Add($pluginMarketplaceLabel)
$pluginMarketplaceRow=[Windows.Controls.Grid]::new(); $pluginMarketplaceRow.Margin='0,0,0,9'; foreach($width in @('*','Auto')){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$pluginMarketplaceRow.ColumnDefinitions.Add($column)}; [void]$pluginBody.Children.Add($pluginMarketplaceRow)
$pluginMarketplaceSource=[Windows.Controls.TextBox]::new(); $pluginMarketplaceSource.ToolTip='owner/repository, Git URL, or local marketplace path'; [void]$pluginMarketplaceRow.Children.Add($pluginMarketplaceSource)
$pluginMarketplaceAdd=[Windows.Controls.Button]::new(); $pluginMarketplaceAdd.Content='Add marketplace'; $pluginMarketplaceAdd.Padding='10,5'; $pluginMarketplaceAdd.Margin='8,0,0,0'; [Windows.Controls.Grid]::SetColumn($pluginMarketplaceAdd,1); [void]$pluginMarketplaceRow.Children.Add($pluginMarketplaceAdd)
$pluginSelectorLabel=New-DeckText 'Plugin' '#A2ADB5' 11; $pluginSelectorLabel.Margin='0,0,0,4'; [void]$pluginBody.Children.Add($pluginSelectorLabel)
$pluginSelectorRow=[Windows.Controls.Grid]::new(); foreach($width in @('*','Auto')){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$pluginSelectorRow.ColumnDefinitions.Add($column)}; [void]$pluginBody.Children.Add($pluginSelectorRow)
$pluginSelector=[Windows.Controls.TextBox]::new(); $pluginSelector.ToolTip='plugin-name@marketplace-name'; [void]$pluginSelectorRow.Children.Add($pluginSelector)
$pluginInstall=[Windows.Controls.Button]::new(); $pluginInstall.Content='Install plugin skills'; $pluginInstall.Padding='10,5'; $pluginInstall.Margin='8,0,0,0'; [Windows.Controls.Grid]::SetColumn($pluginInstall,1); [void]$pluginSelectorRow.Children.Add($pluginInstall)
$pluginStatus=New-DeckText '' '#9BB5D9' 11; $pluginStatus.Margin='0,8,0,0'; [void]$pluginBody.Children.Add($pluginStatus)

$skillAccessLabel=New-DeckText 'Account access preset' '#A2ADB5'; $skillAccessLabel.Margin='0,0,0,6'; [void]$deckSkillPanel.Children.Add($skillAccessLabel)
$skillMembership=[Windows.Controls.ComboBox]::new(); foreach($option in @('Use all accounts and pools (including future entries)','Use all free accounts','Use all Plus or higher accounts','Choose access per account or pool')){[void]$skillMembership.Items.Add($option)}; $skillMembership.Margin='0,0,0,10'; [void]$deckSkillPanel.Children.Add($skillMembership)
$savedSkillScope=if($settings.SkillAccessAccounts){[string]$settings.SkillAccessAccounts}else{'*'}
$skillMembership.SelectedIndex=if($savedSkillScope -eq '*'){0}elseif($savedSkillScope -eq '*free'){1}elseif($savedSkillScope -eq '*paid'){2}else{3}
$skillWorkspace=[Windows.Controls.Grid]::new(); $skillWorkspace.Height=326; $skillWorkspace.Margin='0,0,0,6'
$skillAccessColumn=[Windows.Controls.ColumnDefinition]::new(); $skillAccessColumn.Width='220'; [void]$skillWorkspace.ColumnDefinitions.Add($skillAccessColumn)
$skillDetailColumn=[Windows.Controls.ColumnDefinition]::new(); $skillDetailColumn.Width='*'; [void]$skillWorkspace.ColumnDefinitions.Add($skillDetailColumn); [void]$deckSkillPanel.Children.Add($skillWorkspace)
$skillAccountPanel=[Windows.Controls.Grid]::new(); $skillAccountPanel.Height=$skillWorkspace.Height; $skillAccountPanel.Margin='0,0,14,0'; foreach($height in @('Auto','Auto','*')){$row=[Windows.Controls.RowDefinition]::new();$row.Height=[Windows.GridLengthConverter]::new().ConvertFromString($height);[void]$skillAccountPanel.RowDefinitions.Add($row)}; [void]$skillWorkspace.Children.Add($skillAccountPanel)
$skillAccountTitle=New-DeckText 'Accounts and pools' '#A2ADB5' 11; [void]$skillAccountPanel.Children.Add($skillAccountTitle)
$skillAccountHelp=New-DeckText 'Check access. Select a row to edit its skills.' '#929CA4' 10; $skillAccountHelp.Margin='0,3,0,7'; [Windows.Controls.Grid]::SetRow($skillAccountHelp,1); [void]$skillAccountPanel.Children.Add($skillAccountHelp)
$skillMembers=[Windows.Controls.ListBox]::new(); $skillMembers.Background='#171C1F'; $skillMembers.BorderBrush='#303A42'; $skillMembers.BorderThickness='1'; [Windows.Controls.Grid]::SetRow($skillMembers,2); [void]$skillAccountPanel.Children.Add($skillMembers)
$skillAccountChecks=@{}; $skillAccountItems=@{}
foreach($entryName in $environmentNames){
    $item=[Windows.Controls.ListBoxItem]::new(); $item.Tag=$entryName; $item.Padding='6,4'
    $check=[Windows.Controls.CheckBox]::new(); $check.Content=$entryName; $check.Tag=$item; $item.Content=$check
    $skillAccountChecks[$entryName]=$check; $skillAccountItems[$entryName]=$item; [void]$skillMembers.Items.Add($item)
}
$skillDetailPanel=[Windows.Controls.Grid]::new(); $skillDetailPanel.Height=$skillWorkspace.Height; foreach($height in @('Auto','Auto','*','Auto','Auto')){$row=[Windows.Controls.RowDefinition]::new();$row.Height=[Windows.GridLengthConverter]::new().ConvertFromString($height);[void]$skillDetailPanel.RowDefinitions.Add($row)}; [Windows.Controls.Grid]::SetColumn($skillDetailPanel,1); [void]$skillWorkspace.Children.Add($skillDetailPanel)
$deckSkillTargetLabel=New-DeckText 'Select an account or pool' '#EDF1F7' 14; $deckSkillTargetLabel.Margin='0,0,0,8'; [void]$skillDetailPanel.Children.Add($deckSkillTargetLabel)
$skillTargetPicker=[Windows.Controls.ComboBox]::new(); $skillTargetPicker.Margin='0,0,0,8'; foreach($entryName in $environmentNames){[void]$skillTargetPicker.Items.Add($entryName)}; [Windows.Controls.Grid]::SetRow($skillTargetPicker,1); [void]$skillDetailPanel.Children.Add($skillTargetPicker)
$deckSkillRowsScroll=[Windows.Controls.ScrollViewer]::new(); $deckSkillRowsScroll.VerticalScrollBarVisibility='Auto'; $deckSkillRowsScroll.HorizontalScrollBarVisibility='Disabled'; [Windows.Controls.Grid]::SetRow($deckSkillRowsScroll,2); [void]$skillDetailPanel.Children.Add($deckSkillRowsScroll)
$deckSkillRows=[Windows.Controls.StackPanel]::new(); $deckSkillRowsScroll.Content=$deckSkillRows
$deckSkillPager=[Windows.Controls.StackPanel]::new(); $deckSkillPager.Orientation='Horizontal'; $deckSkillPager.HorizontalAlignment='Right'; $deckSkillPager.Margin='0,7,0,0'; [Windows.Controls.Grid]::SetRow($deckSkillPager,3); [void]$skillDetailPanel.Children.Add($deckSkillPager)
$deckSkillPrevious=[Windows.Controls.Button]::new(); $deckSkillPrevious.Content='Previous'; $deckSkillPrevious.Padding='8,4'; $deckSkillPrevious.Margin='0,0,8,0'; [void]$deckSkillPager.Children.Add($deckSkillPrevious)
$deckSkillPageLabel=New-DeckText 'Page 1 of 1' '#A2ADB5' 11; $deckSkillPageLabel.VerticalAlignment='Center'; $deckSkillPageLabel.Margin='0,0,8,0'; [void]$deckSkillPager.Children.Add($deckSkillPageLabel)
$deckSkillNext=[Windows.Controls.Button]::new(); $deckSkillNext.Content='Next'; $deckSkillNext.Padding='8,4'; [void]$deckSkillPager.Children.Add($deckSkillNext)
$deckSkillStatus=New-DeckText '' '#929CA4'; $deckSkillStatus.Margin='0,5,0,0'; [Windows.Controls.Grid]::SetRow($deckSkillStatus,4); [void]$skillDetailPanel.Children.Add($deckSkillStatus)
$deckSkillTarget=$skillMembers
$browserSkillCard=[Windows.Controls.Border]::new(); $browserSkillCard.BorderBrush='#303A42'; $browserSkillCard.BorderThickness='1'; $browserSkillCard.CornerRadius='6'; $browserSkillCard.Padding='8,5'; $browserSkillCard.Margin='0,8,0,10'
$browserSkillBody=[Windows.Controls.StackPanel]::new(); $browserSkillCard.Child=$browserSkillBody
$browserSkillHeader=[Windows.Controls.DockPanel]::new(); [void]$browserSkillBody.Children.Add($browserSkillHeader)
$browserSkillExpand=[Windows.Controls.Button]::new(); $browserSkillExpand.Content='›'; $browserSkillExpand.Width=24; $browserSkillExpand.Height=22; $browserSkillExpand.Padding='0'; $browserSkillExpand.Margin='8,0,0,0'; $browserSkillExpand.ToolTip='Show description'; [Windows.Controls.DockPanel]::SetDock($browserSkillExpand,'Right'); [void]$browserSkillHeader.Children.Add($browserSkillExpand)
$browserSkillToggle=[Windows.Controls.CheckBox]::new(); $browserSkillToggle.Content='Browser Harness'; $browserSkillToggle.IsChecked=[bool]$settings.BrowserHarnessEnabled; $browserSkillToggle.FontWeight='SemiBold'; [void]$browserSkillHeader.Children.Add($browserSkillToggle)
$browserSkillNote=New-DeckText 'Share the detected Browser Harness skill with accounts and pools in the selected access scope. It applies to new conversations; user-owned copies remain untouched.' '#A2ADB5' 11; $browserSkillNote.Margin='22,6,0,3'; $browserSkillNote.Visibility='Collapsed'; [void]$browserSkillBody.Children.Add($browserSkillNote)
$browserSkillExpand.Add_Click({$expanded=$browserSkillNote.Visibility -ne 'Visible';$browserSkillNote.Visibility=if($expanded){'Visible'}else{'Collapsed'};$browserSkillExpand.Content=if($expanded){'⌄'}else{'›'};$browserSkillExpand.ToolTip=if($expanded){'Hide description'}else{'Show description'}}.GetNewClosure())
[void]$deckSkillPanel.Children.Add($browserSkillCard); $controls.BrowserHarnessEnabled=$browserSkillToggle
$currentSkillScope={
    if($skillMembership.SelectedIndex -eq 3){$chosen=@($environmentNames | Where-Object {[bool]$skillAccountChecks[$_].IsChecked}) -join ',';return $(if($chosen){$chosen}else{'__none__'})}
    return @('*','*free','*paid')[$skillMembership.SelectedIndex]
}.GetNewClosure()
$getDeckBundledSkills=Get-Command Get-DeckBundledSkills -CommandType Function -ErrorAction Stop
$getDeckBundledSkillStatus=Get-Command Get-DeckBundledSkillStatus -CommandType Function -ErrorAction Stop
$setDeckBundledSkillEnabled=Get-Command Set-DeckBundledSkillEnabled -CommandType Function -ErrorAction Stop
$testDeckSkillAccess=Get-Command Test-DeckSkillAccess -CommandType Function -ErrorAction Stop
$newDeckText=Get-Command New-DeckText -CommandType Function -ErrorAction Stop
$renderDeckSkills={
    $deckSkillRows.Children.Clear(); $deckSkillState.Controls=@{}; $deckSkillState.Expanders=@{}
    $selected=$deckSkillTarget.SelectedItem; $entry=if($selected){[string]$selected.Tag}else{''}
    if(-not $entry){$deckSkillStatus.Text='Choose an account or pool.';$deckSkillPageLabel.Text='Page 1 of 1';$deckSkillPrevious.IsEnabled=$false;$deckSkillNext.IsEnabled=$false;return}
    $deckSkillTargetLabel.Text="Skills for $entry"
    $catalog=@(& $getDeckBundledSkills $deckSkillState.SuiteRoot)
    if(-not $catalog.Count){$deckSkillStatus.Text='No Deck skills are installed.';$deckSkillPageLabel.Text='Page 1 of 1';$deckSkillPrevious.IsEnabled=$false;$deckSkillNext.IsEnabled=$false;return}
    $deckSkillState.PageCount=[Math]::Max(1,[Math]::Ceiling($catalog.Count/[double]$deckSkillState.PageSize))
    $deckSkillState.Page=[Math]::Max(1,[Math]::Min($deckSkillState.PageCount,$deckSkillState.Page))
    $deckSkillPageLabel.Text="Page $($deckSkillState.Page) of $($deckSkillState.PageCount)"
    $deckSkillPrevious.IsEnabled=$deckSkillState.Page -gt 1; $deckSkillNext.IsEnabled=$deckSkillState.Page -lt $deckSkillState.PageCount
    $scope=& $currentSkillScope
    $first=($deckSkillState.Page-1)*$deckSkillState.PageSize
    foreach($skill in @($catalog | Select-Object -Skip $first -First $deckSkillState.PageSize)){
        $key=$entry+'|'+$skill.Name
        if($deckSkillState.SmokeTest -and -not (Test-Path -LiteralPath (Join-Path $deckSkillState.SuiteRoot ('accounts/'+$entry)) -PathType Container)){$status=[pscustomobject]@{Desired=[bool]$skill.DefaultEnabled;Active=[bool]$skill.DefaultEnabled;Blocked=$false;BlockedReason='';Access=$true}}
        else{$status=& $getDeckBundledSkillStatus $deckSkillState.SuiteRoot $entry $skill $scope}
        $desired=if($deckSkillState.Changes.ContainsKey($key)){[bool]$deckSkillState.Changes[$key].Enabled}else{[bool]$status.Desired}
        $card=[Windows.Controls.Border]::new(); $card.BorderBrush='#303A42'; $card.BorderThickness='1'; $card.CornerRadius='6'; $card.Padding='8,5'; $card.Margin='0,0,0,6'
        $content=[Windows.Controls.StackPanel]::new(); $card.Child=$content
        $header=[Windows.Controls.DockPanel]::new(); [void]$content.Children.Add($header)
        $expand=[Windows.Controls.Button]::new(); $expand.Content='›'; $expand.Width=24; $expand.Height=22; $expand.Padding='0'; $expand.Margin='8,0,0,0'; $expand.ToolTip='Show description'; [Windows.Controls.DockPanel]::SetDock($expand,'Right'); [void]$header.Children.Add($expand)
        $check=[Windows.Controls.CheckBox]::new(); $check.Content=$skill.DisplayName; $check.IsChecked=$desired; $check.FontWeight='SemiBold'
        $check.IsEnabled=-not [bool]$status.Blocked -and [bool]$status.Access
        $check.Tag=@{Key=$key;Entry=$entry;Name=$skill.Name;Original=[bool]$status.Desired;State=$deckSkillState}
        $check.Add_Click({param($sender,$eventArgs)
            $item=$sender.Tag
            if([bool]$sender.IsChecked -eq $item.Original){$item.State.Changes.Remove($item.Key)}
            else{$item.State.Changes[$item.Key]=@{Entry=$item.Entry;Name=$item.Name;Enabled=[bool]$sender.IsChecked}}
        }.GetNewClosure())
        [void]$header.Children.Add($check)
        $details=[Windows.Controls.StackPanel]::new(); $details.Margin='22,6,0,3'; $details.Visibility='Collapsed'; [void]$content.Children.Add($details)
        $description=& $newDeckText $skill.Description '#A2ADB5' 11; [void]$details.Children.Add($description)
        if(-not $status.Access){$reason=& $newDeckText 'This account is outside the selected skill access scope.' '#929CA4' 11; $reason.Margin='0,6,0,0'; [void]$details.Children.Add($reason)}
        elseif($status.Blocked){$reason=& $newDeckText $status.BlockedReason '#F0B879' 11; $reason.Margin='0,6,0,0'; [void]$details.Children.Add($reason)}
        elseif($desired -and -not $status.Active -and -not $deckSkillState.SmokeTest){$pending=& $newDeckText 'Will be linked on save or the next launch.' '#9BB5D9' 11; $pending.Margin='0,6,0,0'; [void]$details.Children.Add($pending)}
        $expand.Tag=@{Details=$details;Button=$expand}
        $expand.Add_Click({param($sender,$eventArgs)$item=$sender.Tag;$expanded=$item.Details.Visibility -ne 'Visible';$item.Details.Visibility=if($expanded){'Visible'}else{'Collapsed'};$item.Button.Content=if($expanded){'⌄'}else{'›'};$item.Button.ToolTip=if($expanded){'Hide description'}else{'Show description'}}.GetNewClosure())
        [void]$deckSkillRows.Children.Add($card); $deckSkillState.Controls[$skill.Name]=$check; $deckSkillState.Expanders[$skill.Name]=$expand
    }
    $deckSkillStatus.Text=''
}.GetNewClosure()
$updateSkillAccessRows={
    $scope=@('*','*free','*paid')[[Math]::Min(2,$skillMembership.SelectedIndex)]
    $custom=$skillMembership.SelectedIndex -eq 3
    $skillAccessColumn.Width=if($custom){'220'}else{'0'}
    $skillAccountPanel.Visibility=if($custom){'Visible'}else{'Collapsed'}
    $skillTargetPicker.Visibility=if($custom){'Collapsed'}else{'Visible'}
    foreach($entryName in $environmentNames){
        $check=$skillAccountChecks[$entryName]; $check.IsEnabled=$custom
        if(-not $custom){$check.IsChecked=& $testDeckSkillAccess $deckSkillState.SuiteRoot $entryName $scope}
    }
}.GetNewClosure()
foreach($entryName in $environmentNames){
    $skillAccountChecks[$entryName].IsChecked=if($savedSkillScope -in @('*','*free','*paid')){Test-DeckSkillAccess $suite $entryName $savedSkillScope}else{$entryName -in @($savedSkillScope -split ',' | Where-Object {$_})}
    $skillAccountChecks[$entryName].IsEnabled=$skillMembership.SelectedIndex -eq 3
    $skillAccountChecks[$entryName].Add_Click({param($sender,$eventArgs)$skillMembers.SelectedItem=$sender.Tag;& $renderDeckSkills}.GetNewClosure())
}
$skillSelectionState=@{Syncing=$false}
$deckSkillTarget.Add_SelectionChanged({
    if($skillSelectionState.Syncing){return}
    $skillSelectionState.Syncing=$true
    try{$selected=$deckSkillTarget.SelectedItem;if($selected){$skillTargetPicker.SelectedItem=[string]$selected.Tag}}
    finally{$skillSelectionState.Syncing=$false}
    $deckSkillState.Page=1;& $renderDeckSkills
}.GetNewClosure())
$skillTargetPicker.Add_SelectionChanged({
    if($skillSelectionState.Syncing){return}
    $skillSelectionState.Syncing=$true
    try{$name=[string]$skillTargetPicker.SelectedItem;if($name -and $skillAccountItems.ContainsKey($name)){$deckSkillTarget.SelectedItem=$skillAccountItems[$name]}}
    finally{$skillSelectionState.Syncing=$false}
    $deckSkillState.Page=1;& $renderDeckSkills
}.GetNewClosure())
$deckSkillPrevious.Add_Click({if($deckSkillState.Page -gt 1){$deckSkillState.Page--;& $renderDeckSkills}}.GetNewClosure())
$deckSkillNext.Add_Click({if($deckSkillState.Page -lt $deckSkillState.PageCount){$deckSkillState.Page++;& $renderDeckSkills}}.GetNewClosure())
$skillMembership.Add_SelectionChanged({& $updateSkillAccessRows;$deckSkillState.Page=1;& $renderDeckSkills}.GetNewClosure())
$saveDeckSkills={
    param([switch]$ValidateOnly)
    foreach($key in @($deckSkillState.Changes.Keys)){
        $change=$deckSkillState.Changes[$key]
        & $setDeckBundledSkillEnabled $deckSkillState.SuiteRoot $change.Entry $change.Name ([bool]$change.Enabled) -ValidateOnly:$ValidateOnly | Out-Null
        if(-not $ValidateOnly){$deckSkillState.Changes.Remove($key)}
    }
}.GetNewClosure()
& $updateSkillAccessRows
if($deckSkillTarget.Items.Count){$deckSkillTarget.SelectedIndex=0}

$pluginOperation=@{Task=$null;Mode='';SuiteRoot=$suite}
$skillTaskCommands=@{
    Start=Get-Command Start-DeckTask -CommandType Function -ErrorAction Stop
    Stop=Get-Command Stop-DeckTask -CommandType Function -ErrorAction Stop
    Ready=Get-Command Test-DeckTaskReady -CommandType Function -ErrorAction Stop
    Failure=Get-Command Get-DeckTaskFailureMessage -CommandType Function -ErrorAction Stop
    Dispose=Get-Command Dispose-DeckTask -CommandType Function -ErrorAction Stop
    PluginWorker=Get-Command Get-DeckPluginWorkerCode -CommandType Function -ErrorAction Stop
    CatalogFile=Get-Command Get-DeckCatalogFile -CommandType Function -ErrorAction Stop
    Receipt=Get-Command Get-DeckManagedSkillReceipt -CommandType Function -ErrorAction Stop
}
$pluginPoll=[Windows.Threading.DispatcherTimer]::new(); $pluginPoll.Interval=[TimeSpan]::FromMilliseconds(200)
$startPluginOperation={param([string]$Mode,[string]$Value)
    if($pluginOperation.Task){return}
    $Value=$Value.Trim()
    if(-not $Value){$pluginStatus.Text=if($Mode -eq 'marketplace'){'Enter a marketplace source.'}else{'Enter plugin@marketplace.'};return}
    try{
        $pluginOperation.Task=& $skillTaskCommands.Start (& $skillTaskCommands.PluginWorker $pluginOperation.SuiteRoot $Mode $Value) 'Plugin' $Mode
        $pluginOperation.Mode=$Mode; $pluginMarketplaceAdd.IsEnabled=$false; $pluginInstall.IsEnabled=$false
        $pluginStatus.Text=if($Mode -eq 'marketplace'){'Adding marketplace…'}else{'Installing plugin skills…'}
        $pluginPoll.Start()
    }catch{$pluginStatus.Text=$_.Exception.Message}
}.GetNewClosure()
$pluginMarketplaceAdd.Add_Click({& $startPluginOperation 'marketplace' $pluginMarketplaceSource.Text}.GetNewClosure())
$pluginInstall.Add_Click({& $startPluginOperation 'plugin' $pluginSelector.Text}.GetNewClosure())
$pluginMarketplaceSource.Add_KeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq [Windows.Input.Key]::Return){& $startPluginOperation 'marketplace' $pluginMarketplaceSource.Text;$eventArgs.Handled=$true}}.GetNewClosure())
$pluginSelector.Add_KeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq [Windows.Input.Key]::Return){& $startPluginOperation 'plugin' $pluginSelector.Text;$eventArgs.Handled=$true}}.GetNewClosure())
$pluginPoll.Add_Tick({
    $worker=$pluginOperation.Task
    if(-not $worker){$pluginPoll.Stop();return}
    if(([DateTimeOffset]::UtcNow-$worker.Started).TotalSeconds -gt 180){& $skillTaskCommands.Stop $worker;$pluginStatus.Text='Plugin operation timed out.'}
    elseif(-not (& $skillTaskCommands.Ready $worker)){return}
    else{
        try{
            if($worker.Process.ExitCode -ne 0){throw (& $skillTaskCommands.Failure $worker)}
            $pluginStatus.Text=([string]$worker.Out.Result).Trim()
            if($pluginOperation.Mode -eq 'plugin'){& $renderDeckSkills}
        }catch{$pluginStatus.Text=$_.Exception.Message}
    }
    $pluginOperation.Task=$null;$pluginMarketplaceAdd.IsEnabled=$true;$pluginInstall.IsEnabled=$true;$pluginPoll.Stop();& $skillTaskCommands.Dispose $worker
}.GetNewClosure())

$aasSection=[Windows.Controls.Border]::new(); $aasSection.Background='#171C1F'; $aasSection.BorderBrush='#303A42'; $aasSection.BorderThickness='1'; $aasSection.CornerRadius='7'; $aasSection.Padding='12'; $aasSection.Margin='0,14,0,0'; [void]$deckSkillPanel.Children.Add($aasSection)
$aasPanel=[Windows.Controls.StackPanel]::new(); $aasSection.Child=$aasPanel
[void]$aasPanel.Children.Add((New-DeckText 'Agentic Awesome Skills' '#EDF1F7' 18))
$catalogHelp=New-DeckText 'Search and install individual skills here. New entries appear in the managed list above and follow the same account access.' '#929CA4' 11
$catalogHelp.Margin='0,7,0,13'; [void]$aasPanel.Children.Add($catalogHelp)
[void]$aasPanel.Children.Add((New-DeckText 'Find a skill' '#A2ADB5' 11))
$catalogSearch=[Windows.Controls.TextBox]::new(); $catalogSearch.Margin='0,0,0,8'; $catalogSearch.ToolTip='Search names, descriptions, categories and tags'; [void]$aasPanel.Children.Add($catalogSearch)
$catalogFilters=[Windows.Controls.WrapPanel]::new(); $catalogFilters.Margin='0,0,0,8'; [void]$aasPanel.Children.Add($catalogFilters)
$catalogCategory=[Windows.Controls.ComboBox]::new(); $catalogCategory.MinWidth=190; $catalogCategory.Margin='0,0,8,0'; [void]$catalogCategory.Items.Add('All categories'); $catalogCategory.SelectedIndex=0; [void]$catalogFilters.Children.Add($catalogCategory)
$catalogRisk=[Windows.Controls.ComboBox]::new(); $catalogRisk.MinWidth=110; $catalogRisk.Margin='0,0,8,0'; foreach($risk in @('All risks','none','safe','critical','offensive','unknown')){[void]$catalogRisk.Items.Add($risk)}; $catalogRisk.SelectedIndex=0; [void]$catalogFilters.Children.Add($catalogRisk)
$catalogRefresh=[Windows.Controls.Button]::new(); $catalogRefresh.Content='Refresh catalog'; $catalogRefresh.Padding='9,5'; [void]$catalogFilters.Children.Add($catalogRefresh)
$catalogResults=[Windows.Controls.ListBox]::new(); $catalogResults.Height=230; $catalogResults.Margin='0,0,0,8'; $catalogResults.Background='#171C1F'; $catalogResults.Foreground='#EAF0FA'; $catalogResults.BorderBrush='#303A42'; $catalogResults.BorderThickness='1'; [Windows.Controls.VirtualizingStackPanel]::SetIsVirtualizing($catalogResults,$true); [void]$aasPanel.Children.Add($catalogResults)
$catalogToolbar=[Windows.Controls.Grid]::new(); $catalogToolbar.Margin='0,0,0,8'; [void]$aasPanel.Children.Add($catalogToolbar)
foreach($width in @('*','Auto')){$column=[Windows.Controls.ColumnDefinition]::new(); $column.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$catalogToolbar.ColumnDefinitions.Add($column)}
$catalogActions=[Windows.Controls.StackPanel]::new(); $catalogActions.Orientation='Horizontal'; $catalogActions.HorizontalAlignment='Left'; $catalogActions.VerticalAlignment='Center'; [void]$catalogToolbar.Children.Add($catalogActions)
$catalogInstall=[Windows.Controls.Button]::new(); $catalogInstall.Content='Install'; $catalogInstall.IsEnabled=$false; $catalogInstall.Padding='8,5'; $catalogInstall.Margin='0,0,8,0'; [void]$catalogActions.Children.Add($catalogInstall)
$catalogSource=[Windows.Controls.Button]::new(); $catalogSource.Content='Inspect'; $catalogSource.IsEnabled=$false; $catalogSource.Padding='8,5'; [void]$catalogActions.Children.Add($catalogSource)
$catalogPager=[Windows.Controls.StackPanel]::new(); $catalogPager.Orientation='Horizontal'; $catalogPager.HorizontalAlignment='Right'; $catalogPager.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($catalogPager,1); [void]$catalogToolbar.Children.Add($catalogPager)
$catalogPrevious=[Windows.Controls.Button]::new(); $catalogPrevious.Content='Previous'; $catalogPrevious.Padding='9,5'; $catalogPrevious.Margin='0,0,8,0'; $catalogPrevious.IsEnabled=$false; [void]$catalogPager.Children.Add($catalogPrevious)
$catalogPageInput=[Windows.Controls.TextBox]::new(); $catalogPageInput.Text='1'; $catalogPageInput.Width=48; $catalogPageInput.MaxLength=6; $catalogPageInput.VerticalContentAlignment='Center'; $catalogPageInput.Margin='0,0,5,0'; $catalogPageInput.IsEnabled=$false; [void]$catalogPager.Children.Add($catalogPageInput)
$catalogPageGo=[Windows.Controls.Button]::new(); $catalogPageGo.Content='Go'; $catalogPageGo.Padding='9,5'; $catalogPageGo.Margin='0,0,8,0'; $catalogPageGo.IsEnabled=$false; [void]$catalogPager.Children.Add($catalogPageGo)
$catalogNext=[Windows.Controls.Button]::new(); $catalogNext.Content='Next'; $catalogNext.Padding='9,5'; $catalogNext.Margin='0,0,10,0'; $catalogNext.IsEnabled=$false; [void]$catalogPager.Children.Add($catalogNext)
$catalogPageLabel=New-DeckText 'Page 1 of 1' '#A2ADB5' 11; $catalogPageLabel.VerticalAlignment='Center'; [void]$catalogPager.Children.Add($catalogPageLabel)
$catalogDetail=New-DeckText 'Select a skill to see its description, risk and setup notes.' '#A2ADB5' 11; $catalogDetail.Margin='0,0,0,8'; [void]$aasPanel.Children.Add($catalogDetail)
$catalogStatus=New-DeckText '' '#9BB5D9' 11; $catalogStatus.Margin='0,10,0,0'; [void]$aasPanel.Children.Add($catalogStatus)
$catalogState=@{Loaded=$false;Busy=$false;Task=$null;Mode='';Selected=$null;SearchTask=$null;SearchKey='';WantedKey='';Commit='';UpdatingFilters=$false;Closed=$false;Page=1;PageCount=1;SuiteRoot=$suite}
$catalogPoll=[Windows.Threading.DispatcherTimer]::new(); $catalogPoll.Interval=[TimeSpan]::FromMilliseconds(200)
$renderCatalog={
    if($catalogState.Closed -or $catalogState.Busy){return}
    if(-not (Test-Path -LiteralPath (& $skillTaskCommands.CatalogFile $catalogState.SuiteRoot) -PathType Leaf)){
        $catalogStatus.Text='AAS catalog not installed. Use Install catalog here or in Integrations.'
        $catalogRefresh.Content='Install catalog';$catalogRefresh.IsEnabled=$true
        $catalogResults.Items.Clear();$catalogPrevious.IsEnabled=$false;$catalogNext.IsEnabled=$false;$catalogPageGo.IsEnabled=$false;$catalogPageInput.IsEnabled=$false
        return
    }
    $catalogRefresh.Content='Refresh catalog'
    $category=if($catalogCategory.SelectedIndex -gt 0){[string]$catalogCategory.SelectedItem}else{''}
    $risk=if($catalogRisk.SelectedIndex -gt 0){[string]$catalogRisk.SelectedItem}else{''}
    $query=[string]$catalogSearch.Text
    $key=(@($query,$category,$risk,$catalogState.Page,$catalogState.Loaded) | ConvertTo-Json -Compress)
    $catalogState.WantedKey=$key
    if($catalogState.SearchTask){return}
    try{
        $escapedSuite=$catalogState.SuiteRoot.Replace("'","''")
        $escapedQuery=$query.Replace("'","''")
        $escapedCategory=$category.Replace("'","''")
        $escapedRisk=$risk.Replace("'","''")
        $include=if($catalogState.Loaded){'$false'}else{'$true'}
        $code="`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue';try{. '$escapedSuite/Deck.Core.ps1'; `$page=Get-DeckAasCatalogPage '$escapedSuite' '$escapedQuery' '$escapedCategory' '$escapedRisk' 30 $($catalogState.Page) -IncludeCategories:$include; [Console]::Out.Write((ConvertTo-Json -InputObject `$page -Depth 5 -Compress))}catch{[Console]::Error.WriteLine(`$_.Exception.Message);exit 1}"
        $catalogState.SearchTask=& $skillTaskCommands.Start $code 'SkillCatalogSearch' ''
        try{$catalogState.SearchTask.Process.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal}catch{}
        $catalogState.SearchKey=$key
        $catalogInstall.IsEnabled=$false; $catalogRefresh.IsEnabled=$false
        $catalogPrevious.IsEnabled=$false; $catalogNext.IsEnabled=$false; $catalogPageGo.IsEnabled=$false; $catalogPageInput.IsEnabled=$false
        $catalogStatus.Text=if($catalogState.Loaded){'Searching AAS catalog…'}else{'Loading AAS catalog…'}
        $catalogPoll.Start()
    }catch{$catalogStatus.Text=$_.Exception.Message;$catalogRefresh.IsEnabled=$true}
}.GetNewClosure()
$catalogDebounce=[Windows.Threading.DispatcherTimer]::new(); $catalogDebounce.Interval=[TimeSpan]::FromMilliseconds(350)
$catalogDebounce.Add_Tick({$catalogDebounce.Stop(); & $renderCatalog}.GetNewClosure())
$queueCatalogSearch={if(-not $catalogState.UpdatingFilters -and $tabs.SelectedItem -eq $deckSkillTab){$catalogState.Page=1;$catalogPageInput.Text='1';$catalogDebounce.Stop();$catalogDebounce.Start()}}.GetNewClosure()
$catalogSearch.Add_TextChanged($queueCatalogSearch)
$catalogCategory.Add_SelectionChanged($queueCatalogSearch)
$catalogRisk.Add_SelectionChanged($queueCatalogSearch)
$goCatalogPage={param([int]$number)
    if(-not $catalogState.Loaded -or $catalogState.Busy -or $catalogState.SearchTask){return}
    $target=[Math]::Max(1,[Math]::Min($catalogState.PageCount,$number))
    $catalogPageInput.Text=[string]$target
    if($target -ne $catalogState.Page){$catalogState.Page=$target;& $renderCatalog}
}.GetNewClosure()
$catalogPrevious.Add_Click({& $goCatalogPage ($catalogState.Page-1)}.GetNewClosure())
$catalogNext.Add_Click({& $goCatalogPage ($catalogState.Page+1)}.GetNewClosure())
$submitCatalogPage={$number=0;if([int]::TryParse($catalogPageInput.Text,[ref]$number)){& $goCatalogPage $number}else{$catalogPageInput.Text=[string]$catalogState.Page}}.GetNewClosure()
$catalogPageGo.Add_Click($submitCatalogPage)
$catalogPageInput.Add_KeyDown({param($sender,$eventArgs)
    if($eventArgs.Key -eq [Windows.Input.Key]::Return){& $submitCatalogPage;$eventArgs.Handled=$true}
}.GetNewClosure())
$tabs.Add_SelectionChanged({param($sender,$eventArgs)
    if($eventArgs.OriginalSource -eq $tabs -and $tabs.SelectedItem -eq $deckSkillTab -and -not $catalogState.Loaded -and -not $catalogState.SearchTask){& $renderCatalog}
}.GetNewClosure())
$catalogResults.Add_SelectionChanged({
    $selected=$catalogResults.SelectedItem
    $catalogState.Selected=if($selected){$selected.Tag}else{$null}
    $skill=$catalogState.Selected
    if(-not $skill){$catalogInstall.IsEnabled=$false;$catalogSource.IsEnabled=$false;$catalogDetail.Text='Select a skill to see its description, risk and setup notes.';return}
    $installed=Test-Path -LiteralPath (Join-Path $catalogState.SuiteRoot ('skills/'+$skill.id))
    $receipt=if($installed){try{& $skillTaskCommands.Receipt $catalogState.SuiteRoot ([string]$skill.id)}catch{$null}}else{$null}
    $managed=$receipt -and $receipt.repository -eq 'sickn33/agentic-awesome-skills'
    $validName=$skill.id -match '^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$'
    $catalogInstall.IsEnabled=$validName -and (-not $installed -or $managed) -and -not $catalogState.Busy
    $catalogInstall.Content=if($managed){'Update'}elseif($installed){'Name in use'}else{'Install'}
    $catalogInstall.ToolTip=if($installed -and -not $managed){'A skill with this name is already installed.'}else{'Install or update the selected skill for all accounts and pools.'}
    $catalogSource.IsEnabled=$true
    $setup=if($skill.setupSummary){"`nSetup: $($skill.setupSummary)"}else{''}
    $license=if($skill.license){" · license: $($skill.license)"}else{''}
    $catalogDetail.Text="$($skill.id) · $($skill.category) · risk: $($skill.risk)$license`n$($skill.description)$setup"
}.GetNewClosure())
$catalogSource.Add_Click({
    $skill=$catalogState.Selected
    if($skill -and $catalogState.Commit){Start-Process ("https://github.com/sickn33/agentic-awesome-skills/tree/$($catalogState.Commit)/$($skill.path)")}
}.GetNewClosure())
$catalogMenu=[Windows.Controls.ContextMenu]::new(); $catalogMenu.Resources=$window.Resources
$catalogMenuInstall=[Windows.Controls.MenuItem]::new(); $catalogMenuInstall.Header='Install or update'; $catalogMenuInstall.Add_Click({$catalogInstall.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}.GetNewClosure()); [void]$catalogMenu.Items.Add($catalogMenuInstall)
$catalogMenuInspect=[Windows.Controls.MenuItem]::new(); $catalogMenuInspect.Header='Inspect source'; $catalogMenuInspect.Add_Click({$catalogSource.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}.GetNewClosure()); [void]$catalogMenu.Items.Add($catalogMenuInspect)
$catalogMenuCopy=[Windows.Controls.MenuItem]::new(); $catalogMenuCopy.Header='Copy skill ID'; $catalogMenuCopy.Add_Click({if($catalogState.Selected){[Windows.Clipboard]::SetText([string]$catalogState.Selected.id)}}.GetNewClosure()); [void]$catalogMenu.Items.Add($catalogMenuCopy)
$catalogMenuFolder=[Windows.Controls.MenuItem]::new(); $catalogMenuFolder.Header='Open installed folder'; $catalogMenuFolder.Add_Click({if($catalogState.Selected){$path=Join-Path $catalogState.SuiteRoot ('skills/'+$catalogState.Selected.id);if(Test-Path -LiteralPath $path -PathType Container){Start-Process explorer.exe -ArgumentList @($path)}}}.GetNewClosure()); [void]$catalogMenu.Items.Add($catalogMenuFolder)
$catalogMenu.Add_Opened({
    $catalogMenuInstall.IsEnabled=$catalogInstall.IsEnabled
    $catalogMenuInstall.Header=if($catalogInstall.Content -eq 'Update'){'Update skill'}else{'Install skill'}
    $catalogMenuInspect.IsEnabled=$catalogSource.IsEnabled
    $catalogMenuCopy.IsEnabled=[bool]$catalogState.Selected
    $catalogMenuFolder.IsEnabled=[bool]($catalogState.Selected -and (Test-Path -LiteralPath (Join-Path $catalogState.SuiteRoot ('skills/'+$catalogState.Selected.id)) -PathType Container))
}.GetNewClosure())
$catalogResults.ContextMenu=$catalogMenu
$catalogResults.Add_PreviewMouseRightButtonDown({param($sender,$eventArgs)
    $source=$eventArgs.OriginalSource
    while($source -and $source -isnot [Windows.Controls.ListBoxItem]){$source=[Windows.Media.VisualTreeHelper]::GetParent($source)}
    if($source){$catalogResults.SelectedItem=$source}
}.GetNewClosure())
$startCatalogJob={param([string]$Mode,[string]$Id)
    if($catalogState.Busy -or $catalogState.SearchTask){return}
    $escapedSuite=$catalogState.SuiteRoot.Replace("'","''")
    $escapedId=$Id.Replace("'","''")
    $code="`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue';try{. '$escapedSuite/Deck.Core.ps1'; if('$Mode' -eq 'refresh'){Update-DeckAasCatalog '$escapedSuite'}else{Install-DeckAasSkill '$escapedSuite' '$escapedId' -Update:('$Mode' -eq 'update')}}catch{[Console]::Error.WriteLine(`$_.Exception.Message);exit 1}"
    $catalogState.Task=& $skillTaskCommands.Start $code 'SkillCatalog' ''
    $catalogState.Mode=$Mode; $catalogState.Busy=$true
    $catalogInstall.IsEnabled=$false; $catalogRefresh.IsEnabled=$false
    $catalogStatus.Text=if($Mode -eq 'refresh'){'Refreshing AAS catalog…'}else{"$Mode $Id…"}
    $catalogPoll.Start()
}.GetNewClosure()
$catalogInstall.Add_Click({
    try{
        $skill=$catalogState.Selected
        if(-not $skill){return}
        $receipt=& $skillTaskCommands.Receipt $catalogState.SuiteRoot ([string]$skill.id)
        & $startCatalogJob $(if($receipt){'update'}else{'install'}) ([string]$skill.id)
    }catch{$catalogStatus.Text=$_.Exception.Message}
}.GetNewClosure())
$catalogRefresh.Add_Click({try{& $startCatalogJob 'refresh' ''}catch{$catalogStatus.Text=$_.Exception.Message}}.GetNewClosure())
$catalogPoll.Add_Tick({
    if($catalogState.SearchTask){
        $worker=$catalogState.SearchTask
        if(([DateTimeOffset]::UtcNow-$worker.Started).TotalSeconds -gt 12){& $skillTaskCommands.Stop $worker;$catalogState.SearchTask=$null;& $skillTaskCommands.Dispose $worker;$catalogStatus.Text='AAS search timed out.';$catalogRefresh.IsEnabled=$true;$catalogPrevious.IsEnabled=$catalogState.Page -gt 1;$catalogNext.IsEnabled=$catalogState.Page -lt $catalogState.PageCount;$catalogPageGo.IsEnabled=$catalogState.PageCount -gt 1;$catalogPageInput.IsEnabled=$catalogPageGo.IsEnabled}
        elseif(& $skillTaskCommands.Ready $worker){
            $catalogState.SearchTask=$null
            try{
                if($worker.Process.ExitCode -ne 0){throw (& $skillTaskCommands.Failure $worker)}
                if($catalogState.SearchKey -eq $catalogState.WantedKey){
                    $page=([string]$worker.Out.Result) | ConvertFrom-Json -ErrorAction Stop
                    if(-not $page.commit -or $page.total -lt 1){throw 'Invalid AAS search response.'}
                    $catalogState.Commit=[string]$page.commit
                    $catalogState.Page=[int]$page.page; $catalogState.PageCount=[int]$page.pageCount
                    if(-not $catalogState.Loaded){
                        $catalogState.UpdatingFilters=$true
                        try{foreach($category in @($page.categories)){if($category){[void]$catalogCategory.Items.Add([string]$category)}}}
                        finally{$catalogState.UpdatingFilters=$false}
                        $catalogState.Loaded=$true
                    }
                    $catalogResults.Items.Clear()
                    foreach($skill in @($page.skills)){
                        $item=[Windows.Controls.ListBoxItem]::new(); $item.Content=('{0}   ·   {1}   ·   {2}' -f $skill.id,$skill.category,$skill.risk); $item.Tag=$skill
                        [void]$catalogResults.Items.Add($item)
                    }
                    $catalogPageInput.Text=[string]$catalogState.Page
                    $catalogPageLabel.Text="Page $($catalogState.Page) of $($catalogState.PageCount)"
                    $catalogPrevious.IsEnabled=$catalogState.Page -gt 1
                    $catalogNext.IsEnabled=$catalogState.Page -lt $catalogState.PageCount
                    $catalogPageGo.IsEnabled=$catalogState.PageCount -gt 1
                    $catalogPageInput.IsEnabled=$catalogPageGo.IsEnabled
                    $first=if($page.matchCount){(($catalogState.Page-1)*$page.pageSize)+1}else{0}
                    $last=if($page.matchCount){$first+$catalogResults.Items.Count-1}else{0}
                    $catalogStatus.Text="Showing $first–$last of $($page.matchCount) matching skills ($($page.total) in catalog) · pinned $($catalogState.Commit.Substring(0,12))."
                    $catalogRefresh.IsEnabled=$true
                }
            }catch{$catalogStatus.Text=$_.Exception.Message;$catalogRefresh.IsEnabled=$true;$catalogPrevious.IsEnabled=$catalogState.Page -gt 1;$catalogNext.IsEnabled=$catalogState.Page -lt $catalogState.PageCount;$catalogPageGo.IsEnabled=$catalogState.PageCount -gt 1;$catalogPageInput.IsEnabled=$catalogPageGo.IsEnabled}
            finally{& $skillTaskCommands.Dispose $worker}
        }
        if(-not $catalogState.SearchTask -and $catalogState.SearchKey -ne $catalogState.WantedKey){& $renderCatalog}
    }
    if($catalogState.Task -and (& $skillTaskCommands.Ready $catalogState.Task)){
        $worker=$catalogState.Task; $catalogState.Task=$null; $catalogState.Busy=$false
        $catalogRefresh.IsEnabled=$true
        try{
            if($worker.Process.ExitCode -ne 0){throw (& $skillTaskCommands.Failure $worker)}
            $catalogStatus.Text=([string]$worker.Out.Result).Trim()
            if($catalogState.Mode -eq 'refresh'){
                $catalogState.Loaded=$false;$catalogState.Commit='';$catalogState.Page=1;$catalogState.PageCount=1;$catalogPageInput.Text='1';$catalogState.UpdatingFilters=$true
                try{$catalogCategory.Items.Clear();[void]$catalogCategory.Items.Add('All categories');$catalogCategory.SelectedIndex=0}
                finally{$catalogState.UpdatingFilters=$false}
                & $renderCatalog
            }else{
                & $renderDeckSkills
                if($catalogResults.SelectedItem){$selection=$catalogResults.SelectedIndex;$catalogResults.SelectedIndex=-1;$catalogResults.SelectedIndex=$selection}
            }
        }catch{$catalogStatus.Text=$_.Exception.Message}
        finally{& $skillTaskCommands.Dispose $worker}
    }
    if(-not $catalogState.Task -and -not $catalogState.SearchTask){$catalogPoll.Stop()}
}.GetNewClosure())
$dialog.Add_Closed({
    $catalogState.Closed=$true;$catalogDebounce.Stop();$catalogPoll.Stop();$pluginPoll.Stop()
    foreach($worker in @($catalogState.Task,$catalogState.SearchTask,$pluginOperation.Task)){if($worker){& $skillTaskCommands.Stop $worker;& $skillTaskCommands.Dispose $worker}}
}.GetNewClosure())
