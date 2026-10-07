import { afterEach, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { bumpVersion, checkVersion, isAppVersion, isBuildNumber, nextVersion, parseVersionConfig, releaseBase } from "./version";

const directories: string[] = [];
afterEach(async () => { for (const path of directories.splice(0)) await rm(path, { recursive: true, force: true }); });
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "computa-version-")); directories.push(root);
  await mkdir(join(root, "Config")); await mkdir(join(root, "crates/app"), { recursive: true });
  await writeFile(join(root, "Config/Version.xcconfig"), "// Shared app version\nMARKETING_VERSION = 0.1.9\nCURRENT_PROJECT_VERSION = 41\n");
  await writeFile(join(root, "Cargo.toml"), '[workspace]\nmembers = ["crates/app"]\n[workspace.package]\nversion = "0.1.9"\nedition = "2024"\n');
  await writeFile(join(root, "crates/app/Cargo.toml"), '[package]\nname = "computa-app"\nversion.workspace = true\n');
  await writeFile(join(root, "Cargo.lock"), 'version = 4\n\n[[package]]\nname = "computa-app"\nversion = "0.1.9"\n\n[[package]]\nname = "dependency"\nversion = "0.1.9"\nsource = "registry+fixture"\n');
  return root;
}

test("Apple app version is exactly three canonical numeric components", () => {
  expect(isAppVersion("1.10.123")).toBe(true); expect(isAppVersion("0.1.0")).toBe(true);
  for (const invalid of ["1.2", "01.2.3", "1.02.3", "1.2.03", "1.2.3-preview.1", "1.2.3+41", "1.2.3.4", "1.2.3\n", "4294967296.0.0", 1]) expect(isAppVersion(invalid)).toBe(false);
  for (const invalid of ["0", "01", "1.0", "10000", 1]) expect(isBuildNumber(invalid)).toBe(false);
});

test("release labels follow SemVer and retain the numeric app version", () => {
  for (const valid of ["1.2.3", "1.2.3-preview.1", "1.2.3-rc-2+build.001"]) expect(releaseBase(valid)).toBe("1.2.3");
  for (const invalid of ["v1.2.3", "1.2.3.preview.1", "01.2.3", "1.2.3-01", "1.2.3-rc.01", "1.2.3-", "1.2.3+", "1.2.3--bad..x", "1.2.3\n"]) expect(() => releaseBase(invalid)).toThrow();
});

test("config rejects duplicates, missing values and Xcode expressions", () => {
  expect(parseVersionConfig("// app\nMARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n")).toEqual({ version: "0.1.0", build: "1" });
  for (const text of ["MARKETING_VERSION = 0.1.0\n", "MARKETING_VERSION = $(VERSION)\nCURRENT_PROJECT_VERSION = 1", "MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\nCURRENT_PROJECT_VERSION = 2"]) expect(() => parseVersionConfig(text)).toThrow();
});

test("major/minor reset lower components; every bump advances build monotonically", () => {
  const current = { version: "1.9.9", build: "42" };
  expect(nextVersion(current, "major")).toEqual({ version: "2.0.0", build: "43" });
  expect(nextVersion(current, "minor")).toEqual({ version: "1.10.0", build: "43" });
  expect(nextVersion(current, "patch")).toEqual({ version: "1.9.10", build: "43" });
  expect(nextVersion(current, "build")).toEqual({ version: "1.9.9", build: "43" });
  expect(() => nextVersion({ version: "1.0.0", build: "9999" }, "build")).toThrow("exhausted");
  expect(() => nextVersion({ version: "4294967295.0.0", build: "1" }, "major")).toThrow("exhausted");
});

test("a real patch bump updates canonical metadata, Cargo and only workspace lock entries", async () => {
  const root = await fixture();
  expect(await checkVersion(root)).toEqual({ version: "0.1.9", build: "41" });
  expect(await bumpVersion(root, "patch")).toEqual({ version: "0.1.10", build: "42" });
  expect(await checkVersion(root)).toEqual({ version: "0.1.10", build: "42" });
  expect(await readFile(join(root, "Cargo.lock"), "utf8")).toContain('name = "dependency"\nversion = "0.1.9"');
  expect(await readFile(join(root, "Config/Version.xcconfig"), "utf8")).toStartWith("// Shared app version\n");
});

test("build-only bump leaves Cargo manifests and lock bytes unchanged", async () => {
  const root = await fixture(), cargo = await readFile(join(root, "Cargo.toml"), "utf8"), lock = await readFile(join(root, "Cargo.lock"), "utf8");
  expect(await bumpVersion(root, "build")).toEqual({ version: "0.1.9", build: "42" });
  expect(await readFile(join(root, "Cargo.toml"), "utf8")).toBe(cargo);
  expect(await readFile(join(root, "Cargo.lock"), "utf8")).toBe(lock);
});

test("single-quoted workspace versions and commented headers cannot cause an incomplete bump", async () => {
  const root = await fixture(), path = join(root, "Cargo.toml");
  await writeFile(join(root, "Config/Version.xcconfig"), "  MARKETING_VERSION = 0.1.9 // app\n  CURRENT_PROJECT_VERSION = 41 // build\n");
  await writeFile(path, '# [workspace.package]\n[extra]\nversion = "9.0.0"\n' + (await readFile(path, "utf8")).replace('version = "0.1.9"', "version = '0.1.9'"));
  expect(await bumpVersion(root, "minor")).toEqual({ version: "0.2.0", build: "42" });
  expect(await checkVersion(root)).toEqual({ version: "0.2.0", build: "42" });
  expect(await readFile(path, "utf8")).toContain('version = "9.0.0"');
});

test("unsupported lock formatting is rejected before canonical metadata is changed", async () => {
  const root = await fixture(), lock = join(root, "Cargo.lock");
  await writeFile(lock, (await readFile(lock, "utf8")).replace('version = "0.1.9"', "version = '0.1.9'"));
  const before = await readFile(join(root, "Config/Version.xcconfig"), "utf8");
  await expect(bumpVersion(root, "patch")).rejects.toThrow("no files were changed");
  expect(await readFile(join(root, "Config/Version.xcconfig"), "utf8")).toBe(before);
});

test("source drift and missing workspace lock entries fail before changing files", async () => {
  for (const changed of ["Cargo.toml", "Cargo.lock"]) {
    const root = await fixture(), path = join(root, changed);
    await writeFile(path, (await readFile(path, "utf8")).replace('version = "0.1.9"', 'version = "0.2.0"'));
    const before = await readFile(join(root, "Config/Version.xcconfig"), "utf8");
    await expect(bumpVersion(root, "minor")).rejects.toThrow("differs");
    expect(await readFile(join(root, "Config/Version.xcconfig"), "utf8")).toBe(before);
  }
});
