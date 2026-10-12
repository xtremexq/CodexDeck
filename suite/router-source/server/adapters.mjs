const randomUUID = () => globalThis.crypto.randomUUID();
import { fetch, ProxyAgent } from './transport.mjs';
import { providerById } from './catalog.mjs';
import { HttpError, requireThat } from './errors.mjs';

function contentBlocks(content) {
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  requireThat(Array.isArray(content) || content == null, 'Invalid message content.');
  return (content || []).map(part => {
    if (part.type === 'text') return { type: 'text', text: part.text };
    if (part.type === 'image_url') {
      const url = part.image_url?.url || '';
      const match = /^data:(image\/(?:png|jpeg|webp|gif));base64,(.+)$/s.exec(url);
      if (match) return { type: 'image', source: { type: 'base64', media_type: match[1], data: match[2] } };
      requireThat(/^https?:\/\//.test(url), 'Claude images require an HTTP URL or a supported base64 data URL.');
      return { type: 'image', source: { type: 'url', url } };
    }
    throw new HttpError(400, `Claude adapter does not support content type ${part.type}. Use the native Messages endpoint for provider-specific features.`);
  });
}
export function toAnthropic(body) {
  const supported = new Set(['model','messages','max_tokens','max_completion_tokens','temperature','top_p','top_k','stop','stream','stream_options','tools','tool_choice','metadata','user']);
  for (const key of Object.keys(body)) requireThat(supported.has(key), `Claude chat adapter does not support ${key}; use /v1/messages for native features.`);
  requireThat(Array.isArray(body.messages) && body.messages.length, 'messages must be a nonempty array.');
  const result = { model: body.model, max_tokens: body.max_tokens || body.max_completion_tokens || 4096, messages: [], stream: body.stream === true };
  const system = [];
  for (const message of body.messages) {
    if (['system','developer'].includes(message.role)) { system.push(...contentBlocks(message.content)); continue; }
    let role, content;
    if (message.role === 'tool') {
      requireThat(typeof message.tool_call_id === 'string', 'Tool results need tool_call_id.');
      role = 'user'; content = [{ type: 'tool_result', tool_use_id: message.tool_call_id, content: typeof message.content === 'string' ? message.content : contentBlocks(message.content) }];
    } else {
      requireThat(['user','assistant'].includes(message.role), 'Unsupported chat role.');
      role = message.role; content = contentBlocks(message.content);
      for (const call of message.tool_calls || []) {
        requireThat(role === 'assistant' && call.type === 'function', 'Invalid tool call.');
        let input; try { input = JSON.parse(call.function.arguments); } catch { throw new HttpError(400, 'Tool arguments must be valid JSON.'); }
        content.push({ type: 'tool_use', id: call.id, name: call.function.name, input });
      }
    }
    requireThat(content.length, 'Empty messages are not supported by Claude.');
    const previous = result.messages.at(-1);
    if (previous?.role === role) previous.content.push(...content); else result.messages.push({ role, content });
  }
  requireThat(result.messages.length, 'Include a user message.');
  if (system.length) result.system = system;
  for (const key of ['temperature','top_p','top_k','metadata']) if (body[key] !== undefined) result[key] = body[key];
  if (body.stop) result.stop_sequences = Array.isArray(body.stop) ? body.stop : [body.stop];
  if (body.tools && body.tool_choice !== 'none') {
    result.tools = body.tools.map(t => { requireThat(t.type === 'function' && t.function?.name, 'Only function tools are supported.'); return { name: t.function.name, description: t.function.description, input_schema: t.function.parameters || { type: 'object', properties: {} } }; });
    if (body.tool_choice === 'required') result.tool_choice = { type: 'any' };
    else if (typeof body.tool_choice === 'object') result.tool_choice = { type: 'tool', name: body.tool_choice.function.name };
    else if (body.tool_choice) result.tool_choice = { type: 'auto' };
  }
  return result;
}
const finishReason = reason => reason === 'tool_use' ? 'tool_calls' : reason === 'max_tokens' ? 'length' : 'stop';
function usage(value) {
  const prompt = (value.input_tokens || 0) + (value.cache_creation_input_tokens || 0) + (value.cache_read_input_tokens || 0);
  return { prompt_tokens: prompt, completion_tokens: value.output_tokens || 0, total_tokens: prompt + (value.output_tokens || 0) };
}
export function fromAnthropic(value) {
  const calls = (value.content || []).filter(c => c.type === 'tool_use').map(c => ({ id: c.id, type: 'function', function: { name: c.name, arguments: JSON.stringify(c.input) } }));
  return { id: value.id, object: 'chat.completion', created: Math.floor(Date.now()/1000), model: value.model, choices: [{ index: 0, message: { role: 'assistant', content: (value.content || []).filter(c => c.type === 'text').map(c => c.text).join('') || null, ...(calls.length ? { tool_calls: calls } : {}) }, finish_reason: finishReason(value.stop_reason) }], usage: usage(value.usage || {}) };
}
export function messagesToChat(body) {
  const supported = new Set(['model','messages','system','max_tokens','temperature','top_p','stop_sequences','stream','tools','tool_choice']);
  for (const key of Object.keys(body)) requireThat(supported.has(key), `Cross-provider Messages adapter does not support ${key}. Use an Anthropic-only route for native Claude features.`);
  requireThat(Array.isArray(body.messages) && body.messages.length, 'Include Messages content.');
  const result = { model: body.model, messages: [], max_tokens: body.max_tokens, stream: body.stream === true };
  if (body.system) {
    const blocks = typeof body.system === 'string' ? [{type:'text',text:body.system}] : body.system;
    requireThat(Array.isArray(blocks) && blocks.every(b=>b.type==='text'), 'System content must be text for cross-provider routing.');
    result.messages.push({role:'system',content:blocks.map(b=>b.text).join('\n')});
  }
  for (const message of body.messages) {
    requireThat(['user','assistant'].includes(message.role),'Invalid Messages role.');
    const blocks = typeof message.content === 'string' ? [{type:'text',text:message.content}] : message.content;
    requireThat(Array.isArray(blocks),'Invalid Messages content.');
    const content=[],calls=[],results=[];
    for (const b of blocks) {
      if (b.type==='text') content.push({type:'text',text:b.text});
      else if (b.type==='image') {
        requireThat(['base64','url'].includes(b.source?.type),'Unsupported image source.');
        content.push({type:'image_url',image_url:{url:b.source.type==='base64'?`data:${b.source.media_type};base64,${b.source.data}`:b.source.url}});
      } else if (b.type==='tool_use') calls.push({id:b.id,type:'function',function:{name:b.name,arguments:JSON.stringify(b.input)}});
      else if (b.type==='tool_result') {
        const text = typeof b.content==='string' ? b.content : (b.content||[]).map(p=>{requireThat(p.type==='text','Cross-provider tool results must contain text.');return p.text;}).join('\n');
        results.push({role:'tool',tool_call_id:b.tool_use_id,content:text});
      } else throw new HttpError(400,`Cross-provider Messages does not support ${b.type}.`);
    }
    result.messages.push(...results);
    if(content.length||calls.length)result.messages.push({role:message.role,content:content.length?content:null,...(calls.length?{tool_calls:calls}:{})});
  }
  for (const key of ['temperature','top_p']) if(body[key]!==undefined)result[key]=body[key];
  if(body.stop_sequences)result.stop=body.stop_sequences;
  if(body.tools)result.tools=body.tools.map(t=>{requireThat(!t.type || t.type==='custom','Native provider tools cannot be routed to other providers.');return {type:'function',function:{name:t.name,description:t.description,parameters:t.input_schema}};});
  if(body.tool_choice){result.tool_choice=body.tool_choice.type==='any'?'required':body.tool_choice.type==='tool'?{type:'function',function:{name:body.tool_choice.name}}:body.tool_choice.type==='none'?'none':'auto';}
  return result;
}
const nativeStop = finish => finish==='tool_calls'?'tool_use':finish==='length'?'max_tokens':'end_turn';
export function chatToMessages(value) {
  const choice=value.choices?.[0];requireThat(choice,'Invalid chat response from upstream.',502);
  const content=[];
  if(choice.message.content)content.push({type:'text',text:choice.message.content});
  for(const call of choice.message.tool_calls||[]){let input;try{input=JSON.parse(call.function.arguments);}catch{throw new HttpError(502,'Upstream tool arguments were not JSON.');}content.push({type:'tool_use',id:call.id,name:call.function.name,input});}
  return {id:value.id,type:'message',role:'assistant',model:value.model,content,stop_reason:nativeStop(choice.finish_reason),stop_sequence:null,usage:{input_tokens:value.usage?.prompt_tokens||0,output_tokens:value.usage?.completion_tokens||0}};
}
export async function* messagesStream(body,model) {
  const frame=(type,value)=>`event: ${type}\ndata: ${JSON.stringify({type,...value})}\n\n`;
  let started=false,index=0,textIndex=null,finish='end_turn',totals={input_tokens:0,output_tokens:0};const tools=new Map();
  for await(const data of sseEvents(body)){
    if(data==='[DONE]')break;
    let chunk;try{chunk=JSON.parse(data);}catch{throw new HttpError(502,'Invalid upstream chat stream.');}
    if(chunk.error)throw new HttpError(502,'Upstream provider reported a stream error.');
    if(!started){yield frame('message_start',{message:{id:chunk.id||'msg_'+randomUUID(),type:'message',role:'assistant',model,content:[],stop_reason:null,stop_sequence:null,usage:totals}});started=true;}
    if(chunk.usage)totals={input_tokens:chunk.usage.prompt_tokens||0,output_tokens:chunk.usage.completion_tokens||0};
    const choice=chunk.choices?.[0];const delta=choice?.delta;
    if(delta?.content){if(textIndex===null){textIndex=index++;yield frame('content_block_start',{index:textIndex,content_block:{type:'text',text:''}});}yield frame('content_block_delta',{index:textIndex,delta:{type:'text_delta',text:delta.content}});}
    for(const call of delta?.tool_calls||[]){
      let tool=tools.get(call.index);
      if(!tool){requireThat(call.id&&call.function?.name,'Upstream tool stream must include its initial ID and name.',502);tool={index:index++};tools.set(call.index,tool);yield frame('content_block_start',{index:tool.index,content_block:{type:'tool_use',id:call.id,name:call.function.name,input:{}}});}
      if(call.function?.arguments)yield frame('content_block_delta',{index:tool.index,delta:{type:'input_json_delta',partial_json:call.function.arguments}});
    }
    if(choice?.finish_reason)finish=nativeStop(choice.finish_reason);
  }
  requireThat(started,'Upstream stream was empty.',502);
  if(textIndex!==null)yield frame('content_block_stop',{index:textIndex});
  for(const tool of tools.values())yield frame('content_block_stop',{index:tool.index});
  yield frame('message_delta',{delta:{stop_reason:finish,stop_sequence:null},usage:totals});
  yield frame('message_stop',{});
}
export async function* sseEvents(body) {
  const reader = body.getReader(); const decoder = new TextDecoder(); let buffer = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      // Preserve a CR split across network chunks until the following LF arrives.
      buffer = buffer.replace(/\r\n/g, '\n');
      let end;
      while ((end = buffer.indexOf('\n\n')) !== -1) {
        const frame = buffer.slice(0,end); buffer = buffer.slice(end+2);
        const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (data) yield data;
      }
      if (done) break;
      requireThat(buffer.length < 8 * 1024 * 1024, 'Upstream SSE frame exceeds 8 MB.', 502);
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}
export async function* anthropicStream(body, model, includeUsage) {
  let id = 'chatcmpl-' + randomUUID(); let totals = {}; let ended = false;
  const toolIndices = new Map();
  const chunk = (delta, finish = null, extra = {}) => 'data: ' + JSON.stringify({ id, object: 'chat.completion.chunk', created: Math.floor(Date.now()/1000), model, choices: [{ index: 0, delta, finish_reason: finish }], ...extra }) + '\n\n';
  for await (const data of sseEvents(body)) {
    let event; try { event = JSON.parse(data); } catch { throw new HttpError(502, 'Invalid Claude streaming response.'); }
    if (event.type === 'error') throw new HttpError(502, 'Claude reported an error during streaming.');
    if (event.type === 'message_start') { id = event.message.id; totals = event.message.usage || {}; yield chunk({ role: 'assistant', content: '' }); }
    if (event.type === 'content_block_start' && event.content_block.type === 'tool_use') {
      const index = toolIndices.size; toolIndices.set(event.index,index);
      yield chunk({ tool_calls: [{ index, id: event.content_block.id, type: 'function', function: { name: event.content_block.name, arguments: '' } }] });
    }
    if (event.type === 'content_block_delta') {
      if (event.delta.type === 'text_delta') yield chunk({ content: event.delta.text });
      if (event.delta.type === 'input_json_delta') yield chunk({ tool_calls: [{ index: toolIndices.get(event.index), function: { arguments: event.delta.partial_json } }] });
    }
    if (event.type === 'message_delta') { totals = { ...totals, ...event.usage }; yield chunk({}, finishReason(event.delta.stop_reason)); }
    if (event.type === 'message_stop') {
      if (includeUsage) yield 'data: ' + JSON.stringify({ id, object: 'chat.completion.chunk', created: Math.floor(Date.now()/1000), model, choices: [], usage: usage(totals) }) + '\n\n';
      yield 'data: [DONE]\n\n'; ended = true;
    }
  }
  if (!ended) throw new HttpError(502, 'Claude stream ended before message_stop.');
}
export class Adapters {
  constructor(fetchImpl = fetch) { this.fetch = fetchImpl; this.proxies = new Map(); }
  dispatcher(url) { if (!url) return undefined; if (!this.proxies.has(url)) this.proxies.set(url,new ProxyAgent(url)); return this.proxies.get(url); }
  async request(account, key, endpoint, body, signal, { raw = false, contentType = 'application/json', method = 'POST' } = {}) {
    const provider = providerById(account.provider);
    const translated = provider.dialect === 'anthropic' && endpoint === '/chat/completions';
    const reverse = provider.dialect !== 'anthropic' && endpoint === '/messages';
    const headers = { 'content-type': contentType, accept: body?.stream ? 'text/event-stream' : '*/*' };
    if (provider.dialect === 'anthropic') { headers['x-api-key'] = key; headers['anthropic-version'] = '2023-06-01'; }
    else if (key) headers.authorization = `Bearer ${key}`;
    if (provider.webSession) {
      headers['x-aideck-web-provider'] = provider.id;
      headers['x-aideck-web-account'] = account.id;
      headers['x-aideck-web-transport'] = account.webOptions?.transport || 'api-v2';
      headers['x-aideck-web-images'] = account.webOptions?.images === false ? 'false' : 'true';
      headers['x-aideck-web-tools'] = account.webOptions?.tools === false ? 'false' : 'true';
    }
    if (provider.id === 'openrouter') headers['X-OpenRouter-Title'] = 'AIDeck Router';
    const payload = translated ? toAnthropic(body) : reverse ? messagesToChat(body) : body;
    let requestBody = raw ? body : JSON.stringify(payload);
    if (body instanceof FormData) { requestBody=body;delete headers['content-type']; }
    const response = await this.fetch(account.baseUrl + (translated ? '/messages' : reverse ? '/chat/completions' : endpoint), { method, headers, ...(method !== 'GET' ? { body: requestBody } : {}), signal, dispatcher: this.dispatcher(account.proxyUrl), redirect: 'error' });
    return { response, translated, reverse };
  }
  async close() { await Promise.all([...this.proxies.values()].map(p => p.close())); }
}
