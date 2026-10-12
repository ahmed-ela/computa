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
function websiteChatTrackPinnedControls(pin, state) {
  if (!pin || pin.owner !== globalThis.__computaModelOwner || pin.document !== document
    || !websiteChatFamilyValid(pin.selection?.family) || !websiteChatPowerValid(pin.selection?.power)) return;
  pin.controls = pin.controls || new WeakMap();
  if (state.slider) pin.controls.set(state.slider, { attribute: 'aria-valuenow',
    value: String(websiteChatPowers.findIndex(power => power.key === pin.selection.power.key)) });
  for (const control of state.familyControls) pin.controls.set(control.node,
    { attribute: 'aria-checked', value: String(control.choice?.key === pin.selection.family.key) });
}
function websiteChatObservePinnedMutations(records) {
  const pin = globalThis.__computaChatPresetPin;
  if (!pin || pin.invalidated === true || !pin.controls || pin.owner !== globalThis.__computaModelOwner
    || pin.document !== document || window !== window.top || location.origin !== 'https://chatgpt.com') return;
  // Track only previously observed semantic controls. Mounting a popup, updating
  // its visibility, or setting the same selected value cannot invalidate it.
  // Old values preserve an observable switch-and-restore in one mutation batch.
  for (const record of records) {
    if (record.type !== 'attributes') continue;
    const expected = pin.controls.get(record.target);
    if (!expected || record.attributeName !== expected.attribute) continue;
    const value = record.target.getAttribute(expected.attribute);
    if (value !== expected.value || record.oldValue != null && record.oldValue !== expected.value) {
      pin.invalidated = true;
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
  return { provider: 'chatgpt', trigger, triggerCount: triggers.length, triggerCandidates, topMenu, secondary,
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
  const until = Date.now() + 1_800;
  const mutable = typeof freshGuard === 'function';
  const owned = () => window === window.top && location.origin === 'https://chatgpt.com'
    && document === originalDocument && document.URL === url && globalThis.__computaModelOwner === owner
    && owner === request.ownerToken && websiteChatInvocationLease != null
    && globalThis.__computaChatActiveInvocation === websiteChatInvocationLease
    && (!mutable || freshGuard(false) === true);
  let trigger = null, selectionChanged = false, dismissedPopup = null, readStage = 'initial_observation';
  let primaryOpened = false, secondaryOpened = false, closeAttempted = false, observedProof = false;
  const tracked = new Map();
  const observer = new MutationObserver(records => {
    if (mutable) return;
    if (records.some(record => {
      if (record.type !== 'attributes' || !tracked.has(record.target)
        || !['aria-valuenow', 'aria-checked', 'aria-selected'].includes(record.attributeName)) return false;
      const expected = tracked.get(record.target)[record.attributeName];
      return record.target.getAttribute(record.attributeName) !== expected
        || record.oldValue != null && record.oldValue !== expected;
    })) selectionChanged = true;
  });
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
        selectionSettled: selection?.completed === true, selectionCompleted: selection?.completed === true, recoveryEligible: false },
      readAttempt: { primaryOpened, secondaryOpened, closeAttempted, observedProof,
        sameTrigger: !trigger || current.trigger === trigger, popupStillAssociated: !!current.topMenu } }) };
  };
  const state = () => {
    if (!owned()) throw failure('document_changed');
    const pin = globalThis.__computaChatPresetPin;
    if (selectionChanged || pin?.owner === owner && pin.document === document && pin.invalidated === true)
      throw failure('model_mismatch');
    const current = websiteChatPickerState();
    if (current.triggerCount !== 1 || !current.trigger || trigger && current.trigger !== trigger
      || current.duplicate || current.conflicting || current.indicatorInvalid || current.selectionAmbiguous
      || current.navigationAmbiguous || current.allMenus.some(menu => menu !== current.topMenu)) throw failure('model_unverified');
    if (current.powerUnavailable) throw failure(mutable ? 'model_unavailable' : 'model_unverified');
    trigger = trigger || current.trigger;
    websiteModelTrackReadUI(current);
    for (const node of [current.slider, ...current.familyControls.map(control => control.node)].filter(Boolean))
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
    && [null, 'closed'].includes(trigger.getAttribute('data-state'));
  const acknowledgeFamilyClose = current => {
    if (!mutable || attempt.familyClicked !== true || attempt.familyCloseAcknowledged === true) return;
    if (!pickerClosed(current) || current.trigger !== attempt.selectionTrigger || freshGuard() !== true)
      throw failure('model_unverified');
    attempt.familyCloseAcknowledged = true;
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
  const powerView = async () => {
    let current = state();
    if (current.mode === 'power') return current;
    if (current.topMenu) { await close(); current = state(); }
    if (!current.enabled(trigger)) throw failure('model_unverified');
    const recoveryEligible = mutable && attempt.familyCloseAcknowledged === true
      && attempt.postFamilyOpeningClaimed !== true;
    if (recoveryEligible) attempt.postFamilyOpeningClaimed = true;
    primaryOpened = true; readStage = 'primary_open_requested';
    trigger.click();
    const powerAcknowledged = () => {
      const observed = websiteChatPickerState();
      return observed.mode === 'power' || observed.powerUnavailable;
    };
    if (recoveryEligible) {
      // Preserve the existing fresh post-family allowance within the original
      // deadline. A consumed opening grants only one new chrome action, never
      // selection proof, a family/power retry, or an established-read replay.
      const acknowledged = await websiteModelWaitForChange(Math.min(until, Date.now() + 900),
        () => !owned() || powerAcknowledged());
      if (!owned()) throw failure('document_changed');
      current = state();
      if (!acknowledged) {
        if (Date.now() >= until || attempt.openingRecoveryAttempted === true || freshGuard() !== true
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
    current = await powerView();
    if (!current.secondary) throw failure('model_unverified');
    secondaryOpened = true; readStage = 'secondary_open_requested';
    current.secondary.click();
    return wait(() => websiteChatPickerState().mode === 'family');
  };
  const changePower = async target => {
    let current = await powerView();
    while (current.powerIndex !== target) {
      if (!mutable || Date.now() >= until || typeof window.KeyboardEvent !== 'function') throw failure('model_mismatch');
      const before = current.powerIndex, direction = target > before ? 1 : -1;
      if (attempt.powerEvents >= 4) throw failure('model_unverified');
      const powerItem = current.powerItem, slider = current.slider;
      powerItem.focus?.({ preventScroll: true });
      current = state();
      if (current.powerItem !== powerItem || current.slider !== slider || current.powerIndex !== before
        || !current.enabled(powerItem)) throw failure('model_unverified');
      attempt.powerEvents++;
      const key = direction === 1 ? 'ArrowRight' : 'ArrowLeft';
      powerItem.dispatchEvent(new window.KeyboardEvent('keydown', { key, code: key, bubbles: true, cancelable: true }));
      current = await wait(() => websiteChatPickerState().powerIndex !== before);
      if (current.powerIndex !== before + direction) throw failure('model_unverified');
    }
    return current;
  };
  try {
    let powerState = await powerView();
    const desiredPower = expected ? websiteChatPowers.findIndex(power => 'chat/latest/' + power.key === expected.key) : powerState.powerIndex;
    if (desiredPower < 0 || desiredPower > 4) return failure('model_unverified');
    if (!mutable && powerState.powerIndex !== desiredPower) return failure('model_mismatch');
    let familyState = await familyView();
    if (!familyState.newest) return failure('model_unverified');
    if (mutable && familyState.checkedFamily?.key !== familyState.newest.key) {
      const candidates = familyState.familyControls.filter(control => control.choice?.key === familyState.newest.key);
      if (candidates.length !== 1 || attempt.familyClicked) return failure('model_unverified');
      attempt.familyClicked = true;
      attempt.selectionTrigger = trigger;
      candidates[0].node.click();
      await wait(() => {
        const now = websiteChatPickerState();
        return now.mode !== 'family' || now.checkedFamily?.key === now.newest?.key;
      });
      const afterSelection = state();
      if (afterSelection.topMenu && afterSelection.mode !== 'family') await close();
      else if (!afterSelection.topMenu) await close();
      familyState = await familyView();
    }
    if (!familyState.checkedFamily || familyState.checkedFamily.key !== familyState.newest.key) return failure('model_mismatch');
    const family = familyState.checkedFamily;
    await close();
    powerState = mutable ? await changePower(desiredPower) : await powerView();
    if (powerState.powerIndex !== desiredPower) return failure('model_mismatch');
    // Re-read the checked family under the final power. Availability and the
    // automatic maximum must not be borrowed from another power setting.
    familyState = await familyView();
    if (!familyState.checkedFamily || familyState.checkedFamily.key !== family.key || familyState.newest?.key !== family.key)
      return failure('model_mismatch');
    const offered = familyState.offered, modelDiagnostic = websiteModelDiagnostic(familyState);
    await close();
    powerState = await powerView();
    if (powerState.powerIndex !== desiredPower) return failure('model_mismatch');
    const evidence = websiteChatSelectionEvidence(family, powerState.power, offered, expected);
    if (!evidence || expected && !websiteModelChoiceEqual(expected, evidence.selected)) return failure('model_mismatch');
    observedProof = true; readStage = 'proof_observed';
    await close();
    if (!owned() || selectionChanged || mutable && freshGuard() !== true) return failure('model_unverified');
    const pin = globalThis.__computaChatPresetPin;
    if (pin && (pin.owner !== owner || pin.document !== document || pin.invalidated === true
      || !websiteChatResolvedSelectionEqual(pin.selection, evidence.chatSelection))) return failure('model_mismatch');
    if (expected && !pin) {
      if (!mutable) return failure('model_unverified');
      globalThis.__computaChatPresetPin = { owner, document, selection: evidence.chatSelection };
      websiteChatTrackPinnedControls(globalThis.__computaChatPresetPin, { slider: powerState.slider,
        familyControls: familyState.familyControls });
    }
    return { modelEvidence: evidence, modelChoices: websiteChatPowers.map(power => websiteChatPresetChoice(family, power)), modelDiagnostic };
  } catch (error) {
    return error?.error ? error : failure('model_unverified');
  } finally {
    observer.disconnect?.();
    if (owned()) {
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
    : provider === 'gemini' ? /^[0-9]+(?:\.[0-9]+)? (?:Flash-Lite|Flash|Pro)$/
      : /^(?:Sonnet|Haiku|Opus|Fable) [0-9]+(?:\.[0-9]+)?$/;
  return pattern.test(label) ? label : null;
}
function websiteModelSafeTriggerLabel(value) {
  const label = websiteModelNormalize(value);
  if (!label || label.length > 160 || /[\u0000-\u001F\u007F]/.test(label)) return null;
  if (label === 'Select ChatGPT model') return label;
  if (/^Open mode picker, currently (?:Gemini )?(?:(?:[0-9]+(?:\.[0-9]+)? )?(?:Pro|Flash|Flash-Lite))$/.test(label)) return label;
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
      : provider === 'gemini' ? /^Open mode picker, currently (?:Gemini )?(?:[0-9]+(?:\.[0-9]+)? )?(?:Pro|Flash|Flash-Lite)$/.test(label)
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
  if (state.provider === 'chatgpt') diagnostic.chatPower = state.powerDiagnostic;
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
function websiteModelWaitForChange(until, condition, phase = 'model_wait') {
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
        'aria-selected', 'aria-valuenow', 'aria-valuemin', 'aria-valuemax', 'aria-label', 'aria-disabled', 'disabled', 'data-state', 'role', 'class', 'style', 'hidden', 'inert'] });
    const milliseconds = Math.max(1, Math.min(10_000, Math.ceil(until - Date.now())));
    const clock = window.webkit?.messageHandlers?.computaModelClock;
    if (clock && typeof input?.operationID === 'string') {
      try {
        // A native reply expires this wait only. All existing conditions and
        // model/owner guards must still supply their own positive proof.
        Promise.resolve(clock.postMessage({ ownerToken: input.ownerToken,
          operationID: input.operationID, milliseconds })).then(() => finish(false), () => finish(false));
      } catch { finish(false); }
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
function modelResponseExtraction(answer) {
  const flags = { literalCodeValidJSON: null, literalCodeKnownEnvelopeType: null,
    selectedExtraction: 'rendered_fallback', extractionReason: 'absent_answer' };
  let rendered = '', blocks = [], code = null;
  const fallback = reason => ({ text: rendered, blocks, code, flags: { ...flags, extractionReason: reason } });
  if (!answer) return fallback('absent_answer');
  rendered = (answer.innerText || answer.textContent || '').trim();
  blocks = [...answer.querySelectorAll('pre')];
  if (blocks.length !== 1) return fallback(blocks.length ? 'multiple_pre' : 'missing_pre');
  const codes = [...blocks[0].querySelectorAll('code')];
  if (codes.length !== 1) return fallback(codes.length ? 'multiple_code' : 'missing_code');
  code = codes[0];
  const raw = code.textContent || '';
  if (raw.length > 220_000) return fallback('oversized_code');
  let envelope;
  try { envelope = JSON.parse(raw); flags.literalCodeValidJSON = true; }
  catch { flags.literalCodeValidJSON = false; return fallback('invalid_json'); }
  const knownType = envelope && !Array.isArray(envelope) && ['message', 'tool_calls'].includes(envelope.type);
  flags.literalCodeKnownEnvelopeType = knownType ? envelope.type : 'unknown';
  if (!knownType) return fallback('unknown_envelope_type');
  // Observed Claude code chrome: the language label and icon control are
  // siblings of this sole pre inside the provider's exact code-block wrapper.
  // Only these verified nodes can be skipped; authored surrounding text cannot.
  const wrapper = blocks[0].closest('div.relative.border-border-400');
  const chrome = new Set();
  if (wrapper && wrapper !== answer && answer.contains(wrapper)
    && wrapper.querySelectorAll('pre').length === 1 && wrapper.querySelectorAll('code').length === 1) {
    const labels = [...wrapper.querySelectorAll('div.text-text-500.font-small.pb-0')].filter(node =>
      modelVisible(node) && !node.closest('pre') && node.childElementCount === 0 && (node.textContent || '').trim() === 'json');
    const controls = [...wrapper.querySelectorAll('div.absolute.right-0.h-8.px-2.items-center.inline-flex button.cds-reset.relative.isolate.inline-flex.shrink-0.items-center')]
      .filter(node => modelVisible(node) && !node.closest('pre') && /^[\uE000-\uF8FF]$/u.test((node.textContent || '').trim()));
    if (labels.length === 1 && controls.length === 1) { chrome.add(labels[0]); chrome.add(controls[0]); }
  }
  let visited = 0, scanLimit = false;
  const onlyCodeAndWhitespace = node => {
    if (++visited > 10_000) { scanLimit = true; return false; }
    if (node === code || chrome.has(node)) return true;
    if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
    if (node.nodeType !== 1) return true;
    // Actual controls inside this pre are code-block chrome, never surrounding prose.
    if (node.tagName.toLowerCase() === 'button' && blocks[0].contains(node)) return true;
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

// Fixed Claude DOM adapter. Only native structured input runs this private-world program.
function modelVisible(node) {
  return !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
}
function modelEnabled(node) { return modelVisible(node) && !node.disabled && node.getAttribute('aria-disabled') !== 'true'; }
function modelFind(selectors) { return selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(modelVisible); }
// Website UI labels may split/reset whitespace; message bytes never use this.
function modelQuotaLabel(text) { return (text || '').replace(/\s+/g, ' ').trim(); }
function modelUsageLimitPopup() {
  const messages = '[data-testid="assistant-message"], [data-testid="user-message"]';
  const headings = [...document.querySelectorAll('h1, h2, h3, [role="heading"]')].filter(node => modelVisible(node)
    && !node.closest(messages) && /^Your free messages return at (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/.test(modelQuotaLabel(node.textContent)));
  if (headings.length !== 1) return null;
  // AX exposes this popup as a container, without a verified dialog role.
  // Require the lowest bounded container coupling its heading and both observed
  // non-purchase controls. The Upgrade button's rendered currency is variable.
  let container = headings[0].parentElement;
  for (let depth = 0; container && depth < 8; depth++, container = container.parentElement) {
    if (['body', 'html'].includes(container.tagName.toLowerCase()) || container.closest(messages)
      || container.querySelector(messages)) return null;
    const buttons = [...container.querySelectorAll('button')].filter(node => modelEnabled(node) && !node.closest(messages));
    const named = text => buttons.filter(node => modelQuotaLabel(node.getAttribute('aria-label') || node.innerText || node.textContent) === text);
    const plans = named('See all plans'), dismiss = named('Not now');
    if (plans.length && dismiss.length) return plans.length === 1 && dismiss.length === 1 && modelVisible(container) ? container : null;
  }
  return null;
}
function modelUsageLimitBanner() {
  const messages = '[data-testid="assistant-message"], [data-testid="user-message"]';
  const urlOf = node => { try { return new URL(node.getAttribute('href'), document.URL); } catch { return null; } };
  const support = [...document.querySelectorAll('a[href]')].filter(node => modelVisible(node) && !node.closest(messages)
    && urlOf(node)?.href === 'https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits');
  if (support.length !== 1) return false;
  let container = support[0].parentElement;
  for (let depth = 0; container && depth < 8; depth++, container = container.parentElement) {
    if (['body', 'html'].includes(container.tagName.toLowerCase()) || container.closest(messages)
      || container.querySelector(messages)) return false;
    const upgrades = [...container.querySelectorAll('a[href]')].filter(node => {
      const url = urlOf(node);
      return modelVisible(node) && !node.closest(messages) && url?.origin === 'https://claude.ai' && !url.username && !url.password
        && url.pathname === '/upgrade' && !url.hash && url.searchParams.size === 2
        && url.searchParams.get('hide_free') === 'true' && url.searchParams.get('from') === 'ratelimit';
    });
    const nodes = [container, ...container.querySelectorAll('*')].slice(0, 256);
    const text = nodes.some(node => {
      if (!modelVisible(node) || node.closest(messages)) return false;
      const parts = [...node.childNodes].filter(child => child.nodeType === 1 || child.nodeType === 3);
      // The observed warning has exactly text / official support anchor / text.
      // Anchor bytes never contribute authority: its fixed URL contributes only
      // the constant word "messages" to this abort-only quota classification.
      return parts.length === 3 && parts[0].nodeType === 3 && parts[1] === support[0] && parts[2].nodeType === 3
        && /^You are out of free messages until (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/.test(
          modelQuotaLabel(parts.map(child => child === support[0] ? 'messages' : child.textContent || '').join('')));
    });
    if (text && upgrades.length) return upgrades.length === 1 && modelVisible(container);
  }
  return false;
}
function modelUsageLimited() { return !!modelUsageLimitPopup() || modelUsageLimitBanner(); }
function modelQuotaDiagnostic() {
  const boundary = '[data-testid="assistant-message"], [data-testid="user-message"]';
  const tags = ['a', 'button', 'div', 'span', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'section', 'main', 'body', 'html', 'dialog'];
  const bounded = count => Math.min(count, 1_000);
  const physical = node => !!node && node.isConnected && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden';
  const shape = node => {
    const style = getComputedStyle(node), tag = node.tagName.toLowerCase();
    return { tag: tags.includes(tag) ? tag : 'other', rectCount: bounded(node.getClientRects().length),
      strictVisible: modelVisible(node), physicalVisible: physical(node), inertAncestor: !!node.closest('[inert]'),
      ariaHiddenAncestor: !!node.closest('[aria-hidden="true"]'),
      display: ['none', 'contents'].includes(style.display) ? style.display : 'other',
      visibility: ['visible', 'hidden', 'collapse'].includes(style.visibility) ? style.visibility : 'other' };
  };
  const spaced = /^Your free messages return at (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/;
  const joined = /^Your free messages return at (?:[1-9]|1[0-2]):[0-5][0-9](?:AM|PM)$/;
  const headings = [...document.querySelectorAll('h1, h2, h3, [role="heading"]')].filter(node => !node.closest(boundary)
    && modelQuotaLabel(node.textContent).startsWith('Your free messages return at')).slice(0, 4);
  const popupAncestors = [], candidates = new Set();
  for (let node = headings[0]?.parentElement, depth = 0; node && depth < 8; node = node.parentElement, depth++) {
    const controls = [...node.querySelectorAll('button, [role="button"], a')].filter(control => !control.closest(boundary));
    const exact = label => controls.filter(control => modelQuotaLabel(control.getAttribute('aria-label') || control.innerText || control.textContent) === label).length;
    popupAncestors.push({ ...shape(node), depth, containsMessages: !!node.closest(boundary) || !!node.querySelector(boundary),
      buttonCount: bounded(controls.filter(control => control.tagName.toLowerCase() === 'button').length),
      roleButtonCount: bounded(controls.filter(control => control.getAttribute('role') === 'button').length),
      anchorCount: bounded(controls.filter(control => control.tagName.toLowerCase() === 'a').length),
      upgradeExactCount: bounded(exact('Upgrade to Pro for $20/month')), dismissExactCount: bounded(exact('Not now')) });
    if (['body', 'html'].includes(node.tagName.toLowerCase())) break;
    controls.slice(0, 8).forEach(control => candidates.add(control));
  }
  const controlShape = node => {
    const aria = modelQuotaLabel(node.getAttribute('aria-label')), text = modelQuotaLabel(node.innerText || node.textContent);
    const edges = modelQuotaLabel(text.replace(/^[\s\uE000-\uF8FF]+|[\s\uE000-\uF8FF]+$/g, ''));
    return { ...shape(node), roleButton: node.getAttribute('role') === 'button', ariaLabelPresent: node.getAttribute('aria-label') !== null,
      ariaUpgradeExact: aria === 'Upgrade to Pro for $20/month', ariaDismissExact: aria === 'Not now',
      textUpgradeExact: text === 'Upgrade to Pro for $20/month', textDismissExact: text === 'Not now',
      upgradeEdgePrivateUse: text !== edges && edges === 'Upgrade to Pro for $20/month',
      dismissEdgePrivateUse: text !== edges && edges === 'Not now',
      privateUseCount: bounded((text.match(/[\uE000-\uF8FF]/g) || []).length),
      hasUnknownLabelText: !['Upgrade to Pro for $20/month', 'Not now'].includes(edges) };
  };
  const support = [...document.querySelectorAll('a[href]')].filter(node => {
    if (node.closest(boundary)) return false;
    try { return new URL(node.getAttribute('href'), document.URL).href === 'https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits'; }
    catch { return false; }
  }).slice(0, 4);
  const bannerParents = [];
  for (let node = support[0]?.parentElement, depth = 0; node && depth < 4; node = node.parentElement, depth++) {
    const parts = [...node.childNodes].filter(child => child.nodeType === 1 || child.nodeType === 3);
    const sentence = modelQuotaLabel(parts.map(child => child === support[0] ? 'messages' : child.nodeType === 3 ? child.textContent || '' : '').join(''));
    bannerParents.push({ ...shape(node), supportDirect: parts.includes(support[0]),
      spacedClock: /^You are out of free messages until (?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM)$/.test(sentence),
      joinedClock: /^You are out of free messages until (?:[1-9]|1[0-2]):[0-5][0-9](?:AM|PM)$/.test(sentence),
      children: parts.slice(0, 8).map(child => child.nodeType === 3 ? 'text' : child === support[0] ? 'support' : child.nodeType === 1 ? 'element' : 'other') });
    if (['body', 'html'].includes(node.tagName.toLowerCase())) break;
  }
  const header = [...document.querySelectorAll('.animate-incognito-header-in span')].filter(node => !node.closest(boundary));
  const exit = [...document.querySelectorAll('button[aria-label="Exit incognito"]')].filter(node => !node.closest(boundary));
  const result = { kind: 'quota_structure', provider: 'claude',
    headings: headings.map(node => ({ ...shape(node), spacedClock: spaced.test(modelQuotaLabel(node.textContent)), joinedClock: joined.test(modelQuotaLabel(node.textContent)) })),
    controls: [...candidates].slice(0, 8).map(controlShape), popupAncestors,
    support: support.map(node => ({ ...shape(node), labelExact: modelQuotaLabel(node.textContent) === 'messages',
      labelKnownSuffix: modelQuotaLabel(node.textContent) === 'messages (opens in new tab)' })), bannerParents,
    mode: { headerTotal: bounded(header.length), headerVisible: bounded(header.filter(modelVisible).length), headerPhysical: bounded(header.filter(physical).length),
      exitTotal: bounded(exit.length), exitVisible: bounded(exit.filter(modelVisible).length), exitPhysical: bounded(exit.filter(physical).length) } };
  while (JSON.stringify(result).length > 8_192 && result.popupAncestors.length) result.popupAncestors.pop();
  return JSON.stringify(result);
}
function modelTemporaryFailure(error) { return { error, quotaDiagnostic: modelQuotaDiagnostic() }; }
function modelUserRoots() {
  const nodes = [...document.querySelectorAll('[data-testid="user-message"]')];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
function modelUserBody(root) { return root; }
function modelVisibleDialog(blockingOnly = false) {
  // Accessibility hiding does not prove that a dialog stopped occluding input.
  return [...document.querySelectorAll('[role="dialog"], dialog[open]')].some(node => node.isConnected
    && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden'
    && !node.closest('[data-testid="assistant-message"], [data-testid="user-message"]')
    && (!blockingOnly || node.getAttribute('aria-modal') === 'true'
      || node.tagName.toLowerCase() === 'dialog' && node.getAttribute('open') !== null));
}
function modelTemporaryVerified() {
  // A known quota dialog makes the background inert. Cleanup may inspect its
  // already-rendered mode indicators, while every interactive lookup stays strict.
  const popup = input.action === 'stop' && modelUsageLimitPopup();
  const visible = popup
    ? node => !!node && node.isConnected && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden'
    : modelVisible;
  const outside = '[data-testid="assistant-message"], [data-testid="user-message"], dialog, [role="dialog"], [aria-modal="true"]';
  const exit = [...document.querySelectorAll('button[aria-label="Exit incognito"]')].find(node => visible(node)
    && !node.closest(outside) && (!popup || !popup.contains(node)));
  const url = new URL(document.URL);
  return !!exit && url.searchParams.has('incognito') && url.searchParams.get('incognito') === ''
    && [...document.querySelectorAll('.animate-incognito-header-in span')].some(node => visible(node)
      && !node.closest(outside) && (!popup || !popup.contains(node))
      && (node.textContent || '').trim() === 'Incognito chat');
}
function modelURLAllowed() {
  try {
    const url = new URL(document.URL);
    return url.origin === 'https://claude.ai' && !url.username && !url.password
      && /^\/(?:new|chat\/[A-Za-z0-9-]+)\/?$/.test(url.pathname);
  } catch { return false; }
}
const allowedActions = ['inspect', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'stop', 'discoverModels', 'selectModel', 'modelDiagnostic', 'verifyModel'];
if (input.provider !== 'claude' || window !== window.top || location.origin !== 'https://claude.ai'
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
if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken) {
  const signal = { ownerToken: input.ownerToken, observer: null };
  signal.observer = new MutationObserver(records => {
    if (!records.some(record => !websiteModelIgnoreOwnPickerMutation(record))) return;
    if (window !== window.top || location.origin !== 'https://claude.ai'
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
let usageLimited = modelUsageLimited();
function modelUsageLimitFailure() {
  // This is only an empty initial-page abort receipt, never readiness or Send
  // authority. Count physical roots, including hidden responses, before binding
  // the current document for native cleanup of this exact owned empty tab.
  const pristine = ['FirstSubmitted', 'FirstProof', 'LastSubmissionCount', 'FirstPrompt',
    'FirstMarker', 'FirstPrepared', 'TemporaryRequested'].every(name => globalThis[`__computaModel${name}`] === undefined);
  if (input.action === 'inspect' && ownedUserCount === 0 && input.expectedUserCounts.length === 1
    && input.expectedUserCounts[0] === 0 && pristine && input.expectedFirstUserFingerprint == null
    && location.pathname.replace(/\/$/, '') === '/new'
    && window === window.top && location.origin === 'https://claude.ai' && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken && modelUsageLimited()
    && modelUserRoots().length === 0 && document.querySelectorAll('[data-testid="assistant-message"]').length === 0)
    return { error: 'website_usage_limit', freshQuotaAbort: true, url: document.URL, userCount: 0, responseCount: 0 };
  return { error: 'website_usage_limit' };
}
const normalizedBody = node => (node?.innerText || node?.textContent || '').replace(/\r\n?/g, '\n').normalize('NFC').trim();
let firstSnapshot = null, firstUserFingerprint = null, firstUserIdentity = null;
function modelFirstUserFailure(reason, allowSubmittedUser = false, detail = 'first_user_message') {
  const roots = modelUserRoots(), first = roots[0], body = first && modelUserBody(first), pinned = globalThis.__computaModelFirstProof;
  const marker = input.expectedFirstUserMarker, text = normalizedBody(body), markerLine = typeof marker === 'string'
    && /^[a-f0-9-]{36}$/i.test(marker) ? `Computa session marker: ${marker}` : null;
  const lines = text.split('\n');
  const shape = node => ({ tag: node && /^[A-Za-z][A-Za-z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'none', classes: [] });
  const diagnostic = { kind: 'first_user_structure', provider: 'claude', reason,
    userCount: Math.min(roots.length, 1_000), capturedCount: Math.min(ownedUserCount, 1_000),
    expectedCounts: input.expectedUserCounts.filter(count => Number.isInteger(count) && count >= 0 && count <= 1_000).slice(0, 3),
    root: shape(first), body: shape(body), textLength: Math.min(text.length, 220_001), lineCount: Math.min(lines.length, 220_001),
    controlDescendants: Math.min(body?.querySelectorAll('button, [role="button"]').length || 0, 1_000),
    markerFinalLine: markerLine !== null && lines.at(-1) === markerLine,
    markerOccurrences: Math.min(markerLine === null ? 0 : lines.filter(line => line === markerLine).length, 1_000),
    submitted: globalThis.__computaModelFirstSubmitted === true, markerMatches: globalThis.__computaModelFirstMarker === marker,
    urlSame: document.URL === input.expectedURL, ownerSame: globalThis.__computaModelOwner === input.ownerToken,
    originSame: location.origin === 'https://claude.ai', temporary: modelTemporaryVerified() };
  if (firstUserFingerprint !== null) {
    diagnostic.pinnedFingerprintMatch = pinned?.fingerprint === firstUserFingerprint;
    diagnostic.nativeFingerprintMatch = input.expectedFirstUserFingerprint === firstUserFingerprint;
  }
  if (firstSnapshot) diagnostic.snapshot = { rootSame: first === firstSnapshot.root, bodySame: body === firstSnapshot.body,
    bodyConnected: firstSnapshot.body.isConnected, textSame: normalizedBody(firstSnapshot.body) === firstSnapshot.text,
    identitySame: first?.closest('[id]')?.getAttribute('id') === firstSnapshot.identity,
    countSame: roots.length === ownedUserCount || allowSubmittedUser && roots.length === ownedUserCount + 1,
    urlSame: document.URL === input.expectedURL, originSame: location.origin === 'https://claude.ai', ownerSame: globalThis.__computaModelOwner === input.ownerToken };
  return { error: 'conversation_changed', detail, debugStructure: JSON.stringify(diagnostic) };
}
const snapshotUnchanged = (allowSubmittedUser = false) => {
  const current = modelUserRoots();
  return window === window.top && location.origin === 'https://claude.ai' && document.URL === input.expectedURL
    && globalThis.__computaModelOwner === input.ownerToken
    && (current.length === ownedUserCount || allowSubmittedUser && current.length === ownedUserCount + 1)
    && current[0] === firstSnapshot.root && firstSnapshot.body.isConnected
    && modelUserBody(current[0]) === firstSnapshot.body && normalizedBody(firstSnapshot.body) === firstSnapshot.text
    && firstSnapshot.root.closest('[id]')?.getAttribute('id') === firstSnapshot.identity;
};
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker, first = modelUserBody(ownedMessages[0]);
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
  firstUserIdentity = ownedMessages[0].closest('[id]')?.getAttribute('id');
  if (typeof firstUserIdentity !== 'string' || !firstUserIdentity.length || firstUserIdentity.length > 256)
    return modelFirstUserFailure('identity_invalid');
  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered, identity: firstUserIdentity };
  websiteModelDiagnosticPhase('first_user_hash');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  if (!snapshotUnchanged()) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, modelUserRoots().length,
    { snapshotIntact: snapshotUnchanged(true), fingerprint, identity: firstUserIdentity }, modelTemporaryVerified())
    || await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: modelUserRoots, body: modelUserBody, text: normalizedBody,
        identity: root => root.closest('[id]')?.getAttribute('id'), temporary: modelTemporaryVerified })
    || modelFirstUserFailure('snapshot_before_action');
  usageLimited = modelUsageLimited();
  if (!usageLimited && !modelTemporaryVerified()) return modelTemporaryFailure('temporary_mode_unverified');
  firstUserFingerprint = fingerprint;
  const pinned = globalThis.__computaModelFirstProof;
  if (pinned) {
    if (pinned.marker !== marker || pinned.fingerprint !== firstUserFingerprint
      || pinned.identity !== firstUserIdentity
      || input.expectedFirstUserFingerprint !== pinned.fingerprint
        && !(input.expectedFirstUserFingerprint == null && input.allowFirstUserBinding === true
          && input.action === 'inspect' && ownedUserCount === 1))
      return modelFirstUserFailure(pinned.fingerprint !== firstUserFingerprint ? 'pinned_fingerprint'
        : pinned.identity !== firstUserIdentity ? 'pinned_identity' : input.expectedFirstUserFingerprint !== pinned.fingerprint
          ? 'native_fingerprint' : 'binding_not_authorized');
  } else if (input.action !== 'inspect' || input.allowFirstUserBinding !== true || ownedUserCount !== 1
    || input.expectedFirstUserFingerprint != null)
    return modelFirstUserFailure('binding_not_authorized');
} else if (input.expectedFirstUserFingerprint != null || globalThis.__computaModelFirstProof)
  return modelFirstUserFailure('first_missing');
if (usageLimited && input.action !== 'stop') return modelUsageLimitFailure();

async function providerPageAction() {
  websiteModelDiagnosticPhase('page_action');
  const modelState = websiteModelPickerState('claude');
  if (['discoverModels', 'selectModel', 'modelDiagnostic'].includes(input.action))
    return websiteModelPickerAction(modelState, input, ownedUserCount === 0
      && globalThis.__computaModelFirstSubmitted !== true
      && document.querySelectorAll('[data-testid="assistant-message"]').length === 0);
  if (input.action !== 'stop' && input.expectedModelChoice != null) {
    const proof = await websiteModelReadEvidence('claude', input.expectedModelChoice, null,
      { scope: 'action_precheck', action: input.action });
    if (proof.error) return proof;
    // Reading a freshly mounted picker yields. Before any editor mutation,
    // recheck the same native ownership and first-message snapshot again.
    const currentCount = modelUserRoots().length;
    if (window !== window.top || document.URL !== input.expectedURL || globalThis.__computaModelOwner !== input.ownerToken
      || currentCount !== ownedUserCount) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, currentCount,
        firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity } : null,
        modelTemporaryVerified()) || modelFirstUserFailure('count_after_model_read', false, 'user_count');
    if (firstSnapshot && !snapshotUnchanged()) return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: modelUserRoots, body: modelUserBody, text: normalizedBody,
        identity: root => root.closest('[id]')?.getAttribute('id'), temporary: modelTemporaryVerified })
      || modelFirstUserFailure('snapshot_after_model_read');
    modelState.evidence = proof.modelEvidence;
  }
  if (input.action === 'verifyModel') return { modelEvidence: modelState.evidence };

  const { action, prompt, expectedFirstUserMarker } = input;
  const usageLimited = modelUsageLimited();
  if (usageLimited && action !== 'stop') return modelUsageLimitFailure();
  const composer = modelFind(['[data-testid="chat-input"][contenteditable="true"][role="textbox"]']);
  const candidates = [...document.querySelectorAll('[data-testid="assistant-message"] [data-perf-reply-text]')].filter(modelVisible);
  const answers = candidates.filter(node => !candidates.some(other => other !== node && other.contains(node)));
  const answer = answers.at(-1), stop = modelFind(['button[aria-label="Stop response"]']);
  const status = modelFind(['[data-testid="response-status-announcer"][role="status"]']);
  const interrupted = !!status && !status.closest('[data-testid="assistant-message"], [data-testid="user-message"]')
    && (status.textContent || '').trim().replace(/’/g, "'") === "Claude's response was interrupted.";
  const streaming = [...document.querySelectorAll('[data-testid="assistant-message"][data-is-streaming="true"]')].some(modelVisible);
  const busy = !!stop || streaming;
  const message = answer?.closest('[data-testid="assistant-message"]');
  // The observed article is a DIV with this role, not necessarily an ARTICLE tag.
  const article = answer?.closest('[role="article"]');
  const copies = article && article.querySelectorAll('[data-testid="assistant-message"]').length === 1
    ? [...article.querySelectorAll('[data-testid="message-actions"] button[data-testid="action-bar-copy"][aria-label="Copy"]')] : [];
  const scopedCopies = copies.length, enabledCopies = copies.filter(modelEnabled).length;
  const answerComplete = !busy && !interrupted && message?.getAttribute('data-is-streaming') === 'false' && enabledCopies > 0;
  const temporary = modelTemporaryVerified();
  const temporaryActionAvailable = modelEnabled(modelFind(['button[aria-label="Use incognito"]']));
  const responseExtraction = modelResponseExtraction(answer);
  const state = { modelEvidence: modelState.evidence, url: document.URL, temporary, temporaryActionAvailable, conversationIdentity: null, composer: !!composer,
    responseCount: answers.length, userCount: ownedUserCount, firstUserIdentity, firstUserFingerprint,
    firstUserVerified: ownedUserCount > 0, firstUserMarkerVerified: ownedUserCount > 0,
    busy, interrupted, text: modelResponseText(answer, responseExtraction).slice(0, 220_001),
    answerComplete, completionEvidence: { codeStructure: modelResponseStructure(answer, responseExtraction), modernMarkers: 0, logicalAnswers: answers.length,
      scopedCopies, enabledCopies, depth: -1 } };
  if (action === 'inspect') {
    const signIn = !composer && [...document.querySelectorAll('a, button')].filter(modelVisible)
      .some(node => /^(?:Log in|Sign in)(?:\s|$)/i.test(node.getAttribute('aria-label') || (node.innerText || '').trim()));
    return { ...state, signIn, debugStructure: '', quotaDiagnostic: modelQuotaDiagnostic() };
  }
  if (action === 'enableTemporary') {
    if (temporary) return { ...state, enabled: true };
    if (ownedUserCount || answers.length || globalThis.__computaModelFirstSubmitted) return { error: 'not_fresh' };
    if (globalThis.__computaModelTemporaryRequested) return modelTemporaryFailure('temporary_mode_unverified');
    const toggle = modelFind(['button[aria-label="Use incognito"]']);
    if (!modelEnabled(toggle)) return modelTemporaryFailure('temporary_mode_unavailable');
    // Claim before the single click. A lost acknowledgment cannot toggle back.
    globalThis.__computaModelTemporaryRequested = true;
    toggle.click();
    return { ...state, enabled: false };
  }
  if (!temporary) return modelTemporaryFailure('temporary_mode_unverified');
  if (action === 'stop') {
    if (usageLimited) return { ...state, usageLimited: true, busy: false, stopped: false };
    if (modelEnabled(stop)) stop.click();
    return { ...state, stopped: !!stop };
  }
  if (!modelEnabled(composer) || busy) return { error: 'composer_unavailable' };
  if (modelVisibleDialog(true) || modelVisibleDialog() && !websiteModelHitTestTarget(composer)) return { error: 'composer_unavailable' };
  const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
  if (action === 'prepare') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    if (ownedUserCount === 0) globalThis.__computaModelFirstPrepared = true;
    composer.focus();
    return { ...state, prepared: document.activeElement === composer || composer.contains(document.activeElement) };
  }
  if (typeof prompt !== 'string' || !prompt.trim() || prompt.length > 180_000) return { error: 'prompt_not_inserted' };
  if (action === 'insert') {
    if (value?.trim()) return { error: 'composer_not_empty' };
    if (ownedUserCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || typeof expectedFirstUserMarker !== 'string'
        || !/^[a-f0-9-]{36}$/i.test(expectedFirstUserMarker)
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return { error: 'conversation_changed', detail: 'first_user_message' };
      globalThis.__computaModelFirstPrompt = prompt;
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
      } else if (!document.execCommand('insertText', false, prompt)) return { error: 'insert_command_rejected' };
    }
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
  const send = modelFind(['button[data-testid="chat-input-send"][aria-label="Send message"]']);
  const sendUnobstructed = !modelVisibleDialog(true) && (!modelVisibleDialog() || websiteModelHitTestTarget(send));
  if (action === 'sendReady') return { ...state, sendReady: modelEnabled(send) && sendUnobstructed };
  if (!modelEnabled(send) || !sendUnobstructed) return { error: 'send_unavailable' };
  if (globalThis.__computaModelLastSubmissionCount !== undefined
    && ownedUserCount <= globalThis.__computaModelLastSubmissionCount)
    return { error: 'conversation_changed', detail: 'user_count' };
  if (ownedUserCount === 0) {
    if (globalThis.__computaModelFirstSubmitted || globalThis.__computaModelFirstPrompt !== prompt
      || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
      return { error: 'conversation_changed', detail: 'first_user_message' };
    globalThis.__computaModelFirstMarker = expectedFirstUserMarker;
    globalThis.__computaModelFirstSubmitted = true;
  }
  globalThis.__computaModelLastSubmissionCount = ownedUserCount;
  send.click();
  return { submitted: true };
}
const observed = await websiteModelFinalGuard('claude', input, await providerPageAction(), modelTemporaryVerified);
if (observed.error === 'first_user_observation_replaced') return observed;
if (['inspect', 'verifyModel'].includes(input.action) && modelUserRoots().length !== ownedUserCount) {
  const append = websiteModelAcknowledgedUserAppend(input, ownedUserCount, modelUserRoots().length,
    firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity } : null,
    modelTemporaryVerified());
  if (append) return append;
  if (!firstSnapshot) return modelFirstUserFailure('count_after_model_action', false, 'user_count');
}
if (firstSnapshot) {
  if (!snapshotUnchanged(input.action === 'submit')) return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
    { roots: modelUserRoots, body: modelUserBody, text: normalizedBody,
      identity: root => root.closest('[id]')?.getAttribute('id'), temporary: modelTemporaryVerified })
    || modelFirstUserFailure('snapshot_after_action', input.action === 'submit');
  if (observed.error === 'website_usage_limit' || input.action !== 'stop' && modelUsageLimited())
    return { error: 'website_usage_limit' };
  if (!modelTemporaryVerified()) return modelTemporaryFailure('temporary_mode_unverified');
  if (observed.error) return observed;
  if (!globalThis.__computaModelFirstProof) {
    if (observed.temporary !== true) return modelTemporaryFailure('temporary_mode_unverified');
    globalThis.__computaModelFirstProof = { marker: input.expectedFirstUserMarker, fingerprint: firstUserFingerprint,
      identity: firstUserIdentity };
  }
  // Submit intentionally exposes its acknowledgment only, as in the native contract.
  if (input.action === 'submit') return observed;
  return { ...observed, firstUserVerified: true, firstUserFingerprint, firstUserMarkerVerified: true };
}
if (observed.freshQuotaAbort === true) return observed;
return { ...observed, firstUserVerified: false, firstUserFingerprint: null };
