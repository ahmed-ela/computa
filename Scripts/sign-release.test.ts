import { afterEach, expect, test } from "bun:test";
import { cp, lstat, mkdtemp, mkdir, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { parseSignOptions, signRelease, type SignRunner } from "./sign-release";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
const sha = (text: string) => createHash("sha256").update(text).digest("hex");
const identity = "Developer ID Application: Fixture (TEAM123456)";

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "computa-sign-"))); roots.push(root);
  const app = join(root, "input.app"), output = join(root, "signed.app");
  const runtime = "Contents/Resources/AgentRuntime/codex-app-server";
  const manifestPath = "Contents/Resources/AgentRuntime/manifest.json";
  for (const relative of ["Contents/MacOS", "Contents/Resources/ChromeBridge", "Contents/Resources/AgentRuntime"]) await mkdir(join(app, relative), { recursive: true });
  for (const relative of ["Contents/Info.plist", "Contents/MacOS/Computa", "Contents/Resources/ChromeBridge/ChromeBridgeHost"]) await writeFile(join(app, relative), "fixture");
  await writeFile(join(app, runtime), "original");
  const manifest = { executable: "codex-app-server", platform: "macos", architecture: "arm64", binarySize: 8, binarySHA256: sha("original"), sourceCommit: "pinned-source", patchSHA256: "pinned-patch" };
  await writeFile(join(app, manifestPath), JSON.stringify(manifest));
  const calls: string[][] = [];
  const run: SignRunner = async command => {
    calls.push(command);
    if (command[0] === "/usr/bin/security") return `  1) ${"A".repeat(40)} "${identity}"`;
    if (command[0] === "/usr/bin/plutil") return "com.ahmedelamin.LocalCodex";
    if (command[0] === "/usr/bin/ditto") await cp(command[1], command[2], { recursive: true });
    if (command.includes("--sign") && command.at(-1) === join(output, runtime)) await writeFile(join(output, runtime), "signed-runtime");
    if (command.includes("--sign") && command.at(-1) === output) {
      const sealed = JSON.parse(await readFile(join(output, manifestPath), "utf8"));
      expect(sealed.binarySHA256).toBe(sha("signed-runtime"));
      expect(sealed.binarySize).toBe(14);
    }
    return "";
  };
  return { app, output, runtime, manifestPath, calls, run, options: { app, output, identity } };
}

test("signs copy inside out, refreshes integrity before sealing, preserves original and provenance", async () => {
  const f = await fixture(); const result = await signRelease(f.options, f.run);
  expect(await readFile(join(f.app, f.runtime), "utf8")).toBe("original");
  expect(JSON.parse(await readFile(join(f.output, f.manifestPath), "utf8")).sourceCommit).toBe("pinned-source");
  expect(result.runtimeSHA256).toBe(sha("signed-runtime"));
  const signs = f.calls.filter(call => call.includes("--sign"));
  expect(signs.map(call => call.at(-1))).toEqual([join(f.output, f.runtime), join(f.output, "Contents/Resources/ChromeBridge/ChromeBridgeHost"), f.output]);
  expect(signs.every(call => call.includes("--timestamp") && call.includes("runtime"))).toBe(true);
});

test("refuses a modified runtime before staging or signing", async () => {
  const f = await fixture(); await writeFile(join(f.app, f.runtime), "altered");
  await expect(signRelease(f.options, f.run)).rejects.toThrow("integrity manifest");
  expect(f.calls.some(call => call.includes("--sign") || call[0] === "/usr/bin/ditto")).toBe(false);
});

test("does not overwrite existing apps or sign in place", async () => {
  const f = await fixture();
  await expect(signRelease({ ...f.options, output: f.app }, f.run)).rejects.toThrow("separate");
  await mkdir(f.output);
  await expect(signRelease(f.options, f.run)).rejects.toThrow("already exists");
  expect(f.calls).toHaveLength(0);
});

test("refuses unavailable identity and rejects duplicate or option-like CLI arguments", async () => {
  const f = await fixture();
  await expect(signRelease({ ...f.options, identity: "Apple Development: Fixture" }, f.run)).rejects.toThrow("Developer ID");
  expect(() => parseSignOptions(["--app", "a.app", "--output", "b.app", "--identity", "-"])).toThrow();
  expect(() => parseSignOptions(["--app", "a.app", "--app", "b.app"])).toThrow();
});

test("rejects nested output before creating a directory in the source", async () => {
  const f = await fixture();
  await expect(signRelease({ ...f.options, output: join(f.app, "new-dir/signed.app") }, f.run)).rejects.toThrow("separate");
  await expect(lstat(join(f.app, "new-dir"))).rejects.toMatchObject({ code: "ENOENT" });
  expect(f.calls).toHaveLength(0);
});

test("rejects symlinked resource ancestors without signing or changing external files", async () => {
  const f = await fixture();
  const original = join(f.app, "Contents/Resources/AgentRuntime");
  const external = join(f.output, "../external-runtime");
  await rename(original, external); await symlink(external, original);
  await expect(signRelease(f.options, f.run)).rejects.toThrow("symlink");
  expect(await readFile(join(external, "codex-app-server"), "utf8")).toBe("original");
  expect(f.calls).toHaveLength(0);
});
