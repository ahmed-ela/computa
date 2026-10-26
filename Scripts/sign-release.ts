#!/usr/bin/env bun
// Sign a COPY of a completed build. Never edits the source bundle or installation.
import { createHash } from "node:crypto";
import { rejectRetiredBundleResources } from "./retired-bundle-resources";
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";

export interface SignOptions { app: string; output: string; identity: string }
export type SignRunner = (command: string[]) => Promise<string>;
const bundleID = "com.ahmedelamin.LocalCodex";
const digest = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
const help = "Usage: bun Scripts/sign-release.ts --app BUILD.app --output NEW.app --identity 'Developer ID Application: …'";

export function parseSignOptions(args: string[]): SignOptions {
  const values: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    if (!["--app", "--output", "--identity"].includes(key) || values[key] !== undefined) throw new Error(help);
    const value = args[i + 1];
    if (!value || value.startsWith("-") || /[\x00-\x1f\x7f]/.test(value)) throw new Error(help);
    values[key] = value;
  }
  if (Object.keys(values).length !== 3) throw new Error(help);
  return { app: resolve(values["--app"]), output: resolve(values["--output"]), identity: values["--identity"] };
}

async function regular(path: string, directory = false): Promise<void> {
  const stat = await lstat(path);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile())) {
    throw new Error(`Expected a regular ${directory ? "directory" : "file"}: ${path}`);
  }
}

async function noSymlinks(directory: string): Promise<void> {
  // This product has no framework-version symlinks. Reject links anywhere in
  // the input/copy, including code-signature and resource parent directories.
  for (const child of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, child.name);
    const stat = await lstat(path);
    if (stat.isSymbolicLink()) throw new Error(`Refusing a symlink inside the bundle: ${path}`);
    if (stat.isDirectory()) await noSymlinks(path);
    else if (!stat.isFile()) throw new Error(`Unsupported bundle entry: ${path}`);
  }
}

async function canonicalOutput(requested: string): Promise<string> {
  let ancestor = dirname(resolve(requested));
  const missing: string[] = [basename(requested)];
  while (true) {
    try { return join(await realpath(ancestor), ...missing); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT" || ancestor === dirname(ancestor)) throw error;
      missing.unshift(basename(ancestor)); ancestor = dirname(ancestor);
    }
  }
}

export async function signRelease(options: SignOptions, run: SignRunner): Promise<{ app: string; mainSHA256: string; runtimeSHA256: string }> {
  await regular(options.app, true);
  const app = await realpath(options.app);
  if (!app.endsWith(".app") || !options.output.endsWith(".app")) throw new Error("Source and output must be .app bundles.");
  const output = await canonicalOutput(options.output);
  if (output === app || output.startsWith(app + sep) || app.startsWith(output + sep)) {
    throw new Error("The output must be separate from the source bundle.");
  }
  try { await lstat(output); throw new Error("Output already exists; choose a new staging path."); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  await noSymlinks(app);
  await rejectRetiredBundleResources(app);

  const identityList = await run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]);
  const identities = identityList.split("\n").flatMap(line => {
    const match = line.match(/^\s*\d+\)\s+([0-9a-fA-F]{40})\s+"(Developer ID Application: [^"]+)"\s*$/);
    return match ? [{ hash: match[1], name: match[2] }] : [];
  }).filter(value => value.name === options.identity || value.hash.toLowerCase() === options.identity.toLowerCase());
  if (identities.length !== 1) throw new Error("Select one installed Developer ID Application identity. No credentials were created.");
  const identity = identities[0].hash;
  for (const file of ["Contents/Info.plist", "Contents/MacOS/Computa",
    "Contents/Resources/AgentRuntime/codex-app-server", "Contents/Resources/AgentRuntime/manifest.json"]) await regular(join(app, file));
  if ((await run(["/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", join(app, "Contents/Info.plist")])).trim() !== bundleID) {
    throw new Error("Expected the Computa bundle identifier.");
  }
  const manifestPath = "Contents/Resources/AgentRuntime/manifest.json";
  const runtimePath = "Contents/Resources/AgentRuntime/codex-app-server";
  const manifest = JSON.parse(await readFile(join(app, manifestPath), "utf8"));
  const originalRuntime = await readFile(join(app, runtimePath));
  if (manifest.executable !== "codex-app-server" || manifest.platform !== "macos" || manifest.architecture !== "arm64"
      || manifest.binarySize !== originalRuntime.length || manifest.binarySHA256 !== digest(originalRuntime)) {
    throw new Error("The input runtime does not match its integrity manifest.");
  }
  await run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app]);
  await mkdir(dirname(output), { recursive: true });
  if (await realpath(dirname(output)) !== dirname(output)) throw new Error("Output parent changed during preflight.");
  await run(["/usr/bin/ditto", app, output]);
  await regular(output, true);
  await noSymlinks(output);
  await rejectRetiredBundleResources(output);
  // Sign inside out. Signing changes Mach-O bytes, so refresh the runtime's
  // integrity fields before sealing the outer app. Preserve source provenance.
  for (const [relative, identifier] of [
    [runtimePath, `${bundleID}.AgentRuntime`],
  ]) {
    await run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--identifier", identifier,
      "--sign", identity, join(output, relative)]);
    await run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists", join(output, relative)]);
  }
  const signedRuntime = await readFile(join(output, runtimePath));
  manifest.binarySHA256 = digest(signedRuntime);
  manifest.binarySize = signedRuntime.length;
  await writeFile(join(output, manifestPath), JSON.stringify(manifest, null, 2) + "\n");
  await run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, output]);
  await run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists", output]);
  return { app: output, mainSHA256: digest(await readFile(join(output, "Contents/MacOS/Computa"))), runtimeSHA256: manifest.binarySHA256 };
}

if (import.meta.main) {
  try {
    if (process.argv.slice(2).includes("--help")) { console.log(help); process.exit(0); }
    if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("Release signing requires Apple Silicon macOS.");
    const result = await signRelease(parseSignOptions(process.argv.slice(2)), async command => {
      const child = Bun.spawn(command, { stdout: "pipe", stderr: "inherit", stdin: "ignore" });
      const text = await new Response(child.stdout).text();
      const code = await child.exited;
      if (code !== 0) throw new Error(`Signing command failed (${code}): ${command[0]}`);
      return text;
    });
    console.log(JSON.stringify(result, null, 2));
    console.log("Developer ID signed with secure timestamps. Notarization is a separate step; this is not a Gatekeeper acceptance claim.");
  } catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; }
}
