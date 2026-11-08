// Offline observed-shape fixture. No provider requests or credentials.
enum QwenFixturePage {
    static let html = #"""
<!doctype html>
<meta charset="utf-8">
<title>Synthetic Qwen adapter fixture</title>
<style>
  body { font: 15px system-ui; margin: 20px; color: #111; background: white; }
  [hidden] { display: none !important; }
  button, [role=button], [role=option], [role=menuitem] { display: inline-block; padding: 9px 14px; margin: 4px; cursor: pointer; }
  .wms-list, [role=menu], [role=dialog] { padding: 12px; border: 1px solid #555; background: #fafafa; }
  .wms-list__item { display: block; }
  .wms-list__item--selected { background: #ddd; }
  .message-input-container-area { position: fixed; left: 20px; right: 20px; bottom: 20px; background: white; border: 1px solid #777; padding: 8px; z-index: 2; }
  textarea { display: block; box-sizing: border-box; width: 100%; height: 140px; }
  .qwen-chat-message-select-turn { margin-bottom: 240px; }
  .user-message-content { white-space: pre-wrap; max-height: 120px; overflow: auto; }
  .chunked-text-renderer-root-with-expand .user-message-content { min-height: 16px; }
  .chat-menu-trigger { position: fixed; right: 20px; top: 20px; z-index: 3; }
  [role=menu], [role=dialog] { position: fixed; right: 30px; top: 85px; max-width: 440px; z-index: 4; }
  .chat-response-message { padding: 12px; }
</style>
<div id="root">
<div class="wms-trigger" role="button" aria-label="Select Model" aria-haspopup="listbox" aria-expanded="false">
  <div class="wms-trigger__text">Qwen3.8-Max</div>
</div>
<div class="wms-list" role="listbox" aria-label="Models" hidden>
  <div class="wms-list__item" role="option" aria-selected="false"><div class="wms-list__name-text">Qwen3.7-Plus</div></div>
  <div class="wms-list__item wms-list__item--selected" role="option" aria-selected="true"><div class="wms-list__name-text">Qwen3.8-Max</div></div>
  <div class="wms-list__item" role="option" aria-selected="false"><div class="wms-list__name-text">Qwen3.8-Omni-Flash</div></div>
</div>
<div id="transcript"></div>
<div id="history"></div>
<div class="message-input-container-area">
  <textarea class="message-input-textarea" autocomplete="off" placeholder="How can I help you today?"></textarea>
  <div class="chat-prompt-send-button"></div>
</div>
</div>
<script>
// This document is synthetic. It performs no network requests and contains no
// provider account data. Only the actual textarea value becomes its user echo.
(() => {
  const conversationID = 'b3669d48-0898-45f8-a25c-e33d50b21dea';
  const userID = '902f136d-bddf-4078-a667-030715aeff87';
  const answerID = '413e8269-7ba8-476b-84f3-c400e8bed55c';
  const canonical = 'https://chat.qwen.ai/c/' + conversationID;
  const options = { delayUser: false, holdRoot: false, holdProvisional: false, useProvisional: false, holdResponse: false, holdResponseIdentity: false, holdResponseContainer: false, firstLongMessageDisplay: false, menuDelayMs: 0,
    dialogDelayMs: 0, canonicalDelayMs: 0, retainHistoryLink: false, modelCloseOrder: "simultaneous", modelOptionCloseOrder: "simultaneous",
    reply: '{"type":"message","text":"Synthetic Qwen native reply"}' };
  const counts = { input: 0, sends: 0, displayClicks: 0, modelOpens: 0, modelCloses: 0, modelSelections: 0, headerOpens: 0, deleteSelections: 0, confirmations: 0 };
  const editor = document.querySelector('textarea'), sendScope = document.querySelector('.chat-prompt-send-button');
  const trigger = document.querySelector('.wms-trigger'), modelName = trigger.querySelector('.wms-trigger__text');
  const picker = document.querySelector('.wms-list'), rows = [...picker.querySelectorAll('[role=option]')];
  const transcript = document.querySelector('#transcript'), history = document.querySelector('#history');
  let submitted = false, sent = '', turn, userBody, assistant, header, deletionMenu, dialog, ownHistory;
  const node = (tag, attrs = {}, text) => {
    const result = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) result.setAttribute(key, value);
    if (text !== undefined) result.textContent = text;
    return result;
  };
  const delayed = (milliseconds, action) => milliseconds > 0 ? setTimeout(action, milliseconds) : action();
  let pickerClosePending = false, optionClosePending = false;
  const closePicker = () => { picker.hidden = true; trigger.setAttribute('aria-expanded', 'false'); pickerClosePending = false; optionClosePending = false; };
  const requestPickerClose = () => {
    counts.modelCloses++;
    // Synthetic split-order completion. The test releases the second channel
    // only after native transport has observed the pending close callback.
    if (options.modelCloseOrder === 'ariaFirst') {
      pickerClosePending = true; trigger.setAttribute('aria-expanded', 'false');
    } else if (options.modelCloseOrder === 'domFirst') {
      pickerClosePending = true; picker.hidden = true;
    } else closePicker();
  };
  trigger.addEventListener('click', () => {
    if (!picker.hidden) requestPickerClose();
    else { counts.modelOpens++; picker.hidden = false; trigger.setAttribute('aria-expanded', 'true'); }
  });
  rows.forEach(row => row.addEventListener('click', () => {
    counts.modelSelections++; modelName.textContent = row.querySelector('.wms-list__name-text').textContent;
    rows.forEach(other => { other.setAttribute('aria-selected', String(row === other)); other.classList.toggle('wms-list__item--selected', row === other); });
    if (options.modelOptionCloseOrder === 'ariaFirst') {
      optionClosePending = true; trigger.setAttribute('aria-expanded', 'false');
    } else if (options.modelOptionCloseOrder === 'domFirst') {
      optionClosePending = true; picker.hidden = true;
    } else closePicker();
  }));
  const sendButton = node('button', { class: 'send-button', 'aria-label': 'Send' }, 'Send');
  const stopButton = node('button', { class: 'stop-button', 'aria-label': 'Stop', 'data-chat-id': conversationID }, 'Stop');
  editor.addEventListener('input', () => {
    counts.input++;
    if (!submitted) sendScope.replaceChildren(...(editor.value ? [sendButton] : []));
  });
  function appendUser() {
    if (!submitted || turn) return;
    turn = node('div', { class: 'qwen-chat-message-select-turn' });
    const userTurn = node('div', { class: 'qwen-chat-message-select-turn-message' });
    const root = node('div', { class: 'qwen-chat-message qwen-chat-message-user' });
    const container = node('div', { class: 'chat-user-message-container', 'data-msg-id': userID, 'data-chat-id': conversationID });
    const chunk = node('div', { class: 'chunked-text-renderer-root' });
    userBody = node('p', { class: 'user-message-content whitespace-pre-wrap' }, sent);
    chunk.append(userBody); container.append(chunk); root.append(container); userTurn.append(root); turn.append(userTurn); transcript.append(turn);
    if (options.firstLongMessageDisplay) {
      chunk.classList.add('chunked-text-renderer-root-with-expand', 'is-collapsed');
      userBody.textContent = '';
      const control = node('button', { class: 'chat-user-message-expand-toggle chat-user-message-expand-toggle-pc', 'aria-label': 'Expand' }, 'Expand');
      chunk.append(control);
      control.addEventListener('click', () => {
        counts.displayClicks++;
        chunk.classList.remove('is-collapsed');
        control.setAttribute('aria-label', 'Collapse');
        userBody.textContent = sent;
      });
    }
    header = node('div', { class: 'chat-menu-trigger' });
    const more = node('button', { 'aria-label': 'More' }, 'More'); header.append(more); document.body.append(header);
    ownHistory = node('a', { href: canonical, 'data-chat-id': conversationID }, 'Synthetic Qwen chat'); history.append(ownHistory);
    more.addEventListener('click', () => {
      counts.headerOpens++;
      delayed(options.menuDelayMs, () => {
        deletionMenu = node('div', { role: 'menu', class: 'qwen-chat-v2-dropdown-menu-popup' });
        const remove = node('div', { role: 'menuitem', class: 'qwen-chat-v2-dropdown-menu-item-danger chat-menu-item-error chat-menu-item' });
        remove.append(node('span', { class: 'qwen-chat-v2-dropdown-menu-item-label' }, 'Delete'));
        deletionMenu.append(remove); document.body.append(deletionMenu);
        remove.addEventListener('click', () => {
          counts.deleteSelections++; deletionMenu.remove();
          delayed(options.dialogDelayMs, () => {
            dialog = node('div', { role: 'dialog', class: 'chat-item-delete-confirm', 'aria-modal': 'true', 'aria-labelledby': 'synthetic-qwen-delete-title' });
            const title = node('div', { class: 'ant-modal-title', id: 'synthetic-qwen-delete-title' }, 'Delete this chat?');
            const body = node('div', { class: 'ant-modal-body' });
            body.append(node('div', { 'data-aes-exp': 'expChatDeleteMiddle', 'data-chat-id': conversationID },
              'Once deleted, this chat cannot be recovered, and the files in it will be permanently removed. If you have shared this conversation, the share link will no longer be accessible.'));
            const buttons = node('div', { class: 'qwen-chat-v2-modal-footer-btns' });
            const cancel = node('button', { class: 'qwen-chat-v2-btn-plain' }, 'Cancel');
            const confirm = node('button', { class: 'qwen-chat-v2-btn-danger' }, 'Delete');
            buttons.append(cancel, confirm); dialog.append(title, body, buttons); document.body.append(dialog);
            cancel.addEventListener('click', () => dialog.remove());
            confirm.addEventListener('click', () => {
              counts.confirmations++; dialog.remove(); turn.remove(); header.remove(); sendScope.replaceChildren();
              if (!options.retainHistoryLink) ownHistory.remove();
              window.history.replaceState({}, '', '/');
            });
          });
        });
      });
    });
    if (options.holdResponseIdentity) mountPendingResponseIdentity();
    else if (!options.holdResponse) completeResponse();
  }
  function mountPendingResponseIdentity() {
    if (!turn || assistant) return;
    const answerTurn = node('div', { class: 'qwen-chat-message-select-turn-message' });
    const root = node('div', { class: 'qwen-chat-message qwen-chat-message-assistant' });
    assistant = node('div', { class: 'chat-response-message', id: 'chat-response-message-' });
    assistant.append(node('div', { class: 'response-loading' }));
    if (!options.holdResponseContainer) root.append(assistant);
    answerTurn.append(root); turn.append(answerTurn);
  }
  function completeResponse() {
    if (!turn || assistant?.querySelector('.phase-answer')) return;
    const root = assistant?.parentElement || node('div', { class: 'qwen-chat-message qwen-chat-message-assistant' });
    const answerTurn = root.parentElement || node('div', { class: 'qwen-chat-message-select-turn-message' });
    if (!assistant) assistant = node('div', { class: 'chat-response-message' });
    assistant.id = 'chat-response-message-' + answerID;
    assistant.replaceChildren();
    const flow = node('div', { class: 'chat-response-message-render-flow' });
    flow.append(node('div', { class: 'qwen-chat-thinking-tool-status-card-wraper' }, 'Synthetic status chrome'));
    const phase = node('div', { class: 'response-message-content t2t phase-answer' });
    const custom = node('div', { class: 'custom-qwen-markdown' });
    const markdown = node('div', { class: 'qwen-markdown qwen-markdown-loose' });
    const paragraph = node('div', { class: 'qwen-markdown-paragraph' });
    const text = node('span', { class: 'qwen-markdown-text' });
    text.append(node('span', { class: 'qwen-markdown-text-node' }, options.reply));
    paragraph.append(text); markdown.append(paragraph); custom.append(markdown); phase.append(custom); flow.append(phase); assistant.append(flow);
    const footer = node('div', { class: 'response-message-footer-actions' });
    const rail = node('div', { class: 'qwen-chat-package-comp-new-action-control', 'data-chat-id': conversationID, 'data-msg-id': answerID });
    for (const label of ['Copy', 'Good Response', 'Bad Response', 'Share', 'Regenerate', 'More actions']) rail.append(node('button', { 'aria-label': label }, label));
    footer.append(rail); assistant.append(footer); root.append(assistant); answerTurn.append(root); turn.append(answerTurn); sendScope.replaceChildren();
  }
  function canonicalize() {
    if (!submitted) return;
    window.history.replaceState({}, '', '/c/' + conversationID);
    sendScope.replaceChildren(stopButton);
    if (!options.delayUser) appendUser();
  }
  sendButton.addEventListener('click', () => {
    counts.sends++;
    if (submitted) throw new Error('Synthetic duplicate Send');
    submitted = true; sent = editor.value; editor.value = ''; sendScope.replaceChildren();
    if (options.useProvisional) {
      window.history.replaceState({}, '', '/c/new-chat');
      if (!options.holdProvisional) delayed(options.canonicalDelayMs, canonicalize);
    } else if (!options.holdRoot) delayed(options.canonicalDelayMs, canonicalize);
  });
  window.qwenFixture = { options, counts, canonicalize, appendUser, completeResponse,
    revealPreview: () => { userBody.textContent = sent.slice(0, 10240); },
    mountResponseContainer: () => document.querySelector('.qwen-chat-message-assistant').append(assistant),
    settleResponseIdentity: () => { assistant.id = "chat-response-message-" + answerID; },
    finishPickerClose: closePicker, finishOptionClose: closePicker,
    pickerState: () => ({ pending: pickerClosePending, optionPending: optionClosePending, expanded: trigger.getAttribute('aria-expanded'), visible: !picker.hidden }),
    snapshot: () => ({ ...counts, path: location.pathname, model: modelName.textContent,
      composerLength: editor.value.length, firstUserLength: userBody?.textContent.length || 0,
      users: document.querySelectorAll('.qwen-chat-message-user').length,
      answers: document.querySelectorAll('.qwen-chat-message-assistant').length,
      dialogs: document.querySelectorAll('[role=dialog]').length }) };
})();
</script>

"""#
}
