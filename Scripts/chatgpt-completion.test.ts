import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-completion.js', import.meta.url), 'utf8');
const runtimeImport = 'import(runtimeURL)';
const runtimeURL = 'https://chatgpt.com/cdn/assets/633146.510c2d4c2a.js';
const runtimeResource = (name = runtimeURL) => ({ name, initiatorType: 'script', startTime: 1, responseEnd: 50, responseStatus: 200 });
const key = '__computaCompletion_' + 'a'.repeat(32);
const correlationID = '11111111-1111-4111-8111-111111111111';
const conversationID = '22222222-2222-4222-8222-222222222222';
const inputMessageID = '33333333-3333-4333-8333-333333333333';
const messageID = '44444444-4444-4444-8444-444444444444';
const systemID = '55555555-5555-4555-8555-555555555555';
const otherID = '66666666-6666-4666-8666-666666666666';
const inputText = 'Exact owned prompt é😀';
const hash = (text: string) => createHash('sha256').update(text).digest('hex');
const binding = () => ({ correlationID, sequence: 1, inputSHA256: hash(inputText),
  inputUTF8Bytes: new TextEncoder().encode(inputText).length, durationMs: 1000 });
const flush = async () => { await new Promise(resolve => setTimeout(resolve, 0)); };

function fixture(options: { unsupported?: boolean; delayedDigest?: boolean; sendLabelOnly?: boolean;
  resources?: any[]; observeResources?: boolean; moduleID?: string; configureRuntime?: (runtime: any) => void;
  loadRuntime?: () => Promise<unknown>; methodSource?: string; validatorName?: string } = {}) {
  let clock = 100, imports = 0, timerID = 0, throwOriginal: unknown = null;
  // Retain all wire packets; the original authority regressions deliberately
  // inspect only the unchanged terminal/invalidated schemas.
  const allPosts: any[] = [], posts: any[] = [], diagnostics: any[] = [];
  const timers = new Map<number, () => void>(), documentEvents = new Map<string, Function>();
  const windowEvents = new Map<string, Set<Function>>(), resourceObservers: ResourceObserver[] = [], observers: any[] = [], pendingDigests: { bytes: Uint8Array; resolve: Function; reject: Function }[] = [];
  const methodSource = options.methodSource ?? 'recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}';
  const O = new Function(options.validatorName ?? 'T', 'return class O {' + methodSource + '}')({
    safeParse(value: any) { if (throwOriginal) throw throwOriginal; return { success: !!value?.type, data: value }; },
  });
  const original = Object.getOwnPropertyDescriptor(O.prototype, 'recordCompletion')!;
  const exports = Object.defineProperty({}, 'c', { get: new Function('O', 'return ()=>O')(O), enumerable: true, configurable: false });
  const runtime = { __webpack_require__: { c: { [options.moduleID ?? 'jDdw']: { exports } } } };
  options.configureRuntime?.(runtime);
  const resources = options.resources ?? [runtimeResource()], importedURLs: string[] = [];
  const window: any = { webkit: { messageHandlers: { computaChatGPTCompletion: { postMessage(record: any) {
    allPosts.push(record); (record.kind === 'diagnostic' ? diagnostics : posts).push(record);
  } } } },
    addEventListener(name: string, listener: Function) { if (!windowEvents.has(name)) windowEvents.set(name, new Set()); windowEvents.get(name)!.add(listener); },
    removeEventListener(name: string, listener: Function) { windowEvents.get(name)?.delete(listener); if (!windowEvents.get(name)?.size) windowEvents.delete(name); } };
  window.top = window;
  const button: any = { isConnected: true, disabled: false, getClientRects: () => [{}], getAttribute: () => null,
    closest(selector: string) { return (options.sendLabelOnly ? selector.includes('button[aria-label="Send"]')
      : selector.startsWith('button[data-testid="send-button"]')) ? button : null; } };
  const document: any = { querySelectorAll: () => [button],
    addEventListener(name: string, listener: Function) { documentEvents.set(name, listener); },
    removeEventListener(name: string, listener: Function) { if (documentEvents.get(name) === listener) documentEvents.delete(name); } };
  const location = { origin: 'https://chatgpt.com', href: 'https://chatgpt.com/' };
  class Observer {
    active = false;
    constructor(readonly callback: Function) { observers.push(this); }
    observe() { this.active = true; }
    disconnect() { this.active = false; }
  }
  class ResourceObserver {
    active = false; pending: any = []; options: any;
    constructor(readonly callback: Function) { resourceObservers.push(this); }
    observe(options: any) { this.options = options; this.active = true; }
    disconnect() { this.active = false; }
    takeRecords() { const value = this.pending; this.pending = []; return value; }
    deliver(entries: any) { if (this.active) this.callback({ getEntries: () => entries }); }
  }
  const cryptoFixture = { subtle: { digest(_name: string, bytes: Uint8Array) {
    if (options.delayedDigest) return new Promise((resolve, reject) => pendingDigests.push({ bytes, resolve, reject }));
    return Promise.resolve(new Uint8Array(createHash('sha256').update(bytes).digest()).buffer);
  } } };
  const loadRuntime = (url: string) => { imports++; importedURLs.push(url); return options.loadRuntime ? options.loadRuntime()
    : Promise.resolve(options.unsupported ? {} : runtime); };
  expect(source.split(runtimeImport)).toHaveLength(2);
  const execute = new Function('window', 'document', 'location', 'performance', 'crypto', 'MutationObserver',
    'getComputedStyle', 'setTimeout', 'clearTimeout', 'loadRuntime', 'PerformanceObserver', source
      .replace('__COMPUTA_COMPLETION_CONFIG__', JSON.stringify({ key, handlerName: 'computaChatGPTCompletion' }))
      .replace(runtimeImport, 'loadRuntime(runtimeURL)'));
  execute(window, document, location, { now: () => clock, getEntriesByType: (type: string) => type === 'resource' ? resources : [] }, cryptoFixture, Observer, () => ({ visibility: 'visible' }),
    (callback: () => void) => { timers.set(++timerID, callback); return timerID; }, (id: number) => timers.delete(id), loadRuntime, options.observeResources ? ResourceObserver : undefined);
  const receiver = new O();
  return { window, document, button, location, allPosts, posts, diagnostics, timers, observers, resourceObservers, resources, importedURLs, runtime, imports: () => imports,
    api: window[key], O, receiver, original,
    send: () => documentEvents.get('click')?.({ target: button }),
    stopClick: () => documentEvents.get('click')?.({ target: { closest: (s: string) => s.includes('stop-button') ? {} : null } }),
    decode: (payload: any, instance = receiver) => instance.recordCompletion(payload),
    tick: (value: number) => { clock = 100 + value; }, mutate: () => observers.filter(o => o.active).forEach(o => o.callback()),
    pagehide: () => [...(windowEvents.get('pagehide') ?? [])].forEach(callback => callback()), throwOriginal: (error: unknown) => { throwOriginal = error; },
    resolveDigests: () => pendingDigests.splice(0).forEach(({ bytes, resolve }) => resolve(new Uint8Array(createHash('sha256').update(bytes).digest()).buffer)),
    rejectDigests: () => pendingDigests.splice(0).forEach(({ reject }) => reject(new Error('private digest error'))),
    listeners: () => documentEvents.size + [...windowEvents.values()].reduce((n, set) => n + set.size, 0),
  };
}
function input(text = inputText, extra: any = {}) {
  return { type: 'input_message', conversation_id: conversationID, input_message: {
    id: inputMessageID, author: { role: 'user' }, content: { content_type: 'text', parts: [text] } }, ...extra };
}
function system(parent: string | null = inputMessageID, id = systemID) {
  return { conversation_id: conversationID, message: { id, author: { role: 'system' }, metadata: { parent_id: parent } } };
}
function final(text = 'HI', extra: any = {}) {
  return { conversation_id: conversationID, message: { id: messageID, author: { role: 'assistant' },
    status: 'finished_successfully', channel: 'final', recipient: 'all', end_turn: true,
    content: { content_type: 'text', parts: [text] }, metadata: { parent_id: systemID, finish_details: { type: 'stop' } }, ...extra } };
}
const terminal = () => ({ type: 'message_stream_complete', conversation_id: conversationID });
async function ready(f: ReturnType<typeof fixture>) {
  expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send(); f.decode(input()); await flush();
}
function complete(f: ReturnType<typeof fixture>, text = 'HI') { f.decode(system()); f.decode(final(text)); f.decode(terminal()); }

describe('ChatGPT current-response completion admission', () => {
  test('exact decoder grammar permits only consistent distinct identifier renaming', () => {
    const declaration = source.match(/function completionMethodMatches\(source\) \{[\s\S]*?\n  \}/)?.[0];
    expect(declaration).toBeDefined();
    const matches = new Function('return (' + declaration + ')')();
    const method = (input: string, local: string, validator: string) =>
      `recordCompletion(${input}){let ${local}=${validator}.safeParse(${input});return ${local}.success&&"message_stream_complete"===${local}.data.type&&(this.messageStreamCompleted=!0),${input}}`;
    const original = method('e', 't', 'T');
    for (const names of [['e', 't', 'T'], ['e', 't', 'x'], ['payload', 'parsed', 'validator'], ['$input', '_parsed', '$schema']]) {
      expect(matches(method(names[0], names[1], names[2]))).toBe(true);
    }
    const rejected = [
      method('e', 'e', 'T'), method('e', 't', 'e'), method('e', 't', 't'),
      method('e', 't', 'x'.repeat(65)), method('é', 't', 'T'), method('\\u0065', 't', 'T'),
      original.replace('safeParse(e)', 'safeParse(payload)'), original.replace('t.success', 'other.success'),
      original.replace('t.data.type', 'other.data.type'), original.replace(',e}', ',t}'),
      original.replace('message_stream_complete', 'main_stream_complete'),
      original.replace('messageStreamCompleted', 'differentFlag'), original.replace('!0', '!1'),
      original.replace('safeParse(e)', 'safeParse(e.content)'), original.replace('safeParse(e)', 'parse(e)'),
      original.replace('let t=', 'const t='), original.replace('return t.success', 'sideEffect();return t.success'),
      original.replace(',e}', ',sideEffect(),e}'), original.replace('(e)', '(e,extra)'),
      original.replace('recordCompletion', 'otherMethod'), original.replace('.data.type', '?.data.type'),
      original.replace('"message_stream_complete"', "'message_stream_complete'"),
      ' ' + original, original + '\n', original + ';', original.replace('let t=', 'let  t='),
    ];
    for (const candidate of rejected) expect(matches(candidate)).toBe(false);
    for (const reserved of ['this', 'super', 'arguments', 'eval', 'await', 'yield', 'null', 'true', 'false', 'let', 'class', 'static']) {
      for (const candidate of [method(reserved, 't', 'T'), method('e', reserved, 'T'), method('e', 't', reserved)]) {
        expect(matches(candidate)).toBe(false);
      }
    }
  });

  test('old and renamed decoder bindings preserve terminal success, empty failure, return identity and original throws', async () => {
    for (const [input, local, validatorName] of [['e', 't', 'T'], ['e', 't', 'x'], ['payload', 'parsed', 'validator']]) {
      const methodSource = `recordCompletion(${input}){let ${local}=${validatorName}.safeParse(${input});return ${local}.success&&"message_stream_complete"===${local}.data.type&&(this.messageStreamCompleted=!0),${input}}`;
      const valid = fixture({ methodSource, validatorName }); await ready(valid);
      const unchanged = { type: 'metadata' }; expect(valid.decode(unchanged)).toBe(unchanged);
      complete(valid, 'EXACT FINAL');
      expect(valid.posts.map(p => p.kind)).toEqual(['terminal']); expect(valid.posts[0].text).toBe('EXACT FINAL');
      expect(valid.receiver.messageStreamCompleted).toBe(true);
      const error = new Error('original parser failure'); valid.throwOriginal(error);
      let caught: unknown; try { valid.decode(terminal()); } catch (value) { caught = value; }
      expect(caught).toBe(error); expect(valid.posts.map(p => p.kind)).toEqual(['terminal', 'invalidated']);
      expect(valid.O.prototype.recordCompletion).toBe(valid.original.value);

      const empty = fixture({ methodSource, validatorName }); await ready(empty);
      empty.decode(terminal()); empty.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
      expect(empty.posts.map(p => p.kind)).toEqual(['terminal_failure']);
      expect(empty.posts[0].reason).toBe('empty_stream'); expect(empty.posts[0].text).toBeUndefined();
      empty.api.stop(correlationID); expect(empty.O.prototype.recordCompletion).toBe(empty.original.value);
    }
  });

  test('renamed decoder bodies cannot relax method descriptors, name, arity or the approved export getter', async () => {
    const methodSource = 'recordCompletion(e){let t=x.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}';
    for (const mode of ['writable', 'configurable', 'enumerable', 'name', 'arity', 'getter'] as const) {
      const f = fixture({ methodSource, validatorName: 'x', configureRuntime(runtime) {
        const cached = runtime.__webpack_require__.c.jDdw, O = cached.exports.c;
        if (mode === 'getter') cached.exports = Object.defineProperty({}, 'c', {
          get: new Function('P', 'return ()=>P')(O), enumerable: true, configurable: false });
        else if (mode === 'name' || mode === 'arity') Object.defineProperty(O.prototype.recordCompletion,
          mode === 'name' ? 'name' : 'length', { value: mode === 'name' ? 'differentName' : 2 });
        else Object.defineProperty(O.prototype, 'recordCompletion', { [mode]: mode === 'enumerable' });
      } });
      expect(await f.api.arm(binding())).toEqual({ armed: false });
      expect(f.diagnostics[0].reason).toBe(mode === 'getter' ? 'runtime_getter_unavailable' : 'runtime_method_unsupported');
      expect(f.posts).toEqual([]); expect(f.listeners()).toBe(0);
    }
  });

  test('actual methods using receiver or implicit-arguments parsing are not validator binding renames', async () => {
    for (const validator of ['this', 'arguments']) {
      const methodSource = `recordCompletion(e){let t=${validator}.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}`;
      const f = fixture({ methodSource });
      expect(await f.api.arm(binding())).toEqual({ armed: false });
      expect(f.diagnostics[0].reason).toBe('runtime_method_unsupported');
      expect(f.O.prototype.recordCompletion).toBe(f.original.value);
      expect(f.posts).toEqual([]); expect(f.listeners()).toBe(0);
    }
  });

  test('the currently observed runtime and unique initialized decoder survive website asset and module ID changes', async () => {
    for (const moduleID of ['dd', 'jDdw', 'futureCachedModule']) {
      const currentURL = 'https://chatgpt.com/cdn/assets/633146.012345abcd.js';
      const f = fixture({ moduleID, resources: [runtimeResource(currentURL), runtimeResource(currentURL),
        runtimeResource('https://chatgpt.com/cdn/assets/87162.8221492420.js')] });
      await ready(f); complete(f);
      expect(f.importedURLs).toEqual([currentURL]);
      expect(f.posts[0]).toMatchObject({ kind: 'terminal', text: 'HI' });
      f.api.stop(correlationID);
      expect(f.O.prototype.recordCompletion).toBe(f.original.value);
    }
  });

  test('missing, ambiguous, incomplete, foreign and unrelated runtime observations never import a fallback', async () => {
    for (const resources of [[], [runtimeResource(), runtimeResource('https://chatgpt.com/cdn/assets/633146.012345abcd.js')],
      [{ ...runtimeResource(), initiatorType: 'fetch' }], [{ ...runtimeResource(), responseEnd: 0 }],
      [{ ...runtimeResource(), responseEnd: 101 }], [{ ...runtimeResource(), startTime: 51 }],
      [{ ...runtimeResource(), responseStatus: 404 }], [runtimeResource(runtimeURL + '?stale=1')],
      [runtimeResource(runtimeURL + '#fragment')], [runtimeResource(runtimeURL.replace('chatgpt.com', 'other.test'))],
      [runtimeResource(runtimeURL.replace('https:', 'http:'))], Array.from({ length: 4097 }, () => runtimeResource())]) {
      const f = fixture({ resources });
      expect(await f.api.arm(binding())).toEqual({ armed: false });
      expect(f.importedURLs).toEqual([]); expect(f.posts).toEqual([]);
      expect(f.O.prototype.recordCompletion).toBe(f.original.value);
      expect(f.diagnostics[0].reason).toBe('runtime_resources_unavailable');
    }
  });

  test('document-start link observations survive website timing clear and queued callback delivery', async () => {
    for (const queued of [false, true]) {
      const f = fixture({ observeResources: true, resources: [] });
      const observer = f.resourceObservers[0], record = { ...runtimeResource(), initiatorType: 'link' };
      expect(observer.options).toEqual({ type: 'resource', buffered: true });
      if (queued) observer.pending.push(record); else observer.deliver([record]);
      // The website global timing buffer no longer contains startup assets.
      f.resources.push(runtimeResource('https://chatgpt.com/cdn/assets/87162.8221492420.js'));
      await ready(f); complete(f); expect(f.importedURLs).toEqual([runtimeURL]);
      expect(f.posts[0]).toMatchObject({ kind: 'terminal', text: 'HI' });
      f.api.stop(correlationID); f.pagehide();
      expect(observer.active).toBe(false); expect(f.listeners()).toBe(0); expect(f.timers.size).toBe(0);
    }
  });

  test('the resource inventory copies only URLs and expires with its document instead of granting a new lease', async () => {
    const copied = fixture({ observeResources: true, resources: [] });
    const entry = { ...runtimeResource(), initiatorType: 'link' };
    copied.resourceObservers[0].deliver([entry]); entry.name = 'https://private.invalid/arbitrary';
    await ready(copied); expect(copied.importedURLs).toEqual([runtimeURL]); copied.api.stop(correlationID); copied.pagehide();
    for (const mode of ['expiry', 'pagehide']) {
      const f = fixture({ observeResources: true });
      if (mode === 'expiry') { f.tick(600001); [...f.timers.values()][0](); } else f.pagehide();
      expect(await f.api.arm(binding())).toEqual({ armed: false });
      expect(f.importedURLs).toEqual([]); expect(f.resourceObservers[0].active).toBe(false);
      expect(f.listeners()).toBe(0); expect(f.timers.size).toBe(0);
    }
  });

  test('observer ambiguity, malformed batches and finite inventory overflow fail closed without imports', async () => {
    for (const mode of ['ambiguous', 'malformed', 'throwing_entry', 'overflow']) {
      const f = fixture({ observeResources: true, resources: [] }), observer = f.resourceObservers[0];
      observer.deliver([{ ...runtimeResource(), initiatorType: 'link' }]);
      if (mode === 'ambiguous') observer.pending.push(runtimeResource('https://chatgpt.com/cdn/assets/633146.012345abcd.js'));
      if (mode === 'malformed') observer.pending = { unexpected: 'not read or retained' };
      if (mode === 'throwing_entry') observer.pending.push(Object.defineProperty({}, 'initiatorType', { get() { throw Error('private'); } }));
      if (mode === 'overflow') observer.pending.push(...Array.from({ length: 9 }, (_, i) => runtimeResource('https://chatgpt.com/cdn/assets/633146.' + String(i).padStart(10,'0') + '.js')));
      expect(await f.api.arm(binding())).toEqual({ armed: false }); expect(f.importedURLs).toEqual([]);
      expect(f.diagnostics[0].reason).toBe('runtime_resources_unavailable');
      expect(JSON.stringify(f.allPosts)).not.toContain('private'); f.pagehide();
    }
  });

  test('captured observer methods cannot be replaced and a late callback cannot revive an expired inventory', async () => {
    const f = fixture({ observeResources: true, resources: [] }), observer = f.resourceObservers[0];
    observer.pending.push({ ...runtimeResource(), initiatorType: 'link' });
    observer.takeRecords = () => { throw Error('replaced method must not run'); };
    await ready(f); expect(f.importedURLs).toEqual([runtimeURL]);
    f.api.stop(correlationID); f.pagehide();
    observer.callback({ getEntries: () => [runtimeResource()] });
    expect(await f.api.arm(binding())).toEqual({ armed: false });
    expect(f.importedURLs).toEqual([runtimeURL]); expect(f.listeners()).toBe(0); expect(f.timers.size).toBe(0);
  });

  test('runtime diagnostic stages distinguish import, cache and changed observation without response content', async () => {
    const rejected = fixture({ loadRuntime: async () => { throw Error('private network details'); } });
    expect(await rejected.api.arm(binding())).toEqual({ armed: false });
    expect(rejected.diagnostics[0].reason).toBe('runtime_import_failed');
    const unsupported = fixture({ unsupported: true }); expect(await unsupported.api.arm(binding())).toEqual({ armed: false });
    expect(unsupported.diagnostics[0].reason).toBe('runtime_cache_shape');
    expect(JSON.stringify(rejected.allPosts)).not.toContain('private');
  });

  test('a runtime observation changing across the import cannot install a decoder wrapper', async () => {
    let resolve!: (runtime: unknown) => void;
    const f = fixture({ loadRuntime: () => new Promise(value => { resolve = value; }) });
    const arming = f.api.arm(binding());
    f.resources.push(runtimeResource('https://chatgpt.com/cdn/assets/633146.012345abcd.js'));
    resolve(f.runtime);
    expect(await arming).toEqual({ armed: false });
    expect(f.importedURLs).toEqual([runtimeURL]); expect(f.listeners()).toBe(0);
    expect(f.diagnostics[0].reason).toBe('runtime_identity_changed');
    expect(f.O.prototype.recordCompletion).toBe(f.original.value);
  });

  test('a throwing approved getter cannot hide a unique initialized decoder or initialize one', async () => {
    for (const hasDecoder of [true, false]) {
      const f = fixture({ configureRuntime(runtime) {
        const partial = { exports: Object.defineProperty({}, 'c', {
          get: new Function('return ()=>O')(), enumerable: true, configurable: false }) };
        runtime.__webpack_require__.c = { partial, ...(hasDecoder ? runtime.__webpack_require__.c : {}) };
      } });
      expect(await f.api.arm(binding())).toEqual({ armed: hasDecoder });
      if (hasDecoder) { f.send(); f.decode(input()); await flush(); complete(f); expect(f.posts[0].kind).toBe('terminal'); }
      else expect(f.diagnostics[0].reason).toBe('runtime_getter_failed');
      f.api.stop(correlationID);
    }
  });

  test('cache discovery never invokes require, factories, cache accessors or unapproved export getters', async () => {
    let forbidden = 0;
    const reject = () => { forbidden++; throw new Error('must not execute'); };
    const f = fixture({ configureRuntime(runtime) {
      const cache = runtime.__webpack_require__.c;
      Object.defineProperty(cache, 'accessorEntry', { get: reject });
      cache.accessorExports = Object.defineProperty({}, 'exports', { get: reject });
      cache.unapprovedGetter = { exports: Object.defineProperty({}, 'c', { get: reject, enumerable: true }) };
      cache.nonDecoder = { exports: Object.defineProperty({}, 'c', {
        get: new Function('O', 'return ()=>O')(class Unrelated {}), enumerable: true }) };
      const require = Object.assign(reject, { c: cache, m: { uninitializedDecoder: reject } });
      runtime.__webpack_require__ = require;
    } });
    await ready(f); complete(f);
    expect(forbidden).toBe(0); expect(f.posts[0].kind).toBe('terminal');
    f.api.stop(correlationID);
  });

  test('cache-stage diagnostics distinguish missing proof without exposing source or invoking new getters', async () => {
    for (const mode of ['missing', 'nonplain', 'empty', 'unapproved', 'no_export', 'inspection_throw'] as const) {
      let forbidden = 0;
      const f = fixture({ configureRuntime(runtime) {
        const reject = () => { forbidden++; throw new Error('PRIVATE WEBSITE DATA'); };
        if (mode === 'missing') delete runtime.__webpack_require__.c;
        else if (mode === 'nonplain') runtime.__webpack_require__.c = [];
        else if (mode === 'empty') runtime.__webpack_require__.c = Object.create(null);
        else if (mode === 'unapproved') runtime.__webpack_require__.c = { PRIVATE_MODULE_ID: {
          exports: Object.defineProperty({}, 'c', { get: reject, enumerable: true, configurable: false }) } };
        else if (mode === 'no_export') runtime.__webpack_require__.c = { PRIVATE_MODULE_ID: { exports: {} } };
        else runtime.__webpack_require__.c = new Proxy({}, { ownKeys() { throw new Error('PRIVATE WEBSITE DATA'); } });
      } });
      expect(await f.api.arm(binding())).toEqual({ armed: false });
      const reason = { missing: 'runtime_cache_shape', nonplain: 'runtime_cache_shape', empty: 'runtime_cache_empty',
        unapproved: 'runtime_getter_unavailable', no_export: 'runtime_getter_unavailable',
        inspection_throw: 'runtime_cache_unsupported' }[mode];
      expect(f.allPosts).toEqual([{ version: 1, kind: 'diagnostic', correlationID, sequence: 1,
        inputSHA256: hash(inputText), reason, calls: 0, instances: 0 }]);
      expect(forbidden).toBe(0);
      expect(JSON.stringify(f.allPosts)).not.toContain('PRIVATE');
      expect(f.O.prototype.recordCompletion).toBe(f.original.value);
      expect(f.posts).toEqual([]); expect(f.listeners()).toBe(0); expect(f.timers.size).toBe(0);
      expect(f.importedURLs).toEqual([runtimeURL]);
    }
  });

  test('multiple distinct matching cached decoders, oversized cache and changed decoder source fail closed', async () => {
    for (const mode of ['ambiguous', 'oversized', 'changed', 'uninitialized'] as const) {
      let factoryCalls = 0;
      const f = fixture({ configureRuntime(runtime) {
        const cache = runtime.__webpack_require__.c;
        if (mode === 'ambiguous') {
          const O = new Function('T', 'return class O {recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}}')({ safeParse: () => ({ success: false }) });
          cache.second = { exports: Object.defineProperty({}, 'c', { get: new Function('O', 'return ()=>O')(O), enumerable: true }) };
        } else if (mode === 'oversized') {
          for (let index = 0; index < 16384; index++) cache['unrelated' + index] = { exports: {} };
        } else if (mode === 'changed') {
          Object.defineProperty(cache.jDdw.exports.c.prototype, 'recordCompletion', { value(e: unknown) { return e; }, configurable: true, writable: true });
        } else {
          delete cache.jDdw;
          runtime.__webpack_require__.m = { jDdw: () => { factoryCalls++; } };
        }
      } });
      expect(await f.api.arm(binding())).toEqual({ armed: false });
      expect(f.diagnostics[0].reason).toBe({ ambiguous: 'runtime_decoder_ambiguous', oversized: 'runtime_cache_limit',
        changed: 'runtime_method_unsupported', uninitialized: 'runtime_cache_empty' }[mode]);
      expect(factoryCalls).toBe(0); expect(f.posts).toEqual([]); expect(f.listeners()).toBe(0);
      expect(f.importedURLs).toEqual([runtimeURL]);
    }
  });

  test('a large initialized website cache is inspected within the finite budget without initializing unrelated modules', async () => {
    const f = fixture({ configureRuntime(runtime) {
      for (let index = 0; index < 9312; index++) runtime.__webpack_require__.c['unrelated' + index] = { exports: {} };
    } });
    await ready(f); complete(f);
    expect(f.posts[0]).toMatchObject({ kind: 'terminal', text: 'HI' });
    f.api.stop(correlationID);
  });

  test('a current final message needs its system ancestry and a later terminal on the claimed stream', async () => {
    const f = fixture(); await ready(f);
    f.decode(system()); f.decode(final()); expect(f.posts).toEqual([]);
    f.decode(terminal());
    expect(f.posts).toEqual([{ version: 1, kind: 'terminal', correlationID, sequence: 1, inputSHA256: hash(inputText),
      inputMessageID, conversationID, messageID, text: 'HI' }]);
    f.decode(final()); f.decode(terminal()); f.decode({ type: 'conversation_detail_metadata', conversation_id: conversationID });
    expect(f.posts).toHaveLength(1);
    f.api.stop(correlationID); expect(Object.getOwnPropertyDescriptor(f.O.prototype, 'recordCompletion')).toEqual(f.original);
    expect(f.listeners()).toBe(0); expect(f.timers.size).toBe(0); expect(f.observers.every(o => !o.active)).toBe(true);
  });

  test('the observed HI event order replays six intervening system parents without parsing provider rendering code', async () => {
    // Sanitized topology/order from decoded-result3: input text and identifiers
    // are local fixtures; the real conversation and full prompt are not stored.
    const f = fixture({ delayedDigest: true }); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
    f.decode({});
    f.decode(system(null, otherID));
    f.decode({ conversation_id: conversationID, message: { id: inputMessageID, author: { role: 'user' },
      status: 'finished_successfully', recipient: 'all', content: { content_type: 'text', parts: [inputText] } } });
    f.decode(input());
    let parent = inputMessageID;
    for (let index = 0; index < 6; index++) {
      const nodeID = `77777777-7777-4777-8777-${String(index).padStart(12, '0')}`;
      f.decode(system(parent, nodeID)); parent = nodeID;
    }
    const marker = { type: 'message_marker', conversation_id: conversationID, message_id: messageID };
    f.decode(marker); f.decode(marker);
    f.decode(final('', { status: 'in_progress', end_turn: false, metadata: { parent_id: parent,
      model_dil_v2: { code: 'opaque provider rendering program', fallbackMarkdown: 'HI' } } }));
    const finished = final('HI', { metadata: { parent_id: parent, finish_details: { type: 'stop' },
      model_dil_v2: { code: 'opaque provider rendering program', fallbackMarkdown: 'HI' } } });
    f.decode(finished); f.decode(marker); f.decode(finished);
    f.decode({ type: 'server_ste_metadata', conversation_id: conversationID }); f.decode(terminal());
    f.decode({ type: 'conversation_detail_metadata', conversation_id: conversationID });
    expect(f.posts).toEqual([]); f.resolveDigests(); await flush();
    expect(f.posts).toEqual([{ version: 1, kind: 'terminal', correlationID, sequence: 1, inputSHA256: hash(inputText),
      inputMessageID, conversationID, messageID, text: 'HI' }]);
    f.api.stop(correlationID);
  });

  test('the original receiver, return identity and thrown error are preserved', async () => {
    const f = fixture(); await ready(f);
    const value = system(); expect(f.decode(value)).toBe(value);
    const error = new Error('site parser error'); f.throwOriginal(error);
    let caught: unknown; try { f.decode(final()); } catch (value) { caught = value; }
    expect(caught).toBe(error); expect(f.posts.map(p => p.kind)).toEqual(['invalidated']);
    f.api.stop(correlationID);
  });

  test('a late original parser throw invalidates an admission without allowing hostile cleanup to replace the error', async () => {
    const f = fixture(); await ready(f); complete(f);
    const error = new Error('original parser error'); f.throwOriginal(error);
    f.document.removeEventListener = () => { throw new Error('hostile cleanup'); };
    let caught: unknown; try { f.decode(terminal()); } catch (value) { caught = value; }
    expect(caught).toBe(error); expect(f.posts.map(p => p.kind)).toEqual(['terminal', 'invalidated']);
    expect(f.O.prototype.recordCompletion).toBe(f.original.value);
  });

  test('late error, changed final, continuation, cancellation and second Send invalidate a published admission', async () => {
    for (const late of ['error', 'error_code', 'changed', 'partial', 'cancel', 'alternate', 'second_send'] as const) {
      const f = fixture(); await ready(f); complete(f); expect(f.posts).toHaveLength(1);
      if (late === 'error') f.decode({ error: { private: 'not exported' }, conversation_id: conversationID });
      if (late === 'error_code') f.decode({ error_code: 'provider_error', conversation_id: conversationID });
      if (late === 'changed') f.decode(final('CHANGED'));
      if (late === 'partial') f.decode(final('HI', { status: 'finished_partial_completion' }));
      if (late === 'cancel') f.stopClick();
      if (late === 'alternate') f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: true });
      if (late === 'second_send') f.send();
      expect(f.posts.at(-1)).toEqual({ version: 1, kind: 'invalidated', correlationID, sequence: 1, inputSHA256: hash(inputText) });
      expect(f.posts).toHaveLength(2); expect(f.listeners()).toBe(0);
    }
  });

  test('exact raw parts preserve a full JSON fence and literal escapes', async () => {
    const f = fixture(); await ready(f);
    const text = '```json\n{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf \\\"hi\\\\n\\\""}}]}\n```';
    complete(f, text); expect(f.posts[0].text).toBe(text);
    expect(Object.keys(f.posts[0]).sort()).toEqual(['version', 'kind', 'correlationID', 'sequence', 'inputSHA256',
      'inputMessageID', 'conversationID', 'messageID', 'text'].sort());
  });

  test('incomplete pre-final status, finish or parent metadata waits for the unchanged exact final contract', async () => {
    for (const partial of [
      final('', { status: undefined, metadata: undefined, end_turn: false }),
      final('partial', { status: 'finished_successfully', metadata: { parent_id: systemID }, end_turn: false }),
      final('', { status: null, metadata: { finish_details: { type: null } } }),
      final('', { status: 'in_progress', metadata: undefined, end_turn: false }),
      final('partial', { status: 'in_progress', metadata: { parent_id: null }, end_turn: false }),
    ]) {
      const f = fixture(); await ready(f); f.decode(partial);
      expect(f.posts).toEqual([]); expect(f.diagnostics).toEqual([]);
      f.decode(system()); f.decode(final('EXACT FINAL')); expect(f.posts).toEqual([]); f.decode(terminal());
      expect(f.posts).toHaveLength(1); expect(f.posts[0]).toMatchObject({ kind: 'terminal', text: 'EXACT FINAL', messageID });
      f.api.stop(correlationID);
    }
  });

  test('incomplete assistant metadata and terminal events alone supply neither success nor failure authority', async () => {
    for (const change of [{ status: undefined, metadata: undefined }, { metadata: { parent_id: systemID } },
      { status: 'in_progress', metadata: undefined }]) {
      const f = fixture(); await ready(f); f.decode(final('', change)); f.decode(terminal());
      f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
      expect(f.posts).toEqual([]); expect(f.diagnostics[0].reason).toBe('terminal_opaque');
      f.api.stop(correlationID);
    }
  });

  test('explicit failed status or finish cannot hide behind missing metadata, and selected finals cannot regress', async () => {
    for (const change of [
      { status: 'finished_partial_completion', metadata: undefined },
      { status: undefined, metadata: { finish_details: { type: 'length' } } },
      { status: undefined, metadata: { finish_details: { type: 'interrupted' } } },
    ]) {
      const f = fixture(); await ready(f); f.decode(final('', change)); complete(f);
      expect(f.posts.map(p => p.kind)).toEqual(['invalidated']);
    }
    for (const change of [{ status: undefined }, { metadata: { parent_id: systemID } },
      { status: 'in_progress', metadata: undefined }]) {
      const f = fixture(); await ready(f); f.decode(system()); f.decode(final('HI'));
      f.decode(final('HI', change)); f.decode(terminal());
      expect(f.posts.map(p => p.kind)).toEqual(['invalidated']); expect(f.diagnostics[0].reason).toBe('final_changed');
    }
  });

  test('incomplete updates cannot erase or change an already observed assistant parent', async () => {
    for (const nextParent of [undefined, otherID]) {
      const f = fixture(); await ready(f);
      f.decode(final('partial', { status: 'in_progress', end_turn: false, metadata: { parent_id: systemID } }));
      f.decode(final('partial', { status: 'in_progress', end_turn: false, metadata: { parent_id: nextParent } }));
      complete(f);
      expect(f.posts.map(p => p.kind)).toEqual(['invalidated']); expect(f.diagnostics[0].reason).toBe('parent_changed');
    }
  });

  test('partial, non-final, tool-directed, interrupted, multi-part and oversized messages cannot admit completion', async () => {
    for (const change of [
      { status: 'finished_partial_completion' }, { channel: 'analysis' }, { recipient: 'browser' }, { end_turn: false },
      { metadata: { parent_id: systemID, finish_details: { type: 'interrupted' } } },
      { content: { content_type: 'text', parts: ['HI', 'AGAIN'] } },
      { content: { content_type: 'text', parts: ['é'.repeat(110001)] } },
      { metadata: { parent_id: systemID, finish_details: { type: 'stop' }, is_error: true } },
    ]) {
      const f = fixture(); await ready(f); f.decode(system()); f.decode(final('HI', change)); f.decode(terminal());
      expect(f.posts.some(p => p.kind === 'terminal')).toBe(false);
    }
  });

  test('missing, cyclic, foreign or non-system lineage cannot connect an answer to the input', async () => {
    for (const kind of ['missing', 'cycle', 'foreign', 'assistant'] as const) {
      const f = fixture(); await ready(f);
      if (kind === 'cycle') f.decode(system(systemID));
      if (kind === 'foreign') f.decode(system(otherID));
      if (kind === 'assistant') f.decode({ ...system(), message: { ...system().message, author: { role: 'assistant' } } });
      f.decode(final()); f.decode(terminal()); expect(f.posts.some(p => p.kind === 'terminal')).toBe(false);
    }
  });

  test('a mismatched input or unobserved Send never exports a terminal receipt', async () => {
    for (const kind of ['wrong_hash', 'no_send', 'missing_conversation'] as const) {
      const f = fixture(); expect(await f.api.arm(binding())).toEqual({ armed: true });
      if (kind !== 'no_send') f.send();
      f.decode(input(kind === 'wrong_hash' ? 'x'.repeat(new TextEncoder().encode(inputText).length) : inputText,
        kind === 'missing_conversation' ? { conversation_id: null } : {}));
      await flush(); complete(f); expect(f.posts.some(p => p.kind === 'terminal')).toBe(false);
    }
  });

  test('input identity and text are copied before asynchronous digest; terminal can arrive while digest is pending', async () => {
    const f = fixture({ delayedDigest: true }); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
    const payload = input(); f.decode(payload); complete(f); expect(f.posts).toEqual([]);
    payload.conversation_id = otherID; payload.input_message.id = otherID; payload.input_message.content.parts[0] = 'changed';
    f.resolveDigests(); await flush(); expect(f.posts[0]).toMatchObject({ kind: 'terminal', conversationID, inputMessageID, text: 'HI' });
  });

  test('a second matching stream or changed conversation invalidates the first receipt', async () => {
    for (const kind of ['second_stream', 'conversation'] as const) {
      const f = fixture(); await ready(f); complete(f);
      if (kind === 'second_stream') { f.decode(input(), new f.O()); await flush(); }
      else f.decode({ conversation_id: otherID, type: 'conversation_detail_metadata' });
      expect(f.posts.at(-1).kind).toBe('invalidated'); expect(f.posts).toHaveLength(2);
    }
  });

  test('partial or unknown terminal states cannot later upgrade to success in the same attempt', async () => {
    for (const kind of ['partial', 'unknown_status', 'length', 'unknown_terminal', 'unknown_main_terminal'] as const) {
      const f = fixture(); await ready(f); f.decode(system());
      if (kind === 'partial') f.decode(final('HI', { status: 'finished_partial_completion' }));
      if (kind === 'unknown_status') f.decode(final('HI', { status: 'unknown_terminal_state' }));
      if (kind === 'length') f.decode(final('HI', { metadata: { parent_id: systemID, finish_details: { type: 'length' } } }));
      if (kind === 'unknown_terminal') f.decode({ type: 'unknown_stream_complete', conversation_id: conversationID });
      if (kind === 'unknown_main_terminal') f.decode({ type: 'main_stream_complete', conversation_id: conversationID });
      f.decode(final()); f.decode(terminal());
      expect(f.posts).toEqual([{ version: 1, kind: 'invalidated', correlationID, sequence: 1, inputSHA256: hash(inputText) }]);
    }
  });

  test('a second matching stream invalidates even if it errors before its digest resolves', async () => {
    const f = fixture({ delayedDigest: true }); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
    f.decode(input()); f.resolveDigests(); await flush(); complete(f);
    const second = new f.O(); f.decode(input(), second); f.decode({ error: 'failure', conversation_id: conversationID }, second);
    f.resolveDigests(); await flush(); expect(f.posts.map(p => p.kind)).toEqual(['terminal', 'invalidated']);
  });

  test('the observed aria-label Send fallback is admitted without requiring a test ID', async () => {
    const f = fixture({ sendLabelOnly: true }); await ready(f); complete(f); expect(f.posts[0].kind).toBe('terminal');
  });

  test('root-to-owned-conversation promotion is allowed; foreign navigation, expiry and pagehide revoke', async () => {
    for (const kind of ['foreign', 'expiry', 'pagehide'] as const) {
      const f = fixture(); await ready(f);
      f.location.href = 'https://chatgpt.com/c/' + conversationID; f.mutate(); complete(f); expect(f.posts[0].kind).toBe('terminal');
      if (kind === 'foreign') { f.location.href = 'https://chatgpt.com/c/' + otherID; f.mutate(); }
      if (kind === 'expiry') { f.tick(1000); [...f.timers.values()][0](); }
      if (kind === 'pagehide') f.pagehide();
      expect(f.posts.at(-1).kind).toBe('invalidated'); expect(f.listeners()).toBe(0);
    }
  });

  test('unsupported cached decoder and malformed bindings fall back without installing a wrapper or retrying Send', async () => {
    const unavailable = fixture({ unsupported: true }); expect(await unavailable.api.arm(binding())).toEqual({ armed: false });
    expect(unavailable.imports()).toBe(1); expect(unavailable.posts).toEqual([]); expect(unavailable.listeners()).toBe(0);
    const f = fixture(); let reads = 0;
    const malformed = Object.defineProperty(binding(), 'inputSHA256', { enumerable: true, get() { reads++; return hash(inputText); } });
    for (const bad of [{ ...binding(), extra: 'private' }, { ...binding(), sequence: 0 }, { ...binding(), sequence: 17 },
      { ...binding(), inputUTF8Bytes: 180001 }, { ...binding(), inputUTF8Bytes: NaN },
      { ...binding(), durationMs: Infinity }, malformed]) expect(await f.api.arm(bad)).toEqual({ armed: false });
    expect(reads).toBe(0); expect(f.imports()).toBe(0);
  });

  test('wrong stop cannot revoke another correlation and a foreign method replacement is preserved', async () => {
    const f = fixture(); await ready(f); f.api.stop(otherID); complete(f); expect(f.posts[0].kind).toBe('terminal');
    const replacement = function () {}; Object.defineProperty(f.O.prototype, 'recordCompletion', { ...f.original, value: replacement });
    f.api.stop(correlationID); expect(f.O.prototype.recordCompletion).toBe(replacement);
  });

  test('a retained page rearms a fresh round and ignores the decoder previous-complete flag and old stop', async () => {
    const f = fixture(); await ready(f); complete(f); f.api.stop(correlationID);
    f.location.href = 'https://chatgpt.com/c/' + conversationID;
    const nextText = inputText + ' next', nextInputID = '88888888-8888-4888-8888-888888888888';
    const nextMessageID = '99999999-9999-4999-8999-999999999999';
    expect(await f.api.arm({ ...binding(), correlationID: otherID, sequence: 2,
      inputSHA256: hash(nextText), inputUTF8Bytes: new TextEncoder().encode(nextText).length })).toEqual({ armed: true });
    f.api.stop(correlationID); f.send(); expect(f.receiver.messageStreamCompleted).toBe(true);
    const nextInput = input(nextText); nextInput.input_message.id = nextInputID; f.decode(nextInput); await flush();
    f.decode(system(nextInputID)); f.decode(final('NEXT', { id: nextMessageID }));
    expect(f.posts).toHaveLength(1); f.decode(terminal());
    expect(f.posts[1]).toMatchObject({ kind: 'terminal', correlationID: otherID, sequence: 2,
      inputSHA256: hash(nextText), inputMessageID: nextInputID, messageID: nextMessageID, text: 'NEXT' });
    f.api.stop(otherID); expect(f.listeners()).toBe(0);
  });

  test('unsupported runtime emits only a bounded diagnostic and successful stop remains silent', async () => {
    const unavailable = fixture({ unsupported: true });
    expect(await unavailable.api.arm(binding())).toEqual({ armed: false });
    expect(unavailable.allPosts).toEqual([{ version: 1, kind: 'diagnostic', correlationID, sequence: 1,
      inputSHA256: hash(inputText), reason: 'runtime_cache_shape', calls: 0, instances: 0 }]);
    expect(unavailable.O.prototype.recordCompletion).toBe(unavailable.original.value);
    expect(unavailable.listeners()).toBe(0); expect(unavailable.timers.size).toBe(0);
    const successful = fixture(); await ready(successful); complete(successful); successful.api.stop(correlationID);
    expect(successful.allPosts.map(p => p.kind)).toEqual(['terminal']);
    const stopped = fixture({ delayedDigest: true });
    expect(await stopped.api.arm(binding())).toEqual({ armed: true }); stopped.send(); stopped.decode(input());
    stopped.api.stop(correlationID); stopped.rejectDigests(); await flush();
    expect(stopped.allPosts).toEqual([]);
  });

  test('callback and decoder caps emit one diagnostic before the unchanged invalidation without relaxing either cap', async () => {
    const calls = fixture(); await ready(calls);
    for (let index = 0; index < 255; index++) calls.decode({});
    expect(calls.allPosts).toEqual([]); calls.decode({});
    expect(calls.allPosts).toEqual([
      { version: 1, kind: 'diagnostic', correlationID, sequence: 1, inputSHA256: hash(inputText),
        reason: 'call_limit', calls: 257, instances: 1 },
      { version: 1, kind: 'invalidated', correlationID, sequence: 1, inputSHA256: hash(inputText) },
    ]);
    expect(calls.O.prototype.recordCompletion).toBe(calls.original.value);
    const decoders = fixture(); expect(await decoders.api.arm(binding())).toEqual({ armed: true }); decoders.send();
    for (let index = 0; index < 4; index++) decoders.decode({}, new decoders.O());
    expect(decoders.allPosts).toEqual([]); decoders.decode({}, new decoders.O());
    expect(decoders.diagnostics).toHaveLength(1);
    expect(decoders.diagnostics[0]).toMatchObject({ reason: 'decoder_limit', calls: 5, instances: 4 });
    expect(decoders.allPosts.map(p => p.kind)).toEqual(['diagnostic', 'invalidated']);
  });

  test('an unrelated rejected input produces no authority and cannot block a later exact claimed stream', async () => {
    const f = fixture(); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
    const foreign = new f.O(); f.decode(input('x'.repeat(new TextEncoder().encode(inputText).length)), foreign); await flush();
    expect(f.posts).toEqual([]);
    expect(f.diagnostics).toEqual([{ version: 1, kind: 'diagnostic', correlationID, sequence: 1,
      inputSHA256: hash(inputText), reason: 'input_hash', calls: 1, instances: 1 }]);
    f.decode(input()); await flush(); complete(f);
    expect(f.posts).toEqual([{ version: 1, kind: 'terminal', correlationID, sequence: 1, inputSHA256: hash(inputText),
      inputMessageID, conversationID, messageID, text: 'HI' }]);
    f.decode({ error: 'private provider detail' });
    expect(f.diagnostics).toHaveLength(1);
    expect(f.allPosts.map(p => p.kind)).toEqual(['diagnostic', 'terminal', 'invalidated']);
  });

  test('missing ancestry reports once without rejecting a later observed valid parent', async () => {
    const f = fixture(); await ready(f); f.decode(final()); f.decode(terminal());
    expect(f.posts).toEqual([]); expect(f.diagnostics).toHaveLength(1);
    expect(f.diagnostics[0]).toMatchObject({ reason: 'ancestry_missing', calls: 3, instances: 1 });
    f.decode({ type: 'conversation_detail_metadata' }); expect(f.diagnostics).toHaveLength(1);
    f.decode(system()); expect(f.posts[0]).toMatchObject({ kind: 'terminal', text: 'HI' });
    f.api.stop(correlationID);
  });

  test('concrete rejection reasons remain finite and precede unchanged invalidation packets', async () => {
    for (const [reason, action] of [
      ['route_changed', (f: ReturnType<typeof fixture>) => { f.location.href = 'https://chatgpt.com/c/' + otherID; f.mutate(); }],
      ['wrapper_changed', (f: ReturnType<typeof fixture>) => { Object.defineProperty(f.O.prototype, 'recordCompletion', { ...f.original, value() {} }); f.mutate(); }],
      ['parent_changed', (f: ReturnType<typeof fixture>) => f.decode(system(otherID))],
      ['final_status', (f: ReturnType<typeof fixture>) => f.decode(final('HI', { status: 'finished_partial_completion' }))],
      ['final_changed', (f: ReturnType<typeof fixture>) => f.decode(final('DIFFERENT'))],
      ['error', (f: ReturnType<typeof fixture>) => f.decode({ error: { private: 'never exported' } })],
      ['send_changed', (f: ReturnType<typeof fixture>) => f.send()],
      ['expired', (f: ReturnType<typeof fixture>) => { f.tick(1000); [...f.timers.values()][0](); }],
    ] as const) {
      const f = fixture(); await ready(f); complete(f); action(f);
      expect(f.allPosts.map(p => p.kind)).toEqual(['terminal', 'diagnostic', 'invalidated']);
      expect(f.diagnostics[0].reason).toBe(reason);
      expect(Object.keys(f.diagnostics[0]).sort()).toEqual([
        'version', 'kind', 'correlationID', 'sequence', 'inputSHA256', 'reason', 'calls', 'instances',
      ].sort());
      expect(JSON.stringify(f.diagnostics)).not.toContain('private');
      expect(JSON.stringify(f.diagnostics)).not.toContain('https://');
      expect(JSON.stringify(f.diagnostics)).not.toContain(inputMessageID);
    }
  });

  test('an owned empty stream needs both terminal events, in either order, and emits no response bytes', async () => {
    for (const reversed of [false, true]) {
      const f = fixture(); await ready(f);
      const main = { type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false };
      f.decode(reversed ? terminal() : main); expect(f.posts).toEqual([]);
      f.decode(reversed ? main : terminal());
      expect(f.posts).toEqual([{ version: 1, kind: 'terminal_failure', correlationID, sequence: 1,
        inputSHA256: hash(inputText), inputMessageID, conversationID, reason: 'empty_stream', calls: 3,
        assistantMessages: 0, messageTerminalCount: 1, mainTerminalCount: 1 }]);
      f.decode(terminal()); expect(f.posts).toHaveLength(1);
      expect(JSON.stringify(f.posts)).not.toContain(inputText);
      f.api.stop(correlationID);
    }
  });

  test('slow, hanging, alternate and unclaimed streams cannot emit a terminal failure', async () => {
    for (const mode of ['hanging', 'message_only', 'main_only', 'alternate', 'unclaimed', 'wrong_input'] as const) {
      const f = fixture(); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
      if (mode !== 'unclaimed') f.decode(input(mode === 'wrong_input' ? 'x'.repeat(new TextEncoder().encode(inputText).length) : inputText));
      await flush();
      if (!['hanging', 'main_only'].includes(mode)) f.decode(terminal());
      if (!['hanging', 'message_only'].includes(mode)) f.decode({ type: 'main_stream_complete', conversation_id: conversationID,
        alternate_response_expected: mode === 'alternate' });
      expect(f.posts.some(p => p.kind === 'terminal_failure')).toBe(false);
      f.api.stop(correlationID);
    }
  });

  test('opaque DIL, content references and nontext content remain diagnostic-only after the stream ends', async () => {
    for (const change of [
      { metadata: { parent_id: systemID, finish_details: { type: 'stop' }, model_dil_v2: { code: 'not inspected', fallbackMarkdown: '' } } },
      { metadata: { parent_id: systemID, finish_details: { type: 'stop' }, content_references: [{ private: 'not inspected' }] } },
      { content: { content_type: 'native_widget', data: 'not inspected' } },
    ]) {
      const f = fixture(); await ready(f); f.decode(system()); f.decode(final('', change));
      f.decode(terminal()); f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
      expect(f.posts).toEqual([]);
      expect(f.diagnostics).toHaveLength(1); expect(f.diagnostics[0].reason).toBe('terminal_opaque');
      expect(JSON.stringify(f.diagnostics)).not.toContain('not inspected');
      f.api.stop(correlationID);
    }
  });

  test('owned provider errors need both terminal events and a matching resolved input digest', async () => {
    const f = fixture({ delayedDigest: true }); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
    f.decode(input()); f.decode({ error: { message: 'private provider error' }, conversation_id: conversationID });
    expect(f.posts).toEqual([]); f.decode(terminal()); expect(f.posts).toEqual([]);
    f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
    expect(f.posts).toEqual([]); f.resolveDigests(); await flush();
    expect(f.posts).toEqual([{ version: 1, kind: 'terminal_failure', correlationID, sequence: 1,
      inputSHA256: hash(inputText), inputMessageID, conversationID, reason: 'provider_error', calls: 4,
      assistantMessages: 0, messageTerminalCount: 1, mainTerminalCount: 1 }]);
    expect(JSON.stringify(f.allPosts)).not.toContain('private provider error');
    f.pagehide(); expect(f.posts.at(-1).kind).toBe('invalidated');
  });

  test('combined error and message envelopes are diagnostic-only regardless of message shape', async () => {
    for (const message of [final('PRIVATE ANSWER').message, final('', { content: { content_type: 'native_widget' } }).message, {}, null]) {
      const f = fixture(); await ready(f);
      const envelope = { error: 'private error', conversation_id: conversationID, message };
      if (message === null) Object.defineProperty(envelope, 'message', { get() { throw Error('must not execute'); } });
      f.decode(envelope); f.decode(terminal());
      f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
      expect(f.posts).toEqual([]);
      expect(JSON.stringify(f.allPosts)).not.toContain('PRIVATE ANSWER');
      expect(JSON.stringify(f.allPosts)).not.toContain('private error');
      f.api.stop(correlationID);
    }
  });

  test('an error and message terminal cannot abort before a later alternate main stream is known', async () => {
    for (const alternate of [true, false]) {
      const f = fixture(); await ready(f);
      f.decode({ error: 'private error', conversation_id: conversationID }); f.decode(terminal());
      expect(f.posts).toEqual([]);
      f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: alternate });
      expect(f.posts.some(p => p.kind === 'terminal_failure')).toBe(!alternate);
      if (alternate) expect(f.posts.map(p => p.kind)).toEqual(['invalidated']);
      f.api.stop(correlationID);
    }
  });

  test('pending empty observations are revoked by digest mismatch, navigation, cancellation or a foreign conversation', async () => {
    for (const mode of ['wrong_input', 'navigation', 'stop', 'foreign'] as const) {
      const f = fixture({ delayedDigest: true }); expect(await f.api.arm(binding())).toEqual({ armed: true }); f.send();
      f.decode(input(mode === 'wrong_input' ? 'x'.repeat(new TextEncoder().encode(inputText).length) : inputText));
      f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
      f.decode({ ...terminal(), conversation_id: mode === 'foreign' ? otherID : conversationID });
      if (mode === 'navigation') { f.location.href = 'https://chatgpt.com/c/' + otherID; f.mutate(); }
      if (mode === 'stop') f.api.stop(correlationID);
      f.resolveDigests(); await flush();
      expect(f.posts.some(p => p.kind === 'terminal_failure')).toBe(false);
      f.api.stop(correlationID);
    }
  });

  test('mixed error and valid content can neither abort nor gain early completion authority', async () => {
    const f = fixture(); await ready(f);
    f.decode({ error: 'unrelated' }, new f.O());
    f.decode({ error: 'owned but not a terminal result', conversation_id: conversationID });
    expect(f.posts).toEqual([]);
    complete(f, 'ACTUAL ANSWER');
    f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
    expect(f.posts).toEqual([]);
    f.decode({ error: 'late unrecognized metadata' }); expect(f.posts).toEqual([]);
    f.api.stop(correlationID);
  });

  test('late content after an empty terminal revokes the failure instead of creating conflicting success authority', async () => {
    const f = fixture(); await ready(f);
    f.decode(terminal()); f.decode({ type: 'main_stream_complete', conversation_id: conversationID, alternate_response_expected: false });
    expect(f.posts.map(p => p.kind)).toEqual(['terminal_failure']);
    f.decode(final('LATE CONTENT'));
    expect(f.posts.map(p => p.kind)).toEqual(['terminal_failure', 'invalidated']);
    expect(f.O.prototype.recordCompletion).toBe(f.original.value);
  });
});
