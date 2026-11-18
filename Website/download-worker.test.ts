import { expect, test } from 'bun:test';
import { newestMacDownload } from './download-worker.js';

const base = 'https://github.com/ahmed-ela/computa/releases';
function alpha(build: number, overrides = {}) {
  const version = '0.8.0-alpha.' + build;
  return { tag_name: 'v' + version, published_at: '2026-11-18', draft: false,
    assets: [{ name: 'Computa-' + version + '-arm64-signed-test.dmg', state: 'uploaded', size: 123 }],
    ...overrides };
}
test('selects the highest published build with a ready macOS package', () => {
  expect(newestMacDownload([alpha(590, { draft: true }), alpha(588, { published_at: null }),
    alpha(587, { assets: [] }), alpha(363), alpha(584), alpha(585, { tag_name: 'broken' })]))
    .toBe(base + '/download/v0.8.0-alpha.584/Computa-0.8.0-alpha.584-arm64-signed-test.dmg');
});
test('prefers a notarized package and falls back to public releases when none are ready', () => {
  const release = alpha(584);
  release.assets.push({ ...release.assets[0], name: 'Computa-0.8.0-alpha.584-arm64.dmg' });
  expect(newestMacDownload([release])).toBe(base + '/download/v0.8.0-alpha.584/Computa-0.8.0-alpha.584-arm64.dmg');
  expect(newestMacDownload([])).toBe(base);
});
