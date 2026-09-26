// Observation provenance is explicit: guarded health is not a GPU-worker metric.
export type ObservationMode = { kind: "upstream_metrics" } | { kind: "owned_boundary"; instance: string };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function observationMode(value = "metrics"): ObservationMode {
  if (value === "metrics") return { kind: "upstream_metrics" };
  if (value.startsWith("guarded:") && uuid.test(value.slice(8))) {
    return { kind: "owned_boundary", instance: value.slice(8) };
  }
  throw new Error("Observation must be metrics or guarded:<exact-lowercase-launch-UUID>");
}

export function observationPath(mode: ObservationMode) {
  return mode.kind === "owned_boundary" ? "/health" : "/v1/metrics";
}

export function inspectObservation(mode: ObservationMode, value: any, model: string) {
  if (mode.kind === "owned_boundary") {
    if (!value || value.status !== "healthy" || value.backend !== "mlx-vlm" || value.version !== "0.7.1"
      || value.heydash_instance !== mode.instance || typeof value.busy !== "boolean" || value.context_limit !== 16384
      || !["active_bytes", "cache_bytes", "peak_bytes"].every(key =>
        Number.isSafeInteger(value.memory?.[key]) && value.memory[key] >= 0)) {
      throw new Error("Guarded health identity/schema mismatch; refusing to send inference");
    }
    return { source: mode.kind, idle: value.busy === false, instance: value.heydash_instance,
      boundaryBusy: value.busy, workerInFlight: null, workerQueueDepth: null, loadedModel: null,
      memory: value.memory, raw: value };
  }
  if (!value || !Number.isSafeInteger(value.summary?.in_flight) || value.summary.in_flight < 0
    || !Number.isSafeInteger(value.server?.request_queue_depth) || value.server.request_queue_depth < 0) {
    throw new Error("Upstream metrics schema mismatch; refusing to send inference");
  }
  return { source: mode.kind,
    idle: value.summary.in_flight === 0 && value.server.request_queue_depth === 0 && value.server.loaded_model === model,
    instance: null, boundaryBusy: null, workerInFlight: value.summary.in_flight,
    workerQueueDepth: value.server.request_queue_depth, loadedModel: value.server.loaded_model ?? null,
    memory: null, raw: value };
}
