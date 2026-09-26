// Benchmark prototype only. Describes necessary local permission prerequisites,
// not authorization, an observed window, target inspectability, or connectivity.
export const INSPECTION_ROUTES_PREFIX = "INSPECTION_ROUTES ";
export const MAX_INSPECTION_ROUTES_BYTES = 400;

type PermissionGrant = "granted" | "not-granted";

function permission(status: unknown, key: "accessibility" | "screenRecording"): PermissionGrant | null {
  if (status === null || typeof status !== "object" || Array.isArray(status)) return null;
  // Consume plain status data only; do not invoke accessors or inherit grants.
  const property = Object.getOwnPropertyDescriptor(status, key);
  const value: unknown = property && "value" in property ? property.value : undefined;
  return value === "granted" || value === "not-granted" ? value : null;
}

export function makeInspectionRoutes(status: unknown): string {
  const accessibilityGranted = permission(status, "accessibility") === "granted";
  const screenRecordingGranted = permission(status, "screenRecording") === "granted";
  const record = {
    scope: "bound_app_window",
    content_state: "unobserved",
    bind_first: "computer_v2_open",
    ax: { tool: "computer_v2_snapshot", permission_ready: accessibilityGranted },
    pixels: { tool: "computer_v2_capture", permission_ready: accessibilityGranted && screenRecordingGranted },
    approval: "checked_at_execution",
    success: "not_guaranteed",
  } as const;
  return INSPECTION_ROUTES_PREFIX + JSON.stringify(record);
}
