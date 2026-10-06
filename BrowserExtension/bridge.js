import { BridgeError, requireValue, record, text, keys, allowedURL, validateCommand, projectAccessibilityResult, projectClickabilityResult } from "./commands.js";
import { TemporaryTabs, TEMPORARY_TABS_VERSION } from "./temporary-tabs.js";

import { WebProviderSessions } from "./web-providers.js";

export const HOST_NAME = "com.macndash.chrome_bridge";
export const MAX_MESSAGE_BYTES = 512 * 1024;
const STORAGE_KEY = "macndashChromeBridgeV1";
const encoder = new TextEncoder();

// Dependency injection keeps tests away from the user's browser and native host.
export class ChromeBridge {
  constructor({ chrome, emit, uuid = () => crypto.randomUUID(), commandTimeoutMs = 15_000, cleanupTimeoutMs = 1_500,
    temporarySettlementTimeoutMs = 2000, temporarySettlementPollMs = 50 }) {
    this.chrome = chrome;
    this.emit = emit;
    this.uuid = uuid;
    this.commandTimeoutMs = commandTimeoutMs;
    this.cleanupTimeoutMs = cleanupTimeoutMs;
    this.temporarySettlementTimeoutMs = temporarySettlementTimeoutMs;
    this.temporarySettlementPollMs = temporarySettlementPollMs;
    this.bridgeEpoch = uuid();
    this.generation = null;
    this.attachments = new Map();
    this.requestIDs = new Set();
    this.usedGenerations = new Set();
    this.revision = 0;
    this.queue = Promise.resolve();
    this.storageQueue = Promise.resolve();
    this.pendingCount = 0;
    this.pairingNonce = null;
    this.state = null;
    this.temporaryTabs = new TemporaryTabs(this);
    this.webProviders = new WebProviderSessions({ chrome, uuid, bounded: (promise, timeout) => this.bounded(promise, timeout),
      check: (generation, revision) => this.check(generation, revision), emit });
  }

  async initialize() {
    const value = (await this.chrome.storage.local.get(STORAGE_KEY))[STORAGE_KEY];
    this.state = record(value) && text(value.installationId)
      ? { installationId: value.installationId, pairingToken: text(value.pairingToken, 256) ? value.pairingToken : null, suspended: value.suspended === true }
      : { installationId: this.uuid(), pairingToken: null, suspended: false };
    await this.save();
    await this.webProviders.initialize();
  }

  save() {
    const snapshot = structuredClone(this.state);
    const saved = this.storageQueue.then(() => this.chrome.storage.local.set({ [STORAGE_KEY]: snapshot }));
    this.storageQueue = saved.catch(() => {});
    return saved;
  }

  async bounded(promise, timeout = this.commandTimeoutMs) {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new BridgeError("chrome_timeout", "Chrome did not respond in time. Authority was revoked; the request was not replayed.")), timeout);
      })]);
    } finally { clearTimeout(timer); }
  }

  async detachSafely(targetID) {
    try { await this.bounded(this.chrome.debugger.detach({ targetId: targetID }), this.cleanupTimeoutMs); }
    catch { /* No new attachment can adopt an uncertain old session. */ }
  }

  hello() {
    const hello = { version: 1, event: "hello", installationId: this.state.installationId,
      extensionId: this.chrome.runtime.id, bridgeEpoch: this.bridgeEpoch,
      paired: !!this.state.pairingToken, suspended: this.state.suspended,
      capabilities: { temporaryTabsVersion: TEMPORARY_TABS_VERSION } };
    if (this.state.pairingToken) hello.pairingToken = this.state.pairingToken;
    this.emit(hello);
    return hello;
  }

  status() {
    return { paired: !!this.state.pairingToken, suspended: this.state.suspended,
      connected: this.generation !== null, installationId: this.state.installationId,
      extensionId: this.chrome.runtime.id, attachmentCount: this.attachments.size,
      webProviderCleanupFailures: this.webProviders.cleanupFailures };
  }

  // Called only by a validated extension popup message, never by native or web content.
  async requestPairing() {
    requireValue(!this.state.pairingToken, "already_paired", "Forget the existing pairing before pairing again.");
    this.pairingNonce = this.uuid();
    this.emitPairingProposal();
  }

  emitPairingProposal() {
    if (!this.pairingNonce || this.state.pairingToken) return;
    this.emit({ version: 1, event: "pairRequested", installationId: this.state.installationId,
      extensionId: this.chrome.runtime.id, bridgeEpoch: this.bridgeEpoch,
      paired: false, suspended: this.state.suspended, pairingNonce: this.pairingNonce,
      capabilities: { temporaryTabsVersion: TEMPORARY_TABS_VERSION } });
  }

  async resumeFromPopup() {
    requireValue(!!this.state.pairingToken, "not_paired", "Pair this extension first.");
    this.state.suspended = false;
    await this.save();
    this.hello();
  }

  // Revoke synchronously before awaiting browser cleanup so pending actions cannot resume.
  async revoke({ suspend = false, forget = false } = {}) {
    this.revision += 1;
    this.generation = null;
    this.pairingNonce = null;
    const attachments = [...this.attachments.values()];
    this.attachments.clear();
    this.requestIDs.clear();
    const detached = Promise.allSettled(attachments.map(item => this.detachSafely(item.targetID)));
    const temporaryCleanup = this.temporaryTabs.revoke(detached);
    if (suspend) this.state.suspended = true;
    if (forget) { this.state.pairingToken = null; this.pairingNonce = null; this.state.suspended = true; }
    await this.save();
    await Promise.allSettled([temporaryCleanup, detached, this.webProviders.revokeAll()]);
  }

  async hostDisconnected() { await this.revoke(); }

  async onDetach(source, reason) {
    const providerDetached = this.webProviders.onDetach(source);
    if (providerDetached && reason !== "target_closed") { await this.revoke({ suspend: true }); this.hello(); }
    const item = [...this.attachments.values()].find(value => source.targetId === value.targetID || source.tabId === value.tabId);
    if (!item) return;
    this.attachments.delete(item.attachmentToken);
    this.emit({ version: 1, event: "detached", generation: this.generation,
      attachmentToken: item.attachmentToken, reason: reason === "target_closed" ? "target_closed" : "canceled_by_user" });
    // Chrome may also report DevTools conflicts as cancellation. Never fight either.
    if (reason !== "target_closed") { await this.revoke({ suspend: true }); this.hello(); }
  }

  receive(message) {
    if (record(message) && message.version === 1 && message.event === "requestHello") {
      this.hello(); this.emitPairingProposal(); return Promise.resolve();
    }
    if (record(message) && message.version === 1 && message.event === "appDisconnected") {
      return this.revoke().then(() => this.hello());
    }
    const size = (() => { try { return encoder.encode(JSON.stringify(message)).byteLength; } catch { return Infinity; } })();
    if (size > MAX_MESSAGE_BYTES || this.pendingCount >= 32) {
      return this.revoke({ suspend: true }).then(() => this.emit({ version: 1, event: "bridgeError", code: "capacity_exceeded" }));
    }
    // Revocation cannot wait behind a slow browser command. It still passes the
    // complete envelope, pairing/generation, and replay checks in handle().
    if (message?.operation === "revokePair" || message?.operation === "disconnect") {
      return this.handle(message, this.revision);
    }
    this.pendingCount += 1;
    // Serialize operations, but capture admission now. Revocation while queued is final.
    const revision = this.revision;
    const task = this.queue.then(() => this.handle(message, revision));
    this.queue = task.catch(() => {});
    return task.finally(() => { this.pendingCount -= 1; });
  }

  async handle(request, admissionRevision) {
    let result;
    try {
      requireValue(keys(request, ["version", "id", "operation", "params", "generation"])
        && request.version === 1 && text(request.id, 128) && text(request.operation, 64)
        && text(request.generation, 128) && record(request.params));
      requireValue(admissionRevision === this.revision, "revoked", "This request was revoked.");
      requireValue(!this.requestIDs.has(request.id), "duplicate_request", "Requests must not be replayed.");
      requireValue(this.requestIDs.size < 4096, "capacity_exceeded", "Start a fresh authenticated session.");
      this.requestIDs.add(request.id);
      result = await this.perform(request);
      const response = { version: 1, id: request.id, generation: request.generation, ok: true, result };
      requireValue(encoder.encode(JSON.stringify(response)).byteLength <= MAX_MESSAGE_BYTES, "response_too_large", "The bounded bridge response is too large.");
      this.emit(response);
    } catch (error) {
      const failure = error instanceof BridgeError ? error : new BridgeError("chrome_operation_failed", "Chrome could not complete this operation. No operation was retried.");
      if (failure.code === "chrome_timeout") await this.revoke();
      if (text(request?.id, 128) && text(request?.generation, 128)) this.emit({ version: 1, id: request.id,
        generation: request.generation, ok: false, error: { code: failure.code, message: failure.message } });
    }
  }

  check(generation, revision) {
    requireValue(!!this.state.pairingToken && !this.state.suspended && this.generation === generation
      && this.revision === revision, "unauthorized", "The browser session is not authorized.");
  }

  async targets(generation, revision) {
    this.check(generation, revision);
    const targets = await this.bounded(this.chrome.debugger.getTargets());
    this.check(generation, revision);
    requireValue(Array.isArray(targets) && targets.length <= 2048, "invalid_inventory", "Chrome's inventory is invalid or too large.");
    return targets.filter(target => target.type === "page" && text(target.id) && allowedURL(target.url));
  }

  async current(item, generation, revision) {
    requireValue(this.attachments.get(item.attachmentToken) === item, "stale_attachment", "The tab attachment is no longer current.");
    this.temporaryTabs.assertAttachable(item.targetID);
    const target = (await this.targets(generation, revision)).find(target => target.id === item.targetID);
    requireValue(!!target, "target_unavailable", "The exact attached tab is unavailable or restricted.");
    requireValue(this.attachments.get(item.attachmentToken) === item, "stale_attachment", "The tab attachment is no longer current.");
    this.temporaryTabs.assertAttachable(item.targetID);
    return target;
  }

  async perform(request) {
    const { operation, params, generation } = request;
    if (operation === "revokePair") {
      requireValue(keys(params, ["installationId", "pairingToken"]) && !!this.state.pairingToken
        && params.installationId === this.state.installationId && params.pairingToken === this.state.pairingToken,
      "unauthorized", "The extension pairing does not match.");
      await this.revoke({ suspend: true, forget: true });
      this.hello();
      return { paired: false, disconnected: true };
    }
    if (operation === "approvePair") {
      requireValue(keys(params, ["installationId", "pairingNonce", "pairingToken"])
        && !this.state.pairingToken && text(this.pairingNonce)
        && params.installationId === this.state.installationId && params.pairingNonce === this.pairingNonce
        && text(params.pairingToken, 256) && params.pairingToken.length >= 32, "pairing_rejected", "No matching user-initiated pairing request.");
      this.state.pairingToken = params.pairingToken;
      this.state.suspended = false;
      this.pairingNonce = null;
      const revision = this.revision;
      await this.save();
      requireValue(revision === this.revision && this.state.pairingToken === params.pairingToken,
        "revoked", "Pairing was revoked.");
      this.hello();
      return { paired: true };
    }
    if (operation === "authorizeSession") {
      requireValue((keys(params, ["installationId", "pairingToken"])
        || (keys(params, ["installationId", "pairingToken", "temporaryTabsVersion"]) && params.temporaryTabsVersion === TEMPORARY_TABS_VERSION))
        && !!this.state.pairingToken && !this.state.suspended
        && params.installationId === this.state.installationId && params.pairingToken === this.state.pairingToken,
      "unauthorized", "The extension pairing does not match or is suspended.");
      requireValue(!this.usedGenerations.has(generation), "duplicate_generation", "A new session must use a fresh generation.");
      requireValue(this.usedGenerations.size < 4096, "capacity_exceeded", "Restart the extension to establish a new bridge epoch.");
      const expectedRevision = this.revision + 1;
      await this.revoke();
      requireValue(this.revision === expectedRevision && !this.state.suspended && params.pairingToken === this.state.pairingToken,
        "revoked", "Pairing was revoked.");
      this.generation = generation;
      this.temporaryTabs.authorize(params.temporaryTabsVersion);
      this.usedGenerations.add(generation);
      this.requestIDs.add(request.id);
      return { generation, bridgeEpoch: this.bridgeEpoch };
    }
    const revision = this.revision;
    this.check(generation, revision);
    if (["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish", "webProviderCancel"].includes(operation))
      return this.webProviders.perform(operation, params, generation, revision);
    switch (operation) {
      case "ping":
        requireValue(keys(params, []));
        return { generation, bridgeEpoch: this.bridgeEpoch, capabilities: { temporaryTabsVersion: TEMPORARY_TABS_VERSION } };
      case "createTemporary":
        return this.temporaryTabs.create(params, generation, revision);
      case "releaseTemporary":
        return this.temporaryTabs.release(params, generation, revision);
      case "inventory": {
        requireValue(keys(params, []));
        return { generation, candidates: (await this.targets(generation, revision)).map(target => ({ targetID: target.id,
          title: typeof target.title === "string" ? target.title.slice(0, 4096) : "", url: target.url,
          availability: target.attached === false ? "available" : target.attached === true ? "busy" : "unknown" })) };
      }
      case "attach": {
        requireValue(keys(params, ["targetID"]) && text(params.targetID));
        requireValue(this.attachments.size < 16, "capacity_exceeded", "Too many attached tabs.");
        requireValue(![...this.attachments.values()].some(item => item.targetID === params.targetID), "already_attached", "This tab already has a bridge attachment.");
        const target = (await this.targets(generation, revision)).find(target => target.id === params.targetID);
        requireValue(!!target, "target_unavailable", "The exact tab is unavailable or restricted.");
        requireValue(!target.attached, "target_busy", "The exact tab already has an automation or debugger attachment.");
        this.temporaryTabs.assertAttachable(target.id);
        this.check(generation, revision);
        const attachment = this.chrome.debugger.attach({ targetId: target.id }, "1.3");
        // An attach can finish after its deadline. Clean it up on its original exact target.
        void attachment.then(() => {
          if (this.generation !== generation || this.revision !== revision) return this.detachSafely(target.id);
        }, () => {});
        try { await this.bounded(attachment); }
        catch (error) { await this.detachSafely(target.id); throw error; }
        try { this.check(generation, revision); this.temporaryTabs.assertAttachable(target.id); }
        catch (error) { await this.detachSafely(target.id); throw error; }
        const item = { attachmentToken: this.uuid(), targetID: target.id, tabId: target.tabId,
          objects: new Map(), contexts: new Set(), frame: null };
        this.attachments.set(item.attachmentToken, item);
        const current = await this.current(item, generation, revision);
        return { attachmentToken: item.attachmentToken, targetID: item.targetID, title: current.title ?? "", url: current.url };
      }
      case "detach": {
        requireValue(keys(params, ["attachmentToken"]) && text(params.attachmentToken));
        const item = this.attachments.get(params.attachmentToken);
        requireValue(!!item, "stale_attachment", "The tab attachment is no longer current.");
        this.attachments.delete(params.attachmentToken);
        await this.bounded(this.chrome.debugger.detach({ targetId: item.targetID }));
        return { detached: true };
      }
      case "command": {
        requireValue(keys(params, ["attachmentToken", "method", "params"]) && text(params.attachmentToken));
        validateCommand(params.method, params.params);
        const item = this.attachments.get(params.attachmentToken);
        requireValue(!!item, "stale_attachment", "The tab attachment is no longer current.");
        await this.current(item, generation, revision);
        const command = params.params;
        if (params.method === "DOMSnapshot.captureSnapshot") requireValue(!!item.frame, "stale_frame", "Observe the current main frame first.");
        if (params.method === "Page.createIsolatedWorld") requireValue(item.frame?.id === command.frameId, "stale_frame", "Observe the current main frame first.");
        if (params.method === "DOM.resolveNode") requireValue(item.contexts.has(command.executionContextId), "stale_context", "The execution context is not owned by this attachment.");
        if (params.method === "Runtime.callFunctionOn") requireValue(item.objects.has(command.objectId)
          && command.arguments[0].value === item.frame?.url, "stale_object", "The object or document is not current.");
        this.check(generation, revision);
        this.temporaryTabs.mutationStarted(item, params.method, command);
        const result = (await this.bounded(this.chrome.debugger.sendCommand({ targetId: item.targetID }, params.method, command))) ?? {};
        this.temporaryTabs.mutationFinished(item, params.method, command);
        this.check(generation, revision);
        requireValue(this.attachments.get(item.attachmentToken) === item, "stale_attachment", "The tab attachment was revoked.");
        if (params.method === "Page.getFrameTree") {
          const frame = result?.frameTree?.frame;
          requireValue(record(frame) && text(frame.id) && text(frame.loaderId) && allowedURL(frame.url), "invalid_document", "Chrome returned an unsupported document.");
          const identity = { id: frame.id, loaderId: frame.loaderId, url: frame.url + (frame.urlFragment ?? "") };
          if (JSON.stringify(identity) !== JSON.stringify(item.frame)) { item.objects.clear(); item.contexts.clear(); }
          item.frame = identity;
        }
        if (params.method === "Page.createIsolatedWorld") {
          requireValue(Number.isSafeInteger(result.executionContextId) && result.executionContextId > 0, "invalid_context", "Chrome returned no execution context.");
          requireValue(item.contexts.has(result.executionContextId) || item.contexts.size < 64,
            "capacity_exceeded", "Too many execution contexts in this attachment.");
          item.contexts.add(result.executionContextId);
        }
        if (params.method === "DOM.resolveNode") {
          requireValue(text(result.object?.objectId, 2048), "invalid_object", "Chrome returned no object handle.");
          requireValue(item.objects.has(result.object.objectId) || item.objects.size < 256,
            "capacity_exceeded", "Too many object handles in this attachment.");
          item.objects.set(result.object.objectId, command.objectGroup);
        }
        if (params.method === "Runtime.releaseObjectGroup") {
          for (const [id, group] of item.objects) if (group === command.objectGroup) item.objects.delete(id);
        }
        if (params.method === "Accessibility.getFullAXTree") return projectAccessibilityResult(result, MAX_MESSAGE_BYTES - 4096);
        if (params.method === "DOMSnapshot.captureSnapshot") return projectClickabilityResult(result, MAX_MESSAGE_BYTES - 4096, item.frame);
        return result;
      }
      case "disconnect":
        requireValue(keys(params, ["forgetPairing"]) && typeof params.forgetPairing === "boolean");
        await this.revoke({ suspend: true, forget: params.forgetPairing });
        this.hello();
        return { disconnected: true };
      default: throw new BridgeError("unsupported_operation", "Unsupported bridge operation.");
    }
  }
}
