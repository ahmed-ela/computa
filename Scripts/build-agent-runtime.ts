#!/usr/bin/env bun
// Reproducible app-owned dependency build. Never reads or changes an installed
// Codex/ChatGPT bundle, user configuration, model cache, or system permissions.
import { copyFile, lstat, mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseRuntimeArguments, prepareRuntimeSource, readRuntimePin, run, sha256,
  verifyPreparedRuntime } from "./runtime-source";

const root = resolve(import.meta.dir, "..");
const pin = await readRuntimePin(root);
const { profile, prepareOnly, source } = parseRuntimeArguments(process.argv.slice(2), root);
if (!prepareOnly && (process.platform !== "darwin" || process.arch !== "arm64")) {
  throw new Error("This runtime build currently supports arm64 macOS only.");
}
// Keep an in-progress upstream checkout intact. The optional second checkout
// is still pinned and exact-diff verified; it never imports cached source edits.
const target = join(root, ".build/runtime/codex-source/codex-rs/target");
const patch = join(root, "Runtime/patches/compaction-retention.patch");
await prepareRuntimeSource(root, source, pin, patch);
if (prepareOnly) {
  console.log(`Verified complete patched runtime source: ${source}`);
  console.log(`Upstream: ${pin.sourceCommit}; patch SHA-256: ${pin.patchSHA256}`);
  console.log("No compiler, app install, signing, model download, or user-state changes were performed.");
  process.exit(0);
}
const cargo = join(source, "codex-rs");
// An unrelated Homebrew Cargo earlier on PATH must not silently select a
// different compiler. rustup run requires an already-installed exact toolchain.
const rustVersion = await run(["rustup", "run", "1.95.0", "rustc", "--version"], cargo, true);
if (!/^rustc 1\.95\.0(?:\s|$)/.test(rustVersion)) {
  throw new Error("Install Rust 1.95.0 through rustup before building the agent runtime.");
}
// Always invoke Cargo's fingerprint check, even when a binary already exists;
// a source/patch checksum alone does not prove that binary was rebuilt from it.
// Read the reported artifact path rather than guessing it: a caller's Cargo
// target configuration must not make us package an older binary elsewhere.
const buildOutput = await run(["rustup", "run", "1.95.0", "cargo", "build", "--locked", "--profile", profile,
  "--config", `profile.${profile}.build-override.strip="none"`,
  "--target-dir", target, "--message-format=json-render-diagnostics",
  "-p", "codex-app-server", "--bin", "codex-app-server"], cargo, true);
const artifacts = buildOutput.split("\n").map(line => JSON.parse(line)).filter(value =>
  value.reason === "compiler-artifact" && value.target?.name === "codex-app-server"
  && value.target?.kind?.includes("bin") && typeof value.executable === "string");
if (artifacts.length !== 1) throw new Error("Cargo did not report exactly one App Server executable.");
const built = resolve(artifacts[0].executable);
if (!built.startsWith(target + "/")) throw new Error("Unexpected Cargo artifact location.");
await verifyPreparedRuntime(source, pin, patch);
const builtStat = await lstat(built);
if (!builtStat.isFile() || builtStat.isSymbolicLink() || builtStat.size < 32 || builtStat.size > 512 * 1024 * 1024) {
  throw new Error("Cargo artifact must be a regular executable within the 512 MiB bound.");
}
const builtBytes = await readFile(built);
if (builtBytes.length < 32 || builtBytes.readUInt32LE(0) !== 0xfeedfacf
    || builtBytes.readUInt32LE(4) !== 0x0100000c || builtBytes.readUInt32LE(12) !== 2) {
  throw new Error("Cargo artifact is not a thin arm64 Mach-O executable.");
}
const resource = join(root, "Sources/Mactopus/Resources/AgentRuntime");
await mkdir(resource, { recursive: true });
const executable = join(resource, "codex-app-server");
await copyFile(built, executable);
await run(["codesign", "--force", "--options", "runtime", "--sign", "-", executable], root);
await run(["codesign", "--verify", "--strict", executable], root);
const binary = await readFile(executable);
await writeFile(join(resource, "manifest.json"), JSON.stringify({
  schemaVersion: 1, runtimeVersion: pin.runtimeVersion, sourceCommit: pin.sourceCommit,
  patchSHA256: pin.patchSHA256, binarySHA256: sha256(binary), binarySize: binary.length,
  platform: "macos", architecture: "arm64", executable: "codex-app-server",
}, null, 2) + "\n");
await copyFile(join(source, "LICENSE"), join(resource, "LICENSE"));
await copyFile(join(source, "NOTICE"), join(resource, "NOTICE"));
console.log(`Packaged Mactopus runtime (${profile}): ${sha256(binary)}`);
