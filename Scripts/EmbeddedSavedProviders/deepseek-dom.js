// DeepSeek DOM hooks; provider registration and authority stay in the native host.
// The shared saved-chat engine must own claims, hashing and lifecycle. DeepSeek
// exposes modes, not a named backend model. Completion is an unqualified candidate.
function computaDeepSeekDOM(c) {
  const visible = (root, selector, max = 256) => c.nodes(root, selector, max).filter(c.visible);
  const one = (values, reason) => c.unique(values, 'document_changed', reason);
  const optional = (values, reason) => values.length ? one(values, reason) : null;
  const authored = node => !!node.closest('.ds-message');
  const arrow = 'M8.3125 0.980206C8.66767 1.05312 8.97902 1.2042 9.2627 1.43235C9.48724 1.613 9.73029 1.85795 9.97949 2.10716L14.707 6.8347L13.293 8.24876L9 3.95579V15.0417H7V3.95579L2.70703 8.24876L1.29297 6.8347L6.02051 2.10716C6.26971 1.85795 6.51277 1.613 6.7373 1.43235C6.97662 1.23988 7.28445 1.04404 7.6875 0.980206C7.8973 0.947029 8.1031 0.955183 8.3125 0.980206Z';
  const usable = node => c.enabled(node) && !node.classList.contains('ds-button--disabled');
  const leaf = (root, selector, reason) => {
    const node = one(visible(root, selector), reason);
    if (node.children.length) c.fail('document_changed', reason);
    return node;
  };
  function route(exactURL = true) {
    if (exactURL) c.assertContext();
    if (document.URL === 'https://chat.deepseek.com/')
      return { kind: 'fresh', canonical: null, conversation: null, path: '/', id: null };
    const match = /^https:\/\/chat\.deepseek\.com\/a\/chat\/s\/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/.exec(document.URL);
    if (!match) c.fail('conversation_changed', 'conversation_url');
    return { kind: 'canonical', canonical: document.URL, conversation: document.URL,
      path: '/a/chat/s/' + match[1], id: match[1] };
  }
  function initialReady({ control, retain, reject }) {
    if (c.nodes(document, '.ds-message', 64).length) reject('not_fresh');
    const editor = control('composer', document, 'textarea[placeholder="Message DeepSeek"]');
    if (!editor) return false;
    const scope = retain('composer_scope', editor.closest('._020ab5b'));
    if (!scope || c.nodes(scope, 'textarea').length !== 1 || typeof editor.value !== 'string') reject('composer_unavailable');
    if (editor.value !== '') reject('composer_not_empty');
    const send = control('send_control', scope, '[role="button"].ds-button--primary.ds-button--circle');
    const toggles = c.nodes(scope, '.ds-toggle-button', 3);
    if (toggles.length > 2) reject('mode_unverified');
    const found = {};
    for (const node of toggles) {
      const spans = c.nodes(node, 'span', 2);
      if (spans.length !== 1 || spans[0].children.length || !['DeepThink', 'Search'].includes(spans[0].textContent)) reject('mode_unverified');
      const name = spans[0].textContent === 'DeepThink' ? 'deepthink_control' : 'search_control';
      if (found[name]) reject('mode_unverified');
      found[name] = retain(name, node);
      retain(name + '_label', spans[0]);
      const pressed = node.getAttribute('aria-pressed');
      if (!['true', 'false'].includes(pressed) || !usable(node)
        || node.classList.contains('ds-toggle-button--selected') !== (pressed === 'true')) reject('mode_unverified');
    }
    // Search may be on initially. Only a separately claimed selectMode action
    // can turn it off; loading and discovery never alter either toggle.
    for (const name of ['deepthink_control', 'search_control']) if (!found[name]) retain(name, null);
    return !!send && !!found.deepthink_control && !!found.search_control;
  }
  function composer() {
    const editor = one(visible(document, 'textarea[placeholder="Message DeepSeek"]').filter(node => !authored(node)), 'composer');
    const scope = editor.closest('._020ab5b');
    if (!scope || !c.visible(scope) || c.nodes(scope, 'textarea').length !== 1
      || typeof editor.value !== 'string' || new TextEncoder().encode(editor.value).length > 180_200)
      c.fail('composer_unavailable');
    const send = one(visible(scope, '[role="button"].ds-button--primary.ds-button--circle'), 'send_control');
    const svg = visible(send, 'svg'), paths = c.nodes(send, 'path');
    const terminalArrow = svg.length === 1 && svg[0].getAttribute('viewBox') === '0 0 16 16'
      && paths.length === 1 && paths[0].getAttribute('d') === arrow;
    return { editor, scope, send, text: editor.value, empty: editor.value === '', terminalArrow,
      sendReady: terminalArrow && usable(editor) && usable(send) && c.hit(send),
      streaming: null }; // No negative streaming control was captured.
  }
  function modeControls() {
    const { scope } = composer();
    const toggles = visible(scope, '.ds-toggle-button');
    if (toggles.length !== 2) c.fail('model_unverified');
    const get = label => {
      const node = one(toggles.filter(node => {
        const spans = visible(node, 'span');
        return spans.length === 1 && !spans[0].children.length && spans[0].textContent === label;
      }), 'mode_toggle');
      const pressed = node.getAttribute('aria-pressed');
      if (!['true', 'false'].includes(pressed) || !usable(node)
        || node.classList.contains('ds-toggle-button--selected') !== (pressed === 'true')) c.fail('model_unverified');
      return { node, selected: pressed === 'true' };
    };
    const deepThink = get('DeepThink'), search = get('Search');
    return { scope, deepThink, search, choices: [{ key: 'chat', label: 'Chat' }, { key: 'deepthink', label: 'DeepThink' }] };
  }
  function modeEvidence() {
    const modes = modeControls();
    if (modes.search.selected) c.fail('model_unverified');
    return { selected: modes.choices[modes.deepThink.selected ? 1 : 0],
      source: 'website_mode_toggle', backendModel: null, search: false };
  }
  function rejectFirstContainer(root, container, body) {
    // Failure-only metadata from the already selected nodes. No extra selector,
    // action, page read or body value leaves this call; diagnostic failure cannot
    // replace the original terminal rejection. Counts saturate at 16, rows at 4.
    let diagnostic;
    try {
      const rootText = root.textContent, containerText = container.textContent, bodyText = body.textContent;
      const children = container.children, tags = ['DIV', 'SPAN', 'BUTTON', 'SVG', 'P', 'BR', 'INPUT', 'TEXTAREA'];
      const count = node => Math.min(16, node.children.length);
      diagnostic = { version: 1, containerChildren: count(container), wrapperChildren: count(children[0]),
        bodyChildren: count(body), rootEqualsBody: rootText === bodyText, containerEqualsBody: containerText === bodyText,
        rootEmpty: rootText === '', containerEmpty: containerText === '', bodyEmpty: bodyText === '',
        childrenOmitted: children.length > 4, children: Array.from({ length: Math.min(4, children.length) }, (_, index) => {
          const child = children[index];
          return { tag: tags.includes(child.tagName) ? child.tagName : 'other', children: count(child),
            empty: child.textContent === '', containsBody: child.contains(body) };
        }) };
    } catch { /* Retain only the original fixed failure if metadata is unavailable. */ }
    try { c.fail('conversation_changed', 'first_container_children'); }
    catch (error) {
      if (diagnostic && error?.computaAdapterFailure) error.firstContainerDiagnostic = diagnostic;
      throw error;
    }
  }
  function emptyNoninteractiveDecoration(node) {
    // The observed collapsed prompt appends one empty DIV leaf. It contributes
    // no text and is never a control or an action target for this adapter.
    return node?.tagName === 'DIV' && node.children.length === 0 && node.textContent === ''
      && [null, '', 'none', 'presentation'].includes(node.getAttribute('role'))
      && ['tabindex', 'contenteditable', 'aria-haspopup', 'aria-controls', 'aria-activedescendant',
        'aria-pressed', 'aria-checked', 'aria-expanded', 'onclick'].every(name => node.getAttribute(name) === null);
  }
  function transcript() {
    const roots = c.nodes(document, '.ds-message', 2);
    const users = roots.filter(root => root.classList.contains('d29f3d7d'));
    const answers = roots.filter(root => !users.includes(root));
    if (users.length > 1 || answers.length > 1 || answers.length > users.length)
      c.fail('conversation_changed', 'user_count');
    if (!users.length) return { users, answers, first: null, answer: null };
    if (route().kind !== 'canonical') c.fail('conversation_changed', 'conversation_url');
    const root = users[0], container = one(visible(root, '.ds-collapsible-text'), 'first_user_container');
    const body = leaf(container, 'div > span', 'first_user_message'), turn = root.parentElement;
    const id = turn?.getAttribute('data-virtual-list-item-key');
    // Retain the unique complete prompt and exact whole-root/container text.
    // A textless decoration may be a sibling, never a substitute prompt body.
    if (!c.visible(root)) c.fail('conversation_changed', 'first_root_hidden');
    if (!id || !/^-?[0-9]{1,10}$/.test(id)) c.fail('conversation_changed', 'first_id_invalid');
    const children = container.children;
    const decorated = children.length === 2 && children[0].contains(body)
      && emptyNoninteractiveDecoration(children[1]);
    if (children.length !== 1 && !decorated) rejectFirstContainer(root, container, body);
    if (container.children[0].children.length !== 1) c.fail('conversation_changed', 'first_wrapper_children');
    if (container.textContent !== body.textContent) c.fail('conversation_changed', 'first_container_text');
    if (root.textContent !== body.textContent) c.fail('conversation_changed', 'first_root_text');
    let answer = null;
    if (answers.length) {
      const node = answers[0], answerTurn = node.parentElement;
      const answerID = answerTurn?.getAttribute('data-virtual-list-item-key');
      const turns = c.nodes(document, '[data-virtual-list-item-key]', 8);
      if (!c.visible(node) || !answerID || !/^-?[0-9]{1,10}$/.test(answerID) || answerID === id
        || turns.filter(item => item.getAttribute('data-virtual-list-item-key') === id).length !== 1
        || turns.filter(item => item.getAttribute('data-virtual-list-item-key') === answerID).length !== 1
        || turns.indexOf(answerTurn) <= turns.indexOf(turn)) c.fail('conversation_changed', 'response_scope');
      answer = { root: node, turn: answerTurn, id: answerID };
    }
    return { users, answers, first: { root, container, body, turn, id, text: body.textContent }, answer };
  }
  function rawAnswer(answer) {
    if (!answer) return { text: '', finalMarkup: false, formatIssue: false };
    const unsupported = () => ({ text: '', finalMarkup: false, formatIssue: true });
    const finals = c.nodes(answer.root, '.ds-assistant-message-main-content');
    if (!finals.length) return { text: '', finalMarkup: false, formatIssue: false };
    if (finals.length !== 1) return unsupported();
    const final = finals[0];
    if (!c.visible(final) || !final.classList.contains('ds-markdown') || final.parentElement !== answer.root)
      return unsupported();
    const siblings = [...answer.root.children];
    if (siblings.some(node => node !== final && (!node.classList.contains('_74c0879') || siblings.indexOf(node) > siblings.indexOf(final)))
      || siblings.filter(node => node !== final).length > 1
      || [...answer.root.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || '')))
      return unsupported(); // The known reasoning sibling is never traversed/read.
    const child = (parent, tag, cls) => {
      if (!c.visible(parent) || parent.children.length !== 1
        || [...parent.childNodes].some(node => node.nodeType === 3 && !/^\s*$/.test(node.textContent || ''))) return null;
      const node = parent.children[0];
      return node.tagName === tag && (!cls || node.classList.contains(cls)) && c.visible(node) ? node : null;
    };
    const paragraph = child(final, 'P', 'ds-markdown-paragraph');
    const literal = paragraph && child(paragraph, 'SPAN', null);
    if (!literal || literal.children.length) return unsupported();
    const text = literal.textContent;
    if (typeof text !== 'string' || new TextEncoder().encode(text).length > 220_000) c.fail('response_too_large');
    return { text, finalMarkup: true, formatIssue: false }; // Whole bytes, including malformed JSON.
  }
  function completionCandidate(answer) {
    if (!answer) return false;
    const form = composer(), rails = visible(answer.turn, '.ds-flex._965abe9');
    if (!form.empty || !usable(form.editor) || !form.terminalArrow || rails.length !== 1) return false;
    const rail = rails[0];
    if (rail.closest('.ds-message')) return false;
    const buttons = visible(rail, '[role="button"]');
    const readAloud = buttons.filter(node => node.getAttribute('aria-label') === 'Read aloud');
    return buttons.length === 6 && buttons.every(usable) && readAloud.length === 1;
  }
  function sameFirst(first) {
    const now = transcript().first;
    return !!first && !!now && first.root === now.root && first.container === now.container
      && first.body === now.body && first.turn === now.turn && first.id === now.id && first.text === now.text;
  }
  function ownedAnchor(conversationURL) {
    return one(c.nodes(document, 'a[href]', 512).filter(node => {
      try { return new URL(node.getAttribute('href'), document.URL).href === conversationURL; } catch { return false; }
    }), 'delete_anchor');
  }
  function deletionContext(first) {
    const current = route();
    if (current.kind !== 'canonical' || !sameFirst(first)
      || visible(document, '[role="menu"], [role="dialog"], .ds-modal').length) c.fail('conversation_changed', 'delete_ownership');
    const anchor = ownedAnchor(current.canonical);
    if (!c.visible(anchor) || authored(anchor)) c.fail('conversation_changed', 'delete_anchor');
    const trigger = one(visible(anchor, '[role="button"].ds-button'), 'delete_trigger');
    return { conversationURL: current.canonical, first, anchor, trigger };
  }
  function deletionGuard(record) {
    const context = record?.driverContext, current = route();
    if (!context || record.conversationURL !== context.conversationURL || current.canonical !== context.conversationURL
      || !sameFirst(context.first) || ownedAnchor(context.conversationURL) !== context.anchor
      || !c.visible(context.anchor) || record.trigger !== context.trigger
      || one(visible(context.anchor, '[role="button"].ds-button'), 'delete_trigger') !== context.trigger)
      c.fail('conversation_changed', 'delete_ownership');
    return context;
  }
  function deletionTrigger(context) {
    deletionGuard({ driverContext: context, conversationURL: context?.conversationURL, trigger: context?.trigger });
    // Return identity for subsequent scoped checks even if the owned popup
    // covers this control. The engine checks the hit before its sole click.
    return context.trigger;
  }
  function deletionMenu(record) {
    deletionGuard(record);
    if (record.menuAcknowledged !== true) c.fail('conversation_changed', 'delete_menu_open_unacknowledged');
    if (record.deleteAcknowledged === true) c.fail('conversation_changed', 'delete_menu_selection_spent');
    const menu = optional(visible(document, '[role="menu"]'), 'delete_menu');
    if (!menu) return null;
    if (!menu.classList.contains('ds-dropdown-menu') || authored(menu) || record.menu && record.menu !== menu)
      c.fail('conversation_changed', 'delete_menu');
    const target = one(visible(menu, '.ds-dropdown-menu-option').filter(node => {
      const labels = visible(node, '.ds-dropdown-menu-option__label');
      return labels.length === 1 && !labels[0].children.length && labels[0].textContent === 'Delete';
    }), 'delete_control');
    if (!target.classList.contains('ds-dropdown-menu-option--error')) c.fail('conversation_changed', 'delete_control');
    return { menu, target: c.hit(target) ? target : null };
  }
  function deletionConfirmation(record) {
    deletionGuard(record);
    if (record.menuAcknowledged !== true) c.fail('conversation_changed', 'delete_confirm_menu_unacknowledged');
    if (record.deleteAcknowledged !== true) c.fail('conversation_changed', 'delete_confirm_selection_unacknowledged');
    if (!record.menu?.classList.contains('ds-dropdown-menu')) c.fail('conversation_changed', 'delete_confirm_menu_unbound');
    if (visible(document, '[role="menu"]').length) c.fail('conversation_changed', 'delete_confirm_menu_still_visible');
    const dialog = optional(visible(document, '[role="dialog"]'), 'delete_dialog');
    if (!dialog) return null;
    const modal = dialog.closest('.ds-modal');
    const title = leaf(dialog, '.ds-modal-content__title', 'delete_title');
    const body = leaf(dialog, '.ds-modal-content__main', 'delete_body');
    const group = one(visible(dialog, '.ds-modal-content__button-group'), 'delete_buttons');
    const buttons = visible(group, '[role="button"]');
    const button = label => one(buttons.filter(node => {
      const labels = visible(node, '.ds-button__content');
      return labels.length === 1 && !labels[0].children.length && labels[0].textContent === label;
    }), 'delete_control');
    const target = button('Delete chat'), cancel = button('Cancel');
    if (!modal || modal.getAttribute('aria-modal') !== 'true' || visible(document, '.ds-modal').length !== 1
      || !dialog.classList.contains('ds-modal-content--dialog') || authored(dialog)
      || title.textContent !== 'This chat can’t be recovered.' || body.textContent !== 'Share links from it will be disabled.'
      || buttons.length !== 2 || !target.classList.contains('ds-button--error')
      || !cancel.classList.contains('ds-button--outlinedNeutral') || record.dialog && record.dialog !== dialog)
      c.fail('conversation_changed', 'delete_confirmation');
    return { dialog, target: c.hit(target) ? target : null };
  }
  function deletionObserved(record) {
    const context = record?.driverContext;
    if (!context || record.conversationURL !== context.conversationURL || record.confirmAcknowledged !== true)
      c.fail('conversation_changed', 'delete_operation');
    if (route().kind !== 'fresh' || !visible(document, 'textarea[placeholder="Message DeepSeek"]').length) return false;
    const form = composer();
    return form.empty && usable(form.editor) && form.terminalArrow
      && c.nodes(document, '.ds-message, [role="dialog"], .ds-modal').length === 0
      && !!record.dialog && !record.dialog.isConnected && !context.anchor.isConnected
      && [context.first.root, context.first.body].every(node => !node.isConnected)
      && record.roots.every(node => !node.isConnected)
      && c.nodes(document, 'a[href]', 512).every(node => {
        try { return new URL(node.getAttribute('href'), document.URL).href !== record.conversationURL; } catch { return false; }
      });
  }
  function insertLiteral(form, prompt) {
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
    if (!(form.editor instanceof HTMLTextAreaElement) || typeof setter !== 'function') c.fail('composer_unavailable');
    setter.call(form.editor, prompt);
    form.editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
  }
  return { route, authored, initialReady, composer, modeControls, modeEvidence, transcript, rawAnswer, completionCandidate,
    deletionContext, deletionTrigger, deletionMenu, deletionConfirmation, deletionObserved, insertLiteral };
}
