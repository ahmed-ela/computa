const repo = 'ahmed-ela/kolmogor';
const releasesURL = `https://github.com/${repo}/releases`;
const apiURL = `https://api.github.com/repos/${repo}/releases?per_page=100`;

// GitHub's "latest" API excludes alpha releases. Kolmogor build numbers increase
// across versions, so publishing an older build later cannot roll downloads back.
export function newestMacDownload(releases, appcast = false) {
  let newestBuild = 0;
  let notarizedSelected = false;
  let download = appcast ? null : releasesURL;
  for (const release of releases) {
    const match = /^v\d+\.\d+\.\d+-alpha\.([1-9]\d{0,3})$/.exec(release.tag_name);
    if (!match || release.draft || !release.published_at) continue;
    const suffix = `-${release.tag_name.slice(1)}-arm64`;
    const ready = name => release.assets?.find(item => item.name === name && item.state === 'uploaded' && item.size > 0);
    const dmg = ending => ready('Kolmogor' + suffix + ending) || ready('Computa' + suffix + ending);
    const notarized = dmg('.dmg');
    const asset = appcast ? notarized && ready('appcast.xml') : notarized || dmg('-signed-test.dmg');
    const build = Number(match[1]);
    const prefer = notarized && !notarizedSelected;
    if (asset && (prefer || Boolean(notarized) === notarizedSelected && build > newestBuild)) {
      newestBuild = build;
      notarizedSelected = Boolean(notarized);
      download = `${releasesURL}/download/${release.tag_name}/${asset.name}`;
    }
  }
  return download;
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const appcast = path === '/appcast.xml';
    if (!appcast && path !== '/download' && path !== '/download/') return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    let location = appcast ? null : releasesURL;
    try {
      const response = await fetch(apiURL, {
        headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'kolmogor-download' },
        cf: { cacheEverything: true, cacheTtlByStatus: { '200': 60, '400-599': 0 } },
      });
      if (response.ok) location = newestMacDownload(await response.json(), appcast);
    } catch {
      // The public release list also works when GitHub's API is unavailable.
    }
    if (!location) return new Response(null, { status: 503, headers: { 'Retry-After': '60', 'Cache-Control': 'no-store' } });
    return new Response(null, { status: 302, headers: { Location: location, 'Cache-Control': 'no-store' } });
  },
};
