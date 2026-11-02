import { describe, expect, test } from 'bun:test';
import { adapterFixture, instant } from './embedded-kimi-adapter-fixture';
const keys=['version','reason','stage','required','submitted','firstBodyBound','selectionPending','boundSelectionPresent','pickerClosed','triggerSameNode','boundTriggerConnected','labelMatches'].sort();
async function sent(optimistic=false){
 const f=adapterFixture({provisional:optimistic,optimisticUser:optimistic});expect((await f.select()).selected).toBe(true);
 for(const action of ['prepare','insert','sendReady','submit'])expect((await f.run(action)).error).toBeUndefined();
 expect(f.counts().sends).toBe(1);return f;
}
function mutate(f:any,kind:string){
 const s=f.world.__computaKimiSavedSessionV1;
 if(kind==='selection_pending')s.selection={stage:'selected',trigger:f.trigger,menu:f.menu,target:instant,option:{triggerID:f.trigger.getAttribute('id'),menuID:f.trigger.getAttribute('aria-controls'),choice:instant,previous:{choice:instant}}};
 if(kind==='unbound')s.model=null;
 if(kind==='picker_open')f.trigger.click();
 if(kind==='trigger_replaced'){const clone=f.trigger.cloneNode(true);f.remove(f.trigger);f.body.append(clone);}
 if(kind==='label_changed')f.triggerName.text='PRIVATE_CANARY_LABEL';
}
describe('Kimi finite rejected model evidence',()=>{
 test('each old disjunct remains a rejection and reports its finite predicate and exact call path',async()=>{
  for(const optimistic of [true,false])for(const kind of ['selection_pending','unbound','picker_open','trigger_replaced','label_changed']){
   const f=await sent(optimistic);mutate(f,kind);const before=f.counts(),r=await f.run();
   expect(r.error).toBe('model_unverified');expect(r.detail).toBe('model_evidence_'+kind);
   const d=r.modelEvidenceDiagnostic;expect(Object.keys(d).sort()).toEqual(keys);expect(d.version).toBe(1);
   expect(d.reason).toBe(r.detail);expect(d.stage).toBe(optimistic?'optimistic_first':'canonical_first_hash');
   expect(d.required).toBe(true);expect(d.submitted).toBe(true);expect(d.firstBodyBound).toBe(false);
   expect(r.text).toBeUndefined();expect(r.modelEvidence).toBeUndefined();expect(r.firstUserVerified).toBeUndefined();expect(r.answerComplete).toBeUndefined();
   expect(JSON.stringify(d)).not.toContain('PRIVATE');expect(JSON.stringify(d).length).toBeLessThan(640);expect(f.counts()).toEqual(before);
   expect((await f.run()).detail).toBe('terminal_operation');expect(f.counts().sends).toBe(1);
  }
 });
 test('optional read stays null and cannot publish a rejected diagnostic as selection proof',async()=>{
  const f=adapterFixture({delayedUser:true});await f.select();
  for(const action of ['prepare','insert','sendReady','submit'])expect((await f.run(action)).error).toBeUndefined();
  f.triggerName.text='PRIVATE_CANARY_LABEL';const r=await f.run();expect(r.error).toBeUndefined();
  expect(r.modelEvidence).toBeNull();expect(r.modelEvidenceDiagnostic).toBeUndefined();expect(r.firstUserVerified).toBe(false);expect(r.text).toBe('');expect(f.counts().sends).toBe(1);
 });
 test('post-hash model drift records its own predicate without moving the rejection or adding actions',async()=>{
  const f=await sent();f.onDigest(()=>mutate(f,'trigger_replaced'));const before=f.counts();const r=await f.run();
  expect(r.detail).toBe('model_evidence_trigger_replaced');expect(r.modelEvidenceDiagnostic.stage).toBe('canonical_first_hash');
  expect(r.modelEvidenceDiagnostic.boundTriggerConnected).toBe(false);expect(r.modelEvidenceDiagnostic.labelMatches).toBe(true);
  expect(f.world.__computaKimiSavedSessionV1.first).toBeNull();expect(f.counts()).toEqual(before);
 });
 test('picker parse failures keep their existing reason and cannot be misreported as missing model evidence',async()=>{
  const f=await sent();f.remove(f.trigger);const r=await f.run();expect(r.error).toBe('document_changed');expect(r.detail).toBe('model_trigger');expect(r.modelEvidenceDiagnostic).toBeUndefined();
 });
 test('valid response proof and exact chosen model remain unchanged',async()=>{
  const f=await sent();const r=await f.run();expect(r.error).toBeUndefined();expect(r.firstUserVerified).toBe(true);
  expect(r.modelEvidence.selected).toEqual(instant);expect(r.answerComplete).toBe(true);expect(r.modelEvidenceDiagnostic).toBeUndefined();expect(f.counts().sends).toBe(1);
 });
});
