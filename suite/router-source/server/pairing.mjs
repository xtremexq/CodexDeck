import fs from 'node:fs';
import path from 'node:path';
import {randomUUID,randomInt} from 'node:crypto';
import {requireThat} from './errors.mjs';
import {newKey,hashKey} from './admin.mjs';
import {equalToken} from './store.mjs';

export class Pairing{
  constructor(store){this.store=store;this.pending=new Map();this.file=path.join(store.directory,'pairing.json');this.approvals=path.join(store.directory,'approvals.json');this.write();}
  write(){const now=Date.now();for(const [id,item]of this.pending)if(item.expires<=now)this.pending.delete(id);const temporary=this.file+'.tmp';fs.writeFileSync(temporary,JSON.stringify([...this.pending.values()].map(({id,extension,code,expires})=>({id,extension,code,expires}))),{mode:0o600});fs.renameSync(temporary,this.file);}
  create(extension,secret){
    this.write();requireThat(typeof secret==='string'&&/^[A-Za-z0-9_-]{43,128}$/.test(secret),'Invalid pairing proof.');requireThat(this.pending.size<8,'Too many pending pairing requests. Wait for an existing request to expire.',429);
    const item={id:randomUUID(),extension,secret,code:String(randomInt(100000,1000000)),expires:Date.now()+300000};this.pending.set(item.id,item);this.write();return {id:item.id,code:item.code,expires:item.expires,status:'pending'};
  }
  async claim(id,extension,secret){
    this.write();const item=this.pending.get(id);requireThat(item&&item.extension===extension&&equalToken(item.secret,secret),'Pairing request expired or proof is invalid.',403);
    let approval;try{approval=JSON.parse(fs.readFileSync(this.approvals,'utf8').replace(/^\uFEFF/,''));}catch{}
    if(approval?.id!==id||approval?.code!==item.code)return {status:'pending'};
    fs.rmSync(this.approvals,{force:true});this.pending.delete(id);this.write();
    const bridgeKey=newKey();this.store.config.clients.push({id:randomUUID(),name:'Chrome Router bridge',hash:await hashKey(bridgeKey),routes:this.store.config.routes.filter(r=>r.enabled).map(r=>r.id),rpm:60,enabled:true,created:new Date().toISOString()});this.store.save();
    return {status:'approved',token:this.store.secrets.adminToken,bridgeKey};
  }
}
