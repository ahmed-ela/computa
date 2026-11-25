import 'octane/compiler/register';
import { expect, mock, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
mock.module('@octanejs/shadcn/Popover', () => ({
  Popover: ({ children }: Record<string, unknown>) => h('div', { children }),
  PopoverContent: ({ children }: Record<string, unknown>) => h('section', { children }),
  PopoverTrigger: (props: Record<string, unknown>) => h('button', props),
}));
const { CodexCLIUsage, isCodexCLIModel, quotaLeft, quotaSummary, quotaWindowLabel } = await import('../src/CodexCLIUsage');

test('usage is scoped to selected models from the installed Codex CLI', () => {
  expect(isCodexCLIModel('cli/codex/model/gpt-6')).toBe(true);
  for (const model of ['browser/chatgpt', 'api/openai', 'cli/claude/model/sonnet',
    'cli/codex', 'cli/codex/model/', 'cli/codex/model/test\u2028']) {
    expect(isCodexCLIModel(model)).toBe(false);
  }
});

test('quota uses remaining percentages and the reported window duration', () => {
  expect([quotaLeft(20), quotaLeft(100), quotaLeft(125), quotaLeft(-1)]).toEqual([80, 0, 0, 100]);
  expect(quotaWindowLabel(300, 'primary')).toBe('5-hour window');
  expect(quotaWindowLabel(10080, 'secondary')).toBe('1-week window');
  expect(quotaWindowLabel(undefined, 'secondary')).toBe('Secondary window');
});

test('the ring shows the tightest live quota and drops expired windows', () => {
  const normal = { id: 'codex', primary: { usedPercent: 80 } };
  const limited = { id: 'other', secondary: { usedPercent: 90, resetsAt: 123 } };
  expect(quotaSummary(undefined, 122000)).toEqual({ remaining: undefined, nextReset: Infinity });
  expect(quotaSummary([normal, limited], 122000)).toEqual({ remaining: 10, nextReset: 123000 });
  expect(quotaSummary([normal, limited], 123000)).toEqual({ remaining: 20, nextReset: Infinity });
  expect(quotaSummary([limited], 123000).remaining).toBeUndefined();
});

test('the popover renders reported quota and does not turn missing data into zero usage', () => {
  const render = (props: Parameters<typeof CodexCLIUsage>[0]) => renderToStaticMarkup(h(CodexCLIUsage, props)).html;
  const base = { refreshing: false, blocked: false, onRefresh: () => {} };
  expect(render(base)).toContain('Quota is unavailable');
  expect(render({ ...base, buckets: [] })).toContain('did not report any quota windows');
  expect(render({ ...base, refreshing: true })).toContain('Checking Codex quota');
  const markup = render({ ...base, buckets: [{ id: 'codex',
    primary: { usedPercent: 92, windowDurationMins: 300 }, secondary: { usedPercent: 51, resetsAt: 1 },
  }] });
  expect(markup).toContain('aria-label="Codex usage, 8% left"');
  expect(markup).toContain('data-hint="8% left"');
  expect(markup).toContain('data-warning="true"');
  expect(markup).toContain('5-hour window');
  expect(markup).toContain('8% left');
  expect(markup).toContain('Reset time passed');
  expect(markup).not.toContain('49% left');
});

test('the trigger distinguishes empty, full and unavailable without a permanent text label', () => {
  const trigger = (usedPercent?: number) => renderToStaticMarkup(h(CodexCLIUsage, {
    buckets: usedPercent === undefined ? [] : [{ id: 'codex', primary: { usedPercent } }],
    refreshing: false, blocked: false, onRefresh: () => {},
  })).html.split('</button>')[0];
  expect(trigger(100)).toContain('data-hint="0% left"');
  expect(trigger(100)).not.toContain('rotate(-90');
  expect(trigger(0)).toContain('data-hint="100% left"');
  expect(trigger(0)).toContain('rotate(-90');
  expect(trigger()).toContain('data-hint="Usage unavailable"');
  expect(trigger()).not.toContain('% left');
  expect(trigger(50)).not.toContain('>Usage<');
});
