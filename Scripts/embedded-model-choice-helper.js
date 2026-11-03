// Shared source copied into each standalone private-world provider adapter.
// Model names come only from the provider's associated picker, never messages.
// This private-world notification carries no page content and grants no authority.
function websiteModelDiagnosticPhase(phase) {
  try {
    const phases = ['adapter_entry', 'model_proof', 'model_wait', 'model_wait_done', 'first_user_hash',
      'first_user_expand', 'first_user_expand_wait', 'page_action', 'final_model_guard'];
    if (typeof input !== 'object' || input === null || !phases.includes(phase)
      || !/^[a-f0-9-]{36}$/i.test(input.ownerToken || '') || !/^[a-f0-9-]{36}$/i.test(input.operationID || '')
      || window !== window.top) return;
    window.webkit?.messageHandlers?.computaModelDiagnostic?.postMessage({
      ownerToken: input.ownerToken, operationID: input.operationID, phase });
  } catch { /* An unavailable diagnostic channel must not change adapter behavior. */ }
}
websiteModelDiagnosticPhase('adapter_entry');
function websiteModelNormalize(value) {
  return typeof value === 'string' ? value.normalize('NFC').replace(/\s+/g, ' ').trim() : '';
}
function websiteModelChoiceValid(choice) {
  return !!choice && !Array.isArray(choice) && typeof choice === 'object'
    && Object.keys(choice).length === 2 && typeof choice.key === 'string' && typeof choice.label === 'string'
    && choice.key.length > 0 && choice.key.length <= 160 && choice.label.length > 0 && choice.label.length <= 120
    && websiteModelNormalize(choice.key) === choice.key && websiteModelNormalize(choice.label) === choice.label;
}
function websiteModelChoiceEqual(left, right) {
  return websiteModelChoiceValid(left) && websiteModelChoiceValid(right)
    && left.key === right.key && left.label === right.label;
}
function websiteChatClaimInvocation(request) {
  if (request?.provider !== 'chatgpt' || typeof window !== 'object' || window !== window.top
    || location.origin !== 'https://chatgpt.com' || document.URL !== request.expectedURL
    || typeof request.ownerToken !== 'string' || !request.ownerToken
    || globalThis.__computaModelOwner !== request.ownerToken
      && !(globalThis.__computaModelOwner === undefined && request.bindOwner === true)) return null;
  // A native timeout cannot cancel JavaScript already queued in WebContent.
  // Claim at adapter entry, before any async hash/read, so a replacement can
  // revoke an older reader's proof and popup cleanup within the same document.
  const lease = { owner: request.ownerToken, document };
  globalThis.__computaChatActiveInvocation = lease;
  return lease;
}
const websiteChatInvocationLease = websiteChatClaimInvocation(input);
// Chat exposes power presets; the concrete plain GPT family is an independently
// observed automatic-selection policy, never another advertised model choice.
const websiteChatPowers = Object.freeze([
  Object.freeze({ key: 'instant', label: 'Instant' }),
  Object.freeze({ key: 'medium', label: 'Medium' }),
  Object.freeze({ key: 'high', label: 'High' }),
  Object.freeze({ key: 'extra-high', label: 'Extra High' }),
  Object.freeze({ key: 'pro', label: 'Pro' }),
]);
function websiteChatFamilyVersion(label) {
  if (typeof label !== 'string' || label.length > 128
    || !/^GPT-[1-9][0-9]*(?:\.(?:0|[1-9][0-9]*))*$/.test(label)) return null;
  const components = label.slice(4).split('.');
  while (components.length > 1 && components.at(-1) === '0') components.pop();
  return components;
}
function websiteChatCompareVersions(left, right) {
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const a = left[index] || '0', b = right[index] || '0';
    if (a.length !== b.length) return a.length > b.length ? 1 : -1;
    if (a !== b) return a > b ? 1 : -1;
  }
  return 0;
}
function websiteChatNewestFamily(offered) {
  if (!Array.isArray(offered) || offered.length < 1 || offered.length > 32) return null;
  const versions = offered.map(websiteChatFamilyVersion);
  if (versions.some(version => !version)) return null;
  let newest = 0;
  for (let index = 0; index < versions.length; index++) {
    for (let preceding = 0; preceding < index; preceding++)
      if (websiteChatCompareVersions(versions[index], versions[preceding]) === 0) return null;
    if (websiteChatCompareVersions(versions[index], versions[newest]) > 0) newest = index;
  }
  return { key: offered[newest], label: offered[newest] };
}
function websiteChatPowerValid(power) {
  return !!power && !Array.isArray(power) && typeof power === 'object'
    && Object.keys(power).length === 2 && Object.hasOwn(power, 'key') && Object.hasOwn(power, 'label')
    && websiteChatPowers.some(known => known.key === power.key && known.label === power.label);
}
function websiteChatFamilyValid(family) {
  return !!family && !Array.isArray(family) && typeof family === 'object'
    && Object.keys(family).length === 2 && Object.hasOwn(family, 'key') && Object.hasOwn(family, 'label')
    && family.key === family.label && websiteChatFamilyVersion(family.label) !== null;
}
function websiteChatPresetChoice(family, power) {
  if (!websiteChatFamilyValid(family) || !websiteChatPowerValid(power)) return null;
  const choice = { key: 'chat/latest/' + power.key,
    label: power.key === 'pro' ? family.label + ' ' + power.label : power.label };
  return websiteModelChoiceValid(choice) ? choice : null;
}
function websiteChatPresetIntentValid(choice) {
  if (!websiteModelChoiceValid(choice)) return false;
  const power = websiteChatPowers.find(power => choice.key === 'chat/latest/' + power.key);
  return !!power && (choice.label === power.label || power.key === 'pro'
    && choice.label.endsWith(' Pro') && websiteChatFamilyVersion(choice.label.slice(0, -4)) !== null);
}
function websiteChatSelectionEvidence(family, power, offered, intent = null) {
  const newest = websiteChatNewestFamily(offered);
  let selected = websiteChatPresetChoice(family, power);
  if (!selected || !newest || newest.key !== family.key) return null;
  if (intent != null) {
    if (!websiteChatPresetIntentValid(intent) || intent.key !== selected.key
      || intent.label !== selected.label && !(power.key === 'pro' && intent.label === power.label)) return null;
    selected = { key: intent.key, label: intent.label };
  }
  return { selected, verification: 'website_selection', source: 'selected_model_indicator',
    chatSelection: { family: { key: family.key, label: family.label },
      power: { key: power.key, label: power.label },
      automaticFamily: { policy: 'highest_offered_plain_gpt', offered: [...offered] } } };
}
function websiteChatResolvedSelectionEqual(left, right) {
  return websiteChatFamilyValid(left?.family) && websiteChatFamilyValid(right?.family)
    && websiteChatPowerValid(left?.power) && websiteChatPowerValid(right?.power)
    && left.family.key === right.family.key && left.family.label === right.family.label
    && left.power.key === right.power.key && left.power.label === right.power.label;
}
function websiteChatHeaderPresentation(value, negativeCompact = false) {
  if (typeof value !== 'string' || value.length > 128) return { kind: 'unknown', power: null };
  const normalized = websiteModelNormalize(value);
  const canonical = websiteChatPowers.find(power => power.label === normalized);
  if (canonical) return { kind: 'canonical', power: canonical };
  const composite = websiteChatPowers.find(power => 'Thinking effort ' + power.label === normalized);
  if (composite) return { kind: 'generic_power', power: composite };
  // Historical textContent reconstruction can lose rendered block separators.
  // This exact compact grammar is negative evidence only, never model proof.
  const compact = negativeCompact && websiteChatPowers.find(power => 'Thinking effort' + power.label === normalized);
  if (compact) return { kind: 'generic_power_compact', power: compact };
  return { kind: normalized === '' ? 'empty' : normalized === 'Thinking effort' ? 'generic' : 'unknown', power: null };
}
function websiteChatHeaderPower(trigger) {
  return websiteChatHeaderPresentation(trigger?.innerText).power;
}
function websiteChatHeaderTextShape(value) {
  const present = typeof value === 'string';
  const normalized = present && value.length <= 512 ? websiteModelNormalize(value) : null;
  const ordinal = present && value.length <= 128
    ? websiteChatPowers.findIndex(power => power.label === normalized) : -1;
  const presentation = websiteChatHeaderPresentation(value);
  return { present, length: present ? Math.min(value.length, 513) : 0,
    normalizedLength: normalized === null ? null : Math.min(normalized.length, 512),
    empty: normalized === '', over128: present && value.length > 128,
    canonicalOrdinal: ordinal < 0 ? null : ordinal, generic: normalized === 'Thinking effort',
    presentation: presentation.kind,
    powerOrdinal: presentation.power ? websiteChatPowers.findIndex(power => power.key === presentation.power.key) : null };
}
// Generic chrome carries no model value. This predicate supplies only negative
// continuity after a full associated-menu proof on this exact owned header.
function websiteChatClosedHeaderMatches(state, power, pin = globalThis.__computaChatPresetPin) {
  if (!state.closedPresentation || !websiteChatPowerValid(power)) return false;
  if (state.headerPower) return state.headerPower.key === power.key;
  return state.headerPresentation && pin?.genericHeaderVerified === state.trigger
    && pin.headerTrigger === state.trigger && pin.owner === globalThis.__computaModelOwner
    && pin.document === document && pin.invalidated !== true && pin.selection?.power?.key === power.key;
}
// The optional predecessor is private to one fresh Power-step rendering wait.
// Established selections always pass only their single pinned expected power.
function websiteChatHeaderMutationMismatch(records, trigger, expected, diagnostic = null, previous = null) {
  if (!trigger || !expected) return false;
  const fail = (stage, rule) => {
    if (diagnostic && diagnostic.rule == null) { diagnostic.stage = stage; diagnostic.rule = rule; }
    return true;
  };
  const different = value => {
    const power = websiteChatHeaderPresentation(value, true).power;
    return !!power && power.key !== expected.key && power.key !== previous?.key;
  };
  if (different(trigger.innerText)) return fail('current', 'current_power');
  // Current ancestry loses an attached header child that changed and detached
  // before delivery. Undo structural records, then replay their exact lineage.
  // The bounded reconstruction supplies only negative drift evidence.
  if (records.length > 512) return fail('records', 'record_limit');
  const parents = new Map(), children = new Map(), text = new Map(), afterText = new Map();
  const parent = node => parents.has(node) ? parents.get(node) : node?.parentNode || node?.parentElement || null;
  const bounded = value => typeof value === 'string' && value.length <= 128 ? value : null;
  for (const record of records) if (record.type === 'childList') {
    const nodes = [...(record.addedNodes || []), ...(record.removedNodes || [])];
    if (nodes.length > 128) return fail('records', 'child_nodes_limit');
    const candidates = children.get(record.target) || new Set();
    for (const node of nodes) candidates.add(node);
    children.set(record.target, candidates);
  }
  for (let index = records.length - 1; index >= 0; index--) {
    const record = records[index];
    if (record.type === 'childList') {
      for (const node of record.addedNodes || []) if (parent(node) === record.target) parents.set(node, null);
      for (const node of record.removedNodes || []) parents.set(node, record.target);
    } else if (record.type === 'characterData') {
      afterText.set(record, text.has(record.target) ? text.get(record.target) : bounded(record.target?.textContent));
      text.set(record.target, bounded(record.oldValue));
    }
    if (parents.size + text.size > 4_096) return fail('reconstruction', 'reconstruction_limit');
  }
  const suppressed = node => node === trigger && node.nodeType === 1
    && (node.getAttribute('aria-hidden') === 'true' || node.getAttribute('inert') !== null);
  const headerTarget = node => {
    for (let depth = 0; node && depth < 64; depth++, node = parent(node)) {
      if (suppressed(node)) return false;
      if (node === trigger) return true;
    }
    return node ? null : false;
  };
  let textFailure = null;
  const rejectText = rule => { textFailure ||= rule; return null; };
  const textAt = (node, budget = { nodes: 128, depth: 0 }) => {
    if (!node) return rejectText('node_missing');
    if (--budget.nodes < 0) return rejectText('node_limit');
    if (budget.depth > 32) return rejectText('depth_limit');
    if (node.nodeType === 3) {
      const value = text.has(node) ? text.get(node) : bounded(node.textContent);
      return value === null ? rejectText('text_limit') : value;
    }
    // AX suppression below the header does not hide rendered innerText. These
    // bounded records can only reject a pin, including after a node detaches.
    if (node.nodeType !== 1 || suppressed(node)) return '';
    const current = [...(node.childNodes || [])];
    if (current.length > 128) return rejectText('children_limit');
    const candidates = new Set([...current, ...(children.get(node) || [])]);
    if (candidates.size > 128) return rejectText('candidate_limit');
    let value = '';
    budget.depth++;
    for (const child of candidates) if (parent(child) === node) {
      const part = textAt(child, budget);
      if (part === null || value.length + part.length > 128) {
        budget.depth--; return part === null ? null : rejectText('aggregate_limit');
      }
      value += part;
    }
    budget.depth--;
    return value;
  };
  for (const record of records) {
    if (record.type === 'characterData') {
      const owned = headerTarget(record.target);
      if (owned === null) return fail('character_data', 'ancestry_limit');
      if (owned) {
        if (bounded(record.oldValue) === null) return fail('character_data', 'old_text_limit');
        if (afterText.get(record) === null) return fail('character_data', 'new_text_limit');
        if (different(record.oldValue)) return fail('character_data', 'old_power');
        if (different(afterText.get(record))) return fail('character_data', 'new_power');
      }
      text.set(record.target, afterText.get(record));
    } else if (record.type === 'childList') {
      for (const node of record.removedNodes || []) {
        const owned = headerTarget(node), value = owned ? textAt(node) : '';
        if (owned === null) return fail('removed', 'ancestry_limit');
        if (owned && value === null) return fail('removed', textFailure);
        if (owned && different(value)) return fail('removed', 'power');
        if (parent(node) === record.target) parents.set(node, null);
      }
      for (const node of record.addedNodes || []) {
        parents.set(node, record.target);
        const owned = headerTarget(node), value = owned ? textAt(node) : '';
        if (owned === null) return fail('added', 'ancestry_limit');
        if (owned && value === null) return fail('added', textFailure);
        if (owned && different(value)) return fail('added', 'power');
      }
    }
  }
  return false;
}
function websiteChatInvalidatePin(pin, reason, facts = null, source = 'unknown') {
  pin.invalidated = true;
  // Preserve the first finite cause. This records negative evidence only;
  // it cannot revive a selection or change any model/ownership guard.
  if (!pin.invalidationReason && ['header_replaced', 'header_mutation', 'semantic_mutation'].includes(reason)) {
    pin.invalidationReason = reason;
    pin.invalidationFacts = facts;
    pin.invalidationSource = ['header_tracking', 'pinned_header', 'remount_header', 'remount_context', 'provisional_header',
      'provisional_context', 'semantic_observer', 'deferred_model'].includes(source) ? source : 'unknown';
  }
}
function websiteChatTrackPinnedHeader(pin, trigger) {
  if (!pin || pin.owner !== globalThis.__computaModelOwner || pin.document !== document) return;
  if (pin.headerTrigger && pin.headerTrigger !== trigger) {
    websiteChatInvalidatePin(pin, 'header_replaced', { stage: 'header_tracking', rule: 'trigger_identity' }, 'header_tracking'); return;
  }
  pin.headerTrigger = trigger;
  if (pin.headerObserver) return;
  pin.headerObserver = new MutationObserver(records => websiteChatObservePinnedHeader(pin, trigger, records));
  pin.headerObserver.observe(trigger, { subtree: true, childList: true, characterData: true,
    characterDataOldValue: true });
}
function websiteChatObservePinnedHeader(pin, trigger, records) {
  if (globalThis.__computaChatPresetPin !== pin || pin.owner !== globalThis.__computaModelOwner
    || pin.document !== document || window !== window.top || location.origin !== 'https://chatgpt.com') return;
  const diagnostic = {};
  if (websiteChatHeaderMutationMismatch(records, trigger, pin.selection.power, diagnostic))
    websiteChatInvalidatePin(pin, 'header_mutation', Object.freeze(diagnostic), 'pinned_header');
}
function websiteChatDrainPinnedMutations(pin) {
  // Only private model observers are drained. The shared notification observer
  // also owns product-mode evidence and must retain all of its pending records.
  if (pin?.headerTrigger) websiteChatObservePinnedHeader(pin, pin.headerTrigger, pin.headerObserver?.takeRecords?.() || []);
  if (pin) websiteChatObservePinnedMutations(pin.semanticObserver?.takeRecords?.() || [], pin);
}
function websiteChatTrackPinnedControls(pin, state) {
  if (!pin || pin.owner !== globalThis.__computaModelOwner || pin.document !== document
    || !websiteChatFamilyValid(pin.selection?.family) || !websiteChatPowerValid(pin.selection?.power)) return;
  pin.controls = pin.controls || new WeakMap();
  if (!pin.semanticObserver) {
    pin.semanticObserver = new MutationObserver(records => websiteChatObservePinnedMutations(records, pin));
    pin.semanticObserver.observe(document.documentElement || document, { subtree: true,
      attributes: true, attributeOldValue: true, attributeFilter: ['aria-valuenow', 'aria-checked'] });
  }
  const slider = state.slider || state.semanticSlider;
  if (slider) pin.controls.set(slider, { attribute: 'aria-valuenow',
    value: String(websiteChatPowers.findIndex(power => power.key === pin.selection.power.key)) });
  for (const control of state.familyControls) pin.controls.set(control.node,
    { attribute: 'aria-checked', value: String(control.choice?.key === pin.selection.family.key) });
}
function websiteChatObservePinnedMutations(records, pin = globalThis.__computaChatPresetPin) {
  if (!pin || pin.invalidated === true || !pin.controls || pin.owner !== globalThis.__computaModelOwner
    || globalThis.__computaChatPresetPin !== pin || pin.document !== document
    || window !== window.top || location.origin !== 'https://chatgpt.com') return;
  // Track only previously observed semantic controls. Mounting a popup, updating
  // its visibility, or setting the same selected value cannot invalidate it.
  // Old values preserve an observable switch-and-restore in one mutation batch.
  for (const record of records) {
    if (record.type !== 'attributes') continue;
    const expected = pin.controls.get(record.target);
    if (!expected || record.attributeName !== expected.attribute) continue;
    const value = record.target.getAttribute(expected.attribute);
    if (value !== expected.value || record.oldValue != null && record.oldValue !== expected.value) {
      websiteChatInvalidatePin(pin, 'semantic_mutation', {
        attribute: record.attributeName, nodeConnected: record.target.isConnected === true,
        attributePresent: value !== null, currentMatches: value === expected.value,
        oldMatches: record.oldValue === null || record.oldValue === expected.value,
      }, 'semantic_observer');
      return;
    }
  }
}
function websiteChatPickerState() {
  const boundary = '[data-message-author-role], [data-markdown-text-style], [data-turn], [data-user-message-bubble], [role="tooltip"]';
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden';
  const visible = node => physical(node) && !node.closest('[inert], [aria-hidden="true"]');
  const outside = node => !!node && !node.closest(boundary);
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('disabled') === null
    && node.getAttribute('aria-disabled') !== 'true';
  const nodes = selector => [...document.querySelectorAll(selector)].slice(0, 256);
  const triggerCandidates = nodes('button[aria-label], [role="button"][aria-label]')
    .filter(node => physical(node) && outside(node) && /^Select ChatGPT model(?:$|[ ,])/.test(websiteModelNormalize(node.getAttribute('aria-label'))));
  const triggers = triggerCandidates.filter(node => node.getAttribute('aria-label') === 'Select ChatGPT model'
    && node.getAttribute('aria-haspopup') === 'menu');
  const trigger = triggers.length === 1 ? triggers[0] : null;
  const physicalMenus = nodes('[role="menu"], [role="listbox"], [role="dialog"]').filter(node => physical(node) && outside(node));
  const allMenus = physicalMenus.filter(visible);
  const controlledID = trigger?.getAttribute('aria-controls');
  const associated = allMenus.filter(menu => menu.getAttribute('role') === 'menu'
    && typeof controlledID === 'string' && controlledID.length > 0 && controlledID.length <= 256
    && !/\s/.test(controlledID) && menu.getAttribute('id') === controlledID);
  const topMenu = associated.length === 1 ? associated[0] : null;
  const family = node => {
    if (!node || !physical(node) || !outside(node)) return null;
    const raw = node.innerText || node.textContent || '';
    if (raw.length > 512) return null;
    const lines = raw.split('\n').map(websiteModelNormalize).filter(Boolean);
    if (lines.length < 1 || lines.length > 2 || lines.length === 2
      && !/^Leaving on [A-Z][a-z]+ [0-9]{1,2}$/.test(lines[1])) return null;
    const label = lines[0];
    if (label.length > 128 || !/^GPT-[0-9]+(?:\.[0-9]+)*(?: [A-Za-z][A-Za-z0-9-]*)?$/.test(label)) return null;
    return { key: label, label };
  };
  const familyRows = topMenu ? [...topMenu.querySelectorAll('[role="menuitemradio"]')].slice(0, 128)
    .filter(node => enabled(node) && outside(node) && node.closest('[role="menu"]') === topMenu) : [];
  const familyControls = familyRows.map(node => ({ node, choice: family(node) }));
  const familyChoices = familyControls.map(control => control.choice).filter(Boolean);
  const checked = familyControls.filter(control => control.node.getAttribute('aria-checked') === 'true');
  const plain = familyChoices.filter(choice => websiteChatFamilyVersion(choice.label));
  const newest = websiteChatNewestFamily(plain.map(choice => choice.label));
  const physicalPowerItems = topMenu ? [...topMenu.querySelectorAll('[role="menuitem"][aria-label="Power"]')].slice(0, 3)
    .filter(node => physical(node) && outside(node) && node.closest('[role="menu"]') === topMenu) : [];
  const powerItems = physicalPowerItems.filter(visible);
  const powerItem = powerItems.length === 1 ? powerItems[0] : null;
  const physicalPowerItem = physicalPowerItems.length === 1 ? physicalPowerItems[0] : null;
  const physicalSliders = physicalPowerItems.length === 1 ? [...physicalPowerItems[0].querySelectorAll('[role="slider"]')].slice(0, 3)
    .filter(node => physical(node) && outside(node) && node.closest('[role="menu"]') === topMenu) : [];
  const sliders = powerItem ? physicalSliders : [];
  const physicalSlider = physicalSliders.length === 1 ? physicalSliders[0] : null;
  const slider = sliders.length === 1 ? sliders[0] : null;
  // Physically rendered metadata can be accessibility-hidden anywhere below
  // Power. Only its visible, enabled menuitem owns input; suppression at that
  // item or above remains forbidden by visible(), independently of the thumb.
  const metadataScoped = node => physical(node) && !!powerItem && powerItem.contains(node)
    && node.closest('[role="menuitem"][aria-label="Power"]') === powerItem
    && node.closest('[role="menu"]') === topMenu;
  const metadataSuppressedWithinPower = selector => {
    const suppressed = physicalSlider?.closest(selector);
    return !!suppressed && !!physicalPowerItem && suppressed !== physicalPowerItem
      && physicalPowerItem.contains(suppressed);
  };
  const metadataDisabled = node => !!node && (node.disabled || node.getAttribute('disabled') !== null
    || !!node.closest('[disabled], [aria-disabled="true"]'));
  const rawValue = physicalSlider?.getAttribute('aria-valuenow');
  const shapePowerIndex = physicalSlider && physicalSlider.tagName.toLowerCase() === 'span'
    && physicalSlider.getAttribute('aria-valuemin') === '0' && physicalSlider.getAttribute('aria-valuemax') === '4'
    && physicalSlider.getAttribute('aria-orientation') === 'horizontal' && /^[0-4]$/.test(rawValue || '')
    ? Number(rawValue) : null;
  const recognizedPowerIndex = metadataScoped(slider) ? shapePowerIndex : null;
  const powerUnavailable = recognizedPowerIndex !== null && (!enabled(powerItem) || metadataDisabled(slider));
  const powerIndex = powerUnavailable ? null : recognizedPowerIndex;
  const secondaries = topMenu ? [...topMenu.querySelectorAll('button, [role="menuitem"]')].slice(0, 128)
    .filter(node => enabled(node) && outside(node) && node.closest('[role="menu"]') === topMenu
      && websiteModelNormalize(node.getAttribute('aria-label') || node.innerText || node.textContent) === 'Select model') : [];
  const secondary = secondaries.length === 1 ? secondaries[0] : null;
  const duplicate = familyChoices.some((choice, index) => familyChoices.some((other, otherIndex) => index !== otherIndex && choice.key === other.key))
    || plain.length > 0 && !newest;
  const indicatorInvalid = familyControls.some(control => !control.choice
    || !['true', 'false'].includes(control.node.getAttribute('aria-checked'))
    || /^GPT-[0-9]+(?:\.[0-9]+)*$/.test(control.choice.label) && !websiteChatFamilyVersion(control.choice.label))
    || sliders.length > 1 || powerItems.length > 1 || !!slider && recognizedPowerIndex === null;
  const headerPower = enabled(trigger) ? websiteChatHeaderPower(trigger) : null;
  const closedPresentation = enabled(trigger) && !topMenu && allMenus.length === 0
    && [null, 'false'].includes(trigger.getAttribute('aria-expanded'))
    && [null, 'closed'].includes(trigger.getAttribute('data-state'));
  const headerPresentation = websiteModelNormalize(trigger?.innerText) === 'Thinking effort';
  const semanticSlider = shapePowerIndex !== null && physicalPowerItem
    && physicalSlider.closest('[role="menuitem"][aria-label="Power"]') === physicalPowerItem
    && physicalSlider.closest('[role="menu"]') === topMenu ? physicalSlider : null;
  return { provider: 'chatgpt', trigger, triggerCount: triggers.length, triggerCandidates, topMenu, secondary,
    headerPower, headerPresentation, closedPresentation, semanticSlider,
    nestedMenu: familyRows.length ? topMenu : null, menus: topMenu ? [topMenu] : [], allMenus, physicalMenus,
    controls: familyControls.filter(control => control.choice), choices: [], selected: null, evidence: null,
    familyControls, offered: plain.map(choice => choice.label), newest,
    checkedFamily: checked.length === 1 && websiteChatFamilyValid(checked[0].choice) ? checked[0].choice : null,
    powerItem, slider, powerIndex, powerUnavailable, power: powerIndex === null ? null : websiteChatPowers[powerIndex],
    powerDiagnostic: {
      physicalItemCount: physicalPowerItems.length, physicalSliderCount: physicalSliders.length,
      itemVisible: !!powerItem, itemEnabled: enabled(powerItem), sliderPhysical: physical(physicalSlider),
      sliderInertSelf: !!physicalSlider && physicalSlider.getAttribute('inert') !== null,
      sliderInertAncestor: !!physicalSlider?.parentElement?.closest('[inert]'),
      sliderAriaHidden: !!physicalSlider?.closest('[aria-hidden="true"]'), sliderDisabled: metadataDisabled(physicalSlider),
      metadataWithinPower: metadataScoped(physicalSlider),
      metadataInertWithinPower: metadataSuppressedWithinPower('[inert]'),
      metadataAriaHiddenWithinPower: metadataSuppressedWithinPower('[aria-hidden="true"]'),
      powerInertAtOrAbove: !!physicalPowerItem?.closest('[inert]'),
      powerAriaHiddenAtOrAbove: !!physicalPowerItem?.closest('[aria-hidden="true"]'),
      shapeRecognized: shapePowerIndex !== null, ordinal: recognizedPowerIndex },
    mode: familyRows.length ? 'family' : powerIndex !== null && secondary ? 'power' : topMenu ? 'unknown' : 'closed',
    duplicate, conflicting: familyRows.length > 0 && !!slider, indicatorInvalid, selectionAmbiguous: checked.length > 1,
    navigationAmbiguous: associated.length > 1 || secondaries.length > 1,
    physical, visible, enabled, family };
}
async function websiteChatObserveSelection(request, expected, freshGuard = null, attempt = null, context = null) {
  const owner = globalThis.__computaModelOwner, url = document.URL, originalDocument = document;
  const mutable = typeof freshGuard === 'function';
  let until = Date.now() + 1_800;
  // Only the private first-insert final guard may carry time already spent on
  // editor readiness. Other reads retain their original independent budget.
  const cappedFirstInsert = !mutable && request.action === 'insert' && request.submissionSequence === 1
    && request.expectedModelChoice?.key === 'chat/latest/instant' && context?.action === 'insert'
    && context.scope === 'action_final_guard' && context.firstInsertDeadline !== undefined;
  if (cappedFirstInsert) {
    if (!Number.isSafeInteger(context.firstInsertDeadline) || context.firstInsertDeadline < 0)
      return { error: 'model_unverified' };
    until = Math.min(until, context.firstInsertDeadline);
    if (Date.now() >= until) return { error: 'model_unverified' };
  }
  const owned = () => window === window.top && location.origin === 'https://chatgpt.com'
    && document === originalDocument && document.URL === url && globalThis.__computaModelOwner === owner
    && owner === request.ownerToken && websiteChatInvocationLease != null
    && globalThis.__computaChatActiveInvocation === websiteChatInvocationLease
    && (!mutable || freshGuard(false) === true);
  let trigger = null, selectionChanged = false, dismissedPopup = null, readStage = 'initial_observation';
  let primaryOpened = false, secondaryOpened = false, closeAttempted = false, observedProof = false;
  let headerExpected = null, proofLocked = false, headerObserved = false, finalPowerState = null;
  let remount = null, remountClaimed = false;
  let prepareOpening = null, insertOpening = null, genericPowerRecheck = false;
  let verifyObserver = null, verifyAcknowledged = false;
  const recordVerifyOpening = records => {
    if (records.some(record => record.target === trigger && (record.attributeName === 'aria-expanded' && record.oldValue === 'true'
      || record.attributeName === 'data-state' && record.oldValue === 'open'))) verifyAcknowledged = true;
  };
  let headerReadiness = null, changingPowerHeader = null, changingPowerSlider = null;
  const tracked = new Map();
  const observeHeader = records => {
    const diagnostic = {};
    if (websiteChatHeaderMutationMismatch(records, trigger, headerExpected, diagnostic, changingPowerHeader)) {
      selectionChanged = true;
      if (remount && owned()) websiteChatInvalidatePin(remount.pin, 'header_mutation', Object.freeze(diagnostic), 'remount_header');
    }
  };
  const headerObserver = new MutationObserver(observeHeader);
  const observeControls = records => {
    if (changingPowerSlider && records.some(record => record.type === 'attributes'
      && record.target === changingPowerSlider.node && record.attributeName === 'aria-valuenow'
      && (record.target.getAttribute('aria-valuenow') !== changingPowerSlider.value
        || record.oldValue != null && record.oldValue !== changingPowerSlider.value))) selectionChanged = true;
    if (mutable && !proofLocked) return;
    if (records.some(record => {
      if (record.type !== 'attributes' || !tracked.has(record.target)
        || !['aria-valuenow', 'aria-checked', 'aria-selected'].includes(record.attributeName)) return false;
      const expected = tracked.get(record.target)[record.attributeName];
      return record.target.getAttribute(record.attributeName) !== expected
        || record.oldValue != null && record.oldValue !== expected;
    })) selectionChanged = true;
    if (remount) websiteChatObservePinnedMutations(records, remount.pin);
  };
  const observer = new MutationObserver(observeControls);
  observer.observe(document.documentElement || document, { subtree: true, attributes: true, attributeOldValue: true,
    attributeFilter: ['aria-valuenow', 'aria-checked', 'aria-selected'] });
  const failure = code => {
    const current = websiteChatPickerState(), selection = globalThis.__computaModelSelection;
    return { error: code, modelDiagnostic: websiteModelDiagnostic(current, { readStage, headerReadiness,
      readContext: {
        scope: ['action_precheck', 'action_final_guard', 'completed_selection', 'post_selection'].includes(context?.scope)
          ? context.scope : 'unknown',
        action: ['inspect', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop', 'discoverModels',
          'selectModel', 'modelDiagnostic', 'verifyModel'].includes(context?.action) ? context.action : 'unknown',
        selectionAttemptPresent: !!selection && typeof selection === 'object',
        selectionClicked: selection?.familyClicked === true || Number.isInteger(selection?.powerEvents) && selection.powerEvents > 0,
        selectionSettled: selection?.completed === true, selectionCompleted: selection?.completed === true,
        recoveryEligible: prepareOpening !== null || insertOpening !== null },
      readAttempt: { primaryOpened, secondaryOpened, closeAttempted, observedProof,
        sameTrigger: !trigger || current.trigger === trigger, popupStillAssociated: !!current.topMenu } }) };
  };
  const state = () => {
    if (!owned()) throw failure('document_changed');
    const pin = globalThis.__computaChatPresetPin;
    if (remount && (pin !== remount.pin || pin.headerTrigger !== remount.previous
      || !websiteChatResolvedSelectionEqual(pin.selection, remount.selection))) throw failure('model_mismatch');
    if (remount) websiteChatDrainPinnedMutations(pin);
    if (selectionChanged || pin?.owner === owner && pin.document === document && pin.invalidated === true)
      throw failure('model_mismatch');
    const current = websiteChatPickerState();
    let remountFailure = null;
    const rejectRemount = (rule, value) => { if (value && remountFailure == null) remountFailure = rule; return value; };
    if (remount && (rejectRemount('previous_connected', remount.previous.isConnected !== false)
      || rejectRemount('trigger_identity', current.trigger !== remount.replacement))) {
      websiteChatInvalidatePin(pin, 'header_replaced', { stage: 'remount_context', rule: remountFailure }, 'remount_context');
      throw failure('model_mismatch');
    }
    if (current.triggerCount !== 1 || !current.trigger || trigger && current.trigger !== trigger
      || current.duplicate || current.conflicting || current.indicatorInvalid || current.selectionAmbiguous
      || current.navigationAmbiguous || current.allMenus.some(menu => menu !== current.topMenu)) throw failure('model_unverified');
    if (current.powerUnavailable) throw failure(mutable ? 'model_unavailable' : 'model_unverified');
    trigger = trigger || current.trigger;
    if (!headerObserved) {
      headerObserved = true;
      headerObserver.observe(trigger, { subtree: true, childList: true, characterData: true, characterDataOldValue: true });
    }
    if (headerExpected && current.headerPower && current.headerPower.key !== headerExpected.key
      && current.headerPower.key !== changingPowerHeader?.key) throw failure('model_mismatch');
    if (headerExpected && current.closedPresentation && !current.headerPower && !current.headerPresentation)
      throw failure('model_unverified');
    if (pin) {
      if (!remount && pin.headerTrigger && pin.headerTrigger !== trigger) {
        websiteChatDrainPinnedMutations(pin);
        // SPA route creation can remount the header without changing the model.
        // Only a fresh readonly proof may provisionally observe its replacement;
        // the original selection and every negative observation remain pinned.
        if (!mutable && !remountClaimed && pin.invalidated !== true && pin.owner === owner && pin.document === document
          && pin.headerTrigger.isConnected === false && current.closedPresentation && current.enabled(trigger)
          && websiteChatFamilyValid(pin.selection?.family) && websiteChatPowerValid(pin.selection?.power)
          && (current.headerPower?.key === pin.selection.power.key || current.headerPresentation)
          && websiteChatPresetIntentValid(expected)
          && expected.key === 'chat/latest/' + pin.selection.power.key) {
          remount = { pin, previous: pin.headerTrigger, replacement: trigger,
            selection: { family: { ...pin.selection.family }, power: { ...pin.selection.power } } };
          remountClaimed = true;
          headerExpected = pin.selection.power;
        } else websiteChatTrackPinnedHeader(pin, trigger);
      } else if (!remount) websiteChatTrackPinnedHeader(pin, trigger);
      if (pin.invalidated === true) throw failure('model_mismatch');
      if (current.semanticSlider && current.semanticSlider.getAttribute('aria-valuenow')
        !== String(websiteChatPowers.findIndex(power => power.key === pin.selection.power.key))) throw failure('model_mismatch');
    }
    websiteModelTrackReadUI(current);
    for (const node of [current.slider || current.semanticSlider, ...current.familyControls.map(control => control.node)].filter(Boolean))
      if (!tracked.has(node)) tracked.set(node, { 'aria-valuenow': node.getAttribute('aria-valuenow'),
        'aria-checked': node.getAttribute('aria-checked'), 'aria-selected': node.getAttribute('aria-selected') });
    websiteChatTrackPinnedControls(pin, current);
    return current;
  };
  const wait = async condition => {
    const changed = await websiteModelWaitForChange(until, () => !owned() || selectionChanged || condition());
    if (!owned()) throw failure('document_changed');
    if (!changed) throw failure('model_unverified');
    return state();
  };
  const pickerClosed = current => current.trigger === trigger && current.enabled(trigger)
    && !current.topMenu && current.allMenus.length === 0
    && [null, 'false'].includes(trigger.getAttribute('aria-expanded'))
    && [null, 'closed'].includes(trigger.getAttribute('data-state')) && (!!current.headerPower || current.headerPresentation);
  const acknowledgeFamilyClose = current => {
    if (!mutable || attempt.familyClicked !== true || attempt.familyCloseAcknowledged === true) return;
    if (!pickerClosed(current) || current.trigger !== attempt.selectionTrigger || freshGuard() !== true)
      throw failure('model_unverified');
    attempt.familyCloseAcknowledged = true;
  };
  const readonlyOpeningSelectionIntact = (saved, current) => {
    const pin = globalThis.__computaChatPresetPin;
    const choice = saved && websiteChatPresetChoice(saved.resolved.family, saved.resolved.power);
    return saved != null && !mutable && owned() && !selectionChanged && Date.now() < until
      && document.URL === request.expectedURL && location.pathname === '/'
      && saved.owner === owner && saved.document === originalDocument
      && globalThis.__computaModelSelection === saved.attempt && saved.attempt.started === true
      && saved.attempt.completed === true && saved.recoveryClaimed !== true
      && websiteModelChoiceEqual(saved.attempt.choice, expected)
      && pin === saved.pin && pin?.owner === owner && pin.document === originalDocument
      && pin.invalidated !== true && !pin.provisionalHeader && pin.selection === saved.selection
      && websiteChatResolvedSelectionEqual(pin.selection, saved.resolved)
      && websiteChatPresetIntentValid(expected) && choice && expected.key === choice.key
      && (expected.label === choice.label || saved.resolved.power.key === 'pro' && expected.label === 'Pro')
      && pin.headerTrigger === trigger && trigger === saved.header && trigger.isConnected === true
      && pickerClosed(current) && websiteChatClosedHeaderMatches(current, saved.resolved.power, pin)
      && Array.isArray(request.expectedUserCounts) && request.expectedUserCounts.length === 1 && request.expectedUserCounts[0] === 0
      && request.expectedFirstUserFingerprint == null && request.expectedConversation == null
      && globalThis.__computaModelFirstSubmitted !== true && !globalThis.__computaModelFirstProof
      && chatGPTMessageRoots('user').length === 0 && chatGPTMessageRoots('assistant').length === 0
      && !!chatGPTProductModeProof() && chatGPTTemporaryVerified();
  };
  const prepareOpeningIntact = current => {
    if (!readonlyOpeningSelectionIntact(prepareOpening, current) || context?.action !== request.action
      || context.scope !== 'action_final_guard' || globalThis.__computaChatSubmissionState) return false;
    if (request.action === 'prepare') return globalThis.__computaChatFirstPrepareOpening === prepareOpening;
    const composer = prepareOpening.composer;
    recordVerifyOpening(verifyObserver?.takeRecords?.() || []);
    return request.action === 'verifyModel' && request.allowFirstChatVerificationOpening === true
      && prepareOpening.attempt.firstVerificationOpening === prepareOpening && !verifyAcknowledged
      && composer && composer.isConnected && insertComposer(current) === composer && firstVerificationComposerEmpty(composer);
  };
  const insertComposer = current => {
    const candidates = [...new Set(document.querySelectorAll('#prompt-textarea[contenteditable="true"], textarea#prompt-textarea, '
      + '#prompt-textarea [contenteditable="true"], [contenteditable="true"][aria-label="Ask ChatGPT"], textarea[data-testid="prompt-textarea"]'))]
      .filter(node => current.enabled(node));
    return candidates.length === 1 ? candidates[0] : null;
  };
  const insertComposerValue = composer => composer instanceof HTMLTextAreaElement ? composer.value : composer?.innerText;
  const firstVerificationComposerEmpty = composer => {
    const value = insertComposerValue(composer);
    if (value === '') return composer instanceof HTMLTextAreaElement || composer.textContent === '' && !composer.childNodes.length;
    // WebKit renders ProseMirror's sole empty-paragraph caret sentinel as one LF.
    // Neither trimming a draft nor ignoring a second element proves emptiness.
    if (value !== '\n' || composer instanceof HTMLTextAreaElement || composer.textContent !== ''
      || composer.getAttribute('contenteditable') !== 'true' || !composer.classList.contains('ProseMirror')
      || composer.childNodes.length !== 1) return false;
    const paragraph = composer.childNodes[0], br = paragraph.childNodes?.[0];
    return paragraph.tagName === 'P' && paragraph.childNodes.length === 1 && br?.tagName === 'BR'
      && br.classList.contains('ProseMirror-trailingBreak') && !br.childNodes.length;
  };
  const insertOpeningIntact = current => {
    const saved = insertOpening, state = saved?.state, record = saved?.record;
    const composer = saved?.composer;
    const value = insertComposerValue(composer);
    return readonlyOpeningSelectionIntact(saved, current)
      && request.action === 'insert' && context?.action === 'insert' && context.scope === 'action_final_guard'
      && chatGPTSubmissionContext(state) && state.pending === record && state.lastVerified == null
      && record.firstInsertOpening === saved && record.document === originalDocument && record.owner === owner
      && record.sequence === 1 && request.submissionSequence === 1 && record.phase === 'prepared'
      && record.marker === request.submissionMarker && record.marker === request.expectedFirstUserMarker
      && record.root === null && record.body === null && record.expansionAttempted === false
      && Array.isArray(request.expectedSubmissionProofs) && request.expectedSubmissionProofs.length === 0
      && typeof request.prompt === 'string' && request.prompt === saved.prompt
      && record.canonical === saved.canonical && record.fingerprint === saved.fingerprint
      && chatGPTSubmissionCanonical(request.prompt) === record.canonical
      && globalThis.__computaModelFirstPrompt === request.prompt
      && composer?.isConnected === true && insertComposer(current) === composer && current.enabled(composer)
      && value === saved.editorValue && chatGPTSubmissionCanonical(value) === record.canonical;
  };
  const drainOpeningEvidence = () => {
    observeHeader(headerObserver.takeRecords?.() || []);
    observeControls(observer.takeRecords?.() || []);
    websiteChatDrainPinnedMutations(globalThis.__computaChatPresetPin);
    return state();
  };
  const close = async () => {
    const current = state();
    if (!current.topMenu) {
      if (pickerClosed(current)) { acknowledgeFamilyClose(current); return; }
      if (Date.now() >= until) throw failure('model_unverified');
      readStage = 'close_settlement_pending';
      const after = await wait(() => pickerClosed(websiteChatPickerState()));
      acknowledgeFamilyClose(after);
      readStage = 'close_acknowledged';
      return;
    }
    // A lost Escape acknowledgement is not permission to dispatch it again.
    if (dismissedPopup === current.topMenu) throw failure('model_unverified');
    dismissedPopup = current.topMenu;
    if (mutable && attempt.familyClicked === true && attempt.familyCloseAcknowledged !== true)
      attempt.selectionCloseAttempted = true;
    closeAttempted = true; readStage = 'close_requested';
    if (!websiteModelDismissOwnedPicker('chatgpt', trigger, current.topMenu)) throw failure('model_unverified');
    readStage = 'close_unconfirmed';
    if (Date.now() >= until && !pickerClosed(websiteChatPickerState())) throw failure('model_unverified');
    const after = await wait(() => pickerClosed(websiteChatPickerState()));
    acknowledgeFamilyClose(after);
    readStage = 'close_acknowledged';
  };
  const openPicker = async () => {
    let current = state();
    if (current.mode === 'power' || current.mode === 'family') return current;
    if (!mutable && ['prepare', 'insert'].includes(request.action) && context?.scope === 'action_final_guard' && primaryOpened && !genericPowerRecheck)
      throw failure('model_unverified');
    if (current.topMenu) { await close(); current = state(); }
    if (!current.enabled(trigger)) throw failure('model_unverified');
    const recoveryEligible = !genericPowerRecheck && mutable && attempt.familyCloseAcknowledged === true
      && attempt.postFamilyOpeningClaimed !== true;
    if (recoveryEligible) attempt.postFamilyOpeningClaimed = true;
    const completed = globalThis.__computaModelSelection;
    const firstVerify = request.action === 'verifyModel' && request.allowFirstChatVerificationOpening === true;
    if (!genericPowerRecheck && !mutable && context?.action === request.action && context.scope === 'action_final_guard'
      && completed?.completed === true && (request.action === 'prepare' && globalThis.__computaChatFirstPrepareOpening == null
        || firstVerify && completed.firstVerificationOpening == null)) {
      // Claim only the first opening of this phase, including an acknowledged opening.
      const pin = globalThis.__computaChatPresetPin;
      prepareOpening = { owner, document: originalDocument, attempt: completed, pin, selection: pin?.selection, header: trigger,
        recoveryClaimed: false,
        resolved: { family: { ...pin?.selection?.family }, power: { ...pin?.selection?.power } } };
      if (firstVerify) {
        completed.firstVerificationOpening = prepareOpening;
        prepareOpening.composer = insertComposer(current);
      } else globalThis.__computaChatFirstPrepareOpening = prepareOpening;
      current = drainOpeningEvidence();
      if (!prepareOpeningIntact(current)) prepareOpening = null;
      else if (firstVerify) {
        // A popup that briefly opened and dismissed was acknowledged; never reopen it.
        verifyObserver = new MutationObserver(recordVerifyOpening);
        verifyObserver.observe(trigger, { attributes: true, attributeOldValue: true, attributeFilter: ['aria-expanded', 'data-state'] });
      }
    }
    const submission = globalThis.__computaChatSubmissionState, prepared = submission?.pending;
    if (!genericPowerRecheck && !mutable && request.action === 'insert' && context?.scope === 'action_final_guard'
      && completed?.completed === true && prepared?.phase === 'prepared' && prepared.firstInsertOpening == null) {
      // The prepared record spends its first post-insert observation even when
      // that opening succeeds. This never repeats editor input or Send.
      const pin = globalThis.__computaChatPresetPin;
      const composer = insertComposer(current);
      insertOpening = { owner, document: originalDocument, attempt: completed, pin, selection: pin?.selection, header: trigger,
        recoveryClaimed: false, state: submission, record: prepared, composer, editorValue: insertComposerValue(composer), prompt: request.prompt,
        canonical: prepared.canonical, fingerprint: prepared.fingerprint,
        resolved: { family: { ...pin?.selection?.family }, power: { ...pin?.selection?.power } } };
      prepared.firstInsertOpening = insertOpening;
      current = drainOpeningEvidence();
      if (!insertOpeningIntact(current)) insertOpening = null;
    }
    if (cappedFirstInsert && Date.now() >= until) throw failure('model_unverified');
    primaryOpened = true; readStage = 'primary_open_requested';
    trigger.click();
    const powerAcknowledged = () => {
      const observed = websiteChatPickerState();
      return observed.mode === 'power' || observed.mode === 'family' || observed.powerUnavailable;
    };
    if (!genericPowerRecheck && (prepareOpening !== null || insertOpening !== null)) {
      const acknowledgementDeadline = Math.min(until, Date.now() + 900);
      let clockRejected = false;
      const acknowledged = await websiteModelWaitForChange(acknowledgementDeadline,
        () => !owned() || selectionChanged || powerAcknowledged(), 'model_wait', () => { clockRejected = true; });
      current = drainOpeningEvidence();
      // A delayed acknowledgement wins; never toggle an already opened menu.
      if (!acknowledged && !powerAcknowledged()) {
        if (clockRejected || Date.now() < acknowledgementDeadline
          || !(prepareOpening !== null ? prepareOpeningIntact(current) : insertOpeningIntact(current))) throw failure('model_unverified');
        (prepareOpening || insertOpening).recoveryClaimed = true;
        readStage = firstVerify ? 'primary_open_recovery_requested' : prepareOpening !== null ? 'prepare_open_recovery_requested' : 'insert_open_recovery_requested';
        trigger.click();
        current = await wait(powerAcknowledged);
      }
    } else if (recoveryEligible) {
      // Preserve the existing fresh post-family allowance within the original
      // deadline. A consumed opening grants only one new chrome action, never
      // selection proof, a family/power retry, or an established-read replay.
      let clockRejected = false;
      const acknowledged = await websiteModelWaitForChange(Math.min(until, Date.now() + 900),
        () => !owned() || powerAcknowledged(), 'model_wait', () => { clockRejected = true; });
      if (!owned()) throw failure('document_changed');
      current = state();
      if (!acknowledged) {
        if (clockRejected || Date.now() >= until || attempt.openingRecoveryAttempted === true || freshGuard() !== true
          || current.trigger !== attempt.selectionTrigger || !current.enabled(trigger) || current.topMenu
          || current.allMenus.length || ![null, 'false'].includes(trigger.getAttribute('aria-expanded'))
          || ![null, 'closed'].includes(trigger.getAttribute('data-state'))) throw failure('model_unverified');
        attempt.openingRecoveryAttempted = true;
        readStage = 'primary_open_recovery_requested';
        trigger.click();
        current = await wait(powerAcknowledged);
      }
    } else current = await wait(powerAcknowledged);
    dismissedPopup = null;
    return current;
  };
  const familyView = async () => {
    let current = state();
    if (current.mode === 'family') return current;
    current = await openPicker();
    if (current.mode === 'family') return current;
    if (!current.secondary || !current.enabled(trigger)) throw failure('model_unverified');
    secondaryOpened = true; readStage = 'secondary_open_requested';
    current.secondary.click();
    return wait(() => websiteChatPickerState().mode === 'family');
  };
  const changePower = async target => {
    let current = await openPicker();
    if (current.mode !== 'power') throw failure('model_unverified');
    while (current.powerIndex !== target) {
      if (!mutable || Date.now() >= until || typeof window.KeyboardEvent !== 'function') throw failure('model_mismatch');
      const before = current.powerIndex, direction = target > before ? 1 : -1;
      const previousHeader = current.headerPower;
      if (attempt.powerEvents >= 4) throw failure('model_unverified');
      const powerItem = current.powerItem, slider = current.slider;
      powerItem.focus?.({ preventScroll: true });
      current = state();
      if (current.powerItem !== powerItem || current.slider !== slider || current.powerIndex !== before
        || !current.enabled(trigger) || !current.enabled(powerItem)) throw failure('model_unverified');
      attempt.powerEvents++;
      const key = direction === 1 ? 'ArrowRight' : 'ArrowLeft';
      powerItem.dispatchEvent(new window.KeyboardEvent('keydown', { key, code: key, bubbles: true, cancelable: true }));
      current = await wait(() => websiteChatPickerState().powerIndex !== before);
      if (current.powerIndex !== before + direction) throw failure('model_unverified');
      const nextPower = websiteChatPowers[current.powerIndex];
      if (current.headerPower && current.headerPower.key !== nextPower.key) {
        // React can acknowledge the slider before committing the header text.
        // Only this fresh, exact keyboard step may wait for its old header to
        // catch up. Retain every owner, product, structure and drift guard;
        // spend the original deadline without another key or picker action.
        if (Date.now() >= until) throw failure('model_unverified');
        if (!previousHeader || previousHeader.key !== websiteChatPowers[before].key
          || current.headerPower.key !== previousHeader.key || globalThis.__computaChatPresetPin || freshGuard() !== true)
          throw failure('model_mismatch');
        const popup = current.topMenu;
        // The acknowledged arrow's pending record precedes this read-only wait.
        // Every subsequent ordinal change, including a restored one, is drift.
        observer.takeRecords?.();
        changingPowerSlider = { node: slider, value: String(before + direction) };
        headerExpected = nextPower; changingPowerHeader = previousHeader;
        readStage = 'power_header_settlement_pending';
        try {
          current = await wait(() => {
            const observed = websiteChatPickerState();
            return observed.headerPower?.key !== previousHeader.key || observed.trigger !== trigger
              || observed.topMenu !== popup || observed.powerItem !== powerItem || observed.slider !== slider
              || observed.mode !== 'power' || observed.powerIndex !== before + direction
              || !observed.enabled(trigger) || !observed.enabled(powerItem);
          });
          observeHeader(headerObserver.takeRecords?.() || []);
          observeControls(observer.takeRecords?.() || []);
        } finally { changingPowerHeader = null; changingPowerSlider = null; }
        if (Date.now() >= until) throw failure('model_unverified');
        current = state();
        if (current.headerPower?.key !== nextPower.key || current.topMenu !== popup
          || current.powerItem !== powerItem || current.slider !== slider || current.mode !== 'power'
          || current.powerIndex !== before + direction || freshGuard() !== true) throw failure('model_mismatch');
        headerExpected = null; // The next owned step has its own observed predecessor.
        readStage = 'power_header_settled';
      }
    }
    return current;
  };
  try {
    let initial = state();
    if (initial.topMenu) { await close(); initial = state(); }
    // Temporary-page hydration can leave the exact visible model trigger
    // disabled while a recognized placeholder power label is rendered. Wait only
    // in this first, effect-free mutable selection and spend its original clock.
    // Enabling authorizes a fresh full picker read, never model proof by itself.
    const disabled = node => !!node && (node.disabled === true || node.getAttribute('disabled') !== null
      || node.getAttribute('aria-disabled') === 'true');
    const closedShape = current => !current.topMenu && current.allMenus.length === 0
      && [null, 'false'].includes(current.trigger?.getAttribute('aria-expanded'))
      && [null, 'closed'].includes(current.trigger?.getAttribute('data-state'));
    const disabledHeaderRecognized = websiteChatHeaderPresentation(initial.trigger?.innerText).power !== null;
    if (mutable && request.action === 'selectModel' && context?.scope === 'post_selection'
      && initial.visible(trigger) && disabled(trigger) && closedShape(initial) && disabledHeaderRecognized
      && freshGuard() === true && !globalThis.__computaChatPresetPin && globalThis.__computaModelSelection === attempt
      && attempt?.started === true && attempt.completed === false && attempt.powerEvents === 0 && attempt.familyClicked === false
      && !primaryOpened && !secondaryOpened && !closeAttempted && !observedProof) {
      const form = trigger.closest('form');
      // No selection has been observed yet. Hydration may replace this
      // canonical placeholder with another canonical remembered preset;
      // neither disabled value can pin or authorize a model selection.
      headerReadiness = { startedDisabled: true, outcome: 'waiting', reason: null };
      readStage = 'initial_trigger_disabled_wait';
      let rejected = null;
      const reject = reason => { rejected = reason; return true; };
      const ready = () => {
        if (rejected) return true;
        if (!owned()) return reject('ownership_changed');
        if (freshGuard() !== true || globalThis.__computaChatPresetPin || globalThis.__computaModelSelection !== attempt
          || attempt.completed !== false || attempt.powerEvents !== 0 || attempt.familyClicked !== false
          || primaryOpened || secondaryOpened || closeAttempted || observedProof) return reject('state_changed');
        let current;
        try { current = state(); } catch { return reject('state_changed'); }
        if (current.trigger !== trigger || !current.visible(trigger) || !closedShape(current)
          || trigger.closest('form') !== form || form && !current.physical(form)) return reject('state_changed');
        const power = websiteChatHeaderPresentation(trigger.innerText).power;
        if (!power) return reject('unknown_header');
        if (current.enabled(trigger)) return true;
        if (!disabled(trigger)) return reject('state_changed');
        return false;
      };
      const changed = await websiteModelWaitForChange(until, ready, 'model_wait', () => { rejected = 'clock_failed'; });
      if (!ready() && changed) rejected ||= 'state_changed';
      if (!changed || Date.now() >= until || rejected) {
        headerReadiness.outcome = 'rejected'; headerReadiness.reason = rejected || 'deadline';
        readStage = 'initial_trigger_disabled_rejected';
        return failure(rejected === 'ownership_changed' ? 'document_changed' : 'model_unverified');
      }
      initial = state();
      // The newly enabled current header starts the ordinary full picker proof.
      // Its associated Power and checked family still must independently agree.
      headerReadiness.outcome = 'recognized'; readStage = 'initial_trigger_ready';
    }
    // Only the first mutable selection may observe an empty, still-hydrating
    // label. Waiting spends the same proof deadline and dispatches no input.
    const initialText = websiteChatHeaderTextShape(initial.trigger?.innerText);
    if (mutable && request.action === 'selectModel' && context?.scope === 'post_selection'
      && initial.closedPresentation && initialText.present && initialText.empty && !initialText.over128
      && !globalThis.__computaChatPresetPin && globalThis.__computaModelSelection === attempt
      && attempt?.started === true && attempt.completed === false && attempt.powerEvents === 0 && attempt.familyClicked === false
      && !primaryOpened && !secondaryOpened && !closeAttempted && !observedProof) {
      headerReadiness = { startedEmpty: true, outcome: 'waiting', reason: null };
      readStage = 'initial_header_empty_wait';
      let rejected = null;
      const reject = reason => { rejected = reason; return true; };
      const ready = () => {
        if (rejected) return true;
        if (!owned()) return reject('ownership_changed');
        if (globalThis.__computaChatPresetPin || globalThis.__computaModelSelection !== attempt
          || attempt.completed !== false || attempt.powerEvents !== 0 || attempt.familyClicked !== false
          || primaryOpened || secondaryOpened || closeAttempted || observedProof) return reject('state_changed');
        let current;
        try { current = state(); } catch { return reject('state_changed'); }
        if (!current.closedPresentation || current.trigger !== trigger) return reject('state_changed');
        const text = websiteChatHeaderTextShape(current.trigger.innerText);
        if (current.headerPower || current.headerPresentation) return true;
        if (!text.present || !text.empty || text.over128) return reject('unknown_header');
        return false;
      };
      const changed = await websiteModelWaitForChange(until, ready, 'model_wait', () => { rejected = 'clock_failed'; });
      ready();
      if (!changed || Date.now() >= until || rejected) {
        headerReadiness.outcome = 'rejected';
        headerReadiness.reason = rejected || 'deadline';
        readStage = 'initial_header_empty_rejected';
        return failure(rejected === 'ownership_changed' ? 'document_changed' : 'model_unverified');
      }
      initial = state();
      headerReadiness.outcome = 'recognized';
      readStage = 'initial_header_hydrated';
    }
    if (!initial.closedPresentation || !initial.headerPower && !initial.headerPresentation) return failure('model_unverified');
    const genericHeader = !initial.headerPower;
    const headerIndex = initial.headerPower ? websiteChatPowers.findIndex(power => power.key === initial.headerPower.key) : null;
    const expectedIndex = expected ? websiteChatPowers.findIndex(power => 'chat/latest/' + power.key === expected.key) : null;
    if (expectedIndex !== null && (expectedIndex < 0 || expectedIndex > 4)) return failure('model_unverified');
    if (!mutable && headerIndex !== null && expectedIndex !== null && headerIndex !== expectedIndex) return failure('model_mismatch');
    if (!mutable && expectedIndex !== null) headerExpected = websiteChatPowers[expectedIndex];
    let powerState = await openPicker();
    // The generic label authorizes inspection only, never a requested/default
    // power. A remembered Family panel without fresh Power remains unverified.
    if (genericHeader && powerState.mode !== 'power') return failure('model_unverified');
    const startingPower = headerIndex ?? powerState.powerIndex;
    const desiredPower = expectedIndex ?? startingPower;
    if (!Number.isInteger(startingPower) || !Number.isInteger(desiredPower)) return failure('model_unverified');
    if (powerState.mode === 'power' && powerState.powerIndex !== startingPower) return failure(mutable ? 'model_unverified' : 'model_mismatch');
    if (!mutable && startingPower !== desiredPower) return failure('model_mismatch');
    if (mutable) {
      if (powerState.mode !== 'power') return failure('model_unverified');
      powerState = await changePower(desiredPower);
      headerExpected = websiteChatPowers[desiredPower];
    }
    let familyState = await familyView();
    if (!familyState.newest) return failure('model_unverified');
    if (mutable && familyState.checkedFamily?.key !== familyState.newest.key) {
      const candidates = familyState.familyControls.filter(control => control.choice?.key === familyState.newest.key);
      if (candidates.length !== 1 || attempt.familyClicked || !familyState.enabled(trigger)) return failure('model_unverified');
      attempt.familyClicked = true;
      attempt.selectionTrigger = trigger;
      candidates[0].node.click();
      await wait(() => {
        const now = websiteChatPickerState();
        return now.mode !== 'family' || now.checkedFamily?.key === now.newest?.key;
      });
      const afterSelection = state();
      if (afterSelection.mode !== 'family') await close();
      familyState = await familyView();
      if (familyState.semanticSlider && familyState.semanticSlider.getAttribute('aria-valuenow') !== String(desiredPower))
        return failure('model_mismatch');
    }
    if (!familyState.checkedFamily || familyState.checkedFamily.key !== familyState.newest.key) return failure('model_mismatch');
    const family = familyState.checkedFamily, offered = familyState.offered;
    if (genericHeader && mutable) { observer.takeRecords?.(); tracked.clear(); }
    proofLocked = true;
    for (const node of [familyState.semanticSlider, ...familyState.familyControls.map(control => control.node)].filter(Boolean))
      tracked.set(node, { 'aria-valuenow': node.getAttribute('aria-valuenow'),
        'aria-checked': node.getAttribute('aria-checked'), 'aria-selected': node.getAttribute('aria-selected') });
    const modelDiagnostic = websiteModelDiagnostic(familyState, { headerReadiness });
    observedProof = true; readStage = 'family_proof_observed';
    await close();
    let final = state();
    let finalPower = final.headerPower;
    if (final.headerPresentation && !finalPower) {
      // Family selection can reset power. Reopen once for fresh associated
      // Power proof; never repair a mismatch or invent a Back/navigation action.
      genericPowerRecheck = true;
      prepareOpening = null; insertOpening = null;
      const checkedPower = await openPicker();
      if (checkedPower.mode !== 'power' || !checkedPower.power) return failure('model_unverified');
      if (checkedPower.powerIndex !== desiredPower) return failure('model_mismatch');
      finalPower = checkedPower.power;
      finalPowerState = checkedPower;
      await close();
      observeHeader(headerObserver.takeRecords?.() || []);
      observeControls(observer.takeRecords?.() || []);
      final = state();
    }
    if (!final.closedPresentation || !final.headerPower && !final.headerPresentation || !finalPower) return failure('model_unverified');
    if (finalPower.key !== websiteChatPowers[desiredPower].key
      || final.headerPower && final.headerPower.key !== finalPower.key) return failure('model_mismatch');
    const evidence = websiteChatSelectionEvidence(family, finalPower, offered, expected);
    if (!evidence || expected && !websiteModelChoiceEqual(expected, evidence.selected)) return failure('model_mismatch');
    if (!owned() || selectionChanged || mutable && freshGuard() !== true) return failure('model_unverified');
    const pin = globalThis.__computaChatPresetPin;
    if (pin && (pin.owner !== owner || pin.document !== document || pin.invalidated === true
      || !websiteChatResolvedSelectionEqual(pin.selection, evidence.chatSelection))) return failure('model_mismatch');
    if (remount) {
      // Drain undelivered negative evidence before the synchronous reference
      // transfer. No await or website action may intervene in this commit.
      observeHeader(headerObserver.takeRecords?.() || []);
      observeControls(observer.takeRecords?.() || []);
      websiteChatDrainPinnedMutations(pin);
      const commit = state();
      if (Date.now() >= until || !owned() || selectionChanged || pin.invalidated === true
        || !pickerClosed(commit) || commit.headerPower && commit.headerPower.key !== remount.selection.power.key
        || !commit.headerPower && (!commit.headerPresentation || finalPower.key !== remount.selection.power.key)
        || !websiteChatResolvedSelectionEqual(remount.selection, evidence.chatSelection)) return failure('model_mismatch');
      pin.headerObserver?.disconnect?.();
      pin.headerObserver = null;
      pin.headerTrigger = trigger;
      websiteChatTrackPinnedHeader(pin, trigger);
      remount = null;
    }
    if (expected && !pin) {
      if (!mutable) return failure('model_unverified');
      globalThis.__computaChatPresetPin = { owner, document, selection: evidence.chatSelection };
      websiteChatTrackPinnedControls(globalThis.__computaChatPresetPin, familyState);
      if (finalPowerState) websiteChatTrackPinnedControls(globalThis.__computaChatPresetPin, finalPowerState);
      websiteChatTrackPinnedHeader(globalThis.__computaChatPresetPin, trigger);
    }
    if (cappedFirstInsert && Date.now() >= until) return failure('model_unverified');
    const provedPin = globalThis.__computaChatPresetPin;
    if (provedPin?.owner === owner && provedPin.document === originalDocument
      && provedPin.headerTrigger === trigger && provedPin.invalidated !== true
      && websiteChatResolvedSelectionEqual(provedPin.selection, evidence.chatSelection))
      provedPin.genericHeaderVerified = final.headerPresentation && !final.headerPower ? trigger : null;
    return { modelEvidence: evidence, modelChoices: websiteChatPowers.map(power => websiteChatPresetChoice(family, power)), modelDiagnostic };
  } catch (error) {
    return error?.error ? error : failure('model_unverified');
  } finally {
    verifyObserver?.disconnect?.();
    observer.disconnect?.();
    headerObserver.disconnect?.();
    if (owned() && (primaryOpened || secondaryOpened || closeAttempted)) {
      try { await close(); } catch { }
    }
  }
}
async function websiteChatPickerAction(request, fresh, freshGuard) {
  if (request.action === 'modelDiagnostic') return { modelDiagnostic: websiteModelDiagnostic(websiteChatPickerState()) };
  if (!fresh || typeof freshGuard !== 'function') return { error: 'not_fresh' };
  const discovery = request.action === 'discoverModels', choice = request.modelChoice;
  if (!discovery && !websiteChatPresetIntentValid(choice))
    return { error: 'model_unverified' };
  const slot = discovery ? '__computaModelDiscovery' : '__computaModelSelection';
  const previous = globalThis[slot];
  if (previous?.completed) {
    if (discovery) return { modelChoices: previous.choices };
    if (!websiteModelChoiceEqual(previous.choice, choice)) return { error: 'model_mismatch' };
    const result = await websiteChatObserveSelection(request, choice, null, null,
      { scope: 'completed_selection', action: request.action });
    return result.error ? result : { selected: true, modelEvidence: result.modelEvidence };
  }
  if (previous?.started) return { error: 'model_unverified' };
  const current = websiteChatPickerState();
  if (!current.trigger && current.triggerCount === 0 && current.triggerCandidates.length === 0)
    return { pending: true, modelDiagnostic: websiteModelDiagnostic(current) };
  // A fresh discovery page can expose its closed model trigger before it
  // enables it. Let the native preparation deadline and DOM wakeups bound this
  // read-only wait; do not spend a selection attempt or click a disabled row.
  if (discovery && current.triggerCount === 1 && current.triggerCandidates.length === 1
    && current.visible(current.trigger) && (current.trigger.disabled || current.trigger.getAttribute('aria-disabled') === 'true')
    && !current.topMenu && current.allMenus.length === 0 && current.physicalMenus.length === 0
    && [null, 'false'].includes(current.trigger.getAttribute('aria-expanded'))
    && [null, 'closed'].includes(current.trigger.getAttribute('data-state'))
    && !current.duplicate && !current.conflicting && !current.indicatorInvalid
    && !current.selectionAmbiguous && !current.navigationAmbiguous && freshGuard() === true)
    return { pending: true, modelDiagnostic: websiteModelDiagnostic(current) };
  const attempt = globalThis[slot] = { choice, started: true, completed: false, powerEvents: 0, familyClicked: false };
  const result = await websiteChatObserveSelection(request, discovery ? null : choice, freshGuard, attempt,
    { scope: 'post_selection', action: request.action });
  if (result.error) return result;
  attempt.completed = true;
  attempt.choices = result.modelChoices;
  return discovery ? result : { selected: true, modelEvidence: result.modelEvidence, modelDiagnostic: result.modelDiagnostic };
}
function websiteModelReadonlyChoiceValid(request) {
  return websiteModelChoiceValid(request.expectedModelChoice)
    || request.provider === 'chatgpt' && request.action === 'verifyProductMode'
      && typeof chatGPTProductModeProof === 'function'
      && chatGPTProductModeProof()?.temporaryTransition === 'acknowledged';
}
function websiteModelAcknowledgedUserAppend(request, capturedCount, currentCount, lineage = null, temporary = false) {
  const expected = request.expectedUserCounts;
  if (!['inspect', 'verifyModel', 'verifyProductMode'].includes(request.action) || !websiteModelReadonlyChoiceValid(request)
    || !Number.isInteger(capturedCount) || capturedCount < 0 || capturedCount >= 1_000
    || !Array.isArray(expected) || expected.length !== 2 || expected[0] !== capturedCount || expected[1] !== capturedCount + 1
    || currentCount !== capturedCount + 1 || globalThis.__computaModelLastSubmissionCount !== capturedCount
    || window !== window.top || document.URL !== request.expectedURL || globalThis.__computaModelOwner !== request.ownerToken
    || location.origin !== ({ chatgpt: 'https://chatgpt.com', gemini: 'https://gemini.google.com', claude: 'https://claude.ai' })[request.provider]
    || globalThis.__computaModelFirstSubmitted !== true || globalThis.__computaModelFirstMarker !== request.expectedFirstUserMarker
    || typeof request.expectedFirstUserMarker !== 'string' || !/^[a-f0-9-]{36}$/i.test(request.expectedFirstUserMarker)
    || temporary !== true) return null;
  if (capturedCount > 0) {
    const pinned = globalThis.__computaModelFirstProof;
    if (request.allowFirstUserBinding !== false || lineage?.snapshotIntact !== true
      || typeof lineage.fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(lineage.fingerprint)
      || pinned?.marker !== request.expectedFirstUserMarker || pinned.fingerprint !== lineage.fingerprint
      || request.expectedFirstUserFingerprint !== lineage.fingerprint
      || request.provider !== 'chatgpt' && pinned.identity !== lineage.identity) return null;
  } else if (request.expectedFirstUserFingerprint != null || globalThis.__computaModelFirstProof) return null;
  // Discard this observation only. It grants no lineage, response or mutation
  // authority; native must take one fresh full inspect before using any result.
  return { error: 'acknowledged_user_append', detail: 'readonly_model_observation' };
}
let websiteModelReplacementObservationAttempted = false;
async function websiteModelReplacementObservation(request, capturedCount, snapshot, access) {
  const expected = request.expectedUserCounts, pinned = globalThis.__computaModelFirstProof;
  const origin = ({ chatgpt: 'https://chatgpt.com', gemini: 'https://gemini.google.com', claude: 'https://claude.ai' })[request.provider];
  const marker = request.expectedFirstUserMarker, fingerprint = request.expectedFirstUserFingerprint;
  if (!['inspect', 'verifyModel', 'verifyProductMode'].includes(request.action) || !websiteModelReadonlyChoiceValid(request)
    || !snapshot || !Number.isInteger(capturedCount) || capturedCount < 1 || capturedCount > 1_000
    || !Array.isArray(expected) || expected.length < 1 || expected.length > 2 || !expected.includes(capturedCount)
    || expected.some(count => !Number.isInteger(count) || count < 0 || count > 1_000)
    || expected.length === 2 && expected[1] !== expected[0] + 1 || request.allowFirstUserBinding !== false
    || typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker)
    || typeof fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(fingerprint)
    || pinned?.marker !== marker || pinned.fingerprint !== fingerprint || typeof snapshot.text !== 'string'
    || snapshot.text.length > 180_200 || snapshot.root.isConnected || snapshot.body.isConnected) return null;
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  const owned = () => window === window.top && location.origin === origin && document.URL === request.expectedURL
    && globalThis.__computaModelOwner === request.ownerToken && globalThis.__computaModelFirstSubmitted === true
    && globalThis.__computaModelFirstMarker === marker && globalThis.__computaModelFirstProof?.marker === marker
    && globalThis.__computaModelFirstProof?.fingerprint === fingerprint && access.temporary() === true;
  const roots = access.roots(), root = roots[0], body = root && access.body(root);
  const text = body ? access.text(body) : '', identity = root ? access.identity(root) : null;
  const identityMatches = () => request.provider === 'chatgpt'
    || identity === snapshot.identity && globalThis.__computaModelFirstProof?.identity === snapshot.identity;
  const markerLine = `Computa session marker: ${marker}`, lines = text.split('\n');
  if (!owned() || roots.length !== capturedCount || root === snapshot.root || body === snapshot.body || !physical(root)
    || !physical(body) || text !== snapshot.text || lines.at(-1) !== markerLine
    || lines.filter(line => line === markerLine).length !== 1 || !lines.slice(0, -1).join('\n').trim()
    || !identityMatches()) return null;
  if (websiteModelReplacementObservationAttempted) return null;
  websiteModelReplacementObservationAttempted = true;
  websiteModelDiagnosticPhase('first_user_hash');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  const replacementFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const current = access.roots();
  if (!owned() || current.length !== capturedCount || current[0] !== root || access.body(root) !== body || !physical(root)
    || !physical(body) || access.text(body) !== text || access.identity(root) !== identity || !identityMatches()
    || replacementFingerprint !== fingerprint) return null;
  // Exact bytes still match both established pins, but object identity changed
  // during this read. Discard it; only a fresh full native inspect may admit.
  return { error: 'first_user_observation_replaced', detail: 'readonly_model_observation' };
}
function websiteModelFamilyLabel(provider, value) {
  const label = websiteModelNormalize(value);
  if (!label || label.length > 120 || /[\u0000-\u001F\u007F]/.test(label)) return null;
  const pattern = provider === 'chatgpt' ? /^(?:Latest|GPT-[0-9]+(?:\.[0-9]+)?(?: [A-Za-z][A-Za-z0-9-]*)?)$/
    : provider === 'gemini' ? /^[0-9]+(?:\.[0-9]+)? (?:Flash-Lite|Flash|Pro|Argon)$/
      : /^(?:Sonnet|Haiku|Opus|Fable) [0-9]+(?:\.[0-9]+)?$/;
  return pattern.test(label) ? label : null;
}
function websiteModelSafeTriggerLabel(value) {
  const label = websiteModelNormalize(value);
  if (!label || label.length > 160 || /[\u0000-\u001F\u007F]/.test(label)) return null;
  if (label === 'Select ChatGPT model') return label;
  if (/^Open mode picker, currently (?:Gemini )?(?:(?:[0-9]+(?:\.[0-9]+)? )?(?:Pro|Flash|Flash-Lite|Argon))$/.test(label)) return label;
  if (/^Model: (?:Sonnet|Haiku|Opus|Fable) [0-9]+(?:\.[0-9]+)?(?: (?:Low|Medium|High|Extra|Extended|Max))?$/.test(label)) return label;
  return null;
}
function websiteModelPickerState(provider) {
  if (provider === 'chatgpt') return websiteChatPickerState();
  const boundary = '[data-message-author-role], [data-markdown-text-style], [data-turn], [data-user-message-bubble], [data-testid="assistant-message"], [data-testid="user-message"], model-response, user-query, [role="tooltip"]';
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden';
  const visible = node => physical(node) && !node.closest('[inert], [aria-hidden="true"]');
  const outside = node => !node.closest(boundary);
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const nodes = selector => [...document.querySelectorAll(selector)].slice(0, 256);
  const isTrigger = node => {
    const label = websiteModelSafeTriggerLabel(node.getAttribute('aria-label')) || '';
    return provider === 'chatgpt' ? label === 'Select ChatGPT model'
      : provider === 'gemini' ? /^Open mode picker, currently (?:Gemini )?(?:[0-9]+(?:\.[0-9]+)? )?(?:Pro|Flash|Flash-Lite|Argon)$/.test(label)
        : /^Model: (?:Sonnet|Haiku|Opus|Fable) [0-9]+(?:\.[0-9]+)?(?: (?:Low|Medium|High|Extra|Extended|Max))?$/.test(label);
  };
  const triggerScan = nodes('button[aria-label], [role="button"][aria-label]');
  const triggers = triggerScan.filter(node => physical(node) && outside(node) && isTrigger(node));
  const triggerCandidates = nodes('button[aria-label], [role="button"][aria-label]').filter(node => physical(node) && outside(node)
    && /^(?:Select ChatGPT model(?:$|[ ,])|Open mode picker(?:$|[ ,])|Model: )/.test(websiteModelNormalize(node.getAttribute('aria-label'))));
  const trigger = triggers.length === 1 ? triggers[0] : null;
  const physicalMenus = nodes('[role="menu"], [role="listbox"], [role="dialog"]').filter(node => physical(node) && outside(node));
  const allMenus = physicalMenus.filter(visible);
  const associated = owner => allMenus.filter(menu => {
    const control = owner?.getAttribute('aria-controls'), ownerID = owner?.getAttribute('id');
    return !!owner && (control && control.length <= 256 && !/\s/.test(control) && menu.getAttribute('id') === control
      || ownerID && ownerID.length <= 256 && !/\s/.test(ownerID) && menu.getAttribute('aria-labelledby') === ownerID);
  });
  const topMenus = trigger ? associated(trigger) : [];
  const topMenu = topMenus.length === 1 ? topMenus[0] : null;
  const named = (node, value) => {
    if (provider === 'chatgpt') return websiteModelNormalize(node.getAttribute('aria-label') || node.innerText || node.textContent) === value;
    const aria = websiteModelNormalize(node.getAttribute('aria-label'));
    if (aria) return aria === value;
    const leaves = [node, ...node.querySelectorAll('span, div, p')].slice(0, 128)
      .filter(leaf => leaf.childElementCount === 0 && visible(leaf) && outside(leaf)
        && websiteModelNormalize(leaf.textContent) === value);
    return leaves.length === 1;
  };
  const secondaries = topMenu && provider !== 'gemini' ? [...topMenu.querySelectorAll('button, [role="menuitem"]')].slice(0, 256)
    .filter(node => enabled(node) && outside(node) && (provider === 'chatgpt' || node.getAttribute('aria-haspopup') === 'menu')
      && node.closest('[role="menu"], [role="listbox"], [role="dialog"]') === topMenu
      && named(node, provider === 'chatgpt' ? 'Select model' : 'More models')) : [];
  const secondary = secondaries.length === 1 ? secondaries[0] : null;
  const nestedMenus = secondary ? associated(secondary) : [];
  const nestedMenu = nestedMenus.length === 1 ? nestedMenus[0] : null;
  const menus = [topMenu, nestedMenu].filter(Boolean);
  const family = node => {
    if (!physical(node) || !outside(node)) return null;
    // The primary family leaf is distinct from descriptions, departure badges
    // and effort controls. Never infer a model from the option's combined text.
    const leaves = [node, ...node.querySelectorAll('span, div, p')].slice(0, 256)
      .filter(leaf => leaf.childElementCount === 0 && visible(leaf) && outside(leaf));
    const labels = [...new Set(leaves.map(leaf => websiteModelFamilyLabel(provider, leaf.textContent)).filter(Boolean))];
    const aria = websiteModelFamilyLabel(provider, node.getAttribute('aria-label'));
    if (aria) labels.push(aria);
    const unique = [...new Set(labels)];
    return unique.length === 1 ? { key: unique[0], label: unique[0] } : null;
  };
  const choices = [], controls = [];
  let indicatorInvalid = false, indicatorScope = false;
  for (const menu of menus) {
    const selector = '[role="menuitemradio"], [role="radio"], [role="option"]'
      + (provider === 'gemini' ? ', [role="menuitem"]' : '');
    const options = [...menu.querySelectorAll(selector)].slice(0, 128);
    for (const option of options) {
      if (!enabled(option) || !outside(option) || option.closest('[role="menu"], [role="listbox"], [role="dialog"]') !== menu) continue;
      const upgrades = [option, ...option.querySelectorAll('span, div, button, a')].slice(0, 128)
        .some(node => physical(node) && /^(?:Upgrade|Upgrade to .+|Locked|Unavailable)$/.test(websiteModelNormalize(node.getAttribute('aria-label') || node.textContent)));
      // Purchase labels may use any element tag. Text must come from
      // visible descendants of this exact row/menu; ancestor innerText can
      // include aria-hidden/inert labels or a nested foreign option.
      const purchaseScope = node => visible(node) && outside(node)
        && node.closest(selector) === option
        && node.closest('[role="menu"], [role="listbox"], [role="dialog"]') === menu;
      const purchaseLabel = node => {
        if (!purchaseScope(node)) return false;
        const aria = node.getAttribute('aria-label');
        if (aria) return /^Buy credits$/.test(websiteModelNormalize(aria));
        let remaining = 128, text = '', complete = true;
        const visit = (current, depth) => {
          if (!complete) return;
          if (--remaining < 0 || depth > 32) { complete = false; return; }
          if (current.nodeType === 3) {
            text += current.textContent || '';
            if (text.length > 256) complete = false;
          } else if (current.nodeType === 1 && purchaseScope(current)) {
            if (current.tagName === 'BR') text += '\n';
            for (const child of current.childNodes) visit(child, depth + 1);
          }
        };
        visit(node, 0);
        return complete && /^Buy credits$/.test(websiteModelNormalize(text));
      };
      const creditsRequired = provider === 'claude'
        && [option, ...option.querySelectorAll('*')].slice(0, 128).some(purchaseLabel);
      if (upgrades || creditsRequired) continue;
      const choice = family(option);
      // Gemini also selects a separate thinking-effort row in this menu.
      // Its indicator neither proves nor invalidates the model selection.
      // Keep unknown selected rows subject to the ambiguity checks below.
      if (provider === 'gemini' && !choice && option.getAttribute('role') === 'menuitem'
          && ['Low', 'High'].some(label => named(option, label))) continue;
      let indicatorSelected = false;
      if (provider === 'gemini' && option.getAttribute('role') === 'menuitem') {
        const markers = [...option.querySelectorAll('[aria-label="Selected"]')].slice(0, 128)
          .filter(marker => marker.closest('[role="menuitem"], [role="menuitemradio"], [role="radio"], [role="option"]') === option);
        const selectedClass = option.classList.contains('selected');
        indicatorScope ||= !!choice || selectedClass || markers.length > 0;
        indicatorSelected = !!choice && selectedClass && markers.length === 1 && visible(markers[0]) && outside(markers[0])
          && option.getAttribute('aria-checked') === null && option.getAttribute('aria-selected') === null;
        if ((selectedClass || markers.length > 0) && !indicatorSelected) indicatorInvalid = true;
      }
      if (choice) { choices.push(choice); controls.push({ choice, node: option, indicatorSelected }); }
    }
  }
  const duplicate = choices.some((choice, index) => choices.some((other, otherIndex) => otherIndex !== index && other.key === choice.key));
  const checked = controls.filter(control => control.node.getAttribute('role') === 'menuitem'
    ? control.indicatorSelected : control.node.getAttribute('role') === 'option'
      ? control.node.getAttribute('aria-selected') === 'true' : control.node.getAttribute('aria-checked') === 'true');
  const header = trigger && visible(trigger) ? family(trigger) : null;
  const menuSelected = checked.length === 1 ? checked[0].choice : null;
  const conflicting = !!header && !!menuSelected && !websiteModelChoiceEqual(header, menuSelected);
  const selectionAmbiguous = checked.length > 1;
  const selected = !duplicate && !conflicting && !indicatorInvalid && !selectionAmbiguous
    ? menuSelected || (!indicatorScope ? header : null) : null;
  const evidence = selected ? { selected, verification: 'website_selection', source: menuSelected
    ? checked[0].indicatorSelected ? 'selected_model_indicator' : 'checked_model_option' : 'model_picker_label' } : null;
  return { provider, trigger, triggerCount: triggers.length, triggerCandidates, topMenu, secondary, nestedMenu, menus, allMenus, physicalMenus, choices: duplicate ? [] : choices,
    controls: duplicate ? [] : controls, selected, evidence, duplicate, conflicting, indicatorInvalid, selectionAmbiguous,
    navigationAmbiguous: secondaries.length > 1, physical, visible, enabled, family, triggerScan, outside };
}
function websiteClaudeRememberModelTrigger(provider, trigger, owner, url) {
  if (provider !== 'claude') return;
  try {
    if (!trigger || typeof owner !== 'string' || !/^[a-f0-9-]{36}$/i.test(owner)
      || globalThis.__computaModelOwner !== owner || document.URL !== url) return;
    // Reference written only after an existing positive proof, for diagnostics
    // and detached-node wait eligibility. Never selection, response, action,
    // or cleanup authority: a replacement still requires fresh current proof.
    globalThis.__computaClaudeLastModelTrigger = { node: trigger, owner, document, url };
  } catch { /* Diagnostics cannot change the already evaluated proof. */ }
}
function websiteClaudeModelTriggerDiagnostic(state) {
  const empty = scope => ({ kind: 'claude_last_model_trigger_v1', scope,
    connected: null, physical: null, visible: null, nodeKind: null, labelKind: null,
    authored: null, inTriggerScan: null, triggerScanAtLimit: null });
  try {
    const record = globalThis.__computaClaudeLastModelTrigger;
    if (!record) return empty('missing');
    if (typeof record.owner !== 'string' || !/^[a-f0-9-]{36}$/i.test(record.owner)
      || record.owner !== globalThis.__computaModelOwner || record.document !== document || record.url !== document.URL)
      return empty('different_context');
    const node = record.node;
    if (!node || typeof node.getAttribute !== 'function' || typeof node.closest !== 'function') return empty('unavailable');
    const raw = node.getAttribute('aria-label');
    const label = typeof raw === 'string' && raw.length <= 512 ? websiteModelNormalize(raw) : null;
    const labelKind = raw == null || label === '' ? 'missing'
      : label?.startsWith('Model: ') && websiteModelSafeTriggerLabel(label) ? 'recognized'
      : label?.startsWith('Model: ') ? 'known_prefix_unrecognized' : 'other';
    return { kind: 'claude_last_model_trigger_v1', scope: 'same_context',
      connected: node.isConnected === true, physical: state.physical(node), visible: state.visible(node),
      nodeKind: node.tagName === 'BUTTON' ? 'button' : node.getAttribute('role') === 'button' ? 'role_button' : 'other',
      labelKind, authored: !state.outside(node),
      inTriggerScan: state.triggerScan.includes(node), triggerScanAtLimit: state.triggerScan.length === 256 };
  } catch { return empty('unavailable'); }
}
// Failure-only structural inventory. These sampled DOM facts are not ownership,
// model, completion or cleanup evidence. Never read text, arbitrary classes or
// attribute values into the result; a failed read preserves the original error.
function websiteClaudeRemountSurfaceDiagnostic(guard) {
  try {
    if (typeof guard !== 'function' || guard() !== true) return null;
    const limit = 64;
    const physical = node => !!node && node.isConnected === true && node.getClientRects().length > 0
      && !['hidden', 'collapse'].includes(getComputedStyle(node).visibility);
    const visible = node => physical(node) && !node.closest('[hidden], [inert], [aria-hidden="true"]');
    const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
    // Only fixed selector queries; do not enumerate the whole document or its text.
    const scan = (selector, scope = document) => {
      const matches = scope.querySelectorAll(selector), nodes = [];
      for (let index = 0; index < Math.min(matches.length, limit); index++) nodes.push(matches[index]);
      return { nodes, truncated: matches.length > limit };
    };
    const counts = sample => ({ sampled: sample.nodes.length, truncated: sample.truncated,
      physical: sample.nodes.filter(physical).length, visible: sample.nodes.filter(visible).length,
      enabled: sample.nodes.filter(enabled).length });
    const number = (value, min = 0) => typeof value === 'number' && Number.isFinite(value)
      ? { value: Math.max(min, Math.min(100_000, Math.trunc(value))), saturated: value < min || value > 100_000 }
      : { value: null, saturated: false };
    const enumValue = (value, allowed) => value == null ? 'unavailable' : allowed.includes(value) ? value : 'other';
    // CharacterData.length supplies UTF-16 occupancy without concatenating or
    // reading page text. Both traversal and sum are capped, including deep trees.
    const textNodes = root => {
      const stack = [{ node: root, index: 0 }];
      let utf16Units = 0, saturated = false, nodesVisited = 0, truncated = false;
      while (stack.length) {
        const frame = stack.at(-1), children = frame.node.childNodes;
        if (frame.index >= children.length) { stack.pop(); continue; }
        if (nodesVisited === limit) { truncated = true; break; }
        const child = children[frame.index++]; nodesVisited++;
        if (child.nodeType === 3) {
          const length = child.length;
          if (!Number.isSafeInteger(length) || length < 0) throw new Error('text_length_unavailable');
          saturated = saturated || utf16Units + length > 180_201;
          utf16Units = Math.min(180_201, utf16Units + length);
        } else if (child.nodeType === 1) stack.push({ node: child, index: 0 });
      }
      return { utf16Units, saturated, nodesVisited, truncated };
    };
    const shape = node => {
      const tag = node.tagName?.toLowerCase(), role = node.getAttribute('role'), testID = node.getAttribute('data-testid');
      return { tag: ['div', 'span', 'p', 'section', 'article', 'main', 'form', 'button', 'pre', 'code', 'h2', 'svg'].includes(tag) ? tag : 'other',
        role: role === null ? 'absent' : ['article', 'group', 'main', 'log', 'feed', 'region', 'presentation', 'status', 'button', 'textbox'].includes(role) ? role : 'other',
        testID: testID === null ? 'absent' : ['assistant-message', 'user-message', 'message-actions', 'action-bar-copy',
          'response-status-announcer', 'chat-input', 'chat-input-send'].includes(testID) ? testID : 'other',
        replyText: node.getAttribute('data-perf-reply-text') !== null,
        physical: physical(node), visible: visible(node), textNodes: textNodes(node) };
    };
    const labeled = scan('button[aria-label], [role="button"][aria-label]');
    const prefix = [], kinds = { recognized: 0, known_prefix_unrecognized: 0, other: 0 };
    for (const node of labeled.nodes) {
      const raw = node.getAttribute('aria-label');
      // Limit normalization work; oversized labels can establish only a literal
      // known prefix, never a recognized model. No label bytes leave this scope.
      const label = typeof raw === 'string' && raw.length <= 512 ? websiteModelNormalize(raw) : null;
      const knownPrefix = label?.startsWith('Model: ') || typeof raw === 'string' && raw.startsWith('Model: ');
      const kind = knownPrefix ? label && websiteModelSafeTriggerLabel(label) ? 'recognized' : 'known_prefix_unrecognized' : 'other';
      kinds[kind]++;
      if (knownPrefix) prefix.push(node);
    }
    const roots = scan('[data-testid="assistant-message"]');
    const rootSamples = roots.nodes.slice(0, 2).map(node => {
      const children = node.children, samples = [];
      for (let index = 0; index < Math.min(children.length, 6); index++) samples.push(shape(children[index]));
      return { ...shape(node), childrenSampled: samples.length, childrenTruncated: children.length > 6, children: samples };
    });
    const result = { kind: 'claude_remount_surface_v1', scanLimit: limit,
      document: { hidden: typeof document.hidden === 'boolean' ? document.hidden : null,
        visibility: enumValue(document.visibilityState, ['visible', 'hidden', 'prerender']),
        ready: enumValue(document.readyState, ['loading', 'interactive', 'complete']),
        width: number(window.innerWidth), height: number(window.innerHeight),
        scrollX: number(window.scrollX, -100_000), scrollY: number(window.scrollY, -100_000) },
      composers: counts(scan('[data-testid="chat-input"][contenteditable="true"][role="textbox"]')),
      stopButtons: counts(scan('button[aria-label="Stop response"]')),
      sendButtons: counts(scan('button[aria-label="Send message"]')),
      modelControls: { labeledScan: counts(labeled), labelKinds: kinds, prefix: counts({ nodes: prefix, truncated: labeled.truncated }) },
      responseRoots: { ...counts(roots), shapesTruncated: roots.truncated || roots.nodes.length > 2, shapes: rootSamples },
      renderedReplies: counts(scan('[data-testid="assistant-message"] [data-perf-reply-text]')),
      replyTextNodes: counts(scan('[data-perf-reply-text]')) };
    return guard() === true ? result : null;
  } catch { return null; }
}
function websiteModelDiagnostic(state, readObservation = null) {
  const allowedTags = ['button', 'div', 'span', 'p', 'ul', 'li', 'dialog', 'section', 'svg', 'path', 'mat-icon'];
  const allowedRoles = ['button', 'menu', 'menuitem', 'menuitemradio', 'radio', 'listbox', 'option', 'dialog'];
  const shape = node => ({ tag: allowedTags.includes(node.tagName.toLowerCase()) ? node.tagName.toLowerCase() : 'other',
    role: allowedRoles.includes(node.getAttribute('role')) ? node.getAttribute('role') : null,
    visible: state.visible(node), enabled: state.enabled(node),
    attributeNames: [...node.attributes].map(attribute => attribute.name)
      .filter(name => /^(?:aria-(?:controls|label|labelledby|describedby|checked|selected|expanded|disabled|haspopup|hidden)|data-(?:testid|test-id|model-id|model-slug|model|state)|id|role|class)$/.test(name)).slice(0, 16),
    classes: [...node.classList].filter(name => /^[A-Za-z0-9_-]{1,48}$/.test(name)).slice(0, 6),
    popupRole: ['menu', 'listbox', 'dialog', 'true'].includes(node.getAttribute('aria-haspopup')) ? node.getAttribute('aria-haspopup') : null,
    controlsAssociated: !!node.getAttribute('aria-controls') && state.allMenus.some(menu => menu.getAttribute('id') === node.getAttribute('aria-controls')),
    checked: node.getAttribute('aria-checked') === 'true', selected: node.getAttribute('aria-selected') === 'true',
    checkedAttribute: ['true', 'false', 'mixed'].includes(node.getAttribute('aria-checked')) ? node.getAttribute('aria-checked') : null,
    dataState: ['checked', 'unchecked', 'open', 'closed'].includes(node.getAttribute('data-state')) ? node.getAttribute('data-state') : null,
    primaryFamily: state.family(node)?.label || null });
  const navigationCandidates = state.menus.flatMap(menu => [...menu.querySelectorAll('button, [role="menuitem"], [aria-haspopup]')].slice(0, 64))
    .map(node => ({ node, labels: [node, ...node.querySelectorAll('span, div')].slice(0, 64)
      .filter(leaf => leaf.childElementCount === 0).map(leaf => websiteModelNormalize(leaf.textContent))
      .filter(label => ['Select model', 'More models'].includes(label)) }))
    .filter(candidate => candidate.labels.length);
  const rawOptions = state.menus.flatMap(menu => [...menu.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="radio"], [role="option"]')].slice(0, 128)
    .filter(node => node.closest('[role="menu"], [role="listbox"], [role="dialog"]') === menu));
  const rawOptionShape = node => {
    const contents = [node, ...node.querySelectorAll('span, div, p')].slice(0, 128);
    const contentShape = child => {
      const result = shape(child);
      return { tag: result.tag, role: result.role, attributeNames: result.attributeNames.slice(0, 6), classes: result.classes.slice(0, 3) };
    };
    const recognizedContainers = contents.filter(child => state.physical(child)
      && websiteModelFamilyLabel(state.provider, child.textContent)).slice(0, 4)
      .map(child => ({ ...contentShape(child), family: websiteModelFamilyLabel(state.provider, child.textContent),
        childElementCount: Math.min(child.childElementCount, 16) }));
    const selectedMarkers = [node, ...node.querySelectorAll('span, div, svg, mat-icon, [aria-label]')].slice(0, 128)
      .filter(child => child.getAttribute('aria-label') === 'Selected'
        || child.childElementCount === 0 && websiteModelNormalize(child.textContent) === 'Selected')
      .slice(0, 3).map(child => ({ ...contentShape(child), kind: 'selected_label' }));
    return { ...shape(node), recognizedContainers, selectedMarkers };
  };
  const rawFamilySummary = rawOptions.slice(0, 16).map(node => {
    const result = rawOptionShape(node);
    return { role: result.role, visible: result.visible, enabled: result.enabled, checkedAttribute: result.checkedAttribute,
      primaryFamily: result.primaryFamily, recognizedFamily: result.recognizedContainers[0]?.family || null,
      selectedMarkerCount: result.selectedMarkers.length, dataState: result.dataState };
  });
  const diagnostic = { kind: 'model_picker_structure', provider: state.provider, triggerCount: state.triggerCount,
    trigger: state.trigger ? shape(state.trigger) : null,
    triggerCandidates: state.triggerCandidates.slice(0, 4).map(node => ({ ...shape(node),
      labelKind: websiteModelNormalize(node.getAttribute('aria-label')).startsWith('Open mode picker') ? 'gemini_mode_picker'
        : websiteModelNormalize(node.getAttribute('aria-label')).startsWith('Model: ') ? 'claude_model_picker' : 'chatgpt_model_picker',
      safeLabel: websiteModelSafeTriggerLabel(node.getAttribute('aria-label')),
      labelLength: Math.min(websiteModelNormalize(node.getAttribute('aria-label')).length, 256) })),
    associatedMenus: state.menus.map(shape), duplicate: state.duplicate, conflicting: state.conflicting,
    indicatorInvalid: state.indicatorInvalid, selectionAmbiguous: state.selectionAmbiguous, navigationAmbiguous: state.navigationAmbiguous,
    rawOptionCount: rawOptions.length, rawFamilySummary, rawOptions: rawOptions.slice(0, 12).map(rawOptionShape),
    navigationCandidates: navigationCandidates.slice(0, 4).map(candidate => ({ ...shape(candidate.node), navigationLabel: candidate.labels[0] })),
    unassociatedMenus: state.trigger ? state.allMenus.filter(menu => !state.menus.includes(menu)).slice(0, 4)
      .map(menu => ({ ...shape(menu), primaryFamily: null,
        descendants: [...menu.querySelectorAll('button, [role="menuitem"], [role="menuitemradio"], [role="radio"], [role="option"]')].slice(0, 8)
          .map(node => ({ ...shape(node), primaryFamily: null })) })) : [],
    candidates: state.controls.slice(0, 16).map(control => shape(control.node)) };
  if (readObservation) {
    diagnostic.readStage = readObservation.readStage;
    diagnostic.readAttempt = readObservation.readAttempt;
    diagnostic.readContext = readObservation.readContext;
    if (state.provider === 'claude' && readObservation.remountObservation)
      diagnostic.remountObservation = readObservation.remountObservation;
  }
  if (state.provider === 'claude') diagnostic.lastModelTrigger = websiteClaudeModelTriggerDiagnostic(state);
  if (state.provider === 'chatgpt') {
    diagnostic.chatPower = state.powerDiagnostic;
    const pin = globalThis.__computaChatPresetPin;
    diagnostic.chatPin = {
      present: !!pin, invalidated: pin?.invalidated === true,
      invalidationReason: ['header_replaced', 'header_mutation', 'semantic_mutation'].includes(pin?.invalidationReason)
        ? pin.invalidationReason : null,
      sameHeader: !!pin?.headerTrigger && pin.headerTrigger === state.trigger,
      headerConnected: pin?.headerTrigger?.isConnected === true,
      semantic: pin?.invalidationReason === 'semantic_mutation'
        && ['aria-valuenow', 'aria-checked'].includes(pin?.invalidationFacts?.attribute)
        && ['nodeConnected', 'attributePresent', 'currentMatches', 'oldMatches']
          .every(key => typeof pin.invalidationFacts[key] === 'boolean')
        ? { attribute: pin.invalidationFacts.attribute,
          nodeConnected: pin.invalidationFacts.nodeConnected, attributePresent: pin.invalidationFacts.attributePresent,
          currentMatches: pin.invalidationFacts.currentMatches, oldMatches: pin.invalidationFacts.oldMatches } : null,
    };
    diagnostic.chatHeader = { canonicalRecognized: !!state.headerPower, closed: state.closedPresentation,
      openPresentationRecognized: state.headerPresentation,
      presentation: websiteChatHeaderPresentation(state.trigger?.innerText).kind,
      ordinal: state.headerPower ? websiteChatPowers.findIndex(power => power.key === state.headerPower.key) : null,
      menuMode: ['power', 'family', 'unknown', 'closed'].includes(state.mode) ? state.mode : 'unknown' };
    const header = state.trigger;
    const headerChildren = [];
    for (let index = 0; index < Math.min(header?.childNodes?.length || 0, 4); index++)
      headerChildren.push(header.childNodes[index]);
    diagnostic.chatHeader.textShape = {
      innerText: websiteChatHeaderTextShape(header?.innerText), textContent: websiteChatHeaderTextShape(header?.textContent),
      childCount: Math.min(header?.childNodes?.length || 0, 33),
      children: headerChildren.map(node => ({
        kind: node.nodeType === 1 ? 'element' : node.nodeType === 3 ? 'text' : 'other',
        tag: ['span', 'div', 'svg', 'path'].includes(node.tagName?.toLowerCase()) ? node.tagName.toLowerCase() : 'other',
        visible: node.nodeType === 1 ? state.visible(node) : null,
        text: websiteChatHeaderTextShape(node.textContent) })) };
    const readiness = readObservation?.headerReadiness;
    if ((readiness?.startedEmpty === true || readiness?.startedDisabled === true)
      && ['waiting', 'recognized', 'rejected'].includes(readiness.outcome))
      diagnostic.chatHeader.readiness = { ...(readiness.startedDisabled === true ? { startedDisabled: true } : { startedEmpty: true }), outcome: readiness.outcome,
        reason: ['ownership_changed', 'state_changed', 'unknown_header', 'deadline', 'clock_failed'].includes(readiness.reason)
          ? readiness.reason : null };
  }
  const responseRoots = state.provider === 'chatgpt' ? chatGPTMessageRoots('assistant')
    : [...document.querySelectorAll(state.provider === 'claude' ? '[data-testid="assistant-message"]' : 'model-response')];
  const root = responseRoots.filter(node => state.physical(node)).at(-1);
  diagnostic.responseMetadata = root ? {
    present: true, tag: /^[A-Za-z][A-Za-z0-9-]{0,31}$/.test(root.tagName) ? root.tagName.toLowerCase() : 'other',
    modelAttributes: [...root.attributes].filter(attribute => /^[A-Za-z][A-Za-z0-9_:.-]{0,63}$/.test(attribute.name) && /model/i.test(attribute.name))
      .slice(0, 8).map(attribute => ({ name: attribute.name,
        recognizedFamily: websiteModelFamilyLabel(state.provider, attribute.value),
        valueLength: Math.min((attribute.value || '').length, 512) }))
  } : { present: false, modelAttributes: [] };
  while (JSON.stringify(diagnostic).length > 8_192) {
    const last = diagnostic.unassociatedMenus.at(-1);
    if (last?.descendants.length) last.descendants.pop();
    else if (diagnostic.unassociatedMenus.length) diagnostic.unassociatedMenus.pop();
    else if (diagnostic.candidates.length) diagnostic.candidates.pop();
    else if (diagnostic.rawOptions.length) diagnostic.rawOptions.pop();
    else if (diagnostic.associatedMenus.length) diagnostic.associatedMenus.pop();
    else if (diagnostic.navigationCandidates.length) diagnostic.navigationCandidates.pop();
    else if (diagnostic.triggerCandidates.length) diagnostic.triggerCandidates.pop();
    else if (diagnostic.rawFamilySummary.length) diagnostic.rawFamilySummary.pop();
    else break;
  }
  return diagnostic;
}
function websiteModelDismissOwnedPicker(provider, trigger, menu) {
  if (provider === 'chatgpt' || provider === 'claude') {
    if (typeof window.KeyboardEvent !== 'function' || !menu?.dispatchEvent) return false;
    // Selection may already be closing this popup. A trigger toggle could
    // reopen it; Escape only dismisses the exact associated popup. The caller
    // still requires observed physical closure and the same restored trigger.
    menu.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true, cancelable: true }));
  } else trigger.click();
  return true;
}
function websiteModelGuard(state, expected) {
  if (expected == null) return null;
  if (!websiteModelChoiceValid(expected)) return { error: 'model_unverified' };
  if (!state.selected) return { error: 'model_unverified', modelDiagnostic: websiteModelDiagnostic(state) };
  if (!websiteModelChoiceEqual(state.selected, expected)) return { error: 'model_mismatch', modelEvidence: state.evidence };
  return null;
}
function websiteModelWaitForChange(until, condition, phase = 'model_wait', onClockFailure = null, observeEditorControls = false) {
  if (condition()) return Promise.resolve(true);
  websiteModelDiagnosticPhase(phase);
  return new Promise(resolve => {
    let finished = false, timer;
    const observer = new MutationObserver(() => { if (condition()) finish(true); });
    const finish = changed => {
      if (finished) return;
      finished = true;
      observer.disconnect?.();
      if (typeof clearTimeout === 'function') clearTimeout(timer);
      websiteModelDiagnosticPhase('model_wait_done');
      resolve(changed);
    };
    observer.observe(document.documentElement || document, { subtree: true, childList: true, characterData: true,
      attributes: true, attributeFilter: ['aria-expanded', 'aria-hidden', 'aria-controls', 'aria-labelledby', 'aria-checked',
        'aria-selected', 'aria-valuenow', 'aria-valuemin', 'aria-valuemax', 'aria-label', 'aria-disabled', 'disabled', 'data-state', 'role', 'class', 'style', 'hidden', 'inert',
        ...(observeEditorControls === true ? ['id', 'contenteditable', 'data-testid'] : [])] });
    const milliseconds = Math.max(1, Math.min(10_000, Math.ceil(until - Date.now())));
    const clock = window.webkit?.messageHandlers?.computaModelClock;
    if (clock && typeof input?.operationID === 'string') {
      try {
        // A native reply expires this wait only. All existing conditions and
        // model/owner guards must still supply their own positive proof.
        Promise.resolve(clock.postMessage({ ownerToken: input.ownerToken,
          operationID: input.operationID, milliseconds })).then(() => finish(false), () => {
            if (!finished) { onClockFailure?.(); finish(false); }
          });
      } catch { onClockFailure?.(); finish(false); }
    } else {
      // Standalone fixtures and nonnative adapters retain the bounded fallback.
      timer = setTimeout(() => finish(false), milliseconds);
    }
    if (condition()) finish(true); // A synchronous mount cannot fall between read and arm.
  });
}
async function websiteModelSettleSelection(provider, attempt, freshGuard, until) {
  let readStage = 'selection_close_requested';
  const current = () => websiteModelPickerState(provider);
  const unchanged = () => window === window.top && document.URL === attempt.selectionURL
    && location.origin === attempt.selectionOrigin && globalThis.__computaModelOwner === attempt.selectionOwner
    && typeof freshGuard === 'function' && freshGuard(false) === true;
  const closed = () => {
    const state = current();
    return unchanged() && freshGuard() === true && state.triggerCount === 1
      && state.trigger === attempt.selectionTrigger && state.enabled(state.trigger)
      && !state.topMenu && state.allMenus.length === 0
      && [null, 'false'].includes(state.trigger.getAttribute('aria-expanded'))
      && [null, 'closed'].includes(state.trigger.getAttribute('data-state'));
  };
  const failure = () => {
    const state = current();
    return { error: 'model_unverified', modelDiagnostic: websiteModelDiagnostic(state, { readStage,
      readAttempt: { primaryOpened: false, secondaryOpened: false, closeAttempted: attempt.selectionCloseAttempted === true, observedProof: false,
        sameTrigger: state.trigger === attempt.selectionTrigger, popupStillAssociated: !!state.topMenu } }) };
  };
  // A failed or interrupted commit observation cannot be replayed by another
  // pending-stage invocation. This state carries no selected-model evidence.
  if (attempt.settleAttempted) { readStage = 'selection_commit_unconfirmed'; return failure(); }
  attempt.settleAttempted = true;
  const state = current();
  if (!unchanged() || state.triggerCount !== 1 || state.trigger !== attempt.selectionTrigger || !state.physical(state.trigger)
    || state.trigger.disabled || state.trigger.getAttribute('aria-disabled') === 'true'
    || state.duplicate || state.conflicting || state.indicatorInvalid || state.selectionAmbiguous || state.navigationAmbiguous
    || state.allMenus.some(menu => !state.menus.includes(menu))) {
    readStage = 'selection_commit_unconfirmed'; return failure();
  }
  // ChatGPT can return from its family panel to the still-open power popup.
  // Dismiss only that exact associated parent, once, before the fresh read.
  if (state.topMenu) {
    if (attempt.selectionCloseAttempted) { readStage = 'selection_commit_unconfirmed'; return failure(); }
    attempt.selectionCloseAttempted = true;
    websiteModelTrackReadUI(state);
    if (!websiteModelDismissOwnedPicker(provider, state.trigger, state.nestedMenu || state.topMenu)) {
      readStage = 'selection_commit_unconfirmed'; return failure();
    }
  }
  const acknowledged = await websiteModelWaitForChange(until, () => !unchanged() || closed());
  if (!acknowledged || !closed()) { readStage = 'selection_commit_unconfirmed'; return failure(); }
  attempt.settled = true;
  return null;
}
function websiteModelTrackReadUI(state) {
  const previous = globalThis.__computaModelReadUI;
  const scope = previous?.until > Date.now() ? previous : { until: 0, roots: [], ids: [] };
  scope.until = Date.now() + 300;
  scope.provider = state.provider;
  for (const node of [state.trigger, state.secondary, ...state.menus].filter(Boolean)) {
    scope.roots = [...scope.roots.filter(previousNode => previousNode !== node), node].slice(-16);
    const controlled = node.getAttribute('aria-controls');
    if (controlled && controlled.length <= 256 && !/\s/.test(controlled))
      scope.ids = [...scope.ids.filter(previousID => previousID !== controlled), controlled].slice(-16);
  }
  globalThis.__computaModelReadUI = scope;
}
function websiteModelIgnoreOwnPickerMutation(record) {
  const scope = globalThis.__computaModelReadUI;
  if (!scope || scope.until < Date.now() || !record?.target) return false;
  const boundary = '[data-message-author-role], [data-markdown-text-style], [data-turn], [data-user-message-bubble], [data-testid="assistant-message"], [data-testid="user-message"], model-response, user-query';
  const target = record.target.nodeType === 1 ? record.target : record.target.parentElement;
  if (!target || target.closest?.(boundary)) return false;
  const belongs = node => !!node && scope.roots.some(root => root === node || root.contains(node));
  const controlledPortal = node => {
    const menu = node.closest?.('[role="menu"], [role="dialog"], [role="listbox"]');
    return !!menu && scope.ids.includes(menu.getAttribute('id'))
      && !menu.closest?.(boundary) && !menu.querySelector?.(boundary);
  };
  if (record.type === 'attributes') {
    // Real selection/fallback attributes and response content always wake the
    // native reader. Only this observation's menu visibility/chrome is omitted.
    if (!['aria-expanded', 'aria-hidden', 'aria-controls', 'aria-labelledby', 'class', 'style', 'hidden', 'inert', 'data-state'].includes(record.attributeName)) return false;
    const ownedChrome = belongs(target) || controlledPortal(target);
    if (scope.provider === 'gemini' && record.attributeName === 'class' && target.isConnected
      && target.getAttribute('role') === 'menuitem' && ownedChrome) {
      // Gemini's actual model rows use a selected token plus an aria-labelled
      // icon, not checked radios. Active/focus changes remain picker chrome.
      if (record.oldValue === undefined || /(?:^|\s)selected(?:\s|$)/.test(record.oldValue || '') !== target.classList.contains('selected')) return false;
    }
    // A newly mounted portal can deliver visibility records before the next
    // awaited read tracks its root. Its exact aria-controls ID owns only this
    // chrome; selected attributes and message boundaries still notify above.
    return ownedChrome || ['aria-hidden', 'inert', 'style'].includes(record.attributeName)
      && scope.roots.some(root => target.contains(root));
  }
  if (record.type !== 'childList') return false;
  const changed = [...(record.addedNodes || []), ...(record.removedNodes || [])];
  if (!changed.length) return false;
  const row = target.closest('[role="menuitem"]');
  if (scope.provider === 'gemini' && target.isConnected && row?.isConnected && belongs(row)
    && changed.some(node => node.nodeType === 1 && (node.getAttribute('aria-label') === 'Selected'
      || !!node.querySelector('[aria-label="Selected"]')))) return false;
  const portal = node => {
    if (node.nodeType !== 1 || node.closest?.(boundary) || node.querySelector?.(boundary)) return false;
    if (belongs(node)) return true;
    return [node, ...node.querySelectorAll('[role="menu"], [role="dialog"], [role="listbox"]')].slice(0, 64)
      .some(menu => scope.ids.includes(menu.getAttribute('id')));
  };
  return changed.every(node => portal(node) || belongs(target)
    && !(node.nodeType === 1 && (node.closest?.(boundary) || node.querySelector?.(boundary))));
}
function websiteModelHitTestTarget(node) {
  if (!node || typeof node.getBoundingClientRect !== 'function' || typeof document.elementFromPoint !== 'function') return false;
  try {
    const rect = node.getBoundingClientRect(), x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
    if (![rect.left, rect.top, rect.width, rect.height, x, y].every(Number.isFinite)
      || rect.width <= 0 || rect.height <= 0) return false;
    const hit = document.elementFromPoint(x, y);
    return !!hit && node.contains(hit);
  } catch { return false; }
}
async function websiteModelReadEvidence(provider, expected, openingRecovery = null, context = null) {
  websiteModelDiagnosticPhase('model_proof');
  if (provider === 'chatgpt') {
    if (!websiteChatPresetIntentValid(expected))
      return { error: 'model_unverified' };
    const result = await websiteChatObserveSelection(input, expected, null, null, context);
    return result.error ? result : { modelEvidence: result.modelEvidence };
  }
  if (!websiteModelChoiceValid(expected)) return { error: 'model_unverified' };
  const owner = globalThis.__computaModelOwner, url = document.URL;
  const recovery = provider === 'chatgpt' && openingRecovery?.attempt?.clicked === true
    && openingRecovery.attempt.settled === true && openingRecovery.attempt.completed !== true
    && typeof openingRecovery.guard === 'function' ? openingRecovery : null;
  const readDocument = document;
  let claudeRemountStarted = false, claudeRemountTrigger = null, remountObservation = null;
  const submittedReadIntact = () => {
    try { return context.claudeSubmittedReadGuard() === true; } catch { return false; }
  };
  const unchanged = () => window === window.top && document === readDocument && document.URL === url && globalThis.__computaModelOwner === owner
    && (!recovery || recovery.guard(false) === true) && (!claudeRemountStarted || submittedReadIntact());
  const detachedClaudeTrigger = () => {
    try {
      const record = globalThis.__computaClaudeLastModelTrigger;
      if (!record || typeof record !== 'object' || Object.keys(record).length !== 4
        || !['node', 'owner', 'document', 'url'].every(key => Object.getOwnPropertyDescriptor(record, key)?.value !== undefined)
        || record.owner !== owner || record.document !== readDocument || record.url !== url) return false;
      const node = record.node;
      return !!node && node.nodeType === 1 && typeof node.getAttribute === 'function'
        && typeof node.closest === 'function' && node.isConnected === false;
    } catch { return false; }
  };
  const remountProofError = current => {
    if (Date.now() >= until || !unchanged() || current.trigger !== claudeRemountTrigger
      || current.triggerScan.length >= 256 || current.triggerCount !== 1 || current.triggerCandidates.length !== 1 || current.triggerCandidates[0] !== current.trigger
      || current.duplicate || current.conflicting || current.indicatorInvalid || current.selectionAmbiguous || current.navigationAmbiguous
      || current.physicalMenus.length || current.allMenus.length || !current.enabled(current.trigger)
      || ![null, 'false'].includes(current.trigger.getAttribute('aria-expanded'))
      || ![null, 'closed'].includes(current.trigger.getAttribute('data-state')) || !current.evidence) return 'model_unverified';
    return websiteModelChoiceEqual(current.evidence.selected, expected) ? null : 'model_mismatch';
  };
  const until = recovery ? recovery.until : Date.now() + 1_800;
  let primaryOpened = false, secondaryOpened = false, closeAttempted = false, trigger = null, captured = null;
  const ownedMenus = new Set(), popupOwners = new Set(), ownedMenuIDs = new Set(), popupOwnerIDs = new Set();
  const rememberID = (set, value) => { if (value && value.length <= 256 && !/\s/.test(value)) set.add(value); };
  const trackOwnedMenus = current => {
    if (provider !== 'claude' || !current.trigger || current.triggerCount !== 1
      || trigger && current.trigger !== trigger) return;
    for (const menu of current.menus) { ownedMenus.add(menu); rememberID(ownedMenuIDs, menu.getAttribute('id')); }
    for (const owner of [current.trigger, current.secondary].filter(Boolean)) {
      popupOwners.add(owner);
      rememberID(popupOwnerIDs, owner.getAttribute('id'));
      rememberID(ownedMenuIDs, owner.getAttribute('aria-controls'));
    }
  };
  let readStage = 'initial_observation';
  let state = websiteModelPickerState(provider);
  const failure = error => {
    const current = websiteModelPickerState(provider);
    const selection = globalThis.__computaModelSelection;
    const selectionPresent = !!selection && typeof selection === 'object';
    return { error, modelDiagnostic: websiteModelDiagnostic(current, { readStage,
      readContext: {
        scope: ['action_precheck', 'action_final_guard', 'completed_selection', 'post_selection'].includes(context?.scope)
          ? context.scope : 'unknown',
        action: ['inspect', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop', 'discoverModels',
          'selectModel', 'modelDiagnostic', 'verifyModel'].includes(context?.action) ? context.action : 'unknown',
        selectionAttemptPresent: selectionPresent, selectionClicked: selectionPresent && selection.clicked === true,
        selectionSettled: selectionPresent && selection.settled === true, selectionCompleted: selectionPresent && selection.completed === true,
        recoveryEligible: !!recovery },
      ...(remountObservation ? { remountObservation } : {}),
      readAttempt: { primaryOpened, secondaryOpened, closeAttempted, observedProof: !!captured,
        sameTrigger: !trigger || current.trigger === trigger, popupStillAssociated: !!current.topMenu } }),
      ...(captured ? { modelEvidence: captured } : {}) };
  };
  const claudeComposerUnobstructed = current => {
    // Nonmodal ARIA alone cannot rule out an overlay. When another dialog
    // remains, require the actual composer to be exposed by a fresh hit-test.
    const composers = [...document.querySelectorAll('[data-testid="chat-input"][contenteditable="true"][role="textbox"]')].slice(0, 3)
      .filter(node => current.enabled(node) && !node.closest('[data-testid="assistant-message"], [data-testid="user-message"], [role="dialog"], dialog'));
    return composers.length === 1 && websiteModelHitTestTarget(composers[0]);
  };
  const pickerClosed = current => {
    // Claude may mount an unrelated nonmodal dialog while closing its picker.
    // Losing aria-controls is not closure: every exact popup observed in this
    // read must be physically hidden or disconnected before admitting proof.
    const popupsClosed = provider === 'claude' && ownedMenus.size > 0
      ? [...ownedMenus].every(menu => !current.physical(menu)) && !current.topMenu && !current.nestedMenu
        && current.physicalMenus.every(menu => {
          const labelledBy = menu.getAttribute('aria-labelledby') || '';
          const labels = labelledBy.trim() ? labelledBy.trim().split(/\s+/) : [];
          if (labelledBy.length > 1_024 || labels.length > 16 || labels.some(id => id.length > 256)) return false;
          return menu.getAttribute('role') === 'dialog' && menu.getAttribute('aria-modal') !== 'true'
            && !(menu.tagName.toLowerCase() === 'dialog' && menu.getAttribute('open') !== null)
            && !ownedMenuIDs.has(menu.getAttribute('id')) && !labels.some(id => popupOwnerIDs.has(id))
            && [...popupOwners].every(owner => {
              const controls = owner.getAttribute('aria-controls'), ownerID = owner.getAttribute('id');
              return !(controls && controls.length <= 256 && !/\s/.test(controls) && menu.getAttribute('id') === controls
                || ownerID && ownerID.length <= 256 && !/\s/.test(ownerID) && labels.includes(ownerID));
            });
        }) && (current.physicalMenus.length === 0 || claudeComposerUnobstructed(current))
      : current.allMenus.length === 0;
    return !!trigger && current.trigger === trigger && current.enabled(trigger) && popupsClosed
      && [null, 'false'].includes(trigger.getAttribute('aria-expanded'))
      && [null, 'closed'].includes(trigger.getAttribute('data-state'));
  };
  const waitForClosedPicker = async () => {
    const acknowledged = await websiteModelWaitForChange(until,
      () => !unchanged() || pickerClosed(websiteModelPickerState(provider)));
    const closed = acknowledged && unchanged() && pickerClosed(websiteModelPickerState(provider));
    readStage = closed ? 'close_acknowledged' : 'close_unconfirmed';
    return closed;
  };
  const closeOwned = async () => {
    const current = websiteModelPickerState(provider);
    if (!unchanged()) return false;
    // This new read-only branch must never dismiss or open a popup, even if
    // one appears after the replacement header was observed.
    if (claudeRemountStarted) return remountProofError(current) === null;
    if (!trigger || current.trigger !== trigger || !current.physical(trigger) || trigger.disabled
      || trigger.getAttribute('aria-disabled') === 'true') return false;
    if (!current.topMenu) {
      if (pickerClosed(current)) return true;
      readStage = 'close_settlement_pending';
      return waitForClosedPicker();
    }
    // This exact controlled picker may be aria-hidden while its modal portal is
    // open. Its previously verified association, not background text, owns close.
    if (closeAttempted) return false;
    closeAttempted = true; // A lost close acknowledgment cannot toggle this picker open again.
    readStage = 'close_requested';
    if (!websiteModelDismissOwnedPicker(provider, trigger, current.nestedMenu || current.topMenu)) return false;
    // Portal removal can precede the trigger's closing commit. Wait for both
    // observed states before another proof read may open this picker.
    return waitForClosedPicker();
  };
  try {
    // Claude can detach its model header after the acknowledged first Send.
    // A bounded, action-free DOM wait may observe its replacement, but never
    // promotes the remembered diagnostic node or a timer into model evidence.
    if (provider === 'claude' && context?.scope === 'action_precheck'
      && ['inspect', 'verifyModel'].includes(context.action) && typeof context.claudeSubmittedReadGuard === 'function'
      && !state.trigger && state.triggerCount === 0 && state.triggerCandidates.length === 0
      && state.triggerScan.length < 256 && detachedClaudeTrigger()) {
      claudeRemountStarted = true;
      readStage = 'trigger_remount_waiting';
      let rejection = null;
      // Losing absence eligibility is permanent for this read, but does not
      // reject a later exact header with ordinary fresh positive proof.
      let noOutputPendingEligible = input.allowClaudeModelObservationPending === true
        && context.action === 'inspect' && typeof context.claudeNoOutputPending === 'function';
      // Diagnostic rereads only. No extra observer, timer or action is installed,
      // and these snapshots never supply model, ownership or completion proof.
      const diagnosticStarted = Date.now();
      let observations = 0;
      const completionDiagnostic = () => {
        try { return context.claudeRemountCompletionDiagnostic?.() ?? null; } catch { return null; }
      };
      const entry = completionDiagnostic();
      const observeRemount = () => {
        observations = Math.min(observations + 1, 1_000);
        if (rejection) return true;
        if (!unchanged()) { rejection = 'model_unverified'; return true; }
        if (noOutputPendingEligible) {
          try {
            const absent = context.claudeNoOutputPending();
            if (!absent || typeof absent.busy !== 'boolean') noOutputPendingEligible = false;
          } catch { noOutputPendingEligible = false; }
        }
        const current = websiteModelPickerState(provider);
        if (current.triggerScan.length >= 256 || current.duplicate || current.conflicting || current.indicatorInvalid || current.selectionAmbiguous
          || current.navigationAmbiguous || current.physicalMenus.length || current.allMenus.length) {
          rejection = 'model_unverified'; return true;
        }
        if (!current.trigger && current.triggerCount === 0 && current.triggerCandidates.length === 0) return false;
        if (current.triggerCount !== 1 || current.triggerCandidates.length !== 1
          || current.triggerCandidates[0] !== current.trigger || !current.enabled(current.trigger)
          || ![null, 'false'].includes(current.trigger.getAttribute('aria-expanded'))
          || ![null, 'closed'].includes(current.trigger.getAttribute('data-state')) || !current.evidence) {
          rejection = 'model_unverified'; return true;
        }
        if (!websiteModelChoiceEqual(current.evidence.selected, expected)) {
          rejection = 'model_mismatch'; return true;
        }
        // Identity is pinned only after this current node provides exact proof;
        // the ordinary read below must independently observe it again.
        if (claudeRemountTrigger && claudeRemountTrigger !== current.trigger) {
          rejection = 'model_unverified'; return true;
        }
        claudeRemountTrigger = current.trigger;
        return true;
      };
      const changed = await websiteModelWaitForChange(until, observeRemount, 'model_wait',
        () => { rejection = 'model_unverified'; });
      if (!changed || Date.now() >= until || !observeRemount() || rejection) {
        // Only an expired absence observation may return no-output pending.
        // The native permission and fresh semantic callback cannot convert a
        // mismatch, clock error, popup or previously observed context loss.
        if (changed === false && !rejection && !claudeRemountTrigger && noOutputPendingEligible
          && input.allowClaudeModelObservationPending === true && context.scope === 'action_precheck'
          && context.action === 'inspect' && typeof context.claudeNoOutputPending === 'function'
          && unchanged() && detachedClaudeTrigger() && observeRemount() === false) {
          let pending = null;
          try { pending = context.claudeNoOutputPending(); } catch { /* Preserve failure. */ }
          if (pending && typeof pending.busy === 'boolean' && !rejection
            && unchanged() && detachedClaudeTrigger() && observeRemount() === false && !rejection && noOutputPendingEligible)
            return { claudeModelObservationPending: true };
        }
        readStage = rejection ? 'trigger_remount_rejected' : 'trigger_remount_timeout';
        try {
          const elapsed = Date.now() - diagnosticStarted;
          remountObservation = { kind: 'claude_remount_observation_v1',
            elapsedMs: Number.isFinite(elapsed) ? Math.max(0, Math.min(10_000, Math.floor(elapsed))) : null,
            observations, entry, terminal: completionDiagnostic(),
            surface: websiteClaudeRemountSurfaceDiagnostic(context.claudeSubmittedReadGuard) };
        } catch { /* Unavailable diagnostics cannot replace the original failure. */ }
        return failure(rejection || 'model_unverified');
      }
      readStage = 'trigger_remount_observed';
    }
    while (Date.now() < until) {
      if (!unchanged()) return recovery ? failure('model_unverified') : { error: 'document_changed', detail: 'owner_token' };
      state = websiteModelPickerState(provider);
      if (claudeRemountStarted) {
        const invalid = remountProofError(state);
        if (invalid) return failure(invalid);
      }
      trackOwnedMenus(state);
      websiteModelTrackReadUI(state);
      if (state.duplicate || state.conflicting || state.indicatorInvalid || state.selectionAmbiguous || state.navigationAmbiguous)
        return failure('model_unverified');
      if (state.evidence) {
        readStage = 'proof_observed';
        captured = state.evidence;
        trigger = trigger || state.trigger;
        if (!(await closeOwned()) || !unchanged() || recovery && recovery.guard() !== true) return failure('model_unverified');
        const after = websiteModelPickerState(provider);
        if (claudeRemountStarted) {
          const invalid = remountProofError(after);
          if (invalid) return failure(invalid);
        }
        if (after.selected && !websiteModelChoiceEqual(after.selected, captured.selected)) return failure('model_mismatch');
        if (websiteModelChoiceEqual(captured.selected, expected)) {
          websiteClaudeRememberModelTrigger(provider, trigger, owner, url);
          return { modelEvidence: captured };
        }
        return { error: 'model_mismatch', modelEvidence: captured };
      }
      if (!state.trigger || state.triggerCount !== 1) return failure('model_unverified');
      if (trigger && trigger !== state.trigger) return failure('model_unverified');
      trigger = state.trigger;
      if (!state.topMenu) {
        if (primaryOpened || !state.enabled(trigger) || state.allMenus.length || recovery && recovery.guard() !== true)
          return failure('model_unverified');
        primaryOpened = true;
        readStage = 'primary_open_requested';
        trigger.click();
        const acknowledged = await websiteModelWaitForChange(recovery ? Math.min(until, Date.now() + 900) : until,
          () => !unchanged() || !!websiteModelPickerState(provider).topMenu);
        if (!acknowledged) {
          const current = websiteModelPickerState(provider);
          if (recovery && unchanged() && Date.now() < until && current.evidence) continue;
          // Only this fresh post-family read may recover a consumed chrome
          // opening. A timeout authorizes reinspection, never model proof.
          if (!recovery || !unchanged() || recovery.guard() !== true || Date.now() >= until || recovery.attempt.openingRecoveryAttempted
            || current.trigger !== trigger || trigger !== recovery.attempt.selectionTrigger || current.triggerCount !== 1
            || !current.enabled(trigger) || current.topMenu || current.allMenus.length
            || ![null, 'false'].includes(trigger.getAttribute('aria-expanded'))
            || ![null, 'closed'].includes(trigger.getAttribute('data-state'))
            || current.duplicate || current.conflicting || current.indicatorInvalid || current.selectionAmbiguous || current.navigationAmbiguous)
            return failure('model_unverified');
          recovery.attempt.openingRecoveryAttempted = true; // Claim once before the one extra chrome click.
          readStage = 'primary_open_recovery_requested';
          websiteModelTrackReadUI(current);
          trigger.click();
          if (!(await websiteModelWaitForChange(until, () => !unchanged() || !!websiteModelPickerState(provider).topMenu)))
            return failure('model_unverified');
        }
        if (!unchanged()) return failure('model_unverified');
        continue;
      }
      if (state.secondary && !state.nestedMenu) {
        if (secondaryOpened || !state.enabled(state.secondary)) return failure('model_unverified');
        secondaryOpened = true;
        readStage = 'secondary_open_requested';
        state.secondary.click();
        if (!(await websiteModelWaitForChange(until, () => {
          const current = websiteModelPickerState(provider);
          // The provider may replace the primary popup with its family menu.
          // Only the same association parser can supply actual checked proof.
          return !unchanged() || !!current.nestedMenu || !!current.evidence;
        })))
          return failure('model_unverified');
        continue;
      }
      return failure('model_unverified');
    }
    return failure('model_unverified');
  } finally {
    // Close only a popup associated with this observation's exact controlled
    // trigger. This never selects a family or replays a failed editor operation.
    if (!claudeRemountStarted && unchanged() && trigger && !closeAttempted) {
      const current = websiteModelPickerState(provider);
      if (current.topMenu && current.trigger === trigger && current.physical(trigger)
        && !trigger.disabled && trigger.getAttribute('aria-disabled') !== 'true') {
        closeAttempted = true;
        try { websiteModelDismissOwnedPicker(provider, trigger, current.nestedMenu || current.topMenu); } catch { }
      }
    }
  }
}
async function websiteClaudeCloseDiscoveryMenus(state, attempt, freshGuard) {
  if (attempt.closed) return false;
  attempt.closed = true; // Any uncertain dismissal stays claimed across later reads.
  const owner = globalThis.__computaModelOwner, url = document.URL;
  const trigger = state.trigger, top = state.topMenu, nested = state.nestedMenu, secondary = state.secondary;
  const selected = state.selected, owned = [top, nested].filter(Boolean);
  const until = Date.now() + 1_800; // One shared deadline, including both distinct popups.
  const current = () => websiteModelPickerState('claude');
  let invalidated = false, catalog = null;
  const controlsFor = (view, menu) => view.controls.filter(control =>
    control.node.closest('[role="menu"], [role="listbox"], [role="dialog"]') === menu);
  const eligibilityUnchanged = view => !catalog || catalog.every(snapshot => {
    // A verified child dismissal may also close its parent. Only menus still
    // physically present can contribute a later eligibility observation.
    if (!view.physical(snapshot.menu)) return true;
    if (!view.menus.includes(snapshot.menu)) return false;
    const controls = controlsFor(view, snapshot.menu);
    return controls.length === snapshot.controls.length && snapshot.controls.every(expected =>
      controls.some(current => current.node === expected.node && websiteModelChoiceEqual(current.choice, expected.choice)));
  });
  const unchanged = view => {
    const valid = window === window.top && document.URL === url
      && globalThis.__computaModelOwner === owner && globalThis.__computaModelFirstSubmitted !== true
      && (typeof freshGuard !== 'function' || freshGuard() === true)
      && document.querySelectorAll('[data-testid="user-message"], [data-testid="assistant-message"]').length === 0
      && view.trigger === trigger && view.triggerCount === 1 && view.enabled(trigger)
      && !view.duplicate && !view.conflicting && !view.indicatorInvalid && !view.selectionAmbiguous && !view.navigationAmbiguous
      && (selected ? websiteModelChoiceEqual(view.selected, selected) : view.selected == null)
      && view.physicalMenus.every(menu => owned.includes(menu)) && eligibilityUnchanged(view);
    // A wakeup can observe drift that is restored before the await resumes.
    // Its negative evidence remains decisive for this claimed close attempt.
    invalidated ||= !valid;
    return !invalidated;
  };
  try {
    const initial = current();
    if (Date.now() >= until || !unchanged(initial) || initial.topMenu !== top || initial.nestedMenu !== nested
      || initial.secondary !== secondary || owned.some(menu => !initial.menus.includes(menu) || !initial.visible(menu))) return false;
    // Earlier reads are provisional. Publish only this fresh, complete owned
    // picker snapshot, then keep each still-open menu's eligibility unchanged
    // throughout the existing guarded close. Never revive an accumulated row.
    catalog = owned.map(menu => ({ menu, controls: controlsFor(initial, menu)
      .map(control => ({ node: control.node, choice: { ...control.choice } })) }));
    const choices = catalog.flatMap(snapshot => snapshot.controls.map(control => control.choice));
    if (!choices.length || choices.length > 32 || choices.some((choice, index) =>
      choices.some((other, otherIndex) => otherIndex !== index && websiteModelChoiceEqual(choice, other)))) return false;
    // A nested menu can consume Escape without closing its parent. Dismiss
    // each exact observed popup once, child first, with physical closure and
    // fresh context checks before the separate parent's dismissal.
    for (const menu of [nested, top].filter(Boolean)) {
      const before = current();
      if (!unchanged(before) || Date.now() >= until) return false;
      if (!before.physical(menu)) continue;
      if (menu === nested ? before.nestedMenu !== nested || before.secondary !== secondary || before.topMenu !== top
        : before.topMenu !== top || before.nestedMenu != null) return false;
      if (!websiteModelDismissOwnedPicker('claude', trigger, menu)) return false;
      if (!(await websiteModelWaitForChange(until, () => {
        const view = current(); return !unchanged(view) || !view.physical(menu);
      }))) return false;
      const after = current();
      if (Date.now() >= until || !unchanged(after) || after.physical(menu)) return false;
    }
    const after = current();
    const closed = Date.now() < until && unchanged(after) && !after.topMenu && !after.nestedMenu
      && owned.every(menu => !after.physical(menu))
      && [null, 'false'].includes(trigger.getAttribute('aria-expanded'))
      && [null, 'closed'].includes(trigger.getAttribute('data-state'));
    if (closed) attempt.choices = choices;
    return closed;
  } catch { return false; }
}
async function websiteModelPickerAction(state, request, fresh, freshGuard = null) {
  if (state.provider === 'chatgpt') return websiteChatPickerAction(request, fresh, freshGuard);
  const diagnostic = () => ({ modelDiagnostic: websiteModelDiagnostic(state) });
  if (request.action === 'modelDiagnostic') return { ...diagnostic(), modelEvidence: state.evidence };
  if (!fresh) return { error: 'not_fresh', ...diagnostic() };
  const discovery = request.action === 'discoverModels';
  const choice = request.modelChoice;
  if (!discovery && !websiteModelChoiceValid(choice)) return { error: 'model_unverified', ...diagnostic() };
  const slot = discovery ? '__computaModelDiscovery' : '__computaModelSelection';
  let attempt = globalThis[slot];
  if (attempt && !discovery && !websiteModelChoiceEqual(attempt.choice, choice)) return { error: 'model_mismatch', ...diagnostic() };
  if (!attempt) attempt = globalThis[slot] = { choice, primaryOpened: false, secondaryOpened: false, clicked: false, closed: false, choices: [] };
  if (attempt.completed) {
    if (!discovery) {
      const proof = await websiteModelReadEvidence(state.provider, choice, null,
        { scope: 'completed_selection', action: request.action });
      if (proof.error) return proof;
      return { selected: true, ...proof };
    }
    return discovery ? { modelChoices: attempt.choices, modelEvidence: state.evidence, ...diagnostic() } : { selected: true, modelEvidence: state.evidence };
  }
  if (!discovery && attempt.clicked) {
    const until = Date.now() + 1_800;
    // A post-family read first acknowledges actual DOM closure. Its only
    // recovery is one guarded fresh opening when the closing commit consumed it.
    if (state.provider === 'chatgpt' && !attempt.settled) {
      const settling = await websiteModelSettleSelection(state.provider, attempt, freshGuard, until);
      if (settling) return settling;
    }
    if (state.provider === 'chatgpt') {
      if (attempt.verificationAttempted) return { error: 'model_unverified', ...diagnostic() };
      attempt.verificationAttempted = true;
    }
    const proof = await websiteModelReadEvidence(state.provider, choice, state.provider === 'chatgpt'
      ? { attempt, guard: freshGuard, until } : null, { scope: 'post_selection', action: request.action });
    if (proof.error) return proof;
    attempt.completed = true;
    return { selected: true, ...proof };
  }
  if (!discovery && websiteModelChoiceEqual(state.selected, choice)) {
    attempt.completed = true;
    return { selected: true, modelEvidence: state.evidence };
  }
  if (!state.trigger) return state.triggerCount === 0 && state.triggerCandidates.length === 0
    ? { pending: true, ...diagnostic() } : { error: 'model_unverified', ...diagnostic() };
  if (!state.topMenu) {
    if (state.allMenus.length && !attempt.primaryOpened) return { error: 'model_unverified', ...diagnostic() };
    if (attempt.primaryOpened || attempt.clicked) return { pending: true, modelEvidence: state.evidence, ...diagnostic() };
    if (!state.enabled(state.trigger)) return { error: 'model_unverified', ...diagnostic() };
    attempt.primaryOpened = true; // Claim before click: lost acknowledgments cannot toggle it back.
    state.trigger.click();
    return { pending: true, modelEvidence: state.evidence };
  }
  if (state.duplicate || state.conflicting || state.indicatorInvalid || state.selectionAmbiguous || state.navigationAmbiguous)
    return { error: 'model_unverified', ...diagnostic() };
  if (discovery) for (const found of state.choices)
    if (!attempt.choices.some(existing => websiteModelChoiceEqual(existing, found))) attempt.choices.push(found);
  if (state.secondary && !state.nestedMenu && !attempt.secondaryOpened) {
    attempt.secondaryOpened = true;
    state.secondary.click();
    return { pending: true, modelEvidence: state.evidence };
  }
  if (state.secondary && attempt.secondaryOpened && !state.nestedMenu) return { pending: true, ...diagnostic() };
  if (discovery) {
    if (!attempt.choices.length) return { error: 'model_unverified', ...diagnostic() };
    if (attempt.choices.length > 32) return { error: 'model_unverified', ...diagnostic() };
    const receipt = diagnostic();
    if (state.provider === 'claude') {
      if (!(await websiteClaudeCloseDiscoveryMenus(state, attempt, freshGuard)))
        return { error: 'model_unverified', modelDiagnostic: websiteModelDiagnostic(websiteModelPickerState(state.provider)) };
    } else if (!attempt.closed && state.enabled(state.trigger)) {
      attempt.closed = true;
      const url = document.URL, owner = globalThis.__computaModelOwner;
      if (!websiteModelDismissOwnedPicker(state.provider, state.trigger, state.nestedMenu || state.topMenu))
        return { error: 'model_unverified', ...diagnostic() };
      const closed = await websiteModelWaitForChange(Date.now() + 1_800, () => document.URL !== url
        || globalThis.__computaModelOwner !== owner || !websiteModelPickerState(state.provider).topMenu);
      if (!closed || document.URL !== url || globalThis.__computaModelOwner !== owner)
        return { error: 'model_unverified', modelDiagnostic: websiteModelDiagnostic(websiteModelPickerState(state.provider)) };
    } else if (state.topMenu) return { error: 'model_unverified', ...diagnostic() };
    attempt.completed = true;
    return { modelChoices: attempt.choices, modelEvidence: state.evidence, ...receipt };
  }
  if (attempt.clicked) return { pending: true, modelEvidence: state.evidence, ...diagnostic() };
  const matches = state.controls.filter(control => websiteModelChoiceEqual(control.choice, choice));
  if (matches.length !== 1) return { error: 'model_unavailable', ...diagnostic() };
  attempt.clicked = true;
  if (state.provider === 'chatgpt') {
    attempt.selectionTrigger = state.trigger;
    attempt.selectionOwner = globalThis.__computaModelOwner;
    attempt.selectionURL = document.URL;
    attempt.selectionOrigin = location.origin;
  }
  matches[0].node.click();
  return { pending: true, modelEvidence: state.evidence };
}
async function websiteModelFinalGuard(provider, request, observed, currentTemporary = null) {
  websiteModelDiagnosticPhase('final_model_guard');
  if (observed.error || request.action === 'stop' || request.expectedModelChoice == null
    || ['discoverModels', 'selectModel', 'modelDiagnostic'].includes(request.action)) return observed;
  const proof = await websiteModelReadEvidence(provider, request.expectedModelChoice, null,
    { scope: 'action_final_guard', action: request.action });
  if (proof.error) return proof;
  // The picker can hide the mode control while open. Reinspect its actual
  // restored temporary state only after this final owned-popup close.
  if (typeof currentTemporary !== 'function' || currentTemporary() !== true) return { error: 'temporary_mode_unverified' };
  return { ...observed, ...proof, ...(request.action === 'inspect' && observed.answerComplete && observed.responseCount > 0
    ? { modelDiagnostic: websiteModelDiagnostic(websiteModelPickerState(provider)) } : {}) };
}
