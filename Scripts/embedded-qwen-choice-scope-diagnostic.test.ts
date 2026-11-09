import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { fixture, choice, prompt, marker, generation, fingerprint, answerID, raw } from './embedded-qwen-adapter-fixture';
const currentEngine = readFileSync(new URL('./EmbeddedSavedProviders/saved-conversation-engine.js', import.meta.url), 'utf8');
const secondID = 'bbf6615b-e58b-4059-a95c-0d711aa4b6ae';
const nativeGrant = 'caf8aa04-4bac-438b-9280-a98703ec0bee';
async function comparison({waiting = false, body = prompt}: {waiting?:boolean, body?:string} = {}) {
  const f = fixture({completeOnSend:false});
  for (let i=0;i<8;i++) { const r=await f.run('selectModel',{modelChoice:choice()}); expect(r.error).toBeUndefined(); if(r.selected)break; }
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert',{prompt:body})).inserted).toBe(true);
  expect((await f.run('sendReady',{prompt:body})).sendReady).toBe(true);
  const hash=await fingerprint(body);
  expect((await f.run('submit',{prompt:body,savedSubmissionFingerprint:hash})).submitted).toBe(true);
  f.answer.detach();
  f.answerRoot.setAttribute('class','qwen-chat-message qwen-chat-message-assistant qwen-chat-message-dual-message');
  const wrapper=new f.Node('DIV',{class:'smrm'}), list=new f.Node('DIV',{class:'smrm-list smrm-list--mac'});
  const second=f.answer.cloneNode(true); second.values.id='chat-response-message-'+secondID;
  const responses=[f.answer,second];
  const rows=responses.map((response,index)=>{
    const id=[answerID,secondID][index];
    const card=new f.Node('DIV',{class:'smrm-card',id:id+'-smrm-card'});
    const header=new f.Node('DIV',{class:'smrm-card__header'},'Response '+(index+1));
    const cardBody=new f.Node('DIV',{class:'smrm-card__body'}), content=new f.Node('DIV',{class:'smrm-card__content'});
    const footer=new f.Node('DIV',{class:'smrm-card__footer'}), control=new f.Node('BUTTON',{class:'smrm-card__prefer-btn'},'I prefer this response');
    control.disabled=waiting;content.append(response);cardBody.append(content);footer.append(control);card.append(header,cardBody,footer);list.append(card);
    return {id,card,header,cardBody,content,footer,control,response};
  });
  wrapper.append(list);f.answerRoot.append(wrapper);
  let chooseCalls=0;
  const acknowledge=(index=0)=>{
    wrapper.detach(); const selected=rows[index].response; selected.parentElement!.children=[];
    f.answerRoot.append(selected);f.answerRoot.setAttribute('class','qwen-chat-message qwen-chat-message-assistant');
    f.complete();
  };
  rows.forEach((row,index)=>{row.control.onClick=()=>{chooseCalls++;acknowledge(index);};});
  const input={allowSavedResponseChoice:true,allowQwenInitialResponseIdentity:true,expectedModelChoice:choice(),savedSubmissionFingerprint:hash};
  const grant=(r:any)=>({version:1,kind:'qwen_smrm',policy:'first_observed_card_v1',grant:nativeGrant,
    candidate:r.savedResponseChoice.candidate,responseIDs:[answerID,secondID],selectedResponseID:answerID,sequence:1});
  return {f,hash,input,grant,rows,wrapper,list,acknowledge,calls:()=>chooseCalls};
}

function failedScope(value:any, stage:string) {
  expect(value.error).toBe('conversation_changed');expect(value.detail).toBe('response_choice_scope');
  expect(value.qwenResponseChoiceStage).toBe(stage);
  expect(Object.keys(value).sort()).toEqual(['detail','error','qwenResponseChoiceStage']);
}
describe('Qwen response-choice scope failure-only stages',()=>{
 test('valid early comparison and one acknowledged grant preserve envelopes and action counts',async()=>{
   {
   const x=await comparison(),r=await x.f.run('inspect',x.input);
   expect(r.error).toBeUndefined();expect(r.savedResponseChoice.state).toBe('ready');expect(r.qwenResponseChoiceStage).toBeUndefined();
   const dispatched=await x.f.run('inspect',{...x.input,savedResponseChoiceGrant:x.grant(r),evaluationDeadlineEpochMilliseconds:Date.now()+1000});
   expect(dispatched.savedResponseChoice.state).toBe('dispatched');expect(dispatched.qwenResponseChoiceStage).toBeUndefined();
   const result=await x.f.run('inspect',x.input);expect(result.text).toBe(raw);expect(result.savedResponseChoice.state).toBe('acknowledged');
   expect(result.qwenResponseChoiceStage).toBeUndefined();expect(x.calls()).toBe(1);expect(x.f.send.clicks).toBe(1);expect(x.f.more.clicks).toBe(0);
  }
 });
 test('reachable admission flags keep the scope refusal and cannot act',async()=>{
  const variants:any[]=[['choice_grant',{allowSavedResponseChoice:false}],['identity_grant',{allowQwenInitialResponseIdentity:false}],
   ['cleanup',{savedCleanupInspection:true}],['first_bind_grant',{allowFirstUserBinding:false}],
   ['prior_fingerprint',{expectedFirstUserFingerprint:'0'.repeat(64)}],['marker_uuid',{expectedFirstUserMarker:'not-a-uuid'}],
   ['marker_match',{expectedFirstUserMarker:generation}],['model_choice',{expectedModelChoice:choice('Qwen3.8-Max')}],
   ['submission_match',{savedSubmissionFingerprint:'0'.repeat(64)}],['counts_array',{expectedUserCounts:null}],
   ['counts_one',{expectedUserCounts:[0]}],['counts_limit',{expectedUserCounts:[0,1,1]}],['counts_values',{expectedUserCounts:[1,2]}]];
  for(const [tag,over] of variants){
   const x=await comparison();expect((await x.f.run('inspect',x.input)).savedResponseChoice).toBeDefined();
   const before=x.f.mutations(),r=await x.f.run('inspect',{...x.input,...over});
   failedScope(r,'admission_'+tag);expect(x.f.mutations()).toBe(before);expect(x.calls()).toBe(0);expect(x.f.more.clicks).toBe(0);
  }
 });
 test('late comparison after an immutable single reply pin is still refused with no response rebind',async()=>{
  {
   const x=await comparison();x.wrapper.detach();x.rows[0].response.parentElement!.children=[];x.f.answerRoot.append(x.f.answer);
   x.f.answer.setAttribute('id','chat-response-message-');x.f.phase.detach();x.f.answer.append(new x.f.Node('DIV',{class:'response-loading'}));
   expect((await x.f.run('inspect',x.input)).qwenInitialResponseIdentityPending).toBe(true);
   const held=x.f.world.__computaQwenSavedSessionV1.responseIdentity;
   x.f.answer.detach();x.f.answer.setAttribute('id','chat-response-message-'+answerID);x.rows[0].content.append(x.f.answer);x.f.answerRoot.append(x.wrapper);
   const r=await x.f.run('inspect',x.input);failedScope(r,'admission_response_identity');
   expect(x.f.world.__computaQwenSavedSessionV1.responseIdentity).toBe(held);expect(x.f.world.__computaQwenSavedSessionV1.first).toBeNull();
   expect(x.calls()).toBe(0);expect(x.f.more.clicks).toBe(0);
  }
 });
 test('display witness, pair replacement, full-body and asynchronous scope changes retain refusals',async()=>{
  for(const variant of ['witness','pair','body','hash']){
   const x=await comparison();
   if(variant==='witness')x.f.world.__computaQwenSavedSessionV1.firstDisplayWitness={};
   else if(variant==='body')x.f.userBody.text+='PRIVATE_PAGE_CANARY';
   else {expect((await x.f.run('inspect',x.input)).savedResponseChoice).toBeDefined();
    if(variant==='pair'){const replacement=x.wrapper.cloneNode(true);x.wrapper.detach();x.f.answerRoot.append(replacement);}
    else x.f.beforeDigest(()=>{x.f.userBody.text+='PRIVATE_PAGE_CANARY';});
   }
   const r=await x.f.run('inspect',{...x.input,...(variant==='witness'?{allowQwenFirstBodyExpansion:true}:{})});failedScope(r,({witness:'admission_display_witness',pair:'pair_scope',body:'full_body',hash:'hash_scope'} as any)[variant]);
   expect(JSON.stringify(r)).not.toContain('PRIVATE_PAGE_CANARY');expect(x.calls()).toBe(0);expect(x.f.more.clicks).toBe(0);
  }
 });
 test('grant mismatch, wrong selected acknowledgement and lost acknowledgement never replay',async()=>{
  for(const variant of ['grant','selected','throw']){
   const x=await comparison(),ready=await x.f.run('inspect',x.input),grant=x.grant(ready);
   if(variant==='grant')grant.candidate=marker;
   if(variant==='selected')x.rows[0].control.onClick=()=>x.acknowledge(1);
   if(variant==='throw')x.rows[0].control.onClick=()=>{throw new Error('PRIVATE_PAGE_CANARY');};
   const r=await x.f.run('inspect',{...x.input,savedResponseChoiceGrant:grant,evaluationDeadlineEpochMilliseconds:Date.now()+1000});
   if(variant==='grant')failedScope(r,'grant_scope');
   else if(variant==='selected'){expect(r.savedResponseChoice.state).toBe('dispatched');failedScope(await x.f.run('inspect',x.input),'selected_scope');}
   else {expect(r.error).toBe('document_changed');expect(JSON.stringify(r)).not.toContain('PRIVATE_PAGE_CANARY');expect(x.f.world.__computaQwenSavedSessionV1.responseChoice.spent).toBe(true);}
   const clicks=x.rows[0].control.clicks;expect(clicks).toBe(variant==='grant'?0:1);
   expect((await x.f.run('inspect',x.input)).error).toBeDefined();expect(x.rows[0].control.clicks).toBe(clicks);expect(x.f.more.clicks).toBe(0);
  }
 });
 test('scope diagnostic rethrows the exact original adapter object',()=>{
  const start=currentEngine.indexOf("      const refuse = (stage = choiceStage) => {");
  const end=currentEngine.indexOf("      if ((choiceStage = 'admission_action'",start);
  expect(start).toBeGreaterThan(0);expect(end).toBeGreaterThan(start);
  const rejected:any={computaAdapterFailure:true,error:'conversation_changed',detail:'response_choice_scope'};
  const run=new Function('c',"let choiceStage='admission_action';"+currentEngine.slice(start,end)+"try{refuse();}catch(error){return error;}");
  expect(run({fail:()=>{throw rejected;}})).toBe(rejected);expect(rejected.qwenResponseChoiceStage).toBe('admission_action');
  const frozen=Object.freeze({computaAdapterFailure:true,error:'conversation_changed',detail:'response_choice_scope'});
  expect(run({fail:()=>{throw frozen;}})).toBe(frozen);
 });
});
