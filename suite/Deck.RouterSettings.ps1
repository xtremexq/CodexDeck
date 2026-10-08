$routerTab=[Windows.Controls.TabItem]::new();$routerTab.Header='AI Router'
$routerScroll=[Windows.Controls.ScrollViewer]::new();$routerScroll.VerticalScrollBarVisibility='Auto';$routerScroll.HorizontalScrollBarVisibility='Disabled'
$routerPanel=[Windows.Controls.StackPanel]::new();$routerPanel.Margin='2,0,12,0';$routerScroll.Content=$routerPanel;$routerTab.Content=$routerScroll;[void]$tabs.Items.Add($routerTab)
[void]$routerPanel.Children.Add((New-DeckText 'AI Router server' '#EDF1F7' 18))
$routerHelp=New-DeckText 'Optional companion for AIDeck Router. Provides a standard API endpoint, encrypted provider keys, proxies and native Deck terminals. The Chrome extension also works standalone.' '#929CA4';$routerHelp.Margin='0,8,0,14';[void]$routerPanel.Children.Add($routerHelp)
$routerSource=[Windows.Controls.TextBox]::new();$routerSource.Text='';$routerSource.Margin='0,6,0,14';$routerSource.ToolTip='Optional aideck-router source folder. Blank uses the router payload bundled with Deck.'
[void]$routerPanel.Children.Add((New-DeckText 'Router source folder (optional)'));[void]$routerPanel.Children.Add($routerSource)
$routerStartup=[Windows.Controls.CheckBox]::new();$routerStartup.Content='Start server at Windows sign-in';$routerStartup.Margin='0,0,0,14'
$routerSaved=Read-DeckJson (Get-DeckRouterPaths $suite).Service;$routerStartup.IsChecked=if($routerSaved){[bool]$routerSaved.StartAtLogin}else{$true};[void]$routerPanel.Children.Add($routerStartup)
$routerActions=[Windows.Controls.WrapPanel]::new();[void]$routerPanel.Children.Add($routerActions)
$routerButtons=@{}
foreach($label in @('Install / update server','Enable server','Stop server','Open dashboard','Refresh')){$control=[Windows.Controls.Button]::new();$control.Content=$label;[void]$routerActions.Children.Add($control);$routerButtons[$label]=$control}
$routerStatus=New-DeckText '' '#A9E8D5';$routerStatus.Margin='0,14,0,14';[void]$routerPanel.Children.Add($routerStatus)
[void]$routerPanel.Children.Add((New-DeckText 'Extension pairing requests' '#EDF1F7' 15))
$routerRequests=[Windows.Controls.ComboBox]::new();$routerRequests.Margin='0,8,0,14';[void]$routerPanel.Children.Add($routerRequests)
$routerApprove=[Windows.Controls.Button]::new();$routerApprove.Content='Approve matching code';[void]$routerPanel.Children.Add($routerApprove)
$routerNote=New-DeckText 'In the extension, choose Connect to Deck and request pairing. Approve only the code you see there. The extension receives owner access to this local router. After pairing it reconnects using the saved key. Keep Deck enabled; the server restarts if it exits. Chrome installation and provider API keys remain your setup steps.' '#929CA4';$routerNote.Margin='0,14,0,14';[void]$routerPanel.Children.Add($routerNote)
$routerContext=@{Suite=$suite;Demo=[bool]($SmokeTest -or $Demo);Task=$null;Timer=$null;Closing=$false}
$routerCommands=@{};foreach($name in @('Get-DeckRouterStatus','Start-DeckRouter','Stop-DeckRouter','Open-DeckRouterDashboard','Approve-DeckRouterPairing','Start-DeckTask','Test-DeckTaskReady','Get-DeckTaskFailureMessage','Dispose-DeckTask','Stop-DeckTask')){$routerCommands[$name]=Get-Command $name -CommandType Function -ErrorAction Stop}
$routerCommands['Set-DeckRouterStartup']=Get-Command Set-DeckRouterStartup -CommandType Function
$routerStartup.Add_Click({if(-not $routerContext.Demo){try{& $routerCommands['Set-DeckRouterStartup'] $routerContext.Suite ([bool]$routerStartup.IsChecked)}catch{$routerStatus.Text=$_.Exception.Message}}}.GetNewClosure())
$routerRefresh={
    if($routerContext.Demo){$routerStatus.Text='Preview: server operations are disabled.';return}
    if($routerContext.Task){return}
    $status=& $routerCommands['Get-DeckRouterStatus'] $routerContext.Suite
    $routerStatus.Text=if($status.Ready){'Ready: http://127.0.0.1:5147/v1'}elseif($status.Enabled){'Enabled: starting or restarting. Check deck/ai-router/server-error.log and supervisor-error.log if this persists.'}elseif($status.Installed){'Installed. Enable the server to pair.'}else{'Not installed. Node.js 22 or newer is required.'}
    $routerRequests.Items.Clear()
    foreach($pending in $status.Pending){if($pending -and $pending.expires -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()){$item=[Windows.Controls.ComboBoxItem]::new();$item.Content=$pending.code+' / '+$pending.extension;$item.Tag=$pending;[void]$routerRequests.Items.Add($item)}}
    if($routerRequests.Items.Count){$routerRequests.SelectedIndex=0};$routerApprove.IsEnabled=$routerRequests.Items.Count -gt 0
}.GetNewClosure()
$routerButtons['Refresh'].Add_Click($routerRefresh)
foreach($label in @('Enable server','Stop server','Open dashboard')){
    $operation=$label
    $routerButtons[$label].Add_Click({
        if($routerContext.Demo){return}
        try{switch($operation){'Enable server'{& $routerCommands['Set-DeckRouterStartup'] $routerContext.Suite ([bool]$routerStartup.IsChecked);& $routerCommands['Start-DeckRouter'] $routerContext.Suite};'Stop server'{& $routerCommands['Stop-DeckRouter'] $routerContext.Suite};'Open dashboard'{& $routerCommands['Open-DeckRouterDashboard'] $routerContext.Suite}};& $routerRefresh}catch{$routerStatus.Text=$_.Exception.Message}
    }.GetNewClosure())
}
$routerApprove.Add_Click({if($routerContext.Demo){return};try{$pending=$routerRequests.SelectedItem.Tag;if($pending){& $routerCommands['Approve-DeckRouterPairing'] $routerContext.Suite $pending.id $pending.code;$routerStatus.Text='Approved. Keep the extension open to complete pairing.'}}catch{$routerStatus.Text=$_.Exception.Message}}.GetNewClosure())
$routerButtons['Install / update server'].Add_Click({
    if($routerContext.Demo -or $routerContext.Task){return}
    try{
        $module=(Join-Path $routerContext.Suite 'Deck.Core.ps1').Replace("'","''");$source=$routerSource.Text.Replace("'","''");$target=$routerContext.Suite.Replace("'","''")
        $startup=if($routerStartup.IsChecked){'$true'}else{'$false'}
        $routerContext.Task=& $routerCommands['Start-DeckTask'] ("`$ErrorActionPreference='Stop'; . '$module'; Install-DeckRouter '$target' '$source' -EnableAtLogin:$startup") 'router-install' ''
        $routerButtons['Install / update server'].IsEnabled=$false;$routerStatus.Text='Installing dependencies and enabling the server...'
    }catch{$routerStatus.Text=$_.Exception.Message}
}.GetNewClosure())
$routerTimer=[Windows.Threading.DispatcherTimer]::new();$routerTimer.Interval=[TimeSpan]::FromSeconds(2);$routerContext.Timer=$routerTimer
$routerTimer.Add_Tick({
    $task=$routerContext.Task
    if($task -and (& $routerCommands['Test-DeckTaskReady'] $task)){
        $message=if($task.Process.ExitCode -eq 0){'Server installed.'}else{& $routerCommands['Get-DeckTaskFailureMessage'] $task}
        & $routerCommands['Dispose-DeckTask'] $task;$routerContext.Task=$null;$routerButtons['Install / update server'].IsEnabled=$true;& $routerRefresh;$routerStatus.Text=$message+' '+$routerStatus.Text
    }elseif(-not $task -and $tabs.SelectedItem -eq $routerTab){& $routerRefresh}
}.GetNewClosure());$routerTimer.Start();& $routerRefresh
$dialog.Add_Closed({$routerContext.Closing=$true;$routerContext.Timer.Stop();if($routerContext.Task){& $routerCommands['Stop-DeckTask'] $routerContext.Task;& $routerCommands['Dispose-DeckTask'] $routerContext.Task;$routerContext.Task=$null}}.GetNewClosure())
