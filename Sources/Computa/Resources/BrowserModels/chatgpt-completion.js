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
  const prototypeOf = Object.getPrototypeOf, functionSource = Function.prototype.toString;
  const unknown = Symbol('unknown'), initialDocument = document;
  const now = performance.now.bind(performance), encoder = new TextEncoder();
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const completionSource = 'recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}';
  const sendSelector = 'button[data-testid="send-button"], button[aria-label="Send prompt"], button[aria-label="Send message"], button[aria-label="Send"]';
  const stopSelector = 'button[data-testid="stop-button"], button[aria-label="Stop streaming"], button[aria-label="Stop generating"], button[aria-label="Stop"]';
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
  function restore(current, notify) {
    if (lease !== current || current.stopped) return;
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
    if (!route(current)) { restore(current, true); return false; }
    if (current.target) {
      const present = descriptor(current.target, 'recordCompletion');
      if (!present || present.value !== current.wrapper || present.writable !== true
        || present.configurable !== true || present.enumerable !== false) { restore(current, true); return false; }
    }
    return true;
  }
  function reject(current, candidate) {
    candidate.rejected = true;
    if (current.owner === candidate) restore(current, true);
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
      || candidate.published || !candidate.final || !candidate.terminal
      || candidate.terminal <= candidate.final.ordinal || !ancestry(candidate, candidate.final)) return;
    candidate.published = true;
    post({ ...identity(current, 'terminal'), inputMessageID: candidate.inputMessageID,
      conversationID: candidate.conversationID, messageID: candidate.final.id, text: candidate.final.text });
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
    if (++current.calls > 256) { restore(current, true); return; }
    let candidate = current.instances.get(receiver);
    if (!candidate) {
      if (current.instances.size >= 4) { restore(current, true); return; }
      candidate = { parents: new Map(), ordinal: 0, rejected: false, inputSeen: false,
        inputMessageID: null, conversationID: null, final: null, terminal: null, published: false };
      current.instances.set(receiver, candidate);
    }
    const ordinal = ++candidate.ordinal, type = data(payload, 'type');
    if (data(payload, 'error') != null || data(payload, 'error_code') != null
      || ['error', 'message_error', 'conversation_error', 'cancelled', 'canceled'].includes(type)
      || type === 'main_stream_complete' && data(payload, 'alternate_response_expected') !== false
      || typeof type === 'string' && /_complete(?:d)?$/.test(type)
        && !['main_stream_complete', 'message_stream_complete'].includes(type)) {
      reject(current, candidate); return;
    }
    const conversationID = id(data(payload, 'conversation_id'));
    if (candidate.streamConversationID && conversationID && conversationID !== candidate.streamConversationID) {
      reject(current, candidate); return;
    }
    if (conversationID) candidate.streamConversationID = conversationID;
    if (type === 'input_message') {
      if (candidate.inputSeen) { reject(current, candidate); return; }
      candidate.inputSeen = true;
      const input = data(payload, 'input_message'), inputMessageID = id(data(input, 'id'));
      const text = singleText(data(input, 'content'), 180000);
      if (!conversationID || !inputMessageID || data(data(input, 'author'), 'role') !== 'user'
        || text === null || encoder.encode(text).length !== current.inputUTF8Bytes) { reject(current, candidate); return; }
      // Snapshot all identifiers before digest: decoded objects may be reused.
      candidate.inputMessageID = inputMessageID; candidate.conversationID = conversationID;
      crypto.subtle.digest('SHA-256', encoder.encode(text)).then(bytes => {
        if (!live(current)) return;
        const hash = Array.from(new Uint8Array(bytes), value => value.toString(16).padStart(2, '0')).join('');
        if (hash !== current.inputSHA256) { reject(current, candidate); return; }
        if (current.owner && current.owner !== candidate) { restore(current, true); return; }
        if (candidate.rejected) return;
        if (current.serverID && current.serverID !== conversationID) {
          restore(current, true); return;
        }
        current.owner = candidate; publish(current, candidate);
      }).catch(() => reject(current, candidate));
    }
    const message = data(payload, 'message');
    if (message && message !== unknown) {
      const messageID = id(data(message, 'id')), role = data(data(message, 'author'), 'role');
      const metadata = data(message, 'metadata'), parentID = id(data(metadata, 'parent_id'));
      if (data(metadata, 'is_error') === true || data(metadata, 'reasoning_status') === 'reasoning_cancelled'
        || data(data(metadata, 'finish_details'), 'type') === 'interrupted') { reject(current, candidate); return; }
      if (messageID) {
        const previous = candidate.parents.get(messageID);
        if (previous && (previous.role !== role || previous.parentID !== parentID)
          || !previous && candidate.parents.size >= 64) { reject(current, candidate); return; }
        candidate.parents.set(messageID, { role, parentID });
      }
      if (role === 'assistant') {
        const status = data(message, 'status');
        const finishType = data(data(metadata, 'finish_details'), 'type');
        if (status !== 'in_progress' && status !== 'finished_successfully'
          || typeof finishType === 'string' && finishType !== 'stop'
          || status === 'finished_successfully' && finishType !== 'stop') { reject(current, candidate); return; }
        const text = singleText(data(message, 'content'), 220000);
        const success = messageID && parentID && conversationID
          && data(message, 'status') === 'finished_successfully' && data(message, 'channel') === 'final'
          && data(message, 'recipient') === 'all' && data(message, 'end_turn') === true
          && finishType === 'stop' && text !== null && text.length > 0;
        if (candidate.final && (!success || candidate.final.id !== messageID || candidate.final.text !== text
          || candidate.final.parentID !== parentID)) { reject(current, candidate); return; }
        if (success && !candidate.final) candidate.final = { id: messageID, parentID, text, ordinal };
      }
    }
    if (type === 'message_stream_complete') {
      if (!conversationID || !candidate.conversationID || conversationID !== candidate.conversationID
        || !candidate.final || ordinal <= candidate.final.ordinal) { reject(current, candidate); return; }
      candidate.terminal = ordinal;
    }
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
        instances: new Map(), owner: null, calls: 0, sends: 0, routeKind: 'root', serverID: null, localID: null };
      lease = current;
      try {
        if (!route(current)) throw unknown;
        // This is an observed public runtime and an already-initialized cache.
        // Importing it must never initialize dd or call a module factory.
        const runtime = await import('https://chatgpt.com/cdn/assets/633146.fa01f470fd.js');
        if (!live(current)) return { armed: false };
        const require = data(runtime, '__webpack_require__'), cached = data(data(require, 'c'), 'dd');
        const exports = data(cached, 'exports'), exported = exports && exports !== unknown ? descriptor(exports, 'c') : null;
        if (!exported || typeof exported.get !== 'function' || exported.set !== undefined
          || exported.enumerable !== true || exported.configurable !== false
          || apply(functionSource, exported.get, []) !== '()=>O') throw unknown;
        const Decoder = apply(exported.get, exports, []), target = data(Decoder, 'prototype');
        const original = target && target !== unknown ? descriptor(target, 'recordCompletion') : null;
        if (!original || typeof original.value !== 'function' || original.writable !== true
          || original.configurable !== true || original.enumerable !== false
          || data(original.value, 'name') !== 'recordCompletion' || data(original.value, 'length') !== 1
          || apply(functionSource, original.value, []) !== completionSource) throw unknown;
        const wrapper = function (...args) {
          let result;
          try { result = apply(original.value, this, args); }
          catch (error) { restore(current, true); throw error; }
          try { observe(current, this, result); } catch { restore(current, true); }
          return result;
        };
        if (!live(current) || descriptor(target, 'recordCompletion')?.value !== original.value) throw unknown;
        define(target, 'recordCompletion', { ...original, value: wrapper });
        current.target = target; current.original = original; current.wrapper = wrapper;
        current.click = event => {
          if (!live(current)) return;
          try {
            if (event.target?.closest?.(stopSelector)) { restore(current, true); return; }
            const button = event.target?.closest?.(sendSelector);
            const eligible = node => node?.isConnected && !node.disabled && node.getAttribute('aria-disabled') !== 'true'
              && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden'
              && !node.closest('[data-message-author-role], [inert], [aria-hidden="true"]');
            if (!button || !eligible(button)) return;
            const buttons = [...document.querySelectorAll(sendSelector)].filter(eligible);
            if (buttons.length !== 1 || buttons[0] !== button || ++current.sends !== 1) restore(current, true);
          } catch { restore(current, true); }
        };
        current.pagehide = () => restore(current, true);
        current.pathchange = () => { live(current); };
        current.observer = new MutationObserver(current.pathchange);
        current.observer.observe(document, { subtree: true, childList: true, attributes: true });
        document.addEventListener('click', current.click, true);
        window.addEventListener('pagehide', current.pagehide);
        window.addEventListener('popstate', current.pathchange);
        window.addEventListener('hashchange', current.pathchange);
        current.timer = setTimeout(() => restore(current, true), Math.max(0, current.deadline - now()));
        return { armed: true };
      } catch { restore(current, false); return { armed: false }; }
    },
    stop(correlationID) { if (lease && lease.correlationID === correlationID) restore(lease, false); }
  });
  define(window, config.key, { value: api, writable: false, configurable: true, enumerable: false });
})();
