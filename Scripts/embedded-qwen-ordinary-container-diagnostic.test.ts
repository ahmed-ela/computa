import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { fixture, choice, prompt, fingerprint, answerID, generation, raw } from './embedded-qwen-adapter-fixture';

function caught(body: () => unknown): any { try { body(); } catch (error) { return error; } throw Error('expected refusal'); }
function mutate(f: ReturnType<typeof fixture>, kind: string) {
  if (kind === 'zero') f.answer.detach();
  else if (kind === 'hidden') f.answer.setAttribute('hidden', '');
  else {
    f.answerRoot.append(f.answer.cloneNode(true));
    if (kind === 'all-hidden') for (const node of f.answerRoot.children) node.values.hidden = '';
    if (kind === 'saturated') for (let i=0;i<8;i++) f.answerRoot.append(f.answer.cloneNode(true));
  }
}
function noAuthority(result: any) {
  for (const key of ['text','firstUserVerified','firstUserFingerprint','userCount','responseCount','completionEvidence',
    'qwenCodePayload','qwenResponseChoice','qwenInitialResponseIdentityPending','qwenFirstDisplayPending']) expect(result[key], key).toBeUndefined();
}
function safe(packet: any, engine = false) {
  expect(Object.keys(packet).sort()).toEqual(['version','provider','trigger','total','displayed','rootVisible','dual','multi','smrm','cmrm','ancestorLimited','relation','idRelation','containers',...(engine?['firstBodyBound','responseIdentityRetained']:[])].sort());
  expect(packet.total).toBeLessThanOrEqual(3); expect(packet.displayed).toBeLessThanOrEqual(3);
  expect(packet.displayed).not.toBe(1); expect(packet.containers.length).toBe(Math.min(packet.total,2));
  for (const row of packet.containers) { expect(Object.keys(row).sort()).toEqual(['id','visible']); expect(['missing','empty_prefix','uuid','other']).toContain(row.id); }
  const encoded=JSON.stringify(packet); expect(encoded.length).toBeLessThanOrEqual(1024);
  for (const secret of ['PRIVATE', answerID, generation, prompt, raw, 'https://']) expect(encoded).not.toContain(secret);
}
async function sent(model = choice(), initialPending = false) {
  const f=fixture({completeOnSend:false});
  for(let i=0;i<8;i++) if((await f.run('selectModel',{modelChoice:model})).selected) break;
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert',{prompt})).inserted).toBe(true);
  expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);
  const hash=await fingerprint(prompt);
  expect((await f.run('submit',{prompt,savedSubmissionFingerprint:hash})).submitted).toBe(true);
  const grant={expectedModelChoice:model,savedSubmissionFingerprint:hash,...(initialPending?{allowQwenInitialResponseIdentity:true}:{})};
  if(initialPending) {
    f.phase.detach();const loading=new f.Node('DIV',{class:'response-loading'});f.answer.append(loading);f.answer.setAttribute('id','chat-response-message-');
    expect((await f.run('inspect',grant)).qwenInitialResponseIdentityPending).toBe(true);
    f.answer.setAttribute('id','chat-response-message-'+answerID);loading.detach();f.flow.append(f.phase);
  }
  const first=await f.run('inspect',grant);expect(first.firstUserVerified).toBe(true);expect(first.answerComplete).toBe(false);
  return {f,grant,hash};
}

describe('Qwen ordinary response-container failure diagnostics',()=>{
 test('zero, hidden-only, multiple and saturated ordinary reads keep the same refusal with finite counts',()=>{
  for(const kind of ['zero','hidden','two-visible','all-hidden','saturated']) {
   const f=fixture();f.mountConversation();mutate(f,kind);const before=f.mutations();
   const error=caught(()=>f.read().transcript());
   expect(error.error,kind).toBe('document_changed');expect(error.detail,kind).toBe('response_container');
   const p=error.adapterFailureStructure;safe(p);expect(p.trigger).toBe('response_container');expect(p.rootVisible).toBe(true);
   expect(p.total).toBe(kind==='zero'?0:kind==='hidden'?1:kind==='saturated'?3:2);
   expect(p.displayed).toBe(['zero','hidden','all-hidden'].includes(kind)?0:kind==='saturated'?3:2);
   expect(p.relation).toBe(kind==='zero'?'none':kind==='hidden'?'single':'siblings');
   expect(f.mutations()).toBe(before);
  }
 });
 test('a bound first-body ordinary failure remains terminal with no action, reply or cleanup authority for Plus and Max',async()=>{
  for(const label of ['Qwen3.7-Plus','Qwen3.8-Max']) for(const kind of ['zero','hidden','two-visible','all-hidden','saturated']) {
   const {f,grant}=await sent(choice(label)),state=f.world.__computaQwenSavedSessionV1,first=state.first;
   mutate(f,kind);const before=f.mutations(),result=await f.run('inspect',grant);
   expect(result.error,label+kind).toBe('document_changed');expect(result.detail).toBe('response_container');safe(result.adapterFailureStructure,true);expect(result.adapterFailureStructure.firstBodyBound).toBe(true);expect(result.adapterFailureStructure.responseIdentityRetained).toBe(false);noAuthority(result);
   expect(state.first).toBe(first);expect(state.terminal).toBe(true);expect(state.responseChoice).toBeUndefined();
   expect(f.mutations()).toBe(before);expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);expect(f.actions[0].clicks).toBe(0);
   expect((await f.run('inspect',grant)).detail).toBe('terminal_operation');
   expect((await f.run('inspect',{...grant,savedCleanupInspection:true})).detail).toBe('terminal_operation');
   expect(f.more.clicks).toBe(0);expect(f.send.clicks).toBe(1);
  }
 });
 test('retained initial response identity is reported only as a boolean after its later ordinary rejection',async()=>{
  const {f,grant}=await sent(choice(),true);expect(f.world.__computaQwenSavedSessionV1.responseIdentity).toBeTruthy();
  f.answerRoot.append(f.answer.cloneNode(true));const r=await f.run('inspect',grant);
  expect(r.error).toBe('document_changed');expect(r.detail).toBe('response_container');safe(r.adapterFailureStructure,true);
  expect(r.adapterFailureStructure.firstBodyBound).toBe(true);expect(r.adapterFailureStructure.responseIdentityRetained).toBe(true);noAuthority(r);expect(f.send.clicks).toBe(1);
 });
 test('one displayed container plus hidden extras retains existing success and never reads diagnostic-only attributes',()=>{
  const f=fixture();f.mountConversation();const hidden=f.answer.cloneNode(true);hidden.values.hidden='';
  const get=hidden.getAttribute.bind(hidden);hidden.getAttribute=(name:string)=>{if(name==='id')throw Error('diagnostic must not run on success');return get(name);};f.answerRoot.append(hidden);
  const before=f.mutations(),result=f.read().transcript();expect(result.answer.content).toBe(f.answer);expect(result.answer.id).toBe(answerID);
  expect((result as any).adapterFailureStructure).toBeUndefined();expect(f.mutations()).toBe(before);
 });
 test('only finite ancestry and ID categories are retained; reply text and descendants are never read',()=>{
  for(const kind of ['smrm','cmrm','nested']) {
   const f=fixture();f.mountConversation();const other=f.answer.cloneNode(true);other.values.id='PRIVATE_ID';
   if(kind==='nested') f.answer.append(other);
   else {const wrapper=new f.Node('DIV',{class:kind+' PRIVATE_CLASS'}),left=new f.Node('DIV'),right=new f.Node('DIV');f.answer.detach();left.append(f.answer);right.append(other);wrapper.append(left,right);f.answerRoot.append(wrapper);}
   for(const node of [f.answer,other]) Object.defineProperty(node,'textContent',{get(){throw Error('PRIVATE_TEXT');}});
   f.answerRoot.setAttribute('class','qwen-chat-message qwen-chat-message-assistant qwen-chat-message-dual-message qwen-chat-message-multi-message');
   const p=caught(()=>f.read().transcript()).adapterFailureStructure;safe(p);expect(p.smrm).toBe(kind==='smrm');expect(p.cmrm).toBe(kind==='cmrm');
   expect(p.dual).toBe(true);expect(p.multi).toBe(true);expect(p.relation).toBe(kind==='nested'?'nested':'other');expect(p.idRelation).toBe('other');expect(p.containers[1].id).toBe('other');
  }
 });
 test('ancestor work is limited to two selected nodes and at most64 parents each',()=>{
  const f=fixture();f.mountConversation();f.answer.detach();const other=f.answer.cloneNode(true);let parent=f.answerRoot;
  for(let i=0;i<80;i++){const next=new f.Node('DIV',{class:i===0?'smrm':''});parent.append(next);parent=next;}
  parent.append(f.answer,other);let reads=0;
  for(const node of f.answerRoot.descendants().filter(node=>node!==f.answer&&node!==other)) {const cls=node.classList;Object.defineProperty(node,'classList',{get(){return{contains:(value:string)=>{if(['smrm','cmrm'].includes(value))reads++;return cls.contains(value);}}}});}
  const p=caught(()=>f.read().transcript()).adapterFailureStructure;safe(p);expect(p.ancestorLimited).toBe(true);expect(p.smrm).toBe(false);expect(reads).toBeLessThanOrEqual(256);
 });
 test('diagnostic exceptions discard partial metadata and preserve the ordinary rejection',async()=>{
  for(const kind of ['id','root-class']){
   const {f,grant}=await sent();f.answerRoot.append(f.answer.cloneNode(true));
   if(kind==='id'){const get=f.answer.getAttribute.bind(f.answer);f.answer.getAttribute=(name:string)=>{if(name==='id')throw Error('PRIVATE_ATTRIBUTE');return get(name);};}
   else {const cls=f.answerRoot.classList;Object.defineProperty(f.answerRoot,'classList',{get(){return{contains:(name:string)=>{if(name==='qwen-chat-message-dual-message')throw Error('PRIVATE_CLASS');return cls.contains(name);}}}});}
   const before=f.mutations(),r=await f.run('inspect',grant);expect(r.error).toBe('document_changed');expect(r.detail).toBe('response_container');expect(r.adapterFailureStructure).toBeUndefined();noAuthority(r);expect(f.mutations()).toBe(before);expect(f.send.clicks).toBe(1);
  }
 });
 test('the exact uniqueness error object is rethrown once, including failed diagnostic reads and foreign errors',()=>{
  const source=readFileSync(new URL('./EmbeddedSavedProviders/qwen-dom.js',import.meta.url),'utf8');
  const body=source.slice(source.indexOf('  function ordinaryResponseContainer('),source.indexOf('  function responseChoice('));
  for(const kind of ['safe','diagnostic-throw','foreign','primitive']) {
   const original:any=kind==='primitive'?42:kind==='foreign'?new Error('foreign'):{computaAdapterFailure:true,error:'document_changed',detail:'response_container'};
   let calls=0,reads=0;const one=(values:any[],reason:string)=>{calls++;expect(values).toEqual([]);expect(reason).toBe('response_container');throw original;};
   const c={visible:()=>{reads++;if(kind==='diagnostic-throw')throw Error('PRIVATE');return true;}};
   const helper=new Function('one','c',body+';return ordinaryResponseContainer;')(one,c);
   const root={classList:{contains:()=>false}};expect(caught(()=>helper(root,[],[]))).toBe(original);expect(calls).toBe(1);
   if(kind==='safe')expect(original.adapterFailureStructure.total).toBe(0);else if(typeof original==='object')expect(original.adapterFailureStructure).toBeUndefined();
   if(['foreign','primitive'].includes(kind))expect(reads).toBe(0);
  }
 });
 test('other failure reasons do not acquire ordinary-container metadata',async()=>{
  const {f,grant}=await sent();f.userContainer.setAttribute('data-chat-id',generation);const r=await f.run('inspect',grant);
  expect(r.detail).toBe('first_user_message');expect(r.adapterFailureStructure).toBeUndefined();expect(f.send.clicks).toBe(1);
 });
});
