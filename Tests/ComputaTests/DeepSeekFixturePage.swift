// Offline synthetic observed-shape fixture; no live provider requests.
enum DeepSeekFixturePage {
    static let html = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>Synthetic DeepSeek native fixture</title>
<style>
  body { font: 15px system-ui; margin: 20px; color: #111; background: white; }
  [hidden] { display: none !important; }
  [role=button], .ds-toggle-button, .ds-dropdown-menu-option { display: inline-block; min-width: 22px; min-height: 22px; padding: 8px; margin: 3px; cursor: pointer; }
  .ds-button--disabled { color: #777; }
  .ds-toggle-button--selected { background: #dbeaff; }
  ._020ab5b { position: fixed; left: 20px; right: 20px; bottom: 20px; background: white; padding: 8px; border: 1px solid #777; z-index: 2; }
  textarea { display: block; width: 100%; height: 120px; box-sizing: border-box; }
  .ds-button--circle { float: right; }
  .ds-button--circle svg { width: 22px; height: 22px; }
  #transcript { margin-top: 70px; margin-bottom: 240px; max-width: 720px; }
  .ds-collapsible-text { white-space: pre-wrap; max-height: 120px; overflow: auto; }
  .ds-message { padding: 8px; min-height: 24px; }
  .ds-flex._965abe9 { display: flex; min-height: 40px; }
  #history { position: fixed; top: 15px; right: 20px; z-index: 3; }
  #history a { display: inline-flex; align-items: center; gap: 8px; color: #111; background: #eee; padding: 6px; }
  .ds-dropdown-menu { position: fixed; right: 30px; top: 85px; background: #fafafa; padding: 10px; border: 1px solid #555; z-index: 4; }
  .ds-modal { position: fixed; right: 30px; top: 130px; max-width: 460px; background: white; padding: 18px; border: 2px solid #555; z-index: 5; }
  .ds-modal-content__title { font-weight: bold; margin-bottom: 10px; }
  .ds-modal-content__main { margin-bottom: 12px; }
</style></head><body>
<div id="history"></div><div id="transcript"></div>
<div class="_020ab5b">
  <textarea placeholder="Message DeepSeek" autocomplete="off" spellcheck="false"></textarea>
  <div class="ds-toggle-button" aria-pressed="false" tabindex="0"><span>DeepThink</span></div>
  <div class="ds-toggle-button ds-toggle-button--selected" aria-pressed="true" tabindex="0"><span>Search</span></div>
  <div role="button" class="ds-button ds-button--primary ds-button--circle ds-button--disabled" tabindex="0"></div>
</div>
<script>
// Synthetic controls only: no network, account data or adapter-owned state.
// Only the actual textarea value becomes the independently rendered first user.
// Removing/restoring the observed arrow/rail is an inert completion negative,
// not evidence for any unobserved live website streaming or Stop control.
(() => {
  const conversationID = '11111111-abcd-4333-8444-555555555555';
  const conversationPath = '/a/chat/s/' + conversationID;
  const canonical = 'https://chat.deepseek.com' + conversationPath;
  const arrow = 'M8.3125 0.980206C8.66767 1.05312 8.97902 1.2042 9.2627 1.43235C9.48724 1.613 9.73029 1.85795 9.97949 2.10716L14.707 6.8347L13.293 8.24876L9 3.95579V15.0417H7V3.95579L2.70703 8.24876L1.29297 6.8347L6.02051 2.10716C6.26971 1.85795 6.51277 1.613 6.7373 1.43235C6.97662 1.23988 7.28445 1.04404 7.6875 0.980206C7.8973 0.947029 8.1031 0.955183 8.3125 0.980206Z';
  const options = { holdResponse: false, delayUser: false, canonicalDelayMs: 0, menuDelayMs: 0,
    dialogDelayMs: 0, holdDeletionMenu: false, holdDialog: false, menuWakeupMs: 0,
    deleteMenuMutation: 'none', retainHistoryLink: false, inertSearch: false, inertDeepThink: false,
    searchDelayMs: 0, deepThinkDelayMs: 0, firstUserSiblingKind: 'none',
    answerHTML: null, reply: '{"type":"message","text":"Synthetic DeepSeek native reply"}' };
  const counters = { inputs: 0, sends: 0, deepThinkClicks: 0, searchClicks: 0, historyOpens: 0,
    deleteSelections: 0, confirmations: 0, earlySends: 0,
    menuWakeups: 0, prematureConfirmations: 0 };
  let editor = document.querySelector('textarea');
  let [deepThink, search] = document.querySelectorAll('.ds-toggle-button');
  let send = document.querySelector('.ds-button--circle');
  const transcript = document.querySelector('#transcript'), historyList = document.querySelector('#history');
  const prompts = []; window.fixturePrompts = prompts;
  let submitted = false, sent = '', userTurn = null, answerTurn = null, answer = null;
  let firstBody = null, literal = null, rail = null, ownHistory = null, historyTrigger = null, deletionMenu = null, modal = null;
  const node = (tag, attributes = {}, text) => {
    const element = document.createElement(tag);
    for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
    if (text !== undefined) element.textContent = text;
    return element;
  };
  const delayed = (milliseconds, action) => milliseconds > 0 ? setTimeout(action, milliseconds) : action();
  let menuWakeupTimer = null;
  function stopMenuWakeups() { if (menuWakeupTimer !== null) clearInterval(menuWakeupTimer); menuWakeupTimer = null; }
  function closeDeletionMenu() { deletionMenu?.remove(); stopMenuWakeups(); }
  const selected = element => element.getAttribute('aria-pressed') === 'true';
  const setToggle = (element, value) => {
    element.setAttribute('aria-pressed', String(value));
    element.classList.toggle('ds-toggle-button--selected', value);
  };
  const setMode = (thinking, searching = false) => { setToggle(deepThink, thinking); setToggle(search, searching); };
  deepThink.addEventListener('click', () => {
    counters.deepThinkClicks++;
    if (!options.inertDeepThink) delayed(options.deepThinkDelayMs, () => setToggle(deepThink, !selected(deepThink)));
  });
  search.addEventListener('click', () => {
    counters.searchClicks++;
    if (!options.inertSearch) delayed(options.searchDelayMs, () => setToggle(search, !selected(search)));
  });
  function setArrow(present) {
    send.replaceChildren();
    if (!present) return;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path'); path.setAttribute('d', arrow);
    svg.append(path); send.append(svg);
  }
  setArrow(true);
  editor.addEventListener('input', () => {
    counters.inputs++;
    send.classList.toggle('ds-button--disabled', submitted || editor.value === '');
  });
  function showConfirmation() {
    modal = node('div', { class: 'ds-modal', 'aria-modal': 'true' });
    const dialog = node('div', { role: 'dialog', class: 'ds-modal-content ds-modal-content--dialog' });
    dialog.append(node('div', { class: 'ds-modal-content__title' }, 'This chat can’t be recovered.'),
      node('div', { class: 'ds-modal-content__main' }, 'Share links from it will be disabled.'));
    const group = node('div', { class: 'ds-modal-content__button-group' });
    const cancel = node('div', { role: 'button', class: 'ds-button ds-button--outlinedNeutral' });
    const confirm = node('div', { role: 'button', class: 'ds-button ds-button--error' });
    cancel.append(node('span', { class: 'ds-button__content' }, 'Cancel'));
    confirm.append(node('span', { class: 'ds-button__content' }, 'Delete chat'));
    group.append(cancel, confirm); dialog.append(group); modal.append(dialog); document.body.append(modal);
    cancel.addEventListener('click', () => modal.remove());
    confirm.addEventListener('click', () => {
      counters.confirmations++;
      if (document.querySelector('[role=menu]')) counters.prematureConfirmations++;
      modal.remove(); userTurn.remove(); answerTurn?.remove(); deletionMenu?.remove();
      if (!options.retainHistoryLink) ownHistory.remove();
      editor.value = ''; setArrow(true); send.classList.add('ds-button--disabled');
      window.history.replaceState({}, '', '/');
    });
  }
  function showDeletionMenu() {
    deletionMenu = node('div', { role: 'menu', class: 'ds-dropdown-menu ds-elevated' });
    const remove = node('div', { class: 'ds-dropdown-menu-option ds-dropdown-menu-option--error' });
    remove.append(node('div', { class: 'ds-dropdown-menu-option__label' }, 'Delete'));
    deletionMenu.append(remove); document.body.append(deletionMenu);
    remove.addEventListener('click', () => {
      counters.deleteSelections++;
      if (!options.holdDeletionMenu) closeDeletionMenu();
      if (options.deleteMenuMutation === 'foreign') document.body.append(deletionMenu.cloneNode(true));
      if (options.deleteMenuMutation === 'replaced') {
        const replacement = deletionMenu.cloneNode(true); deletionMenu.replaceWith(replacement); deletionMenu = replacement;
      }
      if (options.menuWakeupMs > 0) menuWakeupTimer = setInterval(() => {
        counters.menuWakeups++; deletionMenu.setAttribute('data-state', 'closing-' + (counters.menuWakeups % 2));
      }, options.menuWakeupMs);
      if (!options.holdDialog) delayed(options.dialogDelayMs, showConfirmation);
    });
  }
  function appendUser() {
    if (!submitted || userTurn) return;
    if (location.pathname !== conversationPath) throw new Error('Fixture user must be on its canonical route');
    userTurn = node('div', { 'data-virtual-list-item-key': '-2' });
    const user = node('div', { class: 'd29f3d7d ds-message' });
    const collapse = node('div', { class: 'ds-collapsible-text' }), wrapper = node('div');
    firstBody = node('span', {}, sent);
    wrapper.append(firstBody); collapse.append(wrapper);
    const kind = options.firstUserSiblingKind;
    if (kind !== 'none') {
      const extra = node(kind === 'button' ? 'button' : 'div');
      if (kind === 'text' || kind === 'hidden-text') extra.textContent = 'Synthetic extra text';
      if (kind === 'hidden-text') extra.hidden = true;
      if (kind === 'focusable') extra.setAttribute('tabindex', '-1');
      if (kind === 'editable') extra.setAttribute('contenteditable', '');
      if (kind === 'aria-control') extra.setAttribute('role', 'button');
      if (kind === 'duplicate') extra.append(node('span', {}, sent));
      collapse.append(extra);
      if (kind === 'two') collapse.append(node('div'));
    }
    user.append(collapse); userTurn.append(user); transcript.append(userTurn);
    ownHistory = node('a', { href: conversationPath });
    ownHistory.append(node('div', {}, 'Synthetic DeepSeek chat'));
    historyTrigger = node('div', { role: 'button', class: 'ds-button', tabindex: '0' }, 'More');
    ownHistory.append(historyTrigger); historyList.append(ownHistory);
    ownHistory.addEventListener('click', event => event.preventDefault());
    historyTrigger.addEventListener('click', event => {
      event.preventDefault(); event.stopPropagation(); counters.historyOpens++;
      delayed(options.menuDelayMs, showDeletionMenu);
    });
    if (!options.holdResponse) completeResponse();
  }
  function completeResponse() {
    if (!userTurn) return;
    if (!answerTurn) {
      answerTurn = node('div', { 'data-virtual-list-item-key': '2' });
      answer = node('div', { class: 'ds-message' });
      if (selected(deepThink)) answer.append(node('div', { class: '_74c0879' }, 'Synthetic separate status'));
      const final = node('div', { class: 'ds-markdown ds-assistant-message-main-content' });
      if (typeof options.answerHTML === 'string') {
        // Synthetic observed fixture only; this never runs in provider content.
        final.innerHTML = options.answerHTML;
        literal = final.querySelector('pre');
      } else {
        const paragraph = node('p', { class: 'ds-markdown-paragraph' });
        literal = node('span', {}, options.reply); paragraph.append(literal); final.append(paragraph);
      }
      answer.append(final); answerTurn.append(answer); transcript.append(answerTurn);
    } else literal.textContent = options.reply;
    if (!rail || !rail.isConnected) {
      rail = node('div', { class: 'ds-flex _965abe9' });
      for (let index = 0; index < 6; index++) {
        const attributes = { role: 'button', class: 'ds-button', tabindex: '0' };
        if (index === 4) attributes['aria-label'] = 'Read aloud';
        rail.append(node('div', attributes, 'Action ' + (index + 1)));
      }
      answerTurn.append(rail);
    }
    setArrow(true);
  }
  function resumeStreaming() {
    rail?.remove(); setArrow(false);
  }
  function canonicalize() {
    if (!submitted) return;
    window.history.replaceState({}, '', conversationPath);
    if (!options.delayUser) appendUser();
  }
  send.addEventListener('click', () => {
    if (submitted || !editor.value || send.classList.contains('ds-button--disabled') || selected(search)) {
      counters.earlySends++; return;
    }
    counters.sends++; submitted = true; sent = editor.value; prompts.push(sent);
    editor.value = ''; send.classList.add('ds-button--disabled'); setArrow(false);
    delayed(options.canonicalDelayMs, canonicalize);
  });
  function remountComposer() {
    const old = editor.closest('._020ab5b'), replacement = old.cloneNode(true);
    old.replaceWith(replacement);
    editor = replacement.querySelector('textarea'); editor.value = '';
    [deepThink, search] = replacement.querySelectorAll('.ds-toggle-button');
    send = replacement.querySelector('.ds-button--circle');
    // Any adapter mutation of this new composer is a test failure, even though
    // the fixture deliberately supplies no handler that could repair its mode.
    editor.addEventListener('input', () => counters.inputs++);
    deepThink.addEventListener('click', () => counters.deepThinkClicks++);
    search.addEventListener('click', () => counters.searchClicks++);
    send.addEventListener('click', () => counters.earlySends++);
  }
  window.deepseekFixture = { options, counters, canonical, conversationID, appendUser, completeResponse,
    resumeStreaming, canonicalize, setMode, remountComposer, closeDeletionMenu, showConfirmation, stopMenuWakeups,
    snapshot() { return { counters: { ...counters }, submitted, promptCount: prompts.length,
      promptLength: sent.length, userPresent: !!userTurn?.isConnected, answerPresent: !!answerTurn?.isConnected,
      mode: selected(deepThink) ? 'deepthink' : 'chat', search: selected(search), canonical: location.href === canonical,
      root: location.pathname === '/', menuPresent: !!deletionMenu?.isConnected, dialogPresent: !!modal?.isConnected, historyPresent: !!ownHistory?.isConnected }; } };
  window.fixtureReady = true;
})();
</script></body></html>

"""#
}
