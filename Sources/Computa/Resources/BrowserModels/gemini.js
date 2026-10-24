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
function websiteChatHeaderPower(trigger) {
  const value = trigger?.innerText;
  return typeof value === 'string' && value.length <= 128
    ? websiteChatPowers.find(power => power.label === websiteModelNormalize(value)) || null : null;
}
function websiteChatHeaderTextShape(value) {
  const present = typeof value === 'string';
  const normalized = present && value.length <= 512 ? websiteModelNormalize(value) : null;
  const ordinal = present && value.length <= 128
    ? websiteChatPowers.findIndex(power => power.label === normalized) : -1;
  return { present, length: present ? Math.min(value.length, 513) : 0,
    normalizedLength: normalized === null ? null : Math.min(normalized.length, 512),
    empty: normalized === '', over128: present && value.length > 128,
    canonicalOrdinal: ordinal < 0 ? null : ordinal, generic: normalized === 'Thinking effort' };
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
function websiteChatHeaderMutationMismatch(records, trigger, expected) {
  if (!trigger || !expected) return false;
  const different = value => typeof value === 'string' && value.length <= 128
    && websiteChatPowers.some(power => power.label === websiteModelNormalize(value) && power.key !== expected.key);
  if (different(trigger.innerText)) return true;
  // Current ancestry loses an attached header child that changed and detached
  // before delivery. Undo structural records, then replay their exact lineage.
  // The bounded reconstruction supplies only negative drift evidence.
  if (records.length > 512) return true;
  const parents = new Map(), children = new Map(), text = new Map(), afterText = new Map();
  const parent = node => parents.has(node) ? parents.get(node) : node?.parentNode || node?.parentElement || null;
  const bounded = value => typeof value === 'string' && value.length <= 128 ? value : null;
  for (const record of records) if (record.type === 'childList') {
    const nodes = [...(record.addedNodes || []), ...(record.removedNodes || [])];
    if (nodes.length > 128) return true;
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
    if (parents.size + text.size > 4_096) return true;
  }
  const headerTarget = node => {
    for (let depth = 0; node && depth < 64; depth++, node = parent(node)) {
      if (node.nodeType === 1 && (node.getAttribute('aria-hidden') === 'true' || node.getAttribute('inert') !== null)) return false;
      if (node === trigger) return true;
    }
    return node ? null : false;
  };
  const textAt = (node, budget = { nodes: 128, depth: 0 }) => {
    if (!node || --budget.nodes < 0 || budget.depth > 32) return null;
    if (node.nodeType === 3) return text.has(node) ? text.get(node) : bounded(node.textContent);
    if (node.nodeType !== 1 || node.getAttribute('aria-hidden') === 'true' || node.getAttribute('inert') !== null) return '';
    const current = [...(node.childNodes || [])];
    if (current.length > 128) return null;
    const candidates = new Set([...current, ...(children.get(node) || [])]);
    if (candidates.size > 128) return null;
    let value = '';
    budget.depth++;
    for (const child of candidates) if (parent(child) === node) {
      const part = textAt(child, budget);
      if (part === null || value.length + part.length > 128) { budget.depth--; return null; }
      value += part;
    }
    budget.depth--;
    return value;
  };
  for (const record of records) {
    if (record.type === 'characterData') {
      const owned = headerTarget(record.target);
      if (owned === null || owned && (bounded(record.oldValue) === null || afterText.get(record) === null
        || different(record.oldValue) || different(afterText.get(record)))) return true;
      text.set(record.target, afterText.get(record));
    } else if (record.type === 'childList') {
      for (const node of record.removedNodes || []) {
        const owned = headerTarget(node), value = owned ? textAt(node) : '';
        if (owned === null || owned && (value === null || different(value))) return true;
        if (parent(node) === record.target) parents.set(node, null);
      }
      for (const node of record.addedNodes || []) {
        parents.set(node, record.target);
        const owned = headerTarget(node), value = owned ? textAt(node) : '';
        if (owned === null || owned && (value === null || different(value))) return true;
      }
    }
  }
  return false;
}
function websiteChatInvalidatePin(pin, reason, facts = null) {
  pin.invalidated = true;
  // Preserve the first finite cause. This records negative evidence only;
  // it cannot revive a selection or change any model/ownership guard.
  if (!pin.invalidationReason && ['header_replaced', 'header_mutation', 'semantic_mutation'].includes(reason)) {
    pin.invalidationReason = reason;
    pin.invalidationFacts = facts;
  }
}
function websiteChatTrackPinnedHeader(pin, trigger) {
  if (!pin || pin.owner !== globalThis.__computaModelOwner || pin.document !== document) return;
  if (pin.headerTrigger && pin.headerTrigger !== trigger) { websiteChatInvalidatePin(pin, 'header_replaced'); return; }
  pin.headerTrigger = trigger;
  if (pin.headerObserver) return;
  pin.headerObserver = new MutationObserver(records => websiteChatObservePinnedHeader(pin, trigger, records));
  pin.headerObserver.observe(trigger, { subtree: true, childList: true, characterData: true,
    characterDataOldValue: true });
}
function websiteChatObservePinnedHeader(pin, trigger, records) {
  if (globalThis.__computaChatPresetPin !== pin || pin.owner !== globalThis.__computaModelOwner
    || pin.document !== document || window !== window.top || location.origin !== 'https://chatgpt.com') return;
  if (websiteChatHeaderMutationMismatch(records, trigger, pin.selection.power)) websiteChatInvalidatePin(pin, 'header_mutation');
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
      });
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
  let headerReadiness = null;
  const tracked = new Map();
  const observeHeader = records => {
    if (websiteChatHeaderMutationMismatch(records, trigger, headerExpected)) {
      selectionChanged = true;
      if (remount && owned()) websiteChatInvalidatePin(remount.pin, 'header_mutation');
    }
  };
  const headerObserver = new MutationObserver(observeHeader);
  const observeControls = records => {
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
    if (remount && (remount.previous.isConnected !== false || current.trigger !== remount.replacement)) {
      websiteChatInvalidatePin(pin, 'header_replaced');
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
    if (headerExpected && current.headerPower && current.headerPower.key !== headerExpected.key) throw failure('model_mismatch');
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
  const prepareOpeningIntact = current => readonlyOpeningSelectionIntact(prepareOpening, current)
    && request.action === 'prepare' && context?.action === 'prepare' && context.scope === 'action_final_guard'
    && globalThis.__computaChatFirstPrepareOpening === prepareOpening && !globalThis.__computaChatSubmissionState;
  const insertComposer = current => {
    const candidates = [...new Set(document.querySelectorAll('#prompt-textarea[contenteditable="true"], textarea#prompt-textarea, '
      + '#prompt-textarea [contenteditable="true"], [contenteditable="true"][aria-label="Ask ChatGPT"], textarea[data-testid="prompt-textarea"]'))]
      .filter(node => current.enabled(node));
    return candidates.length === 1 ? candidates[0] : null;
  };
  const insertComposerValue = composer => composer instanceof HTMLTextAreaElement ? composer.value : composer?.innerText;
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
    if (!genericPowerRecheck && !mutable && request.action === 'prepare' && context?.scope === 'action_final_guard'
      && completed?.completed === true && globalThis.__computaChatFirstPrepareOpening == null) {
      // Spend the first prepare observation even when its opening succeeds.
      // Later prepares cannot acquire a new recovery allowance.
      const pin = globalThis.__computaChatPresetPin;
      prepareOpening = { owner, document: originalDocument, attempt: completed, pin, selection: pin?.selection, header: trigger,
        recoveryClaimed: false,
        resolved: { family: { ...pin?.selection?.family }, power: { ...pin?.selection?.power } } };
      globalThis.__computaChatFirstPrepareOpening = prepareOpening;
      current = drainOpeningEvidence();
      if (!prepareOpeningIntact(current)) prepareOpening = null;
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
        readStage = prepareOpening !== null ? 'prepare_open_recovery_requested' : 'insert_open_recovery_requested';
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
    }
    return current;
  };
  try {
    let initial = state();
    if (initial.topMenu) { await close(); initial = state(); }
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
  const triggers = nodes('button[aria-label], [role="button"][aria-label]').filter(node => physical(node) && outside(node) && isTrigger(node));
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
      if (upgrades) continue;
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
    navigationAmbiguous: secondaries.length > 1, physical, visible, enabled, family };
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
  }
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
    if (readiness?.startedEmpty === true && ['waiting', 'recognized', 'rejected'].includes(readiness.outcome))
      diagnostic.chatHeader.readiness = { startedEmpty: true, outcome: readiness.outcome,
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
  if (provider === 'chatgpt') {
    if (typeof window.KeyboardEvent !== 'function' || !menu?.dispatchEvent) return false;
    // The family submenu does not toggle closed when its trigger is clicked.
    // Dismiss only this associated popup; its listener receives one Escape.
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
  const unchanged = () => window === window.top && document.URL === url && globalThis.__computaModelOwner === owner
    && (!recovery || recovery.guard(false) === true);
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
    while (Date.now() < until) {
      if (!unchanged()) return recovery ? failure('model_unverified') : { error: 'document_changed', detail: 'owner_token' };
      state = websiteModelPickerState(provider);
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
        if (after.selected && !websiteModelChoiceEqual(after.selected, captured.selected)) return failure('model_mismatch');
        return websiteModelChoiceEqual(captured.selected, expected) ? { modelEvidence: captured }
          : { error: 'model_mismatch', modelEvidence: captured };
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
    if (unchanged() && trigger && !closeAttempted) {
      const current = websiteModelPickerState(provider);
      if (current.topMenu && current.trigger === trigger && current.physical(trigger)
        && !trigger.disabled && trigger.getAttribute('aria-disabled') !== 'true') {
        closeAttempted = true;
        try { websiteModelDismissOwnedPicker(provider, trigger, current.nestedMenu || current.topMenu); } catch { }
      }
    }
  }
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
    if (!attempt.closed && state.enabled(state.trigger)) {
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

// A fenced envelope keeps JSON escapes out of the website's Markdown parser.
// Admit only one literal code body with no author prose elsewhere in this answer.
function modelResponseText(answer) {
  if (!answer) return '';
  const rendered = (answer.innerText || answer.textContent || '').trim();
  const blocks = [...answer.querySelectorAll('pre')];
  if (blocks.length !== 1) return rendered;
  const codes = [...blocks[0].querySelectorAll('code')];
  if (codes.length !== 1) return rendered;
  const code = codes[0], raw = code.textContent || '';
  if (raw.length > 220_000) return rendered;
  let envelope;
  try { envelope = JSON.parse(raw); } catch { return rendered; }
  if (!envelope || Array.isArray(envelope) || !['message', 'tool_calls'].includes(envelope.type)) return rendered;
  // Observed Gemini code chrome: the uppercase JSON leaf and Copy code
  // button share this header inside the provider's sole code-block wrapper.
  const wrapper = blocks[0].closest('div.formatted-code-block-internal-container');
  const chrome = new Set();
  if (wrapper && wrapper !== answer && answer.contains(wrapper)
    && wrapper.querySelectorAll('pre').length === 1 && wrapper.querySelectorAll('code').length === 1) {
    const headers = [...wrapper.querySelectorAll('div.code-block-decoration.header-formatted.gds-emphasized-body-m')]
      .filter(node => modelVisible(node) && !node.closest('pre'));
    if (headers.length === 1) {
      const labels = [...headers[0].querySelectorAll('span')].filter(node => modelVisible(node)
        && node.childElementCount === 0 && (node.textContent || '').trim() === 'JSON');
      const copies = [...headers[0].querySelectorAll('button[aria-label="Copy code"]')].filter(node =>
        modelEnabled(node) && !(node.textContent || '').trim());
      if (labels.length === 1 && copies.length === 1) { chrome.add(labels[0]); chrome.add(copies[0]); }
    }
  }
  let visited = 0;
  const onlyCodeAndWhitespace = node => {
    if (++visited > 10_000) return false;
    if (node === code || chrome.has(node)) return true;
    if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
    if (node.nodeType !== 1) return true;
    // Actual controls inside this pre are code-block chrome, never surrounding prose.
    if (node.tagName.toLowerCase() === 'button' && blocks[0].contains(node)) return true;
    return [...node.childNodes].every(onlyCodeAndWhitespace);
  };
  return onlyCodeAndWhitespace(answer) ? raw : rendered;
}

// Diagnostic counts describe only this scoped answer; no response bytes leave this function.
function modelResponseStructure(answer) {
  const blocks = answer ? [...answer.querySelectorAll('pre')] : [];
  const allCodes = answer ? [...answer.querySelectorAll('code')] : [];
  const codes = blocks.length === 1 ? [...blocks[0].querySelectorAll('code')] : [];
  const code = codes.length === 1 ? codes[0] : null;
  let visited = 0, outsideTextLength = 0, outsideTruncated = false;
  const outsideNodes = [];
  const nodeShape = node => ({ tag: /^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'other',
    classes: [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)).slice(0, 6),
    preDescendants: Math.min(node.querySelectorAll('pre').length, 1_000),
    copyControls: Math.min(node.querySelectorAll('button[aria-label="Copy"], button[aria-label="Copy code"]').length, 1_000) });
  const countOutside = node => {
    if (++visited > 10_000) { outsideTruncated = true; return; }
    if (node === code) return;
    if (node.nodeType === 3) {
      const text = (node.textContent || '').trim();
      outsideTextLength = Math.min(220_001, outsideTextLength + text.length);
      if (text && outsideNodes.length < 4) {
        const ancestors = [];
        for (let parent = node.parentElement; parent && ancestors.length < 4; parent = parent.parentElement) {
          ancestors.push(nodeShape(parent)); if (parent === answer) break;
        }
        outsideNodes.push({ kind: text === 'json' ? 'json' : /^[\uE000-\uF8FF]+$/u.test(text) ? 'private_use' : 'other',
          textLength: Math.min(text.length, 220_001), ancestors });
      }
      return;
    }
    if (node.nodeType !== 1) return;
    if (blocks.length === 1 && node.tagName.toLowerCase() === 'button' && blocks[0].contains(node)) return;
    for (const child of node.childNodes) { countOutside(child); if (outsideTruncated) break; }
  };
  if (answer) countOutside(answer);
  const preParentTags = [];
  if (blocks.length === 1) for (let node = blocks[0].parentElement; node && preParentTags.length < 3; node = node.parentElement) {
    preParentTags.push(/^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'other');
    if (node === answer) break;
  }
  const result = { preCount: Math.min(blocks.length, 1_000), codeCount: Math.min(allCodes.length, 1_000),
    codeTextLength: Math.min((code?.textContent || '').length, 220_001), outsideTextLength, outsideTruncated, preParentTags, outsideNodes };
  while (JSON.stringify(result).length > 8_192 && result.outsideNodes.length) result.outsideNodes.pop();
  return result;
}

// Report only the first mismatch's offset and Unicode scalar values, never prompt text.
function modelEditorDifference(actual, expected) {
  let firstDifference = 0;
  while (firstDifference < Math.min(actual.length, expected.length)
    && actual.charCodeAt(firstDifference) === expected.charCodeAt(firstDifference)) firstDifference++;
  // A differing low surrogate still belongs to the scalar beginning one unit earlier.
  if (firstDifference > 0 && actual.charCodeAt(firstDifference - 1) >= 0xD800
    && actual.charCodeAt(firstDifference - 1) <= 0xDBFF
    && (actual.charCodeAt(firstDifference) >= 0xDC00 && actual.charCodeAt(firstDifference) <= 0xDFFF
      || expected.charCodeAt(firstDifference) >= 0xDC00 && expected.charCodeAt(firstDifference) <= 0xDFFF)) firstDifference--;
  const scalarAt = text => {
    if (firstDifference >= text.length) return null;
    const scalar = text.codePointAt(firstDifference);
    return scalar >= 0xD800 && scalar <= 0xDFFF ? undefined : scalar;
  };
  return { firstDifference: Math.min(firstDifference, 360_000), actualScalar: scalarAt(actual), expectedScalar: scalarAt(expected) };
}

// Fixed Gemini DOM adapter. Only native structured input runs this private-world program.
function modelVisible(node) {
  return !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
}
function modelEnabled(node) { return modelVisible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true'; }
function modelFind(selectors) { return selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(modelVisible); }
function modelUserRoots() {
  const nodes = [...document.querySelectorAll('user-query')];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
function modelUserBody(root) {
  if (!root) return null;
  // Observed Gemini markup keeps message bytes in one span while controls
  // occupy its sibling. Pin that body through the exact provider wrappers.
  const contents = [...root.querySelectorAll('div.query-content')];
  if (contents.length !== 1 || contents[0].closest('user-query') !== root || !modelVisible(contents[0])) return null;
  const child = (parent, tag, name) => {
    if (!parent) return null;
    const matches = [...parent.children].filter(node => node.tagName.toLowerCase() === tag && node.classList.contains(name));
    return matches.length === 1 && modelVisible(matches[0]) ? matches[0] : null;
  };
  const status = child(contents[0], 'div', 'query-bubble-with-status');
  const bubble = child(status, 'span', 'user-query-bubble-with-background');
  const body = child(bubble, 'span', 'ng-star-inserted');
  if (!body || body.closest('user-query') !== root
    || body.closest('[contenteditable="true"], [role="textbox"]')
    || body.querySelector('button, [role="button"], [contenteditable="true"], [role="textbox"]')) return null;
  return body;
}
function modelQueryHeadingFacts(node) {
  const empty = { headingSemantic: false, absolutePosition: false, onePixelBox: false,
    overflowHidden: false, rectClipped: false, insetClipped: false };
  try {
    if (!node || node.nodeType !== 1) return empty;
    const role = node.getAttribute('role'), style = getComputedStyle(node);
    return { headingSemantic: /^H[1-6]$/.test(node.tagName) && (role === null || role === 'heading') || role === 'heading',
      absolutePosition: style.position === 'absolute', onePixelBox: style.width === '1px' && style.height === '1px',
      overflowHidden: style.overflow === 'hidden' || style.overflowX === 'hidden' && style.overflowY === 'hidden',
      rectClipped: /^rect\(\s*0(?:px)?(?:\s*,\s*|\s+)0(?:px)?(?:\s*,\s*|\s+)0(?:px)?(?:\s*,\s*|\s+)0(?:px)?\s*\)$/.test(style.clip || ''),
      insetClipped: /^inset\(\s*50%\s*\)$/.test(style.clipPath || '') };
  } catch { return empty; }
}
function modelExpectedQueryCanonical(body, recovery = null) {
  try {
    if (window !== window.top || document.URL !== input.expectedURL || location.origin !== 'https://gemini.google.com'
      || globalThis.__computaModelOwner !== input.ownerToken || !modelURLAllowed() || !modelTemporaryVerified()) return null;
    const root = body.closest('user-query'), roots = modelUserRoots(), sequence = roots.indexOf(root) + 1;
    if (sequence < 1 || sequence > 10_000 || modelUserBody(root) !== body) return null;
    let text, marker;
    if (sequence === 1) {
      const context = globalThis.__computaModelFirstPromptContext;
      if (context?.document !== document || context.owner !== input.ownerToken
        || context.marker !== input.expectedFirstUserMarker || globalThis.__computaModelFirstSubmitted !== true
        || globalThis.__computaModelFirstMarker !== context.marker) return null;
      text = globalThis.__computaModelFirstPrompt; marker = context.marker;
    } else {
      const state = globalThis.__computaGeminiSubmissionState;
      if (!state || state.revoked || state.document !== document || state.owner !== input.ownerToken) return null;
      const records = [state.pending, state.lastVerified].filter(record => record?.sequence === sequence);
      if (records.length !== 1) return null;
      const record = records[0];
      const recoveryPermit = recovery?.record === record && recovery.root === root && recovery.body === body
        && state.lastVerified === record && record.phase === 'verified' && record.root && record.body
        && !record.root.isConnected && !record.body.isConnected
        && modelExpectedSubmissionProof(sequence)?.fingerprint === record.fingerprint;
      if (record.document !== document || record.owner !== input.ownerToken
        || !['send_claimed', 'verified'].includes(record.phase)
        || record.phase === 'verified' && (record.root !== root || record.body !== body) && !recoveryPermit
        || record.phase === 'send_claimed' && (record.root !== null || record.body !== null)
        || record.marker === input.expectedFirstUserMarker) return null;
      text = record.canonical; marker = record.marker;
    }
    if (typeof text !== 'string' || text.length > 180_200 || typeof marker !== 'string'
      || !/^[a-f0-9-]{36}$/i.test(marker)) return null;
    const canonical = text.replace(/\r\n?/g, '\n').normalize('NFC').trim(), suffix = `Computa session marker: ${marker}`;
    return canonical.length <= 180_200 && canonical.endsWith(`\n\n${suffix}`)
      && canonical.split(suffix).length === 2 ? canonical : null;
  } catch { return null; }
}
function modelQueryPayload(body, recovery = null) {
  // The measured rich message scaffold has a clipped screen-reader heading
  // followed by one literal paragraph per outbound line. Never use rendered
  // innerText as a fallback after recognizing this scaffold.
  let recognized = false;
  try {
    const containers = [...body.querySelectorAll('div.query-text')];
    // A block wrapper cannot silently become the legacy literal-SPAN path
    // just because a required rich-scaffold class disappeared.
    recognized = containers.length > 0 || body.querySelector('div') !== null;
    if (!recognized) return { recognized: false, text: null };
    if (containers.length !== 1 || containers[0].parentElement !== body
      || !containers[0].classList.contains('gds-body-l')) return { recognized, text: null };
    const query = containers[0];
    let count = 0, characters = 0, headerCharacters = 0;
    const countNode = (node, depth) => {
      if (++count > 8_192 || depth > 64) throw new Error('query_payload_budget');
      if (node.nodeType === 8) return;
      if (node.nodeType !== 1 && node.nodeType !== 3) throw new Error('query_payload_node');
    };
    const structuralChildren = (node, depth) => [...node.childNodes].filter(child => {
      countNode(child, depth);
      if (child.nodeType === 8) return false; // Angular comments have no rendered bytes.
      if (child.nodeType === 3 && child.data === '') return false;
      if (child.nodeType !== 1) throw new Error('query_payload_outside_text');
      return true;
    });
    const safeElement = node => {
      if (!modelVisible(node) || node.getAttribute('hidden') !== null || node.getAttribute('inert') !== null
        || node.getAttribute('contenteditable') !== null || node.getAttribute('tabindex') !== null
        || node.getAttribute('aria-hidden') === 'true') throw new Error('query_payload_hidden');
      const role = node.getAttribute('role');
      if (role !== null && role !== 'heading') throw new Error('query_payload_control');
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse')
        throw new Error('query_payload_hidden');
    };
    countNode(body, 0); safeElement(body);
    const outer = structuralChildren(body, 1);
    if (outer.length !== 1 || outer[0] !== query) return { recognized, text: null };
    safeElement(query);
    const children = structuralChildren(query, 2), heading = children[0];
    if (children.length < 2 || !heading.classList.contains('cdk-visually-hidden')) return { recognized, text: null };
    safeElement(heading);
    const facts = modelQueryHeadingFacts(heading);
    if (!facts.headingSemantic || !facts.absolutePosition || !facts.onePixelBox || !facts.overflowHidden
      || !facts.rectClipped && !facts.insetClipped) return { recognized, text: null };
    const literal = (node, depth, header = false) => {
      countNode(node, depth);
      if (node.nodeType === 8) return '';
      if (node.nodeType === 3) {
        if (typeof node.data !== 'string') throw new Error('query_payload_text');
        if (header) {
          headerCharacters += node.data.length;
          if (headerCharacters > 8_192) throw new Error('query_heading_length');
        } else {
          characters += node.data.length;
          // The only candidate framing adds two ASCII spaces per text row.
          if (characters > 180_200 + 2 * 8_192) throw new Error('query_payload_length');
        }
        return node.data;
      }
      safeElement(node);
      if (node.tagName !== 'SPAN' || node.getAttribute('role') !== null
        || !header && [...node.classList].some(name => name !== 'ng-star-inserted')) throw new Error('query_payload_markup');
      return [...node.childNodes].map(child => literal(child, depth + 1, header)).join('');
    };
    // Validate the omitted header subtree too; its text is never included in
    // the prompt, and controls or unknown rich markup cannot hide there.
    [...heading.childNodes].forEach(child => literal(child, 3, true));
    const rows = children.slice(1), lines = [], blank = [], directTextCounts = [];
    for (const row of rows) {
      safeElement(row);
      if (row.tagName !== 'P' || !row.classList.contains('query-text-line') || row.getAttribute('role') !== null)
        return { recognized, text: null };
      const nodes = [...row.childNodes].filter(node => {
        if (node.nodeType === 8) { countNode(node, 3); return false; }
        return true;
      });
      if (nodes.length === 1 && nodes[0].nodeType === 1 && nodes[0].tagName === 'BR') {
        countNode(nodes[0], 3); safeElement(nodes[0]);
        if (nodes[0].getAttribute('role') !== null || nodes[0].childNodes.length !== 0) return { recognized, text: null };
        lines.push(''); blank.push(true);
      } else {
        const line = [...row.childNodes].map(node => literal(node, 3)).join('');
        // One paragraph represents one line; nested linebreaks or empty
        // paragraphs without the measured lone BR are ambiguous.
        if (!line.length || /[\r\n]/.test(line)) return { recognized, text: null };
        lines.push(line); blank.push(false);
        directTextCounts.push(nodes.filter(node => node.nodeType === 3).length);
      }
    }
    const expected = modelExpectedQueryCanonical(body, recovery), raw = lines.join('\n');
    const normalize = text => text.replace(/\r\n?/g, '\n').normalize('NFC').trim();
    const singleFrame = lines.every((line, index) => blank[index]
      || line.length >= 3 && line.startsWith(' ') && line.endsWith(' '));
    const framedLines = singleFrame ? lines.map((line, index) => blank[index] ? '' : line.slice(1, -1)) : null;
    const framed = framedLines?.join('\n');
    const rawWholeMatches = expected !== null && raw.length <= 180_200 && normalize(raw) === expected;
    const singleFrameWholeMatches = expected !== null && framed !== undefined && framed.length <= 180_200 && normalize(framed) === expected;
    const selectedMode = rawWholeMatches ? 'literal' : singleFrameWholeMatches ? 'ascii_space_frame_v1' : 'unverified';
    const expectedLines = expected?.split('\n');
    const rowMatches = candidate => expectedLines?.length === rows.length && candidate
      ? candidate.filter((line, index) => line.normalize('NFC') === expectedLines[index]).length : 0;
    const queryTemplate = { kind: 'gemini_query_template_v1', expectedAvailable: expected !== null,
      rowCount: rows.length, brRowCount: blank.filter(Boolean).length, textRowCount: directTextCounts.length,
      directTextNodeMin: directTextCounts.length ? Math.min(...directTextCounts) : 0,
      directTextNodeMax: directTextCounts.length ? Math.max(...directTextCounts) : 0,
      allTextRowsSingleFrame: singleFrame, rawWholeMatches, singleFrameWholeMatches,
      rawRowMatches: rowMatches(lines), singleFrameRowMatches: rowMatches(framedLines),
      leadingSpaceRows: lines.filter((line, index) => !blank[index] && line.startsWith(' ')).length,
      trailingSpaceRows: lines.filter((line, index) => !blank[index] && line.endsWith(' ')).length, selectedMode };
    return { recognized, text: rawWholeMatches ? raw : singleFrameWholeMatches ? framed : null, queryTemplate };
  } catch { return { recognized, text: null }; }
}
function modelTemporaryHeadingFacts(heading) {
  const direct = [...heading.childNodes].filter(node => node.nodeType === 3).map(node => node.textContent || '').join('').trim();
  const initialTitle = direct === 'Just stopping by?' || [...heading.querySelectorAll('*')].slice(0, 256)
    .some(node => modelVisible(node) && node.childElementCount === 0 && (node.textContent || '').trim() === 'Just stopping by?');
  const supportLink = [...heading.querySelectorAll('a[href]')].some(node => {
    if (!modelVisible(node)) return false;
    try {
      const url = new URL(node.getAttribute('href'), document.URL);
      return url.origin === 'https://support.google.com' && !url.username && !url.password
        && url.pathname === '/gemini/answer/13275745' && url.searchParams.get('p') === 'temp_chats';
    } catch { return false; }
  });
  const text = (heading.textContent || '').normalize('NFC').replace(/’/g, "'").replace(/\s+/g, ' ');
  const noHistory = text.includes("don't appear in recent chats") && text.includes("aren't used to improve Google AI");
  return { initialTitle, supportLink, noHistory };
}
function modelTemporaryVerified() {
  const exclude = 'button, [role="menu"], [role="tooltip"], model-response, user-query';
  const exit = modelFind(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]']);
  if (exit) return true;
  if ([...document.querySelectorAll('span.info-text')].some(node => modelVisible(node) && !node.closest(exclude)
    && (node.textContent || '').trim() === 'Temporary Chat')) return true;
  return [...document.querySelectorAll('h1, h2, [role="heading"]')].some(node => {
    if (!modelVisible(node) || node.closest(exclude)) return false;
    // Live provider mode scaffold: exact title + linked temp documentation +
    // no-history notice inside this same heading, not arbitrary body text.
    const facts = modelTemporaryHeadingFacts(node);
    return facts.initialTitle && facts.supportLink && facts.noHistory;
  });
}
// Readiness diagnostics contain only bounded structural facts, never page text.
function modelReadinessStructure() {
  const exclude = 'button, [role="menu"], [role="tooltip"], model-response, user-query';
  const shape = node => ({ tag: node.tagName.toLowerCase(),
    classes: [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)).slice(0, 6),
    visible: modelVisible(node), excluded: !!node.closest(exclude),
    textLength: Math.min((node.textContent || '').length, 220_001),
    initialExact: (node.textContent || '').trim() === 'Just stopping by?',
    activeExact: (node.textContent || '').trim() === 'Temporary Chat' });
  const candidates = [...document.querySelectorAll('h1, h2, [role="heading"], span.info-text')].slice(0, 12);
  const nodes = candidates.map(node => ({ ...shape(node), ...modelTemporaryHeadingFacts(node),
    // These booleans diagnose nested headings; they do not grant temporary mode.
    initialContained: (node.textContent || '').includes('Just stopping by?'),
    activeContained: (node.textContent || '').includes('Temporary Chat'),
    exactDescendants: [...node.querySelectorAll('*')].slice(0, 256).filter(child =>
      ['Just stopping by?', 'Temporary Chat'].includes((child.textContent || '').trim())).slice(0, 4).map(shape) }));
  const count = selectors => {
    const found = selectors.flatMap(selector => [...document.querySelectorAll(selector)]);
    const unique = [...new Set(found)];
    return { total: Math.min(unique.length, 1_000), visible: Math.min(unique.filter(modelVisible).length, 1_000),
      enabled: Math.min(unique.filter(modelEnabled).length, 1_000) };
  };
  const result = { kind: 'provider_readiness', provider: 'gemini', nodes,
    composer: count(['[contenteditable="true"][aria-label="Enter a prompt for Gemini"]', 'rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']),
    toggle: count(['button[aria-label="Temporary chat"]']),
    exit: count(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]']) };
  while (JSON.stringify(result).length > 8_192 && result.nodes.length) result.nodes.pop();
  return JSON.stringify(result);
}
function modelURLAllowed() {
  try {
    const url = new URL(document.URL);
    return url.origin === 'https://gemini.google.com' && !url.username && !url.password
      && /^\/(?:u\/[0-9]{1,3}\/)?app(?:\/[A-Za-z0-9_-]+)?\/?$/.test(url.pathname);
  } catch { return false; }
}
const allowedActions = ['inspect', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop', 'discoverModels', 'selectModel', 'modelDiagnostic', 'verifyModel'];
if (input.provider !== 'gemini' || window !== window.top || location.origin !== 'https://gemini.google.com'
  || !modelURLAllowed() || document.URL !== input.expectedURL)
  return { error: 'document_changed', detail: 'document_url' };
if (!allowedActions.includes(input.action)) return { error: 'unknown_action' };
if (typeof input.ownerToken !== 'string' || !/^[a-f0-9-]{36}$/i.test(input.ownerToken))
  return { error: 'document_changed', detail: 'owner_token' };
if (globalThis.__computaModelOwner !== input.ownerToken) {
  if (input.bindOwner === true && globalThis.__computaModelOwner === undefined)
    globalThis.__computaModelOwner = input.ownerToken;
  else return { error: 'document_changed', detail: 'owner_token' };
}
// A newer native invocation can supersede a read still awaiting WebCrypto.
// This witness grants no proof/actions; it only prevents late remount writes.
const submissionReadInvocation = Object.freeze({ owner: input.ownerToken, document,
  operationID: input.operationID ?? null });
globalThis.__computaGeminiReadInvocation = submissionReadInvocation;
const submissionReadActive = () => globalThis.__computaGeminiReadInvocation === submissionReadInvocation;
const submissionReadCurrent = () => submissionReadActive()
  && globalThis.__computaModelOwner === submissionReadInvocation.owner && document === submissionReadInvocation.document;
let submissionRecoveryAttempted = false;
async function modelRecoverSubmissionOnce(record) {
  if (submissionRecoveryAttempted || !submissionReadCurrent()) return null;
  submissionRecoveryAttempted = true;
  const recovered = await modelRecoverVerifiedSubmission(record);
  return submissionReadCurrent() ? recovered : null;
}

if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken) {
  const signal = { ownerToken: input.ownerToken, observer: null };
  signal.observer = new MutationObserver(records => {
    if (!records.some(record => !websiteModelIgnoreOwnPickerMutation(record))) return;
    if (window !== window.top || location.origin !== 'https://gemini.google.com'
      || globalThis.__computaModelOwner !== signal.ownerToken) return;
    // Notification only. Native batches bursts without an inactive-page timer.
    // No page text, tool requests, or native mutation authority cross this bridge.
    try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ ownerToken: signal.ownerToken, kind: 'dom_changed' }); }
    catch { }
  });
  signal.observer.observe(document.documentElement || document, { subtree: true, childList: true,
    characterData: true, attributes: true, attributeOldValue: true, attributeFilter: ['disabled', 'aria-disabled', 'aria-hidden', 'aria-busy',
      'aria-label', 'aria-checked', 'aria-selected', 'aria-controls', 'aria-labelledby', 'aria-expanded', 'class', 'style', 'hidden', 'inert', 'contenteditable', 'data-testid', 'data-is-streaming', 'id'] });
  globalThis.__computaModelSignal = signal;
}
const cleanURL = location.origin + location.pathname.replace(/\/$/, '');
if (input.expectedConversation && cleanURL !== input.expectedConversation)
  return { error: 'conversation_changed', detail: 'conversation_route' };
const ownedMessages = modelUserRoots();
const ownedUserCount = ownedMessages.length;
if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.includes(ownedUserCount))
  return { error: 'conversation_changed', detail: 'user_count' };
const modelUserPayloadText = node => {
  const payload = modelQueryPayload(node);
  return payload.recognized ? payload.text ?? '' : node.innerText || node.textContent || '';
};
function modelExpectedSubmissionProof(sequence) {
  const proofs = input.expectedSubmissionProofs;
  if (!Array.isArray(proofs) || proofs.length > 2 || Object.keys(proofs).join(',') !== proofs.map((_, index) => String(index)).join(',')) return null;
  for (let index = 0; index < proofs.length; index++) {
    const proof = proofs[index];
    if (!proof || Array.isArray(proof) || typeof proof !== 'object' || Object.keys(proof).sort().join(',') !== 'fingerprint,sequence'
      || !Number.isInteger(proof.sequence) || proof.sequence < 1 || proof.sequence > 10_000
      || typeof proof.fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(proof.fingerprint)
      || index > 0 && proof.sequence !== proofs[index - 1].sequence + 1) return null;
  }
  return proofs.find(proof => proof.sequence === sequence) || null;
}
const normalizedBody = node => {
  const text = modelUserPayloadText(node);
  return typeof text === 'string' ? text.replace(/\r\n?/g, '\n').normalize('NFC').trim() : '';
};
const submissionOwnershipEnabled = input.submissionMarker !== undefined || input.submissionSequence !== undefined;
if (submissionOwnershipEnabled && (typeof input.submissionMarker !== 'string' || !/^[a-f0-9-]{36}$/i.test(input.submissionMarker)
  || !Number.isInteger(input.submissionSequence) || input.submissionSequence < 0 || input.submissionSequence > 10_000))
  return modelSubmissionFailure(null, 'invalid_input');
const submissionEditorActions = ['insert', 'sendReady', 'submit'];

function modelSubmissionDiagnostic(record, stage) {
  // Diagnostic predicates cannot grant proof, change state, or expose values.
  // A missing/throwing diagnostic never changes the authoritative failure.
  try {
    const stages = ['invalid_input', 'begin_initial', 'begin_admission', 'begin_digest', 'claim_admission',
      'observe_state', 'observe_record', 'observe_parent', 'observe_pending', 'observe_count', 'observe_body',
      'observe_text', 'observe_digest', 'observe_final'];
    const actions = ['inspect', 'prepare', 'insert', 'sendReady', 'submit', 'verifyModel', 'stop',
      'discoverModels', 'selectModel', 'modelDiagnostic', 'enableTemporary', 'unknown'];
    const phases = ['none', 'insert_claimed', 'inserted', 'send_claimed', 'verified', 'unknown'];
    const boundedSequence = value => Number.isInteger(value) && value >= 0 && value <= 10_000 ? value : null;
    const state = globalThis.__computaGeminiSubmissionState;
    const target = record || state?.pending || state?.lastVerified || null, roots = modelUserRoots();
    const body = boundedSequence(target?.sequence) !== null && target.sequence > 0
      ? modelUserBody(roots[target.sequence - 1]) : null;
    const raw = !stage.startsWith('observe_') && typeof input.prompt === 'string'
      ? input.prompt : body && (body.innerText || body.textContent || '');
    const canonical = typeof raw === 'string' && raw.length <= 180_200 ? raw.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null;
    const marker = target?.marker, markerLine = typeof marker === 'string' && /^[a-f0-9-]{36}$/i.test(marker)
      ? `Computa session marker: ${marker}` : null;
    let contextMatches = false;
    try { contextMatches = modelSubmissionContext(target, input.action === 'submit') === true; } catch { }
    return { kind: 'gemini_submission_v1', stage: stages.includes(stage) ? stage : 'observe_final',
      action: actions.includes(input.action) ? input.action : 'unknown',
      phase: target ? phases.includes(target.phase) ? target.phase : 'unknown' : 'none',
      requestedSequence: boundedSequence(input.submissionSequence), recordSequence: boundedSequence(target?.sequence),
      userCount: Math.min(roots.length, 10_000), statePresent: !!state, recordPresent: !!target, stateRevoked: state?.revoked === true,
      ownerMatches: globalThis.__computaModelOwner === input.ownerToken && (!state || state.owner === input.ownerToken)
        && (!target || target.owner === input.ownerToken),
      documentMatches: !!state && state.document === document && (!target || target.document === document),
      nonceMatches: !!target && typeof input.submissionMarker === 'string' && marker === input.submissionMarker,
      canonicalMatches: canonical !== null && typeof target?.canonical === 'string' && canonical === target.canonical,
      suffixMatches: canonical !== null && markerLine !== null && canonical.split('\n').at(-1) === markerLine
        && canonical.split(markerLine).length === 2,
      contextMatches };
  } catch { return null; }
}
function modelSubmissionBodyDiagnostic(record, body) {
  const result = { kind: 'gemini_submission_body_v1', expectedLength: 0, innerTextLength: 0, textContentLength: 0,
    expectedLines: 0, innerTextLines: 0, textContentLines: 0, innerTextMatches: false, textContentMatches: false,
    innerTextContainsExpected: false, textContentContainsExpected: false, innerTextExpectedOffset: 180_201, textContentExpectedOffset: 180_201,
    firstMismatchIndex: 0, actualCategory: 'end', expectedCategory: 'end', literalDOMAvailable: false,
    literalDOMMatches: false, literalDOMLength: 0, literalDOMUnavailableReason: 'read_failure',
    nodeCount: 0, maximumDepth: 0, paragraphCount: 0, brCount: 0, textNodeCount: 0, spanCount: 0, bodyChildElements: 0 };
  try {
    const normalize = value => typeof value === 'string' && value.length <= 180_200
      ? value.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null;
    const length = value => typeof value === 'string' ? Math.min(value.length, 180_201) : 0;
    const lines = value => typeof value !== 'string' ? 0 : value.length > 180_200 ? 180_201
      : value.split(/\r\n?|\n/).length;
    const expected = record?.canonical, raw = body?.innerText, rawContent = body?.textContent;
    result.expectedLength = length(expected); result.innerTextLength = length(raw); result.textContentLength = length(rawContent);
    result.expectedLines = lines(expected); result.innerTextLines = lines(raw); result.textContentLines = lines(rawContent);
    result.bodyChildElements = Math.min(body?.childElementCount || 0, 8_193);
    const canonical = normalize(expected), actual = normalize(raw), content = normalize(rawContent);
    result.innerTextMatches = canonical !== null && actual === canonical;
    result.textContentMatches = canonical !== null && content === canonical;
    const containedOffset = value => {
      if (canonical === null || !canonical || value === null) return 180_201;
      const index = value.indexOf(canonical);
      return index >= 0 && index <= 180_200 && value.indexOf(canonical, index + 1) === -1 ? index : 180_201;
    };
    result.innerTextExpectedOffset = containedOffset(actual); result.textContentExpectedOffset = containedOffset(content);
    result.innerTextContainsExpected = result.innerTextExpectedOffset !== 180_201;
    result.textContentContainsExpected = result.textContentExpectedOffset !== 180_201;
    if (canonical !== null && actual !== null) {
      let index = 0;
      while (index < Math.min(actual.length, canonical.length) && actual[index] === canonical[index]) index++;
      result.firstMismatchIndex = Math.min(index, 180_201);
      const category = (text, position) => position >= text.length ? 'end' : text[position] === '\n' ? 'linefeed'
        : text[position] === '\r' ? 'carriage_return' : text[position] === ' ' ? 'space'
        : ['"', "'", '`'].includes(text[position]) ? 'quote' : ['[', ']'].includes(text[position]) ? 'bracket'
        : ['{', '}'].includes(text[position]) ? 'brace' : text[position] === '\\' ? 'backslash' : 'other';
      result.actualCategory = category(actual, index); result.expectedCategory = category(canonical, index);
    }
    // This fixed known-node stream is diagnostic only. Unknown or hidden
    // markup, controls and budget exhaustion cannot establish availability.
    const parts = [];
    const fail = reason => { result.literalDOMUnavailableReason = reason; throw new Error('unavailable'); };
    if (!body) fail('missing_body');
    if (canonical === null || actual === null || content === null) fail('length_budget');
    const append = text => {
      if (typeof text !== 'string') fail('read_failure');
      if (result.literalDOMLength + text.length > 180_200) { result.literalDOMLength = 180_201; fail('length_budget'); }
      parts.push(text); result.literalDOMLength += text.length;
    };
    const walk = (node, depth) => {
      result.nodeCount = Math.min(result.nodeCount + 1, 8_193);
      result.maximumDepth = Math.max(result.maximumDepth, Math.min(depth, 65));
      if (result.nodeCount > 8_192) fail('node_budget');
      if (depth > 64) fail('depth_budget');
      if (node.nodeType === 3) { result.textNodeCount++; append(node.data); return; }
      if (node.nodeType !== 1) fail('unsupported_markup');
      if (node.closest('[inert]')) fail('inert');
      const style = getComputedStyle(node);
      if (node.hidden || node.closest('[hidden], [aria-hidden="true"]') || style.display === 'none'
        || ['hidden', 'collapse'].includes(style.visibility)
        || node.tagName !== 'BR' && node.getClientRects().length === 0) fail('hidden');
      if (['BUTTON', 'INPUT', 'TEXTAREA', 'SELECT', 'OPTION', 'A', 'SUMMARY'].includes(node.tagName)
        || ['button', 'textbox', 'link', 'menuitem', 'slider', 'combobox'].includes(node.getAttribute('role'))
        || node.closest('[contenteditable="true"]')) fail('control');
      if (!['DIV', 'SPAN', 'P', 'BR'].includes(node.tagName) || node !== body && node.tagName === 'DIV'
        || node.tagName === 'P' && node !== body && node.parentElement !== body) fail('unsupported_markup');
      if (node.tagName === 'SPAN') result.spanCount++;
      if (node.tagName === 'BR') { result.brCount++; append('\n'); return; }
      if (node.tagName === 'P') { result.paragraphCount++; if (node !== body && parts.length) append('\n'); }
      for (const child of node.childNodes) walk(child, depth + 1);
    };
    walk(body, 0);
    result.literalDOMAvailable = true; result.literalDOMUnavailableReason = 'none';
    result.literalDOMMatches = normalize(parts.join('')) === canonical;
    return result;
  } catch { return result; }
}
function modelFirstFailureProjection(value) {
  // A cache is diagnostic data, including when private test state is malformed.
  // Reconstruct only fixed scalar fields; it is never an ownership input.
  try {
    const keys = ['firstFailureKind', 'stage', 'action', 'sequence', 'digestDiagnostic'];
    const stages = ['begin_digest', 'claim_admission', 'observe_record', 'observe_parent', 'observe_pending',
      'observe_count', 'observe_body', 'observe_text', 'observe_digest', 'observe_final'];
    const actions = ['inspect', 'prepare', 'insert', 'sendReady', 'submit', 'verifyModel', 'stop',
      'discoverModels', 'selectModel', 'modelDiagnostic', 'enableTemporary'];
    if (!value || Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key))
      || value.firstFailureKind !== 'gemini_submission_first_failure_v1' || !stages.includes(value.stage)
      || !actions.includes(value.action) || !Number.isInteger(value.sequence) || value.sequence < 1 || value.sequence > 10_000) return null;
    let digestDiagnostic = null;
    if (value.digestDiagnostic !== null) {
      const digest = value.digestDiagnostic;
      const flags = ['stateSame', 'stateRevoked', 'recordRetained', 'parentRequired', 'parentIntact',
        'remountRequired', 'remountIntact', 'contextMatches', 'rootCountMatches', 'rootsSame', 'firstRootSame',
        'currentRootSame', 'rootConnected', 'bodyConnected', 'bodySame', 'payloadAvailable', 'payloadWithinLimit',
        'bodyTextUnchanged', 'bodyCanonicalMatches', 'priorIntact', 'digestMatches'];
      if (value.stage !== 'observe_digest' || !digest || Object.keys(digest).length !== flags.length + 2
        || digest.kind !== 'gemini_submission_digest_v1' || !Number.isInteger(digest.projectedLength)
        || digest.projectedLength < 0 || digest.projectedLength > 180_201
        || flags.some(key => typeof digest[key] !== 'boolean')
        || !digest.payloadAvailable && digest.projectedLength !== 0
        || digest.payloadWithinLimit !== (digest.payloadAvailable && digest.projectedLength <= 180_200)
        || !digest.payloadWithinLimit && (digest.bodyTextUnchanged || digest.bodyCanonicalMatches)
        || !digest.parentRequired && !digest.parentIntact || !digest.remountRequired && !digest.remountIntact) return null;
      digestDiagnostic = Object.freeze({ kind: digest.kind, projectedLength: digest.projectedLength,
        ...Object.fromEntries(flags.map(key => [key, digest[key]])) });
    }
    return Object.freeze({ firstFailureKind: value.firstFailureKind, stage: value.stage,
      action: value.action, sequence: value.sequence, digestDiagnostic });
  } catch { return null; }
}
function modelRetainedFirstFailure(state, record = null, stage = null, digestDiagnostic = null) {
  try {
    if (!state || globalThis.__computaGeminiSubmissionState !== state || state.document !== document
      || state.owner !== input.ownerToken || globalThis.__computaModelOwner !== input.ownerToken) return null;
    let cache = globalThis.__computaGeminiSubmissionFailures;
    if (cache === undefined && record && !state.revoked) {
      cache = new WeakMap(); globalThis.__computaGeminiSubmissionFailures = cache;
    }
    if (!(cache instanceof WeakMap)) return null;
    const bound = target => target && (state.pending === target || state.lastVerified === target)
      && target.document === document && target.owner === input.ownerToken
      && target.sequence === input.submissionSequence && target.marker === input.submissionMarker
      && typeof target.canonical === 'string' && typeof target.fingerprint === 'string';
    if (!cache.has(state) && record && !state.revoked && bound(record)) {
      const bundle = modelFirstFailureProjection({ firstFailureKind: 'gemini_submission_first_failure_v1',
        stage, action: input.action, sequence: record.sequence, digestDiagnostic });
      if (bundle) cache.set(state, Object.freeze({ state, record, document, owner: input.ownerToken,
        sequence: record.sequence, marker: record.marker, canonical: record.canonical, fingerprint: record.fingerprint, bundle }));
    }
    const saved = cache.get(state);
    if (!saved || saved.state !== state || saved.document !== document || saved.owner !== input.ownerToken || !bound(saved.record)
      || record && saved.record !== record || saved.sequence !== saved.record.sequence || saved.marker !== saved.record.marker
      || saved.canonical !== saved.record.canonical || saved.fingerprint !== saved.record.fingerprint) return null;
    return modelFirstFailureProjection(saved.bundle);
  } catch { return null; }
}
function modelSubmissionFailure(record = null, stage = 'observe_final', body = null, digestDiagnostic = null) {
  // A superseded read must not poison the newer invocation's private state.
  if (!submissionReadActive()) return { error: 'conversation_changed', detail: 'submission_message' };
  const state = globalThis.__computaGeminiSubmissionState;
  const firstFailure = modelRetainedFirstFailure(state, record, stage, digestDiagnostic);
  if (record && state && (state.pending === record || state.lastVerified === record)) state.revoked = true;
  const error = { error: 'conversation_changed', detail: 'submission_message' };
  const diagnostic = modelSubmissionDiagnostic(record, stage);
  const bodyDiagnostic = stage === 'observe_text' && body ? modelSubmissionBodyDiagnostic(record, body) : null;
  let structure = null;
  if (stage === 'observe_text' && body) {
    try { structure = modelFirstUserStructure('submission_text', false, { body, record }); } catch { }
  }
  return { ...error, ...(diagnostic ? { submissionDiagnostic: diagnostic } : {}),
    ...(firstFailure ? { submissionFirstFailure: firstFailure } : {}),
    ...(bodyDiagnostic ? { submissionBodyDiagnostic: bodyDiagnostic } : {}),
    ...(structure ? { debugSubmissionStructure: structure } : {}) };
}
function modelSubmissionContext(record = null, allowSubmitted = false) {
  return window === window.top && location.origin === 'https://gemini.google.com' && modelURLAllowed()
    && document.URL === input.expectedURL && globalThis.__computaModelOwner === input.ownerToken
    && modelTemporaryVerified() && (!record || record.document === document && record.owner === input.ownerToken)
    && (!firstSnapshot || snapshotUnchanged(allowSubmitted));
}
function modelPreviousSubmissionIntact(sequence) {
  if (sequence === 0) return modelUserRoots().length === 0;
  const state = globalThis.__computaGeminiSubmissionState, record = state?.lastVerified, roots = modelUserRoots();
  return !!record && !state.revoked && record.sequence === sequence && record.phase === 'verified'
    && modelSubmissionContext(record) && roots.length === sequence && roots[sequence - 1] === record.root
    && record.body.isConnected && modelUserBody(record.root) === record.body && normalizedBody(record.body) === record.canonical;
}
function modelSubmissionNodesDiagnostic(record, root, body, raw, cause) {
  try {
    return { kind: 'gemini_submission_nodes_v1', cause,
      rootSame: !!root && record.root === root, bodySame: !!body && record.body === body,
      oldRootConnected: !!record.root?.isConnected, oldBodyConnected: !!record.body?.isConnected,
      currentRootConnected: !!root?.isConnected, currentBodyConnected: !!body?.isConnected,
      remountCertificatePresent: !!record.remount,
      projectedCanonicalMatches: !!body && typeof raw === 'string' && raw.length <= 180_200
        && normalizedBody(body) === record.canonical };
  } catch { return null; }
}
function modelSubmissionDigestDiagnostic(state, record, pendingParent, parentValid, remount, remountAllowed,
  roots, current, root, body, text, fingerprint, priorIntact) {
  // Capture only finite post-decision facts, before failure revokes the record.
  // These reads cannot replace the authoritative predicate or grant a proof.
  try {
    const raw = modelUserPayloadText(body);
    const withinLimit = typeof raw === 'string' && raw.length <= 180_200;
    const canonical = withinLimit ? raw.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null;
    return { kind: 'gemini_submission_digest_v1',
      stateSame: globalThis.__computaGeminiSubmissionState === state, stateRevoked: state.revoked === true,
      recordRetained: state.pending === record || state.lastVerified === record,
      parentRequired: parentValid, parentIntact: !parentValid || state.pending === pendingParent
        && pendingParent.phase === 'send_claimed' && pendingParent.sequence === input.submissionSequence
        && pendingParent.marker === input.submissionMarker,
      remountRequired: remountAllowed, remountIntact: !remountAllowed || record.remount === remount,
      contextMatches: modelSubmissionContext(record, input.action === 'submit') === true,
      rootCountMatches: current.length === record.sequence,
      rootsSame: current.length === roots.length && current.every((node, index) => node === roots[index]),
      firstRootSame: current[0] === roots[0], currentRootSame: current[record.sequence - 1] === root,
      rootConnected: root.isConnected === true, bodyConnected: body.isConnected === true,
      bodySame: modelUserBody(root) === body,
      payloadAvailable: typeof raw === 'string', payloadWithinLimit: withinLimit,
      projectedLength: typeof raw === 'string' ? Math.min(raw.length, 180_201) : 0,
      bodyTextUnchanged: canonical !== null && canonical === text,
      bodyCanonicalMatches: canonical !== null && canonical === record.canonical,
      priorIntact: priorIntact() === true, digestMatches: fingerprint === record.fingerprint };
  } catch { return null; }
}
async function modelRecoverVerifiedSubmission(record) {
  // Only one persisted verified record participates. The native pair is an
  // expected-byte pin, never a source of message text or an unsent draft.
  const state = globalThis.__computaGeminiSubmissionState, proof = modelExpectedSubmissionProof(record.sequence);
  const roots = modelUserRoots(), root = roots[record.sequence - 1], body = root && modelUserBody(root);
  const parent = state?.pending, certificate = record.remount;
  const parentCanonical = parent?.canonical ?? null, parentFingerprint = parent?.fingerprint ?? null;
  if (!submissionReadCurrent() || !['inspect', 'verifyModel'].includes(input.action) || !state || state.revoked || state.lastVerified !== record
    || record.phase !== 'verified' || record.document !== document || record.owner !== input.ownerToken
    || proof?.fingerprint !== record.fingerprint || input.allowFirstUserBinding !== false
    || input.expectedFirstUserFingerprint !== firstUserFingerprint
    || globalThis.__computaModelFirstProof?.fingerprint !== firstUserFingerprint
    || globalThis.__computaModelFirstProof?.marker !== input.expectedFirstUserMarker
    || !firstSnapshot || !modelSubmissionContext(record) || !record.root || !record.body
    || record.root.isConnected || record.body.isConnected || !root || !body || root === record.root || body === record.body
    || roots.length < record.sequence || roots.length > record.sequence + 1
    || parent && (parent.sequence !== record.sequence + 1 || parent.sequence !== input.submissionSequence
      || parent.marker !== input.submissionMarker || parent.phase !== 'send_claimed')
    || !parent && (roots.length !== record.sequence || input.submissionSequence !== record.sequence || input.submissionMarker !== record.marker)) return null;
  if (certificate && (certificate.kind !== 'submission' || input.action !== 'inspect'
    || certificate.sequence !== record.sequence || certificate.fingerprint !== proof.fingerprint
    || certificate.previousRoot !== record.root || certificate.previousBody !== record.body
    || certificate.root !== root || certificate.body !== body || certificate.pendingParent !== parent
    || certificate.parentCanonical !== parentCanonical || certificate.parentFingerprint !== parentFingerprint
    || !Array.isArray(certificate.roots) || certificate.roots.length > roots.length
    || certificate.roots.some((node, index) => roots[index] !== node)
    || roots.length > certificate.roots.length && !(parent && roots.length === certificate.roots.length + 1))) return null;
  const oldRoot = record.root, oldBody = record.body, canonical = record.canonical, marker = record.marker;
  const read = () => {
    const payload = modelQueryPayload(body, { record, root, body });
    const text = payload.recognized ? payload.text : body.innerText || body.textContent || '';
    return typeof text === 'string' && text.length <= 180_200 ? text.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null;
  };
  const text = read(), markerLine = `Computa session marker: ${marker}`;
  if (text !== canonical || text.split('\n').at(-1) !== markerLine || text.split(markerLine).length !== 2) return null;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const current = modelUserRoots();
  const sameRoots = current.length === roots.length && roots.every((node, index) => current[index] === node);
  const append = !sameRoots && parent && current.length === roots.length + 1 && roots.length === record.sequence
    && roots.every((node, index) => current[index] === node)
    && websiteModelAcknowledgedUserAppend(input, roots.length, current.length,
      { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity }, modelTemporaryVerified());
  if (!submissionReadCurrent() || !sameRoots && !append || globalThis.__computaGeminiSubmissionState !== state || state.revoked
    || state.lastVerified !== record || state.pending !== parent || record.phase !== 'verified'
    || parent && (parent.phase !== 'send_claimed' || parent.sequence !== record.sequence + 1
      || parent.sequence !== input.submissionSequence || parent.marker !== input.submissionMarker
      || parent.canonical !== parentCanonical || parent.fingerprint !== parentFingerprint)
    || record.root !== oldRoot || record.body !== oldBody || oldRoot.isConnected || oldBody.isConnected
    || record.canonical !== canonical || record.marker !== marker || record.fingerprint !== proof.fingerprint
    || record.remount !== certificate || modelExpectedSubmissionProof(record.sequence)?.fingerprint !== proof.fingerprint
    || !root.isConnected || !body.isConnected || current[record.sequence - 1] !== root || modelUserBody(root) !== body
    || read() !== text || fingerprint !== proof.fingerprint || !modelSubmissionContext(record, !!append)) return null;
  if (certificate) {
    // A fresh inspect is the only consumer. Continue normal current/pending
    // proof checks afterwards; no answer or new-round proof is supplied here.
    record.root = root; record.body = body; record.remount = null;
    return append || {};
  }
  record.remount = { kind: 'submission', sequence: record.sequence, fingerprint,
    previousRoot: oldRoot, previousBody: oldBody, root, body, roots: current, pendingParent: parent, parentCanonical, parentFingerprint };
  return { error: 'submission_observation_replaced', detail: 'readonly_model_observation',
    replacementSubmissionProof: { sequence: record.sequence, fingerprint } };
}
async function modelObserveSubmission(sequence, allowPending = false, pendingParent = null) {
  if (!submissionReadActive()) return { error: 'conversation_changed', detail: 'submission_message' };
  const state = globalThis.__computaGeminiSubmissionState;
  if (sequence === 0) return modelUserRoots().length === 0 ? {} : modelSubmissionFailure(null, 'observe_count');
  if (!state || state.revoked || state.document !== document || state.owner !== input.ownerToken) return modelSubmissionFailure(null, 'observe_state');
  const bound = state.lastVerified;
  if (bound?.phase === 'verified' && input.expectedSubmissionProofs !== undefined && ['inspect', 'verifyModel'].includes(input.action)
    && (bound.remount?.kind === 'submission' || !bound.root.isConnected && !bound.body.isConnected)) {
    const recovered = await modelRecoverSubmissionOnce(bound);
    if (!submissionReadActive()) return { error: 'conversation_changed', detail: 'submission_message' };
    if (recovered?.error) return recovered;
  }
  const record = state.lastVerified?.sequence === sequence ? state.lastVerified : state.pending?.sequence === sequence ? state.pending : null;
  if (!record || !['send_claimed', 'verified'].includes(record.phase)) return modelSubmissionFailure(record, 'observe_record');
  const parentValid = !!pendingParent && state.pending === pendingParent && pendingParent.phase === 'send_claimed'
    && pendingParent.sequence === sequence + 1 && pendingParent.sequence === input.submissionSequence
    && pendingParent.marker === input.submissionMarker && state.lastVerified === record && record.phase === 'verified';
  if (pendingParent && !parentValid) return modelSubmissionFailure(record, 'observe_parent');
  if (!submissionEditorActions.includes(input.action) && input.submissionMarker !== record.marker && !parentValid)
    return modelSubmissionFailure(record, 'observe_parent');
  const roots = modelUserRoots();
  if (allowPending && record.phase === 'send_claimed' && roots.length === sequence - 1
    && modelSubmissionContext(record, input.action === 'submit')) {
    // No proof for the unrendered round. Recheck only the previous whole body
    // so native can retain its already-confirmed count during this pending read.
    const previous = sequence > 1 ? await modelObserveSubmission(sequence - 1, false, record) : {};
    return previous.error ? previous : { ...previous, pending: true };
  }
  if (roots.length !== sequence || !modelSubmissionContext(record, input.action === 'submit')) return modelSubmissionFailure(record, 'observe_count');
  const root = roots[sequence - 1], body = modelUserBody(root);
  const raw = body && modelUserPayloadText(body);
  const remount = record.remount;
  const remountAllowed = sequence === 1 && input.action === 'inspect' && input.allowFirstUserBinding === false
    && remount?.kind !== 'submission'
    && (input.expectedSubmissionProofs === undefined || modelExpectedSubmissionProof(sequence)?.fingerprint === record.fingerprint)
    && remount?.root === root && remount.body === body && remount.previousRoot === record.root
    && remount.previousBody === record.body && !record.root.isConnected && !record.body.isConnected
    && input.expectedFirstUserFingerprint === record.fingerprint
    && globalThis.__computaModelFirstProof?.fingerprint === record.fingerprint
    && globalThis.__computaModelFirstProof?.marker === record.marker;
  const bodyCause = !body ? 'body_missing' : typeof raw !== 'string' ? 'payload_type' : raw.length > 180_200 ? 'payload_limit'
    : record.root && (record.root !== root || record.body !== body) && !remountAllowed
      || sequence > 1 && (root === roots[0] || body === modelUserBody(roots[0])) ? 'physical_replaced' : null;
  if (bodyCause) {
    // A first root can be replaced after the preceding invocation returned.
    // Use its persisted OLD physical snapshot to obtain the existing discard
    // receipt; only the next fresh inspect may consume that certificate.
    if (bodyCause === 'physical_replaced' && sequence === 1 && input.expectedSubmissionProofs === undefined && ['inspect', 'verifyModel'].includes(input.action)
      && state.lastVerified === record && state.pending === null && record.phase === 'verified' && !record.remount
      && record.root && record.body && !record.root.isConnected && !record.body.isConnected
      && firstSnapshot?.root === root && firstSnapshot.body === body && snapshotUnchanged()
      && firstUserFingerprint === record.fingerprint && input.expectedFirstUserFingerprint === record.fingerprint
      && globalThis.__computaModelFirstProof?.fingerprint === record.fingerprint
      && globalThis.__computaModelFirstProof?.marker === record.marker) {
      const discarded = await modelFirstUserReplacementObservation({ root: record.root, body: record.body,
        text: record.canonical, identity: firstUserIdentity });
      if (discarded) return discarded;
    }
    const submissionNodesDiagnostic = modelSubmissionNodesDiagnostic(record, root, body, raw, bodyCause);
    return { ...modelSubmissionFailure(record, 'observe_body'),
      ...(submissionNodesDiagnostic ? { submissionNodesDiagnostic } : {}) };
  }
  const text = normalizedBody(body), markerLine = `Computa session marker: ${record.marker}`;
  if (text !== record.canonical || text.split('\n').at(-1) !== markerLine || text.split(markerLine).length !== 2)
    return modelSubmissionFailure(record, 'observe_text', body);
  const previous = state.lastVerified;
  const priorIntact = () => !previous || previous === record || previous.sequence !== sequence - 1
    || roots[previous.sequence - 1] === previous.root && previous.body.isConnected
      && modelUserBody(previous.root) === previous.body && normalizedBody(previous.body) === previous.canonical;
  if (!priorIntact()) return modelSubmissionFailure(record, 'observe_pending');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const current = modelUserRoots();
  if (parentValid && current.length === sequence + 1) {
    const append = websiteModelAcknowledgedUserAppend(input, ownedUserCount, current.length,
      firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity } : null,
      modelTemporaryVerified());
    return append || (firstSnapshot && !snapshotUnchanged(true) ? modelFirstUserFailure('snapshot_before_action') : modelSubmissionFailure(record, 'observe_pending'));
  }
  if (globalThis.__computaGeminiSubmissionState !== state || state.revoked
    || state.pending !== record && state.lastVerified !== record
    || parentValid && (state.pending !== pendingParent || pendingParent.phase !== 'send_claimed'
      || pendingParent.sequence !== input.submissionSequence || pendingParent.marker !== input.submissionMarker)
    || remountAllowed && record.remount !== remount
    || !modelSubmissionContext(record, input.action === 'submit')
    || current.length !== sequence || current.some((node, index) => node !== roots[index])
    || !root.isConnected || !body.isConnected || modelUserBody(root) !== body || normalizedBody(body) !== text
    || !priorIntact() || fingerprint !== record.fingerprint) {
    // Already verified current queries can remount while SHA-256 yields.
    // Discard only after the existing helper proves the entire replacement;
    // the native single fresh-inspect budget still owns any later rebinding.
    if (sequence > 1 && !submissionRecoveryAttempted && submissionReadCurrent()
      && globalThis.__computaGeminiSubmissionState === state && !state.revoked
      && state.lastVerified === record && state.pending === null && !pendingParent
      && record.phase === 'verified' && record.root === root && record.body === body && record.remount === null
      && !root.isConnected && !body.isConnected && current.length === sequence
      && current[sequence - 1] !== root && current.every((node, index) => index === sequence - 1 || node === roots[index])
      && modelSubmissionContext(record) && priorIntact() && fingerprint === record.fingerprint) {
      const recovered = await modelRecoverSubmissionOnce(record);
      if (recovered?.error === 'submission_observation_replaced') return recovered;
    }
    if (!submissionReadActive()) return { error: 'conversation_changed', detail: 'submission_message' };
    const diagnostic = modelSubmissionDigestDiagnostic(state, record, pendingParent, parentValid, remount, remountAllowed,
      roots, current, root, body, text, fingerprint, priorIntact);
    return { ...modelSubmissionFailure(record, 'observe_digest', null, diagnostic),
      ...(diagnostic ? { submissionDigestDiagnostic: diagnostic } : {}) };
  }
  record.root = root; record.body = body; record.phase = 'verified'; record.remount = null;
  state.lastVerified = record; if (state.pending === record) state.pending = null;
  return { submissionProof: { sequence, fingerprint } };
}
async function modelBeginSubmission(prompt, composer) {
  if (!submissionOwnershipEnabled) return {};
  const sequence = input.submissionSequence, marker = input.submissionMarker;
  const canonical = prompt.replace(/\r\n?/g, '\n').normalize('NFC').trim(), markerLine = `Computa session marker: ${marker}`;
  let state = globalThis.__computaGeminiSubmissionState;
  if (!state) {
    if (sequence !== 1 || ownedUserCount !== 0) return modelSubmissionFailure(null, 'begin_initial');
    state = { document, owner: input.ownerToken, lastVerified: null, pending: null, markers: new Set(), revoked: false };
    globalThis.__computaGeminiSubmissionState = state;
  }
  if (state.revoked || state.document !== document || state.owner !== input.ownerToken || state.pending
    || sequence !== (state.lastVerified?.sequence || 0) + 1 || ownedUserCount !== sequence - 1
    || state.markers.has(marker) || sequence === 1 && marker !== input.expectedFirstUserMarker
    || sequence > 1 && marker === input.expectedFirstUserMarker || canonical.split('\n').at(-1) !== markerLine
    || canonical.split(markerLine).length !== 2 || !canonical.endsWith(`\n\n${markerLine}`)
    || !modelSubmissionContext()) return modelSubmissionFailure(null, 'begin_admission');
  const record = { sequence, marker, canonical, document, owner: input.ownerToken, phase: 'insert_claimed', fingerprint: null, root: null, body: null };
  state.pending = record; state.markers.add(marker);
  const roots = modelUserRoots();
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical));
  const current = modelUserRoots(), value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
  if (globalThis.__computaGeminiSubmissionState !== state || state.pending !== record || state.revoked
    || !modelSubmissionContext(record) || current.length !== sequence - 1 || current.some((node, index) => node !== roots[index])
    || !modelEnabled(composer) || value?.trim() || !modelPreviousSubmissionIntact(sequence - 1)) return modelSubmissionFailure(record, 'begin_digest');
  record.fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  return {};
}
function modelClaimSubmission(prompt) {
  if (!submissionOwnershipEnabled) return {};
  const state = globalThis.__computaGeminiSubmissionState, record = state?.pending;
  if (!state || state.revoked || !record || record.phase !== 'inserted'
    || record.sequence !== input.submissionSequence || record.marker !== input.submissionMarker
    || record.canonical !== prompt.replace(/\r\n?/g, '\n').normalize('NFC').trim()
    || ownedUserCount !== record.sequence - 1 || !modelSubmissionContext(record)
    || !modelPreviousSubmissionIntact(record.sequence - 1)) return modelSubmissionFailure(record, 'claim_admission');
  record.phase = 'send_claimed'; return {};
}
async function modelSubmissionResult(observed) {
  if (!submissionOwnershipEnabled || observed.error) return observed;
  const capability = { submissionOwnershipCapability: 'per_submission_ownership_v1' };
  if (!['inspect', 'prepare', 'verifyModel', ...submissionEditorActions].includes(input.action)) return { ...observed, ...capability };
  // The claimed click acknowledges dispatch only. Rendering can append or
  // remount messages after it; a fresh read must prove every submitted body.
  // Never hash, rebind or revoke a body from the post-Send mutation result.
  if (input.action === 'submit' && observed.submitted === true)
    return { ...observed, ...capability, submissionPending: true, text: '', answerComplete: false };
  const sequence = input.submissionSequence - (['insert', 'sendReady'].includes(input.action) ? 1 : 0);
  const proof = await modelObserveSubmission(sequence, ['inspect', 'verifyModel', 'submit'].includes(input.action));
  if (proof.error) return proof;
  return { ...observed, ...capability, ...(proof.submissionProof ? { submissionProof: proof.submissionProof } : {}),
    ...(proof.pending ? { submissionPending: true } : {}),
    ...(proof.pending && ['inspect', 'verifyModel'].includes(input.action) ? { text: '', answerComplete: false, pending: true } : {}) };
}
function modelFirstUserStructure(reason, allowSubmittedUser = false, submission = null) {
  const roots = modelUserRoots();
  const bodyScoped = reason === 'submission_text' && submission?.body && submission?.record;
  const body = bodyScoped ? submission.body : roots[0] && modelUserBody(roots[0]);
  const root = bodyScoped ? body.closest('user-query') : roots[0];
  const queryPayload = body ? modelQueryPayload(body) : null;
  const selectedBodyScope = bodyScoped || queryPayload?.recognized === true;
  const rendered = body ? normalizedBody(body) : '', lines = rendered.split('\n');
  const marker = bodyScoped ? submission.record.marker : input.expectedFirstUserMarker;
  const markerLine = typeof marker === 'string' && /^[a-f0-9-]{36}$/i.test(marker) ? `Computa session marker: ${marker}` : null;
  const utilities = ['block', 'flex', 'inline-flex', 'relative', 'truncate', 'whitespace-pre-wrap', 'whitespace-normal',
    'break-words', 'overflow-hidden', 'overflow-auto', 'hidden', 'text-sm', 'items-center', 'min-w-0', 'w-full'];
  const shape = node => ({ tag: node && /^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'none',
    classes: node ? [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)
      && (/^(?:query-|user-query-|gds-|mat-|cdk-|ng-)/.test(name) || utilities.includes(name))
      && !rendered.includes(name) && !(globalThis.__computaModelFirstPrompt || '').includes(name)
      && !(bodyScoped ? submission.record.canonical : '').includes(name)).slice(0, 6) : [] });
  const boundedSubmissionNodeText = value => {
    if (typeof value !== 'string' || value.length > 180_200) return null;
    const text = value.replace(/\r\n?/g, '\n').normalize('NFC').trim();
    return text.length <= 180_200 ? text : null;
  };
  const scopeRoot = selectedBodyScope ? body : root;
  const descendants = [], queue = scopeRoot ? [...scopeRoot.children].filter(node => node.nodeType === 1)
    .map((node, index) => ({ node, path: [Math.min(index, 1_000)] })) : [];
  for (let index = 0; index < queue.length && descendants.length < 16; index++) {
    const { node, path } = queue[index];
    const text = bodyScoped ? boundedSubmissionNodeText(node.innerText || node.textContent || '') : normalizedBody(node);
    descendants.push({ ...shape(node), path, childElements: Math.min(node.childElementCount, 1_000),
      controls: Math.min(node.querySelectorAll('button, [role="button"]').length, 1_000),
      textLength: text === null ? 220_001 : Math.min(text.length, 220_001), markerExact: markerLine !== null && text === markerLine,
      markerContained: markerLine !== null && text !== null && text.includes(markerLine), visible: modelVisible(node),
      editable: node.getAttribute('contenteditable') === 'true',
      ...(node.classList.contains('cdk-visually-hidden') ? modelQueryHeadingFacts(node) : {}),
      ...(bodyScoped ? {
        outboundInnerTextMatches: text !== null && text === submission.record.canonical,
        outboundTextContentMatches: boundedSubmissionNodeText(node.textContent || '') === submission.record.canonical
      } : {}) });
    if (path.length < 16) [...node.children].filter(child => child.nodeType === 1).slice(0, 16)
      .forEach((child, childIndex) => queue.push({ node: child, path: [...path, childIndex] }));
  }
  const pinned = globalThis.__computaModelFirstProof;
  const diagnostic = { kind: 'first_user_structure', provider: 'gemini', reason, userCount: Math.min(roots.length, 1_000),
    root: shape(root), body: shape(body), textLength: Math.min(rendered.length, 220_001), lineCount: Math.min(lines.length, 220_001),
    markerFinalLine: markerLine !== null && lines.at(-1) === markerLine,
    markerOccurrences: Math.min(markerLine === null ? 0 : lines.filter(line => line === markerLine).length, 1_000),
    controlDescendants: Math.min(body ? body.querySelectorAll('button, [role="button"]').length : 0, 1_000),
    submitted: globalThis.__computaModelFirstSubmitted === true,
    markerMatches: bodyScoped ? input.submissionMarker === marker : globalThis.__computaModelFirstMarker === marker,
    ...(selectedBodyScope ? { descendantScope: 'selected_body' } : {}),
    ...(queryPayload?.queryTemplate ? { queryTemplate: queryPayload.queryTemplate } : {}), descendants };
  if (firstUserFingerprint !== null) {
    if (typeof pinned?.fingerprint === 'string') diagnostic.pinnedFingerprintMatch = pinned.fingerprint === firstUserFingerprint;
    if (typeof input.expectedFirstUserFingerprint === 'string') diagnostic.nativeFingerprintMatch = input.expectedFirstUserFingerprint === firstUserFingerprint;
  }
  if (firstSnapshot) diagnostic.snapshot = { rootSame: roots[0] === firstSnapshot.root,
    bodySame: !!roots[0] && modelUserBody(roots[0]) === firstSnapshot.body, bodyConnected: firstSnapshot.body.isConnected,
    textSame: normalizedBody(firstSnapshot.body) === firstSnapshot.text,
    countSame: roots.length === ownedUserCount || allowSubmittedUser && roots.length === ownedUserCount + 1,
    urlSame: document.URL === input.expectedURL, originSame: location.origin === 'https://gemini.google.com',
    ownerSame: globalThis.__computaModelOwner === input.ownerToken };
  while (JSON.stringify(diagnostic).length > 8_192 && diagnostic.descendants.length) diagnostic.descendants.pop();
  return JSON.stringify(diagnostic);
}
async function modelFirstUserReplacementObservation(snapshot) {
  // Only the existing exact first-lineage discard proof can propose a remount.
  // It still admits no result: native must request one fresh full inspect.
  const result = await websiteModelReplacementObservation(input, ownedUserCount, snapshot,
    { roots: modelUserRoots, body: modelUserBody, text: normalizedBody, identity: () => firstUserIdentity, temporary: modelTemporaryVerified });
  if (result?.error === 'first_user_observation_replaced' && submissionOwnershipEnabled) {
    const state = globalThis.__computaGeminiSubmissionState, record = state?.lastVerified;
    const roots = modelUserRoots(), root = roots[0], body = root && modelUserBody(root);
    if (state && !state.revoked && record?.sequence === 1 && record.phase === 'verified'
      && record.root === snapshot.root && record.body === snapshot.body && !record.remount
      && record.fingerprint === input.expectedFirstUserFingerprint && body
      && normalizedBody(body) === record.canonical) {
      record.remount = { previousRoot: record.root, previousBody: record.body, root, body };
    }
  }
  return result;
}
function modelFirstUserFailure(reason, allowSubmittedUser = false) {
  return { error: 'conversation_changed', detail: 'first_user_message',
    debugStructure: modelFirstUserStructure(reason, allowSubmittedUser) };
}
let firstSnapshot = null, firstUserFingerprint = null, firstUserIdentity = null;
const snapshotUnchanged = (allowSubmittedUser = false) => {
  const current = modelUserRoots();
  return window === window.top && location.origin === 'https://gemini.google.com' && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken
    && (current.length === ownedUserCount || allowSubmittedUser && current.length === ownedUserCount + 1)
    && current[0] === firstSnapshot.root && firstSnapshot.body.isConnected
    && modelUserBody(current[0]) === firstSnapshot.body && normalizedBody(firstSnapshot.body) === firstSnapshot.text
    && true;
};
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker, first = modelUserBody(ownedMessages[0]);
  if (!first) return modelFirstUserFailure('body_empty');
  const rendered = normalizedBody(first), markerLine = `Computa session marker: ${marker}`;
  const lines = rendered.split('\n');
  if (typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker)
    || globalThis.__computaModelFirstSubmitted !== true || globalThis.__computaModelFirstMarker !== marker
    || rendered.length > 180_200 || lines.at(-1) !== markerLine
    || lines.filter(line => line === markerLine).length !== 1 || !lines.slice(0, -1).join('\n').trim())
    return modelFirstUserFailure(typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker) ? 'marker_invalid'
      : globalThis.__computaModelFirstSubmitted !== true ? 'submission_unclaimed'
      : globalThis.__computaModelFirstMarker !== marker ? 'marker_mismatch'
      : rendered.length > 180_200 ? 'body_limit' : lines.at(-1) !== markerLine ? 'marker_not_final'
      : lines.filter(line => line === markerLine).length !== 1 ? 'marker_duplicate' : 'body_empty');

  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered, identity: firstUserIdentity };
  websiteModelDiagnosticPhase('first_user_hash');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  if (!snapshotUnchanged()) {
    const current = modelUserRoots(), pinned = globalThis.__computaModelFirstProof;
    const append = websiteModelAcknowledgedUserAppend(input, ownedUserCount, current.length,
      { snapshotIntact: snapshotUnchanged(true), fingerprint, identity: firstUserIdentity }, modelTemporaryVerified());
    if (append) return append;
    // A single acknowledged continuation can appear while this read awaits SHA.
    // Discard the observation; the next inspect must recheck the complete state.
    if (input.expectedModelChoice == null && input.action === 'inspect' && input.allowFirstUserBinding === false
      && input.expectedUserCounts.length === 2 && input.expectedUserCounts[0] === ownedUserCount
      && input.expectedUserCounts[1] === ownedUserCount + 1 && current.length === ownedUserCount + 1
      && globalThis.__computaModelLastSubmissionCount === ownedUserCount
      && pinned?.marker === marker && pinned.fingerprint === fingerprint && pinned.identity === firstUserIdentity
      && input.expectedFirstUserFingerprint === fingerprint
      && window === window.top && location.origin === 'https://gemini.google.com' && document.URL === input.expectedURL
      && globalThis.__computaModelOwner === input.ownerToken && current[0] === firstSnapshot.root
      && firstSnapshot.body.isConnected && modelUserBody(current[0]) === firstSnapshot.body
      && normalizedBody(firstSnapshot.body) === firstSnapshot.text && modelTemporaryVerified())
      return { error: 'submission_observation_pending' };
    return await modelFirstUserReplacementObservation(firstSnapshot)
      || modelFirstUserFailure('snapshot_before_action');
  }
  if (!modelTemporaryVerified()) return { error: 'temporary_mode_unverified' };
  firstUserFingerprint = fingerprint;
  const pinned = globalThis.__computaModelFirstProof;
  if (pinned) {
    if (pinned.marker !== marker || pinned.fingerprint !== firstUserFingerprint
      || pinned.identity !== firstUserIdentity
      || input.expectedFirstUserFingerprint !== pinned.fingerprint
        && !(input.expectedFirstUserFingerprint == null && input.allowFirstUserBinding === true
          && input.action === 'inspect' && ownedUserCount === 1))
      return modelFirstUserFailure(pinned.fingerprint !== firstUserFingerprint ? 'pinned_fingerprint'
        : input.expectedFirstUserFingerprint !== pinned.fingerprint ? 'native_fingerprint' : 'binding_not_authorized');
  } else if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || ownedUserCount !== 1
    || input.expectedFirstUserFingerprint != null)
    return modelFirstUserFailure('binding_not_authorized');
} else if (input.expectedFirstUserFingerprint != null || globalThis.__computaModelFirstProof)
  return modelFirstUserFailure('first_missing');

async function providerPageAction() {
  websiteModelDiagnosticPhase('page_action');
  if (submissionOwnershipEnabled && ['inspect', 'prepare', 'verifyModel', ...submissionEditorActions].includes(input.action)) {
    const sequence = input.submissionSequence - (submissionEditorActions.includes(input.action) ? 1 : 0);
    const prior = await modelObserveSubmission(sequence, ['inspect', 'verifyModel'].includes(input.action));
    if (prior.error) return prior;
  }
  const modelState = websiteModelPickerState('gemini');
  if (['discoverModels', 'selectModel', 'modelDiagnostic'].includes(input.action))
    return websiteModelPickerAction(modelState, input, ownedUserCount === 0
      && globalThis.__computaModelFirstSubmitted !== true
      && document.querySelectorAll('model-response, .model-response-text').length === 0);
  if (input.action !== 'stop' && input.expectedModelChoice != null) {
    const proof = await websiteModelReadEvidence('gemini', input.expectedModelChoice, null,
      { scope: 'action_precheck', action: input.action });
    if (proof.error) return proof;
    // Reading a freshly mounted picker yields. Before any editor mutation,
    // recheck the same native ownership and first-message snapshot again.
    const currentCount = modelUserRoots().length;
    if (window !== window.top || document.URL !== input.expectedURL || globalThis.__computaModelOwner !== input.ownerToken
      || currentCount !== ownedUserCount) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, currentCount,
        firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity } : null,
        modelTemporaryVerified()) || { error: 'conversation_changed', detail: 'user_count' };
    if (firstSnapshot && !snapshotUnchanged()) return await modelFirstUserReplacementObservation(firstSnapshot)
      || modelFirstUserFailure('snapshot_after_model_read');
    modelState.evidence = proof.modelEvidence;
  }
  if (input.action === 'verifyModel') return { modelEvidence: modelState.evidence };

  const { action, prompt, expectedFirstUserMarker } = input;
  const composer = modelFind(['[contenteditable="true"][aria-label="Enter a prompt for Gemini"]', 'rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']);
  const candidates = [...document.querySelectorAll('.model-response-text, model-response .markdown')].filter(modelVisible);
  const answers = candidates.filter(node => !candidates.some(other => other !== node && other.contains(node)));
  const answer = answers.at(-1), stop = modelFind(['button[aria-label="Stop response"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]', 'button.stop-button']);
  const response = answer?.closest('model-response');
  const busy = !!stop || !!response && response.getAttribute('aria-busy') === 'true';
  const interrupted = false;
  const copies = response && answers.filter(node => response === node || response.contains(node)).length === 1
    ? [...response.querySelectorAll('button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]')] : [];
  const scopedCopies = copies.length, enabledCopies = copies.filter(modelEnabled).length;
  const answerComplete = !busy && enabledCopies > 0;
  const temporary = modelTemporaryVerified();
  const temporaryActionAvailable = modelEnabled(modelFind(['button[aria-label="Temporary chat"]']));
  const state = { modelEvidence: modelState.evidence, url: document.URL, temporary, temporaryActionAvailable, conversationIdentity: null, composer: !!composer,
    responseCount: answers.length, userCount: ownedUserCount, firstUserIdentity, firstUserFingerprint,
    firstUserVerified: ownedUserCount > 0, firstUserMarkerVerified: ownedUserCount > 0,
    busy, interrupted, text: modelResponseText(answer).slice(0, 220_001),
    answerComplete, completionEvidence: { codeStructure: modelResponseStructure(answer), modernMarkers: 0, logicalAnswers: answers.length,
      scopedCopies, enabledCopies, depth: -1 } };
  if (action === 'inspect') {
    const signIn = !composer && [...document.querySelectorAll('a, button')].filter(modelVisible)
      .some(node => /^(?:Log in|Sign in)(?:\s|$)/i.test(node.getAttribute('aria-label') || (node.innerText || '').trim()));
    return { ...state, signIn, debugStructure: modelReadinessStructure() };
  }
  if (action === 'enableTemporary') {
    if (temporary) return { ...state, enabled: true };
    if (ownedUserCount || answers.length || globalThis.__computaModelFirstSubmitted) return { error: 'not_fresh' };
    if (globalThis.__computaModelTemporaryRequested) return { error: 'temporary_mode_unverified' };
    const toggle = modelFind(['button[aria-label="Temporary chat"]']);
    if (!modelEnabled(toggle)) return { error: 'temporary_mode_unavailable' };
    // Claim before the single click. A lost acknowledgment cannot toggle back.
    globalThis.__computaModelTemporaryRequested = true;
    toggle.click();
    return { ...state, enabled: false };
  }
  if (!temporary) return { error: 'temporary_mode_unverified', detail: 'mode_controls_unverified' };
  if (action === 'stop') {
    if (modelEnabled(stop)) stop.click();
    return { ...state, stopped: !!stop };
  }
  if (!modelEnabled(composer) || busy) return { error: 'composer_unavailable',
    detail: !composer ? 'missing_composer' : !modelEnabled(composer) ? 'inactive_composer' : 'response_busy' };
  const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
  if (action === 'prepare') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    composer.focus();
    return { ...state, prepared: document.activeElement === composer || composer.contains(document.activeElement) };
  }
  if (typeof prompt !== 'string' || !prompt.trim() || prompt.length > 180_000) return { error: 'prompt_not_inserted' };
  if (action === 'insert') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    const claimed = await modelBeginSubmission(prompt, composer);
    if (claimed.error) return claimed;
    if (ownedUserCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || typeof expectedFirstUserMarker !== 'string'
        || !/^[a-f0-9-]{36}$/i.test(expectedFirstUserMarker)
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return modelFirstUserFailure('first_insert');
      globalThis.__computaModelFirstPrompt = prompt;
      globalThis.__computaModelFirstPromptContext = { document, owner: input.ownerToken, marker: expectedFirstUserMarker };
    }
    composer.focus();
    if (composer instanceof HTMLTextAreaElement) {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(composer, prompt);
      composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
    } else {
      const selection = window.getSelection();
      if (!selection) return { error: 'caret_unavailable' };
      const range = document.createRange();
      range.selectNodeContents(composer); range.collapse(false);
      selection.removeAllRanges(); selection.addRange(range);
      if (!composer.contains(selection.anchorNode) || !composer.contains(selection.focusNode)) return { error: 'caret_unavailable' };
      if (composer.classList.contains('ProseMirror')) {
        const paragraph = document.createElement('p');
        prompt.split('\n').forEach((line, index) => {
          if (index) paragraph.appendChild(document.createElement('br'));
          paragraph.appendChild(document.createTextNode(line));
        });
        composer.replaceChildren(paragraph);
        range.selectNodeContents(paragraph); range.collapse(false);
        selection.removeAllRanges(); selection.addRange(range);
        composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
      } else if (composer.classList.contains('ql-editor')) {
        // WebKit insertText applies smart punctuation on the live Quill editor.
        // Quill owns one paragraph per line; write literal nodes instead of
        // passing the text through the browser's editing substitutions.
        const paragraphs = prompt.split('\n').map(line => {
          const paragraph = document.createElement('p');
          paragraph.appendChild(line ? document.createTextNode(line) : document.createElement('br'));
          return paragraph;
        });
        composer.replaceChildren(...paragraphs);
        range.selectNodeContents(paragraphs.at(-1)); range.collapse(false);
        selection.removeAllRanges(); selection.addRange(range);
        composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
      } else if (!document.execCommand('insertText', false, prompt)) return { error: 'insert_command_rejected' };
    }
    if (submissionOwnershipEnabled) globalThis.__computaGeminiSubmissionState.pending.phase = 'inserted';
    return { ...state, inserted: true };
  }
  const actual = (value || '').replace(/\r\n/g, '\n').trim(), expected = prompt.trim();
  if (actual !== expected) {
    const detail = !actual ? 'editor_empty'
      : actual.replace(/\n+/g, '\n') === expected.replace(/\n+/g, '\n') ? 'line_break_expansion'
      : actual.replace(/\u00a0/g, ' ') === expected ? 'nonbreaking_spaces' : 'text_difference';
    return { error: 'prompt_not_inserted', detail, ...modelEditorDifference(actual, expected), actualLength: actual.length, expectedLength: expected.length,
      actualLines: actual.split('\n').length, expectedLines: expected.split('\n').length };
  }
  const send = modelFind(['button[aria-label="Send message"]', 'button[aria-label="Send"]', 'button.send-button']);
  if (action === 'sendReady') return { ...state, sendReady: modelEnabled(send) };
  if (!modelEnabled(send)) return { error: 'send_unavailable' };
  const submission = modelClaimSubmission(prompt);
  if (submission.error) return submission;
  if (globalThis.__computaModelLastSubmissionCount !== undefined
    && ownedUserCount <= globalThis.__computaModelLastSubmissionCount)
    return { error: 'conversation_changed', detail: 'user_count' };
  if (ownedUserCount === 0) {
    if (globalThis.__computaModelFirstSubmitted || globalThis.__computaModelFirstPrompt !== prompt
      || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
      return modelFirstUserFailure('first_submit');
    globalThis.__computaModelFirstMarker = expectedFirstUserMarker;
    globalThis.__computaModelFirstSubmitted = true;
  }
  globalThis.__computaModelLastSubmissionCount = ownedUserCount;
  send.click();
  return { submitted: true };
}
const observed = await websiteModelFinalGuard('gemini', input, await providerPageAction(), modelTemporaryVerified);
if (!submissionReadActive()) return { error: 'conversation_changed', detail: 'submission_message' };
if (observed.error === 'first_user_observation_replaced') return observed;
if (observed.error === 'submission_observation_replaced') {
  const record = globalThis.__computaGeminiSubmissionState?.lastVerified, certificate = record?.remount;
  const proof = record && modelExpectedSubmissionProof(record.sequence);
  // This certified discard already checked an exact claimed append edge.
  // Return no observation; the ordinary count guard must not turn it into a
  // different failure before native takes its single fresh full inspection.
  if (certificate?.kind === 'submission' && observed.detail === 'readonly_model_observation'
    && proof?.fingerprint === certificate.fingerprint && certificate.sequence === record.sequence
    && observed.replacementSubmissionProof?.sequence === record.sequence
    && observed.replacementSubmissionProof?.fingerprint === proof.fingerprint) return observed;
}
if (['inspect', 'verifyModel'].includes(input.action) && modelUserRoots().length !== ownedUserCount) {
  const append = websiteModelAcknowledgedUserAppend(input, ownedUserCount, modelUserRoots().length,
    firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity } : null,
    modelTemporaryVerified());
  if (append) return append;
  if (!firstSnapshot) return { error: 'conversation_changed', detail: 'user_count' };
}
if (firstSnapshot) {
  if (!snapshotUnchanged(input.action === 'submit')) return await modelFirstUserReplacementObservation(firstSnapshot)
    || modelFirstUserFailure('snapshot_after_action', input.action === 'submit');
  if (!modelTemporaryVerified()) return { error: 'temporary_mode_unverified' };
  if (observed.error) return observed;
  const firstBound = !globalThis.__computaModelFirstProof;
  if (!globalThis.__computaModelFirstProof) {
    if (observed.temporary !== true) return { error: 'temporary_mode_unverified' };
    globalThis.__computaModelFirstProof = { marker: input.expectedFirstUserMarker, fingerprint: firstUserFingerprint,
      identity: firstUserIdentity };
  }
  // Submit intentionally exposes its acknowledgment only, as in the native contract.
  if (input.action === 'submit') return await modelSubmissionResult(observed);
  return await modelSubmissionResult({ ...observed, firstUserVerified: true, firstUserFingerprint, firstUserMarkerVerified: true,
    ...(firstBound ? { debugStructure: modelFirstUserStructure('first_bound') } : {}) });
}
return await modelSubmissionResult({ ...observed, firstUserVerified: false, firstUserFingerprint: null });
