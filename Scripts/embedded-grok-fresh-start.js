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
      computaGrokAwaitLayout(c, preparation, node, () => globalThis.__computaGrokFreshStartV1 === preparation
        && preparation.owner === input.ownerToken && preparation.generation === input.documentGeneration
        && !preparation.terminal && !preparation.verified && !preparation.newChat);
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
