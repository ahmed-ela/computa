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
  function authoredSourceCandidate(answer, channel, parentID) {
    if (!answer || !channel || Object.keys(channel).sort().join(',') !== 'dispatch,result,secret'
      || ![channel.dispatch,channel.result,channel.secret,parentID,answer.id].every(c.uuid)
      || route().kind !== 'canonical' || !codePayloadRoot(answer.root)) return null;
    let count = 0, source = null;
    const listener = event => {
      if (event.target !== answer.content || event.detail?.kind !== 'raw_answer_v1' || event.detail?.op !== 'candidate') return;
      count++;
      const value = event.detail;
      if (Object.keys(value).sort().join(',') === 'candidate,eligible,kind,op,responseID'
        && value.eligible === true && c.uuid(value.candidate) && value.responseID === answer.id) source = value.candidate;
    };
    document.addEventListener(channel.result,listener,true);
    try {
      answer.content.dispatchEvent(new CustomEvent(channel.dispatch,{bubbles:true,detail:{kind:'raw_answer_v1',op:'candidate',
        secret:channel.secret,chatID:route().id,parentID,responseID:answer.id}}));
    } finally { document.removeEventListener(channel.result,listener,true); }
    if (count !== 1 || source === null) return null;
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
  return { rejectUserCount, rejectSelectionBinding, firstDisplayReplacement, watchDisplayRender, displayHitFailure, firstBodyPresentation, firstBodyFailureStructure,
    responseChoiceTranscript: () => transcript(true, null, true),
    hasResponseChoice: () => c.nodes(document, '.qwen-chat-message-assistant .smrm', 2).length !== 0,
    initialResponseIdentityTranscript: emptyContainerPrompt => transcript(true, emptyContainerPrompt), route, authored, initialReady, picker, modelRows, composer, transcript, completionCandidate, rawAnswer, codePayloadFailure, sampleCodePayload, authoredSourceCandidate,
    deletionTrigger, deletionMenu, deletionConfirmation, deletionObserved, insertLiteral };
}
