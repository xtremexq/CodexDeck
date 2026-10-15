'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { once } = require('node:events');
const { createProxy, rank, quotaRejected, contextEntries, projectContext } = require('./Deck.Failover.cjs');
const quota = JSON.stringify({error:{type:'usage_limit_reached'}});
const row = (pct, age = 0) => ({Status:'available', CheckedAt:new Date(Date.now()-age).toISOString(), Windows:[{RemainingPct:pct}]});
async function main() {
  const realShape={instructions:'Follow the system rules',tools:[{type:'custom',name:'exec',description:'Run code'}],input:[
    {type:'custom_tool_call',name:'exec',call_id:'call-real',input:'const result = await tools.exec_command({cmd:"rg TODO"});'},
    {type:'custom_tool_call_output',call_id:'call-real',output:[{type:'input_text',text:'Ran rg TODO'},{type:'input_text',text:'match one\nmatch two'}]},
    {type:'reasoning',summary:[],encrypted_content:'encrypted-only'}
  ]};
  const realEntries=contextEntries(realShape);
  assert.equal(realEntries.length,5,'Instructions and tool definitions must appear alongside the input history');
  assert.equal(realEntries[2].text,realShape.input[0].input,'Custom tool code must be visible');
  assert.equal(realEntries[3].text,'Ran rg TODO\nmatch one\nmatch two','All custom tool output blocks must be visible');
  assert.equal(realEntries[3].editable,true,'Text-block tool results must support editing');
  assert.match(realEntries[4].preview,/Encrypted reasoning/,'Encrypted reasoning must be identified honestly');
  assert.equal(realEntries[4].editable,false);
  const fallbackEntry=contextEntries({input:[{type:'message',output:[],content:[{type:'input_text',text:'Visible after empty output'}]}]})[0];
  assert.equal(fallbackEntry.text,'Visible after empty output','An empty earlier field must not hide later text');
  assert.equal(projectContext({input:[fallbackEntry.raw]},new Map([[fallbackEntry.key,{action:'edit',text:'Replacement'}]]),false).output.input[0].content[0].text,'Replacement');
  const editRules=new Map([[realEntries[3].key,{action:'edit',text:'short result'}]]);
  const edited=projectContext(realShape,editRules,false).output;
  assert.equal(edited.input[1].output[0].text,'short result');
  assert.equal(edited.input[1].output[1].text,'');
  assert.equal(realShape.input[1].output[1].text,'match one\nmatch two','Projection must leave the original request intact');
  const suppressed=projectContext(realShape,new Map([[realEntries[2].key,{action:'suppress'}],[realEntries[3].key,{action:'suppress'}]]),false).output;
  assert.deepEqual(suppressed.input.map(item=>item.type),['reasoning']);
  assert.equal(suppressed.instructions,realShape.instructions);
  assert.equal(suppressed.tools.length,1);
  const protectedRules=new Map([[realEntries[0].key,{action:'suppress'}],[realEntries[1].key,{action:'suppress'}]]);
  assert.equal(projectContext(realShape,protectedRules,false).output.instructions,realShape.instructions,'Protected request fields must remain without override');
  const overridden=projectContext(realShape,protectedRules,true).output;
  assert.equal('instructions' in overridden,false,'Advanced suppression must remove top-level instructions');
  assert.equal(overridden.tools.length,0,'Advanced suppression must remove the selected tool definition');
  assert.deepEqual(rank(['a','b','c'], {a:row(30),b:row(80),c:row(90,310000)}), ['b','a']);
  assert.equal(quotaRejected(429,quota),true);
  for (const [status,body,expected] of [[401,quota,false],[500,quota,false],[429,'{"error":{"type":"rate_limit_exceeded"}}',true],[429,'invalid',false]]) assert.equal(quotaRejected(status,body),expected);
  let behavior, seen = [], reports = [];
  let clock = Date.now();
  const upstream = http.createServer(async (req,res) => {
    const parts=[]; for await (const part of req) parts.push(part);
    seen.push({account:req.headers['chatgpt-account-id'],auth:req.headers.authorization,body:Buffer.concat(parts).toString(),headers:req.headers,url:req.url,method:req.method});
    behavior(req,res);
  });
  upstream.listen(0,'127.0.0.1'); await once(upstream,'listening');
  const proxies=[];
  const modelRoot=fs.mkdtempSync(path.join(os.tmpdir(),'deck-context-status-'));
  for(const account of ['a','b']){
    const dir=path.join(modelRoot,'accounts',account);fs.mkdirSync(dir,{recursive:true});
    fs.writeFileSync(path.join(dir,'models_cache.json'),JSON.stringify({models:[{slug:'gpt-test',context_window:100000,effective_context_window_percent:90}]}));
  }
  async function start(extra={}, deps={}) {
    seen=[]; reports=[];
    const p=await createProxy({pool:['a','b','c'],mode:'Ordered',...extra}, {
      upstream:`http://127.0.0.1:${upstream.address().port}`,
      credentials:name=>({token:'synthetic-'+name,id:name}), rows:()=>({a:row(30),b:row(80),c:row(60)}),
      report:name=>reports.push(name), now:()=>clock, ...deps
    }); proxies.push(p.server); return p.baseUrl;
  }
  const send=(url,body={},headers={})=>fetch(url+'/responses',{method:'POST',body:JSON.stringify(body),headers:{'content-type':'application/json',...headers}});
  const compact=(url,body={})=>fetch(url+'/responses/compact',{method:'POST',body:JSON.stringify(body)});
  const select=(url,account,headers={})=>fetch(url+'/_deck/account',{method:'POST',body:JSON.stringify({account}),headers:{'content-type':'application/json',...headers}});
  const context=(url,body)=>fetch(url+'/_deck/context',{method:body?'POST':'GET',headers:body?{'content-type':'application/json'}:{},body:body?JSON.stringify(body):undefined});
  try {
    behavior=(req,res)=> { if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429);res.end(quota);} else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: success\n\n');} };
    let url=await start(); let result=await send(url,{input:'synthetic'},{authorization:'Bearer client-secret',cookie:'private', 'x-account-id':'wrong'});
    assert.equal(await result.text(),'data: success\n\n'); assert.deepEqual(seen.map(r=>r.account),['a','b']); assert.deepEqual(reports,['b']);
    assert.equal(seen[1].auth,'Bearer synthetic-b'); assert.equal(seen[1].headers.cookie,undefined); assert.equal(seen[1].headers['x-account-id'],undefined); assert.equal(seen[0].body,seen[1].body);
    let state=await (await fetch(url+'/_deck/account')).json(); assert.equal(state.failover.active,'b'); assert.deepEqual(state.failover.unavailable,['a']);
    behavior=(req,res)=>{res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: quota reset\n\n');};
    state=await (await select(url,'a')).json();
    assert.equal(state.failover.active,'a','Manual retry after quota reset must select the previously rejected account');
    assert.deepEqual(state.failover.unavailable,[],'Retry must clear the stale quota rejection');
    state=await (await select(url,'a')).json(); assert.equal(state.failover.active,'a','Selecting the already-active account must be idempotent');
    await (await send(url)).text(); assert.equal(seen.at(-1).account,'a','The next request must probe the manually selected account');
    behavior=(req,res)=> { if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429);res.end(quota);} else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: success\n\n');} };
    await (await send(url)).text(); assert.equal(seen.at(-1).account,'b','Still-exhausted accounts must be rejected anew and rotate safely');
    assert.equal((await send(url,{previous_response_id:'created-on-b'})).status,200);
    assert.equal(seen.at(-1).account,'b','The active account must be able to use its own response history after switching');
    url=await start({environment:'pool',environmentPool:['a','b','c']});
    state=await (await fetch(url+'/_deck/account')).json(); assert.deepEqual(state.environment,{name:'pool',pooled:true,accounts:['a','b','c']});
    state=await (await select(url,'c')).json(); assert.equal(state.failover.active,'c');
    await (await send(url)).text(); assert.equal(seen.at(-1).account,'c','Manual selection must change only the live proxy route');
    state=await (await fetch(url+'/_deck/account')).json(); assert.equal(state.failover.lastRequestAccount,'c','Session status must confirm the account used for the latest upstream request');
    assert.equal((await select(url,'outside')).status,400); assert.equal((await select(url,'a',{origin:'https://example.com'})).status,403);
    behavior=(req,res)=>{assert.equal(req.url,'/extensions/web/run?format=json');assert.equal(req.method,'POST');assert.equal(req.headers['x-codex-feature'],'web');assert.equal(req.headers.cookie,undefined);res.writeHead(200,{'content-type':'application/json','x-request-id':'aux-test'});res.end('{"ok":true}');};
    url=await start({owner:'b',automatic:false});
    result=await fetch(url+'/extensions/web/run?format=json',{method:'POST',body:'opaque',headers:{'content-type':'application/octet-stream','x-codex-feature':'web',cookie:'private',authorization:'Bearer wrong'}});
    assert.equal(result.status,200);assert.equal((await result.json()).ok,true);assert.equal(result.headers.get('x-request-id'),'aux-test');assert.equal(seen[0].account,'b');
    state=await (await fetch(url+'/_deck/account')).json();assert.equal(state.failover.automatic,false);assert.equal(state.failover.lastRequestRoute,'/extensions/web/run');
    const resetsAt=Math.ceil((clock+5000)/1000);
    behavior=(_req,res)=>{res.writeHead(429);res.end(JSON.stringify({error:{type:'usage_limit_reached',resets_at:resetsAt}}));};
    result=await send(url);assert.equal(result.status,429);assert.deepEqual(seen.map(r=>r.account),['b','b'],'Manual-only routing must not automatically replay a rejected request');
    behavior=(_req,res)=>{res.writeHead(200,{'content-type':'application/json'});res.end('{"output":[]}');};
    assert.equal((await compact(url)).status,200);assert.equal(seen.length,3,'A manual reset must be detected by one live probe even before the cached reset time');
    state=await (await fetch(url+'/_deck/account')).json();assert.deepEqual(state.failover.unavailable,[],'Successful manual reset probes must clear the stale unavailable state');
    behavior=(req,res)=> { if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429);res.end(quota);} else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: success\n\n');} };
    url=await start(); result=await send(url,{input:[{encrypted_content:'portable-history'}]});
    assert.equal(result.status,200); assert.deepEqual(seen.map(r=>r.account),['a','b'],'Encrypted stateless history must rotate after quota rejection');
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    url=await start(); assert.equal((await send(url)).status,429); assert.deepEqual(seen.map(r=>r.account),['a','b','c']);
    await send(url); assert.equal(seen.length,3,'Exhausted pool must not loop');
    clock+=61000;
    behavior=(_req,res)=>{res.writeHead(200,{'content-type':'application/json'});res.end('{"output":[]}');};
    assert.equal((await compact(url)).status,200); assert.equal(seen.length,4,'An open automatic-failover session must probe again after the bounded no-metadata retry interval');
    state=await (await fetch(url+'/_deck/account')).json(); assert.deepEqual(state.failover.unavailable,[],'Successful reset probes must clear automatic failover exclusions');
    for (const [status,body] of [[401,quota],[500,quota]]) {
      behavior=(_req,res)=>{res.writeHead(status);res.end(body);}; url=await start();
      assert.equal((await send(url)).status,status); assert.equal(seen.length,1);
    }
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    for (const body of [{previous_response_id:'r1'},{input:[{type:'item_reference',id:'r1'}]},{input:[{file_id:'file1'}]}]) {
      url=await start(); assert.equal((await send(url,body)).status,409); assert.equal(seen.length,1);
    }
    url=await start(); assert.equal((await send(url,{input:[{encrypted_content:'portable'}]})).status,429); assert.equal(seen.length,3);
    behavior=(_req,res)=>{res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: partial\n\n');setTimeout(()=>res.destroy(),25);};
    url=await start(); result=await send(url); await assert.rejects(result.text()); assert.equal(seen.length,1,'Interrupted stream must not replay');
    behavior=(_req,res)=>res.destroy(); url=await start(); assert.equal((await send(url)).status,502); assert.equal(seen.length,1);
    behavior=(_req,res)=>{res.writeHead(200);res.end('ok');};
    url=await start({mode:'Best'}); await (await send(url)).text(); assert.equal(seen[0].account,'b');
    let rows={a:row(90),b:row(70),c:row(80)};
    behavior=(_req,res)=>{rows={a:row(90),b:row(70),c:row(80,310000)};res.writeHead(429);res.end(quota);};
    url=await start({mode:'Best'}, {rows:()=>rows}); await send(url); assert.deepEqual(seen.map(r=>r.account),['a','b']);
    await assert.rejects(start({mode:'Best'},{rows:()=>({})}));
    url=await start(); assert.equal((await send(url,{}, {origin:'https://example.com'})).status,403);
    assert.equal((await fetch(url.replace(/\/[a-f0-9]+$/,'/wrong')+'/responses',{method:'POST'})).status,403);
    assert.equal((await fetch(url+'/_deck/arbitrary')).status,404); assert.equal(seen.length,0);
    assert.equal((await send(url,{}, {'content-encoding':'gzip'})).status,400);
    behavior=(_req,res)=>{res.writeHead(200);res.end('ok');};
    for (const [encoding,compress] of [['gzip',zlib.gzipSync],['zstd',zlib.zstdCompressSync]]) {
      if (!compress) continue;
      const response=await fetch(url+'/responses',{method:'POST',headers:{'content-encoding':encoding},body:compress(Buffer.from('{"input":"compressed context"}'))});
      assert.equal(response.status,200); await response.text();
      assert.equal(JSON.parse(seen.at(-1).body).input,'compressed context');
    }
    behavior=(req,res)=>{assert.equal(req.url,'/extensions/web/run');assert.equal(req.headers['content-encoding'],undefined);assert.equal(req.headers['content-length'],'16');res.writeHead(200);res.end('ok');};
    result=await fetch(url+'/extensions/web/run',{method:'POST',headers:{'content-encoding':'gzip'},body:zlib.gzipSync(Buffer.from('decoded payload!'))});
    assert.equal(result.status,200);await result.text();assert.equal(seen.at(-1).body,'decoded payload!');
    behavior=(req,res)=>{assert.equal(req.url,'/responses/compact');res.writeHead(200,{'content-type':'application/json'});res.end('{"output":[]}');};
    url=await start();
    assert.equal((await compact(url)).status,200); assert.equal(seen[0].account,'a');
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    url=await start(); assert.equal((await compact(url)).status,429); assert.equal(seen.length,3,'Full-context compaction can try the configured pool');
    behavior=(req,res)=>{res.writeHead(req.headers['chatgpt-account-id']==='a'?429:200);res.end(req.headers['chatgpt-account-id']==='a'?quota:'ok');};
    url=await start(); await (await send(url)).text();
    assert.equal((await compact(url,{input:[{encrypted_content:'created-on-b'}]})).status,200);
    assert.equal(seen.at(-1).account,'b','Compaction after switching must reach the active account');
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    url=await start(); assert.equal((await compact(url,{input:[{encrypted_content:'portable'}]})).status,429);
    assert.equal(seen.length,3,'Encrypted compact history must try the configured pool');
    const contextBody={model:'gpt-test',input:[
      {type:'message',role:'system',content:[{type:'input_text',text:'protected system instructions'}]},
      {type:'message',role:'user',content:[{type:'input_text',text:'remember this user detail'}]},
      {type:'function_call',call_id:'call_1',name:'exec_command',arguments:'{"cmd":"dir"}'},
      {type:'function_call_output',call_id:'call_1',output:'large paired tool output'}
    ]};
    behavior=(_req,res)=>{res.writeHead(200,{'content-type':'application/json'});res.end('{"output":[]}');};
    const statusRows={a:{CheckedAt:new Date().toISOString(),Windows:[{Label:'5H',UsedPct:28,RemainingPct:72},{Label:'Weekly',UsedPct:12,RemainingPct:88}]},b:{CheckedAt:new Date().toISOString(),Windows:[{Label:'5H',UsedPct:65,RemainingPct:35},{Label:'Weekly',UsedPct:40,RemainingPct:60}]}};
    url=await start({contextManager:true,environment:'launch-account',root:modelRoot,autoCompact:{enabled:true,mode:'Custom',freePercent:55}},{rows:()=>statusRows});
    let emptyContext=await (await context(url)).json();assert.equal(emptyContext.raw.length,0);assert.equal(emptyContext.capturedAt,null,'A newly opened terminal must show an empty context before its first model request');
    assert.deepEqual(emptyContext.session.autoCompact,{enabled:true,mode:'Custom',freePercent:55});
    assert.equal(emptyContext.session.quota.windows[0].usedPercent,28);
    await (await send(url,contextBody)).text();
    state=await (await fetch(url+'/_deck/account')).json();assert.equal(state.contextManager.enabled,true);
    let contextState=await (await context(url)).json();assert.equal(contextState.raw.length,4);assert.equal(contextState.effective.length,4);assert.equal(contextState.account,'a');
    assert.equal(contextState.session.model,'gpt-test');assert.equal(contextState.session.contextWindow,90000);
    const firstRevision=contextState.revision;
    let unchanged=await (await fetch(url+'/_deck/context?since='+firstRevision)).json();assert.equal(unchanged.unchanged,true);assert.equal(unchanged.revision,firstRevision);assert.equal('raw' in unchanged,false,'Unchanged companion polls must stay tiny');assert.equal(unchanged.session.quota.windows[0].usedPercent,28);
    const systemItem=contextState.raw.find(item=>item.role==='system'), userItem=contextState.raw.find(item=>item.role==='user'), toolItem=contextState.raw.find(item=>item.callId==='call_1');
    assert.ok(systemItem && userItem && toolItem,'The live context snapshot must expose stable item identities');
    assert.equal((await context(url,{action:'suppress',key:systemItem.key})).status,403,'Protected context must require the advanced setting');
    assert.equal((await context(url,{action:'suppress',key:toolItem.key})).status,200);
    contextState=await (await context(url)).json();assert.equal(contextState.effective.length,2,'Context metrics must update immediately after an overlay action');assert.ok(contextState.savedTokens>0);assert.ok(contextState.revision>firstRevision);
    await (await send(url,contextBody)).text();
    let projected=JSON.parse(seen.at(-1).body);assert.deepEqual(projected.input.map(item=>item.type),['message','message'],'Tool calls and outputs must be suppressed as a pair');
    contextState=await (await context(url)).json();assert.ok(contextState.savedTokens>0);assert.equal(contextState.rules.length,2);
    assert.equal((await context(url,{action:'edit',key:userItem.key,text:'replacement visible next call'})).status,200);
    contextState=await (await context(url)).json();assert.equal(contextState.effective.find(item=>item.key===userItem.key).text,'replacement visible next call','Edited content must update the companion immediately');
    await (await compact(url,contextBody)).text();
    projected=JSON.parse(seen.at(-1).body);assert.equal(projected.input[1].content[0].text,'replacement visible next call','Edits must apply to compact requests as well as Responses requests');
    assert.deepEqual(projected.input.map(item=>item.type),['message','message']);
    assert.equal((await context(url,{action:'clear'})).status,200);
    contextState=await (await context(url)).json();assert.equal(contextState.effective.length,4);assert.equal(contextState.savedTokens,0,'Restore all must update companion metrics immediately');
    await (await send(url,contextBody)).text();assert.equal(JSON.parse(seen.at(-1).body).input.length,4,'Clearing overlays must restore the immutable raw request projection');
    await (await send(url,contextBody,{'thread-id':'thread-one'})).text();
    contextState=await (await context(url)).json();assert.equal(contextState.threadId,'thread-one');
    assert.equal((await context(url,{action:'suppress',key:contextState.raw.find(item=>item.role==='user').key})).status,200);
    assert.equal((await select(url,'b')).status,200);
    await (await send(url,contextBody,{'thread-id':'thread-one'})).text();
    contextState=await (await context(url)).json();assert.equal(contextState.account,'b','A manual account switch must update the companion account');assert.equal(contextState.session.quota.windows[0].usedPercent,65,'Quota details must follow the active routed account');
    assert.equal(seen.at(-1).account,'b');assert.equal(JSON.parse(seen.at(-1).body).input.length,3,'A manual account switch must keep the current conversation overlay');
    await (await send(url,contextBody,{'thread-id':'thread-two'})).text();
    contextState=await (await context(url)).json();assert.equal(contextState.threadId,'thread-two');assert.equal(contextState.rules.length,0,'A new conversation must not inherit overlays from the previous conversation');
    assert.equal(JSON.parse(seen.at(-1).body).input.length,4,'A new conversation must receive its full untouched first request');
    await (await send(url,contextBody,{'thread-id':'thread-one'})).text();
    contextState=await (await context(url)).json();assert.equal(contextState.threadId,'thread-one');assert.equal(contextState.rules.length,1,'Resuming a conversation must restore only its own overlays');
    assert.equal(JSON.parse(seen.at(-1).body).input.length,3,'A resumed conversation must apply its own saved overlay');
    url=await start();assert.equal((await context(url)).status,404,'The context route must not exist unless explicitly enabled');
    const concurrency=4;
    let pending=[];
    behavior=(req,res)=>{
      if(req.headers['chatgpt-account-id']==='a') {
        pending.push(res);
        if(pending.length===concurrency) for(const waiting of pending) {waiting.writeHead(429);waiting.end(quota);}
      } else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: concurrent success\n\n');}
    };
    url=await start();
    const concurrent=await Promise.all(Array.from({length:concurrency},(_,index)=>send(url,{input:'request-'+index})));
    assert.deepEqual(concurrent.map(response=>response.status),Array(concurrency).fill(200));
    assert.deepEqual(await Promise.all(concurrent.map(response=>response.text())),Array(concurrency).fill('data: concurrent success\n\n'));
    assert.deepEqual(seen.map(request=>request.account).sort(),[...Array(concurrency).fill('a'),...Array(concurrency).fill('b')],'Concurrent quota rejections must independently retry on a usable account');
    behavior=(_req,res)=>{res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: waiting\n\n');};
    url=await start(); const firstController=new AbortController(), secondController=new AbortController();
    const active=await Promise.all([
      fetch(url+'/responses',{method:'POST',body:'{}',signal:firstController.signal}),
      fetch(url+'/responses',{method:'POST',body:'{}',signal:secondController.signal})
    ]);
    assert.deepEqual(active.map(response=>response.status),[200,200]);
    state=await (await select(url,'b')).json(); assert.equal(state.busy,true); assert.equal(state.failover.active,'b'); firstController.abort();
    await new Promise(resolve=>setTimeout(resolve,30)); state=await (await fetch(url+'/_deck/account')).json(); assert.equal(state.busy,true,'One cancellation must not mark another active request idle');
    secondController.abort(); await new Promise(resolve=>setTimeout(resolve,30)); state=await (await fetch(url+'/_deck/account')).json(); assert.equal(state.busy,false);
    assert.equal(seen.length,2);
    behavior=(_req,res)=>{res.writeHead(200);res.end('ok');}; await (await send(url)).text();
    assert.equal(seen.at(-1).account,'b','A switch during an accepted stream must apply to the next request');
    state=await (await fetch(url+'/_deck/account')).json(); assert.equal(state.failover.lastRequestAccount,'b');
    console.log('PASS: failover routing, concurrent requests, live account and context control, fresh ranking, bounded quota retries, affinity protection, credential isolation, stream interruption, transport errors, access controls and cancellation.');
  } finally {
    fs.rmSync(modelRoot,{recursive:true,force:true});
    for(const server of [...proxies,upstream]) { server.closeAllConnections(); server.close(); }
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
