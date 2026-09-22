'use strict';
// Local-only trajectory/context studio and independent efficiency analytics.
// Both surfaces share the rollout index, but have separate settings and routes.
const http = require('node:http');
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const crypto = require('node:crypto');
const readline = require('node:readline');
const VERSION = crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex');

const MAX_CHUNK = 768 * 1024;
const cache = new Map();
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const idFor = value => crypto.createHash('sha256').update(value).digest('hex').slice(0, 24);
const safeJson = value => JSON.stringify(value).replace(/</g, '\\u003c');
async function mapLimit(values, limit, worker) {
  const result=new Array(values.length); let cursor=0;
  await Promise.all(Array.from({length:Math.min(limit,values.length)},async()=>{
    while(cursor<values.length){const index=cursor++;result[index]=await worker(values[index],index);}
  }));
  return result;
}
function settings(root) {
  try { return readJson(path.join(root, 'deck', 'settings.json')); }
  catch { return {}; }
}
function efficiencyLimit(root) {
  const saved=settings(root);
  const legacyDefault=saved.EfficiencyLimitVersion == null && Number(saved.EfficiencySessionLimit) === 200;
  const value=legacyDefault ? 1000 : Number(saved.EfficiencySessionLimit || 1000);
  return Math.max(10,Math.min(5000,Number.isFinite(value) ? value : 1000));
}
function enabled(root, mode) {
  const value = settings(root);
  return mode === 'trajectory' ? value.TrajectoryEnabled === true : value.EfficiencyAnalyticsEnabled === true;
}
function accountName(root, file) {
  const relative = path.relative(path.join(root, 'accounts'), file).split(path.sep);
  return relative[0] && relative[0] !== '..' ? relative[0] : 'unknown';
}
function walkSessions(root, limit = 1000) {
  const files = [];
  let accounts = [];
  try { accounts = fs.readdirSync(path.join(root, 'accounts'), {withFileTypes:true}).filter(entry => entry.isDirectory()); } catch { return files; }
  for (const account of accounts) {
    const start = path.join(root, 'accounts', account.name, 'sessions'), stack = [start];
    while (stack.length) {
      const dir = stack.pop(); let entries;
      try { entries = fs.readdirSync(dir, {withFileTypes:true}); } catch { continue; }
      for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) stack.push(full);
        else if (entry.isFile() && /^rollout-.*\.jsonl$/i.test(entry.name)) {
          try { const stat = fs.statSync(full); files.push({id:idFor(full), file:full, account:account.name, size:stat.size, updatedAt:stat.mtime.toISOString(), mtime:stat.mtimeMs}); } catch { }
        }
      }
    }
  }
  // Rank globally: stopping inside the first account hides newer sessions
  // in every later account once that first account reaches the limit.
  files.sort((a,b) => b.mtime - a.mtime || a.file.localeCompare(b.file));
  const selected=files.slice(0,limit);
  selected.available=files.length;
  return selected;
}
async function walkSessionsAsync(root, limit = 1000) {
  const files=[];
  let accounts;
  try { accounts=(await fsp.readdir(path.join(root,'accounts'),{withFileTypes:true})).filter(entry=>entry.isDirectory()); }
  catch { return Object.assign(files,{available:0}); }
  await mapLimit(accounts,8,async account=>{
    const stack=[path.join(root,'accounts',account.name,'sessions')];
    while(stack.length){
      const dir=stack.pop();
      let entries;
      try { entries=await fsp.readdir(dir,{withFileTypes:true}); } catch { continue; }
      const rollouts=[];
      for(const entry of entries){
        const full=path.join(dir,entry.name);
        if(entry.isDirectory())stack.push(full);
        else if(entry.isFile() && /^rollout-.*\.jsonl$/i.test(entry.name))rollouts.push(full);
      }
      await mapLimit(rollouts,32,async full=>{
        try { const stat=await fsp.stat(full);files.push({id:idFor(full),file:full,account:account.name,size:stat.size,updatedAt:stat.mtime.toISOString(),mtime:stat.mtimeMs}); } catch { }
      });
    }
  });
  files.sort((a,b)=>b.mtime-a.mtime || a.file.localeCompare(b.file));
  const selected=files.slice(0,limit);
  selected.available=files.length;
  return selected;
}
function textOf(value) {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  if (typeof value.text === 'string') return value.text;
  if (typeof value.output === 'string') return value.output;
  if (typeof value.content === 'string') return value.content;
  if (Array.isArray(value.content)) return value.content.map(textOf).filter(Boolean).join('\n');
  return '';
}
function payloadOf(row) { return row?.payload?.item || row?.payload || {}; }
function usageOf(row, payload = payloadOf(row)) {
  if (row?.type !== 'token_usage_record' && !(row?.type === 'event_msg' && payload?.type === 'token_count')) return null;
  const usage=payload.info?.total_token_usage || payload.total_token_usage || payload.info?.last_token_usage || payload;
  return usage && typeof usage === 'object' ? usage : null;
}
function normalize(row, line) {
  const payload = payloadOf(row), base = {line, at:row.timestamp || payload.timestamp || null, kind:row.type || 'event', title:row.type || 'Event', text:'', meta:{}};
  if (row.type === 'session_meta') {
    base.kind='session'; base.title='Session started'; base.text=payload.cwd || payload.id || '';
    base.meta={id:payload.id, cwd:payload.cwd, source:payload.source, model:payload.model};
  } else if (row.type === 'response_item') {
    base.kind=payload.type || 'response'; base.title=payload.type === 'message' ? `${payload.role || 'assistant'} message` : payload.name || payload.type || 'Response item';
    base.text=textOf(payload);
    if (!base.text && payload.type && /call/.test(payload.type)) base.text=typeof payload.arguments === 'string' ? payload.arguments : typeof payload.input === 'string' ? payload.input : '';
    base.meta={role:payload.role, name:payload.name, callId:payload.call_id || payload.callId};
  } else if (usageOf(row,payload)) {
    const usage=usageOf(row,payload);
    base.kind='tokens'; base.title='Token usage'; base.meta=usage;
    base.text=`${Number(usage.input_tokens || 0).toLocaleString()} in · ${Number(usage.output_tokens || 0).toLocaleString()} out · ${Number(usage.cached_input_tokens || 0).toLocaleString()} cached`;
  } else if (row.type === 'event_msg') {
    base.kind=payload.type || 'event'; base.title=(payload.type || 'event').replace(/_/g,' '); base.text=textOf(payload.message || payload);
  } else if (row.type === 'compacted') {
    base.kind='compaction'; base.title='Context compacted'; base.text=textOf(payload);
  } else if (row.type === 'turn_context') {
    base.kind='turn'; base.title='Turn context'; base.text=payload.cwd || payload.model || ''; base.meta={cwd:payload.cwd, model:payload.model, effort:payload.effort};
  } else if (row.type === 'world_state') {
    base.kind='state'; base.title='World state'; base.text='Environment snapshot retained in the transcript';
  } else base.text=textOf(payload);
  if (base.text.length > 200000) { base.text=base.text.slice(0,200000); base.truncated=true; }
  return base;
}
async function scanSession(session) {
  const key=`${session.file}:${session.size}:${session.mtime}`;
  if (cache.has(key)) return cache.get(key);
  const summary={...session,title:path.basename(session.file,'.jsonl'),cwd:'',model:'',source:'',turns:0,messages:0,toolCalls:0,compactions:0,
    usage:{input:0,cached:0,output:0,reasoning:0,total:0,exact:false},tools:{},commands:{},paths:{},largest:[]};
  const stream=fs.createReadStream(session.file,{encoding:'utf8'}), lines=readline.createInterface({input:stream,crlfDelay:Infinity});
  for await (const line of lines) {
    let row; try { row=JSON.parse(line); } catch { continue; }
    const payload=payloadOf(row);
    if (row.type === 'session_meta') {
      summary.cwd=payload.cwd || summary.cwd; summary.model=payload.model || summary.model; summary.source=typeof payload.source === 'string' ? payload.source : payload.source?.subagent ? 'subagent' : summary.source;
    }
    if (row.type === 'event_msg' && ['task_started','user_message'].includes(payload.type)) summary.turns++;
    if (row.type === 'response_item' && payload.type === 'message') {
      summary.messages++;
      if (!summary.userPreview && payload.role === 'user') summary.userPreview=textOf(payload).replace(/\s+/g,' ').slice(0,120);
    }
    if (row.type === 'response_item' && payload.type && /call/.test(payload.type) && !/output/.test(payload.type)) {
      summary.toolCalls++; const tool=payload.name || payload.type; summary.tools[tool]=(summary.tools[tool] || 0)+1;
      const input=typeof payload.arguments === 'string' ? payload.arguments : typeof payload.input === 'string' ? payload.input : '';
      if (input) { const command=input.replace(/\s+/g,' ').slice(0,260); summary.commands[command]=(summary.commands[command] || 0)+1; }
    }
    if (row.type === 'response_item' && /output/.test(payload.type || '')) {
      const output=textOf(payload), size=output.length;
      if (size) summary.largest.push({tool:payload.name || payload.type,chars:size,preview:output.replace(/\s+/g,' ').slice(0,100)});
    }
    if (row.type === 'compacted') summary.compactions++;
    const usage=usageOf(row,payload);
    if (usage) {
      const total=Number(usage.total_tokens || 0);
      if (total >= summary.usage.total) summary.usage={input:Number(usage.input_tokens || 0),cached:Number(usage.cached_input_tokens || 0),output:Number(usage.output_tokens || 0),reasoning:Number(usage.reasoning_output_tokens || 0),total,exact:true};
    }
    const source=line.length < 500000 ? line : '';
    for (const match of source.matchAll(/(?:[A-Za-z]:\\|\.{0,2}\/)[^\s"'<>|]{3,180}/g)) {
      const found=match[0].replace(/[),.;:]+$/,''); summary.paths[found]=(summary.paths[found] || 0)+1;
    }
  }
  summary.title=summary.userPreview || (summary.cwd ? path.basename(summary.cwd) : summary.title);
  summary.largest=summary.largest.sort((a,b)=>b.chars-a.chars).slice(0,8);
  cache.set(key,summary);
  if (cache.size > 1200) cache.delete(cache.keys().next().value);
  return summary;
}
function liveMarkers(root) {
  const result=[]; let files=[];
  try { files=fs.readdirSync(path.join(root,'deck','sessions')).filter(name=>name.endsWith('.json')); } catch { return result; }
  for (const name of files) try {
    const file=path.join(root,'deck','sessions',name), entry=readJson(file);
    if (!Number.isInteger(entry.ProcessId)) continue;
    try { process.kill(entry.ProcessId,0); } catch { continue; }
    result.push({id:idFor(file),file,account:entry.Account,folder:entry.Folder,startedAt:entry.StartedAt,context:Boolean(entry.ContextUrl)});
  } catch { }
  return result.sort((a,b)=>Date.parse(b.startedAt||0)-Date.parse(a.startedAt||0));
}
function markerById(root,id) { return liveMarkers(root).find(marker=>marker.id===id); }
function publicMarker({file,...marker}) { return marker; }
async function timelineChunk(session, cursor=0) {
  const handle=await fsp.open(session.file,'r');
  try {
    const stat=await handle.stat(); if(cursor<0 || cursor>stat.size) cursor=0;
    const length=Math.min(MAX_CHUNK,stat.size-cursor), buffer=Buffer.alloc(length);
    const read=length ? (await handle.read(buffer,0,length,cursor)).bytesRead : 0;
    let text=buffer.subarray(0,read).toString('utf8'), consumed=read;
    if(text && !text.endsWith('\n')){const cut=text.lastIndexOf('\n');if(cut>=0){consumed=Buffer.byteLength(text.slice(0,cut+1));text=text.slice(0,cut+1);}else{consumed=0;text='';}}
    const items=[]; let lineNumber=0;
    for(const line of text.split(/\r?\n/)){if(!line)continue;lineNumber++;try{items.push(normalize(JSON.parse(line),lineNumber));}catch{}}
    return {items,next:cursor+consumed,done:cursor+consumed>=stat.size,size:stat.size};
  } finally { await handle.close(); }
}
async function efficiency(root, limit, index) {
  const sessions=index ? index.slice(0,limit) : await walkSessionsAsync(root,limit);
  if(index)sessions.available=index.available;
  const summaries=await mapLimit(sessions,6,scanSession);
  const totals={sessions:summaries.length,input:0,cached:0,output:0,total:0,toolCalls:0,compactions:0,exactSessions:0};
  const tools={},commands={},paths={},accounts={},projects={},models={}; const largest=[];
  for(const item of summaries){totals.input+=item.usage.input;totals.cached+=item.usage.cached;totals.output+=item.usage.output;totals.total+=item.usage.total;totals.toolCalls+=item.toolCalls;totals.compactions+=item.compactions;if(item.usage.exact)totals.exactSessions++;
    accounts[item.account]=(accounts[item.account]||0)+item.usage.total; projects[item.cwd||'Unknown']=(projects[item.cwd||'Unknown']||0)+item.usage.total; models[item.model||'Unknown']=(models[item.model||'Unknown']||0)+item.usage.total;
    for(const [key,value] of Object.entries(item.tools))tools[key]=(tools[key]||0)+value;for(const [key,value] of Object.entries(item.commands))commands[key]=(commands[key]||0)+value;for(const [key,value] of Object.entries(item.paths))paths[key]=(paths[key]||0)+value;largest.push(...item.largest.map(value=>({...value,account:item.account,title:item.title})));
  }
  const ranked=obj=>Object.entries(obj).map(([name,value])=>({name,value})).sort((a,b)=>b.value-a.value).slice(0,20);
  const recommendations=[];
  const repeats=ranked(commands).filter(value=>value.value>1); if(repeats.length) recommendations.push({title:'Repeated shell work',detail:`${repeats.length} command patterns recur. Cache or consolidate the top repeats.`});
  const pathRepeats=ranked(paths).filter(value=>value.value>4); if(pathRepeats.length) recommendations.push({title:'Repeated file discovery',detail:`${pathRepeats.length} paths are repeatedly surfaced. A project index may reduce rediscovery.`});
  if(largest.some(value=>value.chars>50000)) recommendations.push({title:'Large tool output',detail:'At least one tool result exceeds 50k characters. Filter or summarize it before model ingestion.'});
  if(totals.input && totals.cached/totals.input<.2) recommendations.push({title:'Low cache reuse',detail:'Cached input is below 20% of input tokens across exact sessions. Stable prefixes may help.'});
  if(!recommendations.length) recommendations.push({title:'No dominant waste pattern',detail:'The indexed sessions do not show a strong repeat or oversized-output bottleneck.'});
  return {generatedAt:new Date().toISOString(),limit,availableSessions:sessions.available,limitReached:sessions.available>=limit,totals,tools:ranked(tools),commands:repeats.slice(0,12),paths:pathRepeats.slice(0,12),accounts:ranked(accounts),projects:ranked(projects),models:ranked(models),largest:largest.sort((a,b)=>b.chars-a.chars).slice(0,15),recommendations,sessions:summaries.map(({file,commands,paths,tools,largest,...item})=>item)};
}
function sendJson(res,status,value){if(res.destroyed)return;if(res.headersSent){res.destroy();return;}res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(JSON.stringify(value));}
function error(res,status,message){sendJson(res,status,{error:message});}
async function proxyContext(root,id,req,res,since){
  const marker=markerById(root,id); if(!marker || !marker.context)return error(res,404,'The live context route is unavailable.');
  const entry=readJson(marker.file), target=new URL(entry.ContextUrl);
  if(target.hostname!=='127.0.0.1' || !/^\/[a-f0-9]{64}\/_deck\/context$/.test(target.pathname))return error(res,409,'The stored context route is invalid.');
  if(req.method==='GET'&&/^\d+$/.test(String(since||'')))target.searchParams.set('since',String(since));
  let body=Buffer.alloc(0); if(req.method==='POST'){const parts=[];let size=0;for await(const part of req){size+=part.length;if(size>65536)return error(res,413,'Context action is too large.');parts.push(part);}body=Buffer.concat(parts);}
  await new Promise(resolve=>{const upstream=http.request(target,{method:req.method,headers:{'content-type':'application/json','content-length':body.length}},incoming=>{if(res.destroyed){incoming.destroy();return resolve();}res.writeHead(incoming.statusCode,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});incoming.pipe(res);incoming.on('end',resolve);});upstream.on('error',()=>{error(res,502,'The conversation proxy is no longer available.');resolve();});upstream.end(body);});
}
function contextPage(nonce){return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Codex Deck · Live Context</title><style nonce="${nonce}">
:root{color-scheme:dark;--bg:#080b0c;--surface:#101516;--raised:#151c1d;--line:#273234;--text:#edf5f3;--muted:#849491;--mint:#75e2bd;--blue:#7fb8ff;--red:#ff7f8a;--amber:#f2c66f}*{box-sizing:border-box}html,body{height:100%}body{margin:0;background:var(--bg);color:var(--text);font:13px/1.4 Inter,Segoe UI,sans-serif;overflow:hidden}button,input,select,textarea{font:inherit}.frame{height:100%;display:grid;grid-template-rows:auto auto auto minmax(0,1fr) auto}.top{height:50px;display:flex;align-items:center;padding:0 14px;border-bottom:1px solid var(--line);background:#0b0f10}.brand{font-size:13px;font-weight:800;letter-spacing:.8px}.brand b{color:var(--mint)}.live{display:flex;align-items:center;gap:6px;margin-left:12px;color:var(--muted);font-size:11px}.dot{width:7px;height:7px;border-radius:50%;background:var(--mint);box-shadow:0 0 10px #75e2bd80}.dot.busy{background:var(--amber);box-shadow:0 0 10px #f2c66f80}.studio{margin-left:auto;color:var(--muted);text-decoration:none;border:1px solid var(--line);border-radius:7px;padding:5px 8px}.studio:hover{color:var(--mint);border-color:#3b5c53}.summary{padding:12px 14px 10px;background:linear-gradient(135deg,#101817,#0d1213);border-bottom:1px solid var(--line)}.identity{display:flex;align-items:baseline;gap:8px}.identity strong{font-size:14px}.identity span{color:var(--muted);font-size:10px;margin-left:auto}.meter{height:4px;background:#222c2e;border-radius:4px;overflow:hidden;margin:9px 0}.meter i{display:block;height:100%;background:linear-gradient(90deg,var(--mint),var(--blue));width:0}.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}.stat{min-width:0;text-align:center}.stat b{display:block;font-size:16px;color:var(--mint);font-variant-numeric:tabular-nums}.stat small{color:var(--muted);font-size:9px;text-transform:uppercase;letter-spacing:.6px}.signals{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px 12px;margin-top:9px;padding-top:7px;border-top:1px solid #253433}.signal{display:flex;align-items:baseline;justify-content:space-between;gap:6px;min-width:0;font-size:10px}.signal small{color:var(--muted);white-space:nowrap}.signal b{font-size:10px;font-weight:600;color:#c7e6dd;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}.tools{display:grid;grid-template-columns:minmax(0,1fr) 106px auto;gap:7px;padding:9px 10px;border-bottom:1px solid var(--line);background:#0b0f10}.search,.filter{width:100%;min-width:0;background:#111718;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:7px 9px;outline:none}.search:focus,.filter:focus{border-color:#4e7d70}.tool{border:1px solid var(--line);background:#13191a;color:var(--muted);border-radius:8px;padding:7px 9px;cursor:pointer}.tool:hover,.tool.on{color:var(--mint);border-color:#3c6258}.list{overflow:auto;padding:8px 9px 18px;scrollbar-width:thin;scrollbar-color:#354244 transparent}.item{display:grid;grid-template-columns:36px minmax(0,1fr) 25px;gap:9px;align-items:start;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:10px;margin:6px 0;content-visibility:auto;contain-intrinsic-size:94px}.item.suppressed{opacity:.6;border-color:#63383e;background:#171113}.item.edited{border-color:#315a50}.remove{width:25px;height:25px;border-radius:50%;border:1px solid #653941;background:#28181b;color:var(--red);font-size:16px;font-weight:800;line-height:20px;cursor:pointer}.remove.restore{color:var(--mint);background:#13241f;border-color:#315a50}.remove:disabled{opacity:.25;cursor:not-allowed}.meta{display:flex;gap:5px;align-items:center;flex-wrap:wrap;color:var(--blue);font-size:10px;text-transform:uppercase;letter-spacing:.45px}.chip{color:var(--muted);border:1px solid var(--line);border-radius:999px;padding:1px 5px;text-transform:none;letter-spacing:0}.tokens{margin-left:auto;color:var(--muted);font-variant-numeric:tabular-nums}.preview{white-space:pre-wrap;word-break:break-word;margin:6px 0 0;color:#cbd7d4;font:11px/1.45 Cascadia Mono,Consolas,monospace;max-height:5.8em;overflow:hidden}.item.open .preview{max-height:none}.actions{display:flex;flex-direction:column;gap:5px}.mini{border:1px solid var(--line);background:#151c1d;color:var(--muted);border-radius:7px;padding:5px 7px;cursor:pointer;font-size:10px}.mini:hover{color:var(--text)}.empty{padding:50px 20px;color:var(--muted);text-align:center}.foot{display:flex;align-items:center;gap:8px;min-height:32px;padding:6px 11px;border-top:1px solid var(--line);background:#0b0f10;color:var(--muted);font-size:10px}.follow{display:flex;align-items:center;gap:4px;margin-left:auto;white-space:nowrap;cursor:pointer}.follow input{accent-color:var(--mint);margin:0}.foot button{border:0;background:transparent;color:var(--muted);cursor:pointer}.foot button:hover{color:var(--mint)}dialog{width:min(440px,calc(100vw - 22px));max-height:calc(100vh - 30px);background:#101617;color:var(--text);border:1px solid var(--line);border-radius:13px;padding:14px;box-shadow:0 18px 70px #000c}dialog::backdrop{background:#0009}dialog h3{margin:0 0 4px}dialog p{margin:0 0 10px;color:var(--muted);font-size:11px}textarea{width:100%;height:min(52vh,440px);resize:vertical;background:#080c0d;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:10px;font:11px/1.45 Cascadia Mono,Consolas,monospace;outline:none}.dialog-actions{display:flex;justify-content:flex-end;gap:7px;margin-top:9px}.primary{color:#07100e;background:var(--mint);border-color:var(--mint)}.error{color:var(--red)}@media(max-width:380px){.tools{grid-template-columns:1fr 96px}.tools .tool{display:none}.item{grid-template-columns:34px minmax(0,1fr) 25px;gap:5px}.actions{grid-column:1;flex-direction:column}.top{padding:0 10px}.summary{padding-left:10px;padding-right:10px}}
</style></head><body><div class="frame"><header class="top"><div class="brand">CODEX <b>DECK</b></div><div class="live"><i class="dot" id="dot"></i><span id="status">Connecting</span></div><a class="studio" href="trajectory" title="Open the full trajectory workspace">Full studio ↗</a></header><section class="summary"><div class="identity"><strong id="account">Live context</strong><span id="updated">Waiting for first request</span></div><div class="meter"><i id="meter"></i></div><div class="stats"><div class="stat"><b id="raw">—</b><small>Raw tokens</small></div><div class="stat"><b id="effective">—</b><small>Next request</small></div><div class="stat"><b id="saved">—</b><small>Saved</small></div></div><div class="signals" aria-label="Current session status"><span class="signal"><small id="primaryLabel">Primary quota</small><b id="primary">—</b></span><span class="signal"><small id="secondaryLabel">Secondary quota</small><b id="secondary">—</b></span><span class="signal"><small>Context free ≈</small><b id="contextFree">—</b></span><span class="signal"><small>Auto-compact</small><b id="compact">—</b></span></div></section><section class="tools"><input id="search" class="search" autocomplete="off" placeholder="Filter context…"><select id="filter" class="filter"><option value="all">All items</option><option value="active">Active</option><option value="changed">Changed</option><option value="editable">Editable</option><option value="protected">Protected</option></select><button id="largest" class="tool" title="Sort largest items first">Size ↓</button></section><main id="list" class="list"><div class="empty">Connecting to this conversation…</div></main><footer class="foot"><span id="foot">Changes affect the next model request only.</span><label class="follow" title="Scroll to each new context item"><input id="follow" type="checkbox" checked>Follow new</label><button id="restore">Restore all</button></footer></div><dialog id="editor"><h3>Edit model-visible content</h3><p>Raw history stays intact. This replacement is used on the next request.</p><textarea id="editText"></textarea><div class="dialog-actions"><button id="cancel" class="mini">Cancel</button><button id="save" class="mini primary">Save replacement</button></div></dialog><script nonce="${nonce}">
'use strict';const q=s=>document.querySelector(s),fmt=n=>Number(n||0).toLocaleString(),live=new URLSearchParams(location.search).get('live');let state=null,revision=-1,working=false,largest=false,editing=null,items=new Map(),renderedEnd=null;let followNew=true;try{followNew=localStorage.getItem("deck.context.follow")!=="false"}catch{}q("#follow").checked=followNew;
async function api(url,options){const response=await fetch(url,options),data=await response.json();if(!response.ok)throw Error(data.error||'Request failed');return data}
function busy(value){q('#dot').classList.toggle('busy',value);q('#status').textContent=value?'Model working':'Live'}
function node(name,className,text){const value=document.createElement(name);if(className)value.className=className;if(text!=null)value.textContent=text;return value}
function ruleMap(){return new Map((state?.rules||[]).map(value=>[value.key,value]))}
function renderSessionStatus(){
  const session=state?.session||{},quota=session.quota||{},windows=quota.windows||[];
  for(const [index,labelId,valueId] of [[0,'#primaryLabel','#primary'],[1,'#secondaryLabel','#secondary']]){
    const window=windows[index];q(labelId).textContent=(index?'Secondary':'Primary')+(window?.label?' · '+window.label:'')+' quota';
    q(valueId).textContent=window?.usedPercent!=null?Math.round(window.usedPercent)+'% used':'—';
    q(valueId).title=window?.resetsAtUnix?'Resets '+new Date(window.resetsAtUnix*1000).toLocaleString():(quota.checkedAt?'Checked '+new Date(quota.checkedAt).toLocaleString():'Usage unavailable');
  }
  const capacity=Number(session.contextWindow||0),estimated=Number(state?.effectiveTokens||0);
  q('#contextFree').textContent=capacity&&state?.capturedAt?Math.max(0,Math.round(100-estimated/capacity*100))+'%':'—';
  q('#contextFree').title=capacity?'Estimated from model-visible input only · '+fmt(estimated)+' / '+fmt(capacity)+' tokens · '+(session.model||'unknown model'):'Model context capacity unavailable';
  const compact=session.autoCompact||{};
  q('#compact').textContent=compact.enabled?(compact.mode+' · '+compact.freePercent+'% free'):'Off';
  q('#compact').title=compact.enabled?'Auto-compact begins near '+compact.freePercent+'% context free':'Auto-compact is off for this terminal';
}
function render(){if(!state)return;const rules=ruleMap(),search=q('#search').value.trim().toLowerCase(),filter=q('#filter').value,scroll=q('#list').scrollTop;items=new Map((state.raw||[]).map(value=>[value.key,value]));q('#account').textContent=(state.account||'Conversation')+' · effective context';q('#updated').textContent=state.capturedAt?'Updated '+new Date(state.capturedAt).toLocaleTimeString():'Waiting for first request';q('#raw').textContent=fmt(state.rawTokens);q('#effective').textContent=fmt(state.effectiveTokens);q('#saved').textContent=fmt(state.savedTokens);q('#meter').style.width=(state.rawTokens?Math.min(100,state.effectiveTokens/state.rawTokens*100):0)+'%';renderSessionStatus();busy(Boolean(state.busy));let values=[...(state.raw||[])];if(largest)values.sort((a,b)=>b.tokens-a.tokens||a.index-b.index);values=values.filter(item=>{const rule=rules.get(item.key),changed=Boolean(rule),hay=(item.role+' '+item.type+' '+(item.name||'')+' '+(item.preview||'')).toLowerCase();if(search&&!hay.includes(search))return false;if(filter==='active'&&rule?.action==='suppress')return false;if(filter==='changed'&&!changed)return false;if(filter==='editable'&&!item.editable)return false;if(filter==='protected'&&!item.protected)return false;return true});const fragment=document.createDocumentFragment();for(const item of values){const rule=rules.get(item.key),suppressed=rule?.action==='suppress',edited=rule?.action==='edit',card=node('article','item'+(suppressed?' suppressed':'')+(edited?' edited':''));card.dataset.key=item.key;const remove=node('button','remove'+(suppressed?' restore':''),suppressed?'↶':'−');remove.dataset.action=suppressed?'restore':'suppress';remove.dataset.key=item.key;remove.title=suppressed?'Restore this item':'Suppress this item from the next request'+(item.callId?' with its paired tool item':'');remove.disabled=item.protected&&!state.protectedChanges;const body=node('div'),meta=node('div','meta');meta.append(node('span','',item.role||item.type||'item'));if(item.name)meta.append(node('span','chip',item.name));if(item.callId)meta.append(node('span','chip','paired'));if(item.protected)meta.append(node('span','chip','protected'));if(edited)meta.append(node('span','chip','edited'));if(suppressed)meta.append(node('span','chip','suppressed'));meta.append(node('span','tokens',fmt(item.tokens)+' tok'));const preview=node('pre','preview',edited?(rule.text||''):(item.preview||'(opaque / no displayable text)'));preview.title='Click to expand or collapse';preview.dataset.action='expand';body.append(meta,preview);const actions=node('div','actions');if(item.editable&&(!item.protected||state.protectedChanges)){const edit=node('button','mini','Edit');edit.dataset.action='edit';edit.dataset.key=item.key;actions.append(edit)}card.append(actions,body,remove);fragment.append(card)}const list=q('#list');list.replaceChildren(fragment);if(!values.length)list.append(node('div','empty',state.raw?.length?'No items match this view.':'Waiting for the first model request…'));const end=state.threadId+'|'+(state.raw?.length||0)+'|'+(state.raw?.at(-1)?.key||'');if(followNew&&end!==renderedEnd)list.scrollTop=list.scrollHeight;else list.scrollTop=scroll;renderedEnd=end;q('#foot').textContent=values.length+' / '+(state.raw?.length||0)+' items · overlays are reversible';q('#foot').classList.remove('error');q('#restore').disabled=!state.rules?.length}
async function refresh(force=false){if(working||!live)return;working=true;try{const suffix=!force&&revision>=0?'&since='+revision:'';const next=await api('api/context?id='+encodeURIComponent(live)+suffix);if(next.unchanged){busy(Boolean(next.busy));if(state){state.account=next.account||state.account;state.session=next.session||state.session;q('#account').textContent=state.account+' · effective context';renderSessionStatus()}return}state=next;revision=Number(next.revision||0);render()}catch(error){q('#status').textContent='Disconnected';q('#dot').classList.remove('busy');q('#foot').textContent=error.message;q('#foot').classList.add('error')}finally{working=false}}
async function act(action,key,text){try{await api('api/context?id='+encodeURIComponent(live),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,key,text})});await refresh(true)}catch(error){q('#foot').textContent=error.message;q('#foot').classList.add('error')}}
q('#list').onclick=event=>{const target=event.target.closest('[data-action]');if(!target)return;const action=target.dataset.action,key=target.dataset.key;if(action==='expand'){target.closest('.item').classList.toggle('open');return}if(action==='edit'){const item=items.get(key),rule=ruleMap().get(key);editing=key;q('#editText').value=rule?.action==='edit'?rule.text:(item?.text||'');q('#editor').showModal();q('#editText').focus();return}act(action,key)};q('#search').oninput=render;q('#filter').onchange=render;q('#largest').onclick=()=>{largest=!largest;q('#largest').classList.toggle('on',largest);render()};q('#follow').onchange=()=>{followNew=q('#follow').checked;try{localStorage.setItem('deck.context.follow',String(followNew))}catch{}if(followNew)q('#list').scrollTop=q('#list').scrollHeight};q('#restore').onclick=()=>act('clear');q('#cancel').onclick=()=>q('#editor').close();q('#save').onclick=async()=>{const text=q('#editText').value;q('#editor').close();await act('edit',editing,text)};document.addEventListener('keydown',event=>{if(event.ctrlKey&&event.key.toLowerCase()==='f'){event.preventDefault();q('#search').focus();q('#search').select()}});if(!/^[a-f0-9]{24}$/.test(live||'')){q('#list').replaceChildren(node('div','empty','This companion link is invalid.'));q('#status').textContent='Unavailable'}else{const presence='api/context/presence?id='+encodeURIComponent(live);const heartbeat=()=>fetch(presence,{method:'POST'}).catch(()=>{});heartbeat();setInterval(heartbeat,2000);addEventListener('pagehide',()=>navigator.sendBeacon(presence+'&close=1'));refresh(true);setInterval(()=>refresh(false),700)}
</script></body></html>`}
function page(mode,nonce){return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Codex Deck · ${mode==='trajectory'?'Trajectory':'Efficiency'}</title><style nonce="${nonce}">
:root{color-scheme:dark;--bg:#090d0f;--panel:#111719;--line:#253136;--text:#e8f1f0;--muted:#8a9a9e;--mint:#82e6c5;--blue:#82b9ff;--red:#ff7e87;--amber:#f4c978}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% -10%,#17332e 0,transparent 32%),var(--bg);color:var(--text);font:14px/1.45 Inter,Segoe UI,sans-serif}button,input,textarea{font:inherit}.top{height:64px;display:flex;align-items:center;padding:0 22px;border-bottom:1px solid var(--line);gap:18px;position:sticky;top:0;background:#090d0fee;backdrop-filter:blur(16px);z-index:4}.brand{font-size:18px;font-weight:700;letter-spacing:.2px}.brand b{color:var(--mint)}.switch{display:flex;background:#101719;border:1px solid var(--line);border-radius:10px;padding:3px}.switch a{color:var(--muted);padding:7px 12px;text-decoration:none;border-radius:7px}.switch a.on{background:#21302e;color:var(--mint)}.hint{margin-left:auto;color:var(--muted);font-size:12px}.shell{display:grid;grid-template-columns:310px minmax(0,1fr);height:calc(100vh - 64px)}aside{border-right:1px solid var(--line);overflow:auto;padding:16px}.search{width:100%;background:#0d1214;border:1px solid var(--line);color:var(--text);border-radius:9px;padding:10px 12px;margin-bottom:12px}.session{width:100%;text-align:left;background:transparent;border:1px solid transparent;color:var(--text);padding:11px;border-radius:10px;margin:2px 0;cursor:pointer}.session:hover,.session.on{background:#141e20;border-color:#293a3c}.session strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.session small,.muted{color:var(--muted)}main{overflow:auto;padding:22px}.hero{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:18px}.metric{background:linear-gradient(145deg,#141c1e,#0f1517);border:1px solid var(--line);border-radius:13px;padding:14px 16px;min-width:150px}.metric b{display:block;font-size:23px;color:var(--mint)}.toolbar{display:flex;gap:8px;align-items:center;margin-bottom:16px}.pill,.danger{border:1px solid var(--line);background:#151d20;color:var(--text);padding:8px 11px;border-radius:8px;cursor:pointer}.danger{color:var(--red);border-color:#593238}.event,.analysis{background:#101719;border:1px solid var(--line);border-radius:12px;margin:9px 0;padding:13px 15px}.event .head{display:flex;gap:8px;align-items:center}.event .kind{color:var(--mint);font-size:11px;text-transform:uppercase;letter-spacing:.8px}.event time{margin-left:auto;color:var(--muted);font-size:11px}.event pre{white-space:pre-wrap;word-break:break-word;max-height:360px;overflow:auto;color:#cdd8d7;margin:9px 0 0;font:12px/1.5 Cascadia Mono,Consolas,monospace}.context-item{display:grid;grid-template-columns:auto 1fr auto;gap:12px;align-items:start}.minus{width:26px;height:26px;border-radius:50%;border:1px solid #63343b;background:#26171a;color:var(--red);font-weight:800;cursor:pointer}.tag{font-size:11px;color:var(--blue)}.actions{display:flex;gap:6px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:14px}.analysis h3{margin:0 0 10px}.bar{height:6px;background:#20292c;border-radius:4px;overflow:hidden}.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--mint),var(--blue))}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;margin:10px 0}.empty{padding:50px 10px;text-align:center;color:var(--muted)}dialog{background:#111719;color:var(--text);border:1px solid var(--line);border-radius:14px;width:min(720px,90vw)}textarea{width:100%;min-height:220px;background:#090d0f;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:12px}@media(max-width:800px){.shell{grid-template-columns:1fr}aside{display:none}.hint{display:none}main{padding:14px}}
</style></head><body><header class="top"><div class="brand">CODEX <b>DECK</b></div><nav class="switch"><a href="trajectory" class="${mode==='trajectory'?'on':''}">Trajectory + Context</a><a href="efficiency" class="${mode==='efficiency'?'on':''}">Efficiency Analytics</a></nav><span class="hint">Local only · raw rollouts stay on this machine</span></header><div class="shell"><aside><input id="search" class="search" placeholder="Filter sessions"><div id="sessions"></div></aside><main><div id="app" class="empty">Loading local index…</div></main></div><dialog id="editor"><h3>Edit model-visible projection</h3><p class="muted">Raw history is retained. This replacement applies to the next request.</p><textarea id="editText"></textarea><div class="toolbar"><button id="saveEdit" class="pill">Save overlay</button><button id="cancelEdit" class="pill">Cancel</button></div></dialog><script nonce="${nonce}">
const MODE=${JSON.stringify(mode)},$=s=>document.querySelector(s),el=(n,c,t)=>{const x=document.createElement(n);if(c)x.className=c;if(t!=null)x.textContent=t;return x},fmt=n=>Number(n||0).toLocaleString(),api=async(url,options)=>{const r=await fetch(url,options);const j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j};let sessions=[],selected=null,editorKey=null,activeView=null,contextSignature='';
function metrics(values){const h=el('div','hero');for(const [label,value]of values){const c=el('div','metric');c.append(el('b','',value),el('span','muted',label));h.append(c)}return h}
function renderSessions(){const q=$('#search').value.toLowerCase(),box=$('#sessions'),fragment=document.createDocumentFragment();for(const s of sessions.filter(x=>(x.title+' '+x.account+' '+(x.cwd||'')).toLowerCase().includes(q))){const b=el('button','session'+(selected===s.id?' on':''));b.append(el('strong','',s.title),el('small','',s.account+' · '+new Date(s.updatedAt).toLocaleString()));b.onclick=()=>loadTimeline(s);fragment.append(b)}box.replaceChildren(fragment)}
let sessionListRefreshing=false;
async function refreshSessionList(){if(MODE!=='trajectory'||!activeView||activeView.kind==='awaiting'||sessionListRefreshing)return;sessionListRefreshing=true;try{const data=await api('api/sessions');sessions=data.sessions;renderSessions()}catch{}finally{sessionListRefreshing=false}}
async function loadTrajectory(){const data=await api('api/sessions');sessions=data.sessions;renderSessions();const managed=data.live.filter(x=>x.context);if(managed.length){await loadContext(managed[0]);return}if(data.live.length){const live=data.live[0],current=sessions.find(s=>s.account===live.account&&Date.parse(s.updatedAt)>=Date.parse(live.startedAt)-2000);if(current){await loadTimeline(current);return}activeView={kind:'awaiting',live};$('#app').replaceChildren(el('div','empty','Waiting for this conversation’s rollout…'));return}if(sessions[0]){await loadTimeline(sessions[0]);return}activeView={kind:'empty'};$('#app').replaceChildren(el('div','empty','No local Codex sessions are available yet.'))}
async function refreshAwaiting(view){if(view.busy||activeView!==view)return;view.busy=true;try{const data=await api('api/sessions');if(activeView!==view)return;sessions=data.sessions;renderSessions();const current=sessions.find(s=>s.account===view.live.account&&Date.parse(s.updatedAt)>=Date.parse(view.live.startedAt)-2000);if(current)await loadTimeline(current)}finally{view.busy=false}}
function appendTimeline(stream,items){for(const item of items){const card=el('article','event'),head=el('div','head');head.append(el('span','kind',item.kind),el('strong','',item.title));if(item.at)head.append(el('time','',new Date(item.at).toLocaleString()));card.append(head);if(item.text)card.append(el('pre','',item.text));stream.append(card)}}
async function pollTimeline(view){if(view.busy||activeView!==view)return;view.busy=true;try{for(let pages=0;pages<12&&activeView===view;pages++){const data=await api('api/timeline?id='+encodeURIComponent(view.session.id)+'&cursor='+view.cursor);if(activeView!==view)return;appendTimeline(view.stream,data.items);view.cursor=data.next;if(data.done)break;await new Promise(r=>requestAnimationFrame(r))}}finally{view.busy=false}}
async function loadTimeline(session){selected=session.id;contextSignature='';renderSessions();const app=$('#app'),view={kind:'timeline',session,cursor:0,stream:el('div'),busy:false};activeView=view;app.replaceChildren(metrics([['Account',session.account],['Turns',fmt(session.turns)],['Tools',fmt(session.toolCalls)],['Tokens',session.usage.exact?fmt(session.usage.total):'—'],['Compactions',fmt(session.compactions)]]));const bar=el('div','toolbar');bar.append(el('span','muted',session.cwd||session.fileName));if(session.live&&session.live.context){const b=el('button','pill','Open live context');b.onclick=()=>loadContext(session.live);bar.append(b)}app.append(bar,view.stream);await pollTimeline(view)}
async function contextAction(live,action,key,text){await api('api/context?id='+encodeURIComponent(live.id),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,key,text})});contextSignature='';await loadContext(live)}
async function loadContext(live,passive=false){const state=await api('api/context?id='+encodeURIComponent(live.id)),signature=JSON.stringify([live.id,state.capturedAt,state.busy,state.rawTokens,state.effectiveTokens,state.rules,(state.raw||[]).map(x=>x.key)]);if(passive&&signature===contextSignature)return;contextSignature=signature;selected=null;renderSessions();activeView={kind:'context',live};const app=$('#app');app.replaceChildren(metrics([['Raw tokens ≈',fmt(state.rawTokens)],['Effective ≈',fmt(state.effectiveTokens)],['Saved next call ≈',fmt(state.savedTokens)],['State',state.busy?'Model call active':'Ready']]));const note=el('div','analysis');note.append(el('strong','',live.account+' · live effective context'),el('p','muted',state.capturedAt?'Updated '+new Date(state.capturedAt).toLocaleTimeString()+' · changes affect the next request only. Tool calls and results are paired; raw rollout history is retained.':'Waiting for the first model request. This view updates automatically.'));const refresh=el('button','pill','Refresh now'),clear=el('button','pill','Restore all overlays');refresh.onclick=()=>{contextSignature='';loadContext(live)};clear.onclick=()=>contextAction(live,'clear');note.append(refresh,clear);app.append(note);const rule=new Map((state.rules||[]).map(x=>[x.key,x]));for(const item of state.raw||[]){const card=el('article','event context-item'),minus=el('button','minus',rule.has(item.key)?'↶':'−'),body=el('div'),actions=el('div','actions');minus.title=rule.has(item.key)?'Restore':'Suppress from next request';minus.disabled=item.protected&&!state.protectedChanges;minus.onclick=()=>contextAction(live,rule.has(item.key)?'restore':'suppress',item.key);body.append(el('div','tag',(item.role||item.type)+(item.callId?' · paired tool item':'')+(item.protected?' · protected':'')),el('strong','',fmt(item.tokens)+' tokens · '+fmt(item.chars)+' chars'),el('pre','',item.preview||'(opaque/no displayable text)'));if(item.editable&&(!item.protected||state.protectedChanges)){const edit=el('button','pill','Edit');edit.onclick=()=>{editorKey={live,key:item.key};$('#editText').value=item.text||'';$('#editor').showModal()};actions.append(edit)}card.append(minus,body,actions);app.append(card)}}
function rankedCard(title,rows,unit=''){const c=el('section','analysis');c.append(el('h3','',title));const max=rows[0]?.value||1;for(const r of rows.slice(0,10)){const row=el('div','row'),left=el('div');left.append(el('div','',r.name),(()=>{const b=el('div','bar'),i=el('i');i.style.width=(r.value/max*100)+'%';b.append(i);return b})());row.append(left,el('span','muted',fmt(r.value)+unit));c.append(row)}if(!rows.length)c.append(el('p','muted','No repeated pattern in the indexed sessions.'));return c}
async function loadEfficiency(){activeView={kind:'efficiency'};const app=$('#app');app.replaceChildren(el('div','empty','Analyzing the most recent sessions across all accounts…'));const d=await api('api/efficiency');app.replaceChildren(metrics([['Sessions',fmt(d.totals.sessions)],['Exact-token sessions',fmt(d.totals.exactSessions)],['Input tokens',fmt(d.totals.input)],['Cached input',fmt(d.totals.cached)],['Tool calls',fmt(d.totals.toolCalls)],['Compactions',fmt(d.totals.compactions)]]));if(d.limitReached){const notice=el('section','analysis');notice.append(el('strong','','Session limit reached'),el('p','muted','Analyzed the '+fmt(d.limit)+' most recently updated sessions across all accounts. '+(d.availableSessions>d.limit?fmt(d.availableSessions-d.limit)+' older sessions were excluded.':'Older sessions may be excluded as new ones appear.')+' Change the limit in Deck Settings → Efficiency.'));app.append(notice)}const rec=el('div','grid');for(const r of d.recommendations){const c=el('section','analysis');c.append(el('h3','',r.title),el('p','muted',r.detail));rec.append(c)}app.append(rec);const grid=el('div','grid');grid.append(rankedCard('Tools',d.tools),rankedCard('Repeated commands',d.commands,'×'),rankedCard('Repeated paths',d.paths,'×'),rankedCard('Tokens by account',d.accounts),rankedCard('Tokens by project',d.projects),rankedCard('Tokens by model',d.models));app.append(grid);const large=el('section','analysis');large.append(el('h3','','Largest tool results'));for(const x of d.largest){large.append(el('div','row',null));const row=large.lastChild;row.append(el('span','',x.tool+' · '+x.account+' · '+x.preview),el('span','muted',fmt(x.chars)+' chars'))}app.append(large);sessions=d.sessions;renderSessions()}
$('#search').oninput=renderSessions;$('#cancelEdit').onclick=()=>$('#editor').close();$('#saveEdit').onclick=async()=>{await contextAction(editorKey.live,'edit',editorKey.key,$('#editText').value);$('#editor').close()};setInterval(()=>{if(activeView?.kind==='context'&&!$('#editor').open)loadContext(activeView.live,true).catch(()=>{});else if(activeView?.kind==='timeline')pollTimeline(activeView).catch(()=>{});else if(activeView?.kind==='awaiting')refreshAwaiting(activeView).catch(()=>{})},1000);(MODE==='trajectory'?loadTrajectory():loadEfficiency()).catch(e=>$('#app').textContent=e.message);
setInterval(refreshSessionList,30000);
</script></body></html>`}
async function createInspector(root,stateFile){
  const secret=crypto.randomBytes(32).toString('hex'); let sessions=[],lastIndexAt=0,indexing=null,indexedLimit=0; const contextPresence=new Map();
  const refresh=async()=>{
    const limit=efficiencyLimit(root);
    if(Date.now()-lastIndexAt>10000 || limit>indexedLimit){
      if(!indexing)indexing=walkSessionsAsync(root,limit).then(result=>{sessions=result;indexedLimit=limit;lastIndexAt=Date.now()}).finally(()=>{indexing=null});
      await indexing;
    }
    return limit;
  };
  const server=http.createServer(async(req,res)=>{try{
    const host=`127.0.0.1:${server.address().port}`,origin=`http://${host}`;
    if(req.headers.host!==host || (req.headers.origin&&req.headers.origin!==origin) || !req.url.startsWith('/'+secret+'/'))return error(res,403,'Forbidden.');
    const relative=req.url.slice(secret.length+1),url=new URL(relative,origin); const route=url.pathname.replace(/^\//,'');
    if(route==='health')return sendJson(res,200,{ok:true,pid:process.pid,version:VERSION});
    if(route==='trajectory'||route==='efficiency'){
      if(!enabled(root,route))return error(res,403,`${route==='trajectory'?'Trajectory':'Efficiency analytics'} is disabled in Deck Settings.`);
      const nonce=crypto.randomBytes(18).toString('base64');res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store','content-security-policy':`default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; img-src 'self'`});return res.end(page(route,nonce));
    }
    if(route==='context'){
      const s=settings(root);if(s.TrajectoryEnabled!==true||s.ContextManagerEnabled!==true)return error(res,403,'The live context manager is disabled in Deck Settings.');
      const nonce=crypto.randomBytes(18).toString('base64');res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store','content-security-policy':`default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'`});return res.end(contextPage(nonce));
    }
    if(route==='api/sessions'){
      if(!enabled(root,'trajectory'))return error(res,403,'Trajectory is disabled.'); await refresh(); const internalLive=liveMarkers(root), live=internalLive.map(publicMarker);
      const lite=await mapLimit(sessions.slice(0,500),8,async session=>{const summary=await scanSession(session),updated=Date.parse(summary.updatedAt||0),marker=live.find(item=>item.account===summary.account && updated>=Date.parse(item.startedAt||0)-2000);return {...summary,file:undefined,commands:undefined,paths:undefined,tools:undefined,largest:undefined,fileName:path.basename(session.file),live:marker||null};});
      return sendJson(res,200,{sessions:lite,live});
    }
    if(route==='api/timeline'){
      if(!enabled(root,'trajectory'))return error(res,403,'Trajectory is disabled.');const session=sessions.find(item=>item.id===url.searchParams.get('id'));if(!session)return error(res,404,'Session not found.');return sendJson(res,200,await timelineChunk(session,Number(url.searchParams.get('cursor')||0)));
    }
    if(route==='api/context'){
      const s=settings(root);if(s.TrajectoryEnabled!==true||s.ContextManagerEnabled!==true)return error(res,403,'The live context manager is disabled.');if(!['GET','POST'].includes(req.method))return error(res,405,'Method not allowed.');return proxyContext(root,url.searchParams.get('id'),req,res,url.searchParams.get('since'));
    }
    if(route==='api/context/presence'){
      const s=settings(root),id=url.searchParams.get('id');if(s.TrajectoryEnabled!==true||s.ContextManagerEnabled!==true)return error(res,403,'The live context manager is disabled.');if(!markerById(root,id))return error(res,404,'The live context route is unavailable.');
      if(req.method==='POST'){if(url.searchParams.has('close'))contextPresence.delete(id);else contextPresence.set(id,Date.now());return sendJson(res,200,{ok:true})}
      if(req.method!=='GET')return error(res,405,'Method not allowed.');return sendJson(res,200,{open:Date.now()-(contextPresence.get(id)||0)<5000});
    }
    if(route==='api/efficiency'){
      if(!enabled(root,'efficiency'))return error(res,403,'Efficiency analytics is disabled.');const limit=await refresh();return sendJson(res,200,await efficiency(root,limit,sessions));
    }
    error(res,404,'Not found.');
  }catch(e){error(res,500,e instanceof Error?e.message:'Inspector request failed.')}});
  server.on('clientError',(_error,socket)=>socket.destroy()); await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
  const baseUrl=`http://127.0.0.1:${server.address().port}/${secret}/`;
  await fsp.mkdir(path.dirname(stateFile),{recursive:true});await fsp.writeFile(stateFile,JSON.stringify({ProcessId:process.pid,StartedAt:new Date().toISOString(),BaseUrl:baseUrl},null,2),'utf8');
  return {server,baseUrl};
}
module.exports={walkSessions,scanSession,timelineChunk,efficiency,createInspector,normalize};
if(require.main===module){
  const args=process.argv.slice(2),take=name=>{const i=args.indexOf(name);return i>=0?args[i+1]:''},root=path.resolve(take('--root')),stateFile=path.resolve(take('--state'));
  if(!root||!stateFile||Number(process.versions.node.split('.')[0])<18){process.stderr.write('Deck Inspector needs --root, --state and Node.js 18+.\n');process.exit(1)}
  createInspector(root,stateFile).catch(error=>{process.stderr.write((error?.stack||String(error))+'\n');process.exit(1)});
}
