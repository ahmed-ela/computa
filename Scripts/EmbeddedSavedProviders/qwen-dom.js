// Qwen DOM driver. The saved-conversation engine owns all
// mutation claims, native acknowledgement, exact-body hashing and lifecycle.
// Only insertLiteral mutates, and only after the engine's insertion claim.
function computaQwenDOM(c) {
  const visible = (root, selector, max = 256) => c.nodes(root, selector, max).filter(c.visible);
  const one = (values, reason) => c.unique(values, 'document_changed', reason);
  const optional = (values, reason) => values.length ? one(values, reason) : null;
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
    const trigger = control('model_trigger', document, 'div.wms-trigger[role="button"][aria-label="Select Model"][aria-haspopup="listbox"]');
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
    const trigger = one(visible(document, 'div.wms-trigger[role="button"][aria-label="Select Model"][aria-haspopup="listbox"]')
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
    return { trigger, menu, label, closed: menu === null && expanded === 'false' };
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
  function transcript(allowInitialResponseIdentity = false) {
    const users = c.nodes(document, '.qwen-chat-message.qwen-chat-message-user', 2);
    const answers = c.nodes(document, '.qwen-chat-message.qwen-chat-message-assistant', 2);
    if (users.length > 1 || answers.length > 1 || answers.length > users.length) c.fail('conversation_changed', 'user_count');
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
      const content = one(visible(node, '.chat-response-message'), 'response_container');
      const answerID = content.getAttribute('id')?.replace(/^chat-response-message-/, '');
      if (!c.visible(node) || (!c.uuid(answerID) && !(allowInitialResponseIdentity && answerID === ''))
        || content.getAttribute('id') !== 'chat-response-message-' + answerID
        || answerID === id || !answerTurn?.classList.contains('qwen-chat-message-select-turn-message')
        || answerTurn.parentElement !== turn.parentElement
        || [...turn.parentElement.children].indexOf(answerTurn) <= [...turn.parentElement.children].indexOf(turn))
        c.fail('conversation_changed', 'response_scope');
      if (answerID === '') {
        // The observed first response mounts this exact prefix before its UUID.
        // This is an internal negative candidate, never an answer. Default
        // transcript reads, completion and cleanup retain strict UUID checks.
        const form = composer();
        if (!form.empty || !c.enabled(form.editor) || !form.stop
          || c.nodes(content, '.response-loading', 2).length !== 1
          || c.nodes(content, '.response-message-content.phase-answer', 1).length
          || c.nodes(content, '.response-message-footer-actions', 1).length)
          c.fail('conversation_changed', 'response_scope');
        pendingAnswer = { root: node, content, turn: answerTurn, outer: turn.parentElement };
      } else answer = { root: node, content, id: answerID };

    }
    return { users, answers, first: { root, container, body, id, text: body.textContent }, answer, pendingAnswer };
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
    const unsupported = () => ({ text: '', finalMarkup: false, formatIssue: true });
    if (flows.length !== 1 || !c.visible(flows[0])) return unsupported();
    const flow = flows[0], phases = c.nodes(flow, '.response-message-content.phase-answer');
    if (!phases.length) return { text: '', finalMarkup: false, formatIssue: false };
    if (phases.length !== 1 || !phases[0].classList.contains('t2t')) return unsupported();
    const phase = phases[0];
    const child = (parent, tag, cls) => {
      if (!c.visible(parent) || parent.children.length !== 1
        || [...parent.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || ''))) return null;
      const node = parent.children[0];
      return node.tagName === tag && node.classList.contains(cls) && c.visible(node) ? node : null;
    };
    const custom = child(phase, 'DIV', 'custom-qwen-markdown');
    const markdown = custom && child(custom, 'DIV', 'qwen-markdown');
    const paragraph = markdown && child(markdown, 'DIV', 'qwen-markdown-paragraph');
    const span = paragraph && child(paragraph, 'SPAN', 'qwen-markdown-text');
    const literal = span && child(span, 'SPAN', 'qwen-markdown-text-node');
    if (!literal || literal.children.length !== 0) return unsupported();
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
    if (!onlyAuthoredSource(flow)) return unsupported();
    const text = literal.textContent;
    if (typeof text !== 'string' || new TextEncoder().encode(text).length > 220_000) c.fail('response_too_large');
    // Return the whole source even when it is invalid JSON. Monaco/fences,
    // additional prose blocks and multiple fragments never become a repaired
    // protocol object; the ordinary codec independently validates raw bytes.
    return { text, finalMarkup: true, formatIssue: false };
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
  return { rejectSelectionBinding, firstBodyPresentation, firstBodyFailureStructure, initialResponseIdentityTranscript: () => transcript(true), route, authored, initialReady, picker, modelRows, composer, transcript, completionCandidate, rawAnswer,
    deletionTrigger, deletionMenu, deletionConfirmation, deletionObserved, insertLiteral };
}
