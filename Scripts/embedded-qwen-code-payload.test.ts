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
function installSink(f:ReturnType<typeof fixture>, resultTransform?:(value:any)=>any, sinkPromise:any=Promise) {
  const listeners=new WeakMap<any,Map<string,{fn:any,capture:boolean}[]>>();let delegated=0;
  const add=function(this:any,name:string,fn:any,capture=false){
    if(!listeners.has(this))listeners.set(this,new Map());const map=listeners.get(this)!;
    if(!map.has(name))map.set(name,[]);map.get(name)!.push({fn,capture:!!capture});
  };
  const remove=function(this:any,name:string,fn:any,capture=false){const map=listeners.get(this);if(map)map.set(name,(map.get(name)||[]).filter(v=>v.fn!==fn||v.capture!==!!capture));};
  class ET {}Object.assign(ET.prototype,{addEventListener:add,removeEventListener:remove});
  const Event=class {
    target:any;currentTarget:any;cancelBubble=false;immediate=false;bubbles=false;detail:any;
    constructor(public type:string,init:any={}){Object.assign(this,init);if(type===channel.result&&resultTransform)this.detail=resultTransform(init.detail);}
    stopPropagation(){this.cancelBubble=true;}
    stopImmediatePropagation(){this.cancelBubble=true;this.immediate=true;}
  };
  const root=new f.Node('DIV',{id:'root'}),children=f.body.children.slice();f.body.children=[];root.append(...children);f.body.append(root);
  Object.defineProperty(root,'namespaceURI',{value:html,configurable:true});
  Object.assign(f.Node.prototype,{addEventListener:add,removeEventListener:remove});
  const original=f.Node.prototype.dispatchEvent;
  f.Node.prototype.dispatchEvent=function(event:any){
    event.target=this;original.call(this,event);const path:any[]=[];
    for(let node:any=this;node;node=node.parentElement)path.push(node);path.push(f.document);
    const invoke=(node:any,capture:boolean)=>{event.currentTarget=node;for(const row of [...listeners.get(node)?.get(event.type)||[]]){if(row.capture===capture)row.fn.call(node,event);if(event.immediate)break;}};
    for(const node of path.slice().reverse()){invoke(node,true);if(event.cancelBubble)break;}
    if(!event.cancelBubble)for(const node of event.bubbles?path:[this]){invoke(node,false);if(event.cancelBubble)break;}
    event.currentTarget=null;return true;
  };
  f.Node.prototype.click=function(){this.clicks++;const event=new Event('click',{bubbles:true});(this.onClick as any)?.(event);this.dispatchEvent(event);};
  class Clipboard {writeText(_:string){delegated++;return Promise.resolve();}write(_:any){delegated++;return Promise.resolve();}}
  class Doc {execCommand(_:string){delegated++;return true;}querySelectorAll(selector:string){return f.document.documentElement.querySelectorAll(selector);}}
  Object.assign(Doc.prototype,{addEventListener:add,removeEventListener:remove});Object.setPrototypeOf(f.document,Doc.prototype);
  Object.assign(f.document,{addEventListener:add,removeEventListener:remove});
  const navigator={clipboard:new Clipboard()};
  new Function('window','location','document','Clipboard','navigator','HTMLElement','HTMLButtonElement','Document','CustomEvent','Promise','EventTarget','Event','Node',sink.replace('__COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__',JSON.stringify(channel)))(f.window,{origin:'https://chat.qwen.ai'},f.document,Clipboard,navigator,f.Node,f.Node,Doc,Event,sinkPromise,ET,Event,f.Node);
  return {navigator,root,Event,delegated:()=>delegated,listenerCount:(node:any)=>(listeners.get(node)?.get('click')||[]).length};
}
async function owned(mode='plain', editorStyle?:string, resultTransform?:(value:any)=>any, sinkPromise:any=Promise) {
  const f=fixture(),s=installSink(f,resultTransform,sinkPromise);
  await f.run('inspect');let selected=false;
  for(let i=0;i<8&&!selected;i++)selected=(await f.run('selectModel',{modelChoice:choice()})).selected===true;
  expect(selected).toBe(true);expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert',{prompt,expectedFirstUserMarker:marker})).inserted).toBe(true);
  expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);
  expect((await f.run('submit',{prompt,savedSubmissionFingerprint:await fingerprint(prompt)})).submitted).toBe(true);
  const added=f.body.children.filter(node=>node!==s.root);f.body.children=[s.root];s.root.append(...added);
  const x=installCode(f);
  if(mode==='monaco'||mode==='editor'){
    x.body.setAttribute('class','qwen-markdown-code-body json'+(mode==='monaco'?' qwen-markdown-code-body-virtual':''));
    const viewport=new f.Node('DIV',{class:'qwen-markdown-code-editor-viewport',...(editorStyle===undefined?{}:{style:editorStyle})});
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

test('Qwen code candidate decline reports its first finite gate without private values or new actions',()=>{
  const checks:[string,(f:ReturnType<typeof fixture>,x:ReturnType<typeof installCode>)=>void][]=[
    ['custom_shape',(f)=>f.phase.children[0].setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['markdown_shape',(f)=>f.markdown.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['phase_shape',(f)=>f.phase.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['pre_shape',(_,x)=>x.pre.setAttribute('dir','rtl')],
    ['header_wrapper',(_,x)=>x.wrap.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['header_shape',(_,x)=>x.header.append(x.language.cloneNode(true))],
    ['language',(_,x)=>x.language.text='PRIVATE_LANGUAGE'],
    ['actions_shape',(_,x)=>x.actions.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['body_classes',(_,x)=>x.body.setAttribute('class','PRIVATE_CLASS')],
    ['body_tag',(_,x)=>x.body.tagName='SPAN'],
    ['body_attributes',(_,x)=>x.body.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['body_visibility',(_,x)=>x.body.computedStyle.visibility='hidden'],
    ['body_id',(_,x)=>x.body.removeAttribute('id')],
    ['body_empty',(_,x)=>x.body.replaceChildren()],
    ['body_children',(_,x)=>x.body.append(x.code.cloneNode(true))],
    ['plain_code_tag',(_,x)=>x.code.tagName='DIV'],
    ['plain_code_visibility',(_,x)=>x.code.computedStyle.visibility='hidden'],
    ['plain_code_shape',(_,x)=>{Object.defineProperty(x.code,'childNodes',{value:[],configurable:true});}],
    ['plain_code_attributes',(_,x)=>x.code.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['body_geometry',(_,x)=>x.body.getBoundingClientRect=()=>({left:10,top:10,width:0,height:30})],
    ['control_shape',(_,x)=>x.copy.setAttribute('data-private','PRIVATE_ATTRIBUTE')],
    ['control_decoration',(_,x)=>x.copy.children[0].text='PRIVATE_ICON_TEXT'],
    ['control_label',(_,x)=>x.copy.setAttribute('aria-label','PRIVATE_LABEL')],
    ['collapse_state',(_,x)=>x.actions.children[2].setAttribute('aria-expanded','false')],
    ['missing_copy',(_,x)=>x.copy.detach()],
    ['ancestor_limit',(f)=>{for(let i=0;i<65;i++){const parent=f.phase.parentElement!,wrap=new f.Node('DIV');Object.defineProperty(wrap,'namespaceURI',{value:html});Object.assign(wrap.computedStyle,f.body.computedStyle);parent.replaceChildren(wrap);wrap.append(f.phase);}}],
    ['ancestor_visibility',(f)=>f.body.computedStyle.opacity='0'],
    ['ancestor_root',(f)=>{f.document.documentElement=new f.Node('HTML');}]
  ];
  for(const [reason,mutate] of [
    ['editor_tag',(node:any)=>node.tagName='SPAN'],['editor_class',(node:any)=>node.setAttribute('class','PRIVATE_CLASS')],
    ['editor_attributes',(node:any)=>node.setAttribute('data-private','PRIVATE_ATTRIBUTE')],['editor_visibility',(node:any)=>node.computedStyle.visibility='hidden']
  ] as const)checks.push([reason,(f,x)=>{x.body.setAttribute('class','qwen-markdown-code-body json');const node=new f.Node('DIV',{class:'qwen-markdown-code-editor-viewport'});Object.defineProperty(node,'namespaceURI',{value:html});Object.assign(node.computedStyle,x.body.computedStyle);x.body.replaceChildren(node);mutate(node);}]);
  for(const [reason,mutate] of checks){
    const f=fixture();f.mountConversation();const x=installCode(f);mutate(f,x);const d=f.read(),r=d.rawAnswer(d.transcript().answer);
    expect(r.text,reason).toBe('');expect(r.formatIssue,reason).toBe(true);
    expect(r.failureStructure(),reason).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'code_candidate',reason,count:0});
    expect(JSON.stringify(r.failureStructure())).not.toContain('PRIVATE');expect(x.copy.clicks).toBe(0);
  }
});

test('Qwen sampled refusal distinguishes finite sink cardinality and mutation without returning bytes or another click',async()=>{
  for(const [kind,reason] of [['zero','write_count'],['double','write_count'],['invalid','write_invalid_size'],['mutation','synchronous_mutation']] as const){
    const t=await owned();t.x.copy.onClick=()=>{
      if(kind==='zero')return;
      t.s.navigator.clipboard.writeText(kind==='invalid'?'x'.repeat(220001):payload);
      if(kind==='double')t.s.navigator.clipboard.writeText(payload);
      if(kind==='mutation')t.f.notifyAttribute('class');
    };
    const r=await t.sample();expect(r.error).toBe('unsupported_response_format');expect(r.text).toBeUndefined();
    expect(r.adapterFailureStructure).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'code_sample',reason,count:0});
    expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
    expect((await t.sample()).error).toBeTruthy();expect(t.x.copy.clicks).toBe(1);
  }
});


test('Qwen provider viewport layout styles retain exact owned final Copy bytes',async()=>{
  // Public0.3.32 zI writes viewport.style.height and viewport.style.top after mount.
  for(const mode of ['editor','monaco'])for(const style of ['height: 74px;','top: 52px; height: 582px;','']){
    const t=await owned(mode,style);
    expect(t.first.text).toBe('');expect(t.x.copy.clicks).toBe(0);
    const result=await t.sample();expect(result.error).toBeUndefined();expect(result.text).toBe(payload);
    expect(JSON.parse(result.text).calls[0].input).toBe(originalPatch);
    expect(result.answerComplete).toBe(true);expect(t.x.copy.clicks).toBe(1);
    expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
    expect((await t.sample()).error).toBeTruthy();expect(t.x.copy.clicks).toBe(1);
  }
});
test('Qwen provider viewport style allowance preserves attributes visibility and post-digest refusal',async()=>{
  for(const bad of ['oversize','unknown','namespace','hidden','inert','aria_hidden','display','visibility','opacity','pseudo','after_digest']){
    const t=await owned('monaco');const viewport=t.x.body.children[0] as typeof t.x.body;
    const mutate=()=>{
      viewport.setAttribute('style','height: 74px;');
      if(bad==='oversize')viewport.setAttribute('style','x'.repeat(4097));
      if(bad==='unknown'||bad==='after_digest')viewport.setAttribute('data-private','PRIVATE_VALUE');
      if(bad==='namespace')Object.defineProperty(viewport,'attributes',{get:()=>[
        {name:'class',value:'qwen-markdown-code-editor-viewport'},
        {name:'style',value:'height: 74px;',namespaceURI:'PRIVATE_NAMESPACE'}]});
      if(bad==='hidden'||bad==='inert')viewport.setAttribute(bad,'');
      if(bad==='aria_hidden')viewport.setAttribute('aria-hidden','true');
      if(bad==='display')viewport.computedStyle.display='none';
      if(bad==='visibility')viewport.computedStyle.visibility='hidden';
      if(bad==='opacity')viewport.computedStyle.opacity='0';
      if(bad==='pseudo')viewport.computedStyle.content='"PRIVATE_PSEUDO"';
    };
    if(bad==='after_digest')t.f.beforeDigest(mutate);else mutate();
    const result=await t.sample();expect(result.error,bad).toBeTruthy();expect(result.text).toBeUndefined();
    expect(t.x.copy.clicks).toBe(0);expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});


test('Qwen first invalid Copy cause is finite and cannot change the refusal or spend another grant',async()=>{
  for(const [kind,reason] of [['type','write_invalid_type'],['size','write_invalid_size'],['api','write_invalid_api'],
    ['exec','write_invalid_exec'],['click','write_invalid_click'],['hooks','write_invalid_hooks']] as const){
    const t=await owned();t.x.copy.onClick=()=>{
      t.s.navigator.clipboard.writeText(kind==='type'?42 as any:kind==='size'?'x'.repeat(220001):payload);
      if(kind==='api')t.s.navigator.clipboard.write([]);
      if(kind==='exec')t.f.document.execCommand(' CoPy ');
      if(kind==='click')throw Error('PRIVATE_EXCEPTION_TEXT');
      if(kind==='hooks')Object.defineProperty(t.s.navigator.clipboard,'writeText',{value:()=>Promise.resolve()});
    };
    const r=await t.sample();expect(r.error,kind).toBe('unsupported_response_format');expect(r.text).toBeUndefined();
    expect(r.adapterFailureStructure).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'code_sample',reason,count:0});
    expect(JSON.stringify(r.adapterFailureStructure)).not.toContain('PRIVATE');
    expect(t.x.copy.clicks).toBe(1);expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
    expect((await t.sample()).error).toBeTruthy();expect(t.x.copy.clicks).toBe(1);
  }
});
test('Qwen invalid Copy cause latches first and preserves write-count and hook short-circuit order',async()=>{
  for(const kind of ['first','count','hook_short_circuit']){
    const t=await owned();t.x.copy.onClick=()=>{
      t.s.navigator.clipboard.writeText(42 as any);
      t.s.navigator.clipboard.write([]);
      if(kind==='count')t.s.navigator.clipboard.writeText(payload);
      if(kind==='hook_short_circuit')Object.defineProperty(t.s.navigator,'clipboard',{get(){throw Error('PRIVATE_GETTER');}});
    };
    const r=await t.sample();expect(r.adapterFailureStructure.reason).toBe(kind==='count'?'write_count':'write_invalid_type');
    expect(r.text).toBeUndefined();expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen Copy result requires boolean flag and consistent closed cause without content disclosure',async()=>{
  const cases:[string,(value:any)=>any,string][]=[
    ['false_number',v=>({...v,invalid:0}),'result_invalid'],
    ['null_flag',v=>({...v,invalid:null}),'result_invalid'],
    ['string_flag',v=>({...v,invalid:'false'}),'result_invalid'],
    ['undefined_flag',v=>({...v,invalid:undefined}),'result_invalid'],
    ['false_cause',v=>({...v,invalidCause:'value_type'}),'result_fields'],
    ['true_null',v=>({...v,invalid:true}),'result_fields'],
    ['unknown_cause',v=>({...v,invalid:true,invalidCause:'PRIVATE_CAUSE'}),'result_fields'],
    ['object_cause',v=>({...v,invalid:true,invalidCause:{text:'PRIVATE_TEXT'}}),'result_fields'],
    ['missing_cause',v=>{const {invalidCause,...rest}=v;return rest;},'result_fields'],
    ['extra',v=>({...v,extra:'PRIVATE_TEXT'}),'result_fields']
  ];
  for(const [name,transform,reason] of cases){
    const t=await owned('plain',undefined,transform),r=await t.sample();
    expect(r.error,name).toBe('unsupported_response_format');expect(r.text).toBeUndefined();
    expect(r.adapterFailureStructure.reason,name).toBe(reason);expect(JSON.stringify(r.adapterFailureStructure)).not.toContain('PRIVATE');
    expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});

test('Qwen synchronous sink resolve failure is rethrown privately and refuses even when the provider swallows it',async()=>{
  for(const mode of ['swallowed','rich_fallback','uncaught','private_primitive']){
    let resolves=0,exceptionReads=0,caught=false;
    const privateError=mode==='private_primitive'?'PRIVATE_THROWN_TEXT':Object.defineProperties({}, {
      message:{get(){exceptionReads++;return 'PRIVATE_MESSAGE';}},
      stack:{get(){exceptionReads++;return 'PRIVATE_STACK';}},
      toString:{value(){exceptionReads++;return 'PRIVATE_STRING';}}
    });
    const sinkPromise={resolve(){if(++resolves===1)throw privateError;return Promise.resolve();}};
    const t=await owned('plain',undefined,undefined,sinkPromise);
    t.x.copy.onClick=()=>{
      try{t.s.navigator.clipboard.writeText(payload);}
      catch(error){caught=error===privateError;if(mode==='uncaught')throw error;}
      if(mode==='rich_fallback')t.s.navigator.clipboard.write([]);
    };
    const r=await t.sample();expect(caught,mode).toBe(true);expect(exceptionReads).toBe(0);
    expect(r.error,mode).toBe('unsupported_response_format');expect(r.text).toBeUndefined();
    expect(r.adapterFailureStructure).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'code_sample',reason:'write_invalid_resolve',count:0});
    expect(JSON.stringify(r.adapterFailureStructure)).not.toContain('PRIVATE');
    expect(t.x.copy.clicks).toBe(1);expect(t.f.send.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
    if(mode==='swallowed'){
      const deletion=deleteInput(t);
      for(const action of ['deleteConversation','selectConversationDeletion','confirmConversationDeletion'])expect((await t.f.run(action,deletion)).error).toBeUndefined();
      expect((await t.f.run('observeDeletedConversation',deletion)).deleteProof.conversationDeleted).toBe(true);
    }else expect((await t.sample()).error).toBeTruthy();
    expect(t.x.copy.clicks).toBe(1);
  }
});
test('Qwen sink resolve diagnostic preserves earlier invalid causes and write-count priority',async()=>{
  for(const [kind,reason] of [['type','write_invalid_type'],['size','write_invalid_size'],['api','write_invalid_api'],['count','write_count']] as const){
    let resolves=0;
    const sinkPromise={resolve(){if(++resolves===(kind==='api'?2:1))throw 'PRIVATE_RESOLVE';return Promise.resolve();}};
    const t=await owned('plain',undefined,undefined,sinkPromise);t.x.copy.onClick=()=>{
      if(kind==='api')t.s.navigator.clipboard.write([]);
      try{t.s.navigator.clipboard.writeText(kind==='type'?42 as any:kind==='size'?'x'.repeat(220001):payload);}catch{}
      if(kind==='count')t.s.navigator.clipboard.writeText(payload);
    };
    const r=await t.sample();expect(r.adapterFailureStructure.reason,kind).toBe(reason);
    expect(r.text).toBeUndefined();expect(JSON.stringify(r.adapterFailureStructure)).not.toContain('PRIVATE');
    expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen sink resolve diagnostic does not revise accepted bytes after an inactive late callback',async()=>{
  let resolves=0;
  const sinkPromise={resolve(){if(++resolves===2)throw 'PRIVATE_LATE';return Promise.resolve();}};
  const t=await owned('plain',undefined,undefined,sinkPromise),r=await t.sample();
  expect(r.error).toBeUndefined();expect(r.text).toBe(payload);expect(r.answerComplete).toBe(true);
  let caught=false;try{t.s.navigator.clipboard.writeText('PRIVATE_LATE_BODY');}catch(error){caught=error==='PRIVATE_LATE';}
  expect(caught).toBe(true);expect(r.text).toBe(payload);expect(t.s.delegated()).toBe(0);
  expect((await t.sample()).error).toBeTruthy();expect(t.x.copy.clicks).toBe(1);
  const bad=await owned('plain',undefined,v=>({...v,invalid:false,invalidCause:'resolve_failure'}));
  const refused=await bad.sample();expect(refused.adapterFailureStructure.reason).toBe('result_fields');expect(refused.text).toBeUndefined();
});

test('Qwen owned Copy stops only its own click at the app root after header handling and removes the listener',async()=>{
  const t=await owned();let ancestorOwned=0,otherClicks=0,rootOwned=0;
  const other=new t.f.Node('BUTTON');t.s.root.append(other);
  (t.s.root as any).addEventListener('click',(event:any)=>{if(event.target===t.x.copy)rootOwned++;});
  (t.f.body as any).addEventListener('click',(event:any)=>{
    if(event.target===t.x.copy){ancestorOwned++;t.s.navigator.clipboard.write([]);}else if(event.target===other)otherClicks++;
  });
  const existing=t.s.listenerCount(t.s.root);
  t.x.copy.onClick=()=>{other.click();t.s.navigator.clipboard.writeText(payload);};
  const result=await t.sample();
  expect(result.error).toBeUndefined();expect(result.text).toBe(payload);expect(result.answerComplete).toBe(true);
  expect(rootOwned).toBe(1);expect(ancestorOwned).toBe(0);expect(otherClicks).toBe(1);
  expect(t.s.listenerCount(t.s.root)).toBe(existing);expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  other.click();expect(otherClicks).toBe(2);expect(t.x.copy.clicks).toBe(1);
  const deletion=deleteInput(t);
  for(const action of ['deleteConversation','selectConversationDeletion','confirmConversationDeletion'])expect((await t.f.run(action,deletion)).error).toBeUndefined();
  expect((await t.f.run('observeDeletedConversation',deletion)).deleteProof.conversationDeleted).toBe(true);
  expect(t.x.copy.clicks).toBe(1);
});
test('Qwen app-root boundary refuses missing duplicate malformed or moved roots before Copy',async()=>{
  for(const kind of ['missing','duplicate','tag','namespace','nested','outside'] as const){
    const t=await owned();
    t.f.beforeDigest(()=>{
      if(kind==='missing')t.s.root.removeAttribute('id');
      if(kind==='duplicate'){const duplicate=new t.f.Node('DIV',{id:'root'});t.f.body.append(duplicate);}
      if(kind==='tag')t.s.root.tagName='SECTION';
      if(kind==='namespace')Object.defineProperty(t.s.root,'namespaceURI',{value:svg,configurable:true});
      if(kind==='nested'){const wrapper=new t.f.Node('DIV');t.f.body.children=t.f.body.children.filter(node=>node!==t.s.root);wrapper.append(t.s.root);t.f.body.append(wrapper);}
      if(kind==='outside'){t.f.body.children=t.s.root.children.slice();for(const node of t.f.body.children)node.parentElement=t.f.body;t.s.root.children=[];t.f.body.append(t.s.root);}
    });
    const result=await t.sample();expect(result.error,kind).toBeTruthy();expect(result.text).toBeUndefined();
    expect(t.x.copy.clicks,kind).toBe(0);expect(t.s.listenerCount(t.s.root)).toBe(0);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen root boundary keeps same-root or lower rich writes refused and cleans up after callback throws',async()=>{
  for(const kind of ['same_root','lower','throw','not_seen','changed','duplicate_during'] as const){
    const t=await owned();let after=0;
    const other=new t.f.Node('BUTTON');t.s.root.append(other);
    (t.f.body as any).addEventListener('click',(event:any)=>{if(event.target===other)after++;});
    if(kind==='same_root'||kind==='lower')((kind==='same_root'?t.s.root:t.x.actions) as any).addEventListener('click',()=>t.s.navigator.clipboard.write([]));
    const existing=t.s.listenerCount(t.s.root);
    t.x.copy.onClick=((event:any)=>{
      t.s.navigator.clipboard.writeText(payload);
      if(kind==='throw')throw Error('PRIVATE_CALLBACK');
      if(kind==='not_seen')event.stopPropagation();
      if(kind==='changed')t.s.root.setAttribute('id','changed-root');
      if(kind==='duplicate_during')t.f.body.append(new t.f.Node('DIV',{id:'root'}));
    }) as any;
    const result=await t.sample();expect(result.error,kind).toBe('unsupported_response_format');expect(result.text).toBeUndefined();
    expect(result.adapterFailureStructure.reason,kind).toBe(kind==='same_root'||kind==='lower'?'write_invalid_api':kind==='throw'?'write_invalid_click':'root_boundary');
    expect(JSON.stringify(result.adapterFailureStructure)).not.toContain('PRIVATE');expect(t.s.listenerCount(t.s.root)).toBe(existing);
    other.click();expect(after,kind).toBe(1);expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
  }
});
test('Qwen boundary uses captured event methods and never changes ordinary clicks outside its one dispatch',async()=>{
  const t=await owned();let after=0;
  const other=new t.f.Node('BUTTON');t.s.root.append(other);
  (t.f.body as any).addEventListener('click',(event:any)=>{if(event.target===other)after++;});
  other.click();expect(after).toBe(1);
  (t.s.root as any).addEventListener=()=>{throw Error('PRIVATE_ADD');};
  (t.s.root as any).removeEventListener=()=>{throw Error('PRIVATE_REMOVE');};
  t.s.Event.prototype.stopPropagation=()=>{throw Error('PRIVATE_STOP');};
  const result=await t.sample();expect(result.error).toBeUndefined();expect(result.text).toBe(payload);
  expect(t.s.listenerCount(t.s.root)).toBe(0);other.click();expect(after).toBe(2);expect(t.x.copy.clicks).toBe(1);expect(t.s.delegated()).toBe(0);
});
