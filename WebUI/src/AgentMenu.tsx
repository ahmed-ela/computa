import { useEffect, useRef, useState } from 'octane';
import { Button } from '@octanejs/shadcn/Button';
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem } from '@octanejs/shadcn/DropdownMenu';
import { Icon } from './Icon';
import type { AgentProfile, NativeAction } from './types';

export function AgentMenu({ taskID, name, profile, canStartFresh, post }: {
  taskID: string; name: string; profile?: AgentProfile; canStartFresh: boolean; post: (action: NativeAction) => void;
}) {
  const [panel, setPanel] = useState<'settings' | 'history' | null>(null);
  const [label, setLabel] = useState('');
  const [instructions, setInstructions] = useState('');
  const dialog = useRef<HTMLDialogElement | null>(null);
  useEffect(() => { if (panel && !dialog.current?.open) dialog.current?.showModal(); }, [panel]);
  function settings() {
    setLabel(profile?.name ?? (name === 'Untitled task' ? '' : name));
    setInstructions(profile?.instructions ?? '');
    setPanel('settings');
  }
  return <>
    <DropdownMenu>
      <DropdownMenuTrigger asChild><Button variant="ghost" size="icon-xs" aria-label="Agent menu" title="Agent menu"><Icon name="more" size={16} /></Button></DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="queue-menu-content">
        <DropdownMenuItem disabled={!canStartFresh} onSelect={() => post({action:'startFresh', taskID})}>Start fresh</DropdownMenuItem>
        <DropdownMenuItem disabled={!profile?.history.length} onSelect={() => setPanel('history')}>History</DropdownMenuItem>
        <DropdownMenuItem onSelect={settings}>Agent settings</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
    {panel && <dialog className="agent-settings" ref={dialog} aria-label={panel === 'settings' ? 'Agent settings' : 'Conversation history'} onClose={() => setPanel(null)}>
      {panel === 'settings' ? <form onSubmit={event => {
        event.preventDefault();
        if (!label.trim() || new TextEncoder().encode(label.trim()).length > 256 || new TextEncoder().encode(instructions.trim()).length > 4096) return;
        post({action:'saveAgentSettings', taskID, name:label.trim(), instructions:instructions.trim()});
        dialog.current?.close();
      }}>
        <label>Agent name<input required maxLength={64} value={label} onInput={event => setLabel(event.currentTarget.value)} /></label>
        <label>Instructions for new conversations<textarea rows={4} maxLength={1024} value={instructions} onInput={event => setInstructions(event.currentTarget.value)} /></label>
        <footer><Button type="button" variant="ghost" onClick={() => dialog.current?.close()}>Cancel</Button><Button type="submit" disabled={!label.trim()}>Save</Button></footer>
      </form> : <>
        <h3>Conversation history</h3>
        <div className="agent-history-list">{profile?.history.map(chat => <Button variant="ghost" key={chat.id} onClick={() => {
          dialog.current?.close(); post({action:'openAgentHistory',taskID,conversationID:chat.id});
        }}>{chat.title}</Button>)}</div>
        <footer><Button variant="ghost" onClick={() => dialog.current?.close()}>Close</Button></footer>
      </>}
    </dialog>}
  </>;
}
