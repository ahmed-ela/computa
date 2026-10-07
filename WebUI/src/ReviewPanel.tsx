import { useEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Input } from '@octanejs/shadcn/Input';
import { Textarea } from '@octanejs/shadcn/Textarea';
import { NativeSelect, NativeSelectOption } from '@octanejs/shadcn/NativeSelect';
import { Icon } from './Icon';
import { parseUnifiedDiff, reconcileReviewPresentation, reviewFeedback, reviewFileLabel, reviewPresentationIdentity, splitDiffLines, type DiffLine, type ParsedDiff, type ReviewPresentationState } from './reviewDiff';
import type { NativeAction, ReviewFile, ReviewOperation, ReviewScope, ReviewState } from './types';

const scopes: [ReviewScope, string][] = [
  ['lastTurn', 'Last turn'], ['unstaged', 'Unstaged'], ['staged', 'Staged'],
  ['branch', 'Against branch'], ['commit', 'Commit'],
];
const statusLabels: Record<ReviewFile['status'], string> = {
  added: 'Added', deleted: 'Deleted', modified: 'Modified', renamed: 'Renamed',
  copied: 'Copied', untracked: 'Untracked', typeChanged: 'Type changed', unmerged: 'Conflict',
};

async function copyText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try { await navigator.clipboard.writeText(text); return; } catch { /* Native custom-scheme WebKit may need its copy fallback. */ }
  }
  const previous = document.activeElement as HTMLElement | null;
  const field = document.createElement('textarea');
  field.value = text;
  field.style.cssText = 'position:fixed;left:-10000px;top:0';
  document.body.appendChild(field);
  field.select();
  const copied = document.execCommand('copy');
  field.remove();
  previous?.focus();
  if (!copied) throw new Error('Copy failed. Select the patch text and copy it manually.');
}

interface FeedbackLocation { line: number; side: 'old' | 'new' }

function LineNumber({ number, side, path, onFeedback }: {
  number?: number; side: 'old' | 'new'; path: string;
  onFeedback: (location: FeedbackLocation) => void;
}) {
  return <td className="diff-number">{number == null ? null : (
    <button type="button" title="Add review feedback" aria-label={`Add feedback for ${path}, ${side === 'old' ? 'previous' : 'new'} line ${number}`}
      onClick={() => onFeedback({ line: number, side })}>{number}</button>
  )}</td>;
}

function Sign({ line }: { line?: DiffLine }) {
  return <td className="diff-sign" aria-hidden="true">{line?.kind === 'addition' ? '+' : line?.kind === 'deletion' ? '−' : ''}</td>;
}

export function DiffView({ file, parsed, split, wrap, allowHunkMutation, onMutation, onFeedback, collapsedHunks, onHunkCollapse }: {
  file: ReviewFile; parsed: ParsedDiff; split: boolean; wrap: boolean;
  allowHunkMutation: ReviewOperation[];
  onMutation: (operation: ReviewOperation, hunkID: string) => void;
  onFeedback: (location: FeedbackLocation) => void;
  collapsedHunks?: Record<string, boolean>;
  onHunkCollapse?: (key: string, closed: boolean) => void;
}) {
  const [localClosed, setLocalClosed] = useState<Record<string, boolean>>({});
  const closed = collapsedHunks ?? localClosed;
  if (file.binary) return <p className="review-notice">Binary file changed. Its contents cannot be displayed as a text diff.</p>;
  return <div className={`diff-view ${split ? 'is-split' : 'is-unified'} ${wrap ? 'is-wrapped' : ''}`}>
    {file.truncated ? <p className="review-notice" role="status">This file’s diff was truncated. Changes are read-only until a complete snapshot is available.</p> : null}
    {parsed.warning ? <p className="review-notice" role="status">{parsed.warning}</p> : null}
    {parsed.hunks.length === 0 ? (
      <div className="review-metadata"><p>No text hunks. The file’s metadata or type changed.</p><pre tabIndex={0} aria-label={`Patch metadata for ${file.path}`}>{file.diff}</pre></div>
    ) : parsed.hunks.map((hunk, index) => {
      const native = file.hunks[index];
      const key = `${file.id}:${native?.id ?? `${hunk.header}:${index}`}`;
      const actionable = native?.header === hunk.header && native.oldStart === hunk.oldStart && native.newStart === hunk.newStart
        && file.hunks.length === parsed.hunks.length && file.status === 'modified' && !file.truncated && !parsed.warning && !parsed.limited;
      return <section className="diff-hunk" key={key}>
        <div className="diff-hunk-heading">
          <button type="button" className="diff-hunk-toggle" aria-expanded={!closed[key]} aria-label={`${closed[key] ? 'Expand' : 'Collapse'} hunk ${index + 1}`}
            onClick={() => onHunkCollapse ? onHunkCollapse(key, !closed[key]) : setLocalClosed((current) => ({ ...current, [key]: !current[key] }))}>
            <span aria-hidden="true">{closed[key] ? '▸' : '▾'}</span><code>{hunk.header}</code>
          </button>
          {actionable ? <div className="review-hunk-actions">{allowHunkMutation.map((operation) => (
            <Button key={operation} variant="ghost" size="sm" aria-label={`${operation} hunk ${index + 1} in ${file.path}`}
              onClick={() => onMutation(operation, native.id)}>{operation === 'stage' ? 'Stage hunk' : operation === 'unstage' ? 'Unstage hunk' : 'Revert hunk'}</Button>
          ))}</div> : null}
        </div>
        {!closed[key] ? <div className="diff-table-scroll" tabIndex={0} role="region" aria-label={`Hunk ${index + 1} in ${file.path}`}>
          <table className="diff-table" aria-label={`${split ? 'Split' : 'Unified'} diff for ${file.path}`}>
            <colgroup>{split ? <><col className="diff-column-number" /><col className="diff-column-sign" /><col /><col className="diff-column-number" /><col className="diff-column-sign" /><col /></> : <><col className="diff-column-number" /><col className="diff-column-number" /><col className="diff-column-sign" /><col /></>}</colgroup>
            <thead className="sr-only"><tr>{split ? <><th>Previous line</th><th>Change</th><th>Previous content</th><th>New line</th><th>Change</th><th>New content</th></> : <><th>Previous line</th><th>New line</th><th>Change</th><th>Content</th></>}</tr></thead>
            <tbody>{split ? splitDiffLines(hunk.lines).map((row, rowIndex) => row.note ? (
              <tr className="diff-note" key={rowIndex}><td colSpan={6}>{row.note}</td></tr>
            ) : <tr key={rowIndex}>
              <LineNumber number={row.before?.oldNumber} side="old" path={file.path} onFeedback={onFeedback} />
              <Sign line={row.before} />
              <td className={`diff-code ${row.before ? `diff-${row.before.kind}` : 'diff-absent'}`}>{row.before?.text ?? ''}</td>
              <LineNumber number={row.after?.newNumber} side="new" path={file.path} onFeedback={onFeedback} />
              <Sign line={row.after} />
              <td className={`diff-code ${row.after ? `diff-${row.after.kind}` : 'diff-absent'}`}>{row.after?.text ?? ''}</td>
            </tr>) : hunk.lines.map((line, rowIndex) => line.kind === 'note' ? (
              <tr className="diff-note" key={rowIndex}><td colSpan={4}>{line.text}</td></tr>
            ) : <tr className={`diff-${line.kind}`} key={rowIndex}>
              <LineNumber number={line.oldNumber} side="old" path={file.path} onFeedback={onFeedback} />
              <LineNumber number={line.newNumber} side="new" path={file.path} onFeedback={onFeedback} />
              <Sign line={line} /><td className="diff-code">{line.text}</td>
            </tr>)}</tbody>
          </table>
        </div> : null}
      </section>;
    })}
  </div>;
}

export function ReviewPanel({ taskID, review, busy, post, onFeedback }: {
  taskID: string; review?: ReviewState; busy: boolean;
  post: (action: NativeAction) => void; onFeedback: (text: string) => void;
}) {
  const current = review?.taskID === taskID ? review : undefined;
  const snapshot = current?.snapshot;
  const identity = reviewPresentationIdentity(taskID, snapshot);
  const [fileID, setFileID] = useState<string>();
  const [filter, setFilter] = useState('');
  const [split, setSplit] = useState(false);
  const [wrap, setWrap] = useState(false);
  const [reference, setReference] = useState(current?.reference ?? '');
  const [presentation, setPresentation] = useState<ReviewPresentationState>(() => ({ identity, viewed: {}, files: {}, hunks: {} }));
  const currentPresentation = reconcileReviewPresentation(presentation, identity);
  const viewed = currentPresentation.viewed;
  const collapsed = currentPresentation.files;
  const [copyStatus, setCopyStatus] = useState('');
  const [feedback, setFeedback] = useState<{ fileID: string; location: FeedbackLocation; text: string }>();
  const listRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => { setReference(current?.reference ?? ''); }, [taskID, current?.reference]);
  useEffect(() => {
    setCopyStatus(''); setFeedback(undefined);
  }, [snapshot?.id]);
  useEffect(() => { setPresentation((value) => reconcileReviewPresentation(value, identity)); }, [identity]);
  const files = snapshot?.files ?? [];
  const filtered = files.filter((file) => reviewFileLabel(file).toLocaleLowerCase().includes(filter.toLocaleLowerCase()));
  const selected = files.find((file) => file.id === fileID) ?? filtered[0] ?? files[0];
  const selectedKey = `${identity}:${selected?.id}`;
  const parsed = selected ? parseUnifiedDiff(selected.diff) : undefined;
  const total = files.reduce((counts, file) => ({ additions: counts.additions + file.additions, deletions: counts.deletions + file.deletions }), { additions: 0, deletions: 0 });
  const loading = current?.loading ?? false;
  const fresh = Boolean(snapshot && snapshot.scope === current?.scope && (
    current.scope !== 'branch' && current.scope !== 'commit' || (snapshot.reference ?? '') === (current.reference ?? '')
  ));
  const disabled = busy || loading || !fresh || Boolean(current?.error);
  const operations: ReviewOperation[] = disabled ? [] : [
    ...(snapshot?.canStage ? ['stage' as const] : []),
    ...(snapshot?.canUnstage ? ['unstage' as const] : []),
    ...(snapshot?.canRevert ? ['revert' as const] : []),
  ];
  const mutate = (operation: ReviewOperation, target?: ReviewFile, hunkID?: string) => {
    if (!snapshot || disabled || (target && (target.truncated || target.status === 'unmerged'))) return;
    post({ action: 'reviewMutation', taskID, snapshotID: snapshot.id, operation, ...(target ? { fileID: target.id } : {}), ...(hunkID ? { hunkID } : {}) });
  };
  const copy = async (text: string) => {
    try { await copyText(text); setCopyStatus('Diff copied.'); } catch (error) { setCopyStatus(error instanceof Error ? error.message : 'Copy failed.'); }
  };
  const setScope = (scope: ReviewScope) => post({ action: 'setReviewScope', taskID, scope });
  const compare = () => { if (reference.trim()) post({ action: 'setReviewReference', taskID, reference: reference.trim() }); };
  return <section className="review-panel" aria-label="File changes" aria-busy={loading}>
    <header className="review-header">
      <div className="review-title"><strong>Changes</strong><span>{files.length} {files.length === 1 ? 'file' : 'files'}</span><span className="diff-additions">+{total.additions}</span><span className="diff-deletions">−{total.deletions}</span></div>
      <div className="review-header-actions">
        <Button variant="ghost" size="sm" disabled={loading} onClick={() => post({ action: 'refreshReview', taskID })}>Refresh</Button>
        <Button variant="ghost" size="icon" aria-label="Close changes" onClick={() => post({ action: 'toggleReview' })}><Icon name="x" size={16} /></Button>
      </div>
    </header>
    <div className="review-options">
      <NativeSelect aria-label="Changes scope" value={current?.scope ?? 'lastTurn'} disabled={loading} onInput={(event: Event) => setScope((event.currentTarget as HTMLSelectElement).value as ReviewScope)}>
        {scopes.map(([value, label]) => <NativeSelectOption key={value} value={value}>{label}</NativeSelectOption>)}
      </NativeSelect>
      {current?.scope === 'branch' || current?.scope === 'commit' ? <div className="review-reference">
        <Input aria-label={current.scope === 'branch' ? 'Compare branch' : 'Commit reference'} value={reference} placeholder={current.scope === 'branch' ? 'main' : 'Commit SHA or reference'}
          onInput={(event) => setReference((event.currentTarget as HTMLInputElement).value)}
          onKeyDown={(event) => { if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); compare(); } }} />
        <Button variant="outline" size="sm" disabled={loading || !reference.trim()} onClick={compare}>Compare</Button>
      </div> : null}
      <div className="review-display-options">
        <Button variant="ghost" size="sm" aria-pressed={!split} onClick={() => setSplit(false)}>Unified</Button>
        <Button variant="ghost" size="sm" aria-pressed={split} onClick={() => setSplit(true)}>Split</Button>
        <Button variant="ghost" size="sm" aria-pressed={wrap} onClick={() => setWrap((value) => !value)}>Wrap</Button>
      </div>
    </div>
    <div className="review-scope-note">{current?.scope === 'lastTurn' ? 'Recorded edits from the last turn. Current files may have changed since then.' : current?.scope === 'unstaged' || current?.scope === 'staged' ? 'Current workspace changes include your edits and agent edits.' : 'This comparison is read-only.'}</div>
    {current?.error ? <div className="review-error" role="alert">{current.error}</div> : null}
    {copyStatus ? <div className="review-copy-status" role="status">{copyStatus}</div> : null}
    {loading ? <div className="review-loading" role="status">Loading changes…</div> : null}
    {!loading && !snapshot ? <div className="review-empty"><Icon name="edit" size={24} /><p>{current?.error ? 'Changes could not be loaded.' : 'Choose a scope and refresh to review file changes.'}</p></div> : null}
    {!loading && snapshot && files.length === 0 ? <div className="review-empty"><Icon name="check" size={24} /><p>No changes in this scope.</p></div> : null}
    {snapshot && files.length > 0 ? <div className="review-content">
      <nav className="review-file-navigation" aria-label="Changed files">
        <Input className="review-file-filter" aria-label="Filter changed files" placeholder="Filter files…" value={filter} onInput={(event) => setFilter((event.currentTarget as HTMLInputElement).value)} />
        <div className="review-file-list" ref={listRef} onKeyDown={(event) => {
          if (!['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
          const buttons = Array.from(listRef.current?.querySelectorAll<HTMLButtonElement>('button') ?? []);
          if (!buttons.length) return;
          const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
          const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : event.key === 'ArrowDown' ? Math.min(buttons.length - 1, index + 1) : Math.max(0, index - 1);
          event.preventDefault(); buttons[next]?.focus(); buttons[next]?.click();
        }}>
          {filtered.map((file) => <button type="button" key={file.id} className={`review-file-row ${file.id === selected?.id ? 'selected' : ''}`} aria-current={file.id === selected?.id ? 'true' : undefined} onClick={() => { setFileID(file.id); setFeedback(undefined); }}>
            <span className="review-file-path" title={reviewFileLabel(file)}>{reviewFileLabel(file)}</span>
            <span className="review-file-summary"><span>{statusLabels[file.status]}{file.binary ? ' · Binary' : ''}</span><span className="diff-additions">+{file.additions}</span><span className="diff-deletions">−{file.deletions}</span>{viewed[file.id] ? <Icon name="check" size={12} /> : null}</span>
          </button>)}
          {filtered.length === 0 ? <p className="review-filter-empty">No matching files.</p> : null}
        </div>
        <div className="review-all-actions">
          <Button variant="outline" size="sm" disabled={loading} onClick={() => void copy(files.map((file) => file.diff).join('\n'))}>Copy all diffs</Button>
          {operations.map((operation) => <Button key={operation} variant="outline" size="sm" disabled={files.some((file) => file.truncated || file.status === 'unmerged')} onClick={() => mutate(operation)}>{operation === 'stage' ? 'Stage all' : operation === 'unstage' ? 'Unstage all' : 'Revert all'}</Button>)}
        </div>
      </nav>
      {selected && parsed ? <div className="review-file-detail">
        <div className="review-file-heading">
          <button type="button" className="review-file-collapse" aria-expanded={!collapsed[selected.id]} onClick={() => setPresentation((value) => {
            const base = reconcileReviewPresentation(value, identity);
            return { ...base, files: { ...base.files, [selected.id]: !base.files[selected.id] } };
          })}><span aria-hidden="true">{collapsed[selected.id] ? '▸' : '▾'}</span><strong title={reviewFileLabel(selected)}>{reviewFileLabel(selected)}</strong></button>
          <label className="review-viewed"><input type="checkbox" checked={Boolean(viewed[selected.id])} onInput={(event) => {
            const checked = (event.currentTarget as HTMLInputElement).checked;
            setPresentation((value) => { const base = reconcileReviewPresentation(value, identity); return { ...base, viewed: { ...base.viewed, [selected.id]: checked } }; });
          }} /> Viewed</label>
        </div>
        <div className="review-file-actions">
          <span>{statusLabels[selected.status]}</span><span className="diff-additions">+{selected.additions}</span><span className="diff-deletions">−{selected.deletions}</span>
          <Button variant="ghost" size="sm" disabled={disabled || selected.binary || selected.status === 'deleted'} onClick={() => post({ action: 'openReviewFile', taskID, snapshotID: snapshot.id, fileID: selected.id })}>Open file</Button>
          <Button variant="ghost" size="sm" disabled={loading} onClick={() => void copy(selected.diff)}>Copy diff</Button>
          {operations.map((operation) => <Button key={operation} variant="ghost" size="sm" disabled={selected.truncated || selected.status === 'unmerged'} onClick={() => mutate(operation, selected)}>{operation === 'stage' ? 'Stage file' : operation === 'unstage' ? 'Unstage file' : 'Revert file'}</Button>)}
        </div>
        {!collapsed[selected.id] ? <div className="review-diff-scroll">
          <DiffView key={selectedKey} file={selected} parsed={parsed} split={split} wrap={wrap} allowHunkMutation={operations}
            collapsedHunks={currentPresentation.hunks} onHunkCollapse={(key, closed) => setPresentation((value) => {
              const base = reconcileReviewPresentation(value, identity); return { ...base, hunks: { ...base.hunks, [key]: closed } };
            })}
            onMutation={(operation, hunkID) => mutate(operation, selected, hunkID)} onFeedback={(location) => setFeedback({ fileID: selected.id, location, text: '' })} />
        </div> : <p className="review-notice">File diff collapsed.</p>}
        {feedback?.fileID === selected.id ? <div className="review-feedback">
          <label htmlFor="review-feedback-text">Feedback on {selected.path}:{feedback.location.line}{feedback.location.side === 'old' ? ' (previous version)' : ''}</label>
          <Textarea id="review-feedback-text" aria-label="Review feedback" rows={2} maxLength={10000} value={feedback.text} placeholder="Describe what should change…"
            onInput={(event) => setFeedback({ ...feedback, text: (event.currentTarget as HTMLTextAreaElement).value })} />
          <div><span>This adds a draft to your message.</span><Button variant="ghost" size="sm" onClick={() => setFeedback(undefined)}>Cancel</Button><Button size="sm" disabled={!feedback.text.trim()} onClick={() => {
            onFeedback(reviewFeedback(selected.path, feedback.location.line, feedback.location.side, feedback.text)); setFeedback(undefined);
          }}>Add to message</Button></div>
        </div> : null}
      </div> : null}
    </div> : null}
  </section>;
}
