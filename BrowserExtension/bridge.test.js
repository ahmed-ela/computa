import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { ChromeBridge, MAX_MESSAGE_BYTES } from "./bridge.js";
import { CLICKABILITY_STYLES, PRESS_FUNCTION, SET_TEXT_FUNCTION, validateCommand } from "./commands.js";

const token = "a".repeat(64);
const group = "heydash-mutation-12345678-1234-1234-1234-123456789abc";
function fixture(initial = {}, options = {}) {
  let sequence = 0;
  const messages = [], calls = [], stored = structuredClone(initial);
  const targets = [
    { id: "target-one", tabId: 1, type: "page", title: "First", url: "https://example.com/", attached: false },
    { id: "target-two", tabId: 2, type: "page", title: "Duplicate", url: "https://example.com/", attached: false },
    { id: "restricted", tabId: 3, type: "page", title: "Settings", url: "chrome://settings/", attached: false },
  ];
  const chrome = {
    runtime: { id: "gdghbmoiibghgkfmhjlckipjjlclnlbk" },
    storage: { local: { get: async key => ({ [key]: structuredClone(stored[key]) }),
      set: async value => { Object.assign(stored, structuredClone(value)); } } },
    debugger: {
      getTargets: async () => structuredClone(targets),
      attach: async (target, version) => { calls.push(["attach", target, version]); targets.find(item => item.id === target.targetId).attached = true; },
      detach: async target => { calls.push(["detach", target]); const item = targets.find(item => item.id === target.targetId); if (item) item.attached = false; },
      sendCommand: async (target, method, params) => {
        calls.push(["command", target, method, structuredClone(params)]);
        if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "frame-1", loaderId: "loader-1", url: "https://example.com/" } } };
        if (method === "Page.createIsolatedWorld") return { executionContextId: 7 };
        if (method === "DOM.resolveNode") return { object: { objectId: "object-1" } };
        if (method === "Runtime.callFunctionOn") return { result: { value: true } };
        return {};
      },
    },
  };
  const bridge = new ChromeBridge({ chrome, emit: message => messages.push(structuredClone(message)), uuid: () => `uuid-${++sequence}`, ...options });
  let id = 0;
  const request = async (operation, params = {}, generation = "generation-1", forcedId) => {
    const requestID = forcedId ?? `request-${++id}`;
    await bridge.receive({ version: 1, id: requestID, operation, params, generation });
    return [...messages].reverse().find(message => message.id === requestID);
  };
  const pair = async () => {
    await bridge.requestPairing();
    const event = messages.at(-1);
    return request("approvePair", { installationId: bridge.state.installationId, pairingNonce: event.pairingNonce, pairingToken: token });
  };
  const authorize = generation => request("authorizeSession", { installationId: bridge.state.installationId, pairingToken: token }, generation);
  const setup = async () => { await bridge.initialize(); await pair(); await authorize("generation-1"); };
  const attach = async () => (await request("attach", { targetID: "target-one" })).result.attachmentToken;
  const command = (attachmentToken, method, params = {}) => request("command", { attachmentToken, method, params });
  return { bridge, chrome, messages, calls, targets, stored, request, pair, authorize, setup, attach, command };
}

describe("pairing and session authority", () => {
  test("unpaired bridge exposes identity but not browser data", async () => {
    const f = fixture(); await f.bridge.initialize();
    expect(f.bridge.hello()).not.toHaveProperty("pairingToken");
    expect((await f.request("inventory")).error.code).toBe("unauthorized");
    expect(f.calls).toEqual([]);
  });
  test("approvePair requires a matching popup-initiated nonce", async () => {
    const f = fixture(); await f.bridge.initialize();
    const params = { installationId: f.bridge.state.installationId, pairingNonce: "invented", pairingToken: token };
    expect((await f.request("approvePair", params)).error.code).toBe("pairing_rejected");
    expect((await f.pair()).ok).toBe(true);
    expect(f.bridge.status().paired).toBe(true);
    expect(f.bridge.status().connected).toBe(false);
  });
  test("replays only a user-initiated pairing proposal on a newly connected app", async () => {
    const f = fixture(); await f.bridge.initialize(); await f.bridge.requestPairing();
    const nonce = f.messages.at(-1).pairingNonce;
    await f.bridge.receive({ version: 1, event: "requestHello" });
    expect(f.messages.at(-1).event).toBe("pairRequested");
    expect(f.messages.at(-1).pairingNonce).toBe(nonce);
    expect(f.messages.at(-1).paired).toBe(false);
    expect(f.messages.at(-1).suspended).toBe(false);
    expect(f.calls).toEqual([]);
  });
  test("only exact pairing authorizes, and every generation is fresh", async () => {
    const f = fixture(); await f.setup();
    expect((await f.authorize("generation-1")).error.code).toBe("duplicate_generation");
    expect((await f.request("authorizeSession", { installationId: "wrong", pairingToken: token }, "g2")).error.code).toBe("unauthorized");
    expect((await f.authorize("generation-2")).ok).toBe(true);
    expect((await f.request("inventory", {}, "generation-1")).error.code).toBe("unauthorized");
    expect((await f.authorize("generation-1")).error.code).toBe("duplicate_generation");
  });
  test("pairing survives worker restart, live generation does not", async () => {
    const f = fixture(); await f.setup();
    const next = fixture(f.stored); await next.bridge.initialize();
    expect(next.bridge.status().paired).toBe(true);
    expect(next.bridge.status().connected).toBe(false);
    expect(next.bridge.status()).not.toHaveProperty("pairingToken");
  });
  test("app disconnect revokes immediately and permits fresh explicit authentication", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    await f.bridge.receive({ version: 1, event: "appDisconnected" });
    expect(f.bridge.generation).toBeNull();
    expect((await f.command(attachmentToken, "Page.getFrameTree")).error.code).toBe("unauthorized");
    expect((await f.authorize("g2")).ok).toBe(true);
  });
  test("cancel suspends across restart and native requests cannot resume", async () => {
    const f = fixture(); await f.setup(); await f.attach();
    await f.bridge.onDetach({ tabId: 1 }, "canceled_by_user");
    expect(f.bridge.status().suspended).toBe(true);
    expect((await f.authorize("g2")).error.code).toBe("unauthorized");
    const next = fixture(f.stored); await next.bridge.initialize();
    expect(next.bridge.status().suspended).toBe(true);
    await next.bridge.resumeFromPopup();
    expect((await next.authorize("g2")).ok).toBe(true);
  });
  test("target closure does not silently retarget a duplicate URL", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    await f.bridge.onDetach({ targetId: "target-one" }, "target_closed");
    expect(f.bridge.status().suspended).toBe(false);
    expect((await f.command(attachmentToken, "Page.getFrameTree")).error.code).toBe("stale_attachment");
    expect(f.calls.filter(call => call[0] === "attach")).toHaveLength(1);
  });
  test("explicit forget removes persisted authority and cannot be restored by a native request", async () => {
    const f = fixture(); await f.setup(); await f.attach();
    expect((await f.request("disconnect", { forgetPairing: true })).ok).toBe(true);
    expect(f.bridge.state.pairingToken).toBeNull();
    expect((await f.authorize("g2")).error.code).toBe("unauthorized");
    const next = fixture(f.stored); await next.bridge.initialize();
    expect(next.bridge.status().paired).toBe(false);
  });
  test("native revokePair accepts exact pairing even while suspended, but never grants access", async () => {
    const f = fixture(); await f.setup();
    await f.bridge.revoke({ suspend: true });
    expect((await f.request("revokePair", { installationId: f.bridge.state.installationId, pairingToken: "wrong" }, "forget-1")).error.code).toBe("unauthorized");
    expect((await f.request("revokePair", { installationId: f.bridge.state.installationId, pairingToken: token }, "forget-2")).ok).toBe(true);
    expect(f.bridge.status().paired).toBe(false);
    expect(f.bridge.status().suspended).toBe(true);
    expect((await f.authorize("g2")).error.code).toBe("unauthorized");
  });
});

describe("bounded tab and command contract", () => {
  test("inventory excludes restricted pages without touching tabs", async () => {
    const f = fixture(); await f.setup();
    const reply = await f.request("inventory");
    expect(reply.result.candidates.map(item => item.targetID)).toEqual(["target-one", "target-two"]);
    expect(f.calls).toEqual([]);
  });
  test("attach binds exact target, never duplicate URL, and denies existing debuggers", async () => {
    const f = fixture(); await f.setup();
    f.targets[0].attached = true;
    expect((await f.request("attach", { targetID: "target-one" })).error.code).toBe("target_busy");
    expect((await f.request("attach", { targetID: "restricted" })).error.code).toBe("target_unavailable");
    expect((await f.request("attach", { targetID: "no-longer-present" })).error.code).toBe("target_unavailable");
    expect(f.calls).toEqual([]);
    expect(f.bridge.status().paired).toBe(true);
    expect((await f.request("ping")).ok).toBe(true);
    expect((await f.request("attach", { targetID: "target-two" })).ok).toBe(true);
    expect(f.calls[0]).toEqual(["attach", { targetId: "target-two" }, "1.3"]);
  });
  test("inventory reports fresh finite availability without adopting or releasing another debugger", async () => {
    const f = fixture(); await f.setup();
    f.targets[0].attached = true;
    let reply = await f.request("inventory");
    expect(reply.result.candidates.map(item => item.availability)).toEqual(["busy", "available"]);
    delete f.targets[0].attached;
    reply = await f.request("inventory");
    expect(reply.result.candidates[0].availability).toBe("unknown");
    f.targets[0].attached = false;
    reply = await f.request("inventory");
    expect(reply.result.candidates[0].availability).toBe("available");
    expect(f.calls).toEqual([]);
  });
  test("an ordinary semantic click uses the fixed function and owned handles", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    await f.command(attachmentToken, "Page.getFrameTree");
    await f.command(attachmentToken, "Page.createIsolatedWorld", { frameId: "frame-1", worldName: "LocalCodexBrowserBroker" });
    await f.command(attachmentToken, "DOM.resolveNode", { backendNodeId: 12, executionContextId: 7, objectGroup: group });
    const result = await f.command(attachmentToken, "Runtime.callFunctionOn", { objectId: "object-1", functionDeclaration: PRESS_FUNCTION,
      arguments: [{ value: "https://example.com/" }], returnByValue: true, awaitPromise: true, userGesture: true });
    expect(result.result).toEqual({ result: { value: true } });
    await f.command(attachmentToken, "Runtime.releaseObjectGroup", { objectGroup: group });
    expect(f.bridge.attachments.get(attachmentToken).objects.size).toBe(0);
  });
  test("unobserved frame, context and object handles cannot be supplied", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    expect((await f.command(attachmentToken, "Page.createIsolatedWorld", { frameId: "frame-1", worldName: "LocalCodexBrowserBroker" })).error.code).toBe("stale_frame");
    expect((await f.command(attachmentToken, "DOM.resolveNode", { backendNodeId: 12, executionContextId: 7, objectGroup: group })).error.code).toBe("stale_context");
    expect((await f.command(attachmentToken, "Runtime.callFunctionOn", { objectId: "invented", functionDeclaration: PRESS_FUNCTION,
      arguments: [{ value: "https://example.com/" }], returnByValue: true, awaitPromise: true, userGesture: true })).error.code).toBe("stale_object");
  });
  test.each(["Runtime.evaluate", "Page.navigate", "Target.createTarget", "Target.activateTarget", "Browser.getVersion", "Input.dispatchKeyEvent", "Page.captureScreenshot"])("rejects out-of-contract %s", async method => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    expect((await f.command(attachmentToken, method)).error.code).toBe("unsupported_command");
    expect(f.calls.filter(call => call[0] === "command")).toHaveLength(0);
  });
  test("rejects script variation and extra capability parameters", () => {
    expect(() => validateCommand("Runtime.callFunctionOn", { objectId: "object-1", functionDeclaration: PRESS_FUNCTION + "\n//extra",
      arguments: [{ value: "https://example.com/" }], returnByValue: true, awaitPromise: true, userGesture: true })).toThrow();
    expect(() => validateCommand("Page.createIsolatedWorld", { frameId: "f", worldName: "LocalCodexBrowserBroker", grantUniveralAccess: true })).toThrow();
    expect(() => validateCommand("Accessibility.getFullAXTree", { depth: 999 })).toThrow();
    expect(() => validateCommand("Accessibility.getFullAXTree", { depth: 65 })).toThrow();
    expect(() => validateCommand("Accessibility.getFullAXTree", { depth: 16 })).not.toThrow();
    expect(() => validateCommand("Accessibility.getFullAXTree", { depth: 64 })).not.toThrow();
  });
  test("duplicate request ID is rejected before a second operation", async () => {
    const f = fixture(); await f.setup();
    expect((await f.request("attach", { targetID: "target-one" }, "generation-1", "unique")).ok).toBe(true);
    expect((await f.request("attach", { targetID: "target-two" }, "generation-1", "unique")).error.code).toBe("duplicate_request");
    expect(f.calls.filter(call => call[0] === "attach")).toHaveLength(1);
  });
  test("malformed envelope never dispatches, and browser errors are redacted", async () => {
    const f = fixture(); await f.setup();
    await f.bridge.receive({ version: 1, id: "bad", operation: "inventory", params: {}, generation: "generation-1", extra: "unsafe" });
    expect(f.messages.at(-1).error.code).toBe("invalid_request");
    f.chrome.debugger.getTargets = async () => { throw new Error("secret URL /Users/private"); };
    const reply = await f.request("inventory");
    expect(reply.error.code).toBe("chrome_operation_failed");
    expect(JSON.stringify(reply)).not.toContain("secret");
  });
  test("oversized input suspends the bridge without any Chrome action", async () => {
    const f = fixture(); await f.setup();
    await f.bridge.receive({ junk: "a".repeat(MAX_MESSAGE_BYTES) });
    expect(f.bridge.status().suspended).toBe(true);
    expect(f.calls).toEqual([]);
  });
  test("oversized non-AX result remains a bounded error", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    f.chrome.debugger.sendCommand = async () => ({ unexpected: "x".repeat(MAX_MESSAGE_BYTES) });
    const reply = await f.command(attachmentToken, "Accessibility.enable");
    expect(reply.error.code).toBe("response_too_large");
    expect(JSON.stringify(reply).length).toBeLessThan(1024);
  });
  test("AX projection removes name-computation sources without losing semantic or action identity", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    const node = { nodeId: "node-1", parentId: "parent-1", childIds: ["child-1"], backendDOMNodeId: 42,
      ignored: false, role: { type: "role", value: "textbox" },
      name: { type: "computedString", value: "Exact Unicode 🧪 title", sources: [{ value: "x".repeat(MAX_MESSAGE_BYTES) }] },
      value: { type: "string", value: "Unchanged input" },
      properties: [
        { name: "disabled", value: { type: "boolean", value: false } },
        { name: "readonly", value: { type: "boolean", value: true } },
        { name: "focusable", value: { type: "boolean", value: true } },
        { name: "editable", value: { type: "token", value: "plaintext" } },
        { name: "url", value: { type: "string", value: "https://example.com/read?x=1" } },
      ] };
    f.chrome.debugger.sendCommand = async () => ({ nodes: [node] });
    const reply = await f.command(attachmentToken, "Accessibility.getFullAXTree", { depth: 64 });
    expect(reply.ok).toBe(true);
    expect(reply.result.nodes[0]).toEqual({ ...node, name: { type: "computedString", value: "Exact Unicode 🧪 title" } });
    expect(reply.result.macrouseSourceTruncated).toBe(false);
    expect(reply.result.macrouseSourceNodeCount).toBe(1);
    expect(JSON.stringify(reply).length).toBeLessThan(2048);
  });
  test("wide AX projection keeps a byte-bounded prefix and explicitly marks unreturned nodes", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    const nodes = Array.from({ length: 5000 }, (_, index) => ({ nodeId: `node-${index}`,
      backendDOMNodeId: index + 1, ignored: false, role: { value: "heading" }, name: { value: `Title ${index} 🧪`.repeat(10) } }));
    f.chrome.debugger.sendCommand = async () => ({ nodes });
    const reply = await f.command(attachmentToken, "Accessibility.getFullAXTree", { depth: 64 });
    expect(reply.ok).toBe(true);
    expect(reply.result.macrouseSourceTruncated).toBe(true);
    expect(reply.result.macrouseSourceNodeCount).toBe(5000);
    expect(reply.result.nodes.length).toBeGreaterThan(200);
    expect(reply.result.nodes.length).toBeLessThan(5000);
    expect(reply.result.nodes.at(-1)).toEqual(nodes[reply.result.nodes.length - 1]);
    expect(new TextEncoder().encode(JSON.stringify(reply)).byteLength).toBeLessThan(MAX_MESSAGE_BYTES);
  });
  test("one oversized semantic node is omitted whole, never text-truncated into an actionable identity", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    f.chrome.debugger.sendCommand = async () => ({ nodes: [{ backendDOMNodeId: 1, name: { value: "x".repeat(MAX_MESSAGE_BYTES) } }] });
    const reply = await f.command(attachmentToken, "Accessibility.getFullAXTree", { depth: 64 });
    expect(reply.ok).toBe(true);
    expect(reply.result.nodes).toEqual([]);
    expect(reply.result.macrouseSourceTruncated).toBe(true);
  });
  test("DOM clickability requires an observed main frame before dispatch", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    const reply = await f.command(attachmentToken, "DOMSnapshot.captureSnapshot", { computedStyles: [...CLICKABILITY_STYLES] });
    expect(reply.error.code).toBe("stale_frame");
    expect(f.calls.filter(call => call[0] === "command")).toHaveLength(0);
  });
  test("DOM clickability crosses the bridge only as a bounded main-document projection", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    await f.command(attachmentToken, "Page.getFrameTree");
    f.chrome.debugger.sendCommand = async (target, method, params) => {
      f.calls.push(["command", target, method, params]);
      return { strings: ["frame-1", "https://example.com/", "Private document body"], documents: [{
        frameId: 0, documentURL: 1, nodes: { backendNodeId: [1, 2, 3],
          isClickable: { index: [1] }, nodeValue: [2], attributes: [[2, 2]] },
        layout: { nodeIndex: [], styles: [], bounds: [] },
      }] };
    };
    const reply = await f.command(attachmentToken, "DOMSnapshot.captureSnapshot", { computedStyles: [...CLICKABILITY_STYLES] });
    expect(reply.ok).toBe(true);
    expect(reply.result).toEqual({ mactopusClickability: { frameId: "frame-1",
      documentURL: "https://example.com/", clickableBackendNodeIds: [2],
      pointerBackendNodeIds: [], sourceTruncated: false, sourceNodeCount: 3 } });
    expect(JSON.stringify(reply)).not.toContain("Private document");
    expect(f.calls.filter(call => call[0] === "command").map(call => call[2]))
      .toEqual(["Page.getFrameTree", "DOMSnapshot.captureSnapshot"]);
  });
  test("DOM provenance failure is redacted and does not escalate or revoke pairing", async () => {
    const f = fixture(); await f.setup(); const attachmentToken = await f.attach();
    await f.command(attachmentToken, "Page.getFrameTree");
    f.chrome.debugger.sendCommand = async () => ({ strings: ["frame-1", "https://private.example/"],
      documents: [{ frameId: 0, documentURL: 1, nodes: { backendNodeId: [1], isClickable: { index: [0] } } }] });
    const reply = await f.command(attachmentToken, "DOMSnapshot.captureSnapshot", { computedStyles: [...CLICKABILITY_STYLES] });
    expect(reply.error.code).toBe("invalid_document");
    expect(JSON.stringify(reply)).not.toContain("private.example");
    expect(f.bridge.status().paired).toBe(true);
    expect((await f.request("ping")).ok).toBe(true);
  });
});

describe("revocation races never replay mutations", () => {
  test("authenticated native forget bypasses a pending browser request and revokes immediately", async () => {
    const f = fixture(); await f.setup();
    let release;
    f.chrome.debugger.getTargets = () => new Promise(resolve => { release = resolve; });
    const pending = f.request("inventory");
    await Promise.resolve(); await Promise.resolve();
    const revoked = await f.request("revokePair", { installationId: f.bridge.state.installationId, pairingToken: token }, "forget-generation");
    expect(revoked.ok).toBe(true);
    expect(f.bridge.generation).toBeNull();
    expect(f.bridge.status().paired).toBe(false);
    release(f.targets);
    expect((await pending).error.code).toBe("unauthorized");
  });
  test("cancel while inventory awaits prevents subsequent attach", async () => {
    const f = fixture(); await f.setup();
    let release;
    f.chrome.debugger.getTargets = () => new Promise(resolve => { release = resolve; });
    const pending = f.request("attach", { targetID: "target-one" });
    await Promise.resolve(); await Promise.resolve();
    await f.bridge.revoke({ suspend: true });
    release(f.targets);
    expect((await pending).error.code).toBe("unauthorized");
    expect(f.calls.filter(call => call[0] === "attach")).toHaveLength(0);
  });
  test("cancel during attach detaches the late attachment", async () => {
    const f = fixture(); await f.setup();
    let release;
    f.chrome.debugger.attach = () => new Promise(resolve => { release = resolve; });
    const pending = f.request("attach", { targetID: "target-one" });
    for (let i = 0; i < 16; i++) await Promise.resolve();
    await f.bridge.revoke({ suspend: true });
    release();
    expect((await pending).error.code).toBe("unauthorized");
    expect(f.calls).toContainEqual(["detach", { targetId: "target-one" }]);
  });
  test("a queued request cannot survive disconnect", async () => {
    const f = fixture(); await f.setup();
    let release;
    f.chrome.debugger.getTargets = () => new Promise(resolve => { release = resolve; });
    const first = f.request("inventory");
    const second = f.request("attach", { targetID: "target-one" });
    await Promise.resolve(); await Promise.resolve();
    await f.bridge.receive({ version: 1, event: "appDisconnected" });
    release(f.targets);
    expect((await first).ok).toBe(false);
    expect((await second).error.code).toBe("revoked");
    expect(f.calls.filter(call => call[0] === "attach")).toHaveLength(0);
  });
  test("a hung Chrome inventory times out without wedging a fresh session", async () => {
    const f = fixture({}, { commandTimeoutMs: 5, cleanupTimeoutMs: 5 }); await f.setup();
    f.chrome.debugger.getTargets = () => new Promise(() => {});
    expect((await f.request("inventory")).error.code).toBe("chrome_timeout");
    expect(f.bridge.status().connected).toBe(false);
    f.chrome.debugger.getTargets = async () => f.targets;
    expect((await f.authorize("g2")).ok).toBe(true);
    expect((await f.request("inventory", {}, "g2")).ok).toBe(true);
  });
  test("a late successful attach after timeout is detached, never adopted", async () => {
    const f = fixture({}, { commandTimeoutMs: 5, cleanupTimeoutMs: 5 }); await f.setup();
    let release;
    f.chrome.debugger.attach = () => new Promise(resolve => { release = resolve; });
    expect((await f.request("attach", { targetID: "target-one" })).error.code).toBe("chrome_timeout");
    const before = f.calls.length;
    release();
    for (let i = 0; i < 8; i++) await Promise.resolve();
    expect(f.calls.length).toBeGreaterThan(before);
    expect(f.bridge.attachments.size).toBe(0);
  });
  test("a hung mutation is never replayed and late result cannot regain authority", async () => {
    const f = fixture({}, { commandTimeoutMs: 5, cleanupTimeoutMs: 5 }); await f.setup();
    const attachmentToken = await f.attach();
    await f.command(attachmentToken, "Page.getFrameTree");
    await f.command(attachmentToken, "Page.createIsolatedWorld", { frameId: "frame-1", worldName: "LocalCodexBrowserBroker" });
    await f.command(attachmentToken, "DOM.resolveNode", { backendNodeId: 12, executionContextId: 7, objectGroup: group });
    let count = 0, release;
    f.chrome.debugger.sendCommand = () => { count++; return new Promise(resolve => { release = resolve; }); };
    expect((await f.command(attachmentToken, "Runtime.callFunctionOn", { objectId: "object-1", functionDeclaration: PRESS_FUNCTION,
      arguments: [{ value: "https://example.com/" }], returnByValue: true, awaitPromise: true, userGesture: true })).error.code).toBe("chrome_timeout");
    release({});
    expect(count).toBe(1);
    expect(f.bridge.generation).toBeNull();
  });
});

describe("shipping surface contracts", () => {
  test("manifest pins expected development identity without ambient privileges", async () => {
    const manifest = JSON.parse(await readFile(new URL("manifest.json", import.meta.url), "utf8"));
    const id = [...createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32)]
      .map(char => String.fromCharCode(97 + parseInt(char, 16))).join("");
    expect(id).toBe("gdghbmoiibghgkfmhjlckipjjlclnlbk");
    expect(manifest.permissions).toEqual(["debugger", "nativeMessaging", "storage"]);
    for (const key of ["host_permissions", "content_scripts", "externally_connectable", "web_accessible_resources"]) expect(manifest).not.toHaveProperty(key);
    expect(manifest.minimum_chrome_version).toBe("125");
  });
  test("fixed functions match current Swift native broker byte for byte", async () => {
    const source = await readFile(new URL("../Sources/Computa/Runtime/BrowserCDPDocumentOperations.swift", import.meta.url), "utf8");
    const templates = [...source.matchAll(/"functionDeclaration": """\n([\s\S]*?)\n(\s*)"""/g)]
      .map(match => match[1].split("\n").map(line => line.slice(match[2].length)).join("\n"));
    expect(templates).toEqual([PRESS_FUNCTION, SET_TEXT_FUNCTION]);
  });
});
