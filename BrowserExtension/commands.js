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

export function validateCommand(method, params) {
  requireValue(text(method) && record(params));
  switch (method) {
    case "Page.getFrameTree":
    case "Accessibility.enable":
      requireValue(keys(params, []));
      break;
    case "Accessibility.getFullAXTree":
      requireValue(keys(params, ["depth"]) && params.depth === 16);
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
