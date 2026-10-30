'use strict';
// One launch, loopback only. Credentials and request bodies never enter logs.
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { pipeline } = require('node:stream');
const zlib = require('node:zlib');
const readJson = p => JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
const MAX_BODY = 32 * 1024 * 1024;
function rank(pool, rows, now = Date.now()) {
  return pool.map(name => {
    const r = rows[name] || Object.entries(rows).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1], age = now - Date.parse(r?.CheckedAt);
    if (!r || r.Error || r.Status !== 'available' || !Number.isFinite(age) || age < -60000 || age > 300000 || !r.Windows?.length) return null;
    if (r.Windows.some(w => w.RemainingPct == null || !(w.RemainingPct > 0 && w.RemainingPct <= 100) || w.Dead || (w.ResetsAtUnix && w.ResetsAtUnix * 1000 <= now))) return null;
    return { name, score: Math.min(...r.Windows.map(w => +w.RemainingPct)),
      avg: r.Windows.reduce((s, w) => s + +w.RemainingPct, 0) / r.Windows.length,
      reset: Math.min(...r.Windows.filter(w => w.ResetsAtUnix).map(w => +w.ResetsAtUnix), Infinity) };
  }).filter(Boolean).sort((a,b) => b.score-a.score || b.avg-a.avg || a.reset-b.reset || a.name.localeCompare(b.name)).map(r => r.name);
}
function cachedRows(root) {
  const rows = {};
  function visit(value) {
    if (!value || typeof value !== 'object') return;
    if (value.Account && value.CheckedAt) {
      if (!rows[value.Account] || Date.parse(value.CheckedAt) > Date.parse(rows[value.Account].CheckedAt)) rows[value.Account] = value;
    } else for (const v of Object.values(value)) visit(v);
  }
  for (const name of ['cache.json','terminal-cache.json']) {
    try { visit(readJson(path.join(root, 'deck', name))); } catch { /* missing cache is unknown */ }
  }
  return rows;
}
function credentials(root, name) {
  if (!/^[a-z][a-z0-9_-]{0,39}$/i.test(name) || /^(con|prn|aux|nul|com\d|lpt\d)$/i.test(name)) throw Error('Invalid pool account.');
  const accounts = path.join(root, 'accounts'), dir = path.join(accounts, name), file = path.join(dir, 'auth.json');
  for (const p of [accounts, dir, file]) if (fs.lstatSync(p).isSymbolicLink()) throw Error('Linked account credentials are not supported.');
  const auth = readJson(file);
  if (!auth.tokens?.access_token || !auth.tokens?.account_id || (auth.auth_mode && String(auth.auth_mode).toLowerCase() !== 'chatgpt')) throw Error(`Pool account ${name} needs a file-based ChatGPT login.`);
  const result={token:auth.tokens.access_token,id:auth.tokens.account_id};
  if(auth.tokens.id_token)result.idToken=auth.tokens.id_token;
  return result;
}
function quotaRejected(status, body) {
  if (status !== 429) return false;
  return quotaErrorBody(body);
}
function quotaErrorBody(body) {
  const usageLimitText=/(?:usage.{0,40}(?:limit|exceed|reach|exhaust)|(?:limit|exceed|reach|exhaust).{0,40}usage|insufficient.{0,20}quota|quota.{0,40}(?:exceed|reach|limit|exhaust)|(?:exceed|reach|exhaust).{0,40}quota|rate[_ -]?limit[_ -]?exceeded)/i;
  try {
    const e = JSON.parse(body).error;
    const kinds = ['usage_limit_reached','insufficient_quota','rate_limit_exceeded','billing_hard_limit_reached','quota_exceeded'];
    if(kinds.includes(e?.type) || kinds.includes(e?.code))return true;
    return usageLimitText.test([e?.message,e?.detail,e?.type,e?.code].filter(Boolean).join(' ')) || usageLimitText.test(body.toString('utf8'));
  } catch { return usageLimitText.test(body.toString('utf8')); }
}
function isInvalidAuthBody(body) {
  const text=body.toString('utf8');
  const authFailure=/(?:\btoken\b.{0,60}\b(?:revoked|expired|invalid|invalidated|no longer valid|not valid)\b|\b(?:revoked|expired|invalid|invalidated)\b.{0,60}\btoken\b|invalidated oauth token|(?:oauth|access|bearer|refresh)[_ -]token.{0,60}(?:revoked|expired|invalid|invalidated)|refresh[_ -]token.{0,40}(?:revoked|expired|invalid)|invalid[_ -]grant|invalid[_ -]token|session.{0,40}(?:expired|revoked|invalid)|(?:expired|revoked|invalid).{0,40}session)/i;
  if (authFailure.test(text)) return true;
  try {
    const error = JSON.parse(text).error || {};
    return authFailure.test([error.code, error.type, error.message].filter(Boolean).join(' '));
  } catch { return authFailure.test(text); }
}
function tokenEmail(token) {
  try {
    const part = String(token || '').split('.')[1];
    if (!part) return null;
    const claims = JSON.parse(Buffer.from(part.replace(/-/g,'+').replace(/_/g,'/'), 'base64').toString('utf8'));
    return claims.email || claims['https://api.openai.com/profile']?.email || claims['https://api.openai.com/auth']?.email || null;
  } catch { return null; }
}
function authEmail(auth) {
  return tokenEmail(auth?.idToken) || tokenEmail(auth?.token);
}
function accountEmail(root, account) {
  try {
    const auth = readJson(path.join(root, 'accounts', account, 'auth.json'));
    return tokenEmail(auth.tokens?.id_token) || tokenEmail(auth.tokens?.access_token);
  } catch { return null; }
}
function recordRevokedAuth(root, account, rejectedEmail, rejectedToken) {
  if (!root || !/^[a-z][a-z0-9_-]{0,39}$/i.test(account)) return null;
  let email = rejectedEmail;
  try {
    const authPath = path.join(root, 'accounts', account, 'auth.json');
    const current=readJson(authPath);
    // The file may have been refreshed while the rejected request was in
    // flight. Never mark a newer, different token as revoked.
    if (!rejectedToken || current.tokens?.access_token !== rejectedToken) return null;
    const stat = fs.statSync(authPath, { bigint:true });
    const authStamp = authFileStamp(stat);
    try {
      const directory = path.join(root, 'deck', 'auth-issues');
      fs.mkdirSync(directory, { recursive:true, mode:0o700 });
      const file = path.join(directory, account + '.json');
      let alreadyRecorded=false;
      try {
        const old = readJson(file);
        alreadyRecorded=old.Account===account && ['token_revoked','oauth_invalid'].includes(old.Code) && old.AuthFileStamp===authStamp;
      } catch { /* Write the first marker. */ }
      if(!alreadyRecorded){
        const temporary=file+'.'+process.pid+'.'+crypto.randomBytes(8).toString('hex')+'.tmp';
        try{
          fs.writeFileSync(temporary,JSON.stringify({Version:1,Account:account,Email:email,Code:'oauth_invalid',DetectedAt:new Date().toISOString(),AuthFileStamp:authStamp}),{flag:'wx',mode:0o600});
          fs.renameSync(temporary,file);
        }finally{try{fs.unlinkSync(temporary)}catch{}}
      }
    } catch { /* Dashboard auth status is best-effort. */ }
    return {email,authStamp};
  } catch { return null; }
}
function helperStatusPath(root, account) {
  return path.join(root, 'deck', 'auth-helper', 'status', account + '.json');
}
function writeAuthHelperStatus(root, account, email, state, message, authStamp, attemptId, processId = 0) {
  let temporary;
  try {
    const helperPath=path.join(root,'deck','auth-helper.dat');
    const helperStamp=(()=>{try{const stat=fs.statSync(helperPath,{bigint:true});return (stat.mtimeNs/100n+621355968000000000n).toString()}catch{return '0'}})();
    const file=helperStatusPath(root,account); temporary=file+'.'+process.pid+'.'+crypto.randomBytes(6).toString('hex')+'.tmp';
    fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
    fs.writeFileSync(temporary,JSON.stringify({Version:1,Account:account,Email:email,State:state,Message:message,At:new Date().toISOString(),AuthFileStamp:authStamp,HelperFileStamp:helperStamp,AttemptId:attemptId,ProcessId:processId}),{flag:'wx',mode:0o600});
    fs.renameSync(temporary,file);
    return true;
  } catch { return false; }
  finally { if(temporary)try{fs.unlinkSync(temporary)}catch{} }
}
function authHelperProcessAlive(processId) {
  const pid=Number(processId);
  if(!Number.isSafeInteger(pid) || pid<=0) return false;
  try { process.kill(pid,0); return true; }
  catch(error) { return error?.code==='EPERM'; }
}
function setQueuedAuthHelperProcessId(root, account, attemptId, processId) {
  let temporary;
  try {
    const file=helperStatusPath(root,account), state=readJson(file);
    if(state?.AttemptId!==attemptId || state.State!=='queued') return false;
    state.ProcessId=processId;
    temporary=file+'.'+process.pid+'.'+crypto.randomBytes(6).toString('hex')+'.tmp';
    fs.writeFileSync(temporary,JSON.stringify(state),{flag:'wx',mode:0o600});
    fs.renameSync(temporary,file);
    return true;
  } catch { return false; }
  finally { if(temporary)try{fs.unlinkSync(temporary)}catch{} }
}
function failAuthHelperAttempt(root, account, email, authStamp, attemptId, message = 'Auth Helper worker exited before reporting an outcome.') {
  try {
    const state=readJson(helperStatusPath(root,account));
    if(state?.AttemptId!==attemptId || state.AuthFileStamp!==authStamp || !['queued','running'].includes(state.State)) return false;
    return writeAuthHelperStatus(root,account,email,'failed',message,authStamp,attemptId,0);
  } catch { return false; }
}
async function startAuthHelper(root, account, email, originalAuth, originalStamp, shouldStop = () => false) {
  if (!root || !email || !originalStamp) return Promise.resolve(false);
  const helper = path.join(root, 'Deck.AuthHelper.ps1');
  if (!fs.existsSync(helper)) return Promise.resolve(false);
  const attemptId=crypto.randomBytes(16).toString('hex');
  const statusPath=helperStatusPath(root,account);
  // Reuse a live J/dashboard recovery if one already owns this exact profile.
  try {
    const prior=readJson(statusPath);
    const age=Date.now()-Date.parse(prior?.At || '');
    const activeWindow=prior?.State==='queued' ? 30000 : 360000;
    if(['queued','running'].includes(prior?.State) && String(prior.Email||'').toLowerCase()===String(email).toLowerCase() && prior.AuthFileStamp===originalStamp && Number.isFinite(age) && age>=0 && age<activeWindow){
      const hasProcessId=Number.isSafeInteger(Number(prior.ProcessId)) && Number(prior.ProcessId)>0;
      const workerAlive=hasProcessId ? authHelperProcessAlive(prior.ProcessId) : prior.State==='queued' && age<30000;
      if(workerAlive || (!hasProcessId && prior.State==='running')){
        const recovered=await waitForAuthHelper(root,account,email,originalAuth,originalStamp,330000,shouldStop,null,prior.AttemptId,Date.parse(prior.At));
        if(recovered || shouldStop()) return recovered;
        const latest=readJson(statusPath);
        // A queued status without a worker PID that never advances is an
        // abandoned launch. Replace it once instead of leaving this request
        // waiting for another turn to start recovery.
        if(latest?.AttemptId!==prior.AttemptId || latest.State!=='queued' || Number(latest.ProcessId)>0) return false;
      }
    }
  } catch { /* Start a new recovery if there is no readable live status. */ }
  if(!writeAuthHelperStatus(root,account,email,'queued','Waiting for Deck Auth Helper.',originalStamp,attemptId)) return Promise.resolve(false);
  let child;
  try {
    child = spawn('powershell.exe', [
      '-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
      '-File',helper,'-Recover','-SuiteRoot',root,'-Account',account,'-Email',email,'-BrowserHarness','-Force','-AttemptId',attemptId
    ], { detached:true, windowsHide:true, stdio:'ignore' });
    if(child.pid) setQueuedAuthHelperProcessId(root,account,attemptId,child.pid);
    child.once('error',()=>failAuthHelperAttempt(root,account,email,originalStamp,attemptId,'Could not start Deck Auth Helper.'));
    child.once('exit',()=>failAuthHelperAttempt(root,account,email,originalStamp,attemptId));
    child.unref();
  } catch {
    failAuthHelperAttempt(root,account,email,originalStamp,attemptId,'Could not start Deck Auth Helper.');
    return Promise.resolve(false);
  }
  return waitForAuthHelper(root,account,email,originalAuth,originalStamp,330000,shouldStop,child,attemptId,Date.now());
}
function authFileStamp(stat) {
  return `${stat.size}:${(stat.mtimeNs / 100n + 621355968000000000n).toString()}`;
}
async function waitForAuthHelper(root, account, email, originalAuth, originalStamp, timeoutMs = 150000, shouldStop = () => false, child = null, attemptId = null, startedAt = 0) {
  const authPath=path.join(root,'accounts',account,'auth.json');
  const deadline=Date.now()+timeoutMs;
  while(Date.now()<deadline && !shouldStop()){
    try {
      const stat=fs.statSync(authPath,{bigint:true});
      if(authFileStamp(stat)!==originalStamp){
        const renewed=readJson(authPath);
        if(renewed.tokens?.account_id &&
          renewed.tokens?.access_token && renewed.tokens.access_token!==originalAuth.token &&
          String(accountEmail(root,account)||'').toLowerCase()===String(email).toLowerCase()) return true;
      }
    } catch { /* Login is writing credentials or has not started. */ }
    try {
      const state=readJson(helperStatusPath(root,account));
      const belongsToAttempt=attemptId ? state.AttemptId===attemptId : Date.parse(state.At)>=startedAt;
      if(belongsToAttempt && state.AuthFileStamp===originalStamp && ['unmatched','failed'].includes(state.State)) return false;
      const stateAge=Date.now()-Date.parse(state.At);
      if(!child && Number.isFinite(stateAge) && ((state.State==='queued' && stateAge>30000) || (state.State==='running' && stateAge>330000))) return false;
    } catch { /* The worker has not written status yet. */ }
    if(child?.exitCode!=null || child?.signalCode){
      // Check the auth file and status once more before treating an early exit
      // as a failed launch; the helper writes credentials immediately before exit.
      try {
        const renewed=readJson(authPath);
        if(renewed.tokens?.account_id && renewed.tokens?.access_token && renewed.tokens.access_token!==originalAuth.token && String(accountEmail(root,account)||'').toLowerCase()===String(email).toLowerCase()) return true;
      } catch { }
      return false;
    }
    await new Promise(resolve=>setTimeout(resolve,250));
  }
  return false;
}
function quotaRetryAt(incoming, body, row, now = Date.now()) {
  const future = value => {
    if (typeof value === 'string' && /^\d+(\.\d+)?$/.test(value.trim())) value = Number(value);
    const parsed = typeof value === 'number' && Number.isFinite(value)
      ? (value > 1e12 ? value : value * 1000)
      : Date.parse(value);
    return Number.isFinite(parsed) && parsed > now ? parsed + 1000 : null;
  };
  const retryAfter = Array.isArray(incoming?.headers?.['retry-after']) ? incoming.headers['retry-after'][0] : incoming?.headers?.['retry-after'];
  if (retryAfter != null) {
    const seconds = Number(retryAfter), parsed = Number.isFinite(seconds) ? now + Math.max(1, seconds) * 1000 : future(retryAfter);
    if (parsed > now) return parsed;
  }
  try {
    const candidates = [];
    const visit = value => {
      if (!value || typeof value !== 'object') return;
      for (const [key, child] of Object.entries(value)) {
        if (['resets_at','reset_at','retry_at'].includes(key.toLowerCase())) {
          const parsed = future(child); if (parsed) candidates.push(parsed);
        }
        if (child && typeof child === 'object') visit(child);
      }
    };
    visit(JSON.parse(body));
    if (candidates.length) return Math.min(...candidates);
  } catch { /* a recognized quota body need not include reset metadata */ }
  const windows = Array.isArray(row?.Windows) ? row.Windows : [];
  const cached = windows.filter(window => window?.Dead || (window?.RemainingPct != null && +window.RemainingPct <= 0))
    .map(window => future(window.ResetsAtUnix)).filter(Boolean);
  // When the service omits reset metadata, periodically allow one fresh probe.
  // This prevents an open terminal from retaining a stale local 429 forever.
  return cached.length ? Math.min(...cached) : now + 60000;
}
function accountBound(value) {
  if (!value || typeof value !== 'object') return false;
  // Encrypted reasoning and compaction items are the stateless, portable form
  // of history. Server-stored response/file/item references still require the
  // account that owns those objects.
  if (value.previous_response_id || value.file_id || value.type === 'item_reference') return true;
  return Object.values(value).some(v => typeof v === 'object' && accountBound(v));
}
function stableJson(value) {
  if (Array.isArray(value)) return '[' + value.map(stableJson).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + stableJson(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
function contextText(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(contextText).filter(Boolean).join('\n');
  if (!value || typeof value !== 'object') return '';
  for (const field of ['text','output','arguments','input','content','summary']) {
    if (value[field] != null) { const content=contextText(value[field]); if (content) return content; }
  }
  return '';
}
function hasContextText(value) {
  if (typeof value === 'string') return true;
  if (Array.isArray(value)) return value.some(hasContextText);
  if (!value || typeof value !== 'object') return false;
  return ['text','output','arguments','input','content'].some(field => value[field] != null && hasContextText(value[field]));
}
function replaceTextValue(value, replacement, used = {value:false}) {
  if (typeof value === 'string') { const result=used.value ? '' : replacement; used.value=true; return result; }
  if (Array.isArray(value)) return value.map(part => replaceTextValue(part,replacement,used));
  if (!value || typeof value !== 'object') return value;
  const copy={...value};
  for (const field of ['text','output','arguments','input','content']) {
    if (copy[field] != null && contextText(copy[field]) && hasContextText(copy[field])) { copy[field]=replaceTextValue(copy[field],replacement,used); return copy; }
  }
  for (const field of ['text','output','arguments','input','content']) {
    if (copy[field] != null && hasContextText(copy[field])) { copy[field]=replaceTextValue(copy[field],replacement,used); break; }
  }
  return copy;
}
function contextEntries(parsed) {
  const input = Array.isArray(parsed?.input) ? parsed.input : parsed?.input == null ? [] : [parsed.input];
  const sources = [];
  if (typeof parsed?.instructions === 'string') sources.push({source:'instructions',item:parsed.instructions});
  if (Array.isArray(parsed?.tools)) parsed.tools.forEach((item,toolIndex) => sources.push({source:'tools',toolIndex,item}));
  input.forEach((item,inputIndex) => sources.push({source:'input',inputIndex,item}));
  const seen = new Map();
  return sources.map(({source,toolIndex,inputIndex,item}, index) => {
    const serialized = stableJson(item);
    const hash = crypto.createHash('sha256').update(source+':'+serialized).digest('hex').slice(0, 24);
    const occurrence = seen.get(hash) || 0; seen.set(hash, occurrence + 1);
    const object = item && typeof item === 'object' ? item : {};
    const role = source === 'instructions' ? 'system' : typeof object.role === 'string' ? object.role : null;
    const type = source === 'instructions' ? 'instructions' : source === 'tools' ? 'tool_definition' : typeof object.type === 'string' ? object.type : typeof item === 'string' ? 'input_text' : 'item';
    const callId = object.call_id || object.callId || null;
    const content = source === 'tools' ? JSON.stringify(item,null,2) : contextText(item);
    const protectedItem = source === 'tools' || ['system','developer'].includes(role) || type === 'reasoning' || Boolean(object.encrypted_content);
    const editable = source !== 'tools' && type !== 'reasoning' && hasContextText(item);
    const opaque = !content && (object.encrypted_content ? 'Encrypted reasoning; plaintext is unavailable' : 'No displayable text in this item');
    return { key:`${hash}:${occurrence}`, index, source, toolIndex, inputIndex, type, role, name:object.name || null, callId, text:content,
      preview:content.slice(0, 420) || opaque, chars:content.length || serialized.length, tokens:Math.ceil((content.length || serialized.length) / 4),
      protected:protectedItem, editable, raw:item };
  });
}
function replaceContextText(item, replacement) {
  return replaceTextValue(item, replacement);
}
function projectContext(parsed, rules, allowProtected) {
  const entries = contextEntries(parsed);
  const projected = [], tools = [];
  let instructions = parsed.instructions;
  for (const entry of entries) {
    const rule = rules.get(entry.key);
    const usable = !rule || !entry.protected || allowProtected;
    entry.suppressed = Boolean(usable && rule?.action === 'suppress');
    entry.edited = Boolean(usable && rule?.action === 'edit');
    if (entry.suppressed) continue;
    const value=entry.edited ? replaceContextText(entry.raw, rule.text) : entry.raw;
    if (entry.source === 'instructions') instructions=value;
    else if (entry.source === 'tools') tools.push(value);
    else projected.push(value);
  }
  const output = JSON.parse(JSON.stringify(parsed));
  if (Array.isArray(parsed.input)) output.input = projected;
  else if (parsed.input != null) output.input = projected[0] ?? '';
  if (typeof parsed.instructions === 'string') {
    if (entries.some(entry=>entry.source==='instructions'&&entry.suppressed)) delete output.instructions;
    else output.instructions=instructions;
  }
  if (Array.isArray(parsed.tools)) output.tools=tools;
  const effective = contextEntries(output);
  const rawTokens = entries.reduce((sum, entry) => sum + entry.tokens, 0);
  const effectiveTokens = effective.reduce((sum, entry) => sum + entry.tokens, 0);
  return { output, entries, effective, rawTokens, effectiveTokens };
}
function contextThreadId(headers, parsed) {
  const direct=headers['thread-id'];
  if (typeof direct === 'string' && direct.length <= 128) return direct;
  try {
    const turn=JSON.parse(headers['x-codex-turn-metadata'] || '{}');
    if (typeof turn.thread_id === 'string' && turn.thread_id.length <= 128) return turn.thread_id;
  } catch { }
  const metadata=parsed?.client_metadata;
  for (const value of [metadata?.thread_id, headers['session-id'], metadata?.session_id, parsed?.prompt_cache_key]) {
    if (typeof value === 'string' && value.length > 0 && value.length <= 128) return value;
  }
  return null;
}
async function collect(stream, max) {
  const parts = []; let size = 0;
  for await (const part of stream) {
    size += part.length;
    if (size > max) throw Error('Body exceeds limit.');
    parts.push(part);
  }
  return Buffer.concat(parts);
}
function reply(res, status, message) {
  if (res.destroyed) return;
  if (res.headersSent) { res.destroy(); return; }
  res.writeHead(status, { 'content-type':'application/json', 'cache-control':'no-store' });
  res.end(JSON.stringify({ error: { type:'deck_failover_error', message } }));
}
function replyJson(res, value) {
  if (res.destroyed) return;
  res.writeHead(200, { 'content-type':'application/json', 'cache-control':'no-store' });
  res.end(JSON.stringify(value));
}
async function createProxy(config, dependencies = {}) {
  const pool = config.pool;
  if (!Array.isArray(pool) || !pool.length || pool.length > 200 || new Set(pool.map(n => n.toLowerCase())).size !== pool.length || !['Ordered','Best'].includes(config.mode)) throw Error('Select 1-200 distinct accounts and Ordered or Best mode.');
  const automatic = config.automatic !== false;
  const environmentPool = Array.isArray(config.environmentPool) ? config.environmentPool : [];
  if (environmentPool.some(name => !pool.includes(name))) throw Error('Environment accounts must belong to the failover pool.');
  const getCredentials = dependencies.credentials || (name => credentials(config.root, name));
  const getRows = dependencies.rows || (() => cachedRows(config.root));
  // The full-screen Codex UI owns the terminal after launch. Account changes
  // are queried through the control route instead of writing over the TUI.
  const report = dependencies.report || (() => {});
  // Production never accepts an upstream address from configuration or a request.
  const upstream = dependencies.upstream || 'https://chatgpt.com/backend-api/codex';
  const now = dependencies.now || Date.now;
  const contextEnabled = config.contextManager === true;
  const allowProtected = config.contextManagerProtected === true;
  const autoCompact = config.autoCompact && config.autoCompact.enabled === true
    ? {enabled:true,mode:config.autoCompact.mode === 'Custom' ? 'Custom' : 'Native',freePercent:Number(config.autoCompact.freePercent) || null}
    : {enabled:false,mode:null,freePercent:null};
  let usageRows = {}, usageRowsAt = -Infinity;
  const quotaStatus = () => {
    if (now() - usageRowsAt > 5000) { try { usageRows=getRows(); } catch { usageRows={}; } usageRowsAt=now(); }
    const row=usageRows[current] || Object.entries(usageRows).find(([name])=>name.toLowerCase()===current.toLowerCase())?.[1];
    return {checkedAt:row?.CheckedAt || null,windows:(row?.Windows || []).slice(0,2).map(window=>({label:window.Label || null,usedPercent:Number.isFinite(Number(window.UsedPct)) && window.UsedPct != null ? Number(window.UsedPct) : null,remainingPercent:Number.isFinite(Number(window.RemainingPct)) && window.RemainingPct != null ? Number(window.RemainingPct) : null,resetsAtUnix:window.ResetsAtUnix || null}))};
  };
  const contextWindows = new Map();
  const modelContextWindow = model => {
    if (!model || !config.root) return null;
    const key=current+':'+model, cached=contextWindows.get(key);
    if (cached && now()-cached.at<30000) return cached.value;
    let value=null;
    for (const account of [current,config.environment]) try {
      const entry=readJson(path.join(config.root,'accounts',account,'models_cache.json')).models?.find(item=>item.slug===model);
      const size=Number(entry?.context_window),percent=Number(entry?.effective_context_window_percent || 100);
      if(size>0 && percent>0){value=Math.floor(size*percent/100);break}
    } catch { /* model metadata is optional */ }
    contextWindows.set(key,{at:now(),value});
    return value;
  };
  const sessionStatus = () => ({model:contextSnapshot.model || null,contextWindow:contextSnapshot.model ? modelContextWindow(contextSnapshot.model) : null,autoCompact,quota:quotaStatus()});
  let contextRules = new Map(), contextThread = null;
  const threadRules = new Map();
  let contextSnapshot = { version:1, revision:0, enabled:contextEnabled, protectedChanges:allowProtected, threadId:null, capturedAt:null, requestPath:null, raw:[], effective:[], rawTokens:0, effectiveTokens:0, savedTokens:0, rules:[] };
  const refreshContextSnapshot = () => {
    const raw=contextSnapshot.raw.map(entry => {
      const rule=contextRules.get(entry.key), usable=!rule || !entry.protected || allowProtected;
      return {...entry,suppressed:Boolean(usable&&rule?.action==='suppress'),edited:Boolean(usable&&rule?.action==='edit')};
    });
    const effective=raw.filter(entry=>!entry.suppressed).map(entry=>{
      const rule=contextRules.get(entry.key);
      if(!entry.edited||typeof rule?.text!=='string')return entry;
      const chars=rule.text.length,tokens=Math.ceil(chars/4);
      return {...entry,text:rule.text,preview:rule.text.slice(0,420),chars,tokens};
    });
    const rawTokens=raw.reduce((sum,entry)=>sum+entry.tokens,0),effectiveTokens=effective.reduce((sum,entry)=>sum+entry.tokens,0);
    contextSnapshot={...contextSnapshot,revision:contextSnapshot.revision+1,raw,effective,rawTokens,effectiveTokens,savedTokens:Math.max(0,rawTokens-effectiveTokens)};
  };
  const excluded = new Set();
  const retryAt = new Map();
  const resetProbes = new Set();
  const authRecoveries = new Map();
  const refreshExcluded = () => {
    const timestamp = now();
    for (const name of excluded) if ((retryAt.get(name) || 0) <= timestamp) {
      excluded.delete(name); retryAt.delete(name); resetProbes.add(name);
    }
  };
  const rowFor = (rows, name) => rows[name] || Object.entries(rows).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1];
  const choices = (freshOnly = false) => {
    refreshExcluded();
    const usable = pool.filter(name => !excluded.has(name));
    if (config.mode !== 'Best') return usable;
    const ranked = rank(usable, getRows(), now());
    return freshOnly ? ranked : [...ranked, ...usable.filter(name => resetProbes.has(name) && !ranked.includes(name))];
  };
  let current = config.owner || choices(true)[0];
  if (config.owner && !pool.includes(config.owner)) throw Error('Starting account is not in the pool.');
  if (!current) throw Error('No fresh usable pool account. Refresh usage first.');
  // Automatic pools are validated up front. Manual-only sessions validate the
  // owner now and other accounts lazily, so one damaged unused login cannot
  // prevent an ordinary account from opening.
  if (automatic) for (const name of pool) getCredentials(name); else getCredentials(current);
  const secret = crypto.randomBytes(32).toString('hex');
  let activeRequests = 0;
  let lastRequestAccount = null;
  let lastRequestRoute = null;
  const status = () => {
    refreshExcluded();
    return ({
    version: 1,
    environment: { name:config.environment || null, pooled:environmentPool.length > 0, accounts:environmentPool },
    failover: { automatic, mode:config.mode, accounts:pool, active:current, unavailable:[...excluded], lastRequestAccount, lastRequestRoute },
    busy: activeRequests > 0,
    contextManager: { enabled:contextEnabled, protectedChanges:allowProtected }
    });
  };
  const server = http.createServer(async (req, res) => {
    // A capability URL, exact Host and no browser Origin prevent unauthenticated LAN/browser access.
    if (req.headers.host !== `127.0.0.1:${server.address().port}` || req.headers.origin || !req.url.startsWith('/' + secret + '/')) return reply(res, 403, 'Forbidden.');
    const route = req.url.slice(secret.length + 1), queryAt=route.indexOf('?'), routePath=queryAt<0?route:route.slice(0,queryAt), routeQuery=new URLSearchParams(queryAt<0?'':route.slice(queryAt+1));
    if (routePath === '/_deck/account') {
      if (req.method === 'GET') return replyJson(res, status());
      if (req.method !== 'POST') return reply(res, 404, 'Unsupported failover route.');
      if ((req.headers['content-encoding'] || 'identity') !== 'identity') return reply(res, 415, 'The account control request must not be compressed.');
      try {
        const body = JSON.parse((await collect(req, 4096)).toString('utf8'));
        const selected = pool.find(name => name.toLowerCase() === String(body.account || '').toLowerCase());
        if (!selected) return reply(res, 400, 'Choose an account from this session.');
        try { getCredentials(selected); } catch { return reply(res, 409, 'That account no longer has usable file-based login credentials.'); }
        // A quota rejection describes one request, not the account forever.
        // Manual selection is an explicit request to retry it (commonly after
        // its usage window reset). The next model request is the fresh probe;
        // another quota 429 will simply exclude it again.
        excluded.delete(selected);
        retryAt.delete(selected);
        resetProbes.add(selected);
        if (selected !== current) { current = selected; report(current); }
        return replyJson(res, status());
      } catch { return reply(res, 400, 'Expected a small JSON account request.'); }
    }
    if (routePath === '/_deck/context') {
      if (!contextEnabled) return reply(res, 404, 'The context manager is disabled for this conversation.');
      if (req.method === 'GET') {
        const since=Number(routeQuery.get('since'));
        const account=current;
        if(routeQuery.has('since')&&Number.isInteger(since)&&since===contextSnapshot.revision)return replyJson(res,{version:1,revision:contextSnapshot.revision,unchanged:true,busy:activeRequests>0,account,session:sessionStatus()});
        return replyJson(res, { ...contextSnapshot, account, busy:activeRequests > 0, session:sessionStatus(), rules:[...contextRules.entries()].map(([key,rule]) => ({key,...rule})) });
      }
      if (req.method !== 'POST' || (req.headers['content-encoding'] || 'identity') !== 'identity') return reply(res, 404, 'Unsupported context control request.');
      try {
        const request = JSON.parse((await collect(req, 64 * 1024)).toString('utf8'));
        if (request.action === 'clear') contextRules.clear();
        else {
          const entry = contextSnapshot.raw.find(value => value.key === request.key);
          if (!entry) return reply(res, 409, 'That context item is no longer in the latest request.');
          if (entry.protected && !allowProtected) return reply(res, 403, 'Protected system, developer and reasoning items require the advanced setting.');
          const targets = entry.callId && request.pair !== false ? contextSnapshot.raw.filter(value => value.callId === entry.callId) : [entry];
          if (request.action === 'restore') for (const target of targets) contextRules.delete(target.key);
          else if (request.action === 'suppress') for (const target of targets) contextRules.set(target.key, {action:'suppress'});
          else if (request.action === 'edit') {
            if (!entry.editable || typeof request.text !== 'string' || request.text.length > 250000) return reply(res, 400, 'This item cannot be edited or the replacement is too large.');
            contextRules.set(entry.key, {action:'edit', text:request.text});
          } else return reply(res, 400, 'Expected suppress, edit, restore or clear.');
        }
        refreshContextSnapshot();
        return replyJson(res, { ok:true, rules:[...contextRules.entries()].map(([key,rule]) => ({key,...rule})), appliesTo:'next request' });
      } catch { return reply(res, 400, 'Expected a small JSON context control request.'); }
    }
    // Codex extensions can use provider-relative auxiliary endpoints in
    // addition to Responses and Models. Forward GET/POST routes to the fixed
    // Codex upstream, but reserve Deck's namespace and never accept a caller-
    // supplied destination. Only Responses requests are eligible for replay.
    if (!['GET','POST'].includes(req.method) || routePath.startsWith('/_deck/') || !routePath.startsWith('/')) return reply(res, 404, 'Unsupported Deck routing request.');
    const conversation = req.method === 'POST' && ['/responses','/responses/compact'].includes(routePath);
    if (conversation) activeRequests++;
    let outbound;
    const cancel = () => { if (!res.writableFinished) outbound?.destroy(); };
    res.on('close', cancel);
    try {
      const encoding = req.headers['content-encoding'] || 'identity';
      if (!['identity','gzip','deflate','br','zstd'].includes(encoding) || (encoding === 'zstd' && !zlib.zstdDecompressSync)) return reply(res, 415, 'Unsupported request compression; update Node.js for zstd support.');
      let body = await collect(req, MAX_BODY);
      if (encoding !== 'identity') {
        const decode = {gzip:zlib.gunzipSync,deflate:zlib.inflateSync,br:zlib.brotliDecompressSync,zstd:zlib.zstdDecompressSync}[encoding];
        try { body = decode(body, {maxOutputLength:MAX_BODY}); } catch { return reply(res, 400, 'Invalid or oversized compressed request.'); }
      }
      let bound = false;
      if (conversation) {
        let parsed; try { parsed = JSON.parse(body); } catch { return reply(res, 400, 'Expected JSON request.'); }
        if (contextEnabled) {
          const threadId=contextThreadId(req.headers,parsed);
          if(threadId && threadId!==contextThread){
            if(contextThread)threadRules.set(contextThread,contextRules);
            contextRules=threadRules.get(threadId) || new Map();
            contextThread=threadId;
          }
          const projection = projectContext(parsed, contextRules, allowProtected);
          parsed = projection.output;
          body = Buffer.from(JSON.stringify(parsed));
          contextSnapshot = { version:1, revision:contextSnapshot.revision+1, enabled:true, protectedChanges:allowProtected, threadId:contextThread, capturedAt:new Date(now()).toISOString(), requestPath:routePath, model:typeof parsed.model==='string' ? parsed.model : null,
            hasServerHistory:Boolean(parsed.previous_response_id || projection.entries.some(entry=>entry.type==='item_reference')),
            raw:projection.entries.map(({raw,...entry}) => entry), effective:projection.effective.map(({raw,...entry}) => entry),
            rawTokens:projection.rawTokens, effectiveTokens:projection.effectiveTokens, savedTokens:Math.max(0, projection.rawTokens - projection.effectiveTokens), rules:[] };
        }
        bound = accountBound(parsed);
      }
      // Let the active account validate server-stored references it owns. A 429
      // proves the request was rejected, so portable full/encrypted history can
      // be retried without duplicating an accepted response.
      let attempts = 0, maxAttempts = conversation ? (automatic ? pool.length : 1) + 1 : 1, authRecoveryRetried=false, forcedAuthRecoveryAccount=null;
      while (!res.destroyed && attempts++ < maxAttempts) {
        refreshExcluded();
        if (excluded.has(current)) {
          const next = automatic ? choices()[0] : null;
          if (next) { current = next; report(current); }
          else if (automatic) return reply(res, 429, 'Selected account quota is exhausted until its reset. Retry later or choose another account.');
          else {
            // A reset credit can restore usage before the reset timestamp that
            // accompanied the previous 429. In a manual-only session there is
            // no other account to rotate to, so let each explicit new request
            // make one live probe instead of manufacturing a stale local 429.
            // A 429 never selects the auth-recovery retry; without a next account
            // the rejected quota request is returned without replaying it.
            excluded.delete(current);
            retryAt.delete(current);
            resetProbes.add(current);
          }
        }
        const used = forcedAuthRecoveryAccount || current;
        forcedAuthRecoveryAccount=null;
        const auth = getCredentials(used);
        lastRequestAccount = used;
        lastRequestRoute = routePath;
        const headers = {};
        if (conversation) {
          headers['content-type']=req.headers['content-type'] || 'application/json';
          headers.accept=req.headers.accept || 'text/event-stream';
          // Keep model traffic on the small header surface already accepted by
          // the Codex backend. Client tracing/experimental headers can change
          // independently and have caused otherwise-valid requests to be rejected.
          for (const name of ['user-agent','originator','version','openai-beta']) if (req.headers[name]) headers[name]=req.headers[name];
        } else {
          const blockedHeaders = new Set(['host','authorization','chatgpt-account-id','x-account-id','x-chatgpt-account-id','openai-account-id','cookie','origin','content-length','content-encoding','accept-encoding','connection','proxy-connection','transfer-encoding','upgrade']);
          for (const [name,value] of Object.entries(req.headers)) if (!blockedHeaders.has(name) && !name.startsWith('sec-') && value != null) headers[name] = value;
        }
        headers.authorization='Bearer ' + auth.token;
        headers['chatgpt-account-id']=auth.id;
        headers['accept-encoding']='identity';
        headers['content-length']=body.length;
        if (body.length && !headers['content-type']) headers['content-type']='application/octet-stream';
        const url = new URL(upstream + route);
        const incoming = await new Promise((resolve, reject) => {
          outbound = (url.protocol === 'https:' ? https : http).request(url, { method:req.method, headers }, resolve);
          outbound.setTimeout(120000, () => outbound.destroy(Error('Upstream timeout.')));
          outbound.on('error', reject); outbound.end(body);
        });
        const responseHeaders = { 'cache-control':'no-store' };
        const blockedResponseHeaders = new Set(['connection','proxy-connection','transfer-encoding','upgrade','set-cookie']);
        for (const [name,value] of Object.entries(incoming.headers)) if (!blockedResponseHeaders.has(name) && name !== 'cache-control' && value != null) responseHeaders[name] = value;
        if (conversation && [401,403,429].includes(incoming.statusCode)) {
          let rejected;
          try { rejected=await collect(incoming,1024*1024); }
          catch { return reply(res,incoming.statusCode,'Upstream request was rejected.'); }
          if ((incoming.statusCode===403 || incoming.statusCode===429) && quotaErrorBody(rejected)) {
            excluded.add(used);
            resetProbes.delete(used);
            const rows = getRows();
            retryAt.set(used, quotaRetryAt(incoming, rejected, rowFor(rows, used), now()));
            // Usage limits belong to quota routing and never start OAuth
            // recovery. Rotate only when automatic failover has a candidate.
            const next = automatic ? (current !== used && !excluded.has(current) ? current : choices()[0]) : null;
            if (next && !bound && !res.destroyed) { current = next; report(current); continue; }
            if (automatic && bound && next) return reply(res, 409, 'Quota reached, but this request contains account-scoped history. Start a new session to change accounts.');
            res.writeHead(incoming.statusCode,responseHeaders); res.end(rejected); return;
          }
          // Rate limits without a recognized quota body stay errors; they do
          // not get mistaken for expired credentials.
          if(incoming.statusCode===429){res.writeHead(429,responseHeaders);res.end(rejected);return}
          resetProbes.delete(used);
          if ((incoming.statusCode===401 || incoming.statusCode===403) && !quotaErrorBody(rejected) && !authRecoveryRetried && isInvalidAuthBody(rejected)) {
            const email = authEmail(auth);
            if(email){
              let currentAuth=null;
              try{currentAuth=getCredentials(used)}catch{}
              const currentEmail=authEmail(currentAuth);
              if(currentAuth && currentAuth.token!==auth.token && String(currentAuth.id)===String(auth.id) && String(currentEmail||'').toLowerCase()===String(email).toLowerCase()){
                // J, Codex's native refresh, or another already-running helper
                // may have replaced this same account's token in flight.
                authRecoveryRetried=true;
                forcedAuthRecoveryAccount=used;
                continue;
              }
              const revoked=recordRevokedAuth(config.root,used,email,auth.token);
              if(revoked){
                let recovery=authRecoveries.get(used.toLowerCase());
                if(!recovery){
                  recovery=startAuthHelper(config.root,used,email,auth,revoked.authStamp);
                  authRecoveries.set(used.toLowerCase(),recovery);
                  recovery.then(()=>{if(authRecoveries.get(used.toLowerCase())===recovery)authRecoveries.delete(used.toLowerCase())},()=>{if(authRecoveries.get(used.toLowerCase())===recovery)authRecoveries.delete(used.toLowerCase())});
                }
                if(await recovery){
                  authRecoveryRetried=true;
                  forcedAuthRecoveryAccount=used;
                  continue;
                }
              }else{
                // Close the narrow race between checking the profile above
                // and reading it for the revoked marker.
                try{
                  currentAuth=getCredentials(used);
                  if(currentAuth.token!==auth.token && String(currentAuth.id)===String(auth.id) && String(authEmail(currentAuth)||'').toLowerCase()===String(email).toLowerCase()){
                    authRecoveryRetried=true;
                    forcedAuthRecoveryAccount=used;
                    continue;
                  }
                }catch{}
              }
            }
          }
          if(res.destroyed)return;
          res.writeHead(incoming.statusCode,responseHeaders);
          res.end(rejected);
          return;
        }
        resetProbes.delete(used);
        res.writeHead(incoming.statusCode, responseHeaders);
        res.flushHeaders();
        // Once accepted, stream directly with backpressure. Never replay even if the stream fails.
        await new Promise(resolve => pipeline(incoming, res, () => resolve()));
        return;
      }
    } catch { reply(res, 502, 'Deck routing request failed. No retry was made for an ambiguous transport or credential error.'); }
    finally { if (conversation) activeRequests--; res.removeListener('close', cancel); }
  });
  // Codex immediately falls back to HTTP when the endpoint declines WebSockets.
  server.on('upgrade', (_req, socket) => socket.end('HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'));
  server.on('clientError', (_err, socket) => socket.destroy());
  await new Promise((resolve,reject) => { server.once('error',reject); server.listen(0, '127.0.0.1', resolve); });
  const baseUrl = `http://127.0.0.1:${server.address().port}/${secret}`;
  return { server, baseUrl, contextUrl:contextEnabled ? baseUrl + '/_deck/context' : null, account:current };
}
module.exports = { createProxy, rank, quotaRejected, quotaRetryAt, accountBound, credentials, contextEntries, projectContext };
if (require.main === module) {
  if (Number(process.versions.node.split('.')[0]) < 18) { process.stderr.write('Deck failover requires Node.js 18 or newer.\n'); process.exit(1); }
  // Private inherited stdin supplies startup configuration and acts as a parent-lifetime pipe.
  let input = '', started = false;
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', async chunk => {
    if (started) return;
    input += chunk;
    if (input.length > 65536) process.exit(1);
    const newline = input.indexOf('\n'); if (newline < 0) return;
    started = true;
    try {
      const proxy = await createProxy(JSON.parse(input.slice(0,newline).replace(/^\uFEFF/, '')));
      process.stdout.write(JSON.stringify({ baseUrl:proxy.baseUrl, contextUrl:proxy.contextUrl, account:proxy.account }) + '\n');
    } catch (error) {
      const detail = error instanceof Error ? error.message.replace(/[\r\n]+/g, ' ') : 'Unknown startup error.';
      process.stderr.write('Deck failover could not start: ' + detail + '\n'); process.exit(1);
    }
    input = '';
  });
  process.stdin.on('end', () => process.exit(0));
}
