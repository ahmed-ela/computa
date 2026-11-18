(() => {
  const config = __COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__;
  if (window !== window.top || location.origin !== 'https://chat.qwen.ai') return;
  const descriptor = Object.getOwnPropertyDescriptor, names = Object.getOwnPropertyNames;
  const symbols = Object.getOwnPropertySymbols, prototype = Object.getPrototypeOf, array = Array.isArray;
  const hasOwn = Object.hasOwn, create = Object.create, objectPrototype = Object.prototype;
  const apply = Reflect.apply, query = Document.prototype.querySelectorAll, contains = Node.prototype.contains;
  const dispatch = EventTarget.prototype.dispatchEvent, Custom = CustomEvent;
  const random = crypto.randomUUID.bind(crypto), stringify = JSON.stringify;
  const encode = new TextEncoder(), decode = new TextDecoder('utf-8', {fatal:true});
  const elementKinds = new Set([Symbol.for('react.element'), Symbol.for('react.transitional.element')]);
  const kind = 'raw_answer_v1';
  const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
  if (!config || names(config).sort().join(',') !== 'dispatch,result,secret'
    || ![config.dispatch,config.result,config.secret].every(uuid)) return;
  let held = null, spent = false;
  const require = ok => { if (!ok) throw null; };

  function read(target, request) {
    const reads = [], shapes = [];
    const own = (object, key, optional = false) => {
      require(object !== null && typeof object === 'object');
      const d = descriptor(object, key);
      if (!d) { require(optional); reads.push([object,key,undefined]); return undefined; }
      require(hasOwn(d, 'value')); reads.push([object,key,d.value]); return d.value;
    };
    const keys = (object, maximum = 64) => {
      require(object !== null && typeof object === 'object' && symbols(object).length === 0);
      const result = names(object); require(result.length <= maximum);
      shapes.push([object,result.join('\0')]); return result;
    };
    const plain = object => {
      require(object !== null && typeof object === 'object' && !array(object)
        && [objectPrototype,null].includes(prototype(object)));
      return keys(object);
    };
    const closed = (object, allowed) => { const ks = plain(object); require(ks.every(key => allowed.includes(key))); return ks; };
    const list = (object, maximum) => {
      require(array(object)); const length = own(object,'length');
      require(Number.isInteger(length) && length >= 0 && length <= maximum);
      require(keys(object,maximum+1).length === length+1);
      for (let index=0;index<length;index++) require(descriptor(object,String(index)) !== undefined);
      return length;
    };
    const empty = value => value === undefined || value === null || value === ''
      || (array(value) ? list(value,0) === 0 : typeof value === 'object' && plain(value).length === 0);
    const objectExtra = value => value === undefined || value === null || plain(value).length === 0;

    require(target instanceof HTMLDivElement && target.isConnected && target.ownerDocument === document
      && target.id === 'chat-response-message-'+request.responseID
      && location.href === 'https://chat.qwen.ai/c/'+request.chatID);
    const roots = apply(query, document, ['[id="root"]']);
    require(roots.length === 1 && roots[0].tagName === 'DIV' && roots[0].parentElement === document.body
      && apply(contains, roots[0], [target]));
    const hosts = apply(query, document, ['.chat-response-message']);
    const users = apply(query, document, ['.chat-user-message-container']);
    require(hosts.length === 1 && hosts[0] === target && users.length === 1
      && users[0].getAttribute('data-msg-id') === request.parentID
      && users[0].getAttribute('data-chat-id') === request.chatID);

    // ReactDOM's commit path updates this host-owned props pointer. Walk only
    // this response's ReactElement DATA children; never fibers, owners or hooks.
    const propKeys = keys(target,32).filter(key => key.startsWith('__reactProps$'));
    require(propKeys.length === 1);
    const hostProps = own(target,propKeys[0]); plain(hostProps);
    require(own(hostProps,'id') === target.id);
    const messages = new Set(), inputs = [], stack = [[own(hostProps,'children'),0]];
    let visits = 128;
    while (stack.length) {
      require(--visits >= 0);
      const [node,depth] = stack.pop(); require(depth <= 8);
      if (node === null || node === undefined || typeof node === 'boolean' || node === '') continue;
      require(typeof node === 'object');
      if (array(node)) {
        const count = list(node,64);
        for (let index=count-1;index>=0;index--) stack.push([own(node,String(index)),depth+1]);
        continue;
      }
      plain(node); require(elementKinds.has(own(node,'$$typeof')));
      const props = own(node,'props'); plain(props);
      const message = own(props,'message',true);
      if (message !== undefined) { require(message !== null && typeof message === 'object'); messages.add(message); }
      require([undefined,null,false].includes(own(props,'isEdit',true)) && [undefined,null,false].includes(own(props,'isRenderEmpty',true)));
      const index = own(props,'phaseContentIndex',true);
      if (index !== undefined) inputs.push({props,message,index});
      stack.push([own(props,'children',true),depth+1]);
    }
    require(messages.size === 1);
    const message = messages.values().next().value;
    closed(message,['id','parentId','fid','childrenIds','role','content','model','models','modelName','modelIdx',
      'userContext','chat_type','user_action','info','merged','feature_config','extra','timestamp','sub_chat_type',
      'content_list','done','error','is_stop','is_stop_in_thinking','isMultiResponse','files']);
    require(own(message,'id') === request.responseID && own(message,'parentId') === request.parentID
      && own(message,'role') === 'assistant' && own(message,'done') === true
      && own(message,'chat_type') === 't2t' && [undefined,'t2t'].includes(own(message,'sub_chat_type',true))
      && [undefined,null,''].includes(own(message,'content',true))
      && empty(own(message,'merged',true))
      && [undefined,null,'chat'].includes(own(message,'user_action',true))
      && [undefined,null,false].includes(own(message,'error',true))
      && [undefined,null,false].includes(own(message,'is_stop',true)) && [undefined,null,false].includes(own(message,'is_stop_in_thinking',true))
      && [undefined,null,false].includes(own(message,'isMultiResponse',true)) && list(own(message,'childrenIds'),0) === 0
      && empty(own(message,'files',true)));
    require(empty(own(message,'userContext',true)) && empty(own(message,'models',true)));
    const fid = own(message,'fid',true);
    require(fid === undefined || fid === null || uuid(fid));
    for (const key of ['model','modelName']) {
      const value = own(message,key,true);
      require(value === undefined || typeof value === 'string' && /^[A-Za-z0-9_.:/ -]{1,128}$/.test(value));
    }
    const modelIndex = own(message,'modelIdx',true), timestamp = own(message,'timestamp',true);
    require((modelIndex === undefined || Number.isInteger(modelIndex) && modelIndex >= 0 && modelIndex <= 32)
      && (timestamp === undefined || Number.isSafeInteger(timestamp) && timestamp >= 0 && timestamp <= 10000000000000));
    const extra = own(message,'extra',true);
    if (extra !== undefined && extra !== null) {
      closed(extra,['meta']); const meta = own(extra,'meta',true);
      if (meta !== undefined && meta !== null) {
        const ks = closed(meta,['subChatType']);
        require(ks.length === 0 || own(meta,'subChatType') === 't2t');
      }
    }
    const feature = own(message,'feature_config');
    closed(feature,['thinking_enabled','local_mcp','output_schema','research_mode','auto_thinking','thinking_mode','mcp']);
    const mode = own(feature,'thinking_mode',true), automatic = own(feature,'auto_thinking',true);
    require(typeof own(feature,'thinking_enabled') === 'boolean' && own(feature,'output_schema') === 'phase'
      && [undefined,'normal'].includes(own(feature,'research_mode',true))
      && [undefined,null,'Auto','Thinking','Fast'].includes(mode)
      && (automatic === undefined || typeof automatic === 'boolean' && automatic === (mode === 'Auto'))
      && empty(own(feature,'local_mcp',true)) && empty(own(feature,'mcp',true)));

    // The known stream usage constructor copies numeric usage into info and
    // adds openai/usage. Opaque nonempty info is not silently ignored.
    const info = own(message,'info',true);
    if (info !== undefined && info !== null && plain(info).length) {
      const usage = own(info,'usage'), usageKeys = plain(usage);
      const infoKeys = plain(info); require(own(info,'openai') === true && infoKeys.length === usageKeys.length+2
        && usageKeys.every(key => !['openai','usage','__proto__','constructor','prototype'].includes(key)));
      let budget = 256;
      const numeric = (value,depth) => {
        require(--budget >= 0 && depth <= 3);
        if (typeof value === 'number') { require(Number.isFinite(value) && value >= 0); return value; }
        const ks = plain(value); const output = create(null);
        for (const key of ks.sort()) {
          require(/^[a-z][a-z0-9_]{0,47}$/.test(key) && !['__proto__','constructor','prototype'].includes(key));
          output[key] = numeric(own(value,key),depth+1);
        }
        return output;
      };
      for (const key of usageKeys) require(stringify(numeric(own(info,key),0)) === stringify(numeric(own(usage,key),0)));
    }
    const parts = own(message,'content_list'), count = list(parts,32);
    require(count > 0);
    let answer = null, answerIndex = -1;
    for (let index=0;index<count;index++) {
      const part = own(parts,String(index));
      closed(part,['content','role','phase','timestamp','status','function_id','extra','groupIndex',
        'lang_code','video','text','tool_name','mcp_name','function_call','mcp_results','name']);
      const phase = own(part,'phase');
      require(['answer','think','thinking_summary'].includes(phase));
      require([undefined,'assistant'].includes(own(part,'role',true))
        && [undefined,'typing','finished'].includes(own(part,'status',true))
        && objectExtra(own(part,'extra',true)));
      const timestamp = own(part,'timestamp',true), group = own(part,'groupIndex',true);
      require((timestamp === undefined || Number.isSafeInteger(timestamp) && timestamp >= 0 && timestamp <= 10000000000000)
        && (group === undefined || Number.isInteger(group) && group >= 0 && group <= 32));
      for (const key of ['lang_code','function_id','video','text','tool_name','mcp_name','function_call','mcp_results','name'])
        require(empty(own(part,key,true)));
      if (phase === 'answer') { require(answer === null); answer = part; answerIndex = index; }
      // No non-ANSWER content property/descriptor is read.
    }
    require(answer !== null && own(answer,'role') === 'assistant');
    const text = own(answer,'content');
    require(typeof text === 'string' && text.length > 0 && text.length <= 220000);
    const payloadInputs = inputs.filter(input => input.index === answerIndex && input.message === message);
    require(payloadInputs.length === 1 && own(payloadInputs[0].props,'content') === text);
    const bytes = encode.encode(text); require(bytes.length <= 220000 && decode.decode(bytes) === text);
    return {target,hostProps,message,parts,answer,text,reads,shapes};
  }
  const same = (a,b) => !!a && !!b && a.target === b.target && a.hostProps === b.hostProps && a.message === b.message
    && a.parts === b.parts && a.answer === b.answer && a.text === b.text
    && a.reads.length === b.reads.length && a.reads.every((row,index) => row.every((value,i) => value === b.reads[index][i]))
    && a.shapes.length === b.shapes.length && a.shapes.every((row,index) => row[0] === b.shapes[index][0] && row[1] === b.shapes[index][1]);
  document.addEventListener(config.dispatch,event => {
    const request = event.detail, target = event.target;
    if (!request || request.kind !== kind || request.secret !== config.secret || !['candidate','sample'].includes(request.op)) return;
    let result = {kind,op:request.op,eligible:false,candidate:null,responseID:request.responseID};
    try {
      const allowed = request.op === 'candidate' ? ['kind','op','secret','chatID','parentID','responseID']
        : ['kind','op','secret','chatID','parentID','responseID','candidate','grant'];
      require(names(request).sort().join(',') === allowed.sort().join(',')
        && [request.chatID,request.parentID,request.responseID].every(uuid));
      if (request.op === 'sample') {
        require(!spent && held && uuid(request.grant) && request.candidate === held.candidate);
        spent = true;
      }
      const current = read(target,request);
      if (!held) held = {candidate:random(),source:current};
      require(same(held.source,current));
      if (request.op === 'candidate') result = {kind,op:'candidate',eligible:true,candidate:held.candidate,responseID:request.responseID};
      else {
        require(same(held.source,read(target,request)));
        result = {kind,op:'sample',eligible:true,candidate:held.candidate,responseID:request.responseID,grant:request.grant,text:current.text};
      }
    } catch {
      if (request.op === 'sample') { spent = true; result.grant = request.grant; result.text = null; }
    }
    apply(dispatch,target,[new Custom(config.result,{bubbles:true,detail:result})]);
    if (hasOwn(result,'text')) result.text = null;
  },true);
})();
