// One observed Private Chat per inference. Private is a proved transition,
// not an invented persistent indicator: Grok removes its toggle after Send.
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop'];
  const c = computaProviderCore(input, 'grok', 'https://grok.com', actions);
  if (document.URL !== 'https://grok.com/') c.fail('document_changed', 'document_url');
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
    const editors = c.nodes(document, '[contenteditable], [role="textbox"], textarea', 8);
    if (editors.length > 1) c.fail('composer_unavailable');
    if (editors.length && (!c.enabled(editors[0]) || editors[0].tagName !== 'DIV'
      || editors[0].getAttribute('contenteditable') !== 'true' || editors[0].getAttribute('role') !== 'textbox'
      || editors[0].getAttribute('aria-label') !== 'Message Grok')) c.fail('composer_unavailable');
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
    if (controls.length > 1) c.fail('composer_unavailable');
    if (controls.length) {
      const control = controls[0], label = control.getAttribute('aria-label'), action = control.getAttribute('data-composer-action');
      if (!c.visible(control) || !(label === 'Voice mode' && action === 'voice'
        || label === 'Send' && action === 'send' && control.getAttribute('type') === 'submit'
          && control.getAttribute('data-testid') === 'chat-submit')) c.fail('composer_unavailable');
    }
    if (![editors, triggers, modes, controls].every(nodes => nodes.length === 1)) return true;
    state.initialHydrationClosed = true;
    return false;
  }
  if (initialHydrationPending()) return { grokInitialHydrationPending: true, pending: true, composer: false };
  if (input.action !== 'inspect') state.initialHydrationClosed = true;
  const models = computaGrokModelControls(c, state, guard);
  function composer() {
    const editors = c.nodes(document, 'div[contenteditable="true"][role="textbox"][aria-label="Message Grok"]', 8).filter(c.visible);
    if (editors.length !== 1 || authored(editors[0]?.parentElement)) c.fail('composer_unavailable');
    const editor = editors[0];
    const controls = c.nodes(document, 'button[data-testid="chat-submit"][data-composer-action], button[aria-label="Voice mode"][data-composer-action="voice"], button[aria-label="Stop"]', 8)
      .filter(node => c.visible(node) && !authored(node));
    const action = c.unique(controls, 'composer_unavailable');
    if (authored(action)) c.fail('composer_unavailable');
    const label = action.getAttribute('aria-label'), kind = action.getAttribute('data-composer-action');
    const send = label === 'Send' && kind === 'send' && action.getAttribute('type') === 'submit' ? action : null;
    const stop = label === 'Stop' ? action : null;
    const voice = !state.submitted && label === 'Voice mode' && kind === 'voice';
    if (!send && !stop && !voice) c.fail('composer_unavailable');
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
    if (!control || control.getAttribute('aria-label') !== 'Switch to Private Chat' || control.getAttribute('aria-pressed') !== 'false' || !c.hit(control))
      c.fail('temporary_mode_unavailable');
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
  if (state.submitted || initial.userCount || initial.responseCount || !c.hit(form.editor)) c.fail('composer_unavailable');
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
  if (error?.computaAdapterFailure === true) return { error: error.error, ...(error.detail ? { detail: error.detail } : {}) };
  throw error;
}
