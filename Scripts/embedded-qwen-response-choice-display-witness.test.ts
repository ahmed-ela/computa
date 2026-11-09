import {expect,test} from 'bun:test';
import {fixture,choice,marker,answerID,fingerprint} from './embedded-qwen-adapter-fixture';
const secondID='bbf6615b-e58b-4059-a95c-0d711aa4b6ae';
const body='Synthetic exact pending comparison.\n'+'aé𐀀b\n'.repeat(2800)+'\n\nComputa session marker: '+marker;
async function initial(model="Qwen3.7-Plus"){
 const f=fixture({completeOnSend:false});
 for(let i=0;i<8;i++){const r=await f.run('selectModel',{modelChoice:choice(model)});expect(r.error).toBeUndefined();if(r.selected)break;}
 expect((await f.run('prepare')).prepared).toBe(true);
 expect((await f.run('insert',{prompt:body})).inserted).toBe(true);
 expect((await f.run('sendReady',{prompt:body})).sendReady).toBe(true);
 const hash=await fingerprint(body);
 expect((await f.run('submit',{prompt:body,savedSubmissionFingerprint:hash})).submitted).toBe(true);
 const chunk=f.userBody.parentElement!;
 chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand is-collapsed');
 const expand=new f.Node('BUTTON',{class:'chat-user-message-expand-toggle chat-user-message-expand-toggle-pc','aria-label':'Expand'});
 chunk.append(expand);f.userBody.text=body.slice(0,10240);
 f.answer.setAttribute('id','chat-response-message-');const phaseWrapper=f.phase.parentElement!;f.phase.detach();
 const loading=new f.Node('DIV',{class:'response-loading'});f.answer.append(loading);
 const input={allowSavedResponseChoice:true,allowQwenInitialResponseIdentity:true,allowQwenFirstBodyExpansion:true,expectedModelChoice:choice(model),savedSubmissionFingerprint:hash};
 return {f,chunk,expand,input,hash,loading,phaseWrapper};
}
function mountPair(x:Awaited<ReturnType<typeof initial>>, detached = false){
 const {f,loading}=x;loading.detach();f.answer.setAttribute('id','chat-response-message-'+answerID);
 f.answer.detach();f.answerRoot.setAttribute('class','qwen-chat-message qwen-chat-message-assistant qwen-chat-message-dual-message');
 const wrapper=new f.Node('DIV',{class:'smrm'}),list=new f.Node('DIV',{class:'smrm-list smrm-list--mac'});
 const first=detached?f.answer.cloneNode(true):f.answer;const other=f.answer.cloneNode(true);other.values.id='chat-response-message-'+secondID;
 const controls:any[]=[];
 for(const [index,response]of[first,other].entries()){
  const id=[answerID,secondID][index],card=new f.Node('DIV',{class:'smrm-card',id:id+'-smrm-card'});
  const header=new f.Node('DIV',{class:'smrm-card__header'},'Response '+(index+1));
  const body=new f.Node('DIV',{class:'smrm-card__body'}),content=new f.Node('DIV',{class:'smrm-card__content'});
  const footer=new f.Node('DIV',{class:'smrm-card__footer'}),control=new f.Node('BUTTON',{class:'smrm-card__prefer-btn'},'I prefer this response');
  control.disabled=true;controls.push(control);content.append(response);body.append(content);footer.append(control);card.append(header,body,footer);list.append(card);
 }
 wrapper.append(list);f.answerRoot.append(wrapper);return {wrapper,controls};
}
for(const model of ['Qwen3.7-Plus','Qwen3.8-Max'])test(model+' hands an unchanged optimistic presentation to the exact SMRM pair before any response identity',async()=>{
 const x=await initial(model),{f,input,expand,chunk}=x;
 expect((await f.run('inspect',input)).qwenFirstBodyExpansionPending).toBe(true);
 const state=f.world.__computaQwenSavedSessionV1,original=state.firstDisplayWitness,pins=[...original.pins];
 expect(state.first).toBeNull();expect(state.responseIdentity).toBeNull();
 const p=mountPair(x);
 const first=await f.run('inspect',input);
 expect(first.qwenFirstBodyExpansionPending).toBe(true);expect(first.error).toBeUndefined();
 expect(state.firstDisplayWitness).toBeUndefined();expect(state.firstDisplay.settledPair).toBe(original);
 expect(state.firstDisplay.pins.slice(0,-1)).toEqual(pins.slice(0,-1));
 expect(state.firstDisplay.pins.at(-1)).toBe(p.wrapper);expect(state.responseIdentity).toBeNull();expect(state.first).toBeNull();
 expect(expand.clicks).toBe(0);expect(p.controls.map(n=>n.clicks)).toEqual([0,0]);
 expand.onClick=()=>{chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand');expand.setAttribute('aria-label','Collapse');f.userBody.text=body;};
 expect((await f.run('inspect',input)).qwenFirstBodyExpansionPending).toBe(true);expect(expand.clicks).toBe(1);
 const waiting=await f.run('inspect',input);expect(waiting.savedResponseChoice.state).toBe('waiting');
 expect(waiting.savedResponseChoice.firstUserFingerprint).toBe(x.hash);expect(waiting.text).toBeUndefined();expect(state.first).toBeNull();
 p.controls.forEach(n=>n.disabled=false);
 const ready=await f.run('inspect',input);expect(ready.savedResponseChoice.state).toBe('ready');
 const grant={version:1,kind:'qwen_smrm',policy:'first_observed_card_v1',grant:'caf8aa04-4bac-438b-9280-a98703ec0bee',candidate:ready.savedResponseChoice.candidate,responseIDs:[answerID,secondID],selectedResponseID:answerID,sequence:1};
 p.controls[0].onClick=()=>{p.wrapper.detach();f.answer.detach();f.answerRoot.append(f.answer);f.answerRoot.setAttribute('class','qwen-chat-message qwen-chat-message-assistant');x.phaseWrapper.append(f.phase);f.complete();};
 const dispatched=await f.run('inspect',{...input,savedResponseChoiceGrant:grant,evaluationDeadlineEpochMilliseconds:Date.now()+1000});
 expect(dispatched.savedResponseChoice.state).toBe('dispatched');expect(dispatched.text).toBeUndefined();expect(state.first).toBeNull();
 const accepted=await f.run('inspect',input);expect(accepted.error).toBeUndefined();expect(accepted.firstUserFingerprint).toBe(x.hash);expect(accepted.firstUserVerified).toBe(true);expect(accepted.answerComplete).toBe(true);
 expect(p.controls.map(n=>n.clicks)).toEqual([1,0]);expect(expand.clicks).toBe(1);expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);
 const repeated=await f.run('inspect',{...input,savedResponseChoiceGrant:grant,evaluationDeadlineEpochMilliseconds:Date.now()+1000});
 expect(repeated.savedResponseChoice.state).toBe('acknowledged');expect(p.controls.map(n=>n.clicks)).toEqual([1,0]);
});
test('a comparison cannot adopt changed witness pins, native grants, prompt, model or controls',async()=>{
 for(const fault of ['body','control','root','user-turn','answer-root','editor','composer','model','route','preview','hash','grant','cleanup','foreign-tail','pair-control','double-user']){
  const x=await initial(),{f,input,expand}=x;
  expect((await f.run('inspect',input)).qwenFirstBodyExpansionPending).toBe(true);
  const p=mountPair(x),over:any={...input};
  if(fault==='body'){const fresh=new f.Node('P',{...f.userBody.values},f.userBody.text);f.userBody.detach();x.chunk.append(fresh);}
  if(fault==='control'){expand.detach();x.chunk.append(new f.Node('BUTTON',{...expand.values}));}
  if(fault==='root'){const old=f.root;old.detach();f.turn.children[0].append(old.cloneNode(true));}
  if(fault==='user-turn'){const prior=f.root.parentElement!;f.root.detach();const fresh=new f.Node('DIV',{...prior.values});f.turn.children.unshift(fresh);fresh.parentElement=f.turn;fresh.append(f.root);}
  if(fault==='answer-root'){const old=f.answerRoot;old.detach();f.turn.children[1].append(old.cloneNode(true));}
  if(fault==='editor'){const old=f.editor;old.detach();f.scope.append(new f.Node('TEXTAREA',{...old.values}));}
  if(fault==='composer')f.editor.value='foreign draft';
  if(fault==='model')f.modelName.text='Qwen3.8-Max';
  if(fault==='route')f.document.URL='https://chat.qwen.ai/c/11111111-1111-4111-8111-111111111111';
  if(fault==='preview')f.userBody.text='x'+f.userBody.text.slice(1);
  if(fault==='hash')over.savedSubmissionFingerprint='0'.repeat(64);
  if(fault==='grant')over.allowQwenFirstBodyExpansion=false;
  if(fault==='cleanup')over.savedCleanupInspection=true;
  if(fault==='foreign-tail'){f.answer.detach();f.body.append(f.answer);p.wrapper.querySelectorAll('.smrm-card__content')[0].append(f.answer.cloneNode(true));}
  if(fault==='pair-control'){expect((await f.run('inspect',input)).qwenFirstBodyExpansionPending).toBe(true);const control=p.controls[0];control.detach();p.wrapper.querySelectorAll('.smrm-card__footer')[0].append(control.cloneNode(true));}
  if(fault==='double-user')f.turn.append(f.root.cloneNode(true));
  const rejected=await f.run('inspect',over);expect(rejected.error,fault).toBeDefined();
  for(const key of ['text','firstUserVerified','modelEvidence','answerComplete'])expect(rejected[key],fault).toBeUndefined();
  expect(expand.clicks,fault).toBe(0);expect(p.controls.map(n=>n.clicks),fault).toEqual([0,0]);expect(f.send.clicks,fault).toBe(1);
 }
});
test('a detached empty-ID presentation may hand off under the same physical user and assistant ancestors',async()=>{
 const x=await initial(),{f,input}=x;
 expect((await f.run('inspect',input)).qwenFirstBodyExpansionPending).toBe(true);
 const witness=f.world.__computaQwenSavedSessionV1.firstDisplayWitness,old=witness.pins.at(-1);
 const p=mountPair(x,true);expect(old.isConnected).toBe(false);expect(p.wrapper.contains(old)).toBe(false);
 const r=await f.run('inspect',input);expect(r.qwenFirstBodyExpansionPending).toBe(true);expect(r.error).toBeUndefined();
 const state=f.world.__computaQwenSavedSessionV1;expect(state.firstDisplay.settledPair).toBe(witness);
 expect(state.firstDisplay.pins.slice(0,-1)).toEqual(witness.pins.slice(0,-1));expect(state.firstDisplay.pins.at(-1)).toBe(p.wrapper);
 expect(state.first).toBeNull();expect(state.responseIdentity).toBeNull();expect(x.expand.clicks).toBe(0);expect(p.controls.map(n=>n.clicks)).toEqual([0,0]);expect(f.send.clicks).toBe(1);
});
test('an ordinary response identity remains a separate immutable prohibition',async()=>{
 const x=await initial();
 // A short/full visible body does not acquire the long preview witness.
 x.f.userBody.text=body;x.chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand');x.expand.setAttribute('aria-label','Collapse');
 expect((await x.f.run('inspect',x.input)).qwenInitialResponseIdentityPending).toBe(true);
 const s=x.f.world.__computaQwenSavedSessionV1;expect(s.responseIdentity).toBeDefined();expect(s.firstDisplayWitness).toBeUndefined();
 const p=mountPair(x),r=await x.f.run('inspect',x.input);
 expect(r.qwenResponseChoiceStage).toBe('admission_response_identity');expect(r.error).toBe('conversation_changed');expect(s.first).toBeNull();
 expect(p.controls.map(n=>n.clicks)).toEqual([0,0]);expect(x.f.send.clicks).toBe(1);
});
