import { useEffect, useLayoutEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Textarea } from '@octanejs/shadcn/Textarea';
import { ResponseMarkdown } from './ResponseMarkdown';
import { Icon } from './Icon';
import { copyText } from './clipboard';
import { shouldSubmitPromptKey } from './promptQueue';
import { activityLabel, activityText, entryKey, CodexHistoryWindow } from './codexTranscript';
import type { CodexEntry, CodexPage, HistoryDirection, UserPart } from './codexTranscript';
import type { DesktopReader } from './types';
import { codexModelReady, observeCodexModel } from './codexModelSelection';
import type { CodexModelIntent, CodexModelState } from './codexModelSelection';

function call<T>(reader: DesktopReader, action: string, fields: Record<string, string> = {}): Promise<T> {
  const bridge = window.webkit?.messageHandlers?.codexConversation;
  if (!bridge) return Promise.reject(new Error('Codex is unavailable.'));
  return bridge.postMessage({action, thread: reader.id, selection: reader.request, ...fields}) as Promise<T>;
}
const errorText = (error: unknown) => error instanceof Error ? error.message : String(error);

type ModelCatalog = {state: CodexModelState; choices: {model: string; displayName: string}[]};

function TranscriptEntry({entry, reader}: {entry: CodexEntry; reader: DesktopReader}) {
  const [open, setOpen] = useState(false);
  const [detail, setDetail] = useState<CodexEntry | null>(null);
  const [error, setError] = useState('');
  const item = entry.item;
  useEffect(() => {
    if (!open || !entry.outputDeferred) return;
    let active = true;
    setError('');
    void call<{data: CodexEntry[]}>(reader, 'item', {turn: entry.turnId, item: item.id}).then(result => {
      const full = result.data.find(row => entryKey(row) === entryKey(entry));
      if (!full) throw new Error('Codex could not load this item.');
      if (active) setDetail(full);
    }).catch(e => { if (active) setError(errorText(e)); });
    return () => { active = false; };
  }, [open, entry.outputDeferred, reader.request, entry.turnId, item.id]);
  if (item.type === 'agentMessage') return <article><strong>Codex</strong><ResponseMarkdown text={String(item.text ?? '')} /></article>;
  if (item.type === 'userMessage') return <article><strong>You</strong>
    {(item.content as UserPart[] ?? []).map((part, i) =>
      part.type === 'image' && /^data:image\/(png|jpeg|webp|gif);base64,/i.test(part.url ?? '')
        ? <img key={i} className="desktop-attachment" alt="Attached image" src={part.url} />
        : <p key={i} className="desktop-reader-user">{part.text ?? part.name ?? part.path ?? part.fileId ?? ('Attached ' + part.type)}</p>)}</article>;
  return <details onToggle={event => setOpen((event.currentTarget as HTMLDetailsElement).open)}>
    <summary>{activityLabel(item)}</summary>
    {open && <pre>{error || activityText(detail?.item ?? item)}</pre>}
  </details>;
}

function Chat({reader}: {reader: DesktopReader}) {
  const [entries, setEntries] = useState<CodexEntry[]>([]);
  const navigate = useRef<(direction: HistoryDirection, jump?: boolean) => void>(() => {});
  const available = useRef({before:false, after:false});
  const [atFirst, setAtFirst] = useState(false);
  const [atLast, setAtLast] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [historyError, setHistoryError] = useState('');
  const [queue, setQueue] = useState<string[]>([]);
  const [draft, setDraft] = useState('');
  const [copiedDraft, setCopiedDraft] = useState<string | null>(null);
  const [catalog, setCatalog] = useState<ModelCatalog | null>(null);
  const [modelError, setModelError] = useState('');
  const [catalogError, setCatalogError] = useState('');
  const [intent, setIntent] = useState<CodexModelIntent>({kind:'follow'});
  const modelReady = codexModelReady(intent, catalog?.state);
  const modelRevision = useRef(0);
  const modelBusy = useRef(false);
  const activeReader = useRef(true);
  useEffect(() => {
    activeReader.current = true;
    let pending = false, haveCatalog = false;
    const refresh = async (full = false) => {
      if (pending || modelBusy.current) return;
      pending = true;
      const revision = modelRevision.current;
      try {
        const next = full || !haveCatalog ? await call<ModelCatalog>(reader, 'models') : null;
        const state = next ? next.state : await call<CodexModelState>(reader, 'currentModel');
        if (activeReader.current && revision === modelRevision.current) {
          setCatalogError('');
          if (next) { haveCatalog = true; setCatalog(next); }
          else setCatalog(previous => previous && (previous.state.current !== state.current || previous.state.live !== state.live) ? {...previous, state} : previous);
          setIntent(previous => observeCodexModel(previous, state));
        }
      } catch (error) { if (activeReader.current && revision === modelRevision.current) setCatalogError(errorText(error)); }
      finally { pending = false; }
    };
    void refresh();
    const onFocus = () => { void refresh(true); };
    window.addEventListener('focus', onFocus);
    const interval = setInterval(() => { void refresh(); }, 5000);
    return () => { activeReader.current = false; clearInterval(interval); window.removeEventListener('focus', onFocus); };
  }, [reader.request]);
  const changeModel = async (model: string) => {
    if (modelBusy.current || busy.current || !catalog) return;
    modelBusy.current = true;
    ++modelRevision.current;
    setIntent({kind:'switching', model}); setModelError('');
    try {
      const result = await call<string>(reader, 'changeModel', {model, ...(catalog.state.current ? {expected: catalog.state.current} : {})});
      if (!activeReader.current) return;
      if (result === 'changed') {
        setCatalog({...catalog, state: {current:model, live:true}}); setIntent({kind:'bound', model});
      } else if (result === 'openInCodex') {
        setIntent({kind:'handoff', model});
      } else throw new Error('Codex did not confirm the model change.');
    } catch (error) {
      if (activeReader.current) { setModelError(errorText(error)); setIntent({kind:'unconfirmed', model}); }
    } finally { modelBusy.current = false; }
  };
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState('');
  const [wakeFailed, setWakeFailed] = useState(false);
  const [uncertain, setUncertain] = useState<{id:string; text:string} | null>(null);
  const busy = useRef(false);
  const update = useRef<() => void>(() => {});
  const scroller = useRef<HTMLElement | null>(null);
  const followBottom = useRef(true);
  const anchor = useRef<{key: string; top: number} | null>(null);
  useEffect(() => {
    let active = true, version = 0, fetching = false;
    let lastHead = '';
    const history = new CodexHistoryWindow();
    const read = (direction: HistoryDirection, cursor?: string) =>
      call<CodexPage>(reader, 'page', {direction, ...(cursor ? {cursor} : {})});
    const publish = () => {
      available.current = {before: !!history.before, after: !!history.after};
      setAtFirst(!history.before); setAtLast(!history.after);
      setEntries(history.entries); setLoaded(true); setHistoryError('');
    };
    const rememberAnchor = () => {
      const view = scroller.current;
      if (!view) return;
      const top = view.getBoundingClientRect().top;
      const node = Array.from(view.querySelectorAll<HTMLElement>('[data-codex-entry]')).find(e => e.getBoundingClientRect().bottom > top);
      if (node?.dataset.codexEntry) anchor.current = {key:node.dataset.codexEntry, top:node.getBoundingClientRect().top};
    };
    const move = async (direction: HistoryDirection, jump = false, background = false) => {
      if (!active || (fetching && (!jump || background))) return;
      const cursor = jump ? undefined : (direction === 'desc' ? history.before : history.after);
      if (!jump && !cursor) return;
      const token = ++version;
      fetching = true;
      try {
        const page = await read(direction, cursor ?? undefined);
        if (!active || token !== version || (background && !followBottom.current)) return;
        if (jump && direction === 'desc') {
          const head = JSON.stringify(page.data);
          if (background && lastHead === head) return;
          lastHead = head;
        }
        if (jump) {
          anchor.current = null;
          followBottom.current = direction === 'desc';
          if (!followBottom.current && scroller.current) scroller.current.scrollTop = 0;
        } else rememberAnchor();
        if (!history.accept(page, direction, cursor ?? undefined)) return;
        publish();
        // Prefetch a second page on initial open. Further pages follow scrolling.
        if (jump && direction === 'desc' && history.before) {
          const before = history.before;
          const next = await read('desc', before);
          if (!active || token !== version) return;
          if (!followBottom.current) rememberAnchor();
          if (history.accept(next, 'desc', before)) publish();
        }
      } catch (e) { if (active && token === version) setHistoryError(errorText(e)); }
      finally { if (token === version) fetching = false; }
    };
    let checkingQueue = false;
    const refresh = () => {
      if (!active) return;
      if (!checkingQueue) {
        checkingQueue = true;
        void call<string[]>(reader, 'queue').then(ids => { if (active) setQueue(ids); })
          .catch(e => { if (active) setSendError(errorText(e)); }).finally(() => { checkingQueue = false; });
      }
      if (followBottom.current && !history.after) void move('desc', true, true);
    };
    navigate.current = move;
    update.current = refresh;
    refresh();
    const timer = setInterval(refresh, 3000);
    return () => { active = false; clearInterval(timer); update.current = () => {}; navigate.current = () => {}; };
  }, [reader.request]);
  useLayoutEffect(() => {
    const view = scroller.current;
    if (!view) return;
    if (anchor.current) {
      const previous = anchor.current;
      const first = Array.from(view.querySelectorAll<HTMLElement>('[data-codex-entry]')).find(n => n.dataset.codexEntry === previous.key);
      if (first) view.scrollTop += first.getBoundingClientRect().top - previous.top;
      anchor.current = null;
    } else if (followBottom.current) view.scrollTop = view.scrollHeight;
  }, [entries]);
  useEffect(() => {
    if (uncertain && (queue.includes(uncertain.id) || entries.some(e => e.item.clientId === uncertain.id))) {
      setDraft(value => value === uncertain.text ? '' : value);
      setUncertain(null); setSendError('');
    }
  }, [uncertain, queue, entries]);
  const send = async () => {
    if (busy.current || modelBusy.current || !modelReady || !draft.trim() || !loaded || uncertain?.text === draft) return;
    busy.current = true;
    setSending(true); setSendError('');
    try {
      const submission = crypto.randomUUID();
      const receipt = await call<string>(reader, 'send', {text:draft, submission, ...(intent.kind === 'bound' ? {model:intent.model} : catalog?.state.current ? {expected:catalog.state.current} : {})});
      if (receipt === 'unconfirmed') {
        setUncertain({id:submission, text:draft});
        setSendError('Delivery is unconfirmed. Check this chat in Codex before sending the same message again.');
        return;
      }
      setUncertain(null); setDraft(''); if (receipt !== 'started') setQueue(previous => [...previous, submission]); setWakeFailed(receipt === 'queuedWakeFailed');
      followBottom.current = true;
      navigate.current('desc', true);
    } catch (e) { setSendError(errorText(e)); }
    finally { busy.current = false; setSending(false); update.current(); }
  };
  return <>
    <div className="desktop-history-navigation" aria-label="Conversation history">
      <Button variant="ghost" disabled={!loaded} onClick={() => {
        if (atFirst && scroller.current) { followBottom.current = false; scroller.current.scrollTop = 0; }
        else navigate.current('asc', true);
      }}>Beginning</Button>
      <Button variant="ghost" disabled={!loaded} onClick={() => navigate.current('desc', true)}>Latest</Button>
    </div>
    <section className="desktop-reader" aria-label="Codex conversation" ref={scroller}
      onScroll={() => {
        const v = scroller.current;
        if (!v) return;
        const distance = v.scrollHeight - v.scrollTop - v.clientHeight;
        followBottom.current = atLast && distance < 48;
        if (v.scrollTop < 100 && available.current.before) navigate.current('desc');
        else if (distance < 100 && available.current.after) navigate.current('asc');
      }}>
      {!loaded && !historyError && <p role="status">Loading messages…</p>}
      {historyError && <p role="alert">{historyError}</p>}
      {entries.map(entry => <div key={entryKey(entry)} data-codex-entry={entryKey(entry)}><TranscriptEntry entry={entry} reader={reader} /></div>)}
      {loaded && !entries.length && <p>No messages yet.</p>}
    </section>
    <div className="composer-zone">
      {queue.length > 0 && <div className="desktop-queue" role="status">{queue.length === 1 ? '1 message queued in Codex' : queue.length + ' messages queued in Codex'}
        <Button variant="ghost" onClick={() => { void call(reader, 'wake').then(() => { setWakeFailed(false); update.current(); }).catch(e => setSendError(errorText(e))); }}>Wake Codex</Button></div>}
      {wakeFailed && queue.length > 0 && <p role="alert">Open Codex to resume this conversation.</p>}
      {sendError && <p role="alert">{sendError}</p>}
      {(modelError || catalogError) && <p role="alert">{modelError || catalogError}</p>}
      {intent.kind === 'handoff' && <div className="desktop-model-notice" role="status">Choose {catalog?.choices.find(c => c.model === intent.model)?.displayName ?? intent.model} in Codex and send the next message there. Its reply will appear here.
        {draft && <Button variant="ghost" onClick={() => void copyText(draft).then(() => setCopiedDraft(draft)).catch(e => setModelError(errorText(e)))}>{copiedDraft === draft ? 'Draft copied' : 'Copy draft'}</Button>}
        <Button variant="ghost" onClick={() => void call(reader, 'openModelInCodex').catch(e => setModelError(errorText(e)))}>Open in Codex</Button>
        <Button variant="ghost" onClick={() => setIntent({kind:'follow'})}>Cancel</Button></div>}
      {(intent.kind === 'unconfirmed' || (intent.kind === 'bound' && !modelReady)) && <div className="desktop-model-notice" role="status">Codex hasn’t confirmed the selected model for this turn.
        <Button variant="ghost" onClick={() => { setModelError(''); setIntent({kind:'follow'}); }}>Follow Codex</Button></div>}
      <div className="composer-shell">
        <Textarea aria-label="Message Codex" placeholder="Message Codex…" rows={2} value={draft} maxLength={200000} disabled={sending}
          onInput={event => setDraft((event.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown={event => { if (shouldSubmitPromptKey(event)) { event.preventDefault(); void send(); } }} />
        <div className="desktop-send">
          {catalog && <select aria-label="Codex model" title={catalog.state.live ? 'Current model in Codex' : 'Last model recorded by Codex'} value={catalog.state.current ?? ''} disabled={intent.kind === 'switching' || sending || !!queue.length || intent.kind === 'handoff'}
            onChange={event => { const select = event.currentTarget as HTMLSelectElement; const wanted = select.value;
              select.value = catalog.state.current ?? ''; void changeModel(wanted); }}>
            {!catalog.choices.some(choice => choice.model === catalog.state.current) && <option value={catalog.state.current ?? ''} disabled>{catalog.state.current || 'Codex default'}</option>}
            {catalog.choices.map(choice => <option key={choice.model} value={choice.model}>{choice.displayName || choice.model}</option>)}
          </select>}
          <Button aria-label="Send to Codex" disabled={!loaded || !draft.trim() || sending || !modelReady || uncertain?.text === draft}
          onClick={() => { void send(); }}><Icon name="send" size={16} /></Button></div>
      </div>
    </div>
  </>;
}

export function DesktopConversation({reader}: {reader?: DesktopReader}) {
  return <>
    <header className="desktop-reader-title"><strong>{reader?.title ?? 'Codex chats'}</strong></header>
    {reader ? <Chat key={reader.request} reader={reader} /> : <div className="no-task-view"><p>Select a Codex chat.</p></div>}
  </>;
}
