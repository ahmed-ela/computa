import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt.js', import.meta.url), 'utf8');
const helper = source.slice(source.indexOf('// BEGIN COMPUTA RENDERER WORK DIAGNOSTIC V1'), source.indexOf('// END COMPUTA RENDERER WORK DIAGNOSTIC V1'));
const owner = '00000000-0000-4000-8000-000000000001';
function fixture() {
  let wall = 1_000_000, clock = 0, clockReads = 0;
  const window: any = {}; window.top = window;
  const context: any = createContext({ window, document: {}, location: { origin: 'https://chatgpt.com' },
    Date: { now: () => wall }, performance: { timeOrigin: 1_000_000, now: () => { clockReads++; return clock; } },
    request: { provider: 'chatgpt', ownerToken: owner, rendererWorkDiagnosticExpiresAtUnixSeconds: 1100 } });
  runInContext(helper, context);
  const install = (overrides: any = {}) => {
    context.request = { provider: 'chatgpt', ownerToken: owner, rendererWorkDiagnosticExpiresAtUnixSeconds: 1100, ...overrides };
    return runInContext('chatGPTInstallRendererWorkDiagnostic(request)', context);
  };
  return { context, install, clockReads: () => clockReads, advance: (ms: number) => { clock += ms; },
    setClock: (ms: number) => { clock = ms; }, expire: () => { wall = 1_100_000; } };
}

describe('private synchronous renderer work diagnostic', () => {
  test('is inert unarmed, malformed, expired, overlong, foreign or subframed', () => {
    for (const value of [undefined, null, true, NaN, Infinity, 1000, 1601, '1100']) {
      const f = fixture(); expect(f.install({ rendererWorkDiagnosticExpiresAtUnixSeconds: value })).toBeNull();
      expect(f.context.__computaRendererWorkDiagnosticV1).toBeUndefined(); expect(f.clockReads()).toBe(0);
    }
    for (const mutate of [(c: any) => { c.window.top = {}; }, (c: any) => { c.location.origin = 'https://example.com'; }]) {
      const f = fixture(); mutate(f.context); expect(f.install()).toBeNull(); expect(f.clockReads()).toBe(0);
    }
    const f = fixture(); expect(f.install({ ownerToken: 'unowned' })).toBeNull(); expect(f.install({ provider: 'gemini' })).toBeNull();
  });
  test('records all thirteen fixed stages and bounded numeric data only', () => {
    const f = fixture(), api = f.install();
    for (let index = 0; index < 13; index++) { const start = api.now(); f.advance(index + 1); api.record(index, start); }
    const result = api.snapshot();
    expect(Object.keys(result).sort()).toEqual(['invocationCount','saturated','slowSpans','stages','version']);
    expect(result.stages).toEqual(Array.from({ length: 13 }, (_, index) => [1, index + 1, index + 1]));
    expect(result.invocationCount).toBe(1); expect(result.version).toBe(1);
    expect(JSON.stringify(result).length).toBeLessThan(4096);
    expect(JSON.stringify(result)).not.toContain(owner);
    result.stages[0][0] = 100; expect(api.snapshot().stages[0][0]).toBe(1);
  });
  test('nested measurements remain inclusive and slow spans use aligned epoch timestamps', () => {
    const f = fixture(), api = f.install(), outer = api.now();
    f.advance(5); const inner = api.now(); f.advance(20); api.record(6, inner); f.advance(15); api.record(5, outer);
    expect(api.snapshot().stages[5]).toEqual([1,40,40]); expect(api.snapshot().stages[6]).toEqual([1,20,20]);
    expect(api.snapshot().slowSpans).toEqual([[5,1000000,40],[6,1000005,20]]);
  });
  test('keeps only the eight slowest spans and excludes unknown or nonfinite samples', () => {
    const f = fixture(), api = f.install();
    for (let i = 10; i <= 25; i++) { const start = api.now(); f.advance(i); api.record(0,start); }
    expect(api.snapshot().slowSpans.map((row: number[]) => row[2])).toEqual([25,24,23,22,21,20,19,18]);
    const before = api.snapshot();
    for (const index of [-1,13,1.5,NaN]) api.record(index,0);
    for (const started of [undefined,null,NaN,Infinity,-1]) api.record(1,started);
    f.setClock(NaN); api.record(1,0); expect(api.now()).toBeNull();
    expect(api.snapshot()).toEqual(before);
    f.setClock(600001); api.record(1,0); expect(api.snapshot()).toEqual(before);
  });
  test('bounds invocation and per-stage work without introducing timers or extra messages', () => {
    const f = fixture(), api = f.install();
    for (let i = 0; i < 4097; i++) { const start = api.now(); f.advance(1); api.record(0,start); }
    expect(api.snapshot().stages[0]).toEqual([4096,4096,1]); expect(api.snapshot().saturated).toBeTrue();
    for (let i = 1; i < 256; i++) expect(f.install()).not.toBeNull();
    expect(f.install()).toBeNull(); expect(api.snapshot().invocationCount).toBe(256);
    expect(helper).not.toContain('setTimeout'); expect(helper).not.toContain('MessageChannel');
    expect(helper).not.toContain('querySelector');
  });
  test('stops on expiry or changed document/owner and cannot rebind an existing collector', () => {
    const f = fixture(), api = f.install();
    expect(f.install({ ownerToken: '00000000-0000-4000-8000-000000000002' })).toBeNull();
    expect(f.install({ rendererWorkDiagnosticExpiresAtUnixSeconds: 1150 })).toBeNull();
    f.context.__computaModelOwner = 'different'; expect(api.now()).toBeNull(); expect(api.snapshot()).toBeNull();
    delete f.context.__computaModelOwner;
    f.expire(); expect(api.now()).toBeNull(); expect(api.snapshot()).toBeNull();
    const g = fixture(), other = g.install(); g.context.document = {}; expect(other.snapshot()).toBeNull(); expect(g.install()).toBeNull();
  });
  test('provider-only shared-function wrappers preserve this, arguments, returns and throws', () => {
    const begin = source.indexOf('function chatGPTProfileSynchronousWork(');
    const end = source.indexOf('if (chatGPTRendererWorkDiagnostic)',begin);
    const records: any[] = [], receiver = {}, sentinel = {};
    const wrap = new Function('chatGPTSyncWorkStart','chatGPTSyncWorkEnd',source.slice(begin,end)
      + 'return chatGPTProfileSynchronousWork;')(() => 7,(...args: any[]) => records.push(args));
    const fn = function (this: any, ...args: any[]) { expect(this).toBe(receiver); expect(args).toEqual(['one','two']); return sentinel; };
    expect(wrap(fn,5).call(receiver,'one','two')).toBe(sentinel); expect(records).toEqual([[5,7]]);
    try { wrap(() => { throw sentinel; },11)(); throw new Error('Expected original throw'); }
    catch (error) { expect(error).toBe(sentinel); }
    expect(records).toEqual([[5,7],[11,7]]);
    const shared = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url),'utf8');
    expect(source.startsWith(shared + '\n')).toBeTrue();
  });
  test('direct synchronous wrappers preserve exact return values and thrown objects', () => {
    const names = ['chatGPTProductModeState','chatGPTProductModeProof','chatGPTTemporaryVerified',
      'chatGPTTemporaryOutlineForRoot','websiteChatDeferredModelRead'];
    for (const name of names) {
      const begin = source.indexOf(`function ${name}(`), end = source.indexOf(`function ${name}Unprofiled(`,begin);
      const wrapper = source.slice(begin,end), sentinel = {}, calls: any[] = [];
      const make = (implementation: any) => new Function('chatGPTSyncWorkStart','chatGPTSyncWorkEnd',`${name}Unprofiled`,
        wrapper + `return ${name};`)(() => 7,(...values: any[]) => calls.push(values),implementation);
      expect(make(() => sentinel)('first','second')).toBe(sentinel); expect(calls).toHaveLength(1); expect(calls[0][1]).toBe(7);
      try { make(() => { throw sentinel; })('first','second'); throw new Error('Expected original throw'); }
      catch (error) { expect(error).toBe(sentinel); }
      expect(calls).toHaveLength(2);
    }
  });
});
