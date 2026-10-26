#!/usr/bin/env bun
// Package an already signed app. This never builds, signs, installs or launches it.
import { createHash } from "node:crypto";
import { rejectRetiredBundleResources } from "./retired-bundle-resources";
import { createReadStream } from "node:fs";
import { chmod, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, readlink, realpath, rename, symlink, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { isAppVersion, isBuildNumber } from "./version";
import { tagMetadata } from "./release-policy";

export const bundleID = "com.ahmedelamin.LocalCodex";
const help = `Package a prebuilt, signed Apple Silicon Computa app without modifying it.
Usage: bun Scripts/package-release.ts --app PATH --output DIRECTORY --tag vVERSION
       [--channel notarized|signed-test]

Default channel is notarized: requires stapled app notarization and Gatekeeper
acceptance. signed-test is explicitly non-notarized and may be blocked on another
Mac. Neither mode signs, strips quarantine, builds, installs, or publishes.
Produces a DMG, release manifest and SHA256SUMS. Existing artifacts are never overwritten.`;

export interface Options { app?: string; output?: string; tag?: string; version?: string; channel: "notarized" | "signed-test"; help: boolean }
export interface Context {
  root: string;
  platform: string;
  architecture: string;
  run(command: string[]): Promise<{ code: number; stdout: string }>;
  log(message: string): void;
}
export type FileEntry = { path: string; kind: "file"; sha256: string; size: number; executable: boolean }
  | { path: string; kind: "symlink"; target: string };

export function parseOptions(args: string[]): Options {
  const result: Options = { channel: "notarized", help: false };
  const seen = new Set<string>();
  for (let index = 0; index < args.length; index++) {
    const key = args[index];
    if (!["--app", "--output", "--tag", "--version", "--channel", "--help"].includes(key) || seen.has(key)) throw new Error(`Unknown or duplicate option: ${key}`);
    seen.add(key);
    if (key === "--help") { result.help = true; continue; }
    const value = args[++index];
    if (!value || value.startsWith("-") || /[\x00-\x1f\x7f]/.test(value)) throw new Error(`Invalid value for ${key}`);
    if (key === "--channel") {
      if (value !== "notarized" && value !== "signed-test") throw new Error("Channel must be notarized or signed-test");
      result.channel = value;
    } else if (key === "--tag" || key === "--version") {
      tagMetadata(key === "--tag" ? value : `v${value}`);
      result[key === "--tag" ? "tag" : "version"] = value;
    } else result[key === "--app" ? "app" : "output"] = resolve(value);
  }
  if (!result.help && (!result.app || !result.output || !result.tag)) throw new Error(help);
  if (result.version && result.tag !== `v${result.version}`) throw new Error("--version must match --tag without its v prefix");
  return result;
}

async function exists(path: string) {
  try { await lstat(path); return true; }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }
}

async function safeDirectory(path: string, mayCreate = false) {
  const absolute = resolve(path);
  if (absolute === sep) throw new Error("Refusing filesystem root as a packaging directory");
  for (let current = absolute; current !== dirname(current); current = dirname(current)) {
    if (await exists(current)) {
      const info = await lstat(current);
      if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`Unsafe packaging directory: ${current}`);
    }
  }
  if (mayCreate) await mkdir(absolute, { recursive: true });
  else if (!await exists(absolute)) throw new Error(`Missing directory: ${absolute}`);
}

async function checked(context: Context, command: string[]) {
  const result = await context.run(command);
  if (result.code !== 0) throw new Error(`Command failed (${result.code}): ${command.join(" ")}`);
  return result.stdout.trim();
}

export async function sha256(path: string) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export async function bundleFiles(app: string): Promise<FileEntry[]> {
  await safeDirectory(app);
  const root = await realpath(app);
  const entries: FileEntry[] = [];
  async function visit(directory: string) {
    for (const name of await readdir(directory)) {
      const path = join(directory, name);
      const local = relative(app, path).split(sep).join("/");
      if (/[\x00-\x1f\x7f]/.test(local)) throw new Error("Control characters in bundle paths are unsupported");
      const info = await lstat(path);
      if (info.isSymbolicLink()) {
        const target = await readlink(path);
        const resolved = await realpath(path);
        if (!resolved.startsWith(root + sep)) throw new Error("App symlink points outside its bundle");
        entries.push({ path: local, kind: "symlink", target });
      } else if (info.isDirectory()) await visit(path);
      else if (info.isFile()) entries.push({ path: local, kind: "file", sha256: await sha256(path), size: info.size, executable: Boolean(info.mode & 0o111) });
      else throw new Error("App contains a special filesystem entry");
    }
  }
  await visit(app);
  return entries.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
}

export async function inspectApp(context: Context, app: string, channel: Options["channel"]) {
  const files = await bundleFiles(app);
  await rejectRetiredBundleResources(app);
  const regular = new Set(files.filter(item => item.kind === "file").map(item => item.path));
  for (const path of ["Contents/Info.plist", "Contents/MacOS/Computa", "Contents/Resources/AgentRuntime/codex-app-server",
    "Contents/Resources/AgentRuntime/manifest.json",
    "Contents/Resources/MLXServer/server.py", "Contents/Resources/WebUI/index.html"]) {
    if (!regular.has(path)) throw new Error(`Required release file is missing or nonregular: ${path}`);
  }
  const info = JSON.parse(await checked(context, ["/usr/bin/plutil", "-convert", "json", "-o", "-", join(app, "Contents/Info.plist")]));
  if (info.CFBundleIdentifier !== bundleID || info.CFBundleExecutable !== "Computa") throw new Error("Unexpected app identity");
  const version = info.CFBundleShortVersionString;
  if (!isAppVersion(version)) throw new Error("App version must be numeric major.minor.patch");
  const build = info.CFBundleVersion;
  if (!isBuildNumber(build)) throw new Error("App build must be an integer from 1 through 9999");
  const minimumMacOS = info.LSMinimumSystemVersion;
  if (typeof minimumMacOS !== "string" || !/^\d+\.\d+(?:\.\d+)?$/.test(minimumMacOS) || Number(minimumMacOS.split(".")[0]) < 14) {
    throw new Error("The release must declare macOS 14 or later");
  }
  const runtimePath = join(app, "Contents/Resources/AgentRuntime");
  const runtime = JSON.parse(await readFile(join(runtimePath, "manifest.json"), "utf8"));
  const binary = files.find(item => item.path === "Contents/Resources/AgentRuntime/codex-app-server")!;
  if (runtime.schemaVersion !== 1 || runtime.platform !== "macos" || runtime.architecture !== "arm64"
    || runtime.executable !== "codex-app-server" || binary.kind !== "file" || runtime.binarySHA256 !== binary.sha256 || runtime.binarySize !== binary.size) {
    throw new Error("Agent runtime signature/hash differs from its sealed manifest");
  }
  for (const binaryPath of [join(app, "Contents/MacOS/Computa"), join(runtimePath, "codex-app-server")]) {
    const architectures = (await checked(context, ["/usr/bin/lipo", "-archs", binaryPath])).split(/\s+/);
    if (!architectures.includes("arm64")) throw new Error("All release executables must include arm64");
    // The app may be universal, while the packaged MLX/runtime target is
    // arm64. A single slice also avoids treating a later slice header as a path.
    const libraries = await checked(context, ["/usr/bin/otool", "-arch", "arm64", "-L", binaryPath]);
    for (const line of libraries.split("\n").slice(1).filter(value => value.trim())) {
      const dependency = line.trim().split(" (", 1)[0];
      if (!dependency.startsWith("/System/Library/") && !dependency.startsWith("/usr/lib/")) {
        throw new Error(`Unreviewed non-system dynamic dependency: ${dependency}`);
      }
    }
    await checked(context, ["/usr/bin/codesign", "--verify", "--strict", "-R",
      '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists', binaryPath]);
  }
  await checked(context, ["/usr/bin/codesign", "--verify", "--deep", "--strict", app]);
  if (channel === "notarized") {
    await checked(context, ["/usr/bin/xcrun", "stapler", "validate", app]);
    await checked(context, ["/usr/sbin/spctl", "--assess", "--type", "execute", app]);
  }
  return { version, build, minimumMacOS, files, runtime };
}

export async function packageRelease(options: Options, context: Context) {
  if (options.help) { context.log(help); return; }
  if (context.platform !== "darwin" || context.architecture !== "arm64") throw new Error("Packaging requires Apple Silicon macOS");
  const release = tagMetadata(options.tag!);
  if (options.version !== undefined && options.version !== release.version) throw new Error("--version must match --tag without its v prefix");
  const app = options.app!, output = options.output!;
  if (output === app || output.startsWith(app + sep) || app.startsWith(output + sep)) throw new Error("App and output directories must be separate");
  const inspected = await inspectApp(context, app, options.channel);
  const releaseVersion = release.version;
  if (release.appVersion !== inspected.version) throw new Error("Release tag base must match the signed app version");
  await safeDirectory(output, true);
  const stem = `Computa-${releaseVersion}-arm64${options.channel === "signed-test" ? "-signed-test" : ""}`;
  for (const name of [`${stem}.dmg`, `${stem}.manifest.json`, "SHA256SUMS"]) {
    if (await exists(join(output, name))) throw new Error(`Output already exists; select an empty release directory: ${name}`);
  }
  const stage = await mkdtemp(join(output, ".computa-release-"));
  const payload = join(stage, "payload");
  await mkdir(join(payload, "Installer"), { recursive: true });
  await checked(context, ["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", app, join(payload, "Computa.app")]);
  const copied = await inspectApp(context, join(payload, "Computa.app"), options.channel);
  if (JSON.stringify(copied.files) !== JSON.stringify(inspected.files)) throw new Error("Staging changed the signed application");
  await symlink("/Applications", join(payload, "Applications"));
  const resources = ["install-mlx-runtime.sh", "mlx-runtime-install.py", "mlx-runtime-requirements.lock", "mlx-model.lock.json"];
  for (const name of resources) await copyFile(join(context.root, "Scripts", name), join(payload, "Installer", name));
  for (const name of ["install-release.py", "uv.lock.json"]) await copyFile(join(context.root, "Scripts/distribution", name), join(payload, "Installer", name));
  await copyFile(join(context.root, "Scripts/distribution/Install Computa.command"), join(payload, "Install Computa.command"));
  await chmod(join(payload, "Install Computa.command"), 0o755);
  const manifest = {
    schemaVersion: 1, bundleIdentifier: bundleID, version: releaseVersion, tag: options.tag,
    appVersion: inspected.version, appBuild: inspected.build, architecture: "arm64",
    minimumMacOS: inspected.minimumMacOS, channel: options.channel,
    notarizedAppVerified: options.channel === "notarized", modelIncluded: false,
    modelManifestSHA256: await sha256(join(payload, "Installer/mlx-model.lock.json")),
    requirementsSHA256: await sha256(join(payload, "Installer/mlx-runtime-requirements.lock")),
    uvPin: JSON.parse(await readFile(join(payload, "Installer/uv.lock.json"), "utf8")), appFiles: inspected.files,
  };
  const manifestText = JSON.stringify(manifest, null, 2) + "\n";
  await writeFile(join(payload, "release-manifest.json"), manifestText, { flag: "wx" });
  const guide = `Computa ${releaseVersion} — Apple Silicon, macOS ${inspected.minimumMacOS}+\n\n`
    + `Clean Mac: open Install Computa.command and confirm INSTALL. It installs into ~/Applications, downloads private Python/MLX and pinned Qwen 4B (~3.06 GB), then opens the app. Allow about 10 GB free space. No Xcode, Homebrew, Git, Bun or preinstalled Python required.\n\n`
    + `Already configured: drag Computa.app to Applications, or use the installer for a backed-up update in ~/Applications. Quit Computa and legacy Mactopus first. The installer upgrades a lone Mactopus.app and preserves its old name in the backup; if both names exist, it stops without replacing either. Use the intended app path if both installation locations exist.\n\n`
    + `Channel: ${options.channel}. ${options.channel === "signed-test" ? "Not notarized: macOS may block this test build. Obtain a notarized release for normal distribution." : "The packaged app has a validated notarization ticket; assess/notarize the DMG separately before publishing."}\n`
    + `macOS permissions are separate user actions. No quarantine removal or security bypass is performed. Failed runtime downloads can be retried; prior app backups and model download caches are retained.\n`;
  await writeFile(join(payload, "READ ME.txt"), guide, { flag: "wx" });
  const checksummed = ["Install Computa.command", "READ ME.txt", "release-manifest.json",
    ...resources.map(name => `Installer/${name}`), "Installer/install-release.py", "Installer/uv.lock.json"].sort();
  await writeFile(join(payload, "SHA256SUMS"), (await Promise.all(checksummed.map(async name => `${await sha256(join(payload, name))}  ${name}\n`))).join(""), { flag: "wx" });
  const stagedDMG = join(stage, `${stem}.dmg`);
  await checked(context, ["/usr/bin/hdiutil", "create", "-volname", `Computa ${releaseVersion}`, "-srcfolder", payload,
    "-fs", "HFS+", "-format", "UDZO", stagedDMG]);
  await checked(context, ["/usr/bin/hdiutil", "verify", stagedDMG]);
  const imageHash = await sha256(stagedDMG);
  await rename(stagedDMG, join(output, `${stem}.dmg`));
  await writeFile(join(output, `${stem}.manifest.json`), manifestText, { flag: "wx" });
  await writeFile(join(output, "SHA256SUMS"), `${imageHash}  ${stem}.dmg\n${await sha256(join(output, `${stem}.manifest.json`))}  ${stem}.manifest.json\n`, { flag: "wx" });
  context.log(`Packaged ${join(output, `${stem}.dmg`)}. No signing, installation, launch or publication performed.`);
  context.log(`Staging retained at ${stage}. DMG bytes include filesystem metadata; only the payload manifest is deterministic for identical signed input.`);
  return { dmg: join(output, `${stem}.dmg`), manifest: join(output, `${stem}.manifest.json`), stage };
}

if (import.meta.main) {
  const context: Context = {
    root: resolve(import.meta.dir, ".."), platform: process.platform, architecture: process.arch, log: console.log,
    run: async command => {
      const child = Bun.spawn(command, { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
      return { stdout: await new Response(child.stdout).text(), code: await child.exited };
    },
  };
  try { await packageRelease(parseOptions(process.argv.slice(2)), context); }
  catch (error) { console.error(`Computa packaging: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1; }
}
