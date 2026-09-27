import { createHash } from "node:crypto";
import { lstat, mkdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

export interface RuntimePin {
  runtimeVersion: string;
  sourceURL: string;
  sourceTag: string;
  sourceCommit: string;
  patchSHA256: string;
}

export const sha256 = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");

export function parseRuntimeArguments(args: string[], root: string) {
  let release = false;
  let isolated = false;
  let prepareOnly = false;
  let sourceOverride: string | undefined;
  for (let index = 0; index < args.length; index++) {
    switch (args[index]) {
      case "--release": release = true; break;
      case "--isolated-source": isolated = true; break;
      case "--prepare-only": prepareOnly = true; break;
      case "--source-dir": {
        const value = args[++index];
        if (!value || value.startsWith("--") || sourceOverride) throw new Error("--source-dir requires one directory.");
        sourceOverride = resolve(value);
        break;
      }
      default:
        throw new Error("Usage: bun Scripts/build-agent-runtime.ts [--release] [--isolated-source | --source-dir PATH] [--prepare-only]");
    }
  }
  if (isolated && sourceOverride) throw new Error("Use --isolated-source or --source-dir, not both.");
  return {
    profile: release ? "release" : "dev-small",
    prepareOnly,
    source: sourceOverride ?? join(root, ".build/runtime", isolated ? "codex-source-reviewed" : "codex-source"),
  };
}

export async function readRuntimePin(root: string): Promise<RuntimePin> {
  const pin = JSON.parse(await readFile(join(root, "Runtime/codex-source.lock.json"), "utf8"));
  if (pin.sourceURL !== "https://github.com/openai/codex.git"
      || pin.sourceCommit !== "4607249e430dac1c961df4dc615beae88e33cec8"
      || pin.sourceTag !== "rust-v0.155.0-alpha.9.2"
      || !/^mactopus-[0-9]+$/.test(pin.runtimeVersion)
      || !/^[a-f0-9]{64}$/.test(pin.patchSHA256)) {
    throw new Error("Invalid pinned runtime dependency. Review the lock file before building.");
  }
  return pin;
}

export async function run(command: string[], cwd: string, capture = false) {
  const child = Bun.spawn(command, {
    cwd, env: { ...process.env, CARGO_INCREMENTAL: "0", CARGO_BUILD_JOBS: "1" },
    stdin: "ignore", stdout: capture ? "pipe" : "inherit", stderr: "inherit",
  });
  const output = capture ? await new Response(child.stdout).text() : "";
  if (await child.exited !== 0) throw new Error(`Command failed: ${command.join(" ")}`);
  return output.trim();
}

// Ignore user diff drivers, color/rename preferences, and abbreviation settings:
// this is a source-integrity comparison, not a presentation diff.
export function reviewedDiff(source: string) {
  return run(["git", "--no-pager", "-c", "core.abbrev=7", "-c", "color.ui=false",
    "-c", "diff.algorithm=myers", "-c", "diff.mnemonicPrefix=false", "diff",
    "--no-ext-diff", "--no-textconv", "--no-renames", "--binary", "HEAD", "--"], source, true);
}

async function verifyCheckoutIdentity(source: string, pin: RuntimePin) {
  if (await run(["git", "rev-parse", "HEAD"], source, true) !== pin.sourceCommit) {
    throw new Error("Existing source checkout has the wrong revision; it was left untouched.");
  }
  if (await run(["git", "remote", "get-url", "origin"], source, true) !== pin.sourceURL) {
    throw new Error("Existing source checkout has an unexpected origin; it was left untouched.");
  }
  if (await run(["git", "ls-files", "--others", "--exclude-standard"], source, true)) {
    throw new Error("Source checkout has unreviewed files; it was left untouched. Use --isolated-source or a fresh --source-dir.");
  }
}

export async function verifyPreparedRuntime(source: string, pin: RuntimePin, patch: string) {
  await verifyCheckoutIdentity(source, pin);
  const patchBytes = await readFile(patch);
  if (sha256(patchBytes) !== pin.patchSHA256) throw new Error("Reviewed runtime patch does not match its lock-file checksum.");
  if (await reviewedDiff(source) !== patchBytes.toString("utf8").trim()) {
    throw new Error("Source checkout differs from the exact reviewed patch; it was left untouched. Use --isolated-source or a fresh --source-dir.");
  }
}

export async function prepareRuntimeSource(root: string, source: string, pin: RuntimePin, patch: string) {
  const patchBytes = await readFile(patch);
  if (sha256(patchBytes) !== pin.patchSHA256) throw new Error("Reviewed runtime patch does not match its lock-file checksum.");
  const existing = await lstat(source).catch(error => {
    if (error.code === "ENOENT") return null;
    throw error;
  });
  if (existing && (!existing.isDirectory() || existing.isSymbolicLink())) {
    throw new Error("Source checkout must be a real directory, not a symlink or file.");
  }
  if (!existing) {
    await mkdir(dirname(source), { recursive: true });
    await run(["git", "clone", "--config", "core.autocrlf=false", "--depth", "1",
      "--single-branch", "--branch", pin.sourceTag, pin.sourceURL, source], root);
  }
  await verifyCheckoutIdentity(source, pin);
  const currentDiff = await reviewedDiff(source);
  if (!currentDiff) {
    await run(["git", "apply", "--check", patch], source);
    await run(["git", "apply", "--intent-to-add", patch], source);
  }
  await verifyPreparedRuntime(source, pin, patch);
  return source;
}
