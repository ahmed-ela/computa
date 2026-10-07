import { afterEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checksumEntries, installerSources, parsePublishOptions, publishAlpha, verifyInstallerPayload, type PublishContext } from "./publish-alpha";

const tag = "v0.1.2-alpha.3", repo = "owner/computa", source = "a".repeat(40);
const stem = "Computa-0.1.2-alpha.3-arm64-signed-test";
const digest = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const stages: string[] = [];
afterEach(async () => { for (const stage of stages.splice(0)) await rm(stage, { recursive: true, force: true }); });

function fixture() {
  const manifest = { schemaVersion: 1, bundleIdentifier: "com.ahmedelamin.LocalCodex", tag,
    version: "0.1.2-alpha.3", appVersion: "0.1.2", appBuild: "3", architecture: "arm64",
    channel: "signed-test", notarizedAppVerified: false };
  const files = new Map<string, Buffer>();
  let release: any, releasedReads = 0;
  const config = "MARKETING_VERSION = 0.1.2\nCURRENT_PROJECT_VERSION = 3\n";
  const calls: string[][] = [];
  let failure: string | undefined, changed: string | undefined, verified = false;
  function prepare() {
    files.set(`${stem}.dmg`, Buffer.from("synthetic DMG; mounted verification is a separate test"));
    files.set(`${stem}.manifest.json`, Buffer.from(JSON.stringify(manifest)));
    files.set("SHA256SUMS", Buffer.from([...files].filter(([name]) => name !== "SHA256SUMS")
      .map(([name, bytes]) => `${digest(bytes)}  ${name}\n`).join("")));
    release = { id: 123, tag_name: tag, draft: true, prerelease: true, name: tag, body: "Maintainer validation notes.",
      assets: [...files].map(([name, bytes], i) => ({ id: i + 1, name, size: bytes.length, digest: `sha256:${digest(bytes)}`, state: "uploaded" })) };
  }
  prepare();
  const context: PublishContext = {
    log: () => {},
    verifyPackage: async () => { if (failure === "signature") throw new Error("signature rejected"); verified = true; },
    run: async command => {
      calls.push(command);
      if (command[1] === "api") {
        const path = command[2];
        if (path.includes("git/ref/tags")) return JSON.stringify({ object: { type: "commit", sha: changed === "tag" && verified ? "b".repeat(40) : source } });
        if (path === `repos/${repo}`) return JSON.stringify({ default_branch: "main" });
        if (path.includes("compare/")) return JSON.stringify({ status: failure === "unmerged" || (changed === "branch" && verified) ? "diverged" : "ahead" });
        if (path.includes("contents/")) return JSON.stringify({ encoding: "base64", content: Buffer.from(config).toString("base64") });
        if (path.includes("releases/tags")) {
          releasedReads++;
          if (changed === "notes" && releasedReads === 2) release.body += " changed";
          if (changed === "assets" && releasedReads === 2) release.assets[0].id++;
          return JSON.stringify(release);
        }
      }
      if (command[1] === "release" && command[2] === "download") {
        const directory = command[command.indexOf("--dir") + 1]; stages.push(directory);
        for (const [name, bytes] of files) await writeFile(join(directory, name),
          failure === "download" && name.endsWith(".dmg") ? Buffer.from("corrupt") : bytes);
        return "";
      }
      if (command[1] === "release" && command[2] === "edit") {
        expect(verified).toBe(true);
        release.body = await readFile(command[command.indexOf("--notes-file") + 1], "utf8");
        release.draft = false; release.prerelease = true;
        if (failure === "postcondition") release.prerelease = false;
        return "";
      }
      throw new Error(`Unexpected command: ${command.join(" ")}`);
    },
  };
  return { context, calls, manifest, prepare, release: () => release,
    fail: (value: string) => { failure = value; }, change: (value: string) => { changed = value; } };
}

test("publication requires explicit alpha input and repo; defaults to verification only", () => {
  expect(parsePublishOptions(["--tag", tag], repo)).toEqual({ tag, repo, publish: false });
  expect(parsePublishOptions(["--tag", tag, "--publish"], repo).publish).toBe(true);
  for (const args of [["--tag", "v0.1.2"], ["--tag", "v0.1.2-beta.1"], ["--tag", tag, "--publish", "--publish"],
    ["--tag", tag, "--repo", "owner/repo;command"]]) expect(() => parsePublishOptions(args, repo)).toThrow();
});

test("checksum parser rejects traversal, extra files, duplicates and missing manifest", () => {
  const sum = "a".repeat(64), names = ["a.dmg", "a.manifest.json"];
  expect(checksumEntries(`${sum}  a.dmg\n${sum}  a.manifest.json\n`, names).size).toBe(2);
  for (const text of [`${sum}  ../a.dmg`, `${sum}  a.dmg`, `${sum}  a.dmg\n${sum}  a.dmg`,
    `${sum}  a.dmg\n${sum}  a.manifest.json\n${sum}  extra`]) expect(() => checksumEntries(text, names)).toThrow();
});

test("verification alone performs mounted verification and never edits GitHub", async () => {
  const f = fixture(); await publishAlpha({ tag, repo, publish: false }, f.context);
  expect(f.release().draft).toBe(true);
  expect(f.calls.some(call => call.includes("edit"))).toBe(false);
});

test("verified draft publishes as alpha, never latest, with explicit non-notarized notes", async () => {
  const f = fixture(); await publishAlpha({ tag, repo, publish: true }, f.context);
  const edit = f.calls.find(call => call[2] === "edit")!;
  expect(edit).toContain("--draft=false"); expect(edit).toContain("--prerelease"); expect(edit).toContain("--latest=false");
  expect(f.release().body).toContain("**Not notarized:**");
  expect(f.release().body).toContain("Maintainer validation notes.");
});

test("direct non-alpha calls fail before any command", async () => {
  const f = fixture(); await expect(publishAlpha({ tag: "v0.1.2-preview.1", repo, publish: true }, f.context)).rejects.toThrow();
  expect(f.calls).toEqual([]);
});

test("unmerged source and published releases are rejected without downloads or edits", async () => {
  for (const failure of ["unmerged", "published"]) {
    const f = fixture(); if (failure === "unmerged") f.fail(failure); else f.release().draft = false;
    await expect(publishAlpha({ tag, repo, publish: true }, f.context)).rejects.toThrow();
    expect(f.calls.some(call => call.includes("download") || call.includes("edit"))).toBe(false);
  }
});

test("missing GitHub digests and extra assets are rejected before download", async () => {
  for (const failure of ["digest", "extra"]) {
    const f = fixture(); if (failure === "digest") delete f.release().assets[0].digest; else f.release().assets.push({ name: "unexpected" });
    await expect(publishAlpha({ tag, repo, publish: true }, f.context)).rejects.toThrow();
    expect(f.calls.some(call => call.includes("download") || call.includes("edit"))).toBe(false);
  }
});

test("corrupt downloads, mismatched manifest and signature failures prevent publication", async () => {
  for (const failure of ["download", "manifest", "signature"]) {
    const f = fixture(); if (failure === "manifest") { f.manifest.appBuild = "4"; f.prepare(); } else f.fail(failure);
    await expect(publishAlpha({ tag, repo, publish: true }, f.context)).rejects.toThrow();
    expect(f.calls.some(call => call.includes("edit"))).toBe(false);
  }
});

test("tag, notes or asset replacement during verification prevents publication", async () => {
  for (const changed of ["tag", "notes", "assets"]) {
    const f = fixture(); f.change(changed);
    await expect(publishAlpha({ tag, repo, publish: true }, f.context)).rejects.toThrow("changed during verification");
    expect(f.calls.some(call => call.includes("edit"))).toBe(false);
  }
});

test("source removed from the default branch during verification prevents publication", async () => {
  const f = fixture(); f.change("branch");
  await expect(publishAlpha({ tag, repo, publish: true }, f.context)).rejects.toThrow("already be merged");
  expect(f.calls.some(call => call.includes("edit"))).toBe(false);
});

test("ambiguous publication outcome requires inspection rather than a second mutation", async () => {
  const f = fixture(); f.fail("postcondition");
  await expect(publishAlpha({ tag, repo, publish: true }, f.context)).rejects.toThrow("could not be confirmed");
  expect(f.calls.filter(call => call.includes("edit"))).toHaveLength(1);
});

async function installerFixture() {
  const mount = await mkdtemp(join(tmpdir(), "computa-installer-payload-")); stages.push(mount);
  await mkdir(join(mount, "Installer"));
  await symlink("/Applications", join(mount, "Applications"));
  const sources = new Map<string, Uint8Array>();
  for (const path of Object.keys(installerSources)) {
    const bytes = Buffer.from(path.endsWith("uv.lock.json") ? '{"schemaVersion":1,"version":"fixture"}' : `tagged ${path}\n`);
    sources.set(path, bytes); await writeFile(join(mount, path), bytes);
  }
  await chmod(join(mount, "Install Computa.command"), 0o755);
  const manifest = { version: "0.1.2-alpha.3", channel: "signed-test", uvPin: { schemaVersion: 1, version: "fixture" },
    modelManifestSHA256: digest(sources.get("Installer/mlx-model.lock.json")!),
    requirementsSHA256: digest(sources.get("Installer/mlx-runtime-requirements.lock")!) };
  await writeFile(join(mount, "release-manifest.json"), JSON.stringify(manifest));
  await writeFile(join(mount, "READ ME.txt"), "Computa 0.1.2-alpha.3\nChannel: signed-test. Not notarized\n");
  const refresh = async () => {
    const paths = [...sources.keys(), "READ ME.txt", "release-manifest.json"];
    await writeFile(join(mount, "SHA256SUMS"), (await Promise.all(paths.map(async path => `${digest(await readFile(join(mount, path)))}  ${path}\n`))).join(""));
  };
  await refresh(); return { mount, sources, manifest, refresh };
}

test("complete installer payload matches checksums, tagged source, dependency pins and status", async () => {
  const f = await installerFixture(); await verifyInstallerPayload(f.mount, f.manifest, f.sources);
});

test("missing, corrupted and rechecksummed changed installers are rejected", async () => {
  for (const failure of ["missing", "changed", "rechecksummed"]) {
    const f = await installerFixture(), command = join(f.mount, "Install Computa.command");
    if (failure === "missing") await rm(command); else await writeFile(command, "changed installer\n");
    if (failure === "rechecksummed") await f.refresh();
    await expect(verifyInstallerPayload(f.mount, f.manifest, f.sources)).rejects.toThrow();
  }
});

test("installer metadata and guide mismatches are rejected despite valid inner checksums", async () => {
  for (const failure of ["pin", "guide", "mode"]) {
    const f = await installerFixture();
    if (failure === "pin") f.manifest.requirementsSHA256 = "b".repeat(64);
    if (failure === "guide") { await writeFile(join(f.mount, "READ ME.txt"), "wrong version, notarized\n"); await f.refresh(); }
    if (failure === "mode") await chmod(join(f.mount, "Install Computa.command"), 0o644);
    await expect(verifyInstallerPayload(f.mount, f.manifest, f.sources)).rejects.toThrow();
  }
});

test("extra unchecked installer files and directories prevent publication", async () => {
  for (const kind of ["file", "directory"]) {
    const f = await installerFixture(), extra = join(f.mount, "Installer/extra");
    if (kind === "file") await writeFile(extra, "unchecked"); else await mkdir(extra);
    await expect(verifyInstallerPayload(f.mount, f.manifest, f.sources)).rejects.toThrow("exactly the tagged");
  }
});

test("drag-install shortcut must point exactly to Applications", async () => {
  const f = await installerFixture(), shortcut = join(f.mount, "Applications");
  await rm(shortcut); await symlink("/tmp", shortcut);
  await expect(verifyInstallerPayload(f.mount, f.manifest, f.sources)).rejects.toThrow("shortcut");
});
