import { expect, test } from 'bun:test';
import { adapterFixture, submissionFingerprint } from './embedded-kimi-adapter-fixture';

// The retained401 finite packet proves one markdown is inside an excluded
// outer flow, although closest() classified neither markdown as reasoning.
// Inner wrappers here are synthetic; the packet intentionally omits their DOM.
function nestedReasoning(f: ReturnType<typeof adapterFixture>, outerKind = 'toolcall-flow', innerKind = 'thinking-container') {
  const outer = new f.Node('DIV', { class: outerKind });
  const branch = new f.Node('DIV');
  const inner = new f.Node('DIV', { class: innerKind });
  const first = new f.Node('DIV'), second = new f.Node('DIV');
  const container = new f.Node('DIV', { class: 'markdown-container' });
  const markdown = new f.Node('DIV', { class: 'markdown' });
  markdown.append(new f.Node('P', {}, 'PRIVATE_REASONING_MUST_NOT_BE_READ'));
  container.append(markdown); second.append(container); first.append(second);
  inner.append(first); branch.append(inner); outer.append(branch, new f.Node('DIV'));
  f.thoughtPart.replaceChildren(outer);
  return { outer, inner, markdown };
}

const finiteTree401 = [
  [-1,0,'content_box',false,false,1], [0,1,'other',false,false,3],
  [1,2,'reasoning_part',false,false,1], [2,3,'reasoning_flow',true,true,2],
  [1,2,'reasoning_part',false,false,1], [4,3,'markdown_container',false,false,1],
  [5,4,'markdown',false,false,1], [6,5,'other',true,false,0],
  [1,2,'other',true,false,1], [8,3,'other',true,false,0],
].map(([parent,depth,category,unknownClassPresent,reasoningExcluded,elementChildCount]) => ({
  parent,depth,category,unknownClassPresent,reasoningExcluded,elementChildCount,
  tag:'div',visible:true,interactive:false,childCountOverflow:false,
}));

test('Kimi401 finite projection excludes the already-pruned reasoning subtree but keeps unknown final markup rejected', async () => {
  const f = adapterFixture(); await f.submit(); const r = nestedReasoning(f);
  r.outer.setAttribute('class','toolcall-flow synthetic-opaque-class');
  f.response.markdown.replaceChildren(new f.Node('DIV',{class:'synthetic-unknown-final'},'SYNTHETIC_UNACCEPTED_FINAL'));
  const footer = new f.Node('DIV',{class:'synthetic-unknown-footer'});
  footer.append(new f.Node('DIV',{class:'synthetic-unknown-leaf'})); f.part.parentElement!.append(footer);
  const result = await f.run(), packet = result.adapterFailureStructure;
  expect(result).toMatchObject({error:'unsupported_response_format',detail:'authored_source_json_count'});
  expect(packet.markdownCount).toBe(1); expect(packet.excludedReasoningCount).toBe(1);
  expect(packet.nodeLimitReached).toBe(false); expect(packet.tree).toEqual(finiteTree401);
  expect(packet.markdownCandidates).toEqual([
    {ancestry:['markdown','markdown_container','other','other'],ancestryTruncated:true,excludedReasoning:true,visible:true},
    {ancestry:['markdown','markdown_container','reasoning_part','other'],ancestryTruncated:true,excludedReasoning:false,visible:true},
  ]);
  expect(result.text).toBeUndefined(); expect(result.answerComplete).toBeUndefined();
  expect(result.firstUserFingerprint).toBeUndefined();
  expect(JSON.stringify(result)).not.toContain('PRIVATE_'); expect(JSON.stringify(result)).not.toContain('SYNTHETIC_');
  expect((await f.run('submit')).error).toBeDefined();
  expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
});

test('nested nonqualifying wrappers cannot mask known outer reasoning; final literal and proofs stay exact', async () => {
  for (const outer of ['toolcall-flow','thinking-container']) for (const inner of ['toolcall-flow','thinking-container']) {
    const f = adapterFixture({streaming:true}); await f.submit(); const r = nestedReasoning(f,outer,inner);
    for (const node of [r.outer,r.inner,r.markdown]) Object.defineProperty(node,'textContent',{
      get(){throw new Error('reasoning text must not be read');},
    });
    const literal = '{\n "type": "message", "text": "Literal \\u0061 and café"\n}';
    f.response.code.text = literal;
    const streaming = await f.run(); expect(streaming.error).toBeUndefined(); expect(streaming.answerComplete).toBe(false);
    expect(streaming.text).toBe(literal); expect(streaming.firstUserFingerprint).toBe(submissionFingerprint);
    f.finishResponse(); const complete = await f.run();
    expect(complete.error).toBeUndefined(); expect(complete.answerComplete).toBe(true); expect(complete.text).toBe(literal);
    expect(complete.firstUserFingerprint).toBe(submissionFingerprint);
    expect(complete.modelEvidence.selected).toEqual({key:'k28-instant',label:'Instant'});
    expect(complete.adapterFailureStructure).toBeUndefined(); expect(JSON.stringify(complete)).not.toContain('PRIVATE_');
    const deleteOperation = f.operation();
    for (const action of ['deleteConversation','selectConversationDeletion','confirmConversationDeletion']) {
      expect((await f.run(action,{deleteOperation})).error).toBeUndefined();
    }
    expect((await f.run('observeDeletedConversation',{deleteOperation})).deleteProof.conversationDeleted).toBe(true);
    expect(f.counts()).toEqual({insertions:1,sends:1,confirms:1});
  }
});

test('nested reasoning correction preserves unknown regions, authored reasoning-like nodes, extra sources and prose rejection', async () => {
  for (const kind of ['unknown-outer','authored-outer','extra-final','outside-prose','reasoning-only','duplicate-code']) {
    const f = adapterFixture(); await f.submit(); const r = nestedReasoning(f);
    if (kind === 'unknown-outer') r.outer.setAttribute('class','unrecognized-provider-widget');
    if (kind === 'authored-outer') {
      f.remove(f.thoughtPart); f.response.markdown.append(f.thoughtPart);
    }
    if (kind === 'extra-final') f.part.append(f.response.markdown.parentElement!.cloneNode(true));
    if (kind === 'outside-prose') f.part.append(new f.Node('P',{},'PRIVATE_EXTRA_PROSE'));
    if (kind === 'reasoning-only') f.remove(f.part);
    if (kind === 'duplicate-code') f.response.markdown.append(f.response.segment.cloneNode(true));
    const result = await f.run();
    expect(result.error).toBe('unsupported_response_format');
    expect(result.detail).toBe(kind === 'outside-prose' ? 'authored_source_outside_content'
      : kind === 'duplicate-code' ? 'authored_source_json_count' : 'authored_source_markdown_count');
    expect(result.text).toBeUndefined(); expect(result.answerComplete).toBeUndefined();
    expect(JSON.stringify(result)).not.toContain('PRIVATE_');
    expect((await f.run('submit')).error).toBeDefined(); expect(f.counts()).toEqual({insertions:1,sends:1,confirms:0});
  }
});

test('nested reasoning exclusion never repairs malformed literal JSON or weakens current user ownership', async () => {
  const malformed = adapterFixture(); await malformed.submit(); nestedReasoning(malformed);
  malformed.response.code.text = '{"type":"tool_calls",';
  expect((await malformed.run()).text).toBe('{"type":"tool_calls",');
  const changed = adapterFixture(); await changed.submit(); nestedReasoning(changed);
  changed.messages.userBody.text += ' changed';
  const result = await changed.run(); expect(result.error).toBeDefined(); expect(result.text).toBeUndefined();
  expect(result.firstUserFingerprint).toBeUndefined(); expect(changed.counts()).toEqual({insertions:1,sends:1,confirms:0});
});
