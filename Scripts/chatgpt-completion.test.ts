import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-completion.js', import.meta.url), 'utf8');
const runtimeImport = "import('https://chatgpt.com/cdn/assets/633146.fa01f470fd.js')";
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

function fixture(options: { unsupported?: boolean; delayedDigest?: boolean; sendLabelOnly?: boolean; loadRuntime?: () => Promise<unknown> } = {}) {
  let clock = 0, imports = 0, timerID = 0, throwOriginal: unknown = null;
  // Retain all wire packets; the original authority regressions deliberately
  // inspect only the unchanged terminal/invalidated schemas.
  const allPosts: any[] = [], posts: any[] = [], diagnostics: any[] = [];
  const timers = new Map<number, () => void>(), documentEvents = new Map<string, Function>();
  const windowEvents = new Map<string, Function>(), observers: any[] = [], pendingDigests: { bytes: Uint8Array; resolve: Function; reject: Function }[] = [];
  const O = new Function('T', 'return class O {recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}}')({
    safeParse(value: any) { if (throwOriginal) throw throwOriginal; return { success: !!value?.type, data: value }; },
  });
  const original = Object.getOwnPropertyDescriptor(O.prototype, 'recordCompletion')!;
  const exports = Object.defineProperty({}, 'c', { get: new Function('O', 'return ()=>O')(O), enumerable: true, configurable: false });
  const runtime = { __webpack_require__: { c: { dd: { exports } } } };
  const window: any = { webkit: { messageHandlers: { computaChatGPTCompletion: { postMessage(record: any) {
    allPosts.push(record); (record.kind === 'diagnostic' ? diagnostics : posts).push(record);
  } } } },
    addEventListener(name: string, listener: Function) { windowEvents.set(name, listener); },
    removeEventListener(name: string, listener: Function) { if (windowEvents.get(name) === listener) windowEvents.delete(name); } };
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
  const cryptoFixture = { subtle: { digest(_name: string, bytes: Uint8Array) {
    if (options.delayedDigest) return new Promise((resolve, reject) => pendingDigests.push({ bytes, resolve, reject }));
    return Promise.resolve(new Uint8Array(createHash('sha256').update(bytes).digest()).buffer);
  } } };
  const loadRuntime = () => { imports++; return options.loadRuntime ? options.loadRuntime()
    : Promise.resolve(options.unsupported ? {} : runtime); };
  expect(source.split(runtimeImport)).toHaveLength(2);
  const execute = new Function('window', 'document', 'location', 'performance', 'crypto', 'MutationObserver',
    'getComputedStyle', 'setTimeout', 'clearTimeout', 'loadRuntime', source
      .replace('__COMPUTA_COMPLETION_CONFIG__', JSON.stringify({ key, handlerName: 'computaChatGPTCompletion' }))
      .replace(runtimeImport, 'loadRuntime()'));
  execute(window, document, location, { now: () => clock }, cryptoFixture, Observer, () => ({ visibility: 'visible' }),
    (callback: () => void) => { timers.set(++timerID, callback); return timerID; }, (id: number) => timers.delete(id), loadRuntime);
  const receiver = new O();
  return { window, document, button, location, allPosts, posts, diagnostics, timers, observers, imports: () => imports,
    api: window[key], O, receiver, original,
    send: () => documentEvents.get('click')?.({ target: button }),
    stopClick: () => documentEvents.get('click')?.({ target: { closest: (s: string) => s.includes('stop-button') ? {} : null } }),
    decode: (payload: any, instance = receiver) => instance.recordCompletion(payload),
    tick: (value: number) => { clock = value; }, mutate: () => observers.filter(o => o.active).forEach(o => o.callback()),
    pagehide: () => windowEvents.get('pagehide')?.(), throwOriginal: (error: unknown) => { throwOriginal = error; },
    resolveDigests: () => pendingDigests.splice(0).forEach(({ bytes, resolve }) => resolve(new Uint8Array(createHash('sha256').update(bytes).digest()).buffer)),
    rejectDigests: () => pendingDigests.splice(0).forEach(({ reject }) => reject(new Error('private digest error'))),
    listeners: () => documentEvents.size + windowEvents.size,
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
      inputSHA256: hash(inputText), reason: 'runtime_unsupported', calls: 0, instances: 0 }]);
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
});
