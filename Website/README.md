# Public website

This Octane/Vite package builds the static page for `computa.wtf`. The native
app's interface lives in the separate `WebUI/` package.

```sh
bun install --frozen-lockfile
bun run check
bun run build
```

For Cloudflare Pages, connect this repository and set the root directory to
`Website`, the build command to `bun install --frozen-lockfile && bun run build`,
and the output directory to `dist`. Set `BUN_VERSION` to `1.3.5` to match this
package's lockfile.
