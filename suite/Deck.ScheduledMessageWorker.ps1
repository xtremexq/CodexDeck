param([Parameter(Mandatory=$true)][string]$JobId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Deck.ScheduledMessages.ps1')
try{Invoke-DeckScheduledMessageJob $PSScriptRoot $JobId}catch{Write-Error $_}
