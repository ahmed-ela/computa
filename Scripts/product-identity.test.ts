import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

// Product branding may change; persisted identities and runtime protocols must
// not. These checks read source only and never start the app or touch user data.
const root = resolve(import.meta.dir, "..");
const read = (path: string) => readFileSync(resolve(root, path), "utf8");
const source = (path: string) => read(`Sources/Computa/${path}`);

describe("Computa product identity", () => {
  test("the Swift package and Xcode project use the renamed product", () => {
    const packageFile = read("Package.swift");
    expect(packageFile).toContain('name: "Computa"');
    expect(packageFile).toContain('.executable(name: "Computa", targets: ["Computa"])');
    expect(packageFile).toContain('path: "Sources/Computa"');
    expect(packageFile).toContain('path: "Tests/ComputaTests"');
    expect(packageFile).not.toContain('name: "HeyDash"');

    const project = read("project.yml");
    expect(project).toMatch(/^name: Computa\s*$/m);
    expect(project).toMatch(/^\s+PRODUCT_NAME: Computa\s*$/m);
    expect(project).toContain("path: Sources/Computa");
    expect(project).toContain("INFOPLIST_FILE: Config/Computa-Info.plist");
    const generatedProject = read("Computa.xcodeproj/project.pbxproj");
    expect(generatedProject).toContain("Computa.app");
    expect(generatedProject).toContain("Config/Computa-Info.plist");
    expect(generatedProject).toContain("ComputaTests.xctest");
    expect(generatedProject).not.toContain("Macrouse.app");
  });

  test("the application entry point and owned instruction classes use Computa", () => {
    const app = source("ComputaApp.swift");
    expect(app).toContain("struct ComputaApp: App");
    expect(app).toContain("enum ComputaLaunchMode");
    expect(app).toContain("ComputaAppDelegate.self");
    expect(source("Runtime/ComputaAgentInstructions.swift")).toContain("ComputaAgentInstructions");
    expect(source("Runtime/ComputaRuntimeArtifact.swift")).toContain("struct ComputaRuntimeArtifact");
    expect(source("Runtime/CodexAppServerRuntime.swift")).toMatch(/You are Computa[.,]/);
  });

  test("native and web display branding agrees", () => {
    const info = read("Config/Computa-Info.plist");
    expect(info).toMatch(/<key>CFBundleDisplayName<\/key>\s*<string>Computa<\/string>/);
    expect(info).toContain("Computa captures your display");
    expect(source("Web/WebViewHost.swift")).toContain('window.title = "Computa"');
    expect(read("WebUI/index.html")).toContain("<title>Computa</title>");
    const bundledUI = source("Resources/WebUI/index.html");
    expect(bundledUI).toContain("<title>Computa</title>");
    expect(bundledUI).not.toContain("<title>Macrouse</title>");
    expect(JSON.parse(read("WebUI/package.json")).name).toBe("computa-web-ui");
    expect(read("WebUI/src/App.tsx")).not.toContain("HeyDash");
    expect(read("WebUI/vite.config.ts")).toContain("../Sources/Computa/Resources/WebUI");
  });

  test("the app ships its own instructions without another app's policy resource", () => {
    expect(existsSync(resolve(root, "Sources/Computa/Resources/AgentInstructions/StudyLock.md"))).toBe(false);
    expect(source("Runtime/ComputaAgentInstructions.swift")).not.toContain("StudyLock");
    expect(source("Runtime/CodexAppServerRuntime.swift")).not.toContain("StudyLock");
    expect(read("Package.swift")).not.toContain('Resources/AgentInstructions');
    expect(read("project.yml")).not.toContain('Resources/AgentInstructions');
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

  test("model and access mode preferences keep their stored keys", () => {
    const state = source("State/AppState.swift");
    expect(state).toContain('defaultModelPreferenceKey = "LocalCodex.defaultModelID"');
    expect(state).toContain('accessModePreferenceKey = "HeyDash.accessMode"');
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

  test("a product rename does not relabel or replace the pinned agent runtime", () => {
    const pin = JSON.parse(read("Runtime/codex-source.lock.json"));
    expect(pin.runtimeVersion).toBe("mactopus-9");
    // The verified binary/manifest are intentionally not committed. Also check
    // an already-built artifact when present, without making it a test prerequisite.
    if (existsSync(resolve(root, "Sources/Computa/Resources/AgentRuntime/manifest.json"))) {
      const manifest = JSON.parse(source("Resources/AgentRuntime/manifest.json"));
      expect(manifest.runtimeVersion).toBe(pin.runtimeVersion);
      expect(manifest.sourceCommit).toBe(pin.sourceCommit);
      expect(manifest.patchSHA256).toBe(pin.patchSHA256);
    }
  });
});
