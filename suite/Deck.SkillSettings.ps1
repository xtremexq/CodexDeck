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
$catalogHelp=New-DeckText 'Install or update the AAS index in Integrations, then search it here. Install only the skills you choose; Deck makes each selected skill available to all accounts and pools.' '#929CA4' 11
$catalogHelp.Margin='0,7,0,13'; [void]$deckSkillPanel.Children.Add($catalogHelp)
[void]$deckSkillPanel.Children.Add((New-DeckText 'Find a skill' '#A2ADB5' 11))
$catalogSearch=[Windows.Controls.TextBox]::new(); $catalogSearch.Margin='0,0,0,8'; $catalogSearch.ToolTip='Search names, descriptions, categories and tags'; [void]$deckSkillPanel.Children.Add($catalogSearch)
$catalogFilters=[Windows.Controls.WrapPanel]::new(); $catalogFilters.Margin='0,0,0,8'; [void]$deckSkillPanel.Children.Add($catalogFilters)
$catalogCategory=[Windows.Controls.ComboBox]::new(); $catalogCategory.MinWidth=190; $catalogCategory.Margin='0,0,8,0'; [void]$catalogCategory.Items.Add('All categories'); $catalogCategory.SelectedIndex=0; [void]$catalogFilters.Children.Add($catalogCategory)
$catalogRisk=[Windows.Controls.ComboBox]::new(); $catalogRisk.MinWidth=110; $catalogRisk.Margin='0,0,8,0'; foreach($risk in @('All risks','none','safe','critical','offensive','unknown')){[void]$catalogRisk.Items.Add($risk)}; $catalogRisk.SelectedIndex=0; [void]$catalogFilters.Children.Add($catalogRisk)
$catalogRefresh=[Windows.Controls.Button]::new(); $catalogRefresh.Content='Refresh catalog'; $catalogRefresh.Padding='9,5'; [void]$catalogFilters.Children.Add($catalogRefresh)
$catalogResults=[Windows.Controls.ListBox]::new(); $catalogResults.Height=230; $catalogResults.Margin='0,0,0,8'; $catalogResults.Background='#171C1F'; $catalogResults.Foreground='#EAF0FA'; $catalogResults.BorderBrush='#303A42'; $catalogResults.BorderThickness='1'; [Windows.Controls.VirtualizingStackPanel]::SetIsVirtualizing($catalogResults,$true); [void]$deckSkillPanel.Children.Add($catalogResults)
$catalogToolbar=[Windows.Controls.Grid]::new(); $catalogToolbar.Margin='0,0,0,8'; [void]$deckSkillPanel.Children.Add($catalogToolbar)
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
$catalogDetail=New-DeckText 'Select a skill to see its description, risk and setup notes.' '#A2ADB5' 11; $catalogDetail.Margin='0,0,0,8'; [void]$deckSkillPanel.Children.Add($catalogDetail)
$catalogStatus=New-DeckText '' '#9BB5D9' 11; $catalogStatus.Margin='0,10,0,0'; [void]$deckSkillPanel.Children.Add($catalogStatus)
$catalogState=@{Loaded=$false;Busy=$false;Task=$null;Mode='';Selected=$null;SearchTask=$null;SearchKey='';WantedKey='';Commit='';UpdatingFilters=$false;Closed=$false;Page=1;PageCount=1}
$catalogPoll=[Windows.Threading.DispatcherTimer]::new(); $catalogPoll.Interval=[TimeSpan]::FromMilliseconds(200)
$renderCatalog={
    if($catalogState.Closed -or $catalogState.Busy){return}
    if(-not (Test-Path -LiteralPath (Get-DeckCatalogFile $suite) -PathType Leaf)){
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
        $escapedSuite=$suite.Replace("'","''")
        $escapedQuery=$query.Replace("'","''")
        $escapedCategory=$category.Replace("'","''")
        $escapedRisk=$risk.Replace("'","''")
        $include=if($catalogState.Loaded){'$false'}else{'$true'}
        $code="`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue';try{. '$escapedSuite/Deck.Core.ps1'; `$page=Get-DeckAasCatalogPage '$escapedSuite' '$escapedQuery' '$escapedCategory' '$escapedRisk' 30 $($catalogState.Page) -IncludeCategories:$include; [Console]::Out.Write((ConvertTo-Json -InputObject `$page -Depth 5 -Compress))}catch{[Console]::Error.WriteLine(`$_.Exception.Message);exit 1}"
        $catalogState.SearchTask=Start-DeckTask $code 'SkillCatalogSearch' ''
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
    $installed=Test-Path -LiteralPath (Join-Path $suite ('skills/'+$skill.id))
    $receipt=if($installed){try{Get-DeckManagedSkillReceipt $suite ([string]$skill.id)}catch{$null}}else{$null}
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
$startCatalogJob={param([string]$Mode,[string]$Id)
    if($catalogState.Busy -or $catalogState.SearchTask){return}
    $escapedSuite=$suite.Replace("'","''")
    $escapedId=$Id.Replace("'","''")
    $code="`$ErrorActionPreference='Stop';`$ProgressPreference='SilentlyContinue';try{. '$escapedSuite/Deck.Core.ps1'; if('$Mode' -eq 'refresh'){Update-DeckAasCatalog '$escapedSuite'}else{Install-DeckAasSkill '$escapedSuite' '$escapedId' -Update:('$Mode' -eq 'update')}}catch{[Console]::Error.WriteLine(`$_.Exception.Message);exit 1}"
    $catalogState.Task=Start-DeckTask $code 'SkillCatalog' ''
    $catalogState.Mode=$Mode; $catalogState.Busy=$true
    $catalogInstall.IsEnabled=$false; $catalogRefresh.IsEnabled=$false
    $catalogStatus.Text=if($Mode -eq 'refresh'){'Refreshing AAS catalog…'}else{"$Mode $Id…"}
    $catalogPoll.Start()
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
$catalogPoll.Add_Tick({
    if($catalogState.SearchTask){
        $worker=$catalogState.SearchTask
        if(([DateTimeOffset]::UtcNow-$worker.Started).TotalSeconds -gt 12){Stop-DeckTask $worker;$catalogState.SearchTask=$null;Dispose-DeckTask $worker;$catalogStatus.Text='AAS search timed out.';$catalogRefresh.IsEnabled=$true;$catalogPrevious.IsEnabled=$catalogState.Page -gt 1;$catalogNext.IsEnabled=$catalogState.Page -lt $catalogState.PageCount;$catalogPageGo.IsEnabled=$catalogState.PageCount -gt 1;$catalogPageInput.IsEnabled=$catalogPageGo.IsEnabled}
        elseif(Test-DeckTaskReady $worker){
            $catalogState.SearchTask=$null
            try{
                if($worker.Process.ExitCode -ne 0){throw (Get-DeckTaskFailureMessage $worker)}
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
            finally{Dispose-DeckTask $worker}
        }
        if(-not $catalogState.SearchTask -and $catalogState.SearchKey -ne $catalogState.WantedKey){& $renderCatalog}
    }
    if($catalogState.Task -and (Test-DeckTaskReady $catalogState.Task)){
        $worker=$catalogState.Task; $catalogState.Task=$null; $catalogState.Busy=$false
        $catalogRefresh.IsEnabled=$true
        try{
            if($worker.Process.ExitCode -ne 0){throw (Get-DeckTaskFailureMessage $worker)}
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
        finally{Dispose-DeckTask $worker}
    }
    if(-not $catalogState.Task -and -not $catalogState.SearchTask){$catalogPoll.Stop()}
}.GetNewClosure())
$dialog.Add_Closed({$catalogState.Closed=$true;$catalogDebounce.Stop();$catalogPoll.Stop();foreach($worker in @($catalogState.Task,$catalogState.SearchTask)){if($worker){Stop-DeckTask $worker;Dispose-DeckTask $worker}}}.GetNewClosure())
