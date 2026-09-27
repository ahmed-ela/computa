import { describe, expect, test } from "bun:test";
import { CLICKABILITY_STYLES, projectClickabilityResult, validateCommand } from "./commands.js";

const frame = { id: "main-frame", url: "https://example.com/inbox#message-42" };
function snapshot(ids = [11, 12, 13, 14], indexes = [1, 3]) {
  return { strings: [frame.id, frame.url, "Private message body", "onclick"], documents: [{
    frameId: 0, documentURL: 1, title: 2,
    nodes: { backendNodeId: ids, isClickable: { index: indexes },
      nodeValue: [2, 2, 2, 2], attributes: [[3, 2]], parentIndex: [-1, 0, 1, 1] },
    layout: { nodeIndex: [], styles: [], bounds: [], text: [2] },
  }] };
}
const project = (value, budget = 512 * 1024) => projectClickabilityResult(value, budget, frame);
function pointerSnapshot() {
  const value = snapshot([11, 12, 13, 14], []);
  value.strings.push("pointer", "visible", "flex", "auto", "hidden", "none", "default");
  value.documents[0].layout = {
    nodeIndex: [1], styles: [[4, 5, 6, 7]], bounds: [[-20, 50, 120, 40]],
  };
  return value;
}

describe("exact-node clickability command boundary", () => {
  test("admits only four fixed ordered styles, no optional capture capabilities", () => {
    expect(() => validateCommand("DOMSnapshot.captureSnapshot", { computedStyles: [...CLICKABILITY_STYLES] })).not.toThrow();
    for (const params of [{}, { computedStyles: [] }, { computedStyles: [...CLICKABILITY_STYLES].reverse() },
      { computedStyles: [...CLICKABILITY_STYLES, "color"] }, { computedStyles: ["display"] }, { computedStyles: "" },
      { computedStyles: null }, { computedStyles: [...CLICKABILITY_STYLES], includePaintOrder: false },
      { computedStyles: [...CLICKABILITY_STYLES], includeDOMRects: true },
      { computedStyles: [...CLICKABILITY_STYLES], frameId: frame.id }]) {
      expect(() => validateCommand("DOMSnapshot.captureSnapshot", params)).toThrow();
    }
    expect(() => validateCommand("DOMSnapshot.getSnapshot", { computedStyles: [] })).toThrow();
  });

  test("projects only exact browser-positive identities and document provenance", () => {
    const result = project(snapshot());
    expect(result).toEqual({ mactopusClickability: { frameId: frame.id, documentURL: frame.url,
      clickableBackendNodeIds: [12, 14], pointerBackendNodeIds: [], sourceTruncated: false, sourceNodeCount: 4 } });
    const serialized = JSON.stringify(result);
    expect(serialized).not.toContain("Private message");
    expect(serialized).not.toContain("onclick");
    expect(serialized).not.toContain("layout");
    expect(serialized).not.toContain("attributes");
    // Neither parent 11 nor child 13 acquires authority from adjacent node 12.
    expect(result.mactopusClickability.clickableBackendNodeIds).not.toContain(11);
    expect(result.mactopusClickability.clickableBackendNodeIds).not.toContain(13);
  });

  test("absent optional isClickable means no positive evidence", () => {
    const value = snapshot(); delete value.documents[0].nodes.isClickable;
    expect(project(value).mactopusClickability.clickableBackendNodeIds).toEqual([]);
    expect(project(value).mactopusClickability.sourceTruncated).toBe(false);
  });

  test("pointer affordance is distinct from proven clickability and never extends to relatives", () => {
    const result = project(pointerSnapshot()).mactopusClickability;
    expect(result.clickableBackendNodeIds).toEqual([]);
    expect(result.pointerBackendNodeIds).toEqual([12]);
    expect(result.pointerBackendNodeIds).not.toContain(11);
    expect(result.pointerBackendNodeIds).not.toContain(13);
    expect(JSON.stringify(result)).not.toContain("flex");
    expect(JSON.stringify(result)).not.toContain("Private message");
  });

  test("multiple fragments deduplicate exact IDs and empty text styles confer no affordance", () => {
    const value = pointerSnapshot();
    value.documents[0].layout = { nodeIndex: [1, 1, 1, 2],
      styles: [[4, 5, 6, 7], [4, 5, 6, 7], [], []],
      bounds: [[0, 0, 10, 10], [0, 10, 10, 10], [0, 0, 10, 10], [0, 0, 10, 10]] };
    expect(project(value).mactopusClickability.pointerBackendNodeIds).toEqual([12]);
  });

  test("hidden, nonpointer, pointer-disabled and zero-area fragments are not candidates", () => {
    const modifications = [
      value => { value.documents[0].layout.styles[0][0] = 10; }, // cursor:default
      value => { value.documents[0].layout.styles[0][1] = 8; }, // visibility:hidden
      value => { value.documents[0].layout.styles[0][2] = 9; }, // display:none
      value => { value.documents[0].layout.styles[0][3] = 9; }, // pointer-events:none
      value => { value.documents[0].layout.bounds[0][2] = 0; },
      value => { value.documents[0].layout.bounds[0][3] = 0; },
      value => { value.documents[0].layout.styles[0] = []; },
    ];
    for (const modify of modifications) {
      const value = pointerSnapshot(); modify(value);
      expect(project(value).mactopusClickability.pointerBackendNodeIds).toEqual([]);
    }
  });

  test("rejects malformed layout evidence rather than manufacturing pointer candidates", () => {
    const modifications = [
      value => { delete value.documents[0].layout; },
      value => { value.documents[0].layout.styles = []; },
      value => { value.documents[0].layout.bounds = []; },
      value => { value.documents[0].layout.nodeIndex[0] = -1; },
      value => { value.documents[0].layout.nodeIndex[0] = 4; },
      value => { value.documents[0].layout.nodeIndex[0] = "1"; },
      value => { value.documents[0].layout.styles[0] = [4, 5, 6]; },
      value => { value.documents[0].layout.styles[0][0] = 99; },
      value => { value.documents[0].layout.styles[0][0] = -1; },
      value => { value.documents[0].layout.styles[0][0] = "4"; },
      value => { value.documents[0].layout.bounds[0] = [0, 0, 10]; },
      value => { value.documents[0].layout.bounds[0][2] = -10; },
      value => { value.documents[0].layout.bounds[0][0] = Infinity; },
      value => { value.documents[0].layout.bounds[0][2] = "10"; },
      value => { value.documents[0].layout.nodeIndex = Array(100_001).fill(1); },
    ];
    for (const modify of modifications) {
      const value = pointerSnapshot(); modify(value);
      expect(() => project(value)).toThrow("invalid document clickability evidence");
    }
  });

  test("finds only the unique observed main frame without exposing child-document data", () => {
    const value = snapshot();
    value.strings.push("child-frame", "https://private.example/iframe", "Child document secret");
    value.documents.unshift({ frameId: 4, documentURL: 5, title: 6,
      nodes: { backendNodeId: [991], isClickable: { index: [0] } } });
    const result = project(value);
    expect(result.mactopusClickability.clickableBackendNodeIds).toEqual([12, 14]);
    expect(JSON.stringify(result)).not.toContain("private.example");
    expect(JSON.stringify(result)).not.toContain("991");
  });

  test("requires exact main-frame and document URL including the fragment", () => {
    const wrongFrame = snapshot(); wrongFrame.strings[0] = "different-frame";
    const wrongURL = snapshot(); wrongURL.strings[1] = "https://example.com/inbox#message-43";
    const missingFragment = snapshot(); missingFragment.strings[1] = "https://example.com/inbox";
    const restricted = snapshot(); restricted.strings[1] = "chrome://settings/";
    const duplicateFrame = snapshot(); duplicateFrame.documents.push(structuredClone(duplicateFrame.documents[0]));
    for (const value of [wrongFrame, wrongURL, missingFragment, restricted, duplicateFrame]) {
      expect(() => project(value)).toThrow("invalid document clickability evidence");
    }
  });

  test("rejects malformed shapes and ambiguous identities rather than salvaging positive nodes", () => {
    const modifications = [
      value => { value.documents = []; },
      value => { value.documents = Array(257).fill(value.documents[0]); },
      value => { value.strings = {}; },
      value => { value.documents[0].frameId = -1; },
      value => { value.documents[0].frameId = 0.5; },
      value => { value.documents[0].documentURL = 42; },
      value => { value.strings[0] = 12; },
      value => { value.documents[0].nodes.backendNodeId = [1, 1, 3, 4]; },
      value => { value.documents[0].nodes.backendNodeId = [1, 0, 3, 4]; },
      value => { value.documents[0].nodes.backendNodeId = [1, -2, 3, 4]; },
      value => { value.documents[0].nodes.backendNodeId = [1, "2", 3, 4]; },
      value => { value.documents[0].nodes.backendNodeId = [1, Number.MAX_SAFE_INTEGER + 1, 3, 4]; },
      value => { value.documents[0].nodes.isClickable = null; },
      value => { value.documents[0].nodes.isClickable = { index: [1], value: [false] }; },
      value => { value.documents[0].nodes.isClickable.index = [1, 1]; },
      value => { value.documents[0].nodes.isClickable.index = [-1]; },
      value => { value.documents[0].nodes.isClickable.index = [4]; },
      value => { value.documents[0].nodes.isClickable.index = [1.5]; },
      value => { value.documents[0].nodes.isClickable.index = ["1"]; },
    ];
    for (const modify of modifications) {
      const value = snapshot(); modify(value);
      expect(() => project(value)).toThrow("invalid document clickability evidence");
    }
    expect(() => project(null)).toThrow();
    expect(() => projectClickabilityResult(snapshot(), 1024, null)).toThrow();
  });

  test("bounds source nodes and positive identities separately with explicit truncation", () => {
    const ids = Array.from({ length: 100_000 }, (_, index) => index + 1);
    const result = project(snapshot(ids, Array.from({ length: ids.length }, (_, index) => index)));
    expect(result.mactopusClickability.sourceNodeCount).toBe(100_000);
    expect(result.mactopusClickability.clickableBackendNodeIds).toHaveLength(12_000);
    expect(result.mactopusClickability.clickableBackendNodeIds.at(-1)).toBe(12_000);
    expect(result.mactopusClickability.sourceTruncated).toBe(true);
    expect(() => project(snapshot([...ids, 100_001], []))).toThrow();
    // Validate the complete admitted source before returning a bounded prefix.
    const corruptTail = snapshot(ids, Array.from({ length: ids.length }, (_, index) => index));
    corruptTail.documents[0].nodes.isClickable.index[99_999] = -1;
    expect(() => project(corruptTail)).toThrow();
  });

  test("pointer candidates have a bounded deduplicated prefix and share the byte budget", () => {
    const value = pointerSnapshot();
    value.documents[0].nodes.backendNodeId = Array.from({ length: 12_001 }, (_, index) => index + 1);
    const layout = value.documents[0].layout;
    layout.nodeIndex = Array.from({ length: 12_001 }, (_, index) => index);
    layout.styles = Array.from({ length: 12_001 }, () => [4, 5, 6, 7]);
    layout.bounds = Array.from({ length: 12_001 }, () => [0, 0, 10, 10]);
    const result = project(value).mactopusClickability;
    expect(result.pointerBackendNodeIds).toHaveLength(12_000);
    expect(result.sourceTruncated).toBe(true);
    value.documents[0].nodes.isClickable.index = layout.nodeIndex;
    const bounded = project(value, 300);
    expect(new TextEncoder().encode(JSON.stringify(bounded)).byteLength).toBeLessThanOrEqual(300);
    expect(bounded.mactopusClickability.sourceTruncated).toBe(true);
  });

  test("bounds UTF-8 bytes, never truncates an identity, and reports missing positives", () => {
    const value = snapshot(Array.from({ length: 100 }, (_, index) => 123456789 + index),
      Array.from({ length: 100 }, (_, index) => index));
    const expectedFrame = { id: "main-🧪", url: "https://example.com/🧪" };
    value.strings[0] = expectedFrame.id; value.strings[1] = expectedFrame.url;
    const result = projectClickabilityResult(value, 300, expectedFrame);
    expect(new TextEncoder().encode(JSON.stringify(result)).byteLength).toBeLessThanOrEqual(300);
    expect(result.mactopusClickability.sourceTruncated).toBe(true);
    expect(result.mactopusClickability.clickableBackendNodeIds.length).toBeGreaterThan(0);
    expect(result.mactopusClickability.clickableBackendNodeIds.length).toBeLessThan(100);
    expect(result.mactopusClickability.clickableBackendNodeIds.every(Number.isSafeInteger)).toBe(true);
    expect(() => projectClickabilityResult(value, 20, expectedFrame)).toThrow("too large");
  });
});
