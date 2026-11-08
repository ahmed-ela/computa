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
    // Negative-only fence for the single final Copy. Native stamps the existing
    // evaluation deadline; neither this local clock nor the grant renews it.
    let sampleDeadline = null;
    if (input.qwenCodePayloadSample != null || input.savedResponseChoiceGrant != null) {
      const now = Date.now(), end = input.evaluationDeadlineEpochMilliseconds;
      if (!Number.isSafeInteger(end) || end <= now || end - now > 30000)
        c.fail('unsupported_response_format', 'copy_deadline');
      sampleDeadline = { epoch: end, monotonic: performance.now() + end - now };
    }
    const sampleCurrent = () => {
      if (!sampleDeadline || Date.now() >= sampleDeadline.epoch || performance.now() >= sampleDeadline.monotonic)
        c.fail('unsupported_response_format', 'copy_deadline');
    };
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
    if ((state.firstDisplay || state.firstDisplayWitness) && !state.first && (input.action !== 'inspect' || cleanupInspection
      || !state.firstDisplay?.complete && input.allowQwenFirstBodyExpansion !== true || input.allowQwenInitialResponseIdentity !== true))
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
          if (stage === 'display_reveal_hit' && diagnostic.reason === 'occluded_unrelated' && typeof structure === 'function') {
            try { const cover = structure(); if (cover) error.qwenDisplayCover = cover; } catch { /* Keep the original rejection. */ }
          }
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
      if (state.responseChoice?.acknowledged && (!t.answer || t.answer.id !== state.responseChoice.ids[0]
        || c.nodes(t.answer.root, '.chat-response-message', 2).length !== 1
        || c.nodes(t.answer.root, '.smrm, .cmrm', 1).length))
        c.fail('conversation_changed', 'response_choice_selected');
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
        || answer.root !== held.answer.root || held.answer.content !== null && answer.content !== held.answer.content
        || answer.root.parentElement !== held.answer.turn || held.answer.turn.parentElement !== held.outer)
        c.fail('conversation_changed', 'response_scope');
      if (held.fromEmptyContainer) {
        if (!state.first) {
          const form = dom.composer();
          if (!form.empty || !c.enabled(form.editor) || form.editor !== held.answer.editor
            || form.scope !== held.answer.composerScope) c.fail('conversation_changed', 'response_scope');
        }
        if (answer.content && c.nodes(answer.root, '.chat-response-message', 2).length !== 1
          || held.answerID !== undefined && held.answerID !== t.answer?.id) c.fail('conversation_changed', 'response_scope');
        // The first observed physical container and then its first valid UUID
        // become permanent pins. Disappearance or substitution is terminal.
        if (answer.content) held.answer.content = answer.content;
        if (t.answer) held.answerID = t.answer.id;
      }
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
      requireDisplayPins(held, view, reject);
    }
    function requireDisplayPins(held, view, reject) {
      if (held.pins.length !== view.pins.length) reject('pin_count_changed');
      const i = held.pins.findIndex((node, i) => node !== view.pins[i]);
      if (i >= 0) reject(i === 0 ? 'body_changed' : i === 1 ? 'control_changed'
        : i < held.pins.length - 3 ? 'user_ancestry_changed' : 'answer_ancestry_changed');
    }
    // Only the native-granted long Qwen display may pin a detached picker's
    // replacement. This observation publishes no evidence. Normal selection
    // reads continue to use the original handle until first-body ownership binds.
    function checkFirstDisplaySelection(stage, allowReplacement = false, claim = state.firstDisplay) {
      if (state.first || !claim || !claim.replacement && (!allowReplacement || state.model.trigger.isConnected !== false)) {
        selectionEvidence(true, stage);
        return;
      }
      claim.replacement = dom.firstDisplayReplacement(state.model.trigger, claim.replacement, state.model.choice, stage);
    }
    // An empty body can only wait. A complete exact observed preview can spend
    // one local display claim. Neither path exposes model output or grants ownership.
    function observeFirstDisplay(t, transcriptReader = () => dom.initialResponseIdentityTranscript()) {
      const prompt = state.inserted.prompt;
      const previewLength = 10_240;
      const held = state.firstDisplay, optimistic = state.firstDisplayWitness;
      // The completed presentation was revalidated above. An ID-only receipt can
      // continue without a new display grant and can never spend another click.
      if (held?.complete) return false;
      if (!held && !optimistic && (state.responseIdentity || !t.first || t.first.text === prompt || prompt.length <= previewLength)) return false;
      if (input.allowQwenFirstBodyExpansion !== true) {
        if (held || optimistic) firstBindingFailure('display_scope', 'display_grant_missing');
        return false;
      }
      const view = dom.firstBodyPresentation(t);
      if (!view && !held && !optimistic) return false; // Ordinary full-body mismatch follows.
      const reject = reason => firstBindingFailure('display_observation', reason);
      if (held) requireSameFirstDisplay(view, 'display_held');
      if (optimistic) {
        const refuse = reason => firstBindingFailure('display_held', reason);
        if (!view) refuse('presentation_missing');
        if (optimistic.canonical !== route.canonical) refuse('route_changed');
        requireDisplayPins(optimistic, view, refuse);
      }
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
      // On these Qwen choices, the user UUID beside an empty answer ID may belong
      // only to the optimistic rendering. Keep the original physical turn, but
      // acquire neither message identity nor expansion authority in that phase.
      const witnessControls = optimistic || held?.settledPair;
      if (witnessControls && (form.editor !== witnessControls.editor || form.scope !== witnessControls.scope
        || state.inserted !== witnessControls.inserted || state.send !== witnessControls.send || state.model !== witnessControls.model))
        reject('composer_not_ready');
      if (!held && (optimistic || t.pendingAnswer && config.deferDisplayUntilAnswer?.some(choice => c.equalChoice(state.model.choice, choice)))) {
        const witness = optimistic || (state.firstDisplayWitness = { pins:view.pins, canonical:route.canonical,
          editor:form.editor, scope:form.scope, inserted:state.inserted, send:state.send, model:state.model });
        if (witness.sawPreview && !preview) reject('preview_prefix_mismatch');
        if (preview) witness.sawPreview = true;
        checkFirstDisplaySelection('display_before_click', !optimistic, witness);
        if (t.pendingAnswer) return true;
        // First genuine pair. Spend a separate, unchanged native-granted read
        // after pinning it. No action or response is released by this receipt.
        state.firstDisplay = { ...view, canonical:route.canonical, settledPair:witness, replacement:witness.replacement,
          clicked:false, sawExpanded:false, complete:false };
        delete state.firstDisplayWitness;
        try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ownerToken:input.ownerToken,kind:'dom_changed'}); }
        catch { /* The existing native deadline remains authoritative. */ }
        return true;
      }
      const claim = held || (state.firstDisplay = { ...view, canonical: route.canonical, clicked: false, sawExpanded: false, complete: false });
      checkFirstDisplaySelection(claim.clicked ? 'display_after_click' : 'display_before_click', !claim.settledPair && !settlement && !claim.clicked && view.collapsed);
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
        const current = transcriptReader(), currentView = dom.firstBodyPresentation(current);
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
      const cover = () => {
        const info = point.describeCover?.(form.scope, t.first.root, (t.pendingAnswer || t.answer).root);
        return info && {...info, phase:settlement ? 'settled' : 'revealed'};
      };
      if (settlement) {
        checkedControl();
        const status = settlement.watch.current();
        if (status === 'waiting') return true;
        if (status !== 'ready') renderFailure(status);
      }
      let hit = dom.displayHitFailure(view.control, point, !!settlement);
      if (settlement && hit !== null) firstBindingFailure('display_reveal_hit', hit, cover);
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
        if (hit !== null) firstBindingFailure('display_reveal_hit', hit, cover);
      } else if (hit !== null) firstBindingFailure('display_hit', hit);
      const currentHit = dom.displayHitFailure(checkedControl(), point, claim.scrolled === true);
      if (currentHit !== null) firstBindingFailure(claim.scrolled ? 'display_reveal_hit' : 'display_preclick_hit', currentHit, cover);
      if (settlement) {
        const status = settlement.watch.current();
        if (status !== 'ready') renderFailure(status);
        settlement.watch.consume(); delete claim.settlement;
      }
      claim.clicked = true;
      view.control.click();
      return true;
    }
    function responseChoiceMetadata(phase) {
      const held = state.responseChoice;
      return { version:1, kind:'qwen_smrm', policy:'first_observed_card_v1', state:phase,
        candidate:held.candidate, responseIDs:held.ids, selectedResponseID:held.ids[0],
        firstUserFingerprint:held.fingerprint, ...(held.grant ? {grant:held.grant} : {}) };
    }
    const qwenCodeEnabled = key === '__computaQwenSavedSessionV1'
      && ['Qwen3.7-Plus','Qwen3.8-Max'].some(label => c.equalChoice(input.expectedModelChoice,{key:label,label}));
    const sameCodeAnswer = (held, answer) => !!held && !!answer && held.root === answer.root
      && held.content === answer.content && held.responseID === answer.id && held.root.isConnected && held.content.isConnected;
    const sameCode = (held, current) => !!held && !!current && held.root === current.root
      && held.content === current.content && held.responseID === current.responseID && held.control === current.control
      && held.nodes.length === current.nodes.length && held.nodes.every((node,index) => node === current.nodes[index] && node.isConnected);
    function read() {
      const t = dom.transcript(), form = dom.composer(), evidence = selectionEvidence(false);
      validateInitialResponseIdentity(t, 'ordinary_read');
      const extracted = dom.rawAnswer(t.answer);
      state.initialReadComplete = true;
      const terminalUI = !!state.first && !!evidence && !state.deletion && dom.completionCandidate(t.answer);
      if (terminalUI && extracted.formatIssue && !cleanupInspection && !deletionActions.includes(input.action)) {
        try { c.fail('unsupported_response_format', 'authored_source'); }
        catch (error) {
          if (input.action === 'inspect' && error?.computaAdapterFailure && typeof extracted.failureStructure === 'function') {
            try {
              const qwenChoice = config.stateKey === '__computaQwenSavedSessionV1'
                && c.equalChoice(evidence.selected, input.expectedModelChoice)
                && ['Qwen3.7-Plus', 'Qwen3.8-Max'].some(label => c.equalChoice(evidence.selected, { key: label, label }));
              if (qwenChoice || config.stateKey === '__computaDeepSeekSavedSessionV1')
                error.adapterFailureStructure = extracted.failureStructure();
            } catch { /* Preserve the original refusal. */ }
          }
          throw error;
        }
      }
      let codeMetadata = null;
      if (qwenCodeEnabled && !cleanupInspection && !state.deletion && !deletionActions.includes(input.action) && extracted.codePayload && terminalUI) {
        if (!input.qwenCodePayloadChannel) dom.codePayloadFailure('channel_missing');
        const current = extracted.codePayload;
        if (state.codePayload && !sameCodeAnswer(state.codePayload.source,t.answer)) c.fail('conversation_changed','response_identity');
        if (state.codePayload && !sameCode(state.codePayload.source,current)) dom.codePayloadFailure('candidate_changed');
        if (!state.codePayload) state.codePayload = {candidate:crypto.randomUUID(),source:current,spent:false};
        codeMetadata = {version:1,state:'pending',candidate:state.codePayload.candidate,responseID:current.responseID};
      } else if (state.codePayload && !cleanupInspection && !state.deletion && !deletionActions.includes(input.action)) {
        if (!sameCodeAnswer(state.codePayload.source,t.answer)) c.fail('conversation_changed','response_identity');
        dom.codePayloadFailure('candidate_missing');
      }
      const complete = terminalUI && extracted.finalMarkup && !!extracted.text.trim();
      return { t, form, output: { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
        composer: c.enabled(form.editor), userCount: t.users.length, responseCount: t.answers.length,
        [usesModes ? 'modeEvidence' : 'modelEvidence']: evidence,
        ...(usesModes && !evidence && modeObservationDiagnostic ? { modeObservationDiagnostic } : {}),
        ...(codeMetadata ? {qwenCodePayload:codeMetadata} : {}),
        ...(state.responseChoice?.acknowledged ? {savedResponseChoice:responseChoiceMetadata('acknowledged')} : {}),
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
    if (config.responseChoice === 'qwen_smrm' && state.submitted && !state.first && route.kind === 'canonical'
      && (state.responseChoice || input.allowSavedResponseChoice === true && dom.hasResponseChoice())) {
      // Conversation ownership is sealed independently of either reply. This
      // receipt grants neither output, ordinary first-body proof, nor deletion.
      const refuse = () => c.fail('conversation_changed', 'response_choice_scope');
      if (input.action !== 'inspect' || input.allowSavedResponseChoice !== true
        || input.allowQwenInitialResponseIdentity !== true || cleanupInspection
        || !state.inserted || !state.prepared || !state.send || !state.model || state.selection || state.deletion
        || input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null
        || !qwenCodeEnabled || !c.uuid(input.expectedFirstUserMarker) || input.expectedFirstUserMarker !== state.inserted.marker
        || !state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)
        || !c.equalChoice(input.expectedModelChoice, state.model.choice)
        || !/^[a-f0-9]{64}$/.test(state.submittedFingerprint || '')
        || input.savedSubmissionFingerprint !== state.submittedFingerprint
        || !Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.includes(1)
        || input.expectedUserCounts.length > 2 || input.expectedUserCounts.some(value => ![0,1].includes(value))
        || state.responseIdentity || state.firstDisplayWitness) refuse();
      const readChoice = () => dom.responseChoiceTranscript();
      let current = readChoice();
      const pair = current.responseChoice;
      let held = state.responseChoice;
      const sameUser = t => t.users.length === 1 && t.answers.length === 1 && t.first
        && t.first.root === held.first.root && t.first.container === held.first.container
        && t.first.body === held.first.body && t.first.id === held.first.id
        && t.first.root.parentElement === held.userTurn && held.userTurn.parentElement === held.outer
        && (t.answer || t.pendingAnswer)?.root === held.root
        && held.root.parentElement === held.answerTurn && held.answerTurn.parentElement === held.outer
        && dom.route().canonical === held.canonical;
      const samePair = t => sameUser(t) && t.responseChoice && held.pins.length === t.responseChoice.pins.length
        && held.pins.every((node,i) => node === t.responseChoice.pins[i] && node.isConnected)
        && held.ids.every((id,i) => id === t.responseChoice.rows[i].id);
      if (!held) {
        if (!pair || current.users.length !== 1 || current.answers.length !== 1 || !current.first) refuse();
        held = state.responseChoice = { candidate:crypto.randomUUID(), canonical:route.canonical,
          first:current.first, userTurn:current.first.root.parentElement, outer:current.first.root.parentElement.parentElement,
          root:pair.root, answerTurn:pair.root.parentElement, wrapper:pair.wrapper,
          pins:pair.pins, ids:pair.rows.map(row => row.id), fingerprint:null, spent:false, acknowledged:false };
      }
      if (pair) {
        if (!samePair(current) || held.acknowledged) refuse();
        if (observeFirstDisplay(current, readChoice)) return { qwenFirstBodyExpansionPending:true, url:document.URL,
          sessionLifecycle:'saved_conversation_delete', temporary:false };
      } else if (!held.spent || !sameUser(current) || !current.answer || current.answer.id !== held.ids[0]
        || c.nodes(current.answer.root, '.chat-response-message', 2).length !== 1
        || c.nodes(current.answer.root, '.smrm, .cmrm', 1).length) refuse();
      if (current.first.text !== state.inserted.prompt) refuse();
      checkFirstDisplaySelection('id_before_hash');
      const fingerprint = await c.hash(c.bodyText(current.first.text));
      guard();
      current = readChoice();
      if (!sameUser(current) || current.first.text !== state.inserted.prompt
        || fingerprint !== state.submittedFingerprint || held.fingerprint && fingerprint !== held.fingerprint) refuse();
      checkFirstDisplaySelection('id_after_hash');
      held.fingerprint = fingerprint;
      if (pair) {
        if (!samePair(current)) refuse();
        const row = current.responseChoice.rows[0];
        const ready = current.responseChoice.ready && c.enabled(row.control)
          && !row.footer.classList.contains('smrm-card__footer--btn-hidden') && c.hit(row.control);
        // Revealing this pinned, completed card changes presentation only. It
        // cannot choose a response; the separate native grant below does that.
        if (current.responseChoice.ready && !ready && !held.revealed && !held.spent) {
          held.revealed = true;
          if (typeof row.content.scrollTo === 'function' && Number.isFinite(row.content.scrollHeight)
            && row.content.scrollHeight >= 0 && row.content.scrollHeight <= 100000000)
            row.content.scrollTo({top:row.content.scrollHeight,behavior:'instant'});
          if (typeof row.control.scrollIntoView === 'function') row.control.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
          guard();
          if (!samePair(readChoice())) refuse();
        }
        const modelEvidence = selectionEvidence(true, 'response_choice_ready');
        if (input.savedResponseChoiceGrant != null) {
          const grant = input.savedResponseChoiceGrant;
          if (!ready || held.spent || !grant || Object.keys(grant).sort().join(',') !== 'candidate,grant,kind,policy,responseIDs,selectedResponseID,sequence,version'
            || grant.version !== 1 || grant.sequence !== 1 || grant.kind !== 'qwen_smrm'
            || grant.policy !== 'first_observed_card_v1' || grant.candidate !== held.candidate
            || grant.selectedResponseID !== held.ids[0] || !Array.isArray(grant.responseIDs)
            || grant.responseIDs.length !== 2 || grant.responseIDs.some((id,i) => id !== held.ids[i])
            || !c.uuid(grant.grant) || !sampleDeadline) refuse();
          if (Date.now() >= sampleDeadline.epoch || performance.now() >= sampleDeadline.monotonic)
            c.fail('conversation_changed', 'response_choice_deadline');
          // Both native and JS claims are spent before the official click,
          // including throws, lost acknowledgement, cancellation and timeout.
          held.spent = true; held.grant = grant.grant;
          row.control.click();
          return { savedResponseChoice:responseChoiceMetadata('dispatched'), modelEvidence,
            url:held.canonical, sessionLifecycle:'saved_conversation_delete', temporary:false };
        }
        return { savedResponseChoice:responseChoiceMetadata(held.spent ? 'dispatched' : ready ? 'ready' : 'waiting'),
          modelEvidence, url:document.URL,
          sessionLifecycle:'saved_conversation_delete', temporary:false };
      }
      if (input.savedResponseChoiceGrant != null || !held.spent || !held.grant
        || !current.answer || current.answer.id !== held.ids[0]
        || c.nodes(current.answer.root, '.chat-response-message', 2).length !== 1
        || c.nodes(current.answer.root, '.smrm, .cmrm', 1).length) refuse();
      // Only the acknowledged official preference can replace comparison
      // content. Every user/ancestor pin survives; the sole reply UUID is fixed.
      if (state.firstDisplay) {
        const view = dom.firstBodyPresentation(current), display = state.firstDisplay;
        if (!display.complete || !view || view.collapsed || view.userID !== display.userID
          || view.pins.length !== display.pins.length || display.pins.at(-1) !== held.wrapper
          || view.pins.some((node,i) => i !== view.pins.length - 1 && node !== display.pins[i])) refuse();
        display.pins = view.pins; display.answerID = held.ids[0];
      }
      held.acknowledged = true;
      state.responseIdentity = { canonical:held.canonical, fromEmptyContainer:false, first:current.first,
        userTurn:held.userTurn, outer:held.outer,
        answer:{root:current.answer.root,content:current.answer.content,turn:held.answerTurn} };
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
      const initialResponse = () => {
        const canObserveEmpty = config.firstEmptyContainerChoice && c.equalChoice(state.model.choice, config.firstEmptyContainerChoice)
          && !state.firstDisplay && !state.firstDisplayWitness && (!state.responseIdentity || state.responseIdentity.answer.content === null);
        return dom.initialResponseIdentityTranscript(canObserveEmpty ? state.inserted.prompt : null);
      };
      const candidate = initialResponse();
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
        if (!state.responseIdentity) state.responseIdentity = { canonical: route.canonical, fromEmptyContainer: candidate.pendingAnswer.content === null,
          first: candidate.first, answer: candidate.pendingAnswer,
          userTurn: candidate.first.root.parentElement, outer: candidate.pendingAnswer.outer };
        let fingerprint;
        try { fingerprint = await c.hash(c.bodyText(candidate.first.text)); }
        catch (error) { tagFirstBodyHashFailure(error, 'initial_response_digest'); throw error; }
        guard();
        const current = initialResponse();
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
      || input.expectedUserCounts.some(value => ![0, 1].includes(value)) || !input.expectedUserCounts.includes(initial.t.users.length)) {
      if (dom.rejectUserCount) dom.rejectUserCount('expected', initial.t.users, initial.t.answers);
      c.fail('conversation_changed', 'user_count');
    }
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
    if (input.action === 'inspect') {
      const out = initial.output, choice = input.expectedModelChoice;
      if (input.qwenCodePayloadSample != null) {
        const grant = input.qwenCodePayloadSample, held = state.codePayload;
        if (!qwenCodeEnabled || cleanupInspection || state.deletion || !state.first || !held || held.spent
          || input.allowFirstUserBinding !== false || input.expectedFirstUserFingerprint !== state.first.fingerprint
          || Object.keys(grant).sort().join(',') !== 'candidate,grant,responseID,sequence,version'
          || grant.version !== 1 || grant.sequence !== 1 || !c.uuid(grant.grant)
          || grant.candidate !== held.candidate || grant.responseID !== held.source.responseID
          || out.qwenCodePayload?.state !== 'pending' || !out.firstUserVerified || !out.firstUserMarkerVerified)
          c.fail('conversation_changed','response_identity');
        held.spent = true;
        const recheck = () => {
          sampleCurrent(); guard(); selectionEvidence();
          if (!sameFirst(state.first) || dom.route().canonical !== state.canonical || !dom.completionCandidate(dom.transcript().answer))
            c.fail('conversation_changed','response_identity');
          const transcript = dom.transcript(), current = dom.rawAnswer(transcript.answer).codePayload;
          if (!sameCodeAnswer(held.source,transcript.answer) || transcript.users.length !== 1 || transcript.answers.length !== 1)
            c.fail('conversation_changed','response_identity');
          // This dispatch samples the provider's owned Copy source; it is not a
          // pointer gesture and carries no general browser-action hit authority.
          if (!sameCode(held.source,current)) dom.codePayloadFailure('candidate_changed');
        };
        // This final source sample follows every body/model await. Neither the
        // callback nor this return path may introduce a source-dependent await.
        const text = dom.sampleCodePayload(held.source,input.qwenCodePayloadChannel,grant.grant,recheck);
        return {...out,text,answerComplete:true,busy:false,
          qwenCodePayload:{version:1,state:'sampled',grant:grant.grant,candidate:held.candidate,responseID:held.source.responseID}};
      }
      // Metadata for a separately armed native marker comparison. Ordinary acceptance precedes it.
      if (input.qwenSyntheticMarkerComparison === true && key === '__computaQwenSavedSessionV1'
        && !cleanupInspection && !state.deletion && !input.allowFirstUserBinding && route.kind === 'canonical'
        && c.equalChoice(out.modelEvidence?.selected, choice)
        && ['Qwen3.7-Plus','Qwen3.8-Max'].some(label => c.equalChoice(choice, {key:label, label}))
        && out.answerComplete && out.firstUserVerified && out.firstUserMarkerVerified
        && out.userCount === 1 && out.responseCount === 1 && c.uuid(initial.t.answer?.id)
        && out.firstUserFingerprint === input.expectedFirstUserFingerprint
        && out.firstUserFingerprint === state.submittedFingerprint)
        out.qwenShadowResponseID = initial.t.answer.id;
      return out;
    }
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
        || config.stateKey === '__computaQwenSavedSessionV1' && input.action === 'inspect'
          && error.error === 'document_changed' && error.detail === 'response_container_multiple'
        || ['__computaQwenSavedSessionV1', '__computaDeepSeekSavedSessionV1'].includes(config.stateKey)
          && error.error === 'unsupported_response_format' && error.detail === 'authored_source')
        ? { adapterFailureStructure: error.adapterFailureStructure } : {}),
      ...(config.stateKey === '__computaQwenSavedSessionV1' && input.action === 'inspect' && state?.submitted
        && input.savedCleanupInspection !== true && error.error === 'conversation_changed' && error.detail === 'user_count' && error.qwenCountFailure
        ? { qwenCountFailure: { ...error.qwenCountFailure, adapterFirstBound: !!state?.first } } : {}),
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
        ? { qwenFirstUserBindingDiagnostic: error.qwenFirstUserBindingDiagnostic,
            ...(error.qwenDisplayCover ? {qwenDisplayCover:error.qwenDisplayCover} : {}) } : {}) }
      : { error: 'document_changed' };
  }
}
