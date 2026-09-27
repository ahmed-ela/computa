#!/usr/bin/env bun
// Source installer. Kept separate from the app's runtime and never run by a model.
import { lstat, mkdir, mkdtemp, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const bundleID = "com.ahmedelamin.LocalCodex";
const help = `Build Mactopus from this checked-out source tree (Apple Silicon macOS only).

Usage: ./Scripts/setup.sh [--check | --build-only] [--no-launch] [--download-model]
                         [--signing-identity CERTIFICATE]

  --check           Read-only prerequisite check; no builds, installs, or downloads.
  --build-only      Build and sign .build/SourceInstall/Build/Products/Release/Mactopus.app.
                    Do not install Python, models, or the app, and do not launch it.
  --no-launch       Install without opening the app.
  --download-model  Explicitly download the pinned Qwen 3.5 4B 4-bit model (~3 GB).
  --signing-identity Use your installed Apple code-signing certificate (exact name
                    or SHA-1). Required for the optional Chrome extension bridge.
  --help            Show this help.

Default: build, prepare the private MLX Python environment, install into
~/Applications/Mactopus.app, and open it. No model weights are downloaded unless
--download-model is supplied. Existing apps are backed up; quit Mactopus first.
Default signing is ad-hoc: chat/native AX work, but Chrome extension pairing is
unavailable. No macOS/Chrome permissions are auto-granted. See docs/BUILDING.md.`;

export interface Options {
  check: boolean;
  buildOnly: boolean;
  noLaunch: boolean;
  downloadModel: boolean;
  help: boolean;
  signingIdentity?: string;
}

export function parseOptions(args: string[]): Options {
  const known = new Set(["--check", "--build-only", "--no-launch", "--download-model", "--help", "--signing-identity"]);
  const flags = new Set<string>();
  let signingIdentity: string | undefined;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (!known.has(arg)) throw new Error(`Unknown option: ${arg}\n${help}`);
    if (flags.has(arg)) throw new Error("Duplicate options are not allowed.");
    flags.add(arg);
    if (arg === "--signing-identity") {
      signingIdentity = args[++index];
      if (!signingIdentity || signingIdentity.startsWith("-") || signingIdentity.length > 512 || /[\x00-\x1f\x7f]/.test(signingIdentity)) {
        throw new Error("--signing-identity requires an exact installed certificate name or SHA-1, not a command or option.");
      }
    }
  }
  const options = {
    check: flags.has("--check"), buildOnly: flags.has("--build-only"),
    noLaunch: flags.has("--no-launch"), downloadModel: flags.has("--download-model"),
    help: flags.has("--help"), ...(signingIdentity ? { signingIdentity } : {}),
  };
  if (options.check && [...flags].some(flag => !["--check", "--signing-identity"].includes(flag))) {
    throw new Error("--check is read-only; only --signing-identity can accompany it.");
  }
  if (options.buildOnly && options.downloadModel) {
    throw new Error("--build-only cannot install a model. Use --download-model during installation.");
  }
  return options;
}

export interface CommandResult { code: number; stdout: string }
export interface SetupContext {
  root: string;
  userHome: string;
  platform: string;
  architecture: string;
  which(name: string): string | null;
  run(command: string[], cwd: string, capture?: boolean): Promise<CommandResult>;
  log(message: string): void;
  // Injectable only through the module API for deterministic rollback tests.
  move(source: string, destination: string): Promise<void>;
}

function versionAtLeast(actual: string, minimum: number[]): boolean {
  const parts = actual.match(/\d+(?:\.\d+)+/)?.[0].split(".").map(Number);
  if (!parts) return false;
  for (let i = 0; i < minimum.length; i++) {
    if ((parts[i] ?? 0) !== minimum[i]) return (parts[i] ?? 0) > minimum[i];
  }
  return true;
}

async function checked(context: SetupContext, command: string[], capture = false): Promise<string> {
  const result = await context.run(command, context.root, capture);
  if (result.code !== 0) throw new Error(`Command failed (${result.code}): ${command.join(" ")}`);
  return result.stdout.trim();
}

async function exists(path: string): Promise<boolean> {
  try { await lstat(path); return true; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

async function requireRegular(path: string): Promise<void> {
  const item = await lstat(path).catch(error => {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new Error(`Required source/build file is missing: ${path}`);
    throw error;
  });
  if (!item.isFile() || item.isSymbolicLink()) throw new Error(`Expected a regular file: ${path}`);
}

async function requireSafeDirectory(path: string): Promise<void> {
  const item = await lstat(path);
  if (!item.isDirectory() || item.isSymbolicLink()) throw new Error(`Refusing a non-directory or symlink: ${path}`);
}

export async function checkPrerequisites(context: SetupContext): Promise<void> {
  if (context.platform !== "darwin" || context.architecture !== "arm64") {
    throw new Error("Mactopus currently builds only on Apple Silicon macOS (arm64). Intel and Linux are not supported.");
  }
  const missing = ["bun", "git", "xcodegen", "xcodebuild", "xcrun", "rustup", "cargo", "uv"]
    .filter(name => !context.which(name));
  if (missing.length) throw new Error(`Missing prerequisites: ${missing.join(", ")}. See docs/BUILDING.md; nothing was installed.`);
  const os = await checked(context, ["/usr/bin/sw_vers", "-productVersion"], true);
  if (!versionAtLeast(os, [14, 0])) throw new Error(`macOS 14 or later is required (found ${os}).`);
  const selected = await checked(context, ["/usr/bin/xcode-select", "-p"], true);
  if (!selected.endsWith(".app/Contents/Developer")) {
    throw new Error("Select a full Xcode installation first; Command Line Tools alone cannot build this app.");
  }
  const swift = await checked(context, ["xcrun", "swift", "--version"], true);
  if (!versionAtLeast(swift, [6, 2])) throw new Error("Swift 6.2 or later is required. Select a compatible full Xcode installation.");
  const bun = await checked(context, ["bun", "--version"], true);
  if (!versionAtLeast(bun, [1, 3, 5])) throw new Error("Bun 1.3.5 or later is required for the frozen WebUI lockfile.");
  // rustup run fails if this exact toolchain is absent; unlike an install command,
  // it does not consent to downloading toolchains on the user's behalf.
  const rust = await checked(context, ["rustup", "run", "1.95.0", "rustc", "--version"], true);
  if (!/^rustc 1\.95\.0(?:\s|$)/.test(rust)) throw new Error("Install the pinned Rust 1.95.0 toolchain first.");
  await checked(context, ["xcodebuild", "-version"], true);
  await checked(context, ["xcodegen", "--version"], true);
  await checked(context, ["uv", "--version"], true);
  for (const relative of ["project.yml", "WebUI/bun.lock", "Runtime/codex-source.lock.json",
    "Runtime/patches/compaction-retention.patch", "Scripts/build-agent-runtime.ts", "Scripts/install-mlx-runtime.sh",
    "Scripts/mlx-runtime-install.py", "Scripts/mlx-runtime-requirements.lock", "Scripts/mlx-model.lock.json"]) {
    await requireRegular(join(context.root, relative));
  }
  context.log("Prerequisites passed. Allow substantial Cargo build time and roughly 35–50 GB free build/cache space.");
}

async function inspectApp(context: SetupContext, app: string): Promise<void> {
  await requireSafeDirectory(app);
  const plist = join(app, "Contents/Info.plist");
  await requireRegular(plist);
  const identifier = await checked(context, ["/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist], true);
  const executable = await checked(context, ["/usr/bin/plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", plist], true);
  if (identifier !== bundleID || executable !== "Mactopus") {
    throw new Error(`Refusing to replace or use an unknown app at ${app}. Expected Mactopus (${bundleID}).`);
  }
  await requireRegular(join(app, "Contents/MacOS/Mactopus"));
  await checked(context, ["/usr/bin/codesign", "--verify", "--deep", "--strict", app], true);
}

async function requireStopped(context: SetupContext): Promise<void> {
  const process = await context.run(["/usr/bin/pgrep", "-x", "Mactopus"], context.root, true);
  if (process.code === 0) throw new Error("Mactopus is running. Quit it normally, then rerun setup. No app was replaced or stopped.");
  if (process.code !== 1) throw new Error("Could not determine whether Mactopus is running; refusing to replace the app.");
}

async function resolveSigningIdentity(options: Options, context: SetupContext): Promise<string> {
  if (!options.signingIdentity) return "-";
  const output = await checked(context, ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], true);
  const identities = output.split("\n").flatMap(line => {
    const match = line.match(/^\s*\d+\)\s+([0-9a-fA-F]{40})\s+"([^"]+)"\s*$/);
    return match ? [{ hash: match[1], name: match[2] }] : [];
  });
  const selected = identities.filter(identity => identity.name === options.signingIdentity
    || identity.hash.toLowerCase() === options.signingIdentity!.toLowerCase());
  if (selected.length !== 1) throw new Error("The requested signing identity is missing or ambiguous. Install/select your own Apple code-signing identity; no certificate or account was created.");
  return selected[0].hash;
}

export async function installApp(context: SetupContext, source: string): Promise<{ app: string; backup?: string }> {
  const applications = join(context.userHome, "Applications");
  const destination = join(applications, "Mactopus.app");
  if (await exists(applications)) await requireSafeDirectory(applications);
  else await mkdir(applications, { mode: 0o755 });
  await requireStopped(context);
  if (await exists(destination)) await inspectApp(context, destination);
  const stage = await mkdtemp(join(applications, ".mactopus-install-"));
  const stagedApp = join(stage, "Mactopus.app");
  // ditto preserves executable modes and symlinks within the sealed bundle.
  // All validation happens before the existing app is moved.
  await checked(context, ["/usr/bin/ditto", source, stagedApp]);
  await inspectApp(context, stagedApp);
  await requireStopped(context);
  let backup: string | undefined;
  if (await exists(destination)) {
    // Revalidate after staging, not just at the beginning of a slow copy.
    await inspectApp(context, destination);
    const backupRoot = join(applications, "Mactopus Backups");
    if (await exists(backupRoot)) await requireSafeDirectory(backupRoot);
    else await mkdir(backupRoot, { mode: 0o700 });
    const backupContainer = await mkdtemp(join(backupRoot, `${new Date().toISOString().replace(/[:.]/g, "-")}-`));
    backup = join(backupContainer, "Mactopus.app");
    await context.move(destination, backup);
  }
  try {
    await context.move(stagedApp, destination);
  } catch (error) {
    if (backup && !await exists(destination)) {
      try { await context.move(backup, destination); }
      catch (restoreError) {
        throw new Error(`Install failed and automatic rollback could not complete. Your previous app is preserved at ${backup}. Staged build: ${stagedApp}. ${String(restoreError)}`);
      }
    }
    throw new Error(`Install failed; the previous app was preserved. Staged build: ${stagedApp}. ${String(error)}`);
  }
  // Retain the small staging directory instead of performing any recursive
  // cleanup in the user's Applications tree. Backups are never auto-deleted.
  context.log(`Installed ${destination}`);
  if (backup) context.log(`Previous app preserved at ${backup}`);
  return { app: destination, backup };
}

export async function setup(options: Options, context: SetupContext): Promise<{ app?: string; backup?: string }> {
  if (options.help) { context.log(help); return {}; }
  await checkPrerequisites(context);
  const signingIdentity = await resolveSigningIdentity(options, context);
  if (options.check) return {};
  if (!options.buildOnly) {
    await requireStopped(context);
    const destination = join(context.userHome, "Applications/Mactopus.app");
    if (await exists(destination)) await inspectApp(context, destination);
  }
  context.log("Building the source-pinned agent runtime, frozen WebUI dependencies, and native app. No installed Codex app is used.");
  await checked(context, ["bun", "Scripts/build-agent-runtime.ts", "--release", "--isolated-source"]);
  const webInstall = await context.run(["bun", "install", "--frozen-lockfile"], join(context.root, "WebUI"));
  if (webInstall.code !== 0) throw new Error("Frozen WebUI dependency installation failed.");
  const webBuild = await context.run(["bun", "run", "build"], join(context.root, "WebUI"));
  if (webBuild.code !== 0) throw new Error("WebUI build failed.");
  await checked(context, ["xcodegen", "generate"]);
  const derivedData = join(context.root, ".build/SourceInstall");
  await checked(context, ["xcodebuild", "-project", "Mactopus.xcodeproj", "-scheme", "Mactopus",
    "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", derivedData,
    "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=", "build"]);
  const product = join(derivedData, "Build/Products/Release/Mactopus.app");
  for (const relative of ["Contents/MacOS/Mactopus", "Contents/Resources/ChromeBridge/ChromeBridgeHost",
    "Contents/Resources/AgentRuntime/codex-app-server", "Contents/Resources/AgentRuntime/manifest.json",
    "Contents/Resources/MLXServer/server.py", "Contents/Resources/WebUI/index.html"]) {
    await requireRegular(join(product, relative));
  }
  // The agent builder already signed and hashed its executable. Do not re-sign
  // it here: changing its code signature would invalidate the runtime manifest.
  await checked(context, ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
    "--identifier", `${bundleID}.ChromeBridgeHost`, "--sign", signingIdentity, join(product, "Contents/Resources/ChromeBridge/ChromeBridgeHost")]);
  await checked(context, ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", signingIdentity, product]);
  await inspectApp(context, product);
  if (options.signingIdentity) {
    // A similarly named self-signed certificate is not the Chrome bridge's
    // trust anchor. Verify an Apple chain before installing a signed build.
    await checked(context, ["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple generic", product]);
  } else {
    context.log("Ad-hoc build: local chat/native AX available; Chrome extension pairing requires --signing-identity with your own Apple certificate.");
  }
  if (options.buildOnly) { context.log(`Built ${product}`); return { app: product }; }
  await requireStopped(context);
  await checked(context, ["/bin/zsh", "Scripts/install-mlx-runtime.sh", ...(options.downloadModel ? ["--download-model"] : [])]);
  const installed = await installApp(context, product);
  if (!options.downloadModel) context.log("No weights downloaded. Install the pinned model with: /bin/zsh Scripts/install-mlx-runtime.sh --download-model");
  context.log("Existing chats, preferences, and Chrome tabs were not changed. Grant macOS permissions and pair Chrome yourself if you want computer use.");
  if (!options.noLaunch) await checked(context, ["/usr/bin/open", installed.app]);
  return installed;
}

if (import.meta.main) {
  const context: SetupContext = {
    root: resolve(import.meta.dir, ".."), userHome: homedir(), platform: process.platform, architecture: process.arch,
    which: name => Bun.which(name), log: console.log, move: rename,
    run: async (command, cwd, capture = false) => {
      const child = Bun.spawn(command, { cwd, stdin: "ignore", stdout: capture ? "pipe" : "inherit", stderr: "inherit" });
      const stdout = capture ? await new Response(child.stdout).text() : "";
      return { code: await child.exited, stdout };
    },
  };
  try { await setup(parseOptions(process.argv.slice(2)), context); }
  catch (error) { console.error(`Mactopus setup: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1; }
}
