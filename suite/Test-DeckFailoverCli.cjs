'use strict';
// Optional native-client compatibility check; all model traffic uses synthetic local servers.
const { createProxy } = require('./Deck.Failover.cjs');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const {ruleArguments} = require('./Deck.GlobalRules.cjs');
async function main() {
  if (!process.env.DECK_TEST_CODEX) { console.log('SKIP: set DECK_TEST_CODEX to the native Codex executable for the optional local compatibility test.'); return; }
  const fixture=fs.mkdtempSync(path.join(os.tmpdir(),'deck-failover-cli-'));
  const seen=[];
  const service=http.createServer(async (req,res)=> {
    const parts=[];for await (const chunk of req) parts.push(chunk);
    seen.push({url:req.url,account:req.headers['chatgpt-account-id'],body:Buffer.concat(parts).toString()});
    if(req.url.startsWith('/models')){res.writeHead(200,{'content-type':'application/json'});res.end('{"models":[]}');return;}
    if(req.headers['chatgpt-account-id']==='a') {res.writeHead(429,{'content-type':'application/json'});res.end('{"error":{"type":"usage_limit_reached"}}');return;}
    res.writeHead(200,{'content-type':'text/event-stream'});
    const item={id:'msg_test',type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'Synthetic failover OK',annotations:[]}]};
    for(const event of [
      {type:'response.created',response:{id:'resp_test',object:'response',status:'in_progress',output:[]}},
      {type:'response.output_item.added',output_index:0,item:{...item,status:'in_progress',content:[]}},
      {type:'response.output_text.delta',item_id:'msg_test',output_index:0,content_index:0,delta:'Synthetic failover OK'},
      {type:'response.output_item.done',output_index:0,item},
      {type:'response.completed',response:{id:'resp_test',object:'response',status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}}
    ]) res.write('event: '+event.type+'\ndata: '+JSON.stringify(event)+'\n\n');
    res.end();
  });
  service.on('connect',(_req,socket)=>socket.destroy());
  service.listen(0,'127.0.0.1');await once(service,'listening');
  const proxy=await createProxy({pool:['a','b'],mode:'Ordered'}, {credentials:n=>({token:'synthetic',id:n}),report:()=>{},upstream:`http://127.0.0.1:${service.address().port}`});
  try {
    // Synthetic ChatGPT auth exercises the production authentication mode without real credentials.
    const claims=Buffer.from(JSON.stringify({sub:'synthetic',email:'test@example.com','https://api.openai.com/auth':{chatgpt_account_id:'a',chatgpt_plan_type:'plus',chatgpt_user_id:'synthetic'}})).toString('base64url');
    fs.writeFileSync(path.join(fixture,'auth.json'),JSON.stringify({auth_mode:'chatgpt',tokens:{access_token:'synthetic',account_id:'a',refresh_token:'synthetic',id_token:'eyJhbGciOiJub25lIn0.'+claims+'.synthetic'},last_refresh:new Date().toISOString()}));
    const getArgs=spawn('powershell.exe',['-NoProfile','-Command',". '"+path.join(__dirname,'Deck.Failover.ps1').replaceAll("'","''")+"'; ConvertTo-Json -InputObject @(Get-DeckFailoverArguments '"+proxy.baseUrl+"') -Compress"],{windowsHide:true});
    let argsOutput='';getArgs.stdout.on('data',d=>argsOutput+=d);await once(getArgs,'close');
    const overrides=JSON.parse(argsOutput);
    const args=['exec','--skip-git-repo-check','-m','gpt-5.1-codex','-c','check_for_update_on_startup=false','-c','features.enable_request_compression=false',...overrides,'Reply with the supplied synthetic response; do not use tools.'];
    const env={...process.env,CODEX_HOME:fixture,OPENAI_API_KEY:'synthetic-local-test',HTTP_PROXY:`http://127.0.0.1:${service.address().port}`,HTTPS_PROXY:`http://127.0.0.1:${service.address().port}`,ALL_PROXY:`http://127.0.0.1:${service.address().port}`,NO_PROXY:'127.0.0.1,localhost'};
    delete env.OPENAI_BASE_URL; delete env.OPENAI_API_KEY; delete env.CODEX_API_KEY;
    async function run(argv,home=fixture){
      const child=spawn(process.env.DECK_TEST_CODEX,argv,{cwd:fixture,env:{...env,CODEX_HOME:home},windowsHide:true});
      child.stdin.end();
      let output='';child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);
      const timer=setTimeout(()=>child.kill(),25000);
      const [code]=await once(child,'close');clearTimeout(timer);
      assert.equal(code,0,output.replaceAll(proxy.baseUrl,'[local proxy]'));
      assert.match(output,/Synthetic failover OK/);
      return output;
    }
    await run(args);
    assert.deepEqual(seen.filter(r=>r.url==='/responses').map(r=>r.account),['a','b']);
    const sessionFiles=fs.readdirSync(path.join(fixture,'sessions'),{recursive:true}).filter(p=>p.endsWith('.jsonl'));
    assert.equal(sessionFiles.length,1);
    const metadata=JSON.parse(fs.readFileSync(path.join(fixture,'sessions',sessionFiles[0]),'utf8').split('\n')[0]);
    assert.equal(metadata.payload.model_provider,'openai','Native resume must retain the ordinary provider identity');
    await run(['exec','resume','--last','--skip-git-repo-check',...overrides,'Continue the synthetic conversation.']);
    assert.match(seen.filter(r=>r.url==='/responses').at(-1).body,/Synthetic failover OK/,'Resuming must send the earlier assistant response');
    const poolHome=path.join(fixture,'pool');fs.mkdirSync(poolHome);
    const getPoolArgs=spawn('powershell.exe',['-NoProfile','-Command',". '"+path.join(__dirname,'Deck.Failover.ps1').replaceAll("'","''")+"'; ConvertTo-Json -InputObject @(Get-DeckFailoverArguments '"+proxy.baseUrl+"' -NoAccountAuth) -Compress"],{windowsHide:true});
    let poolOutput='';getPoolArgs.stdout.on('data',d=>poolOutput+=d);await once(getPoolArgs,'close');
    const poolOverrides=JSON.parse(poolOutput);
    fs.writeFileSync(path.join(poolHome,'config.toml'),'developer_instructions = "Keep account-specific instruction."\n');
    fs.mkdirSync(path.join(fixture,'deck'));
    const rulesPath=path.join(fixture,'deck','global-rules.md');fs.writeFileSync(rulesPath,'Always answer hi. Preserve Unicode: olá.');
    const rules=await ruleArguments({rulesPath,executable:process.env.DECK_TEST_CODEX,prefix:[],args:[null],cwd:fixture,codexHome:poolHome});
    assert.match(rules[1],/Keep account-specific instruction/);
    assert.match(rules[1],/Always answer hi/);
    fs.writeFileSync(path.join(poolHome,'writing.config.toml'),'developer_instructions = "Keep profile-specific instruction."\n');
    const profileRules=await ruleArguments({rulesPath,executable:process.env.DECK_TEST_CODEX,prefix:[],args:['--profile','writing'],cwd:fixture,codexHome:poolHome});
    assert.match(profileRules[1],/Keep profile-specific instruction/);
    fs.copyFileSync(path.join(__dirname,'Deck.GlobalRules.cjs'),path.join(fixture,'Deck.GlobalRules.cjs'));
    const rulesCommand="[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); . '"+path.join(__dirname,'Deck.GlobalRules.ps1').replaceAll("'","''")+"'; ConvertTo-Json -InputObject @(Get-DeckGlobalRuleArguments '"+fixture.replaceAll("'","''")+"' '"+poolHome.replaceAll("'","''")+"' @()) -Compress";
    const psRules=spawn('powershell.exe',['-NoProfile','-Command',rulesCommand],{windowsHide:true});
    let rulesOutput='';psRules.stdout.on('data',d=>rulesOutput+=d);const [rulesCode]=await once(psRules,'close');
    assert.equal(rulesCode,0);assert.deepEqual(JSON.parse(rulesOutput),rules);
    await run(['exec','--skip-git-repo-check','-m','gpt-5.1-codex',...poolOverrides,...rules,'Synthetic pool conversation; do not use tools.'],poolHome);
    const payload=seen.filter(r=>r.url==='/responses').at(-1).body;
    assert.match(payload,/Always answer hi/);assert.match(payload,/Keep account-specific instruction/);assert.match(payload,/olá/);
    assert.equal(fs.existsSync(path.join(poolHome,'auth.json')),false,'Pool must not acquire a login');
    await run(['exec','resume','--last','--skip-git-repo-check',...poolOverrides,...rules,'Continue with the same global rules.'],poolHome);
    assert.equal((seen.filter(r=>r.url==='/responses').at(-1).body.match(/Always answer hi/g)||[]).length,1,'Resume must not duplicate Global Rules');
    console.log('PASS: native quota switch, retained history/provider, resume with earlier context, login-free pool, and Global Rules alongside existing account instructions.');
  } finally { proxy.server.closeAllConnections();proxy.server.close();service.closeAllConnections();service.close(); }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
