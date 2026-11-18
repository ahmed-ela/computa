import { describe, expect, test } from 'bun:test';
import { fixture, choice } from './embedded-qwen-adapter-fixture';

type Fixture = ReturnType<typeof fixture>;

describe('Qwen finite discovery failure diagnostics', () => {
  test('initial inspect distinguishes closed-picker and initial-label failures without page prose', async () => {
    const cases: [string, (f: Fixture) => void][] = [
      ['initial_picker_not_closed', f => f.trigger.setAttribute('aria-expanded', 'true')],
      ['initial_model_label', f => f.modelName.text = ''],
      ['initial_menu_present', f => f.modelMenu.removeAttribute('hidden')],
    ];
    for (const [detail, mutate] of cases) {
      const f = fixture(); mutate(f);
      expect(await f.run('inspect')).toEqual({ error: 'model_unverified', detail });
      expect(f.mutations()).toBe(0);
    }
  });

  test('picker state failures identify the existing failed check and preserve zero clicks', async () => {
    const cases: [string, (f: Fixture) => void][] = [
      ['picker_expanded_invalid', f => f.trigger.setAttribute('aria-expanded', 'PRIVATE_ATTRIBUTE_CANARY')],
      ['picker_menu_shape', f => { f.openPicker(); f.modelMenu.setAttribute('aria-label', 'PRIVATE_MENU_CANARY'); }],
      ['picker_menu_collapsed', f => f.modelMenu.removeAttribute('hidden')],
      ['picker_menu_missing', f => f.trigger.setAttribute('aria-expanded', 'true')],
      ['picker_not_closed', f => f.openPicker()],
    ];
    for (const [detail, mutate] of cases) {
      const f = fixture(); mutate(f);
      expect(await f.run('discoverModels')).toEqual({ error: 'model_unverified', detail });
      expect(f.mutations()).toBe(0);
    }
  });

  test('model-row failures retain strict validation after the single menu-open claim', async () => {
    const cases: [string, (f: Fixture) => void][] = [
      ['model_choice_invalid', f => f.choices[0].children[0].text = ''],
      ['model_option_disabled', f => f.choices[1].disabled = true],
      ['model_selected_invalid', f => f.choices[0].setAttribute('aria-selected', 'PRIVATE_SELECTED_CANARY')],
      ['model_selected_contradiction', f => f.choices[1].setAttribute('aria-selected', 'true')],
      ['model_choices_empty', f => f.modelMenu.replaceChildren()],
      ['model_choices_duplicate', f => f.choices[1].children[0].text = f.choices[0].children[0].text],
      ['model_checked_count', f => { f.choices[0].setAttribute('aria-selected', 'false'); f.choices[0].setAttribute('class', 'wms-list__item'); }],
      ['picker_selected_label', f => f.modelName.text = 'PRIVATE_LABEL_CANARY'],
    ];
    for (const [detail, mutate] of cases) {
      const f = fixture(); expect((await f.run('discoverModels')).pending).toBe(true); mutate(f);
      const result = await f.run('discoverModels');
      expect(result).toEqual({ error: 'model_unverified', detail });
      expect(JSON.stringify(result)).not.toContain('PRIVATE_');
      expect(f.trigger.clicks).toBe(1); expect(f.choices.every(row => row.clicks === 0)).toBe(true);
      expect(f.send.clicks).toBe(0);
      expect((await f.run('discoverModels')).detail).toBe('terminal_operation');
      expect(f.trigger.clicks).toBe(1);
    }
  });

  test('hit diagnostics name the claimed stage without retrying or bypassing occlusion', async () => {
    const opening = fixture(); opening.occlude(opening.trigger);
    expect(await opening.run('discoverModels')).toEqual({ error: 'model_unverified', detail: 'picker_open_occluded' });
    expect(opening.trigger.clicks).toBe(0);

    const closing = fixture(); await closing.run('discoverModels'); closing.occlude(closing.trigger);
    expect(await closing.run('discoverModels')).toEqual({ error: 'model_unverified', detail: 'picker_close_occluded' });
    expect(closing.trigger.clicks).toBe(1);
    expect((await closing.run('discoverModels')).detail).toBe('terminal_operation');
    expect(closing.trigger.clicks).toBe(1);

    const option = fixture(); await option.run('selectModel', { modelChoice: choice('Qwen3.8-Max') }); option.occlude(option.choices[1]);
    expect(await option.run('selectModel', { modelChoice: choice('Qwen3.8-Max') }))
      .toEqual({ error: 'model_unverified', detail: 'model_option_occluded' });
    expect(option.choices[1].clicks).toBe(0);

    const verifying = fixture(); await verifying.run('selectModel', { modelChoice: choice('Qwen3.8-Max') });
    await verifying.run('selectModel', { modelChoice: choice('Qwen3.8-Max') }); verifying.occlude(verifying.trigger);
    expect(await verifying.run('selectModel', { modelChoice: choice('Qwen3.8-Max') }))
      .toEqual({ error: 'model_unverified', detail: 'picker_verify_occluded' });
    expect(verifying.trigger.clicks).toBe(1); expect(verifying.choices[1].clicks).toBe(1);
    for (const f of [opening, closing, option, verifying]) expect(f.send.clicks).toBe(0);
  });

  test('a replaced menu and changed selection target remain terminal binding failures', async () => {
    const replaced = fixture(); await replaced.run('selectModel', { modelChoice: choice('Qwen3.8-Max') });
    replaced.choices[1].onClick = () => {}; // Lost selection, menu remains open after the one claimed click.
    await replaced.run('selectModel', { modelChoice: choice('Qwen3.8-Max') });
    const copy = replaced.modelMenu.cloneNode(true); replaced.modelMenu.detach(); replaced.body.append(copy);
    expect(await replaced.run('selectModel', { modelChoice: choice('Qwen3.8-Max') }))
      .toEqual({ error: 'model_unverified', detail: 'picker_menu_replaced' });
    expect(replaced.choices[1].clicks).toBe(1);

    const changed = fixture(); await changed.run('selectModel', { modelChoice: choice('Qwen3.8-Max') });
    expect(await changed.run('selectModel', { modelChoice: choice('Qwen3.7-Plus') }))
      .toEqual({ error: 'model_mismatch', detail: 'selection_target' });
    expect(changed.trigger.clicks).toBe(1); expect(changed.send.clicks).toBe(0);
  });
});
