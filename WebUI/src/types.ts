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
  tool?: ToolSnapshot;
}

export interface TaskSnapshot {
  id: string;
  title: string;
  summary: string;
  status: string;
  statusTone: Tone;
  updatedAt: number;
  workspace: string;
  model: string;
  modelSelectable: boolean;
  branch?: string;
  entries: EntrySnapshot[];
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
  pendingApprovalCount: number;
  connection: ConnectionSnapshot;
  permissions: PermissionSnapshot;
  appearance: 'system' | 'light' | 'dark';
  defaultModel: string;
  modelOptions: ModelOption[];
  showToolPayloads: boolean;
  isInspectorPresented: boolean;
  isSettingsPresented: boolean;
}

export type NativeAction =
  | { action: 'ready' }
  | { action: 'selectTask'; id: string }
  | { action: 'selectEntry'; id: string }
  | { action: 'createTask' }
  | { action: 'submitPrompt'; prompt: string }
  | { action: 'interruptTask'; taskID: string }
  | { action: 'toggleInspector' }
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
