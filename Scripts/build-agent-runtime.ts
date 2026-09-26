#!/usr/bin/env bun
// Reproducible app-owned dependency build. Never reads or changes an installed
// Codex/ChatGPT bundle, user configuration, model cache, or system permissions.
import { createHash } from "node:crypto";
import { copyFile, lstat, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const pinPath = join(root, "Runtime/codex-source.lock.json");
const pin = JSON.parse(await readFile(pinPath, "utf8"));
const args = process.argv.slice(2);
const profile = args.includes("--release") ? "release" : "dev-small";
if (args.some(arg => arg !== "--release")) {
  throw new Error("Usage: bun Scripts/build-agent-runtime.ts [--release]");
}
if (pin.sourceURL !== "https://github.com/openai/codex.git"
    || pin.sourceCommit !== "4607249e430dac1c961df4dc615beae88e33cec8"
    || pin.sourceTag !== "rust-v0.155.0-alpha.9.2"
    || !/^[a-f0-9]{64}$/.test(pin.patchSHA256)) {
  throw new Error("Invalid pinned runtime dependency. Review the lock file before building.");
}
if (process.platform !== "darwin" || process.arch !== "arm64") {
  throw new Error("This runtime build currently supports arm64 macOS only.");
}
const source = join(root, ".build/runtime/codex-source");
const patch = join(root, "Runtime/patches/compaction-retention.patch");
const sha256 = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
if (sha256(await readFile(patch)) !== pin.patchSHA256) {
  throw new Error("Reviewed compaction patch does not match its lock-file checksum.");
}
async function run(command: string[], cwd: string, capture = false) {
  const child = Bun.spawn(command, {
    cwd, env: { ...process.env, CARGO_INCREMENTAL: "0", CARGO_BUILD_JOBS: "2" },
    stdin: "ignore", stdout: capture ? "pipe" : "inherit", stderr: "inherit",
  });
  const output = capture ? await new Response(child.stdout).text() : "";
  if (await child.exited !== 0) throw new Error(`Command failed: ${command.join(" ")}`);
  return output.trim();
}
if (!await stat(source).catch(() => null)) {
  await mkdir(dirname(source), { recursive: true });
  await run(["git", "clone", "--depth", "1", "--single-branch", "--branch", pin.sourceTag,
    pin.sourceURL, source], root);
}
if (await run(["git", "rev-parse", "HEAD"], source, true) !== pin.sourceCommit) {
  throw new Error("Existing source checkout has the wrong revision; it was left untouched.");
}
if (await run(["git", "remote", "get-url", "origin"], source, true) !== pin.sourceURL) {
  throw new Error("Existing source checkout has an unexpected origin; it was left untouched.");
}
const currentDiff = await run(["git", "diff", "--binary", "HEAD", "--"], source, true);
const untracked = await run(["git", "ls-files", "--others", "--exclude-standard"], source, true);
// Source additions must be intent-to-add in the reviewed patch, not silently
// excluded by git diff. Never discard or overwrite an unknown cached change.
if (untracked) throw new Error("Source checkout has unreviewed files; it was left untouched.");
if (!currentDiff) {
  await run(["git", "apply", "--check", patch], source);
  await run(["git", "apply", "--intent-to-add", patch], source);
} else if (currentDiff !== (await readFile(patch, "utf8")).trim()) {
  throw new Error("Source checkout differs from the exact reviewed patch; it was left untouched.");
}
const cargo = join(source, "codex-rs");
// Always invoke Cargo's fingerprint check, even when a binary already exists;
// a source/patch checksum alone does not prove that binary was rebuilt from it.
// Read the reported artifact path rather than guessing it: a caller's Cargo
// target configuration must not make us package an older binary elsewhere.
const buildOutput = await run(["cargo", "build", "--locked", "--profile", profile,
  "--config", `profile.${profile}.build-override.strip="none"`,
  "--target-dir", join(cargo, "target"), "--message-format=json-render-diagnostics",
  "-p", "codex-app-server", "--bin", "codex-app-server"], cargo, true);
const artifacts = buildOutput.split("\n").map(line => JSON.parse(line)).filter(value =>
  value.reason === "compiler-artifact" && value.target?.name === "codex-app-server"
  && value.target?.kind?.includes("bin") && typeof value.executable === "string");
if (artifacts.length !== 1) throw new Error("Cargo did not report exactly one App Server executable.");
const built = resolve(artifacts[0].executable);
if (!built.startsWith(join(cargo, "target") + "/")) throw new Error("Unexpected Cargo artifact location.");
if (await run(["git", "rev-parse", "HEAD"], source, true) !== pin.sourceCommit
    || await run(["git", "diff", "--binary", "HEAD", "--"], source, true) !== (await readFile(patch, "utf8")).trim()
    || await run(["git", "ls-files", "--others", "--exclude-standard"], source, true)
    || sha256(await readFile(patch)) !== pin.patchSHA256) {
  throw new Error("Reviewed source changed while building; no runtime was packaged.");
}
const builtStat = await lstat(built);
if (!builtStat.isFile() || builtStat.isSymbolicLink() || builtStat.size < 32 || builtStat.size > 512 * 1024 * 1024) {
  throw new Error("Cargo artifact must be a regular executable within the 512 MiB bound.");
}
const builtBytes = await readFile(built);
if (builtBytes.length < 32 || builtBytes.readUInt32LE(0) !== 0xfeedfacf
    || builtBytes.readUInt32LE(4) !== 0x0100000c || builtBytes.readUInt32LE(12) !== 2) {
  throw new Error("Cargo artifact is not a thin arm64 Mach-O executable.");
}
const resource = join(root, "Sources/Macrouse/Resources/AgentRuntime");
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
console.log(`Packaged Macrouse runtime (${profile}): ${sha256(binary)}`);
