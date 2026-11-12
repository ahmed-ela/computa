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
          // The pair earns no preference grant until the full submitted body
          // is proved, including when an observed turn replacement is adopted.
          if (oldRootDetached && pairRootMatches && (priorCardIndex === 0 || priorCardIndex < 0 && priorDetached))
            pins[rootIndex] = comparisonPair.root;
          const previousTurn = optimistic.pins.at(-2), currentTurn = view.pins.at(-2);
          if (previousTurn !== currentTurn && oldRootDetached && pairRootMatches
            && priorCardIndex === 0 && prior.isConnected === true && comparisonPair.pins[1] === currentTurn
            && optimistic.turnWatch?.consume(currentTurn))
            pins[rootIndex + 1] = currentTurn;
          requireDisplayPins({ pins }, view, (reason, structure) => {
            if (reason !== 'answer_ancestry_changed') return refuse(reason, structure);
            return refuse(reason, () => {
              const facts = structure();
              const priorResponse = priorCardIndex === 0 ? 'first_card' : priorCardIndex === 1 ? 'second_card' : 'detached';
              // These facts describe a rejection and never grant ownership.
              if (facts.slot === 'assistant_root') return { ...facts, continuity: { oldRootDetached, pairRootMatches,
                priorResponse, assistantTurnMatches: optimistic.pins.at(-2) === view.pins.at(-2) } };
              if (facts.slot === 'assistant_turn' && facts.previous === 'object' && facts.current === 'object') {
                const outer = optimistic.pins.at(-4), userTurn = optimistic.pins.at(-5);
                const sameOuter = currentTurn.parentElement === outer;
                return { ...facts, turnContinuity: { oldRootDetached, oldTurnDetached: previousTurn.isConnected === false,
                  sameOuter, adjacentToUser: sameOuter && currentTurn.previousElementSibling === userTurn, priorResponse } };
              }
              return facts;
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
        if (t.pendingAnswer) {
          if (preview && input.allowSavedResponseChoice === true && !witness.turnWatch
            && config.firstDisplayTurnReplacementChoice && c.equalChoice(state.model.choice, config.firstDisplayTurnReplacementChoice))
            witness.turnWatch = dom.watchAssistantTurnReplacement(view.pins.at(-4), view.pins.at(-5), view.pins.at(-2));
          return true;
        }
        // First genuine pair. Spend a separate, unchanged native-granted read
        // after pinning it. No action or response is released by this receipt.
        witness.turnWatch?.close();
        delete witness.turnWatch;
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
    if (state?.terminal && state.firstDisplayWitness?.turnWatch) {
      state.firstDisplayWitness.turnWatch.close();
      delete state.firstDisplayWitness.turnWatch;
    }
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

// Qwen DOM driver. The saved-conversation engine owns all
// mutation claims, native acknowledgement, exact-body hashing and lifecycle.
// Input uses the engine's insertion claim; code Copy uses its single final-sample grant.
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
  // Attach only the counts already used by the failed guard. Never re-query or change the rejection.
  function rejectUserCount(site, users, answers) {
    try { c.fail('conversation_changed', 'user_count'); }
    catch (error) {
      if (error?.computaAdapterFailure) error.qwenCountFailure = { site, users: users.length, answers: answers.length };
      throw error;
    }
  }
  function rejectResponseContainer(reason, root, containers, displayed, emptyRootMode) {
    try { c.fail('document_changed', reason); }
    catch (error) {
      if (reason === 'response_container_multiple' && error?.computaAdapterFailure) {
        try {
          const first = containers.slice(0, 2), ancestors = [], ids = [];
          let smrm = false, cmrm = false, ancestorLimited = false;
          const rows = first.map(node => {
            const id = node.getAttribute('id'), suffix = id && [22,58].includes(id.length) && id.startsWith('chat-response-message-') ? id.slice(22) : null;
            const idKind = id === null ? 'missing' : suffix === '' ? 'empty_prefix' : c.uuid(suffix) ? 'uuid' : 'other';
            ids.push(idKind === 'uuid' ? suffix : null);
            const chain = []; let parent = node.parentElement;
            for (let depth = 0; parent && parent !== root && depth < 64; depth++, parent = parent.parentElement) {
              chain.push(parent); smrm ||= parent.classList.contains('smrm'); cmrm ||= parent.classList.contains('cmrm');
            }
            ancestorLimited ||= parent !== root; ancestors.push(chain);
            let loading = 0, phase = 0, footer = 0, visited = 0, limited = false;
            const stack = [{node, depth:0}];
            while (stack.length) {
              if (visited++ === 128) { limited = true; break; }
              const item = stack.pop(), child = item.node;
              if (child !== node) {
                if (child.classList.contains('response-loading')) loading = Math.min(3, loading + 1);
                if (child.classList.contains('response-message-content') && child.classList.contains('phase-answer')) phase = Math.min(3, phase + 1);
                if (child.classList.contains('response-message-footer-actions')) footer = Math.min(3, footer + 1);
              }
              const total = child.children.length;
              if (item.depth === 16) { if (total) limited = true; continue; }
              const take = Math.min(total, Math.max(0, 128 - visited - stack.length));
              if (take < total) limited = true;
              for (let index = take - 1; index >= 0; index--) stack.push({node:child.children[index],depth:item.depth + 1});
            }
            return {visible:displayed.includes(node),id:idKind,loading,phase,footer,limited};
          });
          error.adapterFailureStructure = {version:1,provider:'qwen',trigger:'response_container_multiple',
            total:Math.min(3,containers.length),displayed:Math.min(3,displayed.length),emptyRootMode,
            dual:root.classList.contains('qwen-chat-message-dual-message'),multi:root.classList.contains('qwen-chat-message-multi-message'),
            smrm,cmrm,ancestorLimited,
            relation:first[0].parentElement === first[1].parentElement ? 'siblings'
              : ancestors[0].includes(first[1]) || ancestors[1].includes(first[0]) ? 'nested' : 'other',
            idRelation:ids.every(id => id !== null) ? ids[0] === ids[1] ? 'same_uuid' : 'different_uuid' : 'other',containers:rows};
        } catch { /* Failure-only metadata cannot replace the original refusal. */ }
      }
      throw error;
    }
  }
  function ordinaryResponseContainer(root, containers, displayed) {
    // Preserve the ordinary uniqueness guard and its exact thrown value. Only
    // after rejection, describe the already selected nodes without body/ID values.
    try { return one(displayed, 'response_container'); }
    catch (error) {
      if (error?.computaAdapterFailure) {
        try {
          const first = containers.slice(0, 2), ancestors = [], ids = [];
          let smrm = false, cmrm = false, ancestorLimited = false;
          const rows = first.map(node => {
            const id = node.getAttribute('id'), suffix = id && [22,58].includes(id.length) && id.startsWith('chat-response-message-') ? id.slice(22) : null;
            const idKind = id === null ? 'missing' : suffix === '' ? 'empty_prefix' : c.uuid(suffix) ? 'uuid' : 'other';
            ids.push(idKind === 'uuid' ? suffix : null);
            const chain = []; let parent = node.parentElement;
            for (let depth = 0; parent && parent !== root && depth < 64; depth++, parent = parent.parentElement) {
              chain.push(parent); smrm ||= parent.classList.contains('smrm'); cmrm ||= parent.classList.contains('cmrm');
            }
            ancestorLimited ||= parent !== root; ancestors.push(chain);
            return {visible:displayed.includes(node),id:idKind};
          });
          error.adapterFailureStructure = {version:1,provider:'qwen',trigger:'response_container',
            total:Math.min(3,containers.length),displayed:Math.min(3,displayed.length),rootVisible:c.visible(root),
            dual:root.classList.contains('qwen-chat-message-dual-message'),multi:root.classList.contains('qwen-chat-message-multi-message'),
            smrm,cmrm,ancestorLimited,
            relation:first.length === 0 ? 'none' : first.length === 1 ? 'single'
              : first[0].parentElement === first[1].parentElement ? 'siblings'
              : ancestors[0].includes(first[1]) || ancestors[1].includes(first[0]) ? 'nested' : 'other',
            idRelation:ids.length === 2 && ids.every(id => id !== null) ? ids[0] === ids[1] ? 'same_uuid' : 'different_uuid' : 'other',containers:rows};
        } catch { /* Diagnostic reads cannot replace the original refusal. */ }
      }
      throw error;
    }
  }
  function responseChoice(node, containers, displayed, ordered, userID) {
    // The public SMRM component is anonymous. These controls establish a
    // response preference, never a per-card model/backend identity.
    const reject = () => c.fail('conversation_changed', 'response_choice_scope');
    if (!ordered() || !node.classList.contains('qwen-chat-message-dual-message')
      || node.classList.contains('qwen-chat-message-multi-message')
      || c.nodes(node, '.cmrm', 1).length || containers.length !== 2 || displayed.length !== 2) reject();
    const wrapper = one(visible(node, '.smrm', 2), 'response_choice_wrapper');
    if (wrapper.parentElement !== node || node.children.length !== 1 || node.children[0] !== wrapper) reject();
    const list = one(visible(wrapper, '.smrm-list', 2), 'response_choice_list');
    if (list.parentElement !== wrapper || c.nodes(wrapper, '.smrm__track, .smrm-pagination', 1).length) reject();
    const cards = c.nodes(list, '.smrm-card', 3);
    const allCards = c.nodes(node, '.smrm-card', 3);
    if (cards.length !== 2 || allCards.length !== 2 || list.children.length !== 2
      || cards.some((card, i) => card !== list.children[i] || card !== allCards[i] || !c.visible(card))) reject();
    const rows = cards.map((card, index) => {
      const id = card.getAttribute('id')?.replace(/-smrm-card$/, '');
      const header = one(visible(card, '.smrm-card__header', 2), 'response_choice_header');
      const body = one(visible(card, '.smrm-card__body', 2), 'response_choice_body');
      const content = one(visible(card, '.smrm-card__content', 2), 'response_choice_content');
      const footer = one(c.nodes(card, '.smrm-card__footer', 2), 'response_choice_footer');
      const control = one(c.nodes(footer, 'button.smrm-card__prefer-btn', 2), 'response_choice_control');
      if (!c.uuid(id) || id !== id.toLowerCase() || card.getAttribute('id') !== id + '-smrm-card' || id === userID
        || card.children.length !== 3 || card.children[0] !== header || card.children[1] !== body || card.children[2] !== footer
        || header.children.length !== 0 || c.normalize(header.textContent) !== 'Response ' + (index + 1)
        || content.parentElement !== body || footer.parentElement !== card || control.parentElement !== footer
        || footer.children.length !== 1 || content.children.length !== 1 || content.children[0] !== containers[index]
        || containers[index].getAttribute('id') !== 'chat-response-message-' + id
        || c.normalize(control.textContent) !== 'I prefer this response'
        || control.closest('form, a, [contenteditable="true"]')
        || c.nodes(control, 'a, button, input, select, textarea, [contenteditable="true"]', 1).length
        || ['form', 'formaction', 'popovertarget', 'commandfor', 'aria-controls', 'aria-expanded'].some(name => control.getAttribute(name) !== null)
        || ![null, 'button'].includes(control.getAttribute('type')) || typeof control.disabled !== 'boolean'
        || ![null, 'true', 'false'].includes(control.getAttribute('aria-disabled'))) reject();
      return { id, card, header, body, content, footer, control, response: containers[index] };
    });
    const allControls = c.nodes(node, '.smrm-card__prefer-btn', 3);
    if (allControls.length !== 2 || allControls.some((control, i) => control !== rows[i].control)
      || rows[0].id === rows[1].id || rows.some(row => row.control.disabled !== rows[0].control.disabled
      || row.control.getAttribute('aria-disabled') !== rows[0].control.getAttribute('aria-disabled'))) reject();
    // Public AY disables BOTH buttons until every message.done is true. Its
    // normal response footer is intentionally absent during the comparison.
    const ready = rows.every(row => !row.control.disabled && row.control.getAttribute('aria-disabled') !== 'true'
      && c.nodes(row.response, '.response-loading', 1).length === 0);
    return { wrapper, list, rows, ready, root: node,
      pins: [node, node.parentElement, wrapper, list, ...rows.flatMap(row => [row.card, row.header, row.body, row.content, row.footer, row.control, row.response])] };
  }
  function transcript(allowInitialResponseIdentity = false, emptyContainerPrompt = null, allowResponseChoice = false) {
    const users = c.nodes(document, '.qwen-chat-message.qwen-chat-message-user', 2);
    const answers = c.nodes(document, '.qwen-chat-message.qwen-chat-message-assistant', 2);
    if (users.length > 1 || answers.length > 1 || answers.length > users.length) rejectUserCount('transcript', users, answers);
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
      const containers = c.nodes(node, '.chat-response-message'), displayed = containers.filter(c.visible);
      const ordered = () => c.visible(node) && answerTurn?.classList.contains('qwen-chat-message-select-turn-message')
        && answerTurn.parentElement === turn.parentElement
        && [...turn.parentElement.children].indexOf(answerTurn) > [...turn.parentElement.children].indexOf(turn);
      if (allowResponseChoice && c.nodes(node, '.smrm', 2).length) {
        let choice;
        try { choice = responseChoice(node, containers, displayed, ordered, id); }
        catch (error) {
          // Unknown/unsafe comparison shapes retain the existing closed
          // multiple-container refusal and its finite structural diagnostic.
          if (error?.computaAdapterFailure) rejectResponseContainer('response_container_multiple', node, containers, displayed, false);
          throw error;
        }
        return { users, answers, first: { root, container, body, id, text: body.textContent },
          answer: { root: node, content: choice.wrapper, id: null }, pendingAnswer: null, responseChoice: choice };
      }
      if (emptyContainerPrompt !== null && !containers.length) {
        // A physically empty, visible first assistant root is only a negative
        // observation. A hidden container, rendered preview, or nonempty shell
        // cannot enter this path. No output or ownership proof is available.
        const form = composer();
        if (!ordered() || node.childNodes.length !== 0 || body.textContent !== emptyContainerPrompt
          || !form.empty || !c.enabled(form.editor) || !form.stop) c.fail('document_changed', 'response_container_empty');
        pendingAnswer = { root: node, content: null, turn: answerTurn, outer: turn.parentElement, editor: form.editor, composerScope: form.scope };
      } else {
        if (emptyContainerPrompt !== null && containers.length !== 1 || allowInitialResponseIdentity && displayed.length !== 1)
          rejectResponseContainer(!containers.length ? 'response_container_empty'
            : containers.length > 1 ? 'response_container_multiple' : 'response_container_hidden',
            node, containers, displayed, emptyContainerPrompt !== null);
        const content = ordinaryResponseContainer(node, containers, displayed);
        const answerID = content.getAttribute('id')?.replace(/^chat-response-message-/, '');
        if (!ordered() || (!c.uuid(answerID) && !(allowInitialResponseIdentity && answerID === ''))
          || content.getAttribute('id') !== 'chat-response-message-' + answerID || answerID === id)
          c.fail('conversation_changed', 'response_scope');
        if (answerID === '') {
          // The observed first response mounts this exact prefix before its UUID.
          const form = composer();
          if (!form.empty || !c.enabled(form.editor) || !form.stop
            || c.nodes(content, '.response-loading', 2).length !== 1
            || c.nodes(content, '.response-message-content.phase-answer', 1).length
            || c.nodes(content, '.response-message-footer-actions', 1).length)
            c.fail('conversation_changed', 'response_scope');
          pendingAnswer = { root: node, content, turn: answerTurn, outer: turn.parentElement };
        } else answer = { root: node, content, id: answerID };
      }
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

  // Describe only elements returned by this failed hit test. Never probe again.
  function displayCover(nodes, probe, clip, scope, user, answer) {
    const common = values => values.every(v => v === values[0]) ? values[0] : 'mixed';
    const anchor = hit => {
      for (let node = hit, depth = 0; node && depth < 24; node = node.parentElement, depth++) {
        const position = getComputedStyle(node).position;
        if (position === 'fixed' || position === 'sticky') return position;
        if (node === document.documentElement) return 'none';
      }
      return 'unknown';
    };
    return {probe, clip, hits:nodes.length === 1 ? 'one' : 'several',
      scope:common(nodes.map(hit => scope.contains(hit) ? 'composer' : user.contains(hit) ? 'user'
        : answer.contains(hit) ? 'answer' : 'elsewhere')), anchor:common(nodes.map(anchor))};
  }
  // A clipped display button can have a covered center and an exposed edge.
  // Find one actual pointer target, then require the same viewport point on the
  // same pinned button after the caller revalidates the transcript and choice.
  function displayHitFailure(control, point, classifyOcclusion = false, blockers = null) {
    let blocker = null, clip = 'unmeasured';
    const misses = blockers || (classifyOcclusion ? [] : null);
    const probe = point.x === undefined ? 'grid' : 'witness';
    delete point.describeCover;
    const reason = c.hitFailure(control, (left, top, right, bottom) => {
      const ownsPoint = (x, y) => {
        const hit = document.elementFromPoint(x, y);
        if (hit === control) return true;
        const inside = control.contains(hit);
        if (inside && hit.closest('button, a, input, select, textarea, [role], [tabindex], [contenteditable]') === control) return true;
        if (classifyOcclusion) {
          const kind = !hit ? 'none' : inside ? 'descendant' : hit.contains(control) ? 'ancestor' : 'unrelated';
          if (kind === 'unrelated' && misses && !misses.includes(hit)) misses.push(hit);
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
      // The grid can miss a thin part of the button inside a clipping ancestor.
      // Ancestor bounds suggest one more point. Only WebKit's actual hit can select it.
      let x1 = left, y1 = top, x2 = right, y2 = bottom;
      const clips = value => ['hidden', 'clip', 'auto', 'scroll', 'overlay'].includes(value);
      let depth = 0;
      for (let node = control.parentElement; node; node = node.parentElement) {
        if (++depth > 64 || !node.isConnected) return false;
        const style = getComputedStyle(node);
        if (clips(style.overflowX) || clips(style.overflowY)) {
          const r = node.getBoundingClientRect();
          if (clips(style.overflowX)) { x1 = Math.max(x1, r.left); x2 = Math.min(x2, r.left + r.width); }
          if (clips(style.overflowY)) { y1 = Math.max(y1, r.top); y2 = Math.min(y2, r.top + r.height); }
        }
      }
      if ([x1, y1, x2, y2].every(Number.isFinite)) {
        clip = x2 <= x1 || y2 <= y1 ? 'empty' : x1 !== left || x2 !== right || y1 !== top || y2 !== bottom ? 'reduced' : 'unchanged';
      }
      if (x2 > x1 && y2 > y1 && (x1 !== left || x2 !== right || y1 !== top || y2 !== bottom)) {
        const x = (x1 + x2) / 2, y = (y1 + y2) / 2;
        if (ownsPoint(x, y)) { point.x = x; point.y = y; return true; }
      }
      return false;
    });
    if (reason === 'occluded' && blocker === 'unrelated' && misses?.length)
      point.describeCover = (scope, user, answer) => displayCover(misses, probe, clip, scope, user, answer);
    return reason === 'occluded' && blocker ? 'occluded_' + blocker : reason;
  }
  // Observe only the direct children of the pinned transcript. A current
  // sibling match alone cannot prove that an old assistant turn was replaced.
  function watchAssistantTurnReplacement(outer, userTurn, oldTurn) {
    if (!outer?.isConnected || userTurn?.parentElement !== outer || oldTurn?.parentElement !== outer
      || oldTurn.previousElementSibling !== userTurn || typeof MutationObserver !== 'function') return null;
    const before = oldTurn.previousSibling, after = oldTurn.nextSibling;
    const ancestors = new Map();
    for (let node = outer; node.parentNode; node = node.parentNode) {
      if (ancestors.size === 32) return null;
      ancestors.set(node.parentNode, node);
    }
    if (!ancestors.has(document)) return null;
    let records = [], observer, closed = false;
    const close = () => { closed = true; observer?.disconnect(); records = []; };
    const collect = batch => {
      if (closed) return;
      if (batch.length > 64) { close(); return; }
      const direct = [];
      for (const record of batch) {
        if (record.target === outer) {
          if (record.type !== 'childList' || direct.length === 2
            || record.addedNodes.length > 1 || record.removedNodes.length > 1
            || record.previousSibling !== before || record.nextSibling !== after) { close(); return; }
          direct.push(record);
        } else {
          const anchor = ancestors.get(record.target);
          // A moved ancestor or any change inside the pinned user turn ends
          // this witness, even if the page later restores the same nodes.
          if (!anchor || record.type !== 'childList'
            || record.addedNodes.length > 64 || record.removedNodes.length > 64
            || Array.prototype.includes.call(record.addedNodes, anchor)
            || Array.prototype.includes.call(record.removedNodes, anchor)) { close(); return; }
        }
      }
      if (!direct.length) return;
      // A split remove/insert must arrive in a single observer delivery.
      if (records.length) { close(); return; }
      records = direct;
    };
    try {
      observer = new MutationObserver(collect);
      observer.observe(outer, { childList: true });
      observer.observe(userTurn, { childList: true, characterData: true, subtree: true });
      for (const ancestor of ancestors.keys()) observer.observe(ancestor, { childList: true });
    }
    catch { close(); return null; }
    return {
      close,
      consume(currentTurn) {
        if (!closed) collect(observer.takeRecords());
        const [first, second] = records;
        const removed = first?.removedNodes.length === 1 && first.removedNodes[0] === oldTurn;
        const inserted = record => record.addedNodes.length === 1 && record.addedNodes[0] === currentTurn;
        const replaced = !closed && removed && (records.length === 1 && inserted(first)
          || records.length === 2 && first.addedNodes.length === 0 && second.removedNodes.length === 0 && inserted(second));
        close();
        return replaced && oldTurn.isConnected === false && oldTurn.parentElement === null
          && currentTurn.isConnected && currentTurn.parentElement === outer && userTurn.parentElement === outer
          && currentTurn.previousElementSibling === userTurn
          && currentTurn.previousSibling === before && currentTurn.nextSibling === after;
      }
    };
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

  // Negative-only provider quota observation. No body expansion, output,
  // response identity, sampling grant, or deletion authority is published.
  function modelQuotaTV({ prompt, prepared, first, identity, display }) {
    try {
      const current = route();
      if (current.kind !== 'canonical' || typeof prompt !== 'string' || !prepared
        || identity && identity.canonical !== current.canonical) return null;
      const form = composer();
      if (form.scope !== prepared.scope || form.editor !== prepared.editor || !form.empty || !c.enabled(form.editor)) return null;
      const users = c.nodes(document, '.qwen-chat-message.qwen-chat-message-user', 2);
      const answers = c.nodes(document, '.qwen-chat-message.qwen-chat-message-assistant', 2);
      if (users.length !== 1 || answers.length !== 1) return null;
      const user = users[0], userTurn = user.parentElement, answer = answers[0], answerTurn = answer.parentElement;
      if (!c.visible(user) || !c.visible(answer) || !userTurn?.classList.contains('qwen-chat-message-select-turn-message')
        || !answerTurn?.classList.contains('qwen-chat-message-select-turn-message')
        || !userTurn.parentElement?.classList.contains('qwen-chat-message-select-turn')
        || answerTurn.parentElement !== userTurn.parentElement
        || [...userTurn.parentElement.children].indexOf(answerTurn) <= [...userTurn.parentElement.children].indexOf(userTurn)) return null;
      const containers = c.nodes(user, '.chat-user-message-container', 2);
      if (containers.length !== 1) return null;
      const container = containers[0], bodies = c.nodes(container, '.chunked-text-renderer-root > p.user-message-content', 2);
      if (bodies.length !== 1) return null;
      const body = bodies[0], userID = container.getAttribute('data-msg-id');
      // An unseen collapsed prefix is not an owned full body. Exact retained
      // pointers are additional negative fences, never replacement proof.
      if (!c.visible(container) || !c.visible(body) || body.children.length !== 0 || body.textContent !== prompt
        || !c.uuid(userID) || container.getAttribute('data-chat-id') !== current.id) return null;
      for (const held of [first, identity?.first]) if (held && (held.root !== user || held.container !== container
        || held.body !== body || held.id !== userID || held.text !== prompt)) return null;
      const hosts = c.nodes(answer, '.chat-response-message', 2);
      if (hosts.length !== 1 || c.nodes(answer, '.smrm, .cmrm', 1).length) return null;
      const host = hosts[0], hostID = host.getAttribute('id'), prefix = 'chat-response-message-';
      if (!c.visible(host) || host.closest('.qwen-chat-message') !== answer || typeof hostID !== 'string'
        || !hostID.startsWith(prefix) || hostID !== prefix && !c.uuid(hostID.slice(prefix.length))) return null;
      if (identity?.answer && (identity.answer.root !== answer || identity.answer.content !== host
        || identity.answer.turn !== answerTurn)) return null;
      if (display && !first) {
        const view = firstBodyPresentation({users,answers,first:{root:user,container,body,id:userID,text:body.textContent},
          answer:{root:answer,content:host,id:hostID.slice(prefix.length) || null}});
        if (!view || display.canonical !== current.canonical || view.pins.length !== display.pins.length
          || view.pins.some((node,index) => node !== display.pins[index])) return null;
      }
      const rights = c.nodes(host, '.chat-response-message-right', 2);
      if (rights.length !== 1 || rights[0].parentElement !== host || !c.visible(rights[0])) return null;
      const right = rights[0], cards = c.nodes(right, 'section.exceed-limit-error-card', 2);
      if (cards.length !== 1) return null;
      const card = cards[0], reason = card.getAttribute('data-paywall-reason'), messageID = card.getAttribute('data-msg-id');
      if (card.parentElement !== right || !c.visible(card) || card.getAttribute('class') !== 'exceed-limit-error-card'
        || card.getAttribute('data-testid') !== 'exceed-limit-error-card'
        || card.getAttribute('data-aes-exp') !== 'expExceedLimitCard'
        || !['ExceedLimit', 'quota_exhausted', 'update_member'].includes(reason) || card.getAttribute('data-paywall-scene') !== 't2t'
        || card.getAttribute('data-chat-id') !== current.id || !c.uuid(messageID) || messageID === userID
        || hostID !== prefix && messageID !== hostID.slice(prefix.length)) return null;
      // A previously pinned UUID cannot disappear or change merely because a
      // restriction card was added. A fid never adopts positive reply identity.
      for (const heldID of [identity?.answerID, display?.answerID]) {
        if (heldID !== undefined && heldID !== null && heldID !== ''
          && (!c.uuid(heldID) || hostID === prefix || heldID !== hostID.slice(prefix.length) || heldID !== messageID)) return null;
      }
      // update_member is a provider UI flag, not an observed backend code.
      // The exact model-specific daily notice below is mandatory for all reasons.
      const paragraphs = c.nodes(card, 'p', 2);
      if (paragraphs.length !== 1 || paragraphs[0].parentElement !== card || paragraphs[0].children.length !== 0
        || !c.visible(paragraphs[0]) || c.normalize(paragraphs[0].textContent) !==
          "You've reached today's Qwen3.8-Max limit. Upgrade your membership or switch to another model above to continue.") return null;
      if ([...card.children].some(node => node !== paragraphs[0]
        && !(node.tagName === 'DIV' && node.getAttribute('class') === 'exceed-limit-error-card-actions'))) return null;
      return { version: 1, kind: 'qwen_model_quota_v1', surface: 'tv_card', reason, scene: 't2t',
        choice: { key: 'Qwen3.8-Max', label: 'Qwen3.8-Max' } };
    } catch { return null; } // A nonmatch preserves the original guarded path.
  }
  // Optional diagnostics on an already-read physical reply. No text/ID/attribute
  // values leave this helper; these facts never participate in admission.
  function replyProgressUI(t, form = null, terminal = null, maxNotice = false) {
    const ui = { version:1, scope:'none', stop:form && Object.hasOwn(form,'stop') ? !!form.stop : null,
      loading:null, footer:null, tv:null, alert:null, reason:null, daily:null,
      terminal:null, capped:false, visibility:'unknown', hidden:null };
    try { const value=document.visibilityState; if (['visible','hidden','prerender'].includes(value)) ui.visibility=value; } catch { }
    try { const value=document.hidden; if (typeof value === 'boolean') ui.hidden=value; } catch { }
    try {
      if (!t || !Array.isArray(t.answers)) return null;
      if (t.responseChoice) { ui.scope='comparison'; return ui; }
      const answer=t.pendingAnswer || t.answer;
      if (!answer) return t.answers.length === 0 ? ui : null;
      if (t.answers.length !== 1 || answer.root !== t.answers[0] || !c.visible(answer.root)) return null;
      const host=answer.content;
      if (!host) { ui.scope='empty_root'; return ui; }
      if (!host.isConnected || !c.visible(host) || !host.classList.contains('chat-response-message')
        || host.closest('.qwen-chat-message') !== answer.root) return null;
      ui.scope='single';ui.terminal=typeof terminal === 'boolean' ? terminal : null;
      const outsideAuthored=node => !node.closest('.response-message-content, .custom-qwen-markdown, .qwen-markdown');
      const count=nodes => Math.min(3,nodes.length); // 3 is saturated: at least three.
      ui.loading=count(c.nodes(host,'.response-loading').filter(node => c.visible(node) && outsideAuthored(node)));
      ui.footer=count(c.nodes(host,'.response-message-footer-actions').filter(node => c.visible(node) && outsideAuthored(node)));
      const rights=c.nodes(host,'.chat-response-message-right',2);
      if (rights.length === 1 && rights[0].parentElement === host && c.visible(rights[0])) {
        const right=rights[0];
        const cards=c.nodes(right,'section.exceed-limit-error-card').filter(node => node.parentElement === right && c.visible(node));
        const alerts=c.nodes(right,'div.qwen-messsage-status.qwen-alert').filter(node => node.parentElement === right && c.visible(node));
        ui.tv=count(cards);ui.alert=count(alerts);
        ui.reason=cards.length === 0 ? 'none' : cards.length !== 1 ? 'ambiguous' : 'other';
        if (cards.length === 1) {
          const card=cards[0],reason=card.getAttribute('data-paywall-reason');
          if (['ExceedLimit','quota_exhausted','update_member'].includes(reason)) ui.reason=reason;
          // This reports only the observed UI notice, never an HTTP/backend
          // quota code or a replacement for the strict classification path.
          if (maxNotice && card.getAttribute('class') === 'exceed-limit-error-card'
            && card.getAttribute('data-testid') === 'exceed-limit-error-card'
            && card.getAttribute('data-aes-exp') === 'expExceedLimitCard'
            && card.getAttribute('data-paywall-scene') === 't2t'
            && card.getAttribute('data-chat-id') === route().id) {
            const paragraphs=c.nodes(card,'p',2);
            if (paragraphs.length === 1 && paragraphs[0].parentElement === card
              && paragraphs[0].children.length === 0 && c.visible(paragraphs[0]))
              ui.daily=c.normalize(paragraphs[0].textContent) === "You've reached today's Qwen3.8-Max limit. Upgrade your membership or switch to another model above to continue.";
          }
        }
      }
      ui.capped=[ui.loading,ui.footer,ui.tv,ui.alert].some(value => value === 3);
      return ui;
    } catch { return null; } // Diagnostic failure preserves the original read/result.
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
    // Capture the first ordinary rejection without another DOM read. Only the
    // owned terminal inspect can request this finite diagnostic.
    const unsupported = (stage, reason, count = 0) => {
      const result = { text: '', finalMarkup: false, formatIssue: true };
      Object.defineProperty(result, 'failureStructure', { value: () => {
        const packet = { version: 1, provider: 'qwen', trigger: 'authored_source', stage,
          reason: typeof reason === 'function' ? reason() : reason, count: Math.min(count, 2) };
        if (stage === 'phase_set') {
          try { packet.phaseSet = phaseSetStructure(); } catch { /* Keep the original finite refusal. */ }
        }
        return packet;
      } });
      return result;
    };
    if (flows.length !== 1) return unsupported('flow', 'count', flows.length);
    if (!c.visible(flows[0])) return unsupported('flow', 'hidden');
    const flow = flows[0], phases = c.nodes(flow, '.response-message-content.phase-answer');
    // Failure-only samples of the already matched phases. These counts neither
    // select a phase nor reconstruct a response; text values are never read.
    const phaseSetStructure = () => {
      const sampled = Math.min(phases.length, 16), facts = {
        matched: Math.min(phases.length, 33), matchedOverflow: phases.length > 33, sampled,
        visible: 0, textBearing: 0, textBearingVisiblePhase: 0, textEmpty: 0, textUnknown: 0, physicallyEmpty: 0,
        singleWrapper: 0, direct: 0, otherWrapper: 0
      };
      let budget = 256;
      for (let index = 0; index < sampled; index++) {
        const phase = phases[index], parent = phase.parentElement, phaseVisible = c.visible(phase);
        if (phaseVisible) facts.visible++;
        if (parent === flow) facts.direct++;
        else if (parent?.tagName === 'DIV' && parent.parentElement === flow
          && parent.childNodes.length === 1 && parent.attributes.length === 0) facts.singleWrapper++;
        else facts.otherWrapper++;
        if (phase.childNodes.length === 0) { facts.physicallyEmpty++; facts.textEmpty++; continue; }
        const stack = [phase];
        let bearing = false, limited = false;
        while (stack.length) {
          if (budget === 0) { limited = true; break; }
          budget--;
          const node = stack.pop();
          if (node.nodeType === 3) { if (node.length > 0) { bearing = true; break; } continue; }
          const children = node.childNodes;
          if (children.length > 32) { limited = true; break; }
          for (let child = children.length - 1; child >= 0; child--) stack.push(children[child]);
        }
        if (bearing) { facts.textBearing++; if (phaseVisible) facts.textBearingVisiblePhase++; }
        else if (limited) facts.textUnknown++;
        else facts.textEmpty++;
      }
      return facts;
    };
    if (!phases.length) return { text: '', finalMarkup: false, formatIssue: false };
    if (phases.length !== 1) return unsupported('phase_set', () => {
      if (phases.length > 3) return 'phase_count_limit';
      // Count only structurally empty branches and physically visible,
      // text-bearing leaves. Never inspect the value of a text node.
      const wrapper = phase => phase.parentElement;
      if (!phases.every(p => wrapper(p)?.tagName === 'DIV' && wrapper(p).parentElement === flow
        && wrapper(p).childNodes.length === 1 && wrapper(p).attributes.length === 0)
        || new Set(phases.map(wrapper)).size !== phases.length) return 'other_content';
      const invisible = node => {
        const style = getComputedStyle(node);
        return node.closest('[hidden], [inert], [aria-hidden="true"]') || style.display === 'none'
          || style.visibility !== 'visible' || style.opacity === '0';
      };
      if (phases.some(p => invisible(wrapper(p)))) return 'hidden';
      const tags = ['DIV','DIV','DIV','DIV','SPAN','SPAN'];
      const classes = [['response-message-content t2t phase-answer'], ['custom-qwen-markdown'],
        ['qwen-markdown','qwen-markdown qwen-markdown-loose'], ['qwen-markdown-paragraph'],
        ['qwen-markdown-text'], ['qwen-markdown-text-node']];
      let branches = 0, budget = 96;
      for (const p of phases) {
        let hasText = false;
        const stack = [[p, 0]];
        while (stack.length) {
          const [node, depth] = stack.pop();
          if (--budget < 0) return 'node_visit_limit';
          if (node.childNodes.length > 32) return 'child_count_limit';
          if (invisible(node)) return 'hidden';
          if (['IMG','PICTURE','VIDEO','AUDIO','IFRAME','OBJECT','CANVAS'].includes(node.tagName)
            || node.tagName === 'A' && node.getAttribute('download') !== null) return 'media';
          const cls = node.getAttribute('class');
          if (node.tagName !== tags[depth] || !classes[depth]?.includes(cls)
            || node.attributes.length > (depth === 3 ? 2 : 1)
            || node.attributes.length === 2 && node.getAttribute('dir') !== 'ltr') return 'other_content';
          if ((depth < 3 || depth === 4) && node.children.length > 1) return 'other_content';
          for (const child of node.childNodes) {
            if (child.nodeType === 3 && depth === 5) {
              if (child.length) {
                if (!c.visible(node)) return 'hidden';
                hasText = true;
              }
            } else if (child.nodeType === 1 && depth < 5) stack.push([child, depth + 1]);
            else return 'other_content';
          }
        }
        if (hasText) branches++;
      }
      return branches >= 2 ? 'multiple_text_bearing' : branches === 1 ? 'one_text_others_empty' : 'all_empty';
    }, phases.length);
    if (!phases[0].classList.contains('t2t')) return unsupported('phase', 'class');
    const phase = phases[0];
    // The site renders escapes as sibling tokens and removes their leading
    // backslash. Only the three punctuation escapes allowed in JSON have a
    // unique inverse here. Never infer a missing escape from malformed JSON.
    const inlineKind = node => {
      const cls = node.getAttribute('class');
      switch (node.tagName) {
      case 'SPAN':
        if (cls === 'qwen-markdown-escape') return 'escape';
        if (cls === 'qwen-markdown-bidi-ltr') return 'bidi';
        break;
      case 'STRONG': if (cls === 'qwen-markdown-strong') return 'decorated'; break;
      case 'EM': if (cls === 'qwen-markdown-em') return 'decorated'; break;
      case 'DEL': if (cls === 'qwen-markdown-del') return 'decorated'; break;
      case 'CODE': if (cls === 'qwen-markdown-codespan') return 'decorated'; break;
      case 'A': if (cls === 'qwen-markdown-link') return 'decorated'; break;
      }
      return 'other';
    };
    // Describe only a fixed prefix on a hard-limit refusal. This observer
    // runs only when the already rejected, owned failure packet is requested.
    const prefixKind = runs => {
      for (let i = 0; i < Math.min(runs.length, 64); i++) {
        const run = runs[i];
        if (run.tagName !== 'SPAN' || run.getAttribute('class') !== 'qwen-markdown-text') return inlineKind(run);
        for (let j = 0; j < Math.min(run.children.length, 4); j++) {
          const leaf = run.children[j];
          if (leaf.tagName !== 'SPAN' || leaf.getAttribute('class') !== 'qwen-markdown-text-node') return inlineKind(leaf);
        }
        if (run.children.length !== 1) return 'other';
      }
      return 'ordinary_prefix';
    };
    const childCountIssue = (node, stage) => {
      const count = node.children.length;
      if (stage === 'literal' && count > 1 && count <= 64) {
        const atypical = [...node.children].find(el => el.tagName !== 'SPAN' || el.getAttribute('class') !== 'qwen-markdown-text-node');
        if (atypical) return unsupported('inline', inlineKind(atypical));
      }
      return unsupported(stage, 'count', count);
    };
    let projected = null;
    function checkSplitParagraph(paragraph) {
      const count = paragraph.children.length;
      if (count > 256) return unsupported('span_limit', () => prefixKind(paragraph.children), count);
      // Restrict this additional shape to the known passive markdown ancestry.
      if (paragraph.getAttribute('class') !== 'qwen-markdown-paragraph') return unsupported('span', 'class');
      for (let ancestor = paragraph; ancestor !== phase.parentElement; ancestor = ancestor.parentElement) {
        if ([...ancestor.attributes].some(attr => attr.name !== 'class'
          && !(ancestor === paragraph && attr.name === 'dir' && attr.value === 'ltr'))) return unsupported('outside', 'scope');
      }
      const layoutOnly = node => node.nodeType === 1 || node.nodeType === 3 && /^\s*$/.test(node.textContent);
      const plain = (node, cls, stage) => {
        if (node.tagName !== 'SPAN' || node.getAttribute('class') !== cls) return unsupported('inline', inlineKind(node));
        if (!c.visible(node)) return unsupported(stage, 'hidden');
        if (node.attributes.length !== 1) return unsupported('outside', 'scope');
      };
      if (paragraph.childNodes.length > 2 * count + 1) return unsupported('outside', 'node_limit');
      if (![...paragraph.childNodes].every(layoutOnly)) return unsupported('span', 'mixed_text');
      const escapes = new Set();
      for (const run of paragraph.children) {
        if (run.tagName === 'SPAN' && run.getAttribute('class') === 'qwen-markdown-escape') {
          if (run.attributes.length !== 2 || run.getAttribute('dir') !== 'ltr' || !c.visible(run)
            || run.childNodes.length !== 1 || run.childNodes[0].nodeType !== 3
            || run.childNodes[0].length !== 1 || !['"', '\\', '/'].includes(run.childNodes[0].textContent)) return unsupported('inline', 'escape');
          escapes.add(run);
          continue;
        }
        const runIssue = plain(run, 'qwen-markdown-text', 'span');
        if (runIssue) return runIssue;
        if (run.children.length !== 1) return childCountIssue(run, 'literal');
        if (run.childNodes.length > 3) return unsupported('outside', 'node_limit');
        if (![...run.childNodes].every(layoutOnly)) return unsupported('literal', 'mixed_text');
        const leaf = run.children[0], leafIssue = plain(leaf, 'qwen-markdown-text-node', 'literal');
        if (leafIssue) return leafIssue;
        if (leaf.children.length) return unsupported('literal_contents', 'count', leaf.children.length);
        if (count > 64 && leaf.childNodes.length !== 1) return unsupported('inline', 'other');
        if (leaf.childNodes.length > 64) return unsupported('outside', 'node_limit');
        if (![...leaf.childNodes].every(node => node.nodeType === 3)) return unsupported('outside', 'scope');
      }
      if (!escapes.size && count <= 64) return;
      const markdown = paragraph.parentElement, custom = markdown.parentElement;
      if (custom.getAttribute('class') !== 'custom-qwen-markdown'
        || !['qwen-markdown', 'qwen-markdown qwen-markdown-loose'].includes(markdown.getAttribute('class'))
        || !['phase-answer', 'response-message-content', 't2t'].every(cls => phase.classList.contains(cls))
        || [...phase.classList].length !== 3 || paragraph.getAttribute('dir') !== 'ltr'
        || paragraph.childNodes.length !== count) return unsupported('inline', 'escape');
      const positions = [];
      let source = '';
      for (const run of paragraph.children) {
        const escaped = escapes.has(run), leaf = escaped ? run : run.children[0];
        if (run.childNodes.length !== 1 || leaf.childNodes.length !== 1 || leaf.childNodes[0].nodeType !== 3)
          return unsupported('inline', 'other');
        const value = leaf.childNodes[0];
        if (!value.length) return unsupported('inline', 'other');
        if (source.length + (escaped ? 1 : 0) + value.length > 220_000) c.fail('response_too_large');
        if (escaped) {
          positions.push(source.length);
          source += '\\';
        }
        source += value.textContent;
      }
      projected = { source, positions };
    }
    // The public renderer's header Copy closes over token.text in either presentation.
    // This is metadata only; no viewport text or payload is read here.
    let codeDeclineReason = 'custom_shape';
    const codeDecline = reason => { codeDeclineReason = reason; return null; };
    function codePayloadCandidate(pre, markdown) {
      const html = 'http://www.w3.org/1999/xhtml';
      const attrs = (node, names) => node.attributes.length <= names.length
        && [...node.attributes].every(attr => names.includes(attr.name) && !attr.namespaceURI
          && (attr.name !== 'style' || attr.value.length <= 4096));
      const classes = (node, expected) => {
        const raw = node?.getAttribute?.('class');
        if (typeof raw !== 'string' || raw.length > 512) return false;
        const tokens = raw.split(/[ \t\n\r\f]+/).filter(Boolean), wanted = expected.split(' ');
        return tokens.length === wanted.length && new Set(tokens).size === tokens.length
          && tokens.every(token => wanted.includes(token));
      };
      const shown = (node, physical = true) => {
        if (node.namespaceURI !== html || !node.isConnected
          || node.closest('[hidden], [inert], [aria-hidden="true"]')
          || physical && node.getClientRects().length === 0) return false;
        const s = getComputedStyle(node), opacity = Number(s.opacity);
        return s.display !== 'none' && s.visibility === 'visible' && Number.isFinite(opacity)
          && opacity > 0 && s.contentVisibility !== 'hidden';
      };
      const plain = node => {
        if (!shown(node)) return false;
        // Copy supplies token bytes, independent of paint transforms or clipping.
        // Source-local pseudo content still violates the single-payload boundary.
        return ['::before', '::after'].every(pseudo => {
          const content = getComputedStyle(node, pseudo).content;
          return content === 'none' || content === 'normal' || content === '""';
        });
      };
      const exact = (node, tag, cls, names = ['class']) => node?.tagName === tag
        && classes(node, cls) && attrs(node, names) && plain(node);
      const custom = markdown.parentElement;
      if (!exact(custom, 'DIV', 'custom-qwen-markdown') || custom.childNodes.length !== 1)
        return codeDecline('custom_shape');
      if (!['qwen-markdown', 'qwen-markdown qwen-markdown-loose'].some(cls => classes(markdown, cls))
        || !attrs(markdown, ['class']) || !plain(markdown) || markdown.childNodes.length !== 1)
        return codeDecline('markdown_shape');
      if (phase.childNodes.length !== 1 || !attrs(phase, ['class']) || !plain(phase)
        || !classes(phase, 'response-message-content t2t phase-answer')) return codeDecline('phase_shape');
      if (!exact(pre, 'PRE', 'qwen-markdown-code', ['class', 'dir']) || pre.getAttribute('dir') !== 'ltr'
        || pre.childNodes.length !== 2) return codeDecline('pre_shape');
      const [headerWrap, body] = pre.childNodes;
      if (!['qwen-markdown-code-header-wrapper', 'qwen-markdown-code-header-wrapper qwen-markdown-code-header-wrapper-sticky'].some(cls => classes(headerWrap, cls))
        || headerWrap.tagName !== 'DIV' || !attrs(headerWrap, ['class', 'style']) || !plain(headerWrap)
        || headerWrap.childNodes.length !== 1) return codeDecline('header_wrapper');
      // Height/top and class serialization order do not bind Copy's token.text.
      // Bound style size while retaining the exact known structural token sets,
      // attribute names, enabled/hidden checks and the held official control.
      const header = headerWrap.childNodes[0];
      if (!exact(header, 'DIV', 'qwen-markdown-code-header', ['class', 'style'])
        || header.childNodes.length !== 2) return codeDecline('header_shape');
      const [language, actions] = header.childNodes;
      if (language.tagName !== 'DIV' || language.attributes.length || !plain(language)
        || language.childNodes.length !== 1 || language.childNodes[0].nodeType !== 3 || language.textContent !== 'json')
        return codeDecline('language');
      if (!exact(actions, 'DIV', 'qwen-markdown-code-header-actions') || actions.childNodes.length > 3)
        return codeDecline('actions_shape');
      if (!['qwen-markdown-code-body qwen-markdown-code-body-streaming json',
          'qwen-markdown-code-body json', 'qwen-markdown-code-body json qwen-markdown-code-body-virtual'].some(cls => classes(body, cls)))
        return codeDecline('body_classes');
      if (body.tagName !== 'DIV') return codeDecline('body_tag');
      if (!attrs(body, ['class', 'id', 'style'])) return codeDecline('body_attributes');
      if (!plain(body)) return codeDecline('body_visibility');
      if (!body.getAttribute('id') || body.getAttribute('id').length > 128) return codeDecline('body_id');
      const bodyChildren = body.childNodes.length;
      if (bodyChildren !== 1) return codeDecline(bodyChildren === 0 ? 'body_empty' : 'body_children');
      const presentation = body.childNodes[0];
      if (body.classList.contains('qwen-markdown-code-body-streaming')) {
        if (presentation.tagName !== 'CODE') return codeDecline('plain_code_tag');
        if (presentation.attributes.length) return codeDecline('plain_code_attributes');
        if (!plain(presentation)) return codeDecline('plain_code_visibility');
        if (presentation.childNodes.length !== 1 || presentation.childNodes[0].nodeType !== 3) return codeDecline('plain_code_shape');
      } else {
        if (presentation?.tagName !== 'DIV') return codeDecline('editor_tag');
        if (!classes(presentation, 'qwen-markdown-code-editor-viewport')) return codeDecline('editor_class');
        if (!attrs(presentation, ['class', 'style'])) return codeDecline('editor_attributes');
        if (!plain(presentation)) return codeDecline('editor_visibility');
      }
      // The known editor presentation is opaque provider output. Its viewport
      // is never a complete source; only the official code Copy supplies bytes.
      const rect = body.getBoundingClientRect();
      if (!Number.isFinite(rect.width) || !Number.isFinite(rect.height) || rect.width <= 0 || rect.height <= 0) return codeDecline('body_geometry');
      let decorationBudget = 64;
      const decoration = (node, depth, icon) => {
        if (--decorationBudget < 0 || depth > 8 || node.nodeType !== 1 || node.childNodes.length > 8
          || !['SPAN', 'svg', 'path', 'use', 'g'].includes(node.tagName)
          || ![html, 'http://www.w3.org/2000/svg'].includes(node.namespaceURI)
          || node.attributes.length > 16) return false;
        for (const attr of node.attributes) {
          if (attr.value.length > 4096) return false;
          if (attr.namespaceURI) {
            if (node.tagName !== 'use' || attr.namespaceURI !== 'http://www.w3.org/1999/xlink'
              || attr.localName !== 'href' || attr.name !== 'xlink:href'
              || !['#qwpcicon-' + icon, '#appicon-' + icon].includes(attr.value)) return false;
          } else if (!['class', 'role', 'aria-hidden', 'focusable', 'viewBox', 'width', 'height', 'fill', 'stroke', 'stroke-width',
            'stroke-linecap', 'stroke-linejoin', 'fill-rule', 'clip-rule', 'd', 'href'].includes(attr.name)
            || attr.name === 'href' && (node.tagName !== 'use' || !['#qwpcicon-' + icon, '#appicon-' + icon].includes(attr.value))
            || attr.name === 'role' && attr.value !== 'img') return false;
        }
        if (['::before', '::after'].some(pseudo => !['none', 'normal', '""'].includes(getComputedStyle(node, pseudo).content))) return false;
        return [...node.childNodes].every(child => decoration(child, depth + 1, icon));
      };
      const labels = new Set(); let control = null;
      for (const button of actions.childNodes) {
        const label = button.getAttribute?.('aria-label');
        if (button.tagName !== 'BUTTON' || !['Copy', 'Download', 'Collapse Code'].includes(label) || labels.has(label))
          return codeDecline('control_label');
        if (!attrs(button, ['class', 'type', 'aria-label', 'aria-expanded', 'aria-controls']) || !plain(button) || !c.enabled(button)
          || !['qwen-markdown-code-header-action-item', ...(label === 'Collapse Code' ? ['qwen-markdown-code-collapse-btn'] : [])]
            .some(cls => classes(button, 'qwen-chat-v2-btn qwen-chat-v2-btn-text qwen-chat-v2-btn-s qwen-chat-v2-btn-icon-only ' + cls))
          || button.getAttribute('type') !== null && button.getAttribute('type') !== 'button') return codeDecline('control_shape');
        if (button.childNodes.length > 4 || [...button.childNodes].some(child => !decoration(child, 0,
            label === 'Copy' ? 'copy' : label === 'Download' ? 'download' : 'up'))) return codeDecline('control_decoration');
        labels.add(label); if (label === 'Copy') control = button;
        if (label === 'Collapse Code' ? button.getAttribute('aria-expanded') !== 'true'
          || button.getAttribute('aria-controls') !== body.getAttribute('id')
          : button.getAttribute('aria-expanded') !== null || button.getAttribute('aria-controls') !== null) return codeDecline('collapse_state');
      }
      if (!control) return codeDecline('missing_copy');
      const nodes = [phase, custom, markdown, pre, headerWrap, header, language, actions, body, presentation, control];
      let ancestor = phase.parentElement, depth = 0, contentFound = false, last = null;
      while (ancestor) {
        if (++depth > 64 || !(contentFound ? shown(ancestor, false) : plain(ancestor)))
          return codeDecline(depth > 64 ? 'ancestor_limit' : 'ancestor_visibility');
        nodes.push(ancestor);
        if (ancestor === answer.content) contentFound = true;
        last = ancestor; ancestor = ancestor.parentElement;
      }
      if (!contentFound || last !== document.documentElement) return codeDecline('ancestor_root');
      return { nodes, control, root:answer.root, content:answer.content, responseID:answer.id };
    }
    let literal = phase, splitParagraph = null, codePayload = null;
    for (const [stage, tag, cls] of [
      ['custom', 'DIV', 'custom-qwen-markdown'], ['markdown', 'DIV', 'qwen-markdown'],
      ['paragraph', 'DIV', 'qwen-markdown-paragraph'], ['span', 'SPAN', 'qwen-markdown-text'],
      ['literal', 'SPAN', 'qwen-markdown-text-node']
    ]) {
      if (!c.visible(literal)) return unsupported(stage, 'parent_hidden');
      const count = literal.children.length;
      if (stage === 'span' && count > 1) {
        const issue = checkSplitParagraph(literal);
        if (issue) return issue;
        splitParagraph = literal;
        break;
      }
      if (count !== 1) return childCountIssue(literal, stage);
      if ([...literal.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || '')))
        return unsupported(stage, 'mixed_text');
      literal = literal.children[0];
      if (stage === 'paragraph' && literal.tagName === 'PRE') {
        codePayload = codePayloadCandidate(literal, literal.parentElement);
        if (!codePayload) return unsupported('code_candidate', codeDeclineReason);
        break;
      }
      if (literal.tagName !== tag) return unsupported(stage, 'tag');
      if (!literal.classList.contains(cls)) return unsupported(stage, 'class');
      if (!c.visible(literal)) return unsupported(stage, 'hidden');
    }
    const literalChildren = literal.children.length;
    if (!codePayload && !splitParagraph && literalChildren !== 0) return unsupported('literal_contents', 'count', literalChildren);
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
    if (!onlyAuthoredSource(flow)) return unsupported('outside', budget < 0 ? 'node_limit' : 'scope');
    if (codePayload) return { text:'', finalMarkup:false, formatIssue:false, codePayload };
    const text = projected?.source ?? (splitParagraph || literal).textContent;
    if (typeof text !== 'string' || new TextEncoder().encode(text).length > 220_000) c.fail('response_too_large');
    if (projected) {
      // Every such punctuation pair must correspond to exactly one escape token.
      // Return the original spelling and leave the protocol/schema decision to the codec.
      let index = 0;
      for (const match of text.matchAll(/\\["\\/]/g)) {
        if (projected.positions[index++] !== match.index) return unsupported('inline', 'escape_json');
      }
      if (index !== projected.positions.length) return unsupported('inline', 'escape_json');
      try {
        const envelope = JSON.parse(text);
        if (envelope === null || typeof envelope !== 'object' || Array.isArray(envelope)) return unsupported('inline', 'escape_json');
      } catch { return unsupported('inline', 'escape_json'); }
    }
    // The ordinary plain-text path still returns its whole source, even when
    // invalid JSON. The codec independently validates the unchanged bytes.
    return { text, finalMarkup: true, formatIssue: false };
  }
  function codePayloadFailure(reason) {
    try { c.fail('unsupported_response_format', 'authored_source'); }
    catch (error) {
      if (error?.computaAdapterFailure) error.adapterFailureStructure = {
        version:1, provider:'qwen', trigger:'authored_source', stage:'code_sample', reason, count:0
      };
      throw error;
    }
  }
  function codePayloadRoot(control) {
    const roots = document.querySelectorAll('[id="root"]'), root = roots.length === 1 ? roots[0] : null;
    return root && root.tagName === 'DIV' && root.namespaceURI === 'http://www.w3.org/1999/xhtml'
      && root.isConnected && root.parentElement === document.body && root.contains(control) ? root : null;
  }
  function rawDiagnosticFields(value, expected) {
    if (!value || typeof value !== 'object' || Object.getOwnPropertySymbols(value).length !== 0
      || Object.getOwnPropertyNames(value).sort().join(',') !== expected.slice().sort().join(',')) return null;
    const fields = {};
    for (const key of expected) {
      const property = Object.getOwnPropertyDescriptor(value,key);
      if (!property || !Object.prototype.hasOwnProperty.call(property,'value')) return null;
      fields[key] = property.value;
    }
    return fields;
  }
  function rawSourceDiagnostic(input) {
    const value = rawDiagnosticFields(input,['version','stage','kind','phaseCount','phaseOverflow','answersSeen']);
    const stages = ['request','target','root','conversation_nodes','host_props','element_tree',
      'element_tree_budget','element_tree_depth','element_tree_nodekind','element_tree_array','element_tree_elementshape','element_tree_kind','element_tree_props','element_tree_message','element_tree_editflags','element_tree_children','element_tree_message_set','element_tree_nodekind_string','element_tree_nodekind_number','element_tree_nodekind_bigint','element_tree_nodekind_symbol','element_tree_nodekind_function','element_tree_message_set_empty','element_tree_message_set_multiple',
      'message_keys','message_identity',
      'message_state','message_mode','message_legacy_content','message_empty_fields','message_extra','message_meta',
      'message_display','message_timestamp','feature_keys','feature_values','usage_shape','phase_list','phase_keys','phase_kind',
      'phase_state',
      'phase_role_read','phase_role_null','phase_role_value_user','phase_role_value_system','phase_role_value_developer','phase_role_value_tool','phase_role_value_function','phase_role_value_empty','phase_role_value_other_string','phase_role_type_undefined','phase_role_type_boolean','phase_role_type_number','phase_role_type_bigint','phase_role_type_symbol','phase_role_type_function','phase_role_type_object','phase_status_read','phase_status_null','phase_status_value_waiting_input','phase_status_value_error','phase_status_value_pause','phase_status_value_empty','phase_status_value_other_string','phase_status_type_undefined','phase_status_type_boolean','phase_status_type_number','phase_status_type_bigint','phase_status_type_symbol','phase_status_type_function','phase_status_type_object',
      'phase_extra','phase_tools','phase_scalar','answer_count','answer_role','answer_value','renderer_input','utf8','source_stability'];
    if (!value || Object.keys(value).sort().join(',') !== 'answersSeen,kind,phaseCount,phaseOverflow,stage,version'
      || value.version !== 1 || !stages.includes(value.stage) || !['guard','exception'].includes(value.kind)) return null;
    const n = value.phaseCount, overflow = value.phaseOverflow, seen = value.answersSeen;
    if (value.stage.startsWith('element_tree_') && n !== null) return null;
    if ((value.stage.startsWith('phase_role_') || value.stage.startsWith('phase_status_'))
      && (n === null || n === 0 || n === 33 || overflow !== false || seen === null)) return null;
    if (n === null) { if (overflow !== null || seen !== null) return null; }
    else if (!Number.isInteger(n) || n < 0 || n > 33 || typeof overflow !== 'boolean' || overflow !== (n === 33)
      || seen !== null && (!Number.isInteger(seen) || seen < 0 || seen > Math.min(n,2))) return null;
    return {version:1,stage:value.stage,kind:value.kind,phaseCount:n,phaseOverflow:overflow,answersSeen:seen};
  }
  function authoredSourceCandidate(answer, channel, parentID, failedDiagnostic) {
    if (!answer || !channel || Object.keys(channel).sort().join(',') !== 'dispatch,result,secret'
      || ![channel.dispatch,channel.result,channel.secret,parentID,answer.id].every(c.uuid)
      || route().kind !== 'canonical' || !codePayloadRoot(answer.root)) return null;
    let count = 0, source = null, failed = null;
    const listener = event => {
      if (event.target !== answer.content || event.detail?.kind !== 'raw_answer_v1' || event.detail?.op !== 'candidate') return;
      count++;
      const value = event.detail;
      if (Object.keys(value).sort().join(',') === 'candidate,eligible,kind,op,responseID'
        && value.eligible === true && c.uuid(value.candidate) && value.responseID === answer.id) source = value.candidate;
      else {
        // Failed-source metadata can never be returned as a truthy candidate.
        try {
          const rejected = rawDiagnosticFields(value,['candidate','diagnostic','eligible','kind','op','responseID']);
          if (rejected && rejected.kind === 'raw_answer_v1' && rejected.op === 'candidate'
            && rejected.eligible === false && rejected.candidate === null && rejected.responseID === answer.id)
            failed = rawSourceDiagnostic(rejected.diagnostic);
        } catch { /* Diagnostics cannot change the original refusal. */ }
      }
    };
    document.addEventListener(channel.result,listener,true);
    try {
      answer.content.dispatchEvent(new CustomEvent(channel.dispatch,{bubbles:true,detail:{kind:'raw_answer_v1',op:'candidate',
        secret:channel.secret,chatID:route().id,parentID,responseID:answer.id}}));
    } finally { document.removeEventListener(channel.result,listener,true); }
    if (count !== 1 || source === null) {
      if (count === 1 && source === null && failed && typeof failedDiagnostic === 'function') {
        try { failedDiagnostic(failed); } catch { /* Preserve null eligibility. */ }
      }
      return null;
    }
    const nodes = [answer.root,answer.content]; let parent = answer.root.parentElement;
    while (parent && nodes.length < 32) { nodes.push(parent); parent = parent.parentElement; }
    if (parent || nodes[nodes.length-1] !== document.documentElement) return null;
    return {kind:'raw_answer_v1',rawCandidate:source,parentID,nodes,control:answer.content,
      root:answer.root,content:answer.content,responseID:answer.id};
  }
  function sampleAuthoredSource(candidate, channel, grant, recheck) {
    const fail = codePayloadFailure, appRoot = codePayloadRoot(candidate.control);
    if (!channel || Object.keys(channel).sort().join(',') !== 'dispatch,result,secret'
      || ![channel.dispatch,channel.result,channel.secret,grant,candidate.rawCandidate].every(c.uuid)) fail('channel_shape');
    if (!appRoot) fail('root_boundary');
    let count = 0, captured = null, changed = false;
    const observer = new MutationObserver(records => { if (records.length) changed = true; });
    const listener = event => {
      const value = event.detail;
      if (event.target !== candidate.control || value?.kind !== 'raw_answer_v1' || value?.op !== 'sample' || value?.grant !== grant) return;
      count++;
      if (Object.keys(value).sort().join(',') !== 'candidate,eligible,grant,kind,op,responseID,text'
        || value.eligible !== true || value.candidate !== candidate.rawCandidate || value.responseID !== candidate.responseID
        || typeof value.text !== 'string' || value.text.length > 220000) return;
      captured = value.text;
    };
    document.addEventListener(channel.result,listener,true);
    try {
      observer.observe(candidate.root,{subtree:true,childList:true,attributes:true,characterData:true});
      for (const parent of new Set(candidate.nodes.map(node=>node.parentNode).filter(Boolean)))
        observer.observe(parent,{childList:true,attributes:true});
      recheck();
      if (codePayloadRoot(candidate.control) !== appRoot) fail('root_boundary');
      candidate.control.dispatchEvent(new CustomEvent(channel.dispatch,{bubbles:true,detail:{kind:'raw_answer_v1',op:'sample',
        secret:channel.secret,chatID:route().id,parentID:candidate.parentID,responseID:candidate.responseID,
        candidate:candidate.rawCandidate,grant}}));
      if (observer.takeRecords().length) changed = true;
      recheck();
      if (observer.takeRecords().length) changed = true;
      if (changed) fail('synchronous_mutation');
      if (codePayloadRoot(candidate.control) !== appRoot) fail('root_boundary');
      if (count !== 1) fail(count === 0 ? 'result_missing' : 'result_multiple');
      if (captured === null) fail('result_invalid');
      const bytes = new TextEncoder().encode(captured);
      if (bytes.length > 220000) c.fail('response_too_large');
      if (new TextDecoder('utf-8',{fatal:true}).decode(bytes) !== captured) fail('utf8_roundtrip');
      return captured;
    } finally { captured = null; observer.disconnect(); document.removeEventListener(channel.result,listener,true); }
  }
  function sampleCodePayload(candidate, channel, grant, recheck) {
    if (candidate.kind === 'raw_answer_v1') return sampleAuthoredSource(candidate,channel,grant,recheck);
    const fail = codePayloadFailure;
    if (!channel || Object.keys(channel).sort().join(',') !== 'dispatch,result,secret'
      || ![channel.dispatch,channel.result,channel.secret].every(c.uuid) || !c.uuid(grant)) fail('channel_shape');
    const appRoot = codePayloadRoot(candidate.control);
    if (!appRoot) fail('root_boundary');
    let count = 0, captured = null, changed = false, resultReason = 'result_invalid';
    const observer = new MutationObserver(records => { if (records.length) changed = true; });
    const listener = event => {
      if (event.target !== candidate.control || event.detail?.grant !== grant) return;
      count++;
      const value = event.detail;
      if (Object.keys(value).sort().join(',') !== 'count,grant,invalid,invalidCause,text') { resultReason = 'result_fields'; return; }
      if (value.count !== 1) { resultReason = 'write_count'; return; }
      if (value.invalid !== false) {
        const reasons = {value_type:'write_invalid_type',value_size:'write_invalid_size',write_api:'write_invalid_api',
          exec_command:'write_invalid_exec',click_exception:'write_invalid_click',hooks_changed:'write_invalid_hooks',resolve_failure:'write_invalid_resolve',root_boundary:'root_boundary'};
        resultReason = value.invalid !== true ? 'result_invalid'
          : typeof value.invalidCause === 'string' && Object.prototype.hasOwnProperty.call(reasons, value.invalidCause)
            ? reasons[value.invalidCause] : 'result_fields';
        return;
      }
      if (value.invalidCause !== null) { resultReason = 'result_fields'; return; }
      if (typeof value.text !== 'string') { resultReason = 'write_type'; return; }
      if (value.text.length > 220_000) { resultReason = 'write_size'; return; }
      captured = value.text;
    };
    document.addEventListener(channel.result, listener, true);
    try {
      observer.observe(candidate.root, {subtree:true,childList:true,attributes:true,characterData:true});
      // Observe the complete bounded chain, including the Document parent of HTML.
      // Same-node detach/reinsert and restored ancestor masking must still refuse.
      const parents = new Set(candidate.nodes.map(node => node.parentNode).filter(Boolean));
      if (parents.size > 96) fail('ancestor_limit');
      for (const parent of parents) observer.observe(parent, {childList:true,attributes:true});
      recheck();
      if (codePayloadRoot(candidate.control) !== appRoot) fail('root_boundary');
      candidate.control.dispatchEvent(new CustomEvent(channel.dispatch, {bubbles:true,
        detail:{secret:channel.secret,grant}}));
      if (observer.takeRecords().length) changed = true;
      recheck();
      if (observer.takeRecords().length) changed = true;
      if (changed) fail('synchronous_mutation');
      if (count !== 1) fail(count === 0 ? 'result_missing' : 'result_multiple');
      if (codePayloadRoot(candidate.control) !== appRoot) fail('root_boundary');
      if (captured === null) fail(resultReason);
      const bytes = new TextEncoder().encode(captured);
      if (bytes.length > 220_000) c.fail('response_too_large');
      if (new TextDecoder('utf-8', {fatal:true}).decode(bytes) !== captured) fail('utf8_roundtrip');
      return captured;
    } finally { captured = null; observer.disconnect(); document.removeEventListener(channel.result,listener,true); }
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
  return { rejectUserCount, rejectSelectionBinding, firstDisplayReplacement, watchDisplayRender, watchAssistantTurnReplacement,
    displayHitFailure, firstBodyPresentation, firstBodyFailureStructure,
    responseChoiceTranscript: () => transcript(true, null, true),
    hasResponseChoice: () => c.nodes(document, '.qwen-chat-message-assistant .smrm', 2).length !== 0,
    initialResponseIdentityTranscript: emptyContainerPrompt => transcript(true, emptyContainerPrompt), route, authored, initialReady, picker, modelRows, composer, transcript, modelQuotaTV, replyProgressUI, completionCandidate, rawAnswer, codePayloadFailure, sampleCodePayload, authoredSourceCandidate,
    deletionTrigger, deletionMenu, deletionConfirmation, deletionObserved, insertLiteral };
}

// Standalone composition; native catalog admission is separate from this adapter.
try {
  const actions = ['inspect', 'discoverModels', 'selectModel', 'verifyModel', 'prepare', 'insert', 'sendReady', 'submit', 'stop',
    'deleteConversation', 'selectConversationDeletion', 'confirmConversationDeletion', 'observeDeletedConversation'];
  const c = computaProviderCore(input, 'qwen', 'https://chat.qwen.ai', actions);
  return await computaSavedConversation(input, c, computaQwenDOM(c), {
    stateKey: '__computaQwenSavedSessionV1', modelQuota: 'qwen_tv_card_v1', origin: 'https://chat.qwen.ai', initialProvisionalRoute: true, initialResponseIdentity: true,
    responseChoice: 'qwen_smrm', firstEmptyContainerChoice: { key: 'Qwen3.8-Max', label: 'Qwen3.8-Max' },
    firstDisplayTurnReplacementChoice: { key: 'Qwen3.8-Max', label: 'Qwen3.8-Max' },
    deferDisplayUntilAnswer: ['Qwen3.7-Plus', 'Qwen3.8-Max'].map(label => ({ key: label, label }))
  });
} catch (error) {
  return error?.computaAdapterFailure ? { error: error.error, ...(error.detail ? { detail: error.detail } : {}) }
    : { error: 'document_changed' };
}
