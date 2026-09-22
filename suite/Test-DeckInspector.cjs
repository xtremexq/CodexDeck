'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { walkSessions, scanSession, timelineChunk, efficiency, createInspector } = require('./Deck.Inspector.cjs');

async function main() {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'codexdeck-inspector-'));
  const deck=path.join(root,'deck'), sessions=path.join(root,'accounts','account1','sessions','2026','09','22');
  const settingsFile=path.join(deck,'settings.json'), stateFile=path.join(deck,'inspector.json');
  const writeSettings=value=>fs.writeFileSync(settingsFile,JSON.stringify(value),'utf8');
  let server;
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
    const report=await efficiency(root,20);assert.equal(report.totals.sessions,1);assert.equal(report.totals.exactSessions,1);
    assert.ok(report.recommendations.some(item=>item.title==='Repeated shell work'));assert.ok(report.recommendations.some(item=>item.title==='Large tool output'));

    const inspector=await createInspector(root,stateFile);server=inspector.server;
    assert.equal((await fetch(inspector.baseUrl+'health')).status,200);
    let response=await fetch(inspector.baseUrl+'trajectory');assert.equal(response.status,200);assert.match(await response.text(),/Trajectory \+ Context/);
    response=await fetch(inspector.baseUrl+'efficiency');assert.equal(response.status,200);assert.match(await response.text(),/Efficiency Analytics/);
    const sessionResponse=await (await fetch(inspector.baseUrl+'api/sessions')).json();assert.equal(sessionResponse.sessions.length,1);assert.equal('file' in sessionResponse.sessions[0],false);
    const apiReport=await (await fetch(inspector.baseUrl+'api/efficiency')).json();assert.equal(apiReport.totals.total,1400);assert.equal('file' in apiReport.sessions[0],false);
    assert.equal((await fetch(inspector.baseUrl+'api/context?id=missing')).status,403,'Context management has its own opt-in gate');
    assert.equal((await fetch(inspector.baseUrl+'health',{headers:{origin:'https://example.com'}})).status,403);

    writeSettings({TrajectoryEnabled:false,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:true,EfficiencySessionLimit:20});
    assert.equal((await fetch(inspector.baseUrl+'trajectory')).status,403);assert.equal((await fetch(inspector.baseUrl+'efficiency')).status,200,'Efficiency analytics must remain independently available');
    writeSettings({TrajectoryEnabled:true,ContextManagerEnabled:false,EfficiencyAnalyticsEnabled:false,EfficiencySessionLimit:20});
    assert.equal((await fetch(inspector.baseUrl+'trajectory')).status,200);assert.equal((await fetch(inspector.baseUrl+'efficiency')).status,403,'Trajectory must remain independently available');
    console.log('PASS: local trajectory indexing, paged timeline, exact usage, independent efficiency analytics, opt-in gates and inspector access controls.');
  } finally {
    if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
    fs.rmSync(root,{recursive:true,force:true});
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
