import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { adapterFixture, adapterSource, canonical, generation, instant, marker, prompt, provisional, submissionFingerprint } from './embedded-kimi-adapter-fixture';

describe('Kimi saved-conversation adapter', () => {
  test('standalone resource embeds the audited core exactly and no other provider adapter', () => {
    const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
    expect(adapterSource.startsWith(core + '\n')).toBe(true);
    expect(adapterSource).not.toContain('claude.ai');
    expect(adapterSource).not.toContain('chat.groq.com');
    expect(adapterSource).not.toContain('websiteChat');
  });

  test('observed selected model uses one open/close cycle and exports no guessed More model', async () => {
    const f = adapterFixture(), selected = await f.select();
    expect(selected.selected).toBe(true); expect(selected.modelEvidence.selected).toEqual(instant);
    expect(selected.modelChoices).toEqual([instant]);
    expect(selected.discoveryComplete).toBe(false);
    expect(f.trigger.clicks).toBe(2); expect(f.options.reduce((n, row) => n + row.clicks, 0)).toBe(0);
    await f.select(); expect(f.trigger.clicks).toBe(2);
    expect(adapterSource).not.toContain('k28-instant'); expect(adapterSource).not.toContain('K3.1 Pro');
  });

  test('switch from an observed agent selection to Instant clicks once then reopens to prove checked selection', async () => {
    const f = adapterFixture(); f.triggerName.text = 'K3.1 Pro';
    f.options[0].setAttribute('aria-checked', 'true'); f.options[2].setAttribute('aria-checked', 'false');
    const selected = await f.select();
    expect(selected.modelEvidence.selected).toEqual(instant); expect(f.options[2].clicks).toBe(1);
    expect(f.trigger.clicks).toBe(3); expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    const mismatch = await f.run('verifyModel', { expectedModelChoice: { key: 'k3d1-agent', label: 'K3.1 Pro' } });
    expect(mismatch.error).toBe('model_mismatch');
  });

  test('unknown, duplicated or obscured model choices fail without insertion or Send', async () => {
    const unknown = adapterFixture(); expect((await unknown.select({ key: 'invented', label: 'Invented' })).error).toBe('model_mismatch');
    const agent = adapterFixture(); expect((await agent.select({ key: 'k3d1-agent', label: 'K3.1 Pro' })).error).toBe('model_mismatch');
    expect(agent.options[0].clicks).toBe(0);
    const duplicate = adapterFixture(); duplicate.list.append(duplicate.options[0].cloneNode(true));
    expect((await duplicate.select()).error).toBe('model_unverified');
    const blocked = adapterFixture(); blocked.occlude(blocked.trigger);
    expect((await blocked.select()).error).toBe('model_unverified');
    expect(unknown.counts().sends + duplicate.counts().sends + blocked.counts().sends).toBe(0);
  });

  test('exact insertion and one Send bind the real user and literal answer independently', async () => {
    const f = adapterFixture(), complete = await f.submit();
    expect(complete.error).toBeUndefined(); expect(complete.answerComplete).toBe(true);
    expect(complete.text).toBe('{"type":"message","text":"Synthetic reply"}');
    expect(complete).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true,
      conversationIdentity: canonical, sessionLifecycle: 'saved_conversation_delete', temporary: false });
    expect(complete.firstUserFingerprint).toHaveLength(64);
    expect(f.messages.userBody.textContent).toBe(prompt);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
    expect((await f.run('submit')).error).toBe('prompt_not_inserted'); expect(f.counts().sends).toBe(1);
  });

  test('logical Lexical paragraphs preserve the complete payload despite WebKit rendered spacing', async () => {
    const outbound = '\n  café 👋\tNBSP\u00a0  \n\nLine \\"quoted\\" and \\\\ literal  \n\n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound }); await f.select(); await f.run('prepare');
    expect((await f.run('insert')).inserted).toBe(true);
    expect(f.editor.innerText).not.toBe(outbound); expect(f.draftText()).toBe(outbound);
    expect(f.editor.innerText.split('\n').length).toBeGreaterThan(outbound.split('\n').length);
    expect((await f.run('sendReady')).sendReady).toBe(true); expect((await f.run('submit')).submitted).toBe(true);
    const observed = await f.run();
    expect(observed.firstUserVerified).toBe(true); expect(f.messages.userBody.textContent).toBe(outbound);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('long tool-style prompts are not limited by the generic 256-node query budget', async () => {
    const outbound = Array.from({ length: 400 }, (_, index) => `  Exact synthetic tool field ${index}: \\"quoted\\"  `).join('\n')
      + '\n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound }); const result = await f.submit();
    expect(result.firstUserVerified).toBe(true); expect(result.answerComplete).toBe(true);
    expect(f.messages.userBody.textContent).toBe(outbound); expect(f.counts().sends).toBe(1);
  });

  test('one literal fragment preserves quotes and treats HTML-like prompt text only as text', async () => {
    const outbound = '  "straight" and \'single\' — café 👋\u00a0\t  \n\n'
      + '</p><script>globalThis.fixtureInjected = true</script><img src=x onerror="bad()">\n'
      + '&lt; &quot; &#39; &amp; literal\rreturn\n\nComputa session marker: ' + marker;
    const f = adapterFixture({ outbound }); const result = await f.submit();
    expect(result.firstUserVerified).toBe(true); expect(f.messages.userBody.textContent).toBe(outbound);
    expect(f.insertionHTML).toContain('&quot;straight&quot; and &#39;single&#39;');
    expect(f.insertionHTML).toContain('&lt;/p&gt;&lt;script&gt;');
    expect(f.insertionHTML).toContain('&amp;lt; &amp;quot; &amp;#39; &amp;amp; literal&#13;return');
    expect(f.insertionHTML).not.toContain('<script>'); expect(f.insertionHTML).not.toContain('<img');
    expect(f.editor.querySelectorAll('SCRIPT, IMG')).toHaveLength(0);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 0 });
  });

  test('hidden, nested, ambiguous and reordered composer content cannot pass exact Send verification', async () => {
    for (const mutation of ['hidden', 'inert', 'aria-hidden', 'span', 'control', 'inline-break', 'empty-paragraph', 'root-text', 'reordered', 'changed-space']) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      const first = f.editor.children[0];
      if (['hidden', 'inert', 'aria-hidden'].includes(mutation)) first.setAttribute(mutation, mutation === 'aria-hidden' ? 'true' : '');
      else if (mutation === 'span') { const text = first.text; first.replaceChildren(new f.Node('SPAN', {}, text)); }
      else if (mutation === 'control') first.append(new f.Node('INPUT', { value: 'Unexpected' }));
      else if (mutation === 'inline-break') first.append(new f.Node('BR'));
      else if (mutation === 'empty-paragraph') first.replaceChildren();
      else if (mutation === 'root-text') f.editor.text = 'Unexpected root text';
      else if (mutation === 'reordered') [f.editor.children[0], f.editor.children[1]] = [f.editor.children[1], f.editor.children[0]];
      else first.text += ' ';
      expect((await f.run('sendReady')).error).toBeDefined(); expect(f.counts().sends).toBe(0);
      expect((await f.run('submit')).error).toBeDefined(); expect(f.counts().sends).toBe(0);
    }
  });

  test('uncertain insertion and Send acknowledgements cannot be replayed', async () => {
    for (const type of ['insertionFails', 'submitThrows'] as const) {
      const f = adapterFixture({ [type]: true }); const failed = await f.submit();
      expect(failed.error).toBeDefined();
      expect(failed.submissionAcknowledgement).toBeUndefined();
      const before = f.counts();
      expect((await f.run(type === 'insertionFails' ? 'insert' : 'submit')).error).toBe('conversation_changed');
      expect(f.counts()).toEqual(before);
    }
  });

  test('successful Send returns only a bound dispatch acknowledgement before first-body proof', async () => {
    const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
    const sent = await f.run('submit');
    expect(sent.submissionAcknowledgement).toEqual({ ownerToken: '9fe25e48-2e0b-46cb-84f7-7b4f32e1794f',
      documentGeneration: generation, sequence: 1, outboundFingerprint: submissionFingerprint });
    expect(sent.submitted).toBe(true); expect(sent.userCount).toBe(0); expect(sent.firstUserVerified).toBe(false);
    expect(sent.firstUserFingerprint).toBeNull(); expect(sent.answerComplete).toBe(false);
    expect((await f.run()).firstUserVerified).toBe(true); expect(f.counts().sends).toBe(1);
  });

  test('missing or malformed native submission fingerprint cannot dispatch Send', async () => {
    for (const savedSubmissionFingerprint of [undefined, '', 1, 'a'.repeat(63), 'A'.repeat(64), 'x'.repeat(64)]) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      const sent = await f.run('submit', { savedSubmissionFingerprint });
      expect(sent.error).toBe('prompt_not_inserted'); expect(sent.submissionAcknowledgement).toBeUndefined();
      expect(f.counts().sends).toBe(0);
    }
  });

  test('occluded or disabled Send never clicks even with an exact draft', async () => {
    for (const mode of ['occluded', 'disabled']) {
      const f = adapterFixture(); await f.select(); await f.run('prepare'); await f.run('insert');
      if (mode === 'occluded') f.occlude(f.send); else f.send.setAttribute('class', 'send-button-container disabled');
      expect((await f.run('sendReady')).sendReady).toBe(false);
      expect((await f.run('submit')).error).toBe('send_unavailable'); expect(f.counts().sends).toBe(0);
    }
  });

  test('provisional route and delayed body stay pending until the exact canonical first-user bind', async () => {
    const f = adapterFixture({ provisional: true, delayedUser: true });
    const empty = await f.submit(); expect(empty.answerComplete).toBe(false); expect(empty.firstUserVerified).toBe(false);
    expect(f.document.URL).toBe(provisional);
    f.appendUser(); const provisionalBody = await f.run();
    expect(provisionalBody.ownershipPending).toBe(true); expect(provisionalBody.text).toBe('');
    f.document.URL = canonical; const canonicalBody = await f.run();
    expect(canonicalBody.firstUserVerified).toBe(true); expect(canonicalBody.answerComplete).toBe(true);
    expect(f.counts().sends).toBe(1);
  });

  test('stale native route reads cannot poison the one allowed fresh-to-provisional-to-canonical promotion', async () => {
    const f = adapterFixture({ provisional: true });
    await f.select(); await f.run('prepare'); await f.run('insert');
    expect((await f.run('submit')).submitted).toBe(true);
    // Native evaluated the fresh route immediately before the one Send changed
    // it. A rejected stale read publishes no ownership and must be discarded.
    const staleFresh = await f.run('inspect', { expectedURL: 'https://www.kimi.ai/' });
    expect(staleFresh).toEqual({ error: 'document_changed', detail: 'document_url' });
    expect(f.world.__computaKimiSavedSessionV1.terminal).toBe(false);
    let digests = 0; f.onDigest(() => { digests++; });
    const provisionalRead = await f.run();
    expect(provisionalRead.ownershipPending).toBe(true); expect(digests).toBe(0);
    // There is deliberately no awaited hash on a provisional body. Promotion
    // while native awaits its read is handled by a new exact-URL observation.
    f.document.URL = canonical;
    const staleProvisional = await f.run('inspect', { expectedURL: provisional });
    expect(staleProvisional).toEqual({ error: 'document_changed', detail: 'document_url' });
    expect(f.world.__computaKimiSavedSessionV1.terminal).toBe(false);
    const current = await f.run();
    expect(current.firstUserVerified).toBe(true); expect(current.answerComplete).toBe(true);
    expect(digests).toBe(1); expect(f.counts().sends).toBe(1);
  });

  test('foreign canonical route during the first asynchronous digest is terminal and never publishes proof', async () => {
    const f = adapterFixture({ delayedUser: true }); await f.submit(); f.appendUser();
    f.onDigest(() => { f.document.URL = canonical.replace('65258a69', '65258a68'); });
    const changed = await f.run();
    expect(changed).toEqual({ error: 'document_changed', detail: 'document_url' });
    expect(f.fingerprint).toBeUndefined();
    expect(f.world.__computaKimiSavedSessionV1.terminal).toBe(true);
    f.document.URL = canonical;
    expect((await f.run()).detail).toBe('terminal_operation');
    expect(f.counts().sends).toBe(1);
  });

  test('another provisional route, canonical chat or document generation cannot inherit the request', async () => {
    const provisionalFixture = adapterFixture({ provisional: true, delayedUser: true }); await provisionalFixture.submit();
    provisionalFixture.document.URL = provisional.replace('p5258a69', 'p5258a68');
    expect((await provisionalFixture.run()).error).toBe('conversation_changed');
    const canonicalFixture = adapterFixture(); await canonicalFixture.submit();
    canonicalFixture.document.URL = canonical.replace('65258a69', '65258a68');
    expect((await canonicalFixture.run()).error).toBe('conversation_changed');
    const changedGeneration = adapterFixture(); await changedGeneration.submit();
    expect((await changedGeneration.run('inspect', { documentGeneration: marker })).error).toBe('document_changed');
    expect(provisionalFixture.counts().sends + canonicalFixture.counts().sends + changedGeneration.counts().sends).toBe(3);
  });

  test('same-sized wrong body and physical replacement during hash fail ownership', async () => {
    for (const change of ['text', 'body', 'generation']) {
      const f = adapterFixture({ delayedUser: true }); await f.submit(); f.appendUser();
      f.onDigest(() => {
        if (change === 'text') f.messages.userBody.text = prompt.replace('Exact', 'Other');
        if (change === 'body') f.messages.content.replaceChildren(f.messages.userBody.cloneNode(true));
        if (change === 'generation') f.world.__computaKimiSavedSessionV1.generation = marker;
      });
      expect((await f.run()).error).toBeDefined(); expect(f.counts().sends).toBe(1);
    }
  });

  test('response completion must survive the asynchronous ownership check', async () => {
    const f = adapterFixture({ streaming: true }); const streaming = await f.submit();
    expect(streaming.answerComplete).toBe(false); expect(streaming.busy).toBe(true);
    f.finishResponse(); expect((await f.run()).answerComplete).toBe(true);
    f.onDigest(() => f.remove(f.rail));
    expect((await f.run()).answerComplete).toBe(false); expect(f.counts().sends).toBe(1);
  });

  test('authored prose, duplicate code and malformed JSON are never stripped to rescue a tool envelope', async () => {
    const prose = adapterFixture(); await prose.submit();
    prose.part.append(new prose.Node('P', {}, 'This is authored outside prose.'));
    const withProse = await prose.run(); expect(withProse.error).toBe('unsupported_response_format');
    expect(prose.part.textContent).toContain('This is authored outside prose.');
    const duplicate = adapterFixture(); await duplicate.submit(); duplicate.response.markdown.append(duplicate.response.segment.cloneNode(true));
    const duplicated = await duplicate.run(); expect(duplicated.error).toBe('unsupported_response_format');
    const malformed = adapterFixture(); await malformed.submit(); malformed.response.code.text = '{"type":"tool_calls",';
    expect((await malformed.run()).text).toBe('{"type":"tool_calls",');
    const disguised = adapterFixture(); await disguised.submit();
    disguised.response.markdown.append(new disguised.Node('DIV', { class: 'toolcall-flow' }, 'Authored text using a similar class'));
    expect((await disguised.run()).error).toBe('unsupported_response_format');
    expect(disguised.response.markdown.textContent).toContain('Authored text using a similar class');
  });

  test('only structurally known website thinking/tool-flow nodes are excluded from final text', async () => {
    const f = adapterFixture(); const result = await f.submit();
    expect(result.text).not.toContain('Thinking complete');
    f.thoughtPart.append(new f.Node('DIV', { class: 'unknown-provider-widget' }, 'Unknown content must survive'));
    expect((await f.run()).error).toBe('unsupported_response_format');
    expect(f.thoughtPart.textContent).toContain('Unknown content must survive');
  });

  test('a transient code Copy tooltip is optional but extra header text is not silently discarded', async () => {
    const f = adapterFixture(); await f.submit();
    const tooltip = f.response.segment.querySelector('[role="tooltip"]')!;
    f.remove(tooltip);
    expect((await f.run()).text).toBe('{"type":"message","text":"Synthetic reply"}');
    f.response.segment.querySelector('header')!.append(new f.Node('SPAN', {}, 'Unknown header text'));
    expect((await f.run()).error).toBe('unsupported_response_format');
  });

  test('owned deletion performs header, Delete and confirmation once then verifies removal', async () => {
    const f = adapterFixture(); await f.submit(); const operation = f.operation();
    const first = await f.run('deleteConversation', { deleteOperation: operation }); expect(first.pending).toBe(true);
    expect(first.deleteProof).toMatchObject({ phase: 'menu', menuAcknowledged: true, deleteAcknowledged: false, confirmAcknowledged: false, nextActionReady: true });
    expect(f.header.clicks).toBe(1); expect(f.deleteRow.clicks).toBe(0); expect(f.counts().confirms).toBe(0);
    await f.run('observeDeletedConversation', { deleteOperation: operation });
    expect(f.deleteRow.clicks).toBe(0);
    const selected = await f.run('selectConversationDeletion', { deleteOperation: operation });
    expect(selected.deleteProof).toMatchObject({ phase: 'confirmation', deleteAcknowledged: true, confirmAcknowledged: false, nextActionReady: true });
    expect(f.deleteRow.clicks).toBe(1);
    await f.run('observeDeletedConversation', { deleteOperation: operation });
    expect(f.counts().confirms).toBe(0);
    const confirm = await f.run('confirmConversationDeletion', { deleteOperation: operation }); expect(confirm.pending).toBe(true);
    expect(confirm.deleteProof).toMatchObject({ phase: 'observing', confirmAcknowledged: true, conversationDeleted: false, nextActionReady: false });
    expect(confirm.url).toBe('https://www.kimi.ai/'); expect(confirm.userCount).toBeUndefined(); expect(confirm.text).toBeUndefined();
    expect(f.counts().confirms).toBe(1);
    const deleted = await f.run('observeDeletedConversation', { deleteOperation: operation });
    expect(deleted.deleteProof).toMatchObject({ ...operation, menuAcknowledged: true, deleteAcknowledged: true,
      confirmAcknowledged: true, conversationDeleted: true, remoteErasureVerified: false });
    expect(deleted).toMatchObject({ userCount: 0, responseCount: 0, busy: false });
    expect((await f.run('observeDeletedConversation', { deleteOperation: operation })).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 1 });
  });

  test('owned streaming response may be deleted without pretending inference completed', async () => {
    const f = adapterFixture({ streaming: true }); expect((await f.submit()).answerComplete).toBe(false);
    const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); await f.run('selectConversationDeletion', { deleteOperation });
    await f.run('confirmConversationDeletion', { deleteOperation });
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.conversationDeleted).toBe(true);
  });

  test('wrong operation or unbound first user cannot open a deletion menu', async () => {
    const wrong = adapterFixture(); await wrong.submit();
    const result = await wrong.run('deleteConversation', { deleteOperation: { ...wrong.operation(), conversationURL: canonical + '-wrong' } });
    expect(result.error).toBe('conversation_changed'); expect(wrong.header.clicks).toBe(0);
    const unbound = adapterFixture({ provisional: true }); await unbound.submit();
    const pending = await unbound.run('deleteConversation', { deleteOperation: unbound.operation() });
    expect(pending.ownershipPending).toBe(true); expect(unbound.header.clicks).toBe(0);
  });

  test('wrong confirmation, lost acknowledgement and retained history never become successful cleanup', async () => {
    const wrong = adapterFixture(); await wrong.submit(); const wrongOp = wrong.operation();
    await wrong.run('deleteConversation', { deleteOperation: wrongOp }); await wrong.run('selectConversationDeletion', { deleteOperation: wrongOp });
    wrong.confirmation.title.text = 'Delete all chats';
    expect((await wrong.run('confirmConversationDeletion', { deleteOperation: wrongOp })).error).toBe('conversation_changed');
    expect(wrong.counts().confirms).toBe(0);
    const uncertain = adapterFixture({ confirmationThrows: true }); await uncertain.submit(); const uncertainOp = uncertain.operation();
    await uncertain.run('deleteConversation', { deleteOperation: uncertainOp });
    await uncertain.run('selectConversationDeletion', { deleteOperation: uncertainOp });
    expect((await uncertain.run('confirmConversationDeletion', { deleteOperation: uncertainOp })).error).toBeDefined();
    expect((await uncertain.run('observeDeletedConversation', { deleteOperation: uncertainOp })).error).toBe('conversation_changed');
    expect(uncertain.counts().confirms).toBe(1);
    const retained = adapterFixture({ retainHistoryLink: true }); await retained.submit(); const retainedOp = retained.operation();
    await retained.run('deleteConversation', { deleteOperation: retainedOp }); await retained.run('selectConversationDeletion', { deleteOperation: retainedOp });
    await retained.run('confirmConversationDeletion', { deleteOperation: retainedOp });
    expect((await retained.run('observeDeletedConversation', { deleteOperation: retainedOp })).deleteProof.conversationDeleted).toBe(false);
  });

  test('stale source mutation before confirmation prevents destructive dispatch', async () => {
    const f = adapterFixture(); await f.submit(); const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); await f.run('selectConversationDeletion', { deleteOperation });
    f.messages.userBody.text += ' changed';
    expect((await f.run('confirmConversationDeletion', { deleteOperation })).error).toBe('conversation_changed');
    expect(f.counts().confirms).toBe(0);
  });

  test('read-only cleanup observations wait for mounted controls and a real empty fresh composer', async () => {
    const f = adapterFixture(); await f.submit(); const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation });
    f.deletionMenu.setAttribute('hidden', '');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(false);
    expect(f.deleteRow.clicks).toBe(0);
    f.deletionMenu.removeAttribute('hidden');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(true);
    await f.run('selectConversationDeletion', { deleteOperation });
    f.confirmation.mask.setAttribute('hidden', '');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(false);
    expect(f.counts().confirms).toBe(0);
    f.confirmation.mask.removeAttribute('hidden');
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.nextActionReady).toBe(true);
    await f.run('confirmConversationDeletion', { deleteOperation });
    f.remove(f.editor);
    const skeleton = await f.run('observeDeletedConversation', { deleteOperation });
    expect(skeleton.pending).toBe(true); expect(skeleton.deleteProof.conversationDeleted).toBe(false);
    expect(skeleton.composer).toBeUndefined();
    f.editor.connected = true; f.scope.append(f.editor);
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts().confirms).toBe(1);
  });

  test('a not-ready claimed cleanup mutation fails instead of silently allowing another attempt', async () => {
    const f = adapterFixture(); await f.submit(); const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); f.deletionMenu.setAttribute('hidden', '');
    expect((await f.run('selectConversationDeletion', { deleteOperation })).detail).toBe('delete_not_ready');
    f.deletionMenu.removeAttribute('hidden');
    expect((await f.run('selectConversationDeletion', { deleteOperation })).detail).toBe('terminal_operation');
    expect(f.deleteRow.clicks).toBe(0);
  });

  test('verification reopen checks the actual picker hit target before another click', async () => {
    const f = adapterFixture(); f.triggerName.text = 'K3.1 Pro';
    f.options[0].setAttribute('aria-checked', 'true'); f.options[2].setAttribute('aria-checked', 'false');
    await f.run('selectModel'); await f.run('selectModel'); f.occlude(f.trigger);
    expect((await f.run('selectModel')).error).toBe('model_unverified'); expect(f.trigger.clicks).toBe(1);
  });

  test('native cleanup inspection can recover the same unpublished first-body proof after format rejection', async () => {
    const f = adapterFixture({ delayedUser: true }); await f.submit(); f.appendUser();
    f.part.append(new f.Node('P', {}, 'Outside prose is not a valid envelope'));
    expect((await f.run()).error).toBe('unsupported_response_format'); expect(f.fingerprint).toBeUndefined();
    const recovered = await f.run('inspect', { kimiCleanupInspection: true });
    expect(recovered.firstUserVerified).toBe(true); expect(recovered.text).toBe(''); expect(recovered.answerComplete).toBe(false);
    expect((await f.run('verifyModel', { kimiCleanupInspection: true })).error).toBe('unsupported_response_format');
    const deleteOperation = f.operation();
    await f.run('deleteConversation', { deleteOperation }); await f.run('selectConversationDeletion', { deleteOperation });
    await f.run('confirmConversationDeletion', { deleteOperation });
    expect((await f.run('observeDeletedConversation', { deleteOperation })).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts()).toEqual({ insertions: 1, sends: 1, confirms: 1 });
  });
});
