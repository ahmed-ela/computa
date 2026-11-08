(()=>{
'use strict';
// Research fixture. Consume only a reader already owned by the site. Nothing sends, cancels or reads ahead.
function selectiveAnswer(expected) {
  const decoder = new TextDecoder('utf-8', {fatal:true});
  const FRAME = 32*1024, REQUEST = 1024*1024, ANSWER = expected.catalogMarkerOnly === true ? 8*1024 : 128*1024;
  const buf = new Uint8Array(FRAME);
  let n=0, bytes=0, events=0, created=null, state='new', done=false, fault=null;
  let chunks=[], outputBytes=0, explicitFinish=false, eof=false, reportedModel=false;
  const reject = code => { throw Error(code); };
  const uuid = s=> typeof s==='string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(s);
  function reset(code) { if (!fault) fault=code; chunks=[]; buf.fill(0); n=0; }
  // Parse only strict JSON shape metadata as byte ranges. No whole-event UTF-8 decode or JSON.parse.
  // String payloads are not touched by a text decoder until their enclosing branch is established.
  function tree(a) {
    let i=0,nodes=0;
    const ws=()=>{while([32,10,13,9].includes(a[i])) i++};
    function value(depth) {
      ws(); if (depth>12 || ++nodes>220 || i>=a.length) reject('json_limit');
      const start=i, b=a[i++];
      if(b===34) {
        for(;i<a.length;i++) {
          if(a[i]===34){i++;return {t:'str',start,end:i}}
          if(a[i]<32) reject('invalid_json');
          if(a[i]>=128){ // Verify UTF-8 without decoding any non-answer string values.
            const b=a[i],count=b>=194&&b<=223?1:b>=224&&b<=239?2:b>=240&&b<=244?3:0;
            if(!count)reject('invalid_utf8');
            for(let j=0;j<count;j++){const c=a[++i];if(!(c>=128&&c<=191) ||
              (j===0 && (b===224&&c<160||b===237&&c>=160||b===240&&c<144||b===244&&c>143)))
              reject('invalid_utf8')}
            continue;
          }
          if(a[i]===92){i++;if(![34,47,92,98,102,110,114,116,117].includes(a[i]))reject('invalid_json');
            if(a[i]===117)for(let k=0;k<4;k++){const h=a[++i];if(!(h>=48&&h<=57 || h>=65&&h<=70 || h>=97&&h<=102))reject('invalid_json')}}
        }reject('invalid_json');
      }
      if(b===123||b===91) {
        const obj=b===123, end=obj?125:93, v=obj?Object.create(null):[];
        ws();if(a[i]===end){i++;return {t:obj?'obj':'array',v}}
        for(;;) {
          let key;
          if(obj){const k=value(depth+1);if(k.t!=='str'||k.end-k.start>64)reject('key');
            // Literal ASCII keys only. Escaped aliases / non-ASCII keys do not fall through.
            key=''; for(let j=k.start+1;j<k.end-1;j++){const c=a[j];if(c<33||c>126||c===92)reject('key');key+=String.fromCharCode(c)}
            if(Object.hasOwn(v,key))reject('duplicate_key');ws();if(a[i++]!==58)reject('invalid_json')}
          const item=value(depth+1);if(obj)v[key]=item;else v.push(item);
          ws();const c=a[i++];if(c===end)break;if(c!==44)reject('invalid_json');
        }return {t:obj?'obj':'array',v};
      }
      // Only ASCII number/null/boolean may occur here, never a payload string.
      while(i<a.length && ![44,93,125,32,9,13,10].includes(a[i]))i++;
      if(i-start>24)reject('scalar');
      const atom=String.fromCharCode(...a.subarray(start,i));
      if(!/^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)$/.test(atom))reject('invalid_json');
      return {t:'atom',v:atom};
    }
    const root=value(0);ws();if(i!==a.length)reject('invalid_json');return root;
  }
  function process(a) {
    if(++events>2048)reject('event_limit');
    const ascii=s=>s.length===a.length&&Array.from(s,(c,i)=>a[i]===c.charCodeAt(0)).every(Boolean);
    if(done)reject('after_done');
    if(ascii('[DONE]')){if(!explicitFinish)reject('early_terminal');done=true;return;}
    const packet=tree(a);
    function obj(x,allowed) {
      if(x?.t!=='obj'||Object.keys(x.v).some(k=>!allowed.includes(k)))reject('shape');
      return x.v;
    }
    // Metadata uses exact ASCII spelling. Never run arbitrary strings through decoder or logs.
    function word(x,limit=64) {
      if(x?.t!=='str'||x.end-x.start>limit+2)reject('metadata');
      let s='';for(let i=x.start+1;i<x.end-1;i++){if(a[i]<32||a[i]>126||a[i]===92)reject('metadata');s+=String.fromCharCode(a[i])}return s;
    }
    if(Object.hasOwn(packet.v||{},'response.created')){
      if(created)reject('second_created');
      const event=obj(packet,['response.created']);
      const c=obj(event['response.created'],['chat_id','parent_id','response_id','response_index']);
      const chat=word(c.chat_id), user=word(c.parent_id), response=word(c.response_id);
      if(chat!==expected.chat || ![chat,user,response].every(uuid) || new Set([chat,user,response]).size!==3 ||
         (c.response_index && !(c.response_index.t==='atom'&&c.response_index.v==='0')))reject('ids');
      created={chat,user,response};return;
    }
    if(!created)reject('missing_created');
    if(Object.hasOwn(packet.v||{},'done')){
      const e=obj(packet,['done','response_id']);
      if(!explicitFinish || e.done.t!=='atom'||e.done.v!=='true'||word(e.response_id)!==created.response)reject('early_terminal');
      done=true;return;
    }
    if(Object.hasOwn(packet.v||{},'selected_model_id')){
      const e=obj(packet,['selected_model_id','response_id']);
      if(word(e.response_id)!==created.response||word(e.selected_model_id)!==expected.wireModel
         || expected.catalogMarkerOnly===true && (reportedModel||explicitFinish))reject('model');
      reportedModel=true;return;
    }
    const event=obj(packet,['choices','response_id','timestamp']);
    if(word(event.response_id)!==created.response)reject('ids');
    if(event.choices?.t!=='array'||event.choices.v.length!==1)reject('choice');
    const choice=obj(event.choices.v[0],['delta','index']);
    if(choice.index && !(choice.index.t==='atom'&&choice.index.v==='0'))reject('choice');
    const delta=obj(choice.delta,['phase','role','status','content']);
    if(word(delta.role)!=='assistant')reject('role');
    const phase=word(delta.phase),status=word(delta.status);
    if(!['typing','finished'].includes(status)||delta.content?.t!=='str')reject('delta');
    if(phase==='DeepThinking'){
      if(state==='answer'||explicitFinish)reject('more_phases');
      state='nonanswer';return; // Neither decode nor materialize hidden content, even if serialized first.
    }
    if(phase!=='answer'||explicitFinish)reject('more_phases');
    state='answer';
    const size=delta.content.end-delta.content.start;
    if((outputBytes+=size)>ANSWER)reject('answer_limit');
    const text=JSON.parse(decoder.decode(a.subarray(delta.content.start,delta.content.end)));
    if(!text.isWellFormed())reject('invalid_unicode');
    chunks.push(text);explicitFinish=status==='finished';
  }
  // Bounded single-data-line SSE profile, LF or CRLF. Unknown fields, incomplete tails, reconnects refuse.
  let hasData=false;
  function feedLine() {
    if(n && buf[n-1]===13)n--;
    if(!n){hasData=false;return;}
    if(hasData||n<6||buf[0]!==100||buf[1]!==97||buf[2]!==116||buf[3]!==97||buf[4]!==58)reject('sse');
    const off=buf[5]===32?6:5;process(buf.subarray(off,n));hasData=true;buf.fill(0,0,n);n=0;
  }
  return {
    feed(part) {if(fault)return;try{if(!(part instanceof Uint8Array) ||(bytes+=part.length)>REQUEST)reject('byte_limit');
      for(const b of part){if(b===10)feedLine();else{if(n===FRAME)reject('frame_limit');buf[n++]=b}}}catch(e){reset(e.message)}},
    end(){eof=true;if(n||hasData||!done||!explicitFinish||!chunks.length)reset('incomplete')},
    fail(code){reset(code)},
    claim(p){if(fault)return {error:fault};
      if(!eof||!created||!p||p.chat!==created.chat||p.user!==created.user||p.response!==created.response||
         p.turn!==expected.turn||p.generation!==expected.generation||p.wireModel!==expected.wireModel||
         p.visibleModel!==expected.visibleModel||p.exactFirstBody!==true||p.completionControls!==true||p.singleOwnedAssistant!==true||
         p.visibleAnswerPhases!==1||p.documentCurrent!==true||p.submissionVerified!==true||p.promptBound!==true)
        return {error:'native_proof'};
      if(expected.catalogMarkerOnly===true && !reportedModel){reset('spent');return {error:'response_model_unobserved'}}
      const text=chunks.join('');reset('spent');return text?{text}:{error:'empty'};
    }
  };
}

// Match the public sender's compact JSON.stringify DTO without decoding unknown values or message bodies.
// The existing wire string is owned by the site. The matcher copies only the preauthorized prompt spelling.
function matchesOwnedRequest(source, held, chat) {
  const literal=JSON.stringify(held.prompt), model=JSON.stringify(held.wireModel), chatID=JSON.stringify(chat);
  const expectedRoot={stream:'true',incremental_output:'true',version:'"2.1"',chat_mode:'"normal"',model,
    chatId:chatID,chat_id:chatID,parent_id:'null',parentId:'""'};
  const expectedUser={role:'"user"',content:literal,user_action:'"chat"',files:'[]',models:'['+model+']'};
  const number=/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/y;
  let i=0,nodes=0;
  const bad=()=>{throw Error('request')};
  function take(literal){if(!source.startsWith(literal,i))bad();i+=literal.length}
  function key(){
    if(source[i++]!=='"')bad();
    const start=i;
    while(i<source.length && source[i]!=='"'){
      const c=source.charCodeAt(i++);if(c<33||c>126||c===92||i-start>96)bad()
    }
    if(i===start||source[i++]!=='"')bad();return source.slice(start,i-1)
  }
  function skipString(){
    if(source[i++]!=='"')bad();
    while(i<source.length){
      const c=source.charCodeAt(i++);if(c===34)return;if(c<32)bad();
      if(c===92){
        const e=source[i++];if(e==='u'){for(let j=0;j<4;j++){
          const h=source.charCodeAt(i++);if(!(h>=48&&h<=57||h>=65&&h<=70||h>=97&&h<=102))bad()}}
        else if(!['"','\\','/','b','f','n','r','t'].includes(e))bad()
      }
    }bad()
  }
  function uuidValue(){
    if(source[i++]!=='"')bad();
    for(let j=0;j<36;j++){
      const c=source.charCodeAt(i++),dash=j===8||j===13||j===18||j===23;
      if(dash?c!==45:!(c>=48&&c<=57||c>=97&&c<=102))bad()
    }
    if(source[i++]!=='"')bad()
  }
  function value(kind,depth){
    if(depth>12||++nodes>4096||i>=source.length)bad();
    if(kind==='messages'){
      take('[');value('user',depth+1);take(']');return // No history or second message scanned or parsed.
    }
    const c=source[i];
    if(c==='{'){
      i++;const names=new Set();
      const expected=kind==='root'?expectedRoot:kind==='user'?expectedUser:null;
      if(source[i]!=='}')for(;;){
        const name=key();if(names.has(name)||names.size>=128)bad();names.add(name);take(':');
        if(expected&&Object.hasOwn(expected,name))take(expected[name]);
        else if(kind==='root'&&name==='messages')value('messages',depth+1);
        else if(kind==='user'&&name==='id')uuidValue();
        else value('skip',depth+1);
        if(source[i]=== '}')break;take(',')
      }
      take('}');
      if(expected && (!Object.keys(expected).every(k=>names.has(k))||!names.has(kind==='root'?'messages':'id')))bad();
      return
    }
    if(kind!=='skip')bad();
    if(c==='['){i++;if(source[i]!==']')for(;;){value('skip',depth+1);if(source[i]===']')break;take(',')}take(']');return}
    if(c==='"'){skipString();return}
    if(c==='t'){take('true');return}if(c==='f'){take('false');return}if(c==='n'){take('null');return}
    number.lastIndex=i;if(!number.test(source)||number.lastIndex-i>32)bad();i=number.lastIndex
  }
  value('root',0);return i===source.length
}

// Observe only the selected completion's existing reader. Never start a read or send another request.
function observeOwnedCompletion(config) {
  let held=null, sink=null, seen=false, observedReader=false, current=true, fault=null;
  const base=window.fetch;
  let deadline=0,timer=0;
  const installed=[];
  function tap(object,key,observed){
    const before=Object.getOwnPropertyDescriptor(object,key);
    Object.defineProperty(object,key,{configurable:true,value:observed});
    installed.push(()=>{
      if(Object.getOwnPropertyDescriptor(object,key)?.value!==observed)return;
      if(before)Object.defineProperty(object,key,before);else delete object[key];
    });
  }
  const fail=why=>{fault ||= why;sink?.fail(why)};
  const endpoint='/api/v2/chat/completions', uuid=/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
  function fetchTap(input,init) {
    const result=Reflect.apply(base,this,arguments);
    if(!held||!current||location.origin!==config.origin||typeof input!=='string')return result;
    if(performance.now()>=deadline){finish();return result}
    let u;
    try{u=new URL(input,location.href)}catch{return result}
    if(u.origin!==config.origin||u.pathname!==endpoint)return result; // never inspect unrelated headers/body.
    try {
      if(seen){fail('second_request');return result}
      seen=true;
      if(u.username||u.password||u.hash||!/^\?chat_id=[a-f0-9-]+$/.test(u.search)||
         !uuid.test(u.searchParams.get('chat_id'))||!init)throw Error('request');
      const plain = o => o && [null,Object.prototype].includes(Object.getPrototypeOf(o));
      const own = (o,k) => Object.getOwnPropertyDescriptor(o,k)?.value;
      const method = plain(init) && own(init,'method');
      if(typeof method!=='string' || !/^[Pp][Oo][Ss][Tt]$/.test(method))throw Error('request');
      const body=own(init,'body'), headers=own(init,'headers');
      if(typeof body!=='string'||body.length>180200||!plain(headers))throw Error('request');
      const hdr=k=>own(headers,k);
      if(hdr('Version')!=='0.3.32'||!uuid.test(hdr('X-Request-Id')))throw Error('request_id');
      const chat = u.searchParams.get('chat_id');
      if(!matchesOwnedRequest(body,held,chat))throw Error('request');
      sink=selectiveAnswer({...held,chat});
      result.then(res=>{
        try{
          if(!current||fault) return;
          if(res.status!==200||res.redirected||res.url!==u.href||res.headers.get('content-type')?.split(';')[0]!=='text/event-stream'||!res.body)throw Error('http');
          const stream=res.body, origGet=stream.getReader;
          tap(stream,'getReader',function(){
            const reader=Reflect.apply(origGet,this,arguments);
            if(this!==stream||arguments.length||observedReader){fail('reader');return reader}
            observedReader=true;
            const origRead=reader.read;
            try{tap(reader,'read',function(){
              const result=Reflect.apply(origRead,this,arguments);
              if(this!==reader||arguments.length){fail('reader');return result}
              result.then(({done,value})=>{if(!current||fault)return;if(performance.now()>=deadline){finish();return}try{if(done)sink.end();else sink.feed(value)}catch{fail('reader')}},()=>fail('interrupted'));
              return result;
            })}catch{fail('reader')}
            return reader;
          });
        }catch{fail('http_or_reader')}
      },()=>fail('fetch_rejected'));
    }catch(e){fail(['request_id','request'].includes(e.message)?e.message:'request')}
    return result;
  }
  window.fetch=fetchTap;
  const finish=()=>{clearTimeout(timer);current=false;held=null;sink?.fail('retired');sink=null;while(installed.length)installed.pop()();if(window.fetch===fetchTap)window.fetch=base;};
  return {
    arm(p){if(held||seen||!current||location.origin!==config.origin)return false;
      const ms=p.durationMs;if(!Number.isInteger(ms)||ms<1||ms>60000)return false;
      held=p;deadline=performance.now()+ms;timer=setTimeout(finish,ms);return true},
    claim(p){if(!current||performance.now()>=deadline){finish();return {error:'retired'}};const result=fault?{error:fault}:sink?.claim(p)??{error:'no_owned_reader'};finish();return result},
    dispose(){fail('disposed');finish()}
  };
}

// Diagnostic only, paired with a native synthetic-only lease. No endpoint is called by this code.
function matchCatalogTuple(source, label) {
  if(typeof source!=='string'||!source.length||source.length>262144)throw Error('catalog_size');
  const names=new Set(), ids=new Set();
  let index=0,nodes=0,rows=0,pair=null,sawData=false;
  const bad=()=>{throw Error('catalog_shape')};
  function space(){while(index<source.length && [32,9,10,13].includes(source.charCodeAt(index)))index++}
  function quoted(read,limit) {
    const start=index++;
    if(source[start]!=='"')bad();
    while(index<source.length){
      const ch=source.charCodeAt(index++);
      if(ch===34){
        if(!read)return null;
        if(index-start>limit*6+2)bad();const t=JSON.parse(source.slice(start,index));if(t.length>limit)bad();return t;
      }
      if(ch<32)bad();
      if(ch===92){const e=source[index++];if(e==='u'){for(let i=0;i<4;i++){const c=source[index++];if(typeof c!=='string'||!/[0-9a-f]/i.test(c))bad()}}
        else if(!['"','\\','/','b','f','n','r','t'].includes(e))bad()}
    }bad()
  }
  function visit(kind,depth) {
    if(++nodes>16000||depth>16)bad();space();const c=source[index];
    if(kind==='root'&&c!=='{'||kind==='rows'&&c!=='['||kind==='row'&&c!=='{')bad();
    if(c==='{') {
      index++;space();const keys=new Set();let id,name;
      if(source[index]!=='}')for(;;){
        const k=quoted(true,128);if(keys.has(k))bad();keys.add(k);space();if(source[index++]!==':')bad();space();
        if(kind==='root' && k==='data'){sawData=true;visit('rows',depth+1)}
        else if(kind==='root' && ['code','error','message','details','detail'].includes(k))bad();
        else if(kind==='row' && k==='name')name=quoted(true,128);
        else if(kind==='row' && k==='id')id=quoted(true,128);
        else visit('skip',depth+1);
        space();if(source[index]=== '}')break;if(source[index++]!==',')bad();space()
      }
      if(source[index++]!=='}')bad();
      if(kind==='row'){
        if(!name||!id||names.has(name)||ids.has(id))throw Error('catalog_ambiguous');
        names.add(name);ids.add(id);if(name===label){
          if(!/^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,95}$/.test(id))bad();pair={name,id}
        }
      }
    }else if(c==='['){
      index++;space();if(source[index]!==']')for(;;){
        if(kind==='rows'&&++rows>128)bad();
        visit(kind==='rows'?'row':'skip',depth+1);space();if(source[index]===']')break;if(source[index++]!==',')bad();space()
      }
      if(source[index++]!==']')bad()
    }else if(c==='"'){quoted(false,0)}
    else{const start=index;while(index<source.length&&!/[\s,}\]]/.test(source[index]))index++;
      if(index===start||index-start>64||!/^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)$/.test(source.slice(start,index)))bad()}
  }
  visit('root',0);space();if(index!==source.length||!sawData||!rows||!pair)throw Error('catalog_missing');
  return pair.id; // Never return provider descriptions, account entries or unrelated tuples.
}

function observeSiteCatalog(config) {
  const native=XMLHttpRequest.prototype, openDescriptor=Object.getOwnPropertyDescriptor(native,'open'), original=openDescriptor.value;
  const method=n=>Object.getOwnPropertyDescriptor(native,n)?.value;
  const getter=n=>Object.getOwnPropertyDescriptor(native,n)?.get;
  const xhrGet=Object.fromEntries(['responseURL','responseText','status','readyState','responseType'].map(k=>[k,getter(k)]));
  const getHeader=method('getResponseHeader'),sendOriginal=method('send'),add=EventTarget.prototype.addEventListener;
  const entries=performance.getEntriesByName.bind(performance);
  let opened=null, sendWrapper=null;
  const url=config.origin+'/api/v2/models/';
  let held=null,wire=null,error=null,retired=false,submitted=false,received=false;
  function refuse(why){wire=null;error??=why}
  function scoped(){return !retired && Date.now()<config.expiresAt && location.origin===config.origin && window===window.top}
  function valid(){return scoped()&&!error && native.open===wrapped && native.send===sendOriginal}
  const catalogErrors=new Set(['catalog_accessor','catalog_mime','catalog_ambiguous','catalog_missing','catalog_size',
    'catalog_binding','catalog_binding_scope','catalog_open_changed','catalog_send_changed','catalog_held_changed','catalog_send_unobserved','catalog_not_done','catalog_final_url','catalog_non_200','catalog_response_type']);
  function checkHeldResponse(req) {
    const read = key => {
      if(Object.hasOwn(req,key) || typeof xhrGet[key]!=='function')throw Error('catalog_accessor');
      return Reflect.apply(xhrGet[key],req,[]);
    };
    // The first failed check is diagnostic only. Never read responseText from a failed XHR.
    // Preserve the original validity/held checks and their short-circuit order.
    // These fixed reasons discriminate refusal only; none permits a body read.
    if(!scoped() || error)throw Error('catalog_binding_scope');
    if(native.open!==wrapped)throw Error('catalog_open_changed');
    if(native.send!==sendOriginal)throw Error('catalog_send_changed');
    if(req!==held)throw Error('catalog_held_changed');
    if(!submitted)throw Error('catalog_send_unobserved');
    if(read('readyState')!==4)throw Error('catalog_not_done');
    if(read('responseURL')!==url)throw Error('catalog_final_url');
    if(read('status')!==200)throw Error('catalog_non_200');
    if(!['','text'].includes(read('responseType')))throw Error('catalog_response_type');
    if(Reflect.apply(getHeader,req,['content-type'])?.split(';')[0]?.toLowerCase()!=='application/json')throw Error('catalog_mime');
  }
  function wrapped(verb,path,async,...rest) {
    if(this===held)refuse('catalog_reused'); // The old document must not follow an XHR reused for a different request.
    const result=Reflect.apply(original,this,arguments);
    if(!scoped())return result;
    let matching=false;
    try{
      if(typeof path!=='string')return result;
      const requested=new URL(path,location.href);
      if(requested.origin!==config.origin || requested.pathname!=='/api/v2/models/')return result;
      matching=true;
      if(this===held||held!==null||typeof verb!=='string'||verb!=='GET'||requested.href!==url||async!==true||rest.length)throw Error('catalog_request');
      if(Object.hasOwn(this,'send'))throw Error('catalog_accessor');
      held=this;opened=performance.now();
      const req=this;
      sendWrapper=function(body){
        if(this!==req||submitted||body!=null)refuse('catalog_request');submitted=true;
        return Reflect.apply(sendOriginal,this,arguments);
      };
      Object.defineProperty(req,'send',{...Object.getOwnPropertyDescriptor(native,'send'),value:sendWrapper});
      Reflect.apply(add,req,['loadend',()=>{
        if(!scoped()||error)return;
        try{
          checkHeldResponse(req);
          // Defer materialization until native verified the picker and resource timing proves the decoded size.
          received=true;
        }catch(e){refuse(catalogErrors.has(e.message)?e.message:'catalog_shape')}
      },{once:true}]);
    }catch{if(matching)refuse('catalog_request')}
    return result;
  }
  Object.defineProperty(native,'open',{...openDescriptor,value:wrapped});
  function directPath(){
    if(!valid()||!received)return false;
    const all=entries(url,'resource');
    if(all.length!==1)return false;
    const x=all[0];
    // A zero redirect clock alone is insufficient: opaque timing can zero every protected field.
    // Require visible final-request timing, no worker, no redirects and this original XHR interval.
    return x.initiatorType==='xmlhttprequest'&&x.name===url&&x.startTime>=opened&&x.requestStart>0&&
      x.responseStart>=x.requestStart&&x.responseEnd>=x.responseStart&&x.redirectStart===0&&x.redirectEnd===0&&x.workerStart===0&&
      Number.isSafeInteger(x.decodedBodySize)&&x.decodedBodySize>0&&x.decodedBodySize<=262144;
  }
  function pair(){
    if(!directPath())return null;
    try {
      checkHeldResponse(held);
      if(wire)return wire;
      if(Object.hasOwn(held,'responseText'))throw Error('catalog_accessor');
      wire=matchCatalogTuple(Reflect.apply(xhrGet.responseText,held,[]),config.visibleModel);
    } catch(e) {
      refuse(catalogErrors.has(e.message)?e.message:'catalog_shape');
    }
    return wire;
  }
  return {pair,status(){return !scoped()?'retired':error||(!held?'catalog_not_seen':!received?'catalog_pending':'catalog_path_unverified')},

    retire(){retired=true;wire=null;if(held && Object.getOwnPropertyDescriptor(held,'send')?.value===sendWrapper)delete held.send;held=null;sendWrapper=null;if(native.open===wrapped)Object.defineProperty(native,'open',openDescriptor)}};
}

// Page-local surface: auth secret / random property per fresh native-owned view; no raw reply returned.
function installCatalogShadow(cfg) {
  if(location.origin!==cfg.origin || window!==window.top || location.href!==cfg.origin+'/' || Date.now()>=cfg.expiresAt ||
     !['Qwen3.7-Plus','Qwen3.8-Max'].includes(cfg.visibleModel))return;
  const allowedFailureStages=new Set(["after_done","answer_limit","byte_limit","catalog_accessor","catalog_ambiguous","catalog_mime","catalog_missing","catalog_not_seen","catalog_path_unverified","catalog_pending","catalog_request","catalog_response","catalog_reused","catalog_shape","catalog_size","choice","delta","duplicate_key","early_terminal","empty","event_limit","fetch_rejected","frame_limit","http","http_or_reader","ids","incomplete","interrupted","invalid_json","invalid_unicode","invalid_utf8","json_limit","key","marker_mismatch","metadata","missing_created","model","more_phases","native_proof","no_owned_reader","ownership","reader","repeated_arm","request","request_id","response_model_unobserved","retired","role","scalar","scope","second_created","second_request","selection","shape","sse","stream_unavailable","unrecognized","wrong_capability"]);
  const doc=document, catalog=observeSiteCatalog(cfg), stream=observeOwnedCompletion({origin:cfg.origin});
  let retired=false,armed=false,wire=null,turn=null,generation=null;
  const uuid=s=>typeof s==='string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(s);
  const dispose=()=>{retired=true;clearTimeout(timer);catalog.retire();stream.dispose();wire=null;turn=null;generation=null;if(window[cfg.key]===registered)delete window[cfg.key];window.removeEventListener("pagehide",dispose)};
  const timer=setTimeout(dispose,Math.max(0,cfg.expiresAt-Date.now()));
  const registered=Object.freeze(function(secret,command,p){
    if(secret!==cfg.secret)return {stage:'wrong_capability'};
    if(retired||document!==doc||Date.now()>=cfg.expiresAt){dispose();return {stage:'retired'}}
    if(command==='retire'){dispose();return {stage:'retired'}}
    if(!p||!uuid(p.generation)||!uuid(p.turn)||p.visibleModel!==cfg.visibleModel || (armed && (p.turn!==turn||p.generation!==generation))){dispose();return {stage:'ownership'}}
    if(command!=='prepare' && command!=='finish'){dispose();return {stage:'scope'}}
    if(command==='prepare' && (armed||p.pickerVerified!==true||typeof p.prompt!=='string'||!p.prompt.length||p.prompt.length>180000)){
      const reason=armed?'repeated_arm':'selection';dispose();return {stage:reason}
    }
    if(command==='finish' && (!armed||typeof p.expectedWireText!=='string'||!p.expectedWireText.length||p.expectedWireText.length>8192)){
      dispose();return {stage:'scope'}
    }
    const pair=catalog.pair();
    if(command==='prepare'){
      if(!pair){const reason=catalog.status();dispose();return {stage:reason}}
      wire=pair;turn=p.turn;generation=p.generation;
      armed=stream.arm({turn,generation,visibleModel:cfg.visibleModel,wireModel:wire,prompt:p.prompt,catalogMarkerOnly:true,
        durationMs:Math.max(1,Math.min(60000,Math.floor(cfg.expiresAt-Date.now())))});
      return {stage:armed?'ready':'stream_unavailable'};
    }
    if(command!=='finish'||!armed||!pair||pair!==wire){const reason=!pair?catalog.status():'scope';dispose();return {stage:reason}}
    const r=stream.claim({...p,wireModel:wire});
    // Website envelope must also equal the already-verified ordinary native final. This is a shadow result only.
    const equal=typeof p.expectedWireText==='string' && r.text===p.expectedWireText;
    const result={stage:r.error?(allowedFailureStages.has(r.error)?r.error:'unrecognized'):(equal?'wire_equal':'marker_mismatch')};
    dispose();return result;
  });
  window.addEventListener('pagehide',dispose,{once:true});
  Object.defineProperty(window,cfg.key,{configurable:true,value:registered});
}

installCatalogShadow(__COMPUTA_QWEN_MARKER_CONFIG__);
})();
