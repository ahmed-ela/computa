import { describe, expect, test } from 'bun:test';
import { fixture, choice, prompt, marker, raw, ownerToken, generation, fingerprint, conversationID } from './embedded-qwen-adapter-fixture';

const canonical = 'https://chat.qwen.ai/c/' + conversationID;
async function select(f: ReturnType<typeof fixture>, label = 'Qwen3.7-Plus') {
  for (let i = 0; i < 8; i++) {
    const result = await f.run('selectModel', { modelChoice: choice(label) });
    expect(result.error).toBeUndefined();
    if (result.selected) return result;
  }
  throw new Error('Fixture selection did not finish');
}
async function inserted(f: ReturnType<typeof fixture>, text = prompt) {
  await select(f);
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert', { prompt: text })).inserted).toBe(true);
  expect((await f.run('sendReady', { prompt: text })).sendReady).toBe(true);
}
async function submitted(f: ReturnType<typeof fixture>, text = prompt) {
  await inserted(f, text);
  const hash = await fingerprint(text);
  const output = await f.run('submit', { prompt: text, savedSubmissionFingerprint: hash });
  expect(output.submitted).toBe(true);
  expect(output.submissionAcknowledgement).toEqual({ ownerToken, documentGeneration: generation, sequence: 1, outboundFingerprint: hash });
  expect(output.url).toBe('https://chat.qwen.ai/');
  expect(output.userCount).toBe(0); expect(output.firstUserVerified).toBe(false); expect(output.text).toBe('');
  return hash;
}
async function owned(f: ReturnType<typeof fixture>) {
  const hash = await submitted(f);
  const output = await f.run('inspect');
  expect(output.firstUserVerified).toBe(true); expect(output.firstUserFingerprint).toBe(hash);
  return hash;
}
function deletionInput(hash: string) {
  return { expectedFirstUserFingerprint: hash, expectedConversation: canonical, deleteOperation: {
    id: '28f9bb90-310a-42b0-a8a7-0108264cc1fd', documentGeneration: generation, sequence: 1,
    firstUserFingerprint: hash, conversationURL: canonical
  } };
}

describe('Qwen complete saved-conversation adapter', () => {
  test('selection exports observed labels with no API aliases or invented IDs', async () => {
    const f = fixture(); const result = await select(f, 'Qwen3.8-Max');
    expect(result.modelChoices).toEqual(['Qwen3.7-Plus', 'Qwen3.8-Max', 'Qwen3.8-Omni-Flash'].map(choice));
    expect(result.modelEvidence.selected).toEqual(choice('Qwen3.8-Max'));
    expect(f.choices[1].clicks).toBe(1); expect(f.trigger.clicks).toBe(3);
    expect((await f.run('verifyModel', { expectedModelChoice: choice('Qwen3.8-Max') })).modelEvidence.selected).toEqual(choice('Qwen3.8-Max'));
  });

  test('full prompt including spaces Unicode quotes and marker is inserted once and independently echoed', async () => {
    const f = fixture(), text = ' \n\t"literal" \'single\' <script>literal</script> café 👋\u00a0  \n\nComputa session marker: ' + marker;
    const hash = await submitted(f, text);
    expect(f.editor.events).toHaveLength(1); expect(f.userBody.textContent).toBe(text); expect(f.send.clicks).toBe(1);
    const result = await f.run('inspect');
    expect(result.firstUserVerified).toBe(true); expect(result.firstUserFingerprint).toBe(hash);
    expect(result.answerComplete).toBe(true); expect(result.text).toBe(raw); expect(result.conversationIdentity).toBe(canonical);
  });

  test('streaming footer absence and Stop prevent completion until independently observed', async () => {
    const f = fixture({ completeOnSend: false }); const hash = await submitted(f);
    const streaming = await f.run('inspect');
    expect(streaming.firstUserVerified).toBe(true); expect(streaming.answerComplete).toBe(false); expect(streaming.busy).toBe(true);
    f.complete(); const result = await f.run('inspect', { expectedFirstUserFingerprint: hash });
    expect(result.answerComplete).toBe(true); expect(result.busy).toBe(false);
  });

  test('no response is accepted without a complete exact first body', async () => {
    for (const change of ['marker-only', 'append', 'replace-node', 'wrong-count']) {
      const f = fixture(); await submitted(f);
      if (change === 'marker-only') f.userBody.text = 'Computa session marker: ' + marker;
      if (change === 'append') f.userBody.text += ' extra';
      if (change === 'replace-node') f.beforeDigest(() => { f.userBody.parentElement!.replaceChildren(f.userBody.cloneNode(true)); });
      if (change === 'wrong-count') f.root.parentElement!.append(f.root.cloneNode(true));
      const result = await f.run('inspect');
      expect(result.error).toBeDefined(); expect(result.firstUserVerified).toBeUndefined(); expect(result.text).toBeUndefined();
      expect(f.send.clicks).toBe(1);
    }
  });

  test('native marker fingerprint owner generation and physical selected model stay mandatory', async () => {
    for (const change of ['marker', 'hash', 'owner', 'generation', 'model', 'model-node']) {
      const f = fixture(); const hash = await owned(f); const override: any = { expectedFirstUserFingerprint: hash };
      if (change === 'marker') override.expectedFirstUserMarker = generation;
      if (change === 'hash') override.expectedFirstUserFingerprint = '0'.repeat(64);
      if (change === 'owner') override.ownerToken = generation;
      if (change === 'generation') override.documentGeneration = ownerToken;
      if (change === 'model') f.modelName.text = 'Qwen3.8-Max';
      if (change === 'model-node') { f.trigger.detach(); f.body.append(f.trigger.cloneNode(true)); }
      expect((await f.run('inspect', override)).error).toBeDefined(); expect(f.send.clicks).toBe(1);
    }
  });

  test('canonical route changes during hashing cannot publish or adopt another chat', async () => {
    const f = fixture(); await submitted(f);
    f.beforeDigest(() => { f.document.URL = 'https://chat.qwen.ai/c/11111111-2222-4333-8444-555555555555'; });
    expect((await f.run('inspect')).error).toBe('document_changed');
    f.beforeDigest(() => {}); f.document.URL = canonical;
    expect((await f.run('inspect')).detail).toBe('terminal_operation'); expect(f.send.clicks).toBe(1);
  });

  test('a stale native expected URL is discarded before state adoption, then a fresh read proves the body', async () => {
    const f = fixture(); const hash = await submitted(f);
    expect((await f.run('inspect', { expectedURL: 'https://chat.qwen.ai/' })).error).toBe('document_changed');
    const recovered = await f.run('inspect'); expect(recovered.firstUserFingerprint).toBe(hash); expect(recovered.answerComplete).toBe(true);
  });

  test('one native dispatch acknowledgement is not answer or first-body authority', async () => {
    const f = fixture(); await inserted(f);
    f.send.onClick = () => { f.editor.value = ''; };
    const result = await f.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) });
    expect(result.submitted).toBe(true); expect(result.firstUserVerified).toBe(false);
    const pending = await f.run('inspect'); expect(pending.firstUserVerified).toBe(false); expect(pending.answerComplete).toBe(false); expect(pending.text).toBe('');
    expect((await f.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) })).error).toBeDefined();
    expect(f.send.clicks).toBe(1);
  });

  test('missing or malformed native submission fingerprint cannot dispatch', async () => {
    for (const value of [undefined, 'bad', 'A'.repeat(64), 123]) {
      const f = fixture(); await inserted(f);
      const result = await f.run('submit', { prompt, savedSubmissionFingerprint: value });
      expect(result.error).toBe('prompt_not_inserted'); expect(f.send.clicks).toBe(0);
    }
  });

  test('a throwing or lost Send callback never leads to a second Send', async () => {
    const thrown = fixture(); await inserted(thrown);
    const action = thrown.send.onClick!; thrown.send.onClick = () => { action(); throw new Error('Lost callback'); };
    const result = await thrown.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) });
    expect(result.error).toBe('document_changed'); expect(result.submissionAcknowledgement).toBeUndefined();
    expect((await thrown.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) })).error).toBeDefined();
    expect(thrown.send.clicks).toBe(1);
    const lost = fixture(); await submitted(lost); // Discard successful callback as if native timed out.
    expect((await lost.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) })).error).toBeDefined();
    expect(lost.send.clicks).toBe(1);
  });

  test('textarea event mutation fails exact readback and never reinserts', async () => {
    const f = fixture(); await select(f); await f.run('prepare');
    const onInput = f.editor.onDispatch!; f.editor.onDispatch = event => { onInput(event); f.editor.value += ' '; };
    expect((await f.run('insert', { prompt })).error).toBe('prompt_not_inserted');
    expect((await f.run('insert', { prompt })).detail).toBe('terminal_operation');
    expect(f.editor.events).toHaveLength(1); expect(f.send.clicks).toBe(0);
  });

  test('Send and composer replacement or occlusion cannot dispatch', async () => {
    for (const kind of ['send', 'composer', 'occluded']) {
      const f = fixture(); await inserted(f);
      if (kind === 'send') { f.send.detach(); f.sendScope.append(f.send.cloneNode(true)); }
      if (kind === 'composer') { f.editor.detach(); f.scope.append(f.editor.cloneNode(true)); }
      if (kind === 'occluded') f.occlude(f.send);
      expect((await f.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) })).error).toBeDefined();
      expect(f.send.clicks).toBe(0);
    }
  });

  test('malformed raw content is returned whole for codec rejection; authored prose is never rescued', async () => {
    for (const text of ['{"type":"tool_calls",', 'Here is your answer: ' + raw, '```json\n' + raw + '\n```']) {
      const f = fixture(); await submitted(f); f.literal.text = text;
      const result = await f.run('inspect'); expect(result.text).toBe(text); expect(result.firstUserVerified).toBe(true);
    }
  });

  test('unsupported authored structure cannot become an answer but exact owned cleanup remains available', async () => {
    const f = fixture(); const hash = await submitted(f);
    f.flow.append(new f.Node('DIV', {}, 'Extra authored paragraph'));
    expect((await f.run('inspect')).error).toBe('unsupported_response_format');
    const cleanup = await f.run('inspect', { savedCleanupInspection: true });
    expect(cleanup.firstUserFingerprint).toBe(hash); expect(cleanup.text).toBe(''); expect(cleanup.answerComplete).toBe(false);
    expect((await f.run('deleteConversation', deletionInput(hash))).deleteProof.phase).toBe('menu');
  });

  test('deletion requires all three once-only stages and a separate root outcome observation', async () => {
    const f = fixture(); const hash = await owned(f), input = deletionInput(hash);
    let result = await f.run('deleteConversation', input);
    expect(result.deleteProof).toMatchObject({ phase: 'menu', menuAcknowledged: true, deleteAcknowledged: false, confirmAcknowledged: false, nextActionReady: true });
    expect(result.userCount).toBeUndefined(); expect(result.text).toBeUndefined();
    result = await f.run('selectConversationDeletion', input);
    expect(result.deleteProof).toMatchObject({ phase: 'confirmation', menuAcknowledged: true, deleteAcknowledged: true, confirmAcknowledged: false, nextActionReady: true });
    result = await f.run('confirmConversationDeletion', input);
    expect(result.url).toBe('https://chat.qwen.ai/');
    expect(result.deleteProof).toMatchObject({ phase: 'observing', confirmAcknowledged: true, conversationDeleted: false });
    expect(result.userCount).toBeUndefined();
    result = await f.run('observeDeletedConversation', input);
    expect(result.deleteProof.conversationDeleted).toBe(true); expect(result.deleteProof.remoteErasureVerified).toBe(false);
    expect(result.userCount).toBe(0); expect(result.responseCount).toBe(0);
    expect([f.more.clicks, f.remove.clicks, f.confirm.clicks, f.send.clicks]).toEqual([1, 1, 1, 1]);
  });

  test('read-only deletion observation reports readiness without dispatching or replaying lost callbacks', async () => {
    const f = fixture(); const hash = await owned(f), input = deletionInput(hash);
    await f.run('deleteConversation', input); // Discard callback, then observe the actual stage.
    for (let i = 0; i < 3; i++) expect((await f.run('observeDeletedConversation', input)).deleteProof.phase).toBe('menu');
    expect([f.more.clicks, f.remove.clicks, f.confirm.clicks]).toEqual([1, 0, 0]);
    await f.run('selectConversationDeletion', input);
    for (let i = 0; i < 3; i++) expect((await f.run('observeDeletedConversation', input)).deleteProof.phase).toBe('confirmation');
    expect([f.more.clicks, f.remove.clicks, f.confirm.clicks]).toEqual([1, 1, 0]);
    await f.run('confirmConversationDeletion', input);
    for (let i = 0; i < 3; i++) expect((await f.run('observeDeletedConversation', input)).deleteProof.conversationDeleted).toBe(true);
    expect([f.more.clicks, f.remove.clicks, f.confirm.clicks]).toEqual([1, 1, 1]);
  });

  test('not-ready destructive stages are never retried after the native claim', async () => {
    const f = fixture(); const hash = await owned(f), input = deletionInput(hash);
    f.more.onClick = () => {};
    expect((await f.run('deleteConversation', input)).deleteProof.nextActionReady).toBe(false);
    expect((await f.run('observeDeletedConversation', input)).deleteProof.nextActionReady).toBe(false);
    expect((await f.run('selectConversationDeletion', input)).detail).toBe('delete_not_ready');
    f.body.append(f.menu);
    expect((await f.run('selectConversationDeletion', input)).detail).toBe('terminal_operation');
    expect(f.more.clicks).toBe(1); expect(f.remove.clicks).toBe(0);
  });

  test('foreign deletion dialog, replaced menu and changed operation cannot target another chat', async () => {
    for (const kind of ['dialog', 'menu', 'operation', 'route']) {
      const f = fixture(); const hash = await owned(f), input = deletionInput(hash);
      await f.run('deleteConversation', input);
      if (kind === 'menu') { f.menu.detach(); f.body.append(f.menu.cloneNode(true)); }
      if (kind === 'operation') input.deleteOperation.id = generation;
      if (kind === 'route') f.document.URL = 'https://chat.qwen.ai/c/11111111-2222-4333-8444-555555555555';
      if (kind === 'dialog') {
        await f.run('selectConversationDeletion', input); f.notice.setAttribute('data-chat-id', generation);
        expect((await f.run('confirmConversationDeletion', input)).error).toBeDefined();
      } else expect((await f.run('selectConversationDeletion', input)).error).toBeDefined();
      expect(f.confirm.clicks).toBe(0);
    }
  });

  test('throwing destructive callbacks are not acknowledged or repeated', async () => {
    for (const stage of ['menu', 'confirmation', 'observing']) {
      const f = fixture(); const hash = await owned(f), input = deletionInput(hash);
      const control = stage === 'menu' ? f.more : stage === 'confirmation' ? f.remove : f.confirm;
      const action = control.onClick!; control.onClick = () => { action(); throw new Error('Callback lost'); };
      if (stage !== 'menu') await f.run('deleteConversation', input);
      if (stage === 'observing') await f.run('selectConversationDeletion', input);
      const name = stage === 'menu' ? 'deleteConversation' : stage === 'confirmation' ? 'selectConversationDeletion' : 'confirmConversationDeletion';
      const result = await f.run(name, input); expect(result.error).toBe('document_changed'); expect(result.deleteProof).toBeUndefined();
      expect((await f.run(name, input)).detail).toBe('terminal_operation'); expect(control.clicks).toBe(1);
    }
  });

  test('root navigation alone cannot prove deletion while retained transcript, dialog, history or skeleton exists', async () => {
    for (const kind of ['transcript', 'dialog', 'history', 'skeleton', 'draft']) {
      const f = fixture(); const hash = await owned(f), input = deletionInput(hash);
      await f.run('deleteConversation', input); await f.run('selectConversationDeletion', input);
      const confirm = f.confirm.onClick!;
      f.confirm.onClick = () => {
        confirm();
        if (kind === 'transcript') f.body.append(f.turn);
        if (kind === 'dialog') f.body.append(f.dialog);
        if (kind === 'history') f.body.append(new f.Node('A', { href: canonical }, 'Synthetic chat'));
        if (kind === 'skeleton') f.scope.detach();
        if (kind === 'draft') f.editor.value = 'Different draft';
      };
      await f.run('confirmConversationDeletion', input);
      const result = await f.run('observeDeletedConversation', input);
      expect(result.deleteProof.conversationDeleted).toBe(false); expect(result.pending).toBe(true);
      expect(f.confirm.clicks).toBe(1);
    }
  });
});
