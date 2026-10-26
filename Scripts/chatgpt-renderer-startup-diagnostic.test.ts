import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-renderer-startup-diagnostic.js', import.meta.url), 'utf8');
const runnerURL = 'https://cdn.platform.openai.com/deployments/dil/v14/runner.html';
function fixture(url = 'https://chatgpt.com/?temporary-chat=true', subframe = false) {
  let now = 1000000, calls = 0, writes = 0;
  const listeners = new Set<(event: any) => void>(), timers: (() => void)[] = [];
  const location: any = new URL(url);
  const locationView: any = { get href() { return location.href; }, get origin() { return location.origin; },
    get hash() { return location.hash; }, set hash(value: string) { writes++; location.hash = value; } };
  const window: any = { addEventListener: (type: string, fn: any) => { calls++; if (type === 'message') listeners.add(fn); },
    removeEventListener: (type: string, fn: any) => { if (type === 'message') listeners.delete(fn); },
    setTimeout: (fn: () => void) => { timers.push(fn); } };
  window.top = subframe ? {} : window;
  const frame: any = { isConnected: true, src: runnerURL + '#dil-diagnostics=1', contentWindow: {},
    sandbox: new Set(['allow-scripts']) };
  frame.sandbox.contains = frame.sandbox.has.bind(frame.sandbox);
  const frames = [frame];
  const document = { querySelectorAll: () => frames };
  const install = (config: any = { expiresAtUnixSeconds: now / 1000 + 100 }) => {
    const configured = source.replace('__COMPUTA_RENDERER_STARTUP_DIAGNOSTIC_CONFIG__', 'providedConfig');
    new Function('window', 'document', 'location', 'Date', 'providedConfig', configured)(window, document, locationView, { now: () => now }, config);
  };
  const send = (record: any, override: any = {}) => {
    const data = { __oaiDilFrame: true, kind: 'diagnostic', protocolVersion: 14, record, ...override.data };
    for (const listener of [...listeners]) listener({ data, source: frame.contentWindow, ...override });
  };
  const state = () => window.__computaRendererStartupDiagnosticV1;
  const buffer = () => state()?.frames.find((value: any) => value.iframe === frame);
  return { install, send, state, buffer, window, frame, frames, location, timers, listeners, writes: () => writes,
    calls: () => calls, advance: (ms: number) => { now += ms; } };
}

describe('private ChatGPT renderer startup diagnostic', () => {
  test('is inert without a finite current arm and outside exact trusted contexts', () => {
    for (const config of [null, {}, { expiresAtUnixSeconds: true }, { expiresAtUnixSeconds: NaN },
      { expiresAtUnixSeconds: 1000 }, { expiresAtUnixSeconds: 1601 }]) {
      const f = fixture(); f.install(config); expect(f.calls()).toBe(0); expect(f.state()).toBeUndefined();
    }
    for (const url of ['https://example.com/', 'http://chatgpt.com/', 'https://chatgpt.com.example.org/']) {
      const f = fixture(url); f.install(); expect(f.calls()).toBe(0); expect(f.state()).toBeUndefined();
    }
  });
  test('adds only the supported hash on the exact opaque runner frame', () => {
    const f = fixture(runnerURL + '#existing=value', true); f.install();
    expect(f.location.hash).toBe('#existing=value&dil-diagnostics=1'); expect(f.location.search).toBe('');
    expect(f.writes()).toBe(1); expect(f.calls()).toBe(0); expect(f.state()).toBeUndefined();
    f.install(); expect(f.writes()).toBe(1);
    for (const url of [runnerURL + '?query=1', runnerURL.replace('v14', 'v13'), runnerURL.replace('https:', 'http:'),
      runnerURL.replace('cdn.platform.openai.com', 'cdn.platform.openai.com.evil.test'),
      runnerURL.replace('https://', 'https://name@'), runnerURL.replace('runner.html', 'other.html')]) {
      const bad = fixture(url, true); bad.install(); expect(bad.writes()).toBe(0);
    }
  });
  test('collects only finite fields from the current exact sandboxed iframe', () => {
    const f = fixture(); f.install();
    f.send({ realm: 'worker', operation: 'harden_worker', phase: 'returned', localTimeMs: 3.5, timeOriginMs: 1234,
      elapsedMs: 1, budgetMs: 10000, workerGeneration: 1, sessionGeneration: 2, startupAttempt: 1,
      artifactId: 'DrCNBd66', fault: { name: 'TypeError', message: 'secret', stack: 'private' },
      compiledDil: 'secret code', data: { secret: true }, reason: 'arbitrary private text', url: 'https://private.invalid/' });
    expect(f.buffer().events).toEqual([{ realm: 'worker', operation: 'harden_worker', phase: 'returned', localTimeMs: 3.5,
      timeOriginMs: 1234, elapsedMs: 1, budgetMs: 10000, workerGeneration: 1, sessionGeneration: 2, startupAttempt: 1,
      artifactId: 'DrCNBd66', errorName: 'TypeError' }]);
    expect(JSON.stringify(f.state())).not.toContain('secret'); expect(JSON.stringify(f.state())).not.toContain('private');
    const record = { realm: 'iframe', operation: 'frame_ready', phase: 'sent' };
    f.send(record, { source: {} });
    f.frame.src = runnerURL + '?changed'; f.send(record); f.frame.src = runnerURL;
    f.frame.sandbox.add('allow-same-origin'); f.send(record); f.frame.sandbox.delete('allow-same-origin');
    f.frame.isConnected = false; f.send(record); f.frame.isConnected = true;
    f.send(record, { data: { __oaiDilFrame: true, kind: 'diagnostic', protocolVersion: 13, record } });
    expect(f.buffer().events.length).toBe(1);
  });
  test('does not invoke record getters or retain invalid metadata', () => {
    const f = fixture(); f.install(); let reads = 0;
    const record: any = { realm: 'iframe', operation: 'module_entry', phase: 'returned', localTimeMs: NaN,
      timeOriginMs: Infinity, elapsedMs: -1, budgetMs: 1e16, workerGeneration: 0.5, artifactId: 'secret?query', fault: { name: 'PrivateException' } };
    Object.defineProperty(record, 'data', { get() { reads++; throw new Error('payload'); } });
    Object.defineProperty(record, 'startupAttempt', { get() { reads++; return 1; } });
    f.send(record); expect(reads).toBe(0);
    expect(f.buffer().events).toEqual([{ realm: 'iframe', operation: 'module_entry', phase: 'returned' }]);
    Object.defineProperty(record, 'realm', { get() { reads++; return 'iframe'; } }); f.send(record);
    expect(reads).toBe(0); expect(f.buffer().events.length).toBe(1);
  });
  test('preserves initial and latest evidence within count and byte bounds', () => {
    const f = fixture(); f.install();
    for (let index = 0; index < 100; index++) f.send({ realm: 'worker', operation: 'worker_control', phase: 'received',
      localTimeMs: index, timeOriginMs: 1e15, elapsedMs: 1e15, budgetMs: 1e15, workerGeneration: 1000000,
      sessionGeneration: 1000000, startupAttempt: 1000000, artifactId: 'a'.repeat(64), fault: { name: 'ReferenceError' } });
    expect(f.buffer().events.length).toBeLessThanOrEqual(64); expect(f.buffer().dropped).toBeGreaterThan(0);
    expect(f.buffer().events[0].localTimeMs).toBe(0); expect(f.buffer().events[15].localTimeMs).toBe(15);
    expect(f.buffer().events.at(-1).localTimeMs).toBe(99);
    const projection = { version: 1, ...f.buffer() };
    expect(new TextEncoder().encode(JSON.stringify(projection)).length).toBeLessThanOrEqual(10240);
  });
  test('does not overwrite an existing collector and stops at expiry', () => {
    const f = fixture(); f.install(); const state = f.state(); f.install();
    expect(f.state()).toBe(state); expect(f.calls()).toBe(2); expect(f.listeners.size).toBe(1);
    f.advance(100001); f.send({ realm: 'worker', operation: 'worker_ready', phase: 'sent' });
    expect(state.frames.length).toBe(0); expect(f.listeners.size).toBe(0);
  });
  test('bounds four independent frame buffers without mixing identities', () => {
    const f = fixture(); f.install();
    const second = { ...f.frame, contentWindow: {} }, third = { ...f.frame, contentWindow: {} }, fourth = { ...f.frame, contentWindow: {} };
    f.frames.push(second, third, fourth);
    for (const frame of f.frames) {
      for (let index = 0; index < 80; index++) f.send({ realm: 'worker', operation: 'worker_control', phase: 'received',
        localTimeMs: index, timeOriginMs: 1e15, elapsedMs: 1e15, budgetMs: 1e15, workerGeneration: 1000000,
        sessionGeneration: 1000000, startupAttempt: 1000000, artifactId: 'a'.repeat(64), fault: { name: 'ReferenceError' },
        reason: 'csp_violation' }, { source: frame.contentWindow });
    }
    expect(f.state().frames.length).toBe(4);
    for (const entry of f.state().frames) {
      expect(entry.events.length).toBeLessThanOrEqual(64);
      expect(new TextEncoder().encode(JSON.stringify({ version: 1, ...entry })).length).toBeLessThanOrEqual(10240);
      expect(entry.events.at(-1).localTimeMs).toBe(79);
    }
    expect(f.state().frames[0].iframe).toBe(f.frame); expect(f.state().frames[3].iframe).toBe(fourth);
    expect(JSON.stringify(f.state().frames)).not.toContain(runnerURL);
    expect(f.state().frames[3].events.at(-1).reason).toBe('csp_violation');
    f.timers[0](); expect(f.state().frames.length).toBe(0);
  });
  test('marks incomplete coverage when the finite receiver budget stops collection', () => {
    const f = fixture(); f.install();
    for (let index = 0; index < 1025; index++) f.send({ realm: 'worker', operation: 'worker_ready', phase: 'sent' });
    expect(f.state().saturated).toBe(true); expect(f.listeners.size).toBe(0); expect(f.buffer().dropped).toBeGreaterThan(0);
  });
});
