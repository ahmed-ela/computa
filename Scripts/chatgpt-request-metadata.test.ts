import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-request-metadata.js', import.meta.url), 'utf8');
const key = '__computaRequestMetadata_' + 'a'.repeat(32);
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture(options: { origin?: string; frame?: boolean; durationMs?: number; configKey?: string; syncError?: Error } = {}) {
  const pending = deferred<Response>(), calls: { receiver: unknown; args: unknown[] }[] = [];
  let clock = 0;
  const original = function (this: unknown, ...args: unknown[]) {
    calls.push({ receiver: this, args });
    if (options.syncError) throw options.syncError;
    return pending.promise;
  };
  const window: any = { fetch: original, Blob, ArrayBuffer, ReadableStream, FormData, URLSearchParams, DOMException, TypeError, Response, URL };
  const reflection = { apply: Reflect.apply };
  const stringType = { prototype: { charCodeAt: String.prototype.charCodeAt } };
  const objectType = { prototype: Object.prototype, getOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
    getPrototypeOf: Object.getPrototypeOf, defineProperty: Object.defineProperty };
  window.top = options.frame ? {} : window;
  const location = { origin: options.origin ?? 'https://chatgpt.com', href: (options.origin ?? 'https://chatgpt.com') + '/' };
  const config = { key: options.configKey ?? key, durationMs: options.durationMs ?? 1000 };
  const install = () => new Function('window', 'location', 'performance', 'Reflect', 'String', 'Object',
    source.replace('__COMPUTA_REQUEST_METADATA_CONFIG__', JSON.stringify(config)))(window, location, { now: () => clock }, reflection, stringType, objectType);
  install();
  return { window, original, calls, pending, install, reflection, stringType, objectType, tick: (value: number) => { clock = value; },
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
      bodyType: 'string', bodyBytes: 10, keepalive: 'false', duplex: 'half', startedMs: 11, settledMs: 22,
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
    expect(f.hook('snapshot').rows[1]).toMatchObject({ endpoint: 'unknown', origin: 'unknown', bodyType: 'unknown' });
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
    expect(f.hook('snapshot').rows[0]).toMatchObject({ endpoint: 'unknown', method: 'unknown', bodyType: 'unknown', bodyBytes: null,
      keepalive: 'unknown', duplex: 'unknown' });
    expect(request.bodyUsed).toBe(false);
    expect(stream.locked).toBe(false); expect(pulls).toBe(0);
  });

  test('records only finite classes and bounds rows, payload counting and serialized output', () => {
    const f = fixture(); f.hook('activate');
    for (let i = 0; i < 32; i++) f.window.fetch('https://private.example/PRIVATE?token=PRIVATE#PRIVATE', {
      method: 'PRIVATE', body: 'é'.repeat(600000), headers: { Authorization: 'PRIVATE' }, keepalive: true, duplex: 'PRIVATE',
    });
    const snapshot = f.hook('snapshot'), serialized = JSON.stringify(snapshot);
    expect(f.calls).toHaveLength(32); expect(snapshot.rows).toHaveLength(8);
    expect(snapshot.rows[0]).toMatchObject({ endpoint: 'other', origin: 'other', method: 'other', bodyType: 'string',
      bodyBytes: null, duplex: 'other', keepalive: 'true' });
    expect(serialized.length).toBeLessThan(8192); expect(serialized).not.toContain('PRIVATE');
    expect(serialized).not.toContain('Authorization'); expect(serialized).not.toContain('private.example');
    const g = fixture(); g.hook('activate');
    g.window.fetch('/backend-api/sentinel/chat-requirements');
    g.window.fetch('/backend-api/f/conversation/prepare');
    expect(g.hook('snapshot').rows.map((row: any) => row.endpoint)).toEqual(['preparation', 'preparation']);
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
    f.stringType.prototype.charCodeAt = patched;
    f.objectType.getOwnPropertyDescriptor = patched;
    f.objectType.getPrototypeOf = patched;
    for (const name of ['Blob', 'ArrayBuffer', 'ReadableStream', 'FormData', 'URLSearchParams', 'DOMException', 'TypeError', 'Response', 'URL'])
      f.window[name] = patched;
    const promise = f.window.fetch('/backend-api/f/conversation', { method: 'POST', body: 'é😀' });
    const response = new Response('PRIVATE_RESPONSE', { status: 202 });
    f.pending.resolve(response); expect(await promise).toBe(response);
    expect(f.calls).toHaveLength(1); expect(patchesCalled).toBe(0);
    expect(f.hook('snapshot').rows[0]).toMatchObject({ endpoint: 'conversation', bodyType: 'string', bodyBytes: 6, outcome: 'headers', status: 202 });
  });
});
