import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq-owned-status.js', import.meta.url), 'utf8');
const endpoint = 'https://api.groq.com/openai/v1/chat/completions';
const profiles = {
  gptoss20b: { model:'openai/gpt-oss-20b', label:'GPT OSS 20B', temperature:1, maximum:16384, topP:1 },
  qwen27b: { model:'qwen/qwen3.8-27b', label:'Qwen/Qwen3.8-27B', temperature:0.6, maximum:8192, topP:0.95 },
  gptoss120b: { model:'openai/gpt-oss-120b', label:'GPT OSS 120B', temperature:1, maximum:16384, topP:1 },
};
type Profile = keyof typeof profiles;
const prompt = 'Harmless synthetic status marker. e\u0301 🦆';
function deferred<T>() {
  let resolve!: (value:T)=>void, reject!: (reason:unknown)=>void;
  const promise = new Promise<T>((yes,no)=>{resolve=yes;reject=no;});
  return { promise, resolve, reject };
}
function fixture(profile:Profile='qwen27b', options:{configProfile?:string;syncError?:Error}={}) {
  const selected=profiles[profile], pending=deferred<any>(), calls:{receiver:unknown;args:unknown[]}[]=[];
  const original=function(this:unknown,...args:unknown[]) {calls.push({receiver:this,args});if(options.syncError)throw options.syncError;return pending.promise;};
  let clock=0, privateReads=0, visibleLabel=selected.label;
  let button:any={isConnected:true,getClientRects:()=>[{}],closest:()=>null,
    querySelectorAll:()=>[{}],getAttribute:(name:string)=>({'aria-controls':'picker','aria-expanded':'false','data-state':'closed'} as any)[name]??null,
    get innerText(){return visibleLabel;}, get textContent(){return visibleLabel;}};
  const document={baseURI:'https://chat.groq.com/',querySelectorAll:(selector:string)=>selector.startsWith('button')?[button]:[]};
  const location={origin:'https://chat.groq.com',href:'https://chat.groq.com/?model='+encodeURIComponent(selected.model)};
  class ResponseDouble {
    constructor(public code=429,public finalURL=endpoint,public redirectedValue=false,public kind='cors'){}
    get url(){return this.finalURL;}get redirected(){return this.redirectedValue;}get status(){return this.code;}get type(){return this.kind;}
    get headers(){privateReads++;throw Error('PRIVATE_HEADER');}get body(){privateReads++;throw Error('PRIVATE_BODY');}
    clone(){privateReads++;throw Error('PRIVATE_BODY');}text(){privateReads++;throw Error('PRIVATE_BODY');}json(){privateReads++;throw Error('PRIVATE_BODY');}
  }
  const window:any={fetch:original};window.top=window;
  const key='__computaGroqStatus_'+'a'.repeat(32),secret='b'.repeat(32);
  const config={key:'a'.repeat(32),secret,durationMs:1000,profile:options.configProfile??profile};
  new Function('window','top','location','document','Response','performance','setTimeout','clearTimeout','getComputedStyle',
    source.replace('__GROQ_OWNED_SYNTHETIC_CONFIG__',JSON.stringify(config)))(window,window,location,document,ResponseDouble,
      {now:()=>clock},()=>1,()=>{},()=>({visibility:'visible'}));
  const ctl=(command:string,args:any={},givenSecret=secret)=>window[key]?.(givenSecret,command,args);
  const arm=(args:any={})=>ctl('arm',{model:selected.model,label:selected.label,prompt,...args});
  const body=(extra:any={},system=profile!=='qwen27b',pretty=false)=>JSON.stringify({model:selected.model,
    messages:[...(system?[{content:'Harmless system with escaped \" quote',role:'system'}]:[]),{content:prompt,role:'user'}],
    temperature:selected.temperature,max_completion_tokens:selected.maximum,top_p:selected.topP,stream:true,...extra},null,pretty?2:undefined);
  const finish=()=>ctl('finish');
  return {window,original,calls,pending,selected,location,ResponseDouble,arm,body,ctl,finish,key,
    tick:(n:number)=>{clock=n;},privateReads:()=>privateReads,driftLabel:()=>{visibleLabel='Foreign model';},replacePicker:()=>{button={...button};}};
}
const settle=async(f:ReturnType<typeof fixture>,status:number)=>{const response=new f.ResponseDouble(status);f.pending.resolve(response);await f.pending.promise;await Promise.resolve();return response;};

test('all three fixed profiles match exact compact/pretty public requests and retain original fetch identity and result',async()=>{
  for(const profile of Object.keys(profiles) as Profile[])for(const pretty of [false,true]){
    const f=fixture(profile),cached=f.window.fetch;expect(f.arm()).toBe(true);expect(f.arm()).toBe(false);
    const init={method:'POST',body:f.body({},profile!=='qwen27b',pretty)},receiver={synthetic:true};
    const promise=cached.call(receiver,endpoint,init);expect(promise).toBe(f.pending.promise);expect(f.calls).toHaveLength(1);
    expect(f.calls[0].receiver).toBe(receiver);expect(f.calls[0].args).toEqual([endpoint,init]);expect(f.calls[0].args[1]).toBe(init);
    const response=await settle(f,429);expect(await promise).toBe(response);expect(f.finish()).toBe('http_429');
    expect(f.privateReads()).toBe(0);expect(f.window.fetch).toBe(f.original);expect(f.window[f.key]).toBeUndefined();
  }
});
test('finite HTTP status classes distinguish400 and429 while2xx only proves headers',async()=>{
  for(const profile of Object.keys(profiles) as Profile[])for(const [status,expected] of [[200,'http_2xx_opened'],[400,'http_400'],[401,'http_401'],[403,'http_403'],[413,'http_413'],[429,'http_429'],[422,'http_other_non_2xx'],[503,'http_other_non_2xx'],[302,'ambiguous']] as const){
    const f=fixture(profile);f.arm();f.window.fetch(endpoint,{method:'POST',body:f.body()});await settle(f,status);
    expect(f.finish()).toBe(expected);expect(f.privateReads()).toBe(0);expect(f.calls).toHaveLength(1);
  }
});
test('foreign model,label,temperature,output maximum,topP,streaming or body shape cannot claim a matched request',async()=>{
  for(const profile of Object.keys(profiles) as Profile[]){
    const mutations=[{model:'foreign/model'},{temperature:0.123},{max_completion_tokens:4096},{top_p:0.123},{stream:false},
      {messages:[{content:prompt+'foreign',role:'user'}]},{unexpected:true}];
    for(const extra of mutations){const f=fixture(profile);f.arm();f.window.fetch(endpoint,{method:'POST',body:f.body(extra)});await settle(f,429);expect(f.finish()).toBe('ambiguous');expect(f.calls).toHaveLength(1);}
    for(const args of [{model:'foreign/model'},{label:'Foreign model'}]){const f=fixture(profile);expect(f.arm(args)).toBe(false);}
  }
  const q=fixture('qwen27b');q.arm();q.window.fetch(endpoint,{method:'POST',body:q.body({},true)});await settle(q,429);expect(q.finish()).toBe('ambiguous');
  const unknown=fixture('qwen27b',{configProfile:'foreign'});expect(unknown.window.fetch).toBe(unknown.original);expect(unknown.arm()).toBeUndefined();
});
test('foreign URL,duplicate keys,request objects and property getters refuse without extra reads or sends',async()=>{
  for(const mode of ['nearURL','duplicateKey','requestObject','bodyGetter','methodGetter']){
    const f=fixture();f.arm();let reads=0;let init:any={method:'POST',body:f.body()};let input:any=endpoint;
    if(mode==='nearURL')input+='?foreign=1';
    if(mode==='duplicateKey')init.body=init.body.replace('{"model":','{"model":"foreign","model":');
    if(mode==='requestObject')input={url:endpoint};
    if(mode==='bodyGetter')Object.defineProperty(init,'body',{get(){reads++;throw Error('PRIVATE');}});
    if(mode==='methodGetter')Object.defineProperty(init,'method',{get(){reads++;throw Error('PRIVATE');}});
    const promise=f.window.fetch(input,init);expect(promise).toBe(f.pending.promise);await settle(f,429);
    expect(f.finish()).toBe('ambiguous');expect(reads).toBe(0);expect(f.calls).toHaveLength(1);
  }
});
test('headers and credentials are never inspected and response error content is never read',async()=>{
  const f=fixture();f.arm();let sensitive=0;const init:any={method:'POST',body:f.body()};
  for(const name of ['headers','credentials'])Object.defineProperty(init,name,{get(){sensitive++;throw Error('PRIVATE');}});
  f.window.fetch(endpoint,init);await settle(f,400);expect(f.finish()).toBe('http_400');expect(sensitive).toBe(0);expect(f.privateReads()).toBe(0);
});
test('expired,foreign picker,route drift,duplicate fetch and explicit disposal cannot publish a status',async()=>{
  for(const mode of ['expired','label','picker','route','duplicate','dispose']){
    const f=fixture();f.arm();const cached=f.window.fetch;cached(endpoint,{method:'POST',body:f.body()});
    if(mode==='expired')f.tick(1001);if(mode==='label')f.driftLabel();if(mode==='picker')f.replacePicker();
    if(mode==='route')f.location.href='https://chat.groq.com/?model=foreign';
    if(mode==='duplicate')cached(endpoint,{method:'POST',body:f.body()});if(mode==='dispose')f.ctl('dispose');
    await settle(f,429);expect(f.finish()).toBe(mode==='dispose'?undefined:'ambiguous');
    expect(f.calls).toHaveLength(mode==='duplicate'?2:1);expect(f.window.fetch).toBe(f.original);
  }
});
test('network rejection,synchronous throw,pending and unmatched captures keep exact original outcomes',async()=>{
  const f=fixture();f.arm();const error=new TypeError('PRIVATE_ERROR');const promise=f.window.fetch(endpoint,{method:'POST',body:f.body()});
  f.pending.reject(error);try{await promise;throw Error('expected reject');}catch(e){expect(e).toBe(error);}await Promise.resolve();
  expect(f.finish()).toBe('transport_rejected');expect(f.calls).toHaveLength(1);
  const sync=new Error('PRIVATE_SYNC'),s=fixture('qwen27b',{syncError:sync});s.arm();
  expect(()=>s.window.fetch(endpoint,{method:'POST',body:s.body()})).toThrow(sync);expect(s.finish()).toBe('ambiguous');expect(s.calls).toHaveLength(1);
  const pending=fixture();pending.arm();pending.window.fetch(endpoint,{method:'POST',body:pending.body()});expect(pending.finish()).toBe('matched_fetch_unsettled');
  const empty=fixture();empty.arm();expect(empty.finish()).toBe('no_matching_fetch_observed');
});
