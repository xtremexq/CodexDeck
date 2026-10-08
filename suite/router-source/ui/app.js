const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replace(/[&<>"']/g,c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const extension = typeof chrome !== 'undefined' && !!chrome.runtime?.id;
const pages = ['routes','providers','playground','deck','integrations','activity','settings'];
const labels = { routes:'Routes', providers:'Providers', playground:'Playground', deck:'AI Deck', integrations:'Integrations', activity:'Activity', settings:'Settings' };
const paths = { routes:'M3 6h6v6H3zM15 12h6v6h-6zM9 9h5v6h1M17 3v6m-3-3h6', providers:'M8 3v4m8-4v4M6 7h12v5a6 6 0 0 1-12 0zM12 18v3', playground:'m5 5 5 5-5 5m7 2h7', deck:'M4 4h16v13H4zM8 21h8m-4-4v4', integrations:'M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-2 2M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l2-2', activity:'M2 12h5l3-8 4 16 3-8h5', settings:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 3v2m0 14v2M3 12h2m14 0h2M5.6 5.6 7 7m10 10 1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4' };
let base = 'http://127.0.0.1:5147';
let token = ''; let state = null; let page = 'routes'; let chat = []; let chatAbort = null; let bridge = { allowedExtensionIds: [], clientKey: '' }; let busy = false;
let pendingRoute = null; let toastTimer; let mode='deck'; let pairingAbort=null; let extensionClient;
if(extension)extensionClient=await import(chrome.runtime.getURL('client.js'));
const provider = id => state?.providers.find(p => p.id === id);
const account = id => state?.config.accounts.find(a => a.id === id);
const badge = (text,kind='') => `<span class="badge ${kind}">${esc(text)}</span>`;
const mark = p => `<span class="provider-mark">${esc(p?.mark || '?')}</span>`;
const button = (text,action,id='',kind='') => `<button type="button" class="${kind}" data-action="${action}" data-id="${esc(id)}">${text}</button>`;
function toast(message) { clearTimeout(toastTimer); $('#toast').textContent = message; $('#toast').classList.add('show'); toastTimer = setTimeout(() => $('#toast').classList.remove('show'),4200); }
async function api(path, options = {}) {
  if(extension&&mode==='standalone')return extensionClient.standaloneAdmin(path,options);
  const response = await fetch(base+path,{ ...options, headers: { Authorization: `Bearer ${token}`, ...(options.body ? {'Content-Type':'application/json'} : {}), ...options.headers }, body: options.body ? JSON.stringify(options.body) : undefined });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error?.message || `Gateway returned ${response.status}.`);
  return value;
}
function modal(title,content) {
  $('#dialog-content').innerHTML = `<div class="dialog-head"><h2>${esc(title)}</h2><button class="icon-button quiet" data-action="close" aria-label="Close dialog">×</button></div><div class="dialog-body">${content}</div>`;
  if (!$('#dialog').open) $('#dialog').showModal();
}
const formActions = label => `<p class="error-message" role="alert"></p><div class="form-actions"><button type="button" class="quiet" data-action="close">Cancel</button><button class="primary" type="submit">${label}</button></div>`;
function heading(title,description,actions='') { return `<div class="page-head"><div><div class="eyebrow">Your AI infrastructure</div><h1>${title}</h1><p class="subtitle">${description}</p></div><div class="head-actions">${actions}</div></div>`; }
function empty(title,description,action='') { return `<div class="empty"><div class="empty-symbol">⌁</div><h2>${title}</h2><p>${description}</p>${action}</div>`; }
function navigation() {
  $('#nav').innerHTML = pages.map((id,i) => `${i === 3 ? '<div class="nav-label">Workspace</div>' : ''}<a href="#${id}" aria-label="${labels[id]}" class="nav-item ${page===id?'active':''}" ${page===id?'aria-current="page"':''}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[id]}"></path></svg>${labels[id]}${id === 'routes' && state ? `<span class="nav-count" aria-hidden="true">${state.config.routes.length}</span>`:''}</a>`).join('');
  $('#crumb').textContent = labels[page];
}
function targetNode(target,index) { const a=account(target.account),p=provider(a?.provider); return `<div class="target-node"><span class="target-order">${index === 0?'PRIMARY':`FALLBACK ${index}`}</span><div class="target-top">${mark(p)}<span>${esc(a?.name || 'Missing account')}</span></div><div class="target-model">${esc(target.model)}</div></div>`; }
function routesView() {
  const { accounts,routes,settings } = state.config;
  const enabled = accounts.filter(a=>a.enabled).length;
  const successful = state.runtime.events.filter(e=>e.status==='success');
  const median = successful.length ? [...successful].sort((a,b)=>a.ms-b.ms)[Math.floor(successful.length/2)].ms : null;
  return heading('A home for every AI call.','Choose the destination. Keep your apps connected.',button('+ New route','new-route','','primary')) +
    `<div class="metrics"><div class="metric"><div class="metric-label">Active routes <span>↗</span></div><div class="metric-value">${routes.filter(r=>r.enabled).length}<small>ready to receive</small></div></div><div class="metric"><div class="metric-label">Provider accounts <span>⊞</span></div><div class="metric-value">${enabled}<small>of ${accounts.length} enabled</small></div></div><div class="metric"><div class="metric-label">Requests this session <span>⌁</span></div><div class="metric-value">${state.runtime.requests}<small>${state.runtime.active} in flight</small></div></div><div class="metric"><div class="metric-label">Median completion time <span>◷</span></div><div class="metric-value">${median === null?'—':(median/1000).toFixed(1)+'s'}<small>recent requests</small></div></div></div>` +
    `<div class="section-head"><div><h2>Your routes</h2><p>Stable model aliases. Providers can change behind them.</p></div><span class="section-label">${routes.length} CONFIGURED</span></div>` +
    (routes.length ? routes.map(r=>`<article class="route-card"><div class="route-header"><div class="route-title"><span class="route-icon">⌁</span><div><h2>${esc(r.name)}</h2><small>${esc(r.id)}</small></div>${badge(r.enabled?'Active':'Paused',r.enabled?'':'neutral')}${r.id===settings.defaultRoute?badge('Default','orange'):''}</div>${button('Edit route','edit-route',r.id,'small quiet')}</div><div class="route-flow"><div class="source-node"><small>REQUEST MODEL</small>${esc(r.id)}</div><span class="flow-arrow">→</span>${r.targets.map((t,i)=>`${i?'<span class="flow-arrow">⇢</span>':''}${targetNode(t,i)}`).join('')}</div><div class="route-footer"><span>${r.strategy==='ordered'?'Ordered':'Round robin'} · ${r.failover?'Failover enabled':'Failover off'} · ${r.targets.length} destination${r.targets.length===1?'':'s'}</span><span class="mono">POST /v1/chat/completions</span></div></article>`).join('') : empty('Give your first request a destination.','Connect a provider account, then create an alias such as everyday or coding. Your apps will use that alias for every request.',button(accounts.length?'Create a route':'Connect a provider',accounts.length?'new-route':'new-account','','primary'))) +
    `<div class="info-strip"><span class="info-icon">⌘</span><div><h3>Already using an OpenAI-compatible app?</h3><p>${extension&&mode==='standalone'?'Use the extension messaging API, or connect the optional Deck server for a standard HTTP endpoint.':`Set its API base URL to ${esc(base)}/v1, choose a route alias, and add an integration key.`}</p></div><a href="#integrations">Connect an app ↗</a></div>`;
}
function providersView() {
  const accounts = state.config.accounts;
  return heading('Your providers, together.',extension&&mode==='standalone'?'API credentials are saved in this Chrome profile.':'API credentials stay in the local gateway vault.',button('+ Add account','new-account','','primary')) +
    `<div class="section-head"><h2>Connected accounts</h2><span class="section-label">${accounts.length} ACCOUNTS</span></div>` +
    (accounts.length?`<div class="account-list">${accounts.map(a=>{const p=provider(a.provider);return `<div class="account-row">${mark(p)}<div class="account-info"><strong>${esc(a.name)}</strong><small>${esc(p.name)} · ${a.hasKey?'Key saved':'No API key'}${a.proxyUrl?' · Proxy enabled':''}</small></div>${badge(a.enabled?'Enabled':'Paused',a.enabled?'':'neutral')}<div class="row-actions">${button('Models','models',a.id,'small')}${button('Edit','edit-account',a.id,'small quiet')}</div></div>`;}).join('')}</div>`:empty('Connect your first provider.','Add an API key from your provider. You can add several accounts from the same provider for failover.')) +
    `<div class="section-head section-space"><div><h2>Provider directory</h2><p>Pick a provider to connect an account.</p></div></div><div class="provider-grid">${state.providers.map(p=>`<article class="provider-card">${mark(p)}<h2>${esc(p.name)}</h2><p>${p.capabilities.map(esc).join(' · ')}</p>${button('Connect account ↗','new-account',p.id,'small')}</article>`).join('')}</div>`;
}
function playgroundView() {
  const routes = state.config.routes.filter(r=>r.enabled);
  return heading('Take a route for a spin.','Send a real request through your configured providers.') +
    (!routes.length?empty('A route comes first.','Create a route with a connected provider to start testing.',button('Create route','new-route','','primary')):
    `<div class="chat-layout"><section class="panel chat-panel"><div class="chat-toolbar"><select aria-label="Playground route" id="chat-route">${routes.map(r=>`<option value="${esc(r.id)}">${esc(r.id)}</option>`).join('')}</select>${badge('Streaming')}<button class="quiet small" data-action="clear-chat">Clear</button></div><div class="messages" id="messages"></div><form id="chat-form" class="composer"><textarea name="prompt" aria-label="Message" placeholder="What would you like to try?" required></textarea><div class="composer-bottom"><span id="chat-status">Messages stay in this tab.</span><div><button type="button" class="quiet small" id="stop" data-action="stop-chat" disabled>Stop</button> <button class="primary small" id="send-message" type="submit">Send request ↗</button></div></div></form></section><aside class="panel route-summary" id="route-summary"></aside></div>`);
}
function integrationsView() {
  const routes = state.config.routes;
  return heading('One endpoint. Your whole stack.','SDKs, apps, websites, and other extensions.',button('+ Integration key','new-client','','primary')) +
    `<div class="two-col"><section class="panel">${extension&&mode==='standalone'?`<div class="eyebrow">01 · Optional Deck server</div><h2>Connect desktop apps.</h2><p class="hint">Standalone mode provides the Chrome messaging API. For SDKs, terminals and apps with a custom API URL, enable the optional Deck server and pair this extension.</p>${button('Connect to Deck','connect','','primary')}`:`<div class="eyebrow">01 · Standard API</div><h2>Bring your own app.</h2><p class="hint">Works with clients that accept a custom OpenAI-compatible API base URL.</p><pre>Base URL  ${esc(base)}/v1\nAPI key   your integration key\nModel     ${esc(routes[0]?.id || 'your-route-alias')}</pre><pre>import OpenAI from 'openai';\nconst ai = new OpenAI({\n  baseURL: '${esc(base)}/v1',\n  apiKey: process.env.AIDECK_KEY\n});\nconst reply = await ai.chat.completions.create({\n  model: '${esc(routes[0]?.id || 'your-route-alias')}',\n  messages: [{ role: 'user', content: 'Hello!' }]\n});</pre>`}</section><section class="panel"><div class="eyebrow">02 · Chrome extension</div><h2>A bridge to other extensions.</h2><p class="hint">The extension works standalone. Optional Deck mode pairs through a matching code approved in Deck Settings → AI Router.</p><div class="step"><b>1</b><div>Create a dedicated integration key.<small>Only allow the routes the extension needs.</small></div></div><div class="step"><b>2</b><div>Open Router extension Settings.<small>Save the bridge key and approve caller extension IDs.</small></div></div><div class="step"><b>3</b><div>Call the Router messaging interface.<small>One-shot replies and streaming ports are supported.</small></div></div><pre>chrome.runtime.sendMessage(ROUTER_EXTENSION_ID, {\n  type: 'aideck.chat',\n  body: { model: '${esc(routes[0]?.id || 'your-route-alias')}',\n    messages: [{ role: 'user', content: 'Hello!' }] }\n});</pre></section></div><section class="panel"><div class="section-head"><div><h2>Integration keys</h2><p>Each key has its own allowed routes and request limit. Revoke at any time.</p></div></div>${state.config.clients.length?state.config.clients.map(c=>`<div class="integration-row"><div><strong>${esc(c.name)}</strong><small>${c.routes.map(esc).join(', ') || 'No routes allowed'} · ${c.rpm} requests/minute</small></div>${button('Revoke','delete-client',c.id,'small danger quiet')}</div>`).join(''):'<p class="hint">No integration keys yet. Create one to connect an app.</p>'}</section><div class="info-strip"><span class="info-icon">i</span><div><h3>Compatibility has boundaries.</h3><p>Hardcoded API URLs, proprietary payloads, server-side requests, and consumer chat subscriptions require explicit adapters. The extension does not silently rewrite website traffic.</p></div></div>`;
}
function activityView() {
  const events=state.runtime.events;
  return heading('Follow the request.','Routing outcomes and timing. Prompts and API keys are never logged.',button('Refresh','refresh','','small'))+
    (!events.length?empty('Your first request will appear here.','Try a route in the Playground, or call the gateway from one of your apps.', '<a href="#playground">Open Playground ↗</a>'):
    `<div class="table-wrap"><table class="activity-table"><thead><tr><th>Time</th><th>Route / Model</th><th>Account</th><th>Result</th><th>Attempt</th><th>Elapsed</th></tr></thead><tbody>${events.map(e=>`<tr><td>${new Date(e.at).toLocaleTimeString()}</td><td><strong>${esc(e.route)}</strong><br><small>${esc(e.model)}</small></td><td>${esc(account(e.account)?.name || e.account)}</td><td>${badge(e.status,e.status==='success'?'':'orange')}${e.httpStatus?` <small>${e.httpStatus}</small>`:''}</td><td>${e.attempts}</td><td>${(e.ms/1000).toFixed(2)}s</td></tr>`).join('')}</tbody></table></div>`);
}
function settingsView() {
  const s=state.config.settings;
  const connection=extension?`<section class="panel"><h2>Connection mode</h2><p class="hint">${mode==='standalone'?'Standalone: this extension calls providers directly. No Deck or local server required.':'Deck server: API calls and native terminals use your paired local service.'} Settings and provider accounts are kept separately for each mode.</p><div class="form-actions">${button('Use standalone','standalone','','quiet')}${button(mode==='deck'?'Reconnect Deck':'Connect to Deck','connect','','primary')}</div></section>`:'';
  return heading('Make the router yours.',extension&&mode==='standalone'?'Routing defaults and approved extension access.':'Gateway behavior, website access, and Deck integration.')+connection+`<form class="panel" id="settings-form"><h2>Routing defaults</h2><div class="form-grid section-space"><label class="field">Default route<select name="defaultRoute"><option value="">No default</option>${state.config.routes.filter(r=>r.enabled).map(r=>`<option ${r.id===s.defaultRoute?'selected':''} value="${esc(r.id)}">${esc(r.id)}</option>`).join('')}</select></label><label class="field">Upstream timeout (seconds)<input name="timeout" type="number" min="1" max="600" value="${s.timeoutMs/1000}" required></label><label class="field">Account cooldown (seconds)<input name="cooldown" type="number" min="1" max="300" value="${s.cooldownMs/1000}" required></label>${extension&&mode==='standalone'?'':`<label class="field">Allowed website origins<textarea name="origins" placeholder="https://your-app.example">${esc(s.allowedOrigins.join('\n'))}</textarea><span class="hint">Exact origins, one per line. Websites still need a scoped integration key.</span></label><label class="field full">Deck accounts root<input name="deckRoot" value="${esc(s.deckRoot)}" required></label><label class="field full">Deck codex-auth.ps1 path<input name="deckScript" value="${esc(s.deckScript)}" required><span class="hint">Harness launching requires the corresponding Deck build to be deployed. Provider routing settings are managed here, independently.</span></label>`}</div><div class="form-actions"><button class="primary" type="submit">Save settings</button></div></form>`+
    (extension?`<form class="panel" id="bridge-form"><h2>External extension bridge</h2><p class="hint">Approved extensions can spend usage on the routes allowed by this key. Use a dedicated integration key, never the owner key.</p><div class="form-grid section-space"><label class="field">Bridge integration key<input name="clientKey" type="password" autocomplete="off" value="${esc(bridge.clientKey)}" placeholder="aid_…"></label><label class="field">Allowed extension IDs<textarea name="ids" placeholder="32-letter Chrome extension IDs, one per line">${esc(bridge.allowedExtensionIds.join('\n'))}</textarea></label></div><div class="form-actions"><button class="primary" type="submit">Save bridge access</button></div></form>`:'')+
    `<section class="panel"><h2>Local connection</h2><p class="hint">${extension&&mode==='standalone'?'Provider keys are stored in this Chrome profile, in extension local storage. This does not use the Windows encrypted Deck vault.':'Provider keys stay in the encrypted local server vault. On Windows its key is protected with your Windows identity.'}</p>${extension&&mode==='standalone'?'':`<div class="form-actions">${button('Change pairing','connect','','quiet')}${button('Disconnect this browser','disconnect','','danger quiet')}</div>`}</section>`;
}
async function deckView() {
  if(extension&&mode==='standalone'){$('#main').innerHTML=heading('Connect Deck when you need it.','The extension routes directly to providers without Deck.')+empty('Native accounts live in Deck.','Connect the optional Deck server to open harness terminals and manage native logins.',button('Connect to Deck','connect','','primary'));return;}
  $('#main').innerHTML = heading('Your accounts. Your harnesses.','Open isolated Deck terminals without sharing provider credentials.')+'<div class="loading">Reading Deck account metadata…</div>';
  const deck=await api('/admin/deck');
  if(page!=='deck')return;
  $('#main').innerHTML = heading('Your accounts. Your harnesses.','Native account login and gateway routing are separate connections.',button('+ Deck account','new-deck','','primary'))+
    (!deck.harnessModuleAvailable?'<p class="notice">The live Deck installation does not yet have the Harnesses module. Existing Codex accounts can open; deploy the Harnesses-enabled Deck build before using other harnesses here.</p>':'')+
    (!deck.available?empty('Connect your Deck installation.','Set the accounts root and codex-auth wrapper path in Settings.','<a href="#settings">Open Settings ↗</a>'):
    `<div class="account-list">${deck.accounts.map(a=>`<div class="account-row"><span class="provider-mark">${esc(a.harness?.slice(0,2)||'!')}</span><div class="account-info"><strong>${esc(a.id)}</strong><small>${esc(a.harness || a.error)} · ${esc(a.provider || '')}${a.runner?' · Windows runner':''}</small></div>${a.error?'':`<div class="row-actions">${button('Log in','deck-login',a.id,'small')}${button('Open terminal ↗','deck-open',a.id,'small')}</div>`}</div>`).join('')}</div>`)+
    `<div class="two-col"><section class="panel"><h2>Deck accounts and pools</h2><p class="hint">Codex → ChatGPT, Claude Code → Claude, Antigravity → Gemini. OpenCode supports several providers. Native Deck pooling and failover currently apply to Codex accounts.</p></section><section class="panel"><h2>Route API calls from a harness</h2><p class="hint">Use ${esc(base)}/v1 and an integration key in a harness's custom-provider configuration. Keep the native login intact. OpenCode can add an OpenAI-compatible provider; API-mode harness setups remain explicit.</p><p class="hint">A subscription login is not a general API credential, and this router does not automatically intercept logged-in harness traffic.</p></section></div>`;
  state.deck=deck;
}
function render() {
  navigation();
  if(!state)return;
  if(page==='deck'){deckView().catch(e=>{if(page==='deck')$('#main').innerHTML=empty('Deck is unavailable.',esc(e.message));});return;}
  $('#main').innerHTML=({routes:routesView,providers:providersView,playground:playgroundView,integrations:integrationsView,activity:activityView,settings:settingsView}[page])();
  if(page==='playground'&&$('#messages')){ const choice=state.config.settings.defaultRoute; if(choice&&$('#chat-route').querySelector(`option[value="${CSS.escape(choice)}"]`))$('#chat-route').value=choice; renderMessages();renderRouteSummary(); }
}
async function refresh(redraw=true) {
  state=await api('/admin/state');
  $('#connection').classList.add('connected'); $('#connection-label').textContent=extension&&mode==='standalone'?'Standalone mode':'Deck connected';$('.endpoint').textContent=extension&&mode==='standalone'?'Direct to providers':new URL(base).host;
  if(redraw)render();
}
function accountDialog(id,providerId) {
  const a=id?account(id):null; const p=provider(providerId||a?.provider||'openai');
  modal(a?'Edit provider account':'Connect a provider',`<form id="account-form" data-id="${esc(id||'')}"><div class="form-grid"><label class="field">Provider<select name="provider" id="provider-select">${state.providers.map(x=>`<option ${x.id===p.id?'selected':''} value="${x.id}">${esc(x.name)}</option>`).join('')}</select></label><label class="field">Account name<input name="name" value="${esc(a?.name || p.name+' · Personal')}" maxlength="100" required></label><label class="field full">API key<input name="apiKey" type="password" autocomplete="off" placeholder="${a?.hasKey?'Key saved. Leave blank to keep it.':'Paste your provider API key'}"><span class="hint">${extension&&mode==='standalone'?'Saved in this Chrome profile.':'Saved encrypted locally.'} <a id="key-docs" href="${esc(p.docs)}" target="_blank" rel="noreferrer">Get a provider key ↗</a></span></label><label class="field full">API base URL<input name="baseUrl" value="${esc(a?.baseUrl || p.baseUrl)}" placeholder="${p.id==='cloudflare'?'https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/v1':'https://…/v1'}" type="url" required><span class="hint">Include /v1 where required. Credentials are sent to this endpoint.</span></label>${extension&&mode==='standalone'?'':`<label class="field full">HTTP(S) proxy URL · optional<input name="proxyUrl" value="${esc(a?.proxyUrl||'')}" type="url" placeholder="http://127.0.0.1:8080"><span class="hint">Routes outgoing provider requests through this proxy. No credentials in the URL.</span></label>`}</div><h3>Allowed API capabilities</h3><div class="check-wrap" id="capabilities">${p.capabilities.map(c=>`<label class="check"><input type="checkbox" name="capability" value="${c}" ${(!a||a.capabilities.includes(c))?'checked':''}>${esc(c)}</label>`).join('')}</div><label class="check"><input type="checkbox" name="enabled" ${a?.enabled!==false?'checked':''}>Enable this account</label>${a?button('Delete account','delete-account',a.id,'small danger quiet'):''}${formActions(a?'Save account':'Connect account')}</form>`);
}
function routeDialog(id) {
  if(!state.config.accounts.length){toast('Connect a provider account first.');accountDialog();return;}
  const r=state.config.routes.find(r=>r.id===id);
  pendingRoute=r?structuredClone(r):{id:'',name:'',strategy:'ordered',failover:true,retryAuthErrors:false,enabled:true,targets:[{account:state.config.accounts[0].id,model:''}]};
  modal(r?'Edit route':'Create a route',`<form id="route-form" data-edit="${esc(id||'')}"><div class="form-grid"><label class="field">Route name<input name="name" value="${esc(pendingRoute.name)}" placeholder="Everyday assistant" maxlength="100" required></label><label class="field">Model alias<input name="id" value="${esc(pendingRoute.id)}" placeholder="everyday" pattern="[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}" ${r?'readonly':''} required></label><label class="field full">Selection strategy<select name="strategy"><option value="ordered">Ordered · primary, then fallbacks</option><option ${pendingRoute.strategy==='round-robin'?'selected':''} value="round-robin">Round robin · spread calls across accounts</option></select></label></div><div class="section-head"><h3>Destinations, in order</h3>${button('+ Add target','add-target','','small')}</div><div id="targets"></div><datalist id="model-options"></datalist><p class="hint">Use exact upstream model IDs. Models can differ across fallbacks; choose compatible capabilities.</p><label class="check"><input type="checkbox" name="failover" ${pendingRoute.failover?'checked':''}>Retry another target on throttling or temporary failure</label><label class="check"><input type="checkbox" name="retryAuthErrors" ${pendingRoute.retryAuthErrors?'checked':''}>Also fail over on authentication errors (401 / 403)</label><label class="check"><input type="checkbox" name="enabled" ${pendingRoute.enabled?'checked':''}>Enable this route</label>${r?button('Delete route','delete-route',r.id,'small danger quiet'):''}${formActions(r?'Save route':'Create route')}</form>`);
  renderTargets();
}
function syncTargets() { document.querySelectorAll('.target-editor').forEach((row,i)=>{pendingRoute.targets[i]={account:row.querySelector('select').value,model:row.querySelector('input').value};}); }
function renderTargets() {
  $('#targets').innerHTML=pendingRoute.targets.map((t,i)=>`<div class="target-editor"><span class="order">${String(i+1).padStart(2,'0')}</span><label class="field">Account<select name="targetAccount">${state.config.accounts.map(a=>`<option ${a.id===t.account?'selected':''} value="${esc(a.id)}">${esc(a.name)}${a.enabled?'':' (paused)'}</option>`).join('')}</select></label><label class="field model-field">Model<input name="targetModel" value="${esc(t.model)}" placeholder="Upstream model ID" list="model-options" required></label><div class="target-controls">${button('↑','up-target',String(i),'small quiet')}${button('×','remove-target',String(i),'small quiet')}</div></div>`).join('');
}
function clientDialog() {
  if(!state.config.routes.length){toast('Create a route before making an integration key.');return;}
  modal('Create integration key',`<form id="client-form"><label class="field">Integration name<input name="name" placeholder="My coding app" maxlength="100" required></label><label class="field">Requests per minute<input name="rpm" type="number" min="1" max="600" value="60" required></label><h3>Allowed routes</h3>${state.config.routes.map(r=>`<label class="check"><input type="checkbox" name="routes" value="${esc(r.id)}" checked>${esc(r.name)} <small>${esc(r.id)}</small></label>`).join('')}<p class="hint">This key grants API access only. It cannot read or change your settings.</p>${formActions('Create key')}</form>`);
}
function deckDialog(id,login=false) {
  const a=state.deck?.accounts.find(a=>a.id===id);
  if(id&&!a){toast('Refresh the Deck account list first.');return;}
  modal(id?`Open ${id}`:'Create Deck account',`<form id="deck-form" data-id="${esc(id||'')}" data-login="${login}">${id?`<p class="hint">${esc(a.harness)} · ${esc(a.provider)} · separate native account profile</p>`:`<label class="field">Account name<input name="account" pattern="[a-zA-Z][a-zA-Z0-9_-]{0,39}" maxlength="40" required placeholder="work-claude"><span class="hint">Start with a letter; use letters, numbers, underscores or dashes.</span></label><div class="form-grid"><label class="field">Harness<select name="harness" id="harness-select">${Object.keys(state.deck?.harnesses||{Codex:[]}).map(h=>`<option>${h}</option>`).join('')}</select></label><label class="field">Login provider<select name="provider" id="deck-provider"><option>ChatGPT</option></select></label></div><p class="hint">Enable optional harnesses in Deck Settings → Harnesses before creating their accounts.</p>`}${id&&a.harness==='Codex'&&!login?`<label class="field section-space">Native Deck failover<select name="failover"><option value="Off">Off</option><option value="Ordered">Ordered</option><option value="Best">Best available</option></select></label><label class="check"><input type="checkbox" name="pool">Open as a Codex account pool</label>`:''}<p class="hint section-space">A Windows terminal opens for native login or interaction. Gateway routing is configured separately through a harness's custom API provider settings.</p>${formActions(id?(login?'Open login terminal':'Open terminal'):'Create in terminal')}</form>`);
}
function connectDialog(message='') {
  if(extension){modal('Connect to Deck',`<form id="pair-form"><p class="hint">In Deck Settings → AI Router, install and start the server. Request pairing here, then approve the matching code in Deck. Your connection is saved for future launches.</p><label class="field section-space">Deck server URL<input name="base" type="url" value="${esc(base)}" required></label><p id="pair-status" role="status" class="notice">${esc(message||'Default server: localhost port 5147.')}</p>${formActions('Request pairing')}<div class="form-actions">${button('Use standalone','standalone','','quiet')}</div></form>`);return;}
  modal('Connect your local gateway',`<form id="connect-form"><p class="hint">Start the gateway with Start-AIDeckRouter.cmd. Copy the owner key from the private dashboard URL shown at startup.</p><label class="field section-space">Gateway URL<input name="base" type="url" value="${esc(base)}" required></label><label class="field">Owner key<input name="token" type="password" autocomplete="off" value="${esc(token)}" required><span class="hint">${extension?'Saved in Chrome local storage on this machine.':'Kept in this browser tab session.'} Provider keys stay in the gateway.</span></label><p class="error-message" role="alert">${esc(message)}</p><div class="form-actions"><button class="primary" type="submit">Connect gateway</button></div></form>`);
}
function renderMessages() {
  if(!$('#messages'))return;
  $('#messages').innerHTML=chat.length?chat.map(m=>`<div class="message ${m.role}"><span class="role">${m.role==='user'?'You':'Assistant'}</span>${esc(m.content||'Waiting for the first token…')}${m.tools?`<pre>${esc(m.tools)}</pre>`:''}</div>`).join(''):`<div class="chat-empty"><span class="empty-symbol">⌁</span><h2>Same interface. Any destination.</h2><p>Choose a route and send your first message.</p></div>`;
  $('#messages').scrollTop=$('#messages').scrollHeight;
}
function renderRouteSummary() {
  if(!$('#route-summary'))return;const r=state.config.routes.find(r=>r.id===$('#chat-route').value);
  $('#route-summary').innerHTML=`<div class="eyebrow">Selected route</div><h3>${esc(r.name)}</h3>${badge(r.strategy==='ordered'?'Ordered failover':'Round robin')} ${r.targets.map(targetNode).join('')}<p>Retries happen before response bytes are sent. A partially streamed response is never replayed.</p><p>Changing routes starts a new conversation.</p>`;
}
async function sendChat(form) {
  if(chatAbort)return;
  const prompt=form.prompt.value.trim();if(!prompt)return;
  const messages=chat.filter(m=>!m.failed).map(({role,content})=>({role,content}));messages.push({role:'user',content:prompt});
  chat.push({role:'user',content:prompt});const reply={role:'assistant',content:''};chat.push(reply);form.prompt.value='';renderMessages();
  const controller=new AbortController(),status=$('#chat-status'),stop=$('#stop'),send=$('#send-message');let reader;
  chatAbort=controller;stop.disabled=false;send.disabled=true;status.textContent='Routing your request…';
  try {
    const body={model:$('#chat-route').value,messages,stream:true,stream_options:{include_usage:true}};
    const response=extension&&mode==='standalone'?await extensionClient.standaloneChat(body,controller.signal):await fetch(base+'/v1/chat/completions',{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body),signal:controller.signal});
    if(!response.ok){const value=await response.json();throw new Error(value.error?.message||'Request failed.');}
    const selected=account(response.headers.get('x-aideck-account'))?.name||'provider';status.textContent=`Streaming from ${selected}`;
    reader=response.body.getReader();const decoder=new TextDecoder();let buffer='';
    while(true){const {done,value}=await reader.read();if(done)break;buffer+=decoder.decode(value,{stream:true});buffer=buffer.replace(/\r\n/g,'\n');let end;while((end=buffer.indexOf('\n\n'))>=0){const frame=buffer.slice(0,end);buffer=buffer.slice(end+2);for(const line of frame.split('\n')){if(!line.startsWith('data:'))continue;const data=line.slice(5).trim();if(data==='[DONE]'||!data)continue;const chunk=JSON.parse(data);if(chunk.error)throw new Error(chunk.error.message);const delta=chunk.choices?.[0]?.delta;if(delta?.content)reply.content+=delta.content;if(delta?.tool_calls)reply.tools=(reply.tools||'')+JSON.stringify(delta.tool_calls);if(chunk.usage)status.textContent=`${selected} · ${chunk.usage.total_tokens} tokens`;renderMessages();}}}
    if(!reply.content&&!reply.tools)throw new Error('Provider returned no visible text or tool calls.');
    if(!status.textContent.includes('tokens'))status.textContent=`Completed via ${selected}`;
  }catch(e){reply.failed=true;reply.content+=(reply.content?'\n\n':'')+(e.name==='AbortError'?'Request stopped.':e.message);renderMessages();status.textContent='Request ended.';}
  finally{if(reader){await reader.cancel().catch(()=>{});reader.releaseLock();}if(chatAbort===controller)chatAbort=null;stop.disabled=true;send.disabled=false;if(token||extension&&mode==='standalone')refresh(false).catch(()=>{});}
}
document.addEventListener('click',async event=>{
  const el=event.target.closest('[data-action]');if(!el)return;const action=el.dataset.action,id=el.dataset.id;
  try{
    if(action==='close'){pairingAbort?.abort();$('#dialog').close();return;}
    if(action==='connect'){connectDialog();return;}
    if(action==='standalone'){pairingAbort?.abort();chatAbort?.abort();await changeMode('standalone');$('#dialog').close();await refresh();toast('Standalone mode: no local server required.');return;}
    if(action==='disconnect'&&extension){await chrome.storage.local.remove('pair');token='';await changeMode('standalone');await refresh();toast('Deck disconnected. Standalone settings are available.');return;}
    if(action==='disconnect'){chatAbort?.abort();token='';state=null;sessionStorage.removeItem('aideck-pair');if(extension)await chrome.storage.local.remove('pair');$('#connection').classList.remove('connected');$('#connection-label').textContent='Connect gateway';$('#main').innerHTML=empty('Gateway disconnected.','Your provider accounts and routes remain saved locally.');connectDialog();return;}
    if(action==='refresh'){await refresh();return;}
    if(action==='new-account')accountDialog(null,id);
    if(action==='edit-account')accountDialog(id);
    if(action==='new-route')routeDialog();
    if(action==='edit-route')routeDialog(id);
    if(action==='new-client')clientDialog();
    if(action==='new-deck')deckDialog();
    if(action==='deck-open')deckDialog(id);
    if(action==='deck-login')deckDialog(id,true);
    if(action==='add-target'){syncTargets();if(pendingRoute.targets.length>=16)throw new Error('At most 16 targets per route.');pendingRoute.targets.push({account:state.config.accounts[0].id,model:''});renderTargets();}
    if(action==='up-target'){syncTargets();const i=Number(id);if(i>0)[pendingRoute.targets[i],pendingRoute.targets[i-1]]=[pendingRoute.targets[i-1],pendingRoute.targets[i]];renderTargets();}
    if(action==='remove-target'){syncTargets();if(pendingRoute.targets.length<2)throw new Error('Keep at least one target.');pendingRoute.targets.splice(Number(id),1);renderTargets();}
    if(action==='models'){el.disabled=true;const result=await api(`/admin/accounts/${id}/models`);modal('Available models',`<p class="hint">Copy an exact model identifier into a route destination.</p>${result.models.map(m=>`<div class="integration-row"><code>${esc(m.id)}</code>${button('Copy','copy',m.id,'small')}</div>`).join('')||'<p>No models returned. Enter a model ID from your provider documentation.</p>'}`);}
    if(action==='copy'){await navigator.clipboard.writeText(id);toast('Copied to clipboard.');}
    if(action==='delete-account'||action==='delete-route'||action==='delete-client'){
      const noun=action.split('-')[1];
      if(!confirm(`${noun==='client'?'Revoke this integration key':`Delete this ${noun}`}?`))return;
      await api(`/admin/${noun==='client'?'clients':noun+'s'}/${id}`,{method:'DELETE'});$('#dialog').close();await refresh();toast(noun==='client'?'Integration key revoked.':`${noun} deleted.`);
    }
    if(action==='clear-chat'){chatAbort?.abort();chat=[];renderMessages();}
    if(action==='stop-chat')chatAbort?.abort();
  }catch(e){toast(e.message);}finally{if(action==='models')el.disabled=false;}
});
document.addEventListener('change',event=>{
  if(event.target.id==='provider-select'){
    const p=provider(event.target.value),form=$('#account-form');form.elements.namedItem('baseUrl').value=p.baseUrl;form.elements.namedItem('name').value=p.name+' · Personal';form.elements.namedItem('apiKey').value='';$('#key-docs').href=p.docs;
    $('#capabilities').innerHTML=p.capabilities.map(c=>`<label class="check"><input name="capability" type="checkbox" value="${c}" checked>${esc(c)}</label>`).join('');
  }
  if(event.target.id==='harness-select')$('#deck-provider').innerHTML=state.deck.harnesses[event.target.value].map(p=>`<option>${esc(p)}</option>`).join('');
  if(event.target.id==='chat-route'){chatAbort?.abort();chat=[];renderMessages();renderRouteSummary();}
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
        base=url.origin;token=value.token;await chrome.storage.local.set({pair:{base,token}});await changeMode('deck',value.bridgeKey);await refresh();$('#dialog').close();toast('Deck paired. Create routes, then grant bridge access in Settings.');paired=true;break;
      }
      if(!paired&&!signal.aborted)throw new Error('Pairing expired. Request a new code.');
    }
    if(formId==='connect-form'){
      const url=new URL(data.get('base'));if(!['localhost','127.0.0.1'].includes(url.hostname)||url.protocol!=='http:'||url.username||url.password||url.search||url.hash)throw new Error('Use a local HTTP gateway URL, such as http://127.0.0.1:5147.');
      base=url.origin;token=String(data.get('token')).trim();await refresh();const pair={base,token};if(extension)await chrome.storage.local.set({pair});else sessionStorage.setItem('aideck-pair',JSON.stringify(pair));$('#dialog').close();toast('Gateway connected.');
    }
    if(formId==='account-form'){
      const id=form.dataset.id;const body={name:data.get('name'),provider:data.get('provider'),baseUrl:data.get('baseUrl'),proxyUrl:data.get('proxyUrl'),capabilities:data.getAll('capability'),enabled:data.has('enabled')};
      if(extension&&mode==='standalone'){if(body.proxyUrl)throw new Error('Per-account proxies require the optional Deck server.');const origin=new URL(body.baseUrl).origin;if(!await chrome.permissions.request({origins:[origin+'/*']}))throw new Error('Allow access to this provider to connect it.');}
      if(data.get('apiKey')||!id)body.apiKey=data.get('apiKey');await api('/admin/accounts'+(id?'/'+id:''),{method:id?'PUT':'POST',body});$('#dialog').close();await refresh();toast('Provider account saved.');
    }
    if(formId==='route-form'){
      syncTargets();const id=form.dataset.edit;await api('/admin/routes'+(id?'/'+id:''),{method:id?'PUT':'POST',body:{...pendingRoute,id:data.get('id'),name:data.get('name'),strategy:data.get('strategy'),failover:data.has('failover'),retryAuthErrors:data.has('retryAuthErrors'),enabled:data.has('enabled')}});$('#dialog').close();await refresh();toast('Route saved.');
    }
    if(formId==='client-form'){
      const client=await api('/admin/clients',{method:'POST',body:{name:data.get('name'),rpm:Number(data.get('rpm')),routes:data.getAll('routes')}});await refresh();modal('Integration key created',`<p class="notice">Copy this key now. It cannot be revealed again.</p><pre class="key-output">${esc(client.key)}</pre><div class="form-actions">${button('Copy key','copy',client.key,'primary')}${button('Done','close','','quiet')}</div>`);
    }
    if(formId==='settings-form'){
      await api('/admin/settings',{method:'PUT',body:{defaultRoute:data.get('defaultRoute'),timeoutMs:Number(data.get('timeout'))*1000,cooldownMs:Number(data.get('cooldown'))*1000,...(data.has('origins')?{allowedOrigins:String(data.get('origins')).split(/\r?\n/).map(v=>v.trim()).filter(Boolean),deckRoot:data.get('deckRoot'),deckScript:data.get('deckScript')}:{})}});await refresh();toast('Settings saved.');
    }
    if(formId==='bridge-form'){
      const ids=String(data.get('ids')).split(/\s+/).filter(Boolean);if(!ids.every(id=>/^[a-p]{32}$/.test(id)))throw new Error('Use valid 32-letter Chrome extension IDs.');
      const clientKey=String(data.get('clientKey')).trim();if(clientKey&&!clientKey.startsWith('aid_'))throw new Error('Use a scoped aid_ integration key.');
      bridge={allowedExtensionIds:[...new Set(ids)],clientKey};const saved=await chrome.storage.local.get('bridgeModes');await chrome.storage.local.set({bridge,bridgeModes:{...saved.bridgeModes,[mode]:bridge}});toast('Extension bridge access saved.');
    }
    if(formId==='deck-form'){
      const id=form.dataset.id;await api('/admin/deck',{method:'POST',body:{account:id||data.get('account'),action:id?(form.dataset.login==='true'?'login':'open'):'create',harness:data.get('harness'),provider:data.get('provider'),pool:data.has('pool'),failover:data.get('failover')||'Off'}});$('#dialog').close();toast('Deck terminal opened. Complete native login there.');
    }
  }catch(e){if(error)error.textContent=e.message;else toast(e.message);}finally{busy=false;if(submit)submit.disabled=false;}
});
window.addEventListener('hashchange',()=>{const next=location.hash.slice(1);if(pages.includes(next)&&next!==page){chatAbort?.abort();page=next;render();}});
$('#connection').addEventListener('click',()=>connectDialog());$('#refresh').addEventListener('click',()=>refresh().catch(e=>toast(e.message)));
async function init(){
  if(extension){const saved=await chrome.storage.local.get(['pair','bridge','mode']);if(saved.pair){base=saved.pair.base;token=saved.pair.token;}if(saved.bridge)bridge=saved.bridge;mode=saved.mode||(saved.pair?'deck':'standalone');}
  else{try{const saved=JSON.parse(sessionStorage.getItem('aideck-pair'));if(saved){base=saved.base;token=saved.token;}}catch{}}
  const hash=new URLSearchParams(location.hash.slice(1));if(hash.has('token')){token=hash.get('token');if(!extension)base=location.origin;history.replaceState(null,'',location.pathname+'#routes');if(!extension)sessionStorage.setItem('aideck-pair',JSON.stringify({base,token}));}
  if(pages.includes(location.hash.slice(1)))page=location.hash.slice(1);navigation();
  if(token||extension&&mode==='standalone'){try{await refresh();}catch(e){$('#main').innerHTML=empty('The gateway needs a connection.','Start the local gateway, then check your owner key.');connectDialog(e.message);}}
  else{$('#main').innerHTML=empty('Connect your AI workspace.','Run the local gateway to keep your provider credentials, routing, and failover together.');connectDialog();}
}
async function changeMode(next,key){
  const saved=await chrome.storage.local.get('bridgeModes');const modes={...saved.bridgeModes,[mode]:bridge};mode=next;bridge=modes[next]||{allowedExtensionIds:[],clientKey:''};if(key)bridge={...bridge,clientKey:key};
  await chrome.storage.local.set({mode,bridge,bridgeModes:{...modes,[mode]:bridge}});
}
init().catch(e=>toast(e.message));
