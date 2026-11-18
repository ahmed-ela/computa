import { describe, expect, test } from 'bun:test';
import { fixture, choice, generation } from './embedded-qwen-adapter-fixture';

type Fixture = ReturnType<typeof fixture>;
type Order = 'ariaFirst' | 'domFirst';

async function closing(order: Order) {
  const f = fixture();
  expect((await f.run('discoverModels')).pending).toBe(true);
  f.trigger.onClick = () => {
    if (order === 'ariaFirst') f.trigger.setAttribute('aria-expanded', 'false');
    else f.modelMenu.setAttribute('hidden', '');
  };
  return f;
}
function finish(f: Fixture) {
  f.trigger.setAttribute('aria-expanded', 'false'); f.modelMenu.setAttribute('hidden', '');
}
function assertPending(result: any) {
  expect(result.error).toBeUndefined(); expect(result.pending).toBe(true);
  expect(result.selected).toBeUndefined(); expect(result.modelEvidence).toBeNull();
}

describe('Qwen claimed picker close observation', () => {
  test('ARIA-first and DOM-first closes stay pending until both channels close without another click', async () => {
    for (const order of ['ariaFirst', 'domFirst'] as const) {
      const f = await closing(order);
      assertPending(await f.run('discoverModels'));
      for (let i = 0; i < 3; i++) assertPending(await f.run('discoverModels'));
      expect(f.trigger.clicks).toBe(2); expect(f.choices.every(node => node.clicks === 0)).toBe(true);
      finish(f);
      const result = await f.run('discoverModels');
      expect(result.selected).toBe(true); expect(result.modelEvidence.selected).toEqual(choice());
      expect(result.modelChoices.map((item: any) => item.label)).toEqual(['Qwen3.7-Plus', 'Qwen3.8-Max', 'Qwen3.8-Omni-Flash']);
      expect((await f.run('discoverModels')).selected).toBe(true);
      expect(f.trigger.clicks).toBe(2); expect(f.send.clicks).toBe(0); expect(f.editor.events.length).toBe(0);
    }
  });

  test('an explicit different-model selection still verifies its checked row before the delayed final close', async () => {
    const f = fixture(), wanted = choice('Qwen3.8-Max');
    expect((await f.run('selectModel', { modelChoice: wanted })).pending).toBe(true);
    expect((await f.run('selectModel', { modelChoice: wanted })).pending).toBe(true);
    expect(f.choices[1].clicks).toBe(1);
    expect((await f.run('selectModel', { modelChoice: wanted })).pending).toBe(true); // Reopen to verify.
    f.trigger.onClick = () => f.trigger.setAttribute('aria-expanded', 'false');
    assertPending(await f.run('selectModel', { modelChoice: wanted }));
    assertPending(await f.run('selectModel', { modelChoice: wanted }));
    finish(f);
    expect((await f.run('selectModel', { modelChoice: wanted })).modelEvidence.selected).toEqual(wanted);
    expect(f.trigger.clicks).toBe(3); expect(f.choices[1].clicks).toBe(1); expect(f.send.clicks).toBe(0);
  });

  test('visible closing menu keeps exact physical menu and checked row plus the verified choice list', async () => {
    const cases: [string, (f: Fixture) => void][] = [
      ['menu', f => { const copy = f.modelMenu.cloneNode(true); f.modelMenu.detach(); f.body.append(copy); }],
      ['checked row', f => { const copy = f.choices[0].cloneNode(true); f.choices[0].detach(); f.modelMenu.append(copy); }],
      ['label', f => { f.modelName.text = 'Qwen3.8-Max'; }],
      ['choice list', f => { f.choices[2].children[0].text = 'Unexpected synthetic model'; }],
      ['selection', f => { f.choices[0].setAttribute('aria-selected', 'false'); f.choices[0].setAttribute('class', 'wms-list__item');
        f.choices[1].setAttribute('aria-selected', 'true'); f.choices[1].setAttribute('class', 'wms-list__item wms-list__item--selected'); f.modelName.text = 'Qwen3.8-Max'; }],
    ];
    for (const [name, mutate] of cases) {
      const f = await closing('ariaFirst'); assertPending(await f.run('discoverModels')); mutate(f);
      const result = await f.run('discoverModels'); expect(result.error, name).toBeDefined(); expect(result.selected).toBeUndefined();
      expect((await f.run('discoverModels')).detail, name).toBe('terminal_operation');
      expect(f.trigger.clicks, name).toBe(2); expect(f.send.clicks, name).toBe(0);
    }
  });

  test('close observation never changes an owner, generation, route or selected target binding', async () => {
    const cases: [string, (f: Fixture) => Record<string, unknown>][] = [
      ['owner', f => { f.world.__computaModelOwner = '44444444-1111-4111-8111-111111111111'; return {}; }],
      ['generation', () => ({ documentGeneration: generation.replace('7d90', '8d90') })],
      ['route', f => { f.document.URL = 'https://chat.qwen.ai/c/11111111-abcd-4333-8444-555555555555'; return {}; }],
    ];
    for (const [name, mutate] of cases) {
      const f = await closing('ariaFirst'); assertPending(await f.run('discoverModels'));
      const result = await f.run('discoverModels', mutate(f));
      expect(result.error, name).toBeDefined(); expect(result.selected).toBeUndefined();
      expect(f.trigger.clicks, name).toBe(2); expect(f.send.clicks, name).toBe(0);
    }
    const f = await closing('ariaFirst'); assertPending(await f.run('discoverModels'));
    expect((await f.run('selectModel', { modelChoice: choice() })).error).toBe('model_mismatch');
    expect(f.trigger.clicks).toBe(2);
  });

  test('a thrown close callback cannot be observed as success or clicked again', async () => {
    const f = await closing('ariaFirst');
    f.trigger.onClick = () => { f.trigger.setAttribute('aria-expanded', 'false'); throw new Error('Synthetic lost close callback'); };
    expect((await f.run('discoverModels')).error).toBeDefined();
    finish(f); expect((await f.run('discoverModels')).detail).toBe('terminal_operation');
    expect(f.trigger.clicks).toBe(2); expect(f.send.clicks).toBe(0);
  });

  test('a split menu without a claimed final close still fails before new input', async () => {
    for (const claimedOpen of [false, true]) {
      for (const order of ['ariaFirst', 'domFirst'] as const) {
        const f = fixture(); if (claimedOpen) await f.run('discoverModels');
        if (order === 'ariaFirst') { f.modelMenu.removeAttribute('hidden'); f.trigger.setAttribute('aria-expanded', 'false'); }
        else { f.modelMenu.setAttribute('hidden', ''); f.trigger.setAttribute('aria-expanded', 'true'); }
        const result = await f.run('discoverModels');
        expect(result).toEqual({ error: 'model_unverified', detail: order === 'ariaFirst' ? 'picker_menu_collapsed' : 'picker_menu_missing' });
        expect(f.trigger.clicks).toBe(claimedOpen ? 1 : 0); expect(f.send.clicks).toBe(0);
      }
    }
  });
});
