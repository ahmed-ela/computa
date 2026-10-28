import { Button } from '@octanejs/shadcn/Button';
import type { NativeAction, TaskSnapshot } from './types';

const resultMessages = {
  closed: 'The owned website session is closed. Your local chat is retained.',
  no_owned_session: 'No owned website session exists now. Earlier website deletion is unconfirmed.',
  unconfirmed: 'Website cleanup remains unconfirmed. The task stays paused.',
} as const;

export function websiteSessionCleanupAction(task: TaskSnapshot, blocked = false): NativeAction | undefined {
  if (blocked || !['Waiting', 'Failed'].includes(task.status) || task.isBusy || task.websiteSessionCleanupInProgress
      || !task.websiteSessionCleanupAvailable) return undefined;
  return { action: 'retryWebsiteSessionCleanup', taskID: task.id };
}

export function WebsiteSessionCleanupControl({ task, blocked = false, post }: {
  task: TaskSnapshot;
  blocked?: boolean;
  post: (action: NativeAction) => void;
}) {
  const inProgress = Boolean(task.websiteSessionCleanupInProgress);
  const outcome = task.websiteSessionCleanupOutcome;
  if (!task.websiteSessionCleanupAvailable && !inProgress && !outcome) return null;
  const action = websiteSessionCleanupAction(task, blocked);
  const message = inProgress ? 'Closing this task’s website session…'
    : outcome && Object.hasOwn(resultMessages, outcome) ? resultMessages[outcome]
    : 'Close this task’s website session while keeping your local chat.';
  return (
    <section className="website-session-cleanup" aria-label="Website session cleanup" aria-busy={inProgress}>
      <div className="website-session-cleanup-copy" role="status" aria-live="polite">
        <span>{message}</span>
        {task.websiteSessionCleanupReceiptSaved === false && !inProgress
          ? <span className="tone-orange">The cleanup receipt could not be saved locally.</span> : null}
      </div>
      {task.websiteSessionCleanupAvailable || inProgress ? (
        <Button variant="outline" size="sm" disabled={!action} onClick={() => {
          const current = websiteSessionCleanupAction(task, blocked);
          if (current) post(current);
        }}>{inProgress ? 'Closing…' : 'Retry website cleanup'}</Button>
      ) : null}
    </section>
  );
}
