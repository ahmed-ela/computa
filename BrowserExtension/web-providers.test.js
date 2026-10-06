import { describe, expect, test } from "bun:test";
import { BridgeError } from "./commands.js";
import { WebProviderSessions, WEB_PROVIDERS, conversationURL, freshURL, providerPageAction } from "./web-providers.js";

function fixture({ provider = "chatgpt", temporary = true, initial = {} } = {}) {
  let clock = 0, uuid = 0, generation = "g", revision = 1;
  const calls = [], stored = structuredClone(initial), events = [];
  const observed = { url: WEB_PROVIDERS[provider].root, composer: true, temporary, responseCount: 0, userCount: 0,
    documentLoaderId: "owned-loader", prepared: true, busy: false, answerComplete: false, text: "" };
  const chrome = {
    tabs: { create: async params => { calls.push(["create", params]); return { id: 42 }; }, remove: async id => calls.push(["remove", id]) },
    debugger: { attach: async target => calls.push(["attach", target]), detach: async target => calls.push(["detach", target]),
      sendCommand: async (target, method, params) => {
        calls.push(["command", target, method, params]);
        return method === "Page.getFrameTree" ? { frameTree: { frame: { id: "owned-frame", url: observed.url, loaderId: observed.documentLoaderId } } } : {};
      } },
    storage: { session: { get: async key => ({ [key]: stored[key] }), set: async value => Object.assign(stored, structuredClone(value)) } },
  };
  const sessions = new WebProviderSessions({ chrome, uuid: () => `session-${++uuid}`, bounded: promise => promise,
    now: () => clock, sleep: async ms => { clock += ms; }, emit: event => events.push(event),
    check: (g, r) => { if (g !== generation || r !== revision) throw new BridgeError("unauthorized", "revoked"); } });
  sessions.page = async (session, action, extra = {}, cleanup = false) => {
    calls.push(["page", action, extra, cleanup]);
    if (!cleanup) sessions.check(session.generation, session.revision);
    return { ...observed, firstUserMarkerVerified: observed.userCount > 0 && !!session.firstUserMarker,
      firstUserIdentity: observed.userCount > 0 ? "owned-user-id" : null,
      firstUserFingerprint: observed.userCount > 0 ? "a".repeat(64) : null,
      submitted: action === "submit", deleted: action === "deleteVerify" };
  };
  const request = (operation, params) => sessions.perform(operation, params, "g", 1);
  const start = async () => request("webProviderStart", { provider });
  const ready = async () => { const started = await start(); await request("webProviderPoll", { sessionToken: started.sessionToken }); return started.sessionToken; };
  return { sessions, chrome, calls, stored, observed, events, request, start, ready,
    advance: ms => { clock += ms; }, revoke: () => { generation = null; revision += 1; } };
}

describe("owned website provider sessions", () => {
  test("creates inactive fresh tabs without adopting signed-in user tabs", async () => {
    const f = fixture(); const started = await f.start();
    expect(started.state).toBe("loading");
    expect(f.calls[0]).toEqual(["create", { url: "https://chatgpt.com/?temporary-chat=true", active: false }]);
    expect(f.calls[1]).toEqual(["attach", { tabId: 42 }]);
    expect(started.sessionToken).toBe("session-1");
  });
  test("requires verified temporary mode and an empty conversation before first send", async () => {
    const f = fixture(); const token = await f.ready(); f.observed.userCount = 1;
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "hello" })).rejects.toMatchObject({ code: "web_not_fresh" });
    expect(f.calls.filter(call => call[0] === "command")).toEqual([]);
    f.observed.userCount = 0; f.observed.temporary = false;
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "hello" })).rejects.toMatchObject({ code: "web_temporary_mode_unverified" });
    expect(f.calls.filter(call => call[0] === "command")).toEqual([]);
  });
  test("Gemini toggles temporary mode only on a verified empty root", async () => {
    const f = fixture({ provider: "gemini", temporary: false }); const started = await f.start();
    expect((await f.request("webProviderPoll", { sessionToken: started.sessionToken })).state).toBe("loading");
    expect(f.calls.some(call => call[0] === "page" && call[1] === "enableTemporary")).toBe(true);
    f.observed.temporary = true;
    expect((await f.request("webProviderPoll", { sessionToken: started.sessionToken })).state).toBe("ready");
  });
  test("keeps the whole response until the provider signals completion and text is stable", async () => {
    const f = fixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "hello" });
    f.observed.responseCount = 1; f.observed.text = "partial"; f.observed.busy = true;
    expect((await f.request("webProviderPoll", { sessionToken: token })).state).toBe("running");
    f.advance(2000); f.observed.busy = false;
    expect((await f.request("webProviderPoll", { sessionToken: token })).state).toBe("running");
    f.observed.answerComplete = true; f.observed.text = "full response";
    expect((await f.request("webProviderPoll", { sessionToken: token })).state).toBe("running");
    f.advance(1600);
    const finished = await f.request("webProviderPoll", { sessionToken: token });
    expect(finished).toMatchObject({ state: "complete", text: "full response", sequence: 1 });
  });
  test("tool followups share their owned session and cannot reuse the previous answer", async () => {
    const f = fixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" });
    f.observed.responseCount = 1; f.observed.text = "first answer"; f.observed.answerComplete = true;
    await f.request("webProviderPoll", { sessionToken: token }); f.advance(1600);
    await f.request("webProviderPoll", { sessionToken: token });
    const sent = await f.request("webProviderSend", { sessionToken: token, prompt: "tool result" });
    expect(sent).toMatchObject({ state: "running", text: "", sequence: 2 });
    f.advance(1600);
    expect((await f.request("webProviderPoll", { sessionToken: token })).state).toBe("running");
  });
  test("verified temporary chats close exactly the owned tab and report no saved web thread", async () => {
    const f = fixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "hello" });
    const result = await f.request("webProviderFinish", { sessionToken: token });
    expect(result).toMatchObject({ state: "finished", cleanup: "not_created" });
    expect(f.calls.filter(call => call[0] === "remove")).toEqual([["remove", 42]]);
    expect(f.calls.some(call => call[0] === "page" && call[1].startsWith("delete"))).toBe(false);
    expect(f.sessions.sessions.size).toBe(0);
  });
  test("cleanup failure preserves the response, surfaces failure and leaves the tab open", async () => {
    const f = fixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "hello" });
    f.sessions.sessions.get(token).response = "saved locally"; f.observed.temporary = false;
    const result = await f.request("webProviderFinish", { sessionToken: token });
    expect(result).toMatchObject({ cleanup: "failed", text: "saved locally", error: { code: "web_temporary_mode_unverified" } });
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
  test("cancel stops its own response before verified cleanup", async () => {
    const f = fixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "hello" });
    expect((await f.request("webProviderCancel", { sessionToken: token })).cleanup).toBe("not_created");
    expect(f.calls.some(call => call[0] === "page" && call[1] === "stop")).toBe(true);
  });
  test("revocation immediately blocks pending prompt input but still permits owned cleanup", async () => {
    const f = fixture(); const token = await f.ready();
    f.revoke();
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "secret" })).rejects.toMatchObject({ code: "unauthorized" });
    await f.sessions.revokeAll();
    expect(f.calls.filter(call => call[0] === "command")).toEqual([]);
    expect(f.calls.filter(call => call[0] === "remove")).toEqual([["remove", 42]]);
  });
  test("a prompt request with extra scripting or target fields is rejected before Chrome", async () => {
    const f = fixture(); const token = await f.ready(); const count = f.calls.length;
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "hi", targetID: "user-tab" })).rejects.toMatchObject({ code: "invalid_request" });
    expect(f.calls.length).toBe(count);
    await expect(f.start().then(() => f.request("webProviderStart", { provider: "https://evil.test" }))).rejects.toMatchObject({ code: "invalid_request" });
  });
  test("response wait is bounded and partial text survives timeout", async () => {
    const f = fixture(); const token = await f.ready(); await f.request("webProviderSend", { sessionToken: token, prompt: "hi" });
    f.observed.responseCount = 1; f.observed.text = "partial"; f.observed.busy = true; f.advance(180001);
    expect(await f.request("webProviderPoll", { sessionToken: token })).toMatchObject({ state: "failed", text: "partial", error: { code: "web_response_timeout" } });
  });
  test("worker ledger retains owned identities, never prompt text, model responses or auth", async () => {
    const f = fixture(); const token = await f.ready(); await f.request("webProviderSend", { sessionToken: token, prompt: "private request" });
    const ledger = JSON.stringify(f.stored);
    expect(ledger).toContain('"tabId":42');
    expect(ledger).not.toContain("private request");
    expect(ledger).not.toContain("pairingToken");
    const next = fixture({ initial: f.stored }); await next.sessions.initialize();
    expect(next.calls.filter(call => call[0] === "remove")).toEqual([["remove", 42]]);
    expect(next.sessions.sessions.size).toBe(0);
  });
});

describe("website identity boundaries", () => {
  test("provider conversation and fresh roots never accept a different origin or arbitrary page", () => {
    expect(conversationURL("chatgpt", "https://chatgpt.com/c/exact-owned-id?x=1")).toBe("https://chatgpt.com/c/exact-owned-id");
    expect(conversationURL("gemini", "https://gemini.google.com/u/1/app/abc")).toBe("https://gemini.google.com/u/1/app/abc");
    expect(conversationURL("chatgpt", "https://chatgpt.com.evil.test/c/a")).toBeNull();
    expect(conversationURL("gemini", "https://gemini.google.com/settings")).toBeNull();
    expect(freshURL("chatgpt", "https://chatgpt.com/?temporary-chat=true")).toBe(true);
    expect(freshURL("gemini", "https://gemini.google.com/u/2/app")).toBe(true);
    expect(freshURL("gemini", "https://gemini.google.com/app/old-chat")).toBe(false);
  });
});

function domNode({ text = "", attributes = {}, parent = null, query = {} } = {}) {
  return { innerText: text, textContent: text, isConnected: true, disabled: false,
    parentElement: parent, querySelectorAll: () => [], getClientRects: () => [{}], getAttribute: key => attributes[key] ?? null,
    querySelector: selector => query[selector] ?? null,
    closest: selector => selector.includes("data-chatgpt-selection-message-id") || selector === "model-response" ? parent : null };
}
function inspectDOM(provider, url, selectors, expectedConversationIdentity = null, action = "inspect", expectedUserCounts = [1], extra = {}, cryptoImplementation = crypto) {
  const document = { URL: url, querySelectorAll: selector => selectors[selector] ?? [] };
  const window = {}; window.top = window;
  const location = new URL(url);
  const execute = new Function("document", "window", "location", "getComputedStyle", "crypto", "input", `return (${providerPageAction.toString()})(input);`);
  return execute(document, window, location, () => ({ visibility: "visible" }), cryptoImplementation, {
    provider, action, expectedURL: url, expectedConversationIdentity, expectedUserCounts,
    expectedFirstUserMarker: "fixture-marker", ...extra });
}


describe("current provider DOM adaptation", () => {
  test("modern ChatGPT temp response is extracted without its controls or page header", async () => {
    const copy = domNode({ attributes: { "aria-label": "Copy" } });
    const wrapper = domNode({ attributes: { "data-chatgpt-selection-conversation-id": "local-chatgpt:owned" },
      query: { '.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"], button[aria-label="Copy"]': copy } });
    const answer = domNode({ text: '{"message":"works"}', parent: wrapper });
    const save = domNode({ text: "Save chat" });
    const composer = domNode();
    const observed = await inspectDOM("chatgpt", "https://chatgpt.com/c/server-id?temporary-chat=true", {
      '[data-chatgpt-selection-conversation-id]': [wrapper],
      '[data-markdown-text-style="assistant-message"]': [answer],
      '[contenteditable="true"][aria-label="Ask ChatGPT"]': [composer], button: [save, copy] }, "local-chatgpt:owned");
    expect(observed).toMatchObject({ temporary: true, composer: true, responseCount: 1, busy: false,
      answerComplete: true, text: '{"message":"works"}', conversationIdentity: "local-chatgpt:owned" });
  });
  test("a different ChatGPT DOM conversation identity is rejected before reading messages", async () => {
    const wrapper = domNode({ attributes: { "data-chatgpt-selection-conversation-id": "other-conversation" } });
    expect(await inspectDOM("chatgpt", "https://chatgpt.com/c/other?temporary-chat=true", {
      '[data-chatgpt-selection-conversation-id]': [wrapper] }, "owned-conversation")).toEqual({ error: "conversation_changed" });
  });
  test("Gemini requires its actual temporary badge and excludes Gemini said from response", async () => {
    const copy = domNode();
    const wrapper = domNode({ text: "Gemini said header", query: {
      'button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]': copy } });
    const answer = domNode({ text: '{"message":"gemini works"}', parent: wrapper });
    const badge = domNode({ text: "Temporary Chat" });
    const observed = await inspectDOM("gemini", "https://gemini.google.com/app", {
      '.model-response-text, model-response .markdown': [answer],
      'h1, h2, span.info-text': [badge], 'rich-textarea [contenteditable="true"]': [domNode()] });
    expect(observed).toMatchObject({ temporary: true, responseCount: 1, answerComplete: true, text: '{"message":"gemini works"}' });
    const outputBadge = domNode({ text: "Temporary Chat" });
    outputBadge.closest = selector => selector.includes("model-response") ? wrapper : null;
    expect((await inspectDOM("gemini", "https://gemini.google.com/app", {
      'h1, h2, span.info-text': [outputBadge] })).temporary).toBe(false);
  });
});

describe("ChatGPT route promotion", () => {
  async function routed(identity, temporary = true) {
    const f = fixture(); const started = await f.start();
    const session = f.sessions.sessions.get(started.sessionToken);
    Object.assign(session, { submitted: true, temporary: true, conversationIdentity: "local-chatgpt:initial-id",
      conversation: "https://chatgpt.com/c/local-chatgpt%3Ainitial-id" });
    f.sessions.page = WebProviderSessions.prototype.page.bind(f.sessions);
    f.chrome.debugger.sendCommand = async (_target, method) => {
      if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "owned-main-frame", url: "https://chatgpt.com/c/different-server-id?temporary-chat=true" } } };
      if (method === "Page.createIsolatedWorld") return { executionContextId: 9 };
      return { result: { value: { ...f.observed, temporary, conversationIdentity: identity } } };
    };
    return { f, session };
  }
  test("the provisional route promotes only with the same DOM conversation and active temporary mode", async () => {
    const { f, session } = await routed("local-chatgpt:initial-id");
    await f.sessions.page(session, "inspect");
    expect(session.conversation).toBe("https://chatgpt.com/c/different-server-id");
    expect(session.promoted).toBe(true);
  });
  test("a different DOM conversation cannot acquire cleanup ownership through route promotion", async () => {
    const { f, session } = await routed("another-user-chat");
    await expect(f.sessions.page(session, "inspect")).rejects.toMatchObject({ code: "web_conversation_changed" });
    expect(session.conversation).toBe("https://chatgpt.com/c/local-chatgpt%3Ainitial-id");
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
  test("a saved-mode conversation cannot acquire cleanup ownership through route promotion", async () => {
    const { f, session } = await routed("local-chatgpt:initial-id", false);
    await expect(f.sessions.page(session, "inspect")).rejects.toMatchObject({ code: "web_conversation_changed" });
    expect(session.promoted).not.toBe(true);
  });
});

function claudeDOM({ streaming = false, incognito = true, copyAvailable = true, assistantCount = 1 } = {}) {
  const badge = domNode({ text: "Incognito chat" });
  const header = domNode(); header.querySelectorAll = selector => selector === "span" ? [badge] : [];
  const exit = domNode({ attributes: { "aria-label": "Exit incognito" }, parent: header });
  const copy = domNode({ attributes: { "aria-label": "Copy", "data-testid": "action-bar-copy" } });
  const message = domNode({ text: "Claude responded with generated text", attributes: { "data-is-streaming": String(streaming) } });
  const article = domNode({ query: { '[data-testid="message-actions"] button[data-testid="action-bar-copy"][aria-label="Copy"]': copyAvailable ? copy : null } });
  article.tagName = "DIV";
  article.querySelectorAll = selector => selector === '[data-testid="assistant-message"]' ? Array(assistantCount).fill(message) : [];
  const reply = domNode({ text: '{"message":"COMPUTA_CLAUDE_OK"}', parent: message });
  reply.closest = selector => selector === '[data-testid="assistant-message"]' ? message : selector === '[role="article"]' ? article : null;
  const userOwner = domNode({ attributes: { id: "_r_cf_" } });
  const user = domNode({ text: "Computa session marker: fixture-marker\n\nOwned first prompt" });
  user.closest = selector => selector === "[id]" ? userOwner : null;
  const selectors = {
    '[data-testid="user-message"]': [user],
    '[data-testid="assistant-message"] [data-perf-reply-text]': [reply],
    '[data-testid="assistant-message"][data-is-streaming="true"]': streaming ? [message] : [],
    '[data-testid="chat-input"][contenteditable="true"][role="textbox"]': [domNode()],
    'button[aria-label="Exit incognito"]': incognito ? [exit] : [],
    '.animate-incognito-header-in span': incognito ? [badge] : [],
  };
  return { selectors, badge, header, exit, reply, message, article, user, userOwner };
}

describe("Claude incognito transport", () => {
  test("opens a fresh inactive Claude tab and enables incognito before accepting prompts", async () => {
    const f = fixture({ provider: "claude", temporary: false }); const started = await f.start();
    expect(f.calls[0]).toEqual(["create", { url: "https://claude.ai/new", active: false }]);
    expect((await f.request("webProviderPoll", { sessionToken: started.sessionToken })).state).toBe("loading");
    expect(f.calls.some(call => call[0] === "page" && call[1] === "enableTemporary")).toBe(true);
    await expect(f.request("webProviderSend", { sessionToken: started.sessionToken, prompt: "hi" })).rejects.toMatchObject({ code: "web_not_ready" });
    f.observed.temporary = true;
    expect((await f.request("webProviderPoll", { sessionToken: started.sessionToken })).state).toBe("ready");
    expect((await f.request("webProviderSend", { sessionToken: started.sessionToken, prompt: "hi" })).state).toBe("running");
    expect((await f.request("webProviderFinish", { sessionToken: started.sessionToken })).cleanup).toBe("not_created");
    expect(f.calls.filter(call => call[0] === "remove")).toEqual([["remove", 42]]);
  });
  test("Claude accepts only its exact new-chat origin and refuses saved chat routes", async () => {
    expect(freshURL("claude", "https://claude.ai/new?incognito=")).toBe(true);
    expect(freshURL("claude", "https://claude.ai/new")).toBe(true);
    expect(freshURL("claude", "https://claude.ai/chat/existing-user-conversation")).toBe(false);
    expect(freshURL("claude", "https://claude.ai.evil.test/new?incognito=")).toBe(false);
    expect(conversationURL("claude", "https://claude.ai/chat/existing-user-conversation")).toBeNull();
    expect((await inspectDOM("claude", "https://gemini.google.com/app", {})).error).toBe("sign_in_required");
  });
  test("extracts only the Claude response body and confirms its own final toolbar in a DIV article role", async () => {
    const { selectors, article } = claudeDOM();
    expect(article.tagName).toBe("DIV");
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors)).toMatchObject({
      composer: true, temporary: true, responseCount: 1, answerComplete: true, busy: false,
      text: '{"message":"COMPUTA_CLAUDE_OK"}',
    });
  });
  test("streaming Claude replies remain busy even with a visible Copy control", async () => {
    const { selectors } = claudeDOM({ streaming: true });
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors)).toMatchObject({
      temporary: true, busy: true, answerComplete: false,
    });
  });
  test("Claude completion needs final Copy belonging to one assistant message", async () => {
    expect((await inspectDOM("claude", "https://claude.ai/new?incognito=", claudeDOM({ copyAvailable: false }).selectors)).answerComplete).toBe(false);
    expect((await inspectDOM("claude", "https://claude.ai/new?incognito=", claudeDOM({ assistantCount: 2 }).selectors)).answerComplete).toBe(false);
  });
  test("a response saying Incognito chat cannot serve as Claude temporary-mode evidence", async () => {
    const { selectors, reply } = claudeDOM({ incognito: false });
    reply.innerText = reply.textContent = "Incognito chat";
    selectors["span"] = [reply];
    expect((await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors)).temporary).toBe(false);
  });
  test("losing Claude incognito evidence leaves its exact tab open and retains local output", async () => {
    const f = fixture({ provider: "claude" }); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "hi" });
    f.sessions.sessions.get(token).response = "local Claude response";
    f.observed.temporary = false;
    expect(await f.request("webProviderFinish", { sessionToken: token })).toMatchObject({
      cleanup: "failed", text: "local Claude response", error: { code: "web_temporary_mode_unverified" },
    });
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
});


describe("Claude response cancellation", () => {
  test("the observed Stop response control stops its owned streaming reply", async () => {
    const { selectors } = claudeDOM({ streaming: true });
    let clicks = 0;
    const stop = domNode({ attributes: { "aria-label": "Stop response" } }); stop.click = () => { clicks += 1; };
    selectors['button[aria-label="Stop response"]'] = [stop];
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors, null, "stop")).toEqual({ stopped: true });
    expect(clicks).toBe(1);
  });
  test("Claude temporary evidence includes the observed incognito query key", async () => {
    expect((await inspectDOM("claude", "https://claude.ai/new", claudeDOM().selectors)).temporary).toBe(false);
  });
  test("Claude interrupted status never marks a partial reply complete even with final Copy", async () => {
    const { selectors } = claudeDOM();
    selectors['[data-testid="response-status-announcer"][role="status"]'] = [domNode({ text: "Claude’s response was interrupted." })];
    const observed = await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors);
    expect(observed).toMatchObject({ interrupted: true, answerComplete: false, temporary: true });
    const f = fixture({ provider: "claude" }); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "hi" });
    Object.assign(f.observed, { interrupted: true, userCount: 1, responseCount: 1, text: '{"message":"partial', answerComplete: true });
    f.advance(2000);
    expect(await f.request("webProviderPoll", { sessionToken: token })).toMatchObject({ state: "failed",
      text: '{"message":"partial', error: { code: "web_response_interrupted" } });
    expect((await f.request("webProviderFinish", { sessionToken: token })).cleanup).toBe("not_created");
  });
});

function claudeDocumentFixture(initial = {}) {
  const f = fixture({ provider: "claude", initial });
  f.observed.url = "https://claude.ai/new?incognito=";
  const previous = Object.values(initial)[0]?.[0];
  Object.assign(f.observed, { firstUserMarkerVerified: true, firstUserIdentity: previous?.firstUserIdentity ?? "owned-user-id",
    firstUserFingerprint: previous?.firstUserFingerprint ?? null });
  f.sessions.page = WebProviderSessions.prototype.page.bind(f.sessions);
  f.hooks = {};
  f.chrome.debugger.sendCommand = async (target, method, params) => {
    f.calls.push(["command", target, method, params]);
    if (method === "Page.getFrameTree") return { frameTree: { frame: {
      id: "owned-frame", url: f.observed.url, loaderId: f.observed.documentLoaderId,
    } } };
    if (method === "Page.createIsolatedWorld") {
      f.hooks.world?.();
      return { executionContextId: 9 };
    }
    if (method === "Input.insertText") {
      if (params.text.startsWith("Computa session marker:")) f.firstBody = params.text;
      return {};
    }
    if (method !== "Runtime.evaluate") return {};
    const input = JSON.parse(params.expression.slice(params.expression.lastIndexOf(")(") + 2, -1));
    if (!input.expectedUserCounts.includes(f.observed.userCount)) return { result: { value: { error: "conversation_changed" } } };
    if (f.observed.userCount > 0 && f.firstBody && !f.observed.firstUserFingerprint) {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(f.firstBody.replace(/\r\n?/g, "\n").normalize("NFC").trim()));
      f.observed.firstUserFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    }
    f.hooks[input.action]?.();
    return { result: { value: input.action === "submit" ? { submitted: true } : { ...f.observed } } };
  };
  f.complete = async token => {
    const session = f.sessions.sessions.get(token);
    Object.assign(f.observed, { userCount: session.sequence, responseCount: session.sequence,
      text: `owned answer ${session.sequence}`, answerComplete: true, busy: false });
    await f.request("webProviderPoll", { sessionToken: token });
    f.advance(1600);
    return f.request("webProviderPoll", { sessionToken: token });
  };
  return f;
}

describe("Claude document and message ownership", () => {
  test("initial about:blank with no loader identity stays loading until the Claude root arrives", async () => {
    const f = claudeDocumentFixture(); const started = await f.start();
    Object.assign(f.observed, { url: "about:blank", documentLoaderId: "" });
    expect(await f.request("webProviderPoll", { sessionToken: started.sessionToken })).toMatchObject({ state: "loading" });
    expect(f.sessions.sessions.get(started.sessionToken).ownershipLost).not.toBe(true);
    Object.assign(f.observed, { url: "https://claude.ai/new?incognito=", documentLoaderId: "owned-loader" });
    expect(await f.request("webProviderPoll", { sessionToken: started.sessionToken })).toMatchObject({ state: "ready" });
    expect(f.sessions.sessions.get(started.sessionToken).documentLoaderId).toBe("owned-loader");
  });
  test("pins the ready document loader and persists confirmed counts across tool followups", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    const entry = () => Object.values(f.stored)[0][0];
    expect(entry()).toMatchObject({ documentLoaderId: "owned-loader", sequence: 0, confirmedUserCount: 0, pendingSubmission: false });
    await f.request("webProviderSend", { sessionToken: token, prompt: "private first prompt" });
    expect(entry()).toMatchObject({ sequence: 1, confirmedUserCount: 0, pendingSubmission: true });
    expect(await f.complete(token)).toMatchObject({ state: "complete", sequence: 1, text: "owned answer 1" });
    expect(entry()).toMatchObject({ sequence: 1, confirmedUserCount: 1, pendingSubmission: false });
    await f.request("webProviderSend", { sessionToken: token, prompt: "private tool result" });
    expect(await f.complete(token)).toMatchObject({ state: "complete", sequence: 2, text: "owned answer 2" });
    expect(entry()).toMatchObject({ sequence: 2, confirmedUserCount: 2, pendingSubmission: false });
    expect(entry().firstUserIdentity).toBe("owned-user-id");
    expect(entry().firstUserFingerprint).toMatch(/^[a-f0-9]{64}$/);
    const inserted = f.calls.filter(call => call[0] === "command" && call[2] === "Input.insertText");
    expect(inserted[0][3].text).toBe("Computa session marker: session-2\n\nprivate first prompt");
    expect(inserted[1][3].text).toBe("private tool result");
    expect(JSON.stringify(f.stored)).not.toContain("private");
    expect((await f.request("webProviderFinish", { sessionToken: token })).cleanup).toBe("not_created");
  });
  test("a replacement loader on the same Claude URL blocks prompt insertion and ready-tab cleanup", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    f.observed.documentLoaderId = "replacement-loader";
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "hi" })).rejects.toMatchObject({ code: "web_document_changed" });
    expect(f.calls.some(call => call[0] === "command" && call[2] === "Input.insertText")).toBe(false);
    f.observed.documentLoaderId = "owned-loader";
    expect(await f.request("webProviderFinish", { sessionToken: token })).toMatchObject({ cleanup: "failed", error: { code: "web_document_changed" } });
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
  test("replacement during isolated-world creation cannot run a mutation in the new document", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    const evaluated = f.calls.filter(call => call[0] === "command" && call[2] === "Runtime.evaluate").length;
    f.hooks.world = () => { f.observed.documentLoaderId = "replacement-loader"; };
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "hi" })).rejects.toMatchObject({ code: "web_document_changed" });
    expect(f.calls.filter(call => call[0] === "command" && call[2] === "Runtime.evaluate").length).toBe(evaluated);
    expect(f.calls.some(call => call[0] === "command" && call[2] === "Input.insertText")).toBe(false);
  });
  test("a same-document reset cannot receive a followup or inherit cleanup ownership", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" }); await f.complete(token);
    Object.assign(f.observed, { userCount: 0, responseCount: 0, text: "", answerComplete: false });
    const inserts = f.calls.filter(call => call[0] === "command" && call[2] === "Input.insertText").length;
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "followup" })).rejects.toMatchObject({ code: "web_conversation_changed" });
    expect(f.calls.filter(call => call[0] === "command" && call[2] === "Input.insertText").length).toBe(inserts);
    f.observed.userCount = 1;
    expect(await f.request("webProviderFinish", { sessionToken: token })).toMatchObject({ cleanup: "failed", text: "owned answer 1",
      error: { code: "web_document_changed" } });
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
  test("an extra user message fails polling before reading its response", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" });
    Object.assign(f.observed, { userCount: 2, responseCount: 2, text: "unowned response", answerComplete: true });
    expect(await f.request("webProviderPoll", { sessionToken: token })).toMatchObject({ state: "failed", text: "",
      error: { code: "web_conversation_changed" } });
    expect((await f.request("webProviderFinish", { sessionToken: token })).cleanup).toBe("failed");
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
  test("a final assistant response requires exactly one added owned user message", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" });
    Object.assign(f.observed, { responseCount: 1, text: "response without owned user", answerComplete: true });
    f.advance(2000);
    expect(await f.request("webProviderPoll", { sessionToken: token })).toMatchObject({ state: "failed", text: "",
      error: { code: "web_conversation_changed" } });
  });
  test("a lost Send acknowledgement permits cleanup only for the old count or its one pending submission", async () => {
    for (const userCount of [0, 1, 2]) {
      const f = claudeDocumentFixture(); const token = await f.ready();
      f.hooks.submit = () => { throw new BridgeError("chrome_timeout", "lost acknowledgement"); };
      await expect(f.request("webProviderSend", { sessionToken: token, prompt: "first" })).rejects.toMatchObject({ code: "chrome_timeout" });
      f.observed.userCount = userCount;
      const result = await f.request("webProviderFinish", { sessionToken: token });
      expect(result.cleanup).toBe(userCount <= 1 ? "not_created" : "failed");
      expect(f.calls.some(call => call[0] === "remove")).toBe(userCount <= 1);
    }
  });
  test("worker recovery retains loader and count ownership instead of adopting a reset tab", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" }); await f.complete(token);
    for (const changed of [{ documentLoaderId: "replacement-loader", userCount: 1 }, { userCount: 0 }, { userCount: 1 }]) {
      const recovered = claudeDocumentFixture(f.stored);
      Object.assign(recovered.observed, changed);
      await recovered.sessions.initialize();
      const unchanged = changed.documentLoaderId === undefined && changed.userCount === 1;
      expect(recovered.calls.some(call => call[0] === "remove")).toBe(unchanged);
      expect(recovered.sessions.cleanupFailures.length).toBe(unchanged ? 0 : 1);
    }
  });
  test("the fixed DOM guard detects count changes before focus or Stop actions", async () => {
    const { selectors } = claudeDOM({ streaming: true });
    let clicks = 0;
    const stop = domNode(); stop.click = () => { clicks += 1; };
    selectors['button[aria-label="Stop response"]'] = [stop];
    selectors['[data-testid="user-message"]'] = [];
    for (const action of ["prepare", "submit", "stop", "inspect"])
      expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors, null, action, [1])).toEqual({ error: "conversation_changed" });
    expect(clicks).toBe(0);
  });
});

describe("Claude first-message ownership", () => {
  test("the owned marker binds rendered Markdown text and its stable first-message ancestor", async () => {
    const { selectors, user } = claudeDOM();
    user.innerText = user.textContent = "  Computa session marker: fixture-marker\r\n\r\nCafe\u0301\n\ncode rendered without backticks  ";
    const observed = await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors);
    const normalized = "Computa session marker: fixture-marker\n\nCafé\n\ncode rendered without backticks";
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalized));
    const expected = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    expect(observed).toMatchObject({ firstUserIdentity: "_r_cf_", firstUserMarkerVerified: true, firstUserFingerprint: expected });
  });
  test("replacement before the first poll cannot be adopted without the fresh owned marker", async () => {
    const { selectors, user } = claudeDOM();
    user.innerText = user.textContent = "An unrelated replacement first prompt";
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors)).toEqual({ error: "conversation_changed" });
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" });
    Object.assign(f.observed, { userCount: 1, responseCount: 1, firstUserMarkerVerified: false, text: "replacement reply", answerComplete: true });
    expect(await f.request("webProviderPoll", { sessionToken: token })).toMatchObject({ state: "failed", text: "",
      error: { code: "web_conversation_changed" } });
    expect(f.sessions.sessions.get(token).firstUserFingerprint).toBeUndefined();
    expect((await f.request("webProviderFinish", { sessionToken: token })).cleanup).toBe("failed");
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
  });
  test("same-count replacement without an observed zero cannot receive a followup or regain cleanup on recovery", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" }); await f.complete(token);
    const ledger = structuredClone(f.stored);
    f.observed.firstUserIdentity = "replacement-user-id";
    const inserts = f.calls.filter(call => call[0] === "command" && call[2] === "Input.insertText").length;
    await expect(f.request("webProviderSend", { sessionToken: token, prompt: "followup" })).rejects.toMatchObject({ code: "web_conversation_changed" });
    expect(f.calls.filter(call => call[0] === "command" && call[2] === "Input.insertText").length).toBe(inserts);
    expect((await f.request("webProviderFinish", { sessionToken: token })).cleanup).toBe("failed");
    expect(f.calls.some(call => call[0] === "remove")).toBe(false);
    for (const changed of [{ firstUserIdentity: "replacement-user-id" }, { firstUserFingerprint: "f".repeat(64) }]) {
      const recovered = claudeDocumentFixture(ledger);
      Object.assign(recovered.observed, { userCount: 1 }, changed);
      await recovered.sessions.initialize();
      expect(recovered.calls.some(call => call[0] === "remove")).toBe(false);
      expect(recovered.sessions.cleanupFailures.length).toBe(1);
    }
  });
  test("the DOM guard checks both exact message identity and rendered body before Stop", async () => {
    const { selectors, user } = claudeDOM({ streaming: true });
    const first = await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors);
    const extra = { expectedFirstUserIdentity: first.firstUserIdentity, expectedFirstUserFingerprint: first.firstUserFingerprint };
    let clicks = 0;
    const stop = domNode(); stop.click = () => { clicks += 1; };
    selectors['button[aria-label="Stop response"]'] = [stop];
    user.closest = selector => selector === "[id]" ? domNode({ attributes: { id: "_r_ro_" } }) : null;
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors, null, "stop", [1], extra)).toEqual({ error: "conversation_changed" });
    const firstOwner = domNode({ attributes: { id: first.firstUserIdentity } });
    user.closest = selector => selector === "[id]" ? firstOwner : null;
    user.innerText = user.textContent = "Computa session marker: fixture-marker\n\nDifferent body with the same message id";
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors, null, "stop", [1], extra)).toEqual({ error: "conversation_changed" });
    expect(clicks).toBe(0);
  });
  test("replacement during the asynchronous SHA digest is rejected before any mutation", async () => {
    const { selectors, user } = claudeDOM({ streaming: true });
    let clicks = 0;
    const stop = domNode(); stop.click = () => { clicks += 1; };
    selectors['button[aria-label="Stop response"]'] = [stop];
    const cryptoImplementation = { subtle: { digest: async (...args) => {
      user.innerText = user.textContent = "Computa session marker: fixture-marker\n\nReplacement during digest";
      return crypto.subtle.digest(...args);
    } } };
    expect(await inspectDOM("claude", "https://claude.ai/new?incognito=", selectors, null, "stop", [1], {}, cryptoImplementation)).toEqual({ error: "conversation_changed" });
    expect(clicks).toBe(0);
  });
  test("worker recovery of an unobserved Send needs its persisted marker before adopting the first message", async () => {
    const f = claudeDocumentFixture(); const token = await f.ready();
    await f.request("webProviderSend", { sessionToken: token, prompt: "first" });
    expect(Object.values(f.stored)[0][0].firstUserFingerprint).toBeNull();
    for (const firstUserMarkerVerified of [false, true]) {
      const recovered = claudeDocumentFixture(f.stored);
      recovered.firstBody = f.firstBody;
      Object.assign(recovered.observed, { userCount: 1, firstUserMarkerVerified });
      await recovered.sessions.initialize();
      expect(recovered.calls.some(call => call[0] === "remove")).toBe(firstUserMarkerVerified);
    }
  });
});
