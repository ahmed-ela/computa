import { useEffect, useState } from 'octane';
import { resolvePromptReceipt, type PendingPromptSubmission } from './promptQueue';
import type { AppSnapshot } from './types';

const noReceipts: AppSnapshot['promptReceipts'] = [];

// Drafts and in-flight submission receipts belong to conversations, including closed tabs.
export function useConversationDrafts(receipts = noReceipts) {
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [pendingSubmissions, setPendingSubmissions] = useState<Record<string, PendingPromptSubmission>>({});
  const [submissionErrors, setSubmissionErrors] = useState<Record<string, string>>({});
  useEffect(() => {
    const resolved = Object.entries(pendingSubmissions).flatMap(([taskID, pending]) => {
      const matching = receipts.filter((receipt) => receipt.taskID === taskID);
      const result = resolvePromptReceipt(drafts[taskID] ?? '', pending, matching);
      return result ? [{ taskID, pending, result }] : [];
    });
    if (resolved.length === 0) return;

    setPendingSubmissions((current) => {
      const next = { ...current };
      for (const { taskID, pending } of resolved) {
        if (next[taskID]?.requestID === pending.requestID) delete next[taskID];
      }
      return next;
    });
    setDrafts((current) => {
      const next = { ...current };
      for (const { taskID, pending } of resolved) {
        const matching = receipts.filter((receipt) => receipt.taskID === taskID);
        const result = resolvePromptReceipt(current[taskID] ?? '', pending, matching);
        if (result) next[taskID] = result.draft;
      }
      return next;
    });
    setSubmissionErrors((current) => {
      const next = { ...current };
      for (const { taskID, result } of resolved) {
        if (result.error) next[taskID] = result.error;
        else delete next[taskID];
      }
      return next;
    });
  }, [receipts, pendingSubmissions]);

  return { drafts, setDrafts, pendingSubmissions, setPendingSubmissions, submissionErrors, setSubmissionErrors };
}
