'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { walkSessions, scanSession, timelineChunk, efficiency, createInspector } = require('./Deck.Inspector.cjs');

async function main() {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'codexdeck-inspector-'));
  const deck=path.join(root,'deck'), sessions=path.join(root,'accounts','account1','sessions','2026','09','22');
  const settingsFile=path.join(deck,'settings.json'), stateFile=path.join(deck,'inspector.json');
  const writeSettings=value=>fs.writeFileSync(settingsFile,JSON.stringify(value),'utf8');
  let server, proxy, secondProxy;
  try {
    fs.mkdirSync(sessions,{recursive:true});fs.mkdirSync(deck,{recursive:true});
    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:20});
    const repeatedPath='C:\\work\\project\\src\\feature.js';
    const command='{"cmd":"rg -n feature src"}';
    const rows=[
      {timestamp:'2026-09-22T12:00:00Z',type:'session_meta',payload:{id:'session-1',cwd:'C:\\work\\project',model:'gpt-test',source:'cli'}},
      {timestamp:'2026-09-22T12:00:01Z',type:'event_msg',payload:{type:'task_started'}},
      {timestamp:'2026-09-22T12:00:02Z',type:'response_item',payload:{type:'message',role:'user',content:[{type:'input_text',text:'Inspect the feature'}]}},
      {timestamp:'2026-09-22T12:00:03Z',type:'response_item',payload:{type:'function_call',name:'exec_command',call_id:'call-1',arguments:command}},
      {timestamp:'2026-09-22T12:00:04Z',type:'response_item',payload:{type:'function_call',name:'exec_command',call_id:'call-2',arguments:command}},
      {timestamp:'2026-09-22T12:00:05Z',type:'response_item',payload:{type:'function_call_output',call_id:'call-2',output:(repeatedPath+' ').repeat(6)+'x'.repeat(50001)}},
      {timestamp:'2026-09-22T12:00:06Z',type:'compacted',payload:{message:'summary'}},
      {timestamp:'2026-09-22T12:00:07Z',type:'event_msg',payload:{type:'token_count',info:{total_token_usage:{input_tokens:1200,cached_input_tokens:300,output_tokens:200,reasoning_output_tokens:50,total_tokens:1400}}}}
    ];
    fs.writeFileSync(path.join(sessions,'rollout-2026-09-22T12-00-session-1.jsonl'),rows.map(JSON.stringify).join('\n')+'\n','utf8');

    const found=walkSessions(root);assert.equal(found.length,1);assert.equal(found[0].account,'account1');
    const summary=await scanSession(found[0]);
    assert.equal(summary.title,'Inspect the feature');assert.equal(summary.turns,1);assert.equal(summary.toolCalls,2);assert.equal(summary.compactions,1);
    assert.deepEqual(summary.usage,{input:1200,cached:300,output:200,reasoning:50,total:1400,exact:true});
    assert.equal(summary.commands[command],2);assert.ok(summary.largest[0].chars>50000);
    const timeline=await timelineChunk(found[0]);assert.equal(timeline.done,true);assert.equal(timeline.items.at(-1).kind,'tokens');
    const tailFile=path.join(root,'active-rollout.jsonl'),tailFirst=JSON.stringify(rows[2]),tailSecond=JSON.stringify(rows[3]),split=Math.floor(tailSecond.length/2);
    fs.writeFileSync(tailFile,tailFirst+'\n'+tailSecond.slice(0,split),'utf8');
    const firstTail=await timelineChunk({file:tailFile});assert.equal(firstTail.items.length,1);assert.equal(firstTail.done,false,'An incomplete rollout line must remain unread until it is complete');
    fs.appendFileSync(tailFile,tailSecond.slice(split)+'\n','utf8');
    const secondTail=await timelineChunk({file:tailFile},firstTail.next);assert.equal(secondTail.items.length,1);assert.equal(secondTail.items[0].kind,'function_call');assert.equal(secondTail.done,true);
    const report=await efficiency(root,20);assert.equal(report.totals.sessions,1);assert.equal(report.totals.exactSessions,1);
    assert.ok(report.recommendations.some(item=>item.title==='Repeated shell work'));assert.ok(report.recommendations.some(item=>item.title==='Large tool output'));
    const manyRoot=path.join(root,'many'),older=path.join(manyRoot,'accounts','account1','sessions'),newer=path.join(manyRoot,'accounts','account2','sessions');
    fs.mkdirSync(older,{recursive:true});fs.mkdirSync(newer,{recursive:true});
    for(let i=0;i<25;i++){const file=path.join(older,`rollout-${i}.jsonl`);fs.writeFileSync(file,JSON.stringify(rows[0])+'\n');fs.utimesSync(file,new Date(1000000+i*1000),new Date(1000000+i*1000))}
    const newestFile=path.join(newer,'rollout-newest.jsonl');fs.writeFileSync(newestFile,JSON.stringify(rows[0])+'\n');fs.utimesSync(newestFile,new Date(2000000),new Date(2000000));
    const globalIndex=walkSessions(manyRoot,20);assert.equal(globalIndex.length,20);assert.equal(globalIndex.available,26);assert.equal(globalIndex[0].account,'account2','The newest session must lead regardless of account order');
    const globalReport=await efficiency(manyRoot,20);assert.equal(globalReport.totals.sessions,20);assert.equal(globalReport.availableSessions,26);assert.equal(globalReport.limitReached,true);assert.equal(globalReport.sessions.length,20);assert.equal(globalReport.sessions[0].account,'account2');

    const liveDirectory=path.join(deck,'sessions');fs.mkdirSync(liveDirectory,{recursive:true});
    fs.writeFileSync(path.join(liveDirectory,'older.json'),JSON.stringify({ProcessId:process.pid,Account:'account1',Folder:'C:\\work\\project',StartedAt:'2026-09-22T11:59:00Z'}),'utf8');
    fs.writeFileSync(path.join(liveDirectory,'newer.json'),JSON.stringify({ProcessId:process.pid,Account:'account1',Folder:'C:\\work\\project',StartedAt:'2026-09-22T12:00:00Z'}),'utf8');
    const inspector=await createInspector(root,stateFile);server=inspector.server;
    const healthResponse=await fetch(inspector.baseUrl+'health');assert.equal(healthResponse.status,200);
    const health=await healthResponse.json();assert.equal(health.pid,process.pid);
    assert.equal(health.version,require('node:crypto').createHash('sha256').update(fs.readFileSync(require.resolve('./Deck.Inspector.cjs'))).digest('hex'),'The launcher must distinguish an old inspector process from the installed script');
    let response=await fetch(inspector.baseUrl+'trajectory');assert.equal(response.status,200);const trajectoryHtml=await response.text();assert.match(trajectoryHtml,/Trajectory \+ Context/);
    assert.match(trajectoryHtml,/managed\[0\]/,'Trajectory must prefer the newest managed live context');assert.match(trajectoryHtml,/pollTimeline/,'Trajectory must tail active rollouts');assert.match(trajectoryHtml,/setInterval\([^]*1000\)/,'Live views must poll while Codex is working');assert.match(trajectoryHtml,/state\.protectedChanges/,'Protected context controls must honor the advanced setting');
    response=await fetch(inspector.baseUrl+'efficiency');assert.equal(response.status,200);assert.match(await response.text(),/Efficiency Analytics/);
    assert.match(await (await fetch(inspector.baseUrl+'efficiency')).text(),/Session limit reached/,'The efficiency panel must explain when its cap is reached');
    const sessionResponse=await (await fetch(inspector.baseUrl+'api/sessions')).json();assert.equal(sessionResponse.sessions.length,1);assert.equal('file' in sessionResponse.sessions[0],false);assert.equal(sessionResponse.live[0].startedAt,'2026-09-22T12:00:00Z','Newest live launch must be selected first');assert.equal(sessionResponse.sessions[0].live.startedAt,'2026-09-22T12:00:00Z','A historical session must bind to its newest matching live launch');
    const apiReport=await (await fetch(inspector.baseUrl+'api/efficiency')).json();assert.equal(apiReport.totals.total,1400);assert.equal('file' in apiReport.sessions[0],false);
    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:200});
    assert.equal((await (await fetch(inspector.baseUrl+'api/efficiency')).json()).limit,600,'The legacy saved 200-session default must migrate in the inspector');
    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:1000,EfficiencyLimitVersion:2});
    assert.equal((await (await fetch(inspector.baseUrl+'api/efficiency')).json()).limit,600,'The previous 1000-session default must migrate in the inspector');
    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:5000,EfficiencyLimitVersion:2});
    assert.equal((await (await fetch(inspector.baseUrl+'api/efficiency')).json()).limit,5000,'The inspector must accept the 5000-session limit');
    assert.equal((await fetch(inspector.baseUrl+'api/context?id=missing')).status,403,'Context management has its own opt-in gate');
    assert.equal((await fetch(inspector.baseUrl+'context?live=aaaaaaaaaaaaaaaaaaaaaaaa')).status,403,'The compact companion must share the live-context opt-in gate');
    assert.equal((await fetch(inspector.baseUrl+'health',{headers:{origin:'https://example.com'}})).status,403);

    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:true,ContextManagerProtected:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:20});
    response=await fetch(inspector.baseUrl+'context?live=aaaaaaaaaaaaaaaaaaaaaaaa');assert.equal(response.status,200);const companionHtml=await response.text();
    assert.match(companionHtml,/Live Context/);assert.match(companionHtml,/Full studio/);assert.match(companionHtml,/content-visibility:auto/);assert.match(companionHtml,/&since=/);assert.match(companionHtml,/Suppress this item from the next request/);assert.match(companionHtml,/Edit model-visible content/);
    assert.match(companionHtml,/Follow new/);assert.match(companionHtml,/deck\.context\.follow/);assert.match(companionHtml,/card\.append\(actions,body,remove\)/,'Edit must appear to the left of Suppress');
    assert.match(companionHtml,/Context free ≈/);assert.match(companionHtml,/Auto-compact/);assert.match(companionHtml,/renderedEnd/);
    const proxySecret='b'.repeat(64), markerFile=path.join(liveDirectory,'newer.json');
    proxy=http.createServer((request,result)=>{
      assert.equal(request.url,`/${proxySecret}/_deck/context`);
      result.writeHead(200,{'content-type':'application/json'});
      result.end(JSON.stringify({revision:1,account:'account1',raw:[],effective:[],capturedAt:null}));
    });
    await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
    fs.writeFileSync(markerFile,JSON.stringify({ProcessId:process.pid,Account:'account1',Folder:'C:\\work\\project',StartedAt:'2026-09-22T12:00:00Z',ContextUrl:`http://127.0.0.1:${proxy.address().port}/${proxySecret}/_deck/context`}), 'utf8');
    const markerId=crypto.createHash('sha256').update(markerFile).digest('hex').slice(0,24);
    const firstContext=await fetch(inspector.baseUrl+'api/context?id='+markerId);
    assert.equal(firstContext.status,200,'The compact companion must reach its exact live conversation');
    assert.equal((await firstContext.json()).account,'account1');
    const secondSecret='c'.repeat(64), secondMarker=path.join(liveDirectory,'second-terminal.json');
    secondProxy=http.createServer((request,result)=>{assert.equal(request.url,`/${secondSecret}/_deck/context`);result.writeHead(200,{'content-type':'application/json'});result.end(JSON.stringify({revision:1,account:'account2',threadId:'second-terminal',raw:[],effective:[]}))});
    await new Promise(resolve=>secondProxy.listen(0,'127.0.0.1',resolve));
    fs.writeFileSync(secondMarker,JSON.stringify({ProcessId:process.pid,Account:'account2',Folder:'C:\\other',StartedAt:'2026-09-22T12:01:00Z',ContextUrl:`http://127.0.0.1:${secondProxy.address().port}/${secondSecret}/_deck/context`}),'utf8');
    const secondId=crypto.createHash('sha256').update(secondMarker).digest('hex').slice(0,24);
    assert.equal((await (await fetch(inspector.baseUrl+'api/context?id='+secondId)).json()).account,'account2','A second terminal must reach only its own proxy');
    assert.equal((await (await fetch(inspector.baseUrl+'api/context?id='+markerId)).json()).account,'account1','The first terminal must retain its own proxy');
    assert.equal((await (await fetch(inspector.baseUrl+'api/context/presence?id='+markerId)).json()).open,false);
    assert.equal((await fetch(inspector.baseUrl+'api/context/presence?id='+markerId,{method:'POST'})).status,200);
    assert.equal((await (await fetch(inspector.baseUrl+'api/context/presence?id='+markerId)).json()).open,true);
    assert.equal((await (await fetch(inspector.baseUrl+'api/context/presence?id='+secondId)).json()).open,false,'Window presence must be per terminal');

    writeSettings({TrajectoryEnabled:false,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:20});
    assert.equal((await fetch(inspector.baseUrl+'trajectory')).status,403);assert.equal((await fetch(inspector.baseUrl+'efficiency')).status,200,'Efficiency analytics must remain independently available');
    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:false,EfficiencySessionLimit:20});
    assert.equal((await fetch(inspector.baseUrl+'trajectory')).status,200);assert.equal((await fetch(inspector.baseUrl+'efficiency')).status,403,'Trajectory must remain independently available');
    console.log('PASS: local trajectory indexing, compact live-context companion, safe live tailing, newest-live selection, exact usage, independent efficiency analytics, opt-in gates and inspector access controls.');
  } finally {
    if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
    if(proxy){proxy.closeAllConnections();await new Promise(resolve=>proxy.close(resolve));}
    if(secondProxy){secondProxy.closeAllConnections();await new Promise(resolve=>secondProxy.close(resolve));}
    fs.rmSync(root,{recursive:true,force:true});
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
