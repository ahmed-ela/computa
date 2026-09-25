import { describe, expect, test } from "bun:test";
import { makeEvidenceAssociationFixtures } from "./fixtures";

describe("deterministic cross-domain evidence association corpus", () => {
  test("freezes four development and eight disjoint holdout cases without mutable reuse", () => {
    const fixtures = makeEvidenceAssociationFixtures();
    expect(fixtures).toHaveLength(12);
    expect(fixtures.filter(f => f.split === "development")).toHaveLength(4);
    expect(fixtures.filter(f => f.split === "holdout")).toHaveLength(8);
    expect(new Set(fixtures.map(f => f.id)).size).toBe(12);
    expect(new Set(fixtures.map(f => f.snapshotID)).size).toBe(12);
    expect(fixtures.filter(f => f.split === "development").every(f => ["orders", "invoices"].includes(f.domain))).toBe(true);
    expect(fixtures.filter(f => ["calendar", "issues"].includes(f.domain)).every(f => f.split === "holdout")).toBe(true);
    expect(makeEvidenceAssociationFixtures()).toEqual(fixtures);
    fixtures[0].panels[0].rows[0].value = "Mutated";
    expect(makeEvidenceAssociationFixtures()[0].expected["Oak cable"]).toBe("Arrives Tuesday");
  });

  test("answers are independently resolvable only within the exact requested section", () => {
    for (const fixture of makeEvidenceAssociationFixtures()) {
      const target = fixture.panels.find(p => p.id === fixture.request.panelID)!;
      expect(target.heading).toBe(fixture.request.scope);
      expect(Object.keys(fixture.expected)).toEqual(fixture.request.entities);
      for (const entity of fixture.request.entities) {
        const rows = target.rows.filter(r => r.entity === entity);
        expect(fixture.expected[entity]).toBe(rows.length === 1 ? rows[0].value : null);
        expect(fixture.expectedByView.screenshot[entity]).toBe(fixture.expected[entity]);
      }
      expect(fixture.prompt).toContain(fixture.request.scope);
      expect(fixture.prompt).toContain("null");
    }
  });

  test("SVGs contain only bounded deterministic drawing primitives, not oracle metadata", () => {
    for (const f of makeEvidenceAssociationFixtures()) {
      expect(f.width).toBe(1000); expect(f.height).toBe(650);
      expect(f.screenshotSVG).toStartWith('<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="650"');
      expect(f.screenshotSVG).not.toMatch(/<script|<image|href=|expectedByView|simulation|synthetic/i);
      expect(new Set(f.primitives.map(p => p.id)).size).toBe(f.primitives.length);
      expect(f.primitives.length).toBeLessThan(100);
      for (const p of f.primitives) {
        expect(p.x).toBeGreaterThanOrEqual(0); expect(p.y).toBeGreaterThanOrEqual(0);
        expect(p.x).toBeLessThan(1000); expect(p.y).toBeLessThan(650);
        if (p.kind === "rect") {
          expect(p.x + p.width).toBeLessThanOrEqual(1000); expect(p.y + p.height).toBeLessThanOrEqual(650);
        } else expect(f.screenshotSVG).toContain(p.text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;"));
      }
      expect(f.prompt).not.toContain("expected");
      expect(f.observations.renderer).toBe("synthetic-contract-shaped");
    }
  });

  test("every nonempty screenshot cell has an exact AX node with the same row and section provenance", () => {
    for (const f of makeEvidenceAssociationFixtures()) {
      expect(new Set(f.axNodes.map(n => n.id)).size).toBe(f.axNodes.length);
      for (const p of f.panels) for (const r of p.rows) for (const field of ["entity", "value"] as const) {
        const primitive = f.primitives.find(v => v.kind === "text" && v.rowID === r.id && v.field === field);
        const node = f.axNodes.find(n => n.rowID === r.id && n.field === field)!;
        expect(primitive?.panelID).toBe(p.id); expect(node.panelID).toBe(p.id);
        const content = field === "entity" ? r.entity : r.value;
        if (content !== null) expect([node.title, node.value]).toContain(content);
        else { expect(node.title).toBeUndefined(); expect(node.value).toBeUndefined(); }
        let current = node;
        const path = new Set<number>();
        while (current.parent !== null) {
          expect(path.has(current.id)).toBe(false); path.add(current.id);
          current = f.axNodes[current.parent];
          expect(current).toBeDefined();
        }
        expect(current.id).toBe(0);
      }
      const lines = f.ax.split("\n").slice(1);
      expect(lines).toHaveLength(f.axNodes.length - f.axOmittedNodeIDs.length);
      for (const node of f.axNodes) expect(lines.some(l => l.startsWith(`#${node.id} `))).toBe(!f.axOmittedNodeIDs.includes(node.id));
    }
  });

  test("declared AX truncation changes only the modality oracle, never hides an omission", () => {
    const affected = makeEvidenceAssociationFixtures().filter(f => f.axOmittedNodeIDs.length);
    expect(affected).toHaveLength(1);
    const f = affected[0];
    expect(f.expectedByView.screenshot["INV-209"]).toBe("Overdue");
    expect(f.expectedByView.ax["INV-209"]).toBeNull();
    expect(f.ax).not.toContain('label="Overdue"');
    expect(f.screenshotSVG).toContain("Overdue");
    expect(f.ax).toContain("source_truncated=0 output_truncated=1");
    expect(f.observations.axOmissionReason).not.toBeNull();
  });

  test("missing, unrelated-only and duplicated names resolve to null despite plausible distractors", () => {
    const fixtures = makeEvidenceAssociationFixtures();
    expect(fixtures.find(f => f.id === "dev-orders-sidebar-only")!.expected["Cedar dock"]).toBeNull();
    expect(fixtures.find(f => f.id === "hold-calendar-sidebar-only")!.expected["Travel catchup"]).toBeNull();
    expect(fixtures.find(f => f.id === "dev-invoices-missing-cell")!.expected["INV-412"]).toBeNull();
    expect(fixtures.find(f => f.id === "hold-issues-duplicate-title")!.expected).toEqual({ "Retry upload": null, "Refresh token": "Omar" });
    expect(fixtures.find(f => f.id === "hold-issues-board-exact-section")!.expected).toEqual({ "TKT-52": null, "TKT-53": "Normal" });
  });

  test("stale/current observations conflict on the same rows with distinct immutable snapshot IDs", () => {
    const f = makeEvidenceAssociationFixtures().find(f => f.priorObservation)!;
    const prior = f.priorObservation!;
    expect(prior.snapshotID).not.toBe(f.snapshotID);
    expect(f.observations.staleSnapshotID).toBe(prior.snapshotID);
    expect(f.expected).toEqual({ "API-902": "Waiting", "API-417": "In progress" });
    for (const [id, oldValue, newValue] of [["api902", "Blocked", "Waiting"], ["api417", "Done", "In progress"]]) {
      const oldNode = prior.axNodes.find(n => n.rowID === id && n.field === "value")!;
      const newNode = f.axNodes.find(n => n.rowID === id && n.field === "value")!;
      expect(oldNode.id).toBe(newNode.id);
      expect([oldNode.title, oldNode.value]).toContain(oldValue);
      expect([newNode.title, newNode.value]).toContain(newValue);
    }
    expect(prior.screenshotSVG).toContain("Updated 09:15");
    expect(f.screenshotSVG).toContain("Updated 09:45");
  });

  test("layouts, backing, target position and requested order are counterbalanced with a clear control", () => {
    const fixtures = makeEvidenceAssociationFixtures();
    expect(new Set(fixtures.flatMap(f => f.panels.map(p => p.layout)))).toEqual(new Set(["table", "cards", "status-first"]));
    expect(new Set(fixtures.flatMap(f => f.panels.flatMap(p => p.rows.map(r => r.valueBacking))))).toEqual(new Set(["title", "value", "both"]));
    expect(fixtures.some(f => f.tags.includes("current-section-left"))).toBe(true);
    expect(fixtures.some(f => f.tags.includes("current-section-right"))).toBe(true);
    expect(fixtures.some(f => f.tags.includes("request-order-reversed"))).toBe(true);
    const control = fixtures.find(f => f.tags.includes("negative-control-no-distractor"))!;
    expect(control.panels).toHaveLength(1); expect(control.panels[0].rows).toHaveLength(1);
    expect(control.expected).toEqual({ "INV-701": "Paid" });
    expect(control.expectedByView.ax).toEqual(control.expectedByView.screenshot);
  });
});
