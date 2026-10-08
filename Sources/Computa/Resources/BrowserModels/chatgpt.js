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
  const codes = [...answer.querySelectorAll('code')];
  if (blocks.length > 1) return rendered;
  if (codes.length !== 1) return rendered;
  const code = codes[0], raw = code.textContent || '';
  if (blocks.length === 1 && !blocks[0].contains(code)) return rendered;
  const noPre = blocks.length === 0;
  // Current ChatGPT also renders short code bodies in this exact DIV/CODE
  // structure. A generic CODE element without PRE is never admitted.
  const divCode = noPre && code.closest('code.block.text-size-code') === code
    && code.parentElement?.closest('div.text-size-chat.overflow-auto.outline-none.px-4.pt-0.pb-3') === code.parentElement;
  if (noPre && !divCode) return rendered;
  if (raw.length > 220_000) return rendered;
  let envelope;
  try { envelope = JSON.parse(raw); } catch { return rendered; }
  if (!envelope || Array.isArray(envelope) || !['message', 'tool_calls'].includes(envelope.type)) return rendered;
  // Observed ChatGPT code widget. Utility classes bound the actual header;
  // the generated outer CodeBlock class does not carry stable identity.
  const wrapper = (noPre ? code : blocks[0]).closest('div.relative.w-full.min-w-0.overflow-clip.contain-inline-size.border');
  const chrome = new Set();
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[inert], [aria-hidden="true"]');
  if (wrapper && wrapper !== answer && answer.contains(wrapper)
    && wrapper.querySelectorAll('pre').length === blocks.length && wrapper.querySelectorAll('code').length === 1) {
    const headers = [...wrapper.querySelectorAll('div.flex.items-center.font-sans.text-sm.select-none.min-h-12')]
      .filter(node => visible(node) && !node.closest('pre'));
    if (headers.length === 1) {
      const labels = [...headers[0].querySelectorAll('div.min-w-0.flex-1.truncate')].filter(node =>
        visible(node) && node.childElementCount === 0 && (node.textContent || '').trim() === 'JSON');
      const copies = [...headers[0].querySelectorAll('button[aria-label="Copy"]')].filter(node => visible(node)
        && !node.disabled && node.getAttribute('aria-disabled') !== 'true' && !(node.textContent || '').trim());
      if (labels.length === 1 && copies.length === 1) { chrome.add(labels[0]); chrome.add(copies[0]); }
    }
  }
  if (noPre && chrome.size !== 2) return rendered;
  let visited = 0;
  const onlyCodeAndWhitespace = node => {
    if (++visited > 10_000) return false;
    if (node === code || chrome.has(node)) return true;
    if (node.nodeType === 3) return /^\s*$/.test(node.textContent || '');
    if (node.nodeType !== 1) return true;
    // Actual controls inside this pre are code-block chrome, never surrounding prose.
    if (node.tagName.toLowerCase() === 'button' && blocks.length === 1 && blocks[0].contains(node)) return true;
    return [...node.childNodes].every(onlyCodeAndWhitespace);
  };
  return onlyCodeAndWhitespace(answer) ? raw : rendered;
}

// Diagnostic counts describe only this scoped answer; no response bytes leave this function.
function modelResponseStructure(answer) {
  const blocks = answer ? [...answer.querySelectorAll('pre')] : [];
  const allCodes = answer ? [...answer.querySelectorAll('code')] : [];
  const code = allCodes.length === 1 ? allCodes[0] : null;
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

// Fixed ChatGPT DOM adapter derived from BrowserExtension/web-providers.js.
// Runs in a private WebKit content world; input arrives as structured arguments.
function chatGPTMessageRoots(role) {
  const selector = `[data-message-author-role="${role}"], [data-markdown-text-style="${role}-message"], article[data-turn="${role}"]`
    + (role === 'user' ? ', [data-user-message-bubble]' : '');
  const nodes = [...document.querySelectorAll(selector)];
  return nodes.filter(node => !nodes.some(other => other !== node && other.contains(node)));
}
function chatGPTUserBody(root) {
  return root.querySelector('[data-markdown-text-style="user-message"]')
    || root.querySelector('.whitespace-pre-wrap') || root.querySelector('[data-message-author-role="user"]') || root;
}
function chatGPTRenderedTemporary() {
  const visible = node => node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
  const buttons = [...document.querySelectorAll('button')].filter(visible);
  return buttons.some(node => node.getAttribute('aria-label') === 'Turn off temporary chat')
    || new URL(document.URL).searchParams.get('temporary-chat') === 'true'
      && buttons.some(node => node.getAttribute('aria-label') === 'Save chat' || (node.innerText || '').trim() === 'Save chat');
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
    .filter(node => physical(node) && !node.closest(boundary) && labelledGroup(node));
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
    modeControl: node => !!node && node.nodeType === 1 && !node.closest(boundary) && label(node) === 'Work'
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
    chatClickClaimed: globalThis.__computaChatModeClickClaimed === true };
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
  const groups = proof.groups, works = proof.works;
  const trackWork = node => {
    if (!state.modeControl(node)) return;
    works.add(node);
    if (node.getAttribute('aria-pressed') === 'true' || node.getAttribute('aria-checked') === 'true') proof.invalidated = true;
  };
  const register = node => {
    if (!node || node.nodeType !== 1) return;
    const candidates = [node, ...node.querySelectorAll('[aria-label], [aria-labelledby]')].slice(0, 128);
    for (const candidate of candidates) if (state.namedGroup(candidate)) groups.add(candidate);
    const owned = groups.has(node) || [...groups].some(group => group.contains(node));
    if (owned) for (const candidate of [node, ...node.querySelectorAll('button, [role="button"], [role="radio"], [role="switch"], [role="checkbox"]')].slice(0, 128))
      trackWork(candidate);
  };
  if (state.group) groups.add(state.group);
  if (state.work) trackWork(state.work);
  // Process structural provenance before attribute records. A control can be
  // mounted, switched to Work, switched back and detached within one batch.
  for (const record of records.slice(0, 512)) if (record.type === 'childList' && state.outside(record.target)) {
    register(record.target);
    const ownedTarget = groups.has(record.target) || [...groups].some(group => group.contains(record.target));
    for (const node of [...(record.addedNodes || []), ...(record.removedNodes || [])].slice(0, 128)) {
      register(node);
      if (ownedTarget && node?.nodeType === 1) for (const candidate of [node,
        ...node.querySelectorAll('button, [role="button"], [role="radio"], [role="switch"], [role="checkbox"]')].slice(0, 128))
        trackWork(candidate);
    }
  }
  if (groups.size > 64 || works.size > 128 || records.length > 512) { proof.invalidated = true; return; }
  if (state.contradictory || records.some(record => record.type === 'attributes'
    && ['aria-pressed', 'aria-checked'].includes(record.attributeName) && record.oldValue === 'true'
    && works.has(record.target))) proof.invalidated = true;
}
function chatGPTProductModeProof() {
  const proof = globalThis.__computaChatProductMode;
  const state = chatGPTProductModeState();
  if (!proof || proof.invalidated || proof.owner !== globalThis.__computaModelOwner || proof.document !== document
    || window !== window.top || location.origin !== 'https://chatgpt.com'
    || !/^\/(?:c\/(?:[A-Za-z0-9-]+|local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+)\/?)?$/.test(new URL(document.URL).pathname)
    || state.contradictory) {
    if (proof) proof.invalidated = true;
    return null;
  }
  if (!proof.temporaryRequested && (!state.ready || state.chatSelected !== true)) {
    proof.invalidated = true;
    return null;
  }
  if (proof.temporaryRequested && chatGPTRenderedTemporary()) proof.temporaryAcknowledged = true;
  if (chatGPTRenderedTemporary() && !proof.temporaryAcknowledged) return null;
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
  const product = chatGPTProductModeAction(request);
  if (product.error) return product;
  if (['ensureChatMode', 'verifyProductMode'].includes(request.action)) return { ...product, temporary: chatGPTTemporaryVerified() };
  if (!product.chatModeReady && request.action !== 'inspect') return { error: 'product_mode_unverified' };
  const result = await providerPageAction(request, fingerprint);
  if (result.error) return result;
  const finalProduct = chatGPTProductModeAction({ ...request, action: 'verifyProductMode' });
  if (finalProduct.error && product.chatModeReady) return finalProduct;
  return { ...result, ...(finalProduct.error ? product : finalProduct), temporary: chatGPTTemporaryVerified() };
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
async function providerPageAction(input, readLineageFingerprint = null) {
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
    // Latest remains readable as the website's current selection so a concrete
    // requested model can replace it, but is not an advertised model choice.
    if (input.action === 'discoverModels' && Array.isArray(result.modelChoices))
      return { ...result, modelChoices: result.modelChoices.filter(choice => choice.key !== 'Latest') };
    return result;
  }
  // Focus-only preparation and model-only verification need one final proof.
  // Editor and response actions retain their proof before and after the action.
  if (!['stop', 'prepare', 'verifyModel'].includes(input.action) && input.expectedModelChoice != null) {
    const proof = await websiteModelReadEvidence('chatgpt', input.expectedModelChoice, null,
      { scope: 'action_precheck', action: input.action });
    if (proof.error) return proof;
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    // Reading a freshly mounted picker yields. Before any editor mutation,
    // recheck the same native ownership and first-message snapshot again.
    const currentCount = chatGPTMessageRoots('user').length;
    if (window !== window.top || document.URL !== input.expectedURL || globalThis.__computaModelOwner !== input.ownerToken
      || currentCount !== ownedUserCount) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, currentCount,
        firstSnapshot ? { snapshotIntact: snapshotUnchanged(true), fingerprint: readLineageFingerprint } : null, chatGPTTemporaryVerified())
        || { error: 'conversation_changed', detail: 'user_count' };
    if (firstSnapshot && !snapshotUnchanged()) return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
      { roots: () => chatGPTMessageRoots('user'), body: chatGPTUserBody, text: normalizedFirstBody,
        identity: () => null, temporary: chatGPTTemporaryVerified })
      || chatGPTFirstUserFailure('snapshot_after_action', 'model_precheck', {}, false, readLineageFingerprint);
    modelState.evidence = proof.modelEvidence;
  }
  if (input.action === 'verifyModel') return { modelEvidence: modelState.evidence };

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
  const answerText = modelResponseText(answer);
  let answerComplete = false;
  const completionEvidence = { codeStructure: modelResponseStructure(answer), modernMarkers: modernChatGPTAnswers.length, logicalAnswers: answers.length,
    scopedCopies: 0, enabledCopies: 0, depth: -1 };
  if (provider === "chatgpt" && answer) {
    // The current Copy footer is a sibling of the selection wrapper. Keep the
    // search inside an ancestor containing only this one physical answer;
    // nested marker wrappers do not create another message.
    for (let node = answer, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
      if (answers.filter(other => node === other || node.contains(other)).length > 1) break;
      const copies = [...node.querySelectorAll('.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"], button[aria-label="Copy"]')];
      completionEvidence.scopedCopies = copies.length;
      completionEvidence.enabledCopies = copies.filter(enabled).length;
      completionEvidence.depth = depth;
      if (completionEvidence.enabledCopies) { answerComplete = true; break; }
    }
  } else if (provider === "claude" && answer) {
    const message = answer.closest('[data-testid="assistant-message"]');
    const article = answer.closest('[role="article"]');
    const copy = article?.querySelector('[data-testid="message-actions"] button[data-testid="action-bar-copy"][aria-label="Copy"]');
    answerComplete = !interrupted && message?.getAttribute("data-is-streaming") === "false"
      && article?.querySelectorAll('[data-testid="assistant-message"]').length === 1 && enabled(copy);
  } else if (answer) {
    answerComplete = !!answer.closest("model-response")?.querySelector('button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]');
  }
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
  const state = { modelEvidence: modelState.evidence, url: document.URL, temporary, temporaryActionAvailable, conversationIdentity, composer: !!composer, responseCount: answers.length, userCount,
    firstUserIdentity, firstUserFingerprint, firstUserMarkerVerified,
    busy: !!stop || claudeStreaming, interrupted, text: answerText.slice(0, 220_001), answerComplete, completionEvidence };
  if (action === "inspect") {
    const signIn = !composer && !!labelled(document.querySelectorAll('a, button'), /^(?:Log in|Sign in)(?:\s|$)/i);
    return { ...state, signIn, debugStructure: chatGPTStructure(visible) };
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
    composer.focus();
    if (composer instanceof HTMLTextAreaElement) {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set.call(composer, prompt);
      composer.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: prompt }));
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
        composer.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: prompt }));
      } else if (!document.execCommand("insertText", false, prompt))
          return { error: "insert_command_rejected" };
    }
    return { ...state, inserted: true };
  }
  if (action === "prepare") {
    if (!chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
    if (!enabled(composer) || stop || claudeStreaming) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (value?.trim()) return { error: "composer_not_empty" };
    composer.focus();
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
    globalThis.__computaModelLastSubmissionCount = userCount;
    send.click();
    return { submitted: true };
  }
  if (action === "stop") { if (enabled(stop)) stop.click(); return { stopped: !!stop }; }
  return { error: "unknown_action" };
}

if (window !== window.top || location.origin !== "https://chatgpt.com" || document.URL !== input.expectedURL)
  return { error: "document_changed", detail: "document_url" };
if (globalThis.__computaModelOwner !== input.ownerToken) {
  if (input.bindOwner && globalThis.__computaModelOwner === undefined)
    globalThis.__computaModelOwner = input.ownerToken;
  else return { error: "document_changed", detail: "owner_token" };
}
if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken) {
  const signal = { ownerToken: input.ownerToken, queued: false, observer: null };
  signal.observer = new MutationObserver(records => {
    const productProof = globalThis.__computaChatProductMode;
    const mode = productProof ? chatGPTProductModeState() : null;
    if (productProof) chatGPTObserveProductMutations(productProof, mode, records);
    if (!records.some(record => !websiteModelIgnoreOwnPickerMutation(record)) || signal.queued) return;
    signal.queued = true;
    // Batch streaming mutations into one wake-up; this timer is scheduled
    // only by an actual change, never as a recurring website poll.
    setTimeout(() => {
      signal.queued = false;
      if (window !== window.top || location.origin !== "https://chatgpt.com"
        || globalThis.__computaModelOwner !== signal.ownerToken) return;
      // This notification carries no page content and grants no native action.
      // The native receiver validates this exact model view and ownership again.
      try {
        window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({
          ownerToken: signal.ownerToken, kind: "dom_changed"
        });
      } catch { }
    }, 100);
  });
  signal.observer.observe(document.documentElement || document, {
    subtree: true, childList: true, characterData: true, attributes: true, attributeOldValue: true,
    attributeFilter: ["disabled", "aria-disabled", "aria-hidden", "aria-busy", "aria-label", "class", "style",
      "aria-checked", "aria-pressed", "aria-selected", "aria-controls", "aria-labelledby", "aria-expanded", "title", "hidden", "inert", "contenteditable", "data-testid", "data-is-streaming",
      "data-message-author-role", "data-markdown-text-style", "data-chatgpt-selection-conversation-id", "data-turn",
      "data-user-message-bubble"]
  });
  globalThis.__computaModelSignal = signal;
}
const ownedMessages = chatGPTMessageRoots('user');
const ownedUserCount = ownedMessages.length;
if (!Array.isArray(input.expectedUserCounts) || !input.expectedUserCounts.includes(ownedUserCount))
  return { error: "conversation_changed", detail: "user_count" };
let firstUserVerified = false;
let firstUserFingerprint = null;
let firstSnapshot = null;
let firstUserRejectionDiagnostic;
const normalizedFirstBody = node => (node.innerText || node.textContent || "")
  .replace(/\r\n?/g, "\n").normalize("NFC").trim();
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
      markerValid, allowFirstUserBinding: input.allowFirstUserBinding === true,
      privatePinPresent: pinned != null, expectedFingerprintPresent: input.expectedFirstUserFingerprint != null };
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
  return { error: 'conversation_changed', detail: 'first_user_message', ...(debugStructure ? { debugStructure } : {}) };
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
if (ownedUserCount > 0) {
  const marker = input.expectedFirstUserMarker;
  const first = chatGPTUserBody(ownedMessages[0]);
  const rendered = normalizedFirstBody(first);
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
  firstSnapshot = { root: ownedMessages[0], body: first, text: rendered };
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rendered));
  const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  if (!snapshotUnchanged()) return websiteModelAcknowledgedUserAppend(input, ownedUserCount, chatGPTMessageRoots('user').length,
    { snapshotIntact: snapshotUnchanged(true), fingerprint }, chatGPTTemporaryVerified())
    || await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
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
    return await websiteModelReplacementObservation(input, ownedUserCount, firstSnapshot,
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
  return { ...observed, firstUserVerified, firstUserFingerprint, firstUserMarkerVerified: true,
    ...(firstUserDebugStructure ? { firstUserDebugStructure } : {}) };
}
if (input.expectedFirstUserFingerprint != null)
  return chatGPTFirstUserFailure('first_missing', 'first_missing');
const observed = await websiteModelFinalGuard('chatgpt', input, await chatGPTGuardedPageAction(input), chatGPTTemporaryVerified);
if (!observed.error && observed.chatModeReady && !chatGPTProductModeProof()) return { error: 'product_mode_unverified' };
const readContextFailure = finalReadContextFailure(observed);
if (readContextFailure) return readContextFailure;
if (['inspect', 'verifyModel', 'verifyProductMode'].includes(input.action) && chatGPTMessageRoots('user').length !== ownedUserCount)
  return websiteModelAcknowledgedUserAppend(input, ownedUserCount, chatGPTMessageRoots('user').length, null, chatGPTTemporaryVerified())
    || { error: 'conversation_changed', detail: 'user_count' };
return { ...observed, firstUserVerified, firstUserFingerprint };
