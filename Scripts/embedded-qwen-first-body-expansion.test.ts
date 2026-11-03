import { expect, test } from 'bun:test';
import { answerID, choice, conversationID, fingerprint, fixture, generation, marker } from './embedded-qwen-adapter-fixture';

const prompt = 'An exact synthetic long prompt.\n' + 'aé𐀀b\n'.repeat(2800) + '\n\nComputa session marker: ' + marker;
const preview = prompt.slice(0, 10_240);
const canonical = 'https://chat.qwen.ai/c/' + conversationID;
const pending = { qwenFirstBodyExpansionPending: true, url: canonical, sessionLifecycle: 'saved_conversation_delete', temporary: false };
const idPending = { qwenInitialResponseIdentityPending: true, url: canonical, sessionLifecycle: 'saved_conversation_delete', temporary: false };
const chunkClass = 'chunked-text-renderer-root chunked-text-renderer-root-with-expand';

async function sent(model = 'Qwen3.7-Plus', outbound = prompt) {
  const f = fixture({ completeOnSend: false });
  for (let i = 0; i < 8; i++) {
    const result = await f.run('selectModel', { modelChoice: choice(model) });
    expect(result.error).toBeUndefined(); if (result.selected) break;
  }
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert', { prompt: outbound })).inserted).toBe(true);
  expect((await f.run('sendReady', { prompt: outbound })).sendReady).toBe(true);
  const hash = await fingerprint(outbound);
  expect((await f.run('submit', { prompt: outbound, savedSubmissionFingerprint: hash })).submitted).toBe(true);
  const chunk = f.userBody.parentElement!;
  chunk.setAttribute('class', chunkClass + ' is-collapsed');
  const control = new f.Node('BUTTON', { class: 'chat-user-message-expand-toggle chat-user-message-expand-toggle-pc', 'aria-label': 'Expand' });
  chunk.append(control); f.userBody.text = '';
  f.answer.setAttribute('id', 'chat-response-message-'); f.phase.detach();
  const loading = new f.Node('DIV', { class: 'response-loading' }); f.answer.append(loading);
  const settleID = () => { f.answer.setAttribute('id', 'chat-response-message-' + answerID); loading.detach(); f.flow.append(f.phase); f.complete(); };
  const render = () => { chunk.setAttribute('class', chunkClass); control.setAttribute('aria-label', 'Collapse'); f.userBody.text = outbound; };
  const grant = { allowQwenInitialResponseIdentity: true, allowQwenFirstBodyExpansion: true,
    expectedModelChoice: choice(model), savedSubmissionFingerprint: hash };
  const inspect = (overrides = {}) => f.run('inspect', { ...grant, ...overrides });
  return { f, chunk, control, render, hash, settleID, grant, inspect };
}

test('empty pending, exact collapsed preview, one display click, exact full proof after response ID settles', async () => {
  const { f, control, render, settleID, inspect, hash } = await sent();
  expect(await inspect()).toEqual(pending); expect(await inspect()).toEqual(pending); expect(control.clicks).toBe(0);
  f.userBody.text = preview; control.onClick = render;
  expect(await inspect()).toEqual(pending); expect(control.clicks).toBe(1);
  expect(await inspect()).toEqual(idPending); expect(f.world.__computaQwenSavedSessionV1.first).toBeNull();
  settleID(); const result = await inspect({allowQwenFirstBodyExpansion:false}); expect(result.firstUserVerified).toBe(true); expect(result.firstUserFingerprint).toBe(hash);
  expect(result.answerComplete).toBe(true); expect(control.clicks).toBe(1); expect(f.send.clicks).toBe(1); expect(f.more.clicks).toBe(0);
});

test('settled UUID supports first preview, multiple wakes and asynchronous Collapse rendering without replay', async () => {
  const { f, chunk, control, render, settleID, inspect } = await sent(); settleID(); f.userBody.text = preview;
  expect(await inspect()).toEqual(pending); expect(await inspect()).toEqual(pending); expect(control.clicks).toBe(1);
  chunk.setAttribute('class', chunkClass); control.setAttribute('aria-label', 'Collapse');
  expect(await inspect()).toEqual(pending); expect(control.clicks).toBe(1);
  render(); expect((await inspect()).firstUserVerified).toBe(true); expect(f.send.clicks).toBe(1);
});

test('missing grants, wrong native bindings and cleanup inspection never click or publish proof', async () => {
  for (const overrides of [{allowQwenFirstBodyExpansion:false},{allowQwenInitialResponseIdentity:false},{allowFirstUserBinding:false},
    {savedCleanupInspection:true},{expectedFirstUserFingerprint:'0'.repeat(64)},{expectedFirstUserMarker:generation},
    {expectedModelChoice:choice('Qwen3.8-Max')},{savedSubmissionFingerprint:'0'.repeat(64)},{expectedUserCounts:[0]}]) {
    const { f, control, inspect } = await sent(); f.userBody.text = preview;
    const r = await inspect(overrides); expect(r.error, JSON.stringify(overrides)).toBeDefined(); expect(r.firstUserVerified).toBeUndefined(); expect(control.clicks).toBe(0);
  }
});

test('foreign preview, unsupported length, wrong/duplicate/hidden/occluded controls remain terminal', async () => {
  for (const kind of ['different','short','long','normalized','name','label-case','extra','class','wrapper','disabled','occluded','type','form','href-form','popover','unknown-target','aria-controls','aria-expanded','nested-link','dialog','unmarked']) {
    const { f, chunk, control, inspect } = await sent(); f.userBody.text = preview;
    if (kind === 'different') f.userBody.text='?'+preview.slice(1);
    if (kind === 'short') f.userBody.text=preview.slice(1);
    if (kind === 'long') f.userBody.text=prompt.slice(0,10241);
    if (kind === 'normalized') f.userBody.text=preview.normalize('NFD');
    if (kind === 'name') control.setAttribute('aria-label','Delete');
    if (kind === 'label-case') control.setAttribute('aria-label','expand');
    if (kind === 'extra') chunk.append(new f.Node('BUTTON',{ 'aria-label':'Expand' }));
    if (kind === 'class') control.setAttribute('class','chat-user-message-expand-toggle');
    if (kind === 'wrapper') chunk.setAttribute('class','chunked-text-renderer-root');
    if (kind === 'disabled') control.disabled=true;
    if (kind === 'occluded') f.occlude(control);
    if (kind === 'type') control.setAttribute('type','submit');
    if (kind === 'form') control.setAttribute('form','foreign-form');
    if (kind === 'href-form') control.setAttribute('formaction','https://example.invalid');
    if (kind === 'popover') control.setAttribute('popovertarget','other');
    if (kind === 'unknown-target') control.setAttribute('commandfor','other');
    if (kind === 'aria-controls') control.setAttribute('aria-controls','other');
    if (kind === 'aria-expanded') control.setAttribute('aria-expanded','false');
    if (kind === 'nested-link') control.append(new f.Node('A',{href:'https://example.invalid'}));
    if (kind === 'dialog') f.body.append(new f.Node('DIV',{role:'dialog'}));
    if (kind === 'unmarked') chunk.setAttribute('class',chunkClass);
    const r=await inspect();expect(r.error,kind).toBeDefined();expect(r.firstUserVerified).toBeUndefined();expect(control.clicks).toBe(0);expect(f.send.clicks).toBe(1);
  }
});

test('empty read pins physical targets and cannot rebind on a matching preview or replay', async () => {
  for (const kind of ['body','control','middle','answer','model','url','id','empty-after-id','consumed-grant','not-inspect']) {
    const { f, chunk, control, settleID, grant, inspect } = await sent();
    expect(await inspect()).toEqual(pending); f.userBody.text=preview;
    if(kind==='body'){f.userBody.detach();const n=new f.Node('P',{class:'user-message-content'},preview);control.detach();chunk.append(n,control);}
    if(kind==='control'){control.detach();chunk.append(new f.Node('BUTTON',{...control.values}));}
    if(kind==='middle'){const parent=chunk.parentElement!,middle=new f.Node('DIV');chunk.detach();parent.append(middle);middle.append(chunk);}
    if(kind==='answer'){const p=f.answerRoot.parentElement!;f.answerRoot.detach();p.append(f.answerRoot.cloneNode(true));}
    if(kind==='model')f.modelName.text='Qwen3.8-Max';
    if(kind==='url')f.document.URL='https://chat.qwen.ai/c/'+generation;
    if(kind==='id')f.userContainer.setAttribute('data-msg-id',generation);
    if(kind==='empty-after-id'){settleID(); f.userBody.text=''; expect(await inspect()).toEqual(pending); f.answer.setAttribute('id','chat-response-message-');}
    const r=kind==='not-inspect'?await f.run('stop',grant):await inspect(kind==='consumed-grant'?{allowQwenFirstBodyExpansion:false}:{});
    expect(r.error,kind).toBeDefined();expect(control.clicks).toBe(0);expect(f.send.clicks).toBe(1);
  }
});

test('after click every byte and the same physical presentation are required through hash await', async () => {
  for (const kind of ['wrong-tail','shrink','model','route','return-collapsed','control','answer','generation','digest-drift','digest-control']) {
    const { f, chunk, control, render, settleID, inspect } = await sent(); settleID(); f.userBody.text=preview;
    expect(await inspect()).toEqual(pending); render();
    if(kind==='wrong-tail')f.userBody.text=prompt.slice(0,-1)+'x';
    if(kind==='shrink')f.userBody.text='';
    if(kind==='model')f.modelName.text='Other';
    if(kind==='route')f.document.URL='https://chat.qwen.ai/c/'+generation;
    if(kind==='return-collapsed'){chunk.setAttribute('class',chunkClass+' is-collapsed');control.setAttribute('aria-label','Expand');}
    if(kind==='control'){control.detach();chunk.append(new f.Node('BUTTON',{...control.values}));}
    if(kind==='answer')f.answer.setAttribute('id','chat-response-message-'+generation);
    if(kind==='generation')f.world.__computaModelOwner=generation;
    if(kind==='digest-drift')f.beforeDigest(()=>{f.userBody.text+='!';});
    if(kind==='digest-control')f.beforeDigest(()=>{control.detach();chunk.append(new f.Node('BUTTON',{...control.values}));});
    const r=await inspect();expect(r.error,kind).toBeDefined();expect(r.firstUserVerified).toBeUndefined();expect(control.clicks).toBe(1);expect(f.send.clicks).toBe(1);
  }
});

test('ordinary complete first body uses existing strict ownership without a display claim', async () => {
  const { f, control, settleID, inspect, hash } = await sent(); settleID(); f.userBody.text=prompt;
  const r=await inspect();expect(r.firstUserFingerprint).toBe(hash);expect(control.clicks).toBe(0);
  expect(f.world.__computaQwenSavedSessionV1.firstDisplay).toBeUndefined();
});


test('after the expanded transition, returning to collapsed preview cannot resume the display claim', async () => {
  const { f, chunk, control, inspect } = await sent(); f.userBody.text=preview;
  expect(await inspect()).toEqual(pending);
  chunk.setAttribute('class',chunkClass); control.setAttribute('aria-label','Collapse');
  expect(await inspect()).toEqual(pending);
  chunk.setAttribute('class',chunkClass+' is-collapsed'); control.setAttribute('aria-label','Expand');
  expect((await inspect()).error).toBe('conversation_changed'); expect(control.clicks).toBe(1);
});


test('Max must match its own previously selected model and receives the same strict display proof', async () => {
  const { f, control, render, settleID, inspect, hash } = await sent('Qwen3.8-Max');
  settleID(); f.userBody.text = preview; control.onClick = render;
  expect(await inspect()).toEqual(pending);
  const complete = await inspect(); expect(complete.modelEvidence.selected).toEqual(choice('Qwen3.8-Max'));
  expect(complete.firstUserFingerprint).toBe(hash); expect(control.clicks).toBe(1);
});

test('late UUID cannot change during the final digest after completed display handed off to ID-only waiting', async () => {
  const { f, control, render, settleID, inspect } = await sent(); f.userBody.text = preview; control.onClick=render;
  expect(await inspect()).toEqual(pending); expect(await inspect()).toEqual(idPending); settleID();
  f.beforeDigest(()=>f.answer.setAttribute('id','chat-response-message-'+generation));
  const failed=await inspect({allowQwenFirstBodyExpansion:false});
  expect(failed.error).toBe('conversation_changed'); expect(failed.firstUserVerified).toBeUndefined(); expect(control.clicks).toBe(1);
});

function remountPicker(f: ReturnType<typeof fixture>, detached: boolean) {
  const replacement = new f.Node('DIV', {...f.trigger.values});
  replacement.append(new f.Node('DIV', {...f.modelName.values}, f.modelName.text));
  if (detached) f.trigger.detach(); else f.trigger.setAttribute('hidden', '');
  f.body.append(replacement);
  return replacement;
}

test('a connected replacement, open picker or changed label still fails before any display click', async () => {
  for (const [kind,reason] of [['hidden','trigger_replaced'],['open','picker_open'],['label','label_changed']]) {
    const { f, control, inspect } = await sent();
    if (kind === 'hidden') remountPicker(f, false);
    if (kind === 'open') f.openPicker();
    if (kind === 'label') f.modelName.text='PRIVATE_PAGE_CANARY';
    const result = await inspect();
    expect(result).toMatchObject({error:'model_unverified', detail:'selection_binding', qwenSelectionBinding:'display_before_click/'+reason});
    expect(result.firstUserVerified).toBeUndefined(); expect(JSON.stringify(result)).not.toContain('PRIVATE_PAGE_CANARY');
    expect(f.send.clicks).toBe(1); expect(control.clicks).toBe(0);
    expect((await inspect()).detail).toBe('terminal_operation');
  }
});

test('a remount during the single expansion is identified after click and never repeats it', async () => {
  const { f, control, render, inspect } = await sent();
  f.userBody.text=preview; control.onClick=()=>{render();remountPicker(f,true);};
  expect(await inspect()).toEqual(pending);
  const r=await inspect(); expect(r.qwenSelectionBinding).toBe('display_after_click/trigger_detached');
  expect(r.error).toBe('model_unverified'); expect(r.firstUserVerified).toBeUndefined(); expect(control.clicks).toBe(1);
});

test('model changed after digest is distinguished from the earlier display observation', async () => {
  for (const [kind,stage] of [['id','id_after_hash'],['final','body_after_hash']]) {
    const {f, inspect, settleID} = await sent(); f.userBody.text=prompt; if(kind==='final')settleID();
    f.beforeDigest(()=>{f.modelName.text='PRIVATE_PAGE_CANARY';});
    const r=await inspect();expect(r.qwenSelectionBinding).toBe(stage+'/label_changed');expect(r.error).toBe('model_unverified');
    expect(r.detail).toBe('selection_binding');expect(JSON.stringify(r)).not.toContain('PRIVATE_PAGE_CANARY');
  }
});

test('only the first exact expanded body commits its detached-picker replacement', async () => {
  for (const firstRead of ['empty', 'preview', 'before-remount']) {
    const label = firstRead === 'preview' ? 'Qwen3.8-Max' : 'Qwen3.7-Plus';
    const { f, control, render, settleID, inspect, hash } = await sent(label);
    const state = f.world.__computaQwenSavedSessionV1, pickerClicks = f.trigger.clicks;
    if (firstRead === 'before-remount') expect(await inspect()).toEqual(pending);
    const replacement = remountPicker(f, true);
    if (firstRead === 'empty') {
      expect(await inspect()).toEqual(pending);
      expect(control.clicks).toBe(0);
    }
    f.userBody.text = preview; control.onClick = render;
    expect(await inspect()).toEqual(pending); expect(await inspect()).toEqual(idPending);
    expect(state.model.trigger).toBe(f.trigger); expect(state.first).toBeNull();
    settleID();
    f.beforeDigest(() => { expect(state.model.trigger).toBe(f.trigger); expect(state.first).toBeNull(); });
    const result = await inspect({ allowQwenFirstBodyExpansion: false });
    expect(result).toMatchObject({ firstUserVerified: true, firstUserFingerprint: hash,
      modelEvidence: { selected: choice(label) }, answerComplete: true });
    expect(state.model.trigger).toBe(replacement);
    expect([f.trigger.clicks, replacement.clicks, control.clicks, f.send.clicks, f.more.clicks])
      .toEqual([pickerClicks, 0, 1, 1, 0]);
    f.beforeDigest(() => {}); replacement.detach(); remountPicker(f, true);
    const cleanup = await inspect({ savedCleanupInspection: true, allowFirstUserBinding: false, expectedFirstUserFingerprint: hash });
    expect(cleanup.error).toBe('model_unverified'); expect(f.more.clicks).toBe(0);
  }
});

test('a detached picker alone cannot authorize any first-body, selection or delete proof', async () => {
  for (const kind of ['no-display-grant', 'no-id-grant', 'wrong-grant-hash', 'wrong-choice', 'cleanup', 'action',
    'authored', 'hidden-duplicate', 'visible-duplicate', 'replacement-disabled', 'replacement-open', 'wrong-label',
    'wrong-preview', 'full-without-expand']) {
    const { f, control, inspect, grant } = await sent();
    const replacement = remountPicker(f, true);
    f.userBody.text = preview;
    if (kind === 'authored') { replacement.detach(); f.root.append(replacement); }
    if (kind.endsWith('duplicate')) {
      const extra = new f.Node('DIV', { ...replacement.values });
      extra.append(new f.Node('DIV', { ...f.modelName.values }, f.modelName.text));
      if (kind === 'hidden-duplicate') extra.setAttribute('hidden', '');
      f.body.append(extra);
    }
    if (kind === 'replacement-disabled') replacement.setAttribute('aria-disabled', 'true');
    if (kind === 'replacement-open') { replacement.setAttribute('aria-expanded', 'true'); f.modelMenu.removeAttribute('hidden'); }
    if (kind === 'wrong-label') replacement.children[0].text = 'Qwen3.8-Max';
    if (kind === 'wrong-preview') f.userBody.text = '?' + preview.slice(1);
    if (kind === 'full-without-expand') f.userBody.text = prompt;
    const overrides: Record<string, unknown> = {};
    if (kind === 'no-display-grant') overrides.allowQwenFirstBodyExpansion = false;
    if (kind === 'no-id-grant') overrides.allowQwenInitialResponseIdentity = false;
    if (kind === 'wrong-grant-hash') overrides.savedSubmissionFingerprint = '0'.repeat(64);
    if (kind === 'wrong-choice') overrides.expectedModelChoice = choice('Qwen3.8-Max');
    if (kind === 'cleanup') overrides.savedCleanupInspection = true;
    const result = kind === 'action' ? await f.run('deleteConversation', grant) : await inspect(overrides);
    expect(result.error, kind).toBeDefined(); expect(result.modelEvidence).toBeUndefined();
    expect(result.firstUserVerified).toBeUndefined(); expect(result.deleteProof).toBeUndefined();
    expect(f.world.__computaQwenSavedSessionV1.model.trigger).toBe(f.trigger);
    expect([replacement.clicks, control.clicks, f.send.clicks, f.more.clicks]).toEqual([0, 0, 1, 0]);
  }
});

test('the same replacement and message must survive every wait and both digest boundaries', async () => {
  for (const kind of ['empty-replacement', 'original-returns', 'label-node', 'wrong-tail', 'response-id-digest', 'full-digest',
    'digest-label', 'digest-body', 'digest-owner', 'digest-url', 'cleanup-while-held']) {
    const { f, control, render, inspect, settleID } = await sent();
    const replacement = remountPicker(f, true);
    const remount = () => { replacement.detach(); remountPicker(f, true); };
    expect(await inspect()).toEqual(pending);
    const state = f.world.__computaQwenSavedSessionV1;
    f.userBody.text = preview;
    if (kind === 'empty-replacement') remount();
    else {
      control.onClick = render;
      expect(await inspect()).toEqual(pending);
      if (kind === 'original-returns') { f.trigger.setAttribute('hidden', ''); f.body.append(f.trigger); }
      if (kind === 'label-node') { const name = replacement.children[0] as typeof f.modelName; name.detach(); replacement.append(new f.Node('DIV', { ...name.values }, name.text)); }
      if (kind === 'wrong-tail') f.userBody.text = prompt.slice(0, -1) + '!';
      if (kind !== 'response-id-digest') settleID();
      if (kind === 'response-id-digest' || kind === 'full-digest') f.beforeDigest(remount);
      if (kind === 'digest-label') f.beforeDigest(() => { replacement.children[0].text = 'Qwen3.8-Max'; });
      if (kind === 'digest-body') f.beforeDigest(() => { f.userBody.text += '!'; });
      if (kind === 'digest-owner') f.beforeDigest(() => { f.world.__computaModelOwner = generation; });
      if (kind === 'digest-url') f.beforeDigest(() => { f.document.URL = 'https://chat.qwen.ai/c/' + generation; });
    }
    const result = await inspect(kind === 'cleanup-while-held' ? { savedCleanupInspection: true } : {});
    expect(result.error, kind).toBeDefined(); expect(result.modelEvidence).toBeUndefined();
    expect(result.firstUserVerified).toBeUndefined(); expect(state.first).toBeNull(); expect(state.model.trigger).toBe(f.trigger);
    expect([replacement.clicks, control.clicks, f.send.clicks, f.more.clicks])
      .toEqual([0, kind === 'empty-replacement' ? 0 : 1, 1, 0]);
    expect(state.terminal).toBe(true);
  }
});

test('a short exact first body cannot authorize a detached picker even with both grants', async () => {
  const short = 'Synthetic short body.\n\nComputa session marker: ' + marker;
  const { f, control, inspect, settleID } = await sent('Qwen3.7-Plus', short);
  const replacement = remountPicker(f, true);
  settleID(); f.userBody.text = short;
  const result = await inspect();
  expect(result).toMatchObject({ error: 'model_unverified', qwenSelectionBinding: 'body_after_hash/trigger_detached' });
  expect(result.firstUserVerified).toBeUndefined(); expect(result.modelEvidence).toBeUndefined();
  expect(f.world.__computaQwenSavedSessionV1.model.trigger).toBe(f.trigger);
  expect([replacement.clicks, control.clicks, f.send.clicks]).toEqual([0, 0, 1]);
});

test('Qwen display failures report the original hit decision with no repeated geometry check or action', async () => {
  for (const which of [1, 2]) for (const reason of ['outside_viewport', 'invalid_geometry', 'occluded']) {
    const {f, control, inspect} = await sent();
    f.userBody.text = preview;
    let checks = 0;
    const rect = control.getBoundingClientRect.bind(control);
    control.getBoundingClientRect = () => {
      const box = rect();
      if (++checks === which) {
        if (reason === 'outside_viewport') return {...box, left: 1200};
        if (reason === 'invalid_geometry') return {...box, width: 0};
        f.occlude(control);
      }
      return box;
    };
    const result = await inspect();
    expect(result).toEqual({error: 'conversation_changed', detail: 'first_user_message',
      qwenFirstUserBindingDiagnostic: {version: 1, stage: which === 1 ? 'display_hit' : 'display_preclick_hit', reason}});
    expect(checks).toBe(which);
    expect(control.clicks).toBe(0);
    expect(f.send.clicks).toBe(1);
    expect((await inspect()).detail).toBe('terminal_operation');
  }
});

test('Qwen rejects replaced display pins and invalid first preview with only finite evidence', async () => {
  for (const reason of ['body_changed','control_changed','pin_count_changed','answer_ancestry_changed','initial_length_mismatch','initial_prefix_mismatch']) {
    const {f, control, chunk, inspect} = await sent();
    const held = !reason.startsWith('initial_');
    if (held) expect(await inspect()).toEqual(pending);
    f.userBody.text = preview;
    if (reason === 'body_changed') {
      f.userBody.detach(); control.detach(); chunk.append(new f.Node('P',{class:'user-message-content'},preview), control);
    } else if (reason === 'control_changed') {
      control.detach(); chunk.append(new f.Node('BUTTON',{...control.values}));
    } else if (reason === 'pin_count_changed') {
      const parent = chunk.parentElement!, middle = new f.Node('DIV'); chunk.detach(); parent.append(middle); middle.append(chunk);
    } else if (reason === 'answer_ancestry_changed') {
      const parent = f.answerRoot.parentElement!; f.answerRoot.detach(); parent.append(f.answerRoot.cloneNode(true));
    } else {
      f.userBody.text = reason === 'initial_length_mismatch' ? 'PRIVATE_BODY' : 'x' + preview.slice(1);
    }
    const result = await inspect();
    expect(result).toEqual({error: 'conversation_changed', detail: 'first_user_message',
      qwenFirstUserBindingDiagnostic: {version: 1, stage: held ? 'display_held' : 'display_observation', reason}});
    expect(control.clicks).toBe(0); expect(f.send.clicks).toBe(1);
  }
});

test('a clipped Qwen display button needs the same exposed point before its sole click', async () => {
  for (const model of ['Qwen3.7-Plus', 'Qwen3.8-Max']) {
    const { f, control, inspect, render, settleID, hash } = await sent(model);
    const icon = new f.Node('SPAN');
    control.append(icon); control.onClick = render; f.userBody.text = preview;
    control.getBoundingClientRect = () => ({ left: -70, top: 70, width: 100, height: 32 });
    const original = f.document.elementFromPoint;
    const points: number[][] = [];
    f.document.elementFromPoint = (x: number, y: number) => {
      if (y < 70 || y > 102) return original(x, y);
      points.push([x, y]);
      // A foreign overlay occupies the center of the 30 CSS pixels on screen.
      return x < 7 ? icon : f.document.body;
    };
    expect(await inspect()).toEqual(pending);
    expect(points).toEqual([[15,86], [3.75,86], [3.75,86]]);
    expect(control.clicks).toBe(1);
    expect(await inspect()).toEqual(idPending);
    settleID();
    const verified = await inspect({allowQwenFirstBodyExpansion:false});
    expect(verified.firstUserFingerprint).toBe(hash);
    expect(verified.answerComplete).toBe(true); expect(f.send.clicks).toBe(1);
  }
});

test('Qwen refuses full coverage, a lost hit point, a moved target, and nested interactive hits', async () => {
  for (const kind of ['foreign', 'no_hit', 'covered_after', 'moved', 'nested_role', 'replaced']) {
    const { f, chunk, control, inspect } = await sent();
    const foreign = new f.Node('A', {href: '/foreign'}); f.document.body.append(foreign);
    const child = new f.Node('SPAN', {role:'button'}); control.append(child);
    let measurements = 0;
    control.getBoundingClientRect = () => {
      measurements++;
      return { left: kind === 'moved' && measurements === 2 ? 210 : 10, top:70, width:100, height:32 };
    };
    f.userBody.text = preview;
    const original = f.document.elementFromPoint;
    const points: number[][] = [];
    f.document.elementFromPoint = (x: number, y: number) => {
      if (y < 70 || y > 102) return original(x,y);
      points.push([x,y]);
      if (kind === 'nested_role') return child;
      if (kind === 'no_hit') return null;
      if (kind === 'replaced' && points.length === 2) {
        control.detach(); chunk.append(new f.Node('BUTTON', {...control.values}));
        return control;
      }
      if (kind === 'moved' || kind === 'covered_after') {
        // Another exposed point would succeed on the second read.
        if (measurements === 1 ? x === 22.5 : x !== 22.5) return control;
      }
      return foreign;
    };
    const result = await inspect();
    expect(result.error, kind).toBe('conversation_changed');
    expect(result.firstUserVerified).toBeUndefined();
    expect(result.qwenFirstUserBindingDiagnostic.reason).toBe(kind === 'replaced' ? 'control_changed' : 'occluded');
    if (kind === 'covered_after') expect(points).toEqual([[60,86], [22.5,86], [22.5,86]]);
    if (kind === 'moved' || kind === 'replaced') expect(points).toHaveLength(2);
    if (['foreign', 'no_hit', 'nested_role'].includes(kind)) expect(points).toHaveLength(9);
    expect((await inspect()).detail).toBe('terminal_operation');
    expect([control.clicks, child.clicks, foreign.clicks, f.send.clicks, f.more.clicks]).toEqual([0,0,0,1,0]);
  }
});

test('one normal scroll can reveal only the exact pinned preview control', async () => {
  for (const model of ['Qwen3.7-Plus', 'Qwen3.8-Max']) {
    for (const before of ['occluded', 'outside_viewport']) {
      const {f, control, render, inspect, hash, settleID} = await sent(model);
      f.userBody.text = preview; control.onClick = render;
      let scrolls = 0;
      const original = f.document.elementFromPoint;
      const points: number[][] = [];
      control.getBoundingClientRect = () => ({left:20, top:scrolls ? 100 : before === 'occluded' ? 300 : 900, width:100, height:32});
      f.document.elementFromPoint = (x: number, y: number) => {
        if (y < 100) return original(x, y);
        points.push([x, y]);
        return scrolls ? control : f.document.body;
      };
      Object.assign(control, {scrollIntoView(options: unknown) {
        scrolls++; expect(options).toEqual({block:'center', inline:'nearest', behavior:'instant'});
        expect(control.clicks).toBe(0);
      }});
      expect(await inspect()).toEqual(pending);
      expect(points.slice(-2)).toEqual([[70,116],[70,116]]);
      expect(scrolls).toBe(1); expect(control.clicks).toBe(1);
      expect(await inspect()).toEqual(idPending);
      settleID();
      const result = await inspect({allowQwenFirstBodyExpansion:false});
      expect(result.firstUserVerified).toBe(true); expect(result.firstUserFingerprint).toBe(hash);
      expect(result.answerComplete).toBe(true); expect(f.send.clicks).toBe(1);
      expect(scrolls).toBe(1); expect(control.clicks).toBe(1);
    }
  }
});

test('scroll-induced changes and persistent occlusion cannot dispatch a display click', async () => {
  for (const kind of ['ancestor','unrelated','none','descendant','mixed','scroll_failed','covered_again','control_changed','preview_changed','model','route','composer_changed']) {
    const {f, chunk, control, inspect} = await sent();
    f.userBody.text = preview;
    const foreign = new f.Node('A', {href:'/other'}); f.document.body.append(foreign);
    const nestedRole = new f.Node('SPAN', {role:'link'}); control.append(nestedRole);
    const original = f.document.elementFromPoint;
    let scrolls = 0, measurements = 0, afterHits = 0;
    control.getBoundingClientRect = () => {
      measurements++;
      return {left:10, top:110, width:100,height:32};
    };
    f.document.elementFromPoint = (x: number, y: number) => {
      if (y < 110) return original(x, y);
      if (!scrolls) return f.document.body;
      afterHits++;
      if (kind === 'covered_again') return measurements === 2 ? control : foreign;
      if (kind === 'ancestor') return chunk;
      if (kind === 'none') return null;
      if (kind === 'descendant') return nestedRole;
      if (kind === 'mixed') return afterHits === 1 ? null : foreign;
      return foreign;
    };
    Object.assign(control, {scrollIntoView() {
      scrolls++;
      if (kind === 'scroll_failed') throw Error('PRIVATE_FAILURE');
      if (kind === 'control_changed') { control.detach(); chunk.append(new f.Node('BUTTON', {...control.values})); }
      if (kind === 'preview_changed') f.userBody.text = 'z' + preview.slice(1);
      if (kind === 'route') f.document.URL = 'https://chat.qwen.ai/';
      if (kind === 'model') f.modelName.text = 'Qwen3.8-Max';
      if (kind === 'composer_changed') {
        const replacement = new (f.editor.constructor as any)('TEXTAREA', {...f.editor.values});
        f.editor.detach(); f.scope.append(replacement);
      }
    }});
    const result = await inspect();
    expect(result.error, kind).toBeDefined(); expect(result.firstUserVerified).toBeUndefined();
    expect(result.modelEvidence).toBeUndefined(); expect(JSON.stringify(result)).not.toContain('PRIVATE');
    const classified = ['ancestor','unrelated','none','descendant','mixed'];
    if (classified.includes(kind) || kind === 'covered_again' || kind === 'scroll_failed') {
      const reason = kind === 'covered_again' ? 'occluded_unrelated' : kind === 'scroll_failed' ? kind : 'occluded_' + kind;
      expect(result.qwenFirstUserBindingDiagnostic).toEqual({version:1,stage:'display_reveal_hit',reason});
      expect(afterHits).toBe(kind === 'covered_again' ? 2 : kind === 'scroll_failed' ? 0 : 9);
    } else {
      expect(afterHits).toBe(0);
    }
    if (['control_changed','preview_changed','composer_changed'].includes(kind))
      expect(result.qwenFirstUserBindingDiagnostic?.reason, kind + JSON.stringify(result)).toBe(kind);
    if (kind !== 'route') expect((await inspect()).detail).toBe('terminal_operation');
    expect([scrolls,control.clicks,foreign.clicks,f.send.clicks,f.more.clicks]).toEqual([1,0,0,1,0]);
  }
});

test('no scroll is attempted for an ineligible view or foreign preview', async () => {
  for (const kind of ['disabled','invalid_geometry','wrong_preview','cleanup']) {
    const {f, control, inspect} = await sent();
    let scrolls = 0;
    Object.assign(control, {scrollIntoView() { scrolls++; }});
    f.userBody.text = kind === 'wrong_preview' ? 'x' + preview.slice(1) : preview;
    if (kind === 'disabled') control.disabled = true;
    if (kind === 'invalid_geometry') control.getBoundingClientRect = () => ({left:0,top:0,width:0,height:50});
    const result = await inspect(kind === 'cleanup' ? {savedCleanupInspection:true} : {});
    expect(result.error).toBeDefined(); expect([scrolls,control.clicks,f.send.clicks]).toEqual([0,0,1]);
  }
});
