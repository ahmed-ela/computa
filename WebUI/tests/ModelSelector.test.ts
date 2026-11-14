import 'octane/compiler/register';
import { describe, expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { decodeHTML, decodeHTMLAttribute } from 'entities/decode';
import type { ModelOption } from '../src/types';

mock.module('@octanejs/shadcn/Button', () => ({ Button: ({ variant: _variant, size: _size, ...props }: Record<string, unknown>) => h('button', props) }));
// Expose the supplied provider hierarchy, radio values and disabled state.
// Keyboard, focus, portals and submenu interaction belong to the real DropdownMenu
// and require browser verification; these mocks do not simulate that behavior.
const selectionHandlers: ((value: string) => void)[] = [];
mock.module('@octanejs/shadcn/DropdownMenu', () => ({
  DropdownMenu: ({ children, open }: Record<string, unknown>) => h('div', { 'data-menu-open': Boolean(open), children }),
  DropdownMenuTrigger: ({ asChild, children, ...props }: Record<string, unknown>) => asChild
    ? h('span', { 'data-model-trigger': '', children })
    : h('button', { 'data-model-trigger': '', ...props, children }),
  DropdownMenuPortal: ({ children }: Record<string, unknown>) => children,
  DropdownMenuContent: ({ align: _align, side: _side, sideOffset: _sideOffset, collisionPadding: _collisionPadding,
    onCloseAutoFocus: _onCloseAutoFocus, onEscapeKeyDown: _onEscapeKeyDown,
    onPointerDownOutside: _onPointerDownOutside, ...props }: Record<string, unknown>) => h('div', { role: 'menu', 'data-model-menu': '', ...props }),
  DropdownMenuSub: ({ children }: Record<string, unknown>) => h('div', { 'data-submenu': '', children }),
  DropdownMenuSubTrigger: ({ disabled, textValue: _textValue, ...props }: Record<string, unknown>) => h('div', {
    role: 'menuitem', 'data-provider-trigger': '', 'aria-disabled': disabled ? 'true' : undefined, ...props,
  }),
  DropdownMenuSubContent: ({ align: _align, side: _side, sideOffset: _sideOffset, collisionPadding: _collisionPadding,
    ...props }: Record<string, unknown>) => h('div', {
    role: 'menu', 'data-submenu-content': '', ...props,
  }),
  DropdownMenuItem: ({ disabled, ...props }: Record<string, unknown>) => h('div', {
    role: 'menuitem', 'aria-disabled': disabled ? 'true' : undefined, ...props,
  }),
  DropdownMenuRadioGroup: ({ children, value, onValueChange }: Record<string, unknown>) => {
    if (typeof onValueChange === 'function') selectionHandlers.push(onValueChange as (value: string) => void);
    return h('div', { role: 'group', 'data-model-value': value, children });
  },
  DropdownMenuRadioItem: ({ value, disabled, textValue, ...props }: Record<string, unknown>) => h('div', {
    role: 'menuitemradio', 'data-value': value, 'aria-disabled': disabled ? 'true' : undefined,
    'data-text-value': textValue, ...props,
  }),
}));
const { ModelSelector, WebsiteModelsRefresh, groupModelOptions, modelOptionLabel, websiteModelsRefreshAction } = await import('../src/ModelSelector');
const { ModelProviderIcon } = await import('../src/ModelProviderIcon');

const options: ModelOption[] = [
  { id: 'browser/chatgpt', label: 'ChatGPT / Website default · Built-in browser', detail: 'Default website routing', highMemory: false },
  { id: 'browser/chatgpt/choice/fast', label: 'ChatGPT / Fixture Fast · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
  { id: 'browser/chatgpt/choice/pro', label: 'ChatGPT / Fixture Pro · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
  { id: 'browser/gemini/choice/fast', label: 'Gemini / Fixture Fast · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
  { id: 'browser/claude/choice/old', label: 'Claude / Fixture Old · Built-in browser', detail: 'Refresh after sign-in; never substitute', highMemory: false, available: false },
  { id: 'browser/gemini', label: 'Gemini / Website default · Built-in browser', detail: 'Default website routing', highMemory: false },
  { id: 'browser/claude', label: 'Claude / Website default · Built-in browser', detail: 'Default website routing', highMemory: false },
  { id: 'browser/groq', label: 'Groq / Website default · Built-in browser', detail: 'Default website routing', highMemory: false },
  { id: 'browser/groq/choice/observed', label: 'Groq / Fixture Groq · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
];
const selectableOptions = [options[1], options[2], options[3], options[4], options[8]];
const selector = (model = options[1].id, label = 'Task model', disabled = false) => renderToStaticMarkup(h(ModelSelector, {
  options, model, label, disabled, onSelect: () => {},
})).html;

describe('website model selectors', () => {
  test('groups use canonical provider identities and preserve provider and model order', () => {
    const claudeAPI = { ...options[1], id: 'api/claude/model/shared', label: 'Other label / Fixture Fast · API' };
    const input = [options[1], options[3], options[2], options[4], claudeAPI, options[8]];
    const original = structuredClone(input);
    const groups = groupModelOptions(input, options[1].id);
    expect(groups.map(({ id, name, options: models }) => ({ id, name, ids: models.map(({ id }) => id) }))).toEqual([
      { id: 'chatgpt', name: 'ChatGPT', ids: [options[1].id, options[2].id] },
      { id: 'gemini', name: 'Gemini', ids: [options[3].id] },
      { id: 'claude', name: 'Claude', ids: [options[4].id, claudeAPI.id] },
      { id: 'groq', name: 'Groq', ids: [options[8].id] },
    ]);
    for (const group of groups) expect(group.iconModel.split('/')[1]).toBe(group.id);
    expect(input).toEqual(original);
  });

  test('the first menu level contains provider icons and names, with only their models in each submenu', async () => {
    const html = selector();
    const groups = await renderedProviderGroups(html);
    expect(groups.map(({ name, ids }) => ({ name, ids }))).toEqual([
      { name: 'ChatGPT', ids: [options[1].id, options[2].id] },
      { name: 'Gemini', ids: [options[3].id] },
      { name: 'Claude', ids: [options[4].id] },
      { name: 'Groq', ids: [options[8].id] },
    ]);
    expect(groups.map(({ icons }) => icons)).toEqual([['chatgpt'], ['gemini'], ['claude'], ['groq']]);
    expect(await attributesBySelector(html, '[data-model-menu] > [role="menuitemradio"]', 'data-value')).toEqual([]);
    expect(await attributesBySelector(html, '[data-submenu-content] [data-provider]', 'data-provider')).toEqual([]);
    expect((await parsedElements(html)).filter((element) => element.attributes.role === 'menuitem')).toHaveLength(4);
  });

  test('unknown providers use their label prefix or provider ID without merging distinct providers', async () => {
    const custom = [
      { ...options[1], id: 'api/custom/model/first', label: 'Custom Provider / Shared model · API' },
      { ...options[1], id: 'api/other/model/first', label: 'Custom Provider / Shared model · API' },
      { ...options[1], id: 'api/toString/model/first', label: 'Standalone model · API' },
      { ...options[1], id: 'api/__proto__/model/first', label: 'Another model · API' },
    ];
    const groups = groupModelOptions(custom, custom[0].id);
    expect(groups.map(({ id, name, options: models }) => ({ id, name, ids: models.map(({ id }) => id) }))).toEqual([
      { id: 'custom', name: 'Custom Provider', ids: [custom[0].id] },
      { id: 'other', name: 'Custom Provider', ids: [custom[1].id] },
      { id: 'toString', name: 'toString', ids: [custom[2].id] },
      { id: '__proto__', name: '__proto__', ids: [custom[3].id] },
    ]);
    const html = renderToStaticMarkup(h(ModelSelector, { options: custom, model: custom[0].id, label: 'Task model', onSelect: () => {} })).html;
    expect((await renderedProviderGroups(html)).map(({ ids }) => ids)).toEqual(custom.map(({ id }) => [id]));
  });

  test('composer and Settings show model names while keeping provider identity accessible', async () => {
    for (const label of ['Task model', 'Default model for new tasks']) {
      const html = selector(options[1].id, label);
      const elements = await parsedElements(html);
      expect(elements.find((element) => element.tag === 'button' && 'aria-label' in element.attributes)?.attributes['aria-label'])
        .toBe(`${label}: ChatGPT / Fixture Fast`);
      const names = await textBySelector(html, '.model-option-name');
      expect(names).toEqual([modelOptionLabel(options[1]), ...selectableOptions.map(modelOptionLabel)]);
      const providerText = (await textBySelector(html, '[data-provider-trigger]')).join(' ');
      for (const provider of ['ChatGPT', 'Gemini', 'Claude', 'Groq']) expect(providerText).toContain(provider);
      expect(names.join(' ')).not.toContain('Built-in browser');
      expect(names.join(' ')).not.toContain('ChatGPT /');
    }
  });

  test('identical model names across providers retain their exact selection IDs', async () => {
    const html = selector(options[3].id);
    const elements = await parsedElements(html);
    expect(elements.find((element) => element.attributes['data-model-value'])?.attributes['data-model-value'])
      .toBe(options[3].id);
    expect(elements.find((element) => element.tag === 'button' && 'aria-label' in element.attributes)?.attributes['aria-label'])
      .toBe('Task model: Gemini / Fixture Fast');
    expect(elements.filter((element) => element.attributes.role === 'menuitemradio').map((element) => element.attributes['data-value']))
      .toEqual(selectableOptions.map((option) => option.id));
    expect((await textBySelector(html, '.model-option-name')).filter((name) => name === 'Fixture Fast')).toHaveLength(3);
    expect((await renderedProviderGroups(html)).filter(({ name }) => ['ChatGPT', 'Gemini'].includes(name))
      .map(({ name, ids }) => ({ name, ids }))).toEqual([
      { name: 'ChatGPT', ids: [options[1].id, options[2].id] },
      { name: 'Gemini', ids: [options[3].id] },
    ]);
  });

  test('only the provider prefix and metadata suffix are removed from long or slash-containing names', async () => {
    const name = 'organization/model / Detailed model name with a long context window';
    const option = { ...options[1], id: 'api/cerebras/model/fixture', label: `Cerebras / ${name} · API` };
    expect(modelOptionLabel(option)).toBe(name);
    expect(modelOptionLabel({ ...option, label: 'Standalone model · API' })).toBe('Standalone model');
    const html = renderToStaticMarkup(h(ModelSelector, { options: [option], model: option.id, label: 'Task model', onSelect: () => {} })).html;
    expect(await textBySelector(html, '.model-option-name')).toEqual([name, name]);
  });

  test('saved missing choices remain visible and disabled without choosing a fallback', async () => {
    const html = selector(options[4].id);
    expect(html).toContain('(unavailable)');
    expect(await textBySelector(html, '.model-option-name')).toContain('Fixture Old');
    const items = (await parsedElements(html)).filter((element) => element.attributes.role === 'menuitemradio');
    expect(items.find((element) => element.attributes['data-value'] === options[4].id)?.attributes['aria-disabled']).toBe('true');
    expect(html).toContain('Refresh after sign-in; never substitute');
    const unknown = selector('browser/claude/choice/missing');
    expect(await textBySelector(unknown, '.model-option-name')).toContain('browser/claude/choice/missing');
    const unknownElements = await parsedElements(unknown);
    expect(unknownElements.find((element) => element.attributes['data-model-value'])?.attributes['data-model-value'])
      .toBe('browser/claude/choice/missing');
    expect(unknownElements.find((element) => element.attributes['data-value'] === 'browser/claude/choice/missing')?.attributes['aria-disabled'])
      .toBe('true');
    expect((await renderedProviderGroups(unknown)).find(({ name }) => name === 'Claude')?.ids)
      .toEqual([options[4].id, 'browser/claude/choice/missing']);
    expect(unknownElements.filter((element) => 'data-provider-trigger' in element.attributes)
      .every((element) => element.attributes['aria-disabled'] !== 'true')).toBe(true);
  });

  test('Groq selection keeps the exact observed name and a missing saved choice stays unavailable', async () => {
    const observed = selector(options[8].id);
    const elements = await parsedElements(observed);
    expect(elements.find((element) => element.tag === 'button' && 'aria-label' in element.attributes)?.attributes['aria-label'])
      .toBe('Task model: Groq / Fixture Groq');
    expect((await textBySelector(observed, '.model-option-name'))[0]).toBe('Fixture Groq');
    expect(elements.find((element) => element.attributes['data-value'] === options[8].id)?.attributes['aria-disabled'])
      .toBeUndefined();
    const missing = 'browser/groq/choice/missing';
    const staleElements = await parsedElements(selector(missing));
    expect(staleElements.find((element) => element.attributes['data-model-value'])?.attributes['data-model-value']).toBe(missing);
    expect(staleElements.find((element) => element.attributes['data-value'] === missing)?.attributes['aria-disabled']).toBe('true');
    expect(staleElements.some((element) => element.attributes['data-value'] === 'browser/groq')).toBe(false);
  });

  test('native-hidden Groq and aliased Cerebras choices keep saved labels and can be switched away from', async () => {
    const groq = { ...options[8], selectable: false };
    const cerebras = { ...options[1], id: 'api/custom-endpoint/model/gpt-oss',
      label: 'Custom Endpoint / Saved Cerebras · API', selectable: false };
    const input = [groq, options[1], cerebras, options[3], options[2], options[4]];
    for (const hidden of [groq, cerebras]) {
      const selected: string[] = [];
      selectionHandlers.length = 0;
      const html = renderToStaticMarkup(h(ModelSelector, { options: input, model: hidden.id, label: 'Task model',
        onSelect: (value: string) => selected.push(value) })).html;
      expect((await renderedProviderGroups(html)).map(({ name, ids }) => ({ name, ids }))).toEqual([
        { name: 'ChatGPT', ids: [options[1].id, options[2].id] },
        { name: 'Gemini', ids: [options[3].id] },
        { name: 'Claude', ids: [options[4].id] },
      ]);
      const trigger = (await parsedElements(html)).find(({ tag, attributes }) => tag === 'button' && 'aria-label' in attributes);
      expect(trigger?.attributes['aria-label']).toBe(`Task model: ${hidden.label.split(' · ')[0]}`);
      expect(trigger?.attributes).not.toHaveProperty('disabled');
      expect((await textBySelector(html, '.model-option-name'))[0]).toBe(modelOptionLabel(hidden));
      expect(selected).toEqual([]);
      const change = selectionHandlers[0];
      change(groq.id);
      change(cerebras.id);
      expect(selected).toEqual([]);
      change(options[3].id);
      expect(selected).toEqual([options[3].id]);
    }
  });

  test('custom APIs using paused provider IDs retain their configured names and generic marks', async () => {
    for (const provider of ['cerebras', 'groq']) {
      const custom = { ...options[1], id: `api/${provider}/model/custom`, label: 'Custom Endpoint / Fixture API · API' };
      const saved = { ...options[1], id: `api/${provider}/model/saved`,
        label: `${provider} / Saved paused model · API`, selectable: false };
      const selected: string[] = [];
      selectionHandlers.length = 0;
      const props = { options: [saved, custom, options[8]], label: 'Task model',
        onSelect: (value: string) => selected.push(value) };
      const html = renderToStaticMarkup(h(ModelSelector, { ...props, model: custom.id })).html;
      expect(await renderedProviderGroups(html)).toEqual([
        { name: 'Custom Endpoint', icons: [], ids: [custom.id] },
        { name: 'Groq', icons: ['groq'], ids: [options[8].id] },
      ]);
      expect(await attributesBySelector(html, 'button[aria-label]', 'aria-label'))
        .toContain('Task model: Custom Endpoint / Fixture API');
      expect(await attributesBySelector(html, '.model-option-label [data-provider]', 'data-provider')).toEqual([]);
      expect(await attributesBySelector(html, '.model-option-label [aria-hidden="true"]', 'aria-hidden')).toEqual(['true']);

      selectionHandlers.length = 0;
      const savedHTML = renderToStaticMarkup(h(ModelSelector, { ...props, model: saved.id })).html;
      expect(await attributesBySelector(savedHTML, '.model-option-label [data-provider]', 'data-provider')).toEqual([provider]);
      expect(await attributesBySelector(savedHTML, '[role="menuitemradio"]', 'data-value')).not.toContain(saved.id);
      selectionHandlers[0](custom.id);
      expect(selected).toEqual([custom.id]);
    }
  });

  test('new website providers display only supplied model choices and preserve missing selections', async () => {
    for (const [provider, name] of [['kimi', 'Kimi'], ['qwen', 'Qwen'], ['deepseek', 'DeepSeek']]) {
      const defaultModel = `browser/${provider}`;
      const choice = { ...options[1], id: `${defaultModel}/choice/observed`,
        label: `${name} / Fixture model / Exact name · Built-in browser` };
      const hiddenDefault = { ...choice, id: defaultModel, label: `${name} / Website default · Built-in browser` };
      const missing = `${defaultModel}/choice/missing`;
      const input = [hiddenDefault, choice];
      for (const model of [choice.id, missing]) {
        const html = renderToStaticMarkup(h(ModelSelector, { options: input, model, label: 'Task model', onSelect: () => {} })).html;
        const groups = await renderedProviderGroups(html);
        expect(groups.map(({ name, icons, ids }) => ({ name, icons, ids }))).toEqual([
          { name, icons: [provider], ids: model === missing ? [choice.id, missing] : [choice.id] },
        ]);
        expect((await textBySelector(html, '.model-option-name'))).toContain('Fixture model / Exact name');
        const items = (await parsedElements(html)).filter((element) => element.attributes.role === 'menuitemradio');
        expect(items.find((element) => element.attributes['data-value'] === choice.id)?.attributes['aria-disabled']).toBeUndefined();
        if (model === missing) expect(items.find((element) => element.attributes['data-value'] === missing)?.attributes['aria-disabled']).toBe('true');
      }
      expect(groupModelOptions([hiddenDefault], defaultModel)).toEqual([]);
      expect(groupModelOptions([], options[1].id).some(({ id }) => id === provider)).toBe(false);
      const selected: string[] = [];
      selectionHandlers.length = 0;
      renderToStaticMarkup(h(ModelSelector, { options: input, model: missing, label: 'Task model',
        onSelect: (value: string) => selected.push(value) }));
      const change = selectionHandlers[0];
      for (const value of [defaultModel, missing, `${defaultModel}/choice/not-observed`]) change(value);
      expect(selected).toEqual([]);
      change(choice.id);
      expect(selected).toEqual([choice.id]);
    }
  });

  test('DeepSeek typed modes render provider-first human labels without asserting a backend model', async () => {
    const modes: ModelOption[] = ['Chat', 'DeepThink'].map((label) => ({
      id: `browser/deepseek/mode/${label.toLowerCase()}`, label: `DeepSeek / ${label} · Built-in browser`,
      detail: `Uses ${label} with Search off. No backend model or version is attested.`, highMemory: false, available: true,
    }));
    const hidden = { ...modes[0], id: 'browser/deepseek', label: 'DeepSeek / Website default · Built-in browser' };
    const selected: string[] = [];
    selectionHandlers.length = 0;
    const html = renderToStaticMarkup(h(ModelSelector, { options: [hidden, ...modes], model: modes[0].id,
      label: 'Task model', onSelect: (value: string) => selected.push(value) })).html;
    expect(await renderedProviderGroups(html)).toEqual([{ name: 'DeepSeek', icons: ['deepseek'], ids: modes.map(({ id }) => id) }]);
    expect(await textBySelector(html, '.model-option-name')).toEqual(['Chat', 'Chat', 'DeepThink']);
    expect(html).toContain('aria-label="DeepSeek modes"');
    expect(html).toContain('No backend model or version is attested.');
    expect(html).not.toContain('>browser/deepseek/');
    selectionHandlers[0](modes[1].id);
    expect(selected).toEqual([modes[1].id]);
    const unavailable = renderToStaticMarkup(h(ModelSelector, { options: [{ ...modes[1], available: false }],
      model: modes[1].id, label: 'Task model', onSelect: () => {} })).html;
    expect(await textBySelector(unavailable, '.model-option-name')).toEqual(['DeepThink', 'DeepThink']);
    expect((await parsedElements(unavailable)).find((element) => element.attributes['data-value'] === modes[1].id)?.attributes['aria-disabled']).toBe('true');
  });

  test('DeepSeek refresh recognizes only the exact typed mode routes', () => {
    for (const mode of ['chat', 'deepthink']) {
      expect(websiteModelsRefreshAction(`browser/deepseek/mode/${mode}`)).toEqual({ action: 'refreshWebsiteModels', provider: 'deepseek' });
    }
    for (const invalid of ['browser/deepseek/mode/Chat', 'browser/deepseek/mode/pro', 'browser/deepseek/mode/chat/extra',
      'browser/deepseek/mode/chat\n', 'browser/qwen/mode/chat', 'api/deepseek/mode/chat']) {
      expect(websiteModelsRefreshAction(invalid)).toBeUndefined();
    }
  });

  test('saved local and website-default models stay readable but remain absent from the choices', async () => {
    const local = { id: 'local/saved-model', label: 'Local / Saved model · MLX', detail: 'Saved local selection', highMemory: false };
    for (const [model, name] of [[local.id, 'Saved model'], ['local/unknown-model', 'local/unknown-model'],
      ['browser/chatgpt', 'Website default'], ['browser/gemini', 'Website default'], ['browser/claude', 'Website default'],
      ['browser/groq', 'Website default']]) {
      const html = renderToStaticMarkup(h(ModelSelector, { options: [...options, local], model, label: 'Task model', onSelect: () => {} })).html;
      expect((await textBySelector(html, '.model-option-name'))[0]).toBe(name);
      const elements = await parsedElements(html);
      expect(elements.find((element) => element.attributes['data-model-value'])?.attributes['data-model-value']).toBe(model);
      expect(elements.filter((element) => element.attributes.role === 'menuitemradio').map((element) => element.attributes['data-value']))
        .toEqual(selectableOptions.map((option) => option.id));
    }
  });

  test('Alibaba offers only undated Qwen 3.7 Flash, retaining hidden saved choices only in the trigger', async () => {
    const flash = { ...options[1], id: 'api/alibaba/model/cXdlbjMuNy1mbGFzaA', label: 'Alibaba / Qwen 3.7 Flash · API' };
    const dated = { ...flash, id: 'api/alibaba/model/cXdlbjMuNy1mbGFzaC0yMDI2MTAzMQ' };
    const other = { ...flash, id: 'api/alibaba/model/cXdlbi1tYXg', label: 'Alibaba / Qwen Max · API' };
    const input = [...options, dated, flash, other];
    for (const model of [flash.id, dated.id, other.id, 'api/alibaba/model/saved-missing']) {
      expect(groupModelOptions(input, model).find(({ id }) => id === 'alibaba')?.options.map(({ id }) => id)).toEqual([flash.id]);
      const html = renderToStaticMarkup(h(ModelSelector, { options: input, model, label: 'Task model', onSelect: () => {} })).html;
      const elements = await parsedElements(html);
      expect(elements.filter((element) => element.attributes.role === 'menuitemradio')
        .map((element) => element.attributes['data-value']).filter((id) => id.startsWith('api/alibaba/'))).toEqual([flash.id]);
      expect(elements.find((element) => element.attributes['data-model-value'])?.attributes['data-model-value']).toBe(model);
      expect((await textBySelector(html, '.model-option-name'))[0]).toBe(input.find(({ id }) => id === model)
        ? modelOptionLabel(input.find(({ id }) => id === model)!) : model);
    }
    expect(groupModelOptions([dated, other], other.id)).toEqual([]);
  });

  test('model changes preserve exact IDs and ignore busy, unchanged, unavailable or hidden choices', () => {
    for (const disabled of [false, true]) {
      const selected: string[] = [];
      selectionHandlers.length = 0;
      renderToStaticMarkup(h(ModelSelector, { options, model: options[1].id, label: 'Task model', disabled,
        onSelect: (value: string) => selected.push(value) }));
      expect(selected).toEqual([]);
      expect(selectionHandlers.length).toBeGreaterThan(0);
      const change = selectionHandlers[0];
      for (const value of [options[1].id, options[4].id, 'browser/claude/choice/missing',
        'browser/chatgpt', 'local/saved-model', 'api/alibaba/model/saved-missing', 'unknown']) change(value);
      expect(selected).toEqual([]);
      change(options[3].id);
      expect(selected).toEqual(disabled ? [] : [options[3].id]);
    }
  });

  test('a catalog containing only hidden choices shows a disabled empty state without inventing a provider', async () => {
    const hidden = [options[0], options[5], options[6], options[7],
      { ...options[1], id: 'local/saved-model', label: 'Local / Saved model · MLX' }];
    const html = renderToStaticMarkup(h(ModelSelector, { options: hidden, model: 'local/saved-model', label: 'Task model', onSelect: () => {} })).html;
    expect(groupModelOptions(hidden, 'local/saved-model')).toEqual([]);
    expect(await renderedProviderGroups(html)).toEqual([]);
    expect((await textBySelector(html, '.model-option-name'))[0]).toBe('Saved model');
    const items = (await parsedElements(html)).filter((element) => element.attributes.role === 'menuitem');
    expect(items).toHaveLength(1);
    expect(items[0].attributes['aria-disabled']).toBe('true');
    expect(await textBySelector(html, '[role="menuitem"]')).toEqual(['No models available']);
  });

  test('provider identities map to local decorative marks and unknown providers use the generic icon', async () => {
    for (const [model, provider, asset] of [
      ['browser/chatgpt/choice/fast', 'chatgpt', 'openai'],
      ['api/openai/model/fixture', 'openai', 'openai'],
      ['browser/claude/choice/fast', 'claude', 'claude'],
      ['browser/groq/choice/observed', 'groq', 'groq'],
      ['browser/kimi/choice/observed', 'kimi', 'kimi'],
      ['browser/qwen/choice/observed', 'qwen', 'qwen'],
      ['browser/deepseek/choice/observed', 'deepseek', 'deepseek'],
      ['api/cerebras/model/fixture', 'cerebras', 'cerebras'],
    ]) {
      const elements = await parsedElements(renderToStaticMarkup(h(ModelProviderIcon, { model })).html);
      const mark = elements.find((element) => element.attributes['data-provider'] === provider);
      expect(mark).toBeDefined();
      expect(mark?.attributes['aria-hidden']).toBe('true');
      expect(mark?.attributes.style).toContain(`/providers/${asset}.svg`);
      expect(mark?.attributes.style).not.toMatch(/https?:/);
    }
    for (const model of ['api/custom/model/fixture', 'api/toString/model/fixture', 'api/__proto__/model/fixture', 'local/saved-model']) {
      const elements = await parsedElements(renderToStaticMarkup(h(ModelProviderIcon, { model })).html);
      expect(elements.some((element) => element.attributes['data-provider'])).toBe(false);
      // Other suites replace Icon with a decorative span; its root semantics,
      // rather than Lucide's SVG implementation, are the contract here.
      expect(elements[0]?.attributes['aria-hidden']).toBe('true');
    }
  });

  test('official color marks stay local and Alibaba API branding remains distinct from Qwen website', async () => {
    for (const [model, provider, asset] of [
      ['browser/gemini/choice/fast', 'gemini', 'gemini.png'],
      ['api/gemini/model/fixture', 'gemini', 'gemini.png'],
      ['api/alibaba/model/cXdlbjMuNy1mbGFzaA', 'alibaba', 'alibaba-cloud.png'],
    ]) {
      const elements = await parsedElements(renderToStaticMarkup(h(ModelProviderIcon, { model })).html);
      const mark = elements.find((element) => element.attributes['data-provider'] === provider);
      expect(mark?.tag).toBe('img');
      expect(mark?.attributes.src).toEndWith(`/providers/${asset}`);
      expect(mark?.attributes.src).not.toMatch(/^https?:/);
      expect(mark?.attributes).toMatchObject({ alt: '', 'aria-hidden': 'true', width: '16', height: '16' });
      expect(mark?.attributes.class).toContain('model-provider-icon-color');
      expect(mark?.attributes.style).toBeUndefined();
    }
    const qwen = renderToStaticMarkup(h(ModelProviderIcon, { model: 'browser/qwen/choice/observed' })).html;
    expect(qwen).toContain('/providers/qwen.svg');
    expect(qwen).not.toContain('alibaba-cloud');
    const unsupported = renderToStaticMarkup(h(ModelProviderIcon, { model: 'browser/alibaba/choice/fixture' })).html;
    expect(unsupported).not.toContain('alibaba-cloud');

    const alibaba = { ...options[1], id: 'api/alibaba/model/cXdlbjMuNy1mbGFzaA', label: 'Alibaba / Qwen 3.7 Flash · API' };
    const website = { ...options[1], id: 'browser/qwen/choice/observed', label: 'Qwen / Qwen3.7-Plus · Built-in browser' };
    const html = renderToStaticMarkup(h(ModelSelector, {
      options: [alibaba, website], model: alibaba.id, label: 'Task model', onSelect: () => {},
    })).html;
    expect(await renderedProviderGroups(html)).toEqual([
      { name: 'Alibaba', icons: ['alibaba'], ids: [alibaba.id] },
      { name: 'Qwen', icons: ['qwen'], ids: [website.id] },
    ]);
    expect((await textBySelector(html, '[data-submenu-content] .model-option-name'))).toEqual(['Qwen 3.7 Flash', 'Qwen3.7-Plus']);
  });

  test('busy tasks disable model input and discovery refresh reflects its state', async () => {
    const disabled = selector(options[1].id, 'Task model', true);
    expect((await parsedElements(disabled)).find((element) => element.tag === 'button' && 'aria-label' in element.attributes)?.attributes).toHaveProperty('disabled');
    expect(disabled).toContain('data-menu-open="false"');
    const items = (await parsedElements(disabled)).filter((element) => element.attributes.role === 'menuitemradio');
    expect(items).toHaveLength(selectableOptions.length);
    expect(items.every((element) => element.attributes['aria-disabled'] === 'true')).toBe(true);
    const idle = renderToStaticMarkup(h(WebsiteModelsRefresh, { canRefresh: true, onRefresh: () => {} })).html;
    const running = renderToStaticMarkup(h(WebsiteModelsRefresh, { canRefresh: true, refreshing: true, onRefresh: () => {} })).html;
    expect(idle).toContain('Refresh models');
    expect(idle).toContain('aria-label="Refresh website models"');
    expect(idle).not.toMatch(/<button[^>]*disabled/);
    expect(running).toContain('Refreshing…');
    expect(running).toMatch(/<button[^>]*disabled/);
  });

  test('discovery refresh requires explicit native idle permission in composer and Settings', () => {
    for (const canRefresh of [false, undefined]) {
      const blocked = renderToStaticMarkup(h(WebsiteModelsRefresh, { canRefresh, onRefresh: () => {} })).html;
      expect(blocked).toMatch(/<button[^>]*disabled/);
      expect(blocked).toContain('Finish active tasks and approvals');
      expect(blocked).toContain('aria-label="Refresh website models"');
    }
    const allowed = renderToStaticMarkup(h(WebsiteModelsRefresh, { canRefresh: true, onRefresh: () => {} })).html;
    expect(allowed).not.toMatch(/<button[^>]*disabled/);
    expect(allowed).toContain('Read the model choices available');
  });

  test('task refresh addresses only its selected website provider for default and concrete choices', () => {
    for (const [provider, label] of [['gemini', 'Gemini'], ['chatgpt', 'ChatGPT'], ['claude', 'Claude'], ['groq', 'Groq'],
      ['kimi', 'Kimi'], ['qwen', 'Qwen'], ['deepseek', 'DeepSeek']]) {
      for (const model of [`browser/${provider}`, `browser/${provider}/choice/eyJrZXkiOiJmaXh0dXJlIn0`]) {
        expect(websiteModelsRefreshAction(model)).toEqual({ action: 'refreshWebsiteModels', provider });
        const html = renderToStaticMarkup(h(WebsiteModelsRefresh, { model, canRefresh: true, onRefresh: () => {} })).html;
        expect(html).toContain(`aria-label="Refresh ${label} models"`);
        expect(html).toContain(`>Refresh ${label} models</button>`);
        expect(html).toContain(`signed-in ${label} website`);
      }
    }
    expect(websiteModelsRefreshAction()).toEqual({ action: 'refreshWebsiteModels' });
    expect(Object.keys(websiteModelsRefreshAction()!)).toEqual(['action']);
  });

  test('nonwebsite and malformed model scopes cannot request a global refresh', () => {
    for (const model of ['', 'local/model', 'api/cerebras/gpt-oss-120b', 'browser/unknown', 'browser/Gemini',
      'browser/gemini ', 'browser/gemini\n', 'browser/gemini/choice/value\n',
      'browser/gemini/choice/', 'browser/gemini/choice/value/extra', 'browser/gemini/not-choice/value',
      'browser/Groq', 'browser/groq-like', 'browser/groq/choice/', 'browser/groq/choice/value\n',
      'browser/groq/choice/value/extra', 'browser/groq/not-choice/value']) {
      expect(websiteModelsRefreshAction(model)).toBeUndefined();
      expect(renderToStaticMarkup(h(WebsiteModelsRefresh, { model, canRefresh: true, onRefresh: () => {} })).html).toBe('');
    }
  });

  test('scoped refresh retains idle permission and in-progress disabling', () => {
    for (const state of [{ canRefresh: false }, { canRefresh: undefined }, { canRefresh: true, refreshing: true }]) {
      const html = renderToStaticMarkup(h(WebsiteModelsRefresh, { model: 'browser/gemini', ...state, onRefresh: () => {} })).html;
      expect(html).toContain('aria-label="Refresh Gemini models"');
      expect(html).toMatch(/<button[^>]*disabled/);
    }
  });

  test('new provider refresh scopes reject lookalikes, API routes and malformed identities', () => {
    for (const provider of ['kimi', 'qwen', 'deepseek']) {
      for (const model of [`api/${provider}/model/fixture`, `browser/${provider.toUpperCase()}`, `browser/${provider}-like`,
        `browser/${provider}\n`, `browser/${provider}/choice/`, `browser/${provider}/choice/value\n`,
        `browser/${provider}/choice/value/extra`, `browser/${provider}/not-choice/value`]) {
        expect(websiteModelsRefreshAction(model)).toBeUndefined();
        expect(renderToStaticMarkup(h(WebsiteModelsRefresh, { model, canRefresh: true, onRefresh: () => {} })).html).toBe('');
      }
    }
  });

  test('observed website labels and IDs are escaped as text and attribute values', async () => {
    const malicious = { id: 'browser/claude/choice/"<script>', label: 'Claude / <script>alert(1)</script> · Built-in browser', detail: '<img src=x onerror=bad()>" autofocus onfocus="bad()', highMemory: false };
    const html = renderToStaticMarkup(h(ModelSelector, { options: [malicious], model: malicious.id, label: 'Task model', onSelect: () => {} })).html;
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    const elements = await parsedElements(html);
    expect(elements.map((element) => element.tag).filter((tag) => ['script', 'img', 'iframe', 'foreignObject'].includes(tag))).toEqual([]);
    expect(elements.find((element) => element.tag === 'button' && 'aria-label' in element.attributes)?.attributes.title).toBe(malicious.detail);
    expect(elements.find((element) => element.attributes.role === 'menuitemradio')?.attributes['data-value']).toBe(malicious.id);
    expect(await textBySelector(html, '.model-option-name')).toEqual(['<script>alert(1)</script>', '<script>alert(1)</script>']);
    for (const element of elements) {
      expect(element.attributes).not.toHaveProperty('onerror');
      expect(element.attributes).not.toHaveProperty('onfocus');
      expect(element.attributes).not.toHaveProperty('autofocus');
    }
    // Verify the parser detects actual tags rather than hiding an injection
    // through a substring assertion that ignores HTML attribute boundaries.
    expect((await parsedElements('<script>bad()</script><img src=x onerror=bad()>'))
      .map((element) => element.tag)).toEqual(['script', 'img']);
  });
});

async function textBySelector(html: string, selector: string): Promise<string[]> {
  const values: string[] = [];
  await new HTMLRewriter().on(selector, {
    element() { values.push(''); },
    text(chunk) { values[values.length - 1] += chunk.text; },
  }).transform(new Response(html)).text();
  return values.map((value) => decodeHTML(value));
}

async function attributesBySelector(html: string, selector: string, attribute: string): Promise<string[]> {
  const values: string[] = [];
  await new HTMLRewriter().on(selector, { element(element) {
    const value = element.getAttribute(attribute);
    if (value !== null) values.push(decodeHTMLAttribute(value));
  } }).transform(new Response(html)).text();
  return values;
}

async function renderedProviderGroups(html: string): Promise<{ name: string; ids: string[]; icons: string[] }[]> {
  const groups: { name: string; ids: string[]; icons: string[] }[] = [];
  await new HTMLRewriter()
    .on('[data-submenu]', { element() { groups.push({ name: '', ids: [], icons: [] }); } })
    .on('[data-provider-trigger]', { text(chunk) { groups[groups.length - 1].name += chunk.text; } })
    .on('[data-provider-trigger] [data-provider]', { element(element) {
      groups[groups.length - 1].icons.push(decodeHTMLAttribute(element.getAttribute('data-provider')!));
    } })
    .on('[data-submenu-content] [role="menuitemradio"]', { element(element) {
      groups[groups.length - 1].ids.push(decodeHTMLAttribute(element.getAttribute('data-value')!));
    } }).transform(new Response(html)).text();
  return groups.map((group) => ({ ...group, name: decodeHTML(group.name).trim() }));
}

async function parsedElements(html: string): Promise<{ tag: string; attributes: Record<string, string> }[]> {
  const elements: { tag: string; attributes: Record<string, string> }[] = [];
  await new HTMLRewriter().on('*', { element(element) {
    // HTMLRewriter supplies attribute source values. Decode once using HTML
    // attribute entity rules, after it has parsed actual element boundaries.
    elements.push({ tag: element.tagName, attributes: Object.fromEntries(
      [...element.attributes].map(([key, value]) => [key, decodeHTMLAttribute(value)])) });
  } }).transform(new Response(html)).text();
  return elements;
}
