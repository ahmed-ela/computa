import {expect,test} from 'bun:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {ownedRaw} from './embedded-qwen-authored-source-fixture';
import {choice} from './embedded-qwen-adapter-fixture';
const before=readFileSync(new URL('./fixtures/qwen-authored-source-before454.js',import.meta.url),'utf8');
const current=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-authored-source.js',import.meta.url),'utf8');
const raw=JSON.stringify({type:'message',text:'Synthetic whole ANSWER [[12]] λ😀\n\t'});
const observed=(source:string)=>source.replace('const descriptor = Object.getOwnPropertyDescriptor,',
 `const descriptor = (object,key)=>{const d=Object.getOwnPropertyDescriptor(object,key);return d&&object===window.__summaryExtra&&['summary_title','summary_thought','summary_content'].includes(key)?new Proxy(d,{get(target,field){if(field==='value')window.__summaryValueReads++;return Reflect.get(target,field);}}):d;},`);
const metadata=()=>({summary_title:{content:['SECRET_REASONING_TITLE']},summary_thought:{content:['SECRET_REASONING_THOUGHT']},summary_content:'SECRET_REASONING_LEGACY'});

test('known public summary DATA keys are opaque and preserve one complete ANSWER after the old phase_extra refusal',async()=>{
 expect(createHash('sha256').update(before).digest('hex')).toBe('657e45104061cd197ea1eda059ff981188ae6637af4ac12d8911bfc7102c2b0b');
 for(const [reader,accepted] of [[before,false],[current,true]] as const){
  let nested=0;
  const t=await ownedRaw(raw,(p,f)=>{const extra=metadata();
   Object.defineProperty(extra.summary_title,'content',{get(){nested++;throw Error('SECRET_REASONING_TITLE');},enumerable:true});
   Object.defineProperty(extra.summary_thought,'content',{get(){nested++;throw Error('SECRET_REASONING_THOUGHT');},enumerable:true});
   p.hidden.extra=extra;f.window.__summaryExtra=extra;f.window.__summaryValueReads=0;
  },undefined,'inspect',false,observed(reader));
  if(!accepted){
   expect(t.first.error).toBe('unsupported_response_format');expect(t.first.detail).toBe('authored_source');
   expect(t.first.adapterFailureStructure.rawSource).toEqual({version:1,stage:'phase_extra',kind:'guard',phaseCount:2,phaseOverflow:false,answersSeen:0});
   expect(t.first.qwenCodePayload).toBeUndefined();expect(t.first.text).toBeUndefined();
  }else{
   expect(t.first.error).toBeUndefined();const result=await t.sample();expect(result.text).toBe(raw);
   expect(JSON.stringify(result)).not.toContain('SECRET_REASONING');expect((await t.sample()).error).toBeTruthy();
  }
  expect(nested).toBe(0);expect(t.f.window.__summaryValueReads).toBe(0);
  expect(JSON.stringify(t.first)).not.toContain('SECRET_REASONING');expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(a=>a.clicks===0)).toBe(true);
 }
});

test('reasoning empty representations contain no ignored payload while ANSWER representation stays unchanged',async()=>{
 for(const phase of ['think','thinking_summary'])for(const extra of [undefined,null,{},'',[]]){
  const t=await ownedRaw(raw,p=>{p.hidden.phase=phase;p.hidden.extra=extra;});
  expect(t.first.error).toBeUndefined();expect((await t.sample()).text).toBe(raw);expect(t.world.delegated()).toBe(0);
  if(extra===''||Array.isArray(extra)){
   const old=await ownedRaw(raw,p=>{p.hidden.phase=phase;p.hidden.extra=extra;},undefined,'inspect',false,before);
   expect(old.first.adapterFailureStructure.rawSource.stage).toBe('phase_extra');expect(old.first.error).toBe('unsupported_response_format');
  }
 }
 for(const extra of ['',[],metadata()]){
  const t=await ownedRaw(raw,p=>{p.answer.extra=extra;});expect(t.first.error).toBe('unsupported_response_format');
  expect(t.first.adapterFailureStructure.rawSource.stage).toBe('phase_extra');expect(t.first.text).toBeUndefined();expect(t.world.delegated()).toBe(0);
 }
});

test('unknown, accessor, media/tool/update, prose and nonempty THINK extras cannot become source or action authority',async()=>{
 for(const kind of ['unknown','alternating','getter','extraGetter','media','tool','update','prose','array','think','symbol','parent','multiple']){
  let calls=0;
  const t=await ownedRaw(raw,p=>{
   p.hidden.extra=metadata();
   if(kind==='unknown')p.hidden.extra.other='SECRET';
   if(kind==='alternating'){
    const target={...metadata(),unknown:'SECRET'};let views=0;
    p.hidden.extra=new Proxy(target,{ownKeys(object){const names=Reflect.ownKeys(object);return ++views<=2?names:names.filter(key=>key!=='unknown');}});
   }
   if(kind==='getter')Object.defineProperty(p.hidden.extra,'summary_title',{get(){calls++;throw Error('SECRET');},enumerable:true});
   if(kind==='extraGetter')Object.defineProperty(p.hidden,'extra',{get(){calls++;throw Error('SECRET');},enumerable:true});
   if(kind==='media')p.hidden.extra.file_list=[];
   if(kind==='tool')p.hidden.extra.tool_result={};
   if(kind==='update')p.hidden.extra.update_member=false;
   if(kind==='prose')p.hidden.extra='SECRET copied prose';
   if(kind==='array')p.hidden.extra=['SECRET'];
   if(kind==='think')p.hidden.phase='think';
   if(kind==='symbol')p.hidden.extra[Symbol('SECRET')]=true;
   if(kind==='parent')p.message.parentId=crypto.randomUUID();
   if(kind==='multiple')p.message.content_list.push({...p.answer,content:''});
  });
  expect(calls,kind).toBe(0);expect(t.first.error,kind).toBe('unsupported_response_format');expect(t.first.text,kind).toBeUndefined();expect(t.first.qwenCodePayload,kind).toBeUndefined();
  expect(t.world.delegated(),kind).toBe(0);expect(t.f.actions.every(a=>a.clicks===0),kind).toBe(true);
 }
 const changed=await ownedRaw(raw,p=>{p.hidden.extra=metadata();});changed.p.answer.content+='changed';
 expect((await changed.sample()).error).toBeTruthy();expect(changed.world.delegated()).toBe(0);
 const model=await ownedRaw(raw,p=>{p.hidden.extra=metadata();});
 expect((await model.sample({expectedModelChoice:choice('Qwen3.8-Max')})).error).toBeTruthy();expect(model.world.delegated()).toBe(0);
});
