'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createProxy, rank, quotaRejected } = require('./Deck.Failover.cjs');
const quota = JSON.stringify({error:{type:'usage_limit_reached'}});
const row = (pct, age = 0) => ({Status:'available', CheckedAt:new Date(Date.now()-age).toISOString(), Windows:[{RemainingPct:pct}]});
async function main() {
  assert.deepEqual(rank(['a','b','c'], {a:row(30),b:row(80),c:row(90,310000)}), ['b','a']);
  assert.equal(quotaRejected(429,quota),true);
  for (const [status,body] of [[401,quota],[500,quota],[429,'{"error":{"type":"rate_limit_exceeded"}}'],[429,'invalid']]) assert.equal(quotaRejected(status,body),false);
  let behavior, seen = [], reports = [];
  const upstream = http.createServer(async (req,res) => {
    const parts=[]; for await (const part of req) parts.push(part);
    seen.push({account:req.headers['chatgpt-account-id'],auth:req.headers.authorization,body:Buffer.concat(parts).toString(),headers:req.headers});
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
  try {
    behavior=(req,res)=> { if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429);res.end(quota);} else {res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: success\n\n');} };
    let url=await start(); let result=await send(url,{input:'synthetic'},{authorization:'Bearer client-secret',cookie:'private', 'x-account-id':'wrong'});
    assert.equal(await result.text(),'data: success\n\n'); assert.deepEqual(seen.map(r=>r.account),['a','b']); assert.deepEqual(reports,['b']);
    assert.equal(seen[1].auth,'Bearer synthetic-b'); assert.equal(seen[1].headers.cookie,undefined); assert.equal(seen[1].headers['x-account-id'],undefined); assert.equal(seen[0].body,seen[1].body);
    await (await send(url)).text(); assert.equal(seen.at(-1).account,'b');
    assert.equal((await send(url,{previous_response_id:'private'})).status,409);
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    url=await start(); assert.equal((await send(url)).status,429); assert.deepEqual(seen.map(r=>r.account),['a','b','c']);
    await send(url); assert.equal(seen.length,3,'Exhausted pool must not loop');
    for (const [status,body] of [[401,quota],[500,quota],[429,'{"error":{"type":"rate_limit_exceeded"}}']]) {
      behavior=(_req,res)=>{res.writeHead(status);res.end(body);}; url=await start();
      assert.equal((await send(url)).status,status); assert.equal(seen.length,1);
    }
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    for (const body of [{previous_response_id:'r1'},{input:[{type:'item_reference',id:'r1'}]},{input:[{encrypted_content:'opaque'}]},{input:[{file_id:'file1'}]}]) {
      url=await start(); assert.equal((await send(url,body)).status,409); assert.equal(seen.length,1);
    }
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
    assert.equal((await fetch(url+'/arbitrary')).status,404); assert.equal(seen.length,0);
    assert.equal((await send(url,{}, {'content-encoding':'gzip'})).status,415);
    behavior=(req,res)=>{assert.equal(req.url,'/responses/compact');res.writeHead(200,{'content-type':'application/json'});res.end('{"output":[]}');};
    url=await start();
    const compact=(base,body={})=>fetch(base+'/responses/compact',{method:'POST',body:JSON.stringify(body)});
    assert.equal((await compact(url)).status,200); assert.equal(seen[0].account,'a');
    behavior=(_req,res)=>{res.writeHead(429);res.end(quota);};
    url=await start(); assert.equal((await compact(url)).status,429); assert.equal(seen.length,1,'Compaction must not switch accounts');
    behavior=(req,res)=>{res.writeHead(req.headers['chatgpt-account-id']==='a'?429:200);res.end(req.headers['chatgpt-account-id']==='a'?quota:'ok');};
    url=await start(); await (await send(url)).text();
    assert.equal((await compact(url,{input:[{encrypted_content:'opaque'}]})).status,409);
    assert.equal(seen.length,2,'Bound compact history must not cross accounts');
    behavior=(_req,res)=>{res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: waiting\n\n');};
    url=await start(); const controller=new AbortController();
    result=await fetch(url+'/responses',{method:'POST',body:'{}',signal:controller.signal});
    assert.equal((await send(url)).status,409); controller.abort();
    await new Promise(resolve=>setTimeout(resolve,30)); assert.equal(seen.length,1);
    console.log('PASS: failover routing, fresh ranking, bounded quota retries, affinity protection, credential isolation, stream interruption, transport errors, access controls and cancellation.');
  } finally {
    for(const server of [...proxies,upstream]) { server.closeAllConnections(); server.close(); }
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
