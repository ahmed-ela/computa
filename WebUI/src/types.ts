export type Tone = 'neutral' | 'blue' | 'green' | 'orange' | 'red' | 'purple';
export type WebsiteModelProvider = 'chatgpt' | 'gemini' | 'claude' | 'groq' | 'grok' | 'kimi' | 'qwen' | 'deepseek';

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
  thinkingEffort?: string;
  modelSelectable: boolean;
  hasBoundThread?: boolean;
  branch?: string;
  entries: EntrySnapshot[];
  queuedPrompts: QueuedPromptSnapshot[];
  queuePaused: boolean;
  canStartQueuedTurn: boolean;
  canSteer: boolean;
  isBusy: boolean;
  hasUnreadCompletion: boolean;
  unreadCompletionID?: string;
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
  selectable?: boolean;
  thinkingEfforts?: string[];
  defaultThinkingEffort?: string;
}

export interface ModelProviderSetup {
  detail?: string | null;
  checkStatus?: 'checking' | 'installRequired' | 'signInRequired' | 'settingUp' | 'unavailable';
  route: string;
  name: string;
  connected: boolean;
}

export interface WorkspaceTab { kind: 'agent' | 'browser'; id: string }
export interface WorkspaceBrowser {
  id: string; title: string; host?: string; favicon?: string; isFaviconLoading?: boolean; pinIsTemporary?: boolean;
  canGoBack?: boolean; canGoForward?: boolean; canReload?: boolean; isLoading?: boolean;
}

export interface AgentProfile {
  name: string;
  instructions: string;
  history: {id: string; title: string}[];
}

export interface CodexCLIUsageWindow {
  usedPercent: number;
  windowDurationMins?: number;
  resetsAt?: number;
}

export interface CodexCLIUsageBucket {
  id: string;
  label?: string;
  primary?: CodexCLIUsageWindow;
  secondary?: CodexCLIUsageWindow;
}

export interface AppSnapshot {
  selectedAgentProfile?: AgentProfile;
  agentNames?: Record<string, string>;
  priorAgentConversationIDs?: string[];
  canStartFresh?: boolean;
  launcherChat?: { id: string; taskID: string; unsentDraft?: string };
  nativeSidebarControls?: boolean;
  revision: number;
  allowsBrowserSidePane?: boolean;
  mixesBrowserTabsInSidebar?: boolean;
  draftHandoff?: { id: string; drafts: Record<string, string> };
  sidebarDropTarget?: boolean;
  workspaceOrder?: WorkspaceTab[];
  workspacePinnedCount?: number;
  savedChats?: { id: string; title: string; workspace: string; updatedAt: number }[];
  savedChatSelection?: { id: string; error?: string };
  workspaceBrowsers?: WorkspaceBrowser[];
  primaryBrowserID?: string;
  canViewConversation?: boolean;
  titlebarHeight?: number;
  sidebarRail?: { width: number; iconCenter: number };
  trafficLightClearance?: number;
  selectedTaskID?: string;
  selectedEntryID?: string;
  newAgentDraft?: TaskSnapshot;
  tasks: TaskSnapshot[];
  promptReceipts: PromptReceiptSnapshot[];
  pendingApprovalCount: number;
  connection: ConnectionSnapshot;
  permissions: PermissionSnapshot;
  appearance: 'system' | 'light' | 'dark';
  browserAddressPlacement: 'titleBar' | 'sidebar';
  accessMode: 'askEveryTime' | 'fullAccess';
  defaultModel: string;
  defaultThinkingEffort?: string;
  modelOptions: ModelOption[];
  providerSetups: ModelProviderSetup[];
  websiteModelsRefreshing?: boolean;
  selectedModelAvailableForNewPrompt?: boolean;
  canRefreshWebsiteModels?: boolean;
  websiteModelsError?: string;
  codexCLIUsage?: CodexCLIUsageBucket[];
  codexCLIUsageRefreshing?: boolean;
  showToolPayloads: boolean;
  isInspectorPresented: boolean;
  isTaskSidebarCollapsed?: boolean;
  isTaskSidebarPeeked?: boolean;
  isBrowserPresented: boolean;
  isSettingsPresented: boolean;
  chromeProfileImportStatus?: string;
  importingChromeProfile?: boolean;
  isReviewPresented?: boolean;
  review?: ReviewState;
}

export type NativeAction =
  | {action: 'startFresh'; taskID: string}
  | {action: 'saveAgentSettings'; taskID: string; name: string; instructions: string}
  | {action: 'openAgentHistory'; taskID: string; conversationID: string}
  | { action: 'ready' }
  | { action: 'selectTask'; id: string }
  | { action: 'acknowledgeTaskCompletion'; taskID: string; completionID: string }
  | { action: 'selectEntry'; id: string }
  | { action: 'createTask' | 'newWorkspaceBrowserTab' | 'openTabLauncher' }
  | { action: 'openBrowserAddress'; id: string }
  | { action: 'browserNavigation'; id: string; command: 'back' | 'forward' | 'reload' | 'stop' }
  | { action: 'selectWorkspaceTab' | 'closeWorkspaceTab' | 'showWorkspaceTabMenu'; tab: WorkspaceTab }
  | { action: 'setWorkspaceTabPinned'; tab: WorkspaceTab; pinned: boolean }
  | { action: 'setComposerDraft'; taskID: string; text: string }
  | { action: 'beginWorkspaceTabDrag'; tab: WorkspaceTab }
  | { action: 'acknowledgeDraftHandoff'; id: string }
  | { action: 'moveWorkspaceTab'; tab: WorkspaceTab; target: WorkspaceTab }
  | { action: 'chooseTaskWorkspace'; taskID: string }
  | { action: 'prepareWebsiteModel'; taskID: string }
  | { action: 'refreshCodexCLIUsage'; taskID: string }
  | { action: 'launcherChatReady'; taskID: string; requestID: string }
  | { action: 'submitPrompt'; requestID: string; taskID: string; prompt: string }
  | { action: 'interruptTask'; taskID: string }
  | { action: 'retryWebsiteSessionCleanup'; taskID: string }
  | { action: 'beginQueueEdit'; taskID: string; id: string }
  | { action: 'setQueueEditDraft'; taskID: string; id: string; text: string }
  | { action: 'editQueuedPrompt'; taskID: string; id: string; prompt: string }
  | { action: 'cancelQueueEdit'; taskID: string; id: string }
  | { action: 'deleteQueuedPrompt'; taskID: string; id: string }
  | { action: 'moveQueuedPrompt'; taskID: string; id: string; beforeID: string | null }
  | { action: 'sendQueuedPrompt' | 'steerQueuedPrompt'; taskID: string; id: string }
  | { action: 'resumeQueue'; taskID: string }
  | { action: 'toggleInspector' }
  | { action: 'setTaskSidebarPeeked'; peeked: boolean }
  | { action: 'setTaskSidebarCollapsed'; collapsed: boolean }
  | { action: 'toggleBrowser' }
  | { action: 'toggleReview' }
  | { action: 'setReviewScope'; taskID: string; scope: ReviewScope }
  | { action: 'setReviewReference'; taskID: string; reference: string }
  | { action: 'refreshReview'; taskID: string }
  | { action: 'reviewMutation'; taskID: string; snapshotID: string; operation: ReviewOperation; fileID?: string; hunkID?: string }
  | { action: 'openReviewFile'; taskID: string; snapshotID: string; fileID: string }
  | { action: 'showSettings' }
  | { action: 'importChromeProfile' }
  | { action: 'dismissSettings' }
  | { action: 'setAppearance'; value: 'system' | 'light' | 'dark' }
  | { action: 'setBrowserAddressPlacement'; value: AppSnapshot['browserAddressPlacement'] }
  | { action: 'setDefaultModel'; modelID: string; thinkingEffort?: string }
  | { action: 'setTaskModel'; taskID: string; modelID: string; thinkingEffort?: string }
  | { action: 'refreshWebsiteModels'; provider?: WebsiteModelProvider }
  | { action: 'manageCLISetup'; route: string; operation: 'install' | 'signIn' | 'stopWaiting' }
  | { action: 'connectModelProvider'; route: string }
  | { action: 'showAccessModeSettings' }
  | { action: 'showAPIProviders' }
  | { action: 'setShowToolPayloads'; value: boolean }
  | { action: 'refreshPermissions' }
  | { action: 'requestAccessibilityPermission' }
  | { action: 'revealRunningApp' }
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
