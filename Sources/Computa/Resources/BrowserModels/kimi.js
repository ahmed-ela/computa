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
  const hitFailure = node => {
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
        'aria-label', 'aria-expanded', 'aria-controls', 'aria-selected', 'data-state', 'class', 'style', 'hidden', 'inert'] });
    globalThis[signalKey] = record;
  }
  return { uuid, fail, normalize, bodyText, choiceValid, equalChoice, physical, visible, enabled, nodes, unique, hit, hitFailure, context, assertContext, hash };
}

// Kimi saved-conversation adapter. Uses the exact embedded-provider-core.js prefix.
// Saved conversations require an explicit confirmed deletion, never temp mode.
let kimiDraftState = null;
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'prepare',
    'insert', 'sendReady', 'submit', 'stop', 'deleteConversation', 'selectConversationDeletion',
    'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'kimi', 'https://www.kimi.ai', actions);
  const visible = (root, selector, max = 256) => c.nodes(root, selector, max).filter(c.visible);
  const one = (nodes, detail) => c.unique(nodes, 'document_changed', detail);
  const authored = node => !!node.closest('.chat-content-item');
  const key = '__computaKimiSavedSessionV1';
  if (globalThis[key] === undefined) globalThis[key] = { owner: input.ownerToken,
    document, window, generation: input.documentGeneration, model: null, selection: null,
    prepared: null, inserted: null, submitted: false, first: null, provisional: null,
    canonical: null, deletion: null, terminal: false };
  const state = globalThis[key];
  kimiDraftState = state;
  const deletionActionNames = ['deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  // Native-only cleanup inspection preserves full identity/model checks but
  // cannot publish an answer. It is not an alternate inference parser.
  const cleanupInspection = input.action === 'inspect' && input.kimiCleanupInspection === true;
  const guard = () => {
    c.assertContext();
    if (globalThis[key] !== state || state.owner !== input.ownerToken || state.document !== document
      || state.window !== window || state.generation !== input.documentGeneration)
      c.fail('document_changed', 'owner_token');
  };
  guard();
  if (state.terminal) c.fail('conversation_changed', 'terminal_operation');
  const currentRoute = () => {
    const url = new URL(document.URL), items = [...url.searchParams];
    if (url.origin !== 'https://www.kimi.ai' || url.port || url.username || url.password || url.hash
      || items.length > 1 || items.some(([name, value]) => name !== 'chat_enter_method' || value !== 'home'))
      c.fail('document_changed', 'document_url');
    if (url.pathname === '/' && items.length === 0) return { kind: 'fresh', path: '/', canonical: null };
    const suffix = url.pathname.startsWith('/chat/') ? url.pathname.slice(6) : '';
    if (c.uuid(suffix)) return { kind: 'canonical', path: url.pathname, canonical: url.origin + url.pathname };
    // The observed provisional ID replaces the first UUID character with p.
    // It is never promoted into conversation identity or cleanup authority.
    if (/^p[a-f0-9]{7}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(suffix))
      return { kind: 'provisional', path: url.pathname, canonical: null };
    c.fail('conversation_changed', 'conversation_url');
  };
  const route = currentRoute();
  if (!state.submitted && route.kind !== 'fresh') c.fail('not_fresh');
  if (state.submitted && !state.deletion?.confirmAcknowledged) {
    if (route.kind === 'provisional') {
      if (state.canonical || state.provisional && state.provisional !== route.path) c.fail('conversation_changed', 'conversation_url');
      state.provisional = route.path;
    } else if (route.kind === 'canonical') {
      if (state.canonical && state.canonical !== route.canonical) c.fail('conversation_changed', 'conversation_url');
      state.canonical = route.canonical;
    } else if (state.canonical || state.provisional) c.fail('conversation_changed', 'conversation_url');
  }
  if (input.expectedConversation != null && input.expectedConversation !== state.canonical)
    c.fail('conversation_changed', 'conversation_url');

  function composerText(editor) {
    // Live Lexical insertText settles asynchronously into one P[dir=ltr]
    // containing a data-lexical-text span whose text retains literal newlines.
    // The empty P/BR and synthetic WebKit P/text shapes are separately tested.
    // Read only those structures; never trim, normalize or repair payload bytes.
    const paragraphs = [...editor.childNodes], lines = [];
    let nodes = paragraphs.length, bytes = 0;
    if (nodes > 180_201) c.fail('composer_unavailable');
    for (const paragraph of paragraphs) {
      if (paragraph.nodeType !== 1 || paragraph.tagName !== 'P' || !c.visible(paragraph)
        || paragraph.getAttribute('contenteditable') != null) c.fail('composer_unavailable');
      const children = [...paragraph.childNodes];
      nodes += children.length;
      if (nodes > 360_402) c.fail('composer_unavailable');
      const emptyBreak = children.length === 1 && children[0].nodeType === 1 && children[0].tagName === 'BR'
        && children[0].childNodes.length === 0 && c.visible(children[0]);
      const span = children.length === 1 && children[0].nodeType === 1 && children[0].tagName === 'SPAN' ? children[0] : null;
      if (span) {
        nodes += span.childNodes.length;
        if (nodes > 360_402) c.fail('composer_unavailable');
      }
      const lexical = span && paragraphs.length === 1 && paragraph.getAttribute('dir') === 'ltr'
        && span.getAttribute('data-lexical-text') === 'true' && span.getAttribute('contenteditable') == null
        && c.visible(span) && span.childNodes.length > 0 && [...span.childNodes].every(node => node.nodeType === 3);
      if (!emptyBreak && !lexical && (!children.length || children.some(node => node.nodeType !== 3))) c.fail('composer_unavailable');
      const line = emptyBreak ? '' : lexical ? span.textContent : children.map(node => node.textContent).join('');
      bytes += new TextEncoder().encode(line).length + (lines.length ? 1 : 0);
      if (bytes > 180_200) c.fail('composer_unavailable');
      lines.push(line);
    }
    return lines.join('\n');
  }
  function composer() {
    const editor = one(visible(document, '.chat-input-editor[contenteditable="true"][role="textbox"][data-lexical-editor="true"]'), 'composer');
    const scope = editor.closest('.chat-editor-input-wrap');
    if (!scope || !c.visible(scope) || authored(editor)
      || c.nodes(scope, '.chat-input-editor[contenteditable="true"]').length !== 1) c.fail('composer_unavailable');
    const send = one(visible(document, 'div.send-button-container').filter(node => !authored(node)), 'send_control');
    const icons = c.nodes(send, 'svg.send-icon[name="Send"]');
    const text = composerText(editor), empty = text === '';
    return { editor, scope, send, text, empty, sendIcon: icons.length === 1 && c.visible(icons[0]),
      sendEnabled: icons.length === 1 && !send.classList.contains('disabled') && c.enabled(send) };
  }
  function picker() {
    const trigger = one(visible(document, 'div.current-model[data-testid="model-select-trigger"][aria-haspopup="menu"]')
      .filter(node => !authored(node)), 'model_trigger');
    const id = trigger.getAttribute('id'), controlled = trigger.getAttribute('aria-controls');
    if (!id || !controlled || /\s/.test(id + controlled)) c.fail('model_unverified');
    const label = one(visible(trigger, '.model-name .name'), 'model_label');
    if (label.children.length !== 0) c.fail('model_unverified');
    const menus = visible(document, 'div.kimi-menu-positioner[role="menu"]').filter(node => !authored(node));
    const matches = menus.filter(node => node.getAttribute('id') === controlled);
    if (matches.length > 1) c.fail('model_unverified');
    const menu = matches[0] || null;
    if (menu && (menu.getAttribute('aria-labelledby') !== id || menus.length !== 1
      || trigger.getAttribute('aria-expanded') !== 'true')) c.fail('model_unverified');
    const ownedDeleteMenu = state.deletion && menus.length === 1
      && menus[0].getAttribute('id') === state.deletion.menuID
      && menus[0].getAttribute('aria-labelledby') === state.deletion.headerID;
    const closed = !menu && (menus.length === 0 || ownedDeleteMenu) && trigger.getAttribute('aria-expanded') === 'false';
    return { trigger, menu, closed, label: c.normalize(label.textContent) };
  }
  function choices(menu) {
    const list = one(visible(menu, '.model-list-options[data-testid="model-list-options"]'), 'model_list');
    const rows = visible(list, 'button[data-testid="model-option"][role="menuitemradio"]', 32);
    const result = rows.map(node => {
      const label = one(visible(node, '.model-name .name'), 'model_label');
      const choice = { key: node.getAttribute('data-moon-key'), label: c.normalize(label.textContent) };
      const checked = node.getAttribute('aria-checked');
      if (label.children.length !== 0 || !c.choiceValid(choice) || !c.enabled(node)
        || !['agent', 'plain-chat'].includes(node.getAttribute('data-model-family'))
        || !['true', 'false'].includes(checked)) c.fail('model_unverified');
      return { node, choice, family: node.getAttribute('data-model-family'), checked: checked === 'true' };
    });
    if (!result.length || new Set(result.map(row => row.choice.key)).size !== result.length
      || new Set(result.map(row => row.choice.label)).size !== result.length
      || result.filter(row => row.checked).length !== 1) c.fail('model_unverified');
    return result;
  }
  function modelEvidence(required = true) {
    const p = picker(), selected = state.model?.choice;
    if (!selected || !p.closed || p.trigger !== state.model.trigger || p.label !== selected.label) {
      if (required) c.fail('model_unverified'); else return null;
    }
    if (input.expectedModelChoice != null && !c.equalChoice(selected, input.expectedModelChoice)) c.fail('model_mismatch');
    return { selected, verification: 'website_selection', source: 'model_picker_label' };
  }
  function transcript() {
    const users = c.nodes(document, '.chat-content-item.chat-content-item-user', 32);
    const answers = c.nodes(document, '.chat-content-item.chat-content-item-assistant', 32);
    if (users.length > 1 || answers.length > 1 || answers.length > users.length) c.fail('conversation_changed', 'user_count');
    let first = null, answer = null;
    if (users.length) {
      const root = users[0], id = root.getAttribute('data-archer-id');
      const body = one(visible(root, '.user-content .user-content__text'), 'first_user_message');
      if (!c.visible(root) || !c.uuid(id) || root.getAttribute('data-conversation-turn-id') !== id
        || body.tagName !== 'SPAN' || body.children.length !== 0) c.fail('conversation_changed', 'first_user_message');
      first = { root, body, id, text: body.textContent };
      if (answers.length) {
        answer = answers[0];
        if (!c.visible(answer) || !c.uuid(answer.getAttribute('data-archer-id'))
          || answer.getAttribute('data-archer-id') === id || answer.parentElement !== root.parentElement
          || [...root.parentElement.children].indexOf(answer) <= [...root.parentElement.children].indexOf(root))
          c.fail('conversation_changed', 'response_scope');
      }
    }
    return { users, answers, first, answer };
  }
  function sameFirst(first) {
    guard(); const now = transcript().first;
    return !!now && ['root', 'body', 'id', 'text'].every(key => now[key] === first[key]);
  }
  function authoredText(answer) {
    if (!answer) return { text: '', finalMarkup: false };
    const box = one(c.nodes(answer, '.segment-content-box'), 'response_content');
    const markdowns = c.nodes(box, '.markdown');
    const knownReasoning = node => node.nodeType === 1
      && (node.classList.contains('toolcall-flow') || node.classList.contains('thinking-container'))
      && node.parentElement?.classList.contains('toolcall-rollup__part')
      && !node.closest('.markdown');
    // Reconstructing text from disjoint blocks can turn malformed site output
    // into a valid tool envelope. Unknown/prose/multiple-block source is kept
    // unaccepted; a terminal UI reports a format failure, never rescued JSON.
    const full = () => ({ text: '', finalMarkup: false, formatIssue: true });
    if (markdowns.length !== 1 || !c.visible(markdowns[0])
      || !markdowns[0].parentElement?.classList.contains('markdown-container')) return full();
    const markdown = markdowns[0], codes = c.nodes(markdown, 'code.language-json');
    if (codes.length !== 1) return full();
    const code = codes[0], pre = code.parentElement, highlighter = pre?.parentElement, segment = highlighter?.parentElement;
    if (pre?.tagName !== 'PRE' || !pre.classList.contains('language-json') || pre.children.length !== 1
      || highlighter?.tagName !== 'DIV' || !highlighter.classList.contains('syntax-highlighter')
      || !highlighter.classList.contains('segment-code-content') || segment?.parentElement !== markdown
      || !segment.classList.contains('segment-code') || ![code, pre, highlighter, segment].every(c.visible)) return full();
    // Only the observed fenced-code header is presentation chrome. Anything
    // authored outside the literal code remains in full text for codec rejection.
    const headers = c.nodes(segment, 'header.segment-code-header');
    const chrome = headers.length === 1 ? headers[0] : null;
    const tooltips = chrome ? c.nodes(chrome, '[role="tooltip"][data-testid="icon-button-tooltip"]') : [];
    const exactChrome = chrome && c.nodes(chrome, '.segment-code-lang').length === 1
      && c.nodes(chrome, '.segment-code-lang')[0].textContent === 'JSON'
      && tooltips.length <= 1 && (!tooltips.length || tooltips[0].textContent === 'Copy')
      && c.normalize(chrome.textContent) === (tooltips.length ? 'JSON Copy' : 'JSON');
    let visited = 0;
    const onlyLiteral = node => {
      if (++visited > 10_000) return false;
      if (node === code || node === chrome && exactChrome || knownReasoning(node)) return true;
      if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
      if (node.nodeType !== 1) return true;
      if (['INPUT', 'TEXTAREA', 'BUTTON'].includes(node.tagName) || node.getAttribute('contenteditable') === 'true') return false;
      return [...node.childNodes].every(onlyLiteral);
    };
    if (!onlyLiteral(box)) return full();
    return { text: (code.textContent || '').slice(0, 220_001), finalMarkup: true };
  }
  function read() {
    const t = transcript(), form = composer(), evidence = modelEvidence(false), extracted = authoredText(t.answer);
    const rails = t.answer ? visible(t.answer, '.segment-assistant-actions .segment-assistant-actions-content') : [];
    const icons = rails.length === 1 ? visible(rails[0], 'div.icon-button') : [];
    // Draft terminal conjunction from the observed completed response. Its
    // absence during live streaming must be qualified before registration.
    const terminalUI = !!state.first && evidence
      && rails.length === 1 && icons.length === 5 && icons.every(c.enabled)
      && c.enabled(form.editor) && form.empty && form.sendIcon
      && t.answer.getAttribute('aria-busy') !== 'true' && !state.deletion;
    if (terminalUI && extracted.formatIssue && !cleanupInspection && !deletionActionNames.includes(input.action))
      c.fail('unsupported_response_format', 'authored_source');
    const complete = terminalUI && extracted.finalMarkup && !!extracted.text.trim();
    return { t, form, output: { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
      composer: c.enabled(form.editor), userCount: t.users.length, responseCount: t.answers.length,
      modelEvidence: evidence, text: state.first && !cleanupInspection ? extracted.text : '', answerComplete: !!complete && !cleanupInspection,
      busy: state.submitted && !complete, interrupted: false, conversationIdentity: state.first ? state.canonical : null,
      firstUserIdentity: state.first?.id || null, firstUserVerified: false, firstUserMarkerVerified: false,
      firstUserFingerprint: null } };
  }
  const fresh = () => !state.submitted && !state.first && !state.deletion && currentRoute().kind === 'fresh'
    && transcript().users.length === 0 && transcript().answers.length === 0 && composer().empty;

  if (['discoverModels', 'selectModel'].includes(input.action)) {
    if (!fresh()) c.fail('not_fresh');
    if (input.action === 'selectModel' && !c.choiceValid(input.modelChoice)) c.fail('model_unverified');
    const p = picker(), desired = input.action === 'selectModel' ? input.modelChoice : null;
    if (state.model && (!desired || c.equalChoice(state.model.choice, desired)))
      return { ...read().output, selected: true, modelChoices: state.model.choices, discoveryComplete: false };
    if (!state.selection) {
      if (!p.closed || !c.hit(p.trigger)) c.fail('model_unverified');
      state.selection = { trigger: p.trigger, target: desired, stage: 'opening', choice: null, choices: null };
      p.trigger.click(); return { ...read().output, pending: true };
    }
    const selection = state.selection;
    if (p.trigger !== selection.trigger || !!desired !== !!selection.target
      || desired && !c.equalChoice(desired, selection.target)) c.fail('model_mismatch');
    if (selection.stage === 'closing') {
      if (!p.closed) return { ...read().output, pending: true };
      if (p.label !== selection.choice.label) c.fail('model_mismatch');
      state.model = { choice: selection.choice, trigger: p.trigger, choices: selection.choices };
      state.selection = null;
      return { ...read().output, selected: true, modelChoices: state.model.choices, discoveryComplete: false };
    }
    if (selection.stage === 'selected' && p.closed) {
      if (!c.hit(p.trigger)) c.fail('model_unverified');
      selection.stage = 'verifying'; p.trigger.click(); return { ...read().output, pending: true };
    }
    if (!p.menu) return { ...read().output, pending: true };
    const rows = choices(p.menu), checked = rows.find(row => row.checked);
    if (p.label !== checked.choice.label) c.fail('model_mismatch');
    const target = desired ? rows.find(row => c.equalChoice(row.choice, desired)) : checked;
    if (!target) c.fail('model_mismatch');
    if (desired && target.family !== 'plain-chat') c.fail('model_mismatch');
    if (!target.checked) {
      if (selection.stage !== 'opening') return { ...read().output, pending: true };
      if (!c.hit(target.node)) c.fail('model_unverified');
      selection.stage = 'selected'; target.node.click(); return { ...read().output, pending: true };
    }
    selection.choice = target.choice;
    // Website agent products have their own actions and have not been qualified
    // as inference relays. The native catalog further pins qualified key/label.
    selection.choices = rows.filter(row => row.family === 'plain-chat').map(row => row.choice);
    selection.stage = 'closing';
    if (!c.hit(p.trigger)) c.fail('model_unverified');
    p.trigger.click(); return { ...read().output, pending: true };
  }

  const deletionActions = deletionActionNames;
  if (state.deletion && !deletionActions.includes(input.action)) c.fail('conversation_changed', 'deleting_session');
  const deleteKeys = ['id', 'documentGeneration', 'sequence', 'firstUserFingerprint', 'conversationURL'];
  const deletionOperation = () => {
    const op = input.deleteOperation;
    if (!op || Array.isArray(op) || Object.keys(op).length !== deleteKeys.length || !deleteKeys.every(key => Object.hasOwn(op, key))
      || !c.uuid(op.id) || op.documentGeneration !== input.documentGeneration || op.sequence !== 1
      || !state.first || op.firstUserFingerprint !== state.first.fingerprint
      || op.conversationURL !== state.canonical || input.expectedFirstUserFingerprint !== op.firstUserFingerprint
      || state.deletion && !deleteKeys.every(key => state.deletion[key] === op[key]))
      c.fail('conversation_changed', 'delete_operation');
    return op;
  };
  const deleteProof = (op, record, deleted = false, nextActionReady = false) => ({ ...op, phase: record.stage,
    menuAcknowledged: record.menuAcknowledged, deleteAcknowledged: record.deleteAcknowledged,
    confirmAcknowledged: record.confirmAcknowledged, nextActionReady, conversationDeleted: deleted, remoteErasureVerified: false });
  const deletePending = (op, record, nextActionReady = false) => ({ url: document.URL,
    sessionLifecycle: 'saved_conversation_delete', temporary: false, pending: true,
    deleteProof: deleteProof(op, record, false, nextActionReady) });
  if (state.deletion?.confirmAcknowledged) {
    const op = deletionOperation(), record = state.deletion, now = currentRoute();
    if (now.kind !== 'fresh' && now.canonical !== record.conversationURL) c.fail('conversation_changed', 'delete_route');
    if (now.kind !== 'fresh') return deletePending(op, record);
    // A confirmed deletion may temporarily show the fresh-page skeleton. Do
    // not require an unmounted old model trigger or fabricate an empty editor.
    const editors = visible(document, '.chat-input-editor[contenteditable="true"][role="textbox"][data-lexical-editor="true"]');
    const sends = visible(document, 'div.send-button-container').filter(node => !authored(node));
    if (!editors.length || !sends.length) return deletePending(op, record);
    const form = composer(), users = c.nodes(document, '.chat-content-item.chat-content-item-user');
    const answers = c.nodes(document, '.chat-content-item.chat-content-item-assistant');
    const links = c.nodes(document, 'a[href]', 512).filter(node => {
      try { return new URL(node.getAttribute('href'), document.URL).href.split('?')[0] === record.conversationURL; } catch { return false; }
    });
    const deleted = users.length === 0 && answers.length === 0 && form.empty && c.enabled(form.editor)
      && record.roots.every(node => !node.isConnected) && !record.dialog.isConnected
      && visible(document, 'div.modal-container[data-testid="confirm-dialog"]').length === 0 && links.length === 0;
    if (!deleted) return deletePending(op, record);
    return { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
      composer: true, userCount: 0, responseCount: 0, text: '', busy: false, answerComplete: false,
      firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null,
      conversationIdentity: null, deleteProof: deleteProof(op, record, true) };
  }
  const initial = read();
  if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.length || input.expectedUserCounts.length > 2
    || input.expectedUserCounts.some(value => ![0, 1].includes(value))
    || !input.expectedUserCounts.includes(initial.t.users.length)) c.fail('conversation_changed', 'user_count');
  if (initial.t.first && !state.deletion?.confirmAcknowledged) {
    if (!state.submitted || !state.inserted || initial.t.first.text !== state.inserted.prompt
      || !c.uuid(input.expectedFirstUserMarker) || input.expectedFirstUserMarker !== state.inserted.marker
      || !state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`))
      c.fail('conversation_changed', 'first_user_message');
    // A provisional route is a pending observation, never first-body authority.
    if (route.kind !== 'canonical') return { ...initial.output, ownershipPending: true, text: '', answerComplete: false };
    const fingerprint = await c.hash(c.bodyText(initial.t.first.text));
    guard(); if (!sameFirst(initial.t.first)) c.fail('conversation_changed', 'first_user_message');
    modelEvidence();
    if (state.first) {
      const unacknowledgedRead = input.action === 'inspect' && input.allowFirstUserBinding === true && input.expectedFirstUserFingerprint == null;
      if (!sameFirst(state.first) || state.first.fingerprint !== fingerprint
        || input.expectedFirstUserFingerprint !== fingerprint && !unacknowledgedRead)
        c.fail('conversation_changed', 'first_user_message');
    } else {
      if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null)
        c.fail('conversation_changed', 'first_user_message');
      state.first = { ...initial.t.first, fingerprint };
    }
    Object.assign(initial, read());
    Object.assign(initial.output, { firstUserVerified: true, firstUserMarkerVerified: true, firstUserFingerprint: fingerprint });
  } else if (state.first && !state.deletion?.confirmAcknowledged) c.fail('conversation_changed', 'first_user_message');

  if (deletionActions.includes(input.action)) {
    const op = deletionOperation();
    const header = () => {
      const node = one(visible(document, 'header.chat-header-content[aria-haspopup="menu"]').filter(node => !authored(node)), 'chat_header');
      const id = node.getAttribute('id'), controls = node.getAttribute('aria-controls');
      if (!id || !controls || /\s/.test(id + controls)) c.fail('conversation_changed', 'delete_header');
      return { node, id, controls };
    };
    const deleteRow = record => {
      const h = header();
      if (h.node !== record.header || h.id !== record.headerID || h.controls !== record.menuID || !sameFirst(state.first))
        c.fail('conversation_changed', 'delete_ownership');
      const menus = visible(document, 'div.kimi-menu-positioner[role="menu"]');
      if (!menus.length) return null;
      const menu = one(menus, 'delete_menu');
      if (menu.getAttribute('id') !== h.controls || menu.getAttribute('aria-labelledby') !== h.id
        || h.node.getAttribute('aria-expanded') !== 'true') c.fail('conversation_changed', 'delete_menu');
      const candidates = visible(menu, 'div.kimi-menu-item[role="menuitem"][data-kimi-menu-item]').filter(row => {
        const labels = visible(row, '.kimi-menu-item__label');
        return labels.length === 1 && labels[0].children.length === 0 && labels[0].textContent === 'Delete';
      });
      const button = one(candidates, 'delete_control');
      if (!button.classList.contains('is-danger') || button.getAttribute('data-close-on-select') !== 'inherit')
        c.fail('conversation_changed', 'delete_control');
      return c.hit(button) ? button : null;
    };
    const confirmationTarget = record => {
      if (!sameFirst(state.first) || currentRoute().canonical !== record.conversationURL) c.fail('conversation_changed', 'delete_ownership');
      const dialogs = visible(document, 'div.modal-container[data-testid="confirm-dialog"]');
      if (!dialogs.length) return null;
      const dialog = one(dialogs, 'delete_dialog'), mask = dialog.parentElement;
      const title = one(visible(dialog, '.header .title'), 'delete_title'), message = one(visible(dialog, '.body'), 'delete_body');
      const buttons = visible(dialog, 'button'), confirm = one(buttons.filter(node => node.getAttribute('data-testid') === 'confirm-dialog-confirm'), 'delete_confirm');
      const cancel = one(buttons.filter(node => node.getAttribute('data-testid') === 'confirm-dialog-cancel'), 'delete_cancel');
      if (!mask?.classList.contains('modal-mask') || authored(dialog) || buttons.length !== 2
        || title.textContent !== 'Permanently delete chat'
        || message.textContent !== 'This chat data will be permanently deleted and cannot be recovered. Are you sure you want to delete?'
        || confirm.parentElement !== cancel.parentElement || !confirm.parentElement?.classList.contains('bottom')
        || c.normalize(confirm.textContent) !== 'Delete' || c.normalize(cancel.textContent) !== 'Cancel'
        || !confirm.classList.contains('km-button-danger')) c.fail('conversation_changed', 'delete_confirmation');
      return c.hit(confirm) ? { confirm, dialog } : null;
    };
    const pending = record => deletePending(op, record,
      record.stage === 'menu' ? !!deleteRow(record) : record.stage === 'confirmation' ? !!confirmationTarget(record) : false);
    if (!state.deletion) {
      if (input.action !== 'deleteConversation' || route.kind !== 'canonical' || !sameFirst(state.first))
        c.fail('conversation_changed', 'delete_ownership');
      const h = header();
      if (h.node.getAttribute('aria-expanded') !== 'false' || !c.hit(h.node)) c.fail('conversation_changed', 'delete_header');
      state.deletion = { ...op, stage: 'menu', header: h.node, headerID: h.id, menuID: h.controls,
        menuAcknowledged: false, deleteAcknowledged: false, confirmAcknowledged: false,
        roots: [initial.t.first.root, initial.t.first.body, initial.t.answer].filter(Boolean) };
      h.node.click(); state.deletion.menuAcknowledged = true;
      return pending(state.deletion);
    }
    const record = state.deletion;
    if (record.stage === 'menu' && input.action === 'selectConversationDeletion') {
      const button = deleteRow(record);
      if (!button) c.fail('conversation_changed', 'delete_not_ready');
      record.stage = 'confirmation'; button.click(); record.deleteAcknowledged = true;
      return pending(record);
    }
    if (record.stage === 'confirmation' && input.action === 'confirmConversationDeletion') {
      const target = confirmationTarget(record);
      if (!target) c.fail('conversation_changed', 'delete_not_ready');
      record.stage = 'observing'; record.dialog = target.dialog;
      target.confirm.click(); record.confirmAcknowledged = true;
      const now = currentRoute();
      if (now.kind !== 'fresh' && now.canonical !== record.conversationURL) c.fail('conversation_changed', 'delete_route');
      return deletePending(op, record);
    }
    return pending(record);
  }
  if (input.action === 'inspect') return initial.output;
  const evidence = modelEvidence();
  if (input.action === 'verifyModel') return { ...initial.output, modelEvidence: evidence };
  if (input.action === 'stop') return { ...initial.output, stopped: false }; // No Stop control observed yet.
  const form = initial.form;
  if (!c.enabled(form.editor) || !c.hit(form.editor)) c.fail('composer_unavailable');
  if (input.action === 'prepare') {
    if (!fresh() || state.prepared) c.fail('composer_not_empty');
    state.prepared = { editor: form.editor, scope: form.scope, send: form.send };
    form.editor.focus(); guard(); modelEvidence();
    if (composer().editor !== form.editor || !composer().empty) c.fail('composer_not_empty');
    return { ...initial.output, prepared: document.activeElement === form.editor };
  }
  const prompt = input.prompt, marker = input.expectedFirstUserMarker;
  if (typeof prompt !== 'string' || !prompt || new TextEncoder().encode(prompt).length > 180_000
    || !c.uuid(marker) || !prompt.endsWith(`\n\nComputa session marker: ${marker}`)) c.fail('prompt_not_inserted');
  if (!state.prepared || state.prepared.editor !== form.editor || state.prepared.scope !== form.scope
    || state.prepared.send !== form.send) c.fail('composer_unavailable');
  if (input.action === 'insert') {
    if (!fresh() || state.inserted || document.activeElement !== form.editor) c.fail('composer_not_empty');
    const outboundFingerprint = input.savedSubmissionFingerprint;
    if (typeof outboundFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(outboundFingerprint)) c.fail('prompt_not_inserted');
    state.inserted = { prompt, marker, outboundFingerprint, dispatched: false, verified: false }; // Claim before the only attempt.
    const selection = window.getSelection(), range = document.createRange();
    range.selectNodeContents(form.editor); selection.removeAllRanges(); selection.addRange(range);
    // Kimi's live Lexical handler preserves literal insertText but commits it
    // later; insertHTML flattens its newlines. A dispatch receipt is not an
    // inserted-prompt proof. Native may only observe sendReady after this call.
    if (!document.execCommand('insertText', false, prompt)) { state.terminal = true; c.fail('insert_command_rejected'); }
    state.inserted.dispatched = true;
    guard(); modelEvidence();
    const after = composer();
    if (after.editor !== form.editor || after.scope !== form.scope || after.send !== form.send
      || after.text !== prompt && !after.empty) { state.terminal = true; c.fail('prompt_not_inserted'); }
    state.inserted.verified = after.text === prompt;
    return { ...initial.output, inserted: state.inserted.verified, insertionDispatched: true,
      insertionPending: !state.inserted.verified, pending: !state.inserted.verified,
      insertionAcknowledgement: { ownerToken: input.ownerToken, documentGeneration: input.documentGeneration,
        sequence: 1, outboundFingerprint } };
  }
  if (state.submitted || state.inserted?.prompt !== prompt || state.inserted.marker !== marker
    || !state.inserted.dispatched || initial.t.users.length !== 0) c.fail('prompt_not_inserted');
  if (form.text !== prompt) {
    if (input.action === 'sendReady' && form.empty && !state.inserted.verified)
      return { ...initial.output, inserted: false, insertionPending: true, sendReady: false, pending: true };
    state.terminal = true; c.fail('prompt_not_inserted');
  }
  state.inserted.verified = true;
  const ready = form.sendEnabled && c.hit(form.send);
  if (input.action === 'sendReady') return { ...initial.output, inserted: true, insertionPending: false, sendReady: ready };
  if (!ready) c.fail('send_unavailable');
  const outboundFingerprint = input.savedSubmissionFingerprint;
  if (typeof outboundFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(outboundFingerprint)
    || outboundFingerprint !== state.inserted.outboundFingerprint)
    c.fail('prompt_not_inserted');
  state.submitted = true; form.send.click();
  // This proves only that the single exact-draft click returned. Native pins
  // this receipt to its pending outbound; the next ordinary read must still
  // prove the canonical route and complete first user before any answer.
  return { ...initial.output, submitted: true, submissionAcknowledgement: {
    ownerToken: input.ownerToken, documentGeneration: input.documentGeneration,
    sequence: 1, outboundFingerprint } };
} catch (error) {
  if (kimiDraftState && (!error?.computaAdapterFailure || kimiDraftState.deletion || kimiDraftState.submitted
    && ['conversation_changed', 'document_changed', 'model_mismatch', 'model_unverified'].includes(error.error)))
    kimiDraftState.terminal = true;
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}
