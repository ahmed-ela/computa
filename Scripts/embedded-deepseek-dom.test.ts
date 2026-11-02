import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { fixture, conversation, raw } from './embedded-deepseek-adapter-fixture';
const fails = (action: () => unknown, detail?: string) => {
  try { action(); throw new Error('Expected a bounded adapter rejection'); }
  catch (error: any) {
    expect(error.computaAdapterFailure).toBe(true);
    if (detail) expect(error.detail).toBe(detail);
  }
};
describe('DeepSeek DOM driver', () => {
  test('the arrow matches the finite observed control; negative streaming evidence is still absent', () => {
    const observed = JSON.parse(readFileSync(new URL('./EmbeddedSavedProviders/deepseek-observed-controls.json', import.meta.url), 'utf8'));
    expect(fixture().path.getAttribute('d')).toBe(observed.arrowPath);
    expect(observed.negativeStreamingObservation).toBe(false);
  });
  test('mode evidence exposes Chat and DeepThink with no invented backend', () => {
    const f = fixture();
    expect(f.read().modeEvidence()).toEqual({ selected: { key: 'chat', label: 'Chat' }, source: 'website_mode_toggle', backendModel: null, search: false });
    f.setMode(true);
    expect(f.read().modeEvidence().selected).toEqual({ key: 'deepthink', label: 'DeepThink' });
    expect(f.mutations()).toBe(0);
  });
  test('Search, inconsistent pressed state and duplicate toggles cannot supply mode proof', () => {
    const f = fixture(); f.setMode(false, true); fails(() => f.read().modeEvidence());
    f.setMode(false); f.deepThink.values['aria-pressed'] = 'true'; fails(() => f.read().modeEvidence());
    f.setMode(false); f.scope.append(new f.Node('DIV', { class: 'ds-toggle-button' })); fails(() => f.read().modeEvidence());
  });
  test('route recognition is exact and cannot turn query, fragment or alternate host into ownership', () => {
    const f = fixture(); expect(f.read().route().canonical).toBe(conversation);
    for (const url of [conversation + '?x=1', conversation + '#x', conversation + '/', conversation.replace('https:', 'http:'),
      conversation.replace('chat.deepseek.com', 'deepseek.com'), 'https://chat.deepseek.com/a/chat/s/other']) {
      f.document.URL = url; fails(() => f.read().route());
    }
    f.document.URL = 'https://chat.deepseek.com/'; expect(f.read().route().kind).toBe('fresh');
  });
  test('a driver cannot outlive the exact invocation route', () => {
    const f = fixture(), dom = f.read(); f.document.URL = conversation.replace('12345678-', '87654321-');
    fails(() => dom.route(), 'document_url');
  });
  test('exact first body and whole raw final are preserved without parsing or punctuation repair', () => {
    const f = fixture(), dom = f.read(), t = dom.transcript();
    expect(t.first.text).toBe(f.firstText.text); expect(dom.rawAnswer(t.answer).text).toBe(raw);
    f.literal.text = 'Intro: {“type”:“message”}'; expect(dom.rawAnswer(t.answer).text).toBe(f.literal.text);
    expect(f.mutations()).toBe(0);
  });
  test('known reasoning is not read; unrecognized surrounding authored content is rejected', () => {
    const f = fixture();
    f.reasoning.append(new f.Node('DIV', { class: 'ds-collapsible-text' }, 'Never read this reasoning canary'));
    f.answer.replaceChildren(f.reasoning, f.final);
    expect(f.read().rawAnswer(f.read().transcript().answer).text).toBe(raw);
    f.answer.append(new f.Node('P', {}, 'Outside authored prose'));
    expect(f.read().rawAnswer(f.read().transcript().answer)).toEqual({ text: '', finalMarkup: false, formatIssue: true });
  });
  test('additional paragraphs, hidden text and nested formatting cannot be flattened into JSON', () => {
    for (const kind of ['paragraph', 'hidden', 'format']) {
      const f = fixture();
      if (kind === 'paragraph') f.final.append(new f.Node('P', { class: 'ds-markdown-paragraph' }, 'More prose'));
      if (kind === 'hidden') f.literal.values.hidden = '';
      if (kind === 'format') f.literal.append(new f.Node('EM', {}, 'formatted'));
      expect(f.read().rawAnswer(f.read().transcript().answer).formatIssue).toBe(true);
    }
  });
  test('foreign duplicate user/answer roots and repeated turn keys fail closed', () => {
    const f = fixture(); f.answerTurn.values['data-virtual-list-item-key'] = '-2'; fails(() => f.read().transcript(), 'response_scope');
    f.answerTurn.values['data-virtual-list-item-key'] = '2'; f.body.append(new f.Node('DIV', { class: 'ds-message' }));
    fails(() => f.read().transcript());
  });
  test('terminal-looking candidate needs all six buttons, Read aloud and the restored arrow', () => {
    const f = fixture(), dom = f.read(), answer = dom.transcript().answer;
    expect(dom.completionCandidate(answer)).toBe(true);
    f.path.values.d = 'unknown streaming glyph'; expect(dom.completionCandidate(answer)).toBe(false);
    f.path.values.d = fixture().path.values.d;
    f.actions[4].values['aria-label'] = 'Other'; expect(dom.completionCandidate(answer)).toBe(false);
    f.actions[4].values['aria-label'] = 'Read aloud'; f.actions[0].disabled = true;
    expect(dom.completionCandidate(answer)).toBe(false);
    f.actions[0].disabled = false; f.editor.value = 'unsent draft'; expect(dom.completionCandidate(answer)).toBe(false);
    expect(f.mutations()).toBe(0);
  });
  test('missing action rail is negative but does not invent a streaming signal', () => {
    const f = fixture(), answer = f.read().transcript().answer;
    f.rail.detach(); expect(f.read().completionCandidate(answer)).toBe(false);
    expect(f.read().composer().streaming).toBeNull();
  });
  test('Send readiness honors class disabled, aria disabled and hit target', () => {
    const f = fixture(); expect(f.read().composer().sendReady).toBe(false);
    f.send.values.class = 'ds-button ds-button--primary ds-button--circle'; expect(f.read().composer().sendReady).toBe(true);
    f.send.values['aria-disabled'] = 'true'; expect(f.read().composer().sendReady).toBe(false);
    delete f.send.values['aria-disabled']; f.occlude(f.send); expect(f.read().composer().sendReady).toBe(false);
  });
  test('insertion uses one literal textarea assignment and input event only', () => {
    const f = fixture(), dom = f.read(); const prompt = '  café <img> "\\n"\nlast\t\u00a0';
    dom.insertLiteral(dom.composer(), prompt);
    expect(f.editor.value).toBe(prompt); expect(f.editor.events.length).toBe(1); expect(f.mutations()).toBe(1); expect(f.send.clicks).toBe(0);
  });
  test('deletion binds the exact owned history anchor and first body without clicking', () => {
    const f = fixture(), dom = f.read(), context = f.context();
    expect(dom.deletionTrigger(context)).toBe(f.trigger); expect(context.anchor).toBe(f.anchor);
    f.firstText.text += '!'; fails(() => dom.deletionTrigger(context), 'delete_ownership'); expect(f.mutations()).toBe(0);
  });
  test('duplicate or replaced owned anchors cannot inherit a prior deletion chain', () => {
    const f = fixture(), context = f.context();
    f.body.append(new f.Node('A', { href: conversation })); fails(() => f.read().deletionTrigger(context), 'delete_anchor');
    const g = fixture(), old = g.context(); g.anchor.detach();
    const replacement = new g.Node('A', { href: conversation }); replacement.append(new g.Node('DIV', { role: 'button', class: 'ds-button' })); g.body.append(replacement);
    fails(() => g.read().deletionTrigger(old), 'delete_ownership');
  });
  test('an existing foreign popup prevents creating a deletion context', () => {
    const f = fixture(); f.body.append(f.modal); fails(() => f.context(), 'delete_ownership');
    expect(f.mutations()).toBe(0);
  });
  test('menu and confirmation reads need separate acknowledged claims and keep DOM identity', () => {
    const f = fixture(), record: any = f.record(); record.deleteAcknowledged = false; f.body.append(f.menu);
    expect(f.read().deletionMenu(record).target).toBe(f.remove);
    record.menuAcknowledged = false; fails(() => f.read().deletionMenu(record), 'delete_menu_open_unacknowledged'); record.menuAcknowledged = true;
    f.menu.detach(); f.body.append(f.modal); fails(() => f.read().deletionConfirmation(record), 'delete_confirm_selection_unacknowledged');
    record.deleteAcknowledged = true; expect(f.read().deletionConfirmation(record).target).toBe(f.confirm);
    f.firstText.text += ' changed'; fails(() => f.read().deletionConfirmation(record), 'delete_ownership');
    expect(f.mutations()).toBe(0);
  });
  test('cleanup phase diagnostics distinguish exact failed predicates without dispatching', () => {
    for (const kind of ['menu_ack', 'selection_ack', 'menu_binding', 'visible_menu']) {
      const f = fixture(), record: any = f.record(); f.body.append(f.modal);
      if (kind === 'menu_ack') record.menuAcknowledged = false;
      if (kind === 'selection_ack') record.deleteAcknowledged = false;
      if (kind === 'menu_binding') record.menu = null;
      if (kind === 'visible_menu') f.body.append(f.menu);
      const detail = { menu_ack: 'delete_confirm_menu_unacknowledged', selection_ack: 'delete_confirm_selection_unacknowledged',
        menu_binding: 'delete_confirm_menu_unbound', visible_menu: 'delete_confirm_menu_still_visible' }[kind];
      fails(() => f.read().deletionConfirmation(record), detail);
      expect(f.mutations()).toBe(0);
    }
    const f = fixture(), record = f.record(); f.body.append(f.menu);
    fails(() => f.read().deletionMenu(record), 'delete_menu_selection_spent'); expect(f.mutations()).toBe(0);
  });
  test('route drift, wrong wording and duplicate dialogs prevent confirmation', () => {
    for (const kind of ['route', 'wording', 'duplicate']) {
      const f = fixture(), record = f.record(); f.body.append(f.modal);
      if (kind === 'route') f.document.URL = conversation.replace('12345678-', '87654321-');
      if (kind === 'wording') f.title.text = 'Delete all chats';
      if (kind === 'duplicate') f.body.append(new f.Node('DIV', { role: 'dialog' }));
      fails(() => f.read().deletionConfirmation(record)); expect(f.mutations()).toBe(0);
    }
  });
  test('cleanup needs exact confirmed chain and absence of owned roots, dialog and history', () => {
    const f = fixture(), record = f.record(); f.body.append(f.modal);
    expect(f.read().deletionObserved(record)).toBe(false); f.deleted(); expect(f.read().deletionObserved(record)).toBe(true);
    f.body.append(new f.Node('A', { href: conversation })); expect(f.read().deletionObserved(record)).toBe(false);
    const g = fixture(), unconfirmed = g.record(); unconfirmed.confirmAcknowledged = false; g.deleted();
    fails(() => g.read().deletionObserved(unconfirmed), 'delete_operation');
  });
  test('empty root or missing composer alone never establishes deletion', () => {
    const f = fixture(), record = f.record(); f.document.URL = 'https://chat.deepseek.com/';
    expect(f.read().deletionObserved(record)).toBe(false); f.deleted(); f.editor.detach();
    expect(f.read().deletionObserved(record)).toBe(false);
  });
});
