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
          if (stage === 'display_held' && diagnostic.reason === 'answer_ancestry_changed' && typeof structure === 'function') {
            try { diagnostic.ancestry = structure(); } catch { /* Keep the original rejected pin. */ }
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
    // A finite provider error is independent of positive reply/body admission.
    // This Qwen-only observation precedes provisional/identity pending paths.
    if (config.modelQuota === 'qwen_tv_card_v1' && ['inspect', 'verifyModel'].includes(input.action)
      && !cleanupInspection && state.submitted && !state.deletion && !state.selection && state.model
      && state.inserted && state.prepared && state.send && c.choiceValid(input.expectedModelChoice)
      && c.equalChoice(input.expectedModelChoice, {key:'Qwen3.8-Max',label:'Qwen3.8-Max'})
      && c.equalChoice(state.model.choice, input.expectedModelChoice)
      && c.uuid(input.expectedFirstUserMarker) && input.expectedFirstUserMarker === state.inserted.marker
      && state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`)
      && /^[a-f0-9]{64}$/.test(state.submittedFingerprint || '')
      && input.savedSubmissionFingerprint === state.submittedFingerprint
      && (state.first ? input.allowFirstUserBinding === false && input.expectedFirstUserFingerprint === state.first.fingerprint
        : input.allowFirstUserBinding === true && input.expectedFirstUserFingerprint == null)
      && Array.isArray(input.expectedUserCounts) && input.expectedUserCounts.length > 0 && input.expectedUserCounts.length <= 2
      && input.expectedUserCounts.every(value => [0,1].includes(value)) && input.expectedUserCounts.includes(1)
      && typeof dom.modelQuotaTV === 'function') {
      const qwenQuotaScope = dom.modelQuotaTV({prompt:state.inserted.prompt, prepared:state.prepared,
        first:state.first, identity:state.responseIdentity, display:state.firstDisplay || state.firstDisplayWitness});
      // A no-card page keeps its original pending/held-picker path. Fresh
      // selection is still mandatory before publishing any negative receipt.
      if (qwenQuotaScope) {
        const modelEvidence = selectionEvidence(false, 'quota_observation');
        if (modelEvidence && c.equalChoice(modelEvidence.selected, input.expectedModelChoice))
          return {error:'website_usage_limit', modelEvidence, qwenQuotaScope};
      }
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
    function requireSameFirstDisplay(view, stage, rejectedIdentityFacts = null, comparison = false) {
      const held = state.firstDisplay;
      const reject = (reason, structure = null) => firstBindingFailure(stage, reason, structure);
      if (!view) reject('presentation_missing');
      if (held.canonical !== dom.route().canonical) reject('route_changed');
      if (held.userID !== view.userID) firstBindingFailure(stage, 'user_id_changed', rejectedIdentityFacts);
      if (held.answerID !== null && held.answerID !== view.answerID) reject('answer_id_changed');
      requireDisplayPins(held, view, reject, 'claim', comparison);
    }
    function requireDisplayPins(held, view, reject, path = 'claim', comparison = false) {
      let count, previous, current;
      if ((count = held.pins.length) !== view.pins.length) reject('pin_count_changed');
      const i = held.pins.findIndex((node, i) => node !== (current = view.pins[i]) && (previous = node, true));
      if (i >= 0) reject(i === 0 ? 'body_changed' : i === 1 ? 'control_changed'
        : i < held.pins.length - 3 ? 'user_ancestry_changed' : 'answer_ancestry_changed', () => ({
          path, branch:'pins', index:i, count,
          slot:i === count - 3 ? 'assistant_root' : i === count - 2 ? 'assistant_turn' : 'response_content',
          previous:previous === null ? 'null' : previous === undefined ? 'undefined' : typeof previous === 'object' ? 'object' : 'other',
          current:current === null ? 'null' : current === undefined ? 'undefined' : typeof current === 'object' ? 'object' : 'other', comparison }));
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
    function observeFirstDisplay(t, transcriptReader = () => dom.initialResponseIdentityTranscript(), comparisonPair = null) {
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
      if (held) requireSameFirstDisplay(view, 'display_held', null, !!comparisonPair);
      if (optimistic) {
        const refuse = (reason, structure = null) => firstBindingFailure('display_held', reason, structure);
        if (!view) refuse('presentation_missing');
        if (optimistic.canonical !== route.canonical) refuse('route_changed');
        if (comparisonPair) {
          // No response UUID or full-body proof is bound yet. Replace the
          // pending presentation slot with the validated SMRM wrapper.
          if (held || state.responseIdentity || comparisonPair !== t.responseChoice
            || view.pins.at(-1) !== comparisonPair.wrapper) refuse('answer_ancestry_changed', () => ({
              path:'witness', branch:'comparison_scope', index:null, count:null, slot:'none', previous:'unknown', current:'unknown', comparison:true }));
          const prior = optimistic.pins.at(-1);
          const priorCardIndex = comparisonPair.rows.findIndex(row => row.response === prior);
          const priorDetached = prior?.isConnected === false;
          if (!prior || !priorDetached && priorCardIndex < 0) refuse('answer_ancestry_changed', () => ({
              path:'witness', branch:'comparison_prior', index:null, count:null, slot:'none', previous:'unknown', current:'unknown', comparison:true }));
          const pins = [...optimistic.pins.slice(0, -1), comparisonPair.wrapper];
          const rootIndex = pins.length - 3;
          const oldRootDetached = pins[rootIndex]?.isConnected === false;
          const pairRootMatches = comparisonPair.root === view.pins.at(-3);
          // A disconnected root can hand off the same response in the first
          // card or yield a detached, unbound placeholder to the current pair.
          // The assistant turn and every user pin must still match. The pair
          // earns no preference grant until the full submitted body is proved.
          if (oldRootDetached && pairRootMatches && (priorCardIndex === 0 || priorCardIndex < 0 && priorDetached))
            pins[rootIndex] = comparisonPair.root;
          requireDisplayPins({ pins }, view, (reason, structure) => {
            if (reason !== 'answer_ancestry_changed') return refuse(reason, structure);
            return refuse(reason, () => {
              const facts = structure();
              if (facts.slot !== 'assistant_root') return facts;
              // These finite facts explain a rejected remount. They do not
              // supply new proof or read anything outside the existing pins.
              return { ...facts, continuity: { oldRootDetached, pairRootMatches,
                priorResponse: priorCardIndex === 0 ? 'first_card' : priorCardIndex === 1 ? 'second_card' : 'detached',
                assistantTurnMatches: optimistic.pins.at(-2) === view.pins.at(-2) } };
            });
          }, 'witness', true);
        } else requireDisplayPins(optimistic, view, refuse, 'witness', false);
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
      && held.kind === current.kind && held.rawCandidate === current.rawCandidate && held.parentID === current.parentID
      && held.nodes.length === current.nodes.length && held.nodes.every((node,index) => node === current.nodes[index] && node.isConnected);
    const payloadMetadata = (held, stateName, grant) => ({version:held.source.kind === 'raw_answer_v1' ? 2 : 1,
      state:stateName,...(grant ? {grant} : {}),candidate:held.candidate,responseID:held.source.responseID,
      ...(held.source.kind === 'raw_answer_v1' ? {sourceKind:'raw_answer_v1'} : {})});
    function withReplyProgressUI(output, transcript, form = null, terminal = null) {
      if (config.stateKey === '__computaQwenSavedSessionV1' && input.qwenProgressUI === true
        && input.action === 'inspect' && state.submitted && !cleanupInspection && typeof dom.replyProgressUI === 'function') {
        try {
          const ui=dom.replyProgressUI(transcript,form,terminal,
            c.equalChoice(input.expectedModelChoice,{key:'Qwen3.8-Max',label:'Qwen3.8-Max'}));
          if (ui) output.qwenReplyUI=ui;
        } catch { /* Metadata cannot replace the original result/error. */ }
      }
      return output;
    }
    function read() {
      const t = dom.transcript(), form = dom.composer(), evidence = selectionEvidence(false);
      validateInitialResponseIdentity(t, 'ordinary_read');
      let extracted = dom.rawAnswer(t.answer), rawSourceFailure = null;
      state.initialReadComplete = true;
      const terminalUI = !!state.first && !!evidence && !state.deletion && dom.completionCandidate(t.answer);
      if (terminalUI && extracted.formatIssue && qwenCodeEnabled
        && (input.action === 'inspect' || input.action === 'verifyModel' && state.codePayload?.source.kind === 'raw_answer_v1')
        && !cleanupInspection && !state.deletion && typeof dom.authoredSourceCandidate === 'function') {
        const source = dom.authoredSourceCandidate(t.answer,input.qwenCodePayloadChannel,state.first.id,value => { rawSourceFailure = value; });
        if (source) extracted = {text:'',finalMarkup:false,formatIssue:false,codePayload:source};
      }
      if (terminalUI && extracted.formatIssue && !cleanupInspection && !deletionActions.includes(input.action)) {
        try { c.fail('unsupported_response_format', 'authored_source'); }
        catch (error) {
          if (input.action === 'inspect' && error?.computaAdapterFailure && typeof extracted.failureStructure === 'function') {
            try {
              const qwenChoice = config.stateKey === '__computaQwenSavedSessionV1'
                && c.equalChoice(evidence.selected, input.expectedModelChoice)
                && ['Qwen3.7-Plus', 'Qwen3.8-Max'].some(label => c.equalChoice(evidence.selected, { key: label, label }));
              if (qwenChoice || config.stateKey === '__computaDeepSeekSavedSessionV1') {
                const original = extracted.failureStructure();
                error.adapterFailureStructure = rawSourceFailure ? {...original,rawSource:rawSourceFailure} : original;
              }
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
        codeMetadata = payloadMetadata(state.codePayload,'pending');
      } else if (state.codePayload && !cleanupInspection && !state.deletion && !deletionActions.includes(input.action)) {
        if (!sameCodeAnswer(state.codePayload.source,t.answer)) c.fail('conversation_changed','response_identity');
        dom.codePayloadFailure('candidate_missing');
      }
      const complete = terminalUI && extracted.finalMarkup && !!extracted.text.trim();
      const result = { t, form, output: { url: document.URL, sessionLifecycle: 'saved_conversation_delete', temporary: false,
        composer: c.enabled(form.editor), userCount: t.users.length, responseCount: t.answers.length,
        [usesModes ? 'modeEvidence' : 'modelEvidence']: evidence,
        ...(usesModes && !evidence && modeObservationDiagnostic ? { modeObservationDiagnostic } : {}),
        ...(codeMetadata ? {qwenCodePayload:codeMetadata} : {}),
        ...(state.responseChoice?.acknowledged ? {savedResponseChoice:responseChoiceMetadata('acknowledged')} : {}),
        text: state.first && !cleanupInspection ? extracted.text : '', answerComplete: !!complete && !cleanupInspection,
        busy: state.submitted && !complete, interrupted: false, conversationIdentity: state.first ? state.canonical : null,
        firstUserIdentity: state.first?.id || null, firstUserVerified: false, firstUserMarkerVerified: false, firstUserFingerprint: null } };
      withReplyProgressUI(result.output,t,form,state.first && evidence && !state.deletion ? terminalUI : null);
      return result;
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
      let choiceStage = 'admission_action';
      const refuse = (stage = choiceStage) => {
        try { c.fail('conversation_changed', 'response_choice_scope'); }
        catch (error) {
          try { if (error?.computaAdapterFailure) error.qwenResponseChoiceStage = stage; }
          catch { /* Failure-only metadata cannot replace the original refusal. */ }
          throw error;
        }
      };
      if ((choiceStage = 'admission_action', input.action !== 'inspect')
        || (choiceStage = 'admission_choice_grant', input.allowSavedResponseChoice !== true)
        || (choiceStage = 'admission_identity_grant', input.allowQwenInitialResponseIdentity !== true)
        || (choiceStage = 'admission_cleanup', cleanupInspection)
        || (choiceStage = 'admission_inserted', !state.inserted)
        || (choiceStage = 'admission_prepared', !state.prepared)
        || (choiceStage = 'admission_send', !state.send)
        || (choiceStage = 'admission_model', !state.model)
        || (choiceStage = 'admission_selection', state.selection)
        || (choiceStage = 'admission_deletion', state.deletion)
        || (choiceStage = 'admission_first_bind_grant', input.allowFirstUserBinding !== true)
        || (choiceStage = 'admission_prior_fingerprint', input.expectedFirstUserFingerprint != null)
        || (choiceStage = 'admission_code_payload', !qwenCodeEnabled)
        || (choiceStage = 'admission_marker_uuid', !c.uuid(input.expectedFirstUserMarker))
        || (choiceStage = 'admission_marker_match', input.expectedFirstUserMarker !== state.inserted.marker)
        || (choiceStage = 'admission_prompt_marker', !state.inserted.prompt.endsWith(`\n\nComputa session marker: ${input.expectedFirstUserMarker}`))
        || (choiceStage = 'admission_model_choice', !c.equalChoice(input.expectedModelChoice, state.model.choice))
        || (choiceStage = 'admission_submitted_digest', !/^[a-f0-9]{64}$/.test(state.submittedFingerprint || ''))
        || (choiceStage = 'admission_submission_match', input.savedSubmissionFingerprint !== state.submittedFingerprint)
        || (choiceStage = 'admission_counts_array', !Array.isArray(input.expectedUserCounts))
        || (choiceStage = 'admission_counts_one', !input.expectedUserCounts.includes(1))
        || (choiceStage = 'admission_counts_limit', input.expectedUserCounts.length > 2)
        || (choiceStage = 'admission_counts_values', input.expectedUserCounts.some(value => ![0,1].includes(value)))
        || (choiceStage = 'admission_response_identity', state.responseIdentity)
        || (choiceStage = 'admission_display_witness', state.firstDisplayWitness && !Array.isArray(state.firstDisplayWitness.pins))) refuse();
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
        if (!pair || current.users.length !== 1 || current.answers.length !== 1 || !current.first) refuse('initial_pair');
        held = state.responseChoice = { candidate:crypto.randomUUID(), canonical:route.canonical,
          first:current.first, userTurn:current.first.root.parentElement, outer:current.first.root.parentElement.parentElement,
          root:pair.root, answerTurn:pair.root.parentElement, wrapper:pair.wrapper,
          pins:pair.pins, ids:pair.rows.map(row => row.id), fingerprint:null, spent:false, acknowledged:false };
      }
      if (pair) {
        if ((choiceStage = 'pair_scope', !samePair(current)) || (choiceStage = 'pair_ack_state', held.acknowledged)) refuse();
        if (observeFirstDisplay(current, readChoice, pair)) return withReplyProgressUI({ qwenFirstBodyExpansionPending:true, url:document.URL,
          sessionLifecycle:'saved_conversation_delete', temporary:false },current);
      } else if (!held.spent || !sameUser(current) || !current.answer || current.answer.id !== held.ids[0]
        || c.nodes(current.answer.root, '.chat-response-message', 2).length !== 1
        || c.nodes(current.answer.root, '.smrm, .cmrm', 1).length) refuse('selected_scope');
      if (current.first.text !== state.inserted.prompt) refuse('full_body');
      checkFirstDisplaySelection('id_before_hash');
      const fingerprint = await c.hash(c.bodyText(current.first.text));
      guard();
      current = readChoice();
      if (!sameUser(current) || current.first.text !== state.inserted.prompt
        || fingerprint !== state.submittedFingerprint || held.fingerprint && fingerprint !== held.fingerprint) refuse('hash_scope');
      checkFirstDisplaySelection('id_after_hash');
      held.fingerprint = fingerprint;
      if (pair) {
        if (!samePair(current)) refuse('pair_after_hash');
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
          if (!samePair(readChoice())) refuse('reveal_scope');
        }
        const modelEvidence = selectionEvidence(true, 'response_choice_ready');
        if (input.savedResponseChoiceGrant != null) {
          const grant = input.savedResponseChoiceGrant;
          if (!ready || held.spent || !grant || Object.keys(grant).sort().join(',') !== 'candidate,grant,kind,policy,responseIDs,selectedResponseID,sequence,version'
            || grant.version !== 1 || grant.sequence !== 1 || grant.kind !== 'qwen_smrm'
            || grant.policy !== 'first_observed_card_v1' || grant.candidate !== held.candidate
            || grant.selectedResponseID !== held.ids[0] || !Array.isArray(grant.responseIDs)
            || grant.responseIDs.length !== 2 || grant.responseIDs.some((id,i) => id !== held.ids[i])
            || !c.uuid(grant.grant) || !sampleDeadline) refuse('grant_scope');
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
        || c.nodes(current.answer.root, '.smrm, .cmrm', 1).length) refuse('selected_ack');
      // Only the acknowledged official preference can replace comparison
      // content. Every user/ancestor pin survives; the sole reply UUID is fixed.
      if (state.firstDisplay) {
        const view = dom.firstBodyPresentation(current), display = state.firstDisplay;
        if (!display.complete || !view || view.collapsed || view.userID !== display.userID
          || view.pins.length !== display.pins.length || display.pins.at(-1) !== held.wrapper
          || view.pins.some((node,i) => i !== view.pins.length - 1 && node !== display.pins[i])) refuse('display_ack');
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
      if (observeFirstDisplay(candidate)) return withReplyProgressUI({ qwenFirstBodyExpansionPending: true, url: document.URL,
        sessionLifecycle: 'saved_conversation_delete', temporary: false },candidate);
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
        if (current.pendingAnswer) return withReplyProgressUI({ qwenInitialResponseIdentityPending: true, url: document.URL,
          sessionLifecycle: 'saved_conversation_delete', temporary: false },current);
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
        const rawSource = held?.source.kind === 'raw_answer_v1';
        if (!qwenCodeEnabled || cleanupInspection || state.deletion || !state.first || !held || held.spent
          || input.allowFirstUserBinding !== false || input.expectedFirstUserFingerprint !== state.first.fingerprint
          || Object.keys(grant).sort().join(',') !== (rawSource ? 'candidate,grant,responseID,sequence,sourceKind,version' : 'candidate,grant,responseID,sequence,version')
          || grant.version !== (rawSource ? 2 : 1) || rawSource && grant.sourceKind !== 'raw_answer_v1'
          || grant.sequence !== 1 || !c.uuid(grant.grant)
          || grant.candidate !== held.candidate || grant.responseID !== held.source.responseID
          || out.qwenCodePayload?.state !== 'pending' || !out.firstUserVerified || !out.firstUserMarkerVerified)
          c.fail('conversation_changed','response_identity');
        held.spent = true;
        const recheck = () => {
          sampleCurrent(); guard(); selectionEvidence();
          if (!sameFirst(state.first) || dom.route().canonical !== state.canonical || !dom.completionCandidate(dom.transcript().answer))
            c.fail('conversation_changed','response_identity');
          const transcript = dom.transcript(), current = rawSource
            ? dom.authoredSourceCandidate(transcript.answer,input.qwenCodePayloadChannel,state.first.id)
            : dom.rawAnswer(transcript.answer).codePayload;
          if (!sameCodeAnswer(held.source,transcript.answer) || transcript.users.length !== 1 || transcript.answers.length !== 1)
            c.fail('conversation_changed','response_identity');
          // The closed kind is either owned Copy or a read-only current props
          // source. Neither carries general browser-action hit authority.
          if (!sameCode(held.source,current)) dom.codePayloadFailure('candidate_changed');
        };
        // This final source sample follows every body/model await. Neither the
        // callback nor this return path may introduce a source-dependent await.
        const text = dom.sampleCodePayload(held.source,input.qwenCodePayloadChannel,grant.grant,recheck);
        return {...out,text,answerComplete:true,busy:false,
          qwenCodePayload:payloadMetadata(held,'sampled',grant.grant)};
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
    if (config.stateKey === '__computaQwenSavedSessionV1' && input.action === 'inspect'
      && error?.computaAdapterFailure && error.error === 'document_changed' && error.detail === 'response_container'
      && error.adapterFailureStructure?.trigger === 'response_container') {
      try {
        error.adapterFailureStructure = { ...error.adapterFailureStructure,
          firstBodyBound: !!state?.first, responseIdentityRetained: !!state?.responseIdentity };
      } catch { /* Finite state labels cannot replace the original rejection. */ }
    }
    return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}),
      ...(error.adapterFailureStructure && (config.stateKey === '__computaQwenSavedSessionV1'
        && error.error === 'conversation_changed' && error.detail === 'first_user_message'
        || config.stateKey === '__computaQwenSavedSessionV1' && input.action === 'inspect'
          && error.error === 'document_changed' && ['response_container_multiple', 'response_container'].includes(error.detail)
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
      ...(config.stateKey === '__computaQwenSavedSessionV1' && error.error === 'conversation_changed'
        && error.detail === 'response_choice_scope' && error.qwenResponseChoiceStage
        ? { qwenResponseChoiceStage: error.qwenResponseChoiceStage } : {}),
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
    return { scope, deepThink, search, choices: [{ key: 'chat', label: 'Chat' }, { key: 'deepthink', label: 'DeepThink' }] };
  }
  function modeEvidence() {
    const modes = modeControls();
    if (modes.search.selected) c.fail('model_unverified');
    return { selected: modes.choices[modes.deepThink.selected ? 1 : 0],
      source: 'website_mode_toggle', backendModel: null, search: false };
  }
  function rejectFirstContainer(root, container, body) {
    // Failure-only metadata from the already selected nodes. No extra selector,
    // action, page read or body value leaves this call; diagnostic failure cannot
    // replace the original terminal rejection. Counts saturate at 16, rows at 4.
    let diagnostic;
    try {
      const rootText = root.textContent, containerText = container.textContent, bodyText = body.textContent;
      const children = container.children, tags = ['DIV', 'SPAN', 'BUTTON', 'SVG', 'P', 'BR', 'INPUT', 'TEXTAREA'];
      const count = node => Math.min(16, node.children.length);
      diagnostic = { version: 1, containerChildren: count(container), wrapperChildren: count(children[0]),
        bodyChildren: count(body), rootEqualsBody: rootText === bodyText, containerEqualsBody: containerText === bodyText,
        rootEmpty: rootText === '', containerEmpty: containerText === '', bodyEmpty: bodyText === '',
        childrenOmitted: children.length > 4, children: Array.from({ length: Math.min(4, children.length) }, (_, index) => {
          const child = children[index];
          return { tag: tags.includes(child.tagName) ? child.tagName : 'other', children: count(child),
            empty: child.textContent === '', containsBody: child.contains(body) };
        }) };
    } catch { /* Retain only the original fixed failure if metadata is unavailable. */ }
    try { c.fail('conversation_changed', 'first_container_children'); }
    catch (error) {
      if (diagnostic && error?.computaAdapterFailure) error.firstContainerDiagnostic = diagnostic;
      throw error;
    }
  }
  function emptyNoninteractiveDecoration(node) {
    // The observed collapsed prompt appends one empty DIV leaf. It contributes
    // no text and is never a control or an action target for this adapter.
    return node?.tagName === 'DIV' && node.children.length === 0 && node.textContent === ''
      && [null, '', 'none', 'presentation'].includes(node.getAttribute('role'))
      && ['tabindex', 'contenteditable', 'aria-haspopup', 'aria-controls', 'aria-activedescendant',
        'aria-pressed', 'aria-checked', 'aria-expanded', 'onclick'].every(name => node.getAttribute(name) === null);
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
    // Retain the unique complete prompt and exact whole-root/container text.
    // A textless decoration may be a sibling, never a substitute prompt body.
    if (!c.visible(root)) c.fail('conversation_changed', 'first_root_hidden');
    if (!id || !/^-?[0-9]{1,10}$/.test(id)) c.fail('conversation_changed', 'first_id_invalid');
    const children = container.children;
    const decorated = children.length === 2 && children[0].contains(body)
      && emptyNoninteractiveDecoration(children[1]);
    if (children.length !== 1 && !decorated) rejectFirstContainer(root, container, body);
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
    const unsupported = predicate => {
      const result = { text: '', finalMarkup: false, formatIssue: true };
      // Defer all diagnostic DOM reads until the engine is already rejecting
      // this exact terminal inspect. Streaming/cleanup reads gain no new work.
      Object.defineProperty(result, 'failureStructure', { value: () => {
        const categories = [['ds-assistant-message-main-content', 'final'], ['_74c0879', 'reasoning'],
          ['ds-markdown-paragraph', 'paragraph'], ['md-code-block', 'code_block'], ['md-code-block-banner-wrap', 'code_header'],
          ['d813de27', 'code_language'], ['code-info-button-text', 'code_label'], ['_33882ae', 'code_corner_left'],
          ['_28d7e84', 'code_corner_right'], ['token', 'syntax_token']];
        const region = finals.length === 1 ? finals[0] : answer.root;
        const captured = computaSavedFailureTree(region, c, categories);
        let knownReasoningPresent = false;
        for (let i = 0; i < Math.min(answer.root.children.length, 257); i++)
          if (answer.root.children[i].classList.contains('_74c0879')) knownReasoningPresent = true;
        const knownChromePresent = captured.tree.some(row => ['code_header', 'code_label', 'code_corner_left', 'code_corner_right'].includes(row.category));
        return { version: 1, provider: 'deepseek', trigger: 'authored_source', predicate,
          nodeLimitReached: captured.nodeLimitReached, nodeCount: captured.tree.length, tree: captured.tree,
          finalCount: Math.min(finals.length, 257), finalCountOverflow: finals.length > 257,
          knownReasoningPresent, knownReasoningExcluded: knownReasoningPresent,
          knownChromePresent, knownChromeTextExcluded: true };
      } });
      return result;
    };
    const finals = c.nodes(answer.root, '.ds-assistant-message-main-content');
    if (!finals.length) return { text: '', finalMarkup: false, formatIssue: false };
    if (finals.length !== 1) return unsupported('final_count');
    const final = finals[0];
    if (!c.visible(final)) return unsupported('final_visibility');
    if (!final.classList.contains('ds-markdown') || final.parentElement !== answer.root)
      return unsupported('final_parent');
    const siblings = [...answer.root.children];
    if (siblings.some(node => node !== final && (!node.classList.contains('_74c0879') || siblings.indexOf(node) > siblings.indexOf(final)))
      || siblings.filter(node => node !== final).length > 1
      || [...answer.root.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || '')))
      return unsupported('sibling_scope'); // The known reasoning sibling is never traversed/read.
    const child = (parent, tag, cls) => {
      if (!c.visible(parent) || parent.children.length !== 1
        || [...parent.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || ''))) return null;
      const node = parent.children[0];
      return node.tagName === tag && (!cls || node.classList.contains(cls)) && c.visible(node) ? node : null;
    };
    const paragraph = child(final, 'P', 'ds-markdown-paragraph');
    let literal = paragraph && child(paragraph, 'SPAN', null);
    if (literal && literal.children.length) return unsupported('literal_span_shape');
    if (!literal) {
      // The observed JSON fence is one PRE source, with syntax-highlight spans.
      // Read its whole literal text; never join paragraphs, choose one of
      // several blocks, repair JSON, or include reasoning/presentation labels.
      const block = child(final, 'DIV', 'md-code-block');
      if (!block) return unsupported('paragraph_shape');
      if (block.children.length !== 4) return unsupported('fence_child_count');
      const [header, pre, left, right] = block.children;
      const plainWhitespace = parent => [...parent.childNodes].every(node => node.nodeType !== 3 || /^\s*$/.test(node.textContent || ''));
      const labels = c.nodes(header, '.code-info-button-text');
      const languages = c.nodes(header, 'span.d813de27');
      const controls = c.nodes(header, '[role="button"]');
      if (header.tagName !== 'DIV' || !header.classList.contains('md-code-block-banner-wrap') || !c.visible(header))
        return unsupported('header_shape');
      if (languages.length !== 1 || languages[0].children.length || languages[0].textContent !== 'json'
        || labels.length !== 2 || labels[0].textContent !== 'Copy' || labels[1].textContent !== 'Download'
        || labels.some(node => node.children.length || !c.visible(node))) return unsupported('header_labels');
      if (controls.length !== 2 || controls.some((node, index) => !node.contains(labels[index]) || !c.visible(node)))
        return unsupported('header_shape');
      if (header.textContent !== 'jsonCopyDownload') return unsupported('header_labels');
      if (!plainWhitespace(block)) return unsupported('header_shape');
      const corner = (node, cls) => node.tagName.toUpperCase() === 'SVG' && node.classList.contains('_9bc997d')
        && node.classList.contains(cls) && node.textContent === '' && node.children.length === 1
        && node.children[0].tagName.toUpperCase() === 'PATH' && node.children[0].children.length === 0;
      const noninteractive = node => ['role', 'tabindex', 'contenteditable', 'aria-hidden', 'onclick', 'onkeydown']
        .every(name => node.getAttribute(name) === null);
      if (!corner(left, '_33882ae') || !corner(right, '_28d7e84')) return unsupported('corner_shape');
      if (pre.tagName !== 'PRE') return unsupported('literal_span_shape');
      if (![final, block, pre].every(noninteractive)) return unsupported('interactive_attribute');
      literal = child(pre, 'SPAN', null);
      if (!literal) return unsupported('literal_span_shape');
      let visited = 0, spanPredicate = 'literal_span_shape';
      const literalSpans = node => {
        if (++visited > 10_000) { spanPredicate = 'node_limit'; return false; }
        if (node.nodeType === 3) return true;
        if (node.nodeType !== 1 || node.tagName !== 'SPAN' || !c.visible(node)) return false;
        if (!noninteractive(node)) { spanPredicate = 'interactive_attribute'; return false; }
        const cls = node.getAttribute('class') || '';
        if (cls !== '' && !/^token (punctuation|property|operator|string|number|boolean|null)$/.test(cls)) return false;
        return [...node.childNodes].every(literalSpans);
      };
      if (!literalSpans(literal)) return unsupported(spanPredicate);
      literal = pre;
    }
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
    if (record.menuAcknowledged !== true) c.fail('conversation_changed', 'delete_menu_open_unacknowledged');
    if (record.deleteAcknowledged === true) c.fail('conversation_changed', 'delete_menu_selection_spent');
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
    if (record.menuAcknowledged !== true) c.fail('conversation_changed', 'delete_confirm_menu_unacknowledged');
    if (record.deleteAcknowledged !== true) c.fail('conversation_changed', 'delete_confirm_selection_unacknowledged');
    if (!record.menu?.classList.contains('ds-dropdown-menu')) c.fail('conversation_changed', 'delete_confirm_menu_unbound');
    const menus = visible(document, '[role="menu"]');
    if (menus.length) {
      // Delete closes its menu asynchronously. The same pinned menu may still
      // be visible during the first confirmation read; it grants no target.
      // A foreign/replaced menu, or one returning after dialog binding, fails.
      if (!record.dialog && menus.length === 1 && menus[0] === record.menu && !authored(record.menu)) return null;
      c.fail('conversation_changed', 'delete_confirm_menu_still_visible');
    }
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
    stateKey: '__computaDeepSeekSavedSessionV1', origin: 'https://chat.deepseek.com', selectionKind: 'mode', initialModeHandoff: true
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}
