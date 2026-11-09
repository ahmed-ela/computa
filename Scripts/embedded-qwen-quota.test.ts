import {expect,test} from 'bun:test';
import {fixture,choice,prompt,marker,fingerprint,conversationID,answerID} from './embedded-qwen-adapter-fixture';
// Compare the same guarded engine with only the new entry capability disabled.
// This keeps the regression controls runnable in the repository checkout.
const baselineFixture = (options:any={}) => fixture({...options,modelQuota:false});
const max='Qwen3.8-Max';
const notice="You've reached today's Qwen3.8-Max limit. Upgrade your membership or switch to another model above to continue.";
async function setup(factory:any=fixture,label=max,outbound=prompt) {
 const f=factory({completeOnSend:false});await f.run('inspect');
 for(let i=0;i<8;i++)if((await f.run('selectModel',{modelChoice:choice(label)})).selected)break;
 await f.run('prepare');await f.run('insert',{prompt:outbound,expectedFirstUserMarker:marker});await f.run('sendReady',{prompt:outbound});
 const digest=await fingerprint(outbound);await f.run('submit',{prompt:outbound,savedSubmissionFingerprint:digest});
 const inspect=(overrides:any={})=>f.run('inspect',{expectedModelChoice:choice(label),savedSubmissionFingerprint:digest,
  allowQwenInitialResponseIdentity:true,allowQwenFirstBodyExpansion:true,allowFirstUserBinding:true,...overrides});
 return {f,inspect,digest};
}
function card(f:any,reason='ExceedLimit') {
 const node=new f.Node('SECTION',{class:'exceed-limit-error-card','data-testid':'exceed-limit-error-card','data-aes-exp':'expExceedLimitCard',
  'data-chat-id':conversationID,'data-msg-id':answerID,'data-paywall-reason':reason,'data-paywall-scene':'t2t','data-user-type':'free'});
 const p=new f.Node('P',{},notice);node.append(p);f.right.append(node);return {node,p};
}
function noActions(f:any,before:any) {
 expect(f.send.clicks).toBe(before.send);expect(f.actions.map((a:any)=>a.clicks)).toEqual(before.actions);
 expect(f.more.clicks).toBe(before.more);expect(f.confirm.clicks).toBe(before.confirm);expect(f.editor.value).toBe(before.editor);
}
function actions(f:any){return {send:f.send.clicks,actions:f.actions.map((a:any)=>a.clicks),more:f.more.clicks,confirm:f.confirm.clicks,editor:f.editor.value};}

test('strict current Max TV reasons stop with closed scope and no positive or action proof',async()=>{
 for(const reason of ['ExceedLimit','quota_exhausted','update_member']) {
  const {f,inspect}=await setup();card(f,reason);const before=actions(f);const out=await inspect();
  expect(out).toEqual({error:'website_usage_limit',modelEvidence:{selected:choice(max),verification:'website_selection',source:'model_picker_label'},
   qwenQuotaScope:{version:1,kind:'qwen_model_quota_v1',surface:'tv_card',reason,scene:'t2t',choice:choice(max)}});
  expect(Object.keys(out).sort()).toEqual(['error','modelEvidence','qwenQuotaScope']);
  expect(JSON.stringify(out)).not.toContain(notice);expect(JSON.stringify(out)).not.toContain(conversationID);noActions(f,before);
 }
});

test('negative quota observation precedes loading-only empty response identity guard without adopting fid',async()=>{
 const {f,inspect}=await setup();card(f);f.answer.setAttribute('id','chat-response-message-');
 expect((await inspect()).error).toBe('website_usage_limit');
 const baseline=await setup(baselineFixture);card(baseline.f);baseline.f.answer.setAttribute('id','chat-response-message-');
 const original=await baseline.inspect();expect(original.error).toBeTruthy();expect(original.qwenQuotaScope).toBeUndefined();
 expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(f.world.__computaQwenSavedSessionV1.responseIdentity).toBeNull();
});

test('unknown quota/error shape and authored lookalikes preserve exact baseline behavior',async()=>{
 const variants=['prompt','answer','code','nestedCard','generic','unknownReason','upgradeOnly','nonDailyRestriction','wrongScene','wrongChat','wrongMsg','wrongExposure',
  'wrongTestID','nearText','otherModelText','hidden','duplicate','extraParagraph','detached','wrongRight','foreignUserRoute','collapsedPrefix','refusal'];
 for(const variant of variants) {
  const run=async(factory:any)=>{
   const {f,inspect}=await setup(factory);const c=card(f);
   if(variant==='prompt'){c.node.detach();f.userBody.text=notice;}
   if(variant==='answer'){c.node.detach();f.literal.text=notice;}
   if(variant==='code'){c.node.detach();f.paragraph.append(new f.Node('PRE',{},notice));}
   if(variant==='nestedCard'){c.node.detach();f.paragraph.append(c.node);}
   if(variant==='generic'){c.node.detach();f.right.append(new f.Node('DIV',{class:'qwen-messsage-status qwen-alert'},notice));}
   if(variant==='unknownReason')c.node.setAttribute('data-paywall-reason','RateLimited');
   if(variant==='upgradeOnly'){c.node.setAttribute('data-paywall-reason','update_member');c.p.text='Upgrade your membership.';}
   if(variant==='nonDailyRestriction'){c.node.setAttribute('data-paywall-reason','update_member');c.p.text='This feature requires a membership.';}
   if(variant==='wrongScene')c.node.setAttribute('data-paywall-scene','agent_mode');
   if(variant==='wrongChat')c.node.setAttribute('data-chat-id','11111111-1111-4111-8111-111111111111');
   if(variant==='wrongMsg')c.node.setAttribute('data-msg-id','11111111-1111-4111-8111-111111111111');
   if(variant==='wrongExposure')c.node.setAttribute('data-aes-exp','expRequestCard');
   if(variant==='wrongTestID')c.node.setAttribute('data-testid','unknown');
   if(variant==='nearText')c.p.text=notice+' Later.';
   if(variant==='otherModelText')c.p.text=notice.replace('Qwen3.8-Max','Qwen3.7-Plus');
   if(variant==='hidden')c.node.setAttribute('hidden','');
   if(variant==='duplicate')card(f);
   if(variant==='extraParagraph')c.node.append(new f.Node('P',{},'Other notice'));
   if(variant==='detached')c.node.detach();
   if(variant==='wrongRight'){c.node.detach();f.answer.append(c.node);}
   if(variant==='foreignUserRoute')f.userContainer.setAttribute('data-chat-id','11111111-1111-4111-8111-111111111111');
   if(variant==='collapsedPrefix')f.userBody.text=prompt.slice(0,12);
   if(variant==='refusal'){c.node.detach();f.literal.text=JSON.stringify({type:'message',text:notice});f.complete();}
   const before=actions(f),out=await inspect();noActions(f,before);expect(out.qwenQuotaScope,variant).toBeUndefined();return out;
  };
  expect(await run(fixture),variant).toEqual(await run(baselineFixture));
 }
});

test('wrong model and native ownership context cannot mint a scoped or broad quota stop',async()=>{
 for(const variant of ['Plus','selectedChanged','expectedChanged','owner','generation','submission','marker','fingerprint','cleanup','beforeSend']) {
  const {f,inspect}=await setup(fixture,variant==='Plus'?'Qwen3.7-Plus':max);card(f);const overrides:any={};
  if(variant==='selectedChanged')f.modelName.text='Qwen3.7-Plus';
  if(variant==='expectedChanged')overrides.expectedModelChoice=choice('Qwen3.7-Plus');
  if(variant==='owner')overrides.ownerToken='11111111-1111-4111-8111-111111111111';
  if(variant==='generation')overrides.documentGeneration='11111111-1111-4111-8111-111111111111';
  if(variant==='submission')overrides.savedSubmissionFingerprint='a'.repeat(64);
  if(variant==='marker')overrides.expectedFirstUserMarker='11111111-1111-4111-8111-111111111111';
  if(variant==='fingerprint')overrides.expectedFirstUserFingerprint='a'.repeat(64);
  if(variant==='cleanup')overrides.savedCleanupInspection=true;
  if(variant==='beforeSend')f.world.__computaQwenSavedSessionV1.submitted=false;
  const before=actions(f),out=await inspect(overrides);expect(out.qwenQuotaScope,variant).toBeUndefined();expect(out.error,variant).not.toBe('website_usage_limit');noActions(f,before);
 }
});

test('retained physical first/answer witnesses reject replacement and keep existing verification behavior',async()=>{
 for(const which of ['first','answer','canonical']) {
  const {f,inspect}=await setup();const ordinary=await inspect();expect(ordinary.error).toBeUndefined();
  card(f);const state=f.world.__computaQwenSavedSessionV1;
  if(which==='first')state.first={...state.first,root:new f.Node('DIV')};
  else state.responseIdentity={canonical:which==='canonical'?'https://chat.qwen.ai/c/11111111-1111-4111-8111-111111111111':f.document.URL,first:state.first,answer:{root:which==='answer'?new f.Node('DIV'):f.answerRoot,content:f.answer,turn:f.answerRoot.parentElement}};
  const before=actions(f),out=await inspect({allowFirstUserBinding:false,expectedFirstUserFingerprint:ordinary.firstUserFingerprint});
  expect(out.qwenQuotaScope).toBeUndefined();expect(out.error).not.toBe('website_usage_limit');noActions(f,before);
 }
});


test('no TV candidate preserves provisional pending without reading an unsettled picker',async()=>{
 const {f,inspect}=await setup();f.document.URL='https://chat.qwen.ai/c/new-chat';
 let pickerReads=0;Object.defineProperty(f.modelName,'textContent',{get(){pickerReads++;throw Error('Unsettled picker must not be inspected yet');}});
 const out=await inspect({allowQwenProvisionalRoute:true});
 expect(out.error).toBeUndefined();expect(out.qwenProvisionalRoutePending).toBe(true);expect(out.qwenQuotaScope).toBeUndefined();expect(pickerReads).toBe(0);
});

test('a TV candidate still requires fresh selected model before any usage receipt',async()=>{
 const {f,inspect}=await setup();card(f,'update_member');let reads=0;
 Object.defineProperty(f.modelName,'textContent',{get(){reads++;throw Error('No fresh selection');}});
 const out=await inspect();expect(out.error).not.toBe('website_usage_limit');expect(out.qwenQuotaScope).toBeUndefined();expect(reads).toBeGreaterThan(0);
});

test('retained nonempty identity and display answer UUIDs cannot be replaced by quota or fid',async()=>{
 for(const kind of ['identity','display'])for(const empty of [false,true]) {
  const {f,inspect}=await setup();const ordinary=await inspect();expect(ordinary.error).toBeUndefined();
  const state=f.world.__computaQwenSavedSessionV1,other='11111111-1111-4111-8111-111111111111';
  if(kind==='identity')state.responseIdentity={canonical:f.document.URL,first:state.first,userTurn:f.root.parentElement,outer:f.turn,
   answerID,answer:{root:f.answerRoot,content:f.answer,turn:f.answerRoot.parentElement}};
  else state.firstDisplay={answerID};
  const c=card(f,'update_member');c.node.setAttribute('data-msg-id',other);f.answer.setAttribute('id','chat-response-message-'+(empty?'':other));
  const before=actions(f),out=await inspect({allowFirstUserBinding:false,expectedFirstUserFingerprint:ordinary.firstUserFingerprint});
  expect(out.error).not.toBe('website_usage_limit');expect(out.qwenQuotaScope).toBeUndefined();noActions(f,before);
 }
});

async function heldExpandedQuota() {
 const outbound='Synthetic exact long held quota.\n'+'aé𐀀b\n'.repeat(2800)+'\n\nComputa session marker: '+marker;
 const x=await setup(fixture,max,outbound),{f,inspect}=x;
 const chunk=f.userBody.parentElement!,expand=new f.Node('BUTTON',{class:'chat-user-message-expand-toggle chat-user-message-expand-toggle-pc','aria-label':'Expand'});
 chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand is-collapsed');chunk.append(expand);f.userBody.text=outbound.slice(0,10240);f.phase.detach();card(f,'update_member');
 expand.onClick=()=>{chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand');expand.setAttribute('aria-label','Collapse');f.userBody.text=outbound;};
 const pending=await inspect();expect(pending.qwenFirstBodyExpansionPending).toBe(true);expect(pending.qwenQuotaScope).toBeUndefined();expect(expand.clicks).toBe(1);
 expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(f.world.__computaQwenSavedSessionV1.firstDisplay).toBeDefined();
 return {...x,chunk,expand,outbound};
}
test('a legitimate held expanded full body can classify strict TV before ordinary body or reply proof',async()=>{
 const {f,inspect,expand,outbound}=await heldExpandedQuota();const before=actions(f);expect(f.userBody.text).toBe(outbound);
 const result=await inspect();expect(result.error).toBe('website_usage_limit');expect(result.qwenQuotaScope.reason).toBe('update_member');
 expect(Object.keys(result).sort()).toEqual(['error','modelEvidence','qwenQuotaScope']);expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(f.world.__computaQwenSavedSessionV1.responseIdentity).toBeNull();
 noActions(f,before);expect(expand.clicks).toBe(1);expect(f.send.clicks).toBe(1);
});
test('held full-body quota detection still refuses replacement user, control or answer pins',async()=>{
 for(const pin of ['body','control','answer']) {
  const {f,inspect,chunk,expand,outbound}=await heldExpandedQuota();
  if(pin==='body'){const fresh=new f.Node('P',{...f.userBody.values},outbound);f.userBody.detach();chunk.children.unshift(fresh);fresh.parentElement=chunk;}
  if(pin==='control'){expand.detach();chunk.append(new f.Node('BUTTON',{...expand.values}));}
  if(pin==='answer'){f.answer.detach();f.answerRoot.append(f.answer.cloneNode(true));}
  const before=actions(f),result=await inspect();expect(result.qwenQuotaScope,pin).toBeUndefined();expect(result.error,pin).toBeDefined();expect(result.error,pin).not.toBe('website_usage_limit');
  noActions(f,before);expect(expand.clicks,pin).toBe(1);expect(f.send.clicks,pin).toBe(1);
 }
});
