param([switch]$SmokeTest, [switch]$Demo, [switch]$Attach, [string]$ScreenshotPath, [switch]$LifecycleTest, [switch]$PreviewExpanded, [ValidateSet('Panel','Widget')][string]$PreviewMode='Widget')
if($LifecycleTest){$Demo=$true}
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
$script:suite = $PSScriptRoot
$script:root = Join-Path $suite 'deck'
$script:settings = if($SmokeTest -or $Demo){Get-DeckDefaults}else{Get-DeckSettings $root}
$script:cache = @{}; $script:nextCheck = @{}; $script:resets = @{}; $script:history = @{}
$script:expandedRows=@{}; $script:profiles=@{}; $script:profileStamps=@{}; $script:cacheVersion=0; $script:lastPicker=[DateTimeOffset]::MinValue
$script:task = $null; $script:lastRequest = [DateTimeOffset]::MinValue
$script:quit = $false; $script:allProfiles = $false
$script:sessions = @(); $script:notice = 'Ready'; $script:lastRender = ''
# Named mutex is user/session scoped. Other launches signal the existing window.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$created = $false
$mutex = [Threading.Mutex]::new($true, "Local\CodexDeck-$sid", [ref]$created)
if (-not $created -and -not $SmokeTest -and -not $Demo) {
    if (-not $Attach) { Write-DeckJson (Join-Path $root 'show.json') @{ At=[DateTimeOffset]::UtcNow.ToString('o') } }
    $mutex.Dispose(); exit
}
if (-not $SmokeTest -and -not $Demo) {
    foreach ($entry in @(Read-DeckJson (Join-Path $root 'cache.json'))) {
        if ($entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') {
            $cache[$entry.Account] = $entry
            if($entry.CheckedAt){$nextCheck[$entry.Account]=Get-DeckNextCheck $settings $entry ([DateTimeOffset]$entry.CheckedAt)}
        }
    }
    foreach ($entry in @(Read-DeckJson (Join-Path $root 'warmup.json'))) {
        if ($entry.Account) { $history[$entry.Account]=$entry }
    }
    foreach ($key in $cache.Keys) {
        $w = $cache[$key].Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
        if ($w.ResetsAtUnix) { $resets[$key]=[long]$w.ResetsAtUnix }
    }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type @'
using System.Runtime.InteropServices;
public static class DeckTaskbarIdentity {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
'@
[void][DeckTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('Codex.Deck')
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $suite 'Deck.Theme.xaml'))
$script:window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$script:appIcon=[Windows.Media.Imaging.BitmapImage]::new([uri](Join-Path $root 'assets/codex-deck.png'))
$window.Icon=$appIcon; $window.FindName('AppLogo').Source=$appIcon
foreach ($name in 'AccountPicker','SettingsButton','LaunchButton','ConfigButton','NewButton','AllButton','CheckButton','Summary','StatusLine','Cards','ModeButton','CloseButton','LaunchBar','ActionBar','Brand','Subtitle','LayoutRoot','Disclaimer','Header') {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}
# Native caption hit testing covers the top padding, logo, text and gaps too.
# The old Header-only mouse handler left the surrounding margin undraggable.
$chrome=[Windows.Shell.WindowChrome]::new(); $chrome.CaptionHeight=54; $chrome.ResizeBorderThickness='5'; $chrome.GlassFrameThickness='0'; $chrome.CornerRadius='10'
[Windows.Shell.WindowChrome]::SetWindowChrome($window,$chrome)
foreach($button in @($ModeButton,$SettingsButton,$CloseButton)) {
    [Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($button,$true)
}
function New-DeckText([string]$Text, [string]$Color='#EAF0FA', [double]$Size=12) {
    $textBlock = [Windows.Controls.TextBlock]::new()
    $textBlock.Text=$Text; $textBlock.Foreground=$Color; $textBlock.FontSize=$Size
    $textBlock.TextWrapping='Wrap'; $textBlock.Margin='0,2,0,0'
    return $textBlock
}
function New-DeckQuotaTrack($Quota,[string]$Color) {
    $grid=[Windows.Controls.Grid]::new(); $grid.Margin='0,6,0,0'
    foreach($width in @('48','*','42')){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$grid.ColumnDefinitions.Add($col)}
    $label=New-DeckText $Quota.Label '#8898AD' 10; $label.VerticalAlignment='Center'; [void]$grid.Children.Add($label)
    $track=[Windows.Controls.Grid]::new(); $track.Height=3; $track.Background='#2A3443'; $track.VerticalAlignment='Center'; $track.Margin='4,0,8,0'
    $value=if($null -eq $Quota.RemainingPct){0}else{[Math]::Max(0,[Math]::Min(100,[double]$Quota.RemainingPct))}
    foreach($width in @($value,(100-$value))){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLength]::new($width,[Windows.GridUnitType]::Star); [void]$track.ColumnDefinitions.Add($col)}
    $fill=[Windows.Controls.Border]::new(); $fill.Background=$Color; $fill.CornerRadius='1.5'; [void]$track.Children.Add($fill)
    [Windows.Controls.Grid]::SetColumn($track,1); [void]$grid.Children.Add($track)
    $percent=if($null -eq $Quota.RemainingPct){'?'}else{[string]$Quota.RemainingPct+'%'}
    $text=New-DeckText $percent $Color 11; $text.TextAlignment='Right'; [Windows.Controls.Grid]::SetColumn($text,2); [void]$grid.Children.Add($text)
    return $grid
}
function Update-DeckWidgetHeight {
    if($widget -and $settings.WidgetAutoHeight){
        $Cards.Measure([Windows.Size]::new(($window.Width-28),[double]::PositiveInfinity))
        $workArea=[Windows.SystemParameters]::WorkArea
        $window.Height=[Math]::Max(150,[Math]::Min($workArea.Height,($Cards.DesiredSize.Height+124)))
        if(-not [double]::IsNaN($window.Top) -and $window.Top+$window.Height -gt $workArea.Bottom){$window.Top=[Math]::Max($workArea.Top,$workArea.Bottom-$window.Height)}
    }
}
function New-DeckExpander([string]$Name,$Header,$Details) {
    $expander=[Windows.Controls.Expander]::new(); $expander.Header=$Header; $expander.Content=$Details
    $expander.IsExpanded=[bool]$expandedRows[$Name]; $expander.Tag=$Name
    $handler={param($sender,$eventArgs)
        $script:expandedRows[[string]$sender.Tag]=$sender.IsExpanded
        # Expansion events precede the template visibility/layout update.
        [void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded,[Action]{Update-DeckWidgetHeight})
    }
    $expander.Add_Expanded($handler); $expander.Add_Collapsed($handler)
    return $expander
}
function New-DeckWidgetCard([string]$Name,$Row,$Profile,[int]$Count) {
    $card=[Windows.Controls.Border]::new(); $card.CornerRadius='6'; $card.Padding=if($settings.Compact){'8,5'}else{'9,6'}; $card.Margin='0,0,0,4'; $card.BorderThickness='1'; $card.BorderBrush='#33373D'; $card.Background=[Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#1C1E22'),[Windows.Media.ColorConverter]::ConvertFromString('#101113'),90)
    $stack=[Windows.Controls.StackPanel]::new(); $card.Child=$stack
    $head=[Windows.Controls.Grid]::new()
    foreach($width in @('14','*','Auto')){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$head.ColumnDefinitions.Add($col)}
    $dot=[Windows.Shapes.Ellipse]::new(); $dot.Width=5; $dot.Height=5; $dot.HorizontalAlignment='Left'; $dot.VerticalAlignment='Center'; $dot.Fill=if($Count){'#69DEC0'}else{'#65738A'}; [void]$head.Children.Add($dot)
    $title=New-DeckText $Name '#E4EBF5' 12; $title.FontWeight='SemiBold'; [Windows.Controls.Grid]::SetColumn($title,1); [void]$head.Children.Add($title)
    $plan=if($Row.PlanType){$Row.PlanType}else{$Profile.PlanType}
    if($settings.ShowPlan){$badge=New-DeckText $(if($plan){$plan.ToUpperInvariant()}else{'?'}) '#8394AD' 9; $badge.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($badge,2); [void]$head.Children.Add($badge)}
    [void]$stack.Children.Add($head)
    if($settings.WidgetShowEmail -and $settings.ShowEmail){
        $email=if($Row.Email){$Row.Email}else{$Profile.Email}; if($settings.MaskEmail){$email=$email -replace '^(.).*(@.*)$','$1***$2'}
        if($email){[void]$stack.Children.Add((New-DeckText $email '#8C9DB4' 10))}
    }
    $stale=-not $Row.CheckedAt -or ([DateTimeOffset]::Now-[DateTimeOffset]$Row.CheckedAt).TotalMinutes -gt ($settings.PollMinutes+2)
    $color=if($stale -or $Row.Status -notin @('available','blocked')){'#DCB675'}elseif($Row.Status -eq 'blocked'){'#F17D8D'}else{'#69DEC0'}
    if($settings.ShowQuota){
        if(-not $Row){[void]$stack.Children.Add((New-DeckText 'Waiting for first check' '#8394AD' 10))}
        elseif($stale){[void]$stack.Children.Add((New-DeckText 'Cached / awaiting update' '#DCB675' 10))}
        elseif($Row.Status -eq 'blocked'){[void]$stack.Children.Add((New-DeckText $(if(@($Row.Windows | Where-Object Dead).Count){'Quota exhausted'}else{'Limit reached'}) '#F17D8D' 10))}
        elseif($Row.Status -ne 'available'){[void]$stack.Children.Add((New-DeckText 'Quota unavailable' '#DCB675' 10))}
        foreach($quota in $Row.Windows){[void]$stack.Children.Add((New-DeckQuotaTrack $quota $color))}
    }
    if($settings.ShowResets -and $settings.WidgetShowResets){
        $parts=@(); $tips=@()
        foreach($quota in $Row.Windows){
            if($quota.ResetsAtUnix){
                $at=[DateTimeOffset]::FromUnixTimeSeconds([long]$quota.ResetsAtUnix).ToLocalTime(); $delta=$at-[DateTimeOffset]::Now
                $short=if($delta.TotalSeconds -le 0){'pending'}elseif($delta.TotalDays -ge 1){'{0}d {1}h' -f [int][Math]::Floor($delta.TotalDays),$delta.Hours}elseif($delta.TotalHours -ge 1){'{0}h {1}m' -f [int][Math]::Floor($delta.TotalHours),$delta.Minutes}else{[Math]::Max(1,[int]$delta.TotalMinutes).ToString()+'m'}
                $parts+=$quota.Label+' '+$short; $tips+=$quota.Label+': '+$at.ToString('ddd dd MMM HH:mm zzz')
            }
        }
        if($parts.Count){$reset=New-DeckText ('Reset  '+($parts -join '  /  ')) '#8293AA' 10; $reset.Margin='0,7,0,0'; $reset.ToolTip=$tips -join "`n"; [void]$stack.Children.Add($reset)}
    }
    if($settings.ShowPlan){$head.Children.RemoveAt($head.Children.Count-1)}
    $parts=@()
    if($settings.ShowQuota){foreach($quota in $Row.Windows){$pct=if($null -eq $quota.RemainingPct){'?'}else{[string]$quota.RemainingPct+'%'}; $parts+=($quota.Label+' '+$pct)}}
    if(-not $parts.Count){$parts+= $(if($Row.Status -eq 'error'){'Check failed'}elseif($Row.Status -eq 'blocked'){'Limit reached'}elseif($Row){$Row.Status}else{'Not checked'})}
    $summary=New-DeckText ($parts -join '  ') $color 10; $summary.TextWrapping='NoWrap'; $summary.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($summary,2); [void]$head.Children.Add($summary)
    $title.TextWrapping='NoWrap'; $title.TextTrimming='CharacterEllipsis'; $title.Margin='0,0,6,0'; $title.FontSize=11
    $stack.Children.Remove($head); $card.Child=$null
    if($settings.ShowPlan -and $plan){$stack.Children.Insert(0,(New-DeckText $plan.ToUpperInvariant() '#8394AD' 10))}
    $card.Child=New-DeckExpander $Name $head $stack
    $card.ToolTip='Connected terminals: '+$Count+'. Quota and connection are separate.'
    return $card
}
function Set-DeckAppearance {
    $window.Topmost=$settings.AlwaysOnTop; $window.Opacity=$settings.OpacityPercent / 100
    $window.FontSize=$settings.FontSize
}
function Set-DeckMode([string]$Mode, [switch]$Initial) {
    if (-not $Initial) {
        if ($script:widget) {$settings.WidgetWidth=[int]$window.Width; $settings.WidgetHeight=[int]$window.Height}
        else {$settings.Width=[int]$window.Width; $settings.Height=[int]$window.Height}
    }
    $script:widget=$Mode -ne 'Panel'; $settings.ViewMode=$Mode
    $visibility=if($widget){'Collapsed'}else{'Visible'}
    foreach($control in @($LaunchBar,$ActionBar,$Subtitle,$Disclaimer,$SettingsButton)){$control.Visibility=$visibility}
    $window.MinWidth=if($widget){280}else{560}; $window.MinHeight=if($widget){150}else{300}
    $window.Width=if($widget){$settings.WidgetWidth}else{[Math]::Max($window.MinWidth,$settings.Width)}
    $window.Height=if($widget){$settings.WidgetHeight}else{$settings.Height}
    $LayoutRoot.Margin=if($widget){'12'}else{'20'}
    $chrome.CaptionHeight=if($widget){54}else{62}
    $Brand.FontSize=if($widget){13}else{17}; $Brand.Margin='0'
    $ModeButton.Content=if($widget){[string][char]0x2197}else{[string][char]0x2199}
    $ModeButton.ToolTip=if($widget){'Open control panel'}else{'Floating widget'}
    $script:lastRender=''
    if(-not $SmokeTest -and -not $Demo){Write-DeckJson (Join-Path $root 'settings.json') $settings}
    if($Mode -eq 'Tray'){$window.Hide()}elseif(-not $Initial){$window.Show(); [void]$window.Activate()}
}
function Get-DeckAccounts {
    if($SmokeTest -or $Demo){return 'account1'}
    @(Get-ChildItem -LiteralPath (Join-Path $suite 'accounts') -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' | Sort-Object @{Expression={if($_.Name -match '^account(\d+)$'){[long]$Matches[1]}else{[long]::MaxValue}}},Name | ForEach-Object Name)
}
function Update-DeckPicker {
    if(([DateTimeOffset]::UtcNow-$lastPicker).TotalSeconds -lt 15){return}
    $script:lastPicker=[DateTimeOffset]::UtcNow
    $names = @(Get-DeckAccounts)
    foreach($name in $names){
        if($SmokeTest -or $Demo){continue}
        $folder=Join-Path $suite "accounts/$name"
        $stamp=([IO.File]::GetLastWriteTimeUtc((Join-Path $folder 'auth.json')).Ticks.ToString())+'/'+[IO.File]::GetLastWriteTimeUtc((Join-Path $folder 'config.toml')).Ticks
        if($profileStamps[$name] -ne $stamp){$profiles[$name]=Get-DeckProfile $suite $name; $profileStamps[$name]=$stamp; $script:lastRender=''}
    }
    if (($names -join ',') -ne (@($AccountPicker.Items | ForEach-Object Tag) -join ',')) {
        $selected=$AccountPicker.SelectedValue; $AccountPicker.Items.Clear()
        $AccountPicker.SelectedValuePath='Tag'
        foreach ($name in $names) { $item=[Windows.Controls.ComboBoxItem]::new(); $item.Tag=$name; [void]$AccountPicker.Items.Add($item) }
        if ($selected -in $names) { $AccountPicker.SelectedValue=$selected }
        elseif ($names.Count) { $AccountPicker.SelectedIndex=0 }
    }
    foreach($item in $AccountPicker.Items){
        $name=[string]$item.Tag
        if(-not $settings.AccountPickerUsage){$item.Content=$name; continue}
        $row=$cache[$name]; $stack=[Windows.Controls.StackPanel]::new()
        [void]$stack.Children.Add((New-DeckText $name '#E4EBF5' 12))
        $usage=[Windows.Controls.TextBlock]::new(); $usage.FontSize=10; $usage.Margin='0,3,0,0'
        foreach($quota in $row.Windows){
            $used=$quota.UsedPct
            if($null -eq $used -and $null -ne $quota.RemainingPct){$used=100-$quota.RemainingPct}
            $label=switch([long]$quota.DurationSeconds){18000 {'5h'} 604800 {'Weekly'} default {$quota.Label}}
            if([long]$quota.DurationSeconds -ge 2419200 -and [long]$quota.DurationSeconds -le 2764800){$label='Monthly'}
            $reset=if($quota.ResetsAtUnix){[DateTimeOffset]::FromUnixTimeSeconds([long]$quota.ResetsAtUnix).ToLocalTime().ToString('dd MMM HH:mm')}else{'reset unknown'}
            $run=[Windows.Documents.Run]::new(('{0} {1} / {2}   ' -f $label,$(if($null -eq $used){'?'}else{('{0:0}%' -f $used)}),$reset))
            $run.Foreground=if($null -eq $used){'#929CA4'}elseif($used -ge 90){'#F17D8D'}elseif($used -ge 70){'#E7B16A'}else{'#69DEC0'}
            [void]$usage.Inlines.Add($run)
        }
        if(-not $usage.Inlines.Count){$usage.Text='Usage unavailable'; $usage.Foreground='#929CA4'}
        $usage.ToolTip='Percentage used / next local reset. Windows are shown as reported by the account.'
        [void]$stack.Children.Add($usage)
        $age='Never'
        if($row.CheckedAt){
            $seconds=[Math]::Max(0,([DateTimeOffset]::Now-[DateTimeOffset]$row.CheckedAt).TotalSeconds)
            $age=if($seconds -ge 2592000){[Math]::Floor($seconds/2592000).ToString()+'mo'}elseif($seconds -ge 604800){[Math]::Floor($seconds/604800).ToString()+'w'}elseif($seconds -ge 86400){[Math]::Floor($seconds/86400).ToString()+'d'}elseif($seconds -ge 3600){[Math]::Floor($seconds/3600).ToString()+'h'}elseif($seconds -ge 60){[Math]::Floor($seconds/60).ToString()+'m'}else{[Math]::Floor($seconds).ToString()+'s'}
        }
        [void]$stack.Children.Add((New-DeckText ('Last checked: '+$age) '#858B92' 9))
        $item.Content=$stack
    }
}
function Select-DeckFolder([string]$InitialFolder, [switch]$TestUI) {
    $picker=[Windows.Window]::new(); $picker.Title='Choose a folder'; $picker.Width=490; $picker.Height=410; $picker.ResizeMode='NoResize'
    if(-not $TestUI){$picker.Owner=$window}; $picker.WindowStartupLocation='CenterOwner'; $picker.Background='#000000'; $picker.Foreground='#EDF1F7'; $picker.Icon=$appIcon
    $picker.Resources.MergedDictionaries.Add($window.Resources)
    $layout=[Windows.Controls.DockPanel]::new(); $layout.Margin='20'; $picker.Content=$layout
    $title=New-DeckText 'Where are we working?' '#EDF1F7' 20; $title.Margin='0,0,0,14'; [Windows.Controls.DockPanel]::SetDock($title,'Top'); [void]$layout.Children.Add($title)
    $pathBox=[Windows.Controls.TextBox]::new(); $pathBox.Text=$InitialFolder; $pathBox.Margin='0,0,0,10'; [Windows.Controls.DockPanel]::SetDock($pathBox,'Top'); [void]$layout.Children.Add($pathBox)
    $shortcuts=[Windows.Controls.WrapPanel]::new(); $shortcuts.Margin='0,0,0,10'; [Windows.Controls.DockPanel]::SetDock($shortcuts,'Top'); [void]$layout.Children.Add($shortcuts)
    $state=@{Path=$null}
    $errorLabel=New-DeckText '' '#EDAA99'; $errorLabel.Margin='0,6,0,6'
    $open=[Windows.Controls.Button]::new(); $open.Content='Use this folder'; $open.IsDefault=$true; $open.Margin='0,10,0,0'
    [Windows.Controls.DockPanel]::SetDock($open,'Bottom'); [void]$layout.Children.Add($open)
    [Windows.Controls.DockPanel]::SetDock($errorLabel,'Bottom'); [void]$layout.Children.Add($errorLabel)
    $list=[Windows.Controls.ListBox]::new(); $list.Background='#111315'; $list.Foreground='#DDE2E7'; $list.BorderBrush='#363C42'; $list.DisplayMemberPath='Name'; [void]$layout.Children.Add($list)
    $navigate={
        $errorLabel.Text=''
        if(Test-Path -LiteralPath $pathBox.Text -PathType Container){
            $list.Items.Clear()
            foreach($dir in @(Get-ChildItem -LiteralPath $pathBox.Text -Directory -ErrorAction SilentlyContinue)){[void]$list.Items.Add($dir)}
        }else{$errorLabel.Text='Enter an existing folder path.'}
    }
    $up=[Windows.Controls.Button]::new(); $up.Content='Up'; $up.Padding='10,6'; [void]$shortcuts.Children.Add($up)
    $up.Add_Click({$parent=Split-Path -Parent $pathBox.Text; if($parent){$pathBox.Text=$parent; & $navigate}})
    foreach($folder in @(@($HOME,$settings.DefaultFolder)+@($sessions | ForEach-Object Folder)) | Select-Object -Unique | Select-Object -First 4){
        if(-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)){continue}
        $quick=[Windows.Controls.Button]::new(); $quick.Content=if($folder -eq $HOME){'Home'}else{Split-Path -Leaf $folder}; $quick.ToolTip=$folder; $quick.Tag=$folder; $quick.Padding='10,6'
        $quick.Add_Click({param($sender,$eventArgs) $pathBox.Text=[string]$sender.Tag; & $navigate}); [void]$shortcuts.Children.Add($quick)
    }
    $pathBox.Add_LostKeyboardFocus({& $navigate})
    $list.Add_MouseDoubleClick({if($list.SelectedItem){$pathBox.Text=$list.SelectedItem.FullName; & $navigate}})
    $open.Add_Click({if(Test-Path -LiteralPath $pathBox.Text -PathType Container){$state.Path=(Get-Item -LiteralPath $pathBox.Text).FullName; $picker.DialogResult=$true}else{$errorLabel.Text='Choose an existing folder to continue.'}})
    $picker.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq 'Escape'){$picker.Close()}})
    & $navigate
    if($TestUI){return @{Dialog=$picker;PathBox=$pathBox;Folders=$list}}
    [void]$picker.ShowDialog()
    return $state.Path
}
function Open-DeckTerminal([string]$Account) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { return }
    $folder=$settings.DefaultFolder
    if($settings.AlwaysAskFolder -or -not (Test-Path -LiteralPath $folder -PathType Container)){$folder=Select-DeckFolder $folder}
    if(-not $folder){return}
    $auth = (Join-Path $HOME '.local/bin/codex-auth.cmd').Replace("'", "''")
    $code = "Set-Location -LiteralPath '" + $folder.Replace("'", "''") + "'; & '$auth' '$Account'"
    Start-Process powershell.exe -ArgumentList ('-NoProfile -NoExit -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) | Out-Null
}
function Edit-DeckConfig([string]$Path, [string]$Label) {
    $original = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $dialog = [Windows.Window]::new(); $dialog.Title="Codex Deck / $Label"; $dialog.Width=760; $dialog.Height=600
    $dialog.Owner=$window; $dialog.WindowStartupLocation='CenterOwner'; $dialog.Background='#000000'; $dialog.Foreground='#EAF0FA'
    $dialog.Icon=$appIcon; $dialog.Resources.MergedDictionaries.Add($window.Resources)
    $dock=[Windows.Controls.DockPanel]::new(); $dock.Margin='16'; $dialog.Content=$dock
    $note=New-DeckText "TOML editor. Changes apply on next launch. Global defaults seed new profiles; existing model choices are preserved. Save creates a backup. Invalid TOML can prevent Codex from starting." '#9BB5D9'
    [Windows.Controls.DockPanel]::SetDock($note,'Top'); [void]$dock.Children.Add($note)
    $save=[Windows.Controls.Button]::new(); $save.Content='Save with backup'; $save.Margin='0,10,0,0'; $save.Padding='10,6'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom'); [void]$dock.Children.Add($save)
    $editor=[Windows.Controls.TextBox]::new(); $editor.Text=$original; $editor.AcceptsReturn=$true; $editor.AcceptsTab=$true
    $editor.VerticalScrollBarVisibility='Auto'; $editor.HorizontalScrollBarVisibility='Auto'; $editor.FontFamily='Consolas'
    $editor.Background='#192232'; $editor.Foreground='#EAF0FA'; $editor.Margin='0,12,0,0'; [void]$dock.Children.Add($editor)
    $save.Add_Click({
        try {
            $current=if(Test-Path -LiteralPath $Path){[IO.File]::ReadAllText($Path)}else{''}
            if ($current -cne $original) { throw 'This file changed outside the editor. Close and reopen it before saving.' }
            if ($editor.Text -ceq $original) { $dialog.Close(); return }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
            if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination ($Path+'.bak-deck-'+[guid]::NewGuid().ToString('N')) }
            [IO.File]::WriteAllText($Path,$editor.Text,[Text.UTF8Encoding]::new($false))
            $dialog.Close()
        } catch { [void][Windows.MessageBox]::Show($dialog,$_.Exception.Message,'Could not save') }
    }.GetNewClosure())
    [void]$dialog.ShowDialog()
}
function Show-DeckSettings {
    param([switch]$TestUI)
    $dialog=[Windows.Window]::new(); $dialog.Title='Codex Deck / Settings'; $dialog.Width=600; $dialog.Height=640; $dialog.MinWidth=540; $dialog.MinHeight=440
    if(-not $TestUI){$dialog.Owner=$window}; $dialog.WindowStartupLocation='CenterOwner'; $dialog.Background='#000000'; $dialog.Foreground='#EAF0FA'
    $dialog.Icon=$appIcon; $dialog.Resources.MergedDictionaries.Add($window.Resources)
    $dock=[Windows.Controls.DockPanel]::new(); $dock.Margin='18'; $dialog.Content=$dock
    $save=[Windows.Controls.Button]::new(); $save.Content='Save settings'; $save.Padding='12,8'; $save.Margin='0,12,0,0'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom'); [void]$dock.Children.Add($save)
    $heading=New-DeckText 'Settings' '#EDF1F7' 22; $heading.Margin='0,0,0,5'
    [Windows.Controls.DockPanel]::SetDock($heading,'Top'); [void]$dock.Children.Add($heading)
    $intro=New-DeckText 'Make Deck feel at home.' '#929CA4'; $intro.Margin='0,0,0,20'
    [Windows.Controls.DockPanel]::SetDock($intro,'Top'); [void]$dock.Children.Add($intro)
    $tabs=[Windows.Controls.TabControl]::new(); [void]$dock.Children.Add($tabs)
    $groups=[ordered]@{
        Appearance=@('ViewMode','Compact','AlwaysOnTop','CloseToTray','AutoStart','OpacityPercent','FontSize','DefaultFolder','AlwaysAskFolder')
        Details=@('AccountPickerUsage','MaskEmail','ShowEmail','ShowPlan','ShowQuota','ShowResets','ShowSessionCount','ShowUptime','ShowModel','ShowProcessIds','ShowFolder','ShowSource','ShowCheckedAt','ShowCredits','ShowWarmup','WidgetShowEmail','WidgetShowResets','WidgetAutoHeight')
        Checks=@('AutoCheck','PollMinutes','MinimumGapSeconds')
        'Usage Warmup'=@('WarmupEnabled','WarmupAccounts','WarmupModel','WarmupGraceSeconds','WarmupMaxDelayMinutes')
    }
    $descriptions=@{Appearance='Window behavior and reading comfort';Details='Choose what appears in expanded account entries and the widget';Checks='Automatic checks and request spacing. Check also works manually.';'Usage Warmup'='Choose accounts and a model for scheduled warm-up requests.'}
    $labels=@{AccountPickerUsage='Usage and reset times in account picker';DefaultFolder='Terminal start folder';AlwaysAskFolder='Always ask where to open the terminal';ViewMode='Default view';Compact='Compact entries';AlwaysOnTop='Keep Deck above other windows';CloseToTray='Close to the tray';AutoStart='Start Deck with account terminals';OpacityPercent='Window opacity (%)';FontSize='Text size';AutoCheck='Enable automatic checks';PollMinutes='Check interval (minutes)';MinimumGapSeconds='Time between requests (seconds)';WarmupEnabled='Enable scheduled warm-up';WarmupAccounts='Accounts (comma-separated names)';WarmupModel='Model / low reasoning effort';WarmupGraceSeconds='Wait after quota reset (seconds)';WarmupMaxDelayMinutes='Warm-up window after reset (minutes)';WidgetAutoHeight='Fit widget height to content';WidgetShowEmail='Email in widget';WidgetShowResets='Reset times in widget';ShowCheckedAt='Last check time';ShowProcessIds='Process IDs';ShowSessionCount='Terminal count'}
    $panels=@{}; $controls=@{}
    foreach($group in $groups.Keys){
        $tab=[Windows.Controls.TabItem]::new(); $tab.Header=$group
        $scroll=[Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'
        $panel=[Windows.Controls.StackPanel]::new(); $panel.Margin='2,0,12,0'; $scroll.Content=$panel; $tab.Content=$scroll
        $description=New-DeckText $descriptions[$group] '#929CA4'; $description.Margin='0,0,0,20'; [void]$panel.Children.Add($description)
        $panels[$group]=$panel; [void]$tabs.Items.Add($tab)
    }
    foreach ($key in $settings.Keys) {
        if ($key -in @('Width','Height','WidgetWidth','WidgetHeight')) { continue }
        $group=@($groups.Keys | Where-Object { $key -in $groups[$_] })[0]
        if(-not $group){$group='Appearance'}
        $panel=$panels[$group]
        $caption=if($labels.ContainsKey($key)){$labels[$key]}else{(($key -replace '^Show','') -creplace '([a-z])([A-Z])','$1 $2')}
        if ($settings[$key] -is [bool]) {
            $control=[Windows.Controls.CheckBox]::new(); $control.Content=$caption; $control.IsChecked=$settings[$key]
            $control.Foreground='#EAF0FA'; $control.Margin='0,0,0,14'; $control.MinHeight=24
        } else {
            $label=New-DeckText $caption '#A2ADB5'; $label.Margin='0,2,0,6'; [void]$panel.Children.Add($label)
            if($key -eq 'WarmupModel'){
                $control=[Windows.Controls.ComboBox]::new()
                $cachedModels=Read-DeckJson (Join-Path $root 'models.json')
                foreach($model in @(Get-DeckModelNames @($settings.WarmupModel,'gpt-5.6-luna',$cachedModels.Models))){[void]$control.Items.Add([string]$model)}
                $control.SelectedItem=$settings.WarmupModel; $control.ToolTip='Warm-up uses low reasoning effort. Loading models from Codex...'
            }elseif($key -eq 'ViewMode'){$control=[Windows.Controls.ComboBox]::new(); foreach($mode in @('Panel','Widget','Tray')){[void]$control.Items.Add($mode)}; $control.SelectedItem=$settings[$key]}else{$control=[Windows.Controls.TextBox]::new(); $control.Text=[string]$settings[$key]}
            $control.Margin='0,0,10,16'; $control.MinHeight=34
        }
        $controls[$key]=$control; [void]$panel.Children.Add($control)
    }
    $save.Add_Click({
        try {
            $updated=Get-DeckDefaults
            foreach ($key in $settings.Keys) {
                if (-not $controls.ContainsKey($key)) { $updated[$key]=$settings[$key]; continue }
                if ($settings[$key] -is [bool]) { $updated[$key]=[bool]$controls[$key].IsChecked }
                elseif ($key -in @('WarmupModel','ViewMode')) { $updated[$key]=[string]$controls[$key].SelectedItem }
                elseif ($settings[$key] -is [int]) { $updated[$key]=[int]$controls[$key].Text }
                else { $updated[$key]=$controls[$key].Text.Trim() }
            }
            if(-not $updated.AlwaysAskFolder -and -not (Test-Path -LiteralPath $updated.DefaultFolder -PathType Container)){throw 'Choose an existing terminal start folder, or enable Always ask.'}
            if ($updated.WarmupModel -notmatch '^gpt-[a-zA-Z0-9.-]+$') { throw 'Enter a model ID, e.g. gpt-5.6-luna.' }
            if ($updated.ViewMode -notin @('Panel','Widget','Tray')) { throw 'View Mode must be Panel, Widget, or Tray.' }
            foreach ($name in @($updated.WarmupAccounts -split '[,;\s]+' | Where-Object { $_ })) {
                if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -notin @(Get-DeckAccounts)) { throw "Unknown warm-up account: $name" }
            }
            if ($updated.WarmupEnabled -and -not $updated.WarmupAccounts) { throw 'Choose warm-up accounts (comma-separated account names).' }
            if ($updated.WarmupEnabled -and -not $settings.WarmupEnabled) {
                if ([Windows.MessageBox]::Show($dialog,'Enable real, quota-consuming automatic requests for the selected paid accounts?','Enable warm-up','YesNo','Warning') -ne 'Yes') { return }
            }
            Write-DeckJson (Join-Path $root 'settings.json') $updated
            if(-not $updated.AutoCheck){$script:pendingWarm=$null}
            foreach($account in @($nextCheck.Keys)){if($cache[$account].CheckedAt){$nextCheck[$account]=Get-DeckNextCheck $updated $cache[$account] ([DateTimeOffset]$cache[$account].CheckedAt)}}
            if($updated.Compact -and -not $settings.Compact){$script:expandedRows=@{}}
            $script:settings=Get-DeckSettings $root; Set-DeckAppearance; Set-DeckMode $settings.ViewMode; $script:lastRender=''; $dialog.Close()
        } catch { [void][Windows.MessageBox]::Show($dialog,$_.Exception.Message,'Settings not saved') }
    })
    if($TestUI){return @{Dialog=$dialog;Controls=$controls;Panel=$panel}}
    $modelState=@{Task=$null}
    $modelTimer=[Windows.Threading.DispatcherTimer]::new(); $modelTimer.Interval=[TimeSpan]::FromMilliseconds(250)
    $modelTimer.Add_Tick({
        $worker=$modelState.Task
        if(-not $worker){return}
        if(([DateTimeOffset]::UtcNow-$worker.Started).TotalSeconds -gt 30){Stop-DeckTask $worker}
        if(-not $worker.Process.HasExited){return}
        $modelTimer.Stop()
        try{
            if($worker.Process.ExitCode -ne 0){throw 'Model list unavailable'}
            $decoded=$worker.Out.Result | ConvertFrom-Json
            $models=@(Get-DeckModelNames $decoded)
            if(-not $models.Count){throw 'Empty model list'}
            $picker=$controls.WarmupModel; $selected=[string]$picker.SelectedItem
            $picker.Items.Clear()
            foreach($model in @(Get-DeckModelNames @($selected,'gpt-5.6-luna',$models))){[void]$picker.Items.Add($model)}
            $picker.SelectedItem=$selected; $picker.ToolTip='Models from Codex. Warm-up uses low reasoning effort.'
            Write-DeckJson (Join-Path $root 'models.json') @{Models=$models;CheckedAt=[DateTimeOffset]::Now.ToString('o')}
        }catch{$controls.WarmupModel.ToolTip='Model list unavailable; showing saved choices. Warm-up uses low reasoning effort.'}
        finally{$worker.Process.Dispose(); $modelState.Task=$null}
    })
    try{
        $modelAccount=[string]$AccountPicker.SelectedValue
        if(-not $modelAccount){$modelAccount=@(Get-DeckAccounts)[0]}
        if($modelAccount){$modelState.Task=Start-DeckTask (Get-DeckModelsCode $suite $modelAccount) 'Models' $modelAccount; $modelTimer.Start()}
        [void]$dialog.ShowDialog()
    }finally{$modelTimer.Stop(); if($modelState.Task){Stop-DeckTask $modelState.Task; $modelState.Task.Process.Dispose()}}
}
function Render-Deck {
    $names = @($sessions | ForEach-Object Account | Select-Object -Unique)
    if ($allProfiles -and -not $widget) { $names=@(Get-DeckAccounts) }
    $names=@($names | Sort-Object @{Expression={if($_ -match '^account(\d+)$'){[long]$Matches[1]}else{[long]::MaxValue}}},{$_})
    $Summary.Text="{0} connected accounts  /  {1} terminals  /  warm-up {2}" -f @($sessions | ForEach-Object Account | Select-Object -Unique).Count,$sessions.Count,$(if($settings.WarmupEnabled){'on'}else{'off'})
    if($widget){$Summary.Text="{0} online  /  {1} terminals" -f $names.Count,$sessions.Count}
    $StatusLine.Text = if ($task) { "$($task.Kind): $($task.Account)..." } else { $(if($settings.AutoCheck){"$notice / auto-check every $($settings.PollMinutes)m"}else{"$notice / auto-check off"}) }
    if($widget -and -not $task){$StatusLine.Text='Checks '+$(if($settings.AutoCheck){'on'}else{'off'})+'  /  warm-up '+$(if($settings.WarmupEnabled){'on'}else{'off'})}
    $signature=($names -join ',') + (($sessions | ForEach-Object ProcessId) -join ',') + '/' + $cacheVersion + '/' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmm') + $allProfiles + '/' + ($manualChecks.Keys -join ',') + '/' + $task.Account
    if ($signature -eq $lastRender) { return }
    $script:lastRender=$signature; $Cards.Children.Clear()
    if (-not $names.Count) {
        [void]$Cards.Children.Add((New-DeckText 'Your deck is clear. Pick an account and launch a terminal. Already-running sessions attach after their next codex-auth launch.' '#9BB5D9' 14)); return
    }
    foreach ($name in $names) {
        $connected=@($sessions | Where-Object Account -eq $name); $row=$cache[$name]
        $profile=$profiles[$name]
        if($widget){[void]$Cards.Children.Add((New-DeckWidgetCard $name $row $profile $connected.Count)); continue}
        $plan=if($row.PlanType){$row.PlanType}else{$profile.PlanType}
        $displayEmail=if($row.Email){$row.Email}else{$profile.Email}
        $card=[Windows.Controls.Border]::new(); $card.CornerRadius='6'; $card.Margin='0,0,0,5'; $card.Padding=if($settings.Compact){'8,5'}else{'10,8'}
        $card.Background=[Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#1C1E22'),[Windows.Media.ColorConverter]::ConvertFromString('#101113'),90)
        $card.BorderBrush=[Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#383B40'),[Windows.Media.ColorConverter]::ConvertFromString('#202226'),90); $card.BorderThickness='1'
        $grid=[Windows.Controls.Grid]::new(); $card.Child=$grid
        foreach($width in @('12','90','*','Auto')){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$grid.ColumnDefinitions.Add($col)}
        $dot=New-DeckText ([string][char]0x25CF) $(if($connected.Count){'#69DEC0'}else{'#60646B'}) 9
        $dot.VerticalAlignment='Center'; [void]$grid.Children.Add($dot)
        $title=New-DeckText $name '#E4E7EC' $settings.FontSize; $title.FontWeight='SemiBold'; $title.VerticalAlignment='Center'; $title.TextWrapping='NoWrap'; $title.TextTrimming='CharacterEllipsis'; $title.ToolTip=$name; [Windows.Controls.Grid]::SetColumn($title,1); [void]$grid.Children.Add($title)
        $meta=@(); if($settings.ShowPlan){$meta+=$(if($plan){$plan.ToUpperInvariant()}else{'?'})}
        if($settings.ShowEmail -and $displayEmail){$email=$displayEmail; if($settings.MaskEmail){$email=$email -replace '^(.).*(@.*)$','$1***$2'}; $meta+=$email}
        $info=New-DeckText ($meta -join '  /  ') '#858B95' ($settings.FontSize-1); $info.TextWrapping='NoWrap'; $info.TextTrimming='CharacterEllipsis'; $info.Margin='0,0,12,0'; $info.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($info,2); [void]$grid.Children.Add($info)
        $stale=-not $row.CheckedAt -or ([DateTimeOffset]::Now-[DateTimeOffset]$row.CheckedAt).TotalMinutes -gt ($settings.PollMinutes+2)
        $status=if($task -and $task.Account -eq $name){'Checking...'}elseif($manualChecks.ContainsKey($name)){'Queued'}elseif(-not $row){'Not checked'}elseif($row.Status -eq 'error'){'Check failed'}elseif($stale){'Cached'}elseif($row.Status -eq 'blocked'){if(@($row.Windows | Where-Object Dead).Count){'Quota exhausted'}else{'Limit reached'}}elseif($row.Status -eq 'available'){'Ready'}else{'Unknown'}
        $quotaColor=if($stale){'#DCB675'}elseif($row.Status -eq 'blocked'){'#F17D8D'}elseif($row.Status -eq 'available'){'#69DEC0'}else{'#DCB675'}
        $quota=@($status)
        if($settings.ShowQuota){foreach($w in $row.Windows){$pct=if($null -eq $w.RemainingPct){'?'}else{[string]$w.RemainingPct+'%'}; $quota+=($w.Label+' '+$pct)} }
        $text=New-DeckText ($quota -join '   ') $quotaColor ($settings.FontSize-1); $text.TextWrapping='NoWrap'; $text.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($text,3); [void]$grid.Children.Add($text)
        $details=@()
        if($settings.ShowModel){$details+=$profile.Model+' / '+$profile.Effort}
        if($settings.ShowUptime -and $connected.Count){$start=($connected | Sort-Object StartedAt | Select-Object -First 1).StartedAt; $details+='Open '+[int]([DateTimeOffset]::Now-[DateTimeOffset]$start).TotalMinutes+'m'}
        if($settings.ShowProcessIds -and $connected.Count){$details+='PID '+(($connected | ForEach-Object ProcessId)-join ',')}
        if($settings.ShowSource -and $row.Source){$details+='via '+$row.Source}
        if($settings.ShowCheckedAt -and $row.CheckedAt){$details+='checked '+([DateTimeOffset]$row.CheckedAt).ToLocalTime().ToString('HH:mm')}
        if($settings.ShowCredits -and $null -ne $row.Credits){$details+='Credits '+($row.Credits | ConvertTo-Json -Compress)}
        if($settings.ShowWarmup -and $history[$name]){$details+='warm-up: '+$history[$name].Outcome}
        $tips=@($name,($meta -join ' / '),($connected.Count.ToString()+' connected terminals'), 'Percentages show quota remaining.')
        if($settings.ShowResets){foreach($w in $row.Windows){if($w.ResetsAtUnix){$tips+=($w.Label+' resets '+[DateTimeOffset]::FromUnixTimeSeconds([long]$w.ResetsAtUnix).ToLocalTime().ToString('ddd dd MMM HH:mm'))}}}
        $tips+=$details
        if($settings.ShowFolder){$tips+=@($connected | ForEach-Object Folder | Select-Object -Unique)}
        if($row.Error){$tips+=$row.Error}
        $card.ToolTip=$tips -join "`n"
        $detailPanel=[Windows.Controls.StackPanel]::new(); $detailPanel.Margin='12,2,12,6'
        $divider=[Windows.Controls.Border]::new(); $divider.Height=1; $divider.Background='#30343A'; $divider.Margin='0,0,0,10'; [void]$detailPanel.Children.Add($divider)
        if($settings.ShowQuota){foreach($w in $row.Windows){[void]$detailPanel.Children.Add((New-DeckQuotaTrack $w $quotaColor))}}
        $fields=[ordered]@{}
        $fields['Status']=$status
        if($settings.ShowEmail){$fields['Email']=if($displayEmail){if($settings.MaskEmail){$displayEmail -replace '^(.).*(@.*)$','$1***$2'}else{$displayEmail}}else{'Unavailable'}}
        if($settings.ShowPlan){$fields['Plan']=if($plan){$plan}else{'Unavailable'}}
        if($settings.ShowSessionCount){$fields['Terminals']=[string]$connected.Count}
        if($settings.ShowModel){$fields['Model']=$profile.Model+' / '+$profile.Effort}
        if($settings.ShowUptime -and $connected.Count){$fields['Uptime']=[string][int]([DateTimeOffset]::Now-[DateTimeOffset]($connected | Sort-Object StartedAt | Select-Object -First 1).StartedAt).TotalMinutes+' min'}
        if($settings.ShowResets){foreach($w in $row.Windows){if($w.ResetsAtUnix){$fields[$w.Label+' reset']=[DateTimeOffset]::FromUnixTimeSeconds([long]$w.ResetsAtUnix).ToLocalTime().ToString('ddd dd MMM · HH:mm')}}}
        if($settings.ShowCheckedAt){$fields['Last check']=if($row.CheckedAt){([DateTimeOffset]$row.CheckedAt).ToLocalTime().ToString('dd MMM · HH:mm')}else{'Not checked'}}
        if($settings.ShowSource){$fields['Source']=if($row.Source){$row.Source}else{'Not checked'}}
        if($settings.ShowProcessIds){$fields['Process IDs']=($connected | ForEach-Object ProcessId)-join ', '}
        if($settings.ShowFolder){$fields['Folders']=($connected | ForEach-Object Folder | Select-Object -Unique)-join "`n"}
        if($settings.ShowWarmup){$fields['Warm-up']=if($history[$name]){$history[$name].Outcome}elseif($settings.WarmupEnabled){'Enabled / no attempts'}else{'Off / no attempts'}}
        if($settings.ShowCredits){$fields['Credits']=if($null -ne $row.Credits){($row.Credits.PSObject.Properties | ForEach-Object { $_.Name+': '+$_.Value }) -join ' · '}else{'Not provided by Codex'}}
        if($row.Error){$fields['Check error']=$row.Error}
        foreach($key in $fields.Keys){
            if([string]::IsNullOrWhiteSpace([string]$fields[$key])){$fields[$key]='Unavailable'}
            $line=[Windows.Controls.Grid]::new(); $line.Margin='0,4,0,4'
            $col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLength]::new(108); [void]$line.ColumnDefinitions.Add($col)
            [void]$line.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
            [void]$line.Children.Add((New-DeckText $key '#7F8997' 11))
            $value=New-DeckText ([string]$fields[$key]) '#C8D0DB' 11; [Windows.Controls.Grid]::SetColumn($value,1); [void]$line.Children.Add($value)
            [void]$detailPanel.Children.Add($line)
        }
        $card.Child=$null; $card.Child=New-DeckExpander $name $grid $detailPanel
        [void]$Cards.Children.Add($card)
    }
    Update-DeckWidgetHeight
}
function Invoke-DeckTick {
    if($SmokeTest -or $Demo){Render-Deck; return}
    $script:sessions=@(Get-DeckSessions $root); Update-DeckPicker
    $signal=Join-Path $root 'show.json'
    if(Test-Path -LiteralPath $signal){Remove-Item -LiteralPath $signal -ErrorAction SilentlyContinue; $window.Show(); $window.WindowState='Normal'; [void]$window.Activate()}
    $now=[DateTimeOffset]::UtcNow; $unix=$now.ToUnixTimeSeconds()
    if($task){
        $timeout=($now-$task.Started).TotalSeconds -gt 120
        if($timeout){Stop-DeckTask $task}
        if($task.Process.HasExited){
            $account=$task.Account; $success=(-not $timeout -and $task.Process.ExitCode -eq 0)
            if($task.Kind -eq 'Check'){
                try{
                    if(-not $success){throw 'Check process failed or timed out.'}
                    $result=@($task.Out.Result | ConvertFrom-Json)[0]
                    if($result.Account -ne $account){throw 'Unexpected account in response.'}
                    $result | Add-Member NoteProperty CheckedAt $now.ToString('o') -Force
                    $cache[$account]=$result
                    $script:cacheVersion++
                    $previous=$resets[$account]
                    $five=$result.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
                    # Warm-up is evaluated only from a fresh successful check, never stale disk data.
                    $eligible= @($sessions | Where-Object Account -eq $account).Count -gt 0 -and (Test-DeckWarmup $settings $result $previous $history[$account] $unix)
                    if($eligible){$script:pendingWarm=@{Account=$account; Reset=$previous; Record=$result; At=$unix}}
                    if($five.ResetsAtUnix -and [long]$five.ResetsAtUnix -gt $unix -and (-not $previous -or $five.UsedPct -gt 0 -or $unix -gt ([long]$previous+3600))){$resets[$account]=[long]$five.ResetsAtUnix}
                    $nextCheck[$account]=Get-DeckNextCheck $settings $result $now
                    Write-DeckJson (Join-Path $root 'cache.json') @($cache.Values)
                    $script:notice="Updated $account at $($now.ToLocalTime().ToString('HH:mm'))"
                }catch{
                    $nextCheck[$account]=$now.AddMinutes(20); $script:notice="Check failed: $account (20m backoff)"
                    $cache[$account]=[pscustomobject]@{Account=$account;Status='error';CheckedAt=$now.ToString('o');Windows=@();Error=$_.Exception.Message}
                    $script:cacheVersion++; Write-DeckJson (Join-Path $root 'cache.json') @($cache.Values)
                }
            }else{
                $history[$account].Outcome=if($success){'sent'}elseif($timeout){'timed out / no retry'}else{'failed / no retry'}
                Write-DeckJson (Join-Path $root 'warmup.json') @($history.Values)
                $nextCheck[$account]=$now.AddSeconds(60); $script:notice="Warm-up $account : $($history[$account].Outcome)"
            }
            $task.Process.Dispose(); $script:task=$null; $script:lastRender=''
        }
    }
    if(-not $task -and ($settings.AutoCheck -or $manualChecks.Count) -and ($now-$lastRequest).TotalSeconds -ge $settings.MinimumGapSeconds){
        if($script:pendingWarm -and $settings.AutoCheck){
            $pending=$script:pendingWarm; $script:pendingWarm=$null; $account=$pending.Account
            if(($unix-$pending.At) -lt 120 -and @($sessions | Where-Object Account -eq $account).Count -and (Test-DeckWarmup $settings $pending.Record $pending.Reset $history[$account] $unix)){
                # Persist BEFORE sending: crashes/restarts must never duplicate a request.
                $history[$account]=[pscustomobject]@{Account=$account; Reset=$pending.Reset; AttemptAt=$unix; Outcome='attempted / result pending'}
                Write-DeckJson (Join-Path $root 'warmup.json') @($history.Values)
                $script:task=Start-DeckTask (Get-DeckWarmupCode $suite $account $settings.WarmupModel) 'Warm-up' $account
                $script:lastRequest=$now
            }
        }
        if(-not $task){
            $automatic=@(); if($settings.AutoCheck){$automatic=@($sessions | ForEach-Object Account | Select-Object -Unique); if($allProfiles -and -not $widget){$automatic=@(Get-DeckAccounts)}}
            $due=@(Get-DeckDueAccounts $automatic $manualChecks $nextCheck $now)
            if($due.Count){$account=$due[0]; $script:task=Start-DeckTask (Get-DeckCheckCode $suite $account) 'Check' $account; $manualChecks.Remove($account); $script:lastRequest=$now}

        }
    }
    Render-Deck
}
$script:manualChecks=@{}
$script:pendingWarm=$null
$script:widget=$false
$ModeButton.Add_Click({Set-DeckMode $(if($widget){'Panel'}else{'Widget'}); Render-Deck})
$CloseButton.Add_Click({$window.Close()})
$LaunchButton.Add_Click({Open-DeckTerminal ([string]$AccountPicker.SelectedValue)})
$configMenu=[Windows.Controls.ContextMenu]::new()
$configMenu.Resources=$window.Resources
$accountConfigItem=[Windows.Controls.MenuItem]::new(); $accountConfigItem.Header='Account config'
$defaultsItem=[Windows.Controls.MenuItem]::new(); $defaultsItem.Header='Global defaults'; $defaultsItem.ToolTip='Template for new accounts; not the selected account.'
[void]$configMenu.Items.Add($accountConfigItem); [void]$configMenu.Items.Add($defaultsItem)
$ConfigButton.ContextMenu=$configMenu
$ConfigButton.Add_Click({
    $accountConfigItem.IsEnabled=$null -ne $AccountPicker.SelectedValue
    $accountConfigItem.ToolTip='Configuration for '+[string]$AccountPicker.SelectedValue
    $configMenu.PlacementTarget=$ConfigButton; $configMenu.Placement='Bottom'; $configMenu.IsOpen=$true
})
$accountConfigItem.Add_Click({if($AccountPicker.SelectedValue){Edit-DeckConfig (Join-Path $suite ('accounts/'+$AccountPicker.SelectedValue+'/config.toml')) ([string]$AccountPicker.SelectedValue)}})
$defaultsItem.Add_Click({Edit-DeckConfig (Join-Path $HOME '.codex/config.toml') 'Global defaults'})
$SettingsButton.Add_Click({Show-DeckSettings})
$AllButton.Add_Click({$script:allProfiles=-not $allProfiles; $AllButton.Content=if($allProfiles){'Connected only'}else{'Show all'}; $script:lastRender=''; Render-Deck})
$CheckButton.ToolTip='Check visible accounts. Show all includes disconnected profiles. Requests are staggered.'
$CheckButton.Add_Click({
    $names=@($sessions | ForEach-Object Account | Select-Object -Unique)
    if($allProfiles -and -not $widget){$names=@(Get-DeckAccounts)}
    $now=[DateTimeOffset]::UtcNow
    foreach($name in $names){
        if($task -and $task.Account -eq $name){continue}
        $at=$cache[$name].CheckedAt
        $manualChecks[$name]=if($at){$earliest=([DateTimeOffset]$at).AddSeconds(60); if($earliest -gt $now){$earliest}else{$now}}else{$now}
    }
    $script:notice="Check queued: $($manualChecks.Count) accounts"; $script:lastRender=''; Render-Deck
})
$NewButton.Add_Click({
    $names=@(Get-DeckAccounts); $number=1
    while("account$number" -in $names){$number++}
    $dialog=[Windows.Window]::new(); $dialog.Owner=$window; $dialog.WindowStartupLocation='CenterOwner'
    $dialog.WindowStyle='None'; $dialog.ResizeMode='NoResize'; $dialog.Width=380; $dialog.SizeToContent='Height'
    $dialog.Background='#101113'; $dialog.Foreground='#E4E7EC'; $dialog.Icon=$appIcon; $dialog.Resources.MergedDictionaries.Add($window.Resources)
    $panel=[Windows.Controls.StackPanel]::new(); $panel.Margin='22'; $dialog.Content=$panel
    $heading=[Windows.Controls.StackPanel]::new(); $heading.Orientation='Horizontal'; $logo=[Windows.Controls.Image]::new(); $logo.Source=$appIcon; $logo.Width=24; $logo.Height=24; $logo.Margin='0,0,10,0'; [void]$heading.Children.Add($logo); [void]$heading.Children.Add((New-DeckText 'New account' '#E4E7EC' 17)); [void]$panel.Children.Add($heading)
    $label=New-DeckText 'Choose a name for this account.' '#919BA8' 12; $label.Margin='0,10,0,10'; [void]$panel.Children.Add($label)
    $input=[Windows.Controls.TextBox]::new(); $input.Text="account$number"; [void]$panel.Children.Add($input)
    $errorText=New-DeckText '' '#F17D8D' 11; $errorText.Margin='0,8,0,8'; [void]$panel.Children.Add($errorText)
    $buttons=[Windows.Controls.StackPanel]::new(); $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'; [void]$panel.Children.Add($buttons)
    $cancel=[Windows.Controls.Button]::new(); $cancel.Content='Cancel'; $cancel.IsCancel=$true; [void]$buttons.Children.Add($cancel)
    $create=[Windows.Controls.Button]::new(); $create.Content='Create and log in'; $create.IsDefault=$true; [void]$buttons.Children.Add($create)
    $cancel.Add_Click({$dialog.Close()})
    $create.Add_Click({
        $name=$input.Text.Trim()
        if($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9]|list)$'){$errorText.Text='Use 1–40 letters, numbers, underscores or hyphens; start with a letter.'; return}
        if(Test-Path -LiteralPath (Join-Path $suite "accounts/$name")){$errorText.Text='That account already exists. Choose another name.'; return}
        Open-DeckTerminal $name; $dialog.Close()
    })
    $dialog.Add_ContentRendered({[void]$input.Focus(); $input.SelectAll()})
    [void]$dialog.ShowDialog()
})
$deckIcon=[Drawing.Icon]::new((Join-Path $root 'assets/codex-deck.ico'),32,32)
$tray=[Windows.Forms.NotifyIcon]::new(); $tray.Icon=$deckIcon; $tray.Text='Codex Deck'; $tray.Visible=$true
$menu=[Windows.Forms.ContextMenuStrip]::new(); $show=$menu.Items.Add('Show Codex Deck'); $panelMenu=$menu.Items.Add('Control panel'); $widgetMenu=$menu.Items.Add('Floating widget'); $settingsMenu=$menu.Items.Add('Settings'); $exit=$menu.Items.Add('Quit (stop checks and warm-up)'); $tray.ContextMenuStrip=$menu
$panelMenu.Add_Click({Set-DeckMode 'Panel'; Render-Deck})
$widgetMenu.Add_Click({Set-DeckMode 'Widget'; Render-Deck})
$settingsMenu.Add_Click({$window.Show(); Show-DeckSettings})
$show.Add_Click({$window.Show(); $window.WindowState='Normal'; [void]$window.Activate()})
$tray.Add_DoubleClick({$window.Show(); $window.WindowState='Normal'; [void]$window.Activate()})
$exit.Add_Click({$script:quit=$true; $window.Close()})
$window.Add_Closing({param($sender,$eventArgs)
    if($settings.CloseToTray -and -not $quit -and -not $SmokeTest -and (-not $Demo -or $LifecycleTest)){
        $eventArgs.Cancel=$true; $tray.Visible=$true; $window.Hide()
        if(-not $script:trayHintShown -and -not $LifecycleTest){$tray.ShowBalloonTip(3500,'Codex Deck is still running','Open it from the green Deck icon in the notification area (possibly under the ^ overflow arrow).',[Windows.Forms.ToolTipIcon]::Info); $script:trayHintShown=$true}
        return
    }
    if(-not $SmokeTest -and -not $Demo){
        if($widget){$settings.WidgetWidth=[int]$window.Width; $settings.WidgetHeight=[int]$window.Height}else{$settings.Width=[int]$window.Width; $settings.Height=[int]$window.Height}
        Write-DeckJson (Join-Path $root 'settings.json') $settings
    }
})
$window.Width=$settings.Width; $window.Height=$settings.Height; Set-DeckAppearance; Update-DeckPicker
Set-DeckMode $settings.ViewMode -Initial
$window.Add_ContentRendered({if($settings.ViewMode -eq 'Tray' -and $Attach){$window.Hide()}})
$timer=[Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[TimeSpan]::FromSeconds(2)
$timer.Add_Tick({try{Invoke-DeckTick}catch{$script:notice='Companion error: '+$_.Exception.Message; $StatusLine.Text=$notice}})
try{
    if($SmokeTest -or $Demo){
        $script:sessions=@([pscustomobject]@{Account='account1';ProcessId=$PID;StartedAt=[DateTimeOffset]::Now.AddMinutes(-42).ToString('o');Folder='C:\Projects\example'})
        $cache.account1=[pscustomobject]@{Account='account1';Email='demo@example.com';PlanType='plus';Status='available';CheckedAt=[DateTimeOffset]::Now.ToString('o');Source='http';Windows=@([pscustomobject]@{Label='5H';DurationSeconds=18000;RemainingPct=72;UsedPct=28;Dead=$false;ResetsAtUnix=[DateTimeOffset]::Now.AddHours(3).ToUnixTimeSeconds()})}
    }
    if($SmokeTest -or $Demo){Set-DeckMode $PreviewMode -Initial}
    Invoke-DeckTick
    if($SmokeTest){
        $settings.AccountPickerUsage=$true; $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker
        $pickerEntry=@($AccountPicker.Items | Where-Object Tag -eq 'account1')[0]
        if(($pickerEntry.Content.Children[1].Inlines | ForEach-Object Text) -notmatch '5h 28%' -or $pickerEntry.Content.Children[2].Text -notmatch '^Last checked: '){throw ("Account picker usage details failed: "+$pickerEntry.Content.Children[1].Text+" | "+$pickerEntry.Content.Children[2].Text)}
        $AccountPicker.SelectedValue='account1'
        if($AccountPicker.SelectedValue -ne 'account1'){throw 'Account picker identity lost.'}
        $folderUI=Select-DeckFolder $HOME -TestUI
        if($folderUI.PathBox.Text -ne $HOME -or $folderUI.Folders.Items.Count -eq 0){throw 'Folder picker initialization failed.'}
        $folderUI.Dialog.Close()
        $settingsUI=Show-DeckSettings -TestUI
        if(@($settingsUI.Controls.WarmupModel.Items | Where-Object {$_ -isnot [string] -or $_ -notmatch '^gpt-' }).Count){throw 'Model picker contains a non-model item.'}
        if($settingsUI.Controls.WarmupModel -isnot [Windows.Controls.ComboBox] -or $settingsUI.Controls.WarmupModel.SelectedItem -ne $settings.WarmupModel){throw 'Model selector failed.'}
        foreach($control in $settingsUI.Controls.Values){if($control.Margin.Bottom -lt 14){throw 'Settings spacing failed.'}}
        $settingsUI.Dialog.Close()
        $window.Content.Measure([Windows.Size]::new($window.Width,$window.Height)); $window.Content.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height)); $window.Content.UpdateLayout()
        if($Cards.Children.Count -ne 1){throw 'Smoke test card rendering failed.'}
        $rowExpander=$Cards.Children[0].Child
        if($rowExpander -isnot [Windows.Controls.Expander] -or $rowExpander.IsExpanded){throw 'Row must start collapsed.'}
        $collapsedHeight=$window.Height
        $rowExpander.IsExpanded=$true
        $window.Content.UpdateLayout(); Update-DeckWidgetHeight
        if($widget -and $settings.WidgetAutoHeight -and $window.Height -le $collapsedHeight){throw 'Expanding a widget row did not grow the window.'}
        if(-not $expandedRows.account1){throw 'Row expansion not remembered.'}
        $rowExpander.IsExpanded=$false
        $window.Content.UpdateLayout(); Update-DeckWidgetHeight

        if($PreviewExpanded){$rowExpander.IsExpanded=$true}
        if($ScreenshotPath){
            $visual=$window.Content
            $visual.Measure([Windows.Size]::new($window.Width,$window.Height)); $visual.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height)); $visual.UpdateLayout()
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Width,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($visual); $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream=[IO.File]::Create($ScreenshotPath); try{$encoder.Save($stream)}finally{$stream.Dispose()}
        }
        foreach($key in @('ShowModel','ShowProcessIds','ShowFolder','ShowSource','ShowCredits','ShowSessionCount','ShowUptime','ShowWarmup','ShowCheckedAt')){$settings[$key]=$true}
        Set-DeckMode 'Panel' -Initial; Render-Deck
        $detailLabels=@($Cards.Children[0].Child.Content.Children | Where-Object {$_ -is [Windows.Controls.Grid]} | ForEach-Object {$_.Children[0].Text})
        foreach($label in @('Status','Email','Plan','Terminals','Model','Uptime','Last check','Source','Process IDs','Folders','Warm-up','Credits')){if($label -notin $detailLabels){throw "Missing expanded field: $label"}}
        if($LaunchBar.Visibility -ne 'Visible' -or $Cards.Children.Count -ne 1){throw 'Panel mode failed.'}
        if($ActionBar.Children.Count -ne 2 -or $CheckButton.Content -ne 'Check'){throw 'Action bar layout failed.'}
        [void]$configMenu.ApplyTemplate()
        $menuSurface=[Windows.Media.VisualTreeHelper]::GetChild($configMenu,0)
        if($menuSurface -isnot [Windows.Controls.Border] -or $menuSurface.Background.ToString() -ne '#FF141619'){throw 'Configs menu background template failed.'}
        if(-not $window.Icon -or -not $settingsUI.Dialog.Icon){throw 'Application window icon missing.'}
        if($configMenu.Items.Count -ne 2 -or $ConfigButton.Content -ne 'Configs' -or [Windows.Controls.Grid]::GetColumn($NewButton) -ne 0){throw 'Account controls layout failed.'}

        if($chrome.CaptionHeight -ne 62){throw 'Panel caption does not cover top padding.'}
        foreach($button in @($ModeButton,$SettingsButton,$CloseButton)) {
            if(-not [Windows.Shell.WindowChrome]::GetIsHitTestVisibleInChrome($button)){throw 'Caption button would be intercepted by dragging.'}
        }
        Set-DeckMode 'Widget' -Initial
        if($chrome.CaptionHeight -ne 54){throw 'Widget caption does not cover top padding.'}
        Render-Deck
        $perf=[Diagnostics.Stopwatch]::StartNew(); for($i=0;$i -lt 100;$i++){Render-Deck}; $perf.Stop()
        'Unchanged render pass: {0:N2} ms average (100 passes).' -f ($perf.Elapsed.TotalMilliseconds/100)
        'PASS: WPF constructed and synthetic account card rendered; no network calls or warm-ups.'
    }else{
        $timer.Start()
        # ShowDialog ends when hidden, which used to dispose the tray icon. A real
        # application message loop stays alive while the main window is hidden.
        $app=[Windows.Application]::new(); $app.ShutdownMode='OnMainWindowClose'
        $app.Add_DispatcherUnhandledException({param($sender,$eventArgs)
            $message=$eventArgs.Exception.ToString()
            [IO.File]::AppendAllText((Join-Path $root 'errors.log'),([DateTimeOffset]::Now.ToString('o')+"`n"+$message+"`n"))
            $script:notice='Deck error recorded in deck/errors.log'; $StatusLine.Text=$notice
            $eventArgs.Handled=$true
        })
        if($LifecycleTest){
            $settings.CloseToTray=$true; $script:lifecycleStep=0; $script:lifecycleFailure=$null
            $lifeTimer=[Windows.Threading.DispatcherTimer]::new(); $lifeTimer.Interval=[TimeSpan]::FromMilliseconds(300)
            $lifeTimer.Add_Tick({
                try{
                    $script:lifecycleStep++
                    switch($lifecycleStep){
                        1 {$window.Close(); if($window.IsVisible -or -not $tray.Visible){throw 'Close did not preserve tray.'}}
                        2 {if(-not $tray.Visible){throw 'Tray disappeared after hide.'}; $window.Show(); if(-not $window.IsVisible){throw 'Restore failed.'}}
                        3 {$focusWindow=[Windows.Window]::new(); $focusWindow.Title='Deck focus test'; $focusWindow.Width=200; $focusWindow.Height=100; $focusWindow.Show(); [void]$focusWindow.Activate(); $script:focusWindow=$focusWindow}
                        4 {if(-not $window.IsVisible -or -not $tray.Visible){throw 'Deck disappeared on focus loss.'}; $focusWindow.Close(); Set-DeckMode 'Panel'; Render-Deck; if($LaunchButton.Content -ne 'Open Terminal'){throw 'Terminal label mismatch.'}; Set-DeckMode 'Widget'; Render-Deck}
                        5 {$script:quit=$true; $lifeTimer.Stop(); $window.Close()}
                    }
                }catch{$script:lifecycleFailure=$_.Exception.Message; $script:quit=$true; $lifeTimer.Stop(); $app.Shutdown()}
            }); $lifeTimer.Start()
        }
        [void]$app.Run($window)
        if($LifecycleTest){if($lifecycleFailure){throw $lifecycleFailure}; 'PASS: real application close-to-tray, persistent icon, restore, view switching, and quit. No network or warm-ups.'}
    }
}catch{
    [IO.File]::AppendAllText((Join-Path $root 'errors.log'),([DateTimeOffset]::Now.ToString('o')+"`n"+$_.ToString()+"`n"+$_.ScriptStackTrace+"`n"))
    throw
}finally{
    $timer.Stop(); Stop-DeckTask $task; if($task){$task.Process.Dispose()}; $tray.Dispose(); $deckIcon.Dispose()
    if($created){$mutex.ReleaseMutex()}; $mutex.Dispose()
}
