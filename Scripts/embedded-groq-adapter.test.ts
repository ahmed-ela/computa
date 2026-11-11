import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { groqChoice, groqFixture, groqGeneration, groqMarker, groqPrompt } from './embedded-groq-adapter-fixture';

const clearedOperation = (f: ReturnType<typeof groqFixture>) => ({ id: '4e40e8a4-876e-4433-90ab-a40b68063177',
  documentGeneration: groqGeneration, sequence: 1, firstUserFingerprint: f.fingerprint });

const unknownBoundNodes = () => ({ rootConnected: null, bodyConnected: null, parentConnected: null,
  rootClassMatches: null, bodyClassMatches: null, rootParentMatches: null, bodyWithinRoot: null,
  rootInDocument: null, preparedEditorConnected: null, preparedEditorDraftRestored: null });
const removedBoundNodes = () => ({ rootConnected: false, bodyConnected: false, parentConnected: true,
  rootClassMatches: true, bodyClassMatches: true, rootParentMatches: false, bodyWithinRoot: true,
  rootInDocument: false, preparedEditorConnected: true, preparedEditorDraftRestored: false });

const appendObservedShowMore = (f: ReturnType<typeof groqFixture>) => {
  const control = new f.Node('SPAN', { class: 'text-primaryaccent cursor-pointer' }, 'Show more');
  f.f.userBody.parentElement.append(control);
  return control;
};

const htmlParagraph = (f: ReturnType<typeof groqFixture>, text = f.f.reply, attributes = {},
  namespace = 'http://www.w3.org/1999/xhtml', attributeNamespace: string | null = null) => {
  const paragraph = new f.Node('P', attributes);
  Object.defineProperties(paragraph, { namespaceURI: { value: namespace }, attributes: {
    get: () => Object.entries(paragraph.values).map(([name, value]) => ({ name, value, namespaceURI: attributeNamespace })),
  } });
  paragraph.append(new f.Node('#text', {}, text));
  f.f.answer.replaceChildren(paragraph);
  return paragraph;
};

describe('Groq fixed fresh-session adapter', () => {

  test('literal structure facts distinguish paragraphs, known code, authored text and misplaced copy without authorizing fallback', async () => {
    const cases = ['paragraph', 'known', 'malformed_known', 'hidden_authored', 'visible_authored', 'misplaced_copy', 'wrong_language', 'hidden_code'] as const;
    for (const mode of cases) {
      const f = groqFixture(); f.f.structuredReply = mode !== 'paragraph';
      f.f.reply = mode === 'malformed_known' ? '{"type":"tool_calls","calls":[}' : '{"type":"message","text":"PRIVATE_RESPONSE_CANARY\\n\\u005f"}';
      await f.submit();
      if (mode === 'hidden_authored' || mode === 'visible_authored') {
        f.f.answer.append(new f.Node('P', mode === 'hidden_authored' ? { hidden: '' } : {}, 'PRIVATE_AUTHORED_CANARY'));
      }
      if (mode === 'misplaced_copy') {
        const chrome = f.f.codeChrome; chrome.remove(); f.f.code.parentElement.append(chrome);
      }
      if (mode === 'wrong_language') f.f.code.setAttribute('class', 'language-javascript PRIVATE_CLASS_CANARY');
      if (mode === 'hidden_code') f.f.code.setAttribute('hidden', '');
      const observed = await f.run(), structure = observed.completionEvidence.codeStructure;
      const reason = mode === 'paragraph' ? 'pre_count'
        : mode === 'hidden_authored' || mode === 'visible_authored' ? 'outside_content'
        : mode === 'misplaced_copy' ? 'wrapper_children'
        : mode === 'wrong_language' ? 'language_json'
        : mode === 'hidden_code' ? 'code_hidden' : 'accepted_literal_code';
      expect(Object.keys(structure).sort()).toEqual(['kind', 'reason', 'preCount', 'codeCount', 'scanCount'].sort());
      expect(structure.kind).toBe('groq_literal_profile_v1'); expect(structure.reason).toBe(reason);
      expect(structure.preCount).toBe(mode === 'paragraph' ? 0 : 2);
      expect(structure.codeCount).toBe(mode === 'paragraph' ? 0 : 1);
      expect(structure.scanCount).toBeGreaterThanOrEqual(0); expect(structure.scanCount).toBeLessThanOrEqual(10_001);
      expect(observed.groqLiteralResponse).toBe(mode === 'known' || mode === 'malformed_known');
      expect(observed.answerComplete).toBe(true); expect(observed.busy).toBe(false);
      if (mode === 'known' || mode === 'malformed_known' || mode === 'paragraph' || mode === 'misplaced_copy'
        || mode === 'wrong_language' || mode === 'hidden_code') expect(observed.text).toBe(f.f.reply);
      if (mode === 'malformed_known') expect(() => JSON.parse(observed.text)).toThrow();
      if (mode === 'paragraph' || mode === 'misplaced_copy') expect(JSON.parse(observed.text).type).toBe('message');
      if (mode === 'hidden_authored' || mode === 'visible_authored') expect(observed.text).toContain('PRIVATE_AUTHORED_CANARY');
      expect(JSON.stringify(structure)).not.toContain('PRIVATE');
      expect(JSON.stringify(structure).length).toBeLessThanOrEqual(512);
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('literal structure reporting keeps original text short circuits and the bounded outside scan', () => {
    const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq.js', import.meta.url), 'utf8');
    const body = source.slice(source.indexOf('  function responseText('), source.indexOf('  function responseComplete('));
    const raw = '{"type":"message","text":"PRIVATE_CODE_CANARY\\n"}';
    const run = (language: boolean, extraWhitespace = 0) => {
      let answerReads = 0, codeReads = 0, visibilityReads = 0, chromeReads = 0, outsideReads = 0;
      const answer: any = { nodeType: 1 }, outer: any = { nodeType: 1 }, wrapper: any = { nodeType: 1, tagName: 'DIV' },
        inner: any = { nodeType: 1 }, code: any = { nodeType: 1 }, icon = { tagName: 'svg', getAttribute: () => 'copy' },
        chrome: any = { nodeType: 1, tagName: 'DIV', children: [icon] };
      outer.parentElement = answer; wrapper.parentElement = outer; inner.parentElement = wrapper; code.parentElement = inner;
      outer.children = outer.childNodes = [wrapper]; wrapper.children = wrapper.childNodes = [inner, chrome]; inner.children = inner.childNodes = [code];
      answer.childNodes = [outer, ...Array.from({ length: extraWhitespace }, () => ({ nodeType: 3,
        get textContent() { outsideReads++; return ' '; } }))];
      Object.defineProperty(answer, 'textContent', { get: () => { answerReads++; return raw; } });
      Object.defineProperty(code, 'textContent', { get: () => { codeReads++; if (!language) throw Error('unreached code text'); return raw; } });
      Object.defineProperty(chrome, 'textContent', { get: () => { chromeReads++; return ''; } });
      const queries: string[] = [];
      const c = { nodes: (_root: any, selector: string, maximum: number) => {
        queries.push(selector); expect(maximum).toBe(64); return selector === 'pre' ? [outer, inner] : [code];
      }, visible: () => { visibilityReads++; if (!language) throw Error('unreached visibility'); return true; } };
      const token = (node: any, _value: string) => node === code ? language : true;
      const extract = new Function('c', 'token', body + '; return responseText;')(c, token);
      const result = extract(answer);
      expect(queries).toEqual(['pre', 'code']);
      expect(JSON.stringify(result.structure)).not.toContain('PRIVATE');
      return { result, answerReads, codeReads, visibilityReads, chromeReads, outsideReads };
    };
    const refused = run(false);
    expect(refused.result.literal).toBe(false); expect(refused.result.text).toBe(raw);
    expect(refused.result.structure.reason).toBe('language_json'); expect(refused.result.structure.scanCount).toBe(0);
    expect(refused.answerReads).toBe(1); expect(refused.codeReads).toBe(0);
    expect(refused.visibilityReads).toBe(0); expect(refused.chromeReads).toBe(0);
    const accepted = run(true);
    expect(accepted.result.literal).toBe(true); expect(accepted.result.text).toBe(raw);
    expect(accepted.result.structure.reason).toBe('accepted_literal_code');
    expect(accepted.answerReads).toBe(0); expect(accepted.codeReads).toBe(1); expect(accepted.chromeReads).toBe(1);
    const limited = run(true, 10_000);
    expect(limited.result.literal).toBe(false); expect(limited.result.structure.reason).toBe('outside_scan_limit');
    expect(limited.result.structure.scanCount).toBe(10_001); expect(limited.outsideReads).toBe(9_994);
    expect(limited.answerReads).toBe(1); expect(limited.codeReads).toBe(0);
  });


  test('optional completion progress preserves the exact ordinary inspect result and never supplies acceptance', async () => {
    const cases: [string, (f: any) => void][] = [
      ['complete', () => {}],
      ['editor_disabled', f => { f.f.editor.disabled = true; }],
      ['editor_not_empty', f => { f.f.editor.value = 'PRIVATE UNEXPECTED DRAFT'; }],
      ['send_disabled', f => { f.f.send.disabled = true; }],
      ['footer_shape', f => { f.f.toolbar.setAttribute('class', 'PRIVATE FOREIGN CLASS'); }],
      ['footer_hidden', f => { f.f.toolbar.setAttribute('hidden', ''); }],
      ['copy_count', f => { f.f.copy.remove(); }],
      ['copy_disabled', f => { f.f.copy.disabled = true; }],
    ];
    for (const [reason, change] of cases) {
      const f = groqFixture({ key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' });
      await f.submit(); await f.run(); change(f);
      const ordinary = await f.run(), reported = await f.run('inspect', { groqFailureProgress: true });
      expect(ordinary.groqFailureProgress).toBeUndefined();
      expect(reported.groqFailureProgress).toEqual({ kind: 'groq_completion_gate_v1', reason });
      const { groqFailureProgress: report, ...same } = reported;
      expect(same).toEqual(ordinary);
      expect(reported.answerComplete).toBe(reason === 'complete');
      expect(reported.busy).toBe(reason !== 'complete');
      expect(JSON.stringify(report)).not.toContain('PRIVATE');
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
      expect((await f.run('inspect', { groqFailureProgress: false })).groqFailureProgress).toBeUndefined();
    }
    const waiting = groqFixture(); waiting.f.delayResponse = true; await waiting.submit(); await waiting.run();
    const pending = await waiting.run('inspect', { groqFailureProgress: true });
    expect(pending.groqFailureProgress).toEqual({ kind: 'groq_completion_gate_v1', reason: 'answer_absent' });
    expect(pending.answerComplete).toBe(false); expect(pending.responseCount).toBe(0);
    const foreign = groqFixture(); await foreign.submit(); await foreign.run();
    foreign.world.__computaModelOwner = 'foreign';
    const refused = await foreign.run('inspect', { groqFailureProgress: true });
    expect(refused.error).toBe('document_changed'); expect(refused.groqFailureProgress).toBeUndefined();
    expect(foreign.f.sendCount).toBe(1);
  });

  test('completion progress names only the first original gate and preserves every DOM read and short circuit', () => {
    const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq.js', import.meta.url), 'utf8');
    const body = source.slice(source.indexOf('  function responseComplete('), source.indexOf('  function read()'));
    const reasons = ['not_submitted', 'cleared', 'user_absent', 'answer_absent', 'text_empty',
      'editor_disabled', 'editor_not_empty', 'send_disabled', 'footer_missing', 'footer_shape', 'footer_hidden',
      'copy_count', 'copy_parent', 'copy_disabled', 'copy_icon_count', 'complete'];
    for (const failure of reasons) {
      const invoke = (reporting: boolean) => {
        const reads: string[] = [];
        const read = <T>(name: string, value: T): T => { reads.push(name); return value; };
        const footer = { get tagName() { return read('footer.tag', 'DIV'); } };
        const answer = { contains: (_node: any) => read('answer.contains', false) };
        const editor = { get value() { return read('editor.value', failure === 'editor_not_empty' ? 'PRIVATE DRAFT' : ''); } };
        const send = {}, copy = { get parentElement() { return read('copy.parent', failure === 'copy_parent' ? {} : footer); } };
        const state = { get submitted() { return read('submitted', failure !== 'not_submitted'); },
          get clear() { return read('clear', failure === 'cleared'); } };
        const t = { get first() { return read('first', failure === 'user_absent' ? null : {}); },
          get answer() { return read('answer', failure === 'answer_absent' ? null : answer); },
          block: { get children() { return read('children', failure === 'footer_missing' ? [answer] : [answer, footer]); } } };
        let copyReads = 0;
        const c = {
          enabled: (node: any) => read(node === editor ? 'editor.enabled' : node === send ? 'send.enabled' : 'copy.enabled',
            !(node === editor && failure === 'editor_disabled' || node === send && failure === 'send_disabled'
              || node === copy && failure === 'copy_disabled')),
          visible: (_node: any) => read('footer.visible', failure !== 'footer_hidden'),
          nodes: (root: any, _selector: string, _max: number) => {
            if (root === t.block) return read('copies', failure === 'copy_count' ? [] : [copy]);
            copyReads++; return read('copy.icons', Array.from({ length: failure === 'copy_icon_count' && copyReads === 2 ? 2 : 1 }, () => ({})));
          },
        };
        const token = (_node: any, key: string) => read('class.' + key, failure !== 'footer_shape');
        const complete = new Function('state', 'c', 'token', body + '; return responseComplete;')(state, c, token);
        const progress = reporting ? { reason: null } : null;
        const accepted = complete(t, { editor, send }, failure === 'text_empty' ? ' \n ' : 'PRIVATE RESPONSE', progress);
        return { accepted, progress, reads };
      };
      const ordinary = invoke(false), diagnostic = invoke(true);
      expect(diagnostic.accepted).toBe(failure === 'complete');
      expect(diagnostic.progress).toEqual({ reason: failure });
      expect(diagnostic.reads).toEqual(ordinary.reads);
      if (failure === 'not_submitted') expect(diagnostic.reads).toEqual(['submitted']);
      if (failure === 'editor_disabled') expect(diagnostic.reads).not.toContain('editor.value');
      if (failure === 'footer_shape') expect(diagnostic.reads).not.toContain('footer.visible');
      if (failure === 'copy_parent') expect(diagnostic.reads).not.toContain('copy.enabled');
      expect(JSON.stringify(diagnostic.progress)).not.toContain('PRIVATE');
    }
  });
  test('standalone source embeds only the small audited core exactly', () => {
    const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
    const source = readFileSync(new URL('../Sources/Computa/Resources/BrowserModels/groq.js', import.meta.url), 'utf8');
    expect(source.startsWith(core + '\n')).toBe(true);
    expect(source).not.toContain('websiteChat');
    expect(source).not.toContain('claude.ai');
    expect(source).not.toContain('gemini.google.com');
  });

  test('fresh inspection reports explicit clear, never temporary mode or inferred model evidence', async () => {
    const f = groqFixture(), observed = await f.run();
    expect(observed.error).toBeUndefined();
    expect(observed.sessionLifecycle).toBe('explicit_clear'); expect(observed.temporary).toBe(false);
    expect(observed.userCount).toBe(0); expect(observed.responseCount).toBe(0);
    expect(observed.modelEvidence).toBeNull(); expect(observed.answerComplete).toBe(false);
    expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
  });

  test('discovery uses observed option IDs and excludes specialized classifiers', async () => {
    const f = groqFixture();
    let result: any;
    for (let index = 0; index < 4; index++) { result = await f.run('discoverModels'); if (!result.pending) break; }
    expect(result.modelChoices).toEqual([groqChoice,
      { key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' }, { key: 'openai/gpt-oss-20b', label: 'GPT OSS 20B' }]);
    expect(f.f.pickerOpens).toBe(1); expect(f.f.dialog).toBeNull();
    expect(result.modelEvidence.selected).toEqual(groqChoice);
  });

  test('new ordinary observed rows are discovered without a hardcoded fallback list', async () => {
    const f = groqFixture(); f.f.choices.push(['vendor/new-text-model', 'Future Text Model']);
    await f.run('discoverModels'); await f.run('discoverModels');
    expect((await f.run('discoverModels')).modelChoices).toContainEqual({ key: 'vendor/new-text-model', label: 'Future Text Model' });
  });

  test('cmdk focused row never substitutes for the URL and actual trigger model', async () => {
    const choice = { key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' }, f = groqFixture(choice);
    const result = await f.select();
    expect(result.modelEvidence.selected).toEqual(choice);
    expect(f.f.pickerOpens).toBe(1);
  });

  test('duplicate or disabled choices and foreign dialogs cannot supply selected proof', async () => {
    const duplicate = groqFixture(); duplicate.f.choices.push([groqChoice.key, 'Second Label']);
    await duplicate.run('selectModel'); expect((await duplicate.run('selectModel')).error).toBe('model_unverified');
    const disabled = groqFixture(); await disabled.run('selectModel');
    const option = disabled.f.dialog.querySelector('[data-value="qwen/qwen3.8-27b"]'); option.values['aria-disabled'] = 'true';
    await disabled.run('selectModel'); expect((await disabled.run('selectModel')).error).toBe('model_unverified');
    const foreign = groqFixture(); foreign.body.append(new foreign.Node('DIV', { role: 'dialog', id: 'foreign' }));
    expect((await foreign.run('selectModel')).error).toBe('model_unverified');
    expect(foreign.f.pickerOpens).toBe(0);
  });

  test('missing or changed native model/query cannot click a different option', async () => {
    const f = groqFixture();
    expect((await f.run('selectModel', { modelChoice: { key: 'other/model', label: 'Other' } })).error).toBe('model_mismatch');
    expect(f.f.pickerOpens).toBe(0); expect(f.f.sendCount).toBe(0);
  });

  test('lost picker and close acknowledgments never toggle or replay a clicked stage', async () => {
    const f = groqFixture(); f.f.ignoreEscape = true;
    await f.run('selectModel'); await f.run('selectModel'); await f.run('selectModel'); await f.run('selectModel');
    expect(f.f.pickerOpens).toBe(1); expect(f.f.trigger.clicks).toBe(1);
    expect(f.f.dialog.events.filter((event: any) => event.type === 'keydown').length).toBe(1);
    expect(f.f.sendCount).toBe(0);
  });

  test('literal textarea insertion preserves whitespace, Unicode and one Send', async () => {
    const f = groqFixture(); await f.select();
    const prompt = '  Use `quotes` and C++\n  two spaces\u00a0NBSP\n\nComputa session marker: ' + groqMarker;
    expect((await f.run('prepare')).prepared).toBe(true);
    expect((await f.run('insert', { prompt })).inserted).toBe(true);
    expect(f.f.editor.value).toBe(prompt); expect(f.f.mobileEditor.value).toBe('');
    expect((await f.run('sendReady', { prompt })).sendReady).toBe(true);
    expect(await f.run('submit', { prompt })).toMatchObject({ submitted: true,
      sessionLifecycle: 'explicit_clear', temporary: false, userCount: 0, responseCount: 0, firstUserVerified: false });
    const observed = await f.run(); expect(observed.firstUserVerified).toBe(true);
    expect(observed.firstUserFingerprint).toMatch(/^[0-9a-f]{64}$/);
    expect(f.f.sendCount).toBe(1); expect(f.f.mobileSend.clicks).toBe(0);
    expect((await f.run('submit', { prompt })).error).toBeDefined(); expect(f.f.sendCount).toBe(1);
  });

  test('human drafts, ambiguous responsive forms and occluded controls do not receive input', async () => {
    const draft = groqFixture(); await draft.select(); draft.f.editor.value = 'Human draft';
    expect((await draft.run('prepare')).error).toBeDefined(); expect(draft.f.editor.value).toBe('Human draft');
    const ambiguous = groqFixture(); ambiguous.f.mobileForm.removeAttribute('hidden');
    expect((await ambiguous.run()).error).toBe('document_changed');
    const occluded = groqFixture(); await occluded.select(); occluded.blockHit(true);
    expect((await occluded.run('prepare')).error).toBe('composer_unavailable');
    expect(occluded.f.editor.value).toBe(''); expect(occluded.f.sendCount).toBe(0);
  });

  test('composer failures return only the actual closed predicate and preserve short-circuit order', async () => {
    const cases = [
      ['editor_missing', (f: any) => { f.f.editor.setAttribute('hidden', ''); }],
      ['editor_ambiguous', (f: any) => { f.f.mobileForm.removeAttribute('hidden'); }],
      ['form_missing', (f: any) => {
        const original = f.f.editor.closest.bind(f.f.editor);
        f.f.editor.closest = (selector: string) => selector === 'form' ? null : original(selector);
      }],
      ['form_hidden', (f: any) => { f.f.form.values.visibility = 'hidden'; }],
      ['form_editor_count', (f: any) => {
        const original = f.f.form.querySelectorAll.bind(f.f.form);
        f.f.form.querySelectorAll = (selector: string) => selector === 'textarea#chat' ? [] : original(selector);
      }],
      ['editor_disabled', (f: any) => { f.f.editor.disabled = true; f.blockHit(true); f.f.editor.value = 'private draft'; }],
      ['editor_hit_test', (f: any) => { f.blockHit(true); f.f.editor.value = 'private draft'; }],
      ['editor_not_fresh', (f: any) => { f.f.editor.value = 'private draft'; }],
    ] as const;
    for (const [detail, mutate] of cases) {
      const f = groqFixture(); await f.select(); mutate(f);
      const result = await f.run('prepare');
      expect(result).toEqual({ error: 'composer_unavailable', detail });
      expect(JSON.stringify(result)).not.toContain('private draft');
      expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
    }
  });

  test('hit testing uses one visible intersection point and leaves an in-view center unchanged', async () => {
    const cases = [
      [{ left: 24, top: 40, width: 600, height: 120 }, [324, 100]],
      [{ left: 24, top: -2000, width: 600, height: 2744 }, [324, 372]],
      [{ left: 24, top: 700, width: 600, height: 1000 }, [324, 734]],
      [{ left: -2000, top: 40, width: 2600, height: 120 }, [300, 100]],
      [{ left: 1000, top: 40, width: 600, height: 120 }, [1012, 100]],
      [{ left: -1000, top: -2000, width: 4000, height: 5000 }, [512, 384]],
    ] as const;
    for (const [rect, point] of cases) {
      const f = groqFixture(); await f.select(); f.f.editor.rect = { ...rect }; f.hitQueries.length = 0;
      expect((await f.run('prepare')).prepared).toBe(true);
      expect(f.hitQueries.map(({ x, y }) => [x, y])).toEqual([point]);
      expect(f.hitQueries[0].node).toBe(f.f.editor);
      expect(f.f.editor.value).toBe(''); expect(f.f.sendCount).toBe(0);
    }
  });

  test('empty, offscreen, nonfinite and invalid viewport geometry never falls back to another point', async () => {
    const rectangles = [
      { left: -100, top: 0, width: 100, height: 30 },
      { left: 1024, top: 0, width: 100, height: 30 },
      { left: 0, top: -30, width: 100, height: 30 },
      { left: 0, top: 768, width: 100, height: 30 },
      { left: 0, top: 0, width: 0, height: 30 },
      { left: 0, top: 0, width: 100, height: -1 },
      { left: NaN, top: 0, width: 100, height: 30 },
      { left: 0, top: -Infinity, width: 100, height: 30 },
      { left: 0, top: 0, width: Infinity, height: 30 },
      { left: Number.MAX_VALUE, top: 0, width: Number.MAX_VALUE, height: 30 },
    ];
    const changes: ((f: ReturnType<typeof groqFixture>) => void)[] = rectangles.map(rect => f => { f.f.editor.rect = rect; });
    for (const key of ['innerWidth', 'innerHeight']) for (const value of [0, -1, NaN, Infinity, undefined]) {
      changes.push(f => { f.window[key] = value; });
    }
    for (const change of changes) {
      const f = groqFixture(); await f.select(); change(f); f.hitQueries.length = 0;
      expect(await f.run('prepare')).toEqual({ error: 'composer_unavailable', detail: 'editor_hit_test' });
      expect(f.hitQueries).toEqual([]); expect(f.f.editor.value).toBe(''); expect(f.f.sendCount).toBe(0);
    }
  });

  test('an expanded editor still rejects an overlay or ancestor clipping at its sole visible point', async () => {
    for (const returned of ['overlay', 'null', 'ancestor'] as const) {
      const f = groqFixture(); await f.select(); f.f.editor.rect = { left: 24, top: -2000, width: 600, height: 2744 };
      const original = f.document.elementFromPoint;
      f.document.elementFromPoint = (x: number, y: number) => {
        original(x, y);
        return returned === 'null' ? null : returned === 'ancestor' ? f.f.form : f.body;
      };
      f.hitQueries.length = 0;
      expect(await f.run('prepare')).toEqual({ error: 'composer_unavailable', detail: 'editor_hit_test' });
      expect(f.hitQueries.map(({ x, y }) => [x, y])).toEqual([[324, 372]]);
      expect(f.f.editor.value).toBe(''); expect(f.f.sendCount).toBe(0);
    }
  });

  test('visible geometry does not authorize disabled, hidden, inert, ambiguous or human-draft editors', async () => {
    const changes = [
      (f: any) => { f.f.editor.disabled = true; },
      (f: any) => { f.f.editor.setAttribute('aria-disabled', 'true'); },
      (f: any) => { f.f.editor.setAttribute('hidden', ''); },
      (f: any) => { f.f.form.setAttribute('inert', ''); },
      (f: any) => { f.f.form.setAttribute('aria-hidden', 'true'); },
      (f: any) => { f.f.mobileForm.removeAttribute('hidden'); },
      (f: any) => { f.f.editor.value = 'Human draft'; },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.select(); f.f.editor.rect = { left: 24, top: -2000, width: 600, height: 2744 };
      change(f); const before = f.f.editor.value;
      expect((await f.run('prepare')).error).toBeDefined();
      expect(f.f.editor.value).toBe(before); expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
    }
  });

  test('input-driven expansion gets a fresh hit check at readiness and again before one Send', async () => {
    const f = groqFixture(); await f.select(); await f.run('prepare');
    f.f.editor.oninput = () => { f.f.editor.rect = { left: 24, top: -2000, width: 600, height: 2744 }; };
    expect((await f.run('insert', { prompt: groqPrompt })).inserted).toBe(true);
    f.hitQueries.length = 0;
    expect((await f.run('sendReady', { prompt: groqPrompt })).sendReady).toBe(true);
    expect(f.hitQueries.filter(({ node }) => node === f.f.editor).map(({ x, y }) => [x, y])).toEqual([[324, 372]]);
    const original = f.document.elementFromPoint;
    f.document.elementFromPoint = (x: number, y: number) => { const hit = original(x, y); return hit === f.f.editor ? f.body : hit; };
    expect(await f.run('submit', { prompt: groqPrompt })).toEqual({ error: 'composer_unavailable', detail: 'editor_hit_test' });
    expect(f.f.sendCount).toBe(0); expect(f.f.editor.value).toBe(groqPrompt);
    // A separate fresh case proves the unobscured path, without retrying the blocked attempt.
    const clear = groqFixture(); await clear.select(); await clear.run('prepare');
    clear.f.editor.oninput = () => { clear.f.editor.rect = { left: 24, top: -2000, width: 600, height: 2744 }; };
    await clear.run('insert', { prompt: groqPrompt });
    expect((await clear.run('sendReady', { prompt: groqPrompt })).sendReady).toBe(true);
    expect((await clear.run('submit', { prompt: groqPrompt })).submitted).toBe(true);
    expect((await clear.run()).firstUserVerified).toBe(true); expect(clear.f.sendCount).toBe(1);
  });

  test('a visible editor cannot bypass model, owner, document, prompt or Send-control changes after readiness', async () => {
    const changes = [
      (f: any) => { f.f.trigger.text = 'Other model'; },
      (f: any) => { f.world.__computaModelOwner = 'foreign'; },
      (f: any) => { f.document.URL += '&foreign=1'; },
      (f: any) => { f.world.__computaGroqFreshSessionV1.generation = 'foreign'; },
      (f: any) => { f.f.editor.value += 'changed'; },
      (f: any) => { f.f.send.disabled = true; },
      (f: any) => { f.f.send.rect = { left: 1024, top: 0, width: 100, height: 30 }; },
      (f: any) => { const original = f.document.elementFromPoint;
        f.document.elementFromPoint = (x: number, y: number) => { const hit = original(x, y); return hit === f.f.send ? f.body : hit; }; },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.select(); f.f.editor.rect = { left: 24, top: -2000, width: 600, height: 2744 };
      await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      expect((await f.run('sendReady', { prompt: groqPrompt })).sendReady).toBe(true);
      change(f); expect((await f.run('submit', { prompt: groqPrompt })).error).toBeDefined();
      expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
    }
  });

  test('an expanded editor never grants another Send after a lost click acknowledgment', async () => {
    for (const dispatched of [false, true]) {
      const f = groqFixture(); await f.select(); f.f.editor.rect = { left: 24, top: -2000, width: 600, height: 2744 };
      await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      const original = f.f.send.onclick;
      f.f.send.onclick = (event: any) => { if (dispatched) original(event); throw new Error('Synthetic lost acknowledgment'); };
      await expect(f.run('submit', { prompt: groqPrompt })).rejects.toThrow('Synthetic lost acknowledgment');
      expect(f.f.sendCount).toBe(dispatched ? 1 : 0);
      expect((await f.run('submit', { prompt: groqPrompt })).error).toBeDefined();
      expect(f.f.send.clicks).toBe(1); expect(f.f.sendCount).toBe(dispatched ? 1 : 0);
    }
  });

  test('Send readiness reports only the actual finite reason without another hit probe or dispatch', async () => {
    const cases = [
      ['disabled', (f: any) => { f.f.send.disabled = true; }, 0],
      ['invalid_geometry', (f: any) => { f.f.send.getBoundingClientRect = null; }, 0],
      ['invalid_geometry', (f: any) => { f.f.send.rect.left = 'PRIVATE_SEND_GEOMETRY'; }, 0],
      ['outside_viewport', (f: any) => { f.f.send.rect.top = 768; }, 0],
      ['occluded', (f: any) => { const original = f.document.elementFromPoint;
        f.document.elementFromPoint = (x: number, y: number) => { const hit = original(x, y); return hit === f.f.send ? f.body : hit; }; }, 1],
    ] as const;
    for (const [reason, change, probes] of cases) {
      const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      f.f.send.textContent = 'PRIVATE_SEND_LABEL';
      f.f.send.append(new f.Node('SVG', { 'aria-label': 'send' }));
      change(f); f.hitQueries.length = 0;
      const result = await f.run('sendReady', { prompt: groqPrompt });
      expect(result.error).toBeUndefined(); expect(result.sendReady).toBe(false);
      expect(result.sendReadinessFailure).toBe(reason);
      expect(f.hitQueries.filter(({ node }) => node === f.f.send).length).toBe(probes);
      expect(JSON.stringify(result)).not.toContain('PRIVATE_SEND');
      expect(f.f.sendCount).toBe(0); expect(f.f.editor.value).toBe(groqPrompt);
      // The separate submit action rechecks the same guard and still cannot click.
      expect(await f.run('submit', { prompt: groqPrompt })).toEqual({ error: 'send_unavailable', detail: reason });
      expect(f.f.sendCount).toBe(0);
    }
  });

  test('readiness retains the evaluated failure even if a later probe would see a different hit', async () => {
    const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
    const original = f.document.elementFromPoint; let sendProbes = 0;
    f.document.elementFromPoint = (x: number, y: number) => {
      const hit = original(x, y);
      if (hit !== f.f.send) return hit;
      sendProbes++; f.document.elementFromPoint = original;
      return f.body;
    };
    const result = await f.run('sendReady', { prompt: groqPrompt });
    expect(result.sendReady).toBe(false); expect(result.sendReadinessFailure).toBe('occluded');
    expect(sendProbes).toBe(1); expect(f.f.sendCount).toBe(0);
  });

  test('ready has no failure reason and the final editor-enabled check keeps its original order', async () => {
    const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
    f.hitQueries.length = 0;
    const ready = await f.run('sendReady', { prompt: groqPrompt });
    expect(ready.sendReady).toBe(true); expect(ready.sendReadinessFailure).toBeNull();
    expect(f.hitQueries.filter(({ node }) => node === f.f.send).length).toBe(1);
    expect(f.f.sendCount).toBe(0);
    const original = f.document.elementFromPoint;
    f.document.elementFromPoint = (x: number, y: number) => {
      const hit = original(x, y); if (hit === f.f.send) f.f.editor.disabled = true;
      return hit;
    };
    const changed = await f.run('sendReady', { prompt: groqPrompt });
    expect(changed.sendReady).toBe(false); expect(changed.sendReadinessFailure).toBe('disabled');
    expect(f.f.sendCount).toBe(0);
  });

  test('missing and ambiguous Send controls report fixed details without exposing control text', async () => {
    for (const ambiguity of [false, true]) {
      const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      if (ambiguity) {
        const extra = new f.Node('BUTTON', { type: 'submit' }, 'PRIVATE_DUPLICATE_SEND');
        extra.append(new f.Node('SVG', { 'aria-label': 'send' })); f.f.form.append(extra);
      } else f.f.send.remove();
      expect(await f.run('sendReady', { prompt: groqPrompt })).toEqual({ error: 'send_unavailable',
        detail: ambiguity ? 'send_ambiguous' : 'send_missing' });
      expect(f.f.sendCount).toBe(0); expect(f.f.editor.value).toBe(groqPrompt);
    }
  });

  test('only readiness reveals the exact offscreen Send once before a verified single submission', async () => {
    const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
    f.f.send.rect.top = 900; let scrolls = 0;
    f.f.send.scrollIntoView = function (options: any) {
      expect(this).toBe(f.f.send); expect(options).toEqual({ block: 'center', inline: 'nearest' });
      scrolls++; this.rect.top = 600;
    };
    f.hitQueries.length = 0;
    const ready = await f.run('sendReady', { prompt: groqPrompt });
    expect(ready.sendReady).toBe(true); expect(ready.sendReadinessFailure).toBeNull();
    expect(ready.sendRevealDiagnostic).toEqual({ before: 'outside_viewport', after: null, attempted: true });
    expect(f.hitQueries.filter(({ node }) => node === f.f.send).length).toBe(1);
    expect(f.f.editor.value).toBe(groqPrompt); expect(f.f.sendCount).toBe(0); expect(scrolls).toBe(1);
    expect((await f.run('sendReady', { prompt: groqPrompt })).sendRevealDiagnostic).toEqual(ready.sendRevealDiagnostic);
    expect((await f.run('submit', { prompt: groqPrompt })).submitted).toBe(true);
    expect((await f.run()).firstUserVerified).toBe(true);
    expect(f.f.sendCount).toBe(1); expect(scrolls).toBe(1);
    expect((await f.run('submit', { prompt: groqPrompt })).error).toBeDefined(); expect(f.f.sendCount).toBe(1);
  });

  test('disabled, invalid, occluded, missing and ambiguous Send controls never trigger reveal', async () => {
    const changes = [
      (f: any) => { f.f.send.rect.top = 900; f.f.send.disabled = true; },
      (f: any) => { f.f.send.rect.width = NaN; },
      (f: any) => { const original = f.document.elementFromPoint;
        f.document.elementFromPoint = (x: number, y: number) => { const hit = original(x, y); return hit === f.f.send ? f.body : hit; }; },
      (f: any) => { f.f.send.remove(); },
      (f: any) => { const duplicate = new f.Node('BUTTON', { type: 'submit' });
        duplicate.append(new f.Node('SVG', { 'aria-label': 'send' })); f.f.form.append(duplicate); },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      let scrolls = 0; f.f.send.scrollIntoView = () => { scrolls++; };
      change(f); const observed = await f.run('sendReady', { prompt: groqPrompt });
      expect(observed.sendReady === true).toBe(false); expect(observed.sendRevealDiagnostic).toBeUndefined();
      expect(scrolls).toBe(0); expect(f.f.sendCount).toBe(0);
    }
    const submit = groqFixture(); await submit.select(); await submit.run('prepare'); await submit.run('insert', { prompt: groqPrompt });
    submit.f.send.rect.top = 900; let scrolls = 0;
    submit.f.send.scrollIntoView = () => { scrolls++; submit.f.send.rect.top = 600; };
    expect(await submit.run('submit', { prompt: groqPrompt })).toEqual({ error: 'send_unavailable', detail: 'outside_viewport' });
    expect(scrolls).toBe(0); expect(submit.f.sendCount).toBe(0);
  });

  test('ignored or delayed reveal is observation-only and keeps the original finite decision', async () => {
    const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
    f.f.send.rect.top = 900; let scrolls = 0; f.f.send.scrollIntoView = () => { scrolls++; };
    for (let i = 0; i < 4; i++) {
      const pending = await f.run('sendReady', { prompt: groqPrompt });
      expect(pending.sendReady).toBe(false); expect(pending.sendReadinessFailure).toBe('outside_viewport');
      expect(pending.sendRevealDiagnostic).toEqual({ before: 'outside_viewport', after: 'outside_viewport', attempted: true });
    }
    expect(scrolls).toBe(1); expect(f.f.sendCount).toBe(0);
    f.f.send.rect.top = 600;
    const ready = await f.run('sendReady', { prompt: groqPrompt });
    expect(ready.sendReady).toBe(true); expect(ready.sendReadinessFailure).toBeNull();
    expect(ready.sendRevealDiagnostic.after).toBe('outside_viewport');
    expect((await f.run('submit', { prompt: groqPrompt })).submitted).toBe(true);
    expect(scrolls).toBe(1); expect(f.f.sendCount).toBe(1);
  });

  test('a lost reveal acknowledgment cannot repeat scrolling or grant Send even if the button moved', async () => {
    for (const moved of [false, true]) {
      const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      f.f.send.rect.top = 900; let scrolls = 0;
      f.f.send.scrollIntoView = () => { scrolls++; if (moved) f.f.send.rect.top = 600; throw new Error('PRIVATE_SCROLL_EXCEPTION'); };
      for (const action of ['sendReady', 'sendReady', 'submit']) {
        const failure = await f.run(action, { prompt: groqPrompt });
        expect(failure).toEqual({ error: 'send_unavailable', detail: 'reveal_unconfirmed' });
        expect(JSON.stringify(failure)).not.toContain('PRIVATE_SCROLL');
      }
      expect(scrolls).toBe(1); expect(f.f.sendCount).toBe(0);
    }
  });

  test('scroll-induced identity, ownership, prompt, model and editor drift stops without Send', async () => {
    const changes = [
      (f: any) => { f.world.__computaModelOwner = 'foreign'; },
      (f: any) => { f.document.URL += '&foreign=1'; },
      (f: any) => { f.world.__computaGroqFreshSessionV1.generation = 'foreign'; },
      (f: any) => { f.world.__computaGroqFreshSessionV1 = { ...f.world.__computaGroqFreshSessionV1 }; },
      (f: any) => { f.f.trigger.text = 'Other model'; },
      (f: any) => { f.f.editor.value += 'PRIVATE_CHANGED_PROMPT'; },
      (f: any) => { f.f.appendUser(groqPrompt); },
      (f: any) => { const replacement = new f.Textarea('TEXTAREA', { id: 'chat' });
        replacement.value = groqPrompt; f.f.editor.remove(); f.f.form.append(replacement); },
      (f: any) => { const replacement = new f.Node('FORM');
        replacement.append(f.f.editor, f.f.send); f.f.form.remove(); f.body.append(replacement); },
      (f: any) => { const replacement = new f.Node('BUTTON', { type: 'submit' });
        replacement.append(new f.Node('SVG', { 'aria-label': 'send' })); f.f.send.remove(); f.f.form.append(replacement); },
      (f: any) => { f.f.editor.disabled = true; },
      (f: any) => { f.f.editor.rect.top = 900; },
      (f: any) => { f.f.form.setAttribute('inert', ''); },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.select(); await f.run('prepare'); await f.run('insert', { prompt: groqPrompt });
      f.f.send.rect.top = 900; let scrolls = 0;
      f.f.send.scrollIntoView = () => { scrolls++; f.f.send.rect.top = 600; change(f); };
      expect((await f.run('sendReady', { prompt: groqPrompt })).error).toBeDefined();
      expect((await f.run('submit', { prompt: groqPrompt })).error).toBeDefined();
      expect(scrolls).toBe(1); expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
    }
  });

  test('post-reveal obstruction remains blocked and target substitution between readiness and submit cannot borrow proof', async () => {
    const blocked = groqFixture(); await blocked.select(); await blocked.run('prepare'); await blocked.run('insert', { prompt: groqPrompt });
    blocked.f.send.rect.top = 900; let scrolls = 0;
    blocked.f.send.scrollIntoView = () => {
      scrolls++; blocked.f.send.rect.top = 600;
      const original = blocked.document.elementFromPoint;
      blocked.document.elementFromPoint = (x: number, y: number) => { const hit = original(x, y); return hit === blocked.f.send ? blocked.body : hit; };
    };
    const pending = await blocked.run('sendReady', { prompt: groqPrompt });
    expect(pending.sendReady).toBe(false); expect(pending.sendReadinessFailure).toBe('occluded');
    expect(pending.sendRevealDiagnostic).toEqual({ before: 'outside_viewport', after: 'occluded', attempted: true });
    expect((await blocked.run('sendReady', { prompt: groqPrompt })).sendReady).toBe(false);
    expect(scrolls).toBe(1); expect(blocked.f.sendCount).toBe(0);
    const replaced = groqFixture(); await replaced.select(); await replaced.run('prepare'); await replaced.run('insert', { prompt: groqPrompt });
    replaced.f.send.rect.top = 900; let reveals = 0;
    replaced.f.send.scrollIntoView = () => { reveals++; replaced.f.send.rect.top = 600; };
    expect((await replaced.run('sendReady', { prompt: groqPrompt })).sendReady).toBe(true);
    const duplicate = new replaced.Node('BUTTON', { type: 'submit' });
    duplicate.append(new replaced.Node('SVG', { 'aria-label': 'send' })); replaced.f.send.remove(); replaced.f.form.append(duplicate);
    expect((await replaced.run('submit', { prompt: groqPrompt })).error).toBe('conversation_changed');
    expect(reveals).toBe(1); expect(replaced.f.sendCount).toBe(0); expect(duplicate.clicks).toBe(0);
  });

  test('editor substitution and missing exact final marker stop before Send', async () => {
    const f = groqFixture(); await f.select(); await f.run('prepare');
    f.f.editor.oninput = () => { f.f.editor.value += 'changed'; };
    expect((await f.run('insert', { prompt: groqPrompt })).error).toBe('prompt_not_inserted');
    expect((await f.run('submit', { prompt: groqPrompt })).error).toBeDefined(); expect(f.f.sendCount).toBe(0);
    const missing = groqFixture(); await missing.select(); await missing.run('prepare');
    expect((await missing.run('insert', { prompt: 'No marker' })).error).toBe('prompt_not_inserted');
    expect(missing.f.editor.value).toBe('');
  });

  test('submitted ownership requires exact full user text, not only a matching marker', async () => {
    const f = groqFixture(); await f.submit(); f.f.userBody.textContent = 'Foreign middle\n\nComputa session marker: ' + groqMarker;
    expect((await f.run()).error).toBe('conversation_changed'); expect(f.f.clearCount).toBe(0);
    const unclaimed = groqFixture(); await unclaimed.select(); unclaimed.f.appendResponse(groqPrompt);
    expect((await unclaimed.run('inspect', { expectedUserCounts: [1], allowFirstUserBinding: true })).error).toBe('conversation_changed');
  });

  test('user-count diagnostics identify the original branch and hidden duplicates without actions or raw text', async () => {
    const answer = (f: ReturnType<typeof groqFixture>) => {
      const parent = new f.Node('DIV', { class: 'font-normal text-base' });
      const child = new f.Node('DIV', { class: 'font-inter' }, 'PRIVATE ANSWER'); parent.append(child); f.body.append(parent); return child;
    };
    const scenarios = [
      { branch: 'multiple_users', users: 2, answers: 0, visibleUsers: 1, visibleAnswers: 0,
        mutate: (f: ReturnType<typeof groqFixture>) => {
          f.body.append(new f.Node('DIV', { class: 'group/input' }, 'PRIVATE USER'));
          f.body.append(new f.Node('DIV', { class: 'group/input', hidden: '' }, 'PRIVATE HIDDEN USER'));
        } },
      { branch: 'multiple_answers', users: 0, answers: 2, visibleUsers: 0, visibleAnswers: 1,
        mutate: (f: ReturnType<typeof groqFixture>) => { answer(f); answer(f).setAttribute('hidden', ''); } },
      { branch: 'answer_without_user', users: 0, answers: 1, visibleUsers: 0, visibleAnswers: 1,
        mutate: (f: ReturnType<typeof groqFixture>) => { answer(f); } },
    ];
    for (const scenario of scenarios) {
      const f = groqFixture(); await f.select(); scenario.mutate(f);
      let userQueries = 0, answerQueries = 0;
      const query = f.document.querySelectorAll;
      f.document.querySelectorAll = (selector: string) => {
        if (selector === '[class*="group/input"]') userQueries++;
        if (selector === '.font-inter') answerQueries++;
        return query(selector);
      };
      const result = await f.run();
      expect(result).toEqual({ error: 'conversation_changed', detail: 'user_count', groqUserCountDiagnostic: {
        kind: 'groq_user_count_v2', action: 'inspect', branch: scenario.branch,
        userCount: scenario.users, answerCount: scenario.answers,
        visibleUserCount: scenario.visibleUsers, visibleAnswerCount: scenario.visibleAnswers,
        expectedUserCounts: [0], submitted: false, adapterFirstBound: false, boundNodes: unknownBoundNodes() } });
      expect(JSON.stringify(result)).not.toContain('PRIVATE');
      expect([userQueries, answerQueries]).toEqual([1, 1]);
      expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0); expect(f.f.pickerOpens).toBe(1);
    }
  });

  test('user-count diagnostic distinguishes a bound missing row from an allowed initial render gap', async () => {
    const f = groqFixture(); f.f.delayResponse = true; await f.submit();
    const user = f.f.user; user.remove();
    const pending = await f.run();
    expect(pending.error).toBeUndefined(); expect(pending.userCount).toBe(0);
    expect(pending.groqUserCountDiagnostic).toBeUndefined();
    f.f.turn.append(user); user.connected = true;
    const bound = await f.run(); expect(bound.firstUserVerified).toBe(true);
    user.remove();
    expect(await f.run()).toEqual({ error: 'conversation_changed', detail: 'user_count', groqUserCountDiagnostic: {
      kind: 'groq_user_count_v2', action: 'inspect', branch: 'expected_count', userCount: 0, answerCount: 0,
      visibleUserCount: 0, visibleAnswerCount: 0, expectedUserCounts: [1], submitted: true, adapterFirstBound: true, boundNodes: removedBoundNodes() } });
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('bound-row diagnostic distinguishes exact draft restoration without reading message text or dispatching', async () => {
    for (const draft of [groqPrompt, groqPrompt + ' ', '']) {
      const f = groqFixture(); f.f.delayResponse = true; await f.submit(); await f.run();
      f.f.user.remove(); f.f.editor.value = draft;
      Object.defineProperty(f.f.userBody, 'textContent', { get() { throw new Error('PRIVATE BODY'); } });
      const observed = await f.run();
      expect(observed.error).toBe('conversation_changed'); expect(observed.detail).toBe('user_count');
      expect(observed.groqUserCountDiagnostic.boundNodes).toEqual({ ...removedBoundNodes(),
        preparedEditorDraftRestored: draft === groqPrompt });
      expect(JSON.stringify(observed)).not.toContain('PRIVATE'); expect(JSON.stringify(observed)).not.toContain(groqPrompt);
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('bound-row diagnostic distinguishes a connected node whose original class no longer matches', async () => {
    const f = groqFixture(); f.f.delayResponse = true; await f.submit(); await f.run();
    f.f.user.values.class = 'PRIVATE NEW CLASS'; f.f.userBody.values.class = 'PRIVATE NEW BODY CLASS';
    const observed = await f.run();
    expect(observed.error).toBe('conversation_changed'); expect(observed.detail).toBe('user_count');
    expect(observed.groqUserCountDiagnostic.boundNodes).toEqual({ rootConnected: true, bodyConnected: true,
      parentConnected: true, rootClassMatches: false, bodyClassMatches: false, rootParentMatches: true,
      bodyWithinRoot: true, rootInDocument: true, preparedEditorConnected: true, preparedEditorDraftRestored: false });
    expect(JSON.stringify(observed)).not.toContain('PRIVATE');
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('bound-row diagnostic cannot claim restored draft from the disconnected held editor', async () => {
    const f = groqFixture(); f.f.delayResponse = true; await f.submit(); await f.run();
    f.f.turn.remove(); f.f.editor.value = groqPrompt; f.f.editor.remove();
    // This branch rejects before looking for a replacement composer.
    for (let i = 0; i < 2; i++) f.body.append(new f.Node('DIV', { class: 'group/input' }));
    const observed = await f.run();
    expect(observed.error).toBe('conversation_changed'); expect(observed.detail).toBe('user_count');
    expect(observed.groqUserCountDiagnostic.branch).toBe('multiple_users');
    expect(observed.groqUserCountDiagnostic.boundNodes).toEqual({ ...removedBoundNodes(), parentConnected: false,
      rootParentMatches: true, preparedEditorConnected: false, preparedEditorDraftRestored: null });
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('bound-row diagnostic preserves unknown getters and does not reread transcript selectors', async () => {
    const f = groqFixture(); f.f.delayResponse = true; await f.submit(); await f.run(); f.f.user.remove();
    Object.defineProperty(f.f.user, 'classList', { get() { throw new Error('PRIVATE CLASS'); } });
    Object.defineProperty(f.f.editor, 'value', { get() { throw new Error('PRIVATE VALUE'); } });
    // Reject before composer, so throwing current editor getters cannot become the authority error.
    for (let i = 0; i < 2; i++) f.body.append(new f.Node('DIV', { class: 'group/input' }));
    let userQueries = 0, answerQueries = 0; const query = f.document.querySelectorAll;
    f.document.querySelectorAll = (selector: string) => {
      if (selector === '[class*="group/input"]') userQueries++;
      if (selector === '.font-inter') answerQueries++;
      return query(selector);
    };
    const observed = await f.run();
    expect(observed.error).toBe('conversation_changed'); expect(observed.detail).toBe('user_count');
    expect(observed.groqUserCountDiagnostic.boundNodes).toEqual({ ...removedBoundNodes(),
      rootClassMatches: null, preparedEditorDraftRestored: null });
    expect(JSON.stringify(observed)).not.toContain('PRIVATE'); expect([userQueries, answerQueries]).toEqual([1, 1]);
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('user-count diagnostics keep malformed expected counts unknown and preserve original error priority', async () => {
    for (const expectedUserCounts of [null, [], [1, 0], [1, 1], [false], [0, 1, 2], ['PRIVATE'], [1]]) {
      const f = groqFixture(); await f.select();
      const result = await f.run('inspect', { expectedUserCounts });
      expect(result.error).toBe('conversation_changed'); expect(result.detail).toBe('user_count');
      expect(result.groqUserCountDiagnostic.branch).toBe('expected_count');
      expect(result.groqUserCountDiagnostic.expectedUserCounts).toEqual(expectedUserCounts?.length === 1 && expectedUserCounts[0] === 1 ? [1] : null);
      expect(JSON.stringify(result)).not.toContain('PRIVATE'); expect(f.f.sendCount).toBe(0);
    }
    const f = groqFixture(); await f.select();
    for (let i = 0; i < 2; i++) {
      f.body.append(new f.Node('DIV', { class: 'group/input' }));
      const parent = new f.Node('DIV', { class: 'font-normal text-base' }); parent.append(new f.Node('DIV', { class: 'font-inter' })); f.body.append(parent);
    }
    expect((await f.run()).groqUserCountDiagnostic.branch).toBe('multiple_users');
    expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
  });

  test('user-count diagnostic getter failures stay unknown and cannot replace the original rejection', async () => {
    const f = groqFixture(); await f.select();
    const one = new f.Node('DIV', { class: 'group/input' }), two = new f.Node('DIV', { class: 'group/input' });
    f.body.append(one, two);
    one.getClientRects = () => { throw new Error('PRIVATE VISIBILITY'); };
    const result = await f.run();
    expect(result.error).toBe('conversation_changed'); expect(result.detail).toBe('user_count');
    expect(result.groqUserCountDiagnostic.userCount).toBe(2);
    expect(result.groqUserCountDiagnostic.visibleUserCount).toBeNull();
    expect(result.groqUserCountDiagnostic.visibleAnswerCount).toBe(0);
    expect(JSON.stringify(result)).not.toContain('PRIVATE');
    Object.defineProperty(f.world.__computaGroqFreshSessionV1, 'first', { get() { throw new Error('PRIVATE BINDING'); } });
    expect(await f.run()).toEqual({ error: 'conversation_changed', detail: 'user_count' });
    expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
  });

  test('user-count diagnostic counts are the rejected arrays, not a second DOM search', async () => {
    const f = groqFixture(); await f.select();
    const one = new f.Node('DIV', { class: 'group/input' }), two = new f.Node('DIV', { class: 'group/input' });
    f.body.append(one, two);
    const rects = one.getClientRects.bind(one); let changed = false;
    one.getClientRects = () => {
      if (!changed) { changed = true; f.body.append(new f.Node('DIV', { class: 'group/input' })); }
      return rects();
    };
    const result = await f.run();
    expect(result.detail).toBe('user_count'); expect(result.groqUserCountDiagnostic.userCount).toBe(2);
    expect(f.document.querySelectorAll('[class*="group/input"]').length).toBe(3);
    expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
  });

  test('observed Show more sibling preserves the full long-message hash without expansion or replay', async () => {
    const prompt = 'Return only a synthetic marker.\n' + Array.from({ length: 80 }, (_, index) =>
      `Synthetic layout line ${index + 1}: ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789.`).join('\n')
      + '\n\nComputa session marker: ' + groqMarker;
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(prompt));
    const expectedHash = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
    for (const expandedControl of [false, true]) {
      const f = groqFixture({ key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' });
      await f.submit(prompt);
      const control = expandedControl ? appendObservedShowMore(f) : null;
      const observed = await f.run();
      expect(observed.error).toBeUndefined(); expect(observed.firstUserVerified).toBe(true);
      expect(observed.firstUserFingerprint).toBe(expectedHash);
      expect(observed.text).toBe(f.f.reply); expect(observed.answerComplete).toBe(true);
      expect(observed.modelEvidence.selected).toEqual({ key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' });
      expect(f.f.userBody.textContent).toBe(prompt);
      expect(f.f.sendCount).toBe(1); expect(control?.clicks ?? 0).toBe(0);
      const cleared = await f.run('clearTranscript', { clearOperation: clearedOperation(f) });
      expect(cleared.clearProof.transcriptEmpty).toBe(true);
      expect(f.f.clearCount).toBe(1); expect(f.f.sendCount).toBe(1); expect(control?.clicks ?? 0).toBe(0);
    }
  });

  test('Show more admission rejects every unobserved sibling shape and competing body', async () => {
    const changes: ((f: ReturnType<typeof groqFixture>, control: any) => void)[] = [
      (_f, control) => { control.tagName = 'BUTTON'; },
      (_f, control) => { control.textContent = 'Show less'; },
      (_f, control) => { control.textContent = 'Show more extra'; },
      (_f, control) => { control.values.class = 'cursor-pointer'; },
      (_f, control) => { control.values.class += ' foreign'; },
      (_f, control) => { control.values.role = 'button'; },
      (_f, control) => { control.values['aria-label'] = 'Show more'; },
      (_f, control) => { control.values.hidden = ''; },
      (_f, control) => { control.values.inert = ''; },
      (_f, control) => { control.values['aria-hidden'] = 'true'; },
      (f, control) => { control.textContent = ''; control.append(new f.Node('SPAN', {}, 'Show more')); },
      (f) => { appendObservedShowMore(f); },
      (f) => { f.f.userBody.parentElement.append(new f.Node('INPUT')); },
      (f) => { f.f.userBody.parentElement.text = 'Unrelated authored content'; },
      (f) => { f.f.userBody.parentElement.children.reverse(); },
      (f) => { f.f.userBody.parentElement.append(new f.Node('DIV', { class: 'line-clamp-5' }, groqPrompt)); },
      (f) => {
        const wrapper = new f.Node('DIV'); wrapper.append(new f.Node('DIV', { class: 'line-clamp-5' }, groqPrompt));
        f.f.user.append(wrapper);
      },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.submit(); const control = appendObservedShowMore(f); change(f, control);
      expect(await f.run()).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0); expect(control.clicks).toBe(0);
    }
  });

  test('Show more never substitutes for exact body or fresh post-hash ownership', async () => {
    const changes = [
      (f: ReturnType<typeof groqFixture>) => { f.f.userBody.textContent = 'Foreign middle\n\nComputa session marker: ' + groqMarker; },
      (f: ReturnType<typeof groqFixture>) => { f.f.userBody.parentElement.append(new f.Node('SPAN', {}, 'Foreign')); },
      (f: ReturnType<typeof groqFixture>) => { f.f.trigger.text = 'Other model'; },
      (f: ReturnType<typeof groqFixture>) => { f.world.__computaModelOwner = 'foreign'; },
      (f: ReturnType<typeof groqFixture>) => { f.document.URL += '&foreign=1'; },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.submit(); const control = appendObservedShowMore(f);
      f.onDigest(() => change(f));
      expect((await f.run()).error).toBeDefined();
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0); expect(control.clicks).toBe(0);
    }
    const bound = groqFixture(); await bound.submit(); const control = appendObservedShowMore(bound);
    expect((await bound.run()).firstUserVerified).toBe(true);
    bound.f.userBody.textContent = 'Foreign middle\n\nComputa session marker: ' + groqMarker;
    expect((await bound.run()).error).toBe('conversation_changed');
    expect((await bound.run('clearTranscript', { clearOperation: clearedOperation(bound) })).error).toBe('conversation_changed');
    expect(bound.f.clearCount).toBe(0); expect(control.clicks).toBe(0);
  });

  test('a digest yield rechecks first body, model, owner, document URL and generation', async () => {
    const changes = [
      (f: any) => { f.f.userBody.textContent += 'changed'; },
      (f: any) => { f.f.trigger.text = 'Other model'; },
      (f: any) => { f.world.__computaModelOwner = 'foreign'; },
      (f: any) => { f.document.URL += '&foreign=1'; },
      (f: any) => { f.world.__computaGroqFreshSessionV1.generation = 'foreign'; },
    ];
    for (const change of changes) {
      const f = groqFixture(); await f.submit(); f.onDigest(() => change(f));
      expect((await f.run()).error).toBeDefined(); expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('a bound first-root replacement and same-document reset cannot borrow old ownership', async () => {
    const f = groqFixture(); await f.submit(); await f.run();
    f.f.userBody.textContent += 'changed'; expect((await f.run()).error).toBe('conversation_changed');
    const reset = groqFixture(); await reset.submit(); await reset.run(); reset.f.finishClear();
    expect((await reset.run('inspect', { expectedUserCounts: [0] })).error).toBe('conversation_changed');
  });

  test('provider, frame, exact URL and owner guards precede any UI mutation', async () => {
    for (const overrides of [{ provider: 'claude' }, { expectedURL: 'https://chat.groq.com/foreign' },
      { ownerToken: 'invalid' }, { documentGeneration: 'invalid' }]) {
      const f = groqFixture(); expect((await f.run('selectModel', overrides)).error).toBeDefined();
      expect(f.f.pickerOpens).toBe(0); expect(f.f.sendCount).toBe(0);
    }
    const f = groqFixture(); f.window.top = {}; expect((await f.run('selectModel')).error).toBe('document_changed');
  });

  test('fresh hydration reports pending without binding a URL or granting empty-page proof', async () => {
    const f = groqFixture(); f.f.trigger.connected = false;
    expect(await f.run()).toEqual({ pending: true, sessionLifecycle: 'explicit_clear', temporary: false, composer: false });
    expect(f.world.__computaGroqFreshSessionV1.url).toBeNull();
    f.document.URL = 'https://chat.groq.com/'; expect((await f.run()).pending).toBe(true);
    f.document.URL = 'https://chat.groq.com/?model=' + groqChoice.key; f.f.trigger.connected = true;
    expect((await f.select()).selected).toBe(true); expect(f.f.sendCount).toBe(0);
    expect(f.world.__computaGroqFreshSessionV1.url).toBe(f.document.URL);
  });

  test('URL hydration cannot repin after the first owned picker click', async () => {
    const f = groqFixture(); await f.run('selectModel');
    f.document.URL = 'https://chat.groq.com/?model=openai/gpt-oss-20b';
    expect((await f.run('selectModel')).error).toBe('document_changed'); expect(f.f.pickerOpens).toBe(1);
  });

  test('query hydration is no-action pending and rebinds only the notification observer', async () => {
    const f = groqFixture(); f.document.URL = 'https://chat.groq.com/';
    expect((await f.run('discoverModels')).pending).toBe(true); expect(f.f.pickerOpens).toBe(0);
    expect(f.world.__computaGroqFreshSessionV1.url).toBeNull();
    f.document.URL = 'https://chat.groq.com/?model=' + groqChoice.key;
    expect((await f.run()).error).toBeUndefined(); expect(f.observers.length).toBe(2);
    f.observers[0]([]); expect(f.posted).toEqual([]);
    f.observers[1]([]); expect(f.posted.length).toBe(1);
    const root = groqFixture(groqChoice, { root: true });
    expect(new URL(root.document.URL).searchParams.get('model')).toBe(groqChoice.key);
    expect(root.f.sendCount).toBe(0); expect(root.f.pickerOpens).toBe(0);
  });

  test('invalid UUID layouts and oversized UTF-8 model labels cannot authorize UI actions', async () => {
    const f = groqFixture();
    expect((await f.run('selectModel', { ownerToken: 'a'.repeat(36) })).error).toBe('document_changed');
    expect(f.f.pickerOpens).toBe(0);
    const labels = groqFixture(); labels.f.choices.push(['vendor/unicode', '界'.repeat(50)]);
    await labels.run('selectModel'); expect((await labels.run('selectModel')).error).toBe('model_unverified');
  });

  test('the owned answer footer and enabled empty same-form controls establish completion', async () => {
    const f = groqFixture(); await f.submit(); const observed = await f.run();
    expect(observed.text).toBe('{"type":"message","text":"OK"}'); expect(observed.answerComplete).toBe(true);
    expect(observed.busy).toBe(false); expect(observed.firstUserVerified).toBe(true);
  });

  test('a completed owned passive paragraph reports exact text without granting literal authority', async () => {
    for (const [attributes, reply] of [
      [{}, '{"type":"message","text":"GROQ_FIXTURE_MARKER"}'],
      [{ class: 'text-left mb-4' }, '{"type":"message","text":"GROQ_FIXTURE_MARKER"}'],
      [{ dir: 'auto', class: 'mb-4  text-left', lang: 'en-US' }, '{"type":"message","text":"GROQ_FIXTURE_MARKER"}'],
      [{ dir: 'rtl' }, '{"type":"message","text":"GROQ_FIXTURE_MARKER"}'],
      [{}, '{"type":"tool_calls","calls":[}'],
    ] as const) {
      const f = groqFixture({ key: 'openai/gpt-oss-20b', label: 'GPT OSS 20B' });
      const sent = await f.submit();
      expect(sent.groqRenderedMessageRevision).toBeUndefined();
      expect(sent.groqRenderedMessageShape).toBeUndefined();
      htmlParagraph(f, reply, attributes);
      const observed = await f.run();
      expect(observed).toMatchObject({ answerComplete: true, busy: false, firstUserVerified: true,
        text: reply, groqRenderedMessageRevision: 1, groqRenderedMessageShape: 'matched', groqLiteralResponse: false,
        completionEvidence: { codeStructure: { reason: 'pre_count', preCount: 0, codeCount: 0, scanCount: 0 } } });
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('paragraph evidence reports only the first failed predicate and keeps the same rejection', async () => {
    for (const [variant, reason] of [
      ['too_many_attributes', 'attribute_count'], ['extra_attribute', 'attribute_title'], ['unknown_attribute', 'attribute_name'],
      ['unknown_class', 'attribute_value'], ['duplicate_class', 'attribute_value'], ['invalid_dir', 'attribute_value'],
      ['invalid_lang', 'attribute_value'], ['style', 'attribute_style'], ['data', 'attribute_data'], ['aria', 'attribute_aria'],
      ['role', 'attribute_role'], ['tabindex', 'attribute_tabindex'], ['handler', 'attribute_event_handler'],
      ['namespaced_class', 'attribute_namespace'], ['hidden', 'paragraph_hidden'], ['inert', 'paragraph_hidden'],
      ['editable', 'paragraph_editable'], ['foreign_namespace', 'paragraph_namespace'], ['wrapper', 'paragraph_tag'],
      ['direct_text', 'answer_text_child'], ['nested', 'leaf_not_text'], ['split_text', 'paragraph_child_count'],
      ['answer_sibling', 'answer_child_count'], ['second_paragraph', 'answer_child_count'], ['trimmed', 'text_mismatch'],
    ] as const) {
      const f = groqFixture(); await f.submit();
      const attributes = variant === 'too_many_attributes' ? Object.fromEntries(Array.from({ length: 9 }, (_, i) => [`data-test-${i}`, '']))
        : variant === 'extra_attribute' ? { class: 'text-left mb-4', title: 'extra' }
        : variant === 'unknown_attribute' ? { onward: 'private-attribute' }
        : variant === 'unknown_class' ? { class: 'text-left mb-4 extra' }
        : variant === 'duplicate_class' ? { class: 'text-left mb-4 text-left' }
        : variant === 'invalid_dir' ? { dir: 'private-direction' }
        : variant === 'invalid_lang' ? { lang: 'private language' }
        : variant === 'style' ? { style: 'text-align: left' }
        : variant === 'data' ? { 'data-private-attribute': 'value' }
        : variant === 'aria' ? { 'aria-label': 'private-label' }
        : variant === 'role' ? { role: 'button' }
        : variant === 'tabindex' ? { tabindex: '0' }
        : variant === 'handler' ? { onclick: 'void 0' }
        : variant === 'namespaced_class' ? { class: 'text-left mb-4' }
        : variant === 'hidden' ? { hidden: '' } : variant === 'inert' ? { inert: '' } : {};
      const paragraph = htmlParagraph(f, variant === 'trimmed' ? ' ' + f.f.reply : f.f.reply, attributes,
        variant === 'foreign_namespace' ? 'http://www.w3.org/2000/svg' : undefined,
        variant === 'namespaced_class' ? 'urn:fixture-attribute' : null);
      if (variant === 'editable') Object.defineProperty(paragraph, 'isContentEditable', { value: true });
      if (variant === 'wrapper') paragraph.tagName = 'DIV';
      if (variant === 'direct_text') f.f.answer.replaceChildren(new f.Node('#text', {}, f.f.reply));
      if (variant === 'nested') paragraph.replaceChildren(new f.Node('EM', {}, f.f.reply));
      if (variant === 'split_text') paragraph.append(new f.Node('#text', {}, ''));
      if (variant === 'answer_sibling') f.f.answer.append(new f.Node('#text', {}, ' '));
      if (variant === 'second_paragraph') f.f.answer.append(new f.Node('P', {}, ''));
      const observed = await f.run();
      expect(observed.groqRenderedMessageRevision).toBeUndefined();
      expect(observed.groqRenderedMessageShape).toBe(reason);
      expect(observed.groqLiteralResponse).toBe(false);
      expect(observed.answerComplete).toBe(true);
      expect(observed.text).toBe(f.f.reply);
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('rejected HTML attributes report closed names without granting a rendered witness', async () => {
    const cases = [
      ['id', 'private-fixture-id', 'attribute_id'],
      ['contenteditable', 'false', 'attribute_contenteditable'],
      ['draggable', 'false', 'attribute_draggable'],
      ['align', 'left', 'attribute_align'],
      ['translate', 'no', 'attribute_translate'],
      ['spellcheck', 'false', 'attribute_spellcheck'],
      ['popover', 'manual', 'attribute_popover'],
      ['onpointerdown', 'private-handler()', 'attribute_event_handler'],
    ] as const;
    for (const [name, value, reason] of cases) {
      const f = groqFixture(); await f.submit();
      htmlParagraph(f, f.f.reply, { class: 'text-left mb-4', [name]: value });
      const observed = await f.run();
      expect(observed).toMatchObject({ answerComplete: true, firstUserVerified: true,
        text: f.f.reply, groqLiteralResponse: false, groqRenderedMessageShape: reason });
      expect(observed.groqRenderedMessageRevision).toBeUndefined();
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('paragraph evidence is reread after first-user hashing and requires current completion', async () => {
    const f = groqFixture(); await f.submit();
    const paragraph = htmlParagraph(f);
    f.onDigest(() => { paragraph.append(new f.Node('#text', {}, '')); });
    const changed = await f.run();
    expect(changed.answerComplete).toBe(true); expect(changed.text).toBe(f.f.reply);
    expect(changed.groqRenderedMessageRevision).toBeUndefined();
    expect(changed.groqRenderedMessageShape).toBe('paragraph_child_count');
    htmlParagraph(f); f.f.copy.disabled = true;
    const busy = await f.run();
    expect(busy.answerComplete).toBe(false); expect(busy.groqRenderedMessageRevision).toBeUndefined();
    expect(busy.groqRenderedMessageShape).toBeUndefined();
    f.f.copy.disabled = false;
    expect((await f.run()).groqRenderedMessageRevision).toBe(1);
    f.f.userBody.textContent = 'Foreign body';
    const foreign = await f.run();
    expect(foreign.error).toBe('conversation_changed'); expect(foreign.groqRenderedMessageRevision).toBeUndefined();
    expect(foreign.groqRenderedMessageShape).toBeUndefined();
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('paragraph evidence keeps only attached answer, paragraph and Text identities across rereads', async () => {
    const f = groqFixture(); await f.submit();
    let paragraph = htmlParagraph(f);
    const first = await f.run();
    expect(first.groqRenderedMessageRevision).toBe(1);
    const modelCheck = await f.run('verifyModel');
    expect(modelCheck.groqRenderedMessageRevision).toBeUndefined();
    expect(modelCheck.groqRenderedMessageShape).toBeUndefined();
    expect((await f.run()).groqRenderedMessageRevision).toBe(1);
    paragraph.replaceChildren(new f.Node('#text', {}, f.f.reply));
    expect((await f.run()).groqRenderedMessageRevision).toBe(2);
    paragraph = htmlParagraph(f);
    const clone = await f.run();
    expect(clone.text).toBe(first.text); expect(clone.groqRenderedMessageRevision).toBe(3);
    const formerAnswer = f.f.answer, block = formerAnswer.parentElement;
    const nextAnswer = new f.Node('DIV', { ...formerAnswer.values });
    block.children[block.children.indexOf(formerAnswer)] = nextAnswer;
    nextAnswer.parentElement = block;
    formerAnswer.parentElement = null; formerAnswer.connected = false;
    nextAnswer.append(paragraph); f.f.answer = nextAnswer;
    expect((await f.run()).groqRenderedMessageRevision).toBe(4);
    // A break present on the pre-hash read cannot revive the previous witness
    // when the same paragraph and Text are restored during the await.
    paragraph.setAttribute('title', 'extra');
    f.onDigest(() => paragraph.removeAttribute('title'));
    expect((await f.run()).groqRenderedMessageRevision).toBe(5);
    expect((await f.run()).groqRenderedMessageRevision).toBe(5);
    f.world.__computaGroqFreshSessionV1.renderedMessageRevision = 1024;
    htmlParagraph(f);
    const exhausted = await f.run();
    expect(exhausted.groqRenderedMessageRevision).toBeUndefined();
    expect(exhausted.groqRenderedMessageShape).toBe('revision_exhausted');
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('the observed nested JSON block preserves literal escapes and excludes separate reasoning', async () => {
    const f = groqFixture(); f.f.structuredReply = true;
    f.f.reply = '{"type":"tool_calls","calls":[{"name":"fixture","arguments":{"literal":"a\\n  b\\u005f\\\""}}]}';
    await f.submit(); const observed = await f.run();
    expect(observed.text).toBe(f.f.reply); expect(observed.answerComplete).toBe(true);
    expect(observed.groqLiteralResponse).toBe(true);
    expect(observed.groqRenderedMessageRevision).toBeUndefined();
    expect(observed.groqRenderedMessageShape).toBeUndefined();
    expect(observed.text).not.toContain('Synthetic reasoning');
    expect(JSON.parse(observed.text).calls[0].arguments.literal).toBe('a\n  b_"');
    // Syntax highlighting may split code into spans; textContent retains bytes.
    const raw = f.f.reply; f.f.code.textContent = '';
    f.f.code.append(new f.Node('SPAN', {}, raw.slice(0, 20)), new f.Node('SPAN', {}, raw.slice(20)));
    expect((await f.run()).text).toBe(raw);
    expect((await f.run()).groqLiteralResponse).toBe(true);
  });

  test('a Markdown-rendered paragraph that remains valid JSON cannot claim literal response bytes', async () => {
    const f = groqFixture({ key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' });
    const intended = '{"type":"message","text":"a*b*"}';
    f.f.reply = intended; await f.submit();
    // CommonMark emphasis removes source asterisks before textContent. This
    // actual inline DOM produces a valid but semantically different JSON value.
    f.f.answer.textContent = '';
    const paragraph = new f.Node('P');
    paragraph.append(new f.Node('SPAN', {}, '{"type":"message","text":"a'),
      new f.Node('EM', {}, 'b'), new f.Node('SPAN', {}, '"}'));
    f.f.answer.append(paragraph);
    const observed = await f.run();
    expect(observed.text).toBe('{"type":"message","text":"ab"}');
    expect(JSON.parse(observed.text).text).toBe('ab'); expect(JSON.parse(intended).text).toBe('a*b*');
    expect(observed.text).not.toBe(intended); expect(observed.groqLiteralResponse).toBe(false);
    expect(observed.answerComplete).toBe(true); expect(observed.busy).toBe(false); expect(observed.firstUserVerified).toBe(true);
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('the observed display-copy escape loss keeps the invalid paragraph diagnostic text without a literal claim', async () => {
    const f = groqFixture({ key: 'openai/gpt-oss-120b', label: 'GPT OSS 120B' });
    const intended = JSON.stringify({marker:'GROQ477DISPLAYCABE59A846F841098D42FA652E84623F',quoted:'say "hi"',
      path:'C:\\tmp\\note.txt',markdown:'a*b*'});
    const displayed = String.raw`{"marker":"GROQ477DISPLAYCABE59A846F841098D42FA652E84623F","quoted":"say "hi"","path":"C:\tmp\note.txt","markdown":"a b "}`;
    expect(new TextEncoder().encode(intended)).toHaveLength(126);
    expect(new TextEncoder().encode(displayed)).toHaveLength(122);
    expect(JSON.parse(intended).quoted).toBe('say "hi"'); expect(() => JSON.parse(displayed)).toThrow();
    f.f.reply = intended; await f.submit(); f.f.answer.textContent = '';
    f.f.answer.append(new f.Node('P', {}, displayed));
    const observed = await f.run();
    expect(observed.text).toBe(displayed);
    expect(new TextEncoder().encode(observed.text)).toEqual(new TextEncoder().encode(displayed));
    expect(observed.groqLiteralResponse).toBe(false); expect(observed.answerComplete).toBe(true);
    expect(observed.firstUserVerified).toBe(true); expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('finished malformed JSON with the observed extra closing bracket is never repaired', async () => {
    const f = groqFixture({ key: 'openai/gpt-oss-20b', label: 'GPT OSS 20B' }); f.f.structuredReply = true;
    f.f.reply = '{"type":"tool_calls","calls":[{"name":"fixture","arguments":{"numbers":['
      + Array.from({ length: 180 }, (_, i) => i + 1).join(',') + ']]}}]}';
    await f.submit(); const observed = await f.run();
    expect(observed.text).toBe(f.f.reply); expect(observed.text.endsWith(',178,179,180]]}}]}')).toBe(true);
    expect(observed.groqLiteralResponse).toBe(true);
    expect(observed.answerComplete).toBe(true); expect(observed.busy).toBe(false);
    expect(() => JSON.parse(observed.text)).toThrow(); expect(f.f.sendCount).toBe(1);
  });

  test('visible and hidden prose outside the code body cannot be discarded to salvage JSON', async () => {
    for (const hidden of [false, true]) {
      const f = groqFixture(); f.f.structuredReply = true; await f.submit();
      f.f.answer.append(new f.Node('P', hidden ? { hidden: '' } : {}, 'Do not execute this example.'));
      const observed = await f.run();
      expect(observed.text).toContain(f.f.reply); expect(observed.text).toContain('Do not execute this example.');
      expect(observed.groqLiteralResponse).toBe(false);
      expect(() => JSON.parse(observed.text)).toThrow(); expect(observed.answerComplete).toBe(true);
    }
  });

  test('unrecognized copy chrome and multiple code bodies preserve all authored content', async () => {
    const chrome = groqFixture(); chrome.f.structuredReply = true; await chrome.submit();
    chrome.f.codeChrome.append(new chrome.Node('SPAN', {}, 'Authored extra content'));
    expect((await chrome.run()).text).toContain('Authored extra content');
    expect((await chrome.run()).groqLiteralResponse).toBe(false);
    const duplicate = groqFixture(); duplicate.f.structuredReply = true; await duplicate.submit();
    duplicate.f.answer.append(new duplicate.Node('PRE', {}, 'SECOND CODE BODY'));
    const observed = await duplicate.run();
    expect(observed.text).toContain(duplicate.f.reply); expect(observed.text).toContain('SECOND CODE BODY');
    expect(observed.groqLiteralResponse).toBe(false);
    expect(() => JSON.parse(observed.text)).toThrow();
  });

  test('streaming user-only state completes only after its answer footer and controls finish', async () => {
    const f = groqFixture(); f.f.delayResponse = true; f.f.structuredReply = true;
    await f.submit(); const streaming = await f.run();
    expect(streaming.firstUserVerified).toBe(true); expect(streaming.responseCount).toBe(0);
    expect(streaming.answerComplete).toBe(false); expect(streaming.busy).toBe(true);
    f.f.finishResponse(); const complete = await f.run();
    expect(complete.answerComplete).toBe(true); expect(complete.busy).toBe(false);
    expect(complete.text).toBe(f.f.reply); expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  });

  test('early Copy cannot complete while either control is disabled or a draft remains', async () => {
    for (const change of [
      (f: any) => { f.f.editor.disabled = true; },
      (f: any) => { f.f.send.disabled = true; },
      (f: any) => { f.f.editor.setAttribute('aria-disabled', 'true'); },
      (f: any) => { f.f.send.setAttribute('aria-disabled', 'true'); },
      (f: any) => { f.f.editor.value = 'Unexpected draft'; },
    ]) {
      const f = groqFixture(); await f.submit(); change(f);
      const observed = await f.run();
      expect(observed.answerComplete).toBe(false); expect(observed.busy).toBe(true);
      expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
    }
  });

  test('code Copy, stats and missing, disabled, hidden or ambiguous footer Copy are insufficient', async () => {
    for (const change of [
      (f: any) => { f.f.copy.remove(); },
      (f: any) => { f.f.copy.disabled = true; },
      (f: any) => { f.f.copy.setAttribute('hidden', ''); },
      (f: any) => { f.f.toolbar.setAttribute('hidden', ''); },
      (f: any) => { f.f.toolbar.setAttribute('class', 'unrecognized'); },
      (f: any) => { const extra = new f.Node('BUTTON'); extra.append(new f.Node('SVG', { 'aria-label': 'copy' })); f.f.toolbar.append(extra); },
      (f: any) => { f.f.toolbar.remove(); f.body.append(f.f.toolbar); },
    ]) {
      const f = groqFixture(); f.f.structuredReply = true; await f.submit(); change(f);
      const observed = await f.run();
      expect(observed.answerComplete).toBe(false); expect(observed.busy).toBe(true);
      expect(f.f.sendCount).toBe(1);
    }
  });

  test('completion and literal text are reread after the ownership fingerprint yields', async () => {
    const f = groqFixture(); f.f.structuredReply = true; await f.submit();
    f.onDigest(() => { f.f.editor.disabled = true; f.f.code.textContent = '{"type":"message","text":"changed"}'; });
    const observed = await f.run();
    expect(observed.answerComplete).toBe(false); expect(observed.busy).toBe(true);
    expect(observed.text).toBe('{"type":"message","text":"changed"}');
    f.f.editor.disabled = false;
    expect((await f.run()).answerComplete).toBe(true); expect(f.f.sendCount).toBe(1);
  });

  test('clear requires a native-pinned current operation and acknowledged owned first message', async () => {
    const f = groqFixture(); await f.submit(); await f.run();
    expect((await f.run('clearTranscript', { clearOperation: { ...clearedOperation(f), firstUserFingerprint: 'a'.repeat(64) } })).error).toBe('conversation_changed');
    expect(f.f.clearCount).toBe(0);
    const noRecord = groqFixture(); await noRecord.select();
    expect((await noRecord.run('observeClearTranscript', { clearOperation: { ...clearedOperation(noRecord), firstUserFingerprint: 'a'.repeat(64) }, expectedFirstUserFingerprint: 'a'.repeat(64) })).error).toBe('conversation_changed');
    expect(noRecord.f.clearCount).toBe(0);
  });

  test('one acknowledged clear returns only its exact operation proof and cannot be replayed', async () => {
    const f = groqFixture(); await f.submit(); await f.run(); const operation = clearedOperation(f);
    const result = await f.run('clearTranscript', { clearOperation: operation });
    expect(result.clearProof).toEqual({ ...operation, clickAcknowledged: true, transcriptEmpty: true });
    expect(result.temporary).toBe(false); expect(result.sessionLifecycle).toBe('explicit_clear');
    expect(result.userCount).toBe(0); expect(result.responseCount).toBe(0); expect(f.f.clearCount).toBe(1);
    expect((await f.run('observeClearTranscript', { clearOperation: operation })).clearProof).toEqual(result.clearProof);
    await f.run('clearTranscript', { clearOperation: operation }); expect(f.f.clearCount).toBe(1);
    expect((await f.run('insert', { prompt: groqPrompt })).error).toBe('conversation_changed');
  });

  test('ignored or delayed clear is observation-only and a foreign nonce cannot adopt it', async () => {
    for (const delayed of [false, true]) {
      const f = groqFixture(); await f.submit(); await f.run();
      f.f.ignoreClear = !delayed; f.f.delayClear = delayed; const operation = clearedOperation(f);
      expect((await f.run('clearTranscript', { clearOperation: operation })).clearProof.transcriptEmpty).toBe(false);
      await f.run('clearTranscript', { clearOperation: operation }); expect(f.f.clearCount).toBe(1);
      expect((await f.run('observeClearTranscript', { clearOperation: { ...operation, id: 'd11d5e61-d93b-4222-a115-c2a3a47e9c47' } })).error).toBe('conversation_changed');
      if (delayed) { f.f.finishClear(); expect((await f.run('observeClearTranscript', { clearOperation: operation })).clearProof.transcriptEmpty).toBe(true); }
    }
  });

  test('duplicated, hidden, authored, replaced or occluded clear controls cannot be clicked', async () => {
    const mutations = [
      (f: any) => f.body.append(new f.Node('BUTTON', {}, 'Clear chat')),
      (f: any) => f.f.clearButton.setAttribute('hidden', ''),
      (f: any) => { f.f.clearButton.remove(); f.f.answer.append(new f.Node('BUTTON', {}, 'Clear chat')); },
      (f: any) => f.blockHit(true),
    ];
    for (const mutate of mutations) {
      const f = groqFixture(); await f.submit(); await f.run(); mutate(f);
      expect((await f.run('clearTranscript', { clearOperation: clearedOperation(f) })).error).toBeDefined();
      expect(f.f.clearCount).toBe(0);
    }
  });

  test('a thrown clear click never acquires acknowledgment from later emptiness', async () => {
    const f = groqFixture(); await f.submit(); await f.run(); const operation = clearedOperation(f);
    f.f.clearButton.onclick = () => { f.f.clearCount++; f.f.finishClear(); throw new Error('lost acknowledgment'); };
    await expect(f.run('clearTranscript', { clearOperation: operation })).rejects.toThrow('lost acknowledgment');
    const observed = await f.run('observeClearTranscript', { clearOperation: operation });
    expect(observed.clearProof.clickAcknowledged).toBe(false); expect(observed.clearProof.transcriptEmpty).toBe(false);
    expect(f.f.clearCount).toBe(1);
  });

  test('retained transcript nodes cannot impersonate clearing by losing their selector classes', async () => {
    const f = groqFixture(); await f.submit(); await f.run(); const operation = clearedOperation(f);
    f.f.clearButton.onclick = () => {
      f.f.clearCount++; f.f.user.values.class = ''; f.f.answer.values.class = '';
      f.f.clearButton.remove(); f.f.stats.remove();
    };
    expect((await f.run('clearTranscript', { clearOperation: operation })).clearProof.transcriptEmpty).toBe(false);
    expect(f.f.user.isConnected).toBe(true); expect(f.f.clearCount).toBe(1);
  });

  test('bounded clear scrolling rechecks ownership and the same exact control', async () => {
    const f = groqFixture(); await f.submit(); await f.run(); const operation = clearedOperation(f);
    f.blockHit(true); let scrolls = 0;
    f.f.clearButton.scrollIntoView = () => { scrolls++; f.blockHit(false); };
    expect((await f.run('clearTranscript', { clearOperation: operation })).clearProof.transcriptEmpty).toBe(true);
    expect(scrolls).toBe(1); expect(f.f.clearCount).toBe(1);
    const changed = groqFixture(); await changed.submit(); await changed.run(); changed.blockHit(true);
    changed.f.clearButton.scrollIntoView = () => { changed.blockHit(false); changed.f.userBody.textContent += 'changed'; };
    expect((await changed.run('clearTranscript', { clearOperation: clearedOperation(changed) })).error).toBe('conversation_changed');
    expect(changed.f.clearCount).toBe(0);
  });

  test('mutation notifications contain no page text and do not act', async () => {
    const f = groqFixture(); await f.run(); f.observers[0]([]);
    expect(f.posted).toEqual([{ ownerToken: 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30', kind: 'dom_changed' }]);
    expect(f.f.sendCount).toBe(0); expect(f.f.clearCount).toBe(0);
  });
});

test('a fresh generic error in the same previously empty site notification region annotates only a verified rollback', async () => {
  const notice = 'Something went wrong. Please, try again.';
  for (const fault of ['none','stale','replaced','hidden','other_copy','duplicate','prompt_copy',
    'editor_mismatch','parent_attached','not_bound','extra_copy','large','throws','authored','elsewhere','class_drift','body_replaced']) {
    const f = groqFixture(); f.f.delayResponse = true;
    let region = new f.Node('SECTION', { 'aria-label': 'Notifications alt+T' });
    f.body.append(region);
    if (fault === 'stale') region.append(new f.Node('SPAN', {}, notice));
    await f.submit();
    if (fault !== 'not_bound') expect((await f.run()).firstUserVerified).toBe(true);
    if (fault === 'replaced') { region.remove(); region = new f.Node('SECTION', { 'aria-label': 'Notifications alt+T' }); f.body.append(region); }
    if (fault === 'duplicate') f.body.append(new f.Node('SECTION', { 'aria-label': 'Notifications alt+T' }));
    if (fault === 'hidden') region.setAttribute('hidden','');
    if (fault === 'authored') region.setAttribute('class','font-inter');
    if (fault === 'parent_attached') f.f.user.remove(); else f.f.turn.remove();
    if (fault === 'class_drift') f.f.user.setAttribute('class','private');
    if (fault === 'body_replaced') f.f.userBody.remove();
    f.f.editor.value = fault === 'editor_mismatch' ? groqPrompt + ' ' : groqPrompt;
    const leaf = new f.Node('SPAN',{},fault === 'other_copy' ? 'PRIVATE HTTP 429' : fault === 'prompt_copy' ? groqPrompt : notice);
    if (fault !== 'stale') (fault === 'elsewhere' ? f.body : region).append(leaf);
    if (fault === 'extra_copy') region.append(new f.Node('SPAN',{},'PRIVATE EXTRA'));
    if (fault === 'large') for (let i=0;i<49;i++) region.append(new f.Node('DIV'));
    if (fault === 'throws') Object.defineProperty(region,'childNodes',{get(){throw new Error('PRIVATE');}});
    const result = await f.run();
    expect(result.groqUserCountDiagnostic?.freshNotice).toBe(fault === 'none' ? 'generic_error' : undefined);
    if (fault === 'none') {
      expect(result.error).toBe('conversation_changed'); expect(result.detail).toBe('user_count');
      expect(result.groqUserCountDiagnostic.boundNodes.preparedEditorDraftRestored).toBe(true);
    }
    expect(JSON.stringify(result.groqUserCountDiagnostic || {})).not.toContain('PRIVATE');
    expect(f.f.sendCount).toBe(1); expect(f.f.clearCount).toBe(0);
  }
});
