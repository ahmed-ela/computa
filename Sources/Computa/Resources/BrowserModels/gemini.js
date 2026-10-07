// A fenced envelope keeps JSON escapes out of the website's Markdown parser.
// Admit only one literal code body with no author prose elsewhere in this answer.
function modelResponseText(answer) {
  if (!answer) return '';
  const rendered = (answer.innerText || answer.textContent || '').trim();
  const blocks = [...answer.querySelectorAll('pre')];
  if (blocks.length !== 1) return rendered;
  const codes = [...blocks[0].querySelectorAll('code')];
  if (codes.length !== 1) return rendered;
  const code = codes[0], raw = code.textContent || '';
  if (raw.length > 220_000) return rendered;
  let envelope;
  try { envelope = JSON.parse(raw); } catch { return rendered; }
  if (!envelope || Array.isArray(envelope) || !['message', 'tool_calls'].includes(envelope.type)) return rendered;
  // Observed Gemini code chrome: the uppercase JSON leaf and Copy code
  // button share this header inside the provider's sole code-block wrapper.
  const wrapper = blocks[0].closest('div.formatted-code-block-internal-container');
  const chrome = new Set();
  if (wrapper && wrapper !== answer && answer.contains(wrapper)
    && wrapper.querySelectorAll('pre').length === 1 && wrapper.querySelectorAll('code').length === 1) {
    const headers = [...wrapper.querySelectorAll('div.code-block-decoration.header-formatted.gds-emphasized-body-m')]
      .filter(node => modelVisible(node) && !node.closest('pre'));
    if (headers.length === 1) {
      const labels = [...headers[0].querySelectorAll('span')].filter(node => modelVisible(node)
        && node.childElementCount === 0 && (node.textContent || '').trim() === 'JSON');
      const copies = [...headers[0].querySelectorAll('button[aria-label="Copy code"]')].filter(node =>
        modelEnabled(node) && !(node.textContent || '').trim());
      if (labels.length === 1 && copies.length === 1) { chrome.add(labels[0]); chrome.add(copies[0]); }
    }
  }
  let visited = 0;
  const onlyCodeAndWhitespace = node => {
    if (++visited > 10_000) return false;
    if (node === code || chrome.has(node)) return true;
    if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
    if (node.nodeType !== 1) return true;
    // Actual controls inside this pre are code-block chrome, never surrounding prose.
    if (node.tagName.toLowerCase() === 'button' && blocks[0].contains(node)) return true;
    return [...node.childNodes].every(onlyCodeAndWhitespace);
  };
  return onlyCodeAndWhitespace(answer) ? raw : rendered;
}

// Diagnostic counts describe only this scoped answer; no response bytes leave this function.
function modelResponseStructure(answer) {
  const blocks = answer ? [...answer.querySelectorAll('pre')] : [];
  const allCodes = answer ? [...answer.querySelectorAll('code')] : [];
  const codes = blocks.length === 1 ? [...blocks[0].querySelectorAll('code')] : [];
  const code = codes.length === 1 ? codes[0] : null;
  let visited = 0, outsideTextLength = 0, outsideTruncated = false;
  const outsideNodes = [];
  const nodeShape = node => ({ tag: /^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'other',
    classes: [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)).slice(0, 6),
    preDescendants: Math.min(node.querySelectorAll('pre').length, 1_000),
    copyControls: Math.min(node.querySelectorAll('button[aria-label="Copy"], button[aria-label="Copy code"]').length, 1_000) });
  const countOutside = node => {
    if (++visited > 10_000) { outsideTruncated = true; return; }
    if (node === code) return;
    if (node.nodeType === 3) {
      const text = (node.textContent || '').trim();
      outsideTextLength = Math.min(220_001, outsideTextLength + text.length);
      if (text && outsideNodes.length < 4) {
        const ancestors = [];
        for (let parent = node.parentElement; parent && ancestors.length < 4; parent = parent.parentElement) {
          ancestors.push(nodeShape(parent)); if (parent === answer) break;
        }
        outsideNodes.push({ kind: text === 'json' ? 'json' : /^[\uE000-\uF8FF]+$/u.test(text) ? 'private_use' : 'other',
          textLength: Math.min(text.length, 220_001), ancestors });
      }
      return;
    }
    if (node.nodeType !== 1) return;
    if (blocks.length === 1 && node.tagName.toLowerCase() === 'button' && blocks[0].contains(node)) return;
    for (const child of node.childNodes) { countOutside(child); if (outsideTruncated) break; }
  };
  if (answer) countOutside(answer);
  const preParentTags = [];
  if (blocks.length === 1) for (let node = blocks[0].parentElement; node && preParentTags.length < 3; node = node.parentElement) {
    preParentTags.push(/^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'other');
    if (node === answer) break;
  }
  const result = { preCount: Math.min(blocks.length, 1_000), codeCount: Math.min(allCodes.length, 1_000),
    codeTextLength: Math.min((code?.textContent || '').length, 220_001), outsideTextLength, outsideTruncated, preParentTags, outsideNodes };
  while (JSON.stringify(result).length > 8_192 && result.outsideNodes.length) result.outsideNodes.pop();
  return result;
}

// Report only the first mismatch's offset and Unicode scalar values, never prompt text.
function modelEditorDifference(actual, expected) {
  let firstDifference = 0;
  while (firstDifference < Math.min(actual.length, expected.length)
    && actual.charCodeAt(firstDifference) === expected.charCodeAt(firstDifference)) firstDifference++;
  // A differing low surrogate still belongs to the scalar beginning one unit earlier.
  if (firstDifference > 0 && actual.charCodeAt(firstDifference - 1) >= 0xD800
    && actual.charCodeAt(firstDifference - 1) <= 0xDBFF
    && (actual.charCodeAt(firstDifference) >= 0xDC00 && actual.charCodeAt(firstDifference) <= 0xDFFF
      || expected.charCodeAt(firstDifference) >= 0xDC00 && expected.charCodeAt(firstDifference) <= 0xDFFF)) firstDifference--;
  const scalarAt = text => {
    if (firstDifference >= text.length) return null;
    const scalar = text.codePointAt(firstDifference);
    return scalar >= 0xD800 && scalar <= 0xDFFF ? undefined : scalar;
  };
  return { firstDifference: Math.min(firstDifference, 360_000), actualScalar: scalarAt(actual), expectedScalar: scalarAt(expected) };
}

// Fixed Gemini DOM adapter. Only native structured input runs this private-world program.
function modelVisible(node) {
  return !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
}
function modelEnabled(node) { return modelVisible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true'; }
function modelFind(selectors) { return selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(modelVisible); }
function modelUserRoots() {
  const nodes = [...document.querySelectorAll('user-query')];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
function modelUserBody(root) {
  if (!root) return null;
  // Observed Gemini markup keeps message bytes in one span while controls
  // occupy its sibling. Pin that body through the exact provider wrappers.
  const contents = [...root.querySelectorAll('div.query-content')];
  if (contents.length !== 1 || contents[0].closest('user-query') !== root || !modelVisible(contents[0])) return null;
  const child = (parent, tag, name) => {
    if (!parent) return null;
    const matches = [...parent.children].filter(node => node.tagName.toLowerCase() === tag && node.classList.contains(name));
    return matches.length === 1 && modelVisible(matches[0]) ? matches[0] : null;
  };
  const status = child(contents[0], 'div', 'query-bubble-with-status');
  const bubble = child(status, 'span', 'user-query-bubble-with-background');
  const body = child(bubble, 'span', 'ng-star-inserted');
  if (!body || body.closest('user-query') !== root
    || body.closest('[contenteditable="true"], [role="textbox"]')
    || body.querySelector('button, [role="button"], [contenteditable="true"], [role="textbox"]')) return null;
  return body;
}
function modelTemporaryHeadingFacts(heading) {
  const direct = [...heading.childNodes].filter(node => node.nodeType === 3).map(node => node.textContent || '').join('').trim();
  const initialTitle = direct === 'Just stopping by?' || [...heading.querySelectorAll('*')].slice(0, 256)
    .some(node => modelVisible(node) && node.childElementCount === 0 && (node.textContent || '').trim() === 'Just stopping by?');
  const supportLink = [...heading.querySelectorAll('a[href]')].some(node => {
    if (!modelVisible(node)) return false;
    try {
      const url = new URL(node.getAttribute('href'), document.URL);
      return url.origin === 'https://support.google.com' && !url.username && !url.password
        && url.pathname === '/gemini/answer/13275745' && url.searchParams.get('p') === 'temp_chats';
    } catch { return false; }
  });
  const text = (heading.textContent || '').normalize('NFC').replace(/’/g, "'").replace(/\s+/g, ' ');
  const noHistory = text.includes("don't appear in recent chats") && text.includes("aren't used to improve Google AI");
  return { initialTitle, supportLink, noHistory };
}
function modelTemporaryVerified() {
  const exclude = 'button, [role="menu"], [role="tooltip"], model-response, user-query';
  const exit = modelFind(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]']);
  if (exit) return true;
  if ([...document.querySelectorAll('span.info-text')].some(node => modelVisible(node) && !node.closest(exclude)
    && (node.textContent || '').trim() === 'Temporary Chat')) return true;
  return [...document.querySelectorAll('h1, h2, [role="heading"]')].some(node => {
    if (!modelVisible(node) || node.closest(exclude)) return false;
    // Live provider mode scaffold: exact title + linked temp documentation +
    // no-history notice inside this same heading, not arbitrary body text.
    const facts = modelTemporaryHeadingFacts(node);
    return facts.initialTitle && facts.supportLink && facts.noHistory;
  });
}
// Readiness diagnostics contain only bounded structural facts, never page text.
function modelReadinessStructure() {
  const exclude = 'button, [role="menu"], [role="tooltip"], model-response, user-query';
  const shape = node => ({ tag: node.tagName.toLowerCase(),
    classes: [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)).slice(0, 6),
    visible: modelVisible(node), excluded: !!node.closest(exclude),
    textLength: Math.min((node.textContent || '').length, 220_001),
    initialExact: (node.textContent || '').trim() === 'Just stopping by?',
    activeExact: (node.textContent || '').trim() === 'Temporary Chat' });
  const candidates = [...document.querySelectorAll('h1, h2, [role="heading"], span.info-text')].slice(0, 12);
  const nodes = candidates.map(node => ({ ...shape(node), ...modelTemporaryHeadingFacts(node),
    // These booleans diagnose nested headings; they do not grant temporary mode.
    initialContained: (node.textContent || '').includes('Just stopping by?'),
    activeContained: (node.textContent || '').includes('Temporary Chat'),
    exactDescendants: [...node.querySelectorAll('*')].slice(0, 256).filter(child =>
      ['Just stopping by?', 'Temporary Chat'].includes((child.textContent || '').trim())).slice(0, 4).map(shape) }));
  const count = selectors => {
    const found = selectors.flatMap(selector => [...document.querySelectorAll(selector)]);
    const unique = [...new Set(found)];
    return { total: Math.min(unique.length, 1_000), visible: Math.min(unique.filter(modelVisible).length, 1_000),
      enabled: Math.min(unique.filter(modelEnabled).length, 1_000) };
  };
  const result = { kind: 'provider_readiness', provider: 'gemini', nodes,
    composer: count(['[contenteditable="true"][aria-label="Enter a prompt for Gemini"]', 'rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']),
    toggle: count(['button[aria-label="Temporary chat"]']),
    exit: count(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]']) };
  while (JSON.stringify(result).length > 8_192 && result.nodes.length) result.nodes.pop();
  return JSON.stringify(result);
}
function modelURLAllowed() {
  try {
    const url = new URL(document.URL);
    return url.origin === 'https://gemini.google.com' && !url.username && !url.password
      && /^\/(?:u\/[0-9]{1,3}\/)?app(?:\/[A-Za-z0-9_-]+)?\/?$/.test(url.pathname);
  } catch { return false; }
}
const allowedActions = ['inspect', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop'];
if (input.provider !== 'gemini' || window !== window.top || location.origin !== 'https://gemini.google.com'
  || !modelURLAllowed() || document.URL !== input.expectedURL)
  return { error: 'document_changed', detail: 'document_url' };
if (!allowedActions.includes(input.action)) return { error: 'unknown_action' };
if (typeof input.ownerToken !== 'string' || !/^[a-f0-9-]{36}$/i.test(input.ownerToken))
  return { error: 'document_changed', detail: 'owner_token' };
if (globalThis.__computaModelOwner !== input.ownerToken) {
  if (input.bindOwner === true && globalThis.__computaModelOwner === undefined)
    globalThis.__computaModelOwner = input.ownerToken;
  else return { error: 'document_changed', detail: 'owner_token' };
}
if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken) {
  const signal = { ownerToken: input.ownerToken, queued: false, observer: null };
  signal.observer = new MutationObserver(records => {
    if (!records.length || signal.queued) return;
    signal.queued = true;
    setTimeout(() => {
      signal.queued = false;
      if (window !== window.top || location.origin !== 'https://gemini.google.com'
        || globalThis.__computaModelOwner !== signal.ownerToken) return;
      // Notification only. No page text, tool requests, or native mutation authority.
      try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ ownerToken: signal.ownerToken, kind: 'dom_changed' }); }
      catch { }
    }, 100);
  });
  signal.observer.observe(document.documentElement || document, { subtree: true, childList: true,
    characterData: true, attributes: true, attributeFilter: ['disabled', 'aria-disabled', 'aria-hidden', 'aria-busy',
      'aria-label', 'class', 'style', 'hidden', 'inert', 'contenteditable', 'data-testid', 'data-is-streaming', 'id'] });
  globalThis.__computaModelSignal = signal;
}
const cleanURL = location.origin + location.pathname.replace(/\/$/, '');
if (input.expectedConversation && cleanURL !== input.expectedConversation)
  return { error: 'conversation_changed', detail: 'conversation_route' };
const ownedMessages = modelUserRoots();
const ownedUserCount = ownedMessages.length;
if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.includes(ownedUserCount))
  return { error: 'conversation_changed', detail: 'user_count' };
const normalizedBody = node => (node.innerText || node.textContent || '').replace(/\r\n?/g, '\n').normalize('NFC').trim();
function modelFirstUserStructure(reason, allowSubmittedUser = false) {
  const roots = modelUserRoots(), root = roots[0], body = root && modelUserBody(root);
  const rendered = body ? normalizedBody(body) : '', lines = rendered.split('\n');
  const marker = input.expectedFirstUserMarker;
  const markerLine = typeof marker === 'string' && /^[a-f0-9-]{36}$/i.test(marker) ? `Computa session marker: ${marker}` : null;
  const utilities = ['block', 'flex', 'inline-flex', 'relative', 'truncate', 'whitespace-pre-wrap', 'whitespace-normal',
    'break-words', 'overflow-hidden', 'overflow-auto', 'hidden', 'text-sm', 'items-center', 'min-w-0', 'w-full'];
  const shape = node => ({ tag: node && /^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'none',
    classes: node ? [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)
      && (/^(?:query-|user-query-|gds-|mat-|cdk-|ng-)/.test(name) || utilities.includes(name))
      && !rendered.includes(name) && !(globalThis.__computaModelFirstPrompt || '').includes(name)).slice(0, 6) : [] });
  const descendants = [], queue = root ? [...root.children].filter(node => node.nodeType === 1)
    .map((node, index) => ({ node, path: [Math.min(index, 1_000)] })) : [];
  for (let index = 0; index < queue.length && descendants.length < 16; index++) {
    const { node, path } = queue[index], text = normalizedBody(node);
    descendants.push({ ...shape(node), path, childElements: Math.min(node.childElementCount, 1_000),
      controls: Math.min(node.querySelectorAll('button, [role="button"]').length, 1_000),
      textLength: Math.min(text.length, 220_001), markerExact: markerLine !== null && text === markerLine,
      markerContained: markerLine !== null && text.includes(markerLine), visible: modelVisible(node),
      editable: node.getAttribute('contenteditable') === 'true' });
    if (path.length < 16) [...node.children].filter(child => child.nodeType === 1).slice(0, 16)
      .forEach((child, childIndex) => queue.push({ node: child, path: [...path, childIndex] }));
  }
  const pinned = globalThis.__computaModelFirstProof;
  const diagnostic = { kind: 'first_user_structure', provider: 'gemini', reason, userCount: Math.min(roots.length, 1_000),
    root: shape(root), body: shape(body), textLength: Math.min(rendered.length, 220_001), lineCount: Math.min(lines.length, 220_001),
    markerFinalLine: markerLine !== null && lines.at(-1) === markerLine,
    markerOccurrences: Math.min(markerLine === null ? 0 : lines.filter(line => line === markerLine).length, 1_000),
    controlDescendants: Math.min(body ? body.querySelectorAll('button, [role="button"]').length : 0, 1_000),
    submitted: globalThis.__computaModelFirstSubmitted === true, markerMatches: globalThis.__computaModelFirstMarker === marker,
    descendants };
  if (firstUserFingerprint !== null) {
    if (typeof pinned?.fingerprint === 'string') diagnostic.pinnedFingerprintMatch = pinned.fingerprint === firstUserFingerprint;
    if (typeof input.expectedFirstUserFingerprint === 'string') diagnostic.nativeFingerprintMatch = input.expectedFirstUserFingerprint === firstUserFingerprint;
  }
  if (firstSnapshot) diagnostic.snapshot = { rootSame: roots[0] === firstSnapshot.root,
    bodySame: !!roots[0] && modelUserBody(roots[0]) === firstSnapshot.body, bodyConnected: firstSnapshot.body.isConnected,
    textSame: normalizedBody(firstSnapshot.body) === firstSnapshot.text,
    countSame: roots.length === ownedUserCount || allowSubmittedUser && roots.length === ownedUserCount + 1,
    urlSame: document.URL === input.expectedURL, originSame: location.origin === 'https://gemini.google.com',
    ownerSame: globalThis.__computaModelOwner === input.ownerToken };
  while (JSON.stringify(diagnostic).length > 8_192 && diagnostic.descendants.length) diagnostic.descendants.pop();
  return JSON.stringify(diagnostic);
}
function modelFirstUserFailure(reason, allowSubmittedUser = false) {
  return { error: 'conversation_changed', detail: 'first_user_message',
    debugStructure: modelFirstUserStructure(reason, allowSubmittedUser) };
}
let firstSnapshot = null, firstUserFingerprint = null, firstUserIdentity = null;
const snapshotUnchanged = (allowSubmittedUser = false) => {
  const current = modelUserRoots();
  return window === window.top && location.origin === 'https://gemini.google.com' && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken
    && (current.length === ownedUserCount || allowSubmittedUser && current.length === ownedUserCount + 1)
    && current[0] === firstSnapshot.root && firstSnapshot.body.isConnected
    && modelUserBody(current[0]) === firstSnapshot.body && normalizedBody(firstSnapshot.body) === firstSnapshot.text
    && true;
};
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker, first = modelUserBody(ownedMessages[0]);
  if (!first) return modelFirstUserFailure('body_empty');
  const rendered = normalizedBody(first), markerLine = `Computa session marker: ${marker}`;
  const lines = rendered.split('\n');
  if (typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker)
    || globalThis.__computaModelFirstSubmitted !== true || globalThis.__computaModelFirstMarker !== marker
    || rendered.length > 180_200 || lines.at(-1) !== markerLine
    || lines.filter(line => line === markerLine).length !== 1 || !lines.slice(0, -1).join('\n').trim())
    return modelFirstUserFailure(typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker) ? 'marker_invalid'
      : globalThis.__computaModelFirstSubmitted !== true ? 'submission_unclaimed'
      : globalThis.__computaModelFirstMarker !== marker ? 'marker_mismatch'
      : rendered.length > 180_200 ? 'body_limit' : lines.at(-1) !== markerLine ? 'marker_not_final'
      : lines.filter(line => line === markerLine).length !== 1 ? 'marker_duplicate' : 'body_empty');

  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered, identity: firstUserIdentity };
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  if (!snapshotUnchanged()) {
    const current = modelUserRoots(), pinned = globalThis.__computaModelFirstProof;
    // A single acknowledged continuation can appear while this read awaits SHA.
    // Discard the observation; the next inspect must recheck the complete state.
    if (input.action === 'inspect' && input.allowFirstUserBinding === false
      && input.expectedUserCounts.length === 2 && input.expectedUserCounts[0] === ownedUserCount
      && input.expectedUserCounts[1] === ownedUserCount + 1 && current.length === ownedUserCount + 1
      && globalThis.__computaModelLastSubmissionCount === ownedUserCount
      && pinned?.marker === marker && pinned.fingerprint === fingerprint && pinned.identity === firstUserIdentity
      && input.expectedFirstUserFingerprint === fingerprint
      && window === window.top && location.origin === 'https://gemini.google.com' && document.URL === input.expectedURL
      && globalThis.__computaModelOwner === input.ownerToken && current[0] === firstSnapshot.root
      && firstSnapshot.body.isConnected && modelUserBody(current[0]) === firstSnapshot.body
      && normalizedBody(firstSnapshot.body) === firstSnapshot.text && modelTemporaryVerified())
      return { error: 'submission_observation_pending' };
    return modelFirstUserFailure('snapshot_before_action');
  }
  if (!modelTemporaryVerified()) return { error: 'temporary_mode_unverified' };
  firstUserFingerprint = fingerprint;
  const pinned = globalThis.__computaModelFirstProof;
  if (pinned) {
    if (pinned.marker !== marker || pinned.fingerprint !== firstUserFingerprint
      || pinned.identity !== firstUserIdentity
      || input.expectedFirstUserFingerprint !== pinned.fingerprint
        && !(input.expectedFirstUserFingerprint == null && input.allowFirstUserBinding === true
          && input.action === 'inspect' && ownedUserCount === 1))
      return modelFirstUserFailure(pinned.fingerprint !== firstUserFingerprint ? 'pinned_fingerprint'
        : input.expectedFirstUserFingerprint !== pinned.fingerprint ? 'native_fingerprint' : 'binding_not_authorized');
  } else if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || ownedUserCount !== 1
    || input.expectedFirstUserFingerprint != null)
    return modelFirstUserFailure('binding_not_authorized');
} else if (input.expectedFirstUserFingerprint != null || globalThis.__computaModelFirstProof)
  return modelFirstUserFailure('first_missing');

async function providerPageAction() {
  const { action, prompt, expectedFirstUserMarker } = input;
  const composer = modelFind(['[contenteditable="true"][aria-label="Enter a prompt for Gemini"]', 'rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']);
  const candidates = [...document.querySelectorAll('.model-response-text, model-response .markdown')].filter(modelVisible);
  const answers = candidates.filter(node => !candidates.some(other => other !== node && other.contains(node)));
  const answer = answers.at(-1), stop = modelFind(['button[aria-label="Stop response"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]', 'button.stop-button']);
  const response = answer?.closest('model-response');
  const busy = !!stop || !!response && response.getAttribute('aria-busy') === 'true';
  const interrupted = false;
  const copies = response && answers.filter(node => response === node || response.contains(node)).length === 1
    ? [...response.querySelectorAll('button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]')] : [];
  const scopedCopies = copies.length, enabledCopies = copies.filter(modelEnabled).length;
  const answerComplete = !busy && enabledCopies > 0;
  const temporary = modelTemporaryVerified();
  const temporaryActionAvailable = modelEnabled(modelFind(['button[aria-label="Temporary chat"]']));
  const state = { url: document.URL, temporary, temporaryActionAvailable, conversationIdentity: null, composer: !!composer,
    responseCount: answers.length, userCount: ownedUserCount, firstUserIdentity, firstUserFingerprint,
    firstUserVerified: ownedUserCount > 0, firstUserMarkerVerified: ownedUserCount > 0,
    busy, interrupted, text: modelResponseText(answer).slice(0, 220_001),
    answerComplete, completionEvidence: { codeStructure: modelResponseStructure(answer), modernMarkers: 0, logicalAnswers: answers.length,
      scopedCopies, enabledCopies, depth: -1 } };
  if (action === 'inspect') {
    const signIn = !composer && [...document.querySelectorAll('a, button')].filter(modelVisible)
      .some(node => /^(?:Log in|Sign in)(?:\s|$)/i.test(node.getAttribute('aria-label') || (node.innerText || '').trim()));
    return { ...state, signIn, debugStructure: modelReadinessStructure() };
  }
  if (action === 'enableTemporary') {
    if (temporary) return { ...state, enabled: true };
    if (ownedUserCount || answers.length || globalThis.__computaModelFirstSubmitted) return { error: 'not_fresh' };
    if (globalThis.__computaModelTemporaryRequested) return { error: 'temporary_mode_unverified' };
    const toggle = modelFind(['button[aria-label="Temporary chat"]']);
    if (!modelEnabled(toggle)) return { error: 'temporary_mode_unavailable' };
    // Claim before the single click. A lost acknowledgment cannot toggle back.
    globalThis.__computaModelTemporaryRequested = true;
    toggle.click();
    return { ...state, enabled: false };
  }
  if (!temporary) return { error: 'temporary_mode_unverified', detail: 'mode_controls_unverified' };
  if (action === 'stop') {
    if (modelEnabled(stop)) stop.click();
    return { ...state, stopped: !!stop };
  }
  if (!modelEnabled(composer) || busy) return { error: 'composer_unavailable',
    detail: !composer ? 'missing_composer' : !modelEnabled(composer) ? 'inactive_composer' : 'response_busy' };
  const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
  if (action === 'prepare') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    composer.focus();
    return { ...state, prepared: document.activeElement === composer || composer.contains(document.activeElement) };
  }
  if (typeof prompt !== 'string' || !prompt.trim() || prompt.length > 180_000) return { error: 'prompt_not_inserted' };
  if (action === 'insert') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    if (ownedUserCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || typeof expectedFirstUserMarker !== 'string'
        || !/^[a-f0-9-]{36}$/i.test(expectedFirstUserMarker)
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return modelFirstUserFailure('first_insert');
      globalThis.__computaModelFirstPrompt = prompt;
    }
    composer.focus();
    if (composer instanceof HTMLTextAreaElement) {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(composer, prompt);
      composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
    } else {
      const selection = window.getSelection();
      if (!selection) return { error: 'caret_unavailable' };
      const range = document.createRange();
      range.selectNodeContents(composer); range.collapse(false);
      selection.removeAllRanges(); selection.addRange(range);
      if (!composer.contains(selection.anchorNode) || !composer.contains(selection.focusNode)) return { error: 'caret_unavailable' };
      if (composer.classList.contains('ProseMirror')) {
        const paragraph = document.createElement('p');
        prompt.split('\n').forEach((line, index) => {
          if (index) paragraph.appendChild(document.createElement('br'));
          paragraph.appendChild(document.createTextNode(line));
        });
        composer.replaceChildren(paragraph);
        range.selectNodeContents(paragraph); range.collapse(false);
        selection.removeAllRanges(); selection.addRange(range);
        composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
      } else if (composer.classList.contains('ql-editor')) {
        // WebKit insertText applies smart punctuation on the live Quill editor.
        // Quill owns one paragraph per line; write literal nodes instead of
        // passing the text through the browser's editing substitutions.
        const paragraphs = prompt.split('\n').map(line => {
          const paragraph = document.createElement('p');
          paragraph.appendChild(line ? document.createTextNode(line) : document.createElement('br'));
          return paragraph;
        });
        composer.replaceChildren(...paragraphs);
        range.selectNodeContents(paragraphs.at(-1)); range.collapse(false);
        selection.removeAllRanges(); selection.addRange(range);
        composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
      } else if (!document.execCommand('insertText', false, prompt)) return { error: 'insert_command_rejected' };
    }
    return { ...state, inserted: true };
  }
  const actual = (value || '').replace(/\r\n/g, '\n').trim(), expected = prompt.trim();
  if (actual !== expected) {
    const detail = !actual ? 'editor_empty'
      : actual.replace(/\n+/g, '\n') === expected.replace(/\n+/g, '\n') ? 'line_break_expansion'
      : actual.replace(/\u00a0/g, ' ') === expected ? 'nonbreaking_spaces' : 'text_difference';
    return { error: 'prompt_not_inserted', detail, ...modelEditorDifference(actual, expected), actualLength: actual.length, expectedLength: expected.length,
      actualLines: actual.split('\n').length, expectedLines: expected.split('\n').length };
  }
  const send = modelFind(['button[aria-label="Send message"]', 'button[aria-label="Send"]', 'button.send-button']);
  if (action === 'sendReady') return { ...state, sendReady: modelEnabled(send) };
  if (!modelEnabled(send)) return { error: 'send_unavailable' };
  if (globalThis.__computaModelLastSubmissionCount !== undefined
    && ownedUserCount <= globalThis.__computaModelLastSubmissionCount)
    return { error: 'conversation_changed', detail: 'user_count' };
  if (ownedUserCount === 0) {
    if (globalThis.__computaModelFirstSubmitted || globalThis.__computaModelFirstPrompt !== prompt
      || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
      return modelFirstUserFailure('first_submit');
    globalThis.__computaModelFirstMarker = expectedFirstUserMarker;
    globalThis.__computaModelFirstSubmitted = true;
  }
  globalThis.__computaModelLastSubmissionCount = ownedUserCount;
  send.click();
  return { submitted: true };
}
const observed = await providerPageAction();
if (firstSnapshot) {
  if (!snapshotUnchanged(input.action === 'submit')) return modelFirstUserFailure('snapshot_after_action', input.action === 'submit');
  if (!modelTemporaryVerified()) return { error: 'temporary_mode_unverified' };
  if (observed.error) return observed;
  const firstBound = !globalThis.__computaModelFirstProof;
  if (!globalThis.__computaModelFirstProof) {
    if (observed.temporary !== true) return { error: 'temporary_mode_unverified' };
    globalThis.__computaModelFirstProof = { marker: input.expectedFirstUserMarker, fingerprint: firstUserFingerprint,
      identity: firstUserIdentity };
  }
  // Submit intentionally exposes its acknowledgment only, as in the native contract.
  if (input.action === 'submit') return observed;
  return { ...observed, firstUserVerified: true, firstUserFingerprint, firstUserMarkerVerified: true,
    ...(firstBound ? { debugStructure: modelFirstUserStructure('first_bound') } : {}) };
}
return { ...observed, firstUserVerified: false, firstUserFingerprint: null };
