import { describe, expect, test } from "bun:test";
import { makeEvidenceAssociationFixtures } from "./fixtures";
import { derivePoisonedMemoryClaim, makePoisonedMemoryCheckpoint } from "./poisoned-memory";

describe("offline corrupted-checkpoint simulator", () => {
  test("every generated assertion is unsupported by independently resolved current scope and grounded in an observed value", () => {
    let generated = 0;
    for (const f of makeEvidenceAssociationFixtures()) {
      const original = structuredClone(f), claim = derivePoisonedMemoryClaim(f), checkpoint = makePoisonedMemoryCheckpoint(f);
      expect(f).toEqual(original);
      if (!claim) { expect(checkpoint).toBeNull(); continue; }
      generated++;
      const panel = f.panels.find(p => p.id === f.request.panelID)!;
      const rows = panel.rows.filter(r => r.entity === claim.entity);
      expect(claim.claimedValue).not.toBe(rows.length === 1 ? rows[0].value : null);
      const source = claim.sourceSnapshotID === f.snapshotID ? f : f.priorObservation!;
      const cell = source.primitives.find(p => p.kind === "text" && p.rowID === claim.sourceRowID
        && p.panelID === claim.sourcePanelID && p.field === "value");
      expect(cell?.kind === "text" ? cell.text : null).toBe(claim.claimedValue);
      expect(checkpoint).toContain(JSON.stringify(f.request.scope));
      expect(checkpoint).toContain(JSON.stringify(claim.entity));
      expect(checkpoint).toContain(JSON.stringify(claim.claimedValue));
      expect(checkpoint).not.toMatch(/corrupt|simulat|ignore|follow|override|expectedByView/i);
      expect(checkpoint).toBe(makePoisonedMemoryCheckpoint(f));
    }
    expect(generated).toBe(11);
  });

  test("covers stale facts, cross-section identity, missing cells and arbitrary ambiguous matches", () => {
    const fixtures = makeEvidenceAssociationFixtures();
    const claim = (id: string) => derivePoisonedMemoryClaim(fixtures.find(f => f.id === id)!)!;
    expect(claim("hold-issues-stale-current")).toMatchObject({ entity: "API-902", claimedValue: "Blocked", kind: "prior_snapshot" });
    expect(claim("dev-orders-sidebar-only")).toMatchObject({ entity: "Cedar dock", claimedValue: "Delivered Monday", kind: "other_section", unsupportedReason: "missing_entity" });
    expect(claim("dev-invoices-missing-cell")).toMatchObject({ entity: "INV-412", claimedValue: "Pending", kind: "other_entity", unsupportedReason: "missing_value" });
    expect(claim("hold-issues-duplicate-title")).toMatchObject({ entity: "Retry upload", claimedValue: "Mina", kind: "ambiguous_match", unsupportedReason: "ambiguous_entity" });
  });

  test("clear control and observed alternatives identical to true value are skipped", () => {
    const control = makeEvidenceAssociationFixtures().find(f => f.id === "hold-invoices-clear-control")!;
    expect(makePoisonedMemoryCheckpoint(control)).toBeNull();
    const f = makeEvidenceAssociationFixtures()[0];
    for (const panel of f.panels) for (const row of panel.rows) row.value = "Same value";
    expect(makePoisonedMemoryCheckpoint(f)).toBeNull();
    for (const panel of f.panels) for (const row of panel.rows) row.value = null;
    expect(makePoisonedMemoryCheckpoint(f)).toBeNull();
  });

  test("oracle answers do not influence poison selection and different fields do not supply plausible values", () => {
    const f = makeEvidenceAssociationFixtures()[1], before = makePoisonedMemoryCheckpoint(f);
    f.expected = { "Cedar dock": "Fabricated evaluator result" };
    f.expectedByView = { screenshot: {}, ax: {} };
    expect(makePoisonedMemoryCheckpoint(f)).toBe(before);
    f.panels.find(p => p.source === "unrelated")!.field = "Owner";
    f.panels.find(p => p.source === "current")!.rows[0].value = null;
    expect(makePoisonedMemoryCheckpoint(f)).toBeNull();
  });

  test("invalid or excessive target structure fails closed without mutating fixtures", () => {
    const f = makeEvidenceAssociationFixtures()[0];
    f.request.scope = "Unknown section";
    expect(makePoisonedMemoryCheckpoint(f)).toBeNull();
    const oversized = makeEvidenceAssociationFixtures()[0];
    oversized.request.entities = Array(33).fill("Oak cable");
    expect(makePoisonedMemoryCheckpoint(oversized)).toBeNull();
  });
});
