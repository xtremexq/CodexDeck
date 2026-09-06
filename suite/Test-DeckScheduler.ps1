$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.Core.ps1')
function Assert($value,$message){if(-not $value){throw $message}}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Codex-Deck.ps1'),[ref]$null,[ref]$null)
$tick=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeckTick'},$true)
Invoke-Expression $tick.Extent.Text
function Get-DeckSessions { [pscustomobject]@{Account='work-main'} }
function Get-DeckAccounts { 'work-main'; 'account7' }
function Update-DeckPicker {}
function Render-Deck {}
function Start-DeckTask($code,$kind,$account){$script:started=$account; return @{Kind=$kind;Account=$account}}
$root=Join-Path $env:TEMP ('deck-scheduler-'+[guid]::NewGuid().ToString('N'))
$suite=$PSScriptRoot; $settings=Get-DeckDefaults; $task=$null; $manualChecks=@{}; $nextCheck=@{}; $pendingWarm=$null
$lastRequest=[DateTimeOffset]::MinValue; $allProfiles=$false; $widget=$false; $started=$null
Invoke-DeckTick
Assert (-not $started) 'Disabled auto-check started a request'
$settings.AutoCheck=$true
Invoke-DeckTick
Assert ($started -eq 'work-main') 'Enabled auto-check missed a connected custom account'
$task=$null; $started=$null
Invoke-DeckTick
Assert (-not $started) 'Global request gap ignored'
$lastRequest=[DateTimeOffset]::MinValue; $nextCheck['work-main']=[DateTimeOffset]::UtcNow.AddMinutes(10)
Invoke-DeckTick
Assert (-not $started) 'Poll deadline ignored'
$allProfiles=$true
Invoke-DeckTick
Assert ($started -eq 'account7') 'Show all missed a disconnected profile'
$task=$null; $started=$null; $settings.AutoCheck=$false; $lastRequest=[DateTimeOffset]::MinValue
$manualChecks.account7=[DateTimeOffset]::UtcNow.AddSeconds(-1)
Invoke-DeckTick
Assert ($started -eq 'account7' -and -not $manualChecks.ContainsKey('account7')) 'Manual Check failed with auto-check disabled'
'PASS: actual scheduler disabled/enabled, custom accounts, stagger, deadlines, Show all and manual Check. No network or terminals.'
