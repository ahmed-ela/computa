import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';

const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/chatgpt-regex-diagnostic.js', import.meta.url), 'utf8');
function fixture(origin = 'https://chatgpt.com', subframe = false) {
  const context = createContext({ URL, URLSearchParams, TextEncoder });
  const run = (code: string) => runInContext(code, context);
  run(`
    globalThis.window = globalThis; globalThis.top = globalThis;
    globalThis.location = { origin: ${JSON.stringify(origin)}, href: ${JSON.stringify(origin + '/')}, hash: '' };
    globalThis.document = { querySelectorAll: () => [] };
    globalThis.epoch = 1000000; globalThis.clock = 0; globalThis.execDuration = 0;
    globalThis.performance = { now: () => clock }; Date.now = () => epoch;
    globalThis.listeners = new Map(); globalThis.timers = new Map(); globalThis.timerID = 0;
    globalThis.addEventListener = (type, fn) => { if (!listeners.has(type)) listeners.set(type, new Set()); listeners.get(type).add(fn); };
    globalThis.removeEventListener = (type, fn) => listeners.get(type)?.delete(fn);
    globalThis.setTimeout = fn => { const id = ++timerID; timers.set(id, fn); return id; };
    globalThis.clearTimeout = id => timers.delete(id);
    globalThis.emit = type => { for (const fn of [...(listeners.get(type) || [])]) fn(); };
    globalThis.nativeExec = RegExp.prototype.exec;
    globalThis.sentinel = {}; globalThis.throwSentinel = false;
    globalThis.invokeOriginal = (receiver, args) => {
      globalThis.lastThis = receiver; globalThis.lastArgs = args; clock += execDuration;
      if (throwSentinel) throw sentinel;
      return Reflect.apply(nativeExec, receiver, args);
    };
    // The stand-in adds deterministic elapsed time; native matching/getters remain real.
    globalThis.original = (function() { 'use strict'; return function(...args) { return invokeOriginal(this, args); }; })();
    Object.defineProperty(RegExp.prototype, 'exec', { ...Object.getOwnPropertyDescriptor(RegExp.prototype, 'exec'), value: original });
    globalThis.initialDescriptor = Object.getOwnPropertyDescriptor(RegExp.prototype, 'exec');
    globalThis.stackText = 'Error: never retain this message\\n at https://chatgpt.com/cdn/assets/async/87162.8221492420.js:120:9\\n at https://private.invalid/mail?secret=yes:1:2\\n at https://chatgpt.com/cdn/assets/641521.fd69f85d55.js:12:30';
    globalThis.Error = class { constructor() { this.stack = stackText; } };
  `);
  if (subframe) run('globalThis.top = {}');
  const install = (config: any = { expiresAtUnixSeconds: 1100 }) => {
    (context as any).providedConfig = config;
    run(source.replace('__COMPUTA_RENDERER_REGEX_DIAGNOSTIC_CONFIG__', 'providedConfig'));
  };
  return { run, install, state: () => run('globalThis.__computaRendererRegexDiagnosticV1') };
}

describe('private slow RegExp attribution probe', () => {
  test('does not hook without a valid arm or outside the exact top ChatGPT page', () => {
    for (const config of [null, {}, { expiresAtUnixSeconds: true }, { expiresAtUnixSeconds: NaN },
      { expiresAtUnixSeconds: 1000 }, { expiresAtUnixSeconds: 1601 }]) {
      const f = fixture(); f.install(config); expect(f.run('RegExp.prototype.exec === original')).toBe(true); expect(f.state()).toBeUndefined();
    }
    for (const origin of ['https://example.com', 'http://chatgpt.com', 'https://chatgpt.com.example.org']) {
      const f = fixture(origin); f.install(); expect(f.run('RegExp.prototype.exec === original')).toBe(true); expect(f.state()).toBeUndefined();
    }
    const child = fixture('https://chatgpt.com', true); child.install();
    expect(child.run('RegExp.prototype.exec === original')).toBe(true); expect(child.state()).toBeUndefined();
  });
  test('preserves exec and test matches, lastIndex, exact receiver/arguments, and native descriptor', () => {
    const f = fixture(); f.install();
    expect(f.run(`globalThis.re = /a/g; globalThis.output = re.exec('ba', 'unused'); output[0]`)).toBe('a');
    expect(f.run('lastThis === re && lastArgs.length === 2 && lastArgs[1] === "unused"')).toBe(true);
    expect(f.run('re.lastIndex')).toBe(2); expect(f.run("re.test('ba')")).toBe(false); expect(f.run('re.lastIndex')).toBe(0);
    expect(f.run("re.test('ba')")).toBe(true); expect(f.run('re.lastIndex')).toBe(2);
    expect(f.state().records).toHaveLength(0);
    f.run("emit('pagehide')"); expect(f.run('RegExp.prototype.exec === original')).toBe(true);
    expect(f.run('JSON.stringify(Object.getOwnPropertyDescriptor(RegExp.prototype,"exec")) === JSON.stringify(initialDescriptor)')).toBe(true);
    expect(f.state().stopReason).toBe('pagehide');
  });
  test('preserves thrown identity and strict invalid receivers even if diagnostic metadata fails', () => {
    const f = fixture(); f.install(); f.run('execDuration = 150; throwSentinel = true');
    expect(f.run('try { /a/.exec("input"); false; } catch(e) { e === sentinel; }')).toBe(true);
    f.run('throwSentinel = false');
    expect(f.run('try { RegExp.prototype.exec.call(null,"input"); false; } catch(e) { lastThis === null && e instanceof TypeError; }')).toBe(true);
    expect(f.run('try { RegExp.prototype.exec.call(undefined,"input"); false; } catch(e) { lastThis === undefined && e instanceof TypeError; }')).toBe(true);
  });
  test('rolls back an incomplete install and preserves throwing input coercion and sticky matching', () => {
    for (const key of ['addEventListener', 'setTimeout']) {
      const f = fixture(); f.run(`${key} = () => { throw sentinel; }`); f.install();
      expect(f.run('RegExp.prototype.exec === original')).toBe(true); expect(f.state()).toBeUndefined();
    }
    const f = fixture(); f.install(); f.run('execDuration = 100; globalThis.coercions = 0');
    expect(f.run('try { /a/.exec({toString(){coercions++;throw sentinel}}); false; } catch(e) {e === sentinel}')).toBe(true);
    expect(f.run('coercions')).toBe(1); expect(f.state().records[0].inputLength).toBeNull();
    expect(f.run('globalThis.sticky = /a/y; sticky.lastIndex = 1; sticky.exec("ba")[0]')).toBe('a');
    expect(f.run('sticky.lastIndex')).toBe(2); expect(f.run('sticky.exec("ba")')).toBeNull();
    expect(f.run('sticky.lastIndex')).toBe(0);
  });
  test('retains only bounded hashes, lengths, canonical native flags and public stack frames', () => {
    const f = fixture(); f.install(); f.run('execDuration = 150');
    expect(f.run(`globalThis.getterCalls = 0; globalThis.re = /secret-pattern/gim;
      for (const key of ['source','flags','global','ignoreCase','multiline']) Object.defineProperty(re,key,{get(){ getterCalls++; throw sentinel; }});
      re.exec('private input secret-pattern')[0]`)).toBe('secret-pattern');
    expect(f.run('getterCalls')).toBe(0);
    const record = f.state().records[0];
    let hash = 2166136261; for (const char of 'secret-pattern') hash = Math.imul(hash ^ char.charCodeAt(0), 16777619) >>> 0;
    expect(record.patternHash).toBe(hash.toString(16).padStart(8, '0'));
    expect(record.patternLength).toBe(14); expect(record.inputLength).toBe(28); expect(record.flags).toBe('gim');
    expect(record.durationMs).toBe(150); expect(record.startEpochMs).toBe(1000000);
    expect(record.publicStack.split('\n')).toEqual(['https://chatgpt.com/cdn/assets/async/87162.8221492420.js:120:9',
      'https://chatgpt.com/cdn/assets/641521.fd69f85d55.js:12:30']);
    const serialized = JSON.stringify(f.state());
    for (const excluded of ['secret-pattern', 'private input', 'private.invalid', 'never retain', 'secret=yes']) expect(serialized).not.toContain(excluded);
  });
  test('does not coerce an input again and ignores fast, overlong or nonfinite measurements', () => {
    const f = fixture(); f.install(); f.run('execDuration = 100; globalThis.coercions = 0');
    expect(f.run('/a/.exec({toString(){coercions++;return "a"}})[0]')).toBe('a');
    expect(f.run('coercions')).toBe(1); expect(f.state().records[0].inputLength).toBeNull();
    f.run('execDuration = 99; /b/.exec("b")');
    f.run('execDuration = 100; new RegExp("x".repeat(16385)).exec("")');
    f.run('execDuration = Infinity; /a/.exec("a")');
    expect(f.state().records).toHaveLength(1);
  });
  test('aggregates many short calls and original throws without retaining their input or pattern', () => {
    const f = fixture(); f.install(); f.run('execDuration = 25; for(let index=0;index<200;index++) /private/.exec("private input")');
    const snapshot = f.run('__computaRendererRegexDiagnosticV1.snapshot()');
    expect(snapshot).toEqual({version:3,stopReason:'active',records:[],callCount:200,totalDurationMs:5000,maxDurationMs:25,saturated:false});
    f.run('throwSentinel = true; try { /private/.exec("private input") } catch {}');
    expect(f.run('__computaRendererRegexDiagnosticV1.snapshot().callCount')).toBe(201);
    expect(f.run('__computaRendererRegexDiagnosticV1.snapshot().totalDurationMs')).toBe(5025);
    expect(JSON.stringify(snapshot)).not.toContain('private');
    snapshot.callCount = 0; expect(f.state().callCount).toBe(201);
  });
  test('samples only four fixed count checkpoints without claiming their calls were slow', () => {
    const f = fixture(); f.install(); f.run('execDuration = 1');
    for (const count of [250000,500000,750000,1000000]) {
      f.run(`__computaRendererRegexDiagnosticV1.callCount = ${count-2}; /a/g.exec('a')`);
      expect(f.state().records).toHaveLength(count / 250000 - 1);
      f.run("/a/g.exec('a')");
      expect(f.state().records.at(-1).kind).toBe('periodic');
      expect(f.state().records.at(-1).sampleCallCount).toBe(count);
      expect(f.state().records.at(-1).durationMs).toBe(1);
    }
    expect(f.state().records).toHaveLength(4); expect(f.state().callCount).toBe(1000000);
    expect(f.state().saturated).toBe(true); expect(f.state().stopReason).toBe('limit');
    expect(f.run('RegExp.prototype.exec === original')).toBe(true);
    expect(new TextEncoder().encode(JSON.stringify(f.run('__computaRendererRegexDiagnosticV1.snapshot()'))).length).toBeLessThanOrEqual(2304);
    const slow = fixture(); slow.install(); slow.run('execDuration = 100; __computaRendererRegexDiagnosticV1.callCount = 249999; /a/.exec("a")');
    expect(slow.state().records).toHaveLength(1); expect(slow.state().records[0].kind).toBe('slow');
    expect(slow.state().records[0].sampleCallCount).toBe(250000);
  });
  test('bounds aggregate count/time, fails closed for nonfinite clocks, and isolates each realm', () => {
    for (const change of ['__computaRendererRegexDiagnosticV1.callCount = 1000000',
      '__computaRendererRegexDiagnosticV1.totalDurationMs = 1e9', 'execDuration = Infinity']) {
      const f = fixture(); f.install(); f.run('execDuration = 10; ' + change + '; /a/.exec("a")');
      expect(f.state().saturated).toBe(true); expect(f.state().stopReason).toBe('limit');
      expect(f.run('RegExp.prototype.exec === original')).toBe(true);
    }
    const page = fixture(), isolated = fixture(); page.install(); isolated.install();
    page.run('execDuration = 25; /a/.exec("a")'); isolated.run('execDuration = 75; /b/.exec("b"); /b/.exec("b")');
    expect(page.state().callCount).toBe(1); expect(page.state().totalDurationMs).toBe(25);
    expect(isolated.state().callCount).toBe(2); expect(isolated.state().totalDurationMs).toBe(150);
    isolated.run('globalThis.document = {}'); expect(isolated.run('__computaRendererRegexDiagnosticV1.snapshot()')).toBeNull();
    expect(page.run('__computaRendererRegexDiagnosticV1.snapshot()').callCount).toBe(1);
  });
  test('caps four slow calls, stops at expiry, and never overwrites a site replacement', () => {
    const f = fixture(); f.install(); f.run('execDuration = 100; for(let i=0;i<10;i++) /a/.exec("a")');
    expect(f.state().records).toHaveLength(4); expect(f.state().stopReason).toBe('limit');
    expect(f.run('RegExp.prototype.exec === original')).toBe(true);
    expect(new TextEncoder().encode(JSON.stringify(f.run('__computaRendererRegexDiagnosticV1.snapshot()'))).length).toBeLessThanOrEqual(2304);
    const expired = fixture(); expired.install(); expired.run('epoch = 1100001; /a/.exec("a")');
    expect(expired.state().stopReason).toBe('expired'); expect(expired.run('RegExp.prototype.exec === original')).toBe(true);
    const replaced = fixture(); replaced.install();
    replaced.run('globalThis.savedWrapper = RegExp.prototype.exec; globalThis.replacement = function(){return null}; RegExp.prototype.exec = replacement');
    replaced.run("emit('pagehide')"); expect(replaced.state().stopReason).toBe('replaced');
    expect(replaced.run('RegExp.prototype.exec === replacement')).toBe(true);
    const borrowed = fixture(); borrowed.install();
    expect(borrowed.run('const saved = RegExp.prototype.exec; globalThis.replacement = function(){return null}; RegExp.prototype.exec = replacement; saved.call(/a/,"a")[0]')).toBe('a');
    expect(borrowed.state().stopReason).toBe('replaced'); expect(borrowed.run('RegExp.prototype.exec === replacement')).toBe(true);
  });
  test('restores on the expiry timer and bounds complete frames without leaking stack text', () => {
    const f = fixture(); f.install();
    f.run('execDuration = 100; stackText = "Error: private\\n" + "https://chatgpt.com/cdn/assets/123456.0123456789.js:1234567:1234567\\n".repeat(30); /a/.exec("a")');
    expect(f.state().records[0].publicStack.split('\n')).toHaveLength(2);
    expect(f.state().records[0].publicStack.length).toBeLessThanOrEqual(256);
    f.run('epoch = 1100001; for(const fn of [...timers.values()]) fn()');
    expect(f.run('RegExp.prototype.exec === original')).toBe(true); expect(f.state().stopReason).toBe('expired');
  });
});
