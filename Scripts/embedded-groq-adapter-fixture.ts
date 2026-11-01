import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

export const groqFixtureHTMLPath = new URL('./fixtures/groq-chat.html', import.meta.url);
export const groqOwner = 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30';
export const groqGeneration = 'b60fcab5-e5a2-4f6b-a03f-650ee9a714a2';
export const groqMarker = '23b7752b-6a64-4b88-b886-f0d0584ca9de';
export const groqChoice = { key: 'qwen/qwen3.8-27b', label: 'Qwen/Qwen3.8-27B' };
export const groqPrompt = 'Return only a synthetic marker.\n\nComputa session marker: ' + groqMarker;
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

export function groqFixture(choice = groqChoice, options: { root?: boolean } = {}) {
  let currentHit: any = null, obstructed = false;
  const hitQueries: { x: number; y: number; node: any }[] = [];
  const document: any = { URL: 'https://chat.groq.com/' + (options.root ? '' : '?model=' + choice.key), activeElement: null };
  class Node extends Element {
    onclick: any; onkeydown: any; oninput: any;
    rect = { left: 0, top: 0, width: 100, height: 30 };
    setAttribute(name: string, value: string) { this.values[name] = value; }
    removeAttribute(name: string) { delete this.values[name]; }
    get textContent() { return super.textContent; }
    set textContent(value: string) { this.replaceChildren(); this.text = value; }
    remove() {
      if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this);
      this.parentElement = null; this.connected = false;
    }
    focus() { document.activeElement = this; this.onFocus?.(); }
    click() { super.click(); this.onclick?.({ preventDefault() {} }); }
    dispatchEvent(event: any) {
      super.dispatchEvent(event);
      if (event.type === 'keydown') this.onkeydown?.(event);
      if (event.type === 'input') this.oninput?.(event);
      return true;
    }
    getBoundingClientRect() { currentHit = this; return { ...this.rect }; }
  }
  class Textarea extends Node {
    private stored = '';
    get value() { return this.stored; }
    set value(value: string) { this.stored = value; }
  }
  const html = new Node('HTML'), body = new Node('BODY'); html.append(body);
  Object.assign(document, { documentElement: html, body,
    createElement: (tag: string) => tag === 'textarea' ? new Textarea('TEXTAREA') : new Node(tag.toUpperCase()),
    querySelectorAll: (selector: string) => html.querySelectorAll(selector),
    elementFromPoint: (x: number, y: number) => {
      hitQueries.push({ x, y, node: currentHit });
      if (![x, y].every(Number.isFinite) || x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) return null;
      if (obstructed) return body;
      const r = currentHit?.rect;
      return r && x >= r.left && x < r.left + r.width && y >= r.top && y < r.top + r.height ? currentHit : null;
    } });
  const posted: any[] = [], observers: any[] = [];
  const window: any = { innerWidth: 1024, innerHeight: 768,
    history: { replaceState: (_state: any, _title: any, path: string) => { document.URL = new URL(path, document.URL).href; } },
    webkit: { messageHandlers: { computaChatGPTSignal: { postMessage: (value: any) => posted.push(value) } } },
    KeyboardEvent: class { constructor(public type: string, options: any) { Object.assign(this, options); } } };
  window.top = window;
  const htmlSource = readFileSync(groqFixtureHTMLPath, 'utf8');
  const script = htmlSource.split('<script>')[1].split('</script>')[0];
  new Function('document', 'window', script)(document, window);
  const world: Record<string, any> = {}, location = { origin: 'https://chat.groq.com' };
  const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq.js', import.meta.url), 'utf8');
  const execute = new AsyncFunction('input', 'document', 'window', 'location', 'getComputedStyle', 'MutationObserver',
    'globalThis', 'crypto', 'HTMLTextAreaElement', 'InputEvent', source);
  let digestHook: (() => void) | null = null, fingerprint: string | null = null, submitted = false, modelVerified = false;
  const run = async (action = 'inspect', overrides: any = {}, adopt = true) => {
    const result = await execute({ provider: 'groq', action, expectedURL: document.URL, ownerToken: groqOwner,
      documentGeneration: groqGeneration, bindOwner: true, expectedModelChoice: modelVerified ? choice : null,
      ...(action === 'selectModel' ? { modelChoice: choice } : {}),
      expectedUserCounts: submitted ? fingerprint ? [1] : [0, 1] : [0], expectedFirstUserMarker: groqMarker,
      expectedFirstUserFingerprint: fingerprint, allowFirstUserBinding: submitted && !fingerprint,
      ...overrides }, document, window, location,
      (node: Node) => ({ visibility: node.values.visibility || 'visible', display: node.closest('[hidden]') ? 'none' : 'block' }),
      class { constructor(callback: any) { observers.push(callback); } observe() {} }, world,
      { subtle: { digest: async (algorithm: string, data: Uint8Array) => {
        const digest = await crypto.subtle.digest(algorithm, data); const hook = digestHook; digestHook = null; hook?.(); return digest;
      } } }, Textarea, class { constructor(public type: string, options: any) { Object.assign(this, options); } });
    if (adopt && result.submitted) submitted = true;
    if (adopt && result.selected && result.modelEvidence) modelVerified = true;
    if (adopt && result.firstUserVerified) fingerprint = result.firstUserFingerprint;
    return result;
  };
  const select = async () => {
    let result: any;
    for (let i = 0; i < 4; i++) { result = await run('selectModel'); if (!result.pending) return result; }
    return result;
  };
  return { f: window.groqFixture, document, window, location, world, html, body, Node, Textarea, run, select, posted, observers, hitQueries,
    get fingerprint() { return fingerprint; }, blockHit: (value: boolean) => { obstructed = value; },
    onDigest: (callback: () => void) => { digestHook = callback; },
    submit: async (prompt = groqPrompt) => {
      await select(); await run('prepare'); await run('insert', { prompt });
      return run('submit', { prompt });
    } };
}
