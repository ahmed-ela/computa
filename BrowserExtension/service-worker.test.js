import { expect, test } from "bun:test";
import { startChromeBridge } from "./service-worker.js";

function event() {
  const listeners = [];
  return { addListener: listener => listeners.push(listener), listeners, emit: (...args) => listeners.map(listener => listener(...args)) };
}
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
function fixture(state = undefined) {
  const connections = [], timers = [], stored = { macndashChromeBridgeV1: state };
  const id = "gdghbmoiibghgkfmhjlckipjjlclnlbk";
  const chrome = {
    runtime: { id, getURL: path => `chrome-extension://${id}/${path}`,
      onStartup: event(), onInstalled: event(), onMessage: event(),
      connectNative: name => {
        const port = { name, onMessage: event(), onDisconnect: event(), sent: [],
          postMessage(message) { this.sent.push(structuredClone(message)); },
          disconnect() { this.disconnected = true; this.onDisconnect.emit(); } };
        connections.push(port); return port;
      },
    },
    debugger: { onDetach: event(), detach: async () => {} },
    tabs: { onActivated: event(), onRemoved: event(), onUpdated: event() },
    storage: { local: { get: async () => structuredClone(stored), set: async value => Object.assign(stored, structuredClone(value)) } },
  };
  const worker = startChromeBridge(chrome, { schedule: callback => { timers.push(callback); return timers.length; },
    cancelSchedule: index => { timers[index - 1] = null; } });
  const send = (action, sender = { id, url: chrome.runtime.getURL("popup.html") }) => new Promise(resolve => {
    const keepOpen = chrome.runtime.onMessage.listeners[0]({ action }, sender, resolve);
    if (!keepOpen) resolve(undefined);
  });
  return { worker, chrome, connections, timers, send, stored };
}
const paired = { installationId: "installation", pairingToken: "a".repeat(64), suspended: false };

test("an unpaired worker does not open a native port merely by loading", async () => {
  const f = fixture(); await f.worker.ready; await flush();
  expect(f.connections).toHaveLength(0);
  const reply = await f.send("pair");
  expect(reply.ok).toBe(true);
  expect(f.connections).toHaveLength(1);
  expect(f.connections[0].name).toBe("com.macndash.chrome_bridge");
  expect(f.connections[0].sent.map(message => message.event)).toEqual(["hello", "pairRequested"]);
});

test("popup capabilities reject webpage, content-script and unrelated-extension senders", async () => {
  const f = fixture(); await f.worker.ready;
  for (const sender of [
    { id: f.chrome.runtime.id, url: "https://example.com/" },
    { id: f.chrome.runtime.id, url: f.chrome.runtime.getURL("popup.html"), tab: { id: 1 } },
    { id: "different-extension", url: f.chrome.runtime.getURL("popup.html") },
    { id: f.chrome.runtime.id, url: f.chrome.runtime.getURL("unrelated.html") },
  ]) expect(await f.send("pair", sender)).toBeUndefined();
  expect(f.connections).toHaveLength(0);
});

test("stored pairing auto-connects once despite repeated startup/install events", async () => {
  const f = fixture(paired); await f.worker.ready; await flush();
  f.chrome.runtime.onStartup.emit(); f.chrome.runtime.onInstalled.emit(); await flush();
  expect(f.connections).toHaveLength(1);
  expect(f.connections[0].sent[0].pairingToken).toBe(paired.pairingToken);
  const status = await f.send("status");
  expect(status.result).not.toHaveProperty("pairingToken");
});

test("a saved cancellation does not reconnect until explicit popup Resume", async () => {
  const f = fixture({ ...paired, suspended: true }); await f.worker.ready; await flush();
  expect(f.connections).toHaveLength(0);
  expect((await f.send("resume")).ok).toBe(true);
  expect(f.connections).toHaveLength(1);
  expect(f.worker.bridge.status().suspended).toBe(false);
});

test("host loss revokes the session and schedules only a bounded reconnect", async () => {
  const f = fixture(paired); await f.worker.ready; await flush();
  f.worker.bridge.generation = "g1";
  f.connections[0].disconnect(); await flush();
  expect(f.worker.bridge.generation).toBeNull();
  expect(f.timers).toHaveLength(1);
  f.timers[0](); await flush();
  expect(f.connections).toHaveLength(2);
  expect(f.connections[1].sent.map(message => message.event)).toEqual(["hello"]);
  f.worker.bridge.generation = "new-generation";
  f.connections[0].onMessage.emit({ version: 1, event: "appDisconnected" }); await flush();
  expect(f.worker.bridge.generation).toBe("new-generation");
});

test("Chrome Cancel closes the native port and does not reconnect", async () => {
  const f = fixture(paired); await f.worker.ready; await flush();
  f.worker.bridge.generation = "g1";
  f.worker.bridge.attachments.set("token", { attachmentToken: "token", targetID: "target", tabId: 7 });
  f.chrome.debugger.onDetach.emit({ tabId: 7 }, "canceled_by_user"); await flush();
  expect(f.worker.bridge.status().suspended).toBe(true);
  expect(f.connections[0].disconnected).toBe(true);
  expect(f.timers.filter(Boolean)).toHaveLength(0);
});

test("popup forget disconnects and never schedules a native-port restart", async () => {
  const f = fixture(paired); await f.worker.ready; await flush();
  expect((await f.send("forget")).ok).toBe(true); await flush();
  expect(f.connections[0].disconnected).toBe(true);
  expect(f.worker.bridge.status().paired).toBe(false);
  expect(f.timers.filter(Boolean)).toHaveLength(0);
});

test("app reconnect handshake sends current hello instead of buffered actions", async () => {
  const f = fixture(paired); await f.worker.ready; await flush();
  const port = f.connections[0];
  f.worker.bridge.generation = "old-generation";
  port.onMessage.emit({ version: 1, event: "appDisconnected" }); await flush();
  port.onMessage.emit({ version: 1, event: "requestHello" }); await flush();
  expect(f.worker.bridge.generation).toBeNull();
  expect(port.sent.map(message => message.event)).toEqual(["hello", "hello", "hello"]);
  expect(f.connections).toHaveLength(1);
});

test("temporary-tab ownership observes Chrome activation, removal and update events", async () => {
  const f = fixture(); await f.worker.ready;
  const calls = [];
  for (const name of ["onActivated", "onRemoved", "onUpdated"]) {
    f.worker.bridge.temporaryTabs[name] = (...args) => { calls.push([name, ...args]); };
  }
  f.worker.bridge.webProviders.onRemoved = tabId => { calls.push(["providerRemoved", tabId]); };
  f.chrome.tabs.onActivated.emit({ tabId: 11 });
  f.chrome.tabs.onRemoved.emit(12);
  f.chrome.tabs.onUpdated.emit(13, { pinned: true }, { id: 13, active: false });
  await flush();
  expect(calls).toEqual([["onActivated", { tabId: 11 }], ["onRemoved", 12], ["providerRemoved", 12],
    ["onUpdated", 13, { pinned: true }, { id: 13, active: false }]]);
  expect(f.connections).toEqual([]);
});
