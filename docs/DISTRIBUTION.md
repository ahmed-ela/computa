# Download and install Computa

Computa's macOS alpha packages support **Apple Silicon (M1 or later), macOS 14
or later**. Intel Macs are not supported by the bundled runtime. Download from
the public [GitHub Releases page](https://github.com/ahmed-ela/computa/releases).
Alpha releases are marked prerelease and are intentionally excluded from
GitHub's `latest` endpoint.

## Install the app

1. Download the DMG, matching `.manifest.json`, and `SHA256SUMS` from the same
   release. Optionally verify the download with `shasum -a 256 --check SHA256SUMS`
   in their download directory.
2. Quit any running Computa or legacy Mactopus copy. Open the DMG and drag
   **Computa.app** to **Applications**. Open the installed app.
3. Open Computa's built-in browser and sign in to the website provider you want
   to use. Each recipient uses their own account; no account sessions or API
   credentials are included in the package.
4. After completing sign-in, quit and reopen Computa once so its existing model
   discovery can populate the selector. Choose a specific model. Fresh profiles
   start with ChatGPT Instant selected, but it remains unavailable until the
   website's choices have been verified. Saved model preferences are preserved.
5. Alternatively configure an API provider in Settings. Approve macOS permissions
   when a requested feature needs them. Installation does not grant permissions.

Browser and API models require **no Xcode, Homebrew, Git, Bun, Python, MLX or
local model download**. The app includes its native task runtime. Website sign-in,
account plans, quotas and provider model availability still apply. Native app
control and optional visual grounding have their own permission/dependency
requirements; ordinary built-in-browser control does not need local model weights.

Read each release's notes for its exact validation and known limitations. An
alpha is an early testing release, not a claim that every provider/model or
website workflow is reliable. The current Claude qualification notes distinguish
Sonnet 5.5's successful bounded workflow from other models' failures and quota
blocks: [Claude qualification](CLAUDE-HARNESS-QUALIFICATION.md).

## Signing and notarization

Normal distribution uses a Developer ID signed, notarized app. The release notes
must identify whether both the app and DMG were notarized/stapled and assessed.
A valid signature alone does not establish Apple notarization or clean-Mac
installation success.

Assets explicitly named `signed-test` are **not notarized** and may be blocked
by macOS. They are controlled-test packages, not the normal public-installation
path. Neither the app installer nor this guide removes quarantine or disables
security checks. Use a notarized package for normal distribution.

## Updates and existing data

Replacing the app bundle preserves user data stored outside the bundle.
Conversations and runtime data live under `~/Library/Application Support/LocalCodex`;
preferences and website data also use macOS-managed storage. Quit the running
app before replacing it. The bundle identifier remains
`com.ahmedelamin.LocalCodex`.

If both `/Applications/Computa.app` and `~/Applications/Computa.app` exist, open
the intended copy explicitly. Dragging to Applications does not migrate or
remove an older `~/Applications/Mactopus.app`. Preserve any older copy until the
new installation has been checked.

A website quota is an account limit, not an installation failure. Wait for the
provider's actual reset, restart Computa to clear its process-local admission
block, and start a fresh task. Restarting does not reset provider quotas. A failed
or uncertain external action must not be replayed merely because the app restarted.

## Optional legacy local-model setup

Local models are currently hidden from the selector. Existing saved local-model
workflows remain supported. Only those workflows need the DMG's optional
**Install Computa.command**, which provisions private Python/MLX and the pinned
Qwen 3.5 4B model (about 3.06 GB); allow about 10 GB for dependencies, cache and
staging. Weights are not included in the DMG.

The command installer asks for `INSTALL` before downloading or installing. It
uses pinned official downloads and verifies hashes, installs into
`~/Applications/Computa.app`, and preserves the previous app under
`~/Applications/Computa Backups/release-*/`. It supports a lone compatible
`Mactopus.app`; if both names exist, it stops without replacing either. Existing
model/download caches and user data are preserved. `--download-model` explicitly
authorizes the same provisioning noninteractively; `--no-launch` leaves the app
closed afterward. It is not required for browser/API use.

This optional installer has fixture coverage for validation, migration, backups,
rollback and retry behavior. Those tests do not establish physical clean-Mac
qualification for a particular release. Optional visual-grounding model weights
are separate from this legacy language-model installer.

## Release preparation

Maintainers use the source-controlled [alpha release procedure](RELEASING.md)
and [version policy](VERSIONING.md). Build from the reviewed squash-merged source,
sign nested code before the app, notarize and staple, then package the immutable
app with its manifest and checksums. The publisher verifies GitHub digests,
mounted app files, tagged installer sources and signing/notarization requirements
before making the draft public. Release notes identify the source, package checks,
actual live tests and remaining limitations separately.

Historical preview artifacts remain immutable. The old `v0.1.0-preview.1` draft
was a non-notarized migration checkpoint, not this public alpha installation path.
