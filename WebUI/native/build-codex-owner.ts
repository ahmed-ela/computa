import { copyFile } from 'node:fs/promises';
const output = '../Sources/Computa/Resources/CodexDesktop';
const result = await Bun.build({entrypoints: ['native/codex-owner.mjs'], target: 'node', format: 'cjs',
  naming: 'codex-owner.cjs', outdir: output, minify: true, external: ['bufferutil', 'utf-8-validate']});
if (!result.success) throw new AggregateError(result.logs, 'Codex owner adapter build failed');
await copyFile('node_modules/ws/LICENSE', output + '/ws-LICENSE.txt');
