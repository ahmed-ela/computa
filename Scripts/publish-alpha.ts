#!/usr/bin/env bun
// Verify a prepared draft before publication. Never builds, signs or installs.
import { lstat, mkdtemp, readFile, readdir, readlink, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { bundleID, inspectApp, sha256, type Context as PackageContext } from "./package-release";
import { tagMetadata } from "./release-policy";
import { parseVersionConfig } from "./version";

export interface PublishOptions { tag: string; repo: string; publish: boolean }
export interface PublishContext {
  run(command: string[]): Promise<string>;
  verifyPackage(dmg: string, manifest: any, manifestBytes: Uint8Array, installerFiles: Map<string, Uint8Array>): Promise<void>;
  log(message: string): void;
}
const help = "Usage: bun Scripts/publish-alpha.ts --tag vVERSION-alpha.N [--repo OWNER/REPO] [--publish]\nWithout --publish, downloads and verifies the draft without changing GitHub.";
export const installerSources: Record<string, string> = {
  "Install Computa.command": "Scripts/distribution/Install Computa.command",
  "Installer/install-release.py": "Scripts/distribution/install-release.py",
  "Installer/uv.lock.json": "Scripts/distribution/uv.lock.json",
  "Installer/install-mlx-runtime.sh": "Scripts/install-mlx-runtime.sh",
  "Installer/mlx-runtime-install.py": "Scripts/mlx-runtime-install.py",
  "Installer/mlx-runtime-requirements.lock": "Scripts/mlx-runtime-requirements.lock",
  "Installer/mlx-model.lock.json": "Scripts/mlx-model.lock.json",
};

export function parsePublishOptions(args: string[], repo = process.env.GH_REPO ?? ""): PublishOptions {
  let tag = "", publish = false;
  const seen = new Set<string>();
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (!["--tag", "--repo", "--publish"].includes(key) || seen.has(key)) throw new Error(help);
    seen.add(key);
    if (key === "--publish") { publish = true; continue; }
    const value = args[++i];
    if (!value || value.startsWith("-") || /[\x00-\x20\x7f]/.test(value)) throw new Error(help);
    if (key === "--tag") tag = value; else repo = value;
  }
  const metadata = tagMetadata(tag);
  if (!metadata.prerelease) throw new Error("Automatic publication is only enabled for alpha releases");
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) throw new Error("Set GH_REPO or --repo to OWNER/REPO");
  return { tag, repo, publish };
}

function assetsSnapshot(release: any): string {
  if (!Array.isArray(release.assets)) throw new Error("Release assets are missing");
  return JSON.stringify(release.assets.map((asset: any) => ({
    id: asset.id, name: asset.name, size: asset.size, digest: asset.digest, state: asset.state,
  })).sort((a: any, b: any) => String(a.name).localeCompare(String(b.name))));
}
function draftSnapshot(release: any): string {
  return JSON.stringify({ id: release.id, tag: release.tag_name, draft: release.draft,
    prerelease: release.prerelease, name: release.name, body: release.body, assets: assetsSnapshot(release) });
}

export function checksumEntries(text: string, expected: string[]): Map<string, string> {
  const entries = new Map<string, string>();
  for (const line of text.trimEnd().split("\n")) {
    const match = /^([a-f0-9]{64})  ([^\r\n]+)$/.exec(line);
    if (!match || !expected.includes(match[2]) || entries.has(match[2])) throw new Error("Unexpected or duplicate SHA256SUMS entry");
    entries.set(match[2], match[1]);
  }
  if (entries.size !== expected.length) throw new Error("SHA256SUMS must cover exactly the expected files");
  return entries;
}

export async function publishAlpha(options: PublishOptions, context: PublishContext): Promise<void> {
  // Check direct callers as well as CLI input before any command or filesystem effect.
  const { tag, repo, publish } = parsePublishOptions(["--tag", options.tag, "--repo", options.repo,
    ...(options.publish ? ["--publish"] : [])]);
  const metadata = tagMetadata(tag), apiRoot = `repos/${repo}`;
  const api = async (path: string) => JSON.parse(await context.run(["gh", "api", `${apiRoot}/${path}`]));
  const resolveTag = async (): Promise<string> => {
    let object = (await api(`git/ref/tags/${encodeURIComponent(tag)}`)).object;
    for (let depth = 0; object?.type === "tag" && depth < 8; depth++) object = (await api(`git/tags/${object.sha}`)).object;
    if (object?.type !== "commit" || !/^[a-f0-9]{40}$/.test(object.sha)) throw new Error("Tag must resolve to one immutable source commit");
    return object.sha;
  };
  const source = await resolveTag();
  const ensureMerged = async () => {
    const repository = JSON.parse(await context.run(["gh", "api", apiRoot]));
    if (typeof repository.default_branch !== "string" || !repository.default_branch) throw new Error("Repository default branch is missing");
    const comparison = await api(`compare/${source}...${encodeURIComponent(repository.default_branch)}`);
    if (!["ahead", "identical"].includes(comparison.status)) throw new Error("Release source must already be merged into the default branch");
  };
  await ensureMerged();
  const configFile = await api(`contents/Config/Version.xcconfig?ref=${source}`);
  if (configFile.encoding !== "base64" || typeof configFile.content !== "string") throw new Error("Tagged app version config is missing");
  const config = parseVersionConfig(Buffer.from(configFile.content, "base64").toString("utf8"));
  if (metadata.appVersion !== config.version || tag !== `v${config.version}-alpha.${config.build}`) {
    throw new Error("Alpha tag must use the tagged app version and increasing Apple build number");
  }
  const releasePath = `releases/tags/${encodeURIComponent(tag)}`;
  const release = await api(releasePath);
  if (release.draft !== true || release.tag_name !== tag) throw new Error("Select an existing unpublished draft; published releases are immutable");
  const stem = `Computa-${metadata.version}-arm64`;
  const dmgNames = [`${stem}.dmg`, `${stem}-signed-test.dmg`];
  const manifestNames = dmgNames.map(name => name.replace(/\.dmg$/, ".manifest.json"));
  const dmgAssets = release.assets?.filter((asset: any) => dmgNames.includes(asset.name)) ?? [];
  if (dmgAssets.length !== 1) throw new Error("Draft must contain exactly one expected Computa DMG");
  const dmgName = dmgAssets[0].name as string;
  const manifestName = dmgName.replace(/\.dmg$/, ".manifest.json");
  const expected = [dmgName, manifestName, "SHA256SUMS"];
  if (!manifestNames.includes(manifestName) || release.assets.length !== expected.length
    || new Set(release.assets.map((asset: any) => asset.name)).size !== expected.length
    || release.assets.some((asset: any) => !expected.includes(asset.name) || asset.state !== "uploaded"
      || !Number.isSafeInteger(asset.id) || !Number.isSafeInteger(asset.size) || asset.size <= 0
      || !/^sha256:[a-f0-9]{64}$/.test(asset.digest))) {
    throw new Error("Draft needs exactly the final DMG, manifest and SHA256SUMS with GitHub SHA-256 digests");
  }
  const snapshot = draftSnapshot(release);
  const installerFiles = new Map<string, Uint8Array>();
  for (const [destination, path] of Object.entries(installerSources)) {
    const content = await api(`contents/${encodeURI(path)}?ref=${source}`);
    if (content.encoding !== "base64" || typeof content.content !== "string") throw new Error(`Tagged installer file is missing: ${path}`);
    installerFiles.set(destination, Buffer.from(content.content, "base64"));
  }
  const stage = await realpath(await mkdtemp(join(tmpdir(), "computa-alpha-")));
  try {
    await context.run(["gh", "release", "download", tag, "--repo", repo, "--dir", stage,
      ...expected.flatMap(name => ["--pattern", name])]);
    for (const asset of release.assets) {
      const path = join(stage, asset.name);
      const bytes = await readFile(path);
      if (bytes.length !== asset.size || `sha256:${await sha256(path)}` !== asset.digest) throw new Error(`GitHub digest mismatch: ${asset.name}`);
    }
    const sums = checksumEntries(await readFile(join(stage, "SHA256SUMS"), "utf8"), [dmgName, manifestName]);
    for (const [name, digest] of sums) if (await sha256(join(stage, name)) !== digest) throw new Error(`SHA256SUMS mismatch: ${name}`);
    const manifestBytes = await readFile(join(stage, manifestName));
    const manifest = JSON.parse(manifestBytes.toString("utf8"));
    const channel = dmgName.endsWith("-signed-test.dmg") ? "signed-test" : "notarized";
    if (manifest.schemaVersion !== 1 || manifest.bundleIdentifier !== bundleID || manifest.tag !== tag
      || manifest.version !== metadata.version || manifest.appVersion !== config.version || manifest.appBuild !== config.build
      || manifest.architecture !== "arm64" || manifest.channel !== channel
      || manifest.notarizedAppVerified !== (channel === "notarized")) {
      throw new Error("Draft manifest differs from its tag, source app version/build or signing channel");
    }
    await context.verifyPackage(join(stage, dmgName), manifest, manifestBytes, installerFiles);
    await ensureMerged();
    if (await resolveTag() !== source || draftSnapshot(await api(releasePath)) !== snapshot) {
      throw new Error("Release tag, notes or assets changed during verification; nothing was published");
    }
    context.log(`Verified ${tag}: app ${config.version} (${config.build}), ${channel}, tagged source ${source}.`);
    if (!publish) { context.log("Draft remains unpublished. Pass --publish to publish the verified alpha."); return; }
    const notes = `${release.body ?? ""}\n\n### Automated package verification\n\n`
      + `Alpha testing release. Tagged source: ${source}. App: ${config.version} (${config.build}).\n`
      + "GitHub digests, SHA256SUMS, mounted app inventory, tagged installer files, version/build and Developer ID signatures passed.\n"
      + (channel === "signed-test" ? "**Not notarized:** this signed test build may be blocked by macOS.\n"
        : "The app notarization ticket and Gatekeeper assessment passed. DMG notarization is separate.\n")
      + "Compiled app source identity, clean-Mac installation and live model/task qualification remain maintainer checks; see the release notes above.\n";
    const notesPath = join(stage, "verified-notes.md");
    await writeFile(notesPath, notes, { flag: "wx" });
    await context.run(["gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--prerelease", "--latest=false", "--notes-file", notesPath]);
    const published = await api(releasePath);
    if (published.draft !== false || published.prerelease !== true || published.tag_name !== tag
      || assetsSnapshot(published) !== assetsSnapshot(release) || published.body !== notes) {
      throw new Error("Publication outcome could not be confirmed; inspect GitHub before retrying");
    }
    context.log(`Published ${tag} as an alpha prerelease with latest=false.`);
  } finally { await rm(stage, { recursive: true, force: true }); }
}

export async function verifyInstallerPayload(mount: string, manifest: any, installerFiles: Map<string, Uint8Array>): Promise<void> {
  const installer = await lstat(join(mount, "Installer"));
  if (!installer.isDirectory() || installer.isSymbolicLink()) throw new Error("Installer payload must be a regular directory");
  const installerNames = Object.keys(installerSources).filter(path => path.startsWith("Installer/")).map(path => path.slice("Installer/".length)).sort();
  if (JSON.stringify((await readdir(join(mount, "Installer"))).sort()) !== JSON.stringify(installerNames)) {
    throw new Error("Installer payload must contain exactly the tagged installer files");
  }
  const applications = join(mount, "Applications");
  if (!(await lstat(applications)).isSymbolicLink() || await readlink(applications) !== "/Applications") {
    throw new Error("Applications shortcut must point exactly to /Applications");
  }
  const expected = [...Object.keys(installerSources), "READ ME.txt", "release-manifest.json"];
  const sumsFile = await lstat(join(mount, "SHA256SUMS"));
  if (!sumsFile.isFile() || sumsFile.isSymbolicLink()) throw new Error("Mounted checksums must be a regular file");
  const sums = checksumEntries(await readFile(join(mount, "SHA256SUMS"), "utf8"), expected);
  for (const path of expected) {
    const full = join(mount, path), info = await lstat(full);
    if (!info.isFile() || info.isSymbolicLink() || await sha256(full) !== sums.get(path)) throw new Error(`Mounted payload checksum mismatch: ${path}`);
    if (path === "Install Computa.command" && !(info.mode & 0o111)) throw new Error("Installation entrypoint is not executable");
    const source = installerFiles.get(path);
    if (path in installerSources && (!source || !Buffer.from(source).equals(await readFile(full)))) throw new Error(`Installer differs from tagged source: ${path}`);
  }
  if (await sha256(join(mount, "Installer/mlx-model.lock.json")) !== manifest.modelManifestSHA256
    || await sha256(join(mount, "Installer/mlx-runtime-requirements.lock")) !== manifest.requirementsSHA256
    || JSON.stringify(JSON.parse(await readFile(join(mount, "Installer/uv.lock.json"), "utf8"))) !== JSON.stringify(manifest.uvPin)) {
    throw new Error("Installer dependency pins differ from release metadata");
  }
  const guide = await readFile(join(mount, "READ ME.txt"), "utf8");
  if (!guide.includes(`Computa ${manifest.version}`) || !guide.includes(`Channel: ${manifest.channel}.`)
    || (manifest.channel === "signed-test" && !guide.includes("Not notarized"))) throw new Error("Mounted guide has incorrect release or notarization status");
}

export async function verifyMountedPackage(dmg: string, manifest: any, manifestBytes: Uint8Array,
  context: PackageContext, installerFiles: Map<string, Uint8Array>): Promise<void> {
  const checked = async (command: string[]) => {
    const result = await context.run(command);
    if (result.code !== 0) throw new Error(`Package verification failed: ${command[0]}`);
    return result.stdout;
  };
  await checked(["/usr/bin/hdiutil", "verify", dmg]);
  // A private explicit mount point guarantees cleanup even if attach output is malformed.
  const mount = await realpath(await mkdtemp(join(tmpdir(), "computa-alpha-mount-")));
  let attached = false;
  try {
    await checked(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg]);
    attached = true;
    const sealed = await readFile(join(mount, "release-manifest.json"));
    if (!sealed.equals(Buffer.from(manifestBytes))) throw new Error("Mounted and external release manifests differ");
    await verifyInstallerPayload(mount, manifest, installerFiles);
    const inspected = await inspectApp(context, join(mount, "Computa.app"), manifest.channel);
    if (inspected.version !== manifest.appVersion || inspected.build !== manifest.appBuild
      || inspected.minimumMacOS !== manifest.minimumMacOS
      || JSON.stringify(inspected.files) !== JSON.stringify(manifest.appFiles)) {
      throw new Error("Mounted app differs from its release manifest");
    }
  } finally {
    // Try detach after any attach attempt; do not delete a potentially mounted filesystem.
    const detached = await context.run(["/usr/bin/hdiutil", "detach", mount]);
    if (detached.code === 0) await rm(mount, { recursive: true, force: true });
    else if (attached) throw new Error("Release image could not be detached; publication stopped");
    else await rm(mount).catch(() => {});
  }
}

if (import.meta.main) {
  if (process.argv.slice(2).length === 1 && process.argv[2] === "--help") { console.log(help); process.exit(0); }
  try {
    if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("Alpha package verification requires Apple Silicon macOS");
    const options = parsePublishOptions(process.argv.slice(2));
    const run: PackageContext["run"] = async command => {
      const child = Bun.spawn(command, { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
      return { stdout: await new Response(child.stdout).text(), code: await child.exited };
    };
    await publishAlpha(options, {
      run: async command => { const result = await run(command); if (result.code !== 0) throw new Error(`Command failed: ${command[0]}`); return result.stdout; },
      verifyPackage: (dmg, manifest, bytes, installerFiles) => verifyMountedPackage(dmg, manifest, bytes,
        { root: resolve(import.meta.dir, ".."), platform: process.platform, architecture: process.arch, run, log: console.log }, installerFiles),
      log: console.log,
    });
  } catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; }
}
