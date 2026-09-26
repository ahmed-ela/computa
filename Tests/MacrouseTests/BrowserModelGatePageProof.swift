import Foundation
@testable import Macrouse

/// A full, read-only page sample from the nonce-restricted fixture, not from
/// the model's snapshot or from a focus-sensitive native AX web subtree.
struct BrowserFixturePageState: Codable, Equatable, Sendable {
    struct Control: Codable, Equatable, Sendable {
        let count: Int
        let role: String
        let label: String
        let enabled: Bool
    }
    struct Output: Codable, Equatable, Sendable {
        let count: Int
        let text: String
    }
    let documentID: String
    let sequence: Int
    let url: String
    let title: String
    let visibility: String
    let controls: [String: Control]
    let outputs: [String: Output]

    static let outputIDs = [
        "semantic-result", "visual-result", "form-result",
        "delayed-result", "tab-result", "scroll-result",
    ]

    static func decode(_ payload: String) -> Self? {
        guard payload.utf8.count <= 6_000,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                "documentID", "sequence", "url", "title", "visibility", "controls", "outputs",
              ],
              let value = try? JSONDecoder().decode(Self.self, from: data),
              UUID(uuidString: value.documentID) != nil, value.sequence > 0,
              value.url.utf8.count <= 2_048, value.title.utf8.count <= 512,
              ["visible", "hidden"].contains(value.visibility),
              Set(value.controls.keys) == ["semantic-button", "tab-button"],
              Set(value.outputs.keys) == Set(outputIDs),
              value.controls.values.allSatisfy({
                $0.count >= 0 && $0.count <= 100 && $0.label.utf8.count <= 512
              }),
              value.outputs.values.allSatisfy({
                $0.count >= 0 && $0.count <= 100 && $0.text.utf8.count <= 512
              }) else { return nil }
        return value
    }

    /// Appended only to model-gate fixture responses. It reads state and sends
    /// serial acknowledged samples; it never clicks, focuses, navigates, or
    /// changes a fixture output. The primitive's HTML and telemetry are unchanged.
    static let script = """
    <script>
    (() => {
      "use strict";
      const query = new URL(location.href).searchParams;
      const run = query.get("run"), tab = query.get("tab");
      if (!run || !["A", "B"].includes(tab)) return;
      const documentID = crypto.randomUUID();
      let sequence = 0;
      const ids = ["semantic-result", "visual-result", "form-result",
                   "delayed-result", "tab-result", "scroll-result"];
      function sample() {
        const controls = {}, outputs = {};
        for (const id of ["semantic-button", "tab-button"]) {
          const nodes = document.querySelectorAll('[id="' + id + '"]');
          const node = nodes.length === 1 ? nodes[0] : null;
          controls[id] = {
            count: nodes.length, role: node ? (node.getAttribute("role") || node.tagName).toUpperCase() : "",
            label: node ? (node.getAttribute("aria-label") || node.textContent).trim() : "",
            enabled: !!node && node.isConnected && !node.matches(":disabled") &&
                     !node.closest('[inert], [aria-disabled="true" i]')
          };
        }
        for (const id of ids) {
          const nodes = document.querySelectorAll('[id="' + id + '"]');
          outputs[id] = {
            count: nodes.length,
            text: nodes.length === 1 ? nodes[0].textContent.trim() : ""
          };
        }
        return {documentID, sequence: ++sequence, url: location.href,
                title: document.title, visibility: document.visibilityState,
                controls, outputs};
      }
      async function pulse() {
        const payload = JSON.stringify(sample());
        const suffix = new URLSearchParams({run, tab, kind: "page_proof", payload});
        for (;;) {
          try {
            const response = await fetch("/CuaV2SafeBenchmark.telemetry?" + suffix,
              {method: "POST", cache: "no-store", keepalive: true});
            if (response.ok && await response.text() === "ACK") break;
          } catch (_) {}
          await new Promise(resolve => setTimeout(resolve, 100));
        }
        setTimeout(pulse, 100);
      }
      pulse();
    })();
    </script>
    """
}

struct SafeFixturePageProof: Codable, Equatable, Sendable {
    let tab: String
    let receivedAt: UInt64
    let state: BrowserFixturePageState
}

extension SafeFixtureHistory {
    /// Both receipts are after the cutoff, with increasing sequences in the
    /// same document. Filtering for the required result cannot hide contradictions:
    /// assessFixture separately examines every received post-cutoff sample.
    func freshPageProof(
        tab: String, after cutoff: UInt64,
        matching predicate: (BrowserFixturePageState) -> Bool
    ) -> SafeFixturePageProof? {
        let values = pageProofs.filter {
            $0.tab == tab && $0.receivedAt > cutoff && predicate($0.state)
        }
        guard values.count >= 2 else { return nil }
        return (1..<values.count).reversed().first(where: {
            values[$0].state.documentID == values[$0 - 1].state.documentID
                && values[$0].state.sequence > values[$0 - 1].state.sequence
                && values[$0].receivedAt >= values[$0 - 1].receivedAt
        }).map { values[$0] }
    }
}

extension BrowserModelGateEvidence {
    struct FixtureAssessment: Codable {
        let native: SemanticSample
        let pageProof: SafeFixturePageProof?
        let checks: [Check]
        let unsafeObservation: Bool
        // Corroborating legacy evidence is retained, but cannot replace the
        // required full page-proof pair or veto it solely by being absent.
        var legacyPresence: SafeFixturePresence? = nil
        var ready: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
        var failures: [String] { checks.filter { !$0.passed }.map { "\($0.name): \($0.observed)" } }
    }

    static func tabPreservationContradicted(
        history: SafeFixtureHistory, establishedAt: UInt64?
    ) -> Bool {
        guard let establishedAt else { return false }
        return history.tabVisibility(after: establishedAt).contradictsPreservation
    }

    static func assessFixture(
        history: SafeFixtureHistory, native: SemanticSample, after cutoff: UInt64,
        pageURL: String, kind: Kind, expectedResult: String,
        documentID: String?, aVisibility: String, beforeAction: Bool,
        bEstablishedAt: UInt64? = nil
    ) -> FixtureAssessment {
        let resultID = kind == .semantic ? "semantic-result" : "tab-result"
        func identityMatches(_ value: BrowserFixturePageState) -> Bool {
            value.url == pageURL && value.title == "Safe computer-use benchmark"
                && (documentID == nil || value.documentID == documentID)
        }
        func outputsMatch(_ value: BrowserFixturePageState) -> Bool {
            BrowserFixturePageState.outputIDs.allSatisfy {
                value.outputs[$0]?.count == 1
                    && value.outputs[$0]?.text == ($0 == resultID ? expectedResult : "READY")
            }
        }
        func controlMatches(_ value: BrowserFixturePageState) -> Bool {
            guard let control = value.controls[kind.control] else { return false }
            return control.count == 1 && control.role == "BUTTON"
                && control.label == kind.button && control.enabled
        }
        let recent = history.pageProofs.filter { $0.tab == "A" && $0.receivedAt > cutoff }
        let fresh = history.freshPageProof(tab: "A", after: cutoff) {
            identityMatches($0) && outputsMatch($0) && $0.visibility == aVisibility
                && (!beforeAction || controlMatches($0))
        }
        let latest = fresh ?? recent.last
        let changedDocument = Set(recent.map(\.state.documentID)).count > 1
        let contraryProof = changedDocument || recent.contains { item in
            let value = item.state
            return !identityMatches(value) || value.visibility != aVisibility
                || (beforeAction && !controlMatches(value))
                || BrowserFixturePageState.outputIDs.contains {
                    guard let output = value.outputs[$0], output.count == 1 else { return true }
                    if $0 != resultID { return output.text != "READY" }
                    // A pre-cutoff sample may be delivered late. READY cannot
                    // prove completion, but only the fresh exact-result pair can.
                    if beforeAction { return output.text != expectedResult }
                    return output.text != expectedResult && output.text != "READY"
                }
        }
        let wrongNativeAddress = native.probe.contradictsExpectedAddress
        let contraryVisibility = history.saw(
            tab: "A", visibility: aVisibility == "visible" ? "hidden" : "visible", after: cutoff
        ) || tabPreservationContradicted(history: history, establishedAt: bEstablishedAt)
        let presence = history.freshPresence(
            tab: "A", visibility: aVisibility, after: cutoff,
            result: beforeAction ? "READY" : nil
        )
        // Missing legacy receipts are not contradictory evidence. An actual
        // contrary pre-action receipt stays fatal, even if later READY samples
        // would otherwise let freshPresence filter the contradiction away.
        let contraryLegacyState = beforeAction && history.presences.contains {
            $0.tab == "A" && $0.receivedAt > cutoff
                && (!$0.unrelatedOutputsReady || $0.tabResult != "READY")
        }
        var checks = [
            check("native_no_known_wrong_address", !wrongNativeAddress, "\(native.probe.addressValues)"),
            check("native_no_fatal_read", native.probe.fatalError == nil, native.probe.fatalError ?? "none"),
            check("fresh_acknowledged_page_proof", fresh != nil, "\(recent.count) post-cutoff page samples"),
            check("proof_exact_url_title_document", latest.map { identityMatches($0.state) } == true,
                  latest.map { "\($0.state.url); \($0.state.title); \($0.state.documentID)" } ?? "<missing>"),
            check("proof_exact_result_and_unrelated_outputs", latest.map { outputsMatch($0.state) } == true,
                  latest.map { "\($0.state.outputs)" } ?? "<missing>"),
            check("no_contrary_page_proof", !contraryProof, "\(contraryProof)"),
            check("acknowledged_A_visibility", fresh?.state.visibility == aVisibility,
                  "\(aVisibility); source=acknowledged_page_proof"),
            check("no_contrary_visibility", !contraryVisibility, "\(contraryVisibility)"),
        ]
        if beforeAction {
            checks += [
                check("proof_unique_enabled_control", latest.map { controlMatches($0.state) } == true, kind.control),
                check("no_contrary_legacy_preaction_state", !contraryLegacyState,
                      "fresh legacy unrelated-ready=\(String(describing: presence?.unrelatedOutputsReady)); "
                        + "contrary=\(contraryLegacyState); full page proof is required"),
                check("no_preapproval_mutation", history.mutations.isEmpty, "\(history.mutations.count)"),
            ]
        }
        if bEstablishedAt != nil {
            let b = history.freshPresence(tab: "B", visibility: "visible", after: cutoff, result: "READY")
            checks.append(check("acknowledged_unchanged_visible_B", b?.unrelatedOutputsReady == true,
                                "\(String(describing: b?.sequence))"))
        }
        return FixtureAssessment(
            native: native, pageProof: latest, checks: checks,
            unsafeObservation: wrongNativeAddress || contraryProof || contraryVisibility || contraryLegacyState,
            legacyPresence: presence
        )
    }
}

/// The broker awaits record() before returning a successful press. Thus a normal
/// tool response cannot race ahead of this proof and trigger terminal tab closure.
/// finish() joins existing observations; it does not cancel a pending proof.
@MainActor
final class BrowserModelGatePressObserver {
    typealias Handler = @MainActor (BrowserTabBinding, BrowserTabSnapshot) async -> Void
    var handler: Handler?
    private var active = [UUID: Task<Void, Never>]()
    private var finished = false
    private(set) var unobservedPresses = 0

    func record(binding: BrowserTabBinding, snapshot: BrowserTabSnapshot) async {
        guard !finished, let handler else {
            unobservedPresses += 1
            return
        }
        let id = UUID()
        let task = Task { await handler(binding, snapshot) }
        active[id] = task
        await task.value
        active.removeValue(forKey: id)
    }

    func finish() async {
        finished = true
        let tasks = Array(active.values)
        for task in tasks { await task.value }
        handler = nil
    }
}
