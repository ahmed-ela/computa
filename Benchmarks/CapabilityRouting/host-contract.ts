// Frozen benchmark candidate, not production guidance. The sole intervention
// is one parameter description; preserve every other schema/metadata field.
export const HOST_BUNDLE_ID_DESCRIPTION = "The bundle ID of the local macOS app whose window contains the requested interface. For content shown inside a viewer, virtual machine, or remote desktop app, use that containing app’s bundle ID, not a similarly named local app or an app running inside it. Copy an observed ID; do not infer remote apps are available locally.";

export function withHostContract<T extends { name: string }>(specs: readonly T[]): T[] {
  const clone = structuredClone(specs) as T[];
  const matches = clone.filter(spec => spec.name === "computer_v2_open");
  if (matches.length !== 1) throw new Error("Host contract requires exactly one computer_v2_open spec");
  const open = matches[0] as T & { inputSchema?: any; parameters?: any };
  // Accept either the App Server spec or its Responses wire projection, never
  // guess between two competing schema locations.
  if (Object.hasOwn(open, "inputSchema") === Object.hasOwn(open, "parameters")) throw new Error("Ambiguous host contract schema");
  const bundleID = (open.inputSchema ?? open.parameters)?.properties?.bundle_id;
  if (!bundleID || Array.isArray(bundleID) || typeof bundleID !== "object" || bundleID.type !== "string") throw new Error("Missing string bundle_id parameter");
  bundleID.description = HOST_BUNDLE_ID_DESCRIPTION;
  return clone;
}
