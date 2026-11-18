import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { composeSavedProvider, savedProviderResource, savedProviders, verifySavedProviderResource } from './embedded-saved-provider-resources';

describe('saved-conversation generated resources', () => {
  for (const provider of savedProviders) {
    test(`${provider}: shipped bytes exactly reproduce the common core, engine and provider hooks`, () => {
      const actual = readFileSync(savedProviderResource(provider), 'utf8');
      const core = readFileSync(new URL('./embedded-provider-core.js', import.meta.url), 'utf8');
      const engine = readFileSync(new URL('./EmbeddedSavedProviders/saved-conversation-engine.js', import.meta.url), 'utf8');
      expect(() => verifySavedProviderResource(provider, actual)).not.toThrow();
      expect(actual).toBe(composeSavedProvider(provider));
      expect(actual.startsWith(core + '\n' + engine + '\n')).toBe(true);
    });
  }

  test('a one-byte resource drift is rejected without rewriting it', () => {
    const provider = 'qwen', artifact = savedProviderResource(provider);
    const original = readFileSync(artifact, 'utf8');
    expect(() => verifySavedProviderResource(provider, original + '\n')).toThrow('differs from its canonical sources');
    expect(readFileSync(artifact, 'utf8')).toBe(original);
  });
});
