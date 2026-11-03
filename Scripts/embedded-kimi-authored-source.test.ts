import { expect, test } from 'bun:test';
import { adapterFixture, submissionFingerprint } from './embedded-kimi-adapter-fixture';

function reasoningMarkdown(f: ReturnType<typeof adapterFixture>, kind = 'thinking-container') {
  const wrapper = new f.Node('DIV', { class: kind });
  const container = new f.Node('DIV', { class: 'markdown-container' });
  const markdown = new f.Node('DIV', { class: 'markdown' });
  markdown.append(new f.Node('P', {}, 'PRIVATE_REASONING_CANARY'));
  container.append(markdown); wrapper.append(container); f.thoughtPart.append(wrapper);
  return { wrapper, container, markdown };
}

test('recognized reasoning markdown is excluded from final-source cardinality without changing literal JSON', async () => {
  for (const kind of ['thinking-container', 'toolcall-flow']) {
    const f = adapterFixture({ streaming: true }); await f.submit();
    reasoningMarkdown(f, kind);
    expect(f.box.querySelectorAll('.markdown')).toHaveLength(2);
    const streaming = await f.run();
    expect(streaming.error).toBeUndefined(); expect(streaming.answerComplete).toBe(false);
    expect(streaming.text).toBe('{"type":"message","text":"Synthetic reply"}');
    f.finishResponse(); const complete = await f.run();
    expect(complete.error).toBeUndefined(); expect(complete.answerComplete).toBe(true);
    expect(complete.text).toBe('{"type":"message","text":"Synthetic reply"}');
    expect(complete.firstUserFingerprint).toBe(submissionFingerprint);
    expect(complete.modelEvidence.selected).toEqual({ key:'k28-instant', label:'Instant' });
    expect(JSON.stringify(complete)).not.toContain('PRIVATE_REASONING_CANARY');
    expect(f.counts()).toEqual({ insertions:1, sends:1, confirms:0 });
  }
});

test('unknown or authored reasoning-like scopes and ambiguous final regions still reject', async () => {
  for (const kind of ['unknown-wrapper', 'authored-wrapper', 'extra-final', 'reasoning-only', 'outside-prose']) {
    const f = adapterFixture({ streaming: true }); await f.submit();
    const thought = reasoningMarkdown(f, kind === 'unknown-wrapper' ? 'unknown-provider-widget' : 'thinking-container');
    if (kind === 'authored-wrapper') {
      f.thoughtPart.children = f.thoughtPart.children.filter(node => node !== thought.wrapper);
      f.response.markdown.append(thought.wrapper);
    } else if (kind === 'extra-final') {
      f.part.append(f.response.markdown.parentElement!.cloneNode(true));
    } else if (kind === 'reasoning-only') {
      f.remove(f.part);
    } else if (kind === 'outside-prose') {
      f.part.append(new f.Node('P', {}, 'PRIVATE_OUTSIDE_CANARY'));
    }
    const streaming = await f.run();
    expect(streaming.error).toBeUndefined(); expect(streaming.answerComplete).toBe(false);
    expect(streaming.text).toBe('');
    f.finishResponse(); const rejected = await f.run();
    expect(rejected.error).toBe('unsupported_response_format');
    expect(rejected.detail).toBe(kind === 'outside-prose' ? 'authored_source_outside_content' : 'authored_source_markdown_count');
    expect(rejected.text).toBeUndefined(); expect(rejected.answerComplete).toBeUndefined();
    expect(JSON.stringify(rejected)).not.toContain('PRIVATE_');
    expect((await f.run()).error).toBe('unsupported_response_format');
    expect((await f.run('submit')).error).toBeDefined();
    expect(f.counts()).toEqual({ insertions:1, sends:1, confirms:0 });
  }
});

test('every authored-source branch emits a finite exact reason and no page content', async () => {
  const reasons = ['markdown_count','markdown_visibility','markdown_scope','json_count','pre_shape',
    'highlighter_shape','segment_scope','code_visibility','outside_content'];
  for (const reason of reasons) {
    const f = adapterFixture(); await f.submit(); const response = f.response;
    if (reason === 'markdown_count') f.part.append(response.markdown.cloneNode(true));
    if (reason === 'markdown_visibility') response.markdown.setAttribute('hidden','');
    if (reason === 'markdown_scope') response.markdown.parentElement!.setAttribute('class','unknown');
    if (reason === 'json_count') response.code.setAttribute('class','language-text');
    if (reason === 'pre_shape') response.code.parentElement!.append(new f.Node('SPAN',{},'PRIVATE_CANARY'));
    if (reason === 'highlighter_shape') response.code.parentElement!.parentElement!.setAttribute('class','unknown');
    if (reason === 'segment_scope') response.segment.setAttribute('class','unknown');
    if (reason === 'code_visibility') response.code.setAttribute('hidden','');
    if (reason === 'outside_content') f.part.append(new f.Node('P',{},'PRIVATE_CANARY'));
    const result = await f.run();
    expect(result).toEqual({ error:'unsupported_response_format', detail:'authored_source_' + reason });
    expect(JSON.stringify(result)).not.toContain('PRIVATE_CANARY');
    expect(f.counts()).toEqual({ insertions:1, sends:1, confirms:0 });
  }
});

test('reasoning filtering does not repair malformed JSON or merge authored code blocks', async () => {
  const malformed = adapterFixture(); await malformed.submit(); reasoningMarkdown(malformed);
  malformed.response.code.text = '{"type":"tool_calls",';
  expect((await malformed.run()).text).toBe('{"type":"tool_calls",');
  const duplicate = adapterFixture(); await duplicate.submit(); reasoningMarkdown(duplicate);
  duplicate.response.markdown.append(duplicate.response.segment.cloneNode(true));
  expect(await duplicate.run()).toEqual({ error:'unsupported_response_format', detail:'authored_source_json_count' });
});
