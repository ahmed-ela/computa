import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';

const helper = readFileSync(new URL('./embedded-model-choice-helper.js', import.meta.url), 'utf8');
const policy = new Function('input', helper + '\nreturn {version:websiteChatFamilyVersion,newest:websiteChatNewestFamily,'
  + 'choice:websiteChatPresetChoice,intent:websiteChatPresetIntentValid,evidence:websiteChatSelectionEvidence,equal:websiteChatResolvedSelectionEqual};')({});
const family = (label: string) => ({ key: label, label });
const power = (key: string, label: string) => ({ key, label });

describe('Chat preset automatic family policy', () => {
  test('newest uses numeric components, independent of menu order and string ordering', () => {
    expect(policy.newest(['GPT-5.5', 'GPT-6'])).toEqual(family('GPT-6'));
    expect(policy.newest(['GPT-9', 'GPT-10'])).toEqual(family('GPT-10'));
    expect(policy.newest(['GPT-6.2', 'GPT-6.10', 'GPT-5.99'])).toEqual(family('GPT-6.10'));
    expect(policy.newest(['GPT-6.1.2', 'GPT-6.1.11', 'GPT-6'])).toEqual(family('GPT-6.1.11'));
  });

  test('bounded decimal comparison does not lose precision or require a model catalog', () => {
    const old = 'GPT-' + '9'.repeat(80), latest = 'GPT-1' + '0'.repeat(80);
    expect(policy.newest([latest, old])).toEqual(family(latest));
    expect(policy.version('GPT-' + '1'.repeat(125))).toBeNull();
  });

  test('duplicate and semantically equal versions fail even below a unique maximum', () => {
    for (const offered of [['GPT-6', 'GPT-6'], ['GPT-6', 'GPT-6.0'], ['GPT-5', 'GPT-5.0', 'GPT-6'],
      ['GPT-6.1', 'GPT-6.1.0.0']]) expect(policy.newest(offered)).toBeNull();
  });

  test('specialized families, aliases, malformed versions and overflowed inputs cannot prove Latest', () => {
    for (const label of ['Latest', 'GPT-5.6 Sol', 'GPT-6 Work', 'GPT-6 Pro', 'GPT-6-preview', 'GPT-0',
      'GPT-06', 'GPT-6.01', 'GPT-6.', 'GPT-6..1', ' GPT-6', 'GPT-６', 'GPT-6\u0000'])
      expect(policy.version(label)).toBeNull();
    for (const offered of [[], ['GPT-6', 'GPT-5.6 Sol'], Array(33).fill('GPT-6'), null, 'GPT-6'])
      expect(policy.newest(offered)).toBeNull();
  });

  test('choices encode Chat automatic policy and independently observed power', () => {
    for (const [key, label] of [['instant', 'Instant'], ['medium', 'Medium'], ['high', 'High'],
      ['extra-high', 'Extra High'], ['pro', 'Pro']]) {
      expect(policy.choice(family('GPT-6'), power(key, label))).toEqual({ key: 'chat/latest/' + key,
        label: key === 'pro' ? 'GPT-6 Pro' : label });
    }
    expect(policy.choice(family('GPT-7.1'), power('pro', 'Pro'))).toEqual({ key: 'chat/latest/pro', label: 'GPT-7.1 Pro' });
    expect(policy.choice(family('GPT-6'), power('medium', 'High'))).toBeNull();
    expect(policy.choice({ key: 'GPT-6', label: 'GPT-5.5' }, power('medium', 'Medium'))).toBeNull();
  });

  test('evidence requires the selected concrete family to be the unique observed newest', () => {
    const observed = policy.evidence(family('GPT-6'), power('pro', 'Pro'), ['GPT-6', 'GPT-5.5']);
    expect(observed).toEqual({ selected: { key: 'chat/latest/pro', label: 'GPT-6 Pro' },
      verification: 'website_selection', source: 'selected_model_indicator', chatSelection: {
        family: family('GPT-6'), power: power('pro', 'Pro'),
        automaticFamily: { policy: 'highest_offered_plain_gpt', offered: ['GPT-6', 'GPT-5.5'] } } });
    expect(policy.evidence(family('GPT-5.5'), power('medium', 'Medium'), ['GPT-6', 'GPT-5.5'])).toBeNull();
  });

  test('an owned turn must reject family drift despite an unchanged Medium preset identity', () => {
    const before = policy.evidence(family('GPT-6'), power('medium', 'Medium'), ['GPT-6']);
    const later = policy.evidence(family('GPT-6.1'), power('medium', 'Medium'), ['GPT-6.1']);
    expect(before.selected).toEqual(later.selected);
    expect(policy.equal(before.chatSelection, later.chatSelection)).toBe(false);
    expect(policy.equal(before.chatSelection, before.chatSelection)).toBe(true);
    expect(policy.equal(before.chatSelection, { ...before.chatSelection, power: power('high', 'High') })).toBe(false);
  });

  test('stable Pro intent preserves its policy ID while discovery displays the current family', () => {
    const intent = { key: 'chat/latest/pro', label: 'Pro' };
    const before = policy.evidence(family('GPT-6'), power('pro', 'Pro'), ['GPT-6'], intent);
    const later = policy.evidence(family('GPT-7'), power('pro', 'Pro'), ['GPT-7'], intent);
    expect(before.selected).toEqual(intent); expect(later.selected).toEqual(intent);
    expect(policy.choice(family('GPT-6'), power('pro', 'Pro')).label).toBe('GPT-6 Pro');
    expect(policy.choice(family('GPT-7'), power('pro', 'Pro')).label).toBe('GPT-7 Pro');
    expect(policy.equal(before.chatSelection, later.chatSelection)).toBe(false);
    expect(policy.evidence(family('GPT-7'), power('pro', 'Pro'), ['GPT-7'],
      { key: 'chat/latest/pro', label: 'GPT-6 Pro' })).toBeNull();
  });

  test('malformed presets and legacy family intents are rejected before a picker mutation', () => {
    for (const invalid of [{ key: 'GPT-6', label: 'GPT-6' }, { key: 'Latest', label: 'Latest' },
      { key: 'chat/latest/high', label: 'Medium' }, { key: 'chat/latest/pro', label: 'GPT-6 Work Pro' },
      { key: 'chat/latest/pro', label: 'GPT-06 Pro' }, { key: 'chat/latest/pro', label: 'GPT-6 Pro', extra: true }])
      expect(policy.intent(invalid)).toBe(false);
    expect(policy.intent({ key: 'chat/latest/pro', label: 'Pro' })).toBe(true);
    expect(policy.intent({ key: 'chat/latest/pro', label: 'GPT-6 Pro' })).toBe(true);
    expect(policy.intent({ key: 'chat/latest/extra-high', label: 'Extra High' })).toBe(true);
  });

  test('extra keys cannot become trusted family or power identities', () => {
    expect(policy.choice({ ...family('GPT-6'), selected: true }, power('medium', 'Medium'))).toBeNull();
    expect(policy.choice(family('GPT-6'), { ...power('medium', 'Medium'), selected: true })).toBeNull();
  });
});
