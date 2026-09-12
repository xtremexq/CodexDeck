'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const zlib = require('node:zlib');
const { once } = require('node:events');
const { createProxy, rank, quotaRejected } = require('./Deck.Failover.cjs');
const quota = JSON.stringify({error:{type:'usage_limit_reached'}});
const row = (pct, age = 0) => ({Status:'available', CheckedAt:new Date(Date.now()-age).toISOString(), Windows:[{RemainingPct:pct}]});
async function main() {
  assert.deepEqual(rank(['a','b','c'], {a:row(30),b:row(80),c:row(90,310000)}), ['b','a']);
  assert.equal(quotaRejected(429,quota),true);
  for (const [status,body,expected] of [[401,quota,false],[500,quota,false],[429,'{"error":{"type":"rate_limit_exceeded"}}',true],[429,'invalid',false]]) assert.equal(quotaRejected(status,body),expected);
  let behavior, seen = [], reports = [];
  const upstream = http.createServer(async (req,res) => {
    const parts=[]; for await (const part of req) parts.push(part);
    seen.push({account:req.headers['chatgpt-account-id'],auth:req.headers.authorization,body:Buffer.concat(parts).toString(),headers:req.headers,url:req.url,method:req.method});
    behavior(req,res);
  });
  upstream.listen(0,'127.0.0.1'); await once(upstream,'listening');
  const proxies=[];
  async function start(extra={}, deps={}) {
    seen=[]; reports=[];
    const p=await createProxy({pool:['a','b','c'],mode:'Ordered',...extra}, {
      upstream:`http://127.0.0.1:${upstream.address().port}`,
      credentials:name=>({token:'synthetic-'+name,id:name}), rows:()=>({a:row(30),b:row(80),c:row(60)}),
      report:name=>reports.push(name), ...deps
    }); proxies.push(p.server); return p.baseUrl;
  }
  const send=(url,body={},headers={})=>fetch(url+'/responses',{method:'POST',body:JSON.stringify(body),headers:{'content-type':'application/json',...headers}});
  const select=(url,account,headers={})=>fetch(url+'/_deck/account',{method:'POST',body:JSON.stringify({account}),headers:{'content-type':'application/json',...headers}});
  try {
    behavior=(req,res)=> { if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429);res.end(quota);} else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: success\n\n');} };
    let url=await start(); let result=await send(url,{input:'synthetic'},{authorization:'Bearer client-secret',cookie:'private', 'x-account-id':'wrong'});
    assert.equal(await result.text(),'data: success\n\n'); assert.deepEqual(seen.map(r=>r.account),['a','b']); assert.deepEqual(reports,['b']);
    assert.equal(seen[1].auth,'Bearer synthetic-b'); assert.equal(seen[1].headers.cookie,undefined); assert.equal(seen[1].headers['x-account-id'],undefined); assert.equal(seen[0].body,seen[1].body);
    let state=await (await fetch(url+'/_deck/account')).json(); assert.equal(state.failover.active,'b'); assert.deepEqual(state.failover.unavailable,['a']);
    assert.equal((await select(url,'a')).status,409,'Quota-rejected accounts must stay unavailable for the session');
    await (await send(url)).text(); assert.equal(seen.at(-1).account,'b');
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
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    result=await send(url);assert.equal(result.status,429);assert.deepEqual(seen.map(r=>r.account),['b','b'],'Manual-only routing must not automatically replay a rejected request');
    behavior=(req,res)=> { if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429);res.end(quota);} else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: success\n\n');} };
    url=await start(); result=await send(url,{input:[{encrypted_content:'portable-history'}]});
    assert.equal(result.status,200); assert.deepEqual(seen.map(r=>r.account),['a','b'],'Encrypted stateless history must rotate after quota rejection');
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    url=await start(); assert.equal((await send(url)).status,429); assert.deepEqual(seen.map(r=>r.account),['a','b','c']);
    await send(url); assert.equal(seen.length,3,'Exhausted pool must not loop');
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
    const compact=(base,body={})=>fetch(base+'/responses/compact',{method:'POST',body:JSON.stringify(body)});
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
    console.log('PASS: failover routing, concurrent requests, live account control, fresh ranking, bounded quota retries, affinity protection, credential isolation, stream interruption, transport errors, access controls and cancellation.');
  } finally {
    for(const server of [...proxies,upstream]) { server.closeAllConnections(); server.close(); }
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
