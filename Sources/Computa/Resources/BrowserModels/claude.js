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
  // Observed Claude code chrome: the language label and icon control are
  // siblings of this sole pre inside the provider's exact code-block wrapper.
  // Only these verified nodes can be skipped; authored surrounding text cannot.
  const wrapper = blocks[0].closest('div.relative.border-border-400');
  const chrome = new Set();
  if (wrapper && wrapper !== answer && answer.contains(wrapper)
    && wrapper.querySelectorAll('pre').length === 1 && wrapper.querySelectorAll('code').length === 1) {
    const labels = [...wrapper.querySelectorAll('div.text-text-500.font-small.pb-0')].filter(node =>
      modelVisible(node) && !node.closest('pre') && node.childElementCount === 0 && (node.textContent || '').trim() === 'json');
    const controls = [...wrapper.querySelectorAll('div.absolute.right-0.h-8.px-2.items-center.inline-flex button.cds-reset.relative.isolate.inline-flex.shrink-0.items-center')]
      .filter(node => modelVisible(node) && !node.closest('pre') && /^[\uE000-\uF8FF]$/u.test((node.textContent || '').trim()));
    if (labels.length === 1 && controls.length === 1) { chrome.add(labels[0]); chrome.add(controls[0]); }
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

// Fixed Claude DOM adapter. Only native structured input runs this private-world program.
function modelVisible(node) {
  return !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
}
function modelEnabled(node) { return modelVisible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true'; }
function modelFind(selectors) { return selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(modelVisible); }
// Website UI labels may split/reset whitespace; message bytes never use this.
function modelQuotaLabel(text) { return (text || '').replace(/\s+/g, ' ').trim(); }
function modelUsageLimitPopup() {
  const messages = '[data-testid="assistant-message"], [data-testid="user-message"]';
  const headings = [...document.querySelectorAll('h1, h2, h3, [role="heading"]')].filter(node => modelVisible(node)
    && !node.closest(messages) && /^Your free messages return at (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/.test(modelQuotaLabel(node.textContent)));
  if (headings.length !== 1) return null;
  // AX exposes this popup as a container, without a verified dialog role.
  // Require the lowest bounded container coupling its heading and both observed
  // non-purchase controls. The Upgrade button's rendered currency is variable.
  let container = headings[0].parentElement;
  for (let depth = 0; container && depth < 8; depth++, container = container.parentElement) {
    if (['body', 'html'].includes(container.tagName.toLowerCase()) || container.closest(messages)
      || container.querySelector(messages)) return null;
    const buttons = [...container.querySelectorAll('button')].filter(node => modelEnabled(node) && !node.closest(messages));
    const named = text => buttons.filter(node => modelQuotaLabel(node.getAttribute('aria-label') || node.innerText || node.textContent) === text);
    const plans = named('See all plans'), dismiss = named('Not now');
    if (plans.length && dismiss.length) return plans.length === 1 && dismiss.length === 1 && modelVisible(container) ? container : null;
  }
  return null;
}
function modelUsageLimitBanner() {
  const messages = '[data-testid="assistant-message"], [data-testid="user-message"]';
  const urlOf = node => { try { return new URL(node.getAttribute('href'), document.URL); } catch { return null; } };
  const support = [...document.querySelectorAll('a[href]')].filter(node => modelVisible(node) && !node.closest(messages)
    && urlOf(node)?.href === 'https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits');
  if (support.length !== 1) return false;
  let container = support[0].parentElement;
  for (let depth = 0; container && depth < 8; depth++, container = container.parentElement) {
    if (['body', 'html'].includes(container.tagName.toLowerCase()) || container.closest(messages)
      || container.querySelector(messages)) return false;
    const upgrades = [...container.querySelectorAll('a[href]')].filter(node => {
      const url = urlOf(node);
      return modelVisible(node) && !node.closest(messages) && url?.origin === 'https://claude.ai' && !url.username && !url.password
        && url.pathname === '/upgrade' && !url.hash && url.searchParams.size === 2
        && url.searchParams.get('hide_free') === 'true' && url.searchParams.get('from') === 'ratelimit';
    });
    const nodes = [container, ...container.querySelectorAll('*')].slice(0, 256);
    const text = nodes.some(node => {
      if (!modelVisible(node) || node.closest(messages)) return false;
      const parts = [...node.childNodes].filter(child => child.nodeType === 1 || child.nodeType === 3);
      // The observed warning has exactly text / official support anchor / text.
      // Anchor bytes never contribute authority: its fixed URL contributes only
      // the constant word "messages" to this abort-only quota classification.
      return parts.length === 3 && parts[0].nodeType === 3 && parts[1] === support[0] && parts[2].nodeType === 3
        && /^You are out of free messages until (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/.test(
          modelQuotaLabel(parts.map(child => child === support[0] ? 'messages' : child.textContent || '').join('')));
    });
    if (text && upgrades.length) return upgrades.length === 1 && modelVisible(container);
  }
  return false;
}
function modelUsageLimited() { return !!modelUsageLimitPopup() || modelUsageLimitBanner(); }
function modelQuotaDiagnostic() {
  const boundary = '[data-testid="assistant-message"], [data-testid="user-message"]';
  const tags = ['a', 'button', 'div', 'span', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'section', 'main', 'body', 'html', 'dialog'];
  const bounded = count => Math.min(count, 1_000);
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden';
  const shape = node => {
    const style = getComputedStyle(node), tag = node.tagName.toLowerCase();
    return { tag: tags.includes(tag) ? tag : 'other', rectCount: bounded(node.getClientRects().length),
      strictVisible: modelVisible(node), physicalVisible: physical(node), inertAncestor: !!node.closest('[inert]'),
      ariaHiddenAncestor: !!node.closest('[aria-hidden="true"]'),
      display: ['none', 'contents'].includes(style.display) ? style.display : 'other',
      visibility: ['visible', 'hidden', 'collapse'].includes(style.visibility) ? style.visibility : 'other' };
  };
  const spaced = /^Your free messages return at (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/;
  const joined = /^Your free messages return at (?:[1-9]|1[0-2]):[0-5][0-9](?:AM|PM)$/;
  const headings = [...document.querySelectorAll('h1, h2, h3, [role="heading"]')].filter(node => !node.closest(boundary)
    && modelQuotaLabel(node.textContent).startsWith('Your free messages return at')).slice(0, 4);
  const popupAncestors = [], candidates = new Set();
  for (let node = headings[0]?.parentElement, depth = 0; node && depth < 8; node = node.parentElement, depth++) {
    const controls = [...node.querySelectorAll('button, [role="button"], a')].filter(control => !control.closest(boundary));
    const exact = label => controls.filter(control => modelQuotaLabel(control.getAttribute('aria-label') || control.innerText || control.textContent) === label).length;
    popupAncestors.push({ ...shape(node), depth, containsMessages: !!node.closest(boundary) || !!node.querySelector(boundary),
      buttonCount: bounded(controls.filter(control => control.tagName.toLowerCase() === 'button').length),
      roleButtonCount: bounded(controls.filter(control => control.getAttribute('role') === 'button').length),
      anchorCount: bounded(controls.filter(control => control.tagName.toLowerCase() === 'a').length),
      upgradeExactCount: bounded(exact('Upgrade to Pro for $20/month')), dismissExactCount: bounded(exact('Not now')) });
    if (['body', 'html'].includes(node.tagName.toLowerCase())) break;
    controls.slice(0, 8).forEach(control => candidates.add(control));
  }
  const controlShape = node => {
    const aria = modelQuotaLabel(node.getAttribute('aria-label')), text = modelQuotaLabel(node.innerText || node.textContent);
    const edges = modelQuotaLabel(text.replace(/^[\s\uE000-\uF8FF]+|[\s\uE000-\uF8FF]+$/g, ''));
    return { ...shape(node), roleButton: node.getAttribute('role') === 'button', ariaLabelPresent: node.getAttribute('aria-label') !== null,
      ariaUpgradeExact: aria === 'Upgrade to Pro for $20/month', ariaDismissExact: aria === 'Not now',
      textUpgradeExact: text === 'Upgrade to Pro for $20/month', textDismissExact: text === 'Not now',
      upgradeEdgePrivateUse: text !== edges && edges === 'Upgrade to Pro for $20/month',
      dismissEdgePrivateUse: text !== edges && edges === 'Not now',
      privateUseCount: bounded((text.match(/[\uE000-\uF8FF]/g) || []).length),
      hasUnknownLabelText: !['Upgrade to Pro for $20/month', 'Not now'].includes(edges) };
  };
  const support = [...document.querySelectorAll('a[href]')].filter(node => {
    if (node.closest(boundary)) return false;
    try { return new URL(node.getAttribute('href'), document.URL).href === 'https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits'; }
    catch { return false; }
  }).slice(0, 4);
  const bannerParents = [];
  for (let node = support[0]?.parentElement, depth = 0; node && depth < 4; node = node.parentElement, depth++) {
    const parts = [...node.childNodes].filter(child => child.nodeType === 1 || child.nodeType === 3);
    const sentence = modelQuotaLabel(parts.map(child => child === support[0] ? 'messages' : child.nodeType === 3 ? child.textContent || '' : '').join(''));
    bannerParents.push({ ...shape(node), supportDirect: parts.includes(support[0]),
      spacedClock: /^You are out of free messages until (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/.test(sentence),
      joinedClock: /^You are out of free messages until (?:[1-9]|1[0-2]):[0-5][0-9](?:AM|PM)$/.test(sentence),
      children: parts.slice(0, 8).map(child => child.nodeType === 3 ? 'text' : child === support[0] ? 'support' : child.nodeType === 1 ? 'element' : 'other') });
    if (['body', 'html'].includes(node.tagName.toLowerCase())) break;
  }
  const header = [...document.querySelectorAll('.animate-incognito-header-in span')].filter(node => !node.closest(boundary));
  const exit = [...document.querySelectorAll('button[aria-label="Exit incognito"]')].filter(node => !node.closest(boundary));
  const result = { kind: 'quota_structure', provider: 'claude',
    headings: headings.map(node => ({ ...shape(node), spacedClock: spaced.test(modelQuotaLabel(node.textContent)), joinedClock: joined.test(modelQuotaLabel(node.textContent)) })),
    controls: [...candidates].slice(0, 8).map(controlShape), popupAncestors,
    support: support.map(node => ({ ...shape(node), labelExact: modelQuotaLabel(node.textContent) === 'messages',
      labelKnownSuffix: modelQuotaLabel(node.textContent) === 'messages (opens in new tab)' })), bannerParents,
    mode: { headerTotal: bounded(header.length), headerVisible: bounded(header.filter(modelVisible).length), headerPhysical: bounded(header.filter(physical).length),
      exitTotal: bounded(exit.length), exitVisible: bounded(exit.filter(modelVisible).length), exitPhysical: bounded(exit.filter(physical).length) } };
  while (JSON.stringify(result).length > 8_192 && result.popupAncestors.length) result.popupAncestors.pop();
  return JSON.stringify(result);
}
function modelTemporaryFailure(error) { return { error, quotaDiagnostic: modelQuotaDiagnostic() }; }
function modelUserRoots() {
  const nodes = [...document.querySelectorAll('[data-testid="user-message"]')];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
function modelUserBody(root) { return root; }
function modelTemporaryVerified() {
  // A known quota dialog makes the background inert. Cleanup may inspect its
  // already-rendered mode indicators, while every interactive lookup stays strict.
  const popup = input.action === 'stop' && modelUsageLimitPopup();
  const visible = popup
    ? node => !!node && node.isConnected && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden'
    : modelVisible;
  const outside = '[data-testid="assistant-message"], [data-testid="user-message"], dialog, [role="dialog"], [aria-modal="true"]';
  const exit = [...document.querySelectorAll('button[aria-label="Exit incognito"]')].find(node => visible(node)
    && !node.closest(outside) && (!popup || !popup.contains(node)));
  const url = new URL(document.URL);
  return !!exit && url.searchParams.has('incognito') && url.searchParams.get('incognito') === ''
    && [...document.querySelectorAll('.animate-incognito-header-in span')].some(node => visible(node)
      && !node.closest(outside) && (!popup || !popup.contains(node))
      && (node.textContent || '').trim() === 'Incognito chat');
}
function modelURLAllowed() {
  try {
    const url = new URL(document.URL);
    return url.origin === 'https://claude.ai' && !url.username && !url.password
      && /^\/(?:new|chat\/[A-Za-z0-9-]+)\/?$/.test(url.pathname);
  } catch { return false; }
}
const allowedActions = ['inspect', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop'];
if (input.provider !== 'claude' || window !== window.top || location.origin !== 'https://claude.ai'
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
      if (window !== window.top || location.origin !== 'https://claude.ai'
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
let usageLimited = modelUsageLimited();
function modelUsageLimitFailure() {
  // This is only an empty initial-page abort receipt, never readiness or Send
  // authority. Count physical roots, including hidden responses, before binding
  // the current document for native cleanup of this exact owned empty tab.
  const pristine = ['FirstSubmitted', 'FirstProof', 'LastSubmissionCount', 'FirstPrompt',
    'FirstMarker', 'FirstPrepared', 'TemporaryRequested'].every(name => globalThis[`__computaModel${name}`] === undefined);
  if (input.action === 'inspect' && ownedUserCount === 0 && input.expectedUserCounts.length === 1
    && input.expectedUserCounts[0] === 0 && pristine && input.expectedFirstUserFingerprint == null
    && location.pathname.replace(/\/$/, '') === '/new'
    && window === window.top && location.origin === 'https://claude.ai' && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken && modelUsageLimited()
    && modelUserRoots().length === 0 && document.querySelectorAll('[data-testid="assistant-message"]').length === 0)
    return { error: 'website_usage_limit', freshQuotaAbort: true, url: document.URL, userCount: 0, responseCount: 0 };
  return { error: 'website_usage_limit' };
}
const normalizedBody = node => (node.innerText || node.textContent || '').replace(/\r\n?/g, '\n').normalize('NFC').trim();
let firstSnapshot = null, firstUserFingerprint = null, firstUserIdentity = null;
const snapshotUnchanged = (allowSubmittedUser = false) => {
  const current = modelUserRoots();
  return window === window.top && location.origin === 'https://claude.ai' && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken
    && (current.length === ownedUserCount || allowSubmittedUser && current.length === ownedUserCount + 1)
    && current[0] === firstSnapshot.root && firstSnapshot.body.isConnected
    && modelUserBody(current[0]) === firstSnapshot.body && normalizedBody(firstSnapshot.body) === firstSnapshot.text
    && firstSnapshot.root.closest('[id]')?.getAttribute('id') === firstSnapshot.identity;
};
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker, first = modelUserBody(ownedMessages[0]);
  const rendered = normalizedBody(first), markerLine = `Computa session marker: ${marker}`;
  const lines = rendered.split('\n');
  if (typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker)
    || globalThis.__computaModelFirstSubmitted !== true || globalThis.__computaModelFirstMarker !== marker
    || rendered.length > 180_200 || lines.at(-1) !== markerLine
    || lines.filter(line => line === markerLine).length !== 1 || !lines.slice(0, -1).join('\n').trim())
    return { error: 'conversation_changed', detail: 'first_user_message' };
  firstUserIdentity = ownedMessages[0].closest('[id]')?.getAttribute('id');
  if (typeof firstUserIdentity !== 'string' || !firstUserIdentity.length || firstUserIdentity.length > 256)
    return { error: 'conversation_changed', detail: 'first_user_message' };
  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered, identity: firstUserIdentity };
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
  if (!snapshotUnchanged()) return { error: 'conversation_changed', detail: 'first_user_message' };
  usageLimited = modelUsageLimited();
  if (!usageLimited && !modelTemporaryVerified()) return modelTemporaryFailure('temporary_mode_unverified');
  firstUserFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const pinned = globalThis.__computaModelFirstProof;
  if (pinned) {
    if (pinned.marker !== marker || pinned.fingerprint !== firstUserFingerprint
      || pinned.identity !== firstUserIdentity
      || input.expectedFirstUserFingerprint !== pinned.fingerprint
        && !(input.expectedFirstUserFingerprint == null && input.allowFirstUserBinding === true
          && input.action === 'inspect' && ownedUserCount === 1))
      return { error: 'conversation_changed', detail: 'first_user_message' };
  } else if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || ownedUserCount !== 1
    || input.expectedFirstUserFingerprint != null)
    return { error: 'conversation_changed', detail: 'first_user_message' };
} else if (input.expectedFirstUserFingerprint != null || globalThis.__computaModelFirstProof)
  return { error: 'conversation_changed', detail: 'first_user_message' };
if (usageLimited && input.action !== 'stop') return modelUsageLimitFailure();

async function providerPageAction() {
  const { action, prompt, expectedFirstUserMarker } = input;
  const usageLimited = modelUsageLimited();
  if (usageLimited && action !== 'stop') return modelUsageLimitFailure();
  const composer = modelFind(['[data-testid="chat-input"][contenteditable="true"][role="textbox"]']);
  const candidates = [...document.querySelectorAll('[data-testid="assistant-message"] [data-perf-reply-text]')].filter(modelVisible);
  const answers = candidates.filter(node => !candidates.some(other => other !== node && other.contains(node)));
  const answer = answers.at(-1), stop = modelFind(['button[aria-label="Stop response"]']);
  const status = modelFind(['[data-testid="response-status-announcer"][role="status"]']);
  const interrupted = !!status && !status.closest('[data-testid="assistant-message"], [data-testid="user-message"]')
    && (status.textContent || '').trim().replace(/’/g, "'") === "Claude's response was interrupted.";
  const streaming = [...document.querySelectorAll('[data-testid="assistant-message"][data-is-streaming="true"]')].some(modelVisible);
  const busy = !!stop || streaming;
  const message = answer?.closest('[data-testid="assistant-message"]');
  // The observed article is a DIV with this role, not necessarily an ARTICLE tag.
  const article = answer?.closest('[role="article"]');
  const copies = article && article.querySelectorAll('[data-testid="assistant-message"]').length === 1
    ? [...article.querySelectorAll('[data-testid="message-actions"] button[data-testid="action-bar-copy"][aria-label="Copy"]')] : [];
  const scopedCopies = copies.length, enabledCopies = copies.filter(modelEnabled).length;
  const answerComplete = !busy && !interrupted && message?.getAttribute('data-is-streaming') === 'false' && enabledCopies > 0;
  const temporary = modelTemporaryVerified();
  const temporaryActionAvailable = modelEnabled(modelFind(['button[aria-label="Use incognito"]']));
  const state = { url: document.URL, temporary, temporaryActionAvailable, conversationIdentity: null, composer: !!composer,
    responseCount: answers.length, userCount: ownedUserCount, firstUserIdentity, firstUserFingerprint,
    firstUserVerified: ownedUserCount > 0, firstUserMarkerVerified: ownedUserCount > 0,
    busy, interrupted, text: modelResponseText(answer).slice(0, 220_001),
    answerComplete, completionEvidence: { codeStructure: modelResponseStructure(answer), modernMarkers: 0, logicalAnswers: answers.length,
      scopedCopies, enabledCopies, depth: -1 } };
  if (action === 'inspect') {
    const signIn = !composer && [...document.querySelectorAll('a, button')].filter(modelVisible)
      .some(node => /^(?:Log in|Sign in)(?:\s|$)/i.test(node.getAttribute('aria-label') || (node.innerText || '').trim()));
    return { ...state, signIn, debugStructure: '', quotaDiagnostic: modelQuotaDiagnostic() };
  }
  if (action === 'enableTemporary') {
    if (temporary) return { ...state, enabled: true };
    if (ownedUserCount || answers.length || globalThis.__computaModelFirstSubmitted) return { error: 'not_fresh' };
    if (globalThis.__computaModelTemporaryRequested) return modelTemporaryFailure('temporary_mode_unverified');
    const toggle = modelFind(['button[aria-label="Use incognito"]']);
    if (!modelEnabled(toggle)) return modelTemporaryFailure('temporary_mode_unavailable');
    // Claim before the single click. A lost acknowledgment cannot toggle back.
    globalThis.__computaModelTemporaryRequested = true;
    toggle.click();
    return { ...state, enabled: false };
  }
  if (!temporary) return modelTemporaryFailure('temporary_mode_unverified');
  if (action === 'stop') {
    if (usageLimited) return { ...state, usageLimited: true, busy: false, stopped: false };
    if (modelEnabled(stop)) stop.click();
    return { ...state, stopped: !!stop };
  }
  if (!modelEnabled(composer) || busy) return { error: 'composer_unavailable' };
  const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
  if (action === 'prepare') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    if (ownedUserCount === 0) globalThis.__computaModelFirstPrepared = true;
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
        return { error: 'conversation_changed', detail: 'first_user_message' };
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
  const send = modelFind(['button[data-testid="chat-input-send"][aria-label="Send message"]']);
  if (action === 'sendReady') return { ...state, sendReady: modelEnabled(send) };
  if (!modelEnabled(send)) return { error: 'send_unavailable' };
  if (globalThis.__computaModelLastSubmissionCount !== undefined
    && ownedUserCount <= globalThis.__computaModelLastSubmissionCount)
    return { error: 'conversation_changed', detail: 'user_count' };
  if (ownedUserCount === 0) {
    if (globalThis.__computaModelFirstSubmitted || globalThis.__computaModelFirstPrompt !== prompt
      || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
      return { error: 'conversation_changed', detail: 'first_user_message' };
    globalThis.__computaModelFirstMarker = expectedFirstUserMarker;
    globalThis.__computaModelFirstSubmitted = true;
  }
  globalThis.__computaModelLastSubmissionCount = ownedUserCount;
  send.click();
  return { submitted: true };
}
const observed = await providerPageAction();
if (firstSnapshot) {
  if (!snapshotUnchanged(input.action === 'submit')) return { error: 'conversation_changed', detail: 'first_user_message' };
  if (observed.error === 'website_usage_limit' || input.action !== 'stop' && modelUsageLimited())
    return { error: 'website_usage_limit' };
  if (!modelTemporaryVerified()) return modelTemporaryFailure('temporary_mode_unverified');
  if (observed.error) return observed;
  if (!globalThis.__computaModelFirstProof) {
    if (observed.temporary !== true) return modelTemporaryFailure('temporary_mode_unverified');
    globalThis.__computaModelFirstProof = { marker: input.expectedFirstUserMarker, fingerprint: firstUserFingerprint,
      identity: firstUserIdentity };
  }
  // Submit intentionally exposes its acknowledgment only, as in the native contract.
  if (input.action === 'submit') return observed;
  return { ...observed, firstUserVerified: true, firstUserFingerprint, firstUserMarkerVerified: true };
}
if (observed.freshQuotaAbort === true) return observed;
return { ...observed, firstUserVerified: false, firstUserFingerprint: null };
