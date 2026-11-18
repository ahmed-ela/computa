import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

export const savedProviders = ['qwen', 'deepseek'] as const;
export type SavedProvider = typeof savedProviders[number];

export function savedProviderResource(provider: SavedProvider): URL {
  if (!savedProviders.includes(provider)) throw new Error('Unknown saved-conversation provider');
  return new URL(`../Sources/Computa/Resources/BrowserModels/${provider}.js`, import.meta.url);
}

/** One common engine with provider DOM semantics and an explicit entry point.
 * Syntax validation does not execute an adapter or contact a website. */
export function composeSavedProvider(provider: SavedProvider): string {
  savedProviderResource(provider); // Validate before resolving any source path.
  const sources = [
    new URL('./embedded-provider-core.js', import.meta.url),
    new URL('./EmbeddedSavedProviders/saved-conversation-engine.js', import.meta.url),
    new URL(`./EmbeddedSavedProviders/${provider}-dom.js`, import.meta.url),
    new URL(`./EmbeddedSavedProviders/${provider}-entry.js`, import.meta.url)
  ].map(file => readFileSync(file, 'utf8'));
  const script = sources.join('\n');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  new AsyncFunction('input', script);
  return script;
}

export function verifySavedProviderResource(provider: SavedProvider, actual: string): void {
  if (actual !== composeSavedProvider(provider)) {
    throw new Error(`${provider}.js differs from its canonical sources; run bun Scripts/embedded-saved-provider-resources.ts --write`);
  }
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  if (args.length > 1 || args[0] && !['--check', '--write'].includes(args[0])) {
    throw new Error('Usage: bun Scripts/embedded-saved-provider-resources.ts [--check|--write]');
  }
  const write = args[0] === '--write';
  for (const provider of savedProviders) {
    const script = composeSavedProvider(provider), artifact = savedProviderResource(provider);
    if (write) writeFileSync(artifact, script);
    else verifySavedProviderResource(provider, readFileSync(artifact, 'utf8'));
    console.log(JSON.stringify({ provider, operation: write ? 'write' : 'check',
      bytes: Buffer.byteLength(script), sha256: createHash('sha256').update(script).digest('hex') }));
  }
}
