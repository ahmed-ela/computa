import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { Element } from './embedded-provider-adapter-fixture';

// Shapes/labels observed in Kimi on 2026-11-02; every prompt, UUID and response
// here is synthetic. No captured account data or live requests are used.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
export const adapterSource = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/kimi.js', import.meta.url), 'utf8');
const observedChoices = [
  { key: 'k3d1-agent', label: 'K3.1 Pro', family: 'agent', checked: 'false' },
  { key: 'k28-agent-preview', label: 'K2.8 Preview', family: 'agent', checked: 'false' },
  { key: 'k28-instant', label: 'Instant', family: 'plain-chat', checked: 'true' },
];

function kimiFixture() {
  const document: any = { URL: 'https://www.kimi.ai/' };
  class Node extends Element {
    setAttribute(name: string, value: string) { this.values[name] = value; }
    removeAttribute(name: string) { delete this.values[name]; }
  }
  const html = new Node('HTML'), body = new Node('BODY'); html.append(body);
  Object.assign(document, { documentElement: html, body, querySelectorAll: (selector: string) => html.querySelectorAll(selector) });
  const trigger = new Node('DIV', { class: 'current-model', 'data-testid': 'model-select-trigger',
    id: 'fixture-generated-14', 'aria-controls': 'fixture-generated-menu', 'aria-haspopup': 'menu', 'aria-expanded': 'true' });
  const triggerName = new Node('SPAN', { class: 'name' }, observedChoices.find(row => row.checked === 'true')!.label);
  const triggerNameWrap = new Node('SPAN', { class: 'model-name' }); triggerNameWrap.append(triggerName); trigger.append(triggerNameWrap);
  const effort = new Node('SPAN', { class: 'current-effort' }, 'High'); trigger.append(effort);
  const menu = new Node('DIV', { class: 'kimi-menu-positioner', role: 'menu', id: 'fixture-generated-menu', 'aria-labelledby': 'fixture-generated-14' });
  const list = new Node('DIV', { class: 'model-list-options', 'data-testid': 'model-list-options' }); menu.append(list);
  const options = observedChoices.map(choice => {
    const option = new Node('BUTTON', { type: 'button', role: 'menuitemradio', 'data-testid': 'model-option',
      'data-moon-key': choice.key, 'data-model-family': choice.family, 'aria-checked': choice.checked });
    const wrapper = new Node('SPAN', { class: 'model-name' });
    wrapper.append(new Node('SPAN', { class: 'name' }, choice.label)); option.append(wrapper);
    option.append(new Node('SPAN', { class: 'desc' }, 'Synthetic description must not become the label'));
    list.append(option); return option;
  });
  const more = new Node('BUTTON', { 'data-testid': 'model-more-trigger', 'aria-label': 'More models', role: 'menuitem',
    id: 'fixture-more-trigger', 'aria-controls': 'fixture-more-menu',
    'data-close-on-select': 'false', 'aria-haspopup': 'menu', 'aria-expanded': 'false' }, 'More models'); menu.append(more);
  const moreCurrent = new Node('SPAN', { class: 'more-models-current' }); more.append(moreCurrent);
  const moreMenu = new Node('DIV', { class: 'kimi-menu-positioner', role: 'menu', id: 'fixture-more-menu',
    'aria-labelledby': 'fixture-more-trigger', hidden: '' });
  const moreOption = new Node('DIV', { 'data-testid': 'model-more-option', 'data-model-id': 'k3-agent',
    role: 'menuitemradio', 'aria-checked': 'false', 'data-close-on-select': 'inherit' });
  moreOption.append(new Node('SPAN', { class: 'kimi-menu-item__label' }, 'K3')); moreMenu.append(moreOption);
  const scope = new Node('DIV', { class: 'chat-editor-input-wrap' });
  const editor = new Node('DIV', { class: 'chat-input-editor', contenteditable: 'true', role: 'textbox', 'data-lexical-editor': 'true' });
  const empty = new Node('P'); empty.append(new Node('BR')); editor.append(empty); scope.append(editor);
  const draftText = () => editor.children.map(paragraph => paragraph.children.length === 1
    && paragraph.children[0].tagName === 'BR' ? '' : paragraph.textContent).join('\n');
  // The live Lexical span adds one rendered trailing LF. The separate synthetic
  // WK paragraph fixture adds visual block spacing. Neither changes raw text.
  Object.defineProperty(editor, 'innerText', { get: () => editor.children.length === 1
    && editor.children[0].children[0]?.getAttribute('data-lexical-text') === 'true'
      ? editor.children[0].textContent + '\n' : editor.children.length
        ? editor.children.map(paragraph => paragraph.children.length === 1 && paragraph.children[0].tagName === 'BR'
          ? '' : paragraph.textContent).join('\n\n') + '\n\n' : '' });
  body.append(trigger, menu, moreMenu, scope);
  const world: Record<string, any> = {}, location = { origin: 'https://www.kimi.ai' };
  const window: any = { innerWidth: 1000, innerHeight: 800 }; window.top = window;
  const installResponseMarkup = () => {
    const markdown = new Node('DIV', { class: 'markdown' });
    const segment = new Node('DIV', { class: 'segment-code' });
    const highlighter = new Node('DIV', { class: 'syntax-highlighter light segment-code-content' });
    const pre = new Node('PRE', { class: 'language-json' }), code = new Node('CODE', { class: 'language-json' });
    code.text = '{"type":"message","text":"Synthetic reply"}';
    pre.append(code); highlighter.append(pre); segment.append(highlighter); markdown.append(segment); body.append(markdown);
    return { markdown, segment, highlighter, pre, code };
  };
  const installHeader = () => {
    const header = new Node('HEADER', { class: 'chat-header-content desktop-no-drag', id: 'synthetic-header',
      'aria-controls': 'synthetic-header-menu', 'aria-haspopup': 'menu', 'aria-expanded': 'false' }, 'Synthetic title');
    body.append(header); return header;
  };
  const installTranscript = () => {
    const user = new Node('DIV', { class: 'chat-content-item chat-content-item-user',
      'data-archer-id': '461197c8-6e99-4560-bc41-b9fa5c9ca651',
      'data-conversation-turn-id': '461197c8-6e99-4560-bc41-b9fa5c9ca651' });
    const content = new Node('DIV', { class: 'user-content' });
    const userBody = new Node('SPAN', { class: 'user-content__text' }, 'Synthetic fixture prompt');
    content.append(userBody); user.append(content);
    const answer = new Node('DIV', { class: 'chat-content-item chat-content-item-assistant',
      'data-archer-id': 'c1e0ba7d-94b8-440e-9a04-283855c51453' });
    body.append(user, answer); return { user, content, userBody, answer };
  };
  const installConfirmation = () => {
    const mask = new Node('DIV', { class: 'modal-mask' });
    const dialog = new Node('DIV', { class: 'modal-container', 'data-testid': 'confirm-dialog' });
    const heading = new Node('DIV', { class: 'header' });
    const title = new Node('DIV', { class: 'title' }, 'Permanently delete chat'); heading.append(title);
    const message = new Node('DIV', { class: 'body' },
      'This chat data will be permanently deleted and cannot be recovered. Are you sure you want to delete?');
    const bottom = new Node('DIV', { class: 'bottom' });
    const cancel = new Node('BUTTON', { 'data-testid': 'confirm-dialog-cancel', class: 'km-button' }, 'Cancel');
    const confirm = new Node('BUTTON', { 'data-testid': 'confirm-dialog-confirm', class: 'km-button km-button-danger' }, 'Delete');
    bottom.append(cancel, confirm); dialog.append(heading, message, bottom); mask.append(dialog); body.append(mask);
    return { mask, dialog, title, message, bottom, cancel, confirm };
  };
  return { document, window, location, world, body, Node, trigger, triggerName, effort, menu, list, options, more,
    moreCurrent, moreMenu, moreOption, scope, editor,
    installResponseMarkup, installHeader, installTranscript, installConfirmation,
    draftText,
    setDraft: (text: string) => {
      editor.replaceChildren();
      for (const line of text.split('\n')) {
        const paragraph = new Node('P');
        if (line === '') paragraph.append(new Node('BR')); else paragraph.text = line;
        editor.append(paragraph);
      }
    },
    setLexicalDraft: (text: string) => {
      const paragraph = new Node('P', { dir: 'ltr' });
      paragraph.append(new Node('SPAN', { 'data-lexical-text': 'true' }, text));
      editor.replaceChildren(paragraph);
    },
    mutationCount: () => body.descendants().reduce((sum, node) => sum + node.clicks + node.events.length, 0),
  };
}

export const marker = 'b1b67ccb-b8a4-41ea-ab24-2b6f47a9bd26';
export const generation = '20c5f3a8-c773-420c-ae5a-aed28de0c0be';
export const instant = { key: 'k28-instant', label: 'Instant' };
export const canonical = 'https://www.kimi.ai/chat/65258a69-5b44-4d8d-ad88-1704589feee2';
export const provisional = 'https://www.kimi.ai/chat/p5258a69-5b44-4d8d-ad88-1704589feee2?chat_enter_method=home';
export const prompt = 'Exact synthetic café\nA second line, "quoted" and \\ literal\n\nComputa session marker: ' + marker;
export const submissionFingerprint = createHash('sha256').update(prompt.replace(/\r\n?/g, '\n').normalize('NFC').trim()).digest('hex');

export function adapterFixture(options: { delayedUser?: boolean; provisional?: boolean; streaming?: boolean;
  insertionFails?: boolean; insertionThrows?: boolean; delayedInsertion?: boolean; paragraphInsertion?: boolean;
  submitThrows?: boolean; confirmationThrows?: boolean; retainHistoryLink?: boolean; outbound?: string; nestedSelected?: boolean } = {}) {
  const f = kimiFixture(), { Node, document, body, window } = f;
  const fixturePrompt = options.outbound ?? prompt;
  const fixtureFingerprint = createHash('sha256').update(fixturePrompt.replace(/\r\n?/g, '\n').normalize('NFC').trim()).digest('hex');
  const observers: { callback: () => void; attributes: string[]; active: boolean }[] = [], signals: unknown[] = [];
  window.webkit = { messageHandlers: { computaChatGPTSignal: { postMessage: (value: unknown) => signals.push(value) } } };
  let hit: any, occluded: any = null, digestHook: (() => void) | undefined;
  Node.prototype.getBoundingClientRect = function () { hit = this; return { left: 10, top: 10, width: 100, height: 30 }; };
  document.elementFromPoint = () => hit === occluded ? body : hit;
  const remove = (node: any) => {
    if (node.parentElement) node.parentElement.children = node.parentElement.children.filter((child: any) => child !== node);
    node.connected = false; node.parentElement = null;
  };
  const move = (node: any, parent: any) => { remove(node); node.connected = true; parent.append(node); };
  const hideMore = () => { f.moreMenu.setAttribute('hidden', ''); f.more.setAttribute('aria-expanded', 'false'); };
  const hide = () => { f.menu.setAttribute('hidden', ''); f.trigger.setAttribute('aria-expanded', 'false'); hideMore(); };
  const show = () => { f.menu.removeAttribute('hidden'); f.trigger.setAttribute('aria-expanded', 'true'); };
  hide();
  f.trigger.onClick = () => f.trigger.getAttribute('aria-expanded') === 'true' ? hide() : show();
  f.more.onClick = () => {
    if (f.more.getAttribute('aria-expanded') === 'true') hideMore();
    else { f.moreMenu.removeAttribute('hidden'); f.more.setAttribute('aria-expanded', 'true'); }
  };
  for (const row of f.options) row.onClick = () => {
    f.options.forEach(other => other.setAttribute('aria-checked', other === row ? 'true' : 'false'));
    f.moreOption.setAttribute('aria-checked', 'false'); f.moreCurrent.text = '';
    f.triggerName.text = row.querySelector('.name')!.textContent; hide();
  };
  if (options.nestedSelected) {
    f.options.forEach(row => row.setAttribute('aria-checked', 'false'));
    f.moreOption.setAttribute('aria-checked', 'true'); f.moreCurrent.text = 'K3'; f.triggerName.text = 'K3';
  }
  const send = new Node('DIV', { class: 'send-button-container disabled' });
  const sendIcon = new Node('SVG', { class: 'iconify send-icon', name: 'Send', role: 'img' });
  send.append(sendIcon); body.append(send);
  f.editor.onFocus = () => { document.activeElement = f.editor; };
  window.getSelection = () => ({ removeAllRanges() {}, addRange() {} });
  document.createRange = () => ({ selectNodeContents(node: any) { if (node !== f.editor) throw new Error('Unexpected selection'); } });
  let insertions = 0, sends = 0, confirms = 0, submittedText: string | null = null, insertionText: string | null = null;
  const settleInsertion = (text = fixturePrompt) => {
    if (!insertions) throw new Error('No synthetic insertion has been dispatched');
    if (options.paragraphInsertion) f.setDraft(text); else f.setLexicalDraft(text);
    send.setAttribute('class', 'send-button-container');
  };
  document.execCommand = (command: string, _: boolean, text: string) => {
    if (command !== 'insertText' || document.activeElement !== f.editor) throw new Error('Unexpected insertion');
    insertionText = text;
    insertions++; if (options.insertionThrows) throw new Error('Unknown insertion acknowledgement');
    if (options.insertionFails) return false;
    if (!options.delayedInsertion) settleInsertion(text);
    return true;
  };
  let messages: ReturnType<typeof f.installTranscript> | undefined;
  let response: ReturnType<typeof f.installResponseMarkup> | undefined;
  let box: any, rollup: any, part: any, thoughtPart: any, rail: any, header: any, deletionMenu: any, deleteRow: any;
  let confirmation: ReturnType<typeof f.installConfirmation> | undefined, historyLink: any;
  const finishResponse = () => {
    if (!messages || rail) return;
    const outer = new Node('DIV', { class: 'segment-assistant-actions' });
    rail = new Node('DIV', { class: 'segment-assistant-actions-content' });
    for (let i = 0; i < 5; i++) rail.append(new Node('DIV', { class: 'icon-button' }));
    outer.append(rail); messages.answer.append(outer);
  };
  const appendUser = () => {
    if (messages) throw new Error('Only one fixture dispatch is allowed');
    if (submittedText === null) throw new Error('Fixture has no submitted text');
    messages = f.installTranscript(); messages.userBody.text = submittedText;
    response = f.installResponseMarkup(); response.code.replaceChildren(); response.code.text = '{"type":"message","text":"Synthetic reply"}';
    box = new Node('DIV', { class: 'segment-content-box' }); rollup = new Node('DIV', { class: 'toolcall-rollup' });
    thoughtPart = new Node('DIV', { class: 'toolcall-rollup__part toolcall-rollup__flat' });
    thoughtPart.append(new Node('DIV', { class: 'toolcall-flow' }, 'Thinking complete Used 0 tools'));
    part = new Node('DIV', { class: 'toolcall-rollup__part toolcall-rollup__flat' });
    const wrapper = new Node('DIV', { class: 'markdown-container' }); move(response.markdown, wrapper); part.append(wrapper);
    rollup.append(thoughtPart, part); box.append(rollup); messages.answer.append(box);
    const codeHeader = new Node('HEADER', { class: 'segment-code-header' });
    codeHeader.append(new Node('SPAN', { class: 'segment-code-lang' }, 'JSON'),
      new Node('DIV', { role: 'tooltip', 'data-testid': 'icon-button-tooltip' }, ' Copy'));
    // Captured tooltip text is exactly Copy; space belongs between nodes.
    codeHeader.children[1].text = 'Copy'; codeHeader.text = ' ';
    response.segment.append(codeHeader);
    // DOM textContent concatenates adjacent inline labels. The live code header
    // includes a separating whitespace node, retained in this inert fixture.
    codeHeader.children[0].text = 'JSON';
    codeHeader.children.splice(1, 0, new Node('#text', {}, ' ')); codeHeader.children[1].parentElement = codeHeader;
    if (!options.streaming) finishResponse();
    header = f.installHeader();
    header.onClick = () => {
      header.setAttribute('aria-expanded', 'true');
      deletionMenu = new Node('DIV', { class: 'kimi-menu-positioner', role: 'menu', id: 'synthetic-header-menu',
        'aria-labelledby': 'synthetic-header' });
      deleteRow = new Node('DIV', { class: 'kimi-menu-item is-danger', role: 'menuitem', 'data-kimi-menu-item': '', 'data-close-on-select': 'inherit' });
      deleteRow.append(new Node('SPAN', { class: 'kimi-menu-item__label' }, 'Delete'));
      deletionMenu.append(deleteRow); body.append(deletionMenu);
      deleteRow.onClick = () => {
        remove(deletionMenu); header.setAttribute('aria-expanded', 'false');
        confirmation = f.installConfirmation();
        confirmation.confirm.onClick = () => {
          confirms++; if (options.confirmationThrows) throw new Error('Unknown confirmation acknowledgement');
          remove(messages!.user); remove(messages!.answer); remove(header); remove(confirmation!.mask);
          if (!options.retainHistoryLink) remove(historyLink);
          document.URL = 'https://www.kimi.ai/'; f.setDraft('');
        };
      };
    };
    historyLink = new Node('A', { href: canonical }, 'Synthetic title'); body.append(historyLink);
  };
  send.onClick = () => {
    sends++; if (options.submitThrows) throw new Error('Unknown submission acknowledgement');
    submittedText = f.draftText();
    f.setDraft(''); send.setAttribute('class', 'send-button-container disabled');
    document.URL = options.provisional ? provisional : canonical;
    if (!options.delayedUser) appendUser();
  };
  const execute = new AsyncFunction('input', 'document', 'window', 'location', 'globalThis', 'getComputedStyle', 'MutationObserver', 'crypto',
    adapterSource);
  let fingerprint: string | undefined, conversation: string | undefined;
  const run = async (action = 'inspect', overrides: Record<string, unknown> = {}) => {
    const result = await execute({ provider: 'kimi', action, expectedURL: document.URL,
      ownerToken: '9fe25e48-2e0b-46cb-84f7-7b4f32e1794f', documentGeneration: generation, bindOwner: true,
      expectedUserCounts: [0, 1], expectedFirstUserMarker: marker, expectedFirstUserFingerprint: fingerprint,
      expectedConversation: conversation, allowFirstUserBinding: action === 'inspect' && !fingerprint,
      expectedModelChoice: instant, ...(action === 'selectModel' ? { modelChoice: instant } : {}), prompt: fixturePrompt, ...overrides,
      ...(['insert', 'submit'].includes(action) && !Object.hasOwn(overrides, 'savedSubmissionFingerprint') ? { savedSubmissionFingerprint: fixtureFingerprint } : {}),
    }, document, window, f.location, f.world,
    (node: any) => ({ visibility: node.values.visibility || 'visible', display: node.closest('[hidden]') ? 'none' : 'block' }),
    class {
      private record: typeof observers[number];
      constructor(callback: () => void) { this.record = { callback, attributes: [], active: false }; observers.push(this.record); }
      observe(_: unknown, options: { attributeFilter: string[] }) { this.record.attributes = options.attributeFilter; this.record.active = true; }
      disconnect() { this.record.active = false; }
    },
    { subtle: { digest: async (algorithm: string, bytes: Uint8Array) => {
      const value = await crypto.subtle.digest(algorithm, bytes); const hook = digestHook; digestHook = undefined; hook?.(); return value;
    } } });
    if (result.firstUserVerified) { fingerprint = result.firstUserFingerprint; conversation = result.conversationIdentity; }
    return result;
  };
  const select = async (choice = instant) => {
    for (let i = 0; i < 8; i++) {
      const result = await run('selectModel', { modelChoice: choice, expectedModelChoice: choice });
      if (result.error || result.selected) return result;
    }
    throw new Error('Model fixture did not settle');
  };
  const submit = async () => {
    const selection = await select(); if (selection.error) return selection;
    for (const action of ['prepare', 'insert', 'sendReady', 'submit']) {
      const result = await run(action); if (result.error) return result;
    }
    return run('inspect');
  };
  const operation = () => ({ id: '547dbbf5-8955-4b65-9b18-5a6e16c3cd7d', documentGeneration: generation,
    sequence: 1, firstUserFingerprint: fingerprint, conversationURL: canonical });
  return { ...f, run, select, submit, operation, send, sendIcon, remove, appendUser, finishResponse, settleInsertion,
    observers, signals,
    emitAttribute: (name: string) => { for (const observer of observers) if (observer.active && observer.attributes.includes(name)) observer.callback(); },
    onDigest: (hook: () => void) => { digestHook = hook; }, occlude: (node: any) => { occluded = node; },
    counts: () => ({ insertions, sends, confirms }),
    get messages() { return messages!; }, get response() { return response!; }, get box() { return box; },
    get insertionText() { return insertionText; },
    get part() { return part; }, get thoughtPart() { return thoughtPart; }, get rail() { return rail; },
    get header() { return header; }, get deleteRow() { return deleteRow; }, get deletionMenu() { return deletionMenu; },
    get confirmation() { return confirmation!; }, get fingerprint() { return fingerprint; } };
}
