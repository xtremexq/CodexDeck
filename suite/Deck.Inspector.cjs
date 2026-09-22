'use strict';
// Local-only trajectory/context studio and independent efficiency analytics.
// Both surfaces share the rollout index, but have separate settings and routes.
const http = require('node:http');
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const crypto = require('node:crypto');
const readline = require('node:readline');

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
    while (stack.length && files.length < limit) {
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
  return files.sort((a,b) => b.mtime - a.mtime).slice(0, limit);
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
  if (cache.size > 600) cache.delete(cache.keys().next().value);
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
  return result;
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
    if(cursor+read<stat.size){const cut=text.lastIndexOf('\n');if(cut>=0){consumed=Buffer.byteLength(text.slice(0,cut+1));text=text.slice(0,cut+1);}}
    const items=[]; let lineNumber=0;
    for(const line of text.split(/\r?\n/)){if(!line)continue;lineNumber++;try{items.push(normalize(JSON.parse(line),lineNumber));}catch{}}
    return {items,next:cursor+consumed,done:cursor+consumed>=stat.size,size:stat.size};
  } finally { await handle.close(); }
}
async function efficiency(root, limit) {
  const sessions=walkSessions(root,limit), summaries=await mapLimit(sessions,6,scanSession);
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
  return {generatedAt:new Date().toISOString(),limit,totals,tools:ranked(tools),commands:repeats.slice(0,12),paths:pathRepeats.slice(0,12),accounts:ranked(accounts),projects:ranked(projects),models:ranked(models),largest:largest.sort((a,b)=>b.chars-a.chars).slice(0,15),recommendations,sessions:summaries.slice(0,40).map(({file,commands,paths,tools,largest,...item})=>item)};
}
function sendJson(res,status,value){if(res.destroyed)return;if(res.headersSent){res.destroy();return;}res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(JSON.stringify(value));}
function error(res,status,message){sendJson(res,status,{error:message});}
async function proxyContext(root,id,req,res){
  const marker=markerById(root,id); if(!marker || !marker.context)return error(res,404,'The live context route is unavailable.');
  const entry=readJson(marker.file), target=new URL(entry.ContextUrl);
  if(target.hostname!=='127.0.0.1' || !/^\/[a-f0-9]{64}\/_deck\/context$/.test(target.pathname))return error(res,409,'The stored context route is invalid.');
  let body=Buffer.alloc(0); if(req.method==='POST'){const parts=[];let size=0;for await(const part of req){size+=part.length;if(size>65536)return error(res,413,'Context action is too large.');parts.push(part);}body=Buffer.concat(parts);}
  await new Promise(resolve=>{const upstream=http.request(target,{method:req.method,headers:{'content-type':'application/json','content-length':body.length}},incoming=>{if(res.destroyed){incoming.destroy();return resolve();}res.writeHead(incoming.statusCode,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});incoming.pipe(res);incoming.on('end',resolve);});upstream.on('error',()=>{error(res,502,'The conversation proxy is no longer available.');resolve();});upstream.end(body);});
}
function page(mode,nonce){return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Codex Deck · ${mode==='trajectory'?'Trajectory':'Efficiency'}</title><style nonce="${nonce}">
:root{color-scheme:dark;--bg:#090d0f;--panel:#111719;--line:#253136;--text:#e8f1f0;--muted:#8a9a9e;--mint:#82e6c5;--blue:#82b9ff;--red:#ff7e87;--amber:#f4c978}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% -10%,#17332e 0,transparent 32%),var(--bg);color:var(--text);font:14px/1.45 Inter,Segoe UI,sans-serif}button,input,textarea{font:inherit}.top{height:64px;display:flex;align-items:center;padding:0 22px;border-bottom:1px solid var(--line);gap:18px;position:sticky;top:0;background:#090d0fee;backdrop-filter:blur(16px);z-index:4}.brand{font-size:18px;font-weight:700;letter-spacing:.2px}.brand b{color:var(--mint)}.switch{display:flex;background:#101719;border:1px solid var(--line);border-radius:10px;padding:3px}.switch a{color:var(--muted);padding:7px 12px;text-decoration:none;border-radius:7px}.switch a.on{background:#21302e;color:var(--mint)}.hint{margin-left:auto;color:var(--muted);font-size:12px}.shell{display:grid;grid-template-columns:310px minmax(0,1fr);height:calc(100vh - 64px)}aside{border-right:1px solid var(--line);overflow:auto;padding:16px}.search{width:100%;background:#0d1214;border:1px solid var(--line);color:var(--text);border-radius:9px;padding:10px 12px;margin-bottom:12px}.session{width:100%;text-align:left;background:transparent;border:1px solid transparent;color:var(--text);padding:11px;border-radius:10px;margin:2px 0;cursor:pointer}.session:hover,.session.on{background:#141e20;border-color:#293a3c}.session strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.session small,.muted{color:var(--muted)}main{overflow:auto;padding:22px}.hero{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:18px}.metric{background:linear-gradient(145deg,#141c1e,#0f1517);border:1px solid var(--line);border-radius:13px;padding:14px 16px;min-width:150px}.metric b{display:block;font-size:23px;color:var(--mint)}.toolbar{display:flex;gap:8px;align-items:center;margin-bottom:16px}.pill,.danger{border:1px solid var(--line);background:#151d20;color:var(--text);padding:8px 11px;border-radius:8px;cursor:pointer}.danger{color:var(--red);border-color:#593238}.event,.analysis{background:#101719;border:1px solid var(--line);border-radius:12px;margin:9px 0;padding:13px 15px}.event .head{display:flex;gap:8px;align-items:center}.event .kind{color:var(--mint);font-size:11px;text-transform:uppercase;letter-spacing:.8px}.event time{margin-left:auto;color:var(--muted);font-size:11px}.event pre{white-space:pre-wrap;word-break:break-word;max-height:360px;overflow:auto;color:#cdd8d7;margin:9px 0 0;font:12px/1.5 Cascadia Mono,Consolas,monospace}.context-item{display:grid;grid-template-columns:auto 1fr auto;gap:12px;align-items:start}.minus{width:26px;height:26px;border-radius:50%;border:1px solid #63343b;background:#26171a;color:var(--red);font-weight:800;cursor:pointer}.tag{font-size:11px;color:var(--blue)}.actions{display:flex;gap:6px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:14px}.analysis h3{margin:0 0 10px}.bar{height:6px;background:#20292c;border-radius:4px;overflow:hidden}.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--mint),var(--blue))}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;margin:10px 0}.empty{padding:50px 10px;text-align:center;color:var(--muted)}dialog{background:#111719;color:var(--text);border:1px solid var(--line);border-radius:14px;width:min(720px,90vw)}textarea{width:100%;min-height:220px;background:#090d0f;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:12px}@media(max-width:800px){.shell{grid-template-columns:1fr}aside{display:none}.hint{display:none}main{padding:14px}}
</style></head><body><header class="top"><div class="brand">CODEX <b>DECK</b></div><nav class="switch"><a href="trajectory" class="${mode==='trajectory'?'on':''}">Trajectory + Context</a><a href="efficiency" class="${mode==='efficiency'?'on':''}">Efficiency Analytics</a></nav><span class="hint">Local only · raw rollouts stay on this machine</span></header><div class="shell"><aside><input id="search" class="search" placeholder="Filter sessions"><div id="sessions"></div></aside><main><div id="app" class="empty">Loading local index…</div></main></div><dialog id="editor"><h3>Edit model-visible projection</h3><p class="muted">Raw history is retained. This replacement applies to the next request.</p><textarea id="editText"></textarea><div class="toolbar"><button id="saveEdit" class="pill">Save overlay</button><button id="cancelEdit" class="pill">Cancel</button></div></dialog><script nonce="${nonce}">
const MODE=${JSON.stringify(mode)},$=s=>document.querySelector(s),el=(n,c,t)=>{const x=document.createElement(n);if(c)x.className=c;if(t!=null)x.textContent=t;return x},fmt=n=>Number(n||0).toLocaleString(),api=async(url,options)=>{const r=await fetch(url,options);const j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j};let sessions=[],selected=null,editorKey=null;
function metrics(values){const h=el('div','hero');for(const [label,value]of values){const c=el('div','metric');c.append(el('b','',value),el('span','muted',label));h.append(c)}return h}
function renderSessions(){const q=$('#search').value.toLowerCase(),box=$('#sessions');box.replaceChildren();for(const s of sessions.filter(x=>(x.title+' '+x.account+' '+x.cwd).toLowerCase().includes(q))){const b=el('button','session'+(selected===s.id?' on':''));b.append(el('strong','',s.title),el('small','',s.account+' · '+new Date(s.updatedAt).toLocaleString()));b.onclick=()=>{selected=s.id;renderSessions();loadTimeline(s)};box.append(b)}}
async function loadTrajectory(){const data=await api('api/sessions');sessions=data.sessions;renderSessions();if(data.live.length){const bar=el('div','toolbar'),button=el('button','pill','Live Context ('+data.live.length+')');button.onclick=()=>loadContext(data.live[0]);bar.append(button);$('#app').replaceChildren(bar,el('div','empty','Choose a session, or open the live effective context.'))}else $('#app').textContent='Choose a session. No context-managed conversation is live right now.';if(sessions[0]){selected=sessions[0].id;renderSessions();loadTimeline(sessions[0])}}
async function loadTimeline(session){const app=$('#app');app.replaceChildren(metrics([['Account',session.account],['Turns',fmt(session.turns)],['Tools',fmt(session.toolCalls)],['Tokens',session.usage.exact?fmt(session.usage.total):'—'],['Compactions',fmt(session.compactions)]]));const bar=el('div','toolbar');bar.append(el('span','muted',session.cwd||session.fileName));if(session.live){const b=el('button','pill','Open live context');b.onclick=()=>loadContext(session.live);bar.append(b)}app.append(bar);let cursor=0;const stream=el('div');app.append(stream);do{const page=await api('api/timeline?id='+encodeURIComponent(session.id)+'&cursor='+cursor);for(const item of page.items){const card=el('article','event'),head=el('div','head');head.append(el('span','kind',item.kind),el('strong','',item.title));if(item.at)head.append(el('time','',new Date(item.at).toLocaleString()));card.append(head);if(item.text)card.append(el('pre','',item.text));stream.append(card)}cursor=page.next;if(page.done)break;await new Promise(r=>requestAnimationFrame(r))}while(selected===session.id)}
async function contextAction(live,action,key,text){await api('api/context?id='+encodeURIComponent(live.id),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,key,text})});loadContext(live)}
async function loadContext(live){const state=await api('api/context?id='+encodeURIComponent(live.id)),app=$('#app');app.replaceChildren(metrics([['Raw tokens ≈',fmt(state.rawTokens)],['Effective ≈',fmt(state.effectiveTokens)],['Saved next call ≈',fmt(state.savedTokens)],['State',state.busy?'Model call active':'Ready']]));const note=el('div','analysis');note.append(el('strong','',live.account+' · live effective context'),el('p','muted','Changes cannot alter a request already in flight. Tool calls and results are suppressed together by default. Raw rollout history is never rewritten.'));const clear=el('button','pill','Restore all overlays');clear.onclick=()=>contextAction(live,'clear');note.append(clear);app.append(note);const rule=new Map((state.rules||[]).map(x=>[x.key,x]));for(const item of state.raw){const card=el('article','event context-item'),minus=el('button','minus',rule.has(item.key)?'↶':'−'),body=el('div'),actions=el('div','actions');minus.title=rule.has(item.key)?'Restore':'Suppress from next request';minus.disabled=item.protected&&!state.protectedChanges;minus.onclick=()=>contextAction(live,rule.has(item.key)?'restore':'suppress',item.key);body.append(el('div','tag',(item.role||item.type)+(item.callId?' · paired tool item':'')+(item.protected?' · protected':'')),el('strong','',fmt(item.tokens)+' tokens · '+fmt(item.chars)+' chars'),el('pre','',item.preview||'(opaque/no displayable text)'));if(item.editable&&!item.protected){const edit=el('button','pill','Edit');edit.onclick=()=>{editorKey={live,key:item.key};$('#editText').value=item.text||'';$('#editor').showModal()};actions.append(edit)}card.append(minus,body,actions);app.append(card)}}
function rankedCard(title,rows,unit=''){const c=el('section','analysis');c.append(el('h3','',title));const max=rows[0]?.value||1;for(const r of rows.slice(0,10)){const row=el('div','row'),left=el('div');left.append(el('div','',r.name),(()=>{const b=el('div','bar'),i=el('i');i.style.width=(r.value/max*100)+'%';b.append(i);return b})());row.append(left,el('span','muted',fmt(r.value)+unit));c.append(row)}if(!rows.length)c.append(el('p','muted','No repeated pattern in the indexed sessions.'));return c}
async function loadEfficiency(){const d=await api('api/efficiency'),app=$('#app');app.replaceChildren(metrics([['Sessions',fmt(d.totals.sessions)],['Exact-token sessions',fmt(d.totals.exactSessions)],['Input tokens',fmt(d.totals.input)],['Cached input',fmt(d.totals.cached)],['Tool calls',fmt(d.totals.toolCalls)],['Compactions',fmt(d.totals.compactions)]]));const rec=el('div','grid');for(const r of d.recommendations){const c=el('section','analysis');c.append(el('h3','',r.title),el('p','muted',r.detail));rec.append(c)}app.append(rec);const grid=el('div','grid');grid.append(rankedCard('Tools',d.tools),rankedCard('Repeated commands',d.commands,'×'),rankedCard('Repeated paths',d.paths,'×'),rankedCard('Tokens by account',d.accounts),rankedCard('Tokens by project',d.projects),rankedCard('Tokens by model',d.models));app.append(grid);const large=el('section','analysis');large.append(el('h3','','Largest tool results'));for(const x of d.largest){large.append(el('div','row',null));const row=large.lastChild;row.append(el('span','',x.tool+' · '+x.account+' · '+x.preview),el('span','muted',fmt(x.chars)+' chars'))}app.append(large);sessions=d.sessions;renderSessions()}
$('#search').oninput=renderSessions;$('#cancelEdit').onclick=()=>$('#editor').close();$('#saveEdit').onclick=async()=>{await contextAction(editorKey.live,'edit',editorKey.key,$('#editText').value);$('#editor').close()};(MODE==='trajectory'?loadTrajectory():loadEfficiency()).catch(e=>$('#app').textContent=e.message);
</script></body></html>`}
async function createInspector(root,stateFile){
  const secret=crypto.randomBytes(32).toString('hex'); let sessions=[];
  const refresh=()=>{const limit=Math.max(10,Math.min(1000,Number(settings(root).EfficiencySessionLimit||200)));sessions=walkSessions(root,Math.max(1000,limit));return limit}; refresh();
  const server=http.createServer(async(req,res)=>{try{
    const host=`127.0.0.1:${server.address().port}`,origin=`http://${host}`;
    if(req.headers.host!==host || (req.headers.origin&&req.headers.origin!==origin) || !req.url.startsWith('/'+secret+'/'))return error(res,403,'Forbidden.');
    const relative=req.url.slice(secret.length+1),url=new URL(relative,origin); const route=url.pathname.replace(/^\//,'');
    if(route==='health')return sendJson(res,200,{ok:true,pid:process.pid});
    if(route==='trajectory'||route==='efficiency'){
      if(!enabled(root,route))return error(res,403,`${route==='trajectory'?'Trajectory':'Efficiency analytics'} is disabled in Deck Settings.`);
      const nonce=crypto.randomBytes(18).toString('base64');res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store','content-security-policy':`default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; img-src 'self'`});return res.end(page(route,nonce));
    }
    if(route==='api/sessions'){
      if(!enabled(root,'trajectory'))return error(res,403,'Trajectory is disabled.'); refresh(); const internalLive=liveMarkers(root), live=internalLive.map(publicMarker);
      const lite=await mapLimit(sessions.slice(0,500),8,async session=>{const summary=await scanSession(session),marker=live.find(item=>item.account===summary.account);return {...summary,file:undefined,commands:undefined,paths:undefined,tools:undefined,largest:undefined,fileName:path.basename(session.file),live:marker||null};});
      return sendJson(res,200,{sessions:lite,live});
    }
    if(route==='api/timeline'){
      if(!enabled(root,'trajectory'))return error(res,403,'Trajectory is disabled.');const session=sessions.find(item=>item.id===url.searchParams.get('id'));if(!session)return error(res,404,'Session not found.');return sendJson(res,200,await timelineChunk(session,Number(url.searchParams.get('cursor')||0)));
    }
    if(route==='api/context'){
      const s=settings(root);if(s.TrajectoryEnabled!==true||s.ContextManagerEnabled!==true)return error(res,403,'The live context manager is disabled.');if(!['GET','POST'].includes(req.method))return error(res,405,'Method not allowed.');return proxyContext(root,url.searchParams.get('id'),req,res);
    }
    if(route==='api/efficiency'){
      if(!enabled(root,'efficiency'))return error(res,403,'Efficiency analytics is disabled.');const limit=refresh();return sendJson(res,200,await efficiency(root,limit));
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
