import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

// Product branding may change; persisted identities and runtime protocols must
// not. These checks read source only and never start the app or touch user data.
const root = resolve(import.meta.dir, "..");
const read = (path: string) => readFileSync(resolve(root, path), "utf8");
const source = (path: string) => read(`Sources/Mactopus/${path}`);

describe("Mactopus product identity", () => {
  test("the Swift package and Xcode project use the renamed product", () => {
    const packageFile = read("Package.swift");
    expect(packageFile).toContain('name: "Mactopus"');
    expect(packageFile).toContain('.executable(name: "Mactopus", targets: ["Mactopus"])');
    expect(packageFile).toContain('path: "Sources/Mactopus"');
    expect(packageFile).toContain('path: "Tests/MactopusTests"');
    expect(packageFile).not.toContain('name: "HeyDash"');

    const project = read("project.yml");
    expect(project).toMatch(/^name: Mactopus\s*$/m);
    expect(project).toMatch(/^\s+PRODUCT_NAME: Mactopus\s*$/m);
    expect(project).toContain("path: Sources/Mactopus");
    expect(project).toContain("INFOPLIST_FILE: Config/Mactopus-Info.plist");
    const generatedProject = read("Mactopus.xcodeproj/project.pbxproj");
    expect(generatedProject).toContain("Mactopus.app");
    expect(generatedProject).toContain("Config/Mactopus-Info.plist");
    expect(generatedProject).toContain("MactopusTests.xctest");
    expect(generatedProject).not.toContain("Macrouse.app");
  });

  test("the application entry point and owned instruction classes use Mactopus", () => {
    const app = source("MactopusApp.swift");
    expect(app).toContain("struct MactopusApp: App");
    expect(app).toContain("enum MactopusLaunchMode");
    expect(app).toContain("MactopusAppDelegate.self");
    expect(source("Runtime/MactopusAgentInstructions.swift")).toContain("MactopusAgentInstructions");
    expect(source("Runtime/MactopusRuntimeArtifact.swift")).toContain("struct MactopusRuntimeArtifact");
    expect(source("Runtime/CodexAppServerRuntime.swift")).toContain("You are Mactopus.");
  });

  test("native and web display branding agrees", () => {
    const info = read("Config/Mactopus-Info.plist");
    expect(info).toMatch(/<key>CFBundleDisplayName<\/key>\s*<string>Mactopus<\/string>/);
    expect(info).toContain("Mactopus captures your display");
    expect(source("Web/WebViewHost.swift")).toContain('window.title = "Mactopus"');
    expect(read("WebUI/index.html")).toContain("<title>Mactopus</title>");
    const bundledUI = source("Resources/WebUI/index.html");
    expect(bundledUI).toContain("<title>Mactopus</title>");
    expect(bundledUI).not.toContain("<title>Macrouse</title>");
    expect(JSON.parse(read("WebUI/package.json")).name).toBe("mactopus-web-ui");
    expect(read("WebUI/src/App.tsx")).not.toContain("HeyDash");
    expect(read("WebUI/vite.config.ts")).toContain("../Sources/Mactopus/Resources/WebUI");
  });

  test("the packaged UI includes the unified timer without the legacy working footer", () => {
    const html = source("Resources/WebUI/index.html");
    const script = html.match(/<script\b[^>]*\bsrc="\.\/([^"?]+\.js)"/);
    expect(script).not.toBeNull();
    const client = source(`Resources/WebUI/${script![1]}`);
    expect(client).toContain('reasoning-disclosure');
    expect(client).toContain('Working for ');
    expect(client).toContain('Worked for ');
    expect(client).not.toContain('working-indicator');
    expect(client).not.toContain('Working on your task');
  });
});

describe("rename compatibility contracts", () => {
  test("signing and bundle identifiers remain unchanged", () => {
    const project = read("project.yml");
    const identifiers = [...project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)/g)]
      .map(match => match[1]).sort();
    expect(identifiers).toEqual([
      "com.ahmedelamin.LocalCodex",
      "com.ahmedelamin.LocalCodex.AutomationCore",
      "com.ahmedelamin.LocalCodex.AutomationCoreTests",
      "com.ahmedelamin.LocalCodexTests",
    ].sort());
    expect(project).toMatch(/DEVELOPMENT_TEAM:\s*MSMG8CJLB3/);
  });

  test("model, access mode and remembered Chrome preferences keep their stored keys", () => {
    const state = source("State/AppState.swift");
    expect(state).toContain('defaultModelPreferenceKey = "LocalCodex.defaultModelID"');
    expect(state).toContain('accessModePreferenceKey = "HeyDash.accessMode"');
    expect(source("Runtime/RememberedChromeConnection.swift"))
      .toContain('preferenceKey = "HeyDash.rememberedChromeConnection"');
  });

  test("conversation and visual-model storage retain the LocalCodex support directory", () => {
    const runtime = source("Runtime/CodexAppServerRuntime.swift");
    expect(runtime).toContain('.appendingPathComponent("LocalCodex", isDirectory: true)');
    expect(runtime).toContain('.appendingPathComponent("CodexHome", isDirectory: true)');
    expect(source("Runtime/VisualGroundingClient.swift"))
      .toContain('.appendingPathComponent("LocalCodex", isDirectory: true)');
    expect(source("Runtime/HeadlessMLXServer.swift"))
      .toContain('support.appendingPathComponent("LocalCodex/VisualGrounding/venv/bin/python")');
  });

  test("native and Python inference instance protocols stay mutually compatible", () => {
    const native = source("Runtime/HeadlessMLXServer.swift");
    const worker = source("Resources/MLXServer/server.py");
    expect(native).toContain('"HEYDASH_MLX_INSTANCE": instance');
    expect(native).toContain('object["heydash_instance"]');
    expect(worker).toContain('os.environ["HEYDASH_MLX_INSTANCE"]');
    expect(worker).toContain('"heydash_instance": self.instance');
  });

  test("WebKit bridge and app-server client identities remain stable", () => {
    expect(source("Web/WebViewHost.swift")).toContain('scheme = "localcodex-app"');
    expect(read("WebUI/src/App.tsx")).toContain("messageHandlers?.localCodex");
    expect(read("WebUI/src/App.tsx")).toContain("window.__localCodexReceiveState");
    expect(source("Runtime/CodexAppServerRuntime.swift")).toContain('"name": "local_codex"');
  });

  test("Chrome extension branding changes without losing its paired identity", () => {
    const manifest = JSON.parse(read("BrowserExtension/manifest.json"));
    const id = [...createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32)]
      .map(digit => String.fromCharCode(97 + Number.parseInt(digit, 16))).join("");
    expect(manifest.name).toBe("Mactopus Browser Bridge");
    expect(id).toBe("gdghbmoiibghgkfmhjlckipjjlclnlbk");
    expect(read("BrowserExtension/bridge.js")).toContain('HOST_NAME = "com.macndash.chrome_bridge"');
    expect(read("BrowserExtension/bridge.js")).toContain('STORAGE_KEY = "macndashChromeBridgeV1"');
    expect(source("Runtime/ChromeBridgeIPC.swift")).toContain('hostName = "com.macndash.chrome_bridge"');
    const coordinator = source("Runtime/BrowserExtensionCoordinator.swift");
    expect(coordinator).toContain('enabledKey = "Macndash.chromeExtension.enabled"');
    expect(coordinator).toContain('installationKey = "Macndash.chromeExtension.installationID"');
  });

  test("a product rename does not relabel or replace the pinned agent runtime", () => {
    const pin = JSON.parse(read("Runtime/codex-source.lock.json"));
    expect(pin.runtimeVersion).toBe("mactopus-5");
    // The verified binary/manifest are intentionally not committed. Also check
    // an already-built artifact when present, without making it a test prerequisite.
    if (existsSync(resolve(root, "Sources/Mactopus/Resources/AgentRuntime/manifest.json"))) {
      const manifest = JSON.parse(source("Resources/AgentRuntime/manifest.json"));
      expect(manifest.runtimeVersion).toBe("mactopus-5");
      expect(manifest.sourceCommit).toBe(pin.sourceCommit);
      expect(manifest.patchSHA256).toBe(pin.patchSHA256);
    }
  });
});
