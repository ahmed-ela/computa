import { expect, test } from "bun:test";
import { annotateExplicitAppMention as annotate } from "./explicit-app-mention";

const header = (n: number) => `APPS scope=user_facing matched=${n} returned=${n} omitted=0. Synthetic inventory.`;
const chrome = ' {"pid":42, "active":false,"name":"Chrome","bundle_id":"example.Chrome"} ';
const viewer = '{"name":"Remote Viewer","bundle_id":"example.viewer","active":true}';
const paper = '{"name":"Paper Pad","bundle_id":"example.paper"}';
const inventory = [header(3), chrome, viewer, paper].join("\n") + "\n";
const rows = (text: string) => text.trimEnd().split("\n").slice(1).map(line => JSON.parse(line));

test("one mention moves only the annotated existing row; all other bytes/order remain", () => {
  const before = inventory, output = annotate("Read Remote Viewer.", inventory), lines = output.split("\n");
  expect(inventory).toBe(before);
  expect(lines[0]).toBe(header(3)); expect(lines[2]).toBe(chrome); expect(lines[3]).toBe(paper);
  expect(output.endsWith("\n")).toBe(true);
  expect(rows(output)[0]).toEqual({ name: "Remote Viewer", bundle_id: "example.viewer", active: true, user_request_mentions_app: true });
  expect(annotate("EXAMPLE.VIEWER", inventory)).toBe(output);
  expect(annotate("Remote\n  Viewer", inventory)).toBe(output);
});

test("whole-name and ID matching never select substrings or larger identifiers", () => {
  for (const task of ["Chromebook", "MyChrome", "Chrome-browser", "Chrome.com", "example.Chrome.extra", "example.Chrome-book", "苹果Chrome浏览器", "Chrome\u200Bbook"]) {
    expect(annotate(task, inventory)).toBe(inventory);
  }
  expect(rows(annotate("(chrome)", inventory))[0].user_request_mentions_app).toBe(true);
});

test("zero/multiple app mentions and duplicate inventory identities leave bytes untouched", () => {
  for (const task of ["read the remote machine", "Chrome and Remote Viewer", "example.Chrome and Paper Pad", "x".repeat(8193)]) expect(annotate(task, inventory)).toBe(inventory);
  for (const duplicate of [chrome, '{"name":"Other","bundle_id":"example.chrome"}', '{"name":"CHROME","bundle_id":"example.other"}']) {
    const data = [header(2), chrome, duplicate].join("\n"); expect(annotate("Chrome", data)).toBe(data);
  }
});

test("negative phrasing is only a literal mention fact, not an intent/permission inference", () => {
  const result = rows(annotate("Do not activate Chrome or send any input.", inventory))[0];
  expect(result.user_request_mentions_app).toBe(true);
  expect(Object.keys(result).sort()).toEqual(["active", "bundle_id", "name", "pid", "user_request_mentions_app"]);
  expect(annotate("Chrome", inventory)).toBe(annotate("Do not activate Chrome or send any input.", inventory));
});

test("escaped JSON labels and canonically equivalent Unicode work conservatively", () => {
  const escaped = [header(2), '{"name":"Caf\\u00e9 \\"Pad\\"","bundle_id":"example.cafe"}', viewer].join("\n");
  expect(rows(annotate('CAFE\u0301 "Pad"', escaped))[0].user_request_mentions_app).toBe(true);
});

test("invalid records, duplicate decoded keys, count mismatch and prior annotation fail closed", () => {
  for (const row of ['{"name":"Chrome","bundle_id":"bad/id"}', '{"name":"Chrome","bundle_id":null}',
    '{"name":"Chrome","bundle_id":"example.Chrome","bundle\\u005fid":"example.Other"}',
    '{"name":"Chrome","bundle_id":"example.Chrome",}', '{"name":"Chrome","bundle_id":"example.Chrome","extra":{}}',
    '{"name":"Chrome","bundle_id":"example.Chrome","user_request_mentions_app":false}']) {
    const data = [header(1), row].join("\n"); expect(annotate("Chrome", data)).toBe(data);
  }
  const wrongCount = inventory.replace("returned=3", "returned=2"); expect(annotate("Chrome", wrongCount)).toBe(wrongCount);
});

test("query-scoped or incomplete inventories never establish unique mention metadata", () => {
  for (const data of [inventory.replace("scope=user_facing", "scope=query"),
    inventory.replace("matched=3 returned=3 omitted=0", "matched=4 returned=3 omitted=1")]) {
    expect(annotate("Chrome", data)).toBe(data);
  }
});

test("complete annotated output must fit the UTF-8 byte budget, not character count", () => {
  const data = (padding: string) => [header(2), JSON.stringify({ name: "Chrome", bundle_id: "example.Chrome", padding }), viewer].join("\n");
  const allowance = 3500 - Buffer.byteLength(data("")) - Buffer.byteLength(',"user_request_mentions_app":true');
  const padding = "é".repeat(Math.floor(allowance / 2)) + (allowance % 2 ? "x" : "");
  const exact = data(padding), annotated = annotate("Chrome", exact);
  expect(annotated).not.toBe(exact);
  expect(Buffer.byteLength(annotated)).toBe(3500);
  const oversized = data(padding + "é");
  expect(oversized.length).toBeLessThan(3500);
  expect(annotate("Chrome", oversized)).toBe(oversized);
});
