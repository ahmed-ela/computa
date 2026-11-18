import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';
const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
const driver = readFileSync(new URL('./EmbeddedSavedProviders/deepseek-dom.js', import.meta.url), 'utf8');
const engine = readFileSync(new URL('./EmbeddedSavedProviders/saved-conversation-engine.js', import.meta.url), 'utf8');
const entry = readFileSync(new URL('./EmbeddedSavedProviders/deepseek-entry.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const arrow = /const arrow = '([^']+)'/.exec(driver)![1];
export const conversation = 'https://chat.deepseek.com/a/chat/s/12345678-abcd-4321-8765-123456789abc';
export const raw = '{"type":"message","text":"DEEPSEEKFIXTURE383"}';
export const ownerToken = '3336cfe2-11f6-4878-a803-af2efe05a797';
export const generation = '7d90b8a1-0b0f-4801-b995-0bba581a5d8c';
export const marker = '12222222-3333-4444-8555-666666666666';
export const prompt = 'Synthetic exact prompt\n\nComputa session marker: ' + marker;
export const mode = (key = 'chat') => ({ key, label: key === 'chat' ? 'Chat' : 'DeepThink' });
export const fingerprint = async (value: string) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value.replace(/\r\n?/g, '\n').normalize('NFC').trim())))].map(byte => byte.toString(16).padStart(2, '0')).join('');
export function fixture(options: { fresh?: boolean; completeOnSend?: boolean } = {}) {
  let hit: any, occluded: any;
  class Node extends Element {
    _value = '';
    get value() { return this._value; }
    set value(value: string) { this._value = value; }
    detach() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this); this.parentElement = null; this.connected = false; }
    append(...nodes: Element[]) { nodes.forEach(node => { node.connected = true; }); super.append(...nodes); }
    getBoundingClientRect() { hit = this; return { left: 10, top: 10, width: 100, height: 30 }; }
    querySelectorAll(selector: string) {
      if (!selector.includes(' > ')) return super.querySelectorAll(selector);
      const parts = selector.split(/\s+>\s+/);
      const matches = (node: Element, part: string) => Element.prototype.querySelectorAll.call({ descendants: () => [node] }, part).length === 1;
      return this.descendants().filter(candidate => {
        let current: Element | null = candidate;
        for (let i = parts.length - 1; i >= 0; i--) {
          if (!current || !matches(current, parts[i])) return false;
          current = current.parentElement;
        }
        return true;
      });
    }
  }
  class TextArea extends Node {
    get value() { return this._value; }
    set value(value: string) { this._value = value; }
  }
  const body = new Node('BODY'), html = new Node('HTML'); html.append(body);
  const document: any = { URL: conversation, body, documentElement: html,
    querySelectorAll: (selector: string) => html.querySelectorAll(selector),
    elementFromPoint: () => hit === occluded ? body : hit };
  const window: any = { innerWidth: 1000, innerHeight: 800 }; window.top = window;
  const scope = new Node('DIV', { class: '_020ab5b' });
  const editor = new TextArea('TEXTAREA', { placeholder: 'Message DeepSeek' }); scope.append(editor); body.append(scope);
  const deepThink = new Node('DIV', { class: 'ds-toggle-button', 'aria-pressed': 'false', tabindex: '0' });
  const search = new Node('DIV', { class: 'ds-toggle-button', 'aria-pressed': 'false', tabindex: '0' });
  deepThink.append(new Node('SPAN', {}, 'DeepThink')); search.append(new Node('SPAN', {}, 'Search')); scope.append(deepThink, search);
  const send = new Node('DIV', { role: 'button', class: 'ds-button ds-button--primary ds-button--circle ds-button--disabled' });
  const svg = new Node('SVG', { viewBox: '0 0 16 16' }), path = new Node('PATH', { d: arrow }); svg.append(path); send.append(svg); scope.append(send);
  const userTurn = new Node('DIV', { 'data-virtual-list-item-key': '-2' });
  const user = new Node('DIV', { class: 'd29f3d7d ds-message' });
  const collapse = new Node('DIV', { class: 'ds-collapsible-text' }), wrapper = new Node('DIV');
  const firstText = new Node('SPAN', {}, 'Synthetic exact prompt\n\nComputa session marker: 12222222-3333-4444-8555-666666666666');
  wrapper.append(firstText); collapse.append(wrapper); user.append(collapse); userTurn.append(user); body.append(userTurn);
  const answerTurn = new Node('DIV', { 'data-virtual-list-item-key': '2' });
  const answer = new Node('DIV', { class: 'ds-message' });
  const reasoning = new Node('DIV', { class: '_74c0879' });
  Object.defineProperty(reasoning, 'textContent', { get() { throw new Error('Reasoning must never be read'); } });
  const final = new Node('DIV', { class: 'ds-markdown ds-assistant-message-main-content' });
  const paragraph = new Node('P', { class: 'ds-markdown-paragraph' }), literal = new Node('SPAN', {}, raw);
  paragraph.append(literal); final.append(paragraph); answer.append(final); answerTurn.append(answer);
  const rail = new Node('DIV', { class: 'ds-flex _965abe9' });
  const actions = Array.from({ length: 6 }, (_, i) => new Node('DIV', { role: 'button', class: 'ds-button', ...(i === 4 ? { 'aria-label': 'Read aloud' } : {}) }));
  rail.append(...actions); answerTurn.append(rail); body.append(answerTurn);
  const anchor = new Node('A', { href: '/a/chat/s/12345678-abcd-4321-8765-123456789abc' });
  const trigger = new Node('DIV', { role: 'button', class: 'ds-button' }); anchor.append(new Node('DIV', {}, 'Synthetic history entry'), trigger); body.append(anchor);
  const menu = new Node('DIV', { role: 'menu', class: 'ds-dropdown-menu ds-elevated' });
  const remove = new Node('DIV', { class: 'ds-dropdown-menu-option ds-dropdown-menu-option--error' });
  remove.append(new Node('DIV', { class: 'ds-dropdown-menu-option__label' }, 'Delete')); menu.append(remove);
  const modal = new Node('DIV', { class: 'ds-modal', 'aria-modal': 'true' });
  const dialog = new Node('DIV', { role: 'dialog', class: 'ds-modal-content ds-modal-content--dialog' }); modal.append(dialog);
  const title = new Node('DIV', { class: 'ds-modal-content__title' }, 'This chat can’t be recovered.');
  const notice = new Node('DIV', { class: 'ds-modal-content__main' }, 'Share links from it will be disabled.');
  const group = new Node('DIV', { class: 'ds-modal-content__button-group' });
  const cancel = new Node('DIV', { role: 'button', class: 'ds-button ds-button--outlinedNeutral' });
  const confirm = new Node('DIV', { role: 'button', class: 'ds-button ds-button--error' });
  cancel.append(new Node('SPAN', { class: 'ds-button__content' }, 'Cancel')); confirm.append(new Node('SPAN', { class: 'ds-button__content' }, 'Delete chat'));
  group.append(cancel, confirm); dialog.append(title, notice, group);
  const world: any = {};
  const execute = new Function('input', 'document', 'window', 'globalThis', 'location', 'getComputedStyle', 'MutationObserver', 'HTMLTextAreaElement', 'InputEvent',
    core + '\n' + engine + '\n' + driver + '\nreturn computaDeepSeekDOM(computaProviderCore(input,"deepseek","https://chat.deepseek.com",["inspect"]));');
  const observers: any[] = [], signals: any[] = [];
  window.webkit = { messageHandlers: { computaChatGPTSignal: { postMessage: (value: any) => signals.push(value) } } };
  class Observer {
    options: any; disconnected = false;
    constructor(public callback: () => void) { observers.push(this); }
    observe(_root: any, options: any) { this.options = options; }
    disconnect() { this.disconnected = true; }
  }
  const notifyAttribute = (name: string) => {
    for (const observer of observers) if (!observer.disconnected && observer.options?.attributeFilter.includes(name)) observer.callback();
  };
  const style = (node: Node) => ({ visibility: node.values.visibility || 'visible', display: node.closest('[hidden]') ? 'none' : 'block' });
  class FixtureInputEvent { constructor(public type: string, public init: any) {} }
  const read = (expectedURL = document.URL) => execute({ provider: 'deepseek', action: 'inspect', expectedURL,
    ownerToken, documentGeneration: generation, bindOwner: true },
    document, window, world, { origin: 'https://chat.deepseek.com' },
    style, Observer, TextArea, FixtureInputEvent);
  const setMode = (think: boolean, useSearch = false) => {
    for (const [node, selected] of [[deepThink, think], [search, useSearch]] as const) {
      node.values['aria-pressed'] = String(selected); node.values.class = 'ds-toggle-button' + (selected ? ' ds-toggle-button--selected' : '');
    }
  };
  const context = () => { const dom = read(); return dom.deletionContext(dom.transcript().first); };
  const record = () => { const driverContext = context(); return { driverContext, conversationURL: conversation, trigger,
    roots: [user, firstText, answer], menuAcknowledged: true, deleteAcknowledged: true, confirmAcknowledged: true, menu, dialog }; };
  const deleted = () => { userTurn.detach(); answerTurn.detach(); anchor.detach(); modal.detach(); menu.detach(); document.URL = 'https://chat.deepseek.com/'; };
  deepThink.onClick = () => setMode(deepThink.getAttribute('aria-pressed') !== 'true', search.getAttribute('aria-pressed') === 'true');
  search.onClick = () => setMode(deepThink.getAttribute('aria-pressed') === 'true', search.getAttribute('aria-pressed') !== 'true');
  editor.onFocus = () => { document.activeElement = editor; };
  editor.onDispatch = () => { send.values.class = 'ds-button ds-button--primary ds-button--circle' + (editor.value ? '' : ' ds-button--disabled'); };
  send.onClick = () => {
    firstText.text = editor.value; editor.value = ''; document.URL = conversation;
    body.append(userTurn, anchor);
    send.values.class = 'ds-button ds-button--primary ds-button--circle ds-button--disabled';
    if (options.completeOnSend !== false) body.append(answerTurn);
  };
  trigger.onClick = () => { body.append(menu); };
  remove.onClick = () => { menu.detach(); body.append(modal); };
  confirm.onClick = deleted;
  if (options.fresh) deleted();
  const adapter = new AsyncFunction('input', 'document', 'window', 'globalThis', 'location', 'getComputedStyle', 'MutationObserver', 'HTMLTextAreaElement', 'InputEvent', 'crypto',
    [core, engine, driver, entry].join('\n'));
  let beforeDigest: (() => void | Promise<void>) | undefined;
  const run = (action: string, overrides: Record<string, unknown> = {}) => adapter({ provider: 'deepseek', action, expectedURL: document.URL,
    ownerToken, documentGeneration: generation, bindOwner: true, expectedUserCounts: [0, 1], expectedFirstUserMarker: marker,
    allowFirstUserBinding: action === 'inspect', allowDeepSeekComposerHandoff: action === 'inspect', expectedFirstUserFingerprint: null, ...overrides },
    document, window, world, { origin: 'https://chat.deepseek.com' }, style, Observer, TextArea, FixtureInputEvent,
    { subtle: { digest: async (...args: Parameters<typeof crypto.subtle.digest>) => { await beforeDigest?.(); return crypto.subtle.digest(...args); } } });
  return { observers, signals, notifyAttribute, Node, body, document, world, window, read, run, scope, editor, deepThink, search, send, svg, path,
    userTurn, user, collapse, firstText, answerTurn, answer, reasoning, final, paragraph, literal, rail, actions,
    anchor, trigger, menu, remove, modal, dialog, title, notice, group, confirm, cancel, setMode, context, record, deleted,
    beforeDigest: (hook: () => void | Promise<void>) => { beforeDigest = hook; },
    complete: () => { if (!answerTurn.parentElement) body.append(answerTurn); },
    occlude: (node: Node) => { occluded = node; },
    mutations: () => body.descendants().reduce((sum, node) => sum + node.clicks + node.events.length, 0) };
}
