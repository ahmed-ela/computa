import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

const source = readFileSync(process.env.COMPUTA_BROWSER_CONTROL_SOURCE
  || new URL('../Sources/Computa/Resources/BrowserModels/browser-control.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function fixture(target: string | null) {
  const documentPosition = (left: any, right: any) => {
    const path = (node: any) => {
      const result: number[] = [];
      for (let current = node; current?.parentElement; current = current.parentElement)
        result.unshift(current.nodeType === 3 ? -1 : current.parentElement.children.indexOf(current));
      return result;
    };
    if (left === right) return 0;
    const a = path(left), b = path(right);
    for (let index = 0; index < Math.min(a.length, b.length); index++)
      if (a[index] !== b[index]) return a[index] < b[index] ? 4 : 2;
    return a.length < b.length ? 20 : 10;
  };
  class Node extends Element {
    focusOptions: unknown[] = [];
    valueWrites: string[] = [];
    get href() { return this.values.href || ''; }
    get target() { return this.values.target || ''; }
    get type() { return this.values.type || (this.tagName === 'INPUT' ? 'text' : ''); }
    get readOnly() { return this.values.readonly !== undefined; }
    get isContentEditable() { return this.values.contenteditable === 'true'; }
    get value() { return this.values.value || ''; }
    set value(value: string) { this.valueWrites.push(value); this.values.value = value; }
    get textContent() { return super.textContent; }
    set textContent(value: string) { this.replaceChildren(); this.text = value; }
    hasAttribute(name: string) { return this.values[name] !== undefined; }
    matches(selector: string) { return this.closest(selector) === this; }
    compareDocumentPosition(other: any) { return documentPosition(this, other); }
    get childNodes(): any[] {
      return super.childNodes.map(node => node.nodeType === 3
        ? { ...node, compareDocumentPosition(other: any) { return documentPosition(this, other); } } : node);
    }
    scrollIntoView() {}
    getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 20 }; }
    focus(options?: unknown) { this.focusOptions.push(options); document.activeElement = this; this.onFocus?.(); }
  }
  const body = new Node('BODY'), link = new Node('A', {
    href: 'https://example.test/sign-in?return=%2Fmail%2F&literal=A-B', target: target || '',
  }, 'Sign in');
  if (target !== null) body.append(link);
  const listeners = new Map<string, Set<Function>>(), timers = new Map<number, { callback: Function; delay: number }>();
  let timerID = 0;
  const observers: Observer[] = [];
  class Observer {
    active = false;
    target: unknown;
    constructor(readonly callback: Function) { observers.push(this); }
    observe(target: unknown) { this.target = target; this.active = true; }
    disconnect() { this.active = false; }
  }
  const document = { body, documentElement: body, title: 'Outlook', readyState: 'complete', visibilityState: 'visible', activeElement: null as Element | null, elementFromPoint: () => link,
    getElementById: (id: string) => document.body.descendants().find(node => node.values.id === id) || null,
    addEventListener(name: string, callback: Function) {
      if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name)!.add(callback);
    }, removeEventListener(name: string, callback: Function) { listeners.get(name)?.delete(callback); } };
  const state = {}, location = { href: 'https://example.test/' };
  const execute = new AsyncFunction('input', 'globalThis', 'document', 'location', 'Node', 'getComputedStyle', 'TextEncoder',
    'MutationObserver', 'setTimeout', 'clearTimeout', 'HTMLInputElement', 'HTMLTextAreaElement', 'HTMLSelectElement', 'Event', 'Element', 'innerWidth', 'innerHeight', source);
  const run = (input: Record<string, unknown>) => execute({ documentToken: 'owned-document', timeoutMS: 10000, awaitSemanticReadiness: true, ...input }, state, document, location,
    { TEXT_NODE: 3, ELEMENT_NODE: 1, DOCUMENT_POSITION_PRECEDING: 2, DOCUMENT_POSITION_FOLLOWING: 4 }, () => ({ display: 'block', visibility: 'visible' }), TextEncoder, Observer,
    (callback: Function, delay: number) => { timers.set(++timerID, { callback, delay }); return timerID; },
    (id: number) => timers.delete(id), Node, Node, Node, Event, Node, 1024, 768);
  const press = (row: any) => run({ operation: 'press', nodeID: row.backendNodeID,
    expected: row, expectedURL: location.href });
  const fill = (row: any, text: string) => run({ operation: 'fill', nodeID: row.backendNodeID,
    expected: row, expectedURL: location.href, text });
  return { Node, link, run, press, fill, document, location, timers, observers, listeners, state,
    appendText: (text: string) => document.body.append(new Node('P', {}, text)),
    appendControl: () => document.body.append(new Node('BUTTON', {}, 'Continue')),
    appendMetadata: () => document.body.append(new Node('MAIN', { 'aria-label': 'Outlook' })),
    mutate: () => observers.filter(observer => observer.active).forEach(observer => observer.callback()),
    event: (name: string) => listeners.get(name)?.forEach(callback => callback()),
    expire: () => [...timers.values()].forEach(timer => timer.callback()),
    replaceRoot: () => { document.body = new Node('BODY'); document.documentElement = document.body; },
  };
}

describe('explicit ARIA selection item press capabilities', () => {
  test('each supported explicit item dispatches only its exact click and exposes the resulting selection', async () => {
    for (const role of ['option', 'treeitem', 'menuitemcheckbox', 'menuitemradio']) {
      const f = fixture(null), item = new f.Node('DIV', { role }, 'Synthetic item');
      const other = new f.Node('DIV', { role }, 'Other item');
      const result = new f.Node('P', {}, 'Not selected');
      item.onClick = () => {
        item.values[role.startsWith('menuitem') ? 'aria-checked' : 'aria-selected'] = 'true';
        result.text = 'Synthetic item selected';
      };
      f.document.body.append(item, other, result); f.document.elementFromPoint = () => item;
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === role && node.name === 'Synthetic item');
      expect(row.isDOMClickable).toBe(true); expect(row.isPressUnsupported).toBe(false); expect(row.isDisabled).toBe(false);
      expect(await f.press(row)).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
      expect(item.clicks).toBe(1); expect(other.clicks).toBe(0);
      expect(item.values[role.startsWith('menuitem') ? 'aria-checked' : 'aria-selected']).toBe('true');
      expect((await f.run({ operation: 'observe' })).nodes.some((node: any) => node.name === 'Synthetic item selected')).toBe(true);
    }
  });

  test('disabled items and stale selection-item identity, role, parent, route or obstruction never click', async () => {
    for (const drift of ['disabled', 'becomes-disabled', 'replaced', 'role', 'parent', 'route', 'obstructed']) {
      const f = fixture(null), item = new f.Node('DIV', { role: 'option', ...(drift === 'disabled' ? { 'aria-disabled': 'true' } : {}) }, 'Synthetic item');
      f.document.body.append(item); f.document.elementFromPoint = () => item;
      const capturedURL = f.location.href;
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'option');
      expect(row.isDisabled).toBe(drift === 'disabled');
      if (drift === 'becomes-disabled') item.values['aria-disabled'] = 'true';
      if (drift === 'replaced') f.document.body.replaceChildren(new f.Node('DIV', { role: 'option' }, 'Synthetic item'));
      if (drift === 'role') item.values.role = 'row';
      if (drift === 'parent') {
        const group = new f.Node('DIV', { role: 'group' });
        f.document.body.children = []; f.document.body.append(group); group.append(item);
      }
      if (drift === 'route') f.location.href = 'https://example.test/changed';
      if (drift === 'obstructed') f.document.elementFromPoint = () => f.link;
      await expect(f.run({ operation: 'press', nodeID: row.backendNodeID, expected: row, expectedURL: capturedURL })).rejects.toThrow(
        ['disabled', 'route'].includes(drift) ? 'stale_document' : drift === 'obstructed' ? 'element_obstructed' : 'element_changed');
      expect(item.clicks).toBe(0);
    }
  });

  test('text and layout containers do not inherit the press capability of an interactive child', async () => {
    for (const role of ['row', 'gridcell', 'listitem', 'statictext', 'group', 'listbox', 'tree', 'menu']) {
      const f = fixture(null), container = new f.Node('DIV', { role }, 'Container');
      const child = new f.Node('DIV', { role: 'option' }, 'Synthetic item');
      container.append(child); f.document.body.append(container); f.document.elementFromPoint = () => container;
      const snapshot = await f.run({ operation: 'observe' });
      const row = snapshot.nodes.find((node: any) => node.role === role);
      expect(row.isDOMClickable).toBe(false); expect(row.isPressUnsupported).toBe(false);
      expect(snapshot.nodes.find((node: any) => node.role === 'option').isDOMClickable).toBe(true);
      await expect(f.press(row)).rejects.toThrow('unsupported_action');
      expect(container.clicks).toBe(0); expect(child.clicks).toBe(0);
    }
  });

  test('native OPTION and explicit items without a DOM click implementation remain unsupported', async () => {
    for (const nativeOption of [false, true]) {
      const f = fixture(null), item = new f.Node(nativeOption ? 'OPTION' : 'DIV', { role: 'option' }, 'Synthetic item');
      if (!nativeOption) Object.defineProperty(item, 'click', { value: undefined });
      f.document.body.append(item); f.document.elementFromPoint = () => item;
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'option');
      expect(row.isDOMClickable).toBe(false);
      await expect(f.press(row)).rejects.toThrow('unsupported_action');
      expect(item.clicks).toBe(0);
    }
  });

  test('a popup-only anchor cannot use an explicit selection role to regain press', async () => {
    const f = fixture(null), item = new f.Node('A', { role: 'option', target: '_blank', href: 'https://example.test/observed' }, 'Synthetic item');
    f.document.body.append(item); f.document.elementFromPoint = () => item;
    const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'option');
    expect(row.isDOMClickable).toBe(false); expect(row.isPressUnsupported).toBe(true);
    await expect(f.press(row)).rejects.toThrow('unsupported_action'); expect(item.clicks).toBe(0);
  });
});

describe('exact-field page-local fill focus', () => {
  test('focus reveals a search action before the exact value and input/change events are delivered', async () => {
    const f = fixture(null), field = new f.Node('INPUT', { type: 'search', 'aria-label': 'Search' });
    f.document.body.append(field); f.document.elementFromPoint = () => field;
    field.onFocus = () => f.document.body.append(new f.Node('BUTTON', {}, 'Search'));
    const deliveries: string[] = [];
    field.onDispatch = event => {
      expect(f.document.activeElement).toBe(field);
      expect(f.document.body.children.some(node => node.tagName === 'BUTTON')).toBe(true);
      deliveries.push(event.type);
    };
    const before = await f.run({ operation: 'observe' });
    expect(before.nodes.some((node: any) => node.role === 'button')).toBe(false);
    const row = before.nodes.find((node: any) => node.role === 'searchbox');
    const text = 'Exact search & punctuation.';
    expect(await f.fill(row, text)).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
    expect(field.focusOptions).toEqual([{ preventScroll: true }]);
    expect(field.valueWrites).toEqual([text]); expect(field.value).toBe(text);
    expect(deliveries).toEqual(['input', 'change']); expect(field.clicks).toBe(0);
    const after = await f.run({ operation: 'observe' });
    expect(after.nodes.find((node: any) => node.role === 'button').name).toBe('Search');
  });

  test('a focus handler replacing the field cannot inherit its fill authority', async () => {
    const f = fixture(null), field = new f.Node('INPUT', { 'aria-label': 'Search' });
    const replacement = new f.Node('INPUT', { 'aria-label': 'Search' });
    f.document.body.append(field); f.document.elementFromPoint = () => field;
    const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'textbox');
    field.onFocus = () => { f.document.body.replaceChildren(replacement); f.document.activeElement = replacement; };
    await expect(f.fill(row, 'Exact search')).rejects.toThrow('element_changed');
    expect(field.focusOptions).toEqual([{ preventScroll: true }]);
    expect(field.valueWrites).toEqual([]); expect(replacement.valueWrites).toEqual([]);
    expect(field.events).toEqual([]); expect(replacement.events).toEqual([]);
  });

  test('focus-time route, editability, parent, obstruction or focus drift rejects before writing', async () => {
    for (const drift of ['route', 'readonly', 'disabled', 'parent', 'obstructed', 'focus']) {
      const f = fixture(null), field = new f.Node('INPUT', { 'aria-label': 'Search' });
      f.document.body.append(field); f.document.elementFromPoint = () => field;
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'textbox');
      field.onFocus = () => {
        if (drift === 'route') f.location.href = 'https://example.test/changed';
        if (drift === 'readonly') field.values.readonly = '';
        if (drift === 'disabled') field.disabled = true;
        if (drift === 'parent') {
          const group = new f.Node('DIV', { role: 'group' });
          f.document.body.children = []; f.document.body.append(group); group.append(field);
        }
        if (drift === 'obstructed') f.document.elementFromPoint = () => f.link;
        if (drift === 'focus') f.document.activeElement = f.link;
      };
      await expect(f.fill(row, 'Exact search')).rejects.toThrow(
        drift === 'route' ? 'stale_document' : drift === 'obstructed' ? 'element_obstructed' : 'element_changed');
      expect(field.valueWrites).toEqual([]); expect(field.events).toEqual([]);
    }
  });

  test('stale or obstructed preflight never focuses the field', async () => {
    for (const drift of ['metadata', 'obstructed']) {
      const f = fixture(null), field = new f.Node('INPUT', { 'aria-label': 'Search' });
      f.document.body.append(field); f.document.elementFromPoint = () => field;
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'textbox');
      if (drift === 'metadata') field.values['aria-label'] = 'Changed field';
      else f.document.elementFromPoint = () => f.link;
      await expect(f.fill(row, 'Exact search')).rejects.toThrow(
        drift === 'metadata' ? 'element_changed' : 'element_obstructed');
      expect(field.focusOptions).toEqual([]); expect(field.valueWrites).toEqual([]); expect(field.events).toEqual([]);
    }
  });

  test('contenteditable fill focuses the same node and preserves exact text', async () => {
    const f = fixture(null), field = new f.Node('DIV', { contenteditable: 'true', 'aria-label': 'Editor' });
    f.document.body.append(field); f.document.elementFromPoint = () => field;
    const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'textbox');
    const text = 'Exact line one\nLine two & punctuation.';
    expect(await f.fill(row, text)).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
    expect(f.document.activeElement).toBe(field); expect(field.textContent).toBe(text);
    expect(field.valueWrites).toEqual([]); expect(field.events.map((event: any) => event.type)).toEqual(['input', 'change']);
  });
});

describe('built-in browser popup-only link capabilities', () => {
  test('ordinary same-tab anchors retain their observed press capability', async () => {
    for (const target of ['', '_self', '_top', '_parent', '_SELF']) {
      const f = fixture(target), read = await f.run({ operation: 'observe' });
      const link = read.nodes.find((row: any) => row.role === 'link');
      expect(link.isDOMClickable).toBe(true); expect(link.isPressUnsupported).toBe(false);
      expect(link.isDisabled).toBe(false);
      expect(await f.press(link)).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
      expect(f.link.clicks).toBe(1);
    }
  });

  test('popup-only anchors keep the exact destination and enabled read-only semantics, and cannot dispatch', async () => {
    for (const target of ['_blank', '_BLANK', 'outlook-signin']) {
      const f = fixture(target), read = await f.run({ operation: 'observe' });
      const link = read.nodes.find((row: any) => row.role === 'link');
      expect(link.linkURL).toBe(f.link.href); expect(link.name).toBe('Sign in');
      expect(link.isDisabled).toBe(false); expect(link.isDOMClickable).toBe(false);
      expect(link.isPressUnsupported).toBe(true);
      await expect(f.press(link)).rejects.toThrow('unsupported_action');
      expect(f.link.clicks).toBe(0);
    }
  });

  test('a target changed after observation cannot inherit the original press capability', async () => {
    const f = fixture('_self'), read = await f.run({ operation: 'observe' });
    const link = read.nodes.find((row: any) => row.role === 'link');
    f.link.values.target = '_blank';
    await expect(f.press(link)).rejects.toThrow('element_changed');
    expect(f.link.clicks).toBe(0);
  });
});

describe('structural application labels', () => {
  test('a large application preserves its readable descendants without duplicating the entire page in its label', async () => {
    const f = fixture(null), application = new f.Node('DIV', { role: 'application' });
    const parts = Array.from({ length: 8 }, (_, index) => `Record ${index}: ` + 'x'.repeat(900));
    for (const text of parts) application.append(new f.Node('P', {}, text));
    application.append(new f.Node('BUTTON', {}, 'Open record'));
    f.document.body.append(application);
    expect(application.innerText.length).toBeGreaterThan(4096);
    const result = await f.run({ operation: 'observe' });
    const root = result.nodes.find((node: any) => node.role === 'application');
    expect(root.name).toBe(''); expect(root.childNodeIDs).toHaveLength(9);
    expect(root.isDOMClickable).toBe(false);
    expect(result.nodes.filter((node: any) => node.role === 'statictext').map((node: any) => node.name)).toEqual(parts);
    expect(result.nodes.find((node: any) => node.role === 'button').name).toBe('Open record');
    expect(result.sourceTruncated).toBe(false);
    expect(result.nodes.filter((node: any) => node.name.includes('Record 3:')).map((node: any) => node.role)).toEqual(['statictext']);
  });

  test('explicit application accessible names and child traversal remain intact', async () => {
    for (const labelledBy of [false, true]) {
      const f = fixture(null), label = new f.Node('SPAN', { id: 'workspace-name' }, 'Named workspace');
      const application = new f.Node('DIV', labelledBy
        ? { role: 'application', 'aria-labelledby': 'workspace-name' }
        : { role: 'application', 'aria-label': 'Named workspace' });
      application.append(new f.Node('P', {}, 'Exact child content'), new f.Node('BUTTON', {}, 'Open record'));
      f.document.body.append(label, application);
      const result = await f.run({ operation: 'observe' });
      const root = result.nodes.find((node: any) => node.role === 'application');
      expect(root.name).toBe('Named workspace'); expect(root.isDOMClickable).toBe(false);
      expect(root.childNodeIDs).toHaveLength(2);
      expect(result.nodes.some((node: any) => node.role === 'statictext' && node.name === 'Exact child content')).toBe(true);
      expect(result.nodes.find((node: any) => node.role === 'button').name).toBe('Open record');
    }
  });
});

describe('bounded capture of late forms and dialogs', () => {
  function crowded(kind: 'dialog' | 'native-dialog' | 'form' | 'focus-only', focused = false) {
    const f = fixture(null), inbox = new f.Node('DIV', { role: 'grid' });
    for (let index = 0; index < 300; index++) {
      const row = new f.Node('DIV', { role: 'row' }), cell = new f.Node('DIV', { role: 'gridcell' });
      cell.append(new f.Node('P', {}, `Synthetic inbox item ${index}: ${'x'.repeat(1000)}`));
      row.append(cell); inbox.append(row);
    }
    const scope = new f.Node(kind === 'native-dialog' ? 'DIALOG' : kind === 'form' ? 'FORM' : 'DIV',
      { ...(kind === 'dialog' ? { role: 'dialog' } : {}), ...(kind === 'native-dialog' ? { open: '' } : {}),
        'aria-label': 'New message' });
    const to = new f.Node('INPUT', { type: 'email', 'aria-label': 'Recipients' });
    const subject = new f.Node('INPUT', { 'aria-label': 'Subject' });
    const body = new f.Node('DIV', { contenteditable: 'true', 'aria-label': 'Message body' });
    const send = new f.Node('BUTTON', {}, 'Send');
    scope.append(to, subject, body, send); f.document.body.append(inbox, scope);
    if (focused) f.document.activeElement = to;
    f.document.elementFromPoint = () => to;
    return { ...f, inbox, scope, to, subject, body, send };
  }

  function minimized(deep = false, dialog = false) {
    const f = crowded('focus-only');
    if (dialog) f.scope.values.role = 'dialog';
    const heading = new f.Node('H2', {}, 'New message');
    const maximize = new f.Node('BUTTON', {}, 'Maximize');
    const fullscreen = new f.Node('BUTTON', {}, 'Full screen');
    const close = new f.Node('BUTTON', {}, 'Close');
    f.scope.replaceChildren(heading, maximize, fullscreen, close);
    fullscreen.onClick = () => {
      for (const node of [f.to, f.subject, f.body, f.send]) node.connected = true;
      f.scope.append(f.to, f.subject, f.body, f.send);
    };
    if (deep) {
      for (let index = 0; index < 5_000; index++) f.inbox.append(new f.Node('DIV'));
      const application = new f.Node('DIV', { role: 'application' });
      f.document.body.replaceChildren(application); application.append(f.inbox);
      let wrapper = application;
      for (let depth = 0; depth < 12; depth++) {
        const child = new f.Node('DIV'); wrapper.append(child); wrapper = child;
      }
      wrapper.append(f.scope);
      f.inbox.connected = true; f.scope.connected = true;
    }
    f.document.activeElement = null;
    f.document.elementFromPoint = () => fullscreen;
    return { ...f, heading, maximize, fullscreen, close };
  }

  function competingPriorityBranches(kind: 'focus' | 'form') {
    const f = fixture(null), background = new f.Node(kind === 'form' ? 'FORM' : 'DIV');
    const compose = new f.Node('BUTTON', {}, 'Compose');
    background.append(compose);
    for (let index = 0; index < 300; index++)
      background.append(new f.Node('P', {}, `Synthetic record ${index}: ${'x'.repeat(1000)}`));
    const panel = new f.Node('DIV', { ...(kind === 'focus' ? { role: 'dialog' } : {}), 'aria-label': 'New message' });
    const heading = new f.Node('H2', {}, 'New message'), fullscreen = new f.Node('BUTTON', {}, 'Full screen');
    const close = new f.Node('BUTTON', {}, 'Save & close');
    panel.append(heading, fullscreen, close); f.document.body.append(background, panel);
    f.document.activeElement = kind === 'focus' ? compose : null;
    f.document.elementFromPoint = () => fullscreen;
    return { ...f, background, compose, panel, heading, fullscreen, close };
  }

  for (const kind of ['focus', 'form'] as const) {
    test(`a discovered panel survives the ordinary descendants of an earlier ${kind} priority branch`, async () => {
      const f = competingPriorityBranches(kind), result = await f.run({ operation: 'observe' });
      const panel = result.nodes.find((node: any) => node.name === 'New message' && node.role === (kind === 'focus' ? 'dialog' : 'group'));
      expect(panel).toBeDefined(); expect(panel.isDOMClickable).toBe(false); expect(panel.isEditable).toBe(false);
      expect(panel.childNodeIDs.map((id: string) => result.nodes.find((node: any) => node.nodeID === id).name))
        .toEqual(['New message', 'Full screen', 'Save & close']);
      for (const label of ['Full screen', 'Save & close']) {
        const control = result.nodes.find((node: any) => node.name === label);
        expect(control.role).toBe('button'); expect(control.isDOMClickable).toBe(true);
        expect(control.parentNodeID).toBe(panel.nodeID);
      }
      for (const [index, node] of result.nodes.entries()) {
        if (node.parentNodeID) expect(result.nodes.findIndex((parent: any) => parent.nodeID === node.parentNodeID)).toBeLessThan(index);
      }
      expect(result.nodes.some((node: any) => node.name.startsWith('Synthetic record '))).toBe(true);
      expect(result.nodes.some((node: any) => node.isEditable || node.name === 'Send')).toBe(false);
      expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.stopReason).toBe('byte_budget');
      expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
      expect(result.captureDiagnostics.visited).toBeLessThanOrEqual(20_001); expect(result.nodes.length).toBeLessThanOrEqual(3_000);
      expect(new Set(result.nodes.map((node: any) => node.nodeID)).size).toBe(result.nodes.length);
      expect(f.compose.clicks + f.fullscreen.clicks + f.close.clicks).toBe(0);
    });
  }

  test('cross-branch capture priority preserves hidden and changed-reference rejection without input', async () => {
    for (const change of ['hidden', 'replaced', 'parent', 'obstructed']) {
      const f = competingPriorityBranches('focus');
      if (change === 'hidden') f.panel.values['aria-hidden'] = 'true';
      const result = await f.run({ operation: 'observe' });
      if (change === 'hidden') {
        expect(result.nodes.some((node: any) => ['New message', 'Full screen', 'Save & close'].includes(node.name))).toBe(false);
      } else {
        const control = result.nodes.find((node: any) => node.name === 'Full screen');
        expect(control).toBeDefined();
        if (change === 'replaced') f.panel.replaceChildren(new f.Node('BUTTON', {}, 'Full screen'));
        if (change === 'parent') {
          f.panel.children = f.panel.children.filter(child => child !== f.fullscreen);
          f.document.body.append(f.fullscreen);
        }
        if (change === 'obstructed') f.document.elementFromPoint = () => f.compose;
        await expect(f.press(control)).rejects.toThrow(change === 'obstructed' ? 'element_obstructed' : 'element_changed');
      }
      expect(f.compose.clicks + f.fullscreen.clicks + f.close.clicks).toBe(0);
    }
  });

  for (const [deep, dialog] of [[false, false], [true, true], [true, false]]) {
    test(`unfocused minimized ${dialog ? 'dialog' : 'named panel'} ${deep ? 'behind wide fanout' : 'after inbox'} exposes controls without inventing fields`, async () => {
      const f = minimized(deep, dialog);
      const result = await f.run({ operation: 'observe' });
      const panel = result.nodes.find((node: any) => node.name === 'New message' && node.role === (dialog ? 'dialog' : 'group'));
      expect(panel).toBeDefined(); expect(panel.isDOMClickable).toBe(false);
      const controls = result.nodes.filter((node: any) => node.parentNodeID === panel.nodeID && node.role === 'button');
      expect(controls.map((node: any) => node.name)).toEqual(['Maximize', 'Full screen', 'Close']);
      expect(panel.childNodeIDs.map((id: string) => result.nodes.find((node: any) => node.nodeID === id).name))
        .toEqual(['New message', 'Maximize', 'Full screen', 'Close']);
      expect(result.nodes.some((node: any) => node.isEditable || node.name === 'Send')).toBe(false);
      expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.stopReason).toBe('byte_budget');
      expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
      expect(result.captureDiagnostics.visited).toBeLessThanOrEqual(20_001); expect(result.nodes.length).toBeLessThanOrEqual(3_000);
      expect(new Set(result.nodes.map((node: any) => node.nodeID)).size).toBe(result.nodes.length);
      const row = controls.find((node: any) => node.name === 'Full screen');
      expect(row.isDOMClickable).toBe(true); expect(row.isDisabled).toBe(false);
      expect(await f.press(row)).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
      expect(f.fullscreen.clicks).toBe(1); expect(f.maximize.clicks).toBe(0); expect(f.close.clicks).toBe(0); expect(f.send.clicks).toBe(0);
      const expanded = await f.run({ operation: 'observe' });
      expect(expanded.nodes.filter((node: any) => node.isEditable).map((node: any) => node.name))
        .toEqual(['Recipients', 'Subject', 'Message body']);
    });
  }

  test('minimized panel priority never makes its passive container actionable or revives changed controls', async () => {
    for (const drift of ['passive', 'replaced', 'role', 'parent', 'hidden', 'route', 'obstructed']) {
      const f = minimized(), capturedURL = f.location.href;
      const result = await f.run({ operation: 'observe' });
      const row = result.nodes.find((node: any) => node.name === (drift === 'passive' ? 'New message' : 'Full screen')
        && node.role === (drift === 'passive' ? 'group' : 'button'));
      expect(row).toBeDefined();
      if (drift === 'passive') {
        expect(row.isPressUnsupported).toBe(true); expect(row.isReadOnly).toBe(true);
        f.document.elementFromPoint = () => f.scope;
      }
      if (drift === 'replaced') f.scope.replaceChildren(new f.Node('BUTTON', {}, 'Full screen'));
      if (drift === 'role') f.fullscreen.values.role = 'heading';
      if (drift === 'parent') { f.scope.children = f.scope.children.filter(node => node !== f.fullscreen); f.document.body.append(f.fullscreen); }
      if (drift === 'hidden') f.scope.values.hidden = '';
      if (drift === 'route') f.location.href = 'https://example.test/changed';
      if (drift === 'obstructed') f.document.elementFromPoint = () => f.link;
      await expect(f.run({ operation: 'press', nodeID: row.backendNodeID, expected: row, expectedURL: capturedURL }))
        .rejects.toThrow(['passive', 'route'].includes(drift) ? 'stale_document'
          : drift === 'obstructed' ? 'element_obstructed' : 'element_changed');
      expect(f.fullscreen.clicks).toBe(0); expect(f.send.clicks).toBe(0); expect(f.to.valueWrites).toEqual([]);
    }
  });

  test('expansion beyond the compact-panel bound preserves real text fields without autofocus or form semantics', async () => {
    const f = minimized(true);
    f.fullscreen.onClick = () => {
      for (let index = 0; index < 100; index++) f.scope.append(new f.Node('SPAN', {}, `Visible panel detail ${index}`));
      for (const node of [f.to, f.subject, f.body, f.send]) node.connected = true;
      f.scope.append(f.to, f.subject, f.body, f.send);
    };
    const before = await f.run({ operation: 'observe' });
    const full = before.nodes.find((node: any) => node.name === 'Full screen' && node.role === 'button');
    expect(await f.press(full)).toMatchObject({ dispatched: true, noReplay: true });
    expect(f.document.activeElement).toBeNull(); expect(f.scope.values.role).toBeUndefined();
    const result = await f.run({ operation: 'observe' });
    expect(result.nodes.filter((node: any) => node.isEditable).map((node: any) => node.name))
      .toEqual(['Recipients', 'Subject', 'Message body']);
    const panel = result.nodes.find((node: any) => node.name === 'New message' && node.role === 'group');
    expect(panel.isDOMClickable).toBe(false); expect(panel.isReadOnly).toBe(true);
    expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
    f.document.elementFromPoint = () => f.to;
    const to = result.nodes.find((node: any) => node.name === 'Recipients');
    expect(await f.fill(to, 'fixture@example.invalid')).toMatchObject({ dispatched: true, noReplay: true });
    expect(f.to.value).toBe('fixture@example.invalid'); expect(f.send.clicks).toBe(0);
  });

  test('hidden minimized panels expose no controls or secure values', async () => {
    for (const hidden of ['hidden', 'inert', 'aria-hidden']) {
      const f = minimized(true); f.scope.values[hidden] = hidden === 'aria-hidden' ? 'true' : '';
      f.scope.append(new f.Node('INPUT', { type: 'password', value: 'PRIVATE_FIELD_VALUE' }));
      const result = await f.run({ operation: 'observe' });
      expect(result.nodes.some((node: any) => ['New message', 'Full screen', 'Close'].includes(node.name))).toBe(false);
      expect(JSON.stringify(result)).not.toContain('PRIVATE_FIELD_VALUE');
      expect(result.sourceTruncated).toBe(true); expect(f.fullscreen.clicks).toBe(0);
    }
  });

  test('late compose controls survive source truncation with or without focus', async () => {
    for (const kind of ['dialog', 'native-dialog', 'form', 'focus-only'] as const) {
      const f = crowded(kind, kind === 'focus-only');
      const result = await f.run({ operation: 'observe' });
      const fields = result.nodes.filter((node: any) => node.isEditable);
      expect(fields.map((node: any) => node.name)).toEqual(['Recipients', 'Subject', 'Message body']);
      expect(result.nodes.find((node: any) => node.name === 'Send').isDOMClickable).toBe(true);
      expect(result.sourceTruncated).toBe(true);
      expect(result.captureDiagnostics.stopReason).toBe('byte_budget');
      expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230000);
      expect(result.captureDiagnostics.visited).toBeLessThanOrEqual(20001);
      expect(result.nodes.length).toBeLessThanOrEqual(3000);
      expect(new Set(result.nodes.map((node: any) => node.nodeID)).size).toBe(result.nodes.length);
      for (const field of fields) {
        const parent = result.nodes.find((node: any) => node.nodeID === field.parentNodeID);
        expect(parent.name).toBe('New message'); expect(parent.childNodeIDs).toContain(field.nodeID);
        expect(field.isDisabled).toBe(false); expect(field.isReadOnly).toBe(false);
      }
      expect(await f.fill(fields[0], 'fixture@example.invalid'))
        .toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
      expect(f.to.value).toBe('fixture@example.invalid'); expect(f.to.events.map((event: any) => event.type)).toEqual(['input', 'change']);
      expect(f.send.clicks).toBe(0);
    }
  });

  test('focused path survives the bounded discovery cap without manufacturing missing siblings', async () => {
    const f = crowded('focus-only', true);
    // A focused branch is known directly from the DOM, even when structural
    // discovery cannot enumerate all unrelated descendants within its cap.
    for (let index = 0; index < 5000; index++) f.inbox.append(new f.Node('DIV'));
    const result = await f.run({ operation: 'observe' });
    expect(result.nodes.some((node: any) => node.name === 'Recipients' && node.isEditable)).toBe(true);
    expect(result.sourceTruncated).toBe(true);
    expect(result.nodes.filter((node: any) => node.role === 'row').length).toBeLessThan(300);
    expect(result.captureDiagnostics.visited).toBeLessThanOrEqual(20001);
  });

  test('hidden, inert and aria-hidden late dialogs expose neither controls nor secure values', async () => {
    for (const hidden of ['hidden', 'inert', 'aria-hidden']) {
      const f = crowded('dialog', true);
      f.scope.values[hidden] = hidden === 'aria-hidden' ? 'true' : '';
      f.scope.append(new f.Node('INPUT', { type: 'password', value: 'DO_NOT_CAPTURE', 'aria-label': 'Password' }));
      const result = await f.run({ operation: 'observe' });
      expect(result.nodes.some((node: any) => ['Recipients', 'New message', 'Password'].includes(node.name))).toBe(false);
      expect(JSON.stringify(result)).not.toContain('DO_NOT_CAPTURE');
      expect(result.sourceTruncated).toBe(true); expect(f.to.valueWrites).toEqual([]); expect(f.send.clicks).toBe(0);
    }
  });

  test('prioritized fields still reject stale identity, role, parent, route and obstruction before input', async () => {
    for (const drift of ['replaced', 'role', 'parent', 'route', 'obstructed', 'hidden']) {
      const f = crowded('dialog', true), capturedURL = f.location.href;
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'Recipients');
      expect(row).toBeDefined();
      if (drift === 'replaced') f.scope.replaceChildren(new f.Node('INPUT', { type: 'email', 'aria-label': 'Recipients' }));
      if (drift === 'role') f.to.values.role = 'button';
      if (drift === 'parent') {
        f.scope.children = f.scope.children.filter(child => child !== f.to);
        f.document.body.append(f.to);
      }
      if (drift === 'route') f.location.href = 'https://example.test/changed';
      if (drift === 'obstructed') f.document.elementFromPoint = () => f.link;
      if (drift === 'hidden') f.scope.values.hidden = '';
      await expect(f.run({ operation: 'fill', nodeID: row.backendNodeID, expected: row,
        expectedURL: capturedURL, text: 'fixture@example.invalid' })).rejects.toThrow(
          drift === 'route' ? 'stale_document' : drift === 'obstructed' ? 'element_obstructed' : 'element_changed');
      expect(f.to.valueWrites).toEqual([]); expect(f.to.events).toEqual([]); expect(f.send.clicks).toBe(0);
    }
  });

  test('structural groups and table cells retain child text and explicit names without aggregate amplification', async () => {
    for (const role of ['group', 'dialog', 'table', 'grid', 'rowgroup', 'row', 'cell', 'gridcell', 'toolbar', 'listbox']) {
      const f = fixture(null), container = new f.Node('DIV', { role });
      const paragraphs = Array.from({ length: 8 }, (_, index) => `Exact child ${index}: ${'x'.repeat(900)}`);
      for (const paragraph of paragraphs) container.append(new f.Node('P', {}, paragraph));
      f.document.body.append(container);
      const result = await f.run({ operation: 'observe' });
      expect(result.nodes[0].name).toBe(''); expect(result.nodes[0].isDOMClickable).toBe(false);
      expect(result.nodes.filter((node: any) => node.role === 'statictext').map((node: any) => node.name)).toEqual(paragraphs);
      expect(result.sourceTruncated).toBe(false); expect(result.captureDiagnostics.clippedFields).toBe(0);
      container.values['aria-label'] = 'Explicit scope name';
      expect((await f.run({ operation: 'observe' })).nodes[0].name).toBe('Explicit scope name');
    }
  });

  test('small prioritized captures preserve ordinary page content and honest full coverage', async () => {
    const f = fixture(null), before = new f.Node('P', {}, 'Visible page background');
    const dialog = new f.Node('DIV', { role: 'dialog', 'aria-label': 'New message' });
    dialog.append(new f.Node('INPUT', { 'aria-label': 'Recipients' }), new f.Node('BUTTON', {}, 'Send'));
    f.document.body.append(before, dialog);
    const result = await f.run({ operation: 'observe' });
    expect(result.nodes.map((node: any) => node.name)).toEqual(['New message', 'Recipients', 'Send', 'Visible page background']);
    expect(result.sourceTruncated).toBe(false); expect(result.captureDiagnostics.stopReason).toBe('none');
  });

  test('moving focus changes read priority without changing evidence sibling order or text order', async () => {
    const f = fixture(null), group = new f.Node('DIV', { role: 'group', 'aria-label': 'Stable region' });
    const first = new f.Node('P', {}, 'First actual text'), second = new f.Node('P', {}, 'Second actual text');
    group.append(first, second); f.document.body.append(group);
    const before = await f.run({ operation: 'observe' });
    f.document.activeElement = second;
    const after = await f.run({ operation: 'observe' });
    expect(after.nodes.map((node: any) => node.name)).toEqual(['Stable region', 'Second actual text', 'First actual text']);
    expect(after.nodes[0].childNodeIDs).toEqual(before.nodes[0].childNodeIDs);
    expect(after.nodes[0].childNodeIDs.map((id: string) => after.nodes.find((node: any) => node.nodeID === id).name))
      .toEqual(['First actual text', 'Second actual text']);
    expect(after.sourceTruncated).toBe(false);
  });

  test('discovery counts text/comment child slots instead of scanning unbounded non-elements', async () => {
    const f = fixture(null), dialog = new f.Node('DIV', { role: 'dialog', 'aria-label': 'Late dialog' });
    dialog.append(new f.Node('INPUT', { 'aria-label': 'Recipients' }));
    f.document.body.append(dialog);
    const comments = Array.from({ length: 5000 }, () => ({ nodeType: 8, parentElement: f.document.body }));
    const children = [...comments, dialog];
    let lists = 0, discoverySlots = 0;
    Object.defineProperty(f.document.body, 'childNodes', { get() {
      lists++;
      return lists === 1 ? new Proxy(children, { get(target, property, receiver) {
        if (typeof property === 'string' && /^\d+$/.test(property)) discoverySlots++;
        return Reflect.get(target, property, receiver);
      } }) : children;
    } });
    const dialogChildren = dialog.childNodes;
    let dialogLists = 0, dialogSlots = 0;
    Object.defineProperty(dialog, 'childNodes', { get() {
      dialogLists++;
      return dialogLists === 1 ? new Proxy(dialogChildren, { get(target, property, receiver) {
        if (typeof property === 'string' && /^\d+$/.test(property)) dialogSlots++;
        return Reflect.get(target, property, receiver);
      } }) : dialogChildren;
    } });
    const result = await f.run({ operation: 'observe' });
    expect(discoverySlots + dialogSlots).toBe(4096);
    expect(result.nodes.some((node: any) => node.name === 'Recipients' && node.isEditable)).toBe(true);
    expect(result.sourceTruncated).toBe(false, 'Exhausted priority discovery is not omitted source when ordinary capture completed');
    expect(result.captureDiagnostics.stopReason).toBe('none');
  });

  test('compact-panel probes share the discovery cap and never read page or field text', async () => {
    const f = minimized(true);
    await f.run({ operation: 'observe' });
    let captureStarted = false, childSlots = 0, contentReads = 0;
    const map = (f.state as any).__computaBrowserControlV1.nodes;
    map.clear = () => { captureStarted = true; Map.prototype.clear.call(map); };
    const prototype = f.Node.prototype;
    const children = Object.getOwnPropertyDescriptor(prototype, 'childNodes')!.get!;
    Object.defineProperty(prototype, 'childNodes', { get() {
      return new Proxy(children.call(this), { get(target, property, receiver) {
        if (!captureStarted && typeof property === 'string' && /^\d+$/.test(property)) childSlots++;
        return Reflect.get(target, property, receiver);
      } });
    } });
    for (const key of ['textContent', 'innerText', 'value']) {
      let owner: any = prototype;
      while (!Object.getOwnPropertyDescriptor(owner, key)) owner = Object.getPrototypeOf(owner);
      const descriptor = Object.getOwnPropertyDescriptor(owner, key)!;
      Object.defineProperty(prototype, key, { ...descriptor, get() {
        if (!captureStarted) contentReads++;
        return descriptor.get!.call(this);
      } });
    }
    const result = await f.run({ operation: 'observe' });
    expect(childSlots).toBe(4096); expect(contentReads).toBe(0);
    expect(result.nodes.some((node: any) => node.name === 'Full screen')).toBe(true);
    expect(result.sourceTruncated).toBe(true); expect(f.fullscreen.clicks).toBe(0);
  });
});

describe('bounded built-in semantic readiness', () => {
  test('nested footer links do not end a semantic wait before an outside control appears', async () => {
    const f = fixture(null), footer = new f.Node('FOOTER'), group = new f.Node('DIV', { role: 'group' });
    group.append(new f.Node('A', { href: 'https://example.test/terms' }, 'Terms'),
      new f.Node('A', { href: 'https://example.test/privacy' }, 'Privacy'));
    footer.append(group); f.document.body.append(footer);
    const pending = f.run({ operation: 'observe' });
    expect(f.observers.some(observer => observer.active)).toBe(true);
    expect([...f.timers.values()].map(timer => timer.delay)).toEqual([10000]);
    f.mutate(); expect(f.observers.some(observer => observer.active)).toBe(true);
    f.appendControl(); f.mutate();
    const result = await pending;
    expect(result.semanticReadiness).toBe('ready');
    expect(result.nodes.filter((node: any) => node.role === 'link').map((node: any) => node.name)).toEqual(['Terms', 'Privacy']);
    expect(result.nodes.some((node: any) => node.role === 'button' && node.name === 'Continue')).toBe(true);
    expect(f.observers.every(observer => !observer.active)).toBe(true); expect(f.timers.size).toBe(0);
  });

  test('footer-only deadline retains exact footer content and supported link capabilities as inconclusive evidence', async () => {
    const f = fixture(null), footer = new f.Node('FOOTER');
    footer.append(new f.Node('A', { href: 'https://example.test/terms?literal=A-B' }, 'Terms'));
    f.document.body.append(footer);
    const pending = f.run({ operation: 'observe' });
    f.expire(); const result = await pending;
    expect(result.semanticReadiness).toBe('empty_at_deadline'); expect(result.sourceTruncated).toBe(false);
    const link = result.nodes.find((node: any) => node.role === 'link');
    expect(link.name).toBe('Terms'); expect(link.linkURL).toBe('https://example.test/terms?literal=A-B');
    expect(link.isDOMClickable).toBe(true); expect(link.isPressUnsupported).toBe(false); expect(link.isDisabled).toBe(false);
    expect(result.nodes.find((node: any) => node.nodeID === link.parentNodeID).role).toBe('contentinfo');
    expect(f.observers.every(observer => !observer.active)).toBe(true); expect(f.timers.size).toBe(0);
  });

  test('an explicit footer-text wait still matches its observed text without waiting for non-footer content', async () => {
    const f = fixture(null), footer = new f.Node('FOOTER');
    footer.append(new f.Node('A', { href: 'https://example.test/terms' }, 'Terms'));
    f.document.body.append(footer);
    expect(await f.run({ operation: 'wait', text: 'Terms' })).toEqual({ matched: true });
    expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0);
  });

  test('readable content or navigation outside a footer returns immediately', async () => {
    for (const navigation of [false, true]) {
      const f = fixture(null), footer = new f.Node('FOOTER');
      footer.append(new f.Node('A', { href: 'https://example.test/terms' }, 'Terms'));
      f.document.body.append(footer);
      if (navigation) {
        const nav = new f.Node('NAV'); nav.append(new f.Node('A', { href: 'https://example.test/home' }, 'Home'));
        f.document.body.append(nav);
      } else { f.appendText('Rendered document content'); }
      expect((await f.run({ operation: 'observe' })).semanticReadiness).toBe('ready');
      expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0);
    }
  });

  test('identity and preflight captures of blank documents do not register a semantic wait or claim a deadline', async () => {
    const f = fixture(null), result = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    expect(result.nodes).toEqual([]); expect(result.semanticReadiness).toBeUndefined();
    expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0);
  });
  test('meaningful pages return immediately without registering a wait', async () => {
    const f = fixture('_self'), result = await f.run({ operation: 'observe' });
    expect(result.semanticReadiness).toBe('ready');
    expect(f.observers).toHaveLength(0); expect(f.timers.size).toBe(0);
  });

  test('a title or landmark label alone waits for delayed readable DOM content', async () => {
    const f = fixture(null); f.appendMetadata();
    const pending = f.run({ operation: 'observe' });
    expect(f.observers.some(observer => observer.active)).toBe(true);
    expect([...f.timers.values()].map(timer => timer.delay)).toEqual([10000]);
    f.appendText('Rendered page content'); f.mutate();
    const result = await pending;
    expect(result.semanticReadiness).toBe('ready');
    expect(result.nodes.some((node: any) => node.name === 'Rendered page content')).toBe(true);
    expect(f.observers.every(observer => !observer.active)).toBe(true);
    expect(f.timers.size).toBe(0); expect([...f.listeners.values()].every(set => set.size === 0)).toBe(true);
  });

  test('a truly blank page returns bounded empty evidence, without an error or presence claim', async () => {
    const f = fixture(null), pending = f.run({ operation: 'observe' });
    f.expire(); const result = await pending;
    expect(result.semanticReadiness).toBe('empty_at_deadline'); expect(result.nodes).toEqual([]);
    expect(result.sourceTruncated).toBe(false); expect(f.timers.size).toBe(0);
    expect(f.observers.every(observer => !observer.active)).toBe(true);
  });

  test('observing the document follows a replaced root rather than waiting on its detached subtree', async () => {
    const f = fixture(null), pending = f.run({ operation: 'observe' });
    expect(f.observers[0].target).toBe(f.document);
    f.replaceRoot(); f.appendControl(); f.mutate();
    expect((await pending).semanticReadiness).toBe('ready');
  });

  test('omitted-text wait requires semantics after document readiness and expires false when blank', async () => {
    const f = fixture(null); f.document.readyState = 'loading';
    const pending = f.run({ operation: 'wait' });
    f.appendControl(); f.mutate(); expect(f.observers.some(observer => observer.active)).toBe(true);
    f.document.readyState = 'complete'; f.event('readystatechange');
    expect(await pending).toEqual({ matched: true });
    const blank = fixture(null), unmatched = blank.run({ operation: 'wait' });
    blank.expire(); expect(await unmatched).toEqual({ matched: false });
  });

  test('requested text still requires its own observed match and does not dispatch input', async () => {
    const f = fixture('_self'), pending = f.run({ operation: 'wait', text: 'Mailbox result' });
    expect(f.observers.some(observer => observer.active)).toBe(true);
    f.appendText('Mailbox result'); f.mutate();
    expect(await pending).toEqual({ matched: true }); expect(f.link.clicks).toBe(0);
  });

  test('requested text cannot match a document title or landmark label alone', async () => {
    const f = fixture(null); f.appendMetadata();
    const pending = f.run({ operation: 'wait', text: 'Outlook' });
    expect(f.observers.some(observer => observer.active)).toBe(true);
    f.appendText('Outlook mailbox controls'); f.mutate();
    expect(await pending).toEqual({ matched: true });
  });
});
