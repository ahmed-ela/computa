// Private, expiry-armed model-view diagnostic. The native owner substitutes the
// config only for an explicitly armed isolated view. No worker or port hooks.
(() => {
  'use strict';
  const config = __COMPUTA_RENDERER_STARTUP_DIAGNOSTIC_CONFIG__;
  const own = (object, key) => {
    if (object === null || !['object', 'function'].includes(typeof object)) return undefined;
    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    return descriptor && Object.prototype.hasOwnProperty.call(descriptor, 'value') ? descriptor.value : undefined;
  };
  const expires = own(config, 'expiresAtUnixSeconds');
  const now = Date.now() / 1000;
  if (typeof expires !== 'number' || !Number.isFinite(expires) || expires <= now || expires > now + 600) return;
  const live = () => Date.now() / 1000 < expires;
  const isRunner = value => {
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && url.hostname === 'cdn.platform.openai.com'
        && !url.port && !url.username && !url.password && !url.search
        && url.pathname === '/deployments/dil/v14/runner.html';
    } catch { return false; }
  };
  try {
    if (window !== window.top) {
      if (!isRunner(location.href)) return;
      const fragment = new URLSearchParams(location.hash.slice(1));
      if (fragment.get('dil-diagnostics') !== '1') {
        fragment.set('dil-diagnostics', '1');
        location.hash = fragment.toString();
      }
      return;
    }
    if (location.origin !== 'https://chatgpt.com'
      || Object.getOwnPropertyDescriptor(window, '__computaRendererStartupDiagnosticV1')) return;
    // Controlled attribution only: wrapping exec can change engine optimization.
    // It is default-off, top-page-only, and never supplies response authority.
    const installSlowRegexProbe = () => {
      try {
        if (Object.getOwnPropertyDescriptor(window, '__computaRendererRegexDiagnosticV1')) return;
        const Constructor = own(window, 'RegExp'), NativeError = own(window, 'Error');
        const prototype = Constructor && Constructor.prototype;
        const descriptor = prototype && Object.getOwnPropertyDescriptor(prototype, 'exec');
        const sourceGetter = prototype && Object.getOwnPropertyDescriptor(prototype, 'source')?.get;
        const performance = window.performance;
        if (!descriptor || typeof descriptor.value !== 'function' || !descriptor.configurable
          || typeof sourceGetter !== 'function' || typeof NativeError !== 'function'
          || typeof performance?.now !== 'function') return;
        const original = descriptor.value, apply = Reflect.apply, define = Object.defineProperty;
        const getDescriptor = Object.getOwnPropertyDescriptor, clock = performance.now.bind(performance);
        const flags = [['d', 'hasIndices'], ['g', 'global'], ['i', 'ignoreCase'], ['m', 'multiline'],
          ['s', 'dotAll'], ['u', 'unicode'], ['v', 'unicodeSets'], ['y', 'sticky']]
          .map(([letter, key]) => [letter, getDescriptor(prototype, key)?.get]);
        const regexState = { version: 1, expiresAtUnixSeconds: expires, stopReason: 'active', records: [] };
        let active = true, recording = false, timer;
        const stopProbe = reason => {
          if (!active) return;
          active = false;
          const current = getDescriptor(prototype, 'exec');
          regexState.stopReason = current?.value === wrappedExec ? reason : 'replaced';
          if (current?.value === wrappedExec) define(prototype, 'exec', descriptor);
          window.removeEventListener('pagehide', pagehide);
          if (timer !== undefined && typeof window.clearTimeout === 'function') window.clearTimeout(timer);
        };
        const pagehide = () => { try { stopProbe('pagehide'); } catch {} };
        function wrappedExec(...args) {
          if (recording || !active) return apply(original, this, args);
          let start, epoch;
          try {
            if (!live()) stopProbe('expired');
            else if (getDescriptor(prototype, 'exec')?.value !== wrappedExec) stopProbe('replaced');
            else { start = clock(); epoch = Date.now(); }
          } catch { /* Always dispatch the original even when diagnostics fail. */ }
          try { return apply(original, this, args); }
          finally {
            if (start !== undefined && active) {
              recording = true;
              try {
                const duration = clock() - start;
                if (Number.isFinite(duration) && duration >= 100 && duration <= 600000
                  && Number.isFinite(epoch) && epoch >= 0 && epoch <= 1e15) {
                  const pattern = apply(sourceGetter, this, []);
                  if (typeof pattern === 'string' && pattern.length <= 16384) {
                    // FNV-1a over UTF-16 code units; only the finite hash survives.
                    let hash = 2166136261;
                    for (let index = 0; index < pattern.length; index++) hash = Math.imul(hash ^ pattern.charCodeAt(index), 16777619) >>> 0;
                    let flagText = '';
                    for (const [letter, getter] of flags) if (typeof getter === 'function' && apply(getter, this, [])) flagText += letter;
                    const publicFrames = [], rawStack = new NativeError().stack;
                    if (typeof rawStack === 'string' && rawStack.length <= 16384) {
                      const publicFrame = /https:\/\/(?:chatgpt\.com\/cdn\/assets\/(?:async\/)?[0-9]{1,6}\.[0-9a-f]{10}\.js|cdn\.platform\.openai\.com\/deployments\/dil\/v[A-Za-z0-9._-]{1,80}\/[A-Za-z0-9._-]{1,128}\.(?:js|html)):[0-9]{1,7}:[0-9]{1,7}(?=[\s)]|$)/g;
                      for (let match; publicFrames.length < 2 && (match = apply(original, publicFrame, [rawStack]));) {
                        if ([...publicFrames, match[0]].join('\n').length > 256) break;
                        publicFrames.push(match[0]);
                      }
                    }
                    const record = { patternHash: hash.toString(16).padStart(8, '0'), patternLength: pattern.length,
                      inputLength: typeof args[0] === 'string' && args[0].length <= 1e9 ? args[0].length : null,
                      flags: flagText, startEpochMs: epoch, durationMs: duration, publicStack: publicFrames.join('\n') };
                    const next = { version: 1, stopReason: 'active', records: [...regexState.records, record] };
                    if (new TextEncoder().encode(JSON.stringify(next)).length <= 2048) regexState.records.push(record);
                    else stopProbe('limit');
                    if (regexState.records.length >= 4) stopProbe('limit');
                  }
                }
              } catch { /* No diagnostic failure may change an exec result or throw. */ }
              finally { recording = false; }
            }
          }
        }
        define(prototype, 'exec', { ...descriptor, value: wrappedExec });
        try {
          window.addEventListener('pagehide', pagehide, { once: true });
          timer = window.setTimeout(() => { try { stopProbe('expired'); } catch {} }, Math.max(1, (expires - now) * 1000));
          define(window, '__computaRendererRegexDiagnosticV1', { value: regexState });
        } catch {
          // Setup must be atomic even if a required lifecycle API is unavailable.
          try { stopProbe('replaced'); } catch {}
        }
      } catch { /* An unavailable primitive or context leaves the probe inert. */ }
    };
    installSlowRegexProbe();
    const realms = new Set(['bootstrap', 'iframe', 'worker']);
    const operations = new Set(['observer_bootstrap', 'module_load', 'module_resource', 'module_entry', 'frame_ready',
      'manager_create', 'worker_create', 'worker_control', 'worker_module', 'harden_worker', 'runner_create',
      'worker_ready', 'snapshot_post', 'snapshot_receive', 'snapshot_forward', 'error', 'visibility', 'event_loop',
      'frame_probe', 'health_probe', 'request_timer', 'recovery', 'quarantine', 'worker_stop', 'runner_dispose']);
    const phases = new Set(['begin', 'returned', 'threw', 'reported_error', 'sent', 'received', 'acknowledged',
      'resolved', 'rejected', 'armed', 'paused', 'rearmed', 'cancelled', 'fired', 'ignored', 'decision']);
    const names = new Set(['Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError', 'URIError',
      'EvalError', 'AggregateError', 'unknown']);
    const reasons = new Set(['bundle_evaluation', 'clear_all', 'control_unavailable', 'csp_violation', 'disposed',
      'document_state', 'execution_finished', 'execution_started', 'overflow', 'restore_transport', 'runner_module_exception',
      'session_restart', 'source_changed', 'stale_generation', 'startup_exhausted', 'startup_retry', 'target_requested',
      'timing_unavailable', 'uncaught_error', 'unhandled_rejection', 'worker_restart', 'runner_module_script_error',
      'other_script_error', 'status_unavailable', 'timing_ambiguous', 'timing_missing']);
    const numeric = ['localTimeMs', 'timeOriginMs', 'elapsedMs', 'budgetMs'];
    const generations = ['workerGeneration', 'sessionGeneration', 'startupAttempt'];
    const state = { version: 1, expiresAtUnixSeconds: expires, frames: [], saturated: false };
    Object.defineProperty(window, '__computaRendererStartupDiagnosticV1', { value: state });
    let received = 0;
    const drop = entry => { entry.dropped = Math.min(1000000, entry.dropped + 1); };
    const stop = () => window.removeEventListener('message', receive);
    const expire = () => { stop(); state.frames.length = 0; };
    const receive = event => {
      try {
        if (!live()) { expire(); return; }
        const data = event.data;
        if (own(data, '__oaiDilFrame') !== true || own(data, 'kind') !== 'diagnostic'
          || own(data, 'protocolVersion') !== 14) return;
        const frames = document.querySelectorAll('iframe');
        if (frames.length > 16) return;
        const matches = [...frames].filter(frame => frame.isConnected && frame.contentWindow === event.source
          && isRunner(frame.src) && frame.sandbox.contains('allow-scripts') && !frame.sandbox.contains('allow-same-origin'));
        if (matches.length !== 1) return;
        if (++received > 1024) {
          state.saturated = true;
          for (const entry of state.frames) drop(entry);
          stop(); return;
        }
        const record = own(data, 'record'), realm = own(record, 'realm'), operation = own(record, 'operation'), phase = own(record, 'phase');
        if (!realms.has(realm) || !operations.has(operation) || !phases.has(phase)) return;
        const sourceReason = own(record, 'reason');
        // These routine queue operations can flood the handoff timeline when a
        // first snapshot resets all pending commands to their ordinary deadlines.
        if (operation === 'request_timer' && ['cancelled', 'rearmed'].includes(phase)
          || operation === 'health_probe' && phase === 'cancelled'
          || operation === 'worker_control' && ['execution_started', 'execution_finished'].includes(sourceReason)) return;
        const projected = { realm, operation, phase };
        for (const key of numeric) {
          const value = own(record, key);
          if (typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e15) projected[key] = value;
        }
        for (const key of generations) {
          const value = own(record, key);
          if (Number.isSafeInteger(value) && value >= 0 && value <= 1000000) projected[key] = value;
        }
        const artifact = own(record, 'artifactId');
        if (typeof artifact === 'string' && /^[A-Za-z0-9_-]{8,64}$/.test(artifact)) projected.artifactId = artifact;
        const name = own(own(record, 'fault'), 'name');
        if (names.has(name)) projected.errorName = name;
        const reason = sourceReason;
        if (reasons.has(reason)) projected.reason = reason;
        let entry = state.frames.find(value => value.iframe === matches[0]);
        if (!entry) {
          if (state.frames.length >= 4) return;
          entry = { events: [], dropped: 0 };
          Object.defineProperty(entry, 'iframe', { value: matches[0] });
          state.frames.push(entry);
        }
        const key = [realm, operation, phase, projected.workerGeneration, projected.sessionGeneration,
          projected.startupAttempt, projected.reason].join('|');
        Object.defineProperty(projected, 'key', { value: key });
        const matching = entry.events.flatMap((value, index) => value.key === key ? [index] : []);
        // The first and latest occurrence retain stage timing without letting
        // repeated snapshots or resource observations evict startup milestones.
        if (matching.length >= 2) { entry.events.splice(matching.at(-1), 1); drop(entry); }
        entry.events.push(projected);
        // At most four frames; each retains only early and recent finite evidence.
        const size = () => new TextEncoder().encode(JSON.stringify({ version: 1, events: entry.events, dropped: entry.dropped })).length;
        while (entry.events.length > 64 || size() > 10240) {
          if (!entry.events.length) break;
          entry.events.splice(entry.events.length > 16 ? 16 : 0, 1); drop(entry);
        }
      } catch { /* Diagnostics cannot affect provider rendering. */ }
    };
    window.addEventListener('message', receive);
    window.addEventListener('pagehide', expire, { once: true });
    window.setTimeout(expire, Math.max(1, (expires - now) * 1000));
  } catch { /* Invalid context or an unavailable diagnostic stays inert. */ }
})();
