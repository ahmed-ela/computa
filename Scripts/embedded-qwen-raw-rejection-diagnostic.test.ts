import {expect,test} from 'bun:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {ownedRaw,channel} from './embedded-qwen-authored-source-fixture';
import {conversationID,userID,answerID} from './embedded-qwen-adapter-fixture';
const previousBytes=readFileSync(new URL('./fixtures/qwen-authored-source-before452.js',import.meta.url),'utf8');
// Compare observer-only semantics at the same supported public-tree depth.
const previous=previousBytes.replace('require(depth <= 8);','require(depth <= 10);');
const current=readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/qwen-authored-source.js',import.meta.url),'utf8');
const raw='```json\n'+JSON.stringify({type:'message',text:'Synthetic [[12]] λ😀\n\t"raw"'})+'\n```';
const observed=(source:string)=>source.replace('const descriptor = Object.getOwnPropertyDescriptor,',
 "const descriptor = (object,key)=>{(window.__rawReadKeys??=[]).push(key);return Object.getOwnPropertyDescriptor(object,key);},");
const base={version:1,provider:'qwen',trigger:'authored_source',stage:'inline',reason:'other',count:0};

test('raw ineligibility diagnostics preserve original rejection, source descriptor read order and zero actions',async()=>{
  expect(createHash('sha256').update(previousBytes).digest('hex')).toBe('191d72db9192e1b592211197635c60ab9155b7779c97a82516e6be77363dbc6e');
  for(const [kind,stage,count,seen] of [
    ['extra','message_extra',null,null],['timestamp','phase_scalar',2,1],['unknown','phase_kind',2,0],
    ['duplicate','answer_count',3,2],['limit','phase_list',33,null],['accessor','phase_status_read',2,1],
    ['exception','phase_status_read',2,1],['renderer','renderer_input',2,1],['feature','feature_values',null,null]
  ] as const){
    const mutate=(p:any)=>{
      if(kind==='extra')p.message.extra.PRIVATE_SECRET='SECRET_DIAGNOSTIC_MUST_NOT_LEAK';
      if(kind==='timestamp')p.answer.timestamp=.5;
      if(kind==='unknown')p.hidden.phase='SECRET_UNKNOWN_PHASE';
      if(kind==='duplicate')p.message.content_list.push({...p.answer,content:''});
      if(kind==='limit')p.message.content_list=Array(33).fill(p.hidden);
      if(kind==='accessor')Object.defineProperty(p.answer,'status',{get(){throw Error('SECRET_GETTER');},enumerable:true});
      if(kind==='exception')p.message.content_list[1]=new Proxy(p.answer,{getOwnPropertyDescriptor(target,key){
        if(key==='status')throw Error('SECRET_EXCEPTION');return Reflect.getOwnPropertyDescriptor(target,key);}});
      if(kind==='renderer')p.input.content='SECRET_DIFFERENT_RAW';
      if(kind==='feature')p.message.feature_config.output_schema='SECRET_OTHER_SCHEMA';
    };
    const old=await ownedRaw(raw,mutate,undefined,'inspect',false,observed(previous));
    const now=await ownedRaw(raw,mutate,undefined,'inspect',false,observed(current));
    const {rawSource,...original}=now.first.adapterFailureStructure;
    expect(original,kind).toEqual(old.first.adapterFailureStructure);expect(original,kind).toEqual(base);
    expect(now.first.error,kind).toBe(old.first.error);expect(now.first.detail,kind).toBe(old.first.detail);
    expect(now.f.window.__rawReadKeys,kind).toEqual(old.f.window.__rawReadKeys);
    expect(rawSource,kind).toEqual({version:1,stage,kind:kind==='exception'?'exception':'guard',phaseCount:count,phaseOverflow:count===null?null:count===33,answersSeen:seen});
    expect(JSON.stringify(now.first),kind).not.toContain('SECRET');expect(now.first.text,kind).toBeUndefined();
    expect(now.first.qwenCodePayload,kind).toBeUndefined();expect(now.f.world.__computaQwenSavedSessionV1.codePayload,kind).toBeUndefined();
    expect(now.world.delegated(),kind).toBe(0);expect(now.f.actions.every(action=>action.clicks===0),kind).toBe(true);
  }
  // A request accessor observes the exact old external read count for both
  // operations, whether source validation succeeds or throws. Tracing must
  // consume only the already evaluated operation/keyset decision.
  for(const op of ['candidate','sample'])for(const fail of [false,true]){
    const observations:any[]=[];
    for(const source of [previous,current]){
      const results:any[]=[];
      const t=await ownedRaw(raw,undefined,value=>{results.push({...value});return value;},'inspect',false,source);
      if(fail)t.p.message.extra.forbidden='SECRET';
      let reads=0;
      const request:any={kind:'raw_answer_v1',op,secret:channel.secret,chatID:conversationID,parentID:userID,responseID:answerID};
      if(op==='sample'){request.candidate=results.find(row=>row.op==='candidate'&&row.eligible).candidate;request.grant=t.grant.grant;}
      Object.defineProperty(request,'op',{get(){reads++;return op;},enumerable:true});
      t.f.answer.dispatchEvent(new t.world.Event(channel.dispatch,{bubbles:true,detail:request}));
      const result=results[results.length-1];
      expect(reads).toBe(5);expect(result.eligible,JSON.stringify({op,fail,reader:source===previous?"previous":"current",result})).toBe(!fail);
      if(op==='sample')expect(result.text).toBe(fail?null:raw);
      expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
      observations.push({reads,op:result.op,eligible:result.eligible});
    }
    expect(observations[1]).toEqual(observations[0]);
  }
});

test('eligible candidate and one-shot sample retain exact old event shapes and exact source bytes without diagnostic output',async()=>{
  for(const source of [previous,current]){
    const shapes:any[]=[];const t=await ownedRaw(raw,undefined,value=>{shapes.push({op:value.op,keys:Object.keys(value).sort()});return value;},'inspect',false,source);
    expect(t.first.error).toBeUndefined();const result=await t.sample();expect(result.text).toBe(raw);
    expect(result.adapterFailureStructure).toBeUndefined();expect(result.rawSource).toBeUndefined();
    for(const row of shapes)expect(row.keys).toEqual(row.op==='candidate'
      ? ['candidate','eligible','kind','op','responseID'] : ['candidate','eligible','grant','kind','op','responseID','text']);
    expect((await t.sample()).error).toBeTruthy();expect(t.world.delegated()).toBe(0);expect(t.f.actions.every(action=>action.clicks===0)).toBe(true);
  }
});

test('malformed or untrusted failed-result diagnostics cannot change the original refusal or become a truthy source',async()=>{
  for(const kind of ['stage','kind','extra','boolean','overflow','seen','unknownCount','getter','target']){
    let getterCalls=0;
    const t=await ownedRaw(raw,p=>{p.message.extra.forbidden='SECRET';},value=>{
      if(value.op!=='candidate'||value.eligible!==false)return value;
      const diagnostic={...value.diagnostic};
      if(kind==='stage')diagnostic.stage='SECRET_UNKNOWN';if(kind==='kind')diagnostic.kind='SECRET_UNKNOWN';
      if(kind==='extra')diagnostic.content='SECRET';if(kind==='boolean')diagnostic.phaseCount=true;
      if(kind==='overflow'){diagnostic.phaseCount=2;diagnostic.phaseOverflow=true;}
      if(kind==='seen'){diagnostic.phaseCount=1;diagnostic.phaseOverflow=false;diagnostic.answersSeen=2;}
      if(kind==='unknownCount')diagnostic.answersSeen=1;
      if(kind==='target')return {...value,responseID:crypto.randomUUID(),diagnostic};
      if(kind==='getter'){const invalid={...value};Object.defineProperty(invalid,'diagnostic',{get(){getterCalls++;throw Error('SECRET');},enumerable:true});return invalid;}
      return {...value,diagnostic};
    });
    expect(getterCalls,kind).toBe(0);
    expect(t.first.error,kind).toBe('unsupported_response_format');expect(t.first.detail,kind).toBe('authored_source');
    expect(t.first.adapterFailureStructure,kind).toEqual(base);expect(t.first.qwenCodePayload,kind).toBeUndefined();
    expect(t.first.text,kind).toBeUndefined();expect(JSON.stringify(t.first),kind).not.toContain('SECRET');
    expect(t.world.delegated(),kind).toBe(0);expect(t.f.actions.every(action=>action.clicks===0),kind).toBe(true);
  }
});
