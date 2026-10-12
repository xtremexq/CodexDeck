import {providers} from './catalog.mjs';
import {HttpError,requireThat} from './errors.mjs';
import {accountInput,routeInput,settingsInput} from './config.mjs';

export async function hashKey(value){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),n=>n.toString(16).padStart(2,'0')).join('');}
export function newKey(){return 'aid_'+btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');}
function uniqueId(base,used){
  for(let suffix=2;;suffix++){
    const tail=`_imported_${suffix}`,candidate=`${base.slice(0,80-tail.length)}${tail}`;
    if(!used.has(candidate))return candidate;
  }
}
async function importWorkspace(store,body){
  requireThat(typeof body.sourceId==='string'&&/^[a-z0-9-]{16,64}$/i.test(body.sourceId),'Invalid Router settings import source.');
  const prior=store.secrets.workspaceImports||[];
  requireThat(Array.isArray(body.accounts)&&body.accounts.length<=100&&Array.isArray(body.routes)&&body.routes.length<=100&&(body.accounts.length||body.routes.length),'Router settings import is empty or too large.');
  const accounts=body.accounts,routes=body.routes;
  requireThat(new Set(accounts.map(a=>a?.id)).size===accounts.length,'Duplicate provider account IDs in the source configuration.');
  requireThat(new Set(routes.map(r=>r?.id)).size===routes.length,'Duplicate route aliases in the source configuration.');
  const previousImport=prior.find(item=>item.sourceId===body.sourceId);
  if(previousImport){
    const routeMap=previousImport.routeMap&&typeof previousImport.routeMap==='object'?previousImport.routeMap:{};
    for(const source of routes){
      if(typeof source?.id!=='string'||routeMap[source.id])continue;
      const imported=store.config.routes.find(route=>route.id.startsWith(`${source.id}_imported_`)&&route.name===source.name);
      const exact=store.config.routes.find(route=>route.id===source.id);
      const match=imported||exact;if(match)routeMap[source.id]=match.id;
    }
    let routeIds=Array.isArray(previousImport.routeIds)?previousImport.routeIds:Object.values(routeMap);
    routeIds=[...new Set(routeIds.filter(id=>store.config.routes.some(route=>route.id===id&&route.enabled)))];
    const bridgeHash=typeof body.bridgeKey==='string'?await hashKey(body.bridgeKey):'';
    const bridge=bridgeHash&&store.config.clients.find(client=>client.name==='Chrome Router bridge'&&client.hash===bridgeHash);
    if(bridge)bridge.routes=[...new Set([...(bridge.routes||[]),...routeIds])];
    if(bridge||!previousImport.routeMap){previousImport.routeIds=routeIds;previousImport.routeMap=routeMap;await store.save();}
    return {alreadyImported:true,accounts:0,routes:0,routeMap};
  }
  const accountIds=new Set(store.config.accounts.map(a=>a.id)),routeIds=new Set(store.config.routes.map(r=>r.id));
  const accountMap=Object.create(null),routeMap=Object.create(null),plannedAccounts=[],plannedRoutes=[],plannedSecrets=Object.create(null);
  for(const source of accounts){
    requireThat(source&&typeof source.id==='string','Invalid provider account in imported Router settings.');
    requireThat(source&&typeof source.apiKey==='string'&&source.apiKey.length<=8192&&!/[\r\n]/.test(source.apiKey),'Invalid provider API key in imported Router settings.');
    const sourceId=source.id;
    let id=sourceId;
    const input={id,name:source.name,provider:source.provider,baseUrl:source.baseUrl,proxyUrl:source.proxyUrl,capabilities:source.capabilities,webOptions:source.webOptions,enabled:source.enabled};
    const normalized=accountInput(input,{},store.allowWebProviders===true);
    requireThat(providers.find(provider=>provider.id===normalized.provider)?.webSession||normalized.provider==='custom'||source.apiKey.trim().length,'Imported provider account is missing its API key.');
    const matchesSource=(existing,secret)=>JSON.stringify({...existing,id:sourceId})===JSON.stringify(normalized)&&secret===source.apiKey;
    const sameId=store.config.accounts.find(a=>a.id===sourceId);
    if(sameId&&matchesSource(sameId,store.secrets.accounts?.[sourceId]||'')){accountMap[sourceId]=sourceId;continue;}
    const earlierImport=store.config.accounts.find(a=>a.id.startsWith(`${sourceId}_imported_`)&&matchesSource(a,store.secrets.accounts?.[a.id]||''));
    if(earlierImport){accountMap[sourceId]=earlierImport.id;continue;}
    if(accountIds.has(id)){id=uniqueId(sourceId,accountIds);input.id=id;}
    const account=accountInput(input,{},store.allowWebProviders===true);
    accountIds.add(id);accountMap[sourceId]=id;plannedAccounts.push(account);if(source.apiKey)plannedSecrets[id]=source.apiKey;
  }
  const knownAccounts=[...store.config.accounts,...plannedAccounts];
  for(const source of routes){
    requireThat(source&&Array.isArray(source.targets),'Invalid route in imported Router settings.');
    const targets=source.targets.map(target=>({account:accountMap[target.account]||'',model:target.model}));
    let id=source.id;
    let route=routeInput({...source,id,targets},knownAccounts);
    const matchesRoute=existing=>JSON.stringify(existing)===JSON.stringify({...route,id:existing.id});
    const exact=store.config.routes.find(item=>item.id===id);
    if(exact&&matchesRoute(exact)){routeMap[source.id]=exact.id;continue;}
    const earlierImport=store.config.routes.find(item=>item.id.startsWith(`${source.id}_imported_`)&&item.name===source.name&&matchesRoute(item));
    if(earlierImport){routeMap[source.id]=earlierImport.id;continue;}
    if(exact){id=uniqueId(id,routeIds);route=routeInput({...source,id,targets},knownAccounts);}
    routeIds.add(id);routeMap[source.id]=id;plannedRoutes.push(route);
  }
  const previousConfig=store.config,previousSecrets=store.secrets;
  store.config=structuredClone(store.config);store.secrets=structuredClone(store.secrets);
  store.config.accounts.push(...plannedAccounts);store.config.routes.push(...plannedRoutes);
  store.secrets.accounts={...(store.secrets.accounts||{}),...plannedSecrets};
  if(!store.config.settings.defaultRoute&&body.settings?.defaultRoute){
    const importedDefault=routeMap[body.settings.defaultRoute];
    if(importedDefault&&store.config.routes.some(route=>route.id===importedDefault&&route.enabled))store.config.settings.defaultRoute=importedDefault;
  }
  const importedRouteIds=[...new Set(Object.values(routeMap).filter(id=>store.config.routes.some(route=>route.id===id&&route.enabled)))];
  const bridgeHash=typeof body.bridgeKey==='string'?await hashKey(body.bridgeKey):'';
  const bridge=bridgeHash&&store.config.clients.find(client=>client.name==='Chrome Router bridge'&&client.hash===bridgeHash);
  if(bridge)bridge.routes=[...new Set([...(bridge.routes||[]),...importedRouteIds])];
  store.secrets.workspaceImports=[...(store.secrets.workspaceImports||[]),{sourceId:body.sourceId,routeIds:importedRouteIds,routeMap,at:new Date().toISOString()}];
  try{await store.save();}catch(error){store.config=previousConfig;store.secrets=previousSecrets;throw error;}
  return {alreadyImported:false,accounts:plannedAccounts.length,routes:plannedRoutes.length,routeMap};
}
export async function administer(store,router,path,{method='GET',body={},signal=AbortSignal.timeout(30000),deck}={}){
  const [resource,id,action]=path.replace(/^\/admin\//,'').split('/');
  if(resource==='state'&&method==='GET')return {config:store.publicConfig(),providers:store.allowWebProviders?providers:providers.filter(provider=>!provider.webSession),...(deck?{deck:deck.list()}:{ }),runtime:{active:router.active,requests:router.count,events:router.events,cooldowns:Object.fromEntries(router.cooldowns),...(router.webProviderBridge?{webProviderExtensionOnline:router.webProviderBridge.online}:{})}};
  if(resource==='deck'){
    requireThat(deck,'Connect the optional Deck server to use native accounts and terminals.',409);
    return method==='GET'?deck.list():deck.launch(body);
  }
  if(resource==='import'&&method==='POST')return importWorkspace(store,body);
  if(resource==='accounts'){
    const current=store.config.accounts.find(a=>a.id===id);
    if(action==='models'&&method==='GET'){
      requireThat(current,'Account not found.',404);
      const {response}=await router.adapters.request(current,store.secrets.accounts[id]||'','/models',{},signal,{method:'GET'});
      if(!response.ok&&providers.find(provider=>provider.id===current.provider)?.webSession){
        let detail='';try{detail=(await response.json())?.error?.message||'';}catch{}
        throw new HttpError(response.status,detail||`Model discovery returned HTTP ${response.status}. You can also enter model IDs manually.`,'model_discovery_error');
      }
      requireThat(response.ok,`Model discovery returned HTTP ${response.status}. You can also enter model IDs manually.`,502);
      const value=await response.json();return {models:(value.models||value.data||value.result||[]).map(m=>({id:m.id||m.name,name:m.display_name||m.name||m.id})).filter(m=>m.id)};
    }
    if(method==='POST'||method==='PUT'){
      if(id)requireThat(current,'Account not found.',404);
      const account=accountInput({...body,...(id?{id}:{})},current,store.allowWebProviders===true);
      requireThat(current||!store.config.accounts.some(a=>a.id===account.id),'Account already exists.',409);
      const webSession=providers.find(provider=>provider.id===account.provider)?.webSession===true;
      requireThat(!current||current.provider===account.provider||body.apiKey||webSession,'Changing provider requires a new API key.');
      const key=body.apiKey===undefined?store.secrets.accounts[account.id]:body.apiKey;
      requireThat(webSession||account.provider==='custom'||typeof key==='string'&&key.trim().length,'Add an API key for this provider.');
      if(webSession)requireThat(!store.config.accounts.some(existing=>existing.provider===account.provider&&existing.id!==account.id),'Chrome uses one signed-in browser session per web provider.');
      if(body.apiKey!==undefined){requireThat(typeof body.apiKey==='string'&&body.apiKey.length<=8192&&!/[\r\n]/.test(body.apiKey),'Invalid API key.');if(body.apiKey)store.secrets.accounts[account.id]=body.apiKey;else delete store.secrets.accounts[account.id];}
      if(webSession)delete store.secrets.accounts[account.id];
      if(current)Object.assign(current,account);else store.config.accounts.push(account);
      await store.save();return {...account,hasKey:!!store.secrets.accounts[account.id]};
    }
    if(method==='DELETE'&&id){requireThat(!store.config.routes.some(r=>r.targets.some(t=>t.account===id)),'Remove this account from its routes before deleting it.',409);store.config.accounts=store.config.accounts.filter(a=>a.id!==id);delete store.secrets.accounts[id];await store.save();return {deleted:true};}
  }
  if(resource==='routes'){
    if(method==='POST'||method==='PUT'){
      const route=routeInput(body,store.config.accounts,deck?.list().accounts||[]),current=store.config.routes.find(r=>r.id===(id||route.id));
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
    if(method==='POST'||method==='PUT'&&id){
      const current=id?store.config.clients.find(client=>client.id===id):null;
      if(method==='PUT')requireThat(current,'Integration key not found.',404);
      requireThat(typeof body.name==='string'&&body.name.trim().length&&body.name.length<=100,'Enter an integration name.');
      requireThat(Array.isArray(body.routes),'Choose at least one route or All routes.');
      const requested=[...new Set(body.routes)];
      requireThat(requested.every(route=>route==='*'||store.config.routes.some(existing=>existing.id===route)),'Choose existing routes or All routes.');
      const routes=requested.includes('*')?['*']:requested;
      requireThat(routes.length,'Choose at least one route or All routes.');
      requireThat(Number.isInteger(body.rpm)&&body.rpm>=1&&body.rpm<=600,'Request limit must be 1–600 per minute.');
      const values={name:body.name.trim(),routes,rpm:body.rpm,enabled:body.enabled===undefined?current?.enabled!==false:body.enabled!==false};
      if(current){Object.assign(current,values);await store.save();return {id:current.id,...values,created:current.created};}
      const key=newKey(),record={id:crypto.randomUUID(),...values,hash:await hashKey(key),created:new Date().toISOString()};store.config.clients.push(record);await store.save();return {...record,hash:undefined,key};
    }
    if(method==='DELETE'&&id){store.config.clients=store.config.clients.filter(c=>c.id!==id);await store.save();return {deleted:true};}
  }
  throw new HttpError(404,'Unknown administration endpoint.');
}
