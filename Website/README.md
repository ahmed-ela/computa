# Public website

This Octane/Vite package builds the static page for `computa.wtf`. The native
app's interface lives in the separate `WebUI/` package.

```sh
bun install --frozen-lockfile
bun run build
```

For Cloudflare Workers Builds in the personal account, connect this repository
to a Worker named `computa`. Set the production branch to `computa`, root
directory to `Website`, build command to
`bun install --frozen-lockfile && bun run build`, and deploy command to
`npx wrangler deploy`. Set `BUN_VERSION` to `1.3.5` to match the lockfile.
`wrangler.json` serves `dist` as SPA assets and binds `computa.wtf` as a custom
domain.

The build type-checks the site and runs its tests, including the macOS download
and Sparkle feed routing tests, before packaging assets. Keep non-production
branch previews enabled in Workers Builds. On a Cloudflare build, the homepage's
`computa-site-revision` meta tag contains `WORKERS_CI_COMMIT_SHA`. Compare it
with the squash merge commit to verify the public site has updated.
