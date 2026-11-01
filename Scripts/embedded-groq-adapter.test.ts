import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { groqChoice, groqFixture, groqGeneration, groqMarker, groqPrompt } from './embedded-groq-adapter-fixture';

const clearedOperation = (f: ReturnType<typeof groqFixture>) => ({ id: '4e40e8a4-876e-4433-90ab-a40b68063177',
  documentGeneration: groqGeneration, sequence: 1, firstUserFingerprint: f.fingerprint });

describe('Groq fixed fresh-session adapter', () => {
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

  test('the observed nested JSON block preserves literal escapes and excludes separate reasoning', async () => {
    const f = groqFixture(); f.f.structuredReply = true;
    f.f.reply = '{"type":"tool_calls","calls":[{"name":"fixture","arguments":{"literal":"a\\n  b\\u005f\\\""}}]}';
    await f.submit(); const observed = await f.run();
    expect(observed.text).toBe(f.f.reply); expect(observed.answerComplete).toBe(true);
    expect(observed.text).not.toContain('Synthetic reasoning');
    expect(JSON.parse(observed.text).calls[0].arguments.literal).toBe('a\n  b_"');
    // Syntax highlighting may split code into spans; textContent retains bytes.
    const raw = f.f.reply; f.f.code.textContent = '';
    f.f.code.append(new f.Node('SPAN', {}, raw.slice(0, 20)), new f.Node('SPAN', {}, raw.slice(20)));
    expect((await f.run()).text).toBe(raw);
  });

  test('finished malformed JSON with the observed extra closing bracket is never repaired', async () => {
    const f = groqFixture({ key: 'openai/gpt-oss-20b', label: 'GPT OSS 20B' }); f.f.structuredReply = true;
    f.f.reply = '{"type":"tool_calls","calls":[{"name":"fixture","arguments":{"numbers":['
      + Array.from({ length: 180 }, (_, i) => i + 1).join(',') + ']]}}]}';
    await f.submit(); const observed = await f.run();
    expect(observed.text).toBe(f.f.reply); expect(observed.text.endsWith(',178,179,180]]}}]}')).toBe(true);
    expect(observed.answerComplete).toBe(true); expect(observed.busy).toBe(false);
    expect(() => JSON.parse(observed.text)).toThrow(); expect(f.f.sendCount).toBe(1);
  });

  test('visible and hidden prose outside the code body cannot be discarded to salvage JSON', async () => {
    for (const hidden of [false, true]) {
      const f = groqFixture(); f.f.structuredReply = true; await f.submit();
      f.f.answer.append(new f.Node('P', hidden ? { hidden: '' } : {}, 'Do not execute this example.'));
      const observed = await f.run();
      expect(observed.text).toContain(f.f.reply); expect(observed.text).toContain('Do not execute this example.');
      expect(() => JSON.parse(observed.text)).toThrow(); expect(observed.answerComplete).toBe(true);
    }
  });

  test('unrecognized copy chrome and multiple code bodies preserve all authored content', async () => {
    const chrome = groqFixture(); chrome.f.structuredReply = true; await chrome.submit();
    chrome.f.codeChrome.append(new chrome.Node('SPAN', {}, 'Authored extra content'));
    expect((await chrome.run()).text).toContain('Authored extra content');
    const duplicate = groqFixture(); duplicate.f.structuredReply = true; await duplicate.submit();
    duplicate.f.answer.append(new duplicate.Node('PRE', {}, 'SECOND CODE BODY'));
    const observed = await duplicate.run();
    expect(observed.text).toContain(duplicate.f.reply); expect(observed.text).toContain('SECOND CODE BODY');
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
