'use strict';

const {spawn} = require('node:child_process');
const net = require('node:net');
const http = require('node:http');
const crypto = require('node:crypto');
const {AutoCompactController, HANDOFF} = require('./Deck.AutoCompact.cjs');

function optionsFromArgs(args) {
  const options = {threshold:55, cwd:process.cwd(), codexExe:null, codexEntry:null, handoffRequest:null, serverConfig:[], mode:'Custom', autoEnabled:false};
  const names = {'--threshold':'threshold','--cwd':'cwd','--codex-exe':'codexExe','--codex-entry':'codexEntry','--mode':'mode','--auto-enabled':'autoEnabled'};
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
  options.autoEnabled=options.autoEnabled===true || options.autoEnabled==='true';
  if(!Number.isInteger(options.threshold) || options.threshold<30 || options.threshold>90) throw Error('Auto-compact remaining-context threshold must be 30-90%.');
  if(!['Custom','Native'].includes(options.mode)) throw Error('Compaction mode must be Native or Custom.');
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
  constructor(rpc, threshold, handoffRequest, report=()=>{}, mode='Custom', autoEnabled=true) {
    this.rpc=rpc; this.threshold=threshold; this.handoffRequest=handoffRequest; this.report=report; this.mode=mode; this.autoEnabled=autoEnabled;
    this.controllers=new Map(); this.pending=new Set(); this.subscribed=new Set(); this.serial=new Map();
    this.targetThreadId=null; this.selection=Promise.resolve();
  }
  async attach(threadId) {
    if(!threadId) return;
    if(this.targetThreadId!==threadId) {
      const previous=this.targetThreadId;
      this.targetThreadId=threadId;
      if(previous) {
        this.controllers.delete(previous); this.subscribed.delete(previous); this.serial.delete(previous);
      }
      if(!this.controllers.has(threadId)) {
        const controller=new AutoCompactController(this.rpc,this.threshold,this.report,this.handoffRequest,this.mode,this.autoEnabled);
        controller.threadId=threadId;
        this.controllers.set(threadId,controller);
      }
      if(previous) {
        try { await this.rpc('thread/unsubscribe',{threadId:previous}); } catch {}
        if(this.targetThreadId!==threadId) return;
      }
    }
    if(!this.controllers.has(threadId)) {
      const controller=new AutoCompactController(this.rpc,this.threshold,this.report,this.handoffRequest,this.mode,this.autoEnabled);
      controller.threadId=threadId;
      this.controllers.set(threadId,controller);
    }
    if(this.subscribed.has(threadId) || this.pending.has(threadId)) return;
    this.pending.add(threadId);
    try {
      await this.rpc('thread/resume',{threadId,excludeTurns:true});
      if(this.targetThreadId===threadId) this.subscribed.add(threadId);
      else {
        try { await this.rpc('thread/unsubscribe',{threadId}); } catch {}
      }
    } catch {
      // A newly started thread may be visible in memory before its rollout exists.
      // Retry until this observer connection can subscribe to the active TUI thread.
    } finally { this.pending.delete(threadId); }
  }
  async retry() {
    await this.selection;
    if(this.targetThreadId) { await this.attach(this.targetThreadId); return; }
    // A remote TUI does not always broadcast thread/started when it resumes an
    // existing conversation. This app-server belongs to one managed terminal,
    // so its sole loaded thread is the TUI conversation we can safely attach.
    const loaded=await this.rpc('thread/loaded/list',{});
    const ids=loaded?.data || [];
    let threadId=ids.length===1?ids[0]:null;
    if(ids.length>1) {
      const threads=await Promise.all(ids.map(async id=>{
        try { return (await this.rpc('thread/read',{threadId:id,includeTurns:false})).thread; }
        catch { return null; }
      }));
      const roots=threads.filter(thread=>thread && !thread.parentThreadId && thread.originator==='codex-tui');
      if(roots.length===1) threadId=roots[0].id;
    }
    if(typeof threadId==='string') {
      this.selection=this.attach(threadId);
      await this.selection;
    }
  }
  async requestCompact() {
    await this.selection;
    if(!this.targetThreadId) await this.retry();
    const threadId=this.targetThreadId;
    if(!threadId) throw Error('The active Codex thread is not available yet.');
    for(let attempt=0;attempt<10 && !this.subscribed.has(threadId);attempt++) {
      if(this.targetThreadId!==threadId) throw Error('The active Codex thread changed; try again.');
      await this.attach(threadId);
      if(!this.subscribed.has(threadId)) await new Promise(resolve=>setTimeout(resolve,250));
    }
    if(!this.subscribed.has(threadId)) throw Error('The active Codex thread is not ready yet; try again.');
    const previous=this.serial.get(threadId) || Promise.resolve();
    const next=previous.then(async()=>{
      if(this.targetThreadId!==threadId) throw Error('The active Codex thread changed; try again.');
      if(!await this.controllers.get(threadId).requestCompact()) throw Error('Compaction could not start or is already in progress.');
    });
    this.serial.set(threadId,next.catch(()=>{}));
    return next;
  }
  onNotification(message) {
    const event=message.params || {};
    if(message.method==='thread/started' && event.thread?.id) {
      // The native TUI emits this for the conversation it starts or resumes. Child
      // threads belong to subagents and must never replace the observed conversation.
      if(event.thread.parentThreadId || this.pending.has(event.thread.id)) return;
      this.selection=this.attach(event.thread.id).catch(error=>this.report(`Thread selection failed: ${error.message}`));
      return;
    }
    if(message.method==='thread/closed') {
      this.controllers.delete(event.threadId); this.subscribed.delete(event.threadId); this.serial.delete(event.threadId);
      if(this.targetThreadId===event.threadId) this.targetThreadId=null;
      return;
    }
    const controller=this.controllers.get(event.threadId);
    if(!controller) return;
    if(message.method==='turn/started') {
      if(['normal','checkpoint','native-pending'].includes(controller.phase)) controller.activeTurnId=event.turn?.id || null;
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

async function createCompactControl(observer) {
  const secret=crypto.randomBytes(32).toString('hex');
  const server=http.createServer((req,res)=>{
    const port=server.address().port;
    if(req.headers.host!==`127.0.0.1:${port}` || req.headers.origin || req.url!==`/${secret}/compact` || req.method!=='POST' || Number(req.headers['content-length'] || 0)>0) {
      res.writeHead(403); res.end('Forbidden.'); return;
    }
    req.resume();
    observer.requestCompact().then(()=>{res.writeHead(202);res.end('Compaction requested.');},error=>{res.writeHead(409);res.end(error.message);});
  });
  await new Promise((resolve,reject)=>server.once('error',reject).listen(0,'127.0.0.1',resolve));
  return {server,url:`http://127.0.0.1:${server.address().port}/${secret}/compact`};
}

async function main() {
  const options=optionsFromArgs(process.argv.slice(2));
  const url=`ws://127.0.0.1:${await availablePort()}`;
  const args=[...(options.codexEntry?[options.codexEntry]:[]),'app-server','--listen',url,...options.serverConfig];
  const child=spawn(options.codexExe,args,{cwd:options.cwd,env:process.env,windowsHide:true,stdio:'ignore'});
  let stopped=false, socket=null, poll=null, control=null, serverError=null;
  function stop() {
    if(stopped) return;
    stopped=true; if(poll) clearInterval(poll);
    if(control) control.server.close();
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
    // The observer only joins a thread after the native TUI starts or resumes it. Give
    // it a distinct identity so it cannot be mistaken for another interactive TUI.
    await client.call('initialize',{clientInfo:{name:'codex_deck_auto_compact_observer',version:'1.0.0'},capabilities:{experimentalApi:true}});
    client.send({method:'initialized'});
    let reportedBytes=0;
    const report=message=>{
      const line=`[Deck auto-compact] ${message}\n`;
      if(reportedBytes+Buffer.byteLength(line)>8192) return;
      reportedBytes+=Buffer.byteLength(line);
      process.stderr.write(line);
    };
    observer=new ThreadObserver((method,params)=>client.call(method,params),options.threshold,options.handoffRequest,report,options.mode,options.autoEnabled);
    let retrying=false;
    poll=setInterval(async()=>{
      if(retrying) return;
      retrying=true;
      try { await observer.retry(); }
      catch(error) { report(`Thread subscription retry failed: ${error.message}`); }
      finally { retrying=false; }
    },500);
    control=await createCompactControl(observer);
    process.stdout.write(`READY ${url} ${control.url}\n`);
  } catch(error) { process.stdout.write(`ERROR ${error.message}\n`); process.exitCode=1; stop(); }
}

module.exports={optionsFromArgs,ThreadObserver,createCompactControl};
if(require.main===module) main().catch(error=>{process.stdout.write(`ERROR ${error.message}\n`);process.exitCode=1;});
