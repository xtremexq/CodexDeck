[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]*$')][string]$Account,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProjectRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Model,
    [Parameter(Mandatory)][ValidateSet('low','medium','high','xhigh','max','ultra')][string]$Effort,
    [Parameter(Mandatory)][ValidateSet('Diagnostic','Repair')][string]$Mode,
    [Parameter(Mandatory)][ValidateSet('read-only','workspace-write','danger-full-access')][string]$ParentSandboxMode,
    [Parameter(Mandatory)][ValidateSet('never','on-request','untrusted')][string]$ApprovalPolicy,
    [ValidateSet('read-only','workspace-write','danger-full-access')][string]$SandboxMode,
    [bool]$ParentNetworkAccess = $false,
    [switch]$NeedsNetwork,
    [switch]$AutoCompact,
    [int]$AutoCompactFreePercent = 0,
    [string]$OutputLastMessage,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw 'ProjectRoot must be an existing directory.'
}
if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'A worker task prompt is required.' }
if (-not $SandboxMode) { $SandboxMode = $ParentSandboxMode }
$permissionRank = @{'read-only'=0; 'workspace-write'=1; 'danger-full-access'=2}
if ($permissionRank[$SandboxMode] -gt $permissionRank[$ParentSandboxMode]) {
    throw 'Worker permissions cannot be broader than the parent permissions.'
}
if ($Mode -eq 'Repair' -and $SandboxMode -eq 'read-only') {
    throw 'Repair workers require authorized writable permissions.'
}
if ($NeedsNetwork -and -not $ParentNetworkAccess) {
    throw 'Live requests require parent network authorization.'
}
if ($NeedsNetwork -and $SandboxMode -eq 'read-only') {
    throw 'Live read-only workers need a verified custom permission profile; legacy read-only sandbox flags are insufficient.'
}
if ($AutoCompactFreePercent -ne 0 -and ($AutoCompactFreePercent -lt 30 -or $AutoCompactFreePercent -gt 90)) {
    throw 'AutoCompactFreePercent must be 0 (configured default) or 30-90.'
}

# Preserve the established parent policy; do not inject a Windows sandbox override.
# Omit --json so this exact argument array works with Native and Custom supervision.
$workerArgs = @('exec','-C',[IO.Path]::GetFullPath($ProjectRoot),'-m',$Model,
    '-c',('model_reasoning_effort="'+$Effort+'"'),
    '-c','agents.enabled=false','-c','features.multi_agent=false',
    '-s',$SandboxMode,'-a',$ApprovalPolicy)
if ($NeedsNetwork -and $SandboxMode -eq 'workspace-write') {
    $workerArgs += @('-c','sandbox_workspace_write.network_access=true')
}
if ($OutputLastMessage) { $workerArgs += @('-o',$OutputLastMessage) }
$workerArgs += @($Prompt)
$launch = @{Account=$Account; Direct=$true; Failover='Off'; CodexArgs=[string[]]$workerArgs}
if ($AutoCompact -or $AutoCompactFreePercent -ne 0) {
    $launch.AutoCompact = $true
    if ($AutoCompactFreePercent -ne 0) {
        $launch.CodexArgs = [string[]](@([string]$AutoCompactFreePercent+'%') + $workerArgs)
    }
}
return $launch
