import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {test} from 'bun:test';
const file=new URL('../Sources/Computa/Resources/BrowserModels/qwen-marker-wire.js',import.meta.url);
const full=readFileSync(file,'utf8'), init='installCatalogShadow(__COMPUTA_QWEN_MARKER_CONFIG__);';
assert.equal(full.split(init).length,2);
const helpers=full.replace(init,'Object.assign(globalThis,{observeSiteCatalog,observeOwnedCompletion,selectiveAnswer,matchesOwnedRequest});');
function sandbox(){
 const c=vm.createContext({URL,TextDecoder,Uint8Array,console,setTimeout,clearTimeout});
 vm.runInContext(`globalThis.window=globalThis;window.top=window;globalThis.location={origin:"https://fixture.test",href:"https://fixture.test/"};globalThis.EventTarget=class{addEventListener(t,f){this.notify=f}};globalThis.performance={now:()=>1,getEntriesByName:()=>[{name:"https://fixture.test/api/v2/models/",initiatorType:"xmlhttprequest",startTime:1,requestStart:2,responseStart:3,responseEnd:4,redirectStart:0,redirectEnd:0,workerStart:0,decodedBodySize:150}]};globalThis.XMLHttpRequest=class extends EventTarget{open(m,url){this.path=new URL(url,location.href).href;this.state=1}send(){this.state=4;this.notify()}get responseURL(){return this.path}get responseText(){globalThis.reads.push(this.path);return '{"data":[{"name":"Qwen3.7-Plus","id":"pinned-plus"}]}'}get readyState(){return this.state}get status(){return 200}get responseType(){return ""}getResponseHeader(){return "application/json"}};globalThis.reads=[];globalThis.config={origin:location.origin,visibleModel:"Qwen3.7-Plus",expiresAt:Date.now()+10000};`,c);
 vm.runInContext(helpers,c);return code=>vm.runInContext(code,c)
}
test('only accepted complete ordinary catalog is read and only once',()=>{
 const go=sandbox();assert.equal(go(`const o=observeSiteCatalog(config),x=new XMLHttpRequest;x.open('GET','/api/v2/models/',true);x.send();reads.length`),0);
 assert.equal(go('o.pair()'),'pinned-plus');assert.equal(go('o.pair()'),'pinned-plus');assert.equal(go('reads.length'),1);go('o.retire()')
});
for(const bypass of [false,true])test('no foreign body access after XHR reuse '+bypass,()=>{
 const go=sandbox();assert.equal(go(`const original=XMLHttpRequest.prototype.open, originalSend=XMLHttpRequest.prototype.send,o=observeSiteCatalog(config),x=new XMLHttpRequest;x.open('GET','/api/v2/models/',true);x.send();${bypass?"original.call(x,'GET','/private',true)":"x.open('GET','/private',true)"};originalSend.call(x);o.pair()`),null);
 assert.equal(go('reads.length'),0);go('o.retire()')
});
for(const method of ['post','POST','PoSt','PUT','post '])test('accepts only the exact ASCII POST method, ' + JSON.stringify(method),async()=>{
 const go=sandbox();assert.equal(await go(`(async()=>{const id='00000000-0000-4000-8000-', chat=id+'000000000001', user=id+'000000000002';let requests=0;window.fetch=()=>{requests++;return Promise.resolve({status:204})};const o=observeOwnedCompletion(config);o.arm({durationMs:100,visibleModel:config.visibleModel,wireModel:'pinned-plus',prompt:'fixture'});const r=fetch('/api/v2/chat/completions?chat_id='+chat,{method:${JSON.stringify(method)},headers:{Version:'0.3.32','X-Request-Id':user},body:JSON.stringify({chat_id:chat,chatId:chat,model:'pinned-plus',stream:true,incremental_output:true,version:'2.1',chat_mode:'normal',parent_id:null,parentId:'',messages:[{id:user,content:'fixture',user_action:'chat',role:'user',models:['pinned-plus'],files:[]}]})});await r;return [requests,o.claim({}).error].join('/')})()`),method.trim()===method&&method.toUpperCase()==='POST'?'1/http_or_reader':'1/request')
});

for (const mode of ['single','history-append','history-first','unknown-content-first','nested-private','duplicate-model','duplicate-extra','model-mismatch','invalid-user-id']) {
  test('bounded DTO matcher, without materializing unrelated content: '+mode,()=>{
    const go=sandbox();
    const value=go(`const mode=${JSON.stringify(mode)}, chat='00000000-0000-4000-8000-000000000001', user='00000000-0000-4000-8000-000000000002', held={prompt:'fixed\\\" 🦊',wireModel:'pinned-plus'};
      const item={role:'user',content:held.prompt,files:[],models:[held.wireModel],user_action:'chat',id:user};
      const real={stream:true,incremental_output:true,version:'2.1',chat_mode:'normal',model:held.wireModel,chatId:chat,chat_id:chat,parent_id:null,parentId:'',messages:[item]};
      const secret='PRIVATE_CANARY_A25E';
      if(mode==='history-append')real.messages.push({content:secret,role:'assistant'});
      if(mode==='history-first')real.messages.unshift({content:secret,role:'assistant'});
      if(mode==='unknown-content-first')item.content=secret;
      if(mode==='nested-private')real.metadata={nested:{items:[secret]}};
      if(mode==='invalid-user-id')item.id=secret;
      if(mode==='model-mismatch')real.model=secret;
      let raw=JSON.stringify(real);
      if(mode==='duplicate-model')raw=raw.replace('"stream":true','"stream":true,"stream":true');
      if(mode==='duplicate-extra')raw=raw.replace('"stream":true','"extra":{"a":1,"a":2},"stream":true');
      let leaked=false;const parse=JSON.parse, slice=String.prototype.slice;
      JSON.parse=function(s,...a){if(s.includes(secret))leaked=true;return Reflect.apply(parse,this,[s,...a])};
      String.prototype.slice=function(...args){const s=Reflect.apply(slice,this,args);if(s.includes(secret))leaked=true;return s};
      let yes=false;try {yes=matchesOwnedRequest(raw,held,chat)}catch{};
      [yes,leaked].join('/')`);
    assert.equal(value,(mode==='single'||mode==='nested-private'?'true':'false')+'/false');
  });
}
