import { expect, test } from 'bun:test';
import { fixture, choice, fingerprint, prompt, raw } from './embedded-qwen-adapter-fixture';

type Page = ReturnType<typeof fixture>;
function phases(f: Page, count: number) {
  const found = [f.phase];
  for (let index = 1; index < count; index++) {
    const shell = f.phase.parentElement!.cloneNode(true);
    f.flow.append(shell); found.push(shell.children[0] as typeof f.phase);
  }
  return found;
}
function failure(f: Page) {
  f.mountConversation();
  const dom = f.read(), result = dom.rawAnswer(dom.transcript().answer);
  expect(result).toEqual({text:'',finalMarkup:false,formatIssue:true});
  return result.failureStructure();
}
async function submitted(complete = true) {
  const f = fixture({completeOnSend:complete});
  for (let i = 0; i < 8; i++) if ((await f.run('selectModel',{modelChoice:choice('Qwen3.8-Max')})).selected) break;
  expect((await f.run('prepare')).prepared).toBe(true);
  expect((await f.run('insert',{prompt})).inserted).toBe(true);
  expect((await f.run('sendReady',{prompt})).sendReady).toBe(true);
  expect((await f.run('submit',{prompt,savedSubmissionFingerprint:await fingerprint(prompt)})).submitted).toBe(true);
  return f;
}

test('four refused phases distinguish nonempty text, empty wrappers and physically empty phases', () => {
  const f = fixture(), all = phases(f,4);
  all[1].children[0].children[0].children[0].children[0].children[0].text = '';
  all[2].replaceChildren();
  all[3].values.hidden = '';
  const result = failure(f);
  expect(result).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'phase_set',reason:'phase_count_limit',count:2,
    phaseSet:{matched:4,matchedOverflow:false,sampled:4,visible:3,textBearing:2,textBearingVisiblePhase:1,textEmpty:2,textUnknown:0,physicallyEmpty:1,
      singleWrapper:4,direct:0,otherWrapper:0}});
  expect(JSON.stringify(result)).not.toContain(raw);
  expect(f.mutations()).toBe(0);
});

test('sample and match caps are explicit and never read text values or arbitrary attributes', () => {
  const f = fixture(), all = phases(f,40);
  for (const phase of all) {
    phase.values.title = 'PRIVATE_ATTRIBUTE';
    Object.defineProperty(phase,'textContent',{get(){throw new Error('text value must not be read');}});
    Object.defineProperty(phase,'innerText',{get(){throw new Error('text value must not be read');}});
  }
  const result = failure(f);
  expect(result.phaseSet).toEqual({matched:33,matchedOverflow:true,sampled:16,visible:16,textBearing:16,textBearingVisiblePhase:16,textEmpty:0,textUnknown:0,
    physicallyEmpty:0,singleWrapper:16,direct:0,otherWrapper:0});
  expect(JSON.stringify(result)).not.toContain('PRIVATE');
  expect(JSON.stringify(result).length).toBeLessThanOrEqual(512);
});

test('bounded text scans report unknown rather than classifying unvisited branches as empty', () => {
  const f = fixture(), all = phases(f,4);
  all[0].replaceChildren(...Array.from({length:33},()=>new f.Node('SPAN')));
  all[1].replaceChildren();
  let current = all[1];
  for (let index = 0; index < 300; index++) { const next = new f.Node('DIV'); current.append(next); current = next; }
  const result = failure(f);
  expect(result.reason).toBe('phase_count_limit');
  expect(result.phaseSet.textUnknown).toBe(4);
  expect(result.phaseSet.textEmpty).toBe(0);
  expect(result.phaseSet.textBearing).toBe(0);
  expect(result.phaseSet.textBearingVisiblePhase).toBe(0);
  expect(f.mutations()).toBe(0);
});

test('diagnostic read failure preserves the original finite packet and all wrapper categories are closed', () => {
  const f = fixture(), all = phases(f,4);
  all[1].parentElement!.values['data-private'] = 'PRIVATE';
  const direct = all[2], parent = direct.parentElement!; parent.children = parent.children.filter(node=>node !== direct); direct.parentElement = null; f.flow.append(direct);
  expect(failure(f).phaseSet).toMatchObject({singleWrapper:2,direct:1,otherWrapper:1});
  Object.defineProperty(all[0],'getClientRects',{value:()=>{throw new Error('synthetic structural read failure');}});
  expect(failure(f)).toEqual({version:1,provider:'qwen',trigger:'authored_source',stage:'phase_set',reason:'phase_count_limit',count:2});
});

test('only the existing terminal exact-model inspect can publish the added facts; no Copy or other action occurs', async () => {
  for (const mode of ['terminal','streaming','cleanup','missingModel']) {
    const f = await submitted(mode !== 'streaming');
    expect((await f.run('inspect')).firstUserVerified).toBe(true);
    phases(f,4);
    const before = f.mutations();
    const result = await f.run('inspect',{
      ...(mode === 'missingModel' ? {} : {expectedModelChoice:choice('Qwen3.8-Max')}),
      ...(mode === 'cleanup' ? {savedCleanupInspection:true} : {})});
    if (mode === 'terminal') {
      expect(result.error).toBe('unsupported_response_format');
      expect(result.detail).toBe('authored_source');
      expect(result.adapterFailureStructure.phaseSet.matched).toBe(4);
      expect(result.text).toBeUndefined();
      expect(result.answerComplete).toBeUndefined();
    } else expect(result.adapterFailureStructure).toBeUndefined();
    expect(f.mutations()).toBe(before);
    expect(f.send.clicks).toBe(1);
    expect(f.actions.every(action=>action.clicks===0)).toBe(true);
    expect(f.more.clicks).toBe(0);
  }
  const f = await submitted(), result = await f.run('inspect');
  expect(result.text).toBe(raw);
  expect(result.answerComplete).toBe(true);
  expect(result.adapterFailureStructure).toBeUndefined();
});
