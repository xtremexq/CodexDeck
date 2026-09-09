'use strict';
const {spawn,execFile} = require('node:child_process');
const {randomUUID} = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
function configArguments(args) {
  const result=[];
  for(let i=0;i<args.length;i++) {
    const arg=args[i]; if(arg==='--') break;
    if(['-c','--config','-p','--profile','--enable','--disable'].includes(arg)) {
      if(i+1>=args.length) throw Error('Missing configuration argument.');
      result.push(arg,args[++i]);
    } else if (/^--(?:config|profile|enable|disable)=/.test(arg) || /^-[cp].+/.test(arg)) result.push(arg);
  }
  return result;
}
function readConfig(executable, prefix, args, cwd, codexHome) {
  return new Promise((resolve,reject)=>{
    const child=spawn(executable,[...prefix,...configArguments(args),'app-server'],{cwd,env:{...process.env,CODEX_HOME:codexHome},windowsHide:true,stdio:['pipe','pipe','pipe']});
    let settled=false;
    const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);child.stdin.end();child.kill();error?reject(error):resolve(value);};
    const timer=setTimeout(()=>finish(Error('Codex configuration lookup timed out.')),15000);
    child.on('error',()=>finish(Error('Could not read account instructions through Codex.')));
    child.on('exit',()=>{if(!settled)finish(Error('Codex could not resolve account configuration.'));});
    child.stderr.resume(); // Never echo configuration diagnostics or secrets.
    child.stdin.on('error',()=>finish(Error('Codex configuration connection closed.')));
    const send=value=>child.stdin.write(JSON.stringify(value)+'\n');
    readline.createInterface({input:child.stdout}).on('line',line=>{
      let message;try{message=JSON.parse(line);}catch{return;}
      if(message.id!==1 && message.id!==2)return;
      if(message.error)return finish(Error('Codex rejected configuration lookup. Check account configuration.'));
      if(message.id===1){send({method:'initialized'});send({id:2,method:'config/read',params:{includeLayers:false,cwd}});}
      else finish(null,message.result.config);
    });
    send({id:1,method:'initialize',params:{clientInfo:{name:'codex_deck_rules',version:'1.0.0'},capabilities:{experimentalApi:true}}});
  });
}
async function profileInstructions(request,cwd) {
  // App-server cannot select runtime profiles. The local prompt inspector can.
  // A unique replacement identifies the exact custom-instruction segment without
  // copying built-in, skill, project, or permission instructions into our override.
  const marker='DECK_RULES_'+randomUUID();
  const inspect=replacement=>new Promise((resolve,reject)=>{
    const args=[...request.prefix,...configArguments(request.args),...(replacement?['-c','developer_instructions='+JSON.stringify(marker)]:[]),'debug','prompt-input'];
    execFile(request.executable,args,{cwd,env:{...process.env,CODEX_HOME:request.codexHome},windowsHide:true,timeout:15000,maxBuffer:8*1024*1024},(error,stdout)=>{
      if(error)return reject(Error('Codex could not inspect profile instructions.'));
      try{resolve(JSON.parse(stdout).filter(item=>item.role==='developer').flatMap(item=>item.content.map(part=>part.text||'')).join('\n'));}
      catch{reject(Error('Codex returned an unsupported prompt inspection format.'));}
    });
  });
  const [original,replaced]=await Promise.all([inspect(false),inspect(true)]);
  const at=replaced.indexOf(marker);
  if(at<0 || replaced.indexOf(marker,at+marker.length)>=0)throw Error('Could not identify profile instructions.');
  const before=replaced.slice(0,at),after=replaced.slice(at+marker.length);
  if(!original.startsWith(before)||!original.endsWith(after)||original.length<before.length+after.length)throw Error('Profile instructions changed during lookup; retry the launch.');
  return original.slice(before.length,original.length-after.length);
}
async function ruleArguments(request) {
  request.args=(request.args||[]).filter(arg=>typeof arg==='string');
  const rules=fs.existsSync(request.rulesPath)?fs.readFileSync(request.rulesPath,'utf8').replace(/^\uFEFF/,'').trim():'';
  if(!rules)return [];
  let cwd=request.cwd;
  for(let i=0;i<request.args.length;i++){
    if(request.args[i]==='--')break;
    if(['-C','--cd'].includes(request.args[i]))cwd=path.resolve(request.cwd,request.args[++i]);
    else if(request.args[i].startsWith('--cd='))cwd=path.resolve(request.cwd,request.args[i].slice(5));
    else if(/^-C.+/.test(request.args[i]))cwd=path.resolve(request.cwd,request.args[i].slice(2));
  }
  const hasProfile=configArguments(request.args).some(arg=>arg==='-p'||arg==='--profile'||arg.startsWith('--profile=')||/^-p.+/.test(arg));
  const existing=hasProfile?await profileInstructions(request,cwd):(await readConfig(request.executable,request.prefix,request.args,cwd,request.codexHome)).developer_instructions;
  const combined=[existing || '', 'Global Rules (Codex Deck):\n'+rules].filter(Boolean).join('\n\n');
  return ['-c','developer_instructions='+JSON.stringify(combined)];
}
module.exports={ruleArguments,configArguments};
if(require.main===module){
  let input='';process.stdin.setEncoding('utf8');process.stdin.on('data',chunk=>input+=chunk);
  process.stdin.on('end',()=>ruleArguments(JSON.parse(input.replace(/^\uFEFF/,''))).then(args=>process.stdout.write(JSON.stringify(args))).catch(error=>{process.stderr.write(error.message+'\n');process.exitCode=1;}));
}
