// The associated menu and its explicit checkbox state were observed on Grok.
// Model labels remain website discoveries; descriptions and promotions grant no choice.
function computaGrokModelControls(c, state, guard) {
  const authored = node => node?.closest('[data-testid="user-message"], [data-testid="assistant-message"], [contenteditable], pre, code');
  function picker() {
    guard();
    const candidates = c.nodes(document, '#model-select-trigger', 8), triggers = candidates.filter(c.visible);
    if (triggers.length !== 1) c.fail('model_unverified', triggers.length ? 'model_trigger_ambiguous'
      : candidates.length ? 'model_trigger_hidden' : 'model_trigger_missing');
    const trigger = triggers[0];
    if (trigger.tagName !== 'BUTTON' || trigger.getAttribute('aria-haspopup') !== 'menu' || authored(trigger))
      c.fail('model_unverified', 'model_trigger_shape');
    const raw = trigger.getAttribute('aria-label');
    if (typeof raw !== 'string' || !raw.startsWith('Model: ')) c.fail('model_unverified', 'model_trigger_label');
    const label = raw.slice(7), selected = { key: label, label };
    if (!c.choiceValid(selected)) c.fail('model_unverified', 'model_trigger_choice');
    const menus = c.nodes(document, '[role="menu"][aria-labelledby="model-select-trigger"]', 8).filter(c.visible);
    if (menus.length > 1) c.fail('model_unverified', 'model_menu_ambiguous');
    if (menus.some(authored)) c.fail('model_unverified', 'model_menu_authored');
    const expanded = trigger.getAttribute('aria-expanded');
    if (expanded !== 'true' && expanded !== 'false') c.fail('model_unverified', 'model_expansion_invalid');
    if (expanded === 'false' && menus.length) {
      // Grok keeps the clicked menu mounted during its closing animation.
      // This observed transition carries no model proof or action authority.
      const operation = state.grokModelOperation;
      if (operation?.phase !== 'closing') c.fail('model_unverified', 'model_collapsed_menu_present');
      if (operation.trigger !== trigger) c.fail('model_unverified', 'model_closing_trigger_replaced');
      if (operation.menu !== menus[0]) c.fail('model_unverified', 'model_closing_menu_replaced');
      if (!c.equalChoice(operation.selected, selected)) c.fail('model_mismatch', 'model_closing_selection_changed');
      if (menus[0].getAttribute('data-closed') !== '' || menus[0].getAttribute('data-ending-style') !== ''
        || menus[0].hasAttribute('data-open')) c.fail('model_unverified', 'model_closing_shape');
    }
    return { trigger, selected, menu: menus[0] || null, closed: expanded === 'false' && menus.length === 0 };
  }
  function rows(p) {
    if (!p.menu || p.closed) c.fail('model_unverified', 'model_rows_unavailable');
    const options = c.nodes(p.menu, '[role="menuitemcheckbox"]', 64).filter(node => c.visible(node)
      && node.closest('[role="menu"]') === p.menu);
    if (!options.length) c.fail('model_unverified', 'model_rows_empty');
    const mapped = options.map(node => {
      const label = c.normalize(node.innerText), choice = { key: label, label }, checked = node.getAttribute('aria-checked');
      if (!c.choiceValid(choice)) c.fail('model_unverified', 'model_row_choice');
      if (!['true', 'false'].includes(checked)) c.fail('model_unverified', 'model_row_checked');
      if (authored(node)) c.fail('model_unverified', 'model_row_authored');
      return { node, choice, checked: checked === 'true', enabled: c.enabled(node) && !node.hasAttribute('data-disabled') };
    });
    if (new Set(mapped.map(row => row.choice.key)).size !== mapped.length) c.fail('model_unverified', 'model_rows_duplicate');
    const checkedRows = mapped.filter(row => row.checked);
    if (checkedRows.length !== 1) c.fail('model_unverified', 'model_checked_count');
    const checked = checkedRows[0];
    if (!checked.enabled) c.fail('model_unverified', 'model_checked_disabled');
    if (!c.equalChoice(checked.choice, p.selected)) c.fail('model_unverified', 'model_checked_label');
    const enabled = mapped.filter(row => row.enabled);
    if (!enabled.length || enabled.length > 32) c.fail('model_unverified', 'model_enabled_count');
    return { enabled, checked };
  }
  function evidence() {
    const p = picker();
    if (!p.closed || !state.grokModelChoices || !state.grokModelChoices.some(choice => c.equalChoice(choice, p.selected))) return null;
    if (state.grokExpectedModel && !c.equalChoice(state.grokExpectedModel, p.selected)) c.fail('model_mismatch', 'model_pinned_changed');
    return { selected: p.selected, verification: 'website_selection', source: 'selected_model_indicator' };
  }
  function step(action, choice) {
    if (!['discoverModels', 'selectModel'].includes(action)) c.fail('unknown_action', 'model_action_unknown');
    if (action === 'selectModel' && !c.choiceValid(choice)) c.fail('model_unverified', 'model_intent_invalid');
    const p = picker();
    let operation = state.grokModelOperation;
    if (operation && (operation.action !== action || action === 'selectModel' && !c.equalChoice(operation.choice, choice))) {
      if (operation.phase !== 'complete') c.fail('model_unverified', 'model_operation_changed');
      operation = null;
    }
    if (!operation) {
      if (!p.closed) c.fail('model_unverified', 'model_open_not_closed');
      const hitFailure = c.hitFailure(p.trigger);
      if (hitFailure) c.fail('model_unverified', 'model_open_hit_' + hitFailure);
      operation = { action, choice: choice || null, phase: 'opening', trigger: p.trigger, menu: null, selected: null, choices: null };
      state.grokModelOperation = operation; // Claim before opening; uncertain clicks are never replayed.
      p.trigger.click();
      guard();
      return { pending: true };
    }
    if (operation.phase === 'opening') {
      if (!p.menu) return { pending: true };
      if (p.trigger !== operation.trigger) c.fail('model_unverified', 'model_trigger_replaced');
      const menu = rows(p), targets = action === 'selectModel'
        ? menu.enabled.filter(row => c.equalChoice(row.choice, choice)) : [menu.checked];
      if (targets.length !== 1) c.fail('model_unavailable', 'model_target_count');
      const target = targets[0], hitFailure = c.hitFailure(target.node);
      if (hitFailure) c.fail('model_unverified', 'model_option_hit_' + hitFailure);
      operation.choices = menu.enabled.map(row => ({ ...row.choice }));
      operation.selected = { ...target.choice };
      operation.menu = p.menu;
      // Clicking the selected row is the observed menu-dismiss path. It does
      // not substitute another model, and a lost acknowledgement cannot retry.
      operation.phase = 'closing';
      target.node.click();
      guard();
      return { pending: true };
    }
    if (p.trigger !== operation.trigger) c.fail('model_unverified', 'model_closing_trigger_replaced');
    if (!p.closed) return { pending: true };
    if (!c.equalChoice(p.selected, operation.selected)) c.fail('model_mismatch', 'model_selection_changed');
    state.grokModelChoices = operation.choices;
    if (action === 'selectModel') state.grokExpectedModel = operation.selected;
    operation.phase = 'complete';
    return { modelChoices: operation.choices, modelEvidence: evidence(), ...(action === 'selectModel' ? { selected: true } : {}) };
  }
  return { picker, evidence, step };
}
