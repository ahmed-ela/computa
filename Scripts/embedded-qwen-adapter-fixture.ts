import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';
const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
const driver = readFileSync(new URL('./EmbeddedSavedProviders/qwen-dom.js', import.meta.url), 'utf8');
const engine = readFileSync(new URL('./EmbeddedSavedProviders/saved-conversation-engine.js', import.meta.url), 'utf8');
const entry = readFileSync(new URL('./EmbeddedSavedProviders/qwen-entry.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
export const ownerToken = '3336cfe2-11f6-4878-a803-af2efe05a797';
export const generation = '7d90b8a1-0b0f-4801-b995-0bba581a5d8c';
export const marker = 'bb3b2393-96ea-468d-aac4-f970670c8ef6';
export const prompt = 'Return a harmless synthetic response.\n\nComputa session marker: ' + marker;
export const choice = (label = 'Qwen3.7-Plus') => ({ key: label, label });
export const fingerprint = async (value: string) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value.replace(/\r\n?/g, '\n').normalize('NFC').trim())))].map(byte => byte.toString(16).padStart(2, '0')).join('');
export const conversationID = 'b3669d48-0898-45f8-a25c-e33d50b21dea';
export const userID = '902f136d-bddf-4078-a667-030715aeff87';
export const answerID = '413e8269-7ba8-476b-84f3-c400e8bed55c';
export const raw = '{"type":"message","text":"Synthetic Qwen reply"}';

// Observed DOM shapes only; all UUIDs, prompts and responses are synthetic.
export function fixture(options: { completeOnSend?: boolean } = {}) {
  const document: any = { URL: 'https://chat.qwen.ai/' }; let hit: any, occluded: any;
  class Node extends Element {
    computedStyle: Record<string,string> = {};
    _value = '';
    get value() { return this._value; }
    set value(value: string) { this._value = value; }
    setAttribute(name: string, value: string) { this.values[name] = value; }
    removeAttribute(name: string) { delete this.values[name]; }
    detach() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(node => node !== this); this.parentElement = null; this.connected = false; }
    append(...children: Element[]) { children.forEach(child => { child.connected = true; }); super.append(...children); }
    getBoundingClientRect() { hit = this; return { left: 10, top: 10, width: 100, height: 30 }; }
    querySelectorAll(selector: string) {
      if (!selector.includes(' > ')) return super.querySelectorAll(selector);
      const parts = selector.split(/\s+>\s+/);
      const selfMatches = (node: Element, part: string) => Element.prototype.querySelectorAll.call({ descendants: () => [node] }, part).length === 1;
      return this.descendants().filter(candidate => {
        let current: Element | null = candidate;
        for (let index = parts.length - 1; index >= 0; index--) {
          if (!current || !selfMatches(current, parts[index])) return false;
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
  Object.assign(document, { documentElement: html, body, querySelectorAll: (selector: string) => html.querySelectorAll(selector),
    elementFromPoint: () => hit === occluded ? body : hit });
  const window: any = { innerWidth: 1000, innerHeight: 800 }; window.top = window;
  const world: any = {};
  const trigger = new Node('DIV', { class: 'wms-trigger', role: 'button', 'aria-label': 'Select Model', 'aria-haspopup': 'listbox', 'aria-expanded': 'false' });
  const modelName = new Node('DIV', { class: 'wms-trigger__text' }, 'Qwen3.7-Plus'); trigger.append(modelName); body.append(trigger);
  const modelMenu = new Node('DIV', { class: 'wms-list', role: 'listbox', 'aria-label': 'Models', hidden: '' });
  const choices = ['Qwen3.7-Plus', 'Qwen3.8-Max', 'Qwen3.8-Omni-Flash'].map((name, index) => {
    const node = new Node('DIV', { class: 'wms-list__item' + (!index ? ' wms-list__item--selected' : ''), role: 'option', 'aria-selected': String(!index) });
    node.append(new Node('DIV', { class: 'wms-list__name-text' }, name)); modelMenu.append(node); return node;
  }); body.append(modelMenu);
  const scope = new Node('DIV', { class: 'message-input-container-area' });
  const editor = new TextArea('TEXTAREA', { class: 'message-input-textarea', placeholder: 'How can I help you today?' }); scope.append(editor); body.append(scope);
  const sendScope = new Node('DIV', { class: 'chat-prompt-send-button' }); scope.append(sendScope);
  const send = new Node('BUTTON', { class: 'send-button', 'aria-label': 'Send' });
  const stop = new Node('BUTTON', { class: 'stop-button', 'aria-label': 'Stop', 'data-chat-id': conversationID });
  const turn = new Node('DIV', { class: 'qwen-chat-message-select-turn' });
  const userTurn = new Node('DIV', { class: 'qwen-chat-message-select-turn-message' });
  const root = new Node('DIV', { class: 'qwen-chat-message qwen-chat-message-user' });
  const userContainer = new Node('DIV', { class: 'chat-user-message-container', 'data-msg-id': userID, 'data-chat-id': conversationID });
  const userChunk = new Node('DIV', { class: 'chunked-text-renderer-root' });
  const userBody = new Node('P', { class: 'user-message-content whitespace-pre-wrap' }, 'Exact synthetic prompt\nSecond line');
  userChunk.append(userBody); userContainer.append(userChunk); root.append(userContainer); userTurn.append(root);
  const answerTurn = new Node('DIV', { class: 'qwen-chat-message-select-turn-message' });
  const answerRoot = new Node('DIV', { class: 'qwen-chat-message qwen-chat-message-assistant' });
  const answer = new Node('DIV', { class: 'chat-response-message', id: 'chat-response-message-' + answerID });
  const right = new Node('DIV', { class: 'chat-response-message-right' });
  const flow = new Node('DIV', { class: 'chat-response-message-render-flow' });
  const thinking = new Node('DIV', { class: 'qwen-chat-thinking-tool-status-card-wraper' }, 'Thinking status chrome');
  const phase = new Node('DIV', { class: 'response-message-content t2t phase-answer' });
  const custom = new Node('DIV', { class: 'custom-qwen-markdown' }), markdown = new Node('DIV', { class: 'qwen-markdown qwen-markdown-loose' });
  const paragraph = new Node('DIV', { class: 'qwen-markdown-paragraph' }), text = new Node('SPAN', { class: 'qwen-markdown-text' });
  const literal = new Node('SPAN', { class: 'qwen-markdown-text-node' }, raw);
  text.append(literal); paragraph.append(text); markdown.append(paragraph); custom.append(markdown); phase.append(custom);
  const wrapper = new Node('DIV'); wrapper.append(phase); flow.append(thinking, wrapper); right.append(flow); answer.append(right); answerRoot.append(answer); answerTurn.append(answerRoot);
  turn.append(userTurn, answerTurn);
  const footer = new Node('DIV', { class: 'response-message-footer-actions' });
  const rail = new Node('DIV', { class: 'qwen-chat-package-comp-new-action-control', 'data-chat-id': conversationID, 'data-msg-id': answerID });
  const actions = ['Copy', 'Good Response', 'Bad Response', 'Share', 'Regenerate', 'More actions'].map(label => new Node('BUTTON', { 'aria-label': label }));
  rail.append(...actions); footer.append(rail);
  const header = new Node('DIV', { class: 'chat-menu-trigger' }), more = new Node('BUTTON', { 'aria-label': 'More' }); header.append(more);
  const menu = new Node('DIV', { class: 'qwen-chat-v2-dropdown-menu-popup', role: 'menu' });
  const remove = new Node('DIV', { class: 'qwen-chat-v2-dropdown-menu-item-danger chat-menu-item-error chat-menu-item', role: 'menuitem' });
  remove.append(new Node('SPAN', { class: 'qwen-chat-v2-dropdown-menu-item-label' }, 'Delete')); menu.append(remove);
  const dialog = new Node('DIV', { class: 'chat-item-delete-confirm', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'synthetic-title' });
  const title = new Node('DIV', { class: 'ant-modal-title', id: 'synthetic-title' }, 'Delete this chat?');
  const modalBody = new Node('DIV', { class: 'ant-modal-body' });
  const notice = new Node('DIV', { 'data-aes-exp': 'expChatDeleteMiddle', 'data-chat-id': conversationID }, 'Once deleted, this chat cannot be recovered, and the files in it will be permanently removed. If you have shared this conversation, the share link will no longer be accessible.');
  modalBody.append(notice); const buttons = new Node('DIV', { class: 'qwen-chat-v2-modal-footer-btns' });
  const cancel = new Node('BUTTON', { class: 'qwen-chat-v2-btn-plain' }, 'Cancel'), confirm = new Node('BUTTON', { class: 'qwen-chat-v2-btn-danger' }, 'Delete');
  buttons.append(cancel, confirm); dialog.append(title, modalBody, buttons);
  const execute = new Function('input', 'document', 'window', 'globalThis', 'location', 'getComputedStyle', 'MutationObserver', core + '\n' + engine + '\n' + driver
    + '\nreturn computaQwenDOM(computaProviderCore(input,"qwen","https://chat.qwen.ai",["inspect"]));');
  const style = (node: Node) => ({ visibility: node.values.visibility || 'visible', display: node.closest('[hidden]') ? 'none' : 'block', ...node.computedStyle });
  const observers: any[] = [], signals: any[] = [];
  window.webkit = { messageHandlers: { computaChatGPTSignal: { postMessage: (value: any) => signals.push(value) } } };
  class Observer {
    options: any; disconnected = false;
    constructor(public callback: () => void) { observers.push(this); }
    observe(_root: any, options: any) { this.options = options; }
    takeRecords() { return []; }
    disconnect() { this.disconnected = true; }
  }
  const notifyAttribute = (name: string) => {
    for (const observer of observers) if (!observer.disconnected && observer.options?.attributeFilter.includes(name)) observer.callback();
  };
  const read = () => execute({ provider: 'qwen', action: 'inspect', expectedURL: document.URL,
    ownerToken, documentGeneration: generation, bindOwner: true },
    document, window, world, { origin: 'https://chat.qwen.ai' },
    style, Observer);
  const mountConversation = (complete = true) => {
    document.URL = 'https://chat.qwen.ai/c/' + conversationID;
    if (!turn.parentElement) body.append(turn, header);
    if (complete && !footer.parentElement) answer.append(footer);
    if (!complete && !stop.parentElement) sendScope.append(stop);
  };
  const closePicker = () => { modelMenu.setAttribute('hidden', ''); trigger.setAttribute('aria-expanded', 'false'); };
  const openPicker = () => { modelMenu.removeAttribute('hidden'); trigger.setAttribute('aria-expanded', 'true'); };
  trigger.onClick = () => trigger.getAttribute('aria-expanded') === 'true' ? closePicker() : openPicker();
  choices.forEach(node => { node.onClick = () => {
    modelName.text = node.children[0].textContent;
    choices.forEach(other => { other.setAttribute('aria-selected', String(other === node)); other.setAttribute('class', 'wms-list__item' + (other === node ? ' wms-list__item--selected' : '')); });
    closePicker();
  }; });
  editor.onFocus = () => { document.activeElement = editor; };
  editor.onDispatch = () => { if (editor.value && !send.parentElement) sendScope.append(send); };
  send.onClick = () => { userBody.text = editor.value; editor.value = ''; send.detach(); mountConversation(options.completeOnSend !== false); };
  more.onClick = () => { body.append(menu); };
  remove.onClick = () => { menu.detach(); body.append(dialog); };
  confirm.onClick = () => { dialog.detach(); turn.detach(); header.detach(); stop.detach(); document.URL = 'https://chat.qwen.ai/'; };
  const adapter = new AsyncFunction('input', 'document', 'window', 'globalThis', 'location', 'getComputedStyle', 'MutationObserver', 'HTMLTextAreaElement', 'InputEvent', 'crypto',
    [core, engine, driver, entry].join('\n'));
  let beforeDigest: (() => void | Promise<void>) | undefined;
  const run = (action: string, overrides: Record<string, unknown> = {}) => adapter({ provider: 'qwen', action, expectedURL: document.URL,
    ownerToken, documentGeneration: generation, bindOwner: true, expectedUserCounts: [0, 1], expectedFirstUserMarker: marker,
    allowFirstUserBinding: action === 'inspect', expectedFirstUserFingerprint: null, ...overrides },
    document, window, world, { origin: 'https://chat.qwen.ai' }, style, Observer, TextArea,
    class { constructor(public type: string, public init: any) {} },
    { subtle: { digest: async (...args: Parameters<typeof crypto.subtle.digest>) => { await beforeDigest?.(); return crypto.subtle.digest(...args); } } });
  return { observers, signals, notifyAttribute, Node, body, document, read, run, world, window, trigger, modelName, modelMenu, choices, editor, scope, sendScope, send, stop,
    turn, root, userContainer, userBody, answerRoot, answer, right, flow, thinking, phase, markdown, paragraph, literal, rail, actions,
    header, more, menu, remove, dialog, title, notice, confirm, cancel,
    openPicker, mountConversation,
    complete: () => { stop.detach(); if (!footer.parentElement) answer.append(footer); },
    beforeDigest: (hook: () => void | Promise<void>) => { beforeDigest = hook; },
    occlude: (node: Node) => { occluded = node; },
    mutations: () => body.descendants().reduce((count, node) => count + node.clicks + node.events.length, 0) };
}
