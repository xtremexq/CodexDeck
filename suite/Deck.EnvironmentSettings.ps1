# Settings drafts: no filesystem changes until the shared Save settings action.
. (Join-Path $suite 'Deck.Terminal.ps1')
$environmentState=@{Pools=@{}; Changes=@{}; Resources=@{}; Loading=$false; Task=$null; Owner=''}
$environmentStatus=New-DeckText '' '#929CA4'; $environmentStatus.Margin='0,8,0,0'
$environmentTab=[Windows.Controls.TabItem]::new(); $environmentTab.Header='Environments'
$environmentPanel=[Windows.Controls.StackPanel]::new(); $environmentPanel.Margin='2,0,12,0'
$environmentScroll=[Windows.Controls.ScrollViewer]::new(); $environmentScroll.VerticalScrollBarVisibility='Auto'; $environmentScroll.HorizontalScrollBarVisibility='Disabled'; $environmentScroll.Content=$environmentPanel
$environmentTab.Content=$environmentScroll; [void]$tabs.Items.Add($environmentTab)
function Add-DeckEnvironmentLabel([string]$Text) {
    $label=New-DeckText $Text '#A2ADB5'; $label.Margin='0,12,0,6'; [void]$environmentPanel.Children.Add($label)
}
[void]$environmentPanel.Children.Add((New-DeckText 'Pooled environment' '#EDF1F7' 18))
Add-DeckEnvironmentLabel 'Environment'
$poolNameBox=[Windows.Controls.ComboBox]::new(); $poolNameBox.IsEditable=$true; $poolNameBox.ToolTip='Choose an environment or type a new name.'
$environmentNames=if($SmokeTest){@('pool','account1','account2')}else{@(Get-DeckEntryNames $suite)}
foreach($entryName in $environmentNames) {
    if (($SmokeTest -and $entryName -eq 'pool') -or (-not $SmokeTest -and (Get-DeckPoolEntry $suite $entryName))) { [void]$poolNameBox.Items.Add($entryName) }
}
if($poolNameBox.Items.Count){$poolNameBox.SelectedIndex=0; $poolNameBox.Text=[string]$poolNameBox.SelectedItem}else{$poolNameBox.Text='pool'}
[void]$environmentPanel.Children.Add($poolNameBox)
Add-DeckEnvironmentLabel 'Quota accounts'
$poolMembership=[Windows.Controls.ComboBox]::new()
foreach($label in @('Use all signed-in accounts (including future accounts)','Use all free accounts','Use all Plus or higher accounts','Use selected accounts')){[void]$poolMembership.Items.Add($label)}
[void]$environmentPanel.Children.Add($poolMembership)
$poolMemberList=[Windows.Controls.ListBox]::new(); $poolMemberList.SelectionMode='Multiple'; $poolMemberList.MaxHeight=150; $poolMemberList.Margin='0,8,0,0'
foreach($entryName in $environmentNames) {
    if (($SmokeTest -and $entryName -eq 'pool') -or (-not $SmokeTest -and ((Get-DeckPoolEntry $suite $entryName) -or -not (Test-Path -LiteralPath (Join-Path $suite "accounts/$entryName/auth.json"))))) { continue }
    [void]$poolMemberList.Items.Add($entryName)
}
[void]$environmentPanel.Children.Add($poolMemberList)
Add-DeckEnvironmentLabel 'Rotation'
$poolModeBox=[Windows.Controls.ComboBox]::new(); foreach($mode in @('Ordered','Best')){[void]$poolModeBox.Items.Add($mode)}
$poolModeBox.ToolTip='Switch only after an explicit quota rejection. Best uses fresh cached usage.'
[void]$environmentPanel.Children.Add($poolModeBox)
$rememberPool={
    if($environmentState.Loading){return}
    $name=$poolNameBox.Text.Trim(); if(-not $name){return}
    $members=if($poolMembership.SelectedIndex -eq 3){@($poolMemberList.SelectedItems | ForEach-Object {[string]$_})}else{@(@('*','*free','*paid')[$poolMembership.SelectedIndex])}
    $environmentState.Pools[$name]=@{Name=$name; Members=@($members); Mode=[string]$poolModeBox.SelectedItem}
}.GetNewClosure()
$loadPool={
    $environmentState.Loading=$true
    try {
        $name=$poolNameBox.Text.Trim()
        if(-not $name -and $poolNameBox.SelectedItem){$name=[string]$poolNameBox.SelectedItem; $poolNameBox.Text=$name}
        $draft=$environmentState.Pools[$name]
        $entry=if(-not $SmokeTest -and $name){Get-DeckPoolEntry $suite $name}
        $members=if($draft){@($draft.Members)}elseif($entry){@($entry.Accounts)}else{@('*')}
        $poolMembership.SelectedIndex=if(($members -join ',') -eq '*'){0}elseif(($members -join ',') -eq '*free'){1}elseif(($members -join ',') -eq '*paid'){2}else{3}
        $poolModeBox.SelectedItem=if($draft){$draft.Mode}elseif($entry){$entry.Mode}else{'Ordered'}
        $poolMemberList.SelectedItems.Clear(); foreach($member in $members){if($poolMemberList.Items.Contains($member)){[void]$poolMemberList.SelectedItems.Add($member)}}
        $poolMemberList.Visibility=if($poolMembership.SelectedIndex -eq 3){'Visible'}else{'Collapsed'}
    } catch {$environmentStatus.Text=$_.Exception.Message} finally {$environmentState.Loading=$false}
}.GetNewClosure()
$poolMembership.Add_SelectionChanged({$poolMemberList.Visibility=if($poolMembership.SelectedIndex -eq 3){'Visible'}else{'Collapsed'}; & $rememberPool}.GetNewClosure())
$poolModeBox.Add_SelectionChanged($rememberPool); $poolMemberList.Add_SelectionChanged($rememberPool)
$poolNameBox.Add_LostKeyboardFocus({& $loadPool; & $rememberPool}.GetNewClosure())
$poolNameBox.Add_SelectionChanged({$poolNameBox.Text=[string]$poolNameBox.SelectedItem; & $loadPool}.GetNewClosure())
$sharingTitle=New-DeckText 'Resource sharing' '#EDF1F7' 18; $sharingTitle.Margin='0,26,0,0'; [void]$environmentPanel.Children.Add($sharingTitle)
Add-DeckEnvironmentLabel 'Share from'
$shareSourceBox=[Windows.Controls.ComboBox]::new(); foreach($entryName in $environmentNames){[void]$shareSourceBox.Items.Add($entryName)}
[void]$environmentPanel.Children.Add($shareSourceBox)
$sharingGrid=[Windows.Controls.Grid]::new(); $sharingGrid.Margin='0,12,0,0'
foreach($column in 1..2){$definition=[Windows.Controls.ColumnDefinition]::new(); $definition.Width='*'; [void]$sharingGrid.ColumnDefinitions.Add($definition)}
$resourcePanel=[Windows.Controls.StackPanel]::new(); $resourcePanel.Margin='0,0,12,0'; [void]$sharingGrid.Children.Add($resourcePanel)
[void]$resourcePanel.Children.Add((New-DeckText 'Resource' '#A2ADB5'))
$shareResourceList=[Windows.Controls.ListBox]::new(); $shareResourceList.DisplayMemberPath='Label'; $shareResourceList.Height=210; $shareResourceList.Margin='0,6,0,0'; [void]$resourcePanel.Children.Add($shareResourceList)
$recipientPanel=[Windows.Controls.StackPanel]::new(); [Windows.Controls.Grid]::SetColumn($recipientPanel,1); [void]$sharingGrid.Children.Add($recipientPanel)
$recipientHeading=New-DeckText 'Share with' '#A2ADB5'; [void]$recipientPanel.Children.Add($recipientHeading)
$recipientScroll=[Windows.Controls.ScrollViewer]::new(); $recipientScroll.VerticalScrollBarVisibility='Auto'; $recipientScroll.Height=210; $recipientScroll.Margin='0,6,0,0'
$shareRecipients=[Windows.Controls.StackPanel]::new(); $recipientScroll.Content=$shareRecipients; [void]$recipientPanel.Children.Add($recipientScroll)
[void]$environmentPanel.Children.Add($sharingGrid)
[void]$environmentPanel.Children.Add($environmentStatus)
$sharingHint=New-DeckText 'Changes apply with Save settings. Unchecking restores the previous private resource.' '#929CA4'; $sharingHint.Margin='0,12,0,0'; [void]$environmentPanel.Children.Add($sharingHint)
$sharingHint.ToolTip='Shared folders allow edits from every recipient. Instructions and MCP definitions update at launch. Credentials and runtime databases stay private. Close recipient terminals before saving.'
$renderRecipients={
    $shareRecipients.Children.Clear()
    $owner=[string]$shareSourceBox.SelectedItem; $resource=$shareResourceList.SelectedItem
    if(-not $resource){$recipientHeading.Text='Share with'; return}
    $recipientHeading.Text='Share '+$resource.Label+' with'
    foreach($target in $environmentNames){
        if($target -eq $owner){continue}
        $bindings=if($SmokeTest){@()}else{@((Get-DeckSharing $suite $target).Bindings)}
        $binding=@($bindings | Where-Object Resource -eq $resource.Resource) | Select-Object -First 1
        $key=$owner+'|'+$resource.Resource+'|'+$target
        $original=[bool]($binding -and $binding.Source -eq $owner)
        $check=[Windows.Controls.CheckBox]::new(); $check.Content=$target; $check.Margin='4,6,0,8'
        $check.IsChecked=if($environmentState.Changes.ContainsKey($key)){$environmentState.Changes[$key].Enabled}else{$original}
        $check.Tag=@{Key=$key;Source=$owner;Target=$target;Resource=$resource.Resource;Original=$original;State=$environmentState}
        if($binding -and $binding.Source -ne $owner){$check.IsEnabled=$false; $check.Content=$target+' (from '+$binding.Source+')'; $check.ToolTip='Uncheck this resource under its current owner first, then save.'}
        $check.Add_Click({param($sender,$eventArgs)
            $item=$sender.Tag
            if([bool]$sender.IsChecked -eq $item.Original){$item.State.Changes.Remove($item.Key)}else{$item.State.Changes[$item.Key]=@{Source=$item.Source;Target=$item.Target;Resource=$item.Resource;Enabled=[bool]$sender.IsChecked}}
        }.GetNewClosure())
        [void]$shareRecipients.Children.Add($check)
    }
}.GetNewClosure()
$populateResources={
    param($values)
    $shareResourceList.Items.Clear()
    foreach($resource in @($values | Sort-Object -Unique)){
        $label=switch -Regex ($resource){'^skills$'{'All skills';break} '^skills/'{'Skill: '+$resource.Substring(7);break} '^mcp:'{'MCP: '+$resource.Substring(4);break} '^AGENTS.md$'{'Instructions';break} '^memories$'{'Memory files';break} default{(Get-Culture).TextInfo.ToTitleCase($resource)}}
        [void]$shareResourceList.Items.Add([pscustomobject]@{Resource=$resource;Label=$label})
    }
    $environmentStatus.Text=if($shareResourceList.Items.Count){''}else{'This environment has no shareable resources yet.'}
    if($shareResourceList.Items.Count){$shareResourceList.SelectedIndex=0}
}.GetNewClosure()
$resourceTimer=[Windows.Threading.DispatcherTimer]::new(); $resourceTimer.Interval=[TimeSpan]::FromMilliseconds(150)
$resourceTimer.Add_Tick({
    $task=$environmentState.Task; if(-not $task){return}
    if(([DateTimeOffset]::UtcNow-$task.Started).TotalSeconds -gt 30){Stop-DeckTask $task}
    if(-not $task.Process.HasExited){return}
    try{
        $output=$task.Out.GetAwaiter().GetResult()
        if($task.Process.ExitCode -ne 0){throw 'Could not read resources for this environment.'}
        $values=@($output | ConvertFrom-Json)
        $environmentState.Resources[$environmentState.Owner]=$values; & $populateResources $values
    }catch{$environmentStatus.Text=$_.Exception.Message}
    finally{$task.Process.Dispose(); $environmentState.Task=$null; $resourceTimer.Stop()}
}.GetNewClosure())
$shareSourceBox.Add_SelectionChanged({
    if($environmentState.Task){Stop-DeckTask $environmentState.Task; $environmentState.Task.Process.Dispose(); $environmentState.Task=$null}; $resourceTimer.Stop()
    $shareResourceList.Items.Clear(); $shareRecipients.Children.Clear(); $recipientHeading.Text='Share with'
    $owner=[string]$shareSourceBox.SelectedItem; $environmentState.Owner=$owner
    if(-not $owner){return}
    if($SmokeTest){& $populateResources $(if($owner -eq 'pool'){@('skills','memories','mcp:example')}else{@('AGENTS.md','skills/example')}); return}
    if($environmentState.Resources.ContainsKey($owner)){& $populateResources $environmentState.Resources[$owner]; return}
    $environmentStatus.Text='Loading resources...'
    try{
        $escapedSuite=$suite.Replace("'","''"); $escapedOwner=$owner.Replace("'","''")
        $code="`$ErrorActionPreference='Stop'; . '$escapedSuite/Deck.Environments.ps1'; `$values=@(Get-DeckAvailableResources '$escapedSuite' '$escapedOwner'); foreach(`$name in Get-DeckEntryNames '$escapedSuite'){`$values+=@((Get-DeckSharing '$escapedSuite' `$name).Bindings | Where-Object Source -eq '$escapedOwner' | ForEach-Object Resource)}; ConvertTo-Json -Compress -InputObject @(`$values)"
        $environmentState.Task=Start-DeckTask $code 'Resources' $owner; $resourceTimer.Start()
    }catch{$environmentStatus.Text=$_.Exception.Message}
}.GetNewClosure())
$shareResourceList.Add_SelectionChanged({& $renderRecipients}.GetNewClosure())
$dialog.Add_Closed({$resourceTimer.Stop(); if($environmentState.Task){Stop-DeckTask $environmentState.Task; $environmentState.Task.Process.Dispose(); $environmentState.Task=$null}}.GetNewClosure())
$saveEnvironments={
    param([switch]$ValidateOnly)
    foreach($draft in $environmentState.Pools.Values){
        $existing=Get-DeckPoolEntry $suite $draft.Name
        if($existing -and ($existing.Accounts -join ',') -eq ($draft.Members -join ',') -and $existing.Mode -eq $draft.Mode){continue}
        Set-DeckPoolEntry $suite $draft.Name $draft.Members $draft.Mode -ValidateOnly:$ValidateOnly | Out-Null
    }
    foreach($key in @($environmentState.Changes.Keys)){
        $change=$environmentState.Changes[$key]
        Set-DeckResourceSharing $suite $change.Source @($change.Target) @($change.Resource) -Detach:(!$change.Enabled) -ValidateOnly:$ValidateOnly | Out-Null
        if(-not $ValidateOnly){$environmentState.Changes.Remove($key)}
    }
}.GetNewClosure()
& $loadPool
if($shareSourceBox.Items.Count){$shareSourceBox.SelectedIndex=0}
