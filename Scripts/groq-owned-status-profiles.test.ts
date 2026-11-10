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
type FixtureOptions={configProfile?:string;syncError?:Error;setupDiagnostics?:boolean;nonWritableFetch?:boolean;missingResponseGetter?:boolean;triggerCount?:number;pickerClosed?:boolean;siteWrapperBeforeInstall?:boolean};
function fixture(profile:Profile='qwen27b', options:FixtureOptions={}) {
  const selected=profiles[profile], pending=deferred<any>(), calls:{receiver:unknown;args:unknown[]}[]=[];
  const original=function(this:unknown,...args:unknown[]) {calls.push({receiver:this,args});if(options.syncError)throw options.syncError;return pending.promise;};
  let clock=0, privateReads=0, visibleLabel=selected.label;
  let button:any={isConnected:true,getClientRects:()=>[{}],closest:()=>null,
    querySelectorAll:()=>[{}],getAttribute:(name:string)=>({'aria-controls':'picker','aria-expanded':options.pickerClosed===false?'true':'false','data-state':options.pickerClosed===false?'open':'closed'} as any)[name]??null,
    get innerText(){return visibleLabel;}, get textContent(){return visibleLabel;}};
  const document={baseURI:'https://chat.groq.com/',querySelectorAll:(selector:string)=>selector.startsWith('button')?Array.from({length:options.triggerCount??1},()=>button):[]};
  const location={origin:'https://chat.groq.com',href:'https://chat.groq.com/?model='+encodeURIComponent(selected.model)};
  class ResponseDouble {
    constructor(public code=429,public finalURL=endpoint,public redirectedValue=false,public kind='cors'){}
    get url(){return this.finalURL;}get redirected(){return this.redirectedValue;}get status(){return this.code;}get type(){return this.kind;}
    get headers(){privateReads++;throw Error('PRIVATE_HEADER');}get body(){privateReads++;throw Error('PRIVATE_BODY');}
    clone(){privateReads++;throw Error('PRIVATE_BODY');}text(){privateReads++;throw Error('PRIVATE_BODY');}json(){privateReads++;throw Error('PRIVATE_BODY');}
  }
  if(options.missingResponseGetter)delete (ResponseDouble.prototype as any).status;
  const siteCalls:{receiver:unknown;args:unknown[]}[]=[];
  const siteFetch=function(this:unknown,...args:unknown[]) {
    siteCalls.push({receiver:this,args});return Reflect.apply(original,this,args);
  };
  const window:any={fetch:options.siteWrapperBeforeInstall?siteFetch:original};window.top=window;
  const preinstallFetch=window.fetch;
  if(options.nonWritableFetch)Object.defineProperty(window,'fetch',{value:original,writable:false,configurable:true,enumerable:true});
  const fetchDescriptorBefore=Object.getOwnPropertyDescriptor(window,'fetch');
  const timers=new Map<number,()=>void>();let nextTimer=0;
  const setTimer=(callback:()=>void)=>{const id=++nextTimer;timers.set(id,callback);return id;};
  const clearTimer=(id:number)=>{timers.delete(id);};
  const key='__computaGroqStatus_'+'a'.repeat(32),secret='b'.repeat(32);
  const config={key:'a'.repeat(32),secret,durationMs:1000,profile:options.configProfile??profile,
    ...(options.setupDiagnostics===undefined?{}:{setupDiagnostics:options.setupDiagnostics})};
  new Function('window','top','location','document','Response','performance','setTimeout','clearTimeout','getComputedStyle',
    source.replace('__GROQ_OWNED_SYNTHETIC_CONFIG__',JSON.stringify(config)))(window,window,location,document,ResponseDouble,
      {now:()=>clock},setTimer,clearTimer,()=>({visibility:'visible'}));
  const ctl=(command:string,args:any={},givenSecret=secret)=>window[key]?.(givenSecret,command,args);
  const arm=(args:any={})=>ctl('arm',{model:selected.model,label:selected.label,prompt,...args});
  const body=(extra:any={},system=profile!=='qwen27b',pretty=false)=>JSON.stringify({model:selected.model,
    messages:[...(system?[{content:'Harmless system with escaped \" quote',role:'system'}]:[]),{content:prompt,role:'user'}],
    temperature:selected.temperature,max_completion_tokens:selected.maximum,top_p:selected.topP,stream:true,...extra},null,pretty?2:undefined);
  const finish=()=>ctl('finish');
  return {window,original,calls,pending,selected,location,ResponseDouble,arm,body,ctl,finish,key,fetchDescriptorBefore,
    siteFetch,siteCalls,preinstallFetch,
    timerCount:()=>timers.size,fireTimers:()=>{for(const [id,callback] of [...timers]){timers.delete(id);callback();}},
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


test('fixture-only initializer diagnostics are closed one-read reasons without fetch or private response reads',()=>{
  const failures:[FixtureOptions,string][]=[
    [{nonWritableFetch:true},'js_fetch_descriptor'],
    [{missingResponseGetter:true},'js_response_getters'],
    [{configProfile:'foreign'},'js_profile_unavailable'],
  ];
  for(const [options,reason] of failures){
    for(const setupDiagnostics of [undefined,false,true]){
      const f=fixture('gptoss120b',{...options,setupDiagnostics});
      expect(f.calls).toHaveLength(0);expect(f.privateReads()).toBe(0);
      expect(f.window.fetch).toBe(f.original);
      expect(Object.getOwnPropertyDescriptor(f.window,'fetch')).toEqual(f.fetchDescriptorBefore);
      if(setupDiagnostics===true){
        expect(f.ctl('arm',{},'foreign-secret')).toBe(false);
        expect(f.arm()).toBe(reason);expect(f.arm()).toBe(false);
        expect(f.finish()).toBe(false);expect(f.timerCount()).toBe(1);
        expect(f.ctl('dispose')).toBe(true);expect(f.timerCount()).toBe(0);
        expect(f.window[f.key]).toBeUndefined();
        const expired=fixture('gptoss120b',{...options,setupDiagnostics:true});
        const controller=expired.window[expired.key];expired.tick(1001);expired.fireTimers();
        expect(expired.window[expired.key]).toBeUndefined();expect(expired.timerCount()).toBe(0);
        expect(controller('b'.repeat(32),'arm',{})).toBe(false);
        expect(expired.window.fetch).toBe(expired.original);
        expect(Object.getOwnPropertyDescriptor(expired.window,'fetch')).toEqual(expired.fetchDescriptorBefore);
        expect(expired.calls).toHaveLength(0);expect(expired.privateReads()).toBe(0);
      }else{
        expect(f.window[f.key]).toBeUndefined();expect(f.arm()).toBeUndefined();expect(f.timerCount()).toBe(0);
      }
      expect(Object.getOwnPropertyDescriptor(f.window,'fetch')).toEqual(f.fetchDescriptorBefore);
      expect(f.calls).toHaveLength(0);expect(f.privateReads()).toBe(0);
    }
  }
});

test('fixture-only arm diagnostics preserve marker refusal and disposal while successful requests remain exact',async()=>{
  const modes=['fetch','picker','tooManyPickers','notClosed','route','model','label','prompt','oversize','expired','alreadyArmed'] as const;
  const reasons={fetch:'js_fetch_replaced',picker:'js_picker_label_mismatch',tooManyPickers:'js_picker_unavailable',
    notClosed:'js_picker_not_closed',route:'js_route_unavailable',
    model:'js_model_mismatch',label:'js_model_mismatch',prompt:'js_prompt_unavailable',oversize:'js_prompt_unavailable',
    expired:'js_arm_state_unavailable',alreadyArmed:'js_arm_state_unavailable'};
  for(const mode of modes)for(const setupDiagnostics of [undefined,false,true]){
    const f=fixture('gptoss120b',{setupDiagnostics,
      ...(mode==='tooManyPickers'?{triggerCount:65}:{}),...(mode==='notClosed'?{pickerClosed:false}:{})});
    const foreign=()=>{throw Error('FOREIGN_FETCH_MUST_NOT_RUN');};
    let args:any={};
    if(mode==='fetch')f.window.fetch=foreign;
    if(mode==='picker')f.driftLabel();
    if(mode==='route')f.location.href='https://chat.groq.com/?model=foreign';
    if(mode==='model')args={model:'foreign/model'};if(mode==='label')args={label:'Foreign model'};
    if(mode==='prompt')args={prompt:''};if(mode==='oversize')args={prompt:'x'.repeat(180201)};
    if(mode==='expired')f.tick(1001);if(mode==='alreadyArmed')expect(f.arm()).toBe(true);
    expect(f.arm(args)).toBe(setupDiagnostics===true?reasons[mode]:false);
    expect(f.calls).toHaveLength(0);expect(f.privateReads()).toBe(0);
    if(mode==='fetch')expect(f.window.fetch).toBe(foreign);
    expect(f.ctl('dispose')).toBe(true);expect(f.timerCount()).toBe(0);expect(f.window[f.key]).toBeUndefined();
    expect(f.window.fetch).toBe(mode==='fetch'?foreign:f.original);
    if(mode!=='fetch')expect(Object.getOwnPropertyDescriptor(f.window,'fetch')).toEqual(f.fetchDescriptorBefore);
  }
  const timed=fixture('gptoss120b',{setupDiagnostics:true});
  expect(timed.arm({prompt:''})).toBe('js_prompt_unavailable');timed.tick(1001);timed.fireTimers();
  expect(timed.window.fetch).toBe(timed.original);expect(timed.window[timed.key]).toBeUndefined();
  expect(Object.getOwnPropertyDescriptor(timed.window,'fetch')).toEqual(timed.fetchDescriptorBefore);
  expect(timed.calls).toHaveLength(0);expect(timed.privateReads()).toBe(0);
  for(const profile of Object.keys(profiles) as Profile[]){
    const f=fixture(profile,{setupDiagnostics:true});expect(f.arm()).toBe(true);
    const init={method:'POST',body:f.body()},receiver={synthetic:true};
    const promise=f.window.fetch.call(receiver,endpoint,init);expect(promise).toBe(f.pending.promise);
    expect(f.calls).toHaveLength(1);expect(f.calls[0].receiver).toBe(receiver);
    expect(f.calls[0].args).toEqual([endpoint,init]);expect(f.calls[0].args[1]).toBe(init);
    const response=await settle(f,400);expect(await promise).toBe(response);expect(f.finish()).toBe('http_400');
    expect(f.privateReads()).toBe(0);expect(f.window.fetch).toBe(f.original);expect(f.timerCount()).toBe(0);
  }
});


test('observer installed after the site wrapper forwards exactly once and restores that captured wrapper',async()=>{
  const f=fixture('gptoss120b',{setupDiagnostics:true,siteWrapperBeforeInstall:true});
  expect(f.preinstallFetch).toBe(f.siteFetch);expect(f.siteFetch).not.toBe(f.original);
  expect(f.window.fetch).not.toBe(f.siteFetch);expect(f.siteCalls).toHaveLength(0);expect(f.calls).toHaveLength(0);
  expect(f.arm()).toBe(true);
  const receiver={synthetic:true},init={method:'POST',body:f.body()};
  const promise=f.window.fetch.call(receiver,endpoint,init);expect(promise).toBe(f.pending.promise);
  expect(f.siteCalls).toHaveLength(1);expect(f.calls).toHaveLength(1);
  for(const call of [f.siteCalls[0],f.calls[0]]){
    expect(call.receiver).toBe(receiver);expect(call.args).toEqual([endpoint,init]);expect(call.args[1]).toBe(init);
  }
  const response=await settle(f,200);expect(await promise).toBe(response);
  expect(f.finish()).toBe('http_2xx_opened');
  expect(f.window.fetch).toBe(f.siteFetch);expect(f.window.fetch).not.toBe(f.original);
  expect(Object.getOwnPropertyDescriptor(f.window,'fetch')).toEqual(f.fetchDescriptorBefore);
  expect(f.timerCount()).toBe(0);expect(f.window[f.key]).toBeUndefined();expect(f.privateReads()).toBe(0);
});

test('cached preinstallation fetch bypass stays unmatched without a fabricated HTTP result or rebinding',async()=>{
  for(const kind of ['site','original'] as const){
    const f=fixture('gptoss120b',{setupDiagnostics:true,siteWrapperBeforeInstall:true});
    const cached=kind==='site'?f.preinstallFetch:f.original,observer=f.window.fetch;
    expect(f.arm()).toBe(true);
    const receiver={synthetic:true},init={method:'POST',body:f.body()};
    const promise=cached.call(receiver,endpoint,init);expect(promise).toBe(f.pending.promise);
    expect(f.window.fetch).toBe(observer);expect(f.calls).toHaveLength(1);
    expect(f.siteCalls).toHaveLength(kind==='site'?1:0);
    expect(f.calls[0].receiver).toBe(receiver);expect(f.calls[0].args).toEqual([endpoint,init]);
    expect(f.calls[0].args[1]).toBe(init);
    const response=await settle(f,429);expect(await promise).toBe(response);
    expect(f.finish()).toBe('no_matching_fetch_observed');
    expect(f.window.fetch).toBe(f.siteFetch);expect(f.timerCount()).toBe(0);
    expect(f.window[f.key]).toBeUndefined();expect(f.privateReads()).toBe(0);
    expect(Object.getOwnPropertyDescriptor(f.window,'fetch')).toEqual(f.fetchDescriptorBefore);
  }
});
