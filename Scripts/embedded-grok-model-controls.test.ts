import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { Element } from './embedded-provider-adapter-fixture';

const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
const controls = readFileSync(new URL('./embedded-grok-model-controls.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const execute = new AsyncFunction('input', 'document', 'window', 'location', 'getComputedStyle', 'MutationObserver', 'globalThis', 'crypto',
  core + '\n' + controls + `\ntry {
    const c = computaProviderCore(input, 'grok', 'https://grok.com', ['discoverModels','selectModel','verifyModel']);
    const state = globalThis.fixtureState ||= {};
    const model = computaGrokModelControls(c, state, c.assertContext);
    return input.action === 'verifyModel' ? { modelEvidence: model.evidence() } : model.step(input.action, input.modelChoice);
  } catch (e) { if (e?.computaAdapterFailure) return { error: e.error, detail: e.detail }; throw e; }`);

function fixture() {
  let hit: any, blocked: Element | null = null;
  class Node extends Element {
    rect = { left: 0, top: 0, width: 80, height: 24 };
    hasAttribute(name: string) { return Object.hasOwn(this.values, name); }
    getBoundingClientRect() { hit = this; return { ...this.rect }; }
  }
  const body = new Node('BODY'), html = new Node('HTML'); html.append(body);
  const trigger = new Node('BUTTON', { id: 'model-select-trigger', 'aria-haspopup': 'menu', 'aria-expanded': 'false', 'aria-label': 'Model: Fast' });
  const menu = new Node('DIV', { role: 'menu', 'aria-labelledby': 'model-select-trigger', hidden: '' });
  const options = ['Fast', 'Build', 'Auto', 'Expert', 'Heavy'].map(label => {
    const row = new Node('DIV', { role: 'menuitemcheckbox', 'aria-checked': label === 'Fast' ? 'true' : 'false',
      ...(label === 'Build' ? { 'aria-disabled': 'true', 'data-disabled': '' } : {}) }, label);
    row.onClick = () => {
      trigger.values['aria-label'] = 'Model: ' + label;
      options.forEach(other => { other.values['aria-checked'] = other === row ? 'true' : 'false'; });
      trigger.values['aria-expanded'] = 'false'; menu.values.hidden = '';
    };
    return row;
  });
  menu.append(...options, new Node('DIV', { role: 'menuitem' }, 'Get 50% off Premium Unlock extended capabilities Claim offer'));
  body.append(trigger, menu);
  trigger.onClick = () => { trigger.values['aria-expanded'] = 'true'; delete menu.values.hidden; };
  const world: any = {}, document = { URL: 'https://grok.com/', documentElement: html, body,
    querySelectorAll: (selector: string) => html.querySelectorAll(selector), elementFromPoint: () => hit === blocked ? body : hit };
  const window: any = { innerWidth: 800, innerHeight: 600 }; window.top = window;
  const run = (action = 'discoverModels', modelChoice?: unknown, overrides = {}) => execute({ provider: 'grok', action,
    ownerToken: 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30', documentGeneration: 'b60fcab5-e5a2-4f6b-a03f-650ee9a714a2',
    expectedURL: document.URL, bindOwner: true, modelChoice, ...overrides }, document, window, { origin: 'https://grok.com' },
    (node: Node) => ({ visibility: 'visible', display: node.closest('[hidden]') ? 'none' : 'block' }),
    class { observe() {} disconnect() {} }, world, crypto);
  const finish = async (action = 'discoverModels', choice?: unknown) => {
    let result;
    for (let step = 0; step < 5; step++) { result = await run(action, choice); if (!result.pending) return result; }
    return result;
  };
  return { Node, body, trigger, menu, options, world, document, run, finish,
    blockHit: (node: Element | null) => { blocked = node; } };
}

describe('Grok observed model controls', () => {
  test('fixed model guard diagnostics distinguish malformed controls without actions', async () => {
    const cases: [string, (f: ReturnType<typeof fixture>) => void][] = [
      ['model_trigger_missing', f => { f.body.children = [f.menu]; }],
      ['model_trigger_hidden', f => { f.trigger.values.hidden = ''; }],
      ['model_trigger_ambiguous', f => { f.body.append(f.trigger.cloneNode(true)); }],
      ['model_trigger_shape', f => { f.trigger.values['aria-haspopup'] = 'dialog'; }],
      ['model_trigger_label', f => { f.trigger.values['aria-label'] = 'Private page text'; }],
      ['model_trigger_choice', f => { f.trigger.values['aria-label'] = 'Model: '; }],
      ['model_menu_ambiguous', f => { delete f.menu.values.hidden; f.trigger.values['aria-expanded'] = 'true'; f.body.append(f.menu.cloneNode(true)); }],
      ['model_menu_authored', f => { delete f.menu.values.hidden; f.trigger.values['aria-expanded'] = 'true'; f.menu.values['data-testid'] = 'assistant-message'; }],
      ['model_expansion_invalid', f => { f.trigger.values['aria-expanded'] = 'unknown'; }],
      ['model_collapsed_menu_present', f => { delete f.menu.values.hidden; }],
      ['model_open_not_closed', f => { delete f.menu.values.hidden; f.trigger.values['aria-expanded'] = 'true'; }],
    ];
    for (const [detail, alter] of cases) {
      const f = fixture(); alter(f);
      expect(await f.run()).toEqual({ error: 'model_unverified', detail });
      expect(f.trigger.clicks).toBe(0); expect(f.options.every(row => row.clicks === 0)).toBe(true);
    }
  });

  test('open and option hit failures retain their exact phase and never dispatch the blocked click', async () => {
    const cases: [string, (f: ReturnType<typeof fixture>, node: ReturnType<typeof fixture>['trigger']) => void][] = [
      ['disabled', (_f, node) => { node.disabled = true; }],
      ['invalid_geometry', (_f, node) => { node.rect.width = 0; }],
      ['outside_viewport', (_f, node) => { node.rect.left = -200; }],
      ['occluded', (f, node) => { f.blockHit(node); }],
    ];
    for (const phase of ['open', 'option']) {
      for (const [reason, alter] of cases) {
        const f = fixture();
        if (phase === 'option') expect(await f.run('selectModel', { key: 'Expert', label: 'Expert' })).toEqual({ pending: true });
        const node = phase === 'open' ? f.trigger : f.options[3]; alter(f, node);
        // Disabled choices are excluded before target selection; they never
        // reach the hit test, while geometry/occlusion failures do.
        const expected = phase === 'option' && reason === 'disabled'
          ? { error: 'model_unavailable', detail: 'model_target_count' }
          : { error: 'model_unverified', detail: `model_${phase}_hit_${reason}` };
        expect(await f.run('selectModel', { key: 'Expert', label: 'Expert' })).toEqual(expected);
        expect(f.trigger.clicks).toBe(phase === 'open' ? 0 : 1);
        expect(f.options.every(row => row.clicks === 0)).toBe(true);
      }
    }
  });

  test('menu row and checked-state failures keep fixed reasons after the single open', async () => {
    const cases: [string, (f: ReturnType<typeof fixture>) => void][] = [
      ['model_rows_empty', f => { f.menu.children = []; }],
      ['model_row_choice', f => { f.options[4].text = ''; }],
      ['model_row_checked', f => { f.options[4].values['aria-checked'] = 'unknown'; }],
      ['model_row_authored', f => { f.options[4].values['data-testid'] = 'assistant-message'; }],
      ['model_rows_duplicate', f => { f.options[4].text = 'Expert'; }],
      ['model_checked_count', f => { f.options[0].values['aria-checked'] = 'false'; }],
      ['model_checked_disabled', f => { f.options[0].disabled = true; }],
      ['model_checked_label', f => { f.trigger.values['aria-label'] = 'Model: Expert'; }],
      ['model_enabled_count', f => { for (let i = 0; i < 33; i++) f.menu.append(new f.Node('DIV', { role: 'menuitemcheckbox', 'aria-checked': 'false' }, 'Fixture ' + i)); }],
      ['model_trigger_replaced', f => { f.body.children[0] = f.trigger.cloneNode(true); }],
    ];
    for (const [detail, alter] of cases) {
      const f = fixture(); expect(await f.run()).toEqual({ pending: true }); alter(f);
      expect(await f.run()).toEqual({ error: 'model_unverified', detail });
      expect(f.trigger.clicks).toBe(1); expect(f.options.every(row => row.clicks === 0)).toBe(true);
    }
  });

  test('changed selection operations and completed selection pins report fixed mismatch details', async () => {
    const f = fixture(); expect(await f.run()).toEqual({ pending: true });
    expect(await f.run('selectModel', { key: 'Fast', label: 'Fast' })).toEqual({ error: 'model_unverified', detail: 'model_operation_changed' });
    expect(f.options.every(row => row.clicks === 0)).toBe(true);
    const done = fixture(); await done.finish('selectModel', { key: 'Expert', label: 'Expert' });
    done.trigger.values['aria-label'] = 'Model: Fast';
    expect(await done.run('verifyModel')).toEqual({ error: 'model_mismatch', detail: 'model_pinned_changed' });
  });

  test('the exact owned closing menu is pending until it disappears, without another click or model evidence', async () => {
    for (const action of ['discoverModels', 'selectModel']) {
      const f = fixture(), choice = { key: 'Fast', label: 'Fast' };
      f.options[0].onClick = () => {
        f.trigger.values['aria-expanded'] = 'false';
        f.menu.values['data-closed'] = ''; f.menu.values['data-ending-style'] = '';
        delete f.menu.values['data-open'];
      };
      expect(await f.run(action, choice)).toEqual({ pending: true });
      expect(await f.run(action, choice)).toEqual({ pending: true });
      for (let read = 0; read < 3; read++) {
        expect(await f.run('verifyModel')).toEqual({ modelEvidence: null });
        expect(await f.run(action, choice)).toEqual({ pending: true });
      }
      expect(f.trigger.clicks).toBe(1); expect(f.options[0].clicks).toBe(1);
      f.body.children = f.body.children.filter(node => node !== f.menu);
      expect(await f.run(action, choice)).toMatchObject({ modelEvidence: { selected: choice } });
      expect(f.trigger.clicks).toBe(1); expect(f.options[0].clicks).toBe(1);
    }
  });

  test('unclaimed, replaced or inconsistent closing menus cannot use the transition wait', async () => {
    const cases: [string, (f: ReturnType<typeof fixture>) => void][] = [
      ['model_closing_trigger_replaced', f => { f.body.children[0] = f.trigger.cloneNode(true); }],
      ['model_closing_menu_replaced', f => { f.body.children[1] = f.menu.cloneNode(true); }],
      ['model_closing_shape', f => { delete f.menu.values['data-closed']; }],
      ['model_closing_shape', f => { f.menu.values['data-ending-style'] = 'unobserved'; }],
      ['model_closing_shape', f => { f.menu.values['data-open'] = ''; }],
      ['model_closing_selection_changed', f => { f.trigger.values['aria-label'] = 'Model: Heavy'; }],
    ];
    for (const [detail, alter] of cases) {
      const f = fixture();
      f.options[0].onClick = () => {
        f.trigger.values['aria-expanded'] = 'false';
        f.menu.values['data-closed'] = ''; f.menu.values['data-ending-style'] = '';
      };
      expect(await f.run()).toEqual({ pending: true }); expect(await f.run()).toEqual({ pending: true });
      alter(f);
      expect(await f.run()).toEqual({ error: detail.endsWith('selection_changed') ? 'model_mismatch' : 'model_unverified', detail });
      expect(f.trigger.clicks).toBe(1); expect(f.options[0].clicks).toBe(1);
    }
    const unowned = fixture(); delete unowned.menu.values.hidden;
    unowned.menu.values['data-closed'] = ''; unowned.menu.values['data-ending-style'] = '';
    expect(await unowned.run()).toEqual({ error: 'model_unverified', detail: 'model_collapsed_menu_present' });
    expect(unowned.trigger.clicks).toBe(0); expect(unowned.options[0].clicks).toBe(0);
    const removed = fixture(); await removed.run(); await removed.run();
    removed.body.children = [removed.trigger.cloneNode(true)];
    expect(await removed.run()).toEqual({ error: 'model_unverified', detail: 'model_closing_trigger_replaced' });
    expect(removed.trigger.clicks).toBe(1); expect(removed.options[0].clicks).toBe(1);
  });

  test('discovers enabled checked-menu choices, closes on the same checked row, and excludes promotions', async () => {
    const f = fixture(), observed = await f.finish();
    expect(observed.modelChoices).toEqual(['Fast', 'Auto', 'Expert', 'Heavy'].map(label => ({ key: label, label })));
    expect(observed.modelEvidence).toEqual({ selected: { key: 'Fast', label: 'Fast' }, verification: 'website_selection', source: 'selected_model_indicator' });
    expect(f.trigger.clicks).toBe(1); expect(f.options.map(option => option.clicks)).toEqual([1, 0, 0, 0, 0]);
    expect(f.trigger.values['aria-expanded']).toBe('false');
  });

  test('selects an exact enabled website choice without treating another label as an alias', async () => {
    const f = fixture(), choice = { key: 'Expert', label: 'Expert' };
    const result = await f.finish('selectModel', choice);
    expect(result.selected).toBe(true); expect(result.modelEvidence.selected).toEqual(choice);
    expect(f.options[3].clicks).toBe(1);
    f.trigger.values['aria-label'] = 'Model: Heavy';
    expect(await f.run('verifyModel')).toMatchObject({ error: 'model_mismatch' });
  });

  test('new observed labels are discovered without a model-name seed', async () => {
    const f = fixture();
    f.options[4].text = 'Future Family (fixture)';
    const result = await f.finish();
    expect(result.modelChoices.at(-1)).toEqual({ key: 'Future Family (fixture)', label: 'Future Family (fixture)' });
  });

  test('disabled, missing, differently keyed and duplicate choices never click a replacement', async () => {
    for (const choice of [{ key: 'Build', label: 'Build' }, { key: 'Missing', label: 'Missing' }, { key: 'other', label: 'Expert' }]) {
      const f = fixture();
      expect(await f.finish('selectModel', choice)).toMatchObject({ error: 'model_unavailable' });
      expect(f.options.every(row => row.clicks === 0)).toBe(true);
    }
    const f = fixture(); f.options[4].text = 'Expert';
    expect(await f.finish()).toMatchObject({ error: 'model_unverified' });
  });

  test('wrong associations, ambiguous triggers, authored menus and checked-label contradictions fail closed', async () => {
    const scenarios = [
      (f: ReturnType<typeof fixture>) => { f.menu.values['aria-labelledby'] = 'other-trigger'; },
      (f: ReturnType<typeof fixture>) => { f.body.append(f.trigger.cloneNode(true)); },
      (f: ReturnType<typeof fixture>) => { f.body.values['data-testid'] = 'assistant-message'; },
      (f: ReturnType<typeof fixture>) => { f.options[1].values['aria-checked'] = 'true'; },
      (f: ReturnType<typeof fixture>) => { f.trigger.values['aria-label'] = 'Model: Expert'; },
    ];
    for (const alter of scenarios) {
      const f = fixture(); alter(f);
      const result = await f.finish();
      expect(Boolean(result.error) || result.pending === true).toBe(true);
      expect(f.options.every(row => row.clicks === 0)).toBe(true);
    }
  });

  test('uncertain menu-open and row-click acknowledgements are never replayed', async () => {
    const opening = fixture(); opening.trigger.onClick = () => {};
    expect(await opening.finish()).toEqual({ pending: true }); expect(opening.trigger.clicks).toBe(1);
    const selecting = fixture(); selecting.options[0].onClick = () => {};
    expect(await selecting.finish()).toEqual({ pending: true }); expect(selecting.options[0].clicks).toBe(1);
  });

  test('a header alone cannot prove undiscovered model selection or cross-provider ownership', async () => {
    const f = fixture(); expect(await f.run('verifyModel')).toEqual({ modelEvidence: null });
    expect(await f.run('discoverModels', undefined, { provider: 'groq' })).toMatchObject({ error: 'document_changed' });
    expect(f.trigger.clicks).toBe(0);
  });
});
