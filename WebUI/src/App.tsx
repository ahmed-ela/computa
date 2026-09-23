import { useEffect, useState } from 'octane';
import type {
  AppSnapshot,
  EntrySnapshot,
  NativeAction,
  TaskSnapshot,
  Tone,
} from './types';

type IconName =
  | 'archive'
  | 'check'
  | 'chevron'
  | 'computer'
  | 'copy'
  | 'gear'
  | 'info'
  | 'inspect'
  | 'more'
  | 'new'
  | 'plus'
  | 'search'
  | 'send'
  | 'stop'
  | 'sparkles'
  | 'terminal'
  | 'user'
  | 'x';

const iconPaths: Record<IconName, string> = {
  archive: 'M4 7h16M6 7v12h12V7M9 11h6M5 3h14l1 4H4l1-4Z',
  check: 'm5 12 4 4L19 6',
  chevron: 'm9 18 6-6-6-6',
  computer: 'M4 5h16v11H4V5Zm5 15h6m-3-4v4',
  copy: 'M8 8h11v11H8V8Zm-3 8H4V4h12v1',
  gear: 'M12 8.7a3.3 3.3 0 1 0 0 6.6 3.3 3.3 0 0 0 0-6.6Zm8 3.3-2.1-1 .1-2.3-2.1-2.1-2.3.1-1-2.1H9.4l-1 2.1-2.3-.1L4 8.7l.1 2.3L2 12l2.1 1-.1 2.3 2.1 2.1 2.3-.1 1 2.1h3.2l1-2.1 2.3.1 2.1-2.1-.1-2.3 2.1-1Z',
  info: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Zm0-9v5m0-9h.01',
  inspect: 'M4 4h16v16H4V4Zm11 0v16M18 8h-1m1 4h-1m1 4h-1',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  new: 'M5 19h4L19 9l-4-4L5 15v4Zm9-13 4 4M4 4h6',
  plus: 'M12 5v14M5 12h14',
  search: 'm21 21-4.4-4.4m2.4-5.1a7.5 7.5 0 1 1-15 0 7.5 7.5 0 0 1 15 0Z',
  send: 'm5 12 14-7-4 14-3-6-7-1Zm7 1 7-8',
  stop: 'M7 7h10v10H7z',
  sparkles: 'm12 3 1.2 3.8L17 8l-3.8 1.2L12 13l-1.2-3.8L7 8l3.8-1.2L12 3ZM5 14l.8 2.2L8 17l-2.2.8L5 20l-.8-2.2L2 17l2.2-.8L5 14Zm13-1 .8 2.2L21 16l-2.2.8L18 19l-.8-2.2L15 16l2.2-.8L18 13Z',
  terminal: 'm4 7 5 5-5 5m8 0h8',
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm7 8a7 7 0 0 0-14 0',
  x: 'M6 6l12 12M18 6 6 18',
};

function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={iconPaths[name]} />
    </svg>
  );
}

function post(action: NativeAction) {
  window.webkit?.messageHandlers?.localCodex?.postMessage(action);
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

function Sidebar({
  snapshot,
  search,
  setSearch,
}: {
  snapshot: AppSnapshot;
  search: string;
  setSearch: (value: string) => void;
}) {
  const needle = search.trim().toLocaleLowerCase();
  const tasks = needle
    ? snapshot.tasks.filter((task) =>
        `${task.title} ${task.summary} ${task.workspace}`.toLocaleLowerCase().includes(needle),
      )
    : snapshot.tasks;

  return (
    <aside className="sidebar" aria-label="Task navigation">
      <div className="window-drag-strip" />
      <div className="sidebar-brand-row">
        <div className="brand-lockup">
          <span className="brand-mark"><Icon name="sparkles" size={15} /></span>
          <strong>LocalCodex</strong>
          <span className="brand-chevron">⌄</span>
        </div>
        <div className="sidebar-utilities">
          <button className="icon-button" aria-label="Search tasks" title="Search tasks">
            <Icon name="search" size={16} />
          </button>
          <button
            className="icon-button"
            aria-label="Open settings"
            title="Settings"
            onClick={() => post({ action: 'showSettings' })}
          >
            <Icon name="gear" size={16} />
          </button>
        </div>
      </div>

      <nav className="primary-nav" aria-label="Primary">
        <button className="nav-button" onClick={() => post({ action: 'createTask' })}>
          <Icon name="new" size={17} /><span>New task</span><span className="nav-shortcut">⇧⌘N</span>
        </button>
        <button className="nav-button" onClick={() => post({ action: 'showSettings' })}>
          <Icon name="computer" size={17} /><span>Computer use</span>
        </button>
        {snapshot.pendingApprovalCount > 0 ? (
          <div className="nav-button approval-nav" role="status" aria-live="polite">
            <Icon name="info" size={17} /><span>Native approval</span>
            <span className="count-pill">{snapshot.pendingApprovalCount}</span>
          </div>
        ) : null}
      </nav>

      <label className="task-search">
        <Icon name="search" size={15} />
        <input
          value={search}
          onInput={(event) => setSearch((event.currentTarget as HTMLInputElement).value)}
          placeholder="Search tasks"
          aria-label="Search tasks"
        />
        {search ? (
          <button aria-label="Clear search" onClick={() => setSearch('')}><Icon name="x" size={13} /></button>
        ) : null}
      </label>

      <div className="sidebar-section-heading">
        <span>{search ? 'Results' : 'Tasks'}</span>
        <button className="icon-button" aria-label="Create new task" onClick={() => post({ action: 'createTask' })}>
          <Icon name="plus" size={15} />
        </button>
      </div>

      <div className="task-list" role="listbox" aria-label="Tasks">
        {tasks.length === 0 ? (
          <div className="sidebar-empty">No matching tasks</div>
        ) : (
          tasks.map((task) => (
            <button
              key={task.id}
              className={`task-row ${snapshot.selectedTaskID === task.id ? 'selected' : ''}`}
              role="option"
              aria-selected={snapshot.selectedTaskID === task.id}
              onClick={() => post({ action: 'selectTask', id: task.id })}
            >
              <span className="task-row-title">{task.title}</span>
              <span className={`task-row-status ${toneClass(task.statusTone)}`} title={task.status} />
              <span className="task-row-summary">{task.summary || 'No messages yet'}</span>
              <span className="task-row-time">{relativeTime(task.updatedAt)}</span>
            </button>
          ))
        )}
      </div>

      <div className="sidebar-footer">
        <div className="runtime-state">
          <span className={`connection-dot ${toneClass(snapshot.connection.tone)}`} />
          <span title={snapshot.connection.label}>{snapshot.connection.label}</span>
        </div>
        <button className="profile-button" onClick={() => post({ action: 'showSettings' })}>
          <span className="avatar">L</span>
          <span>Local user</span>
          <Icon name="chevron" size={14} />
        </button>
      </div>
    </aside>
  );
}

function TaskToolbar({ snapshot, task }: { snapshot: AppSnapshot; task?: TaskSnapshot }) {
  return (
    <header className="task-toolbar">
      <div className="toolbar-title-block">
        <strong>{task?.title ?? 'LocalCodex'}</strong>
        {task ? <span>{task.workspace}</span> : null}
      </div>
      <div className="toolbar-actions">
        {task ? (
          <span className={`status-label ${toneClass(task.statusTone)}`}>
            <span className="status-dot" />{task.status}
          </span>
        ) : null}
        {task?.status === 'Running' ? (
          <button
            className="secondary-button tone-red"
            aria-label="Stop task"
            title="Stop task"
            onClick={() => post({ action: 'interruptTask', taskID: task.id })}
          >
            <Icon name="stop" size={13} />Stop
          </button>
        ) : null}
        <button className="icon-button" aria-label="More task actions" title="More"><Icon name="more" size={18} /></button>
        <button
          className={`icon-button ${snapshot.isInspectorPresented ? 'active' : ''}`}
          aria-label="Toggle inspector"
          title="Toggle inspector"
          onClick={() => post({ action: 'toggleInspector' })}
        >
          <Icon name="inspect" size={18} />
        </button>
        <button className="icon-button" aria-label="Open settings" title="Settings" onClick={() => post({ action: 'showSettings' })}>
          <Icon name="gear" size={18} />
        </button>
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
        <span className={`tool-icon ${toneClass(tool.tone)}`}><Icon name="terminal" size={15} /></span>
        <span className="tool-title">{tool.name}</span>
        <span className="tool-summary">{tool.summary}</span>
        <span className={`tool-status ${toneClass(tool.tone)}`}>{tool.status}</span>
        <Icon name="chevron" size={14} />
      </summary>
      {showPayload ? (
        <div className="tool-payload">
          <div><span>Input</span><pre>{tool.input}</pre></div>
          {tool.output ? <div><span>Output</span><pre>{tool.output}</pre></div> : null}
        </div>
      ) : null}
    </details>
  );
}

function TimelineEntry({
  entry,
  selected,
  showToolPayloads,
}: {
  entry: EntrySnapshot;
  selected: boolean;
  showToolPayloads: boolean;
}) {
  if (entry.kind === 'user') {
    return (
      <article className={`message-row user-message ${selected ? 'selected' : ''}`}>
        <button
          className="user-bubble"
          onClick={() => post({ action: 'selectEntry', id: entry.id })}
          aria-label={`You: ${entry.body}`}
        >
          {entry.body}
        </button>
      </article>
    );
  }

  if (entry.kind === 'reasoning') {
    return (
      <article className={`message-row activity-message ${selected ? 'selected' : ''}`}>
        <details>
          <summary onClick={() => post({ action: 'selectEntry', id: entry.id })}>
            <span className="activity-spark"><Icon name="sparkles" size={14} /></span>
            <span>{entry.title || 'Working'}</span>
            <span className="message-time">{clockTime(entry.timestamp)}</span>
          </summary>
          <div className="activity-body">{entry.body}</div>
        </details>
      </article>
    );
  }

  if (entry.kind === 'tool') {
    return (
      <article
        className={`message-row tool-message ${selected ? 'selected' : ''}`}
        onClick={() => post({ action: 'selectEntry', id: entry.id })}
      >
        <ToolDetails entry={entry} showPayload={showToolPayloads} />
      </article>
    );
  }

  if (entry.kind === 'system') {
    return (
      <article
        className={`message-row system-message ${selected ? 'selected' : ''}`}
        onClick={() => post({ action: 'selectEntry', id: entry.id })}
      >
        <Icon name="info" size={16} />
        <div><strong>{entry.title}</strong><p>{entry.body}</p></div>
      </article>
    );
  }

  return (
    <article
      className={`message-row assistant-message ${selected ? 'selected' : ''}`}
      onClick={() => post({ action: 'selectEntry', id: entry.id })}
      tabIndex={0}
      aria-label={`${entry.title}: ${entry.body}`}
    >
      <div className="assistant-heading">
        <span className="assistant-mark"><Icon name="sparkles" size={14} /></span>
        <strong>{entry.title || 'LocalCodex'}</strong>
        <span className="message-time">{clockTime(entry.timestamp)}</span>
      </div>
      <div className="assistant-copy">{entry.body}</div>
    </article>
  );
}

function Composer({ task, snapshot }: { task: TaskSnapshot; snapshot: AppSnapshot }) {
  const [value, setValue] = useState('');
  const canSend = value.trim().length > 0 && task.modelSelectable;
  const selectedModel = snapshot.modelOptions.find((option) => option.id === task.model);

  const submit = () => {
    const prompt = value.trim();
    if (!canSend) return;
    post({ action: 'submitPrompt', prompt });
    setValue('');
  };

  return (
    <div className="composer-zone">
      <div className="composer-shell">
        <textarea
          value={value}
          rows={2}
          placeholder="Do anything"
          aria-label="Task prompt"
          maxLength={200000}
          onInput={(event) => setValue((event.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              submit();
            }
          }}
        />
        <div className="composer-controls">
          <div className="composer-left">
            <button className="composer-icon-button" aria-label="Add context" title="Add context"><Icon name="plus" size={19} /></button>
            <span className="access-label"><span className="access-shield">!</span> Approval gated</span>
          </div>
          <div className="composer-right">
            <button className="voice-button" aria-label="Voice input" title="Voice input">⌁</button>
            <button className="send-button" disabled={!canSend} aria-label="Send prompt" onClick={submit}>
              <Icon name="send" size={16} />
            </button>
          </div>
        </div>
        <div className="composer-model-row">
          <span>Model</span>
          <select
            className="model-picker"
            aria-label="Task model"
            title={selectedModel?.detail ?? task.model}
            value={task.model}
            disabled={!task.modelSelectable}
            onChange={(event) => post({ action: 'setTaskModel', taskID: task.id, modelID: (event.currentTarget as HTMLSelectElement).value })}
          >
            {!selectedModel && <option value={task.model}>{task.model}</option>}
            {snapshot.modelOptions.map((option) => <option key={option.id} value={option.id}>{option.label}</option>)}
          </select>
        </div>
      </div>
      <span className="composer-hint">⌘↩ to send · {snapshot.connection.label}</span>
      {selectedModel?.highMemory && <span className="composer-memory-warning">35B needs a separate download and may exceed available memory on this Mac.</span>}
    </div>
  );
}

function Conversation({ snapshot, task }: { snapshot: AppSnapshot; task: TaskSnapshot }) {
  return (
    <div className="conversation-column">
      <div className="conversation-scroll" id="conversation-scroll">
        <div className="conversation-content">
          {task.entries.length === 0 ? (
            <div className="empty-conversation">
              <span className="empty-mark"><Icon name="sparkles" size={22} /></span>
              <h1>What should we do?</h1>
              <p>Ask the selected local model to inspect an app, open Chrome, or perform an approved computer action.</p>
              <div className="suggestion-grid">
                <button onClick={() => post({ action: 'submitPrompt', prompt: 'Check computer-use permissions and tell me what is available.' })}>Check permissions</button>
                <button onClick={() => post({ action: 'submitPrompt', prompt: 'List the running applications and summarize what is available.' })}>Show running apps</button>
                <button onClick={() => post({ action: 'submitPrompt', prompt: 'Open Google Chrome and inspect its focused window.' })}>Inspect Chrome</button>
              </div>
            </div>
          ) : (
            task.entries.map((entry) => (
              <TimelineEntry
                key={entry.id}
                entry={entry}
                selected={snapshot.selectedEntryID === entry.id}
                showToolPayloads={snapshot.showToolPayloads}
              />
            ))
          )}
        </div>
      </div>
      <Composer task={task} snapshot={snapshot} />
    </div>
  );
}

function Inspector({ snapshot, task }: { snapshot: AppSnapshot; task: TaskSnapshot }) {
  const entry = task.entries.find((candidate) => candidate.id === snapshot.selectedEntryID);
  return (
    <aside className="inspector" aria-label="Task inspector">
      <div className="inspector-header">
        <div><span>Inspector</span><strong>{entry?.title ?? task.title}</strong></div>
        <button className="icon-button" aria-label="Close inspector" onClick={() => post({ action: 'toggleInspector' })}>
          <Icon name="x" size={16} />
        </button>
      </div>
      <div className="inspector-scroll">
        <section className="inspector-section">
          <h2>Task</h2>
          <dl>
            <div><dt>Status</dt><dd className={toneClass(task.statusTone)}>{task.status}</dd></div>
            <div><dt>Model</dt><dd>{task.model}</dd></div>
            <div><dt>Workspace</dt><dd className="mono">{task.workspace}</dd></div>
            {task.branch ? <div><dt>Branch</dt><dd className="mono">{task.branch}</dd></div> : null}
            <div><dt>Events</dt><dd>{task.entries.length}</dd></div>
            <div><dt>Updated</dt><dd>{relativeTime(task.updatedAt)} ago</dd></div>
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

function SettingsModal({ snapshot }: { snapshot: AppSnapshot }) {
  if (!snapshot.isSettingsPresented) return null;
  const accessibilityGranted = snapshot.permissions.accessibility === 'Granted';
  const screenRecordingGranted = snapshot.permissions.screenRecording === 'Granted';
  const defaultModel = snapshot.modelOptions.find((option) => option.id === snapshot.defaultModel);
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={() => post({ action: 'dismissSettings' })}>
      <section className="settings-modal" role="dialog" aria-modal="true" aria-labelledby="settings-title" onMouseDown={(event) => event.stopPropagation()}>
        <header>
          <div><span>LocalCodex</span><h1 id="settings-title">Settings</h1></div>
          <button className="icon-button" aria-label="Close settings" onClick={() => post({ action: 'dismissSettings' })}><Icon name="x" /></button>
        </header>
        <div className="settings-content">
          <section>
            <h2>Appearance</h2>
            <label className="setting-row">
              <span><strong>Color scheme</strong><small>Choose how the local client looks.</small></span>
              <select
                value={snapshot.appearance}
                onChange={(event) => post({ action: 'setAppearance', value: (event.currentTarget as HTMLSelectElement).value as AppSnapshot['appearance'] })}
              >
                <option value="system">System</option>
                <option value="light">Light</option>
                <option value="dark">Dark</option>
              </select>
            </label>
          </section>
          <section>
            <h2>Local runtime</h2>
            <label className="setting-row">
              <span><strong>Default model</strong><small>Used for new tasks. Choose a model for this task beside the composer. Context depends on the model and is fixed when the task starts.</small></span>
              <select
                aria-label="Default model for new tasks"
                value={snapshot.defaultModel}
                onChange={(event) => post({ action: 'setDefaultModel', modelID: (event.currentTarget as HTMLSelectElement).value })}
              >
                {snapshot.modelOptions.map((option) => <option key={option.id} value={option.id}>{option.label}</option>)}
              </select>
            </label>
            <p className={defaultModel?.highMemory ? 'model-note high-memory' : 'model-note'}>{defaultModel?.detail} Model files must be installed and loaded in LM Studio separately.</p>
            <div className="setting-row"><span><strong>Connection</strong><small>{snapshot.connection.label}</small></span><span className={`setting-state ${toneClass(snapshot.connection.tone)}`}><span />{snapshot.connection.state}</span></div>
          </section>
          <section>
            <h2>Agent interface</h2>
            <label className="setting-row">
              <span><strong>Show tool input and output</strong><small>Expand tool payloads in the transcript and inspector.</small></span>
              <input
                type="checkbox"
                checked={snapshot.showToolPayloads}
                onChange={(event) => post({ action: 'setShowToolPayloads', value: (event.currentTarget as HTMLInputElement).checked })}
              />
            </label>
            <div className="setting-row"><span><strong>Native computer tools</strong><small>New tasks use action-specific tools for app discovery, semantic inspection, focused-window captures, pointer, keyboard, and text input. Drag is unavailable in V2.</small></span><code>computer_v2_*</code></div>
            <div className="setting-row"><span><strong>Mutating computer actions</strong><small>Native enforcement always requires an explicit decision before input or app changes.</small></span><span className="locked-setting"><Icon name="check" size={14} /> Approval on</span></div>
          </section>
          <section>
            <h2>Computer use</h2>
            <div className="setting-row permission-row">
              <span><strong>Accessibility</strong><small>Required for semantic UI inspection and actions.</small></span>
              <span className="permission-controls">
                <span className={accessibilityGranted ? 'permission-status granted' : 'permission-status'}>{snapshot.permissions.accessibility}</span>
                <button
                  className="secondary-button permission-request-button"
                  disabled={accessibilityGranted}
                  onClick={() => post({ action: 'requestAccessibilityPermission' })}
                >
                  {accessibilityGranted ? 'Granted' : 'Request access'}
                </button>
              </span>
            </div>
            <div className="setting-row permission-row">
              <span><strong>Screen Recording</strong><small>Required for screenshots.</small></span>
              <span className="permission-controls">
                <span className={screenRecordingGranted ? 'permission-status granted' : 'permission-status'}>{snapshot.permissions.screenRecording}</span>
                <button
                  className="secondary-button permission-request-button"
                  disabled={screenRecordingGranted}
                  onClick={() => post({ action: 'requestScreenRecordingPermission' })}
                >
                  {screenRecordingGranted ? 'Granted' : 'Request access'}
                </button>
              </span>
            </div>
            <p className="permission-note">Click Request access to ask macOS. If access remains denied, LocalCodex opens System Settings, directly to Screen &amp; System Audio Recording when available. Add and enable LocalCodex in the screen-recording list, not System Audio Recording Only; then relaunch LocalCodex and refresh here. Local models cannot grant access, but once granted they can capture screenshots without a separate approval for each capture.</p>
            <button className="secondary-button refresh-button" onClick={() => post({ action: 'refreshPermissions' })}>Refresh permission status</button>
          </section>
        </div>
        <footer><span>Octane UI · system WebKit · native Swift runtime</span><button className="primary-button" onClick={() => post({ action: 'dismissSettings' })}>Done</button></footer>
      </section>
    </div>
  );
}

function LoadingView() {
  return (
    <main className="loading-view">
      <span className="loading-mark"><Icon name="sparkles" size={22} /></span>
      <strong>Starting LocalCodex</strong>
      <span>Connecting the native runtime…</span>
    </main>
  );
}

function BridgeUnavailableView() {
  return (
    <main className="loading-view" role="alert">
      <span className="loading-mark"><Icon name="info" size={22} /></span>
      <strong>Native bridge unavailable</strong>
      <span>Open this interface from the LocalCodex macOS application.</span>
    </main>
  );
}

const previewSnapshot: AppSnapshot | null = import.meta.env.DEV ? {
  revision: 1,
  selectedTaskID: 'preview',
  selectedEntryID: 'assistant',
  tasks: [
    {
      id: 'preview',
      title: 'Inspect Chrome locally',
      summary: 'Use Qwen and the native computer tool to inspect Chrome',
      status: 'Running',
      statusTone: 'blue',
      updatedAt: Date.now() / 1000 - 82,
      workspace: '/Users/local/Documents/LocalCodex',
      model: 'mlx-community/Qwen3.8-27B-4bit',
      modelSelectable: false,
      branch: 'local',
      entries: [
        { id: 'user', kind: 'user', title: 'You', body: 'Open Chrome and inspect the active page.', timestamp: Date.now() / 1000 - 76 },
        { id: 'reasoning', kind: 'reasoning', title: 'Working', body: 'Checking permissions and locating Chrome before observing its focused window.', timestamp: Date.now() / 1000 - 65 },
        {
          id: 'tool',
          kind: 'tool',
          title: 'Computer snapshot',
          body: 'Observed the Chrome Accessibility tree.',
          timestamp: Date.now() / 1000 - 40,
          tool: { name: 'computer', summary: 'Captured a bounded semantic snapshot', status: 'Succeeded', tone: 'green', input: '{"action":"snapshot","parameters":{"process_id":812}}', output: 'Chrome window observed' },
        },
        { id: 'assistant', kind: 'assistant', title: 'LocalCodex', body: 'Chrome is open and the active page is available through the native computer-use harness.', timestamp: Date.now() / 1000 - 18 },
      ],
    },
  ],
  pendingApprovalCount: 0,
  connection: { state: 'connected', label: 'Codex App Server · LM Studio', tone: 'green' },
  permissions: { accessibility: 'Not granted', screenRecording: 'Not granted' },
  appearance: 'system',
  defaultModel: 'mlx-community/Qwen3.8-27B-4bit',
  modelOptions: [
    { id: 'mlx-community/Qwen3.8-27B-4bit', label: 'Qwen3.8-27B · MLX 4-bit', detail: '16.1 GB model file. Current validated LocalCodex model.', highMemory: false },
    { id: 'lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit', label: 'Qwen3.6-35B-A3B · MLX 4-bit', detail: '20.4 GB model file. Very tight on this 24 GB Mac; download and load in LM Studio separately.', highMemory: true },
    { id: 'lmstudio-community/Qwen3.5-9B-MLX-4bit', label: 'Qwen3.5-9B · MLX 4-bit', detail: '5.98 GB model files. Lower-memory option; download and load in LM Studio separately.', highMemory: false },
    { id: 'lmstudio-community/Qwen3.5-4B-MLX-4bit', label: 'Qwen3.5-4B · MLX 4-bit', detail: '3.06 GB model files. Smallest option; download and load in LM Studio separately.', highMemory: false },
  ],
  showToolPayloads: true,
  isInspectorPresented: true,
  isSettingsPresented: false,
} : null;

export function App() {
  const nativeHost = Boolean(window.webkit?.messageHandlers?.localCodex);
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(nativeHost ? null : previewSnapshot);
  const [search, setSearch] = useState('');

  useEffect(() => {
    window.__localCodexReceiveState = (next) => {
      setSnapshot((current) => (!current || next.revision >= current.revision ? next : current));
    };
    post({ action: 'ready' });
    return () => {
      delete window.__localCodexReceiveState;
    };
  }, []);

  useEffect(() => {
    const appearance = snapshot?.appearance ?? 'system';
    document.documentElement.dataset.appearance = appearance;
  }, [snapshot?.appearance]);

  useEffect(() => {
    if (!snapshot?.selectedTaskID) return;
    const frame = requestAnimationFrame(() => {
      const scroll = document.getElementById('conversation-scroll');
      if (scroll) scroll.scrollTop = scroll.scrollHeight;
    });
    return () => cancelAnimationFrame(frame);
  }, [snapshot?.selectedTaskID, snapshot?.selectedTaskID ? snapshot.tasks.find((task) => task.id === snapshot.selectedTaskID)?.entries.length : 0]);

  if (!snapshot) return nativeHost ? <LoadingView /> : <BridgeUnavailableView />;

  const task = snapshot.tasks.find((candidate) => candidate.id === snapshot.selectedTaskID);
  return (
    <div className="app-shell">
      <Sidebar snapshot={snapshot} search={search} setSearch={setSearch} />
      <main className="workspace">
        <TaskToolbar snapshot={snapshot} task={task} />
        {task ? (
          <Conversation snapshot={snapshot} task={task} />
        ) : (
          <div className="no-task-view">
            <span><Icon name="sparkles" size={24} /></span>
            <h1>Start a local task</h1>
            <p>Create a task to work with Codex App Server and the configured local model.</p>
            <button className="primary-button" onClick={() => post({ action: 'createTask' })}><Icon name="plus" size={15} /> New task</button>
          </div>
        )}
      </main>
      {task && snapshot.isInspectorPresented ? <Inspector snapshot={snapshot} task={task} /> : null}
      <SettingsModal snapshot={snapshot} />
    </div>
  );
}
