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
function websiteModelAcknowledgedUserAppend(request, capturedCount, currentCount, lineage = null, temporary = false) {
  const expected = request.expectedUserCounts;
  if (!['inspect', 'verifyModel'].includes(request.action) || !websiteModelChoiceValid(request.expectedModelChoice)
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
  if (!['inspect', 'verifyModel'].includes(request.action) || !websiteModelChoiceValid(request.expectedModelChoice)
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
  const allMenus = nodes('[role="menu"], [role="listbox"], [role="dialog"]').filter(node => visible(node) && outside(node));
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
  return { provider, trigger, triggerCount: triggers.length, triggerCandidates, topMenu, secondary, nestedMenu, menus, allMenus, choices: duplicate ? [] : choices,
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
        'aria-selected', 'aria-label', 'role', 'class', 'style', 'hidden', 'inert'] });
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
async function websiteModelReadEvidence(provider, expected, openingRecovery = null) {
  if (!websiteModelChoiceValid(expected)) return { error: 'model_unverified' };
  const owner = globalThis.__computaModelOwner, url = document.URL;
  const recovery = provider === 'chatgpt' && openingRecovery?.attempt?.clicked === true
    && openingRecovery.attempt.settled === true && openingRecovery.attempt.completed !== true
    && typeof openingRecovery.guard === 'function' ? openingRecovery : null;
  const unchanged = () => window === window.top && document.URL === url && globalThis.__computaModelOwner === owner
    && (!recovery || recovery.guard(false) === true);
  const until = recovery ? recovery.until : Date.now() + 1_800;
  let primaryOpened = false, secondaryOpened = false, closeAttempted = false, trigger = null, captured = null;
  let readStage = 'initial_observation';
  let state = websiteModelPickerState(provider);
  const failure = error => {
    const current = websiteModelPickerState(provider);
    return { error, modelDiagnostic: websiteModelDiagnostic(current, { readStage,
      readAttempt: { primaryOpened, secondaryOpened, closeAttempted, observedProof: !!captured,
        sameTrigger: !trigger || current.trigger === trigger, popupStillAssociated: !!current.topMenu } }),
      ...(captured ? { modelEvidence: captured } : {}) };
  };
  const closeOwned = async () => {
    const current = websiteModelPickerState(provider);
    if (!unchanged()) return false;
    if (!current.topMenu) return true;
    if (!trigger || current.trigger !== trigger || !current.physical(trigger) || trigger.disabled
      || trigger.getAttribute('aria-disabled') === 'true') return false;
    // This exact controlled picker may be aria-hidden while its modal portal is
    // open. Its previously verified association, not background text, owns close.
    if (closeAttempted) return false;
    closeAttempted = true; // A lost close acknowledgment cannot toggle this picker open again.
    readStage = 'close_requested';
    if (!websiteModelDismissOwnedPicker(provider, trigger, current.nestedMenu || current.topMenu)) return false;
    const closed = await websiteModelWaitForChange(until, () => !unchanged() || !websiteModelPickerState(provider).topMenu);
    readStage = closed ? 'close_acknowledged' : 'close_unconfirmed';
    return closed;
  };
  try {
    while (Date.now() < until) {
      if (!unchanged()) return recovery ? failure('model_unverified') : { error: 'document_changed', detail: 'owner_token' };
      state = websiteModelPickerState(provider);
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
      const proof = await websiteModelReadEvidence(state.provider, choice);
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
      ? { attempt, guard: freshGuard, until } : null);
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
  const proof = await websiteModelReadEvidence(provider, request.expectedModelChoice);
  if (proof.error) return proof;
  // The picker can hide the mode control while open. Reinspect its actual
  // restored temporary state only after this final owned-popup close.
  if (typeof currentTemporary !== 'function' || currentTemporary() !== true) return { error: 'temporary_mode_unverified' };
  return { ...observed, ...proof, ...(request.action === 'inspect' && observed.answerComplete && observed.responseCount > 0
    ? { modelDiagnostic: websiteModelDiagnostic(websiteModelPickerState(provider)) } : {}) };
}
