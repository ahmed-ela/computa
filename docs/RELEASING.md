# Alpha releases

Computa uses the alpha channel for new testing releases. The automatic publisher
accepts only `vMAJOR.MINOR.PATCH-alpha.N`, publishes a GitHub prerelease, and
leaves it out of the latest stable release. It does not publish stable tags.
The Apple app keeps the numeric `MAJOR.MINOR.PATCH` version and a separate
increasing build number. Use that build number as `N`.

The current production build path is the Swift app through
[`Scripts/setup.sh`](../Scripts/setup.sh). The Rust migration introduced in
PR #3 remains incomplete with separate qualification gates; source integration
does not qualify or promote the Rust app. A Developer ID signature, a verified package, and a
successful publication are also separate from notarization and clean-Mac
installation. Record the actual checks and known limitations in the release
notes. See [distribution](DISTRIBUTION.md), [versioning](VERSIONING.md), and
[migration gates](RUST-MIGRATION.md).

## Release on merge

Squash-merge a reviewed PR into `computa`, the default branch. Each new
first-parent commit queues a macOS alpha. The signing Mac checks GitHub every
60 seconds while the release user is logged in. After sleep or downtime it
resumes from its last completed commit. Feature branches and open PRs do not
enter the queue. Review the [app version decision](VERSIONING.md#version-decision-for-each-pr)
when preparing the PR for merge.
`bun Scripts/version.ts alpha-tag` prints the tag for a checkout.

The service builds the exact merged commit in a dedicated clone, runs release
and WebUI tests, signs the app, and submits both the app and DMG to Apple.
It staples both tickets, signs the final DMG for Sparkle, and uploads a draft.
The publisher independently verifies the tagged build number, mounted image,
asset digests and update signature before publication. The public
[download](https://computa.wtf/download) and [update feed](https://computa.wtf/appcast.xml)
follow the release. Existing updater-enabled clients discover it on their
next check. The service does not restart an installed app.

### Signing Mac setup

On an Apple Silicon Mac with the [build prerequisites](BUILDING.md#requirements),
sign in to GitHub CLI with release, tag, and commit-status permissions. Configure
a Developer ID Application identity, a `notarytool` profile in the login Keychain,
and the existing Computa Sparkle key. The macOS login session must be able to
use all three unattended. Run once, substituting the local paths and identity:

```sh
/usr/bin/python3 Scripts/merge-release-worker.py install /absolute/path/to/release-state \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile your-notary-profile
```

An optional `--sparkle-signer /path/to/sign_update` uses an already-authorized
signer when its SHA-256 matches the pinned distribution. The installer captures
the current PATH and Rust toolchain locations. Keep the state directory on a
persistent volume with space for Xcode and a clean runtime build. An unchanged
runtime can be reused after checking its files against a published notarized
release manifest. Re-run the installer after updating the scheduler or moving
the tools. Use one signing service for this repository.

Each commit has a **Computa / macOS release** status on GitHub. Detailed output
is in `STATE/<commit>.log`, and scheduler errors are in
`~/Library/Application Support/ComputaRelease/worker.log`. A failing tip is
retried after ten minutes. When a newer merge arrives, a persistently broken
older build is marked failed and the newer one can ship. Successful releases
are immutable. A retry resumes the same draft from its staged bytes. The previous
public update stays available during a build or failure.

## Prepare in-app updates

Build 586 and later use the pinned Sparkle framework in the Xcode app. The release publisher verifies the update archive with the public key embedded in that app. The private Ed25519 signing key stays in the release maintainer’s Keychain under the Sparkle account `com.ahmedelamin.LocalCodex.Sparkle`. Keep a secure backup of that key. Use the `sign_update` binary from the pinned Sparkle distribution or Xcode’s resolved `SourcePackages/artifacts/sparkle/Sparkle/bin` directory.

After notarizing and stapling the **app**, package it with `--channel notarized`. Sign the resulting DMG with Developer ID, submit it to Apple notarization, and staple its ticket. Generate the feed and final checksums from those exact bytes:

```sh
bun Scripts/sparkle-appcast.ts "$sparkle_tools/sign_update" "/path/to/Computa-VERSION-alpha.BUILD-arm64.dmg"
```

Upload `appcast.xml` alongside the final DMG, manifest, and `SHA256SUMS` when creating the draft. Use the notarized asset names (without `-signed-test`). The publisher verifies the feed's download URL, version, length, checksum, and Ed25519 signature before it makes the draft public. `https://computa.wtf/appcast.xml` then points clients at the highest published build with both a notarized DMG and a feed. Publishing future app updates requires no website deploy. A `signed-test` package cannot be offered to an installed client.

## Manual recovery

The **Publish Computa alpha** GitHub Actions workflow can verify and publish an
already prepared draft. Use this if the signed assets are uploaded and only the
final publication step needs intervention. Check the signing service status
and stop it before taking over a draft. From the repository, run:

```sh
gh workflow run release-alpha.yml --ref computa --field tag="$computa_release_tag"
```

The workflow checks out the default branch and verifies the exact tag, draft,
installer files and mounted DMG before publishing a prerelease. A changed
artifact requires a new merge and build. Stable releases and the Rust app
migration have separate qualification gates.
