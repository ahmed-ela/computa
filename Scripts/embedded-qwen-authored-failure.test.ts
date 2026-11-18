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
  ['phase_set', 'other_content', 2, f => { f.flow.append(f.phase.cloneNode(true)); }],
  ['phase', 'class', 0, f => { f.phase.setAttribute('class', 'response-message-content phase-answer'); }],
  ['custom', 'parent_hidden', 0, f => { f.phase.setAttribute('hidden', ''); }],
  ['custom', 'count', 0, f => { f.phase.replaceChildren(); }],
  ['markdown', 'mixed_text', 0, f => { f.phase.children[0].text = 'SYNTHETIC_PRIVATE'; }],
  ['paragraph', 'tag', 0, f => { f.markdown.replaceChildren(new f.Node('SECTION', {class:'SYNTHETIC_CLASS'})); }],
  ['inline', 'other', 0, f => { f.paragraph.append(new f.Node('A')); }],
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
    const legacy = {...r.adapterFailureStructure}; delete legacy.phaseSet;
    expect({...r,adapterFailureStructure:legacy}).toEqual({error:'unsupported_response_format',detail:'authored_source',adapterFailureStructure:{
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

function renderJSONEscapes(f: Page, source: string) {
  f.paragraph.replaceChildren();
  f.paragraph.setAttribute('dir', 'ltr');
  const escapes = [];
  let end = 0;
  for (const match of source.matchAll(/\\["\\/]/g)) {
    if (match.index > end) appendRun(f, source.slice(end, match.index));
    const element = new f.Node('SPAN', {class:'qwen-markdown-escape',dir:'ltr'}, match[0][1]);
    f.paragraph.append(element);
    escapes.push(element);
    end = match.index + 2;
  }
  if (end < source.length) appendRun(f, source.slice(end));
  return escapes;
}

test('exact Qwen JSON escapes preserve the original tool envelope and its argument bytes', async () => {
  const argumentsJSON = JSON.stringify({path:'a\\b', note:'"quoted"\nline'});
  const wire = JSON.stringify({type:'tool_calls',calls:[{name:'exec_command',arguments:{cmd:argumentsJSON}}]});
  for (const model of [plus, max]) {
    const f = await submitted(model);
    const escapes = renderJSONEscapes(f, wire);
    expect(escapes.length).toBeGreaterThan(1);
    expect(f.paragraph.textContent).not.toBe(wire);
    const result = await f.run('inspect', {expectedModelChoice:choice(model)});
    expect(result.error).toBeUndefined();
    expect(result.text).toBe(wire);
    expect(JSON.parse(result.text).calls[0].arguments.cmd).toBe(argumentsJSON);
    expect(result.answerComplete).toBe(true);
    expect(result.modelEvidence.selected).toEqual(choice(model));
    expect(f.send.clicks).toBe(1);
  }
  const f = fixture();
  f.mountConversation(false);
  const escapedSlash = String.raw`{"type":"final","text":"a\/b"}`;
  renderJSONEscapes(f, escapedSlash);
  const dom = f.read();
  expect(dom.rawAnswer(dom.transcript().answer).text).toBe(escapedSlash);
  expect(dom.completionCandidate(dom.transcript().answer)).toBe(false);
});

test('Qwen rejects noncanonical escape structures and reports only a finite category', async () => {
  const cases: [string,string,(f:Page, leaf:InstanceType<Page['Node']>)=>void][] = [
    ['wrongDir','escape', (_,e)=>e.setAttribute('dir','rtl')],
    ['extraAttr','escape', (_,e)=>e.setAttribute('title','PRIVATE_ANNOTATION')],
    ['hidden','escape', (_,e)=>e.setAttribute('hidden','')],
    ['extraText','escape', (_,e)=>{e.text='PRIVATE_TEXT'}],
    ['nested','escape', (f,e)=>e.append(new f.Node('SPAN'))],
    ['paragraphDir','scope', (f)=>f.paragraph.setAttribute('dir','auto')],
    ['parentDecoration','escape', (f)=>f.markdown.setAttribute('class','qwen-markdown foreign')],
    ['whitespaceSibling','escape', (f)=>{f.paragraph.text=' ';}],
    ['badPunctuation','escape', (_,e)=>{e.text='*'}],
    ['spoofClass','other', (_,e)=>e.setAttribute('class','qwen-markdown-escape forged')],
    ['bidi','bidi', (_,e)=>e.setAttribute('class','qwen-markdown-bidi-ltr')],
    ['rich','decorated', (f,e)=>{e.detach(); f.paragraph.append(new f.Node('STRONG',{class:'qwen-markdown-strong'},'PRIVATE_RICH'));}],
    ['reflected','other', (_,e)=>e.setAttribute('class','PRIVATE_CLASS')],
    ['invalidJSON','escape_json', f=>{f.paragraph.children[0].children[0].text='prose ';}],
    ['untaggedEscape','escape_json', f=>{f.paragraph.children[0].children[0].text=String.raw`{"a":"left\\`;}],
  ];
  for (const [name,kind,mutate] of cases) {
    const f = await submitted(plus);
    const [leaf] = renderJSONEscapes(f, String.raw`{"a":"x\"y"}`);
    mutate(f,leaf);
    const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
    expect(result.error,name).toBe('unsupported_response_format');
    expect(result.detail,name).toBe('authored_source');
    expect(result.adapterFailureStructure,name).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:kind === 'scope' ? 'outside' : 'inline',reason:kind,count:0});
    expect(result.text,name).toBeUndefined();
    expect(JSON.stringify(result),name).not.toContain('PRIVATE');
    expect(f.send.clicks,name).toBe(1);
  }
});


test('a directional leaf beside a plain leaf stays rejected and reports bidi for both paragraph profiles', async () => {
  for (const multiple of [false,true]) {
    const f = await submitted(plus);
    if (multiple) appendRun(f, 'retained suffix');
    f.literal.parentElement!.append(new f.Node('SPAN',{class:'qwen-markdown-bidi-ltr',dir:'ltr'},'PRIVATE_DIRECTIONAL'));
    const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
    expect(result.error).toBe('unsupported_response_format');
    expect(result.adapterFailureStructure).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'inline',reason:'bidi',count:0});
    expect(result.text).toBeUndefined();
    expect(f.send.clicks).toBe(1);
  }
});

function renderManyRuns(f: Page, count: number) {
  const source = JSON.stringify({type:'message',text:'q'.repeat(count)});
  f.paragraph.replaceChildren();
  f.paragraph.setAttribute('dir','ltr');
  for (let i = 0; i < count; i++) appendRun(f, i < count - 1 ? source[i] : source.slice(i));
  return source;
}

test('bounded complete Qwen paragraphs with 65 through 256 real runs preserve the entire JSON', async () => {
  for (const count of [65,255,256]) {
    const f = await submitted(plus);
    const source = renderManyRuns(f,count);
    const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
    expect(result.error,count).toBeUndefined();
    expect(result.answerComplete).toBe(true);
    expect(result.text).toBe(source);
    expect(f.send.clicks).toBe(1);
  }
  const f = await submitted(plus);
  const cmd = ('"fixture" and backslash \\\\ ').repeat(21);
  const source = JSON.stringify({type:'tool_calls',calls:[{name:'exec_command',arguments:{cmd}}]});
  const escapes = renderJSONEscapes(f,source);
  expect(escapes.length).toBeGreaterThan(64);
  expect(f.paragraph.children.length).toBeLessThanOrEqual(256);
  const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
  expect(result.error).toBeUndefined();
  expect(result.text).toBe(source);
  expect(result.modelEvidence.selected).toEqual(choice(plus));
  expect(f.send.clicks).toBe(1);
});

test('a late invalid sibling, malformed large envelope and oversized bytes cannot qualify', async () => {
  for (const kind of ['last','malformed','bytes']) {
    const f = await submitted(plus);
    renderManyRuns(f,256);
    const end = f.paragraph.children[255].children[0];
    if (kind === 'last') end.setAttribute('class','FOREIGN_PRIVATE_CLASS');
    if (kind === 'malformed') end.text = 'missing end';
    if (kind === 'bytes') end.text = '日'.repeat(74_000) + '"}';
    const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
    expect(result.error,kind).toBe(kind==='bytes'?'response_too_large':'unsupported_response_format');
    expect(result.text).toBeUndefined();
    expect(JSON.stringify(result)).not.toContain('PRIVATE');
    expect(f.send.clicks).toBe(1);
  }
});

test('Qwen long-paragraph limit describes only the first structurally atypical sampled run', async () => {
  for (const kind of ['ordinary_prefix','escape','bidi','decorated','other']) {
    const f = await submitted(plus);
    renderManyRuns(f,257);
    const target = f.paragraph.children[kind === 'ordinary_prefix' ? 64 : 63];
    if (kind === 'bidi') target.children[0].setAttribute('class','qwen-markdown-bidi-ltr');
    else if (kind === 'escape') target.setAttribute('class','qwen-markdown-escape');
    else if (kind === 'decorated') {
      target.tagName='A'; target.setAttribute('class','qwen-markdown-link');
    } else target.setAttribute('class','PRIVATE_UNRECOGNIZED_CLASS');
    const result = await f.run('inspect',{expectedModelChoice:choice(plus)});
    expect(result.error,kind).toBe('unsupported_response_format');
    expect(result.adapterFailureStructure,kind).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'span_limit',reason:kind,count:2});
    expect(result.text).toBeUndefined();
    expect(JSON.stringify(result)).not.toContain('PRIVATE');
    expect(f.send.clicks).toBe(1);
  }
});

test('multiple Qwen answer phases are refused with bounded structural facts and no projected response', async () => {
  for (const kind of ['multiple_text_bearing','one_text_others_empty','all_empty','hidden','media','other_content','phase_count_limit','child_count_limit','node_visit_limit']) {
    const f = await submitted(max);
    const shell = f.phase.parentElement!.cloneNode(true), second = shell.children[0];
    f.flow.append(shell);
    if (kind === 'one_text_others_empty' || kind === 'all_empty') second.replaceChildren();
    if (kind === 'all_empty') f.phase.replaceChildren();
    if (kind === 'hidden') second.values.hidden='';
    if (kind === 'media') second.replaceChildren(new f.Node('IMG', {src:'PRIVATE_FIXTURE'}));
    if (kind === 'other_content') second.replaceChildren(new f.Node('A', {},'PRIVATE_FIXTURE'));
    if (kind === 'phase_count_limit') f.flow.append(shell.cloneNode(true), shell.cloneNode(true));
    if (kind === 'child_count_limit' || kind === 'node_visit_limit') {
      // Each run contains one leaf. Two 32-run branches exceed the visit budget
      // without reaching the width limit, whereas 33 direct runs trip width.
      for (const phase of [f.phase, second]) {
        const paragraph = phase.children[0].children[0].children[0];
        const run = paragraph.children[0];
        const width = kind === 'child_count_limit' ? 33 : 32;
        for (let i = 1; i < width; i++) paragraph.append(run.cloneNode(true));
      }
    }
    const mutations = f.mutations();
    const result = await f.run('inspect',{expectedModelChoice:choice(max)});
    expect(result.error,kind).toBe('unsupported_response_format');
    expect(result.detail).toBe('authored_source');
    const legacy = {...result.adapterFailureStructure}; delete legacy.phaseSet;
    expect(legacy,kind).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'phase_set',reason:kind,count:2});
    expect(result.text).toBeUndefined();
    expect(result.answerComplete).toBeUndefined();
    expect(JSON.stringify(result)).not.toContain('PRIVATE');
    expect(f.mutations()).toBe(mutations);
    expect(f.send.clicks).toBe(1);
  }
});

test('Qwen count rejections identify the deciding guard without rereading or replaying the Send', async () => {
  for (const [kind, site, users, answers, bound] of [
    ['duplicate_user','transcript',2,1,false], ['duplicate_answer','transcript',1,2,false],
    ['orphan_answer','transcript',0,1,false], ['disappeared_after_binding','expected',0,0,true]
  ] as const) {
    const f = await submitted(plus);
    if (bound) expect((await f.run('inspect')).firstUserVerified).toBe(true);
    if (kind === 'duplicate_user') f.root.parentElement!.append(f.root.cloneNode(true));
    else if (kind === 'duplicate_answer') f.answerRoot.parentElement!.append(f.answerRoot.cloneNode(true));
    else { f.root.detach(); if (bound) f.answerRoot.detach(); }
    const result = await f.run('inspect', { expectedUserCounts:bound?[1]:[0,1] });
    expect(result).toEqual({error:'conversation_changed', detail:'user_count',
      qwenCountFailure:{site, users, answers, adapterFirstBound:bound}});
    expect(f.send.clicks).toBe(1);
    expect((await f.run('inspect')).error).toBe('conversation_changed');
    expect(f.send.clicks).toBe(1);
  }
});
