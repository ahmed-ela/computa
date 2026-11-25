import type { AppSnapshot, NativeAction, TaskSnapshot } from './types';

type CompletionAction = Extract<NativeAction, { action: 'acknowledgeTaskCompletion' }>;

export function unreadCompletionID(task: Pick<TaskSnapshot, 'status' | 'isBusy' | 'hasUnreadCompletion' | 'unreadCompletionID'>) {
  if (task.status === 'Completed' && !task.isBusy && task.hasUnreadCompletion) return task.unreadCompletionID;
}

/** The chat actually on screen. A selected task can sit behind a browser, draft or modal. */
export function displayedConversationID(snapshot: AppSnapshot | null): string | undefined {
  if (!snapshot || snapshot.canViewConversation === false || snapshot.primaryBrowserID
    || snapshot.savedChatSelection || snapshot.newAgentDraft || snapshot.isSettingsPresented
    || snapshot.isReviewPresented || snapshot.pendingApprovalCount > 0) return;
  return snapshot.selectedTaskID;
}

export function displayedCompletionAcknowledgment(
  snapshot: AppSnapshot | null, visible: boolean, focused: boolean,
): CompletionAction | undefined {
  if (!snapshot || !visible || !(snapshot.canViewConversation ?? focused)) return;
  const id = displayedConversationID(snapshot);
  if (!id) return;
  const task = snapshot.tasks.find((candidate) => candidate.id === id);
  const completionID = task && unreadCompletionID(task);
  if (completionID) return { action: 'acknowledgeTaskCompletion', taskID: id, completionID };
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
