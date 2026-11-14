import { describe, expect, test } from 'bun:test';
import { fixture, choice, prompt, marker, generation, ownerToken, fingerprint, answerID, userID, raw } from './embedded-qwen-adapter-fixture';
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
function negativeOnly(r:any, state:string) {
  expect(Object.keys(r).sort()).toEqual(['modelEvidence','savedResponseChoice','sessionLifecycle','temporary','url']);
  expect(r.savedResponseChoice.state).toBe(state);expect(r.savedResponseChoice.selectedResponseID).toBe(answerID);
  for(const key of ['text','userCount','responseCount','firstUserVerified','firstUserMarkerVerified','answerComplete','qwenCodePayload'])expect(r[key]).toBeUndefined();
}
describe('Qwen official SMRM one-response choice',()=>{
 test('waits for BOTH done without output, clicks first observed card once, then ordinary exact proof',async()=>{
  const x=await comparison({waiting:true}),{f,input}=x;
  const waiting=await f.run('inspect',input);negativeOnly(waiting,'waiting');expect(x.calls()).toBe(0);expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();
  x.rows.forEach(row=>row.control.disabled=false);
  const ready=await f.run('inspect',input);negativeOnly(ready,'ready');expect(ready.savedResponseChoice.candidate).toBe(waiting.savedResponseChoice.candidate);
  const dispatched=await f.run('inspect',{...input,savedResponseChoiceGrant:x.grant(ready),evaluationDeadlineEpochMilliseconds:Date.now()+1000});
  negativeOnly(dispatched,'dispatched');expect(x.calls()).toBe(1);expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();
  const accepted=await f.run('inspect',input);expect(accepted.error).toBeUndefined();expect(accepted.firstUserFingerprint).toBe(x.hash);
  expect(accepted.firstUserVerified).toBe(true);expect(accepted.text).toBe(raw);expect(accepted.answerComplete).toBe(true);
  expect(accepted.savedResponseChoice.state).toBe('acknowledged');expect(accepted.savedResponseChoice.grant).toBe(nativeGrant);
  expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);
 });
 test('ungranted or premature choice cannot click',async()=>{
  for(const variant of ['no-native','waiting','missing-sequence','other-candidate','reverse-pair','second-choice','expired','no-deadline']){
   const x=await comparison({waiting:variant==='waiting'}),r=await x.f.run('inspect',x.input);const grant:any=x.grant(r);
   if(variant==='missing-sequence')delete grant.sequence;if(variant==='other-candidate')grant.candidate=marker;
   if(variant==='reverse-pair')grant.responseIDs.reverse();if(variant==='second-choice')grant.selectedResponseID=secondID;
   const overrides:any={...x.input,savedResponseChoiceGrant:grant,evaluationDeadlineEpochMilliseconds:Date.now()+1000};
   if(variant==='no-native')overrides.allowSavedResponseChoice=false;
   if(variant==='expired')overrides.evaluationDeadlineEpochMilliseconds=Date.now()-1;
   if(variant==='no-deadline')delete overrides.evaluationDeadlineEpochMilliseconds;
   const failure=await x.f.run('inspect',overrides);expect(failure.error,variant).toBeDefined();expect(failure.text).toBeUndefined();expect(x.calls()).toBe(0);
  }
 });
 test('exact prompt/marker/hash/model/owner/generation/one user proof is independent of both cards',async()=>{
  for(const variant of ['body','marker','fingerprint','model','owner','generation','extra-user','route','cleanup','first-binding','expected-count']){
   const x=await comparison(),over:any={...x.input};
   if(variant==='body')x.f.userBody.text+='changed';if(variant==='marker')over.expectedFirstUserMarker=generation;
   if(variant==='fingerprint')over.savedSubmissionFingerprint='0'.repeat(64);if(variant==='model')x.f.modelName.text='2 Models';
   if(variant==='owner')over.ownerToken=generation;if(variant==='generation')over.documentGeneration=ownerToken;
   if(variant==='extra-user')x.f.turn.append(x.f.root.cloneNode(true));if(variant==='route')x.f.document.URL='https://chat.qwen.ai/c/'+generation;
   if(variant==='cleanup')over.savedCleanupInspection=true;if(variant==='first-binding')over.allowFirstUserBinding=false;
   if(variant==='expected-count')over.expectedUserCounts=[0];
   const r=await x.f.run('inspect',over);expect(r.error,variant).toBeDefined();expect(r.savedResponseChoice).toBeUndefined();expect(r.text).toBeUndefined();expect(x.calls()).toBe(0);
  }
 });
 test('CMRM, extra/hidden/malformed/reordered/duplicate cards and unsafe controls stay refused',async()=>{
  for(const variant of ['cmrm','third','extra-card-outside','extra-control-outside','hidden','bad-id','duplicate-id','user-id','wrong-response','header','anchor','formaction','nested-control','asymmetric-done','mobile','foreign-root']){
   const x=await comparison();const first=x.rows[0];
   if(variant==='cmrm')x.wrapper.setAttribute('class','cmrm');if(variant==='third')x.list.append(first.card.cloneNode(true));
   if(variant==='extra-card-outside')x.wrapper.append(new x.f.Node('DIV',{class:'smrm-card'}));
   if(variant==='extra-control-outside')x.wrapper.append(new x.f.Node('BUTTON',{class:'smrm-card__prefer-btn'},'I prefer this response'));
   if(variant==='hidden')first.card.setAttribute('hidden','');if(variant==='bad-id')first.card.setAttribute('id','not-uuid-smrm-card');
   if(variant==='duplicate-id'){x.rows[1].card.setAttribute('id',answerID+'-smrm-card');x.rows[1].response.values.id='chat-response-message-'+answerID;}
   if(variant==='user-id'){first.card.setAttribute('id',userID+'-smrm-card');first.response.values.id='chat-response-message-'+userID;}
   if(variant==='wrong-response')first.response.values.id='chat-response-message-'+secondID;if(variant==='header')first.header.text='Qwen3.7-Plus';
   if(variant==='anchor')first.control.tagName='A';if(variant==='formaction')first.control.setAttribute('formaction','/unsafe');
   if(variant==='nested-control')first.control.append(new x.f.Node('BUTTON'));if(variant==='asymmetric-done')first.control.disabled=true;
   if(variant==='mobile')x.list.setAttribute('class','smrm__track');if(variant==='foreign-root')x.f.body.append(x.wrapper);
   const r=await x.f.run('inspect',x.input);expect(r.error,variant).toBeDefined();expect(r.text).toBeUndefined();expect(x.calls()).toBe(0);
  }
 });
 test('pair/control/user/model/route changes during digest or while held never acquire a choice',async()=>{
  for(const when of ['digest','held'])for(const variant of ['pair-order','control','user','root','body','model','route']){
   const x=await comparison();const mutate=()=>{
    if(variant==='pair-order')x.list.children.reverse();if(variant==='control'){const old=x.rows[0].control;old.detach();x.rows[0].footer.append(old.cloneNode(true));}
    if(variant==='user')x.f.userContainer.setAttribute('data-msg-id',generation);if(variant==='root'){const old=x.f.answerRoot;old.detach();x.f.turn.append(old.cloneNode(true));}
    if(variant==='body')x.f.userBody.text+='changed';if(variant==='model')x.f.modelName.text='Qwen3.8-Max';if(variant==='route')x.f.document.URL='https://chat.qwen.ai/c/'+generation;
   };
   if(when==='held'){expect((await x.f.run('inspect',x.input)).savedResponseChoice.state).toBe('ready');mutate();}
   else {let once=false;x.f.beforeDigest(()=>{if(!once){once=true;mutate();}});}
   const r=await x.f.run('inspect',x.input);expect(r.error,when+':'+variant).toBeDefined();expect(r.text).toBeUndefined();expect(x.calls()).toBe(0);
  }
 });
 test('lost acknowledgement and callback throw consume the one JS choice claim',async()=>{
  for(const variant of ['lost','throw']){
   const x=await comparison();x.rows[0].control.onClick=()=>{if(variant==='throw')throw new Error('synthetic');};
   const ready=await x.f.run('inspect',x.input),grant=x.grant(ready),arg={...x.input,savedResponseChoiceGrant:grant,evaluationDeadlineEpochMilliseconds:Date.now()+1000};
   const first=await x.f.run('inspect',arg);expect(x.rows[0].control.clicks).toBe(1);
   if(variant==='lost'){negativeOnly(first,'dispatched');negativeOnly(await x.f.run('inspect',x.input),'dispatched');}
   else expect(first.error).toBeDefined();
   const second=await x.f.run('inspect',arg);expect(second.error).toBeDefined();expect(x.rows[0].control.clicks).toBe(1);expect(x.f.send.clicks).toBe(1);
  }
 });
 test('a wrong/missing/ambiguous selected UUID never falls back to the other card',async()=>{
  for(const variant of ['other','missing','hidden-other','new-user','changed-model']){
   const x=await comparison(),ready=await x.f.run('inspect',x.input);
   x.rows[0].control.onClick=()=>x.acknowledge(variant==='other'?1:0);
   negativeOnly(await x.f.run('inspect',{...x.input,savedResponseChoiceGrant:x.grant(ready),evaluationDeadlineEpochMilliseconds:Date.now()+1000}),'dispatched');
   if(variant==='missing')x.f.answer.detach();if(variant==='hidden-other'){const other=x.rows[1].response;other.values.hidden='';x.f.answerRoot.append(other);}
   if(variant==='new-user')x.f.turn.append(x.f.root.cloneNode(true));if(variant==='changed-model')x.f.modelName.text='Qwen3.8-Max';
   const r=await x.f.run('inspect',x.input);expect(r.error,variant).toBeDefined();expect(r.text).toBeUndefined();expect(x.rows[0].control.clicks).toBe(1);
  }
 });
 test('a pinned ordinary pending reply is immutable when a later pair appears',async()=>{
  const x=await comparison();x.wrapper.detach();x.rows[0].response.parentElement!.children=[];x.f.answerRoot.append(x.f.answer);
  x.f.answer.setAttribute('id','chat-response-message-');x.f.phase.detach();x.f.answer.append(new x.f.Node('DIV',{class:'response-loading'}));
  expect((await x.f.run('inspect',x.input)).qwenInitialResponseIdentityPending).toBe(true);
  x.f.answer.detach();x.f.answer.setAttribute('id','chat-response-message-'+answerID);x.rows[0].content.append(x.f.answer);x.f.answerRoot.append(x.wrapper);
  const r=await x.f.run('inspect',x.input);expect(r.error).toBeDefined();expect(r.text).toBeUndefined();expect(x.calls()).toBe(0);
 });
 test('choice metadata cannot authorize other actions or deletion before strict selection',async()=>{
  for(const action of ['submit','insert','sendReady','selectModel','verifyModel','deleteConversation','selectConversationDeletion','confirmConversationDeletion','observeDeletedConversation']){
   const x=await comparison();negativeOnly(await x.f.run('inspect',x.input),'ready');const before=x.f.mutations();
   const r=await x.f.run(action,{...x.input,prompt,modelChoice:choice()});expect(r.error,action).toBeDefined();expect(x.f.mutations()).toBe(before);expect(x.f.more.clicks).toBe(0);
  }
 });
 test('long prompt expands once under its existing grant before a distinct preference grant',async()=>{
  const body='Synthetic long exact prompt.\n'+'aé𐀀b\n'.repeat(2600)+'\n\nComputa session marker: '+marker;
  const x=await comparison({body}),chunk=x.f.userBody.parentElement!;
  chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand is-collapsed');
  const expand=new x.f.Node('BUTTON',{class:'chat-user-message-expand-toggle chat-user-message-expand-toggle-pc','aria-label':'Expand'});
  chunk.append(expand);x.f.userBody.text=body.slice(0,10240);
  expand.onClick=()=>{chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand');expand.setAttribute('aria-label','Collapse');x.f.userBody.text=body;};
  const input={...x.input,allowQwenFirstBodyExpansion:true};
  expect((await x.f.run('inspect',input)).qwenFirstBodyExpansionPending).toBe(true);expect(expand.clicks).toBe(1);expect(x.calls()).toBe(0);
  const ready=await x.f.run('inspect',input);negativeOnly(ready,'ready');expect(ready.savedResponseChoice.firstUserFingerprint).toBe(x.hash);
  negativeOnly(await x.f.run('inspect',{...input,savedResponseChoiceGrant:x.grant(ready),evaluationDeadlineEpochMilliseconds:Date.now()+1000}),'dispatched');
  const r=await x.f.run('inspect',input);expect(r.error).toBeUndefined();expect(r.firstUserFingerprint).toBe(x.hash);expect(r.text).toBe(raw);
  expect(expand.clicks).toBe(1);expect(x.calls()).toBe(1);expect(x.f.send.clicks).toBe(1);
 });
 test('completed hidden footer may be revealed once, with a new exact hit before the choice grant',async()=>{
  const x=await comparison(),row=x.rows[0];let scrolls=0;
  row.footer.setAttribute('class','smrm-card__footer smrm-card__footer--btn-hidden');
  Object.assign(row.content,{scrollHeight:500,scrollTo:()=>{scrolls++;row.footer.setAttribute('class','smrm-card__footer');}});
  const waiting=await x.f.run('inspect',x.input);negativeOnly(waiting,'waiting');expect(scrolls).toBe(1);expect(x.calls()).toBe(0);
  const ready=await x.f.run('inspect',x.input);negativeOnly(ready,'ready');
  negativeOnly(await x.f.run('inspect',{...x.input,savedResponseChoiceGrant:x.grant(ready),evaluationDeadlineEpochMilliseconds:Date.now()+1000}),'dispatched');
  expect((await x.f.run('inspect',x.input)).text).toBe(raw);expect(scrolls).toBe(1);expect(x.calls()).toBe(1);
 });
 test('after acknowledgement every later plain read checks the chosen UUID before reading its payload',async()=>{
  const x=await comparison(),ready=await x.f.run('inspect',x.input);
  negativeOnly(await x.f.run('inspect',{...x.input,savedResponseChoiceGrant:x.grant(ready),evaluationDeadlineEpochMilliseconds:Date.now()+1000}),'dispatched');
  expect((await x.f.run('inspect',x.input)).text).toBe(raw);
  x.f.answer.setAttribute('id','chat-response-message-'+secondID);let reads=0;
  Object.defineProperty(x.f.literal,'textContent',{get:()=>{reads++;throw new Error('must not read alternative');}});
  const r=await x.f.run('inspect',{...x.input,expectedFirstUserFingerprint:x.hash,allowFirstUserBinding:false});
  expect(r.error).toBeDefined();expect(r.text).toBeUndefined();expect(reads).toBe(0);expect(x.calls()).toBe(1);
 });
});
