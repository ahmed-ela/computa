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
        'aria-label', 'aria-expanded', 'aria-controls', 'aria-selected', 'data-state', 'class', 'style', 'hidden', 'inert',
        ...(provider === 'kimi' ? ['role', 'contenteditable', 'data-lexical-editor', 'data-testid', 'aria-haspopup', 'id']
          : provider === 'qwen' ? ['role', 'aria-haspopup']
          : provider === 'deepseek' ? ['role', 'placeholder', 'aria-pressed'] : [])] });
    globalThis[signalKey] = record;
  }
  return { uuid, fail, normalize, bodyText, choiceValid, equalChoice, physical, visible, enabled, nodes, unique, hit, hitFailure, context, assertContext, hash };
}

// Workspace extraction of Kimi's saved-chat protocol. DOM drivers supply only
// provider semantics; this engine owns claims, identity, acknowledgement and
// deletion stages. It does not register a provider or relax native admission.
async function computaSavedConversation(input, c, dom, config) {
  let state = null;
  try {
    const deletionActions = ['deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
    const key = config.stateKey;
    if (globalThis[key] === undefined) globalThis[key] = {
      owner: input.ownerToken, document, window, generation: input.documentGeneration,
      model: null, selection: null, mode: null, modeSelection: null, prepared: null, inserted: null, send: null,
      submitted: false, first: null, provisional: null, canonical: null, deletion: null, terminal: false,
      initialControls: {}, initialReadComplete: false
    };
    state = globalThis[key];
    const guard = (exactURL = true) => {
      if (exactURL) c.assertContext();
      if (globalThis[key] !== state || globalThis.__computaModelOwner !== input.ownerToken
        || state.owner !== input.ownerToken || state.document !== document || state.window !== window
        || state.generation !== input.documentGeneration || window !== window.top
        || new URL(document.URL).origin !== config.origin) c.fail('document_changed', 'owner_token');
    };
    guard();
    if (state.terminal) c.fail('conversation_changed', 'terminal_operation');
    const cleanupInspection = input.action === 'inspect' && input.savedCleanupInspection === true;
    const route = dom.route();
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
    const usesModes = config.selectionKind === 'mode';
    const pickerHit = (node, stage) => {
      const reason = c.hitFailure(node);
      if (reason) c.fail('model_unverified', stage + '_' + reason);
    };
    function selectionEvidence(required = true) {
      if (usesModes) {
        const controls = dom.modeControls(), selected = state.mode?.choice;
        if (input.modelChoice != null || input.expectedModelChoice != null) c.fail('mode_unverified', 'mode_named_input');
        // Finite diagnostics only: retain the same required/optional failure
        // behavior and physical pins; never adopt remounted controls here.
        const unverified = detail => { if (required) c.fail('mode_unverified', detail); return null; };
        if (!selected) return unverified('mode_unbound');
        if (controls.search.selected) return unverified('search_selected');
        if (controls.deepThink.node !== state.mode.deepThink) return unverified('deepthink_replaced');
        if (controls.search.node !== state.mode.search) return unverified('search_replaced');
        const evidence = dom.modeEvidence();
        if (!c.equalChoice(evidence.selected, selected)) return unverified('mode_choice_changed');
        if (input.expectedModeChoice != null && !c.equalChoice(selected, input.expectedModeChoice)) c.fail('mode_mismatch');
        return evidence;
      }
      const p = dom.picker(), selected = state.model?.choice;
      if (!selected || !p.closed || p.trigger !== state.model.trigger || p.label !== selected.label) {
        if (required) c.fail('model_unverified', 'selection_binding');
        return null;
      }
      if (input.expectedModelChoice != null && !c.equalChoice(selected, input.expectedModelChoice)) c.fail('model_mismatch', 'selection_target');
      return { selected, verification: 'website_selection', source: 'model_picker_label' };
    }
    function sameFirst(first) {
      const now = dom.transcript().first;
      return !!first && !!now && first.root === now.root && first.body === now.body
        && first.container === now.container && first.id === now.id && first.text === now.text;
    }
    function read() {
      const t = dom.transcript(), form = dom.composer(), evidence = selectionEvidence(false), extracted = dom.rawAnswer(t.answer);
      state.initialReadComplete = true;
      const terminalUI = !!state.first && !!evidence && !state.deletion && dom.completionCandidate(t.answer);
      if (terminalUI && extracted.formatIssue && !cleanupInspection && !deletionActions.includes(input.action))
        c.fail('unsupported_response_format', 'authored_source');
      const complete = terminalUI && extracted.finalMarkup && !!extracted.text.trim();
      return { t, form, output: { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
        composer: c.enabled(form.editor), userCount: t.users.length, responseCount: t.answers.length,
        [usesModes ? 'modeEvidence' : 'modelEvidence']: evidence,
        text: state.first && !cleanupInspection ? extracted.text : '', answerComplete: !!complete && !cleanupInspection,
        busy: state.submitted && !complete, interrupted: false, conversationIdentity: state.first ? state.canonical : null,
        firstUserIdentity: state.first?.id || null, firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null } };
    }
    const fresh = () => !state.submitted && !state.first && !state.deletion && dom.route().kind === 'fresh'
      && dom.transcript().users.length === 0 && dom.transcript().answers.length === 0 && dom.composer().empty;
    function initialHydrationPending() {
      // Only the first empty-page inspection may describe missing controls as
      // loading. This envelope grants no selection, transcript or action proof.
      // Native retains the existing preparation deadline and DOM-change wait.
      if (input.action !== 'inspect' || cleanupInspection || state.initialReadComplete
        || state.model || state.selection || state.mode || state.modeSelection || state.prepared
        || state.inserted || state.send || state.submitted || state.first || state.provisional
        || state.canonical || state.deletion || route.kind !== 'fresh') return false;
      const reject = (error, detail) => { state.terminal = true; c.fail(error, detail); };
      const retain = (name, node) => {
        const prior = state.initialControls[name];
        if (prior && prior !== node || node && (!c.visible(node) || dom.authored(node)))
          reject('document_changed', name);
        if (node) state.initialControls[name] = node;
        return node;
      };
      const control = (name, root, selector) => {
        const candidates = c.nodes(root, selector);
        if (candidates.length > 1) reject('document_changed', name);
        return retain(name, candidates[0] || null);
      };
      try { return !dom.initialReady({ control, retain, reject }); }
      catch (error) { state.terminal = true; throw error; }
    }
    if (initialHydrationPending()) return { pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false };
    if (usesModes && ['discoverModes', 'selectMode'].includes(input.action)) {
      if (!fresh()) c.fail('not_fresh');
      if (input.modelChoice != null || input.expectedModelChoice != null) c.fail('mode_unverified');
      const controls = dom.modeControls();
      if (input.action === 'discoverModes') {
        // Discovery never changes Search or DeepThink. Mode evidence remains
        // separate from a backend model name; a later explicit select binds it.
        return { ...read().output, modeChoices: controls.choices, discoveryComplete: false };
      }
      const desired = input.modeChoice;
      if (!c.choiceValid(desired) || !controls.choices.some(choice => c.equalChoice(choice, desired))) c.fail('mode_unverified');
      if (!state.modeSelection && state.mode && c.equalChoice(state.mode.choice, desired) && selectionEvidence(false))
        return { ...read().output, selected: true, modeChoices: controls.choices };
      if (!state.modeSelection) state.modeSelection = { choice: desired, deepThink: controls.deepThink.node,
        search: controls.search.node, searchClaimed: false, thinkClaimed: false };
      const selection = state.modeSelection;
      if (!c.equalChoice(selection.choice, desired) || selection.deepThink !== controls.deepThink.node
        || selection.search !== controls.search.node) c.fail('mode_mismatch');
      if (controls.search.selected) {
        if (selection.searchClaimed) return { ...read().output, pending: true };
        if (!c.hit(controls.search.node)) c.fail('mode_unverified');
        selection.searchClaimed = true; controls.search.node.click(); return { ...read().output, pending: true };
      }
      const current = dom.modeEvidence();
      if (!c.equalChoice(current.selected, desired)) {
        if (selection.thinkClaimed) return { ...read().output, pending: true };
        if (!c.hit(controls.deepThink.node)) c.fail('mode_unverified');
        selection.thinkClaimed = true; controls.deepThink.node.click(); return { ...read().output, pending: true };
      }
      state.mode = { choice: desired, deepThink: selection.deepThink, search: selection.search };
      state.modeSelection = null;
      return { ...read().output, selected: true, modeChoices: controls.choices };
    }
    if (['discoverModels', 'selectModel'].includes(input.action)) {
      if (usesModes) c.fail('mode_unverified');
      if (!fresh()) c.fail('not_fresh');
      const desired = input.action === 'selectModel' ? input.modelChoice : null;
      if (desired !== null && !c.choiceValid(desired)) c.fail('model_unverified', 'model_choice_invalid');
      const p = dom.picker();
      if (state.model && (!desired || c.equalChoice(state.model.choice, desired)))
        return { ...read().output, selected: true, modelChoices: state.model.choices, discoveryComplete: false };
      if (!state.selection) {
        if (!p.closed) c.fail('model_unverified', 'picker_not_closed');
        pickerHit(p.trigger, 'picker_open');
        state.selection = { trigger: p.trigger, target: desired, stage: 'opening', menu: null, choice: null, choices: null };
        p.trigger.click(); return { ...read().output, pending: true };
      }
      const selection = state.selection;
      if (p.trigger !== selection.trigger || !!desired !== !!selection.target
        || desired && !c.equalChoice(desired, selection.target)) c.fail('model_mismatch', 'selection_target');
      if (selection.stage === 'closing') {
        if (!p.closed) return { ...read().output, pending: true };
        if (p.label !== selection.choice.label) c.fail('model_mismatch', 'picker_selected_label');
        state.model = { choice: selection.choice, trigger: p.trigger, choices: selection.choices };
        state.selection = null;
        return { ...read().output, selected: true, modelChoices: state.model.choices, discoveryComplete: false };
      }
      if (selection.stage === 'selected' && p.closed) {
        pickerHit(p.trigger, 'picker_verify');
        selection.stage = 'verifying'; selection.menu = null;
        p.trigger.click(); return { ...read().output, pending: true };
      }
      if (!p.menu) return { ...read().output, pending: true };
      if (selection.menu && selection.menu !== p.menu) c.fail('model_unverified', 'picker_menu_replaced');
      selection.menu = p.menu;
      const rows = dom.modelRows(p.menu), checked = rows.find(row => row.selected);
      const target = desired ? rows.find(row => c.equalChoice(row.choice, desired)) : checked;
      if (!target) c.fail('model_mismatch', 'model_target_missing');
      if (p.label !== checked.choice.label) c.fail('model_mismatch', 'picker_selected_label');
      if (!target.selected) {
        if (selection.stage !== 'opening') return { ...read().output, pending: true };
        pickerHit(target.node, 'model_option');
        selection.stage = 'selected'; target.node.click(); return { ...read().output, pending: true };
      }
      selection.choice = target.choice; selection.choices = rows.map(row => row.choice); selection.stage = 'closing';
      pickerHit(p.trigger, 'picker_close');
      p.trigger.click(); return { ...read().output, pending: true };
    }
    if (state.deletion && !deletionActions.includes(input.action)) c.fail('conversation_changed', 'deleting_session');
    const deleteKeys = ['id', 'documentGeneration', 'sequence', 'firstUserFingerprint', 'conversationURL'];
    const deletionOperation = () => {
      const op = input.deleteOperation;
      if (!op || Array.isArray(op) || Object.keys(op).length !== deleteKeys.length || !deleteKeys.every(key => Object.hasOwn(op, key))
        || !c.uuid(op.id) || op.documentGeneration !== input.documentGeneration || op.sequence !== 1
        || !state.first || op.firstUserFingerprint !== state.first.fingerprint || op.conversationURL !== state.canonical
        || input.expectedFirstUserFingerprint !== op.firstUserFingerprint
        || state.deletion && !deleteKeys.every(key => state.deletion[key] === op[key])) c.fail('conversation_changed', 'delete_operation');
      return op;
    };
    const proof = (op, record, deleted = false, nextActionReady = false) => ({ ...op, phase: record.stage,
      menuAcknowledged: record.menuAcknowledged, deleteAcknowledged: record.deleteAcknowledged,
      confirmAcknowledged: record.confirmAcknowledged, nextActionReady, conversationDeleted: deleted, remoteErasureVerified: false });
    const pending = (op, record, ready = false) => ({ url: document.URL, sessionLifecycle: 'saved_conversation_delete',
      temporary: false, pending: true, deleteProof: proof(op, record, false, ready) });
    if (state.deletion?.confirmAcknowledged) {
      const op = deletionOperation(), record = state.deletion;
      if (input.action !== 'observeDeletedConversation') c.fail('conversation_changed', 'delete_phase');
      if (route.kind !== 'fresh' && route.canonical !== record.conversationURL) c.fail('conversation_changed', 'delete_route');
      if (route.kind !== 'fresh' || !dom.deletionObserved(record)) return pending(op, record);
      return { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
        composer: true, userCount: 0, responseCount: 0, text: '', busy: false, answerComplete: false,
        firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null, conversationIdentity: null,
        deleteProof: proof(op, record, true) };
    }
    let initial = read();
    if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.length || input.expectedUserCounts.length > 2
      || input.expectedUserCounts.some(value => ![0, 1].includes(value)) || !input.expectedUserCounts.includes(initial.t.users.length))
      c.fail('conversation_changed', 'user_count');
    // Diagnostic-only mode detail: Qwen retains its existing detail and both
    // providers retain all exact body, marker, identity and fingerprint gates.
    const firstFailure = detail => c.fail('conversation_changed', usesModes ? detail : 'first_user_message');
    if (initial.t.first) {
      if (!state.submitted || !state.inserted) firstFailure('first_not_submitted');
      if (initial.t.first.text !== state.inserted.prompt) firstFailure('first_prompt_mismatch');
      if (!c.uuid(input.expectedFirstUserMarker)) firstFailure('first_marker_invalid');
      if (input.expectedFirstUserMarker !== state.inserted.marker) firstFailure('first_marker_mismatch');
      if (!state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)) firstFailure('first_marker_suffix');
      if (route.kind !== 'canonical') return { ...initial.output, ownershipPending: true, text: '', answerComplete: false };
      const fingerprint = await c.hash(c.bodyText(initial.t.first.text));
      guard(); if (!sameFirst(initial.t.first)) firstFailure('first_changed_after_hash');
      selectionEvidence();
      if (state.first) {
        const unpublished = input.action === 'inspect' && input.allowFirstUserBinding === true && input.expectedFirstUserFingerprint == null;
        if (!sameFirst(state.first)) firstFailure('first_pinned_node_changed');
        if (state.first.fingerprint !== fingerprint) firstFailure('first_pinned_hash_mismatch');
        if (input.expectedFirstUserFingerprint !== fingerprint && !unpublished) firstFailure('first_expected_hash_mismatch');
      } else {
        if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null)
          firstFailure('first_binding_not_authorized');
        state.first = { ...initial.t.first, fingerprint };
      }
      initial = read();
      Object.assign(initial.output, { firstUserVerified: true, firstUserMarkerVerified: true, firstUserFingerprint: fingerprint });
    } else if (state.first) firstFailure('first_disappeared');
    if (deletionActions.includes(input.action)) {
      const op = deletionOperation();
      const deletionTarget = record => {
        if (!sameFirst(state.first) || dom.route().canonical !== record.conversationURL) c.fail('conversation_changed', 'delete_ownership');
        if (record.stage === 'menu') {
          if (dom.deletionTrigger(record.driverContext) !== record.header) c.fail('conversation_changed', 'delete_header');
          const found = dom.deletionMenu(record);
          if (found && record.menu && found.menu !== record.menu) c.fail('conversation_changed', 'delete_menu');
          if (found) record.menu = found.menu;
          return found?.target || null;
        }
        if (record.stage === 'confirmation') {
          const found = dom.deletionConfirmation(record);
          if (found && record.dialog && found.dialog !== record.dialog) c.fail('conversation_changed', 'delete_confirmation');
          if (found) record.dialog = found.dialog;
          return found?.target || null;
        }
        return null;
      };
      if (!state.deletion) {
        if (input.action !== 'deleteConversation' || route.kind !== 'canonical' || !sameFirst(state.first))
          c.fail('conversation_changed', 'delete_ownership');
        const driverContext = dom.deletionContext ? dom.deletionContext(state.first) : null;
        if (!driverContext && (dom.deletionMenu() || dom.deletionConfirmation())) c.fail('conversation_changed', 'delete_ownership');
        const header = dom.deletionTrigger(driverContext);
        if (!header || !c.hit(header)) c.fail('conversation_changed', 'delete_header');
        state.deletion = { ...op, stage: 'menu', header, trigger: header, driverContext, menu: null, dialog: null,
          menuAcknowledged: false, deleteAcknowledged: false, confirmAcknowledged: false,
          roots: [initial.t.first.root, initial.t.first.body, initial.t.answer?.root].filter(Boolean) };
        header.click(); state.deletion.menuAcknowledged = true;
        return pending(op, state.deletion, !!deletionTarget(state.deletion));
      }
      const record = state.deletion;
      if (input.action === 'observeDeletedConversation') return pending(op, record, !!deletionTarget(record));
      const expected = record.stage === 'menu' ? 'selectConversationDeletion'
        : record.stage === 'confirmation' ? 'confirmConversationDeletion' : null;
      if (input.action !== expected) c.fail('conversation_changed', 'delete_phase');
      const target = deletionTarget(record);
      if (!target) c.fail('conversation_changed', 'delete_not_ready');
      if (record.stage === 'menu') {
        record.stage = 'confirmation'; target.click(); record.deleteAcknowledged = true;
        return pending(op, record, !!deletionTarget(record));
      }
      record.stage = 'observing'; target.click(); record.confirmAcknowledged = true;
      // A synchronous confirmed canonical→root transition is metadata only.
      // The next pinned read must independently prove the deletion outcome.
      guard(false);
      const now = dom.route(false);
      if (now.kind !== 'fresh' && now.canonical !== record.conversationURL) c.fail('conversation_changed', 'delete_route');
      return pending(op, record);
    }
    if (input.action === 'inspect') return initial.output;
    const evidence = selectionEvidence();
    if (usesModes && input.action === 'verifyMode') return { ...initial.output, modeEvidence: evidence };
    if (input.action === 'verifyModel') {
      if (usesModes) c.fail('mode_unverified');
      return { ...initial.output, modelEvidence: evidence };
    }
    if (input.action === 'stop') return { ...initial.output, stopped: false };
    const form = initial.form;
    if (!c.enabled(form.editor) || !c.hit(form.editor)) c.fail('composer_unavailable');
    if (input.action === 'prepare') {
      if (!fresh() || state.prepared) c.fail('composer_not_empty');
      state.prepared = { editor: form.editor, scope: form.scope }; state.send = form.send;
      form.editor.focus(); guard(); selectionEvidence();
      if (dom.composer().editor !== form.editor || !dom.composer().empty) c.fail('composer_not_empty');
      return { ...initial.output, prepared: document.activeElement === form.editor };
    }
    const prompt = input.prompt, marker = input.expectedFirstUserMarker;
    if (typeof prompt !== 'string' || !prompt || new TextEncoder().encode(prompt).length > 180_000
      || !c.uuid(marker) || !prompt.endsWith(`\n\nComputa session marker: ${marker}`)) c.fail('prompt_not_inserted');
    if (!state.prepared || state.prepared.editor !== form.editor || state.prepared.scope !== form.scope)
      c.fail('composer_unavailable');
    if (input.action === 'insert') {
      if (!fresh() || state.inserted || document.activeElement !== form.editor) c.fail('composer_not_empty');
      state.inserted = { prompt, marker };
      dom.insertLiteral(form, prompt); // Exactly one attempt, never a corrective retry.
      guard(); selectionEvidence();
      const after = dom.composer();
      if (after.editor !== form.editor || after.scope !== form.scope || after.text !== prompt) {
        state.terminal = true; c.fail('prompt_not_inserted');
      }
      return { ...initial.output, inserted: true };
    }
    if (state.submitted || state.inserted?.prompt !== prompt || state.inserted.marker !== marker
      || form.text !== prompt || initial.t.users.length !== 0) c.fail('prompt_not_inserted');
    if (state.send && form.send !== state.send) c.fail('composer_unavailable');
    if (form.send) state.send = form.send;
    if (input.action === 'sendReady') return { ...initial.output, sendReady: form.sendReady };
    if (!form.sendReady) c.fail('send_unavailable');
    const outboundFingerprint = input.savedSubmissionFingerprint;
    if (typeof outboundFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(outboundFingerprint)) c.fail('prompt_not_inserted');
    state.submitted = true; form.send.click();
    return { ...initial.output, submitted: true, submissionAcknowledgement: { ownerToken: input.ownerToken,
      documentGeneration: input.documentGeneration, sequence: 1, outboundFingerprint } };
  } catch (error) {
    if (state && (!error?.computaAdapterFailure || state.deletion || (state.submitted || state.initialReadComplete
      || state.model || state.selection || state.mode || state.modeSelection || state.prepared || state.inserted)
      && ['conversation_changed', 'document_changed', 'model_mismatch', 'model_unverified', 'mode_mismatch', 'mode_unverified'].includes(error.error))) state.terminal = true;
    return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
      : { error: 'document_changed' };
  }
}

// DeepSeek DOM hooks; provider registration and authority stay in the native host.
// The shared saved-chat engine must own claims, hashing and lifecycle. DeepSeek
// exposes modes, not a named backend model. Completion is an unqualified candidate.
function computaDeepSeekDOM(c) {
  const visible = (root, selector, max = 256) => c.nodes(root, selector, max).filter(c.visible);
  const one = (values, reason) => c.unique(values, 'document_changed', reason);
  const optional = (values, reason) => values.length ? one(values, reason) : null;
  const authored = node => !!node.closest('.ds-message');
  const arrow = 'M8.3125 0.980206C8.66767 1.05312 8.97902 1.2042 9.2627 1.43235C9.48724 1.613 9.73029 1.85795 9.97949 2.10716L14.707 6.8347L13.293 8.24876L9 3.95579V15.0417H7V3.95579L2.70703 8.24876L1.29297 6.8347L6.02051 2.10716C6.26971 1.85795 6.51277 1.613 6.7373 1.43235C6.97662 1.23988 7.28445 1.04404 7.6875 0.980206C7.8973 0.947029 8.1031 0.955183 8.3125 0.980206Z';
  const usable = node => c.enabled(node) && !node.classList.contains('ds-button--disabled');
  const leaf = (root, selector, reason) => {
    const node = one(visible(root, selector), reason);
    if (node.children.length) c.fail('document_changed', reason);
    return node;
  };
  function route(exactURL = true) {
    if (exactURL) c.assertContext();
    if (document.URL === 'https://chat.deepseek.com/')
      return { kind: 'fresh', canonical: null, conversation: null, path: '/', id: null };
    const match = /^https:\/\/chat\.deepseek\.com\/a\/chat\/s\/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/.exec(document.URL);
    if (!match) c.fail('conversation_changed', 'conversation_url');
    return { kind: 'canonical', canonical: document.URL, conversation: document.URL,
      path: '/a/chat/s/' + match[1], id: match[1] };
  }
  function initialReady({ control, retain, reject }) {
    if (c.nodes(document, '.ds-message', 64).length) reject('not_fresh');
    const editor = control('composer', document, 'textarea[placeholder="Message DeepSeek"]');
    if (!editor) return false;
    const scope = retain('composer_scope', editor.closest('._020ab5b'));
    if (!scope || c.nodes(scope, 'textarea').length !== 1 || typeof editor.value !== 'string') reject('composer_unavailable');
    if (editor.value !== '') reject('composer_not_empty');
    const send = control('send_control', scope, '[role="button"].ds-button--primary.ds-button--circle');
    const toggles = c.nodes(scope, '.ds-toggle-button', 3);
    if (toggles.length > 2) reject('mode_unverified');
    const found = {};
    for (const node of toggles) {
      const spans = c.nodes(node, 'span', 2);
      if (spans.length !== 1 || spans[0].children.length || !['DeepThink', 'Search'].includes(spans[0].textContent)) reject('mode_unverified');
      const name = spans[0].textContent === 'DeepThink' ? 'deepthink_control' : 'search_control';
      if (found[name]) reject('mode_unverified');
      found[name] = retain(name, node);
      retain(name + '_label', spans[0]);
      const pressed = node.getAttribute('aria-pressed');
      if (!['true', 'false'].includes(pressed) || !usable(node)
        || node.classList.contains('ds-toggle-button--selected') !== (pressed === 'true')) reject('mode_unverified');
    }
    // Search may be on initially. Only a separately claimed selectMode action
    // can turn it off; loading and discovery never alter either toggle.
    for (const name of ['deepthink_control', 'search_control']) if (!found[name]) retain(name, null);
    return !!send && !!found.deepthink_control && !!found.search_control;
  }
  function composer() {
    const editor = one(visible(document, 'textarea[placeholder="Message DeepSeek"]').filter(node => !authored(node)), 'composer');
    const scope = editor.closest('._020ab5b');
    if (!scope || !c.visible(scope) || c.nodes(scope, 'textarea').length !== 1
      || typeof editor.value !== 'string' || new TextEncoder().encode(editor.value).length > 180_200)
      c.fail('composer_unavailable');
    const send = one(visible(scope, '[role="button"].ds-button--primary.ds-button--circle'), 'send_control');
    const svg = visible(send, 'svg'), paths = c.nodes(send, 'path');
    const terminalArrow = svg.length === 1 && svg[0].getAttribute('viewBox') === '0 0 16 16'
      && paths.length === 1 && paths[0].getAttribute('d') === arrow;
    return { editor, scope, send, text: editor.value, empty: editor.value === '', terminalArrow,
      sendReady: terminalArrow && usable(editor) && usable(send) && c.hit(send),
      streaming: null }; // No negative streaming control was captured.
  }
  function modeControls() {
    const { scope } = composer();
    const toggles = visible(scope, '.ds-toggle-button');
    if (toggles.length !== 2) c.fail('model_unverified');
    const get = label => {
      const node = one(toggles.filter(node => {
        const spans = visible(node, 'span');
        return spans.length === 1 && !spans[0].children.length && spans[0].textContent === label;
      }), 'mode_toggle');
      const pressed = node.getAttribute('aria-pressed');
      if (!['true', 'false'].includes(pressed) || !usable(node)
        || node.classList.contains('ds-toggle-button--selected') !== (pressed === 'true')) c.fail('model_unverified');
      return { node, selected: pressed === 'true' };
    };
    const deepThink = get('DeepThink'), search = get('Search');
    return { deepThink, search, choices: [{ key: 'chat', label: 'Chat' }, { key: 'deepthink', label: 'DeepThink' }] };
  }
  function modeEvidence() {
    const modes = modeControls();
    if (modes.search.selected) c.fail('model_unverified');
    return { selected: modes.choices[modes.deepThink.selected ? 1 : 0],
      source: 'website_mode_toggle', backendModel: null, search: false };
  }
  function transcript() {
    const roots = c.nodes(document, '.ds-message', 2);
    const users = roots.filter(root => root.classList.contains('d29f3d7d'));
    const answers = roots.filter(root => !users.includes(root));
    if (users.length > 1 || answers.length > 1 || answers.length > users.length)
      c.fail('conversation_changed', 'user_count');
    if (!users.length) return { users, answers, first: null, answer: null };
    if (route().kind !== 'canonical') c.fail('conversation_changed', 'conversation_url');
    const root = users[0], container = one(visible(root, '.ds-collapsible-text'), 'first_user_container');
    const body = leaf(container, 'div > span', 'first_user_message'), turn = root.parentElement;
    const id = turn?.getAttribute('data-virtual-list-item-key');
    // Preserve every structural/text check; fixed reasons distinguish a long
    // collapsed rendering from a changed prompt without publishing either body.
    if (!c.visible(root)) c.fail('conversation_changed', 'first_root_hidden');
    if (!id || !/^-?[0-9]{1,10}$/.test(id)) c.fail('conversation_changed', 'first_id_invalid');
    if (container.children.length !== 1) c.fail('conversation_changed', 'first_container_children');
    if (container.children[0].children.length !== 1) c.fail('conversation_changed', 'first_wrapper_children');
    if (container.textContent !== body.textContent) c.fail('conversation_changed', 'first_container_text');
    if (root.textContent !== body.textContent) c.fail('conversation_changed', 'first_root_text');
    let answer = null;
    if (answers.length) {
      const node = answers[0], answerTurn = node.parentElement;
      const answerID = answerTurn?.getAttribute('data-virtual-list-item-key');
      const turns = c.nodes(document, '[data-virtual-list-item-key]', 8);
      if (!c.visible(node) || !answerID || !/^-?[0-9]{1,10}$/.test(answerID) || answerID === id
        || turns.filter(item => item.getAttribute('data-virtual-list-item-key') === id).length !== 1
        || turns.filter(item => item.getAttribute('data-virtual-list-item-key') === answerID).length !== 1
        || turns.indexOf(answerTurn) <= turns.indexOf(turn)) c.fail('conversation_changed', 'response_scope');
      answer = { root: node, turn: answerTurn, id: answerID };
    }
    return { users, answers, first: { root, container, body, turn, id, text: body.textContent }, answer };
  }
  function rawAnswer(answer) {
    if (!answer) return { text: '', finalMarkup: false, formatIssue: false };
    const unsupported = () => ({ text: '', finalMarkup: false, formatIssue: true });
    const finals = c.nodes(answer.root, '.ds-assistant-message-main-content');
    if (!finals.length) return { text: '', finalMarkup: false, formatIssue: false };
    if (finals.length !== 1) return unsupported();
    const final = finals[0];
    if (!c.visible(final) || !final.classList.contains('ds-markdown') || final.parentElement !== answer.root)
      return unsupported();
    const siblings = [...answer.root.children];
    if (siblings.some(node => node !== final && (!node.classList.contains('_74c0879') || siblings.indexOf(node) > siblings.indexOf(final)))
      || siblings.filter(node => node !== final).length > 1
      || [...answer.root.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || '')))
      return unsupported(); // The known reasoning sibling is never traversed/read.
    const child = (parent, tag, cls) => {
      if (!c.visible(parent) || parent.children.length !== 1
        || [...parent.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || ''))) return null;
      const node = parent.children[0];
      return node.tagName === tag && (!cls || node.classList.contains(cls)) && c.visible(node) ? node : null;
    };
    const paragraph = child(final, 'P', 'ds-markdown-paragraph');
    const literal = paragraph && child(paragraph, 'SPAN', null);
    if (!literal || literal.children.length) return unsupported();
    const text = literal.textContent;
    if (typeof text !== 'string' || new TextEncoder().encode(text).length > 220_000) c.fail('response_too_large');
    return { text, finalMarkup: true, formatIssue: false }; // Whole bytes, including malformed JSON.
  }
  function completionCandidate(answer) {
    if (!answer) return false;
    const form = composer(), rails = visible(answer.turn, '.ds-flex._965abe9');
    if (!form.empty || !usable(form.editor) || !form.terminalArrow || rails.length !== 1) return false;
    const rail = rails[0];
    if (rail.closest('.ds-message')) return false;
    const buttons = visible(rail, '[role="button"]');
    const readAloud = buttons.filter(node => node.getAttribute('aria-label') === 'Read aloud');
    return buttons.length === 6 && buttons.every(usable) && readAloud.length === 1;
  }
  function sameFirst(first) {
    const now = transcript().first;
    return !!first && !!now && first.root === now.root && first.container === now.container
      && first.body === now.body && first.turn === now.turn && first.id === now.id && first.text === now.text;
  }
  function ownedAnchor(conversationURL) {
    return one(c.nodes(document, 'a[href]', 512).filter(node => {
      try { return new URL(node.getAttribute('href'), document.URL).href === conversationURL; } catch { return false; }
    }), 'delete_anchor');
  }
  function deletionContext(first) {
    const current = route();
    if (current.kind !== 'canonical' || !sameFirst(first)
      || visible(document, '[role="menu"], [role="dialog"], .ds-modal').length) c.fail('conversation_changed', 'delete_ownership');
    const anchor = ownedAnchor(current.canonical);
    if (!c.visible(anchor) || authored(anchor)) c.fail('conversation_changed', 'delete_anchor');
    const trigger = one(visible(anchor, '[role="button"].ds-button'), 'delete_trigger');
    return { conversationURL: current.canonical, first, anchor, trigger };
  }
  function deletionGuard(record) {
    const context = record?.driverContext, current = route();
    if (!context || record.conversationURL !== context.conversationURL || current.canonical !== context.conversationURL
      || !sameFirst(context.first) || ownedAnchor(context.conversationURL) !== context.anchor
      || !c.visible(context.anchor) || record.trigger !== context.trigger
      || one(visible(context.anchor, '[role="button"].ds-button'), 'delete_trigger') !== context.trigger)
      c.fail('conversation_changed', 'delete_ownership');
    return context;
  }
  function deletionTrigger(context) {
    deletionGuard({ driverContext: context, conversationURL: context?.conversationURL, trigger: context?.trigger });
    // Return identity for subsequent scoped checks even if the owned popup
    // covers this control. The engine checks the hit before its sole click.
    return context.trigger;
  }
  function deletionMenu(record) {
    deletionGuard(record);
    if (record.menuAcknowledged !== true || record.deleteAcknowledged === true) c.fail('conversation_changed', 'delete_phase');
    const menu = optional(visible(document, '[role="menu"]'), 'delete_menu');
    if (!menu) return null;
    if (!menu.classList.contains('ds-dropdown-menu') || authored(menu) || record.menu && record.menu !== menu)
      c.fail('conversation_changed', 'delete_menu');
    const target = one(visible(menu, '.ds-dropdown-menu-option').filter(node => {
      const labels = visible(node, '.ds-dropdown-menu-option__label');
      return labels.length === 1 && !labels[0].children.length && labels[0].textContent === 'Delete';
    }), 'delete_control');
    if (!target.classList.contains('ds-dropdown-menu-option--error')) c.fail('conversation_changed', 'delete_control');
    return { menu, target: c.hit(target) ? target : null };
  }
  function deletionConfirmation(record) {
    deletionGuard(record);
    if (record.menuAcknowledged !== true || record.deleteAcknowledged !== true
      || !record.menu?.classList.contains('ds-dropdown-menu') || visible(document, '[role="menu"]').length)
      c.fail('conversation_changed', 'delete_phase');
    const dialog = optional(visible(document, '[role="dialog"]'), 'delete_dialog');
    if (!dialog) return null;
    const modal = dialog.closest('.ds-modal');
    const title = leaf(dialog, '.ds-modal-content__title', 'delete_title');
    const body = leaf(dialog, '.ds-modal-content__main', 'delete_body');
    const group = one(visible(dialog, '.ds-modal-content__button-group'), 'delete_buttons');
    const buttons = visible(group, '[role="button"]');
    const button = label => one(buttons.filter(node => {
      const labels = visible(node, '.ds-button__content');
      return labels.length === 1 && !labels[0].children.length && labels[0].textContent === label;
    }), 'delete_control');
    const target = button('Delete chat'), cancel = button('Cancel');
    if (!modal || modal.getAttribute('aria-modal') !== 'true' || visible(document, '.ds-modal').length !== 1
      || !dialog.classList.contains('ds-modal-content--dialog') || authored(dialog)
      || title.textContent !== 'This chat can’t be recovered.' || body.textContent !== 'Share links from it will be disabled.'
      || buttons.length !== 2 || !target.classList.contains('ds-button--error')
      || !cancel.classList.contains('ds-button--outlinedNeutral') || record.dialog && record.dialog !== dialog)
      c.fail('conversation_changed', 'delete_confirmation');
    return { dialog, target: c.hit(target) ? target : null };
  }
  function deletionObserved(record) {
    const context = record?.driverContext;
    if (!context || record.conversationURL !== context.conversationURL || record.confirmAcknowledged !== true)
      c.fail('conversation_changed', 'delete_operation');
    if (route().kind !== 'fresh' || !visible(document, 'textarea[placeholder="Message DeepSeek"]').length) return false;
    const form = composer();
    return form.empty && usable(form.editor) && form.terminalArrow
      && c.nodes(document, '.ds-message, [role="dialog"], .ds-modal').length === 0
      && !!record.dialog && !record.dialog.isConnected && !context.anchor.isConnected
      && [context.first.root, context.first.body].every(node => !node.isConnected)
      && record.roots.every(node => !node.isConnected)
      && c.nodes(document, 'a[href]', 512).every(node => {
        try { return new URL(node.getAttribute('href'), document.URL).href !== record.conversationURL; } catch { return false; }
      });
  }
  function insertLiteral(form, prompt) {
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (!(form.editor instanceof HTMLTextAreaElement) || typeof setter !== 'function') c.fail('composer_unavailable');
    setter.call(form.editor, prompt);
    form.editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
  }
  return { route, authored, initialReady, composer, modeControls, modeEvidence, transcript, rawAnswer, completionCandidate,
    deletionContext, deletionTrigger, deletionMenu, deletionConfirmation, deletionObserved, insertLiteral };
}

// Workspace composition only. Native has no mode-selection proof case yet.
try {
  const actions = ['inspect', 'discoverModes', 'selectMode', 'verifyMode', 'prepare', 'insert', 'sendReady', 'submit', 'stop',
    'deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'deepseek', 'https://chat.deepseek.com', actions);
  return await computaSavedConversation(input, c, computaDeepSeekDOM(c), {
    stateKey: '__computaDeepSeekSavedSessionV1', origin: 'https://chat.deepseek.com', selectionKind: 'mode'
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}
