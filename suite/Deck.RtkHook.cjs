'use strict';
const {spawnSync}=require('node:child_process');

function handle(input, rewrite) {
  if (!input || input.hook_event_name!=='PreToolUse' || input.tool_name!=='Bash') return null;
  const toolInput=input.tool_input && typeof input.tool_input==='object' ? input.tool_input : {};
  let command=typeof toolInput.command==='string' ? toolInput.command : '';
  if (!command.trim()) return null;
  // A per-command, cross-shell escape hatch. The pseudo-prefix is removed before
  // Codex executes the original command, so it works in PowerShell and cmd too.
  if (/^\s*NO_RTK=1(?:\s+|$)/.test(command)) {
    command=command.replace(/^\s*NO_RTK=1(?:\s+|$)/,'');
    return {hookSpecificOutput:{hookEventName:'PreToolUse',permissionDecision:'allow',updatedInput:{...toolInput,command}}};
  }
  if (process.env.NO_RTK==='1' || /^\s*(?:["'][^"']+["']\s+)?rtk(?:\.exe)?\b/i.test(command)) return null;
  const rewritten=rewrite(command);
  if (!rewritten || rewritten===command) return null;
  return {hookSpecificOutput:{hookEventName:'PreToolUse',permissionDecision:'allow',updatedInput:{...toolInput,command:rewritten}}};
}

function runRewrite(command) {
  const executable=process.env.CODEX_DECK_RTK_EXE;
  if (!executable) return '';
  const result=spawnSync(executable,['rewrite',command],{
    encoding:'utf8',windowsHide:true,timeout:4000,
    env:{...process.env,RTK_TELEMETRY_DISABLED:'1'}
  });
  return result.status===0 ? (result.stdout||'').trim() : '';
}

module.exports={handle};
if(require.main===module){
  let raw=''; process.stdin.setEncoding('utf8'); process.stdin.on('data',chunk=>raw+=chunk);
  process.stdin.on('end',()=>{
    try { const output=handle(JSON.parse(raw.replace(/^\uFEFF/,'')),runRewrite); if(output)process.stdout.write(JSON.stringify(output)); }
    catch { /* Hooks fail open: Codex receives the untouched command. */ }
  });
}
