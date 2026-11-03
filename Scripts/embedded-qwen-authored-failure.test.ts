import { expect, test } from 'bun:test';
import { fixture, choice, fingerprint, prompt, raw } from './embedded-qwen-adapter-fixture';

type Page = ReturnType<typeof fixture>;
const max = 'Qwen3.8-Max', plus = 'Qwen3.7-Plus';

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
  ['span', 'tag', 0, f => { f.paragraph.append(new f.Node('A')); }],
  ['literal', 'class', 0, f => { f.literal.setAttribute('class','SYNTHETIC_UNKNOWN'); }],
  ['literal', 'hidden', 0, f => { f.literal.setAttribute('hidden',''); }],
  ['literal_contents', 'count', 1, f => { f.literal.append(new f.Node('CODE')); }],
  ['outside', 'scope', 0, f => { f.flow.append(new f.Node('STRONG',{},'SYNTHETIC_PRIVATE')); }],
  ['outside', 'node_limit', 0, f => { for(let i=0;i<10001;i++) f.flow.append(new f.Node('DIV')); }]
];
for (const model of [max, plus]) for (const [stage, reason, count, mutate] of checks) {
  test(`${model} terminal failure reports only ${stage}/${reason} and saturated arity`, async () => {
    const f = await submitted(model);
    expect((await f.run('inspect')).firstUserVerified).toBe(true);
    mutate(f);
    const clicks = f.mutations();
    const r = await f.run('inspect', { expectedModelChoice: choice(model) });
    expect(r).toEqual({error:'unsupported_response_format',detail:'authored_source',adapterFailureStructure:{
      version:1,provider:'qwen',trigger:'authored_source',stage,reason,count
    }});
    expect(f.mutations()).toBe(clicks);
    expect(f.send.clicks).toBe(1);
  });
}

test('missing exact selection, another model, streaming and cleanup cannot emit an authored-source packet', async () => {
  for (const kind of ['missingChoice', 'other', 'stream', 'cleanup']) {
    const model = kind === 'other' ? 'Qwen3.8-Omni-Flash' : plus;
    const f = await submitted(model, kind !== 'stream');
    expect((await f.run('inspect')).firstUserVerified).toBe(true);
    f.paragraph.append(new f.Node('A'));
    const r = await f.run('inspect', {
      ...(kind === 'missingChoice' ? {} : {expectedModelChoice: choice(model)}),
      ...(kind === 'cleanup' ? {savedCleanupInspection:true} : {})
    });
    if (kind === 'stream' || kind === 'cleanup') {
      expect(r.error).toBeUndefined(); expect(r.text).toBe(''); expect(r.answerComplete).toBe(false);
    } else expect(r).toEqual({error:'unsupported_response_format',detail:'authored_source'});
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

function appendRun(f: Page, text: string) {
  const run = new f.Node('SPAN', {class:'qwen-markdown-text'});
  const leaf = new f.Node('SPAN', {class:'qwen-markdown-text-node'}, text);
  run.append(leaf);
  f.paragraph.append(run);
  return {run, leaf};
}

test('complete Qwen Plus and Max preserve every literal byte across adjacent inert runs', async () => {
  for (const selected of [plus, max]) {
    const f = await submitted(selected);
    const encoded = JSON.stringify({type:'tool_calls', calls:[{name:'exec_command',arguments:{cmd:'printf "%s" "escaped\\path"'}}]});
    f.literal.text = encoded.slice(0, 6);
    appendRun(f, encoded.slice(6, 21));
    appendRun(f, encoded.slice(21));
    f.paragraph.setAttribute('dir', 'ltr');
    f.paragraph.text = '\n  ';
    const result = await f.run('inspect', {expectedModelChoice:choice(selected)});
    expect(result.text).toBe('\n  ' + encoded);
    expect(result.answerComplete).toBe(true);
    expect(result.modelEvidence.selected).toEqual(choice(selected));
    expect(result.adapterFailureStructure).toBeUndefined();
    expect(f.send.clicks).toBe(1);
    expect(f.more.clicks).toBe(0);
  }
});

test('split text retains invalid protocol and does not infer completion', () => {
  const f = fixture({completeOnSend:false});
  f.mountConversation(false);
  f.literal.text = 'An authored introduction ';
  appendRun(f, raw);
  const dom = f.read(), answer = dom.transcript().answer;
  expect(dom.rawAnswer(answer)).toEqual({text:'An authored introduction ' + raw, finalMarkup:true, formatIssue:false});
  expect(dom.completionCandidate(answer)).toBe(false);
  expect(f.mutations()).toBe(0);
});

test('a second component cannot import foreign markup, controls, hidden text or siblings', async () => {
  const scenarios = ['link','code','runClass','leafClass','runEvent','leafRole','leafEditable','runHidden',
    'leafHidden','paragraphButton','foreignControl','nestedLeaf','secondLeaf','runText','paragraphText','reasoning','excessRuns'];
  for (const kind of scenarios) {
    const f = await submitted(plus);
    const {run,leaf} = appendRun(f, 'PRIVATE_SYNTHETIC');
    if (kind === 'link' || kind === 'code') {
      run.detach();
      f.paragraph.append(new f.Node(kind === 'link' ? 'A' : 'CODE', {}, 'PRIVATE_SYNTHETIC'));
    } else if (kind === 'runClass') run.setAttribute('class','qwen-markdown-text foreign');
    else if (kind === 'leafClass') leaf.setAttribute('class','qwen-markdown-code');
    else if (kind === 'runEvent') run.setAttribute('onclick','PRIVATE_SYNTHETIC');
    else if (kind === 'leafRole') leaf.setAttribute('role','button');
    else if (kind === 'leafEditable') leaf.setAttribute('contenteditable','true');
    else if (kind === 'runHidden') run.setAttribute('hidden','');
    else if (kind === 'leafHidden') leaf.setAttribute('aria-hidden','true');
    else if (kind === 'paragraphButton') f.paragraph.setAttribute('role','button');
    else if (kind === 'foreignControl') f.paragraph.append(new f.Node('BUTTON'));
    else if (kind === 'nestedLeaf') leaf.append(new f.Node('SPAN',{},'PRIVATE_SYNTHETIC'));
    else if (kind === 'secondLeaf') run.append(new f.Node('SPAN',{class:'qwen-markdown-text-node'},'PRIVATE_SYNTHETIC'));
    else if (kind === 'runText') run.text = 'PRIVATE_SYNTHETIC';
    else if (kind === 'paragraphText') f.paragraph.text = 'PRIVATE_SYNTHETIC';
    else if (kind === 'reasoning') run.setAttribute('class','qwen-chat-thinking-tool-status-card-wraper');
    else for (let i = 0; i < 63; i++) appendRun(f,'');
    const before = f.mutations();
    const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
    expect(result.error, kind).toBe('unsupported_response_format');
    expect(result.detail, kind).toBe('authored_source');
    expect(result.text, kind).toBeUndefined();
    expect(Object.keys(result.adapterFailureStructure).sort()).toEqual(['count','provider','reason','stage','trigger','version']);
    expect(JSON.stringify(result)).not.toContain('PRIVATE_SYNTHETIC');
    expect(f.mutations()).toBe(before);
  }
});
