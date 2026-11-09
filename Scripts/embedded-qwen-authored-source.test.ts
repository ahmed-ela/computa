import {expect,test} from 'bun:test';
import {ownedRaw,channel} from './embedded-qwen-authored-source-fixture';
import {choice} from './embedded-qwen-adapter-fixture';

const patch='*** Begin Patch\n*** Update File: /synthetic/a.py\n@@\n-old\n+"λ😀\\n"\n*** End Patch';
const body=JSON.stringify({type:'tool_calls',calls:[{name:'apply_patch',input:patch}],commentary:'[[12]] **raw** `ticks`\n\t"quote"\\path'});
const raw='```json\n'+body+'\n```';

test('one complete current-host ANSWER crosses only one native-granted read with zero Clipboard or click calls',async()=>{
  const t=await ownedRaw(raw);
  expect(t.first.error).toBeUndefined();expect(t.first.firstUserVerified).toBe(true);
  expect(t.first.text).toBe('');expect(t.first.answerComplete).toBe(false);
  expect(t.first.qwenCodePayload).toMatchObject({version:2,state:'pending',sourceKind:'raw_answer_v1'});
  let awaits=0;t.f.beforeDigest(()=>{awaits++;expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);});
  const result=await t.sample();expect(awaits).toBe(1);expect(result.error).toBeUndefined();expect(result.text).toBe(raw);
  expect(JSON.parse(result.text.slice(8,-4)).calls[0].input).toBe(patch);
  expect(result.answerComplete).toBe(true);expect(result.qwenCodePayload).toEqual({version:2,state:'sampled',grant:t.grant.grant,
    candidate:t.grant.candidate,responseID:t.grant.responseID,sourceKind:'raw_answer_v1'});
  expect(t.world.delegated()).toBe(0);expect(t.f.send.clicks).toBe(1);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
  t.f.beforeDigest(()=>{});expect((await t.sample()).error).toBeTruthy();expect(t.world.delegated()).toBe(0);
});

test('ineligible metadata, duplicate or foreign phases preserve the exact original DOM refusal and zero actions',async()=>{
  const cases=['twoAnswers','emptySecondAnswer','unknownPhase','toolPhase','deepThinking','attachment','placeholder','legacyContent','opaqueInfo','opaqueMeta','mcp','extraKey','sparse','accessor','outsideText','twoMessages','wrongParent','role','notDone','userContext','models','modelMetadata','phaseMetadata','language','accessorMetadata','symbols','listCap','treeCap'];
  for(const kind of cases){
    const t=await ownedRaw(raw,(p,f)=>{
      if(kind==='userContext')p.message.userContext={hidden:'PRIVATE'};if(kind==='models')p.message.models=['foreign'];
      if(kind==='modelMetadata')p.message.modelName={hidden:'PRIVATE'};if(kind==='phaseMetadata')p.answer.groupIndex=-1;
      if(kind==='language')p.answer.lang_code='translated';if(kind==='accessorMetadata')Object.defineProperty(p.message,'fid',{get(){throw Error('unread');},enumerable:true});
      if(kind==='symbols')p.answer[Symbol('foreign')]='PRIVATE';if(kind==='listCap')p.message.content_list=Array(33).fill(p.hidden);
      if(kind==='treeCap')p.current.children=Array(65).fill(null);
      if(kind==='twoAnswers'||kind==='emptySecondAnswer')p.message.content_list.push({...p.answer,content:kind==='emptySecondAnswer'?'':raw});
      if(kind==='unknownPhase')p.hidden.phase='future';if(kind==='toolPhase')p.hidden.phase='tool';if(kind==='deepThinking')p.hidden.phase='DeepThinking';
      if(kind==='attachment')p.answer.extra={prev_round_image_list:[]};if(kind==='placeholder')p.message.extra.update_member=false;
      if(kind==='legacyContent')p.message.content='different';if(kind==='opaqueInfo')p.message.info={payload:'PRIVATE'};
      if(kind==='opaqueMeta')p.message.extra.meta={subChatType:'t2t',payload:'PRIVATE'};if(kind==='mcp')p.message.feature_config.local_mcp={tool:'PRIVATE'};
      if(kind==='extraKey')p.answer.unknown='PRIVATE';if(kind==='sparse')delete p.message.content_list[0];
      if(kind==='accessor')Object.defineProperty(p.answer,'status',{get(){throw new Error('must not invoke');},enumerable:true});
      if(kind==='outsideText')p.current.children=p.element({message:p.message,children:'PRIVATE'});
      if(kind==='twoMessages')p.current.children=p.element({message:{...p.message},children:p.element(p.input)});
      if(kind==='wrongParent')p.message.parentId='11111111-1111-4111-8111-111111111111';if(kind==='role')p.answer.role='function';if(kind==='notDone')p.message.done=false;
    });
    expect(t.first.error,kind).toBe('unsupported_response_format');expect(t.first.detail,kind).toBe('authored_source');
    const {rawSource,...originalFailure}=t.first.adapterFailureStructure;
    expect(originalFailure,kind).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'inline',reason:'other',count:0});
    expect(rawSource.version,kind).toBe(1);
    expect(t.first.qwenCodePayload,kind).toBeUndefined();expect(t.first.text,kind).toBeUndefined();
    expect(JSON.stringify(t.first),kind).not.toContain('PRIVATE');expect(t.world.delegated(),kind).toBe(0);
    expect(t.f.actions.every(action=>action.clicks===0),kind).toBe(true);expect(t.f.send.clicks,kind).toBe(1);
  }
});

test('raw grants retain the exact kind, one body/model proof and original document/response fence',async()=>{
  for(const bad of ['kind','version','extra','grant','candidate','response','fingerprint','initial','model','body','route','owner']){
    const t=await ownedRaw(raw),g:any={...t.grant},options:any={qwenCodePayloadSample:g};
    if(bad==='kind')g.sourceKind='other';if(bad==='version')g.version=1;if(bad==='extra')g.other=true;
    if(bad==='grant')g.grant='other';if(bad==='candidate')g.candidate='other';if(bad==='response')g.responseID='other';
    if(bad==='fingerprint')options.expectedFirstUserFingerprint='0'.repeat(64);if(bad==='initial')options.allowFirstUserBinding=true;
    if(['model','body','route','owner'].includes(bad))t.f.beforeDigest(()=>{
      if(bad==='model')t.f.modelName.text='Qwen3.8-Max';if(bad==='body')t.f.userBody.text='different';
      if(bad==='route')t.f.document.URL='https://chat.qwen.ai/';if(bad==='owner')t.f.world.__computaModelOwner='foreign';
    });
    const result=await t.sample(options);expect(result.error,bad).toBeTruthy();expect(result.text,bad).toBeUndefined();
    expect(t.f.actions.every(action=>action.clicks===0),bad).toBe(true);expect(t.world.delegated(),bad).toBe(0);
  }
});

test('current host replacement and in-place raw/metadata changes never accept a stale source',async()=>{
  for(const kind of ['hostProps','raw','metadata','array','input','edit']){
    const t=await ownedRaw(raw);t.f.beforeDigest(()=>{
      if(kind==='hostProps')(t.f.answer as any).__reactProps$fixture={...t.p.current};
      if(kind==='raw')t.p.answer.content=raw+' ';
      if(kind==='metadata')t.p.message.extra.update_member=true;
      if(kind==='array')t.p.message.content_list=[...t.p.message.content_list];
      if(kind==='input')t.p.input.content=body;
      if(kind==='edit')t.p.current.children=t.p.element({message:t.p.message,isEdit:true,children:t.p.element(t.p.input)});
    });
    const result=await t.sample();expect(result.error,kind).toBeTruthy();expect(result.text,kind).toBeUndefined();
    expect(t.f.actions.every(action=>action.clicks===0),kind).toBe(true);expect(t.world.delegated(),kind).toBe(0);
  }
});

test('missing page-world source channel leaves the old error and source reflection never executes components or reasoning content',async()=>{
  const t=await ownedRaw(raw);expect(t.first.qwenCodePayload.sourceKind).toBe('raw_answer_v1');
  const result=await t.f.run('inspect',{...t.options,qwenCodePayloadChannel:{...channel,secret:crypto.randomUUID()}});
  expect(result.error).toBe('unsupported_response_format');expect(result.text).toBeUndefined();
  expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
});

test('lost or malformed raw-read acknowledgement spends the existing one-shot grant and emits no partial source',async()=>{
  for(const bad of ['missing','grant','candidate','extra','text']){
    const t=await ownedRaw(raw,undefined,value=>{
      if(value.op!=='sample')return value;
      if(bad==='missing')return null;
      if(bad==='grant')return {...value,grant:crypto.randomUUID()};
      if(bad==='candidate')return {...value,candidate:crypto.randomUUID()};
      if(bad==='extra')return {...value,extra:'PRIVATE'};
      return {...value,text:null};
    });
    expect(t.first.qwenCodePayload.sourceKind,bad).toBe('raw_answer_v1');
    const result=await t.sample();expect(result.error,bad).toBeTruthy();expect(result.text,bad).toBeUndefined();
    expect((await t.sample()).error,bad).toBeTruthy();expect(t.world.delegated(),bad).toBe(0);
    expect(t.f.actions.every(action=>action.clicks===0),bad).toBe(true);
  }
});


test('stop, multiple, edit and empty-render flags require explicit clear typed states',async()=>{
  for(const key of ['is_stop','is_stop_in_thinking','isMultiResponse','isEdit','isRenderEmpty']){
    for(const value of [true,1,'false',{},[],0]){
      const t=await ownedRaw(raw,p=>{
        if(key==='isEdit'||key==='isRenderEmpty')p.input[key]=value;
        else p.message[key]=value;
      });
      expect(t.first.error,key).toBe('unsupported_response_format');expect(t.first.detail,key).toBe('authored_source');
      expect(t.first.qwenCodePayload,key).toBeUndefined();expect(t.first.text,key).toBeUndefined();
      expect(t.world.delegated(),key).toBe(0);expect(t.f.actions.every(action=>action.clicks===0),key).toBe(true);
    }
  }
});


test('native post-await verifyModel rechecks only an already held raw source without sampling or model bootstrap',async()=>{
  const t=await ownedRaw(raw);
  expect(t.first.qwenCodePayload.sourceKind).toBe('raw_answer_v1');
  const verified=await t.f.run('verifyModel',t.options);
  expect(verified.error).toBeUndefined();expect(verified.text).toBe('');expect(verified.answerComplete).toBe(false);
  expect(verified.qwenCodePayload).toEqual(t.first.qwenCodePayload);
  expect(verified.modelEvidence.selected).toEqual(choice());
  expect(t.f.world.__computaQwenSavedSessionV1.codePayload.spent).toBe(false);
  expect((await t.sample()).text).toBe(raw);expect(t.world.delegated()).toBe(0);
  expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
  const fresh=await ownedRaw(raw,undefined,undefined,'verifyModel');
  expect(fresh.first.error).toBe('conversation_changed');expect(fresh.first.detail).toBe('first_user_message');
  expect(fresh.first.qwenCodePayload).toBeUndefined();expect(fresh.f.world.__computaQwenSavedSessionV1.codePayload).toBeUndefined();
  expect(fresh.world.delegated()).toBe(0);expect(fresh.f.actions.every(action=>action.clicks===0)).toBe(true);
  const unheld=await ownedRaw(raw,undefined,undefined,'inspect',true);
  expect(unheld.first.error).toBeUndefined();expect(unheld.first.firstUserVerified).toBe(true);
  expect(unheld.first.qwenCodePayload).toBeUndefined();
  const modelOnly=await unheld.f.run('verifyModel',unheld.options);
  expect(modelOnly.error).toBe('unsupported_response_format');expect(modelOnly.detail).toBe('authored_source');
  expect(modelOnly.qwenCodePayload).toBeUndefined();expect(unheld.f.world.__computaQwenSavedSessionV1.codePayload).toBeUndefined();
  expect(unheld.world.delegated()).toBe(0);expect(unheld.f.actions.every(action=>action.clicks===0)).toBe(true);
  for(const kind of ['model','host']){
    const changed=await ownedRaw(raw);
    if(kind==='host')(changed.f.answer as any).__reactProps$fixture={...changed.p.current};
    else changed.f.modelName.text='Qwen3.8-Max';
    const refused=await changed.f.run('verifyModel',changed.options);
    expect(refused.error,kind).toBeTruthy();expect(refused.text,kind).toBeUndefined();
    expect(changed.f.world.__computaQwenSavedSessionV1.codePayload.spent,kind).toBe(false);
    expect(changed.world.delegated(),kind).toBe(0);expect(changed.f.actions.every(action=>action.clicks===0),kind).toBe(true);
  }
});
