#!/usr/bin/env bun
// Offline only: compile the exact allocator against existing cached dependencies, never Cargo.
import { createHash } from "node:crypto";
import { lstat, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dir, "../..");
const sourceRoot = join(root, ".build/runtime/codex-source");
const rustRoot = join(sourceRoot, "codex-rs");
const deps = join(rustRoot, "target/dev-small/deps");
const [rollout, turn, output] = process.argv.slice(2);
if (!rollout?.startsWith("/") || !output?.startsWith("/") || !/^[0-9a-f-]{36}$/.test(turn ?? "")) {
  throw new Error("Usage: bun native-floor-audit.ts ABSOLUTE_ROLLOUT TURN_UUID EXISTING_PRIVATE_DIRECTORY");
}
const directory = await lstat(output);
const input = await lstat(rollout);
if (!directory.isDirectory() || directory.isSymbolicLink() || (directory.mode & 0o077) !== 0
    || !input.isFile() || input.isSymbolicLink() || input.size > 64 * 1024 * 1024) {
  throw new Error("Expected a private output directory and bounded regular rollout file");
}
const hash = (bytes: string | Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const rolloutSHA256 = hash(await readFile(rollout));
async function capture(command: string[], cwd = root, stdin?: string) {
  const proc = Bun.spawn(command, { cwd, stdin: stdin === undefined ? "ignore" : "pipe", stdout: "pipe", stderr: "pipe" });
  if (stdin !== undefined) { proc.stdin.write(stdin); proc.stdin.end(); }
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  if (code !== 0) {
    // Compiler diagnostics contain source paths, not rollout content; persist privately regardless.
    await writeFile(join(output, `failure-${Date.now()}.txt`), stderr, { flag: "wx", mode: 0o600 });
    throw new Error(`Offline command failed (${code}); private diagnostics retained`);
  }
  return stdout.trim();
}
const pin = JSON.parse(await readFile(join(root, "Runtime/codex-source.lock.json"), "utf8"));
const manifest = JSON.parse(await readFile(join(root, "Sources/Computa/Resources/AgentRuntime/manifest.json"), "utf8"));
const patch = await readFile(join(root, "Runtime/patches/compaction-retention.patch"), "utf8");
if (hash(patch) !== pin.patchSHA256 || manifest.patchSHA256 !== pin.patchSHA256
    || await capture(["git", "rev-parse", "HEAD"], sourceRoot) !== pin.sourceCommit
    || await capture(["git", "diff", "--binary", "HEAD", "--"], sourceRoot) !== patch.trim()
    || await capture(["git", "ls-files", "--others", "--exclude-standard"], sourceRoot)) {
  throw new Error("Pinned source, reviewed patch, and packaged manifest must agree exactly");
}
const allocatorPath = join(rustRoot, "core/src/compact_tool_receipts.rs");
const allocator = await readFile(allocatorPath, "utf8");
const frozenAllocatorSHA256 = "ebef138ff0b4808fe21f081ad645f48311d2940b19f4994155796b87c6b46f6f";
if (hash(allocator) !== frozenAllocatorSHA256) throw new Error("Baseline allocator changed; explicitly review a separate candidate audit");
const client = await readFile(join(rustRoot, "core/src/client.rs"), "utf8");
const projection = client.match(/pub\(crate\) fn prepare_input_for_non_openai_provider\(input: &mut \[ResponseItem\]\) \{\n[\s\S]*?\n\}/g);
if (projection?.length !== 1) throw new Error("Expected one exact external-provider projection");
const harness = await readFile(join(import.meta.dir, "native-floor-harness.rs"), "utf8");
const marker = "// END RECEIPT MODULE AUDIT";
const segments = harness.split(marker);
if (segments.length !== 2) throw new Error("Invalid offline instrumentation boundary");
const code = `mod client { use codex_protocol::models::ResponseItem;\n${projection[0]}\n}\n`
  + `mod compact_tool_receipts {\n${allocator}\n${segments[0]}\n}\n${segments[1]}`;
// These are the existing mutually compatible dependency artifacts, not rebuilt libraries.
const libraries = {
  codex_protocol: "libcodex_protocol-c20e9de3c3d8c0ee.rlib",
  codex_history: "libcodex_history-735ccdf773b43ff1.rlib",
  codex_rollout: "libcodex_rollout-a5b9b21ce7963d44.rlib",
  codex_utils_output_truncation: "libcodex_utils_output_truncation-62bac46a284bf25f.rlib",
  base64: "libbase64-245335b498ff70ed.rlib",
  serde_json: "libserde_json-3a9be4674f0338ce.rlib",
};
const libraryHashes: Record<string, { file: string; sha256: string }> = {};
for (const [name, file] of Object.entries(libraries)) {
  const bytes = await readFile(join(deps, file));
  libraryHashes[name] = { file, sha256: hash(bytes) };
}
const binary = join(output, "native-receipt-floor");
if (await lstat(binary).catch(() => null)) throw new Error("Output directory must not contain an earlier runner");
const compiler = await capture(["rustc", "-Vv"]);
const started = performance.now();
await capture(["rustc", "--edition=2024", "--crate-name", "heydash_receipt_floor", "-",
  "-C", "debuginfo=0", "-L", `dependency=${deps}`, ...Object.entries(libraries).flatMap(([name, file]) =>
    ["--extern", `${name}=${join(deps, file)}`]), "-o", binary], root, code);
const compileMS = performance.now() - started;
const result = JSON.parse(await capture([binary, rollout, turn]));
if (hash(await readFile(allocatorPath)) !== hash(allocator)
    || hash(await readFile(rollout)) !== rolloutSHA256) throw new Error("Source or rollout changed during the audit");
const audit = { schemaVersion: 1, offlineOnly: true, productionSourceUnchanged: true,
  sourceCommit: pin.sourceCommit, patchSHA256: pin.patchSHA256,
  allocatorSHA256: hash(allocator), projectionSHA256: hash(projection[0]),
  instrumentationSHA256: hash(harness), compilerInputSHA256: hash(code),
  runnerSHA256: hash(await readFile(import.meta.path)),
  rolloutSHA256, binarySHA256: hash(await readFile(binary)),
  compiler, libraryHashes, compileMS, binaryBytes: (await lstat(binary)).size, ...result };
await writeFile(join(output, "audit.json"), JSON.stringify(audit, null, 2) + "\n", { flag: "wx", mode: 0o600 });
console.log(JSON.stringify({ offlineOnly: true, compileMS, binaryBytes: audit.binaryBytes, ...result }));
