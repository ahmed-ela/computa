import { describe, expect, test } from 'bun:test';
import { formatWorkedFor } from '../src/duration';

describe('turn duration display', () => {
  test('shows seconds and floors fractional time', () => {
    expect(formatWorkedFor(0)).toBe('0s');
    expect(formatWorkedFor(1.9)).toBe('1s');
    expect(formatWorkedFor(59)).toBe('59s');
  });

  test('shows the two highest nonzero units from minutes through weeks', () => {
    expect(formatWorkedFor(65)).toBe('1m 5s');
    expect(formatWorkedFor(3_661)).toBe('1h 1m');
    expect(formatWorkedFor(90_061)).toBe('1d 1h');
    expect(formatWorkedFor(777_661)).toBe('1w 2d');
    expect(formatWorkedFor(3_601)).toBe('1h 1s');
  });

  test('handles invalid and negative timing values', () => {
    expect(formatWorkedFor(-2)).toBe('0s');
    expect(formatWorkedFor(Number.NaN)).toBe('0s');
    expect(formatWorkedFor(Number.POSITIVE_INFINITY)).toBe('0s');
  });
});
