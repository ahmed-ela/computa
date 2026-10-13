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
  private static nextRect = 0;
  private readonly rect = Element.nextRect++;
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
  getBoundingClientRect() { return { left: 0, top: this.rect * 40, width: 100, height: 30 }; }
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

function fixture(options: { articleOnly?: boolean; userPrompt?: string; renderedMarkdown?: boolean; userBubble?: boolean; sharedCopy?: boolean; response?: boolean;
  normalRoot?: boolean; unprovenProduct?: boolean } = {}) {
  const html = new Element("HTML"), body = new Element("BODY"), messages = new Element("MAIN");
  html.append(body); body.append(messages);
  const temporary = new Element("BUTTON", { "aria-label": "Turn off temporary chat" }, "Temporary");
  const composer = new Element("DIV", { id: "prompt-textarea", contenteditable: "true" });
  const modeGroup = new Element('DIV', { 'aria-label': 'Composer mode', role: 'group' });
  const chatMode = new Element('BUTTON', { 'aria-pressed': 'true' }, 'Chat');
  const workMode = new Element('BUTTON', { 'aria-pressed': 'false' }, 'Work');
  modeGroup.append(chatMode, workMode); body.append(modeGroup, temporary, composer);
  chatMode.onClick = () => { chatMode.values['aria-pressed'] = 'true'; workMode.values['aria-pressed'] = 'false'; };
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
  let hitOverride: Element | null | undefined;
  const document = { URL: "https://chatgpt.com/?temporary-chat=true", documentElement: html,
    elementFromPoint: (x: number, y: number) => hitOverride !== undefined ? hitOverride : html.descendants().find(node => {
      const rect = node.getBoundingClientRect(); return node.isConnected && !node.closest('[hidden], [aria-hidden="true"], [inert]')
        && x >= rect.left && x < rect.left + rect.width && y >= rect.top && y < rect.top + rect.height;
    }) || null,
    querySelectorAll: (selector: string) => html.querySelectorAll(selector) };
  temporary.onClick = () => { temporary.values['aria-label'] = 'Turn off temporary chat'; document.URL = 'https://chatgpt.com/?temporary-chat=true'; };
  if (options.normalRoot) { document.URL = 'https://chatgpt.com/'; temporary.values['aria-label'] = 'Temporary chat'; }
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
  let productBootstrapped = false;
  const invoke = (request: Record<string, unknown>, useHook = true) => execute({ provider: 'chatgpt', ownerToken, bindOwner: true,
    expectedURL: document.URL, expectedUserCounts: [options.userPrompt === undefined ? 0 : 1],
    expectedFirstUserMarker: firstMarker, expectedFirstUserFingerprint: nativeFingerprint,
    allowFirstUserBinding: nativeFingerprint === undefined, ...request },
    document, window, location, () => ({ visibility: 'visible' }), Observer, (callback: () => void, delay: number) => {
      timers.push(callback); scheduledDelays.push(delay);
    }, world, { subtle: { digest: async (algorithm: string, data: Uint8Array) => {
      const digest = await crypto.subtle.digest(algorithm, data);
      if (useHook) { digestHook?.(); digestHook = undefined; }
      return digest;
    } } }, class TextArea extends Element {}, { now: () => Date.now() + adapterClockOffset });
  return { posted, observers, location, document, world, window, body, temporary, composer, modeGroup, chatMode, workMode, scheduledDelays, userBody, answer: outer,
    advanceTime: (milliseconds: number) => { adapterClockOffset += milliseconds; },
    setHit: (node: Element | null | undefined) => { hitOverride = node; },
    appendUser: (prompt: string) => {
      const root = new Element('ARTICLE', { 'data-turn': 'user', 'data-testid': 'conversation-turn-appended' });
      root.append(new Element('DIV', { class: 'whitespace-pre-wrap' }, prompt)); messages.append(root);
    },
    onDigest: (hook: () => void) => { digestHook = hook; },
    inspect: async (overrides: Record<string, unknown> = {}, adopt = true) => {
      if (!productBootstrapped && !options.normalRoot && !options.unprovenProduct) {
        // Existing response/lineage fixtures begin after a real empty-root
        // bootstrap. Exercise the production mode and temporary actions, then
        // restore the separately staged response DOM; never seed a fake proof.
        productBootstrapped = true;
        const savedURL = document.URL, savedTemporary = { ...temporary.values }, savedConnected = temporary.connected;
        const savedChildren = [...body.children], savedWorld = { ...world };
        body.children = [modeGroup, temporary, composer]; temporary.connected = true;
        document.URL = 'https://chatgpt.com/'; temporary.values['aria-label'] = 'Temporary chat';
        delete world.__computaModelFirstSubmitted; delete world.__computaModelFirstProof;
        const mode = await invoke({ action: 'ensureChatMode', expectedUserCounts: [0] }, false);
        if (!mode.chatModeReady) throw new Error('Fixture normal Chat bootstrap failed');
        const transition = await invoke({ action: 'enableTemporary', expectedUserCounts: [0] }, false);
        if (!transition.temporary || transition.productModeEvidence?.temporaryTransition !== 'acknowledged')
          throw new Error('Fixture temporary transition failed');
        document.URL = savedURL; temporary.values = savedTemporary; temporary.connected = savedConnected;
        body.children = savedChildren;
        Object.assign(world, savedWorld);
        // A legacy delayed-toggle fixture stages a pre-temporary normal root.
        if (!savedConnected) {
          document.URL = 'https://chatgpt.com/';
          delete world.__computaModelTemporaryRequested;
          (world.__computaChatProductMode as any).temporaryRequested = false;
          (world.__computaChatProductMode as any).temporaryAcknowledged = false;
        }
      }
      const result = await invoke({ action: 'inspect', ...overrides });
      if (adopt && result.firstUserVerified) nativeFingerprint = result.firstUserFingerprint;
      return result;
    },
    flush: () => { const queued = timers.splice(0); queued.forEach(callback => callback()); } };
}

function observedChatGPTCodeBlock(f: ReturnType<typeof fixture>, raw: string, options: { noPre?: boolean; measuredPRE?: boolean } = {}) {
  f.answer.text = ""; f.answer.children = [];
  const outer = new Element("DIV", { class: options.measuredPRE ? "CodeBlock-zu1QM3" : "CodeBlock-generated-class" });
  const wrapper = new Element("DIV", { class: options.measuredPRE
    ? "relative Root-iW7ipz w-full min-w-0 contain-inline-size overflow-clip"
    : "relative w-full min-w-0 overflow-clip contain-inline-size border" });
  const header = new Element("DIV", { class: options.measuredPRE
    ? "flex items-center font-sans text-sm select-none ActionBar-KWWAct"
    : "flex items-center font-sans text-sm select-none min-h-12" });
  const label = new Element("DIV", { class: "min-w-0 flex-1 truncate" }, "JSON");
  const copy = new Element("BUTTON", { "aria-label": "Copy" });
  const wrap = new Element("BUTTON", { "aria-label": "Enable word wrap" });
  header.append(label, wrap, copy);
  const pre = new Element("PRE"), code = new Element("CODE", options.noPre ? { class: "block text-size-code CodeContent-generated-hash" } : {}, raw);
  const content = new Element("DIV", { class: "text-size-chat overflow-auto outline-none px-4 pt-0 pb-3" });
  if (options.noPre) content.append(code); else pre.append(code);
  wrapper.append(header, options.noPre ? content : pre); outer.append(wrapper); f.answer.append(outer);
  Object.defineProperty(f.answer, "innerText", { get: () => (options.measuredPRE ? "JSON\n\n\n" : "JSON\n") + raw });
  return { outer, wrapper, header, label, copy, wrap, pre, code, content };
}

defineWebsiteModelChoiceTests('chatgpt', (owned = false) => {
  const f = fixture({ response: owned, ...(owned ? { userPrompt: 'Synthetic owned prompt' } : {}) });
  return { ...f, run: (action: string, overrides: Record<string, unknown> = {}) => f.inspect({ ...overrides, action }) };
}, Element);

describe('ChatGPT response load failure', () => {
  const errorRegion = () => {
    const region = new Element('DIV'), error = new Element('SPAN', {}, 'Load failed');
    const retry = new Element('BUTTON', {}, 'Retry'); region.append(error, retry);
    return { region, error, retry };
  };
  test('an owned response error beside Retry fails immediately without clicking', async () => {
    const f = fixture({ response: false, userPrompt: 'Read the fixture marker' });
    const e = errorRegion(); f.body.querySelector('main')!.append(e.region);
    const observed = await f.inspect();
    expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
    expect(observed.responseLoadFailed).toBe(true);
    expect(e.retry.clicks).toBe(0);
  });
  test('quoted errors in user and assistant content are not website failures', async () => {
    for (const target of ['user', 'assistant']) {
      const f = fixture({ userPrompt: target === 'user' ? 'Load failedRetry' : 'Explain the text Load failed' }), e = errorRegion();
      if (target === 'user') {
        f.userBody!.text = ''; f.userBody!.append(e.region, new Element('SPAN', {}, '\n\n' + markerLine));
      } else f.answer.append(e.region);
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(e.retry.clicks).toBe(0);
    }
  });
  test('hidden, detached, unpaired and non-conversation errors cannot stop a response', async () => {
    for (const variant of ['hidden-error', 'hidden-retry', 'detached', 'no-retry', 'sidebar', 'editor', 'menu']) {
      const f = fixture({ response: false, userPrompt: 'Read the fixture marker' }), e = errorRegion();
      if (variant === 'hidden-error') e.error.values.hidden = '';
      if (variant === 'hidden-retry') e.retry.values['aria-hidden'] = 'true';
      if (variant === 'detached') e.region.connected = false;
      if (variant === 'no-retry') e.retry.text = 'Something else';
      if (variant === 'menu') e.region.values.role = 'menu';
      if (variant === 'sidebar') { const sidebar = new Element('ASIDE'); sidebar.append(e.region); f.body.append(sidebar); }
      else if (variant === 'editor') f.composer.append(e.region);
      else f.body.querySelector('main')!.append(e.region);
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(e.retry.clicks).toBe(0);
    }
  });
  test('response failure cannot override a changed first message or product mode', async () => {
    for (const drift of ['user', 'work']) {
      const f = fixture({ response: false, userPrompt: 'Read the fixture marker' }), e = errorRegion();
      await f.inspect(); f.body.querySelector('main')!.append(e.region);
      if (drift === 'user') f.userBody!.text = 'Different prompt\n\n' + markerLine;
      else { f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false'; }
      expect((await f.inspect()).error).toBe(drift === 'user' ? 'conversation_changed' : 'product_mode_unverified');
    }
  });
});

describe('normal ChatGPT product provenance', () => {
  test('recognized disabled Chat controls wait without proof or clicks until both actually enable', async () => {
    const f = fixture({ response: false, normalRoot: true }); f.chatMode.disabled = true; f.workMode.disabled = true;
    const pending = await f.inspect();
    expect(pending).toMatchObject({ composer: true, chatModeReady: false, chatModeActionAvailable: false, chatModeHydrating: true, pending: true });
    expect(pending.productModeEvidence).toBeUndefined(); expect(f.world.__computaChatProductMode).toBeUndefined();
    expect(f.chatMode.clicks).toBe(0); expect(f.temporary.clicks).toBe(0);
    f.chatMode.disabled = false;
    expect(await f.inspect()).toMatchObject({ chatModeHydrating: true, pending: true });
    expect(f.world.__computaChatProductMode).toBeUndefined();
    f.workMode.disabled = false;
    const ready = await f.inspect();
    expect(ready).toMatchObject({ chatModeReady: true, productModeEvidence: { mode: 'chat', temporaryTransition: 'not_requested' } });
    expect(ready.chatModeHydrating).toBeUndefined(); expect(f.chatMode.clicks).toBe(0); expect(f.temporary.clicks).toBe(0);
    expect(await f.inspect({ action: 'enableTemporary' })).toMatchObject({ temporary: true,
      productModeEvidence: { temporaryTransition: 'acknowledged' } }); expect(f.temporary.clicks).toBe(1);
  });

  test('recognized disabled Work controls wait, then authorize exactly one enabled Chat switch', async () => {
    const f = fixture({ response: false, normalRoot: true });
    f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true';
    f.chatMode.values['aria-disabled'] = 'true'; f.workMode.values['aria-disabled'] = 'true';
    expect(await f.inspect()).toMatchObject({ chatModeHydrating: true, chatModeActionAvailable: false, pending: true });
    expect(f.world.__computaChatProductMode).toBeUndefined(); expect(f.chatMode.clicks).toBe(0);
    expect(await f.inspect({ action: 'ensureChatMode' })).toMatchObject({ error: 'product_mode_unverified' });
    delete f.chatMode.values['aria-disabled']; delete f.workMode.values['aria-disabled'];
    expect(await f.inspect()).toMatchObject({ chatModeActionAvailable: true, chatModeReady: false });
    expect(await f.inspect({ action: 'ensureChatMode' })).toMatchObject({ pending: true });
    expect(f.chatMode.clicks).toBe(1);
    expect(await f.inspect()).toMatchObject({ productModeEvidence: { mode: 'chat', temporaryTransition: 'not_requested' } });
    expect(await f.inspect({ action: 'ensureChatMode' })).toMatchObject({ chatModeReady: true });
    expect(f.chatMode.clicks).toBe(1); expect(f.temporary.clicks).toBe(0);
  });

  test('never-enabled controls grant only pending inspection, never product reads, edits or mode clicks', async () => {
    const f = fixture({ response: false, normalRoot: true }); f.chatMode.disabled = true; f.workMode.disabled = true;
    for (let step = 0; step < 3; step++) {
      expect(await f.inspect()).toMatchObject({ chatModeHydrating: true, pending: true });
      expect(f.world.__computaChatProductMode).toBeUndefined();
    }
    for (const action of ['ensureChatMode', 'verifyProductMode', 'enableTemporary', 'prepare', 'insert', 'sendReady', 'submit', 'discoverModels'])
      expect(await f.inspect({ action })).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.chatMode.clicks).toBe(0); expect(f.temporary.clicks).toBe(0); expect(f.composer.events).toEqual([]);
  });

  test('hydration cannot excuse unknown or hidden pairs, past-proof disabled controls or prior action claims', async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { delete f.workMode.values['aria-pressed']; },
      (f: ReturnType<typeof fixture>) => { f.workMode.values['aria-pressed'] = 'true'; },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.values['aria-hidden'] = 'true'; },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.values.inert = ''; },
      (f: ReturnType<typeof fixture>) => { f.world.__computaChatModeClickClaimed = true; },
      (f: ReturnType<typeof fixture>) => { f.world.__computaModelTemporaryRequested = true; },
    ]) {
      const f = fixture({ response: false, normalRoot: true }); f.chatMode.disabled = true; f.workMode.disabled = true; mutate(f);
      const result = await f.inspect(); expect(result).toMatchObject({ error: 'product_mode_unverified' });
      expect(result.chatModeHydrating).toBeUndefined(); expect(f.world.__computaChatProductMode).toBeUndefined();
    }
    const proven = fixture({ response: false, normalRoot: true }); await proven.inspect();
    proven.chatMode.disabled = true; proven.workMode.disabled = true;
    expect(await proven.inspect()).toMatchObject({ error: 'product_mode_unverified' });
    expect((proven.world.__computaChatProductMode as any).invalidated).toBe(true);
    proven.chatMode.disabled = false; proven.workMode.disabled = false;
    expect(await proven.inspect()).toMatchObject({ error: 'product_mode_unverified' });
  });

  test('normal Chat and Work share family labels; Chat is proven before one explicit temporary transition', async () => {
    const f = fixture({ response: false, normalRoot: true });
    const picker = installObservedModelPicker(f, 'chatgpt', Element);
    expect(await f.inspect()).toMatchObject({ chatModeReady: true, temporary: false, productModeEvidence: {
      product: 'chatgpt', mode: 'chat', source: 'composer_mode_control', temporaryTransition: 'not_requested' } });
    expect(f.chatMode.clicks).toBe(0); expect(picker.familyOptions.some(option => option.textContent.includes('GPT-5.6 Sol'))).toBe(true);
    expect(await f.inspect({ action: 'enableTemporary' })).toMatchObject({ temporary: true,
      productModeEvidence: { temporaryTransition: 'acknowledged' } });
    expect(f.temporary.clicks).toBe(1);
    f.modeGroup.values.hidden = '';
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ temporary: true,
      productModeEvidence: { mode: 'chat', temporaryTransition: 'acknowledged' } });
    expect(picker.trigger.clicks).toBe(0);
  });

  test('native product-only rechecks on the normal root do not require a temporary transition before it is claimed', async () => {
    const f = fixture({ response: false, normalRoot: true });
    expect(await f.inspect()).toMatchObject({ productModeEvidence: { temporaryTransition: 'not_requested' } });
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ temporary: false,
      chatModeReady: true, productModeEvidence: { mode: 'chat', temporaryTransition: 'not_requested' } });
    expect(f.temporary.clicks).toBe(0);
    expect(await f.inspect({ action: 'prepare' })).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(await f.inspect({ action: 'enableTemporary' })).toMatchObject({ temporary: true,
      productModeEvidence: { temporaryTransition: 'acknowledged' } });
    expect(f.temporary.clicks).toBe(1);
  });

  test('an initial temporary page cannot infer normal Chat from the URL, model labels, or visible mode pair', async () => {
    for (const saveInstead of [false, true]) {
      const f = fixture({ response: false, unprovenProduct: true });
      if (saveInstead) f.temporary.values['aria-label'] = 'Save chat';
      installObservedModelPicker(f, 'chatgpt', Element);
      expect(await f.inspect()).toMatchObject({ error: 'product_mode_unverified' });
      expect(f.world.__computaChatProductMode).toBeUndefined(); expect(f.temporary.clicks).toBe(0);
    }
  });

  test('an owned empty Work root claims one Chat click and waits for the actual complementary states', async () => {
    const f = fixture({ response: false, normalRoot: true });
    f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true';
    const change = f.chatMode.onClick!; f.chatMode.onClick = () => {};
    expect(await f.inspect()).toMatchObject({ chatModeReady: false, chatModeActionAvailable: true });
    expect(await f.inspect({ action: 'ensureChatMode' })).toMatchObject({ pending: true, chatModeReady: false });
    expect(await f.inspect()).toMatchObject({ pending: true, chatModeReady: false, chatModeActionAvailable: false });
    expect(await f.inspect({ action: 'ensureChatMode' })).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.chatMode.clicks).toBe(1); expect(f.temporary.clicks).toBe(0);
    change();
    expect(await f.inspect()).toMatchObject({ chatModeReady: true, productModeEvidence: { temporaryTransition: 'not_requested' } });
    expect(await f.inspect({ action: 'enableTemporary' })).toMatchObject({ temporary: true,
      productModeEvidence: { mode: 'chat', temporaryTransition: 'acknowledged' } });
  });

  test('ambiguous, hidden, disabled and conflicting product controls never acquire proof or click', async () => {
    const mutations = [
      (f: ReturnType<typeof fixture>) => { f.workMode.values['aria-pressed'] = 'true'; },
      (f: ReturnType<typeof fixture>) => { f.chatMode.values['aria-pressed'] = 'false'; },
      (f: ReturnType<typeof fixture>) => { f.chatMode.values['aria-pressed'] = 'mixed'; },
      (f: ReturnType<typeof fixture>) => { delete f.workMode.values['aria-pressed']; },
      (f: ReturnType<typeof fixture>) => { f.chatMode.values['aria-checked'] = 'true'; },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.append(new Element('BUTTON', { 'aria-pressed': 'false' }, 'Work')); },
      (f: ReturnType<typeof fixture>) => { f.body.append(new Element('DIV', { 'aria-label': 'Composer mode' })); },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.values.hidden = ''; },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.values.inert = ''; },
      (f: ReturnType<typeof fixture>) => { f.chatMode.disabled = true; },
      (f: ReturnType<typeof fixture>) => { f.workMode.values['aria-disabled'] = 'true'; },
    ];
    for (const mutate of mutations) {
      const f = fixture({ response: false, normalRoot: true }); mutate(f);
      expect(await f.inspect({ action: 'ensureChatMode' })).toMatchObject({ error: 'product_mode_unverified' });
      expect(f.chatMode.clicks).toBe(0); expect(f.temporary.clicks).toBe(0);
      expect(f.world.__computaChatProductMode).toBeUndefined();
    }
  });

  test('role-appropriate checked controls and exact labelled group retain actual semantic proof', async () => {
    const f = fixture({ response: false, normalRoot: true });
    f.modeGroup.values['aria-labelledby'] = 'composer-mode-label'; delete f.modeGroup.values['aria-label'];
    f.body.append(new Element('SPAN', { id: 'composer-mode-label' }, 'Composer mode'));
    for (const [node, state] of [[f.chatMode, 'true'], [f.workMode, 'false']] as const) {
      delete node.values['aria-pressed']; node.values.role = 'radio'; node.values['aria-checked'] = state;
    }
    expect(await f.inspect()).toMatchObject({ productModeEvidence: { mode: 'chat', temporaryTransition: 'not_requested' } });
    expect(await f.inspect({ action: 'enableTemporary' })).toMatchObject({ productModeEvidence: { temporaryTransition: 'acknowledged' } });
  });

  test('unrequested temporary appearance cannot acknowledge a product transition', async () => {
    const f = fixture({ response: false, normalRoot: true }); await f.inspect();
    f.temporary.values['aria-label'] = 'Turn off temporary chat'; f.document.URL = 'https://chatgpt.com/?temporary-chat=true';
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.temporary.clicks).toBe(0);
  });

  test('a vanished or replaced pre-temporary mode pair cannot reuse the earlier Chat proof', async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.modeGroup.connected = false; },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.children = []; },
      (f: ReturnType<typeof fixture>) => { f.modeGroup.values['aria-hidden'] = 'true'; },
    ]) {
      const f = fixture({ response: false, normalRoot: true }); await f.inspect(); mutate(f);
      expect(await f.inspect({ action: 'enableTemporary' })).toMatchObject({ error: 'product_mode_unverified' });
      expect(f.temporary.clicks).toBe(0);
    }
  });

  test('an occluded Chat or Temporary control cannot claim a programmatic click', async () => {
    const work = fixture({ response: false, normalRoot: true });
    work.chatMode.values['aria-pressed'] = 'false'; work.workMode.values['aria-pressed'] = 'true';
    work.setHit(new Element('DIV', { role: 'dialog' }, 'Overlay'));
    expect(await work.inspect({ action: 'ensureChatMode' })).toMatchObject({ error: 'product_mode_unverified' });
    expect(work.chatMode.clicks).toBe(0); expect(work.world.__computaChatModeClickClaimed).toBeUndefined();
    const normal = fixture({ response: false, normalRoot: true }); await normal.inspect(); normal.setHit(null);
    expect(await normal.inspect({ action: 'enableTemporary' })).toMatchObject({ error: 'temporary_mode_unavailable' });
    expect(normal.temporary.clicks).toBe(0); expect(normal.world.__computaModelTemporaryRequested).toBeUndefined();
  });

  test('an owned pending model popup can hide temporary controls without inventing a physical temp proof', async () => {
    const f = fixture({ response: false }); await f.inspect();
    f.temporary.values['aria-hidden'] = 'true'; f.modeGroup.values['aria-hidden'] = 'true';
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ temporary: false,
      productModeEvidence: { mode: 'chat', temporaryTransition: 'acknowledged' } });
    expect(await f.inspect({ action: 'prepare' })).toMatchObject({ error: 'temporary_mode_unverified' });
    expect(f.composer.events).toEqual([]);
    delete f.temporary.values['aria-hidden']; delete f.modeGroup.values['aria-hidden'];
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ temporary: true,
      productModeEvidence: { temporaryTransition: 'acknowledged' } });
  });

  test('Work or a disallowed product route revokes proof permanently, including a transient mode flip', async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; },
      (f: ReturnType<typeof fixture>) => { f.document.URL = 'https://chatgpt.com/work'; },
      (f: ReturnType<typeof fixture>) => { f.observers[0].callback([{ type: 'attributes', attributeName: 'aria-pressed', oldValue: 'true', target: f.workMode }]); },
    ]) {
      const f = fixture({ response: false }); await f.inspect(); mutate(f);
      expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ error: 'product_mode_unverified' });
      f.chatMode.values['aria-pressed'] = 'true'; f.workMode.values['aria-pressed'] = 'false'; f.document.URL = 'https://chatgpt.com/?temporary-chat=true';
      expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ error: 'product_mode_unverified' });
    }
  });

  test('a replacement Work control flipped and detached within one mutation batch still revokes the owned proof', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const replacement = new Element('BUTTON', { 'aria-pressed': 'false' }, 'Work');
    // React replaced the button, selected Work, restored Chat, then unmounted
    // the replacement before this batched callback. Current DOM alone is normal.
    replacement.connected = false;
    f.observers[0].callback([
      { type: 'childList', target: f.modeGroup, addedNodes: [replacement], removedNodes: [f.workMode] },
      { type: 'attributes', target: replacement, attributeName: 'aria-pressed', oldValue: 'false' },
      { type: 'attributes', target: replacement, attributeName: 'aria-pressed', oldValue: 'true' },
      { type: 'childList', target: f.modeGroup, addedNodes: [f.workMode], removedNodes: [replacement] },
    ]);
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.chatMode.clicks).toBe(0);
  });

  test('a replacement Work control created selected and detached in a structural-only batch also revokes proof', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const replacement = new Element('BUTTON', { 'aria-pressed': 'true' }, 'Work'); replacement.connected = false;
    f.observers[0].callback([
      { type: 'childList', target: f.modeGroup, addedNodes: [replacement], removedNodes: [f.workMode] },
      { type: 'childList', target: f.modeGroup, addedNodes: [f.workMode], removedNodes: [replacement] },
    ]);
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.chatMode.clicks).toBe(0);
  });

  test('Work contradiction after first Send keeps its finite product error before first-lineage temporary checks', async () => {
    const f = fixture({ userPrompt: 'Synthetic first submitted request' });
    // Bootstrap the private owned mode without admitting the pending first
    // message to native. The next product read must bind no lineage on error.
    await f.inspect({ action: 'verifyProductMode' }, false);
    expect(f.world.__computaModelFirstProof).toBeUndefined();
    f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true';
    expect(await f.inspect()).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(f.composer.events).toEqual([]);
  });

  test('a detached Work control from conversation content cannot revoke or establish product provenance', async () => {
    const f = fixture({ userPrompt: 'Synthetic owned prompt' }); await f.inspect();
    const authoredGroup = new Element('DIV', { 'aria-label': 'Composer mode' });
    const authoredWork = new Element('BUTTON', { 'aria-pressed': 'false' }, 'Work'); authoredGroup.append(authoredWork);
    authoredGroup.connected = false;
    f.observers[0].callback([
      { type: 'childList', target: f.answer, addedNodes: [authoredGroup], removedNodes: [] },
      { type: 'attributes', target: authoredWork, attributeName: 'aria-pressed', oldValue: 'true' },
      { type: 'childList', target: f.answer, addedNodes: [], removedNodes: [authoredGroup] },
    ]);
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ temporary: true,
      productModeEvidence: { mode: 'chat', temporaryTransition: 'acknowledged' } });
  });

  test('a product change during a fresh model proof cannot admit editor readiness or a Send', async () => {
    const f = fixture({ response: false });
    const picker = installObservedModelPicker(f, 'chatgpt', Element, { genericHeader: true });
    await f.inspect();
    const open = picker.trigger.onClick!;
    picker.trigger.onClick = () => { open(); f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; };
    f.composer.text = 'Owned synthetic request\n\n' + markerLine;
    const send = new Element('BUTTON', { 'aria-label': 'Send prompt' }); f.body.append(send);
    const result = await f.inspect({ action: 'sendReady', prompt: f.composer.text,
      expectedModelChoice: { key: 'chat/latest/medium', label: 'Medium' } });
    expect(['product_mode_unverified', 'temporary_mode_unverified', 'model_unverified']).toContain(result.error);
    expect(result.sendReady).toBeUndefined(); expect(send.clicks).toBe(0); expect(f.composer.events).toEqual([]);
  });

  test('a product-only continuation read discards an acknowledged append without acquiring new lineage', async () => {
    const f = fixture({ userPrompt: 'Synthetic owned prompt' }); await f.inspect();
    const pinned = f.world.__computaModelFirstProof;
    f.world.__computaModelLastSubmissionCount = 1;
    f.onDigest(() => { f.appendUser('Exact second synthetic request'); });
    expect(await f.inspect({ action: 'verifyProductMode', expectedUserCounts: [1, 2] })).toMatchObject({
      error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
    expect(f.world.__computaModelFirstProof).toBe(pinned);
    expect(f.composer.events).toEqual([]); expect(f.chatMode.clicks).toBe(0);
  });

  test('a product-only read discards an exact disconnected replacement under the existing first-message pins', async () => {
    const f = fixture({ userPrompt: 'Synthetic owned prompt' }); await f.inspect();
    const original = f.userBody!.parentElement!, parent = original.parentElement!;
    const replacement = new Element(original.tagName, { ...original.values });
    const body = new Element(f.userBody!.tagName, { ...f.userBody!.values }, f.userBody!.text);
    replacement.append(body);
    f.onDigest(() => {
      parent.children[parent.children.indexOf(original)] = replacement; replacement.parentElement = parent; original.connected = false;
    });
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({
      error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
    expect(f.composer.events).toEqual([]);
  });

  test('product-mode rejection exposes finite structure without prompt, account or arbitrary control text', async () => {
    const f = fixture({ response: false, normalRoot: true });
    f.workMode.values['aria-label'] = 'Private account secret'; f.workMode.text = 'Another private value';
    f.composer.text = 'Private user draft';
    const rejected = await f.inspect({ action: 'ensureChatMode' });
    expect(rejected).toMatchObject({ error: 'product_mode_unverified', productModeDiagnostic: {
      kind: 'chatgpt_product_mode_structure', recognized: false, groupCount: 1 } });
    expect(JSON.stringify(rejected)).not.toContain('Private'); expect(JSON.stringify(rejected)).not.toContain('private');
    expect(f.chatMode.clicks).toBe(0);
  });
});

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
        codeTextLength: raw.length, outsideTextLength: 0, outsideTruncated: false,
        literalCodeValidJSON: true, literalCodeKnownEnvelopeType: envelope.type,
        selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
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
      expect(result.completionEvidence.codeStructure).toMatchObject({ literalCodeValidJSON: true,
        literalCodeKnownEnvelopeType: envelope.type, selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
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

  test("the measured PRE header preserves literal envelopes across generated-class and layout changes", async () => {
    for (const envelope of [
      { type: "message", text: 'Literal "quoted" C:\\tmp\\path\nnext line' },
      { type: "tool_calls", calls: [{ name: "browser_open", arguments: { url: "http://127.0.0.1:12345/fixture" } }] },
    ]) for (const copyLabel of ["Copy", "Copy code"]) {
      const f = fixture({ userPrompt: "Synthetic owned response" }), raw = JSON.stringify(envelope);
      const block = observedChatGPTCodeBlock(f, raw, { measuredPRE: true });
      block.copy.values["aria-label"] = copyLabel;
      const result = await f.inspect();
      expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.firstUserVerified).toBe(true); expect(result.firstUserMarkerVerified).toBe(true);
      expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 1, codeCount: 1,
        codeTextLength: raw.length, outsideTextLength: 4, literalCodeValidJSON: true,
        literalCodeKnownEnvelopeType: envelope.type, selectedExtraction: "raw_code", extractionReason: "accepted_literal_code" });
      block.outer.values.class = "CodeBlock-fresh-generated-hash";
      block.wrapper.values.class = "overflow-clip contain-inline-size min-w-0 w-full Root-newhash relative border";
      block.header.values.class = "ActionBar-newhash select-none text-sm font-sans items-center flex min-h-12";
      expect((await f.inspect()).text).toBe(raw);
    }
  });

  test("the measured PRE header cannot borrow controls, reverse branches or hide authored output", async () => {
    for (const change of [
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.wrapper.values.class = "Root-iW7ipz w-full min-w-0 contain-inline-size overflow-clip"; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.header.values.class = "flex items-center font-sans text-sm ActionBar-KWWAct"; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.copy.disabled = true; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.copy.values["aria-disabled"] = "true"; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.copy.values["aria-label"] = "Copy unrelated text"; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.copy.text = "Authored control text"; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.label.text = "json"; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.label.append(new Element("SPAN")); },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.header.append(new Element("DIV", { class: "min-w-0 flex-1 truncate" }, "JSON")); },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { const copy = new Element("BUTTON", { "aria-label": "Copy code" }); copy.disabled = true; b.header.append(copy); },
      (f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.header.children = b.header.children.filter(n => n !== b.copy); f.answer.append(b.copy); },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.wrapper.children = [b.pre, b.header]; },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.wrapper.children = b.wrapper.children.filter(n => n !== b.header); b.outer.append(b.header); },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.header.children = b.header.children.filter(n => n !== b.label); const extra = new Element("DIV"); extra.append(b.label); b.header.append(extra); },
      (f: ReturnType<typeof fixture>, _b: ReturnType<typeof observedChatGPTCodeBlock>) => { f.answer.append(new Element("P", {}, "JSON")); },
      (f: ReturnType<typeof fixture>, _b: ReturnType<typeof observedChatGPTCodeBlock>) => { f.answer.append(new Element("P", {}, "Authored prose")); },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{}')); b.wrapper.append(extra); },
      (_f: ReturnType<typeof fixture>, b: ReturnType<typeof observedChatGPTCodeBlock>) => { b.code.text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(), raw = '{"type":"tool_calls","calls":[{"name":"browser_read","arguments":{}}]}';
      const block = observedChatGPTCodeBlock(f, raw, { measuredPRE: true }); change(f, block);
      const result = await f.inspect();
      expect(result.text).toBe("JSON\n\n\n" + raw);
      expect(result.completionEvidence.codeStructure.selectedExtraction).toBe("rendered_fallback");
    }
  });

  test("extraction diagnostics identify the unchanged strict fallback without exposing response content", async () => {
    const raw = JSON.stringify({ type: "tool_calls", calls: [{ name: "private_tool_name", arguments: { cmd: "private command" } }] });
    type Change = (f: ReturnType<typeof fixture>, pre: Element, code: Element) => void;
    const cases: { change: Change; reason: string; valid: boolean | null; type: string | null }[] = [
      { change: (f) => { f.answer.children = []; }, reason: "missing_code", valid: null, type: null },
      { change: (f) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, raw)); f.answer.append(extra); },
        reason: "multiple_pre", valid: null, type: null },
      { change: (_f, pre) => pre.append(new Element("CODE", {}, raw)), reason: "multiple_code", valid: null, type: null },
      { change: (f, _pre, code) => { f.answer.children = []; f.answer.append(code); }, reason: "missing_pre", valid: null, type: null },
      { change: (_f, _pre, code) => { code.text = '{"type":"tool_calls","calls":[{"name":"private_tool_name"'; },
        reason: "invalid_json", valid: false, type: null },
      { change: (_f, _pre, code) => { code.text = '{"type":"private_unknown_type","private_key":"private value"}'; },
        reason: "unknown_envelope_type", valid: true, type: "unknown" },
      { change: (f) => f.answer.append(new Element("P", {}, "private authored prose")),
        reason: "outside_content", valid: true, type: "tool_calls" },
      { change: (f) => { for (let i = 0; i < 10_001; i++) f.answer.append(new Element("SPAN")); },
        reason: "outside_scan_limit", valid: true, type: "tool_calls" },
      { change: (_f, _pre, code) => { code.text = 'private oversized content'.repeat(10_001); },
        reason: "oversized_code", valid: null, type: null },
    ];
    for (const { change, reason, valid, type } of cases) {
      const f = fixture(); f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, raw); pre.append(code); f.answer.append(pre);
      Object.defineProperty(f.answer, "innerText", { get: () => "private rendered fallback" });
      change(f, pre, code);
      const result = await f.inspect();
      expect(result.text).toBe("private rendered fallback");
      expect(result.completionEvidence.codeStructure).toMatchObject({ literalCodeValidJSON: valid,
        literalCodeKnownEnvelopeType: type, selectedExtraction: "rendered_fallback", extractionReason: reason });
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain("private");
      expect(JSON.stringify(result.completionEvidence.codeStructure).length).toBeLessThanOrEqual(8192);
    }
    const f = fixture(), block = observedChatGPTCodeBlock(f, raw, { noPre: true });
    block.label.text = "private unrecognized header";
    const result = await f.inspect();
    expect(result.text).toBe("JSON\n" + raw);
    expect(result.completionEvidence.codeStructure).toMatchObject({ literalCodeValidJSON: true,
      literalCodeKnownEnvelopeType: "tool_calls", selectedExtraction: "rendered_fallback", extractionReason: "outside_content" });
    expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain("private");
  });

  test("an absent answer has finite extraction diagnostics and cannot look like admitted code", async () => {
    const result = await fixture({ response: false }).inspect();
    expect(result.text).toBe("");
    expect(result.answerComplete).toBe(false);
    expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 0, codeCount: 0,
      codeTextLength: 0, outsideTextLength: 0, literalCodeValidJSON: null, literalCodeKnownEnvelopeType: null,
      selectedExtraction: "rendered_fallback", extractionReason: "absent_answer" });
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
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.wrapper.values.class = "w-full min-w-0 overflow-clip contain-inline-size border"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.header.values.class = "flex items-center font-sans text-sm min-h-12"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.values.class = "min-w-0 flex-1"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.text = "json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.text = "Json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.label.append(new Element("EM", {}, "")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedChatGPTCodeBlock>) => { block.copy.values["aria-label"] = "Copy unrelated text"; },
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

  test("private-world mutation notifications deliver without page timers", async () => {
    const f = fixture();
    await f.inspect(); await f.inspect();
    expect(f.observers).toHaveLength(1);
    expect(f.posted).toEqual([]); expect(f.scheduledDelays).toEqual([]);
    expect(f.observers[0].options?.attributeFilter).toContain("disabled");
    expect(f.observers[0].options?.attributeFilter).toContain("aria-hidden");
    expect(f.observers[0].options?.attributeFilter).toContain("data-turn");
    expect(f.observers[0].options?.attributeFilter).toContain("data-user-message-bubble");
    // Do not flush parked page timers; delivery is an actual mutation event.
    f.observers[0].callback([{ type: "childList" }]);
    f.observers[0].callback([{ type: "characterData" }]);
    expect(f.scheduledDelays).toEqual([]);
    expect(f.posted).toEqual(Array(2).fill({ ownerToken: "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30", kind: "dom_changed" }));
    f.location.origin = "https://example.test";
    f.observers[0].callback([{ type: "attributes" }]);
    expect(f.posted).toHaveLength(2);
  });
});
