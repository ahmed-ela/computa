import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/browser-control.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function fixture(target: string | null) {
  class Node extends Element {
    get href() { return this.values.href || ''; }
    get target() { return this.values.target || ''; }
    hasAttribute(name: string) { return this.values[name] !== undefined; }
    scrollIntoView() {}
    getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 20 }; }
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
  const document = { body, documentElement: body, title: 'Outlook', readyState: 'complete', elementFromPoint: () => link,
    addEventListener(name: string, callback: Function) {
      if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name)!.add(callback);
    }, removeEventListener(name: string, callback: Function) { listeners.get(name)?.delete(callback); } };
  const state = {}, location = { href: 'https://example.test/' };
  const execute = new AsyncFunction('input', 'globalThis', 'document', 'location', 'Node', 'getComputedStyle', 'TextEncoder',
    'MutationObserver', 'setTimeout', 'clearTimeout', source);
  const run = (input: Record<string, unknown>) => execute({ documentToken: 'owned-document', timeoutMS: 10000, ...input }, state, document, location,
    { TEXT_NODE: 3, ELEMENT_NODE: 1 }, () => ({ display: 'block', visibility: 'visible' }), TextEncoder, Observer,
    (callback: Function, delay: number) => { timers.set(++timerID, { callback, delay }); return timerID; },
    (id: number) => timers.delete(id));
  const press = (row: any) => run({ operation: 'press', nodeID: row.backendNodeID,
    expected: row, expectedURL: location.href });
  return { link, run, press, document, timers, observers, listeners,
    appendText: (text: string) => document.body.append(new Node('P', {}, text)),
    appendControl: () => document.body.append(new Node('BUTTON', {}, 'Continue')),
    appendMetadata: () => document.body.append(new Node('MAIN', { 'aria-label': 'Outlook' })),
    mutate: () => observers.filter(observer => observer.active).forEach(observer => observer.callback()),
    event: (name: string) => listeners.get(name)?.forEach(callback => callback()),
    expire: () => [...timers.values()].forEach(timer => timer.callback()),
    replaceRoot: () => { document.body = new Node('BODY'); document.documentElement = document.body; },
  };
}

describe('built-in browser popup-only link capabilities', () => {
  test('ordinary same-tab anchors retain their observed press capability', async () => {
    for (const target of ['', '_self', '_top', '_parent', '_SELF']) {
      const f = fixture(target), read = await f.run({ operation: 'observe' });
      const link = read.nodes.find((row: any) => row.role === 'link');
      expect(link.isDOMClickable).toBe(true); expect(link.isPressUnsupported).toBe(false);
      expect(link.isDisabled).toBe(false);
      expect(await f.press(link)).toEqual({ dispatched: true, noReplay: true });
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

describe('bounded built-in semantic readiness', () => {
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
