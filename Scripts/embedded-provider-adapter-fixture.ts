import { readFileSync } from "node:fs";

export const firstMarker = "23b7752b-6a64-4b88-b886-f0d0584ca9de";
export const markerLine = `Computa session marker: ${firstMarker}`;
const ownerToken = "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30";
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

// Inert fixture DOM, deliberately supporting only the fixed adapters' selectors.
export class Element {
  parentElement: Element | null = null;
  children: Element[] = [];
  connected = true;
  disabled = false;
  clicks = 0;
  onClick?: () => void;
  onFocus?: () => void;
  events: unknown[] = [];
  constructor(public tagName: string, public values: Record<string, string> = {}, public text = "") {}
  get nodeType() { return this.tagName === "#text" ? 3 : 1; }
  get childElementCount() { return this.children.filter(child => child.nodeType === 1).length; }
  get childNodes(): any[] { return [...(this.text ? [{ nodeType: 3, textContent: this.text, parentElement: this }] : []), ...this.children]; }
  get isConnected(): boolean { return this.connected && (!this.parentElement || this.parentElement.isConnected); }
  set isConnected(value: boolean) { this.connected = value; }
  get textContent(): string { return this.text + this.children.map(child => child.tagName === "BR" ? "\n" : child.textContent).join(""); }
  get innerText(): string {
    if (this.classList.contains("ql-editor") && this.children.every(child => child.tagName === "P"))
      return this.text + this.children.map(child => child.children.length === 1 && child.children[0].tagName === "BR" ? "" : child.innerText).join("\n");
    return this.textContent;
  }
  get classList() { const names = (this.values.class || "").split(/\s+/).filter(Boolean); return { contains: (name: string) => names.includes(name), [Symbol.iterator]: () => names[Symbol.iterator]() }; }
  getAttribute(name: string) { return this.values[name] ?? null; }
  getClientRects() { return this.isConnected && this.values.hidden === undefined ? [{}] : []; }
  append(...children: Element[]) { children.forEach(child => { child.parentElement = this; this.children.push(child); }); }
  appendChild(child: Element) { this.append(child); return child; }
  replaceChildren(...children: Element[]) { this.children.forEach(child => { child.connected = false; }); this.children = []; this.text = ""; this.append(...children); }
  cloneNode(deep = false): Element { const copy = new Element(this.tagName, { ...this.values }, this.text);
    copy.disabled = this.disabled; if (deep) copy.append(...this.children.map(child => child.cloneNode(true))); return copy; }
  contains(node: Element | null): boolean { return node === this || !!node && this.children.some(child => child.contains(node)); }
  descendants(): Element[] { return this.children.flatMap(child => [child, ...child.descendants()]); }
  closest(selector: string): Element | null {
    for (let node: Element | null = this; node; node = node.parentElement) if (matches(node, selector)) return node;
    return null;
  }
  querySelectorAll(selector: string) { return this.descendants().filter(node => node.nodeType === 1 && matches(node, selector)); }
  querySelector(selector: string) { return this.querySelectorAll(selector)[0] ?? null; }
  click() { this.clicks++; this.onClick?.(); }
  focus() { this.onFocus?.(); }
  dispatchEvent(event: unknown) { this.events.push(event); return true; }
}
function selectorParts(selector: string): string[] {
  const parts: string[] = []; let start = 0, bracket = 0, quote = "";
  for (let index = 0; index < selector.length; index++) {
    const c = selector[index];
    if (quote) { if (c === quote) quote = ""; continue; }
    if (c === '"' || c === "'") { quote = c; continue; }
    if (c === "[") bracket++; else if (c === "]") bracket--;
    else if (!bracket && /\s/.test(c)) { if (index > start) parts.push(selector.slice(start, index)); start = index + 1; }
  }
  if (start < selector.length) parts.push(selector.slice(start));
  return parts;
}
function simple(node: Element, selector: string) {
  const tag = selector.match(/^[a-zA-Z][a-zA-Z0-9-]*/)?.[0];
  if (tag && node.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  const head = selector.split("[", 1)[0];
  if ([...head.matchAll(/\.([a-zA-Z0-9_-]+)/g)].some(([, name]) => !node.classList.contains(name))) return false;
  const id = head.match(/#([a-zA-Z0-9_-]+)/)?.[1];
  if (id && node.getAttribute("id") !== id) return false;
  return [...selector.matchAll(/\[([^\s=\]*]+)(\*=|=)?(?:["']([^"']*)["'])?\]/g)].every(([, name, operator, value]) => {
    const attribute = node.getAttribute(name);
    return !operator ? attribute !== null : operator === "*=" ? attribute?.includes(value) === true : attribute === value;
  });
}
function matches(node: Element, selector: string): boolean {
  return selector.split(",").some(part => {
    const parts = selectorParts(part.trim()); let current: Element | null = node;
    if (!parts.length || !simple(node, parts.pop()!)) return false;
    while (parts.length) {
      const target = parts.pop()!; current = current?.parentElement ?? null;
      while (current && !simple(current, target)) current = current.parentElement;
      if (!current) return false;
    }
    return true;
  });
}
class TextArea extends Element { value = ""; }
class FixtureInputEvent { constructor(public type: string, public options: unknown) {} }
export type Provider = "claude" | "gemini";
export function fixture(provider: Provider, options: { temporary?: boolean; userPrompt?: string; renderedMarkdown?: boolean; response?: boolean } = {}) {
  const source = readFileSync(new URL(`../Sources/Computa/Resources/BrowserModels/${provider}.js`, import.meta.url), "utf8");
  const execute = new AsyncFunction("input", "document", "window", "location", "getComputedStyle", "MutationObserver", "setTimeout", "globalThis", "crypto", "HTMLTextAreaElement", "InputEvent", source);
  const origin = provider === "claude" ? "https://claude.ai" : "https://gemini.google.com";
  const html = new Element("HTML"), body = new Element("BODY"), messages = new Element("MAIN"); html.append(body); body.append(messages);
  const header = new Element("DIV", { class: "animate-incognito-header-in" });
  const badge = provider === "claude" ? new Element("SPAN", {}, "Incognito chat") : new Element("H2");
  if (provider === "gemini") {
    const notice = new Element("DIV");
    notice.append(new Element("A", { href: "https://support.google.com/gemini/answer/13275745?p=temp_chats" }, "Temporary chats"),
      new Element("SPAN", {}, " don't appear in recent chats and aren't used to improve Google AI. Stored for 72 hours for safety."));
    badge.append(new Element("SPAN", {}, "Just stopping by?"), notice);
  }
  header.append(badge); body.append(header);
  const exit = new Element("BUTTON", { "aria-label": provider === "claude" ? "Exit incognito" : "Exit temporary chat" }); body.append(exit);
  // Gemini's real initial mode evidence is the heading, not this optional exit control.
  if (provider === "gemini") exit.connected = false;
  const toggle = new Element("BUTTON", { "aria-label": provider === "claude" ? "Use incognito" : "Temporary chat" }); body.append(toggle);
  const composer = provider === "claude" ? new Element("DIV", { "data-testid": "chat-input", contenteditable: "true", role: "textbox", class: "ProseMirror" })
    : new Element("DIV", { contenteditable: "true", "aria-label": "Enter a prompt for Gemini", class: "ql-editor" });
  const composerHost = new Element(provider === "claude" ? "DIV" : "RICH-TEXTAREA"); composerHost.append(composer); body.append(composerHost);
  const send = new Element("BUTTON", { "aria-label": "Send message", ...(provider === "claude" ? { "data-testid": "chat-input-send" } : {}) }); body.append(send);
  const stop = new Element("BUTTON", { "aria-label": "Stop response" }); stop.connected = false; body.append(stop);
  const status = new Element("DIV", { "data-testid": "response-status-announcer", role: "status" }, "Claude finished the response"); body.append(status);
  const article = new Element("DIV", { role: "article" });
  const response = provider === "claude" ? new Element("DIV", { "data-testid": "assistant-message", "data-is-streaming": "false" }) : new Element("MODEL-RESPONSE");
  const answer = new Element("DIV", provider === "claude" ? { "data-perf-reply-text": "" } : { class: "model-response-text" }, '{"type":"message","text":"OK"}');
  const heading = new Element("H2", {}, provider === "claude" ? "Claude responded" : "Gemini said"); response.append(heading, answer);
  const controls = new Element("DIV", provider === "claude" ? { "data-testid": "message-actions" } : {});
  const copy = new Element("BUTTON", { "aria-label": "Copy", ...(provider === "claude" ? { "data-testid": "action-bar-copy" } : { "data-test-id": "copy-button" }) }); controls.append(copy);
  if (provider === "claude") article.append(response, controls); else { response.append(controls); article.append(response); }
  if (options.response ?? options.userPrompt !== undefined) messages.append(article);
  const location = { origin, pathname: provider === "claude" ? "/new" : "/app" };
  const document: any = { URL: origin + location.pathname, documentElement: html, activeElement: null,
    querySelectorAll: (selector: string) => html.querySelectorAll(selector),
    createElement: (tag: string) => new Element(tag.toUpperCase()), createTextNode: (text: string) => new Element("#text", {}, text),
    createRange: () => { const range: any = { node: null, selectNodeContents: (node: Element) => { range.node = node; }, collapse: () => {} }; return range; },
    execCommand: (_action: string, _ui: boolean, text: string) => { composer.replaceChildren(); composer.text = text; return true; } };
  composer.onFocus = () => { document.activeElement = composer; };
  const selection: any = { anchorNode: null, focusNode: null, removeAllRanges: () => {},
    addRange: (range: any) => { selection.anchorNode = selection.focusNode = range.node; } };
  const posted: unknown[] = [], timers: (() => void)[] = [], delays: number[] = [];
  const observers: { callback: (records: unknown[]) => void; options?: Record<string, unknown> }[] = [];
  class Observer {
    options?: Record<string, unknown>;
    constructor(public callback: (records: unknown[]) => void) { observers.push(this); }
    observe(_target: unknown, values: Record<string, unknown>) { this.options = values; }
  }
  const window: any = { webkit: { messageHandlers: { computaChatGPTSignal: { postMessage: (value: unknown) => posted.push(value) } } }, getSelection: () => selection }; window.top = window;
  const world: Record<string, any> = {};
  let userBody: Element | undefined, userRoot: Element | undefined, nativeFingerprint: string | undefined, digestHook: (() => void) | undefined;
  let expectedCounts = options.userPrompt === undefined ? [0] : [1];
  function temporary(enabled: boolean) {
    badge.connected = enabled;
    if (provider === "claude") { exit.connected = enabled; document.URL = origin + location.pathname + (enabled ? "?incognito" : ""); }
  }
  temporary(options.temporary !== false);
  toggle.onClick = () => temporary(true);
  function appendUser(prompt: string) {
    const wrapper = new Element("DIV", { id: `owned-user-${messages.children.length}` });
    userRoot = new Element(provider === "claude" ? "DIV" : "USER-QUERY", provider === "claude" ? { "data-testid": "user-message" } : {});
    if (provider === "gemini") {
      userRoot.values.class = "ng-star-inserted";
      const outer = new Element("SPAN", { class: "user-query-container" });
      const host = new Element("USER-QUERY-CONTAINER", { class: "user-query-container" });
      const container = new Element("DIV", { class: "user-query-container" });
      const content = new Element("DIV", { class: "query-content ng-star-inserted" });
      const status = new Element("DIV", { class: "query-bubble-with-status ng-star-inserted" });
      const bubble = new Element("SPAN", { class: "user-query-bubble-with-background ng-star-inserted" });
      userBody = new Element("SPAN", { class: "ng-star-inserted" });
      userBody.append(new Element("SPAN"));
      const bubbleControls = new Element("DIV", { class: "ng-star-inserted" }); bubbleControls.append(new Element("BUTTON"));
      bubble.append(userBody, bubbleControls); status.append(bubble); content.append(status);
      const controls = new Element("DIV", { class: "ng-star-inserted" }); controls.append(new Element("BUTTON"), new Element("BUTTON"));
      container.append(new Element("DIV", { class: "ng-star-inserted" }), content, controls);
      host.append(container); outer.append(host); userRoot.append(outer);
    } else userBody = userRoot;
    userBody.text = options.renderedMarkdown ? prompt.replace(/`([^`]+)`/g, "$1") : prompt;
    wrapper.append(userRoot);
    if (provider === "gemini") messages.append(wrapper);
    else { messages.children.unshift(wrapper); wrapper.parentElement = messages; }
    return userRoot;
  }
  if (options.userPrompt !== undefined) {
    appendUser(options.userPrompt + "\n\n" + markerLine);
    world.__computaModelFirstPrompt = options.userPrompt + "\n\n" + markerLine;
    world.__computaModelFirstMarker = firstMarker; world.__computaModelFirstSubmitted = true;
  }
  send.onClick = () => { appendUser(composer.innerText); composer.replaceChildren(); expectedCounts = [0, 1]; };
  return { provider, origin, html, body, messages, header, badge, exit, toggle, composer, send, stop, status, article, response, answer, controls, copy, location, document, world, window,
    posted, observers, delays, get userBody() { return userBody; }, get userRoot() { return userRoot; }, appendUser, temporary,
    onDigest: (hook: () => void) => { digestHook = hook; },
    run: async (action = "inspect", overrides: Record<string, unknown> = {}, adopt = true) => {
      const result = await execute({ provider, action, expectedURL: document.URL, expectedUserCounts: expectedCounts, ownerToken, bindOwner: true,
        expectedFirstUserMarker: firstMarker, expectedFirstUserFingerprint: nativeFingerprint,
        allowFirstUserBinding: nativeFingerprint === undefined, ...overrides }, document, window, location,
        (node: Element) => ({ visibility: node.values.visibility || "visible" }), Observer,
        (callback: () => void, delay: number) => { timers.push(callback); delays.push(delay); }, world,
        { subtle: { digest: async (algorithm: string, data: Uint8Array) => { const digest = await crypto.subtle.digest(algorithm, data); digestHook?.(); digestHook = undefined; return digest; } } }, TextArea, FixtureInputEvent);
      if (adopt && result.firstUserVerified) nativeFingerprint = result.firstUserFingerprint;
      return result;
    },
    flush: () => { timers.splice(0).forEach(callback => callback()); } };
}
