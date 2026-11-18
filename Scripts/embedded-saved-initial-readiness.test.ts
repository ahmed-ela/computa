import { describe, expect, test } from 'bun:test';
import { fixture as qwen, generation, ownerToken } from './embedded-qwen-adapter-fixture';
import { fixture as deepseek } from './embedded-deepseek-adapter-fixture';

const pending = { pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false };
const providers = [
  { name: 'qwen', make: qwen, controls: ['editor', 'trigger', 'modelName'],
    missing: 'modelName', bound: 'editor', selector: 'selectModel', choice: { key: 'Qwen3.7-Plus', label: 'Qwen3.7-Plus' } },
  { name: 'deepseek', make: () => deepseek({ fresh: true }), controls: ['editor', 'send', 'deepThink', 'search'],
    missing: 'send', bound: 'deepThink', selector: 'selectMode', choice: { key: 'deepthink', label: 'DeepThink' } }
] as const;

describe('saved-conversation initial rendering readiness', () => {
  for (const provider of providers) {
    test(`${provider.name}: each missing initial control yields only negative readiness, then mounted controls can be read`, async () => {
      for (const key of provider.controls) {
        const f: any = provider.make(), node = f[key], parent = node.parentElement;
        node.detach();
        expect(await f.run('inspect')).toEqual(pending);
        expect(await f.run('inspect')).toEqual(pending);
        expect(f.mutations()).toBe(0);
        parent.append(node);
        const ready = await f.run('inspect');
        expect(ready.error).toBeUndefined(); expect(ready.pending).toBeUndefined();
        expect(ready.composer).toBe(true); expect(ready.userCount).toBe(0); expect(ready.responseCount).toBe(0);
        expect(ready.firstUserVerified).toBe(false); expect(ready.answerComplete).toBe(false);
        expect(ready.text).toBe(''); expect(f.mutations()).toBe(0);
      }
    });

    test(`${provider.name}: absent root controls stay pending without actions or a new timer`, async () => {
      const f: any = provider.make(); f.scope.detach();
      if (provider.name === 'qwen') f.trigger.detach();
      for (let index = 0; index < 4; index++) expect(await f.run('inspect')).toEqual(pending);
      expect(f.mutations()).toBe(0); expect(f.editor.events).toHaveLength(0);
    });

    test(`${provider.name}: initial duplicate, hidden, drafted or authored pages reject instead of waiting`, async () => {
      for (const kind of ['duplicate', 'hidden', 'draft', 'authored', 'scope']) {
        const f: any = provider.make();
        // Leave another control unmounted, so invalid present structure cannot
        // be masked by a blanket initial-loading response.
        f[provider.missing].detach();
        if (kind === 'duplicate') f.scope.append(f.editor.cloneNode(true));
        if (kind === 'hidden') f.editor.values.hidden = '';
        if (kind === 'draft') f.editor.value = 'Foreign unsent draft';
        if (kind === 'authored') f.body.append(new f.Node('DIV', { class: provider.name === 'qwen' ? 'qwen-chat-message' : 'ds-message' }));
        if (kind === 'scope') f.body.append(f.editor); // Retain the exact editor, but remove its supported ancestry.
        const failed = await f.run('inspect');
        expect(failed.error).toBeDefined(); expect(failed.pending).toBeUndefined();
        expect((await f.run('inspect')).detail).toBe('terminal_operation'); expect(f.mutations()).toBe(0);
      }
    });

    test(`${provider.name}: controls already observed during loading cannot disappear or be replaced`, async () => {
      for (const change of ['disappear', 'replace']) {
        const f: any = provider.make(); f[provider.missing].detach();
        expect(await f.run('inspect')).toEqual(pending);
        const node = f[provider.bound], parent = node.parentElement;
        node.detach(); if (change === 'replace') parent.append(node.cloneNode(true));
        const failed = await f.run('inspect');
        expect(failed.error).toBe('document_changed'); expect(failed.pending).toBeUndefined();
        expect((await f.run('inspect')).detail).toBe('terminal_operation'); expect(f.mutations()).toBe(0);
      }
    });

    test(`${provider.name}: successful first read permanently closes the loading gate`, async () => {
      const f: any = provider.make(); expect((await f.run('inspect')).composer).toBe(true);
      const node = f[provider.missing], parent = node.parentElement; node.detach();
      const failed = await f.run('inspect'); expect(failed.error).toBeDefined(); expect(failed.pending).toBeUndefined();
      parent.append(node); expect((await f.run('inspect')).detail).toBe('terminal_operation'); expect(f.mutations()).toBe(0);
    });

    test(`${provider.name}: a selection claim cannot reset to initial loading`, async () => {
      const f: any = provider.make();
      const choiceKey = provider.name === 'qwen' ? 'modelChoice' : 'modeChoice';
      const selected = await f.run(provider.selector, { [choiceKey]: provider.choice });
      expect(selected.error).toBeUndefined(); expect(f.mutations()).toBeGreaterThan(0);
      const before = f.mutations(); f.editor.detach();
      const failed = await f.run('inspect'); expect(failed.error).toBeDefined(); expect(failed.pending).toBeUndefined();
      expect((await f.run('inspect')).detail).toBe('terminal_operation'); expect(f.mutations()).toBe(before);
    });

    test(`${provider.name}: initial waiting never authorizes cleanup, selection, or changed bindings`, async () => {
      for (const kind of ['cleanup', 'selection', 'owner', 'generation', 'route']) {
        const f: any = provider.make(); f.editor.detach();
        expect(await f.run('inspect')).toEqual(pending);
        let action = 'inspect', overrides: any = {};
        if (kind === 'cleanup') overrides.savedCleanupInspection = true;
        if (kind === 'selection') { action = provider.selector; overrides[provider.name === 'qwen' ? 'modelChoice' : 'modeChoice'] = provider.choice; }
        if (kind === 'owner') overrides.ownerToken = generation;
        if (kind === 'generation') overrides.documentGeneration = ownerToken;
        if (kind === 'route') f.document.URL += 'foreign';
        const failed = await f.run(action, overrides); expect(failed.error).toBeDefined(); expect(failed.pending).toBeUndefined();
        expect(f.mutations()).toBe(0);
      }
    });
  }

  test('Qwen initial readiness does not require Send in its observed empty composer', async () => {
    const f = qwen(); expect(f.send.parentElement).toBeNull();
    const result = await f.run('inspect'); expect(result.composer).toBe(true); expect(result.pending).toBeUndefined(); expect(f.mutations()).toBe(0);
  });

  test('DeepSeek Search on is valid initial state and discovery never toggles it', async () => {
    const f = deepseek({ fresh: true }); f.setMode(false, true);
    const ready = await f.run('inspect'); expect(ready.composer).toBe(true); expect(ready.modeEvidence).toBeNull();
    const modes = await f.run('discoverModes'); expect(modes.modeChoices).toEqual([{ key: 'chat', label: 'Chat' }, { key: 'deepthink', label: 'DeepThink' }]);
    expect(f.search.getAttribute('aria-pressed')).toBe('true'); expect(f.mutations()).toBe(0);
  });

  test('malformed present selection controls cannot hide behind another missing control', async () => {
    for (const kind of ['label', 'expanded']) {
      const f = qwen(); f.editor.detach();
      if (kind === 'label') f.modelName.append(new f.Node('SPAN', {}, 'unexpected'));
      if (kind === 'expanded') f.trigger.values['aria-expanded'] = 'true';
      expect((await f.run('inspect')).error).toBe('model_unverified'); expect(f.mutations()).toBe(0);
    }
    for (const kind of ['third', 'label', 'pressed', 'selected', 'hidden']) {
      const f = deepseek({ fresh: true }); f.send.detach();
      if (kind === 'third') f.scope.append(f.search.cloneNode(true));
      if (kind === 'label') f.search.children[0].text = 'Unknown';
      if (kind === 'pressed') f.search.values['aria-pressed'] = 'maybe';
      if (kind === 'selected') f.search.values['aria-pressed'] = 'true';
      if (kind === 'hidden') f.search.values.hidden = '';
      expect((await f.run('inspect')).error).toBeDefined(); expect(f.mutations()).toBe(0);
    }
  });

  test('provider-specific attribute changes wake initial reads without actions or stale-owner signals', async () => {
    for (const item of [
      { make: qwen, key: 'trigger', attribute: 'role', value: 'button' },
      { make: () => deepseek({ fresh: true }), key: 'editor', attribute: 'placeholder', value: 'Message DeepSeek' },
      { make: () => deepseek({ fresh: true }), key: 'send', attribute: 'role', value: 'button' }
    ]) {
      const f: any = item.make(), node = f[item.key]; delete node.values[item.attribute];
      expect(await f.run('inspect')).toEqual(pending);
      expect(f.observers).toHaveLength(1); expect(f.observers[0].options.attributeFilter).toContain(item.attribute);
      node.values[item.attribute] = item.value; f.notifyAttribute(item.attribute);
      expect(f.signals).toEqual([{ ownerToken, kind: 'dom_changed' }]);
      expect((await f.run('inspect')).composer).toBe(true); expect(f.mutations()).toBe(0);
      f.world.__computaModelOwner = generation; f.notifyAttribute(item.attribute); expect(f.signals).toHaveLength(1);
    }
  });
});
