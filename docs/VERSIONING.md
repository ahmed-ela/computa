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
numeric components without leading zeros. `CURRENT_PROJECT_VERSION` supplies
`CFBundleVersion`: a separate positive build number, increasing across releases
and rebuilds. It never resets on a major, minor, or patch bump. The current
integer convention supports builds 1–9999 and refuses overflow.

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
bun Scripts/version.ts bump build
```

Choose **one** bump for the intended release. For example, from `0.1.1` build
`2`, patch produces `0.1.2` build `3`, minor produces `0.2.0` build `3`, major
produces `1.0.0` build `3`, and build produces `0.1.1` build `3`.

The bump command checks consistency first, then updates the xcconfig, Cargo
workspace version, and only the workspace packages in `Cargo.lock`. Dependency
versions, runtime/source pins, lock hashes, protocol/schema versions, website
and WebUI package versions, and the separately shipped Chrome extension version
remain independent. The command does not create a commit, tag or release, sign,
install, publish, or download anything. Review and commit its diff with the
release changes. Run `check` and the normal build/tests before packaging.

The Swift source setup prerequisite check validates the shared source and Cargo
lock versions. Xcode project regeneration preserves the xcconfig references;
no regeneration is required just to bump a version. Command-line Xcode setting
overrides are intended for local experiments, not release versioning.

## Release packages

New packages accept `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-alpha.N`.
Alpha is the only prerelease channel; beta, release-candidate and preview labels
are not used for new packages. The automatic publisher currently accepts only
alpha tags, leaving stable publication for a separately qualified release.
Use the increasing Apple build number as `N`: app `0.1.2` build `3` produces
`v0.1.2-alpha.3`. A build-only bump produces `v0.1.2-alpha.4`; a patch bump
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

Release useful, validated checkpoints as they become ready, including multiple
alphas in a day when warranted. There is no fixed timer or daily quota.
Version changes go through a feature branch, pull request and squash merge.
After local build/sign/package preparation and draft upload, the GitHub Actions
publisher automatically verifies the assets and publishes an alpha on explicit
dispatch. See [the release procedure](RELEASING.md).

Qualification of the draft Rust migration remains separate from app versioning;
a matching version does not approve installation or satisfy its release gates.
