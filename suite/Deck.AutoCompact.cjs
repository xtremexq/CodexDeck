'use strict';
const {spawn} = require('node:child_process');
const readline = require('node:readline');
const fs = require('node:fs');
const path = require('node:path');

const HANDOFF = 'DECK_HANDOFF';
const HANDOFF_REQUEST = `Context is nearing the configured limit. At the next safe point, write a visible task-state handoff beginning with ${HANDOFF}: with what you're currently doing, objective, work completed, verified findings, decisions and constraints, unresolved questions, and next steps. Be concise while preserving important information. Also list all references, paths, function names, etc. that will "definitely" be useful/necessary for continuing, as to avoid the need for re-investigation.`;
const textInput = text => [{type:'text',text,text_elements:[]}];
const replayPrompt = handoff => `${JSON.stringify(handoff)}\n\nPlease go on.`;

class AutoCompactController {
  constructor(rpc, threshold, report = () => {}, handoffRequest = HANDOFF_REQUEST) {
    this.rpc=rpc; this.threshold=threshold; this.report=report;
    this.handoffRequest=handoffRequest;
    this.threadId=null; this.activeTurnId=null; this.phase='normal'; this.armed=true;
    this.handoff=''; this.checkpointTurnId=null; this.compactionTurnId=null;
    this.checkpointInterrupted=false;
    this.compactionItemDone=false; this.compactionTurnDone=false; this.usagePercent=null;
    this.queue=[]; this.once=false; this.done=false; this.failed=false;
  }
  async start(prompt, extra = {}) {
    const input=Array.isArray(prompt)?prompt:textInput(prompt);
    if(this.activeTurnId || this.phase!=='normal') { this.queue.push({input,extra}); this.report('Message queued until the current turn finishes.'); return; }
    const result=await this.rpc('turn/start',{threadId:this.threadId,input,...extra});
    this.activeTurnId=result.turn.id;
  }
  async onUsage(event) {
    if(event.threadId!==this.threadId) return;
    const usage=event.tokenUsage || {};
    const tokens=usage.last?.totalTokens || 0;
    const window=usage.modelContextWindow || 0;
    if(!tokens || !window) return;
    const exactPercent=tokens/window*100;
    const usedLimit=100-this.threshold;
    this.usagePercent=Math.round(exactPercent);
    if(!this.armed && exactPercent < usedLimit*0.8) this.armed=true;
    if(this.phase!=='normal' || !this.armed || exactPercent < usedLimit) return;
    this.armed=false; this.phase='checkpoint'; this.handoff=''; this.checkpointInterrupted=false;
    this.report(`Context ${this.usagePercent}% used / ${100-this.usagePercent}% free (limit ${this.threshold}% free): requesting task-state handoff.`);
    if(this.activeTurnId && event.turnId===this.activeTurnId) {
      try {
        await this.rpc('turn/steer',{threadId:this.threadId,expectedTurnId:this.activeTurnId,input:textInput(this.handoffRequest)});
        this.checkpointTurnId=this.activeTurnId;
        return;
      } catch(error) { this.report(`Active turn ended before steering: ${error.message}`); }
    }
    if(!this.activeTurnId) await this.startCheckpoint();
  }
  async startCheckpoint() {
    if(this.phase!=='checkpoint' || this.checkpointTurnId || this.activeTurnId) return;
    try {
      const result=await this.rpc('turn/start',{threadId:this.threadId,input:textInput(this.handoffRequest)});
      this.activeTurnId=result.turn.id; this.checkpointTurnId=result.turn.id;
    } catch(error) { this.phase='normal'; this.failCycle(`Handoff could not start; no compaction performed: ${error.message}`); }
  }
  failCycle(message) {
    this.report(message);
    if(this.once) { this.failed=true; this.done=true; }
  }
  async onItem(event) {
    const item=event.item || {};
    if(this.phase==='checkpoint' && event.turnId===this.checkpointTurnId && item.type==='agentMessage' && (item.text || '').trimStart().startsWith(HANDOFF)) {
      this.handoff=item.text;
      if(item.phase!=='final_answer' && !this.checkpointInterrupted) {
        this.checkpointInterrupted=true;
        this.report('Handoff captured. Stopping the active turn before compaction.');
        try { await this.rpc('turn/interrupt',{threadId:this.threadId,turnId:this.checkpointTurnId}); }
        catch(error) { this.report(`The handoff turn ended while it was being stopped: ${error.message}`); }
      }
    }
    if(this.phase==='compacting' && item.type==='contextCompaction') {
      this.compactionTurnId=event.turnId; this.compactionItemDone=true;
      await this.finishCompactionIfReady();
    }
  }
  async onTurnCompleted(event) {
    if(event.threadId!==this.threadId) return;
    const turn=event.turn || {};
    if(this.phase==='compacting' && (!this.compactionTurnId || turn.id===this.compactionTurnId)) {
      this.compactionTurnId=turn.id; this.compactionTurnDone=turn.status==='completed';
      if(turn.status!=='completed') { this.phase='normal'; this.failCycle(`Compaction ${turn.status}; handoff was not replayed.`); }
      else await this.finishCompactionIfReady();
      return;
    }
    if(turn.id===this.activeTurnId) this.activeTurnId=null;
    if(this.phase==='checkpoint') {
      if(!this.checkpointTurnId) { await this.startCheckpoint(); return; }
      if(turn.id!==this.checkpointTurnId) return;
      const fallback=(turn.items || []).filter(item=>item.type==='agentMessage' && (item.text || '').trimStart().startsWith(HANDOFF)).at(-1);
      if(!this.handoff) this.handoff=fallback?.text || '';
      const handoffTurnFinished=turn.status==='completed' || (this.checkpointInterrupted && turn.status==='interrupted');
      if(!handoffTurnFinished || !this.handoff.trimStart().startsWith(HANDOFF)) {
        this.phase='normal'; this.failCycle('Handoff was missing or incomplete; compaction skipped to preserve the task.');
        await this.drain(); return;
      }
      this.phase='compacting'; this.compactionItemDone=false; this.compactionTurnDone=false; this.compactionTurnId=null;
      this.report('Handoff captured. Compacting the thread now.');
      try { await this.rpc('thread/compact/start',{threadId:this.threadId}); }
      catch(error) { this.phase='normal'; this.failCycle(`Compaction failed; handoff was not replayed: ${error.message}`); await this.drain(); }
      return;
    }
    if(this.phase==='normal') {
      if(turn.status!=='completed') { this.failed=true; this.report(`Turn ${turn.status || 'failed'}.`); }
      if(this.once && !this.queue.length) this.done=true; else await this.drain();
    }
  }
  async finishCompactionIfReady() {
    if(this.phase!=='compacting' || !this.compactionItemDone || !this.compactionTurnDone) return;
    this.phase='replaying';
    this.report('Compaction completed. Replaying the quoted handoff and continuing.');
    try {
      const result=await this.rpc('turn/start',{threadId:this.threadId,input:textInput(replayPrompt(this.handoff))});
      this.activeTurnId=result.turn.id; this.phase='normal'; this.checkpointTurnId=null; this.checkpointInterrupted=false; this.handoff='';
    } catch(error) { this.phase='normal'; this.failCycle(`Replay failed; handoff remains visible above: ${error.message}`); await this.drain(); }
  }
  async drain() {
    if(!this.activeTurnId && this.queue.length && this.phase==='normal') {
      const queued=this.queue.shift(); await this.start(queued.input,queued.extra);
    }
  }
}

function decodeBase64(value, label) {
  try { return Buffer.from(value,'base64').toString('utf8'); }
  catch { throw Error(`Invalid ${label}.`); }
}

function readValue(args, index, option) {
  if(index+1>=args.length) throw Error(`Missing value for ${option}.`);
  return args[index+1];
}

function tomlString(value) { return JSON.stringify(String(value)); }

function translateLaunchArgs(rawArgs, defaultCwd) {
  if(!Array.isArray(rawArgs) || rawArgs.some(value=>typeof value!=='string')) throw Error('Codex launch arguments must be a string array.');
  const result={once:false,prompt:null,cwd:defaultCwd,configArgs:[],images:[],ephemeral:false,outputSchema:null,outputLastMessage:null};
  let i=0;
  if(rawArgs[0]==='exec' || rawArgs[0]==='e') { result.once=true; i++; }
  else if(['resume','fork','review'].includes(rawArgs[0])) throw Error(`Auto-compact does not yet support the ${rawArgs[0]} conversation command.`);
  const take=option=>{const value=readValue(rawArgs,i,option);i+=2;return value;};
  const addConfig=(key,value)=>result.configArgs.push('-c',`${key}=${tomlString(value)}`);
  while(i<rawArgs.length) {
    const arg=rawArgs[i];
    if(arg==='-C' || arg==='--cd') { result.cwd=path.resolve(defaultCwd,take(arg)); continue; }
    if(arg.startsWith('--cd=')) { result.cwd=path.resolve(defaultCwd,arg.slice(5)); i++; continue; }
    if(arg==='-m' || arg==='--model') { addConfig('model',take(arg)); continue; }
    if(arg.startsWith('--model=')) { addConfig('model',arg.slice(8)); i++; continue; }
    if(arg==='-s' || arg==='--sandbox') { addConfig('sandbox_mode',take(arg)); continue; }
    if(arg.startsWith('--sandbox=')) { addConfig('sandbox_mode',arg.slice(10)); i++; continue; }
    if(arg==='-a' || arg==='--ask-for-approval') { addConfig('approval_policy',take(arg)); continue; }
    if(arg.startsWith('--ask-for-approval=')) { addConfig('approval_policy',arg.slice(19)); i++; continue; }
    if(arg==='-c' || arg==='--config' || arg==='-p' || arg==='--profile' || arg==='--enable' || arg==='--disable') {
      result.configArgs.push(arg,take(arg)); continue;
    }
    if(/^--(config|profile|enable|disable)=/.test(arg)) {
      const split=arg.indexOf('='); result.configArgs.push(arg.slice(0,split),arg.slice(split+1)); i++; continue;
    }
    if(arg==='--strict-config') { result.configArgs.push(arg); i++; continue; }
    if(arg==='--search') { result.configArgs.push('-c','web_search="live"'); i++; continue; }
    if(arg==='--approve-for-me') {
      result.configArgs.push('-c','approval_policy="on-request"','-c','sandbox_mode="workspace-write"','-c','approvals_reviewer="auto_review"'); i++; continue;
    }
    if(arg==='--dangerously-bypass-approvals-and-sandbox') {
      result.configArgs.push('-c','approval_policy="never"','-c','sandbox_mode="danger-full-access"'); i++; continue;
    }
    if(arg==='-i' || arg==='--image') { result.images.push(take(arg)); continue; }
    if(arg.startsWith('--image=')) { result.images.push(arg.slice(8)); i++; continue; }
    if(arg==='--ephemeral') { result.ephemeral=true; i++; continue; }
    if(arg==='--output-schema') {
      const schemaPath=path.resolve(defaultCwd,take(arg));
      try { result.outputSchema=JSON.parse(fs.readFileSync(schemaPath,'utf8')); }
      catch(error) { throw Error(`Could not read output schema ${schemaPath}: ${error.message}`); }
      continue;
    }
    if(arg.startsWith('--output-schema=')) {
      const schemaPath=path.resolve(defaultCwd,arg.slice(16));
      try { result.outputSchema=JSON.parse(fs.readFileSync(schemaPath,'utf8')); }
      catch(error) { throw Error(`Could not read output schema ${schemaPath}: ${error.message}`); }
      i++; continue;
    }
    if(arg==='-o' || arg==='--output-last-message') { result.outputLastMessage=path.resolve(defaultCwd,take(arg)); continue; }
    if(arg.startsWith('--output-last-message=')) { result.outputLastMessage=path.resolve(defaultCwd,arg.slice(22)); i++; continue; }
    if(arg==='--color') { take(arg); continue; }
    if(arg.startsWith('--color=') || arg==='--no-alt-screen' || arg==='--skip-git-repo-check') { i++; continue; }
    if(['--worktree','--add-dir','--thread-source','--ignore-user-config','--ignore-rules','--json','--dangerously-bypass-hook-trust','--oss','--local-provider'].includes(arg)) {
      throw Error(`${arg} is not compatible with Deck auto-compact supervision.`);
    }
    if(arg==='-' && result.once) throw Error('Deck auto-compact exec requires the prompt as an argument; stdin is reserved for supervision.');
    if(arg.startsWith('-')) throw Error(`Unsupported Codex argument in auto-compact mode: ${arg}`);
    if(result.prompt!==null) throw Error(`Unexpected additional Codex argument: ${arg}`);
    result.prompt=arg; i++;
  }
  result.images=result.images.map(file=>path.resolve(result.cwd,file));
  if(result.once && !result.prompt) throw Error('Deck auto-compact exec requires a prompt argument.');
  return result;
}

function parseArgs(argv) {
  const options={threshold:55,cwd:process.cwd(),once:false,prompt:null,codexExe:null,codexEntry:null,configArgs:[],postConfigArgs:[],launchArgs:[],handoffRequest:HANDOFF_REQUEST};
  for(let i=0;i<argv.length;i++) {
    const arg=argv[i]; if(arg==='--') { options.configArgs=argv.slice(i+1); break; }
    if(arg==='--once') { options.once=true; continue; }
    if(['--threshold','--cwd','--prompt','--codex-exe','--codex-entry'].includes(arg)) { options[{ '--threshold':'threshold','--cwd':'cwd','--prompt':'prompt','--codex-exe':'codexExe','--codex-entry':'codexEntry' }[arg]]=readValue(argv,i,arg); i++; continue; }
    if(arg==='--launch-base64') {
      let decoded; try { decoded=JSON.parse(decodeBase64(readValue(argv,i,arg),'launch arguments')); } catch(error) { throw Error(`Invalid launch arguments: ${error.message}`); }
      if(!Array.isArray(decoded) || decoded.some(value=>typeof value!=='string')) throw Error('Invalid launch arguments: expected a string array.');
      options.launchArgs=decoded; i++; continue;
    }
    if(arg==='--post-config-base64') {
      let decoded; try { decoded=JSON.parse(decodeBase64(readValue(argv,i,arg),'post-config arguments')); } catch(error) { throw Error(`Invalid post-config arguments: ${error.message}`); }
      if(!Array.isArray(decoded) || decoded.some(value=>typeof value!=='string')) throw Error('Invalid post-config arguments: expected a string array.');
      options.postConfigArgs=decoded; i++; continue;
    }
    if(arg==='--handoff-base64') { options.handoffRequest=decodeBase64(readValue(argv,i,arg),'handoff prompt'); i++; continue; }
    throw Error(`Unknown auto-compact option: ${arg}`);
  }
  options.threshold=Number(options.threshold);
  if(!Number.isInteger(options.threshold) || options.threshold<30 || options.threshold>90) throw Error('Auto-compact remaining-context threshold must be 30-90%.');
  if(!options.codexExe) throw Error('Missing Codex executable.');
  if(!options.handoffRequest.trim().includes(HANDOFF)) throw Error(`Auto-compact handoff prompt must contain ${HANDOFF}.`);
  const launch=translateLaunchArgs(options.launchArgs,options.cwd);
  options.cwd=launch.cwd; options.once=options.once || launch.once; options.prompt=options.prompt ?? launch.prompt;
  options.configArgs=[...options.configArgs,...launch.configArgs,...options.postConfigArgs];
  options.images=launch.images; options.ephemeral=launch.ephemeral; options.outputSchema=launch.outputSchema; options.outputLastMessage=launch.outputLastMessage;
  return options;
}

async function main() {
  const options=parseArgs(process.argv.slice(2));
  const args=[...(options.codexEntry?[options.codexEntry]:[]),'app-server',...options.configArgs];
  const child=spawn(options.codexExe,args,{cwd:options.cwd,env:process.env,windowsHide:false,stdio:['pipe','pipe','inherit']});
  child.on('error',error=>{ process.stderr.write(`Codex app-server failed: ${error.message}\n`); process.exitCode=1; });
  const waiting=new Map(); let nextId=1;
  const send=value=>child.stdin.write(JSON.stringify(value)+'\n');
  const rpc=(method,params)=>new Promise((resolve,reject)=>{
    const id=nextId++; const timer=setTimeout(()=>{ waiting.delete(id); reject(Error(`${method} timed out`)); },30000);
    waiting.set(id,{resolve,reject,timer}); send({id,method,params});
  });
  const report=message=>process.stdout.write(`\n[Deck] ${message}\n`);
  const controller=new AutoCompactController(rpc,options.threshold,report,options.handoffRequest); controller.once=options.once;
  const input=readline.createInterface({input:process.stdin,output:process.stdout,terminal:process.stdin.isTTY});
  let approval=null; let multiline=null; let lastFinalMessage=''; let intentionalShutdown=false; const streamed=new Set();
  let controllerEvents=Promise.resolve();
  function finishOneShot() {
    if(!controller.done || intentionalShutdown) return;
    if(options.outputLastMessage && !controller.failed) {
      try { fs.writeFileSync(options.outputLastMessage,lastFinalMessage,'utf8'); }
      catch(error) { controller.failed=true; report(`Could not write final message: ${error.message}`); }
    }
    if(controller.failed) process.exitCode=1;
    else report('One-shot task completed successfully.');
    intentionalShutdown=true; child.kill(); input.close();
  }
  function queueControllerEvent(label, callback, fatal=false) {
    controllerEvents=controllerEvents.then(callback).then(finishOneShot).catch(error=>{
      if(fatal) process.exitCode=1;
      report(`${label}: ${error.message}`);
    });
  }
  function prompt() { if(!options.once) input.setPrompt(multiline?'...> ':'you> '), input.prompt(); }
  input.on('line',line=>{
    if(line.trim()==='/exit') { child.kill(); input.close(); return; }
    if(approval) {
      const state=approval; const request=state.request;
      if(request.method==='item/tool/requestUserInput') {
        const question=request.params.questions[state.index++];
        state.answers[question.id]={answers:[line]};
        if(state.index<request.params.questions.length) { report(request.params.questions[state.index].question || 'Codex requests input:'); prompt(); return; }
        send({id:request.id,result:{answers:state.answers}});
      } else send({id:request.id,result:{decision:/^(y|yes)$/i.test(line.trim())?'accept':'decline'}});
      approval=null;
      prompt(); return;
    }
    if(multiline) {
      if(line.trim()==='/send') { const message=multiline.join('\n'); multiline=null; if(message.trim()) controller.start(message).catch(error=>report(error.message)); }
      else if(line.trim()==='/cancel') { multiline=null; report('Draft discarded.'); }
      else multiline.push(line);
      prompt(); return;
    }
    if(line.trim()==='/multi') { multiline=[]; report('Multiline draft started. Enter /send to submit or /cancel to discard.'); prompt(); return; }
    if(line.trim()==='/help') { report('/status, /interrupt, /multi, /exit. In /multi mode, finish with /send or /cancel.'); prompt(); return; }
    if(line.trim()==='/status') { const used=controller.usagePercent; report(`Thread ${controller.threadId}; context ${used ?? '?'}% used / ${used===null?'?':100-used}% free; limit ${options.threshold}% free; state ${controller.phase}.`); prompt(); return; }
    if(line.trim()==='/interrupt' && controller.activeTurnId) { rpc('turn/interrupt',{threadId:controller.threadId,turnId:controller.activeTurnId}).catch(error=>report(error.message)); prompt(); return; }
    if(line.trim()) controller.start(line).catch(error=>report(error.message));
    prompt();
  });
  const server=readline.createInterface({input:child.stdout});
  server.on('line',line=>{
    let message; try { message=JSON.parse(line); } catch { return; }
    if(Object.prototype.hasOwnProperty.call(message,'id') && !message.method) {
      const pending=waiting.get(message.id); if(!pending)return;
      waiting.delete(message.id); clearTimeout(pending.timer);
      message.error?pending.reject(Error(message.error.message||'Codex request failed')):pending.resolve(message.result);
      return;
    }
    if(Object.prototype.hasOwnProperty.call(message,'id') && message.method) {
      if(approval) { send({id:message.id,error:{code:-32603,message:'Another user prompt is pending'}}); return; }
      if(['item/commandExecution/requestApproval','item/fileChange/requestApproval'].includes(message.method)) {
        approval={request:message}; report(`Approval requested: ${message.params.command || message.params.reason || message.method}. Type y to approve, anything else to decline.`); prompt();
      } else if(message.method==='item/tool/requestUserInput' && message.params.questions?.length) {
        approval={request:message,index:0,answers:{}}; report(message.params.questions[0].question || 'Codex requests input:'); prompt();
      } else { send({id:message.id,error:{code:-32603,message:'Unsupported interactive request in Deck auto-compact terminal'}}); report(`Unsupported Codex request: ${message.method}.`); }
      return;
    }
    const p=message.params || {};
    if(message.method==='thread/tokenUsage/updated') queueControllerEvent('Usage handler',()=>controller.onUsage(p));
    else if(message.method==='item/agentMessage/delta') { streamed.add(p.itemId); process.stdout.write(p.delta || ''); }
    else if(message.method==='item/completed') {
      queueControllerEvent('Item handler',()=>controller.onItem(p));
      if(p.item?.type==='agentMessage') { if(p.item.phase==='final_answer') lastFinalMessage=p.item.text || ''; if(!streamed.has(p.item.id)) process.stdout.write(`\n${p.item.text || ''}`); process.stdout.write('\n'); streamed.delete(p.item.id); }
      else if(p.item?.type==='commandExecution') report(`Command exited ${p.item.exitCode ?? p.item.status}: ${p.item.command || ''}`);
      else if(p.item?.type==='fileChange') report(`File change: ${p.item.status}.`);
    } else if(message.method==='turn/completed') queueControllerEvent('Turn handler',()=>controller.onTurnCompleted(p),true);
    else if(message.method==='error') report(`Codex error: ${p.error?.message || p.message || 'unknown'}`);
  });
  child.on('exit',(code,signal)=>{for(const pending of waiting.values()){clearTimeout(pending.timer);pending.reject(Error('Codex app-server exited'));}waiting.clear(); input.close(); if(code || (signal && !intentionalShutdown))process.exitCode=code || 1;});
  try {
    await rpc('initialize',{clientInfo:{name:'codex_deck_auto_compact',version:'1.0.0'},capabilities:{experimentalApi:true}});
    send({method:'initialized'});
    const threadParams={cwd:options.cwd,serviceName:'codex_deck_auto_compact'};
    if(options.ephemeral) threadParams.ephemeral=true;
    const started=await rpc('thread/start',threadParams);
    controller.threadId=started.thread.id;
    report(`Auto-compact ON when context reaches ${options.threshold}% free (${100-options.threshold}% used). Account: ${process.env.CODEX_HOME?.split(/[\\/]/).at(-1) || 'unknown'}. Thread: ${controller.threadId}`);
    report('Supervised terminal mode. /help lists terminal commands.');
    if(options.prompt) {
      const initial=textInput(options.prompt);
      for(const imagePath of options.images) initial.push({type:'localImage',path:imagePath});
      const extra=options.outputSchema?{outputSchema:options.outputSchema}:{};
      await controller.start(initial,extra);
    } else prompt();
  } catch(error) { report(`Could not start: ${error.message}`); child.kill(); input.close(); process.exitCode=1; }
}

module.exports={AutoCompactController,HANDOFF,HANDOFF_REQUEST,replayPrompt,parseArgs,translateLaunchArgs};
if(require.main===module) main().catch(error=>{process.stderr.write(error.message+'\n');process.exitCode=1;});
