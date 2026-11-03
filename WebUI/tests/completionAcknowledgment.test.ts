import { describe, expect, test } from 'bun:test';
import { displayedCompletionAcknowledgment, observeDisplayedCompletion } from '../src/completionAcknowledgment';
import { makePreviewSnapshot } from '../src/preview';
import type { AppSnapshot, NativeAction } from '../src/types';

function fixture(): AppSnapshot {
  const snapshot = makePreviewSnapshot();
  const task = snapshot.tasks.find((value) => value.hasUnreadCompletion)!;
  return { ...snapshot, selectedTaskID: task.id, isReviewPresented: false, isSettingsPresented: false, pendingApprovalCount: 0 };
}

function harness(initialVisible = true, initialFocused = true) {
  let snapshot = fixture();
  let visible = initialVisible;
  let focused = initialFocused;
  let frame: (() => void) | undefined;
  let onReturn: (() => void) | undefined;
  const sent: NativeAction[] = [];
  const stop = observeDisplayedCompletion(() => snapshot, {
    visible: () => visible, focused: () => focused,
    afterRender: (callback) => { frame = callback; return () => { if (frame === callback) frame = undefined; }; },
    onReturn: (callback) => { onReturn = callback; return () => { onReturn = undefined; }; },
  }, (action) => sent.push(action));
  return {
    sent, stop, snapshot: () => snapshot,
    setSnapshot: (next: AppSnapshot) => { snapshot = next; },
    visible: (value: boolean) => { visible = value; }, focused: (value: boolean) => { focused = value; },
    returnToApp: () => onReturn?.(), frame: () => { const callback = frame; frame = undefined; callback?.(); },
    pendingFrame: () => frame,
  };
}

describe('displayed completion acknowledgment', () => {
  test('requires the exact selected unread completed turn and a visible focused conversation', () => {
    const snapshot = fixture();
    const task = snapshot.tasks.find((value) => value.id === snapshot.selectedTaskID)!;
    expect(displayedCompletionAcknowledgment(snapshot, true, true)).toEqual({
      action: 'acknowledgeTaskCompletion', taskID: task.id, completionID: task.unreadCompletionID,
    });
    expect(displayedCompletionAcknowledgment(null, true, true)).toBeUndefined();
    for (const [visible, focused] of [[false, true], [true, false], [false, false]]) {
      expect(displayedCompletionAcknowledgment(snapshot, visible, focused)).toBeUndefined();
    }
    for (const changes of [{ isSettingsPresented: true }, { isReviewPresented: true }, { pendingApprovalCount: 1 }, { selectedTaskID: 'missing' }]) {
      expect(displayedCompletionAcknowledgment({ ...snapshot, ...changes }, true, true)).toBeUndefined();
    }
    for (const changes of [{ hasUnreadCompletion: false }, { unreadCompletionID: undefined }, { status: 'Failed' }, { status: 'Waiting' }, { isBusy: true }]) {
      const changed = { ...snapshot, tasks: [{ ...task, ...changes }] };
      expect(displayedCompletionAcknowledgment(changed, true, true)).toBeUndefined();
    }
  });
  test('does not acknowledge until a rendered frame and rechecks visibility and focus', () => {
    const h = harness();
    expect(h.sent).toEqual([]);
    h.focused(false); h.frame();
    expect(h.sent).toEqual([]);
    h.focused(true); h.returnToApp(); h.visible(false); h.frame();
    expect(h.sent).toEqual([]);
    h.visible(true); h.returnToApp();
    expect(h.sent).toEqual([]);
    h.frame();
    expect(h.sent).toHaveLength(1);
    h.stop();
  });
  test('completion arriving in the background waits for a focused visible return and a frame', () => {
    for (const [visible, focused] of [[false, true], [true, false], [false, false]]) {
      const h = harness(visible, focused);
      expect(h.pendingFrame()).toBeUndefined();
      h.returnToApp(); h.frame();
      expect(h.sent).toEqual([]);
      h.visible(true); h.focused(true); h.returnToApp();
      expect(h.sent).toEqual([]);
      h.frame();
      expect(h.sent).toHaveLength(1);
      h.stop();
    }
  });
  test('an old scheduled frame cannot acknowledge a newer completion or a different task', () => {
    for (const change of ['completion', 'task', 'settings', 'approval', 'review'] as const) {
      const h = harness();
      const snapshot = h.snapshot();
      const next = structuredClone(snapshot);
      if (change === 'completion') next.tasks.find((value) => value.id === next.selectedTaskID)!.unreadCompletionID = 'new-turn';
      if (change === 'task') next.selectedTaskID = 'preview-completed-4b';
      if (change === 'settings') next.isSettingsPresented = true;
      if (change === 'approval') next.pendingApprovalCount = 1;
      if (change === 'review') next.isReviewPresented = true;
      h.setSnapshot(next); h.frame();
      expect(h.sent).toEqual([]);
      h.stop();
    }
  });
  test('unmount cancels the frame/listeners; even a delivered stale callback is inert', () => {
    const h = harness();
    const oldFrame = h.pendingFrame();
    h.stop(); oldFrame?.(); h.returnToApp(); h.frame();
    expect(h.sent).toEqual([]);
    expect(h.pendingFrame()).toBeUndefined();
  });
});
