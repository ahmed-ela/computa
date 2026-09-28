# Download and install Mactopus

Mactopus releases are for Apple Silicon Macs running macOS 14 or later. A clean
Mac needs an internet connection and about 10 GB of free space for the app,
Python/MLX dependencies, model cache, and model staging. The installer downloads
the pinned Qwen 3.5 4B model (about 3.06 GB); weights are not inside the DMG.
Recipients do not need Xcode, Homebrew, Git, Bun, or an existing Python install.

The first preview uses the explicit tag
[`v0.1.0-preview.1`](https://github.com/ahmed-wlb/mactopus/releases/tag/v0.1.0-preview.1).
This is a private repository: sign in to GitHub with repository access to obtain
its release assets. Use that tag rather than GitHub's `latest` endpoint, which
does not select prereleases. These instructions describe the release workflow;
the presence of scripts in the repository does not establish that an asset has
been published or tested on a clean Mac.

## Install a release

1. Download the DMG, its matching `.manifest.json`, and `SHA256SUMS` from the same
   release. In their download directory, run `shasum -a 256 --check SHA256SUMS`.
2. Quit Mactopus, then open the DMG. Read `READ ME.txt` for the asset's signing
   and notarization status.
3. On a clean Mac, open **Install Mactopus.command** and type **INSTALL** when
   prompted. It copies the app to `~/Applications/Mactopus.app`, provisions the
   private runtime and model, and opens the installed app after verification.
4. Complete macOS permissions and any browser connection consent in the app.
   The installer does not grant permissions or pair a browser extension.

A `signed-test` asset has Developer ID signatures but is **not notarized**.
macOS may block its downloaded app or installer. It is a preview for controlled
testing, not a claim of a frictionless Gatekeeper-approved install. Obtain a
notarized release for normal distribution. Neither the installer nor these
instructions remove quarantine, disable security checks, or alter the signed
bundle.

For an already configured Mac, the DMG also contains an **Applications** shortcut
for dragging the app into `/Applications`. This does not install Python, MLX, or
the model and uses a different location from the command installer. Prefer the
command installer for an update with an automatic backup in `~/Applications`.
If both locations contain Mactopus, open the intended copy explicitly.

If GitHub CLI is already available and authenticated, the equivalent download is:

```sh
gh release download v0.1.0-preview.1 --repo ahmed-wlb/mactopus \
  --pattern '*.dmg' --pattern '*.manifest.json' --pattern SHA256SUMS \
  --dir ./mactopus-preview
cd ./mactopus-preview
shasum -a 256 --check SHA256SUMS
```

After mounting the DMG, the command below explicitly authorizes the same runtime
and model downloads without the interactive prompt. Add `--no-launch` to leave
the app closed after installation.

```sh
/bin/zsh -f "/Volumes/Mactopus 0.1.0-preview.1/Install Mactopus.command" --download-model
```

## Updates, storage, and retries

The installer refuses to replace a running Mactopus app. It stages and verifies
the incoming signed app, verifies or provisions the runtime and model, and only then moves
an existing app into `~/Applications/Mactopus Backups/release-*/Mactopus.app`.
If the final replacement move fails, it attempts to restore that backup. It
does not delete conversations, preferences, browser tabs, or previous backups.

Runtime files live under `~/Library/Application Support/LocalCodex/MLX`:

| Location | Purpose |
| --- | --- |
| `python` | Managed Python 3.12.13, without a global executable or shell-profile change |
| `venv` | Hash-locked MLX runtime packages |
| `models` | Verified pinned model files used by Mactopus |
| `model-download-cache` | Reusable Hugging Face downloads, including interrupted transfers |
| `uv-cache` | Reusable dependency downloads |

The verified standalone `uv` bootstrap is kept under
`~/Library/Application Support/LocalCodex/Installer`. Its official
[`0.12.19` release](https://github.com/astral-sh/uv/releases/tag/0.12.19) and SHA-256
are pinned in [`uv.lock.json`](../Scripts/distribution/uv.lock.json). The installer
checks that hash before executing it. Python, MLX packages, and model revisions
are pinned separately by the bundled installers and lock files.

An existing MLX environment is checked against this release's Python and package
versions and with `uv pip check`. A compatible environment is reused without
synchronizing packages or replacing its installation receipt. An incompatible
or incomplete environment causes installation to stop with the previous app and
environment left untouched; it requires separate inspection and repair before
retrying. These are version and dependency checks, not a rehash of installed
package files. Only an absent environment is provisioned automatically.

If a model download fails, close Mactopus and run the same installer again.
Completed model downloads and partial download caches are retained; an already
complete model is verified before reuse. The previous app remains in place until
provisioning succeeds. A failed first-time dependency installation can leave an
incomplete private environment, which the next run preserves and reports for
repair instead of overwriting it. Failed staging directories are retained for
inspection. No shared Python installation is used.

## Produce a release

Maintainers need a built app, an installed Developer ID Application identity,
Bun, and the standard macOS development tools. The
[source build instructions](BUILDING.md) are separate from the recipient's
installation. Package an explicitly selected build, not a running installation.

Sign a new copy first:

```sh
bun Scripts/sign-release.ts \
  --app /absolute/path/build/Mactopus.app \
  --output /absolute/path/signed/Mactopus.app \
  --identity 'Developer ID Application: Your Name (TEAMID)'
```

The signer signs the bundled agent runtime and Chrome helper with secure
timestamps, updates the runtime integrity manifest for the signed executable,
and seals the app. It never edits the source bundle. Signing alone is not
notarization.

For a deliberately non-notarized preview:

```sh
bun Scripts/package-release.ts \
  --app /absolute/path/signed/Mactopus.app \
  --output /absolute/path/release-output \
  --tag v0.1.0-preview.1 --channel signed-test
```

The normal default channel is `notarized`. It additionally requires a stapled
app notarization ticket and a successful Gatekeeper assessment before packaging.
App notarization and DMG notarization are separate: the packager does not submit,
sign, or staple the resulting DMG. If a DMG is subsequently signed or stapled,
recompute its entry in the external `SHA256SUMS` before publishing because those
operations change its bytes. Do not describe a `signed-test` asset as notarized.

`--tag` is required. Optional `--version` must equal the tag without its leading
`v`; for this preview it is `0.1.0-preview.1`. The manifest records that release
version separately from the app's `0.1.0` bundle version. Existing output assets
are never overwritten.

The packager validates the app identity, architecture, minimum macOS version,
Developer ID signatures, runtime integrity manifest, and system-only dynamic
library dependencies. It copies the app with extended attributes and resource
forks preserved, verifies that the signed file tree is unchanged, adds the
installer and locked dependencies, creates a compressed DMG, and runs
`hdiutil verify`. It does not build, install, launch, sign, notarize, or publish.

The output directory contains the DMG, a release manifest, and `SHA256SUMS`.
The manifest records every app file's hash, size, and executable bit (or an
internal symlink target), plus the installer dependency pins. The mounted image
also has checksums for the installer files and manifest. This is a repeatable
packaging process with a deterministic payload manifest for identical inputs;
DMG filesystem metadata means separate image builds need not be byte-identical.

Focused tests mock downloads and system commands; they do not constitute a clean
Mac installation, notarization, or live app test:

```sh
bun test Scripts/package-release.test.ts Scripts/sign-release.test.ts
python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'
/bin/zsh -n 'Scripts/distribution/Install Mactopus.command'
```

Before publishing, verify the exact final assets and document the actual signing,
notarization, installation, and live validation performed. The lookup and model
stream limitations recorded in [TODO.md](../TODO.md) remain applicable to this
preview.
