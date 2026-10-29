# Loaded inside Show-DeckSettings. Controls join its existing save transaction.
$harnessTab=if($settingsTabRefs.Harnesses){$settingsTabRefs.Harnesses}else{[Windows.Controls.TabItem]::new()}; $harnessTab.Header='Harnesses'; $settingsTabRefs.Harnesses=$harnessTab
$harnessScroll=[Windows.Controls.ScrollViewer]::new(); $harnessScroll.VerticalScrollBarVisibility='Auto'; $harnessScroll.HorizontalScrollBarVisibility='Disabled'
$harnessPanel=[Windows.Controls.StackPanel]::new(); $harnessPanel.Margin='2,0,12,0'; $harnessScroll.Content=$harnessPanel; $harnessTab.Content=$harnessScroll
if(-not $tabs.Items.Contains($harnessTab)){[void]$tabs.Items.Add($harnessTab)}
[void]$harnessPanel.Children.Add((New-DeckText 'Coding harnesses' '#EDF1F7' 18))
[void]$harnessPanel.Children.Add((New-DeckText 'Enable a harness, install its CLI, then add an account from Deck or codex-auth. Changes apply to new launches after saving.' '#929CA4'))
[void]$harnessPanel.Children.Add((New-DeckText 'Dangerous mode skips permission prompts and, where the CLI supports it, removes sandbox restrictions. It applies to every current and future account of that harness.' '#F0C66E'))
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
    $permissions=[Windows.Controls.CheckBox]::new(); $permissions.Content='Enable dangerous automatic permissions for all '+$definition.Name+' accounts'; $permissions.IsChecked=[bool]$settings[('Harness'+$id+'FullPermissions')]; $permissions.Margin='0,0,0,14'; $permissions.ToolTip=switch($id){'Codex'{'Run with danger-full-access and no approval prompts.'} 'Claude'{'Start Claude Code with --dangerously-skip-permissions.'} 'Antigravity'{'Start AGY with --dangerously-skip-permissions; all native tool calls are approved.'} 'OpenCode'{'Start with --auto; automatic approval still honors explicit deny rules.'}}; $controls[('Harness'+$id+'FullPermissions')]=$permissions; [void]$section.Children.Add($permissions)
    $details=[Windows.Controls.StackPanel]::new(); [void]$section.Children.Add($details)
    $headlessFailover=$null;$failoverPool=$null
    if($id -eq 'Antigravity'){
        $headlessFailover=[Windows.Controls.CheckBox]::new();$headlessFailover.Content='Retry quota/provider errors with other AGY accounts for headless prompts';$headlessFailover.IsChecked=[bool]$settings.HarnessAntigravityFailoverEnabled;$headlessFailover.Margin='0,0,0,14';$headlessFailover.ToolTip='Ordered retries run only for agy -p/--print/--prompt. Deck switches profiles only when AGY reports a structured quota/provider failure before any tool or subagent step. Interactive AGY sessions stay on their selected profile.';$controls.HarnessAntigravityFailoverEnabled=$headlessFailover;[void]$details.Children.Add($headlessFailover)
        $poolLabel=New-DeckText 'AGY headless failover profiles (* = all current and future signed-in AGY file profiles)' '#929CA4';$poolLabel.Margin='0,0,0,5';[void]$details.Children.Add($poolLabel)
        $failoverPool=[Windows.Controls.TextBox]::new();$failoverPool.Text=[string]$settings.HarnessAntigravityFailoverAccounts;$failoverPool.Margin='0,0,0,14';$failoverPool.ToolTip='Enter * or comma-separated AGY account names in retry order. Codex, Claude, OpenCode and Windows runner profiles are rejected.';$controls.HarnessAntigravityFailoverAccounts=$failoverPool;[void]$details.Children.Add($failoverPool)
        [void]$details.Children.Add((New-DeckText 'Retry is limited to one-shot headless prompts; native AGY stream output is parsed internally and returned in your requested text, JSON or stream-JSON format.' '#929CA4'))
    }
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
    foreach($accountName in @(if($harnessContext.Demo){@()}else{$settingsLazyState.AccountNames})){
        $identity=if($settingsAccountSnapshot.ContainsKey($accountName)){$settingsAccountSnapshot[$accountName].Identity}else{& $harnessCommands['Get-DeckAccountIdentity'] $suite $accountName}
        if($identity.Harness -eq $id){[void]$accounts.Items.Add($accountName)}
    }
    if($accounts.Items.Count){$accounts.SelectedIndex=0}
    $edit=[Windows.Controls.Button]::new(); $edit.Content='Edit all settings'; $edit.IsEnabled=$accounts.Items.Count -gt 0; [void]$configActions.Children.Add($edit)
    $runner=$null
    if($id -eq 'Antigravity'){$runner=[Windows.Controls.Button]::new();$runner.Content='Configure runner (optional)';$runner.ToolTip='New accounts use isolated file login. Configure an existing Windows user only for the runner fallback.';$runner.IsEnabled=$accounts.Items.Count -gt 0;[void]$configActions.Children.Add($runner)}
    $empty=New-DeckText 'Add an account to edit its isolated native settings. Use the native settings command or file shown in its documentation.' '#929CA4'; $empty.Margin='0,6,0,0'; $empty.Visibility=if($accounts.Items.Count){'Collapsed'}else{'Visible'}; [void]$details.Children.Add($empty)
    $card=@{Id=$id;Definition=$definition;Enabled=$enabled;Details=$details;Path=$path;Status=$status;Install=$install;Info=$info;Docs=$docs;Accounts=$accounts;Edit=$edit;Runner=$runner;Failover=$headlessFailover;FailoverPool=$failoverPool;Task=$null;Timer=$null;Installed=$false;Context=$harnessContext;Commands=$harnessCommands}
    $harnessUI[$id]=$card
    $refresh={
        $card.Details.Visibility=if($card.Enabled.IsChecked){'Visible'}else{'Collapsed'}
        $preferences=& $card.Commands['Get-DeckDefaults']; $preferences[('Harness'+$card.Id+'Path')]=$card.Path.Text.Trim()
        try{
            $executable=& $card.Commands['Resolve-DeckHarnessExecutable'] $preferences $card.Id
            $card.Installed=$true;$card.Install.Content='Update CLI';$card.Status.Text='Installed: '+$executable
        }catch{$card.Installed=$false;$card.Install.Content='Install CLI';$card.Status.Text=$_.Exception.Message}
    }.GetNewClosure()
    $card.Refresh=$refresh
    $enabled.Add_Click($refresh); $path.Add_LostFocus($refresh); & $refresh
    $docs.Add_Click({Start-Process $card.Definition.Docs}.GetNewClosure())
    $info.Add_Click({
        $help=[Windows.Window]::new(); $help.Title=$card.Definition.Name+' / How to use'; $help.Owner=$card.Context.Window; $help.WindowStartupLocation='CenterOwner'; $help.Width=560; $help.Height=440; $help.Background='#101315'; $help.Foreground='#EAF0FA'; $help.Resources.MergedDictionaries.Add($card.Context.Window.Resources)
        $scroll=[Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'; $help.Content=$scroll
        $body=[Windows.Controls.TextBox]::new(); $body.IsReadOnly=$true; $body.TextWrapping='Wrap'; $body.AcceptsReturn=$true; $body.Margin='20'; $body.Background='#101315'; $body.Foreground='#EAF0FA'; $body.BorderThickness='0'
        $provider=$card.Definition.Providers[0]
        $command=switch($card.Id){'Claude'{'claude-auth'} 'Antigravity'{'agy-auth'} default{'codex-auth'}}
        $sample=if($card.Id -in @('Claude','Antigravity')){'account1'}else{'my-account'}
        $create=if($card.Id -in @('Claude','Antigravity')){$command+' '+$sample+' login'}else{'codex-auth '+$sample+' -NewAccount -Harness '+$card.Id+' -Provider '+$provider}
        $check=if($card.Id -eq 'Claude'){$command+' '+$sample+' check'}elseif($card.Id -eq 'Antigravity'){$command+' '+$sample+' check (local credential-file check; use /usage for live limits)'}else{''}
        $body.Text=$card.Definition.Name+"`n`nCreate and sign in:`n"+$create+"`n`nOpen the dashboard:`n"+$command+"`n`nLog in again:`n"+$command+' '+$sample+" login`n"+$(if($check){"`nCheck sign-in:`n$check`n"}else{''})+"`n"+$card.Definition.Help+"`n`nFailover stays within a harness. Codex requests can use Codex accounts; AGY supports ordered retries for eligible headless prompts using AGY accounts. Claude and OpenCode do not have Deck failover. Native provider settings remain available inside each harness."
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
            $operation=if($card.Installed){'Updating'}else{'Installing'}
            $card.Install.IsEnabled=$false; $card.Install.Content=$operation+'...'; $card.Status.Text=$operation+' '+$card.Definition.Name+' in the background. Settings remain responsive.'
            $timer=[Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[TimeSpan]::FromMilliseconds(250); $card.Timer=$timer
            $timer.Add_Tick({
                $task=$card.Task
                if(-not $task){$card.Timer.Stop();return}
                $finished=$false
                try{
                    $elapsed=([DateTimeOffset]::UtcNow-$task.Started)
                    if($elapsed.TotalMinutes -gt 10){
                        & $card.Commands['Stop-DeckTask'] $task
                        $card.Status.Text='Installation timed out after 10 minutes. The worker was stopped; see the documentation to install manually.'
                        $finished=$true
                    }elseif(-not (& $card.Commands['Test-DeckTaskReady'] $task)){
                        $seconds=[int][Math]::Floor($elapsed.TotalSeconds)
                        if($seconds -gt 0 -and $seconds % 5 -eq 0){$card.Status.Text=$operation+' '+$card.Definition.Name+' in the background ('+$seconds+' seconds). Settings remain responsive.'}
                        return
                    }else{
                        $finished=$true
                        if($task.StartError){$card.Status.Text='Install failed: '+$task.StartError}
                        elseif($task.Process.ExitCode -eq 0){
                            $result=($task.Out.Result -split "`r?`n" | Where-Object {$_} | Select-Object -Last 1)
                            & $card.Refresh
                            if($card.Installed){$card.Status.Text=$result}else{$card.Status.Text='Installer completed, but Deck could not locate the CLI. Set its executable path or check the install output: '+$result}
                        }else{$card.Status.Text='Install failed: '+(& $card.Commands['Get-DeckTaskFailureMessage'] $task)}
                    }
                }catch{$finished=$true;$card.Status.Text='Install failed: '+$_.Exception.Message}
                finally{
                    if($finished){
                        $card.Timer.Stop()
                        try{& $card.Commands['Dispose-DeckTask'] $task}catch{}
                        $card.Task=$null;$card.Install.IsEnabled=$true
                        if($card.Installed){$card.Install.Content='Update CLI'}else{$card.Install.Content='Install CLI'}
                    }
                }
            }.GetNewClosure())
            $timer.Start()
        }catch{
            $message=$_.Exception.Message
            if($card.Timer){try{$card.Timer.Stop()}catch{};$card.Timer=$null}
            if($card.Task){try{& $card.Commands['Stop-DeckTask'] $card.Task}catch{};try{& $card.Commands['Dispose-DeckTask'] $card.Task}catch{};$card.Task=$null}
            try{& $card.Refresh}catch{}
            $card.Status.Text='Install failed: '+$message
            $card.Install.IsEnabled=$true
            $card.Install.Content=if($card.Installed){'Update CLI'}else{'Install CLI'}
        }
    }.GetNewClosure())
}
$dialog.Add_Closed({
    foreach($card in $harnessUI.Values){if($card.Timer){$card.Timer.Stop()};if($card.Task){& $card.Commands['Stop-DeckTask'] $card.Task;& $card.Commands['Dispose-DeckTask'] $card.Task;$card.Task=$null}}
}.GetNewClosure())
