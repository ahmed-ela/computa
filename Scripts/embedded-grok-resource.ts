import { readFileSync, writeFileSync } from 'node:fs';

export const grokResource = new URL('../Sources/Computa/Resources/BrowserModels/grok.js', import.meta.url);
export function composeGrokResource(): string {
  const source = ['embedded-provider-core.js', 'embedded-grok-layout-wake.js', 'embedded-grok-fresh-start.js', 'embedded-grok-model-controls.js', 'embedded-grok-editor-geometry.js', 'embedded-grok-transcript-rendering.js', 'embedded-grok-first-user-diagnostic.js', 'embedded-grok-usage-limit.js', 'embedded-grok-private-adapter.js']
    .map(name => readFileSync(new URL(name, import.meta.url), 'utf8')).join('\n');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  new AsyncFunction('input', source);
  return source;
}
if (import.meta.main) {
  if (process.argv.slice(2).some(value => value !== '--write')) throw new Error('Usage: bun scripts/embedded-grok-resource.ts [--write]');
  const source = composeGrokResource();
  if (process.argv.includes('--write')) writeFileSync(grokResource, source);
  else if (readFileSync(grokResource, 'utf8') !== source) throw new Error('Regenerate the Grok adapter with --write');
  console.log('Grok adapter resource verified');
}
