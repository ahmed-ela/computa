// These two fixed templates must stay byte-for-byte equal to the native broker.
// No model-written JavaScript or arbitrary Runtime command is admitted.
export const PRESS_FUNCTION = `function(expectedURL) {
  if (!(this instanceof HTMLElement) || !this.isConnected ||
      this.ownerDocument !== document || window !== window.top ||
      document.URL !== expectedURL || this.matches(":disabled") ||
      this.closest('[inert], [aria-disabled="true" i]')) return false;
  HTMLElement.prototype.click.call(this);
  return true;
}`;

export const SET_TEXT_FUNCTION = `function(expectedURL, value) {
  if (!(this instanceof HTMLElement) || !this.isConnected ||
      this.ownerDocument !== document || window !== window.top ||
      document.URL !== expectedURL || this.matches(":disabled") ||
      this.closest('[inert], [aria-disabled="true" i], [aria-readonly="true" i]')) {
    return false;
  }
  if (this instanceof HTMLInputElement) {
    if (this.readOnly ||
        !["text", "search", "email", "url", "tel", "password"].includes(this.type)) {
      return false;
    }
    const setter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype, "value"
    ).set;
    setter.call(this, value);
  } else if (this instanceof HTMLTextAreaElement) {
    if (this.readOnly) return false;
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype, "value"
    ).set;
    setter.call(this, value);
  } else if (this.isContentEditable) {
    this.textContent = value;
  } else {
    return false;
  }
  this.dispatchEvent(new Event("input", { bubbles: true }));
  this.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
}`;

export class BridgeError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
export function requireValue(condition, code = "invalid_request", message = "Invalid bridge request.") {
  if (!condition) throw new BridgeError(code, message);
}
export const record = value => !!value && typeof value === "object" && !Array.isArray(value);
export const text = (value, max = 256) => typeof value === "string" && value.length > 0 && value.length <= max;
export function keys(value, expected) {
  return record(value) && Object.keys(value).length === expected.length && expected.every(key => Object.hasOwn(value, key));
}
export function allowedURL(value) {
  try { return typeof value === "string" && value.length <= 16_384 && ["http:", "https:"].includes(new URL(value).protocol); }
  catch { return false; }
}
const positive = value => Number.isSafeInteger(value) && value > 0;
const group = value => typeof value === "string" && /^heydash-mutation-[0-9a-f-]{36}$/i.test(value);
export const CLICKABILITY_STYLES = Object.freeze(["cursor", "visibility", "display", "pointer-events"]);

/// CDP AX values repeat verbose name-computation source DOM trees. The broker
/// consumes their resolved semantic values, not those explanations. Project only
/// this fixed response type before the native-messaging ceiling is reached.
/// Values are never text-truncated: a node is either retained whole or omitted.
export function projectAccessibilityResult(result, maximumBytes) {
  if (!record(result) || !Array.isArray(result.nodes)) return result;
  const encoder = new TextEncoder();
  const axValue = value => {
    if (!record(value)) return value;
    const projected = {};
    for (const key of ["type", "value", "relatedNodes"]) {
      if (Object.hasOwn(value, key)) projected[key] = value[key];
    }
    return projected;
  };
  const nodes = [];
  let bytes = 1024; // Reserve result metadata and the authenticated response envelope.
  for (const raw of result.nodes) {
    if (!record(raw)) break;
    const node = {};
    for (const key of ["nodeId", "parentId", "childIds", "backendDOMNodeId", "frameId", "ignored"]) {
      if (Object.hasOwn(raw, key)) node[key] = raw[key];
    }
    for (const key of ["role", "chromeRole", "name", "description", "value"]) {
      if (Object.hasOwn(raw, key)) node[key] = axValue(raw[key]);
    }
    if (Array.isArray(raw.properties)) {
      node.properties = raw.properties.filter(record).map(property => ({
        name: property.name, value: axValue(property.value),
      }));
    }
    const size = encoder.encode(JSON.stringify(node)).byteLength + 1;
    if (nodes.length >= 12_000 || bytes + size > maximumBytes) break;
    nodes.push(node);
    bytes += size;
  }
  return { nodes, macrouseSourceTruncated: nodes.length !== result.nodes.length,
    macrouseSourceNodeCount: result.nodes.length };
}

// DOMSnapshot contains document text, attributes and child-frame data. None of
// that crosses the native bridge: only Chrome's exact-node clickability and the
// already-observed main-document identity are retained. Pointer affordances are
// a separate heuristic, not event-handler proof; native must intersect them with
// the same node's AX focusability. No ancestor/descendant inherits capability.
export function projectClickabilityResult(result, maximumBytes, expectedFrame) {
  const malformed = condition => requireValue(condition, "invalid_document",
    "Chrome returned invalid document clickability evidence.");
  malformed(record(result) && Array.isArray(result.documents)
    && result.documents.length > 0 && result.documents.length <= 256
    && Array.isArray(result.strings));
  malformed(record(expectedFrame) && text(expectedFrame.id) && allowedURL(expectedFrame.url));
  const stringAt = index => {
    malformed(Number.isSafeInteger(index) && index >= 0 && index < result.strings.length
      && typeof result.strings[index] === "string");
    return result.strings[index];
  };
  const frames = new Set();
  let main;
  for (const document of result.documents) {
    malformed(record(document));
    const frameID = stringAt(document.frameId);
    malformed(text(frameID) && !frames.has(frameID));
    frames.add(frameID);
    if (frameID === expectedFrame.id) main = document;
  }
  malformed(!!main);
  const documentURL = stringAt(main.documentURL);
  malformed(allowedURL(documentURL) && documentURL === expectedFrame.url);
  malformed(record(main.nodes) && Array.isArray(main.nodes.backendNodeId)
    && main.nodes.backendNodeId.length <= 100_000);
  const backendIDs = main.nodes.backendNodeId;
  const identities = new Set();
  for (const id of backendIDs) {
    malformed(positive(id) && !identities.has(id));
    identities.add(id);
  }
  const clickable = Object.hasOwn(main.nodes, "isClickable") ? main.nodes.isClickable : { index: [] };
  malformed(keys(clickable, ["index"]) && Array.isArray(clickable.index)
    && clickable.index.length <= backendIDs.length);
  const indices = new Set();
  for (const index of clickable.index) {
    malformed(Number.isSafeInteger(index) && index >= 0 && index < backendIDs.length
      && !indices.has(index));
    indices.add(index);
  }

  const layout = main.layout;
  malformed(record(layout) && Array.isArray(layout.nodeIndex)
    && layout.nodeIndex.length <= 100_000 && Array.isArray(layout.styles)
    && Array.isArray(layout.bounds) && layout.styles.length === layout.nodeIndex.length
    && layout.bounds.length === layout.nodeIndex.length);
  const pointerIDs = new Set();
  for (let offset = 0; offset < layout.nodeIndex.length; offset++) {
    const index = layout.nodeIndex[offset], styles = layout.styles[offset], bounds = layout.bounds[offset];
    malformed(Number.isSafeInteger(index) && index >= 0 && index < backendIDs.length
      && Array.isArray(styles) && (styles.length === 0 || styles.length === CLICKABILITY_STYLES.length)
      && Array.isArray(bounds) && bounds.length === 4 && bounds.every(Number.isFinite)
      && bounds[2] >= 0 && bounds[3] >= 0);
    // Chrome can return multiple layout fragments for the same exact DOM node,
    // and text fragments can have no styles. Neither implies a different node.
    if (styles.length === 0) continue;
    const [cursor, visibility, display, pointerEvents] = styles.map(stringAt);
    if (cursor === "pointer" && visibility === "visible" && display !== "none"
      && display !== "" && pointerEvents !== "none" && pointerEvents !== ""
      && bounds[2] > 0 && bounds[3] > 0) pointerIDs.add(backendIDs[index]);
  }

  const evidence = { frameId: expectedFrame.id, documentURL, clickableBackendNodeIds: [],
    pointerBackendNodeIds: [], sourceTruncated: false, sourceNodeCount: backendIDs.length };
  const projected = { mactopusClickability: evidence };
  const encoder = new TextEncoder();
  let bytes = encoder.encode(JSON.stringify(projected)).byteLength;
  requireValue(Number.isSafeInteger(maximumBytes) && bytes <= maximumBytes,
    "response_too_large", "The bounded clickability response is too large.");
  const appendBounded = (ids, output) => {
    for (const id of ids) {
      const size = String(id).length + (output.length ? 1 : 0);
      if (output.length >= 12_000 || bytes + size > maximumBytes) {
        evidence.sourceTruncated = true;
        break;
      }
      output.push(id);
      bytes += size;
    }
  };
  appendBounded(clickable.index.map(index => backendIDs[index]), evidence.clickableBackendNodeIds);
  appendBounded(pointerIDs, evidence.pointerBackendNodeIds);
  return projected;
}

export function validateCommand(method, params) {
  requireValue(text(method) && record(params));
  switch (method) {
    case "Page.getFrameTree":
    case "Accessibility.enable":
      requireValue(keys(params, []));
      break;
    case "Accessibility.getFullAXTree":
      requireValue(keys(params, ["depth"]) && [16, 64].includes(params.depth));
      break;
    case "DOMSnapshot.captureSnapshot":
      requireValue(keys(params, ["computedStyles"]) && Array.isArray(params.computedStyles)
        && params.computedStyles.length === CLICKABILITY_STYLES.length
        && params.computedStyles.every((style, index) => style === CLICKABILITY_STYLES[index]));
      break;
    case "Page.createIsolatedWorld":
      requireValue(keys(params, ["frameId", "worldName"]) && text(params.frameId)
        && params.worldName === "LocalCodexBrowserBroker");
      break;
    case "DOM.resolveNode":
      requireValue(keys(params, ["backendNodeId", "executionContextId", "objectGroup"])
        && positive(params.backendNodeId) && positive(params.executionContextId) && group(params.objectGroup));
      break;
    case "Runtime.releaseObjectGroup":
      requireValue(keys(params, ["objectGroup"]) && group(params.objectGroup));
      break;
    case "Runtime.callFunctionOn": {
      requireValue(keys(params, ["objectId", "functionDeclaration", "arguments", "returnByValue", "awaitPromise", "userGesture"]));
      const isPress = params.functionDeclaration === PRESS_FUNCTION;
      const isText = params.functionDeclaration === SET_TEXT_FUNCTION;
      requireValue((isPress || isText) && text(params.objectId, 2048)
        && params.returnByValue === true && params.awaitPromise === true && params.userGesture === true
        && Array.isArray(params.arguments) && params.arguments.length === (isPress ? 1 : 2)
        && params.arguments.every(argument => keys(argument, ["value"]))
        && allowedURL(params.arguments[0].value)
        && (isPress || (typeof params.arguments[1].value === "string" && params.arguments[1].value.length <= 65_536)));
      break;
    }
    default: throw new BridgeError("unsupported_command", "This command is not part of the browser bridge contract.");
  }
}
