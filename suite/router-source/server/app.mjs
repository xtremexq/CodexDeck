import { administer } from './admin.mjs';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { endpoints } from './catalog.mjs';
import { HttpError, requireThat, errorBody } from './errors.mjs';
import { equalToken, tokenHash } from './store.mjs';
import { Router } from './router.mjs';
import { deckAccounts, launchDeck } from './deck.mjs';

const uiRoot = fileURLToPath(new URL('../ui/',import.meta.url));
const mime = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml' };
const staticFiles = new Set(['index.html','app.js','style.css','logo.svg']);
const MAX_BODY = 24 * 1024 * 1024;
async function readBuffer(req) {
  let size = 0; const chunks = [];
  for await (const chunk of req) { size += chunk.length; requireThat(size <= MAX_BODY, 'Request exceeds 24 MB.',413); chunks.push(chunk); }
  return Buffer.concat(chunks);
}
async function readJson(req) {
  requireThat((req.headers['content-type'] || '').split(';')[0] === 'application/json','Send Content-Type: application/json.',415);
  let value; try { value = JSON.parse((await readBuffer(req)).toString('utf8')); } catch (e) { if (e instanceof HttpError) throw e; throw new HttpError(400,'Request body is not valid JSON.'); }
  requireThat(value && typeof value === 'object' && !Array.isArray(value),'Send a JSON object.'); return value;
}
const send = (res, status, value) => { res.writeHead(status,{ 'content-type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(value)); };
export function createApp(store, { router = new Router(store), deckLauncher = launchDeck, pairing } = {}) {
  const rates = new Map();
  const server = http.createServer(async (req,res) => {
    const controller = new AbortController();
    res.on('close',() => { if (!res.writableFinished) controller.abort(); });
    res.setHeader('cache-control','no-store');
    res.setHeader('x-content-type-options','nosniff');
    res.setHeader('referrer-policy','no-referrer');
    try {
      const host = req.headers.host || '';
      requireThat(/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(host), 'Invalid gateway host.',403);
      const url = new URL(req.url,`http://${host}`);
      const origin = req.headers.origin;
      const ownOrigins = new Set([`http://${host}`,`http://127.0.0.1:${server.address()?.port}`,`http://localhost:${server.address()?.port}`]);
      const extension = /^chrome-extension:\/\/[a-p]{32}$/.test(origin || '');
      const own = !origin || ownOrigins.has(origin) || extension;
      requireThat(own || store.config.settings.allowedOrigins.includes(origin),'Website origin is not allowed. Add it in Settings.',403);
      if (origin) {
        res.setHeader('access-control-allow-origin',origin); res.setHeader('vary','Origin');
        res.setHeader('access-control-allow-methods','GET, POST, PUT, DELETE, OPTIONS');
        res.setHeader('access-control-allow-headers','Authorization, Content-Type, X-API-Key, Anthropic-Version');
        res.setHeader('access-control-expose-headers','X-AIDeck-Route, X-AIDeck-Account, X-Request-ID');
      }
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      if (url.pathname === '/health' && req.method === 'GET') { send(res,200,{ name: 'AIDeck Router', version: '0.1.0', status: 'ready' }); return; }
      if(url.pathname==='/pair'&&req.method==='POST'||url.pathname.startsWith('/pair/')&&['GET','POST'].includes(req.method)){
        requireThat(pairing&&extension,'Pairing is available only to Chrome extensions on an enabled local server.',403);
        const extensionId=origin.slice('chrome-extension://'.length);
        const proof=req.method==='POST'?(await readJson(req)).secret:(req.headers.authorization||'').replace(/^Bearer /i,'');
        const result=url.pathname==='/pair'?pairing.create(extensionId,proof):await pairing.claim(url.pathname.slice(6),extensionId,proof);
        send(res,200,result);return;
      }
      const staticFile = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
      if (req.method === 'GET' && staticFiles.has(staticFile)) {
        res.setHeader('content-security-policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' http://127.0.0.1:* http://localhost:*; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
        res.writeHead(200,{ 'content-type': mime[path.extname(staticFile)] }); fs.createReadStream(path.join(uiRoot,staticFile)).pipe(res); return;
      }
      const token = (req.headers.authorization || '').replace(/^Bearer /i,'') || req.headers['x-api-key'];
      const admin = equalToken(token,store.secrets.adminToken);
      const client = admin ? null : store.config.clients.find(c => c.hash === tokenHash(typeof token === 'string' ? token : '') && c.enabled);
      requireThat(admin || client,'Pair with a valid gateway key.',401);
      const rateKey = client?.id || 'admin'; const now = Date.now();
      if (rates.size > 1000) for (const [key,value] of rates) if (value.at < now-60000) rates.delete(key);
      const window = rates.get(rateKey);
      if (!window || now-window.at > 60000) rates.set(rateKey,{ at: now, count: 1 });
      else { window.count++; requireThat(window.count <= (client?.rpm || 600),'Integration request limit reached.',429); }
      if (url.pathname.startsWith('/admin/')) {
        requireThat(admin && own,'This action requires the owner key from the local dashboard or extension.',403);
        const body = ['POST','PUT'].includes(req.method) ? await readJson(req) : {};
        const value = await administer(store,router,url.pathname,{method:req.method,body,signal:AbortSignal.any([controller.signal,AbortSignal.timeout(store.config.settings.timeoutMs)]),deck:{list:()=>deckAccounts(store.config.settings),launch:input=>deckLauncher(store.config.settings,input)}});
        send(res,req.method==='POST' && url.pathname==='/admin/clients'?201:200,value);return;
      }
      if (url.pathname === '/v1/models' && req.method === 'GET') { send(res,200,{ object: 'list', data: router.models(client) }); return; }
      if (url.pathname.startsWith('/v1/') && req.method === 'POST') {
        const endpoint = url.pathname.slice(3); requireThat(endpoints.has(endpoint),'Unsupported API endpoint.',404);
        let body,rawOptions;
        if(['/audio/transcriptions','/audio/translations'].includes(endpoint) && req.headers['content-type']?.startsWith('multipart/form-data;')) {
          const buffer=await readBuffer(req);let form;
          try{form=await new Response(buffer,{headers:{'Content-Type':req.headers['content-type']}}).formData();}catch{throw new HttpError(400,'Invalid multipart audio request.');}
          requireThat(form.get('file') instanceof Blob,'Audio upload requires a file.');
          body={model:form.get('model')||store.config.settings.defaultRoute};rawOptions={form,raw:true};
        }else body=await readJson(req);
        if (endpoint === '/chat/completions') requireThat(Array.isArray(body.messages) && body.messages.length,'Include chat messages.');
        await router.execute(endpoint,body,res,client,controller.signal,rawOptions); return;
      }
      throw new HttpError(404,'Unknown gateway endpoint.');
    } catch (error) {
      const safe = error instanceof HttpError ? error : new HttpError(500,'The gateway could not complete this operation.');
      if (!res.headersSent && !res.destroyed) send(res,safe.status,errorBody(safe));
      else if (!res.destroyed) {
        if (String(res.getHeader('content-type') || '').includes('text/event-stream')) res.end('data: ' + JSON.stringify(errorBody(safe)) + '\n\n');
        else res.destroy();
      }
    }
  });
  server.headersTimeout = 10000;
  server.requestTimeout = 30000;
  return { server, router, listen: (port = 0) => new Promise((resolve,reject) => { const fail=error=>reject(error);server.once('error',fail);server.listen(port,'127.0.0.1',() => {server.off('error',fail);resolve(server.address().port);}); }), close: async () => { server.closeIdleConnections(); await new Promise(resolve => server.close(resolve)); await router.adapters.close(); } };
}
