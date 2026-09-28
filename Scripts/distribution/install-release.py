#!/usr/bin/env python3
"""Install an already signed release. Invoked by the verified bootstrap, never a model."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import stat
import subprocess
import tempfile

BUNDLE_ID = "com.ahmedelamin.LocalCodex"


def checked(command, *, env=None):
    result = subprocess.run([str(value) for value in command], check=True, env=env,
                            text=True, stdout=subprocess.PIPE)
    return result.stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def safe_directory(path, *, create=False):
    path = Path(path).absolute()
    if path == Path("/"):
        raise ValueError("Refusing an unsafe directory")
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise ValueError(f"Refusing a symlinked installation directory: {part}")
        if part.exists() and not part.is_dir():
            raise ValueError(f"Expected a directory: {part}")
    if create:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def bundle_files(app):
    app = safe_directory(app)
    result = []
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if any(ord(character) < 32 or ord(character) == 127 for character in relative):
            raise ValueError("Control characters in bundle paths are unsupported")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            if not path.resolve(strict=True).is_relative_to(app.resolve()):
                raise ValueError("The app contains a symlink outside its bundle")
            result.append({"path": relative, "kind": "symlink", "target": target})
        elif stat.S_ISREG(info.st_mode):
            result.append({"path": relative, "kind": "file", "sha256": digest(path),
                           "size": info.st_size, "executable": bool(info.st_mode & 0o111)})
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError("The app contains a special filesystem entry")
    # pathlib orders paths by components; the packager orders complete UTF-8
    # paths, where "Resources.plist" precedes "Resources/file".
    return sorted(result, key=lambda entry: entry["path"].encode("utf-8"))


def inspect_app(app, run=checked, expected_files=None):
    app = safe_directory(app)
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "Mactopus":
        raise ValueError("Refusing to replace or install an unknown application")
    if expected_files is not None and bundle_files(app) != expected_files:
        raise ValueError("The application differs from its release manifest")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    return info


def require_stopped(run=checked):
    try:
        run(["/usr/bin/pgrep", "-x", "Mactopus"])
    except subprocess.CalledProcessError as error:
        if error.returncode == 1:
            return
        raise ValueError("Could not determine whether Mactopus is running") from error
    raise ValueError("Quit Mactopus normally before installing; no process was stopped")


def runtime_environment(home, uv):
    runtime = Path(home) / "Library/Application Support/LocalCodex/MLX"
    return {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "LOCALCODEX_UV": str(uv), "LOCALCODEX_MLX_HOME": str(runtime),
            "UV_NO_CONFIG": "1", "UV_PYTHON_INSTALL_BIN": "0",
            "UV_PYTHON_INSTALL_DIR": str(runtime / "python"), "UV_CACHE_DIR": str(runtime / "uv-cache"),
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "HF_HUB_DISABLE_TELEMETRY": "1"}


def model_helper(package_root):
    spec = importlib.util.spec_from_file_location("pinned_mlx_installer", Path(package_root) / "Installer/mlx-runtime-install.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_model(package_root, home):
    """Retain the HF cache for retry; publish only the existing hash-verified model."""
    from huggingface_hub import hf_hub_download
    helper = model_helper(package_root)
    manifest = helper.load_manifest(Path(package_root) / "Installer/mlx-model.lock.json")
    runtime = safe_directory(Path(home) / "Library/Application Support/LocalCodex/MLX")
    cache = safe_directory(runtime / "model-download-cache", create=True)

    def download(**arguments):
        for filename in arguments["allow_patterns"]:
            # The immutable revision and the original verifier remain decisive.
            # Interrupted downloads and completed files are reusable on a retry.
            source = hf_hub_download(repo_id=arguments["repo_id"], revision=arguments["revision"],
                                     filename=filename, cache_dir=str(cache), token=False)
            shutil.copyfile(source, Path(arguments["local_dir"]) / filename)

    destination = helper.install_model(runtime / "models", manifest, downloader=download)
    print(f"Verified model ready: {destination}")


def prepare_runtime(package_root, runtime, stage, uv, env, run):
    venv = runtime / "venv"
    if venv.exists() or venv.is_symlink():
        # An upgrade must not synchronize packages in the old app's working
        # environment before we know the new app/model can be installed.
        safe_directory(venv)
        python = venv / "bin/python"
        if not python.is_file() or not os.access(python, os.X_OK):
            raise ValueError("Existing MLX environment is incomplete; it was left untouched")
        try:
            run([python, "-I", "-B", package_root / "Installer/mlx-runtime-install.py", "verify-runtime",
                 "--lock", package_root / "Installer/mlx-runtime-requirements.lock",
                 "--receipt", stage / "verified-existing-runtime.json"], env=env)
            run([uv, "pip", "check", "--python", python], env=env)
        except Exception as error:
            raise RuntimeError("Existing MLX environment is incompatible with this release; "
                               "its packages and installation receipt were left untouched") from error
    else:
        run(["/bin/zsh", "-f", package_root / "Installer/install-mlx-runtime.sh"], env=env)


def install(package_root, home, uv, *, download_model=False, launch=True, run=checked,
            move=os.rename, system=None, architecture=None, mac_version=None):
    if not download_model:
        raise ValueError("--download-model is required to authorize runtime and model provisioning")
    if (system or platform.system()) != "Darwin" or (architecture or platform.machine()) != "arm64":
        raise ValueError("Apple Silicon macOS is required")
    package_root, home = Path(package_root).absolute(), Path(home).absolute()
    manifest = json.loads((package_root / "release-manifest.json").read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("bundleIdentifier") != BUNDLE_ID or manifest.get("architecture") != "arm64":
        raise ValueError("Unsupported release manifest")
    minimum = tuple(map(int, manifest["minimumMacOS"].split(".")))
    actual = tuple(map(int, (mac_version or platform.mac_ver()[0]).split(".")))
    if actual < minimum:
        raise ValueError(f"macOS {manifest['minimumMacOS']} or later is required")
    source = package_root / "Mactopus.app"
    inspect_app(source, run, manifest["appFiles"])
    run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple generic", source])
    require_stopped(run)
    applications = safe_directory(home / "Applications", create=True)
    destination = applications / "Mactopus.app"
    if destination.exists() or destination.is_symlink():
        inspect_app(destination, run)
    runtime = safe_directory(home / "Library/Application Support/LocalCodex/MLX", create=True)
    for name in ["models", "python", "uv-cache", "model-download-cache"]:
        safe_directory(runtime / name, create=True)
    # No recursive deletion or in-place app overwrite. Keep a failed staging
    # directory so a retry cannot destroy either the old or new bundle.
    stage = Path(tempfile.mkdtemp(prefix=".mactopus-install-", dir=applications))
    staged_app = stage / "Mactopus.app"
    run(["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", source, staged_app])
    inspect_app(staged_app, run, manifest["appFiles"])
    require_stopped(run)
    env = runtime_environment(home, uv)
    try:
        prepare_runtime(package_root, runtime, stage, uv, env, run)
        require_stopped(run)
        run([runtime / "venv/bin/python", "-I", package_root / "Installer/install-release.py",
             "--package-root", package_root, "--model-only"], env=env)
    except Exception as error:
        raise RuntimeError(f"Runtime/model setup failed ({error}); the installed app was not replaced. "
                           "Model downloads can be retried using the retained cache. "
                           "An incompatible existing Python environment needs separate repair. "
                           f"The staged app remains at {staged_app}.") from error
    require_stopped(run)
    inspect_app(staged_app, run, manifest["appFiles"])
    backup = None
    if destination.exists() or destination.is_symlink():
        inspect_app(destination, run)
        backup_root = safe_directory(applications / "Mactopus Backups", create=True)
        backup = Path(tempfile.mkdtemp(prefix="release-", dir=backup_root)) / "Mactopus.app"
        move(destination, backup)
    try:
        move(staged_app, destination)
    except Exception as error:
        if backup is not None and not destination.exists() and not destination.is_symlink():
            try:
                move(backup, destination)
            except Exception as restore_error:
                raise RuntimeError(f"Install and rollback failed. Previous app: {backup}; staged app: {staged_app}") from restore_error
        raise RuntimeError(f"Install failed; the previous app was preserved. Staged app: {staged_app}") from error
    inspect_app(destination, run, manifest["appFiles"])
    print(f"Installed {destination}")
    if backup:
        print(f"Previous app preserved at {backup}")
    if launch:
        run(["/usr/bin/open", destination])
    return destination, backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, required=True)
    parser.add_argument("--uv", type=Path)
    parser.add_argument("--download-model", action="store_true")
    parser.add_argument("--no-launch", action="store_true")
    parser.add_argument("--model-only", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.model_only:
        install_model(arguments.package_root, Path.home())
    elif arguments.uv is None:
        parser.error("--uv must identify the verified bootstrap executable")
    else:
        install(arguments.package_root, Path.home(), arguments.uv,
                download_model=arguments.download_model, launch=not arguments.no_launch)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(f"Mactopus installer: {error}") from error
