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

$catalogDivider=[Windows.Controls.Border]::new(); $catalogDivider.BorderBrush='#303A42'; $catalogDivider.BorderThickness='0,1,0,0'; $catalogDivider.Margin='0,16,0,14'; [void]$deckSkillPanel.Children.Add($catalogDivider)
[void]$deckSkillPanel.Children.Add((New-DeckText 'Agentic Awesome Skills catalog' '#EDF1F7' 18))
$catalogHelp=New-DeckText 'Search the full AAS catalog locally. Install only the skills you choose; Deck makes each selected skill available to all accounts and pools. Review the risk and setup notes before installing.' '#929CA4' 11
$catalogHelp.Margin='0,7,0,13'; [void]$deckSkillPanel.Children.Add($catalogHelp)
[void]$deckSkillPanel.Children.Add((New-DeckText 'Find a skill' '#A2ADB5' 11))
$catalogSearch=[Windows.Controls.TextBox]::new(); $catalogSearch.Margin='0,0,0,8'; $catalogSearch.ToolTip='Search names, descriptions, categories and tags'; [void]$deckSkillPanel.Children.Add($catalogSearch)
$catalogFilters=[Windows.Controls.WrapPanel]::new(); $catalogFilters.Margin='0,0,0,8'; [void]$deckSkillPanel.Children.Add($catalogFilters)
$catalogCategory=[Windows.Controls.ComboBox]::new(); $catalogCategory.MinWidth=190; $catalogCategory.Margin='0,0,8,0'; [void]$catalogCategory.Items.Add('All categories'); $catalogCategory.SelectedIndex=0; [void]$catalogFilters.Children.Add($catalogCategory)
$catalogRisk=[Windows.Controls.ComboBox]::new(); $catalogRisk.MinWidth=110; $catalogRisk.Margin='0,0,8,0'; foreach($risk in @('All risks','none','safe','critical','offensive','unknown')){[void]$catalogRisk.Items.Add($risk)}; $catalogRisk.SelectedIndex=0; [void]$catalogFilters.Children.Add($catalogRisk)
$catalogRefresh=[Windows.Controls.Button]::new(); $catalogRefresh.Content='Refresh catalog'; $catalogRefresh.Padding='9,5'; [void]$catalogFilters.Children.Add($catalogRefresh)
$catalogResults=[Windows.Controls.ListBox]::new(); $catalogResults.Height=230; $catalogResults.Margin='0,0,0,8'; $catalogResults.Background='#171C1F'; $catalogResults.Foreground='#EAF0FA'; $catalogResults.BorderBrush='#303A42'; $catalogResults.BorderThickness='1'; [Windows.Controls.VirtualizingStackPanel]::SetIsVirtualizing($catalogResults,$true); [void]$deckSkillPanel.Children.Add($catalogResults)
$catalogDetail=New-DeckText 'Select a skill to see its description, risk and setup notes.' '#A2ADB5' 11; $catalogDetail.Margin='0,0,0,8'; [void]$deckSkillPanel.Children.Add($catalogDetail)
$catalogActions=[Windows.Controls.WrapPanel]::new(); [void]$deckSkillPanel.Children.Add($catalogActions)
$catalogInstall=[Windows.Controls.Button]::new(); $catalogInstall.Content='Install selected'; $catalogInstall.IsEnabled=$false; $catalogInstall.Padding='11,7'; $catalogInstall.Margin='0,0,8,0'; [void]$catalogActions.Children.Add($catalogInstall)
$catalogSource=[Windows.Controls.Button]::new(); $catalogSource.Content='Inspect source'; $catalogSource.IsEnabled=$false; $catalogSource.Padding='11,7'; [void]$catalogActions.Children.Add($catalogSource)
$catalogStatus=New-DeckText '' '#9BB5D9' 11; $catalogStatus.Margin='0,10,0,0'; [void]$deckSkillPanel.Children.Add($catalogStatus)
$catalogState=@{Loaded=$false;Busy=$false;Task=$null;Mode='';Selected=$null}
$renderCatalog={
    if(-not $catalogState.Loaded -or $catalogState.Busy){return}
    $catalogResults.Items.Clear()
    $category=if($catalogCategory.SelectedIndex -gt 0){[string]$catalogCategory.SelectedItem}else{''}
    $risk=if($catalogRisk.SelectedIndex -gt 0){[string]$catalogRisk.SelectedItem}else{''}
    $matches=@(Search-DeckAasSkills $suite $catalogSearch.Text $category $risk 60)
    foreach($skill in $matches){
        $item=[Windows.Controls.ListBoxItem]::new(); $item.Content=('{0}   ·   {1}   ·   {2}' -f $skill.id,$skill.category,$skill.risk); $item.Tag=$skill
        [void]$catalogResults.Items.Add($item)
    }
    $pinned=(Read-DeckAasCatalog $suite).commit.Substring(0,12)
    $catalogStatus.Text="Showing $($matches.Count) results (up to 60) · pinned $pinned. Search to narrow the catalog."
}.GetNewClosure()
$loadCatalog={
    if($catalogState.Loaded){return}
    try{
        $catalog=Read-DeckAasCatalog $suite
        foreach($category in @($catalog.skills | ForEach-Object category | Sort-Object -Unique)){if($category){[void]$catalogCategory.Items.Add([string]$category)}}
        $catalogState.Loaded=$true
        $catalogStatus.Text="Pinned AAS catalog: $($catalog.skills.Count) skills at $($catalog.commit.Substring(0,12))."
        & $renderCatalog
    }catch{$catalogStatus.Text=$_.Exception.Message}
}.GetNewClosure()
$catalogDebounce=[Windows.Threading.DispatcherTimer]::new(); $catalogDebounce.Interval=[TimeSpan]::FromMilliseconds(180)
$catalogDebounce.Add_Tick({$catalogDebounce.Stop(); & $renderCatalog}.GetNewClosure())
$catalogSearch.Add_TextChanged({$catalogDebounce.Stop();$catalogDebounce.Start()}.GetNewClosure())
$catalogCategory.Add_SelectionChanged({$catalogDebounce.Stop();$catalogDebounce.Start()}.GetNewClosure())
$catalogRisk.Add_SelectionChanged({$catalogDebounce.Stop();$catalogDebounce.Start()}.GetNewClosure())
$tabs.Add_SelectionChanged({if($tabs.SelectedItem -eq $deckSkillTab){& $loadCatalog}}.GetNewClosure())
$catalogResults.Add_SelectionChanged({
    $selected=$catalogResults.SelectedItem
    $catalogState.Selected=if($selected){$selected.Tag}else{$null}
    $skill=$catalogState.Selected
    if(-not $skill){$catalogInstall.IsEnabled=$false;$catalogSource.IsEnabled=$false;return}
    $installed=Test-Path -LiteralPath (Join-Path $suite ('skills/'+$skill.id))
    $receipt=if($installed){try{Get-DeckManagedSkillReceipt $suite ([string]$skill.id)}catch{$null}}else{$null}
    $managed=$receipt -and $receipt.repository -eq 'sickn33/agentic-awesome-skills'
    $validName=$skill.id -match '^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$'
    $catalogInstall.IsEnabled=$validName -and (-not $installed -or $managed) -and -not $catalogState.Busy
    $catalogInstall.Content=if($managed){'Update selected'}elseif($installed){'Name already in use'}else{'Install selected'}
    $catalogSource.IsEnabled=$true
    $setup=if($skill.setupSummary){"`nSetup: $($skill.setupSummary)"}else{''}
    $license=if($skill.license){" · license: $($skill.license)"}else{''}
    $catalogDetail.Text="$($skill.id) · $($skill.category) · risk: $($skill.risk)$license`n$($skill.description)$setup"
}.GetNewClosure())
$catalogSource.Add_Click({
    $skill=$catalogState.Selected
    if($skill){$catalog=Read-DeckAasCatalog $suite; Start-Process ("https://github.com/sickn33/agentic-awesome-skills/tree/$($catalog.commit)/$($skill.path)")}
}.GetNewClosure())
$startCatalogJob={param([string]$Mode,[string]$Id)
    if($catalogState.Busy){return}
    $escapedSuite=$suite.Replace("'","''")
    $escapedId=$Id.Replace("'","''")
    $code="`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue';try{. '$escapedSuite/Deck.Core.ps1'; if('$Mode' -eq 'refresh'){Update-DeckAasCatalog '$escapedSuite'}else{Install-DeckAasSkill '$escapedSuite' '$escapedId' -Update:('$Mode' -eq 'update')}}catch{[Console]::Error.WriteLine(`$_.Exception.Message);exit 1}"
    $catalogState.Task=Start-DeckTask $code 'SkillCatalog' ''
    $catalogState.Mode=$Mode; $catalogState.Busy=$true
    $catalogInstall.IsEnabled=$false; $catalogRefresh.IsEnabled=$false
    $catalogStatus.Text=if($Mode -eq 'refresh'){'Refreshing AAS catalog…'}else{"$Mode $Id…"}
}.GetNewClosure()
$catalogInstall.Add_Click({
    try{
        $skill=$catalogState.Selected
        if(-not $skill){return}
        $receipt=Get-DeckManagedSkillReceipt $suite ([string]$skill.id)
        & $startCatalogJob $(if($receipt){'update'}else{'install'}) ([string]$skill.id)
    }catch{$catalogStatus.Text=$_.Exception.Message}
}.GetNewClosure())
$catalogRefresh.Add_Click({try{& $startCatalogJob 'refresh' ''}catch{$catalogStatus.Text=$_.Exception.Message}}.GetNewClosure())
$catalogPoll=[Windows.Threading.DispatcherTimer]::new(); $catalogPoll.Interval=[TimeSpan]::FromMilliseconds(200)
$catalogPoll.Add_Tick({
    if(-not $catalogState.Busy -or -not (Test-DeckTaskReady $catalogState.Task)){return}
    $worker=$catalogState.Task; $catalogState.Task=$null; $catalogState.Busy=$false
    $catalogRefresh.IsEnabled=$true
    try{
        if($worker.Process.ExitCode -ne 0){throw (Get-DeckTaskFailureMessage $worker)}
        $catalogStatus.Text=([string]$worker.Out.Result).Trim()
        if($catalogState.Mode -eq 'refresh'){$catalogState.Loaded=$false;$catalogCategory.Items.Clear();[void]$catalogCategory.Items.Add('All categories');$catalogCategory.SelectedIndex=0;& $loadCatalog}
        else{& $renderDeckSkills}
        if($catalogResults.SelectedItem){$catalogInstall.IsEnabled=$true}
    }catch{$catalogStatus.Text=$_.Exception.Message}
    finally{Dispose-DeckTask $worker}
}.GetNewClosure())
$catalogPoll.Start()
$dialog.Add_Closed({$catalogDebounce.Stop();$catalogPoll.Stop();if($catalogState.Task){Stop-DeckTask $catalogState.Task;Dispose-DeckTask $catalogState.Task}}.GetNewClosure())
