import { describe, expect, test } from 'bun:test';
import { fixture, raw, conversationID, answerID } from './embedded-qwen-adapter-fixture';

describe('Qwen observed DOM driver', () => {
  test('only observed exact origin and canonical UUID route are recognized', () => {
    const f = fixture(); expect(f.read().route()).toMatchObject({ kind: 'fresh', conversation: null, id: null });
    f.mountConversation(); expect(f.read().route().id).toBe(conversationID);
    for (const suffix of ['?chat=1', '#fragment', '/', '/other']) {
      f.document.URL = 'https://chat.qwen.ai/c/' + conversationID + suffix;
      expect(() => f.read().route()).toThrow();
    }
    expect(f.mutations()).toBe(0);
  });

  test('model identities come only from unique checked rows, distinct from API IDs', () => {
    const f = fixture(); expect(f.read().picker().closed).toBe(true); f.openPicker();
    const rows = f.read().modelRows(f.modelMenu);
    expect(rows.map(row => row.choice)).toEqual(['Qwen3.7-Plus', 'Qwen3.8-Max', 'Qwen3.8-Omni-Flash'].map(label => ({ key: label, label })));
    expect(rows.filter(row => row.selected)).toHaveLength(1); expect(f.mutations()).toBe(0);
    f.choices[1].setAttribute('aria-selected', 'true'); expect(() => f.read().modelRows(f.modelMenu)).toThrow();
  });

  test('duplicate model labels or contradictory trigger state are not fresh selection proof', () => {
    const duplicate = fixture(); duplicate.openPicker(); duplicate.modelMenu.append(duplicate.choices[0].cloneNode(true));
    expect(() => duplicate.read().modelRows(duplicate.modelMenu)).toThrow();
    const drift = fixture(); drift.openPicker(); drift.modelName.text = 'Other model';
    expect(() => drift.read().modelRows(drift.modelMenu)).toThrow();
    const foreign = fixture(); foreign.body.append(new foreign.Node('DIV', { role: 'listbox' }));
    expect(() => foreign.read().picker()).toThrow();
  });

  test('textarea preserves exact bytes and Send can appear only in its owned composer scope', () => {
    const f = fixture(); const blank = f.read().composer(); expect(blank.empty).toBe(true); expect(blank.send).toBeNull();
    const draft = '\n  "literal" café 👋\t\u00a0\n\n'; f.editor.value = draft;
    f.sendScope.append(f.send); const ready = f.read().composer(); expect(ready.text).toBe(draft); expect(ready.sendReady).toBe(true);
    f.occlude(f.send); expect(f.read().composer().sendReady).toBe(false);
    f.sendScope.append(f.send.cloneNode(true)); expect(() => f.read().composer()).toThrow();
    expect(f.mutations()).toBe(0);
  });

  test('streaming Stop is distinct from completion and must match current conversation', () => {
    const f = fixture(); f.mountConversation(false); let dom = f.read();
    expect(dom.composer().streaming).toBe(true); expect(dom.completionCandidate(dom.transcript().answer)).toBe(false);
    f.stop.setAttribute('data-chat-id', '11111111-2222-4333-8444-555555555555');
    expect(() => f.read().composer()).toThrow();
  });

  test('first user and assistant scopes retain exact bodies and independent message IDs', () => {
    const f = fixture(); f.mountConversation(); let observed = f.read().transcript();
    expect(observed.first.text).toBe('Exact synthetic prompt\nSecond line'); expect(observed.answer.id).toBe(answerID);
    f.userContainer.setAttribute('data-chat-id', '11111111-2222-4333-8444-555555555555');
    expect(() => f.read().transcript()).toThrow();
    f.userContainer.setAttribute('data-chat-id', conversationID);
    f.userBody.append(new f.Node('SPAN', {}, 'Hidden content')); expect(() => f.read().transcript()).toThrow();
  });

  test('raw JSON is read in full from the observed plain text structure, independent of completion', () => {
    const f = fixture(); f.mountConversation(); const dom = f.read(), answer = dom.transcript().answer;
    expect(dom.rawAnswer(answer)).toEqual({ text: raw, finalMarkup: true, formatIssue: false });
    expect(dom.completionCandidate(answer)).toBe(true); expect(f.mutations()).toBe(0);
    f.actions[4].setAttribute('disabled', ''); f.actions[4].disabled = true;
    expect(dom.completionCandidate(answer)).toBe(false);
    f.literal.text = '{"type":"tool_calls",'; expect(dom.rawAnswer(answer).text).toBe('{"type":"tool_calls",');
  });

  test('outside prose and multiple plain-text parts are never silently removed', () => {
    for (const where of ['paragraph', 'markdown', 'flow', 'literal']) {
      const f = fixture(); f.mountConversation();
      if (where === 'literal') f.literal.text = 'Outside prose ' + raw;
      else if (where === 'paragraph') f.paragraph.append(new f.Node('SPAN', {}, 'Outside prose'));
      else if (where === 'markdown') f.markdown.append(f.paragraph.cloneNode(true));
      else f.flow.append(new f.Node('DIV', {}, 'Outside prose'));
      const dom = f.read(), result = dom.rawAnswer(dom.transcript().answer);
      if (where === 'literal') expect(result.text).toBe('Outside prose ' + raw);
      else { expect(result.formatIssue).toBe(true); expect(result.text).toBe(''); }
    }
  });

  test('fenced Monaco code and hidden or unknown nested text remain unsupported', () => {
    for (const kind of ['monaco', 'hidden', 'nested', 'duplicate-phase']) {
      const f = fixture(); f.mountConversation();
      if (kind === 'monaco') {
        const code = new f.Node('PRE', { class: 'qwen-markdown-code' });
        code.append(new f.Node('DIV', { class: 'monaco-editor' }, raw)); f.markdown.replaceChildren(code);
      } else if (kind === 'hidden') f.literal.setAttribute('hidden', '');
      else if (kind === 'nested') f.literal.append(new f.Node('CODE', {}, raw));
      else f.flow.append(f.phase.cloneNode(true));
      const dom = f.read(); expect(dom.rawAnswer(dom.transcript().answer).formatIssue).toBe(true);
    }
  });

  test('footer metadata cannot refer to a different chat or assistant', () => {
    const f = fixture(); f.mountConversation(); const dom = f.read(), answer = dom.transcript().answer;
    f.rail.setAttribute('data-msg-id', conversationID); expect(() => dom.completionCandidate(answer)).toThrow();
    f.rail.setAttribute('data-msg-id', answerID); f.rail.setAttribute('data-chat-id', answerID);
    expect(() => dom.completionCandidate(answer)).toThrow();
  });

  test('deletion controls remain read-only and confirmation must name this exact chat', () => {
    const f = fixture(); f.mountConversation(); const dom = f.read();
    expect(dom.deletionTrigger()).toBe(f.more); expect(dom.deletionMenu()).toBeNull();
    f.body.append(f.menu); expect(dom.deletionMenu().target).toBe(f.remove);
    f.body.append(f.dialog); expect(dom.deletionConfirmation().target).toBe(f.confirm);
    expect(f.mutations()).toBe(0);
    f.notice.setAttribute('data-chat-id', answerID); expect(() => dom.deletionConfirmation()).toThrow();
    expect(f.mutations()).toBe(0);
  });

  test('foreign or ambiguous destructive controls cannot be selected', () => {
    const f = fixture(); f.mountConversation(); f.body.append(f.dialog); const dom = f.read();
    f.title.text = 'Delete all chats?'; expect(() => dom.deletionConfirmation()).toThrow();
    f.title.text = 'Delete this chat?'; f.body.append(f.dialog.cloneNode(true)); expect(() => dom.deletionConfirmation()).toThrow();
    expect(f.mutations()).toBe(0);
  });
});
