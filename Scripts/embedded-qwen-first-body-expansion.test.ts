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
