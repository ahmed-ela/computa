// Private controlled attribution, installed separately in the page and isolated
// model worlds only while native has an explicit, finite diagnostic arm.
// It can perturb engine optimization; its timings are not a baseline benchmark.
(() => {
  'use strict';
  const config = __COMPUTA_RENDERER_REGEX_DIAGNOSTIC_CONFIG__;
  const own = (object, key) => {
    if (object === null || !['object', 'function'].includes(typeof object)) return undefined;
    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    return descriptor && Object.prototype.hasOwnProperty.call(descriptor, 'value') ? descriptor.value : undefined;
  };
  const expires = own(config, 'expiresAtUnixSeconds'), now = Date.now() / 1000, originalDocument = document;
  if (typeof expires !== 'number' || !Number.isFinite(expires) || expires <= now || expires > now + 600
    || window !== window.top || location.origin !== 'https://chatgpt.com') return;
  const live = () => document === originalDocument && window === window.top
    && location.origin === 'https://chatgpt.com' && Date.now() / 1000 < expires;
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
      const regexState = { version: 3, expiresAtUnixSeconds: expires, stopReason: 'active', records: [],
        callCount: 0, totalDurationMs: 0, maxDurationMs: 0, saturated: false };
      const projection = records => ({ version: 3, stopReason: regexState.stopReason, records,
        callCount: regexState.callCount, totalDurationMs: regexState.totalDurationMs,
        maxDurationMs: regexState.maxDurationMs, saturated: regexState.saturated });
      const snapshot = () => {
        if (!live()) return null;
        const value = projection(regexState.records.map(record => ({ ...record })));
        return new TextEncoder().encode(JSON.stringify(value)).length <= 2304 ? value : null;
      };
      Object.defineProperty(regexState, 'snapshot', { value: snapshot });
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
              if (!Number.isFinite(duration) || duration < 0 || duration > 600000
                || regexState.callCount >= 1000000 || regexState.totalDurationMs + duration > 1e9) {
                regexState.saturated = true; stopProbe('limit');
              } else {
                regexState.callCount++;
                regexState.totalDurationMs = Math.round((regexState.totalDurationMs + duration) * 1000) / 1000;
                regexState.maxDurationMs = Math.max(regexState.maxDurationMs, Math.round(duration * 1000) / 1000);
              }
              // Fixed count checkpoints attribute common callers without hashing every call.
              const periodic = regexState.callCount > 0 && regexState.callCount % 250000 === 0;
              if (active && Number.isFinite(duration) && duration >= 0 && duration <= 600000
                && (duration >= 100 || periodic)
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
                  const record = { kind: duration >= 100 ? 'slow' : 'periodic', sampleCallCount: regexState.callCount,
                    patternHash: hash.toString(16).padStart(8, '0'), patternLength: pattern.length,
                    inputLength: typeof args[0] === 'string' && args[0].length <= 1e9 ? args[0].length : null,
                    flags: flagText, startEpochMs: epoch, durationMs: duration, publicStack: publicFrames.join('\n') };
                  const next = projection([...regexState.records, record]);
                  if (new TextEncoder().encode(JSON.stringify(next)).length <= 2304) regexState.records.push(record);
                  else stopProbe('limit');
                  if (regexState.records.length >= 4) stopProbe('limit');
                }
              }
              if (regexState.callCount >= 1000000) { regexState.saturated = true; stopProbe('limit'); }
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
})();
