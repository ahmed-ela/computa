import { BridgeError, keys, requireValue, text } from "./commands.js";

export const WEB_PROVIDERS = Object.freeze({
  chatgpt: { origin: "https://chatgpt.com", root: "https://chatgpt.com/?temporary-chat=true" },
  gemini: { origin: "https://gemini.google.com", root: "https://gemini.google.com/app" },
});
const MAX_PROMPT = 180_000;
const MAX_RESPONSE = 220_000;
const MAX_SESSIONS = 4;
const TURN_TIMEOUT_MS = 180_000;
const READY_TIMEOUT_MS = 45_000;
const STABLE_RESPONSE_MS = 1_600;
const LEDGER_KEY = "computaOwnedWebProviderTabsV1";

export function conversationURL(provider, rawURL) {
  try {
    const url = new URL(rawURL);
    if (url.origin !== WEB_PROVIDERS[provider]?.origin) return null;
    const pattern = provider === "chatgpt" ? /^\/c\/(?:[a-zA-Z0-9-]+|local-chatgpt(?:%3[Aa]|:)[a-zA-Z0-9-]+)\/?$/ : /^\/(?:u\/\d+\/)?app\/[a-zA-Z0-9_-]+\/?$/;
    return pattern.test(url.pathname) ? url.origin + url.pathname.replace(/\/$/, "") : null;
  } catch { return null; }
}
export function freshURL(provider, rawURL) {
  try {
    const url = new URL(rawURL);
    return url.origin === WEB_PROVIDERS[provider]?.origin
      && (provider === "chatgpt" ? url.pathname === "/" : /^\/(?:u\/\d+\/)?app\/?$/.test(url.pathname));
  } catch { return false; }
}

// This fixed function is the only provider DOM program. Prompts are separately
// passed to Chrome's Input.insertText, never interpolated as executable code.
// It runs in an isolated main-frame world and returns only this owned chat.
export function providerPageAction(input) {
  const { provider, action, expectedConversation, expectedConversationIdentity, expectedURL, prompt } = input;
  if (window !== window.top || document.URL !== expectedURL) return { error: "document_changed" };
  const origin = provider === "chatgpt" ? "https://chatgpt.com" : "https://gemini.google.com";
  if (location.origin !== origin) return { error: "sign_in_required" };
  const cleanURL = location.origin + location.pathname.replace(/\/$/, "");
  if (expectedConversation && cleanURL !== expectedConversation) return { error: "conversation_changed" };
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert], [aria-hidden="true"]');
  const conversationIdentities = provider === "chatgpt" ? [...new Set([...document.querySelectorAll("[data-chatgpt-selection-conversation-id]")]
    .filter(visible).map(node => node.getAttribute("data-chatgpt-selection-conversation-id")).filter(Boolean))] : [];
  const conversationIdentity = conversationIdentities.length === 1 ? conversationIdentities[0] : null;
  if (expectedConversationIdentity && conversationIdentity !== expectedConversationIdentity) return { error: "conversation_changed" };
  const enabled = node => visible(node) && !node.disabled && node.getAttribute("aria-disabled") !== "true";
  const find = selectors => selectors.flatMap(selector => [...document.querySelectorAll(selector)]).find(visible);
  const labelled = (nodes, expression) => [...nodes].filter(visible).find(node => expression.test(
    [node.getAttribute("aria-label"), node.getAttribute("data-testid"), node.getAttribute("title"), node.innerText].filter(Boolean).join(" ").trim()));
  const composer = provider === "chatgpt" ? find(["#prompt-textarea", '[contenteditable="true"][aria-label="Ask ChatGPT"]', 'textarea[data-testid="prompt-textarea"]'])
    : find(['rich-textarea [contenteditable="true"]', 'div.ql-editor[contenteditable="true"]']);
  const modernChatGPTAnswers = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')].filter(visible);
  const responseNodes = provider === "chatgpt"
    ? modernChatGPTAnswers.length ? modernChatGPTAnswers
      : [...document.querySelectorAll('[data-message-author-role="assistant"]')].map(node => node.querySelector(".markdown") || node).filter(visible)
    : [...document.querySelectorAll(".model-response-text, model-response .markdown")].filter(visible);
  // Avoid duplicate Gemini descendants when the provider adds a wrapper class.
  const answers = responseNodes.filter(node => !responseNodes.some(other => other !== node && other.contains(node)));
  const userCount = provider === "chatgpt" ? document.querySelectorAll('[data-message-author-role="user"], [data-markdown-text-style="user-message"]').length
    : document.querySelectorAll("user-query").length;
  const stop = provider === "chatgpt" ? find(['button[data-testid="stop-button"]', 'button[aria-label="Stop streaming"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]'])
    : find(['button[aria-label="Stop response"]', 'button[aria-label="Stop generating"]', 'button[aria-label="Stop"]', 'button.stop-button']);
  const answer = answers.at(-1);
  const answerText = answer ? (answer.innerText || answer.textContent || "").trim() : "";
  let answerComplete = false;
  if (provider === "chatgpt" && answer) {
    const answerSelector = modernChatGPTAnswers.length ? '[data-markdown-text-style="assistant-message"]' : '[data-message-author-role="assistant"]';
    // The current Copy footer is a sibling of the selection wrapper. Keep the
    // search inside an ancestor containing only this one assistant answer.
    for (let node = answer, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
      if (node.querySelectorAll(answerSelector).length > 1) break;
      const copy = node.querySelector('.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"], button[aria-label="Copy"]');
      if (enabled(copy)) { answerComplete = true; break; }
    }
  } else if (answer) {
    answerComplete = !!answer.closest("model-response")?.querySelector('button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]');
  }
  const temporary = provider === "chatgpt"
    ? !!find(['button[aria-label="Turn off temporary chat"]'])
      || (new URL(document.URL).searchParams.get("temporary-chat") === "true"
        && [...document.querySelectorAll("button")].some(node => visible(node)
          && (node.getAttribute("aria-label") === "Save chat" || (node.innerText || "").trim() === "Save chat")))
    : !!find(['button[aria-label="Turn off temporary chat"]', 'button[aria-label="Exit temporary chat"]'])
      || [...document.querySelectorAll('h1, h2, span.info-text')].some(node => visible(node)
        && !node.closest('button, [role="menu"], [role="tooltip"], model-response, user-query')
        && ["Just stopping by?", "Temporary Chat"].includes((node.textContent || "").trim()));
  const state = { url: document.URL, temporary, conversationIdentity, composer: !!composer, responseCount: answers.length, userCount,
    busy: !!stop, text: answerText.slice(0, 220_001), answerComplete };
  if (action === "inspect") {
    const signIn = !composer && !!labelled(document.querySelectorAll('a, button'), /^(?:Log in|Sign in)(?:\s|$)/i);
    return { ...state, signIn };
  }
  if (action === "enableTemporary") {
    if (temporary) return { ...state, enabled: true };
    if (userCount || answers.length) return { error: "not_fresh" };
    const toggle = find(['button[aria-label="Temporary chat"]']);
    if (!enabled(toggle)) return { error: "temporary_mode_unavailable" };
    toggle.click(); return { ...state, enabled: false };
  }
  if (action === "prepare") {
    if (!enabled(composer) || stop) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if (value?.trim()) return { error: "composer_not_empty" };
    composer.focus();
    return { ...state, prepared: document.activeElement === composer || composer.contains(document.activeElement) };
  }
  if (action === "submit") {
    if (!enabled(composer) || stop) return { error: "composer_unavailable" };
    const value = composer instanceof HTMLTextAreaElement ? composer.value : composer.innerText;
    if ((value || "").replace(/\r\n/g, "\n").trim() !== prompt.trim()) return { error: "prompt_not_inserted" };
    const send = provider === "chatgpt" ? find(['button[data-testid="send-button"]', 'button[aria-label="Send prompt"]', 'button[aria-label="Send message"]', 'button[aria-label="Send"]'])
      : find(['button[aria-label="Send message"]', 'button[aria-label="Send"]', 'button.send-button']);
    if (!enabled(send)) return { error: "send_unavailable" };
    send.click();
    return { submitted: true };
  }
  if (action === "stop") { if (enabled(stop)) stop.click(); return { stopped: !!stop }; }
  return { error: "unknown_action" };
}

export class WebProviderSessions {
  constructor({ chrome, uuid = () => crypto.randomUUID(), bounded, check, now = () => Date.now(), sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), emit = () => {} }) {
    Object.assign(this, { chrome, uuid, bounded, check, now, sleep, emit });
    this.sessions = new Map();
    this.storageQueue = Promise.resolve();
    this.cleanupFailures = [];
  }
  saveLedger() {
    if (!this.chrome.storage?.session) return Promise.resolve();
    const entries = [...this.sessions.values()].map(session => ({ token: session.token, tabId: session.tabId,
      provider: session.provider, conversation: session.conversation, submitted: session.submitted,
      temporary: session.temporary === true, conversationIdentity: session.conversationIdentity ?? null, promoted: session.promoted === true, cleanup: session.cleanup }));
    const saved = this.storageQueue.then(() => this.chrome.storage.session.set({ [LEDGER_KEY]: entries }));
    this.storageQueue = saved.catch(() => {});
    return saved;
  }
  async initialize() {
    if (!this.chrome.storage?.session) return;
    const stored = (await this.chrome.storage.session.get(LEDGER_KEY))[LEDGER_KEY];
    if (!Array.isArray(stored)) return;
    // Session storage survives worker restarts, but is cleared on browser exit,
    // preventing a new Chrome process from reusing an old tab ID as authority.
    for (const entry of stored.slice(0, MAX_SESSIONS)) {
      if (!entry || !text(entry.token, 128) || !Number.isSafeInteger(entry.tabId)
        || !Object.hasOwn(WEB_PROVIDERS, entry.provider)
        || !(entry.conversation === null || conversationURL(entry.provider, entry.conversation) === entry.conversation)) continue;
      this.sessions.set(entry.token, { ...entry, generation: null, revision: -1, revoked: true,
        created: this.now(), state: "interrupted", sequence: 0, response: "", recovered: true });
    }
    await Promise.allSettled([...this.sessions.values()].map(async session => {
      try { await this.bounded(this.chrome.debugger.attach({ tabId: session.tabId }, "1.3"), 1_000); } catch {}
      // Never resume a prompt after a worker restart. Only the exact owned tab's
      // temporary session may be verified and removed.
      const result = await this.finish(session);
      if (result.cleanup === "failed") this.noteCleanupFailure(session);
    }));
  }
  validate(operation, params) {
    if (operation === "webProviderStart") requireValue(keys(params, ["provider"]) && Object.hasOwn(WEB_PROVIDERS, params.provider));
    else if (operation === "webProviderSend") requireValue(keys(params, ["sessionToken", "prompt"]) && text(params.sessionToken, 128) && text(params.prompt, MAX_PROMPT));
    else requireValue(keys(params, ["sessionToken"]) && text(params.sessionToken, 128));
  }
  async command(session, method, params = {}, cleanup = false) {
    if (!cleanup) {
      this.check(session.generation, session.revision);
      requireValue(!session.revoked, "web_stale_session", "The website session was revoked.");
    }
    return this.bounded(this.chrome.debugger.sendCommand({ tabId: session.tabId }, method, params), 1_500);
  }
  async page(session, action, extra = {}, cleanup = false) {
    requireValue(!cleanup || ["inspect", "stop"].includes(action));
    const tree = await this.command(session, "Page.getFrameTree", {}, cleanup);
    const frame = tree?.frameTree?.frame;
    requireValue(frame && text(frame.id) && text(frame.url, 16_384), "web_invalid_document", "The website returned no main document.");
    const rawURL = frame.url + (frame.urlFragment ?? "");
    const owned = conversationURL(session.provider, rawURL);
    // ChatGPT first allocates a local DOM conversation ID, then promotes the
    // route to a DIFFERENT server UUID. Admit the route transition only once,
    // after the exact same DOM conversation identity and temporary mode agree.
    const promotion = session.provider === "chatgpt" && session.conversation
      && /\/c\/local-chatgpt(?:%3[Aa]|:)[a-zA-Z0-9-]+$/.test(session.conversation)
      && owned && !/\/local-chatgpt/.test(owned) && !session.promoted;
    if (session.conversation && owned !== session.conversation && !promotion)
      throw new BridgeError("web_conversation_changed", "The owned website chat changed. Cleanup was not redirected to another conversation.");
    if (!session.conversation && owned) {
      requireValue(session.submitted, "web_not_fresh", "The website opened an existing conversation. It was not modified.");
      session.conversation = owned;
      await this.saveLedger();
    }
    if (!owned && !freshURL(session.provider, rawURL)) {
      throw new BridgeError("web_sign_in_required", "Sign in to this website in Chrome, then retry.");
    }
    const world = await this.command(session, "Page.createIsolatedWorld", { frameId: frame.id, worldName: "computa-web-provider-v1", grantUniveralAccess: false }, cleanup);
    requireValue(Number.isSafeInteger(world.executionContextId), "web_invalid_document", "The website document could not be inspected.");
    const payload = { provider: session.provider, action, expectedURL: rawURL,
      expectedConversation: promotion ? null : session.conversation,
      expectedConversationIdentity: session.conversationIdentity ?? null, ...extra };
    const source = providerPageAction.toString();
    const result = await this.command(session, "Runtime.evaluate", { expression: `(${source})(${JSON.stringify(payload)})`, contextId: world.executionContextId,
      returnByValue: true, awaitPromise: true }, cleanup);
    requireValue(!result.exceptionDetails && result.result?.value && typeof result.result.value === "object", "web_invalid_document", "The provider page could not be inspected.");
    const value = result.result.value;
    if (value.error) throw new BridgeError(`web_${value.error}`, "The website interface changed or the owned chat is unavailable. No browser action was replayed.");
    if (promotion) {
      requireValue(session.temporary && value.temporary && text(session.conversationIdentity, 256)
        && value.conversationIdentity === session.conversationIdentity, "web_conversation_changed",
        "The website route changed without the same temporary conversation identity. The tab was left open.");
      session.conversation = owned;
      session.promoted = true;
      await this.saveLedger();
    }
    if (!session.conversationIdentity && text(value.conversationIdentity, 256)) {
      session.conversationIdentity = value.conversationIdentity;
      await this.saveLedger();
    }
    requireValue((value.text?.length ?? 0) <= MAX_RESPONSE, "web_response_too_large", "The website response exceeded the local transport limit.");
    return value;
  }
  get(params, generation, revision) {
    this.check(generation, revision);
    const session = this.sessions.get(params.sessionToken);
    requireValue(session && session.generation === generation && session.revision === revision && !session.revoked,
      "web_stale_session", "The website session is no longer current.");
    return session;
  }
  snapshot(session) {
    const result = { sessionToken: session.token, provider: session.provider, state: session.state,
      text: session.response || "", sequence: session.sequence, cleanup: session.cleanup };
    if (session.failure) result.error = session.failure;
    return result;
  }
  async perform(operation, params, generation, revision) {
    this.validate(operation, params);
    this.check(generation, revision);
    if (operation === "webProviderStart") {
      requireValue(this.sessions.size < MAX_SESSIONS, "web_capacity_exceeded", "Finish an existing website chat before opening another.");
      let creationAbandoned = false;
      const creation = this.chrome.tabs.create({ url: WEB_PROVIDERS[params.provider].root, active: false });
      void creation.then(tab => {
        if (creationAbandoned && Number.isSafeInteger(tab?.id)) return this.chrome.tabs.remove(tab.id).catch(() => {});
      }, () => {});
      let tab;
      try { tab = await this.bounded(creation, 3_000); }
      catch (error) { creationAbandoned = true; throw error; }
      requireValue(Number.isSafeInteger(tab?.id), "web_tab_unavailable", "Chrome could not open the provider website.");
      const session = { token: this.uuid(), tabId: tab.id, provider: params.provider, generation, revision, state: "loading",
        created: this.now(), cleanup: "pending", sequence: 0, response: "", submitted: false, conversation: null, revoked: false };
      try {
        this.check(generation, revision);
        const attachment = this.chrome.debugger.attach({ tabId: tab.id }, "1.3");
        void attachment.then(() => {
          if (session.revoked || !this.sessions.has(session.token) && creationAbandoned)
            return this.chrome.debugger.detach({ tabId: tab.id }).catch(() => {});
        }, () => {});
        await this.bounded(attachment, 3_000);
        this.check(generation, revision);
        this.sessions.set(session.token, session);
        await this.saveLedger();
        return this.snapshot(session);
      } catch (error) {
        creationAbandoned = true;
        session.revoked = true;
        this.sessions.delete(session.token);
        try { await this.bounded(this.chrome.debugger.detach({ tabId: tab.id }), 1_000); } catch {}
        try { await this.bounded(this.chrome.tabs.remove(tab.id), 1_000); } catch {}
        await this.saveLedger();
        throw error;
      }
    }
    const session = this.get(params, generation, revision);
    if (operation === "webProviderFinish" || operation === "webProviderCancel") {
      if (operation === "webProviderCancel" && session.state === "running") {
        try { await this.page(session, "stop", {}, true); } catch {}
      }
      return this.finish(session);
    }
    if (operation === "webProviderSend") {
      requireValue(session.state === "ready" || session.state === "complete", "web_not_ready", "Wait for the website chat to be ready before sending.");
      const before = await this.page(session, "prepare");
      requireValue(before.temporary && session.temporary, "web_temporary_mode_unverified", "The website is no longer in its owned temporary chat mode. No prompt was sent.");
      requireValue(before.prepared, "web_composer_unavailable", "The website composer could not receive text.");
      if (!session.submitted) requireValue(before.responseCount === 0 && before.userCount === 0 && freshURL(session.provider, before.url),
        "web_not_fresh", "The website conversation was not empty. It was not modified.");
      session.baseline = before.responseCount;
      session.response = "";
      session.sequence += 1;
      session.lastChanged = this.now();
      session.turnStarted = this.now();
      await this.command(session, "Input.insertText", { text: params.prompt });
      this.check(generation, revision);
      // Mark submission authority before clicking: a click may succeed even if
      // Chrome's reply is lost, and the new URL still belongs to this session.
      session.submitted = true;
      session.state = "running";
      await this.saveLedger();
      try { await this.page(session, "submit", { prompt: params.prompt }); }
      catch (error) { session.state = "failed"; session.failure = { code: error.code ?? "web_send_failed", message: error.message }; throw error; }
      this.check(generation, revision);
      return this.snapshot(session);
    }
    requireValue(operation === "webProviderPoll", "unsupported_operation", "Unsupported web provider operation.");
    if (!["loading", "running"].includes(session.state)) return this.snapshot(session);
    try {
      const observed = await this.page(session, "inspect");
      this.check(generation, revision);
      if (session.state === "loading") {
        requireValue(!session.conversation && observed.responseCount === 0 && observed.userCount === 0, "web_not_fresh", "The website opened an existing conversation. It was not modified.");
        if (observed.composer) {
          if (observed.temporary) { session.temporary = true; session.state = "ready"; await this.saveLedger(); }
          else if (session.provider === "gemini" && !session.temporaryRequested) {
            await this.page(session, "enableTemporary"); session.temporaryRequested = true;
          } else if (this.now() - session.created > READY_TIMEOUT_MS)
            throw new BridgeError("web_temporary_mode_unverified", "The website did not confirm temporary chat mode. No prompt was sent.");
        }
        else if (observed.signIn) { session.state = "needs_sign_in"; session.failure = { code: "web_sign_in_required", message: "Sign in to this website in Chrome, then retry." }; }
        else if (this.now() - session.created > READY_TIMEOUT_MS) throw new BridgeError("web_ready_timeout", "The website did not become ready in time.");
      } else {
        if (observed.responseCount > session.baseline && observed.text) {
          if (session.response !== observed.text) { session.response = observed.text; session.lastChanged = this.now(); }
          if (!observed.busy && observed.answerComplete && this.now() - session.lastChanged >= STABLE_RESPONSE_MS) session.state = "complete";
        }
        if (session.state === "running" && this.now() - session.turnStarted > TURN_TIMEOUT_MS)
          throw new BridgeError("web_response_timeout", "The website did not complete its response in time.");
      }
    } catch (error) {
      // Loading can briefly expose about:blank during Chrome's initial navigation.
      if (session.state === "loading" && error.code === "web_sign_in_required" && this.now() - session.created < 5_000) return this.snapshot(session);
      session.state = error.code === "web_sign_in_required" ? "needs_sign_in" : "failed";
      session.failure = { code: error.code ?? "web_operation_failed", message: error.message };
    }
    return this.snapshot(session);
  }
  async finish(session) {
    if (session.cleanup === "deleted" || session.cleanup === "not_created") return this.snapshot(session);
    try {
      // One final observation captures any late provider conversation URL and
      // proves that this owned session still has no saved history thread.
      const observed = session.submitted || session.recovered ? await this.page(session, "inspect", {}, true) : null;
      if (!session.submitted) {
        if (observed) requireValue(observed.userCount === 0 && observed.responseCount === 0 && !session.conversation,
          "web_cleanup_unverified", "The owned tab no longer contains its empty starting page. It was left open.");
        session.cleanup = "not_created";
      } else {
        requireValue(session.temporary && observed.temporary, "web_temporary_mode_unverified",
          "Temporary chat mode could not be verified at cleanup. The tab remains open.");
        session.cleanup = "not_created";
      }
      try { await this.bounded(this.chrome.debugger.detach({ tabId: session.tabId }), 1_000); } catch {}
      await this.bounded(this.chrome.tabs.remove(session.tabId), 1_000);
      session.state = "finished";
      session.failure = null;
      this.sessions.delete(session.token);
      this.cleanupFailures = this.cleanupFailures.filter(item => item.sessionToken !== session.token);
      await this.saveLedger();
    } catch (error) {
      session.cleanup = "failed";
      await this.saveLedger();
      session.failure = { code: error.code ?? "web_cleanup_failed", message: "The local response is retained, but cleanup of its temporary website chat could not be verified. The provider tab remains open." };
      this.noteCleanupFailure(session);
    }
    return this.snapshot(session);
  }
  noteCleanupFailure(session) {
    this.cleanupFailures = this.cleanupFailures.filter(item => item.sessionToken !== session.token);
    this.cleanupFailures.push({ provider: session.provider, sessionToken: session.token, error: session.failure });
    this.cleanupFailures = this.cleanupFailures.slice(-16);
  }
  async revokeAll() {
    const sessions = [...this.sessions.values()];
    for (const session of sessions) session.revoked = true;
    await Promise.allSettled(sessions.map(async session => {
      const result = await this.finish(session);
      if (result.cleanup === "failed") this.emit({ version: 1, event: "webProviderCleanupFailed", provider: session.provider,
        sessionToken: session.token, error: result.error });
      try { await this.bounded(this.chrome.debugger.detach({ tabId: session.tabId }), 1_000); } catch {}
    }));
  }
  onDetach(source) {
    const session = [...this.sessions.values()].find(value => source.tabId === value.tabId);
    if (!session || ["deleted", "not_created"].includes(session.cleanup)) return false;
    session.revoked = true;
    session.state = "failed";
    session.cleanup = session.submitted ? "failed" : "not_created";
    session.failure = { code: "web_tab_detached", message: "The owned website tab was closed or its automation was canceled. Website deletion was not verified." };
    this.noteCleanupFailure(session);
    this.emit({ version: 1, event: "webProviderCleanupFailed", provider: session.provider, sessionToken: session.token, error: session.failure });
    return true;
  }
}
