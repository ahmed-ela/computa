import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { firstMarker, markerLine, installObservedModelPicker } from './embedded-provider-adapter-fixture';

export function defineWebsiteModelChoiceTests(provider: 'chatgpt' | 'gemini' | 'claude', make: (owned?: boolean) => any, Node: any) {
  const target = provider === 'chatgpt' ? 'High' : provider === 'gemini' ? '3.8 Flash' : 'Sonnet 4.6';
  const initial = provider === 'chatgpt' ? 'Medium' : provider === 'gemini' ? '3.1 Pro' : 'Sonnet 5.5';
  const choice = (label: string) => provider === 'chatgpt' && ['Instant', 'Medium', 'High', 'Extra High', 'Pro', 'GPT-6 Pro'].includes(label)
    ? { key: 'chat/latest/' + (label === 'GPT-6 Pro' ? 'pro' : label.toLowerCase().replace(' ', '-')), label }
    : { key: label, label };
  const selectionSource = provider === 'chatgpt' ? 'selected_model_indicator' : 'checked_model_option';
  const setup = (owned = false, behavior: { genericHeader?: boolean; closedGenericHeader?: boolean; closedCompositeHeader?: boolean; resetToPowerOnClose?: boolean; unmountMenus?: boolean; replacePrimaryOnSecondary?: boolean;
    geminiMenuitemMarkers?: boolean; escapeOnlyClose?: boolean; inlineFamilyPanel?: boolean; parentReturnAfterSelection?: boolean } = {}) => {
    const f = make(owned);
    if (provider === 'chatgpt') f.composer.focus = () => { f.document.activeElement = f.composer; };
    return { f, picker: installObservedModelPicker(f, provider, Node, behavior) };
  };
  const advance = async (f: any, action: string, overrides: Record<string, unknown> = {}) => {
    let result: any;
    for (let step = 0; step < 6; step++) {
      result = await f.run(action, overrides);
      if (!result.pending) return result;
    }
    return result;
  };
  const replaceFirstRoot = (f: any, originalRoot: any, originalBody: any) => {
    let replacementBody: any;
    const clone = (node: any): any => {
      const copy = new Node(node.tagName, { ...node.values }, node.text);
      if (node === originalBody) replacementBody = copy;
      copy.append(...node.children.map(clone)); return copy;
    };
    const root = clone(originalRoot), parent = originalRoot.parentElement;
    parent.children[parent.children.indexOf(originalRoot)] = root; root.parentElement = parent;
    originalRoot.connected = false; originalRoot.parentElement = null;
    return { root, body: replacementBody, parent };
  };
  const firstRoot = (f: any) => provider === 'chatgpt' ? f.userBody.parentElement : f.userRoot;
  describe(`${provider} exact website model choices`, () => {
    test('standalone adapter embeds the audited shared model-control source exactly', () => {
      const helper = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url), 'utf8');
      const source = readFileSync(new URL(`../Sources/Computa/Resources/BrowserModels/${provider}.js`, import.meta.url), 'utf8');
      expect(source.startsWith(helper + '\n')).toBe(true);
    });

    test('diagnostic phases are finite, opt in to one operation and contain no page content', async () => {
      const { f } = setup();
      const posted: any[] = [];
      f.window.webkit.messageHandlers.computaModelDiagnostic = { postMessage: (body: any) => posted.push(body) };
      await f.run('inspect');
      expect(posted).toEqual([]);
      const operationID = 'a909845c-2857-4b22-a66b-261b22281513';
      await f.run('inspect', { operationID });
      expect(posted.length).toBeGreaterThan(0);
      const swift = readFileSync(new URL('../Sources/Computa/Browser/EmbeddedBrowserSession.swift', import.meta.url), 'utf8');
      const enumBody = swift.split('enum ModelAdapterPhase: String, CaseIterable {')[1].split('\n    }')[0];
      const phases = [...enumBody.matchAll(/case \w+ = "([a-z_]+)"/g)].map(match => match[1]);
      for (const body of posted) {
        expect(Object.keys(body).sort()).toEqual(['operationID', 'ownerToken', 'phase']);
        expect(body.operationID).toBe(operationID);
        expect(body.ownerToken).toMatch(/^[a-f0-9-]{36}$/i);
        expect(phases).toContain(body.phase);
      }
    });

    test('a missing or throwing diagnostic sink cannot change the adapter result', async () => {
      const baseline = setup().f;
      const expected = await baseline.run('inspect');
      const missing = setup().f;
      const throwing = setup().f;
      throwing.window.webkit.messageHandlers.computaModelDiagnostic = { postMessage: () => { throw new Error('PRIVATE_RAW_PAGE_CANARY'); } };
      const request = { operationID: 'a909845c-2857-4b22-a66b-261b22281513' };
      expect(await missing.run('inspect', request)).toEqual(expected);
      expect(await throwing.run('inspect', request)).toEqual(expected);
    });

    test('native clock expires a wait when website timers never run and supplies no positive proof', async () => {
      const helper = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url), 'utf8');
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      const execute = new AsyncFunction('input', 'window', 'document', 'MutationObserver', 'setTimeout', 'globalThis',
        helper + '\nreturn await websiteModelWaitForChange(Date.now() + 25, () => false);');
      const input = { ownerToken: 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30', operationID: 'a909845c-2857-4b22-a66b-261b22281513' };
      const posted: any[] = []; let pageTimers = 0, disconnected = 0;
      const window: any = { webkit: { messageHandlers: { computaModelClock: { postMessage: (body: any) => {
        posted.push(body); return new Promise(resolve => setTimeout(() => resolve(true), 25));
      } } } } }; window.top = window;
      class Observer { constructor(_callback: any) {} observe() {} disconnect() { disconnected++; } }
      const pending = execute(input, window, { documentElement: {} }, Observer, () => { pageTimers++; }, {});
      const result = await Promise.race([pending, new Promise((_, reject) => setTimeout(() => reject(new Error('native clock control deadline')), 200))]);
      expect(result).toBe(false);
      expect(pageTimers).toBe(0);
      expect(disconnected).toBe(1);
      expect(posted).toHaveLength(1);
      expect(Object.keys(posted[0]).sort()).toEqual(['milliseconds', 'operationID', 'ownerToken']);
      expect(posted[0]).toMatchObject(input);
      expect(posted[0].milliseconds).toBeGreaterThan(0);
      expect(posted[0].milliseconds).toBeLessThanOrEqual(25);
    });

    test('a real DOM condition wins once over a later native expiry and rejected clocks fail closed', async () => {
      const helper = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url), 'utf8');
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      const execute = new AsyncFunction('input', 'window', 'document', 'MutationObserver', 'setTimeout', 'globalThis', 'condition',
        helper + '\nreturn await websiteModelWaitForChange(Date.now() + 100, condition);');
      const input = { ownerToken: 'f33c8869-a5d3-4b9d-b29e-7b6f591a8e30', operationID: 'a909845c-2857-4b22-a66b-261b22281513' };
      let wake: (() => void) | undefined, expire: ((value: any) => void) | undefined, condition = false, disconnects = 0;
      const window: any = { webkit: { messageHandlers: { computaModelClock: { postMessage: () => new Promise(resolve => { expire = resolve; }) } } } }; window.top = window;
      class Observer { constructor(callback: any) { wake = callback; } observe() {} disconnect() { disconnects++; } }
      const pending = execute(input, window, { documentElement: {} }, Observer, () => { throw new Error('page timer must not run'); }, {}, () => condition);
      condition = true; wake!();
      expect(await pending).toBe(true);
      expire!(true); await Promise.resolve(); await Promise.resolve();
      expect(disconnects).toBe(1);
      window.webkit.messageHandlers.computaModelClock.postMessage = () => Promise.reject(new Error('clock rejected'));
      expect(await execute(input, window, { documentElement: {} }, Observer, () => { throw new Error('page timer must not run'); }, {}, () => false)).toBe(false);
    });

    test('discovery exposes enabled family leaves and excludes descriptions, effort and upgrades', async () => {
      const { f, picker } = setup();
      const result = await advance(f, 'discoverModels');
      const expected = provider === 'chatgpt' ? ['Instant', 'Medium', 'High', 'Extra High', 'GPT-6 Pro']
        : provider === 'gemini' ? ['3.5 Flash-Lite', '3.8 Flash', '3.1 Pro']
          : ['Sonnet 5.5', 'Haiku 4.5', 'Sonnet 5', 'Sonnet 4.6'];
      expect(result.modelChoices).toEqual(expected.map(choice));
      expect(result.modelChoices.some((item: any) => /thinking|Upgrade|Leaving|answers|reasoning|help/.test(item.label))).toBe(false);
      expect(picker.options.reduce((sum: number, option: any) => sum + option.clicks, 0)).toBe(0);
      expect(picker.trigger.clicks).toBeLessThanOrEqual(provider === 'chatgpt' ? 3 : 2);
      if (picker.secondary) expect(picker.secondary.clicks).toBe(1);
      expect((await f.run('discoverModels')).modelChoices).toEqual(result.modelChoices);
      expect(picker.trigger.clicks).toBeLessThanOrEqual(provider === 'chatgpt' ? 3 : 2);
    });

    if (provider === 'chatgpt') test('discovery resolves the newest plain family and never advertises Sol or a literal Latest', async () => {
      const { f, picker } = setup(); picker.selected('GPT-5.6 Sol');
      const sol = picker.familyOptions[1], newest = picker.familyOptions[0];
      const result = await advance(f, 'discoverModels');
      expect(result.modelChoices).toEqual(['Instant', 'Medium', 'High', 'Extra High', 'GPT-6 Pro'].map(choice));
      expect(result.modelEvidence.chatSelection.family).toEqual({ key: 'GPT-6', label: 'GPT-6' });
      expect(result.modelEvidence.chatSelection.automaticFamily.offered).toEqual(['GPT-6', 'GPT-5.5']);
      expect(newest.clicks).toBe(1); expect(sol.clicks).toBe(0);
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      const before = picker.trigger.clicks;
      expect((await f.run('discoverModels')).modelChoices).toEqual(result.modelChoices);
      expect(picker.trigger.clicks).toBe(before);
      const fresh = setup(); fresh.picker.selected('GPT-5.6 Sol');
      expect((await advance(fresh.f, 'selectModel', { modelChoice: choice('Pro') })).modelEvidence.selected).toEqual(choice('Pro'));
      expect(sol.clicks).toBe(0); expect(newest.clicks).toBe(1);
    });

    test('one exact choice is clicked once and reinspection confirms its website label', async () => {
      const { f, picker } = setup();
      const result = await advance(f, 'selectModel', { modelChoice: choice(target) });
      expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), verification: 'website_selection' } });
      const selected = picker.options.find((option: any) => option.children[0].text === target);
      expect(selected.clicks).toBe(1);
      expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).modelEvidence.selected).toEqual(choice(target));
      expect(await f.run('selectModel', { modelChoice: choice(target) })).toMatchObject({ selected: true });
      expect(selected.clicks).toBe(1);
      expect(picker.options.reduce((sum: number, option: any) => sum + option.clicks, 0)).toBe(1);
    });

    test('picker hydration waits for events without clicking or treating composer readiness as model proof', async () => {
      const { f, picker } = setup(); picker.trigger.connected = false;
      for (let step = 0; step < 3; step++) {
        const result = await f.run('discoverModels');
        expect(result.pending).toBe(true);
        if (provider !== 'chatgpt') expect(result.modelDiagnostic).toMatchObject({ triggerCount: 0, triggerCandidates: [] });
      }
      expect(picker.trigger.clicks).toBe(0);
      picker.trigger.connected = true;
      expect((await advance(f, 'discoverModels')).modelChoices.length).toBeGreaterThan(0);
      expect(picker.trigger.clicks).toBeLessThanOrEqual(provider === 'chatgpt' ? 3 : 2);
    });

    test('successful discovery retains bounded menu-shape evidence before it closes the picker', async () => {
      const { f, picker } = setup();
      const result = await advance(f, 'discoverModels');
      expect(result.modelDiagnostic.triggerCount).toBe(1);
      expect(result.modelDiagnostic.associatedMenus.every((menu: any) => menu.visible)).toBe(true);
      expect(result.modelDiagnostic.candidates.some((candidate: any) => candidate.primaryFamily === (provider === 'chatgpt' ? 'GPT-6' : initial))).toBe(true);
      expect(result.modelDiagnostic.rawFamilySummary.some((candidate: any) => candidate.primaryFamily === (provider === 'chatgpt' ? 'GPT-6' : initial))).toBe(true);
      expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8192);
      expect(picker.menu.values.hidden).toBe('');
    });

    if (provider === 'gemini') test('Gemini mode triggers support the observed label without an optional brand', async () => {
      for (const label of ['Open mode picker, currently Pro', 'Open mode picker, currently Flash',
        'Open mode picker, currently 3.1 Pro', 'Open mode picker, currently Gemini Pro']) {
        const { f, picker } = setup(); picker.trigger.values['aria-label'] = label;
        const result = await advance(f, 'discoverModels');
        expect(result.modelChoices).toEqual(['3.5 Flash-Lite', '3.8 Flash', '3.1 Pro'].map(choice));
        expect(result.modelDiagnostic.triggerCount).toBe(1);
        expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe(label);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      }
    });

    if (provider === 'claude') test('the observed Haiku Extended effort suffix verifies the same family and is not a model choice', async () => {
      const { f, picker } = setup(); picker.selected('Haiku 4.5');
      picker.trigger.values['aria-label'] = 'Model: Haiku 4.5 Extended';
      expect((await f.run('verifyModel', { expectedModelChoice: choice('Haiku 4.5') })).modelEvidence.selected).toEqual(choice('Haiku 4.5'));
      const result = await advance(f, 'discoverModels');
      expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe('Model: Haiku 4.5 Extended');
      expect(result.modelChoices.some((model: any) => model.label.includes('Extended'))).toBe(false);
      picker.trigger.values['aria-label'] = 'Model: Haiku 4.5 PRIVATE EFFORT';
      expect((await f.run('verifyModel', { expectedModelChoice: choice('Haiku 4.5') })).error).toBe('model_unverified');
    });

    if (provider === 'gemini') {
      test('separate selected thinking effort neither invalidates nor proves the Gemini model', async () => {
        for (const effort of ['Low', 'High']) {
          const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true });
          const row = new Node('BUTTON', { role: 'menuitem', class: 'selected' });
          row.append(new Node('SPAN', {}, effort), new Node('SPAN', {}, effort === 'Low' ? 'Quick and efficient' : 'Extra thorough'),
            new Node('GEM-ICON', { 'aria-label': 'Selected' }));
          picker.menu.append(row);
          expect(await advance(f, 'selectModel', { modelChoice: choice(target) })).toMatchObject({ selected: true,
            modelEvidence: { selected: choice(target), source: 'selected_model_indicator' } });
          expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).modelEvidence)
            .toMatchObject({ selected: choice(target), source: 'selected_model_indicator' });
          expect(row.clicks).toBe(0);
          picker.open();
          for (const option of picker.options) {
            option.values.class = '';
            option.children = option.children.filter((node: any) => node.values['aria-label'] !== 'Selected');
          }
          expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).error).toBe('model_unverified');
          expect(row.clicks).toBe(0);
        }
      });

      test('observed menuitem Selected icons and selected classes prove Gemini choices without radio attributes', async () => {
        const discovery = setup(false, { genericHeader: true, unmountMenus: true, geminiMenuitemMarkers: true });
        expect((await advance(discovery.f, 'discoverModels')).modelChoices)
          .toEqual(['3.5 Flash-Lite', '3.8 Flash', '3.1 Pro'].map(choice));
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true, geminiMenuitemMarkers: true });
        expect(await advance(f, 'selectModel', { modelChoice: choice(target) })).toMatchObject({ selected: true,
          modelEvidence: { selected: choice(target), source: 'selected_model_indicator', verification: 'website_selection' } });
        const selected = picker.options.find((option: any) => option.children[0].text === target);
        expect(selected.clicks).toBe(1);
        expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).modelEvidence.source).toBe('selected_model_indicator');
        picker.selected(initial);
        expect((await f.run('verifyModel', { expectedModelChoice: choice(target) })).error).toBe('model_mismatch');
        expect(selected.clicks).toBe(1);
      });

      test('Gemini active and focused rows never override the separate Selected marker', async () => {
        const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true });
        picker.options[0].values.class = 'ng-star-inserted active focused';
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence)
          .toMatchObject({ selected: choice(initial), source: 'selected_model_indicator' });
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      });

      test('Gemini missing, duplicate, hidden and contradictory Selected indicators fail closed', async () => {
        for (const change of [
          (p: any, selected: any, marker: any) => { selected.children = selected.children.filter((node: any) => node !== marker); },
          (p: any, selected: any, marker: any) => { marker.values.hidden = ''; },
          (p: any, selected: any, marker: any) => { marker.values['aria-hidden'] = 'true'; },
          (p: any, selected: any) => { selected.append(new Node('GEM-ICON', { 'aria-label': 'Selected' })); },
          (p: any, selected: any) => { selected.values.class = 'ng-star-inserted focused'; },
          (p: any, selected: any) => { selected.values['aria-checked'] = 'false'; },
          (p: any, selected: any) => { selected.values['aria-selected'] = 'true'; },
          (p: any) => { p.options[0].values.class = 'selected'; p.options[0].append(new Node('GEM-ICON', { 'aria-label': 'Selected' })); },
          (p: any) => { p.options[0].append(new Node('GEM-ICON', { 'aria-label': 'Selected' })); },
          (p: any, selected: any) => { selected.children[0].text = 'Unknown family'; },
        ]) {
          const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true }); picker.open();
          const selected = picker.options.find((option: any) => option.children[0].text === initial);
          const marker = selected.children.find((node: any) => node.values['aria-label'] === 'Selected');
          change(picker, selected, marker);
          expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_unverified');
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        }
      });
    }

    if (provider === 'claude') test('nested navigation labels survive decorative SVG content but need their own popup association', async () => {
      const { f, picker } = setup();
      const name = provider === 'chatgpt' ? 'Select model' : 'More models';
      delete picker.secondary.values['aria-label']; picker.secondary.values.role = 'menuitem';
      picker.secondary.append(new Node('SPAN', {}, name), new Node('SVG', {}, 'Decorative arrow text'));
      const result = await advance(f, 'discoverModels');
      expect(result.modelChoices.some((model: any) => model.label === target)).toBe(true);
      expect(picker.secondary.clicks).toBe(1);
      const ambiguous = setup(); ambiguous.picker.open();
      const second = new Node('DIV', { role: 'menuitem', 'aria-haspopup': 'menu' }); second.append(new Node('SPAN', {}, name));
      ambiguous.picker.menu.append(second);
      expect((await ambiguous.f.run('discoverModels')).error).toBe('model_unverified');
      expect(second.clicks).toBe(0); expect(ambiguous.picker.secondary.clicks).toBe(0);
      const detached = setup(); detached.picker.open();
      delete detached.picker.secondary.values['aria-haspopup'];
      expect(((await advance(detached.f, 'discoverModels')).modelChoices || []).some((model: any) => model.label === target)).toBe(false);
      expect(detached.picker.secondary.clicks).toBe(0);
    });

    test('diagnostic trigger labels expose only finite provider mode grammar', async () => {
      const { f, picker } = setup();
      const prefix = provider === 'chatgpt' ? 'Select ChatGPT model ' : provider === 'gemini' ? 'Open mode picker, currently ' : 'Model: ';
      picker.trigger.values['aria-label'] = prefix + 'PRIVATE ACCOUNT SENTINEL';
      let result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.triggerCount).toBe(0);
      expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe(null);
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      picker.trigger.values['aria-label'] = provider === 'chatgpt' ? 'Select ChatGPT model ' + '0'.repeat(10000)
        : provider === 'gemini' ? 'Open mode picker, currently ' + '0'.repeat(10000) + ' Pro' : 'Model: Sonnet ' + '0'.repeat(10000);
      result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.triggerCount).toBe(0);
      expect(result.modelDiagnostic.triggerCandidates[0].safeLabel).toBe(null);
      expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8192);
      expect(picker.trigger.clicks).toBe(0);
    });

    test('raw option diagnostics recognize nested family containers without granting selection authority', async () => {
      const { f, picker } = setup(); picker.open();
      const row = new Node('DIV', { role: 'menuitem', 'data-state': 'checked', 'aria-selected': 'true' });
      const label = new Node('DIV');
      const observedFamily = provider === 'chatgpt' ? 'GPT-6' : target;
      const split = Math.floor(observedFamily.length / 2);
      label.append(new Node('SPAN', {}, observedFamily.slice(0, split)), new Node('SPAN', {}, observedFamily.slice(split)));
      const marker = new Node('SVG', { 'aria-label': 'Selected', 'data-account-id': 'PRIVATE ACCOUNT' });
      row.append(label, marker, new Node('SPAN', {}, 'PRIVATE DESCRIPTION'));
      picker.menu.children.forEach((child: any) => { child.connected = false; });
      picker.menu.children = []; picker.menu.text = ''; picker.menu.append(row);
      if (picker.nested && picker.nested !== picker.menu) picker.nested.values.hidden = '';
      const result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.rawOptionCount).toBe(1);
      expect(result.modelDiagnostic.rawOptions[0]).toMatchObject({ role: 'menuitem', primaryFamily: null,
        checkedAttribute: null, dataState: 'checked', recognizedContainers: [{ family: observedFamily, childElementCount: 2 }],
        selectedMarkers: [{ tag: 'svg', kind: 'selected_label' }] });
      expect(result.modelDiagnostic.rawFamilySummary).toEqual([{ role: 'menuitem', primaryFamily: null,
        recognizedFamily: observedFamily, visible: true, enabled: true, checkedAttribute: null, dataState: 'checked', selectedMarkerCount: 1 }]);
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      const pending = f.run('selectModel', { modelChoice: choice(target) });
      if (provider === 'chatgpt') { for (let tick = 0; tick < 40; tick++) await Promise.resolve(); f.advanceTime(1_801); f.flush(); }
      expect(['model_unavailable', 'model_unverified']).toContain((await pending).error);
      expect(row.clicks).toBe(0);
    });

    test('a Selected icon and presentation data cannot prove a generic-header family choice', async () => {
      const { f, picker } = setup(false, { genericHeader: true });
      if (provider === 'chatgpt') picker.showFamily(); else picker.open();
      const rows = provider === 'chatgpt' ? picker.familyOptions : picker.options;
      for (const option of rows) delete option.values['aria-checked'];
      rows[0].values['data-state'] = 'checked'; rows[0].append(new Node('SVG', { 'aria-label': 'Selected' }));
      expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_unverified');
      expect(rows.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('an already selected choice needs no selection mutation and a later drift is rejected', async () => {
      const { f, picker } = setup();
      expect(await f.run('selectModel', { modelChoice: choice(initial) })).toMatchObject({ selected: true });
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      if (provider !== 'chatgpt') expect(picker.trigger.clicks).toBe(0);
      picker.selected(target);
      expect(await f.run('selectModel', { modelChoice: choice(initial) })).toMatchObject({ error: 'model_mismatch' });
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('strict model drift blocks every editor action before selection mutation or insertion', async () => {
      const { f, picker } = setup();
      for (const action of ['prepare', 'insert', 'sendReady', 'submit', 'inspect', 'verifyModel']) {
        const result = await f.run(action, { expectedModelChoice: choice(target), prompt: 'PRIVATE PROMPT SENTINEL' });
        expect(result.error).toBe('model_mismatch');
        if (provider !== 'chatgpt') expect(result.modelEvidence.selected).toEqual(choice(initial));
        expect(result.text).toBeUndefined(); expect(JSON.stringify(result)).not.toContain('PRIVATE PROMPT SENTINEL');
      }
      if (provider !== 'chatgpt') expect(picker.trigger.clicks).toBe(0);
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      if (f.send) expect(f.send.clicks).toBe(0);
      expect(f.composer.textContent).toBe('');
    });

    test('missing, hidden, inert or message-authored picker cannot verify exact models', async () => {
      for (const change of [
        (f: any, p: any) => { p.trigger.connected = false; },
        (f: any, p: any) => { p.trigger.values.hidden = ''; },
        (f: any, p: any) => { p.trigger.values.inert = ''; },
        (f: any, p: any) => { p.trigger.values['aria-hidden'] = 'true'; },
        (f: any, p: any) => { f.body.children = f.body.children.filter((node: any) => node !== p.trigger); f.answer.append(p.trigger); },
      ]) {
        const { f, picker } = setup(true); change(f, picker);
        if (provider === 'chatgpt') f.window.webkit.messageHandlers.computaModelClock = { postMessage: () => {
          f.advanceTime(1_801); return Promise.resolve(true);
        } };
        const result = await f.run('inspect', { expectedModelChoice: choice(initial),
          ...(provider === 'chatgpt' ? { operationID: '2a56a1c2-7f3f-4ef4-9675-610a5b7cb1c8' } : {}) });
        expect(result).toMatchObject({ error: 'model_unverified' });
        expect(result.text).toBeUndefined(); expect(picker.trigger.clicks).toBe(0);
      }
    });

    test('duplicate visible pickers and conflicting checked model evidence fail closed', async () => {
      const first = setup(); installObservedModelPicker(first.f, provider, Node);
      expect(await first.f.run('inspect', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_unverified' });
      const { f, picker } = setup();
      if (provider === 'chatgpt') {
        picker.showFamily(); picker.familyOptions.forEach((option: any) => { option.values['aria-checked'] = 'true'; });
      } else {
        picker.open(); picker.options.forEach((option: any) => { option.values['aria-checked'] = option.children[0].text === target ? 'true' : 'false'; });
      }
      expect(await f.run('inspect', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_unverified' });
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      if (provider !== 'chatgpt') picker.options.forEach((option: any) => { option.values['aria-checked'] = 'true'; });
      expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_unverified');
    });

    test('focus and presentation selection never substitute for the checked model radio', async () => {
      const { f, picker } = setup();
      if (provider === 'chatgpt') picker.showFamily(); else picker.open();
      const other = provider === 'chatgpt' ? picker.familyOptions[2]
        : picker.options.find((option: any) => option.children[0].text === target);
      other.values.class = 'selected focused'; other.values['data-state'] = 'checked'; other.values['aria-current'] = 'true';
      other.values['aria-selected'] = 'true';
      const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(result.modelEvidence.selected).toEqual(choice(initial));
      if (provider === 'chatgpt') expect(result.modelEvidence.chatSelection).toMatchObject({
        family: { key: 'GPT-6', label: 'GPT-6' }, power: { key: 'medium', label: 'Medium' } });
      expect(other.clicks).toBe(0);
    });

    if (provider !== 'chatgpt') test('lost primary and target-choice acknowledgments never replay any clicked stage', async () => {
      const primary = setup();
      primary.picker.trigger.onClick = () => { throw new Error('lost primary acknowledgment'); };
      await expect(primary.f.run('selectModel', { modelChoice: choice(target) })).rejects.toThrow('lost primary');
      for (let i = 0; i < 3; i++) expect(await primary.f.run('selectModel', { modelChoice: choice(target) })).toMatchObject({ pending: true });
      expect(primary.picker.trigger.clicks).toBe(1);
      const { f, picker } = setup(); picker.open();
      const selected = picker.options.find((option: any) => option.children[0].text === target);
      selected.onClick = () => { throw new Error('lost choice acknowledgment'); };
      await expect(f.run('selectModel', { modelChoice: choice(target) })).rejects.toThrow('lost choice');
      for (let i = 0; i < 3; i++) {
        const observing = f.run('selectModel', { modelChoice: choice(target) });
        if (provider === 'chatgpt') for (let tick = 0; tick < 8; tick++) { await Promise.resolve(); f.flush(); }
        const rejected = await observing;
        expect(provider === 'chatgpt' ? ['model_unverified', 'model_mismatch'] : ['model_mismatch']).toContain(rejected.error);
        expect(rejected.selected).toBeUndefined();
      }
      expect(selected.clicks).toBe(1);
      expect(picker.options.reduce((sum: number, option: any) => sum + option.clicks, 0)).toBe(1);
    });

    if (provider !== 'chatgpt') test('unavailable, disabled and duplicate exact choices are never clicked', async () => {
      for (const change of [
        (p: any) => { p.options.find((option: any) => option.children[0].text === target).disabled = true; },
        (p: any) => { p.options.find((option: any) => option.children[0].text === target).values['aria-disabled'] = 'true'; },
        (p: any) => { p.options.find((option: any) => option.children[0].text === target).append(new Node('SPAN', {}, 'Upgrade')); },
        (p: any) => { p.add(p.nested || p.menu, target); },
      ]) {
        const { f, picker } = setup(); picker.open(); change(picker);
        const result = await f.run('selectModel', { modelChoice: choice(target) });
        expect(['model_unavailable', 'model_unverified']).toContain(result.error);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      }
    });

    test('unknown or malformed native choices cannot be coerced from label-only matches', async () => {
      for (const malformed of [null, { key: initial }, { key: initial, label: target }, { key: initial, label: initial, extra: true },
        { key: ' ' + initial, label: initial }, { key: initial, label: initial + ' ' }, { key: initial, label: '' },
        { key: 'x'.repeat(161), label: initial }]) {
        const { f, picker } = setup();
        const result = await advance(f, 'selectModel', { modelChoice: malformed });
        expect(['model_unverified', 'model_unavailable']).toContain(result.error);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      }
    });

    test('unassociated menus provide structure diagnostics but never model choice authority', async () => {
      const { f, picker } = setup();
      delete picker.trigger.values['aria-controls']; delete picker.menu.values['aria-labelledby']; picker.open();
      const result = await f.run('discoverModels');
      expect(result.modelChoices).toBeUndefined();
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      const next = await f.run('discoverModels');
      expect(next).toMatchObject({ error: 'model_unverified' });
      const diagnostic = next.modelDiagnostic || result.modelDiagnostic;
      expect(diagnostic.unassociatedMenus.length).toBeGreaterThan(0);
      expect(diagnostic.unassociatedMenus.every((menu: any) => menu.primaryFamily === null)).toBe(true);
    });

    test('response prose cannot grant attribution and inspections make no selection mutations', async () => {
      const { f, picker } = setup(true);
      f.answer.append(new Node('SPAN', {}, 'I am ' + target));
      for (let i = 0; i < 3; i++) {
        const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
        expect(result.modelEvidence).toMatchObject({ selected: choice(initial), verification: 'website_selection' });
        expect(result.modelEvidence.response).toBeUndefined();
        expect(result.modelEvidence.source).toBe(provider === 'chatgpt' ? 'selected_model_indicator' : 'model_picker_label');
      }
      if (provider !== 'chatgpt') expect(picker.trigger.clicks).toBe(0);
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('a digest yield cannot admit a response after the website model changed', async () => {
      const { f, picker } = setup(true);
      f.onDigest(() => picker.selected(target));
      expect(await f.run('inspect', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_mismatch' });
      if (provider !== 'chatgpt') expect(picker.trigger.clicks).toBe(0);
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('the final concrete verification must observe current temporary mode after its picker await', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const click = picker.trigger.onClick; let opens = 0;
      picker.trigger.onClick = () => {
        const opening = picker.menu.values.hidden !== undefined; click();
        if (opening && ++opens === (provider === 'chatgpt' ? 1 : 2)) {
          if (provider === 'chatgpt') f.temporary.connected = false;
          else { f.badge.connected = false; f.exit.connected = false; }
        }
      };
      const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(result.error).toBe('temporary_mode_unverified'); expect(result.modelEvidence).toBeUndefined();
      expect(opens).toBe(provider === 'chatgpt' ? 1 : 2); expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      expect(f.composer.textContent).toBe(''); if (f.send) expect(f.send.clicks).toBe(0);
    });

    test('final concrete verification accepts mode controls hidden only by the associated open modal', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const modes = provider === 'chatgpt' ? [f.temporary] : [f.header, f.exit];
      const background = new Node('DIV'); f.body.children = f.body.children.filter((node: any) => !modes.includes(node));
      background.append(...modes); f.body.append(background);
      const click = picker.trigger.onClick; let opens = 0;
      picker.trigger.onClick = () => {
        const opening = picker.menu.values.hidden !== undefined; click();
        if (opening) { opens++; background.values['aria-hidden'] = 'true'; }
        else delete background.values['aria-hidden'];
      };
      if (provider === 'chatgpt') {
        for (const menu of [picker.menu, picker.nested].filter(Boolean)) {
          const escape = menu.onDispatch;
          menu.onDispatch = (event: any) => { escape(event); delete background.values['aria-hidden']; };
        }
      }
      const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(result.error).toBeUndefined(); expect(result.modelEvidence.selected).toEqual(choice(initial));
      expect(opens).toBe(provider === 'chatgpt' ? 1 : 2); expect(background.values['aria-hidden']).toBeUndefined();
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      if (f.send) expect(f.send.clicks).toBe(0);
    });

    test('first acknowledged bubbles during either fresh model read discard only the read observation', async () => {
      for (const action of ['inspect', 'verifyModel']) for (const appendOnOpen of provider === 'chatgpt' && action === 'verifyModel' ? [1] : [1, 2]) {
        const { f, picker } = setup(false, { genericHeader: true });
        const prompt = 'Synthetic pending first\n\n' + markerLine;
        Object.assign(f.world, { __computaModelFirstSubmitted: true, __computaModelFirstMarker: firstMarker,
          __computaModelFirstPrompt: prompt, __computaModelLastSubmissionCount: 0 });
        const click = picker.trigger.onClick; let opens = 0, appended = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && ++opens === appendOnOpen) { appended = true; f.appendUser(prompt); }
        };
        const discarded = await f.run(action, { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial) });
        expect(discarded).toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
        expect(appended).toBe(true); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        expect((await f.run('inspect', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial) })).firstUserVerified).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('acknowledged continuation bubbles during either model read retain exact first-message pins', async () => {
      for (const action of ['inspect', 'verifyModel']) for (const appendOnOpen of provider === 'chatgpt' && action === 'verifyModel' ? [1] : [1, 2]) {
        const { f, picker } = setup(true, { genericHeader: true });
        const first = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const pin = f.world.__computaModelFirstProof;
        f.world.__computaModelLastSubmissionCount = 1;
        const click = picker.trigger.onClick; let opens = 0;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && ++opens === appendOnOpen) f.appendUser('Synthetic acknowledged continuation');
        };
        expect(await f.run(action, { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) }))
          .toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
        expect(f.world.__computaModelFirstProof).toBe(pin);
        const fresh = await f.run('inspect', { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) });
        expect(fresh.firstUserFingerprint).toBe(first.firstUserFingerprint); expect(fresh.firstUserVerified).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('digest-time acknowledged appends keep the same exact model-read constraints', async () => {
      for (const foreignMarker of [false, true]) {
        const { f } = setup(true);
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        f.world.__computaModelLastSubmissionCount = 1;
        f.onDigest(() => {
          f.appendUser('Synthetic digest continuation');
          if (foreignMarker) f.world.__computaModelFirstMarker = '00000000-0000-0000-0000-000000000000';
        });
        const result = await f.run('inspect', { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) });
        if (foreignMarker) expect(result.error).toBe('conversation_changed');
        else expect(result).toEqual({ error: 'acknowledged_user_append', detail: 'readonly_model_observation' });
      }
    });

    test('an exact disconnected first-root replacement during either model read is discarded for a fresh pinned inspect', async () => {
      for (const action of ['inspect', 'verifyModel']) for (const replaceOnOpen of provider === 'chatgpt' && action === 'verifyModel' ? [1] : [1, 2]) {
        const { f, picker } = setup(true, { genericHeader: true });
        const first = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const originalRoot = firstRoot(f), originalBody = f.userBody, pin = f.world.__computaModelFirstProof;
        const click = picker.trigger.onClick; let opens = 0;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && ++opens === replaceOnOpen) replaceFirstRoot(f, originalRoot, originalBody);
        };
        expect(await f.run(action, { expectedUserCounts: [1], expectedModelChoice: choice(initial) }))
          .toEqual({ error: 'first_user_observation_replaced', detail: 'readonly_model_observation' });
        expect(originalRoot.isConnected).toBe(false); expect(originalBody.isConnected).toBe(false);
        expect(f.world.__computaModelFirstProof).toBe(pin);
        const fresh = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        expect(fresh.firstUserVerified).toBe(true); expect(fresh.firstUserFingerprint).toBe(first.firstUserFingerprint);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('replacement retry requires disconnected exact scoped bytes, marker, count, owner, pins and temporary state', async () => {
      for (const change of [
        (f: any, oldRoot: any, pair: any) => { pair.body.text += ' Changed payload'; },
        (f: any, oldRoot: any, pair: any) => { pair.body.text = pair.body.text.replace(firstMarker, '00000000-0000-0000-0000-000000000000'); },
        (f: any) => { f.world.__computaModelFirstProof.fingerprint = '0'.repeat(64); },
        (f: any) => { f.world.__computaModelFirstMarker = '00000000-0000-0000-0000-000000000000'; },
        (f: any) => { f.world.__computaModelOwner = 'foreign'; },
        (f: any) => { f.document.URL += '&changed=1'; },
        (f: any) => { if (provider === 'chatgpt') f.temporary.connected = false; else f.temporary(false); },
        (f: any) => { f.appendUser('Unexpected count append'); },
        (f: any, oldRoot: any) => { oldRoot.connected = true; oldRoot.values = {}; oldRoot.tagName = 'SECTION'; f.body.append(oldRoot); },
        ...(provider === 'claude' ? [(f: any, oldRoot: any, pair: any) => { pair.parent.values.id = 'different-provider-identity'; }] : []),
      ]) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const root = firstRoot(f), body = f.userBody, click = picker.trigger.onClick; let replaced = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !replaced) { replaced = true; const pair = replaceFirstRoot(f, root, body); change(f, root, pair); }
        };
        const result = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        expect(result.error).toBeDefined(); expect(result.error).not.toBe('first_user_observation_replaced');
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('a second replacement during replacement SHA is rejected and every editor action remains strict', async () => {
      for (const action of ['inspect', 'prepare', 'insert', 'sendReady', 'submit']) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const root = firstRoot(f), body = f.userBody, click = picker.trigger.onClick; let replaced = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !replaced) {
            replaced = true; const pair = replaceFirstRoot(f, root, body);
            if (action === 'inspect') f.onDigest(() => replaceFirstRoot(f, pair.root, pair.body));
          }
        };
        const result = await f.run(action, { expectedUserCounts: [1], expectedModelChoice: choice(initial), prompt: 'PRIVATE INSERT' });
        expect(result.error).toBe('conversation_changed'); expect(result.error).not.toBe('first_user_observation_replaced');
        expect(f.composer.textContent).toBe(''); if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('changed bodies, foreign markers, unexpected counts and unclaimed appends never get read retry authority', async () => {
      for (const change of [
        (f: any, body: any) => { body.text += ' Changed first body'; },
        (f: any) => { f.world.__computaModelFirstMarker = '00000000-0000-0000-0000-000000000000'; },
        (f: any) => { delete f.world.__computaModelLastSubmissionCount; },
        (f: any) => { f.appendUser('Unexpected second append'); },
        (f: any) => { f.world.__computaModelOwner = 'foreign'; },
      ]) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        const body = f.userBody; f.world.__computaModelLastSubmissionCount = 1;
        const click = picker.trigger.onClick; let appended = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !appended) { appended = true; f.appendUser('Synthetic continuation'); change(f, body); }
        };
        const rejected = await f.run('inspect', { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial) });
        expect(rejected.error).not.toBe('acknowledged_user_append'); expect(rejected.error).toBeDefined();
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    test('acknowledged appends during model reads never authorize an editor mutation', async () => {
      for (const action of ['prepare', 'insert', 'sendReady', 'submit']) {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        f.world.__computaModelLastSubmissionCount = 1;
        const click = picker.trigger.onClick; let appended = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !appended) { appended = true; f.appendUser('Synthetic continuation'); }
        };
        const rejected = await f.run(action, { expectedUserCounts: [1, 2], expectedModelChoice: choice(initial), prompt: 'PRIVATE INSERT SENTINEL' });
        expect(rejected.error).toBe('conversation_changed'); expect(rejected.error).not.toBe('acknowledged_user_append');
        expect(f.composer.textContent).toBe('');
        if (f.send) expect(f.send.clicks).toBe(0);
      }
    });

    if (provider === 'chatgpt') describe('owned collapsed first message expansion', () => {
      const expansionInput = { allowFirstUserExpansion: true, firstUserExpansionModelChoice: choice(initial) };
      const collapsed = async (behavior: { genericHeader?: boolean } = {}) => {
        const { f, picker } = setup(true, behavior);
        // Establish real Chat/temporary provenance without binding the staged
        // first message; the native first-submission permission stays explicit.
        expect((await f.run('inspect', { allowFirstUserBinding: false })).error).toBe('conversation_changed');
        const prompt = 'PRIVATE LONG OUTBOUND\n' + 'x'.repeat(40_000) + '\n\n' + markerLine;
        f.world.__computaModelFirstPrompt = prompt; f.world.__computaModelLastSubmissionCount = 0;
        f.userBody.text = prompt.slice(0, 10_240);
        const root = firstRoot(f), expand = new Node('BUTTON', { 'aria-label': 'Show more' });
        const send = new Node('BUTTON', { 'aria-label': 'Send' }); root.append(expand); f.body.append(send);
        return { f, picker, root, expand, send, prompt };
      };
      const notify = (f: any) => f.observers.forEach((observer: any) => observer.callback([
        { type: 'characterData', target: { nodeType: 3, parentElement: f.userBody } },
      ]));
      const noSend = (f: any, picker: any, send: any) => {
        expect(send.clicks).toBe(0); expect(f.composer.textContent).toBe(''); expect(f.composer.events).toHaveLength(0);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      };
      const rejected = (result: any) => {
        expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
      };
      test('a recovery-only inspect suppresses a fresh first-message expansion claim without changing ordinary inspection', async () => {
        for (const suppress of [true, false, undefined]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => { f.userBody.text = prompt; };
          const result = await f.run('inspect', { ...expansionInput, suppressFirstUserExpansionClaim: suppress });
          if (suppress === true) {
            rejected(result); expect(expand.clicks).toBe(0);
            expect(f.world.__computaModelFirstExpansion).toBeUndefined();
            expect(f.world.__computaModelFirstProof).toBeUndefined();
            expect(f.userBody.text).toBe(prompt.slice(0, 10_240));
          } else {
            expect(result.firstUserVerified).toBe(true); expect(expand.clicks).toBe(1);
            expect(f.world.__computaModelFirstExpansion.outcome).toBe('expanded');
          }
          noSend(f, picker, send);
        }
      });

      test('a suppressed recovery can bind a prior completed exact expansion without a new claim or click', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; };
        const first = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(target) });
        expect(first.error).toBe('model_mismatch'); expect(f.world.__computaModelFirstProof).toBeUndefined();
        const candidate = f.world.__computaModelFirstExpansion, deadline = candidate.deadline;
        expect(candidate).toMatchObject({ outcome: 'expanded', expandedText: prompt, clicked: true });
        const result = await f.run('inspect', { ...expansionInput, suppressFirstUserExpansionClaim: true,
          expectedModelChoice: choice(initial) });
        expect(result.firstUserVerified).toBe(true); expect(result.firstUserMarkerVerified).toBe(true);
        expect(f.world.__computaModelFirstExpansion).toBe(candidate);
        expect(candidate.deadline).toBe(deadline); expect(candidate.expandedText).toBe(prompt);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('suppressed recovery preserves failed timed-out and still-pending expansion claims without binding or cleanup authority', async () => {
        for (const state of ['failed', 'timeout', 'pending']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
          expand.onClick = () => { dispatched(); if (state === 'failed') throw new Error('PRIVATE FAILED EXPANSION'); };
          const pending = f.run('inspect', expansionInput); await click;
          if (state === 'timeout') f.flush();
          if (state !== 'pending') { rejected(await pending); f.userBody.text = prompt; }
          const candidate = f.world.__computaModelFirstExpansion, deadline = candidate.deadline;
          const outcome = state === 'pending' ? 'claimed' : state;
          expect(candidate.outcome).toBe(outcome);
          for (const action of ['inspect', 'cleanup']) {
            const result = await f.run(action, { ...expansionInput, suppressFirstUserExpansionClaim: true });
            rejected(result); expect(f.world.__computaModelFirstProof).toBeUndefined();
            expect(f.world.__computaModelFirstExpansion).toBe(candidate);
            expect(candidate.outcome).toBe(outcome); expect(candidate.deadline).toBe(deadline);
            expect(expand.clicks).toBe(1); noSend(f, picker, send);
          }
          if (state === 'pending') {
            // The recovery read has no mutation authority; the original bounded
            // observation can still receive its own completion event.
            f.userBody.text = prompt; notify(f);
            expect((await pending).firstUserVerified).toBe(true);
            expect(expand.clicks).toBe(1); noSend(f, picker, send);
          }
        }
      });

      const rejectedFramedExpansion = async (expectedJSON: string, renderedJSON: string, frame = 'unique',
        decorate?: (f: any, prompt: string, rendered: string) => void) => {
        const { f, picker, expand, send } = await collapsed();
        const prefix = 'PRIVATE FRAME PREFIX\n' + 'x'.repeat(11_000) + '\nCOMPLETE_RESPONSES_REQUEST_JSON:\n';
        const suffix = '\nEND_COMPLETE_RESPONSES_REQUEST_JSON.\n\n' + markerLine;
        const prompt = prefix + expectedJSON + suffix;
        f.world.__computaModelFirstPrompt = prompt; f.userBody.text = prompt.slice(0, 10_240);
        expand.onClick = () => {
          const rendered = prefix + renderedJSON + suffix;
          f.userBody.text = frame === 'missing' ? rendered.replace('COMPLETE_RESPONSES_REQUEST_JSON:\n', '')
            : frame === 'duplicate' ? rendered + '\nEND_COMPLETE_RESPONSES_REQUEST_JSON.' : rendered;
          decorate?.(f, prompt, f.userBody.text);
        };
        const result = await f.run('inspect', expansionInput);
        rejected(result); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(result.debugStructure).not.toContain('private_key');
        expect(result.debugStructure).not.toContain('private_value');
        return JSON.parse(result.debugStructure);
      };

      test('framed payload diagnostics classify exact parsed differences without retaining keys or changing rejection', async () => {
        const cases = [
          ['{"tools":[]}', '{"tools":{}}', 'tools', 'container_type', 'array', 'object'],
          ['{"input":["private_value_a","private_value_b"]}', '{"input":["private_value_b","private_value_a"]}', 'input', 'leaf_value', 'string', 'string'],
          ['{"instructions":"private_value_a"}', '{"instructions":"private_value_b"}', 'instructions', 'leaf_value', 'string', 'string'],
          ['{"metadata":{"private_key":"private_value_a"}}', '{"metadata":{"private_key":"private_value_b"}}', 'metadata', 'leaf_value', 'string', 'string'],
          ['{"private_key":"private_value_a"}', '{"private_key":"private_value_b"}', 'other', 'leaf_value', 'string', 'string'],
          ['{"input":[]}', '{}', 'input', 'object_keys', 'array', 'missing'],
          ['{"tools":[1]}', '{"tools":[]}', 'tools', 'array_length', 'array', 'array'],
          ['{"input":null}', '{"input":true}', 'input', 'leaf_type', 'null', 'boolean'],
        ];
        for (const [expected, rendered, field, kind, expectedType, renderedType] of cases) {
          expect(await rejectedFramedExpansion(expected, rendered)).toMatchObject({
            payloadExpectedFrameUnique: true, payloadRenderedFrameUnique: true,
            payloadExpectedParsed: true, payloadRenderedParsed: true, payloadOutsideFrameMatches: true,
            payloadCompared: true, payloadParsedJSONEqual: false, payloadUnavailableReason: 'none',
            payloadMismatchField: field, payloadMismatchKind: kind,
            payloadExpectedType: expectedType, payloadRenderedType: renderedType,
          });
        }
      });

      test('parsed equality from object reordering or duplicate keys never authorizes an altered expanded prompt', async () => {
        for (const [expected, rendered, reordered] of [
          ['{"tools":[],"input":[],"metadata":{"private_key":"private_value"}}', '{"metadata":{"private_key":"private_value"},"input":[],"tools":[]}', true],
          ['{"instructions":"private_value"}', '{"instructions":"different","instructions":"private_value"}', false],
        ] as const) {
          expect(await rejectedFramedExpansion(expected, rendered)).toMatchObject({
            expansionASCIIPromptMatches: false, payloadCompared: true, payloadParsedJSONEqual: true,
            payloadOutsideFrameMatches: true, payloadObjectKeyOrderChanged: reordered, payloadUnavailableReason: 'none',
            payloadMismatchField: 'none', payloadMismatchKind: 'none', payloadExpectedType: 'none', payloadRenderedType: 'none',
          });
        }
      });

      test('framed payload diagnostics stop within finite frame parse depth node and numeric budgets', async () => {
        const nested = '['.repeat(70) + '0' + ']'.repeat(70);
        const many = '[' + Array(8_200).fill('0').join(',') + ']';
        for (const [rendered, frame, reason, renderedFrame, renderedParsed] of [
          ['{', 'unique', 'parse_failure', true, false],
          ['{"tools":{}}', 'missing', 'missing_frame', false, false],
          ['{"tools":{}}', 'duplicate', 'missing_frame', false, false],
          ['{"tools":' + nested + '}', 'unique', 'bounds', true, true],
          ['{"tools":' + many + '}', 'unique', 'bounds', true, true],
          ['{"tools":9007199254740993}', 'unique', 'number_precision', true, true],
          ['{"tools":1e309}', 'unique', 'number_precision', true, true],
          ['{"tools":"' + 'x'.repeat(181_000) + '"}', 'unique', 'bounds', false, false],
        ] as const) {
          expect(await rejectedFramedExpansion('{"tools":[]}', rendered, frame)).toMatchObject({
            payloadRenderedFrameUnique: renderedFrame, payloadRenderedParsed: renderedParsed,
            payloadCompared: false, payloadParsedJSONEqual: false, payloadObjectKeyOrderChanged: false,
            payloadUnavailableReason: reason, payloadMismatchField: 'none', payloadMismatchKind: 'none',
            payloadExpectedType: 'none', payloadRenderedType: 'none',
          });
        }
      });

      const literalText = (data: any) => ({ nodeType: 3, data });
      const literalElement = (tag: string, children: any[], values: Record<string, string> = {}) => {
        const element = new Node(tag, values);
        element.children = children.filter(child => child.nodeType === 1);
        for (const child of children) child.parentElement = element;
        Object.defineProperty(element, 'childNodes', { get: () => children });
        Object.defineProperty(element, 'textContent', { get: () => children.map(child => child.nodeType === 3
          ? typeof child.data === 'string' ? child.data : '' : child.textContent).join('') });
        return element;
      };
      const publishLiteralDOM = (f: any, rendered: string, children: any[]) => {
        for (const child of children) child.parentElement = f.userBody;
        f.userBody.children = children.filter(child => child.nodeType === 1);
        Object.defineProperty(f.userBody, 'innerText', { get: () => rendered });
        Object.defineProperty(f.userBody, 'textContent', { get: () => children.map(child => child.nodeType === 3
          ? typeof child.data === 'string' ? child.data : '' : child.textContent).join('') });
        Object.defineProperty(f.userBody, 'childNodes', { get: () => children });
      };

      test('literal DOM text BR and paragraph comparisons remain diagnostic when the rendered first body is invalid', async () => {
        for (const kind of ['text', 'br', 'paragraph']) {
          const diagnostic = await rejectedFramedExpansion('{"tools":[]}', '{"tools":{]}', 'unique', (f, prompt, rendered) => {
            const lines = prompt.split('\n');
            const children = kind === 'text' ? [literalText(prompt)] : kind === 'paragraph'
              ? lines.map(line => literalElement('P', [literalText(line)]))
              : lines.flatMap((line, index) => index ? [literalElement('BR', []), literalText(line)] : [literalText(line)]);
            publishLiteralDOM(f, rendered, children);
          });
          expect(diagnostic).toMatchObject({ payloadRenderedParsed: false, literalDOMAvailable: true,
            literalDOMMatchesPrompt: true, literalDOMMatchesRendered: false, literalDOMUnavailableReason: 'none',
            literalDOMFrameUnique: true, literalDOMFrameParsed: true, literalDOMPayloadCompared: true,
            literalDOMParsedJSONEqual: true, literalDOMPayloadUnavailableReason: 'none' });
          expect(diagnostic.literalDOMParagraphCount > 0).toBe(kind === 'paragraph');
          expect(diagnostic.literalDOMBRCount > 0).toBe(kind === 'br');
        }
      });

      test('hidden inert interactive or unsupported literal markup cannot claim a matching source stream', async () => {
        for (const [tag, values, reason] of [
          ['SPAN', { 'aria-hidden': 'true' }, 'hidden_markup'], ['SPAN', { inert: '' }, 'inert_markup'],
          ['BUTTON', {}, 'control_markup'], ['CODE', {}, 'unsupported_markup'], ['DIV', {}, 'unsupported_markup'],
        ] as [string, Record<string, string>, string][]) {
          const diagnostic = await rejectedFramedExpansion('{"tools":[]}', '{"tools":{]}', 'unique', (f, prompt, rendered) => {
            // One sole immediate DIV is now diagnostic-only scaffolding. A
            // second nested DIV must still be rejected without skipping it.
            const children = tag === 'DIV' ? [literalElement('DIV', [literalText(prompt)])] : [literalText(prompt)];
            publishLiteralDOM(f, rendered, [literalElement(tag, children, values)]);
          });
          expect(diagnostic).toMatchObject({ literalDOMAvailable: false, literalDOMMatchesPrompt: false,
            literalDOMMatchesRendered: false, literalDOMUnavailableReason: reason, literalDOMFrameUnique: false,
            literalDOMFrameParsed: false, literalDOMPayloadCompared: false, literalDOMParsedJSONEqual: false,
            literalDOMPayloadUnavailableReason: 'unavailable' });
        }
      });

      test('literal DOM diagnostics retain altered nested text and stop at exact node depth character and read budgets', async () => {
        for (const kind of ['changed', 'nodes', 'depth', 'characters', 'read']) {
          const diagnostic = await rejectedFramedExpansion('{"tools":[]}', '{"tools":{]}', 'unique', (f, prompt, rendered) => {
            let children: any[];
            if (kind === 'changed') children = [literalElement('SPAN', [literalText(prompt.replace('{"tools":[]}', '{"tools":{}}'))])];
            else if (kind === 'nodes') children = Array.from({ length: 8_200 }, () => literalText(''));
            else if (kind === 'depth') {
              let nested = literalElement('SPAN', [literalText(prompt)]);
              for (let i = 0; i < 66; i++) nested = literalElement('SPAN', [nested]);
              children = [nested];
            } else if (kind === 'characters') children = [literalText('x'.repeat(180_201))];
            else children = [literalText(123)];
            publishLiteralDOM(f, rendered, children);
          });
          if (kind === 'changed') expect(diagnostic).toMatchObject({ literalDOMAvailable: true, literalDOMMatchesPrompt: false,
            literalDOMMatchesRendered: false, literalDOMFrameParsed: true, literalDOMPayloadCompared: true,
            literalDOMParsedJSONEqual: false, literalDOMUnavailableReason: 'none' });
          else {
            expect(diagnostic).toMatchObject({ literalDOMAvailable: false, literalDOMMatchesPrompt: false,
              literalDOMMatchesRendered: false, literalDOMUnavailableReason: kind === 'nodes' ? 'node_budget'
                : kind === 'depth' ? 'depth_budget' : kind === 'characters' ? 'character_budget' : 'read_failure',
              literalDOMPayloadUnavailableReason: 'unavailable' });
            if (kind === 'nodes') expect(diagnostic.literalDOMNodeCount).toBe(8_193);
            if (kind === 'depth') expect(diagnostic.literalDOMMaxDepth).toBe(65);
            if (kind === 'characters') expect(diagnostic.literalDOMLength).toBe(180_201);
          }
        }
      });

      test('one delayed expansion waits for an event and binds only the complete exact first body', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
        expand.onClick = () => { expect(f.world.__computaModelFirstExpansion.clicked).toBe(true); dispatched(); };
        let settled = false;
        const pending = f.run('inspect', expansionInput).then((result: any) => { settled = true; return result; });
        await click; await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(f.scheduledDelays.filter((delay: number) => delay > 1_000)).toHaveLength(1);
        rejected(await f.run('inspect', expansionInput)); expect(expand.clicks).toBe(1);
        f.userBody.text = prompt.slice(0, 20_000); notify(f); await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        f.userBody.text = prompt; notify(f);
        const result = await pending;
        expect(result.firstUserVerified).toBe(true); expect(result.firstUserMarkerVerified).toBe(true);
        expect(result.firstUserFingerprint).toMatch(/^[a-f0-9]{64}$/);
        expect(expand.clicks).toBe(1); expect(result.firstUserDebugStructure).not.toContain('PRIVATE');
        expect(JSON.parse(result.firstUserDebugStructure).expansionOutcome).toBe('expanded');
        expect(result.firstUserDebugStructure).not.toContain(firstMarker); noSend(f, picker, send);
        expect((await f.run('inspect', expansionInput)).firstUserVerified).toBe(true); expect(expand.clicks).toBe(1);
      });

      const productRecords = (f: any, records: any[]) => {
        for (const observer of [...f.observers]) observer.callback(records);
      };
      const messageChurn = (f: any, count: number) => Array.from({ length: count }, (_, index) => index % 3 === 0
        ? { type: 'characterData', target: { nodeType: 3, parentElement: f.userBody } }
        : index % 3 === 1 ? { type: 'attributes', target: f.userBody, attributeName: 'class', oldValue: 'PRIVATE OLD CLASS' }
          : { type: 'childList', target: f.userBody, addedNodes: [new Node('SPAN', {}, 'PRIVATE RENDER FRAGMENT')], removedNodes: [] });
      const composerChurn = (f: any, count: number) => Array.from({ length: count }, (_, index) => ({
        type: 'attributes', target: f.composer, attributeName: index % 2 ? 'style' : 'class', oldValue: 'PRIVATE PRESENTATION' }));
      const structuralChurn = (f: any, count: number) => {
        const holder = new Node('DIV'); f.body.append(holder);
        return Array.from({ length: count }, () => {
          const node = new Node('SPAN', {}, 'render'); holder.append(node);
          return { type: 'childList', target: holder, addedNodes: [node], removedNodes: [] };
        });
      };

      test('bounded product analysis completes a full 600-record structural render batch', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; productRecords(f, structuralChurn(f, 600)); };
        const result = await f.run('inspect', expansionInput);
        expect(result.firstUserVerified).toBe(true); expect(f.world.__computaChatProductMode.invalidated).toBe(false);
        noSend(f, picker, send);
      });

      test('complete structural analysis keeps late Work, moved controls and historical relabels negative', async () => {
        for (const kind of ['tracked', 'new_detached', 'late_descendant', 'moved_group', 'new_moved_group', 'new_wrapped_moved_group', 'group_label', 'control_label', 'control_role', 'control_text', 'label_id']) {
          const { f, picker, root, expand, send, prompt } = await collapsed();
          expand.onClick = () => {
            f.userBody.text = prompt; const records: any[] = structuralChurn(f, 600);
            if (kind === 'tracked') records.push({ type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' });
            if (kind === 'new_detached' || kind === 'late_descendant' || kind === 'control_label') {
              const work = new Node('BUTTON', { 'aria-pressed': 'false', ...(kind === 'control_label' ? { 'aria-label': 'Other' } : {}) }, 'Work');
              const added = kind === 'late_descendant' ? new Node('DIV') : work;
              if (kind === 'late_descendant') { added.append(...Array.from({ length: 130 }, () => new Node('SPAN'))); added.append(work); }
              records.push({ type: 'childList', target: f.modeGroup, addedNodes: [added], removedNodes: [] },
                { type: 'attributes', target: work, attributeName: kind === 'control_label' ? 'aria-label' : 'aria-pressed',
                  oldValue: kind === 'control_label' ? 'Work' : 'true' },
                { type: 'childList', target: f.modeGroup, addedNodes: [], removedNodes: [added] });
            }
            if (kind === 'moved_group') {
              f.body.children = f.body.children.filter((node: any) => node !== f.modeGroup); root.append(f.modeGroup);
              records.push({ type: 'childList', target: f.body, addedNodes: [], removedNodes: [f.modeGroup] },
                { type: 'childList', target: root, addedNodes: [f.modeGroup], removedNodes: [] },
                { type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' });
            }
            if (kind === 'group_label') {
              const group = new Node('DIV', { 'aria-label': 'Other' });
              const work = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); group.append(work); f.body.append(group);
              records.push({ type: 'childList', target: f.body, addedNodes: [group], removedNodes: [] },
                { type: 'attributes', target: group, attributeName: 'aria-label', oldValue: 'Composer mode' },
                { type: 'attributes', target: work, attributeName: 'aria-pressed', oldValue: 'true' });
            }
            if (kind === 'new_moved_group' || kind === 'new_wrapped_moved_group') {
              const group = new Node('DIV', { 'aria-label': 'Composer mode' });
              const work = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); group.append(work);
              const mounted = kind === 'new_wrapped_moved_group' ? new Node('DIV') : group;
              if (mounted !== group) mounted.append(group); root.append(mounted);
              records.push({ type: 'childList', target: f.body, addedNodes: [mounted], removedNodes: [] },
                { type: 'attributes', target: work, attributeName: 'aria-pressed', oldValue: 'true' },
                { type: 'childList', target: f.body, addedNodes: [], removedNodes: [mounted] },
                { type: 'childList', target: root, addedNodes: [mounted], removedNodes: [] });
            }
            if (kind === 'control_text') records.push({ type: 'characterData', target: { nodeType: 3, parentElement: f.chatMode }, oldValue: 'Work' });
            if (kind === 'control_role') {
              const work = new Node('DIV', { role: 'group', 'aria-label': 'Work', 'aria-pressed': 'false' });
              records.push({ type: 'childList', target: f.modeGroup, addedNodes: [work], removedNodes: [] },
                { type: 'attributes', target: work, attributeName: 'role', oldValue: 'button' },
                { type: 'attributes', target: work, attributeName: 'aria-pressed', oldValue: 'true' },
                { type: 'childList', target: f.modeGroup, addedNodes: [], removedNodes: [work] });
            }
            if (kind === 'label_id') {
              const label = new Node('SPAN', { id: 'original-label' }, 'Other'), group = new Node('DIV', { 'aria-labelledby': 'original-label' });
              group.append(new Node('BUTTON', { 'aria-pressed': 'true' }, 'Chat'), new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'));
              f.body.append(label, group);
              records.push({ type: 'attributes', target: label, attributeName: 'id', oldValue: 'original-label' },
                { type: 'attributes', target: label, attributeName: 'id', oldValue: 'temporary-label' });
            }
            productRecords(f, records);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          const expected = ['new_moved_group', 'new_wrapped_moved_group', 'group_label', 'control_label', 'control_role', 'control_text', 'label_id'].includes(kind) ? 'product_history_ambiguous' : 'work_selected';
          expect(JSON.parse(result.debugStructure).productProofFailure).toBe(expected);
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('record, child-list, depth and actual traversal limits reject rather than truncate semantic tails', async () => {
        for (const kind of ['records', 'children', 'depth', 'visits']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => {
            f.userBody.text = prompt;
            let records: any[];
            if (kind === 'records') records = Array.from({ length: 4_097 }, () => ({ type: 'attributes', target: f.composer, attributeName: 'aria-busy', oldValue: 'false' }));
            else if (kind === 'children') records = [{ type: 'childList', target: f.body,
              addedNodes: Array.from({ length: 4_097 }, () => new Node('SPAN')), removedNodes: [] }];
            else {
              const root = new Node('DIV'); let node = root;
              for (let i = 0; i < (kind === 'depth' ? 130 : 20); i++) {
                const child = new Node('DIV');
                if (kind === 'visits') node.append(...Array.from({ length: 1_000 }, () => new Node('SPAN')));
                node.append(child); node = child;
              }
              records = [{ type: 'childList', target: f.body, addedNodes: [root], removedNodes: [] }];
            }
            productRecords(f, records);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure).productProofFailure).toBe(kind === 'records' ? 'mutation_overflow' : 'mutation_scan_overflow');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('only exact disjoint editor class and style churn is excluded from the product budget', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; productRecords(f, composerChurn(f, 1_100)); };
        const result = await f.run('inspect', expansionInput);
        expect(result.firstUserVerified).toBe(true); expect(f.world.__computaChatProductMode.invalidated).toBe(false);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('editor presentation exclusion preserves transient Work selection and first-failure phase metadata', async () => {
        for (const attribute of ['aria-pressed', 'aria-checked']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          if (attribute === 'aria-checked') {
            delete f.chatMode.values['aria-pressed']; delete f.workMode.values['aria-pressed'];
            f.chatMode.values.role = 'radio'; f.workMode.values.role = 'radio';
            f.chatMode.values['aria-checked'] = 'true'; f.workMode.values['aria-checked'] = 'false';
          }
          expand.onClick = () => {
            f.userBody.text = prompt;
            const saved = f.world.__computaChatSubmissionState;
            f.world.__computaChatSubmissionState = { document: f.document, owner: f.world.__computaChatProductMode.owner,
              pending: { phase: 'send_claimed' } };
            productRecords(f, [...composerChurn(f, 1_100), { type: 'attributes', target: f.workMode,
              attributeName: attribute, oldValue: 'true' }]);
            f.world.__computaChatSubmissionState.pending.phase = 'verified';
            productRecords(f, [{ type: 'attributes', target: f.composer, attributeName: 'class', oldValue: 'PRIVATE LATER' }]);
            f.world.__computaChatSubmissionState = saved;
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ productProofFailure: 'work_selected',
            productMutationRelevantCount: 1, productMutationIgnoredCount: 1_000,
            productMutationHistogram: { version: 1, phase: 'send_claimed', capped: true,
              types: { attributes: 1_000, childList: 0, characterData: 0, other: 0 },
              scopes: { trackedProduct: 1, message: 0, composer: 1_000, other: 0 },
              composerAttributes: { class: 550, style: 550, other: 0 } } });
          const proof = f.world.__computaChatProductMode, histogram = proof.productMutationHistogram;
          expect(Object.isFrozen(histogram)).toBe(true);
          expect(Object.isFrozen(histogram.composerAttributes)).toBe(true);
          for (const malformed of [
            { ...histogram, phase: 'PRIVATE PHASE' },
            { ...histogram, PRIVATE_EXTRA: 'PRIVATE CONTENT' },
            { ...histogram, types: { ...histogram.types, attributes: 'PRIVATE COUNT' } },
            { ...histogram, scopes: { ...histogram.scopes, other: 1_001 } },
          ]) {
            proof.productMutationHistogram = malformed;
            const again = await f.run('inspect', expansionInput), serialized = JSON.stringify(again);
            expect(serialized).not.toContain('PRIVATE'); expect(serialized).not.toContain('productMutationHistogram');
          }
          proof.productMutationHistogram = histogram;
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('ambiguous editor provenance and oversized or unknown batches retain the conservative budget', async () => {
        for (const kind of ['ancestor', 'tracked', 'duplicate', 'control', 'relabel', 'referenced_label', 'message_referenced_label',
          'message_referenced_label_childlist',
          'editor_label', 'editor_descendant_label', 'editor_ancestor_label', 'reference_limit', 'reference_size',
          'moved', 'unknown', 'unknown_children', 'oversized_children', 'prescan_limit']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => {
            f.userBody.text = prompt;
            const records = composerChurn(f, kind === 'prescan_limit' ? 4_097 : 513);
            if (kind === 'ancestor') records.forEach(record => { record.target = f.body; });
            if (kind === 'tracked') records.forEach(record => { record.target = f.modeGroup; });
            if (kind === 'duplicate') f.body.append(new Node('DIV', { id: 'prompt-textarea', contenteditable: 'true' }));
            if (kind === 'control') f.composer.append(new Node('BUTTON'));
            if (['editor_label', 'editor_descendant_label', 'editor_ancestor_label'].includes(kind)) {
              const id = 'editor-related-label';
              if (kind === 'editor_label') f.composer.values.id = id;
              if (kind === 'editor_descendant_label') f.composer.append(new Node('SPAN', { id }));
              if (kind === 'editor_ancestor_label') f.composer.parentElement.values.id = id;
              // Preserve editor recognition independently of its ID.
              f.composer.values['aria-label'] = 'Ask ChatGPT';
              f.body.append(new Node('DIV', { 'aria-labelledby': id }));
            }
            if (kind === 'reference_limit') for (let i = 0; i < 129; i++) f.body.append(new Node('DIV', { 'aria-labelledby': `label-${i}` }));
            if (kind === 'reference_size') f.body.append(new Node('DIV', { 'aria-labelledby': 'x'.repeat(1_025) }));
            if (kind === 'relabel') records.push({ type: 'attributes', target: f.composer,
              attributeName: 'aria-label', oldValue: 'Composer mode' });
            if (kind === 'referenced_label') records.push({ type: 'attributes', target: f.modeGroup,
              attributeName: 'aria-labelledby', oldValue: 'PRIVATE LABEL ID' });
            if (kind === 'message_referenced_label' || kind === 'message_referenced_label_childlist') {
              f.userBody.values.id = 'transient-label';
              const group = new Node('DIV', { 'aria-labelledby': 'transient-label' });
              const work = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); group.append(work); f.body.append(group);
              records.push(kind === 'message_referenced_label'
                ? { type: 'characterData', target: { nodeType: 3, parentElement: f.userBody }, oldValue: 'Composer mode' } as any
                : { type: 'childList', target: f.userBody, addedNodes: [new Node('SPAN', {}, 'Current label')],
                  removedNodes: [new Node('SPAN', {}, 'Composer mode')] } as any);
              records.push({ type: 'attributes', target: work, attributeName: 'aria-pressed', oldValue: 'true' });
            }
            if (kind === 'moved') records.push({ type: 'childList', target: f.modeGroup,
              addedNodes: [f.composer], removedNodes: [f.composer] } as any);
            if (kind === 'unknown') records.push({ type: 'PRIVATE_UNKNOWN', target: f.composer } as any);
            if (kind === 'unknown_children') records.unshift({ type: 'childList', target: f.modeGroup,
              addedNodes: { length: 1 }, removedNodes: [] } as any);
            if (kind === 'oversized_children') records.push({ type: 'childList', target: f.userBody,
              addedNodes: Array.from({ length: 129 }, () => new Node('SPAN')), removedNodes: [] } as any);
            records.push({ type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' });
            productRecords(f, records);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(['work_selected', 'product_history_ambiguous', 'mutation_overflow', 'mutation_uninspectable', 'mutation_scan_overflow'])
            .toContain(JSON.parse(result.debugStructure).productProofFailure);
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('product provenance ignores more than 512 message-only rendering mutations during first expansion', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; productRecords(f, messageChurn(f, 768)); };
        const result = await f.run('inspect', expansionInput);
        expect(result.firstUserVerified).toBe(true); expect(f.world.__computaChatProductMode.invalidated).toBe(false);
        expect(JSON.parse(result.firstUserDebugStructure).productProofFailure).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('a transient Work selection hidden among message churn still revokes pressed and checked controls', async () => {
        for (const attribute of ['aria-pressed', 'aria-checked']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          if (attribute === 'aria-checked') {
            delete f.chatMode.values['aria-pressed']; delete f.workMode.values['aria-pressed'];
            f.chatMode.values.role = 'radio'; f.workMode.values.role = 'radio';
            f.chatMode.values['aria-checked'] = 'true'; f.workMode.values['aria-checked'] = 'false';
          }
          f.modeGroup.values['aria-hidden'] = 'true';
          expand.onClick = () => {
            f.userBody.text = prompt;
            productRecords(f, [...messageChurn(f, 800), { type: 'attributes', target: f.workMode,
              attributeName: attribute, oldValue: 'true' }]);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ expansionContextFailure: 'product',
            productProofFailure: 'work_selected', productMutationRelevantCount: 1, productMutationIgnoredCount: 800 });
          expect(result.debugStructure).not.toContain('PRIVATE'); expect(f.world.__computaModelFirstProof).toBeUndefined();
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('tracked product groups remain authoritative after moving into a message or detaching', async () => {
        for (const disposition of ['moved', 'detached', 'message_marked']) {
          const { f, picker, root, expand, send, prompt } = await collapsed();
          expand.onClick = () => {
            f.userBody.text = prompt;
            const records = messageChurn(f, 700);
            if (disposition === 'message_marked') {
              f.modeGroup.values['data-user-message-bubble'] = '';
              records.push({ type: 'attributes', target: f.modeGroup, attributeName: 'data-user-message-bubble', oldValue: null });
            } else {
              f.body.children = f.body.children.filter((node: any) => node !== f.modeGroup);
              records.push({ type: 'childList', target: f.body, removedNodes: [f.modeGroup], addedNodes: [] });
              if (disposition === 'moved') {
                root.append(f.modeGroup);
                records.push({ type: 'childList', target: root, removedNodes: [], addedNodes: [f.modeGroup] });
              } else { f.modeGroup.parentElement = null; f.modeGroup.connected = false; }
            }
            records.push({ type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' });
            productRecords(f, records);
          };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(f.world.__computaChatProductMode.invalidated).toBe(true);
          expect(JSON.parse(result.debugStructure).productProofFailure).toBe('work_selected');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('new Work descendants of a tracked group moved into a message cannot escape provenance', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          f.body.children = f.body.children.filter((node: any) => node !== f.modeGroup); root.append(f.modeGroup);
          const oldWork = f.workMode, replacement = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work');
          f.modeGroup.children = f.modeGroup.children.filter((node: any) => node !== oldWork); f.modeGroup.append(replacement);
          productRecords(f, [...messageChurn(f, 600),
            { type: 'childList', target: root, addedNodes: [f.modeGroup], removedNodes: [] },
            { type: 'childList', target: f.modeGroup, addedNodes: [replacement], removedNodes: [oldWork] },
            { type: 'attributes', target: replacement, attributeName: 'aria-pressed', oldValue: 'true' }]);
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure).productProofFailure).toBe('work_selected');
        expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
      });

      test('a Work control mounted in a tracked group then moved into a message retains its observed provenance', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          const replacement = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); root.append(replacement);
          productRecords(f, [...messageChurn(f, 600),
            { type: 'childList', target: f.modeGroup, addedNodes: [replacement], removedNodes: [] },
            { type: 'attributes', target: replacement, attributeName: 'aria-pressed', oldValue: 'true' },
            { type: 'childList', target: f.modeGroup, addedNodes: [], removedNodes: [replacement] },
            { type: 'childList', target: root, addedNodes: [replacement], removedNodes: [] }]);
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure).productProofFailure).toBe('work_selected');
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('a detached conversation-authored product group cannot become trusted while rendering expands', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          const authored = new Node('DIV', { 'aria-label': 'Composer mode' });
          const work = new Node('BUTTON', { 'aria-pressed': 'false' }, 'Work'); authored.append(work); authored.connected = false;
          productRecords(f, [...messageChurn(f, 600),
            { type: 'childList', target: root, addedNodes: [authored], removedNodes: [] },
            { type: 'attributes', target: work, attributeName: 'aria-pressed', oldValue: 'true' },
            { type: 'childList', target: root, addedNodes: [], removedNodes: [authored] }]);
          expect(f.world.__computaChatProductMode.groups.has(authored)).toBe(false);
          expect(f.world.__computaChatProductMode.works.has(work)).toBe(false);
        };
        const result = await f.run('inspect', expansionInput);
        expect(result.firstUserVerified).toBe(true); expect(f.world.__computaChatProductMode.invalidated).toBe(false);
        expect(JSON.parse(result.firstUserDebugStructure).productProofFailure).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('unsupported attributes fail closed and preserve first-cause bounded counts', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          productRecords(f, [...messageChurn(f, 1_100), ...Array.from({ length: 513 }, () => ({
            type: 'attributes', target: f.composer, attributeName: 'data-unknown', oldValue: 'PRIVATE OLD ATTRIBUTE' }))]);
          productRecords(f, [{ type: 'attributes', target: f.workMode, attributeName: 'aria-pressed', oldValue: 'true' }]);
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ productProofFailure: 'mutation_uninspectable',
          productMutationRelevantCount: 1, productMutationIgnoredCount: 1_000 });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('message records adding recognized product groups remain relevant to the mutation budget', async () => {
        const { f, picker, root, expand, send, prompt } = await collapsed();
        expand.onClick = () => {
          f.userBody.text = prompt;
          const group = new Node('DIV', { 'aria-label': 'Composer mode' });
          root.append(group);
          productRecords(f, Array.from({ length: 4_097 }, () => ({ type: 'childList', target: root, addedNodes: [group], removedNodes: [] })));
        };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(['mutation_overflow', 'mutation_scan_overflow']).toContain(JSON.parse(result.debugStructure).productProofFailure);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ productMutationRelevantCount: 1_000, productMutationIgnoredCount: 0 });
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      const moveRoute = (f: any, url: string) => { f.document.URL = url; f.location.pathname = new URL(url).pathname; };
      const continuation = (fromURL: string, toURL: string) => ({ ...expansionInput,
        firstUserExpansionRouteContinuation: [{ fromURL, toURL }] });
      const routeChain = (root: string, local: string, final: string) => ({ ...expansionInput,
        firstUserExpansionRouteContinuation: [{ fromURL: root, toURL: local }, { fromURL: local, toURL: final }] });
      const crossedExpansion = async () => {
        const stage = await collapsed(), fromURL = stage.f.document.URL;
        const toURL = 'https://chatgpt.com/c/local-chatgpt:owned-expansion?temporary-chat=true';
        stage.expand.onClick = () => { stage.f.userBody.text = stage.prompt; moveRoute(stage.f, toURL); };
        const first = await stage.f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure)).toMatchObject({ expansionOutcome: 'context_changed', expansionContextFailure: 'url' });
        return { ...stage, fromURL, toURL };
      };

      test('native-certified first route continues the same expanded body without another click or Send', async () => {
        const { f, picker, expand, send, prompt, fromURL, toURL } = await crossedExpansion();
        const deadline = f.world.__computaModelFirstExpansion.deadline;
        const result = await f.run('inspect', continuation(fromURL, toURL));
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(prompt));
        expect(result.firstUserFingerprint).toBe([...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join(''));
        expect(result.firstUserVerified).toBe(true); expect(JSON.parse(result.firstUserDebugStructure).expansionOutcome).toBe('expanded');
        expect(result.firstUserDebugStructure).not.toContain(fromURL); expect(result.firstUserDebugStructure).not.toContain(toURL);
        expect(f.world.__computaModelFirstExpansion.deadline).toBe(deadline);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('two certified monotonic route edges share the original expansion and absolute deadline', async () => {
        const { f, picker, expand, send, prompt } = await collapsed(), fromURL = f.document.URL;
        const local = 'https://chatgpt.com/c/local-chatgpt:owned-two-edge?temporary-chat=true';
        const final = 'https://chatgpt.com/c/owned-two-edge-public?temporary-chat=true';
        expand.onClick = () => moveRoute(f, local);
        rejected(await f.run('inspect', expansionInput));
        const deadline = f.world.__computaModelFirstExpansion.deadline;
        f.advanceTime(200);
        const pending = f.run('inspect', continuation(fromURL, local)); await Promise.resolve();
        f.userBody.text = prompt; moveRoute(f, final); notify(f);
        const crossed = await pending; rejected(crossed);
        expect(JSON.parse(crossed.debugStructure).expansionContextFailure).toBe('url');
        expect(f.world.__computaModelFirstExpansion.routeURL).toBe(local);
        expect((await f.run('inspect', routeChain(fromURL, local, final))).firstUserVerified).toBe(true);
        expect(f.world.__computaModelFirstExpansion.deadline).toBe(deadline);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('an unconsumed first route receipt survives a native-certified public promotion before the next inspect', async () => {
        const { f, picker, expand, send, fromURL, toURL } = await crossedExpansion();
        const final = 'https://chatgpt.com/c/owned-pre-entry-public?temporary-chat=true';
        const candidate = f.world.__computaModelFirstExpansion, deadline = candidate.deadline;
        expect(candidate.routeURL).toBe(fromURL); moveRoute(f, final); f.advanceTime(200);
        const result = await f.run('inspect', routeChain(fromURL, toURL, final));
        expect(result.firstUserVerified).toBe(true); expect(candidate.routeURL).toBe(final);
        expect(candidate.deadline).toBe(deadline); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        expect(result.firstUserDebugStructure).not.toContain(fromURL);
        expect(result.firstUserDebugStructure).not.toContain(toURL);
        expect(result.firstUserDebugStructure).not.toContain(final);
      });

      test('an exact two-edge chain cannot extend the deadline or rescue changed private lineage', async () => {
        for (const condition of ['deadline', 'owner', 'prompt', 'body', 'product', 'temporary']) {
          const stage = await crossedExpansion(), { f, fromURL, toURL } = stage;
          const final = 'https://chatgpt.com/c/owned-pre-entry-rejected?temporary-chat=true';
          moveRoute(f, final);
          if (condition === 'deadline') f.advanceTime(1_801);
          if (condition === 'owner') f.world.__computaModelOwner = 'PRIVATE WRONG OWNER';
          if (condition === 'prompt') f.world.__computaModelFirstPrompt += 'PRIVATE WRONG PROMPT';
          if (condition === 'body') f.userBody.text = stage.prompt.replace('PRIVATE LONG', 'PRIVATE WRONG');
          if (condition === 'product') { f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false'; }
          if (condition === 'temporary') f.temporary.connected = false;
          const result = await f.run('inspect', routeChain(fromURL, toURL, final));
          if (condition === 'owner') expect(result).toMatchObject({ error: 'document_changed', detail: 'owner_token' });
          else rejected(result);
          expect(JSON.stringify(result)).not.toContain('PRIVATE WRONG');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(stage.expand.clicks).toBe(1);
          noSend(f, stage.picker, stage.send);
        }
      });

      test('empty, discontinuous, repeated and over-budget native receipt chains fail without a new display click', async () => {
        for (const alter of [
          (edges: any[]) => [],
          (edges: any[]) => [edges[0], { ...edges[1], fromURL: 'https://chatgpt.com/c/unrelated-local' }],
          (edges: any[]) => [edges[0], { fromURL: edges[0].toURL, toURL: edges[0].fromURL }],
          (edges: any[]) => [edges[0], edges[0], edges[1]],
          (edges: any[]) => [{ ...edges[0], privateValue: 'PRIVATE EXTRA' }, edges[1]],
          (edges: any[]) => [{ fromURL: edges[0].fromURL, toURL: edges[0].fromURL }, edges[1]],
        ]) {
          const stage = await crossedExpansion(), final = 'https://chatgpt.com/c/owned-chain-invalid?temporary-chat=true';
          moveRoute(stage.f, final);
          const request = routeChain(stage.fromURL, stage.toURL, final);
          request.firstUserExpansionRouteContinuation = alter(request.firstUserExpansionRouteContinuation);
          rejected(await stage.f.run('inspect', request)); expect(stage.f.world.__computaModelFirstProof).toBeUndefined();
          expect(stage.expand.clicks).toBe(1); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('missing, mismatched or malformed continuation authority cannot rescue a consumed route failure', async () => {
        for (const alter of [
          (request: any) => { delete request.firstUserExpansionRouteContinuation; },
          (request: any) => { request.firstUserExpansionRouteContinuation[0].fromURL = 'https://chatgpt.com/c/foreign'; },
          (request: any) => { request.firstUserExpansionRouteContinuation[0].toURL = 'https://chatgpt.com/c/foreign'; },
          (request: any) => { request.firstUserExpansionRouteContinuation[0].extra = true; },
          (request: any) => { request.firstUserExpansionRouteContinuation = true; },
          (request: any) => { request.allowFirstUserExpansion = false; },
          (request: any) => { request.allowFirstUserBinding = false; },
          (request: any) => { request.expectedFirstUserFingerprint = 'a'.repeat(64); },
          (request: any) => { request.firstUserExpansionModelChoice = choice(target); },
        ]) {
          const { f, picker, expand, send, fromURL, toURL } = await crossedExpansion();
          const request = continuation(fromURL, toURL); alter(request);
          rejected(await f.run('inspect', request)); expect(f.world.__computaModelFirstProof).toBeUndefined();
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('certified route continuation preserves body, prompt, count, product and temporary rejection', async () => {
        for (const [predicate, mutate] of [
          ['root', (stage: any) => replaceFirstRoot(stage.f, stage.root, stage.f.userBody)],
          ['prompt', (stage: any) => { stage.f.world.__computaModelFirstPrompt += 'PRIVATE MUTATION'; }],
          ['user_count', (stage: any) => stage.f.appendUser('PRIVATE SECOND MESSAGE')],
          ['temporary', (stage: any) => { stage.f.temporary.connected = false; }],
          ['product', (stage: any) => { stage.f.chatMode.values['aria-pressed'] = 'false'; stage.f.workMode.values['aria-pressed'] = 'true'; }],
        ] as [string, (stage: any) => void][]) {
          const stage = await crossedExpansion(); mutate(stage);
          const result = await stage.f.run('inspect', { ...continuation(stage.fromURL, stage.toURL), expectedUserCounts: [1, 2] });
          rejected(result); expect(JSON.parse(result.debugStructure).expansionContextFailure).toBe(predicate);
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); expect(stage.expand.clicks).toBe(1);
          noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('URL change accompanied by destructive drift is never classified as URL-only continuation', async () => {
        const { f, picker, expand, send, prompt } = await collapsed(), fromURL = f.document.URL;
        const toURL = 'https://chatgpt.com/c/local-chatgpt:owned-and-foreign?temporary-chat=true';
        expand.onClick = () => { f.userBody.text = prompt; moveRoute(f, toURL); f.world.__computaModelFirstPrompt += 'PRIVATE DRIFT'; };
        const first = await f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure).expansionContextFailure).toBe('prompt');
        f.world.__computaModelFirstPrompt = prompt;
        rejected(await f.run('inspect', continuation(fromURL, toURL)));
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('continuation neither extends an expired deadline nor grants cleanup or model-only authority', async () => {
        for (const action of ['expired', 'cleanup', 'stop', 'verifyModel', 'verifyProductMode', 'prepare', 'insert', 'submit']) {
          const { f, picker, expand, send, fromURL, toURL } = await crossedExpansion();
          if (action === 'expired') f.advanceTime(1_801);
          const result = await f.run(action === 'expired' ? 'inspect' : action, continuation(fromURL, toURL)); rejected(result);
          expect(JSON.parse(result.debugStructure).expansionContextFailure).toBe(action === 'expired' ? 'deadline' : 'continuation');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('a URL transition cannot conceal incompatible text and revive it after later restoration', async () => {
        const { f, picker, expand, send, prompt } = await collapsed(), fromURL = f.document.URL;
        const toURL = 'https://chatgpt.com/c/local-chatgpt:text-drift?temporary-chat=true';
        expand.onClick = () => { f.userBody.text = prompt.replace('PRIVATE LONG', 'PRIVATE OTHER'); moveRoute(f, toURL); };
        const first = await f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure).expansionOutcome).toBe('text_mismatch');
        f.userBody.text = prompt;
        rejected(await f.run('inspect', continuation(fromURL, toURL)));
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('synchronous expansion binds without recurring polling or an extra Send', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        expand.onClick = () => { f.userBody.text = prompt; };
        expect((await f.run('inspect', expansionInput)).firstUserVerified).toBe(true);
        expect(expand.clicks).toBe(1); expect(f.scheduledDelays).toHaveLength(0); noSend(f, picker, send);
      });

      test('Markdown delimiter loss rejects expansion while JSON escapes preserve strict ownership', async () => {
        const text = '```swift\\nlet x = 1\\n``` and ```json\\n{}\\n``` and ```text\\nkept\\n```';
        const request = JSON.stringify({ model: 'browser/chatgpt', input: text });
        for (const escaped of [false, true]) {
          const { f, picker, expand, send } = await collapsed();
          const json = escaped ? request.replaceAll('`', '\\u0060') : request;
          expect(JSON.parse(json)).toEqual(JSON.parse(request));
          const outbound = f.userBody.text + 'x'.repeat(10_000) + '\n' + json + '\n\n' + markerLine;
          const rendered = outbound.replaceAll('`', '');
          expect(outbound.length - rendered.length).toBe(escaped ? 0 : 18);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = rendered; };
          const result = await f.run('inspect', expansionInput);
          if (escaped) {
            expect(result.firstUserVerified).toBe(true);
            expect((await f.run('inspect', expansionInput)).firstUserFingerprint).toBe(result.firstUserFingerprint);
            f.userBody.text = rendered.replace('let x = 1', 'let x = 2');
            rejected(await f.run('inspect', expansionInput));
          } else {
            rejected(result);
            expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('text_mismatch');
            expect(f.world.__computaModelFirstProof).toBeUndefined();
          }
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('completed provider rendering binds its actual digest when one whitespace run loses twelve source characters', async () => {
        const { f, picker, expand, send } = await collapsed();
        // The live first-message body was twelve characters shorter than the
        // outbound source after a successful display expansion. Preserve its
        // observed exact 10,240-character prefix and model/product context.
        const prefix = f.userBody.text;
        const suffix = '\nUse schema_0 and schema_1' + '\n'.repeat(13) + markerLine;
        const outbound = prefix + 'x'.repeat(46_593 - prefix.length - suffix.length) + suffix;
        const rendered = outbound.replace(/\n{2,}/g, '\n');
        expect(outbound.length).toBe(46_593); expect(rendered.length).toBe(46_581);
        expect(rendered.startsWith(prefix)).toBe(true); expect(rendered).not.toBe(outbound);
        f.world.__computaModelFirstPrompt = outbound;
        expand.onClick = () => { f.userBody.text = rendered; };
        const result = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) });
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
        const expectedFingerprint = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
        expect(result).toMatchObject({ firstUserVerified: true, firstUserMarkerVerified: true,
          firstUserFingerprint: expectedFingerprint });
        expect(JSON.parse(result.firstUserDebugStructure)).toMatchObject({ textLength: 46_581,
          expansionOutcome: 'expanded', markerFinalLine: true, markerOccurrences: 1,
          snapshot: { rootSame: true, bodySame: true, textSame: true } });
        expect((await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) })).firstUserFingerprint).toBe(expectedFingerprint);
        f.userBody.text = rendered.replace('schema_0', 'foreign_schema');
        rejected(await f.run('inspect', expansionInput));
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('ASCII line breaks inside the captured prefix share the full-message whitespace policy through partial and final rendering', async () => {
        for (const delayed of [false, true]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          const rendered = prompt.replace('PRIVATE LONG', 'PRIVATE ' + '\n'.repeat(15) + 'LONG');
          let clicked!: () => void; const click = new Promise<void>(resolve => { clicked = resolve; });
          expand.onClick = () => { if (!delayed) f.userBody.text = rendered; clicked(); };
          let settled = false;
          const pending = f.run('inspect', expansionInput).then((result: any) => { settled = true; return result; });
          await click; const deadline = f.world.__computaModelFirstExpansion.deadline;
          if (delayed) {
            f.userBody.text = rendered.slice(0, 20_000); notify(f); await Promise.resolve();
            expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
            f.userBody.text = rendered; notify(f);
          }
          const result = await pending;
          expect(result.firstUserVerified).toBe(true);
          expect(JSON.parse(result.firstUserDebugStructure)).toMatchObject({ expansionOutcome: 'expanded',
            expansionTextAnalyzed: true, expansionClicked: true, expansionExactPrefixMatches: false,
            expansionASCIIPrefixMatches: true, expansionASCIIPromptMatches: true, expansionFirstMismatchClass: 'none',
            expansionUnicodeSpaceCount: 0, expansionFormatCount: 0 });
          expect(f.world.__computaModelFirstExpansion.deadline).toBe(deadline);
          const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rendered));
          expect(result.firstUserFingerprint).toBe([...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join(''));
          expect(result.firstUserDebugStructure).not.toContain('PRIVATE'); expect(result.firstUserDebugStructure).not.toContain(firstMarker);
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('prefix punctuation and Unicode whitespace or format changes fail with latched content-free diagnostics and no replay', async () => {
        for (const [replacement, kind, spaces, formats] of [
          ['!', 'punctuation', 0, 0], ['\u00a0', 'unicode_space', 1, 0], ['\u2028', 'unicode_space', 1, 0],
          ['\u2029', 'unicode_space', 1, 0], ['\u200b', 'format', 0, 1], ['\ufeff', 'format', 0, 1],
        ] as [string, string, number, number][]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => { f.userBody.text = replacement === '!' ? prompt.replace('LONG', 'L!NG')
            : prompt.replace('PRIVATE LONG', 'PRIVATE' + replacement + 'LONG'); };
          const result = await f.run('inspect', expansionInput); rejected(result);
          const diagnostic = JSON.parse(result.debugStructure);
          expect(diagnostic).toMatchObject({ expansionOutcome: 'text_mismatch', expansionTextAnalyzed: true,
            expansionClicked: true, expansionExactPrefixMatches: false, expansionASCIIPrefixMatches: false,
            expansionASCIIPromptMatches: false, expansionFirstMismatchClass: kind,
            expansionUnicodeSpaceCount: spaces, expansionFormatCount: formats,
            expansionExpectedUnicodeSpaceCount: 0, expansionExpectedFormatCount: 0, expansionFirstMismatchOffset: replacement === '!' ? 9 : 7 });
          const latched = { ...f.world.__computaModelFirstExpansion.textDiagnostic };
          f.userBody.text = prompt;
          rejected(await f.run('inspect', expansionInput));
          expect(f.world.__computaModelFirstExpansion.textDiagnostic).toEqual(latched);
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('prefix normalization cannot authorize a display click after text changes during the model precheck', async () => {
        const { f, picker, expand, send, prompt } = await collapsed({ genericHeader: true });
        const click = picker.trigger.onClick;
        picker.trigger.onClick = () => { click(); f.userBody.text = prompt.replace('PRIVATE LONG', 'PRIVATE \nLONG'); };
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ expansionOutcome: 'text_mismatch', expansionClicked: false,
          expansionTextAnalyzed: true, expansionASCIIPrefixMatches: true, expansionASCIIPromptMatches: true });
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(0); noSend(f, picker, send);
      });

      test('normalized completion waits for its one actual mutation and retains the same bounded event budget', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        const suffix = '\nUse schema\n\n' + markerLine;
        const body = prompt.slice(0, -('\n\n' + markerLine).length);
        const outbound = body.slice(0, 12_000) + '\n\n\n' + body.slice(12_000) + suffix;
        f.world.__computaModelFirstPrompt = outbound;
        let clicked!: () => void; const click = new Promise<void>(resolve => { clicked = resolve; });
        expand.onClick = () => clicked();
        let settled = false;
        const pending = f.run('inspect', expansionInput).then((result: any) => { settled = true; return result; });
        await click; await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        f.userBody.text = outbound.slice(0, 20_000).replace(/\n{2,}/g, '\n'); notify(f); await Promise.resolve();
        expect(settled).toBe(false); expect(f.world.__computaModelFirstProof).toBeUndefined();
        f.userBody.text = outbound.replace(/\n{2,}/g, '\n'); notify(f);
        expect((await pending).firstUserVerified).toBe(true);
        expect(f.scheduledDelays.filter((delay: number) => delay > 1_000)).toHaveLength(1);
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('completed bodies reject changed exact prefixes, duplicate or nonfinal markers and oversized text', async () => {
        for (const mutate of [
          (text: string) => 'foreign-prefix' + text.slice('foreign-prefix'.length),
          (text: string) => text.replace(/\n\nComputa session marker:/, '\ninline ' + markerLine + '\n\nComputa session marker:'),
          (text: string) => text + '\nPRIVATE TRAILING BODY',
          (text: string) => text.replace(markerLine, markerLine + '-changed'),
          (text: string) => text.slice(0, 10_240) + 'x'.repeat(180_201) + '\n\n' + markerLine,
        ]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expand.onClick = () => { f.userBody.text = mutate(prompt); };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('text_mismatch');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('an intact prefix and final marker cannot excuse changed middle, suffix, whitespace boundaries or Markdown delimiters', async () => {
        for (const mutate of [
          (text: string) => text.slice(0, 15_000) + 'foreign' + text.slice(15_007),
          (text: string) => text.replace('schema_0 and schema_1', 'schema_0 or schema_1'),
          (text: string) => text.replace('schema_0 and schema_1', 'schema_0and schema_1'),
          (text: string) => text.replace('`literal_code`', 'literal_code'),
          (text: string) => text.replace('schema_0 and schema_1', 'schema_0\u00a0and schema_1'),
        ]) {
          const { f, picker, expand, send, prompt } = await collapsed();
          const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema_0 and schema_1 and `literal_code`\n\n' + markerLine);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = mutate(outbound); };
          const result = await f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ markerFinalLine: true, expansionOutcome: 'text_mismatch' });
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('provider-normalized full-body rejection diagnostics use the mutated body and never bind after context or physical node drift', async () => {
        for (const [outcome, mutate] of [
          ['context_changed', ({ f }: any) => { f.document.URL = 'https://chatgpt.com/c/foreign'; }],
          ['context_changed', ({ f }: any) => { f.world.__computaModelOwner = 'foreign'; }],
          ['context_changed', ({ f }: any) => { f.world.__computaModelFirstPrompt += 'PRIVATE DRIFT'; }],
          ['context_changed', ({ f }: any) => { f.temporary.connected = false; }],
          ['context_changed', ({ f }: any) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }],
          ['node_changed', ({ f, root }: any) => replaceFirstRoot(f, root, f.userBody)],
        ] as [string, (stage: any) => void][]) {
          const stage = await collapsed();
          const outbound = stage.prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
          stage.f.world.__computaModelFirstPrompt = outbound;
          const rendered = outbound.replace('\n\n' + markerLine, '\n' + markerLine);
          stage.expand.onClick = () => { stage.f.userBody.text = rendered; mutate(stage); };
          const result = await stage.f.run('inspect', expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure)).toMatchObject({ textLength: rendered.length,
            markerFinalLine: true, expansionOutcome: outcome });
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); expect(stage.expand.clicks).toBe(1);
          noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('normalized display completion cannot bind a different selected model', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
        f.world.__computaModelFirstPrompt = outbound;
        expand.onClick = () => { f.userBody.text = outbound.replace('\n\n' + markerLine, '\n' + markerLine); picker.selected(target); };
        const result = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) });
        expect(result.error).toBe('model_mismatch'); expect(f.world.__computaModelFirstProof).toBeUndefined();
        expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('a rejected consumed claim cannot bind a later full body or grant cleanup authority', async () => {
        for (const fail of [
          ({ f, prompt }: any) => { f.userBody.text = 'foreign-prefix' + prompt.slice('foreign-prefix'.length); },
          () => { throw new Error('PRIVATE FAILED EXPANSION'); },
        ]) {
          const stage = await collapsed(); stage.expand.onClick = () => fail(stage);
          rejected(await stage.f.run('inspect', expansionInput));
          // A late site render must not turn a terminally rejected local claim
          // into ownership on either ordinary inspection or cleanup.
          stage.f.userBody.text = stage.prompt;
          for (const action of ['inspect', 'cleanup']) {
            const result = await stage.f.run(action, { ...expansionInput, allowFirstUserExpansion: false });
            rejected(result); expect(stage.f.world.__computaModelFirstProof).toBeUndefined();
          }
          expect(stage.expand.clicks).toBe(1); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('a timed-out consumed claim cannot bind a late completed body during inspection or cleanup', async () => {
        const { f, picker, expand, send, prompt } = await collapsed();
        let clicked!: () => void; const click = new Promise<void>(resolve => { clicked = resolve; });
        expand.onClick = () => clicked();
        const pending = f.run('inspect', expansionInput); await click; f.flush();
        rejected(await pending); f.userBody.text = prompt;
        for (const action of ['inspect', 'cleanup']) {
          const result = await f.run(action, expansionInput); rejected(result);
          expect(JSON.parse(result.debugStructure).expansionOutcome).toBe('timeout');
        }
        expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });

      test('normalized display cannot bypass disabled controls, including changes during the model precheck', async () => {
        for (const duringAwait of [false, true]) {
          const { f, picker, expand, send, prompt } = await collapsed({ genericHeader: duringAwait });
          const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = outbound.replace('\n\n' + markerLine, '\n' + markerLine); };
          if (duringAwait) {
            const click = picker.trigger.onClick; picker.trigger.onClick = () => { click(); expand.disabled = true; };
          } else expand.disabled = true;
          rejected(await f.run('inspect', expansionInput));
          expect(f.world.__computaModelFirstProof).toBeUndefined(); expect(expand.clicks).toBe(0); noSend(f, picker, send);
        }
      });

      test('a successful expansion awaiting first binding retains its exact full body and physical lineage on later reads', async () => {
        for (const drift of ['none', 'whitespace', 'root']) {
          const { f, picker, root, expand, send, prompt } = await collapsed();
          const outbound = prompt.replace('\n\n' + markerLine, '\nUse schema\n\n' + markerLine);
          const rendered = outbound.replace('\n\n' + markerLine, '\n' + markerLine);
          f.world.__computaModelFirstPrompt = outbound;
          expand.onClick = () => { f.userBody.text = rendered; };
          // Expansion succeeds, but a disallowed final model read prevents
          // first binding; a future read still owes the original full snapshot.
          expect((await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(target) })).error).toBe('model_mismatch');
          expect(f.world.__computaModelFirstProof).toBeUndefined();
          expect(f.world.__computaModelFirstExpansion.outcome).toBe('expanded');
          if (drift === 'whitespace') f.userBody.text = rendered.replace('Use schema', 'Use  schema');
          if (drift === 'root') replaceFirstRoot(f, root, f.userBody);
          const later = await f.run('inspect', { ...expansionInput, expectedModelChoice: choice(initial) });
          if (drift === 'none') expect(later.firstUserVerified).toBe(true);
          else { rejected(later); expect(f.world.__computaModelFirstProof).toBeUndefined(); }
          expect(expand.clicks).toBe(1); noSend(f, picker, send);
        }
      });

      test('an offscreen control scrolls once and must become exposed before its single click', async () => {
        for (const expose of [true, false]) {
          const { f, picker, expand, send, prompt } = await collapsed(); let scrolled = 0;
          expand.getBoundingClientRect = () => ({ left: 0, top: scrolled ? 50 : -100, width: 100, height: 30 });
          expand.scrollIntoView = () => { scrolled++; if (expose) f.setHit(expand); };
          f.setHit(null); expand.onClick = () => { f.userBody.text = prompt; };
          const result = await f.run('inspect', expansionInput);
          expect(scrolled).toBe(1); expect(expand.clicks).toBe(expose ? 1 : 0);
          if (expose) expect(result.firstUserVerified).toBe(true); else rejected(result);
          noSend(f, picker, send);
        }
      });

      test('missing permission, first binding state, marker, prompt or verified model never authorize expansion', async () => {
        for (const [mutate, overrides] of [
          [() => {}, { allowFirstUserExpansion: false }], [() => {}, { allowFirstUserBinding: false }],
          [() => {}, { expectedFirstUserFingerprint: 'a'.repeat(64) }],
          [() => {}, { firstUserExpansionModelChoice: undefined }],
          [(f: any) => { f.world.__computaModelFirstProof = { marker: firstMarker, fingerprint: 'a'.repeat(64) }; }, {}],
          [(f: any) => { f.world.__computaModelFirstSubmitted = false; }, {}],
          [(f: any) => { f.world.__computaModelLastSubmissionCount = 1; }, {}],
          [(f: any) => { f.world.__computaModelFirstMarker = 'foreign'; }, {}],
          [(f: any) => { f.world.__computaModelFirstPrompt = 'PRIVATE DIFFERENT PROMPT\n\n' + markerLine; }, {}],
          [(f: any) => { f.world.__computaModelFirstPrompt = 'x'.repeat(180_001) + '\n\n' + markerLine; }, {}],
          [(f: any) => { f.userBody.text = 'PRIVATE WRONG BODY'; }, {}],
        ] as [(f: any) => void, Record<string, unknown>][]) {
          const { f, picker, expand, send, prompt } = await collapsed(); mutate(f);
          expand.onClick = () => { f.userBody.text = prompt; };
          rejected(await f.run('inspect', { ...expansionInput, ...overrides }));
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstExpansion).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('insert, submit, preparation, model reads, stop and cleanup never expand a first body', async () => {
        for (const action of ['prepare', 'insert', 'sendReady', 'submit', 'verifyModel', 'verifyProductMode', 'stop', 'cleanup']) {
          const { f, picker, expand, send } = await collapsed();
          rejected(await f.run(action, expansionInput));
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstExpansion).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('foreign product, temporary, route, identity and model contexts cannot expand', async () => {
        for (const [mutate, overrides] of [
          [(f: any) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }, {}],
          [(f: any) => { f.temporary.connected = false; }, {}],
          [() => {}, { expectedConversation: 'https://chatgpt.com/c/foreign' }],
          [() => {}, { expectedConversationIdentity: 'PRIVATE FOREIGN IDENTITY' }],
          [() => {}, { firstUserExpansionModelChoice: choice(target) }],
        ] as [(f: any) => void, Record<string, unknown>][]) {
          const { f, picker, expand, send } = await collapsed(); mutate(f);
          rejected(await f.run('inspect', { ...expansionInput, ...overrides }));
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
        }
      });

      test('ambiguous, disabled, hidden, disconnected, obstructed or nonlocal controls are never clicked', async () => {
        for (const mutate of [
          ({ root }: any) => root.append(new Node('BUTTON', { 'aria-label': 'Read more' })),
          ({ expand }: any) => { expand.disabled = true; },
          ({ expand }: any) => { expand.values['aria-disabled'] = 'true'; },
          ({ expand }: any) => { expand.values.hidden = ''; },
          ({ expand }: any) => { expand.values['aria-hidden'] = 'true'; },
          ({ expand }: any) => { expand.connected = false; },
          ({ expand }: any) => { expand.values['aria-label'] = 'PRIVATE OTHER CONTROL'; },
          ({ f }: any) => f.setHit(null),
          ({ expand }: any) => { expand.tagName = 'SUMMARY'; },
          ({ f, root, expand }: any) => { root.children = root.children.filter((node: any) => node !== expand); f.body.append(expand); },
        ]) {
          const stage = await collapsed(); mutate(stage);
          rejected(await stage.f.run('inspect', expansionInput)); expect(stage.expand.clicks).toBe(0);
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('ignored expansion times out once and cannot be replayed by a second inspection', async () => {
        const { f, picker, expand, send } = await collapsed();
        let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
        expand.onClick = () => dispatched();
        const pending = f.run('inspect', expansionInput); await click; f.flush();
        const timedOut = await pending; rejected(timedOut);
        expect(JSON.parse(timedOut.debugStructure).expansionOutcome).toBe('timeout');
        const repeated = await f.run('inspect', expansionInput); rejected(repeated);
        expect(JSON.parse(repeated.debugStructure).expansionOutcome).toBe('timeout');
        expect(expand.clicks).toBe(1); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
      });

      test('document, owner, count, body, prompt and mode drift during expansion retain the original rejection', async () => {
        for (const [outcome, mutate] of [
          ['context_changed', ({ f }: any) => { f.document.URL = 'https://chatgpt.com/c/foreign'; }],
          ['context_changed', ({ f }: any) => { f.world.__computaModelOwner = 'foreign'; }],
          ['context_changed', ({ f }: any) => f.appendUser('PRIVATE SECOND MESSAGE')],
          ['node_changed', ({ f, root }: any) => replaceFirstRoot(f, root, f.userBody)],
          ['context_changed', ({ f }: any) => { f.world.__computaModelFirstPrompt += 'PRIVATE DRIFT'; }],
          ['context_changed', ({ f }: any) => { f.temporary.connected = false; }],
          ['context_changed', ({ f }: any) => { f.chatMode.values['aria-pressed'] = 'false'; f.workMode.values['aria-pressed'] = 'true'; }],
          ['text_mismatch', ({ f }: any) => { f.userBody.text = 'PRIVATE DIFFERENT COMPLETE BODY\n\n' + markerLine; }],
        ] as [string, (stage: any) => void][]) {
          const stage = await collapsed();
          let dispatched!: () => void; const click = new Promise<void>(resolve => { dispatched = resolve; });
          stage.expand.onClick = () => dispatched();
          const pending = stage.f.run('inspect', expansionInput); await click;
          stage.f.userBody.text = stage.prompt; mutate(stage); notify(stage.f);
          const result = await pending; rejected(result); expect(stage.expand.clicks).toBe(1);
          expect(JSON.parse(result.debugStructure).expansionOutcome).toBe(outcome);
          expect(stage.f.world.__computaModelFirstProof).toBeUndefined(); noSend(stage.f, stage.picker, stage.send);
        }
      });

      test('rejected expansion preserves finite model and context causes without admitting clicks or another Send', async () => {
        for (const condition of ['unavailable', 'mismatch', 'owner', 'route', 'product']) {
          const { f, picker, expand, send, prompt } = await collapsed();
          expect(f.world.__computaModelFirstSubmitted).toBe(true); expect(f.world.__computaModelLastSubmissionCount).toBe(0);
          const owner = f.world.__computaModelOwner, url = f.document.URL;
          if (condition === 'unavailable') picker.trigger.disabled = true;
          else if (condition === 'mismatch') picker.selected('High');
          else {
            const open = picker.trigger.onClick;
            picker.trigger.onClick = () => {
              open();
              if (condition === 'owner') f.world.__computaModelOwner = 'PRIVATE FOREIGN OWNER';
              else if (condition === 'route') f.document.URL += '&PRIVATE_ROUTE=1';
              else { f.workMode.values['aria-pressed'] = 'true'; f.chatMode.values['aria-pressed'] = 'false'; }
            };
          }
          const result = await f.run('inspect', expansionInput); rejected(result);
          const diagnostic = JSON.parse(result.debugStructure);
          expect(diagnostic).toMatchObject({ reason: 'marker_not_final', scope: 'marker_validation' });
          if (condition === 'product') {
            expect(diagnostic).toMatchObject({ expansionOutcome: 'context_changed', expansionContextFailure: 'product' });
            expect(diagnostic.expansionModelError).toBeUndefined(); expect(result.modelDiagnostic).toBeUndefined();
          } else {
            expect(diagnostic).toMatchObject({ expansionOutcome: 'model_unverified', expansionModelError:
              condition === 'unavailable' ? 'model_unverified' : condition === 'mismatch' ? 'model_mismatch' : 'document_changed' });
            expect(result.modelDiagnostic).toMatchObject({ kind: 'model_picker_structure', provider: 'chatgpt',
              readContext: { scope: 'action_precheck', action: 'inspect' } });
            expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8_192);
          }
          const serialized = JSON.stringify(result);
          for (const value of ['PRIVATE', prompt, url, owner, firstMarker]) expect(serialized).not.toContain(value);
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
          if (['unavailable', 'mismatch'].includes(condition)) {
            picker.trigger.disabled = false; picker.selected('Medium');
            const repeated = await f.run('inspect', expansionInput); rejected(repeated);
            expect(JSON.parse(repeated.debugStructure).expansionModelError).toBe(diagnostic.expansionModelError);
            expect(repeated.modelDiagnostic).toEqual(result.modelDiagnostic);
            expect(expand.clicks).toBe(0); noSend(f, picker, send);
          }
        }
      });

      test('context drift during the pre-expansion model await prevents even the display click', async () => {
        const { f, picker, expand, send } = await collapsed({ genericHeader: true });
        const click = picker.trigger.onClick; let changed = false;
        picker.trigger.onClick = () => { click(); if (!changed) { changed = true; f.userBody.text += 'PRIVATE DRIFT'; } };
        rejected(await f.run('inspect', expansionInput));
        expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noSend(f, picker, send);
      });

      test('a recognized control in an adjacent foreign card is diagnostic-only and cannot receive expansion authority', async () => {
        const { f, picker, root, expand, send } = await collapsed();
        const parent = root.parentElement, wrapper = new Node('DIV'), foreign = new Node('DIV');
        parent.children = parent.children.filter((node: any) => node !== root);
        root.children = root.children.filter((node: any) => node !== expand); foreign.append(expand);
        wrapper.append(root, foreign); parent.append(wrapper);
        const result = await f.run('inspect', expansionInput); rejected(result);
        expect(JSON.parse(result.debugStructure)).toMatchObject({ scopedExpandControlCount: 1, expansionOutcome: 'unavailable' });
        expect(expand.clicks).toBe(0); noSend(f, picker, send);
      });

      test('a failed dispatch consumes its claim and a later inspection cannot click again', async () => {
        const { f, picker, expand, send } = await collapsed();
        expand.onClick = () => { throw new Error('PRIVATE CONTROL FAILURE'); };
        const first = await f.run('inspect', expansionInput); rejected(first);
        expect(JSON.parse(first.debugStructure).expansionOutcome).toBe('failed');
        rejected(await f.run('inspect', expansionInput)); expect(expand.clicks).toBe(1); noSend(f, picker, send);
      });
    });

    if (provider === 'chatgpt') describe('finite first-user ownership diagnostics', () => {
      const failure = (result: any, reason: string, scope: string, action = 'inspect') => {
        expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
        const diagnostic = JSON.parse(result.debugStructure);
        expect(diagnostic).toMatchObject({ kind: 'first_user_structure', provider: 'chatgpt', reason, scope, action });
        expect(diagnostic.root.classes).toEqual([]); expect(diagnostic.body.classes).toEqual([]);
        expect(diagnostic.descendants).toBeUndefined();
        expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
        return diagnostic;
      };
      const noMutation = (f: any, picker: any) => {
        expect(f.composer.textContent).toBe(''); expect(f.composer.events).toHaveLength(0);
        expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
      };
      for (const [reason, mutate, overrides] of [
        ['marker_invalid', (f: any) => { f.world.__computaModelFirstSubmitted = false; }, { expectedFirstUserMarker: 'PRIVATE INVALID MARKER' }],
        ['submission_unclaimed', (f: any) => { f.world.__computaModelFirstSubmitted = false; f.world.__computaModelFirstMarker = 'foreign'; }, {}],
        ['marker_mismatch', (f: any) => { f.world.__computaModelFirstMarker = 'foreign'; f.userBody.text = ''; }, {}],
        ['body_limit', (f: any) => { f.userBody.text = 'x'.repeat(180_201); }, {}],
        ['marker_not_final', (f: any) => { f.userBody.text = 'Synthetic\n' + markerLine + '\nTrailing control'; }, {}],
        ['marker_duplicate', (f: any) => { f.userBody.text = 'Synthetic\n' + markerLine + '\n' + markerLine; }, {}],
        ['body_empty', (f: any) => { f.userBody.text = markerLine; }, {}],
      ] as [string, (f: any) => void, Record<string, unknown>][]) {
        test(`marker/body rejection retains ${reason} precedence without editor mutation`, async () => {
          const { f, picker } = setup(true); mutate(f);
          failure(await f.run('inspect', overrides), reason, 'marker_validation');
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
        });
      }

      for (const reason of ['marker_mismatch', 'pinned_fingerprint', 'native_fingerprint']) {
        test(`private/native pin rejection identifies ${reason} without exposing pins`, async () => {
          const { f, picker } = setup(true);
          const first = await f.run('inspect');
          const overrides: Record<string, unknown> = {};
          if (reason === 'marker_mismatch') f.world.__computaModelFirstProof.marker = 'PRIVATE PIN MARKER';
          if (reason === 'pinned_fingerprint') f.world.__computaModelFirstProof.fingerprint = '0'.repeat(64);
          if (reason === 'native_fingerprint') overrides.expectedFirstUserFingerprint = 'f'.repeat(64);
          const result = await f.run('inspect', overrides), diagnostic = failure(result, reason, 'binding');
          expect(diagnostic.privatePinPresent).toBe(true); expect(diagnostic.expectedFingerprintPresent).toBe(true);
          expect(diagnostic.pinnedFingerprintMatch).toBe(reason !== 'pinned_fingerprint');
          expect(diagnostic.nativeFingerprintMatch).toBe(reason !== 'native_fingerprint');
          expect(result.debugStructure).not.toContain(first.firstUserFingerprint);
          expect(result.debugStructure).not.toContain('PRIVATE PIN MARKER'); noMutation(f, picker);
        });
      }

      test('an already-present unbound first bubble binds only through the pending first inspect', async () => {
        for (const action of ['verifyModel', 'prepare', 'inspect']) {
          const { f, picker } = setup(true);
          const result = await f.run(action, { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial),
            ...(action === 'inspect' ? { allowFirstUserBinding: false } : {}) });
          expect(failure(result, 'binding_not_authorized', 'binding', action)).toMatchObject({ privatePinPresent: false,
            expectedFingerprintPresent: false, allowFirstUserBinding: action !== 'inspect' });
          expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
        }
        const { f, picker } = setup(true);
        const first = await f.run('inspect', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial) });
        expect(first.firstUserVerified).toBe(true);
        expect(JSON.parse(first.firstUserDebugStructure)).toMatchObject({ kind: 'first_user_structure', reason: 'first_bound',
          scope: 'binding', action: 'inspect', privatePinPresent: true, expectedFingerprintPresent: false });
        const pendingPin = await f.run('inspect', { expectedUserCounts: [0, 1], expectedFirstUserFingerprint: undefined,
          allowFirstUserBinding: true, expectedModelChoice: choice(initial) });
        expect(pendingPin.firstUserFingerprint).toBe(first.firstUserFingerprint);
        expect(pendingPin.firstUserVerified).toBe(true);
        // An outer inspect can establish the JS pin before a nested native
        // recheck adopts it. That eligible recheck must carry the same finite
        // binding diagnostic; native's existing gate logs it exactly once.
        expect(typeof pendingPin.firstUserDebugStructure).toBe('string');
        expect(JSON.parse(pendingPin.firstUserDebugStructure)).toMatchObject({ kind: 'first_user_structure', reason: 'first_bound',
          scope: 'binding', action: 'inspect', privatePinPresent: true, expectedFingerprintPresent: false,
          allowFirstUserBinding: true, pinnedFingerprintMatch: true });
        const bound = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
        expect(bound.firstUserVerified).toBe(true); expect(bound.firstUserDebugStructure).toBeUndefined();
        expect(JSON.parse(bound.debugStructure)).toMatchObject({ articleUsers: 1, articleAssistants: 1 });
        noMutation(f, picker);
      });

      test('missing first message reports absence independently of a present expected fingerprint', async () => {
        const { f, picker } = setup(false);
        const result = await f.run('inspect', { expectedFirstUserFingerprint: 'a'.repeat(64) });
        expect(failure(result, 'first_missing', 'first_missing')).toMatchObject({ userCount: 0,
          root: { tag: 'none' }, body: { tag: 'none' }, privatePinPresent: false, expectedFingerprintPresent: true });
        expect(result.debugStructure).not.toContain('a'.repeat(64)); noMutation(f, picker);
      });

      for (const scope of ['digest', 'model_precheck', 'action_final_guard']) {
        test(`first-body drift reports the ${scope} rejection boundary`, async () => {
          const { f, picker } = setup(true, { genericHeader: true });
          if (scope === 'digest') f.onDigest(() => { f.userBody.text += ' PRIVATE DIGEST DRIFT'; });
          else {
            await f.run('inspect', { expectedModelChoice: choice(initial) });
            const click = picker.trigger.onClick; let opens = 0;
            picker.trigger.onClick = () => {
              const opening = picker.menu.values.hidden !== undefined; click();
              if (opening && ++opens === (scope === 'model_precheck' ? 1 : 2)) f.userBody.text += ' PRIVATE MODEL DRIFT';
            };
          }
          const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
          const diagnostic = failure(result, scope === 'digest' ? 'snapshot_before_action' : 'snapshot_after_action', scope);
          expect(diagnostic.snapshot).toEqual({ rootSame: true, bodySame: true, bodyConnected: true, textSame: false,
            countSame: true, urlSame: true, originSame: true, ownerSame: true });
          expect(result.debugStructure).not.toContain('PRIVATE'); noMutation(f, picker);
        });
      }

      test('replacement after private pin but before native binding remains a strict rejection', async () => {
        const { f, picker } = setup(true, { genericHeader: true });
        await f.run('inspect', { expectedModelChoice: choice(initial) });
        const root = firstRoot(f), body = f.userBody, pin = f.world.__computaModelFirstProof;
        const click = picker.trigger.onClick; let replaced = false;
        picker.trigger.onClick = () => {
          const opening = picker.menu.values.hidden !== undefined; click();
          if (opening && !replaced) { replaced = true; replaceFirstRoot(f, root, body); }
        };
        const result = await f.run('inspect', { expectedModelChoice: choice(initial),
          expectedFirstUserFingerprint: undefined, allowFirstUserBinding: true });
        expect(failure(result, 'snapshot_after_action', 'model_precheck')).toMatchObject({ privatePinPresent: true,
          expectedFingerprintPresent: false, snapshot: { rootSame: false, bodySame: false, bodyConnected: false } });
        expect(f.world.__computaModelFirstProof).toBe(pin); noMutation(f, picker);
      });

      test('outbound first insertion and submission failures expose finite predicate booleans only', async () => {
        for (const action of ['insert', 'submit']) for (const cause of action === 'insert' ? ['submitted', 'marker', 'suffix'] : ['submitted', 'prompt', 'suffix']) {
          const { f, picker } = setup(false), send = new Node('BUTTON', { 'data-testid': 'send-button' });
          f.body.append(send);
          const prompt = 'PRIVATE OUTBOUND PROMPT\n\n' + markerLine + (cause === 'suffix' ? '\nPRIVATE TAIL' : '');
          if (action === 'submit') { f.composer.text = prompt; f.world.__computaModelFirstPrompt = cause === 'prompt' ? 'PRIVATE OTHER PROMPT' : prompt; }
          if (cause === 'submitted') f.world.__computaModelFirstSubmitted = true;
          const result = await f.run(action, { prompt, ...(cause === 'marker' ? { expectedFirstUserMarker: 'PRIVATE INVALID MARKER' } : {}) });
          const diagnostic = failure(result, action === 'insert' ? 'first_insert' : 'first_submit', action === 'insert' ? 'first_insert' : 'first_submit', action);
          expect(diagnostic.submitted).toBe(cause === 'submitted'); expect(diagnostic.markerValid).toBe(cause !== 'marker');
          expect(diagnostic.firstPromptPresent).toBe(action === 'submit');
          expect(diagnostic.firstPromptMatches).toBe(action === 'submit' && cause !== 'prompt');
          expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
          expect(f.composer.textContent).toBe(action === 'submit' ? prompt : '');
          expect(f.composer.events).toHaveLength(0); expect(send.clicks).toBe(0);
          expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
        }
      });

      test('whole-article body fallback reports control-suffix rejection without changing selectors', async () => {
        const { f, picker } = setup(true), root = firstRoot(f);
        f.userBody.values = { 'data-user-message-bubble': '' };
        const result = await f.run('inspect');
        expect(failure(result, 'marker_not_final', 'marker_validation')).toMatchObject({ userCount: 1,
          root: { tag: 'article' }, body: { tag: 'article' }, controlDescendants: 1, markerFinalLine: false });
        expect(root.querySelector('[data-user-message-bubble]')).toBe(f.userBody);
        expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
      });

      for (const kind of ['hidden_tail', 'wrong_body', 'clipped_body']) {
        test(`bounded alternate-body evidence distinguishes ${kind} without admitting or expanding it`, async () => {
          const { f, picker } = setup(true), root = firstRoot(f);
          const prompt = 'PRIVATE FULL PROMPT\n' + 'x'.repeat(14_000) + '\n\n' + markerLine;
          const rendered = kind === 'wrong_body' ? 'PRIVATE WRONG BODY\n' + 'z'.repeat(10_221) : prompt.slice(0, 10_240);
          f.world.__computaModelFirstPrompt = prompt;
          f.userBody.text = kind === 'hidden_tail' ? prompt : rendered;
          Object.defineProperty(f.userBody, 'innerText', { configurable: true, get: () => rendered });
          if (kind === 'wrong_body') root.append(new Node('DIV', { 'data-user-message-bubble': '' }, prompt));
          const expand = new Node('BUTTON', { 'aria-label': 'Show more' }, 'PRIVATE CONTROL CONTENT'); root.append(expand);
          const result = await f.run('inspect'), diagnostic = failure(result, 'marker_not_final', 'marker_validation');
          expect(diagnostic).toMatchObject({ bodySelection: 'whitespace_pre_wrap', textLength: rendered.length,
            bodyInnerTextLength: rendered.length, firstPromptLength: prompt.length, firstPromptAnalyzed: true,
            bodyTextContentAnalyzed: true, rootRenderedAnalyzed: true, rootTextContentAnalyzed: true,
            markerOccurrences: 0, bodyTextContentMarkerOccurrences: kind === 'hidden_tail' ? 1 : 0,
            bodyTextContentMarkerFinalLine: kind === 'hidden_tail',
            rootTextContentMarkerOccurrences: kind === 'clipped_body' ? 0 : 1,
            rootRenderedMarkerOccurrences: kind === 'clipped_body' ? 0 : 1,
            renderedPrefixOfFirstPrompt: kind !== 'wrong_body', scopedExpandControlCount: 1 });
          expect(diagnostic.bodyTextContentLength).toBe(kind === 'hidden_tail' ? prompt.length : rendered.length);
          expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
          expect(expand.clicks).toBe(0); expect(f.world.__computaModelFirstProof).toBeUndefined(); noMutation(f, picker);
        });
      }

      test('body selection diagnostics report existing selector precedence without changing it', async () => {
        for (const [selection, attributes] of [
          ['markdown_user_message', { 'data-markdown-text-style': 'user-message', class: 'whitespace-pre-wrap', 'data-message-author-role': 'user' }],
          ['whitespace_pre_wrap', { class: 'whitespace-pre-wrap', 'data-message-author-role': 'user' }],
          ['author_user', { 'data-message-author-role': 'user' }],
          ['root_fallback', { 'data-user-message-bubble': '' }],
        ] as [string, Record<string, string>][]) {
          const { f, picker } = setup(true); f.userBody.values = attributes;
          const result = await f.run('inspect', { expectedFirstUserMarker: 'invalid' });
          expect(failure(result, 'marker_invalid', 'marker_validation').bodySelection).toBe(selection);
          noMutation(f, picker);
        }
      });

      test('expand-control counts remain exact, physical, uniquely scoped and notification-only', async () => {
        for (const shared of [false, true]) {
          const { f, picker } = setup(true), root = firstRoot(f), parent = root.parentElement;
          const local = new Node('DIV'), known = ['Show more', 'View more', 'Read more', 'Expand']
            .map(label => new Node('BUTTON', { 'aria-label': label }, 'PRIVATE CONTROL CONTENT'));
          parent.children = parent.children.filter((node: any) => node !== root);
          local.append(root, ...known); parent.append(local);
          if (shared) local.append(new Node('ARTICLE', { 'data-turn': 'user' }, 'PRIVATE SIBLING MESSAGE'));
          const hidden = new Node('BUTTON', { 'aria-label': 'Show more', hidden: '' });
          const disconnected = new Node('BUTTON', { 'aria-label': 'View more' }); disconnected.connected = false;
          const arbitrary = new Node('BUTTON', { 'aria-label': 'PRIVATE LABEL Show more' });
          const outside = new Node('BUTTON', { 'aria-label': 'Read more' });
          root.append(hidden, disconnected, arbitrary); f.body.append(outside);
          const result = await f.run('inspect', { expectedFirstUserMarker: 'invalid', expectedUserCounts: [shared ? 2 : 1] });
          expect(failure(result, 'marker_invalid', 'marker_validation').scopedExpandControlCount).toBe(shared ? 0 : 4);
          expect([...known, hidden, disconnected, arbitrary, outside].every(control => control.clicks === 0)).toBe(true);
          expect(result.debugStructure).not.toContain('PRIVATE'); noMutation(f, picker);
        }
      });

      test('expand-control observation does not extend into composer or navigation wrappers', async () => {
        for (const [tag, attributes, wrapperRole] of [
          ['FORM', {}, ''], ['TEXTAREA', {}, ''], ['DIV', { contenteditable: 'true' }, ''],
          ['NAV', {}, ''], ['ASIDE', {}, ''], ['DIV', { role: 'navigation' }, ''],
          ['DIV', { role: 'complementary' }, ''], ['DIV', {}, 'main'],
          ['DIV', {}, 'navigation'], ['DIV', {}, 'complementary'],
        ] as [string, Record<string, string>, string][]) {
          const { f, picker } = setup(true), root = firstRoot(f), parent = root.parentElement;
          const wider = new Node('DIV', wrapperRole ? { role: wrapperRole } : {});
          const inside = new Node('BUTTON', { 'aria-label': 'Show more' });
          const outside = new Node('BUTTON', { 'aria-label': 'Read more' });
          root.append(inside); parent.children = parent.children.filter((node: any) => node !== root);
          wider.append(root, new Node(tag, attributes), outside); parent.append(wider);
          const result = await f.run('inspect', { expectedFirstUserMarker: 'invalid' });
          expect(failure(result, 'marker_invalid', 'marker_validation').scopedExpandControlCount).toBe(1);
          expect(inside.clicks + outside.clicks).toBe(0); noMutation(f, picker);
        }
      });

      test('oversized alternate text is counted with a sentinel but never analyzed as absent marker evidence', async () => {
        const { f, picker } = setup(true), root = firstRoot(f);
        const oversized = 'PRIVATE OVERSIZED TEXT ' + 'x'.repeat(220_001) + '\n' + markerLine;
        Object.defineProperty(f.userBody, 'innerText', { get: () => 'PRIVATE CLIPPED BODY' });
        Object.defineProperty(f.userBody, 'textContent', { get: () => oversized });
        Object.defineProperty(root, 'innerText', { get: () => oversized });
        Object.defineProperty(root, 'textContent', { get: () => oversized });
        f.world.__computaModelFirstPrompt = oversized;
        const result = await f.run('inspect'), diagnostic = failure(result, 'marker_not_final', 'marker_validation');
        expect(diagnostic).toMatchObject({ bodyTextContentLength: 220_001, rootRenderedTextLength: 220_001,
          rootTextContentLength: 220_001, firstPromptLength: 220_001, bodyTextContentAnalyzed: false,
          rootRenderedAnalyzed: false, rootTextContentAnalyzed: false, firstPromptAnalyzed: false });
        for (const prefix of ['bodyTextContent', 'rootRendered', 'rootTextContent']) {
          expect(diagnostic[prefix + 'MarkerOccurrences']).toBeUndefined(); expect(diagnostic[prefix + 'MarkerFinalLine']).toBeUndefined();
        }
        expect(diagnostic.renderedPrefixOfFirstPrompt).toBeUndefined();
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker); noMutation(f, picker);
      });

      test('alternate diagnostic property failures cannot obscure the original first-user rejection', async () => {
        const { f, picker } = setup(true);
        Object.defineProperty(f.userBody, 'innerText', { get: () => 'PRIVATE CLIPPED BODY' });
        Object.defineProperty(f.userBody, 'textContent', { get: () => { throw new Error('PRIVATE ALTERNATE FAILURE'); } });
        const result = await f.run('inspect'), diagnostic = failure(result, 'marker_not_final', 'marker_validation');
        expect(diagnostic.bodySelection).toBeUndefined();
        expect(result.debugStructure).not.toContain('PRIVATE'); noMutation(f, picker);
      });

      test('poisoned content and metadata never escape the finite diagnostic projection', async () => {
        const { f } = setup(true), root = firstRoot(f);
        // Bootstrap the normal product owner before poisoning the diagnostic
        // inputs, while deliberately leaving first-message proof unbound.
        await f.run('inspect', { expectedFirstUserMarker: 'invalid' });
        root.values = { 'data-message-author-role': 'user', id: 'PRIVATE ROOT ID', class: 'PRIVATE ROOT CLASS', 'data-private': 'PRIVATE ATTRIBUTE' };
        root.tagName = 'PRIVATE-TAG-CANARY';
        f.userBody.values = { class: 'whitespace-pre-wrap PRIVATE BODY CLASS', id: 'PRIVATE BODY ID' };
        f.userBody.text = 'PRIVATE PROMPT AND REPLY';
        f.document.URL += '&PRIVATE_URL_CANARY=secret';
        f.world.__computaModelFirstMarker = 'PRIVATE GLOBAL MARKER';
        f.world.__computaModelOwner = 'PRIVATE OWNER TOKEN';
        f.world.__computaModelFirstPrompt = 'PRIVATE STORED PROMPT';
        f.world.__computaModelFirstProof = { marker: 'PRIVATE PIN MARKER', fingerprint: 'PRIVATE PIN HASH' };
        const result = await f.run('inspect', { ownerToken: 'PRIVATE OWNER TOKEN', expectedFirstUserMarker: 'PRIVATE INPUT MARKER',
          expectedFirstUserFingerprint: 'PRIVATE NATIVE HASH', prompt: 'PRIVATE OUTBOUND PROMPT', unknown: 'PRIVATE UNKNOWN' });
        expect(failure(result, 'marker_invalid', 'marker_validation').root).toEqual({ tag: 'other', classes: [] });
        expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
        const allowed = new Set(['kind', 'provider', 'reason', 'scope', 'action', 'userCount', 'root', 'body', 'textLength',
          'lineCount', 'markerFinalLine', 'markerOccurrences', 'controlDescendants', 'submitted', 'markerMatches',
          'markerValid', 'allowFirstUserBinding', 'allowFirstUserExpansion', 'allowBoundFirstUserExpansion', 'allowProvisionalFirstUserExpansion',
          'boundRootSame', 'boundBodySame', 'boundOldRootConnected', 'boundOldBodyConnected', 'boundNativePinMatches',
          'initialExpansionSucceeded', 'initialExpansionCanonicalMatches', 'initialExpansionRootSame', 'initialExpansionBodySame',
          'initialExpansionOldRootConnected', 'initialExpansionOldBodyConnected', 'initialExpansionDeadlineLive', 'recoveryLifecycle',
          'privatePinPresent', 'expectedFingerprintPresent', 'bodySelection',
          'bodyInnerTextLength', 'bodyTextContentLength', 'rootRenderedTextLength', 'rootTextContentLength', 'firstPromptLength',
          'bodyTextContentAnalyzed', 'rootRenderedAnalyzed', 'rootTextContentAnalyzed', 'firstPromptAnalyzed',
          'bodyTextContentMarkerOccurrences', 'rootRenderedMarkerOccurrences', 'rootTextContentMarkerOccurrences',
          'bodyTextContentMarkerFinalLine', 'rootRenderedMarkerFinalLine', 'rootTextContentMarkerFinalLine',
          'renderedPrefixOfFirstPrompt', 'scopedExpandControlCount', 'expansionOutcome', 'expansionContextFailure',
          'productProofFailure', 'productMutationRelevantCount', 'productMutationIgnoredCount', 'productMutationHistogram',
          'expansionTextAnalyzed', 'expansionClicked', 'expansionExactPrefixMatches', 'expansionASCIIPrefixMatches',
          'expansionASCIIPromptMatches', 'expansionASCIIRenderedLength', 'expansionASCIIPrefixLength', 'expansionASCIIPromptLength',
          'expansionUnicodeSpaceCount', 'expansionExpectedUnicodeSpaceCount', 'expansionFormatCount', 'expansionExpectedFormatCount',
          'expansionFirstMismatchClass', 'expansionFirstMismatchOffset', 'expansionAdmissionFailure']);
        expect(Object.keys(JSON.parse(result.debugStructure)).every(key => allowed.has(key))).toBe(true);
        const lifecycle = JSON.parse(result.debugStructure).recoveryLifecycle;
        expect(Object.keys(lifecycle).sort()).toEqual(['path', 'present', 'verified', 'initialRoute', 'outcome',
          'finalizationStage', 'finalizationError', 'urlWitness', 'urlDiscard', 'pendingMatches', 'lastVerifiedMatches',
          'recordPhase', 'contextStateMatches', 'leaseCurrent', 'urlChanged'].sort());
        expect(lifecycle).toMatchObject({ path: 'other', present: false, verified: false, initialRoute: false,
          outcome: 'none', finalizationStage: 'not_reached', finalizationError: 'not_returned', recordPhase: 'none' });
        for (const key of ['present', 'verified', 'initialRoute', 'urlWitness', 'urlDiscard', 'pendingMatches',
          'lastVerifiedMatches', 'contextStateMatches', 'leaseCurrent', 'urlChanged']) expect(typeof lifecycle[key]).toBe('boolean');
        const admission = JSON.parse(result.debugStructure).expansionAdmissionFailure;
        if (admission !== undefined) expect(['suppressed', 'action', 'binding', 'native_pin', 'private_pin', 'claim_spent',
          'user_count', 'submission', 'submission_count', 'marker', 'prompt', 'model_choice', 'text_prefix',
          'frame', 'provider', 'origin', 'owner', 'product', 'temporary', 'root', 'body',
          'conversation_route', 'conversation_identity', 'url']).toContain(admission);
      });

      test('diagnostic construction failure or unknown action retains the original ownership error', async () => {
        for (const broken of ['projection', 'action']) {
          const { f, picker } = setup(true);
          if (broken === 'projection') {
            const query = f.userBody.querySelectorAll.bind(f.userBody);
            f.userBody.querySelectorAll = (selector: string) => {
              if (selector === 'button, [role="button"]') throw new Error('PRIVATE DIAGNOSTIC FAILURE');
              return query(selector);
            };
          }
          const result = await f.run(broken === 'action' ? 'PRIVATE UNKNOWN ACTION' : 'inspect', { expectedFirstUserMarker: 'invalid' });
          expect(result).toEqual({ error: 'conversation_changed', detail: 'first_user_message' }); noMutation(f, picker);
        }
      });
    });

    if (provider === 'claude') test('Claude first-user diagnostics distinguish model-read body drift without private text', async () => {
      const { f, picker } = setup(true, { genericHeader: true });
      await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
      const body = f.userBody, click = picker.trigger.onClick; let changed = false;
      picker.trigger.onClick = () => { click(); if (!changed) { changed = true; body.text += ' PRIVATE BODY CHANGE'; } };
      const result = await f.run('inspect', { expectedUserCounts: [1], expectedModelChoice: choice(initial) });
      expect(result).toMatchObject({ error: 'conversation_changed', detail: 'first_user_message' });
      expect(JSON.parse(result.debugStructure)).toMatchObject({ kind: 'first_user_structure', provider: 'claude',
        root: { tag: 'div', classes: [] }, body: { tag: 'div', classes: [] }, controlDescendants: 0,
        snapshot: { rootSame: true, bodySame: true, bodyConnected: true, textSame: false, identitySame: true, countSame: true,
          urlSame: true, originSame: true, ownerSame: true } });
      expect(Number.isInteger(JSON.parse(result.debugStructure).lineCount)).toBe(true);
      expect(result.debugStructure).not.toContain('PRIVATE'); expect(result.debugStructure).not.toContain(firstMarker);
      expect(result.debugStructure.length).toBeLessThanOrEqual(8192);
    });

    test('generic closed headers freshly read checked family radios after portal unmount', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const result = await advance(f, 'selectModel', { modelChoice: choice(target) });
      expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(target), source: selectionSource } });
      expect(picker.menu.isConnected).toBe(false);
      const selected = picker.options.find((option: any) => option.children[0].text === target);
      expect(selected.clicks).toBe(1);
      for (let i = 0; i < 3; i++) {
        const proof = await f.run('verifyModel', { expectedModelChoice: choice(target) });
        expect(proof.modelEvidence).toMatchObject({ selected: choice(target), source: selectionSource });
        expect(picker.menu.isConnected).toBe(false);
      }
      expect(selected.clicks).toBe(1);
      picker.selected(initial);
      expect(await f.run('verifyModel', { expectedModelChoice: choice(target) })).toMatchObject({ error: 'model_mismatch' });
      expect(selected.clicks).toBe(1);
    });

    test('failed picker reads expose only finite scope and selection flags', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      f.world.__computaModelSelection = { clicked: 'PRIVATE_CLICK_VALUE', settled: 'PRIVATE_SETTLE_VALUE',
        completed: 'PRIVATE_COMPLETE_VALUE', arbitrary: 'PRIVATE_UNRECOGNIZED_FIELD' };
      picker.trigger.onClick = () => {};
      const observing = f.run('verifyModel', { expectedModelChoice: choice(initial) });
      if (provider === 'chatgpt') {
        // Its bootstrap and final guard settle before the inert fixture timer
        // is registered. Expire that one existing 1,800ms deadline explicitly.
        for (let tick = 0; tick < 40; tick++) await Promise.resolve();
        await new Promise(resolve => setImmediate(resolve));
        for (let tick = 0; tick < 40; tick++) await Promise.resolve();
        f.advanceTime(1_801); f.flush();
        for (let tick = 0; tick < 40; tick++) await Promise.resolve();
        f.flush();
      } else {
        for (let tick = 0; tick < 10; tick++) await Promise.resolve();
        f.flush();
      }
      const result = await observing;
      expect(result).toMatchObject({ error: 'model_unverified', modelDiagnostic: { readContext: {
        scope: provider === 'chatgpt' ? 'action_final_guard' : 'action_precheck', action: 'verifyModel', selectionAttemptPresent: true,
        selectionClicked: false, selectionSettled: false, selectionCompleted: false, recoveryEligible: false,
      } } });
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      expect(picker.trigger.clicks).toBe(1);
    });

    if (provider === 'chatgpt') {
      const microtasks = async () => { for (let tick = 0; tick < 40; tick++) await Promise.resolve(); };
      const expire = async (f: any, pending: Promise<any>) => {
        await microtasks(); await new Promise(resolve => setImmediate(resolve));
        await microtasks(); f.advanceTime(1_801); f.flush(); await microtasks(); f.flush(); return pending;
      };
      const arrows = (picker: any) => picker.powerItem.events.filter((event: any) => event.type === 'keydown' && event.key.startsWith('Arrow'));
      const noSelection = (f: any, picker: any) => {
        expect(arrows(picker)).toHaveLength(0);
        expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true);
        expect(f.composer.textContent).toBe(''); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
      };
      const closed = (picker: any, callback: () => void) => {
        const dismiss = picker.menu.onDispatch; let count = 0;
        picker.menu.onDispatch = (event: any) => { dismiss(event); if (event.key === 'Escape' && ++count === 1) callback(); };
      };
      const focusedFirstInstantInsert = async (ignoreEmptyFocusedPicker = false) => {
        const { f, picker } = setup(); picker.selected('Instant'); const expected = choice('Instant');
        // Establish the ordinary real picker proof; this scoped insert must not
        // depend on a preceding focus-only prepare or a seeded private proof.
        expect((await f.run('selectModel', { modelChoice: expected })).selected).toBe(true);
        const prompt = 'Synthetic single-operation first Instant preparation\n\n' + markerLine;
        const selection: any = { anchorNode: f.composer, focusNode: f.composer, removeAllRanges() {}, addRange() {} };
        f.window.getSelection = () => selection;
        f.document.createRange = () => ({ selectNodeContents(node: any) { selection.anchorNode = node; selection.focusNode = node; }, collapse() {} });
        const send = new Node('BUTTON', { 'aria-label': 'Send prompt' }); f.body.append(send);
        const timeline: string[] = [], queued: any[] = [];
        let insertions = 0, focuses = 0, ignoredOpenings = 0, onFocus = () => {};
        const open = picker.trigger.onClick;
        picker.trigger.onClick = () => {
          timeline.push('picker');
          if (ignoreEmptyFocusedPicker && f.document.activeElement === f.composer && !f.composer.textContent) { ignoredOpenings++; return; }
          open();
        };
        f.composer.focus = () => { focuses++; timeline.push('focus'); f.document.activeElement = f.composer; onFocus(); };
        f.composer.onDispatch = (event: any) => { if (event.type === 'input') timeline.push('input'); };
        f.document.execCommand = (command: string, _ui: boolean, text: string) => {
          expect(command).toBe('insertText'); expect(text).toBe(prompt);
          insertions++; timeline.push('literal'); f.composer.text = text;
          // Real execCommand emits its own input event. This inert fixture
          // emulates that browser behavior; an extra adapter dispatch would
          // produce a second event and fail the exact ordering assertions.
          f.composer.dispatchEvent({ type: 'input', bubbles: true, inputType: 'insertText', data: text }); return true;
        };
        // The fixture DOM is inert. Deliver exactly the records produced by a
        // simulated synchronous focus handler through the production observer's
        // takeRecords boundary, rather than calling private proof functions.
        f.world.__computaModelSignal.observer.takeRecords = () => queued.splice(0);
        const request = { prompt, expectedModelChoice: expected, submissionSequence: 1, submissionMarker: firstMarker,
          expectedSubmissionProofs: [], prepareFirstInstantInInsert: true, preparationTiming: true };
        const start = (overrides: Record<string, unknown> = {}, action = 'insert') => f.run(action, { ...request, ...overrides });
        const noInput = () => {
          expect(insertions).toBe(0); expect(f.composer.events.filter((event: any) => event.type === 'input')).toHaveLength(0);
          expect(send.clicks).toBe(0); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
        };
        return { f, picker, expected, prompt, send, timeline, queued, start, noInput,
          onFocus: (callback: () => void) => { onFocus = callback; }, counts: () => ({ insertions, focuses }), ignored: () => ignoredOpenings };
      };
      test('scoped first Instant insert proves the model before focus then performs one literal edit without separate prepare', async () => {
        const x = await focusedFirstInstantInsert(true);
        expect(x.counts()).toEqual({ insertions: 0, focuses: 0 });
        const result = await x.start();
        expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
        expect(result.modelEvidence.selected).toEqual(x.expected);
        expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
        expect(x.timeline).toEqual(['picker', 'focus', 'literal', 'input', 'picker']);
        expect(x.counts()).toEqual({ insertions: 1, focuses: 1 }); expect(x.ignored()).toBe(0);
        expect(x.f.composer.textContent).toBe(x.prompt); expect(x.send.clicks).toBe(0);
        expect(x.f.composer.events.filter((event: any) => event.type === 'input')).toEqual([
          { type: 'input', bubbles: true, inputType: 'insertText', data: x.prompt }]);
        expect(x.f.world.__computaModelFirstSubmitted).toBeUndefined();
        expect(x.f.world.__computaChatSubmissionState.pending).toMatchObject({ sequence: 1, marker: firstMarker, phase: 'prepared' });
      });
      test('scoped first Instant focus rechecks fresh ownership product model and editor before any input', async () => {
        const mutations: [string, (x: any) => void][] = [
          ['user', x => { x.f.appendUser('Foreign focus user'); }],
          ['assistant', x => { x.f.messages.append(new Node('ARTICLE', { 'data-turn': 'assistant' }, 'Foreign focus reply')); }],
          ['owner', x => { x.f.world.__computaModelOwner = 'different-owner'; }],
          ['route', x => { x.f.document.URL = 'https://chatgpt.com/c/foreign-focus'; }],
          ['temporary', x => { x.f.temporary.values['aria-label'] = 'Temporary chat'; }],
          ['work', x => { x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true'; }],
          ['power', x => { x.picker.selected('High'); }],
          ['family', x => {
            x.picker.selected('GPT-5.5');
            x.queued.push(
              { type: 'attributes', target: x.picker.familyOptions[0], attributeName: 'aria-checked', oldValue: 'true' },
              { type: 'attributes', target: x.picker.familyOptions[2], attributeName: 'aria-checked', oldValue: 'false' });
          }],
          ['pin', x => { x.f.world.__computaChatPresetPin = { ...x.f.world.__computaChatPresetPin }; }],
          ['invocation', x => { x.f.world.__computaChatActiveInvocation = {}; }],
          ['duplicate_editor', x => { x.f.body.append(new Node('DIV', { ...x.f.composer.values })); }],
          ['remounted_editor', x => {
            const old = x.f.composer, replacement = new Node('DIV', { ...old.values });
            old.parentElement.children = old.parentElement.children.filter((node: any) => node !== old);
            old.connected = false; old.parentElement = null; x.f.body.append(replacement); x.f.document.activeElement = replacement;
          }],
          ['nonempty_editor', x => { x.f.composer.text = 'Foreign focus draft'; }],
        ];
        for (const [name, mutate] of mutations) {
          const x = await focusedFirstInstantInsert(); x.onFocus(() => mutate(x));
          const result = await x.start();
          expect({ name, error: result.error }).toMatchObject({ name, error: expect.any(String) });
          expect(x.counts().focuses).toBe(1); expect(x.timeline.indexOf('picker')).toBeLessThan(x.timeline.indexOf('focus'));
          x.noInput();
        }
      });
      test('scoped first Instant focus drains Work switch-and-restore records before any input', async () => {
        const x = await focusedFirstInstantInsert();
        x.onFocus(() => {
          x.f.workMode.values['aria-pressed'] = 'true'; x.f.chatMode.values['aria-pressed'] = 'false';
          x.f.workMode.values['aria-pressed'] = 'false'; x.f.chatMode.values['aria-pressed'] = 'true';
          x.queued.push(
            { type: 'attributes', target: x.f.workMode, attributeName: 'aria-pressed', oldValue: 'false' },
            { type: 'attributes', target: x.f.chatMode, attributeName: 'aria-pressed', oldValue: 'true' },
            { type: 'attributes', target: x.f.workMode, attributeName: 'aria-pressed', oldValue: 'true' },
            { type: 'attributes', target: x.f.chatMode, attributeName: 'aria-pressed', oldValue: 'false' });
        });
        const result = await x.start();
        expect(result.error).toBe('product_mode_unverified');
        expect(x.f.world.__computaChatProductMode).toMatchObject({ invalidated: true, invalidationReason: 'work_selected' });
        expect(x.queued).toHaveLength(0); x.noInput();
      });
      test('scoped first Instant focus rejects newly associated family menus even with an unchanged closed Instant header', async () => {
        for (const removed of [false, true]) {
          const x = await focusedFirstInstantInsert();
          x.onFocus(() => {
            const menu = new Node('DIV', { id: 'focus-only-family-menu', role: 'menu', 'aria-labelledby': x.picker.trigger.values.id });
            const other = new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'true' }, 'GPT-5.5'); menu.append(other);
            x.f.body.append(menu);
            x.queued.push({ type: 'childList', target: x.f.body, addedNodes: [menu], removedNodes: [] });
            if (removed) {
              x.f.body.children = x.f.body.children.filter((node: any) => node !== menu); menu.parentElement = null; menu.connected = false;
              x.queued.push({ type: 'childList', target: x.f.body, addedNodes: [], removedNodes: [menu] });
            }
          });
          const result = await x.start();
          expect(result.error).toBe('model_unverified'); expect(x.picker.primary.text).toBe('Instant');
          expect(x.picker.trigger.values['aria-expanded']).toBe('false');
          expect(x.queued).toHaveLength(0); x.noInput();
        }
      });
      test('scoped first Instant focus permits unrelated DOM rendering without another pre-input picker opening', async () => {
        const x = await focusedFirstInstantInsert();
        x.onFocus(() => {
          const status = new Node('DIV', { role: 'status' }, 'Unrelated fixture rendering'); x.f.body.append(status);
          x.queued.push({ type: 'childList', target: x.f.body, addedNodes: [status], removedNodes: [] });
        });
        const result = await x.start();
        expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
        expect(x.queued).toHaveLength(0); expect(x.timeline).toEqual(['picker', 'focus', 'literal', 'input', 'picker']);
        expect(x.counts()).toEqual({ insertions: 1, focuses: 1 }); expect(x.send.clicks).toBe(0);
        expect(x.f.composer.events.filter((event: any) => event.type === 'input')).toEqual([
          { type: 'input', bubbles: true, inputType: 'insertText', data: x.prompt }]);
      });
      test('scoped first Instant preparation rejects invalid native request contexts before focus or input', async () => {
        const invalid: [string, Record<string, unknown>][] = [
          ['other_model', { expectedModelChoice: choice('High') }],
          ['later_sequence', { submissionSequence: 2 }],
          ['other_marker', { submissionMarker: '00000000-0000-4000-8000-000000000009' }],
          ['owned_user', { expectedUserCounts: [1] }],
          ['ambiguous_counts', { expectedUserCounts: [0, 1] }],
          ['retained_proofs', { expectedSubmissionProofs: [{ sequence: 1, fingerprint: 'a'.repeat(64) }] }],
          ['retained_conversation', { expectedConversation: 'https://chatgpt.com/' }],
          ['retained_first_fingerprint', { expectedFirstUserFingerprint: 'a'.repeat(64) }],
        ];
        for (const [name, overrides] of invalid) {
          const x = await focusedFirstInstantInsert(); const result = await x.start(overrides);
          expect({ name, error: result.error }).toMatchObject({ name, error: expect.any(String) });
          expect(x.counts().focuses).toBe(0); x.noInput();
        }
        const action = await focusedFirstInstantInsert();
        expect((await action.start({}, 'prepare')).error).toBe('not_fresh');
        expect(action.counts().focuses).toBe(0); action.noInput();
      });
      const firstInstantReadyRequest = { prepareFirstInstantInInsert: undefined, firstInstantReadinessFinalGuardOnly: true };
      test('first Instant readonly readiness uses one full final model proof and preserves exact editor checks', async () => {
        const x = await focusedFirstInstantInsert(); expect((await x.start()).inserted).toBe(true); x.timeline.length = 0;
        const ready = await x.start(firstInstantReadyRequest, 'sendReady');
        expect(ready.error).toBeUndefined(); expect(ready.sendReady).toBe(true); expect(ready.modelEvidence.selected).toEqual(x.expected);
        expect(ready.preparationTiming.modelPrecheckMs).toBeNull(); expect(ready.preparationTiming.finalGuardMs).not.toBeNull();
        expect(x.timeline).toEqual(['picker']); expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
        x.timeline.length = 0; x.f.composer.text += ' foreign draft';
        const changed = await x.start(firstInstantReadyRequest, 'sendReady');
        expect(changed.error).toBe('prompt_not_inserted'); expect(changed.sendReady).toBeUndefined();
        expect(x.timeline).toEqual([]); expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
      });
      test('first Instant readonly readiness keeps transient disabled Send observational and rechecks after enabling', async () => {
        const x = await focusedFirstInstantInsert(); expect((await x.start()).inserted).toBe(true); x.timeline.length = 0;
        x.send.disabled = true;
        const waiting = await x.start(firstInstantReadyRequest, 'sendReady');
        expect(waiting.error).toBeUndefined(); expect(waiting.sendReady).toBe(false); expect(x.timeline).toEqual(['picker']);
        x.timeline.length = 0; x.send.disabled = false;
        const ready = await x.start(firstInstantReadyRequest, 'sendReady');
        expect(ready.error).toBeUndefined(); expect(ready.sendReady).toBe(true); expect(x.timeline).toEqual(['picker']);
        expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
      });
      test('first Instant readonly readiness requires exact fresh native scope and preserves legacy prechecks', async () => {
        for (const flag of [undefined, false, 1, 'true']) {
          const x = await focusedFirstInstantInsert(); expect((await x.start()).inserted).toBe(true); x.timeline.length = 0;
          const observed = await x.start({ ...firstInstantReadyRequest, firstInstantReadinessFinalGuardOnly: flag }, 'sendReady');
          expect(observed.error).toBeUndefined(); expect(observed.sendReady).toBe(true);
          expect(observed.preparationTiming.modelPrecheckMs).not.toBeNull(); expect(x.timeline).toEqual(['picker', 'picker']);
          expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
        }
        const contexts: [string, Record<string, unknown>, string][] = [
          ['other_model', { expectedModelChoice: choice('High') }, 'sendReady'],
          ['later_sequence', { submissionSequence: 2 }, 'sendReady'],
          ['other_marker', { submissionMarker: '00000000-0000-4000-8000-000000000009' }, 'sendReady'],
          ['retained_counts', { expectedUserCounts: [0, 1] }, 'sendReady'],
          ['retained_proofs', { expectedSubmissionProofs: [{ sequence: 1, fingerprint: 'a'.repeat(64) }] }, 'sendReady'],
          ['retained_conversation', { expectedConversation: 'https://chatgpt.com/' }, 'sendReady'],
          ['retained_first_fingerprint', { expectedFirstUserFingerprint: 'a'.repeat(64) }, 'sendReady'],
          ['pending_model_defer', { deferModelVerification: true }, 'sendReady'],
          ['focus_flag_collision', { prepareFirstInstantInInsert: true }, 'sendReady'],
          ['not_readonly', {}, 'submit'],
        ];
        for (const [name, override, action] of contexts) {
          const x = await focusedFirstInstantInsert(); expect((await x.start()).inserted).toBe(true); x.timeline.length = 0;
          const observed = await x.start({ ...firstInstantReadyRequest, ...override }, action);
          expect({ name, error: observed.error }).toMatchObject({ name, error: expect.any(String) });
          expect(x.timeline).toEqual([]); expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
        }
      });
      test('first Instant readonly readiness rejects ownership product and model drift during its unchanged final proof', async () => {
        for (const drift of ['power', 'family', 'owner', 'route', 'work', 'temporary', 'user']) {
          const x = await focusedFirstInstantInsert(); expect((await x.start()).inserted).toBe(true); x.timeline.length = 0;
          const open = x.picker.trigger.onClick; let changed = false;
          x.picker.trigger.onClick = () => {
            open(); if (changed) return; changed = true;
            if (drift === 'power') x.picker.selected('High');
            if (drift === 'family') x.picker.selected('GPT-5.5');
            if (drift === 'owner') x.f.world.__computaModelOwner = 'different-owner';
            if (drift === 'route') x.f.document.URL = 'https://chatgpt.com/c/foreign-readiness';
            if (drift === 'work') { x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true'; }
            if (drift === 'temporary') x.f.temporary.values['aria-label'] = 'Temporary chat';
            if (drift === 'user') x.f.appendUser('Foreign readiness user');
          };
          const observed = await x.start(firstInstantReadyRequest, 'sendReady');
          expect(changed).toBe(true); expect(observed.error).toBeDefined(); expect(observed.sendReady).toBeUndefined();
          expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
        }
      });
      test('first Instant readonly readiness does not replace submit current-body model or enabled-Send checks', async () => {
        for (const drift of ['text', 'disabled_send', 'model']) {
          const x = await focusedFirstInstantInsert(); expect((await x.start()).inserted).toBe(true);
          expect((await x.start(firstInstantReadyRequest, 'sendReady')).sendReady).toBe(true);
          if (drift === 'text') x.f.composer.text += ' foreign body';
          if (drift === 'disabled_send') x.send.disabled = true;
          if (drift === 'model') x.picker.selected('High');
          const pending = x.f.world.__computaChatSubmissionState.pending;
          const sent = await x.start({ prepareFirstInstantInInsert: undefined,
            expectedSubmissionProofs: [{ sequence: pending.sequence, fingerprint: pending.fingerprint }] }, 'submit');
          expect(sent.error).toBe(drift === 'text' ? 'prompt_not_inserted' : drift === 'model' ? 'model_mismatch' : 'send_unavailable');
          expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
          expect(x.f.world.__computaModelFirstSubmitted).toBeUndefined();
        }
      });
      const firstInsertReadiness = async (ignoreWhenReady = false, rejectClock = false, missing = '') => {
        const { f, picker } = setup(); picker.selected('Instant'); const expected = choice('Instant');
        expect((await f.run('selectModel', { modelChoice: expected })).selected).toBe(true);
        expect((await f.run('prepare', { expectedModelChoice: expected })).prepared).toBe(true);
        const prompt = 'Synthetic editor acknowledgement request\n\n' + markerLine;
        const selection: any = { anchorNode: f.composer, focusNode: f.composer, removeAllRanges() {}, addRange() {} };
        f.window.getSelection = () => selection;
        f.document.createRange = () => ({ selectNodeContents(node: any) { selection.anchorNode = node; selection.focusNode = node; }, collapse() {} });
        let insertions = 0, openings = 0;
        f.document.execCommand = (command: string, _ui: boolean, text: string) => {
          expect(command).toBe('insertText'); expect(text).toBe(prompt); insertions++; f.composer.text = text;
          if (['composer', 'both'].includes(missing)) {
            f.composer.parentElement.children = f.composer.parentElement.children.filter((node: any) => node !== f.composer);
            f.composer.connected = false;
          }
          return true;
        };
        const send = new Node('BUTTON', { 'aria-label': missing === 'voice' ? 'Use voice' : 'Send prompt' });
        send.disabled = missing !== 'voice';
        if (!['send', 'both'].includes(missing)) f.body.append(send);
        const open = picker.trigger.onClick;
        picker.trigger.onClick = () => {
          if (!f.composer.textContent) { open(); return; }
          openings++;
          const currentSend = f.document.querySelectorAll('button[data-testid="send-button"], button[aria-label="Send prompt"]')[0];
          if (currentSend && !currentSend.disabled && !ignoreWhenReady) open();
        };
        const request = { prompt, expectedModelChoice: expected, submissionSequence: 1, submissionMarker: firstMarker,
          expectedSubmissionProofs: [], preparationTiming: true,
          ...(rejectClock ? { operationID: 'a909845c-2857-4b22-a66b-261b22281513' } : {}) };
        if (rejectClock) f.window.webkit.messageHandlers.computaModelClock = {
          postMessage: () => Promise.reject(new Error('PRIVATE_READINESS_CLOCK_CANARY')) };
        let settled = false;
        const inserting = f.run('insert', request).then((value: any) => { settled = true; return value; });
        for (let tick = 0; tick < 20 && (insertions === 0 || !f.world.__computaChatSubmissionState?.pending); tick++) {
          await microtasks(); await new Promise(resolve => setImmediate(resolve));
        }
        await microtasks();
        expect(insertions).toBe(1);
        const state = f.world.__computaChatSubmissionState, pending = state.pending;
        expect(pending.phase).toBe('prepared'); expect(state.lastVerified).toBeNull();
        const notify = (attribute?: string, target?: any) => f.observers.forEach((observer: any) => {
          if (attribute && !(observer.options?.attributes === true && observer.options.attributeFilter?.includes(attribute))) return;
          observer.callback(attribute ? [{ type: 'attributes', attributeName: attribute, target, oldValue: null }] : []);
        });
        const expire = async () => {
          if (!settled) { f.advanceTime(1_801); f.flush(); await microtasks(); f.flush(); await microtasks(); }
          return inserting;
        };
        const noReplay = () => {
          expect(insertions).toBe(1); expect(send.clicks).toBe(0);
          expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
        };
        return { f, picker, expected, prompt, request, send, inserting, state, pending, notify, expire, noReplay,
          openings: () => openings, settled: () => settled };
      };
      test('first Instant insert waits for editor acknowledgement before its sole final picker opening', async () => {
        const x = await firstInsertReadiness();
        // A controlled site ignores picker actions while its Send is disabled.
        // Old ordering opens immediately; no readiness proof is fabricated.
        const before = x.openings();
        x.f.advanceTime(20); x.send.disabled = false; x.notify(); await microtasks();
        if (!x.settled()) { x.f.advanceTime(901); x.f.flush(); await microtasks(); }
        const result = await x.expire();
        expect(before).toBe(0); expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
        expect(result.modelEvidence.selected).toEqual(x.expected); expect(x.openings()).toBe(1);
        expect(result.preparationTiming).toMatchObject({ editorReadyAtEntry: false, openingRecoveryUsed: false });
        expect(typeof result.preparationTiming.editorReadinessMs).toBe('number');
        expect(x.picker.trigger.values['aria-expanded']).toBe('false'); x.noReplay();
      });
      test('first Instant readiness observes initially missing Send and editor mounts before its picker proof', async () => {
        for (const missing of ['send', 'composer', 'both']) {
          const x = await firstInsertReadiness(false, false, missing);
          expect(x.openings()).toBe(0);
          if (['composer', 'both'].includes(missing)) x.f.body.append(new Node('DIV', { ...x.f.composer.values }, x.prompt));
          if (['send', 'both'].includes(missing)) x.f.body.append(x.send);
          x.send.disabled = false; x.notify(); await microtasks();
          const result = await x.expire();
          expect(result.error).toBeUndefined(); expect(result.modelEvidence.selected).toEqual(x.expected);
          expect(result.preparationTiming.editorReadyAtEntry).toBe(false); expect(x.openings()).toBe(1); x.noReplay();
        }
      });
      test('first Instant readiness wakes for a data-testid-only Voice-to-Send transition', async () => {
        const x = await firstInsertReadiness(false, false, 'voice');
        expect(x.openings()).toBe(0); expect(x.send.disabled).toBe(false);
        // No childList, disabled, or aria-label mutation accompanies this.
        x.send.values['data-testid'] = 'send-button'; x.notify('data-testid', x.send); await microtasks();
        const result = await x.expire();
        expect(result.error).toBeUndefined(); expect(result.preparationTiming.editorReadyAtEntry).toBe(false);
        expect(result.modelEvidence.selected).toEqual(x.expected); expect(x.openings()).toBe(1); x.noReplay();
      });
      test('first Instant readiness permits exact current controls to remount without replaying editor input', async () => {
        for (const replacement of ['send', 'composer', 'both']) {
          const x = await firstInsertReadiness();
          let currentSend = x.send;
          if (replacement !== 'composer') {
            currentSend = new Node('BUTTON', { ...x.send.values });
            x.send.parentElement.children = x.send.parentElement.children.filter((node: any) => node !== x.send);
            x.send.connected = false; x.f.body.append(currentSend);
          }
          if (replacement !== 'send') {
            const editor = new Node('DIV', { ...x.f.composer.values }, x.prompt);
            x.f.composer.parentElement.children = x.f.composer.parentElement.children.filter((node: any) => node !== x.f.composer);
            x.f.composer.connected = false; x.f.body.append(editor);
          }
          currentSend.disabled = false; x.notify(); await microtasks();
          const result = await x.expire();
          expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
          expect(result.modelEvidence.selected).toEqual(x.expected); expect(x.openings()).toBe(1);
          expect(currentSend.clicks).toBe(0); x.noReplay();
        }
      });
      test('first Instant readiness rejects ambiguous or wrong-text replacement controls', async () => {
        for (const replacement of ['duplicate_send', 'duplicate_editor', 'wrong_editor']) {
          const x = await firstInsertReadiness();
          if (replacement === 'duplicate_send') x.f.body.append(new Node('BUTTON', { ...x.send.values }));
          else {
            const editor = new Node('DIV', { ...x.f.composer.values }, replacement === 'wrong_editor' ? 'Foreign editor body' : x.prompt);
            if (replacement === 'wrong_editor') {
              x.f.composer.parentElement.children = x.f.composer.parentElement.children.filter((node: any) => node !== x.f.composer);
              x.f.composer.connected = false;
            }
            x.f.body.append(editor);
          }
          x.send.disabled = false; x.notify(); await microtasks();
          expect((await x.expire()).error).toBeDefined(); expect(x.openings()).toBe(0); x.noReplay();
        }
      });
      test('first Instant readiness rejects owner model Work and literal drift without a picker action', async () => {
        for (const mutation of ['owner', 'route', 'invocation', 'power', 'pin', 'work', 'temporary', 'body',
          'fingerprint', 'phase', 'user', 'assistant']) {
          const x = await firstInsertReadiness();
          if (mutation === 'owner') x.f.world.__computaModelOwner = 'different-owner';
          if (mutation === 'route') x.f.document.URL = 'https://chatgpt.com/c/foreign';
          if (mutation === 'invocation') x.f.world.__computaChatActiveInvocation = {};
          if (mutation === 'power') x.picker.selected('High');
          if (mutation === 'pin') x.f.world.__computaChatPresetPin = { ...x.f.world.__computaChatPresetPin };
          if (mutation === 'work') { x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true'; }
          if (mutation === 'temporary') x.f.temporary.connected = false;
          if (mutation === 'body') x.f.composer.text += 'foreign';
          if (mutation === 'fingerprint') x.pending.fingerprint = '0'.repeat(64);
          if (mutation === 'phase') x.pending.phase = 'send_claimed';
          if (mutation === 'user') x.f.body.append(new Node('ARTICLE', { 'data-turn': 'user' }));
          if (mutation === 'assistant') x.f.body.append(new Node('ARTICLE', { 'data-turn': 'assistant' }));
          x.send.disabled = false; x.notify(); await microtasks();
          const result = await x.expire();
          expect(result.error).toBeDefined(); expect(x.openings()).toBe(0); x.noReplay();
        }
      });
      test('first Instant readiness does not renew its deadline or recover an unready editor', async () => {
        for (const missing of ['', 'send', 'composer', 'both']) {
          const x = await firstInsertReadiness(false, false, missing);
          x.f.advanceTime(1_801); x.f.flush(); await microtasks();
          expect((await x.expire()).error).toBe('send_unavailable'); expect(x.openings()).toBe(0); x.noReplay();
        }
      });
      test('first Instant readiness cannot turn a rejected native clock into later positive proof', async () => {
        const x = await firstInsertReadiness(false, true);
        const result = await x.expire();
        expect(result.error).toBe('send_unavailable'); expect(x.openings()).toBe(0);
        x.send.disabled = false; x.notify(); await microtasks();
        expect((await x.inserting).error).toBe('send_unavailable'); expect(x.openings()).toBe(0);
        expect(JSON.stringify(result)).not.toContain('PRIVATE_READINESS_CLOCK_CANARY'); x.noReplay();
      });
      test('first Instant final picker inherits only the readiness budget that remains', async () => {
        const x = await firstInsertReadiness(true);
        x.f.advanceTime(1_000); x.send.disabled = false; x.notify(); await microtasks();
        expect(x.openings()).toBe(1);
        // The model proof gets the remaining ~800ms, not a new1800ms scope.
        const delay = x.f.scheduledDelays.at(-1);
        expect(delay).toBeGreaterThan(0); expect(delay).toBeLessThanOrEqual(800);
        x.f.advanceTime(801); x.f.flush(); await microtasks();
        expect((await x.expire()).error).toBeDefined(); expect(x.openings()).toBe(1); x.noReplay();
      });
      const firstInsertOpening = async (behavior: 'ignore_once' | 'late' | 'never' = 'ignore_once', editorSuffix = '') => {
        const { f, picker } = setup(); picker.selected('Instant');
        const expected = choice('Instant');
        expect((await f.run('selectModel', { modelChoice: expected })).selected).toBe(true);
        expect((await f.run('prepare', { expectedModelChoice: expected })).prepared).toBe(true);
        const prompt = 'Synthetic literal first insert opening request\n\n' + markerLine;
        const selection: any = { anchorNode: f.composer, focusNode: f.composer, removeAllRanges() {}, addRange() {} };
        f.window.getSelection = () => selection;
        f.document.createRange = () => ({ selectNodeContents(node: any) { selection.anchorNode = node; selection.focusNode = node; }, collapse() {} });
        let insertions = 0, openings = 0;
        f.document.execCommand = (command: string, _ui: boolean, text: string) => {
          expect(command).toBe('insertText'); expect(text).toBe(prompt); insertions++; f.composer.text = text + editorSuffix; return true;
        };
        const send = new Node('BUTTON', { 'aria-label': 'Send prompt' }); f.body.append(send);
        const open = picker.trigger.onClick;
        picker.trigger.onClick = () => {
          if (!f.composer.textContent) { open(); return; }
          openings++;
          if (behavior === 'ignore_once' && openings > 1) open();
        };
        const request = { prompt, expectedModelChoice: expected, submissionSequence: 1, submissionMarker: firstMarker,
          expectedSubmissionProofs: [] };
        const inserting = f.run('insert', request);
        for (let tick = 0; tick < 20 && openings === 0; tick++) {
          await microtasks(); await new Promise(resolve => setImmediate(resolve));
        }
        expect(insertions).toBe(1); expect(openings).toBe(1); expect(f.composer.textContent).toBe(prompt + editorSuffix);
        const state = f.world.__computaChatSubmissionState, pending = state.pending;
        expect(pending).toMatchObject({ sequence: 1, marker: firstMarker, canonical: prompt, phase: 'prepared', root: null, body: null });
        expect(state.revoked).toBe(false); expect(state.lastVerified).toBeNull();
        expect(f.world.__computaModelFirstSubmitted).toBeUndefined(); expect(send.clicks).toBe(0);
        return { f, picker, expected, prompt, request, inserting, state, pending, send, open,
          counts: () => ({ insertions, openings }), powerBefore: arrows(picker).length,
          familyBefore: picker.familyOptions.map((node: any) => node.clicks) };
      };
      const finishFirstInsertWait = async (x: any, milliseconds = 901) => {
        x.f.advanceTime(milliseconds); x.f.flush(); await microtasks(); x.f.flush();
      };
      const noFirstInsertReplay = (x: any) => {
        expect(x.counts().insertions).toBe(1); expect(x.send.clicks).toBe(0);
        expect(arrows(x.picker)).toHaveLength(x.powerBefore);
        expect(x.picker.familyOptions.map((node: any) => node.clicks)).toEqual(x.familyBefore);
        expect(x.f.world.__computaModelFirstSubmitted).toBeUndefined();
      };
      test('first insert final guard recovers one ignored opening after exactly one literal insertion', async () => {
        const x = await firstInsertOpening();
        await finishFirstInsertWait(x);
        // Old policy spends the whole original budget on the ignored opening.
        // Advancing the remaining budget makes that old-code failure terminal.
        if (x.counts().openings === 1) await finishFirstInsertWait(x, 901);
        const result = await x.inserting;
        expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
        expect(result.modelEvidence.selected).toEqual(x.expected);
        expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
        expect(x.counts().openings).toBe(2); expect(x.picker.trigger.values['aria-expanded']).toBe('false');
        expect(x.state.pending).toBe(x.pending); expect(x.pending.phase).toBe('prepared'); noFirstInsertReplay(x);
        const before = x.counts().openings;
        const replay = await x.f.run('insert', x.request);
        expect(replay.error).toBeDefined(); expect(x.counts().openings).toBe(before);
        expect(x.state.pending).toBe(x.pending); noFirstInsertReplay(x);
      });
      test('first insert final guard preserves a captured canonical-equal terminal editor line break', async () => {
        const x = await firstInsertOpening('ignore_once', '\n');
        await finishFirstInsertWait(x);
        if (x.counts().openings === 1) await finishFirstInsertWait(x, 901);
        const result = await x.inserting;
        expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
        expect(result.modelEvidence.selected).toEqual(x.expected); expect(x.counts().openings).toBe(2);
        expect(x.f.composer.textContent).toBe(x.prompt + '\n'); noFirstInsertReplay(x);
      });
      test('first insert final guard accepts a late acknowledgement without toggling its opened picker', async () => {
        const x = await firstInsertOpening('late');
        x.open(); await finishFirstInsertWait(x);
        const result = await x.inserting;
        expect(result.error).toBeUndefined(); expect(result.inserted).toBe(true);
        expect(result.modelEvidence.selected).toEqual(x.expected); expect(x.counts().openings).toBe(1);
        expect(x.picker.trigger.values['aria-expanded']).toBe('false'); noFirstInsertReplay(x);
      });
      test('first insert final guard spends its recovery once and keeps the original deadline', async () => {
        const x = await firstInsertOpening('never');
        await finishFirstInsertWait(x); await finishFirstInsertWait(x, 901);
        expect((await x.inserting).error).toBe('model_unverified'); expect(x.counts().openings).toBe(2);
        const before = x.counts().openings;
        const later = x.f.run('verifyModel', { expectedModelChoice: x.expected });
        await finishFirstInsertWait(x, 1_801);
        expect((await later).error).toBe('model_unverified'); expect(x.counts().openings).toBe(before + 1);
        noFirstInsertReplay(x);
      });
      test('first insert final guard rejects context body state and model drift before an opening recovery', async () => {
        for (const mutation of ['owner', 'route', 'invocation', 'composer_body', 'canonical_equal_body', 'composer_node', 'phase', 'sequence', 'marker',
          'pending', 'revoked', 'pin', 'power', 'work', 'temporary', 'user', 'assistant']) {
          const x = await firstInsertOpening();
          if (mutation === 'owner') x.f.world.__computaModelOwner = 'different-owner';
          if (mutation === 'route') x.f.document.URL = 'https://chatgpt.com/c/foreign';
          if (mutation === 'invocation') x.f.world.__computaChatActiveInvocation = {};
          if (mutation === 'composer_body') x.f.composer.text += 'changed';
          if (mutation === 'canonical_equal_body') x.f.composer.text += '\n';
          if (mutation === 'composer_node') {
            const old = x.f.composer, replacement = new Node('DIV', { ...old.values }, x.prompt);
            old.parentElement.children = old.parentElement.children.filter((node: any) => node !== old);
            old.connected = false; x.f.body.append(replacement);
          }
          if (mutation === 'phase') x.pending.phase = 'send_claimed';
          if (mutation === 'sequence') x.pending.sequence = 2;
          if (mutation === 'marker') x.pending.marker = '00000000-0000-4000-8000-000000000009';
          if (mutation === 'pending') x.state.pending = { ...x.pending };
          if (mutation === 'revoked') x.state.revoked = true;
          if (mutation === 'pin') x.f.world.__computaChatPresetPin.invalidated = true;
          if (mutation === 'power') x.picker.selected('High');
          if (mutation === 'work') { x.f.chatMode.values['aria-pressed'] = 'false'; x.f.workMode.values['aria-pressed'] = 'true'; }
          if (mutation === 'temporary') x.f.temporary.values['aria-label'] = 'Temporary chat';
          if (mutation === 'user') x.f.appendUser(x.prompt);
          if (mutation === 'assistant') x.f.messages.append(new Node('ARTICLE', { 'data-turn': 'assistant' }, 'Unexpected answer'));
          await finishFirstInsertWait(x);
          expect((await x.inserting).error).toBeDefined(); expect(x.counts().openings).toBe(1); noFirstInsertReplay(x);
        }
      });
      test('first insert final guard never opens again after the original deadline or native clock rejection', async () => {
        const expired = await firstInsertOpening(); await finishFirstInsertWait(expired, 1_801);
        expect((await expired.inserting).error).toBe('model_unverified'); expect(expired.counts().openings).toBe(1); noFirstInsertReplay(expired);
        const { f, picker } = setup(); picker.selected('Instant'); const expected = choice('Instant');
        expect((await f.run('selectModel', { modelChoice: expected })).selected).toBe(true);
        expect((await f.run('prepare', { expectedModelChoice: expected })).prepared).toBe(true);
        const prompt = 'Synthetic clock failure insert\n\n' + markerLine;
        const selection: any = { anchorNode: f.composer, focusNode: f.composer, removeAllRanges() {}, addRange() {} };
        f.window.getSelection = () => selection;
        f.document.createRange = () => ({ selectNodeContents(node: any) { selection.anchorNode = node; selection.focusNode = node; }, collapse() {} });
        let insertions = 0, openings = 0; const open = picker.trigger.onClick;
        f.document.execCommand = (_command: string, _ui: boolean, text: string) => { insertions++; f.composer.text = text; return true; };
        picker.trigger.onClick = () => { if (f.composer.textContent) openings++; else open(); };
        // This case targets the picker's clock after editor acknowledgement.
        // Keep that intended boundary independent of readiness/mount waiting.
        f.body.append(new Node('BUTTON', { 'aria-label': 'Send prompt' }));
        f.window.webkit.messageHandlers.computaModelClock = { postMessage: () => Promise.reject(new Error('synthetic native clock rejection')) };
        const result = await f.run('insert', { prompt, expectedModelChoice: expected, submissionSequence: 1,
          submissionMarker: firstMarker, expectedSubmissionProofs: [], operationID: 'a909845c-2857-4b22-a66b-261b22281513' });
        expect(result.error).toBe('model_unverified'); expect(insertions).toBe(1); expect(openings).toBe(1);
        expect(arrows(picker)).toHaveLength(0); expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true);
        expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
      });
      test('all five stable intents use the enabled Power item and AX-hidden SPAN metadata with concrete family proof', async () => {
        for (const [index, label] of ['Instant', 'Medium', 'High', 'Extra High', 'Pro'].entries()) {
          const { f, picker } = setup();
          expect(picker.slider.tagName).toBe('SPAN'); expect(picker.powerItem.values['aria-label']).toBe('Power');
          expect(picker.slider.values['aria-label']).toBeUndefined();
          expect(picker.slider.values['aria-hidden']).toBe('true');
          const result = await f.run('selectModel', { modelChoice: choice(label) });
          expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(label), source: selectionSource,
            verification: 'website_selection', chatSelection: { family: { key: 'GPT-6', label: 'GPT-6' },
              power: { key: choice(label).key.slice('chat/latest/'.length), label },
              automaticFamily: { policy: 'highest_offered_plain_gpt', offered: ['GPT-6', 'GPT-5.5'] } } } });
          expect(result.modelEvidence.response).toBeUndefined(); expect(picker.slider.values['aria-valuenow']).toBe(String(index));
          expect(arrows(picker)).toHaveLength(Math.abs(index - 1));
          expect(picker.slider.events).toHaveLength(0);
          expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true);
          expect((await f.run('selectModel', { modelChoice: choice(label) })).selected).toBe(true);
          expect(arrows(picker)).toHaveLength(Math.abs(index - 1));
        }
      });
      test('self and wrapper accessibility suppression below Power preserve all five presets without input on metadata', async () => {
        for (const [attribute, wrapper] of [['inert', false], ['aria-hidden', false], ['inert', true], ['aria-hidden', true]] as const) {
          for (const [index, label] of ['Instant', 'Medium', 'High', 'Extra High', 'Pro'].entries()) {
            const { f, picker } = setup(); delete picker.slider.values['aria-hidden'];
            if (wrapper) {
              const container = new Node('DIV', { [attribute]: attribute === 'inert' ? '' : 'true' });
              picker.powerItem.children = []; container.append(picker.slider); picker.powerItem.append(container);
            } else picker.slider.values[attribute] = attribute === 'inert' ? '' : 'true';
            picker.showPower();
            const diagnostic = (await f.run('modelDiagnostic')).modelDiagnostic.chatPower;
            expect(diagnostic).toMatchObject({ itemEnabled: true, metadataWithinPower: true,
              metadataInertWithinPower: attribute === 'inert', metadataAriaHiddenWithinPower: attribute === 'aria-hidden',
              powerInertAtOrAbove: false, powerAriaHiddenAtOrAbove: false, ordinal: 1 });
            const result = await f.run('selectModel', { modelChoice: choice(label) });
            expect(result).toMatchObject({ selected: true, modelEvidence: { selected: choice(label),
              chatSelection: { family: { key: 'GPT-6', label: 'GPT-6' },
                power: { key: choice(label).key.slice('chat/latest/'.length), label } } } });
            expect(arrows(picker)).toHaveLength(Math.abs(index - 1)); expect(picker.slider.events).toHaveLength(0);
            expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true);
            expect(f.composer.textContent).toBe(''); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
          }
        }
      });
      test('power diagnostics report finite physical metadata without attribute values or page content', async () => {
        const { f, picker } = setup(); picker.showPower();
        picker.slider.values.inert = 'PRIVATE_INERT_VALUE'; picker.slider.values['data-account-id'] = 'PRIVATE_ACCOUNT_VALUE';
        picker.slider.text = 'PRIVATE_METADATA_TEXT';
        const result = await f.run('modelDiagnostic');
        expect(result.modelDiagnostic.chatPower).toEqual({ physicalItemCount: 1, physicalSliderCount: 1,
          itemVisible: true, itemEnabled: true, sliderPhysical: true, sliderInertSelf: true,
          sliderInertAncestor: false, sliderAriaHidden: true, sliderDisabled: false, metadataWithinPower: true,
          metadataInertWithinPower: true, metadataAriaHiddenWithinPower: true,
          powerInertAtOrAbove: false, powerAriaHiddenAtOrAbove: false, shapeRecognized: true, ordinal: 1 });
        expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
        expect(JSON.stringify(result.modelDiagnostic).length).toBeLessThanOrEqual(8192); noSelection(f, picker);
        picker.slider.values['aria-valuenow'] = 'PRIVATE_ORDINAL_VALUE';
        expect((await f.run('modelDiagnostic')).modelDiagnostic.chatPower).toMatchObject({ shapeRecognized: false, ordinal: null });
        expect(JSON.stringify((await f.run('modelDiagnostic')).modelDiagnostic)).not.toContain('PRIVATE');
      });
      test('metadata suppression never excuses inert or aria-hidden Power authority at or above the item', async () => {
        for (const [flag, change] of [
          ['powerInertAtOrAbove', (p: any) => { p.powerItem.values.inert = ''; }],
          ['powerAriaHiddenAtOrAbove', (p: any) => { p.powerItem.values['aria-hidden'] = 'true'; }],
          ['powerInertAtOrAbove', (p: any) => {
            const wrapper = new Node('DIV', { inert: '' }); p.menu.children = []; wrapper.append(p.powerItem); p.menu.append(wrapper, p.secondary);
          }],
          ['powerAriaHiddenAtOrAbove', (p: any) => {
            const wrapper = new Node('DIV', { 'aria-hidden': 'true' }); p.menu.children = []; wrapper.append(p.powerItem); p.menu.append(wrapper, p.secondary);
          }],
        ] as const) {
          const { f, picker } = setup(); picker.showPower(); change(picker);
          const open = picker.trigger.onClick;
          picker.trigger.onClick = () => {
            open();
            // React-style popup remounts must retain this negative fixture's
            // blocked authority instead of removing its ancestor wrapper.
            if (picker.menu.contains(picker.powerItem)) change(picker);
          };
          const diagnostic = (await f.run('modelDiagnostic')).modelDiagnostic.chatPower;
          expect(diagnostic.metadataAriaHiddenWithinPower).toBe(true); expect(diagnostic[flag]).toBe(true);
          expect(diagnostic.sliderPhysical).toBe(true); expect(diagnostic.ordinal).toBeNull();
          const result = await expire(f, f.run('selectModel', { modelChoice: choice(target) }));
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
          expect(result.modelChoices).toBeUndefined(); noSelection(f, picker); expect(picker.slider.events).toHaveLength(0);
        }
      });
      test('foreign-scope or CSS-hidden metadata cannot supply power proof or input authority', async () => {
        for (const change of [
          (p: any) => { p.powerItem.children = []; p.secondary.append(p.slider); },
          (p: any) => { p.slider.values.hidden = ''; },
          (p: any) => {
            const wrapper = new Node('DIV', { hidden: '' }); p.powerItem.children = []; wrapper.append(p.slider); p.powerItem.append(wrapper);
          },
        ]) {
          const { f, picker } = setup(); picker.showPower(); change(picker);
          expect((await f.run('modelDiagnostic')).modelDiagnostic.chatPower).toMatchObject({ metadataWithinPower: false, ordinal: null });
          const result = await expire(f, f.run('selectModel', { modelChoice: choice(target) }));
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined(); noSelection(f, picker);
          expect(picker.slider.events).toHaveLength(0);
        }
      });
      test('Power focus cannot grant input after metadata replacement or power drift', async () => {
        for (const change of [
          (p: any) => { p.selected('Pro'); },
          (p: any) => { p.powerItem.children = []; p.powerItem.append(new Node('SPAN', { ...p.slider.values })); },
        ]) {
          const { f, picker } = setup(); const focus = picker.powerItem.focus;
          picker.powerItem.focus = () => { focus(); change(picker); };
          const result = await f.run('selectModel', { modelChoice: choice(target) });
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
          noSelection(f, picker); expect(picker.slider.events).toHaveLength(0);
        }
      });
      test('unknown closed headers cannot bootstrap input or model selection', async () => {
        for (const label of ['Thinking harder', 'GPT-6', 'GPT-6 Pro', 'High Work', 'PRIVATE_HEADER']) {
          const { f, picker } = setup(); picker.primary.text = label;
          const result = await f.run('selectModel', { modelChoice: choice(target) });
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
          expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
          expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
        }
      });
      test('exact rendered composite headers preserve all five Power and checked family proofs', async () => {
        for (const [index, label] of ['Instant', 'Medium', 'High', 'Extra High', 'Pro'].entries()) {
          const { f, picker } = setup(false, { closedCompositeHeader: true });
          picker.primary.values['aria-hidden'] = 'true';
          const diagnostic = (await f.run('modelDiagnostic')).modelDiagnostic.chatHeader;
          expect(diagnostic.presentation).toBe('generic_power');
          expect(diagnostic.textShape.innerText).toMatchObject({ presentation: 'generic_power', powerOrdinal: 1 });
          const result = await f.run('selectModel', { modelChoice: choice(label) });
          expect(result.selected).toBe(true); expect(result.modelEvidence.selected).toEqual(choice(label));
          expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
          expect(arrows(picker)).toHaveLength(Math.abs(index - 1));
          expect((await f.run('verifyModel', { expectedModelChoice: choice(label) })).modelEvidence.selected).toEqual(choice(label));
          expect(arrows(picker)).toHaveLength(Math.abs(index - 1));
        }
      });
      test('composite positive grammar rejects compact duplicate unknown and family text without textContent authority', async () => {
        for (const label of ['Thinking effortInstant', 'Thinking effort Instant Pro', 'Thinking effort Thinking effort Instant',
          'Thinking effort GPT-6', 'Thinking effort GPT-6 Pro', 'Prefix Thinking effort Instant', 'Thinking effort Instant suffix',
          'thinking effort Instant', 'Thinking effort PRIVATE_POWER']) {
          const { f, picker } = setup(); picker.primary.text = label;
          const result = await f.run('selectModel', { modelChoice: choice(initial) });
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
          expect(result.modelDiagnostic.chatHeader.presentation).toBe('unknown');
          expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
          expect(JSON.stringify(result)).not.toContain('PRIVATE');
        }
        const { f, picker } = setup(); picker.primary.text = 'Thinking effort Instant';
        Object.defineProperty(picker.trigger, 'innerText', { get: () => 'PRIVATE_RENDERED_UNKNOWN' });
        const result = await f.run('selectModel', { modelChoice: choice('Instant') });
        expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
        expect(result.modelDiagnostic.chatHeader.textShape.textContent.presentation).toBe('generic_power');
        expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
        expect(JSON.stringify(result)).not.toContain('PRIVATE');
      });
      test('composite current power contradicting the actual menu or pinned power is never repaired', async () => {
        const first = setup(false, { closedCompositeHeader: true });
        first.picker.primary.text = 'Thinking effort\n\nInstant'; // Actual slider remains Medium.
        const rejected = await first.f.run('selectModel', { modelChoice: choice('Instant') });
        expect(rejected.error).toBe('model_unverified'); noSelection(first.f, first.picker);
        const later = setup(false, { closedCompositeHeader: true }); later.picker.selected('Instant');
        expect((await later.f.run('selectModel', { modelChoice: choice('Instant') })).selected).toBe(true);
        const opens = later.picker.trigger.clicks; later.picker.primary.text = 'Thinking effort\n\nPro';
        expect((await later.f.run('verifyModel', { expectedModelChoice: choice('Instant') })).error).toBe('model_mismatch');
        expect(later.picker.trigger.clicks).toBe(opens); noSelection(later.f, later.picker);
      });
      test('composite suppressed header text drift restored in one batch invalidates its pin', async () => {
        for (const attribute of ['aria-hidden', 'inert']) {
          const { f, picker } = setup(false, { closedCompositeHeader: true }); picker.selected('Instant');
          picker.primary.values[attribute] = attribute === 'inert' ? '' : 'true';
          expect((await f.run('selectModel', { modelChoice: choice('Instant') })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin, opens = picker.trigger.clicks;
          pin.headerObserver.callback([{ type: 'characterData', target: { nodeType: 3,
            parentElement: picker.primary, textContent: 'Thinking effort\n\nInstant' }, oldValue: 'Thinking effort\n\nPro' }]);
          expect(pin.invalidationReason).toBe('header_mutation');
          expect((await f.run('verifyModel', { expectedModelChoice: choice('Instant') })).error).toBe('model_mismatch');
          expect(picker.trigger.clicks).toBe(opens); noSelection(f, picker);
        }
      });
      test('split composite subtree drift retains detached header lineage but ignores a foreign subtree', async () => {
        for (const attribute of ['aria-hidden', 'inert']) for (const foreign of [false, true]) {
          const { f, picker } = setup(false, { closedCompositeHeader: true }); picker.selected('Instant');
          expect((await f.run('selectModel', { modelChoice: choice('Instant') })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin, original = picker.primary;
          const parent = foreign ? f.body : picker.trigger;
          const wrong = new Node('SPAN', { [attribute]: attribute === 'inert' ? '' : 'true' });
          wrong.append(new Node('SPAN', {}, 'Thinking effort'), new Node('SPAN', {}, 'Pro'));
          expect(wrong.textContent).toBe('Thinking effortPro');
          // The current DOM is restored; only ordered childList records retain
          // the temporary composite's exact original header ancestry.
          const records: any[] = [];
          if (!foreign) {
            parent.children = []; original.parentElement = null;
            records.push({ type: 'childList', target: parent, addedNodes: [], removedNodes: [original] });
          }
          parent.append(wrong); records.push({ type: 'childList', target: parent, addedNodes: [wrong], removedNodes: [] });
          parent.children = parent.children.filter((node: any) => node !== wrong); wrong.parentElement = null; wrong.connected = false;
          records.push({ type: 'childList', target: parent, addedNodes: [], removedNodes: [wrong] });
          if (!foreign) {
            parent.append(original); records.push({ type: 'childList', target: parent, addedNodes: [original], removedNodes: [] });
          }
          pin.headerObserver.callback(records);
          expect(pin.invalidated === true).toBe(!foreign);
          const result = await f.run('verifyModel', { expectedModelChoice: choice('Instant') });
          if (foreign) expect(result.modelEvidence.selected).toEqual(choice('Instant'));
          else expect(result.error).toBe('model_mismatch');
          noSelection(f, picker);
        }
      });
      const pendingEmptyHeader = async (generic = false) => {
        const { f, picker } = setup(false, { closedGenericHeader: generic, resetToPowerOnClose: true });
        picker.selected('Instant'); picker.primary.text = '';
        const clocks: { milliseconds: number; expire: () => void }[] = [];
        let registered!: () => void;
        const registration = new Promise<void>(resolve => { registered = resolve; });
        f.window.webkit.messageHandlers.computaModelClock = { postMessage: (body: any) => new Promise(resolve => {
          clocks.push({ milliseconds: body.milliseconds, expire: () => resolve(true) }); registered();
        }) };
        const pending = f.run('selectModel', { modelChoice: choice('Instant'),
          operationID: '95e24632-2eb6-4cd6-b30f-17ab208c2fbd' });
        await registration;
        expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
        expect(clocks).toHaveLength(1); expect(clocks[0].milliseconds).toBeLessThanOrEqual(1_800);
        const wake = () => { for (const observer of [...f.observers]) observer.callback([
          { type: 'childList', target: picker.primary, addedNodes: [], removedNodes: [] }]); };
        return { f, picker, clocks, pending, wake };
      };
      test('an empty initial header waits without input then requires full canonical or generic menu proof', async () => {
        for (const generic of [false, true]) {
          const x = await pendingEmptyHeader(generic);
          x.picker.primary.text = generic ? 'Thinking effort' : 'Instant'; x.wake();
          const result = await x.pending;
          expect(result.selected).toBe(true); expect(result.modelEvidence.selected).toEqual(choice('Instant'));
          expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
          expect(result.modelDiagnostic.chatHeader.readiness).toEqual({ startedEmpty: true, outcome: 'recognized', reason: null });
          expect(x.picker.trigger.clicks).toBe(generic ? 2 : 1); noSelection(x.f, x.picker);
        }
      });
      test('empty initial header timeout never opens the picker or renews the proof deadline', async () => {
        const empty = await pendingEmptyHeader();
        empty.f.advanceTime(1_801); empty.clocks[0].expire();
        const timeout = await empty.pending;
        expect(timeout.error).toBe('model_unverified'); expect(timeout.modelEvidence).toBeUndefined();
        expect(timeout.modelDiagnostic.chatHeader.readiness).toEqual({ startedEmpty: true, outcome: 'rejected', reason: 'deadline' });
        expect(empty.picker.trigger.clicks).toBe(0); noSelection(empty.f, empty.picker);
        const late = await pendingEmptyHeader();
        late.f.advanceTime(1_700); late.picker.trigger.onClick = () => {};
        late.picker.primary.text = 'Instant'; late.wake(); await microtasks();
        expect(late.clocks).toHaveLength(2); expect(late.clocks[1].milliseconds).toBeLessThanOrEqual(100);
        late.f.advanceTime(101); late.clocks[1].expire();
        expect((await late.pending).error).toBe('model_unverified');
        expect(late.picker.trigger.clicks).toBe(1); noSelection(late.f, late.picker);
      });
      test('empty header wake rejects unknown text identity ownership ambiguity and new effects immediately', async () => {
        for (const condition of ['unknown', 'replacement', 'owner', 'disabled', 'ambiguous', 'open', 'pin', 'action']) {
          const x = await pendingEmptyHeader();
          if (condition === 'unknown') x.picker.primary.text = 'PRIVATE_UNKNOWN_HEADER';
          if (condition === 'replacement') x.picker.replaceTrigger();
          if (condition === 'owner') x.f.world.__computaModelOwner = 'PRIVATE_FOREIGN_OWNER';
          if (condition === 'disabled') x.picker.trigger.disabled = true;
          if (condition === 'ambiguous') x.f.body.append(new Node('BUTTON', { ...x.picker.trigger.values }));
          if (condition === 'open') x.picker.trigger.values['aria-expanded'] = 'true';
          if (condition === 'pin') x.f.world.__computaChatPresetPin = {};
          if (condition === 'action') x.f.world.__computaModelSelection.powerEvents = 1;
          x.wake();
          // An invalid observed wake is terminal even if a later frame restores text.
          x.picker.primary.text = 'Instant'; x.wake();
          const result = await x.pending;
          expect(result.error).toBeDefined(); expect(result.modelEvidence).toBeUndefined();
          expect(result.modelDiagnostic.chatHeader.readiness.outcome).toBe('rejected');
          expect(result.modelDiagnostic.chatHeader.readiness.reason).toBe(condition === 'unknown' ? 'unknown_header'
            : condition === 'owner' ? 'ownership_changed' : 'state_changed');
          expect(x.picker.trigger.clicks).toBe(0); noSelection(x.f, x.picker);
          expect(JSON.stringify(result)).not.toContain('PRIVATE');
        }
      });
      test('empty readonly discovery and pinned headers never receive the initial mutable hydration wait', async () => {
        for (const condition of ['discovery', 'readonly', 'pinned']) {
          const { f, picker } = setup();
          if (condition === 'pinned') expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const opens = picker.trigger.clicks; picker.primary.text = '';
          let clocks = 0;
          f.window.webkit.messageHandlers.computaModelClock = { postMessage: () => { clocks++; return Promise.resolve(true); } };
          const result = await f.run(condition === 'discovery' ? 'discoverModels' : condition === 'pinned' ? 'selectModel' : 'verifyModel',
            { ...(condition === 'discovery' ? {} : { modelChoice: choice(initial), expectedModelChoice: choice(initial) }),
              operationID: '95e24632-2eb6-4cd6-b30f-17ab208c2fbd' });
          expect(result.error).toBeDefined(); expect(result.modelEvidence).toBeUndefined();
          expect(result.modelDiagnostic?.chatHeader?.readiness).toBeUndefined();
          expect(clocks).toBe(0); expect(picker.trigger.clicks).toBe(opens); noSelection(f, picker);
        }
      });
      test('header diagnostics distinguish rendered hidden and oversized text without exporting content', async () => {
        const { f, picker } = setup();
        Object.defineProperty(picker.trigger, 'innerText', { configurable: true, get: () => '' });
        picker.primary.text = 'Instant';
        const hidden = (await f.run('modelDiagnostic')).modelDiagnostic.chatHeader.textShape;
        expect(hidden.innerText).toMatchObject({ present: true, empty: true, length: 0, canonicalOrdinal: null });
        expect(hidden.textContent).toMatchObject({ empty: false, canonicalOrdinal: 0 });
        picker.primary.text = '\u0344'.repeat(512); // NFC expands this combining character.
        expect((await f.run('modelDiagnostic')).modelDiagnostic.chatHeader.textShape.textContent.normalizedLength).toBe(512);
        picker.primary.text = 'PRIVATE_HEADER_CANARY'.repeat(200);
        for (let index = 0; index < 40; index++) picker.trigger.append(new Node('SPAN', {}, 'PRIVATE_CHILD_CANARY'));
        const diagnostic = (await f.run('modelDiagnostic')).modelDiagnostic;
        expect(diagnostic.chatHeader.textShape.textContent).toMatchObject({ length: 513, normalizedLength: null, over128: true });
        expect(diagnostic.chatHeader.textShape.childCount).toBe(33);
        expect(diagnostic.chatHeader.textShape.children).toHaveLength(4);
        expect(JSON.stringify(diagnostic)).not.toContain('PRIVATE');
        expect(JSON.stringify(diagnostic).length).toBeLessThanOrEqual(8_192);
        expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
      });
      test('generic closed chrome discovers actual power and verifies fresh family then Power before pinning', async () => {
        const behavior = { closedGenericHeader: true, resetToPowerOnClose: true };
        const discovery = setup(false, behavior); discovery.picker.selected('High');
        const found = await discovery.f.run('discoverModels');
        expect(found.modelEvidence.chatSelection.power).toEqual({ key: 'high', label: 'High' });
        expect(found.modelEvidence.chatSelection.family.key).toBe('GPT-6');
        expect(found.modelChoices).toHaveLength(5); noSelection(discovery.f, discovery.picker);
        expect(discovery.picker.trigger.clicks).toBe(2);
        const { f, picker } = setup(false, behavior);
        expect((await f.run('modelDiagnostic')).modelDiagnostic.chatHeader).toMatchObject({
          canonicalRecognized: false, openPresentationRecognized: true, closed: true, ordinal: null });
        const selected = await f.run('selectModel', { modelChoice: choice(target) });
        expect(selected.selected).toBe(true); expect(selected.modelEvidence.selected).toEqual(choice(target));
        expect(selected.modelEvidence.chatSelection.power.key).toBe('high');
        expect(arrows(picker)).toHaveLength(1); expect(picker.trigger.clicks).toBe(2);
        const pin = f.world.__computaChatPresetPin;
        expect(pin.genericHeaderVerified).toBe(picker.trigger); expect(pin.controls.has(picker.slider)).toBe(true);
        expect(picker.primary.text).toBe('Thinking effort');
        const checked = await f.run('verifyModel', { expectedModelChoice: choice(target) });
        expect(checked.modelEvidence.selected).toEqual(choice(target)); expect(picker.trigger.clicks).toBe(4);
        expect(arrows(picker)).toHaveLength(1); expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true);
      });
      test('generic chrome cannot replace missing ambiguous disabled or foreign Power and family proof', async () => {
        for (const condition of ['missing_power', 'disabled_power', 'ambiguous_power', 'foreign_menu', 'ambiguous_family']) {
          const { f, picker } = setup(false, { closedGenericHeader: true, resetToPowerOnClose: true });
          if (condition === 'missing_power') picker.slider.values.hidden = '';
          if (condition === 'disabled_power') picker.powerItem.values['aria-disabled'] = 'true';
          if (condition === 'ambiguous_power') picker.powerItem.append(new Node('SPAN', { ...picker.slider.values }));
          if (condition === 'foreign_menu') picker.trigger.values['aria-controls'] = 'unassociated';
          if (condition === 'ambiguous_family') picker.familyOptions[2].values['aria-checked'] = 'true';
          const result = await expire(f, f.run('selectModel', { modelChoice: choice(initial) }));
          expect(result.error).toBeDefined(); expect(result.modelEvidence).toBeUndefined();
          expect(f.world.__computaChatPresetPin).toBeUndefined(); noSelection(f, picker);
        }
      });
      test('generic closed chrome rejects a family-induced power reset without repairing or retrying', async () => {
        const { f, picker } = setup(false, { closedGenericHeader: true, resetToPowerOnClose: true });
        picker.selected('GPT-5.5');
        const choose = picker.familyOptions[0].onClick;
        picker.familyOptions[0].onClick = () => { choose(); picker.selected('Pro'); };
        const result = await f.run('selectModel', { modelChoice: choice(initial) });
        expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined();
        expect(picker.familyOptions[0].clicks).toBe(1); expect(arrows(picker)).toHaveLength(0);
        expect(picker.trigger.clicks).toBe(2); expect(f.world.__computaChatPresetPin).toBeUndefined();
      });
      test('generic family-only reopening fails closed without inventing a Back action', async () => {
        const { f, picker } = setup(false, { closedGenericHeader: true });
        const result = await f.run('selectModel', { modelChoice: choice(initial) });
        expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
        expect(picker.trigger.clicks).toBe(2); noSelection(f, picker);
        expect(f.world.__computaChatPresetPin).toBeUndefined();
      });
      test('generic header proof catches later power drift and only transfers a remount after fresh menu proof', async () => {
        for (const condition of ['unchanged', 'power_drift', 'family_drift', 'owner_changed']) {
          const { f, picker } = setup(false, { closedGenericHeader: true, resetToPowerOnClose: true });
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin, old = picker.replaceTrigger();
          if (condition === 'power_drift') picker.selected('Pro');
          if (condition === 'family_drift') picker.selected('GPT-5.5');
          if (condition === 'owner_changed') f.world.__computaModelOwner = 'PRIVATE_FOREIGN_OWNER';
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          if (condition === 'unchanged') {
            expect(result.modelEvidence.selected).toEqual(choice(initial));
            expect(pin.headerTrigger).toBe(picker.trigger); expect(pin.genericHeaderVerified).toBe(picker.trigger);
            expect(picker.trigger.clicks).toBe(2);
          } else {
            expect(result.error).toBeDefined(); expect(result.modelEvidence).toBeUndefined(); expect(pin.headerTrigger).toBe(old);
          }
          noSelection(f, picker); expect(JSON.stringify(result)).not.toContain('PRIVATE_FOREIGN_OWNER');
        }
      });
      test('a disconnected header remount rebinds only after fresh readonly family and power proof', async () => {
        const { f, picker } = setup();
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
        const pin = f.world.__computaChatPresetPin, selection = pin.selection, previous = picker.replaceTrigger();
        const replacement = picker.trigger, open = replacement.onClick, close = picker.menu.onDispatch;
        let provedFamily = false, closedAfterProof = false;
        replacement.onClick = () => {
          expect(pin.headerTrigger).toBe(previous); open();
          provedFamily = picker.familyOptions[0].values['aria-checked'] === 'true' && !picker.familyView.values.hidden;
        };
        picker.menu.onDispatch = (event: any) => {
          expect(pin.headerTrigger).toBe(previous); expect(provedFamily).toBe(true);
          close(event); closedAfterProof = true;
        };
        const beforePower = arrows(picker).length, beforeFamily = picker.familyOptions.map((node: any) => node.clicks);
        const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
        expect(result.modelEvidence.selected).toEqual(choice(initial)); expect(closedAfterProof).toBe(true);
        expect(f.world.__computaChatPresetPin).toBe(pin); expect(pin.selection).toBe(selection);
        expect(pin.headerTrigger).toBe(replacement); expect(pin.invalidated).toBeUndefined();
        expect(replacement.clicks).toBe(1); expect(arrows(picker)).toHaveLength(beforePower);
        expect(picker.familyOptions.map((node: any) => node.clicks)).toEqual(beforeFamily);
        replacement.onClick = open; picker.menu.onDispatch = close;
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial));
        expect(pin.headerTrigger).toBe(replacement); noSelection(f, picker);
      });
      test('header remount rejects a connected old header and different or unverifiable family and power', async () => {
        for (const condition of ['connected', 'connected_hidden', 'wrong_power', 'unknown_power', 'wrong_family']) {
          const { f, picker } = setup();
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin;
          const old = picker.replaceTrigger(!condition.startsWith('connected'));
          if (condition === 'connected_hidden') old.values.hidden = '';
          if (condition === 'wrong_power') picker.selected('High');
          if (condition === 'unknown_power') picker.primary.text = 'PRIVATE UNKNOWN';
          if (condition === 'wrong_family') picker.selected('GPT-5.5');
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(['model_mismatch', 'model_unverified']).toContain(result.error); expect(result.modelEvidence).toBeUndefined();
          expect(pin.headerTrigger).toBe(old); expect(JSON.stringify(result)).not.toContain('PRIVATE UNKNOWN');
          expect(picker.trigger.clicks).toBe(condition === 'wrong_family' ? 1 : 0); noSelection(f, picker);
        }
      });
      test('a provisional remount cannot adopt another replacement or a reconnected old header during proof', async () => {
        for (const condition of ['replace_again', 'reconnect_old', 'foreign_route', 'owner_changed']) {
          const { f, picker } = setup();
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin, old = picker.replaceTrigger(), candidate = picker.trigger;
          const open = candidate.onClick;
          candidate.onClick = () => {
            open();
            if (condition === 'replace_again') picker.replaceTrigger();
            if (condition === 'reconnect_old') { old.connected = true; old.values.hidden = ''; f.body.append(old); }
            if (condition === 'foreign_route') f.document.URL = 'https://chatgpt.com/c/foreign';
            if (condition === 'owner_changed') f.world.__computaModelOwner = 'PRIVATE_OTHER_OWNER';
          };
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(['model_mismatch', 'document_changed']).toContain(result.error); expect(result.modelEvidence).toBeUndefined();
          expect(pin.headerTrigger).toBe(old); expect(candidate.clicks).toBe(1); noSelection(f, picker);
          expect(JSON.stringify(result)).not.toContain('PRIVATE_OTHER_OWNER');
        }
      });
      test('remount never clears previous header or semantic drift even after the visible selection is restored', async () => {
        for (const reason of ['header_mutation', 'semantic_mutation', 'header_replaced']) {
          const { f, picker } = setup();
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin;
          if (reason === 'header_mutation') pin.headerObserver.callback([{ type: 'characterData',
            target: { nodeType: 3, parentElement: picker.primary, textContent: 'Medium' }, oldValue: 'High' }]);
          else if (reason === 'semantic_mutation') pin.semanticObserver.callback([{ type: 'attributes',
            target: picker.familyOptions[0], attributeName: 'aria-checked', oldValue: 'false' }]);
          else { pin.invalidated = true; pin.invalidationReason = reason; }
          const old = picker.replaceTrigger();
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined();
          expect(pin.headerTrigger).toBe(old); expect(result.modelDiagnostic.chatPin.invalidationReason).toBe(reason);
          expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
        }
      });
      test('remount drains undelivered old header and semantic negatives without consuming shared notifications', async () => {
        for (const kind of ['header', 'semantic']) {
          const { f, picker } = setup();
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin, primary = picker.primary, old = picker.replaceTrigger();
          let drained = false;
          const pending = kind === 'header' ? pin.headerObserver : pin.semanticObserver;
          pending.takeRecords = () => {
            if (drained) return []; drained = true;
            return kind === 'header' ? [{ type: 'characterData', target: { nodeType: 3, parentElement: primary,
              textContent: 'Medium' }, oldValue: 'High' }] : [{ type: 'attributes', target: picker.familyOptions[0],
              attributeName: 'aria-checked', oldValue: 'false' }];
          };
          f.world.__computaModelSignal.observer.takeRecords = () => { throw new Error('must not drain shared product or wake records'); };
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined(); expect(drained).toBe(true);
          expect(pin.headerTrigger).toBe(old); expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
        }
      });
      test('remount commit drains replacement header and semantic changes queued at close acknowledgment', async () => {
        for (const kind of ['header', 'semantic']) {
          const { f, picker } = setup();
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin, old = picker.replaceTrigger(), observersBefore = f.observers.length;
          const close = picker.menu.onDispatch; let drained = false;
          picker.menu.onDispatch = (event: any) => {
            close(event);
            const pending = kind === 'header'
              ? f.observers.slice(observersBefore).find((observer: any) => observer.options?.characterDataOldValue)
              : pin.semanticObserver;
            pending.takeRecords = () => {
              if (drained) return []; drained = true;
              return kind === 'header' ? [{ type: 'characterData', target: { nodeType: 3, parentElement: picker.primary,
                textContent: 'Medium' }, oldValue: 'High' }] : [{ type: 'attributes', target: picker.familyOptions[0],
                attributeName: 'aria-checked', oldValue: 'false' }];
            };
          };
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined(); expect(drained).toBe(true);
          expect(pin.headerTrigger).toBe(old); expect(picker.trigger.clicks).toBe(1);
          expect(result.modelDiagnostic.chatPin.invalidationReason).toBe(kind === 'header' ? 'header_mutation' : 'semantic_mutation');
          noSelection(f, picker);
        }
      });
      test('pin diagnostics preserve the first finite rejection cause without changing admission', async () => {
        for (const reason of ['header_replaced', 'header_mutation', 'semantic_mutation', 'PRIVATE_PAGE_CANARY']) {
          const { f, picker } = setup();
          expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const pin = f.world.__computaChatPresetPin;
          pin.invalidated = true; pin.invalidationReason = reason;
          const opens = picker.trigger.clicks;
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined();
          expect(result.modelDiagnostic.chatPin).toEqual({ present: true, invalidated: true,
            invalidationReason: reason === 'PRIVATE_PAGE_CANARY' ? null : reason,
            sameHeader: true, headerConnected: true, semantic: null });
          expect(JSON.stringify(result)).not.toContain('PRIVATE_PAGE_CANARY');
          expect(picker.trigger.clicks).toBe(opens); noSelection(f, picker);
        }
      });
      test('closed header and active Power ordinal must agree before fresh input', async () => {
        const { f, picker } = setup(); picker.slider.values['aria-valuenow'] = '0';
        const result = await f.run('selectModel', { modelChoice: choice(target) });
        expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined(); noSelection(f, picker);
      });
      test('a final closed canonical power change cannot repair or qualify fresh selection', async () => {
        const { f, picker } = setup(); const close = picker.menu.onDispatch;
        picker.menu.onDispatch = (event: any) => { close(event); picker.primary.text = 'Medium'; };
        const result = await f.run('selectModel', { modelChoice: choice(target) });
        expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined();
        expect(arrows(picker)).toHaveLength(1); expect(picker.trigger.clicks).toBe(1);
        expect(f.composer.textContent).toBe(''); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
      });
      test('canonical closed header change and restoration latches across callbacks and rejects responses', async () => {
        const { f, picker } = setup(); expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
        picker.primary.text = 'High\n'; picker.primary.text = ' Medium\n';
        for (const observer of f.observers) observer.callback([{ type: 'characterData',
          target: { nodeType: 3, parentElement: picker.primary }, oldValue: ' High\n' }]);
        expect(f.world.__computaChatPresetPin.invalidated).toBe(true);
        expect(f.world.__computaChatPresetPin.invalidationReason).toBe('header_mutation');
        const opens = picker.trigger.clicks;
        for (const action of ['verifyModel', 'prepare', 'inspect', 'submit']) {
          const result = await f.run(action, { expectedModelChoice: choice(initial), prompt: 'PRIVATE NEVER SEND' });
          expect(result.error).toBe('model_mismatch'); expect(result.text).toBeUndefined(); expect(result.submitted).toBeUndefined();
        }
        expect(picker.trigger.clicks).toBe(opens); noSelection(f, picker);
      });
      test('header child replacement latches wrong canonical power while foreign text never grants authority', async () => {
        for (const foreign of [true, false]) {
          const { f, picker } = setup(); expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const wrong = new Node('SPAN', {}, 'High');
          for (const observer of f.observers) observer.callback([{ type: 'childList',
            target: foreign ? f.answer : picker.trigger, addedNodes: [wrong], removedNodes: [] }]);
          expect(f.world.__computaChatPresetPin.invalidated === true).toBe(!foreign);
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          if (foreign) expect(result.modelEvidence.selected).toEqual(choice(initial)); else expect(result.error).toBe('model_mismatch');
          noSelection(f, picker);
        }
      });
      test('nested header drift restored and detached in one batch retains its historical lineage', async () => {
        for (const drift of [false, true]) {
          const { f, picker } = setup(); expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          const original = picker.primary, wrapper = new Node('SPAN'), inner = new Node('SPAN', {}, 'Medium');
          const value: any = { nodeType: 3, parentElement: inner, textContent: 'Medium' };
          Object.defineProperty(inner, 'childNodes', { get: () => value.parentElement === inner ? [value] : [] });
          const records: any[] = [];
          const remove = (parent: any, child: any) => {
            parent.children = parent.children.filter((node: any) => node !== child); child.parentElement = null;
            records.push({ type: 'childList', target: parent, addedNodes: [], removedNodes: [child] });
          };
          remove(picker.trigger, original); picker.trigger.append(wrapper);
          records.push({ type: 'childList', target: picker.trigger, addedNodes: [wrapper], removedNodes: [] });
          wrapper.append(inner); records.push({ type: 'childList', target: wrapper, addedNodes: [inner], removedNodes: [] });
          if (drift) {
            inner.text = value.textContent = 'High'; records.push({ type: 'characterData', target: value, oldValue: 'Medium' });
            inner.text = value.textContent = 'Medium'; records.push({ type: 'characterData', target: value, oldValue: 'High' });
          }
          inner.text = ''; value.parentElement = null;
          records.push({ type: 'childList', target: inner, addedNodes: [], removedNodes: [value] });
          remove(wrapper, inner); remove(picker.trigger, wrapper); picker.trigger.append(original);
          records.push({ type: 'childList', target: picker.trigger, addedNodes: [original], removedNodes: [] });
          for (const observer of f.observers) observer.callback(records);
          expect(f.world.__computaChatPresetPin.invalidated === true).toBe(drift);
          const opens = picker.trigger.clicks;
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          if (drift) { expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined(); expect(picker.trigger.clicks).toBe(opens); }
          else expect(result.modelEvidence.selected).toEqual(choice(initial));
          noSelection(f, picker);
        }
        const outside = setup(), show = outside.picker.secondary.onClick;
        outside.picker.secondary.onClick = () => {
          show();
          const churn = Array.from({ length: 513 }, () => ({ type: 'childList', target: outside.f.answer,
            addedNodes: [new Node('SPAN', {}, 'High')], removedNodes: [] }));
          // Only document-wide observers receive unrelated response churn.
          for (const observer of outside.f.observers) if (observer.options?.attributes === true) observer.callback(churn);
        };
        expect((await outside.f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
        noSelection(outside.f, outside.picker);

        for (const overflow of ['records', 'children', 'text', 'ancestry']) {
          const { f, picker } = setup(); expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
          let records: any[];
          if (overflow === 'records') records = Array.from({ length: 513 }, () => ({ type: 'childList',
            target: picker.trigger, addedNodes: [], removedNodes: [] }));
          else if (overflow === 'children') records = [{ type: 'childList', target: picker.trigger,
            addedNodes: Array.from({ length: 129 }, () => new Node('SPAN')), removedNodes: [] }];
          else if (overflow === 'text') records = [{ type: 'childList', target: picker.trigger,
            addedNodes: [new Node('SPAN', {}, 'x'.repeat(129))], removedNodes: [] }];
          else {
            const root = new Node('SPAN'); let deepest = root;
            for (let depth = 0; depth < 65; depth++) { const child = new Node('SPAN'); deepest.append(child); deepest = child; }
            const value = { nodeType: 3, parentElement: deepest, textContent: 'Medium' };
            records = [{ type: 'childList', target: picker.trigger, addedNodes: [root], removedNodes: [] },
              { type: 'characterData', target: value, oldValue: 'Medium' },
              { type: 'childList', target: picker.trigger, addedNodes: [], removedNodes: [root] }];
          }
          f.world.__computaChatPresetPin.headerObserver.callback(records);
          expect(f.world.__computaChatPresetPin.invalidated).toBe(true);
          const opens = picker.trigger.clicks;
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined(); expect(picker.trigger.clicks).toBe(opens);
          noSelection(f, picker);
        }
      });
      test('all five owned response choices survive disconnected remembered-Family reopening without Power input', async () => {
        for (const label of ['Instant', 'Medium', 'High', 'Extra High', 'Pro']) {
          const { f, picker } = setup(true); picker.selected(label);
          const first = await f.run('inspect', { expectedModelChoice: choice(label) });
          expect(first.modelEvidence.selected).toEqual(choice(label)); expect(first.answerComplete).toBe(true);
          expect(picker.menu.isConnected).toBe(false); expect(picker.primary.text).toBe(label);
          const secondaryClicks = picker.secondary.clicks;
          f.appendUser('Second owned fixture user');
          const article = new Node('ARTICLE', { 'data-turn': 'assistant' });
          const answer = new Node('DIV', { 'data-markdown-text-style': 'assistant-message' }, 'Second exact fixture response');
          const controls = new Node('DIV'); controls.append(new Node('BUTTON', { 'aria-label': 'Copy' })); article.append(answer, controls);
          f.body.querySelector('main').append(article);
          const second = await f.run('inspect', { expectedModelChoice: choice(label), expectedUserCounts: [1, 2],
            allowAcknowledgedUserAppend: true });
          expect(second.modelEvidence.selected).toEqual(choice(label)); expect(second.answerComplete).toBe(true);
          expect(second.text).toBe('Second exact fixture response'); expect(picker.secondary.clicks).toBe(secondaryClicks);
          expect(picker.menu.isConnected).toBe(false); expect(picker.primary.text).toBe(label);
          expect(arrows(picker)).toHaveLength(0); expect(picker.slider.events).toHaveLength(0);
        }
      });
      test('fresh selection steps power before selecting the highest plain family once', async () => {
        const { f, picker } = setup(false, { parentReturnAfterSelection: true }); picker.selected('GPT-5.6 Sol');
        const result = await f.run('selectModel', { modelChoice: choice(target) });
        expect(result.selected).toBe(true); expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
        expect(picker.familyOptions.map((node: any) => node.clicks)).toEqual([1, 0, 0]); expect(arrows(picker)).toHaveLength(1);
        expect(picker.menu.values.hidden).toBe(''); expect(f.composer.textContent).toBe('');
      });
      test('mid-turn lower family drift never gains a repair click despite the same Medium intent', async () => {
        const { f, picker } = setup(true); await f.run('inspect', { expectedModelChoice: choice(initial) });
        picker.selected('GPT-5.5');
        const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
        expect(result.error).toBe('model_mismatch'); expect(result.text).toBeUndefined();
        expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true); expect(arrows(picker)).toHaveLength(0);
      });
      test('a newly offered higher family invalidates current policy proof without automatic mid-turn selection', async () => {
        const { f, picker } = setup(true); await f.run('inspect', { expectedModelChoice: choice(initial) });
        const higher = new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'false' }, 'GPT-6.1'); picker.familyOptions.push(higher);
        const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
        expect(result.error).toBe('model_mismatch'); expect(result.text).toBeUndefined(); expect(higher.clicks).toBe(0);
      });
      test('focus-only prepare rejects power drift before insertion or Send', async () => {
        const { f, picker } = setup(); f.composer.focus = () => { f.document.activeElement = f.composer; picker.selected(target); };
        expect(await f.run('prepare', { expectedModelChoice: choice(initial) })).toMatchObject({ error: 'model_mismatch' }); noSelection(f, picker);
      });
      test('prepare makes a bounded family-power proof with no selection mutation', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        const result = await f.run('prepare', { expectedModelChoice: choice(initial) });
        expect(result).toMatchObject({ prepared: true, modelEvidence: { selected: choice(initial), source: selectionSource } });
        expect(picker.trigger.clicks).toBe(1); expect(picker.secondary.clicks).toBe(1); expect(picker.menu.isConnected).toBe(false); noSelection(f, picker);
      });
      test('no concrete preset produces no implicit model-selection evidence', async () => {
        const { f, picker } = setup(); const result = await f.run('verifyModel');
        expect(result.modelEvidence).toBeFalsy(); expect(picker.trigger.clicks).toBe(0); noSelection(f, picker);
      });
      test('malformed physical power controls fail without keyboard mutation', async () => {
        for (const change of [
          (p: any) => { p.slider.tagName = 'DIV'; }, (p: any) => { p.slider.values['aria-valuemin'] = '1'; },
          (p: any) => { p.slider.values['aria-valuemax'] = '5'; }, (p: any) => { p.slider.values['aria-valuenow'] = '1.0'; },
          (p: any) => { p.slider.values['aria-orientation'] = 'vertical'; },
          (p: any) => { p.powerItem.append(new Node('SPAN', { ...p.slider.values })); },
        ]) {
          const { f, picker } = setup(); picker.showPower(); change(picker);
          expect((await expire(f, f.run('selectModel', { modelChoice: choice(target) }))).error).toBe('model_unverified'); noSelection(f, picker);
        }
      });
      test('closed-start recognized disabled power is unavailable for fresh actions and unverified for reads', async () => {
        for (const action of ['selectModel', 'discoverModels', 'verifyModel']) for (const disable of [
          (p: any) => { p.slider.disabled = true; },
          (p: any) => { p.slider.values['aria-disabled'] = 'true'; },
          (p: any) => { p.powerItem.values['aria-disabled'] = 'true'; },
          (p: any) => {
            const wrapper = new Node('DIV', { 'aria-disabled': 'true', 'aria-hidden': 'true' });
            p.powerItem.children = []; wrapper.append(p.slider); p.powerItem.append(wrapper);
          },
        ]) {
          const { f, picker } = setup(); disable(picker);
          const result = await f.run(action, action === 'selectModel' ? { modelChoice: choice(target) }
            : action === 'verifyModel' ? { expectedModelChoice: choice(initial) } : {});
          expect(result.error).toBe(action === 'verifyModel' ? 'model_unverified' : 'model_unavailable');
          expect(result.modelEvidence).toBeUndefined(); expect(result.modelChoices).toBeUndefined();
          expect(picker.trigger.clicks).toBe(1); noSelection(f, picker);
        }
      });
      test('duplicate, malformed and unproved family rows cannot establish Latest', async () => {
        for (const change of [
          (p: any) => { p.familyOptions.push(new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'false' }, 'GPT-6')); },
          (p: any) => { p.familyOptions.push(new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'false' }, 'GPT-6.0')); },
          (p: any) => { p.familyOptions[0].values['aria-checked'] = 'mixed'; },
          (p: any) => { p.familyOptions[0].children[0].text = 'GPT-6\nPRIVATE NOTICE'; },
        ]) {
          const { f, picker } = setup(); change(picker);
          expect((await f.run('discoverModels')).error).toBe('model_unverified'); noSelection(f, picker);
        }
      });
      test('an unrelated physical menu never grants picker authority or receives Escape', async () => {
        const { f, picker } = setup(); const foreign = new Node('DIV', { role: 'menu', id: 'foreign' }); f.body.append(foreign);
        expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(picker.trigger.clicks).toBe(0); expect(foreign.events).toHaveLength(0); noSelection(f, picker);
      });
      test('a checked family must come from the exact associated popup, not a matching header', async () => {
        const { f, picker } = setup(); picker.primary.values['data-model-id'] = 'GPT-999';
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).modelEvidence.chatSelection.family.key).toBe('GPT-6');
        picker.showFamily(); delete picker.trigger.values['aria-controls'];
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_unverified'); noSelection(f, picker);
      });
      test('same-popup family panel and power view stay associated across portal unmounts', async () => {
        const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
        expect(picker.secondary.values['aria-haspopup']).toBeUndefined();
        for (let read = 0; read < 3; read++) {
          expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial));
          expect(picker.menu.isConnected).toBe(false);
        }
        expect(picker.trigger.clicks).toBe(3); expect(picker.secondary.clicks).toBe(1); noSelection(f, picker);
      });
      test('one-proof preparation and verification reject owner, route, frame, count and mode drift after the final await', async () => {
        for (const action of ['prepare', 'verifyModel']) for (const owned of [false, true])
          for (const drift of ['owner', 'url', 'origin', 'top_frame', 'user_count', 'temporary_mode']) {
            const { f, picker } = setup(owned); if (owned) await f.run('inspect', { expectedModelChoice: choice(initial) });
            closed(picker, () => {
              if (drift === 'owner') f.world.__computaModelOwner = 'foreign-owner';
              if (drift === 'url') f.document.URL += '&foreign-route=true';
              if (drift === 'origin') f.location.origin = 'https://foreign.invalid';
              if (drift === 'top_frame') f.window.top = {};
              if (drift === 'user_count') f.appendUser('Foreign unacknowledged user');
              if (drift === 'temporary_mode') f.temporary.connected = false;
            });
            const result = await f.run(action, { expectedModelChoice: choice(initial) });
            expect(result.error).toBeDefined(); expect(result.error).not.toBe('acknowledged_user_append');
            expect(result.prepared).toBeUndefined(); expect(result.submitted).toBeUndefined(); expect(result.text).toBeUndefined();
            expect(arrows(picker)).toHaveLength(0); expect(f.composer.textContent).toBe('');
          }
      });
      test('fresh selection rejects newly introduced owner, message, association or trigger drift before power input', async () => {
        for (const [caseIndex, change] of [
          (f: any) => { f.world.__computaModelOwner = 'foreign-owner'; }, (f: any) => { f.document.URL += '&foreign=1'; },
          (f: any) => { f.appendUser('Unclaimed user'); }, (f: any) => { const reply = new Node('ARTICLE', { 'data-turn': 'assistant' }); reply.append(new Node('DIV', { 'data-markdown-text-style': 'assistant-message' }, 'Unclaimed answer')); f.body.querySelector('main').append(reply); },
          (f: any) => { f.world.__computaModelFirstSubmitted = true; }, (f: any) => { f.world.__computaModelFirstProof = {}; },
          (f: any, p: any) => { p.trigger.connected = false; }, (f: any, p: any) => { p.trigger.disabled = true; },
          (f: any, p: any) => { delete p.trigger.values['aria-controls']; },
          (f: any) => { f.body.append(new Node('DIV', { role: 'menu', id: 'foreign' })); },
        ].entries()) {
          const { f, picker } = setup(); const show = picker.trigger.onClick;
          picker.trigger.onClick = () => { show(); change(f, picker); };
          const result = await expire(f, f.run('selectModel', { modelChoice: choice(target) }));
          expect(result.error).toBeDefined(); expect(result.selected).toBeUndefined(); expect({ caseIndex, inputs: arrows(picker).length }).toEqual({ caseIndex, inputs: 0 });
          expect(f.composer.textContent).toBe('');
        }
      });
      test('deferred final popup closure is acknowledged before publishing selection', async () => {
        const { f, picker } = setup(false, { unmountMenus: true }); const dismiss = picker.menu.onDispatch; let deferred = false, released = false;
        picker.menu.onDispatch = (event: any) => { if (!deferred) { deferred = true; return; } dismiss(event); };
        const pending = f.run('selectModel', { modelChoice: choice(target) }); await microtasks();
        expect(picker.trigger.clicks).toBe(1); expect(arrows(picker)).toHaveLength(1);
        picker.close(); released = true;
        for (const observer of f.observers) observer.callback([{ type: 'attributes', target: picker.menu, attributeName: 'hidden' }]);
        expect((await pending).selected).toBe(true); expect(released).toBe(true); expect(arrows(picker)).toHaveLength(1);
      });
      test('every closed-popup proof requires a visible enabled trigger with acknowledged closed state', async () => {
        for (const action of ['verifyModel', 'selectModel']) for (const drift of ['hidden', 'disabled', 'open_state']) {
          const { f, picker } = setup(); const dismiss = picker.menu.onDispatch;
          const targetClose = 1;
          let closes = 0, reached!: () => void;
          const changed = new Promise<void>(resolve => { reached = resolve; });
          picker.menu.onDispatch = (event: any) => {
            dismiss(event); if (event.key !== 'Escape' || ++closes !== targetClose) return;
            if (drift === 'hidden') picker.trigger.values.hidden = '';
            else if (drift === 'disabled') picker.trigger.disabled = true;
            else picker.trigger.values['data-state'] = 'open';
            reached();
          };
          const pending = f.run(action, action === 'selectModel' ? { modelChoice: choice(target) }
            : { expectedModelChoice: choice(initial) });
          await changed;
          const opens = picker.trigger.clicks, powers = arrows(picker).length;
          const result = await expire(f, pending);
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined(); expect(result.selected).toBeUndefined();
          expect(picker.trigger.clicks).toBe(opens); expect(arrows(picker)).toHaveLength(powers);
          expect(picker.menu.events.filter((event: any) => event.key === 'Escape')).toHaveLength(targetClose);
          expect(f.composer.textContent).toBe(''); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
        }
      });
      test('delayed full trigger closure acknowledgment wakes the same proof without another Escape', async () => {
        for (const action of ['verifyModel', 'selectModel']) {
          const { f, picker } = setup(); const dismiss = picker.menu.onDispatch;
          const targetClose = 1;
          let closes = 0, reached!: () => void, finished = false;
          const changed = new Promise<void>(resolve => { reached = resolve; });
          picker.menu.onDispatch = (event: any) => {
            dismiss(event); if (event.key !== 'Escape' || ++closes !== targetClose) return;
            picker.trigger.values.hidden = ''; picker.trigger.disabled = true; picker.trigger.values['data-state'] = 'open'; reached();
          };
          const pending = f.run(action, action === 'selectModel' ? { modelChoice: choice(target) }
            : { expectedModelChoice: choice(initial) }).then((result: any) => { finished = true; return result; });
          await changed; await microtasks();
          const opens = picker.trigger.clicks;
          expect(finished).toBe(false); expect(picker.menu.events.filter((event: any) => event.key === 'Escape')).toHaveLength(targetClose);
          expect(picker.trigger.clicks).toBe(opens);
          delete picker.trigger.values.hidden; picker.trigger.disabled = false; picker.trigger.values['data-state'] = 'closed';
          const changes = [{ type: 'attributes', target: picker.trigger, attributeName: 'hidden' },
            { type: 'attributes', target: picker.trigger, attributeName: 'disabled' },
            { type: 'attributes', target: picker.trigger, attributeName: 'data-state', oldValue: 'open' }];
          for (const observer of f.observers) observer.callback(changes.filter(record =>
            !observer.options?.attributeFilter || observer.options.attributeFilter.includes(record.attributeName)));
          const result = await pending;
          expect(result.modelEvidence.selected).toEqual(choice(action === 'selectModel' ? target : initial));
          expect(picker.trigger.clicks).toBe(1);
          expect(picker.menu.events.filter((event: any) => event.key === 'Escape')).toHaveLength(1);
          expect(arrows(picker)).toHaveLength(action === 'selectModel' ? 1 : 0);
          expect(f.composer.textContent).toBe(''); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
        }
      });
      test('a clicked family returning to Power requires its claimed close and restored trigger and temporary mode', async () => {
        for (const retained of ['none', 'disabled_trigger', 'hidden_temporary']) {
          const { f, picker } = setup(false, { parentReturnAfterSelection: true }); picker.selected('GPT-5.6 Sol');
          const family = picker.familyOptions[0], click = family.onClick, dismiss = picker.menu.onDispatch;
          let parentActive = false, parentEscapes = 0;
          family.onClick = () => {
            click(); parentActive = true; picker.trigger.disabled = true; f.temporary.values['aria-hidden'] = 'true';
          };
          picker.menu.onDispatch = (event: any) => {
            if (event.key === 'Escape' && parentActive) {
              expect(f.world.__computaModelSelection.selectionCloseAttempted).toBe(true);
              expect(picker.menu.contains(picker.powerItem)).toBe(true); parentEscapes++; parentActive = false;
              dismiss(event);
              if (retained !== 'disabled_trigger') picker.trigger.disabled = false;
              if (retained !== 'hidden_temporary') delete f.temporary.values['aria-hidden'];
            } else dismiss(event);
          };
          const pending = f.run('selectModel', { modelChoice: choice(initial) });
          const result = retained === 'disabled_trigger' ? await expire(f, pending) : await pending;
          expect(parentEscapes).toBe(1); expect(family.clicks).toBe(1); expect(arrows(picker)).toHaveLength(0);
          if (retained === 'none') {
            expect(result.selected).toBe(true); expect(f.world.__computaModelSelection.familyCloseAcknowledged).toBe(true);
            expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
          } else {
            expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
            expect(f.world.__computaModelSelection.familyCloseAcknowledged).not.toBe(true);
            expect(picker.trigger.clicks).toBe(1);
          }
          expect(f.composer.textContent).toBe(''); expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
        }
      });
      test('a consumed post-family opening permits one bounded claimed recovery with no selection or Send replay', async () => {
        for (const ignoreRecovery of [false, true]) {
          const { f, picker } = setup(false, { parentReturnAfterSelection: true }); picker.selected('GPT-5.6 Sol');
          const operationID = 'b7ea6b9c-81c8-45ef-8bdb-1f2c52c103de';
          const clocks: { request: any; expire: () => void }[] = [];
          let firstClock!: () => void, secondClock!: () => void;
          const waitingFirst = new Promise<void>(resolve => { firstClock = resolve; });
          const waitingSecond = new Promise<void>(resolve => { secondClock = resolve; });
          f.window.webkit.messageHandlers.computaModelClock = { postMessage: (request: any) => new Promise<void>(resolve => {
            clocks.push({ request, expire: resolve }); if (clocks.length === 1) firstClock(); else secondClock();
          }) };
          const open = picker.trigger.onClick;
          picker.trigger.onClick = () => {
            if (picker.trigger.clicks === 2 || ignoreRecovery && picker.trigger.clicks === 3) return;
            open();
          };
          const pending = f.run('selectModel', { modelChoice: choice(initial), operationID });
          await waitingFirst;
          expect(picker.trigger.clicks).toBe(2); expect(clocks[0].request.operationID).toBe(operationID);
          expect(clocks[0].request.milliseconds).toBeGreaterThan(0); expect(clocks[0].request.milliseconds).toBeLessThanOrEqual(900);
          expect(f.world.__computaModelSelection.familyCloseAcknowledged).toBe(true);
          f.advanceTime(901); clocks[0].expire();
          if (ignoreRecovery) {
            await waitingSecond;
            expect(picker.trigger.clicks).toBe(3); expect(clocks[1].request.milliseconds).toBeLessThanOrEqual(900);
            f.advanceTime(901); clocks[1].expire();
          }
          const result = await pending;
          expect(f.world.__computaModelSelection.openingRecoveryAttempted).toBe(true);
          expect(picker.familyOptions.map((node: any) => node.clicks)).toEqual([1, 0, 0]);
          expect(arrows(picker)).toHaveLength(0); expect(f.composer.textContent).toBe('');
          expect(f.world.__computaModelFirstSubmitted).toBeUndefined();
          if (ignoreRecovery) {
            expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined();
            expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified');
            expect(picker.trigger.clicks).toBe(3);
          } else {
            expect(result.selected).toBe(true); expect(result.modelEvidence.chatSelection.family.key).toBe('GPT-6');
            expect(picker.trigger.clicks).toBe(3);
          }
        }
      });
      test('a timed-out read cannot dismiss or mutate the popup claimed by its replacement', async () => {
        const { f, picker } = setup(); await f.run('inspect');
        const oldOperation = '7aac12d2-bcb5-486c-b5f3-244ae6d733b6';
        const replacementOperation = 'c160a144-3480-4768-883d-f5d459480451';
        let expireOld!: () => void, oldWaitStarted!: () => void, replacementWaitStarted!: () => void;
        const oldWaiting = new Promise<void>(resolve => { oldWaitStarted = resolve; });
        const replacementWaiting = new Promise<void>(resolve => { replacementWaitStarted = resolve; });
        f.window.webkit.messageHandlers.computaModelClock = { postMessage: (request: any) => new Promise<void>(resolve => {
          if (request.operationID === oldOperation) { expireOld = resolve; oldWaitStarted(); }
          else if (request.operationID === replacementOperation) replacementWaitStarted();
          else throw new Error('Unexpected fixture clock operation');
        }) };
        const open = picker.trigger.onClick, dismiss = picker.menu.onDispatch;
        picker.trigger.onClick = () => {}; // The first opening exists, but its DOM acknowledgement is delayed.
        const oldRead = f.run('verifyModel', { expectedModelChoice: choice(initial), operationID: oldOperation });
        await oldWaiting;
        expect(picker.trigger.clicks).toBe(1);
        picker.trigger.onClick = open; picker.showPower();
        let heldReplacementClose = false;
        picker.menu.onDispatch = (event: any) => {
          if (event.key === 'Escape' && !heldReplacementClose) { heldReplacementClose = true; return; }
          dismiss(event);
        };
        const replacementRead = f.run('verifyModel', { expectedModelChoice: choice(initial), operationID: replacementOperation });
        await replacementWaiting;
        expect(heldReplacementClose).toBe(true);
        const effects = () => ({ opens: picker.trigger.clicks, panels: picker.secondary.clicks,
          dismissals: picker.menu.events.filter((event: any) => event.key === 'Escape').length, powers: arrows(picker).length });
        const before = effects(); expect(before.dismissals).toBe(1);
        expireOld();
        const stale = await oldRead;
        expect(stale.error).toBe('document_changed'); expect(stale.modelEvidence).toBeUndefined();
        expect(effects()).toEqual(before);
        expect(picker.menu.values.hidden).toBeUndefined();
        // Acknowledge only the replacement's already-dispatched Escape.
        picker.close();
        for (const observer of f.observers) observer.callback([{ type: 'attributes', target: picker.menu, attributeName: 'hidden' }]);
        const replacement = await replacementRead;
        expect(replacement).toMatchObject({ modelEvidence: { selected: choice(initial), source: selectionSource,
          chatSelection: { family: { key: 'GPT-6', label: 'GPT-6' }, power: { key: 'medium', label: 'Medium' } } } });
        expect(effects()).toEqual({ opens: 2, panels: 1, dismissals: 2, powers: 0 });
        expect(picker.menu.values.hidden).toBe(''); noSelection(f, picker);
      });
      test('ignored Escape is claimed once and its deadline cannot reopen or select', async () => {
        const { f, picker } = setup(); picker.menu.onDispatch = () => {};
        const result = await expire(f, f.run('selectModel', { modelChoice: choice(initial) }));
        expect(result.error).toBe('model_unverified'); expect(picker.menu.events.filter((event: any) => event.key === 'Escape')).toHaveLength(1);
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified');
        expect(picker.trigger.clicks).toBe(1); noSelection(f, picker);
      });
      test('lost Escape acknowledgment cannot dispatch another dismissal in finally or a later selection call', async () => {
        const { f, picker } = setup(); const dismiss = picker.menu.onDispatch;
        picker.menu.onDispatch = (event: any) => { dismiss(event); throw new Error('PRIVATE lost Escape'); };
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified');
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified');
        expect(picker.menu.events.filter((event: any) => event.key === 'Escape')).toHaveLength(1); noSelection(f, picker);
      });
      test('lost primary opening acknowledgment cannot replay its click', async () => {
        const { f, picker } = setup(); picker.trigger.onClick = () => { throw new Error('PRIVATE lost opening'); };
        expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(picker.trigger.clicks).toBe(1); noSelection(f, picker);
      });
      test('lost power-step acknowledgment never repeats an input already dispatched', async () => {
        const { f, picker } = setup(); const step = picker.powerItem.onDispatch;
        picker.powerItem.onDispatch = (event: any) => { step(event); throw new Error('PRIVATE lost power'); };
        expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        for (let retry = 0; retry < 3; retry++) expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified');
        expect(arrows(picker)).toHaveLength(1); expect(picker.slider.values['aria-valuenow']).toBe('2'); expect(f.composer.textContent).toBe('');
      });
      test('lost family-change acknowledgment never repeats the clicked newest row', async () => {
        const { f, picker } = setup(); picker.selected('GPT-5.6 Sol'); const node = picker.familyOptions[0], click = node.onClick;
        node.onClick = () => { click(); throw new Error('PRIVATE lost family'); };
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified');
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified');
        expect(node.clicks).toBe(1); expect(arrows(picker)).toHaveLength(0);
      });
      test('an ignored power step expires once without retry or accepting the old value', async () => {
        const { f, picker } = setup(); picker.powerItem.onDispatch = () => {};
        expect((await expire(f, f.run('selectModel', { modelChoice: choice(target) }))).error).toBe('model_unverified');
        expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified'); expect(arrows(picker)).toHaveLength(1);
      });
      test('an ignored newest-family click expires once without input replay', async () => {
        const { f, picker } = setup(); picker.selected('GPT-5.6 Sol'); const node = picker.familyOptions[0]; node.onClick = () => {};
        expect((await expire(f, f.run('selectModel', { modelChoice: choice(initial) }))).error).toBe('model_unverified');
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).error).toBe('model_unverified'); expect(node.clicks).toBe(1); expect(arrows(picker)).toHaveLength(0);
      });
      test('a delayed sequential power acknowledgment wakes through a DOM event without another input', async () => {
        const { f, picker } = setup(); const step = picker.powerItem.onDispatch; let event: any;
        picker.powerItem.onDispatch = (value: any) => { event = value; };
        const pending = f.run('selectModel', { modelChoice: choice(target) }); await microtasks();
        expect(event.key).toBe('ArrowRight'); expect(arrows(picker)).toHaveLength(1); step(event);
        for (const observer of f.observers) observer.callback([{ type: 'attributes', target: picker.slider, attributeName: 'aria-valuenow' }]);
        expect((await pending).selected).toBe(true); expect(arrows(picker)).toHaveLength(1);
      });
      test('a skipped power acknowledgment cannot be accepted as an observed sequential step', async () => {
        const { f, picker } = setup(); picker.powerItem.onDispatch = () => picker.selected('Pro');
        expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_unverified'); expect(arrows(picker)).toHaveLength(1);
      });
      test('completed selection cannot silently repair subsequent family or power drift', async () => {
        for (const drift of ['Medium', 'GPT-5.5']) {
          const { f, picker } = setup(); expect((await f.run('selectModel', { modelChoice: choice(target) })).selected).toBe(true);
          picker.selected(drift); const count = arrows(picker).length;
          expect((await f.run('selectModel', { modelChoice: choice(target) })).error).toBe('model_mismatch'); expect(arrows(picker)).toHaveLength(count);
          expect(picker.familyOptions.every((node: any) => node.clicks === 0)).toBe(true);
        }
      });
      test('physical trigger replacement or lost association after close cannot admit or reopen proof', async () => {
        for (const change of [
          (f: any, p: any) => { p.trigger.connected = false; f.body.append(new Node('BUTTON', { ...p.trigger.values })); },
          (f: any, p: any) => { p.trigger.disabled = true; },
          (f: any) => { f.body.append(new Node('DIV', { role: 'menu', id: 'foreign' })); },
        ]) {
          const { f, picker } = setup(); const dismiss = picker.menu.onDispatch;
          picker.menu.onDispatch = (event: any) => { dismiss(event); change(f, picker); };
          const result = await expire(f, f.run('verifyModel', { expectedModelChoice: choice(initial) }));
          expect(result.error).toBe('model_unverified'); expect(result.modelEvidence).toBeUndefined(); noSelection(f, picker);
        }
        // Association is mandatory while the physical popup is visible.
        const visible = setup(), showFamily = visible.picker.secondary.onClick;
        visible.picker.secondary.onClick = () => { showFamily(); delete visible.picker.trigger.values['aria-controls']; };
        const rejected = await expire(visible.f, visible.f.run('verifyModel', { expectedModelChoice: choice(initial) }));
        expect(rejected.error).toBe('model_unverified'); expect(rejected.modelEvidence).toBeUndefined(); noSelection(visible.f, visible.picker);

        // Actual closed chrome clears its IDREF after physically removing the popup.
        const closed = setup(), dismiss = closed.picker.menu.onDispatch;
        closed.picker.menu.onDispatch = (event: any) => { dismiss(event); delete closed.picker.trigger.values['aria-controls']; };
        const accepted = await closed.f.run('verifyModel', { expectedModelChoice: choice(initial) });
        expect(accepted.modelEvidence.selected).toEqual(choice(initial));
        expect(closed.picker.menu.isConnected).toBe(false); expect(closed.picker.trigger.clicks).toBe(1); noSelection(closed.f, closed.picker);
      });
      test('temporary mode hidden only by the owned popup must return before final admission', async () => {
        for (const drift of [false, true]) {
          const { f, picker } = setup(); const open = picker.trigger.onClick, dismiss = picker.menu.onDispatch;
          picker.trigger.onClick = () => { open(); f.temporary.values['aria-hidden'] = 'true'; };
          picker.menu.onDispatch = (event: any) => { dismiss(event); delete f.temporary.values['aria-hidden']; if (drift) f.temporary.connected = false; };
          const result = await f.run('verifyModel', { expectedModelChoice: choice(initial) });
          if (drift) expect(result.error).toBe('temporary_mode_unverified'); else expect(result.modelEvidence.selected).toEqual(choice(initial));
          noSelection(f, picker);
        }
      });
      test('a transient checked-power flip and restoration during a read still rejects', async () => {
        const { f, picker } = setup(); const dismiss = picker.menu.onDispatch; let flipped = false;
        picker.menu.onDispatch = (event: any) => {
          dismiss(event); if (flipped) return; flipped = true;
          picker.selected(target); picker.selected(initial);
          for (const observer of f.observers) observer.callback([{ type: 'attributes', target: picker.slider, attributeName: 'aria-valuenow', oldValue: '2' }]);
        };
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).error).toBe('model_mismatch'); noSelection(f, picker);
      });
      for (const field of ['power', 'family']) test(`a previously observed ${field} switch and restoration permanently invalidates the owned inference pin`, async () => {
        const { f, picker } = setup();
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
        const pin = f.world.__computaChatPresetPin;
        expect(pin.controls instanceof WeakMap).toBe(true);
        if (field === 'power') {
          picker.selected(target); picker.selected(initial);
          f.observers[0].callback([{ type: 'attributes', target: picker.slider, attributeName: 'aria-valuenow', oldValue: '2' }]);
        } else {
          picker.selected('GPT-5.5'); picker.selected('GPT-6');
          f.observers[0].callback([{ type: 'attributes', target: picker.familyOptions[0], attributeName: 'aria-checked', oldValue: 'false' },
            { type: 'attributes', target: picker.familyOptions[2], attributeName: 'aria-checked', oldValue: 'true' }]);
        }
        expect(pin.invalidated).toBe(true); const before = picker.trigger.clicks;
        for (const action of ['verifyModel', 'prepare', 'sendReady', 'submit']) {
          const result = await f.run(action, { expectedModelChoice: choice(initial), prompt: 'PRIVATE NEVER SENT' });
          expect(result.error).toBe('model_mismatch'); expect(result.modelEvidence).toBeUndefined(); expect(result.submitted).toBeUndefined();
        }
        expect(picker.trigger.clicks).toBe(before); noSelection(f, picker);
      });
      test('same-value tracked attributes and popup mount visibility never invalidate the observed pin', async () => {
        const { f, picker } = setup(false, { unmountMenus: true });
        expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
        const pin = f.world.__computaChatPresetPin; picker.showPower();
        f.observers[0].callback([{ type: 'attributes', target: picker.slider, attributeName: 'aria-valuenow', oldValue: '1' },
          { type: 'attributes', target: picker.familyOptions[0], attributeName: 'aria-checked', oldValue: 'true' },
          { type: 'attributes', target: picker.menu, attributeName: 'hidden', oldValue: '' },
          { type: 'childList', target: f.body, addedNodes: [picker.menu], removedNodes: [] }]);
        expect(pin.invalidated).toBeUndefined(); picker.close();
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial)); noSelection(f, picker);
      });
      test('foreign and conversation-authored controls cannot invalidate a previously observed selection pin', async () => {
        const { f, picker } = setup(); expect((await f.run('selectModel', { modelChoice: choice(initial) })).selected).toBe(true);
        const pin = f.world.__computaChatPresetPin;
        const foreign = new Node('SPAN', { role: 'slider', 'aria-valuenow': '4' });
        const authored = new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'true' }, 'GPT-999');
        f.answer.append(authored);
        f.observers[0].callback([{ type: 'attributes', target: foreign, attributeName: 'aria-valuenow', oldValue: '1' },
          { type: 'attributes', target: authored, attributeName: 'aria-checked', oldValue: 'false' }]);
        expect(pin.invalidated).toBeUndefined();
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial)); noSelection(f, picker);
      });
      test('generic and established reads never gain opening replay after an unacknowledged click', async () => {
        for (const owned of [false, true]) {
          const { f, picker } = setup(owned); if (owned) await f.run('inspect', { expectedModelChoice: choice(initial) });
          const before = picker.trigger.clicks;
          let markOpened!: () => void; const opened = new Promise<void>(resolve => { markOpened = resolve; });
          picker.trigger.onClick = () => markOpened();
          const pending = f.run('verifyModel', { expectedModelChoice: choice(initial) });
          await opened; // Expire only after digest work reaches this exact owned opening.
          expect((await expire(f, pending)).error).toBe('model_unverified');
          expect(picker.trigger.clicks - before).toBe(1); expect(arrows(picker)).toHaveLength(0);
        }
      });
      test('failed discovery closure retains its one claimed dismissal across repeated discovery calls', async () => {
        const { f, picker } = setup(); picker.menu.onDispatch = () => {};
        const result = await expire(f, f.run('discoverModels')); expect(result.error).toBe('model_unverified');
        expect((await f.run('discoverModels')).error).toBe('model_unverified');
        expect(picker.menu.events.filter((event: any) => event.key === 'Escape')).toHaveLength(1); expect(picker.trigger.clicks).toBe(1); noSelection(f, picker);
      });
    }

    test('a generic header cannot reuse selection evidence when its menu association changed', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      await advance(f, 'selectModel', { modelChoice: choice(target) });
      delete picker.trigger.values['aria-controls']; delete picker.menu.values['aria-labelledby']; picker.open();
      expect(await f.run('verifyModel', { expectedModelChoice: choice(target) })).toMatchObject({ error: 'model_unverified' });
      expect(picker.options.find((option: any) => option.children[0].text === target).clicks).toBe(1);
    });

    test('generic-header verification catches drift during digest and does not admit a response', async () => {
      const { f, picker } = setup(true, { genericHeader: true, unmountMenus: true });
      f.onDigest(() => picker.selected(target));
      const result = await f.run('inspect', { expectedModelChoice: choice(initial) });
      expect(result).toMatchObject({ error: 'model_mismatch' }); expect(result.text).toBeUndefined();
      expect(picker.options.every((option: any) => option.clicks === 0)).toBe(true);
    });

    test('fresh picker reads do not generate a transport wake loop but real model and response changes wake', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      const observer = f.observers[0];
      observer.callback([{ type: 'childList', target: f.body, addedNodes: [picker.menu], removedNodes: [] },
        { type: 'attributes', target: picker.trigger, attributeName: 'aria-expanded' }]);
      f.flush(); expect(f.posted.length).toBe(0);
      if (provider === 'chatgpt') expect(observer.options.attributeFilter).toContain('aria-valuenow');
      observer.callback([{ type: 'attributes', target: provider === 'chatgpt' ? picker.slider : picker.options[0],
        attributeName: provider === 'chatgpt' ? 'aria-valuenow' : 'aria-checked' }]);
      f.flush(); expect(f.posted.length).toBe(1);
      observer.callback([{ type: 'childList', target: f.answer, addedNodes: [new Node('SPAN', {}, 'PRIVATE RESPONSE')], removedNodes: [] },
        { type: 'childList', target: f.body, addedNodes: [], removedNodes: [picker.menu] }]);
      f.flush(); expect(f.posted.length).toBe(2);
      expect(JSON.stringify(f.posted)).not.toContain('PRIVATE');
    });

    test('mount-time visibility of an exact controlled portal stays quiet before its root is tracked', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      const open = picker.trigger.onClick;
      let mountObserved = false;
      picker.trigger.onClick = () => {
        open();
        if (!picker.menu.isConnected || mountObserved) return;
        mountObserved = true;
        const scope = f.world.__computaModelReadUI;
        expect(scope.ids).toContain(picker.menu.getAttribute('id'));
        expect(scope.roots.includes(picker.menu)).toBe(false);
        // A real MutationObserver can deliver the newly appended portal's
        // visibility record before the awaited reader tracks its new root.
        f.observers[0].callback([
          { type: 'childList', target: f.body, addedNodes: [picker.menu], removedNodes: [] },
          { type: 'attributes', target: picker.menu, attributeName: 'style' },
          { type: 'attributes', target: picker.menu.children[0], attributeName: 'aria-hidden' },
        ]);
        f.flush(); expect(f.posted.length).toBe(0);
        f.observers[0].callback([{ type: 'attributes', target: provider === 'chatgpt' ? picker.slider : picker.options[0],
          attributeName: provider === 'chatgpt' ? 'aria-valuenow' : 'aria-checked' }]);
        f.flush(); expect(f.posted.length).toBe(1);
        const unrelated = new Node('DIV', { role: 'menu', id: 'unrelated-popup', hidden: '' }); f.body.append(unrelated);
        f.observers[0].callback([{ type: 'attributes', target: unrelated, attributeName: 'style' }]);
        f.flush(); expect(f.posted.length).toBe(2);
        const wrongRole = new Node('BUTTON', { id: picker.menu.getAttribute('id'), hidden: '' }); f.body.append(wrongRole);
        f.observers[0].callback([{ type: 'attributes', target: wrongRole, attributeName: 'style' }]);
        f.flush(); expect(f.posted.length).toBe(3);
        const messagePortal = new Node('DIV', { role: 'menu', id: picker.menu.getAttribute('id'), hidden: '' });
        messagePortal.append(new Node('SPAN', { 'data-message-author-role': 'assistant' }, 'PRIVATE RESPONSE'));
        f.body.append(messagePortal);
        f.observers[0].callback([{ type: 'attributes', target: messagePortal, attributeName: 'style' }]);
        f.flush(); expect(f.posted.length).toBe(4);
        expect(JSON.stringify(f.posted)).not.toContain('PRIVATE');
        for (const extra of [unrelated, wrongRole, messagePortal]) {
          f.body.children = f.body.children.filter((node: any) => node !== extra);
          extra.parentElement = null; extra.connected = false;
        }
      };
      expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial));
      expect(mountObserved).toBe(true);
    });

    if (provider === 'gemini') test('real Gemini selection class and marker changes wake while active-only chrome and portal changes do not', async () => {
      const { f, picker } = setup(false, { genericHeader: true, geminiMenuitemMarkers: true });
      await f.run('verifyModel', { expectedModelChoice: choice(initial) });
      expect(f.observers[0].options.attributeOldValue).toBe(true);
      picker.open();
      const observer = f.observers[0], row = picker.options[0];
      row.values.class = 'ng-star-inserted active focused';
      observer.callback([{ type: 'attributes', target: row, attributeName: 'class', oldValue: 'ng-star-inserted' }]);
      f.flush(); expect(f.posted.length).toBe(0);
      row.values.class += ' selected';
      observer.callback([{ type: 'attributes', target: row, attributeName: 'class', oldValue: 'ng-star-inserted active focused' }]);
      f.flush(); expect(f.posted.length).toBe(1);
      const marker = new Node('GEM-ICON', { 'aria-label': 'Selected' }); row.append(marker);
      observer.callback([{ type: 'childList', target: row, addedNodes: [marker], removedNodes: [] }]);
      f.flush(); expect(f.posted.length).toBe(2);
      row.children = row.children.filter((node: any) => node !== marker);
      observer.callback([{ type: 'childList', target: row, addedNodes: [], removedNodes: [marker] }]);
      f.flush(); expect(f.posted.length).toBe(3);
      row.values.class = 'ng-star-inserted active';
      observer.callback([{ type: 'attributes', target: row, attributeName: 'class', oldValue: 'ng-star-inserted active focused selected' }]);
      f.flush(); expect(f.posted.length).toBe(4);
      observer.callback([{ type: 'childList', target: f.body, addedNodes: [picker.menu], removedNodes: [] },
        { type: 'attributes', target: picker.menu, attributeName: 'class', oldValue: 'closed' }]);
      f.flush(); expect(f.posted.length).toBe(4);
      picker.menu.connected = false;
      observer.callback([{ type: 'childList', target: f.body, addedNodes: [], removedNodes: [picker.menu] },
        { type: 'childList', target: row, addedNodes: [marker], removedNodes: [] }]);
      f.flush(); expect(f.posted.length).toBe(4);
    });

    if (provider === 'chatgpt') test('actual ChatGPT Send claims its old count before click and a lost acknowledgment cannot replay', async () => {
      const { f } = setup();
      const prompt = 'Synthetic first submit\n\n' + markerLine;
      f.composer.text = prompt; f.world.__computaModelFirstPrompt = prompt;
      const send = new Node('BUTTON', { 'data-testid': 'send-button' }); f.body.append(send);
      send.onClick = () => { expect(f.world.__computaModelLastSubmissionCount).toBe(0); throw new Error('lost Send acknowledgment'); };
      await expect(f.run('submit', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial), prompt }))
        .rejects.toThrow('lost Send acknowledgment');
      expect(f.world.__computaModelLastSubmissionCount).toBe(0); expect(send.clicks).toBe(1);
      expect((await f.run('submit', { expectedUserCounts: [0, 1], expectedModelChoice: choice(initial), prompt })).error).toBe('conversation_changed');
      expect(send.clicks).toBe(1);
    });

    test('more than twenty replaced portal IDs keep newest ownership bounded and never suppress unrelated events', async () => {
      const { f, picker } = setup(false, { genericHeader: true, unmountMenus: true });
      let latest: any;
      for (let index = 0; index < 24; index++) {
        if (provider === 'chatgpt') latest = picker.replaceMenu(`fresh-model-menu-${index}`);
        else {
        latest = new Node('DIV', { id: `fresh-model-menu-${index}`, role: 'menu', 'aria-labelledby': 'model-picker-button', hidden: '' });
        latest.connected = false;
        const selected = new Node('DIV', { role: 'menuitemradio', 'aria-checked': 'true' });
        selected.append(new Node('SPAN', {}, initial)); latest.append(selected); f.body.append(latest);
        picker.trigger.values['aria-controls'] = latest.values.id;
        const current = latest;
        picker.trigger.onClick = () => {
          if (current.values.hidden === undefined) { current.values.hidden = ''; current.connected = false; }
          else { delete current.values.hidden; current.connected = true; }
        };
        if (provider === 'chatgpt') current.onDispatch = (event: any) => {
          if (event.key === 'Escape') { current.values.hidden = ''; current.connected = false; }
        };
        }
        const current = latest;
        expect((await f.run('verifyModel', { expectedModelChoice: choice(initial) })).modelEvidence.selected).toEqual(choice(initial));
        const scope = f.world.__computaModelReadUI;
        expect(scope.roots.length).toBeLessThanOrEqual(16); expect(scope.ids.length).toBeLessThanOrEqual(16);
        expect(scope.roots.includes(current)).toBe(true); expect(scope.roots.includes(picker.trigger)).toBe(true);
        expect(scope.ids.includes(current.values.id)).toBe(true);
        const before = f.posted.length;
        f.observers[0].callback([{ type: 'childList', target: f.body, addedNodes: [current], removedNodes: [] }]);
        f.flush(); expect(f.posted.length).toBe(before);
      }
      const before = f.posted.length;
      f.observers[0].callback([{ type: 'childList', target: f.answer, addedNodes: [new Node('SPAN', {}, 'PRIVATE RESPONSE')], removedNodes: [] }]);
      f.flush(); expect(f.posted.length).toBe(before + 1);
      f.observers[0].callback([{ type: 'attributes', target: picker.trigger, attributeName: 'aria-label' }]);
      f.flush(); expect(f.posted.length).toBe(before + 2);
    });

    test('response metadata diagnostics report model attribute names without promoting opaque values or prose', async () => {
      const { f } = setup(true);
      await f.run('inspect');
      const root = provider === 'chatgpt' ? f.answer.parentElement : f.response;
      root.values['data-model-id'] = 'PRIVATE OPAQUE BACKEND ID';
      const responseFamily = provider === 'chatgpt' ? 'GPT-6' : initial;
      root.values['data-model-label'] = responseFamily;
      f.answer.append(new Node('SPAN', {}, 'I am ' + target));
      const result = await f.run('modelDiagnostic');
      expect(result.modelDiagnostic.responseMetadata).toMatchObject({ present: true,
        modelAttributes: [{ name: 'data-model-id', recognizedFamily: null, valueLength: 25 },
          { name: 'data-model-label', recognizedFamily: responseFamily, valueLength: responseFamily.length }] });
      expect(JSON.stringify(result.modelDiagnostic)).not.toContain('PRIVATE');
      expect(result.modelEvidence?.response).toBeUndefined();
      const completed = await f.run('inspect', { expectedModelChoice: choice(initial) });
      expect(completed.modelDiagnostic.responseMetadata.modelAttributes).toEqual(result.modelDiagnostic.responseMetadata.modelAttributes);
      expect(completed.modelEvidence.verification).toBe('website_selection');
    });

    test('cleanup Stop remains usable after selected-model drift', async () => {
      const { f, picker } = setup();
      const stop = f.stop || new Node('BUTTON', { 'aria-label': 'Stop streaming' });
      if (!f.stop) f.body.append(stop); else stop.connected = true;
      expect(await f.run('stop', { expectedModelChoice: choice(target) })).toMatchObject({ stopped: true });
      expect(stop.clicks).toBe(1); expect(picker.trigger.clicks).toBe(0);
    });

    test('discovery and selection cannot mutate nonempty conversations', async () => {
      const { f, picker } = setup(true);
      await f.run('inspect');
      for (const action of ['discoverModels', 'selectModel'])
        expect(await f.run(action, { modelChoice: choice(target) })).toMatchObject({ error: 'not_fresh' });
      expect(picker.trigger.clicks).toBe(0);
    });

    test('bounded diagnostics omit private prompt, reply and account data', async () => {
      const { f, picker } = setup(true);
      await f.run('inspect');
      f.answer.append(new Node('SPAN', {}, 'PRIVATE REPLY SENTINEL'));
      picker.trigger.values['data-account-id'] = 'PRIVATE ACCOUNT SENTINEL';
      const result = await f.run('modelDiagnostic');
      const serialized = JSON.stringify(result.modelDiagnostic);
      expect(serialized).not.toContain('PRIVATE'); expect(serialized).not.toContain('Computa session marker');
      expect(serialized.length).toBeLessThanOrEqual(8192);
    });
  });
}
