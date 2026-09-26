import { expect, test } from "bun:test";
import { inspectObservation, observationMode, observationPath } from "./provider-observation";

const instance = "026169a2-f6b8-412b-a081-05241f27e8c4";
const owned = observationMode(`guarded:${instance}`);
const health = { status: "healthy", backend: "mlx-vlm", version: "0.7.1", heydash_instance: instance,
  context_limit: 16384, busy: false, memory: { active_bytes: 100, cache_bytes: 200, peak_bytes: 500 } };

test("guarded mode requires explicit exact nonce and never requests upstream metrics", () => {
  expect(observationPath(owned)).toBe("/health");
  for (const value of ["guarded", "guarded:", "guarded:any", `guarded:${instance.toUpperCase()}`]) {
    expect(() => observationMode(value)).toThrow();
  }
  expect(() => inspectObservation(owned, { ...health, heydash_instance: "different" }, "model")).toThrow();
});

test("owned idle does not claim a loaded model, worker queue, or freed GPU memory", () => {
  const observation = inspectObservation(owned, health, "model");
  expect(observation.idle).toBe(true);
  expect(observation.workerInFlight).toBeNull();
  expect(observation.workerQueueDepth).toBeNull();
  expect(observation.loadedModel).toBeNull();
  expect(observation.memory?.active_bytes).toBe(100);
  expect(inspectObservation(owned, { ...health, busy: true }, "model").idle).toBe(false);
});

test("missing, nonboolean or malformed owned health fails closed", () => {
  for (const value of [null, {}, { ...health, busy: 0 }, { ...health, memory: {} },
    { ...health, memory: { ...health.memory, active_bytes: -1 } }, { ...health, version: "other" }]) {
    expect(() => inspectObservation(owned, value, "model")).toThrow();
  }
});

test("legacy metric observation retains model, worker-in-flight and queue requirements", () => {
  const mode = observationMode();
  expect(observationPath(mode)).toBe("/v1/metrics");
  const metrics = { summary: { in_flight: 0 }, server: { request_queue_depth: 0, loaded_model: "model" } };
  expect(inspectObservation(mode, metrics, "model").idle).toBe(true);
  expect(inspectObservation(mode, metrics, "different").idle).toBe(false);
  expect(inspectObservation(mode, { ...metrics, summary: { in_flight: 1 } }, "model").idle).toBe(false);
  expect(inspectObservation(mode, { ...metrics, server: { ...metrics.server, request_queue_depth: 1 } }, "model").idle).toBe(false);
  expect(() => inspectObservation(mode, health, "model")).toThrow();
});
