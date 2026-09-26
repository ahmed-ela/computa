import { expect, test } from "bun:test";
import { HOST_BUNDLE_ID_DESCRIPTION, withHostContract } from "./host-contract";

test("clones both protocol shapes and changes only bundle_id description", () => {
  for (const key of ["inputSchema", "parameters"] as const) {
    const specs = [
      { name: "computer_v2_status", type: "function", description: "unchanged status", [key]: { type: "object", properties: {} } },
      { name: "computer_v2_open", type: "function", description: "unchanged open", deferLoading: false,
        [key]: { type: "object", properties: { bundle_id: { type: "string", description: "original description", pattern: "observed IDs only" },
          url: { type: "string", description: "unchanged URL" } }, required: ["bundle_id"], additionalProperties: false } },
    ];
    const before = JSON.stringify(specs);
    const freeze = (value: any): any => { if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };
    freeze(specs);
    const changed = withHostContract(specs);
    expect(JSON.stringify(specs)).toBe(before);
    expect(changed).not.toBe(specs);
    expect(changed[0]).not.toBe(specs[0]);
    expect(changed[0]).toEqual(specs[0]);
    expect((changed[1][key] as any).properties.bundle_id.description).toBe(HOST_BUNDLE_ID_DESCRIPTION);
    (changed[1][key] as any).properties.bundle_id.description = "original description";
    expect(JSON.stringify(changed)).toBe(before);
  }
});

test("fails closed on missing, duplicate, ambiguous, or malformed target schema", () => {
  const valid = { name: "computer_v2_open", inputSchema: { properties: { bundle_id: { type: "string" } } } };
  expect(() => withHostContract([])).toThrow();
  expect(() => withHostContract([valid, valid])).toThrow();
  expect(() => withHostContract([{ ...valid, parameters: valid.inputSchema }])).toThrow();
  expect(() => withHostContract([{ name: "computer_v2_open" }])).toThrow();
  expect(() => withHostContract([{ name: "computer_v2_open", inputSchema: { properties: { bundle_id: { type: "integer" } } } }])).toThrow();
});
