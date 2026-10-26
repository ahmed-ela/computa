// Private, expiry-armed synthetic diagnostic. Evaluate once in WKContentWorld.page only
// after native validates the current owned renderer failure and private arm.
// input: { expectedURL, expectedResponseCount, expectedUserCount }.
// No site functions, runner methods, accessors, writes, hooks, or network calls.
return (() => {
  const unavailable = reason => ({ version: 1, status: 'unavailable', reason });
  const own = (object, key) => {
    if (object === null || !['object', 'function'].includes(typeof object)) return undefined;
    const d = Object.getOwnPropertyDescriptor(object, key);
    return d && Object.prototype.hasOwnProperty.call(d, 'value') ? d.value : undefined;
  };
  const stages = new Set(['host_error', 'invalid_payload', 'payload_too_large', 'runtime_error', 'callback_error',
    'frame_load_error', 'frame_timeout', 'protocol_mismatch', 'worker_start_error', 'worker_timeout', 'messenger_error']);
  const boolean = value => typeof value === 'boolean' ? value : null;
  const finiteStage = value => stages.has(value) ? value : value == null ? null : 'other';
  const label = 'This response couldn’t load';
  const startupProjection = iframe => {
    try {
      const state = own(window, '__computaRendererStartupDiagnosticV1'), expiry = own(state, 'expiresAtUnixSeconds');
      const frames = own(state, 'frames'), now = Date.now() / 1000;
      if (own(state, 'version') !== 1 || typeof expiry !== 'number' || !Number.isFinite(expiry)
        || expiry <= now || expiry > now + 600 || !Array.isArray(frames) || frames.length > 4 || !iframe) return undefined;
      let entry;
      for (let index = 0; index < frames.length; index++) {
        const value = own(frames, String(index));
        if (own(value, 'iframe') !== iframe) continue;
        if (entry) return undefined;
        entry = value;
      }
      // An armed collector with no records from this frame is useful negative evidence.
      if (!entry && (frames.length === 4 || own(state, 'saturated') === true)) return undefined;
      const events = entry ? own(entry, 'events') : [], dropped = entry ? own(entry, 'dropped') : 0;
      if (!Array.isArray(events) || events.length > 64 || !Number.isSafeInteger(dropped)
        || dropped < 0 || dropped > 1000000) return undefined;
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
      const projected = [];
      for (let index = 0; index < events.length; index++) {
        const event = own(events, String(index)), realm = own(event, 'realm'), operation = own(event, 'operation'), phase = own(event, 'phase');
        if (!realms.has(realm) || !operations.has(operation) || !phases.has(phase)) return undefined;
        const result = { realm, operation, phase };
        for (const key of [...numeric, ...generations]) {
          const value = own(event, key);
          if (value === undefined) continue;
          if (typeof value !== 'number' || !Number.isFinite(value) || value < 0
            || (generations.includes(key) ? !Number.isSafeInteger(value) || value > 1000000 : value > 1e15)) return undefined;
          result[key] = value;
        }
        const artifact = own(event, 'artifactId'), name = own(event, 'errorName');
        if (artifact !== undefined) {
          if (typeof artifact !== 'string' || !/^[A-Za-z0-9_-]{8,64}$/.test(artifact)) return undefined;
          result.artifactId = artifact;
        }
        if (name !== undefined) { if (!names.has(name)) return undefined; result.errorName = name; }
        const reason = own(event, 'reason');
        if (reason !== undefined) { if (!reasons.has(reason)) return undefined; result.reason = reason; }
        projected.push(result);
      }
      const result = { version: 1, events: projected, dropped };
      return new TextEncoder().encode(JSON.stringify(result)).length <= 10240 ? result : undefined;
    } catch { return undefined; }
  };
  try {
    if (!input || Object.keys(input).sort().join(',') !== 'expectedResponseCount,expectedURL,expectedUserCount'
      || typeof input.expectedURL !== 'string' || input.expectedURL.length > 2048
      || document.URL !== input.expectedURL || location.origin !== 'https://chatgpt.com' || window !== window.top
      || !Number.isInteger(input.expectedResponseCount) || input.expectedResponseCount < 1 || input.expectedResponseCount > 64
      || !Number.isInteger(input.expectedUserCount) || input.expectedUserCount < 1 || input.expectedUserCount > 16)
      return unavailable('context_mismatch');
    const visible = node => {
      if (!node?.isConnected || node.nodeType !== 1 || !node.getClientRects().length
        || node.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
      const style = getComputedStyle(node);
      return style.display !== 'none' && style.visibility === 'visible' && Number(style.opacity) > 0;
    };
    const roots = role => {
      const nodes = [...document.querySelectorAll(`[data-message-author-role="${role}"], [data-markdown-text-style="${role}-message"], article[data-turn="${role}"]`
        + (role === 'user' ? ', [data-user-message-bubble]' : ''))];
      if (nodes.length > 256) return [];
      return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
    };
    const assistants = roots('assistant'), users = roots('user'), assistant = assistants.at(-1);
    if (assistants.length !== input.expectedResponseCount || users.length !== input.expectedUserCount || !visible(assistant))
      return unavailable('message_scope_mismatch');
    if ([...document.querySelectorAll('button[data-testid="stop-button"], button[aria-label="Stop streaming"], button[aria-label="Stop generating"], button[aria-label="Stop"]')].some(visible))
      return unavailable('response_busy');
    const body = assistant.getAttribute('data-markdown-text-style') === 'assistant-message' ? assistant
      : assistant.querySelector('[data-markdown-text-style="assistant-message"]')
        || assistant.querySelector('.markdown') || assistant.querySelector('[data-message-author-role="assistant"]')
        || (assistant.getAttribute('data-message-author-role') === 'assistant' ? assistant : null);
    if (!visible(body) || body.closest('pre,code,blockquote,.markdown') || body.textContent !== label)
      return unavailable('failure_body_mismatch');
    const divs = [...body.querySelectorAll('div')];
    if (divs.length > 64) return unavailable('dom_budget');
    const has = (node, prefix) => [...node.classList].some(value => value.startsWith(prefix)
      && /^[A-Za-z0-9_-]{1,64}$/.test(value.slice(prefix.length)));
    const dils = [body, ...divs].filter(node => has(node, 'DilRenderer-') && has(node, 'DilResponseRoot-'));
    if (dils.length !== 1) return unavailable('failure_shape_mismatch');
    const dil = dils[0], portal = dil.parentElement, leaf = dil.firstElementChild;
    if (!portal || !body.contains(portal) || !has(portal, 'PortalBoundary-') || !has(portal, 'Renderer-')
      || !visible(dil) || !visible(portal) || !visible(leaf) || leaf.tagName !== 'DIV'
      || dil.childElementCount !== 1 || leaf.classList.length !== 0 || leaf.childElementCount !== 0
      || leaf.childNodes.length !== 1 || leaf.childNodes[0].nodeType !== 3 || leaf.textContent !== label)
      return unavailable('failure_shape_mismatch');
    let copy = null;
    for (let scope = body, depth = 0; scope && depth < 12; scope = scope.parentElement, depth++) {
      if (['MAIN', 'BODY', 'HTML'].includes(scope.tagName)) break;
      const enclosedAssistants = assistants.filter(node => scope.contains(node) || node.contains(scope));
      const enclosedUsers = users.filter(node => scope.contains(node));
      if (enclosedAssistants.length !== 1 || enclosedAssistants[0] !== assistant
        || enclosedUsers.length > 1 || enclosedUsers.length === 1 && enclosedUsers[0] !== users.at(-1)) break;
      const buttons = [...scope.querySelectorAll('button[aria-label="Copy"]')];
      if (buttons.length > 16) return unavailable('copy_budget');
      const enabled = buttons.filter(node => !dil.contains(node) && !users.some(user => user.contains(node))
        && !node.closest('pre,code,blockquote,.markdown') && visible(node)
        && !node.disabled && node.getAttribute('aria-disabled') !== 'true');
      if (enabled.length > 1) return unavailable('copy_ambiguous');
      if (enabled.length === 1) { copy = enabled[0]; break; }
    }
    if (!copy) return unavailable('copy_missing');
    const properties = Object.getOwnPropertyNames(leaf);
    if (properties.length > 64) return unavailable('dom_property_budget');
    const fiberKeys = properties.filter(key => /^__reactFiber\$[A-Za-z0-9_$]{1,64}$/.test(key));
    if (fiberKeys.length !== 1) return unavailable('fiber_missing_or_ambiguous');
    let fiber = own(leaf, fiberKeys[0]), found = null;
    const seen = new Set();
    for (let depth = 0; fiber && depth < 16; depth++, fiber = own(fiber, 'return')) {
      if (seen.has(fiber)) return unavailable('fiber_cycle');
      seen.add(fiber);
      const props = own(fiber, 'memoizedProps'), runner = own(props, 'runner');
      const snapshot = own(runner, 'snapshot'), lifecycle = own(runner, 'lifecycleSnapshot');
      if (!runner || !snapshot || !lifecycle || own(snapshot, 'tree') !== null) continue;
      const version = own(snapshot, 'version'), error = own(snapshot, 'error');
      if (!Number.isSafeInteger(version) || version < 1 || version > 1000000 || !error || typeof error !== 'object') continue;
      if (typeof own(props, 'onSnapshot') !== 'function' || own(props, 'errorFallback') === undefined) continue;
      let hook = own(fiber, 'memoizedState'), matchedHook = false;
      const seenHooks = new Set();
      for (let count = 0; hook && count < 24; count++, hook = own(hook, 'next')) {
        if (seenHooks.has(hook)) break;
        seenHooks.add(hook);
        if (own(hook, 'memoizedState') === snapshot) { matchedHook = true; break; }
      }
      if (!matchedHook) continue;
      if (found) return unavailable('runner_ambiguous');
      found = { runner, snapshot, lifecycle, error, version, depth };
    }
    if (!found) return unavailable('committed_runner_snapshot_missing');
    const { runner, snapshot, lifecycle, error, version, depth } = found;
    const errorName = value => {
      for (let object = value, depth = 0; object && depth < 4; object = Object.getPrototypeOf(object), depth++) {
        const name = own(object, 'name');
        if (typeof name === 'string') return /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(name) ? name : 'other';
      }
      return 'unknown';
    };
    const rawMessage = own(error, 'message');
    const boundedUTF8 = text => {
      let value = '', bytes = 0;
      for (const point of text) {
        const size = new TextEncoder().encode(point).length;
        if (bytes + size > 512) break;
        value += point; bytes += size;
      }
      return value;
    };
    // The exact private fixture is authorized for bounded exception text. URL
    // parameters, fragments and nonpublic addresses are never retained.
    const message = typeof rawMessage === 'string' ? boundedUTF8(rawMessage.slice(0, 512).replace(/[\u0000-\u001f\u007f]/g, ' ')
      .replace(/https?:\/\/[^\s)\]"'<>]+/g, value => {
        try {
          const url = new URL(value);
          const publicPath = url.protocol === 'https:' && !url.username && !url.password && !url.port
            && (url.hostname === 'chatgpt.com' && /^\/cdn\/assets\/(?:async\/)?[0-9]{1,6}\.[0-9a-f]{10}\.js$/.test(url.pathname)
              || url.hostname === 'cdn.platform.openai.com' && /^\/deployments\/dil\/v[A-Za-z0-9._-]{1,80}\/[A-Za-z0-9._-]{1,128}\.(?:js|html)$/.test(url.pathname));
          return publicPath ? url.origin + url.pathname : '[address redacted]';
        } catch { return '[address redacted]'; }
      }).slice(0, 512)) : null;
    const rawStack = own(error, 'stack'), publicFrames = [];
    if (typeof rawStack === 'string' && rawStack.length <= 16384) {
      const pattern = /https:\/\/(?:chatgpt\.com\/cdn\/assets\/(?:async\/)?[0-9]{1,6}\.[0-9a-f]{10}\.js|cdn\.platform\.openai\.com\/deployments\/dil\/v[A-Za-z0-9._-]{1,80}\/[A-Za-z0-9._-]{1,128}\.(?:js|html)):[0-9]{1,7}:[0-9]{1,7}(?=[\s)]|$)/g;
      for (let match; publicFrames.length < 4 && (match = pattern.exec(rawStack));) {
        if ([...publicFrames, match[0]].join('\n').length > 512) break;
        publicFrames.push(match[0]);
      }
    }
    const frame = own(runner, 'frame'), moduleError = own(frame, 'moduleError');
    const provenModuleError = own(moduleError, '__oaiDilFrame') === true && own(moduleError, 'kind') === 'moduleError'
      && own(moduleError, 'protocolVersion') === 14 && [undefined, true].includes(own(moduleError, 'policyDenied'));
    if (document.URL !== input.expectedURL || !leaf.isConnected || !copy.isConnected || body.textContent !== label
      || own(runner, 'snapshot') !== snapshot || own(snapshot, 'error') !== error) return unavailable('state_changed');
    const startup = startupProjection(own(frame, 'iframe'));
    return { version: 1, status: 'captured', ancestorDepth: depth, snapshotVersion: version, treeIsNull: true,
      ...(startup === undefined ? {} : { startup }),
      error: { name: errorName(error), message, messageTruncated: typeof rawMessage === 'string' && (rawMessage.length > 512 || new TextEncoder().encode(rawMessage.slice(0, 512)).length > 512),
        publicStack: publicFrames.join('\n'), stage: finiteStage(own(error, 'stage')) },
      lifecycle: { failureStage: finiteStage(own(lifecycle, 'failureStage')),
        frameReady: boolean(own(lifecycle, 'frameReady')), frameRecovering: boolean(own(lifecycle, 'frameRecovering')),
        workerReady: boolean(own(lifecycle, 'workerReady')), firstSnapshotSucceeded: boolean(own(lifecycle, 'firstSnapshotSucceeded')) },
      runnerDisposed: boolean(own(runner, 'disposed')),
      frame: { readyResolved: boolean(own(frame, 'readyResolved')), disposed: boolean(own(frame, 'disposed')),
        retired: boolean(own(frame, 'retired')), retriedPreReadyFrame: boolean(own(frame, 'retriedPreReadyFrame')),
        moduleErrorPresent: provenModuleError, policyDenied: provenModuleError ? own(moduleError, 'policyDenied') === true : null } };
  } catch { return unavailable('read_failed'); }
})();
