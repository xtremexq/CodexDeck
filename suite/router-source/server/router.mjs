const randomUUID = () => globalThis.crypto.randomUUID();
import { endpoints } from './catalog.mjs';
import { HttpError, requireThat } from './errors.mjs';
import { Adapters, fromAnthropic, anthropicStream, chatToMessages, messagesStream, messagesToChat } from './adapters.mjs';

const clientCanUseRoute=(client,routeId)=>!client||client.routes?.includes('*')||client.routes?.includes(routeId);

export class Router {
  constructor(store, adapters = new Adapters(), deck = null) { this.store = store; this.adapters = adapters; this.deck = deck; this.cooldowns = new Map(); this.cursors = new Map(); this.events = []; this.active = 0; this.count = 0; }
  record(event) { this.events.unshift({ at: new Date().toISOString(), ...event }); this.events.length = Math.min(this.events.length,200); }
  models(client) {
    return this.store.config.routes.filter(r => r.enabled && clientCanUseRoute(client,r.id)).map(r => ({ id: r.id, object: 'model', created: 0, owned_by: 'aideck-router' }));
  }
  select(body, capability, client) {
    const config = this.store.config;
    const alias = body.model || config.settings.defaultRoute;
    const route = config.routes.find(r => r.id === alias && r.enabled);
    requireThat(route, 'No enabled route matches this model. Create a route alias in AIDeck Router.', 404);
    requireThat(clientCanUseRoute(client,route.id), 'This integration key cannot use that route.', 403);
    const deckAccounts=this.deck?.list().accounts||[];
    let targets = route.targets.map(t => {
      if(t.account.startsWith('deck:')){
        const native=deckAccounts.find(a=>`deck:${a.id}`===t.account&&a.routable&&a.harness==='Codex');
        return {...t,accountConfig:native&&(capability==='chat'||capability==='messages')?{id:t.account,deckAccountId:native.id,harness:native.harness,provider:native.provider,name:`${native.id} · ${native.harness}`,enabled:true,capabilities:['chat'],native:true}:null};
      }
      return {...t,accountConfig:config.accounts.find(a=>a.id===t.account&&a.enabled&&(a.capabilities.includes(capability)||capability==='messages'&&a.capabilities.includes('chat')))};
    }).filter(t => t.accountConfig);
    requireThat(targets.length, `No enabled target on ${route.id} supports ${capability}.`, 501);
    if (route.strategy === 'round-robin') { const offset = (this.cursors.get(route.id) || 0) % targets.length; this.cursors.set(route.id,offset+1); targets = [...targets.slice(offset), ...targets.slice(0,offset)]; }
    if (!route.failover) targets = targets.slice(0,1);
    const ready = targets.filter(t => (this.cooldowns.get(t.account) || 0) <= Date.now());
    requireThat(ready.length, 'All matching accounts are cooling down. Retry shortly.', 503);
    return { route: structuredClone(route), targets: ready };
  }
  async execute(endpoint, body, res, client, signal, rawOptions) {
    const capability = endpoints.get(endpoint);
    requireThat(capability, 'Unsupported API endpoint.', 404);
    const { route, targets } = this.select(body,capability,client);
    requireThat(this.active < 32, 'Gateway concurrency limit reached.', 429);
    const requestId = randomUUID(); const started = Date.now(); let attempts = 0; let lastError;
    this.active++; this.count++;
    try {
      for (const target of targets) {
        attempts++;
        const account = target.accountConfig;
        const combinedSignal = AbortSignal.any([signal, AbortSignal.timeout(this.store.config.settings.timeoutMs)]);
        let response, upstream;
        try {
          let payload = { ...body, model: target.model };
          let nativeReverse=false;
          if(account.native){
            if(endpoint==='/messages'){payload=messagesToChat(payload);payload.model=target.model;nativeReverse=true;}
            const value=await this.deck.run(account.deckAccountId,account.harness,target.model,payload,combinedSignal);
            let content;
            if(body.stream){
              const id=value.id,created=value.created,model=value.model,choice=value.choices[0],chunks=[
                {id,object:'chat.completion.chunk',created,model,choices:[{index:0,delta:{role:'assistant'},finish_reason:null}]},
                ...(choice.message.content?[{id,object:'chat.completion.chunk',created,model,choices:[{index:0,delta:{content:choice.message.content},finish_reason:null}]}]:[]),
                {id,object:'chat.completion.chunk',created,model,choices:[{index:0,delta:{},finish_reason:choice.finish_reason}],...(body.stream_options?.include_usage?{usage:value.usage}: {})}
              ];
              content=''+chunks.map(chunk=>`data: ${JSON.stringify(chunk)}\n\n`).join('')+'data: [DONE]\n\n';
            }else content=JSON.stringify(value);
            response=new Response(content,{status:200,headers:{'content-type':body.stream?'text/event-stream':'application/json'}});
            upstream={response,translated:false,reverse:nativeReverse,native:true};
          }else{
          let outgoing=payload;
          if(rawOptions?.form){outgoing=new FormData();for(const[key,value]of rawOptions.form)if(key!=='model')outgoing.append(key,value);outgoing.set('model',target.model);}
          upstream = await this.adapters.request(account,this.store.secrets.accounts[account.id] || '',endpoint,outgoing,combinedSignal,rawOptions);
          response = upstream.response;
          }
          if (!response.ok) {
            await response.body?.cancel();
            const retryable = [408,409,425,429,500,502,503,504,529].includes(response.status) || (route.retryAuthErrors && [401,403].includes(response.status));
            const error = new HttpError(response.status, `${account.name}: upstream returned HTTP ${response.status}.`, 'upstream_error');
            error.retryable = retryable;
            const retryAfter = response.headers.get('retry-after');
            error.cooldownMs = Math.min(300000, Math.max(this.store.config.settings.cooldownMs, (/^\d+$/.test(retryAfter || '') ? Number(retryAfter)*1000 : Date.parse(retryAfter) - Date.now()) || 0));
            throw error;
          }
          const headers = { 'x-aideck-route': route.id, 'x-aideck-account': account.id, 'x-request-id': requestId, 'cache-control': 'no-store' };
          if (account.native && body.stream) headers['x-aideck-streaming'] = 'buffered';
          // Hold headers until the first body read succeeds. Never replay an emitted stream.
          if ((upstream.translated || upstream.reverse) && body.stream) {
            const generator = upstream.reverse ? messagesStream(response.body,target.model) : anthropicStream(response.body,target.model,body.stream_options?.include_usage);
            const first = await generator.next();
            requireThat(!first.done, 'Upstream stream was empty.', 502);
            res.writeHead(200,{ ...headers, 'content-type': 'text/event-stream' });
            await write(res,first.value);
            for await (const chunk of generator) await write(res,chunk);
            res.end();
          } else if (upstream.translated || upstream.reverse) {
            const value = (upstream.reverse ? chatToMessages : fromAnthropic)(await response.json());
            res.writeHead(200,{ ...headers, 'content-type': 'application/json' }); res.end(JSON.stringify(value));
          } else {
            const reader = response.body?.getReader();
            requireThat(reader, 'Upstream response has no body.', 502);
            try {
              const first = await reader.read();
              requireThat(!first.done, 'Upstream returned an empty response.', 502);
              res.writeHead(response.status,{ ...headers, 'content-type': response.headers.get('content-type') || 'application/json' });
              await write(res,first.value);
              while (true) { const chunk = await reader.read(); if (chunk.done) break; await write(res,chunk.value); }
              res.end();
            } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
          }
          this.cooldowns.delete(account.id);
          this.record({ id: requestId, route: route.id, account: account.id, model: target.model, status: 'success', attempts, ms: Date.now()-started });
          return;
        } catch (error) {
          await response?.body?.cancel().catch(() => {});
          lastError = error instanceof HttpError ? error : new HttpError(combinedSignal.aborted ? 504 : 502, combinedSignal.aborted ? 'Upstream request timed out or was cancelled.' : 'Could not reach the upstream provider.', 'upstream_unavailable');
          this.record({ id: requestId, route: route.id, account: account.id, model: target.model, status: res.headersSent ? 'stream-error' : 'failed-attempt', httpStatus: lastError.status, attempts, ms: Date.now()-started });
          if (signal.aborted || res.headersSent) throw lastError;
          if (error instanceof HttpError && !error.retryable && ![502,504].includes(error.status)) throw lastError;
          this.cooldowns.set(account.id,Date.now() + (error.cooldownMs || this.store.config.settings.cooldownMs));
        }
      }
      throw lastError || new HttpError(503,'No route target is currently available.');
    } finally { this.active--; }
  }
}
async function write(res, data) {
  requireThat(!res.destroyed, 'Client disconnected.', 499);
  if (!res.write(data)) await new Promise((resolve,reject) => {
    const clean = () => { res.off('drain',drain); res.off('close',close); res.off('error',error); };
    const drain = () => { clean(); resolve(); };
    const close = () => { clean(); reject(new HttpError(499,'Client disconnected.')); };
    const error = e => { clean(); reject(e); };
    res.once('drain',drain); res.once('close',close); res.once('error',error);
  });
}
