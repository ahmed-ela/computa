export type Tone = 'neutral' | 'blue' | 'green' | 'orange' | 'red' | 'purple';

export interface ConnectionSnapshot {
  state: 'disconnected' | 'connecting' | 'connected' | 'failed';
  label: string;
  tone: Tone;
}

export type PermissionStatus = 'Granted' | 'Not granted';

export interface PermissionSnapshot {
  accessibility: PermissionStatus;
  screenRecording: PermissionStatus;
}

export interface ToolSnapshot {
  name: string;
  summary: string;
  status: string;
  tone: Tone;
  input: string;
  output?: string;
  duration?: number;
}

export interface EntrySnapshot {
  id: string;
  kind: 'user' | 'assistant' | 'reasoning' | 'tool' | 'system';
  title: string;
  body: string;
  timestamp: number;
  workedForSeconds?: number;
  isStreaming?: boolean;
  activityGroupID?: string;
  assistantPhase?: 'commentary' | 'final_answer';
  tool?: ToolSnapshot;
  turnID?: string;
  fileChanges?: AgentFileChange[];
}

export interface AgentFileChange {
  path: string;
  kind: 'add' | 'delete' | 'update';
  movePath?: string;
  diff: string;
}

export type ReviewScope = 'lastTurn' | 'unstaged' | 'staged' | 'branch' | 'commit';
export type ReviewOperation = 'stage' | 'unstage' | 'revert';

export interface ReviewHunk {
  id: string;
  header: string;
  oldStart?: number;
  newStart?: number;
}

export interface ReviewFile {
  id: string;
  path: string;
  previousPath?: string;
  status: 'added' | 'deleted' | 'modified' | 'renamed' | 'copied' | 'untracked' | 'typeChanged' | 'unmerged';
  diff: string;
  additions: number;
  deletions: number;
  binary: boolean;
  truncated: boolean;
  hunks: ReviewHunk[];
}

export interface FileReviewSnapshot {
  id: string;
  workspace: string;
  scope: ReviewScope;
  reference?: string;
  revision: string;
  files: ReviewFile[];
  canStage: boolean;
  canUnstage: boolean;
  canRevert: boolean;
}

export interface ReviewState {
  taskID: string;
  scope: ReviewScope;
  reference: string;
  loading: boolean;
  error?: string;
  snapshot?: FileReviewSnapshot;
}

export type QueuedPromptStatus = 'queued' | 'editing' | 'sending' | 'failed';

export interface QueuedPromptSnapshot {
  id: string;
  text: string;
  status: QueuedPromptStatus;
  error?: string;
  deliveryUncertain?: boolean;
}

export interface PromptReceiptSnapshot {
  id: string;
  taskID: string;
  accepted: boolean;
}

export interface TaskSnapshot {
  id: string;
  title: string;
  summary: string;
  status: string;
  statusTone: Tone;
  updatedAt: number;
  activeTurnStartedAt?: number;
  activeActivityGroupID?: string;
  workspace: string;
  model: string;
  modelSelectable: boolean;
  branch?: string;
  entries: EntrySnapshot[];
  queuedPrompts: QueuedPromptSnapshot[];
  queuePaused: boolean;
  canSteer: boolean;
  isBusy: boolean;
  websiteSessionCleanupAvailable?: boolean;
  websiteSessionCleanupInProgress?: boolean;
  websiteSessionCleanupOutcome?: 'closed' | 'no_owned_session' | 'unconfirmed';
  websiteSessionCleanupReceiptSaved?: boolean;
}

export interface ModelOption {
  id: string;
  label: string;
  detail: string;
  highMemory: boolean;
  available?: boolean;
}

export interface AppSnapshot {
  revision: number;
  selectedTaskID?: string;
  selectedEntryID?: string;
  tasks: TaskSnapshot[];
  promptReceipts: PromptReceiptSnapshot[];
  pendingApprovalCount: number;
  connection: ConnectionSnapshot;
  permissions: PermissionSnapshot;
  appearance: 'system' | 'light' | 'dark';
  accessMode: 'askEveryTime' | 'fullAccess';
  defaultModel: string;
  modelOptions: ModelOption[];
  websiteModelsRefreshing?: boolean;
  websiteModelsError?: string;
  showToolPayloads: boolean;
  isInspectorPresented: boolean;
  isBrowserPresented: boolean;
  isSettingsPresented: boolean;
  isReviewPresented?: boolean;
  review?: ReviewState;
}

export type NativeAction =
  | { action: 'ready' }
  | { action: 'selectTask'; id: string }
  | { action: 'selectEntry'; id: string }
  | { action: 'createTask' }
  | { action: 'chooseTaskWorkspace'; taskID: string }
  | { action: 'submitPrompt'; requestID: string; taskID: string; prompt: string }
  | { action: 'interruptTask'; taskID: string }
  | { action: 'retryWebsiteSessionCleanup'; taskID: string }
  | { action: 'beginQueueEdit'; taskID: string; id: string }
  | { action: 'editQueuedPrompt'; taskID: string; id: string; prompt: string }
  | { action: 'cancelQueueEdit'; taskID: string; id: string }
  | { action: 'deleteQueuedPrompt'; taskID: string; id: string }
  | { action: 'moveQueuedPrompt'; taskID: string; id: string; beforeID: string | null }
  | { action: 'steerQueuedPrompt'; taskID: string; id: string }
  | { action: 'resumeQueue'; taskID: string }
  | { action: 'toggleInspector' }
  | { action: 'toggleBrowser' }
  | { action: 'toggleReview' }
  | { action: 'setReviewScope'; taskID: string; scope: ReviewScope }
  | { action: 'setReviewReference'; taskID: string; reference: string }
  | { action: 'refreshReview'; taskID: string }
  | { action: 'reviewMutation'; taskID: string; snapshotID: string; operation: ReviewOperation; fileID?: string; hunkID?: string }
  | { action: 'openReviewFile'; taskID: string; snapshotID: string; fileID: string }
  | { action: 'showSettings' }
  | { action: 'dismissSettings' }
  | { action: 'setAppearance'; value: 'system' | 'light' | 'dark' }
  | { action: 'setDefaultModel'; modelID: string }
  | { action: 'setTaskModel'; taskID: string; modelID: string }
  | { action: 'refreshWebsiteModels' }
  | { action: 'showAPIProviders' }
  | { action: 'setShowToolPayloads'; value: boolean }
  | { action: 'refreshPermissions' }
  | { action: 'requestAccessibilityPermission' }
  | { action: 'requestScreenRecordingPermission' };

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        localCodex?: {
          postMessage(message: NativeAction): void;
        };
      };
    };
    __localCodexReceiveState?: (snapshot: AppSnapshot) => void;
  }
}
