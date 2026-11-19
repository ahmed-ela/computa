# App versioning

Computa uses `major.minor.patch`, following [Semantic Versioning](https://semver.org/):

- **Major:** incompatible changes to supported interfaces or persisted-data compatibility.
- **Minor:** new compatible features; reset patch to zero.
- **Patch:** compatible fixes; keep major and minor unchanged.

The `0.x.y` series is initial development and does not promise a stable public
API. `1.0.0` will mark the first stable contract. Published release artifacts
are immutable; distribute changed app bytes under a new version or alpha tag.

## Shared source

[`Config/Version.xcconfig`](../Config/Version.xcconfig) is the authoritative
app version and build number. Xcode's Debug and Release configurations read it
directly. The Rust bundler reads it and refuses a mismatch with its compiled
Cargo version or source workspace version. The native runtime handshake reads
the version from its own built bundle.

`MARKETING_VERSION` supplies Apple's `CFBundleShortVersionString`: exactly three
numeric components without leading zeros. For public alphas, the build number is
the baseline `CURRENT_PROJECT_VERSION` plus the number of commits reachable
from the release commit beyond `COMPUTA_ALPHA_BUILD_ANCHOR`. A squash merge
adds one. A merge commit can introduce several commits and skip numbers.
The same commit always yields the same build. Xcode receives that value as
`CURRENT_PROJECT_VERSION` when building the release. It increases across
marketing-version bumps. Builds are integers from 1 through 9999.

This repository currently contains **only a macOS app**. An iOS target added
here should reference this same xcconfig in both configurations and use the
same plist substitutions; no iOS app has been built or validated by this change.
Apple documents the two fields separately:
[app version](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
and [build number](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion).

## Commands

Run from the repository root:

```sh
bun Scripts/version.ts check
bun Scripts/version.ts bump patch
bun Scripts/version.ts bump minor
bun Scripts/version.ts bump major
bun Scripts/version.ts alpha-tag
```

Ordinary PRs can keep the current marketing version. For a marketing-version
change, choose one of patch, minor, or major. Each merged commit already gets
its own public build number.

The bump command checks consistency first, then updates the xcconfig, Cargo
workspace version, and only the workspace packages in `Cargo.lock`. Dependency
versions, runtime/source pins, lock hashes, protocol/schema versions, website
and WebUI package versions remain independent. The command does not create a commit, tag or release, sign,
install, publish, or download anything. Review and commit its diff with the
release changes. Run `check` and the normal build/tests before packaging.

The Swift source setup prerequisite check validates the shared source and Cargo
lock versions. Xcode project regeneration preserves the xcconfig references;
no regeneration is required just to bump a version. The merge publisher independently checks the computed build against GitHub history.

## Release packages

New packages accept `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-alpha.N`.
Alpha is the only prerelease channel; beta, release-candidate and preview labels
are not used for new packages. The automatic publisher currently accepts only
alpha tags, leaving stable publication for a separately qualified release.
Use the increasing Apple build number as `N`: app `0.1.2` build `3` produces
`v0.1.2-alpha.3`. The next squash merge produces `v0.1.2-alpha.4`; a squash merge with a patch bump instead
produces `v0.1.3-alpha.4`. The suffix belongs to the release tag and manifest,
while the Apple app version remains numeric.
Both packagers validate this tag policy and require the tag's numeric base to
match the signed app's marketing version. They read the actual signed plist
and record both `appVersion` and `appBuild`; they never rewrite the app's version
or invalidate its signature to make a tag match.

New installers validate version/build metadata against the sealed plist before
staging or provisioning. They can read older manifests that omit `appBuild`;
those packages still have their exact plist bytes covered by the app file
inventory. Rust packages carry their matching installer; older Rust installers
with strict manifest fields are not forward compatible with new fields.
Historical preview packages and their manifests are not rewritten.

A merge to `computa` queues an alpha on the signing Mac. See
[releasing](RELEASING.md) for the release checks, signing setup, and recovery.

Qualification of the draft Rust migration remains separate from app versioning;
a matching version does not approve installation or satisfy its release gates.
