import { expect, test } from 'bun:test';
import { codexModelReady } from '../src/codexModelSelection';

test('a next-turn selection survives refresh with the desktop closed', () => {
  const next = {kind:'next', model:'new', expected:'old'} as const;
  expect(codexModelReady(next, {current:'old', live:false})).toBe(true);
  expect(codexModelReady(next, {current:'other', live:true})).toBe(false);
  expect(codexModelReady(next)).toBe(false);
});

test('selecting a model works when an older chat has no recorded model', () => {
  const next = {kind:'next', model:'new', expected:null} as const;
  expect(codexModelReady(next, {current:null, live:false})).toBe(true);
  expect(codexModelReady(next, {current:'different', live:false})).toBe(false);
});

test('following the current model requires a catalog for this chat', () => {
  expect(codexModelReady({kind:'follow'})).toBe(false);
  expect(codexModelReady({kind:'follow'}, {current:'model', live:false})).toBe(true);
});
