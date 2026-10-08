# Loaded inside Show-DeckSettings. Controls join its existing save transaction.
$harnessTab=[Windows.Controls.TabItem]::new(); $harnessTab.Header='Harnesses'
$harnessScroll=[Windows.Controls.ScrollViewer]::new(); $harnessScroll.VerticalScrollBarVisibility='Auto'; $harnessScroll.HorizontalScrollBarVisibility='Disabled'
$harnessPanel=[Windows.Controls.StackPanel]::new(); $harnessPanel.Margin='2,0,12,0'; $harnessScroll.Content=$harnessPanel; $harnessTab.Content=$harnessScroll
[void]$tabs.Items.Add($harnessTab)
[void]$harnessPanel.Children.Add((New-DeckText 'Coding harnesses' '#EDF1F7' 18))
[void]$harnessPanel.Children.Add((New-DeckText 'Enable a harness, install its CLI, then add an account from Deck or codex-auth. Changes apply to new launches after saving.' '#929CA4'))
$harnessUI=@{}
$harnessContext=@{Suite=$suite;Demo=[bool]($SmokeTest -or $Demo);Window=$dialog}
$harnessCommands=@{}
foreach($name in @('Get-DeckDefaults','Resolve-DeckHarnessExecutable','Get-DeckEntryNames','Get-DeckAccountIdentity','Get-DeckHarnessConfigPath','Start-DeckTask','Test-DeckTaskReady','Stop-DeckTask','Dispose-DeckTask','Get-DeckTaskFailureMessage','Edit-DeckConfig','Open-DeckTerminal')){$harnessCommands[$name]=Get-Command $name -CommandType Function -ErrorAction Stop}
foreach($definition in @(Get-DeckHarnessCatalog)){
    $id=$definition.Id
    $section=[Windows.Controls.StackPanel]::new(); $section.Margin='0,20,0,0'; [void]$harnessPanel.Children.Add($section)
    $enabled=[Windows.Controls.CheckBox]::new(); $enabled.Content=$definition.Name; $enabled.FontSize=15; $enabled.FontWeight='SemiBold'; $enabled.Margin='0,0,0,14'
    $enabled.IsChecked=Test-DeckHarnessEnabled $settings $id; $enabled.IsEnabled=$id -ne 'Codex'
    if($id -eq 'Codex'){$enabled.ToolTip='Codex CLI is always enabled.';$enabled.Opacity=0.5;$enabled.Cursor='Arrow'}else{$controls[('Harness'+$id+'Enabled')]=$enabled}
    [void]$section.Children.Add($enabled)
    $details=[Windows.Controls.StackPanel]::new(); [void]$section.Children.Add($details)
    $providerNote=New-DeckText ('Account sign-in: '+($definition.Providers -join ', ')) '#929CA4'; [void]$details.Children.Add($providerNote)
    $status=New-DeckText '' '#A9E8D5'; [void]$details.Children.Add($status)
    $actions=[Windows.Controls.WrapPanel]::new(); $actions.Margin='0,8,0,10'; [void]$details.Children.Add($actions)
    $install=[Windows.Controls.Button]::new(); $install.Content='Install / update'; [void]$actions.Children.Add($install)
    $info=[Windows.Controls.Button]::new(); $info.Content='How to use'; [void]$actions.Children.Add($info)
    $docs=[Windows.Controls.Button]::new(); $docs.Content='Documentation'; [void]$actions.Children.Add($docs)
    [void]$details.Children.Add((New-DeckText 'CLI executable (optional; blank uses automatic detection)' '#929CA4'))
    $path=[Windows.Controls.TextBox]::new(); $path.Text=$settings[('Harness'+$id+'Path')]; $path.Margin='0,5,0,14'; $controls[('Harness'+$id+'Path')]=$path; [void]$details.Children.Add($path)
    [void]$details.Children.Add((New-DeckText 'Native settings (models, permissions, tools, MCP and more)' '#929CA4'))
    $configActions=[Windows.Controls.WrapPanel]::new(); $configActions.Margin='0,5,0,0'; [void]$details.Children.Add($configActions)
    $accounts=[Windows.Controls.ComboBox]::new(); $accounts.MinWidth=180; $accounts.MaxWidth=300; $accounts.Margin='0,0,8,0'; [void]$configActions.Children.Add($accounts)
    if($id -eq 'Codex'){[void]$accounts.Items.Add('(new-account defaults)')}
    foreach($accountName in @(if($harnessContext.Demo){@()}else{& $harnessCommands['Get-DeckEntryNames'] $suite})){
        if((& $harnessCommands['Get-DeckAccountIdentity'] $suite $accountName).Harness -eq $id){[void]$accounts.Items.Add($accountName)}
    }
    if($accounts.Items.Count){$accounts.SelectedIndex=0}
    $edit=[Windows.Controls.Button]::new(); $edit.Content='Edit all settings'; $edit.IsEnabled=$accounts.Items.Count -gt 0; [void]$configActions.Children.Add($edit)
    $runner=$null
    if($id -eq 'Antigravity'){$runner=[Windows.Controls.Button]::new();$runner.Content='Configure runner (optional)';$runner.ToolTip='New accounts use isolated file login. Configure an existing Windows user only for the runner fallback.';$runner.IsEnabled=$accounts.Items.Count -gt 0;[void]$configActions.Children.Add($runner)}
    $empty=New-DeckText 'Add an account to edit its isolated native settings. Use the native settings command or file shown in its documentation.' '#929CA4'; $empty.Margin='0,6,0,0'; $empty.Visibility=if($accounts.Items.Count){'Collapsed'}else{'Visible'}; [void]$details.Children.Add($empty)
    $card=@{Id=$id;Definition=$definition;Enabled=$enabled;Details=$details;Path=$path;Status=$status;Install=$install;Info=$info;Docs=$docs;Accounts=$accounts;Edit=$edit;Runner=$runner;Task=$null;Timer=$null;Context=$harnessContext;Commands=$harnessCommands}
    $harnessUI[$id]=$card
    $refresh={
        $card.Details.Visibility=if($card.Enabled.IsChecked){'Visible'}else{'Collapsed'}
        $preferences=& $card.Commands['Get-DeckDefaults']; $preferences[('Harness'+$card.Id+'Path')]=$card.Path.Text.Trim()
        try{$executable=& $card.Commands['Resolve-DeckHarnessExecutable'] $preferences $card.Id; $card.Status.Text='Installed: '+$executable}
        catch{$card.Status.Text=$_.Exception.Message}
    }.GetNewClosure()
    $enabled.Add_Click($refresh); $path.Add_LostFocus($refresh); & $refresh
    $docs.Add_Click({Start-Process $card.Definition.Docs}.GetNewClosure())
    $info.Add_Click({
        $help=[Windows.Window]::new(); $help.Title=$card.Definition.Name+' / How to use'; $help.Owner=$card.Context.Window; $help.WindowStartupLocation='CenterOwner'; $help.Width=560; $help.Height=440; $help.Background='#101315'; $help.Foreground='#EAF0FA'; $help.Resources.MergedDictionaries.Add($card.Context.Window.Resources)
        $scroll=[Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'; $help.Content=$scroll
        $body=[Windows.Controls.TextBox]::new(); $body.IsReadOnly=$true; $body.TextWrapping='Wrap'; $body.AcceptsReturn=$true; $body.Margin='20'; $body.Background='#101315'; $body.Foreground='#EAF0FA'; $body.BorderThickness='0'
        $provider=$card.Definition.Providers[0]
        $body.Text=$card.Definition.Name+"`n`nAdd and log in:`ncodex-auth my-account -NewAccount -Harness "+$card.Id+' -Provider '+$provider+"`n`nOpen:`ncodex-auth my-account`n`nLog in again:`ncodex-auth my-account login`n`n"+$card.Definition.Help+"`n`nAccount sign-in and request routing are separate. Codex ChatGPT failover is available today. Cross-provider conversation routing and ChatGPT / Claude / Gemini web adapters are planned and are not active controls. Native provider settings remain available inside each harness."
        $scroll.Content=$body; [void]$help.ShowDialog()
    }.GetNewClosure())
    if($runner){$runner.Add_Click({
        if(-not $card.Context.Demo){& $card.Commands['Open-DeckTerminal'] ([string]$card.Accounts.SelectedItem) -ConfigureRunner}
    }.GetNewClosure())}
    $edit.Add_Click({
        try{
            $selected=[string]$card.Accounts.SelectedItem
            $config=if($selected -eq '(new-account defaults)'){Join-Path $HOME '.codex/config.toml'}else{& $card.Commands['Get-DeckHarnessConfigPath'] $card.Context.Suite $selected}
            & $card.Commands['Edit-DeckConfig'] $config ($card.Definition.Name+' / '+$selected)
        }catch{$card.Status.Text=$_.Exception.Message}
    }.GetNewClosure())
    $install.Add_Click({
        if($card.Context.Demo){$card.Status.Text='Installation is disabled in preview mode.';return}
        if($card.Task){return}
        try{
            $module=(Join-Path $card.Context.Suite 'Deck.Core.ps1').Replace("'","''")
            $code="`$ErrorActionPreference='Stop'; . '$module'; Install-DeckHarness '"+$card.Id+"'"
            $card.Task=& $card.Commands['Start-DeckTask'] $code 'harness-install' $card.Id
            $card.Install.IsEnabled=$false; $card.Install.Content='Installing...'; $card.Status.Text='Downloading and installing '+$card.Definition.Name+'...'
            $timer=[Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[TimeSpan]::FromMilliseconds(250); $card.Timer=$timer
            $timer.Add_Tick({
                $task=$card.Task
                if(-not $task){$card.Timer.Stop();return}
                if(([DateTimeOffset]::UtcNow-$task.Started).TotalMinutes -gt 10){& $card.Commands['Stop-DeckTask'] $task; $card.Timer.Stop(); $card.Status.Text='Installation timed out. See the documentation to install manually.'}
                elseif(-not (& $card.Commands['Test-DeckTaskReady'] $task)){return}
                else{
                    $card.Timer.Stop()
                    if($task.Process.ExitCode -eq 0){$card.Status.Text=($task.Out.Result -split "`r?`n" | Where-Object {$_} | Select-Object -Last 1)}else{$card.Status.Text='Install failed: '+(& $card.Commands['Get-DeckTaskFailureMessage'] $task)}
                }
                & $card.Commands['Dispose-DeckTask'] $task; $card.Task=$null; $card.Install.IsEnabled=$true; $card.Install.Content='Install / update'
            }.GetNewClosure())
            $timer.Start()
        }catch{$card.Status.Text=$_.Exception.Message; $card.Install.IsEnabled=$true; $card.Install.Content='Install / update'}
    }.GetNewClosure())
}
$dialog.Add_Closed({
    foreach($card in $harnessUI.Values){if($card.Timer){$card.Timer.Stop()};if($card.Task){& $card.Commands['Stop-DeckTask'] $card.Task;& $card.Commands['Dispose-DeckTask'] $card.Task;$card.Task=$null}}
}.GetNewClosure())
