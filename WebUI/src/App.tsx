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
  | 'file'
  | 'gear'
  | 'info'
  | 'inspect'
  | 'more'
  | 'new'
  | 'plus'
  | 'search'
  | 'send'
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
  file: 'M7 3h7l4 4v14H7V3Zm7 0v5h5',
  gear: 'M12 8.7a3.3 3.3 0 1 0 0 6.6 3.3 3.3 0 0 0 0-6.6Zm8 3.3-2.1-1 .1-2.3-2.1-2.1-2.3.1-1-2.1H9.4l-1 2.1-2.3-.1L4 8.7l.1 2.3L2 12l2.1 1-.1 2.3 2.1 2.1 2.3-.1 1 2.1h3.2l1-2.1 2.3.1 2.1-2.1-.1-2.3 2.1-1Z',
  info: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Zm0-9v5m0-9h.01',
  inspect: 'M4 4h16v16H4V4Zm11 0v16M18 8h-1m1 4h-1m1 4h-1',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  new: 'M5 19h4L19 9l-4-4L5 15v4Zm9-13 4 4M4 4h6',
  plus: 'M12 5v14M5 12h14',
  search: 'm21 21-4.4-4.4m2.4-5.1a7.5 7.5 0 1 1-15 0 7.5 7.5 0 0 1 15 0Z',
  send: 'm5 12 14-7-4 14-3-6-7-1Zm7 1 7-8',
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
  const canSend = value.trim().length > 0;

  const submit = () => {
    const prompt = value.trim();
    if (!prompt) return;
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
            <span className="model-label" title={task.model}>{task.model}</span>
            <button className="voice-button" aria-label="Voice input" title="Voice input">⌁</button>
            <button className="send-button" disabled={!canSend} aria-label="Send prompt" onClick={submit}>
              <Icon name="send" size={16} />
            </button>
          </div>
        </div>
      </div>
      <span className="composer-hint">⌘↩ to send · {snapshot.connection.label}</span>
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
              <h1>What should we build?</h1>
              <p>Ask LocalCodex to inspect files, write code, or use approved desktop tools.</p>
              <div className="suggestion-grid">
                <button onClick={() => post({ action: 'submitPrompt', prompt: 'Inspect this workspace and explain its architecture.' })}>Explain this workspace</button>
                <button onClick={() => post({ action: 'submitPrompt', prompt: 'Run the tests and fix any failures.' })}>Run and fix tests</button>
                <button onClick={() => post({ action: 'submitPrompt', prompt: 'Find the highest-impact improvement and implement it.' })}>Improve the project</button>
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
            <div className="setting-row"><span><strong>Model</strong><small>Configured in the native App Server adapter.</small></span><code>{snapshot.defaultModel}</code></div>
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
            <div className="setting-row"><span><strong>Computer-action approvals</strong><small>Native enforcement always requires an explicit decision.</small></span><span className="locked-setting"><Icon name="check" size={14} /> Always on</span></div>
          </section>
          <section>
            <h2>Computer use</h2>
            <div className="setting-row"><span><strong>Accessibility</strong><small>Required for semantic UI inspection and actions.</small></span><span>{snapshot.permissions.accessibility}</span></div>
            <div className="setting-row"><span><strong>Screen Recording</strong><small>Required for window discovery and captures.</small></span><span>{snapshot.permissions.screenRecording}</span></div>
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
      title: 'Build the Octane interface',
      summary: 'Replace the native presentation layer with a WebKit UI',
      status: 'Running',
      statusTone: 'blue',
      updatedAt: Date.now() / 1000 - 82,
      workspace: '/Users/local/Documents/LocalCodex',
      model: 'Qwen3.8-27B · 4-bit',
      branch: 'local',
      entries: [
        { id: 'user', kind: 'user', title: 'You', body: 'Build this interface with Octane and WebKit.', timestamp: Date.now() / 1000 - 76 },
        { id: 'reasoning', kind: 'reasoning', title: 'Working', body: 'Inspecting the native state boundary and preparing a safe bridge.', timestamp: Date.now() / 1000 - 65 },
        {
          id: 'tool',
          kind: 'tool',
          title: 'Build web assets',
          body: 'Compiled the Octane SPA.',
          timestamp: Date.now() / 1000 - 40,
          tool: { name: 'bun run build', summary: 'Compiled Octane for WKWebView', status: 'Succeeded', tone: 'green', input: 'bun run build', output: 'build complete' },
        },
        { id: 'assistant', kind: 'assistant', title: 'LocalCodex', body: 'The presentation layer now matches the Codex desktop structure while the privileged runtime remains native Swift.', timestamp: Date.now() / 1000 - 18 },
      ],
    },
  ],
  pendingApprovalCount: 0,
  connection: { state: 'connected', label: 'Codex App Server · LM Studio', tone: 'green' },
  permissions: { accessibility: 'Not granted', screenRecording: 'Not granted' },
  appearance: 'system',
  defaultModel: 'Qwen3.8-27B 4-bit',
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
