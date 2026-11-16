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
  let hit: any;
  class Node extends Element {
    hasAttribute(name: string) { return Object.hasOwn(this.values, name); }
    getBoundingClientRect() { hit = this; return { left: 0, top: 0, width: 80, height: 24 }; }
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
    querySelectorAll: (selector: string) => html.querySelectorAll(selector), elementFromPoint: () => hit };
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
  return { Node, body, trigger, menu, options, world, document, run, finish };
}

describe('Grok observed model controls', () => {
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
