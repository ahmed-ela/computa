import { describe, expect, test } from 'bun:test';
import { fixture, choice, prompt, marker, generation, ownerToken, fingerprint, conversationID, answerID, userID, raw } from './embedded-qwen-adapter-fixture';
const canonical = 'https://chat.qwen.ai/c/' + conversationID;
const receipt = { qwenInitialResponseIdentityPending: true, url: canonical, sessionLifecycle: 'saved_conversation_delete', temporary: false };
async function sent(model = choice()) {
  const f = fixture({ completeOnSend: false });
  for (let i=0;i<8;i++) { const r=await f.run('selectModel',{modelChoice:model}); expect(r.error).toBeUndefined(); if(r.selected)break; }
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert',{prompt})).inserted).toBe(true);
  expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);
  const hash=await fingerprint(prompt);
  expect((await f.run('submit',{prompt,savedSubmissionFingerprint:hash})).submissionAcknowledgement).toEqual({ownerToken,documentGeneration:generation,sequence:1,outboundFingerprint:hash});
  f.phase.detach(); const loading=new f.Node('DIV',{class:'response-loading'});f.answer.append(loading);
  f.answer.setAttribute('id','chat-response-message-');
  const grant={allowQwenInitialResponseIdentity:true,expectedModelChoice:model,savedSubmissionFingerprint:hash};
  const settle=()=>{ f.answer.setAttribute('id','chat-response-message-'+answerID);loading.detach();f.flow.append(f.phase);f.complete(); };
  return {f,hash,grant,loading,settle};
}
describe('Qwen initial empty assistant identity',()=>{
 test('observed canonical empty suffix is negative only, then same-node UUID restores strict proof',async()=>{
  const {f,hash,grant,settle}=await sent(),before=f.mutations();
  expect(await f.run('inspect',grant)).toEqual(receipt);expect(await f.run('inspect',grant)).toEqual(receipt);
  expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(f.mutations()).toBe(before);
  settle(); const r=await f.run('inspect',grant);
  expect(r.error).toBeUndefined();expect(r.firstUserVerified).toBe(true);expect(r.firstUserFingerprint).toBe(hash);
  expect(r.modelEvidence.selected).toEqual(choice());expect(r.answerComplete).toBe(true);expect(r.text).toBe(raw);expect(f.send.clicks).toBe(1);
 });
 test('ID-only settlement produces a wakeup without proof or a new mutation',async()=>{
  const {f,grant}=await sent();expect(await f.run('inspect',grant)).toEqual(receipt);
  const before=f.signals.length;f.answer.setAttribute('id','chat-response-message-'+answerID);f.notifyAttribute('id');
  expect(f.signals.length).toBe(before+1);expect(f.signals.at(-1)).toEqual({ownerToken,kind:'dom_changed'});
  expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(f.send.clicks).toBe(1);
  const r=await f.run('inspect',grant);expect(r.firstUserVerified).toBe(true);expect(r.answerComplete).toBe(false);expect(r.text).toBe('');
 });
 test('provisional pending transitions through canonical empty ID without changing the Send claim',async()=>{
  const {f,grant,hash,settle}=await sent();f.document.URL='https://chat.qwen.ai/c/new-chat';
  expect((await f.run('inspect',{...grant,allowQwenProvisionalRoute:true})).qwenProvisionalRoutePending).toBe(true);
  f.document.URL=canonical;expect(await f.run('inspect',grant)).toEqual(receipt);settle();
  expect((await f.run('inspect',grant)).firstUserFingerprint).toBe(hash);expect(f.send.clicks).toBe(1);
 });
 test('ordinary DOM transcript remains strict',async()=>{
  const {f}=await sent();expect(()=>f.read().transcript()).toThrow();
  expect((await f.run('inspect')).error).toBeDefined();expect(f.send.clicks).toBe(1);
 });
 test('native grant, exact body, marker, fingerprint, model, generation and first binding required',async()=>{
  for(const over of [{allowQwenInitialResponseIdentity:false},{savedSubmissionFingerprint:'0'.repeat(64)},{savedSubmissionFingerprint:undefined},
   {expectedModelChoice:choice('Qwen3.8-Max')},{expectedFirstUserMarker:generation},{expectedFirstUserFingerprint:'a'.repeat(64)},
   {allowFirstUserBinding:false},{savedCleanupInspection:true},{ownerToken:generation},{documentGeneration:ownerToken},{expectedUserCounts:[0]}]){
   const {f,grant}=await sent();const r=await f.run('inspect',{...grant,...over});expect(r.error).toBeDefined();expect(r.qwenInitialResponseIdentityPending).toBeUndefined();expect(r.text).toBeUndefined();expect(f.send.clicks).toBe(1);
  }
 });
 test('only exact empty prefix in the observed active loading shape is eligible',async()=>{
  for(const mutation of ['missing-id','bad-id','user-id','no-stop','wrong-stop','no-loading','duplicate-loading','answer-phase','footer','body','model-label','model-node','wrong-chat','hidden-answer','wrong-outer','wrong-order','duplicate-answer','duplicate-user']){
   const {f,grant,loading}=await sent();
   if(mutation==='missing-id')f.answer.removeAttribute('id');if(mutation==='bad-id')f.answer.setAttribute('id','chat-response-message-x');
   if(mutation==='user-id')f.answer.setAttribute('id','chat-response-message-'+userID);
   if(mutation==='no-stop')f.stop.detach();if(mutation==='wrong-stop')f.stop.setAttribute('data-chat-id',generation);
   if(mutation==='no-loading')loading.detach();if(mutation==='duplicate-loading')f.answer.append(loading.cloneNode(true));
   if(mutation==='answer-phase')f.flow.append(f.phase);if(mutation==='footer')f.complete();
   if(mutation==='body')f.userBody.text+=' changed';if(mutation==='model-label')f.modelName.text='Qwen3.8-Max';
   if(mutation==='model-node'){f.trigger.detach();f.body.append(f.trigger.cloneNode(true));}
   if(mutation==='wrong-chat')f.userContainer.setAttribute('data-chat-id',generation);
   if(mutation==='hidden-answer')f.answerRoot.setAttribute('hidden','');
   if(mutation==='wrong-outer'){f.answerRoot.parentElement!.detach();f.body.append(f.answerRoot);}
   if(mutation==='wrong-order')f.turn.children.reverse();
   if(mutation==='duplicate-answer')f.turn.append(f.answerRoot.cloneNode(true));if(mutation==='duplicate-user')f.turn.append(f.root.cloneNode(true));
   const r=await f.run('inspect',grant);expect(r.error,mutation).toBeDefined();expect(r.qwenInitialResponseIdentityPending).toBeUndefined();expect(r.text).toBeUndefined();
  }
 });
 test('retained physical nodes, full body, canonical URL and model cannot change while pending or during settlement',async()=>{
  for(const when of ['pending','settled'])for(const mutation of ['user-root','user-body','answer-root','answer-content','body-text','route','model']){
   const {f,grant,settle}=await sent();expect(await f.run('inspect',grant)).toEqual(receipt);if(when==='settled')settle();
   const replace=(node:any)=>{const parent=node.parentElement;const clone=node.cloneNode(true);node.detach();parent.append(clone);};
   if(mutation==='user-root')replace(f.root);if(mutation==='user-body')replace(f.userBody);if(mutation==='answer-root')replace(f.answerRoot);if(mutation==='answer-content')replace(f.answer);
   if(mutation==='body-text')f.userBody.text+=' changed';if(mutation==='route')f.document.URL='https://chat.qwen.ai/c/'+generation;if(mutation==='model')f.modelName.text='Qwen3.8-Max';
   const r=await f.run('inspect',grant);expect(r.error,when+':'+mutation).toBeDefined();expect(r.text).toBeUndefined();expect(f.send.clicks).toBe(1);
  }
 });
 test('hash await revalidates ownership and supports same-node ID settlement without a resend',async()=>{
  for(const kind of ['body','node','route','model','owner','settle']){
   const {f,grant,settle,hash}=await sent();let once=false;
   f.beforeDigest(()=>{if(once)return;once=true;if(kind==='body')f.userBody.text+='changed';if(kind==='node'){f.answer.detach();f.answerRoot.append(f.answer.cloneNode(true));}if(kind==='route')f.document.URL='https://chat.qwen.ai/c/'+generation;if(kind==='model')f.modelName.text='Qwen3.8-Max';if(kind==='owner')f.world.__computaModelOwner=generation;if(kind==='settle')settle();});
   const r=await f.run('inspect',grant);if(kind==='settle'){expect(r.firstUserFingerprint).toBe(hash);expect(r.text).toBe(raw);expect(r.answerComplete).toBe(true);}else{expect(r.error,kind).toBeDefined();expect(r.text).toBeUndefined();}expect(f.send.clicks).toBe(1);
  }
 });
 test('pending never authorizes mutation, cleanup, verifyModel or a second submission',async()=>{
  for(const action of ['verifyModel','submit','insert','sendReady','selectModel','deleteConversation','observeDeletedConversation']){
   const {f,grant,hash}=await sent();expect(await f.run('inspect',grant)).toEqual(receipt);const before=f.mutations();
   const r=await f.run(action,{...grant,prompt,modelChoice:choice(),deleteOperation:{id:marker,documentGeneration:generation,sequence:1,firstUserFingerprint:hash,conversationURL:canonical}});
   expect(r.error,action).toBeDefined();expect(f.mutations()).toBe(before);expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);
  }
 });
 test('empty ID after a bound first body remains a terminal failure',async()=>{
  const {f,grant,settle,hash}=await sent();settle();expect((await f.run('inspect',grant)).firstUserVerified).toBe(true);
  f.answer.setAttribute('id','chat-response-message-');const r=await f.run('inspect',{...grant,expectedFirstUserFingerprint:hash,allowFirstUserBinding:false});expect(r.error).toBeDefined();expect(r.text).toBeUndefined();
 });
});

describe('Qwen Max initial assistant root without a mounted response container', () => {
 const max = choice('Qwen3.8-Max');
 test('exact full first body, same root, then first container, UUID and exact response', async () => {
  const {f, hash, grant, settle} = await sent(max);
  f.answer.detach();
  const before = f.mutations();
  expect(await f.run('inspect', grant)).toEqual(receipt);
  expect(await f.run('inspect', grant)).toEqual(receipt);
  expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();
  expect(f.mutations()).toBe(before);
  f.answerRoot.append(f.answer);
  expect(await f.run('inspect', grant)).toEqual(receipt);
  settle();
  const result = await f.run('inspect', grant);
  expect(result.firstUserFingerprint).toBe(hash);
  expect(result.modelEvidence.selected).toEqual(max);
  expect(result.answerComplete).toBe(true);
  expect(result.text).toBe(raw);
  expect(f.send.clicks).toBe(1);
 });
 test('ambiguous, hidden, nonempty, foreign or ungranted roots cannot enter pending', async () => {
  for (const change of ['two-visible','one-hidden','mixed','foreign-text','element','body','wrong-outer','no-stop','other-model','no-grant']) {
   const {f, grant} = await sent(change === 'other-model' ? choice() : max);
   if (change === 'two-visible' || change === 'mixed') {
    const other = f.answer.cloneNode(true);
    if (change === 'mixed') other.values.hidden = '';
    f.answerRoot.append(other);
   } else if (change === 'one-hidden') f.answer.setAttribute('hidden','');
   else f.answer.detach();
   if (change === 'foreign-text') f.answerRoot.text = 'unbound';
   if (change === 'element') f.answerRoot.append(new f.Node('DIV'));
   if (change === 'body') f.userBody.text = prompt.slice(0,-1);
   if (change === 'wrong-outer') f.body.append(f.answerRoot.parentElement!);
   if (change === 'no-stop') f.stop.detach();
   const result = await f.run('inspect', change === 'no-grant' ? {} : grant);
   expect(result.error, change).toBeDefined();
   if (['two-visible','mixed'].includes(change)) expect(result.detail, change).toBe('response_container_multiple');
   if (change === 'one-hidden') expect(result.detail).toBe('response_container_hidden');
   if (['foreign-text','element','body','no-stop','other-model'].includes(change)) expect(result.detail, change).toBe('response_container_empty');
   expect(result.qwenInitialResponseIdentityPending).toBeUndefined();
   expect(result.text).toBeUndefined();
   expect(f.send.clicks).toBe(1);
  }
 });
 test('first-root pins survive hash awaits and cannot migrate, regress or grant cleanup', async () => {
  for (const change of ['replaced-root','lost-root','changed-user','changed-id','changed-choice','draft','route','owner','removal','replacement','settled-id','cleanup']) {
   const {f, grant, settle} = await sent(max);
   f.answer.detach();
   expect(await f.run('inspect', grant)).toEqual(receipt);
   if (['removal','replacement','settled-id'].includes(change)) {
    f.answerRoot.append(f.answer);
    expect(await f.run('inspect', grant)).toEqual(receipt);
    if (change === 'settled-id') { settle(); expect((await f.run('inspect',grant)).answerComplete).toBe(true); f.answer.setAttribute('id', 'chat-response-message-'+generation); }
    else { f.answer.detach(); if (change === 'replacement') f.answerRoot.append(f.answer.cloneNode(true)); }
   } else if (change !== 'cleanup') {
    f.beforeDigest(() => {
     if (change === 'replaced-root' || change === 'lost-root') {
      const parent = f.answerRoot.parentElement!;
      f.answerRoot.detach();
      if (change === 'replaced-root') parent.append(f.answerRoot.cloneNode(true));
     }
     if (change === 'changed-user') f.userBody.text += ' different';
     if (change === 'changed-id') f.userContainer.setAttribute('data-msg-id', generation);
     if (change === 'changed-choice') f.modelName.text = 'Qwen3.7-Plus';
     if (change === 'draft') f.editor.value = 'new draft';
     if (change === 'route') f.document.URL = 'https://chat.qwen.ai/c/' + generation;
     if (change === 'owner') f.world.__computaModelOwner = generation;
    });
   }
   const result = await f.run('inspect', change === 'cleanup' ? {...grant, savedCleanupInspection:true} : grant);
   expect(result.error, change).toBeDefined();
   expect(result.text).toBeUndefined();expect(result.completionEvidence).toBeUndefined();expect(f.more.clicks).toBe(0);
   expect(f.send.clicks).toBe(1);
  }
 });
});

function noContainerFailureAuthority(f: ReturnType<typeof fixture>, r: any, before: number) {
 expect(r.error).toBe('document_changed');expect(r.detail).toBe('response_container_multiple');
 expect(r.text).toBeUndefined();expect(r.completionEvidence).toBeUndefined();expect(r.qwenCodePayload).toBeUndefined();
 expect(r.qwenInitialResponseIdentityPending).toBeUndefined();expect(f.mutations()).toBe(before);
 expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);expect(f.actions[0].clicks).toBe(0);
}
test('response container diagnostic separates Plus two-visible and all-hidden without response or cleanup authority', async()=>{
 for(const hidden of [false,true]){
  const {f,grant}=await sent();f.answer.setAttribute('id','chat-response-message-'+answerID);
  const other=f.answer.cloneNode(true);other.values.id='chat-response-message-'+generation;f.answerRoot.append(other);
  if(hidden){f.answer.setAttribute('hidden','');other.values.hidden='';}
  const before=f.mutations(),r=await f.run('inspect',grant);noContainerFailureAuthority(f,r,before);
  expect(r.adapterFailureStructure).toEqual({version:1,provider:'qwen',trigger:'response_container_multiple',total:2,displayed:hidden?0:2,
   emptyRootMode:false,dual:false,multi:false,smrm:false,cmrm:false,ancestorLimited:false,relation:'siblings',idRelation:'different_uuid',
   containers:[{visible:!hidden,id:'uuid',loading:1,phase:0,footer:0,limited:false},{visible:!hidden,id:'uuid',loading:1,phase:0,footer:0,limited:false}]});
  f.answerRoot.children=f.answerRoot.children.filter(node=>node!==other);other.parentElement=null;other.connected=false;f.answer.removeAttribute('hidden');
  expect((await f.run('inspect',grant)).detail).toBe('terminal_operation');
  expect((await f.run('inspect',{...grant,savedCleanupInspection:true})).detail).toBe('terminal_operation');
  expect(f.more.clicks).toBe(0);expect(f.send.clicks).toBe(1);
 }
});
test('response container diagnostic recognizes only finite comparison ancestry and nested ID relation',async()=>{
 for(const kind of ['smrm','cmrm','nested']){
  const {f,grant}=await sent();f.answer.setAttribute('id','chat-response-message-'+answerID);const other=f.answer.cloneNode(true);
  if(kind==='nested')f.answer.append(other);
  else{const wrapper=new f.Node('DIV',{class:kind}),left=new f.Node('DIV'),right=new f.Node('DIV');
   f.answer.detach();left.append(f.answer);right.append(other);wrapper.append(left,right);f.answerRoot.append(wrapper);
   f.answerRoot.setAttribute('class','qwen-chat-message qwen-chat-message-assistant qwen-chat-message-dual-message');}
  const before=f.mutations(),r=await f.run('inspect',grant);noContainerFailureAuthority(f,r,before);
  const p=r.adapterFailureStructure;expect(p.idRelation).toBe('same_uuid');expect(p.relation).toBe(kind==='nested'?'nested':'other');
  expect(p.smrm).toBe(kind==='smrm');expect(p.cmrm).toBe(kind==='cmrm');expect(p.dual).toBe(kind!=='nested');
  expect(p.containers[0].loading).toBe(kind==='nested'?2:1);
 }
});
test('response container diagnostic preserves mixed-hidden Plus control and Max refusal',async()=>{
 for(const label of ['Qwen3.7-Plus','Qwen3.8-Max']){
  const {f,grant}=await sent(choice(label));const other=f.answer.cloneNode(true);other.values.hidden='';f.answerRoot.append(other);
  const before=f.mutations(),r=await f.run('inspect',grant);
  if(label==='Qwen3.7-Plus'){expect(r).toEqual(receipt);expect(r.adapterFailureStructure).toBeUndefined();}
  else{noContainerFailureAuthority(f,r,before);expect(r.adapterFailureStructure.displayed).toBe(1);expect(r.adapterFailureStructure.emptyRootMode).toBe(true);}
  expect(f.mutations()).toBe(before);expect(f.send.clicks).toBe(1);
 }
});
test('response container metadata is bounded, never reads text and never replaces its original rejection',async()=>{
 for(const kind of ['bounded','throw']){
  const {f,grant}=await sent();const other=f.answer.cloneNode(true);f.answerRoot.append(other);
  if(kind==='bounded'){for(let i=0;i<300;i++)f.answer.append(new f.Node('DIV',{class:'response-loading PRIVATE_CLASS'},'PRIVATE_TEXT'));
   Object.defineProperty(f.answer,'textContent',{get(){throw new Error('must not read reply');}});
  }else{const get=f.answer.getAttribute.bind(f.answer);f.answer.getAttribute=(name:string)=>{if(name==='id')throw new Error('PRIVATE_ATTRIBUTE');return get(name);};}
  const before=f.mutations(),r=await f.run('inspect',grant);noContainerFailureAuthority(f,r,before);
  if(kind==='bounded'){expect(r.adapterFailureStructure.containers[0].limited).toBe(true);expect(r.adapterFailureStructure.containers[0].loading).toBe(3);
   const text=JSON.stringify(r.adapterFailureStructure);expect(text.length).toBeLessThanOrEqual(1024);expect(text).not.toContain('PRIVATE');expect(text).not.toContain(answerID);}
  else expect(r.adapterFailureStructure).toBeUndefined();
 }
});
test('response container saturation does not conceal the actual first-two categories or grant uniqueness',async()=>{
 const {f,grant}=await sent();f.answerRoot.append(f.answer.cloneNode(true),f.answer.cloneNode(true),f.answer.cloneNode(true));
 const before=f.mutations(),r=await f.run('inspect',grant);noContainerFailureAuthority(f,r,before);
 expect(r.adapterFailureStructure.total).toBe(3);expect(r.adapterFailureStructure.displayed).toBe(3);
 expect(r.adapterFailureStructure.containers).toHaveLength(2);expect(r.adapterFailureStructure.idRelation).toBe('other');
 expect(r.adapterFailureStructure.containers.every((x:any)=>x.id==='empty_prefix')).toBe(true);
});
test('response container diagnostic bounds ancestor walks and describes loading phase footer without values',async()=>{
 const {f,grant}=await sent();f.answer.removeAttribute('id');
 f.answer.append(new f.Node('DIV',{class:'response-message-content phase-answer'},'PRIVATE_ANSWER'),new f.Node('DIV',{class:'response-message-footer-actions'}));
 const other=f.answer.cloneNode(true);other.values.id='PRIVATE_ID';let chain=f.answerRoot;
 for(let i=0;i<70;i++){const next=new f.Node('DIV');chain.append(next);chain=next;}
 chain.append(other);const before=f.mutations(),r=await f.run('inspect',grant);noContainerFailureAuthority(f,r,before);
 expect(r.adapterFailureStructure.ancestorLimited).toBe(true);expect(r.adapterFailureStructure.containers[0]).toEqual({visible:true,id:'missing',loading:1,phase:1,footer:1,limited:false});
 expect(r.adapterFailureStructure.containers[1].id).toBe('other');expect(JSON.stringify(r.adapterFailureStructure)).not.toContain('PRIVATE');
});
