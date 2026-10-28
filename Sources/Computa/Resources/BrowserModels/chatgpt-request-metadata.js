// Opt-in native diagnostic on one disposable model view. Page-world records are
// untrusted observations: they cannot authorize input, retries, or tool output.
(() => {
  'use strict';
  const config = __COMPUTA_REQUEST_METADATA_CONFIG__;
  if (window !== window.top || location.origin !== 'https://chatgpt.com'
    || !config || !/^__computaRequestMetadata_[a-f0-9]{32}$/.test(config.key)
    || !Number.isInteger(config.durationMs) || config.durationMs < 1 || config.durationMs > 600000
    || Object.prototype.hasOwnProperty.call(window, config.key) || typeof window.fetch !== 'function') return;

  const original = window.fetch;
  const call = Reflect.apply;
  const then = Promise.prototype.then;
  const hasInstance = Function.prototype[Symbol.hasInstance];
  const descriptor = Object.getOwnPropertyDescriptor;
  const define = Object.defineProperty;
  const functionSource = Function.prototype.toString;
  const ownKeys = Reflect.ownKeys;
  const prototypeOf = Object.getPrototypeOf;
  const plainPrototype = Object.prototype;
  const arrayPrototype = Array.prototype;
  const isArray = Array.isArray;
  const charCodeAt = String.prototype.charCodeAt;
  const headersForEach = window.Headers && descriptor(window.Headers.prototype, 'forEach')?.value;
  const NativeURL = window.URL;
  const types = { blob: window.Blob, buffer: window.ArrayBuffer, stream: window.ReadableStream,
    form_data: window.FormData, url_params: window.URLSearchParams, type_error: window.TypeError, dom: window.DOMException };
  const isView = window.ArrayBuffer.isView;
  const responseStatus = descriptor(window.Response.prototype, 'status')?.get;
  const exceptionName = descriptor(window.DOMException.prototype, 'name')?.get;
  const now = performance.now.bind(performance);
  const created = now();
  const rows = [];
  // A different, explicit native purpose enables this finite diagnostic.
  // It observes the site's existing decoder, never a response stream or a reply
  // accepted by Computa. No module factory or protected parser is replaced.
  const captureDecodedEvents = config.captureDecodedEvents === true;
  const decoder = { state: 'pending', completionCalls: 0, programObservations: 0,
    recoveredNullObservations: 0, lastProgram: null,
    stream: { inputMessages: 0, assistantMessages: 0, nonemptyTextMessages: 0, opaqueMessages: 0,
      mainTerminals: 0, messageTerminals: 0, errorEvents: 0, originalThrows: 0,
      decoderInstances: 0, decoderOverflow: false } };
  const decoderInstances = new Set();
  let decoderSubscription = null, decoderActivation = null;
  let active = false, stopped = false, began = 0;
  const expired = () => now() - created >= config.durationMs;
  const elapsed = () => Math.max(0, Math.min(config.durationMs, now() - began));
  const available = () => active && !stopped && !expired();
  const unknown = Symbol('unknown');
  function data(object, key) {
    if (object == null) return undefined;
    if (typeof object !== 'object' && typeof object !== 'function') return unknown;
    try {
      // Do not invoke RequestInit getters or stringify request/body objects.
      const property = descriptor(object, key);
      if (property) return 'value' in property ? property.value : unknown;
      const prototype = prototypeOf(object);
      return prototype === plainPrototype || prototype === null ? undefined : unknown;
    } catch { return unknown; }
  }
  const nullProgram = 'DIL.render(__dil.jsx(()=>{const __dilConstants=DIL.useConstants();const __dilModelDataBindings=DIL.useAppData((appData)=>appData.opGenui?.modelDataBindings??{});return null;},{"key":"body:0"}));';
  const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  const conversationID = new RegExp('^' + uuid + '$');
  const conversationPath = new RegExp('^/c/(' + uuid + ')/?$');
  function conversationMatchesDocument(payload) {
    const id = data(payload, 'conversation_id');
    if (typeof id !== 'string' || !conversationID.test(id)) return null;
    try {
      const url = new NativeURL(location.href), match = conversationPath.exec(url.pathname);
      return url.origin === 'https://chatgpt.com' && match ? match[1] === id : null;
    } catch { return null; }
  }
  function position(value) {
    return Number.isInteger(value) && value >= 1 && value <= 1048576 ? value : null;
  }
  function observeProgram(program, carrier, status, association) {
    if (program == null || typeof program !== 'object' || program === unknown) return;
    const code = data(program, 'code'), fallback = data(program, 'fallbackMarkdown');
    const diagnostics = data(program, 'recoveryDiagnostics');
    let recovery = 'unknown', line = null, column = null;
    if (isArray(diagnostics)) {
      const length = data(diagnostics, 'length');
      if (length === 0) recovery = 'none';
      else if (Number.isInteger(length) && length > 0) {
        recovery = 'other';
        for (let i = 0; i < Math.min(length, 8); i++) {
          const item = data(diagnostics, `${i}`);
          if (data(item, 'code') === 'unterminated_braced_value' && data(item, 'action') === 'recovered_parse') {
            recovery = 'unterminated_braced_value_recovered_parse';
            line = position(data(item, 'line')); column = position(data(item, 'column')); break;
          }
        }
      }
    }
    const knownNull = code === nullProgram;
    decoder.programObservations = Math.min(65535, decoder.programObservations + 1);
    if (knownNull && recovery === 'unterminated_braced_value_recovered_parse')
      decoder.recoveredNullObservations = Math.min(65535, decoder.recoveredNullObservations + 1);
    decoder.lastProgram = { elapsedMs: elapsed(), carrier, messageStatus: status,
      conversationMatchesDocument: association,
      codeLength: typeof code === 'string' && code.length <= 1048576 ? code.length : null,
      knownNullProgram: knownNull, emptyFallbackMarkdown: typeof fallback === 'string' ? fallback.length === 0 : null,
      recovery, recoveryLine: line, recoveryColumn: column };
  }
  function increment(key) { decoder.stream[key] = Math.min(65535, decoder.stream[key] + 1); }
  function observeReceiver(receiver) {
    if (!decoderInstances.has(receiver)) {
      if (decoderInstances.size >= 16) decoder.stream.decoderOverflow = true;
      else { decoderInstances.add(receiver); decoder.stream.decoderInstances = decoderInstances.size; }
    }
  }
  // These are leased-view counters, not exact-input ownership or completion
  // proof. Multiple instances/inputs must be treated as attribution ambiguity.
  function observeDecoded(receiver, payload) {
    observeReceiver(receiver);
    const type = data(payload, 'type');
    if (type === 'input_message') increment('inputMessages');
    if (type === 'main_stream_complete') increment('mainTerminals');
    if (type === 'message_stream_complete') increment('messageTerminals');
    const error = data(payload, 'error'), code = data(payload, 'error_code');
    if (['error', 'message_error', 'conversation_error'].includes(type)
      || error !== unknown && error != null && (typeof error === 'object' || typeof error === 'string' && error.length > 0)
      || typeof code === 'string' && code.length > 0) increment('errorEvents');
    decoder.completionCalls = Math.min(65535, decoder.completionCalls + 1);
    const message = data(payload, 'message'), metadata = data(message, 'metadata');
    const rawStatus = data(message, 'status');
    const status = ['in_progress', 'finished_successfully', 'finished_partial'].includes(rawStatus) ? rawStatus
      : typeof rawStatus === 'string' ? 'other' : 'unknown';
    const association = conversationMatchesDocument(payload);
    if (data(data(message, 'author'), 'role') === 'assistant') {
      increment('assistantMessages');
      const content = data(message, 'content'), parts = data(content, 'parts');
      const text = isArray(parts) && data(parts, 'length') === 1 ? data(parts, '0') : unknown;
      if (data(content, 'content_type') === 'text' && typeof text === 'string') {
        if (text.length > 0) increment('nonemptyTextMessages');
      } else increment('opaqueMessages');
      observeProgram(data(metadata, 'model_dil_v2'), 'message', status, association);
      const references = data(metadata, 'content_references');
      if (isArray(references)) observeProgram(data(data(references, '0'), 'model_dil_v2'), 'reference', status, association);
    }
    if (data(payload, 'type') === 'content_references_patch') {
      const patches = data(payload, 'content_references');
      if (isArray(patches)) observeProgram(data(data(patches, '0'), 'model_dil_v2'), 'reference_patch', 'unknown', association);
    }
  }
  function restoreDecoder() {
    if (!decoderSubscription) {
      if (decoder.state === 'pending') decoder.state = 'restored';
      return;
    }
    const subscription = decoderSubscription; decoderSubscription = null;
    try { decoder.state = subscription.stop() ? 'restored' : 'superseded'; }
    catch { decoder.state = 'superseded'; }
  }
  function activateDecoder() {
    if (active || stopped || expired()) return snapshot();
    if (decoderActivation) return decoderActivation;
    decoderActivation = (async () => {
      try {
        if (!/^__computaCompletion_[a-f0-9]{32}$/.test(config.completionKey)) throw unknown;
        const completion = data(window, config.completionKey), subscribe = data(completion, 'subscribeDiagnostic');
        if (typeof subscribe !== 'function') throw unknown;
        const admitted = () => !stopped && !expired() && descriptor(window, config.key)?.value === hook
          && data(window, config.completionKey) === completion;
        const subscription = await call(subscribe, completion, [{
          durationMs: Math.max(1, Math.floor(config.durationMs - (now() - created))), admitted,
          value(receiver, result) { if (available()) observeDecoded(receiver, result); },
          thrown(receiver) { if (available()) { observeReceiver(receiver); increment('originalThrows'); } },
          invalidated(reason) {
            active = false;
            decoder.state = reason === 'expired' || reason === 'route_changed' ? 'restored' : 'superseded';
            decoderSubscription = null;
          }
        }]);
        if (!subscription) throw unknown;
        if (!admitted()) { subscription.stop(); return snapshot(); }
        decoderSubscription = subscription; decoder.state = 'installed'; active = true; began = now();
      } catch { if (decoder.state === 'pending') decoder.state = 'unavailable'; }
      return snapshot();
    })();
    return decoderActivation;
  }
  function utf8Size(value) {
    if (value.length > 1048576) return null;
    let bytes = 0;
    for (let i = 0; i < value.length; i++) {
      const unit = call(charCodeAt, value, [i]);
      if (unit < 0x80) bytes++;
      else if (unit < 0x800) bytes += 2;
      else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < value.length
        && call(charCodeAt, value, [i + 1]) >= 0xdc00 && call(charCodeAt, value, [i + 1]) <= 0xdfff) { bytes += 4; i++; }
      else bytes += 3;
      if (bytes > 1048576) return null;
    }
    return bytes;
  }
  function instance(value, constructor) {
    try { return typeof constructor === 'function' && call(hasInstance, constructor, [value]); }
    catch { return false; }
  }
  function bodyType(body) {
    if (body === unknown) return 'unknown';
    if (body == null) return 'none';
    if (typeof body === 'string') return 'string';
    if (instance(body, types.blob)) return 'blob';
    if (instance(body, types.buffer)) return 'buffer';
    if (isView(body)) return 'view';
    if (instance(body, types.stream)) return 'stream';
    if (instance(body, types.form_data)) return 'form_data';
    if (instance(body, types.url_params)) return 'url_params';
    return 'unknown';
  }
  function headerMetadata(headers) {
    // These are supplied-header observations, not wire sizes: browser-added
    // cookies and other headers are absent, and Headers has already normalized
    // or combined its entries. Unknown/over-budget input stays wholly unknown.
    if (headers == null || headers === unknown || (typeof headers !== 'object' && typeof headers !== 'function')) return null;
    const aggregate = { representation: 'native_headers', count: 0, nameUTF8Bytes: 0, valueUTF8Bytes: 0,
      maxValueUTF8Bytes: 0, invalidTokenName: false, hasNUL: false, hasCRLF: false, hasNonLatin1: false };
    const limit = 1048576, stop = Symbol('header budget');
    function measure(value, name) {
      if (typeof value !== 'string' || value.length > limit) throw stop;
      let bytes = 0;
      if (name && value.length === 0) aggregate.invalidTokenName = true;
      for (let i = 0; i < value.length; i++) {
        const unit = call(charCodeAt, value, [i]);
        if (unit === 0) aggregate.hasNUL = true;
        if (unit === 10 || unit === 13) aggregate.hasCRLF = true;
        if (unit > 255) aggregate.hasNonLatin1 = true;
        if (name && !((unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
          || unit === 33 || (unit >= 35 && unit <= 39) || unit === 42 || unit === 43 || unit === 45 || unit === 46
          || unit === 94 || unit === 95 || unit === 96 || unit === 124 || unit === 126)) aggregate.invalidTokenName = true;
        if (unit < 0x80) bytes++;
        else if (unit < 0x800) bytes += 2;
        else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < value.length
          && call(charCodeAt, value, [i + 1]) >= 0xdc00 && call(charCodeAt, value, [i + 1]) <= 0xdfff) {
          bytes += 4; i++;
        } else bytes += 3;
        if (aggregate.nameUTF8Bytes + aggregate.valueUTF8Bytes + bytes > limit) throw stop;
      }
      return bytes;
    }
    function entry(value, name) {
      if (++aggregate.count > 256) throw stop;
      aggregate.nameUTF8Bytes += measure(name, true);
      const bytes = measure(value, false);
      aggregate.valueUTF8Bytes += bytes;
      if (bytes > aggregate.maxValueUTF8Bytes) aggregate.maxValueUTF8Bytes = bytes;
    }
    if (typeof headersForEach === 'function') {
      try { call(headersForEach, headers, [entry]); return aggregate; }
      catch (reason) { if (reason === stop) return null; }
    }
    try {
      // Inspect only own data properties; no conversion, iterator invocation,
      // or accessor reads. Reflection can still encounter a page Proxy trap.
      if (isArray(headers) && prototypeOf(headers) === arrayPrototype) {
        aggregate.representation = 'pairs';
        const length = descriptor(headers, 'length')?.value;
        if (!Number.isInteger(length) || length < 0 || length > 256 || descriptor(headers, Symbol.iterator)) return null;
        for (let i = 0; i < length; i++) {
          const pair = data(headers, `${i}`);
          if (!isArray(pair) || prototypeOf(pair) !== arrayPrototype || descriptor(pair, 'length')?.value !== 2
            || descriptor(pair, Symbol.iterator)) return null;
          entry(data(pair, '1'), data(pair, '0'));
        }
      } else {
        const prototype = prototypeOf(headers);
        if (prototype !== plainPrototype && prototype !== null) return null;
        aggregate.representation = 'record';
        // ownKeys itself can allocate for an oversized record or enter a Proxy
        // trap; the limits bound subsequent scanning and retained metadata.
        const keys = ownKeys(headers);
        if (keys.length > 256) return null;
        for (const key of keys) {
          const property = descriptor(headers, key);
          if (!property) return null;
          if (!property.enumerable) continue;
          if (typeof key !== 'string' || !('value' in property)) return null;
          entry(property.value, key);
        }
      }
      return aggregate;
    } catch { return null; }
  }
  function requestRow(args) {
    const input = args[0], init = args[1];
    let endpoint = 'unknown', origin = 'unknown';
    if (typeof input === 'string') {
      try {
        const url = new NativeURL(input, location.href);
        origin = url.origin === location.origin ? 'same' : 'other';
        endpoint = origin !== 'same' ? 'other'
          : /^\/backend-api\/(?:f\/)?conversation\/?$/.test(url.pathname) ? 'conversation'
          : /^\/backend-api\/(?:(?:f\/)?conversation\/prepare|sentinel\/chat-requirements)\/?$/.test(url.pathname)
            ? 'preparation' : 'other';
      } catch { /* Never retain the URL, query, fragment, or parse error. */ }
    }
    // Reserve this finite capture for model submission requests. Unrelated
    // fetches keep their original behavior and receive no settlement observer.
    if (origin !== 'same' || (endpoint !== 'conversation' && endpoint !== 'preparation')) return null;
    const method = data(init, 'method'), body = data(init, 'body');
    const keepalive = data(init, 'keepalive'), duplex = data(init, 'duplex');
    const type = bodyType(typeof input === 'string' ? body : unknown);
    return { ordinal: rows.length + 1, endpoint, origin,
      method: method === 'GET' || method === 'POST' ? method
        : method === undefined ? typeof input === 'string' ? 'GET' : 'unknown' : method === unknown ? 'unknown' : 'other',
      bodyType: type, bodyBytes: type === 'string' ? utf8Size(body) : type === 'none' ? 0 : null,
      headerMetadata: headerMetadata(data(init, 'headers')),
      keepalive: keepalive === true ? 'true' : keepalive === false ? 'false'
        : keepalive === undefined && typeof input === 'string' ? 'absent' : 'unknown',
      duplex: duplex === 'half' ? 'half' : duplex === undefined ? typeof input === 'string' ? 'absent' : 'unknown'
        : duplex === unknown ? 'unknown' : 'other',
      startedMs: elapsed(), settledMs: null, outcome: 'pending', status: null, error: 'none' };
  }
  function errorKind(reason) {
    if (instance(reason, types.type_error)) return 'type_error';
    try {
      if (instance(reason, types.dom)) {
        const name = exceptionName ? call(exceptionName, reason, []) : null;
        if (name === 'AbortError') return 'abort';
        if (name === 'NotSupportedError') return 'unsupported';
      }
    } catch { /* Error messages and stacks are never inspected. */ }
    return 'other';
  }
  function settle(row, outcome, response, reason) {
    if (!available()) return;
    row.settledMs = elapsed();
    row.outcome = outcome;
    row.error = outcome === 'headers' ? 'none' : errorKind(reason);
    if (outcome === 'headers') {
      try {
        // Fetch resolution reports headers, not response-stream completion.
        const status = responseStatus ? call(responseStatus, response, []) : null;
        if (Number.isInteger(status) && status >= 100 && status <= 599) row.status = status;
      } catch { /* Opaque or nonstandard responses keep unknown status. */ }
    }
  }
  function observer(...args) {
    let row = null;
    if (available() && rows.length < 8) {
      try { row = requestRow(args); if (row) rows.push(row); } catch { /* Diagnosis cannot reject a fetch. */ }
    }
    let promise;
    try { promise = call(original, this, args); }
    catch (reason) { if (row) { try { settle(row, 'sync_throw', null, reason); } catch {} } throw reason; }
    if (row) {
      try {
        // Return the original promise. This observer still changes fetch
        // identity and rejection bookkeeping; it is an instrumented condition.
        call(then, promise, [
          response => { try { settle(row, 'headers', response, null); } catch {} },
          reason => { try { settle(row, 'rejected', null, reason); } catch {} },
        ]);
      } catch { /* A nonstandard promise remains unmodified. */ }
    }
    return promise;
  }
  function snapshot() {
    if (captureDecodedEvents && (expired() || decoderSubscription && !decoderSubscription.active())) restoreDecoder();
    const value = { schemaVersion: captureDecodedEvents ? 2 : 1, active: available(), expired: expired(),
      rows: rows.map(row => ({ ...row })) };
    if (captureDecodedEvents) value.decoder = { ...decoder, stream: { ...decoder.stream },
      lastProgram: decoder.lastProgram ? { ...decoder.lastProgram } : null };
    return value;
  }
  function hook(command) {
    if (command === 'activate' && !stopped && !expired()) {
      if (captureDecodedEvents) return activateDecoder();
      if (!active) { active = true; began = now(); }
    } else if (command === 'stop') {
      active = false; stopped = true;
      if (captureDecodedEvents) restoreDecoder();
      if (window.fetch === observer) window.fetch = original;
      delete window[config.key];
    } else if (command !== 'snapshot') return null;
    return snapshot();
  }
  try {
    define(window, config.key, { value: hook, configurable: true });
    window.fetch = observer;
    if (window.fetch !== observer) delete window[config.key];
  } catch { if (window.fetch === observer) window.fetch = original; delete window[config.key]; }
})();
