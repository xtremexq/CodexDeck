$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'skills/debug-swarm/scripts/New-WorkerLaunch.ps1'
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Expected) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike ('*'+$Expected+'*')) { throw }
        return
    }
    throw "Expected launch rejection: $Expected"
}
function Invoke-MockAuth {
    [CmdletBinding(PositionalBinding=$false)]
    param([string]$Account,[switch]$Direct,[string]$Failover,[switch]$AutoCompact,[string[]]$CodexArgs)
    [pscustomobject]@{Account=$Account; Direct=[bool]$Direct; Failover=$Failover;
        AutoCompact=[bool]$AutoCompact; Arguments=$CodexArgs}
}

$prompt = "Repair one family.`nKeep literal shell text: " + '$(Do-Not-Execute) `unchanged`'
$spec = @{Account='account111'; ProjectRoot=$PSScriptRoot; Model='gpt-6-luna'; Effort='xhigh';
    Mode='Repair'; ParentSandboxMode='danger-full-access'; ApprovalPolicy='never';
    ParentNetworkAccess=$true; NeedsNetwork=$true; Prompt=$prompt}
$launch = & $helper @spec -AutoCompactFreePercent 50 -OutputLastMessage 'report with spaces.md'
$received = Invoke-MockAuth @launch
Assert ($received.Account -ceq 'account111' -and $received.Direct -and $received.Failover -eq 'Off') 'Exact account isolation was lost.'
Assert ($received.AutoCompact -and $received.Arguments[0] -eq '50%' -and $received.Arguments[1] -eq 'exec') 'Explicit 50% auto-compaction was lost.'
Assert ($received.Arguments[-1] -ceq $prompt) 'The multiline prompt was split or evaluated.'
Assert ($received.Arguments[([array]::IndexOf($received.Arguments,'-m')+1)] -ceq 'gpt-6-luna') 'The requested model was changed.'
Assert ($received.Arguments -contains 'model_reasoning_effort="xhigh"') 'The requested reasoning effort was changed.'
Assert ($received.Arguments[([array]::IndexOf($received.Arguments,'-s')+1)] -eq 'danger-full-access') 'Repair permissions were silently restricted.'
Assert ($received.Arguments[([array]::IndexOf($received.Arguments,'-a')+1)] -eq 'never') 'The parent approval policy was changed.'
Assert (-not ($received.Arguments -contains '--json') -and -not ($received.Arguments -like 'windows.sandbox=*')) 'Launch added incompatible flags or a Windows sandbox override.'
Assert ($received.Arguments[([array]::IndexOf($received.Arguments,'-o')+1)] -ceq 'report with spaces.md') 'The output report path was split.'

$plain = & $helper @spec
Assert (-not $plain.ContainsKey('AutoCompact') -and $plain.CodexArgs[0] -eq 'exec') 'Auto-compact was enabled without a request.'
$configured = & $helper @spec -AutoCompact
Assert ($configured.AutoCompact -and $configured.CodexArgs[0] -eq 'exec') 'Configured auto-compact could not be selected.'
$bounded = & $helper @spec -SandboxMode workspace-write
Assert ($bounded.CodexArgs -contains 'sandbox_workspace_write.network_access=true') 'Authorized workspace network access was omitted.'
Reject { & $helper @spec -SandboxMode read-only } 'writable'
Reject { & $helper @spec -AutoCompactFreePercent 29 } '30-90'
Reject { & $helper @spec -AutoCompactFreePercent 91 } '30-90'
$restricted = $spec.Clone(); $restricted.ParentSandboxMode='workspace-write'
Reject { & $helper @restricted -SandboxMode danger-full-access } 'broader'
$restricted.ParentNetworkAccess=$false
Reject { & $helper @restricted } 'network authorization'
$diagnostic = $spec.Clone(); $diagnostic.Mode='Diagnostic'; $diagnostic.ParentSandboxMode='read-only'
Reject { & $helper @diagnostic } 'custom permission profile'
$diagnostic.NeedsNetwork=$false; $diagnostic.ParentNetworkAccess=$false
$readOnly = & $helper @diagnostic
Assert ($readOnly.CodexArgs[([array]::IndexOf($readOnly.CodexArgs,'-s')+1)] -eq 'read-only') 'Restricted offline diagnosis permissions were broadened.'

# Exercise the real Custom-mode argument translator, without starting any AI worker.
$payload = @($received.Arguments | Select-Object -Skip 1) | ConvertTo-Json -Compress
$translatorTest = @'
const fs=require('node:fs'),assert=require('node:assert/strict'),{translateLaunchArgs}=require(process.argv[1]);
const raw=JSON.parse(fs.readFileSync(0,'utf8').replace(/^\uFEFF/,''));
const parsed=translateLaunchArgs(raw,process.cwd());
assert.equal(parsed.once,true); assert.equal(parsed.prompt,raw.at(-1));
assert.ok(parsed.configArgs.includes('sandbox_mode='+JSON.stringify('danger-full-access')));
assert.ok(parsed.configArgs.includes('approval_policy='+JSON.stringify('never')));
assert.ok(parsed.configArgs.includes('model='+JSON.stringify('gpt-6-luna')));
'@
$payload | node -e $translatorTest (Join-Path $PSScriptRoot 'Deck.AutoCompact.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Custom auto-compact rejected the worker argument array.' }
'PASS: Debug Swarm preserves account/model/effort/permissions, explicit 50% compaction, literal prompts, and Custom-mode compatibility; no workers launched.'
