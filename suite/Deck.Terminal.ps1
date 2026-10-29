# Terminal administration for Codex Deck. Windows PowerShell 5.1, no extra packages.
function ConvertTo-DeckTerminalText($Value, [int]$Width = 200) {
    $text = ([string]$Value -replace '[\x00-\x1f\x7f-\x9f]', ' ')
    if ($text.Length -gt $Width) { return $text.Substring(0, [Math]::Max(0, $Width - 1)) + '~' }
    return $text
}
function Get-DeckTerminalAccountLabel([string]$Account,[string]$Harness) {
    $prefix=if($Harness){$Harness.ToLowerInvariant()+'-'}else{$null}
    if($prefix -and $Account.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $Account.Substring($prefix.Length)}
    return $Account
}
function Expand-DeckTerminalRecords($Value) {
    foreach ($entry in $Value) {
        if ($entry -is [array]) { Expand-DeckTerminalRecords $entry }
        elseif ($entry -and $entry.PSObject.Properties['value']) { Expand-DeckTerminalRecords $entry.value }
        elseif ($entry.Account -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$') { $entry }
    }
}
function Get-DeckTerminalCache([string]$Root) {
    return Get-DeckUsageCache $Root
}
function Get-DeckTerminalCacheStamp([string]$Root) {
    $parts=@()
    foreach($name in 'cache.json','terminal-cache.json'){
        try{$file=Get-Item -LiteralPath (Join-Path $Root $name) -ErrorAction Stop;$parts+=('{0}:{1}:{2}' -f $name,$file.Length,$file.LastWriteTimeUtc.Ticks)}
        catch{$parts+=($name+':missing')}
    }
    return $parts -join '|'
}
function Format-DeckTerminalQuota($Window) {
    if (-not $Window -or $null -eq $Window.RemainingPct) { return '[----------]   ?' }
    $pct = [Math]::Min(100, [Math]::Max(0, [double]$Window.RemainingPct))
    $bars = [int][Math]::Floor($pct / 10)
    return '[{0}{1}] {2,3}%' -f ('#' * $bars), ('-' * (10 - $bars)), [int]$pct
}
function Format-DeckTerminalReset($Window) {
    if(-not $Window -or -not $Window.ResetsAtUnix){return '-'}
    $at=[DateTimeOffset]::FromUnixTimeSeconds([long]$Window.ResetsAtUnix).ToLocalTime()
    if($at -le [DateTimeOffset]::Now){return 'due'}
    return $at.ToString('MMM dd HH:mm')
}
function Get-DeckTerminalResetWindow($Record, $PrimaryWindow) {
    if (-not $Record) { return $PrimaryWindow }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $blocking = @($Record.Windows | Where-Object {
        (-not $_.ResetsAtUnix -or [long]$_.ResetsAtUnix -gt $now) -and
        ($_.Dead -or ($null -ne $_.RemainingPct -and [double]$_.RemainingPct -le 0))
    })
    if ($blocking.Count) {
        # When one or more current windows block requests, only their reset can
        # make the account usable. Do not show an earlier, healthy 5-hour reset.
        return @($blocking | Where-Object ResetsAtUnix | Sort-Object { [long]$_.ResetsAtUnix } | Select-Object -First 1)
    }
    if ($PrimaryWindow) { return $PrimaryWindow }
    return @($Record.Windows | Where-Object ResetsAtUnix | Sort-Object { [long]$_.ResetsAtUnix } | Select-Object -First 1)
}
function Get-DeckTerminalHealth($Record) {
    if (-not $Record) { return 'Not checked' }
    if ($Record.Error -or $Record.Status -eq 'error') { return 'Check failed' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $current = @($Record.Windows | Where-Object { -not $_.ResetsAtUnix -or [long]$_.ResetsAtUnix -gt $now })
    if (@($current | Where-Object { $_.Dead -or ($null -ne $_.RemainingPct -and [double]$_.RemainingPct -le 0) }).Count) { return 'Exhausted' }
    if (@($Record.Windows).Count -gt $current.Count) { return 'Reset passed' }
    if ($Record.Status -ne 'available') { return 'Unavailable' }
    return 'Ready'
}
function Get-DeckTerminalThemePageSize([string]$Theme, [int]$Height) {
    switch ($Theme) {
        'Focus' { return [Math]::Max(1,$Height - 20) }
        'Cards' { return [Math]::Max(1,[int][Math]::Floor(($Height - 15) / 2)) }
        'Ledger' { return [Math]::Max(1,$Height - 18) }
        'Split' { return [Math]::Max(1,$Height - 15) }
        default { return [Math]::Max(1,$Height - 18) }
    }
}
function Get-DeckTerminalDashboardPageSize([string]$Theme,[int]$Height,[bool]$ShowShortcuts,[string]$Harness=$null,[bool]$HasLastConversation=$false) {
    $lastPenalty=if($HasLastConversation){1}else{0}
    if($Theme -in @('Focus','Cards','Ledger','Split')){
        $pageSize=Get-DeckTerminalThemePageSize $Theme $Height
        if($ShowShortcuts){
            if($Harness -eq 'Claude'){if($Theme -eq 'Cards'){$pageSize-=1}}
            elseif($Harness){$pageSize-=1}
            else{switch($Theme){
                'Focus'{$pageSize-=4}
                'Cards'{$pageSize-=2}
                'Ledger'{$pageSize-=4}
                'Split'{$pageSize-=4}
            }}
        }elseif($Theme -eq 'Cards'){$pageSize+=2}else{$pageSize+=5}
        return [Math]::Max(1,$pageSize-$lastPenalty)
    }
    $pageSize=$Height-18
    if($ShowShortcuts){if($Harness){$pageSize-=2}else{$pageSize-=4}}
    else{if($Harness){$pageSize+=1}else{$pageSize+=4}}
    return [Math]::Max(1,$pageSize-$lastPenalty)
}
function Get-DeckTerminalShortcutTable([string]$Harness,[int]$Width,[bool]$Themed=$false,[bool]$CompactAdjusting=$false,[bool]$AutoCompact=$false,[int]$CompactThreshold=55,[string]$CompactMode='Native',$WarmupSettings=$null) {
    $rows=[Collections.Generic.List[object]]::new()
    if($Themed){
        if($Harness -eq 'Claude'){
            $rows.Add(@{Label='NAVIGATE';Text='Enter open   / search   Q quit'})
            $rows.Add(@{Label='CHECK';Text='R selected sign-in   A all sign-ins'})
            $rows.Add(@{Label='ACCOUNTS';Text='L login   N new   F2 rename   Del delete   M mask'})
            $rows.Add(@{Label='DISPLAY';Text='D desktop   S settings   Y Analytics'})
            $rows.Add(@{Label='FILES';Text='G defaults   I instructions   E memory folder   K skills'})
            $rows[2].SeparatorBefore=$true
        }elseif($Harness -eq 'Antigravity'){
            $rows.Add(@{Label='NAVIGATE';Text='Enter open Antigravity   / search   Q quit'})
            $rows.Add(@{Label='CHECK';Text='R selected credentials   A all credentials'})
            $rows.Add(@{Label='ACCOUNTS';Text='L login   N new   F2 rename   Del delete   M mask'})
            $rows.Add(@{Label='DISPLAY';Text=('D desktop   S settings   F failover {0}   Y Analytics' -f $(if($WarmupSettings.HarnessAntigravityFailoverEnabled){'ON'}else{'OFF'}))})
            $rows.Add(@{Label='FILES';Text='G defaults   I instructions   E learned rules   K skills'})
            $rows[2].SeparatorBefore=$true
        }elseif($Harness){
            $rows.Add(@{Label='NAVIGATE';Text=('Enter open {0}   / search   Q quit' -f (Get-DeckHarness $Harness).Name)})
            $rows.Add(@{Label='MANAGE';Text='G global   F2 rename'})
            $rows.Add(@{Label='ACCOUNTS';Text='L login   N new   Del delete   M mask'})
            $rows.Add(@{Label='DISPLAY';Text='D desktop   S settings   Y Analytics'})
            $rows.Add(@{Label='FILES';Text='I instructions   E memories   K skills'})
            $rows[2].SeparatorBefore=$true
        }else{
            $rows.Add(@{Label='LAUNCH';Text='Enter launch   / search   B best   Q quit'})
            $rows.Add(@{Label='MANAGE';Text='R check   A all   J auto-login   H history'})
            $rows.Add(@{Label='ACCOUNTS';Text='F2 rename   L login   N new   Del delete   M mask'})
            $rows.Add(@{Label='OPEN';Text='D desktop   S settings   Y Analytics'})
            $rows.Add(@{Label='FILES';Text='G global   V auth helper   I instructions   E memories   K skills'})
            $rows.Add(@{Label='WARM-UP';Text='U run now   T daily times   W select account   P pause/resume'})
            $rows.Add(@{Label='COMPACT';Text=$(if($CompactAdjusting){'Up/Down 5%   Enter save   Esc cancel'}else{('C compact [{0}] {1} {2}% free   hold C to adjust' -f $(if($AutoCompact){'x'}else{' '}),$CompactMode,$CompactThreshold)})})
            $rows[4].SeparatorBefore=$true
        }
    }elseif($Harness -eq 'Claude'){
        $rows.Add(@{Label='NAVIGATE';Text='Enter open   / search   Q quit'})
        $rows.Add(@{Label='CHECK';Text='R check sign-in   A all sign-ins'})
        $rows.Add(@{Label='ACCOUNTS';Text='L login   N new   F2 rename   Del delete   M mask'})
        $rows.Add(@{Label='DISPLAY';Text='D desktop   S settings   Y Analytics'})
        $rows.Add(@{Label='FILES';Text='G defaults   I instructions   E memory folder   K skills'})
        $rows[2].SeparatorBefore=$true
    }elseif($Harness -eq 'Antigravity'){
        $rows.Add(@{Label='NAVIGATE';Text='Enter open Antigravity   / search   Q quit'})
        $rows.Add(@{Label='CHECK';Text='R selected credentials   A all credentials'})
        $rows.Add(@{Label='ACCOUNTS';Text='L login   N new   F2 rename   Del delete   M mask'})
        $rows.Add(@{Label='DISPLAY';Text=('D desktop   S settings   F failover {0}   Y Analytics' -f $(if($WarmupSettings.HarnessAntigravityFailoverEnabled){'ON'}else{'OFF'}))})
        $rows.Add(@{Label='FILES';Text='G defaults   I instructions   E learned rules   K skills'})
        $rows[2].SeparatorBefore=$true
    }elseif($Harness){
        $rows.Add(@{Label='NAVIGATE';Text=('Enter open {0}   / search   Q quit' -f (Get-DeckHarness $Harness).Name)})
        $rows.Add(@{Label='MANAGE';Text='G global   F2 rename'})
        $rows.Add(@{Label='ACCOUNTS';Text='L login   N new   Del delete   M mask'})
        $rows.Add(@{Label='DISPLAY';Text='D desktop   S settings   Y Analytics'})
        $rows.Add(@{Label='FILES';Text='I instructions   E memories   K skills'})
        $rows[2].SeparatorBefore=$true
    }else{
        $rows.Add(@{Label='NAVIGATE';Text='Enter launch / sign in   / search   B best   Q quit'})
        $rows.Add(@{Label='MANAGE';Text='R refresh   A all   J auto-login   H history'})
        $rows.Add(@{Label='ACCOUNTS';Text='F2 rename   L login   N new   Del delete   M mask'})
        $rows.Add(@{Label='DISPLAY';Text='D desktop   S settings   Y Analytics'})
        $rows.Add(@{Label='FILES';Text='G global   V auth helper   I instructions   E memories   K skills'})
        $rows.Add(@{Label='WARMUP';Text='U run now   T daily times   W select account   P pause/resume'})
        $rows.Add(@{Label='COMPACT';Text=$(if($CompactAdjusting){'Up/Down 5%   Enter save   Esc cancel'}else{('C compact [{0}] {1} {2}% free   hold C to adjust' -f $(if($AutoCompact){'x'}else{' '}),$CompactMode,$CompactThreshold)})})
        $rows[4].SeparatorBefore=$true
    }
    $inside=[Math]::Max(1,[Math]::Min(78,$Width-7))
    $labelWidth=[Math]::Min(10,[Math]::Max(1,$inside-4))
    $valueWidth=[Math]::Max(1,$inside-$labelWidth-3)
    $borderWidth=$inside+2
    $table=[Collections.Generic.List[string]]::new()
    $title=' SHORTCUTS / CTRL TO HIDE '
    $left=[int][Math]::Floor(($borderWidth-$title.Length)/2)
    $right=[Math]::Max(0,$borderWidth-$title.Length-$left)
    $table.Add(('+'+('-' * $left)+$title+('-' * $right)+'+'))
    foreach($row in $rows){
        if($row.SeparatorBefore){$table.Add(('+'+('-' * $borderWidth)+'+'))}
        $label=ConvertTo-DeckTerminalText $row.Label $labelWidth
        $value=ConvertTo-DeckTerminalText $row.Text $valueWidth
        $table.Add(('| {0} | {1} |' -f $label.PadRight($labelWidth),$value.PadRight($valueWidth)))
    }
    $table.Add(('+'+('-' * $borderWidth)+'+'))
    return $table.ToArray()
}
function Initialize-DeckTerminalKeyboard {
    if('CodexDeckNativeKeyboard' -as [type]){return}
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CodexDeckNativeKeyboard {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);
}
'@
}
function Get-DeckTerminalControlKeyDown {
    try{Initialize-DeckTerminalKeyboard;return (([CodexDeckNativeKeyboard]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0)}catch{return $false}
}
function Get-DeckTerminalRecentConversation([string]$SuiteRoot, [string]$Account, [DateTimeOffset]$Since) {
    if($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){return}
    $cutoff=$Since.UtcDateTime.AddSeconds(-2)
    @(Get-DeckSessionHistory $SuiteRoot $Account | Where-Object { $_.Account -eq $Account -and $_.UpdatedAt -ge $cutoff } | Sort-Object UpdatedAt -Descending) | Select-Object -First 1
}
function Format-DeckTerminalLastConversation($Conversation) {
    if(-not $Conversation -or $Conversation.Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $Conversation.Id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){return ''}
    return 'LAST CHAT  {0}  |  codex-auth resume {1}' -f $Conversation.Account,$Conversation.Id
}
function Get-DeckTerminalThemeEntry([string]$Name,$Cache,$Profiles,$Sessions,$Tasks,[bool]$Mask) {
    $row=$Cache[$Name]; $profile=$Profiles[$Name]
    $primary=$row.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
    if(-not $primary){$primary=$row.Windows | Where-Object DurationSeconds -ne 604800 | Select-Object -First 1}
    $weekly=$row.Windows | Where-Object DurationSeconds -eq 604800 | Select-Object -First 1
    $state=if($profile.AuthIssue -in @('token_revoked','oauth_invalid')){'Sign in again'}else{Get-DeckTerminalHealth $row}
    if($profile.PlanType -eq 'pool'){$state='Pooled session'}
    if($profile.Harness -in @('Claude','Antigravity') -and $profile.AuthStatus){$state=$profile.AuthStatus}
    elseif($profile.Harness -and $profile.Harness -ne 'Codex'){$state=$profile.Harness+' / native usage'}
    if($Tasks.ContainsKey($Name)){$state='Checking...'}
    $email=[string]$profile.Email
    if($Mask -and $email){$email=$email -replace '^(.).*?(@.*)$','$1***$2'}
    $checked='never'
    if($row.CheckedAt){try{$checked=([DateTimeOffset]$row.CheckedAt).ToLocalTime().ToString('MMM dd HH:mm')}catch{}}
    if($profile.Harness -eq 'Claude' -and $profile.AuthCheckedAt){try{$checked=([DateTimeOffset]$profile.AuthCheckedAt).ToLocalTime().ToString('MMM dd HH:mm')}catch{}}
    if($profile.Harness -eq 'Antigravity' -and $profile.AuthCheckedAt){try{$checked=([DateTimeOffset]$profile.AuthCheckedAt).ToLocalTime().ToString('MMM dd HH:mm')}catch{}}
    $connected=@(Get-DeckIndexedSessions $Sessions $Name)
    return [pscustomobject]@{
        Name=$Name;DisplayName=(Get-DeckTerminalAccountLabel $Name $profile.Harness);Plan=[string]$profile.PlanType;State=$state;AuthIssue=$profile.AuthIssue;Primary=$primary;Weekly=$weekly
        Reset=(Format-DeckTerminalReset (Get-DeckTerminalResetWindow $row $primary))
        Email=$email;Model=[string]$profile.Model;Effort=[string]$profile.Effort
        Checked=$checked;SessionCount=$connected.Count;Credits=(Format-DeckResetCredits $row)
    }
}
function Format-DeckTerminalThemePercent($Window) {
    if(-not $Window -or $null -eq $Window.RemainingPct){return '  ?%'}
    return ('{0,3}%' -f [int][Math]::Min(100,[Math]::Max(0,[double]$Window.RemainingPct)))
}
function Get-DeckTerminalThemeFrame($Names,$Cache,$Profiles,$Sessions,$Tasks,[int]$Selected,[int]$Width,[int]$Height,[string]$Filter,[string]$Notice,[bool]$Mask,$WarmupSettings,$WarmupHistory,[bool]$AutoCompact,[int]$CompactThreshold,[bool]$CompactAdjusting,[string]$CompactMode,[string]$Theme,$LastConversation=$null,$SessionIndex=$null,[string]$Harness=$null,[bool]$ShowShortcuts=$true) {
    $lines=[Collections.Generic.List[object]]::new()
    if(-not $SessionIndex){$SessionIndex=New-DeckSessionIndex $Sessions}
    function Add-Line([string]$Text,[string]$Color='Gray',[string]$Background='Black') {
        [void]$lines.Add(@{Text=(ConvertTo-DeckTerminalText $Text ([Math]::Max(1,$Width - 1)));Color=$Color;Background=$Background})
    }
    $rule='  '+('-' * [Math]::Max(1,[Math]::Min(78,$Width - 4)))
    $lastConversationLine=Format-DeckTerminalLastConversation $LastConversation
    $pageSize=Get-DeckTerminalDashboardPageSize $Theme $Height $ShowShortcuts $Harness ([bool]$lastConversationLine)
    $start=[int]([Math]::Floor($Selected / $pageSize) * $pageSize)
    $end=[Math]::Min($Names.Count,$start+$pageSize)
    $entries=@(for($i=$start;$i -lt $end;$i++){Get-DeckTerminalThemeEntry $Names[$i] $Cache $Profiles $sessionIndex $Tasks $Mask})
    $active=if($Names.Count){Get-DeckTerminalThemeEntry $Names[$Selected] $Cache $Profiles $sessionIndex $Tasks $Mask}else{$null}
    $filterText=if($Filter){"FILTER  $Filter"}elseif($Harness){"FILTER  All $Harness accounts"}else{'FILTER  All accounts'}
    $dashboardName=if($Harness){(Get-DeckHarness $Harness).Name}else{'Codex'}
    Add-Line ("  $($dashboardName.ToUpperInvariant()) / DECK     $($Theme.ToUpperInvariant())") 'Cyan'
    Add-Line ('  {0} accounts    {1} sessions    {2} checking    |    {3}' -f $Names.Count,@($Sessions).Count,$Tasks.Count,$filterText) 'DarkGray'
    Add-Line $rule 'DarkGray'
    switch($Theme){
        'Focus' {
            Add-Line '  SELECTED ACCOUNT' 'Cyan'
            if($active){
                Add-Line ('  > {0}   {1}   {2}' -f $active.DisplayName,$active.Plan,$active.State) 'White' 'DarkBlue'
                if($Harness){Add-Line ('    LAST PROFILE CHECK  {0}    SESSIONS  {1}' -f $active.Checked,$active.SessionCount) 'Gray'}
                else{Add-Line ('    PRIMARY  {0}    WEEKLY  {1}' -f (Format-DeckTerminalQuota $active.Primary),(Format-DeckTerminalQuota $active.Weekly)) 'Green';Add-Line ('    RESET  {0}    CHECKED  {1}    SESSIONS  {2}' -f $active.Reset,$active.Checked,$active.SessionCount) 'Gray'}
                Add-Line ('    {0}   |   {1} / {2}' -f $active.Email,$active.Model,$active.Effort) 'DarkGray'
            }else{Add-Line '  No matching accounts.' 'Yellow';Add-Line '';Add-Line '';Add-Line ''}
            Add-Line $(if($Harness){'  ACCOUNT ROSTER                         PROVIDER   AUTH STATUS'}else{'  ACCOUNT ROSTER                         PRIMARY   WEEKLY   STATE'}) 'DarkCyan'
            foreach($entry in $entries){
                $marker=if($entry.Name -eq $active.Name){'>'}else{' '}
                if($Harness){Add-Line ('  {0} {1,-27} {2,-10} {3}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 27),$entry.Plan,$entry.State) $(if($marker -eq '>'){'White'}else{'Gray'}) $(if($marker -eq '>'){'DarkBlue'}else{'Black'})}
                else{Add-Line ('  {0} {1,-27} {2,5}   {3,5}   {4}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 27),(Format-DeckTerminalThemePercent $entry.Primary),(Format-DeckTerminalThemePercent $entry.Weekly),$entry.State) $(if($marker -eq '>'){'White'}else{'Gray'}) $(if($marker -eq '>'){'DarkBlue'}else{'Black'})}
            }
        }
        'Cards' {
            foreach($entry in $entries){
                $marker=if($entry.Name -eq $active.Name){'>'}else{' '}
                Add-Line ('  {0} {1,-24} {2,-9} {3}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 24),(ConvertTo-DeckTerminalText $entry.Plan 9),$entry.State) $(if($marker -eq '>'){'White'}else{'Cyan'}) $(if($marker -eq '>'){'DarkBlue'}else{'Black'})
                if($Harness){Add-Line ('      LAST PROFILE CHECK {0}' -f $entry.Checked) 'DarkGray'}else{Add-Line ('      PRIMARY {0}    WEEKLY {1}    RESET {2}' -f (Format-DeckTerminalQuota $entry.Primary),(Format-DeckTerminalQuota $entry.Weekly),$entry.Reset) 'Green'}
            }
            if(-not $Names.Count){Add-Line '  No matching accounts.' 'Yellow'}
            if($active){Add-Line ('  SELECTED  {0}  |  {1} / {2}  |  {3}' -f $active.DisplayName,$active.Model,$active.Effort,$active.Email) 'DarkCyan'}
        }
        'Ledger' {
            Add-Line $(if($Harness){('  {0,-20} {1,-12} {2}' -f 'ACCOUNT','PROVIDER','AUTH STATUS')}else{('  {0,-20} {1,-8} {2,7} {3,7} {4,-15} {5}' -f 'ACCOUNT','PLAN','PRIMARY','WEEK','STATE','RESET')}) 'DarkCyan'
            foreach($entry in $entries){
                $marker=if($entry.Name -eq $active.Name){'>'}else{' '}
                if($Harness){Add-Line ('  {0}{1,-19} {2,-12} {3}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 19),(ConvertTo-DeckTerminalText $entry.Plan 12),$entry.State) $(if($marker -eq '>'){'White'}else{'Gray'}) $(if($marker -eq '>'){'DarkBlue'}else{'Black'})}
                else{Add-Line ('  {0}{1,-19} {2,-8} {3,7} {4,7} {5,-15} {6}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 19),(ConvertTo-DeckTerminalText $entry.Plan 8),(Format-DeckTerminalThemePercent $entry.Primary),(Format-DeckTerminalThemePercent $entry.Weekly),(ConvertTo-DeckTerminalText $entry.State 15),$entry.Reset) $(if($marker -eq '>'){'White'}else{'Gray'}) $(if($marker -eq '>'){'DarkBlue'}else{'Black'})}
            }
            if(-not $Names.Count){Add-Line '  No matching accounts.' 'Yellow'}
            Add-Line $rule 'DarkGray'
            if($active){Add-Line ('  {0}  |  {1} / {2}  |  {3}' -f $active.DisplayName,$active.Model,$active.Effort,$active.Email) 'Cyan';if($Harness){Add-Line ('  Last profile check {0}   Sessions {1}' -f $active.Checked,$active.SessionCount) 'DarkGray'}else{Add-Line ('  Checked {0}   Sessions {1}   Reset credits {2}' -f $active.Checked,$active.SessionCount,$active.Credits) 'DarkGray'}}
            else{Add-Line '';Add-Line ''}
        }
        'Split' {
            $left=[Math]::Min(34,[Math]::Max(24,[int][Math]::Floor($Width * .38)))
            Add-Line (('  {0,-'+$left+'} | ACCOUNT DETAIL') -f 'ACCOUNTS') 'DarkCyan'
            $detail=@()
            if($active){if($Harness){$detail=@($active.DisplayName,('Provider: '+$active.Plan),('Profile status: '+$active.State),('Last profile check: '+$active.Checked),('Sessions: '+$active.SessionCount),('Model: '+$active.Model+' / '+$active.Effort))}else{$detail=@($active.DisplayName,('Plan: '+$active.Plan),('State: '+$active.State),('Primary: '+(Format-DeckTerminalQuota $active.Primary)),('Weekly:  '+(Format-DeckTerminalQuota $active.Weekly)),('Next reset: '+$active.Reset),('Checked: '+$active.Checked),('Sessions: '+$active.SessionCount),('Model: '+$active.Model+' / '+$active.Effort),$active.Email)}}
            for($j=0;$j -lt [Math]::Max($entries.Count,[Math]::Min($detail.Count,$pageSize));$j++){
                $entry=if($j -lt $entries.Count){$entries[$j]}else{$null}
                $marker=if($entry -and $entry.Name -eq $active.Name){'>'}else{' '}
                $leftText=if($entry){if($Harness){'{0} {1,-16} {2}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 16),$entry.State}else{'{0} {1,-16} {2,4}' -f $marker,(ConvertTo-DeckTerminalText $entry.DisplayName 16),(Format-DeckTerminalThemePercent $entry.Primary)}}else{''}
                $rightText=if($j -lt $detail.Count){$detail[$j]}else{''}
                Add-Line (('  {0,-'+$left+'} | {1}') -f $leftText,$rightText) $(if($marker -eq '>'){'White'}else{'Gray'}) $(if($marker -eq '>'){'DarkBlue'}else{'Black'})
            }
            if(-not $Names.Count){Add-Line '  No matching accounts.' 'Yellow'}
        }
    }
    Add-Line ('  {0}-{1} of {2} accounts' -f [Math]::Min($start+1,$Names.Count),$end,$Names.Count) 'DarkGray'
    Add-Line $rule 'DarkGray'
    if(-not $Harness){
        $warmMode=if(-not $WarmupSettings -or -not $WarmupSettings.WarmupEnabled){'PAUSED'}elseif($WarmupSettings.WarmupSchedulingEnabled){'SCHEDULED'}else{'UNSCHEDULED'}
        $warmState=if($WarmupSettings -and $active){if($active.AuthIssue -in @('token_revoked','oauth_invalid')){'Sign in again'}else{Get-DeckWarmupStatus $WarmupSettings $(if($Cache[$active.Name]){$Cache[$active.Name]}else{@{Account=$active.Name}}) $WarmupHistory[$active.Name]}}else{'No account selected'}
        Add-Line ('  STATUS    Warm-up {0}  |  {1}' -f $warmMode,$warmState) 'Yellow'
    }
    if($lastConversationLine){Add-Line ('  '+$lastConversationLine) 'DarkCyan'}
    Add-Line ('  NOTICE    '+$Notice) 'Yellow'
    if($ShowShortcuts){foreach($shortcutLine in @(Get-DeckTerminalShortcutTable $Harness $Width -Themed:$true -CompactAdjusting:$CompactAdjusting -AutoCompact:$AutoCompact -CompactThreshold $CompactThreshold -CompactMode $CompactMode -WarmupSettings $WarmupSettings)){Add-Line ('  '+$shortcutLine) $(if($shortcutLine.StartsWith('+')){'DarkCyan'}else{'Gray'})}}
    else{Add-Line '  Press Ctrl to show shortcuts' 'DarkGray'}
    return $lines.ToArray()
}
function Get-DeckTerminalFrame($Names, $Cache, $Profiles, $Sessions, $Tasks, [int]$Selected, [int]$Width, [int]$Height, [string]$Filter, [string]$Notice, [bool]$Mask = $true, $WarmupSettings = $null, $WarmupHistory = @{}, [bool]$AutoCompact = $false, [int]$CompactThreshold = 55, [bool]$CompactAdjusting = $false, [string]$CompactMode = 'Native', [string]$Theme = 'Default', $LastConversation = $null, $SessionIndex=$null, $Harness=$null,[bool]$ShowShortcuts=$true) {
    if($Theme -in @('Focus','Cards','Ledger','Split')){return Get-DeckTerminalThemeFrame $Names $Cache $Profiles $Sessions $Tasks $Selected $Width $Height $Filter $Notice $Mask $WarmupSettings $WarmupHistory $AutoCompact $CompactThreshold $CompactAdjusting $CompactMode $Theme $LastConversation $SessionIndex $Harness $ShowShortcuts}
    $lines = [Collections.Generic.List[object]]::new()
    if(-not $SessionIndex){$SessionIndex=New-DeckSessionIndex $Sessions}
    function Add-Line([string]$Text, [string]$Color = 'Gray', [string]$Background = 'Black') {
        $lines.Add(@{ Text = (ConvertTo-DeckTerminalText $Text ([Math]::Max(1,$Width - 1))); Color = $Color; Background = $Background })
    }
    $dashboardName=if($Harness){(Get-DeckHarness $Harness).Name}else{'Codex'}
    Add-Line ('  {0} / DECK                                      ACCOUNT CONTROL' -f $dashboardName.ToUpperInvariant()) 'Cyan'
    Add-Line ('  {0} accounts   /   {1} connected sessions   /   {2} checking' -f $Names.Count, @($Sessions).Count, $Tasks.Count) 'DarkGray'
    if($Harness){Add-Line $(if($Harness -eq 'Claude'){'  Isolated Claude profiles  |  sign-in checks available; /usage shows plan limits'}elseif($Harness -eq 'Antigravity'){'  Isolated Antigravity profiles  |  R/A check saved credentials; /usage shows live service status'}else{"  Isolated $Harness profiles"}) 'DarkGray'}
    Add-Line ('  Filter: {0}' -f $(if ($Filter) { $Filter } elseif($Harness){"all $Harness accounts"} else { 'all accounts' })) 'Cyan'
    if($Harness){Add-Line ('  {0,-24} {1,-14} {2}' -f 'ACCOUNT','PROVIDER','STATUS') 'DarkGray'}else{Add-Line ('  {0,-18} {1,-9} {2,-18} {3,-18} {4,-14} {5}' -f 'ACCOUNT','PLAN','PRIMARY','WEEKLY','STATE','NEXT RESET') 'DarkGray'}
    $lastConversationLine=Format-DeckTerminalLastConversation $LastConversation
    $pageSize = Get-DeckTerminalDashboardPageSize $Theme $Height $ShowShortcuts $Harness ([bool]$lastConversationLine)
    $start = [int]([Math]::Floor($Selected / $pageSize) * $pageSize)
    for ($i = $start; $i -lt [Math]::Min($Names.Count, $start + $pageSize); $i++) {
        $name = $Names[$i]; $row = $Cache[$name]; $profile = $Profiles[$name]
        $five = $row.Windows | Where-Object DurationSeconds -eq 18000 | Select-Object -First 1
        if (-not $five) { $five = $row.Windows | Where-Object DurationSeconds -ne 604800 | Select-Object -First 1 }
        $week = $row.Windows | Where-Object DurationSeconds -eq 604800 | Select-Object -First 1
        $state = if($profile.AuthIssue -in @('token_revoked','oauth_invalid')){'Sign in again'}else{Get-DeckTerminalHealth $row}
        if ($profile.PlanType -eq 'pool') { $state = 'Pooled session' }
        if($profile.Harness -in @('Claude','Antigravity') -and $profile.AuthStatus){$state=$profile.AuthStatus}
        elseif($profile.Harness -and $profile.Harness -ne 'Codex'){$state=$profile.Harness}
        if ($Tasks.ContainsKey($name)) { $state = 'Checking...' }
        $marker = if ($i -eq $Selected) { '>' } else { ' ' }
        $color = if ($state -in @('Ready','Signed in','Credentials stored')) { 'Green' } elseif ($state -in @('Check failed','Exhausted','Sign in again','Sign in required')) { 'Yellow' } else { 'Gray' }
        $bg = if ($i -eq $Selected) { 'DarkBlue' } else { 'Black' }
        $resetWindow = Get-DeckTerminalResetWindow $row $five
        $displayName=Get-DeckTerminalAccountLabel $name $profile.Harness
        if($Harness){Add-Line ('{0} {1,-24} {2,-14} {3}' -f $marker,(ConvertTo-DeckTerminalText $displayName 24),(ConvertTo-DeckTerminalText $profile.Provider 14),(ConvertTo-DeckTerminalText $state 24)) $color $bg}
        else{Add-Line ('{0} {1,-18} {2,-9} {3,-18} {4,-18} {5,-14} {6}' -f $marker,(ConvertTo-DeckTerminalText $name 18),(ConvertTo-DeckTerminalText $profile.PlanType 9),(Format-DeckTerminalQuota $five),(Format-DeckTerminalQuota $week),(ConvertTo-DeckTerminalText $state 14),(Format-DeckTerminalReset $resetWindow)) $color $bg}
    }
    if (-not $Names.Count) { Add-Line '  No matching accounts.' 'Yellow' }
    Add-Line ('  -- {0}-{1} of {2} --' -f ([Math]::Min($start + 1,$Names.Count)),([Math]::Min($start + $pageSize,$Names.Count)),$Names.Count) 'DarkGray'
    if ($Names.Count) {
        $name = $Names[$Selected]; $row = $Cache[$name]; $profile = $Profiles[$name]
        $email = [string]$profile.Email
        if ($Mask -and $email) { $email = $email -replace '^(.).*?(@.*)$','$1***$2' }
        Add-Line ('  {0}  |  {1}  |  {2} / {3}' -f (Get-DeckTerminalAccountLabel $name $profile.Harness),$email,$profile.Model,$profile.Effort) 'Cyan'
        $checked = 'never'
        if ($row.CheckedAt) { try { $checked = ([DateTimeOffset]$row.CheckedAt).ToLocalTime().ToString('MMM dd HH:mm:ss') } catch {} }
        $activeHealth=if($profile.AuthIssue -in @('token_revoked','oauth_invalid')){'Sign in again'}else{Get-DeckTerminalHealth $row}
        if($profile.Harness -in @('Claude','Antigravity') -and $profile.AuthStatus){$activeHealth=$profile.AuthStatus}
        if($Harness -eq 'Claude'){$authChecked=if($profile.AuthCheckedAt){try{([DateTimeOffset]$profile.AuthCheckedAt).ToLocalTime().ToString('MMM dd HH:mm:ss')}catch{'unknown'}}else{'never'};Add-Line ('  Last sign-in check: {0}  |  {1}  |  Claude /usage shows plan limits' -f $authChecked,$activeHealth) 'DarkGray';Add-Line ('  NOTICE  '+$Notice) 'Yellow';Add-Line '  Config, credentials, history, plugins, memory and skills are isolated.' 'DarkGray'}
        elseif($Harness -eq 'Antigravity'){$authChecked=if($profile.AuthCheckedAt){try{([DateTimeOffset]$profile.AuthCheckedAt).ToLocalTime().ToString('MMM dd HH:mm:ss')}catch{'unknown'}}else{'never'};$failoverStatus=if($WarmupSettings.HarnessAntigravityFailoverEnabled){'ON'}else{'OFF'};$failoverGroup=[string]$WarmupSettings.HarnessAntigravityFailoverAccounts;Add-Line ('  Last check: {0}  |  headless -p failover: {1} ({2})' -f $authChecked,$failoverStatus,$failoverGroup) 'DarkGray';Add-Line ('  NOTICE  '+$Notice) 'Yellow';Add-Line $(if($profile.AuthStatus -eq 'Runner profile'){'  Legacy runner profile: sign-in is isolated by its Windows user.'}else{'  New profiles keep their OAuth files separate under this Deck account; no extra Windows users are needed. /usage shows live limits.'}) 'DarkGray'}
        elseif($Harness){Add-Line ('  Isolated '+$Harness+' profile and native settings.') 'DarkGray';Add-Line ('  NOTICE  '+$Notice) 'Yellow'}
        else{Add-Line ('  Last checked: {0}  |  {1}  |  active here: {2}' -f $checked,$activeHealth,($env:CODEX_HOME -and (Split-Path $env:CODEX_HOME -Leaf) -eq $name)) 'DarkGray';Add-Line ('  NOTICE  '+$Notice) 'Yellow'}
        $resets = foreach ($window in $row.Windows) {
            if ($window.ResetsAtUnix) { '{0}: {1}' -f $window.Label,([DateTimeOffset]::FromUnixTimeSeconds([long]$window.ResetsAtUnix).ToLocalTime().ToString('MMM dd HH:mm')) }
        }
        if(-not $Harness){Add-Line ('  Window resets (primary = 5H or plan window): ' + ($resets -join '  /  ') + ' | Reset credits: ' + (Format-DeckResetCredits $row)) 'DarkGray'}
        $connected = @(Get-DeckIndexedSessions $sessionIndex $name)
        if ($connected.Count) { Add-Line ('  Sessions: ' + (($connected | ForEach-Object { '{0} @ {1}' -f $_.ProcessId,$_.Folder }) -join ' | ')) 'DarkGray' }
    }
    if ($WarmupSettings -and -not $Harness) {
        $warmState=if($Names.Count){if($Profiles[$Names[$Selected]].AuthIssue -in @('token_revoked','oauth_invalid')){'Sign in again'}else{Get-DeckWarmupStatus $WarmupSettings $(if($Cache[$Names[$Selected]]){$Cache[$Names[$Selected]]}else{@{Account=$Names[$Selected]}}) $WarmupHistory[$Names[$Selected]]}}else{'No account selected'}
        $warmMode=if(-not $WarmupSettings.WarmupEnabled){'PAUSED'}elseif($WarmupSettings.WarmupSchedulingEnabled){'SCHEDULED'}else{'UNSCHEDULED'}
        Add-Line ('  AUTO WARM-UP: '+$warmMode+' | '+$warmState) 'Yellow'
    }
    if(-not $Names.Count){Add-Line ('  NOTICE  '+$Notice) 'Yellow'}
    if($lastConversationLine){Add-Line ('  '+$lastConversationLine) 'DarkCyan'}
    if($CompactAdjusting -and -not $ShowShortcuts){Add-Line ('  AUTO-COMPACT {0} / FREE CONTEXT  [{1}%]   Up/Down 5%   Enter save   Esc cancel' -f $CompactMode.ToUpperInvariant(),$CompactThreshold) 'White' 'DarkBlue'}
    if($ShowShortcuts){foreach($shortcutLine in @(Get-DeckTerminalShortcutTable $Harness $Width -CompactAdjusting:$CompactAdjusting -AutoCompact:$AutoCompact -CompactThreshold $CompactThreshold -CompactMode $CompactMode -WarmupSettings $WarmupSettings)){Add-Line ('  '+$shortcutLine) $(if($shortcutLine.StartsWith('+')){'DarkCyan'}else{'Gray'})}}
    else{Add-Line '  Press Ctrl to show shortcuts' 'DarkGray'}
    return $lines.ToArray()
}
function Read-DeckTerminalInput([string]$Prompt, [int]$MaxLength = 40) {
    [Console]::Write($Prompt + ': ')
    $value = ''
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape' -or [int]$key.KeyChar -eq 27) { return '' }
        if ($key.Key -eq 'Enter' -or [int]$key.KeyChar -in @(10,13)) { [Console]::WriteLine(); return $value }
        if (($key.Key -eq 'Backspace' -or [int]$key.KeyChar -eq 8) -and $value.Length) {
            $value = $value.Substring(0,$value.Length - 1)
            [Console]::Write("`b `b")
        } elseif (-not [char]::IsControl($key.KeyChar) -and $value.Length -lt $MaxLength) {
            $value += $key.KeyChar; [Console]::Write($key.KeyChar)
        }
    }
}
function Test-DeckTerminalKeyHold([int]$VirtualKey, [int]$HoldMilliseconds = 450) {
    try {
        Initialize-DeckTerminalKeyboard
        $until=[DateTimeOffset]::UtcNow.AddMilliseconds($HoldMilliseconds)
        while([DateTimeOffset]::UtcNow -lt $until){
            if(([CodexDeckNativeKeyboard]::GetAsyncKeyState($VirtualKey) -band 0x8000) -eq 0){return $false}
            Start-Sleep -Milliseconds 20
        }
        return $true
    }catch{return $false}
}
function Add-DeckTerminalCheckQueue([string[]]$Names,$Profiles,$Tasks,[Collections.Generic.Queue[string]]$Pending,[string]$AccountRoot) {
    $queued=0
    foreach($item in $Names){
        if($Profiles[$item].Harness -and $Profiles[$item].Harness -ne 'Codex'){continue}
        if($Profiles[$item].PlanType -eq 'pool' -or -not (Test-Path -LiteralPath (Join-Path $AccountRoot "$item/auth.json"))){continue}
        if($Profiles[$item].AuthIssue){continue}
        if(-not $Tasks.ContainsKey($item) -and -not $Pending.Contains($item)){$Pending.Enqueue($item);$queued++}
    }
    return $queued
}

function Invoke-DeckClaudeTerminalAuthChecks([string]$SuiteRoot,[string[]]$Names,$Profiles) {
    $signedIn=0;$needsSignIn=0;$failed=0
    foreach($name in $Names){
        try{
            $result=Get-DeckClaudeAuthStatus $SuiteRoot $name
            $Profiles[$name]=Get-DeckProfile $SuiteRoot $name
            if($result.LoggedIn){$signedIn++}else{$needsSignIn++}
        }catch{
            $failed++
            try{
                $cachePath=Join-Path $SuiteRoot 'deck/claude-auth-checks.json'
                $cache=Read-DeckEnvironmentJson $cachePath
                if(-not (Test-DeckClaudeJsonObject $cache)){$cache=[pscustomobject]@{}}
                $cache | Add-Member NoteProperty $name ([pscustomobject]@{LoggedIn=$false;AuthMethod=$null;CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');Error='Authentication status check failed.'}) -Force
                Write-DeckEnvironmentJson $cachePath $cache
                $Profiles[$name]=Get-DeckProfile $SuiteRoot $name
            }catch{}
        }
    }
    return [pscustomobject]@{SignedIn=$signedIn;NeedsSignIn=$needsSignIn;Failed=$failed;Total=$Names.Count}
}

function Invoke-DeckAntigravityTerminalAuthChecks([string]$SuiteRoot,[string[]]$Names,$Profiles) {
    $credentials=0;$needsSignIn=0;$runner=0;$failed=0
    foreach($name in $Names){
        try{
            $result=Get-DeckAntigravityAuthStatus $SuiteRoot $name
            $Profiles[$name]=Get-DeckProfile $SuiteRoot $name
            if($result.Mode -eq 'Windows runner'){$runner++}
            elseif($result.CredentialsPresent){$credentials++}else{$needsSignIn++}
        }catch{
            $failed++
            try{
                $cachePath=Join-Path $SuiteRoot 'deck/antigravity-auth-checks.json'
                $cache=Read-DeckEnvironmentJson $cachePath
                if(-not (Test-DeckAntigravityJsonObject $cache)){$cache=[pscustomobject]@{}}
                $cache | Add-Member NoteProperty $name ([pscustomobject]@{CredentialsPresent=$false;Mode='Isolated file profile';Status='Check failed';CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');Error='Authentication profile check failed.'}) -Force
                Write-DeckEnvironmentJson $cachePath $cache
                $Profiles[$name]=Get-DeckProfile $SuiteRoot $name
            }catch{}
        }
    }
    return [pscustomobject]@{Credentials=$credentials;NeedsSignIn=$needsSignIn;Runner=$runner;Failed=$failed;Total=$Names.Count}
}

function Show-DeckTerminal {
    param([string]$SuiteRoot, [string]$AuthScript, [switch]$Snapshot, [switch]$CheckAll, [string]$Harness)
    . (Join-Path $SuiteRoot 'Deck.Core.ps1')
    $root = Join-Path $SuiteRoot 'deck'
    $accountRoot = Join-Path $SuiteRoot 'accounts'
    $warmSettings=Get-DeckSettings $root
    $terminalCacheStamp=Get-DeckTerminalCacheStamp $root
    $cache = Get-DeckTerminalCache $root
    $profiles = @{}; $tasks = @{}; $pending = [Collections.Generic.Queue[string]]::new()
    $names=@(); $sessions=@(); $sessionIndex=@{}; $sessionRead=$null; $lastSessionRead=[DateTimeOffset]::MinValue; $warmHistory=@{}; $stateRefreshAt=[DateTimeOffset]::MinValue; $authIssuesStamp=''
    $selected = 0; $filter = ''; $notice = if($Harness -eq 'Claude'){"Claude profiles. Sign-in checks are available; use /usage inside Claude Code for plan limits."}elseif($Harness -eq 'Antigravity'){'Antigravity profiles. N creates isolated file profiles; R/A check saved credentials; /usage shows live status and limits.'}elseif($Harness){"$Harness profiles. Sign-in is available."}else{'Ready. Cached usage is shown; fresh checks are available.'}; $mask = $true; $autoCompact = [bool]$warmSettings.AutoCompactLaunchEnabled; $showShortcuts=$false; $controlWasDown=$false
    $dashboardState=@{LastConversation=$null}
    $queueAll=$CheckAll.IsPresent
    $compactAdjusting=$false; $compactDraft=[int]$warmSettings.AutoCompactThresholdPercent
    $interactive = -not $Snapshot -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    if (-not $interactive) { $notice = if($Harness){"Cached $Harness profile snapshot."}else{'Cached snapshot. Run codex-auth in a terminal for live checks and actions.'} }
    elseif(-not $Harness -and $warmSettings.WarmupEnabled -and $warmSettings.WarmupSchedulingEnabled){
        try{if(Repair-DeckWarmupSchedule $SuiteRoot $warmSettings){$notice='Repaired the missing automatic warm-up schedule.'}}catch{$notice='Warm-up schedule repair failed: '+$_.Exception.Message}
    }
    $oldColor = [Console]::ForegroundColor; $oldBackground = [Console]::BackgroundColor
    $oldCursor = $true
    if ($interactive) { Initialize-DeckTerminalKeyboard; $controlWasDown=Get-DeckTerminalControlKeyDown; $oldCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
    try {
        do {
            $loopNow=[DateTimeOffset]::UtcNow
            $terminalCacheDirty=$false
            if($sessionRead -and $sessionRead.Handle.IsCompleted){
                try{$sessions=@(Complete-DeckSessionRead $sessionRead);$sessionIndex=New-DeckSessionIndex $sessions;$lastFrame=''}catch{}
                $sessionRead=$null
            }
            if($interactive -and -not $sessionRead -and ($loopNow-$lastSessionRead).TotalSeconds -ge 5){
                try{$sessionRead=Start-DeckSessionRead $root}catch{}
                $lastSessionRead=$loopNow
            }
            if($loopNow -ge $stateRefreshAt){
                $warmSettings=Get-DeckSettings $root
                $autoCompact=[bool]$warmSettings.AutoCompactLaunchEnabled
                $warmHistory=@{}; foreach($entry in @(Expand-DeckCheckRecords (Read-DeckJson (Join-Path $root 'warmup.json')))){if($entry.Account){$warmHistory[$entry.Account]=$entry}}
                # Refresh disk-backed state at a human-scale cadence; worker
                # completion remains responsive without reparsing it twice a second.
                $freshTerminalCacheStamp=Get-DeckTerminalCacheStamp $root
                if($freshTerminalCacheStamp -ne $terminalCacheStamp){
                    foreach($entry in (Get-DeckTerminalCache $root).Values){if(-not $cache[$entry.Account] -or (Get-DeckUsageCheckTicks $entry) -gt (Get-DeckUsageCheckTicks $cache[$entry.Account])){$cache[$entry.Account]=$entry}}
                    $terminalCacheStamp=$freshTerminalCacheStamp
                }
                $names = if (Get-Command Get-DeckEntryNames -ErrorAction SilentlyContinue) { @(Get-DeckEntryNames $SuiteRoot) } else { @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object Name) }
                if($Harness){$names=@($names | Where-Object {(Get-DeckAccountIdentity $SuiteRoot $_).Harness -eq $Harness})}
                foreach ($name in $names) {if (-not $profiles.ContainsKey($name)) { $profiles[$name] = Get-DeckProfile $SuiteRoot $name }}
                $freshAuthIssuesStamp=Get-DeckAuthIssuesStamp $SuiteRoot
                if($freshAuthIssuesStamp -ne $authIssuesStamp){
                    foreach($name in $names){$profiles[$name]=Get-DeckProfile $SuiteRoot $name;if(Clear-DeckStaleRevokedAuth $SuiteRoot $name $cache[$name]){$terminalCacheDirty=$true}}
                    $authIssuesStamp=$freshAuthIssuesStamp
                }
                foreach($name in $names){
                    if($profiles[$name].AuthIssue -and -not (Get-DeckAuthIssue $SuiteRoot $name)){
                        $profiles[$name]=Get-DeckProfile $SuiteRoot $name
                        if(Clear-DeckStaleRevokedAuth $SuiteRoot $name $cache[$name]){$terminalCacheDirty=$true}
                        if(-not $profiles[$name].AuthIssue -and $profiles[$name].PlanType -ne 'pool' -and (Test-DeckCodexAccount $SuiteRoot $name) -and (Test-Path -LiteralPath (Join-Path $accountRoot "$name/auth.json")) -and -not $tasks.ContainsKey($name) -and -not $pending.Contains($name)){$pending.Enqueue($name)}
                    }
                }
                if(-not $interactive){$sessions=@(Get-DeckSessions $root);$sessionIndex=New-DeckSessionIndex $sessions}
                $stateRefreshAt=$loopNow.AddSeconds(2)
            }
            if($queueAll -and ($interactive -or $Harness -in @('Claude','Antigravity'))){
                if($Harness -eq 'Claude'){
                    $summary=Invoke-DeckClaudeTerminalAuthChecks $SuiteRoot $names $profiles
                    $notice='Checked '+$summary.Total+' Claude profiles: '+$summary.SignedIn+' signed in, '+$summary.NeedsSignIn+' need sign-in, '+$summary.Failed+' checks failed. Usage limits remain in Claude /usage.'
                }elseif($Harness -eq 'Antigravity'){
                    $summary=Invoke-DeckAntigravityTerminalAuthChecks $SuiteRoot $names $profiles
                    $notice='Checked '+$summary.Total+' Antigravity profiles: '+$summary.Credentials+' credential files present, '+$summary.NeedsSignIn+' need sign-in, '+$summary.Runner+' use Windows runners, '+$summary.Failed+' checks failed. /usage verifies service status and limits.'
                }elseif(-not $Harness){
                    $queued=Add-DeckTerminalCheckQueue $names $profiles $tasks $pending $accountRoot
                    $notice=if($queued){"Queued $queued signed-in accounts (three checks at a time)."}else{'No additional signed-in accounts to queue.'}
                }else{$notice="$Harness does not have a Deck status checker."}
                $queueAll=$false
            }
            foreach ($name in @($tasks.Keys)) {
                $task = $tasks[$name]
                $timeout=($loopNow-$task.Started).TotalSeconds -ge 90
                if(-not $timeout -and -not (Test-DeckTaskReady $task)){continue}
                try {
                    if($timeout){Stop-DeckTask $task; throw 'Usage check timed out.'}
                    if ($task.Process.ExitCode -ne 0) { throw (Get-DeckTaskFailureMessage $task) }
                    $result = @(Expand-DeckTerminalRecords ($task.Out.Result | ConvertFrom-Json) | Where-Object Account -eq $name)
                    if ($result.Count -ne 1) { throw 'Usage check returned no matching account.' }
                    if($result[0].Status -eq 'error'){throw ([string]$result[0].Error)}
                    $result[0] | Add-Member NoteProperty CheckedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
                    $cache[$name] = $result[0]
                    $terminalCacheDirty=$true
                    $notice = "$name refreshed."
                } catch {
                    $failureMessage=[string]$_.Exception.Message
                    $revoked=Test-DeckInvalidAuthMessage $failureMessage
                    if($revoked){
                        [void](Set-DeckAuthIssue $SuiteRoot $name $failureMessage)
                        $profiles[$name]=Get-DeckProfile $SuiteRoot $name
                    $notice="$name needs sign-in. Use its sign-in action to continue."
                    }else{$notice = "$name : $failureMessage"}
                    if (-not $cache[$name]) { $cache[$name] = [pscustomobject]@{Account=$name;Status='error';Windows=@()} }
                    $cache[$name] | Add-Member NoteProperty Error $(if($revoked){'OAuth token expired or invalid; sign in again.'}else{'Last refresh failed; displayed usage is cached.'}) -Force
                    if($revoked){$cache[$name] | Add-Member NoteProperty AuthFileStamp (Get-DeckAuthFileStamp $SuiteRoot $name) -Force}
                }
                finally { Stop-DeckTask $task; Dispose-DeckTask $task; [void]$tasks.Remove($name) }
            }
            if($terminalCacheDirty){$cache=Save-DeckUsageCache $root $cache 'terminal-cache.json';$terminalCacheStamp=Get-DeckTerminalCacheStamp $root}
            while ($interactive -and $pending.Count -and $tasks.Count -lt 3) {
                $name = $pending.Dequeue()
                if ($tasks.ContainsKey($name) -or $name -notin $names -or $profiles[$name].PlanType -eq 'pool') { continue }
                try { $tasks[$name] = Start-DeckTask (Get-DeckCheckCode $SuiteRoot $name) 'check' $name }
                catch { $notice = "Could not start check for $name." }
            }
            $visible = @($names | Where-Object { -not $filter -or $_.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $selected = [Math]::Max(0,[Math]::Min($selected,$visible.Count - 1))
            $width = 110; $height = [Math]::Max(25,$visible.Count + 18)
            if ($interactive) { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight }
            $compactThreshold=if($compactAdjusting){$compactDraft}else{[int]$warmSettings.AutoCompactThresholdPercent}
            $frame = @(Get-DeckTerminalFrame $visible $cache $profiles $sessions $tasks $selected $width $height $filter $notice $mask $warmSettings $warmHistory $autoCompact $compactThreshold $compactAdjusting $warmSettings.AutoCompactMode $warmSettings.DashboardTheme $dashboardState.LastConversation $sessionIndex $Harness $showShortcuts)
            $pageStep=Get-DeckTerminalDashboardPageSize $warmSettings.DashboardTheme $height $showShortcuts $Harness ([bool](Format-DeckTerminalLastConversation $dashboardState.LastConversation))
            if (-not $interactive) { $frame | ForEach-Object { Write-Output $_.Text }; return }
            $signature = "$width/$height/" + (($frame | ForEach-Object { $_.Text + $_.Color + $_.Background }) -join "`n")
            if ($signature -ne $lastFrame) {
            [Console]::SetCursorPosition(0,0)
            for ($line = 0; $line -lt $height - 1; $line++) {
                $text = ''; [Console]::ForegroundColor = 'Gray'; [Console]::BackgroundColor = 'Black'
                if ($line -lt $frame.Count) { $text = $frame[$line].Text; [Console]::ForegroundColor = $frame[$line].Color; [Console]::BackgroundColor = $frame[$line].Background }
                [Console]::Write($text.PadRight([Math]::Max(1,$width - 1)))
                if ($line -lt $height - 2) { [Console]::WriteLine() }
            }
            [Console]::ResetColor()
            $lastFrame = $signature
            }
            $until = [DateTimeOffset]::UtcNow.AddMilliseconds(500)
            while ([DateTimeOffset]::UtcNow -lt $until) {
                $controlDown=Get-DeckTerminalControlKeyDown
                if($controlDown -and -not $controlWasDown){$showShortcuts=-not $showShortcuts;$lastFrame=''}
                $controlWasDown=$controlDown
                if([Console]::KeyAvailable){break}
                Start-Sleep -Milliseconds 20
            }
            if (-not [Console]::KeyAvailable) { continue }
            $key = [Console]::ReadKey($true)
            $name = if ($visible.Count) { $visible[$selected] } else { $null }
            $action = $key.Key.ToString()
            if (-not [char]::IsControl($key.KeyChar)) { $action = ([string]$key.KeyChar).ToUpperInvariant() }
            elseif ([int]$key.KeyChar -in @(10,13)) { $action = 'Enter' }
            elseif ([int]$key.KeyChar -eq 27) { $action = 'Escape' }
            if($compactAdjusting){
                switch($action){
                    'UpArrow' {$compactDraft=[Math]::Min(90,$compactDraft+5)}
                    'DownArrow' {$compactDraft=[Math]::Max(30,$compactDraft-5)}
                    'Enter' {
                        $warmSettings.AutoCompactThresholdPercent=$compactDraft
                        Write-DeckJson (Join-Path $root 'settings.json') $warmSettings
                        $warmSettings=Get-DeckSettings $root
                        $compactAdjusting=$false
                        $notice="Auto-compact saved at $compactDraft% context remaining."
                    }
                    'Escape' {$compactAdjusting=$false; $notice='Auto-compact threshold unchanged.'}
                    'C' {}
                }
                continue
            }
            switch ($action) {
                'Q' { return }
                'F' {
                    if($Harness -ne 'Antigravity'){$notice='Headless failover is an Antigravity-only setting.';continue}
                    try{
                        $warmSettings=Get-DeckSettings $root
                        $warmSettings.HarnessAntigravityFailoverEnabled=-not [bool]$warmSettings.HarnessAntigravityFailoverEnabled
                        Write-DeckJson (Join-Path $root 'settings.json') $warmSettings
                        $lastFrame=''
                        $notice=if($warmSettings.HarnessAntigravityFailoverEnabled){'AGY ordered headless failover is on for quota/provider errors before tools run.'}else{'AGY headless failover is off; prompts stay on the selected profile.'}
                    }catch{$notice='Could not update AGY failover: '+$_.Exception.Message}
                    continue
                }
                'Delete' {
                    if(-not $name){$notice='Select an account to delete.';continue}
                    [Console]::CursorVisible=$true; Clear-Host
                    try{
                        if($tasks.ContainsKey($name) -or $pending.Contains($name)){throw 'Wait for this account''s check to finish before deleting it.'}
                        $confirmation=Read-DeckTerminalInput ("Move $name to local recovery storage? Y/N") 3
                        if($confirmation -match '^(?i:y|yes)$'){
                            Move-DeckAccountToRecovery $SuiteRoot $name
                            [void]$profiles.Remove($name);[void]$cache.Remove($name)
                            $notice='Deleted '+$name+' / saved in local recovery storage.'
                            $stateRefreshAt=[DateTimeOffset]::MinValue
                            $lastSessionRead=[DateTimeOffset]::MinValue
                        }else{$notice='Account deletion cancelled.'}
                    }catch{$notice=$_.Exception.Message}
                    finally{[Console]::CursorVisible=$false;Clear-Host;$lastFrame=''}
                }
                'Escape' { if ($filter) { $filter = ''; $selected = 0 } else { return } }
                'UpArrow' { $selected = [Math]::Max(0,$selected - 1) }
                'DownArrow' { $selected = [Math]::Min($visible.Count - 1,$selected + 1) }
                'Home' { $selected = 0 }
                'End' { $selected = [Math]::Max(0,$visible.Count - 1) }
                'PageUp' { $selected = [Math]::Max(0,$selected - $pageStep) }
                'PageDown' { $selected = [Math]::Min($visible.Count - 1,$selected + $pageStep) }
                'B' {
                    if($Harness){$notice='Best-account recommendations are available for Codex usage checks.';continue}
                    $choice = @(Get-DeckRecommendations $names $cache) | Select-Object -First 1
                    if ($choice) { $filter=''; $selected=[array]::IndexOf($names,$choice.Account); $notice=$choice.Account+': '+$choice.Reason }
                    else { $notice='No fresh usable account. Refresh a signed-in account; unknown and exhausted accounts are excluded.' }
                }
                'H' {
                    if($Harness){$notice='Claude sessions are managed by Claude Code.';continue}
                    [Console]::CursorVisible=$true
                    try { Show-DeckHistoryBrowser $SuiteRoot $AuthScript -DashboardState $dashboardState } catch { $notice=$_.Exception.Message }
                    finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                }
                'F2' {
                    if ($name) {
                        [Console]::CursorVisible=$true; Clear-Host
                        try {
                            if ($tasks.Count -or $pending.Count) { throw 'Wait for queued checks to finish before renaming.' }
                            $newName=Read-DeckTerminalInput ('Rename '+$name+' to (empty cancels)')
                            if ($newName) {
                                if($Harness){$newName=Resolve-DeckHarnessScopedAccountName $SuiteRoot $newName $Harness}
                                $notice=Rename-DeckAccount $SuiteRoot $name $newName
                                [void]$profiles.Remove($name); $cache=Get-DeckTerminalCache $root; $terminalCacheStamp=Get-DeckTerminalCacheStamp $root; $stateRefreshAt=[DateTimeOffset]::MinValue
                            }
                        } catch { $notice=$_.Exception.Message }
                        finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                    }
                }
                'M' { $mask = -not $mask }
                'C' {
                    if($Harness){$notice='Auto-compact controls apply to Codex sessions.';continue}
                    if(Test-DeckTerminalKeyHold 0x43){
                        $compactDraft=[int]$warmSettings.AutoCompactThresholdPercent
                        $compactAdjusting=$true
                        $notice='Adjust the free-context threshold in 5% steps, then press Enter to save.'
                    }else{
                        $warmSettings=Set-DeckAutoCompactLaunch $root (-not $autoCompact)
                        $autoCompact = [bool]$warmSettings.AutoCompactLaunchEnabled
                        $notice = if($autoCompact){'Auto-compact enabled for future account and pool launches ('+$warmSettings.AutoCompactMode+').'}else{'Deck auto-compact disabled for future launches and shared-setting Custom sessions; Codex may still compact natively.'}
                    }
                }
                'R' {
                    if($Harness -eq 'Claude'){
                        if(-not $name){$notice='Select a Claude account first.'}
                        else{try{$check=Get-DeckClaudeAuthStatus $SuiteRoot $name;$profiles[$name]=Get-DeckProfile $SuiteRoot $name;$notice=if($check.LoggedIn){$name+' is signed in ('+$check.AuthMethod+').'}else{$name+' needs Claude sign-in. Use its login action.'}}catch{$notice=$_.Exception.Message}}
                        continue
                    }
                    if($Harness -eq 'Antigravity'){
                        if(-not $name){$notice='Select an Antigravity account first.'}
                        else{try{$check=Get-DeckAntigravityAuthStatus $SuiteRoot $name;$profiles[$name]=Get-DeckProfile $SuiteRoot $name;$notice=if($check.Mode -eq 'Windows runner'){$name+' uses the legacy Windows runner; open it to check sign-in.'}elseif($check.CredentialsPresent){$name+' has a saved isolated credential file. Use /usage to refresh service status and limits.'}else{$name+' needs sign-in. Use its login action.'}}catch{$notice=$_.Exception.Message}}
                        continue
                    }
                    if($Harness){$notice=('{0}: use L to open the native sign-in flow.' -f $name);continue}
                    if($name -and $profiles[$name].AuthIssue){$notice="$name needs sign-in. Use its sign-in action to continue."}
                    elseif($name -and (Test-DeckCodexAccount $SuiteRoot $name) -and $profiles[$name].PlanType -ne 'pool' -and (Test-Path -LiteralPath (Join-Path $accountRoot "$name/auth.json")) -and -not $tasks.ContainsKey($name) -and -not $pending.Contains($name)){$pending.Enqueue($name); $notice="Queued $name."}
                    elseif($name){$notice="$name is not signed in or cannot be checked."}
                }
                'A' {
                    if($Harness -eq 'Claude'){$summary=Invoke-DeckClaudeTerminalAuthChecks $SuiteRoot $names $profiles;$notice='Checked '+$summary.Total+' Claude profiles: '+$summary.SignedIn+' signed in, '+$summary.NeedsSignIn+' need sign-in, '+$summary.Failed+' checks failed. Use Claude /usage for limits.';continue}
                    if($Harness -eq 'Antigravity'){$summary=Invoke-DeckAntigravityTerminalAuthChecks $SuiteRoot $names $profiles;$notice='Checked '+$summary.Total+' Antigravity profiles: '+$summary.Credentials+' credential files present, '+$summary.NeedsSignIn+' need sign-in, '+$summary.Runner+' use Windows runners, '+$summary.Failed+' checks failed. Use /usage for limits.';continue}
                    if($Harness){$notice='Deck checks are currently available for Claude sign-in and Codex usage.';continue}
                    $queued=Add-DeckTerminalCheckQueue $names $profiles $tasks $pending $accountRoot
                    $notice=if($queued){"Queued $queued signed-in accounts (three checks at a time)."}else{'No additional signed-in accounts to queue.'}
                }
                'J' {
                    if($Harness){$notice='Automatic sign-in helper is available for Codex accounts.';continue}
                    if(-not $name){$notice='Select an account first.'}
                    else {
                        try {
                            $email=[string]$profiles[$name].Email
                            if(-not $email){throw 'The selected account has no email to match.'}
                            if(-not (Test-DeckAuthHelperEmail $SuiteRoot $email)){throw 'No matching helper credential is saved for this account email.'}
                            if(Start-DeckAuthHelperRecoveryWorker $SuiteRoot $name $email -Force){$notice="$name automatic sign-in started in the background."}else{$notice="$name automatic sign-in could not be started."}
                        } catch {$notice=$_.Exception.Message}
                    }
                }
                'U' {
                    if($Harness){$notice='Warm-up is available for Codex accounts.';continue}
                    try { Request-DeckWarmup $SuiteRoot $name; $notice='Warm-up queued in background for '+$name+'. Success requires an assistant reply.' } catch { $notice=$_.Exception.Message }
                }
                'T' {
                    if($Harness){$notice='Warm-up scheduling is available for Codex accounts.';continue}
                    [Console]::CursorVisible=$true; Clear-Host
                    try {
                        Write-Host ('Daily warm-up (local time): '+$warmSettings.WarmupTimes)
                        $times=Read-DeckTerminalInput 'Times HH:mm separated by commas; off disables; empty cancels'
                        if($times){
                            if($times -eq 'off'){$times=''}
                            $warmSettings=Set-DeckWarmupTimes $SuiteRoot $times
                            $notice='Daily warm-up: '+$(if($warmSettings.WarmupTimedEnabled){$warmSettings.WarmupTimes+' (local)'}else{'off'})+$(if($warmSettings.WarmupTimedEnabled -and -not $warmSettings.WarmupSchedulingEnabled){'; background scheduling is off in desktop Settings'}else{''})
                        }
                    } catch { $notice=$_.Exception.Message }
                    finally { [Console]::CursorVisible=$false; Clear-Host; $lastFrame='' }
                }
                'W' {
                    if($Harness){$notice='Warm-up selection is available for Codex accounts.';continue}
                    try{$warmSettings=Set-DeckWarmupControl $root $name; if($warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}; $notice=if($warmSettings.WarmupSchedulingEnabled){'Warm-up selection saved. Background scheduling is enabled.'}else{'Warm-up selection saved. Enable background scheduling in desktop Settings for automatic runs.'}}catch{$notice=$_.Exception.Message}
                }
                'P' {
                    if($Harness){$notice='Warm-up is available for Codex accounts.';continue}
                    try{$warmSettings=Set-DeckWarmupControl $root -Pause; if($warmSettings.WarmupEnabled){Start-DeckWarmupScheduler $SuiteRoot}; $notice='Warm-up '+$(if(-not $warmSettings.WarmupEnabled){'paused; in-flight requests may finish.'}elseif($warmSettings.WarmupSchedulingEnabled){'resumed with background scheduling.'}else{'resumed; background scheduling is off in desktop Settings.'})}catch{$notice=$_.Exception.Message}
                }
                'G' { if($Harness -eq 'Claude'){Open-DeckClaudeDefaults $SuiteRoot;$notice='Claude Global Defaults editor opened.'}elseif($Harness -eq 'Antigravity'){Open-DeckAntigravityDefaults $SuiteRoot;$notice='Antigravity Global Defaults editor opened.'}else{Open-DeckGlobalRules $SuiteRoot;$notice='Codex Global Rules editor opened.'} }
                'V' { if($Harness){$notice='Auth Helper is available for Codex accounts.'}else{try{Open-DeckAuthHelper $SuiteRoot;$notice='Auth Helper editor opened.'}catch{$notice=$_.Exception.Message}} }
                'I' { if($name){Open-DeckAccountInstructions $SuiteRoot $name;$notice="$name account instructions opened."} }
                'E' { if($name){if($Harness -eq 'Claude'){Open-DeckAccountMemoryFolder $SuiteRoot $name;$notice="$name Claude auto-memory folder opened."}elseif($Harness -eq 'Antigravity'){Open-DeckAccountMemoryFolder $SuiteRoot $name;$notice="$name Antigravity learned rules opened."}else{Open-DeckAccountMemoryFolder $SuiteRoot $name;$notice="$name memories editor opened."}} }
                'K' { if($name){Open-DeckSkillsFolder $SuiteRoot $name;$notice="$name skills folder opened."} }
                'Y' { try{[void](Open-DeckInspector $SuiteRoot 'Efficiency');$notice='Analytics opened.'}catch{$notice=$_.Exception.Message} }
                'S' { Start-DeckCompanion $SuiteRoot -OpenSettings; $notice='Desktop Settings opened.' }
                'D' { Start-DeckCompanion $SuiteRoot; $notice = 'Desktop Deck opened; use its settings for scheduling and warm-up.' }
                default {
                    if ($key.KeyChar -eq '/') {
                        [Console]::CursorVisible = $true; Clear-Host
                        $filter = Read-DeckTerminalInput 'Find account (empty = all)'; $selected = 0
                        [Console]::CursorVisible = $false; Clear-Host; $lastFrame = ''
                    } elseif ($action -in @('Enter','L','N')) {
                        [Console]::CursorVisible = $true; Clear-Host
                        try {
                            $enterNeedsLogin=$action -eq 'Enter' -and $name -and ([bool]$profiles[$name].AuthIssue -or (Test-DeckInvalidAuthMessage ([string]$cache[$name].Error)))
                            $automaticLoginActive=$false
                            if($enterNeedsLogin){
                                $helperStatus=Read-DeckJson (Join-Path $SuiteRoot "deck/auth-helper/status/$name.json")
                                if($helperStatus -and $helperStatus.State -eq 'running'){
                                    try{$automaticLoginActive=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$helperStatus.At)).TotalMinutes -lt 7}catch{}
                                }
                            }
                            $helperAutoLoginAvailable=$false
                            if($enterNeedsLogin -and $name){$helperAutoLoginAvailable=Test-DeckAuthHelperEmail $SuiteRoot ([string]$profiles[$name].Email)}
                            if($automaticLoginActive){$notice="$name automatic sign-in is already running. Wait for it to finish before continuing."}
                            elseif($enterNeedsLogin -and $helperAutoLoginAvailable){
                                [void](Start-DeckAuthHelperRecoveryWorker $SuiteRoot $name ([string]$profiles[$name].Email) -Force)
                                $notice="$name automatic sign-in started in the background. The dashboard will queue a fresh check when it completes."
                            }
                            else {
                            if ($action -eq 'N') {
                                $chosenHarness=if($Harness){$Harness}else{'Codex'}
                                $chosenProvider=(Get-DeckHarness $chosenHarness).Providers[0]
                                $name = Read-DeckTerminalInput 'New account name or number (empty cancels)'
                                if ($name -match '^\d+$') { $name = "account$name" }
                                if ($name -and ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$')) { throw 'Invalid account name.' }
                                if($name -and $Harness){$name=Resolve-DeckHarnessScopedAccountName $SuiteRoot $name $Harness}
                                if ($name -and (Test-Path -LiteralPath (Join-Path $accountRoot $name))) { throw 'That account already exists.' }
                            }
                            if ($name) {
                                if($action -eq 'N'){
                                    if(-not $Harness){
                                        $enabledHarnesses=@(Get-DeckHarnessCatalog | Where-Object {Test-DeckHarnessEnabled $warmSettings $_.Id})
                                        Write-Host ('Enabled harnesses: '+($enabledHarnesses.Id -join ', '))
                                        $choice=Read-DeckTerminalInput 'Harness (empty = Codex)'
                                        if($choice){$chosenHarness=(Get-DeckHarness $choice).Id}
                                    }
                                    if(-not (Test-DeckHarnessEnabled $warmSettings $chosenHarness)){throw 'Enable this harness in desktop Settings first.'}
                                    $providerChoices=(Get-DeckHarness $chosenHarness).Providers
                                    $chosenProvider=$providerChoices[0]
                                    if($providerChoices.Count -gt 1){Write-Host ('Login providers: '+($providerChoices -join ', '));$choice=Read-DeckTerminalInput ('Provider (empty = '+$chosenProvider+')');if($choice){$chosenProvider=$choice}}
                                }
                                [void][IO.Directory]::CreateDirectory($accountRoot)
                                $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$AuthScript,$name)
                                if ($action -eq 'Enter' -and -not $enterNeedsLogin -and $autoCompact -and (Test-DeckCodexAccount $SuiteRoot $name)) { $arguments += @('-AutoCompact',(([int]$warmSettings.AutoCompactThresholdPercent).ToString()+'%')) }
                                if($action -eq 'N'){$arguments+=@('-NewAccount','-Harness',$chosenHarness,'-Provider',$chosenProvider)}
                                $loginRequested=$action -in @('L','N') -or $enterNeedsLogin
                                if ($loginRequested) { $arguments += 'login' }
                                $loginWasAuthIssue=$loginRequested -and ([bool]$profiles[$name].AuthIssue -or $enterNeedsLogin)
                                $loginOAuthAccountId=if($loginWasAuthIssue){Get-DeckOAuthAccountId $SuiteRoot $name}else{$null}
                                $launchedAt=[DateTimeOffset]::UtcNow
                                if($action -eq 'Enter' -and -not $enterNeedsLogin){$dashboardState.LastConversation=$null}
                                & powershell.exe @arguments
                                $notice = "$name returned (exit $LASTEXITCODE)."
                                if($loginWasAuthIssue -and $LASTEXITCODE -eq 0){
                                    $profiles[$name]=Get-DeckProfile $SuiteRoot $name
                                    if(-not $profiles[$name].AuthIssue){
                                        $reauthOAuthAccountId=Get-DeckOAuthAccountId $SuiteRoot $name
                                        if($loginOAuthAccountId -and $loginOAuthAccountId -eq $reauthOAuthAccountId){
                                            if($cache[$name] -and (Test-DeckInvalidAuthMessage ([string]$cache[$name].Error))){
                                                $cache[$name].PSObject.Properties.Remove('Error'); $cache[$name].PSObject.Properties.Remove('AuthFileStamp')
                                            }
                                            if(-not $pending.Contains($name)){$pending.Enqueue($name)}
                                            $notice="$name signed in. A fresh usage check is queued."
                                            if($dashboardState.LastConversation -and $dashboardState.LastConversation.Account -eq $name){
                                                $resumeChoice=Read-DeckTerminalInput 'Resume the last conversation now? Y/N' 3
                                                if($resumeChoice -match '^(?i:y|yes)$'){
                                                    $resumeAt=[DateTimeOffset]::UtcNow
                                                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AuthScript 'resume' $dashboardState.LastConversation.Id
                                                    $notice="$name conversation returned (exit $LASTEXITCODE)."
                                                    $recent=Get-DeckTerminalRecentConversation $SuiteRoot $name $resumeAt
                                                    if($recent){$dashboardState.LastConversation=$recent}
                                                }
                                            }
                                        }else{$notice="$name sign-in completed for a different or unverified account. Check its email before resuming."}
                        }else{$notice="$name still needs sign-in. Complete Codex login, then continue from the dashboard."}
                                }
                                if($action -eq 'Enter' -and -not $enterNeedsLogin){
                                    $recent=Get-DeckTerminalRecentConversation $SuiteRoot $name $launchedAt
                                    if($recent){$dashboardState.LastConversation=$recent; $notice="$name returned (exit $LASTEXITCODE). Last conversation is ready to resume below."}
                                }
                                [void]$profiles.Remove($name); $stateRefreshAt=[DateTimeOffset]::MinValue; $lastSessionRead=[DateTimeOffset]::MinValue
                            }
                            }
                        } catch { $notice = $_.Exception.Message }
                        finally { [Console]::CursorVisible = $false; Clear-Host; $lastFrame = '' }
                    }
                }
            }
        } while ($true)
    } finally {
        foreach ($task in $tasks.Values) { Stop-DeckTask $task; Dispose-DeckTask $task }
        if($sessionRead){try{$sessionRead.Reader.Stop()}catch{};try{$sessionRead.Reader.Dispose()}catch{}}
        if ($interactive) { [Console]::ForegroundColor = $oldColor; [Console]::BackgroundColor = $oldBackground; [Console]::CursorVisible = $oldCursor; Clear-Host }
    }
}

function Show-DeckPoolPicker([string]$SuiteRoot, [string]$Environment, [string[]]$Members) {
    $selected=0; $notice='Enter selects the starting account. R refreshes it; B selects best fresh quota; Q cancels.'
    $profiles=@{}; foreach ($name in $Members) { $profiles[$name]=Get-DeckProfile $SuiteRoot $name }
    while ($true) {
        $cache=Get-DeckTerminalCache (Join-Path $SuiteRoot 'deck')
        Clear-Host
        Write-Host ("POOL: $Environment | one environment, selectable account usage") -ForegroundColor Cyan
        $frame=Get-DeckTerminalFrame $Members $cache $profiles @() @{} $selected ([Console]::WindowWidth) ([Math]::Max(24,[Console]::WindowHeight-3)) '' $notice -ShowShortcuts:$false
        $frame | Select-Object -SkipLast 2 | ForEach-Object { Write-Host $_.Text -ForegroundColor $_.Color }
        Write-Host 'Up/Down select | Enter use account | R refresh | B best available | Q back'
        $key=[Console]::ReadKey($true)
        switch ($key.Key.ToString()) {
            'Escape' { return $null }
            'Q' { return $null }
            'UpArrow' { $selected=[Math]::Max(0,$selected-1) }
            'DownArrow' { $selected=[Math]::Min($Members.Count-1,$selected+1) }
            'Home' { $selected=0 }
            'End' { $selected=$Members.Count-1 }
            'Enter' {
                if ((Get-DeckTerminalHealth $cache[$Members[$selected]]) -eq 'Exhausted') { $notice='That account is exhausted. Refresh it or select another.' }
                else { return $Members[$selected] }
            }
            'B' {
                $best=@(Get-DeckRecommendations $Members $cache) | Select-Object -First 1
                if ($best) { $selected=[array]::IndexOf($Members,$best.Account); $notice=$best.Reason }
                else { $notice='No fresh available quota. Refresh an account with R.' }
            }
            'R' {
                $task=$null
                try {
                    $name=$Members[$selected]
                    $task=Start-DeckTask (Get-DeckCheckCode $SuiteRoot $name) 'check' $name
                    Write-Host 'Checking usage (Esc cancels)...'
                    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(90)
                    while (-not (Test-DeckTaskReady $task)) {
                        if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Usage check timed out.' }
                        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Escape') { throw 'Check cancelled.' }
                        Start-Sleep -Milliseconds 100
                    }
                    if ($task.Process.ExitCode -ne 0) { throw 'Usage check failed.' }
                    $row=@(Expand-DeckTerminalRecords ($task.Out.Result | ConvertFrom-Json) | Where-Object Account -eq $name)
                    if ($row.Count -ne 1) { throw 'No matching usage result.' }
                    $row[0] | Add-Member NoteProperty CheckedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
                    $cache[$name]=$row[0]
                    $cache=Save-DeckUsageCache (Join-Path $SuiteRoot 'deck') $cache 'terminal-cache.json'
                    $notice="$name refreshed."
                } catch { $notice=$_.Exception.Message }
                finally { if ($task) { Stop-DeckTask $task; Dispose-DeckTask $task } }
            }
        }
    }
}

function Show-DeckHistoryBrowser([string]$SuiteRoot, [string]$AuthScript, [string]$Filter = '', [hashtable]$DashboardState = $null) {
    if (-not [Console]::IsOutputRedirected) { Clear-Host; Write-Host 'Loading local session history...' -ForegroundColor Cyan }
    $rows=@(Get-DeckSessionHistory $SuiteRoot $Filter)
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $rows | Select-Object Account,Id,UpdatedAt,Folder,Provider
        return
    }
    $offset=0; $message='Search matches account, folder, provider or session ID. No conversation contents are read.'
    do {
        Clear-Host
        Write-Host 'CODEX DECK / SESSION HISTORY' -ForegroundColor Cyan
        Write-Host (ConvertTo-DeckTerminalText ('Filter: '+$Filter+' | '+$rows.Count+' sessions'))
        $size=[Math]::Max(1,[Console]::WindowHeight-9)
        for($i=$offset; $i -lt [Math]::Min($rows.Count,$offset+$size); $i++) {
            $row=$rows[$i]
            Write-Host (ConvertTo-DeckTerminalText ('{0,3}. {1} | {2} | {3} | {4}' -f ($i+1),$row.Account,$row.UpdatedAt.ToLocalTime().ToString('MMM dd HH:mm'),$row.Folder,$row.Id) ([Math]::Max(1,[Console]::WindowWidth-1)))
        }
        if(-not $rows.Count){Write-Host 'No local sessions match. Only supported rollout metadata is listed.'}
        Write-Host (ConvertTo-DeckTerminalText $message) -ForegroundColor Yellow
        $inputValue=Read-DeckTerminalInput 'Number resumes | N next | P previous | / search | R reload | Q back'
        switch($inputValue.ToUpperInvariant()) {
            'Q' { return }
            'N' { if($offset+$size -lt $rows.Count){$offset+=$size}; continue }
            'P' { $offset=[Math]::Max(0,$offset-$size); continue }
            '/' { $Filter=Read-DeckTerminalInput 'Search (empty = all)'; $rows=@(Get-DeckSessionHistory $SuiteRoot $Filter); $offset=0; continue }
            'R' { $rows=@(Get-DeckSessionHistory $SuiteRoot $Filter); $offset=0; continue }
        }
        $number=0
        if(-not [int]::TryParse($inputValue,[ref]$number) -or $number -lt 1 -or $number -gt $rows.Count){continue}
        $row=$rows[$number-1]
        # Re-read metadata to avoid launching a stale or replaced selection.
        $current=@(Get-DeckSessionHistory $SuiteRoot $row.Id | Where-Object { $_.Account -eq $row.Account -and $_.Id -eq $row.Id }) | Select-Object -First 1
        if(-not $current){$message='Session no longer exists. Reload the list.'; continue}
        if(-not $current.Folder -or -not (Test-Path -LiteralPath $current.Folder -PathType Container)){$message='Original working folder is unavailable; restore it before resuming.'; continue}
        Push-Location -LiteralPath $current.Folder
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AuthScript $current.Account resume $current.Id
            $message='Session returned (exit '+$LASTEXITCODE+').'
            if($DashboardState){$DashboardState.LastConversation=$current}
        } finally { Pop-Location }
    } while($true)
}
