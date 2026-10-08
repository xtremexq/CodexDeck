param([ValidateSet('Protect','Unprotect')][string]$Mode)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$bytes = [Convert]::FromBase64String([Console]::In.ReadToEnd().Trim())
$scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
if ($Mode -eq 'Protect') {
    $result = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
} else {
    $result = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, $scope)
}
[Console]::Out.Write([Convert]::ToBase64String($result))
