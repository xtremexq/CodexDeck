param([switch]$SmokeTest, [switch]$Demo, [switch]$Attach, [switch]$Background, [switch]$OpenSettings, [string]$ScreenshotPath, [switch]$LifecycleTest, [switch]$PreviewExpanded, [ValidateSet('Panel','Widget')][string]$PreviewMode='Widget')
if($LifecycleTest){$Demo=$true}
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
. (Join-Path $PSScriptRoot 'Deck.Backup.ps1')
$script:suite = $PSScriptRoot
$script:root = Join-Path $suite 'deck'
$script:settings = if($SmokeTest -or $Demo){Get-DeckDefaults}else{Get-DeckSettings $root}
$script:cache = @{}; $script:nextCheck = @{}; $script:resets = @{}; $script:history = @{}
$script:rowPools=@{}; $script:rowControls=@{}; $script:rowStyle=''; $script:expandedRows=@{}; $script:profiles=@{}; $script:profileStamps=@{}; $script:cacheVersion=0; $script:lastPicker=[DateTimeOffset]::MinValue
$script:tasks = @{}; $script:batchAccounts=@(); $script:batchUntil=[DateTimeOffset]::MinValue; $script:task = $null
$script:quit = $false; $script:allProfiles = $false
$script:sessions = @(); $script:notice = 'Ready'; $script:lastRender = ''
$script:pins=@(if(-not $SmokeTest -and -not $Demo){Read-DeckJson (Join-Path $root 'pins.json')})
$script:viewStates=@{}
if(-not $SmokeTest -and -not $Demo){
    $savedViews=Read-DeckJson (Join-Path $root 'views.json')
    foreach($mode in @('Panel','Widget')){if($savedViews.$mode){$viewStates[$mode]=$savedViews.$mode}}
}
# Named mutex is user/session scoped. Other launches signal the existing window.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$created = $false
$mutex = [Threading.Mutex]::new($true, "Local\CodexDeck-$sid", [ref]$created)
if (-not $created -and -not $SmokeTest -and -not $Demo) {
    if (-not $Attach) { Write-DeckJson (Join-Path $root 'show.json') @{ At=[DateTimeOffset]::UtcNow.ToString('o'); OpenSettings=[bool]$OpenSettings } }
    $mutex.Dispose(); exit
}
if (-not $SmokeTest -and -not $Demo) {
    foreach ($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $root 'cache.json')))) {
        if ($entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') {
            $cache[$entry.Account] = $entry
            if($entry.CheckedAt){$nextCheck[$entry.Account]=Get-DeckNextCheck $settings $entry ([DateTimeOffset]$entry.CheckedAt)}
        }
    }
    foreach ($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $root 'warmup.json')))) {
        if ($entry.Account) { $history[$entry.Account]=$entry }
    }
    $savedResets=Read-DeckJson (Join-Path $root 'warmup-resets.json')
    foreach ($key in $cache.Keys) {
        $w = $cache[$key].Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
        if ($w.ResetsAtUnix) { $resets[$key]=[long]$w.ResetsAtUnix }
        if($savedResets.$key){$resets[$key]=[long]$savedResets.$key}
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
foreach ($name in 'AccountPicker','SettingsButton','LaunchButton','ConfigButton','NewButton','Summary','StatusLine','Cards','ModeButton','MinimizeButton','CloseButton','LaunchBar','Brand','Subtitle','LayoutRoot','Disclaimer','Header','SummaryButton','StatusButton','CardScroll') {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}
# Native caption hit testing covers the top padding, logo, text and gaps too.
# The old Header-only mouse handler left the surrounding margin undraggable.
$chrome=[Windows.Shell.WindowChrome]::new(); $chrome.CaptionHeight=54; $chrome.ResizeBorderThickness='5'; $chrome.GlassFrameThickness='0'; $chrome.CornerRadius='10'
[Windows.Shell.WindowChrome]::SetWindowChrome($window,$chrome)
foreach($button in @($MinimizeButton,$ModeButton,$SettingsButton,$CloseButton)) {
    [Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($button,$true)
}
function New-DeckText([string]$Text, [string]$Color='#EAF0FA', [double]$Size=12) {
    $textBlock = [Windows.Controls.TextBlock]::new()
    $textBlock.Text=$Text; $textBlock.Foreground=$Color; $textBlock.FontSize=$Size
    $textBlock.TextWrapping='Wrap'; $textBlock.Margin='0,2,0,0'
    return $textBlock
}
function Get-DeckQuotaLabel($Quota) {
    $seconds=[long]$Quota.DurationSeconds
    if($seconds -eq 18000){return '5H'}
    if($seconds -eq 604800){return 'Weekly'}
    if($seconds -ge 2419200 -and $seconds -le 2764800){return 'Monthly'}
    return [string]$Quota.Label
}
function Format-DeckQuotaReset($Quota) {
    if(-not $Quota.ResetsAtUnix){return ''}
    $at=[DateTimeOffset]::FromUnixTimeSeconds([long]$Quota.ResetsAtUnix).ToLocalTime()
    if($at -le [DateTimeOffset]::Now){return ([string][char]0x21BB)+' due'}
    $format=if($at.Date -eq [DateTimeOffset]::Now.Date){'HH:mm'}elseif($at.Year -eq [DateTimeOffset]::Now.Year){'MMM dd HH:mm'}else{'yyyy-MM-dd HH:mm'}
    return ([string][char]0x21BB)+' '+$at.ToString($format)
}
function New-DeckQuotaTrack($Quota,[string]$Color,[bool]$ShowReset=$true) {
    $Color=Get-DeckQuotaColor $Quota
    $grid=[Windows.Controls.Grid]::new(); $grid.Margin='0,6,0,0'
    foreach($width in @('52','*','42','Auto')){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$grid.ColumnDefinitions.Add($col)}
    $label=New-DeckText (Get-DeckQuotaLabel $Quota) '#8898AD' 10; $label.VerticalAlignment='Center'; [void]$grid.Children.Add($label)
    $track=[Windows.Controls.Grid]::new(); $track.Height=3; $track.Background='#2A3443'; $track.VerticalAlignment='Center'; $track.Margin='4,0,8,0'
    $value=if($null -eq $Quota.RemainingPct){0}else{[Math]::Max(0,[Math]::Min(100,[double]$Quota.RemainingPct))}
    foreach($width in @($value,(100-$value))){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLength]::new($width,[Windows.GridUnitType]::Star); [void]$track.ColumnDefinitions.Add($col)}
    $fill=[Windows.Controls.Border]::new(); $fill.Background=$Color; $fill.CornerRadius='1.5'; [void]$track.Children.Add($fill)
    [Windows.Controls.Grid]::SetColumn($track,1); [void]$grid.Children.Add($track)
    $percent=if($null -eq $Quota.RemainingPct){'?'}else{[string]$Quota.RemainingPct+'%'}
    $text=New-DeckText $percent $Color 11; $text.TextAlignment='Right'; [Windows.Controls.Grid]::SetColumn($text,2); [void]$grid.Children.Add($text)
    $reset=New-DeckText $(if($ShowReset){Format-DeckQuotaReset $Quota}else{''}) '#8293AA' 10; $reset.Margin='8,0,0,0'; $reset.VerticalAlignment='Center'; $reset.TextWrapping='NoWrap'; [Windows.Controls.Grid]::SetColumn($reset,3); [void]$grid.Children.Add($reset)
    $grid.Resources['ResetText']=$reset
    return $grid
}
function Save-DeckView {
    if($script:widget){$settings.WidgetWidth=[int]$window.Width; $settings.WidgetHeight=[int]$window.Height}
    else{$settings.Width=[int]$window.Width; $settings.Height=[int]$window.Height}
    $mode=if($widget){'Widget'}else{'Panel'}
    $viewStates[$mode]=[pscustomobject]@{Left=$window.Left;Top=$window.Top;Expanded=@($expandedRows.Keys | Where-Object {$expandedRows[$_]})}
    if(-not $SmokeTest -and -not $Demo){
        Write-DeckJson (Join-Path $root 'settings.json') $settings
        Write-DeckJson (Join-Path $root 'views.json') $viewStates
    }
}
function Update-DeckWidgetHeight {
    if($script:sizing){return}
    $script:sizing=$true
    try{
        $window.Content.UpdateLayout()
        $width=[Math]::Max(100,$window.Width-2-$LayoutRoot.Margin.Left-$LayoutRoot.Margin.Right-9)
        $Cards.Measure([Windows.Size]::new($width,[double]::PositiveInfinity))
        $window.Content.Measure([Windows.Size]::new($window.Width,[double]::PositiveInfinity))
        $overhead=2+$LayoutRoot.Margin.Top+$LayoutRoot.Margin.Bottom
        foreach($section in $LayoutRoot.Children){if($section -ne $CardScroll){$overhead+=$section.DesiredSize.Height}}
        $Cards.Measure([Windows.Size]::new($width,[double]::PositiveInfinity))
        $collapsed=0
        $expanded=0
        foreach($card in $Cards.Children){
            if($card -isnot [Windows.Controls.Border]){continue}
            if($card.Child.IsExpanded){$expanded=[Math]::Max($expanded,$card.DesiredSize.Height)}
            else{$collapsed=[Math]::Max($collapsed,$card.DesiredSize.Height)}
        }
        if($collapsed -eq 0){$collapsed=if($widget){47}else{34}}
        $rows=if($widget){2}else{3}
        $required=if($expanded -gt 0){$expanded}else{$rows*$collapsed}
        $workArea=[Windows.SystemParameters]::WorkArea
        $window.MinHeight=[Math]::Min($workArea.Height,[Math]::Ceiling($overhead+$required+2))
        if($script:defaultViewHeight){
            $window.Height=$window.MinHeight+$(if($widget -or $expanded -gt 0){0}else{$collapsed/2})
            $script:defaultViewHeight=$false
        }elseif($window.Height -lt $window.MinHeight){$window.Height=$window.MinHeight}
        if($window.Height -gt $workArea.Height){$window.Height=$workArea.Height}
    }finally{$script:sizing=$false}
}
function New-DeckExpander([string]$Name,$Header,$Details) {
    $expander=[Windows.Controls.Expander]::new(); $expander.Header=$Header; $expander.Resources['DetailsMode']=$Details
    if($expandedRows[$Name]){$expander.Content=if($Details -eq 'Widget'){New-DeckWidgetDetails $Name}else{New-DeckPanelDetails $Name}}
    $expander.IsExpanded=[bool]$expandedRows[$Name]; $expander.Tag=$Name
    $handler={param($sender,$eventArgs)
        $script:expandedRows[[string]$sender.Tag]=$sender.IsExpanded
        if($sender.IsExpanded -and -not $sender.Content){$sender.Content=if($sender.Resources['DetailsMode'] -eq 'Widget'){New-DeckWidgetDetails ([string]$sender.Tag)}else{New-DeckPanelDetails ([string]$sender.Tag)}}
        # Expansion events precede the template visibility/layout update.
        [void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded,[Action]{Update-DeckWidgetHeight})
    }
    $expander.Add_Expanded($handler); $expander.Add_Collapsed($handler)
    return $expander
}
function Show-DeckDelete([string]$Name, [switch]$TestUI) {
    $dialog=[Windows.Window]::new(); $dialog.Owner=$window; $dialog.WindowStartupLocation='CenterOwner'
    $dialog.WindowStyle='None'; $dialog.ResizeMode='NoResize'; $dialog.Width=380; $dialog.SizeToContent='Height'
    $dialog.Background='#101113'; $dialog.Foreground='#E4E7EC'; $dialog.Icon=$appIcon; $dialog.Resources.MergedDictionaries.Add($window.Resources)
    $surface=[Windows.Controls.Border]::new(); $surface.BorderBrush='#56383F'; $surface.BorderThickness='1'; $surface.CornerRadius='8'; $dialog.Content=$surface
    $panel=[Windows.Controls.StackPanel]::new(); $panel.Margin='22'; $surface.Child=$panel
    [void]$panel.Children.Add((New-DeckText ('Delete '+$Name+'?') '#F17D8D' 17))
    [void]$panel.Children.Add((New-DeckText 'The account will be moved to local recovery storage. Connected accounts must be disconnected first. Terminals are never closed by this action.' '#9AA5AD' 12))
    $errorText=New-DeckText '' '#F17D8D' 11; $errorText.Margin='0,12,0,12'; [void]$panel.Children.Add($errorText)
    $buttons=[Windows.Controls.StackPanel]::new(); $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'; [void]$panel.Children.Add($buttons)
    $cancel=[Windows.Controls.Button]::new(); $cancel.Content='Cancel'; $cancel.IsCancel=$true; $cancel.IsDefault=$true; [void]$buttons.Children.Add($cancel)
    $delete=[Windows.Controls.Button]::new(); $delete.Content='Delete account'; $delete.Foreground='#F17D8D'; [void]$buttons.Children.Add($delete)
    $cancel.Add_Click({$dialog.Close()})
    $delete.Add_Click({
        try{
            if($SmokeTest -or $Demo){throw 'Deletion is unavailable in preview mode.'}
            if($tasks.ContainsKey($Name)){throw 'Wait for this account check or warm-up to finish.'}
            Move-DeckAccountToRecovery $suite $Name
            foreach($map in @($cache,$profiles,$profileStamps,$manualChecks,$nextCheck,$history,$expandedRows)){$map.Remove($Name)}
            $script:notice='Deleted '+$Name+' / saved in local recovery storage'; $script:lastRender=''
            Update-DeckPicker; Render-Deck; $dialog.Close()
        }catch{$errorText.Text=$_.Exception.Message}
    })
    if($TestUI){return $dialog}
    [void]$dialog.ShowDialog()
}
function New-DeckEntryMenu([string]$Name) {
    if($script:sharedEntryMenu){return $script:sharedEntryMenu}
    $menu=[Windows.Controls.ContextMenu]::new(); $menu.Resources=$window.Resources
    foreach($action in @('Open terminal','Check account','Account config','Warm up now','Toggle automatic warm-up','Pause / resume warm-up','Expand / collapse','Pin / unpin','Delete account')){
        $item=[Windows.Controls.MenuItem]::new(); $item.Header=$action; $item.Tag=@{Account=$Name;Action=$action}
        if($action -eq 'Delete account'){
            $separator=[Windows.Controls.Separator]::new(); $separator.Background='#363A41'; $separator.Margin='8,4'; [void]$menu.Items.Add($separator)
            $item.Foreground='#F17D8D'
        }
        $item.Add_Click({param($sender,$eventArgs)
            $account=$sender.Tag.Account
            switch($sender.Tag.Action){
                'Open terminal' {if(-not $SmokeTest -and -not $Demo){Open-DeckTerminal $account}}
                'Check account' {
                    if($tasks.ContainsKey($account)){return}
                    $now=[DateTimeOffset]::UtcNow; $at=$cache[$account].CheckedAt
                    $manualChecks[$account]=$now
                    $script:notice='Check queued: '+$account; $script:lastRender=''; Render-Deck
                }
                'Warm up now' {
                    if(-not $SmokeTest -and -not $Demo){try{Request-DeckWarmup $suite $account; $script:notice='Background warm-up started: '+$account}catch{$script:notice=$_.Exception.Message}}
                }
                'Toggle automatic warm-up' {
                    if(-not $SmokeTest -and -not $Demo){try{$script:settings=Set-DeckWarmupControl $root $account; $script:nextCheck=@{}; $script:lastRender=''; Render-Deck}catch{$script:notice=$_.Exception.Message}}
                }
                'Pause / resume warm-up' {
                    if(-not $SmokeTest -and -not $Demo){$script:settings=Set-DeckWarmupControl $root -Pause; $script:nextCheck=@{}; $script:lastRender=''; Render-Deck}
                }
                'Account config' {if(-not $SmokeTest -and -not $Demo){Edit-DeckConfig (Join-Path $suite ('accounts/'+$account+'/config.toml')) $account}}
                'Expand / collapse' {
                    foreach($card in $Cards.Children){if($card -is [Windows.Controls.Border] -and $card.Child.Tag -eq $account){$card.Child.IsExpanded=-not $card.Child.IsExpanded}}
                }
                'Pin / unpin' {
                    if($account -in $pins){$script:pins=@($pins | Where-Object {$_ -ne $account})}else{$script:pins=@($pins)+$account}
                    if(-not $SmokeTest -and -not $Demo){Write-DeckJson (Join-Path $root 'pins.json') @($pins)}
                    $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker; $script:lastRender=''; Render-Deck
                }
                'Delete account' {Show-DeckDelete $account}
            }
        })
        [void]$menu.Items.Add($item)
    }
    $menu.Add_Opened({param($sender,$eventArgs)
        $account=[string]$sender.PlacementTarget.Child.Tag
        foreach($item in $sender.Items){if($item -is [Windows.Controls.MenuItem]){
            $item.Tag.Account=$account
            if($item.Tag.Action -eq 'Toggle automatic warm-up'){
                $selected=Test-DeckWarmupSelected $settings $account
                $item.Header=if($selected){'Disable automatic warm-up'}else{'Enable automatic warm-up (uses quota)'}
                $item.IsCheckable=$true; $item.IsChecked=$selected; $item.IsEnabled=-not $settings.WarmupAllPaid
                $item.ToolTip=if($settings.WarmupAllPaid){'Managed by All paid accounts in Settings'}else{'Runs through Windows Task Scheduler, even with Deck closed'}
            }
            if($item.Tag.Action -eq 'Pause / resume warm-up'){$item.Header=if($settings.WarmupEnabled){'Pause all automatic warm-ups'}else{'Resume automatic warm-ups'}}
        }}
    })
    $script:sharedEntryMenu=$menu
    return $menu
}
function New-DeckHealthSummary([string]$Name,$Record,[int]$Size=10,$Existing=$null) {
    $text=if($Existing){$Existing}else{New-DeckText '' '#929CA4' $Size}
    $text.Inlines.Clear()
    $text.TextWrapping='NoWrap'; $text.VerticalAlignment='Center'
    $health=Get-DeckHealth $Record
    $color=switch($health){'Ready'{'#69DEC0'} 'Low'{'#DCB675'} 'Exhausted'{'#F17D8D'} 'Limit reached'{'#F17D8D'} default{'#929CA4'}}
    $run=[Windows.Documents.Run]::new($health); $run.Foreground=$color; [void]$text.Inlines.Add($run)
    if($settings.ShowQuota){foreach($quota in $Record.Windows){
        $expired=$quota.ResetsAtUnix -and [long]$quota.ResetsAtUnix -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $pct=if($null -eq $quota.RemainingPct){'?'}else{[string]$quota.RemainingPct+'%'}
        $reset=if($settings.ShowResets -and (-not $widget -or $settings.WidgetShowResets)){' '+(Format-DeckQuotaReset $quota)}else{''}
        $run=[Windows.Documents.Run]::new('  '+(Get-DeckQuotaLabel $quota)+' '+$pct+$(if($expired){'*'}else{''})+$reset)
        $run.Foreground=Get-DeckQuotaColor $quota; [void]$text.Inlines.Add($run)
    }}
    $suffix=if($tasks.ContainsKey($Name) -or $manualChecks.ContainsKey($Name)){' · checking'}elseif($Record.Error){' · check failed'}else{''}
    $suffixRun=[Windows.Documents.Run]::new($suffix); [void]$text.Inlines.Add($suffixRun); $text.Tag=$suffixRun
    return $text
}
function New-DeckWidgetDetails([string]$Name) {
    $Row=$cache[$Name]; $Profile=$profiles[$Name]
    $plan=if($Row.PlanType){$Row.PlanType}else{$Profile.PlanType}
    $stack=[Windows.Controls.StackPanel]::new()
    if($settings.WidgetShowEmail -and $settings.ShowEmail){
        $email=if($Row.Email){$Row.Email}else{$Profile.Email}; if($settings.MaskEmail){$email=$email -replace '^(.).*(@.*)$','$1***$2'}
        if($email){[void]$stack.Children.Add((New-DeckText $email '#8C9DB4' 10))}
    }
    $color='#69DEC0'
    [void]$stack.Children.Add((New-DeckText ((Get-DeckHealth $Row)+' · percentages remaining; * reset passed, check again') '#929CA4' 10))
    if($Row.Error){[void]$stack.Children.Add((New-DeckText ('Last check failed: '+$Row.Error) '#DCB675' 10))}
    if($settings.ShowQuota){
        foreach($quota in $Row.Windows){[void]$stack.Children.Add((New-DeckQuotaTrack $quota $color ([bool]($settings.ShowResets -and $settings.WidgetShowResets))))}
    }
    if($settings.ShowResetCredits){[void]$stack.Children.Add((New-DeckText ('Reset credits  '+(Format-DeckResetCredits $Row)) '#8293AA' 10))}
    if($settings.ShowPlan -and $plan){$stack.Children.Insert(0,(New-DeckText $plan.ToUpperInvariant() '#8394AD' 10))}
    return $stack
}
function New-DeckWidgetCard([string]$Name,$Row,$Profile,[int]$Count) {
    $card=[Windows.Controls.Border]::new(); $card.CornerRadius='6'; $card.Padding=if($settings.Compact){'8,5'}else{'9,6'}; $card.Margin='0,0,0,4'; $card.BorderThickness='1'; $card.BorderBrush='#33373D'; $card.Background=[Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#1C1E22'),[Windows.Media.ColorConverter]::ConvertFromString('#101113'),90)
    $stack=[Windows.Controls.StackPanel]::new(); $card.Child=$stack
    $head=[Windows.Controls.Grid]::new()
    foreach($width in @('14','*','Auto')){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$head.ColumnDefinitions.Add($col)}
    $dot=[Windows.Shapes.Ellipse]::new(); $dot.Width=5; $dot.Height=5; $dot.HorizontalAlignment='Left'; $dot.VerticalAlignment='Center'; $dot.Fill=if($Count){'#69DEC0'}else{'#65738A'}; [void]$head.Children.Add($dot)
    $title=New-DeckText ($(if($Name -in $pins){'★ '}else{''})+$Name) '#E4EBF5' 12; $title.FontWeight='SemiBold'; [Windows.Controls.Grid]::SetColumn($title,1); [void]$head.Children.Add($title)
    $plan=if($Row.PlanType){$Row.PlanType}else{$Profile.PlanType}
    if($settings.ShowPlan){$badge=New-DeckText $(if($plan){$plan.ToUpperInvariant()}else{'?'}) '#8394AD' 9; $badge.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($badge,2); [void]$head.Children.Add($badge)}
    [void]$stack.Children.Add($head)
    if($settings.ShowPlan){$head.Children.RemoveAt($head.Children.Count-1)}
    $summary=New-DeckHealthSummary $Name $Row 9
    if($settings.WidgetOneLine){
        $head.ColumnDefinitions[0].Width=[Windows.GridLength]::new(11)
        $head.ColumnDefinitions[1].Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
        $head.ColumnDefinitions[2].Width=[Windows.GridLength]::new(2,[Windows.GridUnitType]::Star)
        $title.VerticalAlignment='Center'; $summary.TextTrimming='CharacterEllipsis'
        [Windows.Controls.Grid]::SetColumn($summary,2)
        $card.Padding='8,5'; $card.Margin='0,0,0,4'
    }else{
        foreach($i in 1..2){$rd=[Windows.Controls.RowDefinition]::new(); $rd.Height=[Windows.GridLength]::Auto; [void]$head.RowDefinitions.Add($rd)}
        [Windows.Controls.Grid]::SetRow($summary,1); [Windows.Controls.Grid]::SetColumnSpan($summary,3)
    }
    [void]$head.Children.Add($summary)
    $title.TextWrapping='NoWrap'; $title.TextTrimming='CharacterEllipsis'; $title.Margin='0,0,6,0'; $title.FontSize=11
    $stack.Children.Remove($head); $card.Child=$null
    $card.Resources['HealthSummary']=$summary; $card.Resources['ConnectionDot']=$dot; $card.Resources['Title']=$title
    $card.Child=New-DeckExpander $Name $head 'Widget'
    $card.ContextMenu=New-DeckEntryMenu $Name
    return $card
}
function Set-DeckAppearance {
    $window.Topmost=$settings.AlwaysOnTop; $window.Opacity=$settings.OpacityPercent / 100
    $window.FontSize=$settings.FontSize
}
function Set-DeckMode([string]$Mode, [switch]$Initial) {
    if (-not $Initial) {
        Save-DeckView
    }
    $script:widget=$Mode -ne 'Panel'; $settings.ViewMode=$Mode
    $window.ShowInTaskbar=-not $widget
    $visibility=if($widget){'Collapsed'}else{'Visible'}
    foreach($control in @($LaunchBar,$Subtitle,$SettingsButton,$MinimizeButton)){$control.Visibility=$visibility}
    $window.MinWidth=if($widget){238}else{476}; $window.MinHeight=100
    $window.Width=if($widget){$settings.WidgetWidth}else{[Math]::Max($window.MinWidth,$settings.Width)}
    $savedHeight=if($widget){$settings.WidgetHeight}else{$settings.Height}
    $script:defaultViewHeight=$savedHeight -le 0
    $window.Height=[Math]::Max(100,$savedHeight)
    $view=$viewStates[$(if($widget){'Widget'}else{'Panel'})]
    $script:expandedRows=@{}
    if($view){
        foreach($name in $view.Expanded){if($name -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){$expandedRows[$name]=$true}}
        if($null -ne $view.Left -and $null -ne $view.Top -and -not [double]::IsNaN([double]$view.Left) -and -not [double]::IsNaN([double]$view.Top)){
            $screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]$view.Left,[int]$view.Top)).WorkingArea
            $window.Left=[Math]::Max($screen.Left,[Math]::Min($screen.Right-$window.Width,[double]$view.Left))
            $window.Top=[Math]::Max($screen.Top,[Math]::Min($screen.Bottom-100,[double]$view.Top))
        }
    }
    $LayoutRoot.Margin=if($widget){'12'}else{'20'}
    $chrome.CaptionHeight=if($widget){54}else{62}
    $Brand.FontSize=if($widget){13}else{17}; $Brand.Margin='0'
    $ModeButton.Content.Data=[Windows.Media.Geometry]::Parse($(if($widget){'M 1,11 L 11,1 M 3,1 L 11,1 L 11,9'}else{'M 11,1 L 1,11 M 1,3 L 1,11 L 9,11'}))
    $ModeButton.ToolTip=if($widget){'Open control panel'}else{'Floating widget'}
    $script:lastRender=''
    if(-not $SmokeTest -and -not $Demo){Write-DeckJson (Join-Path $root 'settings.json') $settings}
    if($Mode -eq 'Tray'){$window.Hide()}elseif(-not $Initial){$window.Show(); [void]$window.Activate()}
}
function Set-DeckSavedSettings($Saved) {
    # Settings click handlers use GetNewClosure so TestUI can invoke them after
    # Show-DeckSettings returns. Assigning $script:settings inside that closure
    # writes to the closure's dynamic module, leaving the live Deck settings
    # unchanged; Set-DeckMode then persisted the old values over the new file.
    $wasCompact=[bool]$script:settings.Compact
    $script:settings=$Saved
    foreach($account in @($nextCheck.Keys)){
        if($cache[$account].CheckedAt){$nextCheck[$account]=Get-DeckNextCheck $settings $cache[$account] ([DateTimeOffset]$cache[$account].CheckedAt)}
    }
    if($settings.Compact -and -not $wasCompact){$script:expandedRows=@{}}
    Set-DeckAppearance
    Set-DeckMode $settings.ViewMode
    $script:lastRender=''
}
function Get-DeckAccounts {
    if($SmokeTest -or $Demo){if($script:testPickerNames){return $script:testPickerNames}; return 'account1'}
    @(Get-ChildItem -LiteralPath (Join-Path $suite 'accounts') -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' | Sort-Object @{Expression={if(Test-Path -LiteralPath (Join-Path $_.FullName 'deck-entry.json')){-1}elseif($_.Name -in $pins){0}else{1}}},@{Expression={if($_.Name -match '^account(\d+)$'){[long]$Matches[1]}else{[long]::MaxValue}}},Name | ForEach-Object Name)
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
        $row=$cache[$name]
        $line=[Windows.Controls.TextBlock]::new(); $line.FontSize=11; $line.TextWrapping='NoWrap'; $line.TextTrimming='CharacterEllipsis'
        $title=[Windows.Documents.Run]::new($(if($name -in $pins){'★ '}else{''})+$name+'  '); $title.Foreground='#E4EBF5'; $title.FontWeight='SemiBold'; [void]$line.Inlines.Add($title)
        $usage=[Windows.Controls.TextBlock]::new(); $usage.FontSize=10
        foreach($quota in $row.Windows){
            $used=$quota.UsedPct
            if($null -eq $used -and $null -ne $quota.RemainingPct){$used=100-$quota.RemainingPct}
            $label=switch([long]$quota.DurationSeconds){18000 {'5h'} 604800 {'Weekly'} default {$quota.Label}}
            if([long]$quota.DurationSeconds -ge 2419200 -and [long]$quota.DurationSeconds -le 2764800){$label='Monthly'}
            $reset=if($quota.ResetsAtUnix){[DateTimeOffset]::FromUnixTimeSeconds([long]$quota.ResetsAtUnix).ToLocalTime().ToString('dd/MM HH:mm')}else{'reset unknown'}
            $run=[Windows.Documents.Run]::new(('{0} {1} / {2}   ' -f $label,$(if($null -eq $used){'?'}else{('{0:0}%' -f $used)}),$reset))
            $run.Foreground=if($null -eq $used){'#929CA4'}elseif($used -ge 90){'#F17D8D'}elseif($used -ge 70){'#E7B16A'}else{'#69DEC0'}
            [void]$usage.Inlines.Add($run)
        }
        if(-not $usage.Inlines.Count){$usage.Text='Usage unavailable'; $usage.Foreground='#929CA4'}
        $usage.ToolTip='Percentage used / next local reset. Windows are shown as reported by the account.'
        foreach($run in @($usage.Inlines)){ [void]$usage.Inlines.Remove($run); [void]$line.Inlines.Add($run) }
        $age='Never'
        if($row.CheckedAt){
            $seconds=[Math]::Max(0,([DateTimeOffset]::Now-[DateTimeOffset]$row.CheckedAt).TotalSeconds)
            $age=if($seconds -ge 2592000){[Math]::Floor($seconds/2592000).ToString()+'mo'}elseif($seconds -ge 604800){[Math]::Floor($seconds/604800).ToString()+'w'}elseif($seconds -ge 86400){[Math]::Floor($seconds/86400).ToString()+'d'}elseif($seconds -ge 3600){[Math]::Floor($seconds/3600).ToString()+'h'}elseif($seconds -ge 60){[Math]::Floor($seconds/60).ToString()+'m'}else{[Math]::Floor($seconds).ToString()+'s'}
        }
        $ageRun=[Windows.Documents.Run]::new('  Last checked: '+$age); $ageRun.Foreground='#858B92'; $ageRun.FontSize=9; [void]$line.Inlines.Add($ageRun)
        $item.Content=$line
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
function Open-DeckTerminal([string]$Account,[switch]$NewAccount) {
    if ($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { return }
    $folder=$settings.DefaultFolder
    if($settings.AlwaysAskFolder -or -not (Test-Path -LiteralPath $folder -PathType Container)){$folder=Select-DeckFolder $folder}
    if(-not $folder){return}
    $auth = (Join-Path $HOME '.local/bin/codex-auth.cmd').Replace("'", "''")
    $code = "Set-Location -LiteralPath '" + $folder.Replace("'", "''") + "'; & '$auth' '$Account'"
    if($NewAccount){$code+=' -NewAccount'}
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
    $settingsError=New-DeckText '' '#F17D8D'; [Windows.Controls.DockPanel]::SetDock($settingsError,'Bottom'); $dock.Children.Insert(0,$settingsError)
    $save.Add_Click({
        try {
            $current=if(Test-Path -LiteralPath $Path){[IO.File]::ReadAllText($Path)}else{''}
            if ($current -cne $original) { throw 'This file changed outside the editor. Close and reopen it before saving.' }
            if ($editor.Text -ceq $original) { $dialog.Close(); return }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
            if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination ($Path+'.bak-deck-'+[guid]::NewGuid().ToString('N')) }
            [IO.File]::WriteAllText($Path,$editor.Text,[Text.UTF8Encoding]::new($false))
            $dialog.Close()
        } catch { $settingsError.Text=$_.Exception.Message }
    }.GetNewClosure())
    [void]$dialog.ShowDialog()
}
function Show-DeckSettings {
    param([switch]$TestUI)
    $dialog=[Windows.Window]::new(); $dialog.Title='Codex Deck / Settings'; $dialog.Width=640; $dialog.Height=[Math]::Min(700,[Windows.SystemParameters]::WorkArea.Height); $dialog.MinWidth=540; $dialog.MinHeight=440
    $dialog.WindowStyle='None'; $dialog.ResizeMode='CanResize'; $dialog.ShowInTaskbar=$false
    $settingsChrome=[Windows.Shell.WindowChrome]::new(); $settingsChrome.CaptionHeight=65; $settingsChrome.ResizeBorderThickness='5'; $settingsChrome.GlassFrameThickness='0'
    [Windows.Shell.WindowChrome]::SetWindowChrome($dialog,$settingsChrome)
    if(-not $TestUI){$dialog.Owner=$window}; $dialog.WindowStartupLocation='CenterOwner'; $dialog.Background='#000000'; $dialog.Foreground='#EAF0FA'
    $dialog.Icon=$appIcon; $dialog.Resources.MergedDictionaries.Add($window.Resources)
    $dock=[Windows.Controls.DockPanel]::new(); $dock.Margin='22'
    $frame=[Windows.Controls.Border]::new(); $frame.BorderBrush='#363F45'; $frame.BorderThickness='1'; $frame.CornerRadius='10'; $frame.Background='#101315'; $frame.Child=$dock; $dialog.Content=$frame
    $save=[Windows.Controls.Button]::new(); $save.Content='Save settings'; $save.Padding='12,8'; $save.Margin='0,12,0,0'
    [Windows.Controls.DockPanel]::SetDock($save,'Bottom'); [void]$dock.Children.Add($save)
    $heading=New-DeckText 'Settings' '#EDF1F7' 22; $heading.Margin='0,0,0,5'
    $titlebar=[Windows.Controls.DockPanel]::new(); $titlebar.LastChildFill=$true
    $dismiss=[Windows.Controls.Button]::new(); $dismiss.Style=$window.Resources['IconButton']; $dismiss.Content=[char]0x00D7; $dismiss.ToolTip='Close settings'; $dismiss.Margin='12,0,0,0'; $dismiss.VerticalAlignment='Top'
    [Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($dismiss,$true)
    $dismiss.Add_Click({$dialog.Close()}.GetNewClosure()); [Windows.Controls.DockPanel]::SetDock($dismiss,'Right'); [void]$titlebar.Children.Add($dismiss); [void]$titlebar.Children.Add($heading)
    [Windows.Controls.DockPanel]::SetDock($titlebar,'Top'); [void]$dock.Children.Add($titlebar)
    $intro=New-DeckText 'Make Deck feel at home.' '#929CA4'; $intro.Margin='0,0,0,20'
    [Windows.Controls.DockPanel]::SetDock($intro,'Top'); [void]$dock.Children.Add($intro)
    $tabs=[Windows.Controls.TabControl]::new(); [void]$dock.Children.Add($tabs)
    $groups=[ordered]@{
        Appearance=@('ViewMode','Compact','AlwaysOnTop','CloseToTray','AutoStart','OpacityPercent','FontSize','DefaultFolder','AlwaysAskFolder')
        Details=@('ShowEmail','MaskEmail','ShowPlan','AccountPickerUsage','ShowQuota','ShowResets','ShowResetCredits','ShowCredits','ShowSessionCount','ShowUptime','ShowModel','ShowFolder','ShowWarmup','WidgetOneLine','WidgetShowEmail','WidgetShowResets','ShowCheckedAt','ShowSource','ShowProcessIds')
        Failover=@('FailoverEnabled','FailoverMode','FailoverAccounts')
        'Checks & Warmup'=@('AutoCheck','PollMinutes','MinimumGapSeconds','WarmupEnabled','WarmupSchedulingEnabled','WarmupResetEnabled','WarmupTimedEnabled','WarmupTimes','WarmupStartAtLogin','WarmupAllPaid','WarmupAccounts','WarmupModel','WarmupGraceSeconds','WarmupMaxDelayMinutes')
    }
    $descriptions=@{Failover='Automatically enable for new codex-auth conversations, including launches from Deck. The account you launch stays first; the chosen dynamic group or selected accounts may follow it. Existing sessions are unchanged. Account-specific history can prevent switching. Override one launch with -Failover Off.';Appearance='Window behavior and reading comfort';Details='Choose what appears in expanded account entries and the widget';Checks='Auto-check follows this interval for the displayed account list. Manual checks run immediately, up to eight together.';'Usage Warmup'='Warm-up and its Windows background task are off by default. Choose the accounts and timing below. Enable background scheduling and save only when you want the clearly named CodexDeck Warmup Scheduling task to run while Deck is closed.'}
    $labels=@{ShowResetCredits='Reset credits';ShowCredits='Additional usage credits';MaskEmail='Mask email addresses';AccountPickerUsage='Usage in account picker';FailoverEnabled='Automatically enable failover for codex-auth launches';FailoverMode='Rotation';FailoverAccounts='Quota accounts';DefaultFolder='Terminal start folder';AlwaysAskFolder='Always ask where to open the terminal';ViewMode='Default view';Compact='Compact entries';WidgetOneLine='One-line widget entries';AlwaysOnTop='Keep Deck above other windows';CloseToTray='Close to the tray';AutoStart='Start Deck with account terminals';OpacityPercent='Window opacity (%)';FontSize='Text size';AutoCheck='Enable automatic checks';PollMinutes='Check interval (minutes)';MinimumGapSeconds='Cooldown after a list check (seconds)';WarmupEnabled='Enable automatic warm-up';WarmupResetEnabled='After quota resets';WarmupTimedEnabled='At chosen times every day';WarmupTimes='Daily times in local 24-hour format (08:00, 13:30)';WarmupStartAtLogin='Check and reschedule at Windows sign-in';WarmupAllPaid='All Plus or higher (including future accounts)';WarmupAccounts='Additional accounts (type to find; select one or more)';WarmupModel='Model / low reasoning effort';WarmupGraceSeconds='Wait after quota reset (seconds)';WarmupMaxDelayMinutes='Warm-up window after reset (minutes)';WidgetAutoHeight='Fit widget height to content';WidgetShowEmail='Email in widget';WidgetShowResets='Reset times in widget';ShowCheckedAt='Last check time';ShowProcessIds='Process IDs';ShowSessionCount='Terminal count'}
    $panels=@{}; $controls=@{}
    foreach($group in $groups.Keys){
        $tab=[Windows.Controls.TabItem]::new(); $tab.Header=$group
        $scroll=[Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'
        $panel=[Windows.Controls.StackPanel]::new(); $panel.Margin='2,0,12,0'; $scroll.Content=$panel; $tab.Content=$scroll
        $description=New-DeckText $(if($group -eq 'Checks & Warmup'){$descriptions.Checks}else{$descriptions[$group]}) '#929CA4'; $description.Margin='0,0,0,20'; [void]$panel.Children.Add($description)
        $panels[$group]=$panel; [void]$tabs.Items.Add($tab)
    }
    $detailSections=[ordered]@{
        'Account identity'=@('ShowEmail','MaskEmail','ShowPlan','AccountPickerUsage')
        'Usage & credits'=@('ShowQuota','ShowResets','ShowResetCredits','ShowCredits')
        'Session details'=@('ShowSessionCount','ShowUptime','ShowModel','ShowFolder','ShowWarmup')
        'Widget'=@('WidgetOneLine','WidgetShowEmail','WidgetShowResets')
        'Diagnostics'=@('ShowCheckedAt','ShowSource','ShowProcessIds')
    }
    $detailPanels=@{}; $detailWrap=[Windows.Controls.WrapPanel]::new(); [void]$panels.Details.Children.Add($detailWrap)
    foreach($section in $detailSections.Keys){
        $card=[Windows.Controls.Border]::new(); $card.Width=258; $card.Padding='14'; $card.Margin='0,0,12,12'; $card.CornerRadius='7'; $card.Background='#171C1F'; $card.BorderBrush='#2B343A'; $card.BorderThickness='1'
        $sectionPanel=[Windows.Controls.StackPanel]::new(); $card.Child=$sectionPanel
        $sectionTitle=New-DeckText $section '#A9E8D5' 14; $sectionTitle.Margin='0,0,0,14'; [void]$sectionPanel.Children.Add($sectionTitle)
        [void]$detailWrap.Children.Add($card); foreach($field in $detailSections[$section]){$detailPanels[$field]=$sectionPanel}
    }
    foreach ($key in @(@($groups.Values | ForEach-Object { $_ }) + @($settings.Keys) | Select-Object -Unique)) {
        if ($key -in @('Width','Height','WidgetWidth','WidgetHeight','WidgetAutoHeight')) { continue }
        $group=@($groups.Keys | Where-Object { $key -in $groups[$_] })[0]
        if(-not $group){$group='Appearance'}
        $panel=if($group -eq 'Details'){$detailPanels[$key]}else{$panels[$group]}
        if($key -eq 'AutoCheck'){[void]$panel.Children.Add((New-DeckText 'Checks' '#EDF1F7' 18))}
        if($key -eq 'WarmupEnabled'){[void]$panel.Children.Add((New-DeckText 'Usage Warmup' '#EDF1F7' 18)); [void]$panel.Children.Add((New-DeckText $descriptions['Usage Warmup'] '#929CA4'))}
        $caption=if($labels.ContainsKey($key)){$labels[$key]}else{(($key -replace '^Show','') -creplace '([a-z])([A-Z])','$1 $2')}
        if($key -eq 'WarmupSchedulingEnabled'){
            $control=[Windows.Controls.Button]::new(); $control.Tag=[bool]$settings[$key]
            $control.Content=if($control.Tag){'Disable background scheduling'}else{'Enable background scheduling'}
            $control.ToolTip='Creates or removes the CodexDeck Warmup Scheduling task when you save settings.'
            $control.HorizontalAlignment='Left'; $control.Padding='12,7'; $control.Margin='0,0,10,16'; $control.MinHeight=34
            $control.Add_Click({
                $control.Tag=-not [bool]$control.Tag
                $control.Content=if($control.Tag){'Disable background scheduling'}else{'Enable background scheduling'}
                if($control.Tag){$controls.WarmupEnabled.IsChecked=$true}
            }.GetNewClosure())
        }elseif ($settings[$key] -is [bool]) {
            $control=[Windows.Controls.CheckBox]::new(); $control.Content=$caption; $control.IsChecked=$settings[$key]
            $control.Foreground='#EAF0FA'; $control.Margin='0,0,0,14'; $control.MinHeight=24
        } else {
            $label=New-DeckText $caption '#A2ADB5'; $label.Margin='0,2,0,6'; [void]$panel.Children.Add($label)
            if($key -eq 'WarmupModel'){
                $control=[Windows.Controls.ComboBox]::new()
                $cachedModels=Read-DeckJson (Join-Path $root 'models.json')
                foreach($model in @(Get-DeckModelNames @($settings.WarmupModel,'gpt-5.6-luna',$cachedModels.Models))){[void]$control.Items.Add([string]$model)}
                $control.SelectedItem=$settings.WarmupModel; $control.ToolTip='Warm-up uses low reasoning effort. Loading models from Codex...'
            }elseif($key -eq 'WarmupAccounts'){
                $control=[Windows.Controls.ListBox]::new(); $control.SelectionMode='Multiple'; $control.MaxHeight=150
                $control.IsTextSearchEnabled=$true; $control.Background='#111315'; $control.Foreground='#E4EAF4'; $control.BorderBrush='#363C42'
                $search=[Windows.Controls.TextBox]::new(); $search.ToolTip='Find an existing account'; $search.Margin='0,0,10,6'; $search.Tag=$control
                $search.Add_TextChanged({param($sender,$eventArgs)
                    $query=$sender.Text; $list=$sender.Tag
                    $list.Items.Filter=[Predicate[object]]{param($value) [string]$value -like ('*'+$query+'*')}.GetNewClosure()
                }); [void]$panel.Children.Add($search)
                foreach($account in @(Get-DeckAccounts)){[void]$control.Items.Add($account); if($account -in @($settings.WarmupAccounts -split '[,;\s]+')){[void]$control.SelectedItems.Add($account)}}
            }elseif($key -eq 'FailoverAccounts'){
                $control=[Windows.Controls.StackPanel]::new()
                $membership=[Windows.Controls.ComboBox]::new()
                foreach($option in @('Use all signed-in accounts (including future accounts)','Use all free accounts','Use all Plus or higher accounts','Use selected accounts')){[void]$membership.Items.Add($option)}
                $members=[Windows.Controls.ListBox]::new(); $members.SelectionMode='Multiple'; $members.MaxHeight=150; $members.Margin='0,8,0,0'
                $accountNames=if($SmokeTest){@('account1','account2')}else{@(Get-DeckAccounts | Where-Object {Test-Path -LiteralPath (Join-Path $suite "accounts/$_/auth.json") -PathType Leaf})}
                foreach($account in $accountNames){[void]$members.Items.Add($account)}
                $savedMembers=@($settings[$key] -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})
                $membership.SelectedIndex=if(($savedMembers -join ',') -eq '*'){0}elseif(($savedMembers -join ',') -eq '*free'){1}elseif(($savedMembers -join ',') -eq '*paid'){2}else{3}
                foreach($account in $savedMembers){if($members.Items.Contains($account)){[void]$members.SelectedItems.Add($account)}}
                $members.Visibility=if($membership.SelectedIndex -eq 3){'Visible'}else{'Collapsed'}
                $membership.Add_SelectionChanged({$members.Visibility=if($membership.SelectedIndex -eq 3){'Visible'}else{'Collapsed'}}.GetNewClosure())
                [void]$control.Children.Add($membership); [void]$control.Children.Add($members)
                $control.Resources['Membership']=$membership; $control.Resources['Members']=$members
            }elseif($key -eq 'FailoverMode'){$control=[Windows.Controls.ComboBox]::new(); foreach($mode in @('Ordered','Best')){[void]$control.Items.Add($mode)}; $control.SelectedItem=$settings[$key]
            }elseif($key -eq 'ViewMode'){$control=[Windows.Controls.ComboBox]::new(); foreach($mode in @('Panel','Widget','Tray')){[void]$control.Items.Add($mode)}; $control.SelectedItem=$settings[$key]}else{$control=[Windows.Controls.TextBox]::new(); $control.Text=[string]$settings[$key]}
            $control.Margin='0,0,10,16'; $control.MinHeight=34
        }
        $controls[$key]=$control; [void]$panel.Children.Add($control)
    }
    . (Join-Path $suite 'Deck.SettingsExtras.ps1')
    $settingsError=New-DeckText '' '#F17D8D'; $settingsError.Margin='0,10,0,0'; $settingsError.FontWeight='SemiBold'; [Windows.Controls.DockPanel]::SetDock($settingsError,'Bottom'); $dock.Children.Insert(0,$settingsError)
    $save.Add_Click({
        try {
            $settingsError.Text=''; $save.Content='Save settings'; $save.IsEnabled=$false
            $updated=Get-DeckDefaults
            foreach ($key in $settings.Keys) {
                if (-not $controls.ContainsKey($key)) { $updated[$key]=$settings[$key]; continue }
                if ($key -eq 'WarmupSchedulingEnabled') { $updated[$key]=[bool]$controls[$key].Tag }
                elseif ($settings[$key] -is [bool]) { $updated[$key]=[bool]$controls[$key].IsChecked }
                elseif ($key -eq 'WarmupAccounts') { $updated[$key]=@($controls[$key].SelectedItems) -join ',' }
                elseif ($key -eq 'FailoverAccounts') {
                    $membership=$controls[$key].Resources['Membership']; $members=$controls[$key].Resources['Members']
                    if($membership.SelectedIndex -notin 0..3){throw 'Choose failover quota accounts.'}
                    $updated[$key]=if($membership.SelectedIndex -eq 3){@($members.SelectedItems | ForEach-Object {[string]$_}) -join ','}else{@('*','*free','*paid')[$membership.SelectedIndex]}
                }
                elseif ($key -in @('WarmupModel','ViewMode','FailoverMode')) { $updated[$key]=[string]$controls[$key].SelectedItem }
                elseif ($settings[$key] -is [int]) { $updated[$key]=[int]$controls[$key].Text }
                else { $updated[$key]=$controls[$key].Text.Trim() }
            }
            if(-not $updated.AlwaysAskFolder -and -not (Test-Path -LiteralPath $updated.DefaultFolder -PathType Container)){throw 'Choose an existing terminal start folder, or enable Always ask.'}
            if ($updated.FailoverMode -notin @('Ordered','Best')) { throw 'Choose Ordered or Best failover selection.' }
            if ($updated.FailoverEnabled -or $updated.FailoverAccounts) {
                . (Join-Path $suite 'Deck.Failover.ps1')
                $validated=Resolve-DeckFailoverPool $suite $updated.FailoverAccounts Ordered
                if($updated.FailoverAccounts -notin @('*','*free','*paid')){$updated.FailoverAccounts=$validated.Pool -join ','}
            }
            if ($updated.WarmupModel -notmatch '^gpt-[a-zA-Z0-9.-]+$') { throw 'Enter a model ID, e.g. gpt-5.6-luna.' }
            if ($updated.ViewMode -notin @('Panel','Widget','Tray')) { throw 'View Mode must be Panel, Widget, or Tray.' }
            foreach ($name in @($updated.WarmupAccounts -split '[,;\s]+' | Where-Object { $_ })) {
                if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -notin @(Get-DeckAccounts)) { throw "Unknown warm-up account: $name" }
            }
            if ($updated.WarmupEnabled -and -not $updated.WarmupAllPaid -and -not $updated.WarmupAccounts) { throw 'Select at least one warm-up account.' }
            $updated.WarmupTimes=ConvertTo-DeckWarmupTimes $updated.WarmupTimes
            if($updated.WarmupTimedEnabled -and -not $updated.WarmupTimes){throw 'Enter at least one daily time.'}
            if($tabs.SelectedItem -eq $environmentTab -or $environmentState.Pools.Count){& $rememberPool}
            & $saveEnvironments -ValidateOnly
            & $saveEnvironments
            Write-DeckJson (Join-Path $root 'settings.json') $updated
            if(-not $SmokeTest){Sync-DeckWarmupStartup $suite $updated; if($updated.WarmupEnabled){Start-DeckWarmupScheduler $suite}}
            Set-DeckSavedSettings (Get-DeckSettings $root)
            $dialog.Close()
        } catch { $settingsError.Text='Settings were not saved: '+$_.Exception.Message; $settingsError.BringIntoView(); $save.Content='Save settings' }
        finally {$save.IsEnabled=$true}
    }.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Controls=$controls;Panel=$panel;Tabs=$tabs;Save=$save;Error=$settingsError;SupportPrompt=$supportOverlay;SupportDismiss=$supportDismiss;Environment=@{Name=$poolNameBox;Membership=$poolMembership;Members=$poolMemberList;Mode=$poolModeBox;Owner=$shareSourceBox;Resources=$shareResourceList;Recipients=$shareRecipients;State=$environmentState}}}
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
        if(-not $modelAccount -or (Get-DeckPoolEntry $suite $modelAccount)){$modelAccount=@(Get-DeckAccounts | Where-Object { -not (Get-DeckPoolEntry $suite $_) -and (Test-Path -LiteralPath (Join-Path $suite "accounts/$_/auth.json")) })[0]}
        if($modelAccount){$modelState.Task=Start-DeckTask (Get-DeckModelsCode $suite $modelAccount) 'Models' $modelAccount; $modelTimer.Start()}
        [void]$dialog.ShowDialog()
    }finally{$modelTimer.Stop(); if($modelState.Task){Stop-DeckTask $modelState.Task; $modelState.Task.Process.Dispose()}}
}
function New-DeckPanelDetails([string]$Name) {
    $row=$cache[$Name]; $profile=$profiles[$Name]; $connected=@($sessions | Where-Object Account -eq $Name)
    $plan=if($row.PlanType){$row.PlanType}else{$profile.PlanType}
    $displayEmail=if($row.Email){$row.Email}else{$profile.Email}
    $status=Get-DeckHealth $row; $quotaColor='#69DEC0'
        $detailPanel=[Windows.Controls.StackPanel]::new(); $detailPanel.Margin='12,2,12,6'
        $divider=[Windows.Controls.Border]::new(); $divider.Height=1; $divider.Background='#30343A'; $divider.Margin='0,0,0,10'; [void]$detailPanel.Children.Add($divider)
        if($settings.ShowQuota){foreach($w in $row.Windows){[void]$detailPanel.Children.Add((New-DeckQuotaTrack $w $quotaColor ([bool]$settings.ShowResets)))}}
        $fields=[ordered]@{}
        $fields['Status']=$status+' · percentages remaining; * reset passed, check again'
        if($settings.ShowEmail){$fields['Email']=if($displayEmail){if($settings.MaskEmail){$displayEmail -replace '^(.).*(@.*)$','$1***$2'}else{$displayEmail}}else{'Unavailable'}}
        if($settings.ShowPlan){$fields['Plan']=if($plan){$plan}else{'Unavailable'}}
        if($settings.ShowResetCredits){$fields['Reset credits']=Format-DeckResetCredits $row}
        if($settings.ShowSessionCount){$fields['Terminals']=[string]$connected.Count}
        if($settings.ShowModel){$fields['Model']=$profile.Model+' / '+$profile.Effort}
        if($settings.ShowUptime -and $connected.Count){$fields['Uptime']=[string][int]([DateTimeOffset]::Now-[DateTimeOffset]($connected | Sort-Object StartedAt | Select-Object -First 1).StartedAt).TotalMinutes+' min'}
        if($settings.ShowCheckedAt){$fields['Last check']=if($row.CheckedAt){([DateTimeOffset]$row.CheckedAt).ToLocalTime().ToString('dd MMM · HH:mm')}else{'Not checked'}}
        if($settings.ShowSource){$fields['Source']=if($row.Source){$row.Source}else{'Not checked'}}
        if($settings.ShowProcessIds){$fields['Process IDs']=($connected | ForEach-Object ProcessId)-join ', '}
        if($settings.ShowFolder){$fields['Folders']=($connected | ForEach-Object Folder | Select-Object -Unique)-join "`n"}
        if($settings.ShowWarmup -or (Test-DeckWarmupSelected $settings $name)){$fields['Warm-up']=Get-DeckWarmupStatus $settings $(if($row){$row}else{@{Account=$name}}) $history[$name]}
        if($settings.ShowCredits){$fields['Credits']=if($null -ne $row.Credits){($row.Credits.PSObject.Properties | ForEach-Object { $_.Name+': '+$_.Value }) -join ' · '}else{'Not provided by Codex'}}
        if($row.Error){$fields['Check error']=$row.Error}
        foreach($key in @($fields.Keys)){
            if([string]::IsNullOrWhiteSpace([string]$fields[$key])){$fields[$key]='Unavailable'}
            $line=[Windows.Controls.Grid]::new(); $line.Margin='0,4,0,4'
            $col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLength]::new(108); [void]$line.ColumnDefinitions.Add($col)
            [void]$line.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
            [void]$line.Children.Add((New-DeckText $key '#7F8997' 11))
            $value=New-DeckText ([string]$fields[$key]) '#C8D0DB' 11; [Windows.Controls.Grid]::SetColumn($value,1); [void]$line.Children.Add($value)
            [void]$detailPanel.Children.Add($line)
        }
    return $detailPanel
}
function Render-Deck {
    $names = @($sessions | ForEach-Object Account | Select-Object -Unique)
    if ($allProfiles) { $names=@(Get-DeckAccounts) }
    $names=@($names | Sort-Object @{Expression={if($_ -in $pins){0}else{1}}},@{Expression={if($_ -match '^account(\d+)$'){[long]$Matches[1]}else{[long]::MaxValue}}},{$_})
    $warmupLabel=if(-not $settings.WarmupEnabled){'off'}elseif($settings.WarmupSchedulingEnabled){'scheduled'}else{'scheduling off'}
    $Summary.Text="{0} connected accounts  /  {1} terminals  /  warm-up {2}" -f @($sessions | ForEach-Object Account | Select-Object -Unique).Count,$sessions.Count,$warmupLabel
    if($widget){$Summary.Text="{0} online  /  {1} terminals" -f @($sessions | ForEach-Object Account | Select-Object -Unique).Count,$sessions.Count}
    $warming=@($tasks.Values | Where-Object Kind -eq 'Warm-up').Count
    $StatusLine.Text = if ($tasks.Count) { "Checking $($tasks.Count-$warming) / warming $warming…" } else { $(if($settings.AutoCheck){"$notice / auto-check every $($settings.PollMinutes)m"}else{"$notice / auto-check off"}) }
    if($widget -and -not $tasks.Count){$StatusLine.Text='Checks '+$(if($settings.AutoCheck){'on'}else{'off'})+'  /  warm-up '+$warmupLabel}
    $SummaryButton.ToolTip=if($allProfiles){'Showing all accounts. Click for connected only.'}else{'Showing connected accounts. Click to see all.'}
    $Summary.Foreground=if($allProfiles){'#69DEC0'}else{'#8493AA'}
    $signature=($names -join ',') + (($sessions | ForEach-Object ProcessId) -join ',') + '/' + $cacheVersion + '/' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmm') + $allProfiles + '/' + ($manualChecks.Keys -join ',') + '/' + ($tasks.Keys -join ',')
    if ($signature -eq $lastRender) { return }
    $script:lastRender=$signature
    $style=(@('Compact','FontSize','WidgetOneLine','MaskEmail','ShowEmail','ShowPlan','ShowQuota','ShowResets','ShowSessionCount','ShowUptime','ShowModel','ShowProcessIds','ShowFolder','ShowSource','ShowCheckedAt','ShowCredits','ShowResetCredits','ShowWarmup','WidgetShowEmail','WidgetShowResets','WarmupEnabled','WarmupSchedulingEnabled','WarmupAllPaid','WarmupAccounts','WarmupGraceSeconds') | ForEach-Object {[string]$settings[$_]}) -join '/'; $style+='/'+$widget
    if($style -ne $rowStyle){
        $poolKey=[string]$widget; $pool=$rowPools[$poolKey]
        if($pool -and $pool.Style -eq $style){$script:rowControls=$pool.Controls}else{$script:rowControls=@{}; $rowPools[$poolKey]=@{Style=$style;Controls=$rowControls}}
        $script:rowStyle=$style
    }
    $rendered=[Collections.Generic.List[Windows.UIElement]]::new()
    $built=0
    if (-not $names.Count) {
        $Cards.Children.Clear()
        [void]$Cards.Children.Add((New-DeckText 'Your deck is clear. Pick an account and launch a terminal. Already-running sessions attach after their next codex-auth launch.' '#9BB5D9' 14)); Update-DeckWidgetHeight; return
    }
    foreach ($name in $names) {
        $connected=@($sessions | Where-Object Account -eq $name); $row=$cache[$name]
        $profile=$profiles[$name]
        $rowKey=($connected.ProcessId -join ',')+'/'+($connected.Folder -join ',')+'/'+$profileStamps[$name]+'/'+($name -in $pins)+'/'+[DateTimeOffset]::Now.ToString('yyyyMMddHHmm')+'/'+$row.Error+'/'+$row.CheckedAt+'/'+$history[$name].Outcome
        $healthKey=[string]$tasks.ContainsKey($name)+'/'+$manualChecks.ContainsKey($name)
        $saved=$rowControls[$name]
        if($saved){
            if($saved.Key -ne $rowKey -or -not [object]::ReferenceEquals($saved.Record,$row)){
                $health=$saved.Card.Resources['HealthSummary']
                [void](New-DeckHealthSummary $name $row ([int]$health.FontSize) $health)
                $dot=$saved.Card.Resources['ConnectionDot']; $color=if($connected.Count){'#69DEC0'}else{'#65738A'}
                if($dot -is [Windows.Shapes.Ellipse]){$dot.Fill=$color}else{$dot.Foreground=$color}
                $saved.Card.Resources['Title'].Text=$(if($name -in $pins){'★ '}else{''})+$name
                $info=$saved.Card.Resources['AccountInfo']
                if($info){
                    $plan=if($row.PlanType){$row.PlanType}else{$profile.PlanType}
                    $email=if($row.Email){$row.Email}else{$profile.Email}
                    if($settings.MaskEmail){$email=$email -replace '^(.).*(@.*)$','$1***$2'}
                    $meta=@(); if($settings.ShowPlan){$meta+=$(if($plan){$plan.ToUpperInvariant()}else{'?'})}; if($settings.ShowEmail -and $email){$meta+=$email}
                    $info.Text=$meta -join '  /  '
                }
                $saved.Card.Child.Content=if($expandedRows[$name]){if($widget){New-DeckWidgetDetails $name}else{New-DeckPanelDetails $name}}else{$null}
                $saved.Key=$rowKey; $saved.Record=$row
            }
            $saved.Card.Child.IsExpanded=[bool]$expandedRows[$name]
            if($saved.HealthKey -ne $healthKey){
                $health=$saved.Card.Resources['HealthSummary']; $health.Tag.Text=if($tasks.ContainsKey($name) -or $manualChecks.ContainsKey($name)){' · checking'}elseif($row.Error){' · check failed'}else{''}
                $saved.HealthKey=$healthKey
            }
            $rendered.Add($saved.Card); continue
        }
        $built++
        if($widget){$card=New-DeckWidgetCard $name $row $profile $connected.Count; $rowControls[$name]=@{Key=$rowKey;HealthKey=$healthKey;Record=$row;Card=$card}; $rendered.Add($card); continue}
        $plan=if($row.PlanType){$row.PlanType}else{$profile.PlanType}
        $displayEmail=if($row.Email){$row.Email}else{$profile.Email}
        $card=[Windows.Controls.Border]::new(); $card.CornerRadius='6'; $card.Margin='0,0,0,5'; $card.Padding=if($settings.Compact){'8,5'}else{'10,8'}
        $card.Background=[Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#1C1E22'),[Windows.Media.ColorConverter]::ConvertFromString('#101113'),90)
        $card.BorderBrush=[Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#383B40'),[Windows.Media.ColorConverter]::ConvertFromString('#202226'),90); $card.BorderThickness='1'
        $grid=[Windows.Controls.Grid]::new(); $card.Child=$grid
        foreach($width in @('12','90','*','Auto')){$col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width); [void]$grid.ColumnDefinitions.Add($col)}
        $dot=New-DeckText ([string][char]0x25CF) $(if($connected.Count){'#69DEC0'}else{'#60646B'}) 9
        $dot.VerticalAlignment='Center'; [void]$grid.Children.Add($dot)
        $title=New-DeckText ($(if($name -in $pins){'★ '}else{''})+$name) '#E4E7EC' $settings.FontSize; $title.FontWeight='SemiBold'; $title.VerticalAlignment='Center'; $title.TextWrapping='NoWrap'; $title.TextTrimming='CharacterEllipsis'; [Windows.Controls.Grid]::SetColumn($title,1); [void]$grid.Children.Add($title)
        $meta=@(); if($settings.ShowPlan){$meta+=$(if($plan){$plan.ToUpperInvariant()}else{'?'})}
        if($settings.ShowEmail -and $displayEmail){$email=$displayEmail; if($settings.MaskEmail){$email=$email -replace '^(.).*(@.*)$','$1***$2'}; $meta+=$email}
        $info=New-DeckText ($meta -join '  /  ') '#858B95' ($settings.FontSize-1); $info.TextWrapping='NoWrap'; $info.TextTrimming='CharacterEllipsis'; $info.Margin='0,0,12,0'; $info.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($info,2); [void]$grid.Children.Add($info)
        $status=Get-DeckHealth $row
        $quotaColor='#69DEC0'
        $text=New-DeckHealthSummary $name $row ($settings.FontSize-1); [Windows.Controls.Grid]::SetColumn($text,3); [void]$grid.Children.Add($text)
        $card.ContextMenu=New-DeckEntryMenu $name
        $card.Resources['HealthSummary']=$text; $card.Resources['ConnectionDot']=$dot; $card.Resources['Title']=$title; $card.Resources['AccountInfo']=$info
        $card.Child=$null; $card.Child=New-DeckExpander $name $grid 'Panel'
        $rowControls[$name]=@{Key=$rowKey;HealthKey=$healthKey;Record=$row;Card=$card}; $rendered.Add($card)
    }
    $structureChanged=$false
    # Retain existing visuals and scroll position; only insert/remove changed rows.
    for($index=0;$index -lt $rendered.Count;$index++){
        $card=$rendered[$index]
        if($index -lt $Cards.Children.Count -and [object]::ReferenceEquals($Cards.Children[$index],$card)){continue}
        $structureChanged=$true
        if($Cards.Children.Contains($card)){$Cards.Children.Remove($card)}
        $Cards.Children.Insert($index,$card)
    }
    while($Cards.Children.Count -gt $rendered.Count){$structureChanged=$true; $Cards.Children.RemoveAt($Cards.Children.Count-1)}
    if($structureChanged -or $built -gt 0 -or $script:defaultViewHeight){Update-DeckWidgetHeight}

}
function Invoke-DeckTick {
    if($SmokeTest -or $Demo){Render-Deck; return}
    $settingsSignal=Join-Path $root 'warmup-settings-changed.json'
    if(Test-Path -LiteralPath $settingsSignal){
        Remove-Item -LiteralPath $settingsSignal -ErrorAction SilentlyContinue
        $freshSettings=Get-DeckSettings $root
        foreach($key in @($settings.Keys | Where-Object {$_ -like 'Warmup*'})){$settings[$key]=$freshSettings[$key]}
        $script:nextCheck=@{}; $script:lastRender=''
    }
    $warmStateSignal=Join-Path $root 'warmup-state-changed.json'
    if(Test-Path -LiteralPath $warmStateSignal){
        Remove-Item -LiteralPath $warmStateSignal -ErrorAction SilentlyContinue
        foreach($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $root 'cache.json')))){if($entry.Account){$cache[$entry.Account]=$entry}}
        $script:history=@{}; foreach($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $root 'warmup.json')))){if($entry.Account){$history[$entry.Account]=$entry}}
        $savedResets=Read-DeckJson (Join-Path $root 'warmup-resets.json'); if($savedResets){foreach($property in $savedResets.PSObject.Properties){$resets[$property.Name]=[long]$property.Value}}
        $script:cacheVersion++; $script:lastRender=''
    }
    $script:sessions=@(Get-DeckSessions $root); Update-DeckPicker
    $signal=Join-Path $root 'show.json'
    if(Test-Path -LiteralPath $signal){$request=Read-DeckJson $signal; Remove-Item -LiteralPath $signal -ErrorAction SilentlyContinue; $window.Show(); $window.WindowState='Normal'; [void]$window.Activate(); if($request.OpenSettings){Show-DeckSettings}}
    $now=[DateTimeOffset]::UtcNow; $unix=$now.ToUnixTimeSeconds()
    $tickWatch=[Diagnostics.Stopwatch]::StartNew(); $cacheDirty=$false; $yieldTick=$false
    foreach($task in @($tasks.Values)){
        $timeout=($now-$task.Started).TotalSeconds -gt 120
        if($timeout){Stop-DeckTask $task}
        if($task.Process.HasExited -and ($timeout -or ($task.Out.IsCompleted -ne $false -and $task.Err.IsCompleted -ne $false))){
            $account=$task.Account; $success=(-not $timeout -and $task.Process.ExitCode -eq 0)
            if($task.Kind -eq 'Check'){
                try{
                    if(-not $success){throw 'Check process failed or timed out.'}
                    $records=@(Expand-DeckCheckRecords ($task.Out.Result | ConvertFrom-Json))
                    if($records.Count -ne 1){throw 'Expected exactly one account result.'}
                    $result=$records[0]
                    if($result.Account -ne $account){throw 'Unexpected account in response.'}
                    $result | Add-Member NoteProperty CheckedAt $now.ToString('o') -Force
                    if($result.Status -eq 'error'){throw $result.Error}
                    $cache[$account]=$result
                    $script:cacheVersion++
                    $previous=Get-DeckWarmupReset $result $resets[$account] $unix
                    if($previous){$resets[$account]=$previous}
                    $five=$result.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
                    if($five.ResetsAtUnix -and [long]$five.ResetsAtUnix -gt $unix -and (-not $previous -or $five.UsedPct -gt 0 -or $unix -gt ([long]$previous+60*$settings.WarmupMaxDelayMinutes))){$resets[$account]=[long]$five.ResetsAtUnix}
                    $nextCheck[$account]=Get-DeckNextCheck $settings $result $now
                    $cacheDirty=$true
                    $script:notice="Updated $account at $($now.ToLocalTime().ToString('HH:mm'))"
                }catch{
                    $nextCheck[$account]=$now.AddMinutes(20); $script:notice="Check failed: $account (20m backoff)"
                    if($cache[$account]){$cache[$account] | Add-Member NoteProperty Error $_.Exception.Message -Force}else{$cache[$account]=[pscustomobject]@{Account=$account;Status='error';Windows=@();Error=$_.Exception.Message}}
                    $script:cacheVersion++; $cacheDirty=$true
                }
            }else{
                $reply=if($success){Get-DeckWarmupReply $task.Out.Result}else{$null}
                $history[$account].Outcome=if($reply){'Replied: '+$reply}elseif($timeout){'Timed out / reply unconfirmed'}elseif($success){'No assistant reply / unconfirmed'}else{'Request failed'}
                $history[$account] | Add-Member NoteProperty Reply ([string]$reply) -Force
                $history[$account] | Add-Member NoteProperty CompletedAt $unix -Force
                Write-DeckJson (Join-Path $root 'warmup.json') @(Get-DeckMapValues $history)
                $manualChecks[$account]=$now; $nextCheck[$account]=$now; $script:notice="Warm-up $account : $($history[$account].Outcome)"
            }
            $task.Process.Dispose(); $tasks.Remove($account); $script:lastRender=''
        }
    }
    if($cacheDirty){Write-DeckJson (Join-Path $root 'warmup-resets.json') $resets; Write-DeckJson (Join-Path $root 'cache.json') @(Get-DeckMapValues $cache); $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker}
    if($tasks.Count -lt 8 -and ($settings.AutoCheck -or $manualChecks.Count)){
        if($tasks.Count -lt 8){
            $automatic=@(); if($settings.AutoCheck){$automatic=@($sessions | ForEach-Object Account | Select-Object -Unique); if($allProfiles){$automatic=@(Get-DeckAccounts)}}
            $due=@(Get-DeckDueAccounts $automatic $manualChecks $nextCheck $now)
            foreach($account in $due){
                if (Get-DeckPoolEntry $suite $account) { $manualChecks.Remove($account); continue }
                if($tasks.Count -ge 8){break}; if($tasks.ContainsKey($account)){continue}
                if($window -and $tickWatch.ElapsedMilliseconds -ge 35){$yieldTick=$true; break}
                $tasks[$account]=Start-DeckTask (Get-DeckCheckCode $suite $account) 'Check' $account; $manualChecks.Remove($account)
            }

        }
    }
    if($batchAccounts.Count -and -not @($batchAccounts | Where-Object { $tasks.ContainsKey($_) -or $manualChecks.ContainsKey($_) }).Count){
        $script:batchAccounts=@(); $script:batchUntil=$now.AddSeconds($settings.MinimumGapSeconds)
        $script:notice='List check complete'
    }
    $StatusButton.IsEnabled=-not $batchAccounts.Count -and $now -ge $batchUntil
    Render-Deck
    if($yieldTick -and -not $script:tickQueued){
        $script:tickQueued=$true
        [void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]{
            $script:tickQueued=$false; Invoke-DeckTick
        })
    }
}
$script:manualChecks=@{}
$script:widget=$false
$MinimizeButton.Add_Click({$window.WindowState='Minimized'})
$ModeButton.Add_Click({Set-DeckMode $(if($widget){'Panel'}else{'Widget'}); Render-Deck})
$CloseButton.Add_Click({$window.Close()})
$AccountPicker.Add_DropDownOpened({
    $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker
    # Measure the complete one-line contents, including unselected accounts.
    $popup=$AccountPicker.Template.FindName('PART_Popup',$AccountPicker)
    if($popup){
        $longest=0
        foreach($item in $AccountPicker.Items){
            $content=$item.Content
            if($content -isnot [Windows.FrameworkElement]){$content=New-DeckText ([string]$content) '#E4EBF5' ([int]$AccountPicker.FontSize); $content.TextWrapping='NoWrap'}
            $content.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
            $longest=[Math]::Max($longest,$content.DesiredSize.Width)
        }
        # Item padding, popup border/padding and scrollbar gutter.
        $popup.Child.Width=[Math]::Min([Windows.SystemParameters]::WorkArea.Width-32,[Math]::Max($AccountPicker.ActualWidth,[Math]::Ceiling($longest+42)))
    }
})
$LaunchButton.Add_Click({Open-DeckTerminal ([string]$AccountPicker.SelectedValue)})
$configMenu=[Windows.Controls.ContextMenu]::new()
$configMenu.Resources=$window.Resources
$accountConfigItem=[Windows.Controls.MenuItem]::new(); $accountConfigItem.Header='Account config'
$defaultsItem=[Windows.Controls.MenuItem]::new(); $defaultsItem.Header='Global defaults'; $defaultsItem.ToolTip='Template for new accounts; not the selected account.'
[void]$configMenu.Items.Add($accountConfigItem); [void]$configMenu.Items.Add($defaultsItem)
$globalRulesItem=[Windows.Controls.MenuItem]::new();$globalRulesItem.Header='Global Rules';$globalRulesItem.Add_Click({Show-DeckGlobalRules $suite $window});[void]$configMenu.Items.Add($globalRulesItem)
$bestItem=[Windows.Controls.MenuItem]::new(); $bestItem.Header='Recommend best account'
$bestItem.Add_Click({
    $names=@(Get-DeckAccounts)
    $choice=@(Get-DeckRecommendations $names $cache) | Select-Object -First 1
    if($choice){$AccountPicker.SelectedValue=$choice.Account; $script:notice=$choice.Account+': '+$choice.Reason}
    else{$script:notice='No fresh usable account. Check accounts first.'}
    $script:lastRender=''; Render-Deck
})
[void]$configMenu.Items.Add($bestItem)
$ConfigButton.ContextMenu=$configMenu
$ConfigButton.Add_Click({
    $accountConfigItem.IsEnabled=$null -ne $AccountPicker.SelectedValue
    $accountConfigItem.ToolTip='Configuration for '+[string]$AccountPicker.SelectedValue
    $configMenu.PlacementTarget=$ConfigButton; $configMenu.Placement='Bottom'; $configMenu.IsOpen=$true
})
$accountConfigItem.Add_Click({if($AccountPicker.SelectedValue){Edit-DeckConfig (Join-Path $suite ('accounts/'+$AccountPicker.SelectedValue+'/config.toml')) ([string]$AccountPicker.SelectedValue)}})
$defaultsItem.Add_Click({Edit-DeckConfig (Join-Path $HOME '.codex/config.toml') 'Global defaults'})
$SettingsButton.Add_Click({Show-DeckSettings})
$toggleProfiles={
    $script:allProfiles=-not $allProfiles
    $script:lastRender=''; Render-Deck
}
$SummaryButton.Add_Click($toggleProfiles)
$StatusButton.ToolTip='Check visible accounts. Show all includes disconnected profiles. Up to eight checks run together. A list cooldown starts when they finish.'
$checkVisible={
    if($batchAccounts.Count -or [DateTimeOffset]::UtcNow -lt $batchUntil){return}
    $names=@($sessions | ForEach-Object Account | Select-Object -Unique)
    if($allProfiles){$names=@(Get-DeckAccounts)}
    $now=[DateTimeOffset]::UtcNow
    foreach($name in $names){
        if($tasks.ContainsKey($name)){continue}
        $at=$cache[$name].CheckedAt
        $manualChecks[$name]=$now
    }
    $script:batchAccounts=@($names); $script:notice="Checking $($names.Count) accounts"; $script:lastRender=''; Render-Deck
}
$StatusButton.Add_Click($checkVisible)
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
        Open-DeckTerminal $name -NewAccount; $dialog.Close()
    })
    $dialog.Add_ContentRendered({[void]$input.Focus(); $input.SelectAll()})
    [void]$dialog.ShowDialog()
})
$deckIcon=[Drawing.Icon]::new((Join-Path $root 'assets/codex-deck.ico'),32,32)
$tray=[Windows.Forms.NotifyIcon]::new(); $tray.Icon=$deckIcon; $tray.Text='Codex Deck'; $tray.Visible=$true
$menu=[Windows.Forms.ContextMenuStrip]::new(); $show=$menu.Items.Add('Show Codex Deck'); $panelMenu=$menu.Items.Add('Control panel'); $widgetMenu=$menu.Items.Add('Floating widget'); $settingsMenu=$menu.Items.Add('Settings'); $exit=$menu.Items.Add('Quit Deck (scheduled warm-up stays on)'); $tray.ContextMenuStrip=$menu
$panelMenu.Add_Click({Set-DeckMode 'Panel'; Render-Deck})
$widgetMenu.Add_Click({Set-DeckMode 'Widget'; Render-Deck})
$settingsMenu.Add_Click({$window.Show(); Show-DeckSettings})
$show.Add_Click({$window.Show(); $window.WindowState='Normal'; [void]$window.Activate()})
$tray.Add_DoubleClick({$window.Show(); $window.WindowState='Normal'; [void]$window.Activate()})
$exit.Add_Click({$script:quit=$true; $window.Close()})
$window.Add_Closing({param($sender,$eventArgs)
    Save-DeckView
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
$window.Width=$settings.Width; $window.Height=[Math]::Max(100,$settings.Height); Set-DeckAppearance; Update-DeckPicker
Set-DeckMode $settings.ViewMode -Initial
$window.Add_SizeChanged({if(-not $script:sizing){[void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded,[Action]{Update-DeckWidgetHeight})}})
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
        $script:supportTestPath=Join-Path ([IO.Path]::GetTempPath()) ('deck-support-test-'+[guid]::NewGuid().ToString('N')+'.json')
        $settingsTest=Show-DeckSettings -TestUI
        $failoverAccounts=$settingsTest.Controls.FailoverAccounts; $failoverMembership=$failoverAccounts.Resources['Membership']; $failoverMembers=$failoverAccounts.Resources['Members']
        if (-not $settingsTest.Controls.ContainsKey('FailoverEnabled') -or $settingsTest.Controls.FailoverMode.Items.Count -ne 2 -or $settingsTest.Controls.FailoverEnabled.IsChecked -or $failoverMembership.Items.Count -ne 4 -or $failoverMembership.SelectedIndex -ne 3 -or $failoverMembers.Visibility -ne 'Visible') { throw 'Failover Settings controls/default failed.' }
        $failoverMembership.SelectedIndex=2
        if($failoverMembers.Visibility -ne 'Collapsed'){throw 'Dynamic failover membership did not hide the selected-account list.'}
        $failoverMembership.SelectedIndex=3
        $headers=@($settingsTest.Tabs.Items | ForEach-Object Header)
        if ($headers -notcontains 'Environments') { throw 'Environment sharing Settings tab missing.' }
        $environmentUI=$settingsTest.Environment
        if($environmentUI.Name.Text -ne 'pool' -or $environmentUI.Name.SelectedItem -ne 'pool'){throw 'Environment picker did not select its default pool.'}
        [void]$environmentUI.Name.ApplyTemplate(); $environmentEditor=$environmentUI.Name.Template.FindName('PART_EditableTextBox',$environmentUI.Name)
        if(-not $environmentEditor -or $environmentEditor.Text -ne 'pool' -or $environmentEditor.Visibility -ne 'Visible'){throw 'Editable environment picker did not render its selected name.'}
        if($environmentUI.Membership.Items.Count -ne 4 -or $environmentUI.Membership.SelectedIndex -ne 0 -or $environmentUI.Mode.SelectedItem -ne 'Ordered' -or $environmentUI.Members.Visibility -ne 'Collapsed'){throw 'Membership/rotation defaults failed.'}
        $environmentUI.Membership.SelectedIndex=3
        if($environmentUI.Members.Visibility -ne 'Visible'){throw 'Selected membership did not reveal account list.'}
        $environmentUI.Membership.SelectedIndex=1
        if($environmentUI.Members.Visibility -ne 'Collapsed' -or $environmentUI.State.Pools.pool.Members[0] -ne '*free'){throw 'Free membership draft failed.'}
        $environmentUI.Resources.SelectedIndex=0
        $recipient=$environmentUI.Recipients.Children[0]; $recipient.IsChecked=$true
        $recipient.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if($environmentUI.State.Changes.Count -ne 1){throw 'Sharing checkbox did not stage its change.'}
        $environmentUI.Owner.SelectedItem='account1'
        if(@($environmentUI.Resources.Items | ForEach-Object Resource) -contains 'memories' -or @($environmentUI.Recipients.Children | Where-Object IsChecked).Count){throw 'Owner change retained stale resources or selections.'}
        $environmentUI.Owner.SelectedItem='pool'
        if(-not $environmentUI.Recipients.Children[0].IsChecked){throw 'Owner change lost its pending sharing draft.'}
        if($headers -notcontains 'Checks & Warmup' -or $headers -contains 'Checks' -or $headers -contains 'Usage Warmup'){throw 'Checks and warmup must share one tab.'}
        $checkPanel=$settingsTest.Controls.AutoCheck.Parent
        if($checkPanel -ne $settingsTest.Controls.WarmupEnabled.Parent -or $checkPanel.Children.IndexOf($settingsTest.Controls.AutoCheck) -ge $checkPanel.Children.IndexOf($settingsTest.Controls.WarmupEnabled)){throw 'Checks must appear above warmup.'}
        $schedulingControl=$settingsTest.Controls.WarmupSchedulingEnabled
        if($schedulingControl -isnot [Windows.Controls.Button] -or [bool]$schedulingControl.Tag -or $schedulingControl.Content -ne 'Enable background scheduling'){throw 'Background scheduling must be an explicit opt-in button.'}
        $schedulingControl.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if(-not [bool]$schedulingControl.Tag -or $schedulingControl.Content -ne 'Disable background scheduling' -or -not $settingsTest.Controls.WarmupEnabled.IsChecked){throw 'Background scheduling opt-in did not update its saved state.'}
        $before=$allProfiles
        $SummaryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if($allProfiles -eq $before){throw 'Summary did not switch account view.'}
        $SummaryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if($allProfiles -ne $before){throw 'Summary did not restore account view.'}
        $StatusButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        foreach($name in @($sessions | ForEach-Object Account | Select-Object -Unique)){if(-not $manualChecks.ContainsKey($name)){throw 'Status check skipped a visible account.'}}
        $manualChecks.Clear(); $script:batchAccounts=@()
        if($settingsTest.Dialog.WindowStyle -ne 'None' -or $settingsTest.Dialog.ShowInTaskbar){throw 'Settings chrome/taskbar failed.'}
        if(-not $settingsTest.Controls.ShowResetCredits.IsChecked){throw 'Reset credits must default on.'}
        if($settingsTest.Controls.ShowResetCredits.Parent -eq $settingsTest.Controls.ShowEmail.Parent){throw 'Details sections are not grouped.'}
        $settings.ShowResetCredits=$false
        if(@((New-DeckPanelDetails 'account1').Children | Where-Object {$_ -is [Windows.Controls.Grid] -and $_.Children[0].Text -eq 'Reset credits'}).Count){throw 'Reset credits toggle ignored.'}
        $settings.ShowResetCredits=$true
        $settingsTest.Dialog.Close()
        'PASS: Settings includes opt-in failover, selection mode and saved account pool.'

        function Find-DeckVisual($node,[type]$type){
            if($node -is $type){$node}
            for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++){Find-DeckVisual ([Windows.Media.VisualTreeHelper]::GetChild($node,$i)) $type}
        }
        $script:testPickerNames=@('account1','account2'); $settings.AccountPickerUsage=$true; $script:lastPicker=[DateTimeOffset]::MinValue; Update-DeckPicker
        $pickerEntry=@($AccountPicker.Items | Where-Object Tag -eq 'account1')[0]
        if((($pickerEntry.Content.Inlines | ForEach-Object Text) -join '') -notmatch '5h 28%' -or $pickerEntry.Content.TextWrapping -ne 'NoWrap'){throw ('Picker: '+ [string]::Join('|',@($pickerEntry.Content.Inlines | ForEach-Object Text)))}
        $AccountPicker.SelectedValue='account1'
        if($AccountPicker.SelectedValue -ne 'account1'){throw 'Account picker identity lost.'}
        # Exercise the actual dropdown, including an unselected account.
        $otherEntry=@($AccountPicker.Items | Where-Object Tag -ne 'account1')[0]
        if($otherEntry){
            $otherName=[string]$otherEntry.Tag; $previousRecord=$cache[$otherName]
            $record=$cache.account1 | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $record.Account=$otherName
            $cache[$otherName]=$record
            Set-DeckMode 'Panel' -Initial; $window.Show(); $window.UpdateLayout(); $AccountPicker.ApplyTemplate() | Out-Null; $AccountPicker.IsDropDownOpen=$true
            [Windows.Forms.Application]::DoEvents()
            $popup=$AccountPicker.Template.FindName('PART_Popup',$AccountPicker); $popup.Child.UpdateLayout()
            $otherEntry.ApplyTemplate() | Out-Null
            $presenter=@(Find-DeckVisual $otherEntry ([Windows.Controls.ContentPresenter]))[0]
            $visibleText=($presenter.Content.Inlines | ForEach-Object Text) -join ''
            if(-not $presenter -or $visibleText -notmatch '5h 28%' -or $visibleText -notmatch 'Last checked:'){throw 'Unselected dropdown account is missing usage/reset details'}
            $longest=0
            foreach($item in $AccountPicker.Items){$item.Content.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity)); $longest=[Math]::Max($longest,$item.Content.DesiredSize.Width)}
            $expectedWidth=[Math]::Min([Windows.SystemParameters]::WorkArea.Width-32,[Math]::Max($AccountPicker.ActualWidth,[Math]::Ceiling($longest+42)))
            if([Math]::Abs($popup.Child.ActualWidth-$expectedWidth) -gt 1 -or $otherEntry.ActualHeight -gt 40){throw 'Usage dropdown does not fit its longest line or rows are not compact'}
            $AccountPicker.IsDropDownOpen=$false; Set-DeckMode $PreviewMode -Initial
            if($previousRecord){$cache[$otherName]=$previousRecord}else{$cache.Remove($otherName)}
            Write-Output 'PASS: open account picker renders usage/reset details on unselected rows in a compact content-sized popup.'
        }

        $script:testPickerNames=$null
        $folderUI=Select-DeckFolder $HOME -TestUI
        if($folderUI.PathBox.Text -ne $HOME -or $folderUI.Folders.Items.Count -eq 0){throw 'Folder picker initialization failed.'}
        $folderUI.Dialog.Close()
        if(-not $settings.WidgetOneLine){throw 'One-line widget entries must default on'}
        $quotaReset=[DateTimeOffset]::FromUnixTimeSeconds([long]$cache.account1.Windows[0].ResetsAtUnix).ToLocalTime().ToString('HH:mm')
        $healthText=((New-DeckHealthSummary 'account1' $cache.account1 9).Inlines | ForEach-Object Text) -join ''
        if($healthText -notmatch [regex]::Escape($quotaReset)){throw 'Collapsed usage omitted its adjacent reset time.'}
        $quotaTrack=New-DeckQuotaTrack $cache.account1.Windows[0] '#69DEC0' $true
        if($quotaTrack.Resources['ResetText'].Text -notmatch [regex]::Escape($quotaReset)){throw 'Expanded usage meter omitted its adjacent reset time.'}
        $single=New-DeckWidgetCard 'account1' $cache.account1 $profiles.account1 1
        $single.Measure([Windows.Size]::new(220,[double]::PositiveInfinity))
        if([Windows.Controls.Grid]::GetRow($single.Resources['HealthSummary']) -ne 0){throw 'Widget summary is not inline'}
        $settings.WidgetOneLine=$false
        $double=New-DeckWidgetCard 'account1' $cache.account1 $profiles.account1 1
        $double.Measure([Windows.Size]::new(220,[double]::PositiveInfinity))
        if($single.DesiredSize.Height -ge $double.DesiredSize.Height){throw 'One-line widget did not reduce row height'}
        $settings.WidgetOneLine=$true
        $settingsUI=Show-DeckSettings -TestUI
        if(@($settingsUI.Controls.WarmupModel.Items | Where-Object {$_ -isnot [string] -or $_ -notmatch '^gpt-' }).Count){throw 'Model picker contains a non-model item.'}
        if($settingsUI.Controls.WarmupModel -isnot [Windows.Controls.ComboBox] -or $settingsUI.Controls.WarmupModel.SelectedItem -ne $settings.WarmupModel){throw 'Model selector failed.'}
        foreach($control in $settingsUI.Controls.Values){if($control.Margin.Bottom -lt 14){throw 'Settings spacing failed.'}}
        if(@($settingsUI.Tabs.Items | ForEach-Object Header) -notcontains 'Backup' -or @($settingsUI.Tabs.Items | ForEach-Object Header) -notcontains 'About'){throw 'Backup/About tabs missing'}
        foreach($header in @('Backup','About','Appearance','Environments','Details','Failover','Checks & Warmup')){
            $settingsUI.Tabs.SelectedItem=@($settingsUI.Tabs.Items | Where-Object Header -eq $header)[0]
            $expected=if($header -in @('Backup','About')){'Collapsed'}else{'Visible'}
            if($settingsUI.Save.Visibility -ne $expected){throw "Unexpected Save visibility on $header"}
        }
        if($settingsUI.SupportPrompt.Visibility -ne 'Visible'){throw 'First-visit support prompt missing'}
        $settingsUI.SupportDismiss.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if($settingsUI.SupportPrompt.Visibility -ne 'Collapsed'){throw 'Support prompt did not dismiss'}
        foreach($days in @(1,34,35,36)){
            Write-DeckJson $script:supportTestPath @{ShownAt=[DateTimeOffset]::Now.AddDays(-$days).ToString('o')}
            $returnVisit=Show-DeckSettings -TestUI
            $expected=if($days -ge 35){'Visible'}else{'Collapsed'}
            if($returnVisit.SupportPrompt.Visibility -ne $expected){throw "Support schedule failed at day $days"}
            if($days -ge 35 -and $returnVisit.Tabs.SelectedItem.Header -ne 'About'){throw 'Support visit must open About'}
            if($days -ge 35){
                $returnVisit.Dialog.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.FrameworkElement]::LoadedEvent))
                $visit=Read-DeckJson $script:supportTestPath
                if(([DateTimeOffset]::Now - [DateTimeOffset]$visit.ShownAt).TotalMinutes -gt 1){throw 'Support visit timestamp was not saved'}
            }
            $returnVisit.Dialog.Close()
        }
        Remove-Item -LiteralPath $script:supportTestPath -ErrorAction SilentlyContinue
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
        $Cards.Children[0].Child.IsExpanded=$true
        $detailLabels=@($Cards.Children[0].Child.Content.Children | Where-Object {$_ -is [Windows.Controls.Grid]} | ForEach-Object {$_.Children[0].Text})
        foreach($label in @('Status','Email','Plan','Terminals','Model','Uptime','Last check','Source','Process IDs','Folders','Warm-up','Credits')){if($label -notin $detailLabels){throw "Missing expanded field: $label"}}
        if($LaunchBar.Visibility -ne 'Visible' -or $Cards.Children.Count -ne 1){throw 'Panel mode failed.'}
        if($window.FindName('AllButton') -or $window.FindName('CheckButton')){throw 'Redundant panel controls remain.'}
        if(-not $window.ShowInTaskbar -or $MinimizeButton.Visibility -ne 'Visible'){throw 'Panel taskbar/minimize failed.'}
        if($MinimizeButton.Parent.Children[0] -ne $MinimizeButton){throw 'Minimize must be the first caption button.'}
        $MinimizeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if($window.WindowState -ne 'Minimized'){throw 'Minimize action failed.'}; $window.WindowState='Normal'
        [void]$configMenu.ApplyTemplate()
        $menuSurface=[Windows.Media.VisualTreeHelper]::GetChild($configMenu,0)
        if($menuSurface -isnot [Windows.Controls.Border] -or $menuSurface.Background.ToString() -ne '#FF141619'){throw 'Configs menu background template failed.'}
        if(-not $window.Icon -or -not $settingsUI.Dialog.Icon){throw 'Application window icon missing.'}
        if($configMenu.Items.Count -ne 4 -or $globalRulesItem.Header -ne 'Global Rules' -or $ConfigButton.Content -ne 'Configs' -or [Windows.Controls.Grid]::GetColumn($NewButton) -ne 0){throw 'Account controls layout failed.'}

        if($chrome.CaptionHeight -ne 62){throw 'Panel caption does not cover top padding.'}
        foreach($button in @($MinimizeButton,$ModeButton,$SettingsButton,$CloseButton)) {
            if(-not [Windows.Shell.WindowChrome]::GetIsHitTestVisibleInChrome($button)){throw 'Caption button would be intercepted by dragging.'}
        }
        Set-DeckMode 'Widget' -Initial
        if($window.ShowInTaskbar -or $MinimizeButton.Visibility -ne 'Collapsed'){throw 'Widget taskbar/minimize failed.'}
        if($chrome.CaptionHeight -ne 54){throw 'Widget caption does not cover top padding.'}
        Render-Deck
        $savedSessions=$sessions
        $script:sessions=@(1..4 | ForEach-Object {[pscustomobject]@{Account="account$_";ProcessId=$PID;StartedAt=[DateTimeOffset]::Now.ToString('o')}})
        foreach($testMode in @('Panel','Widget')){
            $viewStates.Clear(); Set-DeckMode $testMode -Initial; $script:expandedRows=@{}; $script:lastRender=''; Render-Deck
            $window.Height=$window.MinHeight
            $window.Content.Measure([Windows.Size]::new($window.Width,$window.Height)); $window.Content.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height)); $window.Content.UpdateLayout()
            $count=if($widget){2}else{3}
            $needed=0; for($index=0;$index -lt $count;$index++){$needed+=$Cards.Children[$index].DesiredSize.Height}
            if($CardScroll.ViewportHeight+1 -lt $needed){throw "$testMode minimum clips collapsed entries: $($CardScroll.ViewportHeight) / $needed"}
            $before=$window.Height; $Cards.Children[0].Child.IsExpanded=$true
            $window.Content.UpdateLayout(); Update-DeckWidgetHeight
            $window.Content.Measure([Windows.Size]::new($window.Width,$window.Height)); $window.Content.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height)); $window.Content.UpdateLayout()
            if($window.Height -lt $before -or $CardScroll.ViewportHeight+1 -lt $Cards.Children[0].DesiredSize.Height){throw "$testMode expansion shrinks or clips the entry"}
            if($Cards.Children[0].ToolTip){throw 'Entry hover overlay remains'}
            $entryMenu=$Cards.Children[0].ContextMenu
            if($entryMenu.Items.Count -ne 10 -or $entryMenu.Items[9].Foreground.ToString() -ne '#FFF17D8D'){throw 'Entry actions or red Delete missing'}
            $entryMenu.Items[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
            if(-not $manualChecks.ContainsKey('account1')){throw 'Entry check did not queue its account'}
            $rememberWidth=[Math]::Min([Windows.SystemParameters]::WorkArea.Width,$window.Width+25); $rememberHeight=[Math]::Min([Windows.SystemParameters]::WorkArea.Height,$window.Height+35)
            $window.Width=$rememberWidth; $window.Height=$rememberHeight
            Set-DeckMode $(if($widget){'Panel'}else{'Widget'}); Render-Deck
            Set-DeckMode $testMode; Render-Deck
            if([Math]::Abs($window.Width-$rememberWidth) -gt 1 -or [Math]::Abs($window.Height-$rememberHeight) -gt 1 -or -not $Cards.Children[0].Child.IsExpanded){throw "$testMode state was not restored: $($window.Width)/$rememberWidth, $($window.Height)/$rememberHeight, expanded=$($Cards.Children[0].Child.IsExpanded)"}
        }
        $script:sessions=@(1..40 | ForEach-Object {[pscustomobject]@{Account="account$_";ProcessId=$PID;StartedAt=[DateTimeOffset]::Now.ToString('o')}})
        foreach($session in $sessions){$record=$cache.account1 | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $record.Account=$session.Account; $cache[$session.Account]=$record}
        foreach($testMode in @('Panel','Widget')){
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $viewStates.Clear(); Set-DeckMode $testMode -Initial; $script:expandedRows=@{}; $script:lastRender=''; Render-Deck
            Write-Output ("{0} 40 populated rows: {1} ms" -f $testMode,$watch.ElapsedMilliseconds)
            $window.Width=$window.MinWidth; $window.Height=$window.MinHeight
            $window.Content.Measure([Windows.Size]::new($window.Width,$window.Height)); $window.Content.Arrange([Windows.Rect]::new(0,0,$window.Width,$window.Height)); $window.Content.UpdateLayout()
            $bar=$CardScroll.Template.FindName('PART_VerticalScrollBar',$CardScroll)
            $track=@(Find-DeckVisual $bar ([Windows.Controls.Primitives.Track]))[0]
            if($bar.ActualWidth -gt 8 -or $bar.Maximum -le 0 -or [Math]::Abs($track.ViewportSize-$CardScroll.ViewportHeight) -gt 1 -or $track.Thumb.ActualHeight -gt $bar.ActualHeight){throw "$testMode crowded scrollbar sizing failed: width=$($bar.ActualWidth), requested=$($bar.Width), min=$($bar.MinWidth), style=$($bar.Style), max=$($bar.Maximum), viewport=$($track.ViewportSize)/$($CardScroll.ViewportHeight), thumb=$($track.Thumb.ActualHeight)/$($bar.ActualHeight)"}
            $CardScroll.ScrollToEnd(); $window.Content.UpdateLayout()
            if([Math]::Abs($CardScroll.VerticalOffset-$CardScroll.ScrollableHeight) -gt 1){throw "$testMode cannot scroll to last account"}
        }
        foreach($testMode in @('Panel','Widget')){
            Set-DeckMode $testMode -Initial; $script:expandedRows=@{}; $script:lastRender=''; Render-Deck
            $originalCards=@($Cards.Children)
            $menu=$Cards.Children[1].ContextMenu; $menu.PlacementTarget=$Cards.Children[1]
            $menu.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.ContextMenu]::OpenedEvent))
            if($menu.Items[1].Tag.Account -ne $Cards.Children[1].Child.Tag){throw 'Shared entry menu targets the wrong account'}

            $settings.Width+=1; $settings.WidgetHeight+=1; $script:lastRender=''; Render-Deck
            for($index=0;$index -lt $originalCards.Count;$index++){if(-not [object]::ReferenceEquals($originalCards[$index],$Cards.Children[$index])){throw 'Geometry change rebuilt account controls'}}
            $fullSessions=$sessions; $script:sessions=@($sessions[0]); $script:lastRender=''; Render-Deck
            $script:sessions=$fullSessions; $script:lastRender=''; $filterWatch=[Diagnostics.Stopwatch]::StartNew(); Render-Deck
            for($index=0;$index -lt $originalCards.Count;$index++){if(-not [object]::ReferenceEquals($originalCards[$index],$Cards.Children[$index])){throw 'Filter switch rebuilt cached rows'}}
            Write-Output ("{0}: cached 40-account list restored in {1} ms." -f $testMode,$filterWatch.ElapsedMilliseconds)
            foreach($session in $sessions){$manualChecks[$session.Account]=[DateTimeOffset]::UtcNow}
            $watch=[Diagnostics.Stopwatch]::StartNew(); $script:lastRender=''; Render-Deck
            for($index=0;$index -lt $originalCards.Count;$index++){if(-not [object]::ReferenceEquals($originalCards[$index],$Cards.Children[$index])){throw 'Checking rebuilt unchanged rows'}}
            Write-Output ("{0} 40-account Check state update: {1} ms (rows retained)" -f $testMode,$watch.ElapsedMilliseconds)
            $manualChecks.Clear()
            $CardScroll.ScrollToEnd(); $window.Content.UpdateLayout()
            $beforeOffset=$CardScroll.VerticalOffset; $beforeExtent=$CardScroll.ExtentHeight
            foreach($session in $sessions){
                $record=$cache[$session.Account] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $record.CheckedAt=[DateTimeOffset]::UtcNow.ToString('o'); $record.Windows[0].RemainingPct=17
                $cache[$session.Account]=$record
            }
            $script:lastRender=''; Render-Deck; $window.Content.UpdateLayout()
            for($index=0;$index -lt $originalCards.Count;$index++){if(-not [object]::ReferenceEquals($originalCards[$index],$Cards.Children[$index])){throw 'Completed checks replaced account rows'}}
            if([Math]::Abs($CardScroll.VerticalOffset-$beforeOffset) -gt 1 -or [Math]::Abs($CardScroll.ExtentHeight-$beforeExtent) -gt 1){throw 'Completed checks disturbed scroll position or extent'}
            if($Cards.Children[0].Resources['HealthSummary'].Text -notmatch '17%'){throw 'Retained row did not display new quota'}
            Write-Output "${testMode}: completed results retain rows, quota updates, scroll offset and extent."
            $script:rowControls=@{}; $Cards.Children.Clear(); $script:lastRender=''
            $watch=[Diagnostics.Stopwatch]::StartNew(); Render-Deck
            if($Cards.Children.Count -ne 40){throw 'Account list was not presented in a single render'}
            if(@($Cards.Children | Where-Object {$_.Child.Content}).Count){throw 'Collapsed rows eagerly built details'}
            Write-Output ("{0}: all 40 rows presented together in {1} ms." -f $testMode,$watch.ElapsedMilliseconds)
        }
        $deletePreview=Show-DeckDelete 'account1' -TestUI
        if($deletePreview.WindowStyle -ne 'None' -or -not $deletePreview.Icon){throw 'Delete confirmation is not themed'}
        $deletePreview.Close()
        $script:sessions=$savedSessions; $script:lastRender=''; Render-Deck
        $perf=[Diagnostics.Stopwatch]::StartNew(); for($i=0;$i -lt 100;$i++){Render-Deck}; $perf.Stop()
        'Unchanged render pass: {0:N2} ms average (100 passes).' -f ($perf.Elapsed.TotalMilliseconds/100)
        $originalSuite=$suite;$originalRoot=$root;$originalSettings=$settings
        $settingsFixture=Join-Path ([IO.Path]::GetTempPath()) ('deck-settings-save-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $settingsFixture 'accounts/account1'))
        [void][IO.Directory]::CreateDirectory((Join-Path $settingsFixture 'accounts/account2'))
        Write-DeckJson (Join-Path $settingsFixture 'accounts/account1/auth.json') @{}
        Write-DeckJson (Join-Path $settingsFixture 'accounts/account2/auth.json') @{}
        Set-DeckPoolEntry $settingsFixture pool @('*') Ordered | Out-Null
        foreach($file in @('Deck.EnvironmentSettings.ps1','Deck.SettingsExtras.ps1','Deck.Terminal.ps1','Deck.Failover.ps1')){Copy-Item -LiteralPath (Join-Path $suite $file) -Destination $settingsFixture}
        try{
            $script:suite=$settingsFixture;$script:root=Join-Path $settingsFixture 'deck'
            $draftUI=Show-DeckSettings -TestUI
            $draftUI.Environment.Membership.SelectedIndex=1
            $draftUI.Environment.Resources.SelectedItem=@($draftUI.Environment.Resources.Items | Where-Object Resource -eq 'skills')[0]
            $shareCheck=$draftUI.Environment.Recipients.Children[0];$shareCheck.IsChecked=$true
            $shareCheck.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $draftUI.Controls.MaskEmail.IsChecked=$true
            $draftUI.Controls.FailoverEnabled.IsChecked=$true
            $draftUI.Controls.FailoverMode.SelectedItem='Best'
            $draftFailover=$draftUI.Controls.FailoverAccounts
            $draftFailover.Resources['Membership'].SelectedIndex=3
            [void]$draftFailover.Resources['Members'].SelectedItems.Add('account2')
            $draftUI.Controls.AutoCheck.IsChecked=$true
            $draftUI.Tabs.SelectedItem=@($draftUI.Tabs.Items | Where-Object Header -eq 'Appearance')[0]
            $draftUI.Save.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if($draftUI.Error.Text){throw $draftUI.Error.Text}
            $savedSettings=Read-DeckJson (Join-Path $root 'settings.json')
            if((Get-DeckPoolEntry $settingsFixture pool).Accounts[0] -ne '*free' -or -not $savedSettings.MaskEmail){throw 'Save settings did not persist environment and another tab together.'}
            if(-not $savedSettings.FailoverEnabled -or $savedSettings.FailoverMode -ne 'Best' -or $savedSettings.FailoverAccounts -ne 'account2' -or -not $savedSettings.AutoCheck){throw 'Save settings did not persist failover and general controls.'}
            if(-not $settings.FailoverEnabled -or $settings.FailoverAccounts -ne 'account2' -or -not $settings.MaskEmail){throw 'Saved settings did not update the live Deck state.'}
            $reopenedUI=Show-DeckSettings -TestUI
            try{
                foreach($key in @($settings.Keys | Where-Object {$reopenedUI.Controls.ContainsKey($_)})){
                    $control=$reopenedUI.Controls[$key]
                    $actual=if($settings[$key] -is [bool]){[bool]$control.IsChecked}elseif($key -eq 'WarmupAccounts'){@($control.SelectedItems) -join ','}elseif($key -eq 'FailoverAccounts'){$membership=$control.Resources['Membership']; if($membership.SelectedIndex -eq 3){@($control.Resources['Members'].SelectedItems) -join ','}else{@('*','*free','*paid')[$membership.SelectedIndex]}}elseif($key -in @('WarmupModel','ViewMode','FailoverMode')){[string]$control.SelectedItem}elseif($settings[$key] -is [int]){[int]$control.Text}else{$control.Text.Trim()}
                    if($actual -ne $settings[$key]){throw "Reopened setting does not match saved value: $key"}
                }
            }finally{$reopenedUI.Dialog.Close()}
            if(-not @((Get-DeckSharing $settingsFixture account1).Bindings).Count){throw 'Save settings did not persist pending resource sharing.'}
            $rulesUI=Show-DeckGlobalRules $settingsFixture -TestUI
            $rulesUI.Editor.Text='Always answer hi.'
            $rulesUI.Save.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if($rulesUI.Error.Text -or [IO.File]::ReadAllText((Join-Path $root 'global-rules.md')) -ne 'Always answer hi.'){throw 'Global Rules editor did not save.'}
            'PASS: Save settings persists drafts across tabs; Global Rules editor saves plain text.'
        }finally{$script:suite=$originalSuite;$script:root=$originalRoot;$script:settings=$originalSettings}
        'PASS: WPF constructed and synthetic account card rendered; no network calls or warm-ups.'
    }else{
        if(-not $Demo){Sync-DeckWarmupStartup $suite $settings}
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
                        1 {if($Background -and $window.IsVisible){throw 'Background startup showed the window.'}; $window.Close(); if($window.IsVisible -or -not $tray.Visible){throw 'Close did not preserve tray.'}}
                        2 {if(-not $tray.Visible){throw 'Tray disappeared after hide.'}; $window.Show(); if(-not $window.IsVisible){throw 'Restore failed.'}}
                        3 {$focusWindow=[Windows.Window]::new(); $focusWindow.Title='Deck focus test'; $focusWindow.Width=200; $focusWindow.Height=100; $focusWindow.Show(); [void]$focusWindow.Activate(); $script:focusWindow=$focusWindow}
                        4 {if(-not $window.IsVisible -or -not $tray.Visible){throw 'Deck disappeared on focus loss.'}; $focusWindow.Close(); Set-DeckMode 'Panel'; Render-Deck; if($LaunchButton.Content -ne 'Open Terminal'){throw 'Terminal label mismatch.'}; Set-DeckMode 'Widget'; Render-Deck}
                        5 {$script:quit=$true; $lifeTimer.Stop(); $window.Close()}
                    }
                }catch{$script:lifecycleFailure=$_.Exception.Message; $script:quit=$true; $lifeTimer.Stop(); $app.Shutdown()}
            }); $lifeTimer.Start()
        }
        if($OpenSettings){$window.Add_ContentRendered({if(-not $script:openedInitialSettings){$script:openedInitialSettings=$true; Show-DeckSettings}})}
        $app.MainWindow=$window
        if(($Background -or ($settings.ViewMode -eq 'Tray' -and $Attach)) -and -not $OpenSettings){
            # Run the dispatcher and tray without ever showing the desktop window.
            [void]$app.Run()
        }else{
            [void]$app.Run($window)
        }
        if($LifecycleTest){if($lifecycleFailure){throw $lifecycleFailure}; 'PASS: real application close-to-tray, persistent icon, restore, view switching, and quit. No network or warm-ups.'}
    }
}catch{
    [IO.File]::AppendAllText((Join-Path $root 'errors.log'),([DateTimeOffset]::Now.ToString('o')+"`n"+$_.ToString()+"`n"+$_.ScriptStackTrace+"`n"))
    throw
}finally{
    $timer.Stop(); foreach($worker in @($tasks.Values)){Stop-DeckTask $worker; $worker.Process.Dispose()}; $tray.Dispose(); $deckIcon.Dispose()
    if($created){$mutex.ReleaseMutex()}; $mutex.Dispose()
}
