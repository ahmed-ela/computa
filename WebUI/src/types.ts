export type Tone = 'neutral' | 'blue' | 'green' | 'orange' | 'red' | 'purple';

export interface ConnectionSnapshot {
  state: 'disconnected' | 'connecting' | 'connected' | 'failed';
  label: string;
  tone: Tone;
}

export interface PermissionSnapshot {
  accessibility: string;
  screenRecording: string;
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
  branch?: string;
  entries: EntrySnapshot[];
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
  | { action: 'toggleInspector' }
  | { action: 'showSettings' }
  | { action: 'dismissSettings' }
  | { action: 'setAppearance'; value: 'system' | 'light' | 'dark' }
  | { action: 'setShowToolPayloads'; value: boolean }
  | { action: 'refreshPermissions' };

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
