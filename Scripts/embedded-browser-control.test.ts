import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/browser-control.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function fixture(target: string) {
  class Node extends Element {
    get href() { return this.values.href || ''; }
    get target() { return this.values.target || ''; }
    hasAttribute(name: string) { return this.values[name] !== undefined; }
    scrollIntoView() {}
    getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 20 }; }
  }
  const body = new Node('BODY'), link = new Node('A', {
    href: 'https://example.test/sign-in?return=%2Fmail%2F&literal=A-B', target,
  }, 'Sign in');
  body.append(link);
  const document = { body, documentElement: body, title: 'Popup fixture', elementFromPoint: () => link };
  const state = {}, location = { href: 'https://example.test/' };
  const execute = new AsyncFunction('input', 'globalThis', 'document', 'location', 'Node', 'getComputedStyle', 'TextEncoder', source);
  const run = (input: Record<string, unknown>) => execute({ documentToken: 'owned-document', ...input }, state, document, location,
    { TEXT_NODE: 3, ELEMENT_NODE: 1 }, () => ({ display: 'block', visibility: 'visible' }), TextEncoder);
  const press = (row: any) => run({ operation: 'press', nodeID: row.backendNodeID,
    expected: row, expectedURL: location.href });
  return { link, run, press };
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
