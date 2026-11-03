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

// Failure-only, bounded element metadata. No text values, HTML, DOM IDs,
// arbitrary class/attribute strings, document-wide queries or page mutations.
function computaSavedFailureTree(root, c, categories) {
  const tags = new Set(['div', 'span', 'p', 'pre', 'code', 'header', 'svg', 'path', 'button', 'input', 'textarea', 'br', 'ul', 'ol', 'li', 'a', 'section', 'article']);
  const known = new Set(categories.map(row => row[0]));
  const category = node => categories.find(row => node.classList.contains(row[0]))?.[1] || 'other';
  const tree = [], nodes = [], stack = root ? [{ node: root, parent: -1, depth: 0 }] : [];
  let nodeLimitReached = false;
  while (stack.length) {
    if (tree.length >= 256) { nodeLimitReached = true; break; }
    const { node, parent, depth } = stack.pop();
    if (!node || node.nodeType !== 1) continue;
    const kind = category(node), reasoningExcluded = kind === 'reasoning';
    let unknownClassPresent = false, tokens = 0;
    for (const name of node.classList) {
      if (++tokens > 32) { unknownClassPresent = true; break; }
      if (!known.has(name)) unknownClassPresent = true;
    }
    const total = reasoningExcluded ? 0 : node.children.length, childCountOverflow = total > 257;
    const name = typeof node.tagName === 'string' ? node.tagName.toLowerCase() : 'other';
    const interactive = ['button', 'input', 'textarea', 'a'].includes(name)
      || ['role', 'tabindex', 'contenteditable', 'onclick', 'onkeydown'].some(key => node.getAttribute(key) !== null);
    const index = tree.length;
    tree.push({ parent, depth, tag: tags.has(name) ? name : 'other', category: kind,
      unknownClassPresent, visible: c.visible(node), interactive,
      elementChildCount: Math.min(total, 257), childCountOverflow, reasoningExcluded });
    nodes.push(node);
    if (reasoningExcluded) continue; // Never walk or read a reasoning subtree.
    if (childCountOverflow || depth === 16 && total) nodeLimitReached = true;
    if (depth === 16) continue;
    // The stack itself is bounded as well as the emitted tree.
    const budget = Math.max(0, 256 - tree.length - stack.length), take = Math.min(total, budget);
    if (take < total) nodeLimitReached = true;
    for (let i = take - 1; i >= 0; i--) stack.push({ node: node.children[i], parent: index, depth: depth + 1 });
  }
  return { tree, nodes, nodeLimitReached, category };
}

function computaSavedFirstBodyComparison(actual, expected) {
  if (typeof actual !== 'string' || typeof expected !== 'string' || actual === expected) return null;
  const limit = 180200, complete = actual.length <= limit && expected.length <= limit;
  const result = { comparisonComplete: complete,
    actualUTF16Length: Math.min(actual.length, limit + 1), expectedUTF16Length: Math.min(expected.length, limit + 1),
    actualUTF8Length: 540601, expectedUTF8Length: 540601, commonPrefixLength: 0, commonSuffixLength: 0,
    exactEqual: false, lfDelta: 0, crDelta: 0, nbspDelta: 0,
    nfcEqual: false, crlfEqual: false, trimEqual: false, mismatchCategory: 'other' };
  if (!complete) return result;
  result.actualUTF8Length = new TextEncoder().encode(actual).length;
  result.expectedUTF8Length = new TextEncoder().encode(expected).length;
  const minimum = Math.min(actual.length, expected.length);
  while (result.commonPrefixLength < minimum && actual[result.commonPrefixLength] === expected[result.commonPrefixLength]) result.commonPrefixLength++;
  while (result.commonSuffixLength < minimum - result.commonPrefixLength
    && actual[actual.length - 1 - result.commonSuffixLength] === expected[expected.length - 1 - result.commonSuffixLength]) result.commonSuffixLength++;
  const counts = value => { const counts = [0, 0, 0]; for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i); if (code === 10) counts[0]++; else if (code === 13) counts[1]++; else if (code === 160) counts[2]++;
  } return counts; };
  const a = counts(actual), e = counts(expected);
  [result.lfDelta, result.crDelta, result.nbspDelta] = a.map((value, i) => value - e[i]);
  result.nfcEqual = actual.normalize('NFC') === expected.normalize('NFC');
  result.crlfEqual = actual.replace(/\r\n?/g, '\n') === expected.replace(/\r\n?/g, '\n');
  result.trimEqual = actual.trim() === expected.trim();
  result.mismatchCategory = result.crlfEqual ? 'line_endings_only'
    : actual.replace(/\s/g, '') === expected.replace(/\s/g, '') ? 'whitespace_only'
    : expected.startsWith(actual) ? 'prefix_only' : expected.endsWith(actual) ? 'suffix_only'
    : result.commonPrefixLength > 0 && result.commonSuffixLength > 0 ? 'internal' : 'other';
  return result;
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
      initialControls: {}, initialReadComplete: false, modeHandoff: null, responseIdentity: null, submittedFingerprint: null
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
    if (state.firstDisplay && !state.first && (input.action !== 'inspect' || cleanupInspection
      || !state.firstDisplay.complete && input.allowQwenFirstBodyExpansion !== true || input.allowQwenInitialResponseIdentity !== true))
      firstBindingFailure('display_scope', 'held_claim_ineligible');
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
    function firstBindingFailure(stage, reason, structure = null) {
      // Diagnostic-only classification of an already rejected guard. Keep the
      // public category/detail and terminal behavior; never publish page data.
      let diagnostic;
      if (config.stateKey === '__computaQwenSavedSessionV1') {
        try { diagnostic = { version: 1, stage, reason: typeof reason === 'function' ? reason() : reason }; }
        catch { /* Diagnostic reads cannot replace the original refusal. */ }
      }
      try { c.fail('conversation_changed', 'first_user_message'); }
      catch (error) {
        if (diagnostic && error?.computaAdapterFailure) {
          error.qwenFirstUserBindingDiagnostic = diagnostic;
          if (stage === 'display_completed' && diagnostic.reason === 'user_id_changed' && typeof structure === 'function') {
            try { diagnostic.change = structure(); } catch { /* Never replace the ownership rejection. */ }
          }
          if (stage === 'initial_response_body' && diagnostic.reason === 'full_prompt_mismatch' && typeof structure === 'function') {
            try { const packet = structure(); if (packet) error.adapterFailureStructure = packet; } catch { /* Preserve the original refusal. */ }
          }
        }
        throw error;
      }
    }
    const initialFirstAdmissionReason = provisional => {
      if (input.action !== 'inspect') return 'action_not_inspect';
      if (input[provisional ? 'allowQwenProvisionalRoute' : 'allowQwenInitialResponseIdentity'] !== true) return 'native_grant_missing';
      if (cleanupInspection) return 'cleanup_inspection';
      if (provisional && !state.submitted) return 'submission_unclaimed';
      if (!state.inserted) return 'insertion_missing';
      if (!state.prepared) return 'preparation_missing';
      if (!state.send) return 'send_missing';
      if (!state.model) return 'model_missing';
      if (state.selection) return 'selection_pending';
      if (provisional && state.first) return 'first_already_bound';
      if (provisional && state.canonical) return 'canonical_already_bound';
      if (state.deletion) return 'deletion_started';
      if (input.allowFirstUserBinding !== true) return 'binding_not_authorized';
      if (input.expectedFirstUserFingerprint != null) return 'expected_fingerprint_present';
      if (!c.uuid(input.expectedFirstUserMarker)) return 'marker_invalid';
      if (input.expectedFirstUserMarker !== state.inserted.marker) return 'marker_mismatch';
      if (!state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)) return 'marker_suffix';
      if (!c.equalChoice(input.expectedModelChoice, state.model.choice)) return 'model_choice_mismatch';
      if (!/^[a-f0-9]{64}$/.test(state.submittedFingerprint || '')) return 'submitted_fingerprint_invalid';
      if (input.savedSubmissionFingerprint !== state.submittedFingerprint) return 'submitted_fingerprint_mismatch';
      return 'predicate_changed';
    };
    const tagFirstBodyHashFailure = (error, stage) => {
      if (config.stateKey === '__computaQwenSavedSessionV1' && error?.computaAdapterFailure
        && error.error === 'conversation_changed' && error.detail === 'first_user_message')
        error.qwenFirstUserBindingDiagnostic = { version: 1, stage, reason: 'hash_input_invalid' };
    };
    const pickerHit = (node, stage) => {
      const reason = c.hitFailure(node);
      if (reason) c.fail('model_unverified', stage + '_' + reason);
    };
    const picker = () => {
      const closing = state.selection?.stage === 'closing' ? state.selection : null;
      const selecting = state.selection?.stage === 'selected' ? state.selection : null;
      // The driver may observe a split DOM/ARIA close only for this claimed,
      // still-owned operation. It cannot adopt a menu or dispatch another click.
      if (closing || selecting) guard();
      return dom.picker(closing, selecting);
    };
    let modeObservationDiagnostic = null;
    function selectionEvidence(required = true, stage = 'bound') {
      if (usesModes) {
        modeObservationDiagnostic = null;
        const controls = dom.modeControls(), selected = state.mode?.choice;
        if (input.modelChoice != null || input.expectedModelChoice != null) c.fail('mode_unverified', 'mode_named_input');
        // Finite diagnostics only: retain the same required/optional failure
        // behavior and physical pins; never adopt remounted controls here.
        const unverified = detail => {
          // Classify this existing read only. A false/optional proof must still
          // fail native validation; diagnostic flags grant no selection proof.
          let diagnostic;
          if (state.submitted) {
            try {
              diagnostic = { version: 1, reason: detail, required, boundSelectionPresent: !!selected,
                boundMode: selected ? ['chat', 'deepthink'].includes(selected.key) ? selected.key : 'other' : 'absent',
                deepThinkSelected: controls.deepThink.selected, searchSelected: controls.search.selected,
                deepThinkSameNode: controls.deepThink.node === state.mode?.deepThink,
                searchSameNode: controls.search.node === state.mode?.search,
                modeMatches: !!selected && c.equalChoice(controls.choices[controls.deepThink.selected ? 1 : 0], selected),
                deepThinkWasConnected: state.mode?.deepThink?.isConnected === true,
                searchWasConnected: state.mode?.search?.isConnected === true,
                composerSameNode: controls.scope === state.prepared?.scope,
                composerWasConnected: state.prepared?.scope?.isConnected === true,
                firstBodyBound: !!state.first };
            } catch { /* Metadata cannot change the original proof failure. */ }
          }
          if (required) {
            try { c.fail('mode_unverified', detail); }
            catch (error) {
              if (diagnostic && error?.computaAdapterFailure) error.modeObservationDiagnostic = diagnostic;
              throw error;
            }
          }
          modeObservationDiagnostic = diagnostic || null;
          return null;
        };
        if (!selected) return unverified('mode_unbound');
        if (controls.search.selected) return unverified('search_selected');
        if (controls.deepThink.node !== state.mode.deepThink) return unverified('deepthink_replaced');
        if (controls.search.node !== state.mode.search) return unverified('search_replaced');
        const evidence = dom.modeEvidence();
        if (!c.equalChoice(evidence.selected, selected)) return unverified('mode_choice_changed');
        if (input.expectedModeChoice != null && !c.equalChoice(selected, input.expectedModeChoice)) c.fail('mode_mismatch');
        return evidence;
      }
      const p = picker(), selected = state.model?.choice;
      if (state.selection?.stage === 'selected' || !selected || !p.closed
        || p.trigger !== state.model.trigger || p.label !== selected.label) {
        if (required) {
          const reason = state.selection?.stage === 'selected' ? 'selection_pending' : !selected ? 'choice_unbound'
            : !p.closed ? 'picker_open' : p.trigger !== state.model.trigger ? 'trigger_replaced' : 'label_changed';
          dom.rejectSelectionBinding(stage, reason, state.model?.trigger);
        }
        return null;
      }
      if (input.expectedModelChoice != null && !c.equalChoice(selected, input.expectedModelChoice)) c.fail('model_mismatch', 'selection_target');
      return { selected, verification: 'website_selection', source: 'model_picker_label' };
    }
    function observeInitialModeHandoff(initial) {
      // DeepSeek mounts a new empty composer after the first Send. Pin that
      // complete replacement once; it has no mode or response authority until
      // the exact submitted first body has survived its ordinary hash checks.
      if (config.initialModeHandoff !== true || input.allowDeepSeekComposerHandoff !== true || !usesModes || input.action !== 'inspect'
        || cleanupInspection || state.first || state.deletion || !state.submitted || !state.inserted
        || !state.mode || state.modeSelection || !state.prepared || !state.send
        || !/^[a-f0-9]{64}$/.test(state.submittedFingerprint || '')
        || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null
        || !c.uuid(input.expectedFirstUserMarker) || input.expectedFirstUserMarker !== state.inserted.marker
        || !state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)
        || !c.equalChoice(input.expectedModeChoice, state.mode.choice)
        || route.kind !== 'canonical' || state.canonical !== route.canonical)
        c.fail('mode_unverified', 'composer_handoff_ineligible');
      const form = initial.form, controls = dom.modeControls();
      if (!form.empty || controls.scope !== form.scope || !c.enabled(form.editor)
        || state.prepared.scope.isConnected || state.prepared.editor.isConnected || state.send.isConnected
        || state.mode.deepThink.isConnected || state.mode.search.isConnected
        || form.scope === state.prepared.scope || form.editor === state.prepared.editor || form.send === state.send
        || controls.deepThink.node === state.mode.deepThink || controls.search.node === state.mode.search
        || controls.search.selected
        || !c.equalChoice(controls.choices[controls.deepThink.selected ? 1 : 0], state.mode.choice))
        c.fail('mode_unverified', 'composer_handoff_binding');
      const current = { scope: form.scope, editor: form.editor, send: form.send,
        deepThink: controls.deepThink.node, search: controls.search.node, canonical: route.canonical };
      if (state.modeHandoff) {
        if (state.modeHandoff.committed || Object.keys(current).some(key => state.modeHandoff[key] !== current[key]))
          c.fail('mode_unverified', 'composer_handoff_changed');
      } else state.modeHandoff = { ...current, committed: false };
      return state.modeHandoff;
    }
    function commitInitialModeHandoff(first, fingerprint) {
      const claim = state.modeHandoff;
      if (!claim || claim.committed || fingerprint !== state.submittedFingerprint
        || dom.route().canonical !== claim.canonical || !sameFirst(first))
        c.fail('mode_unverified', 'composer_handoff_changed');
      // Recompute every current physical and semantic predicate after hashing;
      // only these held controls can replace the detached pre-Send handles.
      observeInitialModeHandoff({form: dom.composer()});
      state.mode = { choice: state.mode.choice, deepThink: claim.deepThink, search: claim.search };
      claim.committed = true;
    }
    function sameFirst(first) {
      const current = dom.transcript();
      validateInitialResponseIdentity(current, 'body_digest_check');
      const now = current.first;
      return !!first && !!now && first.root === now.root && first.body === now.body
        && first.container === now.container && first.id === now.id && first.text === now.text;
    }
    function validateInitialResponseIdentity(t, readPoint) {
      if (state.firstDisplay?.complete && !state.first) {
        const view = dom.firstBodyPresentation(t);
        requireSameFirstDisplay(view, 'display_completed', () => {
          // Only evaluated after rejecting two unequal, strictly validated user IDs.
          const held = state.firstDisplay;
          const reply = held.answerID === null ? (view.answerID === null ? 'pending' : 'settled_now')
            : held.answerID === view.answerID ? 'stable' : 'changed';
          return { point: readPoint, spelling: held.userID.toLowerCase() === view.userID.toLowerCase() ? 'case_only' : 'different_uuid',
            pins: held.pins.length === view.pins.length && held.pins.every((node, index) => node === view.pins[index]) ? 'same' : 'changed',
            body: t.first.text === state.inserted.prompt ? 'exact' : 'changed', display: view.collapsed ? 'collapsed' : 'expanded',
            reply, responseIdentity: state.responseIdentity ? 'held' : 'absent' };
        });
        if (view.collapsed) firstBindingFailure('display_completed', 'recollapsed');
        if (t.first.text !== state.inserted.prompt) firstBindingFailure('display_completed', 'full_text_changed');
        if (view.answerID !== null) state.firstDisplay.answerID = view.answerID;
      }
      const held = state.responseIdentity;
      if (!held) return;
      const first = t.first, answer = t.pendingAnswer || t.answer;
      if (dom.route().canonical !== held.canonical || !first || !answer
        || first.root !== held.first.root || first.container !== held.first.container
        || first.body !== held.first.body || first.id !== held.first.id || first.text !== held.first.text
        || first.root.parentElement !== held.userTurn || held.userTurn.parentElement !== held.outer
        || answer.root !== held.answer.root || answer.content !== held.answer.content
        || answer.root.parentElement !== held.answer.turn || held.answer.turn.parentElement !== held.outer)
        c.fail('conversation_changed', 'response_scope');
    }
    // Compare existing physical pins in their original order. Report only the
    // first failing group; no selector, attribute, text or hit test is reread.
    function requireSameFirstDisplay(view, stage, rejectedIdentityFacts = null) {
      const held = state.firstDisplay;
      const reject = reason => firstBindingFailure(stage, reason);
      if (!view) reject('presentation_missing');
      if (held.canonical !== dom.route().canonical) reject('route_changed');
      if (held.userID !== view.userID) firstBindingFailure(stage, 'user_id_changed', rejectedIdentityFacts);
      if (held.answerID !== null && held.answerID !== view.answerID) reject('answer_id_changed');
      if (held.pins.length !== view.pins.length) reject('pin_count_changed');
      const i = held.pins.findIndex((node, i) => node !== view.pins[i]);
      if (i >= 0) reject(i === 0 ? 'body_changed' : i === 1 ? 'control_changed'
        : i < held.pins.length - 3 ? 'user_ancestry_changed' : 'answer_ancestry_changed');
    }
    // Only the native-granted long Qwen display may pin a detached picker's
    // replacement. This observation publishes no evidence. Normal selection
    // reads continue to use the original handle until first-body ownership binds.
    function checkFirstDisplaySelection(stage, allowReplacement = false) {
      const claim = state.firstDisplay;
      if (state.first || !claim || !claim.replacement && (!allowReplacement || state.model.trigger.isConnected !== false)) {
        selectionEvidence(true, stage);
        return;
      }
      claim.replacement = dom.firstDisplayReplacement(state.model.trigger, claim.replacement, state.model.choice, stage);
    }
    // An empty body can only wait. A complete exact observed preview can spend
    // one local display claim. Neither path exposes model output or grants ownership.
    function observeFirstDisplay(t) {
      const prompt = state.inserted.prompt;
      const previewLength = 10_240;
      const held = state.firstDisplay;
      // The completed presentation was revalidated above. An ID-only receipt can
      // continue without a new display grant and can never spend another click.
      if (held?.complete) return false;
      if (!held && (state.responseIdentity || !t.first || t.first.text === prompt || prompt.length <= previewLength)) return false;
      if (input.allowQwenFirstBodyExpansion !== true) {
        if (held) firstBindingFailure('display_scope', 'display_grant_missing');
        return false;
      }
      const view = dom.firstBodyPresentation(t);
      if (!view && !held) return false; // Ordinary full-body mismatch follows.
      const reject = reason => firstBindingFailure('display_observation', reason);
      if (held) requireSameFirstDisplay(view, 'display_held');
      if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.length || input.expectedUserCounts.length > 2
        || input.expectedUserCounts.some(value => ![0, 1].includes(value)) || !input.expectedUserCounts.includes(1)) reject('user_count_expectation');
      const form = dom.composer();
      if (!form.empty || !c.enabled(form.editor)) reject('composer_not_ready');
      const text = t.first.text;
      const preview = text.length === previewLength && prompt.startsWith(text);
      const settlement = held?.settlement;
      const renderFailure = reason => firstBindingFailure('display_settlement', reason);
      if (settlement && (view.answerID !== settlement.answerID || form.editor !== settlement.editor
        || form.scope !== settlement.scope || !view.collapsed || text !== settlement.text
        || state.model !== settlement.model || state.inserted !== settlement.inserted || state.send !== settlement.send))
        renderFailure('render_binding_changed');
      if (!held && !view.collapsed) reject('initial_not_collapsed');
      if (!held && !preview && (text !== '' || !t.pendingAnswer)) {
        reject(text === '' ? 'initial_empty_no_pending_answer' : text.length === previewLength ? 'initial_prefix_mismatch' : 'initial_length_mismatch');
      }
      const claim = held || (state.firstDisplay = { ...view, canonical: route.canonical, clicked: false, sawExpanded: false, complete: false });
      checkFirstDisplaySelection(claim.clicked ? 'display_after_click' : 'display_before_click', !settlement && !claim.clicked && view.collapsed);
      if (claim.sawExpanded && view.collapsed) reject('recollapsed');
      if (!view.collapsed) claim.sawExpanded = true;
      if (view.answerID !== null) claim.answerID = view.answerID;
      if (!view.collapsed && text === prompt && claim.clicked) {
        claim.complete = true;
        return false; // Continue through exact first-body/hash/marker/response-ID verification.
      }
      if (view.collapsed && text === '' && !claim.clicked) return true;
      if (!preview) reject(text.length === previewLength ? 'preview_prefix_mismatch' : 'preview_length_mismatch');
      if (claim.clicked) return true; // Same preview during the one local display transition.
      if (!view.collapsed) reject('not_collapsed');
      const checkedControl = () => {
        guard();
        const current = dom.initialResponseIdentityTranscript(), currentView = dom.firstBodyPresentation(current);
        checkFirstDisplaySelection('display_preclick');
        requireSameFirstDisplay(currentView, 'display_preclick');
        if ((settlement || claim.scrolled) && currentView.answerID !== view.answerID) renderFailure('render_binding_changed');
        if (settlement) {
          const picker = dom.picker();
          if (picker.trigger !== settlement.trigger || picker.name !== settlement.name) renderFailure('render_binding_changed');
        }
        if (!currentView.collapsed) firstBindingFailure('display_preclick', 'not_collapsed');
        if (current.first.text !== text) firstBindingFailure('display_preclick', 'preview_changed');
        const currentForm = dom.composer();
        if (!currentForm.empty) firstBindingFailure('display_preclick', 'composer_not_empty');
        if (currentForm.editor !== form.editor || currentForm.scope !== form.scope || !c.enabled(currentForm.editor)) firstBindingFailure('display_preclick', 'composer_changed');
        return currentView.control;
      };
      const point = {};
      if (settlement) {
        checkedControl();
        const status = settlement.watch.current();
        if (status === 'waiting') return true;
        if (status !== 'ready') renderFailure(status);
      }
      let hit = dom.displayHitFailure(view.control, point, !!settlement);
      if (settlement && hit !== null) firstBindingFailure('display_reveal_hit', hit);
      if ((hit === 'occluded' || hit === 'outside_viewport') && !claim.scrolled && typeof view.control.scrollIntoView === 'function') {
        const control = checkedControl();
        claim.scrolled = true;
        // Scroll changes presentation only. A usable hit must come from the pinned control.
        try { control.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' }); }
        catch { firstBindingFailure('display_reveal_hit', 'scroll_failed'); }
        const blockers = [];
        hit = dom.displayHitFailure(checkedControl(), point, true, blockers);
        if (hit === 'occluded_unrelated') {
          const picker = dom.picker();
          const wake = () => {
            if (state.terminal || !c.context() || state.firstDisplay !== claim) return;
            try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ownerToken:input.ownerToken,kind:'dom_changed'}); }
            catch { /* The native deadline still applies. */ }
          };
          const watch = dom.watchDisplayRender([...view.pins, form.editor, form.scope, picker.trigger, picker.name],
            [t.first.body, picker.name], form.editor, blockers, wake);
          if (watch) {
            claim.settlement = { watch, answerID:view.answerID, editor:form.editor, scope:form.scope, trigger:picker.trigger, name:picker.name, text,
              model:state.model, inserted:state.inserted, send:state.send };
            return true;
          }
        }
        if (hit !== null) firstBindingFailure('display_reveal_hit', hit);
      } else if (hit !== null) firstBindingFailure('display_hit', hit);
      const currentHit = dom.displayHitFailure(checkedControl(), point, claim.scrolled === true);
      if (currentHit !== null) firstBindingFailure(claim.scrolled ? 'display_reveal_hit' : 'display_preclick_hit', currentHit);
      if (settlement) {
        const status = settlement.watch.current();
        if (status !== 'ready') renderFailure(status);
        settlement.watch.consume(); delete claim.settlement;
      }
      claim.clicked = true;
      view.control.click();
      return true;
    }
    function read() {
      const t = dom.transcript(), form = dom.composer(), evidence = selectionEvidence(false), extracted = dom.rawAnswer(t.answer);
      validateInitialResponseIdentity(t, 'ordinary_read');
      state.initialReadComplete = true;
      const terminalUI = !!state.first && !!evidence && !state.deletion && dom.completionCandidate(t.answer);
      if (terminalUI && extracted.formatIssue && !cleanupInspection && !deletionActions.includes(input.action)) {
        try { c.fail('unsupported_response_format', 'authored_source'); }
        catch (error) {
          if (input.action === 'inspect' && config.stateKey === '__computaDeepSeekSavedSessionV1' && error?.computaAdapterFailure
            && typeof extracted.failureStructure === 'function') {
            try { const packet = extracted.failureStructure(); if (packet) error.adapterFailureStructure = packet; } catch { /* Preserve the original refusal. */ }
          }
          throw error;
        }
      }
      const complete = terminalUI && extracted.finalMarkup && !!extracted.text.trim();
      return { t, form, output: { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
        composer: c.enabled(form.editor), userCount: t.users.length, responseCount: t.answers.length,
        [usesModes ? 'modeEvidence' : 'modelEvidence']: evidence,
        ...(usesModes && !evidence && modeObservationDiagnostic ? { modeObservationDiagnostic } : {}),
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
      const p = picker();
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
      if (selection.stage === 'selected') {
        // A claimed option may close asynchronously. Do not fight that close
        // with another click, and do not treat its label as model authority.
        if (!p.closed || p.label !== selection.target.label) return { ...read().output, pending: true };
        pickerHit(p.trigger, 'picker_verify');
        selection.stage = 'verifying'; selection.menu = null; selection.option = null;
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
        selection.option = { node: target.node, previous: checked, choices: rows.map(row => row.choice) };
        selection.stage = 'selected'; target.node.click(); return { ...read().output, pending: true };
      }
      selection.choice = target.choice; selection.checked = target.node;
      selection.choices = rows.map(row => row.choice); selection.stage = 'closing';
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
    if (config.initialProvisionalRoute === true && route.kind === 'provisional') {
      // Qwen briefly exposes /c/new-chat after Send. This read cannot inspect
      // canonical message IDs, grant model proof, or dispatch any action.
      // Native independently requires its acknowledged first Send and deadline.
      if (input.action !== 'inspect' || input.allowQwenProvisionalRoute !== true || cleanupInspection
        || !state.submitted || !state.inserted || !state.prepared || !state.send || !state.model
        || state.selection || state.first || state.canonical || state.deletion
        || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null
        || !c.uuid(input.expectedFirstUserMarker) || input.expectedFirstUserMarker !== state.inserted.marker
        || !state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)
        || !c.equalChoice(input.expectedModelChoice, state.model.choice)
        || !/^[a-f0-9]{64}$/.test(state.submittedFingerprint || '')
        || input.savedSubmissionFingerprint !== state.submittedFingerprint)
        firstBindingFailure('provisional_admission', () => initialFirstAdmissionReason(true));
      guard();
      return { qwenProvisionalRoutePending: true, url: document.URL,
        sessionLifecycle: 'saved_conversation_delete', temporary: false };
    }
    if (config.initialResponseIdentity === true && state.submitted && !state.first && route.kind === 'canonical'
      && (input.allowQwenInitialResponseIdentity === true || state.responseIdentity)) {
      // A canonical route alone grants nothing. The native first-Send grant and
      // the exact rendered outbound body are mandatory, but no positive body,
      // model, response or deletion proof is published until the ID is strict.
      if (input.action !== 'inspect' || input.allowQwenInitialResponseIdentity !== true || cleanupInspection
        || !state.inserted || !state.prepared || !state.send || !state.model || state.selection || state.deletion
        || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null
        || !c.uuid(input.expectedFirstUserMarker) || input.expectedFirstUserMarker !== state.inserted.marker
        || !state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)
        || !c.equalChoice(input.expectedModelChoice, state.model.choice)
        || !/^[a-f0-9]{64}$/.test(state.submittedFingerprint || '')
        || input.savedSubmissionFingerprint !== state.submittedFingerprint)
        firstBindingFailure('initial_response_admission', () => initialFirstAdmissionReason(false));
      const candidate = dom.initialResponseIdentityTranscript();
      validateInitialResponseIdentity(candidate, 'id_candidate');
      if (observeFirstDisplay(candidate)) return { qwenFirstBodyExpansionPending: true, url: document.URL,
        sessionLifecycle: 'saved_conversation_delete', temporary: false };
      if (candidate.pendingAnswer) {
        if (candidate.users.length !== 1 || candidate.answers.length !== 1 || !candidate.first
          || candidate.first.text !== state.inserted.prompt || !Array.isArray(input.expectedUserCounts)
          || !input.expectedUserCounts.length || input.expectedUserCounts.length > 2
          || input.expectedUserCounts.some(value => ![0, 1].includes(value)) || !input.expectedUserCounts.includes(1))
          firstBindingFailure('initial_response_body', () => candidate.users.length !== 1 ? 'user_count'
            : candidate.answers.length !== 1 ? 'answer_count' : !candidate.first ? 'first_missing'
            : candidate.first.text !== state.inserted.prompt ? 'full_prompt_mismatch'
            : !Array.isArray(input.expectedUserCounts) ? 'counts_not_array'
            : !input.expectedUserCounts.length ? 'counts_empty' : input.expectedUserCounts.length > 2 ? 'counts_limit'
            : input.expectedUserCounts.some(value => ![0, 1].includes(value)) ? 'counts_invalid'
            : !input.expectedUserCounts.includes(1) ? 'one_user_not_expected' : 'predicate_changed',
            () => dom.firstBodyFailureStructure(candidate.first, state.inserted.prompt));
        checkFirstDisplaySelection('id_before_hash');
        if (!state.responseIdentity) state.responseIdentity = { canonical: route.canonical,
          first: candidate.first, answer: candidate.pendingAnswer,
          userTurn: candidate.first.root.parentElement, outer: candidate.pendingAnswer.outer };
        let fingerprint;
        try { fingerprint = await c.hash(c.bodyText(candidate.first.text)); }
        catch (error) { tagFirstBodyHashFailure(error, 'initial_response_digest'); throw error; }
        guard();
        const current = dom.initialResponseIdentityTranscript();
        validateInitialResponseIdentity(current, 'id_digest_check');
        checkFirstDisplaySelection('id_after_hash');
        if (fingerprint !== state.submittedFingerprint) firstBindingFailure('initial_response_digest', 'submitted_fingerprint_mismatch');
        if (current.pendingAnswer) return { qwenInitialResponseIdentityPending: true, url: document.URL,
          sessionLifecycle: 'saved_conversation_delete', temporary: false };
        // The same nodes may settle during hashing. Re-enter the ordinary
        // strict transcript, full body hash, model and completion checks below.
      }
    }
    let initial = read();
    if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.length || input.expectedUserCounts.length > 2
      || input.expectedUserCounts.some(value => ![0, 1].includes(value)) || !input.expectedUserCounts.includes(initial.t.users.length))
      c.fail('conversation_changed', 'user_count');
    // Diagnostic-only mode detail: Qwen retains its existing detail and both
    // providers retain all exact body, marker, identity and fingerprint gates.
    const firstFailure = detail => usesModes ? c.fail('conversation_changed', detail) : firstBindingFailure('binding', detail);
    if (config.initialModeHandoff === true && !state.first
      && (state.modeHandoff || state.submitted && initial.output.modeEvidence == null
        && state.prepared?.scope.isConnected === false && state.prepared.editor.isConnected === false
        && state.send?.isConnected === false && state.mode?.deepThink.isConnected === false
        && state.mode.search.isConnected === false)) {
      observeInitialModeHandoff(initial);
      if (!initial.t.first) {
        if (initial.t.users.length !== 0 || initial.t.answers.length !== 0) firstFailure('first_not_submitted');
        return { deepSeekComposerHandoffPending: true, url: document.URL,
          sessionLifecycle: 'saved_conversation_delete', temporary: false };
      }
    }
    if (initial.t.first) {
      if (!state.submitted || !state.inserted) firstFailure('first_not_submitted');
      if (initial.t.first.text !== state.inserted.prompt) firstFailure('first_prompt_mismatch');
      if (!c.uuid(input.expectedFirstUserMarker)) firstFailure('first_marker_invalid');
      if (input.expectedFirstUserMarker !== state.inserted.marker) firstFailure('first_marker_mismatch');
      if (!state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)) firstFailure('first_marker_suffix');
      if (route.kind !== 'canonical') return { ...initial.output, ownershipPending: true, text: '', answerComplete: false };
      let fingerprint;
      try { fingerprint = await c.hash(c.bodyText(initial.t.first.text)); }
      catch (error) { tagFirstBodyHashFailure(error, 'binding_digest'); throw error; }
      guard(); if (!sameFirst(initial.t.first)) firstFailure('first_changed_after_hash');
      if (state.firstDisplay && fingerprint !== state.submittedFingerprint) firstFailure('first_pinned_hash_mismatch');
      if (state.modeHandoff && !state.modeHandoff.committed) commitInitialModeHandoff(initial.t.first, fingerprint);
      checkFirstDisplaySelection('body_after_hash');
      if (state.first) {
        const unpublished = input.action === 'inspect' && input.allowFirstUserBinding === true && input.expectedFirstUserFingerprint == null;
        if (!sameFirst(state.first)) firstFailure('first_pinned_node_changed');
        if (state.first.fingerprint !== fingerprint) firstFailure('first_pinned_hash_mismatch');
        if (input.expectedFirstUserFingerprint !== fingerprint && !unpublished) firstFailure('first_expected_hash_mismatch');
      } else {
        if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null)
          firstFailure('first_binding_not_authorized');
        if (state.firstDisplay?.replacement) state.model.trigger = state.firstDisplay.replacement.trigger;
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
    state.submittedFingerprint = outboundFingerprint;
    state.submitted = true; form.send.click();
    return { ...initial.output, submitted: true, submissionAcknowledgement: { ownerToken: input.ownerToken,
      documentGeneration: input.documentGeneration, sequence: 1, outboundFingerprint } };
  } catch (error) {
    if (state && (!error?.computaAdapterFailure || state.deletion || (state.submitted || state.initialReadComplete
      || state.model || state.selection || state.mode || state.modeSelection || state.prepared || state.inserted)
      && ['conversation_changed', 'document_changed', 'model_mismatch', 'model_unverified', 'mode_mismatch', 'mode_unverified'].includes(error.error))) state.terminal = true;
    if (state?.terminal && state.firstDisplay?.settlement) {
      state.firstDisplay.settlement.watch.consume();
      delete state.firstDisplay.settlement;
    }
    return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}),
      ...(error.adapterFailureStructure && (config.stateKey === '__computaQwenSavedSessionV1'
        && error.error === 'conversation_changed' && error.detail === 'first_user_message'
        || config.stateKey === '__computaDeepSeekSavedSessionV1' && error.error === 'unsupported_response_format' && error.detail === 'authored_source')
        ? { adapterFailureStructure: error.adapterFailureStructure } : {}),
      ...(config.selectionKind === 'mode' && error.error === 'conversation_changed' && error.detail === 'first_container_children'
        && error.firstContainerDiagnostic ? { firstContainerDiagnostic: error.firstContainerDiagnostic } : {}),
      ...(config.selectionKind === 'mode' && error.error === 'mode_unverified' && error.modeObservationDiagnostic
        ? { modeObservationDiagnostic: error.modeObservationDiagnostic } : {}),
      ...(config.stateKey === '__computaQwenSavedSessionV1' && error.error === 'model_unverified'
        && error.detail === 'selection_binding' && error.qwenSelectionBinding
        ? { qwenSelectionBinding: error.qwenSelectionBinding } : {}),
      ...(config.stateKey === '__computaQwenSavedSessionV1' && error.error === 'conversation_changed'
        && error.detail === 'first_user_message' && error.qwenFirstUserDiagnostic
        ? { qwenFirstUserDiagnostic: error.qwenFirstUserDiagnostic } : {}),
      ...(config.stateKey === '__computaQwenSavedSessionV1' && error.error === 'conversation_changed'
        && error.detail === 'first_user_message' && error.qwenFirstUserBindingDiagnostic
        ? { qwenFirstUserBindingDiagnostic: error.qwenFirstUserBindingDiagnostic } : {}) }
      : { error: 'document_changed' };
  }
}

// Qwen DOM driver. The saved-conversation engine owns all
// mutation claims, native acknowledgement, exact-body hashing and lifecycle.
// Only insertLiteral mutates, and only after the engine's insertion claim.
function computaQwenDOM(c) {
  const visible = (root, selector, max = 256) => c.nodes(root, selector, max).filter(c.visible);
  const one = (values, reason) => c.unique(values, 'document_changed', reason);
  const optional = (values, reason) => values.length ? one(values, reason) : null;
  const triggerSelector = 'div.wms-trigger[role="button"][aria-label="Select Model"][aria-haspopup="listbox"]';
  const authored = node => !!node.closest('.qwen-chat-message');
  const leaf = (root, selector, reason) => {
    const node = one(visible(root, selector), reason);
    if (node.children.length !== 0) c.fail('document_changed', reason);
    return node;
  };
  const route = (exactURL = true) => {
    if (exactURL) c.assertContext();
    if (document.URL === 'https://chat.qwen.ai/') return { kind: 'fresh', canonical: null, path: '/', conversation: null, id: null };
    if (document.URL === 'https://chat.qwen.ai/c/new-chat') return { kind: 'provisional', canonical: null, path: '/c/new-chat', conversation: null, id: null };
    const match = /^https:\/\/chat\.qwen\.ai\/c\/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/.exec(document.URL);
    if (!match) c.fail('conversation_changed', 'conversation_url');
    return { kind: 'canonical', canonical: document.URL, path: '/c/' + match[1], conversation: document.URL, id: match[1] };
  };
  function initialReady({ control, retain, reject }) {
    if (c.nodes(document, '.qwen-chat-message', 64).length) reject('not_fresh');
    const editor = control('composer', document, 'textarea.message-input-textarea');
    const trigger = control('model_trigger', document, triggerSelector);
    const name = trigger ? control('model_label', trigger, '.wms-trigger__text') : null;
    if (trigger && trigger.getAttribute('aria-expanded') !== 'false') reject('model_unverified', 'initial_picker_not_closed');
    if (trigger && name && (name.children.length !== 0 || !c.normalize(name.textContent))) reject('model_unverified', 'initial_model_label');
    if (visible(document, '[role="listbox"]').length) reject('model_unverified', 'initial_menu_present');
    if (editor) {
      const scope = retain('composer_scope', editor.closest('.message-input-container-area'));
      if (!scope || c.nodes(scope, 'textarea.message-input-textarea').length !== 1
        || typeof editor.value !== 'string') reject('composer_unavailable');
      if (editor.value !== '') reject('composer_not_empty');
      // The observed empty Qwen composer legitimately omits Send. Its absence
      // is not missing readiness, and an unrelated Stop is never a fresh page.
      control('send_control', scope, '.chat-prompt-send-button > button.send-button[aria-label="Send"]');
      if (c.nodes(scope, '.chat-prompt-send-button > button.stop-button[aria-label="Stop"]').length) reject('not_fresh');
    }
    // Mounted controls alone do not prove that discovery can click its
    // retained picker. Keep the existing pre-claim initial wait until the same
    // hit test used immediately before clicking succeeds. DOM-change signals
    // wake this read; native retains its original preparation deadline.
    return !!editor && !!trigger && !!name && c.hit(trigger);
  }
  function rejectSelectionBinding(stage, reason, previousTrigger = null) {
    // The original error/detail remain the public outcome. A disconnected old
    // trigger explains one kind of identity change without accepting a new one.
    try { c.fail('model_unverified', 'selection_binding'); }
    catch (error) {
      try {
        if (reason === 'trigger_replaced' && previousTrigger?.isConnected === false) reason = 'trigger_detached';
        error.qwenSelectionBinding = stage + '/' + reason;
      } catch { /* A diagnostic read cannot replace the rejection. */ }
      throw error;
    }
  }
  function picker(closing = null, selecting = null) {
    const trigger = one(visible(document, triggerSelector)
      .filter(node => !authored(node)), 'model_trigger');
    const name = leaf(trigger, '.wms-trigger__text', 'model_label');
    const menus = visible(document, '[role="listbox"]').filter(node => !authored(node));
    const menu = optional(menus, 'model_menu');
    if (!['true', 'false'].includes(trigger.getAttribute('aria-expanded'))) c.fail('model_unverified', 'picker_expanded_invalid');
    if (menu && (!menu.classList.contains('wms-list') || menu.getAttribute('aria-label') !== 'Models')) c.fail('model_unverified', 'picker_menu_shape');
    const label = c.normalize(name.textContent), expanded = trigger.getAttribute('aria-expanded');
    if (closing) {
      if (closing.trigger !== trigger) rejectSelectionBinding('closing', 'trigger_replaced', closing.trigger);
      if (!closing.menu) rejectSelectionBinding('closing', 'previous_menu_missing');
      if (!closing.checked) rejectSelectionBinding('closing', 'previous_checked_missing');
      if (!c.choiceValid(closing.choice)) rejectSelectionBinding('closing', 'choice_invalid');
      if (label !== closing.choice.label) rejectSelectionBinding('closing', 'label_changed');
      if (menu) {
        if (menu !== closing.menu) c.fail('model_unverified', 'picker_menu_replaced');
        const rows = rowsInMenu(menu, label), checked = rows.find(row => row.selected);
        if (checked.node !== closing.checked) rejectSelectionBinding('closing', 'checked_node_changed');
        if (!c.equalChoice(checked.choice, closing.choice)) rejectSelectionBinding('closing', 'checked_choice_changed');
        if (rows.length !== closing.choices.length) rejectSelectionBinding('closing', 'row_count_changed');
        if (rows.some((row, index) => !c.equalChoice(row.choice, closing.choices[index])))
          rejectSelectionBinding('closing', 'row_choices_changed');
      }
    }
    if (selecting) {
      const option = selecting.option;
      if (selecting.trigger !== trigger) rejectSelectionBinding('selecting', 'trigger_replaced', selecting.trigger);
      if (!selecting.menu) rejectSelectionBinding('selecting', 'previous_menu_missing');
      if (!option?.node) rejectSelectionBinding('selecting', 'option_missing');
      if (!option.previous?.node) rejectSelectionBinding('selecting', 'previous_option_missing');
      if (!c.choiceValid(selecting.target)) rejectSelectionBinding('selecting', 'target_invalid');
      if (!c.choiceValid(option.previous.choice)) rejectSelectionBinding('selecting', 'previous_choice_invalid');
      if (label !== selecting.target.label && label !== option.previous.choice.label)
        rejectSelectionBinding('selecting', 'label_changed');
      if (menu) {
        if (menu !== selecting.menu) c.fail('model_unverified', 'picker_menu_replaced');
        // Label and checked-row acknowledgement may settle independently, but
        // both are restricted to the prior selection or this exact clicked target.
        const rows = rowsInMenu(menu, null), checked = rows.find(row => row.selected);
        const target = rows.find(row => c.equalChoice(row.choice, selecting.target));
        const checkedNode = c.equalChoice(checked.choice, selecting.target) ? option.node
          : c.equalChoice(checked.choice, option.previous.choice) ? option.previous.node : null;
        if (target?.node !== option.node) rejectSelectionBinding('selecting', 'target_node_changed');
        if (checked.node !== checkedNode) rejectSelectionBinding('selecting', 'checked_node_changed');
        if (rows.length !== option.choices.length) rejectSelectionBinding('selecting', 'row_count_changed');
        if (rows.some((row, index) => !c.equalChoice(row.choice, option.choices[index])))
          rejectSelectionBinding('selecting', 'row_choices_changed');
      }
    }
    // A claimed close may settle ARIA and physical visibility separately. The
    // retained menu/checked row remains unverified until BOTH channels close.
    // No other phase gains permission to accept an inconsistent picker state.
    if (menu && expanded !== 'true' && !closing && !selecting) c.fail('model_unverified', 'picker_menu_collapsed');
    if (!menu && expanded !== 'false' && !closing && !selecting) c.fail('model_unverified', 'picker_menu_missing');
    return { trigger, name, menu, label, closed: menu === null && expanded === 'false' };
  }
  function firstDisplayReplacement(original, held, choice, stage) {
    const current = picker();
    if (!current.closed) rejectSelectionBinding(stage, 'picker_open');
    if (current.label !== choice.label || current.name.textContent !== choice.label)
      rejectSelectionBinding(stage, 'label_changed');
    if (original.isConnected !== false || current.trigger === original || !c.enabled(current.trigger)
      || c.nodes(document, triggerSelector).filter(node => !authored(node)).length !== 1
      || held && (current.trigger !== held.trigger || current.name !== held.name))
      rejectSelectionBinding(stage, 'trigger_replaced', original);
    return held || { trigger: current.trigger, name: current.name };
  }
  function modelRows(menu) {
    const p = picker();
    if (p.menu !== menu) c.fail('model_unverified', 'picker_menu_binding');
    return rowsInMenu(menu, p.label);
  }
  function rowsInMenu(menu, selectedLabel) {
    const rows = visible(menu, '.wms-list__item[role="option"]', 32).map(node => {
      const label = c.normalize(leaf(node, '.wms-list__name-text', 'model_label').textContent);
      // No DOM model identifier was observed. Keep the exact label as an opaque
      // website key, separate from Alibaba's API IDs and catalog.
      const choice = { key: label, label }, selected = node.getAttribute('aria-selected');
      if (!c.choiceValid(choice)) c.fail('model_unverified', 'model_choice_invalid');
      if (!c.enabled(node)) c.fail('model_unverified', 'model_option_disabled');
      if (!['true', 'false'].includes(selected)) c.fail('model_unverified', 'model_selected_invalid');
      if (node.classList.contains('wms-list__item--selected') !== (selected === 'true')) c.fail('model_unverified', 'model_selected_contradiction');
      return { node, choice, selected: selected === 'true' };
    });
    if (!rows.length) c.fail('model_unverified', 'model_choices_empty');
    if (new Set(rows.map(row => row.choice.key)).size !== rows.length) c.fail('model_unverified', 'model_choices_duplicate');
    if (rows.filter(row => row.selected).length !== 1) c.fail('model_unverified', 'model_checked_count');
    if (selectedLabel !== null && rows.find(row => row.selected).choice.label !== selectedLabel) c.fail('model_unverified', 'picker_selected_label');
    return rows;
  }
  function composer() {
    const editor = one(visible(document, 'textarea.message-input-textarea').filter(node => !authored(node)), 'composer');
    const scope = editor.closest('.message-input-container-area');
    if (!scope || !c.visible(scope) || c.nodes(scope, 'textarea.message-input-textarea').length !== 1
      || typeof editor.value !== 'string' || new TextEncoder().encode(editor.value).length > 180_200) c.fail('composer_unavailable');
    const send = optional(visible(scope, '.chat-prompt-send-button > button.send-button[aria-label="Send"]'), 'send_control');
    const stop = optional(visible(scope, '.chat-prompt-send-button > button.stop-button[aria-label="Stop"]'), 'stop_control');
    if (send && stop) c.fail('composer_unavailable');
    if (stop && stop.getAttribute('data-chat-id') !== route().id) c.fail('conversation_changed', 'stop_conversation');
    return { editor, scope, text: editor.value, empty: editor.value === '', send, stop,
      sendReady: !!send && c.enabled(editor) && c.hit(send), streaming: !!stop };
  }
  function rejectFirstUser(root, container, turn, id, conversationID) {
    // Failure-only predicates from the already selected nodes. No raw ID,
    // URL, body, extra selector or action is retained. Diagnostic failure must
    // not replace the original ownership rejection or authorize recovery.
    let diagnostic;
    try {
      const chatID = container.getAttribute('data-chat-id');
      const flags = { rootVisible: c.visible(root), messageIDValid: c.uuid(id),
        chatIDMatches: chatID === conversationID,
        turnClassMatches: turn?.classList.contains('qwen-chat-message-select-turn-message') === true,
        outerClassMatches: turn?.parentElement?.classList.contains('qwen-chat-message-select-turn') === true,
        messageIDPresent: id !== null, messageIDEmpty: id === '',
        chatIDPresent: chatID !== null, chatIDEmpty: chatID === '' };
      const reason = !flags.rootVisible ? 'root_hidden' : !flags.messageIDValid ? 'message_id_invalid'
        : !flags.chatIDMatches ? 'chat_id_mismatch' : !flags.turnClassMatches ? 'turn_class_missing'
        : !flags.outerClassMatches ? 'outer_class_missing' : null;
      if (reason) diagnostic = { version: 1, reason, ...flags };
    } catch { /* Keep the original error when diagnostic reads are unavailable. */ }
    try { c.fail('conversation_changed', 'first_user_message'); }
    catch (error) {
      if (diagnostic && error?.computaAdapterFailure) error.qwenFirstUserDiagnostic = diagnostic;
      throw error;
    }
  }
  function transcript(allowInitialResponseIdentity = false) {
    const users = c.nodes(document, '.qwen-chat-message.qwen-chat-message-user', 2);
    const answers = c.nodes(document, '.qwen-chat-message.qwen-chat-message-assistant', 2);
    if (users.length > 1 || answers.length > 1 || answers.length > users.length) c.fail('conversation_changed', 'user_count');
    if (!users.length) return { users, answers, first: null, answer: null };
    const current = route();
    if (!current.id) c.fail('conversation_changed', 'conversation_url');
    const root = users[0], turn = root.parentElement, container = one(visible(root, '.chat-user-message-container'), 'first_user_container');
    const body = leaf(container, '.chunked-text-renderer-root > p.user-message-content', 'first_user_message');
    const id = container.getAttribute('data-msg-id');
    if (!c.visible(root) || !c.uuid(id) || container.getAttribute('data-chat-id') !== current.id
      || !turn?.classList.contains('qwen-chat-message-select-turn-message')
      || !turn.parentElement?.classList.contains('qwen-chat-message-select-turn')) rejectFirstUser(root, container, turn, id, current.id);
    let answer = null, pendingAnswer = null;
    if (answers.length) {
      const node = answers[0], answerTurn = node.parentElement;
      const content = one(visible(node, '.chat-response-message'), 'response_container');
      const answerID = content.getAttribute('id')?.replace(/^chat-response-message-/, '');
      if (!c.visible(node) || (!c.uuid(answerID) && !(allowInitialResponseIdentity && answerID === ''))
        || content.getAttribute('id') !== 'chat-response-message-' + answerID
        || answerID === id || !answerTurn?.classList.contains('qwen-chat-message-select-turn-message')
        || answerTurn.parentElement !== turn.parentElement
        || [...turn.parentElement.children].indexOf(answerTurn) <= [...turn.parentElement.children].indexOf(turn))
        c.fail('conversation_changed', 'response_scope');
      if (answerID === '') {
        // The observed first response mounts this exact prefix before its UUID.
        // This is an internal negative candidate, never an answer. Default
        // transcript reads, completion and cleanup retain strict UUID checks.
        const form = composer();
        if (!form.empty || !c.enabled(form.editor) || !form.stop
          || c.nodes(content, '.response-loading', 2).length !== 1
          || c.nodes(content, '.response-message-content.phase-answer', 1).length
          || c.nodes(content, '.response-message-footer-actions', 1).length)
          c.fail('conversation_changed', 'response_scope');
        pendingAnswer = { root: node, content, turn: answerTurn, outer: turn.parentElement };
      } else answer = { root: node, content, id: answerID };

    }
    return { users, answers, first: { root, container, body, id, text: body.textContent }, answer, pendingAnswer };
  }
  // One rendering opportunity after a scroll. Callbacks only invalidate or
  // wake native inspection; they can never operate the button themselves.
  function watchDisplayRender(pins, protectedText, editor, blockers, wake) {
    if (!window.requestAnimationFrame || !window.cancelAnimationFrame || !window.setTimeout || !window.clearTimeout
      || !window.performance?.now || !window.addEventListener || !editor.addEventListener) return null;
    const deadline = window.performance.now() + 300;
    let status = 'waiting', frame = 0, timer = 0;
    const events = [[editor,'input'], [editor,'change'], [window,'pagehide'], [window,'popstate'], [window,'hashchange']];
    if (window.navigation?.addEventListener) events.push([window.navigation,'currententrychange']);
    const disconnect = () => {
      window.cancelAnimationFrame(frame); window.clearTimeout(timer); observer.disconnect();
      events.forEach(([node, key]) => node.removeEventListener(key, invalidate, true));
    };
    const stop = reason => {
      if (status !== 'waiting' && status !== 'ready') return;
      status = reason; disconnect(); wake();
    };
    const invalidate = () => stop('render_binding_changed');
    const ready = () => {
      if (status === 'waiting' && window.performance.now() < deadline) { status = 'ready'; wake(); }
    };
    const checkChanges = records => {
      // Replacing and restoring even an equal-looking pinned node, message or
      // picker label between reads must not give the pending action authority.
      if (records.length > 128 || records.some(r =>
        protectedText.some(n => n === r.target || n.contains(r.target))
        || r.type === 'attributes' && pins.includes(r.target)
        || r.type === 'childList' && (r.removedNodes.length > 64
          || Array.from(r.removedNodes).some(n => pins.some(p => n === p || n.contains?.(p)))))) { invalidate(); return; }
      // Hidden WebKit views can suspend animation frames. Removing an actual
      // intercepting element is another layout change worth a fresh native read.
      if (records.some(r => r.type === 'childList' && Array.from(r.removedNodes).some(n =>
        blockers.some(b => n === b || n.contains?.(b))))) ready();
    };
    const observer = new MutationObserver(checkChanges);
    const current = () => {
      if (status === 'waiting' || status === 'ready') {
        checkChanges(observer.takeRecords());
        if (window.performance.now() >= deadline) stop('render_deadline');
      }
      return status;
    };
    try {
      observer.observe(document.documentElement, {subtree:true,childList:true,characterData:true,attributes:true,
        attributeFilter:['id','data-msg-id','data-chat-id','class','role','disabled','hidden','inert','aria-hidden',
          'aria-disabled','aria-label','aria-expanded','aria-selected','aria-haspopup','contenteditable']});
      events.forEach(([node,key]) => node.addEventListener(key, invalidate, true));
      timer = window.setTimeout(() => stop('render_deadline'), 300);
      frame = window.requestAnimationFrame(() => {
        if (current() !== 'waiting') return;
        frame = window.requestAnimationFrame(() => {
          if (current() === 'waiting') ready();
        });
      });
    } catch { disconnect(); return null; }
    return { current, consume() { disconnect(); status = 'consumed'; } };
  }

  // A clipped display button can have a covered center and an exposed edge.
  // Find one actual pointer target, then require the same viewport point on the
  // same pinned button after the caller revalidates the transcript and choice.
  function displayHitFailure(control, point, classifyOcclusion = false, blockers = null) {
    let blocker = null;
    const reason = c.hitFailure(control, (left, top, right, bottom) => {
      const ownsPoint = (x, y) => {
        const hit = document.elementFromPoint(x, y);
        if (hit === control) return true;
        const inside = control.contains(hit);
        if (inside && hit.closest('button, a, input, select, textarea, [role], [tabindex], [contenteditable]') === control) return true;
        if (classifyOcclusion) {
          const kind = !hit ? 'none' : inside ? 'descendant' : hit.contains(control) ? 'ancestor' : 'unrelated';
          if (kind === 'unrelated' && blockers && !blockers.includes(hit)) blockers.push(hit);
          blocker = !blocker || blocker === kind ? kind : 'mixed';
        }
        return false;
      };
      if (point.x !== undefined) {
        return left < point.x && point.x < right && top < point.y && point.y < bottom && ownsPoint(point.x, point.y);
      }
      for (const [u, v] of [[.5,.5], [.125,.5], [.875,.5], [.5,.125], [.5,.875],
        [.125,.125], [.875,.125], [.125,.875], [.875,.875]]) {
        const x = left + (right - left) * u, y = top + (bottom - top) * v;
        if (ownsPoint(x, y)) { point.x = x; point.y = y; return true; }
      }
      return false;
    });
    return reason === 'occluded' && blocker ? 'occluded_' + blocker : reason;
  }
  // The long user message has a display-only toggle inside this exact chunk.
  // A missing/ambiguous shape is never an invitation to click another button.
  function firstBodyPresentation(transcript) {
    const { first, pendingAnswer, answer } = transcript;
    const response = pendingAnswer || answer;
    if (!first || !response || transcript.users.length !== 1 || transcript.answers.length !== 1
      || visible(document, '[role="dialog"], [aria-modal="true"]', 32).length) return null;
    const { body, container, root } = first;
    const chunk = body.parentElement;
    if (!chunk?.classList.contains('chunked-text-renderer-root-with-expand') || chunk.children.length !== 2
      || chunk.children[0] !== body || !container.contains(chunk) || !c.visible(chunk)) return null;
    const control = chunk.children[1];
    const collapsed = chunk.classList.contains('is-collapsed');
    if (control.tagName !== 'BUTTON' || !control.classList.contains('chat-user-message-expand-toggle')
      || !control.classList.contains('chat-user-message-expand-toggle-pc')
      || control.getAttribute('aria-label') !== (collapsed ? 'Expand' : 'Collapse')
      || !c.enabled(control) || control.closest('form, a, [contenteditable="true"]')
      || control.querySelector('a, button, input, select, textarea, [contenteditable="true"]')
      || ['form', 'formaction', 'popovertarget', 'commandfor', 'aria-controls', 'aria-expanded'].some(name => control.getAttribute(name) !== null)
      || ![null, 'button'].includes(control.getAttribute('type'))) return null;
    const pins = [body, control];
    for (let node = chunk; node !== root; node = node.parentElement) {
      if (!node || pins.length > 16) return null;
      pins.push(node);
    }
    pins.push(root, root.parentElement, root.parentElement.parentElement, response.root, response.root.parentElement, response.content);
    return { pins, control, collapsed, userID: first.id, answerID: answer?.id || null };
  }
  function firstBodyFailureStructure(first, expected) {
    const comparison = computaSavedFirstBodyComparison(first?.text, expected);
    if (!comparison || !first?.container) return null;
    const categories = [['chat-user-message-container', 'user_container'], ['chunked-text-renderer-root', 'chunk_root'], ['user-message-content', 'user_paragraph']];
    const captured = computaSavedFailureTree(first.container, c, categories);
    let direct = 0, visibleDirect = 0, descendant = 0, visibleDescendant = 0;
    const paragraphs = [];
    for (const node of captured.nodes) {
      if (node === first.container || node.tagName !== 'P' || !node.classList.contains('user-message-content')) continue;
      const isDirect = node.parentElement?.classList.contains('chunked-text-renderer-root') === true, isVisible = c.visible(node);
      descendant++; if (isVisible) visibleDescendant++; if (isDirect) direct++; if (isDirect && isVisible) visibleDirect++;
      if (paragraphs.length < 16) {
        const ancestry = []; let parent = node.parentElement, reached = false;
        while (parent && ancestry.length < 4) {
          ancestry.push(captured.category(parent)); if (parent === first.container) { reached = true; break; }
          parent = parent.parentElement;
        }
        paragraphs.push({ direct: isDirect, visible: isVisible, ancestry, ancestryTruncated: !reached });
      }
    }
    return { version: 1, provider: 'qwen', trigger: 'full_prompt_mismatch',
      nodeLimitReached: captured.nodeLimitReached, nodeCount: captured.tree.length, tree: captured.tree, comparison,
      directParagraphCount: Math.min(direct, 33), visibleDirectParagraphCount: Math.min(visibleDirect, 33),
      descendantParagraphCount: Math.min(descendant, 33), visibleDescendantParagraphCount: Math.min(visibleDescendant, 33),
      paragraphCountOverflow: descendant > 33 || direct > 33, paragraphs };
  }

  function completionCandidate(answer) {
    if (!answer) return false;
    const current = route(), form = composer();
    const rails = visible(answer.content, '.response-message-footer-actions > .qwen-chat-package-comp-new-action-control');
    if (rails.length !== 1) return false;
    const rail = rails[0];
    if (rail.getAttribute('data-chat-id') !== current.id || rail.getAttribute('data-msg-id') !== answer.id)
      c.fail('conversation_changed', 'response_actions');
    const actions = ['Copy', 'Good Response', 'Bad Response', 'Share', 'Regenerate'];
    return !form.stop && c.enabled(form.editor) && form.empty && actions.every(label => {
      const controls = visible(rail, `button[aria-label="${label}"]`);
      return controls.length === 1 && c.enabled(controls[0]);
    });
  }
  function rawAnswer(answer) {
    if (!answer) return { text: '', finalMarkup: false, formatIssue: false };
    const flows = c.nodes(answer.content, '.chat-response-message-render-flow');
    if (!flows.length) return { text: '', finalMarkup: false, formatIssue: false };
    const unsupported = () => ({ text: '', finalMarkup: false, formatIssue: true });
    if (flows.length !== 1 || !c.visible(flows[0])) return unsupported();
    const flow = flows[0], phases = c.nodes(flow, '.response-message-content.phase-answer');
    if (!phases.length) return { text: '', finalMarkup: false, formatIssue: false };
    if (phases.length !== 1 || !phases[0].classList.contains('t2t')) return unsupported();
    const phase = phases[0];
    const child = (parent, tag, cls) => {
      if (!c.visible(parent) || parent.children.length !== 1
        || [...parent.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || ''))) return null;
      const node = parent.children[0];
      return node.tagName === tag && node.classList.contains(cls) && c.visible(node) ? node : null;
    };
    const custom = child(phase, 'DIV', 'custom-qwen-markdown');
    const markdown = custom && child(custom, 'DIV', 'qwen-markdown');
    const paragraph = markdown && child(markdown, 'DIV', 'qwen-markdown-paragraph');
    const span = paragraph && child(paragraph, 'SPAN', 'qwen-markdown-text');
    const literal = span && child(span, 'SPAN', 'qwen-markdown-text-node');
    if (!literal || literal.children.length !== 0) return unsupported();
    let budget = 10_000;
    const onlyAuthoredSource = node => {
      if (--budget < 0) return false;
      if (node === phase) return true;
      if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
      if (node.nodeType !== 1 || node.tagName !== 'DIV') return false;
      // The observed thinking-status presentation is a sibling of the answer,
      // never an authored markdown descendant. No reasoning content is read.
      if (node.parentElement === flow && node.classList.contains('qwen-chat-thinking-tool-status-card-wraper')) return true;
      return [...node.childNodes].every(onlyAuthoredSource);
    };
    if (!onlyAuthoredSource(flow)) return unsupported();
    const text = literal.textContent;
    if (typeof text !== 'string' || new TextEncoder().encode(text).length > 220_000) c.fail('response_too_large');
    // Return the whole source even when it is invalid JSON. Monaco/fences,
    // additional prose blocks and multiple fragments never become a repaired
    // protocol object; the ordinary codec independently validates raw bytes.
    return { text, finalMarkup: true, formatIssue: false };
  }
  function deletionTrigger() {
    if (!route().id) c.fail('conversation_changed', 'delete_route');
    const trigger = one(visible(document, '.chat-menu-trigger > button[aria-label="More"]').filter(node => !authored(node)), 'delete_trigger');
    return trigger;
  }
  function deletionMenu() {
    const menus = visible(document, 'div[role="menu"]').filter(node => !authored(node));
    const menu = optional(menus, 'delete_menu');
    if (!menu) return null;
    if (!menu.classList.contains('qwen-chat-v2-dropdown-menu-popup')) c.fail('conversation_changed', 'delete_menu');
    const rows = visible(menu, '[role="menuitem"]').filter(row => {
      const labels = visible(row, '.qwen-chat-v2-dropdown-menu-item-label');
      return labels.length === 1 && labels[0].children.length === 0 && labels[0].textContent === 'Delete';
    });
    const target = one(rows, 'delete_control');
    if (!target.classList.contains('qwen-chat-v2-dropdown-menu-item-danger')
      || !target.classList.contains('chat-menu-item-error') || !target.classList.contains('chat-menu-item'))
      c.fail('conversation_changed', 'delete_control');
    return { menu, target: c.hit(target) ? target : null };
  }
  function deletionConfirmation() {
    const current = route();
    if (!current.id) c.fail('conversation_changed', 'delete_route');
    const dialog = optional(visible(document, '[role="dialog"]').filter(node => !authored(node)), 'delete_dialog');
    if (!dialog) return null;
    const title = leaf(dialog, '.ant-modal-title', 'delete_title');
    const body = leaf(dialog, '.ant-modal-body > [data-aes-exp="expChatDeleteMiddle"]', 'delete_body');
    const buttons = visible(dialog, '.qwen-chat-v2-modal-footer-btns > button');
    const confirm = one(buttons.filter(node => c.normalize(node.textContent) === 'Delete'), 'delete_confirm');
    const cancel = one(buttons.filter(node => c.normalize(node.textContent) === 'Cancel'), 'delete_cancel');
    if (!dialog.classList.contains('chat-item-delete-confirm') || dialog.getAttribute('aria-modal') !== 'true'
      || !title.getAttribute('id') || dialog.getAttribute('aria-labelledby') !== title.getAttribute('id')
      || title.textContent !== 'Delete this chat?' || body.getAttribute('data-chat-id') !== current.id
      || body.textContent !== 'Once deleted, this chat cannot be recovered, and the files in it will be permanently removed. If you have shared this conversation, the share link will no longer be accessible.'
      || buttons.length !== 2 || !confirm.classList.contains('qwen-chat-v2-btn-danger')
      || !cancel.classList.contains('qwen-chat-v2-btn-plain')) c.fail('conversation_changed', 'delete_confirmation');
    return { dialog, target: c.hit(confirm) ? confirm : null };
  }
  function deletionObserved(record) {
    if (route().kind !== 'fresh') return false;
    // A fresh-page skeleton is pending; only an actual empty usable composer
    // plus disappearance of this operation's roots can establish local cleanup.
    if (!visible(document, 'textarea.message-input-textarea').length) return false;
    const form = composer();
    const ownID = record.conversationURL.split('/').at(-1);
    const links = c.nodes(document, 'a[href]', 512).filter(node => {
      try { return new URL(node.getAttribute('href'), document.URL).href.split(/[?#]/)[0] === record.conversationURL; }
      catch { return false; }
    });
    return form.empty && c.enabled(form.editor) && !form.stop
      && c.nodes(document, '.qwen-chat-message').length === 0
      && c.nodes(document, '[role="dialog"]').length === 0
      && c.nodes(document, '[data-chat-id]').every(node => node.getAttribute('data-chat-id') !== ownID)
      && record.roots.every(node => !node.isConnected) && !!record.dialog && !record.dialog.isConnected && links.length === 0;
  }
  function insertLiteral(form, prompt) {
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (!(form.editor instanceof HTMLTextAreaElement) || typeof setter !== 'function') c.fail('composer_unavailable');
    setter.call(form.editor, prompt);
    form.editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
  }
  return { rejectSelectionBinding, firstDisplayReplacement, watchDisplayRender, displayHitFailure, firstBodyPresentation, firstBodyFailureStructure, initialResponseIdentityTranscript: () => transcript(true), route, authored, initialReady, picker, modelRows, composer, transcript, completionCandidate, rawAnswer,
    deletionTrigger, deletionMenu, deletionConfirmation, deletionObserved, insertLiteral };
}

// Standalone composition; native catalog admission is separate from this adapter.
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'prepare', 'insert', 'sendReady', 'submit', 'stop',
    'deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'qwen', 'https://chat.qwen.ai', actions);
  return await computaSavedConversation(input, c, computaQwenDOM(c), {
    stateKey: '__computaQwenSavedSessionV1', origin: 'https://chat.qwen.ai', initialProvisionalRoute: true, initialResponseIdentity: true
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}
