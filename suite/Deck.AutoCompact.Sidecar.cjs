'use strict';

const {spawn} = require('node:child_process');
const net = require('node:net');
const {AutoCompactController, HANDOFF} = require('./Deck.AutoCompact.cjs');

function optionsFromArgs(args) {
  const options = {threshold:70, cwd:process.cwd(), codexExe:null, codexEntry:null, handoffRequest:null, serverConfig:[]};
  const names = {'--threshold':'threshold','--cwd':'cwd','--codex-exe':'codexExe','--codex-entry':'codexEntry'};
  for(let i=0;i<args.length;i++) {
    const name=args[i];
    if(i+1>=args.length) throw Error(`Missing value for ${name}.`);
    const value=args[++i];
    if(names[name]) options[names[name]]=value;
    else if(name==='--handoff-base64') options.handoffRequest=Buffer.from(value,'base64').toString('utf8');
    else if(name==='--server-config-base64') options.serverConfig=JSON.parse(Buffer.from(value,'base64').toString('utf8'));
    else throw Error(`Unknown sidecar option: ${name}`);
  }
  options.threshold=Number(options.threshold);
  if(!Number.isInteger(options.threshold) || options.threshold<30 || options.threshold>90) throw Error('Auto-compact remaining-context threshold must be 30-90%.');
  if(!options.codexExe) throw Error('Missing Codex executable.');
  if(!options.handoffRequest?.includes(HANDOFF)) throw Error(`Auto-compact handoff prompt must contain ${HANDOFF}.`);
  if(!Array.isArray(options.serverConfig) || options.serverConfig.some(value=>typeof value!=='string')) throw Error('Invalid server configuration arguments.');
  return options;
}

async function availablePort() {
  const server=net.createServer();
  await new Promise((resolve,reject)=>server.once('error',reject).listen(0,'127.0.0.1',resolve));
  const port=server.address().port;
  await new Promise(resolve=>server.close(resolve));
  return port;
}

function connect(url) {
  return new Promise((resolve,reject)=>{
    const socket=new WebSocket(url);
    socket.addEventListener('open',()=>resolve(socket),{once:true});
    socket.addEventListener('error',()=>reject(Error('Codex app-server is not ready')),{once:true});
  });
}

class RpcClient {
  constructor(socket, onNotification) {
    this.socket=socket; this.onNotification=onNotification; this.nextId=1; this.pending=new Map();
    socket.addEventListener('message',event=>{
      let message; try { message=JSON.parse(event.data); } catch { return; }
      if(Object.hasOwn(message,'id') && !message.method) {
        const pending=this.pending.get(message.id); if(!pending) return;
        this.pending.delete(message.id); clearTimeout(pending.timer);
        message.error?pending.reject(Error(message.error.message || 'Codex request failed')):pending.resolve(message.result);
      } else if(message.method && !Object.hasOwn(message,'id')) this.onNotification(message);
      // Interactive requests belong to the native TUI. This observer never answers them.
    });
    socket.addEventListener('close',()=>{
      for(const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(Error('Codex app-server disconnected')); }
      this.pending.clear();
    });
  }
  send(message) { this.socket.send(JSON.stringify(message)); }
  call(method, params) {
    return new Promise((resolve,reject)=>{
      const id=this.nextId++;
      const timer=setTimeout(()=>{this.pending.delete(id);reject(Error(`${method} timed out`));},30000);
      this.pending.set(id,{resolve,reject,timer});
      this.send({id,method,params});
    });
  }
}

class ThreadObserver {
  constructor(rpc, threshold, handoffRequest, report=()=>{}) {
    this.rpc=rpc; this.threshold=threshold; this.handoffRequest=handoffRequest; this.report=report;
    this.controllers=new Map(); this.pending=new Set(); this.subscribed=new Set(); this.serial=new Map();
  }
  async attach(threadId) {
    if(!this.controllers.has(threadId)) {
      const controller=new AutoCompactController(this.rpc,this.threshold,this.report,this.handoffRequest);
      controller.threadId=threadId;
      this.controllers.set(threadId,controller);
    }
    if(this.subscribed.has(threadId) || this.pending.has(threadId)) return;
    this.pending.add(threadId);
    try {
      await this.rpc('thread/resume',{threadId,excludeTurns:true});
      this.subscribed.add(threadId);
    } catch {
      // A newly started thread may be visible in memory before its rollout exists.
      // Discovery retries until this observer connection can subscribe to it.
    } finally { this.pending.delete(threadId); }
  }
  async discover() {
    let cursor;
    do {
      const result=await this.rpc('thread/loaded/list',cursor?{cursor}:{});
      for(const threadId of result.data || []) await this.attach(threadId);
      cursor=result.nextCursor;
    } while(cursor);
  }
  onNotification(message) {
    const event=message.params || {};
    if(message.method==='thread/started' && event.thread?.id) { this.attach(event.thread.id); return; }
    if(message.method==='thread/closed') { this.controllers.delete(event.threadId); this.subscribed.delete(event.threadId); this.serial.delete(event.threadId); return; }
    const controller=this.controllers.get(event.threadId);
    if(!controller) return;
    if(message.method==='turn/started') {
      if(controller.phase==='normal' || controller.phase==='checkpoint') controller.activeTurnId=event.turn?.id || null;
      return;
    }
    if(!['item/completed','thread/tokenUsage/updated','turn/completed'].includes(message.method)) return;
    const previous=this.serial.get(event.threadId) || Promise.resolve();
    const next=previous.then(async()=>{
      if(message.method==='item/completed') await controller.onItem(event);
      else if(message.method==='thread/tokenUsage/updated') {
        if(!controller.activeTurnId && controller.phase==='normal') controller.activeTurnId=event.turnId;
        await controller.onUsage(event);
      } else await controller.onTurnCompleted(event);
    }).catch(error=>this.report(`Auto-compact event failed for ${event.threadId}: ${error.message}`));
    this.serial.set(event.threadId,next);
  }
}

async function main() {
  const options=optionsFromArgs(process.argv.slice(2));
  const url=`ws://127.0.0.1:${await availablePort()}`;
  const args=[...(options.codexEntry?[options.codexEntry]:[]),'app-server','--listen',url,...options.serverConfig];
  const child=spawn(options.codexExe,args,{cwd:options.cwd,env:process.env,windowsHide:true,stdio:'ignore'});
  let stopped=false, socket=null, poll=null, serverError=null;
  function stop() {
    if(stopped) return;
    stopped=true; if(poll) clearInterval(poll);
    if(socket && socket.readyState===WebSocket.OPEN) socket.close();
    child.kill();
    setTimeout(()=>process.exit(process.exitCode || 0),2000).unref();
  }
  process.stdin.resume(); process.stdin.on('end',stop);
  process.on('SIGTERM',stop); process.on('SIGINT',stop);
  child.on('error',error=>{serverError=error;});
  child.on('exit',()=>{
    if(stopped) process.exit(process.exitCode || 0);
    process.stderr.write('Codex app-server exited while the native terminal was open.\n');
    process.exitCode=1; stop();
  });
  try {
    for(let attempt=0;attempt<100;attempt++) {
      if(serverError) throw serverError;
      if(child.exitCode!==null) throw Error('Codex app-server exited before it became ready.');
      try { socket=await connect(url); break; }
      catch { await new Promise(resolve=>setTimeout(resolve,100)); }
    }
    if(!socket) throw Error('Codex app-server did not become ready.');
    let observer;
    const client=new RpcClient(socket,message=>observer?.onNotification(message));
    // This app-server hosts the native Codex TUI. Keep its persisted threads in CLI history;
    // the observer connection must not classify the shared session as an editor client.
    await client.call('initialize',{clientInfo:{name:'codex-tui',version:'1.0.0'},capabilities:{experimentalApi:true}});
    client.send({method:'initialized'});
    let reportedBytes=0;
    const report=message=>{
      const line=`[Deck auto-compact] ${message}\n`;
      if(reportedBytes+Buffer.byteLength(line)>8192) return;
      reportedBytes+=Buffer.byteLength(line);
      process.stderr.write(line);
    };
    observer=new ThreadObserver((method,params)=>client.call(method,params),options.threshold,options.handoffRequest,report);
    await observer.discover();
    let discovering=false;
    poll=setInterval(async()=>{
      if(discovering) return;
      discovering=true;
      try { await observer.discover(); }
      catch(error) { report(`Thread discovery failed: ${error.message}`); }
      finally { discovering=false; }
    },500);
    process.stdout.write(`READY ${url}\n`);
  } catch(error) { process.stdout.write(`ERROR ${error.message}\n`); process.exitCode=1; stop(); }
}

module.exports={optionsFromArgs,ThreadObserver};
if(require.main===module) main().catch(error=>{process.stdout.write(`ERROR ${error.message}\n`);process.exitCode=1;});
