import { BridgeError, requireValue, record, text, keys, allowedURL, PRESS_FUNCTION, SET_TEXT_FUNCTION } from "./commands.js";

export const TEMPORARY_TABS_VERSION = 1;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const validTabID = value => Number.isSafeInteger(value) && value >= 0;
const MAX_LEASES = 4;
const MAX_TASKS = 128;
const SETTLE_MS = 1500;

// Leases exist only in this worker epoch. A creation receipt, not a matching
// title or URL, establishes ownership. A restart can leave an orphan but can
// never adopt or remove a user's existing tab.
export class TemporaryTabs {
  constructor(bridge) {
    this.bridge = bridge;
    this.authorizedVersion = null;
    this.tasks = new Map();
    this.leases = new Map();
    this.sequence = 0;
    this.events = new Map();
  }

  authorize(version) { this.authorizedVersion = version === 1 ? 1 : null; }

  check(generation, revision) {
    this.bridge.check(generation, revision);
    requireValue(this.authorizedVersion === 1, "temporary_tabs_not_authorized", "Task-owned temporary tabs need a separate native-user grant.");
  }

  current(item) {
    return this.leases.get(item.leaseToken) === item && item.status === "active"
      && item.generation === this.bridge.generation && item.revision === this.bridge.revision;
  }

  response(item, target) {
    return { leaseToken: item.leaseToken, taskNonce: item.taskNonce, targetID: item.targetID,
      title: typeof target.title === "string" ? target.title.slice(0, 4096) : "", url: target.url,
      availability: target.attached === false ? "available" : target.attached === true ? "busy" : "unknown" };
  }

  note(tabId, kind, value) {
    if (!validTabID(tabId)) return;
    const prior = this.events.get(tabId) ?? {};
    const sequence = ++this.sequence;
    const urlEvents = [...prior.urlEvents ?? []];
    if (value) urlEvents.push({ sequence, url: value });
    const dropped = urlEvents.length > 8 ? urlEvents.shift() : null;
    this.events.set(tabId, { ...prior, [kind]: sequence, urlEvents,
      ...(dropped ? { urlHistoryLostAt: sequence } : {}),
      ...(value ? { url: value, ...(prior.url && prior.url !== value ? { urlTransition: sequence } : {}) } : {}) });
    // Eviction loses evidence, never grants authority: pending creates retain
    // instead of close if any events were evicted after their admission.
    if (this.events.size > 2048) {
      this.events.delete(this.events.keys().next().value);
      this.evictionSequence = this.sequence;
    }
  }

  async retireAttachments(item, reason = "canceled_by_user") {
    const attachments = [...this.bridge.attachments.values()].filter(value => value.tabId === item.tabId);
    for (const attachment of attachments) {
      this.bridge.attachments.delete(attachment.attachmentToken);
      this.bridge.emit({ version: 1, event: "detached", generation: item.generation,
        attachmentToken: attachment.attachmentToken, reason });
    }
    await Promise.allSettled(attachments.map(value => this.bridge.detachSafely(value.targetID)));
  }

  async adopt(item) {
    item.cleanupSafe = false;
    item.status = "retained";
    // Revoke synchronously, before the asynchronous detach. No stale object
    // command can pass its post-dispatch ownership check after user takeover.
    await this.retireAttachments(item);
  }

  onActivated({ tabId } = {}) {
    this.note(tabId, "activation");
    const item = [...this.leases.values()].find(value => value.tabId === tabId);
    if (item && item.status !== "closed") return this.adopt(item);
  }

  onRemoved(tabId) {
    this.note(tabId, "removal");
    const item = [...this.leases.values()].find(value => value.tabId === tabId);
    if (item) { item.cleanupSafe = false; item.status = "closed"; return this.retireAttachments(item, "target_closed"); }
  }

  onUpdated(tabId, changeInfo, tab) {
    const url = typeof changeInfo?.url === "string" ? changeInfo.url : null;
    this.note(tabId, "update", url);
    const item = [...this.leases.values()].find(value => value.tabId === tabId);
    if (!item || item.status === "closed") return;
    if (tab?.active === true || (validTabID(tab?.windowId) && tab.windowId !== item.sourceWindowId)
      || changeInfo?.pinned === true || changeInfo?.groupId !== undefined) return this.adopt(item);
    // Creation initially reports about:blank on some Chrome builds. Until the
    // exact requested URL commits, only that initial blank-to-requested path is
    // permitted; redirects and user takeover still revoke the pending lease.
    if (item.status === "pending" && this.initialURL(url, item.sourceURL)) return;
    if (!url || url === item.url) return;
    // Chrome does not identify the actor behind onUpdated. A narrowly bounded
    // navigation caused while our fixed semantic mutation is settling can be
    // read, but is never sufficient evidence to auto-close the navigated tab.
    item.cleanupSafe = false;
    if (this.current(item) && item.mutationDeadline >= Date.now() && allowedURL(url)) {
      item.url = url;
      return;
    }
    return this.adopt(item);
  }

  mutationStarted(attachment, method, params) {
    const item = [...this.leases.values()].find(value => value.targetID === attachment.targetID);
    if (!item) return;
    requireValue(this.current(item), "stale_temporary_lease", "The temporary tab was released or taken over by the user.");
    if (method === "Runtime.callFunctionOn" && [PRESS_FUNCTION, SET_TEXT_FUNCTION].includes(params.functionDeclaration)) {
      item.mutationDeadline = Date.now() + this.bridge.commandTimeoutMs + SETTLE_MS;
    }
  }

  mutationFinished(attachment, method, params) {
    if (method !== "Runtime.callFunctionOn" || ![PRESS_FUNCTION, SET_TEXT_FUNCTION].includes(params.functionDeclaration)) return;
    const item = [...this.leases.values()].find(value => value.targetID === attachment.targetID);
    if (item) item.mutationDeadline = Date.now() + SETTLE_MS;
  }

  assertAttachable(targetID) {
    const item = [...this.leases.values()].find(value => value.targetID === targetID);
    if (item) requireValue(this.current(item), "stale_temporary_lease", "The temporary tab was released or taken over by the user.");
  }

  initialURL(url, expected) { return url === undefined || url === null || url === "" || url === "about:blank" || url === expected; }

  initialEventsSafe(item) {
    const events = this.events.get(item.tabId);
    return (events?.activation ?? 0) <= item.startedAt && (events?.removal ?? 0) <= item.startedAt
      && (events?.urlHistoryLostAt ?? 0) <= item.startedAt && (this.evictionSequence ?? 0) <= item.startedAt
      && (events?.urlEvents ?? []).filter(value => value.sequence > item.startedAt)
        .every(value => this.initialURL(value.url, item.sourceURL));
  }

  async settle(item, generation, revision) {
    const deadline = Date.now() + this.bridge.temporarySettlementTimeoutMs;
    while (true) {
      this.check(generation, revision);
      requireValue(item.status === "pending" && this.initialEventsSafe(item),
        "stale_temporary_lease", "The temporary tab was taken over before it became ready.");
      const remaining = Math.max(1, deadline - Date.now());
      const tab = await this.bridge.bounded(this.bridge.chrome.tabs.get(item.tabId), remaining);
      this.check(generation, revision);
      const targets = await this.bridge.bounded(this.bridge.chrome.debugger.getTargets(), Math.max(1, deadline - Date.now()));
      this.check(generation, revision);
      requireValue(Array.isArray(targets) && targets.length <= 2048, "invalid_inventory", "Chrome's inventory is invalid or too large.");
      const matching = targets.filter(value => value.type === "page" && value.tabId === item.tabId);
      requireValue(matching.length <= 1, "target_unavailable", "The exact created tab has ambiguous target identity.");
      const target = matching[0];
      if (item.status !== "pending" || !this.initialEventsSafe(item) || tab.id !== item.tabId
        || tab.windowId !== item.sourceWindowId || tab.active !== false || tab.pinned === true
        || !this.initialURL(tab.url, item.sourceURL) || !this.initialURL(tab.pendingUrl, item.sourceURL)
        || (target && !this.initialURL(target.url, item.sourceURL))) {
        item.cleanupSafe = false;
        throw new BridgeError("target_unavailable", "The exact temporary tab changed before it became ready.");
      }
      requireValue(!target?.attached, "target_busy", "Another owner attached to the newly created tab.");
      if (target && text(target.id) && target.attached === false && target.url === item.sourceURL
        && (tab.url === undefined || tab.url === item.sourceURL) && !tab.pendingUrl) {
        item.targetID = target.id;
        item.settledAt = this.sequence;
        return target;
      }
      if (Date.now() >= deadline) throw new BridgeError("target_unavailable", "The exact temporary tab did not become ready within the bounded settling period. Creation was not retried.");
      await new Promise(resolve => setTimeout(resolve, Math.min(this.bridge.temporarySettlementPollMs, Math.max(1, deadline - Date.now()))));
    }
  }

  async create(params, generation, revision) {
    requireValue(keys(params, ["sourceTargetID", "expectedSourceURL", "taskNonce"]) && text(params.sourceTargetID)
      && allowedURL(params.expectedSourceURL)
      && typeof params.taskNonce === "string" && UUID.test(params.taskNonce));
    this.check(generation, revision);
    const existing = this.tasks.get(params.taskNonce);
    if (existing) {
      requireValue(existing.sourceTargetID === params.sourceTargetID && existing.sourceURL === params.expectedSourceURL && this.current(existing),
        "temporary_task_already_used", "This task already created or released its temporary tab; no additional tab was created.");
      const target = (await this.bridge.targets(generation, revision)).find(value => value.id === existing.targetID && value.tabId === existing.tabId);
      requireValue(!!target && this.current(existing), "stale_temporary_lease", "The exact temporary tab is unavailable.");
      return this.response(existing, target);
    }
    requireValue(this.tasks.size < MAX_TASKS && [...this.leases.values()].filter(value => ["pending", "active"].includes(value.status)).length < MAX_LEASES,
      "capacity_exceeded", "The bounded temporary-tab capacity has been reached.");
    const source = (await this.bridge.targets(generation, revision)).find(value => value.id === params.sourceTargetID);
    requireValue(!!source && validTabID(source.tabId), "target_unavailable", "The exact source tab is unavailable.");
    requireValue(source.url === params.expectedSourceURL, "target_unavailable", "The source URL changed since the native observation.");
    requireValue(source.attached === false, "target_busy", "The source must be available; a busy tab cannot be duplicated to avoid its owner.");
    this.assertAttachable(source.id);
    const sourceTab = await this.bridge.bounded(this.bridge.chrome.tabs.get(source.tabId));
    this.check(generation, revision);
    requireValue(record(sourceTab) && sourceTab.id === source.tabId && validTabID(sourceTab.windowId)
      && (sourceTab.url === undefined || sourceTab.url === source.url) && !sourceTab.pendingUrl,
    "target_unavailable", "The source changed before temporary-tab creation. Refresh the inventory.");
    // Recheck debugger ownership after tabs.get, before the sole create dispatch.
    const fresh = (await this.bridge.targets(generation, revision)).find(value => value.id === source.id);
    requireValue(fresh?.tabId === source.tabId && fresh.url === source.url && fresh.attached === false,
      "target_busy", "The source changed or acquired another owner; no tab was created.");
    const item = { leaseToken: this.bridge.uuid(), taskNonce: params.taskNonce, sourceTargetID: source.id,
      generation, revision, status: "pending", startedAt: this.sequence, url: source.url, sourceURL: source.url,
      sourceWindowId: sourceTab.windowId, cleanupSafe: true, mutationDeadline: 0, tabId: null, targetID: null };
    this.tasks.set(item.taskNonce, item);
    this.leases.set(item.leaseToken, item);
    let creation;
    try { creation = this.bridge.chrome.tabs.create({ url: source.url, active: false, windowId: sourceTab.windowId }); }
    catch (error) { item.status = "released"; throw error; }
    // Keep the exact late receipt even if bounded() times out. Revocation never
    // retries creation and never discovers candidates by title or URL.
    const receipt = creation.then(async tab => {
      if (!record(tab) || !validTabID(tab.id)) { item.cleanupSafe = false; item.status = "retained"; throw new BridgeError("invalid_temporary_receipt", "Chrome returned no exact temporary-tab receipt."); }
      item.tabId = tab.id;
      if (tab.active !== false || tab.windowId !== item.sourceWindowId || !this.initialURL(tab.url, item.sourceURL)
        || !this.initialURL(tab.pendingUrl, item.sourceURL) || !this.initialEventsSafe(item)) {
        item.cleanupSafe = false; item.status = "retained";
      }
      if (item.generation !== this.bridge.generation || item.revision !== this.bridge.revision || item.status !== "pending") {
        await this.cleanup(item);
        throw new BridgeError("revoked", "Temporary-tab creation was revoked; no tab capability was returned.");
      }
      return tab;
    });
    try {
      await this.bridge.bounded(receipt);
      this.check(generation, revision);
      const target = await this.settle(item, generation, revision);
      this.check(generation, revision);
      requireValue(item.status === "pending", "stale_temporary_lease", "The temporary tab was taken over before binding.");
      item.status = "active";
      return this.response(item, target);
    } catch (error) {
      // pending receipt may finish later and perform its own exact cleanup.
      if (item.status === "pending" || item.status === "active") item.status = "released";
      if (item.tabId !== null) await this.cleanup(item);
      throw error;
    }
  }

  async cleanup(item) {
    if (item.cleaning) return item.cleaning;
    item.cleaning = this.cleanupOnce(item);
    return item.cleaning;
  }

  async cleanupOnce(item) {
    if (item.tabId === null) return { closed: false, retained: false };
    await this.retireAttachments(item, "temporary_released");
    if (item.status === "closed") return { closed: true, retained: false };
    if (!item.cleanupSafe) return { closed: false, retained: true };
    try {
      const tab = await this.bridge.bounded(this.bridge.chrome.tabs.get(item.tabId), this.bridge.cleanupTimeoutMs);
      const targets = await this.bridge.bounded(this.bridge.chrome.debugger.getTargets(), this.bridge.cleanupTimeoutMs);
      const matching = Array.isArray(targets) ? targets.filter(value => value.tabId === item.tabId && value.type === "page") : [];
      const events = this.events.get(item.tabId);
      // Re-check event-derived ownership after the asynchronous Chrome read.
      if (!item.cleanupSafe || tab.id !== item.tabId || tab.active !== false || tab.pinned === true
        || tab.windowId !== item.sourceWindowId || (tab.url !== undefined && tab.url !== item.url) || tab.pendingUrl
        || matching.length !== 1 || matching[0].url !== item.url || matching[0].attached !== false
        || (item.targetID !== null && matching[0].id !== item.targetID)
        || (events?.activation ?? 0) > item.startedAt || (events?.removal ?? 0) > item.startedAt
        || (events?.urlTransition ?? 0) > (item.settledAt ?? item.startedAt)
        || ((events?.update ?? 0) > item.startedAt && events.url && events.url !== item.url)
        || (this.evictionSequence ?? 0) > item.startedAt) {
        item.cleanupSafe = false; item.status = "retained";
        return { closed: false, retained: true };
      }
      await this.bridge.bounded(this.bridge.chrome.tabs.remove(item.tabId), this.bridge.cleanupTimeoutMs);
      item.status = "closed";
      return { closed: true, retained: false };
    } catch {
      item.cleanupSafe = false; item.status = "retained";
      return { closed: false, retained: true };
    }
  }

  async release(params, generation, revision) {
    requireValue(keys(params, ["leaseToken", "taskNonce"]) && text(params.leaseToken)
      && typeof params.taskNonce === "string" && UUID.test(params.taskNonce));
    this.check(generation, revision);
    const item = this.leases.get(params.leaseToken);
    requireValue(!!item && item.taskNonce === params.taskNonce && item.generation === generation && item.revision === revision,
      "stale_temporary_lease", "No matching task-owned temporary-tab receipt exists.");
    if (item.status === "active") item.status = "released";
    return { released: true, ...await this.cleanup(item) };
  }

  revoke(detached = Promise.resolve()) {
    this.authorizedVersion = null;
    const items = [...this.leases.values()];
    this.tasks.clear();
    this.leases.clear();
    for (const item of items) if (["active", "pending"].includes(item.status)) item.status = "released";
    // Pending creation's late receipt handles its own cleanup after it resolves.
    return detached.then(() => Promise.allSettled(items.filter(item => item.tabId !== null).map(item => this.cleanup(item))));
  }
}
