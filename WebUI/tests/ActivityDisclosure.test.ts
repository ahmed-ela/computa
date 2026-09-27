import { describe, expect, test } from 'bun:test';
import { createElement as h } from 'octane';
import { renderToStaticMarkup } from 'octane/server';
import { ActivityDisclosure, activityLabel } from '../src/ActivityDisclosure';
import { ResponseMarkdown } from '../src/ResponseMarkdown';
import type { ActivityGroup } from '../src/activityTimeline';

const group = (changes: Partial<ActivityGroup> = {}): ActivityGroup => ({
  id: 'turn-1', entries: [{ id: 'r1', kind: 'reasoning', title: 'Working', body: 'Reasoning', timestamp: 0 }],
  isRunning: true, hasFinalAnswer: false, timestamp: 0, ...changes,
});
const render = (value: ActivityGroup, manualOpen?: boolean) => renderToStaticMarkup(h(ActivityDisclosure, {
  group: value, time: '3:30 PM', manualOpen, onOpenChange: () => {},
  children: h(ResponseMarkdown, { text: '**Reasoning**\n\n<script>inert()</script>' }),
})).html;

describe('unified activity disclosure', () => {
  test('starts open while working and exposes an activity region', () => {
    const html = render(group());
    expect(html).toMatch(/<details[^>]*\sopen(?:=|\s|>)/);
    expect(html).toContain('Working…');
    expect(html).toContain('aria-label="Activity"');
    expect(html).toContain('aria-live="off"');
    expect(html).toContain('<strong>Reasoning</strong>');
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toMatch(/<script\b/);
  });
  test('final answer starts collapsed while the turn is still running', () => {
    expect(render(group({ hasFinalAnswer: true }))).not.toMatch(/<details[^>]*\sopen(?:=|\s|>)/);
  });
  test('manual open and closed choices override automatic phases', () => {
    expect(render(group(), false)).not.toMatch(/<details[^>]*\sopen(?:=|\s|>)/);
    expect(render(group({ isRunning: false, hasFinalAnswer: true }), true)).toMatch(/<details[^>]*\sopen(?:=|\s|>)/);
  });
  test('completion uses the duration as the clickable label', () => {
    const html = render(group({ isRunning: false, hasFinalAnswer: true, workedForSeconds: 81 }));
    expect(html).toMatch(/<summary><span class="reasoning-label">Worked for 1m 21s<\/span><svg/);
    expect(html).not.toContain('Thinking');
    expect(html).not.toContain('Thoughts');
  });
  test('a new live turn has one waiting placeholder before its first activity', () => {
    expect(render(group({ entries: [] }))).toContain('Preparing response…');
  });
  test('the supplied clock replaces the fallback and stays inside the clickable header', () => {
    const Clock = () => h('span', { className: 'reasoning-label', children: 'Working for 12s' });
    const html = renderToStaticMarkup(h(ActivityDisclosure, {
      group: group(), time: '3:30 PM', onOpenChange: () => {}, label: h(Clock, {}),
    })).html;
    expect(html.match(/class="reasoning-label"/g)).toHaveLength(1);
    expect(html.match(/Working/g)).toHaveLength(1);
    expect(html).toMatch(/<summary><span class="reasoning-label">Working for 12s<\/span><svg/);
    expect(html).not.toContain('Working…');
    expect(html).not.toContain('working-indicator');
  });
  test('successive clock values and completion each have one status in the same header', () => {
    for (const seconds of [0, 1, 59, 60, 121]) {
      const value = group({ startedAt: 100 });
      const label = activityLabel(value, 100 + seconds);
      const html = renderToStaticMarkup(h(ActivityDisclosure, {
        group: value, time: '3:30 PM', onOpenChange: () => {},
        label: h('span', { className: 'reasoning-label', children: label }),
      })).html;
      expect(html.match(/class="reasoning-label"/g)).toHaveLength(1);
      expect(html.match(/Working/g)).toHaveLength(1);
      expect(html).toContain(`<summary><span class="reasoning-label">${label}</span>`);
    }
    const completed = render(group({ isRunning: false, workedForSeconds: 121 }));
    expect(completed.match(/Worked for/g)).toHaveLength(1);
    expect(completed).not.toContain('Working');
  });
});
