param([string]$Executable,[string]$Folder,[string[]]$Arguments)
$ErrorActionPreference='Stop'
# The Windows identity, not a redirected directory, isolates the secure keyring.
$runnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runnerProfile=Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows NT/CurrentVersion/ProfileList/$runnerSid"
$profilePath=[Environment]::ExpandEnvironmentVariables($runnerProfile.ProfileImagePath)
$env:USERPROFILE=$profilePath
$env:LOCALAPPDATA=Join-Path $profilePath 'AppData/Local'
$env:APPDATA=Join-Path $profilePath 'AppData/Roaming'
foreach($key in @('HOME','GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_GEMINI_BASE_URL')){[Environment]::SetEnvironmentVariable($key,$null,'Process')}
if(-not (Test-Path -LiteralPath $Executable -PathType Leaf)){throw 'The runner cannot access the Antigravity binary. Install it in a location readable by this Windows user.'}
Set-Location -LiteralPath $Folder
$configPath=Join-Path $profilePath '.gemini/antigravity-cli/settings.json'
if(Test-Path -LiteralPath $configPath){
    $config=[IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    if($config.modelProvider){$config.PSObject.Properties.Remove('modelProvider');[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
}
# DECK_NATIVE_HELPERS
Invoke-DeckHarnessProcess $Executable $Arguments
exit $LASTEXITCODE
