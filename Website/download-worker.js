const repo = 'ahmed-ela/computa';
const releasesURL = `https://github.com/${repo}/releases`;
const apiURL = `https://api.github.com/repos/${repo}/releases?per_page=100`;

// GitHub's "latest" API excludes alpha releases. Computa build numbers increase
// across versions, so publishing an older build later cannot roll downloads back.
export function newestMacDownload(releases) {
  let newestBuild = 0;
  let download = releasesURL;
  for (const release of releases) {
    const match = /^v\d+\.\d+\.\d+-alpha\.([1-9]\d{0,3})$/.exec(release.tag_name);
    if (!match || release.draft || !release.published_at || Number(match[1]) <= newestBuild) continue;
    const base = `Computa-${release.tag_name.slice(1)}-arm64`;
    const asset = [base + '.dmg', base + '-signed-test.dmg'].map(name =>
      release.assets?.find(item => item.name === name && item.state === 'uploaded' && item.size > 0)
    ).find(Boolean);
    if (asset) {
      newestBuild = Number(match[1]);
      download = `${releasesURL}/download/${release.tag_name}/${asset.name}`;
    }
  }
  return download;
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path !== '/download' && path !== '/download/') return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    let location = releasesURL;
    try {
      const response = await fetch(apiURL, {
        headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'computa-download' },
        cf: { cacheEverything: true, cacheTtlByStatus: { '200': 60, '400-599': 0 } },
      });
      if (response.ok) location = newestMacDownload(await response.json());
    } catch {
      // The public release list also works when GitHub's API is unavailable.
    }
    return new Response(null, { status: 302, headers: { Location: location, 'Cache-Control': 'no-store' } });
  },
};
