import {providers} from './catalog.mjs';
import {HttpError,requireThat} from './errors.mjs';
import {accountInput,routeInput,settingsInput} from './config.mjs';

export async function hashKey(value){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),n=>n.toString(16).padStart(2,'0')).join('');}
export function newKey(){return 'aid_'+btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');}
export async function administer(store,router,path,{method='GET',body={},signal=AbortSignal.timeout(30000),deck}={}){
  const [resource,id,action]=path.replace(/^\/admin\//,'').split('/');
  if(resource==='state'&&method==='GET')return {config:store.publicConfig(),providers,runtime:{active:router.active,requests:router.count,events:router.events,cooldowns:Object.fromEntries(router.cooldowns)}};
  if(resource==='deck'){
    requireThat(deck,'Connect the optional Deck server to use native accounts and terminals.',409);
    return method==='GET'?deck.list():deck.launch(body);
  }
  if(resource==='accounts'){
    const current=store.config.accounts.find(a=>a.id===id);
    if(action==='models'&&method==='GET'){
      requireThat(current,'Account not found.',404);
      const {response}=await router.adapters.request(current,store.secrets.accounts[id]||'','/models',{},signal,{method:'GET'});
      requireThat(response.ok,`Model discovery returned HTTP ${response.status}. You can also enter model IDs manually.`,502);
      const value=await response.json();return {models:(value.data||value.result||[]).map(m=>({id:m.id||m.name,name:m.display_name||m.name||m.id})).filter(m=>m.id)};
    }
    if(method==='POST'||method==='PUT'){
      if(id)requireThat(current,'Account not found.',404);
      const account=accountInput({...body,...(id?{id}:{})},current);
      requireThat(current||!store.config.accounts.some(a=>a.id===account.id),'Account already exists.',409);
      requireThat(!current||current.provider===account.provider||body.apiKey,'Changing provider requires a new API key.');
      const key=body.apiKey===undefined?store.secrets.accounts[account.id]:body.apiKey;
      requireThat(account.provider==='custom'||typeof key==='string'&&key.trim().length,'Add an API key for this provider.');
      if(body.apiKey!==undefined){requireThat(typeof body.apiKey==='string'&&body.apiKey.length<=8192&&!/[\r\n]/.test(body.apiKey),'Invalid API key.');if(body.apiKey)store.secrets.accounts[account.id]=body.apiKey;else delete store.secrets.accounts[account.id];}
      if(current)Object.assign(current,account);else store.config.accounts.push(account);
      await store.save();return {...account,hasKey:!!store.secrets.accounts[account.id]};
    }
    if(method==='DELETE'&&id){requireThat(!store.config.routes.some(r=>r.targets.some(t=>t.account===id)),'Remove this account from its routes before deleting it.',409);store.config.accounts=store.config.accounts.filter(a=>a.id!==id);delete store.secrets.accounts[id];await store.save();return {deleted:true};}
  }
  if(resource==='routes'){
    if(method==='POST'||method==='PUT'){
      const route=routeInput(body,store.config.accounts),current=store.config.routes.find(r=>r.id===(id||route.id));
      if(method==='PUT')requireThat(current&&id===route.id,'Existing route aliases cannot be renamed.');else requireThat(!current,'Route alias already exists.',409);
      if(current)Object.assign(current,route);else store.config.routes.push(route);
      if(!store.config.settings.defaultRoute&&route.enabled)store.config.settings.defaultRoute=route.id;
      if(store.config.settings.defaultRoute===route.id&&!route.enabled)store.config.settings.defaultRoute=store.config.routes.find(r=>r.enabled)?.id||'';
      await store.save();return route;
    }
    if(method==='DELETE'&&id){store.config.routes=store.config.routes.filter(r=>r.id!==id);if(store.config.settings.defaultRoute===id)store.config.settings.defaultRoute=store.config.routes.find(r=>r.enabled)?.id||'';for(const client of store.config.clients)client.routes=client.routes.filter(r=>r!==id);await store.save();return {deleted:true};}
  }
  if(resource==='settings'&&method==='PUT'){
    const settings=settingsInput(body,store.config.settings);requireThat(!settings.defaultRoute||store.config.routes.some(r=>r.id===settings.defaultRoute&&r.enabled),'Default route must be enabled.');store.config.settings=settings;await store.save();return settings;
  }
  if(resource==='clients'){
    if(method==='POST'){
      requireThat(typeof body.name==='string'&&body.name.trim().length&&body.name.length<=100,'Enter an integration name.');
      requireThat(Array.isArray(body.routes)&&body.routes.length&&body.routes.every(r=>store.config.routes.some(t=>t.id===r)),'Allow at least one existing route.');requireThat(Number.isInteger(body.rpm)&&body.rpm>=1&&body.rpm<=600,'Request limit must be 1–600 per minute.');
      const key=newKey(),record={id:crypto.randomUUID(),name:body.name.trim(),hash:await hashKey(key),routes:[...new Set(body.routes)],rpm:body.rpm,enabled:true,created:new Date().toISOString()};store.config.clients.push(record);await store.save();return {...record,hash:undefined,key};
    }
    if(method==='DELETE'&&id){store.config.clients=store.config.clients.filter(c=>c.id!==id);await store.save();return {deleted:true};}
  }
  throw new HttpError(404,'Unknown administration endpoint.');
}
