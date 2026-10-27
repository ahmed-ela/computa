import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-request-metadata.js', import.meta.url), 'utf8');
const key = '__computaRequestMetadata_' + 'a'.repeat(32);
const completionSource = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-completion.js', import.meta.url), 'utf8');
const completionKey = '__computaCompletion_' + 'b'.repeat(32);
const runtimeURL = 'https://chatgpt.com/cdn/assets/633146.8ccf94f4a9.js';
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture(options: { origin?: string; frame?: boolean; durationMs?: number; configKey?: string; syncError?: Error;
  captureDecodedEvents?: boolean; loadRuntime?: () => Promise<unknown>; defineProperty?: typeof Object.defineProperty } = {}) {
  const pending = deferred<Response>(), calls: { receiver: unknown; args: unknown[] }[] = [];
  let clock = 0;
  const original = function (this: unknown, ...args: unknown[]) {
    calls.push({ receiver: this, args });
    if (options.syncError) throw options.syncError;
    return pending.promise;
  };
  const window: any = { fetch: original, Blob, ArrayBuffer, ReadableStream, FormData, URLSearchParams, DOMException, TypeError, Response, URL, Headers };
  const reflection = { apply: Reflect.apply, ownKeys: Reflect.ownKeys };
  const stringType = { prototype: { charCodeAt: String.prototype.charCodeAt } };
  const objectType = { prototype: Object.prototype, getOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
    getPrototypeOf: Object.getPrototypeOf, keys: Object.keys, freeze: Object.freeze, defineProperty: options.defineProperty ?? Object.defineProperty };
  window.top = options.frame ? {} : window;
  const location = { origin: options.origin ?? 'https://chatgpt.com', href: (options.origin ?? 'https://chatgpt.com') + '/' };
  const config = { key: options.configKey ?? key, durationMs: options.durationMs ?? 1000,
    ...(options.captureDecodedEvents ? { captureDecodedEvents: true, completionKey } : {}) };
  let imports = 0;
  const loadRuntime = () => { imports++; return options.loadRuntime ? options.loadRuntime() : Promise.resolve({}); };
  const documentEvents = new Map<string, Function>();
  const button: any = {isConnected:true,disabled:false,getClientRects:()=>[{}],getAttribute:()=>null,
    closest:(selector:string)=>selector.startsWith('button[data-testid="send-button"]')?button:null};
  const document = {addEventListener:(name:string,fn:Function)=>documentEvents.set(name,fn),
    removeEventListener:(name:string,fn:Function)=>{if(documentEvents.get(name)===fn)documentEvents.delete(name);}, querySelectorAll:()=>[button]};
  const posts:any[]=[]; window.webkit={messageHandlers:{computaChatGPTCompletion:{postMessage:(value:any)=>posts.push(value)}}};
  const events = new Map<string, Set<Function>>();
  window.addEventListener = (name: string, fn: Function) => { if (!events.has(name)) events.set(name, new Set()); events.get(name)!.add(fn); };
  window.removeEventListener = (name: string, fn: Function) => events.get(name)?.delete(fn);
  const timers = new Map<number, Function>(); let timerID = 0;
  const performance = { now: () => clock + 100, getEntriesByType: () => [{name:runtimeURL,initiatorType:'script',startTime:0,responseEnd:1,responseStatus:200}] };
  if (options.captureDecodedEvents) new Function('window','document','location','performance','loadRuntime','Object','setTimeout','clearTimeout','MutationObserver','getComputedStyle',
    completionSource.replace('__COMPUTA_COMPLETION_CONFIG__', JSON.stringify({key:completionKey,handlerName:'computaChatGPTCompletion',allowsDiagnosticSubscribers:true}))
      .replace('import(runtimeURL)', 'loadRuntime(runtimeURL)'))(window, document, location, performance, loadRuntime, objectType,
        (fn:Function) => { timers.set(++timerID,fn); return timerID; }, (id:number) => timers.delete(id), class {observe(){} disconnect(){}}, ()=>({visibility:'visible'}));
  const install = () => new Function('window', 'location', 'performance', 'Reflect', 'String', 'Object', 'loadRuntime',
    source.replace('__COMPUTA_REQUEST_METADATA_CONFIG__', JSON.stringify(config)))(
      window, location, performance, reflection, stringType, objectType, loadRuntime);
  install();
  return { window, original, calls, pending, install, reflection, stringType, objectType, location, imports: () => imports,
    tick: (value: number) => { clock = value; },
    completion: window[completionKey], posts, send:()=>documentEvents.get('click')?.({target:button}),
    pagehide:()=>[...(events.get('pagehide')??[])].forEach(fn=>fn()),
    hook: (command: string) => window[config.key]?.(command) };
}

describe('one-view request metadata diagnostic', () => {
  test('cached fetch forwards receiver/arguments once and returns the original promise and response', async () => {
    const f = fixture(), cached = f.window.fetch;
    const before = cached.call(f.window, '/before');
    expect(before).toBe(f.pending.promise);
    expect(f.hook('snapshot').rows).toEqual([]);
    f.hook('activate'); f.tick(11);
    const init = { method: 'POST', body: 'aé😀\ud800', keepalive: false, duplex: 'half' };
    const promise = cached.call(f.window, '/backend-api/f/conversation?private=TOKEN', init);
    expect(promise).toBe(f.pending.promise);
    expect(f.calls).toHaveLength(2);
    expect(f.calls[1].receiver).toBe(f.window);
    expect(f.calls[1].args[1]).toBe(init);
    f.tick(22);
    const response = new Response('PRIVATE_RESPONSE', { status: 201 });
    f.pending.resolve(response);
    expect(await promise).toBe(response);
    expect(response.bodyUsed).toBe(false);
    expect(f.hook('snapshot').rows).toEqual([{ ordinal: 1, endpoint: 'conversation', origin: 'same', method: 'POST',
      bodyType: 'string', bodyBytes: 10, headerMetadata: null, keepalive: 'false', duplex: 'half', startedMs: 11, settledMs: 22,
      outcome: 'headers', status: 201, error: 'none' }]);
  });

  test('rejects, aborts and synchronous throws retain their exact original error', async () => {
    for (const [reason, kind] of [[new TypeError('PRIVATE_TOKEN'), 'type_error'],
      [new DOMException('PRIVATE_TOKEN', 'AbortError'), 'abort'],
      [new DOMException('PRIVATE_TOKEN', 'NotSupportedError'), 'unsupported'],
      [new Error('PRIVATE_TOKEN'), 'other']] as const) {
      const f = fixture(); f.hook('activate');
      const promise = f.window.fetch('/backend-api/f/conversation', { body: 'PRIVATE_BODY' });
      f.tick(8); f.pending.reject(reason);
      expect(await promise.catch((value: unknown) => value)).toBe(reason);
      const snapshot = f.hook('snapshot');
      expect(snapshot.rows[0]).toMatchObject({ outcome: 'rejected', error: kind, status: null, settledMs: 8 });
      expect(JSON.stringify(snapshot)).not.toContain('PRIVATE');
    }
    const error = new TypeError('PRIVATE_SYNC_ERROR'), f = fixture({ syncError: error });
    f.hook('activate');
    let caught: unknown; try { f.window.fetch('/backend-api/f/conversation'); } catch (value) { caught = value; }
    expect(caught).toBe(error);
    expect(f.calls).toHaveLength(1);
    expect(f.hook('snapshot').rows[0]).toMatchObject({ outcome: 'sync_throw', error: 'type_error' });
  });

  test('does not invoke option getters or stringify opaque input/body objects', () => {
    const f = fixture(); f.hook('activate');
    let reads = 0;
    const init = Object.defineProperties({}, {
      body: { get() { reads++; throw new Error('PRIVATE'); } },
      method: { get() { reads++; return 'POST'; } },
      keepalive: { get() { reads++; return true; } },
    });
    f.window.fetch('/backend-api/f/conversation', init);
    const opaque = { toString() { reads++; throw new Error('PRIVATE'); } };
    f.window.fetch(opaque, { body: opaque });
    f.window.fetch('/backend-api/f/conversation', new Proxy({}, { getOwnPropertyDescriptor() { throw new Error('PRIVATE'); } }));
    expect(reads).toBe(0);
    expect(f.calls).toHaveLength(3);
    expect(f.calls[0].args[1]).toBe(init);
    expect(f.hook('snapshot').rows[0]).toMatchObject({ bodyType: 'unknown', bodyBytes: null, method: 'unknown', keepalive: 'unknown' });
    expect(f.hook('snapshot').rows).toHaveLength(2);
  });

  test('opaque bodies and Request inputs are never read, cloned or consumed', () => {
    let pulls = 0;
    const stream = new ReadableStream({ pull() { pulls++; } }, { highWaterMark: 0 });
    const bodies: [unknown, string][] = [[new Blob(['PRIVATE']), 'blob'], [new ArrayBuffer(4), 'buffer'],
      [new Uint8Array([1, 2]), 'view'], [stream, 'stream'], [new FormData(), 'form_data'],
      [new URLSearchParams({ private: 'TOKEN' }), 'url_params']];
    for (const [body, type] of bodies) {
      const f = fixture(); f.hook('activate');
      f.window.fetch('/backend-api/f/conversation', { method: 'POST', body });
      expect(f.hook('snapshot').rows[0]).toMatchObject({ bodyType: type, bodyBytes: null });
    }
    const f = fixture(), request = new Request('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: 'PRIVATE' });
    f.hook('activate'); f.window.fetch(request);
    expect(f.hook('snapshot').rows).toEqual([]);
    expect(f.calls[0].args[0]).toBe(request);
    expect(request.bodyUsed).toBe(false);
    expect(stream.locked).toBe(false); expect(pulls).toBe(0);
  });

  test('records only finite classes and bounds rows, payload counting and serialized output', () => {
    const f = fixture(); f.hook('activate');
    for (let i = 0; i < 32; i++) f.window.fetch('/backend-api/f/conversation?token=PRIVATE#PRIVATE', {
      method: 'PRIVATE', body: 'é'.repeat(600000), headers: { Authorization: 'PRIVATE' }, keepalive: true, duplex: 'PRIVATE',
    });
    const snapshot = f.hook('snapshot'), serialized = JSON.stringify(snapshot);
    expect(f.calls).toHaveLength(32); expect(snapshot.rows).toHaveLength(8);
    expect(snapshot.rows[0]).toMatchObject({ endpoint: 'conversation', origin: 'same', method: 'other', bodyType: 'string',
      bodyBytes: null, duplex: 'other', keepalive: 'true' });
    expect(serialized.length).toBeLessThan(8192); expect(serialized).not.toContain('PRIVATE');
    expect(serialized).not.toContain('Authorization'); expect(serialized).not.toContain('private.example');
    const g = fixture(); g.hook('activate');
    g.window.fetch('/backend-api/sentinel/chat-requirements');
    g.window.fetch('/backend-api/f/conversation/prepare');
    expect(g.hook('snapshot').rows.map((row: any) => row.endpoint)).toEqual(['preparation', 'preparation']);
  });

  test('counts oversized supplied header strings without retaining names or values, independently of body size', () => {
    const f = fixture(); f.hook('activate');
    const name = 'X-PRIVATE-AUTH', value = 'PRIVATE_VALUE_' + 'a'.repeat(70000);
    const init = { method: 'POST', body: 'tiny', headers: { [name]: value } };
    const promise = f.window.fetch('/backend-api/f/conversation', init);
    expect(promise).toBe(f.pending.promise); expect(f.calls).toEqual([{ receiver: f.window, args: ['/backend-api/f/conversation', init] }]);
    const snapshot = f.hook('snapshot');
    expect(snapshot.rows[0]).toMatchObject({ bodyBytes: 4, headerMetadata: { representation: 'record', count: 1,
      nameUTF8Bytes: name.length, valueUTF8Bytes: value.length, maxValueUTF8Bytes: value.length,
      invalidTokenName: false, hasNUL: false, hasCRLF: false, hasNonLatin1: false } });
    expect(JSON.stringify(snapshot)).not.toContain('PRIVATE');
    expect(JSON.stringify(snapshot)).not.toContain(value);
  });

  test('captured native Headers iteration reports normalized aggregates and ignores later prototype overrides', () => {
    const f = fixture(); f.hook('activate');
    const headers = new Headers([['X-Private', 'PRIVATE'], ['x-private', 'VALUE'], ['Accept', 'text/plain']]);
    let reads = 0;
    Object.defineProperty(headers, 'forEach', { get() { reads++; throw new Error('PRIVATE'); } });
    f.window.Headers = () => { reads++; throw new Error('PRIVATE'); };
    f.window.fetch('/backend-api/f/conversation', { headers });
    expect(reads).toBe(0);
    expect(f.hook('snapshot').rows[0].headerMetadata).toEqual({ representation: 'native_headers', count: 2,
      nameUTF8Bytes: 15, valueUTF8Bytes: 24, maxValueUTF8Bytes: 14,
      invalidTokenName: false, hasNUL: false, hasCRLF: false, hasNonLatin1: false });
    expect(JSON.stringify(f.hook('snapshot'))).not.toContain('PRIVATE');
  });

  test('plain pairs retain only validity flags and opaque or accessor headers remain unknown without reads', () => {
    const f = fixture(); f.hook('activate');
    let reads = 0;
    const accessorInit = Object.defineProperty({}, 'headers', { get() { reads++; throw new Error('PRIVATE'); } });
    const accessorRecord = Object.defineProperty({}, 'X-Private', { enumerable: true, get() { reads++; throw new Error('PRIVATE'); } });
    const accessorPair = ['X-Private', 'PRIVATE'];
    Object.defineProperty(accessorPair, '1', { get() { reads++; throw new Error('PRIVATE'); } });
    const opaque = { toString() { reads++; throw new Error('PRIVATE'); }, [Symbol.iterator]() { reads++; throw new Error('PRIVATE'); } };
    for (const init of [undefined, accessorInit, { headers: accessorRecord }, { headers: [accessorPair] }, { headers: opaque }])
      f.window.fetch('/backend-api/f/conversation', init);
    f.window.fetch('/backend-api/f/conversation', { headers: [['Bad Name', 'PRIVATE\0\r\n😀']] });
    f.window.fetch('/backend-api/f/conversation', { headers: {} });
    expect(reads).toBe(0);
    expect(f.hook('snapshot').rows.slice(0, 5).map((row: any) => row.headerMetadata)).toEqual(Array(5).fill(null));
    expect(f.hook('snapshot').rows[5].headerMetadata).toEqual({ representation: 'pairs', count: 1,
      nameUTF8Bytes: 8, valueUTF8Bytes: 14, maxValueUTF8Bytes: 14,
      invalidTokenName: true, hasNUL: true, hasCRLF: true, hasNonLatin1: true });
    expect(f.hook('snapshot').rows[6].headerMetadata).toEqual({ representation: 'record', count: 0,
      nameUTF8Bytes: 0, valueUTF8Bytes: 0, maxValueUTF8Bytes: 0,
      invalidTokenName: false, hasNUL: false, hasCRLF: false, hasNonLatin1: false });
    expect(JSON.stringify(f.hook('snapshot'))).not.toContain('PRIVATE');
  });

  test('header entry and combined byte caps return unknown rather than partial totals', () => {
    const f = fixture(); f.hook('activate');
    const tooMany = Array.from({ length: 257 }, () => ['x', 'PRIVATE']);
    const max = { x: 'a'.repeat(1048575) };
    const over = { x: 'a'.repeat(1048576) };
    const nativeTooMany = new Headers(Array.from({ length: 257 }, (_, index) => [`x-${index}`, 'PRIVATE']));
    for (const headers of [tooMany, over, nativeTooMany, max]) f.window.fetch('/backend-api/f/conversation', { headers });
    const rows = f.hook('snapshot').rows;
    expect(rows.slice(0, 3).map((row: any) => row.headerMetadata)).toEqual([null, null, null]);
    expect(rows[3].headerMetadata).toMatchObject({ count: 1, nameUTF8Bytes: 1, valueUTF8Bytes: 1048575, maxValueUTF8Bytes: 1048575 });
    expect(JSON.stringify(f.hook('snapshot')).length).toBeLessThan(8192);
  });

  test('unrelated requests cannot exhaust capture capacity or acquire option/settlement observers', async () => {
    const f = fixture(), cached = f.window.fetch;
    f.hook('activate');
    let inspected = 0;
    let settlementObservers = 0;
    Object.defineProperty(f.pending.promise, 'constructor', { get() { settlementObservers++; return Promise; } });
    const opaque = { toString() { inspected++; throw new Error('PRIVATE'); } };
    const unrelatedInit = new Proxy({}, { getOwnPropertyDescriptor() { inspected++; throw new Error('PRIVATE'); } });
    const noise: unknown[] = ['/backend-api/me', '/backend-api/conversations', '/backend-api/f/conversation/other',
      '/backend-api/f/conversation/prepare/other', '/backend-api/sentinel/chat-requirements/other',
      'https://other.example/backend-api/f/conversation', 'https://other.example/backend-api/f/conversation/prepare',
      'data:text/plain,PRIVATE', 'https://', opaque,
      new Request('https://chatgpt.com/backend-api/f/conversation'), '/incidental'];
    const receiver = {};
    for (const input of noise) {
      expect(cached.call(receiver, input, unrelatedInit)).toBe(f.pending.promise);
      expect(f.calls.at(-1)).toEqual({ receiver, args: [input, unrelatedInit] });
    }
    expect(inspected).toBe(0);
    expect(settlementObservers).toBe(0);
    expect(f.hook('snapshot').rows).toEqual([]);
    const prepareInit = { method: 'POST', body: 'PREPARE', keepalive: false };
    const conversationInit = { method: 'POST', body: 'CONVERSATION', keepalive: false };
    const prepare = cached.call(receiver, '/backend-api/f/conversation/prepare?private=TOKEN', prepareInit);
    const conversation = cached.call(receiver, '/backend-api/f/conversation', conversationInit);
    expect(prepare).toBe(f.pending.promise); expect(conversation).toBe(f.pending.promise);
    expect(settlementObservers).toBe(2);
    expect(f.calls).toHaveLength(noise.length + 2);
    expect(f.calls.at(-2)).toEqual({ receiver, args: ['/backend-api/f/conversation/prepare?private=TOKEN', prepareInit] });
    expect(f.calls.at(-1)).toEqual({ receiver, args: ['/backend-api/f/conversation', conversationInit] });
    const response = new Response('PRIVATE_RESPONSE', { status: 202 });
    f.pending.resolve(response);
    expect(await prepare).toBe(response); expect(await conversation).toBe(response);
    expect(response.bodyUsed).toBe(false);
    expect(f.hook('snapshot').rows).toMatchObject([
      { ordinal: 1, endpoint: 'preparation', origin: 'same', bodyBytes: 7, outcome: 'headers', status: 202 },
      { ordinal: 2, endpoint: 'conversation', origin: 'same', bodyBytes: 12, outcome: 'headers', status: 202 },
    ]);
    expect(JSON.stringify(f.hook('snapshot'))).not.toContain('PRIVATE');

    const reason = new TypeError('PRIVATE_UNRELATED'), rejected = fixture(); rejected.hook('activate');
    const promise = rejected.window.fetch('/backend-api/me');
    rejected.pending.reject(reason);
    expect(await promise.catch((error: unknown) => error)).toBe(reason);
    expect(rejected.calls).toHaveLength(1); expect(rejected.hook('snapshot').rows).toEqual([]);
    const sync = fixture({ syncError: reason }); sync.hook('activate');
    let caught: unknown; try { sync.window.fetch('/backend-api/me'); } catch (error) { caught = error; }
    expect(caught).toBe(reason); expect(sync.calls).toHaveLength(1); expect(sync.hook('snapshot').rows).toEqual([]);
  });

  test('expiry stops recording and a native stop restores fetch without overwriting another wrapper', async () => {
    const f = fixture(); f.hook('activate'); f.window.fetch('/backend-api/f/conversation');
    f.tick(1000); f.window.fetch('/after-expiry');
    expect(f.hook('snapshot')).toMatchObject({ active: false, expired: true });
    expect(f.hook('snapshot').rows).toHaveLength(1);
    const stopped = f.hook('stop');
    expect(stopped.active).toBe(false); expect(f.window.fetch).toBe(f.original); expect(f.window[key]).toBeUndefined();
    f.pending.resolve(new Response('PRIVATE')); await f.pending.promise;
    expect(stopped.rows[0].outcome).toBe('pending');
    const g = fixture(); g.hook('activate'); const replacement = () => g.pending.promise;
    g.window.fetch = replacement; g.hook('stop'); expect(g.window.fetch).toBe(replacement);
  });

  test('wrong origin/frame/config and duplicate installation cannot expand capture', () => {
    for (const options of [{ origin: 'https://other.example' }, { frame: true }, { durationMs: 0 },
      { durationMs: 600001 }, { configKey: 'PRIVATE' }]) {
      const f = fixture(options); expect(f.window.fetch).toBe(f.original); expect(f.hook('activate')).toBeUndefined();
    }
    const f = fixture(), wrapper = f.window.fetch;
    f.install(); expect(f.window.fetch).toBe(wrapper);
    expect(f.hook('unknown')).toBeNull(); expect(f.hook('snapshot').active).toBe(false);
  });

  test('later page patches cannot replace forwarding or private-value inspection intrinsics', async () => {
    const f = fixture(); f.hook('activate');
    let patchesCalled = 0;
    const patched = () => { patchesCalled++; throw new Error('PRIVATE_PATCH'); };
    f.reflection.apply = patched;
    f.reflection.ownKeys = patched;
    f.stringType.prototype.charCodeAt = patched;
    f.objectType.getOwnPropertyDescriptor = patched;
    f.objectType.getPrototypeOf = patched;
    for (const name of ['Blob', 'ArrayBuffer', 'ReadableStream', 'FormData', 'URLSearchParams', 'DOMException', 'TypeError', 'Response', 'URL', 'Headers'])
      f.window[name] = patched;
    const promise = f.window.fetch('/backend-api/f/conversation', { method: 'POST', body: 'é😀', headers: { 'X-Private': 'é😀' } });
    const response = new Response('PRIVATE_RESPONSE', { status: 202 });
    f.pending.resolve(response); expect(await promise).toBe(response);
    expect(f.calls).toHaveLength(1); expect(patchesCalled).toBe(0);
    expect(f.hook('snapshot').rows[0]).toMatchObject({ endpoint: 'conversation', bodyType: 'string', bodyBytes: 6, outcome: 'headers', status: 202,
      headerMetadata: { representation: 'record', count: 1, nameUTF8Bytes: 9, valueUTF8Bytes: 6, hasNonLatin1: true } });
  });
});

const knownNullProgram = 'DIL.render(__dil.jsx(()=>{const __dilConstants=DIL.useConstants();const __dilModelDataBindings=DIL.useAppData((appData)=>appData.opGenui?.modelDataBindings??{});return null;},{"key":"body:0"}));';
const currentConversation = '00000000-0000-4000-8000-000000000001';
function program() {
  return { code: knownNullProgram, constants: { PRIVATE_CONSTANT: 'PRIVATE' }, fallbackMarkdown: '',
    recoveryDiagnostics: [{ code: 'unterminated_braced_value', action: 'recovered_parse', line: 1, column: 1 }],
    appData: { PRIVATE_APP_DATA: 'PRIVATE' } };
}
function message(dil: unknown = program()) {
  return { conversation_id: currentConversation, message: { author: { role: 'assistant' }, status: 'finished_successfully',
    content: { parts: ['PRIVATE_MESSAGE'] }, metadata: { model_dil_v2: dil } } };
}
function decoderRuntime(options: { reason?: unknown; malformedGetter?: boolean; wrongMethod?: boolean; frozenMethod?: boolean } = {}) {
  const calls: unknown[] = [];
  const T = { safeParse(input: any) {
    calls.push(input);
    if (options.reason) throw options.reason;
    return { success: true, data: { type: 'message_stream_complete' } };
  } };
  // Use the exact audited class-method/getter source. No vendor code or network
  // runs in these fixtures; the schema delegate is an independent test double.
  const result = new Function('T', `class O {
    recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}
  }; const exports = {}; Object.defineProperty(exports, 'c', {enumerable:true,get:()=>O});
  return { O, exports };`)(T);
  if (options.malformedGetter) result.exports = Object.defineProperty({}, 'c', { enumerable: true, get: () => result.O });
  if (options.wrongMethod) result.O.prototype.recordCompletion = function wrong(input: unknown) { return input; };
  if (options.frozenMethod) Object.defineProperty(result.O.prototype, 'recordCompletion', { writable: false });
  let requires = 0;
  const require = Object.assign(() => { requires++; throw new Error('Factories must not run'); }, { c: { dd: { exports: result.exports } } });
  return { module: { __webpack_require__: require }, Decoder: result.O, calls, requires: () => requires,
    original: Object.getOwnPropertyDescriptor(result.O.prototype, 'recordCompletion')! };
}

describe('explicit pre-presentation decoded metadata diagnostic', () => {
  test('v1 never imports a runtime or changes its exact four-key schema', () => {
    const r = decoderRuntime(), f = fixture({ loadRuntime: async () => r.module });
    expect(f.hook('activate').active).toBe(true);
    expect(Object.keys(f.hook('snapshot')).sort()).toEqual(['active', 'expired', 'rows', 'schemaVersion']);
    expect(f.imports()).toBe(0);
    expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(r.original);
  });

  test('awaits one observed-runtime activation and preserves exact result, receiver and original call count', async () => {
    const r = decoderRuntime(), loading = deferred<unknown>();
    const f = fixture({ captureDecodedEvents: true, loadRuntime: () => loading.promise });
    f.location.href = 'https://chatgpt.com/c/' + currentConversation;
    const activation = f.hook('activate');
    expect(f.hook('activate')).toBe(activation);
    expect(f.hook('snapshot')).toMatchObject({ schemaVersion: 2, active: false, decoder: { state: 'pending' } });
    expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(r.original);
    loading.resolve(r.module);
    expect(await activation).toMatchObject({ active: true, decoder: { state: 'installed' } });
    const decoder = new r.Decoder(), input = message(); f.tick(12);
    expect(decoder.recordCompletion(input, 'PRIVATE_EXTRA')).toBe(input);
    expect(decoder.messageStreamCompleted).toBe(true);
    const second = message();
    expect(await Promise.resolve(second).then(value => decoder.recordCompletion(value))).toBe(second);
    expect(r.calls).toEqual([input, second]); expect(f.imports()).toBe(1); expect(r.requires()).toBe(0);
    const snapshot = f.hook('snapshot');
    expect(snapshot.decoder).toMatchObject({ state: 'installed', completionCalls: 2, programObservations: 2,
      recoveredNullObservations: 2, lastProgram: { elapsedMs: 12, carrier: 'message', messageStatus: 'finished_successfully',
        conversationMatchesDocument: true, codeLength: 194, knownNullProgram: true, emptyFallbackMarkdown: true,
        recovery: 'unterminated_braced_value_recovered_parse', recoveryLine: 1, recoveryColumn: 1 } });
    const serialized = JSON.stringify(snapshot);
    expect(serialized).not.toContain('PRIVATE'); expect(serialized).not.toContain(knownNullProgram);
    expect(serialized).not.toContain(currentConversation); expect(serialized.length).toBeLessThan(8192);
    snapshot.decoder.lastProgram.codeLength = 5;
    expect(f.hook('snapshot').decoder.lastProgram.codeLength).toBe(194);
    const stopped = f.hook('stop');
    expect(stopped.decoder.state).toBe('restored'); expect(stopped.active).toBe(false);
    expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(r.original);
  });

  test('identical original throw escapes once without retaining its text or adding promise observers', async () => {
    const reason = new Error('PRIVATE_THROW'), r = decoderRuntime({ reason });
    const f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module }); await f.hook('activate');
    const decoder = new r.Decoder(), input = message(); let caught;
    try { decoder.recordCompletion(input); } catch (error) { caught = error; }
    expect(caught).toBe(reason); expect(r.calls).toEqual([input]);
    expect(f.hook('snapshot').decoder.completionCalls).toBe(0);
    expect(JSON.stringify(f.hook('snapshot'))).not.toContain('PRIVATE'); f.hook('stop');
    const s = decoderRuntime(), g = fixture({ captureDecodedEvents: true, loadRuntime: async () => s.module });
    await g.hook('activate');
    let observers = 0; const promise = Promise.resolve('PRIVATE');
    Object.defineProperty(promise, 'constructor', { get() { observers++; return Promise; } });
    expect(new s.Decoder().recordCompletion(promise)).toBe(promise);
    expect(observers).toBe(0); expect(s.calls).toEqual([promise]); g.hook('stop');
  });

  test('cache/export/source/descriptor misses stay unsupported without initializing a module', async () => {
    for (const options of [{ malformedGetter: true }, { wrongMethod: true }, { frozenMethod: true }]) {
      const r = decoderRuntime(options), f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module });
      const snapshot = await f.hook('activate');
      expect(snapshot).toMatchObject({ active: false, decoder: { state: 'unavailable', completionCalls: 0, lastProgram: null } });
      expect(r.requires()).toBe(0);
      expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(r.original);
      f.hook('stop');
    }
    let requires = 0;
    const require = Object.assign(() => { requires++; throw new Error('PRIVATE'); }, { c: {} });
    for (const module of [{}, { __webpack_require__: require }]) {
      const f = fixture({ captureDecodedEvents: true, loadRuntime: async () => module });
      expect(await f.hook('activate')).toMatchObject({ active: false, decoder: { state: 'unavailable' } });
      f.hook('stop');
    }
    expect(requires).toBe(0);
  });

  test('late imports cannot install after stop, expiry, key replacement or rejection', async () => {
    for (const mode of ['stop', 'expiry', 'replacement', 'reject']) {
      const r = decoderRuntime(), pending = deferred<unknown>();
      const f = fixture({ captureDecodedEvents: true, loadRuntime: () => pending.promise });
      const activation = f.hook('activate');
      if (mode === 'stop') f.hook('stop');
      if (mode === 'expiry') f.tick(1000);
      if (mode === 'replacement') Object.defineProperty(f.window, key, { value: () => null, configurable: true });
      if (mode === 'reject') pending.reject(new Error('PRIVATE_IMPORT'));
      else pending.resolve(r.module);
      const snapshot = await activation;
      expect(snapshot.active).toBe(false);
      expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(r.original);
      expect(JSON.stringify(snapshot)).not.toContain('PRIVATE');
      if (mode !== 'stop' && mode !== 'replacement') f.hook('stop');
    }
  });

  test('stop and expiry restore only the installed descriptor and preserve foreign replacements', async () => {
    for (const change of ['value', 'attributes', 'expiry']) {
      const r = decoderRuntime(), f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module });
      await f.hook('activate');
      if (change === 'value') r.Decoder.prototype.recordCompletion = (input: unknown) => input;
      if (change === 'attributes') Object.defineProperty(r.Decoder.prototype, 'recordCompletion', { enumerable: true });
      const foreign = Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion');
      if (change === 'expiry') {
        f.tick(1000); new r.Decoder().recordCompletion(message());
        expect(f.hook('snapshot').decoder).toMatchObject({ state: 'restored', completionCalls: 0, lastProgram: null });
      }
      const stopped = f.hook('stop');
      expect(stopped.decoder.state).toBe(change === 'expiry' ? 'restored' : 'superseded');
      expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(change === 'expiry' ? r.original : foreign);
    }
  });

  test('fixed carriers and nullable conversation association do not invent a patch owner', async () => {
    const r = decoderRuntime(), f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module });
    await f.hook('activate'); const decoder = new r.Decoder();
    const reference = { conversation_id: currentConversation, message: { author: { role: 'assistant' }, status: 'in_progress', metadata: { content_references: [{ model_dil_v2: program() }] } } };
    decoder.recordCompletion(reference);
    expect(f.hook('snapshot').decoder.lastProgram).toMatchObject({ carrier: 'reference', conversationMatchesDocument: null });
    f.location.href = 'https://chatgpt.com/c/00000000-0000-4000-8000-000000000002';
    decoder.recordCompletion(reference);
    expect(f.hook('snapshot').decoder.lastProgram.conversationMatchesDocument).toBe(false);
    f.location.href = 'https://chatgpt.com/c/' + currentConversation;
    decoder.recordCompletion({ type: 'content_references_patch', message_id: 'PRIVATE_ID', content_references: [{ model_dil_v2: program() }] });
    expect(f.hook('snapshot').decoder.lastProgram).toMatchObject({ carrier: 'reference_patch', messageStatus: 'unknown', conversationMatchesDocument: null });
    expect(JSON.stringify(f.hook('snapshot'))).not.toContain('PRIVATE_ID'); f.hook('stop');
  });

  test('projection skips getters, distinguishes near-null programs and saturates counters', async () => {
    const r = decoderRuntime(), f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module });
    await f.hook('activate'); const decoder = new r.Decoder(); let getters = 0;
    decoder.recordCompletion(message(Object.defineProperties({}, {
      code: { get() { getters++; throw new Error('PRIVATE'); } },
      fallbackMarkdown: { get() { getters++; return 'PRIVATE'; } },
      recoveryDiagnostics: { get() { getters++; return []; } },
    })));
    expect(getters).toBe(0);
    expect(f.hook('snapshot').decoder.lastProgram).toMatchObject({ codeLength: null, knownNullProgram: false, recovery: 'unknown' });
    const near = program(); near.code += ' '; near.recoveryDiagnostics = [];
    decoder.recordCompletion(message(near));
    expect(f.hook('snapshot').decoder.lastProgram).toMatchObject({ codeLength: 195, knownNullProgram: false, recovery: 'none', recoveryLine: null, recoveryColumn: null });
    const input = message();
    for (let i = 0; i < 65536; i++) decoder.recordCompletion(input);
    expect(f.hook('snapshot').decoder).toMatchObject({ completionCalls: 65535, programObservations: 65535, recoveredNullObservations: 65535 });
    expect(JSON.stringify(f.hook('snapshot')).length).toBeLessThan(8192); f.hook('stop');
  });

  test('non-assistant messages cannot supply a diagnostic assistant program', async () => {
    const r = decoderRuntime(), f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module });
    await f.hook('activate'); const decoder = new r.Decoder();
    for (const role of ['user', 'tool', 'system', 'PRIVATE_ROLE']) {
      const input = message(); input.message.author.role = role; decoder.recordCompletion(input);
    }
    decoder.recordCompletion({ message: { metadata: { model_dil_v2: program() } } });
    expect(f.hook('snapshot').decoder).toMatchObject({ completionCalls: 5, programObservations: 0, lastProgram: null });
    f.hook('stop');
  });

  test('expiry during cache validation refuses even a transient descriptor installation', async () => {
    const r = decoderRuntime(); let methodWrites = 0;
    const f = fixture({ captureDecodedEvents: true, loadRuntime: async () => r.module,
      defineProperty(target, name, property) {
        if (target === r.Decoder.prototype && name === 'recordCompletion') methodWrites++;
        return Object.defineProperty(target, name, property);
      } });
    const exports = r.module.__webpack_require__.c.dd.exports;
    r.module.__webpack_require__.c.dd.exports = new Proxy(exports, { getOwnPropertyDescriptor(target, name) {
      if (name === 'c') f.tick(1000);
      return Object.getOwnPropertyDescriptor(target, name);
    } });
    const snapshot = await f.hook('activate');
    expect(snapshot).toMatchObject({ active: false, expired: true });
    expect(methodWrites).toBe(0);
    expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype, 'recordCompletion')).toEqual(r.original);
    f.hook('stop');
  });
});


describe('actual diagnostic and completion script coexistence', () => {
  const binding = () => ({correlationID:'11111111-1111-4111-8111-111111111111',sequence:1,
    inputSHA256:'a'.repeat(64),inputUTF8Bytes:2,durationMs:1000});
  test('diagnostic activation and completion arm share one wrapper and stop independently in either order', async () => {
    for (const diagnosticFirst of [true,false]) {
      const r=decoderRuntime(), f=fixture({captureDecodedEvents:true,loadRuntime:async()=>r.module});
      if (diagnosticFirst) await f.hook('activate'); else expect(await f.completion.arm(binding())).toEqual({armed:true});
      const wrapper=r.Decoder.prototype.recordCompletion;
      if (diagnosticFirst) expect(await f.completion.arm(binding())).toEqual({armed:true}); else await f.hook('activate');
      expect(r.Decoder.prototype.recordCompletion).toBe(wrapper); expect(f.imports()).toBe(1);
      const decoder=new r.Decoder(); const value=message(); expect(decoder.recordCompletion(value)).toBe(value);
      if (diagnosticFirst) {
        f.completion.stop(binding().correlationID); expect(r.Decoder.prototype.recordCompletion).toBe(wrapper);
        decoder.recordCompletion({type:'main_stream_complete'}); decoder.recordCompletion({type:'message_stream_complete'});
        expect(f.hook('snapshot').decoder.stream).toMatchObject({assistantMessages:1,mainTerminals:1,messageTerminals:1,decoderInstances:1});
        f.hook('stop');
      } else {
        f.hook('stop'); expect(r.Decoder.prototype.recordCompletion).toBe(wrapper);
        f.completion.stop(binding().correlationID);
      }
      expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype,'recordCompletion')).toEqual(r.original);
      expect(r.calls).toHaveLength(diagnosticFirst?3:1);
    }
  });
  test('completion rejection leaves finite diagnostics alive through later terminal events', async () => {
    const r=decoderRuntime(), f=fixture({captureDecodedEvents:true,loadRuntime:async()=>r.module});
    await f.hook('activate'); expect(await f.completion.arm({...binding(),inputSHA256:createHash('sha256').update('hi').digest('hex')})).toEqual({armed:true});
    const decoder=new r.Decoder(); f.send();
    decoder.recordCompletion({type:'input_message',conversation_id:currentConversation,input_message:{id:'33333333-3333-4333-8333-333333333333',author:{role:'user'},content:{content_type:'text',parts:['hi']}}});
    await new Promise(resolve=>setTimeout(resolve,0));
    const partial=message();partial.message.status='finished_partial';decoder.recordCompletion(partial);
    decoder.recordCompletion(message()); decoder.recordCompletion({type:'main_stream_complete'});
    decoder.recordCompletion({type:'message_stream_complete'});
    expect(f.hook('snapshot').decoder.stream).toMatchObject({inputMessages:1,assistantMessages:2,mainTerminals:1,messageTerminals:1});
    expect(f.posts.some(p=>p.kind==='terminal')).toBe(false);
    f.hook('stop'); expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype,'recordCompletion')).toEqual(r.original);
  });
  test('original throw stays exact for both subscribers and diagnostic pagehide restores the method', async () => {
    const reason=new Error('PRIVATE'),r=decoderRuntime({reason}),f=fixture({captureDecodedEvents:true,loadRuntime:async()=>r.module});
    await f.hook('activate'); expect(await f.completion.arm(binding())).toEqual({armed:true});
    try {new r.Decoder().recordCompletion({});throw new Error('no throw');}catch(error){expect(error).toBe(reason);}
    expect(f.hook('snapshot').decoder.stream).toMatchObject({originalThrows:1,decoderInstances:1});
    expect(f.hook('snapshot').decoder.completionCalls).toBe(0);
    f.pagehide();expect(f.hook('snapshot').active).toBe(false);
    expect(Object.getOwnPropertyDescriptor(r.Decoder.prototype,'recordCompletion')).toEqual(r.original);
  });
});
