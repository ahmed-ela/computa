import { describe, expect, test } from "bun:test";
import { Element, fixture, firstMarker, markerLine, installObservedModelPicker } from "./embedded-provider-adapter-fixture";
import { defineWebsiteModelChoiceTests } from "./embedded-model-choice-tests";
const provider = "gemini";
const prompt = 'Use `tool_calls` with C++ "quoted" text\n\n  two spaces and\u00a0NBSP';
const outbound = prompt + "\n\n" + markerLine;

defineWebsiteModelChoiceTests(provider, (owned = false) => fixture(provider, owned ? { userPrompt: 'Synthetic owned prompt' } : {}), Element);

describe('Gemini per-submission ownership', () => {
  const marker = (sequence: number) => sequence === 1 ? firstMarker : 'a909845c-2857-4b22-a66b-' + String(sequence).padStart(12, '0');
  const fields = (sequence: number) => ({ submissionSequence: sequence, submissionMarker: marker(Math.max(1, sequence)) });
  const roundPrompt = (sequence: number) => `PRIVATE ROUND ${sequence}: [literal] e\u0301 and whitespace\n\nComputa session marker: ${marker(sequence)}`;
  const normalized = (text: string) => text.replace(/\r\n?/g, '\n').normalize('NFC').trim();
  const fingerprint = async (text: string) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(normalized(text))))]
    .map(byte => byte.toString(16).padStart(2, '0')).join('');
  const stage = async (f: ReturnType<typeof fixture>, sequence: number, text = roundPrompt(sequence)) => {
    expect(await f.run('prepare', { ...fields(sequence - 1), expectedUserCounts: [sequence - 1] })).toMatchObject({ prepared: true });
    expect(await f.run('insert', { ...fields(sequence), expectedUserCounts: [sequence - 1], prompt: text })).toMatchObject({ inserted: true });
    expect(await f.run('sendReady', { ...fields(sequence), expectedUserCounts: [sequence - 1], prompt: text })).toMatchObject({ sendReady: true });
    return text;
  };
  const submitPending = async (f: ReturnType<typeof fixture>, sequence: number, text: string) => {
    const value = await f.run('submit', { ...fields(sequence), expectedUserCounts: [sequence - 1], prompt: text });
    expect(value).toMatchObject({ submitted: true, submissionOwnershipCapability: 'per_submission_ownership_v1',
      submissionPending: true, text: '', answerComplete: false });
    expect(value.submissionProof).toBeUndefined(); expect(value.firstUserVerified).not.toBe(true);
    expect(f.world.__computaGeminiSubmissionState.pending).toMatchObject({ sequence, phase: 'send_claimed' });
    return value;
  };
  const submitThenInspect = async (f: ReturnType<typeof fixture>, sequence: number, text: string) => {
    await submitPending(f, sequence, text);
    return f.run('inspect', { ...fields(sequence), expectedUserCounts: [sequence] });
  };
  const finishRound = async (f: ReturnType<typeof fixture>, sequence: number, text = roundPrompt(sequence)) => {
    await stage(f, sequence, text);
    await submitPending(f, sequence, text);
    const value = await f.run('inspect', { ...fields(sequence), expectedUserCounts: [sequence] });
    expect(value).toMatchObject({ firstUserVerified: true, submissionOwnershipCapability: 'per_submission_ownership_v1',
      submissionProof: { sequence, fingerprint: await fingerprint(text) } });
    return value;
  };
  const withDigestMutation = async (f: ReturnType<typeof fixture>, sequence: number, phase: string, mutate: () => void,
    operation: () => Promise<any>) => {
    const subtle: any = crypto.subtle, original = subtle.digest;
    let changed = false;
    subtle.digest = async (algorithm: any, data: any) => {
      const digest = await original.call(subtle, algorithm, data);
      if (!changed && f.world.__computaGeminiSubmissionState?.pending?.phase === phase
        && new TextDecoder().decode(data) === normalized(roundPrompt(sequence))) { changed = true; mutate(); }
      return digest;
    };
    try { const value = await operation(); expect(changed).toBe(true); return value; }
    finally { subtle.digest = original; }
  };

  test('seven exact round bodies get independent fingerprints while the first lineage remains pinned', async () => {
    const f = fixture(provider, { response: false });
    let first: string | undefined;
    for (let sequence = 1; sequence <= 7; sequence++) {
      const value = await finishRound(f, sequence);
      first ||= value.firstUserFingerprint;
      expect(value.firstUserFingerprint).toBe(first);
      expect(value.submissionProof.fingerprint).not.toBe(sequence === 1 ? '' : first);
      expect(f.world.__computaGeminiSubmissionState.lastVerified.sequence).toBe(sequence);
      expect(f.world.__computaGeminiSubmissionState.pending).toBeNull();
    }
    expect(f.send.clicks).toBe(7);
  });

  test('a changed second body fails despite a valid composer and cannot be repaired or resent', async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1);
    const text = await stage(f, 2), send = f.send.onClick!;
    f.send.onClick = () => { send(); f.userBody!.text = f.userBody!.text.replace('[literal]', '{altered}'); };
    expect(await submitThenInspect(f, 2, text)).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    f.userBody!.text = text;
    const repeated = await f.run('inspect', { ...fields(2), expectedUserCounts: [2] });
    expect(repeated).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    expect(repeated.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
  });

  test('pending append cannot expose a previous answer and later verifies without another Send', async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1);
    f.messages.append(f.article);
    const text = await stage(f, 2); f.send.onClick = () => { f.composer.replaceChildren(); };
    const sent = await f.run('submit', { ...fields(2), expectedUserCounts: [1], prompt: text });
    expect(sent).toMatchObject({ submitted: true, submissionOwnershipCapability: 'per_submission_ownership_v1' });
    const previousProof = { sequence: 1, fingerprint: await fingerprint(roundPrompt(1)) };
    expect(sent).toMatchObject({ submissionPending: true, text: '', answerComplete: false });
    expect(sent.submissionProof).toBeUndefined();
    // Native rechecks the pinned model after the Send acknowledgment, before
    // the new user body exists. Only the previous round may supply its proof.
    const rechecked = await f.run('verifyModel', { ...fields(2), expectedUserCounts: [1, 2] });
    expect(rechecked).toMatchObject({ submissionPending: true, pending: true, answerComplete: false, text: '', submissionProof: previousProof });
    const pending = await f.run('inspect', { ...fields(2), expectedUserCounts: [1, 2] });
    expect(pending).toMatchObject({ submissionPending: true, pending: true, answerComplete: false, text: '', submissionProof: previousProof });
    expect(f.world.__computaGeminiSubmissionState.pending.sequence).toBe(2);
    expect(f.world.__computaGeminiSubmissionState.lastVerified.sequence).toBe(1);
    f.appendUser(text);
    expect(await f.run('inspect', { ...fields(2), expectedUserCounts: [2] })).toMatchObject({
      submissionProof: { sequence: 2, fingerprint: await fingerprint(text) } });
    expect(f.send.clicks).toBe(2);
  });

  test('third Send acknowledges once without hashing bodies and a racing append is proved only by fresh reads', async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1); await finishRound(f, 2);
    const previous = f.world.__computaGeminiSubmissionState.lastVerified;
    const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
    const expectedModelChoice = { key: '3.1 Pro', label: '3.1 Pro' };
    const text = await stage(f, 3);
    f.send.onClick = () => { f.composer.replaceChildren(); };
    const subtle: any = crypto.subtle, original = subtle.digest;
    let postSendHashes = 0, appended = false;
    subtle.digest = async (algorithm: any, data: any) => {
      const value = await original.call(subtle, algorithm, data);
      if (f.send.clicks === 3) {
        postSendHashes++;
        if (!appended && new TextDecoder().decode(data) === normalized(roundPrompt(2))) {
          appended = true; f.appendUser(text);
        }
      }
      return value;
    };
    try {
      await submitPending(f, 3, text);
      expect(postSendHashes).toBe(0); expect(appended).toBe(false);
      expect(f.world.__computaGeminiSubmissionState.lastVerified).toBe(previous);
      expect(f.world.__computaGeminiSubmissionState.revoked).toBe(false);
      const args = { ...fields(3), expectedUserCounts: [2, 3], expectedModelChoice };
      const crossed = await f.run('inspect', args);
      expect(crossed).toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
      expect(appended).toBe(true); expect(postSendHashes).toBeGreaterThan(0);
      expect(f.world.__computaGeminiSubmissionState.revoked).toBe(false);
      expect(f.world.__computaGeminiSubmissionState.lastVerified).toBe(previous);
      expect(f.world.__computaGeminiSubmissionState.pending.phase).toBe('send_claimed');
      const fresh = await f.run('inspect', args);
      expect(fresh).toMatchObject({ submissionProof: { sequence: 3, fingerprint: await fingerprint(text) } });
      expect(f.world.__computaGeminiSubmissionState.pending).toBeNull(); expect(f.send.clicks).toBe(3);
      expect(await f.run('submit', { ...fields(3), expectedUserCounts: [3], prompt: text })).toHaveProperty('error');
      expect(f.send.clicks).toBe(3);
    } finally { subtle.digest = original; }
  });

  test('an acknowledged second body arriving during the first hash discards the read and cannot excuse first-body corruption', async () => {
    for (const corruptFirst of [false, true]) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
      const choice = { key: '3.1 Pro', label: '3.1 Pro' };
      const firstBody = f.world.__computaGeminiSubmissionState.lastVerified.body;
      const text = await stage(f, 2); f.send.onClick = () => { f.composer.replaceChildren(); };
      expect(await f.run('submit', { ...fields(2), expectedUserCounts: [1], prompt: text })).toMatchObject({ submitted: true, submissionPending: true });
      let appends = 0;
      f.onDigest(() => {
        if (corruptFirst) firstBody.text = firstBody.text.replace('PRIVATE', 'ALTERED');
        f.appendUser(text); appends++;
      });
      const discarded = await f.run('inspect', { ...fields(2), expectedUserCounts: [1, 2], expectedModelChoice: choice });
      expect(discarded).toMatchObject(corruptFirst
        ? { error: 'conversation_changed', detail: 'first_user_message' }
        : { error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
      expect(discarded.submissionProof).toBeUndefined(); expect(appends).toBe(1); expect(f.send.clicks).toBe(2);
      const fresh = await f.run('inspect', { ...fields(2), expectedUserCounts: [2], expectedModelChoice: choice });
      expect(fresh).toMatchObject(corruptFirst ? { error: 'conversation_changed', detail: 'first_user_message' }
        : { submissionProof: { sequence: 2, fingerprint: await fingerprint(text) } });
      expect(f.send.clicks).toBe(2);
    }
  });

  test('repeated insertion reused markers and replayed Send never claim another round', async () => {
    for (const attack of ['insert', 'marker', 'send']) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      if (attack === 'marker') {
        expect(await f.run('insert', { ...fields(2), submissionMarker: firstMarker, expectedUserCounts: [1], prompt: roundPrompt(1) }))
          .toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      } else {
        const text = await stage(f, 2);
        if (attack === 'insert') expect(await f.run('insert', { ...fields(2), expectedUserCounts: [1], prompt: text })).toMatchObject({ error: 'composer_not_empty' });
        else {
          f.send.onClick = () => { f.composer.replaceChildren(); };
          expect(await f.run('submit', { ...fields(2), expectedUserCounts: [1], prompt: text })).toMatchObject({ submitted: true });
          f.composer.text = text;
          expect(await f.run('submit', { ...fields(2), expectedUserCounts: [1], prompt: text })).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
        }
      }
      expect(f.send.clicks).toBe(attack === 'send' ? 2 : 1);
    }
  });

  test('body owner route temporary and ambiguous-body changes across the current digest reject proof', async () => {
    for (const change of ['body', 'owner', 'route', 'temporary', 'replace', 'ambiguous']) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1); const text = await stage(f, 2);
      const rejected = await withDigestMutation(f, 2, 'send_claimed', () => {
        if (change === 'body') f.userBody!.text += ' altered';
        else if (change === 'owner') f.world.__computaModelOwner = '00000000-0000-0000-0000-000000000000';
        else if (change === 'route') f.document.URL += '?crossed=1';
        else if (change === 'temporary') f.temporary(false);
        else {
          const body = f.userBody!, parent = body.parentElement!;
          const replacement = new Element('SPAN', { class: 'ng-star-inserted' }, body.text);
          if (change === 'ambiguous') parent.append(replacement);
          else { parent.children[parent.children.indexOf(body)] = replacement; replacement.parentElement = parent; body.connected = false; body.parentElement = null; }
        }
      }, () => submitThenInspect(f, 2, text));
      if (change === 'temporary') expect(rejected).toEqual({ error: 'temporary_mode_unverified' });
      else expect(rejected).toMatchObject({ error: 'conversation_changed',
        detail: ['owner', 'route'].includes(change) ? 'first_user_message' : 'submission_message' });
      if (['owner', 'route'].includes(change)) {
        const diagnostic = JSON.parse(rejected.debugStructure);
        expect(diagnostic.reason).toBe('snapshot_after_action');
        expect(diagnostic.snapshot[change === 'owner' ? 'ownerSame' : 'urlSame']).toBe(false);
      }
      expect(rejected.submissionProof).toBeUndefined(); expect(JSON.stringify(rejected)).not.toContain('PRIVATE'); expect(f.send.clicks).toBe(2);
    }
  });

  test('only the existing exact first-root discard can rebind its round proof on a fresh inspect', async () => {
    const f = fixture(provider, { response: false }); const bound = await finishRound(f, 1);
    const picker = installObservedModelPicker(f, provider, Element, { unmountMenus: true });
    picker.selected('3.1 Pro');
    const choice = { key: '3.1 Pro', label: '3.1 Pro' };
    const original = picker.trigger.onClick!;
    let replacement: Element | undefined, oldRoot: Element | undefined, oldBody: Element | undefined;
    picker.trigger.onClick = () => {
      const closing = picker.trigger.values['aria-expanded'] === 'true';
      original();
      if (closing && !replacement) {
        oldRoot = f.messages.querySelector('user-query')!;
        oldBody = f.world.__computaGeminiSubmissionState.lastVerified.body;
        replacement = oldRoot.cloneNode(true);
        const parent = oldRoot.parentElement!;
        parent.children[parent.children.indexOf(oldRoot)] = replacement;
        replacement.parentElement = parent; oldRoot.connected = false;
      }
    };
    picker.open(); picker.trigger.values['aria-expanded'] = 'true';
    const discarded = await f.run('inspect', { ...fields(1), expectedUserCounts: [1], expectedModelChoice: choice });
    expect(discarded).toMatchObject({ error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
    expect(discarded.submissionProof).toBeUndefined();
    const record = f.world.__computaGeminiSubmissionState.lastVerified;
    expect(record.root).toBe(oldRoot); expect(record.body).toBe(oldBody);
    expect(record.remount.root).toBe(replacement);
    const refreshed = await f.run('inspect', { ...fields(1), expectedUserCounts: [1], expectedModelChoice: choice });
    expect(refreshed).toMatchObject({ firstUserFingerprint: bound.firstUserFingerprint,
      submissionProof: { sequence: 1, fingerprint: await fingerprint(roundPrompt(1)) } });
    expect(record.root).toBe(replacement); expect(record.remount).toBeNull();
    expect(record.body.isConnected).toBe(true); expect(oldBody!.isConnected).toBe(false);
    expect(f.send.clicks).toBe(1);
    await finishRound(f, 2);
    expect(f.send.clicks).toBe(2);
  });

  test('submission diagnostics expose only fixed typed predicates at actual rejected boundaries', async () => {
    const keys = ['kind', 'stage', 'action', 'phase', 'requestedSequence', 'recordSequence', 'userCount', 'statePresent',
      'recordPresent', 'stateRevoked', 'ownerMatches', 'documentMatches', 'nonceMatches', 'canonicalMatches', 'suffixMatches', 'contextMatches'];
    const flags = keys.slice(7);
    const check = (value: any, stage: string) => {
      expect(value).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      const diagnostic = value.submissionDiagnostic;
      expect(Object.keys(diagnostic).sort()).toEqual([...keys].sort());
      expect(diagnostic).toMatchObject({ kind: 'gemini_submission_v1', stage });
      for (const key of flags) expect(typeof diagnostic[key]).toBe('boolean');
      for (const key of ['requestedSequence', 'recordSequence'])
        expect(diagnostic[key] === null || Number.isInteger(diagnostic[key]) && diagnostic[key] >= 0 && diagnostic[key] <= 10000).toBe(true);
      expect(Number.isInteger(diagnostic.userCount) && diagnostic.userCount >= 0 && diagnostic.userCount <= 10000).toBe(true);
      expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE');
      expect(JSON.stringify(diagnostic)).not.toContain(firstMarker);
      expect(JSON.stringify(diagnostic)).not.toContain('https:');
      return diagnostic;
    };
    const invalid = fixture(provider, { response: false });
    const bad = await invalid.run('inspect', { submissionSequence: 'PRIVATE_SEQUENCE', submissionMarker: 'PRIVATE_NONCE' });
    expect(check(bad, 'invalid_input')).toMatchObject({ action: 'inspect', phase: 'none', requestedSequence: null, recordSequence: null, userCount: 0 });
    expect(invalid.send.clicks).toBe(0);
    const initial = fixture(provider, { response: false }); await finishRound(initial, 1);
    const refused = await initial.run('insert', { ...fields(2), submissionMarker: firstMarker, expectedUserCounts: [1], prompt: roundPrompt(1) });
    expect(check(refused, 'begin_admission')).toMatchObject({ action: 'insert', phase: 'verified', requestedSequence: 2, recordSequence: 1 });
    expect(initial.send.clicks).toBe(1);
    const altered = fixture(provider, { response: false }); await finishRound(altered, 1);
    const text = await stage(altered, 2), send = altered.send.onClick!;
    altered.send.onClick = () => { send(); altered.userBody!.text = altered.userBody!.text.replace('[literal]', '{altered}'); };
    const rejected = await submitThenInspect(altered, 2, text);
    expect(check(rejected, 'observe_text')).toMatchObject({ action: 'inspect', phase: 'send_claimed', requestedSequence: 2,
      recordSequence: 2, userCount: 2, stateRevoked: true, canonicalMatches: false, suffixMatches: true });
    expect(altered.send.clicks).toBe(2);
  });

  test('submission diagnostic failure cannot replace the refusal or revive its private record', async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1);
    const record = f.world.__computaGeminiSubmissionState.lastVerified;
    record.phase = 'PRIVATE_PHASE';
    Object.defineProperty(record, 'canonical', { get() { throw new Error('PRIVATE_DIAGNOSTIC_GETTER'); } });
    const rejected = await f.run('inspect', { ...fields(1), expectedUserCounts: [1] });
    expect(rejected).toEqual({ error: 'conversation_changed', detail: 'submission_message' });
    expect(f.world.__computaGeminiSubmissionState.revoked).toBe(true);
    expect(f.send.clicks).toBe(1); expect(JSON.stringify(rejected)).not.toContain('PRIVATE');
  });

  test('post-digest diagnostics distinguish connected body changes root replacements and private state failures', async () => {
    const flags = ['stateSame', 'stateRevoked', 'recordRetained', 'parentRequired', 'parentIntact', 'remountRequired',
      'remountIntact', 'contextMatches', 'rootCountMatches', 'rootsSame', 'firstRootSame', 'currentRootSame',
      'rootConnected', 'bodyConnected', 'bodySame', 'payloadAvailable', 'payloadWithinLimit',
      'bodyTextUnchanged', 'bodyCanonicalMatches', 'priorIntact', 'digestMatches'];
    for (const fault of ['text', 'currentRoot', 'olderRoot', 'bodyOnly', 'state', 'digest']) {
      const f = fixture(provider, { response: false });
      await finishRound(f, 1); await finishRound(f, 2); const healthy = await finishRound(f, 3);
      expect(healthy.submissionDigestDiagnostic).toBeUndefined();
      const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
      const replace = (old: Element) => {
        const parent = old.parentElement!, fresh = old.cloneNode(true);
        parent.children[parent.children.indexOf(old)] = fresh; fresh.parentElement = parent; old.connected = false;
      };
      const subtle: any = crypto.subtle, original = subtle.digest; let changed = false;
      subtle.digest = async (algorithm: any, data: any) => {
        const digest = await original.call(subtle, algorithm, data);
        if (!changed && new TextDecoder().decode(data) === normalized(roundPrompt(3))) {
          changed = true;
          if (fault === 'text') record.body.text = record.body.text.replace('[literal]', '{altered}');
          else if (fault === 'currentRoot') replace(record.root);
          else if (fault === 'olderRoot') replace(f.messages.querySelectorAll('user-query')[1]);
          else if (fault === 'bodyOnly') replace(record.body);
          else if (fault === 'state') f.world.__computaGeminiSubmissionState = { ...state };
          else record.fingerprint = '0'.repeat(64);
        }
        return digest;
      };
      let rejected: any;
      try { rejected = await f.run('verifyModel', { ...fields(3), expectedUserCounts: [3] }); }
      finally { subtle.digest = original; }
      expect(changed).toBe(true);
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionDiagnostic: { stage: 'observe_digest', stateRevoked: true } });
      const diagnostic = rejected.submissionDigestDiagnostic;
      expect(Object.keys(diagnostic).sort()).toEqual([...flags, 'kind', 'projectedLength'].sort());
      expect(diagnostic.kind).toBe('gemini_submission_digest_v1');
      for (const flag of flags) expect(typeof diagnostic[flag]).toBe('boolean');
      expect(Number.isInteger(diagnostic.projectedLength) && diagnostic.projectedLength >= 0 && diagnostic.projectedLength <= 180201).toBe(true);
      expect(diagnostic).toMatchObject({ stateRevoked: false, parentRequired: false, parentIntact: true,
        remountRequired: false, remountIntact: true, rootCountMatches: true, firstRootSame: true });
      if (fault === 'text') expect(diagnostic).toMatchObject({ rootsSame: true, bodySame: true, rootConnected: true,
        bodyConnected: true, bodyTextUnchanged: false, bodyCanonicalMatches: false, digestMatches: true });
      if (fault === 'currentRoot') expect(diagnostic).toMatchObject({ rootsSame: false, currentRootSame: false,
        rootConnected: false, bodyConnected: false });
      if (fault === 'olderRoot') expect(diagnostic).toMatchObject({ rootsSame: false, currentRootSame: true,
        rootConnected: true, bodyConnected: true, bodyTextUnchanged: true });
      if (fault === 'bodyOnly') expect(diagnostic).toMatchObject({ rootsSame: true, currentRootSame: true,
        rootConnected: true, bodyConnected: false, bodySame: false });
      if (fault === 'state') expect(diagnostic.stateSame).toBe(false);
      if (fault === 'digest') expect(diagnostic).toMatchObject({ digestMatches: false, bodyTextUnchanged: true });
      const encoded = JSON.stringify(diagnostic);
      expect(encoded.length).toBeLessThanOrEqual(960);
      for (const privateValue of ['PRIVATE', marker(3), record.canonical, 'https:']) expect(encoded).not.toContain(privateValue);
      expect(rejected.submissionProof).toBeUndefined(); expect(rejected.replacementSubmissionProof).toBeUndefined();
      expect(f.world.__computaGeminiSubmissionState.revoked).toBe(true); expect(f.send.clicks).toBe(3);
      expect(await f.run('inspect', { ...fields(3), expectedUserCounts: [3] })).toHaveProperty('error');
      expect(await f.run('submit', { ...fields(3), expectedUserCounts: [3], prompt: roundPrompt(3) })).toHaveProperty('error');
      expect(f.send.clicks).toBe(3);
    }
  });

  test('post-digest prior-body corruption remains rejected and missing diagnostics cannot turn a refusal into proof', async () => {
    for (const diagnosticThrows of [false, true]) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1); await finishRound(f, 2);
      const prior = f.world.__computaGeminiSubmissionState.lastVerified;
      const text = await stage(f, 3); await submitPending(f, 3, text);
      const record = f.world.__computaGeminiSubmissionState.pending;
      const rejected = await withDigestMutation(f, 3, 'send_claimed', () => {
        prior.body.text = prior.body.text.replace('[literal]', '{altered}');
        if (diagnosticThrows) Object.defineProperty(record, 'sequence', { get() { throw new Error('PRIVATE_DIAGNOSTIC_GETTER'); } });
      }, () => f.run('inspect', { ...fields(3), expectedUserCounts: [3] }));
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      if (diagnosticThrows) expect(rejected.submissionDigestDiagnostic).toBeUndefined();
      else expect(rejected.submissionDigestDiagnostic).toMatchObject({ priorIntact: false, bodyTextUnchanged: true,
        bodyCanonicalMatches: true, rootsSame: true, digestMatches: true });
      expect(rejected.submissionProof).toBeUndefined(); expect(JSON.stringify(rejected)).not.toContain('PRIVATE');
      expect(f.world.__computaGeminiSubmissionState.revoked).toBe(true); expect(f.send.clicks).toBe(3);
    }
  });

  const maskedFirstSubmissionFailure = async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1);
    const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
    const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
    const expectedModelChoice = { key: '3.1 Pro', label: '3.1 Pro' };
    const subtle: any = crypto.subtle, original = subtle.digest; let hashes = 0;
    subtle.digest = async (algorithm: any, data: any) => {
      const result = await original.call(subtle, algorithm, data);
      if (new TextDecoder().decode(data) === normalized(roundPrompt(1)) && ++hashes === 2) replaceBoundRoot(f);
      return result;
    };
    let discarded: any;
    try { discarded = await f.run('inspect', { ...fields(1), expectedUserCounts: [1], expectedModelChoice }); }
    finally { subtle.digest = original; }
    // The outer first-lineage discard masks the inner submission refusal.
    // Its existing result and one-read recovery policy are intentionally unchanged.
    expect(discarded).toEqual({ error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
    expect(state.revoked).toBe(true); expect(record.remount).toBeNull(); expect(f.send.clicks).toBe(1);
    return { f, state, record };
  };

  test('first finite submission failure survives a masked cross-root discard and later revoked inspection', async () => {
    const { f, state, record } = await maskedFirstSubmissionFailure();
    const cache = f.world.__computaGeminiSubmissionFailures, retained = cache.get(state);
    expect(Object.isFrozen(retained.bundle)).toBe(true);
    expect(Object.isFrozen(retained.bundle.digestDiagnostic)).toBe(true);
    const rejected = await f.run('inspect', { ...fields(1), expectedUserCounts: [1] });
    expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
      submissionDiagnostic: { stage: 'observe_state', stateRevoked: true },
      submissionFirstFailure: { firstFailureKind: 'gemini_submission_first_failure_v1', stage: 'observe_digest',
        action: 'inspect', sequence: 1, digestDiagnostic: { stateSame: true, stateRevoked: false,
          recordRetained: true, rootsSame: false, firstRootSame: false, currentRootSame: false,
          rootConnected: false, bodyConnected: false, digestMatches: true } } });
    expect(rejected.submissionProof).toBeUndefined(); expect(rejected.replacementSubmissionProof).toBeUndefined();
    const again = await f.run('inspect', { ...fields(1), expectedUserCounts: [1] });
    expect(again.submissionFirstFailure).toEqual(rejected.submissionFirstFailure);
    expect(cache.get(state)).toBe(retained); expect(state.lastVerified).toBe(record); expect(state.revoked).toBe(true);
    expect(await f.run('submit', { ...fields(1), expectedUserCounts: [1], prompt: roundPrompt(1) })).toHaveProperty('error');
    expect(f.send.clicks).toBe(1);
    const encoded = JSON.stringify(rejected.submissionFirstFailure);
    for (const secret of ['PRIVATE', marker(1), record.canonical, record.fingerprint, 'https:']) expect(encoded).not.toContain(secret);
  });

  test('first-failure cache cannot follow foreign state record document owner or malformed finite data', async () => {
    for (const fault of ['state', 'transferredState', 'record', 'document', 'owner', 'canonical', 'fingerprint', 'malformed', 'unknownMap']) {
      const { f, state, record } = await maskedFirstSubmissionFailure();
      const cache = f.world.__computaGeminiSubmissionFailures, retained = cache.get(state);
      if (fault === 'state' || fault === 'transferredState') {
        const replacement = { ...state }; f.world.__computaGeminiSubmissionState = replacement;
        if (fault === 'transferredState') cache.set(replacement, retained);
      } else if (fault === 'record') state.lastVerified = { ...record };
      else if (fault === 'document') state.document = {};
      else if (fault === 'owner') state.owner = 'PRIVATE_OTHER_OWNER';
      else if (fault === 'canonical') record.canonical += 'PRIVATE_OTHER_BODY';
      else if (fault === 'fingerprint') record.fingerprint = '0'.repeat(64);
      else if (fault === 'unknownMap') f.world.__computaGeminiSubmissionFailures = { private: 'PRIVATE_MAP' };
      else cache.set(state, { ...retained, bundle: { ...retained.bundle, nonce: 'PRIVATE_NONCE' } });
      const rejected = await f.run('inspect', { ...fields(1), expectedUserCounts: [1] });
      expect(rejected).toHaveProperty('error'); expect(rejected.submissionFirstFailure).toBeUndefined();
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(1);
      expect(JSON.stringify(rejected)).not.toContain('PRIVATE_');
    }
  });

  test('submission diagnostics retain sequence bounds and never accompany healthy proof', async () => {
    for (const sequence of [-1, 10001, true, 'PRIVATE', Infinity]) {
      const f = fixture(provider, { response: false });
      const result = await f.run('inspect', { submissionSequence: sequence, submissionMarker: firstMarker });
      expect(result).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionDiagnostic: { kind: 'gemini_submission_v1', stage: 'invalid_input', requestedSequence: null } });
      expect(result.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(0);
    }
    const f = fixture(provider, { response: false });
    expect((await finishRound(f, 1)).submissionDiagnostic).toBeUndefined();
    expect((await finishRound(f, 2)).submissionDiagnostic).toBeUndefined();
  });

  test('submission body diagnostics distinguish changed bytes from rendered layout without accepting either', async () => {
    const keys = ['kind', 'expectedLength', 'innerTextLength', 'textContentLength', 'expectedLines', 'innerTextLines', 'textContentLines',
      'innerTextMatches', 'textContentMatches', 'innerTextContainsExpected', 'textContentContainsExpected', 'innerTextExpectedOffset', 'textContentExpectedOffset', 'firstMismatchIndex', 'actualCategory', 'expectedCategory', 'literalDOMAvailable',
      'literalDOMMatches', 'literalDOMLength', 'literalDOMUnavailableReason', 'nodeCount', 'maximumDepth', 'paragraphCount', 'brCount',
      'textNodeCount', 'spanCount', 'bodyChildElements'];
    for (const layoutOnly of [false, true]) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      const text = await stage(f, 2), send = f.send.onClick!;
      f.send.onClick = () => {
        send(); const body = f.userBody!, visible = text.replace('[literal]', '{altered}');
        const literal = new Element('SPAN'), node = new Element('#text', {}, layoutOnly ? text : visible);
        (node as any).data = node.text; literal.append(node); body.replaceChildren(literal);
        Object.defineProperty(body, 'innerText', { get: () => visible });
      };
      const rejected = await submitThenInspect(f, 2, text);
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionDiagnostic: { stage: 'observe_text' } });
      const value = rejected.submissionBodyDiagnostic;
      expect(Object.keys(value).sort()).toEqual([...keys].sort());
      expect(value).toMatchObject({ kind: 'gemini_submission_body_v1', innerTextMatches: false,
        textContentMatches: layoutOnly, actualCategory: 'brace', expectedCategory: 'bracket', literalDOMAvailable: true,
        literalDOMMatches: layoutOnly, literalDOMUnavailableReason: 'none', paragraphCount: 0, brCount: 0, textNodeCount: 1 });
      expect(value.firstMismatchIndex).toBe(normalized(text).indexOf('[literal]'));
      expect(value.expectedLength).toBe(normalized(text).length); expect(value.expectedLines).toBe(normalized(text).split('\n').length);
      expect(value.innerTextLength).toBe(text.replace('[literal]', '{altered}').length);
      for (const key of ['expectedLength', 'innerTextLength', 'textContentLength', 'expectedLines', 'innerTextLines', 'textContentLines', 'innerTextExpectedOffset', 'textContentExpectedOffset', 'firstMismatchIndex', 'literalDOMLength'])
        expect(Number.isInteger(value[key]) && value[key] >= 0 && value[key] <= 180201).toBe(true);
      for (const key of ['nodeCount', 'maximumDepth', 'paragraphCount', 'brCount', 'textNodeCount', 'spanCount', 'bodyChildElements'])
        expect(Number.isInteger(value[key]) && value[key] >= 0 && value[key] <= (key === 'maximumDepth' ? 65 : 8193)).toBe(true);
      for (const key of ['innerTextMatches', 'textContentMatches', 'innerTextContainsExpected', 'textContentContainsExpected', 'literalDOMAvailable', 'literalDOMMatches'])
        expect(typeof value[key]).toBe('boolean');
      expect(JSON.stringify(value)).not.toContain('PRIVATE'); expect(JSON.stringify(value)).not.toContain(marker(2));
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
      expect(await f.run('inspect', { ...fields(2), expectedUserCounts: [2] })).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    }
  });

  test('known BR and paragraph literal streams remain diagnostic rather than substitute ownership', async () => {
    for (const paragraphs of [false, true]) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      const text = `PRIVATE paragraph A\nparagraph B\n\nComputa session marker: ${marker(2)}`;
      await stage(f, 2, text); const send = f.send.onClick!;
      f.send.onClick = () => {
        send(); const body = f.userBody!; body.replaceChildren();
        const parts = text.split('\n');
        for (const [index, part] of parts.entries()) {
          const node = new Element('#text', {}, part); (node as any).data = part;
          if (paragraphs) { const paragraph = new Element('P'); paragraph.append(node); body.append(paragraph); }
          else { if (index) body.append(new Element('BR')); body.append(node); }
        }
        Object.defineProperty(body, 'innerText', { get: () => text.replace('\n', ' ') });
        Object.defineProperty(body, 'textContent', { get: () => parts.join('') });
      };
      const rejected = await submitThenInspect(f, 2, text);
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionBodyDiagnostic: { innerTextMatches: false, textContentMatches: false, literalDOMAvailable: true,
          literalDOMMatches: true, literalDOMUnavailableReason: 'none', actualCategory: 'space', expectedCategory: 'linefeed',
          paragraphCount: paragraphs ? 4 : 0, brCount: paragraphs ? 0 : 3, textNodeCount: 4 } });
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
    }
  });

  test('hidden controls unknown markup and exhausted literal budgets cannot produce an available submission body diagnostic', async () => {
    for (const shape of ['hidden', 'inert', 'control', 'markup', 'depth', 'nodes', 'length', 'getter']) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      const text = await stage(f, 2), send = f.send.onClick!;
      f.send.onClick = () => {
        send(); const body = f.userBody!, node = new Element('#text', {}, text); (node as any).data = text;
        body.replaceChildren();
        const wrapper = new Element(shape === 'markup' ? 'EM' : 'SPAN');
        if (shape === 'hidden') wrapper.values.hidden = '';
        if (shape === 'inert') wrapper.values.inert = '';
        if (shape === 'control') wrapper.values.role = 'link';
        body.append(wrapper);
        let parent = wrapper;
        if (shape === 'depth') for (let i = 0; i < 65; i++) { const child = new Element('SPAN'); parent.append(child); parent = child; }
        if (shape === 'nodes') for (let i = 0; i < 8192; i++) body.append(new Element('SPAN'));
        if (shape === 'length') (node as any).data = 'X'.repeat(180201);
        parent.append(node);
        Object.defineProperty(body, 'innerText', { get: () => text.replace('[literal]', '{altered}') });
        if (shape === 'getter') Object.defineProperty(body, 'textContent', { get() { throw new Error('PRIVATE_BODY_GETTER'); } });
      };
      const rejected = await submitThenInspect(f, 2, text);
      const reason = ({ control: 'control', markup: 'unsupported_markup', depth: 'depth_budget', nodes: 'node_budget',
        length: 'length_budget', getter: 'read_failure', hidden: 'hidden', inert: 'inert' } as any)[shape];
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionBodyDiagnostic: { literalDOMAvailable: false, literalDOMMatches: false, literalDOMUnavailableReason: reason } });
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
      expect(JSON.stringify(rejected.submissionBodyDiagnostic)).not.toContain('PRIVATE');
      expect(JSON.stringify(rejected.submissionBodyDiagnostic)).not.toContain(marker(2));
    }
  });

  test('submission structure prioritizes current body children and distinguishes leading UI from the full outbound payload', async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1);
    const text = await stage(f, 2), send = f.send.onClick!, prefix = 'UI PRIVATE LABEL\n\n';
    f.send.onClick = () => {
      send(); const body = f.userBody!, wrapper = new Element('DIV', { class: 'query-text private_canary' });
      const label = new Element('#text', {}, prefix); (label as any).data = prefix;
      const payload = new Element('SPAN', { class: 'user-query-payload' });
      const node = new Element('#text', {}, text); (node as any).data = text;
      payload.append(node); wrapper.append(label, payload); body.replaceChildren(wrapper);
    };
    const rejected = await submitThenInspect(f, 2, text);
    expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
      submissionBodyDiagnostic: { innerTextMatches: false, textContentMatches: false, innerTextContainsExpected: true,
        textContentContainsExpected: true, innerTextExpectedOffset: prefix.length, textContentExpectedOffset: prefix.length,
        firstMismatchIndex: 0, literalDOMAvailable: false, literalDOMUnavailableReason: 'unsupported_markup' } });
    const structure = JSON.parse(rejected.debugSubmissionStructure);
    expect(structure).toMatchObject({ kind: 'first_user_structure', provider: 'gemini', reason: 'submission_text',
      descendantScope: 'selected_body', root: { tag: 'user-query' }, body: { tag: 'span' }, markerMatches: true });
    expect(structure.descendants[0]).toMatchObject({ tag: 'div', path: [0], classes: ['query-text'], childElements: 1,
      controls: 0, markerContained: true, outboundInnerTextMatches: false, outboundTextContentMatches: false });
    expect(structure.descendants[1]).toMatchObject({ tag: 'span', path: [0, 0], classes: ['user-query-payload'],
      outboundInnerTextMatches: true, outboundTextContentMatches: true });
    expect(structure.descendants.length).toBeLessThanOrEqual(16);
    expect(rejected.debugSubmissionStructure).not.toContain('PRIVATE'); expect(rejected.debugSubmissionStructure).not.toContain('private_canary');
    expect(rejected.debugSubmissionStructure).not.toContain(marker(2)); expect(rejected.submissionProof).toBeUndefined();
    expect(f.send.clicks).toBe(2);
  });

  test('duplicated expected payloads and throwing structural getters cannot create proof or replace a refusal', async () => {
    for (const mode of ['duplicate', 'getter', 'oversized']) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      const text = await stage(f, 2), send = f.send.onClick!;
      f.send.onClick = () => {
        send(); const body = f.userBody!, wrapper = new Element('DIV'), span = new Element('SPAN');
        const value = mode !== 'duplicate' ? text.replace('[literal]', '{altered}') : text + '\n' + text;
        const node = new Element('#text', {}, value); (node as any).data = value;
        span.append(node); wrapper.append(span); body.replaceChildren(wrapper);
        if (mode === 'getter') Object.defineProperty(span, 'innerText', { get() { throw new Error('PRIVATE_STRUCTURE_GETTER'); } });
        if (mode === 'oversized') {
          Object.defineProperty(span, 'textContent', { get: () => 'X'.repeat(180201) });
          Object.defineProperty(body, 'innerText', { get: () => value });
          Object.defineProperty(body, 'textContent', { get: () => value });
        }
      };
      const rejected = await submitThenInspect(f, 2, text);
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionBodyDiagnostic: { innerTextContainsExpected: false, textContentContainsExpected: false,
          innerTextExpectedOffset: 180201, textContentExpectedOffset: 180201 } });
      if (mode === 'getter') expect(rejected.debugSubmissionStructure).toBeUndefined();
      if (mode === 'oversized') {
        const structure = JSON.parse(rejected.debugSubmissionStructure);
        expect(structure.descendants.every((node: any) => node.outboundInnerTextMatches === false && node.outboundTextContentMatches === false)).toBe(true);
        expect(structure.descendants.every((node: any) => node.textLength === 220001)).toBe(true);
      }
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
      expect(JSON.stringify(rejected)).not.toContain('PRIVATE_STRUCTURE_GETTER');
    }
  });

  test('an earlier current body changed during next insertion hashing prevents any new editor input', async () => {
    const f = fixture(provider, { response: false }); await finishRound(f, 1); await finishRound(f, 2);
    const inputs = f.composer.events.length;
    expect(await f.run('prepare', { ...fields(2), expectedUserCounts: [2] })).toMatchObject({ prepared: true });
    const rejected = await withDigestMutation(f, 3, 'insert_claimed', () => { f.userBody!.text += ' altered'; },
      () => f.run('insert', { ...fields(3), expectedUserCounts: [2], prompt: roundPrompt(3) }));
    expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    expect(f.composer.textContent).toBe(''); expect(f.composer.events.length).toBe(inputs); expect(f.send.clicks).toBe(2);
  });

  const clippedStyle = { visibility: 'visible', display: 'block', position: 'absolute', width: '1px', height: '1px',
    overflow: 'hidden', clip: 'rect(0px, 0px, 0px, 0px)', clipPath: 'inset(50%)' };
  function queryFixture(framed = false) {
    const styles = new Map<Element, Record<string, unknown>>();
    const f = fixture(provider, { response: false,
      computedStyle: node => styles.get(node) ?? { visibility: node.values.visibility || 'visible', display: 'block' } });
    const shapes: { query: Element; heading: Element; rows: Element[] }[] = [];
    const textNode = (text: string) => { const node = new Element('#text', {}, text); (node as any).data = text; return node; };
    const send = f.send.onClick!;
    f.send.onClick = () => {
      const text = f.composer.innerText; send();
      const query = new Element('DIV', { class: 'query-text gds-body-l' });
      const heading = new Element('H2', { class: 'cdk-visually-hidden' });
      const label = new Element('SPAN'); label.append(textNode('PRIVATE screen-reader query heading')); heading.append(label);
      styles.set(heading, { ...clippedStyle }); query.append(heading);
      const rows = text.replace(/\r\n?/g, '\n').split('\n').map((line, index) => {
        const row = new Element('P', { class: 'query-text-line ng-star-inserted' });
        const rendered = framed ? ' ' + line + ' ' : line;
        if (!line) row.append(new Element('BR'));
        else if (index % 3 === 0) { const span = new Element('SPAN', { class: 'ng-star-inserted' }); span.append(textNode(rendered)); row.append(span); }
        else row.append(textNode(rendered));
        query.append(row); return row;
      });
      f.userBody!.replaceChildren(query);
      Object.defineProperty(f.userBody!, 'innerText', { configurable: true,
        get: () => heading.textContent + '\n\n' + rows.map(row => row.innerText).join('\n\n') });
      shapes.push({ query, heading, rows });
    };
    return { f, styles, shapes, textNode };
  }

  test('measured query paragraphs preserve all 169 lines and seven independent full-body round proofs', async () => {
    const { f, shapes } = queryFixture();
    const lines = Array.from({ length: 167 }, (_, i) => i === 5 ? '' : `PRIVATE line ${i}: \t  [literal] e\u0301\u00a0\u200b tail `);
    const firstText = lines.join('\n') + '\n\n' + markerLine;
    const first = await finishRound(f, 1, firstText);
    expect(shapes[0].rows.length).toBe(169); expect(f.userBody!.innerText).not.toBe(firstText);
    expect(f.userBody!.textContent).not.toBe(firstText);
    const diagnostic = JSON.parse(first.debugStructure);
    expect(diagnostic).toMatchObject({ reason: 'first_bound', lineCount: 169, markerFinalLine: true, markerOccurrences: 1 });
    const header = diagnostic.descendants.find((node: any) => node.classes.includes('cdk-visually-hidden'));
    expect(header).toMatchObject({ tag: 'h2', headingSemantic: true, absolutePosition: true, onePixelBox: true,
      overflowHidden: true, rectClipped: true, insetClipped: true });
    for (let sequence = 2; sequence <= 7; sequence++) {
      const value = await finishRound(f, sequence);
      expect(value.firstUserFingerprint).toBe(first.firstUserFingerprint);
      expect(value.submissionProof).toEqual({ sequence, fingerprint: await fingerprint(roundPrompt(sequence)) });
    }
    expect(f.send.clicks).toBe(7);
    expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE'); expect(JSON.stringify(diagnostic)).not.toContain(firstMarker);
  });

  test('query heading omission requires actual semantic and clipped CSS facts rather than its class', async () => {
    for (const fault of ['class', 'role', 'position', 'box', 'overflow', 'clip', 'moved', 'duplicate']) {
      const { f, shapes, styles } = queryFixture(); const send = f.send.onClick!;
      const text = await stage(f, 1);
      f.send.onClick = () => {
        send(); const { query, heading, rows } = shapes[0];
        if (fault === 'class') heading.values.class = 'ng-star-inserted';
        else if (fault === 'role') heading.values.role = 'presentation';
        else if (fault === 'moved') { query.children.splice(0, 1); query.children.splice(1, 0, heading); }
        else if (fault === 'duplicate') query.append(heading.cloneNode(true));
        else styles.set(heading, { ...clippedStyle,
          ...(fault === 'position' ? { position: 'relative' } : {}), ...(fault === 'box' ? { width: '2px' } : {}),
          ...(fault === 'overflow' ? { overflow: 'visible' } : {}), ...(fault === 'clip' ? { clip: 'auto', clipPath: 'none' } : {}) });
        expect(rows.length).toBeGreaterThan(0);
      };
      const result = await submitThenInspect(f, 1, text);
      expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      expect(result.firstUserVerified).not.toBe(true); expect(result.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(1);
      if (fault === 'role') {
        const structure = JSON.parse(result.debugStructure);
        expect(structure.descendants.find((node: any) => node.classes.includes('cdk-visually-hidden')))
          .toMatchObject({ headingSemantic: false, rectClipped: true, insetClipped: true });
      }
    }
    for (const clipping of ['rect', 'inset']) {
      const { f, shapes, styles } = queryFixture(), send = f.send.onClick!;
      f.send.onClick = () => { send(); styles.set(shapes.at(-1)!.heading, { ...clippedStyle,
        ...(clipping === 'rect' ? { clip: 'rect(0px 0px 0px 0px)', clipPath: 'none' } : { clip: 'auto' }) }); };
      expect((await finishRound(f, 1)).submissionProof.fingerprint).toBe(await fingerprint(roundPrompt(1)));
    }
  });

  test('recognized query markup rejects hidden controls extra content and malformed rows without rendered fallback', async () => {
    for (const fault of ['control', 'headerControl', 'hidden', 'inert', 'unknown', 'extra', 'outside', 'nested', 'blank', 'break', 'spanClass', 'spanRole', 'queryClass', 'containerClass']) {
      const { f, shapes, textNode } = queryFixture(); const text = await stage(f, 1), send = f.send.onClick!;
      f.send.onClick = () => {
        send(); const { query, heading, rows } = shapes[0], row = rows[0];
        if (fault === 'control') row.append(new Element('BUTTON'));
        else if (fault === 'headerControl') heading.append(new Element('A', { role: 'link' }));
        else if (fault === 'hidden') row.values.hidden = '';
        else if (fault === 'inert') row.values.inert = '';
        else if (fault === 'unknown') { const unknown = new Element('EM'); unknown.append(textNode('PRIVATE ROUND 1: [literal] e\u0301 and whitespace')); row.replaceChildren(unknown); }
        else if (fault === 'extra') { const extra = new Element('P', { class: 'query-text-line' }); extra.append(textNode('EXTRA')); query.append(extra); }
        else if (fault === 'outside') f.userBody!.append(textNode('EXTRA'));
        else if (fault === 'nested') { const wrapper = new Element('DIV'); f.userBody!.replaceChildren(wrapper); wrapper.append(query); query.connected = true; }
        else if (fault === 'blank') rows[1].replaceChildren(textNode(''));
        else if (fault === 'break') row.append(new Element('BR'));
        else if (fault === 'spanClass') row.children[0].values.class = 'unknown';
        else if (fault === 'spanRole') row.children[0].values.role = 'heading';
        else if (fault === 'queryClass') query.values.class = 'gds-body-l';
        else query.values.class = 'query-text';
        // A superficially matching rendered getter must not authorize a malformed rich subtree.
        Object.defineProperty(f.userBody!, 'innerText', { configurable: true, get: () => text });
      };
      const result = await submitThenInspect(f, 1, text);
      if (!result.error) {
        const inspected = await f.run('inspect', { ...fields(1), expectedUserCounts: [1] });
        expect(inspected).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
        expect(inspected.submissionProof).toBeUndefined();
      } else expect(result).toMatchObject({ error: 'conversation_changed' });
      expect(f.send.clicks).toBe(1);
    }
  });

  test('query literal bytes and heading eligibility are rechecked across digest and prior-round admission', async () => {
    for (const fault of ['byte', 'space', 'format', 'css', 'replace']) {
      const { f, shapes, styles, textNode } = queryFixture(); await finishRound(f, 1);
      const text = await stage(f, 2);
      const rejected = await withDigestMutation(f, 2, 'send_claimed', () => {
        const { heading, rows } = shapes[1];
        if (fault === 'css') styles.set(heading, { ...clippedStyle, width: '2px' });
        else if (fault === 'replace') { const span = rows[0].children[0]; span.replaceChildren(textNode('ALTERED')); }
        else { const node = rows[0].children[0].children[0]; (node as any).data += fault === 'space' ? '\u00a0' : fault === 'format' ? '\u200b' : 'X'; node.text = (node as any).data; }
      }, () => submitThenInspect(f, 2, text));
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
      expect(await f.run('inspect', { ...fields(2), expectedUserCounts: [2] })).toMatchObject({ error: 'conversation_changed' });
    }
    const { f, shapes, textNode } = queryFixture(); await finishRound(f, 1);
    shapes[0].rows[0].replaceChildren(textNode('ALTERED'));
    const inputs = f.composer.events.length;
    const refused = await f.run('insert', { ...fields(2), expectedUserCounts: [1], prompt: roundPrompt(2) });
    expect(refused).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(f.send.clicks).toBe(1); expect(f.composer.events.length).toBe(inputs); expect(f.composer.textContent).toBe('');
  });

  test('query payload budgets and physical body aliases cannot bypass exact full-body proof', async () => {
    for (const fault of ['length', 'headerLength', 'nodes', 'depth', 'alias']) {
      const { f, shapes, textNode } = queryFixture(); const text = await stage(f, 1), send = f.send.onClick!;
      f.send.onClick = () => {
        send(); const { query, heading, rows } = shapes[0];
        if (fault === 'length') rows[0].replaceChildren(textNode('X'.repeat(180201)));
        else if (fault === 'headerLength') heading.children[0].replaceChildren(textNode('X'.repeat(8193)));
        else if (fault === 'nodes') for (let i = 0; i < 8192; i++) rows[0].append(new Element('SPAN'));
        else if (fault === 'depth') { let parent = rows[0]; parent.replaceChildren(); for (let i = 0; i < 65; i++) { const child = new Element('SPAN'); parent.append(child); parent = child; } parent.append(textNode(text.split('\n')[0])); }
        else f.userBody!.append(query.cloneNode(true));
      };
      const result = await submitThenInspect(f, 1, text);
      expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      expect(result.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(1);
    }
    const { f, shapes, textNode } = queryFixture(), send = f.send.onClick!;
    const suffix = '\n\n' + markerLine, text = 'X'.repeat(180000 - suffix.length) + suffix;
    f.send.onClick = () => { send(); shapes[0].heading.children[0].replaceChildren(textNode('X'.repeat(409))); };
    const value = await finishRound(f, 1, text);
    expect(f.userBody!.innerText.length).toBeGreaterThan(180200);
    expect(value.submissionProof).toEqual({ sequence: 1, fingerprint: await fingerprint(text) });
    expect(f.send.clicks).toBe(1);
  });

  test('one uniform ASCII-space frame preserves user indentation and 169 exact rows across seven owned rounds', async () => {
    const { f, shapes } = queryFixture(true);
    const lines = Array.from({ length: 167 }, (_, i) => i % 8 === 0 ? '' : `PRIVATE ${i}:  \t  [literal] e\u0301\u00a0\u200b tail  `);
    lines[0] = 'PRIVATE first line';
    const text = lines.join('\n') + '\n\n' + markerLine, first = await finishRound(f, 1, text);
    const diagnostic = JSON.parse(first.debugStructure), query = diagnostic.queryTemplate;
    const keys = ['kind', 'expectedAvailable', 'rowCount', 'brRowCount', 'textRowCount', 'directTextNodeMin', 'directTextNodeMax',
      'allTextRowsSingleFrame', 'rawWholeMatches', 'singleFrameWholeMatches', 'rawRowMatches', 'singleFrameRowMatches',
      'leadingSpaceRows', 'trailingSpaceRows', 'selectedMode'];
    expect(Object.keys(query).sort()).toEqual(keys.sort());
    expect(query).toMatchObject({ kind: 'gemini_query_template_v1', expectedAvailable: true, rowCount: 169,
      allTextRowsSingleFrame: true, rawWholeMatches: false, singleFrameWholeMatches: true,
      rawRowMatches: query.brRowCount, singleFrameRowMatches: 169, selectedMode: 'ascii_space_frame_v1' });
    expect(query.textRowCount + query.brRowCount).toBe(169);
    expect(query.leadingSpaceRows).toBe(query.textRowCount); expect(query.trailingSpaceRows).toBe(query.textRowCount);
    expect(query.directTextNodeMin).toBe(0); expect(query.directTextNodeMax).toBe(1);
    expect(diagnostic).toMatchObject({ descendantScope: 'selected_body', lineCount: 169, markerFinalLine: true });
    expect(shapes[0].rows[1].textContent).toBe(' ' + lines[1] + ' ');
    expect(first.firstUserFingerprint).toBe(await fingerprint(text));
    for (let sequence = 2; sequence <= 7; sequence++) {
      const current = await finishRound(f, sequence);
      expect(current.firstUserFingerprint).toBe(first.firstUserFingerprint);
      expect(current.submissionProof).toEqual({ sequence, fingerprint: await fingerprint(roundPrompt(sequence)) });
    }
    for (const key of ['expectedAvailable', 'allTextRowsSingleFrame', 'rawWholeMatches', 'singleFrameWholeMatches'])
      expect(typeof query[key]).toBe('boolean');
    for (const key of keys.filter(key => !['kind', 'selectedMode', 'expectedAvailable', 'allTextRowsSingleFrame', 'rawWholeMatches', 'singleFrameWholeMatches'].includes(key)))
      expect(Number.isInteger(query[key]) && query[key] >= 0 && query[key] <= 8192).toBe(true);
    expect(JSON.stringify(query)).not.toContain('PRIVATE'); expect(JSON.stringify(query)).not.toContain(firstMarker);
    expect(f.send.clicks).toBe(7);
  }, 10_000);

  test('space framing is uniform whole-body selection and cannot repair mixed formats whitespace or changed content', async () => {
    const text = 'PRIVATE first\n  user indentation and trailing  \nPRIVATE third [literal]\n\n' + markerLine;
    for (const fault of ['mixed', 'double', 'left', 'right', 'nbsp', 'tab', 'content', 'marker', 'trimUser']) {
      const { f, shapes, textNode } = queryFixture(true), send = f.send.onClick!;
      await stage(f, 1, text);
      f.send.onClick = () => {
        send(); const rows = shapes[0].rows;
        if (fault === 'double') for (const row of rows.filter(row => row.children[0].tagName !== 'BR'))
          row.replaceChildren(textNode(' ' + row.textContent + ' '));
        else {
          const row = rows[2], raw = row.textContent;
          const altered = fault === 'mixed' ? raw.slice(1, -1) : fault === 'left' ? raw.slice(1)
            : fault === 'right' ? raw.slice(0, -1) : fault === 'nbsp' ? '\u00a0' + raw.slice(1, -1) + '\u00a0'
            : fault === 'tab' ? '\t' + raw.slice(1, -1) + '\t' : fault === 'content' ? raw.replace('[literal]', '{altered}') : raw;
          row.replaceChildren(textNode(altered));
          if (fault === 'marker') rows.at(-1)!.replaceChildren(textNode(' Computa session marker: ' + marker(2) + ' '));
          if (fault === 'trimUser') rows[1].replaceChildren(textNode(' ' + rows[1].textContent.trim() + ' '));
        }
      };
      const rejected = await submitThenInspect(f, 1, text);
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(1);
    }
    const { f, shapes } = queryFixture(true); await finishRound(f, 1);
    const text2 = await stage(f, 2);
    const crossed = await withDigestMutation(f, 2, 'send_claimed', () => {
      const node = shapes[1].rows[0].children[0].children[0]; (node as any).data += 'X'; node.text = (node as any).data;
    }, () => submitThenInspect(f, 2, text2));
    expect(crossed).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
    expect(crossed.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
  });

  test('framed expected text belongs only to its private document owner nonce ordinal and physical body', async () => {
    for (const fault of ['document', 'owner', 'firstNonce', 'ordinal', 'recordNonce', 'bodyPointer', 'otherBody']) {
      const { f, shapes, textNode } = queryFixture(true); await finishRound(f, 1);
      if (['document', 'owner', 'firstNonce'].includes(fault)) {
        const context = f.world.__computaModelFirstPromptContext;
        if (fault === 'document') context.document = {};
        else if (fault === 'owner') context.owner = '00000000-0000-0000-0000-000000000000';
        else context.marker = marker(2);
        const inputs = f.composer.events.length;
        const rejected = await f.run('insert', { ...fields(2), expectedUserCounts: [1], prompt: roundPrompt(2) });
        expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
        expect(f.composer.events.length).toBe(inputs); expect(f.send.clicks).toBe(1);
      } else {
        await finishRound(f, 2);
        const record = f.world.__computaGeminiSubmissionState.lastVerified;
        if (fault === 'ordinal') record.sequence = 1;
        else if (fault === 'recordNonce') record.marker = marker(3);
        else if (fault === 'bodyPointer') record.body = shapes[0].query.parentElement;
        else {
          const first = roundPrompt(1).split('\n');
          shapes[1].rows.forEach((row, index) => row.replaceChildren(index === 1 ? new Element('BR') : textNode(' ' + first[index] + ' ')));
        }
        const rejected = await f.run('inspect', { ...fields(2), expectedUserCounts: [2] });
        expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
        expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
      }
    }
    const { f, shapes, textNode } = queryFixture(true); await finishRound(f, 1);
    shapes[0].rows[0].replaceChildren(textNode(' ALTERED '));
    const inputs = f.composer.events.length;
    expect(await f.run('insert', { ...fields(2), expectedUserCounts: [1], prompt: roundPrompt(2) }))
      .toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(f.composer.events.length).toBe(inputs); expect(f.send.clicks).toBe(1);
  });

  function replaceBoundRoot(f: ReturnType<typeof fixture>, styles?: Map<Element, Record<string, unknown>>, sourceRoot?: Element) {
    const record = f.world.__computaGeminiSubmissionState.lastVerified, oldRoot: Element = sourceRoot ?? record.root;
    const oldBody: Element = oldRoot === record.root ? record.body : oldRoot.querySelector('span.user-query-bubble-with-background')!.children
      .find(node => node.tagName === 'SPAN' && node.classList.contains('ng-star-inserted'))!;
    const clone = (node: Element): Element => {
      const copy = node.cloneNode(false);
      if (node.nodeType === 3) (copy as any).data = (node as any).data;
      if (styles?.has(node)) styles.set(copy, { ...styles.get(node)! });
      copy.append(...node.children.map(clone)); return copy;
    };
    const root = clone(oldRoot), parent = oldRoot.parentElement!;
    parent.children[parent.children.indexOf(oldRoot)] = root; root.parentElement = parent; oldRoot.connected = false;
    const body = root.querySelector('span.user-query-bubble-with-background')!.children
      .find(node => node.tagName === 'SPAN' && node.classList.contains('ng-star-inserted'))!;
    return { record, oldRoot, oldBody, root, body };
  }

  test('a whole first root replaced between reads discards verifyModel and only one fresh inspect consumes its certificate', async () => {
    const { f, styles } = queryFixture(true), bound = await finishRound(f, 1);
    const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
    const expectedModelChoice = { key: '3.1 Pro', label: '3.1 Pro' };
    const unchanged = await f.run('verifyModel', { ...fields(1), expectedUserCounts: [1], expectedModelChoice });
    expect(unchanged.submissionProof).toEqual(bound.submissionProof);
    expect(f.world.__computaGeminiSubmissionState.lastVerified.remount).toBeNull();
    const replaced = replaceBoundRoot(f, styles);
    const discard = await f.run('verifyModel', { ...fields(1), expectedUserCounts: [1], expectedModelChoice });
    expect(discard).toEqual({ error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
    expect(replaced.record.root).toBe(replaced.oldRoot); expect(replaced.record.body).toBe(replaced.oldBody);
    expect(replaced.record.remount).toEqual({ previousRoot: replaced.oldRoot, previousBody: replaced.oldBody,
      root: replaced.root, body: replaced.body });
    expect(f.world.__computaGeminiSubmissionState.revoked).toBe(false); expect(f.send.clicks).toBe(1);
    const fresh = await f.run('inspect', { ...fields(1), expectedUserCounts: [1], expectedModelChoice });
    expect(fresh).toMatchObject({ firstUserVerified: true, firstUserFingerprint: bound.firstUserFingerprint,
      submissionProof: bound.submissionProof });
    expect(replaced.record.root).toBe(replaced.root); expect(replaced.record.body).toBe(replaced.body);
    expect(replaced.record.remount).toBeNull(); expect(f.send.clicks).toBe(1);
    expect((await f.run('verifyModel', { ...fields(1), expectedUserCounts: [1], expectedModelChoice })).submissionProof)
      .toEqual(bound.submissionProof);
    expect(replaced.record.remount).toBeNull(); expect(f.send.clicks).toBe(1);
  });

  test('between-read root recovery rejects connected old nodes body-only aliases changed pins and a crossed certificate digest', async () => {
    for (const fault of ['bodyOnly', 'connectedRoot', 'connectedBody', 'canonical', 'nativePin', 'owner', 'count', 'digest', 'wrongFreshBody']) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1);
      const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
      const expectedModelChoice = { key: '3.1 Pro', label: '3.1 Pro' }, record = f.world.__computaGeminiSubmissionState.lastVerified;
      let currentBody: Element;
      if (fault === 'bodyOnly') {
        const old: Element = record.body, parent = old.parentElement!, copy = old.cloneNode(true);
        parent.children[parent.children.indexOf(old)] = copy; copy.parentElement = parent; old.connected = false; currentBody = copy;
      } else {
        const replaced = replaceBoundRoot(f); currentBody = replaced.body;
        if (fault === 'connectedRoot') record.root = f.body;
        if (fault === 'connectedBody') f.body.append(replaced.oldBody);
      }
      if (fault === 'canonical') currentBody.text = currentBody.text.replace('[literal]', '{altered}');
      if (fault === 'owner') f.world.__computaModelOwner = '00000000-0000-0000-0000-000000000000';
      if (fault === 'count') f.appendUser('UNEXPECTED');
      const args = { ...fields(1), expectedUserCounts: [1], expectedModelChoice,
        ...(fault === 'nativePin' ? { expectedFirstUserFingerprint: '0'.repeat(64) } : {}) };
      let rejected: any;
      if (fault === 'digest') {
        const subtle: any = crypto.subtle, original = subtle.digest; let hashes = 0;
        subtle.digest = async (algorithm: any, data: any) => {
          const digest = await original.call(subtle, algorithm, data);
          if (new TextDecoder().decode(data) === normalized(roundPrompt(1)) && ++hashes === 2) currentBody.text += ' altered';
          return digest;
        };
        try { rejected = await f.run('verifyModel', args); expect(hashes).toBe(2); }
        finally { subtle.digest = original; }
      } else if (fault === 'wrongFreshBody') {
        expect(await f.run('verifyModel', args)).toMatchObject({ error: 'first_user_observation_replaced' });
        replaceBoundRoot(f, undefined, record.remount.root); // A second candidate cannot overwrite the unconsumed certificate.
        rejected = await f.run('inspect', args);
      } else rejected = await f.run('verifyModel', args);
      expect(rejected.error).toBeDefined(); expect(rejected.error).not.toBe('first_user_observation_replaced');
      expect(rejected.submissionProof).toBeUndefined(); expect(rejected.text).toBeUndefined(); expect(f.send.clicks).toBe(1);
      if (fault !== 'wrongFreshBody') expect(record.remount).toBeNull();
      if (fault === 'bodyOnly') expect(rejected.submissionNodesDiagnostic).toMatchObject({ cause: 'physical_replaced',
        rootSame: true, bodySame: false, oldRootConnected: true, oldBodyConnected: false,
        currentRootConnected: true, currentBodyConnected: true, projectedCanonicalMatches: true });
    }
  });

  test('observe-body diagnostics preserve exact finite causes and never accompany healthy proof', async () => {
    const keys = ['kind', 'cause', 'rootSame', 'bodySame', 'oldRootConnected', 'oldBodyConnected',
      'currentRootConnected', 'currentBodyConnected', 'remountCertificatePresent', 'projectedCanonicalMatches'];
    for (const cause of ['body_missing', 'payload_type', 'payload_limit', 'physical_replaced']) {
      const f = fixture(provider, { response: false }); await finishRound(f, 1); const good = await finishRound(f, 2);
      expect(good.submissionNodesDiagnostic).toBeUndefined();
      const record = f.world.__computaGeminiSubmissionState.lastVerified, body: Element = record.body;
      if (cause === 'body_missing') body.values.class = 'unrecognized';
      else if (cause === 'payload_type') Object.defineProperty(body, 'innerText', { get: () => ({ private: 'PRIVATE' }) });
      else if (cause === 'payload_limit') Object.defineProperty(body, 'innerText', { get: () => 'PRIVATE'.repeat(26000) });
      else {
        const parent = body.parentElement!, copy = body.cloneNode(true);
        parent.children[parent.children.indexOf(body)] = copy; copy.parentElement = parent; body.connected = false;
      }
      const rejected = await f.run('inspect', { ...fields(2), expectedUserCounts: [2] });
      expect(rejected).toMatchObject({ error: 'conversation_changed', detail: 'submission_message', submissionDiagnostic: { stage: 'observe_body' } });
      const diagnostic = rejected.submissionNodesDiagnostic;
      expect(Object.keys(diagnostic).sort()).toEqual([...keys].sort());
      expect(diagnostic).toMatchObject({ kind: 'gemini_submission_nodes_v1', cause, remountCertificatePresent: false });
      for (const key of keys.slice(2)) expect(typeof diagnostic[key]).toBe('boolean');
      expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE'); expect(JSON.stringify(diagnostic)).not.toContain(marker(2));
      expect(JSON.stringify(diagnostic)).not.toContain('https:'); expect(rejected.submissionProof).toBeUndefined(); expect(f.send.clicks).toBe(2);
    }
  });

  const nativePins = async (...sequences: number[]) => Promise.all(sequences.map(async sequence => ({ sequence,
    fingerprint: await fingerprint(roundPrompt(sequence)) })));

  const verifiedFive = async () => {
    const q = queryFixture(true);
    let bound: any;
    for (let sequence = 1; sequence <= 5; sequence++) bound = await finishRound(q.f, sequence);
    const args = { ...fields(5), expectedUserCounts: [5], expectedSubmissionProofs: await nativePins(4, 5) };
    return { ...q, bound, args };
  };
  const mutateVerifiedDigest = async (f: ReturnType<typeof fixture>, mutate: (hash: number) => void,
    operation: () => Promise<any>) => {
    const subtle: any = crypto.subtle, original = subtle.digest;
    let hashes = 0;
    subtle.digest = async (algorithm: any, data: any) => {
      const digest = await original.call(subtle, algorithm, data);
      if (new TextDecoder().decode(data) === normalized(roundPrompt(5))) mutate(++hashes);
      return digest;
    };
    try { const result = await operation(); expect(hashes).toBeGreaterThan(0); return result; }
    finally { subtle.digest = original; }
  };

  test('verified fifth query remount during its digest discards once before exact fresh proof without another action', async () => {
    const { f, styles, bound, args } = await verifiedFive();
    const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
    const first = f.messages.querySelectorAll('user-query')[0], events = f.composer.events.length;
    let replaced: ReturnType<typeof replaceBoundRoot> | undefined;
    const discard = await mutateVerifiedDigest(f, hash => {
      if (hash === 1) replaced = replaceBoundRoot(f, styles);
    }, () => f.run('inspect', args));
    expect(discard).toEqual({ error: 'submission_observation_replaced', detail: 'readonly_model_observation',
      replacementSubmissionProof: bound.submissionProof });
    expect(discard.submissionProof).toBeUndefined(); expect(discard.text).toBeUndefined();
    expect(record.root).toBe(replaced!.oldRoot); expect(record.body).toBe(replaced!.oldBody);
    expect(record.root.isConnected).toBe(false); expect(record.body.isConnected).toBe(false);
    expect(record.remount).toMatchObject({ kind: 'submission', sequence: 5, root: replaced!.root, body: replaced!.body });
    expect(state.revoked).toBe(false); expect(f.messages.querySelectorAll('user-query')[0]).toBe(first);
    const fresh = await f.run('inspect', args);
    expect(fresh).toMatchObject({ firstUserFingerprint: bound.firstUserFingerprint, submissionProof: bound.submissionProof });
    expect(record.root).toBe(replaced!.root); expect(record.body).toBe(replaced!.body); expect(record.remount).toBeNull();
    expect(state.revoked).toBe(false); expect(f.send.clicks).toBe(5); expect(f.composer.events.length).toBe(events);
    expect(f.messages.querySelectorAll('user-query')).toHaveLength(5);
  });

  test.each(['body', 'marker', 'bodyOnly', 'donor', 'count', 'owner', 'document', 'mode', 'state', 'firstRoot', 'nativePin'])
    ('post-digest remount recovery preserves refusal for %s', async (fault) => {
    const { f, styles, textNode, args } = await verifiedFive();
    const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
    const events = f.composer.events.length;
    if (fault === 'nativePin') args.expectedSubmissionProofs[1].fingerprint = '0'.repeat(64);
    const denied = await mutateVerifiedDigest(f, hash => {
      if (hash !== 1) return;
      if (fault === 'bodyOnly') {
        const old: Element = record.body, parent = old.parentElement!, copy = old.cloneNode(true);
        parent.children[parent.children.indexOf(old)] = copy; copy.parentElement = parent; old.connected = false;
      } else {
        const replaced = replaceBoundRoot(f, styles), row = replaced.body.querySelector('p.query-text-line')!;
        if (fault === 'body') row.replaceChildren(textNode(' ALTERED '));
        if (fault === 'marker') replaced.body.querySelectorAll('p.query-text-line').at(-1)!.replaceChildren(textNode(' Computa session marker: ' + marker(4) + ' '));
        if (fault === 'donor') {
          const donor = f.messages.querySelectorAll('user-query')[0].querySelector('span.user-query-bubble-with-background')!.children
            .find(node => node.tagName === 'SPAN' && node.classList.contains('ng-star-inserted'))!;
          const rows = replaced.body.querySelectorAll('p.query-text-line'), donorRows = donor.querySelectorAll('p.query-text-line');
          rows.forEach((row, index) => { if (row.children[0]?.tagName !== 'BR') row.replaceChildren(textNode(donorRows[index].textContent)); });
        }
      }
      if (fault === 'count') f.appendUser('UNAUTHORIZED EXTRA USER');
      if (fault === 'owner') f.world.__computaModelOwner = '00000000-0000-0000-0000-000000000000';
      if (fault === 'document') f.document.URL += '/foreign';
      if (fault === 'mode') f.temporary(false);
      if (fault === 'state') f.world.__computaGeminiSubmissionState = { ...state };
      if (fault === 'firstRoot') {
        const first = f.messages.querySelectorAll('user-query')[0], parent = first.parentElement!, copy = first.cloneNode(true);
        parent.children[parent.children.indexOf(first)] = copy; copy.parentElement = parent; first.connected = false;
      }
    }, () => f.run('inspect', args));
    expect(denied.error).toBe('conversation_changed');
    expect(['submission_message', 'first_user_message']).toContain(denied.detail);
    expect(denied.replacementSubmissionProof).toBeUndefined(); expect(denied.submissionProof).toBeUndefined();
    expect(record.remount).toBeNull(); expect(f.send.clicks).toBe(5); expect(f.composer.events.length).toBe(events);
    if (['body', 'marker', 'bodyOnly', 'donor', 'nativePin'].includes(fault)) {
      expect(denied.submissionFirstFailure).toMatchObject({ stage: 'observe_digest', sequence: 5 });
      expect(denied.submissionDigestDiagnostic).toMatchObject({ digestMatches: true });
    }
  });

  test('replacement mutation during recovery hash or another remount cannot buy a second recovery in one read', async () => {
    for (const fault of ['changedDuringRecovery', 'replacedDuringRecovery']) {
      const { f, styles, textNode, args } = await verifiedFive();
      const record = f.world.__computaGeminiSubmissionState.lastVerified;
      let replacement: ReturnType<typeof replaceBoundRoot> | undefined;
      const denied = await mutateVerifiedDigest(f, hash => {
        if (hash === 1) replacement = replaceBoundRoot(f, styles);
        else if (hash === 2) {
          if (fault === 'changedDuringRecovery') replacement!.body.querySelector('p.query-text-line')!.replaceChildren(textNode(' ALTERED DURING RECOVERY '));
          else replaceBoundRoot(f, styles, replacement!.root);
        }
      }, () => f.run('inspect', args));
      expect(denied).toMatchObject({ error: 'conversation_changed', detail: 'submission_message',
        submissionFirstFailure: { stage: 'observe_digest', sequence: 5 } });
      expect(denied.replacementSubmissionProof).toBeUndefined(); expect(record.remount).toBeNull();
      expect(f.send.clicks).toBe(5);
    }
  });

  test('superseded invocation cannot rebind certify revoke or publish a failure into the current private state', async () => {
    for (const supersedeAt of [1, 2]) {
      const { f, styles, bound, args } = await verifiedFive();
      const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
      const firstFailures = f.world.__computaGeminiSubmissionFailures, events = f.composer.events.length;
      let replaced: ReturnType<typeof replaceBoundRoot> | undefined, newer: any;
      const denied = await mutateVerifiedDigest(f, hash => {
        if (hash === 1) replaced = replaceBoundRoot(f, styles);
        if (hash === supersedeAt) {
          newer = Object.freeze({ owner: f.world.__computaModelOwner, document: f.document, operationID: 'later-native-operation' });
          f.world.__computaGeminiReadInvocation = newer;
        }
      }, () => f.run('inspect', args));
      expect(denied).toEqual({ error: 'conversation_changed', detail: 'submission_message' });
      expect(f.world.__computaGeminiReadInvocation).toBe(newer);
      expect(f.world.__computaGeminiSubmissionState).toBe(state); expect(state.revoked).toBe(false);
      expect(record.root).toBe(replaced!.oldRoot); expect(record.body).toBe(replaced!.oldBody); expect(record.remount).toBeNull();
      expect(f.world.__computaGeminiSubmissionFailures).toBe(firstFailures);
      expect(f.send.clicks).toBe(5); expect(f.composer.events.length).toBe(events);
      // This test models a newer/cancelled operation witness, not native task
      // cancellation. A genuinely fresh read still owns its ordinary budget.
      expect(await f.run('inspect', args)).toMatchObject({ error: 'submission_observation_replaced' });
      expect((await f.run('inspect', args)).submissionProof).toEqual(bound.submissionProof);
    }
  });

  test('superseded entry recovery returns no stale diagnostics and preserves the newer private state', async () => {
    const { f, styles, bound, args } = await verifiedFive();
    const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
    const replaced = replaceBoundRoot(f, styles), failures = f.world.__computaGeminiSubmissionFailures;
    let newer: any;
    const denied = await mutateVerifiedDigest(f, hash => {
      if (hash === 1) {
        newer = Object.freeze({ owner: f.world.__computaModelOwner, document: f.document, operationID: 'newer-entry-operation' });
        f.world.__computaGeminiReadInvocation = newer;
      }
    }, () => f.run('inspect', args));
    expect(denied).toEqual({ error: 'conversation_changed', detail: 'submission_message' });
    expect(f.world.__computaGeminiReadInvocation).toBe(newer); expect(state.revoked).toBe(false);
    expect(record.root).toBe(replaced.oldRoot); expect(record.body).toBe(replaced.oldBody); expect(record.remount).toBeNull();
    expect(f.world.__computaGeminiSubmissionFailures).toBe(failures); expect(f.send.clicks).toBe(5);
    expect(await f.run('inspect', args)).toMatchObject({ error: 'submission_observation_replaced' });
    expect((await f.run('inspect', args)).submissionProof).toEqual(bound.submissionProof);
  });

  test('combined first and current root remount under supersession cannot publish an outer snapshot failure', async () => {
    const { f, styles, args } = await verifiedFive();
    const state = f.world.__computaGeminiSubmissionState, record = state.lastVerified;
    const failureCache = f.world.__computaGeminiSubmissionFailures, events = f.composer.events.length;
    let replaced: ReturnType<typeof replaceBoundRoot> | undefined, newer: any;
    const denied = await mutateVerifiedDigest(f, hash => {
      if (hash === 1) replaced = replaceBoundRoot(f, styles);
      if (hash === 2) {
        const first = f.messages.querySelectorAll('user-query')[0], parent = first.parentElement!, copy = first.cloneNode(true);
        parent.children[parent.children.indexOf(first)] = copy; copy.parentElement = parent; first.connected = false;
        newer = Object.freeze({ owner: f.world.__computaModelOwner, document: f.document, operationID: 'newer-combined-operation' });
        f.world.__computaGeminiReadInvocation = newer;
      }
    }, () => f.run('inspect', args));
    expect(denied).toEqual({ error: 'conversation_changed', detail: 'submission_message' });
    expect(f.world.__computaGeminiReadInvocation).toBe(newer); expect(state.revoked).toBe(false);
    expect(record.root).toBe(replaced!.oldRoot); expect(record.body).toBe(replaced!.oldBody); expect(record.remount).toBeNull();
    expect(f.world.__computaGeminiSubmissionFailures).toBe(failureCache);
    expect(f.send.clicks).toBe(5); expect(f.composer.events.length).toBe(events);
  });

  test('native-pinned current-round recovery and next readonly preflight finish before any preparation focus', async () => {
    const { f, styles } = queryFixture(true); await finishRound(f, 1); const second = await finishRound(f, 2);
    const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
    const expectedModelChoice = { key: '3.1 Pro', label: '3.1 Pro' }, expectedSubmissionProofs = await nativePins(1, 2);
    const args = { ...fields(2), expectedUserCounts: [2], expectedModelChoice, expectedSubmissionProofs };
    const firstReplacement = replaceBoundRoot(f, styles);
    expect(await f.run('verifyModel', args)).toEqual({ error: 'submission_observation_replaced', detail: 'readonly_model_observation',
      replacementSubmissionProof: { sequence: 2, fingerprint: await fingerprint(roundPrompt(2)) } });
    expect(firstReplacement.record.root).toBe(firstReplacement.oldRoot); expect(firstReplacement.record.remount.kind).toBe('submission');
    const fresh = await f.run('inspect', args);
    expect(fresh).toMatchObject({ firstUserVerified: true, firstUserFingerprint: second.firstUserFingerprint,
      submissionProof: { sequence: 2, fingerprint: await fingerprint(roundPrompt(2)) } });
    expect(firstReplacement.record.root).toBe(firstReplacement.root); expect(firstReplacement.record.remount).toBeNull();
    const nextReplacement = replaceBoundRoot(f, styles);
    let focuses = 0; const focus = f.composer.onFocus!;
    f.composer.onFocus = () => { focuses++; focus(); };
    const before = f.composer.events.length;
    // Native performs this read before prepare, rather than recovering through
    // a mutation or repeating insertion/Send.
    expect(await f.run('inspect', args)).toMatchObject({ error: 'submission_observation_replaced', replacementSubmissionProof: { sequence: 2 } });
    expect(focuses).toBe(0); expect(f.composer.events.length).toBe(before); expect(f.send.clicks).toBe(2);
    expect((await f.run('inspect', args)).submissionProof).toEqual({ sequence: 2, fingerprint: await fingerprint(roundPrompt(2)) });
    expect(nextReplacement.record.remount).toBeNull(); expect(focuses).toBe(0);
    expect(await f.run('prepare', args)).toMatchObject({ prepared: true }); expect(focuses).toBe(1);
    await finishRound(f, 3); expect(f.send.clicks).toBe(3);
    expect(f.world.__computaGeminiSubmissionState.lastVerified.sequence).toBe(3);
  });

  test('a remounted verified prior round is certified before pending current proof even when its claimed body appends during hashing', async () => {
    for (const appendDuringDigest of [false, true]) {
      const { f, styles } = queryFixture(true); await finishRound(f, 1); await finishRound(f, 2);
      const picker = installObservedModelPicker(f, provider, Element); picker.selected('3.1 Pro');
      const expectedModelChoice = { key: '3.1 Pro', label: '3.1 Pro' };
      const text = await stage(f, 3); f.send.onClick = () => { f.composer.replaceChildren(); };
      expect(await f.run('submit', { ...fields(3), expectedUserCounts: [2], prompt: text })).toMatchObject({ submitted: true, submissionPending: true });
      const prior = replaceBoundRoot(f, styles), expectedSubmissionProofs = await nativePins(2, 3);
      const args = { ...fields(3), expectedUserCounts: [2, 3], expectedSubmissionProofs, expectedModelChoice };
      let discard: any;
      if (appendDuringDigest) {
        const subtle: any = crypto.subtle, original = subtle.digest; let appended = false;
        subtle.digest = async (algorithm: any, data: any) => {
          const digest = await original.call(subtle, algorithm, data);
          if (!appended && new TextDecoder().decode(data) === normalized(roundPrompt(2))) { appended = true; f.appendUser(text); }
          return digest;
        };
        try { discard = await f.run('inspect', args); expect(appended).toBe(true); }
        finally { subtle.digest = original; }
      } else discard = await f.run('inspect', args);
      expect(discard).toEqual({ error: 'submission_observation_replaced', detail: 'readonly_model_observation',
        replacementSubmissionProof: { sequence: 2, fingerprint: await fingerprint(roundPrompt(2)) } });
      expect(discard.submissionProof).toBeUndefined(); expect(discard.text).toBeUndefined(); expect(f.send.clicks).toBe(3);
      expect(prior.record.remount.root).toBe(prior.root); expect(prior.record.root).toBe(prior.oldRoot);
      const fresh = await f.run('inspect', args);
      expect(prior.record.remount).toBeNull(); expect(prior.record.root).toBe(prior.root);
      if (appendDuringDigest) expect(fresh).toMatchObject({ submissionProof: { sequence: 3, fingerprint: await fingerprint(text) } });
      else {
        expect(fresh).toMatchObject({ submissionPending: true, text: '', answerComplete: false,
          submissionProof: { sequence: 2, fingerprint: await fingerprint(roundPrompt(2)) } });
        expect(f.world.__computaGeminiSubmissionState.pending.sequence).toBe(3);
        f.appendUser(text);
        expect(await f.run('inspect', args)).toMatchObject({ submissionProof: { sequence: 3, fingerprint: await fingerprint(text) } });
      }
      expect(f.world.__computaGeminiSubmissionState.lastVerified.sequence).toBe(3); expect(f.send.clicks).toBe(3);
    }
  });

  test('current-round certificates reject malformed native pins unsafe physical aliases and changes during fresh consumption', async () => {
    const good = await nativePins(1, 2), wrong = '0'.repeat(64);
    const invalid: any[] = [undefined, [], [good[0]], [good[1], good[0]], [good[1], good[1]],
      [...good, { sequence: 3, fingerprint: wrong }], [good[0], { sequence: 3, fingerprint: wrong }],
      [good[0], { sequence: 2, fingerprint: wrong }], [good[0], { sequence: true, fingerprint: good[1].fingerprint }],
      [good[0], { sequence: '2', fingerprint: good[1].fingerprint }], [good[0], { ...good[1], extra: true }],
      [good[0], { ...good[1], fingerprint: good[1].fingerprint.toUpperCase() }]];
    for (const expectedSubmissionProofs of invalid) {
      const { f, styles } = queryFixture(true); await finishRound(f, 1); await finishRound(f, 2);
      const replaced = replaceBoundRoot(f, styles);
      const denied = await f.run('inspect', { ...fields(2), expectedUserCounts: [2], expectedSubmissionProofs });
      expect(denied).toMatchObject({ error: 'conversation_changed', detail: 'submission_message' });
      expect(denied.replacementSubmissionProof).toBeUndefined(); expect(replaced.record.remount).toBeNull(); expect(f.send.clicks).toBe(2);
    }
    for (const fault of ['bodyOnly', 'connectedBody', 'canonical', 'consumeBody', 'consumeDigest', 'prepare']) {
      const { f, styles, textNode } = queryFixture(true); await finishRound(f, 1); await finishRound(f, 2);
      const record = f.world.__computaGeminiSubmissionState.lastVerified;
      let replaced: ReturnType<typeof replaceBoundRoot> | null = null;
      if (fault === 'bodyOnly') {
        const old: Element = record.body, parent = old.parentElement!, copy = old.cloneNode(true);
        parent.children[parent.children.indexOf(old)] = copy; copy.parentElement = parent; old.connected = false;
      } else {
        replaced = replaceBoundRoot(f, styles);
        if (fault === 'connectedBody') f.body.append(replaced.oldBody);
        if (fault === 'canonical') replaced.body.querySelector('p.query-text-line')!.replaceChildren(textNode(' ALTERED '));
      }
      const args = { ...fields(2), expectedUserCounts: [2], expectedSubmissionProofs: good };
      let denied: any;
      if (fault.startsWith('consume')) {
        expect(await f.run('inspect', args)).toMatchObject({ error: 'submission_observation_replaced' });
        if (fault === 'consumeBody') { replaceBoundRoot(f, styles, record.remount.root); denied = await f.run('inspect', args); }
        else {
          const subtle: any = crypto.subtle, original = subtle.digest; let changed = false;
          subtle.digest = async (algorithm: any, data: any) => {
            const digest = await original.call(subtle, algorithm, data);
            if (!changed && new TextDecoder().decode(data) === normalized(roundPrompt(2))) {
              changed = true; replaced!.body.querySelector('p.query-text-line')!.replaceChildren(textNode(' ALTERED '));
            }
            return digest;
          };
          try { denied = await f.run('inspect', args); expect(changed).toBe(true); }
          finally { subtle.digest = original; }
        }
      } else denied = await f.run(fault === 'prepare' ? 'prepare' : 'inspect', args);
      expect(denied.error).toBeDefined(); expect(denied.error).not.toBe('submission_observation_replaced');
      expect(denied.submissionProof).toBeUndefined(); expect(denied.text).toBeUndefined(); expect(f.send.clicks).toBe(2);
    }
  });
});

// Matches the prompt-free Gemini 4 observation: normal model picker, exact
// versioned family leaves, and a scoped Selected marker on 4 Argon. Chat/Task
// composer controls are separate; a recognized family does not prove mode.
function observedGeminiArgonPicker(owned = false) {
  const f = fixture(provider, owned ? { userPrompt: prompt } : {});
  const picker = installObservedModelPicker(f, provider, Element, { geminiMenuitemMarkers: true });
  const argon = picker.add(picker.menu, "4 Argon", "Complex tasks");
  picker.selected("4 Argon");
  picker.trigger.values["aria-label"] = "Open mode picker, currently Gemini Argon";
  for (const option of picker.options) {
    const select = option.onClick!;
    option.onClick = () => {
      select();
      picker.trigger.values["aria-label"] = "Open mode picker, currently Gemini " + option.children[0].text.split(" ").slice(1).join(" ");
    };
  }
  return { f, picker, argon };
}

async function advanceGeminiPicker(f: ReturnType<typeof fixture>, action: string, overrides: Record<string, unknown> = {}) {
  let result: any;
  for (let step = 0; step < 6; step++) {
    result = await f.run(action, overrides);
    if (!result.pending) return result;
  }
  return result;
}

describe("observed Gemini Argon family identity", () => {
  test("the observed Argon picker discovers all four families without sending or changing selection", async () => {
    const { f, picker } = observedGeminiArgonPicker();
    const result = await advanceGeminiPicker(f, "discoverModels");
    expect(result.modelChoices).toEqual(["3.5 Flash-Lite", "3.8 Flash", "3.1 Pro", "4 Argon"].map(label => ({ key: label, label })));
    expect(result.modelEvidence.selected).toEqual({ key: "4 Argon", label: "4 Argon" });
    expect(result.modelEvidence.source).toBe("selected_model_indicator");
    expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe("Open mode picker, currently Gemini Argon");
    expect(picker.primary.text).toBe("4 Argon");
    expect(picker.options.every(option => option.clicks === 0)).toBe(true);
    expect(f.send.clicks).toBe(0); expect(f.composer.textContent).toBe("");
  });

  test("Argon selection cannot substitute for the requested Flash family or vice versa", async () => {
    const { f, picker, argon } = observedGeminiArgonPicker();
    const flash = { key: "3.8 Flash", label: "3.8 Flash" };
    expect(await advanceGeminiPicker(f, "selectModel", { modelChoice: flash })).toMatchObject({ selected: true,
      modelEvidence: { selected: flash, source: "model_picker_label" } });
    expect(picker.options.find(option => option.children[0].text === "3.8 Flash")!.clicks).toBe(1);
    expect(argon.clicks).toBe(0);
    expect(await f.run("verifyModel", { expectedModelChoice: { key: "4 Argon", label: "4 Argon" } })).toMatchObject({ error: "model_mismatch" });
    expect(f.send.clicks).toBe(0);
    const actual = observedGeminiArgonPicker(true);
    expect(await actual.f.run("inspect")).toMatchObject({ firstUserVerified: true });
    expect(await actual.f.run("verifyModel", { expectedModelChoice: { key: "4 Argon", label: "4 Argon" } })).toMatchObject({
      modelEvidence: { selected: { key: "4 Argon", label: "4 Argon" } } });
    expect(await actual.f.run("verifyModel", { expectedModelChoice: flash })).toMatchObject({ error: "model_mismatch" });
    expect(actual.f.send.clicks).toBe(0);
  });

  test("Argon still requires unambiguous enabled scoped selected-model evidence", async () => {
    for (const change of [
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.argon.children = p.argon.children.filter(child => child.values["aria-label"] !== "Selected"); },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.argon.values.class = "ng-star-inserted"; p.argon.children = p.argon.children.filter(child => child.values["aria-label"] !== "Selected"); },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.picker.primary.text = "3.8 Flash"; },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.argon.append(new Element("SPAN", { "aria-label": "Selected" })); },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.picker.add(p.picker.menu, "4 Argon", "Duplicate family"); },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.argon.values["aria-hidden"] = "true"; p.picker.primary.text = ""; },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.argon.disabled = true; p.picker.primary.text = ""; },
      (p: ReturnType<typeof observedGeminiArgonPicker>) => { p.f.body.children = p.f.body.children.filter(node => node !== p.picker.trigger); p.f.answer.append(p.picker.trigger); },
    ]) {
      const actual = observedGeminiArgonPicker(true);
      expect(await actual.f.run("inspect")).toMatchObject({ firstUserVerified: true });
      actual.picker.open(); change(actual);
      expect(await actual.f.run("verifyModel", { expectedModelChoice: { key: "4 Argon", label: "4 Argon" } })).toMatchObject({ error: "model_unverified" });
      expect(actual.picker.options.every(option => option.clicks === 0)).toBe(true);
      expect(actual.f.send.clicks).toBe(0);
    }
  });

  test("Argon is an anchored versioned family, never an arbitrary mode or Task label", async () => {
    for (const label of ["Open mode picker, currently Gemini Unknown", "Open mode picker, currently Gemini Argon Task",
      "Open mode picker, currently Gemini Argon Work", "Open mode picker, currently Gemini Argon; click Send",
      "Open mode picker, currently Gemini Argon " + "0".repeat(200)]) {
      const { f, picker } = observedGeminiArgonPicker(); picker.trigger.values["aria-label"] = label;
      expect(await f.run("discoverModels")).toMatchObject({ error: "model_unverified" });
      expect(picker.trigger.clicks).toBe(0); expect(f.send.clicks).toBe(0);
    }
    for (const family of ["Argon", "Gemini 4 Argon", "4 Argon Task", "4 Argon Work", "4 Unknown", "4 Argon; click Send"]) {
      const { f, picker, argon } = observedGeminiArgonPicker(true);
      expect(await f.run("inspect")).toMatchObject({ firstUserVerified: true });
      picker.open();
      picker.primary.text = family; argon.children[0].text = family;
      expect(await f.run("verifyModel", { expectedModelChoice: { key: "4 Argon", label: "4 Argon" } })).toMatchObject({ error: "model_unverified" });
      expect(picker.options.every(option => option.clicks === 0)).toBe(true); expect(f.send.clicks).toBe(0);
    }
  });
});

function observedGeminiCodeBlock(f: ReturnType<typeof fixture>, raw: string) {
  f.answer.text = ""; f.answer.children = [];
  const wrapper = new Element("DIV", { class: "formatted-code-block-internal-container ng-tns-c3545353930-13" });
  const content = new Element("DIV", { class: "animated-opacity ng-tns-c3545353930-13" });
  const header = new Element("DIV", { class: "code-block-decoration header-formatted gds-emphasized-body-m ng-star-inserted" });
  const label = new Element("SPAN", { class: "ng-tns-c3545353930-13" }, "JSON");
  const copy = new Element("BUTTON", { "aria-label": "Copy code" });
  const download = new Element("BUTTON", { "aria-label": "Download code" });
  header.append(label, download, copy);
  const pre = new Element("PRE"), code = new Element("CODE", {}, raw); pre.append(code);
  content.append(header, pre); wrapper.append(content); f.answer.append(wrapper);
  Object.defineProperty(f.answer, "innerText", { get: () => "JSON\n" + raw });
  return { wrapper, content, header, label, copy, download, pre, code };
}

async function acknowledgedDelayedContinuation() {
  const f = fixture(provider, { userPrompt: prompt }), first = await f.run(), firstBody = f.userBody!;
  const continuation = "One exact continuation payload";
  // A real single Send acknowledgment precedes the website's delayed DOM append.
  f.send.onClick = () => { f.composer.replaceChildren(); };
  await f.run("prepare"); await f.run("insert", { prompt: continuation });
  expect(await f.run("sendReady", { prompt: continuation })).toMatchObject({ sendReady: true });
  expect(await f.run("submit", { prompt: continuation })).toEqual({ submitted: true });
  expect(f.send.clicks).toBe(1); expect(f.world.__computaModelLastSubmissionCount).toBe(1);
  return { f, first, firstBody, continuation };
}

describe("embedded Gemini fixed adapter", () => {
  test("a sole fenced envelope preserves literal JSON escapes and code-block controls", async () => {
    for (const envelope of [
      { type: "message", text: 'Literal "quoted" text, C:\\tmp\\file\nnext line\\n stays literal' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "quoted\\n"\npath="C:\\tmp\\file"' } }] },
    ]) {
      const f = fixture(provider, { userPrompt: prompt });
      const raw = "\n" + JSON.stringify(envelope) + "\n";
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, raw);
      pre.append(code, new Element("BUTTON", { "aria-label": "Copy code" }, "Copy code")); f.answer.append(pre);
      // Emulate the exact failure: the site's rendered Markdown loses JSON escapes.
      const rendered = raw.replace(/\\"/g, '"').replace(/\\\\/g, "\\").replace(/\\n/g, "\n");
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.run();
      expect(result.text).toBe(raw);
      expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("Copy code");
      expect(result.completionEvidence.codeStructure).toMatchObject({ preCount: 1, codeCount: 1,
        codeTextLength: raw.length, outsideTextLength: 0, outsideTruncated: false });
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain('quoted');
    }
  });

  test("observed Gemini JSON header preserves its literal sole envelope", async () => {
    for (const envelope of [
      { type: "message", text: 'It\'s "quoted" C:\\tmp\\path\nnext line' },
      { type: "tool_calls", calls: [{ name: "exec_command", arguments: { cmd: 'printf "literal\\n"\nprintf "It\'s quoted"' } }] },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }), raw = "\n" + JSON.stringify(envelope) + "\n";
      observedGeminiCodeBlock(f, raw);
      const result = await f.run();
      expect(result.text).toBe(raw); expect(JSON.parse(result.text)).toEqual(envelope);
      expect(result.text).not.toContain("JSON\n"); expect(result.text).not.toContain("Copy code");
    }
  });

  test("Gemini header admission rejects wrong labels, unscoped controls and author prose", async () => {
    for (const change of [
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.wrapper.values.class = "other-code-wrapper"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.header.values.class = "code-block-decoration header-formatted"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.label.text = "json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.label.text = "Json"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.label.append(new Element("EM", {}, "")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.copy.values["aria-label"] = "Copy"; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.copy.disabled = true; },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.copy.text = "Author text"; },
      (f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.header.children = block.header.children.filter(node => node !== block.copy); f.answer.append(block.copy); },
      (f: ReturnType<typeof fixture>, _block: ReturnType<typeof observedGeminiCodeBlock>) => { f.answer.append(new Element("P", {}, "Author prose")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.header.append(new Element("BUTTON", {}, "Other outside button")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.header.append(new Element("SPAN", {}, "JSON")); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.header.append(new Element("BUTTON", { "aria-label": "Copy code" })); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{}')); block.wrapper.append(extra); },
      (_f: ReturnType<typeof fixture>, block: ReturnType<typeof observedGeminiCodeBlock>) => { block.code.text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }), raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"literal"}}]}';
      const block = observedGeminiCodeBlock(f, raw); change(f, block);
      expect((await f.run()).text).toBe("JSON\n" + raw); expect(f.send.clicks).toBe(0);
    }
  });

  test("outside code-header diagnostics expose only static categories and bounded ancestry", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    f.answer.text = ""; f.answer.children = [];
    const wrapper = new Element("DIV", { class: "provider-code-wrapper", id: "private-account-id" });
    wrapper.append(new Element("SPAN", {}, "\uE056"), new Element("SPAN", {}, "json"));
    const pre = new Element("PRE"), raw = '{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"private command"}}]}';
    pre.append(new Element("CODE", {}, raw)); wrapper.append(pre); f.answer.append(wrapper);
    const result = await f.run();
    // Header acceptance needs actual website evidence; diagnostics cannot grant it.
    expect(result.text).toBe("\uE056json" + raw);
    const diagnostic = result.completionEvidence.codeStructure;
    expect(diagnostic).toMatchObject({ preCount: 1, codeCount: 1, outsideTextLength: 5, outsideTruncated: false });
    expect(diagnostic.outsideNodes.map((node: any) => node.kind)).toEqual(["private_use", "json"]);
    expect(diagnostic.outsideNodes[1].ancestors).toContainEqual({ tag: "div", classes: ["provider-code-wrapper"], preDescendants: 1, copyControls: 0 });
    expect(JSON.stringify(diagnostic)).not.toContain("private command"); expect(JSON.stringify(diagnostic)).not.toContain("private-account-id");
    expect(JSON.stringify(diagnostic)).not.toContain(firstMarker); expect(JSON.stringify(diagnostic).length).toBeLessThanOrEqual(8192);
  });

  test("prose, extra blocks, multiple code bodies and non-envelopes keep rendered extraction", async () => {
    for (const change of [
      (answer: Element, _pre: Element) => { answer.text = "Author prose before the block"; },
      (answer: Element, _pre: Element) => { answer.append(new Element("P", {}, "Author prose after the block")); },
      (answer: Element, _pre: Element) => { const extra = new Element("PRE"); extra.append(new Element("CODE", {}, '{"type":"message","text":"OTHER"}')); answer.append(extra); },
      (_answer: Element, pre: Element) => { pre.append(new Element("CODE", {}, '{"type":"message","text":"OTHER"}')); },
      (_answer: Element, pre: Element) => { pre.text = "Author text outside its code body"; },
      (_answer: Element, pre: Element) => { pre.children[0].text = '{"type":"example","text":"quoted"}'; },
      (_answer: Element, pre: Element) => { pre.children[0].text = '{"type":"message","text":"invalid "quote""}'; },
    ]) {
      const f = fixture(provider, { userPrompt: prompt });
      f.answer.text = ""; f.answer.children = [];
      const pre = new Element("PRE"), code = new Element("CODE", {}, '{"type":"message","text":"quoted\\""}');
      pre.append(code); f.answer.append(pre); change(f.answer, pre);
      const rendered = "Rendered response still requires strict codec validation";
      Object.defineProperty(f.answer, "innerText", { get: () => rendered });
      const result = await f.run();
      expect(result.text).toBe(rendered);
      expect(result.completionEvidence.codeStructure.preCount).toBeGreaterThanOrEqual(1);
      expect(JSON.stringify(result.completionEvidence.codeStructure)).not.toContain('Author prose');
    }
  });

  test("an owned fresh page enables temporary mode once and verifies real UI evidence", async () => {
    const f = fixture(provider, { temporary: false });
    expect(await f.run()).toMatchObject({ temporary: false, userCount: 0, responseCount: 0 });
    expect(await f.run("enableTemporary")).toMatchObject({ enabled: false });
    expect(f.toggle.clicks).toBe(1);
    expect(await f.run()).toMatchObject({ temporary: true });
    expect(await f.run("enableTemporary")).toMatchObject({ enabled: true });
    expect(f.toggle.clicks).toBe(1);
  });

  test("composer readiness cannot authorize a delayed, disabled or vanished mode toggle", async () => {
    const f = fixture(provider, { temporary: false }); f.toggle.connected = false;
    expect(await f.run()).toMatchObject({ composer: true, temporary: false, temporaryActionAvailable: false });
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined(); expect(f.toggle.clicks).toBe(0);
    f.toggle.connected = true; f.toggle.disabled = true;
    expect(await f.run()).toMatchObject({ temporaryActionAvailable: false });
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined();
    f.toggle.disabled = false;
    expect(await f.run()).toMatchObject({ temporary: false, temporaryActionAvailable: true });
    f.toggle.connected = false;
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.world.__computaModelTemporaryRequested).toBeUndefined(); expect(f.toggle.clicks).toBe(0);
    f.toggle.connected = true;
    expect(await f.run("enableTemporary")).toMatchObject({ enabled: false });
    expect(f.toggle.clicks).toBe(1); expect(f.world.__computaModelTemporaryRequested).toBe(true);
    expect(await f.run()).toMatchObject({ temporary: true });
  });

  test("a lost toggle result is never retried or allowed to send in normal mode", async () => {
    const f = fixture(provider, { temporary: false });
    f.toggle.onClick = () => { throw new Error("fixture lost click acknowledgment"); };
    await expect(f.run("enableTemporary")).rejects.toThrow("fixture lost");
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unverified" });
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.toggle.clicks).toBe(1); expect(f.send.clicks).toBe(0);
  });

  test("temporary text inside a model message cannot spoof the mode header", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    f.header.connected = false; f.exit.connected = false;
    const forged = new Element(provider === "claude" ? "DIV" : "SPAN", provider === "claude" ? { class: "animate-incognito-header-in" } : { class: "info-text" });
    if (provider === "claude") forged.append(new Element("SPAN", {}, "Incognito chat")); else forged.text = "Temporary Chat";
    f.answer.append(forged);
    expect(await f.run()).toMatchObject({ error: "temporary_mode_unverified" });
    expect(f.world.__computaModelFirstProof).toBeUndefined();
    expect(f.send.clicks).toBe(0);
  });

  test("hidden evidence and a disabled toggle never authorize temporary mode", async () => {
    const f = fixture(provider, { temporary: false });
    f.badge.connected = true; f.badge.values.visibility = "hidden";
    if (provider === "claude") f.exit.connected = true;
    expect(await f.run()).toMatchObject({ temporary: false });
    f.toggle.disabled = true;
    expect(await f.run("enableTemporary")).toMatchObject({ error: "temporary_mode_unavailable" });
    expect(f.toggle.clicks).toBe(0);
  });

  test("sign-in state is detected without performing any account action", async () => {
    const f = fixture(provider, { temporary: false }); f.composer.connected = false;
    const signIn = new Element("BUTTON", { "aria-label": "Sign in" }); f.body.append(signIn);
    expect(await f.run()).toMatchObject({ signIn: true, composer: false, temporary: false });
    expect(signIn.clicks).toBe(0);
  });

  test("assistant extraction omits headings and admits only its enabled scoped completion control", async () => {
    const f = fixture(provider, { userPrompt: prompt, renderedMarkdown: true });
    const result = await f.run();
    expect(result).toMatchObject({ responseCount: 1, userCount: 1, firstUserVerified: true, firstUserMarkerVerified: true,
      temporary: true, busy: false, answerComplete: true, text: '{"type":"message","text":"OK"}' });
    expect(result.firstUserFingerprint).toMatch(/^[a-f0-9]{64}$/);
    expect(result.text).not.toContain("responded"); expect(result.text).not.toContain("said");
    f.copy.disabled = true;
    expect(await f.run()).toMatchObject({ answerComplete: false });
    f.copy.disabled = false; f.copy.connected = false;
    f.body.append(new Element("BUTTON", { "aria-label": "Copy", "data-testid": "action-bar-copy", "data-test-id": "copy-button" }));
    expect(await f.run()).toMatchObject({ answerComplete: false });
  });

  test("streaming or a visible Stop response prevents premature completion", async () => {
    const f = fixture(provider, { userPrompt: prompt }); f.stop.connected = true;
    expect(await f.run()).toMatchObject({ busy: true, answerComplete: false });
    expect(await f.run("insert", { prompt: "Next turn" })).toMatchObject({ error: "composer_unavailable" });
    expect(f.send.clicks).toBe(0);
    f.stop.connected = false;
    if (provider === "claude") f.response.values["data-is-streaming"] = "true"; else f.response.values["aria-busy"] = "true";
    expect(await f.run()).toMatchObject({ busy: true, answerComplete: false });
  });

  test("literal editor insertion preserves exact text and Submit clicks once", async () => {
    const f = fixture(provider);
    expect(await f.run("prepare")).toMatchObject({ prepared: true, temporary: true });
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ inserted: true });
    expect(f.composer.innerText).toBe(outbound);
    expect(await f.run("sendReady", { prompt: outbound })).toMatchObject({ sendReady: true });
    expect(f.send.clicks).toBe(0);
    expect(await f.run("submit", { prompt: outbound })).toMatchObject({ submitted: true });
    expect(f.send.clicks).toBe(1);
    expect(await f.run()).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true, userCount: 1 });
    expect(await f.run("submit", { prompt: outbound })).toHaveProperty("error");
    expect(f.send.clicks).toBe(1);
  });

  test("the observed Quill composer receives literal paragraphs without smart editing commands", async () => {
    for (const text of [
      'It\'s "quoted" C:\\tmp\\file\n\n  double spaces\nUnicode 💡 and\u00a0NBSP\n',
      'History: It\'s "quoted" \u2019 is already curly\n\n'.repeat(512),
    ]) {
      const f = fixture(provider), exact = text + "\n\n" + markerLine;
      f.document.execCommand = () => { throw new Error("literal Quill path must not invoke smart editing"); };
      expect(await f.run("insert", { prompt: exact })).toMatchObject({ inserted: true });
      expect(f.composer.innerText).toBe(exact);
      expect(f.composer.children.length).toBe(exact.split("\n").length);
      expect(f.composer.children.every(node => node.tagName === "P")).toBe(true);
      expect(f.composer.events.length).toBe(1);
      expect(await f.run("sendReady", { prompt: exact })).toMatchObject({ sendReady: true });
      expect(f.send.clicks).toBe(0);
      expect(await f.run("submit", { prompt: exact })).toMatchObject({ submitted: true });
      expect(f.send.clicks).toBe(1); expect(f.userBody?.innerText).toBe(exact);
    }
    const f = fixture(provider); f.composer.values.class = "ql-editor-candidate";
    f.document.execCommand = () => false;
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ error: "insert_command_rejected" });
    expect(f.composer.innerText).toBe(""); expect(f.send.clicks).toBe(0);
  });

  test("drafts and provider text substitutions fail before send without exposing prompt text", async () => {
    const f = fixture(provider); f.composer.text = "Human draft";
    expect(await f.run("prepare")).toMatchObject({ error: "composer_not_empty" });
    expect(await f.run("insert", { prompt: outbound })).toMatchObject({ error: "composer_not_empty" });
    expect(f.composer.innerText).toBe("Human draft"); f.composer.text = "";
    await f.run("insert", { prompt: outbound });
    f.composer.replaceChildren(); f.composer.text = outbound.replace('"quoted"', '“quoted”');
    const result = await f.run("submit", { prompt: outbound });
    expect(result).toMatchObject({ error: "prompt_not_inserted", detail: "text_difference" });
    expect(JSON.stringify(result)).not.toContain("quoted"); expect(f.send.clicks).toBe(0);
  });

  test("insertion mismatch diagnostics report exact scalar offsets without changing text", async () => {
    const suffix = "\n\n" + markerLine;
    for (const [expectedBody, actualBody, index, actualScalar, expectedScalar] of [
      ['A "private" text', 'A “private” text', 2, 0x201C, 0x22],
      ["A💡private", "A💢private", 1, 0x1F4A2, 0x1F4A1],
      ["A\u00a0B private", "A B private", 1, 0x20, 0xA0],
    ] as const) {
      const f = fixture(provider), expected = expectedBody + suffix;
      await f.run("insert", { prompt: expected });
      f.composer.replaceChildren(); f.composer.text = actualBody + suffix;
      const result = await f.run("sendReady", { prompt: expected });
      expect(result).toMatchObject({ error: "prompt_not_inserted", firstDifference: index, actualScalar, expectedScalar });
      expect(f.composer.innerText).toBe(actualBody + suffix); expect(f.send.clicks).toBe(0);
      expect(JSON.stringify(result)).not.toContain("private"); expect(JSON.stringify(result)).not.toContain(firstMarker);
    }
    const f = fixture(provider), expected = "Private text" + suffix;
    await f.run("insert", { prompt: expected }); f.composer.replaceChildren(); f.composer.text = expected.slice(0, -1);
    expect(await f.run("sendReady", { prompt: expected })).toMatchObject({ error: "prompt_not_inserted",
      firstDifference: expected.length - 1, actualScalar: null, expectedScalar: expected.codePointAt(expected.length - 1) });
    expect(f.send.clicks).toBe(0);
  });

  test("first submission requires its exact inserted prompt and final marker", async () => {
    const missing = fixture(provider);
    expect(await missing.run("insert", { prompt })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(missing.composer.innerText).toBe("");
    const f = fixture(provider); await f.run("insert", { prompt: outbound });
    f.composer.replaceChildren(); f.composer.text = "Replaced prompt\n\n" + markerLine;
    expect(await f.run("submit", { prompt: f.composer.innerText })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(f.send.clicks).toBe(0);
  });

  test("a lost Send acknowledgment cannot replay the original click", async () => {
    const f = fixture(provider); await f.run("insert", { prompt: outbound });
    f.send.onClick = () => { throw new Error("fixture lost send acknowledgment"); };
    await expect(f.run("submit", { prompt: outbound })).rejects.toThrow("fixture lost");
    expect(await f.run("submit", { prompt: outbound })).toHaveProperty("error");
    expect(f.send.clicks).toBe(1);
  });

  test("rendered Markdown binds once, and same-count replacement cannot authorize cleanup", async () => {
    const f = fixture(provider, { userPrompt: prompt, renderedMarkdown: true });
    expect(f.userBody!.innerText).not.toBe(outbound);
    const result = await f.run("inspect", {}, false);
    expect(result).toMatchObject({ firstUserVerified: true });
    expect(await f.run()).toMatchObject({ firstUserFingerprint: result.firstUserFingerprint });
    const previous = f.userRoot!, replacement = previous.cloneNode(true);
    replacement.querySelector('span.user-query-bubble-with-background')!.children[0].text = f.userBody!.innerText.replace("C++", "Changed schema");
    const wrapper = previous.parentElement!;
    wrapper.children[wrapper.children.indexOf(previous)] = replacement; replacement.parentElement = wrapper; previous.connected = false;
    expect(await f.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(f.send.clicks).toBe(0);
  });

  test("an unchanged rendered first bubble may be recreated between inspections", async () => {
    const f = fixture(provider, { userPrompt: prompt, renderedMarkdown: true });
    const before = await f.run();
    const previous = f.userRoot!, replacement = previous.cloneNode(true);
    const wrapper = previous.parentElement!;
    wrapper.children[wrapper.children.indexOf(previous)] = replacement; replacement.parentElement = wrapper; previous.connected = false;
    expect(await f.run()).toMatchObject({ firstUserVerified: true, firstUserFingerprint: before.firstUserFingerprint });
  });

  test("the observed payload span stays immutable when sibling provider controls change", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    const firstBody = f.userBody!, first = await f.run();
    expect(JSON.parse(first.debugStructure)).toMatchObject({ body: { tag: "span", classes: ["ng-star-inserted"] },
      controlDescendants: 0, markerFinalLine: true, markerOccurrences: 1 });
    const controls = firstBody.parentElement!.children[1];
    controls.append(new Element("BUTTON", { "aria-label": "Expand message" }, "Expand"));
    controls.children[0].text = "Copy message";
    f.composer.onFocus = () => {
      f.document.activeElement = f.composer;
      controls.children[1].text = "Collapse message";
    };
    expect(await f.run("prepare")).toMatchObject({ prepared: true, firstUserFingerprint: first.firstUserFingerprint });
    const nextPrompt = "A second exact tool result";
    expect(await f.run("insert", { prompt: nextPrompt })).toMatchObject({ inserted: true });
    expect(await f.run("sendReady", { prompt: nextPrompt })).toMatchObject({ sendReady: true });
    expect(await f.run("submit", { prompt: nextPrompt })).toEqual({ submitted: true });
    expect(await f.run("inspect", { expectedUserCounts: [2] })).toMatchObject({ firstUserVerified: true,
      firstUserFingerprint: first.firstUserFingerprint, userCount: 2 });
    expect(f.send.clicks).toBe(1);
    firstBody.text = firstBody.text.replace("C++", "Changed schema");
    const changed = await f.run("inspect", { expectedUserCounts: [2] });
    expect(changed).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(JSON.parse(changed.debugStructure).reason).toBe("pinned_fingerprint");
  });

  test("an acknowledged continuation appended during a read digest discards only that observation", async () => {
    const { f, first, continuation } = await acknowledgedDelayedContinuation();
    f.onDigest(() => { f.appendUser(continuation); });
    const discarded = await f.run("inspect", { expectedUserCounts: [1, 2] });
    expect(discarded).toEqual({ error: "submission_observation_pending" });
    expect(f.world.__computaModelFirstProof.fingerprint).toBe(first.firstUserFingerprint);
    expect(f.send.clicks).toBe(1);
    const fresh = await f.run("inspect", { expectedUserCounts: [1, 2] });
    expect(fresh).toMatchObject({ firstUserVerified: true, firstUserFingerprint: first.firstUserFingerprint, userCount: 2 });
    expect(await f.run("stop", { expectedUserCounts: [2] })).toMatchObject({ firstUserVerified: true,
      firstUserFingerprint: first.firstUserFingerprint, temporary: true, userCount: 2 });
    expect(f.send.clicks).toBe(1);
  });

  test("a delayed append with changed body, route, owner, mode or unexpected count remains an ownership failure", async () => {
    for (const mutate of [
      ({ firstBody }: Awaited<ReturnType<typeof acknowledgedDelayedContinuation>>) => { firstBody.text = firstBody.text.replace("C++", "Changed schema"); },
      ({ f }: Awaited<ReturnType<typeof acknowledgedDelayedContinuation>>) => { f.document.URL += "?changed=1"; },
      ({ f }: Awaited<ReturnType<typeof acknowledgedDelayedContinuation>>) => { f.world.__computaModelOwner = "foreign"; },
      ({ f }: Awaited<ReturnType<typeof acknowledgedDelayedContinuation>>) => { f.header.connected = false; f.exit.connected = false; },
      ({ f }: Awaited<ReturnType<typeof acknowledgedDelayedContinuation>>) => { f.appendUser("Unexpected extra user"); },
      ({ firstBody }: Awaited<ReturnType<typeof acknowledgedDelayedContinuation>>) => { firstBody.connected = false; },
    ]) {
      const state = await acknowledgedDelayedContinuation();
      state.f.onDigest(() => { state.f.appendUser(state.continuation); mutate(state); });
      const rejected = await state.f.run("inspect", { expectedUserCounts: [1, 2] });
      expect(rejected).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
      expect(state.f.send.clicks).toBe(1);
    }
  });

  test("the pending read signal requires exact expected counts and both original pins plus an owned click claim", async () => {
    for (const scenario of [
      { counts: [1, 2, 3] }, { counts: [2, 1] },
      { counts: [1, 2], native: "0".repeat(64) },
      { counts: [1, 2], removeClaim: true },
      { counts: [1, 2], privateMismatch: true },
      { counts: [1, 2], allowBinding: true },
    ]) {
      const { f, continuation } = await acknowledgedDelayedContinuation();
      if (scenario.removeClaim) delete f.world.__computaModelLastSubmissionCount;
      if (scenario.privateMismatch) f.world.__computaModelFirstProof.fingerprint = "0".repeat(64);
      f.onDigest(() => { f.appendUser(continuation); });
      const overrides: Record<string, unknown> = { expectedUserCounts: scenario.counts };
      if (scenario.native) overrides.expectedFirstUserFingerprint = scenario.native;
      if (scenario.allowBinding) overrides.allowFirstUserBinding = true;
      expect(await f.run("inspect", overrides)).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
      expect(f.send.clicks).toBe(1);
    }
    const unsolicited = fixture(provider, { userPrompt: prompt }); await unsolicited.run();
    unsolicited.onDigest(() => { unsolicited.appendUser("Foreign user"); });
    expect(await unsolicited.run("inspect", { expectedUserCounts: [1, 2] })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(unsolicited.send.clicks).toBe(0);
  });

  test("continuation count changes never authorize replay or relaxation of a mutation action", async () => {
    for (const action of ["prepare", "insert", "sendReady", "submit", "stop"]) {
      const { f, continuation } = await acknowledgedDelayedContinuation();
      f.onDigest(() => { f.appendUser(continuation); });
      expect(await f.run(action, { expectedUserCounts: [1, 2], prompt: continuation })).toMatchObject({
        error: "conversation_changed", detail: "first_user_message" });
      expect(f.send.clicks).toBe(1);
    }
  });

  test("missing, duplicate, foreign, editable and controlled Gemini payloads cannot bind or pass cleanup inspection", async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.userRoot!.querySelector("div.query-content")!.values.class = "other-content"; },
      (f: ReturnType<typeof fixture>) => { f.userRoot!.append(new Element("DIV", { class: "query-content" })); },
      (f: ReturnType<typeof fixture>) => { f.userRoot!.querySelector("div.query-bubble-with-status")!.values.class = "other-status"; },
      (f: ReturnType<typeof fixture>) => { f.userBody!.parentElement!.values.class = "other-bubble"; },
      (f: ReturnType<typeof fixture>) => { f.userBody!.values.class = "other-body"; },
      (f: ReturnType<typeof fixture>) => { f.userBody!.parentElement!.append(f.userBody!.cloneNode(true)); },
      (f: ReturnType<typeof fixture>) => { f.userBody!.values.contenteditable = "true"; },
      (f: ReturnType<typeof fixture>) => { f.userBody!.append(new Element("DIV", { role: "textbox" })); },
      (f: ReturnType<typeof fixture>) => { f.userBody!.append(new Element("BUTTON")); },
      (f: ReturnType<typeof fixture>) => { f.userBody!.append(new Element("SPAN", { role: "button" })); },
      (f: ReturnType<typeof fixture>) => { f.userBody!.values.hidden = ""; },
      (f: ReturnType<typeof fixture>) => { const content = f.userRoot!.querySelector("div.query-content")!;
        content.parentElement!.children = content.parentElement!.children.filter(node => node !== content);
        const foreign = new Element("USER-QUERY"); foreign.append(content); f.userRoot!.append(foreign); },
    ]) {
      const unbound = fixture(provider, { userPrompt: prompt }); mutate(unbound);
      expect(await unbound.run("inspect", { expectedUserCounts: [1, 2] })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
      expect(unbound.world.__computaModelFirstProof).toBeUndefined();
      const bound = fixture(provider, { userPrompt: prompt }); await bound.run(); mutate(bound);
      expect(await bound.run("inspect", { expectedUserCounts: [1, 2] })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
      for (const f of [unbound, bound]) expect(f.send.clicks).toBe(0);
    }
  });

  test("a same-document reset is rejected even when native counts are accidentally empty", async () => {
    const f = fixture(provider, { userPrompt: prompt }); await f.run();
    f.userRoot!.parentElement!.connected = false;
    // Remove from query inventory as a real reset would, not only hide it.
    f.messages.children = f.messages.children.filter(node => !node.contains(f.userRoot!));
    expect(await f.run()).toMatchObject({ error: "conversation_changed", detail: "user_count" });
    expect(await f.run("inspect", { expectedUserCounts: [0] })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
  });

  test("markers cannot bind before Submit, without pending native binding, or as a marker-only body", async () => {
    const unsubmitted = fixture(provider, { userPrompt: prompt }); unsubmitted.world.__computaModelFirstSubmitted = false;
    expect(await unsubmitted.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const notPending = fixture(provider, { userPrompt: prompt });
    expect(await notPending.run("inspect", { allowFirstUserBinding: false })).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const onlyMarker = fixture(provider, { userPrompt: "" });
    expect(await onlyMarker.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const wrongPlacement = fixture(provider, { userPrompt: prompt }); wrongPlacement.userBody!.text += "\nForeign suffix";
    expect(await wrongPlacement.run()).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    for (const f of [unsubmitted, notPending, onlyMarker, wrongPlacement]) expect(f.world.__computaModelFirstProof).toBeUndefined();
  });

  test("digest yields recheck the exact body, owner, route, mode and physical user count", async () => {
    for (const mutate of [
      (f: ReturnType<typeof fixture>) => { f.userBody!.text += " changed"; },
      (f: ReturnType<typeof fixture>) => { f.world.__computaModelOwner = "foreign"; },
      (f: ReturnType<typeof fixture>) => { f.document.URL += "&other=1"; },
      (f: ReturnType<typeof fixture>) => { f.header.connected = false; f.exit.connected = false; },
      (f: ReturnType<typeof fixture>) => { f.appendUser("Foreign user"); },
    ]) {
      const f = fixture(provider, { userPrompt: prompt }); f.onDigest(() => mutate(f));
      const result = await f.run(); expect(["conversation_changed", "temporary_mode_unverified"]).toContain(result.error);
      expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(f.send.clicks).toBe(0);
    }
  });

  test("provider, top-frame, exact URL, owner and pinned route checks precede mutations", async () => {
    for (const overrides of [
      { provider: "chatgpt" }, { expectedURL: "https://example.test/" }, { ownerToken: "foreign" },
      { expectedConversation: fixture(provider).origin + "/foreign" },
    ]) {
      const f = fixture(provider);
      const result = await f.run("enableTemporary", overrides);
      expect(["document_changed", "conversation_changed"]).toContain(result.error);
      expect(f.toggle.clicks).toBe(0); expect(f.send.clicks).toBe(0);
    }
    const frame = fixture(provider); frame.window.top = {};
    expect(await frame.run()).toMatchObject({ error: "document_changed" });
    const foreign = fixture(provider); foreign.location.origin = "https://example.test";
    expect(await foreign.run()).toMatchObject({ error: "document_changed" });
  });

  test("mutation notifications deliver without page timers and carry only ownership and kind", async () => {
    const f = fixture(provider); await f.run(); await f.run();
    expect(f.observers).toHaveLength(1); expect(f.delays).toEqual([]); expect(f.posted).toEqual([]);
    // Leave the fixture's timer queue undrained: a parked background timer
    // must not prevent either actual DOM change reaching the native receiver.
    f.observers[0].callback([{ type: "childList" }]); f.observers[0].callback([{ type: "attributes" }]);
    expect(f.delays).toEqual([]);
    expect(f.posted).toEqual(Array(2).fill({ ownerToken: "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30", kind: "dom_changed" }));
    f.world.__computaModelOwner = "foreign";
    f.observers[0].callback([{ type: "characterData" }]);
    expect(f.posted).toHaveLength(2);
    f.world.__computaModelOwner = "f33c8869-a5d3-4b9d-b29e-7b6f591a8e30";
    f.location.origin = "https://example.test";
    f.observers[0].callback([{ type: "characterData" }]);
    expect(f.posted).toHaveLength(2);
  });

  test("initial temporary mode requires the observed title-link-notice hierarchy", async () => {
    const positive = fixture(provider);
    expect(positive.badge.textContent).not.toBe('Just stopping by?');
    expect(await positive.run()).toMatchObject({ temporary: true });
    for (const change of [
      (f: ReturnType<typeof fixture>) => { f.badge.querySelector('a')!.values.href = 'https://example.test/gemini/answer/13275745?p=temp_chats'; },
      (f: ReturnType<typeof fixture>) => { f.badge.querySelector('a')!.values.href = 'https://support.google.com/gemini/answer/13275745?p=other'; },
      (f: ReturnType<typeof fixture>) => { f.badge.querySelector('a')!.connected = false; },
      (f: ReturnType<typeof fixture>) => { f.badge.children[1].children[1].text = 'Different description'; },
      (f: ReturnType<typeof fixture>) => { f.badge.children[0].values.visibility = 'hidden'; },
      (f: ReturnType<typeof fixture>) => { f.header.children = []; f.answer.append(f.badge); f.messages.append(f.article); },
    ]) {
      const f = fixture(provider); change(f);
      expect(await f.run()).toMatchObject({ temporary: false });
      expect(await f.run('prepare')).toMatchObject({ error: 'temporary_mode_unverified' });
      expect(f.send.clicks).toBe(0);
    }
    const direct = fixture(provider);
    direct.badge.children.shift(); direct.badge.text = 'Just stopping by?';
    expect(await direct.run()).toMatchObject({ temporary: true });
    const titleOnly = fixture(provider); titleOnly.badge.text = 'Just stopping by?'; titleOnly.badge.children = [];
    expect(await titleOnly.run()).toMatchObject({ temporary: false });
  });

  test("readiness diagnostics reveal nested mode evidence without granting mode or exposing text", async () => {
    const f = fixture(provider, { temporary: false });
    f.badge.connected = true; f.badge.text = ''; f.badge.children = [];
    f.badge.append(new Element('SPAN', {}, 'Just stopping by?'), new Element('P', {}, 'Private account sentinel that must never be logged'));
    const result = await f.run();
    expect(result.temporary).toBe(false);
    const diagnostics = JSON.parse(result.debugStructure);
    expect(diagnostics).toMatchObject({ kind: 'provider_readiness', provider: 'gemini', composer: { visible: 1, enabled: 1 } });
    expect(diagnostics.nodes[0]).toMatchObject({ initialExact: false, initialContained: true,
      exactDescendants: [{ tag: 'span', initialExact: true }] });
    expect(result.debugStructure).not.toContain('Private account');
    expect(result.debugStructure).not.toContain(firstMarker);
    expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
    f.composer.connected = false; f.temporary(true);
    f.exit.connected = true;
    expect(await f.run('prepare')).toMatchObject({ error: 'composer_unavailable', detail: 'missing_composer' });
  });

  test("first-user diagnostics report bounded layout and marker facts without content", async () => {
    const secret = "Private account prompt never logged";
    const f = fixture(provider, { userPrompt: secret });
    const first = f.userRoot!;
    first.append(new Element("BUTTON", {}, "Copy private message"));
    f.userBody!.text += "\nForeign suffix";
    const result = await f.run();
    expect(result).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    const metadata = JSON.parse(result.debugStructure);
    expect(metadata).toMatchObject({ kind: "first_user_structure", provider: "gemini", userCount: 1,
      reason: "marker_not_final",
      root: { tag: "user-query" }, body: { tag: "span" }, markerFinalLine: false,
      markerOccurrences: 1, controlDescendants: 0, submitted: true, markerMatches: true });
    expect(metadata.textLength).toBeGreaterThan(0); expect(metadata.lineCount).toBeGreaterThan(1);
    expect(result.debugStructure).not.toContain(secret); expect(result.debugStructure).not.toContain(firstMarker);
    expect(result.debugStructure).not.toContain("Copy private"); expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
    expect(f.send.clicks).toBe(0);
  });

  test("the first successful binding publishes its sanitized structure exactly once", async () => {
    const secret = "Private account prompt never logged";
    const f = fixture(provider, { userPrompt: secret });
    const child = new Element("DIV", { class: "query-extra ng-star-inserted private-class", id: "private-id" });
    f.userRoot!.append(child);
    const first = await f.run();
    expect(first).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true, temporary: true });
    expect(JSON.parse(first.debugStructure)).toMatchObject({ kind: "first_user_structure", provider: "gemini",
      reason: "first_bound", userCount: 1, pinnedFingerprintMatch: true, markerFinalLine: true,
      markerOccurrences: 1, submitted: true, markerMatches: true,
      snapshot: { rootSame: true, bodySame: true, bodyConnected: true, textSame: true,
        countSame: true, urlSame: true, originSame: true, ownerSame: true } });
    expect(JSON.parse(first.debugStructure).descendants).toContainEqual(expect.objectContaining({
      tag: "div", path: [1], classes: ["query-extra", "ng-star-inserted"] }));
    for (const privateValue of [secret, firstMarker, first.firstUserFingerprint, "private-id", "private-class"])
      expect(first.debugStructure).not.toContain(privateValue);
    expect(first.debugStructure.length).toBeLessThanOrEqual(8192);
    const second = await f.run();
    expect(second).toMatchObject({ firstUserVerified: true, firstUserFingerprint: first.firstUserFingerprint });
    expect(JSON.parse(second.debugStructure).kind).toBe("provider_readiness");
    expect(f.send.clicks).toBe(0);
    const invalid = fixture(provider, { userPrompt: secret });
    invalid.world.__computaModelFirstSubmitted = false;
    const rejected = await invalid.run();
    expect(rejected.error).toBe("conversation_changed");
    expect(JSON.parse(rejected.debugStructure).reason).toBe("submission_unclaimed");
    expect(invalid.world.__computaModelFirstProof).toBeUndefined();
  });

  test("first-user diagnostics distinguish rendered digest drift from a native pin mismatch", async () => {
    const changed = fixture(provider, { userPrompt: prompt });
    await changed.run();
    changed.userBody!.text = changed.userBody!.text.replace("C++", "Changed schema");
    const drift = await changed.run("prepare");
    expect(drift).toMatchObject({ error: "conversation_changed", detail: "first_user_message" });
    expect(JSON.parse(drift.debugStructure)).toMatchObject({ reason: "pinned_fingerprint",
      pinnedFingerprintMatch: false, nativeFingerprintMatch: false, markerFinalLine: true,
      snapshot: { rootSame: true, bodySame: true, bodyConnected: true, textSame: true,
        countSame: true, urlSame: true, originSame: true, ownerSame: true } });
    const original = fixture(provider, { userPrompt: prompt }); await original.run();
    const mismatch = await original.run("prepare", { expectedFirstUserFingerprint: "0".repeat(64) });
    expect(JSON.parse(mismatch.debugStructure)).toMatchObject({ reason: "native_fingerprint",
      pinnedFingerprintMatch: true, nativeFingerprintMatch: false, markerFinalLine: true });
    for (const f of [changed, original]) expect(f.send.clicks).toBe(0);
    expect(drift.debugStructure).not.toContain(firstMarker);
    expect(drift.debugStructure).not.toContain("Changed schema");
  });

  test("first-user diagnostics identify digest-yield and action-time snapshot changes", async () => {
    const yielding = fixture(provider, { userPrompt: prompt });
    yielding.onDigest(() => { yielding.userBody!.text = yielding.userBody!.text.replace("C++", "Changed schema"); });
    const before = await yielding.run();
    expect(JSON.parse(before.debugStructure)).toMatchObject({ reason: "snapshot_before_action",
      snapshot: { rootSame: true, bodySame: true, bodyConnected: true, textSame: false,
        countSame: true, urlSame: true, originSame: true, ownerSame: true } });
    expect(JSON.parse(before.debugStructure)).not.toHaveProperty("pinnedFingerprintMatch");
    const focusing = fixture(provider, { userPrompt: prompt }); await focusing.run();
    focusing.composer.onFocus = () => {
      focusing.document.activeElement = focusing.composer;
      focusing.userBody!.text = focusing.userBody!.text.replace("C++", "Changed schema");
    };
    const after = await focusing.run("prepare");
    expect(JSON.parse(after.debugStructure)).toMatchObject({ reason: "snapshot_after_action",
      pinnedFingerprintMatch: true, nativeFingerprintMatch: true,
      snapshot: { rootSame: true, bodySame: true, bodyConnected: true, textSame: false,
        countSame: true, urlSame: true, originSame: true, ownerSame: true } });
    for (const f of [yielding, focusing]) expect(f.send.clicks).toBe(0);
  });

  test("first-user descendant diagnostics reveal only bounded site structure and finite facts", async () => {
    const secret = "Private account query-secret should never enter diagnostics";
    const f = fixture(provider, { userPrompt: secret }); await f.run();
    for (let index = 0; index < 24; index++) {
      const child = new Element("DIV", { class: "query-extra user-query-text gds-body mat-control cdk-content ng-star-inserted flex unknown-private query-secret", id: "Private-node-id", "data-secret": secret });
      if (index === 0) child.append(new Element("BUTTON", { class: "mat-button", "aria-label": secret }));
      f.userRoot!.append(child);
    }
    const result = await f.run("prepare", { expectedFirstUserFingerprint: "0".repeat(64) });
    const metadata = JSON.parse(result.debugStructure);
    expect(metadata.reason).toBe("native_fingerprint");
    expect(metadata.descendants).toHaveLength(16);
    expect(metadata.descendants[1]).toMatchObject({ path: [1], tag: "div",
      classes: ["query-extra", "user-query-text", "gds-body", "mat-control", "cdk-content", "ng-star-inserted"],
      childElements: 1, controls: 1, textLength: 0, markerExact: false, markerContained: false,
      visible: true, editable: false });
    for (const child of metadata.descendants) {
      expect(child.path.length).toBeLessThanOrEqual(16);
      expect(child.classes.length).toBeLessThanOrEqual(6);
      expect(child.path.every((index: number) => Number.isInteger(index) && index >= 0 && index <= 1000)).toBe(true);
    }
    for (const privateValue of [secret, firstMarker, "Private-node-id", "data-secret", "unknown-private", "query-secret"])
      expect(result.debugStructure).not.toContain(privateValue);
    expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
    expect(f.send.clicks).toBe(0);
  });

  test("account-prefixed routes stay exact and cannot escape a pinned conversation", async () => {
    const f = fixture(provider);
    f.location.pathname = "/u/2/app"; f.document.URL = f.origin + f.location.pathname;
    expect(await f.run()).toMatchObject({ temporary: true, composer: true });
    const conversation = fixture(provider, { userPrompt: prompt });
    conversation.location.pathname = "/u/2/app/owned_1"; conversation.document.URL = conversation.origin + conversation.location.pathname;
    const expectedConversation = conversation.document.URL;
    expect(await conversation.run("inspect", { expectedConversation })).toMatchObject({ firstUserVerified: true });
    conversation.location.pathname = "/u/3/app/owned_1"; conversation.document.URL = conversation.origin + conversation.location.pathname;
    expect(await conversation.run("inspect", { expectedConversation })).toMatchObject({ error: "conversation_changed", detail: "conversation_route" });
    for (const pathname of ["/u/-1/app", "/u/1234/app", "/u/foreign/app", "/u/2/not-app", "/app/owned/foreign", "/app/encoded%2Fforeign"]) {
      const invalid = fixture(provider); invalid.location.pathname = pathname; invalid.document.URL = invalid.origin + pathname;
      expect(await invalid.run()).toMatchObject({ error: "document_changed", detail: "document_url" });
    }
  });

  test("the post-send Temporary Chat badge is accepted only outside conversation content", async () => {
    const f = fixture(provider, { userPrompt: prompt }); f.header.connected = false;
    const badge = new Element('SPAN', { class: 'info-text' }, 'Temporary Chat'); f.body.append(badge);
    expect(await f.run()).toMatchObject({ temporary: true, firstUserVerified: true });
    f.body.children = f.body.children.filter(node => node !== badge); f.answer.append(badge);
    expect(await f.run()).toMatchObject({ error: 'temporary_mode_unverified' });
  });
  test("nested Markdown markers count one answer and a toolbar shared across two answers supplies no proof", async () => {
    const f = fixture(provider, { userPrompt: prompt });
    f.answer.text = ''; f.answer.append(new Element('DIV', { class: 'markdown' }, '{"type":"message","text":"OK"}'));
    expect(await f.run()).toMatchObject({ responseCount: 1, answerComplete: true });
    f.response.append(new Element('DIV', { class: 'model-response-text' }, 'Second physical answer'));
    expect(await f.run()).toMatchObject({ responseCount: 2, answerComplete: false });
  });

});
