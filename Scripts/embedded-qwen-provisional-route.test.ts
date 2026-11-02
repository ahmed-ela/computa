import { describe, expect, test } from 'bun:test';
import { fixture, choice, prompt, marker, generation, ownerToken, fingerprint, conversationID, raw } from './embedded-qwen-adapter-fixture';
const canonical = 'https://chat.qwen.ai/c/' + conversationID;
const provisional = 'https://chat.qwen.ai/c/new-chat';
async function sent() {
  const f = fixture();
  for (let i = 0; i < 8; i++) {
    const result = await f.run('selectModel', { modelChoice: choice() });
    expect(result.error).toBeUndefined();
    if (result.selected) break;
  }
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert', { prompt })).inserted).toBe(true);
  expect((await f.run('sendReady', { prompt })).sendReady).toBe(true);
  const hash = await fingerprint(prompt), original = f.send.onClick;
  f.send.onClick = () => { original?.(); f.document.URL = provisional; };
  const ack = await f.run('submit', { prompt, savedSubmissionFingerprint: hash });
  expect(ack.submissionAcknowledgement).toEqual({ ownerToken, documentGeneration: generation, sequence: 1, outboundFingerprint: hash });
  expect(ack.url).toBe('https://chat.qwen.ai/'); expect(ack.userCount).toBe(0); expect(f.send.clicks).toBe(1);
  const grant = { allowQwenProvisionalRoute: true, expectedModelChoice: choice(), savedSubmissionFingerprint: hash };
  return { f, hash, grant };
}
const emptyPending = { qwenProvisionalRoutePending: true, url: provisional, sessionLifecycle: 'saved_conversation_delete', temporary: false };

describe('Qwen exact first-Send provisional route', () => {
  test('placeholder returns only a negative receipt, then canonical full-body proof restores response', async () => {
    const { f, hash, grant } = await sent();
    expect(await f.run('inspect', grant)).toEqual(emptyPending);
    expect(await f.run('inspect', grant)).toEqual(emptyPending);
    expect(f.send.clicks).toBe(1); expect(f.editor.events).toHaveLength(1);
    f.document.URL = canonical;
    const response = await f.run('inspect', grant);
    expect(response.firstUserFingerprint).toBe(hash); expect(response.firstUserVerified).toBe(true);
    expect(response.modelEvidence.selected).toEqual(choice()); expect(response.conversationIdentity).toBe(canonical);
    expect(response.answerComplete).toBe(true); expect(response.text).toBe(raw);
  });
  test('provisional read does not depend on canonical message IDs or publish their available text', async () => {
    const { f, grant } = await sent();
    // These already-rendered synthetic nodes have no authority on /c/new-chat.
    // Canonical-only transcript parsing would reject the wrong data-chat-id.
    f.userBody.text = 'untrusted provisional body';
    f.root.setAttribute('data-chat-id', 'new-chat');
    expect(await f.run('inspect', grant)).toEqual(emptyPending);
    f.document.URL = canonical;
    expect((await f.run('inspect', grant)).error).toBeDefined(); expect(f.send.clicks).toBe(1);
  });
  test('strict permission, first-message marker, submitted digest and chosen model remain mandatory', async () => {
    for (const override of [
      { allowQwenProvisionalRoute: false }, { savedSubmissionFingerprint: '0'.repeat(64) },
      { savedSubmissionFingerprint: undefined }, { expectedModelChoice: choice('Qwen3.8-Max') },
      { expectedFirstUserMarker: generation }, { expectedFirstUserFingerprint: 'a'.repeat(64) },
      { allowFirstUserBinding: false }, { savedCleanupInspection: true },
      { ownerToken: generation }, { documentGeneration: ownerToken }
    ]) {
      const { f, grant } = await sent();
      const response = await f.run('inspect', { ...grant, ...override });
      expect(response.error).toBeDefined(); expect(response.qwenProvisionalRoutePending).toBeUndefined();
      expect(response.text).toBeUndefined(); expect(f.send.clicks).toBe(1);
    }
  });
  test('new-chat is not a fresh session and cannot create a submission claim', async () => {
    const f = fixture(); f.document.URL = provisional;
    expect((await f.run('inspect', { allowQwenProvisionalRoute: true, savedSubmissionFingerprint: await fingerprint(prompt), expectedModelChoice: choice() })).error).toBe('not_fresh');
    expect(f.send.clicks).toBe(0); expect(f.editor.events).toHaveLength(0);
  });
  test('unknown or aliased provisional URLs remain rejected', async () => {
    for (const url of ['https://chat.qwen.ai/c/new-chatx', 'https://chat.qwen.ai/c/new-xxxx', 'https://chat.qwen.ai/c/new-chat/',
      provisional + '?', provisional + '?source=home', provisional + '#', 'https://chat.qwen.ai/c/new%2Dchat',
      'https://chat.qwen.ai:443/c/new-chat', 'http://chat.qwen.ai/c/new-chat', 'https://other.invalid/c/new-chat']) {
      const { f, grant } = await sent(); f.document.URL = url;
      const response = await f.run('inspect', grant);
      expect(response.error).toBeDefined(); expect(response.text).toBeUndefined(); expect(f.send.clicks).toBe(1);
    }
  });
  test('read-only pending cannot issue submit, insertion, selection or deletion actions', async () => {
    for (const action of ['submit', 'insert', 'sendReady', 'selectModel', 'deleteConversation', 'observeDeletedConversation']) {
      const { f, grant, hash } = await sent();
      const response = await f.run(action, { ...grant, prompt, modelChoice: choice(), deleteOperation: {
        id: marker, documentGeneration: generation, sequence: 1, firstUserFingerprint: hash, conversationURL: canonical } });
      expect(response.error).toBeDefined(); expect(f.send.clicks).toBe(1); expect(f.editor.events).toHaveLength(1);
      expect(f.more.clicks).toBe(0); expect(f.remove.clicks).toBe(0); expect(f.confirm.clicks).toBe(0);
    }
  });
  test('backtracking to fresh or provisional after canonical and second canonical are terminal', async () => {
    for (const route of ['https://chat.qwen.ai/', provisional, 'https://chat.qwen.ai/c/11111111-2222-4333-8444-555555555555']) {
      const { f, grant } = await sent(); expect(await f.run('inspect', grant)).toEqual(emptyPending);
      if (route !== 'https://chat.qwen.ai/') { f.document.URL = canonical; expect((await f.run('inspect', grant)).firstUserVerified).toBe(true); }
      f.document.URL = route; expect((await f.run('inspect', grant)).error).toBeDefined();
      expect(f.send.clicks).toBe(1);
    }
  });
  test('canonical promotion does not excuse a changed full body, model node or selected label', async () => {
    for (const mutation of ['body', 'model-node', 'model-label']) {
      const { f, grant } = await sent(); expect(await f.run('inspect', grant)).toEqual(emptyPending);
      f.document.URL = canonical;
      if (mutation === 'body') f.userBody.text += ' changed';
      if (mutation === 'model-node') { f.trigger.detach(); f.body.append(f.trigger.cloneNode(true)); }
      if (mutation === 'model-label') f.modelName.text = 'Qwen3.8-Max';
      const response = await f.run('inspect', grant);
      expect(response.error).toBeDefined(); expect(response.firstUserVerified).toBeUndefined(); expect(response.text).toBeUndefined();
      expect(f.send.clicks).toBe(1);
    }
  });
});
