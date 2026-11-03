import { describe, expect, test } from 'bun:test';
import { fixture, choice } from './embedded-qwen-adapter-fixture';
type Fixture = ReturnType<typeof fixture>;
const desired = choice('Qwen3.8-Max');
async function optionClosing(order: 'ariaFirst' | 'domFirst', settleChoice = true) {
  const f = fixture();
  expect((await f.run('selectModel', { modelChoice: desired })).pending).toBe(true);
  f.choices[1].onClick = () => {
    if (settleChoice) select(f);
    if (order === 'ariaFirst') f.trigger.setAttribute('aria-expanded', 'false');
    else f.modelMenu.setAttribute('hidden', '');
  };
  return f;
}
function select(f: Fixture) {
  f.modelName.text = desired.label;
  f.choices.forEach((node, i) => {
    node.setAttribute('aria-selected', String(i === 1));
    node.setAttribute('class', 'wms-list__item' + (i === 1 ? ' wms-list__item--selected' : ''));
  });
}
function finish(f: Fixture) { f.trigger.setAttribute('aria-expanded', 'false'); f.modelMenu.setAttribute('hidden', ''); }
function pending(result: any) {
  expect(result.error).toBeUndefined(); expect(result.pending).toBe(true);
  expect(result.modelEvidence).toBeNull(); expect(result.selected).toBeUndefined();
}
async function run(f: Fixture) { return await f.run('selectModel', { modelChoice: desired }); }

describe('Qwen claimed option automatic close', () => {
  test('both split orders wait without a second click and still reopen to verify the selected row', async () => {
    for (const order of ['ariaFirst', 'domFirst'] as const) {
      const f = await optionClosing(order); pending(await run(f));
      for (let i = 0; i < 3; i++) pending(await run(f));
      expect(f.trigger.clicks).toBe(1); expect(f.choices[1].clicks).toBe(1);
      finish(f); pending(await run(f)); // One fresh reopen, no model authority.
      expect(f.trigger.clicks).toBe(2);
      pending(await run(f)); // Checked row re-read; one explicit final close.
      expect(f.trigger.clicks).toBe(3);
      const result = await run(f); expect(result.selected).toBe(true); expect(result.modelEvidence.selected).toEqual(desired);
      expect(f.choices[1].clicks).toBe(1); expect(f.send.clicks).toBe(0); expect(f.editor.events.length).toBe(0);
    }
  });

  test('the unchanged prior selection may settle later but never supplies the requested model authority', async () => {
    const f = await optionClosing('ariaFirst', false); pending(await run(f)); pending(await run(f));
    finish(f); pending(await run(f)); // Closed with the prior label: no verify click yet.
    expect(f.trigger.clicks).toBe(1); expect(f.choices[1].clicks).toBe(1);
    select(f); pending(await run(f)); pending(await run(f));
    expect((await run(f)).modelEvidence.selected).toEqual(desired);
    expect(f.trigger.clicks).toBe(3); expect(f.choices[1].clicks).toBe(1);
  });

  test('label and checked-row acknowledgements can settle in either order only during the exact claimed option close', async () => {
    for (const labelFirst of [true, false]) {
      const f = await optionClosing('ariaFirst', false);
      f.choices[1].onClick = () => {
        if (labelFirst) f.modelName.text = desired.label;
        else {
          f.choices.forEach((node,i)=>{node.setAttribute('aria-selected',String(i===1));node.setAttribute('class','wms-list__item'+(i===1?' wms-list__item--selected':''));});
        }
        f.trigger.setAttribute('aria-expanded','false');
      };
      pending(await run(f)); pending(await run(f));
      expect(f.trigger.clicks).toBe(1); expect(f.choices[1].clicks).toBe(1);
      select(f); finish(f);
      pending(await run(f)); pending(await run(f));
      expect((await run(f)).modelEvidence.selected).toEqual(desired);
      expect(f.trigger.clicks).toBe(3); expect(f.choices[1].clicks).toBe(1); expect(f.send.clicks).toBe(0);
    }
  });

  test('a remounted target/menu or third selection cannot inherit the claimed option', async () => {
    const cases: [(f: Fixture) => void][] = [
      [f => { const copy=f.choices[1].cloneNode(true);f.choices[1].detach();f.modelMenu.append(copy); }],
      [f => { const copy=f.modelMenu.cloneNode(true);f.modelMenu.detach();f.body.append(copy); }],
      [f => { const copy=f.trigger.cloneNode(true);f.trigger.detach();f.body.append(copy); }],
      [f => { f.modelName.text='Qwen3.8-Omni-Flash'; }],
    ];
    for (const [mutate] of cases) {
      const f=await optionClosing('ariaFirst');pending(await run(f));mutate(f);
      expect((await run(f)).error).toBeDefined();expect((await run(f)).detail).toBe('terminal_operation');
      expect(f.choices[1].clicks).toBe(1);expect(f.trigger.clicks).toBe(1);expect(f.send.clicks).toBe(0);
    }
  });

  test('fresh checked-row verification cannot be skipped when the reopening no longer confirms the target', async () => {
    const f=await optionClosing('ariaFirst');pending(await run(f));finish(f);
    f.trigger.onClick=()=>{
      f.openPicker(); f.modelName.text=choice().label;
      f.choices.forEach((node,i)=>{node.setAttribute('aria-selected',String(i===0));node.setAttribute('class','wms-list__item'+(i===0?' wms-list__item--selected':''));});
    };
    pending(await run(f)); pending(await run(f)); pending(await run(f));
    expect(f.trigger.clicks).toBe(2);expect(f.choices[1].clicks).toBe(1);expect(f.send.clicks).toBe(0);
  });

  test('lost option callback cannot be observed as successful or replayed', async () => {
    const f=await optionClosing('ariaFirst');
    f.choices[1].onClick=()=>{select(f);f.trigger.setAttribute('aria-expanded','false');throw new Error('Synthetic lost option callback');};
    expect((await run(f)).error).toBeDefined();finish(f);
    expect((await run(f)).detail).toBe('terminal_operation');expect(f.choices[1].clicks).toBe(1);expect(f.trigger.clicks).toBe(1);
  });
});
