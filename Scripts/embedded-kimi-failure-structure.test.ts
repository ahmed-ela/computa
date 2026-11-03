import { expect, test } from 'bun:test';
import { adapterFixture } from './embedded-kimi-adapter-fixture';

const categories = new Set(['content_box','markdown','markdown_container','reasoning_flow','reasoning_container',
  'reasoning_part','segment_code','highlighter','code_header','code_language','json_literal','other']);
const tags = new Set(['div','span','p','pre','code','header','svg','path','button','input','textarea','br','ul','ol','li','a','section','article','other']);
function packetShape(p: any) {
  expect(Object.keys(p).sort()).toEqual(['version','provider','trigger','nodeCount','nodeLimitReached','tree',
    'markdownCount','markdownCountOverflow','excludedReasoningCount','excludedReasoningCountOverflow',
    'answerVisible','boxVisible','markdownCandidates'].sort());
  expect(p.version).toBe(1); expect(p.provider).toBe('kimi'); expect(p.nodeCount).toBe(p.tree.length);
  expect(p.tree.length).toBeGreaterThan(0); expect(p.tree.length).toBeLessThanOrEqual(256);
  expect(p.markdownCandidates.length).toBeLessThanOrEqual(16);
  expect(Buffer.byteLength(JSON.stringify(p))).toBeLessThan(96 * 1024);
  p.tree.forEach((n: any, index: number) => {
    expect(Object.keys(n).sort()).toEqual(['parent','depth','tag','category','unknownClassPresent','visible','interactive',
      'elementChildCount','childCountOverflow','reasoningExcluded'].sort());
    expect(tags.has(n.tag)).toBe(true); expect(categories.has(n.category)).toBe(true);
    expect(n.depth).toBeGreaterThanOrEqual(0); expect(n.depth).toBeLessThanOrEqual(16);
    if (index === 0) { expect(n.parent).toBe(-1); expect(n.depth).toBe(0); }
    else { expect(n.parent).toBeGreaterThanOrEqual(0); expect(n.parent).toBeLessThan(index); expect(n.depth).toBe(p.tree[n.parent].depth + 1); }
    for (const key of ['unknownClassPresent','visible','interactive','childCountOverflow','reasoningExcluded']) expect(typeof n[key]).toBe('boolean');
    expect(n.elementChildCount).toBeGreaterThanOrEqual(0); expect(n.elementChildCount).toBeLessThanOrEqual(257);
  });
  p.markdownCandidates.forEach((n: any) => {
    expect(Object.keys(n).sort()).toEqual(['excludedReasoning','visible','ancestry','ancestryTruncated'].sort());
    expect(n.ancestry.length).toBeLessThanOrEqual(4);
    n.ancestry.forEach((c: string) => expect(categories.has(c)).toBe(true));
  });
}
function reasoning(f: ReturnType<typeof adapterFixture>) {
  const scope = new f.Node('DIV', { class:'thinking-container' });
  const wrapper = new f.Node('DIV', { class:'markdown-container' });
  const markdown = new f.Node('DIV', { class:'markdown' });
  markdown.append(new f.Node('P', {}, 'REASONING_SECRET_DO_NOT_CAPTURE'));
  wrapper.append(markdown); scope.append(wrapper); f.thoughtPart.append(scope);
  return {scope, markdown};
}

test('Kimi structure reports zero versus multiple markdowns; valid one still returns only the original answer', async () => {
  for (const count of [0,1,2]) {
    const f = adapterFixture(); await f.submit();
    if (count === 0) f.remove(f.response.markdown);
    if (count === 2) f.part.append(f.response.markdown.parentElement!.cloneNode(true));
    const result = await f.run();
    if (count === 1) {
      expect(result.error).toBeUndefined(); expect(result.answerComplete).toBe(true);
      expect(result.text).toBe('{"type":"message","text":"Synthetic reply"}');
      expect(result.adapterFailureStructure).toBeUndefined();
    } else {
      expect(result.error).toBe('unsupported_response_format'); expect(result.detail).toBe('authored_source_markdown_count');
      expect(result.text).toBeUndefined(); expect(result.firstUserFingerprint).toBeUndefined();
      packetShape(result.adapterFailureStructure);
      expect(result.adapterFailureStructure.markdownCount).toBe(count);
      expect(result.adapterFailureStructure.markdownCountOverflow).toBe(false);
    }
    expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
  }
});

test('Kimi diagnostic omits recognized reasoning subtrees and never reads their text', async () => {
  const f = adapterFixture(); await f.submit(); const r = reasoning(f);
  Object.defineProperty(r.scope, 'textContent', {get(){ throw new Error('reasoning text must not be read'); }});
  Object.defineProperty(r.markdown, 'textContent', {get(){ throw new Error('reasoning text must not be read'); }});
  f.remove(f.response.markdown);
  const result = await f.run(), p = result.adapterFailureStructure; packetShape(p);
  expect(result.detail).toBe('authored_source_markdown_count'); expect(p.markdownCount).toBe(0);
  expect(p.excludedReasoningCount).toBe(1); expect(p.markdownCandidates[0].excludedReasoning).toBe(true);
  expect(p.tree.filter((n: any) => n.category === 'reasoning_container')).toHaveLength(1);
  const index = p.tree.findIndex((n: any) => n.category === 'reasoning_container');
  expect(p.tree[index].reasoningExcluded).toBe(true);
  expect(p.tree.some((n: any) => n.parent === index)).toBe(false);
  expect(JSON.stringify(p)).not.toContain('REASONING_SECRET');
});

test('Kimi structure preserves hidden, inert and aria-hidden final rejection and ancestry visibility', async () => {
  for (const [attr,value] of [['hidden',''],['inert',''],['aria-hidden','true']]) {
    const f = adapterFixture(); await f.submit(); f.response.markdown.parentElement!.setAttribute(attr,value);
    const result = await f.run(), p = result.adapterFailureStructure; packetShape(p);
    expect(result.detail).toBe('authored_source_markdown_visibility');
    expect(p.markdownCount).toBe(1); expect(p.markdownCandidates[0].visible).toBe(false);
    expect(p.tree.find((n: any) => n.category === 'markdown').visible).toBe(false);
    expect(p.answerVisible).toBe(true); expect(p.boxVisible).toBe(true);
  }
});

test('Kimi structure caps counts, candidates, tree and ancestry without accepting overflow', async () => {
  const f = adapterFixture(); await f.submit();
  for (let i=0;i<40;i++) f.part.append(f.response.markdown.parentElement!.cloneNode(true));
  for (let i=0;i<40;i++) reasoning(f);
  for (let i=0;i<300;i++) f.box.append(new f.Node('DIV'));
  const result = await f.run(), p = result.adapterFailureStructure; packetShape(p);
  expect(result.detail).toBe('authored_source_markdown_count'); expect(result.text).toBeUndefined();
  expect(p.markdownCount).toBe(33); expect(p.markdownCountOverflow).toBe(true);
  expect(p.excludedReasoningCount).toBe(33); expect(p.excludedReasoningCountOverflow).toBe(true);
  expect(p.markdownCandidates).toHaveLength(16); expect(p.tree).toHaveLength(256); expect(p.nodeLimitReached).toBe(true);
  expect(p.tree[0].elementChildCount).toBe(257); expect(p.tree[0].childCountOverflow).toBe(true);
  expect(p.markdownCandidates.some((n: any) => n.ancestryTruncated)).toBe(true);
  expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
});

test('Kimi structure caps deep traversal while preserving the same outside-content refusal', async () => {
  const f = adapterFixture(); await f.submit(); let node=f.box;
  for(let i=0;i<25;i++){const next=new f.Node('DIV');node.append(next);node=next;}
  node.append(new f.Node('P',{},'DO_NOT_CAPTURE_DEEP_TEXT'));
  const result = await f.run(), p=result.adapterFailureStructure; packetShape(p);
  expect(result.detail).toBe('authored_source_outside_content'); expect(p.nodeLimitReached).toBe(true);
  expect(Math.max(...p.tree.map((n: any)=>n.depth))).toBe(16);
  expect(JSON.stringify(p)).not.toContain('DO_NOT_CAPTURE');
});

test('Kimi structure never serializes authored text, arbitrary classes, tags, attribute values, IDs or URLs', async () => {
  const f = adapterFixture(); await f.submit();
  f.part.append(new f.Node('SECRET-TAG',{class:'SECRET_CLASS',id:'SECRET_ID',role:'SECRET_ROLE',
    href:'https://private.invalid/SECRET_URL',title:'SECRET_TITLE'},'SECRET_BODY'));
  const result=await f.run(), p=result.adapterFailureStructure;packetShape(p);
  expect(result.detail).toBe('authored_source_outside_content');
  const unknown=p.tree.find((n: any)=>n.tag==='other');
  expect(unknown.category).toBe('other');expect(unknown.unknownClassPresent).toBe(true);expect(unknown.interactive).toBe(true);
  expect(JSON.stringify(result)).not.toContain('SECRET');expect(JSON.stringify(result)).not.toContain('https:');
  expect(JSON.stringify(result)).not.toContain('65258a69');
});

test('Kimi does not construct a diagnostic before terminal conjunction or during cleanup inspection', async () => {
  const f = adapterFixture({streaming:true});await f.submit(); f.part.append(f.response.markdown.cloneNode(true));
  let structureReads=0;Object.defineProperty(f.box,'childElementCount',{get(){structureReads++;return 2;}});
  const streaming=await f.run();expect(streaming.error).toBeUndefined();expect(streaming.adapterFailureStructure).toBeUndefined();
  expect(structureReads).toBe(0);f.finishResponse();
  const cleanup=await f.run('inspect',{kimiCleanupInspection:true});
  expect(cleanup.error).toBeUndefined();expect(cleanup.text).toBe('');expect(cleanup.answerComplete).toBe(false);
  expect(cleanup.adapterFailureStructure).toBeUndefined();expect(structureReads).toBe(0);
  const failed=await f.run();expect(failed.detail).toBe('authored_source_markdown_count');expect(structureReads).toBeGreaterThan(0);
  expect((await f.run('submit')).error).toBeDefined();expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
});

test('Kimi diagnostic construction failure preserves the exact original rejection', async () => {
  const f=adapterFixture();await f.submit();f.part.append(f.response.markdown.cloneNode(true));
  Object.defineProperty(f.box,'childElementCount',{get(){throw new Error('SENSITIVE_DIAGNOSTIC_FAILURE');}});
  expect(await f.run()).toEqual({error:'unsupported_response_format',detail:'authored_source_markdown_count'});
  expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
});
