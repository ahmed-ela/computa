// Shared source copied into each standalone private-world provider adapter.
// Model names come only from the provider's associated picker, never messages.
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
function websiteModelWaitForChange(until, condition) {
  if (condition()) return Promise.resolve(true);
  return new Promise(resolve => {
    let finished = false, timer;
    const observer = new MutationObserver(() => { if (condition()) finish(true); });
    const finish = changed => {
      if (finished) return;
      finished = true;
      observer.disconnect?.();
      if (typeof clearTimeout === 'function') clearTimeout(timer);
      resolve(changed);
    };
    observer.observe(document.documentElement || document, { subtree: true, childList: true, characterData: true,
      attributes: true, attributeFilter: ['aria-expanded', 'aria-hidden', 'aria-controls', 'aria-labelledby', 'aria-checked',
        'aria-selected', 'aria-label', 'aria-disabled', 'disabled', 'data-state', 'role', 'class', 'style', 'hidden', 'inert'] });
    timer = setTimeout(() => finish(false), Math.max(1, until - Date.now()));
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
  if (record.type === 'attributes') {
    // Real selection/fallback attributes and response content always wake the
    // native reader. Only this observation's menu visibility/chrome is omitted.
    if (!['aria-expanded', 'aria-hidden', 'aria-controls', 'aria-labelledby', 'class', 'style', 'hidden', 'inert', 'data-state'].includes(record.attributeName)) return false;
    if (scope.provider === 'gemini' && record.attributeName === 'class' && target.isConnected
      && target.getAttribute('role') === 'menuitem' && belongs(target)) {
      // Gemini's actual model rows use a selected token plus an aria-labelled
      // icon, not checked radios. Active/focus changes remain picker chrome.
      if (record.oldValue === undefined || /(?:^|\s)selected(?:\s|$)/.test(record.oldValue || '') !== target.classList.contains('selected')) return false;
    }
    return belongs(target) || ['aria-hidden', 'inert', 'style'].includes(record.attributeName)
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
const normalizedBody = node => (node.innerText || node.textContent || '').replace(/\r\n?/g, '\n').normalize('NFC').trim();
function modelFirstUserStructure(reason, allowSubmittedUser = false) {
  const roots = modelUserRoots(), root = roots[0], body = root && modelUserBody(root);
  const rendered = body ? normalizedBody(body) : '', lines = rendered.split('\n');
  const marker = input.expectedFirstUserMarker;
  const markerLine = typeof marker === 'string' && /^[a-f0-9-]{36}$/i.test(marker) ? `Computa session marker: ${marker}` : null;
  const utilities = ['block', 'flex', 'inline-flex', 'relative', 'truncate', 'whitespace-pre-wrap', 'whitespace-normal',
    'break-words', 'overflow-hidden', 'overflow-auto', 'hidden', 'text-sm', 'items-center', 'min-w-0', 'w-full'];
  const shape = node => ({ tag: node && /^[a-zA-Z][a-zA-Z0-9-]{0,31}$/.test(node.tagName) ? node.tagName.toLowerCase() : 'none',
    classes: node ? [...node.classList].filter(name => /^[a-zA-Z0-9_-]{1,48}$/.test(name)
      && (/^(?:query-|user-query-|gds-|mat-|cdk-|ng-)/.test(name) || utilities.includes(name))
      && !rendered.includes(name) && !(globalThis.__computaModelFirstPrompt || '').includes(name)).slice(0, 6) : [] });
  const descendants = [], queue = root ? [...root.children].filter(node => node.nodeType === 1)
    .map((node, index) => ({ node, path: [Math.min(index, 1_000)] })) : [];
  for (let index = 0; index < queue.length && descendants.length < 16; index++) {
    const { node, path } = queue[index], text = normalizedBody(node);
    descendants.push({ ...shape(node), path, childElements: Math.min(node.childElementCount, 1_000),
      controls: Math.min(node.querySelectorAll('button, [role="button"]').length, 1_000),
      textLength: Math.min(text.length, 220_001), markerExact: markerLine !== null && text === markerLine,
      markerContained: markerLine !== null && text.includes(markerLine), visible: modelVisible(node),
      editable: node.getAttribute('contenteditable') === 'true' });
    if (path.length < 16) [...node.children].filter(child => child.nodeType === 1).slice(0, 16)
      .forEach((child, childIndex) => queue.push({ node: child, path: [...path, childIndex] }));
  }
  const pinned = globalThis.__computaModelFirstProof;
  const diagnostic = { kind: 'first_user_structure', provider: 'gemini', reason, userCount: Math.min(roots.length, 1_000),
    root: shape(root), body: shape(body), textLength: Math.min(rendered.length, 220_001), lineCount: Math.min(lines.length, 220_001),
    markerFinalLine: markerLine !== null && lines.at(-1) === markerLine,
    markerOccurrences: Math.min(markerLine === null ? 0 : lines.filter(line => line === markerLine).length, 1_000),
    controlDescendants: Math.min(body ? body.querySelectorAll('button, [role="button"]').length : 0, 1_000),
    submitted: globalThis.__computaModelFirstSubmitted === true, markerMatches: globalThis.__computaModelFirstMarker === marker,
    descendants };
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
    return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: modelUserRoots, body: modelUserBody, text: normalizedBody, identity: () => firstUserIdentity, temporary: modelTemporaryVerified })
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
    if (firstSnapshot && !snapshotUnchanged()) return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: modelUserRoots, body: modelUserBody, text: normalizedBody, identity: () => firstUserIdentity, temporary: modelTemporaryVerified })
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
    if (ownedUserCount === 0) {
      if (globalThis.__computaModelFirstSubmitted || typeof expectedFirstUserMarker !== 'string'
        || !/^[a-f0-9-]{36}$/i.test(expectedFirstUserMarker)
        || !prompt.endsWith(`\n\nComputa session marker: ${expectedFirstUserMarker}`))
        return modelFirstUserFailure('first_insert');
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
if (observed.error === 'first_user_observation_replaced') return observed;
if (['inspect', 'verifyModel'].includes(input.action) && modelUserRoots().length !== ownedUserCount) {
  const append = websiteModelAcknowledgedUserAppend(input, ownedUserCount, modelUserRoots().length,
    firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: firstUserFingerprint, identity: firstUserIdentity } : null,
    modelTemporaryVerified());
  if (append) return append;
  if (!firstSnapshot) return { error: 'conversation_changed', detail: 'user_count' };
}
if (firstSnapshot) {
  if (!snapshotUnchanged(input.action === 'submit')) return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
    { roots: modelUserRoots, body: modelUserBody, text: normalizedBody, identity: () => firstUserIdentity, temporary: modelTemporaryVerified })
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
  if (input.action === 'submit') return observed;
  return { ...observed, firstUserVerified: true, firstUserFingerprint, firstUserMarkerVerified: true,
    ...(firstBound ? { debugStructure: modelFirstUserStructure('first_bound') } : {}) };
}
return { ...observed, firstUserVerified: false, firstUserFingerprint: null };
