import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseRuntimeArguments, prepareRuntimeSource, reviewedDiff, run, sha256,
  verifyPreparedRuntime, type RuntimePin } from "./runtime-source";

const temporaryDirectories: string[] = [];
afterEach(async () => {
  for (const directory of temporaryDirectories.splice(0)) await rm(directory, { recursive: true });
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "computa-runtime-source-test-"));
  temporaryDirectories.push(root);
  const upstream = join(root, "upstream");
  await mkdir(upstream);
  await run(["git", "init", "--quiet"], upstream);
  await run(["git", "config", "user.name", "Runtime Source Test"], upstream);
  await run(["git", "config", "user.email", "runtime-test@example.invalid"], upstream);
  await writeFile(join(upstream, "runtime.rs"), "fn main() {}\n");
  await writeFile(join(upstream, "untouched.rs"), "pub const UPSTREAM: bool = true;\n");
  await run(["git", "add", "runtime.rs", "untouched.rs"], upstream);
  await run(["git", "commit", "--quiet", "-m", "Upstream fixture"], upstream);
  await run(["git", "tag", "fixture-v1"], upstream);
  const sourceCommit = await run(["git", "rev-parse", "HEAD"], upstream, true);
  await writeFile(join(upstream, "runtime.rs"), 'mod retained;\nfn main() { retained::verify(); }\n');
  await writeFile(join(upstream, "retained.rs"), "pub fn verify() {}\n");
  await run(["git", "add", "--intent-to-add", "retained.rs"], upstream);
  const patch = join(root, "reviewed.patch");
  await writeFile(patch, await reviewedDiff(upstream) + "\n");
  const pin: RuntimePin = {
    runtimeVersion: "mactopus-5", sourceURL: `file://${upstream}`, sourceTag: "fixture-v1",
    sourceCommit, patchSHA256: sha256(await readFile(patch)),
  };
  return { root, source: join(root, "prepared"), pin, patch };
}

describe("reviewed runtime source preparation", () => {
  test("preparation includes added source files and is idempotent", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    expect(await readFile(join(value.source, "retained.rs"), "utf8")).toBe("pub fn verify() {}\n");
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    await verifyPreparedRuntime(value.source, value.pin, value.patch);
  });

  test("preparation preserves upstream files outside the reviewed patch in the index", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    expect((await run(["git", "ls-files"], value.source, true)).split("\n")).toEqual([
      "retained.rs", "runtime.rs", "untouched.rs",
    ]);
    expect(await run(["git", "diff", "HEAD", "--", "untouched.rs"], value.source, true)).toBe("");
    expect(await readFile(join(value.source, "untouched.rs"), "utf8")).toBe("pub const UPSTREAM: bool = true;\n");
    await verifyPreparedRuntime(value.source, value.pin, value.patch);
  });

  test("unknown tracked edits are preserved and rejected", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    const edited = "fn preserve_user_work() {}\n";
    await writeFile(join(value.source, "runtime.rs"), edited);
    await expect(prepareRuntimeSource(value.root, value.source, value.pin, value.patch)).rejects.toThrow("differs from the exact reviewed patch");
    expect(await readFile(join(value.source, "runtime.rs"), "utf8")).toBe(edited);
  });

  test("unreviewed additions are preserved and rejected", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    await writeFile(join(value.source, "private-experiment.rs"), "unreviewed source\n");
    await expect(verifyPreparedRuntime(value.source, value.pin, value.patch)).rejects.toThrow("unreviewed files");
    expect(await readFile(join(value.source, "private-experiment.rs"), "utf8")).toBe("unreviewed source\n");
  });

  test("staged edits to patch-added files are preserved and rejected", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    const edited = "pub fn unreviewed() {}\n";
    await writeFile(join(value.source, "retained.rs"), edited);
    await run(["git", "add", "retained.rs"], value.source);
    await expect(verifyPreparedRuntime(value.source, value.pin, value.patch)).rejects.toThrow("differs from the exact reviewed patch");
    expect(await readFile(join(value.source, "retained.rs"), "utf8")).toBe(edited);
  });

  test("wrong source revision is rejected without applying the patch", async () => {
    const value = await fixture();
    await expect(prepareRuntimeSource(value.root, value.source,
      { ...value.pin, sourceCommit: "0".repeat(40) }, value.patch)).rejects.toThrow("wrong revision");
    expect(await readFile(join(value.source, "runtime.rs"), "utf8")).toBe("fn main() {}\n");
  });

  test("origin and patch checksum are rechecked", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    await expect(verifyPreparedRuntime(value.source,
      { ...value.pin, sourceURL: "https://example.invalid/unreviewed" }, value.patch)).rejects.toThrow("unexpected origin");
    await expect(verifyPreparedRuntime(value.source,
      { ...value.pin, patchSHA256: "0".repeat(64) }, value.patch)).rejects.toThrow("checksum");
  });

  test("user diff formatting does not change integrity comparison", async () => {
    const value = await fixture();
    await prepareRuntimeSource(value.root, value.source, value.pin, value.patch);
    await run(["git", "config", "core.abbrev", "12"], value.source);
    await run(["git", "config", "diff.mnemonicPrefix", "true"], value.source);
    await run(["git", "config", "color.ui", "always"], value.source);
    await verifyPreparedRuntime(value.source, value.pin, value.patch);
  });
});

test("prepare-only accepts isolated or explicit source, rejects ambiguous options", () => {
  expect(parseRuntimeArguments(["--prepare-only", "--isolated-source"], "/repo")).toEqual({
    profile: "dev-small", prepareOnly: true, source: "/repo/.build/runtime/codex-source-reviewed",
  });
  expect(parseRuntimeArguments(["--release", "--source-dir", "/clean-source"], "/repo")).toEqual({
    profile: "release", prepareOnly: false, source: "/clean-source",
  });
  expect(() => parseRuntimeArguments(["--isolated-source", "--source-dir", "/source"], "/repo")).toThrow("not both");
  expect(() => parseRuntimeArguments(["--source-dir", "--release"], "/repo")).toThrow("requires one directory");
  expect(() => parseRuntimeArguments(["--unknown"], "/repo")).toThrow("Usage");
});
