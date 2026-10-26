// A completion event only admits the normal, fresh DOM/model/ownership proof.
// It never supplies a response to the transport or dispatches a tool.
(() => {
  'use strict';
  const config = __COMPUTA_COMPLETION_CONFIG__;
  if (window !== window.top || location.origin !== 'https://chatgpt.com'
    || !config || !/^__computaCompletion_[a-f0-9]{32}$/.test(config.key)
    || config.handlerName !== 'computaChatGPTCompletion'
    || Object.prototype.hasOwnProperty.call(window, config.key)) return;
  const apply = Reflect.apply, descriptor = Object.getOwnPropertyDescriptor, define = Object.defineProperty;
  const prototypeOf = Object.getPrototypeOf, ownKeys = Reflect.ownKeys, functionSource = Function.prototype.toString;
  const unknown = Symbol('unknown'), initialDocument = document;
  const now = performance.now.bind(performance), encoder = new TextEncoder();
  const resourceEntries = typeof performance.getEntriesByType === 'function'
    ? performance.getEntriesByType.bind(performance) : null;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const completionSource = 'recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}';
  const sendSelector = 'button[data-testid="send-button"], button[aria-label="Send prompt"], button[aria-label="Send message"], button[aria-label="Send"]';
  const stopSelector = 'button[data-testid="stop-button"], button[aria-label="Stop streaming"], button[aria-label="Stop generating"], button[aria-label="Stop"]';
  const diagnosticReasons = Object.freeze(['runtime_unsupported', 'runtime_resources_unavailable', 'runtime_import_failed',
    'runtime_cache_unsupported', 'runtime_identity_changed', 'call_limit', 'decoder_limit', 'route_changed',
    'wrapper_changed', 'input_shape', 'input_hash', 'owner_conflict', 'parent_changed', 'parent_limit', 'ancestry_missing',
    'final_status', 'final_changed', 'terminal_order', 'terminal_opaque', 'error', 'send_changed', 'expired', 'observer_exception']);
  let lease = null;
  function data(object, key) {
    if (object == null) return undefined;
    if (typeof object !== 'object' && typeof object !== 'function') return unknown;
    try {
      const property = descriptor(object, key);
      if (property) return 'value' in property ? property.value : unknown;
      const prototype = prototypeOf(object);
      return prototype === Object.prototype || prototype === null ? undefined : unknown;
    } catch { return unknown; }
  }
  // Website telemetry clears its global resource timing buffer after startup.
  // Retain only up to eight completed exact runtime URLs in this document; no
  // request bodies, headers, arbitrary URLs or resource payloads are retained.
  const runtimeResources = new Set(), inventoryDeadline = now() + 600000;
  let resourceObserver = null, resourceTakeRecords = null, resourceDisconnect = null;
  let inventoryInvalid = false, inventoryTimer = null, inventoryPagehide = null;
  function stopRuntimeInventory() {
    inventoryInvalid = true; runtimeResources.clear();
    bestEffort(() => resourceDisconnect?.());
    bestEffort(() => { if (inventoryTimer !== null) clearTimeout(inventoryTimer); });
    bestEffort(() => { if (inventoryPagehide) window.removeEventListener('pagehide', inventoryPagehide); });
    resourceObserver = null; resourceTakeRecords = null; resourceDisconnect = null; inventoryTimer = null; inventoryPagehide = null;
  }
  function collectRuntimeResources(entries) {
    if (inventoryInvalid) return;
    if (document !== initialDocument || window !== window.top || location.origin !== 'https://chatgpt.com'
      || now() >= inventoryDeadline || !Array.isArray(entries) || entries.length > 4096) {
      stopRuntimeInventory(); return;
    }
    try {
      for (const entry of entries) {
        if (!entry || !['script', 'link'].includes(entry.initiatorType) || typeof entry.name !== 'string'
          || !/^https:\/\/chatgpt\.com\/cdn\/assets\/633146\.[a-f0-9]{10}\.js$/.test(entry.name)
          || !Number.isFinite(entry.startTime) || entry.startTime < 0
          || !Number.isFinite(entry.responseEnd) || entry.responseEnd <= 0
          || entry.responseEnd < entry.startTime || entry.responseEnd > now()) continue;
        if (entry.responseStatus !== undefined && entry.responseStatus !== 0 && entry.responseStatus !== 200) continue;
        if (!runtimeResources.has(entry.name) && runtimeResources.size >= 8) { stopRuntimeInventory(); return; }
        runtimeResources.add(entry.name);
      }
    } catch { stopRuntimeInventory(); }
  }
  // Install before website startup. Observer records are independent of the
  // website's clearResourceTimings(); draining them avoids a delivery race.
  try {
    if (typeof PerformanceObserver === 'function') {
      resourceObserver = new PerformanceObserver(list => {
        try { collectRuntimeResources(list.getEntries()); } catch { stopRuntimeInventory(); }
      });
      resourceTakeRecords = resourceObserver.takeRecords.bind(resourceObserver);
      resourceDisconnect = resourceObserver.disconnect.bind(resourceObserver);
      resourceObserver.observe({ type: 'resource', buffered: true });
      inventoryPagehide = () => stopRuntimeInventory();
      window.addEventListener('pagehide', inventoryPagehide);
      inventoryTimer = setTimeout(stopRuntimeInventory, Math.max(0, inventoryDeadline - now()));
    }
    if (resourceEntries) collectRuntimeResources(resourceEntries('resource'));
  } catch { stopRuntimeInventory(); }
  function observedRuntimeURL() {
    // Observation proves a completed fetch, not ESM evaluation. Import only the
    // unique same-document observed URL, never a guessed or pinned predecessor.
    try {
      if (resourceTakeRecords) collectRuntimeResources(resourceTakeRecords());
      if (resourceEntries) collectRuntimeResources(resourceEntries('resource'));
    } catch { stopRuntimeInventory(); }
    return !inventoryInvalid && now() < inventoryDeadline && runtimeResources.size === 1
      ? [...runtimeResources][0] : null;
  }
  function initializedDecoder(runtime) {
    // Website chunk/module IDs change independently. Inspect bounded initialized
    // cache entries only: no require, module factory, or unapproved export getter.
    const require = data(runtime, '__webpack_require__'), cache = data(require, 'c');
    if (!cache || typeof cache !== 'object' || ![Object.prototype, null].includes(prototypeOf(cache))) throw unknown;
    const keys = ownKeys(cache);
    if (keys.length > 16384) throw unknown;
    let found = null;
    for (const key of keys) {
      if (typeof key !== 'string' || key.length > 64) continue;
      const cached = data(cache, key), exports = data(cached, 'exports');
      const exported = exports && exports !== unknown ? descriptor(exports, 'c') : null;
      if (!exported || typeof exported.get !== 'function' || exported.set !== undefined
        || exported.enumerable !== true || exported.configurable !== false
        || apply(functionSource, exported.get, []) !== '()=>O') continue;
      // A different cached module can expose the same literal getter while its
      // binding is not initialized yet. It supplies no decoder evidence.
      let Decoder;
      try { Decoder = apply(exported.get, exports, []); } catch { continue; }
      const target = data(Decoder, 'prototype');
      const original = target && target !== unknown ? descriptor(target, 'recordCompletion') : null;
      if (!original || typeof original.value !== 'function' || original.writable !== true
        || original.configurable !== true || original.enumerable !== false
        || data(original.value, 'name') !== 'recordCompletion' || data(original.value, 'length') !== 1
        || apply(functionSource, original.value, []) !== completionSource) continue;
      if (found && found.target !== target) throw unknown;
      found = { cache, key, cached, exports, exported, target, original };
    }
    if (!found) throw unknown;
    return found;
  }
  const id = value => typeof value === 'string' && uuid.test(value) ? value : null;
  function keys(object, expected) {
    try { return object && typeof object === 'object' && !Array.isArray(object)
      && Object.keys(object).sort().join(',') === expected; } catch { return false; }
  }
  function post(record) {
    try {
      const handler = window.webkit?.messageHandlers?.[config.handlerName];
      if (typeof handler?.postMessage === 'function') handler.postMessage(record);
    } catch { /* Native absence or rejection never changes website behavior. */ }
  }
  function identity(current, kind) {
    return { version: 1, kind, correlationID: current.correlationID,
      sequence: current.sequence, inputSHA256: current.inputSHA256 };
  }
  function bestEffort(action) { try { action(); } catch { /* Cleanup cannot change a decoded return or throw. */ } }
  function diagnostic(current, reason) {
    // First observed rejection only; an unclaimed decoder can be unrelated to
    // the eventual matching input. This record supplies no completion authority.
    if (lease !== current || current.stopped || current.diagnosticSent || !diagnosticReasons.includes(reason)) return;
    current.diagnosticSent = true;
    post({ ...identity(current, 'diagnostic'), reason, calls: current.calls, instances: current.instances.size });
  }
  function restore(current, notify, reason = null) {
    if (lease !== current || current.stopped) return;
    if (reason !== null) bestEffort(() => diagnostic(current, reason));
    current.stopped = true; lease = null;
    bestEffort(() => clearTimeout(current.timer));
    bestEffort(() => current.observer?.disconnect());
    bestEffort(() => initialDocument.removeEventListener('click', current.click, true));
    bestEffort(() => window.removeEventListener('pagehide', current.pagehide));
    bestEffort(() => window.removeEventListener('popstate', current.pathchange));
    bestEffort(() => window.removeEventListener('hashchange', current.pathchange));
    if (current.target) {
      try {
        const present = descriptor(current.target, 'recordCompletion');
        if (present && present.value === current.wrapper && present.writable === true
          && present.configurable === true && present.enumerable === false)
          define(current.target, 'recordCompletion', current.original);
      } catch { /* Never replace a newer owner's method. */ }
    }
    if (notify) post(identity(current, 'invalidated'));
  }
  function route(current) {
    try {
      if (document !== initialDocument || window !== window.top || location.origin !== 'https://chatgpt.com'
        || descriptor(window, config.key)?.value !== api || now() >= current.deadline) return false;
      const url = new URL(location.href), path = url.pathname;
      if (url.origin !== 'https://chatgpt.com' || url.hash) return false;
      if (path === '/') return current.routeKind === 'root';
      const server = /^\/c\/([0-9a-f-]+)\/?$/.exec(path);
      if (server && uuid.test(server[1])) {
        if (current.serverID && current.serverID !== server[1]
          || current.owner && current.owner.conversationID !== server[1]) return false;
        current.serverID = server[1]; current.routeKind = 'server'; return true;
      }
      const local = /^\/c\/(local-chatgpt(?::|%3A)[0-9a-f-]+)\/?$/i.exec(path);
      if (!local || current.routeKind === 'server' || current.localID && current.localID !== local[1]) return false;
      current.localID = local[1]; current.routeKind = 'local'; return true;
    } catch { return false; }
  }
  function live(current) {
    if (lease !== current || current.stopped) return false;
    if (!route(current)) { restore(current, true, now() >= current.deadline ? 'expired' : 'route_changed'); return false; }
    if (current.target) {
      const present = descriptor(current.target, 'recordCompletion');
      if (!present || present.value !== current.wrapper || present.writable !== true
        || present.configurable !== true || present.enumerable !== false) { restore(current, true, 'wrapper_changed'); return false; }
    }
    return true;
  }
  function reject(current, candidate, reason) {
    candidate.rejected = true;
    bestEffort(() => diagnostic(current, reason));
    if (current.owner === candidate) restore(current, true, reason);
  }
  function ancestry(candidate, final) {
    const visited = new Set(); let parent = final.parentID;
    for (let count = 0; count < 64 && parent; count++) {
      if (parent === candidate.inputMessageID) return true;
      if (visited.has(parent)) return false;
      visited.add(parent);
      const node = candidate.parents.get(parent);
      // The observed client inserts system messages between user and answer.
      if (!node || node.role !== 'system') return false;
      parent = node.parentID;
    }
    return false;
  }
  function publish(current, candidate) {
    if (!live(current) || current.owner !== candidate || candidate.rejected || current.sends !== 1
      || candidate.published || candidate.failurePublished || candidate.completionDisqualified || !candidate.final || !candidate.terminal
      || candidate.terminal <= candidate.final.ordinal) return;
    if (!ancestry(candidate, candidate.final)) { diagnostic(current, 'ancestry_missing'); return; }
    candidate.published = true;
    post({ ...identity(current, 'terminal'), inputMessageID: candidate.inputMessageID,
      conversationID: candidate.conversationID, messageID: candidate.final.id, text: candidate.final.text });
  }
  function publishFailure(current, candidate) {
    if (!live(current) || current.owner !== candidate || candidate.rejected || current.sends !== 1
      || candidate.published || candidate.failurePublished) return;
    const ended = candidate.mainTerminal > 0 && candidate.messageTerminal > 0;
    if (ended && candidate.opaqueAssistant) diagnostic(current, 'terminal_opaque');
    const empty = ended && !candidate.final && candidate.nonemptyAssistants === 0 && !candidate.opaqueAssistant;
    const failed = ended && candidate.providerErrorOrdinal > 0 && candidate.messageTerminal > candidate.providerErrorOrdinal
      && !candidate.final && candidate.nonemptyAssistants === 0 && !candidate.opaqueAssistant;
    if (!failed && !empty) return;
    candidate.failurePublished = true;
    post({ ...identity(current, 'terminal_failure'), inputMessageID: candidate.inputMessageID,
      conversationID: candidate.conversationID, reason: failed ? 'provider_error' : 'empty_stream',
      calls: candidate.ordinal, assistantMessages: candidate.assistantMessages,
      messageTerminalCount: candidate.messageTerminal > 0 ? 1 : 0, mainTerminalCount: candidate.mainTerminal > 0 ? 1 : 0 });
  }
  function singleText(content, maxBytes) {
    if (data(content, 'content_type') !== 'text') return null;
    const parts = data(content, 'parts');
    if (!Array.isArray(parts) || data(parts, 'length') !== 1) return null;
    const text = data(parts, '0');
    return typeof text === 'string' && text.length <= maxBytes && encoder.encode(text).length <= maxBytes ? text : null;
  }
  function observe(current, receiver, payload) {
    if (!live(current) || current.sends !== 1) return;
    if (++current.calls > 256) { restore(current, true, 'call_limit'); return; }
    let candidate = current.instances.get(receiver);
    if (!candidate) {
      if (current.instances.size >= 4) { restore(current, true, 'decoder_limit'); return; }
      candidate = { parents: new Map(), ordinal: 0, rejected: false, inputSeen: false,
        inputMessageID: null, conversationID: null, final: null, terminal: null, published: false,
        failurePublished: false, completionDisqualified: false, providerErrorOrdinal: 0, mainTerminal: 0, messageTerminal: 0,
        assistantMessages: 0, nonemptyAssistants: 0, opaqueAssistant: false };
      current.instances.set(receiver, candidate);
    }
    const ordinal = ++candidate.ordinal, type = data(payload, 'type');
    const conversationID = id(data(payload, 'conversation_id'));
    if (candidate.streamConversationID && conversationID && conversationID !== candidate.streamConversationID) {
      reject(current, candidate, 'owner_conflict'); return;
    }
    if (conversationID) candidate.streamConversationID = conversationID;
    const providerError = data(payload, 'error'), errorCode = data(payload, 'error_code');
    if (providerError !== unknown && providerError != null
        && (typeof providerError === 'object' || typeof providerError === 'string' && providerError.length > 0)
      || typeof errorCode === 'string' && errorCode.length > 0
      || ['error', 'message_error', 'conversation_error'].includes(type)) {
      // An error predating the input cannot be attributed to that input. An
      // error after it is retained while the exact input digest is pending.
      candidate.completionDisqualified = true;
      // The website decoder may prioritize a valid message in an error-bearing
      // envelope. Any such content excludes an empty/error-only conclusion.
      if (data(payload, 'message') != null) candidate.opaqueAssistant = true;
      if (candidate.published) { reject(current, candidate, 'error'); return; }
      if (candidate.inputSeen) candidate.providerErrorOrdinal = ordinal;
      diagnostic(current, 'error'); return;
    }
    if (['cancelled', 'canceled'].includes(type)
      || type === 'main_stream_complete' && data(payload, 'alternate_response_expected') !== false
      || typeof type === 'string' && /_complete(?:d)?$/.test(type)
        && !['main_stream_complete', 'message_stream_complete'].includes(type)) {
      reject(current, candidate, 'error'); return;
    }
    if (candidate.failurePublished) {
      if (type === 'input_message' || data(payload, 'message') != null) reject(current, candidate, 'final_changed');
      return;
    }
    if (type === 'input_message') {
      if (candidate.inputSeen) { reject(current, candidate, 'input_shape'); return; }
      candidate.inputSeen = true;
      const input = data(payload, 'input_message'), inputMessageID = id(data(input, 'id'));
      const text = singleText(data(input, 'content'), 180000);
      if (!conversationID || !inputMessageID || data(data(input, 'author'), 'role') !== 'user'
        || text === null || encoder.encode(text).length !== current.inputUTF8Bytes) { reject(current, candidate, 'input_shape'); return; }
      // Snapshot all identifiers before digest: decoded objects may be reused.
      candidate.inputMessageID = inputMessageID; candidate.conversationID = conversationID;
      crypto.subtle.digest('SHA-256', encoder.encode(text)).then(bytes => {
        if (!live(current)) return;
        const hash = Array.from(new Uint8Array(bytes), value => value.toString(16).padStart(2, '0')).join('');
        if (hash !== current.inputSHA256) { reject(current, candidate, 'input_hash'); return; }
        if (current.owner && current.owner !== candidate) { restore(current, true, 'owner_conflict'); return; }
        if (candidate.rejected) return;
        if (current.serverID && current.serverID !== conversationID) {
          restore(current, true, 'owner_conflict'); return;
        }
        current.owner = candidate; publishFailure(current, candidate); publish(current, candidate);
      }).catch(() => reject(current, candidate, 'observer_exception'));
    }
    const message = data(payload, 'message');
    if (message && message !== unknown) {
      const messageID = id(data(message, 'id')), role = data(data(message, 'author'), 'role');
      const metadata = data(message, 'metadata'), rawParentID = data(metadata, 'parent_id'), parentID = id(rawParentID);
      const status = data(message, 'status'), finishType = data(data(metadata, 'finish_details'), 'type');
      if (data(metadata, 'is_error') === true || data(metadata, 'reasoning_status') === 'reasoning_cancelled'
        || finishType === 'interrupted') { reject(current, candidate, 'error'); return; }
      if (role === 'assistant') {
        if (status != null && status !== 'in_progress' && status !== 'finished_successfully'
          || finishType != null && finishType !== 'stop') { reject(current, candidate, 'final_status'); return; }
        // Decoded messages can precede their status, finish or parent metadata. Missing
        // fields supply no final or ancestry evidence, and are not an error.
        // A previously selected final can never be downgraded this way.
        if (status == null || status === 'finished_successfully' && finishType == null || rawParentID == null) {
          if (candidate.final) { reject(current, candidate, 'final_changed'); return; }
          const previous = messageID ? candidate.parents.get(messageID) : null;
          if (previous && (previous.role !== role || previous.parentID !== parentID)) {
            reject(current, candidate, 'parent_changed'); return;
          }
          candidate.assistantMessages++; candidate.opaqueAssistant = true; return;
        }
      }
      if (messageID) {
        const previous = candidate.parents.get(messageID);
        if (previous && (previous.role !== role || previous.parentID !== parentID)
          || !previous && candidate.parents.size >= 64) {
          reject(current, candidate, previous ? 'parent_changed' : 'parent_limit'); return;
        }
        candidate.parents.set(messageID, { role, parentID });
      }
      if (role === 'assistant') {
        candidate.assistantMessages++;
        const content = singleText(data(message, 'content'), 220000);
        if (content === null || data(message, 'recipient') !== 'all'
          || data(metadata, 'model_dil_v2') != null
          || data(metadata, 'content_references') != null) candidate.opaqueAssistant = true;
        if (content !== null && content.length > 0) candidate.nonemptyAssistants++;
        const text = singleText(data(message, 'content'), 220000);
        const success = messageID && parentID && conversationID
          && data(message, 'status') === 'finished_successfully' && data(message, 'channel') === 'final'
          && data(message, 'recipient') === 'all' && data(message, 'end_turn') === true
          && finishType === 'stop' && text !== null && text.length > 0;
        if (candidate.final && (!success || candidate.final.id !== messageID || candidate.final.text !== text
          || candidate.final.parentID !== parentID)) { reject(current, candidate, 'final_changed'); return; }
        if (success && !candidate.final) candidate.final = { id: messageID, parentID, text, ordinal };
      }
    }
    if (type === 'main_stream_complete') {
      if (!conversationID || !candidate.conversationID || conversationID !== candidate.conversationID) {
        reject(current, candidate, 'owner_conflict'); return;
      }
      candidate.mainTerminal = ordinal;
    }
    if (type === 'message_stream_complete') {
      if (!conversationID || !candidate.conversationID || conversationID !== candidate.conversationID
        || candidate.final && ordinal <= candidate.final.ordinal) { reject(current, candidate, 'terminal_order'); return; }
      candidate.messageTerminal = ordinal;
      candidate.terminal = ordinal;
    }
    publishFailure(current, candidate);
    publish(current, candidate);
  }
  const api = Object.freeze({
    async arm(binding) {
      if (lease || !keys(binding, 'correlationID,durationMs,inputSHA256,inputUTF8Bytes,sequence')
        || !id(data(binding, 'correlationID')) || !Number.isInteger(data(binding, 'sequence'))
        || binding.sequence < 1 || binding.sequence > 16 || typeof data(binding, 'inputSHA256') !== 'string'
        || !/^[a-f0-9]{64}$/.test(data(binding, 'inputSHA256'))
        || !Number.isInteger(data(binding, 'inputUTF8Bytes')) || binding.inputUTF8Bytes < 1 || binding.inputUTF8Bytes > 180000
        || !Number.isInteger(data(binding, 'durationMs')) || binding.durationMs < 1 || binding.durationMs > 600000) return { armed: false };
      const current = { correlationID: binding.correlationID, sequence: binding.sequence, inputSHA256: binding.inputSHA256,
        inputUTF8Bytes: binding.inputUTF8Bytes, deadline: now() + binding.durationMs, stopped: false,
        instances: new Map(), owner: null, calls: 0, diagnosticSent: false, sends: 0, routeKind: 'root', serverID: null, localID: null };
      lease = current;
      try {
        if (!route(current)) {
          bestEffort(() => diagnostic(current, now() >= current.deadline ? 'expired' : 'route_changed')); throw unknown;
        }
        current.armFailureReason = 'runtime_resources_unavailable';
        const runtimeURL = observedRuntimeURL();
        if (!runtimeURL) throw unknown;
        current.armFailureReason = 'runtime_import_failed';
        const runtime = await import(runtimeURL);
        if (!live(current)) return { armed: false };
        current.armFailureReason = 'runtime_identity_changed';
        if (observedRuntimeURL() !== runtimeURL) throw unknown;
        current.armFailureReason = 'runtime_cache_unsupported';
        const found = initializedDecoder(runtime), { target, original } = found;
        const wrapper = function (...args) {
          let result;
          try { result = apply(original.value, this, args); }
          catch (error) { restore(current, true, 'error'); throw error; }
          try { observe(current, this, result); } catch { restore(current, true, 'observer_exception'); }
          return result;
        };
        current.armFailureReason = 'runtime_identity_changed';
        const currentExport = descriptor(found.exports, 'c'), currentMethod = descriptor(target, 'recordCompletion');
        if (!live(current) || observedRuntimeURL() !== runtimeURL
          || data(found.cache, found.key) !== found.cached || data(found.cached, 'exports') !== found.exports
          || !currentExport || currentExport.get !== found.exported.get || currentExport.set !== undefined
          || currentExport.enumerable !== true || currentExport.configurable !== false
          || data(apply(found.exported.get, found.exports, []), 'prototype') !== target
          || !currentMethod || currentMethod.value !== original.value || currentMethod.writable !== true
          || currentMethod.configurable !== true || currentMethod.enumerable !== false) throw unknown;
        define(target, 'recordCompletion', { ...original, value: wrapper });
        current.target = target; current.original = original; current.wrapper = wrapper;
        current.click = event => {
          if (!live(current)) return;
          try {
            if (event.target?.closest?.(stopSelector)) { restore(current, true, 'send_changed'); return; }
            const button = event.target?.closest?.(sendSelector);
            const eligible = node => node?.isConnected && !node.disabled && node.getAttribute('aria-disabled') !== 'true'
              && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden'
              && !node.closest('[data-message-author-role], [inert], [aria-hidden="true"]');
            if (!button || !eligible(button)) return;
            const buttons = [...document.querySelectorAll(sendSelector)].filter(eligible);
            if (buttons.length !== 1 || buttons[0] !== button || ++current.sends !== 1) restore(current, true, 'send_changed');
          } catch { restore(current, true, 'observer_exception'); }
        };
        current.pagehide = () => restore(current, true, 'route_changed');
        current.pathchange = () => { live(current); };
        current.observer = new MutationObserver(current.pathchange);
        current.observer.observe(document, { subtree: true, childList: true, attributes: true });
        document.addEventListener('click', current.click, true);
        window.addEventListener('pagehide', current.pagehide);
        window.addEventListener('popstate', current.pathchange);
        window.addEventListener('hashchange', current.pathchange);
        current.timer = setTimeout(() => restore(current, true, 'expired'), Math.max(0, current.deadline - now()));
        return { armed: true };
      } catch { restore(current, false, current.armFailureReason || 'runtime_unsupported'); return { armed: false }; }
    },
    stop(correlationID) { if (lease && lease.correlationID === correlationID) restore(lease, false); }
  });
  define(window, config.key, { value: api, writable: false, configurable: true, enumerable: false });
})();
