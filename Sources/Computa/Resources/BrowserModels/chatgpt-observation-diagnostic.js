// Armed synthetic-benchmark diagnostic only; never inference authority.
// Install AFTER unchanged Probe5, on a fresh document immediately before Send.
function computaInstallObservationDiagnostic(config) {
  const key = '__computaObservationDiagnosticV1';
  const fields = ['schemaVersion', 'nonce', 'expectedSHA256', 'expectedCanonicalSHA256', 'expectedUTF8Bytes'];
  const descriptors = config && typeof config === 'object' ? Object.getOwnPropertyDescriptors(config) : null;
  if (!descriptors || Reflect.ownKeys(descriptors).length !== fields.length
    || !fields.every(name => Object.hasOwn(descriptors, name) && Object.hasOwn(descriptors[name], 'value'))
    || config.schemaVersion !== 1 || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(config.nonce)
    || !/^[0-9a-f]{64}$/.test(config.expectedSHA256) || !/^[0-9a-f]{64}$/.test(config.expectedCanonicalSHA256)
    || !Number.isSafeInteger(config.expectedUTF8Bytes) || config.expectedUTF8Bytes < 1 || config.expectedUTF8Bytes > 180200
    || window !== window.top || location.origin !== 'https://chatgpt.com' || location.pathname !== '/') return null;
  const binding = Object.freeze(Object.fromEntries(fields.map(name => [name, descriptors[name].value])));
  const sameBinding = other => !!other && fields.every(name => other[name] === binding[name]);
  const previous = globalThis[key];
  if (previous) return previous.revision === 1 && sameBinding(previous.binding) ? previous : null;
  const documentAtInstall = document, rootAtInstall = document.documentElement;
  const ownerAtInstall = globalThis.__computaModelOwner;
  const probe = globalThis.__computaMatchedBenchmarkProbeV1;
  if (!rootAtInstall || !probe || typeof probe.snapshot !== 'function' || probe.nonce !== binding.nonce) return null;
  const roots = role => {
    const selector = `[data-message-author-role="${role}"], [data-markdown-text-style="${role}-message"], article[data-turn="${role}"]`
      + (role === 'user' ? ', [data-user-message-bubble]' : '');
    const all = [...document.querySelectorAll(selector)];
    if (all.length > 16) return null;
    return all.filter(node => !all.some(other => other !== node && other.contains(node)));
  };
  const initialUsers = roots('user'), initialAnswers = roots('assistant');
  if (!initialUsers || !initialAnswers || initialUsers.length || initialAnswers.length) return null;
  let initialProbe;
  try { initialProbe = probe.snapshot(); } catch { return null; }
  if (!sameBinding(initialProbe) || initialProbe.invalidReason !== 'none' || initialProbe.sendClickCount !== 0
    || initialProbe.userCount !== 0 || initialProbe.assistantCount !== 0) return null;
  const installedAt = performance.now();
  if (!Number.isFinite(installedAt) || installedAt < 0 || !Number.isSafeInteger(Date.now())) return null;
  const state = {
    schemaVersion: 1, revision: 1, binding, diagnosticOnly: true, modelProofRequiredExternally: true,
    installedUnixMs: Date.now(), sendUnixMs: null, ownClickAfterInstallMs: null,
    invalidReason: 'none', endedReason: 'none', stopped: false, expired: false,
    sourceProbeSendObserved: false, payloadBindingVerified: false, sourceProbeCurrentComplete: false,
    clickIsTrusted: null, userCount: 0, assistantCount: 0,
    firstModernBodyAfterSendMs: null, firstRawTextAfterSendMs: null, firstRawTextUTF16Length: null,
    firstRawTextCountClamped: false, callbacks: 0, mutationCallbacks: 0, mutationRecords: 0,
    timerIntervals: [], rafEarlyIntervals: [], rafBodyIntervals: [], visibilityFocus: [],
    resourceSummary: null,
    syncWork: Array.from({ length: 5 }, () => [0, 0, 0, false]), bodyTimerIntervals: []
  };
  let stopped = false, sendAt = null, userRoot = null, assistantRoot = null, modernBody = null;
  let observer = null, expiryTimer = null, nestedTimer = null, earlyFrame = null, bodyFrame = null;
  let lastTimerAt = null, lastEarlyAt = null, lastBodyAt = null;
  let lateBodyTimer = null, lastLateBodyAt = null, lateBodyTicks = 0;
  const rounded = n => Number.isFinite(n) && n >= 0 && n <= 15000 ? Math.round(n * 1000) / 1000 : null;
  const now = () => performance.now();
  const elapsed = origin => rounded(now() - origin);
  const ownTime = () => sendAt === null ? null : elapsed(sendAt);
  const fixedReason = value => ['none', 'explicit_stop', 'deadline', 'pagehide', 'invalid', 'callback_budget', 'record_budget'].includes(value) ? value : 'invalid';
  const collectResources = () => {
    if (state.resourceSummary !== null) return;
    const result = { scannedCount: 0, scanTruncated: false, selectedCount: 0, selectedTruncated: false, available: false, entries: [] };
    state.resourceSummary = result;
    if (sendAt === null || state.invalidReason !== 'none'
      || document !== documentAtInstall || location.origin !== 'https://chatgpt.com') return;
    try {
      const all = performance.getEntriesByType('resource'), end = Math.min(now(), sendAt + 15000);
      result.available = true; result.scanTruncated = all.length > 256;
      const recent = all.slice(-256); result.scannedCount = recent.length;
      const selected = [];
      for (const item of recent) {
        if (item.initiatorType !== 'script' || !Number.isFinite(item.startTime) || item.startTime < sendAt - 15000
          || !Number.isFinite(item.responseEnd) || item.responseEnd < Math.max(item.startTime, sendAt) || item.responseEnd > end) continue;
        let sameOrigin = false;
        try { sameOrigin = new URL(item.name, location.origin).origin === 'https://chatgpt.com'; } catch { continue; }
        if (!sameOrigin) continue;
        const ms = value => Number.isFinite(value) && value >= -15000 && value <= 15000 ? Math.round(value * 1000) / 1000 : null;
        const nonnegativeMs = value => Number.isFinite(value) && value >= 0 && value <= 15000 ? Math.round(value * 1000) / 1000 : null;
        const bytes = value => Number.isSafeInteger(value) && value >= 0 && value <= 1073741824 ? value : null;
        selected.push([ms(item.startTime - sendAt), nonnegativeMs(item.responseEnd - sendAt), nonnegativeMs(item.duration),
          bytes(item.encodedBodySize), bytes(item.decodedBodySize), bytes(item.transferSize)]);
      }
      result.selectedCount = Math.min(selected.length, 256); result.selectedTruncated = selected.length > 8;
      result.entries = selected.slice(-8);
    } catch { result.available = false; }
  };
  const focusSnapshot = phase => {
    if (state.visibilityFocus.length >= 4) return;
    const visibility = ['visible', 'hidden', 'prerender'].includes(document.visibilityState) ? document.visibilityState : 'unknown';
    let focus = null;
    try { const value = document.hasFocus(); if (typeof value === 'boolean') focus = value; } catch { /* finite unknown */ }
    state.visibilityFocus.push([phase, elapsed(installedAt), visibility, focus]);
  };
  const end = reason => {
    if (stopped) return;
    stopped = true; state.stopped = true; state.endedReason = fixedReason(reason); state.expired = reason === 'deadline';
    observer?.disconnect();
    documentAtInstall.removeEventListener('click', onClick, true);
    window.removeEventListener('pagehide', onPageHide, true);
    if (expiryTimer !== null) clearTimeout(expiryTimer);
    if (nestedTimer !== null) clearTimeout(nestedTimer);
    if (earlyFrame !== null) cancelAnimationFrame(earlyFrame);
    if (bodyFrame !== null) cancelAnimationFrame(bodyFrame);
    if (lateBodyTimer !== null) clearTimeout(lateBodyTimer);
    if (sendAt !== null && elapsed(sendAt) !== null) focusSnapshot('end');
    if (reason !== 'explicit_stop' && reason !== 'deadline') state.payloadBindingVerified = false;
    collectResources();
  };
  const invalid = reason => { if (state.invalidReason === 'none') state.invalidReason = reason; state.payloadBindingVerified = false; end('invalid'); };
  const clockAndLease = (allowFrozen = false) => {
    if (state.invalidReason !== 'none' || (stopped && (!allowFrozen
      || !['deadline', 'explicit_stop'].includes(state.endedReason)))) return false;
    if (document !== documentAtInstall || document.documentElement !== rootAtInstall
      || window !== window.top || location.origin !== 'https://chatgpt.com') { invalid('document_or_origin_changed'); return false; }
    if (globalThis.__computaModelOwner !== ownerAtInstall) { invalid('native_owner_changed'); return false; }
    if (!allowFrozen && elapsed(sendAt === null ? installedAt : sendAt) === null) { end('deadline'); return false; }
    if ((userRoot && !userRoot.isConnected) || (assistantRoot && !assistantRoot.isConnected) || (modernBody && !modernBody.isConnected)) {
      invalid('physical_root_removed'); return false;
    }
    return true;
  };
  const readProbe = (allowFrozen = false) => {
    if (!clockAndLease(allowFrozen)) return null;
    if (globalThis.__computaMatchedBenchmarkProbeV1 !== probe) { invalid('source_probe_changed'); return null; }
    let value;
    try { value = probe.snapshot(); } catch { invalid('source_probe_unreadable'); return null; }
    if (!sameBinding(value) || value.invalidReason !== 'none'
      || ![0, 1].includes(value.sendClickCount) || ![0, 1].includes(value.userCount) || ![0, 1].includes(value.assistantCount)
      || (sendAt === null ? value.sendClickCount !== 0 : value.sendClickCount !== 1)
      || value.editorMatchesExpected === false) { invalid('source_probe_invalid'); return null; }
    state.sourceProbeCurrentComplete = value.currentComplete === true;
    state.payloadBindingVerified = sendAt !== null && value.sendClickCount === 1 && value.userCount === 1
      && value.assistantCount === 1 && value.payloadMatched === true && value.editorMatchesExpected === true
      && value.userMatchesExpected === true && value.editorSHA256 === binding.expectedSHA256
      && value.editorCanonicalSHA256 === binding.expectedCanonicalSHA256 && value.userSHA256 === binding.expectedCanonicalSHA256
      && value.editorUTF8Bytes === binding.expectedUTF8Bytes && value.userUTF8Bytes === binding.expectedUTF8Bytes;
    return value;
  };
  const callback = () => {
    if (!clockAndLease()) return false;
    if (state.callbacks >= 256) { end('callback_budget'); return false; }
    state.callbacks += 1; return true;
  };
  const scheduleTimer = () => {
    if (stopped || state.timerIntervals.length >= 12) return;
    nestedTimer = setTimeout(() => {
      nestedTimer = null; if (!callback() || !readProbe()) return;
      const t = now(), interval = rounded(t - lastTimerAt), after = rounded(t - sendAt);
      if (interval === null || after === null) { end('deadline'); return; }
      state.timerIntervals.push([after, interval]); lastTimerAt = t; scheduleTimer();
    }, 0);
  };
  const scheduleFrame = phase => {
    const entries = phase === 'early' ? state.rafEarlyIntervals : state.rafBodyIntervals;
    if (stopped || entries.length >= 8) return;
    const id = requestAnimationFrame(() => {
      if (phase === 'early') earlyFrame = null; else bodyFrame = null;
      if (!callback() || !readProbe()) return;
      const t = now(), previous = phase === 'early' ? lastEarlyAt : lastBodyAt;
      const interval = rounded(t - previous), after = rounded(t - sendAt);
      if (interval === null || after === null) { end('deadline'); return; }
      entries.push([after, interval]);
      if (phase === 'early') lastEarlyAt = t; else lastBodyAt = t;
      scheduleFrame(phase);
    });
    if (phase === 'early') earlyFrame = id; else bodyFrame = id;
  };
  const inspectRawBody = () => {
    if (!readProbe() || sendAt === null) return;
    const users = roots('user'), answers = roots('assistant');
    if (!users || !answers || users.length > 1 || answers.length > 1) { invalid('physical_count_invalid'); return; }
    state.userCount = users.length; state.assistantCount = answers.length;
    if ((userRoot && users[0] !== userRoot) || (assistantRoot && answers[0] !== assistantRoot)) { invalid('physical_root_changed'); return; }
    if (users.length) userRoot ||= users[0];
    if (answers.length) assistantRoot ||= answers[0];
    const bodies = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')];
    if (bodies.length > 1 || (bodies.length && (!assistantRoot || !assistantRoot.contains(bodies[0])))) { invalid('modern_body_count_or_scope'); return; }
    if (!bodies.length) { if (modernBody) invalid('modern_body_removed'); return; }
    if (modernBody && modernBody !== bodies[0]) { invalid('modern_body_changed'); return; }
    if (!modernBody) {
      modernBody = bodies[0]; state.firstModernBodyAfterSendMs = ownTime(); focusSnapshot('body');
      lastBodyAt = now(); scheduleFrame('body');
      lastLateBodyAt = lastBodyAt; scheduleLateBodyTimer();
    }
    // No innerText, geometry, style, visibility/layout query or response text export.
    const raw = modernBody.textContent || '';
    if (state.firstRawTextAfterSendMs === null && /\S/.test(raw.slice(0, 220001))) {
      state.firstRawTextAfterSendMs = ownTime(); state.firstRawTextUTF16Length = Math.min(raw.length, 220001);
      state.firstRawTextCountClamped = raw.length > 220001;
    }
  };
  // Finite late cadence only: no DOM, probe, snapshot, guard or layout read.
  function scheduleLateBodyTimer() {
    lateBodyTimer = setTimeout(() => {
      lateBodyTimer = null;
      try {
        if (stopped || sendAt === null || state.invalidReason !== 'none' || state.callbacks >= 256) return;
        const stamp = now(), after = rounded(stamp - sendAt), interval = rounded(stamp - lastLateBodyAt);
        if (after === null || interval === null) return;
        state.callbacks++; lateBodyTicks++; state.bodyTimerIntervals.push([after, interval]); lastLateBodyAt = stamp;
        if (lateBodyTicks < 8) scheduleLateBodyTimer();
      } catch { /* A failed diagnostic clock cannot affect the page. */ }
    }, 250);
  }
  function onClick(event) {
    if (!callback()) return;
    const target = event.target instanceof Element ? event.target.closest('button[data-testid="send-button"],'
      + 'button[aria-label="Send prompt"],button[aria-label="Send message"],button[aria-label="Send"]') : null;
    if (!target) return;
    if (sendAt !== null) { invalid('multiple_send_clicks'); return; }
    const users = roots('user'), answers = roots('assistant');
    if (!users || !answers || users.length || answers.length) { invalid('not_fresh_at_send'); return; }
    // Probe5 was installed first; its capture listener must have observed this Send.
    let value;
    try { value = probe.snapshot(); } catch { invalid('source_probe_unreadable'); return; }
    if (globalThis.__computaMatchedBenchmarkProbeV1 !== probe || !sameBinding(value)
      || value.invalidReason !== 'none' || value.sendClickCount !== 1 || value.userCount !== 0 || value.assistantCount !== 0
      || !Number.isSafeInteger(value.sendUnixMs) || value.editorMatchesExpected === false) { invalid('source_send_not_observed'); return; }
    sendAt = now(); state.sendUnixMs = value.sendUnixMs; state.ownClickAfterInstallMs = elapsed(installedAt);
    state.sourceProbeSendObserved = true; state.clickIsTrusted = event.isTrusted === true;
    focusSnapshot('send');
    observer = new MutationObserver(onMutations);
    observer.observe(documentAtInstall, { subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ['data-message-author-role', 'data-markdown-text-style', 'data-user-message-bubble'] });
    expiryTimer = setTimeout(() => end('deadline'), 15000);
    lastTimerAt = sendAt; lastEarlyAt = sendAt; scheduleTimer(); scheduleFrame('early');
    inspectRawBody();
  }
  function onPageHide() { if (callback()) end('pagehide'); }
  focusSnapshot('install');
  function onMutations(records) {
    if (!callback()) return;
    if (state.mutationCallbacks >= 128) { end('callback_budget'); return; }
    state.mutationCallbacks += 1;
    state.mutationRecords = Math.min(1025, state.mutationRecords + records.length);
    if (state.mutationRecords > 1024) { end('record_budget'); return; }
    for (const record of records) for (const removed of record.removedNodes) {
      if ([userRoot, assistantRoot, modernBody].some(node => node && (removed === node || removed.contains?.(node)))) {
        invalid('physical_lease_removed'); return;
      }
    }
    if (sendAt === null) {
      const users = roots('user'), answers = roots('assistant');
      if (!users || !answers || users.length || answers.length) invalid('not_fresh_before_send');
    } else inspectRawBody();
  }
  document.addEventListener('click', onClick, true);
  window.addEventListener('pagehide', onPageHide, true);
  const snapshot = () => {
    if (!stopped) readProbe();
    if (stopped && sendAt !== null && readProbe(true)) {
      // Only current lease/binding status may refresh after freeze; no text,
      // timing, resource sample, observer, frame or timeout is resumed.
      const users = roots('user'), answers = roots('assistant');
      if (!users || !answers || users.length !== 1 || answers.length !== 1
        || users[0] !== userRoot || answers[0] !== assistantRoot) invalid('physical_root_changed');
    }
    return JSON.parse(JSON.stringify(state));
  };
  // Called only beside existing synchronous work; no probe/layout/guard call.
  const syncNow = () => {
    try {
      if (stopped || sendAt === null || state.invalidReason !== 'none' || document !== documentAtInstall
        || document.documentElement !== rootAtInstall || globalThis.__computaModelOwner !== ownerAtInstall
        || globalThis.__computaMatchedBenchmarkProbeV1 !== probe) return null;
      const value = now(); return Number.isFinite(value) && value >= sendAt && value - sendAt <= 15000 ? value : null;
    } catch { return null; }
  };
  const recordSync = (index, started) => {
    if (stopped || sendAt === null || !Number.isInteger(index) || index < 0 || index >= 5
      || !Number.isFinite(started) || started < sendAt) return;
    const row = state.syncWork[index], ended = syncNow(), duration = ended === null ? null : rounded(ended - started);
    if (duration === null || row[0] >= 256 || rounded(row[1] + duration) === null) { row[3] = true; return; }
    row[0]++; row[1] = rounded(row[1] + duration); row[2] = Math.max(row[2], duration);
  };
  const api = Object.freeze({ revision: 1, binding, snapshot, syncNow, recordSync, stop() { if (!stopped) readProbe(); end('explicit_stop'); return snapshot(); } });
  Object.defineProperty(globalThis, key, { value: api, writable: false, configurable: false, enumerable: false });
  return api;
}
