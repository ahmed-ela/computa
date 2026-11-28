import { useEffect, useLayoutEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { Textarea } from '@octanejs/shadcn/Textarea';
import { ResponseMarkdown } from './ResponseMarkdown';
import { Icon } from './Icon';
import { shouldSubmitPromptKey } from './promptQueue';
import { activityLabel, activityText, entryKey, CodexHistoryWindow } from './codexTranscript';
import type { CodexEntry, CodexPage, HistoryDirection, UserPart } from './codexTranscript';
import { groupModelOptions, modelOptionLabel } from './ModelSelector';
import type { AppSnapshot, DesktopReader } from './types';

function call<T>(reader: DesktopReader, action: string, fields: Record<string, string | string[]> = {}): Promise<T> {
  const bridge = window.webkit?.messageHandlers?.codexConversation;
  if (!bridge) return Promise.reject(new Error('Codex is unavailable.'));
  return bridge.postMessage({action, thread: reader.id, selection: reader.request, ...fields}) as Promise<T>;
}
const errorText = (error: unknown) => error instanceof Error ? error.message : String(error);


function TranscriptEntry({entry}: {entry: CodexEntry}) {
  const [open, setOpen] = useState(false);
  const item = entry.item;
  if (item.type === 'deliveryStatus') return <p role="status">{String(item.message)}</p>;
  if (item.type === 'agentMessage') return <article><strong>{entry.modelLabel || entry.model?.split('/model/').at(-1) || 'Codex'}</strong><ResponseMarkdown text={String(item.text ?? '')} /></article>;
  if (item.type === 'userMessage') return <article><strong>You</strong>
    {(item.content as UserPart[] ?? []).map((part, i) =>
      part.type === 'image' && /^data:image\/(png|jpeg|webp|gif);base64,/i.test(part.url ?? '')
        ? <img key={i} className="desktop-attachment" alt="Attached image" src={part.url} />
        : <p key={i} className="desktop-reader-user">{part.text ?? part.name ?? part.path ?? part.fileId ?? ('Attached ' + part.type)}</p>)}</article>;
  return <details onToggle={event => setOpen((event.currentTarget as HTMLDetailsElement).open)}>
    <summary>{activityLabel(item)}</summary>
    {open && <pre>{activityText(item)}</pre>}
  </details>;
}


type Choice = {model:string; displayName:string};
const providers = [{id:'codex',name:'Codex CLI'}, {id:'antigravity',name:'Gemini via Antigravity'}, {id:'claude',name:'Claude Code'}];

type WebsitePickerProps = {
  snapshot: AppSnapshot;
  onConnect: (route: string) => void;
};

function Chat({reader, snapshot, onConnect}: {reader:DesktopReader} & WebsitePickerProps) {
  const [history] = useState(() => new CodexHistoryWindow());
  const [entries,setEntries] = useState<CodexEntry[]>([]);
  const [model,setModel] = useState<string | null>(null);
  const [choices,setChoices] = useState<Record<string,Choice[]>>({});
  const websites = groupModelOptions(snapshot.modelOptions.filter(option => option.id.startsWith('browser/')), model ?? '',
    snapshot.providerSetups.filter(setup => setup.route.startsWith('browser/')));
  const websiteChoices = websites.flatMap(group => group.options).filter(option => option.available !== false);
  const [draft,setDraft] = useState('');
  const [error,setError] = useState('');
  const [working,setWorking] = useState(false);
  const [loaded,setLoaded] = useState(false);
  const loading = useRef(0);
  const alive = useRef(true);
  const scroller = useRef<HTMLElement | null>(null);
  const bottom = useRef(true);
  const refresh = async (direction:HistoryDirection = 'desc', cursor?:string) => {
    const ticket = ++loading.current;
    const page = await call<CodexPage>(reader,'page',{direction,...(cursor ? {cursor} : {})});
    if (!alive.current || loading.current !== ticket || !history.accept(page,direction,cursor)) return;
    bottom.current = !cursor && direction === 'desc';
    setEntries(history.entries); setLoaded(true);
  };
  const readModel = async () => {
    const current = await call<string>(reader,'currentModel');
    if (alive.current) setModel(current);
  };
  useEffect(() => {
    alive.current = true;
    void Promise.all([refresh(),readModel()]).catch(e => { if (alive.current) setError(errorText(e)); });
    const refocus = () => {
      const modelRead = readModel();
      void Promise.all(bottom.current ? [modelRead,refresh()] : [modelRead]).catch(e => { if (alive.current) setError(errorText(e)); });
    };
    window.addEventListener('focus',refocus);
    return () => { alive.current = false; window.removeEventListener('focus',refocus); };
  },[reader.request]);
  useLayoutEffect(() => {
    if (bottom.current && scroller.current) scroller.current.scrollTop = scroller.current.scrollHeight;
  },[entries]);
  const choose = async (value:string) => {
    if (working || model === null || !value) return;
    setWorking(true); setError('');
    try {
      if (value.startsWith('@browser/')) {
        onConnect(value.slice(1));
      } else if (value.startsWith('@')) {
        const provider = value.slice(1);
        const next = await call<Choice[]>(reader,'models',{provider});
        if (alive.current) { setChoices(old => ({...old,[provider]:next})); if (!next.length) setError('No available models on this account.'); }
      } else {
        const current = await call<string>(reader,'changeModel',{expected:model,model:value});
        if (alive.current) setModel(current);
      }
    } catch (e) { if (alive.current) { setError(errorText(e)); await readModel(); } }
    finally { if (alive.current) setWorking(false); }
  };
  const send = async () => {
    if (!loaded || working || !model || !draft.trim()) return;
    setWorking(true); setError('');
    try {
      await call(reader,'send',{expected:model,text:draft,submission:crypto.randomUUID()});
      if (alive.current) setDraft('');
    } catch (e) { if (alive.current) setError(errorText(e)); }
    finally {
      if (alive.current) {
        try { await Promise.all([refresh(),readModel()]); } catch (e) { setError(errorText(e)); }
        setWorking(false);
      }
    }
  };
  const page = (direction:HistoryDirection,cursor?:string) => { void refresh(direction,cursor).catch(e=>setError(errorText(e))); };
  return <>
    <div className="desktop-history-navigation" aria-label="Conversation history">
      <Button variant="ghost" disabled={!history.before} onClick={()=>page('asc')}>Beginning</Button>
      <Button variant="ghost" disabled={!history.before} onClick={()=>page('desc',history.before ?? undefined)}>Earlier</Button>
      <Button variant="ghost" disabled={!history.after} onClick={()=>page('asc',history.after ?? undefined)}>Later</Button>
      <Button variant="ghost" disabled={!history.after} onClick={()=>page('desc')}>Latest</Button>
    </div>
    <section className="desktop-reader" aria-label="Imported conversation" ref={scroller}>
      {entries.map(entry=><div key={entryKey(entry)} data-codex-entry={entryKey(entry)}><TranscriptEntry entry={entry} /></div>)}
      {loaded && !entries.length && <p>No messages yet.</p>}
    </section>
    <div className="composer-zone">
      {error && <p role="alert">{error}</p>}
      <div className="composer-shell">
        <Textarea aria-label="Message imported chat" placeholder="Continue in Kolmogor…" rows={2} value={draft} maxLength={200000} disabled={working}
          onInput={e=>setDraft((e.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown={e=>{ if (shouldSubmitPromptKey(e)) { e.preventDefault(); void send(); } }} />
        <div className="desktop-send">
          <select aria-label="Conversation model" value={model ?? ''} disabled={working || model === null}
            onChange={e=>{const select=e.currentTarget as HTMLSelectElement; const value=select.value; select.value=model ?? ''; void choose(value);}}>
            {!websiteChoices.some(option=>option.id===model) && !Object.values(choices).flat().some(c=>c.model===model) && <option value={model ?? ''} disabled>{model?.startsWith('browser/') ? 'Previously selected website model (unavailable)' : model?.split('/model/').at(-1) || 'Choose a model'}</option>}
            {websites.map(group=><optgroup key={group.route} label={group.name + ' (website)'}>
              {group.options.filter(option=>option.available !== false).map(option=><option key={option.id} value={option.id}>{modelOptionLabel(option)}</option>)}
              <option value={'@'+group.route} disabled={!snapshot.canRefreshWebsiteModels || group.setup?.checkStatus === 'checking'}>
                {group.setup?.checkStatus === 'checking' ? 'Checking models…'
                  : group.options.some(option=>option.available !== false) ? 'Manage website connection…' : 'Connect ' + group.name + '…'}
              </option>
            </optgroup>)}
            {providers.map(p=><optgroup key={p.id} label={p.name}>
              {(choices[p.id] ?? []).map(c=><option key={c.model} value={c.model}>{c.displayName}</option>)}
              <option value={'@'+p.id}>{choices[p.id] ? 'Refresh models…' : 'Load models…'}</option>
            </optgroup>)}
          </select>
          <Button aria-label="Send to selected model" disabled={!loaded || !model || working || !draft.trim() || (model.startsWith('browser/') && !websiteChoices.some(option=>option.id===model))} onClick={()=>{void send();}}><Icon name="send" size={16}/></Button>
        </div>
      </div>
      <p className="desktop-model-notice">Replies use this copy’s text history with the selected provider.</p>
    </div>
  </>;
}

export function DesktopConversation({reader,browsing,snapshot,onConnect}: {reader?:DesktopReader; browsing:boolean} & WebsitePickerProps) {
  return <>
    <header className="desktop-reader-title"><strong>{browsing ? 'Import from Codex' : reader?.title ?? 'Imported chats'}</strong></header>
    {browsing ? <div className="no-task-view"><p>Choose a Codex chat to copy into Kolmogor. Future replies stay in the app where you send them.</p></div>
      : reader ? <Chat key={reader.request} reader={reader} snapshot={snapshot} onConnect={onConnect} /> : <div className="no-task-view"><p>Import a Codex chat to continue it here.</p></div>}
  </>;
}
