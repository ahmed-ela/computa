import {expect,test} from 'bun:test';
import {fixture,choice,prompt,marker,fingerprint,answerID,conversationID} from './embedded-qwen-adapter-fixture';
const notice="You've reached today's Qwen3.8-Max limit. Upgrade your membership or switch to another model above to continue.";
async function sent({model='Qwen3.7-Plus',body=prompt,progress=true,quota=true}={}){
 const f=fixture({completeOnSend:false,modelQuota:quota});
 for(let i=0;i<8;i++){const r=await f.run('selectModel',{modelChoice:choice(model)});expect(r.error).toBeUndefined();if(r.selected)break;}
 expect((await f.run('prepare')).prepared).toBe(true);expect((await f.run('insert',{prompt:body})).inserted).toBe(true);
 expect((await f.run('sendReady',{prompt:body})).sendReady).toBe(true);const hash=await fingerprint(body);
 expect((await f.run('submit',{prompt:body,savedSubmissionFingerprint:hash})).submitted).toBe(true);
 const inspect=(overrides:any={})=>f.run('inspect',{allowQwenInitialResponseIdentity:true,allowQwenFirstBodyExpansion:true,expectedModelChoice:choice(model),savedSubmissionFingerprint:hash,qwenProgressUI:progress,...overrides});
 return{f,hash,inspect};
}
function tv(f:any,reason='update_member',text=notice){
 const card=new f.Node('SECTION',{class:'exceed-limit-error-card','data-testid':'exceed-limit-error-card','data-aes-exp':'expExceedLimitCard','data-chat-id':conversationID,'data-msg-id':answerID,'data-paywall-reason':reason,'data-paywall-scene':'t2t'});
 card.append(new f.Node('P',{},text));f.right.append(card);return card;
}
function withoutUI(r:any){const value={...r};delete value.qwenReplyUI;return value;}
function safe(ui:any){
 expect(Object.keys(ui).sort()).toEqual(['version','scope','stop','loading','footer','tv','alert','reason','daily','terminal','capped','visibility','hidden'].sort());
 for(const word of ['PRIVATE','https://','chat.qwen.ai',conversationID,answerID,notice])expect(JSON.stringify(ui)).not.toContain(word);
}
test('actual Stop/loading/footer facts are separate from derived engine busy and preserve the ordinary reply',async()=>{
 for(const phase of ['streaming','loading','finished']){
  const run=async(progress:boolean)=>{
   const {f,inspect}=await sent({progress});if(phase==='loading'){f.phase.detach();f.answer.append(new f.Node('DIV',{class:'response-loading'}));}
   if(phase==='finished')f.complete();const result=await inspect();expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);return result;
  };
  const old=await run(false),current=await run(true),ui=current.qwenReplyUI;safe(ui);
  expect(withoutUI(current)).toEqual(old);expect(ui.scope).toBe('single');expect(ui.stop).toBe(phase!=='finished');
  expect(ui.loading).toBe(phase==='loading'?1:0);expect(ui.footer).toBe(phase==='finished'?1:0);expect(ui.terminal).toBe(phase==='finished');
  expect(ui.tv).toBe(0);expect(ui.alert).toBe(0);expect(ui.reason).toBe('none');expect(ui.daily).toBeNull();expect(ui.capped).toBe(false);
 }
});
test('no physical reply and empty-root pending receipts keep unavailable fields null, never false zeros',async()=>{
 const noReply=await sent();noReply.f.answerRoot.detach();const missing=await noReply.inspect();safe(missing.qwenReplyUI);
 expect(missing.qwenReplyUI.scope).toBe('none');expect(missing.qwenReplyUI.stop).toBe(true);
 for(const key of ['loading','footer','tv','alert','reason','daily','terminal'])expect(missing.qwenReplyUI[key]).toBeNull();
 const empty=await sent({model:'Qwen3.8-Max'});empty.f.answer.detach();const pending=await empty.inspect();safe(pending.qwenReplyUI);
 expect(pending.qwenInitialResponseIdentityPending).toBe(true);expect(pending.qwenReplyUI.scope).toBe('empty_root');
 for(const key of ['stop','loading','footer','tv','alert','reason','daily','terminal'])expect(pending.qwenReplyUI[key]).toBeNull();
 expect(empty.f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(empty.f.world.__computaQwenSavedSessionV1.responseIdentity).toBeDefined();
});
test('a pre-body exact Max TV notice is diagnostic only while the original empty-ID preview still waits',async()=>{
 const body='Synthetic long exact UI witness.\n'+'aé𐀀b\n'.repeat(2800)+'\n\nComputa session marker: '+marker;
 const {f,inspect}=await sent({model:'Qwen3.8-Max',body});const chunk=f.userBody.parentElement!;
 chunk.setAttribute('class','chunked-text-renderer-root chunked-text-renderer-root-with-expand is-collapsed');
 const expand=new f.Node('BUTTON',{class:'chat-user-message-expand-toggle chat-user-message-expand-toggle-pc','aria-label':'Expand'});chunk.append(expand);f.userBody.text=body.slice(0,10240);
 f.answer.setAttribute('id','chat-response-message-');f.phase.detach();f.answer.append(new f.Node('DIV',{class:'response-loading'}));tv(f);
 const pending=await inspect(),ui=pending.qwenReplyUI;safe(ui);expect(pending.qwenFirstBodyExpansionPending).toBe(true);
 expect(ui.scope).toBe('single');expect(ui.stop).toBeNull();expect(ui.loading).toBe(1);expect(ui.footer).toBe(0);expect(ui.tv).toBe(1);expect(ui.alert).toBe(0);
 expect(ui.reason).toBe('update_member');expect(ui.daily).toBe(true);expect(ui.terminal).toBeNull();expect(pending.error).toBeUndefined();expect(pending.qwenQuotaScope).toBeUndefined();
 expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();expect(f.world.__computaQwenSavedSessionV1.responseIdentity).toBeNull();expect(expand.clicks).toBe(0);expect(f.send.clicks).toBe(1);
});
test('known Max notice remains observable after body binding and is not attributed to Plus',async()=>{
 for(const model of ['Qwen3.8-Max','Qwen3.7-Plus']){
  const {f,inspect}=await sent({model,quota:false});
  const bound=await inspect();expect(bound.error).toBeUndefined();
  expect(f.world.__computaQwenSavedSessionV1.first).toBeDefined();tv(f);
  const result=await inspect({allowFirstUserBinding:false,expectedFirstUserFingerprint:bound.firstUserFingerprint});
  expect(result.error).toBeUndefined();safe(result.qwenReplyUI);
  expect(result.qwenReplyUI.tv).toBe(1);expect(result.qwenReplyUI.reason).toBe('update_member');
  expect(result.qwenReplyUI.daily).toBe(model==='Qwen3.8-Max'?true:null);
  expect(result.qwenQuotaScope).toBeUndefined();expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);
 }
});
test('error widget counts exclude authored lookalikes and retain no server wording or unknown reason',async()=>{
 const {f,inspect}=await sent();tv(f,'PRIVATE_REASON','PRIVATE_NOTICE');
 const generic=new f.Node('DIV',{class:'qwen-messsage-status qwen-alert'},'PRIVATE_ALERT');
 Object.defineProperty(generic,'textContent',{get(){throw Error('diagnostic must not read generic message text');}});f.right.append(generic);
 const fake=tv(f);fake.detach();f.markdown.append(fake);const quoted=new f.Node('DIV',{class:'qwen-messsage-status qwen-alert'},'PRIVATE_AUTHORED');f.markdown.append(quoted);
 const result=await inspect(),ui=result.qwenReplyUI;safe(ui);expect(ui.tv).toBe(1);expect(ui.alert).toBe(1);expect(ui.reason).toBe('other');expect(ui.daily).toBeNull();
 expect(result.error).toBeUndefined();expect(result.qwenQuotaScope).toBeUndefined();expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);
});
test('counts saturate at three and report saturation explicitly without merging error meanings',async()=>{
 const {f,inspect}=await sent();f.phase.detach();
 for(let i=0;i<5;i++){f.answer.append(new f.Node('DIV',{class:'response-loading'}));tv(f);f.right.append(new f.Node('DIV',{class:'qwen-messsage-status qwen-alert'}));}
 const result=await inspect(),ui=result.qwenReplyUI;safe(ui);expect(ui.loading).toBe(3);expect(ui.tv).toBe(3);expect(ui.alert).toBe(3);expect(ui.capped).toBe(true);expect(ui.reason).toBe('ambiguous');expect(ui.daily).toBeNull();expect(f.send.clicks).toBe(1);
});
test('diagnostic selector exceptions and malformed scopes cannot change the original response or first error',async()=>{
 const run=async(progress:boolean,fail:boolean)=>{
  const {f,inspect}=await sent({progress});if(fail)f.modelName.text='Qwen3.8-Max';
  const query=f.answer.querySelectorAll.bind(f.answer);f.answer.querySelectorAll=(selector:string)=>{if(selector==='.response-loading')throw Error('PRIVATE_DIAGNOSTIC_FAILURE');return query(selector);};
  const result=await inspect();expect(result.qwenReplyUI).toBeUndefined();expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);return result;
 };
 for(const fail of [false,true])expect(await run(true,fail)).toEqual(await run(false,fail));
 const {f}=await sent(),dom=f.read();expect(dom.replyProgressUI({answers:[]},{},null,false).stop).toBeNull();
 expect(dom.replyProgressUI({answers:[f.answerRoot],answer:{root:f.root,content:f.answer}},null,null,false)).toBeNull();
});
test('new metadata is absent from cleanup/model-only reads and never triggers an extra Send or preference',async()=>{
 const {f,inspect,hash}=await sent();await inspect();
 const cleanup=await inspect({savedCleanupInspection:true,allowFirstUserBinding:false,expectedFirstUserFingerprint:hash});expect(cleanup.qwenReplyUI).toBeUndefined();
 const result=await f.run('verifyModel',{qwenProgressUI:true,expectedModelChoice:choice()});expect(result.qwenReplyUI).toBeUndefined();
 expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);expect(f.confirm.clicks).toBe(0);
});

test('document visibility facts are explicit callback observations and unknown values never become false',async()=>{
 for(const value of ['visible','hidden','prerender','PRIVATE_STATE']){
  const {f,inspect}=await sent();f.document.visibilityState=value;f.document.hidden=value==='hidden';
  const ui=(await inspect()).qwenReplyUI;safe(ui);expect(ui.visibility).toBe(value==='PRIVATE_STATE'?'unknown':value);expect(ui.hidden).toBe(value==='hidden');
 }
 const {f,inspect}=await sent();let visibilityReads=0,hiddenReads=0;
 Object.defineProperty(f.document,'visibilityState',{get(){visibilityReads++;throw Error('PRIVATE_VISIBILITY_FAILURE');}});
 Object.defineProperty(f.document,'hidden',{get(){hiddenReads++;return true;}});
 const ui=(await inspect()).qwenReplyUI;safe(ui);expect(ui.visibility).toBe('unknown');expect(ui.hidden).toBe(true);
 expect(visibilityReads).toBeGreaterThan(0);expect(hiddenReads).toBe(visibilityReads);expect(f.send.clicks).toBe(1);expect(f.more.clicks).toBe(0);
});
