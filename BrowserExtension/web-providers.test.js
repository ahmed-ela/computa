import { describe, expect, test } from "bun:test";
import { BridgeError } from "./commands.js";
import { WebProviderSessions, WEB_PROVIDERS, conversationURL, freshURL, providerPageAction } from "./web-providers.js";

function fixture({ provider = "chatgpt", temporary = true, initial = {} } = {}) {
  let clock = 0, uuid = 0, generation = "g", revision = 1;
  const calls = [], stored = structuredClone(initial), events = [];
  const observed = { url: WEB_PROVIDERS[provider].root, composer: true, temporary, responseCount: 0, userCount: 0,
    prepared: true, busy: false, answerComplete: false, text: "" };
  const chrome = {
    tabs: { create: async params => { calls.push(["create", params]); return { id: 42 }; }, remove: async id => calls.push(["remove", id]) },
    debugger: { attach: async target => calls.push(["attach", target]), detach: async target => calls.push(["detach", target]),
      sendCommand: async (target, method, params) => { calls.push(["command", target, method, params]); return {}; } },
    storage: { session: { get: async key => ({ [key]: stored[key] }), set: async value => Object.assign(stored, structuredClone(value)) } },
  };
  const sessions = new WebProviderSessions({ chrome, uuid: () => `session-${++uuid}`, bounded: promise => promise,
    now: () => clock, sleep: async ms => { clock += ms; }, emit: event => events.push(event),
    check: (g, r) => { if (g !== generation || r !== revision) throw new BridgeError("unauthorized", "revoked"); } });
  sessions.page = async (session, action, extra = {}, cleanup = false) => {
    calls.push(["page", action, extra, cleanup]);
    if (!cleanup) sessions.check(session.generation, session.revision);
    return { ...observed, submitted: action === "submit", deleted: action === "deleteVerify" };
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
function inspectDOM(provider, url, selectors, expectedConversationIdentity = null) {
  const document = { URL: url, querySelectorAll: selector => selectors[selector] ?? [] };
  const window = {}; window.top = window;
  const location = new URL(url);
  const execute = new Function("document", "window", "location", "getComputedStyle", "input", `return (${providerPageAction.toString()})(input);`);
  return execute(document, window, location, () => ({ visibility: "visible" }), {
    provider, action: "inspect", expectedURL: url, expectedConversationIdentity });
}


describe("current provider DOM adaptation", () => {
  test("modern ChatGPT temp response is extracted without its controls or page header", () => {
    const copy = domNode({ attributes: { "aria-label": "Copy" } });
    const wrapper = domNode({ attributes: { "data-chatgpt-selection-conversation-id": "local-chatgpt:owned" },
      query: { '.turn-action-controls button[aria-label="Copy"], button[data-testid="copy-turn-action-button"], button[aria-label="Copy"]': copy } });
    const answer = domNode({ text: '{"message":"works"}', parent: wrapper });
    const save = domNode({ text: "Save chat" });
    const composer = domNode();
    const observed = inspectDOM("chatgpt", "https://chatgpt.com/c/server-id?temporary-chat=true", {
      '[data-chatgpt-selection-conversation-id]': [wrapper],
      '[data-markdown-text-style="assistant-message"]': [answer],
      '[contenteditable="true"][aria-label="Ask ChatGPT"]': [composer], button: [save, copy] }, "local-chatgpt:owned");
    expect(observed).toMatchObject({ temporary: true, composer: true, responseCount: 1, busy: false,
      answerComplete: true, text: '{"message":"works"}', conversationIdentity: "local-chatgpt:owned" });
  });
  test("a different ChatGPT DOM conversation identity is rejected before reading messages", () => {
    const wrapper = domNode({ attributes: { "data-chatgpt-selection-conversation-id": "other-conversation" } });
    expect(inspectDOM("chatgpt", "https://chatgpt.com/c/other?temporary-chat=true", {
      '[data-chatgpt-selection-conversation-id]': [wrapper] }, "owned-conversation")).toEqual({ error: "conversation_changed" });
  });
  test("Gemini requires its actual temporary badge and excludes Gemini said from response", () => {
    const copy = domNode();
    const wrapper = domNode({ text: "Gemini said header", query: {
      'button[aria-label*="Good response"], button[aria-label*="Copy"], button[data-test-id="copy-button"]': copy } });
    const answer = domNode({ text: '{"message":"gemini works"}', parent: wrapper });
    const badge = domNode({ text: "Temporary Chat" });
    const observed = inspectDOM("gemini", "https://gemini.google.com/app", {
      '.model-response-text, model-response .markdown': [answer],
      'h1, h2, span.info-text': [badge], 'rich-textarea [contenteditable="true"]': [domNode()] });
    expect(observed).toMatchObject({ temporary: true, responseCount: 1, answerComplete: true, text: '{"message":"gemini works"}' });
    const outputBadge = domNode({ text: "Temporary Chat" });
    outputBadge.closest = selector => selector.includes("model-response") ? wrapper : null;
    expect(inspectDOM("gemini", "https://gemini.google.com/app", {
      'h1, h2, span.info-text': [outputBadge] }).temporary).toBe(false);
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
