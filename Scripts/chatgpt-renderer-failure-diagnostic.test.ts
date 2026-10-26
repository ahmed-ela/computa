import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-renderer-failure-diagnostic.js', import.meta.url), 'utf8');
const execute = new Function('input', 'document', 'window', 'location', 'getComputedStyle', source);
const failureLabel = 'This response couldn’t load';
class Element {
  parentElement: Element | null = null;
  children: Element[] = [];
  connected = true;
  disabled = false;
  constructor(public tagName: string, public attributes: Record<string, string> = {}, public text = '') {}
  get nodeType() { return 1; }
  get isConnected(): boolean { return this.connected && (this.parentElement?.isConnected ?? true); }
  get childElementCount() { return this.children.length; }
  get firstElementChild() { return this.children[0] ?? null; }
  get childNodes(): any[] { return [...(this.text ? [{ nodeType: 3, textContent: this.text }] : []), ...this.children]; }
  get classList() { return (this.attributes.class ?? '').split(/\s+/).filter(Boolean); }
  get textContent(): string { return this.text + this.children.map(child => child.textContent).join(''); }
  getAttribute(name: string) { return this.attributes[name] ?? null; }
  getClientRects() { return this.isConnected && !this.closest('[hidden]') ? [{}] : []; }
  append(...nodes: Element[]) { for (const node of nodes) { node.parentElement = this; this.children.push(node); } }
  contains(node: Element): boolean { return node === this || this.children.some(child => child.contains(node)); }
  descendants(): Element[] { return this.children.flatMap(child => [child, ...child.descendants()]); }
  matches(selector: string) {
    return selector.split(',').some(raw => {
      const part = raw.trim(), tag = part.match(/^[A-Za-z][A-Za-z0-9-]*/)?.[0];
      if (tag && tag.toUpperCase() !== this.tagName) return false;
      if ([...part.split('[', 1)[0].matchAll(/\.([A-Za-z0-9_-]+)/g)].some(([, name]) => !this.classList.includes(name))) return false;
      return [...part.matchAll(/\[([^=\]]+)(?:="([^"]*)")?\]/g)].every(([, name, value]) =>
        value === undefined ? this.getAttribute(name) !== null : this.getAttribute(name) === value);
    });
  }
  querySelectorAll(selector: string) { return this.descendants().filter(node => node.matches(selector)); }
  querySelector(selector: string) { return this.querySelectorAll(selector)[0] ?? null; }
  closest(selector: string): Element | null {
    for (let node: Element | null = this; node; node = node.parentElement) if (node.matches(selector)) return node;
    return null;
  }
}
function fixture(pairedTurn = false) {
  const html = new Element('HTML'), main = new Element('MAIN'), turn = new Element('DIV');
  html.append(main); main.append(turn);
  const user = new Element('ARTICLE', { 'data-turn': 'user' }, 'Private fixture prompt never projected');
  const assistant = new Element('ARTICLE', { 'data-turn': 'assistant' });
  const body = new Element('DIV', { 'data-markdown-text-style': 'assistant-message' });
  const portal = new Element('DIV', { class: 'PortalBoundary-TFj9W2 Renderer-ojZscX' });
  const dil = new Element('DIV', { class: 'DilRenderer-tB76Jj DilResponseRoot-HfQrEh' });
  const leaf = new Element('DIV', {}, failureLabel), copy = new Element('BUTTON', { 'aria-label': 'Copy' }, 'Copy');
  dil.append(leaf); portal.append(dil); body.append(portal); assistant.append(body); turn.append(user, assistant);
  (pairedTurn ? turn : assistant).append(copy);
  const error = new Error('Timed out waiting for the DIL runner worker');
  error.stack = 'Error: secret\n at https://chatgpt.com/cdn/assets/async/469804.6f57f72d2c.js:215:38604\n at https://private.invalid/account?secret=yes:1:1';
  const snapshot = { error, tree: null, version: 1 };
  const lifecycle = { failureStage: 'worker_timeout', firstSnapshotSucceeded: false, frameReady: true, frameRecovering: false, workerReady: false };
  const runner: any = { snapshot, lifecycleSnapshot: lifecycle, disposed: false,
    frame: { iframe: {}, readyResolved: true, disposed: false, retired: true, retriedPreReadyFrame: false } };
  let calls = 0;
  runner.getSnapshot = () => { calls++; throw new Error('Never invoke runner methods'); };
  Object.defineProperty(runner, 'data', { get() { calls++; throw new Error('Never read data'); } });
  Object.defineProperty(runner, 'compiledDil', { get() { calls++; throw new Error('Never read program'); } });
  const hooks: any = { memoizedState: ['eventStore', [runner]], next: { memoizedState: snapshot, next: null } };
  const rendererFiber: any = { memoizedProps: { runner, onSnapshot: () => {}, errorFallback: {} }, memoizedState: hooks, return: null };
  const hostFiber: any = { memoizedProps: { children: failureLabel }, return: rendererFiber };
  Object.defineProperty(leaf, '__reactFiber$fixture', { value: hostFiber, configurable: true });
  const document = { URL: 'https://chatgpt.com/?temporary-chat=true', querySelectorAll: (selector: string) => html.querySelectorAll(selector) };
  const window: any = {}; window.top = window;
  const input = { expectedURL: document.URL, expectedResponseCount: 1, expectedUserCount: 1 };
  const run = (override: Record<string, unknown> = {}) => execute({ ...input, ...override }, document, window,
    { origin: 'https://chatgpt.com' }, () => ({ display: 'block', visibility: 'visible', opacity: '1' }));
  return { run, main, turn, body, leaf, copy, user, assistant, runner, snapshot, error, hooks, rendererFiber, hostFiber, document, window, calls: () => calls };
}

describe('private ChatGPT renderer failure diagnostic', () => {
  test('includes only current finite startup records and keeps an unarmed capture unchanged', () => {
    const f = fixture(); expect(f.run().startup).toBeUndefined();
    const event = { realm: 'worker', operation: 'harden_worker', phase: 'returned', artifactId: 'DrCNBd66',
      workerGeneration: 1, localTimeMs: 4, errorName: 'Error', payload: 'never retain' };
    const entry: any = { iframe: f.runner.frame.iframe, events: [event], dropped: 0 };
    const state: any = { version: 1, expiresAtUnixSeconds: Date.now() / 1000 + 100, frames: [entry] };
    Object.defineProperty(f.window, '__computaRendererStartupDiagnosticV1', { value: state });
    expect(f.run().startup).toEqual({ version: 1, events: [{ realm: 'worker', operation: 'harden_worker', phase: 'returned',
      artifactId: 'DrCNBd66', workerGeneration: 1, localTimeMs: 4, errorName: 'Error' }], dropped: 0 });
    entry.events = []; expect(f.run().startup).toEqual({ version: 1, events: [], dropped: 0 });
    entry.events = [event]; state.expiresAtUnixSeconds = Date.now() / 1000 - 1;
    expect(f.run().startup).toBeUndefined(); expect(f.run().status).toBe('captured');
  });
  test('rejects forged or accessor startup state without weakening the failure capture', () => {
    const f = fixture(); let reads = 0;
    const entry: any = { iframe: f.runner.frame.iframe,
      events: [{ realm: 'worker', operation: 'private payload', phase: 'returned' }], dropped: 0 };
    const state: any = { version: 1, expiresAtUnixSeconds: Date.now() / 1000 + 100, frames: [entry] };
    Object.defineProperty(f.window, '__computaRendererStartupDiagnosticV1', { value: state });
    expect(f.run().startup).toBeUndefined();
    const event: any = { realm: 'worker', operation: 'worker_ready', phase: 'sent' };
    Object.defineProperty(event, 'artifactId', { get() { reads++; return 'secret'; } });
    entry.events = [event]; expect(f.run().startup.events).toEqual([{ realm: 'worker', operation: 'worker_ready', phase: 'sent' }]);
    Object.defineProperty(event, 'realm', { get() { reads++; return 'worker'; } });
    expect(f.run().startup).toBeUndefined(); expect(reads).toBe(0); expect(f.run().status).toBe('captured');
  });
  test('projects only the exact failed frame and rejects duplicate frame entries', () => {
    const f = fixture();
    const entry = { iframe: f.runner.frame.iframe, events: [{ realm: 'worker', operation: 'runner_create', phase: 'received', reason: 'control_unavailable' }], dropped: 2 };
    const state: any = { version: 1, expiresAtUnixSeconds: Date.now() / 1000 + 100, frames: [
      { iframe: {}, events: [{ realm: 'worker', operation: 'worker_ready', phase: 'sent' }], dropped: 0 }, entry] };
    Object.defineProperty(f.window, '__computaRendererStartupDiagnosticV1', { value: state });
    expect(f.run().startup).toEqual({ version: 1, events: entry.events, dropped: 2 });
    state.frames = [state.frames[0]]; expect(f.run().startup).toEqual({ version: 1, events: [], dropped: 0 });
    state.saturated = true; expect(f.run().startup).toBeUndefined(); state.saturated = false;
    state.frames = [entry, entry]; expect(f.run().startup).toBeUndefined(); expect(f.run().status).toBe('captured');
  });
  test('captures actual committed failure for assistant and paired-turn Copy layouts without invoking site methods', () => {
    for (const paired of [false, true]) {
      const f = fixture(paired), result = f.run();
      expect(result.status).toBe('captured'); expect(result.lifecycle.failureStage).toBe('worker_timeout');
      expect(result.error.message).toBe('Timed out waiting for the DIL runner worker');
      expect(result.error.publicStack).toBe('https://chatgpt.com/cdn/assets/async/469804.6f57f72d2c.js:215:38604');
      expect(result.error.name).toBe('Error'); expect(result.snapshotVersion).toBe(1); expect(f.calls()).toBe(0);
      expect(JSON.stringify(result)).not.toContain('Private fixture prompt'); expect(JSON.stringify(result)).not.toContain('private.invalid');
      expect(new TextEncoder().encode(JSON.stringify(result)).length).toBeLessThan(8192);
    }
  });
  test('declines changed route, wrong counts, changed label, busy response, and missing scoped Copy', () => {
    for (const change of ['route', 'responses', 'users', 'label', 'busy', 'copy'] as const) {
      const f = fixture();
      if (change === 'route') f.document.URL += '#changed';
      if (change === 'label') f.leaf.text = 'This response could load';
      if (change === 'busy') f.main.append(new Element('BUTTON', { 'data-testid': 'stop-button' }));
      if (change === 'copy') f.copy.disabled = true;
      const result = f.run(change === 'responses' ? { expectedResponseCount: 2 } : change === 'users' ? { expectedUserCount: 2 } : {});
      expect(result.status).toBe('unavailable'); expect(f.calls()).toBe(0);
    }
  });
  test('requires the current runner snapshot to match committed hook state', () => {
    const f = fixture(); f.runner.snapshot = { ...f.snapshot };
    expect(f.run().reason).toBe('committed_runner_snapshot_missing');
  });
  test('never invokes accessor-backed runner, hook, or Error fields', () => {
    for (const target of ['runner', 'hook', 'error'] as const) {
      const f = fixture(); let getters = 0;
      const object = target === 'runner' ? f.rendererFiber.memoizedProps : target === 'hook' ? f.hooks.next : f.error;
      const field = target === 'runner' ? 'runner' : target === 'hook' ? 'memoizedState' : 'message';
      Object.defineProperty(object, field, { get() { getters++; throw new Error('Getter must not execute'); }, configurable: true });
      const result = f.run(); expect(getters).toBe(0);
      if (target === 'error') { expect(result.status).toBe('captured'); expect(result.error.message).toBeNull(); }
      else expect(result.status).toBe('unavailable');
    }
  });
  test('declines cyclic, ambiguous and missing page-world fiber state', () => {
    for (const variant of ['cycle', 'ambiguous', 'missing'] as const) {
      const f = fixture();
      if (variant === 'cycle') f.rendererFiber.return = f.hostFiber;
      if (variant === 'ambiguous') f.rendererFiber.return = { ...f.rendererFiber };
      if (variant === 'missing') delete (f.leaf as any).__reactFiber$fixture;
      expect(f.run().status).toBe('unavailable');
    }
  });
  test('bounds Unicode exception text and retains only whole public stack frames', () => {
    const f = fixture(); f.error.message = '🦀'.repeat(400);
    const frame = 'https://cdn.platform.openai.com/deployments/dil/v' + 'a'.repeat(80) + '/' + 'b'.repeat(120) + '.js:123:456';
    f.error.stack = Array(8).fill(frame).join('\n');
    const result = f.run();
    expect(result.status).toBe('captured'); expect(new TextEncoder().encode(result.error.message).length).toBeLessThanOrEqual(512);
    expect(result.error.messageTruncated).toBe(true); expect(result.error.publicStack).toBe(frame);
  });
  test('redacts nonpublic message URLs and records only proven module policy denial', () => {
    const f = fixture(); f.error.message = 'Load https://private.invalid/a?token=secret failed';
    f.runner.frame.moduleError = { __oaiDilFrame: true, kind: 'moduleError', protocolVersion: 14, policyDenied: true };
    const result = f.run(); expect(result.error.message).toBe('Load [address redacted] failed'); expect(result.frame.policyDenied).toBe(true);
    f.runner.frame.moduleError.protocolVersion = 15;
    expect(f.run().frame.policyDenied).toBeNull();
  });
});
