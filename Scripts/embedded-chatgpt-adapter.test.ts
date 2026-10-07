import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { installObservedModelPicker } from "./embedded-provider-adapter-fixture";
import { defineWebsiteModelChoiceTests } from "./embedded-model-choice-tests";

const source = readFileSync(new URL("../Sources/Computa/Resources/BrowserModels/chatgpt.js", import.meta.url), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const execute = new AsyncFunction("input", "document", "window", "location", "getComputedStyle", "MutationObserver", "setTimeout", "globalThis", "crypto", "HTMLTextAreaElement", "Date", source);
const firstMarker = "23b7752b-6a64-4b88-b886-f0d0584ca9de";
const markerLine = `Computa session marker: ${firstMarker}`;

class Element {
  parentElement: Element | null = null;
  children: Element[] = [];
  connected = true;
  get isConnected(): boolean { return this.connected && (!this.parentElement || this.parentElement.isConnected); }
  set isConnected(value: boolean) { this.connected = value; }
  disabled = false;
  clicks = 0;
  onClick?: () => void;
  onDispatch?: (event: any) => void;
  events: any[] = [];
  click() { this.clicks++; this.onClick?.(); }
  dispatchEvent(event: any) { this.events.push(event); this.onDispatch?.(event); return true; }
  constructor(public tagName: string, public values: Record<string, string> = {}, public text = "") {}
  get nodeType() { return 1; }
  get childElementCount() { return this.children.length; }
  get childNodes(): any[] { return [...(this.text ? [{ nodeType: 3, textContent: this.text, parentElement: this }] : []), ...this.children]; }
  get attributes() { return Object.entries(this.values).map(([name, value]) => ({ name, value })); }
  get classList() { const names = (this.values.class || "").split(/\s+/).filter(Boolean); return { contains: (name: string) => names.includes(name), [Symbol.iterator]: () => names[Symbol.iterator]() }; }
  get textContent(): string { return this.text + this.children.map(child => child.textContent).join(""); }
  get innerText() { return this.textContent; }
  getAttribute(name: string) { return this.values[name] ?? null; }
  getClientRects() { return this.isConnected && !this.closest('[hidden]') ? [{}] : []; }
  append(...children: Element[]) { children.forEach(child => { child.parentElement = this; this.children.push(child); }); }
  contains(node: Element | null): boolean { return node === this || !!node && this.children.some(child => child.contains(node)); }
  closest(selector: string): Element | null {
    for (let node: Element | null = this; node; node = node.parentElement)
      if (selector.split(",").some(part => matches(node!, part.trim()))) return node;
    return null;
  }
  descendants(): Element[] { return this.children.flatMap(child => [child, ...child.descendants()]); }
  querySelectorAll(selector: string) { return this.descendants().filter(node => selector.split(",").some(part => matches(node, part.trim()))); }
  querySelector(selector: string) { return this.querySelectorAll(selector)[0] ?? null; }
}

function matches(node: Element, selector: string) {
  // These fixtures need only the fixed adapter's selectors, not a browser DOM.
  const parts: string[] = [];
  let start = 0, bracket = 0, quote = "";
  for (let index = 0; index < selector.length; index++) {
    const char = selector[index];
    if (quote) { if (char === quote) quote = ""; continue; }
    if (char === '"' || char === "'") { quote = char; continue; }
    if (char === "[") bracket++; else if (char === "]") bracket--;
    else if (!bracket && /\s/.test(char)) {
      if (index > start) parts.push(selector.slice(start, index)); start = index + 1;
    }
  }
  if (start < selector.length) parts.push(selector.slice(start));
  if (!parts.length || !simpleMatches(node, parts.pop()!)) return false;
  let current: Element | null = node;
  while (parts.length) {
    const target = parts.pop()!; current = current?.parentElement ?? null;
    while (current && !simpleMatches(current, target)) current = current.parentElement;
    if (!current) return false;
  }
  return true;
}

function simpleMatches(node: Element, target: string) {
  const tag = target.match(/^[a-zA-Z][a-zA-Z0-9-]*/)?.[0];
  if (tag && node.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  const id = target.match(/^#([a-zA-Z0-9_-]+)/)?.[1];
  if (id && node.getAttribute("id") !== id) return false;
  const head = target.split("[", 1)[0];
  if ([...head.matchAll(/\.([a-zA-Z0-9_-]+)/g)].some(([, name]) => !node.classList.contains(name))) return false;
  return [...target.matchAll(/\[([^=\]]+)(?:="([^"]*)")?\]/g)].every(([, name, value]) => value === undefined
    ? node.getAttribute(name) !== null : node.getAttribute(name) === value);
}

function fixture(options: { articleOnly?: boolean; userPrompt?: string; renderedMarkdown?: boolean; userBubble?: boolean; sharedCopy?: boolean; response?: boolean } = {}) {
  const html = new Element("HTML"), body = new Element("BODY"), messages = new Element("MAIN");
  html.append(body); body.append(messages);
  const temporary = new Element("BUTTON", { "aria-label": "Turn off temporary chat" }, "Temporary");
  const composer = new Element("DIV", { id: "prompt-textarea", contenteditable: "true" });
  body.append(temporary, composer);
  const article = new Element("ARTICLE", { "data-turn": "assistant", "data-testid": "conversation-turn-2" });
  const outer = new Element("DIV", options.articleOnly ? { class: "markdown" }
    : { "data-markdown-text-style": "assistant-message" });
  const answer = new Element("DIV", options.articleOnly ? {} : { "data-markdown-text-style": "assistant-message" }, '{"type":"message","text":"OK"}');
  outer.append(answer); article.append(outer); if (options.response !== false) messages.append(article);
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
  let frameID = 0;
  const frames = new Map<number, (time: number) => void>();
  const window: Record<string, unknown> = { webkit: { messageHandlers: { computaChatGPTSignal: { postMessage: (value: unknown) => posted.push(value) } } },
    requestAnimationFrame: (callback: (time: number) => void) => {
      const id = ++frameID; frames.set(id, callback);
      queueMicrotask(() => { if (frames.delete(id)) callback(performance.now()); });
      return id;
    }, cancelAnimationFrame: (id: number) => { frames.delete(id); },
    KeyboardEvent: class { constructor(public type: string, options: any) { Object.assign(this, options); } } };
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
  let adapterClockOffset = 0;
  let digestHook: (() => void) | undefined;
  return { posted, observers, location, document, world, window, body, temporary, composer, scheduledDelays, userBody, answer: outer,
    advanceTime: (milliseconds: number) => { adapterClockOffset += milliseconds; },
    appendUser: (prompt: string) => {
      const root = new Element('ARTICLE', { 'data-turn': 'user', 'data-testid': 'conversation-turn-appended' });
      root.append(new Element('DIV', { class: 'whitespace-pre-wrap' }, prompt)); messages.append(root);
    },
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
      } } }, class TextArea extends Element {}, { now: () => Date.now() + adapterClockOffset });
      if (adopt && result.firstUserVerified) nativeFingerprint = result.firstUserFingerprint;
      return result;
    },
    flush: () => { const queued = timers.splice(0); queued.forEach(callback => callback()); } };
}

function observedChatGPTCodeBlock(f: ReturnType<typeof fixture>, raw: string, options: { noPre?: boolean } = {}) {
  f.answer.text = ""; f.answer.children = [];
  const outer = new Element("DIV", { class: "CodeBlock-generated-class" });
  const wrapper = new Element("DIV", { class: "relative w-full min-w-0 overflow-clip contain-inline-size border" });
  const header = new Element("DIV", { class: "flex items-center font-sans text-sm select-none min-h-12" });
  const label = new Element("DIV", { class: "min-w-0 flex-1 truncate" }, "JSON");
  const copy = new Element("BUTTON", { "aria-label": "Copy" });
  const wrap = new Element("BUTTON", { "aria-label": "Enable word wrap" });
  header.append(label, wrap, copy);
  const pre = new Element("PRE"), code = new Element("CODE", options.noPre ? { class: "block text-size-code CodeContent-generated-hash" } : {}, raw);
  const content = new Element("DIV", { class: "text-size-chat overflow-auto outline-none px-4 pt-0 pb-3" });
  if (options.noPre) content.append(code); else pre.append(code);
  wrapper.append(header, options.noPre ? content : pre); outer.append(wrapper); f.answer.append(outer);
  Object.defineProperty(f.answer, "innerText", { get: () => "JSON\n" + raw });
  return { outer, wrapper, header, label, copy, wrap, pre, code, content };
}

defineWebsiteModelChoiceTests('chatgpt', (owned = false) => {
  const f = fixture({ response: owned, ...(owned ? { userPrompt: 'Synthetic owned prompt' } : {}) });
  return { ...f, run: (action: string, overrides: Record<string, unknown> = {}) => f.inspect({ ...overrides, action }) };
}, Element);

describe("embedded ChatGPT fixed adapter", () => {
  test("a sole fenced envelope preserves literal JSON escapes and code-block controls", async () => {
    for (const envelope of [
      { type: "message", text: 'Literal "quoted" text, C:\\tmp\\file\nnext line\\n stays literal' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "quoted\\n"\npath="C:\\tmp\\file"' } }] },
    ]) {
      const f = fixture();
      const raw = "\n" + JSON.stringify(envelope) + "\n";
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, raw);
      pre.append(code, new Element("BUTTON", { "aria-label": "Copy code" }, "Copy code")); f.answer.append(pre);
      // Emulate the exact failure: the site's rendered Markdown loses JSON escapes.
      const rendered = raw.replace(/\\"/g, '"').replace(/\\\\/g, "\\").replace(/\\n/g, "\n");
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.inspect();
      expect(result.text).toBe(raw);
      expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("Copy code");
      expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 1, codeCount: 1,
        codeTextLength: raw.length, outsideTextLength: 0, outsideTruncated: false });
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain('quoted');
    }
  });

  test("observed ChatGPT widget header admits the literal sole JSON envelope", async () => {
    for (const envelope of [
      { type: "message", text: 'It\'s "quoted" C:\\tmp\\path\nnext line' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "literal\\n"\nprintf "It\'s quoted"' } }] },
    ]) {
      const f = fixture(), raw = "\n" + JSON.stringify(envelope) + "\n";
      const block = observedChatGPTCodeBlock(f, raw); block.outer.values.class = "CodeBlock-unrelated-generated-hash";
      const result = await f.inspect();
      expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("JSON\n"); expect(result.text).not.toContain("Enable word wrap");
    }
  });

  test("the observed sole-code DIV variant uses the same strict header proof", async () => {
    for (const envelope of [
      { type: "message", text: 'It\'s "quoted" C:\\tmp\\path\nnext line' },
      { type: "tool_calls", calls: [{ name: "computer_v2_read_page", arguments: {} }] },
    ]) {
      const f = fixture(), raw = "\n" + JSON.stringify(envelope) + "\n";
      const block = observedChatGPTCodeBlock(f, raw, { noPre: true });
      block.code.values.class = "block text-size-code CodeContent-another-hash";
      const result = await f.inspect();
      expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 0, codeCount: 1,
        codeTextLength: raw.length, outsideTextLength: 4, outsideTruncated: false });
    }
  });

  test("a generic CODE without PRE cannot bypass exact ChatGPT widget identity", async () => {
    for (const change of [
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.code.values.class = "text-size-code"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.content.values.class = "text-size-chat overflow-auto px-4 pt-0 pb-3"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.wrapper.values.class = "relative w-full min-w-0 overflow-clip border"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.values.class = "flex items-center font-sans text-sm select-none"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.text = "json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.values.class = "min-w-0 flex-1"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.copy.disabled = true; },
      (f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.children = block.header.children.filter(node => node !== block.copy); f.answer.append(block.copy); },
      (f: ReturnType<typeof fixture>, _block: ReturnType<typeof observedChatGPTCodeBlock>) => { f.answer.append(new Element("P", {}, "Author prose")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.content.append(new Element("CODE", { class: "block text-size-code" }, '{}')); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.code.text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(), raw = '{"type":"tool_calls","calls":[{"name":"computer_v2_read_page","arguments":{}}]}';
      const block = observedChatGPTCodeBlock(f, raw, { noPre: true }); change(f, block);
      expect((await f.inspect()).text).toBe("JSON\n" + raw);
    }
    const f = fixture(); f.answer.text = ""; f.answer.children = [];
    const raw = '{"type":"tool_calls","calls":[{"name":"computer_v2_read_page","arguments":{}}]}';
    f.answer.append(new Element("CODE", {}, raw));
    Object.defineProperty(f.answer, "innerText", { get: () => "Rendered generic code is not a provider widget" });
    expect((await f.inspect()).text).toBe("Rendered generic code is not a provider widget");
  });

  test("ChatGPT header cannot use an unrelated Copy footer or excuse authored prose", async () => {
    for (const change of [
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.wrapper.values.class = "relative w-full min-w-0 overflow-clip border"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.values.class = "flex items-center font-sans text-sm select-none"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.values.class = "min-w-0 flex-1"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.text = "json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.text = "Json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.append(new Element("EM", {}, "")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.copy.values["aria-label"] = "Copy code"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.copy.disabled = true; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.copy.text = "Author button text"; },
      (f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.children = block.header.children.filter(node => node !== block.copy); f.answer.append(block.copy); },
      (f: ReturnType<typeof fixture>, _block: ReturnType<typeof observedChatGPTCodeBlock>) => { f.answer.append(new Element("P", {}, "Author prose")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.wrap.text = "Other control text"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.append(new Element("DIV", { class: "min-w-0 flex-1 truncate" }, "JSON")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.append(new Element("BUTTON", { "aria-label": "Copy" })); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{}')); block.wrapper.append(extra); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.code.text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(), raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"literal"}}]}';
      const block = observedChatGPTCodeBlock(f, raw); change(f, block);
      expect((await f.inspect()).text).toBe("JSON\n" + raw);
    }
  });

  test("outside code-header diagnostics expose only static categories and bounded ancestry", async () => {
    const f = fixture();;
    f.answer.text = ""; f.answer.children = [];
    const wrapper = new Element("DIV", { class: "provider-code-wrapper", id: "private-account-id" });
    wrapper.append(new Element("SPAN", {}, "\uE056"), new Element("SPAN", {}, "json"));
    const pre = new Element("PRE"), raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"private command"}}]}';
    pre.append(new Element("CODE", {}, raw)); wrapper.append(pre); f.answer.append(wrapper);
    const result = await f.inspect();
    // Header acceptance needs actual website evidence; diagnostics cannot grant it.
    expect(result.text).toBe("\uE056json" + raw);
    const diagnostic = result.completionEvidence.codeStructure;
    expect(diagnostic).toMatchObject({ preCount: 1, codeCount: 1, outsideTextLength: 5, outsideTruncated: false });
    expect(diagnostic.outsideNodes.map((node: any) => node.kind)).toEqual(["private_use", "json"]);
    expect(diagnostic.outsideNodes[1].ancestors).toContainEqual({ tag: "div", classes: ["provider-code-wrapper"], preDescendants: 1, copyControls: 0 });
    expect(JSON.stringify(diagnostic)).not.toContain("private command"); expect(JSON.stringify(diagnostic)).not.toContain("private-account-id");
    expect(JSON.stringify(diagnostic)).not.toContain(firstMarker); expect(JSON.stringify(diagnostic).length).toBeLessThanOrEqual(8192);
  });

  test("prose, extra blocks, multiple code bodies and non-envelopes keep rendered extraction", async () => {
    for (const change of [
      (answer: Element, _pre: Element) => { answer.text = "Author prose before the block"; },
      (answer: Element, _pre: Element) => { answer.append(new Element("P", {}, "Author prose after the block")); },
      (answer: Element, _pre: Element) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{"type":"message","text":"OTHER"}')); answer.append(extra); },
      (_answer: Element, pre: Element) => { pre.append(new Element("CODE", {}, '{"type":"message","text":"OTHER"}')); },
      (_answer: Element, pre: Element) => { pre.text = "Author text outside its code body"; },
      (_answer: Element, pre: Element) => { pre.children[0].text = '{"type":"example","text":"quoted"}'; },
      (_answer: Element, pre: Element) => { pre.children[0].text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture();
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, '{"type":"message","text":"quoted\\""}');
      pre.append(code); f.answer.append(pre); change(f.answer, pre);
      const rendered = "Rendered response still requires strict codec validation";
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      expect((await f.inspect()).text).toBe(rendered);
    }
  });

  test("insertion mismatch diagnostics report scalar boundaries without exposing prompt text", async () => {
    for (const [expected, actual, firstDifference, actualScalar, expectedScalar] of [
      ['A "private"', 'A “private”', 2, 0x201C, 0x22],
      ["A💡private", "A💢private", 1, 0x1F4A2, 0x1F4A1],
      ["A private", "A privat", 8, null, 0x65],
    ] as const) {
      const f = fixture(); f.composer.text = actual;
      const result = await f.inspect({ action: "sendReady", prompt: expected });
      expect(result).toMatchObject({ error: "prompt_not_inserted", firstDifference, actualScalar, expectedScalar });
      expect(f.composer.innerText).toBe(actual); expect(JSON.stringify(result)).not.toContain("private");
    }
  });

  test("delayed temporary control gates startup and a lost click cannot replay", async () => {
    const f = fixture({ response: false }); f.temporary.isConnected = false;
    const toggle = new Element("BUTTON", { "aria-label": "Temporary chat" }); toggle.isConnected = false; f.body.append(toggle);
    expect(await f.inspect()).toMatchObject({ composer: true, temporary: false, temporaryActionAvailable: false });
    expect(await f.inspect({ action: "enableTemporary" })).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined(); expect(toggle.clicks).toBe(0);
    toggle.isConnected = true; toggle.disabled = true;
    expect(await f.inspect()).toMatchObject({ temporaryActionAvailable: false });
    toggle.disabled = false;
    expect(await f.inspect()).toMatchObject({ temporaryActionAvailable: true });
    toggle.isConnected = false;
    expect(await f.inspect({ action: "enableTemporary" })).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined();
    toggle.isConnected = true; toggle.onClick = () => { throw new Error("lost toggle acknowledgment"); };
    await expect(f.inspect({ action: "enableTemporary" })).rejects.toThrow("lost toggle");
    expect(toggle.clicks).toBe(1); expect(f.world.__computaModelTemporaryRequested).toBe(true);
    expect(await f.inspect({ action: "enableTemporary" })).toMatchObject({ error: "temporary_mode_unverified" });
    expect(toggle.clicks).toBe(1);
  });

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
