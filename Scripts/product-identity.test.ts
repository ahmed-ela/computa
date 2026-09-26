import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

// Product branding may change; persisted identities and runtime protocols must
// not. These checks read source only and never start the app or touch user data.
const root = resolve(import.meta.dir, "..");
const read = (path: string) => readFileSync(resolve(root, path), "utf8");
const source = (path: string) => read(`Sources/Macrouse/${path}`);

describe("Macrouse product identity", () => {
  test("the Swift package and Xcode project use the renamed product", () => {
    const packageFile = read("Package.swift");
    expect(packageFile).toContain('name: "Macrouse"');
    expect(packageFile).toContain('.executable(name: "Macrouse", targets: ["Macrouse"])');
    expect(packageFile).toContain('path: "Sources/Macrouse"');
    expect(packageFile).toContain('path: "Tests/MacrouseTests"');
    expect(packageFile).not.toContain('name: "HeyDash"');

    const project = read("project.yml");
    expect(project).toMatch(/^name: Macrouse\s*$/m);
    expect(project).toMatch(/^\s+PRODUCT_NAME: Macrouse\s*$/m);
    expect(project).toContain("path: Sources/Macrouse");
    expect(project).toContain("INFOPLIST_FILE: Config/Macrouse-Info.plist");
    expect(existsSync(resolve(root, "Macrouse.xcodeproj/project.pbxproj"))).toBe(true);
  });

  test("the application entry point and owned instruction classes use Macrouse", () => {
    const app = source("MacrouseApp.swift");
    expect(app).toContain("struct MacrouseApp: App");
    expect(app).toContain("enum MacrouseLaunchMode");
    expect(app).toContain("MacrouseAppDelegate.self");
    expect(source("Runtime/MacrouseAgentInstructions.swift")).toContain("MacrouseAgentInstructions");
    expect(source("Runtime/MacrouseRuntimeArtifact.swift")).toContain("struct MacrouseRuntimeArtifact");
    expect(source("Runtime/CodexAppServerRuntime.swift")).toContain("You are Macrouse.");
  });

  test("native and web display branding agrees", () => {
    const info = read("Config/Macrouse-Info.plist");
    expect(info).toMatch(/<key>CFBundleDisplayName<\/key>\s*<string>Macrouse<\/string>/);
    expect(info).toContain("Macrouse captures your display");
    expect(source("Web/WebViewHost.swift")).toContain('window.title = "Macrouse"');
    expect(read("WebUI/index.html")).toContain("<title>Macrouse</title>");
    expect(JSON.parse(read("WebUI/package.json")).name).toBe("macrouse-web-ui");
    expect(read("WebUI/src/App.tsx")).not.toContain("HeyDash");
    expect(read("WebUI/vite.config.ts")).toContain("../Sources/Macrouse/Resources/WebUI");
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
    expect(manifest.name).toBe("Macrouse Browser Bridge");
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
    expect(pin.runtimeVersion).toBe("heydash-4");
    // The verified binary/manifest are intentionally not committed. Also check
    // an already-built artifact when present, without making it a test prerequisite.
    if (existsSync(resolve(root, "Sources/Macrouse/Resources/AgentRuntime/manifest.json"))) {
      const manifest = JSON.parse(source("Resources/AgentRuntime/manifest.json"));
      expect(manifest.runtimeVersion).toBe("heydash-4");
      expect(manifest.sourceCommit).toBe(pin.sourceCommit);
      expect(manifest.patchSHA256).toBe(pin.patchSHA256);
    }
  });
});
