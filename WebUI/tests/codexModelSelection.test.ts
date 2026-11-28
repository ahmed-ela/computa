import { expect, test } from 'bun:test';
import { codexModelReady, observeCodexModel } from '../src/codexModelSelection';

test('a selected model can send only on a matching live owner', () => {
  const intent = {kind:'bound', model:'chosen'} as const;
  expect(codexModelReady(intent, {live:true, current:'chosen'})).toBe(true);
  expect(codexModelReady(intent, {live:false, current:'chosen'})).toBe(false);
  expect(codexModelReady(intent, {live:true, current:'other'})).toBe(false);
});

test('a lost acknowledgment needs independent live confirmation', () => {
  const intent = {kind:'unconfirmed', model:'chosen'} as const;
  expect(observeCodexModel(intent, {live:false, current:'chosen'})).toBe(intent);
  expect(observeCodexModel(intent, {live:true, current:'other'})).toBe(intent);
  expect(observeCodexModel(intent, {live:true, current:'chosen'})).toEqual({kind:'bound', model:'chosen'});
});

test('a matching past turn cannot confirm the current live model', () => {
  const intent = {kind:'handoff', model:'chosen'} as const;
  expect(codexModelReady(intent, {live:false, current:'other'})).toBe(false);
  expect(observeCodexModel(intent, {live:false, current:'chosen'})).toBe(intent);
  expect(observeCodexModel(intent, {live:true, current:'chosen'})).toEqual({kind:'bound', model:'chosen'});
});
