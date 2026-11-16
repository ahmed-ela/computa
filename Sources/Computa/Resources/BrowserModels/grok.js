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
        ...(provider === 'kimi' ? ['role', 'contenteditable', 'data-lexical-editor', 'data-testid', 'aria-haspopup', 'id', 'href']
          : provider === 'qwen' ? ['role', 'aria-haspopup', 'id']
          : provider === 'deepseek' ? ['role', 'placeholder', 'aria-pressed'] : [])] });
    globalThis[signalKey] = record;
  }
  return { uuid, fail, normalize, bodyText, choiceValid, equalChoice, physical, visible, enabled, nodes, unique, hit, hitFailure, context, assertContext, hash };
}

// Navigation-only preparation for Grok's observed restored saved-chat route.
// This never admits a saved conversation to the inference adapter or reads its
// messages. Native grants and spends these actions before any inference claim.
if (typeof input.action === 'string' && input.action.startsWith('grokFreshStart')) {
  let preparation;
  try {
    const prior = globalThis.__computaGrokFreshStartV1;
    if (prior?.owner === input.ownerToken && prior.generation === input.documentGeneration && prior.document === document)
      prior.layoutWait?.remove();
    const actions = ['grokFreshStartInspect', 'grokFreshStartExpandSidebar', 'grokFreshStartNewChat', 'grokFreshStartVerify'];
    const c = computaProviderCore(input, 'grok', 'https://grok.com', actions);
    if (input.allowGrokFreshStart !== true || !c.uuid(input.grokFreshStartToken)) c.fail('document_changed', 'fresh_start_grant');
    const root = 'https://grok.com/', key = '__computaGrokFreshStartV1';
    const savedRoute = value => typeof value === 'string' && !/[\r\n]/.test(value)
      && /^(https:\/\/grok\.com\/c\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})(?:\?rid=([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}))?$/.exec(value);
    const unclaimedInference = () => {
      const state = globalThis.__computaGrokPrivateSessionV1;
      // A root inspection may finish before native discards its result on a
      // saved-route promotion. Its readiness flag is not an action claim; the
      // native unbound grant and every actual claim below remain mandatory.
      // Do not reset initialHydrationClosed or reopen normal adapter hydration.
      return state === undefined || state.document === document && state.owner === input.ownerToken
        && state.generation === input.documentGeneration
        && !state.toggleClaimed && !state.privateEntered && !state.contradictoryModeObserved
        && !state.prepared && state.prompt === null && !state.submitted && !state.first && !state.stopped
        && !state.grokModelOperation && !state.grokModelChoices && !state.grokExpectedModel;
    };
    if (!unclaimedInference()) c.fail('document_changed', 'fresh_start_already_bound');
    if (globalThis[key] === undefined) {
      if (input.action !== 'grokFreshStartInspect' || !savedRoute(document.URL)) c.fail('document_changed', 'fresh_start_route');
      const route = savedRoute(document.URL);
      globalThis[key] = { owner: input.ownerToken, generation: input.documentGeneration, token: input.grokFreshStartToken,
        document, savedPath: route[1], responseID: route[2] || null, expanded: false, newChat: false, terminal: false, verified: false,
        readyElement: null, readyStage: null };
    }
    preparation = globalThis[key];
    const guard = () => {
      if (globalThis[key] !== preparation || preparation.terminal || preparation.verified || preparation.document !== document
        || preparation.owner !== input.ownerToken || preparation.generation !== input.documentGeneration
        || preparation.token !== input.grokFreshStartToken || globalThis.__computaModelOwner !== input.ownerToken
        || !unclaimedInference())
        c.fail('document_changed', 'fresh_start_context');
      if (preparation.newChat && document.URL === root) return;
      const route = savedRoute(document.URL);
      if (!route || route[1] !== preparation.savedPath || preparation.responseID && route[2] !== preparation.responseID)
        c.fail('document_changed', 'fresh_start_route');
      // The observed page may append its one response ID during hydration.
      // Once present it is pinned; changing/removing it is not preparation.
      if (route[2]) preparation.responseID = route[2];
    };
    guard();
    const packet = (stage, readiness = null) => ({ grokFreshStart: { version: 1, stage, ...(readiness ? { readiness } : {}) } });
    function awaitLayout(node) {
      const ancestors = [];
      for (let current = node; current; current = current.parentElement) ancestors.push(current);
      const types = ['transitionend', 'transitioncancel', 'animationend', 'animationcancel'];
      const wait = { remove: () => {
        for (const type of types) document.removeEventListener(type, wake, true);
        if (preparation.layoutWait === wait) preparation.layoutWait = null;
      } };
      const wake = event => {
        const current = globalThis.__computaGrokFreshStartV1 === preparation && preparation.layoutWait === wait
          && preparation.document === document && preparation.owner === input.ownerToken && preparation.generation === input.documentGeneration
          && !preparation.terminal && !preparation.verified && !preparation.newChat && c.context()
          && node.isConnected && ancestors.every(ancestor => ancestor.contains(node));
        if (!current) { wait.remove(); return; }
        if (!ancestors.includes(event.target)) return;
        wait.remove(); // One wakeup per pending read; this grants no action authority.
        try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ ownerToken: preparation.owner, kind: 'dom_changed' }); }
        catch { /* A missing wake channel cannot grant readiness. */ }
      };
      preparation.layoutWait = wait;
      for (const type of types) document.addEventListener(type, wake, true);
    }
    const unavailableHit = (target, node) => {
      const reason = c.hitFailure(node);
      if (reason === null) return null;
      if (!['disabled', 'invalid_geometry', 'outside_viewport', 'occluded'].includes(reason)) c.fail('document_changed', 'fresh_start_action_unverified');
      awaitLayout(node);
      return packet('pending', { target, reason });
    };
    const authored = node => !!node.closest('[data-testid="user-message"], [data-testid="assistant-message"], pre, code');
    const measurement = node => {
      if (node.tagName !== 'TEXTAREA' || node.parentElement !== document.body || document.activeElement === node
        || node.getAttribute('tabindex') !== '-1' || node.getAttribute('aria-hidden') !== 'true'
        || ['role', 'aria-label', 'aria-labelledby', 'contenteditable', 'id', 'name'].some(name => node.getAttribute(name) !== null)) return false;
      const style = getComputedStyle(node);
      return style.visibility === 'hidden' && style.position === 'absolute' && style.height === '0px' && style.zIndex === '-1000';
    };
    function emptyDrafts() {
      // Values are only checked for occupancy; none are copied into a receipt.
      // A hidden unknown field is still preserved. Only the observed measuring
      // textarea and non-text controls are outside this draft check.
      for (const node of c.nodes(document, 'input, textarea, [contenteditable], [role="textbox"]', 256)) {
        if (measurement(node)) continue;
        if (node.tagName === 'INPUT' && (node.getAttribute('type') || '').toLowerCase() === 'file' && node.files?.length) c.fail('composer_not_empty');
        if (node.tagName === 'INPUT' && !['', 'text', 'search', 'url', 'tel', 'email', 'password', 'number'].includes((node.getAttribute('type') || '').toLowerCase())) continue;
        if (node.tagName !== 'INPUT' && node.tagName !== 'TEXTAREA'
          && node.getAttribute('contenteditable') !== 'true' && node.getAttribute('role') !== 'textbox') continue;
        // An actual editable field in authored content is also a draft; static
        // code and transcript text are neither inspected nor adopted here.
        if (typeof node.value === 'string' && node.value.length || typeof node.textContent === 'string' && node.textContent.length)
          c.fail('composer_not_empty');
      }
      // The observed composer Send identity can represent a non-text draft.
      // Do not confuse unrelated onboarding buttons named Send with it.
      if (c.nodes(document, 'button[type="submit"][aria-label="Send"][data-testid="chat-submit"][data-composer-action="send"]', 8)
        .some(node => !authored(node) && c.enabled(node))) c.fail('composer_not_empty');
    }
    function editor() {
      const candidates = c.nodes(document, '[contenteditable], [role="textbox"], textarea', 64)
        .filter(node => !measurement(node) && !authored(node));
      if (!candidates.length) return null;
      if (candidates.length !== 1) c.fail('composer_unavailable', 'fresh_start_editor_ambiguous');
      const node = candidates[0];
      if (node.tagName === 'TEXTAREA' && c.enabled(node) && node.getAttribute('contenteditable') !== 'true'
        && node.getAttribute('role') !== 'textbox' && c.normalize(node.getAttribute('aria-label')) !== 'Message Grok') return null;
      if (node.tagName !== 'DIV' || node.getAttribute('contenteditable') !== 'true'
        || node.getAttribute('role') !== 'textbox' || node.getAttribute('aria-label') !== 'Message Grok' || !c.enabled(node))
        c.fail('composer_unavailable', 'fresh_start_editor_invalid');
      return node;
    }
    function sidebarState() {
      const toggles = c.nodes(document, 'button[aria-label="Toggle sidebar"]', 8).filter(node => !authored(node));
      const sidebars = c.nodes(document, '#app-sidebar', 8);
      if (toggles.length > 1 || sidebars.length > 1) c.fail('document_changed', 'fresh_start_sidebar_ambiguous');
      const toggle = toggles[0] || null, sidebar = sidebars[0] || null;
      if (toggle && (toggle.getAttribute('type') !== 'button' || toggle.getAttribute('aria-keyshortcuts') !== 'Meta+B'
        || !['true', 'false'].includes(toggle.getAttribute('aria-expanded'))))
        c.fail('document_changed', 'fresh_start_toggle_invalid');
      if (sidebar && (sidebar.tagName !== 'ASIDE' || sidebar.getAttribute('aria-label') !== 'App navigation' || authored(sidebar)))
        c.fail('document_changed', 'fresh_start_sidebar_invalid');
      const buttons = sidebar ? c.nodes(sidebar, 'button[aria-keyshortcuts="Meta+J"]', 8) : [];
      if (buttons.length > 1) c.fail('document_changed', 'fresh_start_new_chat_ambiguous');
      const button = buttons[0] || null;
      if (button) {
        const labels = c.nodes(button, 'span[data-sidebar-item-label]', 8), shortcuts = c.nodes(button, '[data-slot="sidebar-item-shortcut"]', 8);
        if (button.getAttribute('type') !== 'button' || authored(button) || labels.length !== 1 || c.normalize(labels[0].textContent) !== 'New chat'
          || shortcuts.length !== 1 || labels[0].parentElement !== shortcuts[0].parentElement)
          c.fail('document_changed', 'fresh_start_new_chat_invalid');
      }
      return { toggle, sidebar, button };
    }
    function rootReady() {
      if (c.nodes(document, '[data-testid="user-message"], [data-testid="assistant-message"]', 256).length) c.fail('not_fresh');
      emptyDrafts();
      const form = editor();
      const modes = c.nodes(document, 'button[aria-label="Switch to Private Chat"], button[aria-label="Exit Private Chat"]', 8);
      const models = c.nodes(document, '#model-select-trigger', 8);
      if (modes.length > 1 || models.length > 1) c.fail('document_changed', 'fresh_start_root_ambiguous');
      if (modes.length && (authored(modes[0]) || !c.enabled(modes[0]) || modes[0].getAttribute('aria-label') !== 'Switch to Private Chat'
        || modes[0].getAttribute('aria-pressed') !== 'false')) c.fail('temporary_mode_unverified');
      if (models.length) {
        const model = models[0], label = model.getAttribute('aria-label');
        if (authored(model) || !c.enabled(model) || model.tagName !== 'BUTTON' || model.getAttribute('aria-haspopup') !== 'menu'
          || model.getAttribute('aria-expanded') !== 'false' || typeof label !== 'string' || !label.startsWith('Model: ')
          || !c.choiceValid({ key: label.slice(7), label: label.slice(7) })) c.fail('model_unverified');
      }
      return !!form && modes.length === 1 && models.length === 1;
    }
    if (input.action === 'grokFreshStartVerify') {
      if (!preparation.newChat) c.fail('document_changed', 'fresh_start_unclaimed');
      emptyDrafts();
      if (document.URL !== root || !rootReady()) return packet('pending');
      guard(); preparation.verified = true;
      return packet('root_observed');
    }
    if (preparation.newChat || !savedRoute(document.URL)) c.fail('document_changed', 'fresh_start_replay');
    emptyDrafts(); const form = editor(), controls = sidebarState();
    if (input.action === 'grokFreshStartInspect') {
      preparation.readyElement = null; preparation.readyStage = null;
      if (!form || !controls.toggle) return packet('pending');
      if (controls.toggle.getAttribute('aria-expanded') === 'false') {
        if (preparation.expanded) return packet('pending');
        const pending = unavailableHit('toggle', controls.toggle);
        if (pending) return pending;
        preparation.readyElement = controls.toggle; preparation.readyStage = 'sidebar_closed';
        return packet('sidebar_closed');
      }
      if (!controls.sidebar || !controls.button) return packet('pending');
      const pending = unavailableHit('new_chat', controls.button);
      if (pending) return pending;
      preparation.readyElement = controls.button; preparation.readyStage = 'new_chat_ready';
      return packet('new_chat_ready');
    }
    const expand = input.action === 'grokFreshStartExpandSidebar';
    const target = expand ? controls.toggle : controls.button;
    if (!form || !target || target !== preparation.readyElement || preparation.readyStage !== (expand ? 'sidebar_closed' : 'new_chat_ready')
      || !c.hit(target) || !controls.toggle || !c.enabled(controls.toggle)
      || controls.toggle.getAttribute('aria-expanded') !== (expand ? 'false' : 'true')
      || expand && preparation.expanded) c.fail('document_changed', 'fresh_start_action_unverified');
    guard(); emptyDrafts(); preparation.readyElement = null; preparation.readyStage = null;
    if (expand) preparation.expanded = true;
    else preparation.newChat = true;
    target.click(); // Spend before the one dispatch. An uncertain action is never replayed.
    guard();
    return packet(expand ? 'sidebar_requested' : 'new_chat_requested');
  } catch (error) {
    if (preparation) { preparation.layoutWait?.remove(); preparation.terminal = true; }
    if (error?.computaAdapterFailure === true) return { error: error.error, ...(error.detail ? { detail: error.detail } : {}) };
    throw error;
  }
}

// The associated menu and its explicit checkbox state were observed on Grok.
// Model labels remain website discoveries; descriptions and promotions grant no choice.
function computaGrokModelControls(c, state, guard) {
  const authored = node => node?.closest('[data-testid="user-message"], [data-testid="assistant-message"], [contenteditable], pre, code');
  function picker() {
    guard();
    const trigger = c.unique(c.nodes(document, '#model-select-trigger', 8).filter(c.visible), 'model_unverified');
    if (trigger.tagName !== 'BUTTON' || trigger.getAttribute('aria-haspopup') !== 'menu' || authored(trigger)) c.fail('model_unverified');
    const raw = trigger.getAttribute('aria-label');
    if (typeof raw !== 'string' || !raw.startsWith('Model: ')) c.fail('model_unverified');
    const label = raw.slice(7), selected = { key: label, label };
    if (!c.choiceValid(selected)) c.fail('model_unverified');
    const menus = c.nodes(document, '[role="menu"][aria-labelledby="model-select-trigger"]', 8).filter(c.visible);
    if (menus.length > 1 || menus.some(authored)) c.fail('model_unverified');
    const expanded = trigger.getAttribute('aria-expanded');
    if (expanded !== 'true' && expanded !== 'false' || expanded === 'false' && menus.length) c.fail('model_unverified');
    return { trigger, selected, menu: menus[0] || null, closed: expanded === 'false' && menus.length === 0 };
  }
  function rows(p) {
    if (!p.menu || p.closed) c.fail('model_unverified');
    const options = c.nodes(p.menu, '[role="menuitemcheckbox"]', 64).filter(node => c.visible(node)
      && node.closest('[role="menu"]') === p.menu);
    if (!options.length) c.fail('model_unverified');
    const mapped = options.map(node => {
      const label = c.normalize(node.innerText), choice = { key: label, label }, checked = node.getAttribute('aria-checked');
      if (!c.choiceValid(choice) || !['true', 'false'].includes(checked) || authored(node)) c.fail('model_unverified');
      return { node, choice, checked: checked === 'true', enabled: c.enabled(node) && !node.hasAttribute('data-disabled') };
    });
    if (new Set(mapped.map(row => row.choice.key)).size !== mapped.length) c.fail('model_unverified');
    const checked = c.unique(mapped.filter(row => row.checked), 'model_unverified');
    if (!checked.enabled || !c.equalChoice(checked.choice, p.selected)) c.fail('model_unverified');
    const enabled = mapped.filter(row => row.enabled);
    if (!enabled.length || enabled.length > 32) c.fail('model_unverified');
    return { enabled, checked };
  }
  function evidence() {
    const p = picker();
    if (!p.closed || !state.grokModelChoices || !state.grokModelChoices.some(choice => c.equalChoice(choice, p.selected))) return null;
    if (state.grokExpectedModel && !c.equalChoice(state.grokExpectedModel, p.selected)) c.fail('model_mismatch');
    return { selected: p.selected, verification: 'website_selection', source: 'selected_model_indicator' };
  }
  function step(action, choice) {
    if (!['discoverModels', 'selectModel'].includes(action)) c.fail('unknown_action');
    if (action === 'selectModel' && !c.choiceValid(choice)) c.fail('model_unverified');
    const p = picker();
    let operation = state.grokModelOperation;
    if (operation && (operation.action !== action || action === 'selectModel' && !c.equalChoice(operation.choice, choice))) {
      if (operation.phase !== 'complete') c.fail('model_unverified');
      operation = null;
    }
    if (!operation) {
      if (!p.closed || !c.hit(p.trigger)) c.fail('model_unverified');
      operation = { action, choice: choice || null, phase: 'opening', trigger: p.trigger, selected: null, choices: null };
      state.grokModelOperation = operation; // Claim before opening; uncertain clicks are never replayed.
      p.trigger.click();
      guard();
      return { pending: true };
    }
    if (operation.phase === 'opening') {
      if (!p.menu) return { pending: true };
      if (p.trigger !== operation.trigger) c.fail('model_unverified');
      const menu = rows(p), target = action === 'selectModel'
        ? c.unique(menu.enabled.filter(row => c.equalChoice(row.choice, choice)), 'model_unavailable') : menu.checked;
      if (!c.hit(target.node)) c.fail('model_unverified');
      operation.choices = menu.enabled.map(row => ({ ...row.choice }));
      operation.selected = { ...target.choice };
      // Clicking the selected row is the observed menu-dismiss path. It does
      // not substitute another model, and a lost acknowledgement cannot retry.
      operation.phase = 'closing';
      target.node.click();
      guard();
      return { pending: true };
    }
    if (!p.closed) return { pending: true };
    if (!c.equalChoice(p.selected, operation.selected)) c.fail('model_mismatch');
    state.grokModelChoices = operation.choices;
    if (action === 'selectModel') state.grokExpectedModel = operation.selected;
    operation.phase = 'complete';
    return { modelChoices: operation.choices, modelEvidence: evidence(), ...(action === 'selectModel' ? { selected: true } : {}) };
  }
  return { picker, evidence, step };
}

// One observed Private Chat per inference. Private is a proved transition,
// not an invented persistent indicator: Grok removes its toggle after Send.
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop'];
  const c = computaProviderCore(input, 'grok', 'https://grok.com', actions);
  if (document.URL !== 'https://grok.com/') c.fail('document_changed', 'document_url');
  const preparation = globalThis.__computaGrokFreshStartV1;
  if (preparation && (!preparation.verified || preparation.terminal || preparation.document !== document
    || preparation.owner !== input.ownerToken || preparation.generation !== input.documentGeneration))
    c.fail('document_changed', 'fresh_start_unverified');
  const key = '__computaGrokPrivateSessionV1';
  if (globalThis[key] === undefined) globalThis[key] = { owner: input.ownerToken, generation: input.documentGeneration,
    document, toggleClaimed: false, privateEntered: false, contradictoryModeObserved: false,
    prepared: null, prompt: null, submitted: false, first: null, stopped: false, observer: null, initialHydrationClosed: false };
  const state = globalThis[key];
  const authored = node => node?.closest?.('[data-testid="user-message"], [data-testid="assistant-message"], [contenteditable], pre, code');
  const rootGuard = () => {
    c.assertContext();
    if (globalThis[key] !== state || state.owner !== input.ownerToken || state.generation !== input.documentGeneration
      || state.document !== document || document.URL !== 'https://grok.com/') c.fail('document_changed', 'owner_token');
  };
  function recordContradictions(records) {
    if (!state.privateEntered) return;
    const inspect = node => {
      if (node?.nodeType !== 1 || authored(node)) return;
      const label = node.getAttribute('aria-label');
      if (label === 'Switch to Private Chat' || label === 'Exit Private Chat' && node.getAttribute('aria-pressed') !== 'true')
        state.contradictoryModeObserved = true;
      if (node.getAttribute('id') === 'model-select-trigger' && state.grokExpectedModel
        && label !== 'Model: ' + state.grokExpectedModel.label) state.modelContradiction = true;
    };
    for (const record of records) {
      inspect(record.target);
      if (record.type === 'attributes' && !authored(record.target)) {
        const label = record.target.getAttribute('aria-label');
        if (record.attributeName === 'aria-label' && record.oldValue === 'Switch to Private Chat'
          || record.attributeName === 'aria-pressed' && record.oldValue === 'false' && label === 'Exit Private Chat')
          state.contradictoryModeObserved = true;
        if (record.target.getAttribute('id') === 'model-select-trigger' && record.attributeName === 'aria-label'
          && state.grokExpectedModel && record.oldValue?.startsWith('Model: ')
          && record.oldValue !== 'Model: ' + state.grokExpectedModel.label) state.modelContradiction = true;
      }
      for (const node of record.addedNodes || []) {
        inspect(node);
        if (node?.nodeType === 1) for (const child of node.querySelectorAll('[aria-label]')) inspect(child);
      }
    }
  }
  const guard = () => {
    rootGuard(); recordContradictions(state.observer?.takeRecords?.() || []);
    if (state.contradictoryModeObserved) c.fail('temporary_mode_unverified');
    if (state.modelContradiction) c.fail('model_mismatch');
  };
  function privateControl() {
    const controls = c.nodes(document, 'button[aria-label="Exit Private Chat"], button[aria-label="Switch to Private Chat"]', 8)
      .filter(node => c.visible(node) && !authored(node));
    if (controls.length > 1) c.fail('temporary_mode_unverified');
    const node = controls[0] || null;
    return { node, active: !!node && node.getAttribute('aria-label') === 'Exit Private Chat' && node.getAttribute('aria-pressed') === 'true' };
  }
  function privateEvidence() {
    guard(); const control = privateControl();
    if (!state.submitted) {
      if (!control.active) return null;
      if (!state.privateEntered) {
        state.privateEntered = true;
        state.observer = new MutationObserver(recordContradictions);
        state.observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true,
          attributeOldValue: true, attributeFilter: ['aria-label', 'aria-pressed'] });
      }
    } else if (!state.privateEntered || control.node && !control.active) c.fail('temporary_mode_unverified');
    return { version: 1, source: state.submitted ? 'submitted_private_provenance' : 'current_private_control',
      ownerToken: state.owner, documentGeneration: state.generation, url: 'https://grok.com/',
      sequence: state.submitted ? 1 : 0, enteredBeforeSend: true, sendClaimed: state.submitted,
      contradictoryModeObserved: false };
  }
  guard();
  // Native grants this only for its still-unbound initial root inspection. It
  // is a negative readiness observation, without URL, mode, model or transcript
  // authority. The existing native deadline and DOM wakeups bound the wait.
  function initialHydrationPending() {
    if (input.action !== 'inspect' || input.allowGrokInitialHydration !== true || state.initialHydrationClosed
      || state.privateEntered || state.toggleClaimed || state.prepared || state.prompt !== null || state.submitted || state.first
      || state.grokModelOperation || state.grokModelChoices || state.grokExpectedModel) return false;
    if (c.nodes(document, '[data-testid="user-message"], [data-testid="assistant-message"]', 8).length) c.fail('not_fresh');
    // Grok also mounts one inaccessible BODY-level textarea for measurement.
    // Its observed noninteractive shape is not a composer or readiness proof.
    // Matching message editors, accessible fields and changed shapes still
    // participate in ambiguity/malformed-control rejection below.
    const measurementTextarea = node => {
      if (node.tagName !== 'TEXTAREA' || node.parentElement !== document.body || document.activeElement === node
        || node.getAttribute('tabindex') !== '-1' || node.getAttribute('aria-hidden') !== 'true'
        || ['role', 'aria-label', 'aria-labelledby', 'contenteditable', 'id', 'name'].some(name => node.getAttribute(name) !== null)) return false;
      const style = getComputedStyle(node);
      return style.visibility === 'hidden' && style.position === 'absolute' && style.height === '0px' && style.zIndex === '-1000';
    };
    const editors = c.nodes(document, '[contenteditable], [role="textbox"], textarea', 8).filter(node => !measurementTextarea(node));
    if (editors.length > 1) c.fail('composer_unavailable', 'initial_editor_ambiguous');
    // Initial Grok HTML can render one ordinary textarea before mounting the
    // observed Message Grok editor. It is never an editor candidate we may use:
    // only this unclaimed initial inspection may wait for its replacement.
    // An occupied textarea (whose innerText can be empty despite its value),
    // any expected-editor identity, ambiguity or disabled shape still fails.
    const initialTextareaPending = editors.length === 1 && editors[0].tagName === 'TEXTAREA' && c.enabled(editors[0])
      && editors[0].getAttribute('contenteditable') !== 'true' && editors[0].getAttribute('role') !== 'textbox'
      && c.normalize(editors[0].getAttribute('aria-label')) !== 'Message Grok';
    if (initialTextareaPending && (c.bodyText(editors[0].value) || c.bodyText(editors[0].textContent))) c.fail('composer_not_empty');
    if (!initialTextareaPending && editors.length && (!c.enabled(editors[0]) || editors[0].tagName !== 'DIV'
      || editors[0].getAttribute('contenteditable') !== 'true' || editors[0].getAttribute('role') !== 'textbox'
      || editors[0].getAttribute('aria-label') !== 'Message Grok')) {
      const node = editors[0], style = getComputedStyle(node);
      // Failure-only closed predicates preserve the actual early render shape;
      // they contain no page strings and cannot grant readiness or recovery.
      const shape = { version: 1, tag: node.tagName === 'DIV' ? 'div' : node.tagName === 'TEXTAREA' ? 'textarea' : 'other',
        editable: node.getAttribute('contenteditable') === 'true', role: node.getAttribute('role') === 'textbox',
        label: node.getAttribute('aria-label') === 'Message Grok', connected: node.isConnected === true,
        rects: node.getClientRects().length > 0, displayNone: style.display === 'none', visibilityHidden: style.visibility === 'hidden',
        hiddenAncestor: !!node.closest('[hidden]'), inertAncestor: !!node.closest('[inert]'),
        ariaHiddenAncestor: !!node.closest('[aria-hidden="true"]'), disabled: !!node.disabled,
        ariaDisabled: node.getAttribute('aria-disabled') === 'true' };
      const failure = shape.tag !== 'div' ? 'tag_' + shape.tag : !shape.editable ? 'contenteditable'
        : !shape.role ? 'role' : !shape.label ? 'label' : !shape.connected ? 'disconnected' : !shape.rects ? 'no_rects'
        : shape.displayNone ? 'display_none' : shape.visibilityHidden ? 'visibility_hidden' : shape.hiddenAncestor ? 'hidden_ancestor'
        : shape.inertAncestor ? 'inert_ancestor' : shape.ariaHiddenAncestor ? 'aria_hidden_ancestor'
        : shape.disabled ? 'disabled' : shape.ariaDisabled ? 'aria_disabled' : 'invalid';
      throw { computaAdapterFailure: true, error: 'composer_unavailable', detail: 'initial_editor_' + failure,
        grokInitialEditorDiagnostic: shape };
    }
    if (editors.length && c.bodyText(editors[0].innerText)) c.fail('composer_not_empty');
    const buttons = c.nodes(document, 'button', 256);
    const triggers = [...new Set([...c.nodes(document, '#model-select-trigger', 8),
      ...buttons.filter(node => node.getAttribute('aria-label')?.startsWith('Model: '))])];
    if (triggers.length > 1) c.fail('model_unverified');
    if (triggers.length) {
      const trigger = triggers[0], label = trigger.getAttribute('aria-label');
      if (!c.enabled(trigger) || trigger.tagName !== 'BUTTON' || trigger.getAttribute('id') !== 'model-select-trigger'
        || trigger.getAttribute('aria-haspopup') !== 'menu' || trigger.getAttribute('aria-expanded') !== 'false'
        || typeof label !== 'string' || !label.startsWith('Model: ') || !c.choiceValid({ key: label.slice(7), label: label.slice(7) }))
        c.fail('model_unverified');
    }
    if (c.nodes(document, '[role="menu"][aria-labelledby="model-select-trigger"]', 8).some(c.visible)) c.fail('model_unverified');
    const modes = buttons.filter(node => node.getAttribute('aria-label')?.includes('Private Chat') || c.normalize(node.innerText) === 'Private');
    if (modes.length > 1) c.fail('temporary_mode_unverified');
    if (modes.length && (!c.enabled(modes[0])
      || !(modes[0].getAttribute('aria-label') === 'Switch to Private Chat' && modes[0].getAttribute('aria-pressed') === 'false'
        || modes[0].getAttribute('aria-label') === 'Exit Private Chat' && modes[0].getAttribute('aria-pressed') === 'true')))
      c.fail('temporary_mode_unverified');
    const controls = buttons.filter(node => node.hasAttribute('data-composer-action') || node.getAttribute('data-testid') === 'chat-submit'
      || ['Send', 'Stop', 'Voice mode'].includes(node.getAttribute('aria-label')));
    if (controls.length > 1) c.fail('composer_unavailable', 'initial_action_ambiguous');
    if (controls.length) {
      const control = controls[0], label = control.getAttribute('aria-label'), action = control.getAttribute('data-composer-action');
      if (!c.visible(control) || !(label === 'Voice mode' && action === 'voice'
        || label === 'Send' && action === 'send' && control.getAttribute('type') === 'submit'
          && control.getAttribute('data-testid') === 'chat-submit')) c.fail('composer_unavailable', 'initial_action_invalid');
    }
    if (initialTextareaPending || ![editors, triggers, modes, controls].every(nodes => nodes.length === 1)) return true;
    state.initialHydrationClosed = true;
    return false;
  }
  if (initialHydrationPending()) return { grokInitialHydrationPending: true, pending: true, composer: false };
  if (input.action !== 'inspect') state.initialHydrationClosed = true;
  const models = computaGrokModelControls(c, state, guard);
  function composer() {
    const editors = c.nodes(document, 'div[contenteditable="true"][role="textbox"][aria-label="Message Grok"]', 8).filter(c.visible);
    if (editors.length !== 1) c.fail('composer_unavailable', editors.length ? 'editor_ambiguous' : 'editor_missing');
    if (authored(editors[0].parentElement)) c.fail('composer_unavailable', 'editor_authored');
    const editor = editors[0];
    const controls = c.nodes(document, 'button[data-testid="chat-submit"][data-composer-action], button[aria-label="Voice mode"][data-composer-action="voice"], button[aria-label="Stop"]', 8)
      .filter(node => c.visible(node) && !authored(node));
    const action = c.unique(controls, 'composer_unavailable', controls.length ? 'action_ambiguous' : 'action_missing');
    if (authored(action)) c.fail('composer_unavailable', 'action_authored');
    const label = action.getAttribute('aria-label'), kind = action.getAttribute('data-composer-action');
    const send = label === 'Send' && kind === 'send' && action.getAttribute('type') === 'submit' ? action : null;
    const stop = label === 'Stop' ? action : null;
    const voice = !state.submitted && label === 'Voice mode' && kind === 'voice';
    if (!send && !stop && !voice) c.fail('composer_unavailable', 'action_invalid');
    return { editor, send, stop };
  }
  function transcript() {
    const users = c.nodes(document, '[data-testid="user-message"]', 4);
    const answers = c.nodes(document, '[data-testid="assistant-message"]', 4);
    if (users.length > 1 || answers.length > 1 || answers.length > users.length
      || [...users, ...answers].some(node => node.getAttribute('role') !== 'article' || !c.visible(node)
        || node.closest('[contenteditable], pre, code'))) c.fail('conversation_changed', 'user_count');
    const first = users[0] || null;
    const bodies = first ? c.nodes(first, 'span[data-bubble-text]', 4) : [];
    if (first && (bodies.length !== 1 || !c.visible(bodies[0]) || bodies[0].closest('[data-testid="user-message"]') !== first))
      c.fail('conversation_changed', 'first_user_message');
    return { users, answers, first, body: bodies[0] || null, text: bodies[0] ? c.bodyText(bodies[0].innerText) : '' };
  }
  function sameFirst(first) {
    const current = transcript();
    return first.root === current.first && first.body === current.body && first.parent === current.first?.parentElement
      && first.text === current.text;
  }
  function response(t, form) {
    const answer = t.answers[0] || null, parent = answer?.parentElement;
    const stop = !!form.stop && c.enabled(form.stop);
    if (!answer) return { text: '', answerComplete: false, busy: state.submitted && !state.stopped, interrupted: state.stopped };
    const heading = answer.getAttribute('aria-labelledby'), id = parent?.getAttribute('id');
    if (typeof heading !== 'string' || !/^turn-heading-[a-f0-9-]{36}$/i.test(heading)
      || id !== 'response-' + heading.slice(13) || parent.querySelectorAll('[data-testid="assistant-message"]').length !== 1)
      return { text: '', answerComplete: false, busy: true, interrupted: state.stopped };
    const footers = c.nodes(parent, '[data-testid="response-footer-actions"]', 4).filter(node => node.parentElement === parent && c.visible(node));
    const copies = footers.length === 1 ? c.nodes(footers[0], 'button[aria-label="Copy response"]', 4)
      .filter(node => c.enabled(node) && node.closest('[role="toolbar"]')?.getAttribute('aria-label') === 'Response actions') : [];
    const announcements = c.nodes(document, 'span[role="status"][aria-live="polite"]', 16)
      .filter(node => !authored(node) && node.children.length === 1 && node.children[0].tagName === 'SPAN'
        && node.children[0].textContent === 'Grok finished responding');
    const complete = !stop && copies.length === 1 && announcements.length === 1 && c.enabled(form.editor)
      && !!form.send && c.bodyText(form.editor.innerText) === '' && !state.stopped;
    if (!complete) return { text: '', answerComplete: false, busy: stop || !state.stopped, interrupted: state.stopped };
    const cards = c.nodes(answer, '[data-markdown-code][data-code-card]', 4)
      .filter(node => !node.closest('[data-testid="conversation-trace-slot"]'));
    if (cards.length !== 1) c.fail('unsupported_response_format', 'grok_code_card');
    const pres = c.nodes(cards[0], 'pre', 4), codes = c.nodes(cards[0], 'code', 4);
    if (pres.length !== 1 || codes.length !== 1 || codes[0].parentElement !== pres[0]
      || pres[0].children.length !== 1 || !c.visible(codes[0])) c.fail('unsupported_response_format', 'grok_literal_code');
    const header = cards[0].children[0];
    if (cards[0].children.length !== 2 || header?.tagName !== 'DIV' || cards[0].children[1] !== pres[0]
      || pres[0].parentElement !== cards[0]) c.fail('unsupported_response_format', 'grok_code_card_chrome');
    const languages = c.nodes(header, 'bdi', 4), copyControls = c.nodes(header, 'button', 4);
    if (languages.length !== 1 || languages[0].children.length || languages[0].textContent !== 'JSON'
      || copyControls.length !== 1 || copyControls[0].getAttribute('type') !== 'button'
      || copyControls[0].getAttribute('aria-label') !== 'Copy code' || !c.visible(copyControls[0])
      || c.normalize(header.textContent) !== 'JSON') c.fail('unsupported_response_format', 'grok_code_card_chrome');
    const chrome = [header]; let chromeNodes = 0;
    while (chrome.length) {
      const node = chrome.pop();
      if (++chromeNodes > 128) c.fail('unsupported_response_format', 'grok_code_card_chrome');
      if (node.nodeType === 3) continue;
      if (node.nodeType !== 1 || !['DIV', 'SPAN', 'BDI', 'BUTTON', 'SVG', 'USE'].includes(node.tagName.toUpperCase()))
        c.fail('unsupported_response_format', 'grok_code_card_chrome');
      chrome.push(...node.childNodes);
    }
    const code = codes[0], stack = [code]; let visited = 0;
    while (stack.length) {
      const node = stack.pop();
      if (++visited > 20_000) c.fail('unsupported_response_format', 'grok_code_size');
      if (node.nodeType === 3) continue;
      if (node.nodeType !== 1 || node !== code && node.tagName !== 'SPAN'
        || [...node.attributes].some(attribute => attribute.name !== 'class') || !c.visible(node))
        c.fail('unsupported_response_format', 'grok_code_structure');
      stack.push(...node.childNodes);
    }
    // Ignore only observed site chrome, empty wrappers and the explicit trace
    // slot. Any additional authored text outside the literal code fails closed.
    const outside = [answer]; visited = 0;
    while (outside.length) {
      const node = outside.pop();
      if (++visited > 25_000) c.fail('unsupported_response_format', 'grok_answer_size');
      if (node === header || node === code || node.nodeType === 1 && (node.tagName === 'H2' && node.getAttribute('id') === heading
        || node.getAttribute('data-testid') === 'conversation-trace-slot')) continue;
      if (node.nodeType === 3) { if (node.textContent.trim()) c.fail('unsupported_response_format', 'grok_extra_text'); }
      else if (node.nodeType === 1) outside.push(...node.childNodes);
      else c.fail('unsupported_response_format', 'grok_answer_structure');
    }
    const text = code.textContent.trim();
    if (!text || text.length > 220_000) c.fail('unsupported_response_format', 'grok_code_size');
    return { text, answerComplete: true, busy: false, interrupted: false,
      completionEvidence: { codeStructure: { reason: 'literal_code', blocks: 1, preCount: 1, codeCount: 1 } } };
  }
  async function inspect() {
    guard(); const t = transcript(), form = composer(), mode = privateEvidence(), model = models.evidence();
    if (!Array.isArray(input.expectedUserCounts) || input.expectedUserCounts.length < 1 || input.expectedUserCounts.length > 2
      || input.expectedUserCounts.some(value => value !== 0 && value !== 1)
      || !input.expectedUserCounts.includes(t.users.length)) c.fail('conversation_changed', 'user_count');
    if (state.submitted && !mode) c.fail('temporary_mode_unverified');
    if (state.grokExpectedModel && !['discoverModels', 'selectModel'].includes(input.action)
      && input.expectedModelChoice && (!model || !c.equalChoice(model.selected, input.expectedModelChoice))) c.fail('model_mismatch');
    let fingerprint = null;
    if (t.first) {
      const marker = input.expectedFirstUserMarker, line = `Computa session marker: ${marker}`;
      if (!state.submitted || !c.uuid(marker) || state.marker !== marker || t.text !== c.bodyText(state.prompt)
        || !t.text.endsWith('\n\n' + line) || t.text.split('\n').filter(value => value === line).length !== 1)
        c.fail('conversation_changed', 'first_user_message');
      const first = { root: t.first, body: t.body, parent: t.first.parentElement, text: t.text };
      fingerprint = await c.hash(t.text); guard();
      if (!sameFirst(first) || state.first && (!sameFirst(state.first) || state.first.fingerprint !== fingerprint)
        || input.expectedFirstUserFingerprint !== fingerprint && !(input.action === 'inspect'
          && input.allowFirstUserBinding === true && input.expectedFirstUserFingerprint == null)) c.fail('conversation_changed', 'first_user_message');
      if (!state.first) state.first = { ...first, fingerprint };
    } else if (state.first || input.expectedFirstUserFingerprint != null) c.fail('conversation_changed', 'first_user_message');
    // Re-read completion after hashing yields; stale footer/idle observations
    // cannot authorize a response after streaming or the page resumes.
    const current = transcript(), currentForm = composer(), currentMode = privateEvidence(), currentModel = models.evidence();
    if (fingerprint && !sameFirst(state.first) || model && !c.equalChoice(currentModel?.selected, model.selected)) c.fail('conversation_changed', 'first_user_message');
    const result = current.first ? response(current, currentForm) : { text: '', answerComplete: false, busy: state.submitted, interrupted: false };
    return { url: document.URL, temporary: currentMode !== null, ...(currentMode ? { grokPrivateEvidence: currentMode } : {}),
      temporaryActionAvailable: !state.submitted && !currentMode && c.enabled(privateControl().node), conversationIdentity: null,
      modelEvidence: currentModel, composer: c.enabled(currentForm.editor), userCount: current.users.length, responseCount: current.answers.length,
      firstUserIdentity: null, firstUserVerified: fingerprint !== null, firstUserMarkerVerified: fingerprint !== null,
      firstUserFingerprint: fingerprint, ...result };
  }
  const initial = await inspect();
  state.initialHydrationClosed = true;
  if (['discoverModels', 'selectModel'].includes(input.action)) {
    if (state.submitted || initial.userCount || initial.responseCount) c.fail('not_fresh');
    // Public pilot qualification is intentionally narrower than website
    // discovery. Never fabricate Fast if its enabled row was not observed.
    if (input.action === 'selectModel' && (input.modelChoice?.key !== 'Fast' || input.modelChoice?.label !== 'Fast')) c.fail('model_unavailable');
    const observed = models.step(input.action, input.modelChoice);
    if (observed.modelChoices) observed.modelChoices = observed.modelChoices.filter(choice => choice.key === 'Fast' && choice.label === 'Fast');
    if (!observed.pending && !observed.modelChoices?.length) c.fail('model_unavailable');
    return { ...initial, ...observed };
  }
  if (input.action === 'inspect') return initial;
  if (input.action === 'verifyModel') {
    if (!initial.modelEvidence) c.fail('model_unverified');
    return initial;
  }
  if (input.action === 'enableTemporary') {
    if (initial.temporary) return { ...initial, enabled: true };
    if (state.submitted || state.toggleClaimed || initial.userCount || initial.responseCount) c.fail('temporary_mode_unverified');
    const control = privateControl().node;
    if (!control) c.fail('temporary_mode_unavailable', 'private_control_missing');
    if (control.getAttribute('aria-label') !== 'Switch to Private Chat' || control.getAttribute('aria-pressed') !== 'false')
      c.fail('temporary_mode_unavailable', 'private_control_shape');
    const hitFailure = c.hitFailure(control);
    if (hitFailure) c.fail('temporary_mode_unavailable', 'private_control_hit_' + hitFailure);
    state.toggleClaimed = true; control.click(); guard();
    return { ...initial, enabled: false };
  }
  if (!initial.temporary) c.fail('temporary_mode_unverified');
  if (!initial.modelEvidence) c.fail('model_unverified');
  const form = composer();
  if (input.action === 'stop') {
    if (state.stopped) return { ...initial, stopped: true };
    if (form.stop && c.hit(form.stop)) { state.stopped = true; form.stop.click(); guard(); return { ...initial, stopped: true }; }
    return { ...initial, stopped: false };
  }
  if (state.submitted || initial.userCount || initial.responseCount) c.fail('composer_unavailable', 'editor_not_fresh');
  if (!c.hit(form.editor)) c.fail('composer_unavailable', 'editor_hit_test');
  if (input.action === 'prepare') {
    if (state.prepared || c.bodyText(form.editor.innerText)) c.fail('composer_not_empty');
    state.prepared = form.editor; form.editor.focus(); guard();
    return { ...initial, prepared: document.activeElement === form.editor };
  }
  const prompt = input.prompt, marker = input.expectedFirstUserMarker;
  if (typeof prompt !== 'string' || !prompt.trim() || prompt.length > 180_000 || !c.uuid(marker)
    || !prompt.endsWith(`\n\nComputa session marker: ${marker}`) || state.prepared !== form.editor) c.fail('prompt_not_inserted');
  if (input.action === 'insert') {
    if (state.prompt !== null || c.bodyText(form.editor.innerText) || document.activeElement !== form.editor) c.fail('composer_not_empty');
    state.prompt = prompt; state.marker = marker;
    // Focusing a background WebKit contenteditable need not create an editing
    // caret. Bind one collapsed range inside the exact empty owned composer
    // before the single insertion; a foreign/missing selection grants nothing.
    form.editor.focus();
    const selection = window.getSelection();
    if (!selection) c.fail('caret_unavailable');
    const range = document.createRange();
    range.selectNodeContents(form.editor); range.collapse(false);
    selection.removeAllRanges(); selection.addRange(range);
    guard();
    if (selection.isCollapsed !== true || !form.editor.contains(selection.anchorNode) || !form.editor.contains(selection.focusNode)
      || document.activeElement !== form.editor || composer().editor !== form.editor || c.bodyText(form.editor.innerText)) c.fail('caret_unavailable');
    if (!document.execCommand('insertText', false, prompt)) c.fail('insert_command_rejected');
    guard();
    if (composer().editor !== form.editor || c.bodyText(form.editor.innerText) !== c.bodyText(prompt)) c.fail('prompt_not_inserted');
    return { ...initial, inserted: true };
  }
  if (state.prompt !== prompt || state.marker !== marker || c.bodyText(form.editor.innerText) !== c.bodyText(prompt)) c.fail('prompt_not_inserted');
  const ready = !!form.send && c.hit(form.send) && c.enabled(form.editor);
  if (input.action === 'sendReady') return { ...initial, sendReady: ready };
  if (!ready || !privateEvidence() || !c.equalChoice(models.evidence()?.selected, initial.modelEvidence.selected)) c.fail('send_unavailable');
  state.submitted = true; // Spend before dispatch; no uncertain action can replay.
  form.send.click(); rootGuard();
  return { ...initial, submitted: true };
} catch (error) {
  if (error?.computaAdapterFailure === true) return { error: error.error, ...(error.detail ? { detail: error.detail } : {}),
    ...(error.grokInitialEditorDiagnostic ? { grokInitialEditorDiagnostic: error.grokInitialEditorDiagnostic } : {}) };
  throw error;
}
