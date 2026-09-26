import { expect, test } from "bun:test";
import { inspectHealth, parseIdentity, sameProcess } from "./parent-death-live";

test("process identity requires PID,start time and command; permits only expected reparenting", () => {
  const a = parseIdentity("1234 567 Fri Sep 25 17:35:12 2026 /path/python /owned/server.py --parent-pid 567\n");
  expect(a).not.toBeNull();
  expect(sameProcess(a, { ...a!, parent: 1 })).toBe(true);
  expect(sameProcess(a, { ...a!, pid: 999 })).toBe(false);
  expect(sameProcess(a, { ...a!, started: "different" })).toBe(false);
  expect(sameProcess(a, { ...a!, command: "unrelated" })).toBe(false);
  expect(sameProcess(a, null)).toBe(false);
  expect(parseIdentity("invalid response")).toBeNull();
});

test("health refuses foreign nonce, bad schema, nonfinite memory, and non-pinned runtime", () => {
  const valid = { status: "healthy", backend: "mlx-vlm", version: "0.7.1", heydash_instance: "nonce", busy: false,
    context_limit: 16384, memory: { active_bytes: 0, cache_bytes: 0, peak_bytes: 0 } };
  expect(inspectHealth(valid, "nonce").busy).toBe(false);
  for (const changed of [{ ...valid, heydash_instance: "foreign" }, { ...valid, version: "0.7.2" },
    { ...valid, busy: null }, { ...valid, memory: { ...valid.memory, active_bytes: Infinity } }]) {
    expect(() => inspectHealth(changed, "nonce")).toThrow();
  }
});
