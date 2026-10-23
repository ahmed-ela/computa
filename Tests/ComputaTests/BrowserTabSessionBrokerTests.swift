import AutomationCore
import Foundation
import XCTest
@testable import Computa

final class BrowserTabSessionBrokerTests: XCTestCase {
    func testContinuationFooterPreservesExactArgumentsWithoutNamingAnUnavailableTool() throws {
        let cursor = "opaque-\"\\🙂-cursor"
        let footer = try BrowserCompleteObservation.footer(cursor: cursor)
        let prefix = "\nBROWSER_ACTION_REFERENCES "
        XCTAssertTrue(footer.hasPrefix(prefix))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(footer.dropFirst(prefix.count).utf8)) as? [String: Any])
        let continuation = try XCTUnwrap(metadata["continuation"] as? [String: Any])
        XCTAssertEqual(Set(continuation.keys), ["arguments"])
        XCTAssertEqual(continuation["arguments"] as? [String: String], ["cursor": cursor])
        XCTAssertFalse(footer.contains("browser_continue")); XCTAssertFalse(footer.contains("\"tool\""))
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(footer), 0)
        let completed = try BrowserCompleteObservation.footer(cursor: nil)
        let completedMetadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(completed.dropFirst(prefix.count).utf8)) as? [String: Any])
        XCTAssertNil(completedMetadata["continuation"])
    }

    func testOverviewAssociatesInterleavedRecordHeadingsAndReceiptsWithoutNewAuthority() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        // The live238 Sent view interleaved the fresh heading before the old
        // receipt. Record identity must survive that ordering and a page cut.
        let nodes = [
            semanticNode(0, role: "main", name: "", children: ["n1", "n10", "n20", "n30"]),
            semanticNode(1, role: "heading", name: "Sent messages", parent: "n0"),
            semanticNode(10, role: "article", name: "UNEXPOSED_OLD_CONTAINER", parent: "n0", children: ["n11", "n14", "n12", "n13"]),
            semanticNode(11, role: "heading", name: "ODE schedule test 238", parent: "n10"),
            semanticNode(14, role: "StaticText", name: "To: course-staff@example.invalid", parent: "n10"),
            semanticNode(12, role: "StaticText", name: "Please confirm Tuesday at 10:30 AM.", parent: "n10"),
            semanticNode(13, role: "StaticText", name: "Receipt: LOCAL-dee65262e116fe66", parent: "n10"),
            semanticNode(20, role: "article", name: "UNEXPOSED_FRESH_CONTAINER", parent: "n0", children: ["n21", "n24", "n22", "n23"]),
            semanticNode(21, role: "heading", name: "ODE schedule test 238 fresh", parent: "n20"),
            semanticNode(24, role: "StaticText", name: "To: course-staff@example.invalid", parent: "n20"),
            semanticNode(22, role: "StaticText", name: "Please confirm Tuesday at 10:30 AM.", parent: "n20"),
            semanticNode(23, role: "StaticText", name: "Receipt: LOCAL-d11da0d0c59ffe80", parent: "n20"),
            semanticNode(30, role: "button", name: "Existing action", parent: "n0"),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview), compact: true)
        let source = try XCTUnwrap(page.snapshot.readReceipt?.sourceID)
        var records: [String: String] = [:], seen: [String] = []
        var pages = 0
        repeat {
            pages += 1
            XCTAssertLessThan(pages, 12)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceID, source)
            let complete = page.snapshot.formattedText + (try BrowserCompleteObservation.footer(cursor: page.snapshot.nextCursor))
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(complete), 0)
            XCTAssertLessThanOrEqual(page.snapshot.elements.count, 18)
            XCTAssertFalse(complete.contains("UNEXPOSED_"))
            for row in try XCTUnwrap(page.snapshot.presentation).rows {
                let element = try XCTUnwrap(page.snapshot.element(at: row.index))
                seen.append(element.label)
                if element.recordPath.isEmpty { XCTAssertFalse(row.text.contains(" record_path=")); continue }
                let path = try renderedJSONField("record_path", in: row.text)
                XCTAssertEqual(path, source.uuidString + "/" + element.recordPath.map(String.init).joined(separator: "/"))
                records[element.label] = path
                XCTAssertTrue(row.text.contains(source.uuidString), "Historical whole-row excerpts need their own capture scope")
                XCTAssertFalse(element.supportsPress); XCTAssertFalse(element.supportsSetText)
                XCTAssertFalse(row.text.contains("UNEXPOSED_"))
            }
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor), compact: true)
        } while true
        XCTAssertEqual(records["ODE schedule test 238"], records["Receipt: LOCAL-dee65262e116fe66"])
        XCTAssertEqual(records["ODE schedule test 238 fresh"], records["Receipt: LOCAL-d11da0d0c59ffe80"])
        XCTAssertNotEqual(records["ODE schedule test 238"], records["ODE schedule test 238 fresh"])
        XCTAssertLessThan(try XCTUnwrap(seen.firstIndex(of: "ODE schedule test 238 fresh")),
                          try XCTUnwrap(seen.firstIndex(of: "Receipt: LOCAL-dee65262e116fe66")),
                          "Reproduce cross-record interleaving rather than hiding it in a sorted fixture")
        XCTAssertTrue(seen.contains("Existing action"))
        let filtered = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "LOCAL-", view: .content), compact: true)
        let freshSource = try XCTUnwrap(filtered.snapshot.readReceipt?.sourceID)
        XCTAssertNotEqual(freshSource, source)
        XCTAssertEqual(filtered.snapshot.elements.map(\.recordPath), [[1], [2]])
        for row in try XCTUnwrap(filtered.snapshot.presentation).rows {
            XCTAssertTrue(try renderedJSONField("record_path", in: row.text).hasPrefix(freshSource.uuidString + "/"))
            XCTAssertFalse(row.text.contains(source.uuidString))
        }
        await fixture.assertNoInput()
    }

    func testRecordAncestrySurvivesNestedSubtreeAndEscapedFieldContinuationWithinExistingCaps() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let label = String(repeating: "\"quoted\\cafe\u{301}\" 🧭\n", count: 180) + "EXACT_END"
        let nodes = [semanticNode(0, role: "main", name: "", children: ["n1"]),
                     semanticNode(1, role: "article", name: "", parent: "n0", children: ["n2"]),
                     semanticNode(2, role: "listitem", name: "", parent: "n1", children: ["n3"]),
                     semanticNode(3, role: "StaticText", name: label, parent: "n2")]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes,
            sourceTruncated: true)
        let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true)
        let root = try XCTUnwrap(all.snapshot.elements.first { $0.nodeID == "n2" })
        let source = try XCTUnwrap(all.snapshot.readReceipt?.sourceID)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: all.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: .init(view: .content, snapshotID: all.snapshot.id, elementIndex: root.index), compact: true)
        var reconstructed = "", pages = 0
        repeat {
            pages += 1; XCTAssertLessThan(pages, 20)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceID, source)
            let complete = page.snapshot.formattedText + (try BrowserCompleteObservation.footer(cursor: page.snapshot.nextCursor))
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(complete), 0)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceTruncated, true)
            XCTAssertTrue(complete.contains("source_truncated=1"))
            XCTAssertTrue(complete.contains("Records may span pages. Not input targets or verified outcomes."))
            for row in try XCTUnwrap(page.snapshot.presentation).rows {
                XCTAssertEqual(try renderedJSONField("record_path", in: row.text), source.uuidString + "/1/2")
                XCTAssertNil(row.parentIndex, "Ancestor metadata must not fabricate a parent row outside this selected page")
                let exposure = try XCTUnwrap(page.snapshot.readReceipt?.exposures.first { $0.field == .label })
                XCTAssertEqual(exposure.startUTF8, reconstructed.utf8.count)
                reconstructed += try renderedJSONField("label", in: row.text)
                XCTAssertEqual(exposure.endUTF8, reconstructed.utf8.count)
            }
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor), compact: true)
        } while true
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(Data(reconstructed.utf8), Data(label.utf8))
        await fixture.assertNoInput()
    }

    func testFreshCaptureRecordRenumberingPreservesOnlyCorroboratedPublishedActionAuthority() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let target = fixture.observation.binding.targetID, committedID = UUID()
        let nodes = [semanticNode(10, role: "article", name: "", children: ["n11"]),
                     semanticNode(11, role: "button", name: "Existing action", parent: "n10")]
        try await fixture.transport.replaceNodes(targetID: target, nodes: nodes)
        try await fixture.transport.setCommittedDocumentID(targetID: target, id: committedID)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true)
        let original = try XCTUnwrap(first.snapshot.actionWitnesses[1])
        XCTAssertEqual(original.element.recordPath, [1])
        // A different source-order record precedes the unchanged target in the
        // same committed document. Only passive group numbering changes.
        try await fixture.transport.replaceNodes(targetID: target,
            nodes: [semanticNode(20, role: "article", name: "Unrelated record")] + nodes)
        try await fixture.transport.setCommittedDocumentID(targetID: target, id: committedID)
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true,
            priorPublishedActions: [original])
        let proof = try XCTUnwrap(fresh.snapshot.corroboratedActionWitnesses.first)
        XCTAssertEqual(fresh.snapshot.elements.first { $0.nodeID == "n11" }?.recordPath, [2])
        XCTAssertNotEqual(first.snapshot.readReceipt?.sourceID, fresh.snapshot.readReceipt?.sourceID)
        XCTAssertEqual(proof.publicationID, original.publicationID)
        XCTAssertEqual(proof.element.recordPath, [1], "Original published target remains frozen")
        XCTAssertEqual(proof.exposures, original.exposures)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.validatePublishedAction(taskKey: "task-a", binding: fresh.binding, witness: original)
        }
        try await fixture.broker.validatePublishedAction(taskKey: "task-a", binding: fresh.binding, witness: proof)
        _ = try await fixture.broker.perform(taskKey: "task-a", binding: fresh.binding, witness: proof, action: "AXPress")
        let count = await fixture.transport.pressCount(targetID: target)
        XCTAssertEqual(count, 1)
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.perform(taskKey: "task-a", binding: fresh.binding, witness: proof, action: "AXPress")
        }
        let finalCount = await fixture.transport.pressCount(targetID: target)
        XCTAssertEqual(finalCount, 1)
    }

    func testRecordAncestryFailsClosedOnIncompleteIgnoredDuplicateCyclicOrDeepAncestors() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let target = semanticNode(1, role: "StaticText", name: "Target", parent: "n2")
        let ignored = BrowserDocumentNode(backendNodeID: 3, role: "article", name: "HIDDEN_PARENT",
            value: nil, isDisabled: false, isReadOnly: true, isIgnored: true, nodeID: "n2")
        let cases: [[BrowserDocumentNode]] = [
            [target],
            [target, ignored],
            [target, semanticNode(2, role: "article", name: "A"), semanticNode(2, role: "article", name: "B")],
            [target, semanticNode(2, role: "article", name: "", parent: "n3"), semanticNode(3, role: "article", name: "", parent: "n2")],
            [target] + (2...10).map { semanticNode($0, role: "article", name: "", parent: $0 == 10 ? nil : "n\($0 + 1)") },
        ]
        for nodes in cases {
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            let page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Target", view: .all), compact: true)
            XCTAssertEqual(page.snapshot.elements.count, 1)
            XCTAssertEqual(page.snapshot.elements.first?.recordPath, [])
            XCTAssertFalse(page.snapshot.formattedText.contains("record_path="))
            XCTAssertFalse(page.snapshot.formattedText.contains("HIDDEN_PARENT"))
        }
        var action = BrowserTabElement(index: 0, backendNodeID: 1, role: "AXButton", label: "Action",
            value: nil, isEnabled: true, supportsPress: true, supportsSetText: false, recordPath: [1])
        let prior = action
        action.recordPath = [22, 23]
        XCTAssertTrue(action.hasIdenticalActionSemantics(to: prior), "Capture-local record renumbering cannot change input authority")
        await fixture.assertNoInput()
    }

    func testLegacyPressBackendDefaultFeedbackAdapterDispatchesExactlyOnce() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let feedback = try await fixture.broker.perform(taskKey: "task-a", binding: fixture.observation.binding,
            snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress")
        XCTAssertNil(feedback)
        let count = await fixture.transport.pressCount(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(count, 1)
        do {
            _ = try await fixture.broker.perform(taskKey: "task-a", binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress")
            XCTFail("A consumed click cannot be replayed by the optional feedback adapter")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let unchanged = await fixture.transport.pressCount(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(unchanged, 1)
    }

    func testCompactPagesPreserveEveryEscapedFieldByteAndFollowingRowsWithoutCursorSkips() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let label = "e\u{301}" + String(repeating: "🙂\\\"\n\t\u{0001}", count: 220) + " EXACT_LABEL_TAIL"
        let value = String(repeating: "\\\"\n", count: 250) + " EXACT_VALUE_TAIL"
        let link = "https://example.test/" + String(repeating: "quoted%22/path/", count: 180) + "destination"
        let nodes = [semanticNode(0, role: "textbox", name: label, link: link, value: value)]
            + (1...8).map { semanticNode($0, role: "button", name: "Following control \($0)") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: nodes, sourceTruncated: true)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true)
        let source = try XCTUnwrap(page.snapshot.readReceipt?.sourceID)
        var reconstructed: [String: String] = [:]
        var pages = 0
        while true {
            pages += 1
            XCTAssertLessThan(pages, 32)
            let receipt = try XCTUnwrap(page.snapshot.readReceipt)
            XCTAssertEqual(receipt.sourceID, source)
            XCTAssertEqual(receipt.selectedElementCount, nodes.count)
            XCTAssertTrue(receipt.sourceTruncated)
            XCTAssertEqual(receipt.outputTruncated, page.snapshot.nextCursor != nil)
            let complete = page.snapshot.formattedText + (try BrowserCompleteObservation.footer(cursor: page.snapshot.nextCursor))
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(complete), 0)
            XCTAssertTrue(complete.contains("source_truncated=1"))
            let rows = try XCTUnwrap(page.snapshot.presentation).rows
            for exposure in receipt.exposures {
                let element = try XCTUnwrap(page.snapshot.elements.first { "backend:\($0.backendNodeID)" == exposure.nodeID })
                let row = try XCTUnwrap(rows.first { $0.index == element.index }).text
                let key = "\(exposure.nodeID):\(exposure.field.rawValue)"
                XCTAssertEqual(exposure.startUTF8, reconstructed[key, default: ""].utf8.count)
                let partial = exposure.startUTF8 != 0 || exposure.endUTF8 != exposure.totalUTF8
                let field = exposure.field == .linkURL ? (partial ? "href_fragment" : "href") : exposure.field.rawValue
                let emitted = try renderedJSONField(field, in: row)
                XCTAssertEqual(emitted.utf8.count, exposure.endUTF8 - exposure.startUTF8)
                reconstructed[key, default: ""] += emitted
                if exposure.field == .linkURL, partial { XCTAssertFalse(row.contains(" href=")) }
            }
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor), compact: true)
        }
        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(Array(reconstructed["backend:1:label", default: ""].utf8), Array(label.utf8))
        XCTAssertEqual(reconstructed["backend:1:value"], value)
        XCTAssertEqual(reconstructed["backend:1:linkURL"], link)
        for id in 1...8 { XCTAssertEqual(reconstructed["backend:\(id + 1):label"], "Following control \(id)") }
        await fixture.assertNoInput()
    }

    func testCompactDocumentPagesKeepUsefulCapacityAndExactReadOnlyProvenance() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let passage = "The documented setting is managed by the workspace administrator. Review supported settings before changing configuration. "
        let nodes = [semanticNode(0, role: "main", name: "", children: (1...18).map { "n\($0)" })]
            + (1...18).map { semanticNode($0, role: "StaticText", name: "Section \($0). " + passage, parent: "n0") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content), compact: true)
        let receipt = try XCTUnwrap(read.snapshot.readReceipt)
        let full = read.snapshot.formattedText + (try BrowserCompleteObservation.footer(cursor: read.snapshot.nextCursor))
        let usefulBytes = receipt.exposures.reduce(0) { $0 + $1.endUTF8 - $1.startUTF8 }
        XCTAssertGreaterThanOrEqual(read.snapshot.elements.count, 5)
        XCTAssertGreaterThan(Double(usefulBytes) / Double(full.utf8.count), 0.20)
        XCTAssertEqual(receipt.selectedElementCount, 18)
        XCTAssertTrue(receipt.exposures.allSatisfy { $0.kind == .readable && $0.provenance == .main })
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(full), 0)
        XCTAssertTrue(full.contains("Use content for message/document text; all includes toolbars."))
        XCTAssertFalse(full.contains("click_ref=")); XCTAssertFalse(full.contains("fill_ref="))
        print("COMPACT_READ_CAPACITY rows=\(read.snapshot.elements.count) bytes=\(full.utf8.count) field_bytes=\(usefulBytes) field_ratio=\(Double(usefulBytes) / Double(full.utf8.count)) footer_bytes=\(try BrowserCompleteObservation.footer(cursor: read.snapshot.nextCursor).utf8.count)")
        await fixture.assertNoInput()
    }

    func testCompactContentSignalsFilteredInputNodesWithoutExposingTheirLabelsOrAuthority() async throws {
        for truncated in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            let nodes = [
                semanticNode(0, role: "heading", name: "Pick an account"),
                semanticNode(1, role: "button", name: "PRIVATE_ACCOUNT_LABEL"),
                semanticNode(2, role: "textbox", name: "PRIVATE_FIELD_LABEL"),
                semanticNode(3, role: "button", name: "DISABLED_LABEL", disabled: true),
                semanticNode(4, role: "textbox", name: "READ_ONLY_LABEL", readOnly: true),
                BrowserDocumentNode(backendNodeID: 6, role: "button", name: "IGNORED_LABEL", value: nil,
                    isDisabled: false, isReadOnly: false, isIgnored: true, nodeID: "n5"),
                BrowserDocumentNode(backendNodeID: 7, role: "button", name: "NO_PRESS_LABEL", value: nil,
                    isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "n6", isPressUnsupported: true),
            ]
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: nodes, sourceTruncated: truncated, semanticReadiness: .ready)
            let before = await fixture.transport.readinessRequests().count
            let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content), compact: true)
            let after = await fixture.transport.readinessRequests().count
            XCTAssertEqual(after, before + 1, "The signal uses the existing capture, without another read")
            let text = read.snapshot.formattedText
            XCTAssertTrue(text.contains("VIEW content omitted_input_nodes=2 basis=captured_view_and_query."))
            XCTAssertTrue(text.contains("Read overview/all without cursor/query for controls before an access-block claim."))
            XCTAssertTrue(text.contains("source_truncated=\(truncated ? 1 : 0)"))
            XCTAssertTrue(text.contains("not website search or proof of relevance/absence"))
            XCTAssertEqual(read.snapshot.elements.map(\.label), ["Pick an account"])
            for hidden in ["PRIVATE_ACCOUNT_LABEL", "PRIVATE_FIELD_LABEL", "DISABLED_LABEL", "READ_ONLY_LABEL", "IGNORED_LABEL", "NO_PRESS_LABEL"] {
                XCTAssertFalse(text.contains(hidden))
            }
            XCTAssertTrue(read.snapshot.actionWitnesses.isEmpty)
            XCTAssertFalse(text.contains("click_ref=")); XCTAssertFalse(text.contains("fill_ref="))
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(text + BrowserCompleteObservation.footer(cursor: nil)), 0)
            await fixture.assertNoInput()

            let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: read.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true)
            XCTAssertFalse(all.snapshot.formattedText.contains("omitted_input_nodes="))
            let account = try XCTUnwrap(all.snapshot.elements.first { $0.label == "PRIVATE_ACCOUNT_LABEL" })
            XCTAssertNotNil(all.snapshot.actionWitnesses[account.index])
            try await fixture.broker.perform(taskKey: "task-a", binding: all.binding,
                snapshot: all.snapshot, elementIndex: account.index, action: "AXPress")
            let pressed = await fixture.transport.pressedNodeIDs(targetID: all.binding.targetID)
            XCTAssertEqual(pressed, [2], "Only the subsequently published exact control receives input")
        }
    }

    func testCompactAllViewQueryReportsOnlyControlsExcludedByTheLocalSelection() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "heading", name: "Selected heading"),
            semanticNode(1, role: "button", name: "Selected button"),
            semanticNode(2, role: "textbox", name: "PRIVATE_OTHER_FIELD"),
        ])
        let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Selected", view: .all), compact: true)
        XCTAssertTrue(read.snapshot.formattedText.contains("VIEW all omitted_input_nodes=1 basis=captured_view_and_query."))
        XCTAssertFalse(read.snapshot.formattedText.contains("PRIVATE_OTHER_FIELD"))
        XCTAssertEqual(read.snapshot.totalMatches, 2)
        XCTAssertEqual(read.snapshot.elements.map(\.label), ["Selected heading", "Selected button"])
        XCTAssertEqual(read.snapshot.actionWitnesses.count, 1)
        XCTAssertEqual(try selectionEvidence(read.snapshot)["site_search_evaluated"] as? Bool, false)
        await fixture.assertNoInput()
    }

    func testCompactFilteredInputCountFollowsTheImmutableSelectionRatherThanLiveChangesOrPages() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = (0..<18).map { semanticNode($0, role: "StaticText", name: "Passage \($0) " + String(repeating: "observed text ", count: 18)) }
            + [semanticNode(18, role: "button", name: "PRIVATE_FILTERED_CONTROL")]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content), compact: true)
        let source = page.snapshot.readReceipt?.sourceID
        // Continuation revalidates the document but retains its original capture.
        try await fixture.transport.replaceNodes(targetID: page.binding.targetID,
            nodes: Array(nodes.dropLast()))
        var pages = 0
        var seen = Set<Int64>()
        while true {
            pages += 1
            XCTAssertLessThan(pages, 20)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceID, source)
            XCTAssertEqual(page.snapshot.totalMatches, 18)
            XCTAssertTrue(page.snapshot.formattedText.contains("omitted_input_nodes=1"))
            XCTAssertFalse(page.snapshot.formattedText.contains("PRIVATE_FILTERED_CONTROL"))
            XCTAssertTrue(page.snapshot.actionWitnesses.isEmpty)
            let complete = page.snapshot.formattedText + (try BrowserCompleteObservation.footer(cursor: page.snapshot.nextCursor))
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(complete), 0)
            seen.formUnion(page.snapshot.elements.map(\.backendNodeID))
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor), compact: true)
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen, Set((1...18).map(Int64.init)))
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content), compact: true)
        XCTAssertFalse(fresh.snapshot.formattedText.contains("omitted_input_nodes="))
        await fixture.assertNoInput()
    }

    func testCompactPaginationDoesNotMislabelSelectedControlsAsFilteredOut() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: (0..<45).map { semanticNode($0, role: "button", name: "Selected control \($0)") })
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true)
        var pages = 0
        var seen = Set<Int64>()
        while true {
            pages += 1
            XCTAssertLessThan(pages, 20)
            XCTAssertEqual(page.snapshot.totalMatches, 45)
            XCTAssertFalse(page.snapshot.formattedText.contains("omitted_input_nodes="))
            seen.formUnion(page.snapshot.elements.map(\.backendNodeID))
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor), compact: true)
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen, Set((1...45).map(Int64.init)))
        await fixture.assertNoInput()
    }

    func testCompactFilteredInputSignalRespectsSubtreeAndDoesNotInferAbsenceFromIncompleteCapture() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "generic", name: "Observed subtree", children: ["n1"]),
            semanticNode(1, role: "heading", name: "Selected heading", parent: "n0"),
            semanticNode(2, role: "button", name: "PRIVATE_OUTSIDE_CONTROL"),
        ], sourceTruncated: true)
        let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all), compact: true)
        let root = try XCTUnwrap(all.snapshot.elements.first { $0.nodeID == "n0" })
        let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: all.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: .init(view: .content, snapshotID: all.snapshot.id, elementIndex: root.index), compact: true)
        XCTAssertEqual(read.snapshot.elements.map(\.label), ["Selected heading"])
        XCTAssertTrue(read.snapshot.formattedText.contains("scope=subtree"))
        XCTAssertTrue(read.snapshot.formattedText.contains("source_truncated=1"))
        XCTAssertTrue(read.snapshot.formattedText.contains("not website search or proof of relevance/absence"))
        XCTAssertFalse(read.snapshot.formattedText.contains("omitted_input_nodes="))
        XCTAssertFalse(read.snapshot.formattedText.contains("PRIVATE_OUTSIDE_CONTROL"))
        XCTAssertTrue(read.snapshot.actionWitnesses.isEmpty)
        await fixture.assertNoInput()
    }

    func testCompletedReadOmitsCursorFieldWithoutRewritingLiteralPageText() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let literal = "Observed documentation: next_cursor=none"
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "main", name: "", children: ["n1"]),
            semanticNode(1, role: "StaticText", name: literal, parent: "n0"),
        ])
        for view in [SemanticReadView.all, .overview, .content] {
            for query in [nil, "Absent fixture text"] as [String?] {
                let observed = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                    bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: query, view: view))
                let read = try XCTUnwrap(observed.snapshot.formattedText.split(separator: "\n").first { $0.hasPrefix("READ ") })
                XCTAssertNil(observed.snapshot.nextCursor)
                XCTAssertFalse(read.contains("next_cursor="), "An absent continuation must not look like a usable token")
                XCTAssertTrue(read.contains("output_truncated=0"))
                let receipt = try XCTUnwrap(observed.snapshot.readReceipt)
                XCTAssertFalse(receipt.outputTruncated)
                if query == nil {
                    XCTAssertTrue(observed.snapshot.formattedText.contains(literal), "Only native metadata changes, never page text")
                    let exposure = try XCTUnwrap(receipt.exposures.first { $0.nodeID == "backend:2" && $0.field == .label })
                    XCTAssertEqual(exposure.startUTF8, 0); XCTAssertEqual(exposure.endUTF8, literal.utf8.count)
                } else {
                    XCTAssertTrue(observed.snapshot.elements.isEmpty); XCTAssertTrue(receipt.exposures.isEmpty)
                }
            }
        }
        await fixture.assertNoInput()
    }

    func testConstraintMetadataRemainsAttachedToItsPublishedRowWithinReadBudgets() async throws {
        for view in [SemanticReadView.all, .overview] {
            let fixture = try await BrowserBrokerTestFixture.make()
            let state = BrowserConstraintValidation(required: true, candidate: true, valid: false, issues: [.valueMissing])
            let longLabel = String(repeating: "🙂 quoted \"field\" ", count: 400) + "UNPUBLISHED_TAIL"
            let nodes: [BrowserDocumentNode] = (1...25).map { (index: Int) -> BrowserDocumentNode in
                let label: String = index == 1 ? longLabel : "Field \(index)"
                let constraints: BrowserConstraintValidation? = index == 1 ? state : nil
                return BrowserDocumentNode(backendNodeID: Int64(index), role: "textbox",
                    name: label, value: "",
                    isDisabled: false, isReadOnly: false, isIgnored: false,
                    nodeID: "n\(index)", isEditable: true, constraintValidation: constraints)
            }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: view))
            XCTAssertFalse(page.snapshot.formattedText.contains("UNPUBLISHED_TAIL"))
            var pages = 0, seen = Set<Int64>()
            repeat {
                pages += 1
                let rows = try XCTUnwrap(page.snapshot.presentation).rows
                let bodyBytes = rows.reduce(0) { $0 + $1.text.utf8.count + 1 + SemanticReadPresentation.rowMetadataByteReserve }
                XCTAssertLessThanOrEqual(bodyBytes, view == .overview ? 6_000 : 10_000)
                XCTAssertLessThanOrEqual(page.snapshot.formattedText.utf8.count, 16_384)
                for row in rows {
                    let element = try XCTUnwrap(page.snapshot.element(at: row.index))
                    seen.insert(element.backendNodeID)
                    XCTAssertEqual(row.text.contains("required=true constraint=invalid[value_missing]"), element.backendNodeID == 1)
                    XCTAssertEqual(row.text.contains("constraint="), element.constraintValidation != nil)
                    XCTAssertTrue(page.snapshot.formattedText.contains(row.text))
                }
                guard let cursor = page.snapshot.nextCursor else { break }
                XCTAssertLessThan(pages, 20, "Continued metadata cannot prevent byte progress")
                page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                    bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
            } while true
            XCTAssertGreaterThan(pages, 1)
            XCTAssertEqual(seen, Set((1...25).map(Int64.init)))
            await fixture.assertNoInput()
        }
    }

    func testContentReadinessIsRequestedOnlyForFreshContentNotQueryContinuationOrSubtree() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes:
            (0..<100).map { semanticNode($0, role: "StaticText", name: "Observed row \($0)") })
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "Observed", view: .content))
        let cursor = try XCTUnwrap(first.snapshot.nextCursor)
        let continuation = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(cursor: cursor))
        let subtree = try await fixture.broker.snapshot(taskKey: "task-a", binding: continuation.binding,
            bundleIdentifier: "com.ahmedelamin.computa",
            read: .init(view: .content, snapshotID: continuation.snapshot.id, elementIndex: 0))
        XCTAssertEqual(subtree.snapshot.elements.count, 1)
        let afterRetained = await fixture.transport.readinessRequests()
        XCTAssertEqual(afterRetained, [.semanticContent, .content], "Retained reads stay immutable and use only immediate identity preflight")
        _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: subtree.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "Absent", view: .all))
        let afterAll = await fixture.transport.readinessRequests()
        XCTAssertEqual(afterAll, [.semanticContent, .content, .semanticContent], "Query text does not determine the readiness mode")
        await fixture.assertNoInput()
    }

    func testPresentationOffersFillWithoutPressForEditableTextFieldsAndPreservesOtherControls() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = [
            semanticNode(0, role: "RootWebArea", name: "Workspace", children: (1...7).map { "n\($0)" }),
            semanticNode(1, role: "textbox", name: "Text query", parent: "n0", value: "", clickable: true),
            semanticNode(2, role: "searchbox", name: "Search query", parent: "n0", value: "", focusablePointer: true),
            semanticNode(3, role: "combobox", name: "Choose record", parent: "n0", value: "", clickable: true),
            semanticNode(4, role: "textbox", name: "Read only query", parent: "n0", value: "Fixed", clickable: true, readOnly: true),
            semanticNode(5, role: "checkbox", name: "Include archived", parent: "n0"),
            semanticNode(6, role: "button", name: "Submit query", parent: "n0"),
            semanticNode(7, role: "searchbox", name: "Disabled query", parent: "n0", value: "", clickable: true, disabled: true),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let snapshot = observation.snapshot
        let presentation = try XCTUnwrap(snapshot.presentation)
        XCTAssertEqual(presentation.rows.map(\.text),
            snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init))
        let prepared = try ComputerModelReferences().prepare(items: [ComputerModelReferences.attach(
            item: ["type": "inputText", "text": snapshot.formattedText], presentation: presentation)], scope: "browser-fields")
        let menu = try XCTUnwrap(prepared.contentItems.first?["text"] as? String)
        for index in 1...7 {
            let element = try XCTUnwrap(snapshot.elements.first { $0.index == index })
            let row = try XCTUnwrap(presentation.rows.first { $0.index == index })
            let line = try XCTUnwrap(menu.split(separator: "\n").first { $0.contains("label=\"\(element.label)\"") })
            XCTAssertTrue(element.supportsPress, "The menu preference must preserve the legacy capability.")
            XCTAssertTrue(row.text.contains("actions=[\"AXPress\"]"), "Exact legacy rows are not rewritten by presentation metadata.")
            XCTAssertTrue(row.region)
            if [1, 2].contains(index) {
                XCTAssertTrue(element.supportsSetText)
                XCTAssertTrue(row.settable)
                XCTAssertEqual(row.actions, [])
                XCTAssertTrue(line.contains("field_ref="))
                XCTAssertFalse(line.contains("action_ref="))
            } else if index == 7 {
                XCTAssertEqual(row.actions, [])
                XCTAssertFalse(row.settable)
                XCTAssertFalse(line.contains("field_ref="))
                XCTAssertFalse(line.contains("action_ref="))
            } else {
                XCTAssertEqual(row.actions, ["AXPress"])
                XCTAssertEqual(row.settable, index == 3, "Comboboxes retain both choices; readonly and other controls are not fillable.")
                XCTAssertEqual(line.contains("field_ref="), index == 3)
                XCTAssertTrue(line.contains("action_ref="))
            }
        }
        await fixture.assertNoInput()
    }

    func testPresentationUsesExactPublishedRowsWithoutReconstructingHiddenFields() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let longLabel = String(repeating: "🙂 quoted \"value\" ", count: 1_200) + "UNPUBLISHED_TAIL"
        let nodes = [
            semanticNode(0, role: "RootWebArea", name: "Workspace", children: (1...7).map { "n\($0)" }),
            semanticNode(1, role: "navigation", name: "History", parent: "n0"),
            semanticNode(2, role: "button", name: "Search", parent: "n0"),
            semanticNode(3, role: "searchbox", name: "Query", parent: "n0", value: ""),
            semanticNode(4, role: "link", name: "Archive", parent: "n0", link: "https://example.com/archive"),
            semanticNode(5, role: "button", name: "Disabled", parent: "n0", disabled: true),
            semanticNode(6, role: "StaticText", name: longLabel, parent: "n0"),
            semanticNode(7, role: "button", name: "Unpublished control", parent: "n0"),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let snapshot = observation.snapshot
        let presentation = try XCTUnwrap(snapshot.presentation)
        let rows = snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init)
        XCTAssertEqual(presentation.snapshotID, snapshot.id)
        XCTAssertEqual(presentation.maximumOutputBytes, 16_384)
        XCTAssertEqual(presentation.rows.map(\.text), rows)
        XCTAssertEqual(presentation.rows.map(\.index), snapshot.elements.map(\.index))
        XCTAssertTrue(snapshot.elements.contains { $0.label == longLabel }, "Internal action evidence retains the full field.")
        XCTAssertFalse(presentation.rows.contains { $0.text.contains("UNPUBLISHED_TAIL") })
        XCTAssertFalse(presentation.rows.contains { $0.text.contains("Unpublished control") })
        XCTAssertEqual(presentation.rows[1].actions, [])
        XCTAssertEqual(presentation.rows[2].actions, ["AXPress"])
        XCTAssertTrue(presentation.rows[3].settable)
        XCTAssertTrue(presentation.rows[4].followLink)
        XCTAssertEqual(presentation.rows[5].actions, [])
        XCTAssertFalse(presentation.rows[5].settable)
        XCTAssertTrue(presentation.rows.allSatisfy(\.region))
        XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.utf8.count + 1 }
            + rows.count * SemanticReadPresentation.rowMetadataByteReserve, 10_000)
        let exposure = try XCTUnwrap(snapshot.readReceipt?.exposures.first { $0.nodeID == "backend:7" && $0.field == .label })
        XCTAssertLessThan(exposure.endUTF8, exposure.totalUTF8)
        await fixture.assertNoInput()
    }

    func testOverviewInterleavesDocumentTextWithControlsHeadingsAndNavigationWithoutAddingAuthority() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let body = "Ordinary document passage with an exact identifier: cafe\u{301}-219."
        let links = (10..<60).map { semanticNode($0, role: "link", name: "Destination \($0)", link: "https://example.com/item/\($0)") }
        let nodes = [semanticNode(0, role: "StaticText", name: body, parent: "n1000")] + links + [
            semanticNode(100, role: "heading", name: "Observed heading"),
            semanticNode(101, role: "heading", name: "Other heading"),
            semanticNode(200, role: "button", name: "Open panel", children: ["n201"]),
            semanticNode(201, role: "StaticText", name: "Inherited control child", parent: "n200"),
            semanticNode(202, role: "searchbox", name: "Find records"),
            semanticNode(203, role: "generic", name: "Custom action", clickable: true),
            semanticNode(1000, role: "main", name: "", children: ["n0"]),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let overview = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview))
        XCTAssertEqual(overview.snapshot.elements.prefix(4).map(\.semanticRole), ["button", "heading", "StaticText", "link"])
        for label in ["Open panel", "Find records", "Custom action", "Observed heading"] {
            XCTAssertTrue(overview.snapshot.elements.contains { $0.label == label })
        }
        XCTAssertTrue(overview.snapshot.formattedText.contains(body))
        XCTAssertFalse(overview.snapshot.formattedText.contains("Inherited control child"))
        XCTAssertTrue(overview.snapshot.formattedText.contains("document_content_exhaustive=false"))
        let receipt = try XCTUnwrap(overview.snapshot.readReceipt)
        XCTAssertEqual(receipt.view, .overview)
        XCTAssertEqual(receipt.selectedElementCount, 56)
        let bodyExposure = try XCTUnwrap(receipt.exposures.first { $0.nodeID == "backend:1" && $0.field == .label })
        XCTAssertEqual(bodyExposure.startUTF8, 0); XCTAssertEqual(bodyExposure.endUTF8, body.utf8.count)
        XCTAssertEqual(bodyExposure.kind, .readable); XCTAssertEqual(bodyExposure.provenance, .main)
        XCTAssertFalse(receipt.exposures.contains { $0.nodeID == "backend:202" })
        let bodyElement = try XCTUnwrap(overview.snapshot.elements.first { $0.backendNodeID == 1 })
        XCTAssertFalse(bodyElement.supportsPress); XCTAssertFalse(bodyElement.supportsSetText)
        await assertBrowserError(.unsupportedAction("AXPress")) {
            try await fixture.broker.perform(taskKey: "task-a", binding: overview.binding,
                snapshot: overview.snapshot, elementIndex: bodyElement.index, action: "AXPress")
        }
        await assertBrowserError(.unsupportedAction("set text")) {
            try await fixture.broker.setText(taskKey: "task-a", binding: overview.binding,
                snapshot: overview.snapshot, elementIndex: bodyElement.index, text: "Not authorized")
        }
        XCTAssertTrue(overview.snapshot.elements.contains { $0.label == "Custom action" && $0.supportsPress })
        let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: overview.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        XCTAssertEqual(all.snapshot.elements.first?.label, body, "Explicit all retains original source order and full internal fields.")
        let controlIndex = try XCTUnwrap(overview.snapshot.elements.first { $0.label == "Open panel" }?.index)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: overview.binding,
                snapshot: overview.snapshot, elementIndex: controlIndex, action: "AXPress")
        }
        let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: all.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(content.snapshot.elements.first?.label, body)
        XCTAssertEqual(content.snapshot.readReceipt?.view, .content)
        XCTAssertNotEqual(content.snapshot.readReceipt?.sourceID, receipt.sourceID)
        await fixture.assertNoInput()
    }

    func testOverviewRanksSemanticControlsBeforeWeakClickableRootsAndLayoutWithoutDroppingEither() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let weak = [semanticNode(0, role: "RootWebArea", name: "Observed document", link: "https://example.com/", clickable: true)]
            + (1..<36).map { semanticNode($0, role: $0 % 3 == 0 ? "separator" : "generic", name: "", clickable: true) }
            + [semanticNode(36, role: "generic", name: "Custom control", focusablePointer: true)]
        let semantic = [
            semanticNode(100, role: "button", name: "Find records"),
            semanticNode(101, role: "textbox", name: "Record query"),
            semanticNode(102, role: "button", name: "", disabled: true),
        ]
        let headings = [semanticNode(200, role: "heading", name: "Record overview")]
        let navigation = [semanticNode(300, role: "link", name: "Archive", link: "https://example.com/archive"),
                          semanticNode(301, role: "navigation", name: "Sections")]
        let nodes = weak + semantic + headings + navigation
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview))
        XCTAssertEqual(page.snapshot.elements.prefix(3).map(\.semanticRole), ["button", "heading", "link"])
        XCTAssertTrue(page.snapshot.elements.contains { $0.label == "Find records" && $0.supportsPress })
        XCTAssertTrue(page.snapshot.elements.contains { $0.label == "Record query" && $0.supportsSetText })
        XCTAssertTrue(page.snapshot.elements.contains { $0.backendNodeID == 103 && !$0.isEnabled },
                      "Semantic priority does not invent enabled state or require a label.")
        let source = try XCTUnwrap(page.snapshot.readReceipt?.sourceID)
        var seen = [Int64]()
        repeat {
            XCTAssertEqual(page.snapshot.readReceipt?.sourceID, source)
            XCTAssertEqual(page.snapshot.readReceipt?.selectedElementCount, nodes.count)
            XCTAssertLessThanOrEqual(page.snapshot.elements.count, 18)
            let rows = page.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }
            XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.utf8.count + 1 }, 6_000)
            seen += page.snapshot.elements.map(\.backendNodeID)
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while true
        let weakIDs = Set(weak.compactMap(\.backendNodeID))
        let semanticIDs = Set(semantic.compactMap(\.backendNodeID))
        XCTAssertEqual(seen.filter { semanticIDs.contains($0) }, semantic.compactMap(\.backendNodeID))
        XCTAssertEqual(seen.filter { weakIDs.contains($0) }, weak.compactMap(\.backendNodeID))
        XCTAssertLessThan(try XCTUnwrap(seen.lastIndex { semanticIDs.contains($0) }),
                          try XCTUnwrap(seen.firstIndex { weakIDs.contains($0) }))
        XCTAssertEqual(Set(seen), Set(nodes.compactMap(\.backendNodeID)))
        XCTAssertEqual(seen.count, nodes.count, "Weak custom candidates remain accessible exactly once.")
        await fixture.assertNoInput()
    }

    func testOverviewContinuationPreservesItsSelectionSourceAndSmallerOutputBounds() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let controls = (0..<41).map { semanticNode($0, role: "button", name: "Control \($0)") }
        let headings = (100..<115).map { semanticNode($0, role: "heading", name: "Heading \($0)") }
        let links = (200..<220).map { semanticNode($0, role: "link", name: "Destination \($0)", link: "https://example.com/\($0)") }
        let body = (300..<310).map { semanticNode($0, role: "StaticText", name: "Captured body \($0)", parent: "n500") }
        let other = [semanticNode(500, role: "article", name: "", children: body.compactMap(\.nodeID)),
                     semanticNode(600, role: "StaticText", name: "Unscoped text remains outside overview")]
        let nodes = controls + headings + links + body + other
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes, sourceTruncated: true)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview))
        let source = try XCTUnwrap(page.snapshot.readReceipt?.sourceID)
        try await fixture.transport.replaceNodes(targetID: page.binding.targetID, nodes: [semanticNode(400, role: "button", name: "Later live control")])
        var seen = [Int64]()
        repeat {
            let rows = page.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }
            XCTAssertLessThanOrEqual(rows.count, 18)
            XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.utf8.count + 1 + SemanticReadPresentation.rowMetadataByteReserve }, 6_000)
            XCTAssertLessThanOrEqual(page.snapshot.formattedText.utf8.count, 16_384)
            XCTAssertEqual(page.snapshot.readReceipt?.view, .overview)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceID, source)
            XCTAssertEqual(page.snapshot.readReceipt?.selectedElementCount, 86)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceTruncated, true)
            XCTAssertFalse(page.snapshot.formattedText.contains("Later live control"))
            XCTAssertFalse(page.snapshot.formattedText.contains("Unscoped text remains outside overview"))
            seen += page.snapshot.elements.map(\.backendNodeID)
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while true
        XCTAssertEqual(seen.count, 86)
        XCTAssertEqual(Set(seen).count, 86)
        XCTAssertEqual(Set(seen), Set((controls + headings + body + links).compactMap(\.backendNodeID)))
        await fixture.assertNoInput()
    }

    func testOverviewLongFieldsContinueExactUTF8BytesWithoutPromotingPartialDestinations() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let label = String(repeating: "Long \"🙂\n", count: 1_200)
        let url = "https://example.com/" + String(repeating: "x", count: 3_500)
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "link", name: label, link: url)])
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview))
        var labelBytes = 0, urlBytes = 0
        var reconstructedLabel = "", reconstructedURL = ""
        repeat {
            let receipt = try XCTUnwrap(page.snapshot.readReceipt)
            let presentation = try XCTUnwrap(page.snapshot.presentation)
            XCTAssertEqual(presentation.snapshotID, page.snapshot.id)
            XCTAssertEqual(presentation.rows.map(\.text),
                page.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init))
            let row = String(try XCTUnwrap(page.snapshot.formattedText.split(separator: "\n").first { $0.hasPrefix("#") }))
            XCTAssertLessThanOrEqual(row.utf8.count + 1, 6_000)
            XCTAssertEqual(page.snapshot.elements.first?.label, label)
            XCTAssertEqual(page.snapshot.elements.first?.linkURL, url)
            for exposure in receipt.exposures {
                if exposure.field == .label {
                    XCTAssertEqual(exposure.startUTF8, labelBytes)
                    labelBytes = exposure.endUTF8
                    reconstructedLabel += try renderedJSONField("label", in: row)
                } else if exposure.field == .linkURL {
                    XCTAssertEqual(exposure.startUTF8, urlBytes)
                    urlBytes = exposure.endUTF8
                    let field = exposure.startUTF8 == 0 && exposure.endUTF8 == exposure.totalUTF8 ? "href" : "href_fragment"
                    reconstructedURL += try renderedJSONField(field, in: row)
                    if field == "href_fragment" { XCTAssertFalse(row.contains(" href=")) }
                }
            }
            guard let cursor = page.snapshot.nextCursor else { break }
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while true
        XCTAssertEqual(reconstructedLabel, label)
        XCTAssertEqual(reconstructedURL, url)
        XCTAssertEqual(labelBytes, label.utf8.count)
        XCTAssertEqual(urlBytes, url.utf8.count)
        await fixture.assertNoInput()
    }

    func testOverviewDocumentTextUsesExactExposuresAndExistingContinuationBudget() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let body = String(repeating: "Observed \"cafe\u{301}\" 🙂\n", count: 900) + "UNPUBLISHED_BODY_TAIL"
        let nodes = [semanticNode(0, role: "main", name: "", children: ["n1", "n2", "n3", "n4"]),
                     semanticNode(1, role: "StaticText", name: body, parent: "n0"),
                     semanticNode(2, role: "button", name: "Available action", parent: "n0"),
                     semanticNode(3, role: "heading", name: "Observed document", parent: "n0"),
                     semanticNode(4, role: "link", name: "Available destination", parent: "n0", link: "https://example.com/next")]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        var page = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview))
        let first = page, source = try XCTUnwrap(page.snapshot.readReceipt?.sourceID)
        XCTAssertTrue(page.snapshot.elements.contains { $0.label == "Available action" && $0.supportsPress })
        XCTAssertFalse(page.snapshot.formattedText.contains("UNPUBLISHED_BODY_TAIL"))
        XCTAssertEqual(page.snapshot.elements.first { $0.backendNodeID == 2 }?.label, body,
                       "Retaining the full field must not publish its unexposed tail")
        var bytes = Data(), offset = 0, pages = 0
        repeat {
            pages += 1
            let receipt = try XCTUnwrap(page.snapshot.readReceipt), presentation = try XCTUnwrap(page.snapshot.presentation)
            let read = try XCTUnwrap(page.snapshot.formattedText.split(separator: "\n").first { $0.hasPrefix("READ ") })
            if let cursor = page.snapshot.nextCursor {
                XCTAssertEqual(read.split(separator: " ").first { $0.hasPrefix("next_cursor=") }.map(String.init), "next_cursor=\(cursor)")
                XCTAssertTrue(receipt.outputTruncated)
            } else {
                XCTAssertFalse(read.contains("next_cursor=")); XCTAssertFalse(receipt.outputTruncated)
            }
            XCTAssertEqual(receipt.sourceID, source); XCTAssertFalse(receipt.sourceTruncated)
            XCTAssertLessThanOrEqual(presentation.rows.count, 18)
            XCTAssertLessThanOrEqual(presentation.rows.reduce(0) { $0 + $1.text.utf8.count + 1 + SemanticReadPresentation.rowMetadataByteReserve }, 6_000)
            XCTAssertLessThanOrEqual(page.snapshot.formattedText.utf8.count, 16_384)
            for exposure in receipt.exposures where exposure.nodeID == "backend:2" && exposure.field == .label {
                let element = try XCTUnwrap(page.snapshot.elements.first { $0.backendNodeID == 2 })
                let row = try XCTUnwrap(presentation.rows.first { $0.index == element.index })
                XCTAssertEqual(exposure.startUTF8, offset); XCTAssertEqual(exposure.totalUTF8, body.utf8.count)
                XCTAssertEqual(exposure.provenance, .main); XCTAssertEqual(exposure.kind, .readable)
                XCTAssertFalse(element.supportsPress); XCTAssertFalse(element.supportsSetText)
                let fragment = try renderedJSONField("label", in: row.text)
                XCTAssertEqual(fragment.utf8.count, exposure.endUTF8 - exposure.startUTF8)
                bytes.append(contentsOf: fragment.utf8); offset = exposure.endUTF8
            }
            guard let cursor = page.snapshot.nextCursor else { break }
            XCTAssertLessThan(pages, 20, "A long body must continue by actual exposed bytes")
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while true
        XCTAssertGreaterThan(pages, 1); XCTAssertEqual(bytes, Data(body.utf8))
        let oldAction = try XCTUnwrap(first.snapshot.elements.first { $0.label == "Available action" })
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding,
                snapshot: first.snapshot, elementIndex: oldAction.index, action: "AXPress")
        }
        await fixture.assertNoInput()
    }

    func testOverviewDoesNotPromoteUnscopedTextOrImplyItsAbsence() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "StaticText", name: "Observed body fact")])
        let overview = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .overview))
        XCTAssertTrue(overview.snapshot.elements.isEmpty)
        XCTAssertEqual(overview.snapshot.readReceipt?.selectedElementCount, 0)
        XCTAssertNil(overview.snapshot.nextCursor)
        XCTAssertTrue(overview.snapshot.formattedText.contains("document_content_exhaustive=false"))
        let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: overview.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(content.snapshot.elements.map(\.label), ["Observed body fact"])
        await fixture.assertNoInput()
    }

    func testDisplayedRowsUseOnlyCurrentElementIndicesWhileRawNodeIdentitiesRemainHostOwned() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = [
            BrowserDocumentNode(backendNodeID: 801, role: "RootWebArea", name: "Fixture", value: nil,
                isDisabled: false, isReadOnly: true, isIgnored: false,
                nodeID: "17", parentNodeID: nil, childNodeIDs: ["18", "19"]),
            BrowserDocumentNode(backendNodeID: 802, role: "button", name: "Open records", value: nil,
                isDisabled: false, isReadOnly: true, isIgnored: false,
                nodeID: "18", parentNodeID: "17", childNodeIDs: []),
            BrowserDocumentNode(backendNodeID: 803, role: "StaticText", name: "Observed context", value: nil,
                isDisabled: false, isReadOnly: true, isIgnored: false,
                nodeID: "19", parentNodeID: "17", childNodeIDs: []),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let rows = observation.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(observation.snapshot.formattedText.contains("scope=document"))
        XCTAssertFalse(observation.snapshot.formattedText.contains("scope_node="))
        XCTAssertTrue(rows[1].hasPrefix("#1 "))
        XCTAssertTrue(rows[1].contains("parent_index=0"))
        XCTAssertTrue(rows[0].contains("child_count=2 expandable=true"))
        XCTAssertTrue(rows.allSatisfy { !$0.contains(" node=") && !$0.contains(" parent_node=") })
        XCTAssertFalse(rows.joined().contains("\"17\""))
        XCTAssertFalse(rows.joined().contains("\"18\""))
        let control = try XCTUnwrap(observation.snapshot.element(at: 1))
        XCTAssertEqual(control.nodeID, "18")
        XCTAssertEqual(control.parentNodeID, "17")
        XCTAssertEqual(control.backendNodeID, 802)
        XCTAssertEqual(observation.snapshot.element(at: 0)?.childNodeIDs, ["18", "19"])
        XCTAssertTrue(observation.snapshot.readReceipt?.exposures.contains { $0.nodeID == "backend:802" } == true)
        await assertBrowserError(.elementNotFound) {
            try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 18, action: "AXPress")
        }
        await fixture.assertNoInput()
        try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
            snapshot: observation.snapshot, elementIndex: 1, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
        XCTAssertEqual(pressed, [802], "Only the current displayed index resolves the unchanged native action target.")
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 1, action: "AXPress")
        }
    }

    func testResultContainerAffordanceUsesExactSemanticRoleAndVisibleParent() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        // The child deliberately precedes its parent in source order.
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "RootWebArea", name: "Fixture", children: ["n2", "n3"]),
            semanticNode(1, role: "StaticText", name: "Showing the first records", parent: "n2"),
            semanticNode(2, role: "status", name: "", parent: "n0", children: ["n1"]),
            semanticNode(3, role: "button", name: "Next records", parent: "n0"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let rows = observation.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }
        XCTAssertTrue(rows[1].contains("semantic_role=\"StaticText\""))
        XCTAssertTrue(rows[1].contains("parent_index=2"))
        XCTAssertFalse(rows[1].contains("region_changed_candidate"))
        XCTAssertTrue(rows[2].contains("role=\"AXGroup\" semantic_role=\"status\" region_changed_candidate=true"))
        XCTAssertFalse(rows[3].contains("region_changed_candidate"))
        let presentation = try XCTUnwrap(observation.snapshot.presentation)
        XCTAssertTrue(presentation.rows.allSatisfy(\.region))
        XCTAssertTrue(presentation.rows[2].regionChanged)
        XCTAssertEqual(presentation.rows[1].parentIndex, 2)
        XCTAssertFalse(presentation.rows[1].regionChanged)
        XCTAssertFalse(presentation.rows[3].regionChanged)
        XCTAssertTrue(observation.snapshot.formattedText.contains("not authorization or success"))
        let plan = try XCTUnwrap(BrowserActionVerification.compile(
            request: .init(kind: .regionChanged, elementIndex: 2, expected: "changed"), action: .press,
            elementIndex: 3, snapshot: observation.snapshot, binding: observation.binding))
        XCTAssertEqual(plan.anchor?.backendNodeID, 3)
        await assertBrowserError(.unsupportedAction("AXPress")) {
            try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 2, action: "AXPress")
        }
        // The display marker cannot make this snapshot usable after a fresh read.
        _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 3, action: "AXPress", verificationPlan: plan)
        }
        await fixture.assertNoInput()
    }

    func testResultContainerAffordanceRejectsControlsEditabilityAndIncompleteSource() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        for variant in ["control", "editable", "clipped", "overlong", "missingParent"] {
            let childRole = variant == "control" ? "textbox" : "StaticText"
            let text = variant == "overlong" ? String(repeating: "x", count: 8_193) : "Observed result"
            let parentID = variant == "missingParent" ? nil : "n0"
            let nodes = [
                semanticNode(0, role: "RootWebArea", name: "Fixture", children: variant == "missingParent" ? [] : ["n1"]),
                semanticNode(1, role: "status", name: "", parent: parentID, children: ["n2"], editable: variant == "editable"),
                semanticNode(2, role: childRole, name: text, parent: "n1"),
            ]
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: nodes, sourceTruncated: variant == "clipped")
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
            XCTAssertFalse(observation.snapshot.formattedText.contains("region_changed_candidate=true"), variant)
        }
        await fixture.assertNoInput()
    }

    func testRegionAffordancesDoNotJoinParentsAcrossPagesOrAuthorizeRetainedReads() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        var nodes = [semanticNode(0, role: "RootWebArea", name: "Fixture", children: ["n1"]),
                     semanticNode(1, role: "status", name: "", parent: "n0", children: (2...92).map { "n\($0)" })]
        nodes += (2...92).map { semanticNode($0, role: "StaticText", name: "Row \($0)", parent: "n1") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        var observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        XCTAssertTrue(observation.snapshot.formattedText.contains("region_changed_candidate=true"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("parent_index=1"))
        var count = 0
        repeat {
            let rows = observation.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }
            XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.utf8.count + 1 }, 10_000)
            XCTAssertLessThanOrEqual(rows.count, 60)
            XCTAssertLessThanOrEqual(observation.snapshot.formattedText.utf8.count, 16_384)
            count += rows.count
            if !observation.snapshot.isLiveObservation {
                XCTAssertFalse(observation.snapshot.formattedText.contains("parent_index="))
                XCTAssertFalse(observation.snapshot.formattedText.contains(" parent_node="))
                XCTAssertTrue(observation.snapshot.elements.allSatisfy { $0.parentNodeID == "n1" })
                XCTAssertFalse(observation.snapshot.formattedText.contains("region_changed_candidate=true"))
            }
            guard let cursor = observation.snapshot.nextCursor else { break }
            observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while true
        XCTAssertEqual(count, nodes.count)
        await fixture.assertNoInput()
    }

    func testSemanticRoleEscapingIsBoundedWithoutLosingFieldContinuation() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let role = String(repeating: "unusual\"\n", count: 100)
        let label = String(repeating: "A🙂", count: 3_000)
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: role, name: label)])
        var observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        var reconstructed = ""
        repeat {
            let rows = observation.snapshot.formattedText.split(separator: "\n").filter { $0.hasPrefix("#") }
            XCTAssertEqual(rows.count, 1)
            let row = String(try XCTUnwrap(rows.first))
            XCTAssertTrue(row.contains("semantic_role_truncated=1"))
            let emittedRole = try renderedJSONField("semantic_role", in: row)
            let escapedRole = try JSONEncoder().encode(emittedRole)
            XCTAssertLessThanOrEqual(escapedRole.count - 2, 256)
            XCTAssertTrue(role.hasPrefix(emittedRole))
            XCTAssertEqual(observation.snapshot.elements.first?.semanticRole, role)
            XCTAssertLessThanOrEqual(row.utf8.count + 1, 10_000)
            XCTAssertLessThanOrEqual(observation.snapshot.formattedText.utf8.count, 16_384)
            reconstructed += try renderedJSONField("label", in: row)
            guard let cursor = observation.snapshot.nextCursor else { break }
            observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while true
        XCTAssertEqual(reconstructed, label)
    }

    func testResultRegionChangedDuringApprovalRejectsBeforeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        func nodes(text: String) -> [BrowserDocumentNode] {
            [semanticNode(0, role: "RootWebArea", name: "Fixture", children: ["n1", "n2"]),
             semanticNode(1, role: "button", name: "Increment", parent: "n0"),
             semanticNode(2, role: "status", name: "Result", parent: "n0", children: ["n3"]),
             semanticNode(3, role: "StaticText", name: text, parent: "n2")]
        }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes(text: "Count: 0"))
        let before = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        let button = try XCTUnwrap(before.snapshot.elements.first { $0.label == "Increment" })
        let region = try XCTUnwrap(before.snapshot.elements.first { $0.semanticRole == "status" })
        let plan = try XCTUnwrap(BrowserActionVerification.compile(
            request: .init(kind: .regionText, elementIndex: region.index, expected: "Count: 1"),
            action: .press, elementIndex: button.index, snapshot: before.snapshot, binding: before.binding))
        // Simulates a page/human change while approval was pending, without
        // changing the clicked control. The old target-only check missed it.
        try await fixture.transport.replaceNodes(targetID: before.binding.targetID, nodes: nodes(text: "Count: 1"))
        do {
            try await fixture.broker.perform(taskKey: "task-a", binding: before.binding,
                snapshot: before.snapshot, elementIndex: button.index, action: "AXPress", verificationPlan: plan)
            XCTFail("Changed precondition must stop before dispatch")
        } catch let failure as BrowserActionVerification.Failure {
            XCTAssertEqual(failure, .baselineChanged)
        }
        await fixture.assertNoInput()
    }

    func testBrowserReportedExactClickableRowsAndCardsSupportPressWithoutSemanticRoleGuessing() async throws {
        for role in ["row", "generic", "article"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: role, name: "Observed clickable item", clickable: true),
                semanticNode(1, role: role, name: "Passive item"),
            ])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
            let clickable = try XCTUnwrap(observation.snapshot.element(at: 0))
            let passive = try XCTUnwrap(observation.snapshot.element(at: 1))
            XCTAssertTrue(clickable.isDOMClickable)
            XCTAssertTrue(clickable.supportsPress)
            XCTAssertFalse(passive.isDOMClickable)
            XCTAssertFalse(passive.supportsPress)
            let rows = observation.snapshot.formattedText.split(separator: "\n")
            XCTAssertTrue(try XCTUnwrap(rows.first { $0.hasPrefix("#0 ") }).contains("press_source=browser_clickability"))
            XCTAssertFalse(try XCTUnwrap(rows.first { $0.hasPrefix("#1 ") }).contains("press_source="))
            await assertBrowserError(.unsupportedAction("AXPress")) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 1, action: "AXPress")
            }
            try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
            XCTAssertEqual(pressed, [clickable.backendNodeID])
        }
    }

    func testClickabilityIsNotInheritedFromParentOrChildAndDoesNotOverrideDisabledState() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "row", name: "Clickable parent", children: ["n1"], clickable: true),
            semanticNode(1, role: "generic", name: "Passive child", parent: "n0"),
            semanticNode(2, role: "row", name: "Passive parent", children: ["n3"]),
            semanticNode(3, role: "generic", name: "Clickable child", parent: "n2", clickable: true),
            semanticNode(4, role: "row", name: "Disabled clickable row", clickable: true, disabled: true),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        XCTAssertEqual(observation.snapshot.elements.map(\.supportsPress), [true, false, false, true, true])
        XCTAssertEqual(observation.snapshot.elements.map(\.isDOMClickable), [true, false, false, true, true])
        XCTAssertFalse(try XCTUnwrap(observation.snapshot.element(at: 4)).isEnabled)
        for index in [1, 2, 4] {
            await assertBrowserError(.unsupportedAction("AXPress")) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: index, action: "AXPress")
            }
        }
        await fixture.assertNoInput()
        try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
            snapshot: observation.snapshot, elementIndex: 3, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
        XCTAssertEqual(pressed, [4], "Only the exact observed clickable child is dispatched; never an ancestor.")
    }

    func testRemovedExactClickabilityInvalidatesApprovalBeforeDispatch() async throws {
        // The button remains semantically pressable after its DOM flag changes;
        // revalidation must preserve the exact observed capability source too.
        for role in ["row", "button"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: [semanticNode(0, role: role, name: "Stable label", clickable: true)])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
            try await fixture.transport.replaceNodes(targetID: observation.binding.targetID,
                nodes: [semanticNode(0, role: role, name: "Stable label", clickable: false)])
            await assertBrowserError(.elementChanged) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
            await fixture.assertNoInput()
            await assertBrowserError(.staleSnapshot) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
        }
    }

    func testTransportQualifiedFocusablePointerCandidateIsDistinctFromBrowserClickability() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "row", name: "Qualified exact candidate", children: ["n1"], focusablePointer: true),
            semanticNode(1, role: "generic", name: "Passive child", parent: "n0"),
            semanticNode(2, role: "row", name: "focusable=true cursor=pointer in untrusted label"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        let candidate = try XCTUnwrap(observation.snapshot.element(at: 0))
        XCTAssertTrue(candidate.supportsPress)
        XCTAssertFalse(candidate.isDOMClickable)
        XCTAssertTrue(candidate.isFocusablePointer)
        XCTAssertEqual(observation.snapshot.elements.map(\.supportsPress), [true, false, false])
        XCTAssertTrue(observation.snapshot.formattedText.contains("press_source=focusable_pointer"))
        XCTAssertFalse(observation.snapshot.formattedText.contains("press_source=browser_clickability"))
        try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
            snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
        XCTAssertEqual(pressed, [candidate.backendNodeID])
    }

    func testRemovedFocusablePointerCapabilityRejectsInputEvenWhenOtherPressSourceRemains() async throws {
        for domClickable in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: [semanticNode(0, role: "row", name: "Stable label", clickable: domClickable, focusablePointer: true)])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
            try await fixture.transport.replaceNodes(targetID: observation.binding.targetID,
                nodes: [semanticNode(0, role: "row", name: "Stable label", clickable: domClickable, focusablePointer: false)])
            await assertBrowserError(.elementChanged) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
            await fixture.assertNoInput()
        }
    }

    func testBrowserClickabilitySurvivesRetainedPaginationAndExactIndexCopies() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 70).map { semanticNode($0, role: "row", name: "Item \($0)", clickable: true, focusablePointer: true) })
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        let second = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: try XCTUnwrap(first.snapshot.nextCursor)))
        XCTAssertFalse(second.snapshot.isLiveObservation)
        XCTAssertTrue(second.snapshot.elements.allSatisfy { $0.isDOMClickable && $0.isFocusablePointer && $0.supportsPress })
        let target = try XCTUnwrap(second.snapshot.element(at: 0))
        XCTAssertEqual(target.backendNodeID, Int64(first.snapshot.elements.count + 1))
        XCTAssertTrue(second.snapshot.formattedText.contains("press_source=browser_clickability"))
        try await fixture.broker.perform(taskKey: "task-a", binding: second.binding,
            snapshot: second.snapshot, elementIndex: 0, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: second.binding.targetID)
        XCTAssertEqual(pressed, [target.backendNodeID])
    }

    func testUnsupportedAndMissingElementPreflightPreservesSnapshotForSupportedMutation() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: "generic", name: "Passive"),
                semanticNode(1, role: "textbox", name: "Read only", readOnly: true),
                semanticNode(2, role: "textbox", name: "Editable"),
                semanticNode(3, role: "row", name: "Clickable", clickable: true),
            ])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
            await assertBrowserError(.elementNotFound) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 99, action: "AXPress")
            }
            await assertBrowserError(.unsupportedAction("AXPress")) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
            await assertBrowserError(.elementNotFound) {
                try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 99, text: "not sent")
            }
            for index in [0, 1] {
                await assertBrowserError(.unsupportedAction("set text")) {
                    try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                        snapshot: observation.snapshot, elementIndex: index, text: "not sent")
                }
            }
            await fixture.assertNoInput()
            if setText {
                try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 2, text: "supported once")
                let values = await fixture.transport.textValues(targetID: observation.binding.targetID)
                XCTAssertEqual(values, ["supported once"])
            } else {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 3, action: "AXPress")
                let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
                XCTAssertEqual(pressed, [4])
            }
            await assertBrowserError(.staleSnapshot) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 3, action: "AXPress")
            }
        }
    }

    func testSnapshotRetainsOriginalSemanticRolesAlongsideAXDisplayRoles() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "searchbox", name: "Text"),
            semanticNode(1, role: "region", name: "Search results", children: ["n2"]),
            semanticNode(2, role: "status", name: "No results found", parent: "n1"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        XCTAssertEqual(observation.snapshot.elements.map(\.role), ["AXTextField", "AXGroup", "AXGroup"])
        XCTAssertEqual(observation.snapshot.elements.map(\.semanticRole), ["searchbox", "region", "status"])
        let input = try XCTUnwrap(observation.snapshot.elements.first)
        XCTAssertTrue(ComputerSearchEvidence.isSearchInput(role: input.semanticRole ?? input.role, label: input.label))
        XCTAssertFalse(ComputerSearchEvidence.isSearchInput(role: input.role, label: input.label),
            "The generic AX role and generic Text label are not evidence of a search input.")
    }

    func testSemanticRoleChangeInvalidatesApprovalEvenWhenDisplayRoleIsUnchanged() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "textbox", name: "Text")])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "searchbox", name: "Text")])
        await assertBrowserError(.elementChanged) {
            try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 0, text: "must not dispatch")
        }
        await fixture.assertNoInput()
    }

    func testOversizedURLsUseExplicitFragmentsWhileExactMutationIdentityIsRetained() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let longURL = "https://example.test/unique-destination/" + String(repeating: "a", count: 2400) + "/actual-target"
        let destination = try XCTUnwrap(URL(string: longURL))
        try await fixture.transport.navigate(
            targetID: fixture.observation.binding.targetID, url: destination, loaderID: "long-url-loader"
        )
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "link", name: "Read exact destination", link: longURL)]
        )
        let result = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil
        )
        XCTAssertTrue(result.snapshot.formattedText.contains("url_omitted=1"))
        XCTAssertTrue(result.snapshot.formattedText.contains("href_omitted=1"))
        XCTAssertTrue(result.snapshot.formattedText.contains("href_fragment="))
        XCTAssertFalse(result.snapshot.formattedText.contains(" href="))
        XCTAssertNotNil(result.snapshot.nextCursor)
        XCTAssertTrue(try XCTUnwrap(result.snapshot.readReceipt).fieldTruncated)
        XCTAssertEqual(result.snapshot.documentURL, destination)
        XCTAssertEqual(result.snapshot.elements.first?.linkURL, longURL)
        try await fixture.broker.perform(
            taskKey: "task-a", binding: result.binding, snapshot: result.snapshot, elementIndex: 0, action: "AXPress"
        )
        let pressed = await fixture.transport.pressedNodeIDs(targetID: result.binding.targetID)
        XCTAssertEqual(pressed, [1])
    }

    func testProgressiveHeadingReadFindsUnknownTitlesAfterWideDeepWrappers() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let wrappers = (0 ..< 350).map { index in
            semanticNode(index, role: "generic", name: "", parent: index == 0 ? nil : "n\(index - 1)", children: ["n\(index + 1)"])
        }
        let headings = (350 ..< 487).map { index in
            semanticNode(index, role: "heading", name: "Previously unknown title \(index)", parent: "n349")
        }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: wrappers + headings)
        var observation = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: SemanticReadRequest(view: .headings)
        )
        var labels = observation.snapshot.elements.map(\.label)
        XCTAssertEqual(observation.snapshot.totalMatches, 137)
        XCTAssertFalse(observation.snapshot.formattedText.contains(" parent_node="))
        XCTAssertTrue(observation.snapshot.elements.allSatisfy { $0.parentNodeID == "n349" })
        XCTAssertNotNil(observation.snapshot.nextCursor)
        XCTAssertLessThanOrEqual(observation.snapshot.formattedText.utf8.count, 16_384)
        while let cursor = observation.snapshot.nextCursor {
            observation = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                read: SemanticReadRequest(cursor: cursor)
            )
            labels.append(contentsOf: observation.snapshot.elements.map(\.label))
            XCTAssertLessThanOrEqual(observation.snapshot.formattedText.utf8.count, 16_384)
        }
        XCTAssertEqual(labels, headings.map(\.name))
        XCTAssertTrue(observation.snapshot.formattedText.contains("output_truncated=0"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("visibility=unknown"))
    }

    func testContentScopeDistinguishesIdenticalLabelsByObservedAncestry() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let label = "The same observed phrase"
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "RootWebArea", name: "", children: ["n1", "n3", "n8"]),
            semanticNode(1, role: "navigation", name: "", parent: "n0", children: ["n2"]),
            semanticNode(2, role: "link", name: label, parent: "n1"),
            semanticNode(3, role: "main", name: "", parent: "n0", children: ["n4", "n5", "n6"]),
            semanticNode(4, role: "StaticText", name: label, parent: "n3"),
            semanticNode(5, role: "article", name: label, parent: "n3"),
            semanticNode(6, role: "navigation", name: "", parent: "n3", children: ["n7"]),
            semanticNode(7, role: "link", name: label, parent: "n6"),
            semanticNode(8, role: "complementary", name: "", parent: "n0", children: ["n9"]),
            semanticNode(9, role: "article", name: label, parent: "n8"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: SemanticReadRequest(query: label, view: .all))
        XCTAssertEqual(observation.snapshot.elements.map(\.label), Array(repeating: label, count: 5))
        XCTAssertEqual(observation.snapshot.elements.map(\.contentScope), [.navigation, .main, .article, .navigation, .complementary])
        XCTAssertEqual(observation.snapshot.elements.map(\.supportsPress), [true, false, false, true, false],
                       "Provenance must not add or remove action authority.")
        for scope in ["navigation", "main", "article", "complementary"] {
            XCTAssertTrue(observation.snapshot.formattedText.contains("content_scope=\(scope)"))
        }
        XCTAssertTrue(observation.snapshot.formattedText.contains("document_content_shown=1 navigation_shown=2 complementary_shown=1"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("subject_relevance=not_verified"))
        await fixture.assertNoInput()
    }

    func testMissingAmbiguousOrCyclicContentAncestryRemainsUnknown() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "StaticText", name: "No parent"),
            semanticNode(1, role: "StaticText", name: "Missing parent", parent: "missing"),
            semanticNode(2, role: "main", name: "Main with incomplete ancestry", parent: "missing"),
            semanticNode(3, role: "StaticText", name: "Cyclic parent", parent: "n4"),
            semanticNode(4, role: "generic", name: "", parent: "n3"),
            semanticNode(5, role: "main", name: ""),
            semanticNode(5, role: "navigation", name: ""),
            semanticNode(6, role: "StaticText", name: "Ambiguous parent", parent: "n5"),
        ], sourceTruncated: true)
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: SemanticReadRequest(view: .content))
        XCTAssertEqual(observation.snapshot.elements.count, 4)
        XCTAssertTrue(observation.snapshot.elements.allSatisfy { $0.contentScope == .unknown && $0.contentKind == .readable })
        XCTAssertTrue(observation.snapshot.formattedText.contains("document_content_shown=0"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("unknown_shown=4"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("source_truncated=1"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("Unknown scope is not proof that content is absent."))
        await fixture.assertNoInput()
    }

    func testContentProvenanceCountsOnlyTheExposedPageOfTruncatedObservations() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        var nodes = [
            semanticNode(0, role: "RootWebArea", name: ""),
            semanticNode(1, role: "navigation", name: "", parent: "n0"),
            semanticNode(2, role: "main", name: "", parent: "n0"),
        ]
        nodes += (3..<73).map { semanticNode($0, role: "StaticText", name: "Navigation label \($0)", parent: "n1") }
        nodes += (73..<143).map { semanticNode($0, role: "StaticText", name: "Document text \($0)", parent: "n2") }
        nodes += (143..<146).map { semanticNode($0, role: "StaticText", name: "Unknown text \($0)", parent: "missing") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                                                 nodes: nodes, sourceTruncated: true)
        var observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: SemanticReadRequest(view: .content))
        var allElements = [BrowserTabElement]()
        var pages = 0
        while true {
            let elements = observation.snapshot.elements
            let content = elements.filter { $0.contentScope.isDocumentContent }.count
            let navigation = elements.filter { $0.contentScope == .navigation }.count
            let unknown = elements.filter { $0.contentScope == .unknown }.count
            let header = try XCTUnwrap(observation.snapshot.formattedText.split(separator: "\n")
                .first { $0.hasPrefix("CONTENT_EVIDENCE ") })
            XCTAssertTrue(header.contains("document_content_shown=\(content) "))
            XCTAssertTrue(header.contains("navigation_shown=\(navigation) "))
            XCTAssertTrue(header.contains("unknown_shown=\(unknown) "))
            XCTAssertEqual(content + navigation + unknown, elements.count)
            XCTAssertTrue(observation.snapshot.sourceTruncated)
            XCTAssertTrue(header.contains("subject_relevance=not_verified"))
            allElements += elements
            pages += 1
            guard let cursor = observation.snapshot.nextCursor else { break }
            observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: SemanticReadRequest(cursor: cursor))
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(allElements.count, 73)
        XCTAssertEqual(allElements.filter { $0.contentScope == .main }.count, 70)
        XCTAssertEqual(allElements.filter { $0.contentScope == .navigation }.count, 0)
        XCTAssertEqual(allElements.filter { $0.contentScope == .unknown }.count, 3)
        await fixture.assertNoInput()
    }

    func testLocalFilterEchoInSearchFieldIsNotPresentedAsWebsiteSearchResults() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "RootWebArea", name: "Mailbox", children: ["n1", "n2"]),
            semanticNode(1, role: "searchbox", name: "Search", parent: "n0", value: "ODE"),
            semanticNode(2, role: "StaticText", name: "Unrelated message", parent: "n0"),
        ], sourceTruncated: true)
        let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "ODE", view: .all))
        let evidence = try selectionEvidence(read.snapshot)
        XCTAssertEqual(evidence["operation"] as? String, "local_capture_filter")
        XCTAssertEqual(evidence["counts_scope"] as? String, "captured_elements_only")
        XCTAssertEqual(evidence["query_applied"] as? Bool, true)
        XCTAssertEqual(read.snapshot.totalMatches, 1)
        XCTAssertTrue(read.snapshot.sourceTruncated)
        XCTAssertEqual(evidence["site_search_evaluated"] as? Bool, false)
        XCTAssertEqual(evidence["site_result_count"] as? String, "not_measured")
        let hits = try XCTUnwrap(evidence["emitted_query_matches"] as? [String: Any])
        XCTAssertEqual(hits["basis"] as? String, "emitted_field_fragments")
        XCTAssertEqual(hits["input_value_elements"] as? Int, 1)
        XCTAssertEqual(hits["readable_text_elements"] as? Int, 0)
        XCTAssertEqual(hits["other_field_elements"] as? Int, 0)
        XCTAssertEqual(hits["only_input_values"] as? Bool, true)
        let encoded = try JSONSerialization.data(withJSONObject: evidence)
        XCTAssertLessThan(encoded.count, 420, "Selection provenance stays compact and does not repeat header counts")
        XCTAssertTrue(try XCTUnwrap(read.snapshot.elements.first).supportsSetText,
                      "Evidence classification does not change the observed input capability")
        await fixture.assertNoInput()
    }

    func testEmptyLocalSelectionIsNotSiteAbsenceEvenWhenCaptureIsNotTruncated() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        for truncated in [false, true] {
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: "StaticText", name: "Other captured content"),
            ], sourceTruncated: truncated)
            let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "ODE", view: .content))
            let evidence = try selectionEvidence(read.snapshot)
            XCTAssertEqual(read.snapshot.totalMatches, 0)
            XCTAssertTrue(read.snapshot.elements.isEmpty)
            XCTAssertEqual(read.snapshot.sourceTruncated, truncated)
            XCTAssertNil(read.snapshot.nextCursor)
            XCTAssertEqual(evidence["site_search_evaluated"] as? Bool, false)
            XCTAssertEqual(evidence["site_result_count"] as? String, "not_measured")
            XCTAssertTrue(read.snapshot.elements.isEmpty)
            XCTAssertTrue(read.snapshot.formattedText.contains("This is not a website search result or proof of absent content"))
        }
        await fixture.assertNoInput()
    }

    func testSelectionEvidencePreservesReadablePositiveAndExplicitEmptyResultText() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        for text in ["ODE exam announcement: the time changed.", "No results found for ODE in this folder."] {
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: "main", name: "", children: ["n1"]),
                semanticNode(1, role: "StaticText", name: text, parent: "n0"),
            ], sourceTruncated: true)
            let read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "ODE", view: .content))
            let evidence = try selectionEvidence(read.snapshot)
            let hits = try XCTUnwrap(evidence["emitted_query_matches"] as? [String: Any])
            XCTAssertEqual(hits["readable_text_elements"] as? Int, 1)
            XCTAssertEqual(hits["input_value_elements"] as? Int, 0)
            XCTAssertEqual(hits["only_input_values"] as? Bool, false)
            XCTAssertTrue(read.snapshot.formattedText.contains(text),
                          "Truthful positive or scoped empty-state reports must remain available from literal page evidence")
            XCTAssertEqual(evidence["site_search_evaluated"] as? Bool, false,
                           "The host does not classify site-specific result semantics from generic text")
        }
        await fixture.assertNoInput()
    }

    func testQueryMatchProvenanceCountsOnlyEmittedFragmentsAndFollowsCursorPages() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let tail = "TAIL_QUERY_MATCH"
        let text = String(repeating: "unrelated prefix ", count: 700) + tail
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "StaticText", name: text)])
        var read = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: tail, view: .content))
        var pages = 0, matchedPages = 0
        while true {
            let evidence = try selectionEvidence(read.snapshot)
            let hits = try XCTUnwrap(evidence["emitted_query_matches"] as? [String: Any])
            XCTAssertEqual(read.snapshot.totalMatches, 1)
            XCTAssertEqual(evidence["query_applied"] as? Bool, true)
            XCTAssertEqual(read.snapshot.readReceipt?.outputTruncated, read.snapshot.nextCursor != nil)
            XCTAssertLessThanOrEqual(read.snapshot.formattedText.utf8.count, 16_384)
            let exposed = read.snapshot.formattedText.split(separator: "\n")
                .filter { $0.hasPrefix("#") }.contains { $0.contains(tail) }
            XCTAssertEqual(hits["readable_text_elements"] as? Int, exposed ? 1 : 0,
                           "Retained field tails are not emitted query evidence")
            if exposed { matchedPages += 1 }
            pages += 1
            guard let cursor = read.snapshot.nextCursor else { break }
            read = try await fixture.broker.snapshot(taskKey: "task-a", binding: read.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(matchedPages, 1)
        let unfiltered = try await fixture.broker.snapshot(taskKey: "task-a", binding: read.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        let evidence = try selectionEvidence(unfiltered.snapshot)
        XCTAssertEqual(evidence["operation"] as? String, "capture_view_selection")
        XCTAssertEqual(evidence["query_applied"] as? Bool, false)
        XCTAssertNil(evidence["emitted_query_matches"])
        await fixture.assertNoInput()
    }

    private func selectionEvidence(_ snapshot: BrowserTabSnapshot) throws -> [String: Any] {
        let prefix = "READ_SELECTION_EVIDENCE "
        let line = try XCTUnwrap(snapshot.formattedText.split(separator: "\n").first { $0.hasPrefix(prefix) })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any])
    }

    func testNoMatchReturnsNoUnrelatedFallbackAndReportsIncompleteSource() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "heading", name: "A real title")], sourceTruncated: true
        )
        let result = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: SemanticReadRequest(query: "video title")
        )
        XCTAssertTrue(result.snapshot.elements.isEmpty)
        XCTAssertEqual(result.snapshot.totalMatches, 0)
        XCTAssertTrue(result.snapshot.formattedText.contains("no_matches=1"))
        XCTAssertTrue(result.snapshot.formattedText.contains("source_truncated=1"))
        XCTAssertFalse(result.snapshot.formattedText.contains("A real title"))
        XCTAssertNil(result.snapshot.nextCursor)
    }

    func testSubtreeExpansionRetainsAttributionAndLinkDestination() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = [
            semanticNode(0, role: "generic", name: "First card", children: ["n1", "n2"]),
            semanticNode(1, role: "heading", name: "Exact title", parent: "n0"),
            semanticNode(2, role: "link", name: "Publisher", parent: "n0", link: "https://example.test/publisher"),
            semanticNode(3, role: "generic", name: "Other card", children: ["n4"]),
            semanticNode(4, role: "heading", name: "Unrelated title", parent: "n3"),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let first = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil
        )
        let expanded = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: SemanticReadRequest(snapshotID: first.snapshot.id, elementIndex: 0)
        )
        XCTAssertEqual(expanded.snapshot.elements.map(\.label), ["First card", "Exact title", "Publisher"])
        XCTAssertTrue(expanded.snapshot.formattedText.contains("href=\"https://example.test/publisher\""))
        XCTAssertTrue(expanded.snapshot.formattedText.contains("scope=subtree"))
        XCTAssertFalse(expanded.snapshot.formattedText.contains("scope_node="))
        XCTAssertEqual(expanded.snapshot.readReceipt?.subtreeNodeID, "n0")
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                read: SemanticReadRequest(snapshotID: first.snapshot.id, elementIndex: 0)
            )
        }
    }

    func testCursorIsSingleUseAndInvalidatedByChangedDocumentOrNewRead() async throws {
        for cause in ["reuse", "new_read", "navigation"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            let first = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                read: SemanticReadRequest(view: .links)
            )
            let cursor = try XCTUnwrap(first.snapshot.nextCursor)
            switch cause {
            case "reuse":
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                    read: SemanticReadRequest(cursor: cursor)
                )
            case "new_read":
                _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
            default:
                try await fixture.transport.navigate(targetID: first.binding.targetID, url: URL(string: "https://example.test/new")!, loaderID: "new-loader")
            }
            await assertBrowserError(.staleSnapshot) {
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                    read: SemanticReadRequest(cursor: cursor)
                )
            }
        }
    }

    func testCursorAcceptsRepeatedMatchingFiltersAndRetainsSingleUse() async throws {
        for options in ["none", "view", "query", "both"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Item", view: .links))
            let cursor = try XCTUnwrap(first.snapshot.nextCursor)
            let second = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(
                    query: options == "query" || options == "both" ? " Item\n" : nil,
                    view: options == "view" || options == "both" ? .links : nil, cursor: cursor))
            XCTAssertEqual(second.snapshot.totalMatches, 140)
            XCTAssertTrue(second.snapshot.formattedText.contains("observation=retained"))
            let firstLabels = Set(first.snapshot.elements.map(\.label))
            let secondLabels = Set(second.snapshot.elements.map(\.label))
            XCTAssertFalse(secondLabels.isEmpty)
            XCTAssertTrue(firstLabels.isDisjoint(with: secondLabels))
            await assertBrowserError(.staleSnapshot) {
                _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: second.binding,
                    bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Item", view: .links, cursor: cursor))
            }
            await fixture.assertNoInput()
        }
    }

    func testCursorRejectsChangedFiltersAndSubtreeEvenWhenCursorIsCurrent() async throws {
        for change in ["view", "query", "snapshot", "index", "subtree"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") })
            let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Item", view: .links))
            let cursor = try XCTUnwrap(first.snapshot.nextCursor)
            let request = SemanticReadRequest(query: change == "query" ? "Different" : "Item",
                view: change == "view" ? .content : .links, cursor: cursor,
                snapshotID: change == "snapshot" || change == "subtree" ? first.snapshot.id : nil,
                elementIndex: change == "index" || change == "subtree" ? 0 : nil)
            do {
                _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
                    bundleIdentifier: "com.ahmedelamin.LocalCodex", read: request)
                XCTFail("Conflicting continuation must fail: \(change)")
            } catch let error as BrowserTabBrokerError {
                guard case .invalidRead = error else { return XCTFail("Expected invalidRead, got \(error)") }
            }
            await fixture.assertNoInput()
        }
    }

    func testRepeatedMatchingFiltersCannotReviveAStaleCursorAfterNavigation() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") })
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Item", view: .links))
        let cursor = try XCTUnwrap(first.snapshot.nextCursor)
        try await fixture.transport.navigate(targetID: first.binding.targetID,
            url: URL(string: "https://example.test/replaced")!, loaderID: "replaced-loader")
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Item", view: .links, cursor: cursor))
        }
        await fixture.assertNoInput()
    }

    func testRetainedPagesSurviveUnrelatedLiveChangesAndIndicesDispatchExactLateTarget() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        try await fixture.transport.replaceNodes(
            targetID: first.binding.targetID, nodes: nodes + [semanticNode(999, role: "heading", name: "Clock changed")]
        )
        let second = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: SemanticReadRequest(cursor: try XCTUnwrap(first.snapshot.nextCursor))
        )
        XCTAssertEqual(second.snapshot.totalMatches, 140, "One observation must not splice in the new clock.")
        XCTAssertTrue(second.snapshot.formattedText.contains("observation=retained"))
        let lateTarget = try XCTUnwrap(second.snapshot.element(at: 0))
        XCTAssertEqual(lateTarget.backendNodeID, Int64(first.snapshot.elements.count + 1))
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot, elementIndex: 0, action: "AXPress")
        }
        try await fixture.broker.perform(taskKey: "task-a", binding: second.binding, snapshot: second.snapshot, elementIndex: 0, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: first.binding.targetID)
        XCTAssertEqual(pressed, [lateTarget.backendNodeID])
    }

    func testRetainedPageActionRejectsChangedTargetAndFreshReadSeesNewContent() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        let changedIndex = first.snapshot.elements.count
        var changedNodes = nodes
        changedNodes[changedIndex] = semanticNode(changedIndex, role: "link", name: "Replacement destination")
        try await fixture.transport.replaceNodes(targetID: first.binding.targetID, nodes: changedNodes)
        let second = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: SemanticReadRequest(cursor: try XCTUnwrap(first.snapshot.nextCursor))
        )
        await assertBrowserError(.elementChanged) {
            try await fixture.broker.perform(taskKey: "task-a", binding: second.binding, snapshot: second.snapshot, elementIndex: 0, action: "AXPress")
        }
        let fresh = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: second.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: "Replacement destination"
        )
        XCTAssertEqual(fresh.snapshot.elements.map(\.label), ["Replacement destination"])
        XCTAssertTrue(fresh.snapshot.formattedText.contains("observation=live"))
        await fixture.assertNoInput()
    }

    func testExpiredReadCursorRejectsButNewLiveReadWorks() async throws {
        let fixture = try await BrowserBrokerTestFixture.make(readLifetime: .zero)
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        )
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                read: SemanticReadRequest(cursor: first.snapshot.nextCursor)
            )
        }
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: "Item 139")
        XCTAssertEqual(fresh.snapshot.elements.map(\.label), ["Item 139"])
    }

    func testForeignCursorAndUnexposedElementCannotAuthorizeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        )
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil)
        let other = try await fixture.broker.open(taskKey: "task-b", processIdentifier: 60, url: URL(string: "https://example.test/other")!)
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-b", binding: other, bundleIdentifier: "com.ahmedelamin.LocalCodex",
                read: SemanticReadRequest(cursor: first.snapshot.nextCursor)
            )
        }
        await assertBrowserError(.elementNotFound) {
            try await fixture.broker.perform(
                taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 100, action: "AXPress"
            )
        }
        await fixture.assertNoInput()
    }

    func testContentViewSeparatesToolbarControlsAndMetadataFromReadableTextWithoutChangingActions() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "main", name: "Accessible region name", children: ["n1", "n4", "n5"]),
            semanticNode(1, role: "toolbar", name: "Tools", parent: "n0", children: ["n2"]),
            semanticNode(2, role: "button", name: "The matching phrase", parent: "n1", children: ["n3"]),
            semanticNode(3, role: "StaticText", name: "The matching phrase", parent: "n2"),
            semanticNode(4, role: "StaticText", name: "Actual document detail", parent: "n0"),
            semanticNode(5, role: "article", name: "Article accessible name", parent: "n0"),
            semanticNode(6, role: "StaticText", name: "Readable without landmarks", clickable: true),
            semanticNode(7, role: "navigation", name: "Navigation", children: ["n8"]),
            semanticNode(8, role: "StaticText", name: "Sidebar phrase", parent: "n7"),
        ])
        let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(content.snapshot.elements.map(\.label), ["Actual document detail", "Readable without landmarks"])
        XCTAssertEqual(content.snapshot.elements.map(\.contentScope), [.main, .unknown])
        XCTAssertEqual(content.snapshot.elements.map(\.supportsPress), [false, true])
        XCTAssertTrue(content.snapshot.formattedText.contains("document_content_shown=1"))
        let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: content.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init())
        XCTAssertEqual(all.snapshot.elements.map(\.contentKind),
            [.metadata, .control, .control, .control, .readable, .metadata, .readable, .navigation, .navigation])
        let button = try XCTUnwrap(all.snapshot.elements.first { $0.semanticRole == "button" })
        XCTAssertTrue(button.supportsPress)
        try await fixture.broker.perform(taskKey: "task-a", binding: all.binding, snapshot: all.snapshot,
            elementIndex: button.index, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: all.binding.targetID)
        XCTAssertEqual(pressed, [3])
    }

    func testContentViewWarnsThatOtherReadyControlsAreFilteredWhileAllRetainsTheirExactAction() async throws {
        for includeHeading in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            var nodes = [
                semanticNode(0, role: "main", name: "Synthetic workspace", children: includeHeading ? ["n1", "n2"] : ["n2"]),
                semanticNode(2, role: "menu", name: "Synthetic menu", parent: "n0", children: ["n3"]),
                semanticNode(3, role: "menuitem", name: "Synthetic menu action", parent: "n2", children: ["n4"], clickable: true),
                semanticNode(4, role: "StaticText", name: "Synthetic menu preview", parent: "n3"),
            ]
            if includeHeading { nodes.insert(semanticNode(1, role: "heading", name: "Synthetic results heading", parent: "n0"), at: 1) }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: nodes, semanticReadiness: .ready)
            let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
            let lines = content.snapshot.formattedText.split(separator: "\n").map(String.init)
            XCTAssertTrue(lines[1].contains("view=content")); XCTAssertTrue(lines[1].contains("semantic_readiness=ready"))
            XCTAssertTrue(lines[1].contains("source_truncated=0"))
            XCTAssertTrue(lines[2].hasPrefix("CONTENT_VIEW_SCOPE includes=readable_text,listbox_options other_controls_omitted=true"))
            XCTAssertTrue(lines[2].contains("Included options retain original actions"))
            XCTAssertTrue(lines[2].contains("read view=overview or all for other controls and before absence/access claims"))
            XCTAssertEqual(content.snapshot.elements.map(\.label), includeHeading ? ["Synthetic results heading"] : [])
            XCTAssertFalse(content.snapshot.formattedText.contains("Synthetic menu action"))
            XCTAssertFalse(content.snapshot.formattedText.contains("Synthetic menu preview"))
            XCTAssertTrue(lines[1].contains(includeHeading ? "no_matches=0" : "no_matches=1"))
            let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: content.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
            XCTAssertFalse(all.snapshot.formattedText.contains("CONTENT_VIEW_SCOPE"))
            let item = try XCTUnwrap(all.snapshot.elements.first { $0.semanticRole == "menuitem" })
            XCTAssertTrue(item.isEnabled); XCTAssertTrue(item.supportsPress)
            XCTAssertEqual(item.contentKind, .control)
            let row = try XCTUnwrap(all.snapshot.presentation?.rows.first { $0.index == item.index })
            XCTAssertEqual(row.actions, ["AXPress"])
            let preview = try XCTUnwrap(all.snapshot.elements.first { $0.label == "Synthetic menu preview" })
            XCTAssertEqual(preview.contentKind, .control); XCTAssertFalse(preview.supportsPress)
            try await fixture.broker.perform(taskKey: "task-a", binding: all.binding, snapshot: all.snapshot,
                elementIndex: item.index, action: "AXPress")
            let pressed = await fixture.transport.pressedNodeIDs(targetID: all.binding.targetID)
            XCTAssertEqual(pressed, [4], "Only the exact menu item receives input; the filtered text child gains no action")
        }
    }

    func testContentViewIncludesObservedListboxOptionsAndTextWithoutReclassifyingOrInferringActions() async throws {
        for scopeRole in ["main", "complementary"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: scopeRole, name: "Synthetic workspace", children: ["n1"]),
                semanticNode(1, role: "listbox", name: "Synthetic results", parent: "n0", children: ["n2"]),
                semanticNode(2, role: "group", name: "Synthetic group", parent: "n1", children: ["n3", "n5"]),
                semanticNode(3, role: "option", name: "Selectable result", parent: "n2", children: ["n7"], clickable: true),
                semanticNode(7, role: "group", name: "Result layout", parent: "n3", children: ["n4"]),
                semanticNode(4, role: "StaticText", name: "Result detail", parent: "n7"),
                semanticNode(5, role: "option", name: "Read-only result", parent: "n2", children: ["n6"], readOnly: true),
                semanticNode(6, role: "StaticText", name: "Read-only detail", parent: "n5"),
            ], semanticReadiness: .ready)
            let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
            XCTAssertEqual(content.snapshot.elements.map(\.label),
                ["Selectable result", "Result detail", "Read-only result", "Read-only detail"])
            XCTAssertEqual(content.snapshot.elements.map(\.contentKind), Array(repeating: .control, count: 4))
            XCTAssertEqual(content.snapshot.elements.map(\.contentScope),
                Array(repeating: scopeRole == "main" ? BrowserContentScope.main : .complementary, count: 4))
            XCTAssertEqual(content.snapshot.elements.map(\.supportsPress), [true, false, false, false])
            XCTAssertTrue(content.snapshot.formattedText.contains("document_content_shown=0"))
            XCTAssertTrue(content.snapshot.formattedText.contains("controls_shown=4"))
            let option = try XCTUnwrap(content.snapshot.elements.first)
            XCTAssertEqual(option.backendNodeID, 4); XCTAssertEqual(option.nodeID, "n3")
            let rows = try XCTUnwrap(content.snapshot.presentation).rows
            XCTAssertEqual(rows.first { $0.index == option.index }?.actions, ["AXPress"])
            for element in content.snapshot.elements.dropFirst() {
                XCTAssertEqual(rows.first { $0.index == element.index }?.actions, [])
                await assertBrowserError(.unsupportedAction("AXPress")) {
                    try await fixture.broker.perform(taskKey: "task-a", binding: content.binding, snapshot: content.snapshot,
                        elementIndex: element.index, action: "AXPress")
                }
            }
            try await fixture.broker.perform(taskKey: "task-a", binding: content.binding, snapshot: content.snapshot,
                elementIndex: option.index, action: "AXPress")
            let pressed = await fixture.transport.pressedNodeIDs(targetID: content.binding.targetID)
            XCTAssertEqual(pressed, [4])
        }
    }

    func testContentViewDoesNotPromoteUnscopedOptionsNavigationOrOtherControls() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "main", name: "Workspace", children: ["n1", "n2", "n3", "n4", "n7", "n10", "n13"]),
            semanticNode(1, role: "option", name: "Bare option", parent: "n0", clickable: true),
            semanticNode(2, role: "button", name: "Ordinary button", parent: "n0", clickable: true),
            semanticNode(3, role: "treeitem", name: "Tree item", parent: "n0", clickable: true),
            semanticNode(4, role: "navigation", name: "Navigation", parent: "n0", children: ["n5"]),
            semanticNode(5, role: "listbox", name: "Navigation list", parent: "n4", children: ["n6"]),
            semanticNode(6, role: "option", name: "Navigation option", parent: "n5", clickable: true),
            semanticNode(7, role: "banner", name: "Banner", parent: "n0", children: ["n8"]),
            semanticNode(8, role: "listbox", name: "Banner list", parent: "n7", children: ["n9"]),
            semanticNode(9, role: "option", name: "Banner option", parent: "n8", clickable: true),
            semanticNode(10, role: "contentinfo", name: "Footer", parent: "n0", children: ["n11"]),
            semanticNode(11, role: "listbox", name: "Footer list", parent: "n10", children: ["n12"]),
            semanticNode(12, role: "option", name: "Footer option", parent: "n11", clickable: true),
            semanticNode(13, role: "listbox", name: "Results", parent: "n0", children: ["n14"]),
            semanticNode(14, role: "option", name: "Result", parent: "n13", children: ["n15"], clickable: true),
            semanticNode(15, role: "button", name: "Nested button", parent: "n14", children: ["n16"], clickable: true),
            semanticNode(16, role: "StaticText", name: "Nested button text", parent: "n15"),
        ])
        let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(content.snapshot.elements.map(\.label), ["Result"])
        XCTAssertEqual(content.snapshot.elements.first?.contentKind, .control)
        await fixture.assertNoInput()
    }

    func testContentListboxInclusionRejectsMissingAmbiguousAndCyclicParentLineage() async throws {
        for lineage in ["missing", "duplicate", "cycle", "intervening-control"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            var nodes = [
                semanticNode(0, role: "main", name: "Workspace", children: ["n1"]),
                semanticNode(1, role: "listbox", name: "Results", parent: "n0", children: ["n2"]),
                semanticNode(2, role: "option", name: "Unverified result", parent: "n1", clickable: true),
            ]
            if lineage == "missing" { nodes.removeFirst() }
            if lineage == "duplicate" { nodes.append(semanticNode(1, role: "listbox", name: "Duplicate", parent: "n0")) }
            if lineage == "cycle" { nodes[0] = semanticNode(0, role: "main", name: "Workspace", parent: "n2", children: ["n1"]) }
            if lineage == "intervening-control" {
                nodes[2] = semanticNode(2, role: "option", name: "Unverified result", parent: "n3", clickable: true)
                nodes.append(semanticNode(3, role: "button", name: "Wrapper", parent: "n1", children: ["n2"], clickable: true))
            }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
            XCTAssertTrue(content.snapshot.elements.isEmpty)
            await fixture.assertNoInput()
        }
    }

    func testContentListboxRowsKeepTruncatedSourceAndImmutableContinuationFences() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let options = (2..<142).map { semanticNode($0, role: "option", name: "Result \($0)", parent: "n1", clickable: true) }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "complementary", name: "Workspace", children: ["n1"]),
            semanticNode(1, role: "listbox", name: "Results", parent: "n0", children: options.compactMap(\.nodeID)),
        ] + options, sourceTruncated: true)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        let cursor = try XCTUnwrap(first.snapshot.nextCursor)
        let firstReceipt = try XCTUnwrap(first.snapshot.readReceipt)
        XCTAssertTrue(firstReceipt.sourceTruncated); XCTAssertEqual(firstReceipt.selectedElementCount, 140)
        XCTAssertLessThanOrEqual(first.snapshot.formattedText.utf8.count, 16_384)
        XCTAssertTrue(first.snapshot.elements.allSatisfy { $0.contentKind == .control && $0.contentScope == .complementary })
        await assertBrowserError(.elementNotFound) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 100, action: "AXPress")
        }
        let next = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        XCTAssertEqual(next.snapshot.readReceipt?.sourceID, firstReceipt.sourceID)
        XCTAssertTrue(next.snapshot.readReceipt?.sourceTruncated == true)
        XCTAssertTrue(next.snapshot.elements.allSatisfy { $0.contentKind == .control && $0.contentScope == .complementary })
        XCTAssertTrue(Set(first.snapshot.elements.compactMap(\.nodeID)).isDisjoint(with: next.snapshot.elements.compactMap(\.nodeID)))
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 0, action: "AXPress")
        }
        await fixture.assertNoInput()
    }

    func testContentPrioritizesCapturedReadingPaneWhileAllKeepsSourceOrderAndExactActions() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let options = (2..<42).map {
            semanticNode($0, role: "option", name: "Selectable result \($0) " + String(repeating: "x", count: 120),
                parent: "n1", clickable: true)
        }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "complementary", name: "Result region", children: ["n1"]),
            semanticNode(1, role: "listbox", name: "Results", parent: "n0", children: options.compactMap(\.nodeID)),
        ] + options + [
            semanticNode(1000, role: "main", name: "Reading pane", children: ["n1001", "n1002", "n1003"]),
            semanticNode(1001, role: "heading", name: "Opened record", parent: "n1000"),
            semanticNode(1002, role: "StaticText", name: "The complete requested document detail.", parent: "n1000"),
            semanticNode(1003, role: "StaticText", name: "A distinct supporting passage.", parent: "n1000"),
        ])
        let content = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(Array(content.snapshot.elements.prefix(3).map(\.nodeID)), ["n1001", "n1002", "n1003"])
        XCTAssertTrue(content.snapshot.elements.prefix(3).allSatisfy { $0.contentKind == .readable && $0.contentScope == .main })
        let option = try XCTUnwrap(content.snapshot.elements.first { $0.semanticRole == "option" })
        XCTAssertEqual(option.index, 3); XCTAssertEqual(option.backendNodeID, 3); XCTAssertEqual(option.nodeID, "n2")
        XCTAssertEqual(option.contentScope, .complementary); XCTAssertEqual(option.contentKind, .control)
        XCTAssertTrue(option.supportsPress); XCTAssertNotNil(content.snapshot.nextCursor)
        await assertBrowserError(.unsupportedAction("AXPress")) {
            try await fixture.broker.perform(taskKey: "task-a", binding: content.binding, snapshot: content.snapshot,
                elementIndex: 0, action: "AXPress")
        }
        try await fixture.broker.perform(taskKey: "task-a", binding: content.binding, snapshot: content.snapshot,
            elementIndex: option.index, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: content.binding.targetID)
        XCTAssertEqual(pressed, [3], "Reordering changes only the published index, never the exact target")
        let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: content.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        XCTAssertEqual(Array(all.snapshot.elements.prefix(3).map(\.nodeID)), ["n0", "n1", "n2"])
    }

    func testContentPriorityKeepsUnselectedResultsAndAllDuplicateOrDistinctSupportingText() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let duplicate = "Exact result preview"
        let nodes = [
            semanticNode(0, role: "complementary", name: "Results", children: ["n1"]),
            semanticNode(1, role: "listbox", name: "Result list", parent: "n0", children: ["n2"]),
            semanticNode(2, role: "option", name: duplicate, parent: "n1", children: ["n3", "n4"], clickable: true),
            semanticNode(3, role: "StaticText", name: duplicate, parent: "n2"),
            semanticNode(4, role: "StaticText", name: "Distinct detail absent from the option label", parent: "n2"),
            semanticNode(5, role: "main", name: "Unselected reading pane"),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let unselected = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(unselected.snapshot.elements.map(\.label),
            [duplicate, duplicate, "Distinct detail absent from the option label"])
        XCTAssertEqual(unselected.snapshot.elements.map(\.supportsPress), [true, false, false])
        let body = semanticNode(6, role: "StaticText", name: "Opened document passage", parent: "n5")
        try await fixture.transport.replaceNodes(targetID: unselected.binding.targetID, nodes: nodes + [body])
        let selected = try await fixture.broker.snapshot(taskKey: "task-a", binding: unselected.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(selected.snapshot.elements.map(\.label),
            ["Opened document passage", duplicate, duplicate, "Distinct detail absent from the option label"])
        let query = try await fixture.broker.snapshot(taskKey: "task-a", binding: selected.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(query: "Distinct detail", view: .content))
        XCTAssertEqual(query.snapshot.elements.map(\.nodeID), ["n4"])
        XCTAssertEqual(query.snapshot.elements.first?.contentKind, .control)
        XCTAssertFalse(query.snapshot.elements.first?.supportsPress ?? true)
        await fixture.assertNoInput()
    }

    func testContentPriorityFreezesTheOrderedSelectionAcrossBoundedPagesAndSourceChanges() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let options = (2..<92).map { semanticNode($0, role: "option", name: "Result \($0)", parent: "n1", clickable: true) }
        let original = [
            semanticNode(0, role: "complementary", name: "Results", children: ["n1"]),
            semanticNode(1, role: "listbox", name: "Result list", parent: "n0", children: options.compactMap(\.nodeID)),
        ] + options + [
            semanticNode(1000, role: "article", name: "Reading pane", children: ["n1001"]),
            semanticNode(1001, role: "StaticText", name: "Captured document passage", parent: "n1000"),
            semanticNode(1002, role: "StaticText", name: "Readable without a landmark"),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: original, sourceTruncated: true)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        let firstReceipt = try XCTUnwrap(first.snapshot.readReceipt)
        XCTAssertEqual(Array(first.snapshot.elements.prefix(2).map(\.nodeID)), ["n1001", "n1002"])
        XCTAssertEqual(firstReceipt.selectedElementCount, 92); XCTAssertTrue(firstReceipt.sourceTruncated)
        let firstCursor = try XCTUnwrap(first.snapshot.nextCursor)
        await assertBrowserError(.elementNotFound) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 100, action: "AXPress")
        }
        try await fixture.transport.replaceNodes(targetID: first.binding.targetID, nodes: [
            semanticNode(1000, role: "article", name: "Reading pane", children: ["n1001"]),
            semanticNode(1001, role: "StaticText", name: "New live passage", parent: "n1000"),
        ])
        var page = first
        var labels = first.snapshot.elements.map(\.label)
        var pages = 1
        var cursor: String? = firstCursor
        while let next = cursor {
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: next))
            pages += 1; XCTAssertLessThan(pages, 12)
            XCTAssertEqual(page.snapshot.readReceipt?.sourceID, firstReceipt.sourceID)
            XCTAssertTrue(page.snapshot.readReceipt?.sourceTruncated == true)
            XCTAssertLessThanOrEqual(page.snapshot.formattedText.utf8.count, 16_384)
            labels += page.snapshot.elements.map(\.label)
            cursor = page.snapshot.nextCursor
        }
        XCTAssertEqual(labels, ["Captured document passage", "Readable without a landmark"] + options.map(\.name))
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 0, action: "AXPress")
        }
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        XCTAssertEqual(fresh.snapshot.elements.map(\.label), ["New live passage"])
        await fixture.assertNoInput()
    }

    func testLongFieldContinuationReconstructsExactUnicodeAndEscapedBytesWithBoundedOutput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        // The first split falls between a base character and its combining
        // mark; UTF-8 offsets must remain valid Unicode scalar boundaries.
        let text = String(repeating: "x", count: 4095) + "e\u{301}"
            + String(repeating: "🙂\\\"\n\t\u{0001}", count: 850) + " Tail answer: LARK-7392"
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "StaticText", name: text)])
        var observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        let source = try XCTUnwrap(observation.snapshot.readReceipt).sourceID
        var reconstructed = ""
        var end = 0
        var pages = 0
        repeat {
            pages += 1
            XCTAssertLessThan(pages, 20)
            XCTAssertLessThanOrEqual(observation.snapshot.formattedText.utf8.count, 16_384)
            XCTAssertEqual(observation.snapshot.elements.first?.label, text, "Action identity keeps the complete field.")
            let receipt = try XCTUnwrap(observation.snapshot.readReceipt)
            XCTAssertEqual(receipt.sourceID, source)
            XCTAssertEqual(receipt.selectedElementCount, 1)
            XCTAssertEqual(receipt.selectedFieldCount, 1)
            let span = try XCTUnwrap(receipt.exposures.first)
            XCTAssertEqual(span.startUTF8, end)
            XCTAssertEqual(span.totalUTF8, text.utf8.count)
            XCTAssertEqual(span.kind, .readable)
            let row = try XCTUnwrap(observation.snapshot.formattedText.split(separator: "\n").first { $0.hasPrefix("#0 ") })
            let emitted = try renderedJSONField("label", in: String(row))
            XCTAssertEqual(emitted.utf8.count, span.endUTF8 - span.startUTF8)
            reconstructed += emitted
            end = span.endUTF8
            guard let cursor = observation.snapshot.nextCursor else {
                XCTAssertFalse(receipt.fieldTruncated)
                XCTAssertFalse(receipt.outputTruncated)
                break
            }
            XCTAssertTrue(receipt.fieldTruncated)
            XCTAssertTrue(receipt.outputTruncated)
            observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        } while pages < 20
        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(reconstructed, text)
        XCTAssertEqual(end, text.utf8.count)
        XCTAssertTrue(observation.snapshot.formattedText.contains("LARK-7392"))
        await fixture.assertNoInput()
    }

    func testValueAndLinkTailsRemainReachableAndReceiptIncludesOnlyEmittedFields() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let value = String(repeating: "value detail ", count: 900) + "Final detail: 64"
        let link = "https://example.test/" + String(repeating: "segment/", count: 500) + "actual-destination"
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "textbox", name: "Observed label", link: link, value: value)])
        var observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init())
        var values = "", links = ""
        var pages = 0
        while true {
            pages += 1
            let receipt = try XCTUnwrap(observation.snapshot.readReceipt)
            XCTAssertEqual(receipt.selectedFieldCount, 3)
            let row = try XCTUnwrap(observation.snapshot.formattedText.split(separator: "\n").first { $0.hasPrefix("#0 ") })
            for span in receipt.exposures {
                switch span.field {
                case .label:
                    XCTAssertEqual(span.startUTF8, 0)
                    XCTAssertEqual(try renderedJSONField("label", in: String(row)), "Observed label")
                case .value:
                    XCTAssertEqual(span.startUTF8, values.utf8.count)
                    values += try renderedJSONField("value", in: String(row))
                case .linkURL:
                    XCTAssertEqual(span.startUTF8, links.utf8.count)
                    XCTAssertFalse(row.contains(" href="), "Partial URLs are not presented as exact destinations.")
                    links += try renderedJSONField("href_fragment", in: String(row))
                }
            }
            guard let cursor = observation.snapshot.nextCursor else { break }
            guard pages < 20 else { return XCTFail("Continuation failed to make progress") }
            observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: cursor))
        }
        XCTAssertEqual(values, value)
        XCTAssertEqual(links, link)
        XCTAssertFalse(try XCTUnwrap(observation.snapshot.readReceipt).fieldTruncated)
        XCTAssertEqual(observation.snapshot.elements.first?.value, value)
        XCTAssertEqual(observation.snapshot.elements.first?.linkURL, link)
        await fixture.assertNoInput()
    }

    func testFieldContinuationDoesNotWeakenFullActionIdentityOrOldSnapshotRejection() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let label = String(repeating: "a", count: 9000) + " original tail"
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "button", name: label)])
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init())
        let second = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: try XCTUnwrap(first.snapshot.nextCursor)))
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 0, action: "AXPress")
        }
        try await fixture.transport.replaceNodes(targetID: first.binding.targetID,
            nodes: [semanticNode(0, role: "button", name: String(repeating: "a", count: 9000) + " changed tail")])
        await assertBrowserError(.elementChanged) {
            try await fixture.broker.perform(taskKey: "task-a", binding: second.binding, snapshot: second.snapshot,
                elementIndex: 0, action: "AXPress")
        }
        await fixture.assertNoInput()
    }

    func testCaptureIdentitySeparatesFreshVirtualizedReadsAndKeepsRetainedSubtreeScope() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "article", name: "Card", children: ["n1"]),
            semanticNode(1, role: "StaticText", name: "First mounted row", parent: "n0"),
        ], sourceTruncated: true)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init())
        let firstReceipt = try XCTUnwrap(first.snapshot.readReceipt)
        let subtree = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content, snapshotID: first.snapshot.id, elementIndex: 0))
        let subtreeReceipt = try XCTUnwrap(subtree.snapshot.readReceipt)
        XCTAssertEqual(subtreeReceipt.sourceID, firstReceipt.sourceID)
        XCTAssertNotEqual(subtree.snapshot.actionSelectionID, first.snapshot.actionSelectionID)
        XCTAssertFalse(subtree.snapshot.isActionContinuation)
        XCTAssertEqual(subtreeReceipt.subtreeNodeID, "n0")
        XCTAssertEqual(subtreeReceipt.view, .content)
        XCTAssertEqual(subtreeReceipt.selectedElementCount, 1)
        XCTAssertTrue(subtreeReceipt.sourceTruncated)
        try await fixture.transport.replaceNodes(targetID: first.binding.targetID,
            nodes: [semanticNode(2, role: "StaticText", name: "Different mounted row")])
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: subtree.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .content))
        let freshReceipt = try XCTUnwrap(fresh.snapshot.readReceipt)
        XCTAssertNotEqual(freshReceipt.sourceID, firstReceipt.sourceID)
        XCTAssertEqual(freshReceipt.targetGeneration, firstReceipt.targetGeneration)
        XCTAssertNil(freshReceipt.subtreeNodeID)
        XCTAssertFalse(freshReceipt.sourceTruncated)
        XCTAssertEqual(fresh.snapshot.elements.map(\.label), ["Different mounted row"])
        await fixture.assertNoInput()
    }

    private func renderedJSONField(_ name: String, in row: String) throws -> String {
        let pattern = "(?:^| )" + NSRegularExpression.escapedPattern(for: name) + #"=("(?:\\.|[^"\\])*")"#
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(expression.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: row))
        return try JSONDecoder().decode(String.self, from: Data(row[range].utf8))
    }

    private func semanticNode(
        _ id: Int, role: String, name: String, parent: String? = nil,
        children: [String] = [], link: String? = nil, value: String? = nil,
        clickable: Bool = false, focusablePointer: Bool = false, disabled: Bool = false, readOnly: Bool = false,
        editable: Bool = false
    ) -> BrowserDocumentNode {
        BrowserDocumentNode(
            backendNodeID: Int64(id + 1), role: role, name: name, value: value,
            isDisabled: disabled, isReadOnly: readOnly, isIgnored: false,
            nodeID: "n\(id)", parentNodeID: parent, childNodeIDs: children, linkURL: link,
            isDOMClickable: clickable, isFocusablePointer: focusablePointer, isEditable: editable
        )
    }

    func testTaskScopedHandleRejectsCrossTaskSnapshot() async throws {
        let transport = FakeBrowserTabTransport()
        let generation = UUID()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: generation
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 41,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )

        do {
            _ = try await broker.snapshot(
                taskKey: "task-b",
                binding: binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex",
                query: "Mark this tab complete"
            )
            XCTFail("A cross-task browser handle must fail closed.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .crossTaskHandle)
        }
    }

    func testNavigationChangesEpochAndRejectsApprovedSnapshotBeforeInput() async throws {
        let transport = FakeBrowserTabTransport()
        let generation = UUID()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: generation
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 42,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observation = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: "Mark this tab complete"
        )
        try await transport.navigate(
            targetID: binding.targetID,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a?next=1")),
            loaderID: "loader-2"
        )

        do {
            try await broker.perform(
                taskKey: "task-a",
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
            XCTFail("A stale document epoch must reject before input.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .staleDocument)
        }
        let stalePressCount = await transport.pressCount(targetID: binding.targetID)
        XCTAssertEqual(stalePressCount, 0)

        let refreshed = try await broker.snapshot(
            taskKey: "task-a",
            binding: observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: "Mark this tab complete"
        )
        XCTAssertNotEqual(
            refreshed.binding.documentEpoch,
            observation.binding.documentEpoch
        )
    }



    func testNewObservationInvalidatesPriorBrowserSnapshot() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 46,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let first = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: "Mark this tab complete"
        )
        _ = try await broker.snapshot(
            taskKey: "task-a",
            binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: "Mark this tab complete"
        )

        do {
            try await broker.perform(
                taskKey: "task-a",
                binding: first.binding,
                snapshot: first.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
            XCTFail("A newer observation must invalidate the prior snapshot.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .staleSnapshot)
        }
        let pressCount = await transport.pressCount(targetID: binding.targetID)
        XCTAssertEqual(pressCount, 0)
    }

    func testClosedTargetRejectsBeforeInput() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 45,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        await transport.closeTarget(targetID: binding.targetID)

        do {
            _ = try await broker.snapshot(
                taskKey: "task-a",
                binding: binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex",
                query: nil
            )
            XCTFail("A closed tab must reject before any input.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .targetClosed)
        }
    }

    func testClosedOrReusedTargetCannotResurrectHandle() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 43,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        try await transport.replaceTargetInstance(targetID: binding.targetID)

        do {
            _ = try await broker.snapshot(
                taskKey: "task-a",
                binding: binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex",
                query: nil
            )
            XCTFail("A target-ID reuse must not resurrect the opaque handle.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .targetReplaced)
        }
    }

    func testExactBackgroundTargetMutatesWhileOtherTargetStaysForeground() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let bindingA = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 44,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observationA = try await broker.snapshot(
            taskKey: "task-a",
            binding: bindingA,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: "Mark this tab complete"
        )
        let targetB = try await transport.createForegroundTarget(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        let foregroundBefore = await transport.activeTargetID()
        XCTAssertEqual(foregroundBefore, targetB.targetID)

        try await broker.perform(
            taskKey: "task-a",
            binding: observationA.binding,
            snapshot: observationA.snapshot,
            elementIndex: 0,
            action: "AXPress"
        )

        let tabAPressCount = await transport.pressCount(targetID: bindingA.targetID)
        let tabBPressCount = await transport.pressCount(targetID: targetB.targetID)
        let foregroundAfter = await transport.activeTargetID()
        XCTAssertEqual(tabAPressCount, 1)
        XCTAssertEqual(tabBPressCount, 0)
        XCTAssertEqual(foregroundAfter, targetB.targetID)
    }

    func testSnapshotRevocationNeverResurrectsHandle() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            try await fixture.broker.revoke(
                taskKey: "task-a",
                binding: fixture.observation.binding
            )
        }
        await assertBrowserError(.handleMissing) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex",
                query: nil
            )
        }
        await assertBrowserError(.handleMissing) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex",
                query: nil
            )
        }
        await fixture.assertNoInput()
    }

    func testRevocationCancelsBothActionsAcrossAwaits() async throws {
        for setText in [false, true] {
            for atDispatch in [false, true] {
                let fixture = try await BrowserBrokerTestFixture.make()
                let revoke: @Sendable () async throws -> Void = {
                    try await fixture.broker.revoke(
                        taskKey: "task-a",
                        binding: fixture.observation.binding
                    )
                }
                if atDispatch {
                    await fixture.transport.onNextMutation(revoke)
                } else {
                    await fixture.transport.onNextObservation(revoke)
                }
                await assertBrowserError(atDispatch ? .staleSnapshot : .handleMissing) {
                    try await fixture.act(setText: setText)
                }
                await fixture.assertNoInput()
            }
        }
    }

    func testLateReloadAndFragmentChangeRejectBothActions() async throws {
        for setText in [false, true] {
            for sameLoader in [false, true] {
                let fixture = try await BrowserBrokerTestFixture.make()
                let destination: URL
                if sameLoader {
                    destination = try XCTUnwrap(URL(string: "http://127.0.0.1/a#changed"))
                } else {
                    destination = fixture.observation.snapshot.documentURL
                }
                let loaderID = sameLoader
                    ? fixture.observation.snapshot.loaderID : "replacement-loader"
                await fixture.transport.onNextMutation {
                    try await fixture.transport.navigate(
                        targetID: fixture.observation.binding.targetID,
                        url: destination,
                        loaderID: loaderID
                    )
                }
                await assertBrowserError(.staleDocument) {
                    try await fixture.act(setText: setText)
                }
                await fixture.assertNoInput()
                let refreshed = try await fixture.broker.snapshot(
                    taskKey: "task-a",
                    binding: fixture.observation.binding,
                    bundleIdentifier: "com.ahmedelamin.LocalCodex",
                    query: nil
                )
                XCTAssertNotEqual(
                    refreshed.binding.documentEpoch,
                    fixture.observation.binding.documentEpoch
                )
            }
        }
    }

    func testOverlappingSnapshotFailsClosed() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            await assertBrowserError(.operationInProgress) {
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a",
                    binding: fixture.observation.binding,
                    bundleIdentifier: "com.ahmedelamin.LocalCodex",
                    query: nil
                )
            }
        }
        let refreshed = try await fixture.broker.snapshot(
            taskKey: "task-a",
            binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: nil
        )
        XCTAssertNotEqual(refreshed.snapshot.id, fixture.observation.snapshot.id)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: false)
        }
        await fixture.assertNoInput()
    }

    func testFailedSnapshotInvalidatesPriorObservation() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            throw BrowserTabBrokerError.browserUnavailable("injected observation failure")
        }
        await assertBrowserError(.browserUnavailable("injected observation failure")) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex",
                query: nil
            )
        }
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: false)
        }
        await fixture.assertNoInput()
    }

    func testCrossTaskMutationsRejectBeforeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        for setText in [false, true] {
            await assertBrowserError(.crossTaskHandle) {
                try await fixture.act(setText: setText, taskKey: "task-b")
            }
        }
        await fixture.assertNoInput()
    }

    func testBackgroundSetTextIsSingleUseAndLeavesForegroundUntouched() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let targetB = try await fixture.transport.createForegroundTarget(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        try await fixture.act(setText: true)
        let valuesA = await fixture.transport.textValues(
            targetID: fixture.observation.binding.targetID
        )
        let valuesB = await fixture.transport.textValues(targetID: targetB.targetID)
        let foreground = await fixture.transport.activeTargetID()
        XCTAssertEqual(valuesA, ["updated"])
        XCTAssertTrue(valuesB.isEmpty)
        XCTAssertEqual(foreground, targetB.targetID)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: true)
        }
        let finalValuesA = await fixture.transport.textValues(
            targetID: fixture.observation.binding.targetID
        )
        XCTAssertEqual(finalValuesA, ["updated"])
    }

    func testReadOnlyTextIsNotAdvertisedOrMutated() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.makeTextReadOnly(
            targetID: fixture.observation.binding.targetID
        )
        await assertBrowserError(.elementChanged) {
            try await fixture.act(setText: true)
        }
        let refreshed = try await fixture.broker.snapshot(
            taskKey: "task-a",
            binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: nil
        )
        let field = try XCTUnwrap(refreshed.snapshot.element(at: 1))
        XCTAssertFalse(field.supportsSetText)
        await assertBrowserError(.unsupportedAction("set text")) {
            try await fixture.broker.setText(
                taskKey: "task-a",
                binding: refreshed.binding,
                snapshot: refreshed.snapshot,
                elementIndex: 1,
                text: "not allowed"
            )
        }
        await fixture.assertNoInput()
    }

    func testEarlierActionWitnessCannotFollowSubtreeSelectionOfSameCapture() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "article", name: "Card", children: ["n1"]),
            semanticNode(1, role: "button", name: "Intended action", parent: "n0"),
        ])
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let witness = try XCTUnwrap(first.snapshot.actionWitnesses[1])
        let subtree = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            read: .init(view: .all, snapshotID: first.snapshot.id, elementIndex: 0))
        XCTAssertEqual(subtree.snapshot.readReceipt?.sourceID, first.snapshot.readReceipt?.sourceID)
        XCTAssertNotEqual(subtree.snapshot.actionSelectionID, witness.selectionID)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.validatePublishedAction(taskKey: "task-a", binding: subtree.binding, witness: witness)
        }
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: subtree.binding, witness: witness, action: "AXPress")
        }
        await fixture.assertNoInput()
    }

    func testFreshCaptureCorroboratesOnlyCurrentSameBindingPublishedWitnesses() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "article", name: "Card", children: ["n1"]),
            semanticNode(1, role: "button", name: "Intended action", parent: "n0"),
        ])
        try await fixture.transport.setCommittedDocumentID(targetID: fixture.observation.binding.targetID)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let original = try XCTUnwrap(first.snapshot.actionWitnesses[1])
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .headings),
            priorPublishedActions: [original])
        XCTAssertTrue(fresh.snapshot.elements.isEmpty)
        XCTAssertTrue(fresh.snapshot.actionWitnesses.isEmpty, "Native presence alone cannot mint new row authority")
        let proof = try XCTUnwrap(fresh.snapshot.corroboratedActionWitnesses.first)
        XCTAssertEqual(proof.publicationID, original.publicationID)
        XCTAssertEqual(proof.element, original.element); XCTAssertEqual(proof.exposures, original.exposures)
        XCTAssertEqual(proof.snapshotID, original.snapshotID)
        XCTAssertEqual(proof.authoritySourceID, fresh.snapshot.readReceipt?.sourceID)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.validatePublishedAction(taskKey: "task-a", binding: fresh.binding, witness: original)
        }
        try await fixture.broker.validatePublishedAction(taskKey: "task-a", binding: fresh.binding, witness: proof)
        let second = try await fixture.broker.snapshot(taskKey: "task-a", binding: fresh.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .headings),
            priorPublishedActions: [proof, original])
        XCTAssertEqual(second.snapshot.corroboratedActionWitnesses.count, 1, "A stale earlier proof cannot seed authority")
        let foreign = try await fixture.broker.open(taskKey: "task-b", processIdentifier: 47,
            url: XCTUnwrap(URL(string: "http://127.0.0.1/foreign")))
        let other = try await fixture.broker.snapshot(taskKey: "task-b", binding: foreign,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all),
            priorPublishedActions: second.snapshot.corroboratedActionWitnesses)
        XCTAssertTrue(other.snapshot.corroboratedActionWitnesses.isEmpty)
        // Same immutable source is insufficient after selecting a new subtree.
        let all = try await fixture.broker.snapshot(taskKey: "task-a", binding: second.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let beforeSubtree = try XCTUnwrap(all.snapshot.actionWitnesses[1])
        let subtree = try await fixture.broker.snapshot(taskKey: "task-a", binding: all.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all, snapshotID: all.snapshot.id, elementIndex: 0))
        let afterSubtree = try await fixture.broker.snapshot(taskKey: "task-a", binding: subtree.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .headings),
            priorPublishedActions: [beforeSubtree])
        XCTAssertTrue(afterSubtree.snapshot.corroboratedActionWitnesses.isEmpty)
        await fixture.assertNoInput()
    }

    func testMutationPermitChecksCaptureDeadlineInsideCommit() throws {
        var inputs = 0
        let expired = BrowserMutationPermit(deadline: .now - .milliseconds(1))
        XCTAssertThrowsError(try expired.commit { inputs += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        XCTAssertEqual(inputs, 0)
        let current = BrowserMutationPermit(deadline: .now + .seconds(10))
        try current.commit { inputs += 1 }
        XCTAssertEqual(inputs, 1)
    }

    func testRepublishedOldestReferenceCannotBeEvictedByLaterRowsOnItsCurrentPage() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = (0..<220).map { semanticNode($0, role: "button", name: "Control \($0)") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        try await fixture.transport.setCommittedDocumentID(targetID: fixture.observation.binding.targetID)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(view: .all))
        let presentation = try XCTUnwrap(first.snapshot.presentation)
        XCTAssertGreaterThan(presentation.rows.count, 2)
        var registry = EmbeddedBrowserActionReferences()
        // Model a bounded native publication exposing only the first original
        // row. Its witness and every later test row are broker-minted, unchanged.
        var oldestPage = first.snapshot
        oldestPage.presentation = .init(snapshotID: first.snapshot.id, rows: [presentation.rows[0]])
        let firstSuffix = try XCTUnwrap(registry.publish(snapshot: oldestPage, binding: first.binding)[0])
        let oldest = try renderedJSONField("click_ref", in: firstSuffix)
        let contextID = UUID()
        let frozen = try registry.prepare(taskKey: "task-a", contextID: contextID, tool: "browser_click",
            arguments: ["click_ref": oldest], snapshot: oldestPage)
        var page = first
        var exposed = 1
        // Add exactly 119 other references, retaining the original issuance age.
        while exposed < 120 {
            page = try await fixture.broker.snapshot(taskKey: "task-a", binding: page.binding,
                bundleIdentifier: "com.ahmedelamin.LocalCodex", read: .init(cursor: try XCTUnwrap(page.snapshot.nextCursor)))
            var limited = page.snapshot
            let rows = Array(try XCTUnwrap(limited.presentation).rows.prefix(120 - exposed))
            limited.presentation = .init(snapshotID: limited.id, rows: rows)
            _ = registry.publish(snapshot: limited, binding: page.binding)
            exposed += rows.count
        }
        XCTAssertEqual(registry.countsForTesting.current, 120)
        // Re-publish the oldest row followed by one previously withheld row.
        // Eviction must skip this page's printed token without renewing its age.
        var mixed = first.snapshot
        mixed.isActionContinuation = true
        mixed.presentation = .init(snapshotID: mixed.id, rows: Array(presentation.rows.prefix(2)))
        let suffixes = registry.publish(snapshot: mixed, binding: first.binding)
        XCTAssertEqual(try renderedJSONField("click_ref", in: XCTUnwrap(suffixes[0])), oldest)
        XCTAssertTrue(registry.admits(frozen, snapshot: mixed))
        for suffix in suffixes.values {
            let token = try renderedJSONField("click_ref", in: suffix)
            let prepared = try registry.prepare(taskKey: "task-a", contextID: contextID, tool: "browser_click",
                arguments: ["click_ref": token], snapshot: mixed)
            XCTAssertTrue(registry.admits(prepared, snapshot: mixed))
        }
        XCTAssertEqual(registry.countsForTesting.current, 120)
        // A later publication can evict that old token: republication did not
        // promote it to the back of the FIFO or renew its immutable witness.
        mixed.presentation = .init(snapshotID: mixed.id, rows: [presentation.rows[2]])
        _ = registry.publish(snapshot: mixed, binding: first.binding)
        XCTAssertFalse(registry.admits(frozen, snapshot: mixed))
        await fixture.assertNoInput()
    }

    func testMutationPermitRevocationAndSingleUse() throws {
        var sends = 0
        let revoked = BrowserMutationPermit()
        revoked.revoke()
        XCTAssertThrowsError(try revoked.commit { sends += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        XCTAssertEqual(sends, 0)

        let committed = BrowserMutationPermit()
        try committed.commit { sends += 1 }
        XCTAssertThrowsError(try committed.commit { sends += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        committed.revoke()
        XCTAssertEqual(sends, 1)
    }

    func testRevokingOneTaskClosesOnlyItsTargetAndPreservesOtherBinding() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let bindingB = try await fixture.broker.open(
            taskKey: "task-b",
            processIdentifier: 47,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        try await fixture.broker.revoke(taskKey: "task-a", binding: fixture.observation.binding)
        let closed = await fixture.transport.closedTargetIDs()
        XCTAssertEqual(closed, [fixture.observation.binding.targetID])
        let targetA = try await fixture.transport.target(id: fixture.observation.binding.targetID)
        XCTAssertNil(targetA)
        let observationB = try await fixture.broker.snapshot(
            taskKey: "task-b", binding: bindingB,
            bundleIdentifier: "com.ahmedelamin.LocalCodex", query: nil
        )
        try await fixture.broker.setText(
            taskKey: "task-b", binding: observationB.binding,
            snapshot: observationB.snapshot, elementIndex: 1, text: "B only"
        )
        let valuesB = await fixture.transport.textValues(targetID: bindingB.targetID)
        let foreground = await fixture.transport.activeTargetID()
        XCTAssertEqual(valuesB, ["B only"])
        XCTAssertEqual(foreground, bindingB.targetID)
        for setText in [false, true] {
            await assertBrowserError(.handleMissing) { try await fixture.act(setText: setText) }
        }
        await fixture.assertNoInput()
    }

    func testSynchronousRuntimeRevocationWinsBeforeActorCleanup() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            await fixture.transport.onNextMutation {
                fixture.observation.binding.lifetime.revoke()
            }
            await assertBrowserError(.staleSnapshot) {
                try await fixture.act(setText: setText)
            }
            await fixture.assertNoInput()
        }
    }

    func testRevocationDuringCreationClosesTheUnpublishedTarget() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID())
        let lifetime = BrowserTabLifetime()
        await transport.onNextCreation { lifetime.revoke() }
        await assertBrowserError(.handleMissing) {
            _ = try await broker.open(
                taskKey: "pending", processIdentifier: 48,
                url: URL(string: "http://127.0.0.1/pending")!,
                lifetime: lifetime
            )
        }
        let closed = await transport.closedTargetIDs()
        XCTAssertEqual(closed, ["target-1"])
        let target = try await transport.target(id: "target-1")
        let presses = await transport.pressCount(targetID: "target-1")
        let values = await transport.textValues(targetID: "target-1")
        XCTAssertNil(target)
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(values.isEmpty)
    }

    func testSessionShutdownRevokesSuspendedMutationAndRejectsNewOpen() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            await fixture.transport.onNextObservation { await fixture.broker.invalidateAll() }
            await assertBrowserError(.handleMissing) {
                try await fixture.act(setText: setText)
            }
            await assertBrowserError(.handleMissing) {
                _ = try await fixture.broker.open(
                    taskKey: "later", processIdentifier: 47,
                    url: URL(string: "http://127.0.0.1/later")!
                )
            }
            await fixture.assertNoInput()
        }
    }

    func testFakeOracleRetainsInputHistoryAfterClose() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.act(setText: true)
        try await fixture.broker.revoke(taskKey: "task-a", binding: fixture.observation.binding)
        let values = await fixture.transport.textValues(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(values, ["updated"], "Closing a fake target must not erase evidence of input.")
    }






}

private struct BrowserBrokerTestFixture: Sendable {
    let transport: FakeBrowserTabTransport
    let broker: BrowserTabSessionBroker
    let observation: BrowserTabObservation

    static func make(readLifetime: Duration = .seconds(120)) async throws -> BrowserBrokerTestFixture {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID(),
            readLifetime: readLifetime
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 47,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observation = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.ahmedelamin.LocalCodex",
            query: nil
        )
        return BrowserBrokerTestFixture(
            transport: transport,
            broker: broker,
            observation: observation
        )
    }

    func act(setText: Bool, taskKey: String = "task-a") async throws {
        if setText {
            try await broker.setText(
                taskKey: taskKey,
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 1,
                text: "updated"
            )
        } else {
            try await broker.perform(
                taskKey: taskKey,
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
        }
    }

    func assertNoInput(file: StaticString = #filePath, line: UInt = #line) async {
        let presses = await transport.pressCount(targetID: observation.binding.targetID)
        let values = await transport.textValues(targetID: observation.binding.targetID)
        XCTAssertEqual(presses, 0, file: file, line: line)
        XCTAssertTrue(values.isEmpty, file: file, line: line)
    }
}

private func assertBrowserError(
    _ expected: BrowserTabBrokerError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: @Sendable () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as BrowserTabBrokerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor FakeBrowserTabTransport: BrowserTabTransport {
    private struct State {
        var target: BrowserTarget
        var document: BrowserDocumentObservation
        var pressCount = 0
        var pressedNodeIDs: [Int64] = []
        var textValues = [String]()
    }

    private var nextTarget = 1
    private var states = [String: State]()
    private var closedStates = [String: State]()
    private var closedIDs = [String]()
    private var nextCreationHook: (@Sendable () async throws -> Void)?
    private var foregroundTargetID: String?
    private var nextObservationHook: (@Sendable () async throws -> Void)?
    private var nextMutationHook: (@Sendable () async throws -> Void)?
    private var requestedReadiness = [BrowserReadReadiness]()

    func readinessRequests() -> [BrowserReadReadiness] { requestedReadiness }

    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness,
                        authorization: @escaping BrowserReadAuthorization) async throws -> BrowserDocumentObservation {
        guard let current = states[target.targetID]?.target else { throw BrowserTabBrokerError.targetClosed }
        guard current.instanceToken == target.instanceToken else { throw BrowserTabBrokerError.targetReplaced }
        try Task.checkCancellation()
        try authorization(current)
        return try await observeForRead(target: current, readiness: readiness)
    }

    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness) async throws -> BrowserDocumentObservation {
        requestedReadiness.append(readiness)
        return try await observe(target: target)
    }

    func onNextCreation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextCreationHook = hook
    }

    func closedTargetIDs() -> [String] { closedIDs }

    func onNextObservation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextObservationHook = hook
    }

    func onNextMutation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextMutationHook = hook
    }

    func replaceNodes(targetID: String, nodes: [BrowserDocumentNode], sourceTruncated: Bool = false,
                      semanticReadiness: BrowserDocumentObservation.SemanticReadiness? = nil) throws {
        guard var state = states[targetID] else { throw BrowserTabBrokerError.targetClosed }
        state.document = BrowserDocumentObservation(
            loaderID: state.document.loaderID, title: state.document.title, url: state.document.url,
            nodes: nodes, sourceTruncated: sourceTruncated
        )
        state.document.semanticReadiness = semanticReadiness
        states[targetID] = state
    }

    func setCommittedDocumentID(targetID: String, id: UUID = UUID()) throws {
        guard var state = states[targetID] else { throw BrowserTabBrokerError.targetClosed }
        state.document.committedDocumentID = id
        states[targetID] = state
    }

    func createTarget(url: URL) async throws -> BrowserTarget {
        let targetID = "target-\(nextTarget)"
        nextTarget += 1
        let target = makeTarget(targetID: targetID, url: url, instance: UUID())
        states[targetID] = State(
            target: target,
            document: makeDocument(url: url, loaderID: "loader-\(targetID)")
        )
        let hook = nextCreationHook
        nextCreationHook = nil
        if let hook { try await hook() }
        return target
    }

    func target(id: String) async throws -> BrowserTarget? {
        states[id]?.target
    }

    func activateTarget(id: String) async throws {
        guard states[id] != nil else {
            throw BrowserTabBrokerError.targetClosed
        }
        foregroundTargetID = id
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        guard let state = states[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard state.target.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        let hook = nextObservationHook
        nextObservationHook = nil
        if let hook { try await hook() }
        return state.document
    }

    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        let hook = nextMutationHook
        nextMutationHook = nil
        if let hook { try await hook() }
        try permit.commit {
            var state = try stateForMutation(
                target: target, backendNodeID: backendNodeID, document: document
            )
            state.pressCount += 1
            state.pressedNodeIDs.append(backendNodeID)
            states[target.targetID] = state
        }
    }

    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        let hook = nextMutationHook
        nextMutationHook = nil
        if let hook { try await hook() }
        try permit.commit {
            var state = try stateForMutation(
                target: target, backendNodeID: backendNodeID, document: document
            )
            state.textValues.append(text)
            states[target.targetID] = state
        }
    }

    private func stateForMutation(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation
    ) throws -> State {
        guard let state = states[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard state.target.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        guard state.document.loaderID == document.loaderID,
              state.document.url == document.url else {
            throw BrowserTabBrokerError.staleDocument
        }
        let approved = document.nodes.filter { $0.backendNodeID == backendNodeID }
        let current = state.document.nodes.filter { $0.backendNodeID == backendNodeID }
        guard approved.count == 1, current.count == 1 else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard current[0] == approved[0] else {
            throw BrowserTabBrokerError.elementChanged
        }
        return state
    }

    func navigate(targetID: String, url: URL, loaderID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.target = makeTarget(
            targetID: targetID,
            url: url,
            instanceToken: state.target.instanceToken
        )
        state.document = makeDocument(url: url, loaderID: loaderID)
        states[targetID] = state
    }

    func closeTarget(target: BrowserTarget) async throws {
        guard let current = states[target.targetID]?.target else { return }
        guard current.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        closeTarget(targetID: target.targetID)
    }

    func closeTarget(targetID: String) {
        if let state = states.removeValue(forKey: targetID) {
            closedStates[targetID] = state
            closedIDs.append(targetID)
        }
        if foregroundTargetID == targetID {
            foregroundTargetID = nil
        }
    }

    func replaceTargetInstance(targetID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.target = makeTarget(
            targetID: targetID,
            url: state.target.url,
            instance: UUID()
        )
        states[targetID] = state
    }

    func createForegroundTarget(url: URL) async throws -> BrowserTarget {
        let target = try await createTarget(url: url)
        try await activateTarget(id: target.targetID)
        return target
    }

    func pressCount(targetID: String) -> Int {
        (states[targetID] ?? closedStates[targetID])?.pressCount ?? 0
    }

    func pressedNodeIDs(targetID: String) -> [Int64] {
        (states[targetID] ?? closedStates[targetID])?.pressedNodeIDs ?? []
    }

    func activeTargetID() -> String? {
        foregroundTargetID
    }

    func textValues(targetID: String) -> [String] {
        (states[targetID] ?? closedStates[targetID])?.textValues ?? []
    }

    func makeTextReadOnly(targetID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.document = BrowserDocumentObservation(
            loaderID: state.document.loaderID,
            title: state.document.title,
            url: state.document.url,
            nodes: state.document.nodes.map { node in
                BrowserDocumentNode(
                    backendNodeID: node.backendNodeID,
                    role: node.role,
                    name: node.name,
                    value: node.value,
                    isDisabled: node.isDisabled,
                    isReadOnly: node.backendNodeID == 101 || node.isReadOnly,
                    isIgnored: node.isIgnored,
                    nodeID: node.nodeID, parentNodeID: node.parentNodeID,
                    childNodeIDs: node.childNodeIDs, linkURL: node.linkURL,
                    isDOMClickable: node.isDOMClickable, isFocusablePointer: node.isFocusablePointer
                )
            }
        )
        states[targetID] = state
    }

    private func makeTarget(
        targetID: String,
        url: URL,
        instance: UUID
    ) -> BrowserTarget {
        makeTarget(
            targetID: targetID,
            url: url,
            instanceToken: "ws://fake/\(targetID)/\(instance.uuidString)"
        )
    }

    private func makeTarget(
        targetID: String,
        url: URL,
        instanceToken: String
    ) -> BrowserTarget {
        BrowserTarget(
            targetID: targetID,
            instanceToken: instanceToken,
            title: "Safe computer-use benchmark - Computa",
            url: url
        )
    }

    private func makeDocument(
        url: URL,
        loaderID: String
    ) -> BrowserDocumentObservation {
        BrowserDocumentObservation(
            loaderID: loaderID,
            title: "Safe computer-use benchmark - Computa",
            url: url,
            nodes: [
                BrowserDocumentNode(
                    backendNodeID: 100,
                    role: "button",
                    name: "Mark this tab complete",
                    value: nil,
                    isDisabled: false,
                    isReadOnly: false,
                    isIgnored: false
                ),
                BrowserDocumentNode(
                    backendNodeID: 101,
                    role: "textbox",
                    name: "Editable note",
                    value: "",
                    isDisabled: false,
                    isReadOnly: false,
                    isIgnored: false
                ),            ]
        )
    }
}
