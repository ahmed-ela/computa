import { afterEach, expect, test } from "bun:test";
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { bundleFiles, inspectApp, packageRelease, parseOptions, sha256, type Context } from "./package-release";

const directories: string[] = [];
afterEach(async () => { for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true }); });
async function file(path: string, value = "fixture") { await mkdir(dirname(path), { recursive: true }); await writeFile(path, value); }
async function fixture() {
  const temporary = await realpath(await mkdtemp(join(tmpdir(), "computa-release-test-")));
  directories.push(temporary);
  const app = join(temporary, "input/Computa.app"), output = join(temporary, "output");
  const info = { CFBundleIdentifier: "com.ahmedelamin.LocalCodex", CFBundleExecutable: "Computa",
    CFBundleShortVersionString: "0.1.0", CFBundleVersion: "1", LSMinimumSystemVersion: "14.0" };
  await file(join(app, "Contents/Info.plist"), JSON.stringify(info));
  for (const name of ["Contents/MacOS/Computa", "Contents/Resources/AgentRuntime/codex-app-server",
    "Contents/Resources/MLXServer/server.py", "Contents/Resources/WebUI/index.html"]) await file(join(app, name));
  await chmod(join(app, "Contents/MacOS/Computa"), 0o755);
  const binary = join(app, "Contents/Resources/AgentRuntime/codex-app-server");
  await file(join(app, "Contents/Resources/AgentRuntime/manifest.json"), JSON.stringify({ schemaVersion: 1,
    platform: "macos", architecture: "arm64", executable: "codex-app-server", binarySize: 7, binarySHA256: await sha256(binary) }));
  const calls: string[][] = [];
  let failing = "";
  const context: Context = {
    root: resolve(import.meta.dir, ".."), platform: "darwin", architecture: "arm64", log: () => {},
    run: async command => {
      calls.push(command);
      if (failing && command.join(" ").includes(failing)) return { code: 1, stdout: "" };
      if (command[0] === "/usr/bin/plutil") return { code: 0, stdout: JSON.stringify(info) };
      if (command[0] === "/usr/bin/lipo") return { code: 0, stdout: command.at(-1)!.endsWith("codex-app-server") ? "arm64" : "x86_64 arm64" };
      if (command[0] === "/usr/bin/otool") {
        const dependency = "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n";
        const arm64 = `fixture (architecture arm64):\n${dependency}`;
        return { code: 0, stdout: command.slice(1, 4).join(" ") === "-arch arm64 -L" || command.at(-1)!.endsWith("codex-app-server")
          ? arm64 : `fixture (architecture x86_64):\n${dependency}${arm64}` };
      }
      if (command[0] === "/usr/bin/ditto") await cp(command.at(-2)!, command.at(-1)!, { recursive: true });
      if (command[0] === "/usr/bin/hdiutil" && command[1] === "create") await file(command.at(-1)!, "mock DMG; no image was built");
      return { code: 0, stdout: "" };
    },
  };
  const options = parseOptions(["--app", app, "--output", output, "--tag", "v0.1.0-alpha.1", "--channel", "signed-test"]);
  return { context, options, app, output, calls, info, fail: (command: string) => { failing = command; } };
}

test("requires an explicit safe release tag and keeps pre-release version separate from app metadata", () => {
  expect(() => parseOptions(["--app", "/a", "--output", "/b"])).toThrow();
  expect(() => parseOptions(["--app", "/a", "--output", "/b", "--tag", "../../bad"])).toThrow();
  expect(() => parseOptions(["--app", "/a", "--output", "/b", "--tag", "v0.1.0", "--version", "0.2.0"])).toThrow();
  expect(parseOptions(["--help"]).help).toBe(true);
});

test("signed-test packaging preserves exact app bytes and mode, records pins, and never signs or installs", async () => {
  const f = await fixture(); const before = await bundleFiles(f.app);
  const result = (await packageRelease(f.options, f.context))!;
  expect(result.dmg).toEndWith("Computa-0.1.0-alpha.1-arm64-signed-test.dmg");
  expect(await bundleFiles(f.app)).toEqual(before);
  const manifest = JSON.parse(await readFile(result.manifest, "utf8"));
  expect(manifest.appFiles).toEqual(before);
  expect(manifest.appVersion).toBe("0.1.0");
  expect(manifest.appBuild).toBe("1");
  expect(manifest.version).toBe("0.1.0-alpha.1");
  expect(manifest.notarizedAppVerified).toBe(false);
  expect(manifest.modelIncluded).toBe(false);
  expect(manifest.uvPin.sha256).toMatch(/^[a-f0-9]{64}$/);
  expect(await readFile(join(f.output, "SHA256SUMS"), "utf8")).toContain(await sha256(result.dmg));
  expect(f.calls.some(call => call.includes("--sign") || call[0].endsWith("/open") || call[0].endsWith("/xattr"))).toBe(false);
  expect(f.calls.some(call => call[0].endsWith("/hdiutil") && call[1] === "verify")).toBe(true);
});

test("rejects invalid SemVer tags, nonnumeric Apple metadata and a tag for a different app version", async () => {
  for (const tag of ["v01.1.0", "v0.1.0-alpha.01", "v0.1.0.preview.1", "v0.1.0-"]) {
    expect(() => parseOptions(["--app", "/a", "--output", "/b", "--tag", tag])).toThrow();
  }
  const f = await fixture();
  await expect(packageRelease({ ...f.options, tag: "v0.2.0" }, f.context)).rejects.toThrow("must match");
  expect(f.calls.some(call => call[0].endsWith("/ditto") || call[0].endsWith("/hdiutil"))).toBe(false);
  f.info.CFBundleShortVersionString = "0.1.0-alpha.1";
  await expect(inspectApp(f.context, f.app, "signed-test")).rejects.toThrow("major.minor.patch");
  f.info.CFBundleShortVersionString = "0.1.0";
  f.info.CFBundleVersion = "0";
  await expect(inspectApp(f.context, f.app, "signed-test")).rejects.toThrow("App build");
});

test("fresh package policy cannot be bypassed through the module API", async () => {
  const f = await fixture();
  for (const tag of ["v0.1.0-beta.1", "v0.1.0-rc.1", "v0.1.0-preview.1", "v0.1.0+build.1", "v0.1.0-alpha.1+build.1"]) {
    expect(() => parseOptions(["--app", f.app, "--output", f.output, "--tag", tag])).toThrow();
    await expect(packageRelease({ ...f.options, tag }, f.context)).rejects.toThrow("Release tag");
  }
  await expect(packageRelease({ ...f.options, version: "0.1.0-alpha.2" }, f.context)).rejects.toThrow("must match");
  expect(f.calls).toHaveLength(0);
  await expect(lstat(f.output)).rejects.toThrow();
});

test("checks the supported arm64 slice of the app plus the arm64-only runtime", async () => {
  const f = await fixture();
  await inspectApp(f.context, f.app, "signed-test");
  const inspections = f.calls.filter(call => call[0] === "/usr/bin/otool");
  expect(inspections).toHaveLength(2);
  expect(inspections.every(call => call.slice(1, 4).join(" ") === "-arch arm64 -L")).toBe(true);
  expect(inspections.map(call => call.at(-1)!.slice(f.app.length + 1))).toEqual([
    "Contents/MacOS/Computa", "Contents/Resources/AgentRuntime/codex-app-server",
  ]);
});

test("notarized mode requires app stapling and assessment; failure occurs before packaging", async () => {
  const f = await fixture(); f.options.channel = "notarized"; f.fail("stapler validate");
  await expect(packageRelease(f.options, f.context)).rejects.toThrow("Command failed");
  expect(f.calls.some(call => call[0].endsWith("/ditto") || call[0].endsWith("/hdiutil"))).toBe(false);
  f.fail(""); await packageRelease(f.options, f.context);
  expect(f.calls.some(call => call[0].endsWith("/spctl") && call.includes("--assess"))).toBe(true);
});

test("rejects altered runtime manifest, app identity, external links and unsupported architecture", async () => {
  const f = await fixture();
  await file(join(f.app, "Contents/Resources/AgentRuntime/codex-app-server"), "changed signed bytes");
  await expect(inspectApp(f.context, f.app, "signed-test")).rejects.toThrow("sealed manifest");
  f.info.CFBundleIdentifier = "other.app";
  await expect(inspectApp(f.context, f.app, "signed-test")).rejects.toThrow("identity");
  await symlink(f.output, join(f.app, "external")); await mkdir(f.output);
  await expect(bundleFiles(f.app)).rejects.toThrow("outside");
  await expect(packageRelease(f.options, { ...f.context, architecture: "x64" })).rejects.toThrow("Apple Silicon");
});

test("rejects developer-machine dylib dependencies and any signature verification failure", async () => {
  const f = await fixture(); const run = f.context.run;
  f.context.run = command => command[0].endsWith("/otool")
    ? Promise.resolve({ code: 0, stdout: "binary:\n /opt/homebrew/lib/libfixture.dylib (version 1)" }) : run(command);
  await expect(packageRelease(f.options, f.context)).rejects.toThrow("non-system");
  f.context.run = run; f.fail("certificate leaf");
  await expect(packageRelease(f.options, f.context)).rejects.toThrow("Command failed");
  expect(f.calls.some(call => call[0].endsWith("/hdiutil"))).toBe(false);
});

test("does not overwrite existing artifacts or allow output inside the signed app", async () => {
  const f = await fixture(); await file(join(f.output, "SHA256SUMS"), "existing");
  await expect(packageRelease(f.options, f.context)).rejects.toThrow("already exists");
  expect(await readFile(join(f.output, "SHA256SUMS"), "utf8")).toBe("existing");
  await expect(packageRelease({ ...f.options, output: join(f.app, "output") }, f.context)).rejects.toThrow("separate");
});

test("refuses stale retired resources before packaging without modifying the source app", async () => {
  for (const relative of ["Contents/Resources/ChromeBridge", "Contents/Resources/BrowserExtension"]) {
    const f = await fixture();
    await mkdir(join(f.app, relative));
    const before = await bundleFiles(f.app);
    await expect(packageRelease(f.options, f.context)).rejects.toThrow("Retired bundle resource remains");
    expect(await bundleFiles(f.app)).toEqual(before);
    expect(f.calls.some(call => call[0] === "/usr/bin/ditto" || call[0] === "/usr/bin/hdiutil")).toBe(false);
  }
});
