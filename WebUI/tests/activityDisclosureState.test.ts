import { describe, expect, test } from 'bun:test';
import { activityDisclosureOpen } from '../src/activityTimeline';

describe('activity disclosure state', () => {
  test('automatically opens while working before a final answer starts', () => {
    expect(activityDisclosureOpen(true, false)).toBe(true);
  });

  test('commentary and subsequent reasoning or tools do not collapse activity', () => {
    // The projector keeps hasFinalAnswer false for commentary, including
    // completed commentary. Empty final-answer placeholders are also false.
    const snapshots = [
      { phase: 'reasoning', hasFinalAnswer: false },
      { phase: 'commentary-started', hasFinalAnswer: false },
      { phase: 'commentary-completed', hasFinalAnswer: false },
      { phase: 'tool-started', hasFinalAnswer: false },
      { phase: 'tool-completed', hasFinalAnswer: false },
      { phase: 'empty-final-placeholder', hasFinalAnswer: false },
    ];
    for (const snapshot of snapshots) {
      expect(activityDisclosureOpen(true, snapshot.hasFinalAnswer)).toBe(true);
    }
  });

  test('automatically collapses at the first authoritative nonempty final answer', () => {
    expect(activityDisclosureOpen(true, false)).toBe(true);
    // Final text can stream while the native turn remains running.
    expect(activityDisclosureOpen(true, true)).toBe(false);
    expect(activityDisclosureOpen(false, true)).toBe(false);
  });

  test('inactive activity is collapsed when the user has not set an override', () => {
    expect(activityDisclosureOpen(false, false)).toBe(false);
    expect(activityDisclosureOpen(false, true)).toBe(false);
  });

  test('manual open and manual closed both take precedence in every phase', () => {
    for (const isRunning of [false, true]) {
      for (const hasFinalAnswer of [false, true]) {
        expect(activityDisclosureOpen(isRunning, hasFinalAnswer, true)).toBe(true);
        expect(activityDisclosureOpen(isRunning, hasFinalAnswer, false)).toBe(false);
      }
    }
  });

  test('a manually closed disclosure never reopens due to continued updates or resumed work', () => {
    const manualOpen = false;
    const phases = [
      { isRunning: true, hasFinalAnswer: false },
      { isRunning: true, hasFinalAnswer: false },
      { isRunning: false, hasFinalAnswer: false },
      { isRunning: true, hasFinalAnswer: false },
      { isRunning: true, hasFinalAnswer: true },
      { isRunning: false, hasFinalAnswer: true },
    ];
    expect(phases.map(({ isRunning, hasFinalAnswer }) =>
      activityDisclosureOpen(isRunning, hasFinalAnswer, manualOpen),
    )).toEqual([false, false, false, false, false, false]);
  });

  test('a manually opened disclosure survives final streaming and turn completion', () => {
    const manualOpen = true;
    expect(activityDisclosureOpen(true, false, manualOpen)).toBe(true);
    expect(activityDisclosureOpen(true, true, manualOpen)).toBe(true);
    expect(activityDisclosureOpen(false, true, manualOpen)).toBe(true);
  });

  test('undefined means automatic, not an explicit closed preference', () => {
    expect(activityDisclosureOpen(true, false, undefined)).toBe(true);
    expect(activityDisclosureOpen(true, false, false)).toBe(false);
  });

  test('independently keyed groups do not share manual preferences', () => {
    const preferences: Record<string, boolean | undefined> = {
      'task-one:turn-one': false,
      'task-one:turn-two': true,
    };
    expect(activityDisclosureOpen(true, false, preferences['task-one:turn-one'])).toBe(false);
    expect(activityDisclosureOpen(false, true, preferences['task-one:turn-two'])).toBe(true);
    expect(activityDisclosureOpen(true, false, preferences['task-two:turn-one'])).toBe(true);
  });
});
