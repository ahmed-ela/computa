import 'octane/compiler/register';
import { describe, expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { decodeHTML, decodeHTMLAttribute } from 'entities/decode';
import type { ModelOption } from '../src/types';

mock.module('@octanejs/shadcn/Button', () => ({ Button: ({ variant: _variant, size: _size, ...props }: Record<string, unknown>) => h('button', props) }));
// These mocks expose the selector's supplied content and state. Keyboard, focus,
// and portal behavior belong to the real Select and require browser verification.
mock.module('@octanejs/shadcn/Select', () => ({
  Select: ({ children, value, disabled }: Record<string, unknown>) => h('div', {
    'data-select-value': value, 'data-select-disabled': Boolean(disabled), children,
  }),
  SelectTrigger: ({ size: _size, ...props }: Record<string, unknown>) => h('button', { role: 'combobox', ...props }),
  SelectValue: (props: Record<string, unknown>) => h('span', props),
  SelectContent: ({ position: _position, align: _align, side: _side, sideOffset: _sideOffset,
    onCloseAutoFocus: _onCloseAutoFocus, onEscapeKeyDown: _onEscapeKeyDown,
    onPointerDownOutside: _onPointerDownOutside, ...props }: Record<string, unknown>) => h('div', { role: 'listbox', ...props }),
  SelectItem: ({ value, disabled, textValue, ...props }: Record<string, unknown>) => h('div', {
    role: 'option', 'data-value': value, 'aria-disabled': disabled ? 'true' : undefined,
    'data-text-value': textValue, ...props,
  }),
}));
const { ModelSelector, WebsiteModelsRefresh, modelOptionLabel, websiteModelsRefreshAction } = await import('../src/ModelSelector');
const { ModelProviderIcon } = await import('../src/ModelProviderIcon');

const options: ModelOption[] = [
  { id: 'browser/chatgpt', label: 'ChatGPT / Website default · Built-in browser', detail: 'Default website routing', highMemory: false },
  { id: 'browser/chatgpt/choice/fast', label: 'ChatGPT / Fixture Fast · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
  { id: 'browser/chatgpt/choice/pro', label: 'ChatGPT / Fixture Pro · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
  { id: 'browser/gemini/choice/fast', label: 'Gemini / Fixture Fast · Built-in browser', detail: 'Observed choice', highMemory: false, available: true },
  { id: 'browser/claude/choice/old', label: 'Claude / Fixture Old · Built-in browser', detail: 'Refresh after sign-in; never substitute', highMemory: false, available: false },
];
const selector = (model = options[1].id, label = 'Task model', disabled = false) => renderToStaticMarkup(h(ModelSelector, {
  options, model, label, disabled, onSelect: () => {},
})).html;

describe('website model selectors', () => {
  test('composer and Settings show model names while keeping provider identity accessible', async () => {
    for (const label of ['Task model', 'Default model for new tasks']) {
      const html = selector(options[1].id, label);
      const elements = await parsedElements(html);
      expect(elements.find((element) => element.attributes.role === 'combobox')?.attributes['aria-label'])
        .toBe(`${label}: ChatGPT / Fixture Fast`);
      const names = await textBySelector(html, '.model-option-name');
      expect(names).toEqual([modelOptionLabel(options[1]), ...options.map(modelOptionLabel)]);
      const providerText = (await textBySelector(html, '.sr-only')).join(' ');
      for (const provider of ['ChatGPT', 'Gemini', 'Claude']) expect(providerText).toContain(provider);
      expect(names.join(' ')).not.toContain('Built-in browser');
      expect(names.join(' ')).not.toContain('ChatGPT /');
    }
  });

  test('identical model names across providers retain their exact selection IDs', async () => {
    const html = selector(options[3].id);
    const elements = await parsedElements(html);
    expect(elements.find((element) => element.attributes['data-select-value'])?.attributes['data-select-value'])
      .toBe(options[3].id);
    expect(elements.find((element) => element.attributes.role === 'combobox')?.attributes['aria-label'])
      .toBe('Task model: Gemini / Fixture Fast');
    expect(elements.filter((element) => element.attributes.role === 'option').map((element) => element.attributes['data-value']))
      .toEqual(options.map((option) => option.id));
    expect((await textBySelector(html, '.model-option-name')).filter((name) => name === 'Fixture Fast')).toHaveLength(3);
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
    const items = (await parsedElements(html)).filter((element) => element.attributes.role === 'option');
    expect(items.find((element) => element.attributes['data-value'] === options[4].id)?.attributes['aria-disabled']).toBe('true');
    expect(html).toContain('Refresh after sign-in; never substitute');
    const unknown = selector('browser/claude/choice/missing');
    expect(await textBySelector(unknown, '.model-option-name')).toContain('browser/claude/choice/missing');
    const unknownElements = await parsedElements(unknown);
    expect(unknownElements.find((element) => element.attributes['data-select-value'])?.attributes['data-select-value'])
      .toBe('browser/claude/choice/missing');
    expect(unknownElements.find((element) => element.attributes['data-value'] === 'browser/claude/choice/missing')?.attributes['aria-disabled'])
      .toBe('true');
  });

  test('saved local models stay readable in the trigger but remain absent from the choices', async () => {
    const local = { id: 'local/saved-model', label: 'Local / Saved model · MLX', detail: 'Saved local selection', highMemory: false };
    for (const [model, name] of [[local.id, 'Saved model'], ['local/unknown-model', 'local/unknown-model']]) {
      const html = renderToStaticMarkup(h(ModelSelector, { options: [...options, local], model, label: 'Task model', onSelect: () => {} })).html;
      expect((await textBySelector(html, '.model-option-name'))[0]).toBe(name);
      const elements = await parsedElements(html);
      expect(elements.find((element) => element.attributes['data-select-value'])?.attributes['data-select-value']).toBe(model);
      expect(elements.filter((element) => element.attributes.role === 'option').map((element) => element.attributes['data-value']))
        .toEqual(options.map((option) => option.id));
    }
  });

  test('provider identities map to local decorative marks and unknown providers use the generic icon', async () => {
    for (const [model, provider, asset] of [
      ['browser/chatgpt/choice/fast', 'chatgpt', 'openai'],
      ['api/openai/model/fixture', 'openai', 'openai'],
      ['browser/gemini/choice/fast', 'gemini', 'gemini'],
      ['browser/claude/choice/fast', 'claude', 'claude'],
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

  test('busy tasks disable model input and discovery refresh reflects its state', async () => {
    const disabled = selector(options[1].id, 'Task model', true);
    expect(disabled).toContain('data-select-disabled="true"');
    const items = (await parsedElements(disabled)).filter((element) => element.attributes.role === 'option');
    expect(items).toHaveLength(options.length);
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
    for (const [provider, label] of [['gemini', 'Gemini'], ['chatgpt', 'ChatGPT'], ['claude', 'Claude']]) {
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
      'browser/gemini/choice/', 'browser/gemini/choice/value/extra', 'browser/gemini/not-choice/value']) {
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

  test('observed website labels and IDs are escaped as text and attribute values', async () => {
    const malicious = { id: 'browser/claude/choice/"<script>', label: 'Claude / <script>alert(1)</script> · Built-in browser', detail: '<img src=x onerror=bad()>" autofocus onfocus="bad()', highMemory: false };
    const html = renderToStaticMarkup(h(ModelSelector, { options: [malicious], model: malicious.id, label: 'Task model', onSelect: () => {} })).html;
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    const elements = await parsedElements(html);
    expect(elements.map((element) => element.tag).filter((tag) => ['script', 'img', 'iframe', 'foreignObject'].includes(tag))).toEqual([]);
    expect(elements.find((element) => element.attributes.role === 'combobox')?.attributes.title).toBe(malicious.detail);
    expect(elements.find((element) => element.attributes.role === 'option')?.attributes['data-value']).toBe(malicious.id);
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
