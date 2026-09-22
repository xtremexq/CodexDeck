'use strict';
// One launch, loopback only. Credentials and request bodies never enter logs.
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
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
  if (!auth.tokens?.access_token || !auth.tokens?.account_id || (auth.auth_mode && auth.auth_mode !== 'chatgpt')) throw Error('Every pool account needs a file-based ChatGPT login.');
  return { token: auth.tokens.access_token, id: auth.tokens.account_id };
}
function quotaRejected(status, body) {
  if (status !== 429) return false;
  try {
    const e = JSON.parse(body).error;
    const kinds = ['usage_limit_reached','insufficient_quota','rate_limit_exceeded'];
    return kinds.includes(e?.type) || kinds.includes(e?.code);
  } catch { return false; }
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
  if (!value || typeof value !== 'object') return '';
  if (typeof value.text === 'string') return value.text;
  if (typeof value.output === 'string') return value.output;
  if (typeof value.arguments === 'string') return value.arguments;
  if (typeof value.content === 'string') return value.content;
  if (Array.isArray(value.content)) return value.content.map(contextText).filter(Boolean).join('\n');
  return '';
}
function contextEntries(parsed) {
  const input = Array.isArray(parsed?.input) ? parsed.input : parsed?.input == null ? [] : [parsed.input];
  const seen = new Map();
  return input.map((item, index) => {
    const serialized = stableJson(item);
    const hash = crypto.createHash('sha256').update(serialized).digest('hex').slice(0, 24);
    const occurrence = seen.get(hash) || 0; seen.set(hash, occurrence + 1);
    const object = item && typeof item === 'object' ? item : {};
    const role = typeof object.role === 'string' ? object.role : null;
    const type = typeof object.type === 'string' ? object.type : typeof item === 'string' ? 'input_text' : 'item';
    const callId = object.call_id || object.callId || null;
    const content = contextText(item);
    const protectedItem = ['system','developer'].includes(role) || type === 'reasoning' || Boolean(object.encrypted_content);
    const editable = typeof item === 'string' || type === 'message' || typeof object.output === 'string' || typeof object.arguments === 'string' ||
      typeof object.content === 'string' || (Array.isArray(object.content) && object.content.some(part => part && typeof part.text === 'string'));
    return { key:`${hash}:${occurrence}`, index, type, role, name:object.name || null, callId, text:content,
      preview:content.slice(0, 420), chars:content.length || serialized.length, tokens:Math.ceil((content.length || serialized.length) / 4),
      protected:protectedItem, editable, raw:item };
  });
}
function replaceContextText(item, replacement) {
  if (typeof item === 'string') return replacement;
  const copy = JSON.parse(JSON.stringify(item));
  if (typeof copy.output === 'string') copy.output = replacement;
  else if (typeof copy.arguments === 'string') copy.arguments = replacement;
  else if (typeof copy.content === 'string') copy.content = replacement;
  else if (Array.isArray(copy.content)) {
    const parts = copy.content.filter(value => value && typeof value.text === 'string');
    if (parts.length) { parts[0].text = replacement; for (const part of parts.slice(1)) part.text = ''; }
  }
  return copy;
}
function projectContext(parsed, rules, allowProtected) {
  const entries = contextEntries(parsed);
  const projected = [];
  for (const entry of entries) {
    const rule = rules.get(entry.key);
    const usable = !rule || !entry.protected || allowProtected;
    entry.suppressed = Boolean(usable && rule?.action === 'suppress');
    entry.edited = Boolean(usable && rule?.action === 'edit');
    if (entry.suppressed) continue;
    projected.push(entry.edited ? replaceContextText(entry.raw, rule.text) : entry.raw);
  }
  const output = JSON.parse(JSON.stringify(parsed));
  if (Array.isArray(parsed.input)) output.input = projected;
  else if (parsed.input != null) output.input = projected[0] ?? '';
  const effective = contextEntries(output);
  const rawTokens = entries.reduce((sum, entry) => sum + entry.tokens, 0);
  const effectiveTokens = effective.reduce((sum, entry) => sum + entry.tokens, 0);
  return { output, entries, effective, rawTokens, effectiveTokens };
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
  const contextRules = new Map();
  let contextSnapshot = { version:1, revision:0, enabled:contextEnabled, protectedChanges:allowProtected, capturedAt:null, requestPath:null, raw:[], effective:[], rawTokens:0, effectiveTokens:0, savedTokens:0, rules:[] };
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
        const account=config.environment || current;
        if(routeQuery.has('since')&&Number.isInteger(since)&&since===contextSnapshot.revision)return replyJson(res,{version:1,revision:contextSnapshot.revision,unchanged:true,busy:activeRequests>0,account});
        return replyJson(res, { ...contextSnapshot, account, busy:activeRequests > 0, rules:[...contextRules.entries()].map(([key,rule]) => ({key,...rule})) });
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
          const projection = projectContext(parsed, contextRules, allowProtected);
          parsed = projection.output;
          body = Buffer.from(JSON.stringify(parsed));
          contextSnapshot = { version:1, revision:contextSnapshot.revision+1, enabled:true, protectedChanges:allowProtected, capturedAt:new Date(now()).toISOString(), requestPath:routePath,
            raw:projection.entries.map(({raw,...entry}) => entry), effective:projection.effective.map(({raw,...entry}) => entry),
            rawTokens:projection.rawTokens, effectiveTokens:projection.effectiveTokens, savedTokens:Math.max(0, projection.rawTokens - projection.effectiveTokens), rules:[] };
        }
        bound = accountBound(parsed);
      }
      // Let the active account validate server-stored references it owns. A 429
      // proves the request was rejected, so portable full/encrypted history can
      // be retried without duplicating an accepted response.
      let attempts = 0, maxAttempts = conversation && automatic ? pool.length : 1;
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
            // maxAttempts remains one, so the request is never replayed.
            excluded.delete(current);
            retryAt.delete(current);
            resetProbes.add(current);
          }
        }
        const used = current, auth = getCredentials(used);
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
        if (conversation && incoming.statusCode === 429) {
          const rejected = await collect(incoming, 1024 * 1024);
          if (quotaRejected(429, rejected)) {
            excluded.add(used);
            resetProbes.delete(used);
            const rows = getRows();
            retryAt.set(used, quotaRetryAt(incoming, rejected, rowFor(rows, used), now()));
            // A manual selection may arrive while this accepted response is
            // streaming (for example from the Pool skill's local tool call).
            // Preserve it for the next request unless that same account failed.
            const next = automatic ? (current !== used && !excluded.has(current) ? current : choices()[0]) : null;
            if (next && !bound && !res.destroyed) { current = next; report(current); continue; }
            if (automatic && bound && next) return reply(res, 409, 'Quota reached, but this request contains account-scoped history. Start a new session to change accounts.');
          }
          res.writeHead(429, { 'content-type':'application/json', 'cache-control':'no-store' }); res.end(rejected); return;
        }
        resetProbes.delete(used);
        const responseHeaders = { 'cache-control':'no-store' };
        const blockedResponseHeaders = new Set(['connection','proxy-connection','transfer-encoding','upgrade','set-cookie']);
        for (const [name,value] of Object.entries(incoming.headers)) if (!blockedResponseHeaders.has(name) && name !== 'cache-control' && value != null) responseHeaders[name] = value;
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
