import {expect,test} from 'bun:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {ownedRaw} from './embedded-qwen-authored-source-fixture';
const before=readFileSync(new URL('./fixtures/qwen-authored-source-before456.js',import.meta.url),'utf8');
const current=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-authored-source.js',import.meta.url),'utf8');
const raw=JSON.stringify({type:'message',text:'Whole synthetic ANSWER [[12]] λ😀\n\t'});
const observed=(source:string)=>source.replace('const descriptor = Object.getOwnPropertyDescriptor,',
  'const descriptor=(object,key)=>{(window.__treeReads??=[]).push(String(key));return Object.getOwnPropertyDescriptor(object,key);},')
 .replace('const messages = new Set(),',`const messages = new (class extends Set {get size(){window.__setSizeReads=(window.__setSizeReads??0)+1;return super.size;}})(),`);
const cases=[
 ['budget','budget'],['depth','depth'],['nodekind','nodekind_string'],['number','nodekind_number'],['bigint','nodekind_bigint'],['symbol','nodekind_symbol'],['function','nodekind_function'],['array','array'],['elementshape','elementshape'],
 ['kind','kind'],['kindGetter','kind'],['props','props'],['propsGetter','props'],['propsException','props'],
 ['message','message'],['editflags','editflags'],['renderflags','editflags'],['children','children'],
 ['message_set','message_set_multiple'],['no_message','message_set_empty'],['indexGetter','props'],['hostChildrenGetter','children'],['hostChildrenMissing','children']
] as const;
const nv=(p:any)=>p.current.children.props.children[0].props.children;
function mutate(kind:string,p:any,counter:{getters:number}) {
 const getter=()=>{counter.getters++;throw Error('PRIVATE_GETTER_MUST_NOT_RUN');};
 if(kind==='budget')nv(p).props.children=Array(64).fill(p.element({}));
 if(kind==='depth')p.current.children=p.element({children:p.current.children});
 if(kind==='nodekind')nv(p).props.children.unshift('PRIVATE_NONEMPTY_TEXT');
 if(kind==='number')nv(p).props.children.unshift(42);
 if(kind==='bigint')nv(p).props.children.unshift(42n);
 if(kind==='symbol')nv(p).props.children.unshift(Symbol('PRIVATE_SYMBOL'));
 if(kind==='function')nv(p).props.children.unshift(function PRIVATE_FUNCTION(){counter.getters++;throw Error('PRIVATE_FUNCTION_MUST_NOT_RUN');});
 if(kind==='array')p.current.children=Array(65).fill(null);
 if(kind==='elementshape')p.current.children=new Date(0);
 if(kind==='kind')p.current.children={$$typeof:Symbol.for('react.portal'),props:{}};
 if(kind==='kindGetter'){const node=p.element({});Object.defineProperty(node,'$$typeof',{get:getter,enumerable:true});p.current.children=node;}
 if(kind==='props')p.current.children=p.element(new Date(0));
 if(kind==='propsGetter'){const node=p.element({});Object.defineProperty(node,'props',{get:getter,enumerable:true});p.current.children=node;}
 if(kind==='propsException')p.current.children=new Proxy(p.element({}),{getOwnPropertyDescriptor(target,key){if(key==='props')throw Error('PRIVATE_DESCRIPTOR_EXCEPTION');return Reflect.getOwnPropertyDescriptor(target,key);}});
 if(kind==='message')p.current.children=p.element({message:null});
 if(kind==='editflags')nv(p).props.isEdit='PRIVATE_INVALID_FLAG';
 if(kind==='renderflags')nv(p).props.isRenderEmpty=1;
 if(kind==='children')Object.defineProperty(nv(p).props,'children',{get:getter,enumerable:true});
 if(kind==='message_set')nv(p).props.children.unshift(p.element({message:{id:'PRIVATE_FOREIGN_MESSAGE'}}));
 if(kind==='no_message')p.current.children=p.element({});
 if(kind==='indexGetter')Object.defineProperty(nv(p).props,'phaseContentIndex',{get:getter,enumerable:true});
 if(kind==='hostChildrenGetter')Object.defineProperty(p.current,'children',{get:getter,enumerable:true});
 if(kind==='hostChildrenMissing')delete p.current.children;
}

test('each tree subguard refines only the old refusal and preserves external descriptor read order',async()=>{
 expect(createHash('sha256').update(before).digest('hex')).toBe('b83cf4636e0045ef55dfb120bc6bd942f754af52eafddac1ee82a5c22626f26c');
 expect(current).toContain('let visits = 128;');expect(current).toContain('require(depth <= 10);');
 for(const [cause,tag] of cases){
  const counters=[{getters:0},{getters:0}];
  const old=await ownedRaw(raw,p=>mutate(cause,p,counters[0]),undefined,'inspect',false,observed(before));
  const now=await ownedRaw(raw,p=>mutate(cause,p,counters[1]),undefined,'inspect',false,observed(current));
  expect(old.first.error,cause).toBe('unsupported_response_format');expect(now.first.error,cause).toBe(old.first.error);
  expect(now.first.detail,cause).toBe(old.first.detail);
  const original={...old.first.adapterFailureStructure.rawSource,stage:'element_tree_'+tag};
  expect(now.first.adapterFailureStructure,cause).toEqual({...old.first.adapterFailureStructure,rawSource:original});
  expect(now.first.adapterFailureStructure.rawSource.kind,cause).toBe(cause==='propsException'?'exception':'guard');
  expect(now.f.window.__treeReads,cause).toEqual(old.f.window.__treeReads);expect(counters,cause).toEqual([{getters:0},{getters:0}]);
  const expectedSetReads=['message_set','no_message'].includes(cause)?1:0;
  expect(old.f.window.__setSizeReads??0,cause).toBe(expectedSetReads);expect(now.f.window.__setSizeReads??0,cause).toBe(expectedSetReads);
  for(const t of [old,now]){
   expect(t.first.text,cause).toBeUndefined();expect(t.first.qwenCodePayload,cause).toBeUndefined();
   expect(JSON.stringify(t.first),cause).not.toContain('PRIVATE');expect(t.world.delegated(),cause).toBe(0);
   expect(t.f.actions.every(action=>action.clicks===0),cause).toBe(true);
  }
 }
});

function layout(p:any,count:number,answers:number) {
 const parts=Array.from({length:count},(_,index)=>{
  const source=index>=count-answers?p.answer:p.hidden;
  const part=Object.create(Object.getPrototypeOf(source),Object.getOwnPropertyDescriptors(source));
  part.groupIndex=index;part.timestamp=index+1;return part;
 });
 p.message.content_list=parts;
 nv(p).props.children[2]=parts.map((part:any,index:number)=>part.phase==='answer'
  ?p.element({children:p.element({children:p.element({message:p.message,phase:'answer',children:p.element({message:p.message,phaseContentIndex:index,content:raw})})})})
  :p.element({message:p.message,phaseContent:part,contentList:parts}));
}

test('public 15 and 32 part controls preserve the complete one-ANSWER path without raising any bound',async()=>{
 for(const [count,answers] of [[15,1],[32,1],[15,15],[32,15]] as const){
  const observations:any[]=[];
  for(const source of [before,current]){
   const t=await ownedRaw(raw,p=>layout(p,count,answers),undefined,'inspect',false,observed(source));
   if(answers===1){
    expect(t.first.error).toBeUndefined();expect((await t.sample()).text).toBe(raw);expect((await t.sample()).error).toBeTruthy();
    expect(t.first.adapterFailureStructure).toBeUndefined();
   }else{
    expect(t.first.error).toBe('unsupported_response_format');expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();
    expect(t.first.adapterFailureStructure.rawSource.stage).toBe(count===15?'answer_count':source===before?'element_tree':'element_tree_budget');
   }
   observations.push({reads:t.f.window.__treeReads,setSizeReads:t.f.window.__setSizeReads});expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
  }
  expect(observations[1]).toEqual(observations[0]);
 }
});

test('legacy coarse metadata stays readable while forged tree counts or arbitrary tags cannot survive the closed bridge',async()=>{
 // A non-native size getter must still be read once and must never be coerced
 // merely to classify an already rejected count. No global Set is replaced.
 for(const source of [before,current])for(const kind of ['object','exception']){
  const body=kind==='object'?`return {valueOf(){window.__sizeCoercions=(window.__sizeCoercions??0)+1;throw Error('PRIVATE_COERCION');}};`:`throw Error('PRIVATE_SIZE_GETTER_EXCEPTION');`;
  const instrumented=observed(source).replace('return super.size;',body);
  const t=await ownedRaw(raw,undefined,undefined,'inspect',false,instrumented);
  expect(t.first.error).toBe('unsupported_response_format');expect(t.first.detail).toBe('authored_source');
  expect(t.f.window.__setSizeReads).toBe(1);expect(t.f.window.__sizeCoercions??0).toBe(0);
  expect(t.first.adapterFailureStructure.rawSource.stage).toBe(source===before?'element_tree':'element_tree_message_set');
  expect(t.first.adapterFailureStructure.rawSource.kind).toBe(kind==='object'?'guard':'exception');
  expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();
  expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
 }
 for(const variation of ['legacy','legacyPrimitive','legacyMessages','unknown','phaseCount','phaseOverflow','answersSeen','private']){
  const t=await ownedRaw(raw,p=>mutate('props',p,{getters:0}),value=>{
   if(value.op!=='candidate'||value.eligible!==false)return value;
   const diagnostic={...value.diagnostic};
   if(variation==='legacy')diagnostic.stage='element_tree';
   if(variation==='legacyPrimitive')diagnostic.stage='element_tree_nodekind';
   if(variation==='legacyMessages')diagnostic.stage='element_tree_message_set';
   if(variation==='unknown')diagnostic.stage='element_tree_PRIVATE';
   if(variation==='phaseCount'){diagnostic.phaseCount=0;diagnostic.phaseOverflow=false;}
   if(variation==='phaseOverflow')diagnostic.phaseOverflow=false;
   if(variation==='answersSeen')diagnostic.answersSeen=0;
   if(variation==='private')diagnostic.text='PRIVATE_CONTENT';
   return {...value,diagnostic};
  });
  expect(t.first.error).toBe('unsupported_response_format');expect(t.first.detail).toBe('authored_source');
  if(variation.startsWith('legacy'))expect(t.first.adapterFailureStructure.rawSource.stage).toBe(variation==='legacy'?'element_tree':variation==='legacyPrimitive'?'element_tree_nodekind':'element_tree_message_set');
  else expect(t.first.adapterFailureStructure.rawSource).toBeUndefined();
  expect(JSON.stringify(t.first)).not.toContain('PRIVATE');expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();
  expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
 }
});
