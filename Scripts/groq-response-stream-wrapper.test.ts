import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

// These paths remain relative when this test is copied into the repository's Scripts.
const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq-owned-status.js', import.meta.url), 'utf8');
const factory = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq-response-stream-metadata.js', import.meta.url), 'utf8');
const endpoint = 'https://api.groq.com/openai/v1/chat/completions';
const purpose = 'groq_120b_fixture_response_stream_metadata_v1';
const tailPurpose = 'groq_120b_fixture_response_stream_tail_metadata_v2';
const prompt = 'Harmless synthetic exact wrapper marker e\u0301 🌍';
const encoder = new TextEncoder();
const event = (value: unknown) => 'data: ' + JSON.stringify(value) + '\n\n';
function deferred<T>() {
  let resolve!: (value:T)=>void;
  const promise = new Promise<T>(yes => { resolve = yes; }); return {promise, resolve};
}
type Options = {stream?:boolean;early?:boolean;setup?:boolean;purpose?:string;profile?:string;helper?:boolean;
  streamAccessor?:boolean;streamInherited?:boolean;purposeAccessor?:boolean;};
function fixture(options:Options = {}) {
  const profile = options.profile ?? 'gptoss120b';
  const selected = profile === 'qwen27b'
    ? {model:'qwen/qwen3.8-27b',label:'Qwen/Qwen3.8-27B',temperature:0.6,maximum:8192,topP:0.95}
    : {model:'openai/gpt-oss-120b',label:'GPT OSS 120B',temperature:1,maximum:16384,topP:1};
  const pending = deferred<any>(), probe = deferred<any>(), probes:any[] = [], calls:any[] = [];
  let clock = 0, cloneCalls = 0, headerReads = 0, bodyReads = 0, secretReads = 0, domReads = 0;
  const original = function(this:any, ...args:any[]) { calls.push({receiver:this,args}); return pending.promise; };
  const button:any = {isConnected:true,getClientRects:() => [{}],closest:() => null,querySelectorAll:() => [{}],
    getAttribute:(name:string) => ({'aria-controls':'picker','aria-expanded':'false','data-state':'closed'} as any)[name] ?? null,
    innerText:selected.label,textContent:selected.label};
  const document:any = {baseURI:'https://chat.groq.com/',querySelectorAll:(selector:string) => { domReads++; return selector.startsWith('button') ? [button] : []; }};
  const location = {origin:'https://chat.groq.com',href:'https://chat.groq.com/?model='+encodeURIComponent(selected.model)};
  const window:any = {fetch:original}; const backing = new WeakMap<object,Response>();
  class ResponseDouble {
    constructor(response:Response, public finalURL=endpoint, public redirect=false, public kind='cors') { backing.set(this,response); }
    get url() { return this.finalURL; } get redirected() { return this.redirect; }
    get type() { return this.kind; } get status() { return backing.get(this)!.status; }
    get headers() { headerReads++; return backing.get(this)!.headers; }
    get body() { bodyReads++; return backing.get(this)!.body; }
    clone() { cloneCalls++; return new ResponseDouble(backing.get(this)!.clone(),this.finalURL,this.redirect,this.kind); }
    text() { return backing.get(this)!.text(); }
  }
  const timers = new Map<number,{callback:()=>void,ms:number}>(); let nextTimer = 0;
  const setTimer = (callback:()=>void, ms:number) => { const id = ++nextTimer; timers.set(id,{callback,ms}); return id; };
  const clearTimer = (id:number) => { timers.delete(id); };
  const key = '__computaGroqStatus_'+'a'.repeat(32), secret = 'b'.repeat(32);
  const config:any = {key:'a'.repeat(32),secret,durationMs:390000,profile,earlyPassive:options.early ?? true,
    setupDiagnostics:options.setup ?? true,streamMetadata:options.stream ?? true,streamMetadataPurpose:options.purpose ?? purpose};
  let expression = JSON.stringify(config);
  if (options.streamAccessor) expression = 'Object.defineProperty('+expression+',"streamMetadata",{get(){onSecretRead();return true;}})';
  if (options.streamInherited) { delete config.streamMetadata; expression = 'Object.assign(Object.create({streamMetadata:true}),'+JSON.stringify(config)+')'; }
  if (options.purposeAccessor) expression = 'Object.defineProperty('+expression+',"streamMetadataPurpose",{get(){onSecretRead();return "'+purpose+'";}})';
  const marker = 'null /*__GROQ_RESPONSE_STREAM_FACTORY__*/';
  expect(source.split(marker)).toHaveLength(2);
  // Test-local observation of the actual helper's settled promise: no timing
  // ticks, synthetic parser result or replacement acceptance function.
  const injected = options.helper === false ? marker : '(() => {const f=('+factory+');return {...f,startMatchedGroqResponseStreamProbe(...args){const h=f.startMatchedGroqResponseStreamProbe(...args);onProbe(h);return h;}};})()';
  const program = source.replace(marker,injected).replace('__GROQ_OWNED_SYNTHETIC_CONFIG__',expression);
  const context = new Function('window','top','location','document','Response','performance','setTimeout','clearTimeout','getComputedStyle','onProbe','onSecretRead',
    program+'\n;return {replaceDocument(v){document=v;},replaceTop(v){top=v;}};')(
    window,window,location,document,ResponseDouble,{now:() => clock},setTimer,clearTimer,
    () => { domReads++; return {visibility:'visible'}; },(h:any) => { probes.push(h);probe.resolve(h); },() => { secretReads++; });
  const control = window[key];
  const ctl = (command:string,args:any={},credential=secret) => window[key]?.(credential,command,args);
  const savedCtl = (command:string,args:any={}) => control?.(secret,command,args);
  const arm = () => ctl('arm',{model:selected.model,label:selected.label,prompt});
  const body = (extra:any={}) => JSON.stringify({model:selected.model,messages:[{content:prompt,role:'user'}],
    temperature:selected.temperature,max_completion_tokens:selected.maximum,top_p:selected.topP,stream:true,...extra});
  return {window,original,calls,probe,probes,location,document,arm,body,ctl,savedCtl,key,ResponseDouble,
    resolve:(r:Response,url=endpoint,redirect=false,kind='cors') => { const value = new ResponseDouble(r,url,redirect,kind);pending.resolve(value);return value; },
    pending:pending.promise,tick:(value:number) => { clock=value; },replaceDocument:context.replaceDocument,replaceTop:context.replaceTop,
    counts:() => ({cloneCalls,headerReads,bodyReads,secretReads,domReads}),
    timers:() => [...timers.values()].map(t => t.ms),fire:(ms:number) => { for(const [id,t] of [...timers])if(t.ms===ms){timers.delete(id);t.callback();} }};
}
function packet(f:ReturnType<typeof fixture>) {
  const text = f.ctl('finish_metadata'); expect(typeof text).toBe('string');
  expect(encoder.encode(text).length).toBeLessThanOrEqual(2048);
  const outer = JSON.parse(text); expect(Object.keys(outer).sort()).toEqual(['responseStream','stage']);
  if (outer.responseStream !== null) {
    expect(typeof outer.responseStream).toBe('string'); expect(encoder.encode(outer.responseStream).length).toBeLessThanOrEqual(2048);
    const facts = JSON.parse(outer.responseStream); expect(Object.keys(facts)).toHaveLength(20); return {outer,facts,text};
  }
  return {outer,facts:null,text};
}

test('wrapper leaves old modes, false/inherited/accessor flags, foreign purpose/profile and missing helper unable to clone', async () => {
  for (const options of [{stream:false},{streamAccessor:true},{streamInherited:true},{purpose:'foreign'},
    {purposeAccessor:true},{profile:'qwen27b'},{early:false},{setup:false},{helper:false}]) {
    const f=fixture(options); const armed=f.arm();
    if (armed === true) {
      const returned=f.window.fetch(endpoint,{method:'POST',body:f.body()}); const response=f.resolve(new Response('PRIVATE_OLD_BODY'));
      expect(returned).toBe(f.pending); expect(await returned).toBe(response);
      expect(await response.text()).toBe('PRIVATE_OLD_BODY');
      expect(f.ctl('finish_metadata')).toBe(false); expect(f.ctl('finish')).toBe('http_2xx_opened');
    } else { expect([false,'js_profile_unavailable',undefined]).toContain(armed); f.ctl('dispose'); }
    expect(f.counts()).toMatchObject({cloneCalls:0,headerReads:0,bodyReads:0,secretReads:0});
    expect(f.probes).toHaveLength(0);
  }
});

test('one exact matched request preserves fetch Promise, receiver, arguments, Response and bytes with no per-chunk DOM scans', async () => {
  const f=fixture();expect(f.arm()).toBe(true);let requestPrivateReads=0;
  const init:any={method:'POST',body:f.body()};
  for(const key of ['headers','credentials'])Object.defineProperty(init,key,{get(){requestPrivateReads++;throw Error('PRIVATE_REQUEST');}});
  const receiver={fixture:true},returned=f.window.fetch.call(receiver,endpoint,init);
  expect(returned).toBe(f.pending);expect(f.calls).toHaveLength(1);expect(f.calls[0]).toEqual({receiver,args:[endpoint,init]});
  expect(f.calls[0].args[1]).toBe(init);
  let controller:any;
  const response=f.resolve(new Response(new ReadableStream({start(c){controller=c;}}),{headers:{'Content-Type':'text/event-stream'}}));
  expect(await returned).toBe(response);const h=await f.probe.promise;expect(h).not.toBeNull();
  const before=f.counts().domReads,original=response.text();
  const parts=[event({choices:[{delta:{reasoning:'PRIVATE_REASONING'}}]}),event({choices:[{delta:{content:'PRIVATE_CONTENT_🌍'}}]}),
    event({choices:[{delta:{tool_calls:[{function:{arguments:'PRIVATE_ARGS'}}]},finish_reason:'tool_calls'}]}),'data: [DONE]\n\n'];
  for(const part of parts)controller.enqueue(encoder.encode(part));controller.close();
  await h.settled;expect(await original).toBe(parts.join(''));expect(f.counts().domReads).toBe(before);
  const {outer,facts,text}=packet(f);expect(outer.stage).toBe('http_2xx_opened');
  expect(facts).toMatchObject({framing:'sse',content:true,reasoning:true,toolCalls:true,done:true,eof:true,outcome:'eof'});
  for(const value of ['PRIVATE_REASONING','PRIVATE_CONTENT','PRIVATE_ARGS','PRIVATE_REQUEST',prompt])expect(text).not.toContain(value);
  expect(requestPrivateReads).toBe(0);expect(f.counts()).toMatchObject({cloneCalls:1,headerReads:1,bodyReads:1,secretReads:0});
  expect(f.window.fetch).toBe(f.original);expect(f.window[f.key]).toBeUndefined();expect(f.ctl('finish_metadata')).toBeUndefined();
});

test('matched SSE and plain JSON errors produce only closed inner metadata while non2xx remains header-only', async () => {
  for(const framing of ['sse','json']) {
    const f=fixture();f.arm();const returned=f.window.fetch(endpoint,{method:'POST',body:f.body()});
    const error={error:{code:'rate_limit_exceeded',type:'tokens',message:'PRIVATE_ERROR_BODY'},x_groq:{error:'PRIVATE_UNKNOWN_CODE'}};
    const body=framing==='sse'?'event: error\n'+event(error):JSON.stringify(error);
    const response=f.resolve(new Response(body,{headers:{'Content-Type':framing==='sse'?'text/event-stream':'application/json'}}));
    expect(await returned).toBe(response);const h=await f.probe.promise;const original=response.text();await h.settled;
    expect(await original).toBe(body);const {outer,facts,text}=packet(f);expect(outer.stage).toBe('http_2xx_opened');
    expect(facts).toMatchObject({framing,topLevelError:true,apiErrorCode:'rate_limit_exceeded',apiErrorType:'tokens',xGroqError:'other',eof:true});
    expect(facts.eventError).toBe(framing==='sse');for(const s of ['PRIVATE_ERROR_BODY','PRIVATE_UNKNOWN_CODE'])expect(text).not.toContain(s);
  }
  for(const status of [400,401,403,413,429,503]) {
    const f=fixture();f.arm();const returned=f.window.fetch(endpoint,{method:'POST',body:f.body()});
    const response=f.resolve(new Response('PRIVATE_NON2XX_BODY',{status,headers:{'Content-Type':'application/json'}}));
    expect(await returned).toBe(response);expect(await response.text()).toBe('PRIVATE_NON2XX_BODY');
    const {outer,facts,text}=packet(f);expect(outer.stage).toBe(status===503?'http_other_non_2xx':'http_'+status);expect(facts).toBeNull();
    expect(f.counts()).toMatchObject({cloneCalls:0,headerReads:0,bodyReads:0});expect(f.probes).toHaveLength(0);expect(text).not.toContain('PRIVATE_NON2XX_BODY');
  }
});

test('unmatched request or unaccepted Response never clones and retains exact original results', async () => {
  for(const mode of ['wrongBody','duplicateKey','wrongURL','redirected','opaque','foreignURL']) {
    const f=fixture();f.arm();let body=f.body(),input=endpoint;
    if(mode==='wrongBody')body=f.body({temperature:0.25});if(mode==='duplicateKey')body=body.replace('{"model":','{"model":"foreign","model":');
    if(mode==='wrongURL')input+='?foreign=1';
    const returned=f.window.fetch(input,{method:'POST',body});
    const response=f.resolve(new Response('ORIGINAL'),mode==='foreignURL'?endpoint+'/foreign':endpoint,mode==='redirected',mode==='opaque'?'opaque':'cors');
    expect(await returned).toBe(response);expect(await response.text()).toBe('ORIGINAL');
    expect(packet(f).facts).toBeNull();expect(f.counts().cloneCalls).toBe(0);expect(f.calls).toHaveLength(1);
  }
});

test('expiry, document/top/route/controller loss, duplicate fetch and disposal revoke clone metadata without canceling original body', async () => {
  for(const mode of ['expiry','document','top','route','controller','duplicate','dispose']) {
    const f=fixture();f.arm();const cached=f.window.fetch;cached(endpoint,{method:'POST',body:f.body()});
    let controller:any;
    const response=f.resolve(new Response(new ReadableStream({start(c){controller=c;}}),{headers:{'Content-Type':'text/event-stream'}}));
    await f.pending;const h=await f.probe.promise;const original=response.text();let foreignReads=0;
    if(mode==='expiry')f.tick(390001);if(mode==='document')f.replaceDocument({});if(mode==='top')f.replaceTop({});
    if(mode==='route')f.location.href+='&foreign=1';
    if(mode==='controller')Object.defineProperty(f.window,f.key,{configurable:true,get(){foreignReads++;throw Error('PRIVATE_FOREIGN_CONTROLLER');}});
    if(mode==='duplicate')cached(endpoint,{method:'POST',body:f.body()});if(mode==='dispose')f.ctl('dispose');
    const result=mode==='dispose'?f.ctl('finish_metadata'):f.savedCtl('finish_metadata');
    if(mode==='dispose')expect(result).toBeUndefined();else expect(JSON.parse(result).responseStream).toBeNull();
    await h.settled;controller.enqueue(encoder.encode('PRIVATE_LATE_BODY'));controller.close();expect(await original).toBe('PRIVATE_LATE_BODY');
    expect(foreignReads).toBe(0);expect(f.calls).toHaveLength(mode==='duplicate'?2:1);
  }
});

test('expired or disposed ownership before a late Response callback cannot start a clone or publish metadata', async () => {
  for(const mode of ['expiry','document','dispose']) {
    const f=fixture();f.arm();const returned=f.window.fetch(endpoint,{method:'POST',body:f.body()});
    if(mode==='expiry')f.tick(390001);if(mode==='document')f.replaceDocument({});if(mode==='dispose')f.ctl('dispose');
    const response=f.resolve(new Response(event({error:{code:'rate_limit_exceeded'}}),{headers:{'Content-Type':'text/event-stream'}}));
    expect(await returned).toBe(response);await response.text();
    if(mode==='dispose')expect(f.ctl('finish_metadata')).toBeUndefined();else expect(JSON.parse(f.savedCtl('finish_metadata')).responseStream).toBeNull();
    expect(f.counts().cloneCalls).toBe(0);expect(f.probes).toHaveLength(0);expect(f.calls).toHaveLength(1);
  }
});


test('the exact v2 tail purpose passes the same matched request and Response through while observing beyond the v1 cutoff', async () => {
  const f=fixture({purpose:tailPurpose});expect(f.arm()).toBe(true);let privateReads=0;
  Object.defineProperty(f.window,'navigator',{get(){privateReads++;throw Error('PRIVATE_CLIPBOARD_ACCESS');}});
  const receiver={tail:true},init={method:'POST',body:f.body()},returned=f.window.fetch.call(receiver,endpoint,init);
  expect(returned).toBe(f.pending);expect(f.calls).toEqual([{receiver,args:[endpoint,init]}]);expect(f.calls[0].args[1]).toBe(init);
  let controller:any;
  const response=f.resolve(new Response(new ReadableStream({start(c){controller=c;}}),{headers:{'Content-Type':'text/event-stream'}}));
  expect(await returned).toBe(response);const h=await f.probe.promise;expect(h).not.toBeNull();
  expect(f.timers()).toContain(90000);expect(f.timers()).not.toContain(60000);
  const before=f.counts().domReads,original=response.text();
  const hidden=['PRIVATE_WRAPPER_TAIL_REASONING','PRIVATE_WRAPPER_TAIL_CONTENT'];
  const raw=event({choices:[{delta:{reasoning:hidden[0]+'x'.repeat(800)}}]}).repeat(400)
    +event({choices:[{delta:{content:hidden[1]},finish_reason:'length'}]})+'data: [DONE]\n\n';
  const bytes=encoder.encode(raw);expect(bytes.length).toBeGreaterThan(262144);
  for(let at=0;at<bytes.length;at+=4096)controller.enqueue(bytes.subarray(at,at+4096));controller.close();
  await h.settled;expect(await original).toBe(raw);expect(f.counts().domReads).toBe(before);
  const {outer,facts,text}=packet(f);expect(outer.stage).toBe('http_2xx_opened');
  expect(facts).toMatchObject({version:2,framing:'sse',bytes:bytes.length,events:402,jsonEvents:401,reasoning:true,content:true,
    finishReason:'length',done:true,eof:true,outcome:'eof'});
  for(const value of [...hidden,prompt,'PRIVATE_CLIPBOARD_ACCESS'])expect(text).not.toContain(value);
  expect(privateReads).toBe(0);expect(f.calls).toHaveLength(1);expect(f.probes).toHaveLength(1);
  expect(f.counts()).toMatchObject({cloneCalls:1,headerReads:1,bodyReads:1,secretReads:0});
  expect(f.window.fetch).toBe(f.original);expect(f.window[f.key]).toBeUndefined();
});

test('v2 cannot broaden purpose, native flag, profile or ownership and a stopped clone never consumes the original branch', async () => {
  for(const options of [{purpose:tailPurpose,stream:false},{purpose:tailPurpose,streamAccessor:true},{purpose:tailPurpose,streamInherited:true},
    {purpose:tailPurpose,purposeAccessor:true},{purpose:tailPurpose,profile:'qwen27b'},{purpose:tailPurpose,profile:'gptoss20b'},
    {purpose:tailPurpose,early:false},{purpose:tailPurpose,setup:false},{purpose:tailPurpose,helper:false},{purpose:tailPurpose+'/foreign'}]) {
    const f=fixture(options),armed=f.arm();
    if(armed===true){const returned=f.window.fetch(endpoint,{method:'POST',body:f.body()});const response=f.resolve(new Response('PRIVATE_CROSS_SCOPE'));
      expect(returned).toBe(f.pending);expect(await returned).toBe(response);expect(await response.text()).toBe('PRIVATE_CROSS_SCOPE');
      expect(f.ctl('finish_metadata')).toBe(false);f.ctl('dispose');
    }else{expect([false,'js_profile_unavailable',undefined]).toContain(armed);f.ctl('dispose');}
    expect(f.probes).toHaveLength(0);expect(f.counts()).toMatchObject({cloneCalls:0,headerReads:0,bodyReads:0,secretReads:0});
  }
  for(const mode of ['deadline','expiry','document','top','route','controller','duplicate','dispose','lateResponse']) {
    const f=fixture({purpose:tailPurpose});expect(f.arm()).toBe(true);const cached=f.window.fetch;
    const returned=cached(endpoint,{method:'POST',body:f.body()});let controller:any;
    if(mode==='lateResponse')f.tick(390001);
    const response=f.resolve(new Response(new ReadableStream({start(c){controller=c;}}),{headers:{'Content-Type':'text/event-stream'}}));
    expect(await returned).toBe(response);
    if(mode==='lateResponse'){
      controller.enqueue(encoder.encode('PRIVATE_LATE_RESPONSE'));controller.close();expect(await response.text()).toBe('PRIVATE_LATE_RESPONSE');
      expect(JSON.parse(f.savedCtl('finish_metadata')).responseStream).toBeNull();expect(f.counts().cloneCalls).toBe(0);expect(f.probes).toHaveLength(0);continue;
    }
    const h=await f.probe.promise,original=response.text();let foreignReads=0;
    if(mode==='deadline')f.tick(90001);if(mode==='expiry')f.tick(390001);if(mode==='document')f.replaceDocument({});if(mode==='top')f.replaceTop({});
    if(mode==='route')f.location.href+='&foreign=1';
    if(mode==='controller')Object.defineProperty(f.window,f.key,{configurable:true,get(){foreignReads++;throw Error('PRIVATE_FOREIGN_TAIL_CONTROLLER');}});
    if(mode==='duplicate')cached(endpoint,{method:'POST',body:f.body()});if(mode==='dispose')f.ctl('dispose');
    const result=mode==='dispose'?f.ctl('finish_metadata'):f.savedCtl('finish_metadata');
    if(mode==='dispose')expect(result).toBeUndefined();
    else if(mode==='deadline')expect(JSON.parse(JSON.parse(result).responseStream)).toMatchObject({version:2,outcome:'deadline',eof:false,done:false});
    else expect(JSON.parse(result).responseStream).toBeNull();
    await h.settled;controller.enqueue(encoder.encode('PRIVATE_ORIGINAL_AFTER_TAIL_STOP'));controller.close();
    expect(await original).toBe('PRIVATE_ORIGINAL_AFTER_TAIL_STOP');expect(foreignReads).toBe(0);
    expect(f.calls).toHaveLength(mode==='duplicate'?2:1);expect(f.counts().cloneCalls).toBe(1);
  }
  const f=fixture({purpose:tailPurpose});f.arm();const returned=f.window.fetch(endpoint,{method:'POST',body:f.body()});
  const response=f.resolve(new Response('PRIVATE_V2_HTTP_ERROR',{status:429,headers:{'Content-Type':'application/json'}}));
  expect(await returned).toBe(response);expect(await response.text()).toBe('PRIVATE_V2_HTTP_ERROR');
  const {outer,facts,text}=packet(f);expect(outer.stage).toBe('http_429');expect(facts).toBeNull();expect(text).not.toContain('PRIVATE_V2_HTTP_ERROR');
  expect(f.counts()).toMatchObject({cloneCalls:0,headerReads:0,bodyReads:0});
});
