import type { AppSnapshot, EntrySnapshot, NativeAction, ReviewScope, ReviewState, TaskSnapshot } from './types';
import { reorderQueuedPrompts } from './promptQueue';

const previewWorkspace = '/Users/preview/Projects/localcodex-demo';
const model27B = 'mlx-community/Qwen3.8-27B-4bit';
const model35B = 'lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit';
const model9B = 'lmstudio-community/Qwen3.5-9B-MLX-4bit';
const model4B = 'lmstudio-community/Qwen3.5-4B-MLX-4bit';

function previewReview(taskID: string, scope: ReviewScope = 'lastTurn', reference = '', revision = 1): ReviewState {
  const header = '@@ -1,3 +1,4 @@';
  return {
    taskID, scope, reference, loading: false,
    snapshot: {
      id: `preview-review-${taskID}-${scope}-${reference}-${revision}`, revision: `preview-${revision}`,
      workspace: previewWorkspace, scope, ...(scope === 'branch' || scope === 'commit' ? { reference } : {}),
      canStage: scope === 'unstaged', canUnstage: scope === 'staged', canRevert: scope === 'unstaged',
      files: [
        { id: 'preview-source', path: 'src/greeting.ts', status: 'modified', additions: 2, deletions: 1,
          binary: false, truncated: false, hunks: [{ id: 'preview-source-hunk', header, oldStart: 1, newStart: 1 }],
          diff: `diff --git a/src/greeting.ts b/src/greeting.ts\n--- a/src/greeting.ts\n+++ b/src/greeting.ts\n${header}\n export function greeting(name: string) {\n-  return 'Hello';\n+  const label = name.trim() || 'friend';\n+  return \`Hello, \${label}\`;\n }\n` },
        { id: 'preview-readme', path: 'README.md', status: 'added', additions: 2, deletions: 0,
          binary: false, truncated: false, hunks: [{ id: 'preview-readme-hunk', header: '@@ -0,0 +1,2 @@', oldStart: 0, newStart: 1 }],
          diff: 'diff --git a/README.md b/README.md\nnew file mode 100644\n--- /dev/null\n+++ b/README.md\n@@ -0,0 +1,2 @@\n+# Greeting fixture\n+Synthetic preview data only.\n' },
        { id: 'preview-binary', path: 'assets/sample.png', status: 'modified', additions: 0, deletions: 0,
          binary: true, truncated: false, hunks: [], diff: 'Binary files a/assets/sample.png and b/assets/sample.png differ\n' },
      ],
    },
  };
}

function makePreviewSnapshot(): AppSnapshot {
const now = Math.floor(Date.now() / 1000);

const longOutput = Array.from({ length: 48 }, (_, index) => {
  const number = String(index + 1).padStart(2, '0');
  return `${number}  Preview fixture row: inspect <panel-${number}> & preserve keyboard focus while long output scrolls.`;
}).join('\n');

const previewTasks: TaskSnapshot[] = [
  {
    id: 'preview-response-formatting', title: 'Response formatting checks',
    summary: 'Synthetic paragraphs, lists, code, tables, and inert HTML.',
    status: 'Completed', statusTone: 'green', updatedAt: now - 100,
    workspace: previewWorkspace, model: model4B, modelSelectable: true,
    queuedPrompts: [], queuePaused: false, canSteer: false, isBusy: false,
    entries: [{
      id: 'preview-formatted-answer', kind: 'assistant', title: 'Computa', timestamp: now - 100,
      workedForSeconds: 65,
      body: [
        '', '', '## A readable response', '',
        'Paragraphs should flow naturally, with **clear emphasis** and `inline code`.', '',
        '3. Keep the original model output.', '4. Format only its presentation.',
        '   - Preserve nested lists.', '   - Keep code indentation intact.', '',
        '```swift', 'func greet() {', '    print("Hello, Mac")', '',
        '    // Long lines should scroll inside this block, never stretch the app.',
        `    let longValue = "${'0123456789'.repeat(24)}"`, '}', '```', '',
        '> A short note should have its own breathing room.', '',
        '| Surface | Behavior |', '| --- | --- |', '| Native UI | Approval remains required |',
        '| Markdown | Text and structural formatting only |', '',
        '[Example link](https://example.com/) remains keyboard accessible.', '',
        '<script>alert("This must stay visible as literal text")</script>', '',
        '![No image request](https://example.com/no-network-load.png)', '',
      ].join('\n'),
    }],
  },
  {
    id: 'preview-completed-4b',
    title: 'Polish the local dashboard',
    summary: 'Review the app shell and make the task list easier to scan.',
    status: 'Completed',
    statusTone: 'green',
    updatedAt: now - 130,
    workspace: previewWorkspace,
    model: model4B,
    modelSelectable: true,
    queuedPrompts: [],
    queuePaused: false,
    canSteer: false,
    isBusy: false,
    branch: 'design/dashboard-pass',
    entries: [
      {
        id: 'preview-4b-user', kind: 'user', title: 'You',
        body: 'Review the local dashboard and suggest a clearer task layout.',
        timestamp: now - 500,
      },
      {
        id: 'preview-4b-reasoning', kind: 'reasoning', title: 'Looking through the interface',
        body: 'I will compare the navigation, task statuses, and the active conversation before suggesting changes.',
        timestamp: now - 460,
      },
      {
        id: 'preview-4b-tool', kind: 'tool', title: 'Inspect app shell',
        body: 'Read a synthetic interface snapshot for the preview.',
        timestamp: now - 420,
        tool: {
          name: 'preview.inspect',
          summary: 'Synthetic task-list and conversation observations',
          status: 'Succeeded', tone: 'green',
          input: '{"target":"local dashboard"}',
          output: 'Five example tasks; one selected conversation; inspector visible. Preview data only.',
          duration: 0.42,
        },
      },
      {
        id: 'preview-4b-assistant', kind: 'assistant', title: 'Computa',
        body: '\n\nLocal AI runs directly on your Mac instead of relying on a remote server. It can keep your data on the device and work offline.\n\nA practical setup combines a language model with carefully approved computer actions.\n\n- **Privacy:** Keep prompts and model inference local.\n- **Responsiveness:** Use a model that fits your available memory.\n- **Control:** Review clicks and typing before they happen.\n\nThis is synthetic preview content; no model or computer tool ran.\n\n',
        timestamp: now - 130,
        workedForSeconds: 370,
      },
    ],
  },
  {
    id: 'preview-empty',
    title: 'New task',
    summary: 'A clean draft with no conversation yet.',
    status: 'Draft',
    statusTone: 'neutral',
    updatedAt: now - 240,
    workspace: previewWorkspace,
    model: model9B,
    modelSelectable: true,
    queuedPrompts: [],
    queuePaused: false,
    canSteer: false,
    isBusy: false,
    entries: [],
  },
  {
    id: 'preview-running',
    title: 'Inspect a native window',
    summary: 'Observe the Calculator window and report what is visible.',
    status: 'Running',
    statusTone: 'blue',
    updatedAt: now - 28,
    activeTurnStartedAt: now - 95,
    workspace: previewWorkspace,
    model: model9B,
    modelSelectable: false,
    queuedPrompts: [
      { id: 'preview-queue-1', text: 'After that, list the visible Calculator controls.', status: 'queued' },
      { id: 'preview-queue-2', text: 'Then summarize the result in three concise bullets.', status: 'queued' },
    ],
    queuePaused: false,
    canSteer: true,
    isBusy: true,
    entries: [
      {
        id: 'preview-running-user', kind: 'user', title: 'You',
        body: 'Inspect Calculator, then tell me what is visible. Do not click.',
        timestamp: now - 95,
      },
      {
        id: 'preview-running-reasoning', kind: 'reasoning', title: 'Observing the window',
        body: 'Waiting for a read-only observation from the synthetic preview task.',
        timestamp: now - 50,
      },
      {
        id: 'preview-running-tool', kind: 'tool', title: 'Capture native window',
        body: 'A preview-only capture event is in progress.',
        timestamp: now - 28,
        tool: {
          name: 'preview.capture', summary: 'Synthetic window capture',
          status: 'Running', tone: 'blue', input: '{"bundle_id":"com.apple.calculator"}',
        },
      },
    ],
  },
  {
    id: 'preview-failure',
    title: 'Retry an unavailable model',
    summary: 'The selected local model was not ready for this example task.',
    status: 'Waiting',
    statusTone: 'orange',
    updatedAt: now - 850,
    workspace: previewWorkspace,
    model: model27B,
    modelSelectable: true,
    queuedPrompts: [{
      id: 'preview-queue-failed',
      text: 'Retry the workspace summary once the local model is available.',
      status: 'failed',
      error: 'The local model disconnected before this prompt could start.',
    }],
    queuePaused: true,
    canSteer: false,
    isBusy: false,
    entries: [
      {
        id: 'preview-failure-user', kind: 'user', title: 'You',
        body: 'Summarize the current workspace.',
        timestamp: now - 880,
      },
      {
        id: 'preview-failure-system', kind: 'system', title: 'Prompt was not delivered',
        body: 'Preview fixture: the local model was unavailable. No request was sent to LM Studio.',
        timestamp: now - 850,
      },
    ],
  },
  {
    id: 'preview-long-output',
    title: 'Review a long tool result',
    summary: 'Exercise transcript and inspector scrolling with a large output.',
    status: 'Completed',
    statusTone: 'green',
    updatedAt: now - 3_900,
    workspace: previewWorkspace,
    model: model4B,
    modelSelectable: true,
    queuedPrompts: [],
    queuePaused: false,
    canSteer: false,
    isBusy: false,
    entries: [
      {
        id: 'preview-long-user', kind: 'user', title: 'You',
        body: 'Show a long, scrollable example output so I can review the layout.',
        timestamp: now - 4_200,
      },
      {
        id: 'preview-long-tool', kind: 'tool', title: 'Read example output',
        body: 'A long synthetic output for layout testing.',
        timestamp: now - 4_000,
        tool: {
          name: 'preview.long_output', summary: '48 synthetic rows',
          status: 'Succeeded', tone: 'green', input: '{"source":"preview fixture"}',
          output: longOutput, duration: 0.81,
        },
      },
      {
        id: 'preview-long-assistant', kind: 'assistant', title: 'Computa',
        body: 'The output above is intentionally long and contains literal angle brackets. This preview did not read files or run tools.',
        timestamp: now - 3_900,
        workedForSeconds: 300,
      },
    ],
  },
];

return {
  revision: 1,
  selectedTaskID: 'preview-running',
  selectedEntryID: 'preview-running-tool',
  tasks: previewTasks,
  promptReceipts: [],
  pendingApprovalCount: 0,
  connection: { state: 'disconnected', label: 'Preview only · no runtime connected', tone: 'neutral' },
  permissions: { accessibility: 'Not granted', screenRecording: 'Not granted' },
  appearance: 'system',
  accessMode: 'askEveryTime',
  defaultModel: model27B,
  modelOptions: [
    { id: model27B, label: 'Qwen3.8-27B · MLX 4-bit', detail: '16.1 GB model file. Current validated Computa model.', highMemory: false },
    { id: model35B, label: 'Qwen3.6-35B-A3B · MLX 4-bit', detail: '20.4 GB model file. Very tight on this 24 GB Mac; download and load in LM Studio separately.', highMemory: true },
    { id: model9B, label: 'Qwen3.5-9B · MLX 4-bit', detail: '5.98 GB model files. Lower-memory option; download and load in LM Studio separately.', highMemory: false },
    { id: model4B, label: 'Qwen3.5-4B · MLX 4-bit', detail: '3.06 GB model files. Smallest option; download and load in LM Studio separately.', highMemory: false },
  ],
  showToolPayloads: false,
  isInspectorPresented: false,
  isBrowserPresented: false,
  isSettingsPresented: false,
  isReviewPresented: false,
  review: previewReview('preview-running'),
};
}

export const previewSnapshot: AppSnapshot | null = import.meta.env.DEV
  ? makePreviewSnapshot()
  : null;

/** Browser-only simulation. It never installs a WebKit handler or invokes a runtime. */
export function installPreviewBridge(receive: (snapshot: AppSnapshot) => void): () => void {
  if (!import.meta.env.DEV || !previewSnapshot || window.webkit?.messageHandlers?.localCodex) {
    return () => {};
  }

  let snapshot = previewSnapshot;
  let nextID = 0;
  const issueID = () => `preview-action-${++nextID}`;
  const publish = (next: AppSnapshot) => {
    snapshot = { ...next, revision: snapshot.revision + 1 };
    receive(snapshot);
  };
  const selectedTask = () => snapshot.tasks.find((task) => task.id === snapshot.selectedTaskID);
  const updateTask = (id: string, transform: (task: TaskSnapshot) => TaskSnapshot) => {
    publish({
      ...snapshot,
      tasks: snapshot.tasks.map((task) => task.id === id ? transform(task) : task),
    });
  };

  const onAction = (event: Event) => {
    if (!(event instanceof CustomEvent)) return;
    const action = event.detail as NativeAction | undefined;
    if (!action || typeof action.action !== 'string') return;

    switch (action.action) {
      case 'ready':
      case 'refreshPermissions':
      case 'requestAccessibilityPermission':
      case 'requestScreenRecordingPermission':
        // A browser preview must never request macOS permissions.
        return;

      case 'selectTask': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.id);
        if (!task) return;
        publish({
          ...snapshot,
          selectedTaskID: task.id,
          selectedEntryID: task.entries.at(-1)?.id,
          review: previewReview(task.id, snapshot.review?.scope, snapshot.review?.reference, snapshot.revision + 1),
        });
        return;
      }

      case 'selectEntry': {
        if (!selectedTask()?.entries.some((entry) => entry.id === action.id)) return;
        publish({ ...snapshot, selectedEntryID: action.id });
        return;
      }

      case 'createTask': {
        const task: TaskSnapshot = {
          id: issueID(), title: 'New preview task',
          summary: 'Draft task in the browser preview.', status: 'Draft', statusTone: 'neutral',
          updatedAt: Math.floor(Date.now() / 1000), workspace: previewWorkspace,
          model: snapshot.defaultModel, modelSelectable: true, entries: [],
          queuedPrompts: [], queuePaused: false, canSteer: false, isBusy: false,
        };
        publish({ ...snapshot, tasks: [task, ...snapshot.tasks], selectedTaskID: task.id, selectedEntryID: undefined });
        return;
      }

      case 'chooseTaskWorkspace': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        if (!task || task.status !== 'Draft' || task.entries.length || task.isBusy) return;
        updateTask(task.id, (candidate) => ({ ...candidate, workspace: previewWorkspace }));
        return;
      }

      case 'submitPrompt': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        const prompt = action.prompt.trim();
        const accepted = Boolean(
          task
          && (task.modelSelectable || task.isBusy || task.queuePaused || task.queuedPrompts.length > 0)
          && prompt
          && new TextEncoder().encode(prompt).length <= 200_000,
        );
        const promptReceipts = [
          ...snapshot.promptReceipts,
          { id: action.requestID, taskID: action.taskID, accepted },
        ].slice(-64);
        if (!task || !accepted) {
          publish({ ...snapshot, promptReceipts });
          return;
        }
        const timestamp = Math.floor(Date.now() / 1000);
        if (task.isBusy || task.queuePaused || task.queuedPrompts.length > 0) {
          const queuedPrompt = { id: issueID(), text: prompt, status: 'queued' as const };
          publish({
            ...snapshot,
            promptReceipts,
            tasks: snapshot.tasks.map((candidate) => candidate.id === task.id ? {
              ...candidate,
              summary: prompt,
              updatedAt: timestamp,
              queuedPrompts: [...candidate.queuedPrompts, queuedPrompt],
            } : candidate),
          });
          return;
        }
        const userEntry: EntrySnapshot = {
          id: issueID(), kind: 'user', title: 'You', body: prompt, timestamp,
        };
        const assistantEntry: EntrySnapshot = {
          id: issueID(), kind: 'assistant', title: 'Preview response',
          body: 'Preview only — no model, external tool, browser, or native computer action ran. Your prompt was displayed locally to test the interface.',
          timestamp: timestamp + 1,
          workedForSeconds: 1,
        };
        publish({
          ...snapshot,
          promptReceipts,
          selectedEntryID: assistantEntry.id,
          tasks: snapshot.tasks.map((candidate) => candidate.id === task.id ? {
            ...candidate,
            title: candidate.entries.length === 0 ? prompt.slice(0, 64) : candidate.title,
            summary: prompt,
            status: 'Completed', statusTone: 'green', updatedAt: timestamp,
            entries: [...candidate.entries, userEntry, assistantEntry],
          } : candidate),
        });
        return;
      }

      case 'beginQueueEdit': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        const queued = task?.queuedPrompts.find((item) => item.id === action.id);
        if (!task || !queued || queued.status === 'sending') return;
        updateTask(task.id, (candidate) => ({
          ...candidate,
          queuedPrompts: candidate.queuedPrompts.map((item) => item.id === action.id ? { ...item, status: 'editing' } : item),
        }));
        return;
      }

      case 'editQueuedPrompt': {
        const prompt = action.prompt.trim();
        if (!prompt || new TextEncoder().encode(prompt).length > 200_000) return;
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        if (!task?.queuedPrompts.some((item) => item.id === action.id && item.status === 'editing')) return;
        updateTask(task.id, (candidate) => ({
          ...candidate,
          queuedPrompts: candidate.queuedPrompts.map((item) => item.id === action.id ? {
            ...item, text: prompt, status: 'queued', error: undefined,
          } : item),
        }));
        return;
      }

      case 'cancelQueueEdit': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        if (!task?.queuedPrompts.some((item) => item.id === action.id && item.status === 'editing')) return;
        updateTask(task.id, (candidate) => ({
          ...candidate,
          queuedPrompts: candidate.queuedPrompts.map((item) => item.id === action.id ? { ...item, status: 'queued' } : item),
        }));
        return;
      }

      case 'deleteQueuedPrompt': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        const queued = task?.queuedPrompts.find((item) => item.id === action.id);
        if (!task || !queued || queued.status === 'sending') return;
        updateTask(task.id, (candidate) => ({
          ...candidate,
          queuedPrompts: candidate.queuedPrompts.filter((item) => item.id !== action.id),
        }));
        return;
      }

      case 'moveQueuedPrompt': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        const queued = task?.queuedPrompts.find((item) => item.id === action.id);
        if (!task || !queued || queued.status === 'sending') return;
        updateTask(task.id, (candidate) => ({
          ...candidate,
          queuedPrompts: reorderQueuedPrompts(candidate.queuedPrompts, action.id, action.beforeID),
        }));
        return;
      }

      case 'steerQueuedPrompt': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        const queued = task?.queuedPrompts.find((item) => item.id === action.id);
        if (!task?.canSteer || !queued || queued.status !== 'queued') return;
        const timestamp = Math.floor(Date.now() / 1000);
        const entry: EntrySnapshot = {
          id: issueID(), kind: 'user', title: 'You · steered', body: queued.text, timestamp,
        };
        publish({
          ...snapshot,
          selectedEntryID: snapshot.selectedTaskID === task.id ? entry.id : snapshot.selectedEntryID,
          tasks: snapshot.tasks.map((candidate) => candidate.id === task.id ? {
            ...candidate,
            summary: queued.text,
            updatedAt: timestamp,
            entries: [...candidate.entries, entry],
            queuedPrompts: candidate.queuedPrompts.filter((item) => item.id !== action.id),
          } : candidate),
        });
        return;
      }

      case 'resumeQueue': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        if (!task?.queuePaused) return;
        updateTask(task.id, (candidate) => ({
          ...candidate,
          queuePaused: false,
          queuedPrompts: candidate.queuedPrompts.map((item) => item.status === 'failed' ? {
            ...item, status: 'queued', error: undefined,
          } : item),
        }));
        return;
      }

      case 'interruptTask': {
        const task = snapshot.tasks.find((candidate) => candidate.id === action.taskID);
        if (!task || task.status !== 'Running') return;
        const timestamp = Math.floor(Date.now() / 1000);
        const entry: EntrySnapshot = {
          id: issueID(), kind: 'system', title: 'Preview task stopped',
          body: 'This was a browser-only simulation; no runtime turn was interrupted.', timestamp,
        };
        publish({
          ...snapshot,
          selectedEntryID: snapshot.selectedTaskID === task.id ? entry.id : snapshot.selectedEntryID,
          tasks: snapshot.tasks.map((candidate) => candidate.id === task.id ? {
            ...candidate, status: 'Waiting', statusTone: 'orange', modelSelectable: true,
            updatedAt: timestamp, entries: [...candidate.entries, entry],
            queuePaused: true, canSteer: false, isBusy: false,
          } : candidate),
        });
        return;
      }

      case 'toggleInspector':
        publish({ ...snapshot, isInspectorPresented: !snapshot.isInspectorPresented });
        return;
      case 'toggleReview': {
        const task = selectedTask();
        if (!task) return;
        publish({ ...snapshot, isReviewPresented: !snapshot.isReviewPresented,
          review: snapshot.review?.taskID === task.id ? snapshot.review : previewReview(task.id) });
        return;
      }
      case 'setReviewScope':
        publish({ ...snapshot, review: previewReview(action.taskID, action.scope, snapshot.review?.reference, snapshot.revision + 1) });
        return;
      case 'setReviewReference':
        publish({ ...snapshot, review: previewReview(action.taskID, snapshot.review?.scope, action.reference, snapshot.revision + 1) });
        return;
      case 'refreshReview':
        publish({ ...snapshot, review: previewReview(action.taskID, snapshot.review?.scope, snapshot.review?.reference, snapshot.revision + 1) });
        return;
      case 'reviewMutation':
      case 'openReviewFile':
        if (!snapshot.review || snapshot.review.snapshot?.id !== action.snapshotID) return;
        publish({ ...snapshot, review: { ...snapshot.review, error: 'Preview only. No files or Git index were changed, and no external editor was opened.' } });
        return;
      case 'toggleBrowser':
        // The actual browser is a native sibling, not an iframe in this preview.
        publish({ ...snapshot, isBrowserPresented: !snapshot.isBrowserPresented });
        return;
      case 'showSettings':
        publish({ ...snapshot, isSettingsPresented: true });
        return;
      case 'dismissSettings':
        publish({ ...snapshot, isSettingsPresented: false });
        return;
      case 'setAppearance':
        publish({ ...snapshot, appearance: action.value });
        return;
      case 'setDefaultModel':
        if (!snapshot.modelOptions.some((option) => option.id === action.modelID)) return;
        publish({ ...snapshot, defaultModel: action.modelID });
        return;
      case 'prepareWebsiteModel':
        // Preview never opens a website or submits a prompt.
        return;
      case 'setTaskModel':
        if (!snapshot.modelOptions.some((option) => option.id === action.modelID)) return;
        if (!snapshot.tasks.some((task) => task.id === action.taskID && task.modelSelectable)) return;
        updateTask(action.taskID, (task) => ({ ...task, model: action.modelID }));
        return;
      case 'setShowToolPayloads':
        publish({ ...snapshot, showToolPayloads: action.value });
        return;
      case 'refreshWebsiteModels':
        // Preview has no signed-in browser. Never invent provider availability.
        publish({ ...snapshot, websiteModelsRefreshing: false, websiteModelsError: 'Website discovery is available in the desktop app.' });
        return;
      case 'showAPIProviders':
        return; // Credentials are entered only in the desktop's native sheet.
    }
  };

  window.addEventListener('localcodex-preview-action', onAction);
  receive(snapshot);
  return () => window.removeEventListener('localcodex-preview-action', onAction);
}
