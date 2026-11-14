/* Opt-in passive metadata diagnostic. No provider requests are issued.
 * This is not response admission, authentication, ownership or tool authority.
 * Install in .page before one explicitly approved synthetic prompt submission.
 */
(() => {
  'use strict';
  function install(options) {
    const w = globalThis, d = w.document;
    const apply = Reflect.apply, desc = Object.getOwnPropertyDescriptor, define = Object.defineProperty;
    const keys = Object.keys, proto = Object.getPrototypeOf, freeze = Object.freeze;
    const parse = JSON.parse, stringify = JSON.stringify, own = Object.prototype.hasOwnProperty;
    const array = Array.isArray, plain = Object.prototype;
    const promiseThen = Promise.prototype.then, URLClass = URL, Decoder = TextDecoder;
    const encode = TextEncoder.prototype.encode, encoder = new TextEncoder();
    const timeout = w.setTimeout.bind(w), clear = w.clearTimeout.bind(w);
    const add = w.EventTarget?.prototype.addEventListener, remove = w.EventTarget?.prototype.removeEventListener;
    const responseClone = w.Response?.prototype.clone;
    const responseStatus = desc(w.Response?.prototype || {}, 'status')?.get;
    const responseHeaders = desc(w.Response?.prototype || {}, 'headers')?.get;
    const responseBody = desc(w.Response?.prototype || {}, 'body')?.get;
    const headersGet = w.Headers?.prototype.get;
    const streamGetReader = w.ReadableStream?.prototype.getReader;
    const readerRead = w.ReadableStreamDefaultReader?.prototype.read;
    const readerCancel = w.ReadableStreamDefaultReader?.prototype.cancel;
    const readerRelease = w.ReadableStreamDefaultReader?.prototype.releaseLock;
    const initial = desc(w, 'fetch');
    const unavailable = reason => freeze({ status: 'unavailable', reason });
    if (!d || w !== w.top || d.defaultView !== w || w.location?.origin !== 'https://claude.ai')
      return unavailable('context');
    if (!initial || typeof initial.value !== 'function' || !initial.configurable
      || [add, remove, responseClone, responseStatus, responseHeaders, responseBody,
          headersGet, streamGetReader, readerRead, readerCancel, readerRelease].some(v => typeof v !== 'function'))
      return unavailable('apis');
    if (!options || ![plain, null].includes(proto(options))) return unavailable('configuration');
    const allowedOptions = ['expectedPrompt', 'expectedMarker', 'ttlMs', 'maxBytes', 'maxEvents','allowFreshConversationTransition'];
    const optionValues = {};
    for (const key of keys(options)) {
      const p = desc(options, key);
      if (!allowedOptions.includes(key) || !p || !apply(own, p, ['value'])) return unavailable('configuration');
      optionValues[key] = p.value;
    }
    let expectedPrompt = null, marker = null, armed = false, armUsed = false;
    const ttl = optionValues.ttlMs ?? 60000, byteLimit = optionValues.maxBytes ?? 65536, eventLimit = optionValues.maxEvents ?? 128;
    const allowTransition = optionValues.allowFreshConversationTransition ?? false;
    if (!Number.isInteger(ttl) || ttl < 1 || ttl > 60000
      || !Number.isInteger(byteLimit) || byteLimit < 1 || byteLimit > 65536
      || !Number.isInteger(eventLimit) || eventLimit < 1 || eventLimit > 128 || typeof allowTransition !== 'boolean')
      return unavailable('configuration');
    const original = initial.value, documentURL = d.URL;
    if (allowTransition && !['https://claude.ai/new','https://claude.ai/new?incognito'].includes(documentURL))
      return unavailable('fresh_route');
    const expectedOrigin = 'https://claude.ai';
    const routeWords = new Set(['api','organizations','chat_conversations','completion','completions','messages','message','conversation','conversations','stream','chat','v1','v2']);
    const eventNames = new Set(['message_start','message_delta','message_stop','content_block_start','content_block_delta','content_block_stop','ping','error','completion','message','done','metadata','chunk','token','conversation_delta','stream_start','stream_end','text_delta','message_limit','json']);
    const typeNames = new Set(['message_start','message_delta','message_stop','content_block_start','content_block_delta','content_block_stop','text_delta','text','completion','thinking','thinking_delta','signature_delta','redacted_thinking','tool_use','input_json_delta','error','ping']);
    const safeKeys = new Set(['type','index','content','content_block','delta','text','completion','message','usage','input_tokens','output_tokens','stop_reason','stop_sequence','role','id','uuid','model','error','events','data','chat_messages','conversation_uuid']);
    const sensitiveKeys = new Set(['thinking','reasoning','analysis','signature','encrypted_content','redacted_thinking']);
    let active = true, matchedCalls = 0, reader = null, timer = null, phase = 'dormant', terminalReason = null;
    let bytesRead = 0, eventCount = 0, shapeBudgetBytes = 0, markerPresent = false;
    let status = null, mime = null, route = null, restore = 'not_attempted', readPending = false, readCalls = 0;
    let lockReleased = false, unterminatedEventDiscarded = false;
    let transitionedURL = null, transitionCount = 0, transitionReason = 'none';
    const textTails = new Map(), streamIdentities = new Map();
    const events = [];
    function current() {
      if (!active || d !== w.document || w !== w.top || w.location.origin !== expectedOrigin) return false;
      if (transitionedURL !== null) {
        if (d.URL === transitionedURL) return true;
        transitionReason = 'unexpected_route';return false;
      }
      if (d.URL === documentURL) return true;
      if (allowTransition && /^https:\/\/claude\.ai\/chat\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(d.URL)) {
        transitionedURL = d.URL;transitionCount = 1;transitionReason = 'allowed_fresh_to_conversation';return true;
      }
      transitionReason = 'unexpected_route';return false;
    }
    function silence(p) { try { apply(promiseThen, p, [undefined, () => undefined]); } catch {} }
    function cancelReader() {
      const existing = reader; reader = null;
      if (existing) {
        try { silence(apply(readerCancel, existing, [])); } catch {}
        try { apply(readerRelease,existing,[]);lockReleased = true; } catch {}
      }
    }
    function finish(reason) {
      if (!active) return;
      active = false; phase = 'terminal'; terminalReason = reason;textTails.clear();streamIdentities.clear();expectedPrompt = null;marker = null;
      if (timer !== null) { clear(timer); timer = null; }
      cancelReader();
      for (const name of ['pagehide','popstate','hashchange']) try { apply(remove, w, [name, pageHidden, true]); } catch {}
      try {
        if (desc(w, 'fetch')?.value === wrappedFetch) { define(w, 'fetch', initial); restore = 'restored'; }
        else restore = 'superseded';
      } catch { restore = 'restore_failed'; }
    }
    function pageHidden() { finish('navigation'); }
    function arm(configuration) {
      if (!current() || armUsed || armed || matchedCalls !== 0) return false;
      armUsed = true;
      try {
        if (!configuration || ![plain,null].includes(proto(configuration))
          || keys(configuration).length !== 2) return false;
        const p = desc(configuration,'expectedPrompt'), m = desc(configuration,'expectedMarker');
        if (!p || !m || !apply(own,p,['value']) || !apply(own,m,['value'])
          || typeof p.value !== 'string' || !p.value.length || p.value.length > 131072
          || typeof m.value !== 'string' || !/^[A-Za-z0-9_-]{12,128}$/.test(m.value)
          || p.value.split(m.value).length !== 2) return false;
        expectedPrompt = p.value;marker = m.value;armed = true;phase = 'waiting';return true;
      } catch { return false; }
    }
    function leafMatches(value) {
      let visited = 0, matches = 0;
      const stack = [{ value, depth: 0 }];
      while (stack.length) {
        const node = stack.pop();
        if (++visited > 2048 || node.depth > 20) return false;
        if (typeof node.value === 'string') { if (node.value === expectedPrompt) matches++; }
        else if (node.value && typeof node.value === 'object') {
          const children = keys(node.value);
          if (children.length + visited + stack.length > 2048) return false;
          for (const key of children) stack.push({ value: node.value[key], depth: node.depth + 1 });
        }
        if (matches > 1) return false;
      }
      return matches === 1;
    }
    function match(args) {
      if (!current() || !armed || matchedCalls !== 0 || args.length !== 2 || typeof args[0] !== 'string'
        || args[0].length > 8192) return null;
      const init = args[1];
      if (!init || ![plain, null].includes(proto(init))) return null;
      // Inspect descriptors only; do not execute init accessors or inspect any
      // headers/credentials values. A getter anywhere makes this shape unknown.
      for (const key of Reflect.ownKeys(init)) { if (!apply(own, desc(init, key), ['value'])) return null; }
      const method = desc(init, 'method')?.value, body = desc(init, 'body')?.value;
      if (typeof method !== 'string' || method.toUpperCase() !== 'POST' || typeof body !== 'string'
        || body.length > 131072) return null;
      let url, object;
      try { url = new URLClass(args[0], documentURL); object = parse(body); } catch { return null; }
      if (url.origin !== expectedOrigin || url.protocol !== 'https:' || url.username || url.password || !leafMatches(object)) return null;
      return url.pathname.split('/').map(segment => {
        if (!segment) return '';
        if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(segment)) return ':uuid';
        if (/^[0-9]{1,16}$/.test(segment)) return ':number';
        return routeWords.has(segment) ? segment : ':segment';
      }).slice(0, 17).join('/');
    }
    function kind(value) { return value === null ? 'null' : array(value) ? 'array' : typeof value; }
    function sensitiveNode(value) {
      return value && typeof value === 'object' && ['thinking','thinking_delta','signature_delta','redacted_thinking'].includes(value.type);
    }
    function eventRecord(name, data) {
      if (!current()) { finish('context_changed'); return; }
      if (eventCount >= eventLimit) { finish('event_limit'); return; }
      eventCount++;
      const record = { name: eventNames.has(name) ? name : 'other', json: false, type: null,
        shape: [], otherKeys: 0, sensitiveBranchesOmitted: 0, textFields: [] };
      let value;
      try { value = parse(data); } catch { events.push(record); return; }
      record.json = true;
      if (value && typeof value === 'object' && typeNames.has(value.type)) record.type = value.type;
      if (['message_start','message_stop'].includes(name) || ['message_start','message_stop'].includes(value?.type)) textTails.clear();
      for (const [key, identity] of [['message_id',value?.message_id],['conversation_uuid',value?.conversation_uuid],
        ['conversation_id',value?.conversation_id],['message.id',value?.message?.id]]) {
        if (identity === undefined) continue;
        if (typeof identity !== 'string' || identity.length > 256) { textTails.clear();continue; }
        if (streamIdentities.has(key) && streamIdentities.get(key) !== identity) textTails.clear();
        streamIdentities.set(key,identity);
      }
      const index = Number.isInteger(value?.index) && value.index >= 0 && value.index <= 4095 ? value.index : null;
      if (index !== null && ['content_block_start','content_block_stop'].includes(value?.type)) textTails.delete('block:'+index);
      const stack = [{ value, path: '', depth: 0 }];
      let seen = 0;
      while (stack.length && seen < 32) {
        const node = stack.pop();seen++;
        if (sensitiveNode(node.value)) { record.sensitiveBranchesOmitted++; continue; }
        if (!node.value || typeof node.value !== 'object' || node.depth >= 4) continue;
        if (array(node.value)) {
          record.shape.push({ path: node.path || '$', kind: 'array' });
          for (let i = Math.min(node.value.length, 2) - 1; i >= 0; i--)
            stack.push({ value: node.value[i], path: node.path + '[]', depth: node.depth + 1 });
          continue;
        }
        for (const key of keys(node.value).slice(0, 32)) {
          if (sensitiveKeys.has(key)) { record.sensitiveBranchesOmitted++; continue; }
          if (!safeKeys.has(key)) { record.otherKeys++; continue; }
          const field = node.value[key], path = node.path ? node.path + '.' + key : key;
          if (record.shape.length < 32) record.shape.push({ path, kind: kind(field) });
          // Only a known text/text_delta node, or top-level completion event,
          // supplies marker evidence. Ambiguous text fields stay shapes only.
          const clearText = key === 'text' && ['text','text_delta'].includes(node.value.type)
            || key === 'completion' && node.depth === 0 && (name === 'completion' || node.value.type === 'completion');
          if (clearText && typeof field === 'string') {
            const group = node.path === 'delta' && value?.type === 'content_block_delta' && index !== null
              ? 'block:'+index : key === 'completion' && node.depth === 0 && name === 'completion' ? 'completion' : null;
            const present = field.includes(marker), combined = (group ? textTails.get(group) || '' : '') + field;
            const joined = group !== null && combined.includes(marker);
            markerPresent ||= present || joined;
            if (group !== null && (textTails.has(group) || textTails.size < 8)) textTails.set(group,combined.slice(-(marker.length-1)));
            record.textFields.push({ path, utf16Length: field.length, expectedMarkerPresent: present });
          } else if (field && typeof field === 'object') stack.push({ value: field, path, depth: node.depth + 1 });
        }
      }
      const size = apply(encode, encoder, [stringify(record)]).byteLength;
      if (shapeBudgetBytes + size > 49152) { finish('metadata_limit'); return; }
      shapeBudgetBytes += size; events.push(record);
    }
    async function observe(response) {
      if (!current()) { finish('context_changed'); return; }
      let clone;
      try {
        status = apply(responseStatus, response, []);
        if (!Number.isInteger(status) || status < 0 || status > 599) { finish('response_shape'); return; }
        const headers = apply(responseHeaders, response, []);
        const rawMime = apply(headersGet, headers, ['content-type']);
        const knownMime = typeof rawMime === 'string' ? rawMime.split(';',1)[0].trim().toLowerCase() : '';
        mime = ['text/event-stream','application/json'].includes(knownMime) ? knownMime : 'other';
        if (mime === 'other') { finish('unsupported_mime'); return; }
        clone = apply(responseClone, response, []);
        const body = apply(responseBody, clone, []);
        if (!body) { finish('empty_body'); return; }
        reader = apply(streamGetReader, body, []);
      } catch { finish('response_unavailable'); return; }
      phase = 'observing';
      const decoder = new Decoder('utf-8', { fatal: true });
      let buffer = '', eventName = '', lines = [], jsonBody = '';
      const dispatch = () => {
        if (lines.length) eventRecord(eventName || 'message', lines.join('\n'));
        eventName = '';lines = [];
      };
      const line = text => {
        if (!text) { dispatch();return; }
        if (text.startsWith(':')) return;
        const colon = text.indexOf(':');
        const key = colon < 0 ? text : text.slice(0,colon);
        let value = colon < 0 ? '' : text.slice(colon+1);
        if (value.startsWith(' ')) value = value.slice(1);
        if (key === 'event') eventName = value;
        else if (key === 'data') lines.push(value);
        // id/retry/comment data is ignored without publication.
      };
      const drain = final => {
        while (active) {
          const index = buffer.search(/[\r\n]/);
          if (index < 0) break;
          const cr = buffer[index] === '\r';
          if (cr && index === buffer.length-1 && !final) break;
          const length = cr && buffer[index+1] === '\n' ? 2 : 1;
          line(buffer.slice(0,index));buffer = buffer.slice(index+length);
        }
        // SSE dispatch requires an actual blank-line terminator. EOF is not a
        // provider completion signal and cannot promote an unterminated event.
        if (final && active) { unterminatedEventDiscarded = !!buffer || lines.length > 0;buffer='';lines=[];eventName=''; }
      };
      try {
        while (current() && reader) {
          if (++readCalls > 512) { finish('read_limit');return; }
          readPending = true;
          const item = await apply(readerRead, reader, []);
          readPending = false;
          if (!current()) { finish('context_changed'); return; }
          if (item.done) {
            const tail = decoder.decode();
            if (mime === 'application/json') { jsonBody += tail;if (jsonBody) eventRecord('json',jsonBody); }
            else { buffer += tail;drain(true); }
            finish('end_of_stream');return;
          }
          if (!(item.value instanceof Uint8Array)) { finish('chunk_shape');return; }
          const available = byteLimit - bytesRead;
          const consumed = Math.min(item.value.byteLength,available);
          bytesRead += consumed;
          const text = decoder.decode(item.value.subarray(0,consumed),{stream:true});
          if (mime === 'application/json') jsonBody += text;
          else { buffer += text;drain(false); }
          if (bytesRead >= byteLimit) { finish('byte_limit');return; }
          if (eventCount >= eventLimit) { finish('event_limit');return; }
        }
        if (active) finish('context_changed');
      } catch { readPending = false;finish('stream_unavailable'); }
    }
    function wrappedFetch(...args) {
      if (active && !current()) finish('context_changed');
      let matched = null;
      try { matched = match(args); } catch { /* Unknown request shapes are untouched. */ }
      // Reserve before invoking fetch: a reentrant wrapper cannot claim again.
      if (matched !== null) { matchedCalls++;route=matched;phase='awaiting_response'; }
      let promise;
      try { promise = apply(original,this,args); }
      catch (error) { if (matched !== null) finish('fetch_threw'); throw error; }
      if (matched !== null) {
        try {
          const observation = apply(promiseThen,promise,[
            response => { if (!current()) { finish('context_changed');return; }silence(observe(response)); },
            () => finish('fetch_rejected'),
          ]);
          silence(observation);
        } catch { finish('promise_shape'); }
      }
      return promise;
    }
    try {
      define(w,'fetch',{...initial,value:wrappedFetch});
      for (const name of ['pagehide','popstate','hashchange']) apply(add,w,[name,pageHidden,true]);
      timer=timeout(()=>finish('expired'),ttl);
    } catch { finish('installation_failed');return unavailable('installation_failed'); }
    if ('expectedPrompt' in optionValues || 'expectedMarker' in optionValues) {
      if (!arm({expectedPrompt:optionValues.expectedPrompt,expectedMarker:optionValues.expectedMarker})) {
        finish('invalid_arm');return unavailable('configuration');
      }
    }
    return freeze({status:'installed',arm,
      stop(){finish('stopped');return this.snapshot();},
      snapshot(){return parse(stringify({version:1,scope:'passive_synthetic_response_metadata_only',phase,terminalReason,
        armed,armUsed,matchedCalls,status,mime,route,bytesRead,eventCount,markerPresent,readPending,readCalls,lockReleased,
        unterminatedEventDiscarded,transitionCount,transitionReason,restore,events}));},
    });
  }
  // Native-only configuration. The reviewed observer above is unchanged from
  // SHA256 23838004da2d0875c7ee1dc2e8d318d149b22128240eecaf33c20be8772df117.
  // Only this random-key wrapper replaces the workspace's public installer.
  const config = __COMPUTA_CLAUDE_RESPONSE_STREAM_CONFIG__;
  if (!config || !/^__computaClaudeResponseStream_[a-f0-9]{32}$/.test(config.key)
    || !Number.isInteger(config.durationMs) || config.durationMs < 1 || config.durationMs > 60000
    || globalThis !== globalThis.top || Object.prototype.hasOwnProperty.call(globalThis,config.key)) return;
  let observer;
  try { observer=install({ttlMs:config.durationMs,maxBytes:65536,maxEvents:128,allowFreshConversationTransition:true}); }
  catch { return; }
  if (observer.status !== 'installed') return;
  const controller=function(command, expectedPrompt, expectedMarker) {
    if (command === 'arm') return observer.arm({expectedPrompt,expectedMarker});
    if (command !== 'stop') return null;
    try { return observer.stop(); }
    finally {
      if (Object.getOwnPropertyDescriptor(globalThis,config.key)?.value === controller) delete globalThis[config.key];
    }
  };
  try { Object.defineProperty(globalThis,config.key,{value:controller,writable:false,configurable:true}); }
  catch { observer.stop(); }
})();
