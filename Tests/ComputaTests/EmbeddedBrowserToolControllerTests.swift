import Foundation
import XCTest
@testable import Computa

@MainActor
final class EmbeddedBrowserToolControllerTests: XCTestCase {
    func testModelFacingEpochProjectionPreservesCanonicalSnapshotAndLiteralPageBytes() async throws {
        let backend = EmbeddedBrowserFixtureBackend()
        let broker = BrowserTabSessionBroker(transport: backend, browserGeneration: UUID(), ownership: .borrowed)
        let humanID = await backend.humanID
        let observedTarget = try await backend.target(id: humanID)
        let target = try XCTUnwrap(observedTarget)
        let binding = try await broker.bindBorrowed(taskKey: "projection", processIdentifier: 42, target: target)
        let epochField = " document_epoch=\(binding.documentEpoch.uuidString)"
        let literal = " tab_handle=\(binding.handle.uuidString)\(epochField) source=page\nAXSNAPSHOT id=page U+002D-\u{2011} e\u{0301}"
        await backend.setObservedResult(literal)
        let observation = try await broker.snapshot(taskKey: "projection", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let snapshot = observation.snapshot
        let canonical = snapshot.formattedText
        let projected = EmbeddedBrowserToolController.modelFacingSnapshotText(snapshot)
        let canonicalHeader = try XCTUnwrap(canonical.split(separator: "\n").first).description
        let projectedHeader = try XCTUnwrap(projected.split(separator: "\n").first).description
        XCTAssertTrue(canonicalHeader.contains(epochField))
        XCTAssertFalse(projectedHeader.contains(" document_epoch="))
        XCTAssertEqual(projectedHeader, canonicalHeader.replacingOccurrences(of: epochField, with: ""))
        XCTAssertEqual(Array(projected.dropFirst(projectedHeader.count).utf8),
                       Array(canonical.dropFirst(canonicalHeader.count).utf8), "Only the host header may change; all page rows and READ provenance retain exact bytes")
        XCTAssertTrue(projected.contains(epochField), "A page value resembling host metadata must not be scrubbed")
        XCTAssertEqual(try snapshotID(projected), snapshot.id.uuidString)
        XCTAssertEqual(try field("tab_handle", in: projected), snapshot.tabHandle.uuidString)
        XCTAssertEqual(snapshot.documentEpoch, binding.documentEpoch)
        XCTAssertEqual(snapshot.formattedText, canonical)
        XCTAssertEqual(snapshot.evidenceDocument?.nodes.last?.name, literal)
        XCTAssertEqual(snapshot.presentation?.snapshotID, snapshot.id)
        XCTAssertEqual(try field("source_observation", in: projected), try field("source_observation", in: canonical))
        try await broker.perform(taskKey: "projection", binding: observation.binding, snapshot: snapshot,
            elementIndex: 1, action: "AXPress")
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 1); XCTAssertEqual(counts.fills, 0)
        try await broker.revoke(taskKey: "projection", binding: observation.binding)
    }

    func testProjectedReadAndPostInputKeepExactSingleUseSnapshotIdentifiers() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read")
        XCTAssertFalse(try XCTUnwrap(read.split(separator: "\n").first).contains("document_epoch="))
        let id = try snapshotID(read)
        let before = await backend.counts()
        // This is the exact malformed UUID shape observed in the native call:
        // a snapshot prefix combined with a thirteen-character epoch suffix.
        let mixed = "2EAB84FB-C48F-4313-BFB6-3C010A3E722D1"
        let malformed: [String: Any] = ["snapshot_id": mixed, "element_index": 0, "text": "MUST_NOT_APPEAR"]
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill",
                arguments: JSONSerialization.data(withJSONObject: malformed))
            XCTFail("Malformed references must be rejected before approval")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .invalidRead("Use an exact observed browser identifier.")) }
        do { _ = try await call(controller, "browser_fill", malformed); XCTFail("Direct calls must reject the same malformed reference") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .invalidRead("Use an exact observed browser identifier.")) }
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], key: "turn-b")
        let foreign = try await call(controller, "browser_read", key: "turn-b")
        do { _ = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(foreign), "element_index": 0, "text": "MUST_NOT_APPEAR"]); XCTFail("Another task's valid UUID cannot authorize this task") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let denied = await backend.counts()
        XCTAssertEqual(denied.fills, 0); XCTAssertEqual(denied.presses, 0)
        XCTAssertEqual(denied.observes, before.observes + 2, "Only the separate task's binding/read may observe; denied references cannot reach mutation preflight")
        let arguments: [String: Any] = ["snapshot_id": id, "element_index": 0, "text": "UA 4629"]
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill",
            arguments: JSONSerialization.data(withJSONObject: arguments))
        let fill = try await call(controller, "browser_fill", arguments)
        let fresh = try availableObservation(fill)
        XCTAssertFalse(try XCTUnwrap(fresh.split(separator: "\n").first).contains("document_epoch="))
        XCTAssertNotEqual(try snapshotID(fresh), id)
        XCTAssertEqual(try field("tab_handle", in: fresh), try field("tab_handle", in: read))
        XCTAssertEqual(try actionReferenceMetadata(fresh)["snapshot_id"] as? String, try snapshotID(fresh))
        do { _ = try await call(controller, "browser_fill", arguments); XCTFail("Omitting presentation metadata cannot revive a consumed reference") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let clicked = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1])
        XCTAssertFalse(try XCTUnwrap(availableObservation(clicked).split(separator: "\n").first).contains("document_epoch="))
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1]); XCTFail("Click also consumes the exact reference") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 1)
        let fieldValue = await backend.fieldValue()
        XCTAssertEqual(fieldValue, "UA 4629")
        let closed = try jsonObject(await call(controller, "browser_close"))
        XCTAssertEqual(closed["released"] as? Bool, true)
        XCTAssertEqual(closed["existing_user_tab_preserved"] as? Bool, true)
        _ = await controller.shutdown()
    }

    func testPublishedReadAndSuccessfulCloseRepeatOnlyGenericLiteralCopyGuidanceWithoutChangingValues() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let literal = "ID-A-B\u{2011}C  D\tE\nF\u{00A0}G-e\u{0301}"
        await backend.setObservedResult(literal)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        let state = try actionReferenceMetadata(read)
        let guidance = try XCTUnwrap(state["literal_copy_guidance"] as? String)
        XCTAssertLessThanOrEqual(guidance.utf8.count, 384)
        XCTAssertTrue(guidance.contains("already observed")); XCTAssertTrue(guidance.contains("inline code"))
        XCTAssertTrue(guidance.contains("exact raw output"))
        XCTAssertTrue(guidance.contains("Preserve original Unicode and whitespace"))
        XCTAssertTrue(guidance.contains("ASCII '-' (U+002D) must never become U+2011"))
        XCTAssertTrue(guidance.contains("Inline code changes presentation, not characters"))
        XCTAssertTrue(guidance.contains("no new observation or action authority"))
        let row = try XCTUnwrap(read.split(separator: "\n").first { $0.hasPrefix("#2 ") }).description
        let regex = try NSRegularExpression(pattern: #"label=("(?:[^"\\]|\\.)*")"#)
        let match = try XCTUnwrap(regex.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: row))
        let published = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row[range].utf8), options: .fragmentsAllowed) as? String)
        XCTAssertEqual(Array(published.utf8), Array(literal.utf8), "Observation must preserve spaces, controls, Unicode and decomposed text byte-for-byte")
        XCTAssertFalse(guidance.contains("ID-A-B"), "Guidance cannot duplicate an observed value")
        let closeOutput = try await call(controller, "browser_close")
        let closed = try jsonObject(closeOutput)
        XCTAssertEqual(closed["released"] as? Bool, true)
        XCTAssertEqual(closed["existing_user_tab_preserved"] as? Bool, true)
        XCTAssertEqual(closed["literal_copy_guidance"] as? String, guidance)
        XCTAssertEqual(Set(closed.keys), ["released", "existing_user_tab_preserved", "literal_copy_guidance"])
        do { _ = try await call(controller, "browser_read"); XCTFail("Close must not provide a last snapshot or retain reading authority") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.closes, 1)
        _ = await controller.shutdown()
    }

    func testUnconfirmedClosePublishesNoLiteralGuidanceAndRetiresExistingAuthority() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read")
        XCTAssertNotNil(try actionReferenceMetadata(read)["literal_copy_guidance"])
        await backend.failNextClose()
        var closeOutput: String?
        do { closeOutput = try await call(controller, "browser_close"); XCTFail("Unconfirmed close cannot return success guidance") }
        catch {
            XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Task-tab cleanup could not be confirmed."))
            XCTAssertFalse(error.localizedDescription.contains("literal_copy_guidance"))
        }
        XCTAssertNil(closeOutput)
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(read), "element_index": 1]); XCTFail("Failed physical close still retires prior authority") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = await controller.shutdown()
    }

    func testLiteralGuidanceBudgetFallbackDoesNotPublishPartialMetadataOrReviveOldReferences() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let initial = try await call(controller, "browser_read", ["view": "all"])
        let originalText = try XCTUnwrap(initial.components(separatedBy: "\nBROWSER_ACTION_REFERENCES ").first)
        // Exercise the actual read formatter at its existing byte boundary. A
        // bounded provider-independent metadata row leaves no space for hints.
        let hiddenEpochBytes = " document_epoch=".utf8.count + UUID().uuidString.utf8.count
        let padding = 16_384 - originalText.utf8.count - hiddenEpochBytes + "computa_webkit_dom".utf8.count - 8
        await backend.setObservationSourceName(String(repeating: "x", count: padding))
        let nearLimit = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertLessThanOrEqual(nearLimit.utf8.count, 16_384)
        XCTAssertGreaterThan(nearLimit.utf8.count, 16_000)
        XCTAssertFalse(nearLimit.contains("BROWSER_ACTION_REFERENCES"), "Optional guidance is omitted whole, never truncated into partial capabilities")
        XCTAssertFalse(nearLimit.contains("literal_copy_guidance"))
        XCTAssertFalse(try XCTUnwrap(nearLimit.split(separator: "\n").first).contains("document_epoch="), "The whole-metadata budget fallback uses the same projected header")
        XCTAssertNotEqual(try snapshotID(nearLimit), try snapshotID(initial))
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(initial), "element_index": 1]); XCTFail("Omitted metadata cannot revive older references") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        await backend.setObservationSourceName(String(repeating: "x", count: 17_000))
        var rejectedOutput: String?
        do { rejectedOutput = try await call(controller, "browser_read", ["view": "all"]); XCTFail("Over-budget observation must fail before publication") }
        catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        XCTAssertNil(rejectedOutput)
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(nearLimit), "element_index": 1]); XCTFail("Failed publication must leave no retained action references") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = await controller.shutdown()
    }

    private func actionReferenceMetadata(_ read: String) throws -> [String: Any] {
        let line = try XCTUnwrap(read.split(separator: "\n").first { $0.hasPrefix("BROWSER_ACTION_REFERENCES ") })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst("BROWSER_ACTION_REFERENCES ".count).utf8)) as? [String: Any])
    }

    func testReadPublishesOnlyCurrentEligibleActionReferencesAndInputConsumesThem() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        let line = try XCTUnwrap(read.split(separator: "\n").first { $0.hasPrefix("BROWSER_ACTION_REFERENCES ") })
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst("BROWSER_ACTION_REFERENCES ".count).utf8)) as? [String: Any])
        XCTAssertEqual(state["snapshot_id"] as? String, try snapshotID(read))
        XCTAssertEqual(state["supersedes_previous"] as? Bool, true)
        XCTAssertEqual(state["consumed_by_admitted_input"] as? Bool, true)
        XCTAssertEqual(state["clickable_element_indices"] as? [Int], [1])
        XCTAssertEqual(state["fillable_element_indices"] as? [Int], [0])
        XCTAssertLessThanOrEqual(read.utf8.count, 16_384)
        let output = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(read), "element_index": 0, "text": "UA 1842"])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let next = try XCTUnwrap(result["action_references"] as? [String: Any])
        XCTAssertEqual(next["consumed"] as? Bool, true)
        XCTAssertEqual(next["next"] as? String, "current_observation")
        let observed = try XCTUnwrap(result["current_observation"] as? [String: Any])
        XCTAssertEqual(observed["status"] as? String, "available")
        let returned = try XCTUnwrap(observed["text"] as? String)
        XCTAssertEqual(try actionReferenceMetadata(returned)["literal_copy_guidance"] as? String,
                       state["literal_copy_guidance"] as? String)
        XCTAssertNotEqual(try snapshotID(returned), try snapshotID(read))
        do {
            _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(read), "element_index": 1])
            XCTFail("Guidance must not retain input authority after admitted fill")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let fresh = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertNotEqual(try snapshotID(fresh), try snapshotID(read))
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0)
        _ = await controller.shutdown()
    }

    func testPostInputObservationSuppliesFreshFillThenClickReferencesWithoutAnotherRead() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let original = try await call(controller, "browser_read")
        let fill = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(original), "element_index": 0, "text": "UA 4629"])
        let next = try XCTUnwrap(jsonObject(fill)["next"] as? String)
        XCTAssertTrue(next.contains("Recheck each current row's label/action; indices change"))
        XCTAssertTrue(next.contains("Use only its new references; prior references remain consumed"))
        XCTAssertTrue(next.contains("Input already dispatched: if the page is unchanged, wait/read instead of clicking again"))
        let fresh = try availableObservation(fill)
        XCTAssertTrue(fresh.contains("UA 4629"))
        XCTAssertNotEqual(try snapshotID(fresh), try snapshotID(original))
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(original), "element_index": 1]); XCTFail("Old action cannot be replayed") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let click = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1])
        let final = try availableObservation(click)
        XCTAssertTrue(final.contains("UA 4629"))
        XCTAssertFalse(final.contains("UA 4629 departs at 18:45"), "Overview does not invent unexposed body evidence")
        XCTAssertNotEqual(try snapshotID(final), try snapshotID(fresh))
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1]); XCTFail("Click capability is consumed too") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let body = try await call(controller, "browser_read", ["view": "content"])
        XCTAssertTrue(body.contains("UA 4629 departs at 18:45"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 1)
        XCTAssertEqual(counts.creates, 1); XCTAssertEqual(counts.navigations, 0)
        XCTAssertLessThanOrEqual(fill.utf8.count, 20_480); XCTAssertLessThanOrEqual(click.utf8.count, 20_480)
        _ = await controller.shutdown()
    }

    func testPostInputObservationFailuresPreserveDispatchAndExposeNoCapabilityOrPrivateError() async throws {
        for scenario in ["read_failed", "no_read_authority", "generation_drift", "redirect", "replaced", "protected", "drift_after_capture"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Check http://localhost:8123/flight only.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let original = try await call(controller, "browser_read", scope: scope)
            await backend.configureAfterInput(scenario)
            let fill = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(original), "element_index": 0, "text": "UA 4629"], scope: scope)
            let result = try jsonObject(fill)
            XCTAssertEqual(result["dispatched"] as? Bool, true, scenario)
            XCTAssertEqual(result["no_replay"] as? Bool, true)
            XCTAssertEqual(result["result_verified"] as? Bool, false)
            let observation = try XCTUnwrap(result["current_observation"] as? [String: Any])
            XCTAssertEqual(observation["status"] as? String, "unavailable", scenario)
            XCTAssertNil(observation["snapshot_id"]); XCTAssertNil(observation["text"])
            XCTAssertFalse(fill.contains("PRIVATE_READ_ERROR")); XCTAssertFalse(fill.contains("AXSNAPSHOT"))
            do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(original), "element_index": 1], scope: scope); XCTFail("Failed observation must not resurrect consumed input") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            let counts = await backend.counts()
            XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0)
            if ["redirect", "replaced", "protected"].contains(scenario) {
                XCTAssertEqual(counts.observes, 3, "After-input target denial must precede another observation")
            }
            if scenario == "read_failed" {
                let fresh = try await call(controller, "browser_read", scope: scope)
                XCTAssertTrue(fresh.contains("UA 4629"), "Explicit later read can recover without refilling")
                let finalCounts = await backend.counts(); XCTAssertEqual(finalCounts.fills, 1)
            }
            _ = await controller.shutdown()
        }
    }

    func testReleaseDuringPostInputReadRetainsDispatchWithoutPublishingLateReferences() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read")
        await backend.configureAfterInput("hold_observation")
        let operation = Task { try await self.call(controller, "browser_fill", ["snapshot_id": self.snapshotID(read), "element_index": 0, "text": "UA 4629"]) }
        await backend.waitUntilObservationHeld()
        _ = await controller.release(taskKey: "turn-a")
        await backend.resumeObservation()
        let result = try jsonObject(await operation.value)
        XCTAssertEqual(result["dispatched"] as? Bool, true)
        let observation = try XCTUnwrap(result["current_observation"] as? [String: Any])
        XCTAssertEqual(observation["status"] as? String, "unavailable")
        XCTAssertNil(observation["text"]); XCTAssertNil(observation["snapshot_id"])
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.closes, 1)
        _ = await controller.shutdown()
    }

    func testFreshReadRetriesOneNavigationRaceWithTheSameLeaseAndFreshReferences() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let scope = ComputerTaskScope(userPrompt: "Read http://localhost:8123/flight only.")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
        let first = try await call(controller, "browser_read", ["view": "all"], scope: scope)
        let before = await backend.counts()
        await backend.failObservations([.staleDocument], redirect: URL(string: "http://localhost:8123/result")!)
        let fresh = try await call(controller, "browser_read", ["view": "all", "query": "Check flight"], scope: scope)
        XCTAssertTrue(fresh.contains("/result"))
        XCTAssertTrue(fresh.contains("Check flight"), "The retry retains the caller's view and query")
        XCTAssertEqual(try field("tab_handle", in: fresh), try field("tab_handle", in: first))
        XCTAssertNotEqual(try snapshotID(fresh), try snapshotID(first))
        do {
            _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(first), "element_index": 1], scope: scope)
            XCTFail("A failed old-document read must not preserve old action authority")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes + 2)
        XCTAssertEqual(after.creates, before.creates); XCTAssertEqual(after.navigations, 0)
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
    }

    func testSemanticReadinessDefaultsToAbsentForOtherBackends() async throws {
        let observation = BrowserDocumentObservation(loaderID: "ordinary", title: "Fixture",
            url: URL(string: "http://localhost:8123/flight")!, nodes: [])
        XCTAssertNil(observation.semanticReadiness)
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setObservationSourceName("chrome_devtools")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertTrue(read.contains("source=chrome_devtools"))
        XCTAssertFalse(read.contains("semantic_readiness="))
        XCTAssertTrue(read.contains("actions=[\"AXPress\"]"), "Absent optional metadata does not change existing capabilities")
        _ = await controller.shutdown()
    }

    func testReadyObservationPublishesOnlyTheFiniteReadinessMarker() async throws {
        let wait = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == "browser_wait" })
        let description = try XCTUnwrap(wait["description"] as? String)
        XCTAssertTrue(description.contains("When text is omitted, wait for readable text or controls after document readiness"))
        XCTAssertTrue(description.contains("a title-only or empty shell is not ready"))
        XCTAssertTrue(description.contains("This readiness is not proof that requested content exists"))
        XCTAssertTrue(description.contains("Does not refresh or replay actions"))
        let schema = try XCTUnwrap(wait["inputSchema"] as? [String: Any])
        XCTAssertFalse((schema["required"] as? [String] ?? []).contains("text"))
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let omission = try XCTUnwrap(properties["text"]?["description"] as? String)
        XCTAssertTrue(omission.contains("Omit text to wait for readable text or controls after document readiness"))
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setSemanticReadiness(.ready)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertEqual(try field("semantic_readiness", in: read), "ready")
        XCTAssertEqual(read.components(separatedBy: "semantic_readiness=").count - 1, 1)
        XCTAssertTrue(read.contains("Check flight"))
        XCTAssertTrue(read.contains("subject_relevance=not_verified"), "Readiness is not task success or document relevance")
        let references = try actionReferenceMetadata(read)
        XCTAssertEqual(references["clickable_element_indices"] as? [Int], [1])
        XCTAssertEqual(references["fillable_element_indices"] as? [Int], [0])
        let before = await backend.counts()
        XCTAssertEqual(before.presses, 0); XCTAssertEqual(before.fills, 0); XCTAssertEqual(before.navigations, 0)
        _ = await controller.shutdown()
    }

    func testEmptyAtDeadlineIsNonErrorInconclusiveEvidenceWithoutMutationAuthority() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"])
        await backend.setSemanticReadiness(.emptyAtDeadline, empty: true)
        let empty = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertEqual(try field("semantic_readiness", in: empty), "empty_at_deadline")
        XCTAssertTrue(empty.contains("source_nodes=0")); XCTAssertTrue(empty.contains("no_matches=1"))
        XCTAssertTrue(empty.contains("subject_relevance=not_verified"))
        XCTAssertNotEqual(try snapshotID(empty), try snapshotID(first))
        let references = try actionReferenceMetadata(empty)
        XCTAssertEqual(references["clickable_element_indices"] as? [Int], [])
        XCTAssertEqual(references["fillable_element_indices"] as? [Int], [])
        for (id, index, expected) in [(try snapshotID(first), 1, BrowserTabBrokerError.staleSnapshot),
                                      (try snapshotID(empty), 0, .elementNotFound)] {
            do {
                _ = try await call(controller, "browser_click", ["snapshot_id": id, "element_index": index])
                XCTFail("Readiness metadata cannot create or retain input authority")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, expected) }
        }
        await backend.setSemanticReadiness(.ready)
        let fresh = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertEqual(try field("semantic_readiness", in: fresh), "ready")
        XCTAssertEqual(try field("tab_handle", in: fresh), try field("tab_handle", in: first))
        XCTAssertTrue(fresh.contains("Check flight"), "A later read may expose new ordinary content under the same lease")
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.navigations, 0)
        _ = await controller.shutdown()
    }

    func testFreshReadRetryIsBoundedAndDoesNotRecoverOtherFailures() async throws {
        for failures: [BrowserTabBrokerError] in [[.staleDocument, .staleDocument], [.browserUnavailable("read failed")]] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read")
            let before = await backend.counts()
            await backend.failObservations(failures)
            do { _ = try await call(controller, "browser_read"); XCTFail("The final read failure must propagate") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError, failures.last) }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + failures.count)
            do {
                _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(first), "element_index": 1])
                XCTFail("Failed reads cannot leave an old controller capability current")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0); XCTAssertEqual(after.navigations, 0)
            _ = await controller.shutdown()
        }
    }

    func testFreshReadRetryRechecksScopeAndPhysicalTargetBeforeObservingAgain() async throws {
        for replaced in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Read http://localhost:8123/flight only.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let first = try await call(controller, "browser_read", scope: scope)
            let before = await backend.counts()
            await backend.failObservations([.staleDocument],
                redirect: replaced ? nil : URL(string: "https://unrelated.example/private")!, replaceTarget: replaced)
            do { _ = try await call(controller, "browser_read", scope: scope); XCTFail("Changed target or scope must fail") }
            catch {
                if replaced { XCTAssertEqual(error as? BrowserTabBrokerError, .targetClosed) }
                else if let failure = error as? BrowserTabBrokerError, case .invalidRead = failure { /* Scope still rejects the redirect. */ }
                else { XCTFail("Expected a scope failure, got \(error)") }
            }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1, "Denial must precede the retry's observation")
            do {
                _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(first), "element_index": 1], scope: scope)
                XCTFail("An invalidated read cannot revive old references")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testReadContinuationNeverRestartsAfterNavigation() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.showManyControls()
        let first = try await call(controller, "browser_read", ["view": "all"])
        let cursor = try field("next_cursor", in: first)
        XCTAssertNotEqual(cursor, "none")
        let before = await backend.counts()
        await backend.failObservations([.staleDocument])
        do { _ = try await call(controller, "browser_read", ["cursor": cursor]); XCTFail("A stale continuation cannot become a new read") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleDocument) }
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes + 1)
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
    }

    func testFreshReadDoesNotRetryAfterCancellationOrLeaseRelease() async throws {
        for cancelled in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let before = await backend.counts()
            await backend.failObservations([.staleDocument])
            await backend.holdNextRead()
            let operation = Task { try await self.call(controller, "browser_read") }
            await backend.waitUntilObservationHeld()
            if cancelled { operation.cancel() }
            else { _ = await controller.release(taskKey: "turn-a") }
            await backend.resumeObservation()
            do { _ = try await operation.value; XCTFail("A cancelled or released read must not recover") }
            catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
            }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0); XCTAssertEqual(after.navigations, 0)
            _ = await controller.shutdown()
        }
    }

    func testPostInputObservationRetainsDocumentAndPaginationAuthority() async throws {
        for scenario in ["new_document", "same_url_reload", "pagination"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read")
            await backend.configureAfterInput(scenario)
            let filled = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(first), "element_index": 0, "text": "UA 4629"])
            let fresh = try availableObservation(filled)
            XCTAssertFalse(try XCTUnwrap(fresh.split(separator: "\n").first).contains("document_epoch="))
            XCTAssertTrue(fresh.contains("UA 4629"))
            XCTAssertNotEqual(try snapshotID(first), try snapshotID(fresh))
            if scenario == "new_document" { XCTAssertTrue(fresh.contains("/result")) }
            if scenario == "pagination" {
                let cursor = try field("next_cursor", in: fresh)
                let source = try field("source_observation", in: fresh)
                let next = try await call(controller, "browser_read", ["cursor": cursor])
                XCTAssertEqual(try field("source_observation", in: next), source)
                XCTAssertNotNil(UUID(uuidString: source))
                XCTAssertEqual(try field("tab_handle", in: next), try field("tab_handle", in: fresh))
                XCTAssertFalse(try XCTUnwrap(next.split(separator: "\n").first).contains("document_epoch="))
                XCTAssertNotEqual(try snapshotID(next), try snapshotID(fresh))
                do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1]); XCTFail("Continuing the returned observation supersedes its first page") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            } else {
                _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1])
            }
            let counts = await backend.counts()
            XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, scenario == "pagination" ? 0 : 1)
            _ = await controller.shutdown()
        }
    }

    private func jsonObject(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func availableObservation(_ output: String) throws -> String {
        let result = try jsonObject(output)
        XCTAssertEqual(result["dispatched"] as? Bool, true)
        XCTAssertEqual(result["result_verified"] as? Bool, false)
        let current = try XCTUnwrap(result["current_observation"] as? [String: Any])
        XCTAssertEqual(current["status"] as? String, "available")
        XCTAssertEqual(current["view"] as? String, "overview")
        let text = try XCTUnwrap(current["text"] as? String)
        XCTAssertEqual(current["snapshot_id"] as? String, try snapshotID(text))
        return text
    }

    private func field(_ name: String, in text: String) throws -> String {
        let range = try XCTUnwrap(text.range(of: name + "="))
        return try XCTUnwrap(text[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first.map(String.init))
    }

    func testCapturedMutationPreflightRejectsUnsupportedTargetsWithoutConsumingSnapshot() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        let id = try snapshotID(read)
        let before = await backend.counts()
        for (tool, index, failure) in [
            ("browser_click", 0, EmbeddedBrowserTools.MutationEligibilityFailure.pressUnavailable),
            ("browser_fill", 1, EmbeddedBrowserTools.MutationEligibilityFailure.fillUnavailable),
        ] {
            var arguments: [String: Any] = ["snapshot_id": id, "element_index": index]
            if tool == "browser_fill" { arguments["text"] = "MUST_NOT_APPEAR" }
            let data = try JSONSerialization.data(withJSONObject: arguments)
            do {
                try await controller.preflightMutation(taskKey: "turn-a", tool: tool, arguments: data)
                XCTFail("Unsupported captured intent must be rejected before an approval is requested")
            } catch {
                XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, failure)
                XCTAssertTrue(error.localizedDescription.contains("No input was dispatched."))
                XCTAssertTrue(error.localizedDescription.contains("browser_read"))
                XCTAssertFalse(error.localizedDescription.contains("Chrome"))
            }
            do {
                _ = try await call(controller, tool, arguments)
                XCTFail("Direct execution must enforce the same captured eligibility")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, failure) }
        }
        let denied = await backend.counts()
        XCTAssertEqual(denied.presses, 0); XCTAssertEqual(denied.fills, 0)
        XCTAssertEqual(denied.observes, before.observes, "Unsupported intent must not reach backend preflight")
        let valid: [String: Any] = ["snapshot_id": id, "element_index": 1]
        let validData = try JSONSerialization.data(withJSONObject: valid)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: validData)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: validData)
        _ = try await call(controller, "browser_click", valid)
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: validData)
            XCTFail("An admitted mutation must consume its snapshot")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        do { _ = try await call(controller, "browser_click", valid); XCTFail("Replay must not dispatch") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let after = await backend.counts()
        XCTAssertEqual(after.presses, 1); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
    }

    func testMutationPreflightRetainsDisabledStaleAndTargetIdentityGuards() async throws {
        for condition in ["disabled", "stale", "replaced_target", "released"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            if condition == "disabled" { await backend.disableButton() }
            let read = try await call(controller, "browser_read", ["view": "all"])
            let arguments = try JSONSerialization.data(withJSONObject: ["snapshot_id": snapshotID(read), "element_index": 1])
            if condition == "stale" { _ = try await call(controller, "browser_read", ["view": "all"]) }
            if condition == "replaced_target" { await backend.replaceOwnedTarget() }
            if condition == "released" { _ = await controller.release(taskKey: "turn-a") }
            do {
                try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: arguments)
                XCTFail("Preflight must reject \(condition)")
            } catch {
                if condition == "disabled" {
                    XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, .disabledTarget)
                } else {
                    let expected: BrowserTabBrokerError = condition == "stale" ? .staleSnapshot
                        : condition == "replaced_target" ? .targetClosed : .handleMissing
                    XCTAssertEqual(error as? BrowserTabBrokerError, expected)
                }
            }
            let counts = await backend.counts()
            XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testMutationAfterApprovalStillRevalidatesReplacedOrDisabledPhysicalTarget() async throws {
        for change in ["replacement", "disabled", "released"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let read = try await call(controller, "browser_read", ["view": "all"])
            let arguments: [String: Any] = ["snapshot_id": try snapshotID(read), "element_index": 1]
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                                                   arguments: JSONSerialization.data(withJSONObject: arguments))
            if change == "replacement" { await backend.replaceButton() }
            if change == "disabled" { await backend.disableButton() }
            if change == "released" { _ = await controller.release(taskKey: "turn-a") }
            do { _ = try await call(controller, "browser_click", arguments); XCTFail("Approval cannot authorize \(change)") }
            catch {
                let expected: BrowserTabBrokerError = change == "replacement" ? .elementNotFound
                    : change == "disabled" ? .elementChanged : .handleMissing
                XCTAssertEqual(error as? BrowserTabBrokerError, expected)
            }
            let counts = await backend.counts()
            XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testBuiltInContinuationSchemasNameTheirOwnCursorTools() throws {
        for name in ["browser_read", "browser_tabs"] {
            let spec = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            let description = try XCTUnwrap(spec["description"] as? String)
            XCTAssertTrue(description.contains(name + "(cursor=next_cursor)"))
            XCTAssertTrue(description.contains("computer_v2_continue"))
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: ["cursor": UUID().uuidString]))
        }
    }

    func testOptionalBrowserReadArgumentsAdvertiseOmissionAndRejectEmptyStrings() throws {
        for name in ["browser_tabs", "browser_read"] {
            let specification = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            let schema = try XCTUnwrap(specification["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let required = try XCTUnwrap(schema["required"] as? [String])
            let cursor = try XCTUnwrap(properties["cursor"] as? [String: Any])
            XCTAssertEqual(cursor["type"] as? String, "string")
            XCTAssertEqual(cursor["minLength"] as? Int, 1)
            XCTAssertFalse(required.contains("cursor"))
            let guidance = try XCTUnwrap(cursor["description"] as? String)
            XCTAssertTrue(guidance.contains("Omit this field on the first page or a fresh read"))
            XCTAssertTrue(guidance.contains("exact nonempty next_cursor"))
            XCTAssertTrue(guidance.contains("current turn"))
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: [:]))
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: ["cursor": ""]))
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: ["cursor": UUID().uuidString]))
        }
        let read = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == "browser_read" })
        let schema = try XCTUnwrap(read["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let query = try XCTUnwrap(properties["query"] as? [String: Any])
        XCTAssertEqual(query["minLength"] as? Int, 1)
        XCTAssertNil(query["pattern"], "Existing whitespace-only queries retain their unfiltered-read semantics")
        XCTAssertTrue((query["description"] as? String)?.contains("Omit this field for an unfiltered read") == true)
        XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: "browser_read", arguments: ["query": ""]))
        XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: "browser_read", arguments: ["query": " \t\n"]))
    }

    func testOptionalBrowserReadArgumentsKeepNativeUTF8BoundsWithoutNormalizing() throws {
        for (name, field) in [("browser_tabs", "cursor"), ("browser_read", "cursor"), ("browser_read", "query")] {
            let boundary = String(repeating: "é", count: 1024)
            XCTAssertEqual(boundary.utf8.count, 2048)
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: boundary]))
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: boundary + "x"]))
            for value: Any in ["", NSNull(), 17] {
                XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: value]))
            }
        }
    }

    func testKnownServiceEntrypointGuidanceKeepsExplicitNavigationAndTargetChecks() throws {
        let definitions = EmbeddedBrowserTools.definitions()
        let inventory = try XCTUnwrap(definitions.first { $0["name"] as? String == "browser_tabs" })
        XCTAssertTrue((inventory["description"] as? String)?.contains("Empty inventory means no matching user tabs were listed, not denied access") == true)
        let scope = ComputerTaskScope(userPrompt: "Read the requested page on Wikipedia in the built-in browser.")
        XCTAssertEqual(scope.targetConfidence, .recognizedService)
        let entrypoint = try XCTUnwrap(URL(string: "https://en.wikipedia.org/"))
        XCTAssertNil(scope.siteViolation(url: entrypoint), "A user-named service does not require a literal URL in the prompt")
        XCTAssertNotNil(scope.siteViolation(url: try XCTUnwrap(URL(string: "https://unrelated.example/"))))
        for name in ["browser_open", "browser_navigate"] {
            let specification = try XCTUnwrap(definitions.first { $0["name"] as? String == name })
            let schema = try XCTUnwrap(specification["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let url = try XCTUnwrap(properties["url"] as? [String: Any])
            let guidance = try XCTUnwrap(url["description"] as? String)
            XCTAssertTrue(guidance.contains("Copy a supplied or observed URL exactly"))
            XCTAssertTrue(guidance.contains("Without a supplied URL"))
            XCTAssertTrue(guidance.contains("official homepage or sign-in entrypoint, then observed controls"))
            XCTAssertTrue(guidance.contains("Never invent deep links, account paths, message IDs"))
            XCTAssertEqual(schema["required"] as? [String], ["url"])
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: ["url": entrypoint.absoluteString]))
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: [:]))
        }
        let open = try XCTUnwrap(definitions.first { $0["name"] as? String == "browser_open" })
        XCTAssertTrue((open["description"] as? String)?.contains("sharing its signed-in profile") == true)
        XCTAssertTrue((open["description"] as? String)?.contains("Preserve any supplied URL exactly") == true)
        XCTAssertTrue(EmbeddedBrowserTools.requiresApproval(tool: "browser_open"))
    }

    private func call(_ controller: EmbeddedBrowserToolController, _ tool: String, _ arguments: [String: Any] = [:], key: String = "turn-a", scope: ComputerTaskScope? = nil) async throws -> String {
        try await controller.execute(taskKey: key, tool: tool, arguments: JSONSerialization.data(withJSONObject: arguments), scope: scope)
    }

    func testContractRejectsUnknownArgumentsGuessedURLsAndBoolIndicesBeforeDispatch() throws {
        for (tool, arguments) in [
            ("browser_open", ["url":"javascript:alert(1)"]),
            ("browser_open", ["url":"https://user:password@example.com"]),
            ("browser_bind", ["tab_id":"invented"]),
            ("browser_click", ["snapshot_id":UUID().uuidString,"element_index":true]),
            ("browser_wait", ["timeout_ms":10_001]),
            ("browser_read", ["view":"everything"]),
            ("browser_close", ["tab_id":UUID().uuidString])
        ] as [(String,[String:Any])] { XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: tool, arguments: arguments)) }
        XCTAssertEqual(Set(EmbeddedBrowserTools.definitions().compactMap { $0["name"] as? String }), EmbeddedBrowserTools.names)
        XCTAssertFalse(EmbeddedBrowserTools.requiresApproval(tool: "browser_read"))
        XCTAssertTrue(EmbeddedBrowserTools.requiresApproval(tool: "browser_fill"))
        let descriptions = Dictionary(uniqueKeysWithValues: EmbeddedBrowserTools.definitions().map {
            ($0["name"] as! String, $0["description"] as! String)
        })
        XCTAssertTrue(descriptions["browser_click"]?.contains("actions=[\"AXPress\"]") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("Recheck the current row's label/action; indices change") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("If dispatched input leaves the page unchanged, wait/read instead of clicking again") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("After stale errors, browser_read before input") == true)
        XCTAssertTrue(descriptions["browser_read"]?.contains("actions=[] is read-only") == true)
        XCTAssertTrue(descriptions["browser_fill"]?.contains("enabled=true and settable=true") == true)
    }

    func testFlightReadFillClickAndResultRequireFreshSnapshotAndNeverReplay() async throws {
        for name in ["browser_fill", "browser_click"] {
            let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let snapshot = try XCTUnwrap(properties["snapshot_id"] as? [String: Any])
            XCTAssertEqual(snapshot["type"] as? String, "string")
            XCTAssertTrue((snapshot["description"] as? String)?.contains("never batch another input") == true)
        }
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let first = try await call(controller,"browser_read")
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill",
            arguments: JSONSerialization.data(withJSONObject: ["snapshot_id": snapshotID(first), "element_index": 0, "text": "UA 123"]))
        XCTAssertTrue(first.contains("Flight number"))
        let firstID = try snapshotID(first)
        _ = try await call(controller,"browser_fill",["snapshot_id":firstID,"element_index":0,"text":"UA 123"])
        do { _ = try await call(controller,"browser_fill",["snapshot_id":firstID,"element_index":0,"text":"UA 456"]); XCTFail("Consumed snapshot replay must fail") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let second = try await call(controller,"browser_read")
        _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(second),"element_index":1])
        let result = try await call(controller,"browser_read",["view":"content"])
        XCTAssertTrue(result.contains("UA 123 departs at 18:45"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills,1); XCTAssertEqual(counts.presses,1)
        let issues = await controller.release(taskKey:"turn-a")
        XCTAssertTrue(issues.isEmpty)
        let end = await backend.counts()
        XCTAssertEqual(end.closes,1)
    }

    func testObservedBuiltInLinkUsesBrowserClickAndConsumesOneSnapshot() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setLink("http://localhost:8123/details")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let read = try await call(controller,"browser_read",["view":"overview"])
        let linkLine = try XCTUnwrap(read.split(separator:"\n").first { $0.contains("label=\"Destination\"") })
        XCTAssertTrue(linkLine.contains("follow_link=true"))
        let index = try XCTUnwrap(Int(linkLine.dropFirst().prefix { $0.isNumber }))
        let id = try snapshotID(read)
        let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == "browser_read" })
        XCTAssertTrue((definition["description"] as? String)?.contains("Use browser_click for observed enabled links (including follow_link=true)") == true)
        _ = try await call(controller,"browser_click",["snapshot_id":id,"element_index":index])
        do { _ = try await call(controller,"browser_click",["snapshot_id":id,"element_index":index]); XCTFail("Consumed link snapshot cannot replay input") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,1)
        XCTAssertEqual(counts.fills,0)
        let cleanup = await controller.release(taskKey:"turn-a")
        XCTAssertTrue(cleanup.isEmpty)
    }

    func testHumanTabLeaseRejectsOtherTaskAndCleanupPreservesExistingTab() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let human = await backend.humanID
        _ = try await call(controller,"browser_tabs")
        _ = try await call(controller,"browser_bind",["tab_id":human])
        _ = try await call(controller,"browser_tabs",key:"turn-b")
        do { _ = try await call(controller,"browser_bind",["tab_id":human],key:"turn-b"); XCTFail("Two task writers must not lease one tab") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError,.operationInProgress) }
        _ = await controller.release(taskKey:"turn-a")
        _ = try await call(controller,"browser_bind",["tab_id":human],key:"turn-b")
        _ = try await call(controller,"browser_close",key:"turn-b")
        let counts = await backend.counts()
        XCTAssertEqual(counts.closes,0)
        let available = try await backend.humanTargets()
        XCTAssertEqual(available.count,1)
    }

    func testSwitchingTargetsClosesCreatedTabAndRetainsTurnLifetime() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/first"])
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/second"])
        _ = try await call(controller,"browser_read")
        _ = try await call(controller,"browser_close")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/third"])
        _ = await controller.shutdown()
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,3); XCTAssertEqual(counts.closes,3)
    }

    func testBindingAlreadyBoundCreatedTabPreservesItsOwnedPage() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let opened = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(opened.utf8)) as? [String:Any])
        let id = try XCTUnwrap(value["tab_id"] as? String)
        XCTAssertEqual(value["bound"] as? Bool, true)
        XCTAssertEqual(value["already_bound"] as? Bool, false, "This reports no prior binding; the new page is now bound")
        let read = try await call(controller,"browser_read")
        let before = await backend.counts()
        let rebound = try await call(controller,"browser_bind",["tab_id":id])
        let bound = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rebound.utf8)) as? [String: Any])
        XCTAssertEqual(bound["bound"] as? Bool, true)
        XCTAssertEqual(bound["already_bound"] as? Bool, true)
        XCTAssertEqual(bound["ownership"] as? String, "task_created")
        XCTAssertEqual(bound["tab_handle"] as? String, value["tab_handle"] as? String)
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,1); XCTAssertEqual(counts.closes,0); XCTAssertEqual(counts.navigations,0)
        XCTAssertEqual(counts.observes, before.observes, "Idempotent bind must not observe or replace the current snapshot")
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
            arguments: JSONSerialization.data(withJSONObject: ["snapshot_id": snapshotID(read), "element_index": 1]))
        let after = await backend.counts()
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
        let end = await backend.counts()
        XCTAssertEqual(end.closes,1)
    }

    func testOpenedTabReceiptCannotBindUnknownForeignRetiredReplacedOrOffScopeTarget() async throws {
        for scenario in ["unknown", "foreign", "foreign_inventory", "retired", "released", "replaced", "redirected", "changed_scope"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Check http://localhost:8123/flight only.")
            let opened = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(opened.utf8)) as? [String: Any])
            let id = try XCTUnwrap(object["tab_id"] as? String)
            if scenario == "foreign_inventory" { _ = try await call(controller, "browser_tabs", key: "turn-b", scope: scope) }
            if scenario == "retired" {
                await backend.failNextClose()
                do { _ = try await call(controller, "browser_close", scope: scope); XCTFail("Fixture close must be unconfirmed") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Task-tab cleanup could not be confirmed.")) }
            }
            if scenario == "released" { _ = await controller.release(taskKey: "turn-a") }
            if scenario == "replaced" { await backend.replaceOwnedTarget() }
            if scenario == "redirected" { await backend.redirectOwnedTarget(to: URL(string: "https://unrelated.example/")!) }
            let before = await backend.counts()
            let key = scenario.hasPrefix("foreign") ? "turn-b" : "turn-a"
            let suppliedScope = scenario == "changed_scope" ? nil : scope
            do {
                _ = try await call(controller, "browser_bind", ["tab_id": scenario == "unknown" ? UUID().uuidString : id], key: key, scope: suppliedScope)
                XCTFail("The open receipt must not authorize \(scenario)")
            } catch {
                if scenario == "foreign_inventory" { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
                else if scenario == "released" { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
                else if scenario == "replaced" { XCTAssertEqual(error as? BrowserTabBrokerError, .targetClosed) }
                else if let failure = error as? BrowserTabBrokerError, case .invalidRead = failure { /* Exact observed target or scope denied. */ }
                else { XCTFail("Unexpected error for \(scenario): \(error)") }
            }
            let after = await backend.counts()
            XCTAssertEqual(after.creates, 1); XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            XCTAssertEqual(after.observes, before.observes); XCTAssertEqual(after.navigations, 0)
            XCTAssertEqual(after.closes, before.closes, "A denied bind cannot retire any current page")
            _ = await controller.shutdown()
        }
    }

    func testFieldValueContractAndTransportPreservePrefixesSpacesAndPunctuation() async throws {
        let specification = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == "browser_fill" })
        let schema = try XCTUnwrap(specification["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let text = try XCTUnwrap(properties["text"] as? [String: Any])
        let description = try XCTUnwrap(specification["description"] as? String)
        XCTAssertEqual(text["type"] as? String, "string")
        XCTAssertTrue((text["description"] as? String)?.contains("complete requested field value verbatim") == true)
        XCTAssertTrue((text["description"] as? String)?.contains("including prefixes, spaces and punctuation") == true)
        XCTAssertTrue((text["description"] as? String)?.contains("Do not infer a shorter identifier format") == true)
        XCTAssertTrue((text["description"] as? String)?.contains("Transform only when the task explicitly requires it") == true)
        XCTAssertTrue(description.contains("compare its field value with the complete requested value before submitting"))
        // This checks the actual API schema boundary, not model adherence.
        let provider = APIProviderDefinition(id: "field-fixture", name: "Field Fixture",
            baseURL: URL(string: "https://example.invalid/v1")!, wireAPI: .chatCompletions,
            models: [.init(id: "fixture-model", name: "Fixture")])
        let instructions = ComputaAgentInstructions.developerInstructions(embeddedBrowserTools: true)
        let prepared = try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: [
            "model": APIProviderCatalog.appModelID(providerID: provider.id, modelID: provider.models[0].id),
            "instructions": instructions, "input": [["role": "user", "content": "Fill the requested reference."]],
            "tools": [["type": "function", "name": "browser_fill", "description": description, "parameters": schema]],
            "store": false, "stream": true,
        ]), selection: .init(provider: provider, model: provider.models[0]), threadID: UUID().uuidString,
            capsules: APIReasoningCapsules(key: Data(repeating: 7, count: 32)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let functions = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let emitted = try XCTUnwrap(functions.first?["function"] as? [String: Any])
        XCTAssertEqual(emitted["parameters"] as? NSDictionary, schema as NSDictionary)
        XCTAssertTrue((emitted["description"] as? String)?.hasSuffix(description) == true)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.first?["content"] as? String, instructions)
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read")
        let value = "REF 0007-A_1 / return"
        _ = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(read), "element_index": 0, "text": value])
        let actualValue = await backend.fieldValue()
        XCTAssertEqual(actualValue, value)
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0)
        _ = await controller.shutdown()
    }

    func testReleaseDuringOpeningClosesLateTargetWithoutPublishingBinding() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        await backend.holdNextCreate()
        let operation = Task { try await self.call(controller,"browser_open",["url":"http://localhost:8123/flight"]) }
        await backend.waitUntilCreateHeld()
        let initial = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertFalse(initial.isSettled)
        XCTAssertTrue(initial.pendingOperation)
        XCTAssertTrue(initial.failures.contains(.operationPending))
        XCTAssertTrue(initial.targets.isEmpty, "An unresolved opening is not an invented owned-target receipt")
        await backend.resumeCreate()
        do { _ = try await operation.value; XCTFail("Canceled opening must not bind") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.handleMissing) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,1); XCTAssertEqual(counts.closes,1); XCTAssertEqual(counts.observes,0)
        let repeated = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertEqual(repeated, initial, "Later absence cannot replace the original pending observation with successful closure")
    }

    func testFailedOwnedBindWithConfirmedCloseAllowsTheNextOpen() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.failObservations([.browserUnavailable("Synthetic bind read failed")])
        do { _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"]); XCTFail("Binding must fail") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Synthetic bind read failed")) }
        let failed = await backend.counts()
        XCTAssertEqual(failed.creates, 1); XCTAssertEqual(failed.closes, 1); XCTAssertEqual(failed.closeAttempts, 1)
        let opened = try jsonObject(await call(controller, "browser_open", ["url": "http://localhost:8123/result"]))
        XCTAssertEqual(opened["bound"] as? Bool, true)
        let read = try await call(controller, "browser_read")
        XCTAssertTrue(read.contains("/result"))
        let reopened = await backend.counts()
        XCTAssertEqual(reopened.creates, 2); XCTAssertEqual(reopened.closes, 1)
        XCTAssertEqual(reopened.closeAttempts, 1, "Confirmed failed-open disposal must not be attempted a second time")
        let report = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertTrue(report.isSettled)
        XCTAssertTrue(report.targets.allSatisfy(\.closed))
        _ = await controller.shutdown()
    }

    func testFailedOwnedBindCloseRemainsReservedAndCleanupIsRetriedWithoutCreatingAnotherTab() async throws {
        for retryFails in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.failObservations([.browserUnavailable("Synthetic bind read failed")])
            await backend.failNextClose()
            do { _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"]); XCTFail("Binding must fail") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Synthetic bind read failed")) }
            let inventory = try jsonObject(await call(controller, "browser_tabs", key: "turn-b"))
            let rows = try XCTUnwrap(inventory["tabs"] as? [[String: Any]])
            let reserved = try XCTUnwrap(rows.first { $0["availability"] as? String == "busy" })
            let targetID = try XCTUnwrap(reserved["tab_id"] as? String)
            do {
                _ = try await call(controller, "browser_bind", ["tab_id": targetID], key: "turn-b")
                XCTFail("An unconfirmed created target cannot become another task's borrowed tab")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
            if retryFails { await backend.failNextClose() }
            do {
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/result"])
                XCTAssertFalse(retryFails, "Another failed close must block creation")
            } catch {
                XCTAssertTrue(retryFails)
                XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Previous task-tab cleanup could not be confirmed."))
            }
            let retried = await backend.counts()
            XCTAssertEqual(retried.closeAttempts, 2, "The retained cleanup target must be retried once")
            XCTAssertEqual(retried.creates, retryFails ? 1 : 2)
            XCTAssertEqual(retried.closes, retryFails ? 0 : 1)
            if retryFails {
                for key in ["turn-a", "turn-b"] {
                    let inventory = try jsonObject(await call(controller, "browser_tabs", key: key))
                    let rows = try XCTUnwrap(inventory["tabs"] as? [[String: Any]])
                    XCTAssertEqual(rows.first { $0["tab_id"] as? String == targetID }?["availability"] as? String, "busy")
                    do { _ = try await call(controller, "browser_bind", ["tab_id": targetID], key: key); XCTFail("A failed cleanup retry must not expose its surviving target") }
                    catch { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
                }
            }
            let report = await controller.releaseReport(taskKey: "turn-a")
            if retryFails {
                XCTAssertFalse(report.isSettled)
                XCTAssertTrue(report.failures.contains(.ownedTargetCloseFailed))
                XCTAssertEqual(report.targets.map(\.closed), [false], "Unconfirmed disposal must remain in the cleanup report")
                let inventory = try jsonObject(await call(controller, "browser_tabs", key: "turn-b"))
                let rows = try XCTUnwrap(inventory["tabs"] as? [[String: Any]])
                XCTAssertEqual(rows.first { $0["tab_id"] as? String == targetID }?["availability"] as? String, "busy",
                               "Removing the original context cannot release physical-disposal uncertainty")
                do { _ = try await call(controller, "browser_bind", ["tab_id": targetID], key: "turn-b"); XCTFail("Retired context quarantine remains binding") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
            } else { XCTAssertTrue(report.isSettled) }
            _ = await controller.shutdown()
        }
    }

    func testLateFailedOpenDisposalRemainsQuarantinedAfterItsContextWasRemoved() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.holdNextCreate()
        let pending = Task { try await self.call(controller, "browser_open", ["url": "http://localhost:8123/flight"]) }
        await backend.waitUntilCreateHeld()
        let original = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertTrue(original.pendingOperation); XCTAssertTrue(original.targets.isEmpty)
        await backend.failNextClose()
        await backend.resumeCreate()
        do { _ = try await pending.value; XCTFail("A retired opening cannot publish a binding") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
        let inventory = try jsonObject(await call(controller, "browser_tabs", key: "turn-b"))
        let rows = try XCTUnwrap(inventory["tabs"] as? [[String: Any]])
        let target = try XCTUnwrap(rows.first { $0["availability"] as? String == "busy" })
        let id = try XCTUnwrap(target["tab_id"] as? String)
        do { _ = try await call(controller, "browser_bind", ["tab_id": id], key: "turn-b"); XCTFail("Late failed close cannot expose an orphaned owned target") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
        let repeated = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertEqual(repeated, original, "Quarantine does not rewrite immutable cleanup evidence")
        let counts = await backend.counts()
        XCTAssertEqual(counts.closeAttempts, 1); XCTAssertEqual(counts.closes, 0)
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = await controller.shutdown()
    }

    func testQuarantineDoesNotAttachToANewTargetIncarnation() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.failNextClose()
        do { _ = try await call(controller, "browser_close"); XCTFail("Close must remain unconfirmed") } catch { }
        let original = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertFalse(original.isSettled)
        await backend.replaceOwnedTargetWithHumanIncarnation()
        let inventory = try jsonObject(await call(controller, "browser_tabs", key: "turn-b"))
        let rows = try XCTUnwrap(inventory["tabs"] as? [[String: Any]])
        let replacement = try XCTUnwrap(rows.first { $0["title"] as? String == "Replacement user tab" })
        XCTAssertEqual(replacement["availability"] as? String, "available")
        let id = try XCTUnwrap(replacement["tab_id"] as? String)
        let bound = try jsonObject(await call(controller, "browser_bind", ["tab_id": id], key: "turn-b"))
        XCTAssertEqual(bound["ownership"] as? String, "user_existing")
        let released = await controller.releaseReport(taskKey: "turn-b")
        XCTAssertTrue(released.isSettled); XCTAssertTrue(released.userBindingReleased)
        let repeated = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertEqual(repeated, original)
        let counts = await backend.counts()
        XCTAssertEqual(counts.closeAttempts, 1); XCTAssertEqual(counts.closes, 0,
            "An old target/token quarantine cannot close or reserve a different incarnation")
        _ = await controller.shutdown()
    }

    func testFailedBorrowedBindRetiresOnlyItsLocalLeaseAndNeverClosesTheUserTab() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_tabs")
        let targetID = await backend.humanID
        await backend.failObservations([.browserUnavailable("Synthetic bind read failed")])
        do { _ = try await call(controller, "browser_bind", ["tab_id": targetID]); XCTFail("Binding must fail") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Synthetic bind read failed")) }
        let reopened = try jsonObject(await call(controller, "browser_bind", ["tab_id": targetID]))
        XCTAssertEqual(reopened["bound"] as? Bool, true)
        XCTAssertEqual(reopened["ownership"] as? String, "user_existing")
        _ = try await call(controller, "browser_read")
        let report = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertTrue(report.isSettled); XCTAssertTrue(report.userBindingReleased); XCTAssertTrue(report.targets.isEmpty)
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates, 0); XCTAssertEqual(counts.closes, 0); XCTAssertEqual(counts.closeAttempts, 0)
        _ = await controller.shutdown()
    }

    func testCancelledOrReleasedBindCleanupCannotClearTheNextContext() async throws {
        for cancelled in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.holdNextRead()
            let pending = Task { try await self.call(controller, "browser_open", ["url": "http://localhost:8123/flight"]) }
            await backend.waitUntilObservationHeld()
            var released: EmbeddedBrowserCleanupReport?
            let nextKey = cancelled ? "turn-a" : "turn-b"
            if cancelled { pending.cancel() }
            else {
                released = await controller.releaseReport(taskKey: "turn-a")
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/result"], key: nextKey)
            }
            await backend.resumeObservation()
            do { _ = try await pending.value; XCTFail("Retired binding cannot publish") }
            catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error is BrowserTabBrokerError) }
            }
            if cancelled { _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/result"], key: nextKey) }
            let current = try await call(controller, "browser_read", key: nextKey)
            XCTAssertTrue(current.contains("/result"))
            let counts = await backend.counts()
            XCTAssertEqual(counts.creates, 2); XCTAssertEqual(counts.closes, 1)
            XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            if let released {
                XCTAssertFalse(released.isSettled); XCTAssertTrue(released.pendingOperation)
                let repeated = await controller.releaseReport(taskKey: "turn-a")
                XCTAssertEqual(repeated, released, "Late cleanup cannot rewrite the original pending release as a success")
            }
            _ = await controller.shutdown()
        }
    }

    func testFailedExplicitCloseRemainsUnconfirmedAtTurnEndWithoutReplayingClose() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.failNextClose()
        do { _ = try await call(controller, "browser_close"); XCTFail("Physical failure must not return tool success") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("Task-tab cleanup could not be confirmed.")) }
        let report = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertFalse(report.isSettled)
        XCTAssertFalse(report.pendingOperation)
        XCTAssertEqual(report.targets.map(\.trigger), [.explicit])
        XCTAssertEqual(report.targets.map(\.closed), [false])
        XCTAssertTrue(report.failures.contains(.ownedTargetCloseFailed))
        let repeated = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertEqual(repeated, report)
        let counts = await backend.counts()
        XCTAssertEqual(counts.closes, 0, "Turn-end bookkeeping cannot replay the failed explicit close")
        _ = await controller.shutdown()
    }

    func testRetiredKeyCannotRegainAuthorityAfterDetailedReportEviction() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], key: "000-old")
        _ = await controller.releaseReport(taskKey: "000-old")
        for index in 0..<256 { _ = await controller.releaseReport(taskKey: "later-\(index)") }
        do {
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/MUST_NOT_OPEN"], key: "000-old")
            XCTFail("Detail eviction must never restore a retired task key")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
        let unavailable = await controller.releaseReport(taskKey: "000-old")
        XCTAssertFalse(unavailable.isSettled)
        XCTAssertTrue(unavailable.failures.contains(.historyLimit))
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates, 1)
        XCTAssertEqual(counts.closes, 1)
        _ = await controller.shutdown()
    }

    func testReleaseDuringMutationRevokesPermitBeforeLateDispatch() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let read = try await call(controller,"browser_read")
        await backend.holdNextMutation()
        let id = try snapshotID(read)
        let operation = Task { try await self.call(controller,"browser_click",["snapshot_id":id,"element_index":1]) }
        await backend.waitUntilMutationHeld()
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                arguments: JSONSerialization.data(withJSONObject: ["snapshot_id": id, "element_index": 1]))
            XCTFail("Preflight cannot overlap an admitted mutation")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
        _ = await controller.release(taskKey:"turn-a")
        await backend.resumeMutation()
        do { _ = try await operation.value; XCTFail("Revoked mutation must not dispatch") } catch { }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.closes,1)
    }

    func testNavigationRetiresOldSnapshotAndWaitNeverCreatesOrMutates() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let read = try await call(controller,"browser_read")
        _ = try await call(controller,"browser_navigate",["url":"http://localhost:8123/other"])
        do { _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(read),"element_index":1]); XCTFail("Navigation retires old controls") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let wait = try await call(controller,"browser_wait",["text":"No such result","timeout_ms":1])
        XCTAssertTrue(wait.contains("\"matched\":false"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.navigations,1); XCTAssertEqual(counts.creates,1); XCTAssertEqual(counts.presses,0)
        _ = await controller.shutdown()
    }

    func testInventoryPagesAreBoundedAndCursorIsScopedToCurrentTurnAndInventory() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        await backend.addLongInventory()
        var page = try await call(controller,"browser_tabs")
        var identifiers = Set<String>(), firstCursor: String?
        while true {
            XCTAssertLessThanOrEqual(page.utf8.count,8_192)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(page.utf8)) as? [String:Any])
            let rows = try XCTUnwrap(value["tabs"] as? [[String:Any]])
            identifiers.formUnion(rows.compactMap { $0["tab_id"] as? String })
            guard let cursor = value["next_cursor"] as? String else { break }
            firstCursor = firstCursor ?? cursor
            do { _ = try await call(controller,"browser_tabs",["cursor":cursor],key:"turn-b"); XCTFail("Foreign inventory cursor must fail") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
            page = try await call(controller,"browser_tabs",["cursor":cursor])
        }
        XCTAssertEqual(identifiers.count,14)
        _ = try await call(controller,"browser_tabs")
        if let firstCursor {
            do { _ = try await call(controller,"browser_tabs",["cursor":firstCursor]); XCTFail("Replaced inventory cursor must fail") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        }
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,0); XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.fills,0)
        _ = await controller.shutdown()
    }

    func testCombiningAndControlTitlesAlwaysIssueRowsWithinFiniteBoundedInventory() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let combining = "A" + String(repeating:"\u{0301}",count:6_000)
        XCTAssertEqual(combining.count,1,"The fixture is one oversized grapheme, not many ordinary characters")
        let controls = String(repeating:"\u{0000}",count:6_000)
        let url = try XCTUnwrap(URL(string:"http://localhost:8123/" + String(repeating:"/",count:2_000)))
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count,2_048)
        let combiningID = await backend.addInventoryTarget(title:combining,url:url)
        let otherCombiningID = await backend.addInventoryTarget(title:combining,url:url)
        let controlID = await backend.addInventoryTarget(title:controls,url:url)
        let humanID = await backend.humanID
        let expected = Set([combiningID,otherCombiningID,controlID,humanID])
        var issued = Set<String>(), pages = 0, firstPage = true
        var page = try await call(controller,"browser_tabs")
        while true {
            pages += 1
            XCTAssertLessThanOrEqual(pages,expected.count,"Every nonempty page must advance inventory")
            XCTAssertLessThanOrEqual(page.utf8.count,8_192)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(page.utf8)) as? [String:Any])
            let rows = try XCTUnwrap(value["tabs"] as? [[String:Any]])
            XCTAssertFalse(rows.isEmpty,"An oversized grapheme must not trap pagination at an empty page")
            XCTAssertEqual(value["returned"] as? Int,rows.count)
            for row in rows {
                let id = try XCTUnwrap(row["tab_id"] as? String)
                XCTAssertTrue(issued.insert(id).inserted,"Each retained inventory target is returned exactly once")
                let title = try XCTUnwrap(row["title"] as? String)
                XCTAssertLessThanOrEqual(title.utf8.count,256)
                if id == combiningID || id == otherCombiningID {
                    XCTAssertEqual(title,"A" + String(repeating:"\u{0301}",count:127))
                    XCTAssertEqual(row["title_truncated"] as? Bool,true)
                } else if id == controlID {
                    XCTAssertEqual(title,String(repeating:"\u{0000}",count:256))
                    XCTAssertEqual(row["title_truncated"] as? Bool,true)
                }
            }
            if firstPage {
                let unissued = try XCTUnwrap(expected.subtracting(issued).first)
                do { _ = try await call(controller,"browser_bind",["tab_id":unissued]); XCTFail("An unissued inventory target cannot be guessed") }
                catch { XCTAssertTrue((error as? BrowserTabBrokerError)?.errorDescription?.contains("List browser_tabs") == true) }
                firstPage = false
            }
            guard let cursor = value["next_cursor"] as? String else { break }
            guard pages < expected.count else { XCTFail("Inventory did not finish within its target count"); break }
            page = try await call(controller,"browser_tabs",["cursor":cursor])
        }
        XCTAssertEqual(issued,expected)
        _ = try await call(controller,"browser_bind",["tab_id":combiningID])
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,0); XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.fills,0)
        XCTAssertEqual(counts.observes,1,"Only binding the returned target can inspect its document")
        _ = await controller.shutdown()
    }

    func testHostScopeRejectsWrongOriginBeforeCreationOrInputAndRetainsOriginalTab() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let scope = ComputerTaskScope(userPrompt:"Use only http://localhost:8123/flight to check my flight.")
        do { _ = try await call(controller,"browser_open",["url":"https://example.com/flight"],scope:scope); XCTFail("Wrong destination must fail before creation") } catch { }
        let initial = await backend.counts()
        XCTAssertEqual(initial.creates,0)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:scope)
        let read = try await call(controller,"browser_read",scope:scope)
        do { _ = try await call(controller,"browser_navigate",["url":"http://localhost:8124/other"],scope:scope); XCTFail("Wrong port is outside exact user origin") } catch { }
        do { _ = try await call(controller,"browser_open",["url":"https://example.com/other"],scope:scope); XCTFail("Rejected open must not close current tab") } catch { }
        _ = try await call(controller,"browser_read",scope:scope)
        let during = await backend.counts()
        XCTAssertEqual(during.creates,1); XCTAssertEqual(during.closes,0); XCTAssertEqual(during.navigations,0); XCTAssertEqual(during.presses,0); XCTAssertEqual(during.fills,0)
        XCTAssertFalse(read.isEmpty)
        _ = await controller.shutdown()
    }

    func testRedirectedDocumentCannotPublishOrReuseOldActionUnderHostScope() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let scope = ComputerTaskScope(userPrompt:"Check http://localhost:8123/flight only.")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:scope)
        let read = try await call(controller,"browser_read",scope:scope)
        await backend.redirectOnNextObserve(to:URL(string:"https://unrelated.example/other")!)
        do { _ = try await call(controller,"browser_read",scope:scope); XCTFail("Unrelated redirected content must not be published") } catch { }
        do { _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(read),"element_index":1],scope:scope); XCTFail("Redirected tab cannot reuse old action") } catch { }
        do { _ = try await call(controller,"browser_fill",["snapshot_id":try snapshotID(read),"element_index":0,"text":"MUST_NOT_APPEAR"],scope:scope); XCTFail("Redirected tab cannot fill") } catch { }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.fills,0)
        _ = await controller.shutdown()
    }

    func testExplicitChromeRestrictionDoesNotRejectGenericBackgroundBrowser() async throws {
        let chrome = ComputerTaskScope(userPrompt:"Use background Chrome only. Check my flight.")
        XCTAssertNotNil(chrome.embeddedBrowserToolViolation())
        let generic = ComputerTaskScope(userPrompt:"Use background browser only. Check my flight.")
        XCTAssertNil(generic.embeddedBrowserToolViolation())
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        do { _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:chrome); XCTFail("Explicit Chrome restriction must not admit another browser") } catch { }
        let before = await backend.counts()
        XCTAssertEqual(before.creates,0)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:generic)
        _ = await controller.shutdown()
    }

    func testObservedOffsiteLinkIsRejectedBeforePressUnderHostScope() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let scope = ComputerTaskScope(userPrompt:"Read http://localhost:8123/flight only.")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:scope)
        await backend.setLink("https://unrelated.example/other")
        let read = try await call(controller,"browser_read",["view":"links"],scope:scope)
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                arguments: JSONSerialization.data(withJSONObject: ["snapshot_id": snapshotID(read), "element_index": 0]),
                scope: scope)
            XCTFail("Known offsite destination must fail before approval")
        } catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        do { _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(read),"element_index":0],scope:scope); XCTFail("Known offsite destination must fail before press") } catch { }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,0)
        _ = await controller.shutdown()
    }

    func testPopupOnlyLinkRetainsExactDestinationButRejectsPressBeforeInput() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let destination = "http://localhost:8123/sign-in?return=%2Fmail%2F&literal=A-B"
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.setLink(destination, pressUnsupported: true)
        let read = try await call(controller, "browser_read", ["view": "links"])
        let row = try XCTUnwrap(read.split(separator: "\n").first { $0.hasPrefix("#0 ") }).description
        XCTAssertTrue(row.contains("semantic_role=\"link\""))
        XCTAssertTrue(row.contains("href=\"\(destination)\""))
        XCTAssertTrue(row.contains("enabled=true")); XCTAssertTrue(row.contains("actions=[]"))
        XCTAssertFalse(row.contains("follow_link=true"))
        let arguments: [String: Any] = ["snapshot_id": try snapshotID(read), "element_index": 0]
        for preflight in [true, false] {
            do {
                if preflight {
                    try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                        arguments: JSONSerialization.data(withJSONObject: arguments))
                } else { _ = try await call(controller, "browser_click", arguments) }
                XCTFail("A readable popup destination does not grant press authority")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, .pressUnavailable) }
        }
        let before = await backend.counts()
        XCTAssertEqual(before.presses, 0); XCTAssertEqual(before.navigations, 0)
        _ = try await call(controller, "browser_navigate", ["url": destination])
        let after = await backend.counts()
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.navigations, 1)
        _ = await controller.shutdown()
    }

    private func snapshotID(_ text: String) throws -> String {
        let prefix = "AXSNAPSHOT id="
        guard let start = text.range(of:prefix), let id = text[start.upperBound...].split(separator:" ").first, UUID(uuidString:String(id)) != nil else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        return String(id)
    }
}

private actor EmbeddedBrowserFixtureBackend: EmbeddedBrowserControlBackend {
    struct Counts: Sendable { var creates=0,closes=0,closeAttempts=0,observes=0,presses=0,fills=0,navigations=0 }
    let humanID = UUID().uuidString
    private var targets = [String: BrowserTarget](), owned = Set<String>(), stats = Counts()
    private var generation = UUID().uuidString, field = "", result = ""
    private var observationSourceName = "computa_webkit_dom"
    private var semanticReadiness: BrowserDocumentObservation.SemanticReadiness?, emptyObservation = false
    private var buttonID: Int64 = 2, buttonDisabled = false
    private var pendingRedirect: URL?
    private var link: String?, linkPressUnsupported = false
    private var holdCreate=false, createHeld=false, createContinuation: CheckedContinuation<Void,Never>?
    private var holdMutation=false, mutationHeld=false, mutationContinuation: CheckedContinuation<Void,Never>?
    private var shouldFailClose = false
    private var createWaiters=[CheckedContinuation<Void,Never>](), mutationWaiters=[CheckedContinuation<Void,Never>]()
    private var afterInputScenario: String?, postInputPending = false, manyControls = false
    private var protectedTargets = Set<String>()
    private var observationHeld = false, observationContinuation: CheckedContinuation<Void, Never>?
    private var observationWaiters = [CheckedContinuation<Void, Never>]()
    private var observationFailures = [BrowserTabBrokerError](), failureRedirect: URL?, replaceOnFailure = false, holdRead = false

    init() { targets[humanID] = BrowserTarget(targetID:humanID,instanceToken:humanID,title:"Flights",url:URL(string:"http://localhost:8123/flight")!,webSocketURL:nil) }
    func counts() -> Counts { stats }
    func fieldValue() -> String { field }
    func setObservedResult(_ text: String) { result = text }
    func setObservationSourceName(_ name: String) { observationSourceName = name }
    func setSemanticReadiness(_ value: BrowserDocumentObservation.SemanticReadiness?, empty: Bool = false) {
        semanticReadiness = value; emptyObservation = empty
    }
    func failNextClose() { shouldFailClose = true }
    func addInventoryTarget(title:String,url:URL) -> String {
        let id=UUID().uuidString
        targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:title,url:url,webSocketURL:nil)
        return id
    }
    func addLongInventory() {
        for index in 0..<12 {
            let id=UUID().uuidString
            targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:String(repeating:"🙂",count:200),
                url:URL(string:"http://localhost:8123/\(index)?q=" + String(repeating:"x",count:1_800))!,webSocketURL:nil)
        }
        let id=UUID().uuidString
        targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:"Oversized URL",
            url:URL(string:"http://localhost:8123/?q=" + String(repeating:"x",count:3_000))!,webSocketURL:nil)
    }
    func humanTargets() async throws -> [BrowserTarget] { Array(targets.values) }
    func createTarget(url:URL) async throws -> BrowserTarget {
        stats.creates += 1
        let id=UUID().uuidString, target=BrowserTarget(targetID:id,instanceToken:id,title:"Flight fixture",url:url,webSocketURL:nil)
        targets[id]=target; owned.insert(id)
        if holdCreate {
            createHeld=true; createWaiters.forEach { $0.resume() }; createWaiters.removeAll()
            await withCheckedContinuation { createContinuation=$0 }
        }
        return target
    }
    func target(id:String) async throws -> BrowserTarget? { protectedTargets.contains(id) ? nil : targets[id] }
    func activateTarget(id:String) async throws { }
    func closeTarget(target:BrowserTarget) async throws {
        stats.closeAttempts += 1
        guard targets[target.targetID]?.instanceToken == target.instanceToken else { throw BrowserTabBrokerError.targetClosed }
        if shouldFailClose { shouldFailClose = false; throw BrowserTabBrokerError.browserUnavailable("Synthetic close failure") }
        guard owned.remove(target.targetID) != nil else { throw BrowserTabBrokerError.ownershipMismatch }
        targets.removeValue(forKey:target.targetID); stats.closes += 1
    }
    func closeOwnedTargets() async -> [String] {
        for id in Array(owned) { if let target=targets[id] { try? await closeTarget(target:target) } }; return []
    }
    func observe(target:BrowserTarget) async throws -> BrowserDocumentObservation {
        stats.observes += 1
        if holdRead {
            holdRead = false; observationHeld = true
            observationWaiters.forEach { $0.resume() }; observationWaiters.removeAll()
            await withCheckedContinuation { observationContinuation = $0 }
        }
        if !observationFailures.isEmpty {
            let failure = observationFailures.removeFirst()
            if let redirect = failureRedirect {
                generation = UUID().uuidString
                redirectOwnedTarget(to: redirect); failureRedirect = nil
            }
            if replaceOnFailure { replaceOwnedTarget(); replaceOnFailure = false }
            throw failure
        }
        var driftAfterCapture = false
        if postInputPending {
            postInputPending = false
            let scenario = afterInputScenario
            afterInputScenario = nil
            if scenario == "read_failed" { throw BrowserTabBrokerError.browserUnavailable("PRIVATE_READ_ERROR") }
            if scenario == "no_read_authority" { throw BrowserTabBrokerError.invalidRead("PRIVATE_READ_ERROR") }
            // Native WebKit rejects an observation that spans its document
            // generation changing; this fixture models that backend contract.
            if scenario == "generation_drift" { throw BrowserTabBrokerError.staleDocument }
            driftAfterCapture = scenario == "drift_after_capture"
            if scenario == "hold_observation" {
                observationHeld = true
                observationWaiters.forEach { $0.resume() }; observationWaiters.removeAll()
                await withCheckedContinuation { observationContinuation = $0 }
            }
        }
        if let redirect = pendingRedirect {
            targets[target.targetID] = BrowserTarget(targetID:target.targetID,instanceToken:target.instanceToken,title:target.title,url:redirect,webSocketURL:nil)
            pendingRedirect = nil
        }
        var nodes = [
            BrowserDocumentNode(backendNodeID:1,role:"textbox",name:"Flight number",value:field,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"1",isEditable:true),
            BrowserDocumentNode(backendNodeID:buttonID,role:"button",name:"Check flight",value:nil,isDisabled:buttonDisabled,isReadOnly:false,isIgnored:false,nodeID:String(buttonID),isDOMClickable:true),
            BrowserDocumentNode(backendNodeID:3,role:"statictext",name:result,value:nil,isDisabled:true,isReadOnly:true,isIgnored:false,nodeID:"3")
        ]
        if let link {
            nodes.append(BrowserDocumentNode(backendNodeID:4,role:"link",name:"Destination",value:nil,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"4",linkURL:link,isDOMClickable:!linkPressUnsupported,isPressUnsupported:linkPressUnsupported))
        }
        if manyControls {
            for index in 10..<110 {
                nodes.append(BrowserDocumentNode(backendNodeID: Int64(index), role: "button", name: "Extra control \(index)",
                    value: nil, isDisabled: false, isReadOnly: false, isIgnored: false,
                    nodeID: String(index), isDOMClickable: true))
            }
        }
        var observation=BrowserDocumentObservation(loaderID:generation,title:target.title,url:targets[target.targetID]?.url ?? target.url,nodes:emptyObservation ? [] : nodes)
        observation.sourceName = observationSourceName
        observation.semanticReadiness = semanticReadiness
        if driftAfterCapture {
            targets[target.targetID] = BrowserTarget(targetID: target.targetID, instanceToken: target.instanceToken,
                title: target.title, url: URL(string: "http://localhost:8123/changed-after-capture")!, webSocketURL: nil)
        }
        return observation
    }
    func press(target:BrowserTarget,backendNodeID:Int64,document:BrowserDocumentObservation,permit:BrowserMutationPermit) async throws {
        if holdMutation {
            mutationHeld=true; mutationWaiters.forEach { $0.resume() }; mutationWaiters.removeAll()
            await withCheckedContinuation { mutationContinuation=$0 }
        }
        try permit.commit { stats.presses += 1; result="\(field) departs at 18:45"; didInput(target) }
    }
    func setText(target:BrowserTarget,backendNodeID:Int64,text:String,document:BrowserDocumentObservation,permit:BrowserMutationPermit) async throws { try permit.commit { stats.fills += 1; field=text; didInput(target) } }
    func navigate(target:BrowserTarget,url:URL,permit:BrowserMutationPermit) async throws {
        try permit.commit { stats.navigations += 1; generation=UUID().uuidString; targets[target.targetID]=BrowserTarget(targetID:target.targetID,instanceToken:target.instanceToken,title:target.title,url:url,webSocketURL:nil) }
    }
    func wait(target:BrowserTarget,text:String?,timeoutMS:Int) async throws -> Bool { text == nil || result.contains(text!) }
    func holdNextCreate() { holdCreate=true }
    func waitUntilCreateHeld() async { if !createHeld { await withCheckedContinuation { createWaiters.append($0) } } }
    func resumeCreate() { createContinuation?.resume(); createContinuation=nil; holdCreate=false }
    func holdNextMutation() { holdMutation=true }
    func waitUntilMutationHeld() async { if !mutationHeld { await withCheckedContinuation { mutationWaiters.append($0) } } }
    func resumeMutation() { mutationContinuation?.resume(); mutationContinuation=nil; holdMutation=false }
    func redirectOnNextObserve(to url: URL) { pendingRedirect = url }
    func failObservations(_ failures: [BrowserTabBrokerError], redirect: URL? = nil, replaceTarget: Bool = false) {
        observationFailures = failures; failureRedirect = redirect; replaceOnFailure = replaceTarget
    }
    func showManyControls() { manyControls = true }
    func holdNextRead() { holdRead = true }
    func configureAfterInput(_ scenario: String) { afterInputScenario = scenario }
    func waitUntilObservationHeld() async {
        if !observationHeld { await withCheckedContinuation { observationWaiters.append($0) } }
    }
    func resumeObservation() { observationContinuation?.resume(); observationContinuation = nil }
    private func didInput(_ target: BrowserTarget) {
        guard let scenario = afterInputScenario else { return }
        switch scenario {
        case "redirect": redirectOwnedTarget(to: URL(string: "https://unrelated.example/PRIVATE_READ_ERROR")!)
        case "replaced": replaceOwnedTarget()
        case "protected": protectedTargets.insert(target.targetID)
        case "new_document":
            generation = UUID().uuidString
            redirectOwnedTarget(to: URL(string: "http://localhost:8123/result")!)
        case "same_url_reload": generation = UUID().uuidString
        case "pagination": manyControls = true
        default: postInputPending = true; return
        }
        afterInputScenario = nil
    }
    func setLink(_ url: String, pressUnsupported: Bool = false) { link = url; linkPressUnsupported = pressUnsupported }
    func disableButton() { buttonDisabled = true }
    func replaceButton() { buttonID = 99 }
    func replaceOwnedTarget() {
        for id in owned {
            guard let target = targets[id] else { continue }
            targets[id] = BrowserTarget(targetID:id,instanceToken:UUID().uuidString,title:target.title,
                                        url:target.url,webSocketURL:nil)
        }
    }
    func replaceOwnedTargetWithHumanIncarnation() {
        for id in Array(owned) {
            guard let target = targets[id] else { continue }
            targets[id] = BrowserTarget(targetID: id, instanceToken: UUID().uuidString,
                title: "Replacement user tab", url: target.url, webSocketURL: nil)
            owned.remove(id)
        }
    }
    func redirectOwnedTarget(to url: URL) {
        for id in owned {
            guard let target = targets[id] else { continue }
            targets[id] = BrowserTarget(targetID: id, instanceToken: target.instanceToken, title: target.title,
                                        url: url, webSocketURL: nil)
        }
    }
}
