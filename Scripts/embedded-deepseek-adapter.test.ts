import { describe, expect, test } from 'bun:test';
import { fixture, conversation, mode, prompt, marker, raw, ownerToken, generation, fingerprint } from './embedded-deepseek-adapter-fixture';

async function select(f: ReturnType<typeof fixture>, choice = mode()) {
  for (let index = 0; index < 6; index++) {
    const result = await f.run('selectMode', { modeChoice: choice });
    expect(result.error).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
    if (result.selected) return result;
  }
  throw new Error('Synthetic mode selection did not settle');
}
async function submitted(f: ReturnType<typeof fixture>, choice = mode(), text = prompt) {
  await select(f, choice);
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert', { prompt: text })).inserted).toBe(true);
  expect((await f.run('sendReady', { prompt: text })).sendReady).toBe(true);
  const hash = await fingerprint(text);
  const result = await f.run('submit', { prompt: text, savedSubmissionFingerprint: hash });
  expect(result.submissionAcknowledgement).toEqual({ ownerToken, documentGeneration: generation, sequence: 1, outboundFingerprint: hash });
  expect(result.modeEvidence.selected).toEqual(choice); expect(result.modelEvidence).toBeUndefined();
  expect(result.firstUserVerified).toBe(false); expect(result.text).toBe(''); expect(result.userCount).toBe(0);
  return hash;
}
async function owned(f: ReturnType<typeof fixture>, choice = mode()) {
  const hash = await submitted(f, choice);
  const result = await f.run('inspect', { expectedModeChoice: choice });
  expect(result.firstUserVerified).toBe(true); expect(result.firstUserFingerprint).toBe(hash);
  expect(result.modeEvidence.selected).toEqual(choice); expect(result.modelEvidence).toBeUndefined();
  return hash;
}
function deletion(hash: string) {
  return { expectedFirstUserFingerprint: hash, expectedConversation: conversation, deleteOperation: {
    id: '28f9bb90-310a-42b0-a8a7-0108264cc1fd', documentGeneration: generation, sequence: 1,
    firstUserFingerprint: hash, conversationURL: conversation
  } };
}

describe('DeepSeek composed mode adapter (not live qualification)', () => {
  test('discovery exposes modes only and performs no toggle or backend-model assertion', async () => {
    const f = fixture({ fresh: true }); f.setMode(false, true);
    const result = await f.run('discoverModes');
    expect(result.modeChoices).toEqual([mode(), mode('deepthink')]);
    expect(result.modeEvidence).toBeNull(); expect(result.modelEvidence).toBeUndefined();
    expect(f.search.clicks).toBe(0); expect(f.deepThink.clicks).toBe(0);
    expect((await f.run('selectModel', { modelChoice: mode() })).error).toBe('unknown_action');
  });

  test('Chat and DeepThink have separately pinned mode evidence with Search disabled', async () => {
    for (const key of ['chat', 'deepthink']) {
      const f = fixture({ fresh: true }); f.setMode(key === 'chat', true);
      const result = await select(f, mode(key));
      expect(result.modeEvidence).toEqual({ selected: mode(key), source: 'website_mode_toggle', backendModel: null, search: false });
      expect(f.search.clicks).toBe(1); expect(f.deepThink.clicks).toBe(1);
      expect((await f.run('verifyMode', { expectedModeChoice: mode(key) })).modeEvidence).toEqual(result.modeEvidence);
      await select(f, mode(key)); expect(f.search.clicks).toBe(1); expect(f.deepThink.clicks).toBe(1);
    }
  });

  test('unknown backend-name choices, named-model inputs and contradictory toggle state cannot bind', async () => {
    for (const args of [{ modeChoice: { key: 'deepseek-v4', label: 'DeepSeek V4' } },
      { modeChoice: mode(), modelChoice: mode() }, { modeChoice: mode(), expectedModelChoice: mode() }]) {
      const f = fixture({ fresh: true });
      expect((await f.run('selectMode', args)).error).toBe('mode_unverified');
      expect(f.deepThink.clicks).toBe(0); expect(f.search.clicks).toBe(0);
    }
    const f = fixture({ fresh: true }); f.deepThink.values['aria-pressed'] = 'true';
    expect((await f.run('selectMode', { modeChoice: mode('deepthink') })).error).toBeDefined(); expect(f.deepThink.clicks).toBe(0);
  });

  test('a lost mode callback is observed, never replayed; throwing callbacks grant no mode proof', async () => {
    const f = fixture({ fresh: true });
    await f.run('selectMode', { modeChoice: mode('deepthink') }); // Successful callback discarded.
    const result = await f.run('selectMode', { modeChoice: mode('deepthink') });
    expect(result.selected).toBe(true); expect(f.deepThink.clicks).toBe(1);
    const thrown = fixture({ fresh: true }); const click = thrown.deepThink.onClick!;
    thrown.deepThink.onClick = () => { click(); throw new Error('Synthetic lost callback'); };
    const failed = await thrown.run('selectMode', { modeChoice: mode('deepthink') });
    expect(failed.error).toBe('document_changed'); expect(failed.modeEvidence).toBeUndefined();
    expect((await thrown.run('selectMode', { modeChoice: mode('deepthink') })).detail).toBe('terminal_operation');
    expect(thrown.deepThink.clicks).toBe(1);
  });

  test('pending Search and DeepThink state cannot cause repeated toggles or inherit replaced controls', async () => {
    for (const target of ['search', 'deepThink'] as const) {
      const f = fixture({ fresh: true }); f.setMode(false, target === 'search'); f[target].onClick = () => {};
      for (let i = 0; i < 3; i++) expect((await f.run('selectMode', { modeChoice: mode('deepthink') })).pending).toBe(true);
      expect(f[target].clicks).toBe(1);
      const old = f[target]; old.detach(); f.scope.append(old.cloneNode(true));
      expect((await f.run('selectMode', { modeChoice: mode('deepthink') })).error).toBe('mode_mismatch');
      expect(old.clicks).toBe(1);
    }
  });

  test('both modes preserve complete prompt, dispatch ack and exact body independently of completion', async () => {
    for (const key of ['chat', 'deepthink']) {
      const f = fixture({ fresh: true }), text = ' \n"literal" <img> café 👋\t\u00a0\n\nComputa session marker: ' + marker;
      const hash = await submitted(f, mode(key), text);
      const result = await f.run('inspect', { expectedModeChoice: mode(key) });
      expect(result.firstUserFingerprint).toBe(hash); expect(f.firstText.text).toBe(text);
      expect(result.text).toBe(raw); expect(result.answerComplete).toBe(true);
      expect(result.modeEvidence.backendModel).toBeNull(); expect(result.modelEvidence).toBeUndefined();
      expect(f.send.clicks).toBe(1); expect(f.editor.events).toHaveLength(1);
    }
  });

  test('missing observed terminal controls withhold completion; no invented streaming glyph is used', async () => {
    for (const state of ['no-answer', 'no-rail', 'no-arrow', 'no-read-aloud', 'disabled-action', 'draft']) {
      const f = fixture({ fresh: true, completeOnSend: state !== 'no-answer' }); await submitted(f);
      if (state === 'no-rail') f.rail.detach();
      if (state === 'no-arrow') f.path.detach();
      if (state === 'no-read-aloud') delete f.actions[4].values['aria-label'];
      if (state === 'disabled-action') f.actions[0].disabled = true;
      if (state === 'draft') f.editor.value = 'Unexpected draft';
      const result = await f.run('inspect');
      expect(result.firstUserVerified).toBe(true); expect(result.answerComplete).toBe(false); expect(result.busy).toBe(true);
      expect(f.read().composer().streaming).toBeNull(); expect(f.send.clicks).toBe(1);
    }
  });

  test('no-answer candidate becomes complete only after controls and final source are observed', async () => {
    const f = fixture({ fresh: true, completeOnSend: false }); const hash = await owned(f);
    expect((await f.run('inspect', { expectedFirstUserFingerprint: hash })).answerComplete).toBe(false);
    f.complete(); const result = await f.run('inspect', { expectedFirstUserFingerprint: hash });
    expect(result.answerComplete).toBe(true); expect(result.text).toBe(raw);
  });

  test('mode/Search changes during the awaited body hash reject output and never toggle them back', async () => {
    for (const kind of ['mode', 'search', 'physical']) {
      const f = fixture({ fresh: true }); await submitted(f);
      f.beforeDigest(() => {
        if (kind === 'mode') f.setMode(true);
        if (kind === 'search') f.setMode(false, true);
        if (kind === 'physical') { f.deepThink.detach(); f.scope.append(f.deepThink.cloneNode(true)); }
      });
      expect((await f.run('inspect')).error).toBe('mode_unverified');
      expect(f.deepThink.clicks).toBe(0); expect(f.search.clicks).toBe(0); expect(f.send.clicks).toBe(1);
    }
  });

  test('mode binding failures identify finite stages without accepting changed controls or replaying Send', async () => {
    for (const timing of ['before-read', 'during-hash']) {
      for (const kind of ['mode_unbound', 'search_selected', 'deepthink_replaced', 'search_replaced', 'mode_choice_changed', 'mode_named_input']) {
        const f = fixture({ fresh: true }); await submitted(f);
        const change = () => {
          if (kind === 'mode_unbound') f.world.__computaDeepSeekSavedSessionV1.mode = null;
          if (kind === 'search_selected') f.setMode(false, true);
          if (kind === 'mode_choice_changed') f.setMode(true, false);
          if (kind === 'deepthink_replaced') { f.deepThink.detach(); f.scope.append(f.deepThink.cloneNode(true)); }
          if (kind === 'search_replaced') { f.search.detach(); f.scope.append(f.search.cloneNode(true)); }
        };
        if (timing === 'before-read') change(); else f.beforeDigest(change);
        const result = await f.run('inspect', { expectedModeChoice: mode(),
          ...(kind === 'mode_named_input' ? { expectedModelChoice: mode() } : {}) });
        expect(result.error).toBe('mode_unverified'); expect(result.detail).toBe(kind);
        expect(result.modeEvidence).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
        expect(result.text).toBeUndefined(); expect(result.firstUserVerified).toBeUndefined();
        expect((await f.run('inspect')).detail).toBe('terminal_operation');
        expect((await f.run('deleteConversation')).detail).toBe('terminal_operation');
        expect(f.send.clicks).toBe(1); expect(f.deepThink.clicks).toBe(0); expect(f.search.clicks).toBe(0);
        expect(f.trigger.clicks).toBe(0); expect(f.remove.clicks).toBe(0); expect(f.confirm.clicks).toBe(0);
      }
    }
  });

  test('mismatched first body or canonical route cannot be substituted after submission', async () => {
    for (const kind of ['body', 'route', 'hash']) {
      const f = fixture({ fresh: true }); const hash = await owned(f);
      if (kind === 'body') f.firstText.text += ' foreign';
      if (kind === 'route') f.document.URL = conversation.replace('12345678-', '87654321-');
      const result = await f.run('inspect', { expectedFirstUserFingerprint: kind === 'hash' ? '0'.repeat(64) : hash });
      expect(result.error).toBe('conversation_changed'); expect(result.text).toBeUndefined(); expect(f.send.clicks).toBe(1);
    }
  });

  test('unsupported outside prose keeps owned cleanup available without exposing reasoning', async () => {
    const f = fixture({ fresh: true }); const hash = await submitted(f);
    f.answer.replaceChildren(f.reasoning, f.final);
    expect((await f.run('inspect')).text).toBe(raw);
    f.answer.append(new f.Node('P', {}, 'Additional authored text'));
    expect((await f.run('inspect', { expectedFirstUserFingerprint: hash })).error).toBe('unsupported_response_format');
    const cleanup = await f.run('inspect', { savedCleanupInspection: true, expectedFirstUserFingerprint: hash });
    expect(cleanup.firstUserVerified).toBe(true); expect(cleanup.text).toBe(''); expect(cleanup.answerComplete).toBe(false);
    expect((await f.run('deleteConversation', deletion(hash))).deleteProof.phase).toBe('menu');
  });

  test('history anchor context is held through all three acknowledged deletion stages', async () => {
    const f = fixture({ fresh: true }); const hash = await owned(f), input = deletion(hash);
    expect((await f.run('deleteConversation', input)).deleteProof).toMatchObject({ phase: 'menu', menuAcknowledged: true, nextActionReady: true });
    expect((await f.run('observeDeletedConversation', input)).deleteProof.nextActionReady).toBe(true);
    expect(f.remove.clicks).toBe(0);
    expect((await f.run('selectConversationDeletion', input)).deleteProof).toMatchObject({ phase: 'confirmation', deleteAcknowledged: true, nextActionReady: true });
    expect((await f.run('observeDeletedConversation', input)).deleteProof.nextActionReady).toBe(true);
    expect(f.confirm.clicks).toBe(0);
    const confirmation = await f.run('confirmConversationDeletion', input);
    expect(confirmation.url).toBe('https://chat.deepseek.com/'); expect(confirmation.userCount).toBeUndefined();
    expect(confirmation.deleteProof).toMatchObject({ phase: 'observing', confirmAcknowledged: true, conversationDeleted: false });
    const result = await f.run('observeDeletedConversation', input);
    expect(result.deleteProof.conversationDeleted).toBe(true); expect(result.deleteProof.remoteErasureVerified).toBe(false);
    expect([f.trigger.clicks, f.remove.clicks, f.confirm.clicks]).toEqual([1, 1, 1]);
  });

  test('no-ID confirmation cannot inherit changed history anchor, first body, route or foreign dialog', async () => {
    for (const change of ['anchor', 'body', 'route', 'dialog', 'mode', 'operation']) {
      const f = fixture({ fresh: true }); const hash = await owned(f), input = deletion(hash);
      await f.run('deleteConversation', input); await f.run('selectConversationDeletion', input);
      if (change === 'anchor') { f.anchor.detach(); f.body.append(f.anchor.cloneNode(true)); }
      if (change === 'body') f.firstText.text += '!';
      if (change === 'route') f.document.URL = conversation.replace('12345678-', '87654321-');
      if (change === 'dialog') { f.modal.detach(); f.body.append(f.modal.cloneNode(true)); }
      if (change === 'mode') f.setMode(true);
      if (change === 'operation') input.deleteOperation.id = ownerToken;
      expect((await f.run('confirmConversationDeletion', input)).error).toBeDefined(); expect(f.confirm.clicks).toBe(0);
    }
  });

  test('missing menu stays read-only pending and a claimed not-ready mutation cannot be retried', async () => {
    const f = fixture({ fresh: true }); const hash = await owned(f), input = deletion(hash);
    f.trigger.onClick = () => {};
    expect((await f.run('deleteConversation', input)).deleteProof.nextActionReady).toBe(false);
    for (let index = 0; index < 3; index++) expect((await f.run('observeDeletedConversation', input)).deleteProof.nextActionReady).toBe(false);
    expect((await f.run('selectConversationDeletion', input)).detail).toBe('delete_not_ready');
    f.body.append(f.menu);
    expect((await f.run('selectConversationDeletion', input)).detail).toBe('terminal_operation');
    expect(f.trigger.clicks).toBe(1); expect(f.remove.clicks).toBe(0);
  });

  test('retained history and replacement-root skeleton cannot fabricate deletion success', async () => {
    for (const change of ['history', 'skeleton', 'dialog']) {
      const f = fixture({ fresh: true }); const hash = await owned(f), input = deletion(hash);
      await f.run('deleteConversation', input); await f.run('selectConversationDeletion', input);
      const click = f.confirm.onClick!; f.confirm.onClick = () => {
        click();
        if (change === 'history') f.body.append(new f.Node('A', { href: conversation }));
        if (change === 'skeleton') f.editor.detach();
        if (change === 'dialog') f.body.append(f.modal);
      };
      await f.run('confirmConversationDeletion', input);
      const result = await f.run('observeDeletedConversation', input);
      expect(result.deleteProof.conversationDeleted).toBe(false); expect(result.pending).toBe(true); expect(f.confirm.clicks).toBe(1);
    }
  });

  test('throwing confirm callback grants no receipt and cannot replay the destructive action', async () => {
    const f = fixture({ fresh: true }); const hash = await owned(f), input = deletion(hash);
    await f.run('deleteConversation', input); await f.run('selectConversationDeletion', input);
    const click = f.confirm.onClick!; f.confirm.onClick = () => { click(); throw new Error('Synthetic callback loss'); };
    const result = await f.run('confirmConversationDeletion', input);
    expect(result.error).toBe('document_changed'); expect(result.deleteProof).toBeUndefined();
    expect((await f.run('confirmConversationDeletion', input)).detail).toBe('terminal_operation'); expect(f.confirm.clicks).toBe(1);
  });
});
