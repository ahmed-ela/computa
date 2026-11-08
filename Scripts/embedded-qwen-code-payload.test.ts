import { readFileSync } from 'node:fs';
import { expect, test } from 'bun:test';
import { fixture, raw, choice, prompt, marker, fingerprint, generation, conversationID } from './embedded-qwen-adapter-fixture';

const html='http://www.w3.org/1999/xhtml', svg='http://www.w3.org/2000/svg';
const originalPatch='*** Begin Patch\n*** Update File: /synthetic/report-`x`-**y**.py\n@@\n-    return 1\n+    return "λ😀\\n"\n*** End Patch';
const payload=JSON.stringify({type:'tool_calls',calls:[{name:'apply_patch',input:originalPatch}]});
function installCode(f:ReturnType<typeof fixture>, text=payload, controls=true) {
  const make=(tag:string,values:Record<string,string>={},text='')=>new f.Node(tag,values,text);
  const pre=make('PRE',{class:'qwen-markdown-code',dir:'ltr'});
  const wrap=make('DIV',{class:'qwen-markdown-code-header-wrapper qwen-markdown-code-header-wrapper-sticky',style:'top: -40px;'});
  Object.assign(wrap,{style:{top:'-40px'}});
  const header=make('DIV',{class:'qwen-markdown-code-header',style:'height: 36px;'});
  const language=make('DIV',{},'json'),actions=make('DIV',{class:'qwen-markdown-code-header-actions'});
  header.append(language,actions);wrap.append(header);
  const body=make('DIV',{id:'_r_0_',class:'qwen-markdown-code-body qwen-markdown-code-body-streaming json'}),code=make('CODE',{},text);
  const leaf={nodeType:3,get textContent(){return code.text;},get length(){return code.text.length;},get isConnected(){return code.isConnected;},parentElement:code};
  Object.defineProperty(code,'childNodes',{get:()=>code.children.length?[leaf,...code.children]:[leaf],configurable:true});
  body.append(code);pre.append(wrap,body);f.markdown.replaceChildren(pre);
  if(controls)for(const label of ['Copy','Download','Collapse Code']){
    const button=make('BUTTON',{type:'button',class:'qwen-chat-v2-btn qwen-chat-v2-btn-text qwen-chat-v2-btn-s qwen-chat-v2-btn-icon-only '+(label==='Collapse Code'?'qwen-markdown-code-collapse-btn':'qwen-markdown-code-header-action-item'),'aria-label':label,
      ...(label==='Collapse Code'?{'aria-expanded':'true','aria-controls':'_r_0_'}:{})});
    const span=make('SPAN',{class:'qwen-chat-v2-btn-icon'}),icon=make('svg',{width:'1em',height:'1em',fill:'currentColor','aria-hidden':'true',focusable:'false'}),use=make('use');
    Object.defineProperty(use,'attributes',{get:()=>[{name:'xlink:href',localName:'href',namespaceURI:'http://www.w3.org/1999/xlink',value:'#qwpcicon-'+(label==='Copy'?'copy':label==='Download'?'download':'up')}],configurable:true});
    icon.append(use);span.append(icon);button.append(span);actions.append(button);
  }
  for(const node of [f.document.documentElement,f.body,...f.body.descendants(),pre,...pre.descendants()]){
    Object.defineProperty(node,'namespaceURI',{value:['svg','use'].includes(node.tagName)?svg:html,configurable:true});
    Object.assign(node.computedStyle,{opacity:'1',visibility:'visible',textTransform:'none',webkitTextSecurity:'none',filter:'none',clipPath:'none',contentVisibility:'visible',whiteSpace:'pre',content:'none'});
  }
  return {pre,wrap,header,language,actions,body,code,leaf,copy:actions.children[0]};
}
const channel={dispatch:'11a11111-1111-4111-8111-111111111111',result:'22a22222-2222-4222-8222-222222222222',secret:'33a33333-3333-4333-8333-333333333333'};
const sink=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-code-payload.js',import.meta.url),'utf8');
function installSink(f:ReturnType<typeof fixture>) {
  const listeners=new Map<string,Set<(e:any)=>void>>();let delegated=0;
  Object.assign(f.document,{addEventListener:(name:string,fn:any)=>{if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name)!.add(fn);},removeEventListener:(name:string,fn:any)=>listeners.get(name)?.delete(fn)});
  const original=f.Node.prototype.dispatchEvent;
  f.Node.prototype.dispatchEvent=function(event:any){Object.assign(event,{target:this});const r=original.call(this,event);for(const fn of [...listeners.get(event.type)||[]])fn(event);return r;};
  Object.defineProperty(f.Node.prototype,'parentNode',{get(){return this.parentElement;}});
  class Clipboard {writeText(_:string){delegated++;return Promise.resolve();}write(_:any){delegated++;return Promise.resolve();}}
  class Doc {execCommand(_:string){delegated++;return true;}}
  Object.setPrototypeOf(f.document,Doc.prototype);
  const navigator={clipboard:new Clipboard()};
  const Event=class {constructor(public type:string,init:any){Object.assign(this,init);}};
  new Function('window','location','document','Clipboard','navigator','HTMLElement','HTMLButtonElement','Document','CustomEvent',sink.replace('__COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__',JSON.stringify(channel)))(f.window,{origin:'https://chat.qwen.ai'},f.document,Clipboard,navigator,f.Node,f.Node,Doc,Event);
  return {navigator,delegated:()=>delegated};
}
async function owned(mode='plain') {
  const f=fixture(),s=installSink(f);
  await f.run('inspect');let selected=false;
  for(let i=0;i<8&&!selected;i++)selected=(await f.run('selectModel',{modelChoice:choice()})).selected===true;
  expect(selected).toBe(true);expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert',{prompt,expectedFirstUserMarker:marker})).inserted).toBe(true);
  expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);
  expect((await f.run('submit',{prompt,savedSubmissionFingerprint:await fingerprint(prompt)})).submitted).toBe(true);
  const x=installCode(f);
  if(mode==='monaco'){
    x.body.setAttribute('class','qwen-markdown-code-body json qwen-markdown-code-body-virtual');
    const viewport=new f.Node('DIV',{class:'qwen-markdown-code-editor-viewport'});
    Object.defineProperty(viewport,'namespaceURI',{value:html});Object.assign(viewport.computedStyle,x.body.computedStyle);
    viewport.append(new f.Node('DIV',{class:'monaco-editor'},'only a virtual fragment'));
    x.body.replaceChildren(viewport);
  }
  let value=payload;
  x.copy.onClick=()=>{s.navigator.clipboard.writeText(value);};
  const first=await f.run('inspect',{expectedModelChoice:choice(),qwenCodePayloadChannel:channel});
  expect(first.firstUserVerified).toBe(true);expect(first.text).toBe('');expect(first.answerComplete).toBe(false);
  expect(first.qwenCodePayload.state).toBe('pending');expect(x.copy.clicks).toBe(0);
  const options={expectedModelChoice:choice(),expectedFirstUserFingerprint:first.firstUserFingerprint,allowFirstUserBinding:false,qwenCodePayloadChannel:channel};
  const grant={version:1,grant:crypto.randomUUID(),candidate:first.qwenCodePayload.candidate,responseID:first.qwenCodePayload.responseID,sequence:1};
  return {f,s,x,first,options,grant,setValue:(text:string)=>value=text,sample:(overrides:any={})=>f.run('inspect',{...options,evaluationDeadlineEpochMilliseconds:Date.now()+10000,qwenCodePayloadSample:grant,...overrides})};
}
test('Qwen metadata is empty until one final native-granted Copy after the body digest',async()=>{
  for(const mode of ['plain','monaco']){
    const t=await owned(mode);let hashes=0;t.f.beforeDigest(()=>{hashes++;expect(t.x.copy.clicks).toBe(0);});
    const result=await t.sample();expect(hashes).toBe(1);expect(result.error).toBeUndefined();
    expect(result.text).toBe(payload);expect(JSON.parse(result.text).calls[0].input).toBe(originalPatch);
    expect(result.answerComplete).toBe(true);expect(result.qwenCodePayload).toEqual({version:1,state:'sampled',grant:t.grant.grant,candidate:t.grant.candidate,responseID:t.grant.responseID});
    expect(t.x.copy.clicks).toBe(1);expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
    t.f.beforeDigest(()=>{});expect((await t.sample()).error).toBeTruthy();expect(t.x.copy.clicks).toBe(1);
  }
});
test('Qwen candidate polling and model reads are passive; final Copy samples current provider payload',async()=>{
  const t=await owned('monaco');
  for(const action of ['inspect','verifyModel']){const r=await t.f.run(action,t.options);expect(r.text).toBe('');expect(t.x.copy.clicks).toBe(0);}
  const changed=payload.replace('return','yield');t.f.beforeDigest(()=>t.setValue(changed));
  const r=await t.sample();expect(r.text).toBe(changed);expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
});
test('Qwen final Copy rejects wrong grants and missing native fingerprint without a click',async()=>{
  for(const bad of ['candidate','responseID','grant','sequence','version','extra','fingerprint','initial','channel']){
    const t=await owned(),grant:any={...t.grant};const extra:any={qwenCodePayloadSample:grant};
    if(bad==='extra')grant.extra=true;else if(bad==='fingerprint')extra.expectedFirstUserFingerprint='0'.repeat(64);
    else if(bad==='initial')extra.allowFirstUserBinding=true;else if(bad==='channel')extra.qwenCodePayloadChannel=null;
    else grant[bad]=['sequence','version'].includes(bad)?2:'foreign';
    const r=await t.sample(extra);expect(r.error).toBeTruthy();expect(r.text).toBeUndefined();expect(t.x.copy.clicks).toBe(0);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen final Copy retains model owner route response and exact first-body guards across await',async()=>{
  for(const bad of ['owner','model','route','body','response','control','disabled','duplicate','hidden_outer']){
    const t=await owned();t.f.beforeDigest(()=>{
      if(bad==='owner')t.f.world.__computaModelOwner='foreign';
      if(bad==='model')t.f.modelName.text='Qwen3.8-Max';
      if(bad==='route')t.f.document.URL+='?changed';
      if(bad==='body')t.f.userBody.text+='changed';
      if(bad==='response')t.f.answer.setAttribute('id','chat-response-message-11111111-2222-4333-8444-555555555555');
      if(bad==='control')t.x.actions.replaceChildren(t.x.copy.cloneNode(true));
      if(bad==='disabled')t.x.copy.setAttribute('disabled','');
      if(bad==='duplicate')t.x.actions.append(t.x.copy.cloneNode(true));
      if(bad==='occluded')t.f.occlude(t.x.copy);
      if(bad==='hidden_outer')t.f.body.computedStyle.opacity='0';
    });
    const r=await t.sample();expect(r.error).toBeTruthy();expect(t.x.copy.clicks).toBe(0);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen spent Copy refuses zero double late fallback mutated and oversized output without retry or clipboard delegation',async()=>{
  for(const bad of ['zero','double','late','fallback','mutation','replacement','oversize','surrogate']){
    const t=await owned();t.x.copy.onClick=()=>{
      if(bad==='zero')return;
      if(bad==='late'){queueMicrotask(()=>t.s.navigator.clipboard.writeText(payload));return;}
      if(bad==='fallback'){t.f.document.execCommand(' COPY ');return;}
      t.s.navigator.clipboard.writeText(bad==='oversize'?'x'.repeat(220001):bad==='surrogate'?'\ud800':payload);
      if(bad==='double')t.s.navigator.clipboard.writeText(payload);
      if(bad==='mutation')t.f.notifyAttribute('class');
      if(bad==='replacement')t.x.actions.replaceChildren(t.x.copy.cloneNode(true));
    };
    const r=await t.sample();expect(r.error,bad).toBeTruthy();expect(r.text).toBeUndefined();expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
    expect((await t.sample()).error).toBeTruthy();expect(t.x.copy.clicks).toBe(1);
  }
});
test('Qwen cleanup and ordinary plain JSON never dispatch code Copy',async()=>{
  const t=await owned();const result=await t.f.run('inspect',{...t.options,savedCleanupInspection:true});
  expect(result.text).toBe('');expect(t.x.copy.clicks).toBe(0);
  const f=fixture();f.mountConversation();const d=f.read();expect(d.rawAnswer(d.transcript().answer).text).toBe(raw);
});

test('Qwen Copy deadline is original and refuses a delayed body digest without a click',async()=>{
  for(const bad of ['missing','expired','over','type','during_digest']){
    const t=await owned();let deadline:any=Date.now()+10000;
    if(bad==='missing')deadline=undefined;
    if(bad==='expired')deadline=Date.now()-1;
    if(bad==='over')deadline=Date.now()+60000;
    if(bad==='type')deadline=String(deadline);
    if(bad==='during_digest'){
      deadline=Date.now()+15;
      t.f.beforeDigest(async()=>{await new Promise(resolve=>setTimeout(resolve,25));});
    }
    const r=await t.sample({evaluationDeadlineEpochMilliseconds:deadline});
    expect(r.error,bad).toBeTruthy();expect(t.x.copy.clicks).toBe(0);expect(t.s.delegated()).toBe(0);
  }
});

test('Qwen code Copy uses source identity despite outer clipping or offscreen paint',async()=>{
  for(const mode of ['clip','filter','text','offscreen','covered']){
    const t=await owned();
    if(mode==='clip')t.f.body.computedStyle.clipPath='inset(0 0 100% 0)';
    if(mode==='filter')t.f.body.computedStyle.filter='blur(2px)';
    if(mode==='text')t.f.body.computedStyle.textTransform='uppercase';
    if(mode==='offscreen')t.x.copy.getBoundingClientRect=()=>({left:-1000,top:-1000,width:20,height:20});
    if(mode==='covered')t.f.occlude(t.x.copy);
    const r=await t.sample();expect(r.error,mode).toBeUndefined();expect(r.text).toBe(payload);expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
function deleteInput(t:Awaited<ReturnType<typeof owned>>){
  const canonical='https://chat.qwen.ai/c/'+conversationID,hash=t.first.firstUserFingerprint;
  return {...t.options,expectedConversation:canonical,deleteOperation:{id:'28f9bb90-310a-42b0-a8a7-0108264cc1fd',documentGeneration:generation,sequence:1,firstUserFingerprint:hash,conversationURL:canonical}};
}
test('Qwen payload-child loss after failed Copy cannot resample but preserves independent deletion',async()=>{
  for(const change of ['copy','body']){
    const t=await owned();t.x.copy.onClick=()=>{};
    expect((await t.sample()).error).toBe('unsupported_response_format');expect(t.x.copy.clicks).toBe(1);
    if(change==='copy')t.x.actions.replaceChildren(t.x.copy.cloneNode(true));else t.x.body.replaceChildren(new t.f.Node('DIV',{},'unknown source widget'));
    const input=deleteInput(t);
    for(const action of ['deleteConversation','selectConversationDeletion','confirmConversationDeletion'])expect((await t.f.run(action,input)).error,action).toBeUndefined();
    expect((await t.f.run('observeDeletedConversation',input)).deleteProof.conversationDeleted).toBe(true);
    expect(t.x.copy.clicks).toBe(1);expect(t.f.send.clicks).toBe(1);expect(t.f.confirm.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen real response or first-user drift still refuses Copy and deletion',async()=>{
  for(const change of ['response_id','response_root','first_body']){
    const t=await owned();t.f.beforeDigest(()=>{
      if(change==='response_id')t.f.answer.setAttribute('id','chat-response-message-11111111-2222-4333-8444-555555555555');
      if(change==='response_root')t.f.answerRoot.parentElement!.replaceChildren(t.f.answerRoot.cloneNode(true));
      if(change==='first_body')t.f.userBody.text+='changed';
    });
    expect((await t.sample()).error).toBe('conversation_changed');t.f.beforeDigest(()=>{});
    expect((await t.f.run('deleteConversation',deleteInput(t))).error).toBeTruthy();
    expect(t.x.copy.clicks).toBe(0);expect(t.f.confirm.clicks).toBe(0);expect(t.f.more.clicks).toBe(0);
  }
});


test('Qwen official Copy binding ignores known class order and bounded header paint serialization',async()=>{
  for(const presentation of ['plain','monaco'])for(const layout of ['classes','styles','empty_styles']){
    const t=await owned(presentation);
    if(layout==='classes')for(const node of [t.f.phase,t.f.markdown,t.f.markdown.parentElement!,t.x.pre,...t.x.pre.descendants()]){
      const value=node.getAttribute('class');if(value)node.setAttribute('class',value.split(' ').reverse().join('  '));
    }
    if(layout==='styles'){
      t.x.wrap.setAttribute('style','top: -4096px; position: sticky;');
      t.x.header.setAttribute('style','height:42px; color: rgb(1, 2, 3)');
      t.x.body.setAttribute('style','min-height: 40px;');
    }
    if(layout==='empty_styles')for(const node of [t.x.wrap,t.x.header,t.x.body])node.setAttribute('style','');
    const result=await t.sample();expect(result.error,presentation+'/'+layout).toBeUndefined();
    expect(result.text).toBe(payload);expect(JSON.parse(result.text).calls[0].input).toBe(originalPatch);
    expect(t.x.copy.clicks).toBe(1);expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen layout allowance keeps style and class bounds and unknown structure refused before Copy',async()=>{
  for(const bad of ['wrap_style','header_style','body_style','class_bound','unknown_class','missing_class','duplicate_class','unknown_attribute','decoration_style','phase_unknown','phase_bound']){
    const t=await owned();
    if(bad==='wrap_style')t.x.wrap.setAttribute('style','x'.repeat(4097));
    if(bad==='header_style')t.x.header.setAttribute('style','x'.repeat(4097));
    if(bad==='body_style')t.x.body.setAttribute('style','x'.repeat(4097));
    if(bad==='class_bound')t.x.header.setAttribute('class',' '.repeat(513)+'qwen-markdown-code-header');
    if(bad==='unknown_class')t.x.header.setAttribute('class','qwen-markdown-code-header unknown');
    if(bad==='missing_class')t.x.copy.setAttribute('class','qwen-chat-v2-btn');
    if(bad==='duplicate_class')t.x.header.setAttribute('class','qwen-markdown-code-header qwen-markdown-code-header');
    if(bad==='unknown_attribute')t.x.header.setAttribute('data-unknown','');
    if(bad==='decoration_style')t.x.copy.children[0].setAttribute('style','color: red;');
    if(bad==='phase_unknown')t.f.phase.setAttribute('class','response-message-content unknown phase-answer');
    if(bad==='phase_bound')t.f.phase.setAttribute('class',' '.repeat(513)+'response-message-content t2t phase-answer');
    const result=await t.sample();expect(result.error,bad).toBeTruthy();expect(result.text).toBeUndefined();
    expect(t.x.copy.clicks).toBe(0);expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
