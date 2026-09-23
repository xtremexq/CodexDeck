param([string]$OutputPath = (Join-Path $PSScriptRoot 'terminal.png'))
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot '../suite/Deck.Core.ps1')
. (Join-Path $PSScriptRoot '../suite/Deck.AccountTools.ps1')
. (Join-Path $PSScriptRoot '../suite/Deck.Terminal.ps1')

# Render the actual dashboard frame with example data. No installed accounts are read.
$now = [DateTimeOffset]::Now
function New-ExampleWindow([string]$Label, [int]$Duration, [int]$Remaining, [DateTimeOffset]$Reset) {
    return @{Label=$Label;DurationSeconds=$Duration;RemainingPct=$Remaining;ResetsAtUnix=$Reset.ToUnixTimeSeconds()}
}
$names = @('pool','account1','account2','account3','work-main')
$profiles = @{
    pool      = @{PlanType='pool';Email='';Model='default';Effort='default'}
    account1  = @{PlanType='plus';Email='demo@example.com';Model='default';Effort='high'}
    account2  = @{PlanType='plus';Email='second@example.com';Model='default';Effort='medium'}
    account3  = @{PlanType='free';Email='third@example.com';Model='default';Effort='medium'}
    'work-main' = @{PlanType='plus';Email='work@example.com';Model='default';Effort='high'}
}
$checked = $now.AddMinutes(-2).ToString('o')
$cache = @{
    pool = @{Status='available';Windows=@()}
    account1 = @{Status='available';CheckedAt=$checked;Windows=@(
        (New-ExampleWindow '5H' 18000 72 $now.AddHours(3)),
        (New-ExampleWindow 'Weekly' 604800 49 $now.AddDays(4)))}
    account2 = @{Status='available';CheckedAt=$checked;Windows=@(
        (New-ExampleWindow '5H' 18000 95 $now.AddHours(4)),
        (New-ExampleWindow 'Weekly' 604800 86 $now.AddDays(5)))}
    account3 = @{Status='available';CheckedAt=$checked;Windows=@(
        (New-ExampleWindow '30-day' 2592000 42 $now.AddDays(12)))}
    'work-main' = @{Status='available';CheckedAt=$checked;Windows=@(
        (New-ExampleWindow '5H' 18000 18 $now.AddHours(2)),
        (New-ExampleWindow 'Weekly' 604800 31 $now.AddDays(3)))}
}
$sessions = @([pscustomobject]@{Account='account1';ProcessId=4820;Folder='C:\Projects\example'})
$frame = @(Get-DeckTerminalFrame $names $cache $profiles $sessions @{} 1 126 27 '' 'Select an account and press Enter to launch.' $true $null @{} $false 55 $false 'Native' 'Default')

$font = [Drawing.Font]::new('Consolas',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$format = [Drawing.StringFormat]::GenericTypographic
$lineHeight = 23
$width = 1240
$height = 56 + $frame.Count * $lineHeight + 16
$bitmap = [Drawing.Bitmap]::new($width,$height)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$brushes = @{}
try {
    $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#0C0C0C'))
    $header = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#1C1D1F'))
    $brushes.Header = $header
    $graphics.FillRectangle($header,0,0,$width,43)
    $colors = @{
        Black='#0C0C0C';DarkBlue='#0B398F';White='#F1F3F5';Gray='#C9CDD2'
        DarkGray='#8B96A4';Cyan='#6FE3E8';DarkCyan='#4CB4BF';Green='#6EDD91'
        Yellow='#EBC16D';DarkMagenta='#C19BD0'
    }
    foreach($name in $colors.Keys){$brushes[$name]=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($colors[$name]))}
    $graphics.DrawString('>_ codex-auth',$font,$brushes.White,24,12,$format)
    $graphics.DrawString('SYNTHETIC PREVIEW',$font,$brushes.DarkGray,$width-208,12,$format)
    for($i=0;$i -lt $frame.Count;$i++){
        $line=$frame[$i]
        $y=52+$i*$lineHeight
        if($line.Background -ne 'Black'){$graphics.FillRectangle($brushes[$line.Background],18,$y-2,$width-36,$lineHeight)}
        $graphics.DrawString([string]$line.Text,$font,$brushes[$line.Color],22,$y,$format)
    }
    $bitmap.Save($OutputPath,[Drawing.Imaging.ImageFormat]::Png)
} finally {
    foreach($brush in $brushes.Values){$brush.Dispose()}
    $graphics.Dispose()
    $bitmap.Dispose()
    $font.Dispose()
}
