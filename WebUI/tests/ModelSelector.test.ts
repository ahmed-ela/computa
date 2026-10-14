import 'octane/compiler/register';
import { describe, expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { decodeHTMLAttribute } from 'entities/decode';
import type { ModelOption } from '../src/types';

mock.module('@octanejs/shadcn/Button', () => ({ Button: ({ variant: _variant, size: _size, ...props }: Record<string, unknown>) => h('button', props) }));
mock.module('@octanejs/shadcn/NativeSelect', () => ({ NativeSelect: (props: Record<string, unknown>) => h('select', props), NativeSelectOption: (props: Record<string, unknown>) => h('option', props) }));
const { ModelSelector, WebsiteModelsRefresh, modelOptionLabel } = await import('../src/ModelSelector');

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
  test('composer and Settings distinguish provider and exact model labels', () => {
    for (const label of ['Task model', 'Default model for new tasks']) {
      const html = selector(options[1].id, label);
      expect(html).toContain(`aria-label="${label}"`);
      for (const option of options) expect(html).toContain(modelOptionLabel(option));
      expect(html).toContain('ChatGPT / Website default');
      expect(html).toContain('Gemini / Fixture Fast');
      expect(html).not.toContain('Built-in browser</option>');
    }
  });

  test('saved missing choices remain visible and disabled without choosing a fallback', () => {
    const html = selector(options[4].id);
    expect(html).toContain('Claude / Fixture Old (unavailable)');
    expect(html).toMatch(/<option[^>]*value="browser\/claude\/choice\/old"[^>]*disabled/);
    expect(html).toContain('Refresh after sign-in; never substitute');
    const unknown = selector('browser/claude/choice/missing');
    expect(unknown).toContain('browser/claude/choice/missing</option>');
    expect(unknown).toMatch(/<option[^>]*value="browser\/claude\/choice\/missing"[^>]*disabled/);
  });

  test('busy tasks disable model input and discovery refresh reflects its state', () => {
    expect(selector(options[1].id, 'Task model', true)).toMatch(/<select[^>]*disabled/);
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

  test('observed website labels and IDs are escaped as text and attribute values', async () => {
    const malicious = { id: 'browser/claude/choice/"<script>', label: 'Claude / <script>alert(1)</script> · Built-in browser', detail: '<img src=x onerror=bad()>" autofocus onfocus="bad()', highMemory: false };
    const html = renderToStaticMarkup(h(ModelSelector, { options: [malicious], model: malicious.id, label: 'Task model', onSelect: () => {} })).html;
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(html).toContain('value="browser/claude/choice/&quot;<script>"');
    const elements = await parsedElements(html);
    expect(elements.map((element) => element.tag)).toEqual(['select', 'option']);
    expect(elements[0].attributes.title).toBe(malicious.detail);
    expect(elements[1].attributes.value).toBe(malicious.id);
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
