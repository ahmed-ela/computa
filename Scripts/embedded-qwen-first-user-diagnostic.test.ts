import { describe, expect, test } from 'bun:test';
import { fixture, choice, prompt, fingerprint, raw, conversationID, userID } from './embedded-qwen-adapter-fixture';

const reasons = ['root_hidden', 'message_id_invalid', 'chat_id_mismatch', 'turn_class_missing', 'outer_class_missing'];
const keys = ['version', 'reason', 'rootVisible', 'messageIDValid', 'chatIDMatches', 'turnClassMatches',
  'outerClassMatches', 'messageIDPresent', 'messageIDEmpty', 'chatIDPresent', 'chatIDEmpty'].sort();
async function sent() {
  const f = fixture();
  for (let i = 0; i < 8; i++) { const r = await f.run('selectModel', { modelChoice: choice() }); expect(r.error).toBeUndefined(); if (r.selected) break; }
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert', { prompt })).inserted).toBe(true);
  expect((await f.run('sendReady', { prompt })).sendReady).toBe(true);
  expect((await f.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) })).submitted).toBe(true);
  return f;
}
function mutate(f: ReturnType<typeof fixture>, reason: string) {
  if (reason === 'root_hidden') f.root.setAttribute('visibility', 'hidden');
  if (reason === 'message_id_invalid') f.userContainer.setAttribute('data-msg-id', 'PRIVATE_MESSAGE_ID');
  if (reason === 'chat_id_mismatch') f.userContainer.setAttribute('data-chat-id', 'PRIVATE_CHAT_ID');
  if (reason === 'turn_class_missing') f.root.parentElement!.setAttribute('class', 'PRIVATE_TURN_CLASS');
  if (reason === 'outer_class_missing') f.turn.setAttribute('class', 'PRIVATE_OUTER_CLASS');
}

describe('Qwen finite first-user ownership rejection diagnostic', () => {
  test('all five original predicates still reject without binding, actions or raw page values', async () => {
    for (const reason of reasons) {
      const f = await sent(); mutate(f, reason); const before = f.mutations(); const r = await f.run('inspect');
      expect(r.error).toBe('conversation_changed'); expect(r.detail).toBe('first_user_message');
      const d = r.qwenFirstUserDiagnostic; expect(Object.keys(d).sort()).toEqual(keys); expect(d.version).toBe(1); expect(d.reason).toBe(reason);
      expect(Object.keys(d).filter(k => !['version', 'reason'].includes(k)).every(k => typeof d[k] === 'boolean')).toBe(true);
      expect(JSON.stringify(d)).not.toContain('PRIVATE'); expect(JSON.stringify(d)).not.toContain(conversationID); expect(JSON.stringify(d)).not.toContain(userID);
      expect(JSON.stringify(d).length).toBeLessThan(512);
      for (const key of ['text', 'modelEvidence', 'firstUserFingerprint', 'firstUserVerified', 'answerComplete']) expect(r[key]).toBeUndefined();
      expect(f.world.__computaQwenSavedSessionV1.first).toBeNull(); expect(f.world.__computaQwenSavedSessionV1.terminal).toBe(true);
      expect(f.mutations()).toBe(before); expect(f.send.clicks).toBe(1);
      expect((await f.run('inspect')).detail).toBe('terminal_operation'); expect(f.send.clicks).toBe(1);
    }
  });
  test('missing, empty and malformed IDs are distinguished only by booleans and remain failures', async () => {
    for (const name of ['data-msg-id', 'data-chat-id']) for (const value of [null, '', 'PRIVATE_VALUE']) {
      const f = await sent(); if (value === null) f.userContainer.removeAttribute(name); else f.userContainer.setAttribute(name, value);
      const r = await f.run('inspect'), d = r.qwenFirstUserDiagnostic;
      expect(r.error).toBe('conversation_changed'); expect(r.detail).toBe('first_user_message');
      expect(d.reason).toBe(name === 'data-msg-id' ? 'message_id_invalid' : 'chat_id_mismatch');
      const prefix = name === 'data-msg-id' ? 'messageID' : 'chatID'; expect(d[prefix + 'Present']).toBe(value !== null); expect(d[prefix + 'Empty']).toBe(value === '');
      expect(JSON.stringify(d)).not.toContain('PRIVATE'); expect(f.send.clicks).toBe(1);
    }
  });
  test('first failing predicate priority remains the original compound-guard order', async () => {
    for (let index = 0; index < reasons.length; index++) {
      const f = await sent(); for (const reason of reasons.slice(index)) mutate(f, reason);
      expect((await f.run('inspect')).qwenFirstUserDiagnostic.reason).toBe(reasons[index]);
    }
  });
  test('diagnostic read failures cannot replace the original error or cause a replay', async () => {
    const f = await sent(); let reads = 0;
    f.root.getClientRects = () => { if (++reads === 1) return []; throw new Error('PRIVATE_DIAGNOSTIC_FAILURE'); };
    const r = await f.run('inspect'); expect(r).toEqual({ error: 'conversation_changed', detail: 'first_user_message' });
    expect(f.send.clicks).toBe(1); expect(f.world.__computaQwenSavedSessionV1.terminal).toBe(true);
  });
  test('a separate leaf-shape failure does not invent a compound-guard diagnostic', async () => {
    const f = await sent(); f.userBody.append(new f.Node('SPAN', {}, 'PRIVATE_BODY'));
    const r = await f.run('inspect'); expect(r.error).toBe('document_changed'); expect(r.detail).toBe('first_user_message'); expect(r.qwenFirstUserDiagnostic).toBeUndefined();
  });
  test('valid exact-model response retains full verification and emits no rejected diagnostic', async () => {
    const f = await sent(), r = await f.run('inspect'); expect(r.error).toBeUndefined(); expect(r.text).toBe(raw);
    expect(r.firstUserVerified).toBe(true); expect(r.firstUserFingerprint).toBe(await fingerprint(prompt)); expect(r.modelEvidence.selected).toEqual(choice());
    expect(r.answerComplete).toBe(true); expect(r.qwenFirstUserDiagnostic).toBeUndefined(); expect(f.send.clicks).toBe(1);
  });
});
