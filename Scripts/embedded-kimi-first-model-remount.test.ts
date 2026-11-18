import { describe, expect, test } from 'bun:test';
import { adapterFixture, canonical, generation, instant, marker, prompt, submissionFingerprint } from './embedded-kimi-adapter-fixture';
const state = (f: any) => f.world.__computaKimiSavedSessionV1;
async function sent(options: any = {}) {
 const f=adapterFixture({provisional:true,optimisticUser:true,...options});expect((await f.select()).selected).toBe(true);
 for(const a of ['prepare','insert','sendReady','submit'])expect((await f.run(a)).error).toBeUndefined();expect(f.counts().sends).toBe(1);return f;
}
function remount(f:any,old=state(f).model.trigger,keep=false){const n=old.cloneNode(true);if(keep)old.values.hidden='';else f.remove(old);f.body.append(n);return n;}
async function rejected(f:any,r:any,before:any){expect(r.error).toBeDefined();for(const k of ['text','modelEvidence','firstUserVerified','answerComplete'])expect(r[k]).toBeUndefined();expect(f.counts()).toEqual(before);expect((await f.run()).error).toBeDefined();expect(state(f).terminal).toBe(true);expect(f.counts()).toEqual(before);}
describe('Kimi one first-submit detached trigger revalidation',()=>{
 test('only pending ownership until strict canonical proof, with no new action',async()=>{
  const f=await sent(),old=f.trigger,n=remount(f),before=f.counts(),r=await f.run();
  expect(r.error).toBeUndefined();expect(r).toMatchObject({ownershipPending:true,text:'',responseCount:0,answerComplete:false,firstUserVerified:false,firstUserMarkerVerified:false,firstUserFingerprint:null,conversationIdentity:null});
  expect(r.modelEvidence.selected).toEqual(instant);expect(state(f).first).toBeNull();expect(state(f).model.trigger).toBe(n);expect(state(f).initialModelRemount.previousTrigger).toBe(old);
  for(let i=0;i<3;i++)expect((await f.run()).ownershipPending).toBe(true);expect(f.counts()).toEqual(before);expect(n.clicks).toBe(0);
  f.replaceOptimisticUser();expect((await f.run()).ownershipPending).toBe(true);f.document.URL=canonical;
  const complete=await f.run();expect(complete.firstUserVerified).toBe(true);expect(complete.firstUserFingerprint).toBe(submissionFingerprint);expect(complete.modelEvidence.selected).toEqual(instant);expect(complete.answerComplete).toBe(true);expect(complete.text).toBe('{"type":"message","text":"Synthetic reply"}');expect(f.counts()).toEqual(before);
  const op=f.operation();for(const action of ['deleteConversation','selectConversationDeletion','confirmConversationDeletion'])expect((await f.run(action,{deleteOperation:op})).error).toBeUndefined();
  expect((await f.run('observeDeletedConversation',{deleteOperation:op})).deleteProof.conversationDeleted).toBe(true);expect(f.counts()).toEqual({...before,confirms:1});
 });
 test('whole long prompt and original outbound digest are retained',async()=>{
  const outbound='Synthetic tool schema café\\quoted "value"\n'.repeat(1600)+'\nComputa session marker: '+marker;
  const f=await sent({outbound});remount(f);expect((await f.run()).ownershipPending).toBe(true);expect(f.messages.userBody.textContent).toBe(outbound);
  f.replaceOptimisticUser();f.document.URL=canonical;expect((await f.run()).firstUserVerified).toBe(true);expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
  const b=await sent();remount(b);state(b).inserted.outboundFingerprint='a'.repeat(64);await rejected(b,await b.run(),b.counts());
 });
 test('cannot leave the acknowledged optimistic first-user window',async()=>{
  for(const k of ['unack','capability','cleanup','fingerprint','canonical','uuid','choice','selection','prepared','inserted','unverified','first','old_connected','hidden_duplicate','duplicate','authored','label','open','links','catalog']){
   const f=await sent(),n=remount(f,f.trigger,k==='old_connected'),s=state(f);let x:any={};
   if(k==='unack')s.submissionAcknowledged=false;if(k==='capability')x.allowFirstUserBinding=false;if(k==='cleanup')x.kimiCleanupInspection=true;
   if(k==='fingerprint')x.expectedFirstUserFingerprint=submissionFingerprint;if(k==='canonical')f.document.URL=canonical;if(k==='uuid'){f.replaceOptimisticUser();f.document.URL=canonical;}
   if(k==='choice')x.expectedModelChoice={key:'other',label:'Instant'};if(k==='selection')s.selection={stage:'opening'};if(k==='prepared')s.prepared=null;
   if(k==='inserted')s.inserted=null;if(k==='unverified')s.inserted.verified=false;if(k==='first')s.first={};
   if(k==='duplicate'||k==='hidden_duplicate'){const d=n.cloneNode(true);if(k==='hidden_duplicate')d.values.hidden='';f.body.append(d);}
   if(k==='authored'){f.remove(n);n.connected=true;f.messages.user.append(n);}if(k==='label')n.querySelector('.name').text='Other';
   if(k==='open')n.values['aria-expanded']='true';if(k==='links')n.values['aria-controls']='bad id';if(k==='catalog')s.model.choices=[];
   await rejected(f,await f.run('inspect',x),f.counts());
  }
 });
 test('prompt, ownership, route, model, controls and physical first nodes remain pinned across the digest await',async()=>{
  for(const k of ['echo','root','body','ids','route','canonical','owner','generation','model','choice','trigger','label','links','old_returns','duplicate','draft','editor','send','inserted','hash','prompt','prepared','ack','selection','spent']){
   const f=await sent(),n=remount(f),s=state(f),before=f.counts();f.onDigest(()=>{
    if(k==='echo')f.messages.userBody.text=prompt.replace('Exact','Other');
    if(k==='root'){const d=f.messages.user.cloneNode(true);f.remove(f.messages.user);f.body.append(d);}if(k==='body'){const d=f.messages.userBody.cloneNode(true);f.remove(f.messages.userBody);f.messages.content.append(d);}
    if(k==='ids')f.messages.user.values['data-archer-id']=marker;if(k==='route')f.document.URL=canonical;if(k==='canonical')s.canonical=canonical;
    if(k==='owner')f.world.__computaModelOwner=marker;if(k==='generation')s.generation=marker;if(k==='model')s.model={...s.model};if(k==='choice')s.model.choice={key:'other',label:'Instant'};
    if(k==='trigger')remount(f,n);if(k==='label')n.querySelector('.name').text='Other';if(k==='links')n.values['aria-controls']='different-menu';
    if(k==='old_returns'){f.trigger.connected=true;f.trigger.values.hidden='';f.body.append(f.trigger);}if(k==='duplicate'){const d=n.cloneNode(true);d.values.hidden='';f.body.append(d);}
    if(k==='draft')f.setDraft('New unrelated draft');if(k==='editor'){const d=f.editor.cloneNode(true);f.remove(f.editor);f.scope.append(d);}if(k==='send'){const d=f.send.cloneNode(true);f.remove(f.send);f.body.append(d);}
    if(k==='inserted')s.inserted={...s.inserted};if(k==='hash')s.inserted.outboundFingerprint='b'.repeat(64);if(k==='prompt')s.inserted.prompt+=' changed';if(k==='prepared')s.prepared={...s.prepared};
    if(k==='ack')s.submissionAcknowledged=false;if(k==='selection')s.selection={stage:'opening'};if(k==='spent')s.initialModelRemount=null;
   });await rejected(f,await f.run(),before);expect(s.first).toBeNull();expect(s.model?.trigger).not.toBe(n);
  }
 });
 test('second remount and returning old trigger fail before and after canonical binding',async()=>{
  for(const bound of [false,true])for(const k of ['second','old']){const f=await sent(),n=remount(f);expect((await f.run()).ownershipPending).toBe(true);
   if(bound){f.replaceOptimisticUser();f.document.URL=canonical;expect((await f.run()).firstUserVerified).toBe(true);}
   if(k==='second')remount(f,n);else{f.trigger.connected=true;f.trigger.values.hidden='';f.body.append(f.trigger);}await rejected(f,await f.run(),f.counts());}
 });
 test('remount grants no exemption from final body, marker or post-hash model proof',async()=>{
  for(const k of ['body','link','body_hash','trigger_hash','choice','marker']){const f=await sent(),n=remount(f);expect((await f.run()).ownershipPending).toBe(true);f.replaceOptimisticUser();f.document.URL=canonical;let x:any={};
   if(k==='body')f.messages.userBody.text=prompt.replace('Exact','Other');if(k==='link')f.messages.user.values['data-conversation-turn-id']=marker;
   if(k==='body_hash')f.onDigest(()=>{f.messages.userBody.text+=' changed';});if(k==='trigger_hash')f.onDigest(()=>{remount(f,n);});
   if(k==='choice')x.expectedModelChoice={key:'other',label:'Instant'};if(k==='marker')x.expectedFirstUserMarker=generation;
   await rejected(f,await f.run('inspect',x),f.counts());expect(state(f).first).toBeNull();}
 });
 test('other actions cannot claim the remount or dispatch',async()=>{
  for(const a of ['verifyModel','prepare','stop','deleteConversation','selectConversationDeletion','confirmConversationDeletion']){const f=await sent();remount(f);await rejected(f,await f.run(a),f.counts());}
  const f=adapterFixture();await f.select();remount(f);expect((await f.run('prepare')).error).toBeDefined();expect(f.counts()).toEqual({insertions:0,sends:0,confirms:0});
 });
});
