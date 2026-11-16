// The associated menu and its explicit checkbox state were observed on Grok.
// Model labels remain website discoveries; descriptions and promotions grant no choice.
function computaGrokModelControls(c, state, guard) {
  const authored = node => node?.closest('[data-testid="user-message"], [data-testid="assistant-message"], [contenteditable], pre, code');
  function picker() {
    guard();
    const trigger = c.unique(c.nodes(document, '#model-select-trigger', 8).filter(c.visible), 'model_unverified');
    if (trigger.tagName !== 'BUTTON' || trigger.getAttribute('aria-haspopup') !== 'menu' || authored(trigger)) c.fail('model_unverified');
    const raw = trigger.getAttribute('aria-label');
    if (typeof raw !== 'string' || !raw.startsWith('Model: ')) c.fail('model_unverified');
    const label = raw.slice(7), selected = { key: label, label };
    if (!c.choiceValid(selected)) c.fail('model_unverified');
    const menus = c.nodes(document, '[role="menu"][aria-labelledby="model-select-trigger"]', 8).filter(c.visible);
    if (menus.length > 1 || menus.some(authored)) c.fail('model_unverified');
    const expanded = trigger.getAttribute('aria-expanded');
    if (expanded !== 'true' && expanded !== 'false' || expanded === 'false' && menus.length) c.fail('model_unverified');
    return { trigger, selected, menu: menus[0] || null, closed: expanded === 'false' && menus.length === 0 };
  }
  function rows(p) {
    if (!p.menu || p.closed) c.fail('model_unverified');
    const options = c.nodes(p.menu, '[role="menuitemcheckbox"]', 64).filter(node => c.visible(node)
      && node.closest('[role="menu"]') === p.menu);
    if (!options.length) c.fail('model_unverified');
    const mapped = options.map(node => {
      const label = c.normalize(node.innerText), choice = { key: label, label }, checked = node.getAttribute('aria-checked');
      if (!c.choiceValid(choice) || !['true', 'false'].includes(checked) || authored(node)) c.fail('model_unverified');
      return { node, choice, checked: checked === 'true', enabled: c.enabled(node) && !node.hasAttribute('data-disabled') };
    });
    if (new Set(mapped.map(row => row.choice.key)).size !== mapped.length) c.fail('model_unverified');
    const checked = c.unique(mapped.filter(row => row.checked), 'model_unverified');
    if (!checked.enabled || !c.equalChoice(checked.choice, p.selected)) c.fail('model_unverified');
    const enabled = mapped.filter(row => row.enabled);
    if (!enabled.length || enabled.length > 32) c.fail('model_unverified');
    return { enabled, checked };
  }
  function evidence() {
    const p = picker();
    if (!p.closed || !state.grokModelChoices || !state.grokModelChoices.some(choice => c.equalChoice(choice, p.selected))) return null;
    if (state.grokExpectedModel && !c.equalChoice(state.grokExpectedModel, p.selected)) c.fail('model_mismatch');
    return { selected: p.selected, verification: 'website_selection', source: 'selected_model_indicator' };
  }
  function step(action, choice) {
    if (!['discoverModels', 'selectModel'].includes(action)) c.fail('unknown_action');
    if (action === 'selectModel' && !c.choiceValid(choice)) c.fail('model_unverified');
    const p = picker();
    let operation = state.grokModelOperation;
    if (operation && (operation.action !== action || action === 'selectModel' && !c.equalChoice(operation.choice, choice))) {
      if (operation.phase !== 'complete') c.fail('model_unverified');
      operation = null;
    }
    if (!operation) {
      if (!p.closed || !c.hit(p.trigger)) c.fail('model_unverified');
      operation = { action, choice: choice || null, phase: 'opening', trigger: p.trigger, selected: null, choices: null };
      state.grokModelOperation = operation; // Claim before opening; uncertain clicks are never replayed.
      p.trigger.click();
      guard();
      return { pending: true };
    }
    if (operation.phase === 'opening') {
      if (!p.menu) return { pending: true };
      if (p.trigger !== operation.trigger) c.fail('model_unverified');
      const menu = rows(p), target = action === 'selectModel'
        ? c.unique(menu.enabled.filter(row => c.equalChoice(row.choice, choice)), 'model_unavailable') : menu.checked;
      if (!c.hit(target.node)) c.fail('model_unverified');
      operation.choices = menu.enabled.map(row => ({ ...row.choice }));
      operation.selected = { ...target.choice };
      // Clicking the selected row is the observed menu-dismiss path. It does
      // not substitute another model, and a lost acknowledgement cannot retry.
      operation.phase = 'closing';
      target.node.click();
      guard();
      return { pending: true };
    }
    if (!p.closed) return { pending: true };
    if (!c.equalChoice(p.selected, operation.selected)) c.fail('model_mismatch');
    state.grokModelChoices = operation.choices;
    if (action === 'selectModel') state.grokExpectedModel = operation.selected;
    operation.phase = 'complete';
    return { modelChoices: operation.choices, modelEvidence: evidence(), ...(action === 'selectModel' ? { selected: true } : {}) };
  }
  return { picker, evidence, step };
}
