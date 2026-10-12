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
  onDispatch?: (event: any) => void;
  onFocus?: () => void;
  events: unknown[] = [];
  constructor(public tagName: string, public values: Record<string, string> = {}, public text = "") {}
  get nodeType() { return this.tagName === "#text" ? 3 : 1; }
  get childElementCount() { return this.children.filter(child => child.nodeType === 1).length; }
  get attributes() { return Object.entries(this.values).map(([name, value]) => ({ name, value })); }
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
  getClientRects() { return this.isConnected && !this.closest('[hidden]') ? [{}] : []; }
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
  dispatchEvent(event: unknown) { this.events.push(event); this.onDispatch?.(event); return true; }
}

// Selector fixtures mirror the observed native picker semantics. They qualify
// selection/ownership behavior; live DOM diagnostics separately qualify shape.
export function installObservedModelPicker(f: any, provider: 'chatgpt' | 'gemini' | 'claude', Node: any = Element,
  behavior: { genericHeader?: boolean; unmountMenus?: boolean; replacePrimaryOnSecondary?: boolean; geminiMenuitemMarkers?: boolean;
    escapeOnlyClose?: boolean; inlineFamilyPanel?: boolean; parentReturnAfterSelection?: boolean } = {}) {
  if (provider === 'chatgpt') return installObservedChatPowerPicker(f, Node, behavior);
  const initial = provider === 'chatgpt' ? 'GPT-5.6 Sol' : provider === 'gemini' ? '3.1 Pro' : 'Sonnet 5.5';
  let selectedLabel = initial;
  const triggerLabel = () => provider === 'chatgpt' ? 'Select ChatGPT model'
    : provider === 'gemini' ? 'Open mode picker, currently Gemini Pro' : `Model: ${selectedLabel} Medium`;
  const primary = new Node('SPAN', {}, behavior.genericHeader ? '' : initial);
  const trigger = new Node('BUTTON', { id: 'model-picker-button', 'aria-controls': 'model-picker-menu', 'aria-haspopup': 'menu', 'aria-label': '' });
  trigger.values['aria-label'] = triggerLabel();
  trigger.append(primary, new Node('SPAN', {}, 'Medium'));
  const menu = new Node('DIV', { id: 'model-picker-menu', role: 'menu', 'aria-labelledby': 'model-picker-button', hidden: '' });
  const secondary = provider === 'gemini' ? null : new Node('BUTTON', { id: 'model-family-button', 'aria-label': provider === 'chatgpt' ? 'Select model' : 'More models', 'aria-controls': 'model-family-menu', 'aria-haspopup': 'menu' });
  const nested = secondary ? new Node('DIV', { id: 'model-family-menu', role: 'menu', 'aria-labelledby': 'model-family-button', hidden: '' }) : null;
  let inlinePanel: any;
  const options: any[] = [];
  const syncIndicators = () => {
    if (provider !== 'gemini' || !behavior.geminiMenuitemMarkers) return;
    for (const option of options) {
      option.values.role = 'menuitem'; delete option.values['aria-checked'];
      option.children = option.children.filter((child: any) => child.values['aria-label'] !== 'Selected');
      option.values.class = option.children[0].text === selectedLabel ? 'ng-star-inserted selected' : 'ng-star-inserted';
      if (option.children[0].text === selectedLabel) option.append(new Node('GEM-ICON', { 'aria-label': 'Selected', class: 'ng-star-inserted' }));
    }
  };
  const add = (scope: any, label: string, description = '', extra: Record<string, string> = {}) => {
    const option = new Node('DIV', { role: 'menuitemradio', 'aria-checked': label === initial ? 'true' : 'false', ...extra });
    option.append(new Node('SPAN', {}, label), new Node('SPAN', {}, description));
    options.push(option); scope.append(option);
    option.onClick = () => {
      selectedLabel = label;
      if (!behavior.genericHeader) primary.text = label;
      trigger.values['aria-label'] = triggerLabel();
      options.forEach(other => { other.values['aria-checked'] = other === option ? 'true' : 'false'; });
      syncIndicators();
      menu.values.hidden = ''; if (nested) nested.values.hidden = '';
      if (behavior.unmountMenus) { menu.connected = false; if (nested) nested.connected = false; }
      trigger.values['aria-expanded'] = 'false';
      if (provider === 'chatgpt' && behavior.parentReturnAfterSelection) {
        menu.connected = true; delete menu.values.hidden; trigger.values['aria-expanded'] = 'true';
        trigger.values['aria-controls'] = 'model-picker-menu';
        if (inlinePanel) {
          inlinePanel.values.hidden = ''; delete secondary.values.hidden;
          for (const child of menu.children) if (child !== inlinePanel && child !== secondary) delete child.values.hidden;
        }
      }
    };
    return option;
  };
  if (provider === 'chatgpt') {
    menu.append(new Node('DIV', { role: 'radio', 'aria-checked': 'true' }, 'Medium'));
    add(nested, 'Latest'); add(nested, 'GPT-5.6 Sol'); add(nested, 'GPT-5.5', 'Leaving October 14');
  } else if (provider === 'gemini') {
    add(menu, '3.5 Flash-Lite', 'Fastest answers'); add(menu, '3.8 Flash', 'All-around help'); add(menu, '3.1 Pro', 'Advanced reasoning');
    menu.append(new Node('DIV', { role: 'menuitemcheckbox', 'aria-checked': 'true' }, 'Extended thinking'));
  } else {
    add(menu, 'Sonnet 5.5'); add(menu, 'Haiku 4.5'); add(menu, 'Fable 6', 'Upgrade');
    add(nested, 'Sonnet 5'); add(nested, 'Sonnet 4.6'); add(nested, 'Opus 4.8', 'Upgrade');
  }
  syncIndicators();
  if (provider === 'chatgpt' && behavior.inlineFamilyPanel) {
    inlinePanel = new Node('DIV', { hidden: '' });
    inlinePanel.append(...nested.children); nested.children = [];
    menu.append(inlinePanel);
    secondary.tagName = 'DIV'; secondary.values.role = 'menuitem';
    delete secondary.values['aria-haspopup']; delete secondary.values['aria-controls'];
    const text = new Node('DIV'); text.append(new Node('SPAN', {}, 'Select model'), new Node('SVG', {}, 'Decorative arrow'));
    secondary.append(text);
  }
  if (secondary) menu.append(secondary);
  f.body.append(trigger, menu); if (nested) f.body.append(nested);
  trigger.onClick = () => {
    if (menu.values.hidden === undefined || behavior.replacePrimaryOnSecondary && nested?.values.hidden === undefined) {
      if (provider === 'chatgpt' && behavior.escapeOnlyClose) return;
      menu.values.hidden = ''; if (nested) nested.values.hidden = ''; trigger.values['aria-expanded'] = 'false';
      if (behavior.unmountMenus) { menu.connected = false; if (nested) nested.connected = false; }
    } else {
      trigger.values['aria-controls'] = 'model-picker-menu';
      if (inlinePanel) {
        inlinePanel.values.hidden = ''; delete secondary.values.hidden;
        for (const child of menu.children) if (child !== inlinePanel && child !== secondary) delete child.values.hidden;
      }
      menu.connected = true; delete menu.values.hidden; trigger.values['aria-expanded'] = 'true';
    }
  };
  if (secondary) secondary.onClick = () => {
    if (inlinePanel) {
      for (const child of menu.children) if (child !== inlinePanel) child.values.hidden = '';
      delete inlinePanel.values.hidden;
      return;
    }
    if (behavior.replacePrimaryOnSecondary) {
      menu.values.hidden = ''; if (behavior.unmountMenus) menu.connected = false;
      nested.values['aria-labelledby'] = 'model-picker-button';
      trigger.values['aria-controls'] = 'model-family-menu';
    }
    nested.connected = true; delete nested.values.hidden;
  };
  if (provider === 'chatgpt') {
    const dismiss = (event: any) => {
      if (event.type !== 'keydown' || event.key !== 'Escape') return;
      menu.values.hidden = ''; if (nested) nested.values.hidden = '';
      if (behavior.unmountMenus) { menu.connected = false; if (nested) nested.connected = false; }
      trigger.values['aria-expanded'] = 'false';
    };
    menu.onDispatch = dismiss; if (nested) nested.onDispatch = dismiss;
  }
  if (behavior.unmountMenus) { menu.connected = false; if (nested) nested.connected = false; }
  return { trigger, primary, menu, secondary, nested, inlinePanel, options, add, initial,
    choice: (label: string) => ({ key: label, label }),
    open: () => { menu.connected = true; delete menu.values.hidden; if (nested) { nested.connected = true; delete nested.values.hidden; } },
    selected: (label: string) => {
      selectedLabel = label; if (!behavior.genericHeader) primary.text = label; trigger.values['aria-label'] = triggerLabel();
      options.forEach(option => { option.values['aria-checked'] = option.children[0].text === label ? 'true' : 'false'; });
      syncIndicators();
    } };
}

// Mirrors the measured Chat-only zero-based slider and same-popup family panel.
// Power entries below are telemetry for keyboard steps, not invented DOM radios.
function installObservedChatPowerPicker(f: any, Node: any, behavior: any) {
  const labels = ['Instant', 'Medium', 'High', 'Extra High', 'Pro'];
  let powerIndex = 1, selectedFamily = 'GPT-6';
  const primary = new Node('SPAN', {}, behavior.genericHeader ? '' : selectedFamily);
  const trigger = new Node('BUTTON', { id: 'model-picker-button', 'aria-label': 'Select ChatGPT model',
    'aria-haspopup': 'menu', 'aria-expanded': 'false', 'aria-controls': 'model-picker-menu' });
  trigger.append(primary);
  let menu = new Node('DIV', { id: 'model-picker-menu', role: 'menu', 'aria-labelledby': 'model-picker-button', hidden: '' });
  const powerItem = new Node('DIV', { role: 'menuitem', 'aria-label': 'Power', tabindex: '-1' });
  const slider = new Node('SPAN', { role: 'slider', 'aria-valuemin': '0', 'aria-valuemax': '4', 'aria-valuenow': '1',
    'aria-orientation': 'horizontal', tabindex: '-1' });
  slider.focus = () => { f.document.activeElement = slider; };
  powerItem.append(slider);
  const secondary = new Node('DIV', { role: 'menuitem', 'aria-label': 'Select model', tabindex: '-1' }, 'Select model');
  const familyOptions = ['GPT-6', 'GPT-5.6 Sol', 'GPT-5.5'].map(label => {
    const node = new Node('DIV', { role: 'menuitemradio', 'aria-checked': label === selectedFamily ? 'true' : 'false' });
    node.append(new Node('DIV', {}, label === 'GPT-5.5' ? label + '\nLeaving on October 14' : label));
    node.onClick = () => {
      selectedFamily = label; if (!behavior.genericHeader) primary.text = label;
      familyOptions.forEach(other => { other.values['aria-checked'] = other === node ? 'true' : 'false'; });
      if (behavior.parentReturnAfterSelection) showPower(); else close();
    };
    return node;
  });
  const options = labels.map((label, index) => {
    const node = new Node('SPAN'); node.append(new Node('SPAN', {}, label));
    node.values = new Proxy({} as Record<string, string>, {
      get: (_target, name: string) => name === 'aria-checked' ? String(powerIndex === index) : undefined,
      set: (_target, name: string, value: string) => {
        if (name === 'aria-checked' && value === 'true') selected(label);
        else if (name === 'aria-disabled' && value === 'true') slider.values['aria-disabled'] = 'true';
        return true;
      },
    });
    return node;
  });
  const mount = (children: any[]) => {
    menu.children.forEach((node: any) => { node.parentElement = null; });
    menu.children = []; menu.append(...children);
    menu.connected = true; delete menu.values.hidden; menu.values['data-state'] = 'open';
    trigger.values['aria-expanded'] = 'true';
  };
  const showPower = () => mount([powerItem, secondary]);
  const close = () => {
    menu.values.hidden = ''; menu.values['data-state'] = 'closed'; trigger.values['aria-expanded'] = 'false';
    if (behavior.unmountMenus) menu.connected = false;
  };
  trigger.onClick = () => {
    if (menu.values.hidden === undefined) { if (!behavior.escapeOnlyClose) close(); }
    else showPower();
  };
  secondary.onClick = () => mount(familyOptions);
  menu.onDispatch = (event: any) => { if (event.type === 'keydown' && event.key === 'Escape') close(); };
  slider.onDispatch = (event: any) => {
    if (event.type !== 'keydown' || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    const next = Math.max(0, Math.min(4, powerIndex + (event.key === 'ArrowRight' ? 1 : -1)));
    if (next !== powerIndex) { powerIndex = next; slider.values['aria-valuenow'] = String(next); options[next].clicks++; }
  };
  function selected(label: string) {
    const index = labels.indexOf(label === 'GPT-6 Pro' ? 'Pro' : label);
    if (index >= 0) { powerIndex = index; slider.values['aria-valuenow'] = String(index); }
    else {
      selectedFamily = label;
      familyOptions.forEach(node => { node.values['aria-checked'] = node.children[0].text.split('\n')[0] === label ? 'true' : 'false'; });
      if (!behavior.genericHeader) primary.text = label;
    }
  }
  f.body.append(trigger, menu);
  const seedPriorSelection = (action: string, overrides: any) => {
    // Mid-turn ownership fixtures begin after native selection; fresh selector
    // tests never seed their own evidence. A later drift cannot replace this pin.
    if ((overrides.expectedModelChoice || overrides.firstUserExpansionModelChoice)
      && !f.world.__computaChatPresetPin && action !== 'selectModel')
      f.world.__computaChatPresetPin = { owner: ownerToken, document: f.document,
        selection: { family: { key: selectedFamily, label: selectedFamily },
          power: { key: ['instant', 'medium', 'high', 'extra-high', 'pro'][powerIndex], label: labels[powerIndex] } } };
  };
  if (typeof f.run === 'function') {
    const run = f.run.bind(f);
    f.run = (action = 'inspect', overrides: any = {}, adopt = true) => {
      seedPriorSelection(action, overrides); return run(action, overrides, adopt);
    };
  } else {
    const inspect = f.inspect.bind(f);
    f.inspect = (overrides: any = {}, adopt = true) => {
      seedPriorSelection(overrides.action || 'inspect', overrides); return inspect(overrides, adopt);
    };
  }
  return { trigger, get menu() { return menu; }, get nested() { return menu; }, secondary, primary,
    options, familyOptions, slider, powerItem, selected, open: showPower, showPower,
    showFamily: () => mount(familyOptions), close,
    replaceMenu: (id: string) => {
      menu.connected = false; menu.values.hidden = '';
      menu = new Node('DIV', { id, role: 'menu', 'aria-labelledby': 'model-picker-button', hidden: '' });
      menu.onDispatch = (event: any) => { if (event.type === 'keydown' && event.key === 'Escape') close(); };
      menu.connected = !behavior.unmountMenus; f.body.append(menu);
      trigger.values['aria-controls'] = id;
      return menu;
    } };

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
  const window: any = { webkit: { messageHandlers: { computaChatGPTSignal: { postMessage: (value: unknown) => posted.push(value) } } }, getSelection: () => selection,
    KeyboardEvent: class { constructor(public type: string, options: any) { Object.assign(this, options); } } }; window.top = window;
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
    if (provider === "gemini" || messages.querySelector('[data-testid="user-message"]')) messages.append(wrapper);
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
