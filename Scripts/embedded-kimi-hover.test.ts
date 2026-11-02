import { expect, test } from 'bun:test';
import { adapterFixture, instant, marker } from './embedded-kimi-adapter-fixture';

const discover = (f: ReturnType<typeof adapterFixture>) => f.run('discoverModels', { expectedModelChoice: undefined });
async function settle(f: ReturnType<typeof adapterFixture>) {
  for (let i = 0; i < 8; i++) { const r = await discover(f); if (!r.pending) return r; }
  throw new Error('Bounded fixture discovery did not settle');
}

test('candidate uses exactly one pointer entry and exit, with no submenu click or model substitution', async () => {
  const f = adapterFixture({ nestedSelected: true });
  const result = await settle(f);
  expect(result.modelChoices).toEqual([instant]); expect(result.modelEvidence.selected).toEqual({ key: 'k3-agent', label: 'K3' });
  expect(f.more.clicks).toBe(0); expect(f.more.events.map((e: any) => e.type)).toEqual(['pointerover', 'pointerout']);
  for (const event of f.more.events as any[]) {
    expect(event.bubbles).toBe(true); expect(event.composed).toBe(true);
    expect(event.pointerType).toBe('mouse'); expect(event.isPrimary).toBe(true); expect(event.relatedTarget).toBe(event.type === 'pointerover' ? f.menu : f.body);
  }
  expect(f.moreOption.clicks).toBe(0); expect(f.options.reduce((n, x) => n + x.clicks, 0)).toBe(0);
  expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
});

test('both delayed acknowledgements remain spent across repeated ordinary reads', async () => {
  const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
  let queued: any = null;
  f.more.onDispatch = event => { expect(queued).toBeNull(); queued = event; };
  await discover(f); await discover(f);
  for (let i = 0; i < 5; i++) expect((await discover(f)).discoveryProgressDiagnostic.phase).toBe('moreOpening');
  expect(f.more.events).toHaveLength(1); expect(f.more.clicks).toBe(0);
  apply(queued); queued = null;
  await discover(f);
  for (let i = 0; i < 5; i++) expect((await discover(f)).discoveryProgressDiagnostic.phase).toBe('moreClosing');
  expect(f.more.events).toHaveLength(2); expect(f.more.clicks).toBe(0);
  apply(queued); queued = null;
  expect((await settle(f)).modelChoices).toEqual([instant]); expect(f.more.events).toHaveLength(2);
  expect(f.counts()).toEqual({ insertions: 0, sends: 0, confirms: 0 });
});

test('inert entry and inert exit never trigger a click fallback or a second event', async () => {
  for (const blocked of ['pointerover', 'pointerout']) {
    const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
    f.more.onDispatch = event => { if (event.type !== blocked) apply(event); };
    for (let i = 0; i < 10; i++) expect((await discover(f)).pending).toBe(true);
    expect(f.more.events.map((e: any) => e.type)).toEqual(blocked === 'pointerover' ? ['pointerover'] : ['pointerover', 'pointerout']);
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
    expect(result.error).toBeDefined(); expect(f.more.events).toHaveLength(1); expect(f.more.clicks).toBe(0);
    expect(f.counts().sends).toBe(0);
  }
});

test('replaced checked row during pending exit cannot become selection proof', async () => {
  const f = adapterFixture({ nestedSelected: true }), apply = f.more.onDispatch!;
  f.more.onDispatch = event => { if (event.type === 'pointerover') apply(event); };
  await discover(f); await discover(f); await discover(f);
  const original = f.moreOption; f.remove(original); f.moreMenu.append(original.cloneNode(true));
  expect((await discover(f)).detail).toBe('more_selected_label');
  expect((await discover(f)).detail).toBe('terminal_operation');
  expect(f.more.events).toHaveLength(2); expect(f.more.clicks).toBe(0); expect(f.counts().sends).toBe(0);
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
