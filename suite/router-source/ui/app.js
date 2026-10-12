const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replace(/[&<>"']/g,c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const extension = typeof chrome !== 'undefined' && !!chrome.runtime?.id;
const pages = ['routes','providers','playground','deck','integrations','activity','settings'];
const labels = { routes:'Routes', providers:'Providers', playground:'Playground', deck:'AI Deck', integrations:'Integrations', activity:'Activity', settings:'Settings' };
const paths = { routes:'M3 6h6v6H3zM15 12h6v6h-6zM9 9h5v6h1M17 3v6m-3-3h6', providers:'M8 3v4m8-4v4M6 7h12v5a6 6 0 0 1-12 0zM12 18v3', playground:'m5 5 5 5-5 5m7 2h7', deck:'M4 4h16v13H4zM8 21h8m-4-4v4', integrations:'M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-2 2M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l2-2', activity:'M2 12h5l3-8 4 16 3-8h5', settings:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 3v2m0 14v2M3 12h2m14 0h2M5.6 5.6 7 7m10 10 1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4' };
let base = 'http://127.0.0.1:5147';
let token = ''; let state = null; let page = 'routes'; let chat = []; let chatAbort = null; let bridge = { allowedExtensionIds: [], clientKey: '' }; let busy = false;
let pendingRoute = null; let toastTimer; let mode='deck'; let connectionKind='deck'; let pairingAbort=null; let extensionClient; let workspaceMigrationError='';
const HISTORY_KEY='aideck-playground-history-v1',ATTACHMENT_DB='aideck-playground-attachments-v1';let chatHistory=[],activeConversationId=null,historySaveTimer,historyQueue=Promise.resolve(),selectedRouteId='',attachmentDbPromise,pendingImages=[],playgroundPanel='details',chatRun=null;
const modelCache=new Map();
const MAX_PLAYGROUND_IMAGES=8,MAX_PLAYGROUND_IMAGE_BYTES=10*1024*1024,MAX_PLAYGROUND_FILE_BYTES=5*1024*1024,MAX_PLAYGROUND_HISTORY_IMAGE_BYTES=50*1024*1024;
if(extension)extensionClient=await import(chrome.runtime.getURL('client.js'));
const provider = id => state?.providers.find(p => p.id === id);
const account = id => state?.config.accounts.find(a => a.id === id);
const nativeAccount = id => typeof id==='string'&&id.startsWith('deck:')?state?.deck?.accounts?.find(a=>`deck:${a.id}`===id):null;
const routeAccounts = () => [...(state?.config.accounts||[]),...(state?.deck?.accounts||[]).filter(a=>a.routable).map(a=>({id:`deck:${a.id}`,name:`${a.id} · ${a.harness}`,enabled:true,native:true,harness:a.harness,provider:a.provider}))];
const accountLabel = id => {const a=account(id),d=nativeAccount(id);return a?.name|| (d?`${d.id} · ${d.harness}`:id);};
const defaultTargetModel = id => nativeAccount(id)?'default':provider(account(id)?.provider)?.webSession?(account(id)?.webOptions?.model||'auto'):'';
const badge = (text,kind='') => `<span class="badge ${kind}">${esc(text)}</span>`;
const providerIcons={openai:'openai',google:'gemini',anthropic:'anthropic',deepseek:'deepseek',xai:'xai',cloudflare:'cloudflare',openrouter:'openrouter',mistral:'mistral','chatgpt-web':'openai','claude-web':'claude','gemini-web':'gemini','grok-web':'grok',custom:'compatible'};
const providerIcon = id => providerIcons[id]||'compatible';
const logoImage = (icon,size=20) => `<img class="provider-logo" src="icons-${esc(icon)}.svg" width="${size}" height="${size}" loading="lazy" decoding="async" alt="" aria-hidden="true">`;
const mark = p => `<span class="provider-mark" title="${esc(p?.name||'Provider')}">${logoImage(providerIcon(p?.id))}</span>`;
const harnessMark = harness => {const name=String(harness||'').toLowerCase(),icon=name.includes('codex')?'openai':name.includes('claude')?'claude':name.includes('gemini')?'gemini':name.includes('grok')?'grok':null;return icon?`<span class="provider-mark" title="${esc(harness)}">${logoImage(icon)}</span>`:`<span class="provider-mark" title="${esc(harness||'Harness')}">${esc(String(harness||'?').slice(0,2).toUpperCase())}</span>`;};
const button = (text,action,id='',kind='') => `<button type="button" class="${kind}" data-action="${action}" data-id="${esc(id)}">${text}</button>`;
function toast(message) { clearTimeout(toastTimer); $('#toast').textContent = message; $('#toast').classList.add('show'); toastTimer = setTimeout(() => $('#toast').classList.remove('show'),4200); }
async function api(path, options = {}) {
  if(extension&&mode==='standalone')return extensionClient.standaloneAdmin(path,options);
  const response = await fetch(base+path,{ ...options, headers: { Authorization: `Bearer ${token}`, ...(options.body ? {'Content-Type':'application/json'} : {}), ...options.headers }, body: options.body ? JSON.stringify(options.body) : undefined });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error?.message || `Gateway returned ${response.status}.`);
  return value;
}
async function readHistory(){
  try{
    const value=extension?(await chrome.storage.local.get(HISTORY_KEY))[HISTORY_KEY]:JSON.parse(localStorage.getItem(HISTORY_KEY)||'[]');
    chatHistory=Array.isArray(value)?value.filter(item=>item&&typeof item.id==='string'&&Array.isArray(item.messages)).sort((a,b)=>(b.updatedAt||0)-(a.updatedAt||0)).slice(0,30):[];
    const latest=chatHistory[0];if(latest){activeConversationId=latest.id;chat=await hydrateMessages(latest.messages);const pending=chat.findLast?.(message=>message.role==='assistant'&&!message.content&&!message.tools);if(pending){pending.content='Response interrupted before any output.';pending.failed=true;}}
  }catch{chatHistory=[];activeConversationId=null;chat=[];}
}
function attachmentDb(){
  if(!attachmentDbPromise)attachmentDbPromise=new Promise((resolve,reject)=>{const request=indexedDB.open(ATTACHMENT_DB,1);request.onupgradeneeded=()=>request.result.createObjectStore('images',{keyPath:'id'});request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error||new Error('Image history storage is unavailable.'));});
  return attachmentDbPromise;
}
function dataUrlFor(blob){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result));reader.onerror=()=>reject(new Error('Image could not be read.'));reader.readAsDataURL(blob);});}
function saveImageBlob(record){return attachmentDb().then(db=>new Promise((resolve,reject)=>{const tx=db.transaction('images','readwrite');tx.objectStore('images').put({id:record.id,name:record.name,type:record.type,size:record.size,blob:record.blob});tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error||new Error('Image could not be saved in browser history.'));tx.onabort=()=>reject(tx.error||new Error('Image could not be saved in browser history.'));}));}
function readImageBlob(id){return attachmentDb().then(db=>new Promise((resolve,reject)=>{const tx=db.transaction('images','readonly'),request=tx.objectStore('images').get(id);request.onsuccess=()=>resolve(request.result||null);request.onerror=()=>reject(request.error||new Error('Saved image could not be read.'));}));}
function removeImageBlobs(ids){if(!ids.length)return Promise.resolve();return attachmentDb().then(db=>new Promise((resolve,reject)=>{const tx=db.transaction('images','readwrite'),store=tx.objectStore('images');ids.forEach(id=>store.delete(id));tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);}));}
function allImageBlobIds(){return attachmentDb().then(db=>new Promise((resolve,reject)=>{const tx=db.transaction('images','readonly'),request=tx.objectStore('images').getAllKeys();request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);}));}
function revokePreviews(messages){for(const message of messages)for(const image of message.attachments||[])if(image.previewUrl?.startsWith('blob:'))URL.revokeObjectURL(image.previewUrl);}
async function hydrateMessages(messages){
  const hydrated=[];
  for(const message of messages){const copy={...message};copy.attachments=[];for(const meta of message.attachments||[]){try{const saved=await readImageBlob(meta.id);copy.attachments.push(saved?{...meta,dataUrl:await dataUrlFor(saved.blob),previewUrl:URL.createObjectURL(saved.blob)}:{...meta,missing:true});}catch{copy.attachments.push({...meta,missing:true});}}hydrated.push(copy);}
  return hydrated;
}
async function pruneImageBlobs(){
  const keep=new Set(pendingImages.map(image=>image.id));for(const conversation of chatHistory)for(const message of conversation.messages||[])for(const image of message.attachments||[])keep.add(image.id);
  const stored=await allImageBlobIds();await removeImageBlobs(stored.filter(id=>!keep.has(id)));
}
function writeHistory(){
  const snapshot=JSON.stringify(chatHistory.slice(0,30));
  historyQueue=historyQueue.catch(()=>{}).then(()=>extension?chrome.storage.local.set({[HISTORY_KEY]:JSON.parse(snapshot)}):localStorage.setItem(HISTORY_KEY,snapshot));
  return historyQueue;
}
async function remapConversationRoutes(routeMap){
  if(!routeMap||typeof routeMap!=='object')return;
  let changed=false;
  chatHistory=chatHistory.map(conversation=>{const route=routeMap[conversation.route];if(!route||route===conversation.route)return conversation;changed=true;return {...conversation,route};});
  if(changed){await writeHistory();renderHistoryList();}
}
function saveActiveConversation(routeOverride,conversationId=activeConversationId,messages=chat){
  clearTimeout(historySaveTimer);if(!conversationId||!messages.length)return historyQueue;
  const first=messages.find(message=>message.role==='user');
  const conversation={id:conversationId,route:routeOverride===undefined?($('#chat-route')?.value||chatHistory.find(item=>item.id===conversationId)?.route||''):routeOverride,title:String(first?.content||(first?.attachments?.length?'Image conversation':'New conversation')).slice(0,100),createdAt:chatHistory.find(item=>item.id===conversationId)?.createdAt||Date.now(),updatedAt:Date.now(),messages:messages.slice(-80).map(({role,content,tools,failed,attachments})=>({role,content:String(content||'').slice(0,30000),...(attachments?.length?{attachments:attachments.map(({id,name,type,size})=>({id,name,type,size}))}:{}),...(tools?{tools:String(tools).slice(0,30000)}:{}),...(failed?{failed:true}:{})}))};
  chatHistory=[conversation,...chatHistory.filter(item=>item.id!==conversation.id)].slice(0,30);renderHistoryList();
  let encoded=JSON.stringify(chatHistory);while(encoded.length>3_800_000&&chatHistory.length>1){chatHistory.pop();encoded=JSON.stringify(chatHistory);}let imageBytes=chatHistory.reduce((total,item)=>total+(item.messages||[]).reduce((sum,message)=>sum+(message.attachments||[]).reduce((n,image)=>n+(image.size||0),0),0),0);while(imageBytes>MAX_PLAYGROUND_HISTORY_IMAGE_BYTES&&chatHistory.length>1){const removed=chatHistory.pop();imageBytes-=(removed.messages||[]).reduce((sum,message)=>sum+(message.attachments||[]).reduce((n,image)=>n+(image.size||0),0),0);}renderHistoryList();
  return writeHistory().then(async()=>{await pruneImageBlobs();});
}
function scheduleHistorySave(conversationId=activeConversationId,messages=chat,routeId){if(!conversationId)return;clearTimeout(historySaveTimer);historySaveTimer=setTimeout(()=>saveActiveConversation(routeId,conversationId,messages).catch(()=>{const status=$('#chat-status');if(status&&activeConversationId===conversationId)status.textContent='Conversation history could not be saved.';}),300);}
function renderHistoryList(){
  const count=$('#history-count'),toggle=$('#history-toggle');if(count)count.textContent=String(chatHistory.length);if(toggle)toggle.setAttribute('aria-pressed',String(playgroundPanel==='history'));
  const list=$('#conversation-list');if(!list)return;
  list.innerHTML=chatHistory.length?chatHistory.map(item=>`<div class="history-row"><button type="button" class="history-item" data-action="open-chat" data-id="${esc(item.id)}" ${item.id===activeConversationId?'aria-current="true"':''}><strong>${esc(item.title||'New conversation')}</strong><small>${esc(item.route||'No route')} · ${new Date(item.updatedAt||item.createdAt||Date.now()).toLocaleDateString(undefined,{month:'short',day:'numeric'})}</small></button><button type="button" class="history-delete" data-action="delete-chat" data-id="${esc(item.id)}" aria-label="Delete conversation: ${esc(item.title||'New conversation')}" title="Delete conversation">×</button></div>`).join(''):'<p class="history-empty">No saved conversations</p>';
}
function syncChatControls(){
  const routeId=$('#chat-route')?.value,available=state?.config.routes.some(route=>route.id===routeId&&route.enabled),send=$('#send-message'),status=$('#chat-status'),detachedRequest=!!chatAbort&&chatRun?.conversationId!==activeConversationId;
  if(send){send.disabled=chatAbort?detachedRequest:!available;send.textContent=chatAbort?(detachedRequest?'Stopping…':'Stop request'):'Send request ↗';send.classList.toggle('stop-action',!!chatAbort&&!detachedRequest);send.setAttribute('aria-label',chatAbort?(detachedRequest?'Stopping previous request':'Stop the current request'):'Send request');send.title=chatAbort?(detachedRequest?'Stopping the previous request':'Stop the current request'):'Send request';}
  const prompt=$('#chat-form textarea[name="prompt"]');if(prompt)prompt.disabled=!!chatAbort;
  const attach=$('[data-action="attach-image"]');if(attach)attach.disabled=!!chatAbort||!available;
  if(status&&detachedRequest)status.textContent='Stopping previous request…';else if(status&&!chatAbort&&!chatRun)status.textContent=available?'History saved on this device':'This conversation’s route is unavailable. Choose an active route to start another.';
}
function modal(title,content) {
  $('#dialog-content').innerHTML = `<div class="dialog-head"><h2>${esc(title)}</h2><button class="icon-button quiet" data-action="close" aria-label="Close dialog">×</button></div><div class="dialog-body">${content}</div>`;
  if (!$('#dialog').open) $('#dialog').showModal();
}
const formActions = label => `<p class="error-message" role="alert"></p><div class="form-actions"><button type="button" class="quiet" data-action="close">Cancel</button><button class="primary" type="submit">${label}</button></div>`;
function heading(title,description,actions='') { return `<div class="page-head"><div><div class="eyebrow">Your AI infrastructure</div><h1>${title}</h1><p class="subtitle">${description}</p></div><div class="head-actions">${actions}</div></div>`; }
function empty(title,description,action='') { return `<div class="empty"><div class="empty-symbol">⌁</div><h2>${title}</h2><p>${description}</p>${action}</div>`; }
function navigation() {
  $('#nav').innerHTML = pages.map((id,i) => `${i === 3 ? '<div class="nav-label">Configure</div>' : ''}<a href="#${id}" aria-label="${labels[id]}" class="nav-item ${page===id?'active':''}" ${page===id?'aria-current="page"':''}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[id]}"></path></svg>${labels[id]}${id === 'routes' && state ? `<span class="nav-count" aria-hidden="true">${state.config.routes.length}</span>`:''}</a>`).join('');
  $('#crumb').textContent = labels[page];
}
function targetNode(target,index) { const a=account(target.account),d=nativeAccount(target.account),p=provider(a?.provider); return `<div class="target-node"><span class="target-order">${index === 0?'PRIMARY':`FALLBACK ${index}`}</span><div class="target-top">${d?harnessMark(d.harness):mark(p)}<span>${esc(accountLabel(target.account))}</span></div><div class="target-model">${esc(target.model==='default'&&d?'Deck CLI default':target.model)}</div></div>`; }
function routesView() {
  const { accounts,routes,settings } = state.config;
  const enabled = accounts.filter(a=>a.enabled).length;
  const successful = state.runtime.events.filter(e=>e.status==='success');
  const median = successful.length ? [...successful].sort((a,b)=>a.ms-b.ms)[Math.floor(successful.length/2)].ms : null;
  return heading('A home for every AI call.','Choose the destination. Keep your apps connected.',button('+ New route','new-route','','primary')) +
    `<div class="metrics"><div class="metric"><div class="metric-label">Active routes <span>↗</span></div><div class="metric-value">${routes.filter(r=>r.enabled).length}<small>ready to receive</small></div></div><div class="metric"><div class="metric-label">Provider accounts <span>⊞</span></div><div class="metric-value">${enabled}<small>of ${accounts.length} enabled</small></div></div><div class="metric"><div class="metric-label">Requests this session <span>⌁</span></div><div class="metric-value">${state.runtime.requests}<small>${state.runtime.active} in flight</small></div></div><div class="metric"><div class="metric-label">Median completion time <span>◷</span></div><div class="metric-value">${median === null?'—':(median/1000).toFixed(1)+'s'}<small>recent requests</small></div></div></div>` +
    `<div class="section-head"><div><h2>Your routes</h2><p>Stable model aliases. Providers can change behind them.</p></div><span class="section-label">${routes.length} CONFIGURED</span></div>` +
    (routes.length ? routes.map(r=>`<article class="route-card"><div class="route-header"><div class="route-title"><span class="route-icon">⌁</span><div><h2>${esc(r.name)}</h2><small>${esc(r.id)}</small></div>${badge(r.enabled?'Active':'Paused',r.enabled?'':'neutral')}${r.id===settings.defaultRoute?badge('Default','orange'):''}</div>${button('Edit route','edit-route',r.id,'small quiet')}</div><div class="route-flow"><div class="source-node"><small>REQUEST MODEL</small>${esc(r.id)}</div><span class="flow-arrow">→</span>${r.targets.map((t,i)=>`${i?'<span class="flow-arrow">⇢</span>':''}${targetNode(t,i)}`).join('')}</div><div class="route-footer"><span>${r.strategy==='ordered'?'Ordered':'Round robin'} · ${r.failover?'Failover enabled':'Failover off'} · ${r.targets.length} destination${r.targets.length===1?'':'s'}</span><span class="mono">POST /v1/chat/completions</span></div></article>`).join('') : empty('Give your first request a destination.','Connect a provider account or sign in to a Deck account, then create an alias such as everyday or coding.',button('Create a route','new-route','','primary'))) +
    `<div class="info-strip"><span class="info-icon">⌘</span><div><h3>Already using an OpenAI-compatible app?</h3><p>${extension&&mode==='standalone'?'Use the extension messaging API, or connect the optional Deck server for a standard HTTP endpoint.':`Set its API base URL to ${esc(base)}/v1, choose a route alias, and add an integration key.`}</p></div><a href="#integrations">Connect an app ↗</a></div>`;
}
function providersView() {
  const accounts = state.config.accounts;
  const apiProviders=state.providers.filter(p=>!p.webSession),webProviders=state.providers.filter(p=>p.webSession);
  const webBridgeOffline=!extension&&accounts.some(a=>provider(a.provider)?.webSession)&&!state.runtime.webProviderExtensionOnline;
  return `<div class="section-head account-section-head"><h2>Connected accounts</h2><div class="head-actions"><span class="section-label">${accounts.length} ACCOUNTS</span>${button('+ Add account','new-account','','primary')}</div></div>` +
    (webBridgeOffline?'<p class="notice">Signed-in provider requests need the AIDeck Router Chrome extension connected and granted browser access.</p>':'')+
    (accounts.length?`<div class="account-list">${accounts.map(a=>{const p=provider(a.provider),webOptions=a.webOptions,v2ChatUnavailable=p?.webSession&&webOptions?.transport!=='ui-v1'&&['chatgpt-web','grok-web'].includes(a.provider);return `<div class="account-row">${mark(p)}<div class="account-info"><strong>${esc(a.name)}</strong><small>${esc(p?.name||a.provider)} · ${p?.webSession?`${webOptions?.transport==='ui-v1'?'UI bridge V1':'Background API V2'} · ${esc(webOptions?.model||'auto')} · images ${webOptions?.images===false?'off':'on'} · function calls ${webOptions?.tools===false?'off':'on'}${v2ChatUnavailable?' · V2 chat unavailable; choose V1 or an API account':''}`:a.hasKey?'Key saved':'No API key'}${a.proxyUrl?' · Proxy enabled':''}</small></div>${badge(a.enabled?'Enabled':'Paused',a.enabled?'':'neutral')}<div class="row-actions">${button('Models','models',a.id,'small')}${p?.webSession&&extension&&mode!=='standalone'&&webOptions?.transport!=='ui-v1'?button('Grant access','web-provider-access',a.id,'small quiet'):''}${p?.webSession&&webOptions?.transport==='ui-v1'?button('Open session','web-provider-connect',a.id,'small quiet'):''}${button('Edit','edit-account',a.id,'small quiet')}</div></div>`;}).join('')}</div>`:empty('Connect your first provider.','Add an API key or connect a signed-in browser account.')) +
    `<details class="provider-directory section-space"><summary class="provider-directory-summary"><span class="provider-directory-copy"><strong>Provider directory</strong><small>Pick a provider to connect an account.</small></span><span class="provider-directory-meta">${apiProviders.length+webProviders.length} providers <svg viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4"/></svg></span></summary><div class="provider-grid">${apiProviders.map(p=>`<article class="provider-card">${mark(p)}<h2>${esc(p.name)}</h2><p>${p.capabilities.map(esc).join(' · ')}</p>${button('Connect account ↗','new-account',p.id,'small')}</article>`).join('')}${webProviders.length?`<article class="provider-card web-provider-card"><div class="web-provider-logos">${webProviders.map(mark).join('')}</div><h2>Web Providers</h2><p>${webProviders.map(p=>esc(p.name.replace(' Web',''))).join(' · ')}</p><small>V2 routes in background HTTP without provider tabs. Availability depends on each site’s private API and browser challenges; V1 is an optional page bridge.</small>${button('Choose a web provider ↗','new-account','web','small')}</article>`:''}</div></details>`;
}
function playgroundView() {
  const routes = state.config.routes.filter(r=>r.enabled);
  const activeThread=chatHistory.find(item=>item.id===activeConversationId);
  const missingRoute=activeThread&&!routes.some(route=>route.id===activeThread.route)?`<option value="${esc(activeThread.route)}" disabled>${esc(activeThread.route)} · unavailable</option>`:'';
  return (!routes.length&&!activeThread?empty('A route comes first.','Create a route with a provider or a signed-in Deck Codex account to start testing.',button('Create route','new-route','','primary')):
    `<div class="chat-layout"><section class="panel chat-panel"><div class="chat-toolbar"><select aria-label="Playground route" id="chat-route">${routes.map(r=>`<option value="${esc(r.id)}">${esc(r.id)}</option>`).join('')}${missingRoute}</select>${badge('Chat')}<div class="chat-toolbar-actions"><button class="quiet small" data-action="new-chat">New conversation</button><button class="quiet small history-toggle" id="history-toggle" data-action="toggle-playground-panel" aria-pressed="${playgroundPanel==='history'}">History <span id="history-count">${chatHistory.length}</span></button></div></div><div class="messages" id="messages"></div><form id="chat-form" class="composer"><div class="attachment-strip" id="chat-attachments"></div><textarea name="prompt" aria-label="Message" placeholder="What would you like to try?"></textarea><div class="composer-tools"><input id="image-input" type="file" accept="image/png,image/jpeg,image/webp" multiple hidden><button type="button" class="quiet small" data-action="attach-image">＋ Add image</button><span>Paste or drop PNG, JPEG, WebP · up to 8 images / 10 MB per conversation</span></div><div class="composer-bottom"><span id="chat-status">History saved on this device</span><button class="primary small" id="send-message" type="submit">Send request ↗</button></div></form></section><aside class="panel playground-side-panel" id="playground-panel"></aside></div>`);
}
function integrationsView() {
  const routes = state.config.routes;
  const clients=state.config.clients;
  const clientCards=clients.map(client=>{
    const allRoutes=client.routes?.includes('*');
    const scope=allRoutes?'All routes · includes future routes':(client.routes||[]).map(esc).join(', ')||'No routes allowed';
    const created=client.created?new Date(client.created).toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'}):'Existing key';
    return `<article class="integration-card"><div class="integration-card-main"><div class="integration-card-title"><span class="integration-key-mark" aria-hidden="true">⌘</span><div><div class="integration-name"><strong>${esc(client.name)}</strong>${badge(client.enabled===false?'Paused':'Active',client.enabled===false?'neutral':'')}</div><small>${allRoutes?'All routes':`${(client.routes||[]).length} route${client.routes?.length===1?'':'s'}`} · ${client.rpm} requests/min · Created ${esc(created)}</small></div></div><p class="integration-card-scope">${scope}</p></div><div class="integration-card-actions">${button('Edit','edit-client',client.id,'small quiet')}${button('Revoke','delete-client',client.id,'small danger quiet')}</div></article>`;
  }).join('');
  return heading('One endpoint. Your whole stack.','SDKs, apps, websites, and other extensions.',button('+ Integration key','new-client','','primary')) +
    `<section class="integration-keys"><div class="section-head"><div><h2>Integration keys</h2><p>Edit a key’s name, allowed routes, request limit, and status.</p></div><span class="section-label">${clients.length} KEY${clients.length===1?'':'S'}</span></div>${clients.length?`<div class="integration-list">${clientCards}</div>`:'<div class="integration-empty">No integration keys yet. Create one to connect an app.</div>'}</section><div class="two-col"><section class="panel">${extension&&mode==='standalone'?`<div class="eyebrow">01 · Local Router API</div><h2>Connect your apps.</h2><p class="hint">Start the local Router server, then connect this extension with its owner key. Your saved browser accounts and routes will be imported into this Router configuration.</p>${button('Connect local API server','connect-local','','primary')}`:`<div class="eyebrow">01 · Standard API</div><h2>Bring your own app.</h2><p class="hint">Works with clients that accept a custom OpenAI-compatible API base URL.</p><pre>Base URL  ${esc(base)}/v1\nAPI key   your integration key\nModel     ${esc(routes[0]?.id || 'your-route-alias')}</pre>`}</section><section class="panel"><div class="eyebrow">02 · Chrome extension</div><h2>A bridge to other extensions.</h2><p class="hint">Optional Deck mode pairs through a matching code approved in Deck Settings → AI Router.</p><div class="step"><b>1</b><div>Create a dedicated integration key.<small>Only allow the routes the extension needs.</small></div></div><div class="step"><b>2</b><div>Open Router extension Settings.<small>Save the bridge key and approve caller extension IDs.</small></div></div><div class="step"><b>3</b><div>Call the Router messaging interface.<small>One-shot replies and streaming ports are supported.</small></div></div></section></div><div class="info-strip"><span class="info-icon">i</span><div><h3>Compatibility has boundaries.</h3><p>Hardcoded API URLs, proprietary payloads, server-side requests, and consumer chat subscriptions require explicit adapters. The extension does not silently rewrite website traffic.</p></div></div>`;
}
function activityView() {
  const events=state.runtime.events;
  return heading('Follow the request.','Routing outcomes and timing. Prompts and API keys are never logged.',button('Refresh','refresh','','small'))+
    (!events.length?empty('Your first request will appear here.','Try a route in the Playground, or call the gateway from one of your apps.', '<a href="#playground">Open Playground ↗</a>'):
    `<div class="table-wrap"><table class="activity-table"><thead><tr><th>Time</th><th>Route / Model</th><th>Account</th><th>Result</th><th>Attempt</th><th>Elapsed</th></tr></thead><tbody>${events.map(e=>`<tr><td>${new Date(e.at).toLocaleTimeString()}</td><td><strong>${esc(e.route)}</strong><br><small>${esc(e.model)}</small></td><td>${esc(accountLabel(e.account))}</td><td>${badge(e.status,e.status==='success'?'':'orange')}${e.httpStatus?` <small>${e.httpStatus}</small>`:''}</td><td>${e.attempts}</td><td>${(e.ms/1000).toFixed(2)}s</td></tr>`).join('')}</tbody></table></div>`);
}
function settingsView() {
  const s=state.config.settings;
  const connection=extension?`<section class="panel"><h2>Router connection</h2><p class="hint">${mode==='standalone'?'This extension currently uses settings saved in this browser. Connect a local Router server to import these accounts, keys, and routes; afterward the extension and HTTP clients use the same Router configuration.':connectionKind==='local'?'This browser and HTTP clients use the same local Router configuration. Browser accounts, keys, and routes were imported when connected.':'This browser is paired with Deck. Provider accounts, routes, settings, and API requests use the same encrypted Router configuration. Existing browser accounts and routes are imported during pairing.'}</p><div class="form-actions">${mode==='standalone'?`${button('Connect local API server','connect-local','','primary')}${button('Pair with Deck','connect','','small quiet')}`:button(connectionKind==='local'?'Reconnect local server':'Reconnect Deck',connectionKind==='local'?'connect-local':'connect','','primary')}</div></section>${workspaceMigrationError?`<section class="panel"><h2>Browser settings need another try</h2><p class="notice">${esc(workspaceMigrationError)} Your saved browser settings are still available.</p><div class="form-actions">${button('Retry import','retry-workspace-merge','','primary')}</div></section>`:''}`:'';
  return connection+`<form class="panel" id="settings-form"><h2>Routing defaults</h2><div class="form-grid section-space"><label class="field">Default route<select name="defaultRoute"><option value="">No default</option>${state.config.routes.filter(r=>r.enabled).map(r=>`<option ${r.id===s.defaultRoute?'selected':''} value="${esc(r.id)}">${esc(r.id)}</option>`).join('')}</select></label><label class="field">Upstream timeout (seconds)<input name="timeout" type="number" min="1" max="600" value="${s.timeoutMs/1000}" required></label><label class="field">Account cooldown (seconds)<input name="cooldown" type="number" min="1" max="300" value="${s.cooldownMs/1000}" required></label>${extension&&mode==='standalone'?'':`<label class="field">Allowed website origins<textarea name="origins" placeholder="https://your-app.example">${esc(s.allowedOrigins.join('\n'))}</textarea><span class="hint">Exact origins, one per line. Websites still need a scoped integration key.</span></label><label class="field full">Deck accounts root<input name="deckRoot" value="${esc(s.deckRoot)}" required></label><label class="field full">Deck codex-auth.ps1 path<input name="deckScript" value="${esc(s.deckScript)}" required><span class="hint">Used to open and manage native Deck terminals. Signed-in Codex profiles are also available as route destinations.</span></label>`}</div><div class="form-actions"><button class="primary" type="submit">Save settings</button></div></form>`+
    (extension?`<form class="panel" id="bridge-form"><h2>External extension bridge</h2><p class="hint">Approved extensions can spend usage on the routes allowed by this key. Use a dedicated integration key, never the owner key.</p><div class="form-grid section-space"><label class="field">Bridge integration key<input name="clientKey" type="password" autocomplete="off" value="${esc(bridge.clientKey)}" placeholder="aid_…"></label><label class="field">Allowed extension IDs<textarea name="ids" placeholder="32-letter Chrome extension IDs, one per line">${esc(bridge.allowedExtensionIds.join('\n'))}</textarea></label></div><div class="form-actions"><button class="primary" type="submit">Save bridge access</button></div></form>`:'')+
    `<section class="panel"><h2>Local connection</h2><p class="hint">${extension&&mode==='standalone'?'Provider keys are stored in this Chrome profile. Connecting a local API server imports the API accounts and keys into its encrypted vault.':'Provider keys stay in the encrypted local server vault. On Windows its key is protected with your Windows identity.'}</p></section>`;
}
async function deckView() {
  if(extension&&mode==='standalone'){$('#main').innerHTML=heading('Connect Deck when you need it.','The extension routes directly to providers without Deck.')+empty('Native Codex accounts come from Deck.','Connect this extension to a Deck Router server to use its signed-in Codex accounts in routes.',button('Connect to Deck','connect','','primary'));return;}
  $('#main').innerHTML = heading('Your accounts. Your harnesses.','Open isolated Deck terminals without sharing provider credentials.')+'<div class="loading">Reading Deck account metadata…</div>';
  const deck=await api('/admin/deck');
  if(page!=='deck')return;
  $('#main').innerHTML = heading('Your accounts. Your harnesses.','Signed-in Codex accounts can be selected directly as route destinations.',button('+ Deck account','new-deck','','primary'))+
    (!deck.harnessModuleAvailable?'<p class="notice">The live Deck installation does not yet have the Harnesses module. Existing Codex accounts can open; deploy the Harnesses-enabled Deck build before using other harnesses here.</p>':'')+
    (!deck.available?empty('Connect your Deck installation.','Set the accounts root and codex-auth wrapper path in Settings.','<a href="#settings">Open Settings ↗</a>'):
    `<div class="account-list">${deck.accounts.map(a=>`<div class="account-row">${harnessMark(a.harness)}<div class="account-info"><strong>${esc(a.id)}</strong><small>${esc(a.harness || a.error)} · ${esc(a.provider || '')}${a.runner?' · Windows runner':''}${a.routable?' · route ready':a.harness==='Codex'?' · sign in to enable routing':''}</small></div>${a.error?'':`<div class="row-actions">${button('Open terminal ↗','deck-open',a.id,'small')}</div>`}</div>`).join('')}</div>`)+
    `<div class="two-col"><section class="panel"><h2>Use a Deck login in a route</h2><p class="hint">Create or edit a route and choose a signed-in Codex account. Requests use that account's existing Deck profile and Codex CLI login; credentials stay in Deck.</p></section><section class="panel"><h2>Native chat support</h2><p class="hint">Codex accounts support text and inline PNG, JPEG, or WebP image input with the default or a named Codex model. Images are held in a temporary request folder and removed when the request ends.</p><p class="hint">Native routes do not expose shell, browser, computer, or other local tools. Tool calls, audio, embeddings, and Responses API requests are not supported. API-key provider accounts keep their own supported capabilities.</p></section></div>`;
  state.deck=deck;
}
function render() {
  navigation();
  if(!state)return;
  if(page==='deck'){deckView().catch(e=>{if(page==='deck')$('#main').innerHTML=empty('Deck is unavailable.',esc(e.message));});return;}
  $('#main').innerHTML=({routes:routesView,providers:providersView,playground:playgroundView,integrations:integrationsView,activity:activityView,settings:settingsView}[page])();
  if(page==='playground'&&$('#messages')){ const choice=chatHistory.find(item=>item.id===activeConversationId)?.route||selectedRouteId||state.config.settings.defaultRoute; if(choice&&$('#chat-route').querySelector(`option[value="${CSS.escape(choice)}"]`))$('#chat-route').value=choice;selectedRouteId=$('#chat-route').value;renderMessages();renderPlaygroundPanel();syncChatControls(); }
}
async function refresh(redraw=true) {
  state=await api('/admin/state');
  $('#connection').classList.add('connected'); $('#connection-label').textContent=extension&&mode==='standalone'?'Standalone mode':extension&&connectionKind==='local'?'Local API server':'Deck connected';$('.endpoint').textContent=extension&&mode==='standalone'?'Direct to providers':new URL(base).host;
  if(redraw)render();
}
function accountDialog(id,providerId) {
  const a=id?account(id):null,stored=provider(a?.provider),requested=provider(providerId),webProviders=state.providers.filter(x=>x.webSession);
  const webSelected=stored?.webSession===true||providerId==='web'||requested?.webSession===true;
  const selectedWeb=stored?.webSession?stored:requested?.webSession?requested:webProviders[0];
  const p=webSelected?selectedWeb:stored||requested||provider('openai');
  const standardProviders=state.providers.filter(x=>!x.webSession);
  modal(a?'Edit provider account':'Connect a provider',`<form id="account-form" data-id="${esc(id||'')}"><div class="form-grid"><label class="field">Provider<select name="provider" id="provider-select">${standardProviders.map(x=>`<option ${!webSelected&&x.id===p.id?'selected':''} value="${x.id}">${esc(x.name)}</option>`).join('')}<option value="web" ${webSelected?'selected':''}>Web Providers</option></select></label><label class="field" id="web-provider-field" ${webSelected?'':'hidden'}>Web provider<select name="webProvider" id="web-provider-select">${webProviders.map(x=>`<option ${x.id===selectedWeb?.id?'selected':''} value="${x.id}">${esc(x.name)}</option>`).join('')}</select></label><label class="field" id="web-transport-field" ${webSelected?'':'hidden'}>Transport<select name="webTransport" id="web-transport-select"><option value="api-v2" ${a?.webOptions?.transport!=='ui-v1'?'selected':''}>Web API V2 · no provider tabs</option><option value="ui-v1" ${a?.webOptions?.transport==='ui-v1'?'selected':''}>UI bridge V1 · uses a provider tab</option></select></label><label class="field">Account name<input name="name" id="account-name" value="${esc(a?.name || p.name+' · Personal')}" maxlength="100" required></label><label class="field full" id="api-key-field" ${webSelected?'hidden':''}>API key<input name="apiKey" type="password" autocomplete="off" placeholder="${a?.hasKey?'Key saved. Leave blank to keep it.':'Paste your provider API key'}"><span class="hint">${extension&&mode==='standalone'?'Saved in this Chrome profile.':'Saved encrypted locally.'} <a id="key-docs" href="${esc(p.docs)}" target="_blank" rel="noreferrer">Get a provider key ↗</a></span></label><label class="field full" id="base-url-field" ${webSelected?'hidden':''}>API base URL<input name="baseUrl" id="account-base-url" value="${esc(a?.baseUrl || p.baseUrl)}" placeholder="${p.id==='cloudflare'?'https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/v1':'https://…/v1'}" type="url" ${webSelected?'':'required'}><span class="hint">Include /v1 where required. Credentials are sent to this endpoint.</span></label>${extension&&mode==='standalone'?'':`<label class="field full" id="proxy-field" ${webSelected?'hidden':''}>HTTP(S) proxy URL · optional<input name="proxyUrl" value="${esc(a?.proxyUrl||'')}" type="url" placeholder="http://127.0.0.1:8080"><span class="hint">Routes outgoing provider requests through this proxy. No credentials in the URL.</span></label>`}</div><section class="section-space" id="web-options" ${webSelected?'':'hidden'}><h3>Web account options</h3><label class="field">Preferred model<input name="webModel" list="web-model-options" value="${esc(a?.webOptions?.model||'auto')}" maxlength="200" placeholder="auto"><datalist id="web-model-options"><option value="auto">Use the provider’s default model</option>${(modelCache.get(a?.id)||[]).map(m=>`<option value="${esc(m.id)}">${esc(m.name||m.id)}</option>`).join('')}</datalist><span class="hint">Routes can override this. Load models to read the selected transport’s catalog or type an exact model ID.</span></label><label class="check"><input type="checkbox" name="webImages" ${a?.webOptions?.images!==false?'checked':''}>Allow images where this transport supports them</label><label class="check"><input type="checkbox" name="webTools" ${a?.webOptions?.tools!==false?'checked':''}>Allow function calls where this transport supports them</label><p class="hint" id="web-feature-note">Tool calls are returned in the standard API format for the calling app to execute; the router does not run the tools itself.</p></section><p class="hint" id="web-session-note" ${webSelected?'':'hidden'}></p><h3 id="capabilities-heading" ${webSelected?'hidden':''}>Allowed API capabilities</h3><div class="check-wrap" id="capabilities" ${webSelected?'hidden':''}>${p.capabilities.map(c=>`<label class="check"><input type="checkbox" name="capability" value="${c}" ${(!a||a.capabilities.includes(c))?'checked':''}>${esc(c)}</label>`).join('')}</div><label class="check"><input type="checkbox" name="enabled" ${a?.enabled!==false?'checked':''}>Enable this account</label>${a?button('Delete account','delete-account',a.id,'small danger quiet'):''}${formActions(a?'Save account':'Connect account')}</form>`);
  syncProviderAccountFields({ resetName:false });
}
function syncProviderAccountFields({resetName=true}={}) {
  const form=$('#account-form');if(!form)return;
  const isWeb=$('#provider-select').value==='web',selected=provider(isWeb?$('#web-provider-select').value:$('#provider-select').value);
  $('#web-provider-field').hidden=!isWeb;$('#web-transport-field').hidden=!isWeb;$('#web-session-note').hidden=!isWeb;$('#api-key-field').hidden=isWeb;$('#base-url-field').hidden=isWeb;$('#base-url-field input').required=!isWeb;
  $('#web-options').hidden=!isWeb;
  $('#proxy-field')?.toggleAttribute('hidden',isWeb);$('#capabilities-heading').hidden=isWeb;$('#capabilities').hidden=isWeb;
  if(!selected){$('#web-session-note').textContent='No web session providers are available in this Router configuration.';return;}
  $('#account-base-url').value=selected.baseUrl;$('#key-docs').href=selected.docs;
  const transport=$('#web-transport-select')?.value||'api-v2';
  const directNotes={
    'gemini-web':'V2 sends background HTTP requests with the signed-in Gemini session. Full-router checks returned text, inline image recognition and prompt-emulated function calls. Gemini’s private RPC and image upload can change or reject extension requests.',
    'claude-web':'V2 sends background HTTP requests with the signed-in Claude session. Full-router checks returned text and native function calls. Inline images are unsupported because the current web upload flow does not expose an attachable file ID; Cloudflare may also reject background requests.',
    'chatgpt-web':'V2 never opens a ChatGPT tab. Model discovery works, but the current signed-in session requires Sentinel proof, Turnstile and so challenge values that V2 does not produce. V2 returns an explicit error instead of opening a provider tab. Select V1 only if you accept its provider tab, or use an official API account.',
    'grok-web':'V2 routes directly over background HTTP without opening a Grok tab. It loads the modes currently available to this signed-in account. Live full-router checks passed text, inline PNG image input, and streamed function-call output on the Fast mode. Function calls are prompt-emulated; Router does not execute them. Grok’s private web protocol and anti-bot checks may change.'
  };
  $('#web-session-note').textContent=transport==='ui-v1'?'V1 drives the provider page through a dedicated tab. It can open an inactive tab for routing and the Open session action can activate it.':directNotes[selected.id]||'V2 uses background HTTP and does not create, inspect, or manipulate provider tabs.';
  $('#web-feature-note').textContent=transport==='api-v2'&&selected.id==='claude-web'?'Claude V2 supports native function calls. Inline image parts are currently unsupported because Claude’s web upload response provides no file ID for completion. Tool calls are returned for the calling app to execute; Router does not run tools.':transport==='api-v2'&&selected.id==='gemini-web'?'Gemini V2 supports inline images and asks the model to return function calls in a checked JSON format. Live full-router checks passed both paths. Tool calls are emulated, not a native Gemini tool API, and Router does not execute them.':transport==='api-v2'&&selected.id==='grok-web'?'Grok V2 loads account-available modes and supports text, inline PNG/JPEG/WebP/GIF images, and prompt-emulated function calls. Live full-router checks passed image input and a streamed function-call response on Fast mode. Router returns calls for the app to execute and never runs tools.':transport==='api-v2'&&selected.id==='chatgpt-web'?'Chat completion is unavailable in V2 while this signed-in session requires per-request Sentinel proof, Turnstile and so values. Model discovery works, but V2 returns an explicit error instead of opening a provider tab.': 'Tool calls are returned in the standard API format for the calling app to execute; Router does not run tools. Provider support depends on the selected transport.';
  if(resetName)$('#account-name').value=selected.name+' · Personal';
  if(isWeb)$('#capabilities').innerHTML='<label class="check"><input type="checkbox" name="capability" value="chat" checked>chat</label>';
  else $('#capabilities').innerHTML=selected.capabilities.map(c=>`<label class="check"><input type="checkbox" name="capability" value="${c}" checked>${esc(c)}</label>`).join('');
}
async function requestWebProviderPermission(providerId,transport='api-v2') {
  if(!extension)throw new Error('Open Router in Chrome to grant access to a signed-in provider session.');
  const selected=provider(providerId);if(!selected?.webSession)throw new Error('Choose a web provider.');
  const origin=new URL(selected.baseUrl).origin;
  const permissions=transport==='ui-v1'?['scripting']:[];
  const origins=[origin+'/*'];if(transport==='api-v2'&&providerId==='gemini-web')origins.push('https://push.clients6.google.com/*');
  const request={origins,...(permissions.length?{permissions}:{})};
  if(!await chrome.permissions.request(request))throw new Error(`Allow ${extensionPermissionName(transport)} access to ${selected.name}.`);
}
function extensionPermissionName(transport){return transport==='ui-v1'?'the provider page bridge':'background web access for its signed-in session';}
function routeDialog(id) {
  if(!routeAccounts().length){toast('Connect a provider account or sign in to a Codex account in Deck first.');return;}
  const r=state.config.routes.find(r=>r.id===id);
  const known=routeAccounts();pendingRoute=r?structuredClone(r):{id:'',name:'',strategy:'ordered',failover:true,retryAuthErrors:false,enabled:true,targets:[{account:known[0].id,model:defaultTargetModel(known[0].id)}]};
  modal(r?'Edit route':'Create route',`<form id="route-form" data-edit="${esc(id||'')}"><div class="form-grid"><label class="field">Route name<input name="name" value="${esc(pendingRoute.name)}" placeholder="Everyday assistant" maxlength="100" required></label><label class="field">Model alias<input name="id" value="${esc(pendingRoute.id)}" placeholder="everyday" pattern="[a-zA-Z0-9][a-zA-Z0-9._\-]{0,79}" ${r?'readonly':''} required></label><label class="field full">Selection strategy<select name="strategy"><option value="ordered">Ordered · primary, then fallbacks</option><option ${pendingRoute.strategy==='round-robin'?'selected':''} value="round-robin">Round robin · spread calls across accounts</option></select></label></div><div class="section-head"><h3>Destinations, in order</h3>${button('+ Add target','add-target','','small')}</div><div id="targets"></div><datalist id="model-options"></datalist><p class="hint">Set the exact model ID for each web route target; Router sends it with the request. Use “Load models” to read the selected transport’s catalog. API accounts use exact upstream IDs; Codex uses <code>default</code>.</p><label class="check"><input type="checkbox" name="failover" ${pendingRoute.failover?'checked':''}>Retry another target on throttling or temporary failure</label><label class="check"><input type="checkbox" name="retryAuthErrors" ${pendingRoute.retryAuthErrors?'checked':''}>Also fail over on authentication errors (401 / 403)</label><label class="check"><input type="checkbox" name="enabled" ${pendingRoute.enabled?'checked':''}>Enable this route</label>${r?button('Delete route','delete-route',r.id,'small danger quiet'):''}${formActions(r?'Save route':'Create route')}</form>`);
  renderTargets();
}
function syncTargets() { document.querySelectorAll('.target-editor').forEach((row,i)=>{pendingRoute.targets[i]={account:row.querySelector('select[name="targetAccount"]').value,model:row.querySelector('[name="targetModel"]').value};}); }
function renderTargets() {
  const known=routeAccounts();pendingRoute.targets.forEach(t=>{if(!t.model&&(nativeAccount(t.account)||provider(account(t.account)?.provider)?.webSession))t.model=defaultTargetModel(t.account);});
  $('#targets').innerHTML=pendingRoute.targets.map((t,i)=>{const selected=known.find(a=>a.id===t.account),web=provider(selected?.provider)?.webSession;const options=known.map(a=>`<option ${a.id===t.account?'selected':''} value="${esc(a.id)}">${esc(a.name)}${a.enabled?'':' (paused)'}</option>`);if(!selected)options.unshift(`<option selected value="${esc(t.account)}">${esc(accountLabel(t.account))} (unavailable)</option>`);const discovered=modelCache.get(t.account)||[],preferred=selected?.webOptions?.model||'auto';const modelOptions=[...discovered].filter(m=>m.id!==preferred);if(t.model&&t.model!==preferred&&!modelOptions.some(m=>m.id===t.model))modelOptions.unshift({id:t.model,name:t.model});const modelField=web?`<div class="field model-field"><label for="target-model-${i}">Model</label><input id="target-model-${i}" name="targetModel" list="target-model-options-${i}" value="${esc(t.model||preferred)}" placeholder="${esc(preferred)}" required><datalist id="target-model-options-${i}"><option value="${esc(preferred)}">Account preference</option>${modelOptions.map(m=>`<option value="${esc(m.id)}">${esc(m.name||m.id)}</option>`).join('')}</datalist>${button('Load models','route-models',t.account,'small quiet')}</div>`:`<label class="field model-field">Model<input name="targetModel" value="${esc(t.model)}" placeholder="${selected?.native?'default or Codex model ID':'Upstream model ID'}" list="model-options" required></label>`;return `<div class="target-editor"><span class="order">${String(i+1).padStart(2,'0')}</span><label class="field">Account<select name="targetAccount">${options.join('')}</select></label>${modelField}<div class="target-controls">${button('↑','up-target',String(i),'small quiet')}${button('×','remove-target',String(i),'small quiet')}</div></div>`;}).join('');
}
async function loadRouteModels(accountId){const result=await api(`/admin/accounts/${accountId}/models`);const models=result.models||[];modelCache.set(accountId,models);if($('#route-form')){syncTargets();renderTargets();}return models;}
function clientRouteFields(routes) {
  const selected=routes===undefined?(state.config.routes.length?state.config.routes.map(route=>route.id):['*']):routes;
  const all=selected.includes('*');
  return `<fieldset class="route-access"><legend>Allowed routes</legend><label class="check route-all-option"><input type="checkbox" name="routes" value="*" ${all?'checked':''}><span><strong>All routes</strong><small>Includes routes added in the future.</small></span></label><div class="route-choice-list${all?' locked':''}" id="client-route-options">${state.config.routes.map(route=>`<label class="check"><input type="checkbox" name="routes" value="${esc(route.id)}" ${selected.includes(route.id)?'checked':''} ${all?'disabled':''}><span>${esc(route.name)} <small>${esc(route.id)}</small></span></label>`).join('')}${state.config.routes.length?'':'<p class="hint">No routes exist yet. Choosing All routes grants access as routes are added.</p>'}</div></fieldset>`;
}
function syncClientRouteFields(form) {
  const all=form.querySelector('input[name="routes"][value="*"]'),options=form.querySelector('#client-route-options');
  if(!all||!options)return;
  options.classList.toggle('locked',all.checked);
  options.querySelectorAll('input[name="routes"]').forEach(input=>input.disabled=all.checked);
}
function clientDialog(id) {
  const client=id?state.config.clients.find(item=>item.id===id):null;
  if(id&&!client){toast('Refresh the integration keys first.');return;}
  modal(client?'Edit integration key':'Create integration key',`<form id="client-form" data-id="${esc(id||'')}"><label class="field">Integration name<input name="name" value="${esc(client?.name||'')}" placeholder="My coding app" maxlength="100" required></label><div class="form-grid"><label class="field">Requests per minute<input name="rpm" type="number" min="1" max="600" value="${client?.rpm??60}" required></label><label class="check client-enabled"><input type="checkbox" name="enabled" ${client?.enabled!==false?'checked':''}>Key is active</label></div>${clientRouteFields(client?.routes)}<p class="hint">This key grants API access only. It cannot read or change your settings.</p>${formActions(client?'Save changes':'Create key')}</form>`);
  syncClientRouteFields($('#client-form'));
}
function deckDialog(id) {
  const a=state.deck?.accounts.find(a=>a.id===id);
  if(id&&!a){toast('Refresh the Deck account list first.');return;}
  modal(id?`Open ${id}`:'Create Deck account',`<form id="deck-form" data-id="${esc(id||'')}">${id?`<p class="hint">${esc(a.harness)} · ${esc(a.provider)} · separate native account profile</p>`:`<label class="field">Account name<input name="account" pattern="[a-zA-Z][a-zA-Z0-9_\-]{0,39}" maxlength="40" required placeholder="work-claude"><span class="hint">Start with a letter; use letters, numbers, underscores or dashes.</span></label><div class="form-grid"><label class="field">Harness<select name="harness" id="harness-select">${Object.keys(state.deck?.harnesses||{Codex:[]}).map(h=>`<option>${h}</option>`).join('')}</select></label><label class="field">Login provider<select name="provider" id="deck-provider"><option>ChatGPT</option></select></label></div><p class="hint">Enable optional harnesses in Deck Settings → Harnesses before creating their accounts.</p>`}${id&&a.harness==='Codex'?`<label class="field section-space">Native Deck failover<select name="failover"><option value="Off">Off</option><option value="Ordered">Ordered</option><option value="Best">Best available</option></select></label><label class="check"><input type="checkbox" name="pool">Open as a Codex account pool</label>`:''}<p class="hint section-space">A Windows terminal opens for native login or interaction. Gateway routing is configured separately through a harness's custom API provider settings.</p>${formActions(id?'Open terminal':'Create in terminal')}</form>`);
}
function connectDialog(message='') {
  if(extension&&connectionKind==='local'){connectLocalServerDialog(message);return;}
  if(extension){modal('Connect a Router server',`<form id="pair-form"><p class="hint">For a Deck-managed server, start it in Deck Settings → AI Router and approve the matching code below. Pairing connects this extension to the Router server and imports provider accounts and routes saved in this browser.</p><label class="field section-space">Deck server URL<input name="base" type="url" value="${esc(base)}" required></label><p id="pair-status" role="status" class="notice">${esc(message||'Default server: localhost port 5147.')}</p>${formActions('Request Deck pairing')}</form><div class="form-actions">${button('Connect to local server with owner key','connect-local','','small quiet')}</div>`);return;}
  modal('Connect your local gateway',`<form id="connect-form"><p class="hint">Start the gateway with Start-AIDeckRouter.cmd. Copy the owner key from the private dashboard URL shown at startup.</p><label class="field section-space">Gateway URL<input name="base" type="url" value="${esc(base)}" required></label><label class="field">Owner key<input name="token" type="password" autocomplete="off" value="${esc(token)}" required><span class="hint">${extension?'Saved in Chrome local storage on this machine.':'Kept in this browser tab session.'} Provider keys stay in the gateway.</span></label><p class="error-message" role="alert">${esc(message)}</p><div class="form-actions"><button class="primary" type="submit">Connect gateway</button></div></form>`);
}
function connectLocalServerDialog(message='') {
  modal('Connect local API server',`<form id="local-server-form"><p class="hint">Start this project's server with Start-AIDeckRouter.cmd, then connect here with its owner key. Your saved browser accounts, keys, and routes will be imported into the server configuration so the extension and API clients use the same settings.</p><label class="field section-space">Local server URL<input name="base" type="url" value="${esc(base)}" required></label><label class="field">Owner key<input name="token" type="password" autocomplete="off" value="${esc(token)}" required><span class="hint">Copy it from the private dashboard URL printed when the server starts. It is saved in Chrome local storage for this connection.</span></label><p class="error-message" role="alert">${esc(message)}</p>${formActions('Connect and import settings')}</form>`);
}
function renderMessages() {
  if(!$('#messages'))return;
  $('#messages').innerHTML=chat.length?chat.map(m=>`<div class="message ${m.role}"><span class="role">${m.role==='user'?'You':'Assistant'}${m.failed?' · INTERRUPTED':''}</span>${esc(m.content||(m.role==='assistant'?'Waiting for a response…':''))}${m.attachments?.length?`<div class="message-images">${m.attachments.map(image=>image.previewUrl?`<figure><img src="${esc(image.previewUrl)}" alt="${esc(image.name||'Attached image')}"><figcaption>${esc(image.name||'Image')}</figcaption></figure>`:`<span class="missing-image">Image unavailable: ${esc(image.name||'attachment')}</span>`).join('')}</div>`:''}${m.tools?`<pre>${esc(m.tools)}</pre>`:''}</div>`).join(''):`<div class="chat-empty"><span class="empty-symbol">⌁</span><h2>Same interface. Any destination.</h2><p>Choose a route and send your first message.</p></div>`;
  $('#messages').scrollTop=$('#messages').scrollHeight;
  renderPendingImages();
  renderHistoryList();
}
function renderPendingImages(){
  const strip=$('#chat-attachments');if(!strip)return;
  strip.innerHTML=pendingImages.map(image=>`<div class="attachment-chip"><img src="${esc(image.previewUrl)}" alt=""><span>${esc(image.name)}</span>${button('×','remove-image',image.id,'small quiet')}</div>`).join('');
}
async function addPendingImages(files){
  const selected=Array.from(files||[]);if(!selected.length)return;
  const conversationImageCount=chat.reduce((sum,message)=>sum+(message.attachments||[]).length,0);
  if(conversationImageCount+pendingImages.length+selected.length>MAX_PLAYGROUND_IMAGES)throw new Error('A conversation can contain up to 8 images. Start a new conversation to attach more.');
  const conversationImageBytes=chat.reduce((sum,message)=>sum+(message.attachments||[]).reduce((bytes,image)=>bytes+(image.size||0),0),0);
  if(conversationImageBytes+pendingImages.reduce((sum,image)=>sum+image.size,0)+selected.reduce((sum,file)=>sum+file.size,0)>MAX_PLAYGROUND_IMAGE_BYTES)throw new Error('Images may total at most 10 MB per conversation. Start a new conversation to attach more.');
  const allowed=new Set(['image/png','image/jpeg','image/webp']);
  for(const file of selected){if(!allowed.has(file.type))throw new Error('Choose PNG, JPEG, or WebP images.');if(file.size>MAX_PLAYGROUND_FILE_BYTES)throw new Error('Each image must be 5 MB or smaller.');}
  if(pendingImages.reduce((sum,image)=>sum+image.size,0)+selected.reduce((sum,file)=>sum+file.size,0)>MAX_PLAYGROUND_IMAGE_BYTES)throw new Error('Images may total at most 10 MB per message.');
  const added=[];
  try{
    for(const file of selected){const image={id:crypto.randomUUID(),name:(file.name||'attached-image').slice(0,180),type:file.type,size:file.size,blob:file,previewUrl:URL.createObjectURL(file)};try{image.dataUrl=await dataUrlFor(file);await saveImageBlob(image);added.push(image);}catch(error){URL.revokeObjectURL(image.previewUrl);await removeImageBlobs([image.id]).catch(()=>{});throw error;}}
    pendingImages.push(...added);renderPendingImages();syncChatControls();
  }catch(error){for(const image of added)URL.revokeObjectURL(image.previewUrl);await removeImageBlobs(added.map(image=>image.id)).catch(()=>{});throw error;}
}
async function removePendingImage(id){const image=pendingImages.find(item=>item.id===id);if(!image)return;pendingImages=pendingImages.filter(item=>item.id!==id);URL.revokeObjectURL(image.previewUrl);await removeImageBlobs([id]);renderPendingImages();syncChatControls();}
async function clearPendingImages(){const images=pendingImages;pendingImages=[];for(const image of images)URL.revokeObjectURL(image.previewUrl);await removeImageBlobs(images.map(image=>image.id)).catch(()=>{});renderPendingImages();}
function renderPlaygroundPanel() {
  const panel=$('#playground-panel');if(!panel)return;
  const toggle=$('#history-toggle'),count=$('#history-count');if(count)count.textContent=String(chatHistory.length);if(toggle){toggle.setAttribute('aria-pressed',String(playgroundPanel==='history'));toggle.title=playgroundPanel==='history'?'Show request details':'Show conversation history';}
  if(playgroundPanel==='history'){
    panel.innerHTML=`<div class="playground-panel-head"><h2>History</h2>${button('+ New','new-chat','','small quiet')}</div><div class="conversation-list" id="conversation-list"></div>`;renderHistoryList();return;
  }
  const r=state.config.routes.find(route=>route.id===$('#chat-route')?.value),conversation=chatHistory.find(item=>item.id===activeConversationId),turns=chat.filter(message=>message.role==='user').length,imageCount=chat.reduce((n,message)=>n+(message.attachments||[]).length,0);
  const status=chatRun?.conversationId===activeConversationId?chatRun:null,detachedRequest=!!chatAbort&&!status;
  const statusCopy=detachedRequest?'Stopping previous request':!status?'Ready · Send a prompt':status.status==='connecting'?'Connecting to provider':status.status==='waiting'?`Waiting · ${status.account||'provider'}`:status.status==='streaming'?`Streaming · ${status.account||'provider'}`:status.status==='stopping'?'Stopping request':status.status==='stopped'?'Stopped':status.status==='error'?`Failed · ${status.error||'Request error'}`:status.status==='completed'?`Done · ${(status.ms/1000).toFixed(1)}s${status.tokens===null?'':` · ${status.tokens} tokens`}`:'Ready';
  const statusKind=status?.status==='error'?'error':status?.status==='completed'?'success':detachedRequest||status?.status==='streaming'||status?.status==='connecting'||status?.status==='waiting'||status?.status==='stopping'?'working':'';
  const targets=r?.targets||[];
  panel.innerHTML=`<div class="playground-panel-head"><h2>Request details</h2>${badge(r?.strategy==='ordered'?'Ordered':'Round robin',r?'':'neutral')}</div>${r?`<div class="inspector-row"><span>Route</span><strong title="${esc(r.id)}">${esc(r.id)}</strong></div><div class="inspector-section"><div class="inspector-section-head"><span>Destinations</span><small>${targets.length}</small></div><div class="destination-list">${targets.map((target,index)=>{const a=account(target.account),d=nativeAccount(target.account),p=provider(a?.provider),icon=d?(String(d.harness).toLowerCase().includes('codex')?'openai':String(d.harness).toLowerCase().includes('claude')?'claude':String(d.harness).toLowerCase().includes('gemini')?'gemini':String(d.harness).toLowerCase().includes('grok')?'grok':null):providerIcon(p?.id),model=target.model==='default'&&d?'Default model':target.model,name=`${index===0?'Primary':'Fallback'} · ${accountLabel(target.account)}`;return `<div class="destination-row" title="${esc(`${name} · ${model}`)}">${icon?logoImage(icon,18):''}<span class="destination-account">${esc(name)}</span><span class="destination-model">${esc(model)}</span></div>`;}).join('')}</div></div>`:`<div class="inspector-row"><span>Route</span><strong>Unavailable</strong></div>`}<div class="inspector-row"><span>Conversation</span><strong>${conversation?`${turns} turn${turns===1?'':'s'}${imageCount?` · ${imageCount} image${imageCount===1?'':'s'}`:''}`:'New'}</strong></div><div class="request-status ${statusKind}" role="status"><span class="status-dot"></span><span title="${esc(status?.error||statusCopy)}">${esc(statusCopy)}</span></div>`;
}
function renderRouteSummary() {
  renderPlaygroundPanel();
}
function startNewConversation(){
  void saveActiveConversation();chatAbort?.abort();revokePreviews(chat);void clearPendingImages();activeConversationId=null;chat=[];chatRun=null;playgroundPanel='details';const select=$('#chat-route');if(select?.selectedOptions[0]?.disabled){const active=[...select.options].find(option=>!option.disabled);if(active){select.value=active.value;selectedRouteId=active.value;}}renderMessages();renderHistoryList();renderRouteSummary();syncChatControls();
}
async function openConversation(id){
  if(!chatHistory.some(item=>item.id===id))return;
  void saveActiveConversation();chatAbort?.abort();revokePreviews(chat);await clearPendingImages();const conversation=chatHistory.find(item=>item.id===id);activeConversationId=id;chatRun=null;chat=await hydrateMessages(conversation.messages);
  const select=$('#chat-route');if(select&&conversation.route){let option=[...select.options].find(option=>option.value===conversation.route);if(!option){option=document.createElement('option');option.value=conversation.route;option.textContent=`${conversation.route} · unavailable`;option.disabled=true;select.append(option);}select.value=conversation.route;selectedRouteId=conversation.route;}
  renderMessages();renderRouteSummary();syncChatControls();
}
function deleteConversation(id){
  const conversation=chatHistory.find(item=>item.id===id);if(!conversation||!confirm(`Delete “${conversation.title||'New conversation'}” from this browser?`))return;
  const removedIds=(conversation.messages||[]).flatMap(message=>(message.attachments||[]).map(image=>image.id));chatHistory=chatHistory.filter(item=>item.id!==id);if(activeConversationId===id){chatAbort?.abort();revokePreviews(chat);activeConversationId=null;chat=[];chatRun=null;renderMessages();renderRouteSummary();syncChatControls();}
  writeHistory().then(()=>removeImageBlobs(removedIds)).catch(()=>toast('Conversation history could not be updated.'));renderHistoryList();
}
async function sendChat(form) {
  if(chatAbort){if(chatRun?.conversationId===activeConversationId){chatRun={...chatRun,status:'stopping'};renderPlaygroundPanel();}chatAbort.abort();return;}
  const prompt=form.prompt.value.trim();if(!prompt&&!pendingImages.length)return;
  const priorImageBytes=chat.reduce((sum,message)=>sum+(message.attachments||[]).reduce((n,image)=>n+(image.size||0),0),0);
  const priorImageCount=chat.reduce((sum,message)=>sum+(message.attachments||[]).length,0);
  if(priorImageCount+pendingImages.length>MAX_PLAYGROUND_IMAGES){toast('This conversation has reached its 8 image limit. Start a new conversation to attach more images.');return;}
  if(priorImageBytes+pendingImages.reduce((sum,image)=>sum+image.size,0)>MAX_PLAYGROUND_IMAGE_BYTES){toast('This conversation has reached its 10 MB image limit. Start a new conversation to attach more images.');return;}
  if(!activeConversationId)activeConversationId=crypto.randomUUID();
  const attachments=pendingImages;
  let messages;try{messages=chat.filter(m=>!m.failed).map(message=>chatRequestMessage(message));messages.push(chatRequestMessage({role:'user',content:prompt,attachments}));}catch(error){toast(error.message);return;}
  pendingImages=[];
  chat.push({role:'user',content:prompt,attachments});const reply={role:'assistant',content:''};chat.push(reply);form.prompt.value='';renderMessages();const requestConversationId=activeConversationId,requestChat=chat,requestRoute=$('#chat-route').value;await saveActiveConversation(requestRoute,requestConversationId,requestChat).catch(()=>{});
  const controller=new AbortController(),status=$('#chat-status'),startedAt=performance.now();let reader;
  chatAbort=controller;chatRun={conversationId:requestConversationId,status:'connecting',account:'',error:'',startedAt};syncChatControls();renderPlaygroundPanel();status.textContent='Routing your request…';
  try {
    const body={model:$('#chat-route').value,messages,stream:true,stream_options:{include_usage:true}};
    const response=extension&&mode==='standalone'?await extensionClient.standaloneChat(body,controller.signal):await fetch(base+'/v1/chat/completions',{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body),signal:controller.signal});
    if(!response.ok){const value=await response.json();throw new Error(value.error?.message||'Request failed.');}
    const selected=accountLabel(response.headers.get('x-aideck-account'))||'provider',buffered=response.headers.get('x-aideck-streaming')==='buffered';if(chatRun?.conversationId===requestConversationId){chatRun={...chatRun,status:buffered?'waiting':'streaming',account:selected};renderPlaygroundPanel();}status.textContent=buffered?`Waiting for a complete response from ${selected}`:`Streaming from ${selected}`;
    reader=response.body.getReader();const decoder=new TextDecoder();let buffer='',totalTokens=null;
    while(true){const {done,value}=await reader.read();if(done)break;buffer+=decoder.decode(value,{stream:true});buffer=buffer.replace(/\r\n/g,'\n');let end;while((end=buffer.indexOf('\n\n'))>=0){const frame=buffer.slice(0,end);buffer=buffer.slice(end+2);for(const line of frame.split('\n')){if(!line.startsWith('data:'))continue;const data=line.slice(5).trim();if(data==='[DONE]'||!data)continue;const chunk=JSON.parse(data);if(chunk.error)throw new Error(chunk.error.message);const delta=chunk.choices?.[0]?.delta;if(delta?.content)reply.content+=delta.content;if(delta?.tool_calls)reply.tools=(reply.tools||'')+JSON.stringify(delta.tool_calls);if(chunk.usage)totalTokens=chunk.usage.total_tokens;renderMessages();scheduleHistorySave(requestConversationId,requestChat,requestRoute);}}}
    if(!reply.content&&!reply.tools)throw new Error('Provider returned no visible text or tool calls.');
    if(chatRun?.conversationId===requestConversationId){chatRun={...chatRun,status:'completed',ms:performance.now()-startedAt,tokens:totalTokens,account:selected};renderPlaygroundPanel();}status.textContent=`Completed via ${selected}${totalTokens===null?'':` · ${totalTokens} tokens`}`;
  }catch(e){reply.failed=true;reply.content+=(reply.content?'\n\n':'')+(e.name==='AbortError'?'Request stopped.':e.message);if(chatRun?.conversationId===requestConversationId){chatRun={...chatRun,status:e.name==='AbortError'?'stopped':'error',error:e.name==='AbortError'?'':e.message};renderPlaygroundPanel();}renderMessages();status.textContent='Request ended.';}
  finally{if(reader){await reader.cancel().catch(()=>{});reader.releaseLock();}if(chatAbort===controller)chatAbort=null;syncChatControls();await saveActiveConversation(requestRoute,requestConversationId,requestChat).catch(()=>{const currentStatus=$('#chat-status');if(currentStatus&&activeConversationId===requestConversationId)currentStatus.textContent='Conversation history could not be saved.';});if(token||extension&&mode==='standalone')refresh(false).catch(()=>{});}
}
function chatRequestMessage(message){
  const attachments=message.attachments||[];if(attachments.some(image=>!image.dataUrl))throw new Error('A saved image is missing from this browser. Remove it and attach the image again.');
  if(!attachments.length)return {role:message.role,content:message.content||''};
  const content=[];if(message.content)content.push({type:'text',text:message.content});
  for(const image of attachments)content.push({type:'image_url',image_url:{url:image.dataUrl}});
  return {role:message.role,content};
}
document.addEventListener('click',async event=>{
  const el=event.target.closest('[data-action]');if(!el)return;const action=el.dataset.action,id=el.dataset.id;
  try{
    if(action==='close'){pairingAbort?.abort();$('#dialog').close();return;}
    if(action==='connect'){connectDialog();return;}
    if(action==='disconnect'){chatAbort?.abort();token='';state=null;sessionStorage.removeItem('aideck-pair');if(extension){const saved=await chrome.storage.local.get('bridgeModes');mode='standalone';connectionKind='standalone';bridge=saved.bridgeModes?.standalone||bridge;await chrome.storage.local.set({mode,connectionKind,bridge});await chrome.storage.local.remove('pair');}$('#connection').classList.remove('connected');$('#connection-label').textContent='Connect gateway';$('#main').innerHTML=empty('Gateway disconnected.','Your provider accounts and routes remain saved locally.');connectDialog();return;}
    if(action==='retry-workspace-merge'){
      const result=await mergeSavedChromeWorkspace(base,token,bridge.clientKey);workspaceMigrationError='';await refresh();toast(result?.alreadyImported?'Router settings are up to date.':result?`Imported ${result.accounts} provider account${result.accounts===1?'':'s'} and ${result.routes} route${result.routes===1?'':'s'}.`:'There are no saved browser providers or routes to import.');return;
    }
    if(action==='connect-local'){connectLocalServerDialog();return;}
    if(action==='refresh'){await refresh();return;}
    if(action==='new-account')accountDialog(null,id);
    if(action==='edit-account')accountDialog(id);
    if(action==='new-route')routeDialog();
    if(action==='edit-route')routeDialog(id);
    if(action==='new-client')clientDialog();
    if(action==='edit-client')clientDialog(id);
    if(action==='new-deck')deckDialog();
    if(action==='deck-open')deckDialog(id);
    if(action==='add-target'){syncTargets();if(pendingRoute.targets.length>=16)throw new Error('At most 16 targets per route.');const available=routeAccounts();if(!available.length)throw new Error('Connect a provider or sign in to a Codex account in Deck first.');pendingRoute.targets.push({account:available[0].id,model:defaultTargetModel(available[0].id)});renderTargets();}
    if(action==='up-target'){syncTargets();const i=Number(id);if(i>0)[pendingRoute.targets[i],pendingRoute.targets[i-1]]=[pendingRoute.targets[i-1],pendingRoute.targets[i]];renderTargets();}
    if(action==='remove-target'){syncTargets();if(pendingRoute.targets.length<2)throw new Error('Keep at least one target.');pendingRoute.targets.splice(Number(id),1);renderTargets();}
    if(action==='models'){el.disabled=true;const result=await api(`/admin/accounts/${id}/models`),a=account(id),web=provider(a?.provider)?.webSession;if(web)modelCache.set(id,result.models||[]);modal('Available models',`<p class="hint">${web?'These are the model IDs returned by this account’s selected transport. You can select one on a route or enter an exact ID.':'Copy an exact model identifier into a route destination.'}</p>${(result.models||[]).map(m=>`<div class="integration-row"><code>${esc(m.id)}</code>${button('Copy','copy',m.id,'small')}</div>`).join('')||'<p>No model IDs were returned. You can still type a model ID on the route.</p>'}`);}
    if(action==='route-models'){el.disabled=true;const models=await loadRouteModels(id);toast(models.length?`Loaded ${models.length} model ID${models.length===1?'':'s'}.`:'No model IDs returned; type an exact model ID in the field.');}
    if(action==='web-provider-connect'){
      const a=account(id);if(!a||!provider(a.provider)?.webSession)throw new Error('Web provider account not found.');
      if(a.webOptions?.transport!=='ui-v1')throw new Error('Open session is available only for the V1 page bridge.');
      await requestWebProviderPermission(a.provider,'ui-v1');const result=await chrome.runtime.sendMessage({type:'aideck.web-provider',action:'connect',accountId:a.id,provider:a.provider,activate:true});if(!result?.ok)throw new Error(result?.error||'Could not open the provider page.');toast(`Opened ${provider(a.provider).name} for V1 sign-in or model selection.`);
    }
    if(action==='web-provider-access'){
      const a=account(id);if(!a||!provider(a.provider)?.webSession)throw new Error('Web provider account not found.');
      await requestWebProviderPermission(a.provider,a.webOptions?.transport||'api-v2');toast(`Browser access is enabled for ${provider(a.provider).name}.`);
    }
    if(action==='copy'){await navigator.clipboard.writeText(id);toast('Copied to clipboard.');}
    if(action==='delete-account'||action==='delete-route'||action==='delete-client'){
      const noun=action.split('-')[1];
      if(!confirm(`${noun==='client'?'Revoke this integration key':`Delete this ${noun}`}?`))return;
      if(noun==='account'&&provider(account(id)?.provider)?.webSession)await chrome.runtime.sendMessage({type:'aideck.web-provider',action:'disconnect',accountId:id});
      await api(`/admin/${noun==='client'?'clients':noun+'s'}/${id}`,{method:'DELETE'});$('#dialog').close();await refresh();toast(noun==='client'?'Integration key revoked.':`${noun} deleted.`);
    }
    if(action==='new-chat'){startNewConversation();}
    if(action==='toggle-playground-panel'){playgroundPanel=playgroundPanel==='history'?'details':'history';renderPlaygroundPanel();}
    if(action==='open-chat'){await openConversation(id);}
    if(action==='delete-chat'){deleteConversation(id);}
    if(action==='attach-image')$('#image-input')?.click();
    if(action==='remove-image')await removePendingImage(id);
  }catch(e){toast(e.message);}finally{if(action==='models'||action==='route-models')el.disabled=false;}
});
document.addEventListener('change',event=>{
  if(event.target.matches('#client-form input[name="routes"]')){
    const form=$('#client-form');
    if(event.target.value!=='*'&&event.target.checked)form.querySelector('input[name="routes"][value="*"]').checked=false;
    syncClientRouteFields(form);
  }
  if(event.target.id==='image-input'){const files=event.target.files;void addPendingImages(files).catch(error=>toast(error.message)).finally(()=>{event.target.value='';});}
  if(event.target.matches('#targets select[name="targetAccount"]')){
    syncTargets();const row=event.target.closest('.target-editor'),index=Array.from(document.querySelectorAll('.target-editor')).indexOf(row),selected=routeAccounts().find(a=>a.id===event.target.value);if(index>=0){pendingRoute.targets[index]={account:event.target.value,model:defaultTargetModel(event.target.value)};renderTargets();if(provider(selected?.provider)?.webSession)void loadRouteModels(event.target.value).catch(error=>toast(error.message));}
  }
  if(event.target.id==='provider-select'){
    if(event.target.value!=='web')$('#account-form').elements.namedItem('apiKey').value='';syncProviderAccountFields();
  }
  if(event.target.id==='web-provider-select'||event.target.id==='web-transport-select')syncProviderAccountFields();
  if(event.target.id==='harness-select')$('#deck-provider').innerHTML=state.deck.harnesses[event.target.value].map(p=>`<option>${esc(p)}</option>`).join('');
  if(event.target.id==='chat-route'){void saveActiveConversation(selectedRouteId||undefined);revokePreviews(chat);void clearPendingImages();selectedRouteId=event.target.value;chatAbort?.abort();activeConversationId=null;chat=[];chatRun=null;renderMessages();renderRouteSummary();syncChatControls();}
});
document.addEventListener('paste',event=>{
  if(page!=='playground'||chatAbort)return;
  const files=Array.from(event.clipboardData?.items||[]).filter(item=>item.kind==='file'&&item.type.startsWith('image/')).map(item=>item.getAsFile()).filter(Boolean);
  if(!files.length)return;
  event.preventDefault();void addPendingImages(files).catch(error=>toast(error.message));
});
for(const selector of ['#messages','#chat-form'])for(const eventName of ['dragenter','dragover','dragleave','drop'])document.addEventListener(eventName,event=>{
  const zone=event.target.closest?.(selector);if(!zone)return;
  if(eventName==='dragleave'&&event.relatedTarget&&zone.contains(event.relatedTarget))return;
  if(eventName==='dragenter'||eventName==='dragover'){
    if(!Array.from(event.dataTransfer?.types||[]).includes('Files'))return;
    event.preventDefault();zone.classList.add('drag-over');if(event.dataTransfer)event.dataTransfer.dropEffect='copy';return;
  }
  zone.classList.remove('drag-over');
  if(eventName==='drop'&&Array.from(event.dataTransfer?.types||[]).includes('Files')){
    event.preventDefault();const files=Array.from(event.dataTransfer?.files||[]).filter(file=>file.type.startsWith('image/'));
    if(files.length)void addPendingImages(files).catch(error=>toast(error.message));
  }
});
document.addEventListener('submit',async event=>{
  const form=event.target;if(!(form instanceof HTMLFormElement))return;event.preventDefault();const formId=form.getAttribute('id');
  if(formId==='chat-form'){await sendChat(form);return;}
  if(busy)return;busy=true;const submit=form.querySelector('[type=submit]');if(submit)submit.disabled=true;
  const data=new FormData(form),error=form.querySelector('.error-message');if(error)error.textContent='';
  try{
    if(formId==='pair-form'){
      const url=new URL(data.get('base'));if(url.protocol!=='http:'||!['localhost','127.0.0.1'].includes(url.hostname)||url.username||url.password||url.search||url.hash)throw new Error('Use a local HTTP server URL.');
      pairingAbort?.abort();pairingAbort=new AbortController();const signal=pairingAbort.signal;const secret=crypto.randomUUID()+crypto.randomUUID();
      const response=await fetch(url.origin+'/pair',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({secret}),signal:AbortSignal.any([signal,AbortSignal.timeout(5000)])});const pending=await response.json();if(!response.ok)throw new Error(pending.error?.message||'Deck server unavailable.');
      $('#pair-status').textContent=`Pairing code: ${pending.code}. Approve this code in Deck → Settings → AI Router. Request expires in five minutes.`;
      const deadline=Date.now()+300000;let paired=false;
      while(Date.now()<deadline&&!signal.aborted){
        await new Promise(resolve=>{const finish=()=>{clearTimeout(timer);signal.removeEventListener('abort',finish);resolve();};const timer=setTimeout(finish,1500);signal.addEventListener('abort',finish,{once:true});});if(signal.aborted)break;
        const poll=await fetch(url.origin+'/pair/'+pending.id,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({secret}),signal:AbortSignal.any([signal,AbortSignal.timeout(5000)])});const value=await poll.json();if(!poll.ok)throw new Error(value.error?.message||'Pairing failed.');if(value.status!=='approved')continue;
        await saveActiveConversation().catch(()=>{});base=url.origin;token=value.token;mode='deck';connectionKind='deck';const savedModes=await chrome.storage.local.get('bridgeModes');bridge={...(savedModes.bridgeModes?.deck||bridge),clientKey:value.bridgeKey};await chrome.storage.local.set({pair:{base,token},mode,connectionKind,bridge,bridgeModes:{...savedModes.bridgeModes,deck:bridge}});
        try{var imported=await mergeSavedChromeWorkspace(base,token,bridge.clientKey);workspaceMigrationError='';}catch(mergeError){workspaceMigrationError=mergeError.message;}
        await refresh();$('#dialog').close();toast(workspaceMigrationError?`Deck connected. Browser settings need another try: ${workspaceMigrationError}`:imported&&!imported.alreadyImported?`Deck connected. Imported ${imported.accounts} provider${imported.accounts===1?'':'s'} and ${imported.routes} route${imported.routes===1?'':'s'}.`:'Deck connected. Router settings are ready.');paired=true;break;
      }
      if(!paired&&!signal.aborted)throw new Error('Pairing expired. Request a new code.');
    }
    if(formId==='local-server-form'){
      const url=new URL(data.get('base'));if(url.protocol!=='http:'||!['localhost','127.0.0.1'].includes(url.hostname)||url.username||url.password||url.search||url.hash)throw new Error('Use a local HTTP server URL, such as http://127.0.0.1:5147.');
      const ownerToken=String(data.get('token')).trim();const response=await fetch(url.origin+'/admin/state',{headers:{Authorization:`Bearer ${ownerToken}`},signal:AbortSignal.timeout(10000)});const value=await response.json().catch(()=>({}));if(!response.ok)throw new Error(value.error?.message||`Could not connect to the local server (${response.status}).`);
      await saveActiveConversation().catch(()=>{});const saved=await chrome.storage.local.get(['pair','bridge','bridgeModes']);const sameServer=saved.pair?.base===url.origin;const savedBridge=saved.bridgeModes?.local||saved.bridgeModes?.standalone||saved.bridge||{allowedExtensionIds:[],clientKey:''};bridge=sameServer?(saved.bridgeModes?.local||{...savedBridge,clientKey:''}):{...savedBridge,clientKey:''};base=url.origin;token=ownerToken;mode='deck';connectionKind='local';await chrome.storage.local.set({pair:{base,token},mode,connectionKind,bridge,bridgeModes:{...saved.bridgeModes,local:bridge}});
      try{var imported=await mergeSavedChromeWorkspace(base,token,bridge.clientKey);workspaceMigrationError='';}catch(mergeError){workspaceMigrationError=mergeError.message;}
      await refresh();$('#dialog').close();toast(workspaceMigrationError?`Local API connected. Browser settings need another try: ${workspaceMigrationError}`:imported&&!imported.alreadyImported?`Connected. Imported ${imported.accounts} provider account${imported.accounts===1?'':'s'} and ${imported.routes} route${imported.routes===1?'':'s'}.`:imported?.alreadyImported?'Connected. Router settings are up to date.':'Connected. The extension and local API now use the same Router settings.');return;
    }
    if(formId==='connect-form'){
      const url=new URL(data.get('base'));if(!['localhost','127.0.0.1'].includes(url.hostname)||url.protocol!=='http:'||url.username||url.password||url.search||url.hash)throw new Error('Use a local HTTP gateway URL, such as http://127.0.0.1:5147.');
      base=url.origin;token=String(data.get('token')).trim();await refresh();const pair={base,token};if(extension)await chrome.storage.local.set({pair});else sessionStorage.setItem('aideck-pair',JSON.stringify(pair));$('#dialog').close();toast('Gateway connected.');
    }
    if(formId==='account-form'){
      const id=form.dataset.id,isWeb=data.get('provider')==='web',providerId=isWeb?data.get('webProvider'):data.get('provider'),selected=provider(providerId);
      const transport=String(data.get('webTransport')||'api-v2'),body={name:data.get('name'),provider:providerId,baseUrl:isWeb?selected.baseUrl:data.get('baseUrl'),proxyUrl:isWeb?'':data.get('proxyUrl'),capabilities:isWeb?['chat']:data.getAll('capability'),...(isWeb?{webOptions:{transport,model:String(data.get('webModel')||'auto').trim(),images:data.has('webImages'),tools:data.has('webTools')}}:{}),enabled:data.has('enabled')};
      if(extension&&isWeb)await requestWebProviderPermission(providerId,transport);
      else if(extension&&mode==='standalone'){
        if(body.proxyUrl)throw new Error('Per-account proxies require the optional Deck server.');const origin=new URL(body.baseUrl).origin;if(!await chrome.permissions.request({origins:[origin+'/*']}))throw new Error('Allow access to this provider to connect it.');
      }
      if(data.get('apiKey')||!id)body.apiKey=data.get('apiKey');const saved=await api('/admin/accounts'+(id?'/'+id:''),{method:id?'PUT':'POST',body});
      if(isWeb&&transport==='ui-v1'){const result=await chrome.runtime.sendMessage({type:'aideck.web-provider',action:'connect',accountId:saved.id,provider:saved.provider});if(!result?.ok)throw new Error(result?.error||'Could not open the provider page.');}
      $('#dialog').close();await refresh();toast(isWeb?transport==='api-v2'?'Provider saved. V2 will use the signed-in session over background HTTP without opening a provider tab.':'Provider saved. V1 will use its dedicated page bridge.':'Provider account saved.');
    }
    if(formId==='route-form'){
      syncTargets();const id=form.dataset.edit;await api('/admin/routes'+(id?'/'+id:''),{method:id?'PUT':'POST',body:{...pendingRoute,id:data.get('id'),name:data.get('name'),strategy:data.get('strategy'),failover:data.has('failover'),retryAuthErrors:data.has('retryAuthErrors'),enabled:data.has('enabled')}});$('#dialog').close();await refresh();toast('Route saved.');
    }
    if(formId==='client-form'){
      const id=form.dataset.id,payload={name:data.get('name'),rpm:Number(data.get('rpm')),routes:data.getAll('routes'),enabled:data.has('enabled')};
      if(!payload.routes.length)throw new Error('Choose at least one route or All routes.');
      if(id){await api(`/admin/clients/${id}`,{method:'PUT',body:payload});$('#dialog').close();await refresh();toast('Integration key updated.');}
      else{const client=await api('/admin/clients',{method:'POST',body:payload});await refresh();modal('Integration key created',`<p class="notice">Copy this key now. It cannot be revealed again.</p><pre class="key-output">${esc(client.key)}</pre><div class="form-actions">${button('Copy key','copy',client.key,'primary')}${button('Done','close','','quiet')}</div>`);}
    }
    if(formId==='settings-form'){
      await api('/admin/settings',{method:'PUT',body:{defaultRoute:data.get('defaultRoute'),timeoutMs:Number(data.get('timeout'))*1000,cooldownMs:Number(data.get('cooldown'))*1000,...(data.has('origins')?{allowedOrigins:String(data.get('origins')).split(/\r?\n/).map(v=>v.trim()).filter(Boolean),deckRoot:data.get('deckRoot'),deckScript:data.get('deckScript')}:{})}});await refresh();toast('Settings saved.');
    }
    if(formId==='bridge-form'){
      const ids=String(data.get('ids')).split(/\s+/).filter(Boolean);if(!ids.every(id=>/^[a-p]{32}$/.test(id)))throw new Error('Use valid 32-letter Chrome extension IDs.');
      const clientKey=String(data.get('clientKey')).trim();if(clientKey&&!clientKey.startsWith('aid_'))throw new Error('Use a scoped aid_ integration key.');
      bridge={allowedExtensionIds:[...new Set(ids)],clientKey};const savedModes=await chrome.storage.local.get('bridgeModes'),bridgeMode=connectionKind==='local'?'local':connectionKind==='deck'?'deck':'standalone';await chrome.storage.local.set({bridge,bridgeModes:{...savedModes.bridgeModes,[bridgeMode]:bridge}});toast('Extension bridge access saved.');
    }
    if(formId==='deck-form'){
      const id=form.dataset.id;await api('/admin/deck',{method:'POST',body:{account:id||data.get('account'),action:id?'open':'create',harness:data.get('harness'),provider:data.get('provider'),pool:data.has('pool'),failover:data.get('failover')||'Off'}});$('#dialog').close();toast('Deck terminal opened. Complete native login there.');
    }
  }catch(e){if(error)error.textContent=e.message;else toast(e.message);}finally{busy=false;if(submit)submit.disabled=false;}
});
window.addEventListener('hashchange',()=>{const next=location.hash.slice(1);if(pages.includes(next)&&next!==page){chatAbort?.abort();page=next;render();}});
$('#connection').addEventListener('click',()=>connectDialog());$('#refresh').addEventListener('click',()=>refresh().catch(e=>toast(e.message)));
async function init(){
  await readHistory();
  if(extension){const saved=await chrome.storage.local.get(['pair','bridge','bridgeModes','mode','connectionKind']);if(saved.pair){base=saved.pair.base;token=saved.pair.token;mode='deck';connectionKind=saved.connectionKind||'deck';bridge=saved.bridgeModes?.[connectionKind]||saved.bridge||bridge;await chrome.storage.local.set({mode,connectionKind});try{await mergeSavedChromeWorkspace(base,token,bridge.clientKey);workspaceMigrationError='';}catch(error){workspaceMigrationError=error.message;}}else{mode='standalone';connectionKind='standalone';bridge=saved.bridgeModes?.standalone||saved.bridge||bridge;}}
  else{try{const saved=JSON.parse(sessionStorage.getItem('aideck-pair'));if(saved){base=saved.base;token=saved.token;}}catch{}}
  const hash=new URLSearchParams(location.hash.slice(1));if(hash.has('token')){token=hash.get('token');if(!extension)base=location.origin;history.replaceState(null,'',location.pathname+'#routes');if(!extension)sessionStorage.setItem('aideck-pair',JSON.stringify({base,token}));}
  if(pages.includes(location.hash.slice(1)))page=location.hash.slice(1);navigation();
  if(token||extension&&mode==='standalone'){try{await refresh();}catch(e){$('#main').innerHTML=empty('The gateway needs a connection.','Start the local gateway, then check your owner key.');connectDialog(e.message);}}
  else{$('#main').innerHTML=empty('Connect to Router.','Run the local gateway to manage provider credentials, routing, and failover in one place.');connectDialog();}
}
async function mergeSavedChromeWorkspace(server,ownerToken,bridgeKey=''){
  const saved=await chrome.storage.local.get(['standalone','workspaceId']);const workspace=saved.standalone;
  const sourceAccounts=Array.isArray(workspace?.config?.accounts)?workspace.config.accounts:[],accountIds=new Set(sourceAccounts.map(account=>account.id));
  const sourceRoutes=(Array.isArray(workspace?.config?.routes)?workspace.config.routes:[]).map(route=>({...route,targets:(route.targets||[]).filter(target=>accountIds.has(target.account))})).filter(route=>route.targets.length);
  if(!sourceAccounts.length&&!sourceRoutes.length)return null;
  const workspaceId=saved.workspaceId||crypto.randomUUID();if(!saved.workspaceId)await chrome.storage.local.set({workspaceId:workspaceId});const sourceId=`${workspaceId}-v3`;
  const accounts=sourceAccounts.map(account=>({...account,apiKey:workspace.secrets?.accounts?.[account.id]||''}));
  const response=await fetch(server+'/admin/import',{method:'POST',headers:{Authorization:`Bearer ${ownerToken}`,'Content-Type':'application/json'},body:JSON.stringify({sourceId,accounts,routes:sourceRoutes,settings:{defaultRoute:workspace.config.settings?.defaultRoute||''},...(bridgeKey?{bridgeKey}:{})}),signal:AbortSignal.timeout(30000)});
  const result=await response.json();if(!response.ok)throw new Error(result.error?.message||`Router settings import failed (${response.status}).`);await remapConversationRoutes(result.routeMap);
  const currentImports=await chrome.storage.local.get('workspaceImports');await chrome.storage.local.set({workspaceImports:[...new Set([...(currentImports.workspaceImports||[]),`${server}|${sourceId}`])]});
  return result;
}
init().catch(e=>toast(e.message));
