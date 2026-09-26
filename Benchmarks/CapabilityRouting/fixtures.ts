// Frozen synthetic routing corpus. No desktop acquisition, model calls, or tool
// dispatch. Runner-side expectations must never enter model input.
export type ToolArguments = Record<string, string | boolean>;
export type Receipt = { callID: string; name: string; arguments: string; output: string };
export type ExpectedNextAction =
  | { kind: "call"; name: "computer_v2_open" | "computer_v2_capture"; allowedArguments: ToolArguments[] }
  | { kind: "abstain"; reason: "permissions_denied" | "explicit_block" | "login_required" };
export type CapabilityRoutingFixture = {
  id: string; split: "development" | "holdout";
  domain: "remote_viewer" | "virtual_machine" | "pdf" | "canvas" | "dashboard";
  stage: "inventory" | "sparse_ax" | "blocked"; synthetic: true;
  prompt: string; receipts: Receipt[]; expectedNextAction: ExpectedNextAction;
  observedHost: { name: string; bundleID: string; windowTitle: string };
};
export type RoutingResponse = { toolCalls: { name: string; arguments: string }[]; text: string };
export type RoutingOutcome = "correct_call" | "correct_abstention" | "multiple_actions" | "wrong_tool"
  | "wrong_arguments" | "invalid_arguments" | "missing_action" | "action_when_abstention_required"
  | "empty_abstention" | "invalid_response";

type Spec = Omit<CapabilityRoutingFixture, "synthetic" | "receipts" | "expectedNextAction"> & {
  mode: "open" | "capture" | "denied" | "screen_denied" | "blocked" | "login";
  distractor: string; reverseInventory?: boolean;
};
const host = (name: string, slug: string, windowTitle: string) => ({ name, bundleID: `example.synthetic.${slug}`, windowTitle });
function specs(): Spec[] {
  return [
    { id: "dev-remote-host-inventory", split: "development", domain: "remote_viewer", stage: "inventory", mode: "open",
      observedHost: host("Harbor Viewer", "harbor-viewer", "Training Node A"), distractor: "Training Node A",
      prompt: "In the Training Node A desktop displayed by Harbor Viewer, list the open browser tabs. Keep all tabs open." },
    { id: "dev-scanned-pdf-sparse-ax", split: "development", domain: "pdf", stage: "sparse_ax", mode: "capture",
      observedHost: host("PaperFrame", "paperframe", "Sample scan 17.pdf"), distractor: "Sample scan 17.pdf",
      prompt: "Read the total printed on the scanned page currently shown in PaperFrame. Do not modify the document." },
    { id: "dev-canvas-sparse-ax", split: "development", domain: "canvas", stage: "sparse_ax", mode: "capture",
      observedHost: host("ShapeDesk", "shapedesk", "Practice diagram"), distractor: "Practice diagram",
      prompt: "How many blue circles are on the current ShapeDesk canvas? Leave the drawing unchanged." },
    { id: "dev-permissions-denied", split: "development", domain: "remote_viewer", stage: "blocked", mode: "denied",
      observedHost: host("Window Ferry", "window-ferry", "Practice Station"), distractor: "Practice Station",
      prompt: "Read the browser tab titles in the Practice Station desktop shown by Window Ferry. Do not change permissions or settings." },
    { id: "hold-vm-host-not-guest-browser", split: "holdout", domain: "virtual_machine", stage: "inventory", mode: "open", reverseInventory: true,
      observedHost: host("Orbit Machines", "orbit-machines", "Atlas sandbox"), distractor: "Cobalt Browser",
      prompt: "List the tabs in Cobalt Browser inside the Atlas sandbox virtual machine shown in Orbit Machines. Do not use the local browser or close any tabs." },
    { id: "hold-remote-host-not-session-name", split: "holdout", domain: "remote_viewer", stage: "inventory", mode: "open",
      observedHost: host("Horizon Console", "horizon-console", "Training Node Beta"), distractor: "Training Node Beta",
      prompt: "Read the names of the open documents on Training Node Beta, the desktop displayed inside Horizon Console. Leave them open." },
    { id: "hold-dashboard-opaque-surface", split: "holdout", domain: "dashboard", stage: "sparse_ax", mode: "capture",
      observedHost: host("Metric Mosaic", "metric-mosaic", "Sample operations board"), distractor: "Sample operations board",
      prompt: "What value is displayed for the purple series in the current Metric Mosaic chart? Do not edit the dashboard." },
    { id: "hold-image-editor-opaque-surface", split: "holdout", domain: "canvas", stage: "sparse_ax", mode: "capture",
      observedHost: host("Pixel Orchard", "pixel-orchard", "Practice map"), distractor: "Practice map",
      prompt: "Read the three legend labels in the map currently displayed in Pixel Orchard. Keep the image unchanged." },
    { id: "hold-pdf-host-not-document-name", split: "holdout", domain: "pdf", stage: "inventory", mode: "open", reverseInventory: true,
      observedHost: host("Folio Lens", "folio-lens", "SAMPLE-42.pdf"), distractor: "SAMPLE-42.pdf",
      prompt: "Read the handwritten date on SAMPLE-42.pdf, which is open in Folio Lens. Do not edit or reopen the file." },
    { id: "hold-explicit-remote-policy-block", split: "holdout", domain: "virtual_machine", stage: "blocked", mode: "blocked",
      observedHost: host("Nimbus Workbench", "nimbus-workbench", "Test Guest Gamma"), distractor: "Test Guest Gamma",
      prompt: "Read the names of the open windows in Test Guest Gamma through Nimbus Workbench. Do not change connection or policy settings." },
    { id: "hold-remote-login-required", split: "holdout", domain: "remote_viewer", stage: "blocked", mode: "login",
      observedHost: host("Canvas Passage", "canvas-passage", "Example Session Delta"), distractor: "Example Session Delta",
      prompt: "Read the visible task list in Example Session Delta through Canvas Passage. Do not sign in or change session settings." },
    { id: "hold-opaque-screen-permission-denied", split: "holdout", domain: "dashboard", stage: "blocked", mode: "screen_denied",
      observedHost: host("Chart Harbor", "chart-harbor", "Practice graph"), distractor: "Practice graph",
      prompt: "Read the value in the current Chart Harbor graph. Do not request new permissions or change settings." },
  ];
}

export function makeCapabilityRoutingFixtures(): CapabilityRoutingFixture[] {
  return specs().map((spec, index) => {
    const { mode, distractor, reverseInventory, ...fixture } = spec;
    const receipts: Receipt[] = [];
    const add = (name: string, args: ToolArguments, output: string) => receipts.push({
      callID: `call_synthetic_${index + 1}_${receipts.length + 1}`, name, arguments: JSON.stringify(args), output });
    add("computer_v2_status", {}, JSON.stringify({ fixture: "synthetic offline capability observation",
      accessibility: mode === "denied" ? "denied" : "granted",
      screenRecording: ["denied", "screen_denied"].includes(mode) ? "denied" : "granted" }));
    const apps = [
      { pid: 4101, active: true, name: "Local Sample Browser", bundle_id: "example.synthetic.local-browser" },
      { pid: 4102, active: false, name: distractor, bundle_id: "example.synthetic.same-name-local-app" },
      { pid: 4103, active: false, name: spec.observedHost.name, bundle_id: spec.observedHost.bundleID },
    ];
    if (reverseInventory) apps.reverse();
    if (["open", "denied"].includes(mode)) add("computer_v2_apps", {},
      "APPS scope=user_facing matched=3 returned=3 omitted=0. Synthetic local application inventory.\n" + apps.map(app => JSON.stringify(app)).join("\n"));
    else {
      add("computer_v2_open", { bundle_id: spec.observedHost.bundleID }, JSON.stringify({
        fixture: "synthetic native host binding; no real application opened", success: true,
        application: { processIdentifier: 4103, bundleIdentifier: spec.observedHost.bundleID, applicationName: spec.observedHost.name },
        window: { title: spec.observedHost.windowTitle }, bound: true }));
      const snapshotID = `10000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
      if (mode === "blocked" || mode === "login") add("computer_v2_snapshot", {}, JSON.stringify({
        fixture: "synthetic observed host-session state", snapshot_id: snapshotID,
        session_status: mode === "blocked" ? "blocked_by_remote_policy" : "login_required",
        remote_display_available: false,
        observed_text: mode === "blocked" ? "Connection blocked by remote policy." : "Sign in required. No remote desktop is available." }));
      else add("computer_v2_snapshot", {},
        `AXSNAPSHOT id=${snapshotID} pid=4103 app=${JSON.stringify(spec.observedHost.name)} bundle=${JSON.stringify(spec.observedHost.bundleID)} root=0 shown=3 total=3 source_truncated=0 output_truncated=0 parents=[0:-,1:0,2:1]\n`
        + `#0 role="AXWindow" label=${JSON.stringify(spec.observedHost.windowTitle)} actions=[] parent=-\n`
        + '#1 role="AXGroup" actions=[] screen_frame=[0,0,1000,650] parent=0\n'
        + '#2 role="AXImage" actions=[] screen_frame=[0,0,1000,650] parent=1');
    }
    const expectedNextAction: ExpectedNextAction = mode === "open"
      ? { kind: "call", name: "computer_v2_open", allowedArguments: [{ bundle_id: spec.observedHost.bundleID }] }
      : mode === "capture" ? { kind: "call", name: "computer_v2_capture", allowedArguments:
        [undefined, false, true].flatMap(include => [undefined, false, true].map(cursor => ({
          ...(include === undefined ? {} : { include_accessibility: include }),
          ...(cursor === undefined ? {} : { shows_cursor: cursor }),
        }))) }
      : { kind: "abstain", reason: mode === "blocked" ? "explicit_block" : mode === "login" ? "login_required" : "permissions_denied" };
    return { ...fixture, synthetic: true, receipts, expectedNextAction };
  });
}

// Flat argument objects only: all permitted routing arguments are strings or
// booleans. Reject duplicate decoded keys rather than JSON.parse's last-wins.
function parseArguments(raw: string): ToolArguments | null {
  if (typeof raw !== "string" || raw.length > 2048) return null;
  let offset = 0;
  const whitespace = () => { while (/[\x20\t\r\n]/.test(raw[offset] ?? "")) offset++; };
  const string = () => {
    const token = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"/y;
    token.lastIndex = offset;
    const match = token.exec(raw);
    if (!match) throw new Error("string");
    offset = token.lastIndex;
    return JSON.parse(match[0]) as string;
  };
  try {
    whitespace(); if (raw[offset++] !== "{") return null; whitespace();
    const result: ToolArguments = Object.create(null);
    if (raw[offset] !== "}") while (true) {
      const key = string(); if (Object.hasOwn(result, key)) return null;
      whitespace(); if (raw[offset++] !== ":") return null; whitespace();
      if (raw[offset] === '"') result[key] = string();
      else if (raw.slice(offset, offset + 4) === "true") { result[key] = true; offset += 4; }
      else if (raw.slice(offset, offset + 5) === "false") { result[key] = false; offset += 5; }
      else return null;
      whitespace(); if (raw[offset] === "}") break;
      if (raw[offset++] !== ",") return null; whitespace();
    }
    offset++; whitespace(); return offset === raw.length ? result : null;
  } catch { return null; }
}
const canonical = (value: ToolArguments) => JSON.stringify(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)));

/** Only next-action routing, not explanation truth, task success, or model status. */
export function scoreCapabilityRouting(fixture: Pick<CapabilityRoutingFixture, "expectedNextAction">, response: RoutingResponse): { passed: boolean; outcome: RoutingOutcome } {
  const answer = (outcome: RoutingOutcome) => ({ passed: outcome === "correct_call" || outcome === "correct_abstention", outcome });
  if (!response || !Array.isArray(response.toolCalls) || typeof response.text !== "string") return answer("invalid_response");
  if (response.toolCalls.length > 1) return answer("multiple_actions");
  if (fixture.expectedNextAction.kind === "abstain") return answer(response.toolCalls.length
    ? "action_when_abstention_required" : response.text.trim() ? "correct_abstention" : "empty_abstention");
  if (response.toolCalls.length === 0) return answer("missing_action");
  const call = response.toolCalls[0];
  if (!call || call.name !== fixture.expectedNextAction.name) return answer("wrong_tool");
  const args = parseArguments(call.arguments);
  if (!args) return answer("invalid_arguments");
  return answer(fixture.expectedNextAction.allowedArguments.some(allowed => canonical(allowed) === canonical(args)) ? "correct_call" : "wrong_arguments");
}
