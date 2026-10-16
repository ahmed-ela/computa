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
  zeroRects = false;
  cssVisibility = 'visible';
  beforeContent = 'none';
  afterContent = 'none';
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
  getClientRects() { return this.isConnected && !this.zeroRects && this.values['data-fixture-display'] !== 'contents' && !this.closest('[hidden]') ? [{}] : []; }
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
  let digestHook: (() => void | Promise<void>) | undefined;
  let digestExpectedText: string | undefined;
  let productBootstrapped = false;
  const invoke = (request: Record<string, unknown>, useHook = true) => execute({ provider: 'chatgpt', ownerToken, bindOwner: true,
    expectedURL: document.URL, expectedUserCounts: [options.userPrompt === undefined ? 0 : 1],
    expectedFirstUserMarker: firstMarker, expectedFirstUserFingerprint: nativeFingerprint,
    allowFirstUserBinding: nativeFingerprint === undefined, ...request },
    document, window, location, (node: Element, pseudo?: string) => ({ visibility: node.cssVisibility,
      display: node.values['data-fixture-display'] ?? (node.getAttribute('hidden') !== null ? 'none' : 'block'),
      content: pseudo === '::before' ? node.beforeContent : node.afterContent }), Observer, (callback: () => void, delay: number) => {
      timers.push(callback); scheduledDelays.push(delay);
    }, world, { subtle: { digest: async (algorithm: string, data: Uint8Array) => {
      const digest = await crypto.subtle.digest(algorithm, data);
      if (useHook && (digestExpectedText === undefined || new TextDecoder().decode(data) === digestExpectedText)) {
        const hook = digestHook; digestHook = undefined; digestExpectedText = undefined; await hook?.();
      }
      return digest;
    } } }, class TextArea extends Element {}, { now: () => Date.now() + adapterClockOffset });
  return { rawRun: invoke, messages, posted, observers, location, document, world, window, body, temporary, composer, modeGroup, chatMode, workMode, scheduledDelays, userBody, answer: outer,
    advanceTime: (milliseconds: number) => { adapterClockOffset += milliseconds; },
    setHit: (node: Element | null | undefined) => { hitOverride = node; },
    appendUser: (prompt: string) => {
      const root = new Element('ARTICLE', { 'data-turn': 'user', 'data-testid': 'conversation-turn-appended' });
      root.append(new Element('DIV', { class: 'whitespace-pre-wrap' }, prompt)); messages.append(root); return root;
    },
    onDigest: (hook: () => void | Promise<void>, expectedText?: string) => { digestHook = hook; digestExpectedText = expectedText; },
    diagnose: (overrides: Record<string, unknown> = {}) => invoke({ action: 'failedPageDiagnostic', bindOwner: false, ...overrides }),
    submit: (prompt: string) => invoke({ action: 'submit', prompt }),
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

async function chatTurnFixture(modelChoice?: { key: string; label: string }, initialMarker = firstMarker) {
  const f = fixture({ response: false });
  await f.inspect({ expectedUserCounts: [0], expectedFirstUserMarker: initialMarker });
  let picker: ReturnType<typeof installObservedModelPicker> | undefined;
  if (modelChoice) {
    picker = installObservedModelPicker(f, 'chatgpt', Element, { genericHeader: true });
    const model = await f.inspect({ action: 'verifyModel', expectedUserCounts: [0], expectedModelChoice: modelChoice });
    expect(model.error).toBeUndefined();
  }
  const selection: any = { anchorNode: f.composer, focusNode: f.composer,
    removeAllRanges() {}, addRange() {} };
  (f.window as any).getSelection = () => selection;
  (f.document as any).createRange = () => ({ selectNodeContents(node: Element) {
    selection.anchorNode = node; selection.focusNode = node;
  }, collapse() {} });
  (f.composer as any).focus = () => { (f.document as any).activeElement = f.composer; };
  (f.document as any).execCommand = (command: string, _ui: boolean, text: string) => {
    if (command !== 'insertText') return false; f.composer.text = text; return true;
  };
  const send = new Element('BUTTON', { 'aria-label': 'Send prompt' }); f.body.append(send);
  let outgoing = '', addBody = true;
  send.onClick = () => { if (addBody) f.appendUser(outgoing); f.composer.text = ''; };
  const proofs: { sequence: number; fingerprint: string }[] = [];
  const records: { sequence: number; marker: string; outbound: string; fingerprint: string }[] = [];
  const hex = async (text: string) => [...new Uint8Array(await crypto.subtle.digest('SHA-256',
    new TextEncoder().encode(text.replace(/\r\n?/g, '\n').normalize('NFC').trim())))].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const values = (record: typeof records[number], current = proofs) => ({ submissionSequence: record.sequence,
    submissionMarker: record.marker, expectedFirstUserMarker: initialMarker, expectedSubmissionProofs: current.slice(-2), ...(modelChoice ? { expectedModelChoice: modelChoice } : {}) });
  return { f, send, records, proofs, values, picker,
    addBody(value: boolean) { addBody = value; },
    async dispatch(text: string, submitOverrides: Record<string, unknown> = {}, beforeSubmit?: () => void) {
      const sequence = records.length + 1, marker = sequence === 1 ? initialMarker
        : `00000000-0000-4000-8000-${sequence.toString(16).padStart(12, '0')}`;
      const outbound = text + '\n\nComputa session marker: ' + marker;
      const record = { sequence, marker, outbound, fingerprint: await hex(outbound) };
      const inserted = await f.rawRun({ action: 'insert', prompt: outbound, expectedUserCounts: [sequence - 1], ...values(record) });
      expect(inserted.error).toBeUndefined(); expect(inserted.inserted).toBe(true);
      const ready = await f.rawRun({ action: 'sendReady', prompt: outbound, expectedUserCounts: [sequence - 1], ...values(record) });
      expect(ready.sendReady).toBe(true);
      outgoing = outbound; proofs.push({ sequence, fingerprint: record.fingerprint }); records.push(record);
      beforeSubmit?.();
      const ack = await f.rawRun({ action: 'submit', prompt: outbound, expectedUserCounts: [sequence - 1], ...values(record), ...submitOverrides });
      expect(ack.error).toBeUndefined(); expect(ack.submitted).toBe(true); expect(ack.submissionPending).toBe(true);
      expect(ack.text).toBe(''); expect(ack.answerComplete).toBe(false); expect(ack).not.toHaveProperty('submissionProof');
      return record;
    },
    async observe(record = records.at(-1)!, overrides: Record<string, unknown> = {}) {
      return await f.inspect({ expectedUserCounts: [record.sequence], ...values(record), ...overrides });
    },
    answer(text: string) {
      const root = new Element('ARTICLE', { 'data-turn': 'assistant' });
      root.append(new Element('DIV', { 'data-markdown-text-style': 'assistant-message' }, JSON.stringify({ type: 'message', text })),
        new Element('BUTTON', { 'aria-label': 'Copy' })); f.messages.append(root); return root;
    } };
}

describe('ChatGPT bounded in-flight model proof deferral', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };

  test('Send retains a full precheck and its post-Send guard opens no picker', async () => {
    const x = await chatTurnFixture(choice), picker: any = x.picker;
    let beforeSubmit = 0, atSend = 0;
    const send = x.send.onClick!;
    x.send.onClick = () => { atSend = picker.trigger.clicks; send(); };
    const record = await x.dispatch('Owned deferred submission', { deferModelVerification: true }, () => { beforeSubmit = picker.trigger.clicks; });
    expect(atSend).toBeGreaterThan(beforeSubmit);
    expect(picker.trigger.clicks).toBe(atSend); expect(x.send.clicks).toBe(1);
    x.answer('Final owned answer');
    for (const action of ['inspect', 'verifyModel', 'verifyProductMode']) {
      const observed = await x.observe(record, { action, deferModelVerification: true });
      expect(observed.error).toBeUndefined(); expect(observed.modelVerificationPending).toBe(true);
      expect(observed).not.toHaveProperty('modelEvidence'); expect(picker.trigger.clicks).toBe(atSend);
    }
    const complete = await x.observe(record, { deferModelVerification: false });
    expect(complete.error).toBeUndefined(); expect(complete.modelEvidence.selected).toEqual(choice);
    expect(complete).not.toHaveProperty('modelVerificationPending'); expect(complete.answerComplete).toBe(true);
    expect(complete.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    expect(picker.trigger.clicks).toBeGreaterThan(atSend); expect(x.send.clicks).toBe(1);
  });

  test('deferred reads require an enabled closed recognized header without opening the picker', async () => {
    for (const mutation of ['disabled', 'open', 'unknown_power']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const record = await x.dispatch('Owned passive header observation'); x.answer('Owned answer');
      const before = picker.trigger.clicks;
      const healthy = await x.observe(record, { deferModelVerification: true });
      expect(healthy.error).toBeUndefined(); expect(healthy.modelVerificationPending).toBe(true);
      expect(healthy).not.toHaveProperty('modelEvidence'); expect(picker.trigger.clicks).toBe(before);
      if (mutation === 'disabled') picker.trigger.disabled = true;
      if (mutation === 'open') picker.trigger.values['aria-expanded'] = 'true';
      if (mutation === 'unknown_power') picker.trigger.text = 'Thinking effort';
      const rejected = await x.observe(record, { deferModelVerification: true });
      expect(rejected.error).toBeDefined(); expect(rejected).not.toHaveProperty('modelVerificationPending');
      expect(rejected).not.toHaveProperty('modelEvidence'); expect(picker.trigger.clicks).toBe(before);
      expect(x.send.clicks).toBe(1);
    }
  });

  test('an initial model read cannot defer before any Send', async () => {
    const x = await chatTurnFixture(choice), picker: any = x.picker, before = picker.trigger.clicks;
    const observed = await x.f.inspect({ action: 'verifyModel', expectedUserCounts: [0], expectedModelChoice: choice,
      deferModelVerification: true });
    expect(observed.error).toBeUndefined(); expect(observed.modelEvidence.selected).toEqual(choice);
    expect(observed).not.toHaveProperty('modelVerificationPending'); expect(picker.trigger.clicks).toBeGreaterThan(before);
  });

  test('only a first claimed root-to-local or public route Send can acknowledge pending without body authority', async () => {
    for (const path of ['/c/local-chatgpt%3Afixture', '/c/public-fixture']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const raw = x.f.rawRun; let ack: any, atSend = 0;
      x.f.rawRun = async request => { const result = await raw(request); if (request.action === 'submit') ack = result; return result; };
      const click = x.send.onClick!;
      x.send.onClick = () => { atSend = picker.trigger.clicks; click();
        x.f.document.URL = 'https://chatgpt.com' + path + '?temporary-chat=true'; x.f.location.pathname = path; };
      const first = await x.dispatch('Exact first deferred route transition', { deferModelVerification: true });
      expect(ack).toMatchObject({ submitted: true, modelVerificationPending: true, submissionPending: true, text: '', answerComplete: false });
      expect(ack).not.toHaveProperty('modelEvidence'); expect(ack).not.toHaveProperty('submissionProof');
      expect(ack.firstUserFingerprint == null).toBe(true); expect(picker.trigger.clicks).toBe(atSend);
      x.answer('Fresh URL answer');
      const current = await x.observe(first, { deferModelVerification: false });
      expect(current.error).toBeUndefined(); expect(current.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
      expect(current.answerComplete).toBe(true); expect(x.send.clicks).toBe(1);
    }
  });

  test('a deferred route acknowledgment rejects foreign later stale marker and document witnesses', async () => {
    for (const mutation of ['foreign', 'later', 'stale', 'marker', 'document']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      if (mutation === 'later') { const first = await x.dispatch('Exact first'); x.answer('First'); await x.observe(first); }
      const sequence = mutation === 'later' ? 2 : 1;
      const marker = sequence === 1 ? firstMarker : '00000000-0000-4000-8000-000000000002';
      const outbound = 'Exact rejected route request\n\nComputa session marker: ' + marker;
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(outbound));
      const fingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
      const values = { submissionSequence: sequence, submissionMarker: marker, expectedUserCounts: [sequence - 1],
        expectedModelChoice: choice, expectedSubmissionProofs: [...x.proofs.slice(-1)] };
      expect((await x.f.rawRun({ action: 'insert', prompt: outbound, ...values })).inserted).toBe(true);
      expect((await x.f.rawRun({ action: 'sendReady', prompt: outbound, ...values })).sendReady).toBe(true);
      let atSend = 0;
      x.send.onClick = () => { atSend = picker.trigger.clicks; x.f.appendUser(outbound); x.f.composer.text = '';
        x.f.document.URL = mutation === 'foreign' ? 'https://foreign.test/c/fixture' : 'https://chatgpt.com/c/new-fixture?temporary-chat=true';
        const state: any = x.f.world.__computaChatSubmissionState;
        if (mutation === 'stale') x.f.world.__computaChatActiveInvocation = {};
        if (mutation === 'marker') state.pending.marker = '00000000-0000-4000-8000-000000000099';
        if (mutation === 'document') state.document = {};
      };
      const ack = await x.f.rawRun({ action: 'submit', prompt: outbound, ...values, deferModelVerification: true,
        expectedSubmissionProofs: [...x.proofs.slice(-1), { sequence, fingerprint }] });
      expect(ack.error).toBeDefined(); expect(ack).not.toHaveProperty('modelVerificationPending');
      expect(ack).not.toHaveProperty('modelEvidence'); expect(ack).not.toHaveProperty('submissionProof');
      expect(ack).not.toHaveProperty('answerComplete', true); expect(picker.trigger.clicks).toBe(atSend);
      expect(x.send.clicks).toBe(sequence);
    }
  });

  test('deferred reads drain switch-and-restore negatives without opening the picker', async () => {
    for (const field of ['power', 'header']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const record = await x.dispatch('Owned negative observation'); x.answer('Owned answer');
      const before = picker.trigger.clicks, pin: any = x.f.world.__computaChatPresetPin;
      let records: any[];
      if (field === 'power') {
        picker.selected('High'); picker.selected('Medium');
        records = [{ type: 'attributes', target: picker.slider, attributeName: 'aria-valuenow', oldValue: '2' }];
        pin.semanticObserver.takeRecords = () => { const result = records; records = []; return result; };
      } else {
        const leaf: any = { nodeType: 3, textContent: 'Medium', parentElement: picker.trigger };
        records = [{ type: 'characterData', target: leaf, oldValue: 'High' }];
        pin.headerObserver.takeRecords = () => { const result = records; records = []; return result; };
      }
      const observed = await x.observe(record, { deferModelVerification: true });
      expect(observed.error).toBe('model_mismatch'); expect(observed).not.toHaveProperty('modelEvidence');
      expect(pin.invalidated).toBe(true); expect(picker.trigger.clicks).toBe(before);
    }
  });

  test('one healthy provisional header stays pending with zero opens until full original remount proof transfers its pin', async () => {
    const x = await chatTurnFixture(choice), picker: any = x.picker;
    const record = await x.dispatch('Owned header remount'); x.answer('Owned answer');
    const pin: any = x.f.world.__computaChatPresetPin, old = picker.replaceTrigger(), before = picker.trigger.clicks;
    const deferred = await x.observe(record, { deferModelVerification: true });
    expect(deferred.error).toBeUndefined(); expect(deferred.modelVerificationPending).toBe(true);
    expect(deferred).not.toHaveProperty('modelEvidence');
    expect(pin.headerTrigger).toBe(old); expect(picker.trigger.clicks).toBe(before);
    const provisional = pin.provisionalHeader; let disconnected = 0;
    provisional.observer.disconnect = () => { disconnected++; };
    expect(provisional.header).toBe(picker.trigger); expect(provisional.previous).toBe(old);
    expect(provisional.completed).toBe(false);
    const full = await x.observe(record, { deferModelVerification: false });
    expect(full.error).toBeUndefined(); expect(full.modelEvidence.selected).toEqual(choice);
    expect(pin.headerTrigger).toBe(picker.trigger); expect(picker.trigger.clicks).toBeGreaterThan(before);
    expect(pin.provisionalHeader).toBe(provisional); expect(provisional.completed).toBe(true); expect(disconnected).toBe(1);
  });

  test('provisional header negative history cannot be restored replaced rearmed or borrowed by a stale owner', async () => {
    for (const mutation of ['flip_restore', 'unknown_restore', 'detached_flip_restore', 'second_replacement', 'old_reconnect',
      'foreign_owner', 'foreign_url', 'queued_before_full']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const record = await x.dispatch('Owned provisional header history'); x.answer('Owned answer');
      const pin: any = x.f.world.__computaChatPresetPin, old = picker.replaceTrigger();
      expect((await x.observe(record, { deferModelVerification: true })).modelVerificationPending).toBe(true);
      const provisional = pin.provisionalHeader, before = picker.trigger.clicks;
      const leaf: any = { nodeType: 3, textContent: 'Medium', parentElement: picker.trigger };
      const records: any[] = [{ type: 'characterData', target: leaf,
        oldValue: mutation === 'unknown_restore' ? 'PRIVATE_UNKNOWN_HEADER' : 'High' }];
      if (mutation === 'detached_flip_restore') {
        leaf.parentElement = null;
        records.unshift({ type: 'childList', target: picker.trigger, addedNodes: [], removedNodes: [leaf] });
      }
      if (['flip_restore', 'unknown_restore', 'detached_flip_restore'].includes(mutation)) provisional.observer.callback(records);
      if (mutation === 'queued_before_full') provisional.observer.takeRecords = () => records.splice(0);
      if (mutation === 'second_replacement') picker.replaceTrigger();
      if (mutation === 'old_reconnect') old.connected = true;
      if (mutation === 'foreign_owner') x.f.world.__computaModelOwner = 'fc109e52-2192-45c7-8f63-4ab8ea137999';
      const overrides: any = { deferModelVerification: mutation !== 'queued_before_full' };
      if (mutation === 'foreign_url') overrides.expectedURL = 'https://chatgpt.com/c/stale-certified-route';
      const observed = await x.observe(record, overrides);
      expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('modelEvidence');
      expect(observed).not.toHaveProperty('modelVerificationPending'); expect(picker.trigger.clicks).toBe(before);
      expect(pin.headerTrigger).toBe(old); expect(pin.provisionalHeader).toBe(provisional); expect(provisional.completed).toBe(false);
      expect(JSON.stringify(observed)).not.toContain('PRIVATE_UNKNOWN_HEADER');
    }
  });

  test('foreign ownership and another expected preset cannot become pending model authority', async () => {
    for (const foreign of [true, false]) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const record = await x.dispatch('Owned native choice'); x.answer('Owned answer');
      const before = picker.trigger.clicks;
      const observed = await x.observe(record, { deferModelVerification: true, ...(foreign
        ? { ownerToken: 'fc109e52-2192-45c7-8f63-4ab8ea137999', bindOwner: false }
        : { expectedModelChoice: { key: 'chat/latest/high', label: 'High' } }) });
      expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('modelEvidence');
      expect(observed).not.toHaveProperty('modelVerificationPending'); expect(picker.trigger.clicks).toBe(before);
    }
  });

  test('first and later owned submission expansion use pending guards with zero picker opens', async () => {
    for (const sequence of [1, 2]) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      if (sequence === 2) { const first = await x.dispatch('First exact request'); x.answer('First'); await x.observe(first); }
      const record = await x.dispatch('Owned expansion ' + 'A'.repeat(11_000), { deferModelVerification: true });
      x.answer('Expanded owned answer');
      const root = x.f.document.querySelectorAll('article[data-turn="user"]')[sequence - 1], body = root.children[0];
      body.text = record.outbound.slice(0, 40);
      const more = new Element('BUTTON', { 'aria-label': 'Show more' });
      more.onClick = () => { body.text = record.outbound; }; root.append(more);
      const before = picker.trigger.clicks;
      const observed = await x.observe(record, { deferModelVerification: true, allowFirstUserExpansion: true,
        firstUserExpansionModelChoice: choice, allowSubmissionExpansion: true });
      expect(observed.error).toBeUndefined(); expect(observed.modelVerificationPending).toBe(true);
      expect(observed).not.toHaveProperty('modelEvidence'); expect(more.clicks).toBe(1);
      expect(picker.trigger.clicks).toBe(before); expect(x.send.clicks).toBe(sequence);
    }
  });

  test('full final proof rejects answer body text count busy or footer drift across the picker await', async () => {
    for (const mutation of ['text', 'body', 'count', 'busy', 'footer']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const record = await x.dispatch('Exact final response snapshot'), answer = x.answer('Original');
      await x.observe(record, { deferModelVerification: true });
      let opens = 0; const open = picker.trigger.onClick;
      picker.trigger.onClick = () => {
        open(); if (++opens !== 2) return;
        if (mutation === 'text') answer.children[0].text += ' changed';
        if (mutation === 'body') {
          const old = answer.children[0], replacement = new Element(old.tagName, { ...old.values }, old.text);
          replacement.parentElement = answer; answer.children[0] = replacement; old.connected = false;
        }
        if (mutation === 'count') x.answer('Unowned extra answer');
        if (mutation === 'busy') x.f.body.append(new Element('BUTTON', { 'aria-label': 'Stop streaming' }));
        if (mutation === 'footer') answer.children[1].disabled = true;
      };
      const observed = await x.observe(record, { deferModelVerification: false });
      expect(opens).toBe(2); expect(observed).toMatchObject({ error: 'conversation_changed', detail: 'response_changed' });
      expect(observed).not.toHaveProperty('modelEvidence'); expect(observed).not.toHaveProperty('submissionProof'); expect(x.send.clicks).toBe(1);
    }
  });

  test('the last submission digest cannot publish stale answer or authority after final model proof', async () => {
    for (const mutation of ['answer', 'owner', 'product', 'header']) {
      const x = await chatTurnFixture(choice), picker: any = x.picker;
      const record = await x.dispatch('Exact final digest snapshot'), answer = x.answer('Original');
      await x.observe(record, { deferModelVerification: true });
      let closes = 0, mutated = false; const close = picker.menu.onDispatch;
      picker.menu.onDispatch = (event: any) => {
        close(event); if (++closes !== 2) return;
        x.f.onDigest(() => {
          mutated = true;
          if (mutation === 'answer') answer.children[0].text += ' changed after proof';
          if (mutation === 'owner') x.f.world.__computaModelOwner = 'fc109e52-2192-45c7-8f63-4ab8ea137999';
          if (mutation === 'product') { x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true'; }
          if (mutation === 'header') picker.replaceTrigger();
        }, record.outbound);
      };
      const observed = await x.observe(record, { deferModelVerification: false });
      expect(mutated).toBe(true); expect(observed.error).toBeDefined();
      expect(observed).not.toHaveProperty('modelEvidence'); expect(observed).not.toHaveProperty('submissionProof'); expect(x.send.clicks).toBe(1);
    }
  });
});

describe('ChatGPT per-round canonical submission ownership', () => {
  const replaceRoot = (x: Awaited<ReturnType<typeof chatTurnFixture>>, ordinal = 0, changed = false) => {
    const roots = x.f.document.querySelectorAll('article[data-turn="user"]'), old = roots[ordinal];
    const root = new Element('ARTICLE', { 'data-turn': 'user' });
    root.append(new Element('DIV', { class: 'whitespace-pre-wrap' }, old.children[0].text + (changed ? '!' : '')));
    x.f.messages.children = x.f.messages.children.map(node => node === old ? root : node);
    root.parentElement = x.f.messages; old.connected = false;
    return { old, root, body: root.children[0] };
  };

  test('first claimed root-to-conversation acknowledgement publishes no body authority and fresh URL read proves it', async () => {
    const x = await chatTurnFixture(); const click = x.send.onClick!;
    x.send.onClick = () => { click(); x.f.document.URL = 'https://chatgpt.com/c/local-chatgpt%3Afixture?temporary-chat=true';
      x.f.location.pathname = '/c/local-chatgpt%3Afixture'; };
    const first = await x.dispatch('Exact first route transition');
    x.answer('First complete'); const current = await x.observe(first);
    expect(current.error).toBeUndefined(); expect(current.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
    expect(x.send.clicks).toBe(1);
    const second = await x.dispatch('Exact second route-stable request'); x.answer('Second complete');
    expect((await x.observe(second)).submissionProof).toEqual({ sequence: 2, fingerprint: second.fingerprint });
    expect(x.send.clicks).toBe(2);
  });

  test('a first Send cannot acknowledge foreign or unrelated routes and later Send cannot promote a new route', async () => {
    for (const [route, later] of [['https://foreign.test/c/x', false], ['https://chatgpt.com/settings', false],
      ['https://chatgpt.com/c/different?temporary-chat=true', true]] as const) {
      const x = await chatTurnFixture();
      if (later) { const first = await x.dispatch('Exact first'); x.answer('First'); await x.observe(first); }
      const sequence = later ? 2 : 1, marker = later ? '00000000-0000-4000-8000-000000000002' : firstMarker;
      const outbound = 'Exact route request\n\nComputa session marker: ' + marker;
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(outbound));
      const fingerprint = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
      const values = { submissionSequence: sequence, submissionMarker: marker, expectedUserCounts: [sequence - 1],
        expectedSubmissionProofs: [...x.proofs.slice(-1)] };
      expect((await x.f.rawRun({ action: 'insert', prompt: outbound, ...values })).inserted).toBe(true);
      const click = x.send.onClick!;
      x.send.onClick = () => { x.f.appendUser(outbound); x.f.composer.text = ''; x.f.document.URL = route; };
      const ack = await x.f.rawRun({ action: 'submit', prompt: outbound, ...values,
        expectedSubmissionProofs: [...x.proofs.slice(-1), { sequence, fingerprint }] });
      expect(ack.error).toBeDefined(); expect(ack).not.toHaveProperty('submissionProof'); expect(ack).not.toHaveProperty('answerComplete', true);
      expect(x.send.clicks).toBe(sequence);
    }
  });

  test('only an existing certified first-body discard can rebind an exact detached root on fresh inspect', async () => {
    const x = await chatTurnFixture({ key: 'chat/latest/medium', label: 'Medium' });
    const first = await x.dispatch('Exact first certified replacement'); x.answer('First'); await x.observe(first); await x.observe(first);
    const state: any = x.f.world.__computaChatSubmissionState, record = state.lastVerified;
    expect(record.nativeFirstPinned).toBe(true);
    let replacement: ReturnType<typeof replaceRoot>;
    x.f.onDigest(() => { replacement = replaceRoot(x); }, first.outbound);
    const discarded = await x.observe(first);
    expect(discarded).toMatchObject({ error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
    expect(discarded).not.toHaveProperty('submissionProof'); expect(discarded).not.toHaveProperty('text');
    expect(record.root).toBe(replacement!.old); expect(record.replacement.root).toBe(replacement!.root);
    const current = await x.observe(first);
    expect(current.error).toBeUndefined(); expect(current.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
    expect(record.root).toBe(replacement!.root); expect(record.replacement).toBeNull(); expect(state.revoked).toBe(false);
    expect(x.send.clicks).toBe(1);

    // No certificate exists for a replacement between reads, even at seq1.
    replaceRoot(x);
    const unissued = await x.observe(first);
    expect(unissued.error).toBeDefined(); expect(unissued).not.toHaveProperty('submissionProof'); expect(x.send.clicks).toBe(1);
  });

  test('a certified candidate is refused after replacement body or native pin changes and during its digest', async () => {
    for (const mutation of ['body', 'root', 'native_pin', 'digest']) {
      const x = await chatTurnFixture({ key: 'chat/latest/medium', label: 'Medium' });
      const first = await x.dispatch('Exact certified bytes'); x.answer('First'); await x.observe(first); await x.observe(first);
      x.f.onDigest(() => { replaceRoot(x); }, first.outbound);
      expect((await x.observe(first)).error).toBe('first_user_observation_replaced');
      if (mutation === 'body') x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0].text += '!';
      if (mutation === 'root') replaceRoot(x);
      if (mutation === 'digest') x.f.onDigest(() => { replaceRoot(x); }, first.outbound);
      const current = await x.observe(first, mutation === 'native_pin' ? { expectedSubmissionProofs: [{ sequence: 1, fingerprint: '0'.repeat(64) }] } : {});
      expect(current.error).toBeDefined(); expect(current).not.toHaveProperty('submissionProof'); expect(x.send.clicks).toBe(1);
    }
  });

  test('a private-only first read rejects its crossed replacement but a separate Native-authorized binding proves exact bytes', async () => {
    const x = await chatTurnFixture({ key: 'chat/latest/medium', label: 'Medium' });
    const first = await x.dispatch('Exact provisional first read'); x.answer('First');
    const initial = await x.f.rawRun({ action: 'inspect', expectedUserCounts: [1], ...x.values(first),
      expectedFirstUserFingerprint: null, allowFirstUserBinding: true });
    expect(initial.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
    const record: any = (x.f.world.__computaChatSubmissionState as any).lastVerified;
    expect(record.nativeFirstPinned).not.toBe(true);
    x.f.onDigest(() => { replaceRoot(x); }, first.outbound);
    const crossed = await x.f.rawRun({ action: 'inspect', expectedUserCounts: [1], ...x.values(first),
      expectedFirstUserFingerprint: null, allowFirstUserBinding: true });
    expect(crossed).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(crossed).not.toHaveProperty('submissionProof'); expect(record.replacement).toBeUndefined();
    const independentlyBound = await x.observe(first, { expectedFirstUserFingerprint: null, allowFirstUserBinding: true });
    expect(independentlyBound.error).toBeUndefined(); expect(independentlyBound.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
    expect(record.root).toBe(x.f.document.querySelectorAll('article[data-turn="user"]')[0]); expect(x.send.clicks).toBe(1);
  });

  const collapsedSecond = async (mutation = 'none') => {
    const x = await chatTurnFixture({ key: 'chat/latest/medium', label: 'Medium' });
    const first = await x.dispatch('Exact first canonical request'); x.answer('First'); await x.observe(first);
    const second = await x.dispatch('Complete second canonical request ' + 'A'.repeat(180)); x.answer('Second');
    const root = x.f.document.querySelectorAll('article[data-turn="user"]')[1], body = root.children[0];
    body.text = second.outbound.slice(0, 40);
    const more = new Element('BUTTON', { 'aria-label': 'Show more' }, 'Show more');
    more.onClick = () => { body.text = second.outbound + (mutation === 'expanded_change' ? '!' : ''); };
    if (mutation !== 'missing_control') root.append(more);
    return { ...x, first, second, root, body, more };
  };

  test('product-only collapsed current submission stays pending without authority until authorized exact expansion', async () => {
    const x = await collapsedSecond();
    const deferred = await x.observe(x.second, { action: 'verifyProductMode', expectedModelChoice: null, allowSubmissionExpansion: false });
    expect(deferred.error).toBeUndefined();
    expect(deferred).toMatchObject({ submissionOwnershipCapability: 'per_submission_ownership_v1', submissionPending: true,
      temporary: true, text: '', answerComplete: false,
      productModeEvidence: { product: 'chatgpt', mode: 'chat', temporaryTransition: 'acknowledged' } });
    expect(deferred).not.toHaveProperty('submissionProof');
    const state: any = x.f.world.__computaChatSubmissionState;
    expect(state.revoked).toBe(false); expect(state.pending.phase).toBe('send_claimed');
    expect(state.pending.root).toBeNull(); expect(state.pending.body).toBeNull(); expect(state.pending.expansionAttempted).toBe(false);
    expect(state.lastVerified.sequence).toBe(1); expect(x.more.clicks).toBe(0); expect(x.send.clicks).toBe(2);
    const current = await x.observe(x.second, { allowSubmissionExpansion: true });
    expect(current.error).toBeUndefined(); expect(current.submissionProof).toEqual({ sequence: 2, fingerprint: x.second.fingerprint });
    expect(current.firstUserFingerprint).toBe(x.first.fingerprint);
    expect(current.text).toContain('Second'); expect(current.answerComplete).toBe(true);
    expect(x.more.clicks).toBe(1); expect(x.send.clicks).toBe(2);
  });

  test('pending product-only deferral rejects wrong prefix marker prior product and pins while authorized expansion still rejects drift', async () => {
    for (const mutation of ['wrong_prefix', 'full_wrong', 'marker', 'prior', 'product', 'native_pin', 'model', 'missing_control', 'expanded_change']) {
      const x = await collapsedSecond(mutation);
      if (mutation === 'wrong_prefix') x.body.text = 'Wrong ' + x.body.text;
      if (mutation === 'full_wrong') x.body.text = x.second.outbound + '!';
      if (mutation === 'marker') x.body.text += '\nComputa session marker: ' + x.second.marker;
      if (mutation === 'prior') x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0].text += '!';
      if (mutation === 'product') {
        x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true';
        x.f.observers.forEach(observer => observer.callback([{ type: 'attributes', target: x.f.workMode,
          attributeName: 'aria-pressed', oldValue: 'false' }]));
      }
      const overrides: any = { action: 'verifyProductMode', expectedModelChoice: null, allowSubmissionExpansion: false };
      if (mutation === 'native_pin') overrides.expectedSubmissionProofs = [
        { sequence: 1, fingerprint: x.first.fingerprint }, { sequence: 2, fingerprint: '0'.repeat(64) }];
      if (mutation === 'model') {
        const thumb = x.f.document.querySelectorAll('[role="slider"]')[0];
        expect(thumb).toBeDefined(); thumb.values['aria-valuenow'] = '2';
      }
      const observed = await x.observe(x.second, overrides);
      if (['model', 'missing_control', 'expanded_change'].includes(mutation)) {
        expect(observed.error).toBeUndefined(); expect(observed.submissionPending).toBe(true);
        expect(observed).not.toHaveProperty('submissionProof'); expect(observed.text).toBe('');
        expect(x.more.clicks).toBe(0);
        const rejected = await x.observe(x.second, { allowSubmissionExpansion: true });
        expect(rejected.error).toBeDefined(); expect(rejected).not.toHaveProperty('submissionProof');
        expect(rejected).not.toHaveProperty('answerComplete', true);
        expect(x.more.clicks).toBe(mutation === 'expanded_change' ? 1 : 0);
      } else {
        expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('submissionProof');
        expect(observed).not.toHaveProperty('answerComplete', true); expect(x.more.clicks).toBe(0);
      }
      expect(x.send.clicks).toBe(2);
    }
  });

  test('submission failure diagnostics distinguish exact physical replacements from content and native pin mismatch', async () => {
    const fields = ['kind', 'action', 'stage', 'requestedSequence', 'recordSequence', 'userCount', 'contextMatches',
      'nativePinMatches', 'pendingRecord', 'lastVerifiedRecord', 'rootSame', 'bodySame', 'oldRootConnected',
      'oldBodyConnected', 'currentRootConnected', 'currentBodyConnected', 'canonicalMatches', 'oldRootPresent', 'oldBodyPresent', 'recordPhase', 'contextChecks'].sort();
    for (const mutation of ['whole_root', 'body_only', 'content', 'native_pin']) {
      const x = await chatTurnFixture(); const first = await x.dispatch('PRIVATE_FIRST_CANARY'); x.answer('First'); await x.observe(first);
      const second = await x.dispatch('PRIVATE_SECOND_CANARY'); x.answer('Second'); await x.observe(second);
      const state: any = x.f.world.__computaChatSubmissionState;
      if (mutation === 'whole_root') replaceRoot(x, 1);
      if (mutation === 'body_only') {
        const root = x.f.document.querySelectorAll('article[data-turn="user"]')[1], old = root.children[0];
        const body = new Element('DIV', { class: 'whitespace-pre-wrap' }, second.outbound);
        root.children = [body]; body.parentElement = root; old.connected = false;
      }
      if (mutation === 'content') x.f.document.querySelectorAll('article[data-turn="user"]')[1].children[0].text += '!';
      const rejected = await x.observe(second, mutation === 'native_pin' ? { expectedSubmissionProofs: [
        { sequence: 1, fingerprint: first.fingerprint }, { sequence: 2, fingerprint: '0'.repeat(64) }] } : {});
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      const diagnostic = rejected.submissionDiagnostic;
      expect(Object.keys(diagnostic).sort()).toEqual(fields);
      expect(diagnostic).toMatchObject({ kind: 'chatgpt_submission_v1', action: 'inspect', requestedSequence: 2,
        recordSequence: 2, userCount: 2, contextMatches: true, pendingRecord: false, lastVerifiedRecord: true,
        stage: mutation === 'native_pin' ? 'observe_count' : mutation === 'content' ? 'observe_text' : 'observe_body',
        nativePinMatches: mutation !== 'native_pin', canonicalMatches: mutation !== 'content',
        rootSame: mutation !== 'whole_root', bodySame: mutation !== 'whole_root' && mutation !== 'body_only',
        oldRootConnected: mutation !== 'whole_root', oldBodyConnected: mutation !== 'whole_root' && mutation !== 'body_only',
        currentRootConnected: true, currentBodyConnected: true });
      const encoded = JSON.stringify(diagnostic);
      expect(encoded.length).toBeLessThanOrEqual(2_048);
      for (const privateValue of ['PRIVATE_FIRST_CANARY', 'PRIVATE_SECOND_CANARY', second.fingerprint, second.marker, x.f.document.URL])
        expect(encoded).not.toContain(privateValue);
      expect(rejected).not.toHaveProperty('submissionProof'); expect(rejected).not.toHaveProperty('answerComplete', true);
      expect(state.revoked).toBe(true); expect(x.send.clicks).toBe(2);
    }
  });

  test('first pending context refusal distinguishes absent physical binding from a remount without another Send', async () => {
    const x = await chatTurnFixture(); const first = await x.dispatch('PRIVATE_UNBOUND_CONTEXT_CANARY');
    const state: any = x.f.world.__computaChatSubmissionState, record = state.pending;
    expect(record.root).toBeNull(); expect(record.body).toBeNull(); expect(record.phase).toBe('send_claimed');
    expect(state.lastVerified).toBeNull();
    const root = x.f.document.querySelectorAll('article[data-turn="user"]')[0], body = root.children[0];
    state.revoked = true;
    const rejected = await x.observe(first);
    expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    expect(rejected.submissionDiagnostic).toMatchObject({ stage: 'observe_context', pendingRecord: true, lastVerifiedRecord: false,
      recordPhase: 'send_claimed', oldRootPresent: false, oldBodyPresent: false, rootSame: false, bodySame: false,
      oldRootConnected: false, oldBodyConnected: false, currentRootConnected: true, currentBodyConnected: true,
      nativePinMatches: true, canonicalMatches: true,
      contextChecks: { invocationClaimed: true, invocationCurrent: true, statePresent: true, stateNotRevoked: false,
        stateDocumentMatches: null, productProofVerified: null, temporaryVerified: null, modelChoiceMatches: null } });
    expect(record.root).toBeNull(); expect(record.body).toBeNull(); expect(state.lastVerified).toBeNull();
    expect(x.f.document.querySelectorAll('article[data-turn="user"]')[0]).toBe(root); expect(root.children[0]).toBe(body);
    expect(rejected).not.toHaveProperty('submissionProof'); expect(rejected).not.toHaveProperty('answerComplete', true);
    const encoded = JSON.stringify(rejected.submissionDiagnostic);
    for (const privateValue of ['PRIVATE_UNBOUND_CONTEXT_CANARY', first.marker, first.fingerprint, x.f.document.URL]) expect(encoded).not.toContain(privateValue);
    expect(x.send.clicks).toBe(1);
  });

  test('context observation preserves operand order short circuiting and product getter call count', () => {
    const start = source.indexOf('const chatGPTSubmissionContextCheckKeys =');
    const end = source.indexOf('function chatGPTInitialSubmissionRoute(state)', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const run = new Function('env', `
      const { document, window, location, input, globalThis, lease } = env;
      const websiteChatInvocationLease = lease;
      const chatGPTProductModeProof = () => { env.calls.push('product'); return env.product; };
      const chatGPTTemporaryVerified = () => { env.calls.push('temporary'); return env.temporary; };
      const websiteModelChoiceEqual = () => { env.calls.push('model'); return env.model; };
      const chatGPTInitialSubmissionRoute = () => { env.calls.push('route'); return env.route; };
      ${source.slice(start, end)}
      const result = chatGPTSubmissionContext(env.state, env.initial === true);
      return { result, checks: chatGPTSubmissionContextFailure?.checks ?? null };
    `);
    const make = () => {
      const document = { URL: 'https://chatgpt.com/?temporary-chat=true' }, lease = {}, window: any = {}; window.top = window;
      const state = { document, owner: 'OWNER', revoked: false, firstMarker: 'MARKER', modelChoice: {} };
      const input = { provider: 'chatgpt', ownerToken: 'OWNER', expectedURL: document.URL, expectedFirstUserMarker: 'MARKER', expectedModelChoice: {} };
      return { document, window, location: { origin: 'https://chatgpt.com' }, input, state, lease,
        globalThis: { __computaChatActiveInvocation: lease, __computaChatSubmissionState: state, __computaModelOwner: 'OWNER' },
        calls: [] as string[], product: {}, temporary: true, model: true, route: true, initial: false };
    };
    const healthy = make(); expect(run(healthy)).toEqual({ result: true, checks: null });
    expect(healthy.calls).toEqual(['product', 'temporary', 'model']);
    const revoked = make(); revoked.state.revoked = true;
    Object.defineProperty(revoked.state, 'document', { get() { throw new Error('PRIVATE_UNREACHED_GETTER'); } });
    const refused = run(revoked); expect(refused.result).toBe(false);
    expect(refused.checks).toMatchObject({ stateNotRevoked: false, stateDocumentMatches: null, productProofVerified: null, modelChoiceMatches: null });
    expect(revoked.calls).toEqual([]);
    const product = make(); product.product = null as any;
    expect(run(product).checks).toMatchObject({ productProofVerified: false, temporaryVerified: null, modelChoiceMatches: null });
    expect(product.calls).toEqual(['product']);
    const temporary = make(); temporary.temporary = false;
    expect(run(temporary).checks).toMatchObject({ productProofVerified: true, temporaryVerified: false, modelChoiceMatches: null });
    expect(temporary.calls).toEqual(['product', 'temporary']);
    const model = make(); model.model = false;
    expect(run(model).checks).toMatchObject({ productProofVerified: true, temporaryVerified: true, modelChoiceMatches: false });
    expect(model.calls).toEqual(['product', 'temporary', 'model']);
    const route = make(); route.document.URL = 'https://chatgpt.com/c/local-chatgpt%3Afixture'; route.initial = true;
    expect(run(route).result).toBe(true); expect(route.calls).toEqual(['route', 'product', 'temporary', 'model']);
  });

  test('diagnostic capture can fail without changing the original refusal or making another input', async () => {
    const x = await chatTurnFixture(); const first = await x.dispatch('PRIVATE_DIAGNOSTIC_GETTER'); x.answer('First'); await x.observe(first);
    const record: any = (x.f.world.__computaChatSubmissionState as any).lastVerified;
    Object.defineProperty(record, 'body', { get() { throw new Error('PRIVATE_THROW_CANARY'); } });
    const rejected = await x.f.rawRun({ action: 'insert', prompt: 'invalid sequence', expectedUserCounts: [1],
      submissionSequence: 17, submissionMarker: firstMarker, expectedSubmissionProofs: x.proofs });
    expect(rejected).toEqual({ error: 'conversation_changed', detail: 'submission_message' });
    expect(rejected).not.toHaveProperty('submissionDiagnostic'); expect(rejected).not.toHaveProperty('inserted');
    expect(x.send.clicks).toBe(1); expect(x.f.composer.text).toBe('');
  });

  test('native uppercase first nonce is retained byte-for-byte while malformed and replaced nonces reject', async () => {
    const uppercase = firstMarker.toUpperCase();
    const x = await chatTurnFixture(undefined, uppercase);
    const record = await x.dispatch('Exact native uppercase request');
    x.answer('Uppercase body verified');
    const verified = await x.observe(record);
    expect(verified.error).toBeUndefined();
    expect(verified.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    expect(verified.firstUserFingerprint).toBe(record.fingerprint);
    expect(record.outbound.endsWith('Computa session marker: ' + uppercase)).toBe(true);
    const state: any = x.f.world.__computaChatSubmissionState;
    expect(state.firstMarker).toBe(uppercase); expect(state.lastVerified.marker).toBe(uppercase);
    expect(state.lastVerified.canonical).toBe(record.outbound);
    const replaced = await x.observe(record, { expectedFirstUserMarker: uppercase.toLowerCase() });
    expect(replaced.error).toBeDefined(); expect(replaced).not.toHaveProperty('submissionProof');
    expect(x.send.clicks).toBe(1);

    for (const marker of [uppercase.replace('B', 'G'), uppercase.slice(1), uppercase + '0']) {
      const bad = await chatTurnFixture(undefined, uppercase);
      const outbound = 'Exact input\n\nComputa session marker: ' + marker;
      const rejected = await bad.f.rawRun({ action: 'insert', prompt: outbound, expectedUserCounts: [0],
        expectedFirstUserMarker: uppercase, submissionSequence: 1, submissionMarker: marker, expectedSubmissionProofs: [] });
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      expect(rejected).not.toHaveProperty('inserted'); expect(bad.send.clicks).toBe(0); expect(bad.f.composer.text).toBe('');
    }

    const beforeSend = await chatTurnFixture(undefined, uppercase);
    const outbound = 'Exact pending input\n\nComputa session marker: ' + uppercase;
    const fingerprint = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(outbound)))].map(b => b.toString(16).padStart(2, '0')).join('');
    const input = { prompt: outbound, expectedUserCounts: [0], expectedFirstUserMarker: uppercase,
      submissionSequence: 1, submissionMarker: uppercase, expectedSubmissionProofs: [] };
    const inserted = await beforeSend.f.rawRun({ ...input, action: 'insert' });
    expect(inserted.inserted).toBe(true);
    const replacedAtClaim = await beforeSend.f.rawRun({ ...input, action: 'submit', submissionMarker: uppercase.toLowerCase(),
      expectedSubmissionProofs: [{ sequence: 1, fingerprint }] });
    expect(replacedAtClaim).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    expect(replacedAtClaim).not.toHaveProperty('submitted'); expect(beforeSend.send.clicks).toBe(0);
  });

  test('seven rounds retain exact outbound fingerprints and suppress the previous answer', async () => {
    const x = await chatTurnFixture();
    for (let i = 0; i < 7; i++) {
      const record = await x.dispatch(`Complete request ${i}: {"input":["literal .:/- ${i}"],"tools":[]}`);
      const beforeAnswer = await x.observe(record);
      expect(beforeAnswer.error).toBeUndefined(); expect(beforeAnswer.submissionProof).toEqual({ sequence: i + 1, fingerprint: record.fingerprint });
      expect(beforeAnswer.text).toBe(''); expect(beforeAnswer.answerComplete).toBe(false);
      x.answer(`Round ${i} complete`);
      const complete = await x.observe(record);
      expect(complete.error).toBeUndefined(); expect(complete.answerComplete).toBe(true);
      expect(complete.submissionProof).toEqual({ sequence: i + 1, fingerprint: record.fingerprint });
      expect(complete.firstUserFingerprint).toBe(x.records[0].fingerprint);
      expect(complete.text).toContain(`Round ${i} complete`);
    }
    expect(x.send.clicks).toBe(7); expect(new Set(x.records.map(r => r.marker)).size).toBe(7);
  });

  test('changed current or prior bodies and physical replacements cannot yield another response', async () => {
    for (const mutation of ['current', 'prior', 'body', 'root', 'ordinal', 'native_pin', 'model', 'owner', 'route']) {
      const x = await chatTurnFixture(); const first = await x.dispatch('Exact first request'); x.answer('First'); await x.observe(first);
      const second = await x.dispatch('Exact second request'); x.answer('Second');
      const roots = x.f.document.querySelectorAll('article[data-turn="user"]');
      if (mutation === 'current') roots[1].children[0].text += ' changed';
      if (mutation === 'prior') roots[0].children[0].text += ' changed';
      if (mutation === 'body') { const old = roots[1].children[0]; old.connected = false;
        const replacement = new Element('DIV', { class: 'whitespace-pre-wrap' }, second.outbound);
        roots[1].children = [replacement]; replacement.parentElement = roots[1];
        // First bind, then replacing the certified body is refused below.
        old.connected = true; roots[1].children = [old]; await x.observe(second);
        old.connected = false; roots[1].children = [replacement]; }
      if (mutation === 'root') { await x.observe(second); const old = roots[1]; old.connected = false;
        const replacement = new Element('ARTICLE', { 'data-turn': 'user' }); replacement.append(new Element('DIV', { class: 'whitespace-pre-wrap' }, second.outbound));
        x.f.messages.children = x.f.messages.children.map(node => node === old ? replacement : node); replacement.parentElement = x.f.messages; }
      if (mutation === 'owner') x.f.world.__computaModelOwner = 'foreign';
      if (mutation === 'route') x.f.document.URL = 'https://chatgpt.com/c/other';
      const overrides: any = mutation === 'ordinal' ? { submissionSequence: 1 } : mutation === 'native_pin'
        ? { expectedSubmissionProofs: [{ sequence: 1, fingerprint: first.fingerprint }, { sequence: 2, fingerprint: '0'.repeat(64) }] }
        : mutation === 'model' ? { expectedModelChoice: { provider: 'chatgpt', key: 'foreign', label: 'Foreign' } }
        : mutation === 'route' ? { expectedURL: 'https://chatgpt.com/' } : {};
      const rejected = await x.observe(second, overrides);
      expect(rejected.error).toBeDefined(); expect(rejected).not.toHaveProperty('submissionProof');
      expect(rejected).not.toHaveProperty('answerComplete', true); expect(x.send.clicks).toBe(2);
    }
  });

  test('body, ordinal and owner changes during the digest revoke proof without another Send', async () => {
    for (const mutation of ['body', 'append', 'owner']) {
      const x = await chatTurnFixture(); const record = await x.dispatch('Exact pending request');
      x.f.onDigest(() => { if (mutation === 'body') x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0].text += '!';
        if (mutation === 'append') x.f.appendUser('Unowned extra body'); if (mutation === 'owner') x.f.world.__computaModelOwner = 'foreign'; });
      const rejected = await x.observe(record); expect(rejected.error).toBeDefined(); expect(rejected).not.toHaveProperty('submissionProof');
      expect(x.send.clicks).toBe(1);
    }
  });

  test('a replacement readonly invocation owns proof while a timed-out digest cannot revoke or bind', async () => {
    const x = await chatTurnFixture(); const first = await x.dispatch('Exact first'); x.answer('First'); await x.observe(first);
    const second = await x.dispatch('Exact second'); x.answer('Second');
    let release!: () => void, entered!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const enteredGate = new Promise<void>(resolve => { entered = resolve; });
    x.f.onDigest(async () => { entered(); await gate; }, second.outbound);
    const staleRead = x.observe(second); await enteredGate;
    const fresh = await x.observe(second);
    expect(fresh.submissionProof).toEqual({ sequence: 2, fingerprint: second.fingerprint });
    const state: any = x.f.world.__computaChatSubmissionState;
    expect(state.pending).toBeNull(); expect(state.revoked).toBe(false);
    release();
    const stale = await staleRead;
    expect(stale.error).toBe('document_changed'); expect(stale).not.toHaveProperty('submissionProof');
    expect(state.revoked).toBe(false); expect(state.lastVerified.sequence).toBe(2);
    expect((await x.observe(second)).submissionProof).toEqual({ sequence: 2, fingerprint: second.fingerprint });
    expect(x.send.clicks).toBe(2);
  });

  test('later expansion uses only the sole current message ancestor and still requires exact whole bytes', async () => {
    for (const altered of [false, true]) {
      const x = await chatTurnFixture({ key: 'chat/latest/medium', label: 'Medium' });
      const first = await x.dispatch('Exact first request'); x.answer('First'); await x.observe(first);
      const second = await x.dispatch('Complete second request ' + 'A'.repeat(160));
      const root = x.f.document.querySelectorAll('article[data-turn="user"]')[1], body = root.children[0];
      body.text = second.outbound.slice(0, 30);
      const wrapper = new Element('DIV'); x.f.messages.children = x.f.messages.children.map(node => node === root ? wrapper : node);
      wrapper.parentElement = x.f.messages; root.parentElement = wrapper; wrapper.children = [root];
      const more = new Element('BUTTON', { 'aria-label': 'Show more' }, 'Show more');
      more.onClick = () => { body.text = second.outbound + (altered ? '!' : ''); };
      wrapper.append(more); x.answer('Second');
      const result = await x.observe(second, { allowSubmissionExpansion: true });
      if (altered) { expect(result.error).toBeDefined(); expect(result).not.toHaveProperty('submissionProof'); }
      else { expect(result.error).toBeUndefined(); expect(result.submissionProof).toEqual({ sequence: 2, fingerprint: second.fingerprint }); }
      expect(more.clicks).toBe(1); expect(x.send.clicks).toBe(2);
    }
  });

  test('missing private round state cannot downgrade dispatched native pins to a legacy answer', async () => {
    for (const malformed of [false, true]) {
      const x = await chatTurnFixture(); const record = await x.dispatch('Exact owned request'); x.answer('Observed final'); await x.observe(record);
      delete x.f.world.__computaChatSubmissionState;
      const rejected = await x.observe(record, malformed ? { expectedSubmissionProofs: { sequence: 1 } } : {});
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      expect(rejected).not.toHaveProperty('submissionProof'); expect(rejected).not.toHaveProperty('text'); expect(x.send.clicks).toBe(1);
    }
  });

  test('pending absence and duplicate claimed submissions never publish an answer or replay Send', async () => {
    const x = await chatTurnFixture(); x.addBody(false); const record = await x.dispatch('Exact body not yet rendered');
    const pending = await x.observe(record, { expectedUserCounts: [0, 1] });
    expect(pending.error).toBeUndefined(); expect(pending.submissionPending).toBe(true);
    expect(pending.text).toBe(''); expect(pending.answerComplete).toBe(false); expect(pending).not.toHaveProperty('submissionProof');
    x.f.composer.text = record.outbound;
    const replay = await x.f.rawRun({ action: 'submit', prompt: record.outbound, expectedUserCounts: [0], ...x.values(record) });
    expect(replay.error).toBeDefined(); expect(x.send.clicks).toBe(1);
  });
});

describe('ChatGPT literal DOM failure diagnostics', () => {
  const fields = ['literalDOMFailureNodeKind', 'literalDOMFailureTag', 'literalDOMFailureParentTag', 'literalDOMFailureRule'];
  const text = (data: any) => ({ nodeType: 3, data, parentElement: null });
  const element = (tag: string, children: any[] = [], values: Record<string, string> = {}) => {
    const node = new Element(tag, values);
    node.children = children.filter(child => child.nodeType === 1);
    children.forEach(child => { child.parentElement = node; });
    Object.defineProperty(node, 'childNodes', { get: () => children });
    return node;
  };
  const rejected = async (children: (prompt: string) => any[], configurePhysical?: (body: Element) => void) => {
    const f = fixture({ userPrompt: 'Synthetic owned prompt' });
    f.composer.focus = () => { f.document.activeElement = f.composer; };
    const picker = installObservedModelPicker(f, 'chatgpt', Element);
    expect((await f.inspect({ allowFirstUserBinding: false })).error).toBe('conversation_changed');
    const prefix = 'PRIVATE_DIAGNOSTIC_CANARY\n' + 'x'.repeat(11_000) + '\nCOMPLETE_RESPONSES_REQUEST_JSON:\n';
    const suffix = '\nEND_COMPLETE_RESPONSES_REQUEST_JSON.\n\n' + markerLine;
    const prompt = prefix + '{"tools":[]}' + suffix, rendered = prefix + '{"tools":{]}' + suffix;
    f.world.__computaModelFirstPrompt = prompt; f.world.__computaModelLastSubmissionCount = 0;
    f.userBody!.text = prompt.slice(0, 10_240);
    const expand = new Element('BUTTON', { 'aria-label': 'Show more' }), send = new Element('BUTTON', { 'aria-label': 'Send' });
    f.userBody!.parentElement!.append(expand); f.body.append(send);
    expand.onClick = () => {
      const nodes = children(prompt);
      nodes.forEach(node => { node.parentElement = f.userBody; });
      f.userBody!.children = nodes.filter(node => node.nodeType === 1);
      Object.defineProperty(f.userBody, 'childNodes', { get: () => nodes });
      Object.defineProperty(f.userBody, 'innerText', { get: () => rendered });
      configurePhysical?.(f.userBody!);
    };
    const result = await f.inspect({ allowFirstUserExpansion: true,
      firstUserExpansionModelChoice: { key: 'chat/latest/medium', label: 'Medium' } });
    expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1);
    expect(send.clicks).toBe(0); expect(f.composer.events).toHaveLength(0);
    expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    expect(result.debugStructure).not.toContain('PRIVATE_DIAGNOSTIC_CANARY');
    expect(result.debugStructure).not.toContain(firstMarker);
    return JSON.parse(result.debugStructure);
  };

  test('first unsupported child exposes only finite node and rule facts while ownership still rejects', async () => {
    for (const [build, kind, tag, parent, rule] of [
      [() => [{ nodeType: 8, data: 'PRIVATE_DIAGNOSTIC_CANARY' }], 'comment', 'none', 'div', 'node_type'],
      [() => [{ nodeType: 7, data: 'PRIVATE_DIAGNOSTIC_CANARY' }], 'other', 'none', 'div', 'node_type'],
      [(prompt: string) => [element('DIV', [element('DIV', [text(prompt)])])], 'element', 'div', 'div', 'nested_div'],
      [(prompt: string) => [element('PRE', [text(prompt)])], 'element', 'pre', 'div', 'tag'],
      [(prompt: string) => [element('CODE', [text(prompt)])], 'element', 'code', 'div', 'tag'],
      [(prompt: string) => [element('PRIVATE_DIAGNOSTIC_CANARY', [text(prompt)])], 'element', 'other', 'div', 'tag'],
      [(prompt: string) => [element('SPAN', [element('P', [text(prompt)])])], 'element', 'p', 'span', 'paragraph_parent'],
    ] as const) {
      const diagnostic = await rejected(build);
      expect(diagnostic).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: 'unsupported_markup',
        literalDOMMatchesPrompt: false, literalDOMMatchesRendered: false, literalDOMLength: 0 });
      expect(Object.fromEntries(fields.map(field => [field, diagnostic[field]]))).toEqual({
        literalDOMFailureNodeKind: kind, literalDOMFailureTag: tag, literalDOMFailureParentTag: parent, literalDOMFailureRule: rule });
      expect(diagnostic.literalDOMNodeCount).toBe(['paragraph_parent', 'nested_div'].includes(rule) ? 3 : 2);
      expect(diagnostic.literalDOMMaxDepth).toBe(['paragraph_parent', 'nested_div'].includes(rule) ? 2 : 1);
    }
  });

  test('a sole immediate DIV diagnoses literal bytes and direct paragraphs while ownership still rejects', async () => {
    const literal = await rejected(prompt => [element('DIV', [text(prompt)])]);
    expect(literal).toMatchObject({ literalDOMAvailable: true, literalDOMUnavailableReason: 'none',
      literalDOMMatchesPrompt: true, literalDOMMatchesRendered: false, literalDOMFrameParsed: true,
      literalDOMPayloadCompared: true, literalDOMParsedJSONEqual: true, literalDOMNodeCount: 3, literalDOMMaxDepth: 2 });
    for (const field of fields) expect(literal[field]).toBeUndefined();
    let rows = 0;
    const paragraphs = await rejected(prompt => {
      const lines = prompt.split('\n'); rows = lines.length;
      return [element('DIV', lines.map(line => element('P', [text(line)])))];
    });
    expect(paragraphs).toMatchObject({ literalDOMAvailable: true, literalDOMMatchesPrompt: true,
      literalDOMMatchesRendered: false, literalDOMFrameParsed: true, literalDOMParsedJSONEqual: true,
      literalDOMNodeCount: 2 + 2 * rows, literalDOMMaxDepth: 3, literalDOMParagraphCount: rows, literalDOMBRCount: 0 });
    const altered = await rejected(prompt => [element('DIV', [text(prompt.replace('{"tools":[]}', '{"tools":{]}'))])]);
    expect(altered).toMatchObject({ literalDOMAvailable: true, literalDOMMatchesPrompt: false,
      literalDOMMatchesRendered: true, literalDOMFrameParsed: false, literalDOMPayloadCompared: false,
      literalDOMParsedJSONEqual: false, literalDOMNodeCount: 3 });
  });

  test('sole-wrapper diagnostics reject siblings deeper wrappers hidden inert and controls without skipping nodes', async () => {
    for (const build of [
      (prompt: string) => [text(' '), element('DIV', [text(prompt)])],
      (prompt: string) => [element('DIV', [text(prompt)]), text(' ')],
      (prompt: string) => [{ nodeType: 8, data: 'PRIVATE_DIAGNOSTIC_CANARY' }, element('DIV', [text(prompt)])],
      (prompt: string) => [element('DIV', [text(prompt)]), { nodeType: 8, data: 'PRIVATE_DIAGNOSTIC_CANARY' }],
      (prompt: string) => [element('DIV', [text(prompt)]), element('DIV')],
      (prompt: string) => [element('DIV', [element('DIV', [text(prompt)])])],
      (prompt: string) => [element('DIV', [element('SPAN', [element('P', [text(prompt)])])])],
    ]) {
      const diagnostic = await rejected(build);
      expect(diagnostic).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: 'unsupported_markup',
        literalDOMMatchesPrompt: false, literalDOMMatchesRendered: false });
      expect(diagnostic.literalDOMNodeCount).toBeGreaterThanOrEqual(2);
    }
    for (const [values, reason] of [[{ hidden: '' }, 'hidden_markup'], [{ inert: '' }, 'inert_markup'],
      [{ role: 'button' }, 'control_markup']] as const) {
      const wrapper = await rejected(prompt => [element('DIV', [text(prompt)], values)]);
      expect(wrapper).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: reason,
        literalDOMNodeCount: 2, literalDOMLength: 0 });
      const physical = await rejected(prompt => [element('DIV', [text(prompt)])], body => Object.assign(body.values, values));
      expect(physical).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: reason,
        literalDOMNodeCount: 1, literalDOMLength: 0 });
      if (reason === 'control_markup') {
        expect(wrapper).toMatchObject({ literalDOMFailureNodeKind: 'element', literalDOMFailureTag: 'div',
          literalDOMFailureParentTag: 'div', literalDOMFailureRule: 'control' });
        expect(physical).toMatchObject({ literalDOMFailureNodeKind: 'element', literalDOMFailureTag: 'div',
          literalDOMFailureParentTag: 'article', literalDOMFailureRule: 'control' });
      } else for (const field of fields) { expect(wrapper[field]).toBeUndefined(); expect(physical[field]).toBeUndefined(); }
    }
    const control = await rejected(prompt => [element('DIV', [element('BUTTON', [text(prompt)])])]);
    expect(control).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: 'control_markup',
      literalDOMNodeCount: 3, literalDOMLength: 0 });
  });

  test('first control exposes only finite node facts and never skips its content or grants ownership', async () => {
    for (const [tag, values, projectedTag] of [
      ['A', { href: 'https://PRIVATE_DIAGNOSTIC_CANARY', role: 'button' }, 'a'],
      ['BUTTON', { title: 'PRIVATE_DIAGNOSTIC_CANARY' }, 'button'],
      ['INPUT', { value: 'PRIVATE_DIAGNOSTIC_CANARY' }, 'input'],
      ['TEXTAREA', { name: 'PRIVATE_DIAGNOSTIC_CANARY' }, 'textarea'],
      ['SELECT', {}, 'other'], ['OPTION', {}, 'other'], ['SUMMARY', {}, 'other'],
      ['SPAN', { role: 'link' }, 'span'], ['SPAN', { role: 'textbox' }, 'span'],
      ['SPAN', { role: 'menuitem' }, 'span'], ['SPAN', { role: 'slider' }, 'span'],
      ['SPAN', { role: 'combobox' }, 'span'], ['SPAN', { contenteditable: 'true' }, 'span'],
    ] as const) {
      const diagnostic = await rejected(prompt => [element('DIV', [element('P', [
        text(prompt.slice(0, 32)), element(tag, [text(prompt.slice(32))], values),
      ])])]);
      expect(diagnostic).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: 'control_markup',
        literalDOMMatchesPrompt: false, literalDOMMatchesRendered: false, literalDOMLength: 32,
        literalDOMNodeCount: 5, literalDOMMaxDepth: 3, literalDOMParagraphCount: 1,
        literalDOMFailureNodeKind: 'element', literalDOMFailureTag: projectedTag,
        literalDOMFailureParentTag: 'p', literalDOMFailureRule: 'control' });
      expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE_DIAGNOSTIC_CANARY');
      expect(JSON.stringify(diagnostic)).not.toContain('https://');
    }
  });

  test('observed inline anchors diagnose literal paragraph text without reading URLs clicking or granting proof', async () => {
    for (const [wrapper, role, altered] of [[false, null, false], [true, null, false], [true, 'link', false], [true, null, true]] as const) {
      let anchor: Element | undefined, hrefReads = 0;
      const diagnostic = await rejected(prompt => {
        const literal = altered ? prompt.replace('{"tools":[]}', '{"tools":{]}') : prompt;
        anchor = element('A', [element('SPAN', [text(literal.slice(32, 64))])],
          { href: 'https://PRIVATE_DIAGNOSTIC_CANARY', ...(role ? { role } : {}) });
        const getAttribute = anchor.getAttribute.bind(anchor);
        anchor.getAttribute = name => { if (name === 'href') hrefReads++; return getAttribute(name); };
        const row = element('P', [text(literal.slice(0, 32)), anchor, text(literal.slice(64))]);
        return wrapper ? [element('DIV', [row])] : [row];
      });
      expect(diagnostic).toMatchObject({ literalDOMAvailable: true, literalDOMUnavailableReason: 'none',
        literalDOMLinkCount: 1, literalDOMParagraphCount: 1,
        literalDOMMatchesPrompt: !altered, literalDOMMatchesRendered: altered,
        literalDOMFrameParsed: !altered, literalDOMParsedJSONEqual: !altered });
      for (const field of fields) expect(diagnostic[field]).toBeUndefined();
      expect(anchor!.clicks).toBe(0); expect(anchor!.events).toHaveLength(0); expect(hrefReads).toBe(0);
      expect(JSON.stringify(diagnostic)).not.toContain('https://');
    }
    let rows = 0;
    const lines = await rejected(prompt => {
      const values = prompt.split('\n'); rows = values.length;
      return [element('DIV', values.map(value => element('P', [element('A', [text(value)])])))];
    });
    expect(lines).toMatchObject({ literalDOMAvailable: true, literalDOMMatchesPrompt: true,
      literalDOMLinkCount: rows, literalDOMParagraphCount: rows, literalDOMBRCount: 0 });
    const hardBreak = await rejected(prompt => {
      const index = prompt.indexOf('\n');
      return [element('P', [element('A', [text(prompt.slice(0, index)), element('BR'), text(prompt.slice(index + 1))])])];
    });
    expect(hardBreak).toMatchObject({ literalDOMAvailable: true, literalDOMMatchesPrompt: true,
      literalDOMLinkCount: 1, literalDOMBRCount: 1 });
  });

  test('inline anchor diagnostics reject hidden inert controls wrong parents and unsupported descendants', async () => {
    for (const [build, reason, links] of [
      [(prompt: string) => [element('P', [element('A', [text(prompt)], { hidden: '' })])], 'hidden_markup', 0],
      [(prompt: string) => [element('P', [element('A', [text(prompt)], { inert: '' })])], 'inert_markup', 0],
      [(prompt: string) => [element('P', [element('A', [text(prompt)], { role: 'button' })])], 'control_markup', 0],
      [(prompt: string) => [element('P', [element('A', [text(prompt)], { contenteditable: 'true' })])], 'control_markup', 0],
      [(prompt: string) => [element('A', [text(prompt)])], 'control_markup', 0],
      [(prompt: string) => [element('P', [element('SPAN', [element('A', [text(prompt)])])])], 'control_markup', 0],
      [(prompt: string) => [element('P', [element('A', [element('A', [text(prompt)])])])], 'control_markup', 1],
      [(prompt: string) => [element('P', [element('A', [element('BUTTON', [text(prompt)])])])], 'control_markup', 1],
      [(prompt: string) => [element('P', [element('A', [element('SPAN', [text(prompt)], { hidden: '' })])])], 'hidden_markup', 1],
      [(prompt: string) => [element('P', [element('A', [element('SPAN', [text(prompt)], { inert: '' })])])], 'inert_markup', 1],
      [(prompt: string) => [element('P', [element('A', [element('DIV', [text(prompt)])])])], 'unsupported_markup', 1],
      [(prompt: string) => [element('P', [element('A', [element('PRE', [text(prompt)])])])], 'unsupported_markup', 1],
    ] as const) {
      const diagnostic = await rejected(build);
      expect(diagnostic).toMatchObject({ literalDOMAvailable: false, literalDOMUnavailableReason: reason,
        literalDOMLinkCount: links, literalDOMMatchesPrompt: false, literalDOMMatchesRendered: false });
    }
  });

  test('finite failure fields are absent for accepted literal diagnostics and non-node rejection rules', async () => {
    for (const [build, reason] of [
      [(prompt: string) => [text(prompt)], 'none'],
      [(prompt: string) => [element('SPAN', [text(prompt)], { hidden: '' })], 'hidden_markup'],
      [(prompt: string) => [element('SPAN', [text(prompt)], { inert: '' })], 'inert_markup'],
      [() => [text(123)], 'read_failure'],
    ] as const) {
      const diagnostic = await rejected(build);
      expect(diagnostic.literalDOMUnavailableReason).toBe(reason);
      expect(diagnostic.literalDOMAvailable).toBe(reason === 'none');
      expect(diagnostic.literalDOMMatchesPrompt).toBe(reason === 'none');
      for (const field of fields) expect(diagnostic[field]).toBeUndefined();
    }
  });
});

describe('ChatGPT resource timing finite diagnostic', () => {
  const ended = (name = 'https://chatgpt.com/backend-api/f/conversation', changes: Record<string, unknown> = {}) => ({
    name, initiatorType: 'fetch', startTime: 101.75, responseEnd: 151.9, duration: 50.15,
    transferSize: 130, encodedBodySize: 100, decodedBodySize: 150, ...changes,
  });
  const sent = async (timing?: any) => {
    const f = fixture({ response: false }); await f.inspect();
    f.window.performance = timing;
    const prompt = 'PRIVATE_TIMING_PROMPT\n\n' + markerLine, send = new Element('BUTTON', { 'aria-label': 'Send prompt' });
    f.body.append(send); f.composer.text = prompt; f.world.__computaModelFirstPrompt = prompt;
    const result = await f.submit(prompt); expect(result.submitted).toBe(true); expect(send.clicks).toBe(1);
    return { f, prompt, send, result };
  };
  test('ended resource observations feature-detect status and publish at Send completion and failure without authority', async () => {
    let now = 100.25, entries: any[] = [], reads = 0;
    const { f, prompt, send, result } = await sent({ now: () => now, getEntriesByType: (kind: string) => { expect(kind).toBe('resource'); reads++; return entries; } });
    expect(result.resourceTimingDiagnostic).toMatchObject({ phase: 'send', sequence: 1, available: true, sendMarkAvailable: true,
      conversationCount: 0, observations: [], absenceInconclusive: true });
    const claim = f.world.__computaChatResourceTimingClaim as any;
    expect(Object.isFrozen(claim)).toBe(true); expect(claim.mark).toBe(100.25);
    now = 200; entries = [ended(undefined, { responseStatus: 200 }), ended('https://chatgpt.com/backend-api/f/conversation/prepare', { initiatorType: 'xmlhttprequest' }),
      ended(undefined, { responseStatus: 0, transferSize: 0, encodedBodySize: 0, decodedBodySize: 0 })];
    f.appendUser(prompt); f.body.querySelector('main')!.append(f.answer.parentElement!);
    const complete = await f.inspect({ expectedUserCounts: [1] });
    expect(complete.firstUserVerified).toBe(true); expect(complete.answerComplete).toBe(true);
    const diagnostic = complete.resourceTimingDiagnostic;
    expect(diagnostic).toMatchObject({ phase: 'completion', sequence: 1, conversationCount: 2, preparationCount: 1,
      scannedCount: 3, scanTruncated: false, observationsTruncated: false, absenceInconclusive: true });
    expect(diagnostic.observations[0]).toEqual({ endpoint: 'conversation', initiator: 'fetch', startOffsetMs: 1, durationMs: 50,
      transferBytes: 130, encodedBodyBytes: 100, decodedBodyBytes: 150, responseStatusAvailable: true, responseStatus: 200 });
    expect(diagnostic.observations[1].responseStatusAvailable).toBe(false); expect(diagnostic.observations[1].responseStatus).toBeNull();
    expect(diagnostic.observations[2].responseStatus).toBe(0); expect(diagnostic.absenceInconclusive).toBe(true);
    const before = { clicks: send.clicks, observers: f.observers.length, timers: f.scheduledDelays.length, reads };
    const failed = await f.diagnose();
    expect(failed.resourceTimingDiagnostic).toEqual({ ...diagnostic, phase: 'failure' });
    expect(failed).not.toHaveProperty('submissionProof'); expect(failed).not.toHaveProperty('firstUserVerified');
    expect(send.clicks).toBe(before.clicks); expect(f.observers.length).toBe(before.observers); expect(f.scheduledDelays.length).toBe(before.timers);
    expect(reads).toBe(before.reads + 1); expect(f.world.__computaChatResourceTimingClaim).toBe(claim);
    for (const secret of ['PRIVATE', firstMarker, 'https:', 'backend-api', 'name', 'upload']) expect(JSON.stringify(failed.resourceTimingDiagnostic)).not.toContain(secret);
  });
  test('unavailable zero incomplete future and fractional premark entries remain inconclusive without a retry', async () => {
    for (const unavailable of [undefined, { now: () => 100.25 }, { getEntriesByType: () => [] }]) {
      const { f, send, result } = await sent(unavailable);
      expect(result.resourceTimingDiagnostic).toMatchObject({ available: false, sendMarkAvailable: false, observations: [], absenceInconclusive: true });
      expect((await f.diagnose()).resourceTimingDiagnostic.available).toBe(false); expect(send.clicks).toBe(1);
    }
    let now = 100.25;
    const entries = [ended(undefined, { startTime: 100.2 }), ended(undefined, { responseEnd: 0 }),
      ended(undefined, { responseEnd: 250 }), ended(undefined, { startTime: 250, responseEnd: 251 }),
      ended(undefined, { transferSize: true }), ended(undefined, { responseStatus: 600 })];
    const { f, send } = await sent({ now: () => now, getEntriesByType: () => entries }); now = 200;
    const diagnostic = (await f.diagnose()).resourceTimingDiagnostic;
    expect(diagnostic).toMatchObject({ available: true, sendMarkAvailable: true, scannedCount: 6,
      conversationCount: 0, preparationCount: 0, observations: [], absenceInconclusive: true });
    expect(send.clicks).toBe(1); expect((await f.submit('different')).error).toBeDefined(); expect(send.clicks).toBe(1);
  });
  test('hostile names and unapproved endpoint aliases never escape finite resource metadata', async () => {
    let now = 100.25;
    const names = ['https://private.example/backend-api/f/conversation', 'https://chatgpt.com.evil.invalid/backend-api/f/conversation',
      'https://PRIVATE_USER@chatgpt.com/backend-api/f/conversation', 'https://chatgpt.com/backend-api/conversation',
      'https://chatgpt.com/backend-api/f/conversation/', 'https://chatgpt.com/backend-api/f/conversation/other',
      'PRIVATE_NOT_A_URL', 'https://chatgpt.com/backend-api/f/conversation?PRIVATE_QUERY#PRIVATE_FRAGMENT'];
    const { f, send } = await sent({ now: () => now, getEntriesByType: () => names.map(name => ended(name)) }); now = 200;
    const diagnostic = (await f.diagnose()).resourceTimingDiagnostic;
    expect(diagnostic.conversationCount).toBe(1); expect(diagnostic.observations).toHaveLength(1);
    for (const secret of ['PRIVATE', 'http', 'backend-api', 'name', 'url', 'header', 'body']) expect(JSON.stringify(diagnostic)).not.toContain(secret);
    expect(send.clicks).toBe(1);
  });
  test('resource metadata cannot follow foreign owner document claim sequence or crossed native contexts', async () => {
    let now = 100.25; const { f, send } = await sent({ now: () => now, getEntriesByType: () => [ended()] }); now = 200;
    const claim = f.world.__computaChatResourceTimingClaim as any;
    for (const delta of [{ owner: 'PRIVATE_OWNER' }, { document: {} }, { userCount: 1 }, { sequence: 2 }, { sequence: true }]) {
      f.world.__computaChatResourceTimingClaim = { ...claim, ...delta };
      expect((await f.diagnose()).resourceTimingDiagnostic).toBeUndefined(); expect(send.clicks).toBe(1);
    }
    f.world.__computaChatResourceTimingClaim = claim;
    for (const overrides of [{ ownerToken: 'PRIVATE_OWNER' }, { expectedURL: 'https://chatgpt.com/c/PRIVATE' }, { provider: 'gemini' }]) {
      const result = await f.diagnose(overrides); expect(result.error).toBe('document_changed'); expect(result.resourceTimingDiagnostic).toBeUndefined();
    }
    expect(send.clicks).toBe(1);
  });
  test('scan observation and response-byte caps remain finite without touching performance buffers', async () => {
    let now = 100.25; const entries = Array.from({ length: 300 }, (_, index) => ended(undefined,
      { startTime: 101.75 + index, responseEnd: 151.9 + index, transferSize: 2_147_483_647 }));
    const timing = { now: () => now, getEntriesByType: () => entries,
      clearResourceTimings: () => { throw new Error('Must not clear'); }, setResourceTimingBufferSize: () => { throw new Error('Must not resize'); } };
    const { f, send } = await sent(timing); now = 1_000;
    const diagnostic = (await f.diagnose()).resourceTimingDiagnostic;
    expect(diagnostic).toMatchObject({ scannedCount: 256, scanTruncated: true, conversationCount: 256,
      preparationCount: 0, observationsTruncated: true, absenceInconclusive: true });
    expect(diagnostic.observations).toHaveLength(4); expect(diagnostic.observations[3].startOffsetMs).toBe(300);
    expect(JSON.stringify(diagnostic).length).toBeLessThanOrEqual(2_048); expect(entries).toHaveLength(300); expect(send.clicks).toBe(1);
  });
});

describe('ChatGPT failed-page finite diagnostic', () => {
  test('outbound size counts are claimed once at Send and remain finite without prompt content', async () => {
    for (const text of ['PRIVATE_SIZE_CANARY😀é\uD800', 'é'.repeat(100_000)]) {
      const f = fixture({ response: false }); await f.inspect();
      expect((await f.diagnose()).failureDiagnostic).toMatchObject({ outboundUTF16Count: null, outboundUTF8Count: null });
      const prompt = text + '\n\n' + markerLine, send = new Element('BUTTON', { 'aria-label': 'Send prompt' });
      f.body.append(send); f.composer.text = prompt; f.world.__computaModelFirstPrompt = prompt;
      expect(await f.submit(prompt)).toMatchObject({ submitted: true, firstUserVerified: false, firstUserFingerprint: null });
      expect(send.clicks).toBe(1);
      const size = f.world.__computaChatSubmissionSize as any;
      expect(Object.isFrozen(size)).toBe(true);
      expect(Object.keys(size).sort()).toEqual(['document', 'owner', 'userCount', 'utf16Count', 'utf8Count']);
      const before = { observers: f.observers.length, timers: f.scheduledDelays.length, events: f.composer.events.length };
      const diagnostic = (await f.diagnose()).failureDiagnostic;
      expect(diagnostic.outboundUTF16Count).toBe(prompt.length);
      expect(diagnostic.outboundUTF8Count).toBe(new TextEncoder().encode(prompt).length);
      expect(diagnostic.outboundUTF8Count).toBeGreaterThan(diagnostic.outboundUTF16Count);
      expect(diagnostic).not.toHaveProperty('submissionProof'); expect(diagnostic).not.toHaveProperty('firstUserVerified');
      expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE_SIZE'); expect(JSON.stringify(diagnostic)).not.toContain(firstMarker);
      expect(f.observers.length).toBe(before.observers); expect(f.scheduledDelays.length).toBe(before.timers);
      expect(f.composer.events.length).toBe(before.events); expect(send.clicks).toBe(1);
      expect((await f.submit(prompt)).error).toBe('conversation_changed');
      expect(send.clicks).toBe(1); expect(f.world.__computaChatSubmissionSize).toBe(size);
    }
  });
  test('outbound size diagnostics cannot follow foreign document owner claim or malformed counts', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const prompt = 'PRIVATE_SIZE_CANARY\n\n' + markerLine, send = new Element('BUTTON', { 'aria-label': 'Send prompt' });
    f.body.append(send); f.composer.text = prompt; f.world.__computaModelFirstPrompt = prompt;
    expect(await f.submit(prompt)).toMatchObject({ submitted: true, firstUserVerified: false, firstUserFingerprint: null });
    const measured = f.world.__computaChatSubmissionSize as any;
    for (const changes of [{ document: {} }, { owner: 'PRIVATE_OWNER' }, { userCount: 1 },
      { utf16Count: true }, { utf16Count: -1 }, { utf16Count: 180_201 }, { utf8Count: 0 },
      { utf8Count: 720_801 }, { utf8Count: measured.utf16Count * 3 + 1 }, { utf8Count: 1.5 }]) {
      f.world.__computaChatSubmissionSize = { ...measured, ...changes };
      const diagnostic = (await f.diagnose()).failureDiagnostic;
      expect(diagnostic).toMatchObject({ outboundUTF16Count: null, outboundUTF8Count: null });
      expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE_'); expect(send.clicks).toBe(1);
    }
    f.world.__computaChatSubmissionSize = measured;
    expect((await f.diagnose()).failureDiagnostic.outboundUTF16Count).toBe(prompt.length);
  });
  test('reads owned root counts and controls without rehashing, menus or page actions', async () => {
    const f = fixture({ userPrompt: 'PRIVATE_PROMPT_CANARY' });
    await f.inspect();
    f.onDigest(() => { throw new Error('A diagnostic cannot hash a message'); });
    f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false';
    f.userBody!.text = 'REPLACED_PRIVATE_PROMPT';
    const buttons = f.body.querySelectorAll('button');
    const productProofBefore = { ...(f.world.__computaChatProductMode as any) };
    const clicks = buttons.map(button => button.clicks), events = buttons.map(button => button.events.length);
    const timers = f.scheduledDelays.length, observerCount = f.observers.length;
    const result = await f.diagnose({ expectedModelChoice: { key: 'chat/latest/high', label: 'High' }, expectedFirstUserFingerprint: 'invalid' });
    expect(result.error).toBeUndefined();
    expect(result.failureDiagnostic).toEqual({ kind: 'chatgpt_failed_page_v1', route: 'root', errorCategory: 'none',
      outboundUTF16Count: null, outboundUTF8Count: null,
      responseNoticeDiagnostic: { kind: 'chatgpt_response_notice_v1', retryCount: 0, observationsTruncated: false, observations: [] },
      modernUsers: { connected: 0, visible: 0 }, legacyUsers: { connected: 1, visible: 1 },
      modernAssistants: { connected: 1, visible: 1 }, legacyAssistants: { connected: 1, visible: 1 },
      stopPresent: false, composerPresent: true, composerEnabled: true, copyPresent: true, copyEnabled: true,
      retryPresent: false, retryInsideUserMessage: false, retryInsideAssistantMessage: false,
      retryInsideCodeOrEditor: false, retryInsideMenuOrNavigation: false, retryOutsideExcludedContent: false,
      temporaryRendered: true, temporaryVerified: false, alertCount: 0, statusCount: 0,
      alertTextLengths: [], statusTextLengths: [], noticesTruncated: false });
    expect(buttons.map(button => button.clicks)).toEqual(clicks); expect(buttons.map(button => button.events.length)).toEqual(events);
    expect(f.scheduledDelays.length).toBe(timers); expect(f.observers.length).toBe(observerCount);
    expect(f.world.__computaChatProductMode).toEqual(productProofBefore);
    const serialized = JSON.stringify(result);
    for (const secret of ['PRIVATE_PROMPT', 'REPLACED_PRIVATE_PROMPT', 'OK', 'https', 'temporary-chat', 'invalid']) expect(serialized.includes(secret)).toBe(false);
  });
  test('reports only scoped Load failed or unknown notice lengths, never notice text', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const main = f.body.querySelector('main')!, error = new Element('DIV', { role: 'alert' });
    const retry = new Element('BUTTON', {}, 'Retry'); error.append(new Element('SPAN', {}, 'Load failed'), retry); main.append(error);
    const status = new Element('DIV', { role: 'status' }, 'PRIVATE_STATUS_URL_https://private.example/token'); main.append(status);
    let observed = (await f.diagnose()).failureDiagnostic;
    expect(observed.errorCategory).toBe('load_failed'); expect(observed.alertCount).toBe(1); expect(observed.statusCount).toBe(1);
    expect(observed.alertTextLengths).toEqual([16]); expect(observed.statusTextLengths).toEqual([status.textContent.length]);
    expect(observed.retryPresent).toBe(true); expect(observed.retryOutsideExcludedContent).toBe(true);
    expect(retry.clicks).toBe(0); expect(JSON.stringify(observed).includes('PRIVATE_STATUS')).toBe(false);
    retry.text = 'Not Retry'; observed = (await f.diagnose()).failureDiagnostic;
    expect(observed.errorCategory).toBe('unrecognized_notice'); expect(retry.clicks).toBe(0);
    for (let index = 0; index < 9; index++) main.append(new Element('DIV', { role: 'status' }, 'PRIVATE_' + index));
    observed = (await f.diagnose()).failureDiagnostic;
    expect(observed.statusCount).toBe(10); expect(observed.statusTextLengths.length).toBe(8); expect(observed.noticesTruncated).toBe(true);
  });
  test('excludes quoted errors, hidden roots and foreign controls from error and completion evidence', async () => {
    const f = fixture({ userPrompt: 'PRIVATE_USER_CONTENT' }); await f.inspect();
    const quote = () => { const node = new Element('DIV', { role: 'alert' }); node.append(new Element('SPAN', {}, 'Load failed'), new Element('BUTTON', {}, 'Retry')); return node; };
    f.userBody!.append(quote()); f.answer.append(quote()); f.composer.append(quote());
    const codeQuote = new Element('PRE'); codeQuote.append(quote()); f.body.querySelector('main')!.append(codeQuote);
    const menu = new Element('DIV', { role: 'menu' }); menu.append(quote()); f.body.querySelector('main')!.append(menu);
    const sidebar = new Element('ASIDE'); sidebar.append(quote()); f.body.append(sidebar);
    const hidden = new Element('ARTICLE', { 'data-turn': 'assistant', hidden: '' });
    hidden.append(new Element('DIV', { 'data-markdown-text-style': 'assistant-message' }, 'PRIVATE_HIDDEN_REPLY'));
    f.body.querySelector('main')!.append(hidden);
    const detached = new Element('ARTICLE', { 'data-turn': 'assistant' }); detached.connected = false; f.body.querySelector('main')!.append(detached);
    f.body.querySelector('.turn-action-controls button[aria-label="Copy"]')!.disabled = true;
    f.body.append(new Element('BUTTON', { 'aria-label': 'Copy' }));
    const observed = (await f.diagnose()).failureDiagnostic;
    expect(observed.errorCategory).toBe('none'); expect(observed.alertCount).toBe(0);
    expect(observed.retryPresent).toBe(true); expect(observed.retryInsideUserMessage).toBe(true);
    expect(observed.retryInsideAssistantMessage).toBe(true); expect(observed.retryInsideCodeOrEditor).toBe(true);
    expect(observed.retryInsideMenuOrNavigation).toBe(true); expect(observed.retryOutsideExcludedContent).toBe(false);
    expect(observed.modernAssistants).toEqual({ connected: 2, visible: 1 });
    expect(observed.legacyAssistants).toEqual({ connected: 2, visible: 1 });
    expect(observed.copyPresent).toBe(true); expect(observed.copyEnabled).toBe(false);
    expect(JSON.stringify(observed).includes('PRIVATE_')).toBe(false);
  });
  test('classifies routes and sign-in without emitting identifiers, queries or body text', async () => {
    const f = fixture({ response: false }); await f.inspect();
    for (const [path, route] of [['/', 'root'], ['/c/local-chatgpt%3APRIVATE-ID', 'local_conversation'],
      ['/c/PRIVATE-ID', 'server_conversation'], ['/other/PRIVATE-ID', 'other']]) {
      f.document.URL = 'https://chatgpt.com' + path + '?private=SECRET_QUERY';
      const observed = (await f.diagnose()).failureDiagnostic;
      expect(observed.route).toBe(route); expect(JSON.stringify(observed).includes('PRIVATE-ID')).toBe(false);
      expect(JSON.stringify(observed).includes('SECRET_QUERY')).toBe(false);
    }
    f.composer.values.hidden = ''; f.body.append(new Element('BUTTON', {}, 'Sign in'));
    const observed = (await f.diagnose()).failureDiagnostic;
    expect(observed.composerPresent).toBe(false); expect(observed.composerEnabled).toBe(false); expect(observed.errorCategory).toBe('sign_in_required');
  });
  test('fails closed for unowned, crossed-document, wrong-origin and child-frame contexts', async () => {
    const f = fixture({ response: false });
    expect((await f.diagnose()).error).toBe('document_changed');
    await f.inspect();
    for (const overrides of [{ ownerToken: 'FOREIGN' }, { ownerToken: undefined }, { expectedURL: 'https://chatgpt.com/c/FOREIGN' }, { bindOwner: true }, { provider: 'gemini' }]) {
      const observed = await f.diagnose(overrides); expect(observed.error).toBe('document_changed'); expect(observed.failureDiagnostic).toBeUndefined();
    }
    delete f.world.__computaModelOwner;
    expect((await f.diagnose({ ownerToken: undefined })).failureDiagnostic).toBeUndefined();
    f.location.origin = 'https://foreign.example'; expect((await f.diagnose()).failureDiagnostic).toBeUndefined();
    f.location.origin = 'https://chatgpt.com'; f.window.top = {}; expect((await f.diagnose()).failureDiagnostic).toBeUndefined();
  });
});

describe('ChatGPT inline DIL renderer failure', () => {
  function rendererError() {
    const portal = new Element('DIV', { class: 'relative PortalBoundary-TFj9W2 Renderer-ojZscX' });
    const root = new Element('DIV', { class: 'DilRenderer-tB76Jj DilResponseRoot-HfQrEh Reveal-k2IWvM' });
    const leaf = new Element('DIV', {}, 'This response couldn’t load');
    root.append(leaf); portal.append(root);
    return { portal, root, leaf };
  }
  function replaceAnswer(f: ReturnType<typeof fixture>, node: Element) {
    f.answer.children.forEach(child => { child.connected = false; child.parentElement = null; });
    f.answer.text = ''; f.answer.children = []; f.answer.append(node);
  }

  test('recognizes the measured inline DIL renderer error before answer acceptance', async () => {
    const f = fixture({ userPrompt: 'Read the fixture and close its tab' }), e = rendererError();
    await f.inspect();
    const temporaryClicks = f.temporary.clicks;
    replaceAnswer(f, e.portal);
    const observed = await f.inspect();
    expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
    expect(observed.text).toBe('This response couldn’t load');
    expect(observed.answerComplete).toBe(true);
    expect(observed.responseLoadFailed).toBe(true);
    expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0);
    expect(f.temporary.clicks).toBe(temporaryClicks); expect(f.composer.events).toEqual([]);
  });

  test('uses component prefix pairs without depending on Copy or the measured hash suffixes', async () => {
    const f = fixture({ userPrompt: 'Observe the current renderer failure' }), e = rendererError();
    e.root.values.class = 'DilRenderer-NewHash DilResponseRoot-OtherHash';
    e.portal.values.class = 'PortalBoundary-NewHash Renderer-OtherHash';
    replaceAnswer(f, e.portal);
    const copy = f.messages.querySelector('button[aria-label="Copy"]')!;
    copy.connected = false;
    const observed = await f.inspect();
    expect(observed.responseLoadFailed).toBe(true); expect(observed.answerComplete).toBe(false);
    expect(observed.text).toBe('This response couldn’t load'); expect(copy.clicks).toBe(0);
    expect(f.composer.events).toEqual([]);
  });

  test('recognizes the exact visible renderer error after a fully empty hidden DIV subtree', async () => {
    for (const bodyIsRoot of [false, true]) for (const layoutKind of ['hidden', 'zero-rect', 'visibility-hidden']) {
      const f = fixture({ userPrompt: 'Classify only the current visible renderer error' }), e = rendererError();
      await f.inspect();
      if (bodyIsRoot) delete f.answer.parentElement!.values['data-turn'];
      const decoration = new Element('DIV', layoutKind === 'hidden' ? { hidden: '' } : {});
      if (layoutKind === 'zero-rect') decoration.zeroRects = true;
      if (layoutKind === 'visibility-hidden') decoration.cssVisibility = 'hidden';
      decoration.append(new Element('DIV'), new Element('DIV'));
      const layout = new Element('DIV'), inner = new Element('DIV');
      replaceAnswer(f, layout); layout.append(inner); inner.append(decoration, e.portal);
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect({ responseLoadFailed: observed.responseLoadFailed, ...observed.completionEvidence.codeStructure.rendererGuard })
        .toMatchObject({ responseLoadFailed: true, reason: 'matched', guardBodyIsExtractedAnswer: true, bodyIsRoot });
      expect(observed.answerComplete).toBe(true); expect(observed.text).toBe('This response couldn’t load');
      expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0);
      expect(f.composer.events).toEqual([]);
    }
  });

  test('never exempts hidden text, controls, message markers or display-contents descendants', async () => {
    const variants = ['text', 'whitespace', 'known-label', 'button', 'link', 'quote', 'markdown', 'role', 'tabindex',
      'editable', 'author', 'turn', 'user-bubble', 'unknown-attribute', 'onclick', 'hidden-component',
      'contents-root', 'contents-child', 'visible-child-text', 'css-before', 'css-after', 'unknown-css'];
    for (const variant of variants) {
      const f = fixture({ userPrompt: 'Preserve hidden-content and status boundaries' }), e = rendererError();
      await f.inspect();
      replaceAnswer(f, e.portal);
      const decoration = new Element('DIV', { hidden: '' }), child = new Element('DIV');
      decoration.append(child); f.answer.children.unshift(decoration); decoration.parentElement = f.answer;
      if (variant === 'text') child.text = 'Hidden author content';
      if (variant === 'whitespace') child.text = '\n ';
      if (variant === 'known-label') child.text = 'This response couldn’t load';
      if (variant === 'button') child.append(new Element('BUTTON'));
      if (variant === 'link') child.append(new Element('A', { href: 'https://example.test/' }));
      if (variant === 'quote') child.append(new Element('BLOCKQUOTE'));
      if (variant === 'markdown') child.values.class = 'markdown';
      if (variant === 'role') child.values.role = 'status';
      if (variant === 'tabindex') child.values.tabindex = '-1';
      if (variant === 'editable') child.values.contenteditable = 'false';
      if (variant === 'author') child.values['data-message-author-role'] = 'tool';
      if (variant === 'turn') child.values['data-turn'] = 'tool';
      if (variant === 'user-bubble') child.values['data-user-message-bubble'] = '';
      if (variant === 'unknown-attribute') child.values['data-unmeasured-content'] = '';
      if (variant === 'onclick') child.values.onclick = 'untrusted()';
      if (variant === 'hidden-component') child.values.class = 'DilRenderer-Other DilResponseRoot-Other';
      if (variant === 'contents-root') decoration.values['data-fixture-display'] = 'contents';
      if (variant === 'contents-child') child.values['data-fixture-display'] = 'contents';
      if (variant === 'visible-child-text') {
        delete decoration.values.hidden; decoration.cssVisibility = 'hidden'; child.cssVisibility = 'visible'; child.text = 'Visible override';
      }
      if (variant === 'css-before') child.beforeContent = '"Generated author text"';
      if (variant === 'css-after') child.afterContent = '"Generated author text"';
      if (variant === 'unknown-css') child.beforeContent = '';
      const observed = await f.inspect(variant === 'user-bubble' ? { expectedUserCounts: [1, 2] } : {});
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false);
      expect(observed.completionEvidence.codeStructure.rendererGuard.rawKnownLabel).toBeNull();
      expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0); expect(f.composer.events).toEqual([]);
    }
  });

  test('counts every hidden descendant against the existing shared renderer limits', async () => {
    for (const variant of ['depth', 'nodes', 'children', 'classes', 'class-length']) {
      const f = fixture({ userPrompt: 'Keep the original classifier work budget' }), e = rendererError();
      replaceAnswer(f, e.portal);
      const decoration = new Element('DIV', { hidden: '' });
      f.answer.children.unshift(decoration); decoration.parentElement = f.answer;
      if (variant === 'depth') {
        let node = decoration;
        for (let i = 0; i < 9; i++) { const child = new Element('DIV'); node.append(child); node = child; }
      }
      if (variant === 'nodes') for (let i = 0; i < 30; i++) {
        const child = new Element('DIV'); child.append(new Element('DIV')); decoration.append(child);
      }
      if (variant === 'children') for (let i = 0; i < 33; i++) decoration.append(new Element('DIV'));
      if (variant === 'classes') decoration.values.class = Array.from({ length: 17 }, (_, i) => `layout${i}`).join(' ');
      if (variant === 'class-length') decoration.values.class = 'x'.repeat(65);
      const observed = await f.inspect();
      expect(observed.responseLoadFailed).toBe(false);
      expect(observed.completionEvidence.codeStructure.rendererGuard.reason).toBe({ depth: 'tree_depth', nodes: 'node_budget',
        children: 'children_budget', classes: 'class_budget', 'class-length': 'class_budget' }[variant]);
      expect(observed.completionEvidence.codeStructure.rendererGuard.visitedNodeCount).toBeLessThanOrEqual(65);
      expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0); expect(f.composer.events).toEqual([]);
    }
  });

  test('projects only finite same-invocation renderer relationships without changing recognition', async () => {
    for (const bodyIsRoot of [false, true]) {
      const f = fixture({ userPrompt: 'Read the current renderer facts' }), e = rendererError();
      replaceAnswer(f, e.portal);
      if (bodyIsRoot) delete f.answer.parentElement!.values['data-turn'];
      const observed = await f.inspect();
      expect(observed.responseLoadFailed).toBe(true);
      const facts = observed.completionEvidence.codeStructure.rendererGuard;
      expect(Object.keys(facts).sort()).toEqual(['reason', 'subject', 'visitedNodeCount', 'rawKnownLabel', 'trimmedKnownLabel',
        'guardBodyIsExtractedAnswer', 'bodyIsRoot', 'knownScopedCopyOutsideDIL', 'rejectedDisplayContents'].sort());
      expect(facts).toMatchObject({ reason: 'matched', subject: 'other', rawKnownLabel: true, trimmedKnownLabel: true,
        guardBodyIsExtractedAnswer: true, bodyIsRoot, knownScopedCopyOutsideDIL: true, rejectedDisplayContents: null });
      expect(facts.visitedNodeCount).toBeGreaterThan(0); expect(facts.visitedNodeCount).toBeLessThanOrEqual(65);
      for (const excluded of ['This response', 'DilRenderer-', 'https:', firstMarker, 'owner', 'document'])
        expect(JSON.stringify(facts)).not.toContain(excluded);
      expect(f.composer.events).toEqual([]);
    }
  });

  test('distinguishes a raw label mismatch from a trimmed known label without accepting it', async () => {
    const f = fixture({ userPrompt: 'Preserve the existing strict label predicate' }), e = rendererError();
    e.leaf.text = ' This response couldn’t load\n'; replaceAnswer(f, e.portal);
    const observed = await f.inspect();
    expect(observed.responseLoadFailed).toBe(false);
    expect(observed.completionEvidence.codeStructure.rendererGuard).toMatchObject({ reason: 'raw_label_differs',
      subject: 'text_leaf', rawKnownLabel: false, trimmedKnownLabel: true, guardBodyIsExtractedAnswer: true,
      bodyIsRoot: false, knownScopedCopyOutsideDIL: true, rejectedDisplayContents: null });
    expect(f.composer.events).toEqual([]);
  });

  test('reports the first layout or boundary decline and leaves unexamined label facts unknown', async () => {
    for (const variant of ['contents', 'hidden', 'no-main']) {
      const f = fixture({ userPrompt: 'Observe the first structural decline' }), e = rendererError();
      replaceAnswer(f, e.portal);
      if (variant === 'contents') e.root.values['data-fixture-display'] = 'contents';
      if (variant === 'hidden') e.root.values.hidden = '';
      if (variant === 'no-main') f.messages.tagName = 'DIV';
      // This later bad label must not replace the first rejected predicate.
      e.leaf.text = 'A later mismatched label';
      const observed = await f.inspect();
      expect(observed.responseLoadFailed).toBe(false);
      const facts = observed.completionEvidence.codeStructure.rendererGuard;
      expect(facts).toMatchObject({ reason: variant === 'no-main' ? 'conversation_boundary_missing' : 'node_not_visible',
        subject: variant === 'no-main' ? 'root' : 'dil_pair', rawKnownLabel: null, trimmedKnownLabel: null,
        rejectedDisplayContents: variant === 'no-main' ? null : variant === 'contents' });
      expect(facts.guardBodyIsExtractedAnswer).toBe(variant === 'no-main' ? null : true);
      expect(facts.knownScopedCopyOutsideDIL).toBeNull(); expect(f.composer.events).toEqual([]);
    }
  });

  test('compares the guard body to the body actually selected by extraction in the same invocation', async () => {
    const f = fixture({ userPrompt: 'Preserve selected-answer identity facts' }), e = rendererError();
    replaceAnswer(f, e.portal);
    const laterRoot = new Element('ARTICLE', { 'data-turn': 'assistant' });
    const hiddenBody = new Element('DIV', { 'data-markdown-text-style': 'assistant-message', hidden: '' }, 'Hidden unrelated answer');
    laterRoot.append(hiddenBody); f.messages.append(laterRoot);
    const observed = await f.inspect();
    expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false);
    expect(observed.text).toBe('This response couldn’t load');
    expect(observed.completionEvidence.codeStructure.rendererGuard).toMatchObject({ reason: 'body_not_visible', subject: 'body',
      guardBodyIsExtractedAnswer: false, bodyIsRoot: false, knownScopedCopyOutsideDIL: null,
      rawKnownLabel: null, trimmedKnownLabel: null, rejectedDisplayContents: false });
    expect(f.composer.events).toEqual([]);
  });

  test('does not classify ordinary prose, markdown, code or quoted renderer text as a website failure', async () => {
    for (const kind of ['plain', 'paragraph', 'markdown', 'blockquote', 'pre', 'code', 'legitimate-sibling']) {
      const f = fixture({ userPrompt: 'Explain the recorded response text' }), e = rendererError();
      if (kind === 'plain') replaceAnswer(f, new Element('DIV', {}, 'This response couldn’t load'));
      else if (kind === 'paragraph') replaceAnswer(f, new Element('P', {}, 'This response couldn’t load'));
      else if (kind === 'legitimate-sibling') {
        replaceAnswer(f, e.portal); f.answer.append(new Element('DIV', {}, 'Quoted renderer status, with an explanation.'));
      } else {
        const wrapper = new Element(kind === 'markdown' ? 'DIV' : kind.toUpperCase(), kind === 'markdown' ? { class: 'markdown' } : {});
        wrapper.append(e.portal); replaceAnswer(f, wrapper);
      }
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false);
      expect(observed.text).toContain('This response couldn’t load'); expect(f.composer.events).toEqual([]);
    }
  });

  test('does not import renderer-shaped user, tool-result, old-answer or outside-body content', async () => {
    for (const kind of ['user', 'tool-result', 'old-answer', 'outside-body']) {
      const prefix = kind === 'tool-result' ? 'Recorded tool output: ' : '';
      const f = fixture({ userPrompt: ['user', 'tool-result'].includes(kind) ? prefix + 'This response couldn’t load' : 'Read the current answer' });
      const e = rendererError();
      if (['user', 'tool-result'].includes(kind)) {
        f.userBody!.text = prefix; f.userBody!.append(e.portal, new Element('SPAN', {}, '\n\n' + markerLine));
      } else if (kind === 'old-answer') {
        const earlier = new Element('ARTICLE', { 'data-turn': 'assistant' });
        const body = new Element('DIV', { 'data-markdown-text-style': 'assistant-message' }); body.append(e.portal); earlier.append(body);
        f.messages.children.unshift(earlier); earlier.parentElement = f.messages;
      } else {
        // The familiar classes above a selected leaf cannot confer renderer
        // provenance on that body. Both component boundaries must be inside it.
        const article = f.answer.parentElement!;
        article.children = article.children.filter(child => child !== f.answer);
        e.root.children = []; e.root.append(f.answer); article.append(e.portal);
        replaceAnswer(f, new Element('DIV', {}, 'This response couldn’t load'));
      }
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false);
      expect(f.composer.events).toEqual([]);
    }
  });

  test('does not classify an assistant-looking renderer nested in a modern user or tool body', async () => {
    for (const boundary of ['modern-user', 'tool']) {
      const f = fixture({ userPrompt: 'Keep user and tool content outside assistant status' }), e = rendererError();
      await f.inspect();
      const container = new Element('DIV', boundary === 'modern-user'
        ? { 'data-markdown-text-style': 'user-message' } : { 'data-message-author-role': 'tool' });
      const counterfeit = new Element('DIV', { 'data-markdown-text-style': 'assistant-message' });
      counterfeit.append(e.portal); container.append(counterfeit); f.messages.append(container);
      // A pending append can legitimately expose either count. The status
      // detector must still exclude the enclosing user/tool provenance.
      const observed = await f.inspect({ expectedUserCounts: [1, 2] });
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect(observed.text).toBe('This response couldn’t load');
      expect(observed.responseLoadFailed).toBe(false); expect(f.composer.events).toEqual([]);
    }
  });

  test('does not classify a selected assistant body with conflicting author or turn markers', async () => {
    for (const attribute of ['data-message-author-role', 'data-turn']) {
      const f = fixture({ userPrompt: 'Reject conflicting body provenance' }), e = rendererError();
      await f.inspect(); replaceAnswer(f, e.portal);
      f.answer.values[attribute] = 'tool';
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect(observed.text).toBe('This response couldn’t load');
      expect(observed.responseLoadFailed).toBe(false); expect(f.composer.events).toEqual([]);
    }
  });

  test('rejects counterfeit, ambiguous, hidden, interactive and over-budget renderer shapes', async () => {
    const variants = ['missing-renderer', 'missing-response-root', 'missing-portal', 'missing-parent-renderer', 'empty-suffix',
      'counterfeit-prefix', 'split-root-pair', 'indirect-root', 'indirect-leaf', 'styled-leaf', 'span-leaf', 'nested-label',
      'different-label', 'padded-label', 'extra-text', 'second-leaf', 'second-root', 'second-portal', 'hidden-leaf', 'hidden-root',
      'hidden-portal', 'detached', 'role', 'tabindex', 'editable', 'button', 'link', 'svg',
      'long-text', 'long-class', 'many-classes', 'many-nodes', 'many-children', 'deep-tree', 'nested-author'];
    for (const variant of variants) {
      const f = fixture({ userPrompt: 'Observe only a proven renderer error' }), e = rendererError();
      replaceAnswer(f, e.portal);
      if (variant === 'missing-renderer') e.root.values.class = 'DilResponseRoot-HfQrEh';
      if (variant === 'missing-response-root') e.root.values.class = 'DilRenderer-tB76Jj';
      if (variant === 'missing-portal') e.portal.values.class = 'Renderer-ojZscX';
      if (variant === 'missing-parent-renderer') e.portal.values.class = 'PortalBoundary-TFj9W2';
      if (variant === 'empty-suffix') e.root.values.class = 'DilRenderer- DilResponseRoot-';
      if (variant === 'counterfeit-prefix') e.root.values.class = 'NotDilRenderer-tB76Jj NotDilResponseRoot-HfQrEh';
      if (variant === 'split-root-pair') { e.root.values.class = 'DilRenderer-tB76Jj'; e.leaf.values.class = 'DilResponseRoot-HfQrEh'; }
      if (variant === 'indirect-root') { const wrapper = new Element('DIV'); e.portal.children = []; wrapper.append(e.root); e.portal.append(wrapper); }
      if (variant === 'indirect-leaf') { const wrapper = new Element('DIV'); e.root.children = []; wrapper.append(e.leaf); e.root.append(wrapper); }
      if (variant === 'styled-leaf') e.leaf.values.class = 'markdown';
      if (variant === 'span-leaf') e.leaf.tagName = 'SPAN';
      if (variant === 'nested-label') { e.leaf.text = ''; e.leaf.append(new Element('SPAN', {}, 'This response couldn’t load')); }
      if (variant === 'different-label') e.leaf.text = "This response couldn't load";
      if (variant === 'padded-label') e.leaf.text = ' This response couldn’t load ';
      if (variant === 'extra-text') e.portal.append(new Element('DIV', {}, 'Additional readable answer'));
      if (variant === 'second-leaf') e.root.append(new Element('DIV', {}, 'This response couldn’t load'));
      if (variant === 'second-root') { const duplicate = rendererError(); duplicate.leaf.text = ''; e.portal.append(duplicate.root); }
      if (variant === 'second-portal') { const duplicate = rendererError(); duplicate.leaf.text = ''; f.answer.append(duplicate.portal); }
      if (variant === 'hidden-leaf') e.leaf.values.hidden = '';
      if (variant === 'hidden-root') e.root.values['aria-hidden'] = 'true';
      if (variant === 'hidden-portal') e.portal.values.inert = '';
      if (variant === 'detached') e.portal.connected = false;
      if (variant === 'role') e.leaf.values.role = 'status';
      if (variant === 'tabindex') e.leaf.values.tabindex = '-1';
      if (variant === 'editable') e.leaf.values.contenteditable = 'false';
      if (variant === 'button') e.portal.append(new Element('BUTTON', {}, 'Retry'));
      if (variant === 'link') e.portal.append(new Element('A', { href: 'https://example.test/' }));
      if (variant === 'svg') e.portal.append(new Element('SVG'));
      if (variant === 'long-text') e.leaf.text += ' '.repeat(129);
      if (variant === 'long-class') e.portal.values.class += ' ' + 'x'.repeat(65);
      if (variant === 'many-classes') e.portal.values.class += ' ' + Array.from({ length: 17 }, (_, i) => `fixture${i}`).join(' ');
      if (variant === 'many-nodes') for (let i = 0; i < 25; i++) { const wrapper = new Element('DIV'); wrapper.append(new Element('DIV'), new Element('DIV')); e.portal.append(wrapper); }
      if (variant === 'many-children') for (let i = 0; i < 33; i++) e.portal.append(new Element('DIV'));
      if (variant === 'deep-tree') { let node = new Element('DIV'); const top = node; for (let i = 0; i < 9; i++) { const child = new Element('DIV'); node.append(child); node = child; } e.portal.append(top); }
      if (variant === 'nested-author') e.leaf.values['data-message-author-role'] = 'assistant';
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false);
      expect(f.composer.events).toEqual([]);
      expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0);
    }
  });

  test('cannot override owned first-message, product or native document-context rejection', async () => {
    for (const drift of ['user', 'work', 'owner', 'url']) {
      const f = fixture({ userPrompt: 'Preserve the owned message' }), e = rendererError();
      await f.inspect(); replaceAnswer(f, e.portal);
      f.onDigest(() => {
        if (drift === 'user') f.userBody!.text = 'Changed user\n\n' + markerLine;
        if (drift === 'work') { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }
        if (drift === 'owner') f.world.__computaModelOwner = 'another-owner';
        if (drift === 'url') f.document.URL = 'https://chatgpt.com/c/unrelated';
      });
      const observed = await f.inspect();
      // The existing first-message digest guard rejects owner/URL crossings
      // before later document-context checks. Preserve that error ordering.
      expect(observed.error).toBe(drift === 'work' ? 'product_mode_unverified' : 'conversation_changed');
      expect(observed.responseLoadFailed).toBeUndefined(); expect(f.composer.events).toEqual([]);
    }
  });
});

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
    for (const variant of ['hidden-error', 'hidden-retry', 'detached', 'no-retry', 'sidebar', 'editor', 'menu', 'pre', 'code', 'legacy-assistant']) {
      const f = fixture({ response: false, userPrompt: 'Read the fixture marker' }), e = errorRegion();
      if (variant === 'hidden-error') e.error.values.hidden = '';
      if (variant === 'hidden-retry') e.retry.values['aria-hidden'] = 'true';
      if (variant === 'detached') e.region.connected = false;
      if (variant === 'no-retry') e.retry.text = 'Something else';
      if (variant === 'menu') e.region.values.role = 'menu';
      if (variant === 'sidebar') { const sidebar = new Element('ASIDE'); sidebar.append(e.region); f.body.append(sidebar); }
      else if (variant === 'editor') f.composer.append(e.region);
      else if (['pre', 'code', 'legacy-assistant'].includes(variant)) {
        const wrapper = new Element(variant === 'pre' ? 'PRE' : variant === 'code' ? 'CODE' : 'DIV',
          variant === 'legacy-assistant' ? { 'data-message-author-role': 'assistant' } : {});
        wrapper.append(e.region); f.body.querySelector('main')!.append(wrapper);
      }
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


describe('finite response notice relationship diagnostics without error-policy changes', () => {
  const addWidget = (f: ReturnType<typeof fixture>, options: { shared?: boolean; nested?: boolean; text?: string; dialog?: boolean } = {}) => {
    const parent = new Element('DIV', options.dialog === false ? {} : { role: 'dialog' });
    const notice = new Element('DIV', { role: 'status' });
    const retry = new Element('BUTTON', {}, 'Retry');
    const label = new Element('SPAN', {}, options.nested ? 'Load ' : options.text ?? 'Load failed');
    if (options.nested) label.append(new Element('STRONG', {}, 'failed'));
    notice.append(label);
    if (options.shared) parent.append(notice, retry); else { notice.append(retry); parent.append(notice); }
    f.body.querySelector('main')!.append(parent);
    return { parent, notice, retry, label };
  };
  test('observes a shared status widget in a dialog and aborts without clicking', async () => {
    const f = fixture({ response: false, userPrompt: 'Read the fixture' });
    const widget = addWidget(f, { nested: true });
    const inspection = await f.inspect();
    expect(inspection.responseLoadFailed).toBe(true);
    const notice = inspection.responseNoticeDiagnostic;
    expect(notice).toEqual({ kind: 'chatgpt_response_notice_v1', retryCount: 1, observationsTruncated: false,
      observations: [{ excludedAncestor: 'dialog', contentExcluded: false, retryEnabled: true,
        noticeRole: 'status', pairing: 'ancestor', sameWidget: true, knownError: 'load_failed',
        labelStructure: 'nested', labelScanTruncated: false }] });
    expect((await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic).toEqual(notice);
    expect(widget.retry.clicks).toBe(0); expect(widget.retry.events.length).toBe(0);
  });
  test('pairs only the single status and Retry in a small direct shared parent', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const widget = addWidget(f, { shared: true });
    let observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
    expect(observation.pairing).toBe('shared_parent'); expect(observation.sameWidget).toBe(true);
    widget.parent.append(new Element('INPUT'));
    observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
    expect(observation.pairing).toBe('none'); expect(observation.sameWidget).toBe(false);
    expect(observation.knownError).toBe('none'); expect(widget.retry.clicks).toBe(0);
  });
  test('does not pair an unrelated page status with a Retry in another control', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const main = f.body.querySelector('main')!;
    const status = new Element('DIV', { role: 'status' }, 'Load failed');
    const unrelated = new Element('DIV', { role: 'dialog' }); unrelated.append(new Element('BUTTON', {}, 'Retry'));
    main.append(status, unrelated);
    const observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
    expect(observation.noticeRole).toBe('none'); expect(observation.sameWidget).toBe(false);
    expect(observation.knownError).toBe('none'); expect(observation.excludedAncestor).toBe('dialog');
  });
  test('preserves exclusions for quoted user/assistant/editor/code and menu/navigation widgets', async () => {
    for (const kind of ['user', 'assistant', 'editor', 'code', 'menu', 'nav', 'aside']) {
      const f = fixture({ userPrompt: 'Original fixture task' }); await f.inspect();
      const widget = addWidget(f);
      const originalParent = widget.parent.parentElement!;
      originalParent.children = originalParent.children.filter(child => child !== widget.parent);
      let wrapper: Element;
      if (kind === 'user') wrapper = f.userBody!;
      else if (kind === 'assistant') wrapper = f.answer;
      else if (kind === 'editor') { wrapper = new Element('DIV', { contenteditable: 'true' }); f.body.querySelector('main')!.append(wrapper); }
      else {
        wrapper = new Element(kind === 'code' ? 'CODE' : kind.toUpperCase(), kind === 'menu' ? { role: 'menu' } : {});
        f.body.querySelector('main')!.append(wrapper);
      }
      // A dialog nested inside quoted content still cannot become a status proof.
      if (['menu', 'nav', 'aside'].includes(kind)) widget.parent.values.role = '';
      wrapper.append(widget.parent);
      const observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
      expect(observation.sameWidget).toBe(false); expect(observation.knownError).toBe('none');
      if (['menu', 'nav', 'aside'].includes(kind)) expect(observation.excludedAncestor).toBe(kind);
      else expect(observation.contentExcluded).toBe(true);
      expect(widget.retry.clicks).toBe(0);
    }
  });
  test('a paired status cannot promote known strings quoted inside protected label descendants', async () => {
    for (const kind of ['pre', 'code', 'user', 'assistant', 'menu', 'nav', 'aside']) {
      const f = fixture({ response: false }); await f.inspect(); const widget = addWidget(f);
      widget.label.text = ''; widget.retry.text = ''; widget.retry.values['aria-label'] = 'Retry';
      const quoted = new Element(['pre', 'code', 'nav', 'aside'].includes(kind) ? kind.toUpperCase() : 'DIV',
        kind === 'user' || kind === 'assistant' ? { 'data-message-author-role': kind }
          : kind === 'menu' ? { role: 'menu' } : {});
      quoted.append(new Element('SPAN', {}, 'Load failed')); widget.notice.append(quoted);
      const observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
      expect(observation.sameWidget).toBe(false); expect(observation.knownError).toBe('none');
      expect(observation.labelStructure).toBe('none'); expect(widget.retry.clicks).toBe(0);
    }
  });
  test('a main status container cannot pair unrelated label and Retry branches', async () => {
    const f = fixture({ response: false }); await f.inspect(); const main = f.body.querySelector('main')!;
    main.values.role = 'status';
    const labelBranch = new Element('DIV'); labelBranch.append(new Element('SPAN', {}, 'Load failed'));
    const controlBranch = new Element('DIV'); const retry = new Element('BUTTON', {}, 'Retry'); controlBranch.append(retry);
    main.append(labelBranch, controlBranch);
    const observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
    expect(observation.pairing).toBe('none'); expect(observation.sameWidget).toBe(false);
    expect(observation.knownError).toBe('none'); expect(retry.clicks).toBe(0);
  });
  test('a non-main status with unrelated nested branches or form controls is not one widget', async () => {
    for (const variant of ['separate-branches', 'form-control']) {
      const f = fixture({ response: false }); await f.inspect(); const main = f.body.querySelector('main')!;
      const status = new Element('DIV', { role: 'status' }), label = new Element('SPAN', {}, 'Load failed');
      const retry = new Element('BUTTON', {}, 'Retry');
      if (variant === 'separate-branches') {
        const labelBranch = new Element('DIV'), controlBranch = new Element('DIV');
        labelBranch.append(label); controlBranch.append(retry); status.append(labelBranch, controlBranch);
      } else status.append(label, retry, new Element('INPUT'));
      main.append(status);
      const observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
      expect(observation.pairing).toBe('ambiguous'); expect(observation.sameWidget).toBe(false);
      expect(observation.knownError).toBe('none'); expect(retry.clicks).toBe(0);
    }
  });
  test('outer menu/navigation/aside ancestry wins over an inner status dialog', async () => {
    for (const kind of ['menu', 'nav', 'aside']) {
      const f = fixture({ response: false }); await f.inspect(); const widget = addWidget(f);
      const main = f.body.querySelector('main')!;
      main.children = main.children.filter(child => child !== widget.parent);
      const outer = new Element(kind === 'menu' ? 'DIV' : kind.toUpperCase(), kind === 'menu' ? { role: 'menu' } : {});
      outer.append(widget.parent); main.append(outer);
      const observation = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic.observations[0];
      expect(observation.excludedAncestor).toBe(kind); expect(observation.pairing).toBe('none');
      expect(observation.sameWidget).toBe(false); expect(observation.knownError).toBe('none');
      expect(widget.retry.clicks).toBe(0);
    }
  });
  test('unknown status text remains an enum and cannot leak notice text or URLs', async () => {
    const f = fixture({ response: false }); await f.inspect();
    addWidget(f, { text: 'PRIVATE_NOTICE https://private.example/?token=PRIVATE_TOKEN' });
    const diagnostic = (await f.diagnose()).failureDiagnostic;
    const observation = diagnostic.responseNoticeDiagnostic.observations[0];
    expect(observation.sameWidget).toBe(true); expect(observation.knownError).toBe('unknown');
    expect(observation.labelStructure).toBe('none');
    expect(JSON.stringify(diagnostic).includes('PRIVATE')).toBe(false);
    expect(JSON.stringify(diagnostic).includes('https')).toBe(false);
  });
  test('ambiguous widgets, hidden Retry and disabled Retry retain separate finite facts', async () => {
    const f = fixture({ response: false }); await f.inspect();
    const widget = addWidget(f); const second = new Element('BUTTON', {}, 'Retry'); widget.notice.append(second);
    let diagnostic = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic;
    expect(diagnostic.retryCount).toBe(2); expect(diagnostic.observations[0].pairing).toBe('ambiguous');
    expect(diagnostic.observations[0].sameWidget).toBe(false);
    second.values.hidden = ''; widget.retry.disabled = true;
    diagnostic = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic;
    expect(diagnostic.retryCount).toBe(1); expect(diagnostic.observations[0].retryEnabled).toBe(false);
    expect(diagnostic.observations[0].sameWidget).toBe(true); expect(widget.retry.clicks).toBe(0);
  });
  test('bounds retry observations and marks a truncated label scan as unknown', async () => {
    const f = fixture({ response: false }); await f.inspect(); const widget = addWidget(f);
    const labelWrapper = new Element('DIV'); widget.notice.append(labelWrapper);
    for (let index = 0; index < 129; index++) labelWrapper.append(new Element('DIV', {}, 'PRIVATE_' + index));
    let diagnostic = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic;
    expect(diagnostic.observations[0].labelScanTruncated).toBe(true);
    expect(diagnostic.observations[0].knownError).toBe('unknown');
    for (let index = 0; index < 3; index++) f.body.querySelector('main')!.append(new Element('BUTTON', {}, 'Retry'));
    diagnostic = (await f.diagnose()).failureDiagnostic.responseNoticeDiagnostic;
    expect(diagnostic.retryCount).toBe(4); expect(diagnostic.observations.length).toBe(2);
    expect(diagnostic.observationsTruncated).toBe(true); expect(JSON.stringify(diagnostic).includes('PRIVATE')).toBe(false);
  });
});


describe('bounded abort-only response error widget', () => {
  const widget = (f: ReturnType<typeof fixture>, variant: 'plain' | 'leaf' | 'nested' = 'leaf', role?: string) => {
    const dialog = new Element('DIV', { role: 'dialog' });
    const region = new Element('DIV', role ? { role } : {});
    const retry = new Element('BUTTON', {}, 'Retry');
    const label = new Element('SPAN', {}, variant === 'nested' ? 'Load ' : 'Load failed');
    if (variant === 'nested') label.append(new Element('STRONG', {}, 'failed'));
    if (variant === 'plain') region.text = 'Load failed'; else region.append(label);
    region.append(retry); dialog.append(region); f.body.querySelector('main')!.append(dialog);
    return { dialog, region, retry, label };
  };
  test('a generic direct text or single leaf/nested label fails promptly inside a dialog', async () => {
    for (const variant of ['plain', 'leaf', 'nested'] as const) {
      for (const role of [undefined, 'status', 'alert']) {
        const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect();
        const w = widget(f, variant, role), result = await f.inspect();
        expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
        expect(result.responseLoadFailed).toBe(true); expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
      }
    }
  });
  test('unknown text, multiple labels, disabled Retry and extra controls cannot become a known failure', async () => {
    for (const variant of ['unknown', 'two-labels', 'disabled', 'extra-control', 'extra-button', 'wide', 'long-label']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f);
      if (variant === 'unknown') w.label.text = 'PRIVATE_UNKNOWN_NOTICE';
      if (variant === 'two-labels') w.region.append(new Element('SPAN', {}, 'Load failed'));
      if (variant === 'disabled') w.retry.disabled = true;
      if (variant === 'extra-control') w.region.append(new Element('INPUT'));
      if (variant === 'extra-button') w.region.append(new Element('BUTTON', {}, 'Retry'));
      if (variant === 'wide') for (let i = 0; i < 5; i++) w.region.append(new Element('DIV'));
      if (variant === 'long-label') w.label.text = 'Load failed' + ' '.repeat(129);
      const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0);
    }
  });
  test('main/status and non-main split branches stay unpaired even with a valid current user', async () => {
    for (const variant of ['main', 'split-status', 'mixed-status']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect();
      const main = f.body.querySelector('main')!, region = variant === 'main' ? main : new Element('DIV', { role: 'status' });
      region.values.role = 'status'; const retry = new Element('BUTTON', {}, 'Retry'), label = new Element('SPAN', {}, 'Load failed');
      if (variant === 'mixed-status') region.append(label, retry, new Element('INPUT'));
      else { const a = new Element('DIV'), b = new Element('DIV'); a.append(label); b.append(retry); region.append(a, b); }
      if (region !== main) main.append(region);
      const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(retry.clicks).toBe(0);
    }
  });
  test('outer menu/nav/aside cannot hide behind a dialog or a generic widget', async () => {
    for (const kind of ['menu', 'nav', 'aside']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f, 'plain');
      const main = f.body.querySelector('main')!; main.children = main.children.filter(child => child !== w.dialog);
      const blocked = new Element(kind === 'menu' ? 'DIV' : kind.toUpperCase(), kind === 'menu' ? { role: 'menu' } : {});
      blocked.append(w.dialog); main.append(blocked);
      const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0);
    }
  });
  test('only a small direct common parent can pair a status sibling with Retry', async () => {
    const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect();
    const main = f.body.querySelector('main')!, dialog = new Element('DIV', { role: 'dialog' });
    const status = new Element('DIV', { role: 'status' }, 'Load failed'), retry = new Element('BUTTON', {}, 'Retry');
    dialog.append(status, retry); main.append(dialog);
    // It is a small direct widget despite the optional inner status role. No
    // broad ancestor search or unrelated page status supplies this result.
    expect((await f.inspect()).responseLoadFailed).toBe(true); expect(retry.clicks).toBe(0);
    const unrelated = new Element('DIV'); dialog.children = dialog.children.filter(child => child !== retry);
    unrelated.append(retry); dialog.append(unrelated);
    expect((await f.inspect()).responseLoadFailed).toBe(false); expect(retry.clicks).toBe(0);
  });
  test('hidden nested label text and protected wrapper or label content cannot abort', async () => {
    for (const kind of ['hidden-nested', 'user', 'assistant', 'editor', 'pre', 'code', 'markdown', 'nested-user', 'nested-editor']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f, 'nested');
      if (kind === 'hidden-nested') w.label.children[0].values.hidden = '';
      else if (kind.startsWith('nested-')) {
        w.label.values[kind === 'nested-user' ? 'data-message-author-role' : 'contenteditable'] = kind === 'nested-user' ? 'user' : 'true';
      } else {
        const main = f.body.querySelector('main')!; main.children = main.children.filter(child => child !== w.dialog);
        const protectedWrapper = new Element(['pre', 'code'].includes(kind) ? kind.toUpperCase() : 'DIV',
          kind === 'user' || kind === 'assistant' ? { 'data-message-author-role': kind }
            : kind === 'editor' ? { contenteditable: 'true' } : kind === 'markdown' ? { class: 'markdown' } : {});
        protectedWrapper.append(w.dialog); main.append(protectedWrapper);
      }
      const result = await f.inspect();
      if (kind === 'user' || kind === 'nested-user') {
        // A newly added user-role region invalidates message identity before
        // website error classification. Keep that stronger ownership rejection.
        expect(result).toMatchObject({ error: 'conversation_changed', detail: 'user_count' });
        expect(result.responseLoadFailed).toBeUndefined();
      } else { expect(result.error).toBeUndefined(); expect(result.responseLoadFailed).toBe(false); }
      expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
    }
  });
  test('semantic navigation and any editable ancestry cannot hide behind a dialog', async () => {
    for (const kind of ['navigation', 'complementary', 'menubar', 'editable-empty', 'editable-plaintext', 'editable-false']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f, 'plain');
      const main = f.body.querySelector('main')!; main.children = main.children.filter(child => child !== w.dialog);
      const blocked = new Element('DIV', kind.startsWith('editable-') ? { contenteditable:
        kind === 'editable-empty' ? '' : kind === 'editable-plaintext' ? 'plaintext-only' : 'false' } : { role: kind });
      blocked.append(w.dialog); main.append(blocked);
      const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0);
      expect(w.retry.events.length).toBe(0);
    }
  });
  test('ARIA controls and interactive semantics cannot supply the exact label or enclose the widget', async () => {
    const roles = ['textbox', 'button', 'link', 'checkbox', 'combobox', 'grid', 'gridcell', 'listbox', 'menu', 'menubar',
      'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'radiogroup', 'scrollbar', 'searchbox',
      'slider', 'spinbutton', 'switch', 'tab', 'tablist', 'toolbar', 'tree', 'treegrid', 'treeitem', 'navigation', 'complementary'];
    for (const role of roles) {
      for (const placement of ['label', 'nested', 'region', 'outer']) {
        const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f, 'nested');
        if (placement === 'label') w.label.values.role = role;
        if (placement === 'nested') w.label.children[0].values.role = role;
        if (placement === 'region') w.region.values.role = role;
        if (placement === 'outer') {
          const main = f.body.querySelector('main')!; main.children = main.children.filter(child => child !== w.dialog);
          const wrapper = new Element('DIV', { role }); wrapper.append(w.dialog); main.append(wrapper);
        }
        const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0);
        expect(w.retry.events.length).toBe(0);
      }
    }
    for (const kind of ['tabindex', 'editable-empty', 'editable-plaintext', 'editable-false', 'link', 'label-for', 'details']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f);
      if (kind === 'tabindex') w.label.values.tabindex = '-1';
      if (kind.startsWith('editable-')) w.label.values.contenteditable = kind === 'editable-empty' ? '' : kind === 'editable-plaintext' ? 'plaintext-only' : 'false';
      if (kind === 'link') { w.label.tagName = 'A'; w.label.values.href = '/private'; }
      if (kind === 'label-for') { w.label.tagName = 'LABEL'; w.label.values.for = 'another-control'; }
      if (kind === 'details') w.label.tagName = 'SUMMARY';
      const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0);
      expect(w.retry.events.length).toBe(0);
    }
    // The actual Retry button may use its normal ARIA role, and a dialog can
    // be focusable. Only label branches must be inert; controls cannot enclose it.
    const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f);
    w.retry.values.role = 'button'; w.dialog.values.tabindex = '-1';
    expect((await f.inspect()).responseLoadFailed).toBe(true); expect(w.retry.clicks).toBe(0);
  });
  test('compound navigation and complementary role tokens retain their excluded boundary', async () => {
    for (const role of ['navigation region', 'complementary region', 'region navigation', 'region complementary']) {
      for (const placement of ['label', 'nested', 'region', 'outer']) {
        const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f, 'nested');
        if (placement === 'label') w.label.values.role = role;
        if (placement === 'nested') w.label.children[0].values.role = role;
        if (placement === 'region') w.region.values.role = role;
        if (placement === 'outer') {
          const main = f.body.querySelector('main')!; main.children = main.children.filter(child => child !== w.dialog);
          const wrapper = new Element('DIV', { role }); wrapper.append(w.dialog); main.append(wrapper);
        }
        const result = await f.inspect(); expect(result.error).toBeUndefined(); expect(result.responseLoadFailed).toBe(false);
        expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
      }
    }
  });
  test('an error widget cannot override changed ownership, message, product, origin or frame proof', async () => {
    for (const drift of ['owner', 'user', 'work', 'origin', 'frame']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = widget(f, 'plain');
      if (drift === 'owner') f.world.__computaModelOwner = 'FOREIGN_OWNER';
      if (drift === 'user') f.userBody!.text = 'Changed user body\n\n' + markerLine;
      if (drift === 'work') { f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false'; }
      if (drift === 'origin') f.location.origin = 'https://foreign.example';
      if (drift === 'frame') f.window.top = {};
      const result = await f.inspect(); expect(result.error).toBeDefined(); expect(result.responseLoadFailed).toBeUndefined();
      expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
    }
  });
});


describe('bounded semantic alert aside response error', () => {
  const alertWidget = (f: ReturnType<typeof fixture>) => {
    // The nine elements measured in the admitted live page, without page text
    // outside the fixed error/Retry literals or any account data.
    const alert = new Element('ASIDE', { role: 'alert' }), empty = new Element('DIV');
    const content = new Element('DIV'), row = new Element('DIV'), errorBranch = new Element('DIV');
    const labelWrapper = new Element('DIV'), label = new Element('DIV', {}, 'Load failed');
    const controlBranch = new Element('DIV'), retry = new Element('BUTTON', {}, 'Retry');
    alert.append(empty, content); content.append(row); row.append(errorBranch, controlBranch);
    errorBranch.append(labelWrapper); labelWrapper.append(label); controlBranch.append(retry);
    f.body.querySelector('main')!.append(alert);
    return { alert, empty, content, row, errorBranch, labelWrapper, label, controlBranch, retry };
  };
  test('the exact nine-element nested alert-aside is an abort-only owned error', async () => {
    const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = alertWidget(f);
    expect(w.alert.descendants().length + 1).toBe(9); expect(w.alert.textContent).toBe('Load failedRetry');
    w.retry.values.role = 'button'; w.retry.values.tabindex = '0';
    const result = await f.inspect(); expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
    expect(result.responseLoadFailed).toBe(true); expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
  });
  test('unknown text, hidden labels, extra controls and unbounded shapes never become the known error', async () => {
    for (const variant of ['no-alert', 'complementary', 'compound-alert', 'unknown', 'extra-text', 'second-label', 'hidden-label', 'hidden-retry',
      'disabled', 'aria-disabled', 'extra-button', 'input', 'link', 'script', 'wide', 'deep', 'long-label', 'extra-retry-text']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = alertWidget(f);
      if (variant === 'no-alert') delete w.alert.values.role;
      if (variant === 'complementary') w.alert.values.role = 'complementary';
      if (variant === 'compound-alert') w.alert.values.role = 'alert complementary';
      if (variant === 'unknown') w.label.text = 'PRIVATE_UNKNOWN';
      if (variant === 'extra-text') w.empty.text = 'Unrelated';
      if (variant === 'second-label') w.empty.text = 'Load failed';
      if (variant === 'hidden-label') w.errorBranch.values.hidden = '';
      if (variant === 'hidden-retry') w.retry.values['aria-hidden'] = 'true';
      if (variant === 'disabled') w.retry.disabled = true;
      if (variant === 'aria-disabled') w.retry.values['aria-disabled'] = 'true';
      if (variant === 'extra-button') w.empty.append(new Element('BUTTON', {}, 'Continue'));
      if (variant === 'input') w.empty.append(new Element('INPUT'));
      if (variant === 'link') w.labelWrapper.append(new Element('A', { href: '/private' }));
      if (variant === 'script') w.empty.append(new Element('SCRIPT'));
      if (variant === 'wide') for (let i = 0; i < 130; i++) w.empty.append(new Element('DIV'));
      if (variant === 'deep') { let parent = w.empty; for (let i = 0; i < 18; i++) { const node = new Element('DIV'); parent.append(node); parent = node; } }
      if (variant === 'long-label') w.label.text = ' '.repeat(129) + 'Load failed';
      if (variant === 'extra-retry-text') { w.retry.values['aria-label'] = 'Retry'; w.retry.text = 'Retry PRIVATE_EXTRA'; }
      const result = await f.inspect(); expect(result.error).toBeUndefined(); expect(result.responseLoadFailed).toBe(false);
      expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
    }
  });
  test('all protected ancestors remain excluded outside the semantic alert aside', async () => {
    for (const kind of ['nav', 'aside', 'menu', 'menubar', 'navigation', 'complementary', 'navigation region', 'complementary region',
      'textbox', 'button', 'assistant', 'pre', 'code', 'markdown', 'editable-empty', 'editable-plaintext', 'editable-false']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = alertWidget(f);
      const main = f.body.querySelector('main')!; main.children = main.children.filter(child => child !== w.alert);
      const attrs = kind === 'assistant' ? { 'data-message-author-role': 'assistant' }
        : kind === 'markdown' ? { class: 'markdown' }
        : kind.startsWith('editable-') ? { contenteditable: kind === 'editable-empty' ? '' : kind === 'editable-plaintext' ? 'plaintext-only' : 'false' }
        : ['nav', 'aside', 'pre', 'code'].includes(kind) ? {} : { role: kind };
      const outer = new Element(['nav', 'aside', 'pre', 'code'].includes(kind) ? kind.toUpperCase() : 'DIV', attrs);
      outer.append(w.alert); main.append(outer);
      const result = await f.inspect(); expect(result.error).toBeUndefined(); expect(result.responseLoadFailed).toBe(false);
      expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
    }
    const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = alertWidget(f);
    f.body.values.role = 'navigation region';
    expect((await f.inspect()).responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0);
  });
  test('protected label branches and custom controls cannot supply an alert-aside error label', async () => {
    for (const kind of ['assistant', 'code', 'pre', 'editor-empty', 'editor-plaintext', 'markdown', 'textbox', 'button', 'link',
      'checkbox', 'combobox', 'navigation region', 'complementary region', 'menu', 'menubar', 'tabindex', 'hidden-nested']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = alertWidget(f);
      if (kind === 'assistant') w.label.values['data-message-author-role'] = 'assistant';
      else if (['code', 'pre'].includes(kind)) w.label.tagName = kind.toUpperCase();
      else if (kind.startsWith('editor-')) w.label.values.contenteditable = kind === 'editor-empty' ? '' : 'plaintext-only';
      else if (kind === 'markdown') w.label.values.class = 'markdown';
      else if (kind === 'tabindex') w.label.values.tabindex = '-1';
      else if (kind === 'hidden-nested') { w.label.text = ''; w.label.append(new Element('DIV', { hidden: '' }, 'Load failed')); }
      else w.label.values.role = kind;
      const result = await f.inspect(); expect(result.responseLoadFailed).toBe(false); expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
    }
  });
  test('a known semantic alert cannot override current ownership, first-user, product, origin or frame guards', async () => {
    for (const drift of ['owner', 'user', 'work', 'origin', 'frame']) {
      const f = fixture({ response: false, userPrompt: 'Read the controlled fixture' }); await f.inspect(); const w = alertWidget(f);
      if (drift === 'owner') f.world.__computaModelOwner = 'FOREIGN_OWNER';
      if (drift === 'user') f.userBody!.text = 'Changed user body\n\n' + markerLine;
      if (drift === 'work') { f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false'; }
      if (drift === 'origin') f.location.origin = 'https://foreign.example';
      if (drift === 'frame') f.window.top = {};
      const result = await f.inspect(); expect(result.error).toBeDefined(); expect(result.responseLoadFailed).toBeUndefined();
      expect(w.retry.clicks).toBe(0); expect(w.retry.events.length).toBe(0);
    }
  });
});
