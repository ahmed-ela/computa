import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

const source = readFileSync(process.env.COMPUTA_BROWSER_CONTROL_SOURCE
  || new URL('../Sources/Computa/Resources/BrowserModels/browser-control.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function fixture(target: string | null) {
  const styles = new WeakMap<Element, { display?: string; visibility?: string }>();
  const computedStyle = (element: Element) => {
    let visibility = 'visible';
    for (let node: Element | null = element; node; node = node.parentElement) {
      const declared = styles.get(node)?.visibility;
      if (declared && declared !== 'inherit') { visibility = declared; break; }
    }
    return { display: styles.get(element)?.display || 'block', visibility };
  };
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
    getClientRects() {
      if (computedStyle(this).display === 'contents') return [];
      for (let node: Element | null = this; node; node = node.parentElement)
        if (computedStyle(node).display === 'none') return [];
      return super.getClientRects();
    }
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
    createRange: () => ({ selectNodeContents() {}, getClientRects: () => [{}] }),
    getElementById: (id: string) => document.body.descendants().find(node => node.values.id === id) || null,
    addEventListener(name: string, callback: Function) {
      if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name)!.add(callback);
    }, removeEventListener(name: string, callback: Function) { listeners.get(name)?.delete(callback); } };
  const state = {}, location = { href: 'https://example.test/' };
  const execute = new AsyncFunction('input', 'globalThis', 'document', 'location', 'Node', 'getComputedStyle', 'TextEncoder',
    'MutationObserver', 'setTimeout', 'clearTimeout', 'HTMLInputElement', 'HTMLTextAreaElement', 'HTMLSelectElement', 'Event', 'Element', 'innerWidth', 'innerHeight', source);
  const rawRun = (input: Record<string, unknown>) => execute({ documentToken: 'owned-document', timeoutMS: 10000, awaitSemanticReadiness: true, ...input }, state, document, location,
    { TEXT_NODE: 3, ELEMENT_NODE: 1, DOCUMENT_POSITION_PRECEDING: 2, DOCUMENT_POSITION_FOLLOWING: 4 }, computedStyle, TextEncoder, Observer,
    (callback: Function, delay: number) => { timers.set(++timerID, { callback, delay }); return timerID; },
    (id: number) => timers.delete(id), Node, Node, Node, Event, Node, 1024, 768);
  // Native rejects this private diagnostic envelope as the same unconfirmed
  // action. Preserve direct guard assertions; dedicated tests inspect rawRun.
  const run = async (input: Record<string, unknown>) => {
    const result = await rawRun(input);
    if (result.browserActionFailure) throw new Error(result.browserActionFailure.code);
    return result;
  };
  const press = (row: any) => run({ operation: 'press', nodeID: row.backendNodeID,
    expected: row, expectedURL: location.href });
  const fill = (row: any, text: string) => run({ operation: 'fill', nodeID: row.backendNodeID,
    expected: row, expectedURL: location.href, text });
  return { Node, link, run, rawRun, press, fill, document, location, timers, observers, listeners, state, styles,
    appendText: (text: string) => document.body.append(new Node('P', {}, text)),
    appendControl: () => document.body.append(new Node('BUTTON', {}, 'Continue')),
    appendMetadata: () => document.body.append(new Node('MAIN', { 'aria-label': 'Outlook' })),
    mutate: () => observers.filter(observer => observer.active).forEach(observer => observer.callback()),
    event: (name: string) => listeners.get(name)?.forEach(callback => callback()),
    expire: () => [...timers.values()].forEach(timer => timer.callback()),
    replaceRoot: () => { document.body = new Node('BODY'); document.documentElement = document.body; },
  };
}

describe('finite browser action failure diagnostics', () => {
  async function setup() {
    const f = fixture(null), field = new f.Node('INPUT', { 'aria-label': 'PRIVATE_FIELD_LABEL' });
    f.document.body.append(field); f.document.elementFromPoint = () => field;
    const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.role === 'textbox');
    const action = () => f.rawRun({ operation: 'fill', nodeID: row.backendNodeID, expected: row,
      expectedURL: f.location.href, text: 'PRIVATE_TYPED_VALUE' });
    return { ...f, field, row, action };
  }
  function finite(result: any, stage: string, code: string, operation = 'fill') {
    const { hitTest, ...diagnostic } = result.browserActionFailure || {};
    expect(diagnostic).toEqual({ version: 1, operation, stage, code });
    expect(Object.keys(result)).toEqual(['browserActionFailure']);
    if (code !== 'element_obstructed') expect(hitTest).toBeUndefined();
    const serialized = JSON.stringify(result);
    for (const secret of ['PRIVATE_', 'example.test', 'owned-document', 'selector', 'stack', 'message']) expect(serialized).not.toContain(secret);
    expect(result).not.toHaveProperty('dispatched'); expect(result).not.toHaveProperty('noReplay');
  }
  test('pre-focus obstruction is finite and cannot focus or write a visible settable field', async () => {
    const f = await setup(); expect(f.row.isEditable).toBe(true);
    f.document.elementFromPoint = () => f.link;
    finite(await f.action(), 'initial_hit_test', 'element_obstructed');
    expect(f.field.focusOptions).toEqual([]); expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toEqual([]);
  });
  test('initial metadata and post-focus metadata, focus destination and hit tests remain distinct closed failures', async () => {
    for (const kind of ['initial', 'metadata', 'focus', 'hit']) {
      const f = await setup();
      if (kind === 'initial') f.field.values['aria-label'] = 'PRIVATE_CHANGED_LABEL';
      else f.field.onFocus = () => {
        if (kind === 'metadata') f.field.values['aria-label'] = 'PRIVATE_CHANGED_LABEL';
        if (kind === 'focus') f.document.activeElement = f.link;
        if (kind === 'hit') f.document.elementFromPoint = () => f.link;
      };
      finite(await f.action(), kind === 'initial' ? 'initial_revalidation' : kind === 'metadata'
        ? 'focused_revalidation' : kind === 'focus' ? 'focus_confirmation' : 'focused_hit_test',
      kind === 'hit' ? 'element_obstructed' : 'element_changed');
      expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toEqual([]);
      expect(f.field.focusOptions).toHaveLength(kind === 'initial' ? 0 : 1);
    }
  });
  test('unexpected scroll and focus throws never expose their text or impersonate a known rejection', async () => {
    for (const stage of ['scroll', 'focus']) for (const thrown of [new Error('element_changed PRIVATE_EXCEPTION'), 'element_obstructed']) {
      const f = await setup();
      if (stage === 'scroll') f.field.scrollIntoView = () => { throw thrown; };
      else f.field.onFocus = () => { throw thrown; };
      finite(await f.action(), stage, 'unexpected'); expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toEqual([]);
    }
  });
  test('setter, input and change exceptions retain dispatch ambiguity and do not roll back or retry', async () => {
    for (const stage of ['value_write', 'input_event', 'change_event']) {
      const f = await setup();
      if (stage === 'value_write') {
        const descriptor = Object.getOwnPropertyDescriptor(f.Node.prototype, 'value')!;
        Object.defineProperty(f.Node.prototype, 'value', { ...descriptor, set(value: string) {
          descriptor.set!.call(this, value); throw new Error('PRIVATE_SETTER_SECRET');
        } });
      } else {
        f.field.dispatchEvent = (event: Event) => {
          f.field.events.push(event);
          if (event.type === (stage === 'input_event' ? 'input' : 'change')) throw new Error('PRIVATE_EVENT_SECRET');
          return true;
        };
      }
      finite(await f.action(), stage, 'unexpected');
      expect(f.field.valueWrites).toEqual(['PRIVATE_TYPED_VALUE']); expect(f.field.value).toBe('PRIVATE_TYPED_VALUE');
      expect(f.field.events.map(event => event.type)).toEqual(stage === 'value_write' ? [] : stage === 'input_event' ? ['input'] : ['input', 'change']);
    }
  });
  test('press exceptions can follow a click effect without yielding a dispatch claim', async () => {
    const f = fixture(null), button = new f.Node('BUTTON', {}, 'PRIVATE_BUTTON');
    f.document.body.append(button); f.document.elementFromPoint = () => button;
    const row = (await f.run({ operation: 'observe' })).nodes[0];
    button.onClick = () => { throw new Error('PRIVATE_CLICK_SECRET'); };
    finite(await f.rawRun({ operation: 'press', nodeID: row.backendNodeID, expected: row, expectedURL: f.location.href }),
      'press_dispatch', 'unexpected', 'press');
    expect(button.clicks).toBe(1);
  });
  test('successful action replies and values stay unchanged', async () => {
    const f = await setup();
    expect(await f.action()).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
    expect(f.field.valueWrites).toEqual(['PRIVATE_TYPED_VALUE']); expect(f.field.events.map(event => event.type)).toEqual(['input', 'change']);
  });
});

describe('finite hit-test obstruction diagnostics', () => {
  async function setup() {
    const f = fixture(null), field = new f.Node('INPUT', { 'aria-label': 'PRIVATE_SUBJECT' });
    const panel = new f.Node('DIV', { role: 'dialog' }); panel.append(field); f.document.body.append(panel);
    f.document.elementFromPoint = () => field;
    const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'PRIVATE_SUBJECT');
    const action = () => f.rawRun({ operation: 'fill', nodeID: row.backendNodeID, expected: row, expectedURL: f.location.href, text: 'PRIVATE_VALUE' });
    return { ...f, field, panel, row, action };
  }
  function finite(result: any, stage: string, hitTest: Record<string, string>) {
    expect(result).toEqual({ browserActionFailure: { version: 1, operation: 'fill', stage, code: 'element_obstructed', hitTest } });
    const json = JSON.stringify(result);
    for (const secret of ['PRIVATE', 'left', 'top', 'width', 'height', 'value', 'label', 'selector', 'class', 'message']) expect(json).not.toContain(secret);
    expect(json.length).toBeLessThan(512); expect(result).not.toHaveProperty('dispatched');
  }
  test('recipient-style overlay classifies a foreign listbox without focus, write or replay', async () => {
    const f = await setup(), overlay = new f.Node('DIV', { role: 'listbox', 'aria-label': 'PRIVATE_RECIPIENTS' });
    f.document.body.append(overlay); f.document.elementFromPoint = () => overlay;
    finite(await f.action(), 'initial_hit_test', { reason: 'foreign_hit', centerX: 'inside', centerY: 'inside',
      hitTag: 'div', hitRole: 'listbox', relation: 'other' });
    expect(f.field.focusOptions).toEqual([]); expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toEqual([]);
  });
  test('post-focus overlay and an ancestor hit are distinguished without changing guard order', async () => {
    for (const ancestor of [false, true]) {
      const f = await setup(), overlay = ancestor ? f.panel : new f.Node('SPAN', { role: 'tooltip' });
      f.field.onFocus = () => { f.document.elementFromPoint = () => overlay; };
      finite(await f.action(), 'focused_hit_test', { reason: 'foreign_hit', centerX: 'inside', centerY: 'inside',
        hitTag: ancestor ? 'div' : 'span', hitRole: ancestor ? 'dialog' : 'tooltip', relation: ancestor ? 'ancestor' : 'other' });
      expect(f.field.focusOptions).toEqual([{ preventScroll: true }]); expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toEqual([]);
    }
  });
  test('offscreen centers, null hits and nonpositive boxes use finite relative classes only', async () => {
    for (const scenario of [
      { left: 1100, top: 0, width: 100, height: 20, reason: 'outside_viewport', x: 'after', y: 'inside' },
      { left: -200, top: 0, width: 100, height: 20, reason: 'outside_viewport', x: 'before', y: 'inside' },
      { left: 0, top: 800, width: 100, height: 20, reason: 'outside_viewport', x: 'inside', y: 'after' },
      { left: 0, top: 0, width: 100, height: 20, reason: 'null_hit', x: 'inside', y: 'inside' },
      { left: 0, top: 0, width: 0, height: 20, reason: 'rect_nonpositive', x: 'inside', y: 'inside' },
      { left: NaN, top: 0, width: 100, height: 20, reason: 'rect_nonfinite', x: 'unknown', y: 'inside' },
    ]) {
      const f = await setup(), calls: unknown[] = [];
      f.field.getBoundingClientRect = () => scenario;
      f.document.elementFromPoint = ((x: number, y: number) => { calls.push([x, y]); return null; }) as any;
      finite(await f.action(), 'initial_hit_test', { reason: scenario.reason, centerX: scenario.x, centerY: scenario.y,
        hitTag: 'none', hitRole: 'none', relation: 'none' });
      expect(calls).toHaveLength(1); expect(f.field.focusOptions).toEqual([]); expect(f.field.valueWrites).toEqual([]);
    }
  });
  test('unknown tags and arbitrary roles cannot escape their finite buckets', async () => {
    for (const role of ['PRIVATE_CUSTOM_ROLE', 'PRIVATE_' + 'x'.repeat(2000)]) {
      const f = await setup(), overlay = new f.Node('PRIVATE-TAG', { role }); f.document.elementFromPoint = () => overlay;
      finite(await f.action(), 'initial_hit_test', { reason: 'foreign_hit', centerX: 'inside', centerY: 'inside',
        hitTag: 'other', hitRole: 'other', relation: 'other' });
    }
  });
  test('diagnostic getter failures preserve the original obstruction without leaking or altering effects', async () => {
    const f = await setup(), overlay = new f.Node('DIV');
    overlay.getAttribute = () => { throw new Error('PRIVATE_GETTER'); }; f.document.elementFromPoint = () => overlay;
    expect(await f.action()).toEqual({ browserActionFailure: { version: 1, operation: 'fill', stage: 'initial_hit_test', code: 'element_obstructed' } });
    expect(f.field.focusOptions).toEqual([]); expect(f.field.valueWrites).toEqual([]);
  });
  test('successful input adds no geometry reads or hit-test diagnostics', async () => {
    const f = await setup(); let rects = 0, hits = 0;
    f.field.getBoundingClientRect = () => { rects++; return { left: 0, top: 0, width: 100, height: 20 }; };
    f.document.elementFromPoint = () => { hits++; return f.field; };
    expect(await f.action()).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
    expect(rects).toBe(2); expect(hits).toBe(2); expect(f.field.valueWrites).toEqual(['PRIVATE_VALUE']);
  });
});

describe('CSS visibility overrides preserve rendered descendants', () => {
  test('visible descendants of hidden or collapsed wrappers remain observable and actionable', async () => {
    for (const visibility of ['hidden', 'collapse']) for (const display of ['block', 'contents']) {
      const f = fixture(null), scope = new f.Node('DIV', {}, 'EXCLUDED_PARENT_TEXT');
      const inherited = new f.Node('P', {}, 'EXCLUDED_INHERITED_TEXT');
      const branch = new f.Node('DIV'), field = new f.Node('INPUT', { 'aria-label': 'Recipient' });
      const button = new f.Node('BUTTON', {}, 'Apply');
      f.styles.set(scope, { visibility, display }); f.styles.set(branch, { visibility: 'visible' });
      branch.append(new f.Node('P', {}, 'Visible child body'), field, button);
      scope.append(inherited, branch); f.document.body.append(scope);
      const snapshot = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
      expect(snapshot.nodes.some((node: any) => node.name === 'Visible child body')).toBe(true);
      expect(snapshot.nodes.some((node: any) => node.name.includes('EXCLUDED_'))).toBe(false);
      const fieldRow = snapshot.nodes.find((node: any) => node.name === 'Recipient');
      const buttonRow = snapshot.nodes.find((node: any) => node.name === 'Apply');
      expect(fieldRow?.isEditable).toBe(true); expect(buttonRow?.isDOMClickable).toBe(true);
      f.document.elementFromPoint = () => field;
      expect((await f.fill(fieldRow, 'Synthetic recipient')).dispatched).toBe(true);
      f.document.elementFromPoint = () => button;
      expect((await f.press(buttonRow)).dispatched).toBe(true);
      expect(button.clicks).toBe(1); expect(field.valueWrites).toEqual(['Synthetic recipient']);
    }
  });

  test('hidden semantic scopes retain only empty nonactionable ancestry for their visible children', async () => {
    for (const role of ['toolbar', 'button', 'textbox', 'navigation', 'dialog', 'group']) {
      const f = fixture(null), scope = new f.Node('DIV', { role, 'aria-label': 'EXCLUDED_SCOPE_NAME', contenteditable: 'true' }, 'EXCLUDED_SCOPE_VALUE');
      const child = new f.Node('BUTTON', {}, 'Visible action');
      f.styles.set(scope, { visibility: 'hidden' }); f.styles.set(child, { visibility: 'visible' });
      scope.append(child); f.document.body.append(scope); f.document.elementFromPoint = () => child;
      const snapshot = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
      expect(snapshot.nodes.some((node: any) => node.name.includes('EXCLUDED_') || String(node.value || '').includes('EXCLUDED_'))).toBe(false);
      const parent = snapshot.nodes.find((node: any) => node.role === role && node.name === '');
      const row = snapshot.nodes.find((node: any) => node.name === 'Visible action');
      expect(parent).toBeDefined(); expect(row?.parentNodeID).toBe(parent.nodeID);
      expect(parent.isIgnored).toBe(true);
      expect(parent.value).toBeNull(); expect(parent.isDisabled).toBe(true); expect(parent.isReadOnly).toBe(true);
      expect(parent.isEditable).toBe(false); expect(parent.isDOMClickable).toBe(false); expect(parent.isPressUnsupported).toBe(true);
      await expect(f.press(parent)).rejects.toThrow('element_changed');
      expect((await f.press(row)).dispatched).toBe(true); expect(child.clicks).toBe(1); expect(scope.clicks).toBe(0);
    }
  });

  test('visible overrides cannot bypass subtree exclusions or expose inherited hidden values', async () => {
    for (const exclusion of ['hidden', 'inert', 'aria-hidden', 'display:none', 'visibility:hidden']) {
      const f = fixture(null), scope = new f.Node('DIV');
      const child = new f.Node('INPUT', { 'aria-label': 'EXCLUDED_FIELD', value: 'EXCLUDED_VALUE' });
      if (exclusion === 'display:none') f.styles.set(scope, { display: 'none' });
      else if (exclusion === 'visibility:hidden') f.styles.set(scope, { visibility: 'hidden' });
      else scope.values[exclusion] = exclusion === 'aria-hidden' ? 'true' : '';
      if (exclusion !== 'visibility:hidden') f.styles.set(child, { visibility: 'visible' });
      scope.append(child); f.document.body.append(scope);
      const snapshot = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
      expect(snapshot.nodes.some((node: any) => node.name.includes('EXCLUDED_') || String(node.value || '').includes('EXCLUDED_'))).toBe(false);
      expect(snapshot.nodes.some((node: any) => node.isEditable || node.isDOMClickable)).toBe(false);
    }
  });

  test('hidden controls alone never release semantic readiness or expose their metadata', async () => {
    const f = fixture(null), scope = new f.Node('DIV', { role: 'button', 'aria-label': 'EXCLUDED_ACTION' });
    scope.append(new f.Node('INPUT', { 'aria-label': 'EXCLUDED_FIELD', value: 'EXCLUDED_VALUE' }));
    f.styles.set(scope, { visibility: 'hidden' }); f.document.body.append(scope);
    let settled = false;
    const observation = f.run({ operation: 'observe' }).then((result: any) => { settled = true; return result; });
    await Promise.resolve(); await Promise.resolve();
    expect(settled).toBe(false); expect(f.timers.size).toBe(1);
    f.expire();
    const result = await observation;
    expect(result.semanticReadiness).toBe('empty_at_deadline');
    expect(result.nodes.every((node: any) => node.isIgnored && !node.name && node.value === null)).toBe(true);
  });

  test('a large hidden-only legacy branch consumes no capture rows ahead of a later visible control', async () => {
    const f = fixture(null), hidden = new f.Node('DIV', { role: 'toolbar' });
    f.styles.set(hidden, { visibility: 'hidden' });
    for (let index = 0; index < 3500; index++)
      hidden.append(new f.Node('BUTTON', { 'aria-label': 'EXCLUDED_LEGACY_' + index }));
    const active = new f.Node('BUTTON', {}, 'Visible current action');
    f.document.body.append(hidden, active); f.document.elementFromPoint = () => active;
    const snapshot = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    const row = snapshot.nodes.find((node: any) => node.name === 'Visible current action');
    expect(row?.isDOMClickable).toBe(true);
    expect(snapshot.nodes.some((node: any) => node.isIgnored)).toBe(false);
    expect(snapshot.nodes).toHaveLength(1);
    expect(snapshot.sourceTruncated).toBe(false);
    expect(snapshot.captureDiagnostics.visited).toBeGreaterThan(3500);
    expect(snapshot.captureDiagnostics.estimatedBytes).toBeLessThan(2000);
    expect((await f.press(row)).dispatched).toBe(true); expect(active.clicks).toBe(1);
  });

  test('shared hidden ancestry flushes once across priority paths and retains visible text descendants', async () => {
    const f = fixture(null), scope = new f.Node('DIV', { role: 'toolbar' });
    const field = new f.Node('INPUT', { 'aria-label': 'Prioritized field' });
    const text = new f.Node('SPAN', {}, 'Visible text'), button = new f.Node('BUTTON', {}, 'Visible action');
    f.styles.set(scope, { visibility: 'hidden' });
    for (const child of [field, text, button]) f.styles.set(child, { visibility: 'visible' });
    scope.append(text, button, field); f.document.body.append(scope);
    const snapshot = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    const hiddenRows = snapshot.nodes.filter((node: any) => node.isIgnored);
    expect(hiddenRows).toHaveLength(1);
    const parent = hiddenRows[0], children = snapshot.nodes.filter((node: any) => node.parentNodeID === parent.nodeID);
    expect(children.map((node: any) => node.name).sort()).toEqual(['Prioritized field', 'Visible action', 'Visible text']);
    expect(parent.childNodeIDs).toHaveLength(3); expect(new Set(parent.childNodeIDs).size).toBe(3);
    expect(snapshot.captureDiagnostics.scheduling.emittedByPriority.reduce((a: number, b: number) => a + b, 0)).toBe(snapshot.nodes.length);
    expect(snapshot.captureDiagnostics.estimatedBytes).toBeLessThanOrEqual(220000);
  });

  test('a hidden ancestry chain that exceeds the byte budget cannot publish an orphaned child', async () => {
    const f = fixture(null);
    let parent = f.document.body;
    for (let depth = 0; depth < 300; depth++) {
      const scope = new f.Node('DIV', { role: 'toolbar' });
      f.styles.set(scope, { visibility: 'hidden' }); parent.append(scope); parent = scope;
    }
    const child = new f.Node('BUTTON', {}, 'Unpublished child');
    f.styles.set(child, { visibility: 'visible' }); parent.append(child);
    const snapshot = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    expect(snapshot.sourceTruncated).toBe(true); expect(snapshot.captureDiagnostics.stopReason).toBe('byte_budget');
    expect(snapshot.nodes).toHaveLength(0); expect(snapshot.captureDiagnostics.estimatedBytes).toBe(0);
    expect(snapshot.captureDiagnostics.scheduling.emittedByPriority).toEqual([0, 0, 0, 0]);
    expect((f.state as any).__computaBrowserControlV1.nodes.size).toBe(0); expect(child.clicks).toBe(0);
  });

  test('visibility, hard exclusions, parent identity and hit-test drift still reject current descendant references', async () => {
    for (const drift of ['inherited-hidden', 'own-hidden', 'display:none', 'hidden', 'inert', 'aria-hidden', 'parent', 'obstructed']) {
      const f = fixture(null), scope = new f.Node('DIV', { role: 'toolbar' }), child = new f.Node('BUTTON', {}, 'Visible action');
      f.styles.set(scope, { visibility: 'hidden' }); f.styles.set(child, { visibility: 'visible' });
      scope.append(child); f.document.body.append(scope); f.document.elementFromPoint = () => child;
      const row = (await f.run({ operation: 'observe', awaitSemanticReadiness: false })).nodes.find((node: any) => node.name === 'Visible action');
      expect(row).toBeDefined();
      if (drift === 'inherited-hidden') f.styles.delete(child);
      else if (drift === 'own-hidden') f.styles.set(child, { visibility: 'hidden' });
      else if (drift === 'display:none') f.styles.set(scope, { visibility: 'hidden', display: 'none' });
      else if (['hidden', 'inert', 'aria-hidden'].includes(drift)) scope.values[drift] = drift === 'aria-hidden' ? 'true' : '';
      else if (drift === 'parent') { scope.children = []; f.document.body.append(child); }
      else f.document.elementFromPoint = () => scope;
      await expect(f.press(row)).rejects.toThrow(drift === 'obstructed' ? 'element_obstructed' : 'element_changed');
      expect(child.clicks).toBe(0);
    }
  });
});

describe('bounded panel discovery diagnostics', () => {
  test('encountered panels distinguish rendered, subtree exclusion, visibility and missing own boxes', async () => {
    const f = fixture(null);
    const rendered = new f.Node('FORM'), displayNone = new f.Node('DIV', { role: 'dialog' });
    const hiddenVisibility = new f.Node('DIALOG'), boxless = new f.Node('DIV', { role: 'alertdialog' });
    f.styles.set(displayNone, { display: 'none' }); f.styles.set(hiddenVisibility, { visibility: 'hidden' });
    f.styles.set(boxless, { display: 'contents' });
    const hardHidden = ['hidden', 'inert', 'aria-hidden'].map(attribute =>
      new f.Node('FORM', { [attribute]: attribute === 'aria-hidden' ? 'true' : '' }));
    const prunedParent = new f.Node('DIV', { hidden: '' }); prunedParent.append(new f.Node('FORM'));
    f.document.body.append(rendered, displayNone, hiddenVisibility, boxless, ...hardHidden, prunedParent);
    const result = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    expect(result.captureDiagnostics.discovery).toEqual({ panelsByState: [1, 1, 3, 1, 1], prunedSubtrees: 5, limitReached: false });
    expect(result.sourceTruncated).toBe(false);
    expect(Object.keys(result.captureDiagnostics.discovery).sort()).toEqual(['limitReached', 'panelsByState', 'prunedSubtrees']);
  });

  test('a visible panel override is rendered but a panel below a pruned ancestor is unobserved', async () => {
    const f = fixture(null), hiddenVisibility = new f.Node('DIV'), panel = new f.Node('FORM');
    f.styles.set(hiddenVisibility, { visibility: 'hidden' }); f.styles.set(panel, { visibility: 'visible' });
    hiddenVisibility.append(panel);
    const displayNone = new f.Node('DIV'); f.styles.set(displayNone, { display: 'none' });
    displayNone.append(new f.Node('DIV', { role: 'dialog' })); f.document.body.append(hiddenVisibility, displayNone);
    const result = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    expect(result.captureDiagnostics.discovery).toEqual({ panelsByState: [1, 0, 0, 0, 0], prunedSubtrees: 1, limitReached: false });
  });

  test('discovery at its limit remains partial positive evidence even when normal capture completes', async () => {
    const f = fixture(null);
    for (let index = 0; index < 5000; index++) {
      const node = index === 2500 ? new f.Node('FORM', { hidden: '' }) : new f.Node('SPAN');
      f.document.body.append(node);
    }
    f.document.body.append(new f.Node('FORM'));
    const result = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    expect(result.captureDiagnostics.discovery).toEqual({ panelsByState: [1, 0, 0, 0, 0], prunedSubtrees: 0, limitReached: true });
    expect(result.captureDiagnostics.scheduling.discoverySlots).toBe(4096);
    expect(result.sourceTruncated).toBe(false);
    expect(result.nodes.filter((node: any) => node.role === 'form')).toHaveLength(1);
  });

  test('a pruned root is counted once without inventing charged child slots', async () => {
    const f = fixture(null); f.document.body.values.role = 'form'; f.document.body.values.hidden = '';
    const result = await f.run({ operation: 'observe', awaitSemanticReadiness: false });
    expect(result.captureDiagnostics.discovery).toEqual({ panelsByState: [0, 0, 1, 0, 0], prunedSubtrees: 1, limitReached: false });
    expect(result.captureDiagnostics.scheduling.discoverySlots).toBe(0);
    expect(result.nodes).toHaveLength(0);
  });
});

describe('native field semantics inside contenteditable', () => {
  const nestedField = (tag: string, attributes: Record<string, string> = {}) => {
    const f = fixture(null), wrapper = new f.Node('DIV', { contenteditable: 'true' });
    const field = new f.Node(tag, { 'aria-label': 'Native field', value: 'Before value', ...attributes }, 'Original child markup');
    // Real WebKit supplies true here through the editable ancestor. Keep this
    // focused fixture about native-kind precedence, not a new DOM emulator.
    Object.defineProperty(field, 'isContentEditable', { get: () => true });
    wrapper.append(field); f.document.body.append(wrapper); f.document.elementFromPoint = () => field;
    return { ...f, field, wrapper };
  };

  test('INPUT, TEXTAREA and SELECT read native values and dispatch their native setter without replacing child markup', async () => {
    for (const tag of ['INPUT', 'TEXTAREA', 'SELECT']) {
      const f = nestedField(tag), events: string[] = [];
      f.field.onDispatch = (event: any) => events.push(event.type);
      Object.assign(f.field, { required: true, willValidate: true, validity: { valid: true } });
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'Native field');
      expect(row.role).toBe(tag === 'SELECT' ? 'combobox' : 'textbox');
      expect(row.value).toBe('Before value'); expect(row.isEditable).toBe(true);
      expect(row.constraintValidation).toEqual({ required: true, candidate: true, valid: true, issues: [] });
      expect(await f.fill(row, 'After value')).toEqual({ dispatched: true, noReplay: true, constraintFeedback: null });
      expect(f.field.value).toBe('After value'); expect(f.field.valueWrites).toEqual(['After value']);
      expect(f.field.textContent).toBe('Original child markup'); expect(events).toEqual(['input', 'change']);
      expect((await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'Native field').value).toBe('After value');
    }
  });

  test('inherited editing never expands the native INPUT type allowlist or reveals protected values', async () => {
    for (const type of ['file', 'hidden', 'checkbox', 'radio', 'range', 'submit', 'button', 'reset', 'image', 'password']) {
      const f = nestedField('INPUT', { type, role: 'textbox', value: 'EXCLUDED_PRIVATE_VALUE' });
      const snapshot = await f.run({ operation: 'observe' });
      const row = snapshot.nodes.find((node: any) => node.name === 'Native field');
      expect(row.isEditable).toBe(false); expect(row.isReadOnly).toBe(true); expect(row.value).toBeNull();
      expect(snapshot.nodes.some((node: any) => String(node.value || '').includes('EXCLUDED_PRIVATE_VALUE'))).toBe(false);
      await expect(f.fill(row, 'Must not write')).rejects.toThrow(type === 'password' ? 'stale_document' : 'unsupported_action');
      expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toHaveLength(0);
    }
  });

  test('the supported native INPUT types retain their native-value capability under inherited editing', async () => {
    for (const type of ['text', 'search', 'email', 'url', 'tel', 'number', 'date', 'datetime-local', 'month', 'week', 'time', 'color']) {
      const f = nestedField('INPUT', { type });
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'Native field');
      expect(row.isEditable).toBe(true); expect(row.value).toBe('Before value');
      expect((await f.fill(row, 'After value')).dispatched).toBe(true); expect(f.field.valueWrites).toEqual(['After value']);
    }
  });

  test('ordinary contenteditable elements still use rendered text and the exact content setter', async () => {
    const f = fixture(null), field = new f.Node('DIV', { contenteditable: 'true', 'aria-label': 'Editable body' }, 'Before text');
    f.document.body.append(field); f.document.elementFromPoint = () => field;
    const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'Editable body');
    expect(row.value).toBe('Before text'); expect(row.isEditable).toBe(true);
    expect((await f.fill(row, 'After text')).dispatched).toBe(true);
    expect(field.textContent).toBe('After text'); expect(field.valueWrites).toEqual([]);
    expect(field.events.map((event: any) => event.type)).toEqual(['input', 'change']);
  });

  test('native value, readonly, disabled, visibility, parent, identity and obstruction changes still reject before writing', async () => {
    for (const drift of ['value', 'readonly', 'disabled', 'hidden', 'parent', 'replaced', 'obstructed']) {
      const f = nestedField('INPUT');
      const row = (await f.run({ operation: 'observe' })).nodes.find((node: any) => node.name === 'Native field');
      if (drift === 'value') f.field.values.value = 'Changed native value';
      else if (drift === 'readonly') f.field.values.readonly = '';
      else if (drift === 'disabled') f.field.disabled = true;
      else if (drift === 'hidden') f.wrapper.values.hidden = '';
      else if (drift === 'parent') { f.wrapper.children = []; f.document.body.append(f.field); }
      else if (drift === 'replaced') f.wrapper.replaceChildren(new f.Node('INPUT', { 'aria-label': 'Native field', value: 'Before value' }));
      else f.document.elementFromPoint = () => f.wrapper;
      await expect(f.fill(row, 'Must not write')).rejects.toThrow(drift === 'obstructed' ? 'element_obstructed' : 'element_changed');
      expect(f.field.valueWrites).toEqual([]); expect(f.field.events).toHaveLength(0);
    }
  });
});

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

  function panelBeforeCompetingForm(dialog: boolean, panelFirst = true) {
    const f = fixture(null), background = new f.Node('FORM');
    for (let index = 0; index < 300; index++)
      background.append(new f.Node('P', {}, `Synthetic record ${index}: ${'x'.repeat(1000)}`));
    const panel = new f.Node('DIV', { 'aria-label': 'New message', ...(dialog ? { role: 'dialog' } : {}) });
    const header = new f.Node('DIV'), actions = new f.Node('DIV');
    const heading = new f.Node('H2', {}, 'New message'), fullscreen = new f.Node('BUTTON', {}, 'Full screen');
    const close = new f.Node('BUTTON', {}, 'Save & close');
    actions.append(fullscreen, close); header.append(heading, actions); panel.append(header);
    f.document.body.append(...(panelFirst ? [panel, background] : [background, panel]));
    f.document.elementFromPoint = () => fullscreen;
    return { ...f, panel, header, actions, heading, fullscreen, close, background };
  }

  for (const dialog of [false, true]) for (const panelFirst of [false, true]) {
    test(`nested ${dialog ? 'dialog' : 'named panel'} controls survive ${panelFirst ? 'later' : 'earlier'} competing FORM background`, async () => {
      const f = panelBeforeCompetingForm(dialog, panelFirst), result = await f.run({ operation: 'observe' });
      const panel = result.nodes.find((node: any) => node.name === 'New message' && node.role === (dialog ? 'dialog' : 'group'));
      expect(panel).toBeDefined(); expect(panel.isDOMClickable).toBe(false); expect(panel.isEditable).toBe(false);
      expect(panel.childNodeIDs.map((id: string) => result.nodes.find((node: any) => node.nodeID === id).name))
        .toEqual(['New message', 'Full screen', 'Save & close']);
      for (const name of ['Full screen', 'Save & close']) {
        const control = result.nodes.find((node: any) => node.name === name);
        expect(control.role).toBe('button'); expect(control.parentNodeID).toBe(panel.nodeID);
      }
      expect(result.nodes.some((node: any) => node.name.startsWith('Synthetic record '))).toBe(true);
      expect(result.nodes.some((node: any) => node.isEditable || node.name === 'Send')).toBe(false);
      expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.stopReason).toBe('byte_budget');
      expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
      expect(result.captureDiagnostics.visited).toBeLessThanOrEqual(20_001); expect(result.nodes.length).toBeLessThanOrEqual(3_000);
      for (const [index, node] of result.nodes.entries())
        if (node.parentNodeID) expect(result.nodes.findIndex((parent: any) => parent.nodeID === node.parentNodeID)).toBeLessThan(index);
      expect(new Set(result.nodes.map((node: any) => node.nodeID)).size).toBe(result.nodes.length);
      expect(f.fullscreen.clicks + f.close.clicks).toBe(0);
    });
  }

  for (const dialog of [false, true]) {
    test(`expanded ${dialog ? 'dialog' : 'named panel'} keeps fields and Send before later FORM background without input`, async () => {
      const f = panelBeforeCompetingForm(dialog);
      // Model the rendered result of expansion without dispatching an input.
      for (let index = 0; index < 100; index++) f.panel.append(new f.Node('SPAN', {}, `Visible panel detail ${index}`));
      const to = new f.Node('INPUT', { type: 'email', 'aria-label': 'Recipients' });
      const subject = new f.Node('INPUT', { 'aria-label': 'Subject' });
      const body = new f.Node('DIV', { contenteditable: 'true', 'aria-label': 'Message body' });
      const send = new f.Node('BUTTON', {}, 'Send');
      const footer = new f.Node('DIV'), footerInner = new f.Node('DIV'), footerControls = new f.Node('DIV');
      footerControls.append(to, subject, body, send); footerInner.append(footerControls); footer.append(footerInner); f.panel.append(footer);
      const result = await f.run({ operation: 'observe' });
      expect(result.nodes.filter((node: any) => node.isEditable).map((node: any) => node.name))
        .toEqual(['Recipients', 'Subject', 'Message body']);
      expect(result.nodes.find((node: any) => node.name === 'Send')).toBeDefined();
      expect(result.nodes.find((node: any) => node.name === 'Send').isDOMClickable).toBe(true);
      expect(result.nodes.findIndex((node: any) => node.name === 'Send'))
        .toBeLessThan(result.nodes.findIndex((node: any) => node.name.startsWith('Synthetic record ')));
      expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
      expect(f.document.activeElement).toBeNull(); expect(f.fullscreen.clicks + f.close.clicks + send.clicks).toBe(0);
      expect(to.valueWrites.concat(subject.valueWrites, body.valueWrites)).toEqual([]);
    });
  }

  test('native form controls survive the ordinary descendants of a later form', async () => {
    const f = panelBeforeCompetingForm(false), form = new f.Node('FORM', { 'aria-label': 'New message' });
    const to = new f.Node('INPUT', { type: 'email', 'aria-label': 'Recipients' });
    const subject = new f.Node('INPUT', { 'aria-label': 'Subject' });
    const body = new f.Node('TEXTAREA', { 'aria-label': 'Message body' });
    const send = new f.Node('BUTTON', {}, 'Send'); form.append(to, subject, body, send);
    f.document.body.replaceChildren(form, f.background); f.background.connected = true;
    const result = await f.run({ operation: 'observe' });
    expect(result.nodes.filter((node: any) => node.isEditable).map((node: any) => node.name))
      .toEqual(['Recipients', 'Subject', 'Message body']);
    expect(result.nodes.find((node: any) => node.name === 'Send')).toBeDefined();
      expect(result.nodes.find((node: any) => node.name === 'Send').isDOMClickable).toBe(true);
    expect(result.nodes.find((node: any) => node.role === 'form' && node.name === 'New message')).toBeDefined();
    expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
    expect(to.valueWrites.concat(subject.valueWrites, body.valueWrites)).toEqual([]); expect(send.clicks).toBe(0);
  });

  test('sampled panel priority preserves hidden, secure, disabled and stale-reference guards', async () => {
    for (const dialog of [false, true]) for (const change of ['hidden', 'disabled', 'replaced', 'parent', 'obstructed']) {
      const f = panelBeforeCompetingForm(dialog);
      f.panel.append(new f.Node('INPUT', { type: 'password', value: 'PRIVATE_PANEL_SECRET' }));
      if (change === 'hidden') f.panel.values['aria-hidden'] = 'true';
      if (change === 'disabled') f.fullscreen.values.disabled = '';
      const result = await f.run({ operation: 'observe' });
      expect(JSON.stringify(result)).not.toContain('PRIVATE_PANEL_SECRET');
      const control = result.nodes.find((node: any) => node.name === 'Full screen');
      if (change === 'hidden') expect(control).toBeUndefined();
      else {
        expect(control).toBeDefined();
        if (change === 'disabled') { expect(control.isDisabled).toBe(true); }
        if (change === 'replaced') f.actions.replaceChildren(new f.Node('BUTTON', {}, 'Full screen'));
        if (change === 'parent') { f.actions.children = f.actions.children.filter(child => child !== f.fullscreen); f.document.body.append(f.fullscreen); }
        if (change === 'obstructed') f.document.elementFromPoint = () => f.close;
        await expect(f.press(control)).rejects.toThrow(change === 'obstructed' ? 'element_obstructed'
          : change === 'disabled' ? 'stale_document' : 'element_changed');
      }
      expect(f.fullscreen.clicks + f.close.clicks).toBe(0);
    }
  });

  test('large named applications retain sampled controls without promoting their ordinary inbox subtree', async () => {
    const f = panelBeforeCompetingForm(false);
    const application = new f.Node('DIV', { 'aria-label': 'Synthetic application' });
    f.document.body.replaceChildren(application); application.append(f.background, f.panel);
    f.background.connected = true; f.panel.connected = true;
    const result = await f.run({ operation: 'observe' }), scheduling = result.captureDiagnostics.scheduling;
    expect(result.nodes.some((node: any) => node.name === 'Full screen')).toBe(true);
    expect(result.nodes.some((node: any) => node.name.startsWith('Synthetic record '))).toBe(true);
    expect(scheduling.emittedByPriority.slice(0, 3).reduce((sum: number, count: number) => sum + count, 0)).toBeLessThan(20);
    expect(scheduling.emittedByPriority[3]).toBeGreaterThan(20);
    expect(scheduling.partialPanels).toBeGreaterThan(0); expect(scheduling.discoverySlots).toBeLessThanOrEqual(4096);
    expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.stopReason).toBe('byte_budget');
    expect(f.fullscreen.clicks + f.close.clicks).toBe(0);
  });

  test('repeated large named candidates share the slot cap while a later observed panel stays discoverable', async () => {
    const f = panelBeforeCompetingForm(false);
    const candidates = new f.Node('DIV');
    for (let index = 0; index < 100; index++) {
      const candidate = new f.Node('DIV', { 'aria-label': 'Synthetic candidate' });
      for (let child = 0; child < 80; child++) candidate.append(new f.Node('SPAN', {}, 'Background detail'));
      candidate.append(new f.Node('BUTTON', {}, 'Background action')); candidates.append(candidate);
    }
    f.document.body.replaceChildren(candidates, f.background, f.panel);
    f.background.connected = true; f.panel.connected = true;
    const result = await f.run({ operation: 'observe' }), scheduling = result.captureDiagnostics.scheduling;
    expect(result.nodes.some((node: any) => node.name === 'Full screen')).toBe(true);
    expect(scheduling.panelProbes).toBeGreaterThan(2); expect(scheduling.partialPanels).toBeGreaterThan(1);
    expect(scheduling.discoverySlots).toBe(4096);
    expect(scheduling.partialPanels).toBeLessThanOrEqual(scheduling.panelProbes);
    expect(scheduling.controlsEmitted).toBeLessThanOrEqual(scheduling.controlsPrioritized);
    expect(scheduling.controlsPrioritized).toBeLessThanOrEqual(scheduling.controlsVisible);
    expect(scheduling.controlsVisible).toBeLessThanOrEqual(scheduling.controlsSeen);
    expect(scheduling.controlsSeen).toBeLessThanOrEqual(4096);
    expect(scheduling.emittedByPriority.reduce((sum: number, count: number) => sum + count, 0)).toBe(result.nodes.length);
    expect(result.sourceTruncated).toBe(true); expect(result.captureDiagnostics.estimatedBytes).toBeLessThan(230_000);
    expect(f.fullscreen.clicks + f.close.clicks).toBe(0);
    expect(JSON.stringify(scheduling)).not.toMatch(/Synthetic|Background|Full screen/);
  });

  test('capture scheduling diagnostics stay finite when pending fanout exceeds the visited budget', async () => {
    const f = fixture(null), comments = Array.from({ length: 100_000 }, () => ({ nodeType: 8, parentElement: f.document.body }));
    Object.defineProperty(f.document.body, 'childNodes', { get: () => comments });
    const result = await f.run({ operation: 'observe', awaitSemanticReadiness: false }), scheduling = result.captureDiagnostics.scheduling;
    expect(result.captureDiagnostics.stopReason).toBe('visited_limit'); expect(result.sourceTruncated).toBe(true);
    expect(scheduling.discoverySlots).toBe(4096);
    expect(scheduling.pendingByPriority).toEqual([0, 0, 0, 20001]); expect(scheduling.pendingClipped).toBe(true);
    expect(scheduling.emittedByPriority).toEqual([0, 0, 0, 0]);
    expect(Object.keys(scheduling).sort()).toEqual(['controlsEmitted', 'controlsPrioritized', 'controlsSeen', 'controlsVisible',
      'discoverySlots', 'emittedByPriority', 'panelProbes', 'partialPanels', 'pendingByPriority', 'pendingClipped'].sort());
  });

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
    let captureStarted = false, discoverySlots = 0, dialogSlots = 0;
    await f.run({ operation: 'observe' });
    const map = (f.state as any).__computaBrowserControlV1.nodes;
    map.clear = () => { captureStarted = true; Map.prototype.clear.call(map); };
    Object.defineProperty(f.document.body, 'childNodes', { get() {
      return new Proxy(children, { get(target, property, receiver) {
        if (!captureStarted && typeof property === 'string' && /^\d+$/.test(property)) discoverySlots++;
        return Reflect.get(target, property, receiver);
      } });
    } });
    const dialogChildren = dialog.childNodes;
    Object.defineProperty(dialog, 'childNodes', { get() {
      return new Proxy(dialogChildren, { get(target, property, receiver) {
        if (!captureStarted && typeof property === 'string' && /^\d+$/.test(property)) dialogSlots++;
        return Reflect.get(target, property, receiver);
      } });
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
