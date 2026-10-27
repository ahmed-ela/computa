import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { installObservedModelPicker } from "./embedded-provider-adapter-fixture";
import { defineWebsiteModelChoiceTests } from "./embedded-model-choice-tests";

const source = readFileSync(new URL("../Sources/Computa/Resources/BrowserModels/chatgpt.js", import.meta.url), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const execute = new AsyncFunction("input", "document", "window", "location", "getComputedStyle", "MutationObserver", "setTimeout", "globalThis", "crypto", "HTMLTextAreaElement", "Date", source);
// Pure DOM fixtures explicitly disable the optional clock-only profiler.
const disabledWorkDiagnostic = 'const chatGPTSyncWorkStart = () => null; const chatGPTSyncWorkEnd = () => {};\n';
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
  get firstElementChild() { return this.children[0] || null; }
  get lastElementChild() { return this.children.at(-1) || null; }
  get localName() { return this.tagName.toLowerCase(); }
  private namespaceOverride?: string;
  get namespaceURI() { return this.namespaceOverride ?? (['SVG', 'RECT'].includes(this.tagName) ? 'http://www.w3.org/2000/svg' : 'http://www.w3.org/1999/xhtml'); }
  set namespaceURI(value: string) { this.namespaceOverride = value; }
  hasAttribute(name: string) { return this.getAttribute(name) !== null; }
  get childNodes(): any[] { return [...(this.text ? [{ nodeType: 3, textContent: this.text, parentElement: this }] : []), ...this.children]; }
  get attributes() { return Object.entries(this.values).map(([name, value]) => ({ name, value })); }
  get classList() { const names = (this.values.class || "").split(/\s+/).filter(Boolean); return { contains: (name: string) => names.includes(name), [Symbol.iterator]: () => names[Symbol.iterator]() }; }
  get textContent(): string { return this.text + this.children.map(child => child.textContent).join(""); }
  get innerText() { return this.textContent; }
  getAttribute(name: string) { return this.values[name] ?? null; }
  getClientRects() { return this.isConnected && !this.zeroRects && this.values['data-fixture-display'] !== 'contents' && !this.closest('[hidden]') ? [{}] : []; }
  getBoundingClientRect() { return { left: 0, top: this.rect * 40, width: 100, height: 30 }; }
  append(...children: Element[]) { children.forEach(child => {
    // Native append moves an existing node instead of leaving it in two trees.
    if (child.parentElement) child.parentElement.children = child.parentElement.children.filter(existing => existing !== child);
    child.parentElement = this; this.children.push(child);
  }); }
  contains(node: Element | null): boolean { return node === this || !!node && this.children.some(child => child.contains(node)); }
  compareDocumentPosition(other: Element): number {
    if (other === this) return 0;
    const root = (node: Element) => { while (node.parentElement) node = node.parentElement; return node; };
    const mine = root(this), theirs = root(other);
    if (mine !== theirs) return 1 | 32; // DISCONNECTED | IMPLEMENTATION_SPECIFIC
    const order = [mine, ...mine.descendants()];
    return (order.indexOf(this) < order.indexOf(other) ? 4 : 2)
      | (this.contains(other) ? 16 : 0) | (other.contains(this) ? 8 : 0);
  }
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
  const posted: unknown[] = [], timers: (() => void)[] = [], scheduledDelays: number[] = [], digestInputs: string[] = [];
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
      opacity: node.values['data-fixture-opacity'] ?? '1',
      stroke: node.values.stroke ?? 'none', strokeOpacity: node.values['stroke-opacity'] ?? '0', strokeWidth: node.values['stroke-width'] ?? '0',
      content: pseudo === '::before' ? node.beforeContent : node.afterContent }), Observer, (callback: () => void, delay: number) => {
      timers.push(callback); scheduledDelays.push(delay);
    }, world, { subtle: { digest: async (algorithm: string, data: Uint8Array) => {
      digestInputs.push(new TextDecoder().decode(data));
      const digest = await crypto.subtle.digest(algorithm, data);
      if (useHook && (digestExpectedText === undefined || new TextDecoder().decode(data) === digestExpectedText)) {
        const hook = digestHook; digestHook = undefined; digestExpectedText = undefined; await hook?.();
      }
      return digest;
    } } }, class TextArea extends Element {}, { now: () => Date.now() + adapterClockOffset });
  return { rawRun: invoke, messages, posted, observers, location, document, world, window, body, temporary, composer, modeGroup, chatMode, workMode, scheduledDelays, digestInputs, userBody, answer: outer,
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

function observedChatGPTCodeBlock(f: ReturnType<typeof fixture>, raw: string, options: { noPre?: boolean; measuredPRE?: boolean; renderedText?: () => string } = {}) {
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
  Object.defineProperty(f.answer, "innerText", { get: options.renderedText ?? (() => (options.measuredPRE ? "JSON\n\n\n" : "JSON\n") + raw) });
  return { outer, wrapper, header, label, copy, wrap, pre, code, content };
}

defineWebsiteModelChoiceTests('chatgpt', (owned = false) => {
  const f = fixture({ response: owned, ...(owned ? { userPrompt: 'Synthetic owned prompt' } : {}) });
  return { ...f, run: (action: string, overrides: Record<string, unknown> = {}) => f.inspect({ ...overrides, action }) };
}, Element);

async function chatTurnFixture(modelChoice?: { key: string; label: string }, initialMarker = firstMarker, closedGenericHeader = false) {
  const f = fixture({ response: false });
  await f.inspect({ expectedUserCounts: [0], expectedFirstUserMarker: initialMarker });
  let picker: ReturnType<typeof installObservedModelPicker> | undefined;
  if (modelChoice) {
    picker = installObservedModelPicker(f, 'chatgpt', Element, { genericHeader: true, closedGenericHeader, resetToPowerOnClose: closedGenericHeader });
    if (closedGenericHeader) expect((await f.inspect({ action: 'selectModel', modelChoice, expectedUserCounts: [0] })).selected).toBe(true);
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

// Captured ChatGPT user-message presentation: direct prefix TEXT, one PRE /
// CODE / TEXT, then direct suffix TEXT. innerText inserts an extra block break.
function renderFencedSubmission(body: Element, outbound: string, clipped = false) {
  const opening = 'COMPLETE_RESPONSES_REQUEST_JSON:\n```\n', closing = '\n```\nEND_COMPLETE_RESPONSES_REQUEST_JSON.';
  const start = outbound.indexOf(opening) + opening.length, finish = outbound.indexOf(closing, start);
  if (start < opening.length || finish < start) throw new Error('Invalid fenced fixture');
  const textNode = (parentElement: Element, textContent: string) => ({ nodeType: 3, parentElement, textContent });
  const prefix = textNode(body, outbound.slice(0, start - 4));
  const pre = new Element('PRE', { 'data-markdown-copy': 'code-block', 'data-horizontal-scroll': 'true', dir: 'ltr' });
  const code = new Element('CODE', { 'data-markdown-copy-content': 'true' });
  const text = textNode(code, outbound.slice(start, clipped ? start + 24 : finish));
  const suffix = textNode(body, outbound.slice(finish + 4));
  const codeNodes: any[] = [text], preNodes: any[] = [code], bodyNodes: any[] = [prefix, pre, ...(clipped ? [] : [suffix])];
  body.text = ''; body.children = []; body.append(pre); pre.append(code);
  Object.defineProperties(code, {
    childNodes: { configurable: true, get: () => codeNodes },
    textContent: { configurable: true, get: () => codeNodes.map(node => node.textContent).join('') },
  });
  Object.defineProperty(pre, 'childNodes', { configurable: true, get: () => preNodes });
  Object.defineProperties(body, {
    childNodes: { configurable: true, get: () => bodyNodes },
    textContent: { configurable: true, get: () => bodyNodes.map(node => node.textContent).join('') },
    innerText: { configurable: true, get: () => bodyNodes.map(node => node.textContent + (node === pre ? '\n' : '')).join('') },
  });
  return { prefix, pre, code, text, suffix, codeNodes, preNodes, bodyNodes };
}
const fencedRequest = (payload = '{"model":"chatgpt:chat/latest/instant","input":"literal \\u005f \\u0060", "duplicate":1,"duplicate":2,"exact":9007199254740993}') =>
  'Use the available tools.\n\nCOMPLETE_RESPONSES_REQUEST_JSON:\n```\n' + payload
    + '\n```\nEND_COMPLETE_RESPONSES_REQUEST_JSON.\n\nReturn one JSON object.';

describe('ChatGPT exact fenced request presentation', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  test('three retained rounds preserve exact lexical bytes, native hashes, model proof and one send each', async () => {
    const x = await chatTurnFixture(choice);
    for (let index = 0; index < 3; index++) {
      const record = await x.dispatch(fencedRequest());
      const body = x.f.document.querySelectorAll('article[data-turn="user"]')[index].children[0];
      const dom = renderFencedSubmission(body, record.outbound);
      expect(body.innerText).not.toBe(record.outbound); expect(body.textContent).not.toBe(record.outbound);
      expect(dom.text.textContent).toContain('"duplicate":1,"duplicate":2,"exact":9007199254740993');
      x.answer('Owned result ' + index);
      const observed = await x.observe(record);
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect(observed.submissionProof).toEqual({ sequence: index + 1, fingerprint: record.fingerprint });
      expect(observed.modelEvidence.selected).toEqual(choice); expect(observed.answerComplete).toBe(true);
      expect(observed.text).toContain('Owned result ' + index); expect(x.send.clicks).toBe(index + 1);
      expect(x.f.digestInputs).toContain(record.outbound);
    }
  });

  test('literal fenced echoes and legacy unfenced requests retain their original exact proof path', async () => {
    for (const prompt of ['Legacy exact request', fencedRequest()]) {
      const x = await chatTurnFixture(choice), record = await x.dispatch(prompt); x.answer('Literal');
      const observed = await x.observe(record);
      expect(observed.error).toBeUndefined(); expect(observed.submissionProof?.fingerprint).toBe(record.fingerprint);
      expect(observed.answerComplete).toBe(true); expect(x.send.clicks).toBe(1);
    }
  });

  test('altered payload lexemes and surrounding bytes cannot gain authority through JSON equivalence', async () => {
    for (const mutation of ['escape', 'precision', 'duplicate', 'prefix', 'suffix', 'truncated', 'fence']) {
      const x = await chatTurnFixture(choice), record = await x.dispatch(fencedRequest());
      const body = x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0];
      const dom = renderFencedSubmission(body, record.outbound); x.answer('Unverified');
      if (mutation === 'escape') dom.text.textContent = dom.text.textContent.replace('\\u005f', '_');
      if (mutation === 'precision') dom.text.textContent = dom.text.textContent.replace('9007199254740993', '9007199254740992');
      if (mutation === 'duplicate') dom.text.textContent = dom.text.textContent.replace('"duplicate":1,', '');
      if (mutation === 'prefix') dom.prefix.textContent += 'changed';
      if (mutation === 'suffix') dom.suffix.textContent += 'changed';
      if (mutation === 'truncated') dom.text.textContent = dom.text.textContent.slice(0, -1);
      if (mutation === 'fence') dom.text.textContent += '\n```';
      const observed = await x.observe(record);
      expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('submissionProof');
      expect(observed).not.toHaveProperty('answerComplete', true); expect(x.send.clicks).toBe(1);
    }
  });

  test('extra, hidden, nested or ambiguous DOM cannot reconstruct a known request', async () => {
    for (const mutation of ['extra_text', 'extra_block', 'comment', 'nested_code', 'hidden_pre', 'hidden_code', 'wrong_attribute', 'wrong_body']) {
      const x = await chatTurnFixture(choice), record = await x.dispatch(fencedRequest());
      const body = x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0];
      const dom = renderFencedSubmission(body, record.outbound); x.answer('Unverified');
      if (mutation === 'extra_text') dom.bodyNodes.push({ nodeType: 3, parentElement: body, textContent: '' });
      if (mutation === 'extra_block') { const extra = new Element('PRE'); body.append(extra); dom.bodyNodes.push(extra); }
      if (mutation === 'comment') dom.preNodes.push({ nodeType: 8, textContent: '', parentElement: dom.pre });
      if (mutation === 'nested_code') dom.codeNodes[0] = new Element('SPAN', {}, dom.text.textContent);
      if (mutation === 'hidden_pre') dom.pre.values.hidden = '';
      if (mutation === 'hidden_code') dom.code.values['aria-hidden'] = 'true';
      if (mutation === 'wrong_attribute') dom.code.values['data-markdown-copy-content'] = 'false';
      if (mutation === 'wrong_body') body.values.class = 'different-body';
      const observed = await x.observe(record);
      expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('submissionProof');
      expect(observed).not.toHaveProperty('answerComplete', true); expect(x.send.clicks).toBe(1);
    }
  });

  test('same-byte node replacement during digest invalidates the existing physical observation', async () => {
    for (const mutation of ['code', 'text', 'prefix', 'suffix']) {
      const x = await chatTurnFixture(choice), record = await x.dispatch(fencedRequest());
      const body = x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0];
      const dom = renderFencedSubmission(body, record.outbound); x.answer('Unverified');
      x.f.onDigest(() => {
        if (mutation === 'code') {
          const replacement = new Element('CODE', { ...dom.code.values }, dom.text.textContent);
          replacement.parentElement = dom.pre; dom.pre.children = [replacement]; dom.preNodes[0] = replacement;
        } else if (mutation === 'text') dom.codeNodes[0] = { ...dom.text };
        else if (mutation === 'prefix') dom.bodyNodes[0] = { ...dom.prefix };
        else dom.bodyNodes[2] = { ...dom.suffix };
      }, record.outbound);
      const observed = await x.observe(record);
      expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('submissionProof');
      expect(observed).not.toHaveProperty('answerComplete', true); expect(x.send.clicks).toBe(1);
    }
  });

  test('first and later clipped fences get only the existing authorized expansion before exact binding', async () => {
    for (const sequence of [1, 2]) {
      const x = await chatTurnFixture(choice);
      if (sequence === 2) { const first = await x.dispatch(fencedRequest()); x.answer('First'); await x.observe(first); }
      const record = await x.dispatch(fencedRequest()); x.answer('Expanded');
      const root = x.f.document.querySelectorAll('article[data-turn="user"]')[sequence - 1], body = root.children[0];
      renderFencedSubmission(body, record.outbound, true);
      const more = new Element('BUTTON', { 'aria-label': 'Show more' });
      more.onClick = () => { renderFencedSubmission(body, record.outbound); }; root.append(more);
      const observed = await x.observe(record, { allowFirstUserExpansion: true, firstUserExpansionModelChoice: choice,
        allowSubmissionExpansion: true });
      expect(observed.error).toBeUndefined(); expect(observed.submissionProof?.fingerprint).toBe(record.fingerprint);
      expect(observed.answerComplete).toBe(true); expect(more.clicks).toBe(1); expect(x.send.clicks).toBe(sequence);
    }
  });
});

describe('readiness-only selector observation', () => {
  test('only an exact opt-in adds the fixed editor selector attributes to the existing event waiter', async () => {
    const helper = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url), 'utf8');
    const start = helper.indexOf('function websiteModelWaitForChange(');
    const end = helper.indexOf('async function websiteModelSettleSelection(', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const run = new Function('optIn', `
      let callback, captured, ready = false;
      const Date = { now: () => 1000 }, window = {}, input = {};
      const document = { documentElement: {} };
      const websiteModelDiagnosticPhase = () => {};
      const setTimeout = () => 0, clearTimeout = () => {};
      class MutationObserver {
        constructor(value) { callback = value; }
        observe(_target, options) { captured = options; }
        disconnect() {}
      }
      ${helper.slice(start, end)}
      const pending = websiteModelWaitForChange(2000, () => ready, 'model_wait', null, optIn);
      ready = true; callback([]); return pending.then(() => captured.attributeFilter);
    `);
    const baseline = await run(false);
    for (const value of [undefined, false, 1, 'true']) expect(await run(value)).toEqual(baseline);
    expect(await run(true)).toEqual([...baseline, 'id', 'contenteditable', 'data-testid']);
    for (const name of ['id', 'contenteditable', 'data-testid']) expect(baseline).not.toContain(name);
  });
});

describe('private first-insert model deadline cap', () => {
  test('expired and malformed final-guard caps reject before observing or clicking page controls', async () => {
    const start = source.indexOf('async function websiteChatObserveSelection(');
    const end = source.indexOf('async function websiteChatPickerAction(', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const run = new AsyncFunction('document', 'globalThis', 'Date', 'context', source.slice(start, end)
      + "return websiteChatObserveSelection({ action: 'insert', submissionSequence: 1, expectedModelChoice: { key: 'chat/latest/instant' } }, {}, null, null, context);");
    for (const value of [999, 1_000, -1, 1.5, NaN, Infinity, null, '1001']) {
      const result = await run({ URL: 'https://chatgpt.com/' }, {}, { now: () => 1_000 },
        { action: 'insert', scope: 'action_final_guard', firstInsertDeadline: value });
      expect(result).toEqual({ error: 'model_unverified' });
    }
  });
});

describe('optional first-preparation timing', () => {
  const setupDurations = ['outerSetupMs', 'guardedSetupMs', 'providerEntryMs', 'providerSetupMs',
    'insertPreFocusMs', 'insertPostFocusMs', 'providerReturnMs', 'guardedFinalizationMs', 'outerFinalizationMs'];
  test('an actual first insert keeps exact submission state and emits only finite timing fields', async () => {
    for (const enabled of [false, true]) {
      const x = await chatTurnFixture();
      const outbound = 'PRIVATE_TIMING_PROMPT_CANARY\n\n' + markerLine;
      const result = await x.f.rawRun({ action: 'insert', prompt: outbound, expectedUserCounts: [0],
        submissionSequence: 1, submissionMarker: firstMarker, preparationTiming: enabled });
      expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
      expect(x.f.composer.text).toBe(outbound); expect(x.send.clicks).toBe(0);
      const state: any = x.f.world.__computaChatSubmissionState;
      expect(state.pending.phase).toBe('prepared'); expect(state.pending.canonical).toBe(outbound);
      if (!enabled) { expect(result).not.toHaveProperty('preparationTiming'); continue; }
      const timing = result.preparationTiming;
      expect(Object.keys(timing).sort()).toEqual(['totalMs', 'beginSubmissionMs', 'beginSubmissionHashMs',
        'modelPrecheckMs', 'finalGuardMs', 'editorFocusMs', 'editorMutationMs', 'inputDispatchMs', 'editorReadinessMs', 'editorReadyAtEntry', 'openingRecoveryUsed', ...setupDurations].sort());
      for (const [key, value] of Object.entries(timing)) {
        if (key === 'openingRecoveryUsed') { expect(value).toBe(false); continue; }
        if (key === 'editorReadyAtEntry') { expect(value).toBeNull(); continue; }
        if (value === null) continue;
        expect(typeof value).toBe('number'); expect(Number.isFinite(value)).toBe(true);
        expect(value as number).toBeGreaterThanOrEqual(0); expect(value as number).toBeLessThanOrEqual(45_000);
      }
      expect(timing.totalMs).not.toBeNull(); expect(timing.beginSubmissionMs).not.toBeNull();
      expect(timing.beginSubmissionHashMs).not.toBeNull(); expect(timing.editorMutationMs).not.toBeNull();
      for (const key of setupDurations) {
        expect(timing[key]).not.toBeNull(); expect(timing[key]).toBeLessThanOrEqual(timing.totalMs);
      }
      // The execCommand fixture includes browser input in its mutation span.
      expect(timing.inputDispatchMs).toBeNull();
      for (const privateValue of [outbound, firstMarker, state.pending.fingerprint, x.f.document.URL])
        expect(JSON.stringify(timing)).not.toContain(privateValue);
    }
  });

  test('unsupported flag values and nonempty native history never enable timing', async () => {
    for (const flag of [undefined, false, 1, 'true', {}]) {
      const f = fixture({ response: false });
      const result = await f.inspect({ preparationTiming: flag });
      expect(result).not.toHaveProperty('preparationTiming');
    }
    const x = await chatTurnFixture(); const record = await x.dispatch('PRIVATE_HISTORY_CANARY');
    x.answer('Done');
    const result = await x.observe(record, { preparationTiming: true });
    expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
    expect(result).not.toHaveProperty('preparationTiming'); expect(x.send.clicks).toBe(1);
  });

  test('timing clock failure and a backwards clock leave action results intact', () => {
    const start = source.indexOf('// Optional first-preparation timings are diagnostic only.');
    const end = source.indexOf('function websiteChatProvisionalHeaderRecords', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const helper = new Function('input', 'performance', 'globalThis', source.slice(start, end)
      + "return chatGPTPreparationResult({ inserted: true });");
    const input = { provider: 'chatgpt', action: 'insert', preparationTiming: true, expectedUserCounts: [0] };
    const failed = helper(input, { now() { throw new Error('PRIVATE_CLOCK_CANARY'); } }, {});
    expect(failed.inserted).toBe(true); expect(failed.preparationTiming.totalMs).toBeNull();
    let value = 10;
    const backwards = helper(input, { now: () => value-- }, {});
    expect(backwards.inserted).toBe(true); expect(backwards.preparationTiming.totalMs).toBeNull();
    expect(JSON.stringify(failed)).not.toContain('PRIVATE_CLOCK_CANARY');
  });
});

function moveFixtureElement(node: Element, parent: Element) {
  if (node.parentElement) node.parentElement.children = node.parentElement.children.filter(child => child !== node);
  parent.append(node);
}

async function modernOnlyEmptyChatGPTAnswerFixture() {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const x = await chatTurnFixture(choice);
  const record = await x.dispatch('Wait for actual answer text, even beside a completed footer', { deferModelVerification: true });
  const bound = await x.observe(record, { deferModelVerification: true });
  expect(bound.error).toBeUndefined(); expect(bound.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
  const turn = new Element('SECTION');
  const answer = new Element('DIV', { 'data-markdown-text-style': 'assistant-message' });
  const body = new Element('DIV'); answer.append(body);
  const footer = new Element('DIV', { class: 'turn-action-controls' });
  const copy = new Element('BUTTON', { 'aria-label': 'Copy' }); footer.append(copy);
  turn.append(answer, footer); x.f.messages.append(turn);
  return { x, record, choice, answer, body, copy };
}

describe('ChatGPT modern-only empty answer', () => {
  test('an empty modern assistant beside a legacy user and enabled footer carries no response proof', async () => {
    const p = await modernOnlyEmptyChatGPTAnswerFixture();
    const pickerClicks = p.x.picker!.trigger.clicks;
    for (let attempt = 0; attempt < 3; attempt++) {
      const observed = await p.x.observe(p.record, { deferModelVerification: true });
      expect(observed.error).toBeUndefined();
      expect(observed).toMatchObject({ text: '', answerComplete: true, busy: false,
        responseCount: 1, userCount: 1, modelVerificationPending: true,
        answerScopeDiagnostic: { rootPresent: true, bodyPresent: true, rootTextLength: 0,
          bodyTextLength: 0, rootChildren: 1, bodyChildren: 1 } });
      expect(observed).not.toHaveProperty('modelEvidence');
      expect(p.x.picker!.trigger.clicks).toBe(pickerClicks);
    }
    expect((await p.x.f.diagnose()).failureDiagnostic).toMatchObject({
      modernUsers: { connected: 0, visible: 0 }, legacyUsers: { connected: 1, visible: 1 },
      modernAssistants: { connected: 1, visible: 1 }, legacyAssistants: { connected: 0, visible: 0 },
      stopPresent: false, copyPresent: true, copyEnabled: true });
    expect(p.x.send.clicks).toBe(1); expect(p.copy.clicks).toBe(0);
  });

  test('later nonempty content in the same modern-only answer requires fresh full proof', async () => {
    const p = await modernOnlyEmptyChatGPTAnswerFixture();
    expect(await p.x.observe(p.record, { deferModelVerification: true })).toMatchObject({ text: '', modelVerificationPending: true });
    const pickerClicks = p.x.picker!.trigger.clicks;
    const response = JSON.stringify({ type: 'message', text: 'Actual delayed answer' });
    p.body.text = response;
    const candidate = await p.x.observe(p.record, { deferModelVerification: true });
    expect(candidate.error).toBeUndefined();
    expect(candidate).toMatchObject({ text: response, answerComplete: true, busy: false, modelVerificationPending: true });
    expect(candidate).not.toHaveProperty('modelEvidence');
    expect(p.x.picker!.trigger.clicks).toBe(pickerClicks);
    const verified = await p.x.observe(p.record, { deferModelVerification: false });
    expect(verified.error).toBeUndefined(); expect(verified.text).toBe(response);
    expect(verified.modelEvidence.selected).toEqual(p.choice);
    expect(verified).not.toHaveProperty('modelVerificationPending');
    expect(p.x.picker!.trigger.clicks).toBeGreaterThan(pickerClicks);
    expect(p.x.send.clicks).toBe(1); expect(p.copy.clicks).toBe(0);
  });
});

async function pairedChatGPTFooterFixture() {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const x = await chatTurnFixture(choice);
  const record = await x.dispatch('Exact owned paired-turn footer request', { deferModelVerification: true });
  // Establish the real production first-user and per-submission bindings before
  // staging the completed response. This fixture never manufactures proof state.
  const bound = await x.observe(record, { deferModelVerification: true });
  expect(bound.error).toBeUndefined(); expect(bound.firstUserVerified).toBe(true);
  expect(bound.submissionProof).toEqual({ sequence: record.sequence, fingerprint: record.fingerprint });
  const user = x.f.document.querySelectorAll('article[data-turn="user"]')[0], userBody = user.children[0];
  const state: any = x.f.world.__computaChatSubmissionState;
  expect(state.pending).toBeNull(); expect(state.lastVerified.phase).toBe('verified');
  expect(state.lastVerified.root).toBe(user); expect(state.lastVerified.body).toBe(userBody);
  expect(state.lastVerified.canonical).toBe(record.outbound);
  expect(state.lastVerified.fingerprint).toBe(record.fingerprint);

  const assistant = x.answer('Exact paired response');
  const oldCopy = assistant.children[1]; assistant.children = assistant.children.slice(0, 1);
  oldCopy.parentElement = null; oldCopy.connected = false;
  const outer = new Element('DIV', { 'data-content-search-turn-key': 'synthetic-owned-turn-key' });
  const pair = new Element('DIV', { 'data-talvt-turn-state': 'complete' });
  const row = new Element('DIV');
  const copy = new Element('BUTTON', { 'aria-label': 'Copy' });
  const companions = ['Rate response', 'Read aloud', 'Regenerate response'].map(label =>
    new Element('BUTTON', { 'aria-label': label }));
  row.append(copy, ...companions);
  outer.append(pair); x.f.messages.append(outer);
  moveFixtureElement(user, pair); moveFixtureElement(assistant, pair); pair.append(row);
  expect(user.compareDocumentPosition(assistant) & 4).toBe(4);
  expect(assistant.compareDocumentPosition(user) & 2).toBe(2);
  expect(assistant.compareDocumentPosition(row) & 4).toBe(4);
  expect(pair.compareDocumentPosition(user)).toBe(4 | 16);
  expect(user.compareDocumentPosition(pair)).toBe(2 | 8);
  return { x, record, choice, user, userBody, assistant, outer, pair, row, copy, companions };
}

describe('ChatGPT named paired-turn Copy association', () => {
  test('a named completed paired turn admits its owned sibling Copy row after real submission binding', async () => {
    const p = await pairedChatGPTFooterFixture();
    const observed = await p.x.observe(p.record, { deferModelVerification: false });
    expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
    expect(observed.submissionProof).toEqual({ sequence: 1, fingerprint: p.record.fingerprint });
    expect(observed.modelEvidence.selected).toEqual(p.choice);
    expect(observed.text).toBe(JSON.stringify({ type: 'message', text: 'Exact paired response' }));
    expect({ answerComplete: observed.answerComplete, responseCount: observed.responseCount,
      userCount: observed.userCount, scopedCopies: observed.completionEvidence.scopedCopies,
      enabledCopies: observed.completionEvidence.enabledCopies }).toEqual({ answerComplete: true,
      responseCount: 1, userCount: 1, scopedCopies: 1, enabledCopies: 1 });
    expect(observed.completionEvidence.footerAssociation).toBe('paired_turn');
    expect(p.x.send.clicks).toBe(1); expect(p.copy.clicks).toBe(0);
    expect(p.companions.every(button => button.clicks === 0)).toBe(true);
    // Native's deadline-only diagnostic deliberately omits submission proof
    // inputs. False here means no proved scope, not that no Copy exists in DOM.
    expect(await p.x.f.diagnose()).toMatchObject({ failureDiagnostic: { copyPresent: false, copyEnabled: false } });
  });

  test('paired Copy never uses incomplete cancelled generic or ambiguous named turns', async () => {
    for (const mutation of ['in_progress', 'cancelled', 'unknown', 'missing_state', 'generic', 'missing_key',
      'empty_key', 'oversized_key', 'comparison', 'second_assistant', 'hidden_assistant', 'outer_assistant',
      'hidden_outer_assistant', 'named_ancestor', 'nested_outer']) {
      const p = await pairedChatGPTFooterFixture();
      if (['in_progress', 'cancelled', 'unknown'].includes(mutation)) p.pair.values['data-talvt-turn-state'] = mutation;
      if (['missing_state', 'generic'].includes(mutation)) delete p.pair.values['data-talvt-turn-state'];
      if (['missing_key', 'generic'].includes(mutation)) delete p.outer.values['data-content-search-turn-key'];
      if (mutation === 'empty_key') p.outer.values['data-content-search-turn-key'] = '';
      if (mutation === 'oversized_key') p.outer.values['data-content-search-turn-key'] = 'K'.repeat(1025);
      if (mutation === 'comparison') p.outer.append(new Element('DIV', { 'data-talvt-turn-state': 'complete' }));
      if (['second_assistant', 'hidden_assistant', 'outer_assistant', 'hidden_outer_assistant'].includes(mutation)) {
        const other = new Element('ARTICLE', { 'data-turn': 'assistant' });
        other.append(new Element('DIV', { 'data-markdown-text-style': 'assistant-message' }, 'Foreign response'));
        if (mutation.includes('hidden')) other.cssVisibility = 'hidden';
        (mutation.includes('outer') ? p.outer : p.pair).append(other);
      }
      if (['named_ancestor', 'nested_outer'].includes(mutation)) {
        const wrapper = new Element('DIV', mutation === 'named_ancestor' ? { 'data-talvt-turn-state': 'complete' }
          : { 'data-content-search-turn-key': 'foreign-enclosing-turn-key' });
        p.x.f.messages.append(wrapper); moveFixtureElement(p.outer, wrapper);
      }
      const observed = await p.x.observe(p.record, { deferModelVerification: true });
      expect(observed.error).toBeUndefined(); expect(observed.answerComplete).toBe(false);
      expect(observed.completionEvidence.scopedCopies).toBe(0);
      expect(observed).not.toHaveProperty('modelEvidence'); expect(p.x.send.clicks).toBe(1);
    }
  });

  test('paired Copy refuses foreign page content and split semantic footer controls', async () => {
    for (const mutation of ['outer', 'main', 'body', 'foreign_pair', 'user', 'pre', 'code', 'quote', 'tool', 'tool_turn', 'markdown',
      'editable', 'form', 'input', 'textarea', 'select', 'before_answer', 'split_companions', 'duplicate_labels',
      'hidden_companions', 'duplicate_copy', 'prose']) {
      const p = await pairedChatGPTFooterFixture();
      if (mutation === 'outer') moveFixtureElement(p.row, p.outer);
      if (mutation === 'main') moveFixtureElement(p.row, p.x.f.messages);
      if (mutation === 'body') moveFixtureElement(p.row, p.x.f.body);
      if (mutation === 'foreign_pair') {
        const foreign = new Element('DIV', { 'data-talvt-turn-state': 'complete' });
        p.outer.append(foreign); moveFixtureElement(p.row, foreign);
      }
      if (mutation === 'user') moveFixtureElement(p.row, p.user);
      if (['pre', 'code', 'quote', 'tool', 'tool_turn', 'markdown', 'editable'].includes(mutation)) {
        const content = new Element(mutation === 'pre' ? 'PRE' : mutation === 'code' ? 'CODE'
          : mutation === 'quote' ? 'BLOCKQUOTE' : 'DIV', mutation === 'tool' ? { 'data-message-author-role': 'tool' }
            : mutation === 'tool_turn' ? { 'data-turn': 'tool' } : mutation === 'markdown' ? { class: 'markdown' }
            : mutation === 'editable' ? { contenteditable: 'true' } : {});
        p.pair.append(content); moveFixtureElement(p.row, content);
      }
      if (mutation === 'form') {
        const form = new Element('FORM'); p.pair.append(form); moveFixtureElement(p.row, form);
      }
      if (['input', 'textarea', 'select'].includes(mutation)) p.row.append(new Element(mutation.toUpperCase()));
      if (mutation === 'before_answer') p.pair.children = [p.user, p.row, p.assistant];
      if (mutation === 'split_companions') {
        const other = new Element('DIV'); p.pair.children.unshift(other); other.parentElement = p.pair;
        moveFixtureElement(p.companions[1], other); moveFixtureElement(p.companions[2], other);
      }
      if (mutation === 'duplicate_labels') p.companions.forEach(button => { button.values['aria-label'] = 'Rate response'; });
      if (mutation === 'hidden_companions') p.companions.slice(1).forEach(button => { button.cssVisibility = 'hidden'; });
      if (mutation === 'duplicate_copy') p.row.append(new Element('BUTTON', { 'aria-label': 'Copy' }));
      if (mutation === 'prose') p.row.append(new Element('P', {}, 'Unrelated authored content'));
      const observed = await p.x.observe(p.record, { deferModelVerification: true });
      expect(observed.error).toBeUndefined(); expect(observed.answerComplete).toBe(false);
      expect(observed.completionEvidence.scopedCopies).toBe(0);
      expect(observed).not.toHaveProperty('modelEvidence'); expect(p.x.send.clicks).toBe(1);
    }
  });

  test('paired Copy cannot replace the verified current user or its canonical body', async () => {
    for (const mutation of ['foreign_user', 'canonical_body']) {
      const p = await pairedChatGPTFooterFixture();
      if (mutation === 'foreign_user') {
        moveFixtureElement(p.user, p.x.f.messages);
        const foreign = new Element('ARTICLE', { 'data-turn': 'user' });
        foreign.append(new Element('DIV', { class: 'whitespace-pre-wrap' }, 'Foreign request')); p.pair.children.unshift(foreign);
        foreign.parentElement = p.pair;
      } else p.userBody.text += ' changed after binding';
      const observed = await p.x.observe(p.record, { deferModelVerification: false });
      expect(observed.error).toBe('conversation_changed'); expect(observed).not.toHaveProperty('modelEvidence');
      expect(observed).not.toHaveProperty('submissionProof'); expect(p.x.send.clicks).toBe(1);
    }
    for (const mutation of ['sequence', 'marker', 'url']) {
      const p = await pairedChatGPTFooterFixture();
      const observed = await p.x.observe(p.record, { deferModelVerification: false, ...(mutation === 'sequence'
        ? { submissionSequence: 2 } : mutation === 'marker' ? { submissionMarker: '00000000-0000-4000-8000-000000000009' }
          : { expectedURL: 'https://chatgpt.com/c/foreign-document' }) });
      expect(observed.error).toBeDefined(); expect(observed).not.toHaveProperty('modelEvidence');
      expect(observed).not.toHaveProperty('submissionProof'); expect(p.x.send.clicks).toBe(1);
    }
    const p = await pairedChatGPTFooterFixture();
    const second = await p.x.dispatch('Second exact native submission', { deferModelVerification: true });
    const bound = await p.x.observe(second, { deferModelVerification: true });
    expect(bound.error).toBeUndefined(); expect(bound.submissionProof).toEqual({ sequence: 2, fingerprint: second.fingerprint });
    const secondUser = p.x.f.document.querySelectorAll('article[data-turn="user"]')[1];
    expect((p.x.f.world.__computaChatSubmissionState as any).lastVerified.root).toBe(secondUser);
    // Keep a structurally convincing old footer with user1, but make its answer
    // the latest response to user2. Global user count and native proofs stay valid.
    moveFixtureElement(p.assistant, p.x.f.messages);
    p.x.f.messages.children = [p.assistant, ...p.x.f.messages.children.filter(node => node !== p.assistant)];
    const assistant = p.x.answer('Second response beside stale first-user footer'), oldCopy = assistant.children[1];
    assistant.children = assistant.children.slice(0, 1); oldCopy.connected = false; oldCopy.parentElement = null;
    moveFixtureElement(assistant, p.pair); p.pair.children = [p.user, assistant, p.row];
    const observed = await p.x.observe(second, { deferModelVerification: true });
    expect(observed.error).toBeUndefined(); expect(observed.submissionProof).toEqual({ sequence: 2, fingerprint: second.fingerprint });
    expect(observed.userCount).toBe(2); expect(observed.responseCount).toBe(2);
    expect(observed.answerComplete).toBe(false); expect(observed.completionEvidence.scopedCopies).toBe(0);
    expect(observed).not.toHaveProperty('modelEvidence'); expect(p.x.send.clicks).toBe(2); expect(p.copy.clicks).toBe(0);
  });

  test('paired Copy row pair state key and companion identities are revalidated after the final picker await', async () => {
    for (const mutation of ['replace_row', 'move_row', 'replace_pair', 'outer_key', 'cancelled', 'move_copy', 'hide_companion', 'replace_companion']) {
      const p = await pairedChatGPTFooterFixture(), picker: any = p.x.picker;
      let opens = 0; const open = picker.trigger.onClick;
      picker.trigger.onClick = () => {
        open(); if (++opens !== 2) return;
        if (mutation === 'replace_row') {
          const replacement = new Element('DIV'); p.pair.children = p.pair.children.filter(node => node !== p.row);
          p.pair.append(replacement); for (const child of [...p.row.children]) moveFixtureElement(child, replacement);
          p.row.parentElement = null; p.row.connected = false;
        }
        if (mutation === 'move_row') moveFixtureElement(p.row, p.outer);
        if (mutation === 'replace_pair') {
          const replacement = new Element('DIV', { ...p.pair.values }); p.outer.children = [replacement]; replacement.parentElement = p.outer;
          for (const child of [...p.pair.children]) moveFixtureElement(child, replacement);
          p.pair.parentElement = null; p.pair.connected = false;
        }
        if (mutation === 'outer_key') p.outer.values['data-content-search-turn-key'] = 'different-owned-turn-key';
        if (mutation === 'cancelled') p.pair.values['data-talvt-turn-state'] = 'cancelled';
        if (mutation === 'move_copy') { const other = new Element('DIV'); p.pair.append(other); moveFixtureElement(p.copy, other); }
        if (mutation === 'hide_companion') p.companions[0].cssVisibility = 'hidden';
        if (mutation === 'replace_companion') {
          const old = p.companions[0], replacement = new Element('BUTTON', { ...old.values });
          p.row.children[p.row.children.indexOf(old)] = replacement; replacement.parentElement = p.row;
          old.parentElement = null; old.connected = false;
        }
      };
      const observed = await p.x.observe(p.record, { deferModelVerification: false });
      expect(opens).toBe(2); expect(observed).toMatchObject({ error: 'conversation_changed', detail: 'response_changed' });
      expect(observed).not.toHaveProperty('modelEvidence'); expect(observed).not.toHaveProperty('submissionProof');
      expect(p.x.send.clicks).toBe(1); expect(p.copy.clicks).toBe(0);
    }
  });
});

describe('ChatGPT terminal completion admission', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const conversationID = '6ad86c7a-2284-8331-b846-a59490db0c46';
  const messageID = 'cea6201b-846d-404a-b4dc-f974e184065a';
  const stage = async (pathname = '/c/' + conversationID) => {
    const x = await chatTurnFixture(choice), click = x.send.onClick!;
    x.send.onClick = () => { click(); x.f.location.pathname = pathname;
      x.f.document.URL = 'https://chatgpt.com' + x.f.location.pathname + '?temporary-chat=true'; };
    const record = await x.dispatch('Exact terminal candidate request', { deferModelVerification: true });
    const answer = x.answer('Complete source text');
    answer.values['data-chatgpt-selection-message-id'] = messageID;
    const pending = await x.observe(record, { deferModelVerification: true });
    expect(pending.error).toBeUndefined(); expect(pending.answerComplete).toBe(true);
    const candidate = { correlationID: '245e3c88-8dac-4239-947b-1aff997b9f61', sequence: 1,
      inputSHA256: createHash('sha256').update(record.outbound).digest('hex'),
      inputMessageID: 'ae2e44b2-714e-43cd-ba07-d5c3f09c9463', conversationID, messageID, text: pending.text };
    return { x, record, answer, candidate };
  };
  test('exact current terminal text and message identity still obtain fresh full model proof', async () => {
    const p = await stage(), before = p.x.picker!.trigger.clicks;
    const result = await p.x.observe(p.record, { deferModelVerification: false, terminalCompletionCandidate: p.candidate });
    expect(result.error).toBeUndefined(); expect(result.terminalCompletionMatched).toBe(true);
    expect(result.terminalCompletionDiagnostic).toEqual({ reason: 'matched', routeKind: 'server' });
    expect(result.modelEvidence.selected).toEqual(choice); expect(result.submissionProof.fingerprint).toBe(p.record.fingerprint);
    expect(p.x.picker!.trigger.clicks).toBeGreaterThan(before); expect(p.x.send.clicks).toBe(1);
  });
  test('finite diagnostics identify the first failing terminal check without granting proof', async () => {
    for (const mutation of ['absent', 'local', 'conversation', 'context', 'text', 'assistant_id']) {
      const p = await stage(mutation === 'local'
        ? '/c/local-chatgpt%3A11111111-1111-4111-8111-111111111111' : '/c/' + conversationID);
      const candidate: any = { ...p.candidate };
      if (mutation === 'conversation') candidate.conversationID = p.candidate.inputMessageID;
      if (mutation === 'context') candidate.sequence = 2;
      if (mutation === 'text') candidate.text += ' changed bytes';
      if (mutation === 'assistant_id') candidate.messageID = p.candidate.inputMessageID;
      const result = await p.x.observe(p.record, { deferModelVerification: true,
        ...(mutation === 'absent' ? {} : { terminalCompletionCandidate: candidate }) });
      const reason = mutation === 'absent' ? 'absent_candidate' : mutation === 'local' || mutation === 'conversation'
        ? 'route_mismatch' : mutation === 'context' ? 'context_invalid' : mutation === 'text' ? 'text_relation' : 'assistant_id';
      expect(result.error, mutation).toBeUndefined();
      expect(result.terminalCompletionDiagnostic, mutation).toEqual({ reason, routeKind: mutation === 'local' ? 'local' : 'server' });
      expect(Object.keys(result.terminalCompletionDiagnostic).sort()).toEqual(['reason', 'routeKind']);
      expect(result.terminalCompletionMatched, mutation).toBeUndefined();
      expect(result.terminalCompletionRepresentation, mutation).toBeUndefined();
      expect(result.modelEvidence, mutation).toBeUndefined(); expect(p.x.send.clicks).toBe(1);
    }
  });
  test('diagnostics are fresh and do not decorate busy or failed reads', async () => {
    const p = await stage();
    const matched = await p.x.observe(p.record, { deferModelVerification: true, terminalCompletionCandidate: p.candidate });
    expect(matched.terminalCompletionDiagnostic).toEqual({ reason: 'matched', routeKind: 'server' });
    const missing = await p.x.observe(p.record, { deferModelVerification: true });
    expect(missing.terminalCompletionDiagnostic).toEqual({ reason: 'absent_candidate', routeKind: 'server' });
    expect(missing.terminalCompletionMatched).toBeUndefined(); expect(missing.terminalCompletionRepresentation).toBeUndefined();
    p.x.f.body.append(new Element('BUTTON', { 'data-testid': 'stop-button' }));
    const busy = await p.x.observe(p.record, { deferModelVerification: true, terminalCompletionCandidate: p.candidate });
    expect(busy.terminalCompletionDiagnostic).toBeUndefined(); expect(busy.terminalCompletionMatched).toBeUndefined();
    p.x.f.world.__computaModelOwner = 'foreign-owner';
    const failed = await p.x.observe(p.record, { deferModelVerification: true, terminalCompletionCandidate: p.candidate });
    expect(failed.error).toBeDefined(); expect(failed.terminalCompletionDiagnostic).toBeUndefined(); expect(p.x.send.clicks).toBe(1);
  });
  test('terminal data does not qualify partial or different DOM, wrong identity, stale sequence, or missing completion controls', async () => {
    for (const mutation of ['empty', 'partial', 'message_id', 'conversation_id', 'sequence', 'footer', 'busy', 'fenced_source', 'extra_key']) {
      const p = await stage(), candidate: any = { ...p.candidate };
      if (mutation === 'empty') p.answer.children[0].text = '';
      if (mutation === 'partial') p.answer.children[0].text = p.candidate.text.slice(0, -2);
      if (mutation === 'message_id') p.answer.values['data-chatgpt-selection-message-id'] = p.candidate.inputMessageID;
      if (mutation === 'conversation_id') candidate.conversationID = p.candidate.inputMessageID;
      if (mutation === 'sequence') candidate.sequence = 2;
      if (mutation === 'footer') p.answer.children[1].disabled = true;
      if (mutation === 'busy') p.x.f.body.append(new Element('BUTTON', { 'data-testid': 'stop-button' }));
      if (mutation === 'fenced_source') candidate.text = '```json\n' + candidate.text + '\n```';
      if (mutation === 'extra_key') candidate.authorized = true;
      const result = await p.x.observe(p.record, { deferModelVerification: true, terminalCompletionCandidate: candidate });
      expect(result.terminalCompletionMatched, mutation).toBeUndefined(); expect(p.x.send.clicks).toBe(1);
    }
  });
  test('message ID and exact text are rechecked after the last picker await', async () => {
    for (const mutation of ['message_id', 'text', 'model', 'owner']) {
      const p = await stage(), picker: any = p.x.picker, open = picker.trigger.onClick;
      let opens = 0;
      picker.trigger.onClick = () => { open(); if (++opens !== 2) return;
        if (mutation === 'message_id') p.answer.values['data-chatgpt-selection-message-id'] = p.candidate.inputMessageID;
        if (mutation === 'text') p.answer.children[0].text += ' late text';
        if (mutation === 'model') picker.selected('High');
        if (mutation === 'owner') p.x.f.world.__computaModelOwner = 'foreign-owner'; };
      const result = await p.x.observe(p.record, { deferModelVerification: false, terminalCompletionCandidate: p.candidate });
      expect(opens).toBe(2); expect(result.terminalCompletionMatched, mutation).toBeUndefined(); expect(p.x.send.clicks).toBe(1);
    }
  });
});

describe('ChatGPT literal terminal source equivalence', () => {
  const messageID = 'cea6201b-846d-404a-b4dc-f974e184065a';
  const start = source.indexOf('function chatGPTSingleJSONFence(text) {');
  const end = source.indexOf('function chatGPTTerminalCompletionMatches(observed) {', start);
  const extractionStart = source.indexOf('function modelResponseExtraction(answer) {');
  const extractionEnd = source.indexOf('function modelResponseText(', extractionStart);
  const read = new Function('rawSource', 'answer', 'messageID', 'getComputedStyle',
    source.slice(start, end) + source.slice(extractionStart, extractionEnd)
      + 'const extraction=modelResponseExtraction(answer);return {relation:chatGPTTerminalResponseTextRelation(rawSource,answer,extraction,messageID),text:extraction.text,flags:extraction.flags};');
  const style = (node: any, pseudo?: string) => ({ visibility: node.cssVisibility || 'visible',
    display: node.literalDisplay || (node.getAttribute('hidden') !== null ? 'none' : 'block'),
    opacity: node.literalOpacity || '1', content: pseudo === '::before' ? node.beforeContent : node.afterContent });
  const wrap = (body: string) => '```json\n' + body + '\n```';
  function literal(body: string) {
    const answer = new Element('DIV', { 'data-markdown-text-style': 'assistant-message' });
    const copy = new Element('DIV', { class: 'my-4', 'data-dil-source-message-id': messageID,
      'data-chatgpt-copy-reference': '0', 'data-markdown-copy': 'contents' });
    const layout = new Element('DIV', { class: 'layout' }), hidden = new Element('DIV', { hidden: '' });
    const portal = new Element('DIV', { class: 'relative PortalBoundary-TFj9W2 Renderer-ojZscX', 'data-theme': 'light', style: '--puik-portal-zoom: 1;' });
    const dil = new Element('DIV', { class: 'DilRenderer-tB76Jj DilResponseRoot-HfQrEh Reveal-k2IWvM',
      dir: 'auto', 'data-d-inline-reveal': '', 'data-d-direction': 'col', 'data-dil-message-id': messageID });
    const p = new Element('P', { class: 'TextBase-hXhSqg Text-lIMP0_', 'data-d-text-flow': '', 'data-d-component': 'text' });
    const span = (text: string) => new Element('SPAN', { 'data-d-text-flow': 'word', 'data-d-stream-word': '' }, text);
    p.append(span('```json\n'), span(body + '\n'), span('```'));
    dil.append(p); portal.append(dil); layout.append(hidden, portal); copy.append(layout); answer.append(copy);
    Object.defineProperty(answer, 'innerText', { configurable: true, get: () => p.children.map(child => child.textContent.replace(/\r?\n$/, ' ')).join('') + '\n' });
    const raw = () => p.textContent;
    return { answer, copy, layout, hidden, portal, dil, p, span, raw,
      read: (value = '<escape>' + raw() + '</escape>') => read(value, answer, messageID, style) };
  }
  test('the actual three-span source preserves LF, JSON escapes and a single exact escape wrapper', () => {
    expect(start).toBeGreaterThan(0); expect(extractionStart).toBeGreaterThan(end);
    for (const envelope of [
      { type: 'message', text: 'HI' },
      { type: 'tool_calls', calls: [{ name: 'exec_command', arguments: { cmd: 'printf "quoted\\n"\npath="C:\\tmp\\file"' } }] },
    ]) {
      const raw = JSON.stringify(envelope), f = literal(raw), before = f.raw();
      expect(f.read().relation).toBe('dil_escaped_literal_json_fence');
      expect(f.read(f.raw()).relation).toBe('dil_literal_json_fence');
      expect(f.read().text).toBe('```json ' + raw + ' ```');
      expect(f.read().flags.selectedExtraction).toBe('rendered_fallback');
      expect(f.raw()).toBe(before); expect(f.raw()).toBe(wrap(raw));
    }
  });
  test('only an accepted sole literal code body can match one JSON fence, with its single presentation LF', () => {
    const raw = JSON.stringify({ type: 'tool_calls', calls: [{ name: 'exec_command', arguments: { cmd: 'echo "a\\n"' } }] });
    for (const text of [raw, raw + '\n', raw.replace(/\n/g, '\r\n') + '\r\n']) {
      const f = fixture(); observedChatGPTCodeBlock(f, text);
      expect(read(wrap(raw), f.answer, messageID, style).relation).toBe('json_code_fence');
      expect(read(wrap(raw).replace(/\n/g, '\r\n'), f.answer, messageID, style).relation).toBe('json_code_fence');
    }
    const f = fixture(); observedChatGPTCodeBlock(f, raw + '\n\n');
    expect(read(wrap(raw), f.answer, messageID, style).relation).toBeNull();
  });
  test('malformed, mixed-prose, multiple, non-json and ambiguous wrappers cannot use a representation mapping', () => {
    const f = literal('{"type":"message","text":"HI"}'), raw = f.raw();
    for (const value of ['Before\n' + raw, raw + '\nAfter', raw + '\n' + raw, raw.replace('```json', '```javascript'),
      raw.replace('```json', '```JSON'), raw.slice(0, -1), '<escape>' + raw, raw + '</escape>',
      '<escape><escape>' + raw + '</escape></escape>', '<ESCAPE>' + raw + '</ESCAPE>'])
      expect(f.read(value).relation, value).toBeNull();
    for (const value of ['{"type":"message",}', '{"type":"unknown","text":"HI"}', '[{"type":"message"}]',
      '{"type":"message","text":"<escape>literal</escape>"}', '{"type":"message","text":"literal ``` token"}'])
      expect(literal(value).read().relation, value).toBeNull();
  });
  test('hidden ancestors, extra attributes/nodes, pseudo content and mismatched message identities are excluded', () => {
    const mutations = [
      (f: ReturnType<typeof literal>) => { f.answer.values.inert = ''; },
      (f: ReturnType<typeof literal>) => { f.answer.values['aria-hidden'] = 'true'; },
      (f: ReturnType<typeof literal>) => { f.p.values.onclick = 'not invoked'; },
      (f: ReturnType<typeof literal>) => { f.p.children[0].values.style = 'display:none'; },
      (f: ReturnType<typeof literal>) => { f.p.children[0].beforeContent = '"extra"'; },
      (f: ReturnType<typeof literal>) => { f.hidden.text = 'Hidden extra'; },
      (f: ReturnType<typeof literal>) => { (f.hidden as any).literalDisplay = 'block'; f.hidden.values.hidden = 'false'; },
      (f: ReturnType<typeof literal>) => { f.layout.append(new Element('DIV', {}, 'Extra')); },
      (f: ReturnType<typeof literal>) => { f.p.children[0].append(new Element('B', {}, 'nested')); },
      (f: ReturnType<typeof literal>) => { f.dil.values['data-dil-message-id'] = firstMarker; },
      (f: ReturnType<typeof literal>) => { f.copy.values['data-dil-source-message-id'] = firstMarker; },
      (f: ReturnType<typeof literal>) => { f.copy.values['data-chatgpt-copy-reference'] = '1'; },
      (f: ReturnType<typeof literal>) => { f.portal.values.class = 'Renderer-ojZscX'; },
      (f: ReturnType<typeof literal>) => { (f.dil as any).literalOpacity = '0'; },
    ];
    for (const mutate of mutations) {
      const f = literal('{"type":"message","text":"HI"}'), raw = '<escape>' + f.raw() + '</escape>';
      mutate(f); expect(f.read(raw).relation, String(mutate)).toBeNull();
    }
  });
  test('presentation changes and late literal source changes cannot retain a prior relation', () => {
    const f = literal('{"type":"message","text":"HI"}'), raw = '<escape>' + f.raw() + '</escape>';
    expect(f.read(raw).relation).toBe('dil_escaped_literal_json_fence');
    Object.defineProperty(f.answer, 'innerText', { configurable: true, get: () => '```json  {"type":"message","text":"HI"} ```\n' });
    expect(f.read(raw).relation).toBeNull();
    Object.defineProperty(f.answer, 'innerText', { configurable: true, get: () => f.p.children.map(child => child.textContent.replace(/\r?\n$/, ' ')).join('') + '\n' });
    f.p.children[1].text = '{"type":"message","text":"CHANGED"}\n';
    expect(f.read(raw).relation).toBeNull();
  });
  test('a fenced DIL source still obtains full fresh proof and is rechecked after the last picker await', async () => {
    for (const mutation of ['none', 'raw_line_ending', 'dil_identity', 'extra_attribute']) {
      const choice = { key: 'chat/latest/medium', label: 'Medium' }, conversationID = '6ad86c7a-2284-8331-b846-a59490db0c46';
      const x = await chatTurnFixture(choice), click = x.send.onClick!;
      x.send.onClick = () => { click(); x.f.location.pathname = '/c/' + conversationID;
        x.f.document.URL = 'https://chatgpt.com' + x.f.location.pathname + '?temporary-chat=true'; };
      const record = await x.dispatch('Exact owned DIL terminal source', { deferModelVerification: true });
      const body = literal('{"type":"message","text":"HI"}'), root = x.answer('placeholder');
      root.children[0].connected = false; root.children[0] = body.answer; body.answer.parentElement = root;
      root.values['data-chatgpt-selection-message-id'] = messageID;
      const candidate = { correlationID: '245e3c88-8dac-4239-947b-1aff997b9f61', sequence: 1,
        inputSHA256: createHash('sha256').update(record.outbound).digest('hex'),
        inputMessageID: 'ae2e44b2-714e-43cd-ba07-d5c3f09c9463', conversationID, messageID,
        text: '<escape>' + body.raw() + '</escape>' };
      const picker: any = x.picker, open = picker.trigger.onClick; let opens = 0;
      picker.trigger.onClick = () => { open(); if (++opens !== 2) return;
        if (mutation === 'raw_line_ending') body.p.children[0].text = '```json\r\n';
        if (mutation === 'dil_identity') body.dil.values['data-dil-message-id'] = firstMarker;
        if (mutation === 'extra_attribute') body.p.values.onclick = 'not invoked'; };
      const observed = await x.observe(record, { deferModelVerification: false, terminalCompletionCandidate: candidate });
      expect(opens).toBe(2); expect(x.send.clicks).toBe(1);
      if (mutation === 'none') {
        expect(observed.error).toBeUndefined(); expect(observed.terminalCompletionMatched).toBe(true);
        expect(observed.terminalCompletionRepresentation).toBe('dil_escaped_literal_json_fence');
        expect(observed.modelEvidence.selected).toEqual(choice); expect(observed.submissionProof.fingerprint).toBe(record.fingerprint);
      } else {
        expect(observed.terminalCompletionMatched, mutation).toBeUndefined();
        expect(observed.terminalCompletionRepresentation, mutation).toBeUndefined();
      }
      expect(candidate.text).toBe('<escape>```json\n{"type":"message","text":"HI"}\n```</escape>');
    }
  });
});

describe('ChatGPT quiet completion precheck', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const stage = async () => {
    const x = await chatTurnFixture(choice);
    const record = await x.dispatch('Exact quiet candidate request', { deferModelVerification: true });
    const answer = x.answer('Exact quiet answer');
    const observed = await x.observe(record, { deferModelVerification: true });
    expect(observed.error).toBeUndefined(); expect(observed.answerComplete).toBe(true);
    expect(observed.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    const candidate = { text: observed.text, responseCount: observed.responseCount, userCount: observed.userCount };
    return { x, record, answer, candidate, picker: x.picker! };
  };

  test('exact current candidates run a fresh full proof for first and retained submissions', async () => {
    const p = await stage();
    for (let sequence = 1; sequence <= 2; sequence++) {
      const record = sequence === 1 ? p.record
        : await p.x.dispatch('Exact retained quiet candidate', { deferModelVerification: true });
      if (sequence === 2) p.x.answer('Retained quiet answer');
      const pending = await p.x.observe(record, { deferModelVerification: true });
      const before = p.picker.trigger.clicks;
      const full = await p.x.observe(record, { deferModelVerification: false,
        quietCompletionCandidate: { text: pending.text, responseCount: pending.responseCount, userCount: pending.userCount } });
      expect(full.error).toBeUndefined(); expect(full).not.toHaveProperty('modelVerificationPending');
      expect(full.modelEvidence.selected).toEqual(choice); expect(full.text).toBe(pending.text);
      expect(full.submissionProof).toEqual({ sequence, fingerprint: record.fingerprint });
      expect(p.picker.trigger.clicks).toBeGreaterThan(before); expect(p.x.send.clicks).toBe(sequence);
    }
  });

  test('changed body, busy state, missing footer and changed counts defer without opening the picker', async () => {
    for (const mutation of ['text', 'busy', 'disabled_copy', 'hidden_copy', 'missing_footer', 'extra_answer']) {
      const p = await stage(), before = p.picker.trigger.clicks;
      if (mutation === 'text') p.answer.children[0].text = JSON.stringify({ type: 'message', text: 'Changed quiet answer' });
      if (mutation === 'busy') p.x.f.body.append(new Element('BUTTON', { 'data-testid': 'stop-button' }));
      if (mutation === 'disabled_copy') p.answer.children[1].disabled = true;
      if (mutation === 'hidden_copy') p.answer.children[1].values.hidden = '';
      if (mutation === 'missing_footer') {
        p.answer.children[1].connected = false; p.answer.children = p.answer.children.slice(0, 1);
      }
      if (mutation === 'extra_answer') p.x.answer('Unrelated extra answer');
      const deferred = await p.x.observe(p.record, { deferModelVerification: false, quietCompletionCandidate: p.candidate });
      expect(deferred.error, mutation).toBeUndefined(); expect(deferred.modelVerificationPending, mutation).toBe(true);
      expect(deferred, mutation).not.toHaveProperty('modelEvidence');
      expect(deferred.submissionProof, mutation).toEqual({ sequence: 1, fingerprint: p.record.fingerprint });
      expect(p.picker.trigger.clicks, mutation).toBe(before); expect(p.x.send.clicks, mutation).toBe(1);
    }
  });

  test('candidate metadata has exact shape, finite integer counts and UTF8 bounds', async () => {
    const p = await stage(), before = p.picker.trigger.clicks;
    const invalid = [null, [], {}, { ...p.candidate, extra: true },
      { ...p.candidate, text: '' }, { ...p.candidate, text: 1 }, { ...p.candidate, text: 'é'.repeat(110_001) },
      ...[true, '1', 0, -1, 1.5, 10_001].map(value => ({ ...p.candidate, responseCount: value })),
      ...[true, '1', 0, -1, 1.5, 17, 2].map(value => ({ ...p.candidate, userCount: value }))];
    for (const candidate of invalid) {
      const rejected = await p.x.observe(p.record, { deferModelVerification: false, quietCompletionCandidate: candidate });
      expect(rejected.error).toBe('model_unverified'); expect(rejected).not.toHaveProperty('modelEvidence');
      expect(rejected).not.toHaveProperty('firstUserVerified');
    }
    expect(p.picker.trigger.clicks).toBe(before); expect(p.x.send.clicks).toBe(1);
  });

  test('candidate metadata cannot replace current model or ownership proof', async () => {
    for (const mutation of ['model', 'owner', 'submission']) {
      const p = await stage(), before = p.picker.trigger.clicks;
      if (mutation === 'model') p.picker.selected('High');
      if (mutation === 'owner') p.x.f.world.__computaModelOwner = 'foreign-owner';
      if (mutation === 'submission') (p.x.f.world.__computaChatSubmissionState as any).lastVerified.fingerprint = 'a'.repeat(64);
      const rejected = await p.x.observe(p.record, { deferModelVerification: false, quietCompletionCandidate: p.candidate });
      expect(rejected.error, mutation).toBeDefined(); expect(rejected, mutation).not.toHaveProperty('modelEvidence');
      expect(rejected, mutation).not.toHaveProperty('firstUserVerified');
      expect(p.picker.trigger.clicks, mutation).toBe(before); expect(p.x.send.clicks, mutation).toBe(1);
    }
  });
});

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

  test('closed generic chrome retains full menu proof through first Instant input Send and response', async () => {
    const instant = { key: 'chat/latest/instant', label: 'Instant' };
    const x = await chatTurnFixture(instant, firstMarker, true), picker: any = x.picker;
    const record = await x.dispatch('Synthetic generic-header request', { deferModelVerification: true });
    expect(x.send.clicks).toBe(1); expect(picker.primary.text).toBe('Thinking effort');
    const before = picker.trigger.clicks;
    x.answer('Verified synthetic response');
    const pending = await x.observe(record, { deferModelVerification: true });
    expect(pending.error).toBeUndefined(); expect(pending.modelVerificationPending).toBe(true);
    expect(pending).not.toHaveProperty('modelEvidence'); expect(picker.trigger.clicks).toBe(before);
    const complete = await x.observe(record, { deferModelVerification: false });
    expect(complete.error).toBeUndefined(); expect(complete.modelEvidence.selected).toEqual(instant);
    expect(complete.modelEvidence.chatSelection).toMatchObject({ family: { key: 'GPT-6' }, power: { key: 'instant' } });
    expect(complete.answerComplete).toBe(true); expect(complete.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    expect(picker.trigger.clicks).toBeGreaterThan(before); expect(x.send.clicks).toBe(1);
  });

  test('generic pending continuity never hides tracked power switch-and-restore or unknown header text', async () => {
    for (const condition of ['power_restore', 'unknown_header', 'unproved_generic']) {
      const instant = { key: 'chat/latest/instant', label: 'Instant' };
      const x = await chatTurnFixture(instant, firstMarker, true), picker: any = x.picker;
      const record = await x.dispatch('Synthetic guarded generic response', { deferModelVerification: true });
      x.answer('Unaccepted synthetic response');
      const pin = x.f.world.__computaChatPresetPin as any, before = picker.trigger.clicks;
      if (condition === 'power_restore') pin.semanticObserver.callback([{ type: 'attributes', target: picker.slider,
        attributeName: 'aria-valuenow', oldValue: '4' }]);
      if (condition === 'unknown_header') picker.primary.text = 'Unknown effort';
      if (condition === 'unproved_generic') delete pin.genericHeaderVerified;
      const rejected = await x.observe(record, { deferModelVerification: true });
      expect(rejected.error).toBeDefined(); expect(rejected).not.toHaveProperty('modelEvidence');
      expect(rejected).not.toHaveProperty('modelVerificationPending');
      expect(picker.trigger.clicks).toBe(before); expect(x.send.clicks).toBe(1);
    }
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
      if (mutation === 'unknown_power') picker.trigger.text = 'Unknown effort';
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

  describe('bound first-message display recovery', () => {
    const choice = { key: 'chat/latest/medium', label: 'Medium' };
    const allowance = { allowBoundFirstUserExpansion: true, allowFirstUserBinding: false,
      allowFirstUserExpansion: false, firstUserExpansionModelChoice: choice };
    const stage = async (initialExpansion = false) => {
      const x = await chatTurnFixture(choice), first = await x.dispatch('PRIVATE BOUND PROMPT\n' + 'x'.repeat(40_000));
      const record: any = (x.f.world.__computaChatSubmissionState as any).pending;
      const root = x.f.document.querySelectorAll('article[data-turn="user"]')[0], body = root.children[0];
      const expand = new Element('BUTTON', { 'aria-label': 'Show more' }); root.append(expand);
      expand.onClick = () => { body.text = first.outbound; };
      x.answer('Verified answer');
      if (initialExpansion) body.text = first.outbound.slice(0, 10_240);
      const bound = await x.observe(first, initialExpansion ? { allowFirstUserExpansion: true, firstUserExpansionModelChoice: choice } : {});
      expect(bound.error).toBeUndefined(); expect(bound.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
      body.text = first.outbound.slice(0, 10_240);
      x.f.document.URL = 'https://chatgpt.com/c/local-chatgpt%3Abound?temporary-chat=true';
      x.f.location.pathname = '/c/local-chatgpt%3Abound';
      return { x, first, record, root, body, expand };
    };
    const denied = (result: any) => {
      expect(result.error).toBeDefined(); expect(result).not.toHaveProperty('submissionProof');
      expect(result).not.toHaveProperty('firstUserVerified', true); expect(result).not.toHaveProperty('answerComplete', true);
      expect(result).not.toHaveProperty('text');
    };

    test('recovers a same-body post-binding collapse after native route adoption and freshly hashes all bytes', async () => {
      for (const initialExpansion of [false, true]) {
        const { x, first, body, expand } = await stage(initialExpansion);
        const oldClaim = x.f.world.__computaModelFirstExpansion, digestCount = x.f.digestInputs.length;
        const result = await x.observe(first, allowance);
        expect(result.error).toBeUndefined(); expect(result.firstUserFingerprint).toBe(first.fingerprint);
        expect(result.submissionProof).toEqual({ sequence: 1, fingerprint: first.fingerprint });
        expect(body.text).toBe(first.outbound); expect(expand.clicks).toBe(initialExpansion ? 2 : 1);
        expect(x.f.digestInputs.slice(digestCount).filter(text => text === first.outbound).length).toBeGreaterThanOrEqual(2);
        expect(x.f.world.__computaModelFirstExpansion).toBe(oldClaim);
        expect(x.f.world.__computaModelBoundFirstExpansion).toMatchObject({ outcome: 'expanded', verified: true });
        expect((await x.observe(first)).error).toBeUndefined(); expect(x.send.clicks).toBe(1);
      }
    });

    test('requires explicit bound inspection permission and current native/private submission pins', async () => {
      for (const mutation of ['permission', 'action', 'native_first', 'native_round', 'private_first', 'record_hash',
        'canonical', 'pending', 'sequence', 'choice', 'owner', 'route', 'temporary', 'product', 'suppressed']) {
        const { x, first, record, expand } = await stage(), overrides: any = { ...allowance };
        if (mutation === 'permission') overrides.allowBoundFirstUserExpansion = false;
        if (mutation === 'action') overrides.action = 'cleanup';
        if (mutation === 'native_first') overrides.expectedFirstUserFingerprint = '0'.repeat(64);
        if (mutation === 'native_round') overrides.expectedSubmissionProofs = [{ sequence: 1, fingerprint: '0'.repeat(64) }];
        if (mutation === 'private_first') (x.f.world.__computaModelFirstProof as any).fingerprint = '0'.repeat(64);
        if (mutation === 'record_hash') record.fingerprint = '0'.repeat(64);
        if (mutation === 'canonical') record.canonical = record.canonical.slice(0, 20_000) + '!' + record.canonical.slice(20_001);
        if (mutation === 'pending') (x.f.world.__computaChatSubmissionState as any).pending = { sequence: 2 };
        if (mutation === 'sequence') overrides.submissionSequence = 2;
        if (mutation === 'choice') overrides.firstUserExpansionModelChoice = { key: 'chat/latest/high', label: 'High' };
        if (mutation === 'owner') overrides.ownerToken = '00000000-0000-4000-8000-000000000000';
        if (mutation === 'route') overrides.expectedURL = 'https://chatgpt.com/c/foreign';
        if (mutation === 'temporary') x.f.temporary.values['aria-label'] = 'Temporary chat';
        if (mutation === 'product') x.f.workMode.values['aria-pressed'] = 'true';
        if (mutation === 'suppressed') overrides.suppressFirstUserExpansionClaim = true;
        denied(await x.observe(first, overrides)); expect(expand.clicks).toBe(0); expect(x.send.clicks).toBe(1);
      }
    });

    test('does not expand remounted roots or bodies and records finite physical identity facts', async () => {
      for (const mutation of ['root', 'body']) {
        const { x, first, root, body, expand } = await stage();
        if (mutation === 'root') replaceRoot(x);
        else {
          const replacement = new Element('DIV', { class: 'whitespace-pre-wrap' }, body.text);
          root.children = root.children.map(node => node === body ? replacement : node); replacement.parentElement = root;
          body.connected = false; body.parentElement = null;
        }
        const result = await x.observe(first, allowance); denied(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ allowBoundFirstUserExpansion: true,
          boundRootSame: mutation !== 'root', boundBodySame: false, boundNativePinMatches: true });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(expand.clicks).toBe(0); expect(x.send.clicks).toBe(1);
      }
    });

    test('failed display claims remain spent even if exact complete bytes appear on a later read', async () => {
      for (const mutation of ['wrong_suffix', 'no_control', 'ambiguous', 'body_after_click', 'owner_after_click', 'timeout']) {
        const { x, first, root, body, expand } = await stage();
        if (mutation === 'no_control') expand.connected = false;
        if (mutation === 'ambiguous') root.append(new Element('BUTTON', { 'aria-label': 'Show more' }));
        expand.onClick = () => {
          body.text = mutation === 'wrong_suffix' ? first.outbound + '!' : first.outbound;
          if (mutation === 'body_after_click') replaceRoot(x);
          if (mutation === 'owner_after_click') x.f.world.__computaModelOwner = 'foreign';
          if (mutation === 'timeout') x.f.advanceTime(2_000);
        };
        denied(await x.observe(first, allowance));
        const clicks = expand.clicks;
        body.text = first.outbound;
        denied(await x.observe(first, allowance)); expect(expand.clicks).toBe(clicks); expect(x.send.clicks).toBe(1);
        expect(x.f.world.__computaModelBoundFirstExpansion).not.toHaveProperty('verified', true);
      }
    });

    test('hash-await mutations never admit a recovered prefix or a changed full body', async () => {
      for (const mutation of ['prefix', 'body', 'root', 'record', 'private_pin', 'product']) {
        const { x, first, body, record, expand } = await stage();
        x.f.onDigest(() => {
          if (mutation === 'prefix') body.text = first.outbound.slice(0, 10_240);
          if (mutation === 'body') body.text = first.outbound + '!';
          if (mutation === 'root') replaceRoot(x);
          if (mutation === 'record') record.fingerprint = '0'.repeat(64);
          if (mutation === 'private_pin') (x.f.world.__computaModelFirstProof as any).fingerprint = '0'.repeat(64);
          if (mutation === 'product') x.f.workMode.values['aria-pressed'] = 'true';
        }, first.outbound);
        denied(await x.observe(first, allowance)); expect(expand.clicks).toBe(1); expect(x.send.clicks).toBe(1);
        body.text = first.outbound; denied(await x.observe(first, allowance));
      }
    });

    test('a successful bound display recovery never grants another expansion or blocks a verified later submission', async () => {
      const { x, first, body, expand } = await stage();
      expect((await x.observe(first, allowance)).error).toBeUndefined();
      body.text = first.outbound.slice(0, 10_240); denied(await x.observe(first, allowance));
      expect(expand.clicks).toBe(1); expect(x.send.clicks).toBe(1);
      body.text = first.outbound;
      const next = await x.dispatch('A separate authorized continuation'); x.answer('Next verified answer');
      expect((await x.observe(next)).submissionProof).toEqual({ sequence: 2, fingerprint: next.fingerprint });
      expect(x.send.clicks).toBe(2); expect(expand.clicks).toBe(1);
    });
  });

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

  test('a URL-crossed submission digest is discarded without poisoning the fresh native read', async () => {
    const choice = { key: 'chat/latest/medium', label: 'Medium' };
    const x = await chatTurnFixture(choice);
    const click = x.send.onClick!;
    x.send.onClick = () => { click(); x.f.document.URL = 'https://chatgpt.com/c/local-chatgpt%3Afixture?temporary-chat=true';
      x.f.location.pathname = '/c/local-chatgpt%3Afixture'; };
    const record = await x.dispatch('Exact route-bound request', { deferModelVerification: true }); x.answer('Owned answer');
    let promoted = false;
    const promoteAtSubmissionDigest = () => {
      if (!x.f.world.__computaModelFirstProof) { x.f.onDigest(promoteAtSubmissionDigest, record.outbound); return; }
      promoted = true; x.f.document.URL = 'https://chatgpt.com/c/public-fixture?temporary-chat=true';
      x.f.location.pathname = '/c/public-fixture';
    };
    x.f.onDigest(promoteAtSubmissionDigest, record.outbound);
    const crossed = await x.observe(record, { deferModelVerification: true });
    const state: any = x.f.world.__computaChatSubmissionState;
    expect(promoted).toBe(true); expect(state.pending.phase).toBe('send_claimed');
    expect(state.pending.root).toBeNull(); expect(state.revoked).toBe(false);
    expect(crossed).toMatchObject({ error: 'document_changed', detail: 'model_read_context' });
    expect(crossed).not.toHaveProperty('submissionProof'); expect(crossed).not.toHaveProperty('text');
    // Only Native can authorize a fresh invocation for the new URL. This
    // fixture supplies that next structured input; no crossed read succeeds.
    const fresh = await x.observe(record);
    expect(fresh.error).toBeUndefined();
    expect(fresh.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    expect(fresh.modelEvidence.selected).toEqual(choice);
    expect(fresh.answerComplete).toBe(true); expect(x.send.clicks).toBe(1);
  });

  test('a discarded URL-crossed digest cannot excuse changed body, owner or native pin on the fresh read', async () => {
    for (const mutation of ['body', 'owner', 'pin']) {
      const x = await chatTurnFixture();
      const record = await x.dispatch('Exact request requiring independent fresh proof'); x.answer('Owned answer');
      let crossed = false;
      const mutateAtSubmissionDigest = () => {
        if (!x.f.world.__computaModelFirstProof) { x.f.onDigest(mutateAtSubmissionDigest, record.outbound); return; }
        crossed = true; x.f.document.URL = 'https://chatgpt.com/c/public-fixture?temporary-chat=true';
        x.f.location.pathname = '/c/public-fixture';
        if (mutation === 'body') x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0].text += '!';
        if (mutation === 'owner') x.f.world.__computaModelOwner = 'foreign';
        if (mutation === 'pin') (x.f.world.__computaChatSubmissionState as any).pending.fingerprint = '0'.repeat(64);
      };
      x.f.onDigest(mutateAtSubmissionDigest, record.outbound);
      const discarded = await x.observe(record); expect(crossed).toBe(true);
      expect(discarded.error).toBeDefined(); expect(discarded).not.toHaveProperty('submissionProof');
      const fresh = await x.observe(record);
      expect(fresh.error).toBeDefined(); expect(fresh).not.toHaveProperty('submissionProof');
      expect(fresh).not.toHaveProperty('answerComplete', true); expect(x.send.clicks).toBe(1);
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

describe('ChatGPT optimistic submission body deferral', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const optimistic = (x: Awaited<ReturnType<typeof chatTurnFixture>>, record: { sequence: number; outbound: string }) => {
    const old = x.f.document.querySelectorAll('article[data-turn="user"]')[record.sequence - 1];
    const root = new Element('DIV', { 'data-user-message-bubble': 'true' });
    const body = new Element('SPAN', { class: 'text-size-chat leading-relaxed whitespace-pre-wrap' }, record.outbound);
    const svg = new Element('SVG', { 'aria-hidden': 'true', focusable: 'false',
      class: 'pointer-events-none absolute inset-0 h-full w-full temporaryOutline-bbkcxS' });
    const rect = new Element('RECT', { x: '0.5', y: '0.5', width: 'calc(100% - 1px)', height: 'calc(100% - 1px)',
      fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.4', 'stroke-width': '1',
      'stroke-dasharray': '8 8', 'vector-effect': 'non-scaling-stroke' });
    svg.append(rect); root.append(svg, body);
    const parent = old.parentElement!, index = parent.children.indexOf(old);
    parent.children[index] = root; root.parentElement = parent; old.connected = false;
    return { root, body, svg, rect, parent, index,
      remount(clipped = false) {
        const durable = new Element('ARTICLE', { 'data-turn': 'user' });
        const currentBody = new Element('DIV', { class: 'whitespace-pre-wrap' }, clipped ? record.outbound.slice(0, 10_240) : record.outbound);
        durable.append(currentBody); parent.children[index] = durable; durable.parentElement = parent; root.connected = false;
        const more = new Element('BUTTON', { 'aria-label': 'Show more' });
        more.onClick = () => { currentBody.text = record.outbound; }; if (clipped) durable.append(more);
        return { root: durable, body: currentBody, more };
      } };
  };
  test('first optimistic full echo stays negative without hashing or pinning and normal DIV binds once', async () => {
    const x = await chatTurnFixture(choice), record = await x.dispatch('Owned optimistic first ' + 'A'.repeat(11_000));
    const o = optimistic(x, record); x.answer('Final');
    x.f.temporary.values['aria-hidden'] = 'true'; // Actual post-Send page has only the scoped outline witness.
    const state: any = x.f.world.__computaChatSubmissionState, pending = state.pending;
    const hashes = x.f.digestInputs.length, timers = x.f.scheduledDelays.length;
    for (const action of ['inspect', 'verifyModel', 'verifyProductMode', 'inspect']) {
      expect(await x.observe(record, { action })).toEqual({ error: 'submission_observation_pending', detail: 'optimistic_user_body',
        submissionSequence: 1, submissionFingerprint: record.fingerprint });
      expect(state.pending).toBe(pending); expect(pending.phase).toBe('send_claimed'); expect(state.lastVerified).toBeNull();
      expect(pending.root).toBeNull(); expect(pending.body).toBeNull(); expect(pending.expansionAttempted).toBe(false);
      expect(x.f.world.__computaModelFirstProof).toBeUndefined(); expect(x.f.world.__computaModelFirstExpansion).toBeUndefined();
    }
    expect(x.f.digestInputs.length).toBe(hashes); expect(x.f.scheduledDelays.length).toBe(timers); expect(x.send.clicks).toBe(1);
    delete x.f.temporary.values['aria-hidden'];
    o.remount(); const result = await x.observe(record);
    expect(result.error).toBeUndefined(); expect(result.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    expect(state.pending).toBeNull(); expect(state.lastVerified.phase).toBe('verified'); expect(x.send.clicks).toBe(1);
  });
  test('first and retained optimistic echoes allow the existing one-click clipped DIV expansion after remount', async () => {
    for (const sequence of [1, 2]) {
      const x = await chatTurnFixture(choice);
      if (sequence === 2) { const first = await x.dispatch('Prior verified request'); x.answer('First'); await x.observe(first); }
      const record = await x.dispatch('Owned optimistic clipped ' + 'A'.repeat(11_000)), o = optimistic(x, record); x.answer('Final');
      const state: any = x.f.world.__computaChatSubmissionState, parent = state.lastVerified;
      for (let read = 0; read < 2; read++) {
        expect(await x.observe(record, { deferModelVerification: true })).toMatchObject({ error: 'submission_observation_pending', submissionSequence: sequence });
        expect(state.lastVerified).toBe(parent); expect(state.pending.phase).toBe('send_claimed');
      }
      const d = o.remount(true); x.f.setHit(d.more);
      const result = await x.observe(record, { deferModelVerification: true, allowFirstUserExpansion: true,
        firstUserExpansionModelChoice: choice, allowSubmissionExpansion: true });
      expect(result.error).toBeUndefined(); expect(result.submissionProof).toEqual({ sequence, fingerprint: record.fingerprint });
      expect(d.more.clicks).toBe(1); expect(x.send.clicks).toBe(sequence);
      expect((await x.observe(record, { deferModelVerification: true })).error).toBeUndefined(); expect(d.more.clicks).toBe(1);
    }
  });
  test('the original containing DIV layout may verify a selected SPAN body normally', async () => {
    const x = await chatTurnFixture(choice), record = await x.dispatch('Known normal containing DIV request');
    const o = optimistic(x, record); x.answer('Final');
    const content = new Element('DIV'); content.append(o.body); o.root.children = [o.svg, content]; content.parentElement = o.root;
    const result = await x.observe(record);
    expect(result.error).toBeUndefined(); expect(result.submissionProof).toEqual({ sequence: 1, fingerprint: record.fingerprint });
    expect((x.f.world.__computaChatSubmissionState as any).pending).toBeNull(); expect(x.send.clicks).toBe(1);
  });
  test('explicit post-Send product-only recheck cannot pin optimistic or durable first and retained bodies', async () => {
    for (const sequence of [1, 2]) for (const shape of ['optimistic', 'durable']) {
      const x = await chatTurnFixture(choice);
      if (sequence === 2) { const first = await x.dispatch('Prior verified product request'); x.answer('First'); await x.observe(first); }
      const record = await x.dispatch('Current product-only request'), o = optimistic(x, record); x.answer('Final');
      if (shape === 'durable') o.remount();
      const state: any = x.f.world.__computaChatSubmissionState, pending = state.pending, parent = state.lastVerified;
      const firstProof = x.f.world.__computaModelFirstProof, hashes = x.f.digestInputs.length;
      const result = await x.observe(record, { action: 'verifyProductMode', allowFirstUserBinding: false,
        pendingSubmissionProductRecheck: { sequence, fingerprint: record.fingerprint } });
      expect(Object.keys(result).sort()).toEqual(['chatModeActionAvailable', 'chatModeReady', 'productModeEvidence', 'temporary']);
      expect(result).toMatchObject({ chatModeReady: true, temporary: true, productModeEvidence: { temporaryTransition: 'acknowledged' } });
      expect(x.f.digestInputs.length).toBe(hashes); expect(state.pending).toBe(pending); expect(state.lastVerified).toBe(parent);
      expect(pending.phase).toBe('send_claimed'); expect(pending.root).toBeNull(); expect(pending.body).toBeNull();
      expect(x.f.world.__computaModelFirstProof).toBe(firstProof); expect(x.send.clicks).toBe(sequence);
    }
  });
  test('product-only native scope rejects wrong action fields round pins product and spent state without ownership proof', async () => {
    for (const mutation of ['action', 'extra', 'sequence', 'fingerprint', 'pin', 'product', 'spent']) {
      const x = await chatTurnFixture(choice), record = await x.dispatch('Scoped post-Send product request'); optimistic(x, record);
      const request: any = { sequence: 1, fingerprint: record.fingerprint }, overrides: any = { action: 'verifyProductMode', allowFirstUserBinding: false };
      if (mutation === 'action') overrides.action = 'inspect';
      if (mutation === 'extra') request.extra = true;
      if (mutation === 'sequence') request.sequence = 2;
      if (mutation === 'fingerprint') request.fingerprint = '0'.repeat(64);
      if (mutation === 'pin') overrides.expectedSubmissionProofs = [{ sequence: 1, fingerprint: '0'.repeat(64) }];
      if (mutation === 'product') { x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true'; }
      if (mutation === 'spent') (x.f.world.__computaChatSubmissionState as any).pending.phase = 'verified';
      const result = await x.observe(record, { ...overrides, pendingSubmissionProductRecheck: request });
      expect(result.error).toBeDefined(); expect(result).not.toHaveProperty('firstUserVerified', true);
      expect(result).not.toHaveProperty('submissionProof'); expect(result).not.toHaveProperty('text'); expect(x.send.clicks).toBe(1);
    }
  });
  test('optimistic deferral rejects changed prefix marker scope physical witness owner and native round pins', async () => {
    for (const mutation of ['prefix', 'marker', 'scope', 'outline', 'owner', 'sequence', 'pin', 'native_first_pin', 'private_first_pin']) {
      const x = await chatTurnFixture(choice), record = await x.dispatch('Owned optimistic negatives ' + 'A'.repeat(11_000));
      const o = optimistic(x, record); x.answer('Final'); const overrides: any = {};
      if (mutation === 'prefix') o.body.text = 'Wrong' + o.body.text.slice(0, 30);
      if (mutation === 'marker') o.body.text = 'Prefix\nComputa session marker: ' + record.marker;
      if (mutation === 'scope') o.root.values['data-user-message-bubble'] = 'false';
      if (mutation === 'outline') o.rect.values['stroke-dasharray'] = '4 4';
      if (mutation === 'owner') overrides.ownerToken = 'foreign-owner';
      if (mutation === 'sequence') overrides.submissionSequence = 2;
      if (mutation === 'pin') overrides.expectedSubmissionProofs = [{ sequence: 1, fingerprint: '0'.repeat(64) }];
      if (mutation === 'native_first_pin') overrides.expectedFirstUserFingerprint = record.fingerprint;
      if (mutation === 'private_first_pin') x.f.world.__computaModelFirstProof = { marker: firstMarker, fingerprint: record.fingerprint };
      const result = await x.observe(record, overrides);
      expect(result.error, mutation).toBeDefined(); expect(result.error, mutation).not.toBe('submission_observation_pending');
      expect(result).not.toHaveProperty('submissionProof'); expect(result).not.toHaveProperty('firstUserVerified', true);
      expect(result).not.toHaveProperty('text'); expect(x.send.clicks).toBe(1);
    }
  });
  test('retained optimistic echo cannot hide altered prior body or a spent verified round', async () => {
    for (const mutation of ['prior', 'verified']) {
      const x = await chatTurnFixture(choice), first = await x.dispatch('Prior intact request'); x.answer('First'); await x.observe(first);
      const record = await x.dispatch('Current optimistic request'); optimistic(x, record); x.answer('Final');
      if (mutation === 'prior') x.f.document.querySelectorAll('article[data-turn="user"]')[0].children[0].text += '!';
      if (mutation === 'verified') (x.f.world.__computaChatSubmissionState as any).pending.phase = 'verified';
      const result = await x.observe(record);
      expect(result.error).toBeDefined(); expect(result.error).not.toBe('submission_observation_pending');
      expect(result).not.toHaveProperty('submissionProof'); expect(x.send.clicks).toBe(2);
    }
  });
});

describe('ChatGPT first-message expansion after a failed center hit', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const staged = async () => {
    const prompt = 'Owned clipped first-message expansion.\n'.repeat(600);
    const f = fixture({ userPrompt: prompt });
    const picker = installObservedModelPicker(f, 'chatgpt', Element);
    expect((await f.inspect({ allowFirstUserBinding: false })).error).toBeDefined();
    const outbound = prompt + '\n\n' + markerLine;
    f.world.__computaModelLastSubmissionCount = 0;
    f.userBody!.text = outbound.slice(0, 10_240);
    const expand = new Element('BUTTON', { 'aria-label': 'Show more' });
    const send = new Element('BUTTON', { 'aria-label': 'Send' });
    const overlay = new Element('DIV');
    f.userBody!.parentElement!.append(expand); f.body.append(send, overlay);
    f.window.innerWidth = 1_000; f.window.innerHeight = 800;
    expand.getBoundingClientRect = () => ({ left: 20, top: 80, width: 100, height: 30 });
    f.setHit(overlay); // Finite in-window center, clipped or covered in the rendered page.
    expand.onClick = () => { f.userBody!.text = outbound; expand.connected = false; };
    const inspect = () => f.inspect({ allowFirstUserExpansion: true,
      firstUserExpansionModelChoice: choice, expectedModelChoice: choice }, false);
    return { f, picker, expand, send, outbound, inspect };
  };

  test('a clipped center inside the window gets one scroll and one verified local expansion', async () => {
    const x = await staged(), scrolls: unknown[] = [];
    (x.expand as any).scrollIntoView = (options: unknown) => { scrolls.push(options); x.f.setHit(x.expand); };
    const result = await x.inspect();
    if (result.error) expect(JSON.parse(result.debugStructure)).toMatchObject({
      expansionOutcome: 'obstructed', bodyInnerTextLength: 10_240, scopedExpandControlCount: 1 });
    expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
    expect(result.firstUserMarkerVerified).toBe(true); expect(x.f.userBody!.text).toBe(x.outbound);
    expect(scrolls).toEqual([{ block: 'center', inline: 'nearest', behavior: 'instant' }]);
    expect(x.expand.clicks).toBe(1); expect(x.send.clicks).toBe(0); expect(x.f.composer.events).toHaveLength(0);
    expect((x.f.world.__computaModelFirstExpansion as any).outcome).toBe('expanded');
    expect((await x.inspect()).error).toBeUndefined(); expect(scrolls).toHaveLength(1); expect(x.expand.clicks).toBe(1);
  });

  test('scrolling cannot bypass a persistent overlay or changed owned control, body or owner', async () => {
    for (const mutation of ['overlay', 'replacement', 'disabled', 'body', 'owner']) {
      const x = await staged(); let scrolls = 0;
      (x.expand as any).scrollIntoView = () => {
        scrolls++;
        if (mutation !== 'overlay') x.f.setHit(x.expand);
        if (mutation === 'replacement') {
          const parent = x.expand.parentElement!, replacement = new Element('BUTTON', { 'aria-label': 'Show more' });
          replacement.parentElement = parent; parent.children[parent.children.indexOf(x.expand)] = replacement;
          x.expand.connected = false;
        }
        if (mutation === 'disabled') x.expand.disabled = true;
        if (mutation === 'body') x.f.userBody!.text += 'changed';
        if (mutation === 'owner') x.f.world.__computaModelOwner = 'foreign-owner';
      };
      const result = await x.inspect();
      expect(result.error, mutation).toBeDefined(); expect(result, mutation).not.toHaveProperty('firstUserVerified');
      if (mutation === 'overlay') expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('obstructed');
      expect(scrolls, mutation).toBe(1); expect(x.expand.clicks, mutation).toBe(0);
      expect(x.f.world.__computaModelFirstProof, mutation).toBeUndefined();
      expect(x.send.clicks, mutation).toBe(0); expect(x.f.composer.events, mutation).toHaveLength(0);
      expect((await x.inspect()).error, mutation).toBeDefined(); expect(scrolls, mutation).toBe(1);
    }
  });
});

describe('ChatGPT completed expansion route continuation', () => {
  const choice = { key: 'chat/latest/medium', label: 'Medium' };
  const localURL = 'https://chatgpt.com/c/local-chatgpt%3Acompleted-expansion?temporary-chat=true';
  const publicURL = 'https://chatgpt.com/c/public-completed-expansion?temporary-chat=true';
  const edge = { fromURL: localURL, toURL: publicURL };

  // The first read completes its sole local display expansion, then the site
  // promotes the route while the first-message hash is awaiting. Native must
  // discard that read and certify the local-to-public edge before reinspection.
  const crossedRead = async () => {
    const prompt = 'Owned completed expansion line.\n'.repeat(600);
    const f = fixture({ userPrompt: prompt });
    const picker = installObservedModelPicker(f, 'chatgpt', Element);
    expect((await f.inspect({ allowFirstUserBinding: false })).error).toBeDefined();
    const outbound = prompt + '\n\n' + markerLine;
    f.world.__computaModelLastSubmissionCount = 0;
    f.document.URL = localURL; f.location.pathname = '/c/local-chatgpt%3Acompleted-expansion';
    f.userBody!.text = outbound.slice(0, 10_240);
    const more = new Element('BUTTON', { 'aria-label': 'Show more' });
    const send = new Element('BUTTON', { 'aria-label': 'Send' });
    f.userBody!.parentElement!.append(more); f.body.append(send);
    more.onClick = () => { f.userBody!.text = outbound; more.connected = false; };
    let expandedAtCrossing: unknown;
    f.onDigest(() => {
      expandedAtCrossing = (f.world.__computaModelFirstExpansion as any)?.outcome;
      f.document.URL = publicURL; f.location.pathname = '/c/public-completed-expansion';
    }, outbound);
    const crossed = await f.inspect({ allowFirstUserExpansion: true,
      firstUserExpansionModelChoice: choice, expectedModelChoice: choice }, false);
    expect(crossed).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(expandedAtCrossing).toBe('expanded');
    expect(f.world.__computaModelFirstProof).toBeUndefined();
    const candidate: any = f.world.__computaModelFirstExpansion;
    expect(candidate).toMatchObject({ clicked: true, outcome: 'expanded', routeURL: localURL, expandedText: outbound });
    const deadline = candidate.deadline;
    const resume = (overrides: Record<string, unknown> = {}) => f.inspect({ allowFirstUserExpansion: true,
      firstUserExpansionModelChoice: choice, expectedModelChoice: choice,
      firstUserExpansionRouteContinuation: [edge], ...overrides }, false);
    return { f, picker, candidate, more, send, deadline, resume };
  };

  test('a native-certified local-to-public edge preserves a completed exact expansion without another click', async () => {
    const x = await crossedRead(), reads = x.picker.trigger.clicks;
    const result = await x.resume({ suppressFirstUserExpansionClaim: true });
    expect(result.error).toBeUndefined();
    expect(result.firstUserVerified).toBe(true); expect(result.firstUserMarkerVerified).toBe(true);
    expect(result.modelEvidence.selected).toEqual(choice);
    expect(x.picker.trigger.clicks).toBeGreaterThan(reads);
    expect(x.candidate).toMatchObject({ outcome: 'expanded', routeURL: publicURL, deadline: x.deadline });
    expect(x.more.clicks).toBe(1); expect(x.send.clicks).toBe(0); expect(x.f.composer.events).toHaveLength(0);
  });

  test('only the unconsumed native edge is used and completed display work gets no new deadline', async () => {
    const x = await crossedRead();
    x.f.advanceTime(2_000);
    const result = await x.resume({ firstUserExpansionRouteContinuation: [
      { fromURL: 'https://chatgpt.com/?temporary-chat=true', toURL: localURL }, edge,
    ] });
    expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
    expect(result.modelEvidence.selected).toEqual(choice);
    expect(x.candidate.deadline).toBe(x.deadline); expect(x.more.clicks).toBe(1); expect(x.send.clicks).toBe(0);
  });

  test('completed display work cannot repair altered route, document, owner, body, model, or previous proof', async () => {
    for (const mutation of ['wrong_from', 'wrong_to', 'second_navigation', 'document', 'owner', 'body', 'body_node',
      'marker', 'native_fingerprint', 'private_fingerprint', 'model', 'model_choice', 'temporary', 'work',
      'failed_expansion', 'failed_context', 'failed_text', 'cleanup']) {
      const x = await crossedRead(), overrides: Record<string, unknown> = {};
      if (mutation === 'wrong_from') overrides.firstUserExpansionRouteContinuation = [{ ...edge, fromURL: 'https://chatgpt.com/c/foreign' }];
      if (mutation === 'wrong_to') overrides.firstUserExpansionRouteContinuation = [{ ...edge, toURL: 'https://chatgpt.com/c/foreign' }];
      if (mutation === 'second_navigation') {
        x.f.document.URL = 'https://chatgpt.com/c/second-public?temporary-chat=true';
        x.f.location.pathname = '/c/second-public';
      }
      if (mutation === 'document') x.candidate.document = {};
      if (mutation === 'owner') x.f.world.__computaModelOwner = 'foreign-owner';
      if (mutation === 'body') x.f.userBody!.text = x.f.userBody!.text.replace('Owned', 'Other');
      if (mutation === 'body_node') {
        const body = x.f.userBody!, parent = body.parentElement!;
        const replacement = new Element('DIV', { class: 'whitespace-pre-wrap' }, body.text);
        replacement.parentElement = parent; parent.children[parent.children.indexOf(body)] = replacement; body.connected = false;
      }
      if (mutation === 'marker') overrides.expectedFirstUserMarker = '11111111-1111-4111-8111-111111111111';
      if (mutation === 'native_fingerprint') overrides.expectedFirstUserFingerprint = 'a'.repeat(64);
      if (mutation === 'private_fingerprint') x.f.world.__computaModelFirstProof = { marker: firstMarker, fingerprint: 'a'.repeat(64) };
      if (mutation === 'model') x.picker.selected('High');
      if (mutation === 'model_choice') overrides.firstUserExpansionModelChoice = { key: 'chat/latest/high', label: 'High' };
      if (mutation === 'temporary') x.f.temporary.values['aria-label'] = 'Temporary chat';
      if (mutation === 'work') x.f.workMode.values['aria-pressed'] = 'true';
      if (mutation === 'failed_expansion') x.candidate.outcome = 'timeout';
      if (mutation === 'failed_context') x.candidate.contextFailure = 'body';
      if (mutation === 'failed_text') x.candidate.expandedText += '!';
      if (mutation === 'cleanup') overrides.allowFirstUserExpansion = false;
      const pinned = x.f.world.__computaModelFirstProof;
      const result = await x.resume(overrides);
      expect(result.error, mutation).toBeDefined(); expect(result, mutation).not.toHaveProperty('text');
      expect(result, mutation).not.toHaveProperty('firstUserVerified');
      expect(x.f.world.__computaModelFirstProof, mutation).toBe(pinned);
      expect(x.more.clicks, mutation).toBe(1); expect(x.send.clicks, mutation).toBe(0);
      expect(x.f.composer.events, mutation).toHaveLength(0); expect(x.candidate.deadline, mutation).toBe(x.deadline);
    }
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
    expect(diagnostic).toMatchObject({ kind: 'chatgpt_resource_timing_v2', phase: 'completion', sequence: 1, conversationCount: 2, preparationCount: 1,
      scannedCount: 3, scanTruncated: false, observationsTruncated: false, absenceInconclusive: true });
    expect(diagnostic.observations[0]).toEqual({ endpoint: 'conversation', initiator: 'fetch', startOffsetMs: 1, durationMs: 50,
      requestStartOffsetMs: null, responseStartOffsetMs: null, responseEndOffsetMs: 51,
      transferBytes: 130, encodedBodyBytes: 100, decodedBodyBytes: 150, responseStatusAvailable: true, responseStatus: 200 });
    expect(diagnostic.observations[1].responseStatusAvailable).toBe(false); expect(diagnostic.observations[1].responseStatus).toBeNull();
    expect(diagnostic.observations[2].responseStatus).toBe(0); expect(diagnostic.absenceInconclusive).toBe(true);
    const before = { clicks: send.clicks, observers: f.observers.length, timers: f.scheduledDelays.length, reads };
    const failed = await f.diagnose();
    expect(failed.resourceTimingDiagnostic).toEqual({ ...diagnostic, kind: 'chatgpt_resource_timing_v3', phase: 'failure',
      scriptResources: { count: 0, unknownStatusCount: 0, httpFailureCount: 0, failuresTruncated: false, failures: [] } });
    expect(failed).not.toHaveProperty('submissionProof'); expect(failed).not.toHaveProperty('firstUserVerified');
    expect(send.clicks).toBe(before.clicks); expect(f.observers.length).toBe(before.observers); expect(f.scheduledDelays.length).toBe(before.timers);
    expect(reads).toBe(before.reads + 1); expect(f.world.__computaChatResourceTimingClaim).toBe(claim);
    for (const secret of ['PRIVATE', firstMarker, 'https:', 'backend-api', 'name', 'upload']) expect(JSON.stringify(failed.resourceTimingDiagnostic)).not.toContain(secret);
  });
  test('terminal renderer inspection retains failure timing with or without completion controls and no extra read', async () => {
    for (const retainCopy of [false, true]) {
      let now = 100.25, entries: any[] = [], reads = 0;
      const { f, prompt, send } = await sent({ now: () => now, getEntriesByType: () => { reads++; return entries; } });
      now = 200; entries = [ended(undefined, { responseStatus: 200 })];
      f.appendUser(prompt); f.body.querySelector('main')!.append(f.answer.parentElement!);
      f.answer.children.forEach(child => { child.connected = false; child.parentElement = null; });
      f.answer.text = ''; f.answer.children = [];
      const portal = new Element('DIV', { class: 'PortalBoundary-Fixture Renderer-Fixture' });
      const renderer = new Element('DIV', { class: 'DilRenderer-Fixture DilResponseRoot-Fixture' });
      renderer.append(new Element('DIV', {}, 'This response couldn’t load')); portal.append(renderer); f.answer.append(portal);
      const copy = f.messages.querySelector('button[aria-label="Copy"]')!;
      if (!retainCopy) copy.connected = false;
      const before = { reads, clicks: send.clicks, timers: f.scheduledDelays.length, observers: f.observers.length };
      const failed = await f.inspect({ expectedUserCounts: [1] });
      expect(failed.firstUserVerified).toBe(true); expect(failed.responseLoadFailed).toBe(true);
      expect(failed.answerComplete).toBe(retainCopy);
      expect(failed.completionEvidence.codeStructure.rendererGuard.reason).toBe('matched');
      expect(failed.resourceTimingDiagnostic).toMatchObject({ phase: 'failure', sequence: 1, conversationCount: 1,
        observations: [{ endpoint: 'conversation', responseStatus: 200 }], absenceInconclusive: true });
      expect(reads).toBe(before.reads + 1); expect(send.clicks).toBe(before.clicks);
      expect(f.scheduledDelays.length).toBe(before.timers); expect(f.observers.length).toBe(before.observers);
      for (const privateValue of ['PRIVATE', firstMarker, 'https:', 'backend-api'])
        expect(JSON.stringify(failed.resourceTimingDiagnostic)).not.toContain(privateValue);
    }
  });
  test('public request and response timing offsets are finite ordered or explicitly unknown', async () => {
    let now = 100.25, entries: any[] = [];
    const { f, send } = await sent({ now: () => now, getEntriesByType: () => entries }); now = 200;
    const read = async (changes: Record<string, unknown>) => {
      entries = [ended(undefined, { requestStart: 110.5, responseStart: 130.1, ...changes })];
      const result = await f.diagnose();
      expect(result).not.toHaveProperty('submissionProof'); expect(result).not.toHaveProperty('firstUserVerified');
      expect(result.resourceTimingDiagnostic.kind).toBe('chatgpt_resource_timing_v3');
      return result.resourceTimingDiagnostic.observations[0];
    };
    expect(await read({ headers: 'PRIVATE_HEADERS', cookies: 'PRIVATE_COOKIES' })).toEqual({
      endpoint: 'conversation', initiator: 'fetch', startOffsetMs: 1, durationMs: 50,
      requestStartOffsetMs: 10, responseStartOffsetMs: 29, responseEndOffsetMs: 51,
      transferBytes: 130, encodedBodyBytes: 100, decodedBodyBytes: 150, responseStatusAvailable: false, responseStatus: null });
    for (const bad of [undefined, null, 0, -1, NaN, Infinity, true, '110', 101, 152, 3_600_101]) {
      expect((await read({ requestStart: bad })).requestStartOffsetMs).toBeNull();
      expect((await read({ responseStart: bad })).responseStartOffsetMs).toBeNull();
    }
    // Compare the original fractions before flooring, which can hide reversal.
    expect(await read({ requestStart: 130.9, responseStart: 130.8 })).toMatchObject({
      requestStartOffsetMs: null, responseStartOffsetMs: null, responseEndOffsetMs: 51 });
    expect(await read({ requestStart: undefined, responseStart: 130.1 })).toMatchObject({
      requestStartOffsetMs: null, responseStartOffsetMs: 29, responseEndOffsetMs: 51 });
    const diagnostic = (await f.diagnose()).resourceTimingDiagnostic;
    for (const secret of ['PRIVATE', 'headers', 'cookies', 'https:']) expect(JSON.stringify(diagnostic)).not.toContain(secret);
    expect(send.clicks).toBe(1);
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
    for (const secret of ['PRIVATE', 'http:', 'https:', 'backend-api', 'name', 'url', 'header', 'body']) expect(JSON.stringify(diagnostic)).not.toContain(secret);
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
  test('failure timing records only ended exact public scripts with positive HTTP errors', async () => {
    let now = 100.25, reads = 0, entries: any[] = [];
    const { f, send, result } = await sent({ now: () => now, getEntriesByType: () => { reads++; return entries; } });
    expect(result.resourceTimingDiagnostic.kind).toBe('chatgpt_resource_timing_v2');
    expect(result.resourceTimingDiagnostic).not.toHaveProperty('scriptResources');
    now = 200;
    const asset = (id: number, status?: unknown, extra: Record<string, unknown> = {}) => ended(
      `https://chatgpt.com/cdn/assets/${id}.abcdef0123.js`, { initiatorType: 'script', responseStatus: status, ...extra });
    entries = [asset(1, 404), asset(2, 500), asset(3, 503), asset(4, undefined), asset(5, 0),
      asset(6, 200, { transferSize: 0, encodedBodySize: 0, decodedBodySize: 0 }), asset(7, 304),
      asset(8, 404, { startTime: 100.2 }), asset(9, 404, { responseEnd: 0 }), asset(10, 404, { responseEnd: 201 }),
      asset(11, 404, { initiatorType: 'fetch' }), asset(12, 600), asset(13, 99), asset(14, true), asset(15, '404')];
    const before = { reads, timers: f.scheduledDelays.length, observers: f.observers.length };
    const diagnostic = (await f.diagnose()).resourceTimingDiagnostic;
    expect(diagnostic).toMatchObject({ kind: 'chatgpt_resource_timing_v3', phase: 'failure', absenceInconclusive: true,
      scriptResources: { count: 7, unknownStatusCount: 2, httpFailureCount: 3, failuresTruncated: true,
        failures: [{ asset: '2.abcdef0123.js', responseStatus: 500, startOffsetMs: 1, durationMs: 50 },
          { asset: '3.abcdef0123.js', responseStatus: 503, startOffsetMs: 1, durationMs: 50 }] } });
    expect(reads).toBe(before.reads + 1); expect(send.clicks).toBe(1);
    expect(f.scheduledDelays.length).toBe(before.timers); expect(f.observers.length).toBe(before.observers);
    expect(JSON.stringify(diagnostic)).not.toContain('https:');
  });
  test('failure timing includes current async renderer chunks and modulepreloads without inferring execution', async () => {
    let now = 100.25;
    const entries = [
      ended('https://chatgpt.com/cdn/assets/async/641521.fd69f85d55.js', { initiatorType: 'script', responseStatus: 503 }),
      ended('https://chatgpt.com/cdn/assets/633146.510c2d4c2a.js', { initiatorType: 'link', responseStatus: 200 }),
      ended('https://chatgpt.com/cdn/assets/async/550464.48704311ca.js', { initiatorType: 'link', responseStatus: 0 })
    ];
    const { f, send } = await sent({ now: () => now, getEntriesByType: () => entries }); now = 200;
    expect((await f.diagnose()).resourceTimingDiagnostic.scriptResources).toEqual({
      count: 3, unknownStatusCount: 1, httpFailureCount: 1, failuresTruncated: false,
      failures: [{ asset: '641521.fd69f85d55.js', responseStatus: 503, startOffsetMs: 1, durationMs: 50 }]
    });
    expect(send.clicks).toBe(1);
  });
  test('public script resource projection rejects hostile names aliases and unapproved filenames', async () => {
    let now = 100.25;
    const names = ['https://private.example/cdn/assets/1.abcdef0123.js', 'https://chatgpt.com.evil.invalid/cdn/assets/1.abcdef0123.js',
      'https://PRIVATE@chatgpt.com/cdn/assets/1.abcdef0123.js', 'https://chatgpt.com/cdn/assets/1.abcdef0123.js?PRIVATE',
      'https://chatgpt.com/cdn/assets/1.abcdef0123.js#PRIVATE', 'https://chatgpt.com/cdn/assets/1.abcdef0123.js?',
      'https://chatgpt.com:443/cdn/assets/1.abcdef0123.js', 'https://chatgpt.com/cdn/assets/../assets/1.abcdef0123.js',
      'https://chatgpt.com/cdn/assets/%31.abcdef0123.js', 'https://chatgpt.com/cdn/assets/1.ABCDEF0123.js',
      'https://chatgpt.com/cdn/assets/1234567.abcdef0123.js', 'https://chatgpt.com/cdn/assets/1.abcdef01234.js',
      'https://chatgpt.com/cdn/assets/PRIVATE.js', 'https://chatgpt.com/cdn/assets/1.abcdef0123.js/'];
    const { f, send } = await sent({ now: () => now, getEntriesByType: () => names.map(name => ended(name,
      { initiatorType: 'script', responseStatus: 404 })) }); now = 200;
    const diagnostic = (await f.diagnose()).resourceTimingDiagnostic;
    expect(diagnostic.scriptResources).toEqual({ count: 0, unknownStatusCount: 0, httpFailureCount: 0,
      failuresTruncated: false, failures: [] });
    for (const secret of ['PRIVATE', 'https:', 'abcdef', 'url', 'name']) expect(JSON.stringify(diagnostic)).not.toContain(secret);
    expect(send.clicks).toBe(1);
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
    expect(observed.responseLoadFailed).toBe(true); expect(observed.responseFailureKind).toBe('renderer');
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
    expect(observed.responseLoadFailed).toBe(true); expect(observed.responseFailureKind).toBe('renderer'); expect(observed.answerComplete).toBe(false);
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

  test('recognizes metadata before the exact DIL error in a large owned request', async () => {
    // The metadata is synthetic. It reproduces the observed first-decline
    // shape without claiming which annotation the live page used.
    const f = fixture({ userPrompt: 'Large owned request: ' + 'x'.repeat(69_986) }), e = rendererError();
    await f.inspect();
    const temporaryClicks = f.temporary.clicks;
    const layout = new Element('DIV'), inner = new Element('DIV');
    const decoration = new Element('DIV', { hidden: '' }), child = new Element('DIV');
    const grandchild = new Element('DIV'), metadata = new Element('DIV', { role: 'status' });
    decoration.append(child); child.append(grandchild); grandchild.append(metadata);
    replaceAnswer(f, layout); layout.append(inner); inner.append(decoration, e.portal);
    const observed = await f.inspect();
    expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
    expect({ responseLoadFailed: observed.responseLoadFailed, ...observed.completionEvidence.codeStructure.rendererGuard })
      .toMatchObject({ responseLoadFailed: true, reason: 'matched', rawKnownLabel: true, trimmedKnownLabel: true,
        guardBodyIsExtractedAnswer: true });
    expect(observed.text).toBe('This response couldn’t load');
    expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0);
    expect(f.temporary.clicks).toBe(temporaryClicks); expect(f.composer.events).toEqual([]);
  });

  test('uses DIV annotations only to recognize the exact abort-only renderer error', async () => {
    for (const variant of ['hidden-role', 'hidden-tabindex', 'hidden-data', 'hidden-many-attributes', 'hidden-onclick',
      'hidden-aria', 'portal-role', 'root-tabindex', 'leaf-role', 'leaf-tabindex']) {
      const f = fixture({ userPrompt: 'Observe the scoped error without interacting' }), e = rendererError();
      await f.inspect();
      const temporaryClicks = f.temporary.clicks;
      replaceAnswer(f, e.portal);
      const decoration = new Element('DIV', { hidden: '' });
      f.answer.children.unshift(decoration); decoration.parentElement = f.answer;
      if (variant === 'hidden-role') decoration.values.role = 'status';
      if (variant === 'hidden-tabindex') decoration.values.tabindex = '-1';
      if (variant === 'hidden-data') decoration.values['data-fixture-annotation'] = 'opaque';
      if (variant === 'hidden-many-attributes') for (let index = 0; index < 8; index++)
        decoration.values[`data-fixture-${index}`] = 'opaque';
      if (variant === 'hidden-onclick') decoration.values.onclick = 'untrusted()';
      if (variant === 'hidden-aria') decoration.values['aria-live'] = 'polite';
      if (variant === 'portal-role') e.portal.values.role = 'group';
      if (variant === 'root-tabindex') e.root.values.tabindex = '0';
      if (variant === 'leaf-role') e.leaf.values.role = 'status';
      if (variant === 'leaf-tabindex') e.leaf.values.tabindex = '-1';
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect(observed.responseLoadFailed).toBe(true); expect(observed.responseFailureKind).toBe('renderer');
      expect(observed.completionEvidence.codeStructure.rendererGuard).toMatchObject({ reason: 'matched', rawKnownLabel: true,
        guardBodyIsExtractedAnswer: true });
      expect(observed.text).toBe('This response couldn’t load');
      expect([decoration, e.portal, e.root, e.leaf].every(node => node.clicks === 0 && node.events.length === 0)).toBe(true);
      expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0);
      expect(f.temporary.clicks).toBe(temporaryClicks); expect(f.composer.events).toEqual([]);
    }
  });

  test('preserves a requested literal phrase without structural renderer error evidence', async () => {
    for (const kind of ['plain', 'paragraph', 'markdown', 'blockquote', 'pre', 'code']) {
      const f = fixture({ userPrompt: 'Return exactly: This response couldn’t load' });
      const wrapper = new Element(kind === 'plain' || kind === 'markdown' ? 'DIV' : kind === 'paragraph' ? 'P' : kind.toUpperCase(),
        { ...(kind === 'markdown' ? { class: 'markdown' } : {}), role: 'status', tabindex: '-1' }, 'This response couldn’t load');
      replaceAnswer(f, wrapper);
      const observed = await f.inspect();
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull(); expect(observed.text).toBe('This response couldn’t load');
      expect(observed.answerComplete).toBe(true); expect(wrapper.clicks).toBe(0); expect(f.composer.events).toEqual([]);
    }
  });

  test('never interacts with an active Stop while classifying annotated error metadata', async () => {
    const f = fixture({ userPrompt: 'Do not interact with page controls' }), e = rendererError();
    await f.inspect(); replaceAnswer(f, e.portal); e.leaf.values.role = 'status';
    const stop = new Element('BUTTON', { 'aria-label': 'Stop generating' }); f.body.append(stop);
    const observed = await f.inspect();
    expect(observed.error).toBeUndefined(); expect(observed.busy).toBe(true);
    expect(observed.responseLoadFailed).toBe(true); expect(observed.responseFailureKind).toBe('renderer'); expect(stop.clicks).toBe(0);
    expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0); expect(f.composer.events).toEqual([]);
  });

  test('never exempts hidden text, controls, message markers or display-contents descendants', async () => {
    const variants = ['text', 'whitespace', 'known-label', 'button', 'link', 'quote', 'markdown',
      'editable', 'author', 'turn', 'assistant-turn', 'user-bubble', 'hidden-component',
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
      if (variant === 'editable') child.values.contenteditable = 'false';
      if (variant === 'author') child.values['data-message-author-role'] = 'tool';
      if (variant === 'turn') child.values['data-turn'] = 'tool';
      if (variant === 'assistant-turn') child.values['data-turn'] = 'assistant';
      if (variant === 'user-bubble') child.values['data-user-message-bubble'] = '';
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
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
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
      expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
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
      expect(observed.responseLoadFailed).toBe(true); expect(observed.responseFailureKind).toBe('renderer');
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
    expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
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
      expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
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
    expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
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
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
      expect(observed.text).toContain('This response couldn’t load'); expect(f.composer.events).toEqual([]);
    }
  });

  test('does not import renderer-shaped user, tool-result, old-answer or outside-body content', async () => {
    for (const kind of ['user', 'tool-result', 'old-answer', 'outside-body']) {
      const prefix = kind === 'tool-result' ? 'Recorded tool output: ' : '';
      const f = fixture({ userPrompt: ['user', 'tool-result'].includes(kind) ? prefix + 'This response couldn’t load' : 'Read the current answer' });
      const e = rendererError();
      e.root.values.role = 'status';
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
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
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
      expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull(); expect(f.composer.events).toEqual([]);
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
      expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull(); expect(f.composer.events).toEqual([]);
    }
  });

  test('rejects counterfeit, ambiguous, hidden, interactive and over-budget renderer shapes', async () => {
    const variants = ['missing-renderer', 'missing-response-root', 'missing-portal', 'missing-parent-renderer', 'empty-suffix',
      'counterfeit-prefix', 'split-root-pair', 'indirect-root', 'indirect-leaf', 'styled-leaf', 'span-leaf', 'nested-label',
      'different-label', 'padded-label', 'extra-text', 'second-leaf', 'second-root', 'second-portal', 'hidden-leaf', 'hidden-root',
      'hidden-portal', 'detached', 'editable', 'button', 'link', 'svg',
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
      expect(observed.error).toBeUndefined(); expect(observed.responseLoadFailed).toBe(false); expect(observed.responseFailureKind).toBeNull();
      expect(f.composer.events).toEqual([]);
      expect(f.messages.querySelector('button[aria-label="Copy"]')!.clicks).toBe(0);
    }
  });

  test('cannot override owned first-message, product or native document-context rejection', async () => {
    for (const drift of ['user', 'work', 'owner', 'url']) {
      const f = fixture({ userPrompt: 'Preserve the owned message' }), e = rendererError();
      await f.inspect(); replaceAnswer(f, e.portal);
      e.leaf.values.role = 'status';
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

  test('product-state scans keep bounds and aliases but avoid layout reads on unrelated aria labels', () => {
    const start = source.indexOf('function chatGPTProductModeState()');
    const end = source.indexOf('function chatGPTProductModeDiagnostic', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const run = new Function('document', 'getComputedStyle', 'websiteModelNormalize', disabledWorkDiagnostic + source.slice(start, end)
      + 'return chatGPTProductModeState();');
    const read = (f: ReturnType<typeof fixture>) => run(f.document, (node: Element) => ({ visibility: node.cssVisibility }),
      (value: unknown) => typeof value === 'string' ? value.normalize('NFC').replace(/\s+/g, ' ').trim() : '');
    const f = fixture({ response: false, normalRoot: true });
    const irrelevant = new Element('SPAN', { 'aria-label': 'Unrelated control' }); f.body.append(irrelevant);
    let unrelatedLayoutReads = 0;
    irrelevant.getClientRects = () => { unrelatedLayoutReads++; return [{}]; };
    expect(read(f)).toMatchObject({ ready: true, chatSelected: true, workSelected: false });
    expect(unrelatedLayoutReads).toBe(0);
    // Exact aria-labelledby aliases remain supported and physically required.
    delete f.modeGroup.values['aria-label']; f.modeGroup.values['aria-labelledby'] = 'scan-mode-label';
    const label = new Element('SPAN', { id: 'scan-mode-label' }, 'Composer mode'); f.body.append(label);
    expect(read(f).ready).toBe(true);
    label.cssVisibility = 'hidden'; expect(read(f).ready).toBe(false);
    label.cssVisibility = 'visible';
    const duplicate = new Element('SPAN', { id: 'scan-mode-label' }, 'Composer mode'); f.body.append(duplicate);
    expect(read(f).ready).toBe(false);
    duplicate.connected = false; f.body.children = f.body.children.filter(node => node !== duplicate);
    f.modeGroup.cssVisibility = 'hidden'; expect(read(f).ready).toBe(false);
    f.modeGroup.cssVisibility = 'visible';
    f.body.append(new Element('DIV', { 'aria-label': 'Composer mode' }));
    expect(read(f)).toMatchObject({ contradictory: true });
    // Cheap filtering must happen AFTER the unchanged first1024 candidate cap.
    const bounded = fixture({ response: false, normalRoot: true });
    const padding = Array.from({ length: 1024 }, (_, index) => new Element('SPAN', { 'aria-label': 'Other ' + index }));
    padding.forEach(node => { node.parentElement = bounded.body; });
    bounded.body.children = [...padding, ...bounded.body.children];
    expect(read(bounded)).toMatchObject({ ready: false, group: null });
  });

  test('temporary-state scans inspect exact off controls first and preserve hidden and Save fallbacks', () => {
    const start = source.indexOf('function chatGPTRenderedTemporary()');
    const end = source.indexOf('// Product mode is independent', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const run = new Function('document', 'getComputedStyle', source.slice(start, end) + 'return chatGPTRenderedTemporary();');
    for (const condition of ['off', 'hidden', 'aria_hidden', 'inert', 'save_aria', 'save_text', 'save_hidden', 'save_wrong_route']) {
      const f = fixture({ response: false });
      const unrelated = new Element('BUTTON', { 'aria-label': 'Unrelated action' }, 'Unrelated action'); f.body.append(unrelated);
      let unrelatedLayoutReads = 0;
      unrelated.getClientRects = () => { unrelatedLayoutReads++; return [{}]; };
      if (condition === 'hidden') f.temporary.cssVisibility = 'hidden';
      if (condition === 'aria_hidden') f.temporary.values['aria-hidden'] = 'true';
      if (condition === 'inert') f.temporary.values.inert = '';
      if (condition.startsWith('save_')) {
        f.temporary.values['aria-label'] = condition === 'save_text' ? 'Other label' : 'Save chat';
        f.temporary.text = condition === 'save_text' ? 'Save chat' : 'Other text';
      }
      if (condition === 'save_hidden') f.temporary.cssVisibility = 'hidden';
      if (condition === 'save_wrong_route') f.document.URL = 'https://chatgpt.com/';
      expect(run(f.document, (node: Element) => ({ visibility: node.cssVisibility })))
        .toBe(['off', 'save_aria', 'save_text'].includes(condition));
      if (condition === 'off') expect(unrelatedLayoutReads).toBe(0);
    }
  });

  describe('temporary outlined user body physical witness', () => {
    const start = source.indexOf('function chatGPTTemporaryOutlineForRoot(root, body) {');
    const end = source.indexOf('// This fallback observes', start);
    const read = new Function('root', 'body', 'getComputedStyle', disabledWorkDiagnostic + source.slice(start, end)
      + 'return chatGPTTemporaryOutlineForRoot(root, body);');
    function outlined(shape: 'div' | 'span' = 'span') {
      const element = (tag: string, attrs: Record<string, string> = {}, text = '') => {
        const node: any = new Element(tag, attrs, text);
        node.namespaceURI = ['SVG', 'RECT'].includes(tag) ? 'http://www.w3.org/2000/svg' : 'http://www.w3.org/1999/xhtml';
        node.hasAttribute = (name: string) => node.getAttribute(name) !== null;
        node.outlineStyle = { display: 'block', visibility: 'visible', opacity: '1',
          stroke: 'currentColor', strokeOpacity: '0.4', strokeWidth: '1px' };
        Object.defineProperties(node, {
          localName: { get: () => node.tagName.toLowerCase() },
          firstElementChild: { get: () => node.children[0] || null },
          lastElementChild: { get: () => node.children.at(-1) || null },
        });
        return node;
      };
      const parent = element('DIV'), root = element('DIV', { 'data-user-message-bubble': 'true' });
      const body = element('SPAN', { class: 'text-size-chat leading-relaxed whitespace-pre-wrap', dir: 'auto' }, 'Synthetic owned body');
      const svg = element('SVG', { 'aria-hidden': 'true', focusable: 'false',
        class: 'pointer-events-none absolute inset-0 h-full w-full temporaryOutline-bbkcxS' });
      const rect = element('RECT', { x: '0.5', y: '0.5', width: 'calc(100% - 1px)', height: 'calc(100% - 1px)',
        fill: 'none', stroke: 'currentColor', 'stroke-opacity': '0.4', 'stroke-width': '1',
        'stroke-dasharray': '8 8', 'vector-effect': 'non-scaling-stroke' });
      svg.append(rect); parent.append(root);
      const content = shape === 'span' ? body : element('DIV');
      if (content !== body) content.append(body);
      root.append(svg, content);
      return { parent, root, body, svg, rect, content, element,
        read: () => read(root, body, (node: any) => node.outlineStyle) };
    }

    test('accepts the observed direct SPAN body and the original containing DIV wrapper', () => {
      expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
      for (const shape of ['span', 'div'] as const) {
        const f = outlined(shape);
        expect(f.read()).toBe(true);
        expect(f.root.children).toEqual([f.svg, f.content]);
        expect(f.body.tagName).toBe('SPAN');
      }
    });

    test('rejects extra or sibling content, nested SPAN wrappers, wrong tags and another selected body', () => {
      const mutations = [
        (f: ReturnType<typeof outlined>) => f.root.append(f.element('SPAN')),
        (f: ReturnType<typeof outlined>) => { const wrapper = f.element('SPAN'); f.root.children.pop(); wrapper.append(f.body); f.root.append(wrapper); },
        (f: ReturnType<typeof outlined>) => { f.body.tagName = 'P'; },
        (f: ReturnType<typeof outlined>) => { f.body.values.class = 'text-size-chat'; f.body.values['data-markdown-text-style'] = 'user-message'; },
        (f: ReturnType<typeof outlined>) => { f.svg.append(f.element('SPAN', { class: 'whitespace-pre-wrap' }, 'Sibling body')); },
      ];
      for (const mutate of mutations) { const f = outlined(); mutate(f); expect(f.read()).toBe(false); }
    });

    test('preserves exact SVG and rectangle decoration checks for both content shapes', () => {
      const mutations = [
        (f: ReturnType<typeof outlined>) => { f.svg.values['data-extra'] = 'true'; },
        (f: ReturnType<typeof outlined>) => { f.svg.values.class += ' unexpected'; },
        (f: ReturnType<typeof outlined>) => { f.svg.namespaceURI = 'http://www.w3.org/1999/xhtml'; },
        (f: ReturnType<typeof outlined>) => { f.rect.values['stroke-dasharray'] = '4 4'; },
        (f: ReturnType<typeof outlined>) => { delete f.rect.values['vector-effect']; },
        (f: ReturnType<typeof outlined>) => { f.rect.outlineStyle.stroke = 'none'; },
        (f: ReturnType<typeof outlined>) => { f.body.append(f.element('SVG', { class: 'temporaryOutline-duplicate' })); },
      ];
      for (const shape of ['span', 'div'] as const) for (const mutate of mutations) {
        const f = outlined(shape); mutate(f); expect(f.read()).toBe(false);
      }
    });

    test('preserves physical visibility and excluded-scope requirements', () => {
      const mutations = [
        (f: ReturnType<typeof outlined>) => { f.parent.values.inert = ''; },
        (f: ReturnType<typeof outlined>) => { f.parent.values['aria-hidden'] = 'true'; },
        (f: ReturnType<typeof outlined>) => { f.body.outlineStyle.display = 'none'; },
        (f: ReturnType<typeof outlined>) => { f.root.outlineStyle.opacity = '0'; },
        (f: ReturnType<typeof outlined>) => { f.parent.values['data-message-author-role'] = 'assistant'; },
        (f: ReturnType<typeof outlined>) => { f.parent.tagName = 'BUTTON'; },
        (f: ReturnType<typeof outlined>) => { f.root.values['data-user-message-bubble'] = 'false'; },
      ];
      for (const shape of ['span', 'div'] as const) for (const mutate of mutations) {
        const f = outlined(shape); mutate(f); expect(f.read()).toBe(false);
      }
    });
  });

  test('one product proof reuses only its synchronous temporary observation and rereads later calls', () => {
    const start = source.indexOf('function chatGPTProductModeProof()');
    const end = source.indexOf('function chatGPTTemporaryVerified()', start);
    expect(start).toBeGreaterThan(0); expect(end).toBeGreaterThan(start);
    const run = new Function('env', `
      ${disabledWorkDiagnostic}
      const { document, window, location, globalThis } = env;
      const chatGPTProductModeState = () => env.mode;
      const chatGPTRenderedTemporary = () => { env.temporaryReads++; return env.rendered; };
      const chatGPTInvalidateProductProof = (proof, reason) => { proof.invalidated = true; proof.invalidationReason = reason; return null; };
      ${source.slice(start, end)}
      return chatGPTProductModeProof();
    `);
    const document = { URL: 'https://chatgpt.com/?temporary-chat=true' }, window: any = {}; window.top = window;
    const proof = { owner: 'OWNER', document, invalidated: false, temporaryRequested: true, temporaryAcknowledged: false };
    const env = { document, window, location: { origin: 'https://chatgpt.com' },
      globalThis: { __computaModelOwner: 'OWNER', __computaChatProductMode: proof },
      mode: { contradictory: false, ready: true, chatSelected: true }, temporaryReads: 0, rendered: true };
    expect(run(env)).toMatchObject({ temporaryTransition: 'acknowledged' });
    expect(env.temporaryReads).toBe(1); expect(proof.temporaryAcknowledged).toBe(true);
    env.rendered = false;
    expect(run(env)).toMatchObject({ temporaryTransition: 'acknowledged' });
    expect(env.temporaryReads).toBe(2); // A new call always observes the current DOM again.
    env.mode.contradictory = true;
    expect(run(env)).toBeNull(); expect(proof.invalidated).toBe(true);
    env.mode.contradictory = false; env.rendered = true;
    expect(run(env)).toBeNull(); expect(env.temporaryReads).toBe(2); // No reviving an invalidated proof.
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

  test('message text can label an outside Composer group and permanently revoke product provenance', async () => {
    const f = fixture({ userPrompt: 'Synthetic owned prompt' }); await f.inspect();
    const label = new Element('SPAN', { id: 'outside-mode-label' }, 'Ordinary answer label'); f.answer.append(label);
    const outside = new Element('DIV', { role: 'group', 'aria-labelledby': 'outside-mode-label' });
    outside.append(new Element('BUTTON', { 'aria-pressed': 'true' }, 'Chat'),
      new Element('BUTTON', { 'aria-pressed': 'false' }, 'Work')); f.body.append(outside);
    f.observers[0].callback([{ type: 'childList', target: f.body, addedNodes: [outside], removedNodes: [] }]);
    expect((f.world.__computaChatProductMode as any).invalidated).toBe(false);
    label.text = 'Composer mode';
    const posted = f.posted.length;
    f.observers[0].callback([{ type: 'characterData', target: label.childNodes[0], oldValue: 'Ordinary answer label' }]);
    // The local classifier ignores this message record, but its referenced
    // label changes the global product controls. Keep that negative history.
    expect(f.world.__computaChatProductMode).toMatchObject({ invalidated: true,
      invalidationReason: 'contradictory_controls', productMutationRelevantCount: 0, productMutationIgnoredCount: 1 });
    expect(f.posted.length).toBe(posted + 1);
    label.text = 'Ordinary answer label'; outside.connected = false;
    expect(await f.inspect({ action: 'verifyProductMode' })).toMatchObject({ error: 'product_mode_unverified' });
    expect(f.chatMode.clicks).toBe(0); expect(f.composer.events).toEqual([]);
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
  test("accepted literal envelopes do not traverse rendered answer text", async () => {
    for (const options of [{}, { measuredPRE: true }, { noPre: true }]) {
      for (const envelope of [
        { type: "message", text: 'Literal "quotes", C:\\tmp\\file\nnext line' },
        { type: "tool_calls", calls: [{ name: "browser_open", arguments: { url: "http://127.0.0.1:12345/fixture" } }] },
      ]) {
        const f = fixture({ userPrompt: "Synthetic owned literal response" });
        const raw = "\n" + JSON.stringify(envelope) + "\n";
        let renderedReads = 0;
        observedChatGPTCodeBlock(f, raw, { ...options, renderedText: () => {
          renderedReads++; throw Error("An accepted literal body must not require rendered text");
        } });
        const result = await f.inspect();
        expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
        expect(result.firstUserMarkerVerified).toBe(true);
        expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
        expect(result.completionEvidence.codeStructure).toMatchObject({ selectedExtraction: "raw_code",
          extractionReason: "accepted_literal_code", literalCodeValidJSON: true,
          literalCodeKnownEnvelopeType: envelope.type });
        expect(renderedReads).toBe(0);
      }
    }
  });

  test("declined literal bodies and ordinary answers preserve fresh rendered fallback text", async () => {
    const raw = '{"type":"tool_calls","calls":[{"name":"browser_read","arguments":{}}]}';
    for (const kind of ["authored_prose", "invalid_json", "unknown_type", "div_header"] as const) {
      const f = fixture(); let renderedReads = 0;
      const rendered = "Rendered provider text for " + kind;
      const block = observedChatGPTCodeBlock(f, raw, { noPre: kind === "div_header", renderedText: () => {
        renderedReads++; return "  " + rendered + "\n";
      } });
      let reason = "outside_content";
      if (kind === "authored_prose") f.answer.append(new Element("P", {}, "Authored prose"));
      if (kind === "invalid_json") { block.code.text = '{"type":"message","text":"invalid "quote""}'; reason = "invalid_json"; }
      if (kind === "unknown_type") { block.code.text = '{"type":"unrecognized","text":"unknown"}'; reason = "unknown_envelope_type"; }
      if (kind === "div_header") block.label.text = "json";
      const result = await f.inspect();
      expect(result.error).toBeUndefined(); expect(result.text).toBe(rendered);
      expect(result.completionEvidence.codeStructure).toMatchObject({ selectedExtraction: "rendered_fallback", extractionReason: reason });
      expect(renderedReads).toBeGreaterThan(0);
    }
    const f = fixture(); let renderedReads = 0;
    Object.defineProperty(f.answer, "innerText", { get: () => { renderedReads++; return "  Visible ordinary response\n"; } });
    const result = await f.inspect();
    expect(result.text).toBe("Visible ordinary response");
    expect(result.completionEvidence.codeStructure).toMatchObject({ selectedExtraction: "rendered_fallback", extractionReason: "missing_code" });
    expect(renderedReads).toBeGreaterThan(0);
  });

  test("literal extraction cannot retain a prior body or rendered fallback across reads", async () => {
    const f = fixture(); let renderedReads = 0, rendered = "First rendered fallback";
    const first = '{"type":"message","text":"first"}';
    const block = observedChatGPTCodeBlock(f, first, { measuredPRE: true,
      renderedText: () => { renderedReads++; return rendered; } });
    expect((await f.inspect()).text).toBe(first); expect(renderedReads).toBe(0);
    f.answer.append(new Element("P", {}, "Authored prose"));
    expect((await f.inspect()).text).toBe(rendered); expect(renderedReads).toBeGreaterThan(0);
    rendered = "Changed rendered fallback";
    expect((await f.inspect()).text).toBe(rendered);
    f.answer.children = f.answer.children.filter(node => node === block.outer);
    const next = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf done"}}]}';
    block.code.text = next;
    const priorReads = renderedReads, result = await f.inspect();
    expect(result.error).toBeUndefined(); expect(result.text).toBe(next);
    expect(result.completionEvidence.codeStructure.selectedExtraction).toBe("raw_code");
    expect(renderedReads).toBe(priorReads);
  });

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

  test("only an explicit false suppresses the ordinary reply structure diagnostic", async () => {
    for (const flag of [undefined, true, null, 0, "false", false]) {
      const f = fixture({ userPrompt: "Owned diagnostic-budget request" });
      let walks = 0;
      Object.assign(f.document, { createTreeWalker: () => { walks++; return { nextNode: () => null }; } });
      const result = await f.inspect(flag === undefined ? {} : { requestDebugStructure: flag });
      expect(result.error).toBeUndefined(); expect(result.firstUserVerified).toBe(true);
      expect(result.firstUserMarkerVerified).toBe(true); expect(result.answerComplete).toBe(true);
      expect(result.text).toBe('{"type":"message","text":"OK"}');
      // First-message diagnostics and all completion/provenance facts remain
      // independent of the optional generic whole-document structure.
      expect(JSON.parse(result.firstUserDebugStructure)).toMatchObject({ kind: 'first_user_structure', reason: 'first_bound' });
      expect(Object.hasOwn(result, 'debugStructure')).toBe(flag !== false);
      expect(walks).toBe(flag === false ? 0 : 1);
      const fresh = await f.inspect({ requestDebugStructure: true });
      expect(JSON.parse(fresh.debugStructure)).toMatchObject({ articleUsers: 1, articleAssistants: 1 });
      expect(walks).toBe(flag === false ? 1 : 2);
    }
  });

  test("empty user or response shapes retain structure even when native declines the ordinary diagnostic", async () => {
    for (const kind of ['no_user', 'no_answer'] as const) {
      const f = fixture(kind === 'no_user' ? {} : { userPrompt: 'Owned empty-response request', response: false });
      if (kind === 'no_answer') f.body.append(new Element('BUTTON', { 'aria-label': 'Copy' }));
      let walks = 0;
      Object.assign(f.document, { createTreeWalker: () => { walks++; return { nextNode: () => null }; } });
      const result = await f.inspect({ requestDebugStructure: false });
      expect(result.error).toBeUndefined(); expect(Object.hasOwn(result, 'debugStructure')).toBe(true);
      expect(JSON.parse(result.debugStructure)).toMatchObject(kind === 'no_user'
        ? { articleUsers: 0, articleAssistants: 1 } : { articleUsers: 1, articleAssistants: 0 });
      expect(walks).toBe(1);
      if (kind === 'no_answer') {
        expect(result.firstUserVerified).toBe(true); expect(result.responseCount).toBe(0);
        expect(result.answerComplete).toBe(false); expect(result.text).toBe('');
      }
    }
  });

  test("declining a generic structure cannot suppress a first-message rejection diagnostic", async () => {
    const f = fixture({ userPrompt: 'Owned corruption-diagnostic request' }); await f.inspect();
    f.userBody!.text = f.userBody!.text.replace('Owned', 'Changed');
    const result = await f.inspect({ requestDebugStructure: false });
    expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(JSON.parse(result.debugStructure)).toMatchObject({ kind: 'first_user_structure' });
    expect(f.composer.events).toEqual([]); expect(f.chatMode.clicks).toBe(0);
  });

  test("a Copy control outside two physical answers supplies no completion proof", async () => {
    const result = await fixture({ sharedCopy: true }).inspect();
    expect(result.responseCount).toBe(2);
    expect(result.answerComplete).toBe(false);
    expect(result.completionEvidence.enabledCopies).toBe(0);
  });

  test("a lone answer cannot borrow Copy from the page or a user-containing ancestor", async () => {
    for (const boundary of ['MAIN', 'BODY', 'HTML', 'user-container']) {
      const f = fixture({ userPrompt: 'Owned request' });
      const article = f.answer.parentElement!;
      const controls = article.children.find(node => node.values.class === 'turn-action-controls')!;
      article.children = article.children.filter(node => node !== controls);
      let target = boundary === 'MAIN' ? f.messages : boundary === 'BODY' ? f.body : f.body.parentElement!;
      if (boundary === 'user-container') {
        const conversation = new Element('DIV');
        const children = [...f.messages.children]; f.messages.children = [];
        conversation.append(...children); f.messages.append(conversation); target = conversation;
      }
      target.append(controls);
      const result = await f.inspect();
      expect(result.responseCount).toBe(1);
      expect(result.answerComplete).toBe(false);
      expect(result.completionEvidence.enabledCopies).toBe(0);
      expect(await f.diagnose()).toMatchObject({ failureDiagnostic: { copyPresent: false, copyEnabled: false } });
    }
  });

  test("hidden Copy controls cannot complete a lone answer", async () => {
    const f = fixture();
    const copy = f.answer.parentElement!.querySelector('button[aria-label="Copy"]')!;
    copy.cssVisibility = 'hidden';
    const result = await f.inspect();
    expect(result.answerComplete).toBe(false);
    expect(result.completionEvidence.scopedCopies).toBe(0);
    expect(await f.diagnose()).toMatchObject({ failureDiagnostic: { copyPresent: false, copyEnabled: false } });
  });

  test("answer scope counts distinguish empty selected content from content elsewhere in its physical turn", async () => {
    const f = fixture(); f.answer.children = []; f.answer.text = '';
    const payload = 'PRIVATE_RESPONSE_CANARY';
    f.answer.parentElement!.append(new Element('DIV', {}, payload));
    const result = await f.inspect();
    expect(result.text).toBe('');
    expect(result.answerScopeDiagnostic).toMatchObject({ kind: 'chatgpt_answer_scope_v1', rootPresent: true,
      bodyPresent: true, bodyTextLength: 0, bodyChildren: 0, rootChildren: 3 });
    expect(result.answerScopeDiagnostic.rootTextLength).toBe(payload.length + 'Copy'.length);
    expect(JSON.stringify(result.answerScopeDiagnostic)).not.toContain(payload);
    const absent = await fixture({ response: false }).inspect();
    expect(absent.answerScopeDiagnostic).toEqual({ kind: 'chatgpt_answer_scope_v1', rootPresent: false,
      bodyPresent: false, bodyTextLength: 0, bodyChildren: 0, rootTextLength: 0, rootChildren: 0 });
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
    expect(f.observers[0].options?.attributeFilter).toContain("id");
    for (const attribute of ['data-talvt-turn-state', 'data-content-search-turn-key',
      'data-chatgpt-selection-message-id', 'data-tool-call-id', 'role'])
      expect(f.observers[0].options?.attributeFilter).toContain(attribute);
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

describe('response mutation notifications survive HTML replacement', () => {
  const syncStart = source.indexOf('function chatGPTSyncWorkStart(');
  const syncEnd = source.indexOf('// BEGIN COMPUTA MATCHED BENCHMARK PROBE V1', syncStart);
  const processStart = source.indexOf('function chatGPTProcessSignalRecords(');
  const processEnd = source.indexOf('function chatGPTDrainSignalRecords(', processStart);
  const filterStart = source.indexOf('function websiteModelIgnoreOwnPickerMutation(');
  const filterEnd = source.indexOf('function websiteModelHitTestTarget(', filterStart);
  const installStart = source.indexOf('if (globalThis.__computaModelSignal?.ownerToken !== input.ownerToken)');
  const installEnd = source.indexOf('// Diagnostic-only observation does not await', installStart);

  function notificationFixture(legacyHTMLTarget = false) {
    expect(syncStart).toBeGreaterThan(0); expect(syncEnd).toBeGreaterThan(syncStart);
    expect(processStart).toBeGreaterThan(0); expect(processEnd).toBeGreaterThan(processStart);
    expect(filterStart).toBeGreaterThan(0); expect(filterEnd).toBeGreaterThan(filterStart);
    expect(installStart).toBeGreaterThan(0); expect(installEnd).toBeGreaterThan(installStart);
    class Node {
      parentNode: Node | null = null;
      constructor(public nodeType: number, public attributes: Record<string, string> = {}) {}
      get parentElement() { return this.parentNode?.nodeType === 1 ? this.parentNode : null; }
      contains(target: Node | null): boolean {
        for (let node = target; node; node = node.parentNode) if (node === this) return true;
        return false;
      }
      getAttribute(name: string) { return this.attributes[name] ?? null; }
      closest(_selector: string): Node | null {
        for (let node: Node | null = this; node; node = node.parentElement)
          if (node.attributes['data-markdown-text-style'] === 'assistant-message') return node;
        return null;
      }
      querySelector() { return null; }
      querySelectorAll() { return []; }
    }
    const document = Object.assign(new Node(9), { documentElement: new Node(1) });
    document.documentElement.parentNode = document;
    const oldHTML = document.documentElement;
    const registrations: { target: Node; options: Record<string, any>; callback: (records: any[]) => void }[] = [];
    class Observer {
      constructor(public callback: (records: any[]) => void) {}
      observe(target: Node, options: Record<string, any>) { registrations.push({ target, options, callback: this.callback }); }
    }
    const posted: unknown[] = [], ownerToken = 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30';
    const world: any = { __computaModelOwner: ownerToken };
    const window: any = { webkit: { messageHandlers: { computaChatGPTSignal: {
      postMessage: (message: unknown) => posted.push(message)
    } } } }; window.top = window;
    let installation = source.slice(installStart, installEnd);
    if (legacyHTMLTarget) installation = installation.replace(
      'signal.observer.observe(document, {', 'signal.observer.observe(document.documentElement || document, {');
    const install = new Function('document', 'window', 'location', 'MutationObserver', 'globalThis', 'input',
      'const websiteChatObservePinnedMutations = () => {};\n'
      + source.slice(syncStart, syncEnd) + source.slice(filterStart, filterEnd) + source.slice(processStart, processEnd) + installation);
    install(document, window, { origin: 'https://chatgpt.com' }, Observer, world, { ownerToken });
    function deliver(record: any) {
      for (const registration of registrations) {
        if (!registration.options[record.type]) continue;
        if (record.type === 'attributes' && registration.options.attributeFilter
          && !registration.options.attributeFilter.includes(record.attributeName)) continue;
        if (record.target === registration.target
          || registration.options.subtree && registration.target.contains(record.target)) registration.callback([record]);
      }
    }
    function textIn(parent: Node) {
      const answer = new Node(1, { 'data-markdown-text-style': 'assistant-message' }); answer.parentNode = parent;
      const text = new Node(3); text.parentNode = answer; return { answer, text };
    }
    return { document, oldHTML, posted, world, ownerToken, deliver, textIn,
      replaceHTML() {
        const replacement = new Node(1); oldHTML.parentNode = null;
        replacement.parentNode = document; document.documentElement = replacement;
        deliver({ type: 'childList', target: document, addedNodes: [replacement], removedNodes: [oldHTML] });
        return replacement;
      },
      chromeIn(parent: Node) { const node = new Node(1); node.parentNode = parent; return node; }
    };
  }

  test('replacement and new answer mutations notify through the same Document and owner', () => {
    const f = notificationFixture();
    const replacement = f.replaceHTML();
    expect(f.posted).toEqual([{ ownerToken: f.ownerToken, kind: 'dom_changed' }]);
    const { answer, text } = f.textIn(replacement);
    f.deliver({ type: 'childList', target: replacement, addedNodes: [answer], removedNodes: [] });
    f.deliver({ type: 'characterData', target: text });
    expect(f.posted).toEqual(Array.from({ length: 3 }, () => ({ ownerToken: f.ownerToken, kind: 'dom_changed' })));
    const detached = f.textIn(f.oldHTML);
    f.deliver({ type: 'characterData', target: detached.text });
    expect(f.posted).toHaveLength(3);
  });

  test('the old HTML-only registration misses replacement and the newly populated answer subtree', () => {
    const f = notificationFixture(true), old = f.textIn(f.oldHTML);
    f.deliver({ type: 'characterData', target: old.text });
    expect(f.posted).toHaveLength(1); // Proves the delivery harness and callback work before replacement.
    const replacement = f.replaceHTML(), current = f.textIn(replacement);
    f.deliver({ type: 'childList', target: replacement, addedNodes: [current.answer], removedNodes: [] });
    f.deliver({ type: 'characterData', target: current.text });
    expect(f.posted).toHaveLength(1);
  });

  test('replacement notifications preserve picker-noise filtering and reject a changed owner', () => {
    const f = notificationFixture(), replacement = f.replaceHTML();
    f.posted.length = 0;
    const chrome = f.chromeIn(replacement);
    f.world.__computaModelReadUI = { until: Date.now() + 300, provider: 'chatgpt', roots: [chrome], ids: [] };
    f.deliver({ type: 'attributes', target: chrome, attributeName: 'class' });
    expect(f.posted).toHaveLength(0);
    const current = f.textIn(replacement);
    f.deliver({ type: 'characterData', target: current.text });
    expect(f.posted).toHaveLength(1);
    f.world.__computaModelOwner = '00000000-0000-4000-8000-000000000001';
    f.deliver({ type: 'characterData', target: current.text });
    expect(f.posted).toHaveLength(1);
  });
});

describe('armed observation diagnostic without inference authority', () => {
  const auxiliarySource = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-observation-diagnostic.js', import.meta.url), 'utf8');
  const install = new Function('config', 'document', 'window', 'location', 'performance', 'MutationObserver', 'setTimeout', 'clearTimeout',
    'requestAnimationFrame', 'cancelAnimationFrame', 'globalThis', 'Element', 'Date', 'URL',
    auxiliarySource + '\nreturn computaInstallObservationDiagnostic(config);');
  const binding = { schemaVersion: 1, nonce: '01000000-0000-4000-8000-000000000001', expectedSHA256: 'a'.repeat(64),
    expectedCanonicalSHA256: 'b'.repeat(64), expectedUTF8Bytes: 51657 };
  function auxiliaryFixture() {
    class RawElement extends Element {
      get innerText(): string { throw new Error('auxiliary must not read innerText'); }
      getClientRects(): any[] { throw new Error('auxiliary must not read layout'); }
      getBoundingClientRect(): any { throw new Error('auxiliary must not read geometry'); }
    }
    let clock = 0, serial = 0;
    const html = new RawElement('HTML'), body = new RawElement('BODY'), messages = new RawElement('MAIN'); html.append(body); body.append(messages);
    const send = new RawElement('BUTTON', { 'aria-label': 'Send' }); body.append(send);
    const clicks = new Set<(event: any) => void>(), pagehides = new Set<() => void>();
    const timers = new Map<number, { callback: () => void; delay: number }>(), frames = new Map<number, () => void>();
    const observers: any[] = [];
    const current: any = { ...binding, invalidReason: 'none', sendClickCount: 0, userCount: 0, assistantCount: 0,
      editorMatchesExpected: null, userMatchesExpected: null, payloadMatched: false, currentComplete: false, sendUnixMs: null };
    const probe = { nonce: binding.nonce, snapshot: () => ({ ...current }) };
    const world: any = { __computaMatchedBenchmarkProbeV1: probe, __computaModelOwner: '01000000-0000-4000-8000-000000000002' };
    const document: any = { documentElement: html, visibilityState: 'visible', hasFocus: () => true,
      querySelectorAll: (selector: string) => document.documentElement.querySelectorAll(selector),
      addEventListener: (name: string, callback: any) => { if (name === 'click') clicks.add(callback); },
      removeEventListener: (name: string, callback: any) => { if (name === 'click') clicks.delete(callback); } };
    const window: any = { addEventListener: (name: string, callback: any) => { if (name === 'pagehide') pagehides.add(callback); },
      removeEventListener: (name: string, callback: any) => { if (name === 'pagehide') pagehides.delete(callback); } }; window.top = window;
    const resources: any[] = [];
    const performance = { now: () => clock, getEntriesByType: (kind: string) => { expect(kind).toBe('resource'); return resources; } };
    class Observer {
      active = false; target: any;
      constructor(public callback: (records: any[]) => void) { observers.push(this); }
      observe(target: any) { this.active = true; this.target = target; }
      disconnect() { this.active = false; }
    }
    const location: any = { origin: 'https://chatgpt.com', pathname: '/' };
    const run = (config: any = binding) => install(config, document, window, location, performance, Observer,
      (callback: () => void, delay: number) => { const id = ++serial; timers.set(id, { callback, delay }); return id; },
      (id: number) => timers.delete(id), (callback: () => void) => { const id = ++serial; frames.set(id, callback); return id; },
      (id: number) => frames.delete(id), world, RawElement, { now: () => 1_000_000 + clock }, URL);
    const deliver = (records: any[] = [{ type: 'characterData' }]) => observers.filter(o => o.active)
      .forEach(o => o.callback(records.map(record => ({ removedNodes: [], ...record }))));
    let user: RawElement, answer: RawElement, modern: RawElement;
    return { run, world, current, timers, frames, observers, document, window, location, performance, probe, resources, deliver,
      setTime(value: number) { clock = value; },
      send() { current.sendClickCount = 1; current.sendUnixMs = 1_000_000 + clock; clicks.forEach(callback => callback({ target: send, isTrusted: false })); },
      appendAnswer(raw = '') {
        user = new RawElement('DIV', { 'data-user-message-bubble': 'true' });
        answer = new RawElement('ARTICLE', { 'data-turn': 'assistant' }); modern = new RawElement('DIV', { 'data-markdown-text-style': 'assistant-message' }, raw);
        answer.append(modern); messages.append(user, answer); current.userCount = 1; current.assistantCount = 1; deliver(); return { user, answer, modern };
      },
      qualify() { Object.assign(current, { editorMatchesExpected: true, userMatchesExpected: true, payloadMatched: true,
        editorSHA256: binding.expectedSHA256, editorCanonicalSHA256: binding.expectedCanonicalSHA256,
        userSHA256: binding.expectedCanonicalSHA256, editorUTF8Bytes: binding.expectedUTF8Bytes, userUTF8Bytes: binding.expectedUTF8Bytes }); },
      raw(text: string) { modern.text = text; deliver(); },
      fireTimer(delay = 0, advance = 4) { const entry = [...timers].find(([, task]) => task.delay === delay); if (!entry) return false;
        timers.delete(entry[0]); clock += advance; entry[1].callback(); return true; },
      fireFrame() { const entry = frames.entries().next().value; if (!entry) return false; frames.delete(entry[0]); clock += 16; entry[1](); return true; },
      pagehide() { pagehides.forEach(callback => callback()); },
      listenerCounts: () => [clicks.size, pagehides.size]
    };
  }

  test('the original Probe5 source remains byte-identical', () => {
    const begin = source.indexOf('// BEGIN COMPUTA MATCHED BENCHMARK PROBE V1');
    const endMarker = '// END COMPUTA MATCHED BENCHMARK PROBE V1.\n';
    const end = source.indexOf(endMarker, begin) + endMarker.length;
    expect(createHash('sha256').update(source.slice(begin, end)).digest('hex')).toBe('665280936fd0dfd7bf1281f81ff10c30d84fffdaffd3f4aba177caf7bc85dcb1');
  });

  test('synchronous cost recording is dormant before Send and reads no proof or DOM query', () => {
    const f = auxiliaryFixture(), api = f.run();
    const empty = Array.from({ length: 5 }, () => [0, 0, 0, false]);
    expect(api.syncNow()).toBeNull(); api.recordSync(0, 0);
    expect(api.snapshot().syncWork).toEqual(empty);
    f.setTime(100); f.send(); f.appendAnswer('HI');
    const originalQuery = f.document.querySelectorAll, originalSnapshot = f.probe.snapshot;
    f.document.querySelectorAll = () => { throw Error('recording must not query the DOM'); };
    f.probe.snapshot = () => { throw Error('recording must not read the source proof'); };
    const scheduled = [f.timers.size, f.frames.size, f.observers.length];
    const began = api.syncNow(); f.setTime(107); api.recordSync(0, began);
    const second = api.syncNow(); f.setTime(110); api.recordSync(0, second);
    expect([f.timers.size, f.frames.size, f.observers.length]).toEqual(scheduled);
    f.document.querySelectorAll = originalQuery; f.probe.snapshot = originalSnapshot;
    expect(api.snapshot().syncWork[0]).toEqual([2, 10, 7, false]);
    expect(api.snapshot().payloadBindingVerified).toBe(false);
  });

  test('synchronous samples have finite call budgets and never mutate frozen metrics', () => {
    const f = auxiliaryFixture(), api = f.run(); f.setTime(100); f.send(); f.appendAnswer('HI');
    for (const invalid of [null, undefined, true, '100', NaN, Infinity, -1]) api.recordSync(0, invalid);
    for (const invalid of [-1, 5, 0.5, true, '0']) api.recordSync(invalid, 100);
    expect(api.snapshot().syncWork[0]).toEqual([0, 0, 0, false]);
    for (let i = 0; i < 257; i++) {
      f.setTime(100 + i); const began = api.syncNow(); f.setTime(101 + i); api.recordSync(0, began);
    }
    expect(api.snapshot().syncWork[0]).toEqual([256, 256, 1, true]);
    const originalNow = f.performance.now; f.performance.now = () => { throw Error('clock unavailable'); };
    expect(api.syncNow()).toBeNull(); expect(() => api.recordSync(1, 100)).not.toThrow();
    f.performance.now = originalNow;
    expect(api.snapshot().syncWork[1]).toEqual([0, 0, 0, true]);
    f.qualify(); const beforeStop = api.syncNow(), stopped = api.stop();
    f.setTime(1000); api.recordSync(0, beforeStop);
    expect(api.syncNow()).toBeNull(); expect(api.snapshot().syncWork).toEqual(stopped.syncWork);
    expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
  });

  test('late body cadence measures eight actual timer intervals without any DOM or proof reads', () => {
    const f = auxiliaryFixture(), api = f.run(); f.setTime(100); f.send(); f.setTime(500); f.appendAnswer();
    const originalQuery = f.document.querySelectorAll, originalSnapshot = f.probe.snapshot;
    const html = f.document.documentElement;
    f.document.querySelectorAll = () => { throw Error('late cadence must not query'); };
    f.probe.snapshot = () => { throw Error('late cadence must not read proof'); };
    Object.defineProperty(f.document, 'documentElement', { configurable: true, get() { throw Error('late cadence must not read DOM identity'); } });
    for (let i = 0; i < 8; i++) expect(f.fireTimer(250, i === 4 ? 1000 : 250)).toBe(true);
    expect(f.fireTimer(250)).toBe(false);
    Object.defineProperty(f.document, 'documentElement', { configurable: true, writable: true, value: html });
    f.document.querySelectorAll = originalQuery; f.probe.snapshot = originalSnapshot;
    const measured = api.snapshot();
    expect(measured.bodyTimerIntervals).toHaveLength(8);
    expect(measured.bodyTimerIntervals.map((row: number[]) => row[1])).toEqual([250, 250, 250, 250, 1000, 250, 250, 250]);
    expect(measured.bodyTimerIntervals[0][0]).toBe(650);
    expect(measured.firstRawTextAfterSendMs).toBeNull(); expect(measured.payloadBindingVerified).toBe(false);
    api.stop(); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
  });

  test('late cadence respects the existing stop and fifteen-second boundaries without rescheduling', () => {
    for (const expired of [false, true]) {
      const f = auxiliaryFixture(), api = f.run(); f.setTime(100); f.send(); f.setTime(200); f.appendAnswer('HI');
      const late = [...f.timers.values()].find(timer => timer.delay === 250)!.callback;
      if (expired) {
        f.setTime(15101); expect(f.fireTimer(250, 0)).toBe(true);
        expect([...f.timers.values()].some(timer => timer.delay === 250)).toBe(false);
        expect(f.fireTimer(15000, 0)).toBe(true);
      } else api.stop();
      const frozen = api.snapshot(); f.setTime(16000); late();
      expect(api.snapshot().bodyTimerIntervals).toEqual(frozen.bodyTimerIntervals);
      expect(api.snapshot().callbacks).toBe(frozen.callbacks);
      expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
    }
  });

  test('all diagnostic arrays and five saturated cost rows fit the existing payload limit', () => {
    const f = auxiliaryFixture(), api = f.run(); f.setTime(100); f.send();
    let clock = 100;
    for (let row = 0; row < 5; row++) for (let call = 0; call < 257; call++) {
      const began = api.syncNow(); f.setTime(++clock); api.recordSync(row, began);
    }
    for (let i = 0; i < 12; i++) expect(f.fireTimer()).toBe(true);
    for (let i = 0; i < 8; i++) expect(f.fireFrame()).toBe(true);
    f.setTime(1600); f.appendAnswer();
    for (let i = 0; i < 8; i++) expect(f.fireFrame()).toBe(true);
    for (let i = 0; i < 8; i++) expect(f.fireTimer(250, 250)).toBe(true);
    f.raw('x'.repeat(220002)); f.qualify(); f.current.currentComplete = true;
    for (let i = 0; i < 8; i++) f.resources.push({ initiatorType: 'script', name: `https://chatgpt.com/script-${i}.js`,
      startTime: 0, responseEnd: 3000, duration: 3000,
      encodedBodySize: 1073741824, decodedBodySize: 1073741824, transferSize: 1073741824 });
    const final = api.stop(), json = JSON.stringify(final);
    expect(final.syncWork).toEqual(Array.from({ length: 5 }, () => [256, 256, 1, true]));
    expect(final.timerIntervals).toHaveLength(12); expect(final.rafEarlyIntervals).toHaveLength(8);
    expect(final.rafBodyIntervals).toHaveLength(8); expect(final.bodyTimerIntervals).toHaveLength(8);
    expect(final.visibilityFocus).toHaveLength(4); expect(final.resourceSummary.entries).toHaveLength(8);
    expect(final.firstRawTextUTF16Length).toBe(220001); expect(final.firstRawTextCountClamped).toBe(true);
    expect(final.payloadBindingVerified).toBe(true); expect(final.sourceProbeCurrentComplete).toBe(true);
    expect(Buffer.byteLength(json)).toBeLessThanOrEqual(4096); expect(JSON.parse(json)).toEqual(final);
    expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
  });

  test('observer cost finally preserves the actual guard result and original exception', async () => {
    const f = fixture({ userPrompt: 'Owned synchronous guard request' }); await f.inspect();
    const posted = f.posted.length, indices: number[] = [];
    f.world.__computaObservationDiagnosticV1 = { syncNow() { throw Error('diagnostic clock failed'); },
      recordSync(index: number) { indices.push(index); throw Error('diagnostic recorder failed'); } };
    const record = { type: 'characterData', target: f.answer.children[0].childNodes[0] };
    expect(() => f.observers[0].callback([record])).not.toThrow();
    expect(f.posted.length).toBe(posted + 1); expect(indices).toEqual([0]);
    const original = f.document.querySelectorAll, failure = new Error('actual product discovery failed');
    f.document.querySelectorAll = selector => {
      if (selector === '[aria-label], [aria-labelledby]') throw failure;
      return original(selector);
    };
    let thrown: unknown;
    try { f.observers[0].callback([record]); } catch (error) { thrown = error; }
    expect(thrown).toBe(failure); expect(indices).toEqual([0, 0]);
    expect(f.posted.length).toBe(posted + 1);
    f.document.querySelectorAll = original;
  });

  test('ineligible configuration and missing source probe create no observer or scheduled work', () => {
    for (const config of [{ ...binding, extra: true }, { ...binding, expectedUTF8Bytes: true }, { ...binding, nonce: 'ABCDEF00-0000-4000-8000-000000000001' },
      Object.assign({ ...binding }, { [Symbol('extra')]: true })]) {
      const f = auxiliaryFixture(); expect(f.run(config)).toBeNull(); expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
    }
    const f = auxiliaryFixture(); delete f.world.__computaMatchedBenchmarkProbeV1; expect(f.run()).toBeNull(); expect(f.listenerCounts()).toEqual([0, 0]);
  });

  test('install is idle; one Send records bounded raw and scheduling observations before late clipped-user qualification', () => {
    const f = auxiliaryFixture(), api = f.run(); expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
    f.setTime(100); f.send(); expect(f.observers[0].target).toBe(f.document);
    for (let i = 0; i < 12; i++) expect(f.fireTimer()).toBe(true);
    expect(f.fireTimer()).toBe(false); for (let i = 0; i < 8; i++) expect(f.fireFrame()).toBe(true);
    f.current.editorMatchesExpected = true; f.current.userMatchesExpected = false; f.setTime(500); f.appendAnswer();
    for (let i = 0; i < 8; i++) expect(f.fireFrame()).toBe(true);
    f.setTime(900); f.raw('JSON'); const tentative = api.snapshot();
    expect(tentative.firstModernBodyAfterSendMs).toBe(400); expect(tentative.firstRawTextAfterSendMs).toBe(800);
    expect(tentative.firstRawTextUTF16Length).toBe(4); expect(tentative.payloadBindingVerified).toBe(false);
    f.qualify(); f.current.currentComplete = true; f.setTime(1100); const final = api.stop();
    expect(final.payloadBindingVerified).toBe(true); expect(final.firstRawTextAfterSendMs).toBe(800);
    expect(final.timerIntervals).toHaveLength(12); expect(final.rafEarlyIntervals).toHaveLength(8); expect(final.rafBodyIntervals).toHaveLength(8);
    expect(final.visibilityFocus).toHaveLength(4); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0); expect(f.listenerCounts()).toEqual([0, 0]);
    f.setTime(1200); f.raw('later'); expect(api.snapshot().firstRawTextAfterSendMs).toBe(800);
  });

  test('deadline freezes metrics but later full Probe5 proof can bind the same physical clipped user', () => {
    const f = auxiliaryFixture(), api = f.run(); f.setTime(100); f.send(); f.current.editorMatchesExpected = true; f.current.userMatchesExpected = false;
    f.setTime(1000); f.appendAnswer('HI'); f.current.currentComplete = true;
    for (let i = 0; i < 300; i++) f.resources.push({ name: `https://chatgpt.com/private-module-${i}.js?secret=never-output`, initiatorType: 'script',
      startTime: 50, responseEnd: 14000, duration: 13950, encodedBodySize: 12, decodedBodySize: 24, transferSize: 42 });
    f.resources.push({ name: 'https://chatgpt.com/not-yet-ended.js', initiatorType: 'script', startTime: 1, responseEnd: 20000, duration: 19999 });
    f.resources.push({ name: 'https://chatgpt.com/invalid-duration.js', initiatorType: 'script', startTime: 50, responseEnd: 14000, duration: -7 });
    f.setTime(15100); expect(f.fireTimer(15000, 3)).toBe(true); const pending = api.snapshot();
    expect(pending.endedReason).toBe('deadline'); expect(pending.payloadBindingVerified).toBe(false);
    expect(pending.resourceSummary.available).toBe(true); expect(pending.resourceSummary.scanTruncated).toBe(true);
    expect(pending.resourceSummary.entries).toHaveLength(8); expect(pending.resourceSummary.entries[0][0]).toBe(-50);
    expect(pending.resourceSummary.entries.at(-1)[2]).toBeNull();
    expect(JSON.stringify(pending)).not.toContain('private-module'); expect(JSON.stringify(pending)).not.toContain('secret');
    const earlier = pending.firstRawTextAfterSendMs; f.setTime(30000); f.qualify(); const late = api.snapshot();
    expect(late.payloadBindingVerified).toBe(true); expect(late.firstRawTextAfterSendMs).toBe(earlier); expect(late.expired).toBe(true);
    expect(late.resourceSummary).toEqual(pending.resourceSummary); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
    expect(new TextEncoder().encode(JSON.stringify(late)).length).toBeLessThanOrEqual(4096);
  });

  test('document/owner/physical-root changes and record overflow remain irreversible negatives', () => {
    for (const failure of ['document', 'owner', 'removed', 'records'] as const) {
      const f = auxiliaryFixture(), api = f.run(); f.send(); const nodes = f.appendAnswer('HI'); f.qualify();
      if (failure === 'document') f.document.documentElement = new Element('HTML');
      if (failure === 'owner') f.world.__computaModelOwner = 'different';
      if (failure === 'removed') f.deliver([{ type: 'childList', removedNodes: [nodes.answer] }]);
      if (failure === 'records') f.deliver(Array.from({ length: 1025 }, () => ({ type: 'characterData' })));
      const snapshot = api.snapshot(); expect(snapshot.stopped).toBe(true); expect(snapshot.payloadBindingVerified).toBe(false);
      if (failure === 'records') { expect(snapshot.endedReason).toBe('record_budget'); expect(snapshot.mutationRecords).toBe(1025); }
      f.qualify(); expect(api.snapshot().payloadBindingVerified).toBe(false); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
    }
  });

  test('setup expiry, changed immutable binding and a second Send do not create a new measurement', () => {
    const f = auxiliaryFixture(), api = f.run(); expect(f.run({ ...binding, expectedSHA256: 'c'.repeat(64) })).toBeNull();
    f.setTime(15001); f.send(); expect(api.snapshot().sourceProbeSendObserved).toBe(false); expect(api.snapshot().expired).toBe(true);
    expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0); expect(f.frames.size).toBe(0);
    const g = auxiliaryFixture(), other = g.run(); g.send(); g.send(); expect(other.snapshot().invalidReason).toBe('multiple_send_clicks');
  });
});
