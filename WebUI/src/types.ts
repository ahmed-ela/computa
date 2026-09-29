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
}

export type QueuedPromptStatus = 'queued' | 'editing' | 'sending' | 'failed';

export interface QueuedPromptSnapshot {
  id: string;
  text: string;
  status: QueuedPromptStatus;
  error?: string;
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
}

export interface ModelOption {
  id: string;
  label: string;
  detail: string;
  highMemory: boolean;
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
  showToolPayloads: boolean;
  isInspectorPresented: boolean;
  isBrowserPresented: boolean;
  isSettingsPresented: boolean;
}

export type NativeAction =
  | { action: 'ready' }
  | { action: 'selectTask'; id: string }
  | { action: 'selectEntry'; id: string }
  | { action: 'createTask' }
  | { action: 'submitPrompt'; requestID: string; taskID: string; prompt: string }
  | { action: 'interruptTask'; taskID: string }
  | { action: 'beginQueueEdit'; taskID: string; id: string }
  | { action: 'editQueuedPrompt'; taskID: string; id: string; prompt: string }
  | { action: 'cancelQueueEdit'; taskID: string; id: string }
  | { action: 'deleteQueuedPrompt'; taskID: string; id: string }
  | { action: 'moveQueuedPrompt'; taskID: string; id: string; beforeID: string | null }
  | { action: 'steerQueuedPrompt'; taskID: string; id: string }
  | { action: 'resumeQueue'; taskID: string }
  | { action: 'toggleInspector' }
  | { action: 'toggleBrowser' }
  | { action: 'showSettings' }
  | { action: 'dismissSettings' }
  | { action: 'setAppearance'; value: 'system' | 'light' | 'dark' }
  | { action: 'setDefaultModel'; modelID: string }
  | { action: 'setTaskModel'; taskID: string; modelID: string }
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
