import { ChromeBridge, HOST_NAME } from "./bridge.js";

export function startChromeBridge(chrome, { schedule = setTimeout, cancelSchedule = clearTimeout } = {}) {
let port = null;
let reconnectTimer = null;
let retryCount = 0;
const bridge = new ChromeBridge({ chrome, emit: message => {
  if (port) { try { port.postMessage(message); } catch { /* onDisconnect revokes authority */ } }
} });
const ready = bridge.initialize();

function connect() {
  if (port) return;
  try {
    const connection = chrome.runtime.connectNative(HOST_NAME);
    port = connection;
    connection.onMessage.addListener(message => {
      if (port !== connection) return;
      void bridge.receive(message).then(() => {
        if (message?.operation === "authorizeSession" && bridge.generation === message.generation) retryCount = 0;
        // Allow revokePair's response to reach the app before ending its native port.
        // The host signals this only after the app acknowledges by closing its link.
        if (message?.event === "appDisconnected" && !bridge.status().paired && bridge.status().suspended && port === connection) {
          port = null;
          connection.disconnect();
        }
      });
    });
    connection.onDisconnect.addListener(() => {
      // Never expose Chrome's diagnostic payload; it may contain installation paths.
      void chrome.runtime.lastError;
      if (port !== connection) return;
      port = null;
      void bridge.hostDisconnected().then(() => {
        if (bridge.status().paired && !bridge.status().suspended && retryCount < 5) {
          const delay = Math.min(1000 * 2 ** retryCount++, 16_000);
          reconnectTimer = schedule(() => { reconnectTimer = null; connect(); }, delay);
        }
      });
    });
    bridge.hello();
  } catch { void bridge.hostDisconnected(); }
}

chrome.debugger.onDetach.addListener((source, reason) => {
  void ready.then(() => bridge.onDetach(source, reason)).then(() => {
    if (bridge.status().suspended && port) {
      const oldPort = port;
      port = null;
      oldPort.disconnect();
    }
  });
});
chrome.tabs.onActivated.addListener(info => { void ready.then(() => bridge.temporaryTabs.onActivated(info)); });
chrome.tabs.onRemoved.addListener(tabId => {
  void ready.then(() => Promise.allSettled([bridge.temporaryTabs.onRemoved(tabId), bridge.webProviders.onRemoved(tabId)]));
});
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  void ready.then(() => bridge.temporaryTabs.onUpdated(tabId, changeInfo, tab));
});
chrome.runtime.onStartup.addListener(() => { void ready.then(() => { if (bridge.status().paired && !bridge.status().suspended) connect(); }); });
chrome.runtime.onInstalled.addListener(() => { void ready.then(() => { if (bridge.status().paired && !bridge.status().suspended) connect(); }); });
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL("popup.html") || sender.tab) return false;
  void ready.then(async () => {
    if (message?.action === "status") return bridge.status();
    if (message?.action === "pair") { retryCount = 0; connect(); await bridge.requestPairing(); return bridge.status(); }
    if (message?.action === "resume") { retryCount = 0; connect(); await bridge.resumeFromPopup(); return bridge.status(); }
    if (message?.action === "forget") {
      if (reconnectTimer) cancelSchedule(reconnectTimer);
      reconnectTimer = null;
      await bridge.revoke({ suspend: true, forget: true });
      bridge.hello();
      if (port) { const oldPort = port; port = null; oldPort.disconnect(); }
      return bridge.status();
    }
    throw new Error("Unknown popup action");
  }).then(result => sendResponse({ ok: true, result }), () => sendResponse({ ok: false, error: "The bridge could not complete that request. Open Computa and try again." }));
  return true;
});
void ready.then(() => { if (bridge.status().paired && !bridge.status().suspended) connect(); });
return { ready, bridge };
}

if (globalThis.chrome?.runtime?.id) startChromeBridge(globalThis.chrome);
