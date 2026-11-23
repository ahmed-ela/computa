#!/usr/bin/env python3
"""Build an immutable merged commit, then hand its sealed draft to the standard alpha publisher."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

REPO = "ahmed-ela/kolmogor"
RUNTIME = Path("Sources/Computa/Resources/AgentRuntime")
RUNTIME_FILES = ("codex-app-server", "manifest.json", "LICENSE", "NOTICE")
RUNTIME_INPUTS = ["Runtime/codex-source.lock.json", "Runtime/patches", "Scripts/build-agent-runtime.ts",
                  "Scripts/runtime-source.ts", "rust-toolchain.toml"]


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def read(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def seed_runtime():
    # An existing public package can supply exactly the same runtime inputs.
    # Authenticate the four bytesets against its published inventory before reuse.
    return any(seed_installed_runtime(Path("/Applications") / (name + ".app") / "Contents")
               for name in ("Kolmogor", "Computa"))


def seed_installed_runtime(installed):
    try:
        info = plistlib.loads((installed / "Info.plist").read_bytes())
        if info["CFBundleIdentifier"] != "com.ahmedelamin.LocalCodex":
            return False
        tag = f"v{info['CFBundleShortVersionString']}-alpha.{info['CFBundleVersion']}"
        if subprocess.run(["git", "merge-base", "--is-ancestor", tag, "HEAD"]).returncode != 0:
            return False
        if subprocess.run(["git", "diff", "--quiet", tag, "HEAD", "--", *RUNTIME_INPUTS]).returncode != 0:
            return False
        release = json.loads(read("gh", "release", "view", tag, "--repo", REPO, "--json", "isDraft,assets"))
        product = info["CFBundleExecutable"]
        if product not in ("Kolmogor", "Computa"):
            return False
        name = f"{product}-{tag[1:]}-arm64.manifest.json"
        if release["isDraft"]:
            return False
        asset = next(a for a in release["assets"] if a["name"] == name)
        raw = subprocess.check_output(["gh", "release", "download", tag, "--repo", REPO, "-p", name, "-O", "-"])
        if "sha256:" + hashlib.sha256(raw).hexdigest() != asset["digest"]:
            return False
        manifest = json.loads(raw)
        if manifest["tag"] != tag or manifest["channel"] != "notarized":
            return False
        inventory = {r["path"]: r.get("sha256") for r in manifest["appFiles"]}
        source = installed / "Resources/AgentRuntime"
        for f in RUNTIME_FILES:
            if (source / f).is_symlink() or digest(source / f) != inventory["Contents/Resources/AgentRuntime/" + f]:
                return False
        RUNTIME.mkdir(exist_ok=True, parents=True)
        for f in RUNTIME_FILES:
            shutil.copy2(source / f, RUNTIME / f)
        print(f"Reused the verified agent runtime from {tag}")
        return True
    except (OSError, KeyError, StopIteration, ValueError, subprocess.CalledProcessError):
        return False


def prepare_runtime(state):
    key = read("git", "log", "-1", "--format=%H", "HEAD", "--", *RUNTIME_INPUTS)
    receipt = state / "runtime.json"
    if receipt.exists():
        saved = json.loads(receipt.read_text())
        if saved["input"] == key and set(saved["files"]) == set(RUNTIME_FILES) and all((RUNTIME / name).is_file() and digest(RUNTIME / name) == sha
                for name, sha in saved["files"].items()):
            return
    if not seed_runtime():
        run("bun", "Scripts/build-agent-runtime.ts", "--release", "--isolated-source")
    files = {name: digest(RUNTIME / name) for name in RUNTIME_FILES}
    pending = state / "runtime.tmp"
    pending.write_text(json.dumps({"input": key, "files": files}))
    pending.replace(receipt)


def notarize(file):
    profile = os.environ["COMPUTA_NOTARY_PROFILE"]
    args = ["--keychain-profile", profile, "--keychain", str(Path.home() / "Library/Keychains/login.keychain-db")]
    submitted = json.loads(read("xcrun", "notarytool", "submit", file, *args, "--output-format", "json"))
    job = submitted["id"]
    print(f"Apple submission {job} for {file.name}")
    result = json.loads(read("xcrun", "notarytool", "wait", job, *args, "--output-format", "json"))
    if result["status"] != "Accepted":
        run("xcrun", "notarytool", "log", job, *args)
        raise RuntimeError(f"Apple notarization returned {result['status']}")


def package(state, tag, job):
    stage = job / "staging"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    prepare_runtime(state)
    run("cargo", "test", "--locked", "--target-dir", state / "contracts-target",
        "-p", "computa-contracts", "--bin", "browser-tool-catalog")
    run(sys.executable, "Scripts/merge-release-worker.test.py")
    run(sys.executable, "Scripts/sign_browser_passkeys_test.py")
    run("bun", "test", "Scripts/version.test.ts", "Scripts/release-policy.test.ts", "Scripts/sign-release.test.ts",
        "Scripts/package-release.test.ts", "Scripts/sparkle-appcast.test.ts", "Scripts/publish-alpha.test.ts",
        "Website/download-worker.test.ts")
    run("bun", "install", "--frozen-lockfile", cwd="WebUI")
    run("bun", "run", "test", cwd="WebUI")
    run("bun", "run", "build", cwd="WebUI")
    run("xcodegen", "generate")
    derived = state / "DerivedData"
    product = derived / "Build/Products/Release/Kolmogor.app"
    if product.exists():
        shutil.rmtree(product)
    run("xcodebuild", "-project", "Kolmogor.xcodeproj", "-scheme", "Kolmogor", "-configuration", "Release",
        "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", derived, "-onlyUsePackageVersionsFromResolvedFile",
        "-jobs", "3", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-",
        "DEVELOPMENT_TEAM=", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=", "CURRENT_PROJECT_VERSION=" + tag.split(".")[-1], "build")
    app = stage / "signed/Kolmogor.app"
    identity = os.environ["COMPUTA_SIGN_IDENTITY"]
    profile = os.environ.get("COMPUTA_BROWSER_PASSKEY_PROFILE")
    run("bun", "Scripts/sign-release.ts", "--app", product, "--output", app, "--identity", identity,
        *(["--browser-passkey-profile", profile] if profile else []))
    archive = stage / "submission.zip"
    run("ditto", "-c", "-k", "--keepParent", app, archive)
    notarize(archive)
    archive.unlink()
    run("xcrun", "stapler", "staple", app)
    out = stage / "package"
    run("bun", "Scripts/package-release.ts", "--app", app, "--output", out, "--tag", tag, "--channel", "notarized")
    image = out / f"Kolmogor-{tag[1:]}-arm64.dmg"
    run("codesign", "--force", "--timestamp", "--sign", identity, image)
    notarize(image)
    run("xcrun", "stapler", "staple", image)
    pinned = derived / "SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    signer = Path(os.environ.get("COMPUTA_SPARKLE_SIGNER", pinned))
    if not signer.is_file() or digest(signer) != digest(pinned):
        signer = pinned
    run("bun", "Scripts/sparkle-appcast.ts", signer, image, REPO)
    run("shasum", "-a", "256", "-c", "SHA256SUMS", cwd=out)
    for temporary in out.glob(".computa-release-*"):
        shutil.rmtree(temporary)
    out.rename(job / "ready")
    shutil.rmtree(stage)


def release_info(tag):
    pages = json.loads(read("gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    matches = [r for page in pages for r in page if r["tag_name"] == tag]
    if len(matches) > 1:
        raise RuntimeError("Ambiguous release tag")
    return matches[0] if matches else None


def main(state, tag):
    commit = read("git", "rev-parse", "HEAD")
    if tag != read("bun", "Scripts/version.ts", "alpha-tag"):
        raise RuntimeError("Release tag differs from this checkout")
    remote = read("git", "ls-remote", "--refs", "origin", f"refs/tags/{tag}")
    if remote and remote.split()[0] != commit:
        raise RuntimeError("Existing tag belongs to another commit")
    release = release_info(tag)
    names = {f"Kolmogor-{tag[1:]}-arm64.dmg", f"Kolmogor-{tag[1:]}-arm64.manifest.json", "appcast.xml", "SHA256SUMS"}
    if release and not release["draft"]:
        if not remote or not release["prerelease"] or {a["name"] for a in release["assets"] if a["state"] == "uploaded"} != names:
            raise RuntimeError("Published release has unexpected assets or identity")
        return
    job = state / "jobs" / commit
    job.mkdir(parents=True, exist_ok=True)
    ready = job / "ready"
    if not ready.exists():
        package(state, tag, job)
    if not remote:
        run("gh", "api", "-X", "POST", f"repos/{REPO}/git/refs", "-f", f"ref=refs/tags/{tag}", "-f", f"sha={commit}")
    if not release:
        notes = job / "notes.md"
        notes.write_text(f"Apple Silicon macOS alpha from [commit {commit[:9]}](https://github.com/{REPO}/commit/{commit}).\n\n"
                         "Download the notarized DMG or choose **Kolmogor → Check for Updates…** in the app.\n")
        run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--draft", "--prerelease", "--latest=false",
            "--title", f"Kolmogor {tag[1:]}", "--notes-file", notes)
    uploaded = {a["name"]: a for a in (release or {}).get("assets", [])}
    if set(uploaded) - names:
        raise RuntimeError("Draft contains unexpected assets")
    for name in sorted(names):
        file = ready / name
        if name in uploaded and uploaded[name]["state"] == "starter" and uploaded[name]["size"] == 0:
            # GitHub can leave an empty placeholder after an interrupted upload to a draft.
            run("gh", "api", "-X", "DELETE", f"repos/{REPO}/releases/assets/{uploaded[name]['id']}")
            del uploaded[name]
        if name in uploaded:
            if uploaded[name].get("digest") != "sha256:" + digest(file):
                raise RuntimeError(f"Draft asset differs from the staged release: {name}")
        else:
            run("gh", "release", "upload", tag, file, "--repo", REPO)
    run("bun", "Scripts/publish-alpha.ts", "--tag", tag, "--repo", REPO, "--publish")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(strict=True), sys.argv[2])
