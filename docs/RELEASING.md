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

## Prepare the source

1. Choose one appropriate version bump using `bun Scripts/version.ts bump
   patch`, `minor`, `major`, or `build`. A build-only bump produces another
   alpha of the same marketing version; every bump increases the Apple build.
2. Include the version changes with the release changes in a pull request.
   Run the relevant checks, review the diff, and squash-merge it into the
   default branch, `computa`, only when its gates are satisfied.
3. Check out that merged default-branch commit in a clean checkout. Run
   `bun Scripts/version.ts check`. The alpha tag must identify this commit or
   another qualified ancestor of the current default branch.

The workflow and publisher must themselves be merged into the default branch
before dispatching. Do not merge a draft migration merely to enable releases.

## Build and package locally

Use an Apple Silicon Mac with the [build prerequisites](BUILDING.md#requirements)
and an installed Developer ID Application signing identity. Signing keys stay
in the local Keychain; the workflow does not need an exported certificate,
signing secret, or notarization credential.

From the qualified source checkout, derive the tag from the canonical metadata:

```sh
computa_release_tag=$(bun -e 'import { checkVersion } from "./Scripts/version.ts"; const app = await checkVersion(process.cwd()); console.log("v" + app.version + "-alpha." + app.build);')
computa_release_version="${computa_release_tag#v}"
computa_release_root="$PWD/.build/Alpha/$computa_release_tag"
computa_release_output="$computa_release_root/package"
computa_signing_identity='Developer ID Application: Your Name (TEAMID)'
```

Replace the example identity with your installed certificate. Use a fresh
output path; the signer and packager refuse to overwrite previous artifacts.
Create and push the exact tag, then build and sign a copy:

```sh
git tag "$computa_release_tag"
git push origin "$computa_release_tag"
./Scripts/setup.sh --build-only
bun Scripts/sign-release.ts \
  --app "$PWD/.build/SourceInstall/Build/Products/Release/Computa.app" \
  --output "$computa_release_root/signed/Computa.app" \
  --identity "$computa_signing_identity"
bun Scripts/package-release.ts \
  --app "$computa_release_root/signed/Computa.app" \
  --output "$computa_release_output" \
  --tag "$computa_release_tag" --channel signed-test
```

`--build-only` does not install or launch Computa or download model weights.
The build still obtains its pinned source and development dependencies.
`signed-test` means Developer ID signed but **not notarized**; macOS may block
the downloaded app on another Mac. For a notarized alpha, complete the separate
notarization and stapling steps first and package with `--channel notarized`.
Use that channel's filenames when uploading. The alpha label describes release
stability, not notarization status.

## Prepare in-app updates

Build 586 and later use the pinned Sparkle framework in the Xcode app. The release publisher verifies the update archive with the public key embedded in that app. The private Ed25519 signing key stays in the release maintainer’s Keychain under the Sparkle account `com.ahmedelamin.LocalCodex.Sparkle`. Keep a secure backup of that key. Use the `sign_update` binary from the pinned Sparkle distribution or Xcode’s resolved `SourcePackages/artifacts/sparkle/Sparkle/bin` directory.

After notarizing and stapling the **app**, package it with `--channel notarized`. Sign the resulting DMG with Developer ID, submit it to Apple notarization, and staple its ticket. Generate the feed and final checksums from those exact bytes:

```sh
bun Scripts/sparkle-appcast.ts "$sparkle_tools/sign_update" "$computa_release_output/Computa-${computa_release_version}-arm64.dmg"
```

Upload `appcast.xml` alongside the final DMG, manifest, and `SHA256SUMS` when creating the draft. Use the notarized asset names (without `-signed-test`). The publisher verifies the feed's download URL, version, length, checksum, and Ed25519 signature before it makes the draft public. `https://computa.wtf/appcast.xml` then points clients at the highest published build with both a notarized DMG and a feed. Publishing future app updates requires no website deploy. A `signed-test` package cannot be offered to an installed client.

## Upload a draft, then dispatch publication

Write release notes to a local file, identifying the source commit, app version
and build, signing/notarization status, validation performed, and remaining
limitations. For the `signed-test` package above:

```sh
computa_release_notes=/absolute/path/alpha-release-notes.md
computa_asset_stem="Computa-${computa_release_version}-arm64-signed-test"
gh release create "$computa_release_tag" \
  "$computa_release_output/$computa_asset_stem.dmg" \
  "$computa_release_output/$computa_asset_stem.manifest.json" \
  "$computa_release_output/SHA256SUMS" \
  --repo ahmed-ela/computa --verify-tag --draft --prerelease --latest=false \
  --title "Computa $computa_release_tag (alpha)" \
  --notes-file "$computa_release_notes"
gh workflow run release-alpha.yml --repo ahmed-ela/computa \
  --ref computa --field tag="$computa_release_tag"
```

The repository, [`ahmed-ela/computa`](https://github.com/ahmed-ela/computa), is
public. GitHub CLI must be signed in with permission to create releases and
dispatch workflows; an unpublished draft still requires maintainer access.
Published release assets are public downloads. Finish uploading all assets
before dispatching; a tag push alone does not publish a release. You can also
dispatch **Publish Computa alpha** in GitHub's Actions page and provide the
existing draft tag.

The workflow checks out the current default branch rather than executing code
from the supplied tag. On a macOS runner, the publisher downloads the draft's
assets into unique staging, checks the tag and default-branch ancestry,
manifest and checksums, verifies installer files against the tagged source and
their dependency pins, and verifies the app inside the mounted DMG. It rejects
non-alpha tags and already published releases. Only after those checks pass
does it publish the draft as a prerelease with latest disabled. Publication is
serialized per tag. No build, signing, installation, launch, or model download
runs in this workflow.

If verification fails, review the failure and keep the release unpublished.
Published artifacts are immutable: changed app bytes need a new build and
alpha tag, not replacement assets under an existing published tag.

## Cadence and limits

Release an alpha whenever a useful, reviewed checkpoint is ready. The flow has
no daily timer, release quota, or automatic merge. The version bump and local
artifact preparation are deliberate steps; verification and publication run
automatically after dispatch. A future merge-triggered build would require its
own signing, runner, version-bump, and qualification policy.

The publisher verifies release assets; it does not establish live model
correctness, browser sign-in compatibility, native permission behavior, or
clean-Mac acceptance. Matching app metadata and a valid signature do not prove
the compiled app came from the tag; maintainers must build from the qualified
clean source checkout and record that provenance. The publisher labels the
commit as the tagged source. Stable publication remains outside this workflow.
