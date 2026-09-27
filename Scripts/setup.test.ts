import { afterEach, describe, expect, test } from "bun:test";
import { cp, lstat, mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { checkPrerequisites, installApp, parseOptions, setup, type SetupContext } from "./setup";

const temporaryDirectories: string[] = [];
afterEach(async () => {
  for (const directory of temporaryDirectories.splice(0)) await rm(directory, { recursive: true, force: true });
});

async function file(path: string, contents = "fixture") {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents);
}

async function app(path: string, identity = "com.ahmedelamin.LocalCodex", marker = "new build") {
  await file(join(path, "Contents/Info.plist"), identity);
  await file(join(path, "Contents/MacOS/Mactopus"), marker);
  for (const relative of ["ChromeBridge/ChromeBridgeHost", "AgentRuntime/codex-app-server", "AgentRuntime/manifest.json",
    "MLXServer/server.py", "WebUI/index.html"]) await file(join(path, "Contents/Resources", relative));
}

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "mactopus-setup-test-"));
  temporaryDirectories.push(directory);
  const root = join(directory, "checkout");
  const userHome = join(directory, "user");
  await mkdir(userHome);
  for (const path of ["project.yml", "WebUI/bun.lock", "Runtime/codex-source.lock.json",
    "Runtime/patches/compaction-retention.patch", "Scripts/build-agent-runtime.ts", "Scripts/install-mlx-runtime.sh",
    "Scripts/mlx-runtime-install.py", "Scripts/mlx-runtime-requirements.lock", "Scripts/mlx-model.lock.json"]) {
    await file(join(root, path));
  }
  const calls: string[][] = [];
  const logs: string[] = [];
  let running = false;
  let failedCommand: string | undefined;
  const context: SetupContext = {
    root, userHome, platform: "darwin", architecture: "arm64", which: command => `/fixture/bin/${command}`,
    log: message => logs.push(message), move: rename,
    run: async (command, cwd, capture) => {
      calls.push(command);
      if (failedCommand && command.join(" ").includes(failedCommand)) return { code: 2, stdout: "" };
      const executable = command[0];
      if (executable === "/usr/bin/sw_vers") return { code: 0, stdout: "26.0" };
      if (executable === "/usr/bin/xcode-select") return { code: 0, stdout: "/Applications/Xcode.app/Contents/Developer" };
      if (executable === "xcrun") return { code: 0, stdout: "Apple Swift version 6.2 (swiftlang-6.2)" };
      if (executable === "bun" && command[1] === "--version") return { code: 0, stdout: "1.3.5" };
      if (executable === "rustup") return { code: 0, stdout: "rustc 1.95.0 (012345678 2026-04-01)" };
      if (executable === "/usr/bin/security") return { code: 0, stdout: '  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Apple Development: Fixture (FIXTURE123)"\n     1 valid identities found' };
      if (executable === "/usr/bin/pgrep") return { code: running ? 0 : 1, stdout: running ? "42" : "" };
      if (executable === "/usr/bin/plutil") return { code: 0, stdout: command[2] === "CFBundleIdentifier"
        ? await readFile(command.at(-1)!, "utf8") : "Mactopus" };
      if (executable === "/usr/bin/ditto") await cp(command[1], command[2], { recursive: true });
      if (executable === "xcodebuild" && command.includes("build")) {
        await app(join(root, ".build/SourceInstall/Build/Products/Release/Mactopus.app"));
      }
      return { code: 0, stdout: "fixture version 1.0" };
    },
  };
  return { context, calls, logs, setRunning: (value: boolean) => { running = value; },
    failCommand: (value: string) => { failedCommand = value; } };
}

describe("source setup options", () => {
  test("explicit flags and defaults", () => {
    expect(parseOptions([])).toEqual({ check: false, buildOnly: false, noLaunch: false, downloadModel: false, help: false });
    expect(parseOptions(["--no-launch", "--download-model"]).downloadModel).toBe(true);
  });
  test("reject unknown, duplicate, and misleading combinations", () => {
    for (const arguments_ of [["--sudo"], ["--check", "--no-launch"], ["--build-only", "--download-model"], ["--check", "--check"]]) {
      expect(() => parseOptions(arguments_)).toThrow();
    }
    for (const arguments_ of [["--signing-identity"], ["--signing-identity", "-"], ["--signing-identity", "bad\nname"],
      ["--signing-identity", "A", "--signing-identity", "B"]]) expect(() => parseOptions(arguments_)).toThrow();
  });
});

describe("source prerequisite checks", () => {
  test("check is read-only and never invokes builds, installs, or launches", async () => {
    const f = await fixture();
    await setup(parseOptions(["--check"]), f.context);
    expect(f.calls.some(call => call.includes("build") || call.includes("install") || call[0] === "/usr/bin/open")).toBe(false);
    expect(await lstat(join(f.context.userHome, "Applications")).catch(() => null)).toBeNull();
    expect(await lstat(join(f.context.root, ".build")).catch(() => null)).toBeNull();
  });
  test("reject unsupported platforms before any subprocess", async () => {
    const f = await fixture();
    await expect(checkPrerequisites({ ...f.context, architecture: "x64" })).rejects.toThrow("Apple Silicon");
    expect(f.calls).toHaveLength(0);
  });
  test("missing tools are not silently installed", async () => {
    const f = await fixture();
    await expect(checkPrerequisites({ ...f.context, which: name => name === "uv" ? null : name })).rejects.toThrow("uv");
    expect(f.calls).toHaveLength(0);
  });
  test("reject standalone command line tools and old Swift", async () => {
    const f = await fixture();
    const run = f.context.run;
    await expect(checkPrerequisites({ ...f.context, run: (command, ...args) => command[0] === "/usr/bin/xcode-select"
      ? Promise.resolve({ code: 0, stdout: "/Library/Developer/CommandLineTools" }) : run(command, ...args) })).rejects.toThrow("full Xcode");
    await expect(checkPrerequisites({ ...f.context, run: (command, ...args) => command[0] === "xcrun"
      ? Promise.resolve({ code: 0, stdout: "Apple Swift version 6.1" }) : run(command, ...args) })).rejects.toThrow("Swift 6.2");
  });
});

describe("source build flow", () => {
  test("explicit certificate signs helper and outer app and checks Apple trust", async () => {
    const f = await fixture();
    await setup(parseOptions(["--build-only", "--signing-identity", "Apple Development: Fixture (FIXTURE123)"]), f.context);
    const signatures = f.calls.filter(call => call[0] === "/usr/bin/codesign" && call.includes("--sign"));
    expect(signatures).toHaveLength(2);
    expect(signatures.every(call => call[call.indexOf("--sign") + 1] === "ABCDEF0123456789ABCDEF0123456789ABCDEF01")).toBe(true);
    expect(f.calls.some(call => call.includes("=anchor apple generic"))).toBe(true);
  });
  test("missing certificate fails before builds and Apple-chain rejection prevents install", async () => {
    const f = await fixture();
    await expect(setup(parseOptions(["--signing-identity", "Not my certificate"]), f.context)).rejects.toThrow("missing or ambiguous");
    expect(f.calls.some(call => call.includes("Scripts/build-agent-runtime.ts"))).toBe(false);
    f.failCommand("anchor apple generic");
    await expect(setup(parseOptions(["--signing-identity", "ABCDEF0123456789ABCDEF0123456789ABCDEF01"]), f.context)).rejects.toThrow("Command failed");
    expect(f.calls.some(call => call.includes("Scripts/install-mlx-runtime.sh") || call[0] === "/usr/bin/ditto")).toBe(false);
  });
  test("build-only uses locked sources and portable signing without touching user installation", async () => {
    const f = await fixture();
    const result = await setup(parseOptions(["--build-only"]), f.context);
    expect(result.app).toBe(join(f.context.root, ".build/SourceInstall/Build/Products/Release/Mactopus.app"));
    expect(f.calls).toContainEqual(["bun", "Scripts/build-agent-runtime.ts", "--release", "--isolated-source"]);
    expect(f.calls).toContainEqual(["bun", "install", "--frozen-lockfile"]);
    expect(f.calls.find(call => call[0] === "xcodebuild" && call.includes("build"))).toContain("DEVELOPMENT_TEAM=");
    expect(f.calls.some(call => call.includes("Scripts/install-mlx-runtime.sh") || call[0] === "/usr/bin/open")).toBe(false);
    const signatures = f.calls.filter(call => call[0] === "/usr/bin/codesign" && call.includes("--sign"));
    expect(signatures).toHaveLength(2);
    expect(signatures.every(call => call[call.indexOf("--sign") + 1] === "-")).toBe(true);
    expect(signatures.some(call => call.at(-1)?.endsWith("AgentRuntime/codex-app-server"))).toBe(false);
    expect(await lstat(join(f.context.userHome, "Applications")).catch(() => null)).toBeNull();
  });
  test("normal install provisions environment but downloads no model and launches exact user app", async () => {
    const f = await fixture();
    const result = await setup(parseOptions([]), f.context);
    expect(f.calls).toContainEqual(["/bin/zsh", "Scripts/install-mlx-runtime.sh"]);
    expect(f.calls).toContainEqual(["/usr/bin/open", join(f.context.userHome, "Applications/Mactopus.app")]);
    expect(await readFile(join(result.app!, "Contents/MacOS/Mactopus"), "utf8")).toBe("new build");
  });
  test("download is explicit and no-launch does not start the installed app", async () => {
    const f = await fixture();
    await setup(parseOptions(["--download-model", "--no-launch"]), f.context);
    expect(f.calls).toContainEqual(["/bin/zsh", "Scripts/install-mlx-runtime.sh", "--download-model"]);
    expect(f.calls.some(call => call[0] === "/usr/bin/open")).toBe(false);
  });
  test("running app blocks install before building or provisioning", async () => {
    const f = await fixture();
    f.setRunning(true);
    await expect(setup(parseOptions([]), f.context)).rejects.toThrow("Quit it normally");
    expect(f.calls.some(call => call.includes("Scripts/build-agent-runtime.ts"))).toBe(false);
  });
  test("app started during build blocks MLX provisioning and application replacement", async () => {
    const f = await fixture();
    const run = f.context.run;
    f.context.run = async (command, ...arguments_) => {
      const result = await run(command, ...arguments_);
      if (command[0] === "xcodebuild" && command.includes("build")) f.setRunning(true);
      return result;
    };
    await expect(setup(parseOptions(["--download-model"]), f.context)).rejects.toThrow("Quit it normally");
    expect(f.calls.some(call => call.includes("Scripts/install-mlx-runtime.sh") || call[0] === "/usr/bin/ditto")).toBe(false);
    expect(await lstat(join(f.context.userHome, "Applications")).catch(() => null)).toBeNull();
  });
  test("failed build leaves existing app and user state unchanged", async () => {
    const f = await fixture();
    const existing = join(f.context.userHome, "Applications/Mactopus.app");
    await app(existing, undefined, "previous build");
    f.failCommand("Scripts/build-agent-runtime.ts");
    await expect(setup(parseOptions([]), f.context)).rejects.toThrow("Command failed");
    expect(await readFile(join(existing, "Contents/MacOS/Mactopus"), "utf8")).toBe("previous build");
    expect(f.calls.some(call => call.includes("Scripts/install-mlx-runtime.sh"))).toBe(false);
  });
});

describe("installation preservation", () => {
  test("existing compatible app is backed up without changing application support", async () => {
    const f = await fixture();
    const source = join(f.context.root, "product/Mactopus.app");
    const destination = join(f.context.userHome, "Applications/Mactopus.app");
    const savedChat = join(f.context.userHome, "Library/Application Support/LocalCodex/chat.json");
    await app(source);
    await app(destination, undefined, "previous build");
    await file(savedChat, "private saved data");
    const result = await installApp(f.context, source);
    expect(result.backup).toBeDefined();
    expect(await readFile(join(result.backup!, "Contents/MacOS/Mactopus"), "utf8")).toBe("previous build");
    expect(await readFile(join(destination, "Contents/MacOS/Mactopus"), "utf8")).toBe("new build");
    expect(await readFile(savedChat, "utf8")).toBe("private saved data");
  });
  test("unknown app identity is preserved", async () => {
    const f = await fixture();
    const source = join(f.context.root, "product/Mactopus.app");
    const destination = join(f.context.userHome, "Applications/Mactopus.app");
    await app(source);
    await app(destination, "org.example.Unrelated", "unknown app");
    await expect(installApp(f.context, source)).rejects.toThrow("unknown app");
    expect(await readFile(join(destination, "Contents/MacOS/Mactopus"), "utf8")).toBe("unknown app");
    expect(f.calls.some(call => call[0] === "/usr/bin/ditto")).toBe(false);
  });
  test("symlinked Applications is rejected", async () => {
    const f = await fixture();
    const other = join(f.context.userHome, "elsewhere");
    await mkdir(other);
    await symlink(other, join(f.context.userHome, "Applications"));
    await expect(installApp(f.context, "/not-used")).rejects.toThrow("symlink");
  });
  test("failed final rename restores the previous app and keeps staged evidence", async () => {
    const f = await fixture();
    const source = join(f.context.root, "product/Mactopus.app");
    const destination = join(f.context.userHome, "Applications/Mactopus.app");
    await app(source);
    await app(destination, undefined, "previous build");
    f.context.move = async (from, to) => {
      if (from.includes(".mactopus-install-") && to === destination) throw new Error("simulated rename failure");
      await rename(from, to);
    };
    await expect(installApp(f.context, source)).rejects.toThrow("previous app was preserved");
    expect(await readFile(join(destination, "Contents/MacOS/Mactopus"), "utf8")).toBe("previous build");
  });
});
