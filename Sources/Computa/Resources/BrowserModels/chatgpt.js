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
    return { error: code, modelDiagnostic: websiteModelDiagnostic(current, { readStage,
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
    const modelDiagnostic = websiteModelDiagnostic(familyState);
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
  return discovery ? result : { selected: true, modelEvidence: result.modelEvidence };
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

// Optional first-preparation timings are diagnostic only. No timer grants page
// authority, schedules work, or changes an action's return/throw behavior.
const chatGPTPreparationTimingEnabled = input?.preparationTiming === true && input.provider === 'chatgpt'
  && ['prepare', 'insert', 'sendReady', 'submit', 'verifyModel', 'verifyProductMode'].includes(input.action)
  && Array.isArray(input.expectedUserCounts) && input.expectedUserCounts.length === 1 && input.expectedUserCounts[0] === 0;
function chatGPTPreparationNow() {
  if (!chatGPTPreparationTimingEnabled) return null;
  try {
    const value = typeof performance !== 'undefined' ? performance.now() : Date.now();
    return typeof value === 'number' && Number.isFinite(value) ? value : null;
  } catch { return null; }
}
const chatGPTPreparationTiming = { started: chatGPTPreparationNow(), beginSubmissionMs: null,
  beginSubmissionHashMs: null, modelPrecheckMs: null, finalGuardMs: null, editorFocusMs: null, editorMutationMs: null, inputDispatchMs: null,
  editorReadinessMs: null, editorReadyAtEntry: null,
  outerSetupMs: null, guardedSetupMs: null, providerEntryMs: null, providerSetupMs: null,
  insertPreFocusMs: null, insertPostFocusMs: null, providerReturnMs: null,
  guardedFinalizationMs: null, outerFinalizationMs: null };
// Successful fresh inserts partition the formerly unmeasured intervals around
// the existing awaits. These spans do not overlap beginSubmissionMs, model
// precheck/final guard, focus, literal mutation, input dispatch or readiness.
// beginSubmissionHashMs remains a child of beginSubmissionMs. The timestamp
// below is diagnostic only: it cannot grant proof, affect a wait or replay work.
let chatGPTProviderReturnStarted = null;
function chatGPTPreparationElapsed(started) {
  const ended = chatGPTPreparationNow();
  return started !== null && ended !== null && ended >= started && ended - started <= 45_000
    ? Math.round((ended - started) * 1_000) / 1_000 : null;
}
function chatGPTPreparationRecord(key, started) {
  if (chatGPTPreparationTimingEnabled) chatGPTPreparationTiming[key] = chatGPTPreparationElapsed(started);
}
// No supplied callback ever executes a guard; these functions record only clocks.
function chatGPTSyncWorkStart() { try { return globalThis.__computaObservationDiagnosticV1?.syncNow?.() ?? null; } catch { return null; } }
function chatGPTSyncWorkEnd(index, started) { try { globalThis.__computaObservationDiagnosticV1?.recordSync?.(index, started); } catch { } }
// BEGIN COMPUTA MATCHED BENCHMARK PROBE V1 — diagnostic-only, shared verbatim.
function computaInstallMatchedBenchmarkProbe(config) {
  const keys = ['schemaVersion', 'nonce', 'expectedSHA256', 'expectedCanonicalSHA256', 'expectedUTF8Bytes'];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const sha = /^[0-9a-f]{64}$/;
  if (!config || typeof config !== 'object' || Object.keys(config).length !== keys.length
    || !keys.every(key => Object.hasOwn(config, key)) || config.schemaVersion !== 1
    || !uuid.test(config.nonce) || !sha.test(config.expectedSHA256) || !sha.test(config.expectedCanonicalSHA256)
    || !Number.isSafeInteger(config.expectedUTF8Bytes) || config.expectedUTF8Bytes < 1 || config.expectedUTF8Bytes > 180_200
    || window !== window.top || location.origin !== 'https://chatgpt.com') return null;
  const globalKey = '__computaMatchedBenchmarkProbeV1';
  const existing = globalThis[globalKey];
  if (existing) {
    try {
      const snapshot = existing.snapshot();
      return existing.nonce === config.nonce && snapshot.expectedSHA256 === config.expectedSHA256
        && snapshot.expectedCanonicalSHA256 === config.expectedCanonicalSHA256
        && snapshot.expectedUTF8Bytes === config.expectedUTF8Bytes ? existing : null;
    } catch { return null; }
  }
  const originalDocument = document, started = performance.now();
  if (!Number.isFinite(started) || started < 0) return null;
  const canonical = text => text.replace(/\r\n?/g, '\n').normalize('NFC').trim();
  const roots = role => {
    const selector = `[data-message-author-role="${role}"], [data-markdown-text-style="${role}-message"], article[data-turn="${role}"]`
      + (role === 'user' ? ', [data-user-message-bubble]' : '');
    const all = [...document.querySelectorAll(selector)];
    return all.filter(node => !all.some(other => other !== node && other.contains(node)));
  };
  if (location.pathname !== '/' || roots('user').length || roots('assistant').length) return null;
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && getComputedStyle(node).display !== 'none';
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const state = { schemaVersion: 1, nonce: config.nonce, expectedSHA256: config.expectedSHA256,
    expectedCanonicalSHA256: config.expectedCanonicalSHA256, expectedUTF8Bytes: config.expectedUTF8Bytes,
    invalidReason: 'none', sendClickCount: 0, userCount: 0, assistantCount: 0,
    editorUTF8Bytes: null, editorSHA256: null, editorCanonicalSHA256: null,
    editorRenderedUTF8Bytes: null, editorRenderedSHA256: null, editorRepresentation: 'unknown',
    userUTF8Bytes: null, userSHA256: null, responseUTF8Bytes: null, responseSHA256: null,
    editorMatchesExpected: null, userMatchesExpected: null, payloadMatched: false,
    installedUnixMs: Date.now(), sendUnixMs: null, sendSinceInstallMs: null,
    firstTextAfterSendMs: null, firstCompleteAfterSendMs: null, lastTextChangeAfterSendMs: null,
    completionScope: 'none', responseKind: 'none', currentComplete: false };
  let sendAt = null, userRoot = null, answerRoot = null, pinnedUserText = null;
  let lastUserText = null, lastAnswerText = null, userGeneration = 0, answerGeneration = 0;
  let observer = null, stopped = false;
  const elapsed = from => {
    const now = performance.now(), value = now - from;
    return Number.isFinite(value) && value >= 0 && value <= 600_000 ? Math.round(value * 1_000) / 1_000 : null;
  };
  const detach = () => { observer?.disconnect(); document.removeEventListener('click', onClick, true); stopped = true; };
  const invalid = reason => { if (state.invalidReason === 'none') state.invalidReason = reason; state.payloadMatched = false; detach(); };
  const qualify = () => { state.payloadMatched = state.invalidReason === 'none' && state.sendClickCount === 1
    && state.userCount === 1 && state.assistantCount === 1 && state.editorMatchesExpected === true && state.userMatchesExpected === true; };
  const hash = (text, receive) => {
    const bytes = new TextEncoder().encode(text);
    if (bytes.length > 220_000) { invalid('overflow'); return; }
    try {
      Promise.resolve(crypto.subtle.digest('SHA-256', bytes)).then(value => {
        if (state.invalidReason !== 'none') return;
        receive([...new Uint8Array(value)].map(byte => byte.toString(16).padStart(2, '0')).join(''), bytes.length);
        qualify();
      }, () => invalid('hash_failed'));
    } catch { invalid('hash_failed'); }
  };
  const userBody = root => root.querySelector('[data-markdown-text-style="user-message"]')
    || root.querySelector('.whitespace-pre-wrap') || root.querySelector('[data-message-author-role="user"]') || root;
  const answerBody = root => root.getAttribute('data-markdown-text-style') === 'assistant-message' ? root
    : root.querySelector('[data-markdown-text-style="assistant-message"]') || root.querySelector('.markdown')
      || root.querySelector('[data-message-author-role="assistant"]') || root;
  const scopedCopy = (answer, users, assistants) => {
    for (let node = answer, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
      if (['MAIN', 'BODY', 'HTML'].includes(node.tagName) || users.some(user => node === user || node.contains(user))
        || assistants.filter(other => node === other || node.contains(other)).length > 1) break;
      const footerCopies = [...node.querySelectorAll('.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"]')]
        .filter(copy => !answer.contains(copy) && !copy.closest('pre,code'));
      if (footerCopies.some(enabled)) return 'assistant_ancestor';
    }
    // Physical paired-turn fallback mirrors the current footer layout, without
    // borrowing native ownership/proof objects. It is never inference authority.
    const turn = answer.closest('div[data-talvt-turn-state]');
    const outer = turn?.closest('div[data-content-search-turn-key]');
    if (!turn || turn.getAttribute('data-talvt-turn-state') !== 'complete' || !outer || outer === turn
      || !visible(turn) || !visible(outer) || outer.closest('div[data-talvt-turn-state]')
      || outer.parentElement?.closest('div[data-content-search-turn-key]')
      || outer.querySelectorAll('div[data-talvt-turn-state]').length !== 1
      || users.length !== 1 || assistants.length !== 1 || !turn.contains(users[0]) || !turn.contains(assistants[0])
      || !outer.contains(users[0]) || !outer.contains(assistants[0])) return 'none';
    const precedes = (a, b) => a !== b && !a.contains(b) && !b.contains(a) && (a.compareDocumentPosition(b) & 4) !== 0;
    if (!precedes(users[0], assistants[0])) return 'none';
    const content = 'pre,code,blockquote,.markdown,[data-turn],form,input,textarea,select,option,[contenteditable],'
      + '[role="textbox"],[role="menu"],[role="dialog"],[role="listbox"],[data-message-author-role],'
      + '[data-markdown-text-style],[data-user-message-bubble],[data-tool-call-id]';
    const outside = node => node?.closest('div[data-talvt-turn-state]') === turn && !node.closest(content)
      && ![...users, ...assistants].some(root => root.contains(node));
    const copies = [...turn.querySelectorAll('button[aria-label="Copy"]')].filter(outside);
    if (copies.length !== 1 || !enabled(copies[0])) return 'none';
    const companions = ['Rate response', 'Read aloud', 'Regenerate response'].map(name =>
      [...turn.querySelectorAll('button,[role="button"]')].filter(node => node.getAttribute('aria-label') === name && outside(node) && enabled(node)));
    if (companions.some(items => items.length > 1) || companions.filter(items => items.length === 1).length < 2) return 'none';
    for (let row = copies[0].parentElement, depth = 0; row && row !== turn && depth < 6; row = row.parentElement, depth++) {
      if (!companions.flat().every(node => row.contains(node))) continue;
      if (!outside(row) || !visible(row) || !precedes(assistants[0], row) || row.querySelector(content)
        || row.querySelectorAll('*').length > 256) return 'none';
      const pending = [...row.childNodes]; let visited = 0;
      while (pending.length) {
        if (++visited > 256) return 'none';
        const node = pending.pop();
        if (node.nodeType === 3 && (node.textContent || '').trim()) return 'none';
        if (node.nodeType === 1) {
          if (['SCRIPT', 'STYLE', 'TEMPLATE', 'IFRAME'].includes(node.tagName)) return 'none';
          if (node.tagName !== 'BUTTON' && node.getAttribute('role') !== 'button') pending.push(...node.childNodes);
        }
      }
      return 'paired_turn';
    }
    return 'none';
  };
  const sample = () => {
    if (stopped || sendAt === null) return;
    if (document !== originalDocument || location.origin !== 'https://chatgpt.com') { invalid('document_changed'); return; }
    if (elapsed(started) === null) { invalid('expired'); return; }
    state.currentComplete = false;
    const users = roots('user'), assistants = roots('assistant');
    state.userCount = Math.min(2, users.length); state.assistantCount = Math.min(2, assistants.length);
    if (users.length > 1) { invalid('extra_user'); return; }
    if (assistants.length > 1) { invalid('extra_answer'); return; }
    if (userRoot && users.length && users[0] !== userRoot) { invalid('user_root_changed'); return; }
    if (answerRoot && assistants.length && assistants[0] !== answerRoot) { invalid('answer_root_changed'); return; }
    if (users.length === 1) {
      userRoot ||= users[0];
      const text = canonical(userBody(userRoot).innerText || userBody(userRoot).textContent || '');
      if (pinnedUserText !== null && text !== pinnedUserText) { invalid('user_body_changed'); return; }
      if (text && text !== lastUserText) {
        lastUserText = text; const generation = ++userGeneration;
        hash(text, (value, bytes) => {
          if (generation !== userGeneration) return;
          state.userSHA256 = value; state.userUTF8Bytes = bytes;
          state.userMatchesExpected = value === config.expectedCanonicalSHA256;
          if (state.userMatchesExpected) pinnedUserText = text;
        });
      }
    }
    if (assistants.length === 1) {
      answerRoot ||= assistants[0]; const answer = answerBody(answerRoot);
      const codes = [...answer.querySelectorAll('code')];
      const kind = codes.length === 1 ? 'code' : 'rendered';
      const text = canonical(codes.length === 1 ? (codes[0].textContent || '') : (answer.innerText || answer.textContent || ''));
      // A fence language label alone is not a first response token.
      if (text && text.toLowerCase() !== 'json' && visible(answer)) {
        state.firstTextAfterSendMs ??= elapsed(sendAt);
        if (text !== lastAnswerText) {
          lastAnswerText = text; state.lastTextChangeAfterSendMs = elapsed(sendAt); state.responseKind = kind;
          const generation = ++answerGeneration;
          hash(text, (value, bytes) => { if (generation === answerGeneration) { state.responseSHA256 = value; state.responseUTF8Bytes = bytes; } });
        }
        const stop = [...document.querySelectorAll('button[data-testid="stop-button"],button[aria-label="Stop streaming"],button[aria-label="Stop generating"],button[aria-label="Stop"]')].some(visible);
        const scope = scopedCopy(answer, users, assistants);
        if (!stop && scope !== 'none') { state.firstCompleteAfterSendMs ??= elapsed(sendAt); state.completionScope = scope; state.currentComplete = true; }
      } else if (lastAnswerText !== null) {
        // Do not retain a stale hash if the same physical answer empties.
        lastAnswerText = null; answerGeneration += 1;
        state.responseSHA256 = null; state.responseUTF8Bytes = null; state.responseKind = 'none';
        state.lastTextChangeAfterSendMs = elapsed(sendAt);
      }
    } else if (lastAnswerText !== null) {
      lastAnswerText = null; answerGeneration += 1;
      state.responseSHA256 = null; state.responseUTF8Bytes = null; state.responseKind = 'none';
      state.lastTextChangeAfterSendMs = elapsed(sendAt);
    }
    qualify();
  };
  function onClick(event) {
    const target = event.target instanceof Element ? event.target.closest('button[data-testid="send-button"],'
      + 'button[aria-label="Send prompt"],button[aria-label="Send message"],button[aria-label="Send"]') : null;
    if (!target || !enabled(target)) return;
    // A passive probe never suppresses the website click, even if its timing
    // sample is invalidated by pre-Send contamination.
    if (roots('user').length || roots('assistant').length) { invalid('not_fresh'); return; }
    state.sendClickCount = Math.min(2, state.sendClickCount + 1);
    if (state.sendClickCount !== 1) { invalid('multiple_sends'); return; }
    sendAt = performance.now(); state.sendUnixMs = Date.now(); state.sendSinceInstallMs = elapsed(started);
    const editors = [...document.querySelectorAll('#prompt-textarea[contenteditable="true"],textarea#prompt-textarea,#prompt-textarea [contenteditable="true"],[contenteditable="true"][aria-label="Ask ChatGPT"],textarea[data-testid="prompt-textarea"]')]
      .filter(visible).filter((node, i, all) => !all.some(other => other !== node && other.contains(node)));
    if (editors.length !== 1) { invalid('editor_unavailable'); return; }
    const editor = editors[0], rendered = editor instanceof HTMLTextAreaElement ? editor.value : (editor.innerText || editor.textContent || '');
    const renderedBytes = new TextEncoder().encode(rendered).length;
    // ProseMirror can expose one presentation-only terminal LF in innerText.
    // Preserve its raw hash separately. Only the exact remaining whole payload
    // may match; textarea values and all other whitespace remain byte-exact.
    const terminalNewline = !(editor instanceof HTMLTextAreaElement) && rendered.endsWith('\n')
      && renderedBytes === config.expectedUTF8Bytes + 1;
    const text = terminalNewline ? rendered.slice(0, -1) : rendered;
    state.editorRepresentation = terminalNewline ? 'single_terminal_newline' : 'exact';
    hash(rendered, (value, bytes) => { state.editorRenderedSHA256 = value; state.editorRenderedUTF8Bytes = bytes; });
    hash(text, (value, bytes) => {
      state.editorSHA256 = value; state.editorUTF8Bytes = bytes;
      state.editorMatchesExpected = value === config.expectedSHA256 && bytes === config.expectedUTF8Bytes;
      if (!state.editorMatchesExpected) invalid('editor_mismatch');
    });
    hash(canonical(text), value => { state.editorCanonicalSHA256 = value; });
    sample();
  }
  observer = new MutationObserver(sample);
  observer.observe(document.documentElement || document, { subtree: true, childList: true, characterData: true,
    attributes: true, attributeFilter: ['disabled', 'aria-disabled', 'class', 'style', 'hidden', 'data-talvt-turn-state', 'data-message-author-role', 'data-markdown-text-style', 'data-user-message-bubble'] });
  document.addEventListener('click', onClick, true);
  const api = Object.freeze({ nonce: config.nonce,
    snapshot() { if (!stopped && elapsed(started) === null) invalid('expired'); return { ...state }; },
    read() { return JSON.stringify(this.snapshot()); }, stop() { detach(); } });
  Object.defineProperty(globalThis, globalKey, { value: api, configurable: true });
  return api;
}
// END COMPUTA MATCHED BENCHMARK PROBE V1.

function chatGPTMatchedBenchmarkResult(observed) {
  try {
    const binding = input.matchedBenchmarkProbe, probe = globalThis.__computaMatchedBenchmarkProbeV1;
    if (input.action !== 'inspect' || !binding || !probe || probe.nonce !== binding.nonce
      || !observed || typeof observed !== 'object') return observed;
    const snapshot = probe.snapshot();
    if (snapshot.expectedSHA256 !== binding.expectedSHA256 || snapshot.expectedCanonicalSHA256 !== binding.expectedCanonicalSHA256
      || snapshot.expectedUTF8Bytes !== binding.expectedUTF8Bytes) return observed;
    return { ...observed, benchmarkMilestones: snapshot };
  } catch { return observed; }
}

// The separately loaded auxiliary diagnostic never supplies inference proof.
// Its private input is present only for an armed, captured first-Instant run.
function chatGPTObservationDiagnosticResult(observed) {
  try {
    const binding = input.matchedObservationDiagnostic;
    if (!binding || !['inspect', 'failedPageDiagnostic', 'stop'].includes(input.action)
      || !observed || typeof observed !== 'object') return observed;
    const api = globalThis.__computaObservationDiagnosticV1, probe = globalThis.__computaMatchedBenchmarkProbeV1;
    const fields = ['schemaVersion', 'nonce', 'expectedSHA256', 'expectedCanonicalSHA256', 'expectedUTF8Bytes'];
    if (!api || api.revision !== 1 || !probe || !fields.every(name => api.binding?.[name] === binding[name])) return observed;
    const diagnostic = input.stopObservationDiagnostic === true || input.action !== 'inspect' ? api.stop() : api.snapshot();
    const current = probe.snapshot();
    // Read the existing passive binding again even if the auxiliary's finite
    // observation window has ended. No output text, timing or callback authorizes an action.
    if (!fields.every(name => current[name] === binding[name]) || current.invalidReason !== 'none'
      || current.sendClickCount !== 1 || current.userCount !== 1 || current.assistantCount !== 1
      || current.payloadMatched !== true || current.editorMatchesExpected !== true || current.userMatchesExpected !== true
      || current.editorSHA256 !== binding.expectedSHA256 || current.editorCanonicalSHA256 !== binding.expectedCanonicalSHA256
      || current.userSHA256 !== binding.expectedCanonicalSHA256 || current.editorUTF8Bytes !== binding.expectedUTF8Bytes
      || current.userUTF8Bytes !== binding.expectedUTF8Bytes) return observed;
    return { ...observed, observationDiagnostic: diagnostic };
  } catch { return observed; }
}

function chatGPTPreparationResult(observed) {
  observed = chatGPTMatchedBenchmarkResult(observed);
  if (input.matchedObservationDiagnostic != null) observed = chatGPTObservationDiagnosticResult(observed);
  if (!chatGPTPreparationTimingEnabled || !observed || typeof observed !== 'object') return observed;
  try {
    const openingRecoveryUsed = input.action === 'prepare' && globalThis.__computaChatFirstPrepareOpening?.recoveryClaimed === true
      || input.action === 'insert' && globalThis.__computaChatSubmissionState?.pending?.firstInsertOpening?.recoveryClaimed === true;
    const { started, ...timings } = chatGPTPreparationTiming;
    return { ...observed, preparationTiming: { ...timings, totalMs: chatGPTPreparationElapsed(started), openingRecoveryUsed } };
  } catch { return observed; }
}
function websiteChatProvisionalHeaderRecords(pin, pending, records) {
  if (pending.completed || pin.invalidated === true) return;
  const proving = pending.proofLease != null && globalThis.__computaChatActiveInvocation === pending.proofLease;
  const allowed = value => typeof value === 'string' && value.length <= 128
    && ['', pending.power.label, ...(proving ? ['Thinking effort'] : [])].includes(websiteModelNormalize(value));
  const changed = records.length > 512 || websiteChatHeaderMutationMismatch(records, pending.header, pending.power)
    || records.some(record => record.type === 'characterData'
      ? !allowed(record.oldValue) || !allowed(record.target?.textContent)
      : record.type === 'childList' && ([...(record.addedNodes || []), ...(record.removedNodes || [])].length > 128
        || [...(record.addedNodes || []), ...(record.removedNodes || [])].some(node => !allowed(node.textContent || ''))));
  if (changed) websiteChatInvalidatePin(pin, 'header_mutation');
}
function websiteChatDrainProvisionalHeader(pin) {
  const pending = pin?.provisionalHeader;
  if (!pending || pending.completed) return;
  websiteChatProvisionalHeaderRecords(pin, pending, pending.observer.takeRecords?.() || []);
  if (pin.invalidated === true) return;
  const current = websiteChatPickerState();
  const proving = pending.proofLease != null && globalThis.__computaChatActiveInvocation === pending.proofLease;
  if (globalThis.__computaChatPresetPin !== pin || pin.owner !== pending.owner || pin.document !== pending.document
    || globalThis.__computaModelOwner !== pending.owner || document !== pending.document
    || window !== window.top || location.origin !== 'https://chatgpt.com'
    || pin.selection !== pending.selection || pin.selection?.family?.key !== pending.family
    || pin.selection?.power?.key !== pending.power.key || pending.previous.isConnected !== false
    || pin.headerTrigger !== pending.previous && !(proving && pin.headerTrigger === pending.header)
    || current.triggerCount !== 1 || current.trigger !== pending.header || !current.enabled(pending.header)
    || !proving && !current.closedPresentation || current.headerPower && current.headerPower.key !== pending.power.key
    || !current.headerPower && !(proving && current.headerPresentation)
    || current.duplicate || current.conflicting || current.indicatorInvalid || current.selectionAmbiguous || current.navigationAmbiguous
    || current.semanticSlider && current.semanticSlider.getAttribute('aria-valuenow')
      !== String(websiteChatPowers.findIndex(power => power.key === pending.power.key))
    || current.checkedFamily && current.checkedFamily.key !== pending.family) websiteChatInvalidatePin(pin, 'header_replaced');
}
function websiteChatClaimProvisionalHeader(pin, current) {
  const pending = pin.provisionalHeader;
  if (pending) {
    websiteChatDrainProvisionalHeader(pin);
    return !pending.completed && pending.header === current.trigger && pin.invalidated !== true;
  }
  if (!pin.headerTrigger || pin.headerTrigger.isConnected !== false || current.triggerCount !== 1
    || !current.trigger || !current.enabled(current.trigger) || !current.closedPresentation
    || current.headerPower?.key !== pin.selection.power.key || !chatGPTProductModeProof() || !chatGPTTemporaryVerified()) return false;
  const candidate = { owner: pin.owner, document, invocation: websiteChatInvocationLease,
    previous: pin.headerTrigger, header: current.trigger, selection: pin.selection,
    family: pin.selection.family.key, power: { ...pin.selection.power }, completed: false, proofLease: null, observer: null };
  candidate.observer = new MutationObserver(records => websiteChatProvisionalHeaderRecords(pin, candidate, records));
  candidate.observer.observe(candidate.header, { subtree: true, childList: true, characterData: true, characterDataOldValue: true });
  pin.provisionalHeader = candidate;
  websiteChatDrainProvisionalHeader(pin);
  return pin.invalidated !== true;
}
function websiteChatDeferredModelRead(expected, context) {
  if (input.deferModelVerification !== true || globalThis.__computaModelFirstSubmitted !== true
    || !['inspect', 'verifyModel', 'verifyProductMode', 'submit'].includes(input.action)
    || !['action_precheck', 'action_final_guard'].includes(context?.scope)
    || input.action === 'submit' && context.scope === 'action_precheck') return null;
  if (!websiteChatInvocationLease || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease
    || websiteChatInvocationLease.document !== document || window !== window.top
    || location.origin !== 'https://chatgpt.com' || document.URL !== input.expectedURL
      && !(input.action === 'submit' && context?.scope === 'action_final_guard' && context.action === 'submit'
        && chatGPTSubmissionContext(globalThis.__computaChatSubmissionState, true))
    || globalThis.__computaModelOwner !== input.ownerToken) return { error: 'document_changed' };
  const pin = globalThis.__computaChatPresetPin;
  if (!websiteChatPresetIntentValid(expected) || !pin || pin.owner !== input.ownerToken || pin.document !== document
    || !pin.headerTrigger || !websiteChatFamilyValid(pin.selection?.family) || !websiteChatPowerValid(pin.selection?.power))
    return { error: 'model_unverified' };
  websiteChatDrainPinnedMutations(pin);
  const pinnedChoice = websiteChatPresetChoice(pin.selection.family, pin.selection.power);
  if (pin.invalidated === true || !pinnedChoice || expected.key !== pinnedChoice.key
    || expected.label !== pinnedChoice.label && !(pin.selection.power.key === 'pro' && expected.label === 'Pro'))
    return { error: 'model_mismatch' };
  const current = websiteChatPickerState();
  if (current.triggerCount !== 1 || !current.trigger || !current.enabled(current.trigger)
    || !websiteChatClosedHeaderMatches(current, pin.selection.power, pin) || current.duplicate || current.conflicting || current.indicatorInvalid
    || current.selectionAmbiguous || current.navigationAmbiguous) return { error: 'model_unverified' };
  // One replacement may retain negative history while pending. Its observer
  // never transfers the original pin or creates positive model evidence.
  if (current.trigger !== pin.headerTrigger && !websiteChatClaimProvisionalHeader(pin, current))
    return { error: 'model_mismatch' };
  if (current.headerPower && current.headerPower.key !== pin.selection.power.key
    || current.semanticSlider && current.semanticSlider.getAttribute('aria-valuenow')
      !== String(websiteChatPowers.findIndex(power => power.key === pin.selection.power.key))
    || current.checkedFamily && current.checkedFamily.key !== pin.selection.family.key) {
    websiteChatInvalidatePin(pin, 'semantic_mutation');
    return { error: 'model_mismatch' };
  }
  return { modelVerificationPending: true };
}
function chatGPTResponseReadSnapshot() {
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const roots = chatGPTMessageRoots('assistant');
  const nodes = roots.map(node => node.getAttribute('data-markdown-text-style') === 'assistant-message' ? node
    : node.querySelector('[data-markdown-text-style="assistant-message"]') || node.querySelector('.markdown')
      || node.querySelector('[data-message-author-role="assistant"]')
      || (node.getAttribute('data-message-author-role') === 'assistant' ? node : null)).filter(visible);
  const answers = nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
  const answer = answers.at(-1);
  const scope = chatGPTAnswerCopyScope(answer, answers, chatGPTMessageRoots('user'), visible, enabled);
  const footer = scope.footer;
  const copies = footer ? scope.copies.map(node => ({ node, enabled: enabled(node) })) : [];
  return { roots, answers, answer, footer, copies, association: scope.association || null,
    text: modelResponseText(answer, modelResponseExtraction(answer)).slice(0, 220_001),
    busy: [...document.querySelectorAll('button[data-testid="stop-button"], button[aria-label="Stop streaming"], button[aria-label="Stop generating"], button[aria-label="Stop"]')].some(visible),
    users: chatGPTMessageRoots('user').map(root => {
      const body = chatGPTUserBody(root);
      return { root, body, text: normalizedFirstBody(body) };
    }) };
}
function chatGPTResponseSnapshotMatches(captured, observed) {
  const current = chatGPTResponseReadSnapshot();
  const same = (left, right) => left.length === right.length && left.every((value, index) => value === right[index]);
  return observed.busy === false && observed.answerComplete === true && observed.text === captured.text
    && observed.responseCount === captured.answers.length && observed.userCount === captured.users.length
    && captured.busy === false && current.busy === false && !!captured.answer && captured.answer.isConnected
    && !!captured.footer && captured.footer.isConnected && current.answer === captured.answer && current.footer === captured.footer
    && chatGPTCopyAssociationMatches(current.association, captured.association)
    && current.text === captured.text && same(current.roots, captured.roots) && same(current.answers, captured.answers)
    && current.copies.length === captured.copies.length && captured.copies.some(copy => copy.enabled)
    && current.copies.every((copy, index) => copy.node === captured.copies[index].node && copy.enabled === captured.copies[index].enabled)
    && current.users.length === captured.users.length && current.users.every((user, index) => {
      const previous = captured.users[index];
      return user.root === previous.root && user.body === previous.body && user.body?.isConnected && user.text === previous.text;
    });
}
// Native supplies only the candidate it already waited on. Check the current
// exact body, completion footer and Stop state before opening any picker. This
// cannot prove a model or complete a response: a match only permits the normal
// fresh full proof; a mismatch uses this invocation's ordinary deferred read.
function chatGPTQuietCompletionPrecheck(request) {
  if (!Object.prototype.hasOwnProperty.call(request, 'quietCompletionCandidate')) return null;
  const candidate = request.quietCompletionCandidate;
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)
    || Object.keys(candidate).sort().join(',') !== 'responseCount,text,userCount'
    || typeof candidate.text !== 'string' || !candidate.text.length
    || new TextEncoder().encode(candidate.text).length > 220_000
    || !Number.isSafeInteger(candidate.responseCount) || candidate.responseCount < 1 || candidate.responseCount > 10_000
    || !Number.isSafeInteger(candidate.userCount) || candidate.userCount < 1 || candidate.userCount > 16
    || request.provider !== 'chatgpt' || request.action !== 'inspect' || request.deferModelVerification !== false
    || request.expectedModelChoice == null || globalThis.__computaModelFirstSubmitted !== true
    || !Array.isArray(request.expectedUserCounts) || request.expectedUserCounts.length !== 1
    || request.expectedUserCounts[0] !== candidate.userCount || request.submissionSequence !== candidate.userCount
    || typeof request.expectedFirstUserFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(request.expectedFirstUserFingerprint))
    return { error: 'model_unverified' };
  const state = globalThis.__computaChatSubmissionState, record = state?.lastVerified;
  const current = chatGPTResponseReadSnapshot();
  return !!record && state.pending == null && chatGPTSubmissionContext(state)
    && record.phase === 'verified' && record.sequence === candidate.userCount && chatGPTSubmissionPins(record)
    && chatGPTSubmissionBodyIntact(record, current.users.map(user => user.root))
    && current.text === candidate.text && current.answers.length === candidate.responseCount
    && current.users.length === candidate.userCount && current.busy === false
    && !!current.answer && current.answer.isConnected && !!current.footer && current.footer.isConnected
    && current.copies.some(copy => copy.enabled);
}
// The main-world decoder supplies only a terminal candidate. It cannot bypass
// the isolated adapter's current submission, physical answer, footer or model
// proof. In particular the terminal event can precede an empty DIL render.
function chatGPTSingleJSONFence(text) {
  if (typeof text !== 'string' || !text.length || text.length > 220_000
    || new TextEncoder().encode(text).length > 220_000) return null;
  const normalized = text.replace(/\r\n/g, '\n');
  if (normalized.includes('\r') || !normalized.startsWith('```json\n')) return null;
  const end = normalized.endsWith('\n```\n') ? normalized.length - 5
    : normalized.endsWith('\n```') ? normalized.length - 4 : -1;
  if (end < 8) return null;
  const body = normalized.slice(8, end);
  if (!body || body.includes('```') || body.includes('<escape>') || body.includes('</escape>')) return null;
  let value;
  try { value = JSON.parse(body); } catch { return null; }
  return value && !Array.isArray(value) && ['message', 'tool_calls'].includes(value.type) ? body : null;
}

// This is the observed text-only renderer shape, not a DIL/Markdown parser.
// Every text leaf is accounted for; a hidden placeholder must be truly empty.
function chatGPTLiteralDILText(answer, messageID) {
  if (!answer?.isConnected || typeof messageID !== 'string') return null;
  const children = node => [...node.childNodes];
  const only = (node, expected) => {
    const actual = children(node);
    return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
  };
  const attrs = (node, allowed) => [...node.attributes].every(attribute => allowed.includes(attribute.name));
  const physical = node => {
    if (!node?.isConnected || node.nodeType !== 1 || node.getClientRects().length === 0
      || node.closest('[inert], [aria-hidden="true"], [hidden]')) return false;
    const style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility !== 'visible' || !(Number(style.opacity) > 0)) return false;
    for (const pseudo of ['::before', '::after'])
      if (!['none', 'normal', '""', "''"].includes(getComputedStyle(node, pseudo).content)) return false;
    return true;
  };
  for (let node = answer.parentElement, depth = 0; node; node = node.parentElement) {
    if (++depth > 64 || !node.isConnected || node.closest('[inert], [aria-hidden="true"], [hidden]')) return null;
    const style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility !== 'visible' || !(Number(style.opacity) > 0)) return null;
  }
  const sources = [...answer.querySelectorAll('[data-dil-source-message-id]')];
  if (sources.length !== 1) return null;
  const source = sources[0], layout = source.children[0], hidden = layout?.children[0], portal = layout?.children[1];
  const dil = portal?.children[0], paragraph = dil?.children[0];
  if (source.tagName !== 'DIV' || source.getAttribute('data-dil-source-message-id') !== messageID
    || source.getAttribute('data-chatgpt-copy-reference') !== '0' || source.getAttribute('data-markdown-copy') !== 'contents'
    || !attrs(source, ['class', 'data-dil-source-message-id', 'data-chatgpt-copy-reference', 'data-markdown-copy'])
    || !only(answer, [source]) || !layout || layout.tagName !== 'DIV' || !attrs(layout, ['class'])
    || !only(source, [layout]) || !hidden || hidden.tagName !== 'DIV' || hidden.getAttribute('hidden') !== ''
    || !attrs(hidden, ['hidden']) || children(hidden).length !== 0 || hidden.textContent !== ''
    || hidden.getClientRects().length !== 0 || getComputedStyle(hidden).display !== 'none'
    || !portal || portal.tagName !== 'DIV' || !attrs(portal, ['class', 'data-theme', 'style'])
    || !only(layout, [hidden, portal]) || !dil || dil.tagName !== 'DIV' || !only(portal, [dil])
    || dil.getAttribute('data-dil-message-id') !== messageID || dil.getAttribute('data-d-inline-reveal') !== ''
    || dil.getAttribute('data-d-direction') !== 'col' || dil.getAttribute('dir') !== 'auto'
    || !attrs(dil, ['class', 'dir', 'data-d-inline-reveal', 'data-d-direction', 'data-dil-message-id'])
    || !paragraph || paragraph.tagName !== 'P' || !only(dil, [paragraph])
    || paragraph.getAttribute('data-d-text-flow') !== '' || paragraph.getAttribute('data-d-component') !== 'text'
    || !attrs(paragraph, ['class', 'data-d-text-flow', 'data-d-component'])) return null;
  const pair = (node, prefixes) => prefixes.every(prefix => [...node.classList]
    .some(name => name.startsWith(prefix) && /^[A-Za-z0-9_-]{1,64}$/.test(name.slice(prefix.length))));
  if (!pair(portal, ['PortalBoundary-', 'Renderer-']) || !pair(dil, ['DilRenderer-', 'DilResponseRoot-'])) return null;
  const spans = children(paragraph);
  if (!spans.length || spans.length > 128 || ![answer, source, layout, portal, dil, paragraph].every(physical)) return null;
  let text = '', displayed = '';
  for (const span of spans) {
    if (span.nodeType !== 1 || span.tagName !== 'SPAN' || !physical(span)
      || span.getAttribute('data-d-text-flow') !== 'word' || span.getAttribute('data-d-stream-word') !== ''
      || !attrs(span, ['data-d-text-flow', 'data-d-stream-word']) || span.childElementCount !== 0
      || children(span).some(node => node.nodeType !== 3) || !span.textContent.length) return null;
    text += span.textContent;
    // Only the terminal line break of each observed word span is a presentation
    // separator. Internal whitespace, JSON escapes and string bytes stay exact.
    displayed += span.textContent.replace(/\r?\n$/, ' ');
    if (text.length > 220_000) return null;
  }
  if (displayed.endsWith(' ')) displayed = displayed.slice(0, -1);
  if (text !== answer.textContent || text !== source.textContent || text !== paragraph.textContent) return null;
  return { text, displayed };
}

function chatGPTTerminalResponseTextRelation(source, answer, extraction, messageID) {
  if (typeof source !== 'string' || source.length > 220_000 || new TextEncoder().encode(source).length > 220_000
    || typeof extraction?.text !== 'string') return null;
  if (source === extraction.text) return 'exact';
  const fence = chatGPTSingleJSONFence(source);
  if (fence !== null && extraction.flags?.selectedExtraction === 'raw_code'
    && extraction.flags?.extractionReason === 'accepted_literal_code') {
    const code = extraction.text.replace(/\r\n/g, '\n');
    if (!code.includes('\r') && (code === fence || code === fence + '\n')) return 'json_code_fence';
  }
  if (extraction.flags?.selectedExtraction !== 'rendered_fallback' || extraction.code || extraction.blocks?.length) return null;
  const literal = chatGPTLiteralDILText(answer, messageID);
  if (!literal || chatGPTSingleJSONFence(literal.text) === null || extraction.text !== literal.displayed) return null;
  if (source === literal.text) return 'dil_literal_json_fence';
  // One exact wrapper was observed on this exact physical text-only renderer.
  // No general provider escape semantics or source rewriting is inferred.
  return source === '<escape>' + literal.text + '</escape>' ? 'dil_escaped_literal_json_fence' : null;
}

function chatGPTTerminalCompletionMatches(observed) {
  const candidate = input.terminalCompletionCandidate;
  const finish = reason => {
    // Content-free rejection facts only. They never supply a match bit or
    // alter a busy/error/preparation read, and are recomputed for this read.
    try {
      if (input.action === 'inspect' && !observed.error && observed.busy === false && observed.answerComplete === true) {
        const path = location.pathname;
        const routeKind = path === '/' ? 'root'
          : /^\/c\/local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+\/?$/.test(path) ? 'local'
            : /^\/c\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\/?$/.test(path) ? 'server' : 'other';
        observed.terminalCompletionDiagnostic = { reason, routeKind };
      }
    } catch { /* Diagnostics cannot change completion admission. */ }
    return reason === 'matched';
  };
  const keys = ['correlationID', 'sequence', 'inputSHA256', 'inputMessageID', 'conversationID', 'messageID', 'text'];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  if (candidate == null) return finish('absent_candidate');
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)
    || Object.keys(candidate).length !== keys.length || !keys.every(key => Object.hasOwn(candidate, key))
    || !['correlationID', 'inputMessageID', 'conversationID', 'messageID'].every(key => typeof candidate[key] === 'string' && uuid.test(candidate[key]))
    || typeof candidate.inputSHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(candidate.inputSHA256)
    || !Number.isSafeInteger(candidate.sequence) || candidate.sequence < 1 || candidate.sequence > 16
    || typeof candidate.text !== 'string' || candidate.text.length === 0 || new TextEncoder().encode(candidate.text).length > 220_000
    || input.provider !== 'chatgpt' || input.action !== 'inspect' || input.submissionSequence !== candidate.sequence
    || !Array.isArray(input.expectedUserCounts) || ![1, 2].includes(input.expectedUserCounts.length)
    || !input.expectedUserCounts.includes(candidate.sequence)
    || !input.expectedUserCounts.every(count => count === candidate.sequence || count === candidate.sequence - 1)
    || window !== window.top || location.origin !== 'https://chatgpt.com' || document.URL !== input.expectedURL) return finish('context_invalid');
  if (location.pathname !== '/c/' + candidate.conversationID) return finish('route_mismatch');
  if (globalThis.__computaModelOwner !== input.ownerToken) return finish('context_invalid');
  if (observed.error || observed.busy !== false || observed.answerComplete !== true
    || observed.userCount !== candidate.sequence) return finish('current_body_invalid');
  const state = globalThis.__computaChatSubmissionState, record = state?.lastVerified;
  if (!record || state.pending != null || !chatGPTSubmissionContext(state)
    || record.phase !== 'verified' || record.sequence !== candidate.sequence || !chatGPTSubmissionPins(record)) return finish('context_invalid');
  const current = chatGPTResponseReadSnapshot();
  if (current.busy !== false || !current.answer?.isConnected || !current.footer?.isConnected
    || current.text !== observed.text || current.answers.length !== observed.responseCount
    || current.users.length !== candidate.sequence || !current.copies.some(copy => copy.enabled)
    || !chatGPTSubmissionBodyIntact(record, current.users.map(user => user.root))) return finish('current_body_invalid');
  const relation = chatGPTTerminalResponseTextRelation(candidate.text, current.answer,
    modelResponseExtraction(current.answer), candidate.messageID);
  if (!relation) return finish('text_relation');
  // This attribute was observed on the final assistant's containing element,
  // after the decoded terminal event. Never borrow an ID from another turn.
  let scope = current.answer;
  for (let depth = 0; scope && depth < 5; depth++, scope = scope.parentElement) {
    if (scope.getAttribute('data-chatgpt-selection-message-id') !== null) {
      const matches = scope.isConnected && scope.getAttribute('data-chatgpt-selection-message-id') === candidate.messageID
        && current.answers.filter(answer => answer === scope || scope.contains(answer)).length === 1
        && !current.users.some(user => user.root === scope || scope.contains(user.root));
      if (matches) observed.terminalCompletionRepresentation = relation;
      return finish(matches ? 'matched' : 'assistant_id');
    }
  }
  return finish('assistant_id');
}
function chatGPTFinalizeResponseRead(observed) {
  delete observed.terminalCompletionDiagnostic;
  if (observed.error) return observed;
  const terminalChecked = () => {
    // Never retain a positive bit from an earlier read or across an await.
    delete observed.terminalCompletionMatched;
    delete observed.terminalCompletionRepresentation;
    delete observed.terminalCompletionDiagnostic;
    if (chatGPTTerminalCompletionMatches(observed)) observed.terminalCompletionMatched = true;
    return observed;
  };
  if (!chatGPTFinalResponseSnapshot) return terminalChecked();
  if (!websiteChatInvocationLease || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease
    || websiteChatInvocationLease.document !== document || window !== window.top
    || location.origin !== 'https://chatgpt.com' || document.URL !== input.expectedURL
    || globalThis.__computaModelOwner !== input.ownerToken) return { error: 'document_changed' };
  const pin = globalThis.__computaChatPresetPin;
  websiteChatDrainPinnedMutations(pin);
  const picker = websiteChatPickerState();
  const proof = chatGPTFinalResponseSnapshot;
  if (!pin || pin !== proof.pin || pin.headerTrigger !== proof.header || pin.selection !== proof.selection
    || pin.owner !== input.ownerToken || pin.document !== document || pin.invalidated === true
    || pin.selection?.family?.key !== proof.family || pin.selection?.power?.key !== proof.power
    || picker.trigger !== proof.header || !websiteChatClosedHeaderMatches(picker, pin.selection.power, pin)
    || !websiteModelChoiceEqual(input.expectedModelChoice, proof.expected))
    return { error: 'model_mismatch' };
  if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
  if (!chatGPTTemporaryVerified()) return { error: 'temporary_mode_unverified' };
  const first = globalThis.__computaModelFirstProof;
  if (proof.users.length > 0 && (!first || first.marker !== input.expectedFirstUserMarker
    || first.fingerprint !== proof.fingerprint || observed.firstUserFingerprint !== proof.fingerprint
    || input.expectedFirstUserFingerprint != null && input.expectedFirstUserFingerprint !== proof.fingerprint))
    return { error: 'conversation_changed', detail: 'first_user_message' };
  return chatGPTResponseSnapshotMatches(chatGPTFinalResponseSnapshot, observed)
    ? terminalChecked() : { error: 'conversation_changed', detail: 'response_changed' };
}
// ChatGPT alone can defer in-flight reads. Keep the shared full-proof control
// layer byte-identical; every nondeferred read still executes that original path.
const websiteChatFullDrainPinnedMutations = websiteChatDrainPinnedMutations;
websiteChatDrainPinnedMutations = function(pin) {
  websiteChatFullDrainPinnedMutations(pin);
  websiteChatDrainProvisionalHeader(pin);
};
// Controlled first-Instant ordering: wait for the current exact editor and
// enabled Send without inferring why either is still unavailable. This performs
// no action and cannot replace the unchanged full picker proof that follows.
let chatGPTFirstInsertFinalDeadline = null;
function chatGPTAwaitFirstInsertEditor(request, observed) {
  if (observed.error || observed.inserted !== true || request.action !== 'insert'
    || request.expectedModelChoice?.key !== 'chat/latest/instant' || request.submissionSequence !== 1
    || request.submissionMarker !== request.expectedFirstUserMarker
    || !Array.isArray(request.expectedSubmissionProofs) || request.expectedSubmissionProofs.length !== 0
    || request.expectedFirstUserFingerprint != null || request.expectedConversation != null) return null;
  const state = globalThis.__computaChatSubmissionState, record = state?.pending;
  const pin = globalThis.__computaChatPresetPin, attempt = globalThis.__computaModelSelection;
  if (!record || !pin || !attempt?.completed) return null;
  const started = chatGPTPreparationNow();
  const until = Date.now() + 1_800, originalDocument = document, originalURL = document.URL;
  const invocation = websiteChatInvocationLease, selection = pin.selection;
  const canonical = record.canonical, fingerprint = record.fingerprint, familyKey = selection?.family?.key;
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const composers = () => [...new Set(document.querySelectorAll('#prompt-textarea[contenteditable="true"], textarea#prompt-textarea, '
    + '#prompt-textarea [contenteditable="true"], [contenteditable="true"][aria-label="Ask ChatGPT"], textarea[data-testid="prompt-textarea"]'))].filter(visible);
  const sends = () => [...new Set(document.querySelectorAll('button[data-testid="send-button"], button[aria-label="Send prompt"], '
    + 'button[aria-label="Send message"], button[aria-label="Send"]'))].filter(visible);
  const composerCandidates = composers(), sendCandidates = sends();
  // This is a read-only ordering hint, not control dispatch or body binding.
  // Zero controls may be a pending mount; no positive proof uses that state.
  if (composerCandidates.length > 1 || sendCandidates.length > 1) return { error: 'composer_unavailable' };
  let send = sendCandidates[0] || null, editorReady = false;
  const failure = () => {
    if (window !== window.top || document !== originalDocument || document.URL !== originalURL
      || document.URL !== request.expectedURL || location.origin !== 'https://chatgpt.com'
      || !invocation || websiteChatInvocationLease !== invocation || globalThis.__computaChatActiveInvocation !== invocation
      || globalThis.__computaModelOwner !== request.ownerToken) return { error: 'document_changed' };
    if (globalThis.__computaChatSubmissionState !== state || state.pending !== record || state.lastVerified != null
      || state.revoked || state.document !== document || state.owner !== request.ownerToken
      || state.firstMarker !== request.expectedFirstUserMarker || !websiteModelChoiceEqual(state.modelChoice, request.expectedModelChoice)
      || record.document !== document || record.owner !== request.ownerToken
      || record.sequence !== 1 || record.marker !== request.submissionMarker || record.phase !== 'prepared'
      || record.root !== null || record.body !== null || record.expansionAttempted
      || record.canonical !== canonical || canonical !== chatGPTSubmissionCanonical(request.prompt)
      || record.fingerprint !== fingerprint || typeof fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(fingerprint)
      || globalThis.__computaModelFirstPrompt !== request.prompt || globalThis.__computaModelFirstSubmitted === true
      || globalThis.__computaModelFirstProof || chatGPTMessageRoots('user').length || chatGPTMessageRoots('assistant').length)
      return chatGPTSubmissionFailure(state, 'begin_admission', record);
    websiteChatDrainPinnedMutations(pin);
    if (globalThis.__computaChatPresetPin !== pin || globalThis.__computaModelSelection !== attempt
      || attempt.completed !== true || pin.invalidated === true || pin.owner !== request.ownerToken || pin.document !== document
      || pin.selection !== selection || selection?.family?.key !== familyKey || selection?.power?.key !== 'instant'
      || !websiteModelChoiceEqual(request.expectedModelChoice, websiteChatPresetChoice(selection.family, selection.power)))
      return { error: 'model_mismatch' };
    const picker = websiteChatPickerState();
    if (picker.trigger !== pin.headerTrigger || !websiteChatClosedHeaderMatches(picker, pin.selection.power, pin)
      || picker.duplicate || picker.conflicting || picker.indicatorInvalid || picker.selectionAmbiguous || picker.navigationAmbiguous)
      return { error: 'model_unverified' };
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    if (!chatGPTTemporaryVerified()) return { error: 'temporary_mode_unverified' };
    const currentComposers = composers(), currentSends = sends();
    if (currentComposers.length > 1 || currentSends.length > 1
      || [...document.querySelectorAll('button[data-testid="stop-button"], button[aria-label="Stop streaming"], '
        + 'button[aria-label="Stop generating"], button[aria-label="Stop"]')].some(visible)) return { error: 'composer_unavailable' };
    send = currentSends[0] || null;
    editorReady = false;
    const composer = currentComposers[0];
    if (!composer) return null;
    if (!enabled(composer)) return { error: 'composer_unavailable' };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (typeof value !== 'string' || value.replace(/\r\n/g, '\n').trim() !== request.prompt.trim()
      || chatGPTSubmissionCanonical(value) !== record.canonical) return { error: 'prompt_not_inserted' };
    editorReady = true;
    return null;
  };
  let rejected = failure();
  if (rejected) return rejected;
  const readyAtEntry = editorReady && enabled(send);
  if (chatGPTPreparationTimingEnabled) chatGPTPreparationTiming.editorReadyAtEntry = readyAtEntry;
  if (readyAtEntry) {
    if (Date.now() >= until) return { error: 'send_unavailable' };
    chatGPTFirstInsertFinalDeadline = until;
    chatGPTPreparationRecord('editorReadinessMs', started);
    return null;
  }
  return (async () => {
    let clockFailed = false;
    try {
      const changed = await websiteModelWaitForChange(until, () => {
        rejected = failure(); return !!rejected || editorReady && enabled(send);
      }, 'model_wait', () => { clockFailed = true; }, true);
      if (rejected) return rejected;
      if (clockFailed || !changed || Date.now() >= until) return { error: 'send_unavailable' };
      rejected = failure();
      if (rejected) return rejected;
      if (Date.now() >= until || !editorReady || !enabled(send)) return { error: 'send_unavailable' };
      chatGPTFirstInsertFinalDeadline = until;
      return null;
    } finally { chatGPTPreparationRecord('editorReadinessMs', started); }
  })();
}
const websiteModelFullReadEvidence = websiteModelReadEvidence;
websiteModelReadEvidence = async function(provider, expected, openingRecovery = null, context = null) {
  if (provider === 'chatgpt') {
    const deferred = websiteChatDeferredModelRead(expected, context);
    if (deferred) return deferred;
  }
  const pin = provider === 'chatgpt' ? globalThis.__computaChatPresetPin : null;
  const pending = pin?.provisionalHeader;
  if (pending && !pending.completed) {
    websiteChatDrainPinnedMutations(pin);
    if (pin.invalidated === true) return { error: 'model_mismatch' };
    pending.proofLease = websiteChatInvocationLease;
  }
  const precheckStarted = context?.scope === 'action_precheck' ? chatGPTPreparationNow() : null;
  const cappedContext = provider === 'chatgpt' && input.action === 'insert' && context?.scope === 'action_final_guard'
    && context.action === 'insert' && chatGPTFirstInsertFinalDeadline !== null
    ? { ...context, firstInsertDeadline: chatGPTFirstInsertFinalDeadline } : context;
  try {
    const result = await websiteModelFullReadEvidence(provider, expected, openingRecovery, cappedContext);
    if (pending && !pending.completed) {
      websiteChatDrainPinnedMutations(pin);
      if (pin.invalidated === true) return { error: 'model_mismatch' };
      if (!result.error && result.modelEvidence && globalThis.__computaChatPresetPin === pin
        && pin.headerTrigger === pending.header) {
        pending.completed = true;
        pending.observer.disconnect?.();
      }
    }
    return result;
  } finally {
    if (pending) pending.proofLease = null;
    if (context?.scope === 'action_precheck') chatGPTPreparationRecord('modelPrecheckMs', precheckStarted);
  }
};
const websiteModelFullFinalGuard = websiteModelFinalGuard;
websiteModelFinalGuard = async function(provider, request, observed, currentTemporary = null) {
  const candidate = provider === 'chatgpt' && !observed.error && request.action === 'inspect'
    && request.expectedModelChoice != null && request.deferModelVerification !== true
    && observed.answerComplete && observed.busy === false && observed.responseCount > 0
    ? chatGPTResponseReadSnapshot() : null;
  if (candidate && !chatGPTResponseSnapshotMatches(candidate, observed))
    return { error: 'conversation_changed', detail: 'response_changed' };
  const editorWait = provider === 'chatgpt' ? chatGPTAwaitFirstInsertEditor(request, observed) : null;
  const editorFailure = editorWait instanceof Promise ? await editorWait : editorWait;
  if (editorFailure) return editorFailure;
  const finalGuardStarted = chatGPTPreparationNow();
  let result;
  try { result = await websiteModelFullFinalGuard(provider, request, observed, currentTemporary); }
  finally { chatGPTPreparationRecord('finalGuardMs', finalGuardStarted); }
  if (result.error) return result;
  if (result.modelVerificationPending === true) {
    delete result.modelEvidence;
    return result;
  }
  if (candidate) {
    if (!chatGPTResponseSnapshotMatches(candidate, result))
      return { error: 'conversation_changed', detail: 'response_changed' };
    const pin = globalThis.__computaChatPresetPin;
    chatGPTFinalResponseSnapshot = { ...candidate, pin, header: pin?.headerTrigger,
      selection: pin?.selection, family: pin?.selection?.family?.key, power: pin?.selection?.power?.key,
      expected: result.modelEvidence?.selected, fingerprint: firstUserFingerprint };
  }
  return result;
};

// A fenced envelope keeps JSON escapes out of the website's Markdown parser.
// Admit only one literal code body with no author prose elsewhere in this answer.
function modelResponseExtraction(answer) {
  const flags = { literalCodeValidJSON: null, literalCodeKnownEnvelopeType: null,
    selectedExtraction: 'rendered_fallback', extractionReason: 'absent_answer' };
  let blocks = [], code = null;
  // A verified literal code body needs no rendered-text traversal. Read the
  // rendered fallback only after its unchanged structural checks decline.
  const fallback = reason => ({ text: answer ? (answer.innerText || answer.textContent || '').trim() : '',
    blocks, code, flags: { ...flags, extractionReason: reason } });
  if (!answer) return fallback('absent_answer');
  blocks = [...answer.querySelectorAll('pre')];
  const codes = [...answer.querySelectorAll('code')];
  if (codes.length === 1) code = codes[0];
  if (blocks.length > 1) return fallback('multiple_pre');
  if (codes.length !== 1) return fallback(codes.length ? 'multiple_code' : 'missing_code');
  const raw = code.textContent || '';
  if (blocks.length === 1 && !blocks[0].contains(code)) return fallback('outside_content');
  const noPre = blocks.length === 0;
  // Current ChatGPT also renders short code bodies in this exact DIV/CODE
  // structure. A generic CODE element without PRE is never admitted.
  const divCode = noPre && code.closest('code.block.text-size-code') === code
    && code.parentElement?.closest('div.text-size-chat.overflow-auto.outline-none.px-4.pt-0.pb-3') === code.parentElement;
  if (noPre && !divCode) return fallback('missing_pre');
  if (raw.length > 220_000) return fallback('oversized_code');
  let envelope;
  try { envelope = JSON.parse(raw); flags.literalCodeValidJSON = true; }
  catch { flags.literalCodeValidJSON = false; return fallback('invalid_json'); }
  const knownType = envelope && !Array.isArray(envelope) && ['message', 'tool_calls'].includes(envelope.type);
  flags.literalCodeKnownEnvelopeType = knownType ? envelope.type : 'unknown';
  if (!knownType) return fallback('unknown_envelope_type');
  // The observed PRE widget retained this structural core while its generated
  // classes and border/header-height styling changed. Bind its actual preceding
  // header to this sole code body; a footer or authored caption is insufficient.
  // The separately observed PRE-free widget keeps its original exact proof.
  const wrapper = (noPre ? code : blocks[0]).closest(noPre
    ? 'div.relative.w-full.min-w-0.overflow-clip.contain-inline-size.border'
    : 'div.relative.w-full.min-w-0.overflow-clip.contain-inline-size');
  const chrome = new Set();
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  if (wrapper && wrapper !== answer && answer.contains(wrapper)
    && wrapper.querySelectorAll('pre').length === blocks.length && wrapper.querySelectorAll('code').length === 1) {
    let codeBranch = noPre ? null : blocks[0];
    for (let depth = 0; codeBranch && codeBranch.parentElement !== wrapper && depth < 4; depth++)
      codeBranch = codeBranch.parentElement;
    const branches = [...wrapper.children];
    const codeIndex = codeBranch?.parentElement === wrapper ? branches.indexOf(codeBranch) : -1;
    const headers = [...wrapper.querySelectorAll(noPre
      ? 'div.flex.items-center.font-sans.text-sm.select-none.min-h-12'
      : 'div.flex.items-center.font-sans.text-sm.select-none')]
      .filter(node => visible(node) && !node.closest('pre') && (noPre
        || node.parentElement === wrapper && !node.querySelectorAll('pre, code').length
          && codeIndex >= 0 && branches.indexOf(node) >= 0 && branches.indexOf(node) < codeIndex));
    if (headers.length === 1) {
      const labels = [...headers[0].querySelectorAll('div.min-w-0.flex-1.truncate')].filter(node =>
        visible(node) && node.childElementCount === 0 && (node.textContent || '').trim() === 'JSON'
        && (noPre || node.parentElement === headers[0]));
      const copyNodes = [...headers[0].querySelectorAll(noPre
        ? 'button[aria-label="Copy"]' : 'button[aria-label="Copy"], button[aria-label="Copy code"]')].filter(visible);
      const copies = copyNodes.filter(node => !node.disabled && node.getAttribute('aria-disabled') !== 'true'
        && !(node.textContent || '').trim());
      if (labels.length === 1 && copies.length === 1 && (noPre || copyNodes.length === 1)) {
        chrome.add(labels[0]); chrome.add(copies[0]);
      }
    }
  }
  if (noPre && chrome.size !== 2) return fallback('outside_content');
  let visited = 0, scanLimit = false;
  const onlyCodeAndWhitespace = node => {
    if (++visited > 10_000) { scanLimit = true; return false; }
    if (node === code || chrome.has(node)) return true;
    if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
    if (node.nodeType !== 1) return true;
    // Actual controls inside this pre are code-block chrome, never surrounding prose.
    if (node.tagName.toLowerCase() === 'button' && blocks.length === 1 && blocks[0].contains(node)) return true;
    return [...node.childNodes].every(onlyCodeAndWhitespace);
  };
  if (!onlyCodeAndWhitespace(answer)) return fallback(scanLimit ? 'outside_scan_limit' : 'outside_content');
  return { text: raw, blocks, code, flags: { ...flags, selectedExtraction: 'raw_code', extractionReason: 'accepted_literal_code' } };
}

function modelResponseText(answer, extraction = modelResponseExtraction(answer)) {
  return extraction.text;
}

// Diagnostic counts describe only this scoped answer; no response bytes leave this function.
function modelResponseStructure(answer, extraction = modelResponseExtraction(answer)) {
  const { blocks, code } = extraction;
  const allCodes = answer ? [...answer.querySelectorAll('code')] : [];
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
    codeTextLength: Math.min((code?.textContent || '').length, 220_001), outsideTextLength, outsideTruncated, preParentTags, outsideNodes,
    ...extraction.flags };
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

// Fixed ChatGPT DOM adapter for the app-owned embedded browser.
// Runs in a private WebKit content world; input arrives as structured arguments.
function chatGPTMessageRoots(role) {
  const selector = `[data-message-author-role="${role}"], [data-markdown-text-style="${role}-message"], article[data-turn="${role}"]`
    + (role === 'user' ? ', [data-user-message-bubble]' : '');
  const nodes = [...document.querySelectorAll(selector)];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
// The generic footer search stays within assistant-only ancestors. The named
// paired-turn layout below needs a separately verified current submission and
// a content-free assistant action row; its state alone never proves completion.
function chatGPTPairedTurnCopyScope(answer, answers, users, visible, enabled) {
  if (!answer || answers.at(-1) !== answer || users.length > 64 || answers.length > 64) return null;
  if (!websiteChatInvocationLease || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease
    || websiteChatInvocationLease.document !== document || window !== window.top
    || input.provider !== 'chatgpt' || location.origin !== 'https://chatgpt.com') return null;
  const state = globalThis.__computaChatSubmissionState, record = state?.lastVerified;
  if (!state || state.revoked || state.pending != null || state.document !== document
    || state.owner !== input.ownerToken || globalThis.__computaModelOwner !== state.owner
    || !record || record.phase !== 'verified' || !Number.isInteger(record.sequence)
    || record.sequence !== users.length || record.document !== document || record.owner !== state.owner
    || record.sequence !== input.submissionSequence || record.marker !== input.submissionMarker
    || document.URL !== input.expectedURL
    || !chatGPTSubmissionPins(record) || !chatGPTSubmissionBodyIntact(record, users)) return null;
  const turn = answer.closest('div[data-talvt-turn-state]');
  if (!turn || turn.getAttribute('data-talvt-turn-state') !== 'complete' || !visible(turn)) return null;
  const outer = turn.closest('div[data-content-search-turn-key]');
  const turnKey = outer?.getAttribute('data-content-search-turn-key');
  if (!outer || outer === turn || !visible(outer) || typeof turnKey !== 'string'
    || !turnKey.length || turnKey.length > 256 || /[\x00-\x20\x7f]/.test(turnKey)
    || outer.closest('div[data-talvt-turn-state]')
    || outer.parentElement?.closest('div[data-content-search-turn-key]')) return null;
  const namedTurns = [...outer.querySelectorAll('div[data-talvt-turn-state]')];
  if (namedTurns.length !== 1 || namedTurns[0] !== turn) return null;
  const physicalAssistants = chatGPTMessageRoots('assistant');
  if (physicalAssistants.length > 64) return null;
  const pairUsers = users.filter(node => turn.contains(node));
  const pairAssistants = physicalAssistants.filter(node => turn.contains(node));
  if (pairUsers.length !== 1 || pairAssistants.length !== 1) return null;
  const user = pairUsers[0], assistant = pairAssistants[0];
  if (user !== record.root || user !== users.at(-1) || assistant !== physicalAssistants.at(-1)
    || users.filter(node => outer.contains(node)).length !== 1
    || physicalAssistants.filter(node => outer.contains(node)).length !== 1
    || answers.filter(node => outer.contains(node)).length !== 1
    || !(assistant === answer || assistant.contains(answer)) || !visible(user) || !visible(assistant)
    || [...users, ...physicalAssistants].some(node => node === turn || node.contains(turn))) return null;
  const precedes = (left, right) => left !== right && !left.contains(right) && !right.contains(left)
    && typeof left.compareDocumentPosition === 'function' && (left.compareDocumentPosition(right) & 4) !== 0;
  if (!precedes(user, assistant)) return null;
  const content = 'pre, code, blockquote, .markdown, [data-turn], form, input, textarea, select, option, '
    + '[contenteditable], [role="textbox"], [role="menu"], [role="dialog"], [role="listbox"], [data-chatgpt-selection-message-id], '
    + '[data-message-author-role], [data-markdown-text-style], [data-user-message-bubble], article[data-turn], '
    + '[data-testid="tool-message"], [data-testid="tool-response"], [data-tool-call-id]';
  const outsideContent = node => node && node.closest('div[data-talvt-turn-state]') === turn
    && !node.closest(content) && ![...users, ...physicalAssistants].some(root => root.contains(node));
  const allCopies = [...turn.querySelectorAll('button[aria-label="Copy"]')];
  if (allCopies.length > 64) return null;
  const copies = allCopies.filter(outsideContent);
  if (copies.length !== 1 || !enabled(copies[0])) return null;
  const copy = copies[0], names = ['Rate response', 'Read aloud', 'Regenerate response'];
  const buttons = [...turn.querySelectorAll('button, [role="button"]')];
  if (buttons.length > 128) return null;
  const companions = [];
  for (const name of names) {
    const matches = buttons.filter(node => node.getAttribute('aria-label') === name && outsideContent(node));
    if (matches.length > 1) return null;
    if (matches.length === 1 && enabled(matches[0])) companions.push(matches[0]);
  }
  if (companions.length < 2) return null;
  const contentFree = row => {
    const pending = [...row.childNodes];
    let visited = 0;
    while (pending.length) {
      if (++visited > 256) return false;
      const node = pending.pop();
      if (node.nodeType === 3) { if ((node.textContent || '').trim()) return false; }
      else if (node.nodeType === 1) {
        if (['SCRIPT', 'STYLE', 'TEMPLATE', 'IFRAME'].includes(node.tagName)) return false;
        if (node.tagName !== 'BUTTON' && node.getAttribute('role') !== 'button') pending.push(...node.childNodes);
      }
    }
    return true;
  };
  // A footer is a content-free, bounded common ancestor, never the paired turn
  // or its outer conversation wrapper. Copy remains the completion signal.
  for (let row = copy.parentElement, depth = 0; row && row !== turn && depth < 6; row = row.parentElement, depth++) {
    if (!companions.every(node => row.contains(node))) continue;
    if (!outsideContent(row) || !visible(row) || !precedes(assistant, row)
      || row.querySelector(content) || row.querySelectorAll('*').length > 256
      || [...users, ...physicalAssistants].some(node => row.contains(node)) || !contentFree(row)) return null;
    return { copies: [copy], enabledCopies: [copy], depth, footer: row,
      association: { turn, outer, turnKey, user, assistant, record, row, companions } };
  }
  return null;
}

function chatGPTCopyAssociationMatches(left, right) {
  if (left == null || right == null) return left == null && right == null;
  return ['turn', 'outer', 'turnKey', 'user', 'assistant', 'record', 'row'].every(key => left[key] === right[key])
    && left.companions.length === right.companions.length
    && left.companions.every((node, index) => node === right.companions[index]);
}

function chatGPTAnswerCopyScope(answer, answers, users, visible, enabled) {
  let copies = [], enabledCopies = [], depth = -1, footer = null;
  for (let node = answer, currentDepth = 0; node && currentDepth < 10; node = node.parentElement, currentDepth++) {
    if (['MAIN', 'BODY', 'HTML'].includes(node.tagName)
      || users.some(user => node === user || node.contains(user))
      || answers.filter(other => node === other || node.contains(other)).length > 1) break;
    copies = [...node.querySelectorAll('.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"], button[aria-label="Copy"]')].filter(visible);
    enabledCopies = copies.filter(enabled); depth = currentDepth;
    if (enabledCopies.length) { footer = node; break; }
  }
  return (footer ? null : chatGPTPairedTurnCopyScope(answer, answers, users, visible, enabled))
    || { copies, enabledCopies, depth, footer };
}
// Counts from the selected body and its physical assistant root distinguish an
// empty selection wrapper from an empty turn. No response text or identifiers
// enter this diagnostic, and it never changes extraction or completion.
function chatGPTAnswerScopeDiagnostic(answer) {
  const root = answer && chatGPTMessageRoots('assistant').find(node => node === answer || node.contains(answer));
  return { kind: 'chatgpt_answer_scope_v1', rootPresent: !!root, bodyPresent: !!answer,
    rootTextLength: Math.min((root?.textContent || '').length, 220_001),
    bodyTextLength: Math.min((answer?.textContent || '').length, 220_001),
    rootChildren: Math.min(root?.childElementCount || 0, 1_000),
    bodyChildren: Math.min(answer?.childElementCount || 0, 1_000) };
}
function chatGPTUserBody(root) {
  return root.querySelector('[data-markdown-text-style="user-message"]')
    || root.querySelector('.whitespace-pre-wrap') || root.querySelector('[data-message-author-role="user"]') || root;
}
// Private per-round ownership. A composer or Send acknowledgment is never
// proof of a rendered request; only the exact owned body can bind its digest.
const chatGPTSubmissionDiagnosticStages = Object.freeze(['missing_state', 'begin_invocation', 'begin_input', 'begin_text',
  'begin_initial', 'begin_admission', 'begin_digest', 'claim_admission', 'observe_context', 'observe_ordinal',
  'observe_record', 'observe_count', 'observe_body', 'observe_expansion', 'observe_text', 'observe_parent', 'observe_digest']);
function chatGPTSubmissionDiagnostic(state, stage, selectedRecord = null) {
  // Finite, read-only failure facts. Never call the product proof getter here:
  // that getter can latch authority; diagnostics must not change its state.
  try {
    if (!chatGPTSubmissionDiagnosticStages.includes(stage)) return null;
    const actions = ['inspect', 'prepare', 'insert', 'sendReady', 'submit', 'verifyModel', 'verifyProductMode',
      'ensureChatMode', 'stop', 'discoverModels', 'selectModel', 'modelDiagnostic', 'enableTemporary', 'cleanup', 'unknown'];
    const sequence = value => Number.isInteger(value) && value >= 0 && value <= 16 ? value : null;
    const record = selectedRecord || state?.pending || state?.lastVerified;
    const roots = chatGPTMessageRoots('user'), root = record && Number.isInteger(record.sequence) ? roots[record.sequence - 1] : null;
    const body = root && chatGPTUserBody(root), product = globalThis.__computaChatProductMode;
    const raw = body ? body.innerText || body.textContent || '' : null;
    const canonical = typeof raw === 'string' && raw.length <= 180_200 ? chatGPTSubmissionCanonical(raw) : null;
    const contextMatches = websiteChatInvocationLease != null && globalThis.__computaChatActiveInvocation === websiteChatInvocationLease
      && !!state && !state.revoked && state.document === document && state.owner === input.ownerToken
      && globalThis.__computaChatSubmissionState === state && globalThis.__computaModelOwner === state.owner
      && window === window.top && input.provider === 'chatgpt' && location.origin === 'https://chatgpt.com'
      && document.URL === input.expectedURL && state.firstMarker === input.expectedFirstUserMarker
      && !!product && !product.invalidated && product.document === document && product.owner === state.owner
      && product.temporaryAcknowledged === true && chatGPTRenderedTemporary()
      && (input.expectedModelChoice == null || state.modelChoice == null || websiteModelChoiceEqual(state.modelChoice, input.expectedModelChoice));
    return { kind: 'chatgpt_submission_v1', action: actions.includes(input.action) ? input.action : 'unknown', stage,
      requestedSequence: sequence(input.submissionSequence), recordSequence: sequence(record?.sequence), userCount: Math.min(roots.length, 17),
      contextMatches: !!contextMatches, nativePinMatches: !!record && chatGPTSubmissionPins(record),
      pendingRecord: !!record && state?.pending === record, lastVerifiedRecord: !!record && state?.lastVerified === record,
      rootSame: !!record?.root && root === record.root, bodySame: !!record?.body && body === record.body,
      oldRootConnected: record?.root?.isConnected === true, oldBodyConnected: record?.body?.isConnected === true,
      currentRootConnected: root?.isConnected === true, currentBodyConnected: body?.isConnected === true,
      canonicalMatches: !!record && canonical !== null && canonical === record.canonical,
      oldRootPresent: record?.root != null, oldBodyPresent: record?.body != null,
      recordPhase: !record ? 'none' : ['prepared', 'send_claimed', 'verified'].includes(record.phase) ? record.phase : 'unknown',
      contextChecks: chatGPTSubmissionContextFailure?.state === state ? chatGPTSubmissionContextFailure.checks : null };
  } catch { return null; }
}
function chatGPTSubmissionFailure(state, stage = 'missing_state', record = null) {
  if (websiteChatInvocationLease == null || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease)
    return { error: 'document_changed', detail: 'model_read_context' };
  const context = chatGPTSubmissionContextFailure;
  if (['inspect', 'verifyModel', 'verifyProductMode'].includes(input.action)
    && ['observe_context', 'observe_digest'].includes(stage) && context?.state === state
    && context.checks.urlMatches === false && document.URL !== input.expectedURL
    && chatGPTSubmissionContextCheckKeys.slice(0, chatGPTSubmissionContextCheckKeys.indexOf('urlMatches'))
      .every(key => context.checks[key] === true)) {
    // A URL-bound read that crossed an SPA transition supplies no authority.
    // Native must certify the existing route edge and issue a fresh inspect;
    // do not let this discarded read revoke that inspect's unchanged claim.
    // Body/pin/owner failures at the current URL still permanently revoke.
    return { error: 'document_changed', detail: 'model_read_context' };
  }
  const submissionDiagnostic = chatGPTSubmissionDiagnostic(state, stage, record);
  if (state) state.revoked = true;
  return { error: 'conversation_changed', detail: 'submission_message', ...(submissionDiagnostic ? { submissionDiagnostic } : {}) };
}
// This invocation-local witness observes the authoritative conjunction once.
// Null means short-circuiting did not evaluate that check. Returning the actual
// operand preserves the old truthiness, ordering and product getter effects.
const chatGPTSubmissionContextCheckKeys = Object.freeze(['invocationClaimed', 'invocationCurrent', 'statePresent',
  'stateNotRevoked', 'stateDocumentMatches', 'stateOwnerMatches', 'stateCurrent', 'globalOwnerMatches', 'topFrame',
  'providerMatches', 'originMatches', 'urlMatches', 'firstMarkerMatches', 'productProofVerified', 'temporaryVerified',
  'modelChoiceMatches']);
let chatGPTSubmissionContextFailure = null;
function chatGPTSubmissionContext(state, initialDispatchAcknowledgment = false) {
  const checks = Object.fromEntries(chatGPTSubmissionContextCheckKeys.map(key => [key, null]));
  const check = (key, value) => { checks[key] = !!value; return value; };
  const result = check('invocationClaimed', websiteChatInvocationLease != null)
    && check('invocationCurrent', globalThis.__computaChatActiveInvocation === websiteChatInvocationLease)
    && check('statePresent', state) && check('stateNotRevoked', !state.revoked)
    && check('stateDocumentMatches', state.document === document) && check('stateOwnerMatches', state.owner === input.ownerToken)
    && check('stateCurrent', globalThis.__computaChatSubmissionState === state)
    && check('globalOwnerMatches', globalThis.__computaModelOwner === state.owner)
    && check('topFrame', window === window.top) && check('providerMatches', input.provider === 'chatgpt')
    && check('originMatches', location.origin === 'https://chatgpt.com')
    && check('urlMatches', document.URL === input.expectedURL || initialDispatchAcknowledgment && chatGPTInitialSubmissionRoute(state))
    && check('firstMarkerMatches', state.firstMarker === input.expectedFirstUserMarker)
    && check('productProofVerified', chatGPTProductModeProof()) && check('temporaryVerified', chatGPTTemporaryVerified())
    && check('modelChoiceMatches', input.expectedModelChoice == null || state.modelChoice == null
      || websiteModelChoiceEqual(state.modelChoice, input.expectedModelChoice));
  if (!result && chatGPTSubmissionContextFailure == null) chatGPTSubmissionContextFailure = { state, checks };
  return result;
}
function chatGPTInitialSubmissionRoute(state) {
  // This acknowledges only the already-claimed first click. Native still
  // validates the root-to-conversation edge, and the next URL-bound read must
  // prove the complete body before any response or conversation can be used.
  try {
    const oldURL = new URL(input.expectedURL), nextURL = new URL(document.URL), record = state.pending;
    return input.action === 'submit' && record?.sequence === 1 && record.phase === 'send_claimed'
      && input.submissionSequence === 1 && input.submissionMarker === record.marker
      && input.expectedFirstUserFingerprint == null && oldURL.origin === 'https://chatgpt.com'
      && oldURL.pathname === '/' && nextURL.origin === oldURL.origin && /^\/c\/[^/]+\/?$/.test(nextURL.pathname)
      && globalThis.__computaModelLastSubmissionCount === 0 && chatGPTMessageRoots('user').length <= 1;
  } catch { return false; }
}
async function chatGPTFirstReplacementObservation(request, capturedCount, snapshot, access) {
  const observed = await websiteModelReplacementObservation(request, capturedCount, snapshot, access);
  if (observed?.error !== 'first_user_observation_replaced') return observed;
  const state = globalThis.__computaChatSubmissionState, record = state?.lastVerified;
  // Only carry the shared helper's existing certified discard. No per-round
  // read invents a certificate or renews Native's one-fresh-inspect budget.
  if (chatGPTSubmissionContext(state) && record?.sequence === 1 && record.phase === 'verified'
    && state.pending == null && record.root === snapshot.root && record.body === snapshot.body
    && !record.root.isConnected && !record.body.isConnected && !record.replacement
    && record.fingerprint === request.expectedFirstUserFingerprint && chatGPTSubmissionPins(record)) {
    const roots = chatGPTMessageRoots('user'), root = roots[0], body = root && chatGPTUserBody(root);
    if (roots.length === capturedCount && root?.isConnected && body?.isConnected
      && chatGPTSubmissionCanonical(body.innerText || body.textContent || '') === record.canonical)
      record.replacement = { root, body, oldRoot: record.root, oldBody: record.body, document, owner: state.owner };
  }
  return observed;
}
function chatGPTSubmissionReplacement(state, record, root, body, roots) {
  if (input.action !== 'inspect' || record.sequence !== 1 || record.phase !== 'verified'
    || state.pending != null || state.lastVerified !== record || !chatGPTSubmissionContext(state)
    || !chatGPTSubmissionPins(record) || record.root.isConnected || record.body.isConnected
    || root === record.root || body === record.body || roots[0] !== root || !root.isConnected || !body.isConnected
    || chatGPTUserBody(root) !== body) return null;
  const receipt = record.replacement;
  if (receipt && input.expectedFirstUserFingerprint === record.fingerprint
    && receipt.root === root && receipt.body === body && receipt.oldRoot === record.root && receipt.oldBody === record.body
    && receipt.document === document && receipt.owner === state.owner) return receipt;
  // A private-only first read cannot freeze physical identity before Native
  // adopts its first fingerprint. Its later independent binding inspect still
  // proves the actual full body and current outbound digest from scratch.
  if (!receipt && record.nativeFirstPinned !== true && input.allowFirstUserBinding === true
    && input.expectedFirstUserFingerprint == null && roots.length === 1)
    return { root, body, oldRoot: record.root, oldBody: record.body, document, owner: state.owner, provisional: true };
  return null;
}
function chatGPTSubmissionCanonical(text) {
  return typeof text === 'string' && text.length <= 180_200
    ? text.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null;
}
function chatGPTSubmissionPins(record) {
  const pins = input.expectedSubmissionProofs;
  if (!Array.isArray(pins) || pins.length > 2) return false;
  let previous = null, matched = false;
  for (const pin of pins) {
    if (!pin || Object.keys(pin).sort().join(',') !== 'fingerprint,sequence'
      || !Number.isInteger(pin.sequence) || pin.sequence < 1 || pin.sequence > 10_000
      || typeof pin.fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(pin.fingerprint)
      || previous != null && pin.sequence !== previous + 1) return false;
    previous = pin.sequence;
    if (pin.sequence === record.sequence) matched = pin.fingerprint === record.fingerprint;
  }
  return matched;
}
function chatGPTSubmissionBodyIntact(record, roots = chatGPTMessageRoots('user'), replacement = null) {
  const root = replacement?.root || record.root, body = replacement?.body || record.body;
  return root?.isConnected && body?.isConnected
    && roots[record.sequence - 1] === root && chatGPTUserBody(root) === body
    && (!replacement || !record.root.isConnected && !record.body.isConnected
      && replacement.oldRoot === record.root && replacement.oldBody === record.body)
    && chatGPTSubmissionCanonical(body.innerText || body.textContent || '') === record.canonical;
}
async function chatGPTBeginSubmission(request) {
  if (websiteChatInvocationLease == null || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease)
    return chatGPTSubmissionFailure(null, 'begin_invocation');
  const sequence = request.submissionSequence, marker = request.submissionMarker;
  let state = globalThis.__computaChatSubmissionState;
  if (!Number.isInteger(sequence) || sequence < 1 || sequence > 16
    || typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker)) return chatGPTSubmissionFailure(state, 'begin_input');
  const roots = chatGPTMessageRoots('user'), canonical = chatGPTSubmissionCanonical(request.prompt);
  const suffix = `Computa session marker: ${marker}`;
  if (canonical == null || !canonical.endsWith(`\n\n${suffix}`)
    || canonical.split('\n').filter(line => line === suffix).length !== 1
    || roots.length !== sequence - 1) return chatGPTSubmissionFailure(state, 'begin_text');
  if (!state) {
    if (sequence !== 1 || roots.length || marker !== input.expectedFirstUserMarker) return chatGPTSubmissionFailure(state, 'begin_initial');
    state = { document, owner: input.ownerToken, firstMarker: input.expectedFirstUserMarker,
      modelChoice: websiteModelChoiceValid(input.expectedModelChoice) ? input.expectedModelChoice : null,
      revoked: false, pending: null, lastVerified: null, markers: new Set() };
    globalThis.__computaChatSubmissionState = state;
  }
  const parent = state.lastVerified;
  if (!chatGPTSubmissionContext(state) || state.pending || state.markers.has(marker)
    || (sequence === 1 ? parent != null : !parent || parent.sequence !== sequence - 1
      || !chatGPTSubmissionPins(parent) || !chatGPTSubmissionBodyIntact(parent, roots)))
    return chatGPTSubmissionFailure(state, 'begin_admission', parent);
  const captured = [...roots];
  const hashStarted = chatGPTPreparationNow();
  let digest;
  try { digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical)); }
  finally { chatGPTPreparationRecord('beginSubmissionHashMs', hashStarted); }
  const now = chatGPTMessageRoots('user');
  if (!chatGPTSubmissionContext(state) || state.pending || state.lastVerified !== parent
    || now.length !== captured.length || now.some((node, index) => node !== captured[index])
    || parent && !chatGPTSubmissionBodyIntact(parent, now)) return chatGPTSubmissionFailure(state, 'begin_digest', parent);
  state.markers.add(marker);
  state.pending = { document, owner: state.owner, sequence, marker, canonical,
    fingerprint: [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join(''),
    phase: 'prepared', root: null, body: null, expansionAttempted: false };
  return null;
}
function chatGPTClaimSubmission(request, prompt, userCount) {
  const state = globalThis.__computaChatSubmissionState;
  if (!state) return request.submissionSequence == null && request.submissionMarker == null ? null : chatGPTSubmissionFailure(state, 'claim_admission');
  const record = state.pending;
  if (!chatGPTSubmissionContext(state) || !record || record.phase !== 'prepared'
    || record.sequence !== request.submissionSequence || record.marker !== request.submissionMarker
    || userCount !== record.sequence - 1 || chatGPTSubmissionCanonical(prompt) !== record.canonical
    || !chatGPTSubmissionPins(record)) return chatGPTSubmissionFailure(state, 'claim_admission', record);
  record.phase = 'send_claimed';
  return null;
}
async function chatGPTExpandSubmission(state, record, root, body, rendered) {
  if (!['inspect', 'verifyModel'].includes(input.action) || input.allowSubmissionExpansion !== true || record.sequence < 2
    || record.phase !== 'send_claimed' || record.expansionAttempted || !rendered
    || rendered.length >= record.canonical.length || !record.canonical.startsWith(rendered)
    || rendered.includes(`Computa session marker: ${record.marker}`)
    || !websiteModelChoiceValid(input.expectedModelChoice)) return false;
  const capturedRoots = chatGPTMessageRoots('user');
  const intact = () => chatGPTSubmissionContext(state) && state.pending === record
    && chatGPTSubmissionPins(record) && capturedRoots.length === record.sequence
    && chatGPTMessageRoots('user').length === capturedRoots.length
    && chatGPTMessageRoots('user').every((node, index) => node === capturedRoots[index])
    && root === capturedRoots[record.sequence - 1] && root.isConnected && body.isConnected
    && chatGPTUserBody(root) === body;
  if (!intact()) return false;
  record.expansionAttempted = true;
  const controls = () => chatGPTFirstUserExpandControls(root, capturedRoots, 3);
  const candidates = controls(), control = candidates.length === 1 ? candidates[0] : null;
  const available = () => control && control.isConnected && (control.tagName === 'BUTTON' || control.getAttribute('role') === 'button')
    && !control.disabled && control.getAttribute('aria-disabled') !== 'true' && getComputedStyle(control).pointerEvents !== 'none'
    && controls().length === 1 && controls()[0] === control;
  if (!available()) return false;
  const model = await websiteModelReadEvidence('chatgpt', input.expectedModelChoice, null,
    { scope: 'action_precheck', action: input.action });
  if (model.error || !intact() || !available()
    || chatGPTSubmissionCanonical(body.innerText || body.textContent || '') !== rendered) return false;
  if (!chatGPTControlExposed(control)) {
    const rect = control.getBoundingClientRect(), x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
    const offscreen = [x, y, rect.width, rect.height].every(Number.isFinite) && rect.width > 0 && rect.height > 0
      && (x < 0 || y < 0 || Number.isFinite(window.innerWidth) && x >= window.innerWidth
        || Number.isFinite(window.innerHeight) && y >= window.innerHeight);
    if (!offscreen || typeof control.scrollIntoView !== 'function') return false;
    control.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
  }
  if (!intact() || !available() || !chatGPTControlExposed(control)) return false;
  control.click();
  await websiteModelWaitForChange(Date.now() + 1_800, () => !intact()
    || chatGPTSubmissionCanonical(body.innerText || body.textContent || '') !== rendered, 'submission_expansion');
  return intact() && chatGPTSubmissionCanonical(body.innerText || body.textContent || '') === record.canonical;
}
function chatGPTPendingProductSubmission(state, record, roots, root, body, rendered, observed) {
  // A product-only recheck has no model or expansion authority. A recognized
  // collapsed current body can remain pending until the normal model/inspect
  // path proves every actual byte. This result never binds a body or answer.
  try {
    const parent = state.lastVerified, product = observed.productModeEvidence;
    return input.action === 'verifyProductMode' && state.pending === record && record.phase === 'send_claimed'
      && record.sequence > 1 && record.root == null && record.body == null && record.expansionAttempted === false
      && input.submissionSequence === record.sequence && input.submissionMarker === record.marker
      && roots.length === record.sequence && roots[record.sequence - 1] === root
      && root.isConnected && body.isConnected && chatGPTUserBody(root) === body
      && chatGPTSubmissionContext(state) && chatGPTSubmissionPins(record)
      && parent?.sequence === record.sequence - 1 && chatGPTSubmissionPins(parent) && chatGPTSubmissionBodyIntact(parent, roots)
      && observed.temporary === true && product?.product === 'chatgpt' && product.mode === 'chat'
      && product.source === 'composer_mode_control' && product.temporaryTransition === 'acknowledged'
      && typeof rendered === 'string' && rendered.length > 0 && rendered.length < record.canonical.length
      && record.canonical.startsWith(rendered) && !rendered.includes(`Computa session marker: ${record.marker}`)
      && chatGPTSubmissionCanonical(body.innerText || body.textContent || '') === rendered;
  } catch { return false; }
}
function chatGPTOptimisticSubmissionPending(state, record, roots, root, body, rendered) {
  // This observed direct-SPAN layout is an optimistic echo. React replaces it
  // with the normal (possibly clipped) DIV body; do not pin either first-user
  // lineage or a retained round to its temporary physical nodes. No positive
  // proof, new deadline, expansion or Send comes from this negative receipt.
  if (!body || body.tagName !== 'SPAN' || body.parentElement !== root) return null;
  const parent = state?.lastVerified, first = globalThis.__computaModelFirstProof;
  const markerLine = `Computa session marker: ${record?.marker}`;
  if (!['inspect', 'verifyModel', 'verifyProductMode'].includes(input.action)
    || !record || state.pending !== record || record.phase !== 'send_claimed'
    || record.root != null || record.body != null || record.expansionAttempted !== false
    || record.document !== document || record.owner !== state.owner || !chatGPTSubmissionContext(state)
    || input.submissionSequence !== record.sequence || input.submissionMarker !== record.marker
    || !chatGPTSubmissionPins(record) || roots.length !== record.sequence || roots[record.sequence - 1] !== root
    || !root?.isConnected || !body.isConnected || body.parentElement !== root || chatGPTUserBody(root) !== body
    || root.getAttribute('data-user-message-bubble') !== 'true' || !body.classList.contains('whitespace-pre-wrap')
    || !chatGPTTemporaryOutlineForRoot(root, body)
    || typeof rendered !== 'string' || !rendered || (rendered !== record.canonical
      && (rendered.length >= record.canonical.length || !record.canonical.startsWith(rendered) || rendered.includes(markerLine)))
    || (record.sequence === 1
      ? parent != null || first != null || input.expectedFirstUserFingerprint != null || input.allowFirstUserBinding !== true
        || globalThis.__computaModelLastSubmissionCount !== 0
      : !parent || parent.sequence !== record.sequence - 1 || !chatGPTSubmissionPins(parent)
        || !chatGPTSubmissionBodyIntact(parent, roots) || !first || first.marker !== input.expectedFirstUserMarker
        || first.fingerprint !== input.expectedFirstUserFingerprint
        || globalThis.__computaModelLastSubmissionCount !== record.sequence - 1))
    return chatGPTSubmissionFailure(state, 'observe_optimistic', record);
  return { error: 'submission_observation_pending', detail: 'optimistic_user_body',
    submissionSequence: record.sequence, submissionFingerprint: record.fingerprint };
}
async function chatGPTSubmissionResult(request, observed) {
  if (observed.error) return observed;
  const capability = { submissionOwnershipCapability: 'per_submission_ownership_v1' };
  const state = globalThis.__computaChatSubmissionState;
  if (!state) return observed;
  if (!chatGPTSubmissionContext(state, request.action === 'submit' && observed.submitted === true)) return chatGPTSubmissionFailure(state, 'observe_context');
  // Dispatch acknowledgment only. Never inspect/hash a body on the click path.
  if (request.action === 'submit' && observed.submitted === true)
    return { ...observed, ...capability, submissionPending: true, text: '', answerComplete: false };
  const roots = chatGPTMessageRoots('user'), pending = state.pending;
  const active = pending?.phase === 'send_claimed' ? pending : state.lastVerified;
  if (active && !['insert', 'sendReady', 'submit'].includes(request.action)
    && (request.submissionSequence !== active.sequence || request.submissionMarker !== active.marker))
    return chatGPTSubmissionFailure(state, 'observe_ordinal', active);
  let record = pending?.phase === 'send_claimed' && roots.length === pending.sequence ? pending : state.lastVerified;
  if (!record) {
    if (roots.length === 0 && (!pending || pending.sequence === 1))
      return { ...observed, ...capability, ...(pending?.phase === 'send_claimed'
        ? { submissionPending: true, text: '', answerComplete: false } : {}) };
    return chatGPTSubmissionFailure(state, 'observe_record');
  }
  const waiting = pending?.phase === 'send_claimed' && record !== pending;
  if (roots.length !== (waiting ? pending.sequence - 1 : record.sequence)
    || !chatGPTSubmissionPins(record) || record.document !== document || record.owner !== state.owner)
    return chatGPTSubmissionFailure(state, 'observe_count', record);
  const root = roots[record.sequence - 1], body = root && chatGPTUserBody(root);
  const replacement = record.phase === 'verified' && (root !== record.root || body !== record.body)
    ? chatGPTSubmissionReplacement(state, record, root, body, roots) : null;
  if (!root?.isConnected || !body?.isConnected || record.phase === 'verified' && (root !== record.root || body !== record.body) && !replacement)
    return chatGPTSubmissionFailure(state, 'observe_body', record);
  let rendered = chatGPTSubmissionCanonical(body.innerText || body.textContent || ''), expanded = false;
  if (record === pending) {
    const optimistic = chatGPTOptimisticSubmissionPending(state, record, roots, root, body, rendered);
    if (optimistic) return optimistic;
  }
  if (rendered !== record.canonical && record === pending && record.sequence > 1) {
    if (chatGPTPendingProductSubmission(state, record, roots, root, body, rendered, observed))
      return { ...observed, ...capability, submissionPending: true, text: '', answerComplete: false };
    if (!await chatGPTExpandSubmission(state, record, root, body, rendered)) return chatGPTSubmissionFailure(state, 'observe_expansion', record);
    expanded = true;
    rendered = chatGPTSubmissionCanonical(body.innerText || body.textContent || '');
  }
  const markerLine = `Computa session marker: ${record.marker}`;
  if (rendered !== record.canonical || !rendered.endsWith(`\n\n${markerLine}`)
    || rendered.split('\n').filter(line => line === markerLine).length !== 1) return chatGPTSubmissionFailure(state, 'observe_text', record);
  const capturedAssistants = chatGPTMessageRoots('assistant'), capturedParent = state.lastVerified;
  if (capturedParent && !chatGPTSubmissionBodyIntact(capturedParent, roots, capturedParent === record ? replacement : null)) return chatGPTSubmissionFailure(state, 'observe_parent', capturedParent);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const currentRoots = chatGPTMessageRoots('user');
  if (!chatGPTSubmissionContext(state) || (state.pending !== pending) || !chatGPTSubmissionPins(record)
    || state.lastVerified !== capturedParent || capturedParent && !chatGPTSubmissionBodyIntact(capturedParent, currentRoots, capturedParent === record ? replacement : null)
    || currentRoots.length !== roots.length || currentRoots.some((node, index) => node !== roots[index])
    || !root.isConnected || !body.isConnected || chatGPTUserBody(root) !== body
    || chatGPTSubmissionCanonical(body.innerText || body.textContent || '') !== rendered
    || fingerprint !== record.fingerprint || replacement && (replacement.provisional
      ? input.allowFirstUserBinding !== true || input.expectedFirstUserFingerprint != null || record.nativeFirstPinned === true
      : record.replacement !== replacement || input.expectedFirstUserFingerprint !== record.fingerprint)) return chatGPTSubmissionFailure(state, 'observe_digest', record);
  if (replacement) { record.root = root; record.body = body; record.replacement = null; }
  if (input.expectedFirstUserFingerprint === record.fingerprint) record.nativeFirstPinned = true;
  if (record === pending) { record.root = root; record.body = body; record.phase = 'verified'; state.lastVerified = record; state.pending = null; }
  if (expanded && chatGPTFinalResponseSnapshot) {
    // Only this invocation's authorized expansion can advance the current
    // body's strict prefix to its now digest-proven exact canonical bytes.
    // Preserve physical identity, every prior user, and the assistant snapshot.
    const captured = chatGPTFinalResponseSnapshot.users[record.sequence - 1];
    if (chatGPTFinalResponseSnapshot.users.length !== record.sequence || !captured
      || captured.root !== root || captured.body !== body || !captured.text
      || captured.text.length >= rendered.length || !rendered.startsWith(captured.text)
      || captured.text.includes(markerLine)) return chatGPTSubmissionFailure(state, 'observe_expansion_snapshot', record);
    chatGPTFinalResponseSnapshot.users = chatGPTFinalResponseSnapshot.users.map((user, index) =>
      index === record.sequence - 1 ? { ...user, text: rendered } : user);
  }
  const nowAssistants = chatGPTMessageRoots('assistant');
  const responseChanged = nowAssistants.length !== capturedAssistants.length
    || nowAssistants.some((node, index) => node !== capturedAssistants[index]);
  return { ...observed, ...capability, submissionProof: { sequence: record.sequence, fingerprint },
    ...(waiting || responseChanged || nowAssistants.length < record.sequence ? { submissionPending: waiting, text: '', answerComplete: false,
      responseCount: nowAssistants.length } : {}) };
}
function chatGPTRenderedTemporary() {
  const visible = node => node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
  // Read layout only for exact off controls on the common path. The Save
  // fallback retains its original current-visibility and exact-label rules.
  if ([...document.querySelectorAll('button[aria-label="Turn off temporary chat"]')].some(visible)) return true;
  if (new URL(document.URL).searchParams.get('temporary-chat') !== 'true') return false;
  const buttons = [...document.querySelectorAll('button')].filter(visible);
  if (buttons.some(node => node.getAttribute('aria-label') === 'Save chat' || (node.innerText || '').trim() === 'Save chat')) return true;
  return chatGPTTemporaryOutlineVerified();
}
// Pure physical signature only. Callers must independently prove the submitted
// user root and the acknowledged transition; this decoration grants no ownership.
function chatGPTTemporaryOutlineForRoot(root, body) {
  try {
    const svgNamespace = 'http://www.w3.org/2000/svg';
    const excluded = '[data-message-author-role="assistant"], [data-markdown-text-style="assistant-message"], '
      + '[data-turn="assistant"], [role="tooltip"], pre, code, button, a, form, input, textarea, '
      + '[role="button"], [role="link"], [role="menu"], [role="dialog"], [contenteditable="true"], [contenteditable=""]';
    const physical = (node, decoration = null) => {
      if (!node?.isConnected || node.nodeType !== 1 || node.getClientRects().length === 0) return false;
      const rect = node.getBoundingClientRect();
      if (![rect.width, rect.height].every(value => Number.isFinite(value) && value > 0 && value <= 10_000_000)) return false;
      let current = node, depth = 0;
      for (; current && depth < 64; current = current.parentElement, depth++) {
        const style = getComputedStyle(current), opacity = Number(style.opacity);
        if (current.hasAttribute('inert') || current !== decoration && current.getAttribute('aria-hidden') === 'true'
          || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse'
          || !Number.isFinite(opacity) || opacity <= 0) return false;
      }
      return current == null;
    };
    if (!root || !body || root === body || root.tagName !== 'DIV'
      || root.getAttribute('data-user-message-bubble') !== 'true' || !root.contains(body)
      || root.closest(excluded) || body.closest(excluded) || !physical(root) || !physical(body)) return false;
    const selected = root.querySelector('[data-markdown-text-style="user-message"]')
      || root.querySelector('.whitespace-pre-wrap') || root.querySelector('[data-message-author-role="user"]') || root;
    const content = root.lastElementChild;
    const bodyShape = content?.tagName === 'DIV' && content.contains(body)
      || content === body && body.tagName === 'SPAN' && body.classList.contains('whitespace-pre-wrap');
    if (selected !== body || root.children.length !== 2 || !bodyShape) return false;
    const allSVGs = [...root.querySelectorAll('svg[class]')];
    if (allSVGs.length > 128) return false;
    const outlines = allSVGs.filter(node => [...node.classList].some(value => value.startsWith('temporaryOutline-')));
    if (outlines.length !== 1) return false;
    const svg = outlines[0], attrs = node => [...node.attributes].map(attribute => attribute.name).sort().join(',');
    if (svg !== root.firstElementChild || svg.parentElement !== root || body.contains(svg)
      || svg.namespaceURI !== svgNamespace || svg.localName !== 'svg'
      || attrs(svg) !== 'aria-hidden,class,focusable' || svg.getAttribute('aria-hidden') !== 'true'
      || svg.getAttribute('focusable') !== 'false' || svg.closest(excluded) || !physical(svg, svg)) return false;
    const classes = [...svg.classList].sort();
    const fixed = ['absolute', 'h-full', 'inset-0', 'pointer-events-none', 'w-full'];
    if (classes.length !== 6 || !fixed.every(value => classes.includes(value))
      || classes.filter(value => /^temporaryOutline-[A-Za-z0-9_-]{1,64}$/.test(value)).length !== 1
      || svg.children.length !== 1 || [...svg.childNodes].some(node => node.nodeType !== 1
        && (node.nodeType !== 3 || node.textContent.trim() !== ''))) return false;
    const rect = svg.firstElementChild;
    const values = { x: '0.5', y: '0.5', width: 'calc(100% - 1px)', height: 'calc(100% - 1px)',
      fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.4', 'stroke-width': '1',
      'stroke-dasharray': '8 8', 'vector-effect': 'non-scaling-stroke' };
    if (rect.namespaceURI !== svgNamespace || rect.localName !== 'rect'
      || attrs(rect) !== Object.keys(values).sort().join(',') || rect.children.length !== 0
      || rect.textContent.trim() !== '' || !Object.entries(values).every(([name, value]) => rect.getAttribute(name) === value)
      || !physical(rect, svg)) return false;
    const style = getComputedStyle(rect);
    return style.stroke !== 'none' && Number(style.strokeOpacity) > 0 && Number.parseFloat(style.strokeWidth) > 0;
  } catch { return false; }
}
// This fallback observes an existing acknowledged Temporary session only. It
// never latches product provenance, binds a body, or calls proof/context getters.
function chatGPTTemporaryOutlineVerified() {
  try {
    const product = globalThis.__computaChatProductMode, state = globalThis.__computaChatSubmissionState;
    const url = new URL(document.URL), marker = input.expectedFirstUserMarker;
    if (websiteChatInvocationLease == null || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease
      || websiteChatInvocationLease.document !== document || websiteChatInvocationLease.owner !== input.ownerToken
      || window !== window.top || input.provider !== 'chatgpt' || url.origin !== 'https://chatgpt.com'
      || url.username || url.password || url.searchParams.getAll('temporary-chat').length !== 1
      || url.searchParams.get('temporary-chat') !== 'true'
      || !/^\/(?:c\/(?:[A-Za-z0-9-]+|local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+)\/?)?$/.test(url.pathname)
      || !state || state.revoked || state.document !== document || state.owner !== input.ownerToken
      || globalThis.__computaModelOwner !== state.owner
      || document.URL !== input.expectedURL && !chatGPTInitialSubmissionRoute(state)
      || !product || product.invalidated || product.document !== document || product.owner !== state.owner
      || product.temporaryRequested !== true || product.temporaryAcknowledged !== true
      || !websiteModelChoiceValid(state.modelChoice)
      || input.expectedModelChoice != null && !websiteModelChoiceEqual(state.modelChoice, input.expectedModelChoice)
      || typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker) || state.firstMarker !== marker
      || globalThis.__computaModelFirstMarker !== marker || globalThis.__computaModelFirstSubmitted !== true) return false;
    const prompt = globalThis.__computaModelFirstPrompt, markerLine = `Computa session marker: ${marker}`;
    if (typeof prompt !== 'string' || prompt.length > 180_000 || !prompt.endsWith(`\n\n${markerLine}`)
      || prompt.split('\n').filter(line => line === markerLine).length !== 1) return false;
    const canonical = chatGPTSubmissionCanonical(prompt), roots = chatGPTMessageRoots('user');
    const root = roots[0], body = root && chatGPTUserBody(root);
    if (canonical == null || !root?.isConnected || !body?.isConnected || roots.length < 1 || roots.length > 16) return false;
    const rendered = chatGPTSubmissionCanonical(body.innerText || body.textContent || ''), first = globalThis.__computaModelFirstProof;
    if (!rendered) return false;
    if (input.expectedFirstUserFingerprint == null) {
      // The first claimed Send may still be clipped. Its exact prepared bytes
      // and native round pin precede expansion; they grant no rendered binding.
      const record = state.pending?.phase === 'send_claimed' ? state.pending : state.lastVerified;
      if (roots.length !== 1 || globalThis.__computaModelLastSubmissionCount !== 0
        || !record || record.sequence !== 1 || record.document !== document || record.owner !== state.owner
        || record.marker !== marker || record.canonical !== canonical || !chatGPTSubmissionPins(record)
        || !['send_claimed', 'verified'].includes(record.phase)
        || record.phase === 'verified' && (input.action !== 'inspect' || input.allowFirstUserBinding !== true
          || !chatGPTSubmissionBodyIntact(record, roots))
        || first != null && (first.marker !== marker || first.fingerprint !== record.fingerprint || rendered !== canonical)
        || rendered !== canonical && (!canonical.startsWith(rendered) || rendered.length >= canonical.length
          || rendered.includes(markerLine))) return false;
    } else {
      // Retained rounds retain the full first native/private pin and the latest
      // digest-proven body. A pending append cannot replace either witness.
      const record = state.lastVerified;
      if (typeof input.expectedFirstUserFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(input.expectedFirstUserFingerprint)
        || !first || first.marker !== marker || first.fingerprint !== input.expectedFirstUserFingerprint
        || rendered !== canonical || !record || record.phase !== 'verified' || record.document !== document
        || record.owner !== state.owner || !chatGPTSubmissionPins(record) || !chatGPTSubmissionBodyIntact(record, roots)) return false;
    }
    return chatGPTTemporaryOutlineForRoot(root, body);
  } catch { return false; }
}
// Product mode is independent of the family picker: normal Chat and Work can
// offer the same models. Only a fresh, empty normal root may establish Chat
// provenance, followed by this owner's actual temporary-chat transition.
function chatGPTProductModeState() {
  const boundary = '[data-message-author-role], [data-markdown-text-style], [data-turn], [data-user-message-bubble], [role="tooltip"]';
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden';
  const visible = node => physical(node) && !node.closest('[inert], [aria-hidden="true"]');
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const label = node => websiteModelNormalize(node.getAttribute('aria-label') || node.innerText || node.textContent);
  const labelledGroup = node => {
    if (node.getAttribute('aria-label') != null) return websiteModelNormalize(node.getAttribute('aria-label')) === 'Composer mode';
    const id = node.getAttribute('aria-labelledby');
    if (typeof id !== 'string' || !id || id.length > 256 || /\s/.test(id)) return false;
    const labels = [...document.querySelectorAll('[id]')].slice(0, 512).filter(item => item.getAttribute('id') === id);
    return labels.length === 1 && physical(labels[0]) && websiteModelNormalize(labels[0].textContent) === 'Composer mode';
  };
  const groups = [...document.querySelectorAll('[aria-label], [aria-labelledby]')].slice(0, 1_024)
    .filter(node => !node.closest(boundary) && labelledGroup(node) && physical(node));
  const group = groups.length === 1 ? groups[0] : null;
  const controls = group ? [...group.querySelectorAll('button, [role="button"], [role="radio"], [role="switch"], [role="checkbox"]')].slice(0, 32)
    .filter(node => physical(node) && !node.closest(boundary) && ['Chat', 'Work'].includes(label(node))) : [];
  const chat = controls.filter(node => label(node) === 'Chat'), work = controls.filter(node => label(node) === 'Work');
  const state = node => {
    const role = node.getAttribute('role');
    const pressed = node.getAttribute('aria-pressed'), checked = node.getAttribute('aria-checked');
    // Mixed states or competing state attributes never imply a product choice.
    if (pressed != null && checked != null) return null;
    const value = pressed != null && (node.tagName.toLowerCase() === 'button' && (!role || role === 'button') || role === 'button')
      ? pressed : checked != null && ['radio', 'switch', 'checkbox'].includes(role) ? checked : null;
    return value === 'true' ? true : value === 'false' ? false : null;
  };
  const pair = chat.length === 1 && work.length === 1;
  const chatSelected = pair ? state(chat[0]) : null, workSelected = pair ? state(work[0]) : null;
  const recognized = pair && chatSelected != null && workSelected != null && chatSelected !== workSelected;
  return { group, groups, chat: chat[0] || null, work: work[0] || null, recognized, chatSelected, workSelected,
    ready: recognized && enabled(chat[0]) && enabled(work[0]),
    contradictory: groups.length > 1 || !!group && (!recognized || workSelected === true), physical, visible, enabled,
    outside: node => !!node && node.nodeType === 1 && !node.closest(boundary),
    namedGroup: node => !!node && node.nodeType === 1 && !node.closest(boundary) && labelledGroup(node),
    labelledGroup,
    modeControl: (node, trackedGroup = false) => !!node && node.nodeType === 1 && (trackedGroup || !node.closest(boundary)) && label(node) === 'Work'
      && (node.tagName.toLowerCase() === 'button' || ['button', 'radio', 'switch', 'checkbox'].includes(node.getAttribute('role'))) };
}
function chatGPTProductModeDiagnostic(state) {
  const control = node => !node ? null : {
    tag: node.tagName.toLowerCase() === 'button' ? 'button' : 'other',
    role: ['button', 'radio', 'switch', 'checkbox'].includes(node.getAttribute('role')) ? node.getAttribute('role') : null,
    pressed: ['true', 'false', 'mixed'].includes(node.getAttribute('aria-pressed')) ? node.getAttribute('aria-pressed') : null,
    checked: ['true', 'false', 'mixed'].includes(node.getAttribute('aria-checked')) ? node.getAttribute('aria-checked') : null,
    visible: state.visible(node), enabled: state.enabled(node) };
  return { kind: 'chatgpt_product_mode_structure', groupCount: Math.min(state.groups.length, 16),
    groupVisible: state.visible(state.group), recognized: state.recognized, contradictory: state.contradictory,
    chat: control(state.chat), work: control(state.work),
    proofPresent: !!globalThis.__computaChatProductMode, proofInvalidated: globalThis.__computaChatProductMode?.invalidated === true,
    chatClickClaimed: globalThis.__computaChatModeClickClaimed === true,
    ...chatGPTProductProofFailureDiagnostic() };
}
function chatGPTProductProofFailureDiagnostic() {
  const proof = globalThis.__computaChatProductMode;
  const reasons = ['work_selected', 'mutation_overflow', 'group_overflow', 'work_overflow', 'contradictory_controls',
    'owner', 'document', 'frame', 'origin', 'route', 'not_ready', 'temporary_unclaimed'];
  if (!proof?.invalidated || !reasons.includes(proof.invalidationReason)) return {};
  const diagnostic = { productProofFailure: proof.invalidationReason };
  for (const key of ['productMutationRelevantCount', 'productMutationIgnoredCount'])
    if (Number.isInteger(proof[key]) && proof[key] >= 0) diagnostic[key] = Math.min(proof[key], 1_000);
  return diagnostic;
}
function chatGPTInvalidateProductProof(proof, reason, counts = null) {
  if (!proof.invalidated) {
    proof.invalidationReason = reason;
    if (counts) {
      proof.productMutationRelevantCount = Math.min(counts.relevant, 1_000);
      proof.productMutationIgnoredCount = Math.min(counts.ignored, 1_000);
    }
  }
  proof.invalidated = true;
  return null;
}
function chatGPTControlExposed(node) {
  if (!node || typeof node.getBoundingClientRect !== 'function' || typeof document.elementFromPoint !== 'function') return false;
  const rect = node.getBoundingClientRect();
  if (![rect.left, rect.top, rect.width, rect.height].every(Number.isFinite) || rect.width <= 0 || rect.height <= 0) return false;
  const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
  if (x < 0 || y < 0 || Number.isFinite(window.innerWidth) && x >= window.innerWidth
    || Number.isFinite(window.innerHeight) && y >= window.innerHeight || getComputedStyle(node).pointerEvents === 'none') return false;
  const hit = document.elementFromPoint(x, y);
  return hit === node || !!hit && node.contains(hit);
}
function chatGPTObserveProductMutations(proof, state, records) {
  if (proof.invalidated) return;
  const groups = proof.groups, works = proof.works;
  // Rendering a conversation is not a product-mode event. Tracked product
  // nodes take precedence even after moving into a message or detaching.
  const messageBoundary = '[data-message-author-role="user"], [data-message-author-role="assistant"], '
    + '[data-markdown-text-style="user-message"], [data-markdown-text-style="assistant-message"], '
    + 'article[data-turn="user"], article[data-turn="assistant"], [data-user-message-bubble]';
  const tracked = [...groups, ...works];
  const touchesTracked = node => !!node && tracked.some(control => control === node
    || control.contains(node) || node.contains?.(control));
  const containsGroup = node => {
    if (node?.nodeType !== 1) return false;
    const candidates = [node, ...node.querySelectorAll('[aria-label], [aria-labelledby]')];
    return candidates.length > 128 || candidates.some(candidate => state.labelledGroup(candidate));
  };
  const messageOnly = record => {
    // State transitions stay relevant until structural records establish which
    // controls belonged to a tracked group earlier in this mutation batch.
    if (record.type === 'attributes' && ['aria-pressed', 'aria-checked'].includes(record.attributeName)) return false;
    const element = record.target?.nodeType === 1 ? record.target : record.target?.parentElement;
    if (!element?.closest(messageBoundary) || touchesTracked(record.target)) return false;
    // A new/moved product group in a message is still relevant to provenance.
    for (let node = element; node; node = node.parentElement) if (state.labelledGroup(node)) return false;
    if (record.type === 'attributes' && record.attributeName === 'aria-label' && record.oldValue === 'Composer mode') return false;
    return [...(record.addedNodes || []), ...(record.removedNodes || [])]
      .every(node => !touchesTracked(node) && !containsGroup(node));
  };
  const relevant = [];
  let ignored = 0;
  // Counts describe the examined prefix, stopping at the first over-budget
  // relevant record. Unrelated message rendering does not consume that budget.
  for (const record of records) {
    if (messageOnly(record)) ignored++;
    else relevant.push(record);
    if (relevant.length > 512) break;
  }
  const counts = { relevant: relevant.length, ignored };
  const invalidate = reason => chatGPTInvalidateProductProof(proof, reason, counts);
  const trackWork = (node, observedInTrackedGroup = false) => {
    const trackedGroup = observedInTrackedGroup || works.has(node) || [...groups].some(group => group.contains(node));
    if (!state.modeControl(node, trackedGroup)) return;
    works.add(node);
    if (node.getAttribute('aria-pressed') === 'true' || node.getAttribute('aria-checked') === 'true') invalidate('work_selected');
  };
  const register = (node, allowNewGroups) => {
    if (!node || node.nodeType !== 1) return;
    const candidates = [node, ...node.querySelectorAll('[aria-label], [aria-labelledby]')].slice(0, 128);
    for (const candidate of candidates) if (allowNewGroups && state.namedGroup(candidate)) groups.add(candidate);
    const owned = groups.has(node) || [...groups].some(group => group.contains(node));
    if (owned) for (const candidate of [node, ...node.querySelectorAll('button, [role="button"], [role="radio"], [role="switch"], [role="checkbox"]')].slice(0, 128))
      trackWork(candidate);
  };
  if (state.group) groups.add(state.group);
  if (state.work) trackWork(state.work);
  // Process structural provenance before attribute records. A control can be
  // mounted, switched to Work, switched back and detached within one batch.
  for (const record of relevant.slice(0, 512)) if (record.type === 'childList') {
    // A detached group authored in a message cannot become trusted just
    // because its final ancestry no longer contains that message boundary.
    const allowNewGroups = state.outside(record.target);
    register(record.target, allowNewGroups);
    const ownedTarget = groups.has(record.target) || [...groups].some(group => group.contains(record.target));
    for (const node of [...(record.addedNodes || []), ...(record.removedNodes || [])].slice(0, 128)) {
      register(node, allowNewGroups);
      if (ownedTarget && node?.nodeType === 1) for (const candidate of [node,
        ...node.querySelectorAll('button, [role="button"], [role="radio"], [role="switch"], [role="checkbox"]')].slice(0, 128))
        trackWork(candidate, true);
    }
  }
  if (groups.size > 64) { invalidate('group_overflow'); return; }
  if (works.size > 128) { invalidate('work_overflow'); return; }
  if (relevant.length > 512) { invalidate('mutation_overflow'); return; }
  if (state.contradictory) invalidate('contradictory_controls');
  if (relevant.some(record => record.type === 'attributes'
    && ['aria-pressed', 'aria-checked'].includes(record.attributeName) && record.oldValue === 'true'
    && works.has(record.target))) invalidate('work_selected');
}
function chatGPTProductModeProof() {
  const proof = globalThis.__computaChatProductMode;
  const state = chatGPTProductModeState();
  if (!proof || proof.invalidated) return null;
  if (proof.owner !== globalThis.__computaModelOwner) return chatGPTInvalidateProductProof(proof, 'owner');
  if (proof.document !== document) return chatGPTInvalidateProductProof(proof, 'document');
  if (window !== window.top) return chatGPTInvalidateProductProof(proof, 'frame');
  if (location.origin !== 'https://chatgpt.com') return chatGPTInvalidateProductProof(proof, 'origin');
  if (!/^\/(?:c\/(?:[A-Za-z0-9-]+|local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+)\/?)?$/.test(new URL(document.URL).pathname))
    return chatGPTInvalidateProductProof(proof, 'route');
  if (state.contradictory) return chatGPTInvalidateProductProof(proof, 'contradictory_controls');
  if (!proof.temporaryRequested && (!state.ready || state.chatSelected !== true)) {
    return chatGPTInvalidateProductProof(proof, 'not_ready');
  }
  // Only the private acknowledgement changes between these consecutive
  // checks; reuse this physical observation within this synchronous call.
  const renderedTemporary = chatGPTRenderedTemporary();
  if (proof.temporaryRequested && renderedTemporary) proof.temporaryAcknowledged = true;
  if (renderedTemporary && !proof.temporaryAcknowledged) return null;
  return { product: 'chatgpt', mode: 'chat', source: 'composer_mode_control',
    temporaryTransition: proof.temporaryAcknowledged ? 'acknowledged' : 'not_requested' };
}
function chatGPTTemporaryVerified() {
  return chatGPTRenderedTemporary() && chatGPTProductModeProof()?.temporaryTransition === 'acknowledged';
}
function chatGPTProductModeAction(request) {
  const state = chatGPTProductModeState();
  const reject = () => ({ error: 'product_mode_unverified', productModeDiagnostic: chatGPTProductModeDiagnostic(chatGPTProductModeState()) });
  const fresh = chatGPTMessageRoots('user').length === 0 && chatGPTMessageRoots('assistant').length === 0
    && globalThis.__computaModelFirstSubmitted !== true && !globalThis.__computaModelFirstProof;
  const root = new URL(document.URL).pathname === '/' && !chatGPTRenderedTemporary()
    && new URL(document.URL).searchParams.get('temporary-chat') !== 'true';
  let proof = chatGPTProductModeProof();
  if (!proof && !globalThis.__computaChatProductMode && fresh && root && state.ready && state.chatSelected === true) {
    // Pending mode mutations belong to the pre-proof phase. The next observed
    // mutation can revoke this proof even if Work immediately switches back.
    globalThis.__computaModelSignal?.observer?.takeRecords?.();
    globalThis.__computaChatProductMode = { owner: globalThis.__computaModelOwner, document,
      groups: new Set([state.group]), works: new Set([state.work]), invalidated: false,
      temporaryRequested: false, temporaryAcknowledged: false };
    proof = chatGPTProductModeProof();
  }
  const actionAvailable = !globalThis.__computaChatProductMode && fresh && root && state.ready && state.workSelected === true
    && globalThis.__computaChatModeClickClaimed !== true;
  if (request.action === 'ensureChatMode' && !proof) {
    if (!actionAvailable || !chatGPTControlExposed(state.chat)) return reject();
    globalThis.__computaChatModeClickClaimed = true;
    state.chat.click();
    return { chatModeReady: false, chatModeActionAvailable: false, pending: true };
  }
  if (proof) return { chatModeReady: true, chatModeActionAvailable: false, productModeEvidence: proof };
  if (request.action === 'inspect' && fresh && root && state.ready && state.workSelected === true
    && globalThis.__computaChatModeClickClaimed === true)
    return { chatModeReady: false, chatModeActionAvailable: false, pending: true };
  if (request.action === 'inspect' && fresh && root && actionAvailable)
    return { chatModeReady: false, chatModeActionAvailable: true };
  const disabledControl = node => node.disabled === true || node.getAttribute('aria-disabled') === 'true';
  if (request.action === 'inspect' && fresh && root && !globalThis.__computaChatProductMode
    && globalThis.__computaChatModeClickClaimed !== true && globalThis.__computaModelTemporaryRequested !== true
    && state.recognized && state.visible(state.group) && state.visible(state.chat) && state.visible(state.work)
    && (disabledControl(state.chat) || disabledControl(state.work))) {
    // The signed-in page briefly disables its already recognized Chat/Work
    // pair while hydrating. This is only a bounded native readiness wait;
    // neither provenance nor any click is authorized until both enable.
    return { chatModeReady: false, chatModeActionAvailable: false, chatModeHydrating: true, pending: true };
  }
  if (request.action === 'inspect' && fresh && root && !state.group && !document.querySelectorAll('#prompt-textarea, [contenteditable="true"]').length)
    return { chatModeReady: false, chatModeActionAvailable: false };
  return reject();
}
async function chatGPTGuardedPageAction(request, fingerprint = null) {
  const setupStarted = chatGPTPreparationNow();
  const product = chatGPTProductModeAction(request);
  chatGPTPreparationRecord('guardedSetupMs', setupStarted);
  if (product.error) return product;
  if (['ensureChatMode', 'verifyProductMode'].includes(request.action)) return { ...product, temporary: chatGPTTemporaryVerified() };
  if (!product.chatModeReady && request.action !== 'inspect') return { error: 'product_mode_unverified' };
  if (request.action === 'insert' && (request.submissionSequence != null || request.submissionMarker != null
    || globalThis.__computaChatSubmissionState != null)) {
    const beginStarted = chatGPTPreparationNow();
    let failure;
    try { failure = await chatGPTBeginSubmission(request); }
    finally { chatGPTPreparationRecord('beginSubmissionMs', beginStarted); }
    if (failure) return failure;
  }
  const result = await providerPageAction(request, fingerprint);
  chatGPTPreparationRecord('providerReturnMs', chatGPTProviderReturnStarted);
  const finalizationStarted = chatGPTPreparationNow();
  if (result.error) return result;
  const finalProduct = chatGPTProductModeAction({ ...request, action: 'verifyProductMode' });
  if (finalProduct.error && product.chatModeReady) return finalProduct;
  const finalized = { ...result, ...(finalProduct.error ? product : finalProduct), temporary: chatGPTTemporaryVerified() };
  chatGPTPreparationRecord('guardedFinalizationMs', finalizationStarted);
  return finalized;
}
function chatGPTStructure(visible) {
  const buttons = [...document.querySelectorAll('button')].filter(visible).filter(button =>
    ['Copy', 'Copy message'].includes(button.getAttribute('aria-label') || (button.textContent || '').trim()))
    .sort((a, b) => Number(a.getAttribute('aria-label') === 'Copy message') - Number(b.getAttribute('aria-label') === 'Copy message')).slice(0, 3);
  // Preserve the one diagnostic receipt until the assistant footer exists.
  if (!buttons.some(button => !button.disabled && button.getAttribute('aria-disabled') !== 'true'
    && (button.getAttribute('aria-label') || (button.textContent || '').trim()) === 'Copy')) return '';
  const safeRoles = ['article', 'button', 'group', 'main', 'textbox', 'list', 'listitem', 'presentation', 'none'];
  const ancestorsOf = start => {
    const ancestors = [];
    for (let node = start, depth = 0; node && depth < 20; node = node.parentElement, depth++) {
      const role = node.getAttribute('role'), turn = node.getAttribute('data-turn');
      const author = node.getAttribute('data-message-author-role'), style = node.getAttribute('data-markdown-text-style');
      const testId = node.getAttribute('data-testid');
      const metadata = { tag: /^[a-zA-Z0-9-]{1,24}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'other',
        ...(safeRoles.includes(role) ? { role } : {}),
        ...(turn ? { turn: ['user', 'assistant'].includes(turn) ? turn : 'other' } : {}),
        ...(author ? { author: ['user', 'assistant'].includes(author) ? author : 'other' } : {}),
        ...(style ? { style: ['user-message', 'assistant-message'].includes(style) ? style : 'other' } : {}),
        ...(testId && /^[a-z0-9_-]{1,64}$/.test(testId) ? { testId } : {}),
        dataAttributes: [...node.attributes].map(attribute => attribute.name)
          .filter(name => /^data-[a-z0-9_-]{1,32}$/.test(name)).sort().slice(0, 8) };
      if (metadata.dataAttributes.length || role || turn || author || style || testId) ancestors.push(metadata);
    }
    return ancestors;
  };
  const replyBodies = [];
  if (typeof document.createTreeWalker === 'function') {
    const walker = document.createTreeWalker(document.body, 4);
    for (let textNode = walker.nextNode(); textNode; textNode = walker.nextNode()) {
      const text = (textNode.nodeValue || '').trim();
      const parent = textNode.parentElement;
      if (!parent || parent.closest('[data-user-message-bubble]') || text.length > 220_000 || !text.startsWith('{')) continue;
      let value; try { value = JSON.parse(text); } catch { continue; }
      if (!['tool_calls', 'message'].includes(value?.type)) continue;
      const ancestors = [];
      for (let node = parent, depth = 0; node && depth < 6; node = node.parentElement, depth++) {
        ancestors.push({ tag: node.tagName.toLowerCase(),
          classes: [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)).slice(0, 4),
          dataAttributes: [...node.attributes].map(attribute => attribute.name)
            .filter(name => /^data-[a-z0-9_-]{1,32}$/.test(name)).sort().slice(0, 8) });
      }
      replyBodies.push({ kind: value.type, ancestors });
      break;
    }
  }
  const structure = { bodies: replyBodies,
    copies: buttons.slice(0, 1).map(button => ({ kind: 'response_copy', ancestors: ancestorsOf(button) })),
    articleCount: document.querySelectorAll('article').length,
    articleUsers: document.querySelectorAll('article[data-turn="user"]').length,
    articleAssistants: document.querySelectorAll('article[data-turn="assistant"]').length,
    markdownBodies: document.querySelectorAll('.markdown').length,
    preservedUserBodies: document.querySelectorAll('.whitespace-pre-wrap').length };
  // Always emit complete JSON, reducing only diagnostic ancestry if necessary.
  let serialized = JSON.stringify(structure);
  while (serialized.length > 8192) {
    const longest = [...structure.copies, ...structure.bodies].sort((a, b) => b.ancestors.length - a.ancestors.length)[0];
    if (!longest?.ancestors.length) return '';
    longest.ancestors.pop();
    serialized = JSON.stringify(structure);
  }
  return serialized;
}
function chatGPTAlertAsideLoadFailed(retry, main, visible) {
  const alert = retry.closest('aside');
  if (!alert || alert.getAttribute('role') !== 'alert' || !main || alert.closest('main') !== main
    || !visible(alert) || !visible(retry) || retry.disabled || retry.getAttribute('aria-disabled') === 'true'
    || alert.parentElement?.closest('aside')) return false;
  const protectedContent = '[data-message-author-role], [data-markdown-text-style], article[data-turn], [data-user-message-bubble], .markdown, pre, code, #prompt-textarea, [contenteditable], textarea, [role="menu"], [role="menubar"], [role="navigation"], [role="complementary"], nav';
  if (alert.closest(protectedContent) || alert.querySelector(protectedContent)) return false;
  const controlRoles = new Set(['button', 'checkbox', 'combobox', 'grid', 'gridcell', 'link', 'listbox',
    'menu', 'menubar', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'radiogroup',
    'scrollbar', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'tablist', 'textbox', 'toolbar',
    'tree', 'treegrid', 'treeitem', 'navigation', 'complementary']);
  const controlTags = new Set(['BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'SUMMARY', 'DETAILS', 'AUDIO', 'VIDEO', 'IFRAME', 'OBJECT', 'EMBED']);
  let ancestors = 0;
  for (let node = alert; node; node = node.parentElement) {
    if (++ancestors > 64 || (node.getAttribute('role') || '').trim().split(/\s+/).some(role => controlRoles.has(role))
      || controlTags.has(node.tagName) || node.getAttribute('contenteditable') !== null
      || (['A', 'AREA'].includes(node.tagName) && node.getAttribute('href') !== null)
      || (node.tagName === 'LABEL' && node.getAttribute('for') !== null)) return false;
  }
  // This is one finite semantic error widget, not a broad ancestor text search.
  // Visit all nodes, including hidden/empty branches, before accepting its label.
  const inertTags = new Set(['DIV', 'SPAN', 'P', 'STRONG', 'EM', 'B', 'I', 'SMALL']);
  const stack = [{ node: alert, depth: 0, inRetry: false }];
  let visited = 0, errorText = '', retryText = '';
  while (stack.length) {
    const { node, depth, inRetry } = stack.pop();
    if (++visited > 128 || depth > 16) return false;
    if (node.nodeType === 8) continue;
    if (node.nodeType === 3) {
      const text = node.textContent || '';
      if (text.length > 128 || text.trim() && !visible(node.parentElement)) return false;
      if (inRetry) retryText += text; else errorText += text;
      if (errorText.length > 128 || retryText.length > 128) return false;
      continue;
    }
    if (node.nodeType !== 1 || node !== alert && node !== retry && !inertTags.has(node.tagName)
      || node.getAttribute('contenteditable') !== null || node !== retry && node.getAttribute('tabindex') !== null) return false;
    const role = node.getAttribute('role');
    if (node !== alert && role !== null && ![node === retry ? 'button' : 'none', 'presentation'].includes(role)) return false;
    const children = [...node.childNodes];
    if (children.length > 128 || stack.length + children.length > 128) return false;
    for (let index = children.length - 1; index >= 0; index--)
      stack.push({ node: children[index], depth: depth + 1, inRetry: inRetry || node === retry });
  }
  return errorText.replace(/\s+/g, ' ').trim() === 'Load failed'
    && retryText.replace(/\s+/g, ' ').trim() === 'Retry';
}
// One invocation only; DOM references never enter the diagnostic projection.
let chatGPTInlineRendererState = null;
function chatGPTInlineRendererLoadFailed(visible) {
  const report = { reason: 'not_evaluated', subject: 'none', visitedNodeCount: 0,
    rawKnownLabel: null, trimmedKnownLabel: null, guardBodyIsExtractedAnswer: null,
    bodyIsRoot: null, knownScopedCopyOutsideDIL: null, rejectedDisplayContents: null };
  const state = { report, root: null, body: null, dil: null, portal: null };
  chatGPTInlineRendererState = state;
  const subject = node => {
    if (!node) return 'none';
    if (node === state.body) return 'body';
    if (node === state.root) return 'root';
    if (node.nodeType === 3) return 'text_leaf';
    try {
      const names = [];
      for (const name of node.classList || []) {
        if (names.length >= 16 || name.length > 64) return 'other';
        names.push(name);
      }
      const has = prefix => names.some(name => name.startsWith(prefix) && /^[A-Za-z0-9_-]{1,48}$/.test(name.slice(prefix.length)));
      if (has('DilRenderer-') && has('DilResponseRoot-')) return 'dil_pair';
      if (has('PortalBoundary-') && has('Renderer-')) return 'portal_pair';
    } catch { /* Diagnostic classification cannot change the original result. */ }
    return 'other';
  };
  const finish = (matched, reason, node = null) => {
    report.reason = reason; report.subject = subject(node);
    if (['root_not_visible', 'body_not_visible', 'node_not_visible', 'text_not_visible'].includes(reason)) {
      try {
        const style = getComputedStyle(node);
        if (typeof style.display === 'string') report.rejectedDisplayContents = style.display === 'contents';
      } catch { /* Unknown layout remains unknown. */ }
    }
    return matched;
  };
  // These finite facts explain the first decline. Only the exact visible
  // component/label conjunction below can establish this abort-only status.
  const root = chatGPTMessageRoots('assistant').at(-1); state.root = root || null;
  if (!root) return finish(false, 'root_missing');
  if (!visible(root)) return finish(false, 'root_not_visible', root);
  const foreignMessage = node => {
    const author = node.getAttribute('data-message-author-role'), turn = node.getAttribute('data-turn');
    const style = node.getAttribute('data-markdown-text-style');
    return author !== null && author !== 'assistant' || turn !== null && turn !== 'assistant'
      || style !== null && style !== 'assistant-message';
  };
  let inConversation = false;
  for (let node = root, depth = 0; node; node = node.parentElement) {
    if (++depth > 64) return finish(false, 'ancestor_budget', node);
    if (['PRE', 'CODE', 'BLOCKQUOTE', 'NAV', 'ASIDE', 'TEXTAREA'].includes(node.tagName)
      || ['menu', 'dialog'].includes(node.getAttribute('role')) || node.getAttribute('contenteditable') !== null
      || node.getAttribute('id') === 'prompt-textarea' || node.getAttribute('data-user-message-bubble') !== null)
      return finish(false, 'ancestor_excluded', node);
    if (foreignMessage(node)) return finish(false, 'ancestor_foreign_message', node);
    if (node.tagName === 'MAIN') { inConversation = true; break; }
  }
  if (!inConversation) return finish(false, 'conversation_boundary_missing', root);
  const body = root.getAttribute('data-markdown-text-style') === 'assistant-message' ? root
    : root.querySelector('[data-markdown-text-style="assistant-message"]') || root.querySelector('.markdown')
      || root.querySelector('[data-message-author-role="assistant"]')
      || (root.getAttribute('data-message-author-role') === 'assistant' ? root : null);
  state.body = body || null; report.bodyIsRoot = body ? body === root : null;
  if (!body) return finish(false, 'body_missing');
  if (!visible(body)) return finish(false, 'body_not_visible', body);
  if (!root.contains(body)) return finish(false, 'body_outside_root', body);
  for (let node = body, depth = 0; node; node = node.parentElement) {
    if (++depth > 16) return finish(false, 'body_ancestor_budget', node);
    if (['PRE', 'CODE', 'BLOCKQUOTE'].includes(node.tagName) || node.classList.contains('markdown'))
      return finish(false, 'body_quote_or_markdown', node);
    if (foreignMessage(node)) return finish(false, 'body_foreign_message', node);
    if (node === root) break;
  }
  const pairs = { dil: [], portal: [] }, stack = [{ node: body, depth: 0 }];
  let visited = 0, textParent = null;
  while (stack.length) {
    const { node, depth, emptyOnly = false } = stack.pop();
    report.visitedNodeCount = Math.min(++visited, 65);
    if (visited > 64) return finish(false, 'node_budget', node);
    if (depth > 8) return finish(false, 'tree_depth', node);
    if (node.nodeType === 8) {
      if (emptyOnly && (node.textContent || '') !== '') return finish(false, 'node_not_visible', node.parentElement);
      continue;
    }
    if (node.nodeType === 3) {
      const text = node.textContent || '';
      // A hidden decoration is exempt only after its entire bounded subtree
      // proves empty. Even whitespace or a hidden quoted label is unknown.
      if (emptyOnly) {
        if (text !== '') return finish(false, 'node_not_visible', node.parentElement);
        continue;
      }
      if (text.length > 128) {
        if (report.rawKnownLabel === null) report.rawKnownLabel = false;
        return finish(false, 'text_budget', node);
      }
      if (text.trim()) {
        // These flags describe the first examined nonempty leaf, not a scan
        // of arbitrary response text. Unexamined values remain null.
        if (report.rawKnownLabel === null) {
          report.rawKnownLabel = text === 'This response couldn’t load';
          report.trimmedKnownLabel = text.trim() === 'This response couldn’t load';
        }
        if (textParent) return finish(false, 'multiple_text_leaves', node);
        if (text !== 'This response couldn’t load') return finish(false, 'raw_label_differs', node);
        if (!visible(node.parentElement)) return finish(false, 'text_not_visible', node.parentElement);
        textParent = node.parentElement;
      }
      continue;
    }
    if (node.nodeType !== 1) return finish(false, 'non_element', node);
    if (node.tagName !== 'DIV') return finish(false, 'non_div_element', node);
    const nodeVisible = visible(node), emptySubtree = emptyOnly || !nodeVisible;
    if (emptySubtree) {
      // Missing layout boxes do not prove that descendants are empty.
      // Inspect every child under the original shared limits, and refuse
      // display:contents or generated CSS text rather than skipping either.
      let display;
      try { display = getComputedStyle(node).display; } catch { return finish(false, 'node_not_visible', node); }
      if (!node.isConnected || typeof display !== 'string' || display === 'contents')
        return finish(false, 'node_not_visible', node);
      for (const pseudo of ['::before', '::after']) {
        let content;
        try { content = getComputedStyle(node, pseudo).content; } catch { return finish(false, 'node_not_visible', node); }
        if (!['none', 'normal', '""', "''"].includes(content)) return finish(false, 'node_not_visible', node);
      }
      // This abort-only check never interprets DIV annotations as response,
      // ownership or action authority. Unknown metadata cannot hide its error.
    }
    if (node.getAttribute('contenteditable') !== null) return finish(false, 'interactive_metadata', node);
    if (node.classList.contains('markdown')) return finish(false, 'markdown_content', node);
    if (node !== body && (node.getAttribute('data-markdown-text-style') !== null
      || node.getAttribute('data-message-author-role') !== null || node.getAttribute('data-turn') !== null
      || node.getAttribute('data-user-message-bubble') !== null))
      return finish(false, 'nested_message', node);
    const classes = [];
    for (const name of node.classList) {
      if (classes.length >= 16 || name.length > 64) return finish(false, 'class_budget', node);
      classes.push(name);
    }
    const has = prefix => classes.some(name => name.startsWith(prefix) && /^[A-Za-z0-9_-]{1,48}$/.test(name.slice(prefix.length)));
    if (emptySubtree && classes.some(name => ['DilRenderer-', 'DilResponseRoot-', 'PortalBoundary-', 'Renderer-']
      .some(prefix => name.startsWith(prefix)))) return finish(false, 'node_not_visible', node);
    if (classes.some(name => name.startsWith('DilRenderer-') || name.startsWith('DilResponseRoot-'))) {
      if (!has('DilRenderer-') || !has('DilResponseRoot-')) return finish(false, 'dil_pair_incomplete', node);
      if (pairs.dil.length) { state.dil = null; return finish(false, 'dil_pair_multiple', node); }
      pairs.dil.push(node); state.dil = node;
    }
    if (classes.some(name => name.startsWith('PortalBoundary-') || name.startsWith('Renderer-'))) {
      if (!has('PortalBoundary-') || !has('Renderer-')) return finish(false, 'portal_pair_incomplete', node);
      if (pairs.portal.length) { state.portal = null; return finish(false, 'portal_pair_multiple', node); }
      pairs.portal.push(node); state.portal = node;
    }
    const children = node.childNodes;
    if (children.length > 32 || stack.length + children.length > 64) return finish(false, 'children_budget', node);
    for (let index = children.length - 1; index >= 0; index--)
      stack.push({ node: children[index], depth: depth + 1, emptyOnly: emptySubtree });
  }
  const dil = pairs.dil[0], portal = pairs.portal[0];
  if (textParent) for (const _ of textParent.classList) return finish(false, 'leaf_classed', textParent);
  if (pairs.dil.length !== 1 || pairs.portal.length !== 1) return finish(false, 'components_missing', body);
  if (!textParent) return finish(false, 'label_missing', body);
  if (dil.parentElement !== portal) return finish(false, 'portal_not_direct_parent', dil);
  if (textParent.parentElement !== dil) return finish(false, 'leaf_not_direct_child', textParent);
  if (textParent.childElementCount !== 0) return finish(false, 'leaf_has_elements', textParent);
  if (dil.childElementCount !== 1) return finish(false, 'dil_has_other_children', dil);
  if (!body.contains(portal) || !portal.contains(dil)) return finish(false, 'component_scope_changed', body);
  return finish(true, 'matched', textParent);
}
function chatGPTInlineRendererGuardStructure(answer, enabledScopedCopies) {
  const state = chatGPTInlineRendererState;
  if (!state) return null;
  const sameBody = state.body ? state.body === answer : null;
  const knownDIL = sameBody === true && state.dil && state.portal && state.dil.parentElement === state.portal
    && state.body.contains(state.portal) && state.portal.contains(state.dil);
  return { ...state.report, guardBodyIsExtractedAnswer: sameBody,
    knownScopedCopyOutsideDIL: knownDIL ? enabledScopedCopies.some(copy => !state.dil.contains(copy)) : null };
}
function chatGPTResponseLoadFailed(visible) {
  if (chatGPTInlineRendererLoadFailed(visible)) return true;
  // Abort-only website error evidence from this admitted read. A single small
  // direct widget can use plain text or nested labels, including in a dialog.
  // Never widen the search to main or another ancestor, accept an answer, or Retry.
  const protectedContent = '[data-message-author-role], [data-markdown-text-style], article[data-turn], [data-user-message-bubble], .markdown, pre, code, #prompt-textarea, [contenteditable], textarea, [role="menu"], [role="menubar"], [role="navigation"], [role="complementary"], nav, aside';
  const retries = [...document.querySelectorAll('main button')].filter(node => visible(node)
    && (node.getAttribute('aria-label') || node.innerText || '').trim() === 'Retry');
  if (retries.length !== 1) return false;
  const retry = retries[0], region = retry.parentElement, main = retry.closest('main');
  if (chatGPTAlertAsideLoadFailed(retry, main, visible)) return true;
  if (retry.disabled || retry.getAttribute('aria-disabled') === 'true' || retry.closest(protectedContent)
    || !region || !main || region === main || !visible(region)
    || ['MAIN', 'BODY', 'HTML'].includes(region.tagName) || region.closest('main') !== main
    || region.childElementCount > 4 || region.querySelectorAll('*').length > 128
    || region.querySelector(protectedContent + ', input, select, a[href], [role="dialog"], dialog')) return false;
  const buttons = [...region.querySelectorAll('button')].filter(visible);
  if (buttons.length !== 1 || buttons[0] !== retry) return false;
  const interactiveRoles = new Set(['button', 'checkbox', 'combobox', 'grid', 'gridcell', 'link', 'listbox',
    'menu', 'menubar', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'radiogroup',
    'scrollbar', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'tablist', 'textbox', 'toolbar',
    'tree', 'treegrid', 'treeitem', 'navigation', 'complementary']);
  const nonLabelControl = (node, labelBranch = true) => (node.getAttribute('role') || '').trim().split(/\s+/).some(role => interactiveRoles.has(role))
    || (labelBranch && node.getAttribute('tabindex') !== null) || node.getAttribute('contenteditable') !== null
    || ['BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'SUMMARY', 'DETAILS', 'AUDIO', 'VIDEO', 'IFRAME', 'OBJECT', 'EMBED'].includes(node.tagName)
    || (['A', 'AREA'].includes(node.tagName) && node.getAttribute('href') !== null)
    || (node.tagName === 'LABEL' && node.getAttribute('for') !== null);
  for (let ancestor = region; ancestor; ancestor = ancestor.parentElement) {
    if (nonLabelControl(ancestor, false)) return false;
    if (ancestor === main) break;
  }
  let knownLabels = 0;
  for (const node of region.childNodes) {
    if (node === retry || node.nodeType === 8) continue;
    if (node.nodeType !== 1 && node.nodeType !== 3) return false;
    if (node.nodeType === 1 && !visible(node)) continue;
    if (node.nodeType === 1 && [node, ...node.querySelectorAll('*')].some(child => nonLabelControl(child))) return false;
    if (node.nodeType === 1 && [...node.querySelectorAll('*')].some(child => !visible(child) && (child.textContent || '').trim())) return false;
    const text = node.textContent || '';
    if (text.length > 128) return false;
    const label = text.replace(/\s+/g, ' ').trim();
    if (!label) continue;
    if (label !== 'Load failed') return false;
    knownLabels += 1;
  }
  return knownLabels === 1;
}
// Diagnostic relationship facts only. This never classifies a response as failed,
// changes readiness/ownership, clicks Retry or supplies completion evidence.
function chatGPTResponseNoticeDiagnostic(visible) {
  const contentSelector = '[data-message-author-role], [data-markdown-text-style], article[data-turn], [data-user-message-bubble], .markdown, pre, code, #prompt-textarea, [contenteditable="true"], textarea';
  const contentExcluded = node => !!node.closest(contentSelector);
  const labelExcluded = node => contentExcluded(node) || !!node.closest('[role="menu"], nav, aside')
    || !!node.querySelector(contentSelector + ', [role="menu"], nav, aside');
  const excludedAncestor = node => {
    // An inner dialog cannot hide any enclosing navigation/menu boundary.
    const blocked = node.closest('[role="menu"], nav, aside');
    if (blocked) return blocked.getAttribute('role') === 'menu' ? 'menu' : blocked.tagName === 'NAV' ? 'nav' : 'aside';
    return node.closest('[role="dialog"]') ? 'dialog' : 'none';
  };
  const smallWidget = (region, retry, main) => !!region && region !== main
    && !['MAIN', 'BODY', 'HTML'].includes(region.tagName) && region.childElementCount <= 4
    && region.closest('main') === main && visible(region)
    && !region.querySelector(contentSelector + ', input, select, [role="menu"], nav, aside')
    && [...region.querySelectorAll('button')].filter(visible).length === 1
    && [...region.querySelectorAll('button')].filter(visible)[0] === retry;
  const retries = [...document.querySelectorAll('main button')].filter(node => visible(node)
    && (node.getAttribute('aria-label') || node.innerText || '').trim() === 'Retry').slice(0, 10_001);
  const observations = retries.slice(0, 2).map(retry => {
    const excluded = contentExcluded(retry), ancestor = excludedAncestor(retry), main = retry.closest('main');
    const base = { excludedAncestor: ancestor, contentExcluded: excluded,
      retryEnabled: !retry.disabled && retry.getAttribute('aria-disabled') !== 'true',
      noticeRole: 'none', pairing: 'none', sameWidget: false,
      knownError: 'none', labelStructure: 'none', labelScanTruncated: false };
    // Payloads and navigation/menu controls cannot become provider-status facts.
    // Dialog ancestry is observed only; it does not relax response error policy.
    if (excluded || ['menu', 'nav', 'aside'].includes(ancestor) || !main) return base;
    let notice = retry.closest('[role="alert"], [role="status"]');
    if (notice && (!visible(notice) || contentExcluded(notice) || notice.closest('main') !== main)) notice = null;
    if (notice) {
      if (notice === main) return base;
      // Semantic status ancestry alone does not bind two unrelated branches.
      if (retry.parentElement !== notice || !smallWidget(notice, retry, main)
        || notice.querySelector('[role="alert"], [role="status"]')) return { ...base, pairing: 'ambiguous' };
      base.pairing = 'ancestor';
    } else {
      const parent = retry.parentElement;
      if (!smallWidget(parent, retry, main)) return base;
      const notices = [...parent.querySelectorAll('[role="alert"], [role="status"]')]
        .filter(node => node.parentElement === parent && visible(node) && !contentExcluded(node));
      if (notices.length > 1) return { ...base, pairing: 'ambiguous' };
      if (notices.length !== 1) return base;
      notice = notices[0]; base.pairing = 'shared_parent';
    }
    const candidates = [notice, ...notice.querySelectorAll('span, p, div')];
    const scanned = candidates.slice(0, 128);
    const matches = scanned.filter(node => visible(node) && !labelExcluded(node)
      && (node.textContent || '').length <= 128 && (node.textContent || '').replace(/\s+/g, ' ').trim() === 'Load failed');
    const physical = matches.filter(node => !matches.some(other => other !== node && node.contains(other)));
    const truncated = candidates.length > 128;
    return { ...base, noticeRole: notice.getAttribute('role'), sameWidget: true,
      knownError: !truncated && physical.length ? 'load_failed' : 'unknown',
      labelStructure: truncated || !physical.length ? 'none' : physical.length > 1 ? 'multiple'
        : physical[0].childElementCount ? 'nested' : 'leaf', labelScanTruncated: truncated };
  });
  return { kind: 'chatgpt_response_notice_v1', retryCount: Math.min(10_000, retries.length),
    observationsTruncated: retries.length > 2, observations };
}
function chatGPTResourceTimingDiagnostic(phase) {
  // Resource entries are observations of ended fetches, not upload sizes or
  // dispatch/acceptance proof. Missing entries remain explicitly inconclusive.
  try {
    const claim = globalThis.__computaChatResourceTimingClaim;
    if (!claim || claim.document !== document || claim.owner !== input.ownerToken
      || globalThis.__computaModelOwner !== input.ownerToken
      || claim.userCount !== globalThis.__computaModelLastSubmissionCount
      || !Number.isInteger(claim.sequence) || claim.sequence !== claim.userCount + 1
      || claim.sequence < 1 || claim.sequence > 10_000) return null;
    const result = { kind: 'chatgpt_resource_timing_v2', phase, sequence: claim.sequence,
      available: false, sendMarkAvailable: false, scanTruncated: false, scannedCount: 0,
      conversationCount: 0, preparationCount: 0, observations: [], observationsTruncated: false,
      absenceInconclusive: true };
    const timing = window.performance;
    if (!timing || typeof timing.now !== 'function' || typeof timing.getEntriesByType !== 'function') return result;
    const now = timing.now();
    if (!Number.isFinite(now) || now < 0) return result;
    result.available = true;
    if (!Number.isFinite(claim.mark) || claim.mark < 0 || claim.mark > now) return result;
    result.sendMarkAvailable = true;
    const entries = timing.getEntriesByType('resource');
    if (!Array.isArray(entries)) { result.available = false; return result; }
    result.scanTruncated = entries.length > 256;
    const scanned = entries.slice(-256); result.scannedCount = scanned.length;
    const byteCount = value => typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 2_147_483_647;
    for (const entry of scanned) {
      if (!entry || typeof entry.name !== 'string' || entry.name.length > 2_048
        || !Number.isFinite(entry.startTime) || entry.startTime < claim.mark || entry.startTime > now
        || !Number.isFinite(entry.responseEnd) || entry.responseEnd <= 0
        || entry.responseEnd < entry.startTime || entry.responseEnd > now
        || !Number.isFinite(entry.duration) || entry.duration < 0 || entry.duration > 3_600_000
        || entry.startTime - claim.mark > 3_600_000
        || !byteCount(entry.transferSize) || !byteCount(entry.encodedBodySize) || !byteCount(entry.decodedBodySize)) continue;
      let endpoint;
      try {
        const url = new URL(entry.name);
        if (url.origin !== 'https://chatgpt.com' || url.username || url.password) continue;
        endpoint = url.pathname === '/backend-api/f/conversation' ? 'conversation'
          : url.pathname === '/backend-api/f/conversation/prepare' ? 'preparation' : null;
      } catch { continue; }
      if (!endpoint) continue;
      const responseStatusAvailable = typeof entry.responseStatus === 'number';
      if (responseStatusAvailable && (!Number.isInteger(entry.responseStatus) || entry.responseStatus < 0 || entry.responseStatus > 599)) continue;
      // Public Resource Timing values may be absent or zero when unavailable.
      // Keep unknown distinct from zero and never infer headers from duration.
      const offset = value => typeof value === 'number' && Number.isFinite(value) && value > 0
        && value >= entry.startTime && value <= entry.responseEnd && value - claim.mark <= 3_600_000
        ? Math.floor(value - claim.mark) : null;
      let requestStartOffsetMs = offset(entry.requestStart), responseStartOffsetMs = offset(entry.responseStart);
      if (requestStartOffsetMs !== null && responseStartOffsetMs !== null && entry.requestStart > entry.responseStart) {
        requestStartOffsetMs = null; responseStartOffsetMs = null;
      }
      const responseEndOffsetMs = offset(entry.responseEnd);
      if (endpoint === 'conversation') result.conversationCount++; else result.preparationCount++;
      result.observations.push({ endpoint,
        initiator: ['fetch', 'xmlhttprequest'].includes(entry.initiatorType) ? entry.initiatorType : 'other',
        startOffsetMs: Math.floor(entry.startTime - claim.mark), durationMs: Math.floor(entry.duration),
        requestStartOffsetMs, responseStartOffsetMs, responseEndOffsetMs,
        transferBytes: entry.transferSize, encodedBodyBytes: entry.encodedBodySize, decodedBodyBytes: entry.decodedBodySize,
        responseStatusAvailable, responseStatus: responseStatusAvailable ? entry.responseStatus : null });
    }
    result.observationsTruncated = result.observations.length > 4;
    result.observations = result.observations.slice(-4);
    return result;
  } catch { return null; }
}
function chatGPTFailedPageDiagnostic() {
  // A deadline observation is deliberately independent of model menus,
  // first-message hashing and response extraction. It reads only this owned
  // document and never grants readiness, completion or cleanup authority.
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
  const nodes = selector => [...document.querySelectorAll(selector)].slice(0, 10_001);
  const roots = selector => {
    const found = nodes(selector).filter(node => node.isConnected);
    const physical = found.filter(node => !found.some(other => other !== node && other.contains(node)));
    return { connected: Math.min(10_000, physical.length), visible: Math.min(10_000, physical.filter(visible).length) };
  };
  const content = node => !!node.closest('[data-message-author-role], [data-markdown-text-style], article[data-turn], [data-user-message-bubble], .markdown, pre, code, #prompt-textarea, [contenteditable="true"], textarea, [role="menu"], [role="dialog"], nav, aside');
  const notices = role => nodes(`main [role="${role}"]`).filter(node => visible(node) && !content(node))
    .filter((node, _, found) => !found.some(other => other !== node && other.contains(node)));
  const alertNodes = notices('alert'), statusNodes = notices('status');
  const lengths = found => found.slice(0, 8).map(node => Math.min(220_001, (node.textContent || '').length));
  const composer = nodes('#prompt-textarea[contenteditable="true"], textarea#prompt-textarea, #prompt-textarea [contenteditable="true"], [contenteditable="true"][aria-label="Ask ChatGPT"], textarea[data-testid="prompt-textarea"]').find(visible);
  const stop = nodes('button[data-testid="stop-button"], button[aria-label="Stop streaming"], button[aria-label="Stop generating"], button[aria-label="Stop"]').find(visible);
  const retries = nodes('main button').filter(node => visible(node)
    && (node.getAttribute('aria-label') || node.innerText || '').trim() === 'Retry');
  const answers = chatGPTMessageRoots('assistant').filter(visible);
  const answer = answers.at(-1);
  const copyScope = chatGPTAnswerCopyScope(answer, answers, chatGPTMessageRoots('user'), visible, enabled);
  const copyPresent = copyScope.copies.length > 0, copyEnabled = copyScope.enabledCopies.length > 0;
  const signIn = !composer && nodes('a, button').some(node => visible(node) && !content(node)
    && /^(?:Log in|Sign in)(?:\s|$)/i.test((node.getAttribute('aria-label') || node.innerText || '').trim()));
  const loadFailed = chatGPTResponseLoadFailed(visible);
  const path = new URL(document.URL).pathname;
  const route = /^\/$/.test(path) ? 'root'
    : /^\/c\/local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+\/?$/.test(path) ? 'local_conversation'
    : /^\/c\/[A-Za-z0-9-]+\/?$/.test(path) ? 'server_conversation' : 'other';
  const temporaryRendered = chatGPTRenderedTemporary(), productProof = globalThis.__computaChatProductMode;
  // Project an already-acknowledged proof without acknowledging a transition
  // or invalidating a latch. Ordinary inference/cleanup still validate it.
  const temporaryVerified = temporaryRendered && route !== 'other'
    && productProof?.owner === input.ownerToken && productProof?.document === document
    && productProof.temporaryRequested === true && productProof.temporaryAcknowledged === true
    && !productProof.invalidated && !chatGPTProductModeState().contradictory;
  const size = globalThis.__computaChatSubmissionSize;
  const sizeCurrent = size?.document === document && size.owner === input.ownerToken
    && size.userCount === globalThis.__computaModelLastSubmissionCount
    && Number.isInteger(size.utf16Count) && size.utf16Count >= 0 && size.utf16Count <= 180_200
    && Number.isInteger(size.utf8Count) && size.utf8Count >= size.utf16Count
    && size.utf8Count <= 720_800 && size.utf8Count <= 3 * size.utf16Count;
  return { kind: 'chatgpt_failed_page_v1', route,
    outboundUTF16Count: sizeCurrent ? size.utf16Count : null,
    outboundUTF8Count: sizeCurrent ? size.utf8Count : null,
    responseNoticeDiagnostic: chatGPTResponseNoticeDiagnostic(visible),
    errorCategory: loadFailed ? 'load_failed' : signIn ? 'sign_in_required'
      : alertNodes.length || statusNodes.length ? 'unrecognized_notice' : 'none',
    modernUsers: roots('[data-markdown-text-style="user-message"]'),
    legacyUsers: roots('[data-message-author-role="user"], article[data-turn="user"], [data-user-message-bubble]'),
    modernAssistants: roots('[data-markdown-text-style="assistant-message"]'),
    legacyAssistants: roots('[data-message-author-role="assistant"], article[data-turn="assistant"]'),
    stopPresent: !!stop, composerPresent: !!composer, composerEnabled: enabled(composer), copyPresent, copyEnabled,
    retryPresent: retries.length > 0,
    retryInsideUserMessage: retries.some(node => !!node.closest('[data-message-author-role="user"], [data-markdown-text-style="user-message"], article[data-turn="user"], [data-user-message-bubble]')),
    retryInsideAssistantMessage: retries.some(node => !!node.closest('[data-message-author-role="assistant"], [data-markdown-text-style="assistant-message"], article[data-turn="assistant"], .markdown')),
    retryInsideCodeOrEditor: retries.some(node => !!node.closest('pre, code, #prompt-textarea, [contenteditable="true"], textarea')),
    retryInsideMenuOrNavigation: retries.some(node => !!node.closest('[role="menu"], [role="dialog"], nav, aside')),
    retryOutsideExcludedContent: retries.some(node => !content(node)),
    temporaryRendered, temporaryVerified,
    alertCount: Math.min(10_000, alertNodes.length), statusCount: Math.min(10_000, statusNodes.length),
    alertTextLengths: lengths(alertNodes), statusTextLengths: lengths(statusNodes),
    noticesTruncated: alertNodes.length > 8 || statusNodes.length > 8 };
}
function chatGPTFreshInstantInsert(request) {
  const state = globalThis.__computaChatSubmissionState, pending = state?.pending;
  return request.prepareFirstInstantInInsert === true && request.action === 'insert'
    && request.expectedModelChoice?.key === 'chat/latest/instant'
    && request.submissionSequence === 1 && request.submissionMarker === request.expectedFirstUserMarker
    && Array.isArray(request.expectedUserCounts) && request.expectedUserCounts.length === 1 && request.expectedUserCounts[0] === 0
    && Array.isArray(request.expectedSubmissionProofs) && request.expectedSubmissionProofs.length === 0
    && request.expectedFirstUserFingerprint == null && request.expectedConversation == null
    && window === window.top && location.origin === 'https://chatgpt.com'
    && document.URL === request.expectedURL && new URL(document.URL).pathname === '/'
    && globalThis.__computaModelOwner === request.ownerToken
    && websiteChatInvocationLease != null && globalThis.__computaChatActiveInvocation === websiteChatInvocationLease
    && globalThis.__computaModelFirstSubmitted !== true && !globalThis.__computaModelFirstProof
    && chatGPTMessageRoots('user').length === 0 && chatGPTMessageRoots('assistant').length === 0
    && state && chatGPTSubmissionContext(state) && state.lastVerified == null
    && pending?.sequence === 1 && pending.marker === request.submissionMarker && pending.phase === 'prepared'
    && pending.root === null && pending.body === null && !pending.expansionAttempted
    && pending.canonical === chatGPTSubmissionCanonical(request.prompt);
}
function chatGPTFirstInstantReadinessFinalGuard(request) {
  // Reuse the existing fresh prepared-submission predicate without performing
  // insertion. Readiness is read-only and its unchanged final guard still
  // proves the current full model before any observation can be admitted.
  return request.firstInstantReadinessFinalGuardOnly === true && request.action === 'sendReady'
    && request.prepareFirstInstantInInsert !== true && request.deferModelVerification !== true
    && chatGPTFreshInstantInsert({ ...request, action: 'insert', prepareFirstInstantInInsert: true });
}
function chatGPTProcessSignalRecords(signal, records) {
  const observerStarted = chatGPTSyncWorkStart();
  try {
    websiteChatObservePinnedMutations(records);
    const productProof = globalThis.__computaChatProductMode;
    const mode = productProof ? chatGPTProductModeState() : null;
    if (productProof) chatGPTObserveProductMutations(productProof, mode, records);
    if (!records.some(record => !websiteModelIgnoreOwnPickerMutation(record))) return;
    if (window !== window.top || location.origin !== 'https://chatgpt.com'
      || globalThis.__computaModelOwner !== signal.ownerToken) return;
  }
  finally { chatGPTSyncWorkEnd(0, observerStarted); }
  // Notification only: draining before input retains the ordinary observer's
  // negative-history processing and native notification semantics.
  try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ ownerToken: signal.ownerToken, kind: 'dom_changed' }); }
  catch { }
}
function chatGPTDrainSignalRecords() {
  const signal = globalThis.__computaModelSignal;
  const records = signal?.observer?.takeRecords?.() || [];
  if (records.length) chatGPTProcessSignalRecords(signal, records);
  return records;
}
function chatGPTFocusModelActivity(records, trigger, previousControls) {
  const controlIDs = new Set([previousControls, trigger.getAttribute('aria-controls'),
    ...records.filter(record => record.type === 'attributes' && record.target === trigger
      && record.attributeName === 'aria-controls').map(record => record.oldValue)]
    .filter(value => typeof value === 'string' && value.length <= 256).flatMap(value => value.split(/\s+/)).filter(Boolean));
  const triggerID = trigger.getAttribute('id');
  const associated = node => node?.nodeType === 1 && node.getAttribute('role') === 'menu'
    && !node.closest('[data-message-author-role], [data-markdown-text-style], [data-turn], [data-user-message-bubble], [role="tooltip"]')
    && (controlIDs.has(node.getAttribute('id')) || typeof triggerID === 'string' && triggerID.length > 0
      && (node.getAttribute('aria-labelledby') || '').split(/\s+/).includes(triggerID));
  return records.some(record => record.type === 'attributes' && record.target === trigger
      && record.attributeName === 'aria-expanded' && (record.oldValue === 'true' || trigger.getAttribute('aria-expanded') === 'true')
    || record.type === 'childList' && [...(record.addedNodes || []), ...(record.removedNodes || [])]
      .some(node => associated(node) || node?.nodeType === 1 && [...node.querySelectorAll('[role="menu"]')].some(associated)));
}
async function providerPageAction(input, readLineageFingerprint = null) {
  const entryStarted = chatGPTPreparationNow();
  websiteModelDiagnosticPhase('page_action');
  const quietCandidate = chatGPTQuietCompletionPrecheck(input);
  if (quietCandidate?.error) return quietCandidate;
  if (quietCandidate === false) input.deferModelVerification = true;
  const modelState = websiteModelPickerState('chatgpt');
  if (['discoverModels', 'selectModel', 'modelDiagnostic'].includes(input.action)) {
    const result = await websiteModelPickerAction(modelState, input, ownedUserCount === 0
      && globalThis.__computaModelFirstSubmitted !== true
      && chatGPTMessageRoots('assistant').length === 0, (requireTemporary = true) => window === window.top
        && input.provider === 'chatgpt' && location.origin === 'https://chatgpt.com'
        && document.URL === input.expectedURL && globalThis.__computaModelOwner === input.ownerToken
        && globalThis.__computaModelFirstSubmitted !== true && !globalThis.__computaModelFirstProof
        && input.expectedFirstUserFingerprint == null && ownedUserCount === 0
        && Array.isArray(input.expectedUserCounts) && input.expectedUserCounts.length === 1 && input.expectedUserCounts[0] === 0
        && chatGPTMessageRoots('user').length === 0 && chatGPTMessageRoots('assistant').length === 0
        && (!requireTemporary || chatGPTTemporaryVerified()));
    return result;
  }
  const focusFirstInstantInInsert = input.prepareFirstInstantInInsert === true;
  if (focusFirstInstantInInsert && !chatGPTFreshInstantInsert(input)) return { error: 'not_fresh' };
  const readinessFinalGuardOnly = input.firstInstantReadinessFinalGuardOnly === true;
  if (readinessFinalGuardOnly && !chatGPTFirstInstantReadinessFinalGuard(input)) return { error: 'not_fresh' };
  chatGPTPreparationRecord('providerEntryMs', entryStarted);
  let setupStarted = null;
  // Focus-only preparation, model-only verification and scoped read-only
  // first-Instant readiness need the full final proof. Mutating editor and
  // response actions retain their proof before and after the action.
  if (!['stop', 'prepare', 'verifyModel'].includes(input.action) && input.expectedModelChoice != null
    && !readinessFinalGuardOnly) {
    const proof = await websiteModelReadEvidence('chatgpt', input.expectedModelChoice, null,
      { scope: 'action_precheck', action: input.action });
    setupStarted = chatGPTPreparationNow();
    if (proof.error) return proof;
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    // Reading a freshly mounted picker yields. Before any editor mutation,
    // recheck the same native ownership and first-message snapshot again.
    const currentCount = chatGPTMessageRoots('user').length;
    if (window !== window.top || document.URL !== input.expectedURL || globalThis.__computaModelOwner !== input.ownerToken
      || currentCount !== ownedUserCount) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, currentCount,
        firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: readLineageFingerprint } : null, chatGPTTemporaryVerified())
        || { error: 'conversation_changed', detail: 'user_count' };
    if (firstSnapshot && !snapshotUnchanged()) return await chatGPTFirstReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: () => chatGPTMessageRoots('user'), body: chatGPTUserBody, text: normalizedFirstBody,
        identity: () => null, temporary: chatGPTTemporaryVerified })
      || chatGPTFirstUserFailure('snapshot_after_action', 'model_precheck', {}, false, readLineageFingerprint);
    modelState.evidence = proof.modelEvidence;
    modelState.modelVerificationPending = proof.modelVerificationPending === true;
  }
  if (input.action === 'verifyModel') return modelState.modelVerificationPending
    ? { modelVerificationPending: true } : { modelEvidence: modelState.evidence };
  if (setupStarted === null) setupStarted = chatGPTPreparationNow();

  const { provider, action, expectedConversation, expectedConversationIdentity, expectedUserCounts, expectedFirstUserMarker,
    expectedFirstUserIdentity, expectedFirstUserFingerprint, expectedURL, prompt } = input;
  if (window !== window.top || document.URL !== expectedURL) return { error: "document_changed", detail: "document_url" };
  const origin = ({ chatgpt: "https://chatgpt.com", gemini: "https://gemini.google.com", claude: "https://claude.ai" })[provider];
  if (location.origin !== origin) return { error: "sign_in_required" };
  // Foundation's URL.path decodes the colon in ChatGPT's local-chatgpt%3A ID.
  // Compare that same canonical path while document.URL remains exact above.
  const cleanURL = location.origin + decodeURIComponent(location.pathname).replace(/\/$/, "");
  if (expectedConversation && cleanURL !== expectedConversation) return { error: "conversation_changed", detail: "conversation_route" };
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
  const conversationIdentities = provider === "chatgpt" ? [...new Set([...document.querySelectorAll("[data-chatgpt-selection-conversation-id]")]
    .filter(visible).map(node => node.getAttribute("data-chatgpt-selection-conversation-id")).filter(Boolean))] : [];
  const conversationIdentity = conversationIdentities.length === 1 ? conversationIdentities[0] : null;
  if (expectedConversationIdentity && conversationIdentity !== expectedConversationIdentity) return { error: "conversation_changed", detail: "conversation_identity" };
  const enabled = node => visible(node) && !node.disabled && node.getAttribute("aria-disabled") !== "true";
  const responseLoadFailed = action === 'inspect' && chatGPTResponseLoadFailed(visible);
  const responseNoticeDiagnostic = action === 'inspect' ? chatGPTResponseNoticeDiagnostic(visible) : null;
  const find = selectors => selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(visible);
  const labelled = (nodes, expression) => [...nodes].filter(visible).find(node => expression.test(
    [node.getAttribute("aria-label"), node.getAttribute("data-testid"), node.getAttribute("title"), node.innerText].filter(Boolean).join(" ").trim()));
  const composer = provider === "chatgpt" ? find(['#prompt-textarea[contenteditable="true"]', 'textarea#prompt-textarea', '#prompt-textarea [contenteditable="true"]', '[contenteditable="true"][aria-label="Ask ChatGPT"]', 'textarea[data-testid="prompt-textarea"]'])
    : provider === "claude" ? find(['[data-testid="chat-input"][contenteditable="true"][role="textbox"]'])
    : find(['rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']);
  const modernChatGPTAnswers = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')].filter(visible);
  const responseNodes = provider === "chatgpt"
    ? chatGPTMessageRoots('assistant').map(node => node.getAttribute('data-markdown-text-style') === 'assistant-message' ? node
      : node.querySelector('[data-markdown-text-style="assistant-message"]') || node.querySelector('.markdown')
        || node.querySelector('[data-message-author-role="assistant"]')
        || (node.getAttribute('data-message-author-role') === 'assistant' ? node : null)).filter(visible)
    : provider === "claude" ? [...document.querySelectorAll('[data-testid="assistant-message"] [data-perf-reply-text]')].filter(visible)
    : [...document.querySelectorAll(".model-response-text, model-response .markdown")].filter(visible);
  // Avoid duplicate Gemini descendants when the provider adds a wrapper class.
  const answers = responseNodes.filter(node => !responseNodes.some(other => other !== node && other.contains(node)));
  const claudeUsers = provider === "claude" ? [...document.querySelectorAll('[data-testid="user-message"]')] : [];
  const userCount = provider === "chatgpt" ? chatGPTMessageRoots('user').length
    : provider === "claude" ? claudeUsers.length
    : document.querySelectorAll("user-query").length;
  if (provider === "claude" && (!Array.isArray(expectedUserCounts) || !expectedUserCounts.includes(userCount)))
    return { error: "conversation_changed" };
  let firstUserIdentity = null, firstUserFingerprint = null, firstUserMarkerVerified = false;
  if (provider === "claude" && userCount > 0) {
    const firstUser = claudeUsers[0];
    const owner = firstUser.closest("[id]");
    const normalizedBody = (firstUser.innerText || firstUser.textContent || "").replace(/\r\n?/g, "\n").normalize("NFC").trim();
    firstUserIdentity = owner?.getAttribute("id");
    firstUserMarkerVerified = typeof expectedFirstUserMarker === "string" && expectedFirstUserMarker.length > 0
      && normalizedBody.split("\n").some(line => line.trim() === `Computa session marker: ${expectedFirstUserMarker}`);
    if (!firstUserMarkerVerified || typeof firstUserIdentity !== "string" || firstUserIdentity.length === 0
      || firstUserIdentity.length > 256 || normalizedBody.length > 180_200
      || expectedFirstUserIdentity && firstUserIdentity !== expectedFirstUserIdentity
      || !expectedFirstUserFingerprint && ["prepare", "submit"].includes(action)) return { error: "conversation_changed" };
    websiteModelDiagnosticPhase('first_user_hash');
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalizedBody));
    firstUserFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    // Digesting yields the event loop. Recheck the same first DOM message and
    // rendered body before reading an answer or performing any mutation.
    const currentUsers = [...document.querySelectorAll('[data-testid="user-message"]')];
    if (document.URL !== expectedURL || !firstUser.isConnected || currentUsers.length !== userCount || currentUsers[0] !== firstUser
      || firstUser.closest("[id]") !== owner || owner.getAttribute("id") !== firstUserIdentity
      || (firstUser.innerText || firstUser.textContent || "").replace(/\r\n?/g, "\n").normalize("NFC").trim() !== normalizedBody
      || expectedFirstUserFingerprint && firstUserFingerprint !== expectedFirstUserFingerprint) return { error: "conversation_changed" };
  }
  const stop = provider === "chatgpt" ? find(['button[data-testid="stop-button"]', 'button[aria-label="Stop streaming"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]'])
    : provider === "claude" ? find(['button[aria-label="Stop response"]'])
    : find(['button[aria-label="Stop response"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]', 'button.stop-button']);
  const claudeStatus = provider === "claude" ? find(['[data-testid="response-status-announcer"][role="status"]']) : null;
  const interrupted = !!claudeStatus && (claudeStatus.textContent || "").trim().replace(/’/g, "'") === "Claude's response was interrupted.";
  const claudeStreaming = provider === "claude" && [...document.querySelectorAll('[data-testid="assistant-message"][data-is-streaming="true"]')].some(visible);
  const answer = answers.at(-1);
  let responseExtraction; const extractionStarted = chatGPTSyncWorkStart();
  try { responseExtraction = modelResponseExtraction(answer); }
  finally { chatGPTSyncWorkEnd(1, extractionStarted); }
  const answerText = modelResponseText(answer, responseExtraction);
  let answerComplete = false;
  let rendererScopedCopies = [];
  const completionEvidence = { codeStructure: modelResponseStructure(answer, responseExtraction), modernMarkers: modernChatGPTAnswers.length, logicalAnswers: answers.length,
    scopedCopies: 0, enabledCopies: 0, depth: -1 };
  if (provider === "chatgpt" && answer) {
    const scope = chatGPTAnswerCopyScope(answer, answers, chatGPTMessageRoots('user'), visible, enabled);
    completionEvidence.scopedCopies = scope.copies.length;
    completionEvidence.enabledCopies = scope.enabledCopies.length;
    completionEvidence.depth = scope.depth;
    completionEvidence.footerAssociation = scope.association ? 'paired_turn' : scope.footer ? 'assistant_ancestor' : 'none';
    rendererScopedCopies = scope.enabledCopies; answerComplete = scope.enabledCopies.length > 0;
  } else if (provider === "claude" && answer) {
    const message = answer.closest('[data-testid="assistant-message"]');
    const article = answer.closest('[role="article"]');
    const copy = article?.querySelector('[data-testid="message-actions"] button[data-testid="action-bar-copy"][aria-label="Copy"]');
    answerComplete = !interrupted && message?.getAttribute("data-is-streaming") === "false"
      && article?.querySelectorAll('[data-testid="assistant-message"]').length === 1 && enabled(copy);
  } else if (answer) {
    answerComplete = !!answer.closest("model-response")?.querySelector('button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]');
  }
  const rendererGuard = chatGPTInlineRendererGuardStructure(answer, rendererScopedCopies);
  if (rendererGuard) completionEvidence.codeStructure.rendererGuard = rendererGuard;
  const claudeExit = provider === "claude" ? find(['button[aria-label="Exit incognito"]']) : null;
  const claudeIncognitoBadge = claudeExit && new URL(document.URL).searchParams.has("incognito")
    && [...document.querySelectorAll(".animate-incognito-header-in span")].find(node => visible(node)
      && (node.textContent || "").trim() === "Incognito chat");
  const temporary = provider === "claude" ? !!claudeIncognitoBadge : provider === "chatgpt"
    ? chatGPTTemporaryVerified()
    : !!find(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]'])
      || [...document.querySelectorAll('h1, h2, span.info-text')].some(node => visible(node)
        && !node.closest('button, [role="menu"], [role="tooltip"], model-response, user-query')
        && ["Just stopping by?", "Temporary Chat"].includes((node.textContent || "").trim()));
  const temporaryActionAvailable = enabled(provider === "claude" ? find(['button[aria-label="Use incognito"]'])
    : find(['button[aria-label="Temporary chat"]']));
  const state = { ...(modelState.modelVerificationPending ? { modelVerificationPending: true } : { modelEvidence: modelState.evidence }), url: document.URL, temporary, temporaryActionAvailable, conversationIdentity, composer: !!composer, responseCount: answers.length, userCount,
    firstUserIdentity, firstUserFingerprint, firstUserMarkerVerified,
    busy: !!stop || claudeStreaming, interrupted, responseLoadFailed, responseNoticeDiagnostic,
    ...(provider === 'chatgpt' ? { answerScopeDiagnostic: chatGPTAnswerScopeDiagnostic(answer) } : {}),
    text: answerText.slice(0, 220_001), answerComplete, completionEvidence };
  chatGPTPreparationRecord('providerSetupMs', setupStarted);
  if (action === "inspect") {
    const signIn = !composer && !!labelled(document.querySelectorAll('a, button'), /^(?:Log in|Sign in)(?:\s|$)/i);
    const resourceTimingDiagnostic = answerComplete ? chatGPTResourceTimingDiagnostic('completion') : null;
    // Native can decline this generic diagnostic on an established reply.
    // Keep fresh/empty shapes observable and preserve every proof above.
    const includeDebugStructure = input.requestDebugStructure !== false || userCount === 0 || answers.length === 0;
    let debugStructure;
    if (includeDebugStructure) {
      const structureStarted = chatGPTSyncWorkStart();
      try { debugStructure = chatGPTStructure(visible); } finally { chatGPTSyncWorkEnd(2, structureStarted); }
    }
    return { ...state, signIn, ...(includeDebugStructure ? { debugStructure } : {}),
      ...(resourceTimingDiagnostic ? { resourceTimingDiagnostic } : {}) };
  }
  if (action === "enableTemporary") {
    if (temporary) return { ...state, enabled: true };
    if (userCount || answers.length) return { error: "not_fresh" };
    if (globalThis.__computaModelTemporaryRequested) return { error: "temporary_mode_unverified" };
    const toggle = provider === "claude" ? find(['button[aria-label="Use incognito"]'])
      : find(['button[aria-label="Temporary chat"]']);
    if (!enabled(toggle)) return { error: "temporary_mode_unavailable" };
    if (!chatGPTControlExposed(toggle)) return { error: "temporary_mode_unavailable" };
    const mode = chatGPTProductModeProof();
    if (!mode || mode.temporaryTransition !== 'not_requested') return { error: 'product_mode_unverified' };
    globalThis.__computaModelTemporaryRequested = true;
    globalThis.__computaChatProductMode.temporaryRequested = true;
    toggle.click(); return { ...state, enabled: false };
  }
  if (["prepare", "insert", "sendReady", "submit", "stop"].includes(action) && !temporary)
    return { error: "temporary_mode_unverified" };
  if (action === "insert") {
    const preFocusStarted = chatGPTPreparationNow();
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    if (!enabled(composer) || stop) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (value?.trim() || typeof prompt !== "string" || prompt.length > 180000)
      return { error: "composer_not_empty" };
    if (userCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || typeof expectedFirstUserMarker !== "string"
        || !/^[a-f0-9-]{36}$/i.test(expectedFirstUserMarker)
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return chatGPTFirstUserFailure('first_insert', 'first_insert', { rendered: prompt });
      // This is insertion data, not ownership proof. The marker becomes
      // authoritative only at the exact-text check immediately before Send.
      globalThis.__computaModelFirstPrompt = prompt;
    }
    const focusPin = focusFirstInstantInInsert ? globalThis.__computaChatPresetPin : null;
    const focusSelection = focusPin?.selection, focusAttempt = globalThis.__computaModelSelection;
    const focusFamily = focusSelection?.family?.key;
    const currentEditors = () => [...new Set(document.querySelectorAll('#prompt-textarea[contenteditable="true"], textarea#prompt-textarea, '
      + '#prompt-textarea [contenteditable="true"], [contenteditable="true"][aria-label="Ask ChatGPT"], textarea[data-testid="prompt-textarea"]'))].filter(visible);
    if (focusFirstInstantInInsert && (!chatGPTFreshInstantInsert(input) || !focusPin || !focusAttempt?.completed
      || currentEditors().length !== 1 || currentEditors()[0] !== composer))
      return { error: 'not_fresh' };
    const previousFocusControls = focusPin?.headerTrigger?.getAttribute('aria-controls');
    if (focusFirstInstantInInsert) {
      chatGPTDrainSignalRecords();
      websiteChatDrainPinnedMutations(focusPin);
      if (focusPin.invalidated === true || !chatGPTProductModeProof()) return { error: 'model_unverified' };
    }
    chatGPTPreparationRecord('insertPreFocusMs', preFocusStarted);
    const focusStarted = chatGPTPreparationNow();
    try { composer.focus(); }
    finally { chatGPTPreparationRecord('editorFocusMs', focusStarted); }
    const postFocusStarted = chatGPTPreparationNow();
    if (focusFirstInstantInInsert) {
      const focusRecords = chatGPTDrainSignalRecords();
      if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
      if (!chatGPTTemporaryVerified()) return { error: 'temporary_mode_unverified' };
      if (document.activeElement !== composer && !composer.contains(document.activeElement)) return { error: 'composer_unavailable' };
      if (!chatGPTFreshInstantInsert(input)) return { error: 'not_fresh' };
      // The full precheck already ran. Focus handlers are synchronous: drain
      // their negative history and recheck this exact closed proof without
      // another picker opening or any yield before the single editor mutation.
      websiteChatDrainPinnedMutations(focusPin);
      const picker = websiteChatPickerState();
      if (chatGPTFocusModelActivity(focusRecords, focusPin.headerTrigger, previousFocusControls)
        || globalThis.__computaChatPresetPin !== focusPin || globalThis.__computaModelSelection !== focusAttempt
        || focusAttempt.completed !== true || focusPin.invalidated === true || focusPin.document !== document || focusPin.owner !== input.ownerToken
        || focusPin.selection !== focusSelection || focusSelection?.family?.key !== focusFamily || focusSelection?.power?.key !== 'instant'
        || !websiteModelChoiceEqual(input.expectedModelChoice, websiteChatPresetChoice(focusSelection.family, focusSelection.power))
        || picker.trigger !== focusPin.headerTrigger || !websiteChatClosedHeaderMatches(picker, focusPin.selection.power, focusPin)
        || picker.duplicate || picker.conflicting || picker.indicatorInvalid || picker.selectionAmbiguous || picker.navigationAmbiguous)
        return { error: 'model_unverified' };
      const editorsAfterFocus = currentEditors();
      if (!enabled(composer) || editorsAfterFocus.length !== 1 || editorsAfterFocus[0] !== composer
        || (composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText)?.trim()
        || find(['button[data-testid="stop-button"]', 'button[aria-label="Stop streaming"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]']))
        return { error: 'composer_unavailable' };
    }
    chatGPTPreparationRecord('insertPostFocusMs', postFocusStarted);
    const mutationStarted = chatGPTPreparationNow();
    const dispatchInput = () => {
      chatGPTPreparationRecord('editorMutationMs', mutationStarted);
      const dispatchStarted = chatGPTPreparationNow();
      try { composer.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: prompt })); }
      finally { chatGPTPreparationRecord('inputDispatchMs', dispatchStarted); }
    };
    if (composer instanceof HTMLTextAreaElement) {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set.call(composer, prompt);
      dispatchInput();
    } else {
      // A background WebKit editor can have focus without an editing caret.
      // Select only this empty, owned composer before the single insertion.
      const selection = window.getSelection();
      if (!selection) return { error: "caret_unavailable" };
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
      if (!composer.contains(selection.anchorNode) || !composer.contains(selection.focusNode))
        return { error: "caret_unavailable" };
      if (composer.classList.contains("ProseMirror")) {
        // Native editing commands can apply macOS text substitutions. Build one
        // literal paragraph with hard line breaks and let the editor observe it.
        const paragraph = document.createElement("p");
        prompt.split("\n").forEach((line, index) => {
          if (index) paragraph.appendChild(document.createElement("br"));
          paragraph.appendChild(document.createTextNode(line));
        });
        composer.replaceChildren(paragraph);
        range.selectNodeContents(paragraph);
        range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
        dispatchInput();
      } else {
        // execCommand includes its browser-dispatched input handlers; this
        // fallback cannot split mutation from reaction without changing it.
        if (!document.execCommand("insertText", false, prompt)) return { error: "insert_command_rejected" };
        chatGPTPreparationRecord('editorMutationMs', mutationStarted);
      }
    }
    chatGPTProviderReturnStarted = chatGPTPreparationNow();
    return { ...state, inserted: true };
  }
  if (action === "prepare") {
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    if (!enabled(composer) || stop || claudeStreaming) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (value?.trim()) return { error: "composer_not_empty" };
    const focusStarted = chatGPTPreparationNow();
    try { composer.focus(); }
    finally { chatGPTPreparationRecord('editorFocusMs', focusStarted); }
    return { ...state, prepared: document.activeElement === composer || composer.contains(document.activeElement) };
  }
  if (action === "submit" || action === "sendReady") {
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    if (!enabled(composer) || stop || claudeStreaming) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    const actual = (value || "").replace(/\r\n/g, "\n").trim();
    const expected = prompt.trim();
    if (actual !== expected) {
      // Report shape only, never prompt or page text.
      const detail = !actual ? "editor_empty"
        : actual.replace(/\n+/g, "\n") === expected.replace(/\n+/g, "\n") ? "line_break_expansion"
        : actual.replace(/\u00a0/g, " ") === expected ? "nonbreaking_spaces" : "text_difference";
      return { error: "prompt_not_inserted", detail, ...modelEditorDifference(actual, expected), actualLength: actual.length,
        expectedLength: expected.length, actualLines: actual.split("\n").length, expectedLines: expected.split("\n").length };
    }
    const send = provider === "chatgpt" ? find(['button[data-testid="send-button"]', 'button[aria-label="Send prompt"]', 'button[aria-label="Send message"]', 'button[aria-label="Send"]'])
      : provider === "claude" ? find(['button[data-testid="chat-input-send"][aria-label="Send message"]'])
      : find(['button[aria-label="Send message"]', 'button[aria-label="Send"]', 'button.send-button']);
    if (action === "sendReady") return { ...state, sendReady: enabled(send) };
    if (!enabled(send)) return { error: "send_unavailable" };
    if (globalThis.__computaModelLastSubmissionCount !== undefined
      && userCount <= globalThis.__computaModelLastSubmissionCount)
      return { error: 'conversation_changed', detail: 'user_count' };
    if (userCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || globalThis.__computaModelFirstPrompt !== prompt
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return chatGPTFirstUserFailure('first_submit', 'first_submit', { rendered: prompt });
      globalThis.__computaModelFirstMarker = expectedFirstUserMarker;
      globalThis.__computaModelFirstSubmitted = true;
    }
    const submissionFailure = chatGPTClaimSubmission(input, prompt, userCount);
    if (submissionFailure) return submissionFailure;
    globalThis.__computaModelLastSubmissionCount = userCount;
    // Diagnostic metadata only: claim counts once beside the existing Send
    // claim, without retaining another prompt or granting observation authority.
    try {
      globalThis.__computaChatSubmissionSize = Object.freeze({ document, owner: input.ownerToken, userCount,
        utf16Count: prompt.length, utf8Count: new TextEncoder().encode(prompt).length });
    } catch { /* Measurement failure cannot change the existing Send behavior. */ }
    try {
      const mark = typeof window.performance?.now === 'function' ? window.performance.now() : null;
      globalThis.__computaChatResourceTimingClaim = Object.freeze({ document, owner: input.ownerToken,
        userCount, sequence: userCount + 1, mark: Number.isFinite(mark) && mark >= 0 ? mark : null });
    } catch { /* A missing clock cannot alter submission behavior. */ }
    send.click();
    const resourceTimingDiagnostic = chatGPTResourceTimingDiagnostic('send');
    return { submitted: true, ...(resourceTimingDiagnostic ? { resourceTimingDiagnostic } : {}) };
  }
  if (action === "stop") { if (enabled(stop)) stop.click(); return { stopped: !!stop }; }
  return { error: "unknown_action" };
}

if (window !== window.top || location.origin !== "https://chatgpt.com" || document.URL !== input.expectedURL)
  return { error: "document_changed", detail: "document_url" };
if (input.action === 'failedPageDiagnostic' && (input.provider !== 'chatgpt' || input.bindOwner === true
  || typeof input.ownerToken !== 'string' || !/^[a-f0-9-]{36}$/i.test(input.ownerToken)))
  return { error: 'document_changed', detail: 'owner_token' };
if (globalThis.__computaModelOwner !== input.ownerToken) {
  if (input.bindOwner && globalThis.__computaModelOwner === undefined)
    globalThis.__computaModelOwner = input.ownerToken;
  else return { error: "document_changed", detail: "owner_token" };
}
if (globalThis.__computaChatSubmissionState == null && input.expectedSubmissionProofs != null
  && (!Array.isArray(input.expectedSubmissionProofs) || input.expectedSubmissionProofs.length > 0))
  return chatGPTSubmissionFailure(null);
if (input.action === 'failedPageDiagnostic') {
  const resourceTimingDiagnostic = chatGPTResourceTimingDiagnostic('failure');
  return chatGPTObservationDiagnosticResult({ failureDiagnostic: chatGPTFailedPageDiagnostic(), ...(resourceTimingDiagnostic ? { resourceTimingDiagnostic } : {}) });
}
if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken) {
  const signal = { ownerToken: input.ownerToken, observer: null };
  signal.observer = new MutationObserver(records => chatGPTProcessSignalRecords(signal, records));
  // The HTML element can be replaced without replacing this Document or owner.
  // Observe its parent so replacement and the new subtree still wake a fresh read.
  signal.observer.observe(document, {
    subtree: true, childList: true, characterData: true, attributes: true, attributeOldValue: true,
    attributeFilter: ["disabled", "aria-disabled", "aria-hidden", "aria-busy", "aria-label", "class", "style",
      "aria-checked", "aria-pressed", "aria-selected", "aria-valuenow", "aria-valuemin", "aria-valuemax", "aria-controls", "aria-labelledby", "aria-expanded", "title", "hidden", "inert", "contenteditable", "data-testid", "data-is-streaming",
      "data-message-author-role", "data-markdown-text-style", "data-chatgpt-selection-conversation-id", "data-turn",
      "data-user-message-bubble", "data-talvt-turn-state", "data-content-search-turn-key",
      "data-chatgpt-selection-message-id", "data-tool-call-id", "role"]
  });
  globalThis.__computaModelSignal = signal;
}
// Diagnostic-only observation does not await, mutate the page, or grant proof.
if (input.action === 'insert' && input.matchedBenchmarkProbe != null) {
  try { computaInstallMatchedBenchmarkProbe(input.matchedBenchmarkProbe); } catch { /* inference unchanged */ }
}
if (input.action === 'insert' && input.matchedObservationDiagnostic != null && input.matchedBenchmarkProbe != null
  && input.expectedModelChoice?.key === 'chat/latest/instant' && input.submissionSequence === 1) {
  try {
    const fields = ['schemaVersion', 'nonce', 'expectedSHA256', 'expectedCanonicalSHA256', 'expectedUTF8Bytes'];
    if (fields.every(name => input.matchedObservationDiagnostic[name] === input.matchedBenchmarkProbe[name])
      && typeof computaInstallObservationDiagnostic === 'function')
      computaInstallObservationDiagnostic(input.matchedObservationDiagnostic);
  } catch { /* diagnostic failure leaves inference unchanged */ }
}
const ownedMessages = chatGPTMessageRoots('user');
const ownedUserCount = ownedMessages.length;
if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.includes(ownedUserCount))
  return { error: "conversation_changed", detail: "user_count" };
let firstUserVerified = false;
let firstUserFingerprint = null;
let firstSnapshot = null;
let firstUserRejectionDiagnostic;
let chatGPTFinalResponseSnapshot = null;
const normalizedFirstBody = node => {
  const bodyStarted = chatGPTSyncWorkStart();
  try { return (node.innerText || node.textContent || "").replace(/\r\n?/g, "\n").normalize("NFC").trim(); }
  finally { chatGPTSyncWorkEnd(3, bodyStarted); }
};
function chatGPTFirstUserExpandControls(root, roots, maxDepth = 3) {
  const controls = new Set(), assistants = chatGPTMessageRoots('assistant');
  const physical = node => node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  for (let scope = root, depth = 0; scope && depth <= maxDepth; scope = scope.parentElement, depth++) {
    if (depth > 0 && !['DIV', 'SECTION', 'ARTICLE'].includes(scope.tagName)) break;
    if (depth > 0 && (['main', 'navigation', 'complementary'].includes(scope.getAttribute('role'))
      || scope.querySelector('form, textarea, [contenteditable="true"], nav, aside, [role="navigation"], [role="complementary"]'))) break;
    if (roots.filter(node => scope === node || scope.contains(node)).length !== 1
      || assistants.some(node => scope === node || scope.contains(node))) break;
    for (const control of [...scope.querySelectorAll('button, [role="button"], summary')].slice(0, 1_001)) {
      if (!physical(control)) continue;
      const label = control.getAttribute('aria-label') || control.innerText || control.textContent;
      if (typeof label !== 'string' || label.length > 64) continue;
      if (/^(?:show more|view more|read more|expand)$/i.test(label.trim().replace(/\s+/g, ' '))) controls.add(control);
    }
  }
  return [...controls];
}
// Invocation-local rejection facts only; no claim, retry or ownership comes
// from this diagnostic. In particular a pre-claim context failure must not be
// lost merely because the expansion was correctly refused.
let chatGPTFirstUserExpansionAdmissionFailure = null;
function chatGPTFirstUserExpansionCandidate(root, body, rendered) {
  const prompt = globalThis.__computaModelFirstPrompt, marker = input.expectedFirstUserMarker;
  const reject = reason => { chatGPTFirstUserExpansionAdmissionFailure = reason; return null; };
  if (input.suppressFirstUserExpansionClaim === true) return reject('suppressed');
  if (input.action !== 'inspect') return reject('action');
  if (input.allowFirstUserExpansion !== true || input.allowFirstUserBinding !== true) return reject('binding');
  if (input.expectedFirstUserFingerprint != null) return reject('native_pin');
  if (globalThis.__computaModelFirstProof != null) return reject('private_pin');
  if (globalThis.__computaModelFirstExpansion != null) return reject('claim_spent');
  if (ownedUserCount !== 1) return reject('user_count');
  if (globalThis.__computaModelFirstSubmitted !== true) return reject('submission');
  if (globalThis.__computaModelLastSubmissionCount !== 0) return reject('submission_count');
  if (typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker)
    || globalThis.__computaModelFirstMarker !== marker) return reject('marker');
  if (typeof prompt !== 'string' || prompt.length > 180_000
    || !prompt.endsWith(`\n\nComputa session marker: ${marker}`)) return reject('prompt');
  if (!websiteModelChoiceValid(input.firstUserExpansionModelChoice)) return reject('model_choice');
  const canonical = prompt.replace(/\r\n?/g, '\n').normalize('NFC').trim();
  if (!rendered || rendered.length >= canonical.length || !canonical.startsWith(rendered)
    || rendered.includes(`Computa session marker: ${marker}`)) return reject('text_prefix');
  const candidate = { root, body, rendered, prompt, canonical, marker, clicked: false, outcome: 'claimed',
    document, owner: input.ownerToken, routeURL: input.expectedURL, modelChoice: input.firstUserExpansionModelChoice };
  const contextFailure = chatGPTFirstUserExpansionContextFailure(candidate);
  return contextFailure === null ? candidate : reject(contextFailure);
}
function chatGPTFirstUserExpansionContextFailure(candidate) {
  const roots = chatGPTMessageRoots('user');
  if (window !== window.top || candidate.document !== document) return 'frame';
  if (input.provider !== 'chatgpt') return 'provider';
  if (location.origin !== 'https://chatgpt.com') return 'origin';
  if (globalThis.__computaModelOwner !== candidate.owner || input.ownerToken !== candidate.owner) return 'owner';
  if (roots.length !== 1) return 'user_count';
  if (globalThis.__computaModelFirstSubmitted !== true) return 'submission';
  if (globalThis.__computaModelLastSubmissionCount !== 0) return 'submission_count';
  if (globalThis.__computaModelFirstMarker !== candidate.marker) return 'marker';
  if (globalThis.__computaModelFirstPrompt !== candidate.prompt) return 'prompt';
  if (globalThis.__computaModelFirstProof != null) return 'private_pin';
  if (!chatGPTProductModeProof()) return 'product';
  if (!chatGPTTemporaryVerified()) return 'temporary';
  if (roots[0] !== candidate.root || !candidate.root.isConnected) return 'root';
  if (!candidate.body.isConnected || chatGPTUserBody(candidate.root) !== candidate.body) return 'body';
  const cleanURL = location.origin + decodeURIComponent(location.pathname).replace(/\/$/, '');
  if (input.expectedConversation && cleanURL !== input.expectedConversation) return 'conversation_route';
  if (input.expectedConversationIdentity) {
    const identities = [...new Set([...document.querySelectorAll('[data-chatgpt-selection-conversation-id]')]
      .filter(node => node.isConnected && node.getClientRects().length > 0
        && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]'))
      .map(node => node.getAttribute('data-chatgpt-selection-conversation-id')).filter(Boolean))];
    if (identities.length !== 1 || identities[0] !== input.expectedConversationIdentity) return 'conversation_identity';
  }
  // URL-only failure is continuable only after every other predicate passes.
  // The native route classifier, never this page, certifies the specific edge.
  if (document.URL !== input.expectedURL) return 'url';
  return null;
}
function chatGPTFirstUserExpansionContext(candidate) { return chatGPTFirstUserExpansionContextFailure(candidate) === null; }
function chatGPTFirstUserExpansionTextFacts(candidate, text) {
  if (typeof text !== 'string' || text.length > 180_200 || typeof candidate.canonical !== 'string'
    || candidate.canonical.length > 180_200 || typeof candidate.rendered !== 'string' || candidate.rendered.length > 180_200) return null;
  // The full message already permits differences within ASCII whitespace
  // runs. Apply precisely that same policy to its previously captured prefix.
  // Every other character and every whitespace boundary remains significant.
  const runs = value => value.replace(/[ \t\n]+/g, ' ');
  const actual = runs(text), expected = runs(candidate.canonical), prefix = runs(candidate.rendered);
  const prefixMatches = actual.startsWith(prefix), promptMatches = actual === expected;
  const markerLine = `Computa session marker: ${candidate.marker}`;
  const complete = actual.length > prefix.length && prefixMatches && promptMatches
    && text.split('\n').at(-1) === markerLine && text.split(markerLine).length === 2;
  const compatible = complete || prefixMatches && !text.includes(markerLine) && expected.startsWith(actual);
  return { complete, compatible, expansionTextAnalyzed: true, expansionClicked: candidate.clicked === true,
    expansionExactPrefixMatches: text.startsWith(candidate.rendered), expansionASCIIPrefixMatches: prefixMatches,
    expansionASCIIPromptMatches: promptMatches, expansionASCIIRenderedLength: actual.length,
    expansionASCIIPrefixLength: prefix.length, expansionASCIIPromptLength: expected.length };
}
function chatGPTFramedPayloadDiagnostic(expected, rendered) {
  const result = { payloadExpectedFrameUnique: false, payloadRenderedFrameUnique: false,
    payloadExpectedParsed: false, payloadRenderedParsed: false, payloadOutsideFrameMatches: false,
    payloadCompared: false, payloadParsedJSONEqual: false, payloadObjectKeyOrderChanged: false, payloadUnavailableReason: 'missing_frame',
    payloadMismatchField: 'none', payloadMismatchKind: 'none', payloadExpectedType: 'none', payloadRenderedType: 'none' };
  try {
    const begin = 'COMPLETE_RESPONSES_REQUEST_JSON:\n', end = '\nEND_COMPLETE_RESPONSES_REQUEST_JSON.';
    if (typeof expected !== 'string' || typeof rendered !== 'string' || expected.length > 180_200 || rendered.length > 180_200) {
      result.payloadUnavailableReason = 'bounds'; return result;
    }
    const frame = value => {
      if (typeof value !== 'string' || value.length > 180_200) return null;
      const start = value.indexOf(begin), finish = value.indexOf(end);
      if (start < 0 || finish < start + begin.length || value.indexOf(begin, start + begin.length) !== -1
        || value.indexOf(end, finish + end.length) !== -1) return null;
      return { payload: value.slice(start + begin.length, finish), before: value.slice(0, start), after: value.slice(finish + end.length) };
    };
    const left = frame(expected), right = frame(rendered);
    result.payloadExpectedFrameUnique = left !== null; result.payloadRenderedFrameUnique = right !== null;
    if (!left || !right) return result;
    result.payloadOutsideFrameMatches = left.before === right.before && left.after === right.after;
    result.payloadUnavailableReason = 'parse_failure';
    let expectedValue, renderedValue;
    try { expectedValue = JSON.parse(left.payload); result.payloadExpectedParsed = true; } catch { }
    try { renderedValue = JSON.parse(right.payload); result.payloadRenderedParsed = true; } catch { }
    if (!result.payloadExpectedParsed || !result.payloadRenderedParsed) return result;
    result.payloadUnavailableReason = 'bounds';
    const type = value => value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
    let nodes = 0;
    const validate = (value, depth) => {
      if (++nodes > 8_192 || depth > 64) throw new Error('bounded');
      if (typeof value === 'number' && (!Number.isFinite(value) || Number.isInteger(value) && !Number.isSafeInteger(value))) {
        result.payloadUnavailableReason = 'number_precision';
        throw new Error('bounded');
      }
      if (Array.isArray(value)) { for (const item of value) validate(item, depth + 1); }
      else if (value !== null && typeof value === 'object') {
        const keys = Object.keys(value); if (keys.length > 8_192) throw new Error('bounded');
        for (const key of keys) validate(value[key], depth + 1);
      }
    };
    validate(expectedValue, 0); validate(renderedValue, 0);
    let mismatch = null, orderChanged = false;
    const field = key => ['instructions', 'input', 'tools', 'metadata'].includes(key) ? key : 'other';
    const record = (top, kind, expectedType, renderedType) => {
      mismatch ||= { payloadMismatchField: top, payloadMismatchKind: kind, payloadExpectedType: expectedType, payloadRenderedType: renderedType };
    };
    const compare = (a, b, top = 'other', depth = 0) => {
      const at = type(a), bt = type(b);
      if (at !== bt) { record(top, ['array', 'object'].includes(at) || ['array', 'object'].includes(bt) ? 'container_type' : 'leaf_type', at, bt); return; }
      if (at === 'array') {
        if (a.length !== b.length) record(top, 'array_length', at, bt);
        for (let i = 0; i < Math.min(a.length, b.length); i++) compare(a[i], b[i], top, depth + 1);
      } else if (at === 'object') {
        const ak = Object.keys(a), bk = Object.keys(b), owns = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
        const sameKeys = ak.length === bk.length && ak.every(key => owns(b, key));
        if (sameKeys && ak.some((key, i) => key !== bk[i])) orderChanged = true;
        for (const key of ak) {
          const child = depth === 0 ? field(key) : top;
          if (!owns(b, key)) record(child, 'object_keys', type(a[key]), 'missing');
          else compare(a[key], b[key], child, depth + 1);
        }
        for (const key of bk) if (!owns(a, key)) record(depth === 0 ? field(key) : top, 'object_keys', 'missing', type(b[key]));
      } else if (!Object.is(a, b)) record(top, 'leaf_value', at, bt);
    };
    compare(expectedValue, renderedValue);
    // Parsed JSON equivalence is diagnostic only: JSON.parse resolves duplicate
    // keys and numeric lexemes. It cannot replace the original ownership proof.
    result.payloadCompared = true; result.payloadParsedJSONEqual = mismatch === null;
    result.payloadObjectKeyOrderChanged = orderChanged; result.payloadUnavailableReason = 'none';
    if (mismatch) Object.assign(result, mismatch);
    return result;
  } catch { return result; }
}
function chatGPTLiteralDOMDiagnostic(candidate, rendered) {
  const result = { literalDOMAvailable: false, literalDOMMatchesPrompt: false, literalDOMMatchesRendered: false,
    literalDOMLength: 0, literalDOMNodeCount: 0, literalDOMMaxDepth: 0, literalDOMParagraphCount: 0, literalDOMBRCount: 0, literalDOMLinkCount: 0,
    literalDOMUnavailableReason: 'read_failure', literalDOMFrameUnique: false, literalDOMFrameParsed: false,
    literalDOMPayloadCompared: false, literalDOMParsedJSONEqual: false, literalDOMPayloadUnavailableReason: 'unavailable' };
  try {
    // A fixed text/BR/paragraph stream diagnoses presentation only. It is not
    // a replacement ownership extractor, and unsupported markup grants none.
    const root = candidate.body, parts = [], children = root.childNodes;
    // Keep the exact physical body and count/validate both nodes. Only one
    // immediate DIV with no text, whitespace or comment siblings is logical
    // content; this diagnostic never changes the original ownership reader.
    const logicalRoot = root.nodeType === 1 && root.tagName === 'DIV' && children.length === 1
      && children[0].nodeType === 1 && children[0].tagName === 'DIV' ? children[0] : root;
    const fail = reason => { result.literalDOMUnavailableReason = reason; throw new Error('unavailable'); };
    const failureNode = (node, rule, reason = 'unsupported_markup') => {
      const tags = ['div', 'span', 'p', 'pre', 'code', 'button', 'section', 'article', 'a', 'strong', 'em', 'ol', 'ul', 'li', 'br', 'input', 'textarea'];
      const tag = value => !value || value.nodeType !== 1 ? 'none'
        : tags.includes(value.tagName?.toLowerCase()) ? value.tagName.toLowerCase() : 'other';
      Object.assign(result, { literalDOMFailureNodeKind: node.nodeType === 1 ? 'element' : node.nodeType === 8 ? 'comment' : 'other',
        literalDOMFailureTag: tag(node), literalDOMFailureParentTag: tag(node.parentElement), literalDOMFailureRule: rule });
      fail(reason);
    };
    const append = text => {
      if (typeof text !== 'string') fail('read_failure');
      if (result.literalDOMLength + text.length > 180_200) {
        result.literalDOMLength = 180_201; fail('character_budget');
      }
      parts.push(text); result.literalDOMLength += text.length;
    };
    const walk = (node, depth) => {
      result.literalDOMNodeCount = Math.min(result.literalDOMNodeCount + 1, 8_193);
      result.literalDOMMaxDepth = Math.max(result.literalDOMMaxDepth, Math.min(depth, 65));
      if (result.literalDOMNodeCount > 8_192) fail('node_budget');
      if (depth > 64) fail('depth_budget');
      if (node.nodeType === 3) { append(node.data); return; }
      if (node.nodeType !== 1) failureNode(node, 'node_type');
      if (node.closest('[inert]')) fail('inert_markup');
      const style = getComputedStyle(node);
      if (node.hidden || node.closest('[hidden], [aria-hidden="true"]') || style.display === 'none'
        || ['hidden', 'collapse'].includes(style.visibility)
        || node.tagName !== 'BR' && node.getClientRects().length === 0) fail('hidden_markup');
      // Diagnose the literal text of the observed inline anchor only. Its URL
      // and action semantics are never read, and this stream grants no proof.
      const role = node.getAttribute('role');
      const inlineLink = node.tagName === 'A' && node.parentElement?.tagName === 'P'
        && node.parentElement.parentElement === logicalRoot && logicalRoot.tagName === 'DIV'
        && (role === null || role === 'link');
      if (!inlineLink && ['BUTTON', 'INPUT', 'TEXTAREA', 'SELECT', 'OPTION', 'A', 'SUMMARY'].includes(node.tagName)
        || ['button', 'textbox', 'link', 'menuitem', 'slider', 'combobox'].includes(role) && !(inlineLink && role === 'link')
        || node.closest('[contenteditable="true"]')) failureNode(node, 'control', 'control_markup');
      if (!inlineLink && !['DIV', 'SPAN', 'P', 'BR'].includes(node.tagName)) failureNode(node, 'tag');
      if (node !== root && node !== logicalRoot && node.tagName === 'DIV') failureNode(node, 'nested_div');
      if (node.tagName === 'P' && node !== root && (node.parentElement !== logicalRoot || logicalRoot.tagName !== 'DIV')) failureNode(node, 'paragraph_parent');
      if (node.tagName === 'BR') { result.literalDOMBRCount++; append('\n'); return; }
      if (inlineLink) result.literalDOMLinkCount++;
      if (node.tagName === 'P') {
        result.literalDOMParagraphCount++;
        if (node !== root && parts.length) append('\n');
      }
      for (const child of node.childNodes) walk(child, depth + 1);
    };
    walk(root, 0);
    const normalize = value => value.replace(/\r\n?/g, '\n').normalize('NFC').trim();
    const text = normalize(parts.join(''));
    const payload = chatGPTFramedPayloadDiagnostic(candidate.canonical, text);
    result.literalDOMAvailable = true; result.literalDOMUnavailableReason = 'none';
    result.literalDOMMatchesPrompt = text === candidate.canonical;
    result.literalDOMMatchesRendered = typeof rendered === 'string' && text === normalize(rendered);
    result.literalDOMFrameUnique = payload.payloadRenderedFrameUnique;
    result.literalDOMFrameParsed = payload.payloadRenderedParsed;
    result.literalDOMPayloadCompared = payload.payloadCompared;
    result.literalDOMParsedJSONEqual = payload.payloadParsedJSONEqual;
    result.literalDOMPayloadUnavailableReason = payload.payloadUnavailableReason;
    return result;
  } catch { return result; }
}
function chatGPTLatchExpansionTextDiagnostic(candidate, text) {
  if (candidate.textDiagnostic) return;
  try {
    const facts = chatGPTFirstUserExpansionTextFacts(candidate, text);
    const payload = chatGPTFramedPayloadDiagnostic(candidate.canonical, text);
    const literalDOM = chatGPTLiteralDOMDiagnostic(candidate, text);
    if (!facts) { candidate.textDiagnostic = { expansionTextAnalyzed: false, expansionClicked: candidate.clicked === true, ...payload, ...literalDOM }; return; }
    const { complete, compatible, ...diagnostic } = facts;
    const actual = text.replace(/[ \t\n]+/g, ' '), expected = candidate.canonical.replace(/[ \t\n]+/g, ' ');
    const count = (value, predicate) => Math.min([...value].filter(predicate).length, 1_000);
    const unicodeSpace = value => /\p{White_Space}/u.test(value) && !/[ \t\n]/.test(value);
    const format = value => /\p{Cf}/u.test(value);
    let offset = 0;
    while (offset < actual.length && offset < expected.length && actual.codePointAt(offset) === expected.codePointAt(offset))
      offset += actual.codePointAt(offset) > 0xFFFF ? 2 : 1;
    const scalar = value => offset < value.length ? String.fromCodePoint(value.codePointAt(offset)) : '';
    const left = scalar(actual), right = scalar(expected);
    // A finite syntax vocabulary distinguishes rendering changes without
    // logging arbitrary content scalars, letters, digits or text fragments.
    const character = value => offset >= value.length ? 'end' : ({
      32: 'ascii_space', 33: 'exclamation', 34: 'double_quote', 35: 'hash', 36: 'dollar',
      38: 'ampersand', 39: 'apostrophe', 40: 'left_parenthesis', 41: 'right_parenthesis',
      42: 'asterisk', 45: 'hyphen', 46: 'period', 47: 'slash', 58: 'colon',
      60: 'less_than', 62: 'greater_than', 91: 'left_bracket', 92: 'backslash',
      93: 'right_bracket', 95: 'underscore', 96: 'backtick', 123: 'left_brace',
      125: 'right_brace', 126: 'tilde', 160: 'no_break_space', 8203: 'zero_width_space',
      8288: 'word_joiner', 65279: 'byte_order_mark',
    })[value.codePointAt(offset)] || 'other';
    const mismatch = diagnostic.expansionASCIIPromptMatches ? 'none' : !left || !right ? 'end'
      : format(left) || format(right) ? 'format' : unicodeSpace(left) || unicodeSpace(right) ? 'unicode_space'
        : left === ' ' || right === ' ' ? 'ascii_space'
          : /\p{P}/u.test(left) || /\p{P}/u.test(right) ? 'punctuation' : 'content';
    Object.assign(diagnostic, {
      expansionUnicodeSpaceCount: count(text, unicodeSpace), expansionExpectedUnicodeSpaceCount: count(candidate.canonical, unicodeSpace),
      expansionFormatCount: count(text, format), expansionExpectedFormatCount: count(candidate.canonical, format),
      expansionFirstMismatchClass: mismatch,
      ...(diagnostic.expansionASCIIPromptMatches ? {} : {
        expansionFirstMismatchOffset: offset,
        expansionFirstActualCharacter: character(actual),
        expansionFirstExpectedCharacter: character(expected),
      }) });
    candidate.textDiagnostic = { ...diagnostic, ...payload, ...literalDOM };
  } catch { /* A diagnostic cannot change admission or the original error. */ }
}

function chatGPTRejectFirstUserExpansion(candidate, outcome, contextFailure = null) {
  if (outcome === 'text_mismatch') {
    try {
      const raw = candidate.body.innerText || candidate.body.textContent || '';
      chatGPTLatchExpansionTextDiagnostic(candidate, typeof raw === 'string' && raw.length <= 180_200
        ? raw.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null);
    } catch { /* Preserve the original failure if the physical body vanished. */ }
  }
  if (contextFailure) candidate.contextFailure = contextFailure;
  candidate.outcome = outcome;
  return false;
}
const chatGPTExpansionModelErrors = Object.freeze(['model_unverified', 'model_unavailable', 'model_mismatch',
  'document_changed', 'conversation_changed', 'product_mode_unverified', 'temporary_mode_unverified']);
function chatGPTLatchExpansionModelFailure(candidate, model) {
  // The helper already projects a bounded, content-free picker diagnostic.
  // Retain its first finite cause without changing the expansion rejection.
  try {
    if (candidate.modelFailure || !chatGPTExpansionModelErrors.includes(model.error)) return;
    candidate.modelFailure = { error: model.error };
    if (model.modelDiagnostic?.kind === 'model_picker_structure' && model.modelDiagnostic.provider === 'chatgpt'
      && JSON.stringify(model.modelDiagnostic).length <= 8_192)
      candidate.modelFailure.modelDiagnostic = model.modelDiagnostic;
  } catch { /* A diagnostic cannot change admission or the original error. */ }
}
function chatGPTRejectFirstUserExpansionContext(candidate) {
  const failure = chatGPTFirstUserExpansionContextFailure(candidate);
  return chatGPTRejectFirstUserExpansion(candidate,
    failure ? ['root', 'body'].includes(failure) ? 'node_changed' : 'context_changed' : 'text_mismatch', failure);
}
async function chatGPTObserveFirstUserExpansion(candidate) {
  websiteModelDiagnosticPhase('first_user_expand');
  const reject = outcome => chatGPTRejectFirstUserExpansion(candidate, outcome);
  if (!Number.isFinite(candidate.deadline) || Date.now() > candidate.deadline)
    return chatGPTRejectFirstUserExpansion(candidate, 'timeout', 'deadline');
  const currentText = () => {
    const value = candidate.body.innerText || candidate.body.textContent || '';
    return typeof value === 'string' && value.length <= 180_200
      ? value.replace(/\r\n?/g, '\n').normalize('NFC').trim() : null;
  };
  const facts = () => chatGPTFirstUserExpansionTextFacts(candidate, currentText());
  const changed = await websiteModelWaitForChange(candidate.deadline, () => {
    if (!chatGPTFirstUserExpansionContext(candidate)) return true;
    const observed = facts();
    return !observed || observed.complete || !observed.compatible;
  }, 'first_user_expand_wait');
  const contextFailure = chatGPTFirstUserExpansionContextFailure(candidate);
  // A crossed route cannot hide a changed message and later revive it. Only
  // the same complete body or a still-compatible prefix is a URL-only failure.
  if (contextFailure === 'url' && facts()?.compatible !== true) return reject('text_mismatch');
  if (contextFailure) return chatGPTRejectFirstUserExpansionContext(candidate);
  if (!changed || Date.now() > candidate.deadline) return chatGPTRejectFirstUserExpansion(candidate, 'timeout', 'deadline');
  const expandedText = currentText();
  if (chatGPTFirstUserExpansionTextFacts(candidate, expandedText)?.complete !== true) return reject('text_mismatch');
  chatGPTLatchExpansionTextDiagnostic(candidate, expandedText);
  candidate.expandedText = expandedText;
  candidate.outcome = 'expanded';
  return true;
}
async function chatGPTContinueFirstUserExpansion(candidate) {
  const edges = input.firstUserExpansionRouteContinuation;
  const validChain = Array.isArray(edges) && edges.length >= 1 && edges.length <= 2
    && Object.keys(edges).join(',') === (edges.length === 1 ? '0' : '0,1')
    && edges.every((edge, index) => edge && !Array.isArray(edge) && typeof edge === 'object'
      && Object.keys(edge).sort().join(',') === 'fromURL,toURL'
      && typeof edge.fromURL === 'string' && typeof edge.toURL === 'string' && edge.fromURL !== edge.toURL
      && (index === 0 || edges[index - 1].toURL === edge.fromURL))
    && new Set([edges[0].fromURL, ...edges.map(edge => edge.toURL)]).size === edges.length + 1;
  const starts = validChain ? edges.flatMap((edge, index) => edge.fromURL === candidate.routeURL ? [index] : []) : [];
  // The local display can finish before a later digest/model read crosses the
  // route. Native still discards that read and certifies the same first-route
  // edge. Preserve only its already-completed, exact physical body; a failed or
  // still-pending expansion keeps its original bounded observation path below.
  const completed = candidate.outcome === 'expanded' && candidate.contextFailure == null
    && typeof candidate.expandedText === 'string' && candidate.expandedText === candidate.canonical
    && normalizedFirstBody(candidate.body) === candidate.expandedText;
  const interrupted = candidate.outcome === 'context_changed' && candidate.contextFailure === 'url';
  if (input.action !== 'inspect' || input.allowFirstUserExpansion !== true || input.allowFirstUserBinding !== true
    || input.expectedFirstUserFingerprint != null || globalThis.__computaModelFirstProof != null
    || !validChain || starts.length !== 1 || edges.at(-1).toURL !== input.expectedURL || edges.at(-1).toURL !== document.URL
    || candidate.clicked !== true || !completed && !interrupted
    || !websiteModelChoiceEqual(candidate.modelChoice, input.firstUserExpansionModelChoice))
    return chatGPTRejectFirstUserExpansion(candidate, 'context_changed', 'continuation');
  if (!chatGPTFirstUserExpansionContext(candidate)) return chatGPTRejectFirstUserExpansionContext(candidate);
  // Consume only the unconsumed suffix of the exact native-certified chain.
  // A route may have promoted before this read or before the previous script
  // consumed its receipt. Neither the deadline nor click claim is reset.
  for (const edge of edges.slice(starts[0])) candidate.routeURL = edge.toURL;
  candidate.contextFailure = null;
  // Display completion does not grant lineage. The caller must still hash the
  // unchanged body and complete the ordinary current model/product/temporary
  // guards before installing any first-user proof. Do not wait or click again.
  if (completed) return true;
  candidate.outcome = 'claimed';
  try { return await chatGPTObserveFirstUserExpansion(candidate); }
  catch { return chatGPTRejectFirstUserExpansion(candidate, 'failed'); }
}
async function chatGPTExpandFirstUser(candidate) {
  // One private claim survives timeout/reinspection. It grants only this local
  // display expansion, never Send, lineage, cleanup, or another attempt.
  globalThis.__computaModelFirstExpansion = candidate;
  const reject = outcome => chatGPTRejectFirstUserExpansion(candidate, outcome);
  try {
    const intact = () => chatGPTFirstUserExpansionContext(candidate)
      && normalizedFirstBody(candidate.body) === candidate.rendered;
    // Only descendants of the captured physical message can receive a click.
    // The wider diagnostic ancestry never grants mutation authority.
    const localControls = () => chatGPTFirstUserExpandControls(candidate.root, [candidate.root], 0);
    const controls = localControls();
    const control = controls.length === 1 ? controls[0] : null;
    const available = () => !!control && (control.tagName === 'BUTTON' || control.getAttribute('role') === 'button')
      && !control.disabled && control.getAttribute('aria-disabled') !== 'true'
      && getComputedStyle(control).pointerEvents !== 'none'
      && localControls().length === 1 && localControls()[0] === control;
    if (!intact()) return chatGPTRejectFirstUserExpansionContext(candidate);
    if (!control) return reject(controls.length ? 'ambiguous' : 'unavailable');
    if (!available()) return reject('disabled');
    const model = await websiteModelReadEvidence('chatgpt', input.firstUserExpansionModelChoice, null,
      { scope: 'action_precheck', action: input.action });
    if (model.error) {
      chatGPTLatchExpansionModelFailure(candidate, model);
      return reject('model_unverified');
    }
    if (!intact()) return chatGPTRejectFirstUserExpansionContext(candidate);
    if (!available()) return reject('unavailable');
    if (!chatGPTControlExposed(control)) {
      const rect = control.getBoundingClientRect();
      const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
      // A center inside the window can still be clipped by a nested scroller
      // or covered. One scroll may expose it; the same hit test must then pass.
      const scrollable = [rect.left, rect.top, x, y, rect.width, rect.height].every(Number.isFinite)
        && rect.width > 0 && rect.height > 0;
      if (!scrollable || typeof control.scrollIntoView !== 'function') return reject('obstructed');
      control.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
      if (!intact()) return chatGPTRejectFirstUserExpansionContext(candidate);
      if (!available()) return reject('unavailable');
    }
    if (!intact()) return chatGPTRejectFirstUserExpansionContext(candidate);
    if (!chatGPTControlExposed(control)) return reject('obstructed');
    candidate.clicked = true;
    candidate.deadline = Date.now() + 1_800;
    control.click();
    return await chatGPTObserveFirstUserExpansion(candidate);
  } catch { return reject('failed'); }
}
// An optional scheduling observation for the terminal native product recheck.
// It neither prepares/claims a message nor replaces submit's ordinary checks.
function chatGPTPreparedEditorReadinessResult(observed) {
  try {
    const request = input.firstInstantPreparedEditorReadiness;
    if (!request || typeof request !== 'object' || Array.isArray(request)
      || Object.keys(request).sort().join(',') !== 'fingerprint,marker,sequence'
      || request.sequence !== 1 || typeof request.marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(request.marker)
      || typeof request.fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(request.fingerprint)
      || input.action !== 'verifyProductMode' || observed.error || observed.temporary !== true
      || !chatGPTProductModeProof() || !chatGPTTemporaryVerified()
      || !websiteChatInvocationLease || globalThis.__computaChatActiveInvocation !== websiteChatInvocationLease
      || websiteChatInvocationLease.document !== document || window !== window.top
      || location.origin !== 'https://chatgpt.com' || document.URL !== input.expectedURL
      || globalThis.__computaModelOwner !== input.ownerToken
      || input.expectedFirstUserMarker !== request.marker || input.expectedFirstUserFingerprint != null
      || input.expectedConversation != null || globalThis.__computaModelFirstProof != null
      || globalThis.__computaModelFirstSubmitted === true || globalThis.__computaModelLastSubmissionCount != null
      || !Array.isArray(input.expectedUserCounts) || input.expectedUserCounts.length !== 1 || input.expectedUserCounts[0] !== 0
      || !Array.isArray(input.expectedSubmissionProofs) || input.expectedSubmissionProofs.length !== 0
      || chatGPTMessageRoots('user').length !== 0 || chatGPTMessageRoots('assistant').length !== 0) return observed;
    const state = globalThis.__computaChatSubmissionState, pending = state?.pending;
    const expected = globalThis.__computaModelFirstPrompt;
    if (!state || state.document !== document || state.owner !== input.ownerToken || state.revoked
      || state.firstMarker !== request.marker || state.lastVerified != null
      || state.modelChoice?.key !== 'chat/latest/instant' || !websiteModelChoiceValid(state.modelChoice)
      || !pending || pending.document !== document || pending.owner !== input.ownerToken
      || pending.sequence !== request.sequence || pending.marker !== request.marker || pending.fingerprint !== request.fingerprint
      || pending.phase !== 'prepared' || pending.root !== null || pending.body !== null || pending.expansionAttempted !== false
      || typeof expected !== 'string' || expected.length > 180_000
      || !expected.endsWith(`\n\nComputa session marker: ${request.marker}`)
      || chatGPTSubmissionCanonical(expected) !== pending.canonical) return observed;
    const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
      && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
    const enabled = node => visible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true';
    const nodes = selectors => [...new Set(selectors.flatMap(selector => [...document.querySelectorAll(selector)]))].filter(visible);
    const editors = nodes(['#prompt-textarea[contenteditable="true"]', 'textarea#prompt-textarea',
      '#prompt-textarea [contenteditable="true"]', '[contenteditable="true"][aria-label="Ask ChatGPT"]', 'textarea[data-testid="prompt-textarea"]']);
    const sends = nodes(['button[data-testid="send-button"]', 'button[aria-label="Send prompt"]',
      'button[aria-label="Send message"]', 'button[aria-label="Send"]']);
    const stops = nodes(['button[data-testid="stop-button"]', 'button[aria-label="Stop streaming"]',
      'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]']);
    const editor = editors.length === 1 ? editors[0] : null, send = sends.length === 1 ? sends[0] : null;
    const value = editor instanceof HTMLTextAreaElement ? editor.value : editor?.innerText;
    // Keep raw submit equality as well as the pending record's canonical identity.
    const actual = typeof value === 'string' && value.length <= 180_200 ? value.replace(/\r\n/g, '\n').trim() : null;
    // The contenteditable can be much taller than its clipped scroll viewport.
    // Its center need not be onscreen; Send must still be physically exposed.
    const ready = enabled(editor) && enabled(send) && chatGPTControlExposed(send)
      && stops.length === 0 && actual !== null && actual === expected.trim()
      && chatGPTSubmissionCanonical(value) === pending.canonical;
    return { ...observed, firstInstantPreparedEditorReadiness: { sequence: pending.sequence,
      marker: pending.marker, fingerprint: pending.fingerprint, ready: !!ready } };
  } catch { return observed; }
}
function chatGPTFirstUserBodyObservation(root, body, rendered, markerLine, roots) {
  try {
    const limit = 220_000, result = {};
    let selected = null, selection = root ? 'root_fallback' : 'none';
    if (root) {
      for (const [selector, kind] of [['[data-markdown-text-style="user-message"]', 'markdown_user_message'],
        ['.whitespace-pre-wrap', 'whitespace_pre_wrap'], ['[data-message-author-role="user"]', 'author_user']]) {
        selected = root.querySelector(selector);
        if (selected) { selection = kind; break; }
      }
      selected ||= root;
      if (selected !== body) selection = 'unmatched';
    }
    result.bodySelection = selection;
    Object.assign(result, chatGPTProductProofFailureDiagnostic());
    Object.assign(result, globalThis.__computaModelFirstExpansion?.textDiagnostic || {});
    const outcome = globalThis.__computaModelFirstExpansion?.outcome;
    if (chatGPTFirstUserExpansionAdmissionFailure !== null)
      result.expansionAdmissionFailure = chatGPTFirstUserExpansionAdmissionFailure;
    result.expansionOutcome = ['unavailable', 'ambiguous', 'disabled', 'obstructed', 'claimed', 'model_unverified',
      'timeout', 'context_changed', 'node_changed', 'text_mismatch', 'expanded', 'failed'].includes(outcome)
      ? outcome : input.allowFirstUserExpansion === true ? 'ineligible' : 'not_requested';
    const contextFailure = globalThis.__computaModelFirstExpansion?.contextFailure;
    if (['frame', 'provider', 'origin', 'owner', 'user_count', 'submission', 'submission_count', 'marker', 'prompt',
      'private_pin', 'product', 'temporary', 'root', 'body', 'conversation_route', 'conversation_identity', 'url',
      'continuation', 'deadline'].includes(contextFailure)) result.expansionContextFailure = contextFailure;
    const modelError = globalThis.__computaModelFirstExpansion?.modelFailure?.error;
    if (chatGPTExpansionModelErrors.includes(modelError)) result.expansionModelError = modelError;
    const length = (key, value) => { if (typeof value === 'string') result[key] = Math.min(value.length, limit + 1); };
    const normalized = value => value.replace(/\r\n?/g, '\n').normalize('NFC').trim();
    const alternate = (prefix, value, lengthKey = prefix + 'Length') => {
      length(lengthKey, value);
      const available = typeof value === 'string' && value.length <= limit;
      result[prefix + 'Analyzed'] = available;
      if (!available) return;
      const text = normalized(value);
      // Count literal occurrences too: an adjacent control can remove the
      // marker's line boundary without removing the marker from this DOM text.
      result[prefix + 'MarkerOccurrences'] = markerLine === null ? 0 : Math.min(text.split(markerLine).length - 1, 1_000);
      result[prefix + 'MarkerFinalLine'] = markerLine !== null && text.split('\n').at(-1) === markerLine;
    };
    const innerText = body?.innerText, textContent = body?.textContent;
    const rootInnerText = root?.innerText, rootTextContent = root?.textContent;
    length('bodyInnerTextLength', innerText);
    alternate('bodyTextContent', textContent);
    const rootRendered = typeof rootInnerText === 'string' && rootInnerText ? rootInnerText : rootTextContent;
    alternate('rootRendered', rootRendered, 'rootRenderedTextLength');
    alternate('rootTextContent', rootTextContent);
    const firstPrompt = globalThis.__computaModelFirstPrompt;
    length('firstPromptLength', firstPrompt);
    result.firstPromptAnalyzed = typeof firstPrompt === 'string' && firstPrompt.length <= limit;
    if (result.firstPromptAnalyzed && typeof rendered === 'string' && rendered.length <= limit)
      result.renderedPrefixOfFirstPrompt = normalized(firstPrompt).startsWith(rendered);

    // Look only inside the first physical message and at most three local
    // wrappers containing that message alone. Never search main/body/sidebar.
    result.scopedExpandControlCount = Math.min(chatGPTFirstUserExpandControls(root, roots).length, 1_000);
    return result;
  } catch { return {}; }
}
// Diagnostics are a finite, best-effort projection. They never authorize an
// action, await, or publish page text, private pins, attributes, or addresses.
function chatGPTFirstUserStructure(reason, scope, captured = {}, allowSubmittedUser = false, fingerprint = firstUserFingerprint) {
  try {
    const reasons = ['first_bound', 'marker_invalid', 'submission_unclaimed', 'marker_mismatch', 'body_limit',
      'marker_not_final', 'marker_duplicate', 'body_empty', 'snapshot_before_action', 'pinned_fingerprint',
      'native_fingerprint', 'binding_not_authorized', 'first_missing', 'snapshot_after_action', 'first_insert', 'first_submit'];
    const scopes = ['marker_validation', 'digest', 'model_precheck', 'binding', 'action_final_guard', 'first_insert', 'first_submit', 'first_missing'];
    const actions = ['inspect', 'ensureChatMode', 'verifyProductMode', 'enableTemporary', 'discoverModels', 'selectModel',
      'modelDiagnostic', 'verifyModel', 'prepare', 'insert', 'sendReady', 'submit', 'stop', 'cleanup'];
    const resolvedReason = typeof reason === 'function' ? reason() : reason;
    if (!reasons.includes(resolvedReason) || !scopes.includes(scope) || !actions.includes(input.action)) return undefined;
    const roots = captured.roots || chatGPTMessageRoots('user'), root = roots[0];
    const body = captured.body || (root && chatGPTUserBody(root));
    const rendered = typeof captured.rendered === 'string' ? captured.rendered : body ? normalizedFirstBody(body) : '';
    const lines = rendered.split('\n'), marker = input.expectedFirstUserMarker;
    const markerValid = typeof marker === 'string' && /^[a-f0-9-]{36}$/i.test(marker);
    const markerLine = markerValid ? `Computa session marker: ${marker}` : null;
    const tags = ['div', 'span', 'p', 'pre', 'code', 'button', 'section', 'article', 'a', 'strong', 'em', 'ol', 'ul', 'li', 'br', 'input', 'textarea'];
    const shape = node => ({ tag: !node ? 'none' : tags.includes(node.tagName?.toLowerCase()) ? node.tagName.toLowerCase() : 'other', classes: [] });
    const pinned = globalThis.__computaModelFirstProof;
    const diagnostic = { kind: 'first_user_structure', provider: 'chatgpt', reason: resolvedReason, scope, action: input.action,
      userCount: Math.min(roots.length, 1_000), root: shape(root), body: shape(body),
      textLength: Math.min(rendered.length, 220_001), lineCount: Math.min(lines.length, 220_001),
      markerFinalLine: markerLine !== null && lines.at(-1) === markerLine,
      markerOccurrences: Math.min(markerLine === null ? 0 : lines.filter(line => line === markerLine).length, 1_000),
      controlDescendants: Math.min(body ? body.querySelectorAll('button, [role="button"]').length : 0, 1_000),
      submitted: globalThis.__computaModelFirstSubmitted === true, markerMatches: globalThis.__computaModelFirstMarker === marker,
      markerValid, allowFirstUserBinding: input.allowFirstUserBinding === true, allowFirstUserExpansion: input.allowFirstUserExpansion === true,
      privatePinPresent: pinned != null, expectedFingerprintPresent: input.expectedFirstUserFingerprint != null };
    Object.assign(diagnostic, chatGPTFirstUserBodyObservation(root, body, rendered, markerLine, roots));
    if (scope === 'first_insert' || scope === 'first_submit') {
      diagnostic.firstPromptPresent = typeof globalThis.__computaModelFirstPrompt === 'string';
      diagnostic.firstPromptMatches = globalThis.__computaModelFirstPrompt === input.prompt;
    }
    if (typeof fingerprint === 'string') {
      if (typeof pinned?.fingerprint === 'string') diagnostic.pinnedFingerprintMatch = pinned.fingerprint === fingerprint;
      if (typeof input.expectedFirstUserFingerprint === 'string') diagnostic.nativeFingerprintMatch = input.expectedFirstUserFingerprint === fingerprint;
    }
    if (firstSnapshot) diagnostic.snapshot = { rootSame: root === firstSnapshot.root,
      bodySame: !!root && chatGPTUserBody(root) === firstSnapshot.body, bodyConnected: firstSnapshot.body.isConnected,
      textSame: normalizedFirstBody(firstSnapshot.body) === firstSnapshot.text,
      countSame: roots.length === ownedUserCount || allowSubmittedUser && roots.length === ownedUserCount + 1,
      urlSame: document.URL === input.expectedURL, originSame: location.origin === 'https://chatgpt.com',
      ownerSame: globalThis.__computaModelOwner === input.ownerToken };
    const serialized = JSON.stringify(diagnostic);
    return serialized.length <= 8_192 ? serialized : undefined;
  } catch { return undefined; }
}
function chatGPTFirstUserFailure(reason, scope, captured = {}, allowSubmittedUser = false, fingerprint = firstUserFingerprint) {
  // The outer snapshot guard can repeat the same first-user rejection after an
  // inner model precheck. Keep its first finite cause without changing either guard.
  const debugStructure = firstUserRejectionDiagnostic
    || chatGPTFirstUserStructure(reason, scope, captured, allowSubmittedUser, fingerprint);
  if (debugStructure) firstUserRejectionDiagnostic = debugStructure;
  const modelDiagnostic = globalThis.__computaModelFirstExpansion?.modelFailure?.modelDiagnostic;
  return { error: 'conversation_changed', detail: 'first_user_message', ...(debugStructure ? { debugStructure } : {}),
    ...(modelDiagnostic ? { modelDiagnostic } : {}) };
}
const snapshotUnchanged = (allowSubmittedUser = false) => {
  const current = chatGPTMessageRoots('user');
  return window === window.top && location.origin === "https://chatgpt.com" && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken
    && (current.length === ownedUserCount || allowSubmittedUser && current.length === ownedUserCount + 1)
    && current[0] === firstSnapshot.root && firstSnapshot.body.isConnected
    && chatGPTUserBody(current[0]) === firstSnapshot.body
    && normalizedFirstBody(firstSnapshot.body) === firstSnapshot.text;
};
const finalReadContextFailure = observed => {
  // A rejected picker read already prevents admission. Preserve its precise
  // diagnostics and the existing outer lineage-error ordering.
  if (observed.error || input.expectedModelChoice == null && input.action !== 'verifyProductMode'
    || !['prepare', 'verifyModel', 'verifyProductMode'].includes(input.action)) return null;
  if (window !== window.top || location.origin !== 'https://chatgpt.com' || document.URL !== input.expectedURL
    || globalThis.__computaModelOwner !== input.ownerToken)
    return { error: 'document_changed', detail: 'model_read_context' };
  // Verification retains the explicit acknowledged-append branch below.
  // Preparation cannot acquire a new message while its final proof awaits.
  if (input.action === 'prepare' && chatGPTMessageRoots('user').length !== ownedUserCount)
    return { error: 'conversation_changed', detail: 'user_count' };
  if (input.action === 'verifyProductMode') {
    const product = chatGPTProductModeProof();
    if (!product) return { error: 'product_mode_unverified' };
    // Product-only reads retain provenance before the actual temporary click
    // and while an owned model popup hides its off-temp control. The returned
    // physical temporary boolean is independent; native permits only its
    // narrowly claimed pending picker phase to progress with it false.
    return null;
  }
  if (!chatGPTTemporaryVerified()) return { error: 'temporary_mode_unverified' };
  return null;
};
if (input.pendingSubmissionProductRecheck != null) {
  // The explicitly scoped native post-Send recheck observes product controls
  // only. It precedes native dispatch acknowledgment and cannot bind the newly
  // rendered user, even when the optimistic echo already contains every byte.
  const request = input.pendingSubmissionProductRecheck;
  const state = globalThis.__computaChatSubmissionState, record = state?.pending, parent = state?.lastVerified;
  const first = globalThis.__computaModelFirstProof;
  if (input.action !== 'verifyProductMode' || !request || typeof request !== 'object' || Array.isArray(request)
    || Object.keys(request).sort().join(',') !== 'fingerprint,sequence'
    || !record || record.phase !== 'send_claimed' || record.root != null || record.body != null
    || record.expansionAttempted !== false || request.sequence !== record.sequence || request.fingerprint !== record.fingerprint
    || input.submissionSequence !== record.sequence || input.submissionMarker !== record.marker
    || !chatGPTSubmissionPins(record) || record.document !== document || record.owner !== state.owner
    || !chatGPTSubmissionContext(state) || ![record.sequence - 1, record.sequence].includes(ownedUserCount)
    || (record.sequence === 1
      ? parent != null || first != null || input.expectedFirstUserFingerprint != null || globalThis.__computaModelLastSubmissionCount !== 0
      : !parent || parent.sequence !== record.sequence - 1 || !chatGPTSubmissionPins(parent)
        || !chatGPTSubmissionBodyIntact(parent, ownedMessages) || !first || first.marker !== input.expectedFirstUserMarker
        || first.fingerprint !== input.expectedFirstUserFingerprint
        || globalThis.__computaModelLastSubmissionCount !== record.sequence - 1))
    return chatGPTSubmissionFailure(state, 'observe_product_ack', record);
  if (ownedUserCount === record.sequence) {
    const root = ownedMessages[record.sequence - 1], body = root && chatGPTUserBody(root);
    const rendered = body && chatGPTSubmissionCanonical(body.innerText || body.textContent || '');
    if (!root?.isConnected || !body?.isConnected || !rendered || rendered !== record.canonical
      && (rendered.length >= record.canonical.length || !record.canonical.startsWith(rendered)
        || rendered.includes(`Computa session marker: ${record.marker}`)))
      return chatGPTSubmissionFailure(state, 'observe_product_ack_body', record);
  }
  const product = chatGPTProductModeAction(input);
  return product.error ? product : { ...product, temporary: chatGPTTemporaryVerified() };
}
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker;
  const first = chatGPTUserBody(ownedMessages[0]);
  let rendered = normalizedFirstBody(first);
  const firstSubmissionState = globalThis.__computaChatSubmissionState;
  const firstPending = firstSubmissionState?.pending;
  if (firstPending?.sequence === 1 && firstPending.phase === 'send_claimed') {
    const optimistic = chatGPTOptimisticSubmissionPending(firstSubmissionState, firstPending,
      ownedMessages, ownedMessages[0], first, rendered);
    if (optimistic) return optimistic;
  }
  const consumedExpansion = globalThis.__computaModelFirstExpansion;
  let expansionRejected = false;
  if (globalThis.__computaModelFirstProof == null && consumedExpansion != null
    && input.firstUserExpansionRouteContinuation != null) {
    expansionRejected = !await chatGPTContinueFirstUserExpansion(consumedExpansion);
    rendered = normalizedFirstBody(first);
  }
  if (globalThis.__computaModelFirstProof == null && consumedExpansion != null
    && (consumedExpansion.outcome !== 'expanded' || !chatGPTFirstUserExpansionContext(consumedExpansion)
      || consumedExpansion.root !== ownedMessages[0] || consumedExpansion.body !== first
      || consumedExpansion.marker !== marker || rendered !== consumedExpansion.expandedText))
    // A consumed local claim cannot acquire first-message or cleanup authority
    // on a later read after failure, replacement, or a different full body.
    return chatGPTFirstUserFailure('snapshot_before_action', 'digest', { roots: ownedMessages, body: first, rendered });
  let expansion; const expansionStarted = chatGPTSyncWorkStart();
  try { expansion = chatGPTFirstUserExpansionCandidate(ownedMessages[0], first, rendered); }
  finally { chatGPTSyncWorkEnd(4, expansionStarted); }
  if (expansion) {
    expansionRejected = !await chatGPTExpandFirstUser(expansion);
    // A display click can mutate the body before a later guard rejects it.
    // Keep diagnostics current; a failed attempt never falls through to bind.
    rendered = normalizedFirstBody(first);
  }
  const markerLine = `Computa session marker: ${marker}`;
  const renderedLines = rendered.split("\n");
  if (typeof marker !== "string" || !/^[a-f0-9-]{36}$/i.test(marker)
    || globalThis.__computaModelFirstSubmitted !== true || globalThis.__computaModelFirstMarker !== marker
    || rendered.length > 180_200
    || renderedLines.at(-1) !== markerLine || renderedLines.filter(line => line === markerLine).length !== 1
    || !renderedLines.slice(0, -1).join("\n").trim())
    return chatGPTFirstUserFailure(() => typeof marker !== 'string' || !/^[a-f0-9-]{36}$/i.test(marker) ? 'marker_invalid'
      : globalThis.__computaModelFirstSubmitted !== true ? 'submission_unclaimed'
        : globalThis.__computaModelFirstMarker !== marker ? 'marker_mismatch'
          : rendered.length > 180_200 ? 'body_limit' : renderedLines.at(-1) !== markerLine ? 'marker_not_final'
            : renderedLines.filter(line => line === markerLine).length !== 1 ? 'marker_duplicate' : 'body_empty',
      'marker_validation', { roots: ownedMessages, body: first, rendered });
  if (expansionRejected)
    return chatGPTFirstUserFailure('snapshot_before_action', 'digest', { roots: ownedMessages, body: first, rendered });
  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered };
  websiteModelDiagnosticPhase('first_user_hash');
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rendered));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  if (!snapshotUnchanged()) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, chatGPTMessageRoots('user').length,
    { snapshotIntact: snapshotUnchanged(true), fingerprint }, chatGPTTemporaryVerified())
    || await chatGPTFirstReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: () => chatGPTMessageRoots('user'), body: chatGPTUserBody, text: normalizedFirstBody,
        identity: () => null, temporary: chatGPTTemporaryVerified })
    || chatGPTFirstUserFailure('snapshot_before_action', 'digest', {}, false, fingerprint);
  if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
  if (!chatGPTTemporaryVerified()) return { error: "temporary_mode_unverified" };
  firstUserFingerprint = fingerprint;
  const pinned = globalThis.__computaModelFirstProof;
  if (pinned) {
    if (pinned.marker !== marker || pinned.fingerprint !== firstUserFingerprint
      || input.expectedFirstUserFingerprint !== pinned.fingerprint
        && !(input.expectedFirstUserFingerprint == null && input.allowFirstUserBinding === true
          && input.action === "inspect" && ownedUserCount === 1))
      return chatGPTFirstUserFailure(() => pinned.marker !== marker ? 'marker_mismatch'
        : pinned.fingerprint !== firstUserFingerprint ? 'pinned_fingerprint' : 'native_fingerprint', 'binding');
  } else {
    // Only the native pending first submission may bind rendered lineage.
    // Markdown is lossy; exact outbound bytes were checked before one Send.
    if (input.action !== "inspect" || input.allowFirstUserBinding !== true || ownedUserCount !== 1
      || input.expectedFirstUserFingerprint != null)
      return chatGPTFirstUserFailure('binding_not_authorized', 'binding');
  }
  // Pin only after this same document still confirms the owned temporary chat.
  const observed = await websiteModelFinalGuard('chatgpt', input, await chatGPTGuardedPageAction(input, firstUserFingerprint), chatGPTTemporaryVerified);
  if (!observed.error && !chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
  const readContextFailure = finalReadContextFailure(observed);
  if (readContextFailure) return readContextFailure;
  if (observed.error === 'first_user_observation_replaced') return observed;
  if (['inspect', 'verifyModel', 'verifyProductMode'].includes(input.action) && chatGPTMessageRoots('user').length !== ownedUserCount) {
    const append = websiteModelAcknowledgedUserAppend(input, ownedUserCount, chatGPTMessageRoots('user').length,
      { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint }, chatGPTTemporaryVerified());
    if (append) return append;
  }
  if (!snapshotUnchanged(input.action === "submit"))
    return await chatGPTFirstReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: () => chatGPTMessageRoots('user'), body: chatGPTUserBody, text: normalizedFirstBody,
        identity: () => null, temporary: chatGPTTemporaryVerified })
      || chatGPTFirstUserFailure('snapshot_after_action', 'action_final_guard', {}, input.action === 'submit');
  if (observed.error) return observed;
  if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
  if (!chatGPTTemporaryVerified()) return { error: "temporary_mode_unverified" };
  if (!pinned) {
    if (observed.temporary !== true) return { error: "temporary_mode_unverified" };
    globalThis.__computaModelFirstProof = { marker, fingerprint: firstUserFingerprint };
  }
  firstUserVerified = true;
  // Native may adopt the first fingerprint in a nested inspect after an outer
  // read already pinned JS lineage. Carry this metadata until native binding;
  // its existing once-per-session log gate decides which read records it.
  const firstUserDebugStructure = input.action === 'inspect' && input.allowFirstUserBinding === true
    && input.expectedFirstUserFingerprint == null && ownedUserCount === 1
      ? chatGPTFirstUserStructure('first_bound', 'binding') : undefined;
  const result = { ...observed, firstUserVerified, firstUserFingerprint, firstUserMarkerVerified: true,
    ...(firstUserDebugStructure ? { firstUserDebugStructure } : {}) };
  return chatGPTPreparationResult(chatGPTFinalizeResponseRead(globalThis.__computaChatSubmissionState != null ? await chatGPTSubmissionResult(input, result) : result));
}
if (input.expectedFirstUserFingerprint != null)
  return chatGPTFirstUserFailure('first_missing', 'first_missing');
chatGPTPreparationRecord('outerSetupMs', chatGPTPreparationTiming.started);
const observed = await websiteModelFinalGuard('chatgpt', input, await chatGPTGuardedPageAction(input), chatGPTTemporaryVerified);
const outerFinalizationStarted = chatGPTPreparationNow();
if (!observed.error && observed.chatModeReady && !chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
const readContextFailure = finalReadContextFailure(observed);
if (readContextFailure) return readContextFailure;
if (['inspect', 'verifyModel', 'verifyProductMode'].includes(input.action) && chatGPTMessageRoots('user').length !== ownedUserCount)
  return websiteModelAcknowledgedUserAppend(input, ownedUserCount, chatGPTMessageRoots('user').length, null, chatGPTTemporaryVerified())
    || { error: 'conversation_changed', detail: 'user_count' };
const result = { ...observed, firstUserVerified, firstUserFingerprint };
const finalized = chatGPTFinalizeResponseRead(globalThis.__computaChatSubmissionState != null ? await chatGPTSubmissionResult(input, result) : result);
chatGPTPreparationRecord('outerFinalizationMs', outerFinalizationStarted);
return chatGPTPreparationResult(chatGPTPreparedEditorReadinessResult(finalized));
