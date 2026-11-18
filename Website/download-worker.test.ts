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
  expect(newestMacDownload([alpha(600), release, alpha(601)])).toBe(base + '/download/v0.8.0-alpha.584/Computa-0.8.0-alpha.584-arm64.dmg');
  expect(newestMacDownload([])).toBe(base);
});

test('the update feed only follows published alphas with both a notarized disk image and an appcast', () => {
  function withFeed(n: number) {
    const r = alpha(n);
    r.assets[0].name = r.assets[0].name.replace('-signed-test', '');
    r.assets.push({ name: 'appcast.xml', state: 'uploaded', size: 128 });
    return r;
  }
  const missing = withFeed(590); missing.assets.pop();
  const signedTest = alpha(589); signedTest.assets.push({ name: 'appcast.xml', state: 'uploaded', size: 128 });
  const candidates = [missing, { ...withFeed(591), draft: true }, signedTest];
  expect(newestMacDownload(candidates, true)).toBe(null);
  expect(newestMacDownload([...candidates, withFeed(587), withFeed(586)], true)).toBe(base + '/download/v0.8.0-alpha.587/appcast.xml');
});
