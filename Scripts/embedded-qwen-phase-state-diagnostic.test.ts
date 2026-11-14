import {expect,test} from 'bun:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {ownedRaw} from './embedded-qwen-authored-source-fixture';
const before=readFileSync(new URL('./fixtures/qwen-authored-source-before457.js',import.meta.url),'utf8');
const current=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-authored-source.js',import.meta.url),'utf8');
const raw=JSON.stringify({type:'message',text:'Whole synthetic source [[12]] λ😀\n\t'});
const observed=(source:string)=>source.replace('const descriptor = Object.getOwnPropertyDescriptor,',
 `const descriptor=(object,key)=>{(window.__descriptorOrder??=[]).push(String(key));if(object===window.__watchedPart&&['role','status','extra'].includes(key))(window.__phaseOrder??=[]).push('own-'+key);return Object.getOwnPropertyDescriptor(object,key);},`)
 .replaceAll("[undefined,'assistant'].includes",`({get includes(){(window.__phaseOrder??=[]).push('lookup-role');return value=>{window.__phaseOrder.push('call-role');return value===undefined||value==='assistant';};}}).includes`)
 .replaceAll("[undefined,'typing','finished'].includes",`({get includes(){(window.__phaseOrder??=[]).push('lookup-status');return value=>{window.__phaseOrder.push('call-status');return value===undefined||value==='typing'||value==='finished';};}}).includes`);
type Counters={calls:number};
const values:(counter:Counters)=>[any,string][] = counter=>[
 [null,'null'],['','value_empty'],['PRIVATE_UNKNOWN_STRING','value_other_string'],[true,'type_boolean'],[17,'type_number'],
 [17n,'type_bigint'],[Symbol('PRIVATE_SYMBOL'),'type_symbol'],
 [function PRIVATE_FUNCTION(){counter.calls++;throw Error('PRIVATE_FUNCTION');},'type_function'],
 [{get valueOf(){counter.calls++;throw Error('PRIVATE_VALUE_GETTER');}},'type_object'],[[], 'type_object']
];

test('cached role and status buckets preserve lookup, DATA read, call order, short circuit and the old rejection',async()=>{
 expect(createHash('sha256').update(before).digest('hex')).toBe('cb09eaa1dde2efae24b9270b6680da1e34efc1e8755c5022c129f1a128ea5c75');
 for(const field of ['role','status'] as const){
  const specific=field==='role'?['user','system','developer','tool','function']:['waiting_input','error','pause'];
  const tags=[...specific.map(value=>[value,'value_'+value] as [any,string]),...values({calls:0})];
  for(const [caseIndex,[value,tag]] of tags.entries()){
   const counters=[{calls:0},{calls:0}];const results:any[]=[];
   for(const [index,source] of [before,current].entries()){
    const t=await ownedRaw(raw,(p,f)=>{
     // Build each inert value afresh so counters really observe any attempted
     // function invocation or value/member coercion in this read.
     const offset=caseIndex-specific.length;
     p.answer[field]=offset>=0?values(counters[index])[offset][0]:value;f.window.__watchedPart=p.answer;
    },undefined,'inspect',false,observed(source));
    expect(t.first.error).toBe('unsupported_response_format');expect(t.first.detail).toBe('authored_source');
    const diagnostic=t.first.adapterFailureStructure.rawSource;
    expect(diagnostic).toEqual({version:1,stage:source===before?'phase_state':`phase_${field}_${tag}`,kind:'guard',phaseCount:2,phaseOverflow:false,answersSeen:1});
    const order=t.f.window.__phaseOrder,roleAt=order.indexOf('own-role');
    expect(order.slice(roleAt-1,roleAt+2)).toEqual(['lookup-role','own-role','call-role']);
    if(field==='role'){expect(order.includes('own-status')).toBe(false);expect(order.includes('own-extra')).toBe(false);}
    else {const at=order.indexOf('own-status');expect(order.slice(at-1,at+2)).toEqual(['lookup-status','own-status','call-status']);expect(order.includes('own-extra')).toBe(false);}
    expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();expect(JSON.stringify(t.first)).not.toContain('PRIVATE');
    expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
    results.push({order,descriptors:t.f.window.__descriptorOrder});
   }
   expect(results[1]).toEqual(results[0]);expect(counters).toEqual([{calls:0},{calls:0}]);
  }
 }
 for(const field of ['role','status'] as const)for(const cause of ['accessor','exception']){
  const results:any[]=[];let getters=0;
  for(const source of [before,current]){
   const t=await ownedRaw(raw,(p,f)=>{
    if(cause==='accessor')Object.defineProperty(p.answer,field,{get(){getters++;throw Error('PRIVATE_GETTER');},enumerable:true});
    else p.message.content_list[1]=new Proxy(p.answer,{getOwnPropertyDescriptor(target,key){if(key===field)throw Error('PRIVATE_DESCRIPTOR_EXCEPTION');return Reflect.getOwnPropertyDescriptor(target,key);}});
    f.window.__watchedPart=p.message.content_list[1];
   },undefined,'inspect',false,observed(source));
   expect(t.first.error).toBe('unsupported_response_format');expect(t.first.adapterFailureStructure.rawSource).toEqual({version:1,stage:source===before?'phase_state':`phase_${field}_read`,kind:cause==='accessor'?'guard':'exception',phaseCount:2,phaseOverflow:false,answersSeen:1});
   const at=t.f.window.__phaseOrder.indexOf('own-'+field);expect(t.f.window.__phaseOrder.slice(at-1)).toEqual(['lookup-'+field,'own-'+field]);
   expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();expect(t.world.delegated()).toBe(0);
   results.push({order:t.f.window.__phaseOrder,descriptors:t.f.window.__descriptorOrder});
  }
  expect(results[1]).toEqual(results[0]);expect(getters).toBe(0);
 }
});

test('a later reasoning record can fail after one ANSWER without reading reasoning and no valid source shape changes',async()=>{
 for(const source of [before,current]){
  const t=await ownedRaw(raw,(p,f)=>{
   const summaries=Array.from({length:19},(_,index)=>{const part=Object.create(Object.getPrototypeOf(p.hidden),Object.getOwnPropertyDescriptors(p.hidden));part.groupIndex=index+1;return part;});
   summaries[18].status='pause';p.message.content_list=[p.answer,...summaries];p.input.phaseContentIndex=0;
   const nv=p.current.children.props.children[0].props.children;
   const phase=p.element({children:p.element({children:p.element({message:p.message,phase:'answer',children:p.element(p.input)})})});
   nv.props.children[2]=[phase,...summaries.map(part=>p.element({message:p.message,phaseContent:part,contentList:p.message.content_list}))];
   f.window.__watchedPart=summaries[18];
  },undefined,'inspect',false,observed(source));
  expect(t.first.error).toBe('unsupported_response_format');expect(t.first.adapterFailureStructure.rawSource).toEqual({version:1,stage:source===before?'phase_state':'phase_status_value_pause',kind:'guard',phaseCount:20,phaseOverflow:false,answersSeen:1});
  expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();expect(t.world.delegated()).toBe(0);
 }
 for(const source of [before,current])for(const role of [undefined,'assistant'])for(const status of [undefined,'typing','finished']){
  const t=await ownedRaw(raw,p=>{p.hidden.role=role;p.hidden.status=status;p.answer.status=status;},undefined,'inspect',false,source);
  expect(t.first.error).toBeUndefined();expect((await t.sample()).text).toBe(raw);expect((await t.sample()).error).toBeTruthy();
  expect(t.first.adapterFailureStructure).toBeUndefined();expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
 }
});

test('legacy phase_state stays readable while forged partial-count or value fields cannot survive the closed bridge',async()=>{
 for(const variation of ['legacy','unknown','countNull','countZero','overflow','seenNull','private']){
  const t=await ownedRaw(raw,p=>{p.answer.status='pause';},value=>{
   if(value.op!=='candidate'||value.eligible!==false)return value;
   const diagnostic={...value.diagnostic};
   if(variation==='legacy')diagnostic.stage='phase_state';if(variation==='unknown')diagnostic.stage='phase_status_PRIVATE';
   if(variation==='countNull'){diagnostic.phaseCount=null;diagnostic.phaseOverflow=null;diagnostic.answersSeen=null;}
   if(variation==='countZero'){diagnostic.phaseCount=0;diagnostic.answersSeen=0;}
   if(variation==='overflow'){diagnostic.phaseCount=33;diagnostic.phaseOverflow=true;}
   if(variation==='seenNull')diagnostic.answersSeen=null;if(variation==='private')diagnostic.status='PRIVATE_STATUS';
   return {...value,diagnostic};
  });
  expect(t.first.error).toBe('unsupported_response_format');expect(t.first.detail).toBe('authored_source');
  if(variation==='legacy')expect(t.first.adapterFailureStructure.rawSource.stage).toBe('phase_state');
  else expect(t.first.adapterFailureStructure.rawSource).toBeUndefined();
  expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();expect(JSON.stringify(t.first)).not.toContain('PRIVATE');
  expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
 }
});
