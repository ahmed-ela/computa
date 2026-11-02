import { describe, expect, test } from 'bun:test';
import { fixture, generation, ownerToken } from './embedded-qwen-adapter-fixture';

const pending = { pending: true, sessionLifecycle: 'saved_conversation_delete', temporary: false, composer: false };

describe('Qwen pre-claim hit readiness', () => {
  test('a simulated delayed overlay keeps initial reads pending until its observed change', async () => {
    const f = fixture(); f.occlude(f.trigger);
    for (let i = 0; i < 3; i++) expect(await f.run('inspect')).toEqual(pending);
    expect(f.mutations()).toBe(0); expect(f.send.clicks).toBe(0); expect(f.trigger.clicks).toBe(0);
    expect(f.observers).toHaveLength(1); expect(f.observers[0].options.attributeFilter).toContain('hidden');
    f.occlude(f.send); // The same picker point is now uncovered; no action is issued.
    f.notifyAttribute('hidden');
    expect(f.signals).toEqual([{ ownerToken, kind: 'dom_changed' }]);
    const ready = await f.run('inspect');
    expect(ready.pending).toBeUndefined(); expect(ready.error).toBeUndefined(); expect(ready.composer).toBe(true);
    expect(f.mutations()).toBe(0);
    expect((await f.run('discoverModels')).pending).toBe(true);
    expect(f.trigger.clicks).toBe(1); expect(f.send.clicks).toBe(0);
  });

  test('the retained picker, label and editor cannot be replaced while the initial hit is blocked', async () => {
    for (const key of ['trigger', 'modelName', 'editor'] as const) {
      const f = fixture(); f.occlude(f.trigger); expect(await f.run('inspect')).toEqual(pending);
      const node = f[key], parent = node.parentElement!; node.detach(); parent.append(node.cloneNode(true));
      f.occlude(f.send); f.notifyAttribute('hidden');
      const result = await f.run('inspect');
      expect(result.error).toBe('document_changed'); expect(result.pending).toBeUndefined();
      expect((await f.run('inspect')).detail).toBe('terminal_operation');
      expect(f.mutations()).toBe(0); expect(f.send.clicks).toBe(0);
    }
  });

  test('an occluded initial wait never accepts a changed owner, generation, route or nonempty draft', async () => {
    for (const change of ['owner', 'generation', 'route', 'draft']) {
      const f = fixture(); f.occlude(f.trigger); expect(await f.run('inspect')).toEqual(pending);
      const extra: Record<string, unknown> = {};
      if (change === 'owner') extra.ownerToken = generation;
      if (change === 'generation') extra.documentGeneration = ownerToken;
      if (change === 'route') f.document.URL += 'foreign';
      if (change === 'draft') f.editor.value = 'Foreign draft';
      expect((await f.run('inspect', extra)).error).toBeDefined(); expect(f.mutations()).toBe(0);
    }
  });

  test('occlusion introduced after initial readiness still fails the immediate action check', async () => {
    const f = fixture(); expect((await f.run('inspect')).composer).toBe(true);
    f.occlude(f.trigger);
    expect(await f.run('discoverModels')).toEqual({ error: 'model_unverified', detail: 'picker_open_occluded' });
    expect(f.trigger.clicks).toBe(0); expect(f.send.clicks).toBe(0);
  });
});
