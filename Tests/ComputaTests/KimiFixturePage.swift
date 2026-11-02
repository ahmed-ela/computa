// Offline observed-shape fixture; no provider requests or credentials.
enum KimiFixturePage {
    static let html = #"""
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Offline Kimi adapter fixture</title>
    <style>
      body { font: 14px system-ui; margin: 20px; height: 680px; display:flex; flex-direction:column; gap:12px; }
      [hidden] { display:none !important; }
      .current-model,.chat-header-content { display:inline-block; padding:10px; border:1px solid #aaa; cursor:pointer; }
      .kimi-menu-positioner { position:fixed; top:70px; left:20px; width:300px; padding:10px; background:#eee; z-index:20; }
      .kimi-menu-positioner button,.kimi-menu-item { display:block; width:100%; box-sizing:border-box; padding:12px; cursor:pointer; }
      #fixture-delete-menu { left:350px; width:200px; }
      #fixture-more-menu { left:350px; top:200px; width:200px; }
      #fixture-messages { overflow:auto; flex:1; min-height:200px; }
      .user-content__text { display:block; white-space:pre-wrap; max-height:160px; overflow:auto; }
      .chat-editor-input-wrap { min-height:90px; }
      .chat-input-editor { min-height:70px; max-height:130px; overflow:auto; width:700px; padding:8px; border:1px solid #aaa; white-space:pre-wrap; }
      .send-button-container { width:40px; height:36px; border:1px solid #888; cursor:pointer; }
      .send-icon { width:24px; height:24px; display:block; }
      .disabled { opacity:.5; }
      .segment-assistant-actions .icon-button { display:inline-block; width:28px; height:28px; border:1px solid #aaa; margin:4px; }
      .modal-mask { position:fixed; inset:0; display:flex; align-items:center; justify-content:center; background:#0004; z-index:100; }
      .modal-container { background:white; width:460px; padding:20px; }
      .modal-container .bottom { display:flex; gap:20px; margin-top:20px; }
      .modal-container button { padding:10px 20px; }
      pre { white-space:pre-wrap; }
    </style></head><body>
    <div>
      <div class="current-model" data-testid="model-select-trigger" id="fixture-model-trigger"
        aria-controls="fixture-model-menu" aria-haspopup="menu" aria-expanded="false">
        <span class="model-name"><span class="name">Instant</span></span><span class="current-effort">High</span>
      </div>
      <header class="chat-header-content desktop-no-drag" id="fixture-header-trigger"
        aria-controls="fixture-delete-menu" aria-haspopup="menu" aria-expanded="false" hidden><h2>Synthetic fixture chat</h2></header>
    </div>
    <div class="kimi-menu-positioner" role="menu" id="fixture-model-menu" aria-labelledby="fixture-model-trigger" hidden>
      <div class="model-list-options" data-testid="model-list-options">
        <button type="button" data-testid="model-option" role="menuitemradio" data-model-family="agent" data-moon-key="k3d1-agent" aria-checked="false"><span class="model-name"><span class="name">K3.1 Pro</span></span></button>
        <button type="button" data-testid="model-option" role="menuitemradio" data-model-family="agent" data-moon-key="k28-agent-preview" aria-checked="false"><span class="model-name"><span class="name">K2.8 Preview</span></span></button>
        <button type="button" data-testid="model-option" role="menuitemradio" data-model-family="plain-chat" data-moon-key="k28-instant" aria-checked="true"><span class="model-name"><span class="name">Instant</span></span></button>
      </div>
      <button type="button" data-testid="model-more-trigger" aria-label="More models" role="menuitem"
        data-close-on-select="false" aria-haspopup="menu" aria-expanded="false" id="fixture-more-trigger" aria-controls="fixture-more-menu">
        More models <span class="more-models-current"></span>
      </button>
    </div>
    <div class="kimi-menu-positioner" role="menu" id="fixture-more-menu" aria-labelledby="fixture-more-trigger" hidden>
      <div data-testid="model-more-option" data-model-id="k3-agent" role="menuitemradio" aria-checked="false" data-close-on-select="inherit">
        <span class="kimi-menu-item__label">K3</span>
      </div>
    </div>
    <main id="fixture-messages"></main>
    <div class="chat-editor-content"><div class="chat-editor-input-wrap"><div class="chat-input"><div class="chat-input-editor-container">
      <div class="chat-input-editor" contenteditable="true" role="textbox" data-lexical-editor="true"><p><br></p></div>
    </div></div></div></div>
    <div class="send-button-container disabled"><svg class="iconify send-icon" name="Send" role="img" viewBox="0 0 24 24"><path d="M12 2L22 20H2Z"></path></svg></div>
    <script>
    (() => {
      const model = document.getElementById('fixture-model-trigger'), menu = document.getElementById('fixture-model-menu');
      const more = document.getElementById('fixture-more-trigger'), moreMenu = document.getElementById('fixture-more-menu');
      const moreCurrent = more.querySelector('.more-models-current'), moreOption = moreMenu.querySelector('[data-testid="model-more-option"]');
      const editor = document.querySelector('.chat-input-editor'), send = document.querySelector('.send-button-container');
      const header = document.getElementById('fixture-header-trigger'), messages = document.getElementById('fixture-messages');
      const canonical = '/chat/11111111-abcd-4333-8444-555555555555';
      const provisional = '/chat/p1111111-2222-4333-8444-555555555555?chat_enter_method=home';
      const options = { delayUser: false, holdProvisional: false, holdResponse: false,
        menuDelayMs: 0, dialogDelayMs: 0, canonicalDelayMs: 60, retainHistoryLink: false,
        moreOpenDelayMs: 0, moreCloseDelayMs: 0,
        lexicalDelayMs: 0, lexicalNeverSettle: false, lexicalWrongText: false, preventNativeInput: true,
        reply: '{"type":"message","text":"Offline Kimi fixture reply"}' };
      const counters = { beforeInput: 0, input: 0, settlements: 0, earlySends: 0, sends: 0,
        modelOpens: 0, modelSelections: 0, moreOpens: 0, moreCloses: 0, moreSelections: 0, moreClicks: 0,
        headerOpens: 0, deleteSelections: 0, confirmations: 0 };
      let outbound = null, user = null, answer = null, historyLink = null;
      let nativeInput = null, pendingCommit = null, lexicalSettled = false;
      const inputEvents = []; let firstEventData = null;
      window.fixturePrompts = [];
      function hideMore() { moreMenu.hidden = true; more.setAttribute('aria-expanded', 'false'); }
      function hideModel() { menu.hidden = true; model.setAttribute('aria-expanded', 'false'); hideMore(); }
      model.addEventListener('click', () => {
        if (!menu.hidden) hideModel();
        else { counters.modelOpens++; menu.hidden = false; model.setAttribute('aria-expanded', 'true'); }
      });
      // Candidate fixture only: a click has no submenu effect. Real WebKit
      // dispatch reaches these ordinary handlers; no adapter state is read.
      more.addEventListener('click', () => { counters.moreClicks++; });
      more.addEventListener('pointerover', event => {
        if (event.target !== more || event.pointerType !== 'mouse' || event.relatedTarget !== menu) return;
        counters.moreOpens++;
        setTimeout(() => { moreMenu.hidden = false; more.setAttribute('aria-expanded', 'true'); }, options.moreOpenDelayMs);
      });
      more.addEventListener('pointerout', event => {
        if (event.target !== more || event.pointerType !== 'mouse' || event.relatedTarget !== document.body) return;
        counters.moreCloses++; setTimeout(hideMore, options.moreCloseDelayMs);
      });
      moreOption.addEventListener('click', () => { counters.moreSelections++; });
      for (const row of menu.querySelectorAll('[data-testid="model-option"]')) row.addEventListener('click', () => {
        counters.modelSelections++;
        for (const other of menu.querySelectorAll('[data-testid="model-option"]')) other.setAttribute('aria-checked', String(other === row));
        moreOption.setAttribute('aria-checked', 'false'); moreCurrent.textContent = '';
        model.querySelector('.name').textContent = row.querySelector('.name').textContent; hideModel();
      });
      // Model the observed controlled-editor boundary using actual browser
      // input events. No prompt argument, adapter state or test request is read.
      // The default cancels the native edit and commits the beforeinput payload;
      // the explicit comparison mode retains native substitution events as
      // evidence. This is a bounded fixture, not a bundled Lexical runtime.
      function recordInputEvent(event) {
        if (inputEvents.length >= 32) return;
        const data = typeof event.data === 'string' ? event.data : null;
        if (firstEventData === null && data !== null) firstEventData = data;
        let hash = 2166136261;
        if (data !== null) for (let i = 0; i < data.length; i++) hash = Math.imul(hash ^ data.charCodeAt(i), 16777619) >>> 0;
        inputEvents.push({ event: event.type, inputType: ['insertText','insertReplacementText','insertParagraph','insertLineBreak'].includes(event.inputType) ? event.inputType : 'other',
          dataLength: data?.length ?? null, dataFNV1a: data === null ? null : hash.toString(16).padStart(8, '0'),
          sameAsFirst: data !== null && data === firstEventData, cancelable: event.cancelable, defaultPrevented: event.defaultPrevented });
      }
      function queueEditorCommit(captured) {
        lexicalSettled = false;
        const empty = document.createElement('p'); empty.append(document.createElement('br'));
        editor.replaceChildren(empty); send.classList.add('disabled');
        // One execCommand can emit an input event per paragraph. Coalesce that
        // one real beforeinput payload, without losing it on later input events
        // or manufacturing text from the native request/adapter state.
        if (!captured || captured.scheduled) return;
        captured.scheduled = true;
        pendingCommit = () => {
          if (nativeInput !== captured || !editor.isConnected) return;
          nativeInput = null;
          const paragraph = document.createElement('p'); paragraph.dir = 'ltr';
          const span = document.createElement('span'); span.setAttribute('data-lexical-text', 'true');
          span.textContent = options.lexicalWrongText ? captured.text + 'foreign edit' : captured.text;
          paragraph.append(span); editor.replaceChildren(paragraph);
          lexicalSettled = true; counters.settlements++;
          send.classList.toggle('disabled', !span.textContent);
        };
        if (!options.lexicalNeverSettle) setTimeout(() => {
          const commit = pendingCommit; pendingCommit = null; commit?.();
        }, options.lexicalDelayMs);
      }
      editor.addEventListener('beforeinput', event => {
        counters.beforeInput++;
        nativeInput = event.inputType === 'insertText' && typeof event.data === 'string'
          ? { text: event.data, scheduled: false } : null;
        if (options.preventNativeInput && nativeInput) {
          event.preventDefault();
          if (event.defaultPrevented) queueEditorCommit(nativeInput);
        }
        recordInputEvent(event);
      });
      editor.addEventListener('input', event => {
        counters.input++; recordInputEvent(event);
        queueEditorCommit(nativeInput);
      });
      function completeResponse() {
        if (!answer || answer.querySelector('.segment-assistant-actions')) return;
        const rail = document.createElement('div'); rail.className = 'segment-assistant-actions';
        const content = document.createElement('div'); content.className = 'segment-assistant-actions-content';
        for (let index = 0; index < 5; index++) { const icon = document.createElement('div'); icon.className = 'icon-button'; content.append(icon); }
        rail.append(content); answer.append(rail);
      }
      function appendUser() {
        if (user || typeof outbound !== 'string') throw new Error('Invalid fixture append');
        user = document.createElement('div'); user.className = 'chat-content-item chat-content-item-user';
        user.setAttribute('data-archer-id', 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
        user.setAttribute('data-conversation-turn-id', 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
        const userContent = document.createElement('div'); userContent.className = 'user-content';
        const userText = document.createElement('span'); userText.className = 'user-content__text'; userText.textContent = outbound;
        userContent.append(userText); user.append(userContent); messages.append(user);
        answer = document.createElement('div'); answer.className = 'chat-content-item chat-content-item-assistant';
        answer.setAttribute('data-archer-id', 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff');
        answer.innerHTML = '<div class="segment-content-box"><div class="toolcall-rollup">'
          + '<div class="toolcall-rollup__part toolcall-rollup__flat"><div class="toolcall-flow">Thinking complete Used 0 tools</div></div>'
          + '<div class="toolcall-rollup__part toolcall-rollup__flat"><div class="markdown-container"><div class="markdown">'
          + '<div class="segment-code"><div class="sticky-release"><header class="segment-code-header"><span class="segment-code-lang">JSON</span> '
          + '<div role="tooltip" data-testid="icon-button-tooltip">Copy</div></header></div>'
          + '<div class="syntax-highlighter light segment-code-content"><pre class="language-json"><code class="language-json"></code></pre></div>'
          + '</div></div></div></div></div></div>';
        answer.querySelector('code').textContent = options.reply; messages.append(answer);
        header.hidden = false;
        historyLink = document.createElement('a'); historyLink.href = canonical; historyLink.textContent = 'Synthetic fixture history'; document.body.append(historyLink);
        if (!options.holdResponse) completeResponse();
      }
      send.addEventListener('click', () => {
        if (!lexicalSettled) { counters.earlySends++; return; }
        if (send.classList.contains('disabled') || outbound !== null) return;
        // Model this fixture editor's logical paragraphs independently of
        // WebKit's rendered paragraph spacing. No adapter-private state is read.
        const paragraphs = [...editor.children];
        if (!paragraphs.length || paragraphs.some(node => node.tagName !== 'P')) throw new Error('Unexpected fixture editor paragraphs');
        counters.sends++; outbound = paragraphs.map(node => node.textContent).join('\n'); window.fixturePrompts.push(outbound);
        editor.replaceChildren(); send.classList.add('disabled'); history.pushState({}, '', provisional);
        if (!options.delayUser) appendUser();
        if (!options.holdProvisional) setTimeout(() => history.replaceState({}, '', canonical), options.canonicalDelayMs);
      });
      function showConfirmation() {
        const mask = document.createElement('div'); mask.className = 'modal-mask';
        mask.innerHTML = '<div class="modal-container" data-testid="confirm-dialog"><div class="header"><div class="title">Permanently delete chat</div></div>'
          + '<div class="body">This chat data will be permanently deleted and cannot be recovered. Are you sure you want to delete?</div>'
          + '<div class="bottom"><button type="button" data-testid="confirm-dialog-cancel" class="km-button">Cancel</button>'
          + '<button type="button" data-testid="confirm-dialog-confirm" class="km-button km-button-danger">Delete</button></div></div>';
        document.body.append(mask);
        mask.querySelector('[data-testid="confirm-dialog-cancel"]').addEventListener('click', () => mask.remove());
        mask.querySelector('[data-testid="confirm-dialog-confirm"]').addEventListener('click', () => {
          counters.confirmations++; user?.remove(); answer?.remove(); header.hidden = true; mask.remove();
          if (!options.retainHistoryLink) historyLink?.remove();
          editor.replaceChildren(); send.classList.add('disabled'); history.replaceState({}, '', '/');
        });
      }
      function showDeleteMenu() {
        const popup = document.createElement('div'); popup.id = 'fixture-delete-menu'; popup.className = 'kimi-menu-positioner';
        popup.setAttribute('role', 'menu'); popup.setAttribute('aria-labelledby', 'fixture-header-trigger');
        const row = document.createElement('div'); row.className = 'kimi-menu-item is-danger'; row.setAttribute('role', 'menuitem');
        row.setAttribute('data-kimi-menu-item', ''); row.setAttribute('data-close-on-select', 'inherit');
        const label = document.createElement('span'); label.className = 'kimi-menu-item__label'; label.textContent = 'Delete'; row.append(label);
        popup.append(row); document.body.append(popup); header.setAttribute('aria-expanded', 'true');
        row.addEventListener('click', () => {
          counters.deleteSelections++; popup.remove(); header.setAttribute('aria-expanded', 'false');
          setTimeout(showConfirmation, options.dialogDelayMs);
        });
      }
      header.addEventListener('click', () => { counters.headerOpens++; setTimeout(showDeleteMenu, options.menuDelayMs); });
      window.kimiFixture = { options, counters, inputEvents, appendUser, completeResponse,
        selectNestedInitially: () => {
          for (const row of menu.querySelectorAll('[data-testid="model-option"]')) row.setAttribute('aria-checked', 'false');
          moreOption.setAttribute('aria-checked', 'true'); moreCurrent.textContent = 'K3';
          model.querySelector('.name').textContent = 'K3';
        },
        settleInput: () => { const commit = pendingCommit; pendingCommit = null; commit?.(); },
        canonicalize: () => history.replaceState({}, '', canonical),
        resumeStreaming: () => answer?.querySelector('.segment-assistant-actions')?.remove() };
      window.fixtureReady = true; window.fixtureGeneration = 'initial';
    })();
    </script></body></html>
    """#
}
