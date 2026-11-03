import {describe,expect,test} from 'bun:test';
import {fixture,choice,prompt,marker,generation,fingerprint} from './embedded-qwen-adapter-fixture';
async function sent(pending=false) {
 const f=fixture({completeOnSend:!pending});
 for(let i=0;i<8;i++){const r=await f.run('selectModel',{modelChoice:choice()});expect(r.error).toBeUndefined();if(r.selected)break;}
 expect((await f.run('prepare')).prepared).toBe(true);expect((await f.run('insert',{prompt})).inserted).toBe(true);
 expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);const hash=await fingerprint(prompt);
 expect((await f.run('submit',{prompt,savedSubmissionFingerprint:hash})).submitted).toBe(true);
 if(pending){f.phase.detach();f.answer.append(new f.Node('DIV',{class:'response-loading'}));f.answer.setAttribute('id','chat-response-message-');}
 return {f,hash,grant:{allowQwenInitialResponseIdentity:true,allowQwenProvisionalRoute:true,expectedModelChoice:choice(),savedSubmissionFingerprint:hash}};
}
async function rejection(f:any,over:any,stage:string,reason:string){
 const before=f.mutations(),r=await f.run('inspect',over);expect(r.error).toBe('conversation_changed');expect(r.detail).toBe('first_user_message');
 expect(r.qwenFirstUserBindingDiagnostic).toEqual({version:1,stage,reason});expect(Object.keys(r).sort()).toEqual(['detail','error','qwenFirstUserBindingDiagnostic']);
 expect(JSON.stringify(r.qwenFirstUserBindingDiagnostic)).not.toContain('PRIVATE');expect(JSON.stringify(r).length).toBeLessThan(300);
 expect(f.world.__computaQwenSavedSessionV1.terminal).toBe(true);expect(f.mutations()).toBe(before);expect(f.send.clicks).toBe(1);
 expect((await f.run('inspect',over)).detail).toBe('terminal_operation');expect(f.send.clicks).toBe(1);
}
describe('Qwen finite shared-engine first-user rejection tags',()=>{
 test('both initial admission compounds expose their first failed predicate and preserve terminal rejection',async()=>{
  for(const provisional of [true,false])for(const kind of ['grant','cleanup','insert','prepare','send','model','selection','binding','fingerprint','markerinvalid','marker','suffix','choice','hashinvalid','hash']){
   const {f,grant}=await sent(true);const s=f.world.__computaQwenSavedSessionV1;let expected='';const over:any={...grant};
   if(provisional)f.document.URL='https://chat.qwen.ai/c/new-chat';
   if(kind==='grant'){over[provisional?'allowQwenProvisionalRoute':'allowQwenInitialResponseIdentity']=false;expected='native_grant_missing';if(!provisional)s.responseIdentity={};}
   if(kind==='cleanup'){over.savedCleanupInspection=true;expected='cleanup_inspection';}
   if(kind==='insert'){s.inserted=null;expected='insertion_missing';}if(kind==='prepare'){s.prepared=null;expected='preparation_missing';}
   if(kind==='send'){s.send=null;expected='send_missing';}if(kind==='model'){s.model=null;expected='model_missing';}
   if(kind==='selection'){s.selection={};expected='selection_pending';}
   if(kind==='binding'){over.allowFirstUserBinding=false;expected='binding_not_authorized';}
   if(kind==='fingerprint'){over.expectedFirstUserFingerprint='a'.repeat(64);expected='expected_fingerprint_present';}
   if(kind==='markerinvalid'){over.expectedFirstUserMarker='PRIVATE_MARKER';expected='marker_invalid';}
   if(kind==='marker'){over.expectedFirstUserMarker=generation;expected='marker_mismatch';}
   if(kind==='suffix'){s.inserted.prompt+='PRIVATE_SUFFIX';expected='marker_suffix';}
   if(kind==='choice'){over.expectedModelChoice=choice('PRIVATE_MODEL');expected='model_choice_mismatch';}
   if(kind==='hashinvalid'){s.submittedFingerprint='PRIVATE_HASH';expected='submitted_fingerprint_invalid';}
   if(kind==='hash'){over.savedSubmissionFingerprint='a'.repeat(64);expected='submitted_fingerprint_mismatch';}
   await rejection(f,over,provisional?'provisional_admission':'initial_response_admission',expected);
  }
 });
 test('pending answer body and expected counts retain exact rejection reasons',async()=>{
  for(const kind of ['body','array','empty','limit','value','one']){
   const {f,grant}=await sent(true);const over:any={...grant};let reason='';
   if(kind==='body'){f.userBody.text+='PRIVATE_BODY';reason='full_prompt_mismatch';}
   if(kind==='array'){over.expectedUserCounts='PRIVATE';reason='counts_not_array';}
   if(kind==='empty'){over.expectedUserCounts=[];reason='counts_empty';}
   if(kind==='limit'){over.expectedUserCounts=[0,1,1];reason='counts_limit';}
   if(kind==='value'){over.expectedUserCounts=[1,2];reason='counts_invalid';}
   if(kind==='one'){over.expectedUserCounts=[0];reason='one_user_not_expected';}
   await rejection(f,over,'initial_response_body',reason);
  }
 });
 test('ordinary full-body, marker and binding guards stay strict with precise tags',async()=>{
  for(const kind of ['body','markerinvalid','marker','suffix','binding','changed']){
   const {f}=await sent();const over:any={};const s=f.world.__computaQwenSavedSessionV1;let reason='';
   if(kind==='body'){f.userBody.text+='PRIVATE_BODY';reason='first_prompt_mismatch';}
   if(kind==='markerinvalid'){over.expectedFirstUserMarker='PRIVATE';reason='first_marker_invalid';}
   if(kind==='marker'){over.expectedFirstUserMarker=generation;reason='first_marker_mismatch';}
   if(kind==='suffix'){s.inserted.prompt+='PRIVATE';f.userBody.text=s.inserted.prompt;reason='first_marker_suffix';}
   if(kind==='binding'){over.allowFirstUserBinding=false;reason='first_binding_not_authorized';}
   if(kind==='changed'){f.beforeDigest(()=>{f.userBody.text+='PRIVATE';});reason='first_changed_after_hash';}
   await rejection(f,over,'binding',reason);
  }
 });
 test('pinned full-body hash, native fingerprint and missing first message remain failures',async()=>{
  for(const kind of ['pinned','native','missing']){
   const {f,hash}=await sent();expect((await f.run('inspect')).firstUserVerified).toBe(true);const s=f.world.__computaQwenSavedSessionV1;
   const over:any={expectedFirstUserFingerprint:hash,allowFirstUserBinding:false};let reason='';
   if(kind==='pinned'){s.first.fingerprint='a'.repeat(64);reason='first_pinned_hash_mismatch';}
   if(kind==='native'){over.expectedFirstUserFingerprint='a'.repeat(64);reason='first_expected_hash_mismatch';}
   if(kind==='missing'){f.root.detach();f.answerRoot.detach();reason='first_disappeared';}
   await rejection(f,over,'binding',reason);
  }
 });
 test('submitted digest mismatch and hash input bounds are tagged without extra actions',async()=>{
  {const {f,grant}=await sent(true);f.world.__computaQwenSavedSessionV1.submittedFingerprint='a'.repeat(64);await rejection(f,{...grant,savedSubmissionFingerprint:'a'.repeat(64)},'initial_response_digest','submitted_fingerprint_mismatch');}
  for(const pending of [false,true]){
   const {f,grant}=await sent(pending);f.userBody.text='x'.repeat(180201)+'\n\nComputa session marker: '+marker;f.world.__computaQwenSavedSessionV1.inserted.prompt=f.userBody.text;
   await rejection(f,pending?grant:{},pending?'initial_response_digest':'binding_digest','hash_input_invalid');
  }
 });
 test('successful proof and existing DOM diagnostic keep their own paths',async()=>{
  const {f,hash}=await sent(),r=await f.run('inspect');expect(r.firstUserVerified).toBe(true);expect(r.firstUserFingerprint).toBe(hash);expect(r.answerComplete).toBe(true);expect(r.qwenFirstUserBindingDiagnostic).toBeUndefined();expect(f.send.clicks).toBe(1);
  const g=await sent();g.f.userContainer.setAttribute('data-msg-id','PRIVATE_ID');const failed=await g.f.run('inspect');expect(failed.qwenFirstUserDiagnostic.reason).toBe('message_id_invalid');expect(failed.qwenFirstUserBindingDiagnostic).toBeUndefined();
 });
});
