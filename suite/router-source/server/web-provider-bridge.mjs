import {createHash,randomUUID} from 'node:crypto';
import {HttpError} from './errors.mjs';
import {equalToken} from './store.mjs';
import {providers} from './catalog.mjs';

const MAX_FRAME=32*1024*1024;
const websocketGuid='258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function frame(opcode,value=''){
  const payload=Buffer.isBuffer(value)?value:Buffer.from(String(value));
  let header;
  if(payload.length<126){header=Buffer.from([0x80|opcode,payload.length]);}
  else if(payload.length<=0xffff){header=Buffer.allocUnsafe(4);header[0]=0x80|opcode;header[1]=126;header.writeUInt16BE(payload.length,2);}
  else{header=Buffer.allocUnsafe(10);header[0]=0x80|opcode;header[1]=127;header.writeBigUInt64BE(BigInt(payload.length),2);}
  return Buffer.concat([header,payload]);
}

export class WebProviderBridge{
  constructor(store){this.store=store;this.connection=null;this.pending=new Map();this.keepalive=setInterval(()=>this.send({type:'bridge.ping'}),15000);this.keepalive.unref?.();}
  get online(){return !!this.connection&&!this.connection.socket.destroyed;}
  send(message,connection=this.connection){if(!connection||connection.socket.destroyed)return false;try{connection.socket.write(frame(1,JSON.stringify(message)));return true;}catch{return false;}}
  rejectPending(error){
    for(const [id,item] of this.pending){this.pending.delete(id);item.signal?.removeEventListener('abort',item.abort);if(item.controller){try{item.controller.error(error);}catch{}}else item.reject(error);}
  }
  upgrade(request,socket,head){
    const host=request.headers.host||'',origin=request.headers.origin||'',extension=/^chrome-extension:\/\/([a-p]{32})$/.exec(origin);
    const key=request.headers['sec-websocket-key'];
    if(!/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(host)||request.url!=='/extension-bridge'||!extension||!key||request.headers['sec-websocket-version']!=='13'){
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');return;
    }
    const accept=createHash('sha1').update(key+websocketGuid).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.setNoDelay(true);
    const connection={socket,extensionId:extension[1],authenticated:false,buffer:Buffer.alloc(0),fragments:[],fragmentOpcode:0,fragmentBytes:0,authTimer:null};
    connection.authTimer=setTimeout(()=>this.closeConnection(connection,1008,'Authentication required'),5000);
    socket.on('data',chunk=>this.receive(connection,chunk));
    socket.on('error',()=>this.closeConnection(connection,1001,'Connection lost'));
    socket.on('close',()=>this.closeConnection(connection,1001,'Connection lost'));
    if(head?.length)this.receive(connection,head);
  }
  receive(connection,chunk){
    connection.buffer=Buffer.concat([connection.buffer,chunk]);
    if(connection.buffer.length>MAX_FRAME*2){this.closeConnection(connection,1009,'Bridge message is too large');return;}
    while(connection.buffer.length>=2){
      const first=connection.buffer[0],second=connection.buffer[1],fin=!!(first&0x80),opcode=first&0x0f,masked=!!(second&0x80);
      if(!masked){this.closeConnection(connection,1002,'Client frames must be masked');return;}
      let length=second&0x7f,offset=2;
      if(length===126){if(connection.buffer.length<4)return;length=connection.buffer.readUInt16BE(2);offset=4;}
      else if(length===127){if(connection.buffer.length<10)return;const big=connection.buffer.readBigUInt64BE(2);if(big>BigInt(MAX_FRAME)){this.closeConnection(connection,1009,'Bridge message is too large');return;}length=Number(big);offset=10;}
      if(length>MAX_FRAME){this.closeConnection(connection,1009,'Bridge message is too large');return;}
      if(connection.buffer.length<offset+4+length)return;
      const mask=connection.buffer.subarray(offset,offset+4),payload=Buffer.from(connection.buffer.subarray(offset+4,offset+4+length));
      connection.buffer=connection.buffer.subarray(offset+4+length);
      for(let i=0;i<payload.length;i++)payload[i]^=mask[i&3];
      if(opcode===8){this.closeConnection(connection,1000,'Closed');return;}
      if(opcode===9){if(!fin||length>125){this.closeConnection(connection,1002,'Invalid control frame');return;}connection.socket.write(frame(10,payload));continue;}
      if(opcode===10)continue;
      if(opcode===1){
        if(connection.fragmentOpcode){this.closeConnection(connection,1002,'Nested data frame');return;}
        if(fin)this.message(connection,payload.toString('utf8'));
        else{connection.fragmentOpcode=1;connection.fragments=[payload];connection.fragmentBytes=payload.length;}
      }else if(opcode===0){
        if(!connection.fragmentOpcode){this.closeConnection(connection,1002,'Unexpected continuation');return;}
        connection.fragmentBytes+=payload.length;if(connection.fragmentBytes>MAX_FRAME){this.closeConnection(connection,1009,'Bridge message is too large');return;}connection.fragments.push(payload);
        if(fin){const value=Buffer.concat(connection.fragments);connection.fragments=[];connection.fragmentOpcode=0;connection.fragmentBytes=0;this.message(connection,value.toString('utf8'));}
      }else{this.closeConnection(connection,1003,'Text messages only');return;}
    }
  }
  message(connection,text){
    let message;try{message=JSON.parse(text);}catch{this.closeConnection(connection,1007,'Invalid bridge message');return;}
    if(!connection.authenticated){
      if(message.type!=='bridge.auth'||!equalToken(message.token,this.store.secrets.adminToken)){this.closeConnection(connection,1008,'Invalid Router owner key');return;}
      const paired=this.store.config.clients.map(client=>client.pairingExtension).filter(Boolean);
      if(paired.length&&!paired.includes(connection.extensionId)){this.closeConnection(connection,1008,'This extension is not paired with the Router');return;}
      clearTimeout(connection.authTimer);connection.authenticated=true;
      if(this.connection&&this.connection!==connection)this.closeConnection(this.connection,1012,'A newer Router extension connected');
      this.connection=connection;this.send({type:'bridge.ready'});return;
    }
    if(message.type==='bridge.pong')return;
    const item=this.pending.get(message.id);if(!item||item.connection!==connection)return;
    if(message.type==='web.response.start'){
      const status=Number(message.status),headers={};
      if(Number.isInteger(status)&&status>=200&&status<=599){
        for(const name of ['content-type','retry-after','cache-control'])if(typeof message.headers?.[name]==='string')headers[name]=message.headers[name];
        const stream=new ReadableStream({start:controller=>{item.controller=controller;},cancel:()=>this.cancel(message.id)});
        item.started=true;item.resolve(new Response([204,205,304].includes(status)?null:stream,{status,headers}));
      }else this.fail(message.id,new HttpError(502,'The browser extension returned an invalid provider response.'));
      return;
    }
    if(message.type==='web.response.chunk'){
      if(!item.controller||typeof message.chunk!=='string')return;
      try{item.controller.enqueue(new Uint8Array(Buffer.from(message.chunk,'base64')));}catch(error){this.fail(message.id,error);}
      return;
    }
    if(message.type==='web.response.end'){
      if(!item.started){this.fail(message.id,new HttpError(502,'The browser extension ended a provider request before returning a response.'));return;}
      if(item.controller){try{item.controller.close();}catch{}}
      this.finish(message.id);return;
    }
    if(message.type==='web.response.error')this.fail(message.id,new HttpError(Number(message.status)||502,String(message.error||'The browser extension could not reach the provider.')));
  }
  finish(id){const item=this.pending.get(id);if(!item)return;this.pending.delete(id);item.signal?.removeEventListener('abort',item.abort);}
  fail(id,error){const item=this.pending.get(id);if(!item)return;this.pending.delete(id);item.signal?.removeEventListener('abort',item.abort);if(item.controller){try{item.controller.error(error);}catch{}}else item.reject(error);}
  cancel(id){const item=this.pending.get(id);if(!item)return;this.send({type:'web.cancel',id},item.connection);this.fail(id,new HttpError(499,'Provider request cancelled.'));}
  closeConnection(connection,code=1001,reason='Connection closed'){
    if(connection.closed)return;connection.closed=true;clearTimeout(connection.authTimer);
    if(!connection.socket.destroyed){try{connection.socket.write(frame(8,Buffer.concat([Buffer.from([code>>8,code&255]),Buffer.from(reason)])));}catch{}connection.socket.end();}
    if(this.connection===connection){this.connection=null;this.rejectPending(new HttpError(503,'The Router extension disconnected while handling a web provider request.'));}
  }
  fetch(url,options={}){
    const connection=this.connection;
    if(!connection?.authenticated||connection.socket.destroyed)return Promise.reject(new HttpError(503,'Connect the AIDeck Router extension to use signed-in web provider accounts.'));
    if(options.body!==undefined&&options.body!==null&&typeof options.body!=='string')return Promise.reject(new HttpError(400,'Web provider requests require a JSON request body.'));
    const providerId=options.headers?.['x-aideck-web-provider'],accountId=options.headers?.['x-aideck-web-account'];
    const provider=providers.find(item=>item.id===providerId&&item.webSession),account=this.store.config.accounts.find(item=>item.id===accountId&&item.provider===providerId);
    let target;try{target=new URL(url);}catch{return Promise.reject(new HttpError(400,'Invalid web provider request URL.'));}
    if(!provider||!account||target.origin!==new URL(provider.baseUrl).origin||!['GET','POST'].includes(options.method||'GET'))return Promise.reject(new HttpError(400,'Web provider request does not match an enabled Router account.'));
    const id=randomUUID(),signal=options.signal;
    return new Promise((resolve,reject)=>{
      if(this.pending.size>=32){reject(new HttpError(429,'Too many web provider requests are already in progress.'));return;}
      const item={resolve,reject,signal,started:false,controller:null,connection,abort:null};
      item.abort=()=>this.cancel(id);this.pending.set(id,item);
      if(signal?.aborted){this.cancel(id);return;}
      signal?.addEventListener('abort',item.abort,{once:true});
      const sent=this.send({type:'web.request',id,url:String(url),method:options.method||'GET',headers:options.headers||{},body:options.body??null},connection);
      if(!sent)this.fail(id,new HttpError(503,'The Router extension disconnected before the provider request started.'));
    });
  }
  close(){clearInterval(this.keepalive);if(this.connection)this.closeConnection(this.connection,1001,'Router is shutting down');this.rejectPending(new HttpError(503,'The Router server is shutting down.'));}
}
