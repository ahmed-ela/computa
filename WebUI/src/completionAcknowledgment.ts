import type { AppSnapshot, NativeAction } from './types';

type CompletionAction = Extract<NativeAction, { action: 'acknowledgeTaskCompletion' }>;

export function displayedCompletionAcknowledgment(
  snapshot: AppSnapshot | null, visible: boolean, focused: boolean,
): CompletionAction | undefined {
  if (!snapshot || !visible || !focused || snapshot.isSettingsPresented
    || snapshot.isReviewPresented || snapshot.pendingApprovalCount > 0) return;
  const task = snapshot.tasks.find((candidate) => candidate.id === snapshot.selectedTaskID);
  if (!task || task.status !== 'Completed' || task.isBusy || !task.hasUnreadCompletion
    || !task.unreadCompletionID) return;
  return { action: 'acknowledgeTaskCompletion', taskID: task.id, completionID: task.unreadCompletionID };
}

export interface CompletionDisplayEvents {
  visible: () => boolean;
  focused: () => boolean;
  afterRender: (callback: () => void) => () => void;
  onReturn: (callback: () => void) => () => void;
}

export function observeDisplayedCompletion(
  snapshot: () => AppSnapshot | null, events: CompletionDisplayEvents,
  acknowledge: (action: CompletionAction) => void,
): () => void {
  let disposed = false;
  let cancelFrame: (() => void) | undefined;
  const schedule = () => {
    cancelFrame?.();
    cancelFrame = undefined;
    const candidate = displayedCompletionAcknowledgment(snapshot(), events.visible(), events.focused());
    if (disposed || !candidate) return;
    cancelFrame = events.afterRender(() => {
      cancelFrame = undefined;
      if (disposed) return;
      const current = displayedCompletionAcknowledgment(snapshot(), events.visible(), events.focused());
      // A frame scheduled for an older task/completion cannot acknowledge a newer one.
      if (current?.taskID === candidate.taskID && current.completionID === candidate.completionID) acknowledge(current);
    });
  };
  const stopListening = events.onReturn(schedule);
  schedule();
  return () => { disposed = true; cancelFrame?.(); stopListening(); };
}
