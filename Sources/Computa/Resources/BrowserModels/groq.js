// Small private-world primitives; provider DOM semantics remain in each adapter.
// Embedded verbatim in standalone adapters and checked by their fixture tests.
function computaProviderCore(request, provider, origin, actions) {
  const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
  const fail = (error, detail) => { throw { computaAdapterFailure: true, error, ...(detail ? { detail } : {}) }; };
  const normalize = value => typeof value === 'string' ? value.normalize('NFC').replace(/\s+/g, ' ').trim() : '';
  const bodyText = value => typeof value === 'string' ? value.replace(/\r\n?/g, '\n').normalize('NFC').trim() : '';
  const choiceValid = value => !!value && !Array.isArray(value) && typeof value === 'object'
    && Object.keys(value).length === 2 && typeof value.key === 'string' && typeof value.label === 'string'
    && value.key.length > 0 && new TextEncoder().encode(value.key).length <= 128
    && value.label.length > 0 && new TextEncoder().encode(value.label).length <= 128
    && normalize(value.key) === value.key && normalize(value.label) === value.label
    && !/[\p{Cc}\p{Cf}]/u.test(value.key + value.label);
  const equalChoice = (left, right) => choiceValid(left) && choiceValid(right)
    && left.key === right.key && left.label === right.label;
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && getComputedStyle(node).display !== 'none';
  const visible = node => physical(node) && !node.closest('[hidden], [inert], [aria-hidden="true"]');
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const nodes = (root, selector, maximum = 256) => {
    const found = [...root.querySelectorAll(selector)];
    if (found.length > maximum) fail('document_changed', 'structure_limit');
    return found;
  };
  const unique = (values, error = 'document_changed', detail = 'ambiguous_structure') => {
    if (values.length !== 1) fail(error, detail);
    return values[0];
  };
  const hitFailure = (node, testIntersection) => {
    if (!enabled(node)) return 'disabled';
    if (typeof node.getBoundingClientRect !== 'function' || typeof document.elementFromPoint !== 'function') return 'invalid_geometry';
    const r = node.getBoundingClientRect(), width = window.innerWidth, height = window.innerHeight;
    const right = r.left + r.width, bottom = r.top + r.height;
    if (![r.left, r.top, r.width, r.height, right, bottom, width, height].every(Number.isFinite)
      || r.width <= 0 || r.height <= 0 || width <= 0 || height <= 0) return 'invalid_geometry';
    // An expanding editor can extend above the viewport. Test one point in its
    // visible intersection; an overlay or ancestor clip still fails the hit.
    const left = Math.max(0, r.left), top = Math.max(0, r.top);
    const clippedRight = Math.min(width, right), clippedBottom = Math.min(height, bottom);
    if (clippedRight <= left || clippedBottom <= top) return 'outside_viewport';
    if (testIntersection) return testIntersection(left, top, clippedRight, clippedBottom) ? null : 'occluded';
    const x = left + (clippedRight - left) / 2, y = top + (clippedBottom - top) / 2;
    return node.contains(document.elementFromPoint(x, y)) ? null : 'occluded';
  };
  const hit = node => hitFailure(node) === null;
  const originalDocument = document, expectedURL = request.expectedURL;
  const context = () => request.provider === provider && window === window.top && document === originalDocument
    && location.origin === origin && document.URL === expectedURL
    && globalThis.__computaModelOwner === request.ownerToken;
  if (request.provider !== provider || window !== window.top || location.origin !== origin
    || typeof expectedURL !== 'string' || document.URL !== expectedURL) fail('document_changed', 'document_url');
  if (!actions.includes(request.action)) fail('unknown_action');
  if (!uuid(request.ownerToken) || !uuid(request.documentGeneration)) fail('document_changed', 'owner_token');
  if (globalThis.__computaModelOwner === undefined && request.bindOwner === true) globalThis.__computaModelOwner = request.ownerToken;
  if (!context()) fail('document_changed', 'owner_token');
  const assertContext = () => { if (!context()) fail('document_changed', 'document_url'); };
  const hash = async text => {
    if (typeof text !== 'string' || text.length > 180_200) fail('conversation_changed', 'first_user_message');
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
    assertContext();
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  };
  const signalKey = '__computaProviderChangeSignal';
  if (globalThis[signalKey]?.owner !== request.ownerToken || globalThis[signalKey]?.document !== originalDocument
    || globalThis[signalKey]?.url !== expectedURL) {
    globalThis[signalKey]?.observer?.disconnect?.();
    const record = { owner: request.ownerToken, document: originalDocument, url: expectedURL, observer: null };
    record.observer = new MutationObserver(() => {
      if (!context() || globalThis[signalKey] !== record) return;
      try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ ownerToken: record.owner, kind: 'dom_changed' }); }
      catch { /* Wakeups never grant model, response or action authority. */ }
    });
    record.observer.observe(document.documentElement || document, { subtree: true, childList: true,
      characterData: true, attributes: true, attributeFilter: ['disabled', 'aria-disabled', 'aria-hidden', 'aria-busy',
        'aria-label', 'aria-expanded', 'aria-controls', 'aria-selected', 'data-state', 'class', 'style', 'hidden', 'inert',
        ...(provider === 'kimi' ? ['role', 'contenteditable', 'data-lexical-editor', 'data-testid', 'aria-haspopup', 'id']
          : provider === 'qwen' ? ['role', 'aria-haspopup', 'id']
          : provider === 'deepseek' ? ['role', 'placeholder', 'aria-pressed'] : [])] });
    globalThis[signalKey] = record;
  }
  return { uuid, fail, normalize, bodyText, choiceValid, equalChoice, physical, visible, enabled, nodes, unique, hit, hitFailure, context, assertContext, hash };
}

// Groq chat is a fresh explicit-clear session, never a temporary conversation.
// The native transport owns lifecycle receipts, document generations and URLs.
const stateKey = '__computaGroqFreshSessionV1';
let groqUserCountDiagnostic = null;
let groqSession = globalThis[stateKey];
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'modelDiagnostic', 'verifyModel',
    'prepare', 'insert', 'sendReady', 'submit', 'stop', 'clearTranscript', 'observeClearTranscript'];
  const c = computaProviderCore(input, 'groq', 'https://chat.groq.com', actions);
  const url = new URL(document.URL), parameters = [...url.searchParams];
  if (url.pathname !== '/' || url.hash || url.username || url.password || url.port
    || parameters.length > 1 || parameters.some(([key]) => key !== 'model')) c.fail('document_changed', 'document_url');
  const modelKey = url.searchParams.get('model');
  const validKey = key => typeof key === 'string' && key.length > 0 && key.length <= 160
    && /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(key) && !key.includes('..') && !key.includes('//');
  if (modelKey !== null && !validKey(modelKey)) c.fail('model_unverified');
  if (globalThis[stateKey] === undefined) globalThis[stateKey] = { owner: input.ownerToken,
    document, generation: input.documentGeneration, url: null, mapping: null, picker: null,
    prepared: null, inserted: null, submitted: false, first: null, clear: null, sendReveal: null,
    renderedMessage: null, renderedMessageRevision: 0 };
  const state = globalThis[stateKey];
  groqSession = state;
  const owned = () => c.context() && globalThis[stateKey] === state && state.owner === input.ownerToken
    && state.document === document && state.generation === input.documentGeneration
    && (state.url === null && !state.picker && !state.prepared && !state.inserted && !state.submitted && !state.clear
      || state.url === document.URL);
  const guard = () => { if (!owned()) c.fail('document_changed', 'owner_token'); };
  const claimURL = () => { guard(); if (state.url === null) state.url = document.URL; };
  guard();
  const token = (node, value) => !!node?.classList.contains(value);
  const authored = node => !!node?.closest('[class*="group/input"], .font-inter, pre, code');
  const ordinaryChoice = choice => c.choiceValid(choice) && validKey(choice.key)
    // These are classification/safety models observed in the same picker, not agents.
    && !['meta-llama/llama-prompt-guard-2-22m', 'meta-llama/llama-prompt-guard-2-86m',
      'openai/gpt-oss-safeguard-20b'].includes(choice.key)
    && !/(?:^|\/)(?:whisper|distil-whisper|playai-tts|canopylabs\/orpheus)(?:[-/]|$)/i.test(choice.key);
  // The site's notification region was empty before the observed submission,
  // then displayed this exact generic failure. Its copy supplies no HTTP status.
  function notificationRegion(expected, failed = false) {
    try {
      const matches = document.querySelectorAll('[aria-label="Notifications alt+T"]');
      if (matches.length !== 1) return null;
      const region = matches[0];
      if (!region.isConnected || !document.documentElement.contains(region) || expected && region !== expected
        || region.closest('form, textarea, [contenteditable], [hidden], [inert], [aria-hidden="true"]')
        || authored(region) || region.contains(state.prepared)) return null;
      const stack = [region]; let visited = 0, messages = 0;
      while (stack.length) {
        const node = stack.pop();
        if (++visited > 48) return null;
        if (node.nodeType === 3) {
          if (node.length > 96) return null;
          const text = node.textContent.trim();
          if (!text) continue;
          if (!failed || text !== 'Something went wrong. Please, try again.' || ++messages > 1
            || !c.visible(node.parentElement) || authored(node.parentElement)) return null;
        } else if (node.nodeType === 1) {
          if (node.childNodes.length + stack.length + visited > 48) return null;
          for (const child of node.childNodes) stack.push(child);
        } else return null;
      }
      return messages === (failed ? 1 : 0) ? region : null;
    } catch { return null; }
  }
  function failUserCount(branch, users, answers) {
    // Snapshot the arrays from this rejected evaluation; no transcript reread.
    // Visibility is diagnostic only and unknown if its getters cannot be read.
    try {
      const visibleCount = nodes => { try { return nodes.filter(c.visible).length; } catch { return null; } };
      const expected = input.expectedUserCounts;
      const validExpected = Array.isArray(expected) && (expected.length === 1 && [0, 1].includes(expected[0])
        || expected.length === 2 && expected[0] === 0 && expected[1] === 1);
      const expectedUserCounts = validExpected ? [...expected] : null;
      const submitted = state.submitted === true, first = state.first, editor = state.prepared;
      const adapterFirstBound = !!first;
      const flag = read => { try { const value = read(); return typeof value === 'boolean' ? value : null; } catch { return null; } };
      const held = read => first ? flag(read) : null;
      const preparedEditorConnected = editor ? flag(() => editor.isConnected) : null;
      // Only compare the already-held editor and exact inserted string. A detached
      // editor is unknown, not evidence that the current page restored its draft.
      const preparedEditorDraftRestored = submitted && preparedEditorConnected === true
        && typeof state.inserted === 'string' ? flag(() => { const value = editor.value; return typeof value === 'string' ? value === state.inserted : null; }) : null;
      const boundNodes = {
        rootConnected: held(() => first.root.isConnected), bodyConnected: held(() => first.body.isConnected),
        parentConnected: held(() => first.parent.isConnected),
        rootClassMatches: held(() => first.root.classList.contains('group/input')),
        bodyClassMatches: held(() => first.body.classList.contains('line-clamp-5')),
        rootParentMatches: held(() => first.root.parentElement === first.parent),
        bodyWithinRoot: held(() => first.root.contains(first.body)),
        rootInDocument: held(() => document.documentElement.contains(first.root)),
        preparedEditorConnected, preparedEditorDraftRestored };
      groqUserCountDiagnostic = { kind: 'groq_user_count_v2', action: input.action, branch,
        userCount: users.length, answerCount: answers.length,
        visibleUserCount: visibleCount(users), visibleAnswerCount: visibleCount(answers),
        expectedUserCounts, submitted, adapterFirstBound, boundNodes };
      if (input.action === 'inspect' && branch === 'expected_count' && expectedUserCounts?.length === 1
        && expectedUserCounts[0] === 1 && users.length === 0 && answers.length === 0 && adapterFirstBound && submitted
        && preparedEditorDraftRestored === true && boundNodes.rootConnected === false && boundNodes.bodyConnected === false
        && boundNodes.parentConnected === false && boundNodes.rootInDocument === false && boundNodes.rootClassMatches === true
        && boundNodes.bodyClassMatches === true && boundNodes.rootParentMatches === true && boundNodes.bodyWithinRoot === true
        && state.emptyNotice && notificationRegion(state.emptyNotice, true))
        groqUserCountDiagnostic.freshNotice = 'generic_error';
    } catch { groqUserCountDiagnostic = null; }
    c.fail('conversation_changed', 'user_count');
  }
  function transcript() {
    const users = c.nodes(document, '[class*="group/input"]', 64).filter(node => token(node, 'group/input'));
    const answers = c.nodes(document, '.font-inter', 64).filter(node =>
      node.parentElement && token(node.parentElement, 'font-normal') && token(node.parentElement, 'text-base'));
    if (users.length > 1 || answers.length > 1)
      failUserCount(users.length > 1 ? 'multiple_users' : 'multiple_answers', users, answers);
    let first = null, answer = null, block = null;
    if (users.length) {
      const root = users[0], wrappers = [...root.children].filter(node => node.tagName === 'DIV'
        && token(node.children[0], 'line-clamp-5'));
      const wrapper = c.unique(wrappers, 'conversation_changed', 'first_user_message'), body = wrapper.children[0];
      // Long messages retain their complete leaf text and add this observed
      // presentation control. Never expand it or hash the wrapper's chrome.
      if (wrapper.children.length !== 1) {
        const more = wrapper.children[1];
        if (wrapper.children.length !== 2 || body.tagName !== 'DIV' || more.tagName !== 'SPAN'
          || more.children.length !== 0 || more.textContent !== 'Show more'
          || [...more.classList].length !== 2 || !token(more, 'text-primaryaccent') || !token(more, 'cursor-pointer')
          || more.getAttribute('role') !== null || more.getAttribute('aria-label') !== null || !c.visible(more)
          || c.nodes(root, '.line-clamp-5', 64).length !== 1
          || ![...wrapper.childNodes].every(node => node === body || node === more
            || node.nodeType === 3 && /^\s*$/.test(node.textContent || '')))
          c.fail('conversation_changed', 'first_user_message');
      }
      if (!c.visible(root) || !c.visible(body) || body.children.length > 0) c.fail('conversation_changed', 'first_user_message');
      const parent = root.parentElement;
      if (!token(parent, 'flex-col') || !token(parent, '[word-break:break-word]')) c.fail('conversation_changed', 'first_user_message');
      first = { root, body, parent, text: c.bodyText(body.textContent) };
      if (answers.length) {
        answer = answers[0]; block = answer.parentElement;
        if (block.parentElement !== parent || [...parent.children].indexOf(block) <= [...parent.children].indexOf(root)
          || !c.visible(answer) || !c.visible(block)) c.fail('conversation_changed', 'response_scope');
      }
    } else if (answers.length) failUserCount('answer_without_user', users, answers);
    return { users, answers, first, answer, block };
  }
  function composer() {
    const editors = c.nodes(document, 'textarea#chat', 8).filter(c.visible);
    const editor = c.unique(editors, 'composer_unavailable', editors.length ? 'editor_ambiguous' : 'editor_missing');
    const form = editor.closest('form');
    if (!form) c.fail('composer_unavailable', 'form_missing');
    if (!c.visible(form)) c.fail('composer_unavailable', 'form_hidden');
    if (c.nodes(form, 'textarea#chat', 4).filter(c.visible).length !== 1) c.fail('composer_unavailable', 'form_editor_count');
    const sends = c.nodes(form, 'button[type="submit"]', 8).filter(node => c.visible(node)
      && c.nodes(node, 'svg[aria-label="send"]', 4).length === 1);
    const send = c.unique(sends, 'send_unavailable', sends.length ? 'send_ambiguous' : 'send_missing');
    return { editor, form, send };
  }
  function picker() {
    const triggers = c.nodes(document, 'button[aria-haspopup="dialog"][aria-controls]', 64)
      .filter(node => !authored(node) && c.physical(node) && c.nodes(node, 'svg.lucide-chevrons-up-down', 4).length === 1);
    const trigger = c.unique(triggers, 'model_unverified');
    const controls = trigger.getAttribute('aria-controls');
    if (!controls || controls.length > 256 || /\s/.test(controls)) c.fail('model_unverified');
    const dialogs = c.nodes(document, '[role="dialog"]', 16).filter(node => c.physical(node) && !authored(node));
    const associated = dialogs.filter(node => node.getAttribute('id') === controls);
    if (associated.length > 1 || dialogs.some(node => !associated.includes(node))) c.fail('model_unverified');
    const dialog = associated[0] || null;
    const closed = !dialog && c.visible(trigger) && trigger.getAttribute('aria-expanded') === 'false'
      && trigger.getAttribute('data-state') === 'closed';
    const label = c.normalize(trigger.innerText || trigger.textContent);
    return { trigger, dialog, closed, label };
  }
  function menuChoices(dialog) {
    if (!c.visible(dialog)) c.fail('model_unverified');
    const search = c.unique(c.nodes(dialog, 'input[role="combobox"][cmdk-input]', 8).filter(c.visible), 'model_unverified');
    if (search.getAttribute('placeholder') !== 'Search Models...' || search.value !== '') c.fail('model_unverified');
    const lists = c.nodes(dialog, '[role="listbox"][cmdk-list]', 8).filter(node => c.visible(node)
      && node.getAttribute('id') === search.getAttribute('aria-controls'));
    const list = c.unique(lists, 'model_unverified');
    const options = c.nodes(list, '[role="option"][cmdk-item][data-value]', 64).filter(c.enabled);
    const choices = options.map(node => ({ key: node.getAttribute('data-value'), label: c.normalize(node.innerText || node.textContent) }));
    if (!choices.length || choices.some(choice => !c.choiceValid(choice) || !validKey(choice.key))
      || new Set(choices.map(choice => choice.key)).size !== choices.length
      || new Set(choices.map(choice => choice.label)).size !== choices.length) c.fail('model_unverified');
    return choices.filter(ordinaryChoice);
  }
  function selected() {
    const p = picker();
    if (!p.closed || !state.mapping) return null;
    const matches = state.mapping.filter(choice => choice.key === modelKey && choice.label === p.label);
    if (matches.length !== 1) return null;
    const choice = matches[0];
    if (input.expectedModelChoice != null && !c.equalChoice(input.expectedModelChoice, choice)) c.fail('model_mismatch');
    return { selected: choice, verification: 'website_selection', source: 'model_picker_label' };
  }
  function evidence(required = true) {
    const value = selected();
    if (!value && required) c.fail('model_unverified');
    return value;
  }
  function clearButtons() {
    return c.nodes(document, 'button', 128).filter(node => c.visible(node) && !authored(node)
      && c.normalize(node.innerText || node.textContent) === 'Clear chat');
  }
  function renderedMessageShape(answer, text) {
    const declined = reason => ({ witness: null, reason });
    if (answer.childNodes.length !== 1) return declined('answer_child_count');
    const paragraph = answer.childNodes[0];
    const kind = paragraph.nodeType;
    if (kind !== 1) return declined(kind === 3 ? 'answer_text_child' : 'answer_child_kind');
    if (paragraph.namespaceURI !== 'http://www.w3.org/1999/xhtml') return declined('paragraph_namespace');
    if (paragraph.tagName !== 'P') return declined('paragraph_tag');
    if (paragraph.childNodes.length !== 1) return declined('paragraph_child_count');
    if (paragraph.isContentEditable) return declined('paragraph_editable');
    if (!c.visible(paragraph)) return declined('paragraph_hidden');
    // Language and direction metadata do not add authored nodes or controls.
    // Only allow the known layout classes and closed passive HTML attributes.
    const attrs = paragraph.attributes;
    if (attrs.length > 8) return declined('attribute_count');
    for (const { namespaceURI, name, value } of attrs) {
      if (namespaceURI !== null) return declined('attribute_namespace');
      switch (name) {
        case 'class': {
          if (value.length > 64) return declined('attribute_value');
          const tokens = value.split(/[\t\n\f\r ]+/).filter(Boolean);
          if (tokens.length !== 2 || !tokens.includes('text-left') || !tokens.includes('mb-4'))
            return declined('attribute_value');
          break;
        }
        case 'dir':
          if (!['auto', 'ltr', 'rtl'].includes(value)) return declined('attribute_value');
          break;
        case 'lang':
          if (!/^[a-z]{2,8}(?:-[a-z0-9]{1,8}){0,5}$/i.test(value)) return declined('attribute_value');
          break;
        case 'id': return declined('attribute_id');
        case 'title': return declined('attribute_title');
        case 'role': return declined('attribute_role');
        case 'tabindex': return declined('attribute_tabindex');
        case 'contenteditable': return declined('attribute_contenteditable');
        case 'draggable': return declined('attribute_draggable');
        case 'align': return declined('attribute_align');
        case 'translate': return declined('attribute_translate');
        case 'spellcheck': return declined('attribute_spellcheck');
        case 'popover': return declined('attribute_popover');
        case 'onclick': case 'ondblclick': case 'oncontextmenu':
        case 'onkeydown': case 'onkeyup': case 'onfocus': case 'onblur':
        case 'oninput': case 'onchange': case 'onmousedown': case 'onmouseup':
        case 'onpointerdown': case 'onpointerup': case 'ontouchstart': case 'ontouchend':
          return declined('attribute_event_handler');
        default:
          if (name === 'style') return declined('attribute_style');
          if (name.startsWith('data-')) return declined('attribute_data');
          if (name.startsWith('aria-')) return declined('attribute_aria');
          return declined('attribute_name');
      }
    }
    const body = paragraph.childNodes[0];
    // Native checks message grammar. The paragraph profile never normalizes,
    // truncates or joins text to obtain a matching byte sequence.
    if (body.nodeType !== 3) return declined('leaf_not_text');
    if (body.textContent !== text) return declined('text_mismatch');
    return { witness: { answer, paragraph, body }, reason: 'matched' };
  }
  function responseText(answer) {
    const structure = { kind: 'groq_literal_profile_v1', reason: 'absent_answer', preCount: 0, codeCount: 0, scanCount: 0 };
    const result = (text, literal, reason) => { structure.reason = reason; return { text, literal, structure }; };
    if (!answer) return result('', false, 'absent_answer');
    // These closed facts report the first original predicate only. They never
    // read extra DOM/text or participate in literal/completion acceptance.
    const fallback = reason => result((answer.textContent || '').trim().slice(0, 220_001), false, reason);
    const decline = (value, reason) => { if (value) structure.reason = reason; return value; };
    const pres = c.nodes(answer, 'pre', 64), codes = c.nodes(answer, 'code', 64);
    structure.preCount = pres.length; structure.codeCount = codes.length;
    if (decline(pres.length !== 2, 'pre_count') || decline(codes.length !== 1, 'code_count')) return fallback(structure.reason);
    const outer = pres[0], inner = pres[1], code = codes[0], wrapper = inner.parentElement;
    if (decline(outer.parentElement !== answer, 'outer_parent') || decline(wrapper?.tagName !== 'DIV', 'wrapper_tag')
      || decline(wrapper.parentElement !== outer, 'wrapper_parent') || decline(code.parentElement !== inner, 'code_parent')
      || decline(!token(code, 'language-json'), 'language_json') || decline(!c.visible(code), 'code_hidden')
      || decline(outer.children.length !== 1, 'outer_children') || decline(wrapper.children.length !== 2, 'wrapper_children')
      || decline(inner.children.length !== 1, 'inner_children')) return fallback(structure.reason);
    const chrome = [...wrapper.children].find(node => node !== inner);
    if (decline(chrome?.tagName !== 'DIV', 'chrome_tag') || decline(!['w-min', 'ml-2', 'cursor-pointer', 'absolute', 'top-2', 'right-2', 'text-sm', 'px-2']
      .every(value => token(chrome, value)), 'chrome_classes') || decline(!c.visible(chrome), 'chrome_hidden')
      || decline(chrome.children.length !== 1, 'chrome_children')
      || decline(chrome.children[0].tagName.toLowerCase() !== 'svg', 'chrome_icon_tag')
      || decline(chrome.children[0].getAttribute('aria-label') !== 'copy', 'chrome_icon_label')
      || decline((chrome.textContent || '').trim() !== '', 'chrome_text')) return fallback(structure.reason);
    let visited = 0;
    const onlyLiteralAndChrome = node => {
      if (++visited > 10_000) return false;
      if (node === code || node === chrome) return true;
      if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
      if (node.nodeType !== 1) return true;
      return [...node.childNodes].every(onlyLiteralAndChrome);
    };
    // Preserve hidden/visible authored content and the original scan bound.
    const isolated = onlyLiteralAndChrome(answer); structure.scanCount = visited;
    if (!isolated) return fallback(visited > 10_000 ? 'outside_scan_limit' : 'outside_content');
    return result((code.textContent || '').slice(0, 220_001), true, 'accepted_literal_code');
  }
  function responseComplete(t, form, text, progress) {
    // Record only the first failed operand, at its original evaluation point.
    // This optional report never participates in completion or ownership.
    const no = reason => { if (progress) progress.reason = reason; return false; };
    if (!state.submitted) return no('not_submitted');
    if (state.clear) return no('cleared');
    if (!t.first) return no('user_absent');
    if (!t.answer) return no('answer_absent');
    if (!text.trim()) return no('text_empty');
    if (!c.enabled(form.editor)) return no('editor_disabled');
    if (form.editor.value !== '') return no('editor_not_empty');
    if (!c.enabled(form.send)) return no('send_disabled');
    const siblings = [...t.block.children], footer = siblings[siblings.indexOf(t.answer) + 1];
    if (footer?.tagName !== 'DIV') return no('footer_missing');
    if (!['flex', 'flex-row', 'align-center', 'items-center', 'gap-1', 'pt-2']
      .every(value => token(footer, value))) return no('footer_shape');
    if (!c.visible(footer)) return no('footer_hidden');
    const copies = c.nodes(t.block, 'button', 32).filter(node =>
      c.nodes(node, 'svg[aria-label="copy"]', 4).length > 0 && !t.answer.contains(node));
    if (copies.length !== 1) return no('copy_count');
    if (copies[0].parentElement !== footer) return no('copy_parent');
    if (!c.enabled(copies[0])) return no('copy_disabled');
    if (c.nodes(copies[0], 'svg[aria-label="copy"]', 4).length !== 1) return no('copy_icon_count');
    if (progress) progress.reason = 'complete';
    return true;
  }
  function read() {
    const t = transcript(), form = composer(), modelEvidence = evidence(false);
    const progress = input.action === 'inspect'
      && Object.getOwnPropertyDescriptor(input, 'groqFailureProgress')?.value === true ? { reason: null } : null;
    const extracted = responseText(t.answer), text = extracted.text, answerComplete = responseComplete(t, form, text, progress);
    const rendered = answerComplete && !extracted.literal && (input.action === 'inspect' || state.renderedMessage)
      ? renderedMessageShape(t.answer, text) : null;
    const renderedMessage = rendered?.witness ?? null;
    const prior = state.renderedMessage;
    if (prior && (!renderedMessage || prior.answer !== renderedMessage.answer || prior.paragraph !== renderedMessage.paragraph
      || prior.body !== renderedMessage.body)) state.renderedMessage = null;
    // The terminal conjunction is answer-scoped footer Copy plus an empty,
    // enabled composer and enabled Send. Global speed/code-copy grant nothing.
    return { t, form, renderedMessage, renderedMessageReason: rendered?.reason,
      output: { url: document.URL, sessionLifecycle: 'explicit_clear', temporary: false,
      modelEvidence, composer: c.enabled(form.editor), userCount: t.users.length, responseCount: t.answers.length,
      conversationIdentity: null, busy: !answerComplete && (t.users.length > 0 || state.submitted && !state.clear),
      interrupted: false, answerComplete, text, groqLiteralResponse: extracted.literal,
      completionEvidence: { codeStructure: extracted.structure },
      ...(progress ? { groqFailureProgress: { kind: 'groq_completion_gate_v1', reason: progress.reason } } : {}),
      firstUserIdentity: null, firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null } };
  }
  // React can mount the composer before the picker and canonical model query.
  // Before any action, report only pending; do not fabricate empty transcript,
  // selected-model, URL or generation-binding evidence for native readiness.
  if (state.url === null && ['inspect', 'discoverModels', 'selectModel'].includes(input.action)) {
    const editors = c.nodes(document, 'textarea#chat', 8).filter(c.visible);
    const triggers = c.nodes(document, 'button[aria-haspopup="dialog"][aria-controls]', 64)
      .filter(node => !authored(node) && c.physical(node) && c.nodes(node, 'svg.lucide-chevrons-up-down', 4).length === 1);
    if (editors.length > 1 || triggers.length > 1) c.fail('document_changed', 'ambiguous_structure');
    if (modelKey === null || editors.length === 0 || triggers.length === 0) {
      const current = transcript();
      if (current.users.length || current.answers.length) c.fail('not_fresh');
      return { pending: true, sessionLifecycle: 'explicit_clear', temporary: false, composer: false };
    }
  }
  const initial = read();
  const fresh = () => !state.submitted && !state.first && !state.clear && transcript().users.length === 0
    && transcript().answers.length === 0 && composer().editor.value === '';
  const sameFirst = first => {
    guard();
    const current = transcript().first;
    return !!current && current.root === first.root && current.body === first.body && current.parent === first.parent && current.text === first.text;
  };
  const clearActions = ['clearTranscript', 'observeClearTranscript'];
  if (clearActions.includes(input.action)) {
    const operation = input.clearOperation, keys = ['id', 'documentGeneration', 'sequence', 'firstUserFingerprint'];
    if (!operation || typeof operation !== 'object' || Array.isArray(operation) || Object.keys(operation).length !== keys.length
      || !keys.every(key => Object.hasOwn(operation, key)) || !c.uuid(operation.id)
      || operation.documentGeneration !== input.documentGeneration || operation.sequence !== 1
      || typeof operation.firstUserFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(operation.firstUserFingerprint)
      || input.expectedFirstUserFingerprint !== operation.firstUserFingerprint) c.fail('conversation_changed', 'clear_operation');
    const model = evidence();
    if (!state.clear) {
      if (input.action !== 'clearTranscript' || !state.submitted || !state.first
        || state.first.fingerprint !== operation.firstUserFingerprint || input.expectedFirstUserFingerprint !== operation.firstUserFingerprint
        || !sameFirst(state.first)) c.fail('conversation_changed', 'clear_ownership');
      const digest = await c.hash(state.first.text);
      if (!sameFirst(state.first) || digest !== operation.firstUserFingerprint || !c.equalChoice(evidence().selected, model.selected)) c.fail('conversation_changed', 'clear_ownership');
      const button = c.unique(clearButtons(), 'conversation_changed', 'clear_control');
      if (!c.hit(button) && typeof button.scrollIntoView === 'function') {
        // A long owned answer may put this exact control below the viewport.
        // Scrolling grants no click authority; recheck the original target and
        // all ownership evidence before using the resulting hit test.
        button.scrollIntoView({ block: 'center', inline: 'nearest' });
        guard();
        if (!sameFirst(state.first) || c.unique(clearButtons(), 'conversation_changed', 'clear_control') !== button
          || !c.equalChoice(evidence().selected, model.selected)) c.fail('conversation_changed', 'clear_ownership');
      }
      if (!c.hit(button) || !c.enabled(initial.form.editor)) c.fail('conversation_changed', 'clear_control');
      const before = transcript();
      state.clear = { ...operation, owner: state.owner, url: document.URL, model: model.selected,
        removedNodes: [before.first.root, before.first.body, before.first.parent, before.answer, before.block].filter(Boolean),
        clickAcknowledged: false };
      button.click();
      state.clear.clickAcknowledged = true;
    }
    const record = state.clear;
    if (!keys.every(key => record[key] === operation[key]) || record.owner !== input.ownerToken
      || record.url !== document.URL || !c.equalChoice(record.model, evidence().selected)) c.fail('conversation_changed', 'clear_operation');
    guard();
    const current = read(), empty = current.t.users.length === 0 && current.t.answers.length === 0
      && current.form.editor.value === '' && c.enabled(current.form.editor) && clearButtons().length === 0
      && record.removedNodes.every(node => !node.isConnected);
    return { ...current.output, clearProof: { ...operation, clickAcknowledged: record.clickAcknowledged, transcriptEmpty: record.clickAcknowledged && empty } };
  }
  if (state.clear) c.fail('conversation_changed', 'cleared_session');
  if (!Array.isArray(input.expectedUserCounts) || input.expectedUserCounts.length < 1 || input.expectedUserCounts.length > 2
    || input.expectedUserCounts.some(value => !Number.isInteger(value) || value < 0 || value > 1)
    || input.expectedUserCounts.length === 2 && (input.expectedUserCounts[0] !== 0 || input.expectedUserCounts[1] !== 1)
    || !input.expectedUserCounts.includes(initial.t.users.length))
    failUserCount('expected_count', initial.t.users, initial.t.answers);
  if (state.submitted && !initial.output.modelEvidence) c.fail('model_unverified');
  if (initial.t.first) {
    const first = initial.t.first, marker = input.expectedFirstUserMarker, markerLine = `Computa session marker: ${marker}`;
    if (!c.uuid(marker) || !state.submitted || state.marker !== marker || first.text !== c.bodyText(state.inserted)
      || first.text.split('\n').at(-1) !== markerLine || first.text.split('\n').filter(line => line === markerLine).length !== 1
      || !first.text.slice(0, -markerLine.length).trim()) c.fail('conversation_changed', 'first_user_message');
    const fingerprint = await c.hash(first.text);
    if (!sameFirst(first)) c.fail('conversation_changed', 'first_user_message');
    if (!c.equalChoice(evidence().selected, initial.output.modelEvidence?.selected)) c.fail('model_mismatch');
    if (state.first) {
      if (state.first.fingerprint !== fingerprint || !sameFirst(state.first)
        || input.expectedFirstUserFingerprint !== fingerprint && !(input.action === 'inspect' && input.allowFirstUserBinding === true
          && input.expectedFirstUserFingerprint == null)) c.fail('conversation_changed', 'first_user_message');
    } else {
      if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null) c.fail('conversation_changed', 'first_user_message');
      state.first = { ...first, fingerprint };
    }
    // Hashing yields to the page. Use a fresh terminal observation afterward;
    // a pre-yield enabled footer/composer must not survive resumed streaming.
    const current = read();
    if (!sameFirst(first) || !c.equalChoice(current.output.modelEvidence?.selected, initial.output.modelEvidence?.selected))
      c.fail('conversation_changed', 'first_user_message');
    Object.assign(initial.output, current.output,
      { firstUserVerified: true, firstUserMarkerVerified: true, firstUserFingerprint: fingerprint });
    // Issue the witness only from the post-hash owned inspection. Losing the
    // shape even on the pre-hash read invalidates its old revision.
    if (input.action === 'inspect' && current.renderedMessage) {
      if (!state.renderedMessage && state.renderedMessageRevision < 1024) {
        state.renderedMessage = current.renderedMessage;
        state.renderedMessageRevision++;
      }
      if (state.renderedMessage) initial.output.groqRenderedMessageRevision = state.renderedMessageRevision;
    }
    if (input.action === 'inspect' && current.renderedMessageReason) {
      initial.output.groqRenderedMessageShape = current.renderedMessage && !state.renderedMessage
        ? 'revision_exhausted' : current.renderedMessageReason;
    }
  } else if (state.first || input.expectedFirstUserFingerprint != null) c.fail('conversation_changed', 'first_user_message');
  if (['discoverModels', 'selectModel'].includes(input.action)) {
    if (!fresh()) c.fail('not_fresh');
    if (input.action === 'selectModel' && (!c.choiceValid(input.modelChoice) || input.modelChoice.key !== modelKey)) c.fail('model_mismatch');
    const p = picker();
    if (!state.picker) {
      if (!p.closed || !c.hit(p.trigger)) c.fail('model_unverified');
      claimURL();
      state.picker = { trigger: p.trigger, stage: 'opening', choices: null };
      p.trigger.click();
      return { ...initial.output, pending: true };
    }
    if (state.picker.trigger !== p.trigger) c.fail('model_unverified');
    if (state.picker.stage === 'opening') {
      if (!p.dialog) return { ...initial.output, pending: true };
      const choices = menuChoices(p.dialog);
      if (!choices.length || choices.length > 32) c.fail('model_unverified');
      state.picker.choices = choices; state.picker.stage = 'closing';
      if (typeof window.KeyboardEvent !== 'function') c.fail('model_unverified');
      p.dialog.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true, cancelable: true }));
      return { ...initial.output, pending: true };
    }
    if (!p.closed) return { ...initial.output, pending: true };
    state.mapping = state.picker.choices;
    const observed = evidence(input.action === 'selectModel');
    if (input.action === 'selectModel' && !c.equalChoice(observed?.selected, input.modelChoice)) c.fail('model_mismatch');
    return { ...initial.output, modelChoices: state.mapping, modelEvidence: observed, ...(input.action === 'selectModel' ? { selected: true } : {}) };
  }
  if (input.action === 'modelDiagnostic') return { ...initial.output, modelDiagnostic: { kind: 'groq_model_picker_v1', mappingKnown: !!state.mapping, closed: picker().closed } };
  if (input.action === 'inspect') return initial.output;
  const model = evidence();
  if (input.action === 'verifyModel') return { ...initial.output, modelEvidence: model };
  if (input.action === 'stop') return { ...initial.output, modelEvidence: model, stopped: false };
  const form = composer();
  // Finite details identify the actual rejecting predicate without logging
  // page text, URLs or input. Preserve the original short-circuit order.
  if (!c.enabled(form.editor)) c.fail('composer_unavailable', 'editor_disabled');
  if (!c.hit(form.editor)) c.fail('composer_unavailable', 'editor_hit_test');
  if (!fresh() && !state.inserted) c.fail('composer_unavailable', 'editor_not_fresh');
  if (input.action === 'prepare') {
    if (!fresh() || state.prepared) c.fail('composer_not_empty');
    claimURL();
    state.prepared = form.editor;
    form.editor.focus();
    guard(); evidence();
    if (composer().editor !== form.editor || form.editor.value !== '') c.fail('composer_not_empty');
    return { ...initial.output, prepared: document.activeElement === form.editor };
  }
  const prompt = input.prompt, marker = input.expectedFirstUserMarker;
  if (typeof prompt !== 'string' || !prompt.trim() || prompt.length > 180_000 || !c.uuid(marker)
    || !prompt.endsWith(`\n\nComputa session marker: ${marker}`)) c.fail('prompt_not_inserted');
  if (input.action === 'insert') {
    if (!fresh() || state.inserted || state.prepared !== form.editor || document.activeElement !== form.editor) c.fail('composer_not_empty');
    state.inserted = prompt; state.marker = marker;
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (!setter) c.fail('insert_command_rejected');
    setter.call(form.editor, prompt);
    form.editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
    guard(); evidence();
    if (composer().editor !== form.editor || form.editor.value !== prompt) c.fail('prompt_not_inserted');
    return { ...initial.output, inserted: true };
  }
  if (state.submitted || state.inserted !== prompt || form.editor.value !== prompt || transcript().users.length !== 0) c.fail('prompt_not_inserted');
  const validateReveal = record => {
    guard();
    const current = composer();
    if (state.sendReveal !== record || state.prepared !== record.editor || state.submitted || state.first || state.clear
      || current.editor !== record.editor || current.form !== record.form || current.send !== record.send)
      c.fail('conversation_changed', 'send_reveal_target');
    if (state.inserted !== record.prompt || prompt !== record.prompt || current.editor.value !== record.prompt
      || state.marker !== marker || transcript().users.length !== 0) c.fail('prompt_not_inserted');
    if (!c.equalChoice(evidence().selected, record.model)) c.fail('model_mismatch');
  };
  if (state.sendReveal) {
    if (state.sendReveal.status !== 'verified') c.fail('send_unavailable', 'reveal_unconfirmed');
    validateReveal(state.sendReveal);
  }
  // Retain only the fixed reason from this actual decision. A later geometry
  // probe could disagree with the check that prevented this Send.
  let sendReadinessFailure = c.hitFailure(form.send) ?? (c.enabled(form.editor) ? null : 'disabled');
  if (input.action === 'sendReady' && sendReadinessFailure === 'outside_viewport' && !state.sendReveal
    && typeof form.send.scrollIntoView === 'function') {
    if (state.prepared !== form.editor) c.fail('conversation_changed', 'send_reveal_target');
    // Claim before scrolling: lost acknowledgments and failed rechecks never
    // permit another reveal. This neither reinserts text nor dispatches Send.
    const record = { editor: form.editor, form: form.form, send: form.send, prompt,
      model: model.selected, status: 'attempting', diagnostic: null };
    state.sendReveal = record;
    try { form.send.scrollIntoView({ block: 'center', inline: 'nearest' }); }
    catch { record.status = 'failed'; c.fail('send_unavailable', 'reveal_unconfirmed'); }
    try {
      validateReveal(record);
      if (!c.enabled(form.editor)) c.fail('composer_unavailable', 'editor_disabled');
      if (!c.hit(form.editor)) c.fail('composer_unavailable', 'editor_hit_test');
      sendReadinessFailure = c.hitFailure(form.send) ?? (c.enabled(form.editor) ? null : 'disabled');
      record.diagnostic = { before: 'outside_viewport', after: sendReadinessFailure, attempted: true };
      record.status = 'verified';
    } catch (error) { record.status = 'failed'; throw error; }
  }
  const ready = sendReadinessFailure === null;
  if (input.action === 'sendReady') return { ...initial.output, sendReady: ready, sendReadinessFailure,
    ...(state.sendReveal?.diagnostic ? { sendRevealDiagnostic: state.sendReveal.diagnostic } : {}) };
  if (!ready) c.fail('send_unavailable', sendReadinessFailure);
  state.emptyNotice = notificationRegion(null);
  state.submitted = true;
  form.send.click();
  // This is the pre-click empty observation plus dispatch acknowledgment. It
  // cannot bind the newly appended user body or prove response completion.
  return { ...initial.output, submitted: true };
} catch (error) {
  if (groqSession) groqSession.renderedMessage = null;
  if (error?.computaAdapterFailure === true) return { error: error.error, ...(error.detail ? { detail: error.detail } : {}),
    ...(error.error === 'conversation_changed' && error.detail === 'user_count' && groqUserCountDiagnostic
      ? { groqUserCountDiagnostic } : {}) };
  throw error;
}
