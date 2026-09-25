// Deterministic, offline evidence-association corpus. The runner must send only
// prompt plus the chosen observation, NEVER expected answers or source metadata.
// AX is contract-shaped synthetic input, not output of the production formatter.
export type Split = "development" | "holdout";
export type Backing = "title" | "value" | "both";
export type Layout = "table" | "status-first" | "cards";
export type Answer = Record<string, string | null>;
type Frame = { x: number; y: number; width: number; height: number };
export type Row = { id: string; entity: string; value: string | null; entityBacking: Backing; valueBacking: Backing };
export type Panel = { id: string; heading: string; field: string; layout: Layout; frame: Frame; rows: Row[]; source: "current" | "unrelated" | "stale" };
export type Primitive = ({ kind: "rect"; fill: string; stroke?: string; radius?: number } & Frame
  | { kind: "text"; text: string; x: number; y: number; size: number; fill: string; weight?: number })
  & { id: string; panelID?: string; rowID?: string; field?: "entity" | "value" | "heading" | "column" };
export type AXNode = { id: number; parent: number | null; role: string; title?: string; value?: string; frame?: Frame; panelID?: string; rowID?: string; field?: string };
export type Observation = { snapshotID: string; screenshotSVG: string; primitives: Primitive[]; ax: string; axNodes: AXNode[]; axOmittedNodeIDs: number[] };
export type EvidenceAssociationFixture = Observation & {
  id: string; split: Split; domain: "orders" | "invoices" | "calendar" | "issues";
  width: 1000; height: 650; prompt: string;
  request: { scope: string; panelID: string; entities: string[]; field: string };
  expected: Answer; expectedByView: { screenshot: Answer; ax: Answer };
  tags: string[]; panels: Panel[]; priorObservation?: Observation;
  observations: { renderer: "synthetic-contract-shaped"; captureLabel: string; axOmissionReason: string | null;
    staleSnapshotID: string | null; currentSnapshotID: string };
};

type Spec = {
  id: string; split: Split; domain: EvidenceAssociationFixture["domain"]; title: string;
  panelID: string; entities: string[]; panels: Panel[]; tags: string[];
  omitValues?: string[]; priorValues?: Record<string, string | null>;
};

const MAIN: Frame = { x: 24, y: 112, width: 690, height: 490 };
const SIDE: Frame = { x: 738, y: 112, width: 238, height: 490 };
const LEFT: Frame = { x: 24, y: 112, width: 464, height: 490 };
const RIGHT: Frame = { x: 512, y: 112, width: 464, height: 490 };
const row = (id: string, entity: string, value: string | null, valueBacking: Backing = "value", entityBacking: Backing = "title"): Row =>
  ({ id, entity, value, entityBacking, valueBacking });
const panel = (id: string, heading: string, field: string, rows: Row[], layout: Layout = "table", frame = MAIN,
  source: Panel["source"] = "current"): Panel => ({ id, heading, field, rows, layout, frame: { ...frame }, source });

function specs(): Spec[] {
  return [
    { id: "dev-orders-current-cards", split: "development", domain: "orders", title: "Orders", panelID: "open", entities: ["Oak cable", "Birch adapter"],
      panels: [panel("open", "Open orders", "Delivery", [row("oak", "Oak cable", "Arrives Tuesday", "title"), row("birch", "Birch adapter", "Arrives Saturday", "value")], "cards"),
        panel("activity", "Recent activity", "Delivery", [row("old-oak", "Oak cable", "Delivered Friday", "both")], "cards", SIDE, "unrelated")],
      tags: ["cross-section-distractor", "multiple-entities", "target-first-and-last", "mixed-backing"] },
    { id: "dev-orders-sidebar-only", split: "development", domain: "orders", title: "Orders", panelID: "current", entities: ["Cedar dock"],
      panels: [panel("activity", "Recent activity", "Delivery", [row("cedar-history", "Cedar dock", "Delivered Monday", "title")], "cards", SIDE, "unrelated"),
        panel("current", "Current orders", "Delivery", [row("willow", "Willow cable", "Arrives Thursday")])],
      tags: ["target-only-unrelated-sidebar", "unsupported", "panel-source-order-reversed"] },
    { id: "dev-invoices-truncated-ax", split: "development", domain: "invoices", title: "Invoices", panelID: "outstanding", entities: ["INV-209", "INV-104"],
      panels: [panel("outstanding", "Outstanding invoices", "Status", [row("i104", "INV-104", "Unpaid", "value"), row("i209", "INV-209", "Overdue", "title")]),
        panel("archive", "Archive", "Status", [row("arch104", "INV-104", "Paid", "both")], "cards", SIDE, "unrelated")],
      omitValues: ["i209"], tags: ["ax-value-omitted-screenshot-complete", "request-order-reversed", "mixed-backing"] },
    { id: "dev-invoices-missing-cell", split: "development", domain: "invoices", title: "Invoices", panelID: "current", entities: ["INV-412", "INV-311"],
      panels: [panel("current", "Current invoices", "Status", [row("i311", "INV-311", "Pending", "title"), row("i412", "INV-412", null)], "status-first")],
      tags: ["missing-value", "status-column-first", "request-order-reversed"] },
    { id: "hold-calendar-agenda-cross-section", split: "holdout", domain: "calendar", title: "Calendar", panelID: "today", entities: ["Budget sync", "Design review"],
      panels: [panel("today", "Thursday agenda", "Time", [row("design", "Design review", "14:35", "value", "both"), row("budget", "Budget sync", "09:20", "title")], "cards"),
        panel("earlier", "Wednesday agenda", "Time", [row("old-design", "Design review", "08:10", "title")], "cards", SIDE, "unrelated")],
      tags: ["cross-section-distractor", "heldout-domain", "request-order-reversed", "dual-backed-entity"] },
    { id: "hold-calendar-missing-time", split: "holdout", domain: "calendar", title: "Calendar", panelID: "friday", entities: ["Release review", "Research sync"],
      panels: [panel("friday", "Friday agenda", "Time", [row("research", "Research sync", "16:20", "both"), row("release", "Release review", null)], "status-first")],
      tags: ["missing-value", "status-column-first", "heldout-domain", "target-second"] },
    { id: "hold-issues-duplicate-title", split: "holdout", domain: "issues", title: "Issues", panelID: "ready", entities: ["Retry upload", "Refresh token"],
      panels: [panel("backlog", "Backlog", "Owner", [row("old-retry", "Retry upload", "Lena")], "cards", LEFT, "unrelated"),
        panel("ready", "Ready", "Owner", [row("retry-one", "Retry upload", "Mina", "title"), row("refresh", "Refresh token", "Omar", "both"), row("retry-two", "Retry upload", "Noah", "value")], "cards", RIGHT)],
      tags: ["ambiguous-duplicate-entity", "same-label-across-sections", "current-section-right", "heldout-domain"] },
    { id: "hold-issues-stale-current", split: "holdout", domain: "issues", title: "Issue queue", panelID: "queue", entities: ["API-902", "API-417"],
      panels: [panel("queue", "Current queue", "Status", [row("api902", "API-902", "Waiting", "title"), row("api417", "API-417", "In progress", "value")], "status-first"),
        panel("previous", "Previous export (stale)", "Status", [row("old417", "API-417", "Done", "title"), row("old902", "API-902", "Blocked", "value")], "cards", SIDE, "stale")],
      priorValues: { api902: "Blocked", api417: "Done" }, tags: ["conflicting-stale-current", "prior-observation", "status-column-first", "heldout-domain"] },
    { id: "hold-invoices-nested-summary", split: "holdout", domain: "invoices", title: "Billing workspace", panelID: "review", entities: ["INV-803", "INV-620"],
      panels: [panel("review", "Review required", "Balance", [row("i620", "INV-620", "$63.20", "title"), row("i803", "INV-803", "$18.45", "value")], "cards", RIGHT),
        panel("settled", "Settled invoices", "Balance", [row("old803", "INV-803", "$0.00", "both")], "cards", LEFT, "unrelated")],
      tags: ["novel-currency-field", "current-section-right", "request-order-reversed", "nested-row-value"] },
    { id: "hold-calendar-sidebar-only", split: "holdout", domain: "calendar", title: "Calendar", panelID: "monday", entities: ["Travel catchup"],
      panels: [panel("monday", "Monday agenda", "Time", [row("roadmap", "Roadmap review", "10:45", "title")]),
        panel("upcoming", "Next week", "Time", [row("travel", "Travel catchup", "11:30", "value")], "cards", SIDE, "unrelated")],
      tags: ["target-only-unrelated-sidebar", "unsupported", "heldout-domain"] },
    { id: "hold-issues-board-exact-section", split: "holdout", domain: "issues", title: "Issue board", panelID: "ready", entities: ["TKT-52", "TKT-53"],
      panels: [panel("blocked", "Blocked", "Priority", [row("t52", "TKT-52", "High", "value")], "cards", RIGHT, "unrelated"),
        panel("ready", "Ready", "Priority", [row("t53", "TKT-53", "Normal", "title"), row("t54", "TKT-54", "Urgent", "both")], "cards", LEFT)],
      tags: ["target-only-other-section", "partially-unsupported-list", "panel-source-order-reversed", "current-section-left"] },
    { id: "hold-invoices-clear-control", split: "holdout", domain: "invoices", title: "Invoice detail", panelID: "invoice", entities: ["INV-701"],
      panels: [panel("invoice", "Invoice details", "Status", [row("i701", "INV-701", "Paid", "value", "value")], "cards")],
      tags: ["negative-control-no-distractor", "single-entity", "value-backed-entity"] },
  ];
}

const escapeXML = (text: string) => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const quoted = (text: string) => JSON.stringify(text);
function backed(text: string, backing: Backing): Pick<AXNode, "title" | "value"> {
  return { ...(backing !== "value" ? { title: text } : {}), ...(backing !== "title" ? { value: text } : {}) };
}

function render(spec: Spec, index: number, prior = false): Observation {
  const snapshotID = `00000000-0000-4000-8000-${String(index + (prior ? 100 : 0)).padStart(12, "0")}`;
  const primitives: Primitive[] = [], axNodes: AXNode[] = [], axOmittedNodeIDs: number[] = [];
  const add = (parent: number | null, role: string, attributes: Omit<AXNode, "id" | "parent" | "role"> = {}) => {
    const id = axNodes.length; axNodes.push({ id, parent, role, ...attributes }); return id;
  };
  const rect = (id: string, frame: Frame, fill: string, stroke?: string, radius = 0) =>
    primitives.push({ kind: "rect", id, ...frame, fill, ...(stroke ? { stroke } : {}), radius });
  const text = (id: string, value: string, x: number, y: number, size = 16, weight = 400, fill = "#17212b", meta: Partial<Primitive> = {}) =>
    primitives.push({ kind: "text", id, text: value, x, y, size, weight, fill, ...meta } as Primitive);
  rect("background", { x: 0, y: 0, width: 1000, height: 650 }, "#f5f7fa");
  rect("toolbar", { x: 0, y: 0, width: 1000, height: 82 }, "#ffffff");
  text("page-title", spec.title, 26, 42, 25, 650);
  text("capture-label", prior ? "Updated 09:15" : "Updated 09:45", 850, 42, 14, 400, "#5c6776");
  const root = add(null, "AXWindow", { title: spec.title, frame: { x: 0, y: 0, width: 1000, height: 650 } });
  const document = add(root, "AXWebArea", { title: spec.title });
  for (const p of spec.panels) {
    const { x, y, width, height } = p.frame;
    rect(`${p.id}-panel`, p.frame, "#ffffff", "#dbe1e8", 12);
    text(`${p.id}-heading`, p.heading, x + 16, y + 30, width < 300 ? 15 : 20, 650, "#17212b", { panelID: p.id, field: "heading" });
    const section = add(document, "AXGroup", { panelID: p.id, frame: p.frame });
    add(section, "AXHeading", { title: p.heading, panelID: p.id });
    const rowsParent = add(section, p.layout === "cards" ? "AXGroup" : "AXTable", { panelID: p.id });
    if (p.layout !== "cards") {
      const left = p.layout === "status-first" ? p.field : "Item", right = p.layout === "status-first" ? "Item" : p.field;
      text(`${p.id}-left-column`, left, x + 18, y + 70, 13, 600, "#5c6776", { panelID: p.id, field: "column" });
      text(`${p.id}-right-column`, right, x + width * 0.53, y + 70, 13, 600, "#5c6776", { panelID: p.id, field: "column" });
      add(rowsParent, "AXColumnHeader", { title: left, panelID: p.id });
      add(rowsParent, "AXColumnHeader", { title: right, panelID: p.id });
    }
    p.rows.forEach((r, rowIndex) => {
      const top = y + (p.layout === "cards" ? 52 : 88) + rowIndex * (p.layout === "cards" ? 106 : 76);
      const rowFrame = { x: x + 12, y: top, width: width - 24, height: p.layout === "cards" ? 92 : 62 };
      rect(`${r.id}-background`, rowFrame, rowIndex % 2 === 0 ? "#f4f7fb" : "#ffffff", undefined, 7);
      const group = add(rowsParent, p.layout === "cards" ? "AXGroup" : "AXRow", { panelID: p.id, rowID: r.id, frame: rowFrame });
      const value = prior && spec.priorValues && Object.hasOwn(spec.priorValues, r.id) ? spec.priorValues[r.id] : r.value;
      const entityX = x + (p.layout === "status-first" ? width * 0.53 : 20);
      const valueX = x + (p.layout === "cards" || p.layout === "status-first" ? 20 : width * 0.53);
      const entityY = top + 28, valueY = top + (p.layout === "cards" ? 66 : 28);
      const entityFrame = { x: entityX, y: entityY - 19, width: p.layout === "cards" ? width - 40 : width * 0.43, height: 24 };
      const valueFrame = { x: valueX, y: valueY - 19, width: p.layout === "cards" ? width - 40 : width * 0.43, height: 24 };
      text(`${r.id}-entity`, r.entity, entityX, entityY, width < 300 ? 15 : 17, 600, "#17212b", { panelID: p.id, rowID: r.id, field: "entity" });
      text(`${r.id}-value`, value === null ? "—" : value, valueX, valueY, width < 300 ? 14 : 17, 400,
        value === null ? "#778190" : "#243d59", { panelID: p.id, rowID: r.id, field: "value" });
      add(group, p.layout === "cards" ? "AXHeading" : "AXStaticText", { ...backed(r.entity, r.entityBacking), frame: entityFrame, panelID: p.id, rowID: r.id, field: "entity" });
      // A nested group forces association through ancestry, not merely an
      // immediate sibling heading. The pixels retain exactly the same content.
      const valueParent = spec.tags.includes("nested-row-value") ? add(group, "AXGroup", { panelID: p.id, rowID: r.id }) : group;
      const valueID = add(valueParent, "AXStaticText", { ...(value === null ? {} : backed(value, r.valueBacking)), frame: valueFrame, panelID: p.id, rowID: r.id, field: "value" });
      if (!prior && spec.omitValues?.includes(r.id)) axOmittedNodeIDs.push(valueID);
    });
  }
  const omitted = new Set(axOmittedNodeIDs), shown = axNodes.filter(node => !omitted.has(node.id));
  const parentMap = axNodes.map(node => `${node.id}:${node.parent ?? "-"}`).join(",");
  const ax = [`AXSNAPSHOT id=${snapshotID} pid=4242 app="Workspace" bundle="example.workspace" root=0 shown=${shown.length} total=${axNodes.length} source_truncated=0 output_truncated=${omitted.size ? 1 : 0} parents=[${parentMap}]`,
    ...shown.map(node => `#${node.id} role=${quoted(node.role)}${node.title === undefined ? "" : ` label=${quoted(node.title)}`}${node.value === undefined ? "" : ` value=${quoted(node.value)}`} actions=[]${node.frame ? ` screen_frame=[${node.frame.x},${node.frame.y},${node.frame.width},${node.frame.height}]` : ""} parent=${node.parent ?? "-"}`)].join("\n");
  const shapes = primitives.map(p => p.kind === "rect"
    ? `<rect x="${p.x}" y="${p.y}" width="${p.width}" height="${p.height}" rx="${p.radius ?? 0}" fill="${p.fill}"${p.stroke ? ` stroke="${p.stroke}"` : ""}/>`
    : `<text x="${p.x}" y="${p.y}" font-size="${p.size}" font-weight="${p.weight ?? 400}" fill="${p.fill}">${escapeXML(p.text)}</text>`).join("\n");
  const screenshotSVG = `<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="650" viewBox="0 0 1000 650"><g font-family="Arial, Helvetica, sans-serif">\n${shapes}\n</g></svg>`;
  return { snapshotID, screenshotSVG, primitives, ax, axNodes, axOmittedNodeIDs };
}

/** Twelve fixed cases; keep holdout results unopened until a candidate is frozen. */
export function makeEvidenceAssociationFixtures(): EvidenceAssociationFixture[] {
  return specs().map((spec, index) => {
    const target = spec.panels.find(p => p.id === spec.panelID)!;
    const observation = render(spec, index + 1);
    const expected: Answer = {}, axExpected: Answer = {};
    for (const entity of spec.entities) {
      const matches = target.rows.filter(r => r.entity === entity);
      expected[entity] = matches.length === 1 ? matches[0].value : null;
      axExpected[entity] = matches.length === 1 && !spec.omitValues?.includes(matches[0].id) ? matches[0].value : null;
    }
    const priorObservation = spec.priorValues ? render(spec, index + 1, true) : undefined;
    return { ...observation, id: spec.id, split: spec.split, domain: spec.domain, width: 1000, height: 650,
      request: { scope: target.heading, panelID: target.id, entities: [...spec.entities], field: target.field },
      prompt: `In the current "${target.heading}" section, what is the ${target.field.toLowerCase()} for ${spec.entities.map(quoted).join(" and ")}? Return only one JSON object mapping each exact requested name to its exact displayed value. Do not use Markdown fences or extra text. Use null when that section does not show a value or contains multiple indistinguishable matches. Do not use a different section or an older observation.`,
      expected, expectedByView: { screenshot: { ...expected }, ax: axExpected }, tags: [...spec.tags], panels: spec.panels,
      ...(priorObservation ? { priorObservation } : {}),
      observations: { renderer: "synthetic-contract-shaped", captureLabel: "Updated 09:45",
        axOmissionReason: spec.omitValues?.length ? "The selected AX observation omits these value nodes; screenshot still exposes them." : null,
        staleSnapshotID: priorObservation?.snapshotID ?? null, currentSnapshotID: observation.snapshotID } };
  });
}
