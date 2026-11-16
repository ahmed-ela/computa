import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

export const grokFixtureHTMLPath = new URL('./fixtures/grok-private-chat.html', import.meta.url);
export const grokOwner = 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30';
export const grokGeneration = 'b60fcab5-e5a2-4f6b-a03f-650ee9a714a2';
export const grokMarker = '23b7752b-6a64-4b88-b886-f0d0584ca9de';
export const grokChoice = { key: 'Fast', label: 'Fast' };
export const grokPrompt = 'Return a synthetic marker.\n\nComputa session marker: ' + grokMarker;
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

export function grokFixture() {
  let currentHit: any = null, obstructed = false;
  const document: any = { URL: 'https://grok.com/', activeElement: null, insertCommandCount: 0 };
  const selection: any = { anchorNode: null, focusNode: null, isCollapsed: false,
    removeAllRanges() { this.anchorNode = this.focusNode = null; this.isCollapsed = false; },
    addRange(range: any) { this.anchorNode = this.focusNode = range.container; this.isCollapsed = range.collapsed; } };
  class Node extends Element {
    onclick: any; oninput: any;
    rect = { left: 0, top: 0, width: 100, height: 30 };
    setAttribute(name: string, value: string) { this.values[name] = value; }
    removeAttribute(name: string) { delete this.values[name]; }
    hasAttribute(name: string) { return Object.hasOwn(this.values, name); }
    get textContent() { return super.textContent; }
    set textContent(value: string) { this.replaceChildren(); this.text = value; }
    remove() {
      if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this);
      this.parentElement = null; this.connected = false;
    }
    focus() { document.activeElement = this; this.onFocus?.(); }
    click() { super.click(); this.onclick?.({ preventDefault() {} }); }
    getBoundingClientRect() { currentHit = this; return { ...this.rect }; }
  }
  const html = new Node('HTML'), body = new Node('BODY'); html.append(body);
  Object.assign(document, { documentElement: html, body,
    createElement: (tag: string) => new Node(tag.toUpperCase()),
    querySelectorAll: (selector: string) => html.querySelectorAll(selector),
    elementFromPoint: () => obstructed ? body : currentHit,
    createRange: () => ({ container: null, collapsed: false,
      selectNodeContents(node: any) { this.container = node; }, collapse() { this.collapsed = true; } }),
    execCommand: (command: string, _ui: boolean, text: string) => {
      document.insertCommandCount++;
      if (command !== 'insertText' || !document.activeElement || selection.isCollapsed !== true
        || !document.activeElement.contains(selection.anchorNode) || !document.activeElement.contains(selection.focusNode)) return false;
      document.activeElement.textContent = text; document.activeElement.oninput?.(); return true;
    } });
  const posted: any[] = [], observers: any[] = [];
  const window: any = { innerWidth: 1024, innerHeight: 768, getSelection: () => selection,
    webkit: { messageHandlers: { computaChatGPTSignal: { postMessage: (value: any) => posted.push(value) } } } };
  window.top = window;
  new Function('document', 'window', readFileSync(grokFixtureHTMLPath, 'utf8').split('<script>')[1].split('</script>')[0])(document, window);
  const world: Record<string, any> = {}, location = { origin: 'https://grok.com' };
  const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/grok.js', import.meta.url), 'utf8');
  const execute = new AsyncFunction('input', 'document', 'window', 'location', 'getComputedStyle', 'MutationObserver', 'globalThis', 'crypto', source);
  let digestHook: (() => void) | null = null, fingerprint: string | null = null, submitted = false, modelVerified = false;
  const run = async (action = 'inspect', overrides: any = {}, adopt = true) => {
    const result = await execute({ provider: 'grok', action, expectedURL: document.URL, ownerToken: grokOwner,
      documentGeneration: grokGeneration, bindOwner: true, expectedModelChoice: modelVerified ? grokChoice : null,
      ...(action === 'selectModel' ? { modelChoice: grokChoice } : {}),
      expectedUserCounts: submitted ? fingerprint ? [1] : [0, 1] : [0], expectedFirstUserMarker: grokMarker,
      expectedFirstUserFingerprint: fingerprint, allowFirstUserBinding: submitted && !fingerprint,
      ...overrides }, document, window, location,
      (node: Node) => {
        const inline = Object.fromEntries((node.values.style || '').split(';').filter(Boolean).map(declaration => {
          const separator = declaration.indexOf(':');
          return [declaration.slice(0, separator).trim(), declaration.slice(separator + 1).replace(/!important\s*$/, '').trim()];
        }));
        return { visibility: node.values.visibility || inline.visibility || 'visible',
          display: node.closest('[hidden]') ? 'none' : inline.display || 'block',
          position: inline.position || 'static', height: inline.height || '30px', zIndex: inline['z-index'] || 'auto' };
      },
      class {
        records: any[] = [];
        constructor(public callback: any) { observers.push(this); }
        observe() {} disconnect() {}
        takeRecords() { const records = this.records; this.records = []; return records; }
      }, world, { subtle: { digest: async (algorithm: string, data: Uint8Array) => {
        const digest = await crypto.subtle.digest(algorithm, data); const hook = digestHook; digestHook = null; hook?.(); return digest;
      } } });
    if (adopt && result.submitted) submitted = true;
    if (adopt && result.selected && result.modelEvidence) modelVerified = true;
    if (adopt && result.firstUserVerified) fingerprint = result.firstUserFingerprint;
    return result;
  };
  const select = async () => {
    let result: any;
    for (let step = 0; step < 5; step++) { result = await run('selectModel'); if (!result.pending) return result; }
    return result;
  };
  const prepare = async (prompt = grokPrompt) => {
    const selected = await select(); if (selected.error) return selected;
    const enabled = await run('enableTemporary'); if (enabled.error) return enabled;
    const ready = await run('prepare'); if (ready.error) return ready;
    return run('insert', { prompt });
  };
  return { f: window.grokFixture, document, window, location, world, html, body, Node, run, select, prepare, posted, observers, selection,
    get fingerprint() { return fingerprint; }, blockHit: (value: boolean) => { obstructed = value; },
    onDigest: (callback: () => void) => { digestHook = callback; },
    submit: async (prompt = grokPrompt) => {
      const inserted = await prepare(prompt); if (inserted.error) return inserted;
      const ready = await run('sendReady', { prompt }); if (!ready.sendReady) return ready;
      return run('submit', { prompt });
    } };
}
