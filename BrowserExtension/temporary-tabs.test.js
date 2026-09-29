import { describe, expect, test } from "bun:test";
import { ChromeBridge } from "./bridge.js";
import { PRESS_FUNCTION } from "./commands.js";

const task = "12345678-1234-4234-8234-123456789abc";
const otherTask = "22345678-1234-4234-8234-123456789abc";
const sourceURL = "https://example.com/observed?x=one#fragment";
const token = "a".repeat(64);
const params = (taskNonce = task) => ({ sourceTargetID: "source", expectedSourceURL: sourceURL, taskNonce });
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

async function fixture({ grant = true, ...options } = {}) {
  let sequence = 0, requestSequence = 0, tabSequence = 10;
  const messages = [], calls = [];
  const targets = [{ id: "source", type: "page", tabId: 1, title: "Existing draft", url: sourceURL, attached: false },
    { id: "same-url-borrowed", type: "page", tabId: 2, title: "Existing draft", url: sourceURL, attached: false }];
  const tabs = new Map([[1, { id: 1, windowId: 7, active: true, pinned: false, url: sourceURL }],
    [2, { id: 2, windowId: 7, active: false, pinned: false, url: sourceURL }]]);
  const stored = {};
  let bridge;
  const chrome = {
    runtime: { id: "extension" },
    storage: { local: { get: async () => structuredClone(stored), set: async value => Object.assign(stored, structuredClone(value)) } },
    debugger: {
      getTargets: async () => structuredClone(targets),
      attach: async ({ targetId }) => { calls.push(["attach", targetId]); targets.find(value => value.id === targetId).attached = true; },
      detach: async ({ targetId }) => {
        calls.push(["detach", targetId]);
        const target = targets.find(value => value.id === targetId); if (target) target.attached = false;
        await bridge.onDetach({ targetId }, "canceled_by_user");
      },
      sendCommand: async () => ({}),
    },
    tabs: {
      get: async id => { calls.push(["get", id]); if (!tabs.has(id)) throw new Error("missing"); return structuredClone(tabs.get(id)); },
      create: async options => {
        calls.push(["create", structuredClone(options)]);
        const id = ++tabSequence;
        const tab = { id, windowId: options.windowId, active: options.active, url: options.url, pinned: false };
        tabs.set(id, tab);
        targets.push({ id: `temporary-${id}`, type: "page", tabId: id, title: "Temporary", url: options.url, attached: false });
        return structuredClone(tab);
      },
      remove: async id => {
        calls.push(["remove", id]); tabs.delete(id);
        const index = targets.findIndex(value => value.tabId === id); if (index >= 0) targets.splice(index, 1);
        await bridge.temporaryTabs.onRemoved(id);
      },
      update: async () => { throw new Error("must never update or activate a tab"); },
    },
  };
  bridge = new ChromeBridge({ chrome, emit: value => messages.push(structuredClone(value)),
    uuid: () => `00000000-0000-4000-8000-${String(++sequence).padStart(12, "0")}`,
    temporarySettlementTimeoutMs: 20, temporarySettlementPollMs: 1, ...options });
  const request = async (operation, params = {}, generation = "g1") => {
    const id = `request-${++requestSequence}`;
    await bridge.receive({ version: 1, id, operation, params, generation });
    return messages.findLast(value => value.id === id);
  };
  const authorize = (version, generation = "g1") => request("authorizeSession", {
    installationId: bridge.state.installationId, pairingToken: token, ...(version === undefined ? {} : { temporaryTabsVersion: version }),
  }, generation);
  const create = (overrides = {}) => request("createTemporary", { ...params(), ...overrides });
  const release = (receipt, overrides = {}, generation = "g1") => request("releaseTemporary", {
    leaseToken: receipt.leaseToken, taskNonce: receipt.taskNonce, ...overrides,
  }, generation);
  await bridge.initialize(); await bridge.requestPairing();
  await request("approvePair", { installationId: bridge.state.installationId, pairingNonce: bridge.pairingNonce, pairingToken: token });
  await authorize(grant ? 1 : undefined);
  return { chrome, bridge, targets, tabs, stored, messages, calls, request, authorize, create, release };
}

describe("versioned temporary-tab authority", () => {
  test("ping advertises support but an old grant does not authorize creation or release", async () => {
    const f = await fixture({ grant: false });
    expect((await f.request("ping")).result.capabilities).toEqual({ temporaryTabsVersion: 1 });
    expect((await f.create()).error.code).toBe("temporary_tabs_not_authorized");
    expect((await f.release({ leaseToken: "invented", taskNonce: task })).error.code).toBe("temporary_tabs_not_authorized");
    expect(f.calls).toEqual([]);
  });

  test("pre-auth hello and user pairing proposal advertise support without granting it", async () => {
    const f = await fixture({ grant: false });
    expect(f.bridge.hello().capabilities).toEqual({ temporaryTabsVersion: 1 });
    const proposal = f.messages.find(value => value.event === "pairRequested");
    expect(proposal.capabilities).toEqual({ temporaryTabsVersion: 1 });
    expect(f.bridge.temporaryTabs.authorizedVersion).toBeNull();
  });

  test("unknown versions and extra capability flags fail closed", async () => {
    const f = await fixture({ grant: false });
    for (const value of [0, 2, true, "1", null]) expect((await f.authorize(value, `g-${value}`)).ok).toBe(false);
    expect(f.bridge.temporaryTabs.authorizedVersion).toBeNull();
  });

  test("creates an exact inactive clone in the same window and releases only its receipt", async () => {
    const f = await fixture();
    const receipt = (await f.create()).result;
    expect(receipt).toEqual({ leaseToken: expect.any(String), taskNonce: task, targetID: "temporary-11",
      title: "Temporary", url: sourceURL, availability: "available" });
    expect(f.calls.filter(value => value[0] === "create")).toEqual([["create", { url: sourceURL, active: false, windowId: 7 }]]);
    expect((await f.release(receipt)).result).toEqual({ released: true, closed: true, retained: false });
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([["remove", 11]]);
    expect([...f.tabs.keys()]).toEqual([1, 2]);
    expect(f.bridge.state.suspended).toBe(false);
  });

  test("Chrome URL metadata is not required from tabs API; exact debugger identity supplies it", async () => {
    const f = await fixture(); const get = f.chrome.tabs.get, create = f.chrome.tabs.create;
    f.chrome.tabs.get = async id => { const tab = await get(id); delete tab.url; return tab; };
    f.chrome.tabs.create = async options => { const tab = await create(options); delete tab.url; return tab; };
    const response = await f.create(); expect(response.ok).toBe(true);
    expect((await f.release(response.result)).result.closed).toBe(true);
  });

  test("unchanged duplicates return one lease and cannot recreate after release", async () => {
    const f = await fixture(); const first = (await f.create()).result;
    expect((await f.create()).result).toEqual(first);
    expect((await f.create({ sourceTargetID: "same-url-borrowed" })).error.code).toBe("temporary_task_already_used");
    await f.release(first);
    expect((await f.create()).error.code).toBe("temporary_task_already_used");
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(1);
    expect((await f.release(first)).result.closed).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toHaveLength(1);
  });

  test("forged, wrong-task and stale-generation release never touches borrowed tabs", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    for (const overrides of [{ leaseToken: "source" }, { taskNonce: otherTask }, { leaseToken: "temporary-11" }]) {
      expect((await f.release(receipt, overrides)).error.code).toBe("stale_temporary_lease");
    }
    expect((await f.release(receipt, {}, "different-generation")).error.code).toBe("unauthorized");
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("rejects model navigation/activation/close parameters and malformed task IDs", async () => {
    const f = await fixture();
    for (const overrides of [{ url: "https://other.example/" }, { active: true }, { tabId: 1 }, { taskNonce: "invented" }]) {
      expect((await f.create(overrides)).error.code).toBe("invalid_request");
    }
    expect(f.calls).toEqual([]);
  });

  test("busy and unknown source availability cannot be bypassed by cloning", async () => {
    const f = await fixture();
    f.targets[0].attached = true; expect((await f.create()).error.code).toBe("target_busy");
    delete f.targets[0].attached; expect((await f.create()).error.code).toBe("target_busy");
    expect(f.calls).toEqual([]);
  });

  test("changed observed source URL is not silently replaced by live URL", async () => {
    const f = await fixture(); f.targets[0].url = "https://example.com/different";
    expect((await f.create()).error.code).toBe("target_unavailable");
    expect(f.calls).toEqual([]);
  });

  test("source ownership and URL are rechecked after tabs.get", async () => {
    for (const change of [target => { target.attached = true; }, target => { target.url = "https://other.example/"; }]) {
      const f = await fixture(); const get = f.chrome.tabs.get;
      f.chrome.tabs.get = async id => { const tab = await get(id); change(f.targets[0]); return tab; };
      expect((await f.create()).error.code).toBe("target_busy");
      expect(f.calls.filter(value => value[0] === "create")).toEqual([]);
    }
  });

  test("restricts eligible source URLs and missing exact targets", async () => {
    const f = await fixture();
    for (const url of ["chrome://settings", "file:///private/file", "javascript:alert(1)"]) {
      expect((await f.create({ expectedSourceURL: url })).error.code).toBe("invalid_request");
    }
    expect((await f.create({ sourceTargetID: "missing" })).error.code).toBe("target_unavailable");
    expect(f.calls).toEqual([]);
  });

  test("limits active leases globally without closing or replacing one to make room", async () => {
    const f = await fixture();
    for (let i = 0; i < 4; i++) expect((await f.create({ taskNonce: `${i}2345678-1234-4234-8234-123456789abc` })).ok).toBe(true);
    expect((await f.create({ taskNonce: "92345678-1234-4234-8234-123456789abc" })).error.code).toBe("capacity_exceeded");
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(4);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });
});

describe("temporary-tab takeover and cleanup", () => {
  test("activation revokes an existing attachment and retains the tab even after user switches away", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    const attachment = (await f.request("attach", { targetID: receipt.targetID })).result;
    f.tabs.get(11).active = true; await f.bridge.temporaryTabs.onActivated({ tabId: 11 });
    f.tabs.get(11).active = false;
    expect((await f.request("attach", { targetID: receipt.targetID })).error.code).toBe("stale_temporary_lease");
    expect((await f.request("command", { attachmentToken: attachment.attachmentToken, method: "Accessibility.enable", params: {} })).error.code).toBe("stale_attachment");
    expect((await f.release(receipt)).result).toEqual({ released: true, closed: false, retained: true });
    await f.bridge.hostDisconnected();
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
    expect(f.bridge.state.suspended).toBe(false);
  });

  test("uncertain navigation retains and revokes instead of claiming user ownership", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    f.targets.find(value => value.tabId === 11).url = "https://other.example/";
    f.tabs.get(11).url = "https://other.example/";
    await f.bridge.temporaryTabs.onUpdated(11, { url: "https://other.example/" }, f.tabs.get(11));
    expect((await f.request("attach", { targetID: receipt.targetID })).error.code).toBe("stale_temporary_lease");
    expect((await f.release(receipt)).result.retained).toBe(true);
    expect(f.tabs.has(11)).toBe(true);
  });

  test("owned semantic navigation can settle but never proves safe automatic deletion", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    const attachment = (await f.request("attach", { targetID: receipt.targetID })).result;
    const item = f.bridge.attachments.get(attachment.attachmentToken);
    f.bridge.temporaryTabs.mutationStarted(item, "Runtime.callFunctionOn", { functionDeclaration: PRESS_FUNCTION });
    const url = "https://example.com/result";
    f.targets.find(value => value.tabId === 11).url = url; f.tabs.get(11).url = url;
    await f.bridge.temporaryTabs.onUpdated(11, { url }, f.tabs.get(11));
    expect(f.bridge.temporaryTabs.leases.get(receipt.leaseToken).status).toBe("active");
    expect(f.bridge.attachments.has(attachment.attachmentToken)).toBe(true);
    expect((await f.release(receipt)).result.retained).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("no mutation settling period overrides an explicit activation", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    const attachment = (await f.request("attach", { targetID: receipt.targetID })).result;
    f.bridge.temporaryTabs.mutationStarted(f.bridge.attachments.get(attachment.attachmentToken), "Runtime.callFunctionOn", { functionDeclaration: PRESS_FUNCTION });
    await f.bridge.temporaryTabs.onActivated({ tabId: 11 });
    expect(f.bridge.temporaryTabs.leases.get(receipt.leaseToken).status).toBe("retained");
    expect((await f.release(receipt)).result.retained).toBe(true);
  });

  test("expired mutation settlement does not authorize later independent navigation", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    f.bridge.temporaryTabs.leases.get(receipt.leaseToken).mutationDeadline = Date.now() - 1;
    await f.bridge.temporaryTabs.onUpdated(11, { url: "https://example.com/later" }, f.tabs.get(11));
    expect(f.bridge.temporaryTabs.leases.get(receipt.leaseToken).status).toBe("retained");
    expect((await f.release(receipt)).result.retained).toBe(true);
  });

  test("pinned or newly grouped tabs are retained", async () => {
    for (const changeInfo of [{ pinned: true }, { groupId: 42 }]) {
      const f = await fixture(); const receipt = (await f.create()).result;
      await f.bridge.temporaryTabs.onUpdated(11, changeInfo, f.tabs.get(11));
      expect((await f.release(receipt)).result.retained).toBe(true);
      expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
    }
  });

  test("release removes own attachment before detach so intentional cleanup never pauses access", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    await f.request("attach", { targetID: receipt.targetID });
    expect((await f.release(receipt)).result.closed).toBe(true);
    expect(f.bridge.state.suspended).toBe(false);
    const actionCalls = f.calls.filter(value => ["detach", "remove"].includes(value[0]));
    expect(actionCalls).toEqual([["detach", "temporary-11"], ["remove", 11]]);
  });

  test("host loss cleans exact unchanged owned tabs after detach, never same-URL existing tabs", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    await f.request("attach", { targetID: receipt.targetID });
    await f.request("attach", { targetID: "same-url-borrowed" });
    await f.bridge.hostDisconnected();
    expect([...f.tabs.keys()]).toEqual([1, 2]);
    expect(f.bridge.state.suspended).toBe(false);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([["remove", 11]]);
    expect(f.bridge.temporaryTabs.authorizedVersion).toBeNull();
    await f.authorize(undefined, "g2");
    expect((await f.request("createTemporary", params(), "g2")).error.code).toBe("temporary_tabs_not_authorized");
  });

  test("lost cleanup evidence retains rather than deleting a potentially repurposed tab", async () => {
    for (const mutate of [
      f => { f.tabs.get(11).active = true; },
      f => { f.targets.find(value => value.tabId === 11).id = "different-exact-target"; },
      f => { f.targets.find(value => value.tabId === 11).attached = true; },
      f => { f.chrome.tabs.get = async () => { throw new Error("unavailable"); }; },
    ]) {
      const f = await fixture(); const receipt = (await f.create()).result; mutate(f);
      expect((await f.release(receipt)).result.retained).toBe(true);
      expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
    }
  });

  test("worker restart does not adopt or close old receipt IDs from persisted state", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    const next = new ChromeBridge({ chrome: f.chrome, emit: () => {} });
    await next.initialize();
    expect(next.temporaryTabs.leases.size).toBe(0);
    expect(JSON.stringify(f.stored)).not.toContain(receipt.leaseToken);
    await next.hostDisconnected();
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("Chrome cancellation still pauses the bridge and native authorization cannot resume it", async () => {
    const f = await fixture(); const receipt = (await f.create()).result;
    await f.request("attach", { targetID: receipt.targetID });
    f.targets.find(value => value.tabId === 11).attached = false;
    await f.bridge.onDetach({ tabId: 11 }, "canceled_by_user");
    expect(f.bridge.state.suspended).toBe(true);
    expect((await f.authorize(1, "g2")).error.code).toBe("unauthorized");
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([["remove", 11]]);
  });
});

describe("temporary creation races", () => {
  test("initial blank receipt settles read-only to the exact requested URL without another create", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create, get = f.chrome.tabs.get;
    let reads = 0;
    f.chrome.tabs.create = async options => {
      const tab = await original(options);
      f.tabs.get(tab.id).url = "about:blank";
      f.tabs.get(tab.id).pendingUrl = sourceURL;
      f.targets.find(value => value.tabId === tab.id).url = "about:blank";
      await f.bridge.temporaryTabs.onUpdated(tab.id, { url: "about:blank" }, f.tabs.get(tab.id));
      return { ...tab, url: "about:blank", pendingUrl: sourceURL };
    };
    f.chrome.tabs.get = async id => {
      if (id === 11 && ++reads === 3) {
        f.tabs.get(id).url = sourceURL; delete f.tabs.get(id).pendingUrl;
        f.targets.find(value => value.tabId === id).url = sourceURL;
        await f.bridge.temporaryTabs.onUpdated(id, { url: sourceURL }, f.tabs.get(id));
      }
      return get(id);
    };
    const result = await f.create(); expect(result.ok).toBe(true); expect(reads).toBe(3);
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(1);
    expect((await f.release(result.result)).result.closed).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([["remove", 11]]);
  });

  test("pending requested URL and missing target may settle without replay", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create, getTargets = f.chrome.debugger.getTargets;
    let reads = 0, created = false;
    f.chrome.tabs.create = async options => { const tab = await original(options); created = true; f.tabs.get(tab.id).pendingUrl = sourceURL; return { ...tab, pendingUrl: sourceURL }; };
    f.chrome.debugger.getTargets = async () => {
      if (created && ++reads < 3) return f.targets.filter(value => value.tabId !== 11);
      if (created) delete f.tabs.get(11).pendingUrl;
      return getTargets();
    };
    const result = await f.create(); expect(result.ok).toBe(true);
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(1);
    expect((await f.release(result.result)).result.closed).toBe(true);
  });

  test("never-ready exact blank tab expires boundedly, retains safely, and does not create again", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => {
      const tab = await original(options); f.tabs.get(tab.id).url = "about:blank";
      f.targets.find(value => value.tabId === tab.id).url = "about:blank";
      return { ...tab, url: "about:blank" };
    };
    expect((await f.create()).error.code).toBe("target_unavailable");
    expect((await f.create()).error.code).toBe("temporary_task_already_used");
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(1);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("initial redirect away and back is not mistaken for the allowed blank-to-requested commit", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => {
      const tab = await original(options);
      await f.bridge.temporaryTabs.onUpdated(tab.id, { url: "https://example.com/unexpected" }, tab);
      await f.bridge.temporaryTabs.onUpdated(tab.id, { url: sourceURL }, tab);
      return tab;
    };
    expect((await f.create()).ok).toBe(false);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
    expect(f.tabs.has(11)).toBe(true);
  });

  test("activation during initial loading prevents settlement from publishing authority", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create, get = f.chrome.tabs.get;
    f.chrome.tabs.create = async options => {
      const tab = await original(options); f.tabs.get(tab.id).pendingUrl = sourceURL; return tab;
    };
    f.chrome.tabs.get = async id => { if (id === 11) await f.bridge.temporaryTabs.onActivated({ tabId: id }); return get(id); };
    expect((await f.create()).ok).toBe(false);
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("cancel during delayed creation exact-cleans a late receipt without publishing or replay", async () => {
    const f = await fixture(); const gate = deferred(), original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => { await gate.promise; return original(options); };
    const pending = f.create(); await flush();
    await f.bridge.hostDisconnected(); gate.resolve();
    expect((await pending).ok).toBe(false);
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(1);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([["remove", 11]]);
    expect([...f.tabs.keys()]).toEqual([1, 2]);
  });

  test("timeout followed by late creation cleans exact receipt and never replays", async () => {
    const f = await fixture({ commandTimeoutMs: 10 }); const gate = deferred(), original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => { await gate.promise; return original(options); };
    const response = await f.create(); expect(response.error.code).toBe("chrome_timeout");
    gate.resolve(); await flush();
    expect(f.calls.filter(value => value[0] === "create")).toHaveLength(1);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([["remove", 11]]);
    expect(f.bridge.generation).toBeNull();
  });

  test("activation before delayed receipt arrives is remembered even if the tab is inactive again", async () => {
    const f = await fixture(); const gate = deferred(), original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => { const tab = await original(options); await gate.promise; return tab; };
    const pending = f.create(); await flush();
    await f.bridge.temporaryTabs.onActivated({ tabId: 11 });
    await f.bridge.temporaryTabs.onActivated({ tabId: 1 });
    await f.bridge.hostDisconnected(); gate.resolve();
    expect((await pending).ok).toBe(false);
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("activation during revoked cleanup read prevents close after lease maps were cleared", async () => {
    const f = await fixture(); await f.create(); const get = f.chrome.tabs.get, gate = deferred();
    f.chrome.tabs.get = async id => { const tab = await get(id); if (id === 11) await gate.promise; return tab; };
    const revoking = f.bridge.hostDisconnected(); await flush();
    await f.bridge.temporaryTabs.onActivated({ tabId: 11 }); gate.resolve(); await revoking;
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("navigation away and back during revoked cleanup remains uncertain", async () => {
    const f = await fixture(); await f.create(); const get = f.chrome.tabs.get, gate = deferred();
    f.chrome.tabs.get = async id => { const tab = await get(id); if (id === 11) await gate.promise; return tab; };
    const revoking = f.bridge.hostDisconnected(); await flush();
    await f.bridge.temporaryTabs.onUpdated(11, { url: "https://example.com/other" }, f.tabs.get(11));
    await f.bridge.temporaryTabs.onUpdated(11, { url: sourceURL }, f.tabs.get(11));
    gate.resolve(); await revoking;
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("activation while attach is pending detaches its late result and returns no attachment", async () => {
    const f = await fixture(); const receipt = (await f.create()).result, gate = deferred(), original = f.chrome.debugger.attach;
    f.chrome.debugger.attach = async (...args) => { await gate.promise; return original(...args); };
    const pending = f.request("attach", { targetID: receipt.targetID }); await flush();
    await f.bridge.temporaryTabs.onActivated({ tabId: 11 }); gate.resolve();
    expect((await pending).error.code).toBe("stale_temporary_lease");
    expect(f.bridge.attachments.size).toBe(0);
    expect(f.calls.filter(value => value[0] === "detach")).toEqual([["detach", "temporary-11"]]);
    expect((await f.release(receipt)).result.retained).toBe(true);
  });

  test("synchronous create failure retains the task tombstone without reserving live capacity", async () => {
    const f = await fixture(); f.chrome.tabs.create = () => { throw new Error("Chrome rejected create"); };
    expect((await f.create()).error.code).toBe("chrome_operation_failed");
    expect((await f.create()).error.code).toBe("temporary_task_already_used");
    expect(f.bridge.temporaryTabs.tasks.get(task).status).toBe("released");
  });

  test("redirect before exact target mapping is retained, never mislabeled as requested URL", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => {
      const tab = await original(options);
      f.targets.find(value => value.tabId === tab.id).url = "https://example.com/redirected";
      return tab;
    };
    expect((await f.create()).error.code).toBe("target_unavailable");
    expect(f.tabs.has(11)).toBe(true);
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
  });

  test("target-mapping failure never substitutes an existing tab with the same URL", async () => {
    const f = await fixture(); const original = f.chrome.tabs.create;
    f.chrome.tabs.create = async options => {
      const tab = await original(options); f.targets.splice(f.targets.findIndex(value => value.tabId === tab.id), 1); return tab;
    };
    expect((await f.create()).error.code).toBe("target_unavailable");
    expect(f.calls.filter(value => value[0] === "remove")).toEqual([]);
    expect(f.tabs.has(1)).toBe(true); expect(f.tabs.has(2)).toBe(true);
  });
});
