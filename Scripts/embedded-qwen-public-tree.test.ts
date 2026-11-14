import {expect,test} from 'bun:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {ownedRaw} from './embedded-qwen-authored-source-fixture';
const current=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-authored-source.js',import.meta.url),'utf8');
const beforeExtra=readFileSync(new URL('./fixtures/qwen-authored-source-before454.js',import.meta.url),'utf8');
const before=beforeExtra.replace('require(depth <= 10);','require(depth <= 8);');
const traced=before.replace('require(depth <= 8);',"if(depth>8)window.__treeReject={guard:'depth',depth}; require(depth <= 8);");
const raw=JSON.stringify({type:'message',text:'Synthetic whole raw ANSWER'});
const nv=(p:any)=>p.current.children.props.children[0].props.children;

test('pinned public CY wrappers require depth10 including the skipped leaf and preserve one-shot whole source',async()=>{
 expect(current.match(/require\(depth <= 10\);/g)?.length).toBe(1);
 expect(createHash('sha256').update(before).digest('hex')).toBe('c5594d94314d50f9d71dca8a8d833761af8ef2f05da659ca4d30f31e0584e470');
 // Current-host.children: rightDIV0/array1/Fragment2/NV3/array4/maparray5/
 // phaseFragment6/div7/$W8/PG9/undefined10. No downloaded code is executed.
 for(const source of [before,traced]){
  const t=await ownedRaw(raw,undefined,undefined,'inspect',false,source);
  expect(t.first.error).toBe('unsupported_response_format');expect(t.first.detail).toBe('authored_source');
  expect(t.first.adapterFailureStructure.rawSource).toEqual({version:1,stage:'element_tree',kind:'guard',phaseCount:null,phaseOverflow:null,answersSeen:null});
  expect(t.first.text).toBeUndefined();expect(t.first.qwenCodePayload).toBeUndefined();
  if(source===traced)expect(t.f.window.__treeReject).toEqual({guard:'depth',depth:9});
  expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(a=>a.clicks===0)).toBe(true);
 }
 const t=await ownedRaw(raw);expect(t.first.error).toBeUndefined();expect((await t.sample()).text).toBe(raw);
 expect((await t.sample()).error).toBeTruthy();expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(a=>a.clicks===0)).toBe(true);
});

test('supported depth keeps malformed trees, prose children, caps, multiple ANSWER, parent and source drift refused',async()=>{
 for(const cause of ['prose','portal','foreignMessage','duplicateAnswer','parent','accessor','arrayCap','depthCap','visitCap']){
  let calls=0;
  const t=await ownedRaw(raw,p=>{
   if(cause==='prose')nv(p).props.children.unshift('Synthetic unsupported prose child');
   if(cause==='portal')nv(p).props.children.unshift({$$typeof:Symbol.for('react.portal'),props:{}});
   if(cause==='foreignMessage')nv(p).props.children.unshift(p.element({message:{...p.message,id:crypto.randomUUID()}}));
   if(cause==='duplicateAnswer')p.message.content_list.push({...p.answer,content:''});
   if(cause==='parent')p.message.parentId=crypto.randomUUID();
   if(cause==='accessor')Object.defineProperty(nv(p).props,'children',{get(){calls++;throw Error('PRIVATE');},enumerable:true});
   if(cause==='arrayCap')p.current.children=Array(65).fill(null);
   if(cause==='depthCap')p.current.children=p.element({children:p.current.children});
   if(cause==='visitCap')nv(p).props.children=Array(64).fill(p.element({}));
  });
  expect(calls,cause).toBe(0);expect(t.first.error,cause).toBe('unsupported_response_format');expect(t.first.text,cause).toBeUndefined();expect(t.first.qwenCodePayload,cause).toBeUndefined();
  const stages:any={prose:'element_tree_nodekind_string',portal:'element_tree_kind',foreignMessage:'element_tree_message_set_multiple',duplicateAnswer:'answer_count',parent:'message_identity',accessor:'element_tree_children',arrayCap:'element_tree_array',depthCap:'element_tree_depth',visitCap:'element_tree_budget'};
  expect(t.first.adapterFailureStructure.rawSource.stage,cause).toBe(stages[cause]);
  expect(t.world.delegated(),cause).toBe(0);expect(t.f.actions.every(a=>a.clicks===0),cause).toBe(true);
 }
 const t=await ownedRaw(raw);(t.f.answer as any).__reactProps$fixture={...t.p.current};
 expect((await t.sample()).error).toBeTruthy();expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(a=>a.clicks===0)).toBe(true);
});
