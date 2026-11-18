import {readFileSync} from 'node:fs';
import {fixture,choice,prompt,marker,fingerprint,answerID,userID} from './embedded-qwen-adapter-fixture';
export const channel={dispatch:'11a11111-1111-4111-8111-111111111111',result:'22a22222-2222-4222-8222-222222222222',secret:'33a33333-3333-4333-8333-333333333333'};
const html='http://www.w3.org/1999/xhtml';
const source=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-authored-source.js',import.meta.url),'utf8');
function installRawWorld(f:ReturnType<typeof fixture>, resultTransform?:(value:any)=>any, sinkPromise:any=Promise, sourceOverride?:string) {
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
  Object.assign(ET.prototype,{dispatchEvent:f.Node.prototype.dispatchEvent});
  const navigator={clipboard:new Clipboard()};
  Object.defineProperty(f.Node.prototype,'ownerDocument',{get:()=>f.document,configurable:true});
  Object.defineProperty(f.Node.prototype,'id',{get(){return this.getAttribute('id')||'';},configurable:true});
  new Function('window','location','document','Clipboard','navigator','HTMLElement','HTMLButtonElement','Document','CustomEvent','Promise','EventTarget','Event','Node','HTMLDivElement',(sourceOverride ?? source).replace('__COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__',JSON.stringify(channel)))(f.window,{origin:'https://chat.qwen.ai',get href(){return f.document.URL;}},f.document,Clipboard,navigator,f.Node,f.Node,Doc,Event,sinkPromise,ET,Event,f.Node,f.Node);
  return {navigator,root,Event,delegated:()=>delegated,listenerCount:(node:any)=>(listeners.get(node)?.get('click')||[]).length};
}

export function props(f:ReturnType<typeof fixture>, raw:string) {
  const hidden:any={phase:'thinking_summary',role:'assistant',status:'finished',extra:{},timestamp:1,groupIndex:0};
  Object.defineProperty(hidden,'content',{get(){throw new Error('reasoning content must never be read');},enumerable:true,configurable:true});
  const answer:any={phase:'answer',role:'assistant',status:'finished',content:raw,extra:{},timestamp:2,function_id:undefined,groupIndex:1};
  const usage={prompt_tokens:1,completion_tokens:2,total_tokens:3};
  const message:any={id:answerID,parentId:userID,role:'assistant',done:true,childrenIds:[],content:'',chat_type:'t2t',sub_chat_type:'t2t',
    extra:{meta:{subChatType:'t2t'}},feature_config:{thinking_enabled:true,local_mcp:undefined,output_schema:'phase',research_mode:'normal',auto_thinking:true,thinking_mode:'Auto'},
    info:{...usage,openai:true,usage},content_list:[hidden,answer]};
  const element=(p:any)=>({$$typeof:Symbol.for('react.transitional.element'),type:()=>{throw new Error('component must never execute');},props:p});
  const input:any={message,phaseContentIndex:1,content:raw};
  // Pinned0.3.38 CY: rightDIV/array/Fragment/NV/array/map-array/phaseFragment/div/$W/PG.
  const phase=element({children:element({children:element({message,phase:'answer',children:element(input)})})});
  const phases=[element({message,phaseContent:hidden,contentList:message.content_list}),phase];
  const nv=element({message,children:[element({message}),element({message}),phases,false]});
  const right=element({className:'chat-response-message-right',children:[element({children:nv}),false,false,false,false,false,false,
    element({message,isEdit:false,isRenderEmpty:false}),false,false]});
  const current:any={id:'chat-response-message-'+answerID,children:right};
  Object.defineProperty(f.answer,'__reactProps$fixture',{value:current,writable:true,configurable:true});
  return {message,answer,hidden,current,input,element};
}
export async function ownedRaw(raw:string, mutate?:(p:ReturnType<typeof props>,f:ReturnType<typeof fixture>)=>void, transform?:(value:any)=>any, firstAction:'inspect'|'verifyModel'='inspect', deferDOMRefusal=false, sourceOverride?:string) {
  const f=fixture(),world=installRawWorld(f,transform,Promise,sourceOverride);
  await f.run('inspect');for(let i=0;i<8;i++)if((await f.run('selectModel',{modelChoice:choice()})).selected)break;
  await f.run('prepare');await f.run('insert',{prompt,expectedFirstUserMarker:marker});await f.run('sendReady',{prompt});
  await f.run('submit',{prompt,savedSubmissionFingerprint:await fingerprint(prompt)});
  const added=f.body.children.filter(node=>node!==world.root);f.body.children=[world.root];world.root.append(...added);
  const p=props(f,raw);mutate?.(p,f);
  // The DOM parser still refuses this structure. The separate current raw
  // source must account for the entire answer, never the visible fragments.
  const refuseDOM=()=>f.paragraph.append(new f.Node('A',{},'DOM is not the raw source'));
  if(!deferDOMRefusal)refuseDOM();
  const first=await f.run(firstAction,{expectedModelChoice:choice(),qwenCodePayloadChannel:channel});
  if(deferDOMRefusal)refuseDOM();
  const options={expectedModelChoice:choice(),expectedFirstUserFingerprint:first.firstUserFingerprint,allowFirstUserBinding:false,qwenCodePayloadChannel:channel};
  const grant={version:2,sourceKind:'raw_answer_v1',sequence:1,grant:crypto.randomUUID(),candidate:first.qwenCodePayload?.candidate,responseID:first.qwenCodePayload?.responseID};
  return {f,world,p,first,options,grant,sample:(overrides:any={})=>f.run('inspect',{...options,evaluationDeadlineEpochMilliseconds:Date.now()+10000,qwenCodePayloadSample:grant,...overrides})};
}
