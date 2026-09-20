param([Parameter(Mandatory=$true)][string]$JobId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.ScheduledMessages.ps1')
try{Invoke-DeckDelayedMessageJob $PSScriptRoot $JobId;exit 0}catch{Write-Error $_;exit 1}
