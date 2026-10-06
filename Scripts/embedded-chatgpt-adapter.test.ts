import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../Sources/Computa/Resources/BrowserModels/chatgpt.js", import.meta.url), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const execute = new AsyncFunction("input", "document", "window", "location", "getComputedStyle", "MutationObserver", "setTimeout", "globalThis", "crypto", source);
const firstMarker = "23b7752b-6a64-4b88-b886-f0d0584ca9de";
const markerLine = `Computa session marker: ${firstMarker}`;

class Element {
  parentElement: Element | null = null;
  children: Element[] = [];
  isConnected = true;
  disabled = false;
  constructor(public tagName: string, public values: Record<string, string> = {}, public text = "") {}
  get attributes() { return Object.entries(this.values).map(([name, value]) => ({ name, value })); }
  get classList() { return { contains: (name: string) => (this.values.class || "").split(/\s+/).includes(name) }; }
  get textContent(): string { return this.text + this.children.map(child => child.textContent).join(""); }
  get innerText() { return this.textContent; }
  getAttribute(name: string) { return this.values[name] ?? null; }
  getClientRects() { return this.isConnected ? [{}] : []; }
  append(...children: Element[]) { children.forEach(child => { child.parentElement = this; this.children.push(child); }); }
  contains(node: Element | null): boolean { return node === this || !!node && this.children.some(child => child.contains(node)); }
  closest(_selector: string) { return null; }
  descendants(): Element[] { return this.children.flatMap(child => [child, ...child.descendants()]); }
  querySelectorAll(selector: string) { return this.descendants().filter(node => selector.split(",").some(part => matches(node, part.trim()))); }
  querySelector(selector: string) { return this.querySelectorAll(selector)[0] ?? null; }
}

function matches(node: Element, selector: string) {
  // These fixtures need only the fixed adapter's selectors, not a browser DOM.
  const target = selector.split(/\s+(?=[a-zA-Z.#\[])/).at(-1)!;
  const tag = target.match(/^[a-zA-Z][a-zA-Z0-9-]*/)?.[0];
  if (tag && node.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  const id = target.match(/^#([a-zA-Z0-9_-]+)/)?.[1];
  if (id && node.getAttribute("id") !== id) return false;
  const cssClass = target.match(/^\.([a-zA-Z0-9_-]+)/)?.[1];
  if (cssClass && !node.classList.contains(cssClass)) return false;
  return [...target.matchAll(/\[([^=\]]+)(?:="([^"]*)")?\]/g)].every(([, name, value]) => value === undefined
    ? node.getAttribute(name) !== null : node.getAttribute(name) === value);
}

function fixture(options: { articleOnly?: boolean; userPrompt?: string; renderedMarkdown?: boolean; userBubble?: boolean; sharedCopy?: boolean } = {}) {
  const html = new Element("HTML"), body = new Element("BODY"), messages = new Element("MAIN");
  html.append(body); body.append(messages);
  const temporary = new Element("BUTTON", { "aria-label": "Turn off temporary chat" }, "Temporary");
  const composer = new Element("DIV", { id: "prompt-textarea", contenteditable: "true" });
  body.append(temporary, composer);
  const article = new Element("ARTICLE", { "data-turn": "assistant", "data-testid": "conversation-turn-2" });
  const outer = new Element("DIV", options.articleOnly ? { class: "markdown" }
    : { "data-markdown-text-style": "assistant-message" });
  const answer = new Element("DIV", options.articleOnly ? {} : { "data-markdown-text-style": "assistant-message" }, '{"type":"message","text":"OK"}');
  outer.append(answer); article.append(outer); messages.append(article);
  const controls = new Element("DIV", { class: "turn-action-controls" });
  const copy = new Element("BUTTON", { "aria-label": "Copy" }, "Copy");
  controls.append(copy);
  if (options.sharedCopy) {
    const earlier = new Element("ARTICLE", { "data-turn": "assistant" });
    earlier.append(new Element("DIV", { "data-markdown-text-style": "assistant-message" }, "Earlier answer"));
    messages.children.unshift(earlier); earlier.parentElement = messages;
    messages.append(controls);
  } else article.append(controls);
  let userBody: Element | undefined;
  if (options.userPrompt !== undefined) {
    const user = options.userBubble ? new Element("DIV", { "data-user-message-bubble": "" })
      : new Element("ARTICLE", { "data-turn": "user", "data-testid": "conversation-turn-1" });
    userBody = new Element("DIV", { class: "whitespace-pre-wrap" });
    if (options.renderedMarkdown) {
      // A realistic rendered inline-code node has its contents but no source
      // backtick delimiters. Exact source equality would reject this owned turn.
      options.userPrompt.split(/(`[^`]+`)/).forEach(part => userBody!.append(
        new Element(part.startsWith('`') ? "CODE" : "SPAN", {}, part.startsWith('`') ? part.slice(1, -1) : part)));
      userBody.append(new Element("SPAN", {}, "\n\n" + markerLine));
    } else userBody.text = options.userPrompt + "\n\n" + markerLine;
    user.append(new Element("H5", {}, "You said:"), userBody,
      new Element("BUTTON", { "aria-label": "Copy message" }, "Copy message"));
    messages.children.unshift(user); user.parentElement = messages;
  }
  const location = { origin: "https://chatgpt.com", pathname: "/" };
  const posted: unknown[] = [], timers: (() => void)[] = [], scheduledDelays: number[] = [];
  const observers: { callback: (records: unknown[]) => void; options?: Record<string, unknown> }[] = [];
  class Observer {
    options?: Record<string, unknown>;
    constructor(public callback: (records: unknown[]) => void) { observers.push(this); }
    observe(_target: unknown, options: Record<string, unknown>) { this.options = options; }
  }
  const window: Record<string, unknown> = { webkit: { messageHandlers: { computaChatGPTSignal: { postMessage: (value: unknown) => posted.push(value) } } } };
  window.top = window;
  const document = { URL: "https://chatgpt.com/?temporary-chat=true", documentElement: html,
    querySelectorAll: (selector: string) => html.querySelectorAll(selector) };
  const world: Record<string, unknown> = {};
  if (options.userPrompt !== undefined) {
    world.__computaModelFirstPrompt = options.userPrompt + "\n\n" + markerLine;
    world.__computaModelFirstMarker = firstMarker;
    world.__computaModelFirstSubmitted = true;
  }
  const ownerToken = "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30";
  let nativeFingerprint: string | undefined;
  let digestHook: (() => void) | undefined;
  return { posted, observers, location, document, world, temporary, scheduledDelays, userBody,
    onDigest: (hook: () => void) => { digestHook = hook; },
    inspect: async (overrides: Record<string, unknown> = {}, adopt = true) => {
      const result = await execute({ provider: "chatgpt", action: "inspect", expectedURL: document.URL,
      expectedUserCounts: [options.userPrompt === undefined ? 0 : 1], ownerToken, bindOwner: true,
      expectedFirstUserMarker: firstMarker, expectedFirstUserFingerprint: nativeFingerprint,
      allowFirstUserBinding: nativeFingerprint === undefined, ...overrides },
      document, window, location, () => ({ visibility: "visible" }), Observer, (callback: () => void, delay: number) => {
        timers.push(callback); scheduledDelays.push(delay);
      }, world, { subtle: { digest: async (algorithm: string, data: Uint8Array) => {
        const digest = await crypto.subtle.digest(algorithm, data);
        digestHook?.(); digestHook = undefined;
        return digest;
      } } });
      if (adopt && result.firstUserVerified) nativeFingerprint = result.firstUserFingerprint;
      return result;
    },
    flush: () => { const queued = timers.splice(0); queued.forEach(callback => callback()); } };
}

describe("embedded ChatGPT fixed adapter", () => {
  test("nested modern markers remain one answer and admit its sibling Copy footer", async () => {
    const f = fixture();
    const result = await f.inspect();
    expect(result.responseCount).toBe(1);
    expect(result.text).toBe('{"type":"message","text":"OK"}');
    expect(result.answerComplete).toBe(true);
    expect(result.completionEvidence).toMatchObject({ modernMarkers: 2, logicalAnswers: 1, enabledCopies: 1 });
  });

  test("article turns pin the scoped first-message lineage", async () => {
    const prompt = 'Literal "quote"\n\n  two spaces and\u00a0NBSP';
    const f = fixture({ articleOnly: true, userPrompt: prompt });
    const result = await f.inspect();
    expect(result.userCount).toBe(1);
    expect(result.responseCount).toBe(1);
    expect(result.firstUserVerified).toBe(true);
    expect(result.answerComplete).toBe(true);
    const structure = JSON.parse(result.debugStructure);
    expect(structure).toMatchObject({ articleUsers: 1, articleAssistants: 1, markdownBodies: 1 });
    expect(result.debugStructure).not.toContain(prompt);
    expect(result.debugStructure).not.toContain('"quote"');
    expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
    f.userBody!.text = f.userBody!.text.replace("Literal", "Changed");
    expect(await f.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
  });

  test("a Copy control outside two physical answers supplies no completion proof", async () => {
    const result = await fixture({ sharedCopy: true }).inspect();
    expect(result.responseCount).toBe(2);
    expect(result.answerComplete).toBe(false);
    expect(result.completionEvidence.enabledCopies).toBe(0);
  });

  test("the observed user-bubble marker proves exactly its preserved body", async () => {
    const prompt = 'Known "literal"\n\n  {"a":"& <script>"}\nNBSP \u00a0 stays';
    const f = fixture({ userBubble: true, userPrompt: prompt });
    const result = await f.inspect();
    expect(result.userCount).toBe(1);
    expect(result.firstUserVerified).toBe(true);
    expect(result.responseCount).toBe(1);
    // The marker and physical count are unchanged; different message content
    // must never supply ownership proof, even beside the same toolbar.
    f.userBody!.text = f.userBody!.text.replace("Known", "Other");
    expect(await f.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
  });

  test("rendered Markdown binds once after the submitted marker and rejects same-count substitution", async () => {
    const prompt = 'Use `tool_calls` and `exec_command` with "quotes"\n\n  preserved\u00a0spaces';
    const f = fixture({ userBubble: true, userPrompt: prompt, renderedMarkdown: true });
    expect(f.userBody!.innerText).not.toBe(prompt + "\n\n" + markerLine);
    expect(f.userBody!.querySelectorAll('code')).toHaveLength(2);
    const result = await f.inspect({}, false);
    expect(result.firstUserVerified).toBe(true);
    expect(result.firstUserMarkerVerified).toBe(true);
    expect(result.firstUserFingerprint).toMatch(/^[a-f0-9]{64}$/);
    // A native route-race reread may adopt the same already-pinned proof; it
    // cannot replace it with a different body before native adoption.
    expect(await f.inspect()).toMatchObject({ firstUserFingerprint: result.firstUserFingerprint });
    f.userBody!.children[1].text = "foreign_schema";
    expect(await f.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
  });

  test("marker presence cannot bind before Submit, outside its body, or after native proof is pinned", async () => {
    const unsubmitted = fixture({ userBubble: true, userPrompt: "A body" });
    unsubmitted.world.__computaModelFirstSubmitted = false;
    expect(await unsubmitted.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(unsubmitted.world.__computaModelFirstProof).toBeUndefined();
    const outside = fixture({ userBubble: true, userPrompt: "A body" });
    outside.userBody!.text = "A body";
    outside.userBody!.parentElement!.text = markerLine + "\n";
    expect(await outside.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const pinned = fixture({ userBubble: true, userPrompt: "A body" });
    await pinned.inspect();
    delete pinned.world.__computaModelFirstProof;
    expect(await pinned.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const notPending = fixture({ userBubble: true, userPrompt: "A body" });
    expect(await notPending.inspect({ allowFirstUserBinding: false })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const partial = fixture({ userBubble: true, userPrompt: "A body" });
    partial.userBody!.text = "A partially rendered body";
    expect(await partial.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const markerOnly = fixture({ userBubble: true, userPrompt: "" });
    expect(await markerOnly.inspect()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
  });

  test("a digest yield cannot admit changed body, owner, URL, or temporary mode", async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.userBody!.text += " substituted"; },
      (f: ReturnType<typeof fixture>) => { f.world.__computaModelOwner = "foreign-owner"; },
      (f: ReturnType<typeof fixture>) => { f.document.URL = "https://chatgpt.com/c/foreign"; },
      (f: ReturnType<typeof fixture>) => { f.temporary.isConnected = false; },
      (f: ReturnType<typeof fixture>) => {
        const root = f.userBody!.parentElement!;
        root.parentElement!.append(new Element("DIV", { "data-user-message-bubble": "" }, "Foreign user"));
      },
      (f: ReturnType<typeof fixture>) => {
        const body = f.userBody!, root = body.parentElement!;
        const replacement = new Element("DIV", { class: "whitespace-pre-wrap" }, body.innerText);
        replacement.parentElement = root;
        root.children[root.children.indexOf(body)] = replacement;
        body.isConnected = false;
      },
    ]) {
      const f = fixture({ userBubble: true, userPrompt: "Read `schema`", renderedMarkdown: true });
      f.onDigest(() => mutate(f));
      const result = await f.inspect();
      expect(["conversation_changed", "temporary_mode_unverified"]).toContain(result.error);
      expect(f.world.__computaModelFirstProof).toBeUndefined();
    }
  });

  test("private-world mutation notifications coalesce and carry only ownership and kind", async () => {
    const f = fixture();
    await f.inspect(); await f.inspect();
    expect(f.observers).toHaveLength(1);
    expect(f.posted).toEqual([]);
    expect(f.scheduledDelays).toEqual([]);
    expect(f.observers[0].options?.attributeFilter).toContain("disabled");
    expect(f.observers[0].options?.attributeFilter).toContain("aria-hidden");
    expect(f.observers[0].options?.attributeFilter).toContain("data-turn");
    expect(f.observers[0].options?.attributeFilter).toContain("data-user-message-bubble");
    f.observers[0].callback([{ type: "childList" }]);
    f.observers[0].callback([{ type: "characterData" }]);
    expect(f.scheduledDelays).toEqual([100]);
    f.flush();
    expect(f.posted).toEqual([{ ownerToken: "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30", kind: "dom_changed" }]);
    f.observers[0].callback([{ type: "attributes" }]);
    f.location.origin = "https://example.test";
    f.flush();
    expect(f.posted).toHaveLength(1);
  });
});
