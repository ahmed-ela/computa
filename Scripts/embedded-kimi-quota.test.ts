import { describe, expect, test } from 'bun:test';
import { adapterFixture, canonical } from './embedded-kimi-adapter-fixture';

// Bounded structure observed on 2026-11-15. Text and drafts are synthetic;
// Vue scope hashes, SVG paths and actual account reset dates are not fixtures.
const quotaText = 'Your free quota is used up. Refreshes at 12-02.';
const initial = { expectedUserCounts: [0] };
const quotaError = { error: 'website_usage_limit' };

function installQuota(f: ReturnType<typeof adapterFixture>, text = quotaText) {
  const box = new f.Node('DIV', { id: 'chat-box', class: 'chat-box' });
  const wrap = new f.Node('DIV', { class: 'chat-editor-wrap' });
  const card = new f.Node('DIV', { class: 'chat-input-bar' });
  const content = new f.Node('DIV', { class: 'chat-input-bar-content' });
  const icon = new f.Node('svg', { role: 'img', class: 'iconify', name: 'music' });
  const label = new f.Node('SPAN', {}, text);
  const upgrade = new f.Node('SPAN', { class: 'chat-input-bar-upgrade' }, 'Upgrade');
  const actions = new f.Node('DIV', { class: 'chat-input-bar-actions' });
  const close = new f.Node('DIV', { class: 'icon-button no-background chat-input-bar-close', role: 'button', tabindex: '0', 'aria-label': 'Close' });
  close.append(new f.Node('svg', { role: 'img', class: 'iconify', name: 'Close' }));
  content.append(icon, label, upgrade); actions.append(close); card.append(content, actions);
  f.remove(f.scope); f.scope.connected = true;
  wrap.append(card, f.scope); box.append(wrap); f.body.append(box);
  return { box, wrap, card, content, icon, label, upgrade, actions, close };
}

function move(f: ReturnType<typeof adapterFixture>, node: any, parent: any) {
  f.remove(node); node.connected = true; parent.append(node);
}

describe('Kimi initial provider-owned free-quota banner', () => {
  test('reports the actual quota before a restored draft without exposing or changing it', async () => {
    for (const draft of ['', '   ', 'Unsent synthetic harness draft\nkeep every byte']) {
      const f = adapterFixture(), q = installQuota(f); f.setDraft(draft);
      expect(await f.run('inspect', initial)).toEqual(quotaError);
      expect(f.draftText()).toBe(draft);
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
      expect(f.trigger.clicks).toBe(0); expect(q.close.clicks).toBe(0); expect(q.upgrade.clicks).toBe(0);
    }
  });

  test('accepts the bounded reset-date slot without depending on the captured account date', async () => {
    for (const date of ['01-01', '02-28', '12-31']) {
      const f = adapterFixture(); installQuota(f, `Your free quota is used up. Refreshes at ${date}.`);
      f.setDraft('Unsent synthetic draft');
      expect(await f.run('inspect', initial)).toEqual(quotaError);
    }
  });

  test('only the exact visible message inside the scoped quota card can establish a limit', async () => {
    for (const change of ['no-card', 'body-text', 'editor-text', 'authored', 'editable', 'sidebar', 'hidden', 'inert', 'aria-hidden', 'css-hidden',
      'duplicate-card', 'duplicate-box', 'detached-card', 'wrong-parent', 'wrong-box-class', 'foreign-box', 'wrong-content', 'extra-child',
      'extra-content', 'missing-icon', 'wrong-icon', 'nested-label', 'other-message', 'prefix', 'suffix', 'invalid-date', 'hidden-label',
      'wrong-upgrade', 'hidden-upgrade', 'missing-close', 'wrong-close', 'nested-close', 'duplicate-editor', 'missing-editor', 'hidden-editor',
      'wrong-editor-role', 'misplaced-editor']) {
      const f = adapterFixture(), q = installQuota(f); f.setDraft('Unsent synthetic draft');
      switch (change) {
        case 'no-card': f.remove(q.card); break;
        case 'body-text': f.remove(q.card); f.body.append(new f.Node('P', {}, quotaText)); break;
        case 'editor-text': f.remove(q.card); f.setDraft(quotaText); break;
        case 'authored': q.box.setAttribute('class', 'chat-box chat-content-item'); break;
        case 'editable': q.box.setAttribute('contenteditable', 'true'); break;
        case 'sidebar': { const aside = new f.Node('ASIDE'); f.body.append(aside); move(f, q.box, aside); break; }
        case 'hidden': q.card.setAttribute('hidden', ''); break;
        case 'inert': q.wrap.setAttribute('inert', ''); break;
        case 'aria-hidden': q.box.setAttribute('aria-hidden', 'true'); break;
        case 'css-hidden': q.card.setAttribute('visibility', 'hidden'); break;
        case 'duplicate-card': q.wrap.append(q.card.cloneNode(true)); break;
        case 'duplicate-box': f.body.append(new f.Node('DIV', { id: 'chat-box', class: 'chat-box' })); break;
        case 'detached-card': f.remove(q.card); break;
        case 'wrong-parent': move(f, q.card, q.box); break;
        case 'wrong-box-class': q.box.setAttribute('class', 'other'); break;
        case 'foreign-box': q.box.setAttribute('id', 'other'); break;
        case 'wrong-content': q.content.setAttribute('class', 'other'); break;
        case 'extra-child': q.card.append(new f.Node('P', {}, 'Other content')); break;
        case 'extra-content': q.content.append(new f.Node('SPAN', {}, 'Other content')); break;
        case 'missing-icon': f.remove(q.icon); break;
        case 'wrong-icon': q.icon.setAttribute('name', 'other'); break;
        case 'nested-label': q.label.text = ''; q.label.append(new f.Node('SPAN', {}, quotaText)); break;
        case 'other-message': q.label.text = 'Your current plan includes free quota.'; break;
        case 'prefix': q.label.text = 'Example: ' + quotaText; break;
        case 'suffix': q.label.text = quotaText + ' Example only.'; break;
        case 'invalid-date': q.label.text = 'Your free quota is used up. Refreshes at 99-99.'; break;
        case 'hidden-label': q.label.setAttribute('hidden', ''); break;
        case 'wrong-upgrade': q.upgrade.text = 'Other action'; break;
        case 'hidden-upgrade': q.upgrade.setAttribute('hidden', ''); break;
        case 'missing-close': f.remove(q.close); break;
        case 'wrong-close': q.close.setAttribute('aria-label', 'Dismiss other message'); break;
        case 'nested-close': { const inner = new f.Node('DIV'); q.actions.append(inner); move(f, q.close, inner); break; }
        case 'duplicate-editor': q.wrap.append(f.editor.cloneNode(true)); break;
        case 'missing-editor': f.remove(f.editor); break;
        case 'hidden-editor': f.editor.setAttribute('hidden', ''); break;
        case 'wrong-editor-role': f.editor.setAttribute('role', 'button'); break;
        case 'misplaced-editor': move(f, f.scope, q.box); break;
      }
      const result = await f.run('inspect', initial);
      expect(result.error, change).not.toBe('website_usage_limit');
      expect(result.freshQuotaAbort, change).toBeUndefined();
      expect(f.counts(), change).toEqual({ insertions: 0, sends: 0, confirms: 0 });
      expect(q.close.clicks, change).toBe(0); expect(q.upgrade.clicks, change).toBe(0);
    }
  });

  test('quota text copied into a draft never replaces its actual empty-editor failure', async () => {
    const f = adapterFixture(); f.setDraft(quotaText);
    const result = await f.run('inspect', initial);
    expect(result.error).toBe('composer_not_empty'); expect(f.draftText()).toBe(quotaText);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  });

  test('cannot override owner, generation, account or existing-conversation checks', async () => {
    for (const change of ['owner', 'generation', 'route', 'guest', 'unknown-account', 'conversation', 'fingerprint', 'count', 'not-binding']) {
      const f = adapterFixture(); installQuota(f); f.setDraft('Unsent synthetic draft');
      const overrides: Record<string, any> = { ...initial };
      switch (change) {
        case 'owner': f.world.__computaModelOwner = 'bad-owner'; break;
        case 'generation': overrides.documentGeneration = 'bad-generation'; break;
        case 'route': f.document.URL = canonical; break;
        case 'guest': f.body.append(new f.Node('BUTTON', {}, 'Log in to sync chat history')); break;
        case 'unknown-account': f.remove(f.accountHistory); break;
        case 'conversation': overrides.expectedConversation = canonical; break;
        case 'fingerprint': overrides.expectedFirstUserFingerprint = 'a'.repeat(64); break;
        case 'count': overrides.expectedUserCounts = [1]; break;
        case 'not-binding': overrides.bindOwner = false; break;
      }
      expect((await f.run('inspect', overrides)).error, change).not.toBe('website_usage_limit');
      expect(f.counts(), change).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });

  test('unknown account chrome with a restored draft waits without authority then reports the actual quota', async () => {
    const f = adapterFixture(), q = installQuota(f); f.setDraft('Unsent synthetic draft');
    f.remove(f.accountHistory);
    const pending = { pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false };
    for (let read = 0; read < 3; read++) expect(await f.run('inspect', initial)).toEqual(pending);
    expect(f.draftText()).toBe('Unsent synthetic draft');
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 }); expect(f.trigger.clicks).toBe(0);
    f.accountHistory.connected = true; f.body.append(f.accountHistory);
    expect(await f.run('inspect', initial)).toEqual(quotaError);
    expect(f.draftText()).toBe('Unsent synthetic draft');
    expect(q.close.clicks).toBe(0); expect(q.upgrade.clicks).toBe(0);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  });

  test('account hydration preserves authenticated draft rejection and guest sign-in rejection', async () => {
    for (const account of ['authenticated', 'guest']) {
      const f = adapterFixture(); f.setDraft('Unsent synthetic draft'); f.remove(f.accountHistory);
      expect(await f.run('inspect', initial)).toEqual({ pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false });
      if (account === 'authenticated') { f.accountHistory.connected = true; f.body.append(f.accountHistory); }
      else f.body.append(new f.Node('BUTTON', {}, 'Log in to sync chat history'));
      const result = await f.run('inspect', initial);
      expect(result.error).toBe(account === 'authenticated' ? 'composer_not_empty' : 'sign_in_required');
      expect(result.pending).toBeUndefined(); expect(result.freshQuotaAbort).toBeUndefined(); expect(result.freshKimiSignInAbort).toBeUndefined();
      expect(f.draftText()).toBe('Unsent synthetic draft');
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 }); expect(f.trigger.clicks).toBe(0);
    }
  });

  test('unknown account and a draft cannot hide an ownership, transcript or control contradiction', async () => {
    for (const mutation of ['owner', 'generation', 'route', 'transcript', 'editor-duplicate', 'editor-hidden',
      'scope', 'trigger-duplicate', 'trigger-hidden', 'trigger-malformed', 'open-menu', 'editor-replaced']) {
      const f = adapterFixture(); f.setDraft('Unsent synthetic draft'); f.remove(f.accountHistory);
      const overrides: Record<string, any> = { ...initial };
      switch (mutation) {
        case 'owner': f.world.__computaModelOwner = 'other-owner'; break;
        case 'generation': overrides.documentGeneration = 'other-generation'; break;
        case 'route': f.document.URL = canonical; break;
        case 'transcript': f.installTranscript(); break;
        case 'editor-duplicate': f.scope.append(f.editor.cloneNode(true)); break;
        case 'editor-hidden': f.editor.setAttribute('hidden', ''); break;
        case 'scope': f.scope.setAttribute('class', 'other'); break;
        case 'trigger-duplicate': f.body.append(f.trigger.cloneNode(true)); break;
        case 'trigger-hidden': f.trigger.setAttribute('hidden', ''); break;
        case 'trigger-malformed': f.trigger.removeAttribute('aria-controls'); break;
        case 'open-menu': f.menu.removeAttribute('hidden'); break;
        case 'editor-replaced': {
          expect((await f.run('inspect', initial)).pending).toBe(true);
          const replacement = f.editor.cloneNode(true); f.remove(f.editor); f.scope.append(replacement); break;
        }
      }
      const result = await f.run('inspect', overrides);
      expect(result.error, mutation).toBeDefined(); expect(result.pending, mutation).toBeUndefined();
      expect(f.counts(), mutation).toEqual({ insertions: 0, sends: 0, confirms: 0 }); expect(f.trigger.clicks, mutation).toBe(0);
    }
  });

  test('unknown account wait cannot authorize model, editor, submission or cleanup operations', async () => {
    for (const action of ['discoverModels', 'selectModel', 'verifyModel', 'prepare', 'insert', 'sendReady', 'submit', 'deleteConversation']) {
      const f = adapterFixture(); f.setDraft('Unsent synthetic draft'); f.remove(f.accountHistory);
      expect((await f.run('inspect', initial)).pending).toBe(true);
      const result = await f.run(action, initial);
      expect(result.error, action).toBeDefined(); expect(result.pending, action).toBeUndefined();
      expect(f.draftText()).toBe('Unsent synthetic draft');
      expect(f.counts(), action).toEqual({ insertions: 0, sends: 0, confirms: 0 }); expect(f.trigger.clicks, action).toBe(0);
    }
  });

  test('composer rejection records only the first finite quota-read guard without changing it', async () => {
    const mutations: Record<string, (f: ReturnType<typeof adapterFixture>, q: ReturnType<typeof installQuota>) => void> = {
      card_missing: (f, q) => f.remove(q.card),
      card_ambiguous: (f, q) => q.wrap.append(q.card.cloneNode(true)),
      box_missing: (f, q) => q.box.setAttribute('id', 'other'),
      box_ambiguous: (f, q) => f.body.append(new f.Node('DIV', { id: 'chat-box' })),
      card_or_parent_shape: (f, q) => q.card.setAttribute('visibility', 'hidden'),
      associated_editor: (f, q) => move(f, f.scope, q.box),
      card_child_count: (f, q) => q.card.append(new f.Node('P', {}, 'Private text must not escape')),
      content_actions_shape: (f, q) => q.content.setAttribute('class', 'other'),
      content_or_control_count: (f, q) => f.remove(q.close),
      icon_shape: (f, q) => q.icon.setAttribute('name', 'PRIVATE_ICON'),
      label_shape: (f, q) => q.label.append(new f.Node('SPAN', {}, 'Private label')),
      label_text: (f, q) => { q.label.text = 'PRIVATE_LABEL'; },
      upgrade_shape: (f, q) => q.upgrade.setAttribute('hidden', ''),
      upgrade_label: (f, q) => { q.upgrade.text = 'PRIVATE_UPGRADE'; },
      close_shape: (f, q) => q.close.setAttribute('aria-label', 'PRIVATE_CLOSE'),
    };
    for (const [reason, mutate] of Object.entries(mutations)) {
      const f = adapterFixture(), q = installQuota(f); f.setDraft('PRIVATE_RESTORED_DRAFT'); mutate(f, q);
      const result = await f.run('inspect', initial);
      expect(result.error, reason).toBe('composer_not_empty');
      expect(result.composerGuardDiagnostic.quotaReadReason, reason).toBe(reason);
      expect(Object.keys(result).sort()).toEqual(['composerGuardDiagnostic', 'error']);
      expect(JSON.stringify(result)).not.toContain('PRIVATE_');
      expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
    const f = adapterFixture(); installQuota(f); f.setDraft('PRIVATE_RESTORED_DRAFT');
    const result = await f.run('inspect', { expectedUserCounts: [0, 1] });
    expect(result.error).toBe('composer_not_empty');
    expect(result.composerGuardDiagnostic.quotaReadReason).toBe('expected_counts');
  });

  test('does not create cleanup authority or replace a post-readiness verification', async () => {
    for (const change of ['cleanup', 'ready', 'selection', 'claimed-send', 'transcript']) {
      const f = adapterFixture();
      if (change === 'ready') expect((await f.run('inspect', initial)).composer).toBe(true);
      if (change === 'selection') expect((await f.run('selectModel')).pending).toBe(true);
      const q = installQuota(f); f.setDraft('Unsent synthetic draft');
      if (change === 'claimed-send') {
        await f.run('inspect', { ...initial, kimiCleanupInspection: true });
        f.world.__computaKimiSavedSessionV1.submitted = true;
      }
      if (change === 'transcript') f.installTranscript();
      const result = await f.run('inspect', { ...initial, ...(change === 'cleanup' ? { kimiCleanupInspection: true } : {}) });
      expect(result.error, change).not.toBe('website_usage_limit');
      expect(result.freshQuotaAbort, change).toBeUndefined();
      expect(q.close.clicks, change).toBe(0); expect(q.upgrade.clicks, change).toBe(0);
      expect(f.counts(), change).toEqual({ insertions: 0, sends: 0, confirms: 0 });
    }
  });
});
