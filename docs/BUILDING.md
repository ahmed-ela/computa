# Building Mactopus from source

## Packaging status

The source-install entry point builds the pinned Rust engine, native app and
WebUI, then prepares app-owned headless MLX serving. Orchestration and rollback
have deterministic tests. **A full clean-machine installation and live Chrome
pairing of another developer's signed build have not yet been verified.**
This is a source-build workflow, not a notarized prebuilt distribution.
See [the measured packaging validation](SOURCE-INSTALL-VALIDATION.md) for checks
that passed and the remaining clean-machine qualification limits.

The repository remains private. “From GitHub” means a clone by someone who has
been granted repository access; it does not imply anonymous public access.

## Requirements

- Apple Silicon Mac (arm64), macOS 14 or later. Intel and Linux builds are not
  supported by the pinned agent-runtime packaging route.
- Full Xcode with Swift 6.2 or later, selected with Xcode's command-line tools
  setting. Command Line Tools alone are insufficient. Open Xcode and complete
  its first-launch setup before building.
- Git, XcodeGen, Bun 1.3.5 or later, Rustup with Rust **1.95.0**, and `uv`.
  Install these explicitly through their official installation instructions or
  your preferred package manager. Setup does not run Homebrew, `sudo`, install
  global packages, accept an Xcode license, or change the selected Xcode.
- Internet access for pinned upstream Rust source, Cargo crates, frozen Bun
  dependencies, and the private Python environment. Allow roughly 35–50 GB
  free space for an initial Rust/Xcode build and its caches. This is a planning
  estimate, not a measured clean-machine peak.
- Optional Qwen 3.5 4B MLX 4-bit weights: approximately **3.06 GB** of model
  files, separate from the app and build caches. Runtime RAM requirements are
  larger than the weight size; 16 GB or more unified memory is recommended.
- For the optional Chrome extension bridge: your own installed **Apple
  Development or Developer ID Application** code-signing identity. Local chat
  and native Accessibility do not require an Apple signing account.

Rust's broader workspace test suite can need additional SDKs. The packaged
`codex-app-server` normal/build dependency graph does **not** require GStreamer;
do not install the full multimedia stack merely to build this application.
The normal pinned arm64 build compiles AWS-LC, SQLite, zstd, bzip2 and lzma from
bundled sources with Xcode's C toolchain; protoc is vendored. External CMake,
pkg-config and system copies of those libraries are not baseline requirements.
Custom Cargo features or environment overrides can change those requirements.

No LM Studio, Node.js, npm, installed Codex application, author signing
certificate, or author account is required for the default local build. Bun builds the
Octane frontend; macOS WebKit renders it. The owned Rust App Server is built
from the exact upstream commit and checksum-locked local patch described in
[`Runtime/README.md`](../Runtime/README.md). Its source is not a prebuilt binary
copied from another app.

## Checkout and setup

```sh
git clone https://github.com/ahmed-wlb/mactopus.git
cd mactopus
./Scripts/setup.sh --check
./Scripts/setup.sh --download-model
```

This default ad-hoc-signed build supports local chat and native app
Accessibility, subject to normal macOS permissions. **Chrome extension pairing
is unavailable for ad-hoc builds**: the bridge requires an Apple-backed signing
identity so an unrelated local process cannot impersonate the app.

If you already have your own Apple code-signing identity installed, build with:

```sh
./Scripts/setup.sh --download-model --signing-identity 'Apple Development: Your Name (YOURTEAMID)'
```

Replace that entire example certificate name with your exact installed
identity, or use its 40-character SHA-1 fingerprint. Setup validates it before
building, signs the helper and outer app with it, and verifies the Apple trust
chain before installation. It does not create an Apple account, enroll in a
paid program, import credentials, or approve Keychain prompts. A self-signed
certificate with an Apple-like name is not accepted as that trust anchor.

Use GitHub CLI authentication or a Git credential helper for private access;
never paste a token into this script or into a clone URL. Review the checked-out
source before running it. This workflow deliberately does not use `curl | sh`.

`--download-model` is explicit consent to download the pinned Qwen 3.5 4B
weights. Without it, setup prepares the Python environment but downloads no
model weights: an already compatible local model is required for chat.
Optional visual-grounding models are separate and are not downloaded by the
basic source setup.

Python **3.12.13** and the hash-locked MLX serving packages are installed into
`~/Library/Application Support/LocalCodex/MLX/venv`. The serving dependency set
still includes MLX-VLM's upstream vision/audio dependencies (roughly 567 MiB of
installed packages, plus Python and caches); "headless" does not mean no Python packages. Model weights
go into `LocalCodex/MLX/models`. The default model is pinned to
`lmstudio-community/Qwen3.5-4B-MLX-4bit` revision
`c43ee1d65576a5d98de1e8405cac93c371a655c1`; files are verified against the
committed model manifest. Existing supported models under `~/.lmstudio/models`
remain readable without copying or starting LM Studio. The legacy grounding
venv remains a compatibility fallback when no new owned MLX venv is installed.

Other modes:

```sh
./Scripts/setup.sh --check                 # Read-only; no build/install/download
./Scripts/setup.sh --build-only            # Only build a signed app in .build
./Scripts/setup.sh --no-launch             # Install without opening Mactopus
./Scripts/setup.sh --download-model --no-launch
bun test Scripts/setup.test.ts             # Mocked commands and temporary homes
```

The build-only artifact is:

```text
.build/SourceInstall/Build/Products/Release/Mactopus.app
```

The source build sequence is pinned Rust App Server, `bun install
--frozen-lockfile`, WebUI production compilation, `xcodegen generate`, and a
Release arm64 Xcode build. Setup overrides the author's development-team
setting and applies an **ad-hoc signature** to the helper and app by default,
or the explicitly selected Apple identity with `--signing-identity`. The runtime
builder signs and hashes its own executable; setup does not re-sign it and
invalidate that integrity manifest. Ad-hoc signing is local-build integrity,
not a Developer ID distribution signature or notarization.

## Installation, data, and permissions

Setup installs only to `~/Applications/Mactopus.app`, not `/Applications`.
Quit Mactopus normally first; setup refuses to kill it or replace it while it
is running. It checks the existing bundle identity, executable, and signature,
and refuses an unknown app or a symlinked installation directory.

The new bundle is staged and verified before replacement. A compatible old
bundle is moved into a uniquely named directory under `~/Applications/Mactopus
Backups/`. A failed final move attempts to restore the old bundle and reports
the preserved paths if recovery needs assistance. Backups are not automatically
deleted. Existing `~/Library/Application Support/LocalCodex` chats, preferences,
browser tabs, and installed system-level applications are not removed or reset.

An existing `/Applications/Mactopus.app` is intentionally left untouched. When
both locations exist, use the exact newly installed path instead of assuming
Spotlight picked the desired copy. The setup command opens that exact path.

The stable legacy bundle ID is `com.ahmedelamin.LocalCodex`; the product name is
Mactopus. A locally rebuilt ad-hoc signature may require macOS permissions to
be granted again. Setup does not edit TCC, bypass Gatekeeper, enable Remote
Debugging, install a browser extension silently, or grant Full Access. Review
Accessibility and Screen Recording prompts yourself. Optional Chrome access
requires installing and explicitly pairing the extension in the intended
profile as described in [`BrowserExtension/README.md`](../BrowserExtension/README.md).
The app and helper must be signed by the same verified Apple team for this
optional bridge. Pairing and macOS permissions remain native user decisions;
signing does not grant access automatically.

## Test fixture portability

TypeScript App Server fixtures use Bun. In Debug tests the runtime resolves an
explicit interpreter at the current user's `~/.bun/bin/bun` or standard
Homebrew locations, rather than adding arbitrary directories to the isolated
engine's PATH. For a custom trusted installation:

```sh
MACTOPUS_TEST_BUN=/absolute/path/to/bun swift test
```

The override exists only for Debug fixtures. Release builds cannot launch those
fixtures, and production's system-only PATH and owned engine isolation stay
unchanged. The fixture resolver checks for an executable regular file that is
not group/world writable; it does not claim to authenticate the Bun publisher.

An optional signing-boundary test uses your existing Apple identity to compile
and sign small temporary fixtures; it does not connect to Chrome:

```sh
MACTOPUS_RUN_SIGNING_TESTS=1 MACTOPUS_TEST_SIGNING_IDENTITY='Your existing Apple signing identity' bun test Scripts/chrome-bridge-signing.test.ts
```

Without that explicit flag the signing tests are skipped. Provisioning and
synthetic downloader tests are not evidence of a fresh multi-gigabyte model
download; that end-to-end download has not been repeated during packaging.

## Limits of this release

A successful build is not proof that every computer-use task succeeds. The
native Messages window-binding issue and live end-to-end task reliability have
separate validation gates. Background-only operations stay background-only;
unsupported or unverified actions must fail without stealing focus or guessing
an answer. Source installation does not relax those boundaries.
