# Public website

This Octane/Vite package builds the static page for `computa.wtf`. The native
app's interface lives in the separate `WebUI/` package.

```sh
bun install --frozen-lockfile
bun run check
bun run build
```

For Cloudflare Workers Builds in the personal account, connect this repository
to a Worker named `computa`. Set the production branch to `Macrouse`, root
directory to `Website`, build command to
`bun install --frozen-lockfile && bun run build`, and deploy command to
`npx wrangler deploy`. Set `BUN_VERSION` to `1.3.5` to match the lockfile.
`wrangler.json` serves `dist` as SPA assets and binds `computa.wtf` as a custom
domain.
