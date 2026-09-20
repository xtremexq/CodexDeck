# Dot-sourced inside Show-DeckSettings after Deck.EnvironmentSettings.ps1.
$deckSkillState=@{Changes=@{};Controls=@{}}
$deckSkillTab=[Windows.Controls.TabItem]::new(); $deckSkillTab.Header='Skills'
$deckSkillPanel=[Windows.Controls.StackPanel]::new(); $deckSkillPanel.Margin='2,0,12,0'
$deckSkillScroll=[Windows.Controls.ScrollViewer]::new(); $deckSkillScroll.VerticalScrollBarVisibility='Auto'; $deckSkillScroll.HorizontalScrollBarVisibility='Disabled'; $deckSkillScroll.Content=$deckSkillPanel
$deckSkillTab.Content=$deckSkillScroll; [void]$tabs.Items.Add($deckSkillTab)
[void]$deckSkillPanel.Children.Add((New-DeckText 'Deck skills' '#EDF1F7' 18))
$deckSkillHelp=New-DeckText 'Reusable workflows maintained with Codex Deck. Enabled skills appear in new Codex sessions for the selected account or pool. User-owned skills are never overwritten.' '#929CA4'
$deckSkillHelp.Margin='0,8,0,16'; [void]$deckSkillPanel.Children.Add($deckSkillHelp)
$deckSkillTargetLabel=New-DeckText 'Account or pool' '#A2ADB5'; $deckSkillTargetLabel.Margin='0,0,0,6'; [void]$deckSkillPanel.Children.Add($deckSkillTargetLabel)
$deckSkillTarget=[Windows.Controls.ComboBox]::new(); foreach($entryName in $environmentNames){[void]$deckSkillTarget.Items.Add($entryName)}; [void]$deckSkillPanel.Children.Add($deckSkillTarget)
$deckSkillRows=[Windows.Controls.StackPanel]::new(); $deckSkillRows.Margin='0,14,0,0'; [void]$deckSkillPanel.Children.Add($deckSkillRows)
$deckSkillStatus=New-DeckText '' '#929CA4'; $deckSkillStatus.Margin='0,12,0,0'; [void]$deckSkillPanel.Children.Add($deckSkillStatus)
$renderDeckSkills={
    $deckSkillRows.Children.Clear(); $deckSkillState.Controls=@{}
    $entry=[string]$deckSkillTarget.SelectedItem
    if(-not $entry){$deckSkillStatus.Text='Choose an account or pool.';return}
    $catalog=@(Get-DeckBundledSkills $suite)
    if(-not $catalog.Count){$deckSkillStatus.Text='No Deck skills are installed.';return}
    foreach($skill in $catalog){
        $key=$entry+'|'+$skill.Name
        if($SmokeTest -and -not (Test-Path -LiteralPath (Join-Path $suite ('accounts/'+$entry)) -PathType Container)){$status=[pscustomobject]@{Desired=[bool]$skill.DefaultEnabled;Active=[bool]$skill.DefaultEnabled;Blocked=$false;BlockedReason=''}}
        else{$status=Get-DeckBundledSkillStatus $suite $entry $skill}
        $desired=if($deckSkillState.Changes.ContainsKey($key)){[bool]$deckSkillState.Changes[$key].Enabled}else{[bool]$status.Desired}
        $card=[Windows.Controls.Border]::new(); $card.BorderBrush='#303A42'; $card.BorderThickness='1'; $card.CornerRadius='6'; $card.Padding='12'; $card.Margin='0,0,0,10'
        $content=[Windows.Controls.StackPanel]::new(); $card.Child=$content
        $check=[Windows.Controls.CheckBox]::new(); $check.Content=$skill.DisplayName; $check.IsChecked=$desired; $check.FontWeight='SemiBold'
        $check.IsEnabled=-not [bool]$status.Blocked
        $check.Tag=@{Key=$key;Entry=$entry;Name=$skill.Name;Original=[bool]$status.Desired;State=$deckSkillState}
        $check.Add_Click({param($sender,$eventArgs)
            $item=$sender.Tag
            if([bool]$sender.IsChecked -eq $item.Original){$item.State.Changes.Remove($item.Key)}
            else{$item.State.Changes[$item.Key]=@{Entry=$item.Entry;Name=$item.Name;Enabled=[bool]$sender.IsChecked}}
        }.GetNewClosure())
        [void]$content.Children.Add($check)
        $description=New-DeckText $skill.Description '#A2ADB5' 11; $description.Margin='22,6,0,0'; [void]$content.Children.Add($description)
        if($status.Blocked){$reason=New-DeckText $status.BlockedReason '#F0B879' 11; $reason.Margin='22,6,0,0'; [void]$content.Children.Add($reason)}
        elseif($desired -and -not $status.Active -and -not $SmokeTest){$pending=New-DeckText 'Will be linked on save or the next launch.' '#9BB5D9' 11; $pending.Margin='22,6,0,0'; [void]$content.Children.Add($pending)}
        [void]$deckSkillRows.Children.Add($card); $deckSkillState.Controls[$skill.Name]=$check
    }
    $deckSkillStatus.Text='Changes apply with Save settings and affect new Codex sessions.'
}.GetNewClosure()
$deckSkillTarget.Add_SelectionChanged($renderDeckSkills)
$saveDeckSkills={
    param([switch]$ValidateOnly)
    foreach($key in @($deckSkillState.Changes.Keys)){
        $change=$deckSkillState.Changes[$key]
        Set-DeckBundledSkillEnabled $suite $change.Entry $change.Name ([bool]$change.Enabled) -ValidateOnly:$ValidateOnly | Out-Null
        if(-not $ValidateOnly){$deckSkillState.Changes.Remove($key)}
    }
}.GetNewClosure()
if($deckSkillTarget.Items.Count){$deckSkillTarget.SelectedIndex=0}
