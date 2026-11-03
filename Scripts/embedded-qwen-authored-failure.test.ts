import { expect, test } from 'bun:test';
import { fixture, choice, fingerprint, prompt, raw } from './embedded-qwen-adapter-fixture';

type Page = ReturnType<typeof fixture>;
const max = 'Qwen3.8-Max';

async function submitted(label = max, complete = true) {
  const f = fixture({ completeOnSend: complete });
  for (let i = 0; i < 8; i++) if ((await f.run('selectModel', { modelChoice: choice(label) })).selected) break;
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert', { prompt })).inserted).toBe(true);
  expect((await f.run('sendReady', { prompt })).sendReady).toBe(true);
  expect((await f.run('submit', { prompt, savedSubmissionFingerprint: await fingerprint(prompt) })).submitted).toBe(true);
  return f;
}

const checks: [string, string, number, (f: Page) => void][] = [
  ['flow', 'count', 2, f => { f.right.append(f.flow.cloneNode(true), f.flow.cloneNode(true)); }],
  ['flow', 'hidden', 0, f => { f.flow.setAttribute('hidden', ''); }],
  ['phase', 'count', 2, f => { f.flow.append(f.phase.cloneNode(true)); }],
  ['phase', 'class', 0, f => { f.phase.setAttribute('class', 'response-message-content phase-answer'); }],
  ['custom', 'parent_hidden', 0, f => { f.phase.setAttribute('hidden', ''); }],
  ['custom', 'count', 0, f => { f.phase.replaceChildren(); }],
  ['markdown', 'mixed_text', 0, f => { f.phase.children[0].text = 'SYNTHETIC_PRIVATE'; }],
  ['paragraph', 'tag', 0, f => { f.markdown.replaceChildren(new f.Node('PRE', {class:'SYNTHETIC_CLASS'})); }],
  ['span', 'count', 2, f => { f.paragraph.append(new f.Node('A')); }],
  ['literal', 'class', 0, f => { f.literal.setAttribute('class','SYNTHETIC_UNKNOWN'); }],
  ['literal', 'hidden', 0, f => { f.literal.setAttribute('hidden',''); }],
  ['literal_contents', 'count', 1, f => { f.literal.append(new f.Node('CODE')); }],
  ['outside', 'scope', 0, f => { f.flow.append(new f.Node('STRONG',{},'SYNTHETIC_PRIVATE')); }],
  ['outside', 'node_limit', 0, f => { for(let i=0;i<10001;i++) f.flow.append(new f.Node('DIV')); }]
];
for (const [stage, reason, count, mutate] of checks) {
  test(`Max terminal failure reports only ${stage}/${reason} and saturated arity`, async () => {
    const f = await submitted();
    expect((await f.run('inspect')).firstUserVerified).toBe(true);
    mutate(f);
    const clicks = f.mutations();
    const r = await f.run('inspect', { expectedModelChoice: choice(max) });
    expect(r).toEqual({error:'unsupported_response_format',detail:'authored_source',adapterFailureStructure:{
      version:1,provider:'qwen',trigger:'authored_source',stage,reason,count
    }});
    expect(f.mutations()).toBe(clicks);
    expect(f.send.clicks).toBe(1);
  });
}

test('Plus shares the original rejection, and Max streaming and cleanup return no structure or answer', async () => {
  for (const kind of ['plus','stream','cleanup']) {
    const f = await submitted(kind === 'plus' ? 'Qwen3.7-Plus' : max, kind !== 'stream');
    expect((await f.run('inspect')).firstUserVerified).toBe(true);
    f.paragraph.append(new f.Node('A'));
    const r = await f.run('inspect', kind === 'cleanup' ? {savedCleanupInspection:true} : {});
    if (kind === 'plus') expect(r).toEqual({error:'unsupported_response_format',detail:'authored_source'});
    else { expect(r.error).toBeUndefined(); expect(r.text).toBe(''); expect(r.answerComplete).toBe(false); }
    expect(r.adapterFailureStructure).toBeUndefined();
    expect(f.send.clicks).toBe(1);
  }
});

test('a literal stays byte exact and a foreign selection or document never receives the packet', async () => {
  const f = await submitted(), r = await f.run('inspect');
  expect(r.text).toBe(raw);
  expect(r.answerComplete).toBe(true);
  expect(r.adapterFailureStructure).toBeUndefined();
  for (const overrides of [{expectedModelChoice:choice('Qwen3.7-Plus')}, {documentGeneration:'00000000-0000-4000-8000-000000000001'}]) {
    const page = await submitted();
    expect((await page.run('inspect')).firstUserVerified).toBe(true);
    page.paragraph.append(new page.Node('A'));
    const rejected = await page.run('inspect',overrides);
    expect(rejected.error).toBeDefined();
    expect(rejected.adapterFailureStructure).toBeUndefined();
  }
});
