// Inert private prototype. This expression creates no page/global controller.
// Caller must establish the unchanged native exact-request/response joins first.
(() => {
  'use strict';
  const purpose = 'groq_120b_fixture_response_stream_metadata_v1';
  const limits = Object.freeze({bytes:262144, events:4096, frameBytes:16384, durationMS:60000});
  const apply = Reflect.apply, descriptor = Object.getOwnPropertyDescriptor;
  const parse = JSON.parse, stringify = JSON.stringify;
  const own = (value, key) => value !== null && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, key);
  const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const dataValue = (value, key) => record(value) ? descriptor(value, key)?.value : undefined;
  const nativeClone = typeof Response === 'function' ? descriptor(Response.prototype, 'clone')?.value : null;
  const nativeBody = typeof Response === 'function' ? descriptor(Response.prototype, 'body')?.get : null;
  const nativeStatus = typeof Response === 'function' ? descriptor(Response.prototype, 'status')?.get : null;
  const nativeHeaders = typeof Response === 'function' ? descriptor(Response.prototype, 'headers')?.get : null;
  const nativeHeaderGet = typeof Headers === 'function' ? descriptor(Headers.prototype, 'get')?.value : null;
  const nativeReader = typeof ReadableStream === 'function' ? descriptor(ReadableStream.prototype, 'getReader')?.value : null;
  const readerPrototype = typeof ReadableStreamDefaultReader === 'function' ? ReadableStreamDefaultReader.prototype : null;
  const nativeRead = readerPrototype ? descriptor(readerPrototype, 'read')?.value : null;
  const nativeCancel = readerPrototype ? descriptor(readerPrototype, 'cancel')?.value : null;
  const nativeRelease = readerPrototype ? descriptor(readerPrototype, 'releaseLock')?.value : null;
  const nativeThen = Promise.prototype.then;

  // JSON.parse alone would silently collapse duplicate selected keys. Reject
  // duplicate keys at every object depth, including escaped aliases. No source
  // text, keys, strings or parser exception survives this bounded call.
  function uniqueJSON(text) {
    const value = parse(text);
    let at = 0, nodes = 0;
    const space = () => { while (/\s/.test(text[at] || '') && at < text.length) at++; };
    function string() {
      const start = at++;
      while (at < text.length) {
        const c = text[at++];
        if (c === '"') return parse(text.slice(start, at));
        if (c === '\\') at++;
      }
      throw 0;
    }
    function item(depth) {
      if (++nodes > 4096 || depth > 32) throw 0;
      space();
      if (text[at] === '{') {
        at++; space(); const keys = new Set();
        if (text[at] === '}') { at++; return; }
        while (true) {
          space(); if (text[at] !== '"') throw 0;
          const key = string(); if (keys.has(key)) throw 0; keys.add(key);
          space(); if (text[at++] !== ':') throw 0; item(depth + 1); space();
          const end = text[at++]; if (end === '}') return; if (end !== ',') throw 0;
        }
      }
      if (text[at] === '[') {
        at++; space(); if (text[at] === ']') { at++; return; }
        while (true) { item(depth + 1); space(); const end = text[at++]; if (end === ']') return; if (end !== ',') throw 0; }
      }
      if (text[at] === '"') { string(); return; }
      const start = at; while (at < text.length && !/[\s,\]}]/.test(text[at])) at++;
      if (start === at) throw 0;
    }
    item(0); space(); if (at !== text.length) throw 0;
    return value;
  }

  function createGroqSSEMetadataParser(framing = 'sse') {
    if (!['sse','json','other','missing'].includes(framing)) framing = 'other';
    const facts = {version:1, framing, bytes:0, chunks:0, events:0, jsonEvents:0,
      content:false, reasoning:false, toolCalls:false, topLevelError:false,
      eventError:false, xGroqError:'none', apiErrorCode:'none', apiErrorType:'none', finishReason:'none', done:false,
      eof:false, unknownFrames:0, incompleteFrame:false, outcome:'reading'};
    let decoder = new TextDecoder('utf-8', {fatal:true}), line = '', lineBytes = 0;
    let data = [], dataBytes = 0, jsonBuffer = '', jsonBytes = 0, eventError = false, hadCR = false, stopped = false;
    function clear() { line = ''; lineBytes = 0; data = []; dataBytes = 0; jsonBuffer = ''; jsonBytes = 0; eventError = false; decoder = null; }
    function stop(reason) {
      if (stopped) return;
      facts.outcome = ['eof','byte_limit','event_limit','chunk_limit','frame_limit','utf8_invalid',
        'read_rejected','deadline','revoked','disposed','unavailable'].includes(reason) ? reason : 'unavailable';
      stopped = true; clear();
    }
    function unknown() { facts.unknownFrames = Math.min(limits.events, facts.unknownFrames + 1); }
    function finish(value) {
      const next = ['stop','length','tool_calls','function_call','content_filter'].includes(value) ? value : 'other';
      facts.finishReason = facts.finishReason === 'none' || facts.finishReason === next ? next : 'multiple';
    }
    function errorEnum(key, value, allowed) {
      const next = allowed.includes(value) ? value : 'other';
      facts[key] = facts[key] === 'none' || facts[key] === next ? next : 'other';
    }
    function json(text) {
      let value; try { value = uniqueJSON(text); } catch { unknown(); return; }
      if (!record(value)) { unknown(); return; }
      facts.jsonEvents++;
      let recognized = false;
      if (own(value, 'error')) {
        recognized = true;
        if (value.error) {
          facts.topLevelError = true;
          if (record(value.error)) {
            if (own(value.error, 'code')) errorEnum('apiErrorCode', value.error.code,
              ['rate_limit_exceeded','context_length_exceeded','invalid_api_key','model_not_found','invalid_request_error',
                'insufficient_quota','over_capacity','service_unavailable']);
            if (own(value.error, 'type')) errorEnum('apiErrorType', value.error.type,
              ['rate_limit_error','invalid_request_error','authentication_error','permission_error','not_found_error','server_error','insufficient_quota','tokens','requests']);
          } else { errorEnum('apiErrorCode', null, []); errorEnum('apiErrorType', null, []); }
        }
      }
      if (own(value, 'x_groq') && record(value.x_groq) && own(value.x_groq, 'error')) {
        recognized = true;
        const error = value.x_groq.error;
        if (error) {
          const next = ['over_capacity','rate_limit_exceeded','service_unavailable'].includes(error) ? error : 'other';
          facts.xGroqError = facts.xGroqError === 'none' || facts.xGroqError === next ? next : 'other';
        }
      }
      if (own(value, 'choices')) {
        if (!Array.isArray(value.choices) || value.choices.length > 4) { unknown(); return; }
        recognized = true;
        for (const choice of value.choices) {
          if (!record(choice)) { unknown(); continue; }
          if (own(choice, 'finish_reason') && choice.finish_reason !== null) finish(choice.finish_reason);
          if (!own(choice, 'delta')) continue;
          if (!record(choice.delta)) { unknown(); continue; }
          const delta = choice.delta;
          facts.content ||= own(delta, 'content') && typeof delta.content === 'string' && delta.content.length > 0;
          facts.reasoning ||= own(delta, 'reasoning') && typeof delta.reasoning === 'string' && delta.reasoning.length > 0
            || own(delta, 'reasoning_content') && typeof delta.reasoning_content === 'string' && delta.reasoning_content.length > 0;
          facts.toolCalls ||= own(delta, 'tool_calls') && Array.isArray(delta.tool_calls) && delta.tool_calls.length > 0
            || own(delta, 'function_call') && record(delta.function_call);
        }
      }
      if (!recognized) unknown();
    }
    function event() {
      if (!data.length) { eventError = false; return; }
      if (facts.events === limits.events) { stop('event_limit'); return; }
      facts.events++;
      const text = data.join('\n'), hadEventError = eventError; data = []; dataBytes = 0; eventError = false;
      if (text === '[DONE]') { facts.done = true; return; }
      if (facts.done) { unknown(); return; }
      facts.eventError ||= hadEventError;
      json(text);
    }
    function consumeLine() {
      if (!line.length) { event(); if (!stopped && facts.events === limits.events) stop('event_limit'); }
      else if (line[0] !== ':') {
        const colon = line.indexOf(':'), field = colon < 0 ? line : line.slice(0, colon);
        let value = colon < 0 ? '' : line.slice(colon + 1); if (value[0] === ' ') value = value.slice(1);
        if (field === 'data') {
          const size = new TextEncoder().encode(value).length + (data.length ? 1 : 0);
          if (dataBytes + size > limits.frameBytes) stop('frame_limit');
          else { data.push(value); dataBytes += size; }
        } else if (field === 'event') eventError = value === 'error';
      }
      line = ''; lineBytes = 0;
    }
    function text(value) {
      for (const c of value) {
        if (stopped) return;
        if (framing === 'json') {
          const cp = c.codePointAt(0), n = cp < 128 ? 1 : cp < 2048 ? 2 : cp < 65536 ? 3 : 4;
          if (jsonBytes + n > limits.frameBytes) { stop('frame_limit'); return; }
          jsonBuffer += c; jsonBytes += n; continue;
        }
        if (hadCR) { hadCR = false; if (c === '\n') continue; }
        if (c === '\r' || c === '\n') { consumeLine(); hadCR = c === '\r'; continue; }
        const cp = c.codePointAt(0), n = cp < 128 ? 1 : cp < 2048 ? 2 : cp < 65536 ? 3 : 4;
        if (lineBytes + n > limits.frameBytes) { stop('frame_limit'); return; }
        line += c; lineBytes += n;
      }
    }
    function push(bytes) {
      if (stopped) return false;
      if (!(bytes instanceof Uint8Array)) { stop('unavailable'); return false; }
      facts.chunks = Math.min(65535, facts.chunks + 1);
      if (facts.chunks >= 8192) { stop('chunk_limit'); return false; }
      const remaining = limits.bytes - facts.bytes, take = Math.min(remaining, bytes.byteLength);
      facts.bytes += take;
      try {
        if (framing === 'other' || framing === 'missing') { if (take) facts.unknownFrames = 1; }
        else for (let at = 0; at < take && !stopped; at += 4096) text(decoder.decode(bytes.subarray(at, Math.min(take, at + 4096)), {stream:true}));
      } catch { stop('utf8_invalid'); }
      if (!stopped && bytes.byteLength >= remaining) stop('byte_limit');
      return !stopped;
    }
    function end() {
      if (stopped) return;
      try { text(decoder.decode()); } catch { stop('utf8_invalid'); return; }
      if (stopped) return;
      if (framing === 'json' && jsonBuffer.length) { facts.events = 1; json(jsonBuffer); }
      facts.eof = true; facts.incompleteFrame = framing === 'sse' && (line.length > 0 || data.length > 0);
      stop('eof');
    }
    return Object.freeze({push, end, stop, isStopped:() => stopped, snapshot:() => ({__proto__:null, ...facts})});
  }

  // This API does NOT establish native admission. Root integration must invoke
  // it only inside the already-accepted single request/Response callback. Clone
  // tees the body: object identity is preserved, timing equivalence is not.
  function startMatchedGroqResponseStreamProbe(value, options) {
    if (dataValue(options, 'streamMetadata') !== true || dataValue(options, 'purpose') !== purpose
      || dataValue(options, 'profile') !== 'gptoss120b') return null;
    const isCurrent = dataValue(options, 'isCurrent');
    if (typeof isCurrent !== 'function' || ![nativeClone,nativeBody,nativeStatus,nativeHeaders,nativeHeaderGet,nativeReader,nativeRead,nativeCancel,nativeRelease]
      .every(fn => typeof fn === 'function')) return null;
    const current = () => { try { return isCurrent() === true; } catch { return false; } };
    if (!current()) return null;
    let clone, reader, framing;
    try {
      const status = apply(nativeStatus, value, []);
      if (status < 200 || status >= 300) return null;
      const header = apply(nativeHeaderGet, apply(nativeHeaders, value, []), ['content-type']);
      const type = typeof header === 'string' ? header.split(';', 1)[0].trim().toLowerCase() : null;
      framing = type === 'text/event-stream' ? 'sse' : type === 'application/json' ? 'json' : type === null ? 'missing' : 'other';
      clone = apply(nativeClone, value, []);
      const body = apply(nativeBody, clone, []); if (!body) return null;
      reader = apply(nativeReader, body, []);
    } catch { return null; }
    const parser = createGroqSSEMetadataParser(framing);
    const now = performance.now.bind(performance), expiresAt = now() + limits.durationMS;
    let stopped = false, published = false, timer, settle;
    const settled = new Promise(resolve => { settle = resolve; });
    function cancel() {
      try { const promise = apply(nativeCancel, reader, []); apply(nativeThen, promise, [() => {}, () => {}]); } catch { /* Closed category only. */ }
    }
    function stop(reason = 'disposed') {
      if (stopped) return;
      stopped = true; clearTimeout(timer); parser.stop(reason); cancel(); settle();
    }
    timer = setTimeout(() => stop(current() ? 'deadline' : 'revoked'), limits.durationMS);
    (async () => {
      try {
        while (!stopped) {
          if (!current()) { stop('revoked'); break; }
          if (now() >= expiresAt) { stop('deadline'); break; }
          const next = await apply(nativeRead, reader, []);
          if (stopped) break;
          if (!current()) { stop('revoked'); break; }
          if (now() >= expiresAt) { stop('deadline'); break; }
          if (next.done) { parser.end(); stop('eof'); break; }
          if (!parser.push(next.value)) { stop(parser.snapshot().outcome); break; }
        }
      } catch { if (!stopped) stop(current() ? 'read_rejected' : 'revoked'); }
      finally { try { apply(nativeRelease, reader, []); } catch { /* A pending read can delay release; cancellation is never awaited. */ } }
    })();
    return Object.freeze({settled, stop,
      finishFailure:() => {
        if (published || !current()) { stop('revoked'); return null; }
        if (now() >= expiresAt) stop('deadline');
        published = true; const snapshot = parser.snapshot(); stop('disposed');
        // snapshot is frozen at first failure; later clone activity is ignored.
        return snapshot.outcome === 'revoked' || snapshot.outcome === 'disposed' ? null : snapshot;
      }});
  }
  return Object.freeze({createGroqSSEMetadataParser, startMatchedGroqResponseStreamProbe});
})()
