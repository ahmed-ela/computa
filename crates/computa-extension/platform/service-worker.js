import init, { ExtensionEngine } from "./computa_extension.js";

// Only Chrome's asynchronous API and MV3 event boundary lives here. Every
// admission, authority, retry, selector and lifecycle decision is in Rust.
let engine, port, effectQueue = Promise.resolve();
const ports = new Map();
const waiting = [], popupReplies = new Map();
let popupSequence = 0;
const now = () => Math.trunc(performance.now());
function deliver(event) {
  if (!engine) { waiting.push(event); return; }
  const effects = engine.dispatch(event);
  for (const effect of effects) execute(effect);
}
function execute(effect) {
  if (effect.kind === "store") {
    effectQueue = effectQueue.then(() => chrome.storage[effect.area].set(effect.value));
    effectQueue = effectQueue.catch(() => deliver({ kind: "storageFailed", now: now() }));
  } else if (effect.kind === "chrome") {
    void effectQueue.then(() => {
      if (!engine.permits(effect.id)) return;
      const calls = {
        "debugger.getTargets": args => chrome.debugger.getTargets(...args),
        "debugger.attach": args => chrome.debugger.attach(...args),
        "debugger.detach": args => chrome.debugger.detach(...args),
        "debugger.sendCommand": args => chrome.debugger.sendCommand(...args),
        "tabs.get": args => chrome.tabs.get(...args),
        "tabs.create": args => chrome.tabs.create(...args),
        "tabs.remove": args => chrome.tabs.remove(...args),
      };
      let completed = false;
      const timer = setTimeout(() => {
        if (!completed) deliver({ kind: "chromeReply", id: effect.id, result: null, error: "timeout", now: now() });
      }, effect.timeoutMs);
      let operation;
      try { operation = calls[effect.api](effect.params); }
      catch { operation = Promise.reject(); }
      Promise.resolve(operation).then(result => {
        completed = true; clearTimeout(timer);
        // Late results are still delivered to Rust's retired exact-receipt
        // ledger. The host never adopts or retries a browser operation.
        deliver({ kind: "chromeReply", id: effect.id, result: result ?? {}, error: null, now: now() });
      }, () => {
        completed = true; clearTimeout(timer);
        deliver({ kind: "chromeReply", id: effect.id, result: null, error: "failed", now: now() });
      });
    });
  } else if (effect.kind === "emit") {
    void effectQueue.then(() => { try { ports.get(effect.connection)?.postMessage(effect.message); } catch {} });
  } else if (effect.kind === "connect") {
    try {
      const connection = chrome.runtime.connectNative(effect.host);
      port = connection;
      ports.set(effect.id, connection);
      connection.onMessage.addListener(message => deliver({ kind: "native", message, connection: effect.id, now: now() }));
      connection.onDisconnect.addListener(() => {
        void chrome.runtime.lastError;
        if (port === connection) port = null;
        ports.delete(effect.id);
        deliver({ kind: "hostDisconnected", connection: effect.id, now: now() });
      });
    } catch { deliver({ kind: "hostDisconnected", connection: effect.id, now: now() }); }
  } else if (effect.kind === "disconnect") {
    const old = port; port = null; old?.disconnect();
  } else if (effect.kind === "schedule") {
    setTimeout(() => deliver({ kind: "timer", token: effect.token, now: now() }), effect.afterMs);
  } else if (effect.kind === "popupReply") {
    popupReplies.get(effect.id)?.(effect.value); popupReplies.delete(effect.id);
  }
}
chrome.debugger.onDetach.addListener((source, reason) => deliver({ kind: "detached", source, reason, now: now() }));
chrome.tabs.onActivated.addListener(info => deliver({ kind: "activated", tabId: info.tabId, now: now() }));
chrome.tabs.onRemoved.addListener(tabId => deliver({ kind: "removed", tabId, now: now() }));
chrome.tabs.onUpdated.addListener((tabId, change, tab) => deliver({ kind: "updated", tabId, change, tab, now: now() }));
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (engine && !engine.accepts_popup(sender)) return false;
  const id = ++popupSequence; popupReplies.set(id, sendResponse);
  deliver({ kind: "popup", action: typeof message?.action === "string" ? message.action : "", sender, id, now: now() });
  return true;
});
await init();
engine = new ExtensionEngine(crypto.randomUUID(), chrome.runtime.id, crypto.randomUUID());
const [local, session] = await Promise.all([chrome.storage.local.get(null), chrome.storage.session.get(null)]);
deliver({ kind: "bootstrap", local, session, now: now() });
for (const event of waiting.splice(0)) deliver(event);
