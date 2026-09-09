'use strict';
// One launch, loopback only. Credentials and request bodies never enter logs.
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { pipeline } = require('node:stream');
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
    return ['usage_limit_reached','insufficient_quota'].includes(e?.type) || ['usage_limit_reached','insufficient_quota'].includes(e?.code);
  } catch { return false; }
}
function accountBound(value) {
  if (!value || typeof value !== 'object') return false;
  if (value.previous_response_id || value.file_id || value.encrypted_content || value.type === 'item_reference') return true;
  return Object.values(value).some(v => typeof v === 'object' && accountBound(v));
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
async function createProxy(config, dependencies = {}) {
  const pool = config.pool;
  if (!Array.isArray(pool) || !pool.length || pool.length > 200 || new Set(pool.map(n => n.toLowerCase())).size !== pool.length || !['Ordered','Best'].includes(config.mode)) throw Error('Select 1-200 distinct accounts and Ordered or Best mode.');
  const getCredentials = dependencies.credentials || (name => credentials(config.root, name));
  const getRows = dependencies.rows || (() => cachedRows(config.root));
  const report = dependencies.report || (name => process.stderr.write('[Deck failover] Active account: ' + name + '\n'));
  // Production never accepts an upstream address from configuration or a request.
  const upstream = dependencies.upstream || 'https://chatgpt.com/backend-api/codex';
  for (const name of pool) getCredentials(name);
  const excluded = new Set();
  const choices = () => (config.mode === 'Best' ? rank(pool, getRows()) : pool).filter(n => !excluded.has(n));
  let current = config.owner || choices()[0];
  if (config.owner && !pool.includes(config.owner)) throw Error('Starting account is not in the pool.');
  const owner = current;
  if (!current) throw Error('No fresh usable pool account. Refresh usage first.');
  const secret = crypto.randomBytes(32).toString('hex');
  let busy = false;
  const server = http.createServer(async (req, res) => {
    // A capability URL, exact Host and no browser Origin prevent unauthenticated LAN/browser access.
    if (req.headers.host !== `127.0.0.1:${server.address().port}` || req.headers.origin || !req.url.startsWith('/' + secret + '/')) return reply(res, 403, 'Forbidden.');
    const route = req.url.slice(secret.length + 1);
    if (!((req.method === 'POST' && ['/responses','/responses/compact'].includes(route)) || (req.method === 'GET' && /^\/models(?:\?[^#]*)?$/.test(route)))) return reply(res, 404, 'Unsupported failover route.');
    if (busy) return reply(res, 409, 'Another request is active; concurrent failover requests are not supported.');
    busy = true;
    let outbound;
    const cancel = () => { if (!res.writableFinished) outbound?.destroy(); };
    res.on('close', cancel);
    try {
      if (req.headers['content-encoding'] && req.headers['content-encoding'] !== 'identity') return reply(res, 415, 'Compressed requests are not supported.');
      const body = await collect(req, MAX_BODY);
      let bound = false;
      if (req.method === 'POST') {
        let parsed; try { parsed = JSON.parse(body); } catch { return reply(res, 400, 'Expected JSON request.'); }
        bound = accountBound(parsed);
      }
      // Bound history cannot safely move across accounts, including on a later request.
      if (bound && current !== owner) return reply(res, 409, 'Account-scoped history cannot move between accounts. Start a new failover session.');
      let attempts = 0;
      while (!res.destroyed && attempts++ < pool.length) {
        if (excluded.has(current)) return reply(res, 429, 'Selected account quota is exhausted. Start a new session after refreshing usage.');
        const used = current, auth = getCredentials(used);
        const headers = { 'content-type':req.headers['content-type'] || 'application/json', accept:req.headers.accept || 'text/event-stream',
          authorization:'Bearer ' + auth.token, 'chatgpt-account-id':auth.id, 'accept-encoding':'identity', 'content-length':body.length };
        // Do not forward cookies, client credentials, account-affinity or arbitrary destination headers.
        for (const h of ['user-agent','originator','version','openai-beta']) if (req.headers[h]) headers[h] = req.headers[h];
        const url = new URL(upstream + route);
        const incoming = await new Promise((resolve, reject) => {
          outbound = (url.protocol === 'https:' ? https : http).request(url, { method:req.method, headers }, resolve);
          outbound.setTimeout(120000, () => outbound.destroy(Error('Upstream timeout.')));
          outbound.on('error', reject); outbound.end(body);
        });
        if (req.method === 'POST' && route === '/responses' && incoming.statusCode === 429) {
          const rejected = await collect(incoming, 1024 * 1024);
          if (quotaRejected(429, rejected)) {
            excluded.add(used);
            const next = choices()[0];
            if (next && !bound && !res.destroyed) { current = next; report(current); continue; }
            if (bound && next) return reply(res, 409, 'Quota reached, but this request contains account-scoped history. Start a new session to change accounts.');
          }
          res.writeHead(429, { 'content-type':'application/json', 'cache-control':'no-store' }); res.end(rejected); return;
        }
        const responseHeaders = { 'cache-control':'no-store' };
        for (const h of ['content-type','content-encoding','retry-after']) if (incoming.headers[h]) responseHeaders[h] = incoming.headers[h];
        res.writeHead(incoming.statusCode, responseHeaders);
        res.flushHeaders();
        // Once accepted, stream directly with backpressure. Never replay even if the stream fails.
        await new Promise(resolve => pipeline(incoming, res, () => resolve()));
        return;
      }
    } catch { reply(res, 502, 'Failover request failed. No retry was made for an ambiguous transport or credential error.'); }
    finally { busy = false; res.removeListener('close', cancel); }
  });
  server.on('upgrade', (_req, socket) => socket.destroy());
  server.on('clientError', (_err, socket) => socket.destroy());
  await new Promise((resolve,reject) => { server.once('error',reject); server.listen(0, '127.0.0.1', resolve); });
  return { server, baseUrl:`http://127.0.0.1:${server.address().port}/${secret}`, account:current };
}
module.exports = { createProxy, rank, quotaRejected, accountBound, credentials };
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
      process.stdout.write(JSON.stringify({ baseUrl:proxy.baseUrl, account:proxy.account }) + '\n');
    } catch { process.stderr.write('Deck failover could not start. Check pool logins and fresh usage.\n'); process.exit(1); }
    input = '';
  });
  process.stdin.on('end', () => process.exit(0));
}
