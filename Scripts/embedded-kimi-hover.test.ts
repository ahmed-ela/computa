import { expect, test } from 'bun:test';
import { adapterFixture, instant, marker } from './embedded-kimi-adapter-fixture';

const entry = ['pointerover', 'pointerenter', 'mouseover', 'mouseenter'];
const exit = ['pointerout', 'pointerleave', 'mouseout', 'mouseleave'];
const discover = (f: ReturnType<typeof adapterFixture>) => f.run('discoverModels', { expectedModelChoice: undefined });
async function settle(f: ReturnType<typeof adapterFixture>) {
  for (let i = 0; i < 8; i++) { const r = await discover(f); if (!r.pending) return r; }
  throw new Error('Bounded fixture discovery did not settle');
}

test('candidate uses exactly one fixed pointer and mouse entry and exit, with no submenu click or model substitution', async () => {
  const f = adapterFixture({ nestedSelected: true });
  const result = await settle(f);
  expect(result.modelChoices).toEqual([instant]); expect(result.modelEvidence.selected).toEqual({ key: 'k3-agent', label: 'K3' });
  expect(f.more.clicks).toBe(0); expect(f.more.events.map((e: any) => e.type)).toEqual([...entry, ...exit]);
  for (const [index, event] of (f.more.events as any[]).entries()) {
    expect(event.bubbles).toBe(index % 2 === 0); expect(event.composed).toBe(index % 2 === 0);
    expect(event.cancelable).toBe(index % 2 === 0);
    if (event.type.startsWith('pointer')) { expect(event.pointerType).toBe('mouse'); expect(event.isPrimary).toBe(true); }
    expect(event.relatedTarget).toBe(index < 4 ? f.menu : f.body);
  }
  expect(f.moreOption.clicks).toBe(0); expect(f.options.reduce((n, x) => n + x.clicks, 0)).toBe(0);
  expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
});

test('both delayed acknowledgements remain spent across repeated ordinary reads', async () => {
  const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
  let queued: any = null;
  f.more.onDispatch = event => { if (!['mouseover', 'mouseout'].includes(event.type)) return; expect(queued).toBeNull(); queued = event; };
  await discover(f); await discover(f);
  for (let i = 0; i < 5; i++) expect((await discover(f)).discoveryProgressDiagnostic.phase).toBe('moreOpening');
  expect(f.more.events).toHaveLength(4); expect(f.more.clicks).toBe(0);
  apply(queued); queued = null;
  await discover(f);
  for (let i = 0; i < 5; i++) expect((await discover(f)).discoveryProgressDiagnostic.phase).toBe('moreClosing');
  expect(f.more.events).toHaveLength(8); expect(f.more.clicks).toBe(0);
  apply(queued); queued = null;
  expect((await settle(f)).modelChoices).toEqual([instant]); expect(f.more.events).toHaveLength(8);
  expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
});

test('inert entry and inert exit never trigger a click fallback or a repeated sequence', async () => {
  for (const blocked of ['mouseover', 'mouseout']) {
    const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
    f.more.onDispatch = event => { if (event.type !== blocked) apply(event); };
    for (let i = 0; i < 10; i++) expect((await discover(f)).pending).toBe(true);
    expect(f.more.events.map((e: any) => e.type)).toEqual(blocked === 'mouseover' ? entry : [...entry, ...exit]);
    expect(f.more.clicks).toBe(0); expect(f.counts().sends).toBe(0);
  }
});

test('a lost callback after either pointer dispatch remains terminal without replay', async () => {
  for (const broken of ['pointerover', 'pointerout']) {
    const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
    f.more.onDispatch = event => { apply(event); if (event.type === broken) throw new Error('Synthetic lost acknowledgement'); };
    expect((await settle(f)).detail).toBe('unexpected_exception');
    const count = f.more.events.length;
    for (let i = 0; i < 3; i++) expect((await discover(f)).detail).toBe('terminal_operation');
    expect(f.more.events).toHaveLength(count); expect(f.more.clicks).toBe(0); expect(f.counts().sends).toBe(0);
  }
});

test('changed binding or owner after an entry claim cannot authorize another pointer event', async () => {
  for (const change of ['trigger', 'main', 'aria', 'label', 'owner', 'generation', 'route']) {
    const f = adapterFixture({ nestedSelected: true }); f.more.onDispatch = () => {};
    await discover(f); await discover(f);
    if (change === 'trigger' || change === 'main') {
      const old = change === 'trigger' ? f.more : f.menu, parent = old.parentElement!;
      const replacement = old.cloneNode(true); f.remove(old); parent.append(replacement);
    } else if (change === 'aria') f.more.setAttribute('aria-controls', 'foreign-menu');
    else if (change === 'label') f.moreCurrent.text = 'Instant';
    else if (change === 'route') f.document.URL = 'https://www.kimi.ai/chat/aaaa1111-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    const overrides = change === 'owner' ? { ownerToken: marker } : change === 'generation' ? { documentGeneration: marker } : {};
    const result = await f.run('discoverModels', { expectedModelChoice: undefined, ...overrides });
    expect(result.error).toBeDefined(); expect(f.more.events).toHaveLength(4); expect(f.more.clicks).toBe(0);
    expect(f.counts().sends).toBe(0);
  }
});

test('replaced checked row during pending exit cannot become selection proof', async () => {
  const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
  f.more.onDispatch = event => { if (event.type === 'mouseover') apply(event); };
  await discover(f); await discover(f); await discover(f);
  const original = f.moreOption; f.remove(original); f.moreMenu.append(original.cloneNode(true));
  expect((await discover(f)).detail).toBe('more_selected_label');
  expect((await discover(f)).detail).toBe('terminal_operation');
  expect(f.more.events).toHaveLength(8); expect(f.more.clicks).toBe(0); expect(f.counts().sends).toBe(0);
});

test('hit-test failure before the opening claim dispatches no pointer event', async () => {
  const f = adapterFixture({ nestedSelected: true }); f.occlude(f.more);
  await discover(f);
  expect((await discover(f)).detail).toBe('more_open_occluded');
  expect(f.more.events).toHaveLength(0); expect(f.more.clicks).toBe(0); expect(f.counts().sends).toBe(0);
});

test('already-selected Instant does not acquire submenu event behavior', async () => {
  const f = adapterFixture(); expect((await f.select()).modelEvidence.selected).toEqual(instant);
  expect(f.more.events).toHaveLength(0); expect(f.more.clicks).toBe(0); expect(f.trigger.clicks).toBe(2);
});


function partialMoreClose(f: ReturnType<typeof adapterFixture>, order: 'ariaFirst' | 'domFirst') {
  const dispatch = f.more.onDispatch!;
  f.more.onDispatch = (event: any) => {
    if (event.type !== 'mouseout') { dispatch(event); return; }
    if (order === 'ariaFirst') f.more.setAttribute('aria-expanded', 'false');
    else f.moreMenu.setAttribute('hidden', '');
  };
  return () => { f.more.setAttribute('aria-expanded', 'false'); f.moreMenu.setAttribute('hidden', ''); };
}

test('split submenu close acknowledgements remain pending in either DOM/ARIA order without replay', async () => {
  for (const order of ['ariaFirst', 'domFirst'] as const) {
    const f = adapterFixture({ nestedSelected: true }), acknowledge = partialMoreClose(f, order);
    await discover(f); await discover(f); await discover(f);
    for (let read = 0; read < 5; read++) {
      const result = await discover(f);
      expect(result.pending).toBe(true); expect(result.modelEvidence).toBeNull(); expect(result.modelChoices).toBeUndefined();
      expect(result.discoveryProgressDiagnostic).toMatchObject({ phase: 'moreClosing', mainMenuPresent: true,
        mainExpanded: true, submenuPresent: order === 'ariaFirst', submenuExpanded: order === 'domFirst', submenuCollapsed: order === 'ariaFirst' });
    }
    expect(f.more.events.map((event: any) => event.type)).toEqual([...entry, ...exit]);
    expect(f.trigger.clicks).toBe(1); expect(f.more.clicks + f.moreOption.clicks).toBe(0);
    acknowledge(); expect((await settle(f)).modelChoices).toEqual([instant]);
    expect(f.more.events).toHaveLength(8); expect(f.trigger.clicks).toBe(2);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  }
});

test('split main-menu close acknowledgements remain pending in either DOM/ARIA order without replay', async () => {
  for (const order of ['ariaFirst', 'domFirst'] as const) {
    const f = adapterFixture({ nestedSelected: true }), click = f.trigger.onClick!;
    f.trigger.onClick = () => {
      if (f.trigger.clicks === 1) { click(); return; }
      if (order === 'ariaFirst') f.trigger.setAttribute('aria-expanded', 'false');
      else f.menu.setAttribute('hidden', '');
    };
    for (let read = 0; read < 4; read++) await discover(f);
    for (let read = 0; read < 5; read++) {
      const result = await discover(f);
      expect(result.pending).toBe(true); expect(result.modelEvidence).toBeNull(); expect(result.modelChoices).toBeUndefined();
      expect(result.discoveryProgressDiagnostic).toMatchObject({ phase: 'closing', mainMenuPresent: order === 'ariaFirst',
        mainExpanded: order === 'domFirst', mainCollapsed: order === 'ariaFirst', submenuPresent: false });
    }
    expect(f.trigger.clicks).toBe(2); expect(f.more.events).toHaveLength(8);
    f.trigger.setAttribute('aria-expanded', 'false'); f.menu.setAttribute('hidden', '');
    expect((await settle(f)).modelChoices).toEqual([instant]);
    expect(f.trigger.clicks).toBe(2); expect(f.more.events).toHaveLength(8);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  }
});

test('pending submenu close still rejects changed physical bindings, checked selection and malformed ARIA', async () => {
  const mutations = [
    (f: ReturnType<typeof adapterFixture>) => { const old = f.more, parent = old.parentElement!; const next = old.cloneNode(true); f.remove(old); parent.append(next); },
    (f: ReturnType<typeof adapterFixture>) => { const old = f.moreMenu, parent = old.parentElement!; const next = old.cloneNode(true); f.remove(old); parent.append(next); },
    (f: ReturnType<typeof adapterFixture>) => { const old = f.moreOption, parent = old.parentElement!; const next = old.cloneNode(true); f.remove(old); parent.append(next); },
    (f: ReturnType<typeof adapterFixture>) => { f.moreOption.setAttribute('aria-checked', 'false'); },
    (f: ReturnType<typeof adapterFixture>) => { f.moreMenu.setAttribute('aria-labelledby', 'foreign-trigger'); },
    (f: ReturnType<typeof adapterFixture>) => { f.more.setAttribute('aria-expanded', 'unknown'); },
    (f: ReturnType<typeof adapterFixture>) => { f.world.__computaModelOwner = 'revoked'; },
  ];
  for (const mutate of mutations) {
    const f = adapterFixture({ nestedSelected: true }); partialMoreClose(f, 'ariaFirst');
    await discover(f); await discover(f); await discover(f);
    expect((await discover(f)).pending).toBe(true); mutate(f);
    expect((await discover(f)).error).toBeDefined();
    expect((await discover(f)).error).toBeDefined();
    expect(f.more.events).toHaveLength(8); expect(f.trigger.clicks).toBe(1);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  }
});

test('collapsed visible submenu without a claimed close cannot establish its first selection proof', async () => {
  const f = adapterFixture({ nestedSelected: true }), dispatch = f.more.onDispatch!;
  f.more.onDispatch = (event: any) => { dispatch(event); if (event.type === 'mouseover') f.more.setAttribute('aria-expanded', 'false'); };
  expect((await settle(f)).detail).toBe('picker_menu_binding');
  expect(f.more.events.map((event: any) => event.type)).toEqual(['pointerover', 'pointerenter', 'mouseover']);
  expect((await discover(f)).detail).toBe('terminal_operation');
  expect(f.more.events).toHaveLength(3); expect(f.counts().sends).toBe(0);
});

test('pending main close cannot adopt a replacement menu or changed selected label', async () => {
  for (const change of ['menu', 'label']) {
    const f = adapterFixture({ nestedSelected: true }), click = f.trigger.onClick!;
    f.trigger.onClick = () => { if (f.trigger.clicks === 1) click(); else f.trigger.setAttribute('aria-expanded', 'false'); };
    for (let i = 0; i < 4; i++) await discover(f);
    expect((await discover(f)).pending).toBe(true);
    if (change === 'menu') { const old = f.menu, parent = old.parentElement!; const next = old.cloneNode(true); f.remove(old); parent.append(next); }
    else f.triggerName.text = 'Changed';
    expect((await discover(f)).error).toBeDefined();
    expect(f.trigger.clicks).toBe(2); expect(f.more.events).toHaveLength(8);
    expect(f.counts().sends).toBe(0);
  }
});


function movingMore(f: ReturnType<typeof adapterFixture>) {
  const rect = f.more.getBoundingClientRect.bind(f.more), hit = f.document.elementFromPoint;
  let dx = 0, dy = 0, blocked: { x: number; y: number } | null = null;
  f.more.getBoundingClientRect = () => { const r = rect(); return { ...r, left: r.left + dx, top: r.top + dy }; };
  f.document.elementFromPoint = (x: number, y: number) => {
    const node = hit(x, y); if (node !== f.more) return node;
    const r = f.more.getBoundingClientRect();
    return x > r.left && x < r.left + r.width && y > r.top && y < r.top + r.height
      && !(blocked?.x === x && blocked?.y === y) ? f.more : f.body;
  };
  return { shift: (x: number, y: number) => { dx = x; dy = y; },
    block: (x: number, y: number) => { blocked = { x, y }; } };
}

test('a small layout shift preserves the original boundary point for discovery and Instant selection', async () => {
  for (const action of ['discover', 'select']) for (const phase of ['pointerover', 'pointerout']) {
    const f = adapterFixture({ nestedSelected: true }), layout = movingMore(f), dispatch = f.more.onDispatch!;
    f.more.onDispatch = (event: any) => { dispatch(event); if (event.type === phase) layout.shift(4, 2); };
    const result = action === 'discover' ? await settle(f) : await f.select();
    expect(result.error).toBeUndefined();
    if (action === 'discover') expect(result.modelChoices).toEqual([instant]);
    else expect(result.modelEvidence.selected).toEqual(instant);
    expect(f.more.events.map((event: any) => event.type)).toEqual([...entry, ...exit]);
    for (const offset of [0, 4]) {
      const phaseEvents = f.more.events.slice(offset, offset + 4) as any[];
      expect(new Set(phaseEvents.map(event => event.clientX)).size).toBe(1);
      expect(new Set(phaseEvents.map(event => event.clientY)).size).toBe(1);
    }
    expect(f.more.clicks + f.moreOption.clicks).toBe(0);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  }
});

test('a claimed point leaving the target, becoming occluded, or losing its physical binding stops without replay', async () => {
  for (const phase of ['pointerover', 'pointerout']) for (const change of ['outside', 'occluded', 'replacement']) {
    const f = adapterFixture({ nestedSelected: true }), layout = movingMore(f), dispatch = f.more.onDispatch!;
    f.more.onDispatch = (event: any) => {
      dispatch(event); if (event.type !== phase) return;
      if (change === 'outside') layout.shift(101, 0);
      else if (change === 'occluded') { layout.shift(4, 2); layout.block(event.clientX, event.clientY); }
      else { const parent = f.more.parentElement!, replacement = f.more.cloneNode(true); f.remove(f.more); parent.append(replacement); }
    };
    const result = await settle(f);
    expect(result.error).toBe('model_unverified');
    if (change === 'outside') expect(result.detail).toBe('more_point_outside');
    else if (change === 'occluded') expect(result.detail).toBe('more_center_occluded');
    else expect(result.detail).toBe(phase === 'pointerover' ? 'more_trigger_changed' : 'picker_menu_binding');
    const expectedEvents = phase === 'pointerover' ? ['pointerover'] : [...entry, 'pointerout'];
    expect(f.more.events.map((event: any) => event.type)).toEqual(expectedEvents);
    for (let repeat = 0; repeat < 3; repeat++) expect((await discover(f)).detail).toBe('terminal_operation');
    expect(f.more.events.map((event: any) => event.type)).toEqual(expectedEvents);
    expect(f.more.clicks + f.moreOption.clicks).toBe(0);
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  }
});


test('legacy coordinate flooring cannot move a claimed event outside or behind an overlay', async () => {
  for (const phase of ['pointerover', 'pointerout']) for (const change of ['left', 'top', 'occluded']) {
    const f = adapterFixture({ nestedSelected: true, mouseCoordinates: Math.floor });
    const originalRect = f.more.getBoundingClientRect.bind(f.more);
    f.more.getBoundingClientRect = () => { const r = originalRect(); return { ...r, left: r.left + 0.25, top: r.top + 0.25 }; };
    const layout = movingMore(f), dispatch = f.more.onDispatch!;
    f.more.onDispatch = (event: any) => {
      dispatch(event); if (event.type !== phase) return;
      const r = f.more.getBoundingClientRect();
      if (change === 'left') layout.shift(Math.floor(event.clientX) + 0.125 - r.left, 0);
      else if (change === 'top') layout.shift(0, Math.floor(event.clientY) + 0.125 - r.top);
      else layout.block(Math.floor(event.clientX), Math.floor(event.clientY));
    };
    const result = await settle(f);
    expect(result.detail).toBe(change === 'occluded' ? 'more_event_point_occluded' : 'more_event_point_outside');
    const count = phase === 'pointerover' ? 2 : 6;
    expect(f.more.events.map((event: any) => event.type)).toEqual([...entry, ...exit].slice(0, count));
    for (let repeat = 0; repeat < 3; repeat++) expect((await discover(f)).detail).toBe('terminal_operation');
    expect(f.more.events).toHaveLength(count); expect(f.more.clicks).toBe(0); expect(f.counts().sends).toBe(0);
  }
});

test('safe legacy flooring preserves the sequence but any other coordinate encoding rejects before dispatch', async () => {
  for (const encode of [Math.floor, (value: number) => value + 0.125, () => NaN]) {
    const f = adapterFixture({ nestedSelected: true, mouseCoordinates: encode });
    const rect = f.more.getBoundingClientRect.bind(f.more);
    f.more.getBoundingClientRect = () => { const r = rect(); return { ...r, left: r.left + 0.25, top: r.top + 0.25 }; };
    const result = await settle(f);
    if (encode === Math.floor) {
      expect(result.modelChoices).toEqual([instant]);
      expect(f.more.events.map((event: any) => event.type)).toEqual([...entry, ...exit]);
    } else {
      expect(result.detail).toBe('more_event_coordinates');
      expect((await discover(f)).detail).toBe('terminal_operation');
      expect(f.more.events.map((event: any) => event.type)).toEqual(['pointerover', 'pointerenter']);
    }
    expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
  }
});
