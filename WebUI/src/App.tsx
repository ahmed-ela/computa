import { useEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Textarea } from '@octanejs/shadcn/Textarea';
import { NativeSelect, NativeSelectOption } from '@octanejs/shadcn/NativeSelect';
import { Switch } from '@octanejs/shadcn/Switch';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@octanejs/shadcn/DropdownMenu';
import { Icon } from './Icon';
import { AgentMenu } from './AgentMenu';
import { useConversationDrafts } from './conversationDrafts';
import { WorkspaceSidebar, sidebarIsCompact } from './WorkspaceSidebar';
import { copyText } from './clipboard';
import { ReviewPanel } from './ReviewPanel';
import { ModelLabel, ModelSelector } from './ModelSelector';
import { WebsiteSessionCleanupControl } from './WebsiteSessionCleanupControl';
import { fileChangeSummary } from './reviewDiff';
import { ResponseMarkdown } from './ResponseMarkdown';
import { ActivityDisclosure, activityLabel } from './ActivityDisclosure';
import { activityTimeline, systemMessageText, type ActivityGroup, type ConversationEntry } from './activityTimeline';
import { formatWorkedFor } from './duration';
import { observeDisplayedCompletion } from './completionAcknowledgment';
import { previewSnapshot, installPreviewBridge } from './preview';
import {
  composerPrimaryAction,
  dropQueuedPrompt,
  isValidPrompt,
  moveQueuedPrompt,
  shouldSubmitPromptKey,
} from './promptQueue';
import type {
  AppSnapshot,
  EntrySnapshot,
  NativeAction,
  QueuedPromptSnapshot,
  TaskSnapshot,
  Tone,
} from './types';

// Keep both project-folder entry points available for a future UI revision.
const showProjectFolderPicker = false;

function post(action: NativeAction) {
  const bridge = window.webkit?.messageHandlers?.localCodex;
  if (bridge) bridge.postMessage(action);
  else if (import.meta.env.DEV) window.dispatchEvent(new CustomEvent('localcodex-preview-action', { detail: action }));
}

function toneClass(tone: Tone) {
  return `tone-${tone}`;
}

function relativeTime(timestamp: number) {
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - timestamp));
  if (seconds < 15) return 'now';
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return days < 7
    ? `${days}d`
    : new Date(timestamp * 1000).toLocaleDateString(undefined, {
        month: 'short',
        day: 'numeric',
      });
}

function clockTime(timestamp: number) {
  return new Date(timestamp * 1000).toLocaleTimeString(undefined, {
    hour: 'numeric',
    minute: '2-digit',
  });
}

const toolNames: Record<string, string> = {
  commandExecution: 'Command',
  fileChange: 'File edits', apply_patch: 'Edit files',
  computer_v2_status: 'Check permissions', computer_v2_apps: 'Find applications',
  computer_v2_open: 'Open application', computer_v2_snapshot: 'Inspect interface',
  computer_v2_capture: 'Capture window', computer_v2_ground_click: 'Locate and click',
  computer_v2_ax: 'Interact with interface', computer_v2_set_text: 'Enter text',
  computer_v2_click: 'Click target', computer_v2_pointer: 'Move pointer',
  computer_v2_keypress: 'Press keys', computer_v2_type: 'Type text',
};

function TaskToolbar({ task, snapshot, allowFresh, rowHeight, onNewChat }: { snapshot: AppSnapshot; allowFresh: boolean; task?: TaskSnapshot; rowHeight?: number; onNewChat?: () => void }) {
  return (
    <header className="task-toolbar" style={rowHeight ? { height: `${rowHeight}px` } : undefined}>
      <div className="toolbar-title-block">
        {task ? <strong>{snapshot.agentNames?.[task.id] || (task.title === 'Untitled task' ? 'New agent' : task.title)}</strong> : null}
        {task?.workspace && task.workspace !== 'No workspace selected' ? <span className="toolbar-workspace" title={task.workspace}>{task.workspace.split('/').filter(Boolean).at(-1) ?? task.workspace}</span> : null}
      </div>
      <div className="toolbar-actions">
        {showProjectFolderPicker && task?.status === 'Draft' && task.entries.length === 0 && !task.isBusy ? <Button variant="ghost" size="sm" onClick={() => post({ action: 'chooseTaskWorkspace', taskID: task.id })}>Choose folder</Button> : null}
        {/* Temporarily hide the Changes and inspector buttons.
        {task ? <Button variant="ghost" size="sm" className={`review-toolbar-button ${snapshot.isReviewPresented ? 'active' : ''}`}
          aria-label="Toggle changes" aria-pressed={Boolean(snapshot.isReviewPresented)} onClick={() => post({ action: 'toggleReview' })}>
          <Icon name="edit" size={15} /> Changes
        </Button> : null}
        <Button variant="ghost" size="icon"
          className={`icon-button ${snapshot.isInspectorPresented ? 'active' : ''}`}
          aria-label="Toggle inspector"
          aria-pressed={snapshot.isInspectorPresented}
          title="Toggle inspector"
          onClick={() => post({ action: 'toggleInspector' })}
        >
          <Icon name="info" size={18} />
        </Button>
        */}
        {task && <AgentMenu key={task.id} taskID={task.id} name={task.title} profile={snapshot.selectedAgentProfile}
          canStartFresh={Boolean(snapshot.canStartFresh && allowFresh)} post={post} />}
        {onNewChat && <Button variant="ghost" size="icon-xs" aria-label="New agent" title="New agent (⇧⌘N)" onClick={onNewChat}>
          <Icon name="compose" size={16} />
        </Button>}
      </div>
    </header>
  );
}

function ToolDetails({ entry, showPayload }: { entry: EntrySnapshot; showPayload: boolean }) {
  const tool = entry.tool;
  if (!tool) return null;

  return (
    <details className="tool-card" open={tool.status === 'Needs approval'}>
      <summary>
        <span className={`tool-icon ${toneClass(tool.tone)}`}><Icon name={tool.status === 'Succeeded' ? 'check' : tool.status === 'Failed' ? 'info' : 'computer'} size={15} /></span>
        <span className="tool-labels"><span className="tool-title">{toolNames[tool.name] ?? tool.name}</span><span className="tool-summary">{tool.summary}</span></span>
        {tool.duration != null ? <span className="tool-duration">{tool.duration < 1 ? `${Math.round(tool.duration * 1000)} ms` : `${tool.duration.toFixed(1)} s`}</span> : null}
        <span className={`tool-status ${toneClass(tool.tone)}`}>{tool.status}</span>
        <Icon name="chevron" size={14} />
      </summary>
      <div className="tool-expanded-summary"><span>{tool.name}</span><p>{tool.summary}</p></div>
      {entry.fileChanges?.length ? <div className="inline-file-changes">
        {entry.fileChanges.map((change, index) => {
          const summary = fileChangeSummary(change);
          return <div className="inline-file-change" key={`${change.path}:${index}`}>
            <span className="mono" title={change.path}>{change.movePath ? `${change.path} → ${change.movePath}` : change.path}</span>
            <span>{summary.label}</span>
            {summary.partial ? <span>Partial diff</span> : <><span className="diff-additions">+{summary.additions}</span><span className="diff-deletions">−{summary.deletions}</span></>}
          </div>;
        })}
        <Button variant="outline" size="sm" onClick={() => post({ action: 'toggleReview' })}>Review changes</Button>
      </div> : null}
      {showPayload || tool.name === 'commandExecution' ? (
        <div className="tool-payload">
          <div><span>Input</span><pre>{tool.input}</pre></div>
          {tool.output ? <div><span>Output</span><pre>{tool.output}</pre></div> : null}
        </div>
      ) : null}
    </details>
  );
}

function MessageActions({ timestamp, label, copy }: { timestamp: number; label: string; copy: () => Promise<void> }) {
  const [feedback, setFeedback] = useState<'' | 'Copied' | 'Copy failed'>('');
  useEffect(() => {
    if (!feedback) return;
    const timer = window.setTimeout(() => setFeedback(''), 2200);
    return () => window.clearTimeout(timer);
  }, [feedback]);

  async function copyMessage(event: MouseEvent) {
    event.stopPropagation();
    try {
      await copy();
      setFeedback('Copied');
    } catch {
      setFeedback('Copy failed');
    }
  }

  return <div className="message-actions">
    <time className="message-time" dateTime={new Date(timestamp * 1000).toISOString()}>{clockTime(timestamp)}</time>
    <Button type="button" variant="ghost" size="icon-xs" className="message-copy"
      aria-label={label} title={label} onClick={copyMessage}>
      <Icon name={feedback === 'Copied' ? 'check' : 'copy'} size={14} />
    </Button>
    <span className={feedback === 'Copy failed' ? 'message-time' : 'sr-only'} role="status">{feedback}</span>
  </div>;
}

function UserMessage({ entry, selected }: { entry: EntrySnapshot; selected: boolean }) {
  return (
    <article className={`message-row user-message ${selected ? 'selected' : ''}`}>
      <Button variant="secondary" className="user-bubble"
        onClick={() => post({ action: 'selectEntry', id: entry.id })}
        aria-label={`You: ${entry.body}`}>
        {entry.body}
      </Button>
      <MessageActions timestamp={entry.timestamp} label="Copy message" copy={() => copyText(entry.body)} />
    </article>
  );
}

function TimelineEntry({
  entry,
  selected,
  hideAnswerDuration = false,
}: {
  entry: ConversationEntry;
  selected: boolean;
  hideAnswerDuration?: boolean;
}) {
  const response = useRef<HTMLDivElement | null>(null);
  if (entry.kind === 'assistant' && !entry.body.trim()) return null;
  if (entry.kind === 'user') return <UserMessage entry={entry} selected={selected} />;

  if (entry.kind === 'system') {
    return (
      <article
        className={`message-row system-message ${selected ? 'selected' : ''}`}
        onClick={() => post({ action: 'selectEntry', id: entry.id })}
      >
        <Icon name="info" size={16} />
        <div><strong>{entry.title}</strong><p>{systemMessageText(entry)}</p></div>
      </article>
    );
  }

  return (
    <article
      className={`message-row assistant-message ${selected ? 'selected' : ''}`}
      onClick={() => post({ action: 'selectEntry', id: entry.id })}
      tabIndex={0}
      onKeyDown={(event) => { if (event.target === event.currentTarget && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); post({ action: 'selectEntry', id: entry.id }); } }}
      aria-label="Assistant response"
    >
      {!hideAnswerDuration && entry.workedForSeconds != null && Number.isFinite(entry.workedForSeconds) && entry.workedForSeconds >= 0
        ? <div className="assistant-metadata">Worked for {formatWorkedFor(entry.workedForSeconds)}</div> : null}
      <ResponseMarkdown text={entry.body} contentRef={response} />
      <MessageActions timestamp={entry.timestamp} label="Copy response" copy={async () => {
        if (!response.current) throw new Error('Response is unavailable');
        await copyText(entry.body, response.current.innerHTML);
      }} />
    </article>
  );
}

interface QueueEditDraft {
  id: string;
  text: string;
}

function queueStatusLabel(item: QueuedPromptSnapshot) {
  if (item.status === 'sending') return 'Sending';
  if (item.status === 'editing') return 'Editing';
  if (item.status === 'failed') return 'Needs attention';
  return 'Queued';
}

function PromptQueue({ task }: { task: TaskSnapshot }) {
  const [editDrafts, setEditDrafts] = useState<Record<string, QueueEditDraft>>({});
  const [draggedID, setDraggedID] = useState<string | null>(null);
  const nativeEditingItem = task.queuedPrompts.find((item) => item.status === 'editing');
  const editDraft = editDrafts[task.id]
    ?? (nativeEditingItem ? { id: nativeEditingItem.id, text: nativeEditingItem.text } : undefined);

  const setTaskEdit = (draft?: QueueEditDraft) => {
    setEditDrafts((current) => {
      const next = { ...current };
      if (draft) next[task.id] = draft;
      else delete next[task.id];
      return next;
    });
  };

  const beginEdit = (item: QueuedPromptSnapshot) => {
    if (item.status === 'sending' || (editDraft && editDraft.id !== item.id)) return;
    setTaskEdit({ id: item.id, text: item.text });
    post({ action: 'beginQueueEdit', taskID: task.id, id: item.id });
  };

  const cancelEdit = (id: string) => {
    post({ action: 'cancelQueueEdit', taskID: task.id, id });
    setTaskEdit();
  };

  const saveEdit = (id: string) => {
    const prompt = editDraft?.id === id ? editDraft.text.trim() : '';
    if (!isValidPrompt(prompt)) return;
    post({ action: 'editQueuedPrompt', taskID: task.id, id, prompt });
    setTaskEdit();
  };

  const move = (id: string, direction: -1 | 1) => {
    const result = moveQueuedPrompt(task.queuedPrompts, id, direction);
    if (result) post({ action: 'moveQueuedPrompt', taskID: task.id, id, beforeID: result.beforeID });
  };

  const drop = (event: DragEvent, targetID?: string) => {
    event.preventDefault();
    event.stopPropagation();
    const id = draggedID || event.dataTransfer?.getData('text/plain');
    const moving = task.queuedPrompts.find((item) => item.id === id);
    if (!id || !moving || moving.status === 'sending') return;

    if (!targetID) {
      post({ action: 'moveQueuedPrompt', taskID: task.id, id, beforeID: null });
    } else {
      const bounds = (event.currentTarget as HTMLElement).getBoundingClientRect();
      const result = dropQueuedPrompt(task.queuedPrompts, id, targetID, event.clientY >= bounds.top + bounds.height / 2);
      const beforeItem = task.queuedPrompts.find((item) => item.id === result?.beforeID);
      if (result && beforeItem?.status !== 'sending') {
        post({ action: 'moveQueuedPrompt', taskID: task.id, id, beforeID: result.beforeID });
      }
    }
    setDraggedID(null);
  };

  if (task.queuedPrompts.length === 0) return null;
  const hasFailure = task.queuedPrompts.some((item) => item.status === 'failed');
  const hasUncertainFailure = task.queuedPrompts.some((item) => item.status === 'failed' && item.deliveryUncertain !== false);

  return (
    <section
      className={`prompt-queue ${task.queuePaused ? 'is-paused' : ''}`}
      aria-label="Queued messages"
      onDragOver={(event) => { if (draggedID) event.preventDefault(); }}
      onDrop={(event) => drop(event)}
    >
      <div className="queue-header" title="Queued messages are kept while Kolmogor is open">
        <div><strong>Up next</strong><span>{task.queuedPrompts.length}</span></div>
        {task.queuePaused ? (
          <Button variant="outline" size="sm" className="queue-resume-button" onClick={() => post({ action: 'resumeQueue', taskID: task.id })}>
            <Icon name="resume" size={13} /> Resume queue
          </Button>
        ) : null}
      </div>
      {task.queuePaused || hasFailure ? (
        <div className="queue-warning" role="status">
          <Icon name="info" size={14} />
          <span>{hasUncertainFailure
            ? 'Delivery is uncertain and may already have happened. Review this message before resuming or resending.'
            : hasFailure
              ? 'The message was not sent. Choose a model or fix the connection, then resume manually.'
              : 'The queue is paused after this task stopped. Review it, then resume manually.'}</span>
        </div>
      ) : null}
      <div className="queue-list">
        {task.queuedPrompts.map((item, index) => {
          const locked = item.status === 'sending';
          const sendNow = () => post({ action: 'steerQueuedPrompt', taskID: task.id, id: item.id });
          const editing = !locked && editDraft?.id === item.id;
          const canMoveUp = !locked && !editing && index > 0 && task.queuedPrompts[index - 1]?.status !== 'sending';
          const canMoveDown = !locked && !editing && index < task.queuedPrompts.length - 1;
          return (
            <div
              key={item.id}
              className={`queue-item queue-item-${item.status} ${draggedID === item.id ? 'is-dragging' : ''}`}
              draggable={!locked && !editing}
              onDragStart={(event) => {
                setDraggedID(item.id);
                if (event.dataTransfer) {
                  event.dataTransfer.effectAllowed = 'move';
                  event.dataTransfer.setData('text/plain', item.id);
                }
              }}
              onDragEnd={() => setDraggedID(null)}
              onDragOver={(event) => { if (draggedID && draggedID !== item.id) event.preventDefault(); }}
              onDrop={(event) => drop(event, item.id)}
            >
              <span className="queue-drag-handle" aria-hidden="true"><Icon name="drag" size={14} /></span>
              {editing ? (
                <div className="queue-edit">
                  <Textarea
                    value={editDraft.text}
                    rows={2}
                    maxLength={200000}
                    aria-label="Edit queued message"
                    onInput={(event) => setTaskEdit({ id: item.id, text: (event.currentTarget as HTMLTextAreaElement).value })}
                    onKeyDown={(event) => {
                      if (event.key === 'Escape' && !event.isComposing && !event.repeat) {
                        event.preventDefault();
                        cancelEdit(item.id);
                        return;
                      }
                      if (shouldSubmitPromptKey(event)) {
                        event.preventDefault();
                        saveEdit(item.id);
                      }
                    }}
                  />
                  <div className="queue-edit-actions">
                    <Button variant="ghost" size="sm" onClick={() => cancelEdit(item.id)}>Cancel</Button>
                    <Button size="sm" disabled={!isValidPrompt(editDraft.text)} onClick={() => saveEdit(item.id)}>Save</Button>
                  </div>
                </div>
              ) : (
                <div className="queue-item-copy">
                  <span className="queue-item-text">{item.text}</span>
                  <span className={`queue-item-status ${item.status === 'failed' ? 'tone-red' : item.status === 'sending' ? 'tone-blue' : ''}`}>
                    {queueStatusLabel(item)}
                  </span>
                  {item.error ? <span className="queue-item-error">{item.error}</span> : null}
                </div>
              )}
              {!editing ? (
                <div className="queue-item-actions">
                  {item.status === 'queued' && (
                    <Button
                      variant="ghost"
                      size="xs"
                      disabled={!task.canSteer}
                      aria-label={`Send queued message ${index + 1} now`}
                      title={task.canSteer ? 'Send now into the current turn' : 'The agent cannot take a message right now'}
                      onClick={sendNow}
                    >
                      <Icon name="send" size={14} /> Send
                    </Button>
                  )}
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        className="queue-menu-trigger"
                        disabled={locked}
                        aria-label={`Actions for queued message ${index + 1}`}
                      >
                        <Icon name="more" size={15} />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end" className="queue-menu-content">
                      {task.canSteer && item.status === 'queued' ? (
                        <>
                          <DropdownMenuItem onSelect={sendNow}>
                            <Icon name="steer" size={14} /> Steer into current turn
                          </DropdownMenuItem>
                          <DropdownMenuSeparator />
                        </>
                      ) : null}
                      <DropdownMenuItem disabled={!canMoveUp} onSelect={() => move(item.id, -1)}>
                        <Icon name="send" size={14} /> Move up
                      </DropdownMenuItem>
                      <DropdownMenuItem disabled={!canMoveDown} onSelect={() => move(item.id, 1)}>
                        <Icon name="down" size={14} /> Move down
                      </DropdownMenuItem>
                      <DropdownMenuSeparator />
                      <DropdownMenuItem disabled={Boolean(editDraft && editDraft.id !== item.id)} onSelect={() => beginEdit(item)}>
                        <Icon name="edit" size={14} /> Edit
                      </DropdownMenuItem>
                      <DropdownMenuItem variant="destructive" onSelect={() => post({ action: 'deleteQueuedPrompt', taskID: task.id, id: item.id })}>
                        <Icon name="delete" size={14} /> Delete
                      </DropdownMenuItem>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </div>
              ) : null}
            </div>
          );
        })}
      </div>
    </section>
  );
}

function availableForNewPrompt(model: string, snapshot: AppSnapshot): boolean {
  if (snapshot.selectedModelAvailableForNewPrompt !== undefined) return snapshot.selectedModelAvailableForNewPrompt;
  if (!(model.startsWith('browser/') || model.startsWith('cli/')) || !snapshot.providerSetups?.length) return true;
  return snapshot.modelOptions.some(option => option.id === model && option.available !== false && option.selectable !== false);
}

function Composer({
  task,
  snapshot,
  value,
  setValue,
  pending,
  submissionError,
  onSubmit,
}: {
  task: TaskSnapshot;
  snapshot: AppSnapshot;
  value: string;
  setValue: (value: string) => void;
  pending: boolean;
  submissionError?: string;
  onSubmit: () => void;
}) {
  const textarea = useRef<HTMLTextAreaElement | null>(null);
  const websitePrepareDemand = useRef<{ taskID: string; model: string; at: number | null }>({ taskID: task.id, model: task.model, at: null });
  if (websitePrepareDemand.current.taskID !== task.id || websitePrepareDemand.current.model !== task.model) {
    websitePrepareDemand.current = { taskID: task.id, model: task.model, at: null };
  }
  const prepareWebsiteModel = () => {
    if (task.model !== 'browser/chatgpt' && !task.model.startsWith('browser/chatgpt/choice/')) return;
    const now = performance.now();
    const previous = websitePrepareDemand.current;
    if (previous.at !== null && now < previous.at + 5000) return;
    previous.at = now;
    post({ action: 'prepareWebsiteModel', taskID: task.id });
  };
  const queueActive = task.queuedPrompts.length > 0;
  const willQueue = task.isBusy || task.queuePaused || queueActive;
  const selectedModel = snapshot.modelOptions.find((option) => option.id === task.model);
  const canSubmit = !pending && isValidPrompt(value) && (willQueue || task.modelSelectable && availableForNewPrompt(task.model, snapshot));
  const primaryAction = composerPrimaryAction(task.status === 'Running', value, willQueue);
  const stopsTask = primaryAction === 'stop';
  useEffect(() => {
    if (!textarea.current) return;
    textarea.current.style.height = 'auto';
    textarea.current.style.height = `${Math.min(200, textarea.current.scrollHeight)}px`;
  }, [value, task.id]);

  const submit = () => {
    if (!canSubmit) return;
    onSubmit();
  };

  return (
    <div className="composer-zone">
      <WebsiteSessionCleanupControl task={task} blocked={snapshot.pendingApprovalCount > 0} post={post} />
      <PromptQueue task={task} />
      <div className="composer-shell">
        <Textarea
          ref={textarea}
          id="task-prompt"
          value={value}
          rows={2}
          placeholder={task.isBusy ? 'Type your next message to queue it…' : 'Ask a question or describe a task…'}
          aria-label="Task prompt"
          maxLength={200000}
          onFocus={prepareWebsiteModel}
          onInput={(event) => {
            setValue((event.currentTarget as HTMLTextAreaElement).value);
            prepareWebsiteModel();
          }}
          onKeyDown={(event) => {
            if (shouldSubmitPromptKey(event)) {
              event.preventDefault();
              submit();
            }
          }}
        />
        <div className="composer-controls">
          <div className="composer-left">
            <ModelSelector
              key={task.id}
              className="model-picker"
              label="Task model"
              model={task.model}
              boundToRuntime={task.hasBoundThread}
              options={snapshot.modelOptions}
              setups={snapshot.providerSetups}
              canConnect={snapshot.canRefreshWebsiteModels === true}
              onConnect={(route) => post({ action: 'connectModelProvider', route })}
              onRefresh={post}
              disabled={!task.modelSelectable}
              onSelect={(modelID) => post({ action: 'setTaskModel', taskID: task.id, modelID })}
            />
            {/* Model refresh controls are temporarily hidden; retain the component for later restoration.
            <WebsiteModelsRefresh model={task.model} canRefresh={snapshot.canRefreshWebsiteModels === true} refreshing={snapshot.websiteModelsRefreshing}
              onRefresh={post} />
            */}
          </div>
          <div className="composer-right">
            <Button variant={stopsTask ? 'outline' : 'default'} size="icon" className="composer-action"
              disabled={!stopsTask && !canSubmit}
              aria-label={stopsTask ? 'Stop task' : primaryAction === 'queue' ? 'Queue prompt' : 'Send prompt'}
              title={stopsTask ? 'Stop task' : primaryAction === 'queue' ? 'Queue message · Enter' : 'Send message · Enter'}
              onClick={stopsTask ? () => post({ action: 'interruptTask', taskID: task.id }) : submit}>
              <Icon name={stopsTask ? 'pause' : 'send'} size={stopsTask ? 18 : 19} />
            </Button>
          </div>
        </div>
      </div>
      {pending || submissionError ? (
        <span
          className={`composer-submit-status ${submissionError ? 'tone-red' : ''}`}
          role="status"
          aria-live="polite"
        >
          {submissionError ?? 'Submitting…'}
        </span>
      ) : null}
      {selectedModel?.highMemory && <span className="composer-memory-warning">35B needs a separate download and may exceed available memory on this Mac.</span>}
    </div>
  );
}

function ActivityClock({ group }: { group: ActivityGroup }) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    if (!group.isRunning) return;
    setNow(Date.now() / 1000);
    const interval = window.setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => window.clearInterval(interval);
  }, [group.isRunning, group.startedAt]);
  return <span className="reasoning-label">{activityLabel(group, now)}</span>;
}

function Conversation({ snapshot, task, draftState }: { snapshot: AppSnapshot; task: TaskSnapshot; draftState: ReturnType<typeof useConversationDrafts> }) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const followingOutput = useRef(true);
  const { drafts, setDrafts, pendingSubmissions, setPendingSubmissions, submissionErrors, setSubmissionErrors } = draftState;
  const [activityOpenOverrides, setActivityOpenOverrides] = useState<Record<string, boolean>>({});

  useEffect(() => {
    const scroll = scrollRef.current;
    const content = contentRef.current;
    if (!scroll || !content) return;
    followingOutput.current = true;
    const follow = () => {
      if (followingOutput.current) scroll.scrollTop = scroll.scrollHeight;
    };
    // A streaming reply grows without adding another entry. Observe its
    // rendered size, but leave the reader alone when they scroll up.
    const observer = new ResizeObserver(follow);
    observer.observe(content);
    observer.observe(scroll);
    follow();
    return () => observer.disconnect();
  }, [task.id]);
  const setDraft = (value: string) => {
    setDrafts((current) => ({ ...current, [task.id]: value }));
    setSubmissionErrors((current) => {
      if (!(task.id in current)) return current;
      const next = { ...current };
      delete next[task.id];
      return next;
    });
  };

  const submitDraft = () => {
    if (pendingSubmissions[task.id]) return;
    const draft = drafts[task.id] ?? '';
    const prompt = draft.trim();
    const canSubmit = task.modelSelectable && availableForNewPrompt(task.model, snapshot) || task.isBusy || task.queuePaused || task.queuedPrompts.length > 0;
    if (!canSubmit || !isValidPrompt(draft)) return;

    followingOutput.current = true;
    const requestID = crypto.randomUUID();
    setPendingSubmissions((current) => ({ ...current, [task.id]: { requestID, draft } }));
    setSubmissionErrors((current) => {
      if (!(task.id in current)) return current;
      const next = { ...current };
      delete next[task.id];
      return next;
    });
    post({ action: 'submitPrompt', requestID, taskID: task.id, prompt });
  };
  const handledLaunch = useRef<string>();
  useEffect(() => {
    const launch = snapshot.launcherChat;
    if (!launch || launch.taskID !== task.id || handledLaunch.current === task.id ||
        snapshot.pendingApprovalCount || snapshot.isSettingsPresented || snapshot.primaryBrowserID) return;
    handledLaunch.current = task.id;
    if (launch.unsentDraft) {
      setDraft(launch.unsentDraft);
      const reason = isValidPrompt(launch.unsentDraft) ? 'Choose an available model to send this draft.' : 'Shorten this draft before sending.';
      setSubmissionErrors(current => ({ ...current, [task.id]: reason }));
    }
    document.getElementById('task-prompt')?.focus();
    post({ action: 'launcherChatReady', taskID: task.id });
  }, [snapshot.launcherChat?.taskID, task.id, snapshot.pendingApprovalCount, snapshot.isSettingsPresented, snapshot.primaryBrowserID]);
  const rows = activityTimeline(task);
  return (
    <div className={`conversation-column ${rows.length === 0 && !snapshot.isReviewPresented ? 'is-empty' : ''} ${snapshot.isReviewPresented ? 'is-reviewing' : ''}`}>
      <div className="review-host" hidden={!snapshot.isReviewPresented}><ReviewPanel taskID={task.id} review={snapshot.review} busy={task.isBusy} post={post} onFeedback={(text) => {
        setDraft((drafts[task.id] ?? '').trim() ? `${drafts[task.id]}\n\n${text}` : text);
        post({ action: 'toggleReview' });
        requestAnimationFrame(() => document.getElementById('task-prompt')?.focus());
      }} /></div>
      <div className="conversation-scroll" id="conversation-scroll" ref={scrollRef}
        hidden={Boolean(snapshot.isReviewPresented)}
        onScroll={(event) => {
          const scroll = event.currentTarget as HTMLDivElement;
          followingOutput.current = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight <= 48;
        }}>
        <div className="conversation-content" ref={contentRef}>
          {rows.length === 0 ? (
            <div className="empty-conversation">
              <h1>Kolmogor will take care of it.</h1>
              <p>Ask a question or give your Mac a task.</p>
              {showProjectFolderPicker && task.status === 'Draft' && task.entries.length === 0 && !task.isBusy ? <Button variant="outline" size="sm" className="choose-workspace-button" onClick={() => post({ action: 'chooseTaskWorkspace', taskID: task.id })}>Choose a project folder</Button> : null}
            </div>
          ) : (
            rows.map((row) => {
              if (row.kind === 'entry') return <TimelineEntry key={row.entry.id} entry={row.entry}
                selected={snapshot.selectedEntryID === row.entry.id}
                hideAnswerDuration={row.hideAnswerMetadata} />;
              const group = row.group;
              const key = `${task.id}:${group.id}`;
              return <ActivityDisclosure key={`activity:${key}`} group={group} time={clockTime(group.timestamp)}
                label={<ActivityClock group={group} />}
                manualOpen={activityOpenOverrides[key]}
                onOpenChange={(open) => setActivityOpenOverrides((current) => ({ ...current, [key]: open }))}>
                {group.entries.map((entry) => <div key={entry.id}
                  className={`activity-step ${entry.kind === 'tool' ? 'activity-tool' : 'activity-reasoning'} ${snapshot.selectedEntryID === entry.id ? 'selected' : ''}`}
                  onClick={() => post({ action: 'selectEntry', id: entry.id })}>
                  {entry.kind === 'tool'
                    ? <ToolDetails entry={entry} showPayload={snapshot.showToolPayloads} />
                    : <ResponseMarkdown text={entry.body} />}
                </div>)}
              </ActivityDisclosure>;
            })
          )}
        </div>
      </div>
      <Composer
        task={task}
        snapshot={snapshot}
        value={drafts[task.id] ?? ''}
        setValue={setDraft}
        pending={Boolean(pendingSubmissions[task.id])}
        submissionError={submissionErrors[task.id]}
        onSubmit={submitDraft}
      />
    </div>
  );
}

function Inspector({ snapshot, task }: { snapshot: AppSnapshot; task: TaskSnapshot }) {
  const entry = task.entries.find((candidate) => candidate.id === snapshot.selectedEntryID);
  return (
    <aside className="inspector" aria-label="Task inspector">
      <div className="inspector-header">
        <div><span>Details</span><strong>{entry?.tool ? toolNames[entry.tool.name] ?? entry.title : entry?.title ?? 'Task overview'}</strong></div>
        <Button variant="ghost" size="icon" className="icon-button" aria-label="Close inspector" onClick={() => post({ action: 'toggleInspector' })}>
          <Icon name="x" size={16} />
        </Button>
      </div>
      <div className="inspector-scroll">
        <section className="inspector-section">
          <h2>Task</h2>
          <dl>
            <div><dt>Status</dt><dd className={toneClass(task.statusTone)}>{task.status}</dd></div>
            <div><dt>Model</dt><dd title={task.model}><ModelLabel model={task.model} option={snapshot.modelOptions.find((option) => option.id === task.model)} /></dd></div>
            <div><dt>Workspace</dt><dd className="mono">{task.workspace}</dd></div>
            {task.branch ? <div><dt>Branch</dt><dd className="mono">{task.branch}</dd></div> : null}
            <div><dt>Events</dt><dd>{task.entries.length}</dd></div>
            <div><dt>Updated</dt><dd>{relativeTime(task.updatedAt) === 'now' ? 'Just now' : `${relativeTime(task.updatedAt)} ago`}</dd></div>
          </dl>
        </section>
        <section className="inspector-section">
          <h2>{entry ? 'Selected event' : 'Selection'}</h2>
          {entry ? (
            <>
              <dl>
                <div><dt>Type</dt><dd>{entry.kind}</dd></div>
                <div><dt>Time</dt><dd>{clockTime(entry.timestamp)}</dd></div>
                {entry.tool ? <div><dt>Tool</dt><dd className="mono">{entry.tool.name}</dd></div> : null}
              </dl>
              <div className="inspector-event-copy">{entry.body}</div>
              {entry.tool && snapshot.showToolPayloads ? (
                <div className="inspector-payload"><span>Input</span><pre>{entry.tool.input}</pre></div>
              ) : null}
            </>
          ) : (
            <div className="inspector-empty"><Icon name="inspect" size={23} /><p>Select a transcript event to inspect it.</p></div>
          )}
        </section>
      </div>
    </aside>
  );
}

function DefaultModelSelector({ snapshot }: { snapshot: AppSnapshot }) {
  return <ModelSelector label="Default model for new tasks" model={snapshot.defaultModel}
    options={snapshot.modelOptions} setups={snapshot.providerSetups} canConnect={snapshot.canRefreshWebsiteModels === true}
    onConnect={(route) => post({ action: 'connectModelProvider', route })}
    onRefresh={post}
    onSelect={(modelID) => post({ action: 'setDefaultModel', modelID })} />;
}

function SettingsModal({ snapshot, nativeHost }: { snapshot: AppSnapshot; nativeHost: boolean }) {
  const dialog = useRef<HTMLElement | null>(null);
  const canRestoreFocus = useRef(true);
  canRestoreFocus.current = snapshot.pendingApprovalCount === 0;
  const isOpen = snapshot.isSettingsPresented && snapshot.pendingApprovalCount === 0;
  useEffect(() => {
    if (!isOpen) return;
    const previous = document.activeElement as HTMLElement | null;
    const frame = requestAnimationFrame(() => dialog.current?.querySelector<HTMLButtonElement>('button')?.focus());
    const handleKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return;
      if (event.key === 'Escape') { event.preventDefault(); post({ action: 'dismissSettings' }); }
      if (event.key !== 'Tab') return;
      const controls = Array.from(dialog.current?.querySelectorAll<HTMLElement>('button:not(:disabled), select:not(:disabled), input:not(:disabled), summary, [tabindex="0"]') ?? []);
      const first = controls[0]; const last = controls[controls.length - 1];
      if (!dialog.current?.contains(document.activeElement)) { event.preventDefault(); first?.focus(); }
      else if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    document.addEventListener('keydown', handleKey);
    return () => {
      cancelAnimationFrame(frame);
      document.removeEventListener('keydown', handleKey);
      // Native approval owns focus; Settings teardown must not steal it back.
      if (canRestoreFocus.current) previous?.focus();
    };
  }, [isOpen]);
  if (!isOpen) return null;
  const accessibilityGranted = snapshot.permissions.accessibility === 'Granted';
  const screenRecordingGranted = snapshot.permissions.screenRecording === 'Granted';
  const defaultModel = snapshot.modelOptions.find((option) => option.id === snapshot.defaultModel);
  const accessModeLabel = snapshot.accessMode === 'fullAccess' ? 'Full access' : 'Ask every time';
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={() => post({ action: 'dismissSettings' })}>
      <section ref={dialog} className="settings-modal" role="dialog" aria-modal="true" aria-labelledby="settings-title" onMouseDown={(event) => event.stopPropagation()}>
        <header>
          <h1 id="settings-title">Settings</h1>
          <Button variant="ghost" size="icon" className="icon-button" aria-label="Close settings" onClick={() => post({ action: 'dismissSettings' })}><Icon name="x" /></Button>
        </header>
        <div className="settings-content">
          <section>
            <h2>Appearance</h2>
            <label className="setting-row">
              <span><strong>Color scheme</strong></span>
              <NativeSelect
                aria-label="Color scheme"
                value={snapshot.appearance}
                onChange={(event: Event) => post({ action: 'setAppearance', value: (event.currentTarget as HTMLSelectElement).value as AppSnapshot['appearance'] })}
              >
                <NativeSelectOption value="system">System</NativeSelectOption>
                <NativeSelectOption value="light">Light</NativeSelectOption>
                <NativeSelectOption value="dark">Dark</NativeSelectOption>
              </NativeSelect>
            </label>
          </section>
          {nativeHost && <section>
            <h2>Browser</h2>
            <div className="setting-row">
              <span><strong>Import browser data</strong><small>Choose a Chrome profile to bring in history, bookmarks, and saved passwords. Find imported pages in the address bar. Use View → Fill Saved Login on a sign-in page.</small></span>
              <Button variant="outline" disabled={snapshot.importingChromeProfile}
                onClick={() => post({ action: 'importChromeProfile' })}>Import from Chrome…</Button>
            </div>
            {snapshot.chromeProfileImportStatus && <p className="model-note" role="status">{snapshot.chromeProfileImportStatus}</p>}
          </section>}
          <section>
            <h2>Models and runtime</h2>
            <label className="setting-row">
              <span><strong>Default model</strong><small>Used for new tasks. You can choose another in the composer.</small></span>
              <DefaultModelSelector snapshot={snapshot} />
            </label>
            <p className={defaultModel?.highMemory ? 'model-note high-memory' : 'model-note'}>{defaultModel?.detail}</p>
            <div className="setting-row"><span><strong>Website models</strong><small>Choices come from the model menus on your signed-in provider websites.</small></span>
              {/* Model refresh controls are temporarily hidden; retain the component for later restoration.
              <WebsiteModelsRefresh canRefresh={snapshot.canRefreshWebsiteModels === true} refreshing={snapshot.websiteModelsRefreshing} onRefresh={post} />
              */}
            </div>
            {snapshot.websiteModelsError && <p className="model-note" role="status">{snapshot.websiteModelsError}</p>}
            <div className="setting-row"><span><strong>API providers</strong><small>Connect an API provider and load its available models.</small></span>
              <Button variant="outline" onClick={() => post({ action: 'showAPIProviders' })}>Manage providers</Button>
            </div>
            <div className="setting-row"><span><strong>Connection</strong><small>{snapshot.connection.label}</small></span><span className={`setting-state ${toneClass(snapshot.connection.tone)}`}><span />{snapshot.connection.state}</span></div>
          </section>
          <section>
            <h2>Agent interface</h2>
            <label className="setting-row">
              <span><strong>Show tool input and output</strong><small>Expand tool payloads in the transcript and inspector.</small></span>
              <Switch
                aria-label="Show tool input and output"
                checked={snapshot.showToolPayloads}
                onCheckedChange={(checked: boolean) => post({ action: 'setShowToolPayloads', value: checked })}
              />
            </label>
            <div className="setting-row">
              <span><strong>Access mode</strong></span>
              <Button variant="outline" disabled={!nativeHost} aria-haspopup="dialog"
                aria-label={`Change access mode: ${accessModeLabel}`}
                onClick={() => post({ action: 'showAccessModeSettings' })}>
                {accessModeLabel}
              </Button>
            </div>
          </section>
          <section>
            <h2>Computer use</h2>
            <p className="permission-note">New tasks use the latest computer tools. Older tasks may keep an earlier tool version; start a new task to use updated capabilities. Your existing task history is kept.</p>
            <div className="setting-row permission-row">
              <span><strong>Accessibility</strong><small>Required for semantic UI inspection and actions.</small></span>
              <span className="permission-controls">
                <span className={accessibilityGranted ? 'permission-status granted' : 'permission-status'}>{snapshot.permissions.accessibility}</span>
                <Button variant="outline"
                  className="secondary-button permission-request-button"
                  disabled={accessibilityGranted}
                  onClick={() => post({ action: 'requestAccessibilityPermission' })}
                >
                  {accessibilityGranted ? 'Granted' : 'Request access'}
                </Button>
              </span>
            </div>
            <div className="setting-row permission-row">
              <span><strong>Screen Recording</strong><small>Required for screenshots.</small></span>
              <span className="permission-controls">
                <span className={screenRecordingGranted ? 'permission-status granted' : 'permission-status'}>{snapshot.permissions.screenRecording}</span>
                <Button variant="outline"
                  className="secondary-button permission-request-button"
                  disabled={screenRecordingGranted}
                  onClick={() => post({ action: 'requestScreenRecordingPermission' })}
                >
                  {screenRecordingGranted ? 'Granted' : 'Request access'}
                </Button>
              </span>
            </div>
            <details className="permission-help"><summary>About computer access <Icon name="chevron" size={13} /></summary><p className="permission-note">macOS permissions are separate from the app's access mode. Full access allows terminal/file commands outside the workspace and network access without engine approval prompts, and automatically approves Kolmogor action requests. Ask every time keeps the workspace sandbox and asks before protected actions. Read-only inspection stays prompt-free. Both modes keep tool validation and macOS permission checks. New submissions use this choice; running turns keep their execution permissions. Your choice is remembered across launches.</p></details>
            <Button variant="outline" className="refresh-button" onClick={() => post({ action: 'refreshPermissions' })}>Refresh permission status</Button>
          </section>
        </div>
        <footer><Button onClick={() => post({ action: 'dismissSettings' })}>Done</Button></footer>
      </section>
    </div>
  );
}

function LoadingView() {
  return (
    <main className="loading-view">
      <span className="loading-mark"><Icon name="sparkles" size={22} /></span>
      <strong>Starting Kolmogor</strong>
      <span>Connecting the native runtime…</span>
    </main>
  );
}

function BridgeUnavailableView() {
  return (
    <main className="loading-view" role="alert">
      <span className="loading-mark"><Icon name="info" size={22} /></span>
      <strong>Native bridge unavailable</strong>
      <span>Open this interface from the Kolmogor macOS application.</span>
    </main>
  );
}

export function App() {
  const nativeHost = Boolean(window.webkit?.messageHandlers?.localCodex);
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(nativeHost ? null : previewSnapshot);
  const [search, setSearch] = useState('');
  const draftState = useConversationDrafts(snapshot?.promptReceipts);
  const focusSearchOnExpand = useRef(false);
  const currentSnapshot = useRef(snapshot);
  currentSnapshot.current = snapshot;
  const selectedTask = snapshot?.tasks.find((candidate) => candidate.id === snapshot.selectedTaskID);

  useEffect(() => observeDisplayedCompletion(() => currentSnapshot.current, {
    visible: () => document.visibilityState === 'visible',
    focused: () => document.hasFocus(),
    afterRender: (callback) => {
      const frame = window.requestAnimationFrame(callback);
      return () => window.cancelAnimationFrame(frame);
    },
    onReturn: (callback) => {
      window.addEventListener('focus', callback);
      document.addEventListener('visibilitychange', callback);
      return () => {
        window.removeEventListener('focus', callback);
        document.removeEventListener('visibilitychange', callback);
      };
    },
  }, post), [snapshot?.selectedTaskID, selectedTask?.unreadCompletionID,
    selectedTask?.hasUnreadCompletion, selectedTask?.status, selectedTask?.isBusy,
    snapshot?.primaryBrowserID, snapshot?.isSettingsPresented, snapshot?.isReviewPresented, snapshot?.pendingApprovalCount]);

  useEffect(() => {
    if (import.meta.env.DEV && !nativeHost) return installPreviewBridge(setSnapshot);
    window.__localCodexReceiveState = (next) => {
      setSnapshot((current) => (!current || next.revision >= current.revision ? next : current));
    };
    post({ action: 'ready' });
    return () => {
      delete window.__localCodexReceiveState;
    };
  }, []);

  useEffect(() => {
    if (!snapshot?.isTaskSidebarCollapsed && focusSearchOnExpand.current) {
      focusSearchOnExpand.current = false;
      document.getElementById('task-search')?.focus();
    }
  }, [snapshot?.isTaskSidebarCollapsed]);

  function focusSearch() {
    const current = currentSnapshot.current;
    if (!current || current.isSettingsPresented || current.pendingApprovalCount) return;
    const field = document.getElementById('task-search');
    if (field && !current.isTaskSidebarCollapsed) { field.focus(); return; }
    focusSearchOnExpand.current = true;
    if (current.isTaskSidebarCollapsed) post({ action: 'setTaskSidebarCollapsed', collapsed: false });
  }

  function createChat() {
    setSearch('');
    post({ action: 'createTask' });
  }

  useEffect(() => {
    const clearSearch = () => setSearch('');
    document.addEventListener('kolmogor-clear-chat-search', clearSearch);
    return () => document.removeEventListener('kolmogor-clear-chat-search', clearSearch);
  }, []);

  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => {
      if (!event.metaKey || snapshot?.isSettingsPresented) return;
      if (event.key.toLowerCase() === 'k' && !snapshot?.pendingApprovalCount) {
        event.preventDefault();
        focusSearch();
      }
      if (!nativeHost && event.key.toLowerCase() === 'n' && event.shiftKey) { event.preventDefault(); createChat(); }
      if (!nativeHost && event.key === ',') { event.preventDefault(); post({ action: 'showSettings' }); }
    };
    document.addEventListener('keydown', handleKey);
    document.addEventListener('kolmogor-focus-tab-search', focusSearch);
    return () => {
      document.removeEventListener('keydown', handleKey);
      document.removeEventListener('kolmogor-focus-tab-search', focusSearch);
    };
  }, [snapshot?.isSettingsPresented, snapshot?.isTaskSidebarCollapsed, snapshot?.pendingApprovalCount]);

  useEffect(() => {
    const appearance = snapshot?.appearance ?? 'system';
    document.documentElement.dataset.appearance = appearance;
    const system = window.matchMedia('(prefers-color-scheme: dark)');
    const syncTheme = () => document.documentElement.classList.toggle('dark', appearance === 'dark' || (appearance === 'system' && system.matches));
    syncTheme();
    system.addEventListener('change', syncTheme);
    return () => system.removeEventListener('change', syncTheme);
  }, [snapshot?.appearance]);

  if (!snapshot) return nativeHost ? <LoadingView /> : <BridgeUnavailableView />;

  const task = snapshot.tasks.find((candidate) => candidate.id === snapshot.selectedTaskID);
  return (
    <div className="app-shell" data-native-host={nativeHost ? 'true' : undefined} data-native-sidebar-controls={snapshot.nativeSidebarControls || undefined}
      data-browser-primary={snapshot.primaryBrowserID && !snapshot.isSettingsPresented ? (nativeHost ? "native" : "preview") : undefined}
      data-sidebar-peeked={snapshot.isTaskSidebarCollapsed && snapshot.isTaskSidebarPeeked || undefined}
      data-sidebar-collapsed={sidebarIsCompact(snapshot) ? 'true' : undefined}
      data-allows-side-pane={snapshot.allowsBrowserSidePane || undefined}
      data-browser-pane={nativeHost && snapshot.isBrowserPresented && !snapshot.isSettingsPresented ? 'open' : undefined}>
      <div className="app-panels" inert={snapshot.isSettingsPresented || snapshot.pendingApprovalCount > 0}>
      <WorkspaceSidebar post={post} snapshot={snapshot} search={search} setSearch={setSearch} nativeHost={nativeHost} />
      {!nativeHost && snapshot.primaryBrowserID && <main className="preview-browser-content">
        <Icon name="browser" /><strong>{snapshot.workspaceBrowsers?.find(tab => tab.id === snapshot.primaryBrowserID)?.title}</strong>
        <span>Pages open in the desktop browser.</span></main>}
      <main className="workspace">
        {snapshot.allowsBrowserSidePane && !nativeHost && <Button variant="ghost" size="icon" className="preview-browser-toggle"
          aria-label="Toggle browser" aria-pressed={snapshot.isBrowserPresented}
          title={snapshot.isBrowserPresented ? 'Hide browser' : 'Show browser'}
          onClick={() => post({ action: 'toggleBrowser' })}>
          <Icon name="browser" size={18} />
        </Button>}
        <TaskToolbar task={task} snapshot={snapshot} allowFresh={Boolean(task && !draftState.drafts[task.id] && !draftState.pendingSubmissions[task.id])} rowHeight={snapshot.titlebarHeight} onNewChat={snapshot.allowsBrowserSidePane && !snapshot.nativeSidebarControls ? createChat : undefined} />
        {snapshot.savedChatSelection ? (
          <div className="no-task-view" role={snapshot.savedChatSelection.error ? 'alert' : 'status'}>
            {snapshot.savedChatSelection.error ? <>
              <p>Couldn’t open this chat. {snapshot.savedChatSelection.error}</p>
              <Button onClick={() => post({ action: 'selectTask', id: snapshot.savedChatSelection!.id })}>Retry</Button>
            </> : <p>Loading chat…</p>}
          </div>
        ) : task ? (
          <Conversation snapshot={snapshot} task={task} draftState={draftState} />
        ) : (
          <div className="no-task-view">
            <p>Choose a model for your next task.</p>
            <DefaultModelSelector snapshot={snapshot} />
          </div>
        )}
      </main>
      {task && snapshot.isInspectorPresented && !snapshot.isReviewPresented ? <Inspector snapshot={snapshot} task={task} /> : null}
      </div>
      <SettingsModal snapshot={snapshot} nativeHost={nativeHost} />
    </div>
  );
}
