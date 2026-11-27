import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';

await build({
  entryPoints: ['web/display.js'],
  bundle: true,
  format: 'esm',
  minify: true,
  outfile: 'public/display.js',
  banner: {js: '/*! Includes noVNC 1.7.0. Source: https://github.com/novnc/noVNC/tree/v1.7.0 – notices: /viewer-licenses.txt */'},
});
const noVnc = new URL('./node_modules/@novnc/novnc/', import.meta.url);
const files = ['LICENSE.txt', 'AUTHORS', 'docs/LICENSE.MPL-2.0', 'docs/LICENSE.BSD-2-Clause', 'docs/LICENSE.BSD-3-Clause', 'docs/LICENSE.OFL-1.1'];
const notices = await Promise.all(files.map(async file => file+'\n'+await readFile(new URL(file, noVnc), 'utf8')));
await writeFile('public/viewer-licenses.txt', notices.join('\n\n'));
