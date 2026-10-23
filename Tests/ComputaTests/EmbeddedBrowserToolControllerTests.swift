import AutomationCore
import Foundation
import XCTest
@testable import Computa

@MainActor
final class EmbeddedBrowserToolControllerTests: XCTestCase {
    private struct PublishedTarget { let role: String; let label: String?; let clickRef: String?; let fillRef: String? }
    private var publishedTargets = [String: [Int: PublishedTarget]]()

    func testFreshReadAndContinueHaveDisjointSchemasWithFrozenLegacyDefinition() throws {
        let definitions = EmbeddedBrowserTools.definitions()
        let read = try XCTUnwrap(definitions.first { $0["name"] as? String == "browser_read" })
        let schema = try XCTUnwrap(read["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(schema["properties"] as? [String: Any]).keys), ["view", "query"])
        XCTAssertEqual(schema["required"] as? [String], [])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertFalse((read["description"] as? String)?.contains("browser_read(cursor=") == true)
        let next = try XCTUnwrap(definitions.first { $0["name"] as? String == "browser_continue" })
        let nextSchema = try XCTUnwrap(next["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(nextSchema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["cursor"])
        XCTAssertEqual(nextSchema["required"] as? [String], ["cursor"])
        XCTAssertEqual(nextSchema["additionalProperties"] as? Bool, false)
        let cursor = try XCTUnwrap(properties["cursor"] as? [String: Any])
        XCTAssertEqual(cursor["type"] as? String, "string"); XCTAssertEqual(cursor["minLength"] as? Int, 1)
        XCTAssertFalse(EmbeddedBrowserTools.requiresApproval(tool: "browser_continue"))
        let legacy = EmbeddedBrowserTools.legacyReadDefinition
        let legacySchema = try XCTUnwrap(legacy["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(legacySchema["properties"] as? [String: Any]).keys), ["view", "query", "cursor"])
        XCTAssertTrue((legacy["description"] as? String)?.contains("browser_read(cursor=next_cursor)") == true)
        XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: "browser_read", arguments: ["cursor": NSNull()]))
        XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: "browser_read", arguments: ["cursor": "legacy", "view": "all"]))
    }

    func testContinueInvalidArgumentsNeverBecomeFreshReadsOrGrantBindings() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let invalid: [[String: Any]] = [[:], ["cursor": NSNull()], ["cursor": ""], ["cursor": 1],
            ["cursor": true], ["cursor": ["cursor"]], ["cursor": String(repeating: "é", count: 1_025)],
            ["cursor": "unissued", "view": "content"], ["cursor": "unissued", "query": "text"],
            ["cursor": "unissued", "snapshot_id": UUID().uuidString]]
        let before = await backend.counts()
        for arguments in invalid {
            do { _ = try await call(controller, "browser_continue", arguments); XCTFail("Invalid continuation must reject before binding") }
            catch { XCTAssertTrue(error is BrowserTabBrokerError); XCTAssertFalse(error is EmbeddedBrowserPreflightRecoveryFailure) }
        }
        let after = await backend.counts(); XCTAssertEqual(after, before)
        do { _ = try await call(controller, "browser_continue", ["cursor": "unissued"]); XCTFail("A cursor cannot create a binding") }
        catch { XCTAssertTrue(error is EmbeddedBrowserBindingRequiredFailure) }
        let unbound = await backend.counts(); XCTAssertEqual(unbound, before)
        _ = await controller.shutdown()
    }

    func testContinueUsesSameImmutableCaptureAndCursorStateAsLegacyRead() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls(count: 200)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all", "query": "Extra control"])
        let firstCursor = try field("next_cursor", in: first), source = try field("source_observation", in: first)
        let before = await backend.counts()
        let second = try await controller.executeResult(taskKey: "turn-a", tool: "browser_continue",
            arguments: JSONSerialization.data(withJSONObject: ["cursor": firstCursor]))
        XCTAssertEqual(second.nativeRead?.rawValue, "continue_v1")
        XCTAssertTrue(second.completeObservation); XCTAssertNil(second.actionReceipt)
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(second.response), 0)
        XCTAssertEqual(try field("source_observation", in: second.response), source)
        XCTAssertEqual(try field("view", in: second.response), "all")
        XCTAssertTrue(second.response.contains("Extra control")); XCTAssertFalse(second.response.contains("Flight number"))
        let secondCursor = try field("next_cursor", in: second.response)
        let third = try await controller.executeResult(taskKey: "turn-a", tool: "browser_read",
            arguments: JSONSerialization.data(withJSONObject: ["cursor": secondCursor]))
        XCTAssertEqual(third.nativeRead, .read, "Legacy genuine call identity keeps its original proof kind")
        XCTAssertEqual(try field("source_observation", in: third.response), source)
        let continued = await backend.counts()
        XCTAssertEqual(continued.observes, before.observes + 2, "Each mode keeps exactly the existing document freshness probe")
        for tool in ["browser_read", "browser_continue"] {
            for cursor in [firstCursor, secondCursor] {
                do { _ = try await call(controller, tool, ["cursor": cursor]); XCTFail("Names share the same latest cursor") }
                catch { assertNoncurrentReadCursor(error) }
            }
        }
        let after = await backend.counts(); XCTAssertEqual(after, continued)
        let thirdCursor = try field("next_cursor", in: third.response)
        let fresh = try await call(controller, "browser_read", ["view": "all", "query": "Flight number"])
        XCTAssertNotEqual(try field("source_observation", in: fresh), source)
        let afterFresh = await backend.counts()
        do { _ = try await call(controller, "browser_continue", ["cursor": thirdCursor]); XCTFail("Fresh filters replace the old continuation") }
        catch { assertNoncurrentReadCursor(error) }
        let final = await backend.counts(); XCTAssertEqual(final, afterFresh)
        XCTAssertEqual(final.presses, 0); XCTAssertEqual(final.fills, 0)
        _ = await controller.shutdown()
    }

    func testContinueRejectsForeignAndInventoryCursorsWithoutConsumingCurrentReference() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls(); await backend.addLongInventory()
        let inventory = try jsonObject(await call(controller, "browser_tabs"))
        let inventoryCursor = try XCTUnwrap(inventory["next_cursor"] as? String)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let page = try await call(controller, "browser_read", ["view": "all"])
        let pageID = try snapshotID(page), reference = try XCTUnwrap(publishedTargets[pageID]?[1]?.clickRef)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], key: "turn-b")
        let foreign = try await call(controller, "browser_read", ["view": "all"], key: "turn-b")
        let before = await backend.counts()
        for cursor in [inventoryCursor, try field("next_cursor", in: foreign), pageID, reference, UUID().uuidString] {
            do { _ = try await call(controller, "browser_continue", ["cursor": cursor]); XCTFail("Wrong-route cursor cannot refresh or rebind") }
            catch { assertNoncurrentReadCursor(error) }
        }
        let rejected = await backend.counts(); XCTAssertEqual(rejected, before)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
            arguments: JSONSerialization.data(withJSONObject: ["click_ref": reference]))
        let next = try await call(controller, "browser_continue", ["cursor": field("next_cursor", in: page)])
        XCTAssertEqual(try field("source_observation", in: next), try field("source_observation", in: page))
        _ = await controller.release(taskKey: "turn-a")
        let retired = await backend.counts()
        do { _ = try await call(controller, "browser_continue", ["cursor": field("next_cursor", in: next)]); XCTFail("Retired turn cannot continue") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
        let final = await backend.counts(); XCTAssertEqual(final, retired)
        XCTAssertEqual(final.presses, 0); XCTAssertEqual(final.fills, 0)
        _ = await controller.shutdown()
    }

    func testContinueRejectsChangedFiltersWithoutRecoveryAndInputRetiresItsCursor() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"])
        let cursor = try field("next_cursor", in: first), id = try snapshotID(first)
        let before = await backend.counts()
        do { _ = try await call(controller, "browser_continue", ["cursor": cursor, "view": "content"]); XCTFail("Continue has no filter-changing mode") }
        catch { XCTAssertTrue(error is BrowserTabBrokerError); XCTAssertFalse(error is EmbeddedBrowserPreflightRecoveryFailure) }
        let rejected = await backend.counts(); XCTAssertEqual(rejected, before)
        let filled = try await call(controller, "browser_fill", ["snapshot_id": id, "element_index": 0, "text": "UA 4629"])
        XCTAssertEqual(try jsonObject(filled)["dispatched"] as? Bool, true)
        let afterInput = await backend.counts()
        for tool in ["browser_read", "browser_continue"] {
            do { _ = try await call(controller, tool, ["cursor": cursor]); XCTFail("Admitted input consumes both routes' old cursor") }
            catch { assertNoncurrentReadCursor(error) }
        }
        let final = await backend.counts(); XCTAssertEqual(final, afterInput)
        XCTAssertEqual(final.fills, 1); XCTAssertEqual(final.presses, 0)
        _ = await controller.shutdown()
    }

    func testContinueCannotPublishAfterCancellationOrReleaseDuringFreshnessProbe() async throws {
        for release in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.showManyControls()
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let page = try await call(controller, "browser_read", ["view": "all"])
            let arguments = try JSONSerialization.data(withJSONObject: ["cursor": field("next_cursor", in: page)])
            await backend.holdNextRead()
            let operation = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_continue", arguments: arguments) }
            await backend.waitUntilObservationHeld()
            if release { _ = await controller.release(taskKey: "turn-a") } else { operation.cancel() }
            await backend.resumeObservation()
            do { _ = try await operation.value; XCTFail("Cancelled or retired continuation cannot publish a complete page/proof") }
            catch { XCTAssertTrue(error is BrowserTabBrokerError || error is CancellationError) }
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testInvalidEventFeedbackParticipatesInPageBudgetWithoutSkippingContinuationRows() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls()
        await backend.reportInvalidFieldOnPress()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let original = try await call(controller, "browser_read")
        let before = await backend.counts()
        let clicked = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click",
            arguments: argumentData(["snapshot_id": snapshotID(original), "element_index": 1]))
        try assertCompleteActionObservation(clicked)
        let body = try jsonObject(clicked.response), feedback = try XCTUnwrap(body["input_feedback"] as? [String: Any])
        let fields = try XCTUnwrap(feedback["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["label"] as? String, "Flight number")
        XCTAssertEqual(fields.first?["issues"] as? [String], ["value_missing"])
        let after = await backend.counts()
        XCTAssertEqual(after.presses, 1); XCTAssertEqual(after.observes - before.observes, 2)
        var page = try availableObservation(clicked.response), labels = Set<String>(), pages = 0
        while true {
            pages += 1; XCTAssertLessThan(pages, 32)
            for row in page.split(separator: "\n") where row.hasPrefix("#") {
                if let label = try publishedString("label", in: String(row)) {
                    XCTAssertTrue(labels.insert(label).inserted, "Short rows must not be duplicated or skipped while packing feedback")
                }
            }
            guard let continuation = try actionReferenceMetadata(page)["continuation"] as? [String: Any] else { break }
            page = try await call(controller, "browser_read", XCTUnwrap(continuation["arguments"] as? [String: Any]))
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertTrue(labels.contains("Flight number")); XCTAssertTrue(labels.contains("Check flight"))
        for index in 10..<110 { XCTAssertTrue(labels.contains("Extra control \(index)")) }
        let final = await backend.counts()
        XCTAssertEqual(final.presses, 1); XCTAssertEqual(final.fills, 0)
        _ = await controller.shutdown()
    }

    func testInvalidEventFeedbackWithoutCurrentPageHasNoLabelsAndRetiredTurnHasNoFeedback() async throws {
        for interruption in ["none", "release", "cancel"] {
            let retired = interruption != "none"
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.reportInvalidFieldOnPress()
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let read = try await call(controller, "browser_read")
            let input = try argumentData(["snapshot_id": snapshotID(read), "element_index": 1])
            await backend.configureAfterInput(retired ? "hold_observation" : "read_failed")
            let operation = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: input) }
            if retired {
                await backend.waitUntilObservationHeld()
                if interruption == "release" { _ = await controller.release(taskKey: "turn-a") }
                else { operation.cancel() }
                await backend.resumeObservation()
            }
            let result = try await operation.value, body = try jsonObject(result.response)
            XCTAssertFalse(result.completeObservation)
            XCTAssertEqual(body["dispatched"] as? Bool, true); XCTAssertEqual(body["result_verified"] as? Bool, false)
            if retired { XCTAssertNil(body["input_feedback"]) }
            else {
                let feedback = try XCTUnwrap(body["input_feedback"] as? [String: Any])
                XCTAssertEqual((feedback["fields"] as? [[String: Any]])?.count, 0)
                XCTAssertEqual(feedback["fields_omitted"] as? Bool, true)
                XCTAssertFalse(result.response.contains("Flight number"))
            }
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 1)
            _ = await controller.shutdown()
        }
    }

    func testCompleteReadSerializedLimitIncludesEscapingAndPublishedReferenceSuffixes() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let label = String(repeating: "🙂\\\"\n\u{0001}", count: 300) + " exact final label"
        await backend.setButtonLabel(label)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        var arguments: [String: Any] = ["view": "all"], pages = 0, observed = ""
        while true {
            let result = try await controller.executeResult(taskKey: "turn-a", tool: arguments["cursor"] == nil ? "browser_read" : "browser_continue",
                arguments: JSONSerialization.data(withJSONObject: arguments))
            XCTAssertEqual(result.nativeRead, arguments["cursor"] == nil ? .read : .continuation)
            XCTAssertTrue(result.completeObservation)
            let items = [["type": "inputText", "text": BrowserCompleteObservation.marker],
                         ["type": "inputText", "text": result.response]]
            XCTAssertLessThanOrEqual(items.reduce(1) { $0 + $1["text", default: ""].utf8.count }, 4_096)
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: items).count, 4_608)
            let id = try snapshotID(result.response)
            for row in (publishedTargets[id] ?? [:]).values where row.role == "AXButton" {
                XCTAssertNotNil(row.clickRef)
                observed += try XCTUnwrap(row.label)
            }
            pages += 1
            guard let next = try actionReferenceMetadata(result.response)["continuation"] as? [String: Any] else { break }
            XCTAssertLessThan(pages, 24)
            arguments = try XCTUnwrap(next["arguments"] as? [String: Any])
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(Array(observed.utf8), Array(label.utf8))
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = await controller.shutdown()
    }

    func testCompleteReadPagesRetainPreviouslyExposedTargetsWithinExistingBudgets() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        var arguments: [String: Any] = ["view": "all"]
        var seen = Set<String>(), pages = 0, firstReference: String?
        while true {
            let result = try await controller.executeResult(taskKey: "turn-a", tool: arguments["cursor"] == nil ? "browser_read" : "browser_continue",
                arguments: JSONSerialization.data(withJSONObject: arguments))
            XCTAssertEqual(result.nativeRead, arguments["cursor"] == nil ? .read : .continuation)
            XCTAssertTrue(result.completeObservation); XCTAssertNil(result.actionReceipt)
            let items = [["type": "inputText", "text": BrowserCompleteObservation.marker],
                         ["type": "inputText", "text": result.response]]
            XCTAssertLessThanOrEqual(items.reduce(1) { $0 + $1["text", default: ""].utf8.count }, 4_096)
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: items).count, 4_608)
            let id = try snapshotID(result.response)
            let targets = try XCTUnwrap(publishedTargets[id])
            if firstReference == nil { firstReference = targets[1]?.clickRef }
            for target in targets.values {
                if let label = target.label { XCTAssertTrue(seen.insert(label).inserted, "Ordinary short rows must never be skipped or duplicated") }
            }
            pages += 1
            let metadata = try actionReferenceMetadata(result.response)
            XCTAssertTrue((metadata["references"] as? String)?.contains("same capture") == true)
            guard let continuation = metadata["continuation"] as? [String: Any] else { break }
            XCTAssertLessThan(pages, 32)
            arguments = try XCTUnwrap(continuation["arguments"] as? [String: Any])
        }
        XCTAssertEqual(seen.count, 103, "The all-nodes view retains its captured empty StaticText row")
        XCTAssertTrue(seen.contains(""))
        XCTAssertTrue(seen.contains("Flight number")); XCTAssertTrue(seen.contains("Check flight"))
        for index in 10..<110 { XCTAssertTrue(seen.contains("Extra control \(index)")) }
        let before = await backend.counts()
        XCTAssertEqual(before.presses, 0); XCTAssertEqual(before.fills, 0)
        let click = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click",
            arguments: JSONSerialization.data(withJSONObject: ["click_ref": try XCTUnwrap(firstReference)]))
        XCTAssertTrue(click.completeObservation)
        XCTAssertEqual(try jsonObject(XCTUnwrap(click.actionReceipt).compactText)["kind"] as? String, "click")
        let after = await backend.counts()
        XCTAssertEqual(after.presses, 1); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
    }

    private func assertCompleteActionObservation(_ result: EmbeddedBrowserToolExecution,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(result.completeObservation, file: file, line: line)
        let cue = try XCTUnwrap(result.actionReceipt?.compactText, file: file, line: line)
        let items = [BrowserCompleteObservation.marker, cue, result.response].map { ["type": "inputText", "text": $0] }
        XCTAssertLessThanOrEqual(items.reduce(2) { $0 + $1["text", default: ""].utf8.count }, 4_096, file: file, line: line)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: items).count, 4_608, file: file, line: line)
        XCTAssertEqual(try jsonObject(result.response)["result_verified"] as? Bool, false, file: file, line: line)
    }

    func testNestedEscapedPostFillPageShrinksWithoutRecaptureAndContinuesEveryValueByte() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setButtonLabel("Send message")
        await backend.setLink("http://localhost:8123/sent", label: "Sent")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let original = try await call(controller, "browser_read")
        let value = String(repeating: "\\\"", count: 900) + "e\u{301} 🙂\n\t\u{0001} EXACT_VALUE_TAIL"
        let before = await backend.counts()
        let result = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill",
            arguments: argumentData(["snapshot_id": snapshotID(original), "element_index": 0, "text": value]))
        try assertCompleteActionObservation(result)
        var page = try availableObservation(result.response)
        XCTAssertTrue(page.contains("value_utf8=0:"), "The first page must expose a bounded prefix rather than fail or skip the field")
        let source = try field("source_observation", in: page)
        let afterInput = await backend.counts()
        XCTAssertEqual(afterInput.observes, before.observes + 2, "Packing retries reuse the captured document; only mutation preflight and post-input capture may read")
        XCTAssertEqual(afterInput.fills, 1); XCTAssertEqual(afterInput.presses, 0)
        var reconstructed = "", pages = 0, labels = Set<String>()
        while true {
            pages += 1
            XCTAssertLessThan(pages, 20)
            XCTAssertEqual(try field("source_observation", in: page), source)
            for rawRow in page.split(separator: "\n") where rawRow.hasPrefix("#") {
                let row = String(rawRow)
                if let label = try publishedString("label", in: row) { labels.insert(label) }
                guard let fragment = try publishedString("value", in: row) else { continue }
                if let range = row.range(of: " value_utf8=") {
                    let span = try XCTUnwrap(row[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first)
                    let offsets = span.split(whereSeparator: { $0 == ":" || $0 == "/" }).compactMap { Int($0) }
                    XCTAssertEqual(offsets.count, 3)
                    XCTAssertEqual(offsets.first, reconstructed.utf8.count)
                    XCTAssertEqual(offsets.last, value.utf8.count)
                    if offsets.count == 3 { XCTAssertEqual(offsets[1] - offsets[0], fragment.utf8.count) }
                }
                reconstructed += fragment
            }
            guard let continuation = try actionReferenceMetadata(page)["continuation"] as? [String: Any] else { break }
            let arguments = try XCTUnwrap(continuation["arguments"] as? [String: Any])
            let next = try await controller.executeResult(taskKey: "turn-a", tool: "browser_read",
                arguments: JSONSerialization.data(withJSONObject: arguments))
            XCTAssertTrue(next.completeObservation)
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(next.response), 0)
            page = next.response
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(Array(reconstructed.utf8), Array(value.utf8))
        XCTAssertTrue(labels.contains("Send message")); XCTAssertTrue(labels.contains("Sent"))
        let final = await backend.counts()
        XCTAssertEqual(final.observes, afterInput.observes + pages - 1)
        XCTAssertEqual(final.fills, 1); XCTAssertEqual(final.presses, 0)
        let actualValue = await backend.fieldValue()
        XCTAssertEqual(actualValue, value)
        _ = await controller.shutdown()
    }

    func testIntrinsicallyOversizedPostInputMetadataRetainsDispatchWithoutPublishingAPage() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let original = try await call(controller, "browser_read")
        await backend.setObservationSourceName(String(repeating: "x", count: 4_096))
        let result = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill",
            arguments: argumentData(["snapshot_id": snapshotID(original), "element_index": 0, "text": "UA 4629"]))
        XCTAssertFalse(result.completeObservation)
        XCTAssertEqual(try jsonObject(XCTUnwrap(result.actionReceipt).compactText)["outcome"] as? String, "unverified")
        let body = try jsonObject(result.response)
        XCTAssertEqual(body["dispatched"] as? Bool, true)
        XCTAssertEqual(body["no_replay"] as? Bool, true)
        XCTAssertEqual(body["result_verified"] as? Bool, false)
        let observation = try XCTUnwrap(body["current_observation"] as? [String: Any])
        XCTAssertEqual(observation["status"] as? String, "unavailable")
        XCTAssertEqual(observation["reason"] as? String, "output_limit", "Actual packing failure is not an authorization or sign-in failure")
        XCTAssertFalse(result.response.contains("read_not_authorized"))
        XCTAssertNil(observation["text"]); XCTAssertNil(observation["snapshot_id"])
        XCTAssertFalse(result.response.contains("click_ref=")); XCTAssertFalse(result.response.contains("fill_ref="))
        do {
            _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(original), "element_index": 1])
            XCTFail("An unavailable post-input page cannot revive the consumed reference")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0)
        _ = await controller.shutdown()
    }

    func testReadFailureScopeRequiresCurrentNativeCommittedDocumentEvidence() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity()
        func execute(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> EmbeddedBrowserToolExecution {
            try await controller.executeResult(taskKey: "turn-a", tool: tool,
                arguments: JSONSerialization.data(withJSONObject: arguments))
        }
        let inventory = try await execute("browser_tabs")
        XCTAssertNil(inventory.readFailureScope)
        let humanID = await backend.humanID
        let bound = try await execute("browser_bind", ["tab_id": humanID])
        let first = try XCTUnwrap(bound.readFailureScope)
        let noOp = try await execute("browser_bind", ["tab_id": humanID])
        XCTAssertNil(noOp.readFailureScope, "A successful already-bound no-op is not a transition")
        let read = try await execute("browser_read", ["view": "all"])
        XCTAssertEqual(read.readFailureScope, first, "Fresh snapshots retain the same native scope")
        let opened = try await execute("browser_open", ["url": "http://localhost:8123/document"])
        let second = try XCTUnwrap(opened.readFailureScope)
        XCTAssertNotEqual(second, first)
        do {
            _ = try await execute("browser_open", ["url": "file:///MUST_NOT_OPEN"])
            XCTFail("An invalid replacement cannot return binding evidence")
        } catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        let afterFailure = try await execute("browser_read", ["view": "all"])
        XCTAssertEqual(afterFailure.readFailureScope, second)
        let navigating = try await execute("browser_navigate", ["url": "http://localhost:8123/replacement"])
        XCTAssertNil(navigating.readFailureScope, "Accepting navigation alone is not an observed commit")
        let committedRead = try await execute("browser_read", ["view": "all"])
        let afterCommit = try XCTUnwrap(committedRead.readFailureScope)
        XCTAssertEqual(afterCommit.bindingHandle, second.bindingHandle)
        XCTAssertNotEqual(afterCommit.committedDocumentID, second.committedDocumentID)
        await backend.hideCommittedDocumentIdentity()
        let unknown = try await execute("browser_read", ["view": "all"])
        XCTAssertNil(unknown.readFailureScope, "Unknown native provenance cannot relax the guard")
        _ = await controller.shutdown()
    }

    func testNewBindingsAndCommittedDocumentsDoNotRefundTheTurnWideThreeReadRecoveryBudget() async throws {
        for transition in ["browser_open", "browser_navigate"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.exposeCommittedDocumentIdentity()
            await backend.showManyControls()
            for index in 0..<4 {
                _ = try await call(controller, index == 0 ? "browser_open" : transition,
                                   ["url": "http://localhost:8123/document-\(index)"])
                let read = try await call(controller, "browser_read", ["view": "all"])
                let before = await backend.counts()
                let failure = try await changedFilterFailure(controller,
                    arguments: ["cursor": field("next_cursor", in: read), "view": "content"])
                let observation = try XCTUnwrap(jsonObject(failure.observationResponse)["current_observation"] as? [String: Any])
                XCTAssertEqual(observation["status"] as? String, index < 3 ? "available" : "unavailable")
                if index < 3 { XCTAssertNotNil(failure.readFailureScope) }
                else {
                    XCTAssertEqual(observation["reason"] as? String, "recovery_limit")
                    XCTAssertNil(failure.readFailureScope, "A rejected recovery cannot reset retry accounting")
                }
                let after = await backend.counts()
                XCTAssertEqual(after.observes, before.observes + (index < 3 ? 1 : 0))
                XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            }
            _ = await controller.shutdown()
        }
    }

    /// Legacy-shaped fixture inputs are translated only from an exact emitted
    /// row; production accepts no legacy live mutation arguments.
    private func argumentData(_ arguments: [String: Any]) throws -> Data {
        if let snapshotID = arguments["snapshot_id"] as? String,
           let index = arguments["element_index"] as? Int {
            let row = publishedTargets[snapshotID]?[index]
            let filling = arguments["text"] != nil
            let ref = filling ? row?.fillRef : row?.clickRef
            var input: [String: Any] = [filling ? "fill_ref" : "click_ref": ref ?? "unpublished-reference"]
            if let text = arguments["text"] { input["text"] = text }
            return try JSONSerialization.data(withJSONObject: input)
        }
        return try JSONSerialization.data(withJSONObject: arguments)
    }

    private func publishedString(_ name: String, in row: String) throws -> String? {
        let pattern = #"(?:^| )\#(name)=("(?:[^"\\]|\\.)*")"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
              let range = Range(match.range(at: 1), in: row) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(row[range].utf8), options: .fragmentsAllowed) as? String
    }

    func testTypedRefsAreRequiredAndExplicitEmptyLabelRemainsActionable() async throws {
        for tool in ["browser_click", "browser_fill"] {
            let schema = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == tool }?["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["required"] as? [String], tool == "browser_click" ? ["click_ref"] : ["fill_ref", "text"])
            let props = try XCTUnwrap(schema["properties"] as? [String: Any])
            for old in ["snapshot_id", "element_index", "expected_role", "expected_label"] { XCTAssertNil(props[old]) }
            var legacy: [String: Any] = ["snapshot_id": UUID().uuidString, "element_index": 0, "expected_role": "AXButton", "expected_label": ""]
            if tool == "browser_fill" { legacy["text"] = "value" }
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: tool, arguments: legacy))
        }
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setButtonLabel("")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(read)
        let ref = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef)
        let data = try argumentData(["click_ref": ref])
        let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        XCTAssertEqual(prepared.canonicalArguments?["expected_label"] as? String, "")
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared)
        let result = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared)
        XCTAssertEqual(try jsonObject(result.response)["dispatched"] as? Bool, true)
        _ = await controller.shutdown()
    }

    func testSendSentRefsBindDistinctObservedRowsAndRejectUnknownOrWrongKindsWithoutCapture() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setButtonLabel("Send message"); await backend.setLink("http://localhost:8123/sent", label: "Sent")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(read)
        let send = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef), sent = try XCTUnwrap(publishedTargets[id]?[3]?.clickRef)
        let fill = try XCTUnwrap(publishedTargets[id]?[0]?.fillRef)
        XCTAssertNotEqual(send, sent)
        let before = await backend.counts()
        for bad in [fill, "bclick_00000000-0000-4000-8000-000000000000", "native-reference"] {
            let input = try argumentData(["click_ref": bad])
            for preflight in [true, false] {
                do {
                    if preflight { try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: input) }
                    else { _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: input) }
                    XCTFail("Invalid references must reject before approval/input")
                } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
            }
        }
        let denied = await backend.counts(); XCTAssertEqual(denied, before)
        for (ref, label, role) in [(send, "Send message", "AXButton"), (sent, "Sent", "AXLink")] {
            let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": ref]))
            XCTAssertEqual(prepared.canonicalArguments?["expected_label"] as? String, label)
            XCTAssertEqual(prepared.canonicalArguments?["expected_role"] as? String, role)
        }
        let result = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": send]))
        XCTAssertEqual(try jsonObject(XCTUnwrap(result.actionReceipt).compactText)["label"] as? String, "Send message")
        XCTAssertEqual(try jsonObject(result.response)["result_verified"] as? Bool, false)
        let counts = await backend.counts(); XCTAssertEqual(counts.presses, 1); XCTAssertEqual(counts.navigations, 0)
        _ = await controller.shutdown()
    }

    func testRepublishedRefCanReindexButFrozenApprovalCannotMoveToANewerObservation() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity()
        await backend.setLink("http://localhost:8123/next", label: "Open document")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let all = try await call(controller, "browser_read", ["view": "all"]), first = try snapshotID(all)
        let ref = try XCTUnwrap(publishedTargets[first]?[3]?.clickRef), data = try argumentData(["click_ref": ref])
        let approved = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: approved)
        let links = try await call(controller, "browser_read", ["view": "links"]), current = try snapshotID(links)
        XCTAssertEqual(publishedTargets[current]?[0]?.clickRef, ref, "The same current exposed target may retain its token across reindexing")
        do {
            _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: approved)
            XCTFail("Approval cannot refresh its frozen snapshot")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let denied = await backend.counts(); XCTAssertEqual(denied.presses, 0)
        let next = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        XCTAssertEqual(next.canonicalArguments?["element_index"] as? Int, 3, "Corroboration preserves the original published target; current row numbering is not authority")
        XCTAssertEqual(approved.canonicalArguments?["element_index"] as? Int, 3)
        XCTAssertEqual(next.intentIdentity, approved.intentIdentity)
        _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: next)
        _ = await controller.shutdown()
    }

    func testChangedAbsentAmbiguousOrUnprovenTargetsCannotRetainTheirPublishedReference() async throws {
        for change in ["label", "node", "value", "missing", "hidden", "duplicate_backend", "duplicate_node", "disabled", "document", "commit", "unknown_commit", "url", "unicode", "role", "parent", "constraints"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.exposeCommittedDocumentIdentity()
            if change == "unicode" { await backend.setButtonLabel("Check flight é") }
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
            let filling = change == "value", tool = filling ? "browser_fill" : "browser_click"
            let old = try XCTUnwrap(filling ? publishedTargets[id]?[0]?.fillRef : publishedTargets[id]?[1]?.clickRef)
            switch change {
            case "label": await backend.setButtonLabel("Changed label")
            case "node": await backend.replaceButton()
            case "value": await backend.setInitialField("Changed value")
            case "document": await backend.reloadDocument()
            case "commit": await backend.replaceCommittedDocumentIdentity()
            case "unknown_commit": await backend.hideCommittedDocumentIdentity()
            case "url": await backend.redirectOwnedTarget(to: URL(string: "http://localhost:8123/other")!)
            case "disabled": await backend.disableButton()
            case "unicode": await backend.setButtonLabel("Check flight e\u{301}")
            default: await backend.setButtonCaptureScenario(change)
            }
            let next = try await call(controller, "browser_read", ["view": "content"])
            let nextID = try snapshotID(next)
            XCTAssertFalse(publishedTargets[nextID]?.values.contains { $0.clickRef == old || $0.fillRef == old } ?? false)
            var input: [String: Any] = [filling ? "fill_ref" : "click_ref": old]
            if filling { input["text"] = "MUST_NOT_INPUT" }
            let frozen = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: argumentData(input))
            XCTAssertNil(frozen.canonicalArguments, "A known retired ref is only a bounded recovery hint")
            do {
                _ = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: argumentData(input), prepared: frozen)
                XCTFail("Changed, absent or ambiguous native targets never retarget an old input: \(change)")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testFreshReadCorroboratesPreviouslyPublishedControlsWithoutExposingNewTargets() async throws {
        for fill in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.exposeCommittedDocumentIdentity()
            await backend.setObservedResult("A readable result")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
            let ref = try XCTUnwrap(fill ? publishedTargets[id]?[0]?.fillRef : publishedTargets[id]?[1]?.clickRef)
            let tool = fill ? "browser_fill" : "browser_click"
            var arguments: [String: Any] = [fill ? "fill_ref" : "click_ref": ref]
            if fill { arguments["text"] = "UA 1842" }
            let data = try argumentData(arguments)
            let frozen = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            let before = await backend.counts()
            let content = try await call(controller, "browser_read", ["view": "content"])
            XCTAssertFalse(content.contains(ref), "The current content view does not falsely publish the control")
            let observed = await backend.counts()
            XCTAssertEqual(observed.observes - before.observes, 1, "Corroboration uses the existing capture")
            let firstProof = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            _ = try await call(controller, "browser_read", ["view": "content", "query": "readable"])
            let secondProof = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            XCTAssertEqual(firstProof.witness?.publicationID, secondProof.witness?.publicationID)
            XCTAssertNotEqual(firstProof.witness, secondProof.witness, "Each corroboration has a new capture revision")
            do {
                _ = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: data, prepared: frozen)
                XCTFail("A fresh capture cannot move an earlier approval")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            XCTAssertNotNil(prepared.canonicalArguments)
            XCTAssertEqual(prepared.intentIdentity, frozen.intentIdentity)
            XCTAssertEqual(prepared.witness?.publicationID, frozen.witness?.publicationID)
            XCTAssertNotEqual(prepared.witness, frozen.witness, "The host proof revision is newly frozen")
            let result = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: data, prepared: prepared)
            try assertCompleteActionObservation(result)
            let counts = await backend.counts()
            XCTAssertEqual(counts.presses, fill ? 0 : 1); XCTAssertEqual(counts.fills, fill ? 1 : 0)
            if fill { let value = await backend.fieldValue(); XCTAssertEqual(value, "UA 1842") }
            // Even an unchanged button is consumed by input. A later fresh
            // read cannot silently renew the old token.
            let oldButton = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef)
            _ = try await call(controller, "browser_read", ["view": "content"])
            let consumed = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click",
                arguments: argumentData(["click_ref": oldButton]))
            XCTAssertNil(consumed.canonicalArguments)
            _ = await controller.shutdown()
        }
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        _ = try await call(controller, "browser_read", ["view": "content"])
        let counts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
        XCTAssertEqual(counts.current, 0, "Unpublished native controls cannot become new capabilities")
        _ = await controller.shutdown()
    }

    func testFreshReadCorroborationPreservesOriginalExpiryIncludingLockedDispatch() async throws {
        for boundary in ["preapproval", "enqueue"] {
            let backend = EmbeddedBrowserFixtureBackend()
            let controller = EmbeddedBrowserToolController(transport: backend, readLifetime: .milliseconds(400))
            await backend.exposeCommittedDocumentIdentity()
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
            let data = try argumentData(["click_ref": XCTUnwrap(publishedTargets[id]?[1]?.clickRef)])
            try await Task.sleep(for: .milliseconds(220))
            _ = try await call(controller, "browser_read", ["view": "content"])
            let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
            XCTAssertNotNil(prepared.canonicalArguments)
            if boundary == "enqueue" {
                await backend.holdNextMutation()
                let task = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared) }
                await backend.waitUntilMutationHeld()
                try await Task.sleep(for: .milliseconds(220))
                await backend.resumeMutation()
                do { _ = try await task.value; XCTFail("Corroboration cannot renew a locked input permit") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            } else {
                try await Task.sleep(for: .milliseconds(220))
                do {
                    try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared)
                    XCTFail("The old reference expires before the new capture")
                } catch {
                    let failure = try XCTUnwrap(error as? EmbeddedBrowserPreflightRecoveryFailure)
                    XCTAssertEqual(failure.original, .staleSnapshot)
                }
            }
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0)
            _ = await controller.shutdown()
        }
    }

    func testKnownCommitDriftAfterCorroborationRejectsClickAndFillBeforeInput() async throws {
        for fill in [false, true] {
            for missing in [false, true] {
                let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
                await backend.exposeCommittedDocumentIdentity()
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
                let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
                var arguments: [String: Any] = [fill ? "fill_ref" : "click_ref": try XCTUnwrap(fill ? publishedTargets[id]?[0]?.fillRef : publishedTargets[id]?[1]?.clickRef)]
                if fill { arguments["text"] = "MUST_NOT_INPUT" }
                let tool = fill ? "browser_fill" : "browser_click", data = try argumentData(arguments)
                _ = try await call(controller, "browser_read", ["view": "content"])
                let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
                try await controller.preflightMutation(taskKey: "turn-a", tool: tool, arguments: data, prepared: prepared)
                if missing { await backend.hideCommittedDocumentIdentity() }
                else { await backend.replaceCommittedDocumentIdentity() }
                do { _ = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: data, prepared: prepared); XCTFail() }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleDocument) }
                let counts = await backend.counts(); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.presses, 0)
                _ = await controller.shutdown()
            }
        }
    }

    func testFreshCorroborationDoesNotPromoteFIFOAgeOrIncreaseCapacity() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity(); await backend.showManyControls(count: 118)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all", "query": "Check flight"]), id = try snapshotID(first)
        let oldest = try XCTUnwrap(publishedTargets[id]?[0]?.clickRef)
        var page = try await call(controller, "browser_read", ["view": "all", "query": "Extra control"])
        let extraID = try snapshotID(page), extra = try XCTUnwrap(publishedTargets[extraID]?[0]?.clickRef)
        while let continuation = try actionReferenceMetadata(page)["continuation"] as? [String: Any] {
            page = try await call(controller, "browser_read", XCTUnwrap(continuation["arguments"] as? [String: Any]))
        }
        _ = try await call(controller, "browser_read", ["view": "all", "query": "Flight number"])
        var counts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
        XCTAssertEqual(counts.current, 120)
        for _ in 0..<2 { _ = try await call(controller, "browser_read", ["view": "content"]) }
        let stillOldest = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": oldest]))
        XCTAssertNotNil(stillOldest.canonicalArguments)
        await backend.setLink("http://localhost:8123/new", label: "New observed link")
        _ = try await call(controller, "browser_read", ["view": "links"])
        let evicted = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": oldest]))
        let retained = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": extra]))
        XCTAssertNil(evicted.canonicalArguments, "Repeated corroboration never moves the oldest token to the FIFO tail")
        XCTAssertNotNil(retained.canonicalArguments)
        counts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
        XCTAssertEqual(counts.current, 120); XCTAssertLessThanOrEqual(counts.retired, 256)
        let inputs = await backend.counts(); XCTAssertEqual(inputs.presses, 0); XCTAssertEqual(inputs.fills, 0)
        _ = await controller.shutdown()
    }

    func testFailedFreshReadsCannotReviveUnexposedEarlierReferences() async throws {
        for failure in ["capture", "output", "publication"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.exposeCommittedDocumentIdentity()
            let scope: ComputerTaskScope? = failure == "publication"
                ? ComputerTaskScope(userPrompt: "Use only http://localhost:8123/flight.") : nil
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let first = try await call(controller, "browser_read", ["view": "all"], scope: scope), id = try snapshotID(first)
            let ref = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef)
            switch failure {
            case "capture": await backend.failObservations([.browserUnavailable("Synthetic failed read")])
            case "output": await backend.setObservationSourceName(String(repeating: "x", count: 4_096))
            default: await backend.redirectOnNextObserve(to: URL(string: "https://unrelated.example/no-publish")!)
            }
            do { _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_read",
                    arguments: argumentData(["view": "content"]), scope: scope); XCTFail() }
            catch { XCTAssertTrue(error is BrowserTabBrokerError) }
            await backend.setObservationSourceName("computa_webkit_dom")
            await backend.redirectOwnedTarget(to: URL(string: "http://localhost:8123/flight")!)
            _ = try await call(controller, "browser_read", ["view": "content"], scope: scope)
            let prior = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": ref]))
            XCTAssertNil(prior.canonicalArguments, "A later capture cannot revive a failed read's old authority: \(failure)")
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testFailedReplacementThenContinuationCannotRestoreOmittedFreshCarryEligibility() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity(); await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
        let data = try argumentData(["click_ref": XCTUnwrap(publishedTargets[id]?[1]?.clickRef)])
        let original = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        let cursor = try field("next_cursor", in: first)
        await backend.failObservations([.browserUnavailable("Synthetic changed-filter read failure")])
        do { _ = try await call(controller, "browser_read", ["cursor": cursor, "view": "content"]); XCTFail() }
        catch { XCTAssertTrue(error is EmbeddedBrowserPreflightRecoveryFailure) }
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: original)
        let continued = try await call(controller, "browser_read", ["cursor": cursor])
        XCTAssertFalse(continued.contains(original.reference))
        _ = try await call(controller, "browser_read", ["view": "content"])
        let stale = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        XCTAssertNil(stale.canonicalArguments)
        let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = await controller.shutdown()
    }

    func testActionSuffixesFitReservedPageBytesAndContinuationPublishesOnlyItsOwnRows() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity(); await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"]), firstID = try snapshotID(first)
        let firstRef = try XCTUnwrap(publishedTargets[firstID]?[1]?.clickRef)
        let next = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: first)])
        for page in [first, next] {
            let rows = page.split(separator: "\n").filter { $0.hasPrefix("#") }
            XCTAssertLessThanOrEqual(page.utf8.count, 16_384)
            XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.utf8.count + 1 }, 12_000)
            for row in rows {
                let refs = [try publishedString("click_ref", in: String(row)), try publishedString("fill_ref", in: String(row))].compactMap { $0 }
                XCTAssertTrue(refs.allSatisfy { $0.utf8.count <= 128 })
            }
        }
        let nextID = try snapshotID(next)
        XCTAssertFalse(publishedTargets[nextID]?.values.contains { $0.clickRef == firstRef } ?? false)
        let old = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": firstRef]))
        XCTAssertEqual(old.canonicalArguments?["expected_label"] as? String, "Check flight", "Continuation retains only the previously exposed exact target")
        let currentRef = try XCTUnwrap(publishedTargets[nextID]?.values.compactMap(\.clickRef).first)
        let current = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": currentRef]))
        XCTAssertNotNil(current.canonicalArguments)
        _ = await controller.shutdown()
    }

    func testFrozenClickAndFillSurviveOnlySameCaptureCursorContinuation() async throws {
        for fill in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.showManyControls()
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read", ["view": "all"]), firstID = try snapshotID(first)
            let row = try XCTUnwrap(publishedTargets[firstID]?[fill ? 0 : 1])
            let ref = try XCTUnwrap(fill ? row.fillRef : row.clickRef)
            let tool = fill ? "browser_fill" : "browser_click"
            var arguments: [String: Any] = [fill ? "fill_ref" : "click_ref": ref]
            if fill { arguments["text"] = "exact e\u{301} value" }
            let data = try argumentData(arguments)
            let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            try await controller.preflightMutation(taskKey: "turn-a", tool: tool, arguments: data, prepared: prepared)
            let second = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: first)])
            XCTAssertEqual(try field("source_observation", in: first), try field("source_observation", in: second))
            XCTAssertNotEqual(firstID, try snapshotID(second))
            XCTAssertFalse(second.contains(ref), "The later page does not falsely reprint the earlier row")
            let again = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            XCTAssertEqual(again.witness, prepared.witness, "Pagination never refreshes an approved target or its capture age")
            let result = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: data, prepared: prepared)
            try assertCompleteActionObservation(result)
            let counts = await backend.counts()
            XCTAssertEqual(counts.fills, fill ? 1 : 0); XCTAssertEqual(counts.presses, fill ? 0 : 1)
            do {
                _ = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: data, prepared: prepared)
                XCTFail("Input consumes references from every page")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            _ = await controller.shutdown()
        }
    }

    func testRetainedPageWitnessStillRejectsChangedLiveTargetBeforeDispatch() async throws {
        for change in ["label", "disabled", "value", "document"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            await backend.showManyControls()
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
            let fill = change == "value", tool = fill ? "browser_fill" : "browser_click"
            let ref = try XCTUnwrap(fill ? publishedTargets[id]?[0]?.fillRef : publishedTargets[id]?[1]?.clickRef)
            var arguments: [String: Any] = [fill ? "fill_ref" : "click_ref": ref]
            if fill { arguments["text"] = "MUST_NOT_INPUT" }
            let data = try argumentData(arguments)
            let frozen = try await controller.prepareMutation(taskKey: "turn-a", tool: tool, arguments: data)
            _ = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: first)])
            switch change {
            case "label": await backend.setButtonLabel("Changed target")
            case "disabled": await backend.disableButton()
            case "value": await backend.setInitialField("Changed current value")
            default: await backend.reloadDocument()
            }
            do {
                _ = try await controller.executeResult(taskKey: "turn-a", tool: tool, arguments: data, prepared: frozen)
                XCTFail("Retained exposure cannot bypass live semantics: \(change)")
            } catch { XCTAssertTrue(error is BrowserTabBrokerError) }
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testContinuationEvictionRevokesFrozenApprovalWithinUnchanged120ReferenceBound() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls(count: 170)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        var page = try await call(controller, "browser_read", ["view": "all"])
        let id = try snapshotID(page), ref = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef)
        let data = try argumentData(["click_ref": ref])
        let frozen = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: frozen)
        var pages = 0
        while let continuation = try actionReferenceMetadata(page)["continuation"] as? [String: Any] {
            pages += 1; XCTAssertLessThan(pages, 40)
            page = try await call(controller, "browser_read", XCTUnwrap(continuation["arguments"] as? [String: Any]))
            let currentID = try snapshotID(page)
            for target in (publishedTargets[currentID] ?? [:]).values {
                guard let currentRef = target.clickRef else { continue }
                let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": currentRef]))
                XCTAssertNotNil(prepared.canonicalArguments, "Every token printed on the newly published page must remain admitted")
            }
            let counts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
            XCTAssertLessThanOrEqual(counts.current, 120); XCTAssertLessThanOrEqual(counts.retired, 256)
        }
        let finalCounts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
        XCTAssertEqual(finalCounts.current, 120)
        do {
            _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: frozen)
            XCTFail("An approval cannot retain a FIFO-evicted witness outside the registry")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let input = await backend.counts(); XCTAssertEqual(input.presses, 0); XCTAssertEqual(input.fills, 0)
        _ = await controller.shutdown()
    }

    func testInvalidCursorPreservesReferencesButAdmittedFailedContinuationRevokesThem() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
        let data = try argumentData(["click_ref": XCTUnwrap(publishedTargets[id]?[1]?.clickRef)])
        let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
        do { _ = try await call(controller, "browser_read", ["cursor": "unissued"]); XCTFail() }
        catch { assertNoncurrentReadCursor(error) }
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared)
        await backend.failObservations([.browserUnavailable("fixture read failure")])
        do { _ = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: first)]); XCTFail() }
        catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        do {
            _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared)
            XCTFail("Failed admitted continuation cannot revive earlier page authority")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0)
        _ = await controller.shutdown()
    }

    func testOriginalCaptureDeadlineSurvivesPaginationAndLockedMutationEnqueue() async throws {
        for boundary in ["preapproval", "continuation", "enqueue"] {
            let backend = EmbeddedBrowserFixtureBackend()
            let controller = EmbeddedBrowserToolController(transport: backend, readLifetime: .milliseconds(250))
            await backend.showManyControls()
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
            let data = try argumentData(["click_ref": XCTUnwrap(publishedTargets[id]?[1]?.clickRef)])
            let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: data)
            if boundary == "enqueue" {
                await backend.holdNextMutation()
                let task = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared) }
                await backend.waitUntilMutationHeld()
                try await Task.sleep(for: .milliseconds(280))
                await backend.resumeMutation()
                do { _ = try await task.value; XCTFail("An already queued mutation must check expiry at locked commit") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            } else {
                if boundary == "continuation" {
                    try await Task.sleep(for: .milliseconds(140))
                    _ = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: first)])
                    try await Task.sleep(for: .milliseconds(140))
                } else { try await Task.sleep(for: .milliseconds(280)) }
                do {
                    try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: data, prepared: prepared)
                    XCTFail("A retained witness keeps its original capture deadline")
                } catch {
                    let failure = try XCTUnwrap(error as? EmbeddedBrowserPreflightRecoveryFailure)
                    XCTAssertEqual(failure.original, .staleSnapshot)
                }
            }
            let counts = await backend.counts(); XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testDensePostInputPageContinuesWithoutLosingSendOrEarlierFieldReference() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls(count: 50, buttonLast: true); await backend.setButtonLabel("Send message")
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let initial = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(initial)
        let firstFill = try XCTUnwrap(publishedTargets[id]?[0]?.fillRef)
        let result = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill",
            arguments: argumentData(["fill_ref": firstFill, "text": "complete message"]))
        try assertCompleteActionObservation(result)
        var page = try availableObservation(result.response)
        let afterID = try snapshotID(page), retainedFill = try XCTUnwrap(publishedTargets[afterID]?.values.compactMap(\.fillRef).first)
        XCTAssertFalse(page.contains("label=\"Send message\""), "The fixture forces the distinct submit control onto a later page")
        var seen = Set<String>(), send: String?, pages = 0
        while true {
            let currentID = try snapshotID(page)
            for target in (publishedTargets[currentID] ?? [:]).values {
                if let label = target.label { XCTAssertTrue(seen.insert(label).inserted) }
                if target.label == "Send message" { send = target.clickRef }
            }
            guard let continuation = try actionReferenceMetadata(page)["continuation"] as? [String: Any] else { break }
            pages += 1; XCTAssertLessThan(pages, 20)
            page = try await call(controller, "browser_read", XCTUnwrap(continuation["arguments"] as? [String: Any]))
        }
        XCTAssertEqual(seen.count, 52)
        let fillData = try argumentData(["fill_ref": retainedFill, "text": "complete message"])
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill", arguments: fillData)
        let clicked = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click",
            arguments: argumentData(["click_ref": XCTUnwrap(send)]))
        try assertCompleteActionObservation(clicked)
        XCTAssertEqual(try jsonObject(XCTUnwrap(clicked.actionReceipt).compactText)["label"] as? String, "Send message")
        let counts = await backend.counts(); XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 1)
        _ = await controller.shutdown()
    }

    func testFrozenFillPreservesExactTextAndRejectsChangedInvocation() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(read)
        let ref = try XCTUnwrap(publishedTargets[id]?[0]?.fillRef), value = " e\u{301} UA 4629 "
        let data = try argumentData(["fill_ref": ref, "text": value])
        let approved = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_fill", arguments: data)
        XCTAssertEqual(Data((approved.canonicalArguments?["text"] as? String ?? "").utf8), Data(value.utf8))
        do {
            _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill",
                arguments: argumentData(["fill_ref": ref, "text": value.precomposedStringWithCanonicalMapping]), prepared: approved)
            XCTFail("A frozen approval cannot authorize modified fill bytes")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill", arguments: data, prepared: approved)
        let actual = await backend.fieldValue(); XCTAssertEqual(Data(actual.utf8), Data(value.utf8))
        _ = await controller.shutdown()
    }

    func testReferenceUsesExactExposedUnicodeFragmentAndValueOnlyContinuationHasNoReference() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let label = "UNEXPOSED_PREFIX " + String(repeating: "e\u{0301}👩‍💻\"\\\n ", count: 1_200) + " UNEXPOSED_SUFFIX"
        await backend.setButtonLabel(label)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"])
        let continued = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: first)])
        let id = try snapshotID(continued), row = try XCTUnwrap(publishedTargets[id]?.first { $0.value.role == "AXButton" })
        let fragment = try XCTUnwrap(row.value.label), ref = try XCTUnwrap(row.value.clickRef)
        XCTAssertFalse(fragment.contains("UNEXPOSED_PREFIX")); XCTAssertFalse(fragment.contains("UNEXPOSED_SUFFIX"))
        let prepared = try await controller.prepareMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": ref]))
        XCTAssertEqual(Data((prepared.canonicalArguments?["expected_label"] as? String ?? "").utf8), Data(fragment.utf8))
        XCTAssertNotEqual(Data(fragment.precomposedStringWithCanonicalMapping.utf8), Data(fragment.utf8))
        _ = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": ref]), prepared: prepared)
        await backend.setInitialField(String(repeating: "visible value ", count: 1_000))
        let valueFirst = try await call(controller, "browser_read", ["view": "all"])
        let valueTail = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: valueFirst)])
        let tailID = try snapshotID(valueTail), fieldRow = try XCTUnwrap(publishedTargets[tailID]?.first { $0.value.role == "AXTextField" })
        XCTAssertNil(fieldRow.value.label); XCTAssertNil(fieldRow.value.fillRef); XCTAssertNil(fieldRow.value.clickRef)
        _ = await controller.shutdown()
    }

    func testReferenceStoreIsBoundedAndEvictedUnknownRefsDoNotCapture() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let first = try await call(controller, "browser_read", ["view": "all"]), id = try snapshotID(first)
        let ref = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef)
        let firstCounts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
        let readsToEvictFirstPage = EmbeddedBrowserActionReferences.maximumRetired / max(1, firstCounts.current) + 2
        for _ in 0..<readsToEvictFirstPage { _ = try await call(controller, "browser_read", ["view": "all"]) }
        let counts = await controller.actionReferenceCountsForTesting(taskKey: "turn-a")
        XCTAssertLessThanOrEqual(counts.current, EmbeddedBrowserActionReferences.maximumCurrent)
        XCTAssertEqual(counts.retired, EmbeddedBrowserActionReferences.maximumRetired)
        let before = await backend.counts()
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: argumentData(["click_ref": ref]))
            XCTFail("Evicted refs grant no recovery lookup")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        let after = await backend.counts(); XCTAssertEqual(after, before)
        _ = await controller.shutdown()
    }

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
        // Opaque refs cannot be reconstructed by mixing previously observed
        // identifiers, nor corrected/normalized into another published input.
        let malformed: [String: Any] = ["fill_ref": "bfill_2EAB84FB-C48F-4313-BFB6-3C010A3E722D1", "text": "MUST_NOT_APPEAR"]
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill",
                arguments: argumentData(malformed))
            XCTFail("Malformed references must be rejected before approval")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        do { _ = try await call(controller, "browser_fill", malformed); XCTFail("Direct calls must reject the same malformed reference") }
        catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], key: "turn-b")
        let foreign = try await call(controller, "browser_read", key: "turn-b")
        do { _ = try await call(controller, "browser_fill", ["snapshot_id": snapshotID(foreign), "element_index": 0, "text": "MUST_NOT_APPEAR"]); XCTFail("Another task's issued reference cannot authorize this task") }
        catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        let denied = await backend.counts()
        XCTAssertEqual(denied.fills, 0); XCTAssertEqual(denied.presses, 0)
        XCTAssertEqual(denied.observes, before.observes + 2, "Only the separate task's binding/read may observe; denied references cannot reach mutation preflight")
        let arguments: [String: Any] = ["snapshot_id": id, "element_index": 0, "text": "UA 4629"]
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill",
            arguments: argumentData(arguments))
        let fill = try await call(controller, "browser_fill", arguments)
        let fresh = try availableObservation(fill)
        XCTAssertFalse(try XCTUnwrap(fresh.split(separator: "\n").first).contains("document_epoch="))
        XCTAssertNotEqual(try snapshotID(fresh), id)
        XCTAssertEqual(try field("tab_handle", in: fresh), try field("tab_handle", in: read))
        XCTAssertNotNil(publishedTargets[try snapshotID(fresh)]?[1]?.clickRef)
        XCTAssertNotNil(publishedTargets[try snapshotID(fresh)]?[0]?.fillRef)
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
        XCTAssertEqual(guidance, "Copy observed values verbatim, preserving Unicode and whitespace.")
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
        XCTAssertEqual(closed["literal_copy_guidance"] as? String, BrowserCompleteObservation.literalCopyGuidance)
        XCTAssertEqual(Set(closed.keys), ["released", "existing_user_tab_preserved", "literal_copy_guidance"])
        do { _ = try await call(controller, "browser_read"); XCTFail("Close must not provide a last snapshot or retain reading authority") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.closes, 1)
        _ = await controller.shutdown()
    }

    func testNewTurnReportsMissingBindingAndRecoversOnlyThroughAnExplicitFreshOpen() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let scope = ComputerTaskScope(userPrompt: "Use only http://127.0.0.1:63846 to send the requested test message.")
        _ = try await call(controller, "browser_open", ["url": "http://127.0.0.1:63846"], scope: scope)
        let old = try await call(controller, "browser_read", scope: scope)
        let released = await controller.releaseReport(taskKey: "turn-a")
        XCTAssertTrue(released.isSettled)
        let before = await backend.counts()
        for tool in ["browser_click", "browser_read"] {
            do {
                if tool == "browser_click" {
                    try await controller.preflightMutation(taskKey: "turn-b", tool: tool,
                        arguments: argumentData(["snapshot_id": try snapshotID(old), "element_index": 1]), scope: scope)
                } else { _ = try await call(controller, tool, key: "turn-b", scope: scope) }
                XCTFail("A new turn cannot inherit its previous binding")
            } catch let failure as EmbeddedBrowserBindingRequiredFailure {
                let state = try jsonObject(failure.localizedDescription)
                XCTAssertLessThan(failure.localizedDescription.utf8.count, 2_048)
                XCTAssertEqual((state["error"] as? [String: Any])?["code"] as? String, "browser_binding_required")
                XCTAssertEqual(state["binding_state"] as? String, "unbound_current_turn")
                XCTAssertEqual(state["inventory_evidence"] as? String, "not_observed")
                XCTAssertEqual(state["permission_evidence"] as? String, "not_assessed")
                XCTAssertEqual(state["dispatched"] as? Bool, false)
                XCTAssertTrue((state["next"] as? String)?.contains("previously observed URL") == true)
                XCTAssertTrue((state["next"] as? String)?.contains("subject to current user scope and approvals") == true)
            }
        }
        let rejected = await backend.counts()
        XCTAssertEqual(rejected, before, "Lifecycle guidance must not create, bind, observe or mutate anything")
        let inventory = try jsonObject(await call(controller, "browser_tabs", key: "turn-b", scope: scope))
        XCTAssertEqual(inventory["binding_state"] as? String, "unbound_current_turn")
        XCTAssertEqual(inventory["count"] as? Int, 0)
        XCTAssertTrue((inventory["next"] as? String)?.contains("including local URLs") == true)
        for tool in ["browser_click", "browser_fill"] {
            var input: [String: Any] = [tool == "browser_click" ? "click_ref" : "fill_ref": "unknown-reference"]
            if tool == "browser_fill" { input["text"] = "MUST_NOT_INPUT" }
            do {
                _ = try await controller.prepareMutation(taskKey: "turn-b", tool: tool, arguments: argumentData(input))
                XCTFail("Inventory alone cannot bind a page or resolve inputs")
            } catch { XCTAssertTrue(error is EmbeddedBrowserBindingRequiredFailure) }
        }
        _ = try await call(controller, "browser_open", ["url": "http://127.0.0.1:63846"], key: "turn-b", scope: scope)
        let current = try await call(controller, "browser_read", key: "turn-b", scope: scope)
        XCTAssertNotEqual(try field("tab_handle", in: current), try field("tab_handle", in: old))
        do {
            _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(old), "element_index": 1], key: "turn-b", scope: scope)
            XCTFail("New binding must not revive old references")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        let arguments: [String: Any] = ["snapshot_id": try snapshotID(current), "element_index": 0, "text": "UA 4629"]
        try await controller.preflightMutation(taskKey: "turn-b", tool: "browser_fill",
            arguments: argumentData(arguments), scope: scope)
        _ = try await call(controller, "browser_fill", arguments, key: "turn-b", scope: scope)
        let after = await backend.counts()
        XCTAssertEqual(after.creates, 2); XCTAssertEqual(after.closes, 1)
        XCTAssertEqual(after.fills, 1); XCTAssertEqual(after.presses, 0)
        // A genuinely retired key remains retired and never invites revival.
        do { _ = try await call(controller, "browser_read", key: "turn-a", scope: scope); XCTFail("Retired turns cannot recover authority") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing) }
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

    func testCompleteReadFailsBeforePublishingOverBudgetMetadataOrRevivingOldReferences() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let initial = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(initial), 0)
        await backend.setObservationSourceName(String(repeating: "x", count: 4_096))
        var output: String?
        do { output = try await call(controller, "browser_read", ["view": "all"]); XCTFail("A complete page cannot silently omit metadata") }
        catch {
            guard let failure = error as? BrowserTabBrokerError, case .outputLimit = failure else {
                return XCTFail("Expected a typed output limit from actual packing, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("bounded"))
            XCTAssertTrue(error.localizedDescription.contains("narrower view or query"))
        }
        XCTAssertNil(output)
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(initial), "element_index": 1]); XCTFail("Unpublished replacement cannot leave old input authority") }
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
        XCTAssertTrue((state["references"] as? String)?.contains("same capture") == true)
        XCTAssertEqual(state["consumed_by_admitted_input"] as? Bool, true)
        let id = try snapshotID(read)
        XCTAssertNotNil(publishedTargets[id]?[1]?.clickRef)
        XCTAssertNotNil(publishedTargets[id]?[0]?.fillRef)
        XCTAssertNil(publishedTargets[id]?[1]?.fillRef)
        XCTAssertNil(state["continuation"], "An exhausted read cannot invent a continuation")
        XCTAssertEqual(state["next_after_input"] as? String,
                       "Use current_observation or browser_read; never replay.")
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
                       "Copy observed values verbatim, preserving Unicode and whitespace.")
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
        let opened = try await controller.executeResult(taskKey: "turn-a", tool: "browser_open",
            arguments: argumentData(["url": "http://localhost:8123/flight"]))
        XCTAssertNil(opened.actionReceipt)
        XCTAssertFalse(opened.completeObservation)
        let read = try await controller.executeResult(taskKey: "turn-a", tool: "browser_read", arguments: Data("{}".utf8))
        XCTAssertNil(read.actionReceipt)
        XCTAssertTrue(read.completeObservation)
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(read.response), 0)
        let original = read.response
        let filled = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill",
            arguments: argumentData(["snapshot_id": snapshotID(original), "element_index": 0, "text": "UA 4629"]))
        XCTAssertTrue(filled.completeObservation)
        let fill = filled.response
        let compactFill = try XCTUnwrap(filled.actionReceipt?.compactText)
        let fillCue = try jsonObject(compactFill)
        XCTAssertEqual(fillCue["kind"] as? String, "fill")
        XCTAssertEqual(fillCue["label"] as? String, "Flight number")
        XCTAssertEqual(fillCue["partial"] as? Bool, false)
        XCTAssertEqual(fillCue["dispatched"] as? Bool, true)
        XCTAssertEqual(fillCue["outcome"] as? String, "unverified")
        XCTAssertEqual(Set(fillCue.keys), ["kind", "label", "partial", "dispatched", "outcome"])
        XCTAssertLessThanOrEqual(compactFill.utf8.count, 128)
        XCTAssertFalse(compactFill.contains("UA 4629"), "The dispatch cue never duplicates typed field content")
        let fillReceipt = try jsonObject(fill)
        XCTAssertEqual(fillReceipt["input_kind"] as? String, "fill")
        XCTAssertEqual(fillReceipt["dispatched"] as? Bool, true)
        XCTAssertEqual(fillReceipt["result_verified"] as? Bool, false)
        XCTAssertEqual(fillReceipt["no_replay"] as? Bool, true)
        let next = try XCTUnwrap(fillReceipt["next"] as? String)
        XCTAssertTrue(next.contains("Fill dispatched; no Enter or submit click"))
        XCTAssertTrue(next.contains("Page handlers may react"))
        XCTAssertTrue(next.contains("distinct submit action"))
        XCTAssertTrue(next.contains("do not repeat input"))
        XCTAssertFalse(next.contains("if the page is unchanged"))
        try assertCompleteActionObservation(filled)
        let fresh = try availableObservation(fill)
        XCTAssertTrue(fresh.contains("UA 4629"))
        XCTAssertNotEqual(try snapshotID(fresh), try snapshotID(original))
        do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(original), "element_index": 1]); XCTFail("Old action cannot be replayed") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let clicked = try await controller.executeResult(taskKey: "turn-a", tool: "browser_click",
            arguments: argumentData(["snapshot_id": snapshotID(fresh), "element_index": 1]))
        XCTAssertTrue(clicked.completeObservation)
        let click = clicked.response
        let compactClick = try XCTUnwrap(clicked.actionReceipt?.compactText)
        let clickCue = try jsonObject(compactClick)
        XCTAssertEqual(clickCue["kind"] as? String, "click")
        XCTAssertEqual(clickCue["label"] as? String, "Check flight")
        XCTAssertEqual(clickCue["partial"] as? Bool, false)
        XCTAssertEqual(clickCue["dispatched"] as? Bool, true)
        XCTAssertEqual(clickCue["outcome"] as? String, "unverified")
        XCTAssertLessThanOrEqual(compactClick.utf8.count, 128)
        let clickReceipt = try jsonObject(click)
        XCTAssertEqual(clickReceipt["input_kind"] as? String, "click")
        XCTAssertEqual(clickReceipt["result_verified"] as? Bool, false)
        XCTAssertEqual(clickReceipt["no_replay"] as? Bool, true)
        let clickNext = try XCTUnwrap(clickReceipt["next"] as? String)
        XCTAssertTrue(clickNext.contains("If unchanged, wait/read"))
        try assertCompleteActionObservation(clicked)
        XCTAssertFalse(clickNext.contains("no Enter key or submit-control click was sent"))
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

    func testCompactActionReceiptUsesOnlyCurrentPageExposedLabelBytesAndEscapedBudget() async throws {
        let backend = EmbeddedBrowserFixtureBackend()
        let label = "UNEXPOSED_PREFIX " + String(repeating: "👩‍💻\"\\\n-e\u{0301}-", count: 1_200) + " UNEXPOSED_SUFFIX"
        await backend.setButtonLabel(label)
        let broker = BrowserTabSessionBroker(transport: backend, browserGeneration: UUID(), ownership: .borrowed)
        let humanID = await backend.humanID
        let observedTarget = try await backend.target(id: humanID)
        let target = try XCTUnwrap(observedTarget)
        let bound = try await broker.bindBorrowed(taskKey: "receipt", processIdentifier: 42, target: target)
        let first = try await broker.snapshot(taskKey: "receipt", binding: bound,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let cursor = try XCTUnwrap(first.snapshot.nextCursor)
        let second = try await broker.snapshot(taskKey: "receipt", binding: first.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(cursor: cursor))
        let snapshot = second.snapshot
        let element = try XCTUnwrap(snapshot.elements.first { $0.backendNodeID == 2 })
        let exposure = try XCTUnwrap(snapshot.readReceipt?.exposures.first { $0.nodeID == "backend:2" && $0.field == .label })
        XCTAssertGreaterThan(exposure.startUTF8, 0)
        XCTAssertLessThan(exposure.endUTF8, label.utf8.count)
        XCTAssertEqual(element.label, label, "The retained source includes text the current page did not expose")
        let bytes = Array(label.utf8)
        let exposed = try XCTUnwrap(String(bytes: bytes[exposure.startUTF8..<exposure.endUTF8], encoding: .utf8))
        let receipt = try EmbeddedBrowserActionReceipt(kind: .click, snapshot: snapshot, elementIndex: element.index)
        let cue = try jsonObject(receipt.compactText)
        let fragment = try XCTUnwrap(cue["label"] as? String)
        XCTAssertFalse(fragment.isEmpty)
        XCTAssertTrue(exposed.hasPrefix(fragment))
        XCTAssertEqual(cue["partial"] as? Bool, true)
        XCTAssertEqual(cue["outcome"] as? String, "unverified")
        XCTAssertLessThanOrEqual(receipt.compactText.utf8.count, 128)
        XCTAssertFalse(receipt.compactText.contains("UNEXPOSED_PREFIX"))
        XCTAssertFalse(receipt.compactText.contains("UNEXPOSED_SUFFIX"))
        XCTAssertFalse(receipt.compactText.contains(snapshot.id.uuidString))
        // The receipt does not replace or broaden the ordinary current-page
        // capability. The actual admitted node still dispatches exactly once.
        try await broker.perform(taskKey: "receipt", binding: second.binding, snapshot: snapshot,
                                 elementIndex: element.index, action: "AXPress")
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 1)
        var missingExposure = snapshot
        missingExposure.readReceipt = nil
        let missing = try jsonObject(EmbeddedBrowserActionReceipt(kind: .click,
            snapshot: missingExposure, elementIndex: element.index).compactText)
        XCTAssertEqual(missing["label"] as? String, "")
        XCTAssertEqual(missing["partial"] as? Bool, true, "Missing exposure cannot resurrect the retained label")
        try await broker.revoke(taskKey: "receipt", binding: second.binding)
    }

    func testPostInputObservationFailuresPreserveDispatchAndExposeNoCapabilityOrPrivateError() async throws {
        for scenario in ["read_failed", "invalid_read", "redirect", "replaced", "protected"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Check http://localhost:8123/flight only.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let original = try await call(controller, "browser_read", scope: scope)
            await backend.configureAfterInput(scenario)
            let filled = try await controller.executeResult(taskKey: "turn-a", tool: "browser_fill", arguments:
                argumentData(["snapshot_id": snapshotID(original), "element_index": 0, "text": "UA 4629"]), scope: scope)
            let fill = filled.response
            let cue = try jsonObject(XCTUnwrap(filled.actionReceipt).compactText)
            XCTAssertEqual(cue["label"] as? String, "Flight number")
            XCTAssertEqual(cue["outcome"] as? String, "unverified", "A failed follow-up read cannot upgrade dispatch into verified outcome")
            let result = try jsonObject(fill)
            XCTAssertEqual(result["dispatched"] as? Bool, true, scenario)
            XCTAssertEqual(result["no_replay"] as? Bool, true)
            XCTAssertEqual(result["result_verified"] as? Bool, false)
            XCTAssertEqual(result["input_kind"] as? String, "fill")
            let next = try XCTUnwrap(result["next"] as? String)
            XCTAssertTrue(next.contains("no Enter key or submit-control click was sent"))
            XCTAssertTrue(next.contains("Do not repeat this input"))
            XCTAssertTrue(next.contains("Use browser_read for current evidence and new references"))
            let observation = try XCTUnwrap(result["current_observation"] as? [String: Any])
            XCTAssertEqual(observation["status"] as? String, "unavailable", scenario)
            let reasons = ["read_failed": "read_failed", "invalid_read": "invalid_read", "redirect": "scope_denied",
                           "replaced": "target_unavailable", "protected": "target_unavailable"]
            XCTAssertEqual(observation["reason"] as? String, reasons[scenario], scenario)
            XCTAssertFalse(fill.contains("read_not_authorized"), "An unavailable read cannot establish an authentication challenge")
            XCTAssertFalse(filled.completeObservation)
            XCTAssertNil(observation["snapshot_id"]); XCTAssertNil(observation["text"])
            XCTAssertFalse(fill.contains("PRIVATE_READ_ERROR")); XCTAssertFalse(fill.contains("AXSNAPSHOT"))
            do { _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(original), "element_index": 1], scope: scope); XCTFail("Failed observation must not resurrect consumed input") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            let counts = await backend.counts()
            XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0)
            if ["redirect", "replaced", "protected"].contains(scenario) {
                XCTAssertEqual(counts.observes, 3, "After-input target denial must precede another observation")
            } else {
                XCTAssertEqual(counts.observes, 4, "A generic read failure does not authorize a retry")
            }
            if scenario == "read_failed" {
                let fresh = try await call(controller, "browser_read", scope: scope)
                XCTAssertTrue(fresh.contains("UA 4629"), "Explicit later read can recover without refilling")
                let finalCounts = await backend.counts(); XCTAssertEqual(finalCounts.fills, 1)
            }
            _ = await controller.shutdown()
        }
    }

    func testPostInputReadRecoversOneNavigationRaceWithoutReplayingClickOrFill() async throws {
        for tool in ["browser_click", "browser_fill"] {
            for scenario in ["generation_drift", "drift_after_capture"] {
                let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
                let scope = ComputerTaskScope(userPrompt: "Use only http://localhost:8123/flight for the requested action.")
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
                let read = try await call(controller, "browser_read", ["view": "all"], scope: scope)
                let oldID = try snapshotID(read)
                var arguments: [String: Any] = ["snapshot_id": oldID, "element_index": tool == "browser_click" ? 1 : 0]
                if tool == "browser_fill" { arguments["text"] = "UA 4629" }
                await backend.configureAfterInput(scenario)
                let before = await backend.counts()
                let output = try await controller.executeResult(taskKey: "turn-a", tool: tool,
                    arguments: argumentData(arguments), scope: scope)
                let response = try jsonObject(output.response)
                let fresh = try availableObservation(output.response)
                XCTAssertNotEqual(try snapshotID(fresh), oldID)
                XCTAssertEqual(try field("tab_handle", in: fresh), try field("tab_handle", in: read))
                XCTAssertEqual(response["dispatched"] as? Bool, true)
                XCTAssertEqual(response["no_replay"] as? Bool, true)
                XCTAssertEqual(response["result_verified"] as? Bool, false)
                XCTAssertEqual(try jsonObject(XCTUnwrap(output.actionReceipt).compactText)["outcome"] as? String, "unverified")
                if scenario == "drift_after_capture" { XCTAssertTrue(fresh.contains("changed-after-capture")) }
                do { _ = try await call(controller, tool, arguments, scope: scope); XCTFail("The old input reference remains consumed") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
                let after = await backend.counts()
                XCTAssertEqual(after.observes - before.observes, 3, "One physical input preflight and exactly two post-input reads")
                XCTAssertEqual(after.presses, tool == "browser_click" ? 1 : 0)
                XCTAssertEqual(after.fills, tool == "browser_fill" ? 1 : 0)
                XCTAssertEqual(after.creates, 1); XCTAssertEqual(after.navigations, 0)
                _ = await controller.shutdown()
            }
        }
    }

    func testPostInputReadStopsAfterSecondNavigationRaceAndNeverRetriesOtherFailures() async throws {
        for scenario in ["generation_drift_twice", "generation_drift_offscope", "generation_drift_replaced",
                         "read_failed", "invalid_read"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Use only http://localhost:8123/flight for the requested action.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let read = try await call(controller, "browser_read", ["view": "all"], scope: scope)
            let oldID = try snapshotID(read)
            await backend.configureAfterInput(scenario)
            let before = await backend.counts()
            let output = try await call(controller, "browser_click", ["snapshot_id": oldID, "element_index": 1], scope: scope)
            let result = try jsonObject(output)
            let observation = try XCTUnwrap(result["current_observation"] as? [String: Any])
            XCTAssertEqual(observation["status"] as? String, "unavailable", scenario)
            XCTAssertNil(observation["snapshot_id"]); XCTAssertNil(observation["text"])
            XCTAssertEqual(result["dispatched"] as? Bool, true)
            XCTAssertEqual(result["no_replay"] as? Bool, true)
            XCTAssertEqual(result["result_verified"] as? Bool, false)
            XCTAssertFalse(output.contains("PRIVATE_READ_ERROR"))
            if scenario == "generation_drift_twice" { XCTAssertEqual(observation["reason"] as? String, "document_changed") }
            let after = await backend.counts()
            XCTAssertEqual(after.observes - before.observes, scenario == "generation_drift_twice" ? 3 : 2,
                "No third read; a changed scope/target or ordinary read failure prevents a second capture")
            XCTAssertEqual(after.presses, 1); XCTAssertEqual(after.fills, 0); XCTAssertEqual(after.navigations, 0)
            XCTAssertEqual(after.creates, 1, "Recovery cannot replace or rebind a tab")
            _ = await controller.shutdown()
        }
    }

    func testPostInputNavigationRecoveryCannotPublishAfterCancellationReleaseReplacementOrScopeChange() async throws {
        for attempt in [1, 2] {
            for change in ["cancel", "release", "replacement", "offscope"] {
                let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
                let scope = ComputerTaskScope(userPrompt: "Use only http://localhost:8123/flight for the requested action.")
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
                let read = try await call(controller, "browser_read", ["view": "all"], scope: scope)
                let input = try argumentData(["snapshot_id": snapshotID(read), "element_index": 1])
                await backend.configureAfterInput(attempt == 1 ? "hold_generation_drift" : "generation_drift_hold_retry")
                let before = await backend.counts()
                let operation = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: input, scope: scope) }
                await backend.waitUntilObservationHeld()
                if change == "cancel" { operation.cancel() }
                if change == "release" { _ = await controller.release(taskKey: "turn-a") }
                if change == "replacement" { await backend.replaceOwnedTarget() }
                if change == "offscope" { await backend.redirectOwnedTarget(to: URL(string: "https://unrelated.example/PRIVATE_READ_ERROR")!) }
                await backend.resumeObservation()
                let execution = try await operation.value
                let result = try jsonObject(execution.response)
                let observation = try XCTUnwrap(result["current_observation"] as? [String: Any])
                XCTAssertEqual(observation["status"] as? String, "unavailable", "\(attempt):\(change)")
                XCTAssertNil(observation["snapshot_id"]); XCTAssertNil(observation["text"])
                XCTAssertEqual(result["dispatched"] as? Bool, true)
                XCTAssertEqual(result["result_verified"] as? Bool, false)
                XCTAssertEqual(try jsonObject(XCTUnwrap(execution.actionReceipt).compactText)["outcome"] as? String, "unverified")
                XCTAssertFalse(execution.response.contains("PRIVATE_READ_ERROR"))
                let after = await backend.counts()
                XCTAssertEqual(after.observes - before.observes, attempt + 1, "No recovery may continue past its cancelled/replaced lease or scope")
                XCTAssertEqual(after.presses, 1); XCTAssertEqual(after.fills, 0); XCTAssertEqual(after.navigations, 0)
                _ = await controller.shutdown()
            }
        }
    }

    func testPostInputRecoveryCancellationDuringFinalTargetCheckCannotPublishSnapshot() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        let input = try argumentData(["snapshot_id": snapshotID(read), "element_index": 1])
        await backend.configureAfterInput("generation_drift_hold_publication")
        let before = await backend.counts()
        let operation = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_click", arguments: input) }
        await backend.waitUntilFinalTargetHeld()
        operation.cancel()
        await backend.resumeFinalTarget()
        let output = try await operation.value
        let response = try jsonObject(output.response)
        let observation = try XCTUnwrap(response["current_observation"] as? [String: Any])
        XCTAssertEqual(response["dispatched"] as? Bool, true)
        XCTAssertEqual(response["result_verified"] as? Bool, false)
        XCTAssertEqual(observation["status"] as? String, "unavailable")
        XCTAssertEqual(observation["reason"] as? String, "cancelled")
        XCTAssertNil(observation["snapshot_id"]); XCTAssertNil(observation["text"])
        let counts = await backend.counts()
        XCTAssertEqual(counts.observes - before.observes, 3)
        XCTAssertEqual(counts.presses, 1)
        _ = await controller.shutdown()
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
        XCTAssertTrue(description.contains("When text is omitted, wait for readable text or controls outside the footer after document readiness"))
        XCTAssertTrue(description.contains("a title-only, empty or footer-only shell is not ready"))
        XCTAssertTrue(description.contains("This readiness is not proof that requested content exists"))
        XCTAssertTrue(description.contains("Does not refresh or replay actions"))
        let schema = try XCTUnwrap(wait["inputSchema"] as? [String: Any])
        XCTAssertFalse((schema["required"] as? [String] ?? []).contains("text"))
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let omission = try XCTUnwrap(properties["text"]?["description"] as? String)
        XCTAssertTrue(omission.contains("Omit text to wait for readable text or controls outside the footer after document readiness"))
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setSemanticReadiness(.ready)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let read = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertEqual(try field("semantic_readiness", in: read), "ready")
        XCTAssertEqual(read.components(separatedBy: "semantic_readiness=").count - 1, 1)
        XCTAssertTrue(read.contains("Check flight"))
        XCTAssertTrue(read.contains("not website search or proof of relevance/absence"), "Readiness is not task success or document relevance")
        let id = try snapshotID(read)
        XCTAssertNotNil(publishedTargets[id]?[1]?.clickRef)
        XCTAssertNotNil(publishedTargets[id]?[0]?.fillRef)
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
        XCTAssertTrue(empty.contains("READINESS deadline reached without qualifying content"))
        XCTAssertTrue(empty.contains("search completion and absence remain unverified"))
        XCTAssertTrue(empty.contains("source_nodes=0")); XCTAssertTrue(empty.contains("no_matches=1"))
        XCTAssertTrue(empty.contains("not website search or proof of relevance/absence"))
        XCTAssertNotEqual(try snapshotID(empty), try snapshotID(first))
        XCTAssertFalse(empty.contains("click_ref=")); XCTAssertFalse(empty.contains("fill_ref="))
        do {
            _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(first), "element_index": 1])
            XCTFail("An empty read retires previously published inputs")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        do {
            _ = try await call(controller, "browser_click", ["click_ref": "unpublished-reference"])
            XCTFail("Readiness metadata cannot create input authority")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        await backend.setSemanticReadiness(.ready)
        let fresh = try await call(controller, "browser_read", ["view": "all"])
        XCTAssertEqual(try field("semantic_readiness", in: fresh), "ready")
        XCTAssertEqual(try field("tab_handle", in: fresh), try field("tab_handle", in: first))
        XCTAssertTrue(fresh.contains("Check flight"), "A later read may expose new ordinary content under the same lease")
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.navigations, 0)
        _ = await controller.shutdown()
    }

    func testLinksViewExplainsOmittedControlsWithoutClaimingThatAnyExist() async throws {
        for hasLink in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            if hasLink { await backend.setLink("http://localhost:8123/terms") }
            let links = try await call(controller, "browser_read", ["view": "links"])
            let lines = links.split(separator: "\n")
            XCTAssertTrue(lines[1].hasPrefix("READ view=links"))
            XCTAssertTrue(links.contains("VIEW links omitted_input_nodes=2 basis=captured_view_and_query. Read overview/all without cursor/query for controls before an access-block claim."))
            XCTAssertTrue(links.contains("not website search or proof of relevance/absence"))
            XCTAssertFalse(links.contains("label=\"Check flight\"")); XCTAssertFalse(links.contains("label=\"Flight number\""))
            if !hasLink { XCTAssertTrue(links.contains("no_matches=1")) }
            let overview = try await call(controller, "browser_read", ["view": "overview"])
            XCTAssertFalse(overview.contains("LINK_VIEW_SCOPE")); XCTAssertTrue(overview.contains("label=\"Check flight\""))
            let counts = await backend.counts()
            XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.navigations, 0)
            _ = await controller.shutdown()
        }
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

    func testFreshReadAuthorizesSettledMetadataBeforeAnyPageCapture() async throws {
        for settlesAllowed in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Read http://localhost:8123/flight only.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            await backend.redirectOwnedTarget(to: URL(string: "https://unrelated.example/transient")!)
            await backend.prepareFreshRead(settlingAt: settlesAllowed ? URL(string: "http://localhost:8123/result")! : nil)
            let before = await backend.counts()
            do {
                let page = try await call(controller, "browser_read", scope: scope)
                XCTAssertTrue(settlesAllowed)
                XCTAssertTrue(page.contains("http://localhost:8123/result"))
            } catch {
                XCTAssertFalse(settlesAllowed)
                guard let failure = error as? BrowserTabBrokerError, case .scopeDenied = failure else {
                    XCTFail("Expected a scope rejection before capture, got \(error)"); continue
                }
            }
            let after = await backend.counts(), admissions = await backend.readAdmissionCounts()
            XCTAssertEqual(admissions.preparations, 1, "Reuse the single fresh-read preparation")
            XCTAssertEqual(admissions.admissions, settlesAllowed ? 1 : 0)
            XCTAssertEqual(after.observes - before.observes, settlesAllowed ? 1 : 0)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testPostInputReadSettlesScopeWithoutReplayingClickOrFill() async throws {
        for tool in ["browser_click", "browser_fill"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Use only http://localhost:8123/flight for the requested action.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            let page = try await call(controller, "browser_read", scope: scope)
            var arguments: [String: Any] = ["snapshot_id": try snapshotID(page), "element_index": tool == "browser_click" ? 1 : 0]
            if tool == "browser_fill" { arguments["text"] = "UA 4629" }
            await backend.configureAfterInput("transient_scope")
            let before = await backend.counts(), beforeAdmissions = await backend.readAdmissionCounts()
            let output = try await controller.executeResult(taskKey: "turn-a", tool: tool,
                arguments: argumentData(arguments), scope: scope)
            let observation = try availableObservation(output.response), response = try jsonObject(output.response)
            XCTAssertTrue(observation.contains("http://localhost:8123/result"))
            XCTAssertEqual(response["dispatched"] as? Bool, true)
            XCTAssertEqual(response["no_replay"] as? Bool, true)
            XCTAssertEqual(response["result_verified"] as? Bool, false)
            let after = await backend.counts(), admissions = await backend.readAdmissionCounts()
            XCTAssertEqual(admissions.preparations - beforeAdmissions.preparations, 1)
            XCTAssertEqual(admissions.admissions - beforeAdmissions.admissions, 1)
            XCTAssertEqual(after.observes - before.observes, 2, "One input preflight and one settled post-input capture")
            XCTAssertEqual(after.presses, tool == "browser_click" ? 1 : 0)
            XCTAssertEqual(after.fills, tool == "browser_fill" ? 1 : 0)
            _ = await controller.shutdown()
        }
    }

    func testPostCaptureNavigationUsesOnlyExistingReadRecoveryAndPreservesScope() async throws {
        for tool in ["browser_click", "browser_fill"] {
            for scenario in ["post_capture_scope_settles", "post_capture_scope_permanent",
                             "post_capture_scope_twice", "post_capture_outscope_document"] {
                let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
                let scope = ComputerTaskScope(userPrompt: "Use only http://localhost:8123/flight for the requested action.")
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
                let page = try await call(controller, "browser_read", scope: scope)
                var arguments: [String: Any] = ["snapshot_id": try snapshotID(page), "element_index": tool == "browser_click" ? 1 : 0]
                if tool == "browser_fill" { arguments["text"] = "UA 4629" }
                await backend.configureAfterInput(scenario)
                let before = await backend.counts(), beforeAdmissions = await backend.readAdmissionCounts()
                let output = try await controller.executeResult(taskKey: "turn-a", tool: tool,
                    arguments: argumentData(arguments), scope: scope)
                let response = try jsonObject(output.response)
                let observation = try XCTUnwrap(response["current_observation"] as? [String: Any])
                XCTAssertEqual(response["dispatched"] as? Bool, true, scenario)
                XCTAssertEqual(response["no_replay"] as? Bool, true)
                XCTAssertEqual(response["result_verified"] as? Bool, false)
                if scenario == "post_capture_scope_settles" {
                    XCTAssertEqual(observation["status"] as? String, "available")
                    let text = try XCTUnwrap(observation["text"] as? String)
                    XCTAssertTrue(text.contains("http://localhost:8123/settled-after-capture"))
                    XCTAssertTrue(output.completeObservation)
                } else {
                    XCTAssertEqual(observation["status"] as? String, "unavailable", scenario)
                    XCTAssertEqual(observation["reason"] as? String,
                        scenario == "post_capture_scope_twice" ? "document_changed" : "scope_denied", scenario)
                    XCTAssertNil(observation["text"]); XCTAssertNil(observation["snapshot_id"])
                    XCTAssertFalse(output.completeObservation)
                }
                XCTAssertFalse(output.response.contains("PRIVATE_POST_CAPTURE_ROUTE"))
                let after = await backend.counts(), admissions = await backend.readAdmissionCounts()
                let captureDenied = scenario == "post_capture_scope_permanent"
                let capturedOutscope = scenario == "post_capture_outscope_document"
                XCTAssertEqual(admissions.preparations - beforeAdmissions.preparations, capturedOutscope ? 1 : 2)
                XCTAssertEqual(admissions.admissions - beforeAdmissions.admissions, captureDenied || capturedOutscope ? 1 : 2)
                XCTAssertEqual(after.observes - before.observes, captureDenied || capturedOutscope ? 2 : 3,
                    "One input preflight, at most two post-input captures, and no capture after a denied retry gate")
                XCTAssertEqual(after.presses, tool == "browser_click" ? 1 : 0)
                XCTAssertEqual(after.fills, tool == "browser_fill" ? 1 : 0)
                XCTAssertEqual(after.creates, 1); XCTAssertEqual(after.navigations, 0)
                _ = await controller.shutdown()
            }
        }
    }

    func testFreshReadGateRejectsCancellationReleaseReplacementAndScopeChangeBeforeCapture() async throws {
        for change in ["cancel", "release", "replacement", "offscope"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Read http://localhost:8123/flight only.")
            if change == "release" {
                _ = try await call(controller, "browser_tabs", scope: scope)
                _ = try await call(controller, "browser_bind", ["tab_id": await backend.humanID], scope: scope)
            } else {
                _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            }
            await backend.prepareFreshRead(hold: true)
            let before = await backend.counts()
            let operation = Task { try await controller.execute(taskKey: "turn-a", tool: "browser_read",
                arguments: Data("{}".utf8), scope: scope) }
            await backend.waitUntilFreshReadHeld()
            if change == "cancel" { operation.cancel() }
            if change == "release" { _ = await controller.release(taskKey: "turn-a") }
            if change == "replacement" { await backend.replaceOwnedTarget() }
            if change == "offscope" { await backend.redirectOwnedTarget(to: URL(string: "https://unrelated.example/private")!) }
            await backend.resumeFreshRead()
            do { _ = try await operation.value; XCTFail("Retired or unauthorized read must not publish: \(change)") }
            catch { /* The gate propagates the exact cancellation, lease, target, or scope rejection. */ }
            let after = await backend.counts(), admissions = await backend.readAdmissionCounts()
            XCTAssertEqual(admissions.preparations, 1); XCTAssertEqual(admissions.admissions, 0)
            XCTAssertEqual(after.observes, before.observes, change)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            if change == "release" {
                let preserved = try await backend.target(id: backend.humanID)
                XCTAssertNotNil(preserved, "The revoked lease must deny capture even when the user's physical tab survives")
            }
            _ = await controller.shutdown()
        }
    }

    func testRetainedReadAndMutationKeepImmediateScopePreflight() async throws {
        for tool in ["browser_read", "browser_click"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            let scope = ComputerTaskScope(userPrompt: "Read http://localhost:8123/flight only.")
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"], scope: scope)
            await backend.showManyControls()
            let page = try await call(controller, "browser_read", ["view": "all"], scope: scope)
            let arguments: [String: Any] = tool == "browser_read"
                ? ["cursor": try field("next_cursor", in: page)]
                : ["snapshot_id": try snapshotID(page), "element_index": 1]
            let before = await backend.counts(), beforeAdmissions = await backend.readAdmissionCounts()
            await backend.redirectOwnedTarget(to: URL(string: "https://unrelated.example/transient")!)
            await backend.prepareFreshRead(settlingAt: URL(string: "http://localhost:8123/result")!)
            do { _ = try await call(controller, tool, arguments, scope: scope); XCTFail("Retained authority must not follow a provisional route") }
            catch {
                guard let failure = error as? BrowserTabBrokerError, case .scopeDenied = failure else {
                    XCTFail("Expected immediate scope rejection, got \(error)"); continue
                }
            }
            let after = await backend.counts(), admissions = await backend.readAdmissionCounts()
            XCTAssertEqual(admissions.preparations, beforeAdmissions.preparations)
            XCTAssertEqual(after.observes, before.observes)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
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
                else if let failure = error as? BrowserTabBrokerError, case .scopeDenied = failure { /* Scope still rejects the redirect. */ }
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
        for tool in ["browser_read", "browser_continue"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            let first = try await call(controller, "browser_read", ["view": "all"])
            let cursor = try field("next_cursor", in: first)
            XCTAssertNotEqual(cursor, "none")
            let before = await backend.counts()
            await backend.failObservations([.staleDocument])
            do { _ = try await call(controller, tool, ["cursor": cursor]); XCTFail("A stale continuation cannot become a new read") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleDocument) }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testCompletedReadOffersNoPlaceholderCursorAndInventedNoneStillRejectsWithoutDispatch() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let output = try await call(controller, "browser_read", ["view": "all"])
        let read = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("READ ") })
        XCTAssertFalse(read.contains("next_cursor=")); XCTAssertTrue(read.contains("output_truncated=0"))
        XCTAssertNil(try actionReferenceMetadata(output)["continuation"])
        let before = await backend.counts()
        do {
            _ = try await call(controller, "browser_read", ["cursor": "none"])
            XCTFail("Removing the placeholder must not make a guessed cursor a fresh read")
        } catch { assertNoncurrentReadCursor(error) }
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes)
        XCTAssertEqual(after.presses, before.presses); XCTAssertEqual(after.fills, before.fills)
        _ = await controller.shutdown()
    }

    func testReadContinuationMetadataNamesOnlyItsExactCursorAndPreservesCapturedFilters() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.showManyControls()
        let first = try await call(controller, "browser_read", ["view": "overview", "query": "Extra control"])
        let metadata = try actionReferenceMetadata(first)
        let continuation = try XCTUnwrap(metadata["continuation"] as? [String: Any])
        XCTAssertEqual(Set(continuation.keys), ["arguments"])
        XCTAssertNil(continuation["tool"], "The native page must not prescribe a tool absent from a saved catalog")
        let arguments = try XCTUnwrap(continuation["arguments"] as? [String: Any])
        XCTAssertEqual(Set(arguments.keys), ["cursor"], "Do not suggest a new view/query beside a retained cursor")
        XCTAssertEqual(arguments["cursor"] as? String, try field("next_cursor", in: first))
        let next = try await call(controller, "browser_read", arguments)
        XCTAssertEqual(try field("source_observation", in: next), try field("source_observation", in: first))
        XCTAssertEqual(try field("view", in: next), "overview")
        XCTAssertTrue(next.contains("Extra control")); XCTAssertFalse(next.contains("Flight number"))
        XCTAssertNotEqual(try snapshotID(next), try snapshotID(first))
        let originalID = try snapshotID(first)
        let retainedRef = try XCTUnwrap(publishedTargets[originalID]?[0]?.clickRef)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
            arguments: argumentData(["click_ref": retainedRef]))
        let nextMetadata = try actionReferenceMetadata(next)
        let nextContinuation = try XCTUnwrap(nextMetadata["continuation"] as? [String: Any])
        var wrongArguments = try XCTUnwrap(nextContinuation["arguments"] as? [String: Any])
        wrongArguments["view"] = "content"
        do {
            _ = try await call(controller, "browser_read", wrongArguments)
            XCTFail("Metadata does not normalize or admit changed cursor filters")
        } catch {
            guard let failure = error as? EmbeddedBrowserPreflightRecoveryFailure,
                  case .invalidRead = failure.original else {
                return XCTFail("Expected filter rejection with separate read, got \(error)")
            }
            let observation = try XCTUnwrap(jsonObject(failure.observationResponse)["current_observation"] as? [String: Any])
            XCTAssertEqual(observation["view"] as? String, "content")
        }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = await controller.shutdown()
    }

    func testChangedContinuationFiltersReturnOneSeparateRequestedReadWithoutInput() async throws {
        for changedFilter in [["view": "content"], ["query": "Check flight"], ["view": "content", "query": "Result marker"]] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            await backend.setObservedResult("Result marker: an actual body paragraph")
            let first = try await call(controller, "browser_read", ["view": "overview", "query": "Extra control"])
            let cursor = try field("next_cursor", in: first)
            let before = await backend.counts()
            var invalid: [String: Any] = changedFilter
            invalid["cursor"] = cursor
            let rejected = try await changedFilterFailure(controller, arguments: invalid)
            let response = try jsonObject(rejected.observationResponse)
            XCTAssertEqual(response["success"] as? Bool, false)
            XCTAssertEqual(response["dispatched"] as? Bool, false)
            XCTAssertEqual(response["no_replay"] as? Bool, true)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "continuation_filters_changed")
            let observed = try XCTUnwrap(response["current_observation"] as? [String: Any])
            XCTAssertEqual(observed["status"] as? String, "available")
            XCTAssertEqual(observed["view"] as? String, changedFilter["view"] ?? "overview")
            let fresh = try XCTUnwrap(observed["text"] as? String)
            XCTAssertNotEqual(try field("source_observation", in: first), try field("source_observation", in: fresh))
            XCTAssertNotEqual(try snapshotID(first), try snapshotID(fresh))
            XCTAssertEqual(try field("view", in: fresh), changedFilter["view"] ?? "overview")
            XCTAssertTrue(fresh.contains(changedFilter["query"] ?? "Result marker"))
            XCTAssertFalse(fresh.contains("label=\"Extra control"), "Omitted old query must not leak into the requested fresh view")
            try assertCompleteRecovery(rejected, kind: "read", reason: "continuation_filters_changed")
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            do {
                _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(first), "element_index": 0])
                XCTFail("The separate fresh read supersedes old action references")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            do {
                _ = try await call(controller, "browser_read", invalid)
                XCTFail("The prior cursor is no longer current")
            } catch { assertNoncurrentReadCursor(error) }
            let repeated = await backend.counts()
            XCTAssertEqual(repeated.observes, after.observes, "A retired cursor does not grant another recovery read")
            _ = await controller.shutdown()
        }
    }

    func testCompoundRecoveryPagesEveryPublishedRowWithinAtomicBudgetWithoutRecaptureOrInput() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.showManyControls(count: 36)
        let first = try await call(controller, "browser_read", ["view": "overview"])
        let before = await backend.counts()
        let failure = try await changedFilterFailure(controller,
            arguments: ["cursor": field("next_cursor", in: first), "view": "all", "query": "Extra control"])
        try assertCompleteRecovery(failure, kind: "read", reason: "continuation_filters_changed")
        let body = try jsonObject(failure.observationResponse)
        XCTAssertEqual(body["dispatched"] as? Bool, false)
        let recovery = try XCTUnwrap(body["current_observation"] as? [String: Any])
        XCTAssertEqual(recovery["source"] as? String, "separate_recovery_read")
        XCTAssertEqual(recovery["view"] as? String, "all")
        var page = try XCTUnwrap(recovery["text"] as? String)
        let source = try field("source_observation", in: page)
        var labels = [String](), pages = 0
        while true {
            pages += 1
            XCTAssertLessThan(pages, 36)
            XCTAssertEqual(try field("source_observation", in: page), source)
            for raw in page.split(separator: "\n") where raw.hasPrefix("#") {
                if let label = try publishedString("label", in: String(raw)), label.hasPrefix("Extra control") {
                    labels.append(label)
                }
            }
            let metadata = try actionReferenceMetadata(page)
            guard let continuation = metadata["continuation"] as? [String: Any],
                  let arguments = continuation["arguments"] as? [String: Any] else { break }
            page = try await call(controller, "browser_read", arguments)
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(labels.count, 36); XCTAssertEqual(Set(labels).count, 36, "Pagination must not skip or duplicate a row")
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes + pages, "Packing retries reuse one capture; continuation retains its usual immediate validation")
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
    }

    func testOversizedRecoveryMetadataKeepsFailureUnmarkedWithoutExtraReadOrInput() async throws {
        for tool in ["browser_read", "browser_click", "browser_fill"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            let old = try await call(controller, "browser_read", ["view": "overview"])
            if tool != "browser_read" { _ = try await call(controller, "browser_read", ["view": "overview"]) }
            await backend.setObservationSourceName(String(repeating: "x", count: 4_096))
            let before = await backend.counts()
            let failure: EmbeddedBrowserPreflightRecoveryFailure
            if tool == "browser_read" {
                failure = try await changedFilterFailure(controller,
                    arguments: ["cursor": field("next_cursor", in: old), "view": "all"])
            } else {
                var arguments: [String: Any] = ["snapshot_id": try snapshotID(old), "element_index": tool == "browser_fill" ? 0 : 1]
                if tool == "browser_fill" { arguments["text"] = "MUST_NOT_FILL" }
                failure = try await stalePreflight(controller, tool: tool, arguments: arguments)
            }
            XCTAssertNil(failure.rejectionReceipt)
            let body = try jsonObject(failure.observationResponse)
            XCTAssertEqual(body["success"] as? Bool, false); XCTAssertEqual(body["dispatched"] as? Bool, false)
            let observation = try XCTUnwrap(body["current_observation"] as? [String: Any])
            XCTAssertEqual(observation["status"] as? String, "unavailable")
            XCTAssertEqual(observation["reason"] as? String, "output_limit")
            XCTAssertNil(observation["text"]); XCTAssertNil(observation["snapshot_id"])
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    private func assertCompleteRecovery(_ failure: EmbeddedBrowserPreflightRecoveryFailure,
                                        kind: String, reason: String,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let cue = try XCTUnwrap(failure.rejectionReceipt?.compactText, file: file, line: line)
        let items = [BrowserCompleteObservation.marker, cue, failure.observationResponse]
            .map { ["type": "inputText", "text": $0] }
        XCTAssertLessThanOrEqual(items.reduce(2) { $0 + $1["text", default: ""].utf8.count }, 4_096, file: file, line: line)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: items).count, 4_608, file: file, line: line)
        let rejection = try jsonObject(cue)
        XCTAssertEqual(rejection["kind"] as? String, kind, file: file, line: line)
        XCTAssertEqual(rejection["reason"] as? String, reason, file: file, line: line)
        XCTAssertEqual(rejection["dispatched"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(rejection["outcome"] as? String, "unverified", file: file, line: line)
        let body = try jsonObject(failure.observationResponse)
        XCTAssertEqual(body["success"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(body["result_verified"] as? Bool, false, file: file, line: line)
        XCTAssertNil((body["error"] as? [String: Any])?["message"], "Original diagnostic remains on the local error", file: file, line: line)
    }

    func testFailedChangedFilterReadPreservesValidSnapshotAndCannotRetryRecovery() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.showManyControls()
        let first = try await call(controller, "browser_read", ["view": "overview"])
        let cursor = try field("next_cursor", in: first)
        let before = await backend.counts()
        await backend.failObservations([.browserUnavailable("PRIVATE_RECOVERY_ERROR")])
        let invalid: [String: Any] = ["cursor": cursor, "view": "content"]
        let rejected = try await changedFilterFailure(controller, arguments: invalid)
        let unavailable = try XCTUnwrap(jsonObject(rejected.observationResponse)["current_observation"] as? [String: Any])
        XCTAssertEqual(unavailable["status"] as? String, "unavailable")
        XCTAssertEqual(unavailable["reason"] as? String, "read_failed")
        XCTAssertNil(unavailable["text"]); XCTAssertNil(unavailable["snapshot_id"])
        XCTAssertFalse(rejected.observationResponse.contains("PRIVATE_RECOVERY_ERROR"))
        XCTAssertNil(rejected.rejectionReceipt, "An unavailable read cannot claim a complete observation")
        let repeated = try await changedFilterFailure(controller, arguments: invalid)
        XCTAssertEqual((try jsonObject(repeated.observationResponse)["current_observation"] as? [String: Any])?["reason"] as? String, "recovery_already_attempted")
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes + 1)
        // Both the controller and broker keep the exact old capture on failure.
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
            arguments: argumentData(["snapshot_id": try snapshotID(first), "element_index": 1]))
        let continued = try await call(controller, "browser_read", ["cursor": cursor])
        XCTAssertEqual(try field("source_observation", in: continued), try field("source_observation", in: first))
        let final = await backend.counts()
        XCTAssertEqual(final.presses, 0); XCTAssertEqual(final.fills, 0)
        _ = await controller.shutdown()
    }

    func testChangedFilterRecoveryRejectsForeignExpiredAndNavigatedCursors() async throws {
        for scenario in ["foreign", "expired", "navigated", "replaced", "reloaded"] {
            let backend = EmbeddedBrowserFixtureBackend()
            let controller = EmbeddedBrowserToolController(transport: backend,
                readLifetime: scenario == "expired" ? .zero : .seconds(120))
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            let first = try await call(controller, "browser_read", ["view": "overview"])
            let cursor = scenario == "foreign" ? UUID().uuidString : (try field("next_cursor", in: first))
            if scenario == "navigated" { await backend.redirectOwnedTarget(to: URL(string: "http://localhost:8123/new-page")!) }
            if scenario == "replaced" { await backend.replaceOwnedTarget() }
            if scenario == "reloaded" { await backend.reloadDocument() }
            let before = await backend.counts()
            do {
                _ = try await call(controller, "browser_read", ["cursor": cursor, "view": "content"])
                XCTFail("An inadmissible cursor must not publish a fresh view")
            } catch let failure as EmbeddedBrowserPreflightRecoveryFailure {
                let observed = try XCTUnwrap(jsonObject(failure.observationResponse)["current_observation"] as? [String: Any])
                XCTAssertEqual(observed["status"] as? String, "unavailable", scenario)
                XCTAssertNil(observed["snapshot_id"]); XCTAssertNil(observed["text"])
            } catch {
                if scenario == "foreign" { assertNoncurrentReadCursor(error) }
                else { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot, scenario) }
            }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + (scenario == "reloaded" ? 1 : 0), scenario)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testChangedFilterRecoveryIsLimitedToThreeSeparateReadsPerTurn() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.showManyControls()
        for attempt in 0..<4 {
            let overview = try await call(controller, "browser_read", ["view": "overview"])
            let before = await backend.counts()
            let rejected = try await changedFilterFailure(controller,
                arguments: ["cursor": field("next_cursor", in: overview), "view": "content"])
            let observed = try XCTUnwrap(jsonObject(rejected.observationResponse)["current_observation"] as? [String: Any])
            XCTAssertEqual(observed["status"] as? String, attempt < 3 ? "available" : "unavailable")
            if attempt == 3 { XCTAssertEqual(observed["reason"] as? String, "recovery_limit") }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + (attempt < 3 ? 1 : 0))
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        }
        _ = await controller.shutdown()
    }

    func testChangedFilterRecoveryCannotPublishAfterCancellationOrRelease() async throws {
        for cancelled in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            let overview = try await call(controller, "browser_read", ["view": "overview"])
            let cursor = try field("next_cursor", in: overview)
            await backend.holdNextRead()
            let operation = Task { try await self.changedFilterFailure(controller, arguments: ["cursor": cursor, "view": "content"]) }
            await backend.waitUntilObservationHeld()
            if cancelled { operation.cancel() } else { _ = await controller.release(taskKey: "turn-a") }
            await backend.resumeObservation()
            if cancelled {
                do { _ = try await operation.value; XCTFail("Cancellation must not publish references") }
                catch { XCTAssertTrue(error is CancellationError) }
            } else {
                let rejected = try await operation.value
                let observed = try XCTUnwrap(jsonObject(rejected.observationResponse)["current_observation"] as? [String: Any])
                XCTAssertEqual(observed["status"] as? String, "unavailable")
                XCTAssertNil(observed["snapshot_id"]); XCTAssertNil(observed["text"])
            }
            let counts = await backend.counts()
            XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testChangedFilterAndStaleActionRecoveryShareTheExistingTurnReadBudget() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        await backend.showManyControls()
        for _ in 0..<2 {
            let overview = try await call(controller, "browser_read", ["view": "overview"])
            _ = try await changedFilterFailure(controller,
                arguments: ["cursor": field("next_cursor", in: overview), "view": "content"])
        }
        let old = try await call(controller, "browser_read", ["view": "overview"])
        let new = try await call(controller, "browser_read", ["view": "overview"])
        let third = try await stalePreflight(controller,
            arguments: ["snapshot_id": snapshotID(old), "element_index": 1])
        XCTAssertEqual((try jsonObject(third.observationResponse)["current_observation"] as? [String: Any])?["status"] as? String, "available")
        let before = await backend.counts()
        let fourth = try await stalePreflight(controller,
            arguments: ["snapshot_id": snapshotID(new), "element_index": 1])
        XCTAssertEqual((try jsonObject(fourth.observationResponse)["current_observation"] as? [String: Any])?["reason"] as? String, "recovery_limit")
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes)
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        _ = await controller.shutdown()
    }

    private func changedFilterFailure(_ controller: EmbeddedBrowserToolController,
                                       arguments: [String: Any]) async throws -> EmbeddedBrowserPreflightRecoveryFailure {
        do {
            _ = try await call(controller, "browser_read", arguments)
            XCTFail("A changed-filter continuation must remain a failed request")
            throw BrowserTabBrokerError.invalidRead("Expected changed-filter rejection")
        } catch let failure as EmbeddedBrowserPreflightRecoveryFailure { return failure }
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
                let continuation = try XCTUnwrap(try actionReferenceMetadata(fresh)["continuation"] as? [String: Any])
                XCTAssertNil(continuation["tool"], "The exact arguments work with the admitted continuation tool")
                let arguments = try XCTUnwrap(continuation["arguments"] as? [String: String])
                XCTAssertEqual(arguments, ["cursor": cursor], "Post-input overview supplies a cursor-only call too")
                let next = try await call(controller, "browser_read", arguments)
                XCTAssertEqual(try field("source_observation", in: next), source)
                XCTAssertNotNil(UUID(uuidString: source))
                XCTAssertEqual(try field("tab_handle", in: next), try field("tab_handle", in: fresh))
                XCTAssertFalse(try XCTUnwrap(next.split(separator: "\n").first).contains("document_epoch="))
                XCTAssertNotEqual(try snapshotID(next), try snapshotID(fresh))
                _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1])
            } else {
                _ = try await call(controller, "browser_click", ["snapshot_id": snapshotID(fresh), "element_index": 1])
            }
            let counts = await backend.counts()
            XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 1)
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
        for (tool, index) in [("browser_click", 0), ("browser_fill", 1)] {
            var arguments: [String: Any] = ["snapshot_id": id, "element_index": index]
            if tool == "browser_fill" { arguments["text"] = "MUST_NOT_APPEAR" }
            let data = try argumentData(arguments)
            do {
                try await controller.preflightMutation(taskKey: "turn-a", tool: tool, arguments: data)
                XCTFail("Unsupported captured intent must be rejected before an approval is requested")
            } catch {
                XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference)
                XCTAssertTrue(error.localizedDescription.contains("No input was dispatched."))
                XCTAssertTrue(error.localizedDescription.contains("browser_read"))
                XCTAssertFalse(error.localizedDescription.contains("Chrome"))
            }
            do {
                _ = try await call(controller, tool, arguments)
                XCTFail("Direct execution must enforce the same captured eligibility")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        }
        let denied = await backend.counts()
        XCTAssertEqual(denied.presses, 0); XCTAssertEqual(denied.fills, 0)
        XCTAssertEqual(denied.observes, before.observes, "Unsupported intent must not reach backend preflight")
        let valid: [String: Any] = ["snapshot_id": id, "element_index": 1]
        let validData = try argumentData(valid)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: validData)
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: validData)
        _ = try await call(controller, "browser_click", valid)
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: validData)
            XCTFail("An admitted mutation must consume its snapshot")
        } catch { XCTAssertEqual((error as? EmbeddedBrowserPreflightRecoveryFailure)?.original, .staleSnapshot) }
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
            let arguments = try argumentData(["snapshot_id": snapshotID(read), "element_index": 1])
            if condition == "stale" { _ = try await call(controller, "browser_read", ["view": "all"]) }
            if condition == "replaced_target" { await backend.replaceOwnedTarget() }
            if condition == "released" { _ = await controller.release(taskKey: "turn-a") }
            do {
                try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click", arguments: arguments)
                XCTFail("Preflight must reject \(condition)")
            } catch {
                if condition == "disabled" {
                    XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference)
                } else if condition == "stale" {
                    XCTAssertEqual((error as? EmbeddedBrowserPreflightRecoveryFailure)?.original, .staleSnapshot)
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

    func testStalePreflightPublishesOnlyFreshReadEvidenceThenRequiresASeparateInput() async throws {
        for tool in ["browser_click", "browser_fill"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let old = try await call(controller, "browser_read", ["view": "all"])
            _ = try await call(controller, "browser_read", ["view": "content"])
            let index = tool == "browser_click" ? 1 : 0
            var arguments: [String: Any] = ["snapshot_id": try snapshotID(old), "element_index": index]
            if tool == "browser_fill" { arguments["text"] = "UA 4629" }
            let before = await backend.counts()
            let failure = try await stalePreflight(controller, tool: tool, arguments: arguments)
            XCTAssertEqual(failure.original, .staleSnapshot)
            XCTAssertEqual(failure.localizedDescription, BrowserTabBrokerError.staleSnapshot.localizedDescription)
            XCTAssertLessThan(failure.localizedDescription.utf8.count, 256)
            try assertCompleteRecovery(failure, kind: tool == "browser_fill" ? "fill" : "click", reason: "stale_snapshot")
            let response = try jsonObject(failure.observationResponse)
            XCTAssertEqual(response["success"] as? Bool, false); XCTAssertEqual(response["dispatched"] as? Bool, false)
            XCTAssertEqual(response["no_replay"] as? Bool, true)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "stale_snapshot")
            let current = try XCTUnwrap(response["current_observation"] as? [String: Any])
            XCTAssertEqual(current["status"] as? String, "available"); XCTAssertEqual(current["view"] as? String, "overview")
            let text = try XCTUnwrap(current["text"] as? String)
            let newID = try snapshotID(text)
            XCTAssertEqual(current["snapshot_id"] as? String, newID); XCTAssertNotEqual(newID, try snapshotID(old))
            XCTAssertNotNil(publishedTargets[newID]?[1]?.clickRef)
            XCTAssertNotNil(publishedTargets[newID]?[0]?.fillRef)
            XCTAssertTrue((response["next"] as? String)?.contains("separate call") == true)
            let recovered = await backend.counts()
            XCTAssertEqual(recovered.observes, before.observes + 1)
            XCTAssertEqual(recovered.presses, 0); XCTAssertEqual(recovered.fills, 0)
            arguments["snapshot_id"] = newID
            try await controller.preflightMutation(taskKey: "turn-a", tool: tool,
                arguments: argumentData(arguments))
            _ = try await call(controller, tool, arguments)
            let after = await backend.counts()
            XCTAssertEqual(after.presses, tool == "browser_click" ? 1 : 0)
            XCTAssertEqual(after.fills, tool == "browser_fill" ? 1 : 0)
            _ = await controller.shutdown()
        }
    }

    func testNavigatedDocumentPreflightProvidesFreshReadWithoutReplayingTheRejectedAction() async throws {
        for tool in ["browser_click", "browser_fill"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let old = try await call(controller, "browser_read", ["view": "all"])
            await backend.redirectOwnedTarget(to: URL(string: "http://localhost:8123/new-document")!)
            var arguments: [String: Any] = ["snapshot_id": try snapshotID(old), "element_index": tool == "browser_click" ? 1 : 0]
            if tool == "browser_fill" { arguments["text"] = "UA 4629" }
            let before = await backend.counts()
            let failure = try await stalePreflight(controller, tool: tool, arguments: arguments)
            XCTAssertEqual(failure.original, .staleDocument)
            XCTAssertEqual(failure.localizedDescription, BrowserTabBrokerError.staleDocument.localizedDescription)
            try assertCompleteRecovery(failure, kind: tool == "browser_fill" ? "fill" : "click", reason: "stale_document")
            let response = try jsonObject(failure.observationResponse)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "stale_document")
            XCTAssertEqual(response["dispatched"] as? Bool, false)
            let current = try XCTUnwrap(response["current_observation"] as? [String: Any])
            XCTAssertEqual(current["status"] as? String, "available")
            let text = try XCTUnwrap(current["text"] as? String)
            XCTAssertTrue(text.contains("/new-document"))
            XCTAssertNotEqual(try snapshotID(text), try snapshotID(old))
            let recovered = await backend.counts()
            XCTAssertEqual(recovered.observes, before.observes + 1)
            XCTAssertEqual(recovered.presses, 0); XCTAssertEqual(recovered.fills, 0)
            arguments["snapshot_id"] = try snapshotID(text)
            try await controller.preflightMutation(taskKey: "turn-a", tool: tool,
                arguments: argumentData(arguments))
            _ = try await call(controller, tool, arguments)
            let after = await backend.counts()
            XCTAssertEqual(after.presses, tool == "browser_click" ? 1 : 0)
            XCTAssertEqual(after.fills, tool == "browser_fill" ? 1 : 0)
            _ = await controller.shutdown()
        }
    }

    func testStalePreflightRecoveryIsOncePerRejectedSnapshotAndAtMostThreePerTurn() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        var ids = [String]()
        for _ in 0..<4 { ids.append(try snapshotID(await call(controller, "browser_read", ["view": "all"]))) }
        _ = try await call(controller, "browser_read", ["view": "all"])
        for (offset, id) in ids.enumerated() {
            let before = await backend.counts()
            let failure = try await stalePreflight(controller, arguments: ["snapshot_id": id, "element_index": 1])
            let current = try XCTUnwrap(jsonObject(failure.observationResponse)["current_observation"] as? [String: Any])
            XCTAssertEqual(current["status"] as? String, offset < 3 ? "available" : "unavailable")
            if offset == 3 {
                XCTAssertEqual(current["reason"] as? String, "recovery_limit"); XCTAssertNil(current["text"])
                XCTAssertNil(failure.rejectionReceipt)
            } else { try assertCompleteRecovery(failure, kind: "click", reason: "stale_snapshot") }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + (offset < 3 ? 1 : 0))
            if offset == 0 {
                _ = try await call(controller, "browser_read", ["view": "all"])
                let beforeRepeat = await backend.counts()
                let repeated = try await stalePreflight(controller, arguments: ["snapshot_id": id, "element_index": 1])
                let unavailable = try XCTUnwrap(jsonObject(repeated.observationResponse)["current_observation"] as? [String: Any])
                XCTAssertEqual(unavailable["reason"] as? String, "recovery_already_attempted")
                XCTAssertNil(repeated.rejectionReceipt)
                XCTAssertNil(unavailable["text"]); XCTAssertNil(unavailable["snapshot_id"])
                let afterRepeat = await backend.counts()
                XCTAssertEqual(afterRepeat.observes, beforeRepeat.observes, "Explicit reads cannot refund rejected-reference recovery")
            }
        }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.navigations, 0)
        _ = await controller.shutdown()
    }

    func testFailedStalePreflightRecoveryRetainsOriginalErrorWithoutReferencesOrReadRetry() async throws {
        for failure in [BrowserTabBrokerError.browserUnavailable("PRIVATE_RECOVERY_ERROR"), .staleDocument] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let old = try await call(controller, "browser_read", ["view": "all"])
            _ = try await call(controller, "browser_read", ["view": "all"])
            await backend.failObservations([failure])
            let before = await backend.counts()
            let rejected = try await stalePreflight(controller, arguments: ["snapshot_id": snapshotID(old), "element_index": 1])
            XCTAssertEqual(rejected.original, .staleSnapshot)
            XCTAssertFalse(rejected.localizedDescription.contains("PRIVATE_RECOVERY_ERROR"))
            XCTAssertFalse(rejected.observationResponse.contains("PRIVATE_RECOVERY_ERROR"))
            XCTAssertNil(rejected.rejectionReceipt)
            let current = try XCTUnwrap(jsonObject(rejected.observationResponse)["current_observation"] as? [String: Any])
            XCTAssertEqual(current["status"] as? String, "unavailable")
            XCTAssertNil(current["text"]); XCTAssertNil(current["snapshot_id"])
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1)
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testStalePreflightRecoveryCannotPublishReferencesAfterCancellationOrContextRelease() async throws {
        for cancel in [false, true] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let old = try await call(controller, "browser_read", ["view": "all"])
            _ = try await call(controller, "browser_read", ["view": "all"])
            await backend.holdNextRead()
            let operation = Task {
                try await self.stalePreflight(controller, arguments: ["snapshot_id": self.snapshotID(old), "element_index": 1])
            }
            await backend.waitUntilObservationHeld()
            if cancel { operation.cancel() } else { _ = await controller.release(taskKey: "turn-a") }
            await backend.resumeObservation()
            if cancel {
                do { _ = try await operation.value; XCTFail("Cancellation cannot publish recovery evidence") }
                catch { XCTAssertTrue(error is CancellationError) }
            } else {
                let rejected = try await operation.value
                let current = try XCTUnwrap(jsonObject(rejected.observationResponse)["current_observation"] as? [String: Any])
                XCTAssertEqual(current["status"] as? String, "unavailable")
                XCTAssertNil(current["text"]); XCTAssertNil(current["snapshot_id"])
            }
            let counts = await backend.counts()
            XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
            _ = await controller.shutdown()
        }
    }

    private func stalePreflight(_ controller: EmbeddedBrowserToolController, tool: String = "browser_click",
                                arguments: [String: Any]) async throws -> EmbeddedBrowserPreflightRecoveryFailure {
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: tool,
                arguments: argumentData(arguments))
            XCTFail("The stale reference must remain rejected before input")
            throw BrowserTabBrokerError.invalidRead("Expected a stale preflight rejection")
        } catch let failure as EmbeddedBrowserPreflightRecoveryFailure { return failure }
    }

    func testMutationAfterApprovalStillRevalidatesReplacedOrDisabledPhysicalTarget() async throws {
        for change in ["replacement", "disabled", "released"] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            let read = try await call(controller, "browser_read", ["view": "all"])
            let arguments: [String: Any] = ["snapshot_id": try snapshotID(read), "element_index": 1]
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                                                   arguments: argumentData(arguments))
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
        for name in ["browser_continue", "browser_tabs"] {
            let spec = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            let description = try XCTUnwrap(spec["description"] as? String)
            XCTAssertTrue(description.contains(name + "(cursor=next_cursor)"))
            XCTAssertTrue(description.contains("computer_v2_continue"))
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: ["cursor": UUID().uuidString]))
        }
    }

    func testOptionalBrowserReadArgumentsAdvertiseOmissionAndRejectEmptyStrings() throws {
        for name in ["browser_tabs", "browser_read"] {
            let specification: [String: Any]
            if name == "browser_read" { specification = EmbeddedBrowserTools.legacyReadDefinition }
            else { specification = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name }) }
            let schema = try XCTUnwrap(specification["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let required = try XCTUnwrap(schema["required"] as? [String])
            let cursor = try XCTUnwrap(properties["cursor"] as? [String: Any])
            XCTAssertEqual(cursor["type"] as? [String], ["string", "null"])
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: ["cursor": NSNull()]))
            XCTAssertEqual(cursor["minLength"] as? Int, 1)
            XCTAssertFalse(required.contains("cursor"))
            let guidance = try XCTUnwrap(cursor["description"] as? String)
            XCTAssertTrue(guidance.contains("Omit this field on the first page or a fresh"))
            XCTAssertTrue(guidance.contains("never resumes a previous cursor"))
            XCTAssertTrue(guidance.contains("exact nonempty next_cursor"))
            XCTAssertTrue(guidance.contains("current turn"))
            if name == "browser_read" {
                XCTAssertTrue(guidance.contains("latest page"))
                XCTAssertTrue(guidance.contains("Prefer cursor alone"))
                XCTAssertTrue(guidance.contains("repeated view/query must match the captured filters"))
                XCTAssertTrue(guidance.contains("successful continuation, fresh read or current_observation replaces older cursors"))
                XCTAssertTrue(guidance.contains("admitted input invalidates them"))
            }
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

    func testNullInventoryCursorStartsFreshFirstPageAndRetiresPriorCursorAndUnpublishedTabIDs() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.addLongInventory()
        func inventory(_ arguments: [String: Any] = [:], key: String = "turn-a") async throws -> [String: Any] {
            let text = try await call(controller, "browser_tabs", arguments, key: key)
            XCTAssertLessThanOrEqual(text.utf8.count, 8_192)
            return try jsonObject(text)
        }
        func rows(_ inventory: [String: Any]) throws -> [[String: Any]] { try XCTUnwrap(inventory["tabs"] as? [[String: Any]]) }
        let first = try await inventory(["cursor": NSNull()])
        let firstCursor = try XCTUnwrap(first["next_cursor"] as? String)
        XCTAssertEqual(first["truncated"] as? Bool, true)
        let next = try await inventory(["cursor": firstCursor])
        let nextCursor = try XCTUnwrap(next["next_cursor"] as? String)
        let laterID = try XCTUnwrap(rows(next).first?["tab_id"] as? String)
        let afterContinuation = await backend.inventoryReadCount()
        XCTAssertEqual(afterContinuation, 1, "A valid inventory continuation retains the enumerated inventory")
        let freshNull = try await inventory(["cursor": NSNull()])
        XCTAssertEqual(try rows(freshNull).compactMap { $0["tab_id"] as? String },
                       try rows(first).compactMap { $0["tab_id"] as? String }, "Null starts at offset zero, not the prior cursor")
        XCTAssertNotEqual(freshNull["next_cursor"] as? String, nextCursor)
        do {
            _ = try await call(controller, "browser_bind", ["tab_id": laterID])
            XCTFail("Fresh inventory cannot retain tab IDs from an omitted old page")
        } catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        let foreign = try await inventory(key: "turn-b")
        let foreignCursor = try XCTUnwrap(foreign["next_cursor"] as? String)
        let beforeRejections = await backend.inventoryReadCount()
        for cursor in [firstCursor, nextCursor, foreignCursor, UUID().uuidString, ""] {
            do { _ = try await inventory(["cursor": cursor]); XCTFail("Null support cannot admit stale, foreign or empty cursors") }
            catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        }
        let afterRejections = await backend.inventoryReadCount()
        XCTAssertEqual(afterRejections, beforeRejections, "Rejected inventory cursors cannot silently refresh")
        let omitted = try await inventory()
        XCTAssertEqual(try rows(omitted).compactMap { $0["tab_id"] as? String },
                       try rows(freshNull).compactMap { $0["tab_id"] as? String })
        _ = await backend.addInventoryTarget(title: "Newly listed", url: URL(string: "http://localhost:8123/new")!)
        let refreshed = try await inventory(["cursor": NSNull()])
        XCTAssertEqual(refreshed["count"] as? Int, (try XCTUnwrap(omitted["count"] as? Int)) + 1)
        let currentCursor = try XCTUnwrap(refreshed["next_cursor"] as? String)
        _ = await backend.addInventoryTarget(title: "After retained capture", url: URL(string: "http://localhost:8123/later")!)
        let beforeValid = await backend.inventoryReadCount()
        let retained = try await inventory(["cursor": currentCursor])
        XCTAssertEqual(retained["count"] as? Int, refreshed["count"] as? Int)
        let afterValid = await backend.inventoryReadCount()
        XCTAssertEqual(afterValid, beforeValid)
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates, 0); XCTAssertEqual(counts.observes, 0)
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.navigations, 0)
        _ = await controller.shutdown()
    }

    func testNullReadCursorStartsFreshOverviewInsteadOfContinuingOrRevivingOldReferences() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.exposeCommittedDocumentIdentity()
        await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/other"], key: "turn-b")
        let foreign = try await call(controller, "browser_read", ["view": "all"], key: "turn-b")
        let foreignCursor = try field("next_cursor", in: foreign)
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        let omitted = try await call(controller, "browser_read"), oldID = try snapshotID(omitted)
        let oldCursor = try field("next_cursor", in: omitted)
        let oldRef = try XCTUnwrap(publishedTargets[oldID]?[1]?.clickRef)
        let unchangedFieldRef = try XCTUnwrap(publishedTargets[oldID]?[0]?.fillRef)
        await backend.setButtonLabel("Check flight updated")
        let before = await backend.counts()
        let null = try await call(controller, "browser_read", ["cursor": NSNull()]), nullID = try snapshotID(null)
        let after = await backend.counts()
        XCTAssertEqual(after.observes, before.observes + 1, "Null captures afresh instead of consuming a retained continuation")
        for page in [omitted, null] {
            XCTAssertEqual(try field("view", in: page), "overview")
            XCTAssertEqual(try field("offset", in: page), "0")
            XCTAssertLessThanOrEqual(page.utf8.count, 16_384)
        }
        XCTAssertNotEqual(nullID, oldID)
        XCTAssertNotEqual(try field("source_observation", in: null), try field("source_observation", in: omitted),
                          "Null starts a new captured observation")
        XCTAssertEqual(publishedTargets[nullID]?[0]?.fillRef, unchangedFieldRef,
                       "An explicitly republished unchanged field retains its current reference")
        XCTAssertNotEqual(publishedTargets[nullID]?[1]?.clickRef, oldRef,
                          "The changed target receives a new reference")
        XCTAssertNotEqual(try field("next_cursor", in: null), oldCursor)
        do {
            _ = try await call(controller, "browser_click", ["click_ref": oldRef])
            XCTFail("A fresh read cannot revive the reference of a changed target")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        for cursor in [oldCursor, foreignCursor, UUID().uuidString] {
            do { _ = try await call(controller, "browser_read", ["cursor": cursor]); XCTFail("Unknown or replaced cursors remain rejected") }
            catch { assertNoncurrentReadCursor(error) }
        }
        do { _ = try await call(controller, "browser_read", ["cursor": ""]); XCTFail("An empty string is not omission") }
        catch { XCTAssertTrue(error is BrowserTabBrokerError) }
        let rejected = await backend.counts()
        XCTAssertEqual(rejected, after, "Rejected cursors and retired refs do not capture or dispatch")
        let continued = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: null)])
        XCTAssertGreaterThan(try XCTUnwrap(Int(field("offset", in: continued))), 0)
        let retained = await backend.counts()
        XCTAssertEqual(retained.observes, after.observes + 1, "Continuation performs the existing live document freshness probe")
        XCTAssertEqual(try field("source_observation", in: continued), try field("source_observation", in: null),
                       "The next page retains its immutable source despite the separate freshness probe")
        XCTAssertEqual(retained.presses, 0); XCTAssertEqual(retained.fills, 0)
        do {
            _ = try await call(controller, "browser_read", ["cursor": field("next_cursor", in: null)])
            XCTFail("A successfully consumed continuation cannot be reused even within the same capture")
        } catch { assertNoncurrentReadCursor(error) }
        let afterReplay = await backend.counts()
        XCTAssertEqual(afterReplay, retained, "An old issued cursor neither recaptures nor consumes current references")
        let filtered = try await call(controller, "browser_read", ["cursor": NSNull(), "view": "all", "query": "updated"])
        XCTAssertEqual(try field("view", in: filtered), "all")
        XCTAssertTrue(filtered.contains("label=\"Check flight updated\""))
        XCTAssertFalse(filtered.contains("label=\"Flight number\""), "Null does not discard explicitly requested filters")
        _ = await controller.shutdown()
    }

    func testNoncurrentReadCursorDiagnosisPreservesReferencesAndRequiresExplicitFreshRead() async throws {
        for freshArguments: [String: Any] in [[:], ["cursor": NSNull()]] {
            let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            let page = try await call(controller, "browser_read", ["view": "all"])
            let id = try snapshotID(page)
            let reference = try XCTUnwrap(publishedTargets[id]?[1]?.clickRef)
            let before = await backend.counts()
            for invalid in [id, try field("tab_handle", in: page), try field("source_observation", in: page),
                            reference, "PRIVATE_UNISSUED_CURSOR", UUID().uuidString] {
                do {
                    _ = try await call(controller, "browser_read", ["cursor": invalid, "view": "content"])
                    XCTFail("Only the exact current next_cursor can continue or request changed-filter recovery")
                } catch {
                    assertNoncurrentReadCursor(error)
                    XCTAssertFalse(error.localizedDescription.contains(invalid), "The diagnostic must not echo identifiers or page data")
                }
            }
            let rejected = await backend.counts()
            XCTAssertEqual(rejected, before, "Rejected identifiers neither capture nor dispatch input")
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                arguments: JSONSerialization.data(withJSONObject: ["click_ref": reference]))
            let retained = await backend.counts()
            XCTAssertEqual(retained, before, "The rejected reads leave the exact published input reference unconsumed")
            let fresh = try await call(controller, "browser_read", freshArguments)
            XCTAssertEqual(try field("view", in: fresh), "overview")
            XCTAssertEqual(try field("offset", in: fresh), "0")
            XCTAssertNotEqual(try field("source_observation", in: fresh), try field("source_observation", in: page))
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + 1, "Only the explicit fresh read captures the page")
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
            _ = await controller.shutdown()
        }
    }

    func testExactCurrentReadCursorStillReportsExpiryInsteadOfInvalidIdentifier() async throws {
        for tool in ["browser_read", "browser_continue"] {
            let backend = EmbeddedBrowserFixtureBackend()
            let controller = EmbeddedBrowserToolController(transport: backend, readLifetime: .zero)
            _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
            await backend.showManyControls()
            let page = try await call(controller, "browser_read", ["view": "all"])
            let before = await backend.counts()
            do {
                _ = try await call(controller, tool, ["cursor": field("next_cursor", in: page)])
                XCTFail("An issued but expired cursor must not become a fresh read")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            let after = await backend.counts()
            XCTAssertEqual(after, before)
            _ = await controller.shutdown()
        }
    }

    func testNullReadCursorDoesNotRelaxOtherArgumentsOrRefundRecoveryBudget() async throws {
        for (tool, args) in [
            ("browser_tabs", ["query": NSNull()]), ("browser_read", ["view": NSNull()]),
            ("browser_read", ["query": NSNull()]), ("browser_click", ["click_ref": NSNull()]),
            ("browser_fill", ["fill_ref": NSNull(), "text": "value"]),
            ("browser_fill", ["fill_ref": "bfill_fixture", "text": NSNull()]),
            ("browser_open", ["url": NSNull()]), ("browser_navigate", ["url": NSNull()]),
            ("browser_bind", ["tab_id": NSNull()]), ("browser_wait", ["text": NSNull()]),
            ("browser_wait", ["timeout_ms": NSNull()]),
        ] as [(String, [String: Any])] {
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: tool, arguments: args))
        }
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.showManyControls()
        _ = try await call(controller, "browser_open", ["url": "http://localhost:8123/flight"])
        for attempt in 0..<4 {
            let fresh = try await call(controller, "browser_read", ["cursor": NSNull(), "view": "all"])
            let before = await backend.counts()
            let failure = try await changedFilterFailure(controller,
                arguments: ["cursor": field("next_cursor", in: fresh), "view": "content"])
            let current = try XCTUnwrap(jsonObject(failure.observationResponse)["current_observation"] as? [String: Any])
            XCTAssertEqual(current["status"] as? String, attempt < 3 ? "available" : "unavailable")
            if attempt == 3 { XCTAssertEqual(current["reason"] as? String, "recovery_limit") }
            let after = await backend.counts()
            XCTAssertEqual(after.observes, before.observes + (attempt < 3 ? 1 : 0))
            XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
        }
        _ = await controller.shutdown()
    }

    func testOptionalBrowserReadArgumentsKeepNativeUTF8BoundsWithoutNormalizing() throws {
        for (name, field) in [("browser_tabs", "cursor"), ("browser_read", "cursor"), ("browser_read", "query")] {
            let boundary = String(repeating: "é", count: 1024)
            XCTAssertEqual(boundary.utf8.count, 2048)
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: boundary]))
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: boundary + "x"]))
            for value: Any in ["", 17] {
                XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: value]))
            }
            if field == "cursor" {
                XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: NSNull()]))
            } else {
                XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: name, arguments: [field: NSNull()]))
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
        try await controller.execute(taskKey: key, tool: tool, arguments: argumentData(arguments), scope: scope)
    }

    private func assertNoncurrentReadCursor(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? BrowserTabBrokerError, case .invalidRead(let detail) = error else {
            return XCTFail("Expected an invalid-read cursor diagnosis, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(detail.contains("latest page's exact next_cursor"), file: file, line: line)
        XCTAssertTrue(detail.contains("replaces older cursors"), file: file, line: line)
        XCTAssertTrue(detail.contains("admitted input invalidates them"), file: file, line: line)
        XCTAssertFalse(detail.contains("snapshot ID or tab handle"), "An earlier issued cursor is not necessarily an identifier of another kind", file: file, line: line)
        XCTAssertTrue(detail.contains("No read or input was dispatched"), file: file, line: line)
        XCTAssertTrue(detail.contains("Use browser_read without cursor"), file: file, line: line)
        XCTAssertLessThanOrEqual(detail.utf8.count, 384, file: file, line: line)
    }

    func testContractRejectsUnknownArgumentsGuessedURLsAndBoolIndicesBeforeDispatch() throws {
        for (tool, arguments) in [
            ("browser_open", ["url":"javascript:alert(1)"]),
            ("browser_open", ["url":"https://user:password@example.com"]),
            ("browser_bind", ["tab_id":"invented"]),
            ("browser_click", ["snapshot_id":UUID().uuidString,"element_index":true,
                               "expected_role":"AXButton","expected_label":"Check flight"]),
            ("browser_wait", ["timeout_ms":10_001]),
            ("browser_read", ["view":"everything"]),
            ("browser_close", ["tab_id":UUID().uuidString])
        ] as [(String,[String:Any])] {
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: tool, arguments: arguments)) { error in
                if tool == "browser_click" {
                    XCTAssertEqual(error as? BrowserTabBrokerError,
                        .invalidRead("The built-in browser tool has missing or unexpected arguments."))
                }
            }
        }
        XCTAssertEqual(Set(EmbeddedBrowserTools.definitions().compactMap { $0["name"] as? String }), EmbeddedBrowserTools.names)
        XCTAssertFalse(EmbeddedBrowserTools.requiresApproval(tool: "browser_read"))
        XCTAssertTrue(EmbeddedBrowserTools.requiresApproval(tool: "browser_fill"))
        let descriptions = Dictionary(uniqueKeysWithValues: EmbeddedBrowserTools.definitions().map {
            ($0["name"] as! String, $0["description"] as! String)
        })
        XCTAssertTrue(descriptions["browser_click"]?.contains("actions=[\"AXPress\"]") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("Choose the intended row by its observed label and action") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("existing-account selector may be used within the authorized service/task and approvals") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("when credentials, MFA or account ambiguity actually require it") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("If dispatched input leaves the page unchanged, wait/read instead of clicking again") == true)
        XCTAssertTrue(descriptions["browser_click"]?.contains("After stale errors use available current_observation; otherwise browser_read") == true)
        XCTAssertFalse(descriptions["browser_click"]?.contains("After stale errors, browser_read before input") == true)
        XCTAssertTrue(descriptions["browser_read"]?.contains("actions=[] cannot be clicked") == true)
        XCTAssertTrue(descriptions["browser_fill"]?.contains("enabled=true and settable=true") == true)
    }

    func testFlightReadFillClickAndResultRequireFreshSnapshotAndNeverReplay() async throws {
        for name in ["browser_fill", "browser_click"] {
            let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(properties[name == "browser_fill" ? "fill_ref" : "click_ref"])
            XCTAssertNil(properties["snapshot_id"]); XCTAssertNil(properties["element_index"])
        }
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let first = try await call(controller,"browser_read")
        try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_fill",
            arguments: argumentData(["snapshot_id": snapshotID(first), "element_index": 0, "text": "UA 123"]))
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
        let busyInventory = try jsonObject(await call(controller,"browser_tabs",key:"turn-b"))
        XCTAssertNil(busyInventory["inventory_state"]); XCTAssertNil(busyInventory["authentication_evidence"])
        XCTAssertNil(busyInventory["next"], "An occupied tab is not an empty-inventory invitation to duplicate it")
        XCTAssertEqual((busyInventory["tabs"] as? [[String: Any]])?.first?["availability"] as? String, "busy")
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
            arguments: argumentData(["snapshot_id": snapshotID(read), "element_index": 1]))
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
                else if scenario == "redirected" || scenario == "changed_scope" {
                    guard let failure = error as? BrowserTabBrokerError, case .scopeDenied = failure else {
                        return XCTFail("Expected typed scope denial, got \(error)")
                    }
                }
                else if let failure = error as? BrowserTabBrokerError, case .invalidRead = failure { /* Exact observed target denied. */ }
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
        let prepared = try APIModelResponseCodec.prepare(argumentData([
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
        let operation = Task { try await controller.executeResult(taskKey: "turn-a", tool: "browser_click",
            arguments: argumentData(["snapshot_id": id, "element_index": 1])) }
        await backend.waitUntilMutationHeld()
        do {
            try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                arguments: argumentData(["snapshot_id": id, "element_index": 1]))
            XCTFail("Preflight cannot overlap an admitted mutation")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .operationInProgress) }
        _ = await controller.release(taskKey:"turn-a")
        await backend.resumeMutation()
        do { _ = try await operation.value; XCTFail("Revoked broker mutation must not return a successful dispatch cue") } catch { }
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

    func testEmptyMatchingInventoryReportsUnobservedAuthenticationWithoutGrantingPageAuthority() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        let scope = ComputerTaskScope(userPrompt: "Read the requested page on Wikipedia using the built-in browser.")
        let output = try await call(controller, "browser_tabs", scope: scope)
        let inventory = try jsonObject(output)
        XCTAssertEqual(inventory["count"] as? Int, 0); XCTAssertEqual(inventory["returned"] as? Int, 0)
        XCTAssertEqual(inventory["truncated"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(inventory["tabs"] as? [[String: Any]]).isEmpty)
        XCTAssertTrue(inventory["next_cursor"] is NSNull)
        XCTAssertEqual(inventory["content_evidence"] as? String, "metadata_only")
        XCTAssertEqual(inventory["inventory_state"] as? String, "no_matching_human_tabs")
        XCTAssertEqual(inventory["authentication_evidence"] as? String, "not_observed")
        let next = try XCTUnwrap(inventory["next"] as? String)
        XCTAssertTrue(next.contains("does not establish logout, missing credentials or denied access"))
        XCTAssertTrue(next.contains("Use browser_open with the task's supplied or previously observed URL"))
        XCTAssertTrue(next.contains("empty inventory is not a reason to refuse"))
        XCTAssertTrue(next.contains("then browser_read"))
        XCTAssertFalse(next.contains("://"), "The inventory must not manufacture a service URL")
        XCTAssertNil(inventory["authenticated"]); XCTAssertNil(inventory["snapshot_id"]); XCTAssertNil(inventory["tab_id"])
        XCTAssertLessThan(output.utf8.count, 1_024)
        let unrelatedHumanTabs = try await backend.humanTargets()
        XCTAssertEqual(unrelatedHumanTabs.count, 1, "No matching tabs does not assert the whole profile has no tabs")
        do { _ = try await call(controller, "browser_read", scope: scope); XCTFail("Inventory metadata grants no page binding") }
        catch { XCTAssertTrue(error is EmbeddedBrowserBindingRequiredFailure) }
        var counts = await backend.counts()
        XCTAssertEqual(counts.creates, 0); XCTAssertEqual(counts.observes, 0)
        XCTAssertEqual(counts.presses, 0); XCTAssertEqual(counts.fills, 0)
        _ = try await call(controller, "browser_open", ["url": "https://en.wikipedia.org/"], scope: scope)
        counts = await backend.counts()
        XCTAssertEqual(counts.creates, 1, "The ordinary authorized open remains available after empty inventory")
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
            XCTAssertNil(value["inventory_state"]); XCTAssertNil(value["authentication_evidence"])
            XCTAssertNil(value["next"], "A nonempty retained inventory, including its last page, keeps its normal cursor contract")
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

    func testProductTroubleshootingCanOpenOfficialHelpWhileExplicitChatDestinationRemainsBound() async throws {
        let reported = ComputerTaskScope(userPrompt: "Help me enable Chrome access through ChatGPT’s supported settings. Focus on read-only Terminal diagnostics to identify why Local browser use is disabled in Work settings appears. Find the documented setting or supported command, and explain any action I must perform myself. Don’t alter internal permission databases or override safety restrictions. This is a read-only troubleshooting request: do not change settings or configuration files; report your findings and the supported user steps.")
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller, "browser_open", ["url": "https://help.openai.com/"], scope: reported)
        let help = try await call(controller, "browser_read", scope: reported)
        XCTAssertTrue(help.contains("https://help.openai.com/"))
        let explicit = ComputerTaskScope(userPrompt: "Open ChatGPT")
        do {
            _ = try await call(controller, "browser_open", ["url": "https://help.openai.com/"], key: "turn-b", scope: explicit)
            XCTFail("A specific chat destination cannot be silently replaced with a documentation site")
        } catch { }
        let after = await backend.counts()
        XCTAssertEqual(after.creates, 1)
        XCTAssertEqual(after.presses, 0); XCTAssertEqual(after.fills, 0)
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
                arguments: argumentData(["snapshot_id": snapshotID(read), "element_index": 0]),
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
        XCTAssertTrue(read.contains("Omitted row flags: enabled=true settable=false actions=[]"))
        XCTAssertFalse(row.contains("enabled=false")); XCTAssertFalse(row.contains("actions="))
        XCTAssertFalse(row.contains("click_ref=")); XCTAssertFalse(row.contains("fill_ref="))
        XCTAssertFalse(row.contains("follow_link=true"))
        let arguments: [String: Any] = ["snapshot_id": try snapshotID(read), "element_index": 0]
        for preflight in [true, false] {
            do {
                if preflight {
                    try await controller.preflightMutation(taskKey: "turn-a", tool: "browser_click",
                        arguments: argumentData(arguments))
                } else { _ = try await call(controller, "browser_click", arguments) }
                XCTFail("A readable popup destination does not grant press authority")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
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
        let identifier = String(id)
        var targets = [Int: PublishedTarget]()
        for line in text.split(separator: "\n") where line.hasPrefix("#") {
            let row = String(line)
            guard let number = row.split(separator: " ").first,
                  let index = Int(number.dropFirst()),
                  let role = try publishedString("role", in: row) else { continue }
            targets[index] = PublishedTarget(role: role, label: try publishedString("label", in: row),
                clickRef: try publishedString("click_ref", in: row), fillRef: try publishedString("fill_ref", in: row))
        }
        publishedTargets[identifier] = targets
        return identifier
    }
}

private actor EmbeddedBrowserFixtureBackend: EmbeddedBrowserControlBackend {
    struct Counts: Equatable, Sendable { var creates=0,closes=0,closeAttempts=0,observes=0,presses=0,fills=0,navigations=0 }
    let humanID = UUID().uuidString
    private var targets = [String: BrowserTarget](), owned = Set<String>(), stats = Counts()
    private var inventoryReads = 0
    private var generation = UUID().uuidString, field = "", result = ""
    private var committedDocumentID: UUID? = UUID()
    private var committedIdentityExposed = false
    private var observationSourceName = "computa_webkit_dom"
    private var semanticReadiness: BrowserDocumentObservation.SemanticReadiness?, emptyObservation = false
    private var buttonID: Int64 = 2, buttonDisabled = false, buttonLabel = "Check flight"
    private var buttonCaptureScenario: String?
    private var pendingRedirect: URL?
    private var link: String?, linkPressUnsupported = false, linkLabel = "Destination"
    private var holdCreate=false, createHeld=false, createContinuation: CheckedContinuation<Void,Never>?
    private var holdMutation=false, mutationHeld=false, mutationContinuation: CheckedContinuation<Void,Never>?
    private var shouldFailClose = false
    private var createWaiters=[CheckedContinuation<Void,Never>](), mutationWaiters=[CheckedContinuation<Void,Never>]()
    private var afterInputScenario: String?, postInputPending = false, manyControls = false
    private var invalidFieldOnPress = false
    private var extraControlCount = 100, buttonAfterControls = false
    private var protectedTargets = Set<String>()
    private var observationHeld = false, observationContinuation: CheckedContinuation<Void, Never>?
    private var observationWaiters = [CheckedContinuation<Void, Never>]()
    private var observationFailures = [BrowserTabBrokerError](), failureRedirect: URL?, replaceOnFailure = false, holdRead = false
    private var holdPublicationAfterRead = false, targetChecksBeforeHold: Int?
    private var finalTargetHeld = false, finalTargetContinuation: CheckedContinuation<Void, Never>?
    private var finalTargetWaiters = [CheckedContinuation<Void, Never>]()
    private var freshReadPreparations = 0, freshReadAdmissions = 0
    private var settleFreshReadURL: URL?
    private var holdFreshRead = false, freshReadHeld = false
    private var freshReadContinuation: CheckedContinuation<Void, Never>?
    private var freshReadWaiters = [CheckedContinuation<Void, Never>]()

    init() { targets[humanID] = BrowserTarget(targetID:humanID,instanceToken:humanID,title:"Flights",url:URL(string:"http://localhost:8123/flight")!) }
    func counts() -> Counts { stats }
    func readAdmissionCounts() -> (preparations: Int, admissions: Int) { (freshReadPreparations, freshReadAdmissions) }
    func prepareFreshRead(settlingAt url: URL? = nil, hold: Bool = false) {
        settleFreshReadURL = url; holdFreshRead = hold; freshReadHeld = false
    }
    func waitUntilFreshReadHeld() async {
        if !freshReadHeld { await withCheckedContinuation { freshReadWaiters.append($0) } }
    }
    func resumeFreshRead() { freshReadContinuation?.resume(); freshReadContinuation = nil }
    func inventoryReadCount() -> Int { inventoryReads }
    func reportInvalidFieldOnPress() { invalidFieldOnPress = true; committedIdentityExposed = true }
    func hideCommittedDocumentIdentity() { committedIdentityExposed = false }
    func exposeCommittedDocumentIdentity() { committedIdentityExposed = true }
    func fieldValue() -> String { field }
    func setInitialField(_ value: String) { field = value }
    func setObservedResult(_ text: String) { result = text }
    func setButtonLabel(_ text: String) { buttonLabel = text }
    func setButtonCaptureScenario(_ scenario: String) { buttonCaptureScenario = scenario }
    func replaceCommittedDocumentIdentity() { committedDocumentID = UUID() }
    func setObservationSourceName(_ name: String) { observationSourceName = name }
    func setSemanticReadiness(_ value: BrowserDocumentObservation.SemanticReadiness?, empty: Bool = false) {
        semanticReadiness = value; emptyObservation = empty
    }
    func failNextClose() { shouldFailClose = true }
    func addInventoryTarget(title:String,url:URL) -> String {
        let id=UUID().uuidString
        targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:title,url:url)
        return id
    }
    func addLongInventory() {
        for index in 0..<12 {
            let id=UUID().uuidString
            targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:String(repeating:"🙂",count:200),
                url:URL(string:"http://localhost:8123/\(index)?q=" + String(repeating:"x",count:1_800))!)
        }
        let id=UUID().uuidString
        targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:"Oversized URL",
            url:URL(string:"http://localhost:8123/?q=" + String(repeating:"x",count:3_000))!)
    }
    func humanTargets() async throws -> [BrowserTarget] { inventoryReads += 1; return Array(targets.values) }
    func createTarget(url:URL) async throws -> BrowserTarget {
        stats.creates += 1
        let id=UUID().uuidString, target=BrowserTarget(targetID:id,instanceToken:id,title:"Flight fixture",url:url)
        targets[id]=target; owned.insert(id)
        if holdCreate {
            createHeld=true; createWaiters.forEach { $0.resume() }; createWaiters.removeAll()
            await withCheckedContinuation { createContinuation=$0 }
        }
        return target
    }
    func target(id:String) async throws -> BrowserTarget? {
        if let remaining = targetChecksBeforeHold {
            targetChecksBeforeHold = remaining > 1 ? remaining - 1 : nil
            if remaining == 1 {
                finalTargetHeld = true
                finalTargetWaiters.forEach { $0.resume() }; finalTargetWaiters.removeAll()
                await withCheckedContinuation { finalTargetContinuation = $0 }
            }
        }
        return protectedTargets.contains(id) ? nil : targets[id]
    }
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
    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness,
                        authorization: @escaping BrowserReadAuthorization) async throws -> BrowserDocumentObservation {
        freshReadPreparations += 1
        if holdFreshRead {
            holdFreshRead = false; freshReadHeld = true
            freshReadWaiters.forEach { $0.resume() }; freshReadWaiters.removeAll()
            await withCheckedContinuation { freshReadContinuation = $0 }
        }
        if let settled = settleFreshReadURL { redirectOwnedTarget(to: settled); settleFreshReadURL = nil }
        try Task.checkCancellation()
        guard !protectedTargets.contains(target.targetID), let current = targets[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard current.instanceToken == target.instanceToken else { throw BrowserTabBrokerError.targetReplaced }
        try authorization(current)
        freshReadAdmissions += 1
        return try await observe(target: current)
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
        var postCaptureScopeScenario: String?
        if postInputPending {
            postInputPending = false
            let scenario = afterInputScenario
            afterInputScenario = nil
            if scenario == "read_failed" { throw BrowserTabBrokerError.browserUnavailable("PRIVATE_READ_ERROR") }
            if scenario == "invalid_read" { throw BrowserTabBrokerError.invalidRead("PRIVATE_READ_ERROR") }
            driftAfterCapture = scenario == "drift_after_capture"
            if scenario?.hasPrefix("post_capture_scope_") == true || scenario == "post_capture_outscope_document" {
                postCaptureScopeScenario = scenario
            }
            if scenario == "hold_observation" || scenario == "hold_generation_drift" {
                observationHeld = true
                observationWaiters.forEach { $0.resume() }; observationWaiters.removeAll()
                await withCheckedContinuation { observationContinuation = $0 }
            }
            // Native WebKit rejects a read spanning navigation, after the input
            // itself was already dispatched. Count/fence its separate retry.
            if ["generation_drift", "generation_drift_twice", "generation_drift_offscope",
                "generation_drift_replaced", "hold_generation_drift", "generation_drift_hold_retry",
                "generation_drift_hold_publication"].contains(scenario ?? "") {
                generation = UUID().uuidString
                if scenario == "generation_drift_twice" { observationFailures = [.staleDocument] }
                if scenario == "generation_drift_hold_retry" { holdRead = true }
                if scenario == "generation_drift_hold_publication" { holdPublicationAfterRead = true }
                if scenario == "generation_drift_offscope" {
                    redirectOwnedTarget(to: URL(string: "https://unrelated.example/PRIVATE_READ_ERROR")!)
                }
                if scenario == "generation_drift_replaced" { replaceOwnedTarget() }
                throw BrowserTabBrokerError.staleDocument
            }
        }
        if let redirect = pendingRedirect {
            targets[target.targetID] = BrowserTarget(targetID:target.targetID,instanceToken:target.instanceToken,title:target.title,url:redirect)
            pendingRedirect = nil
        }
        var nodes = [
            BrowserDocumentNode(backendNodeID:1,role:"textbox",name:"Flight number",value:field,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"1",isEditable:true),
            BrowserDocumentNode(backendNodeID:buttonID,role:buttonCaptureScenario == "role" ? "link" : "button",name:buttonLabel,value:nil,isDisabled:buttonDisabled,isReadOnly:false,isIgnored:buttonCaptureScenario == "hidden",nodeID:String(buttonID),parentNodeID:buttonCaptureScenario == "parent" ? "changed-parent" : nil,isDOMClickable:true,constraintValidation:buttonCaptureScenario == "constraints" ? .init(required: false, candidate: false, valid: true, issues: []) : nil),
            BrowserDocumentNode(backendNodeID:3,role:"statictext",name:result,value:nil,isDisabled:true,isReadOnly:true,isIgnored:false,nodeID:"3")
        ]
        if buttonCaptureScenario == "missing" { nodes.removeAll { $0.backendNodeID == buttonID } }
        if buttonCaptureScenario == "duplicate_backend", let node = nodes.first(where: { $0.backendNodeID == buttonID }) { nodes.append(node) }
        if buttonCaptureScenario == "duplicate_node" {
            nodes.append(BrowserDocumentNode(backendNodeID: 999, role: "button", name: "Different target", value: nil,
                isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: String(buttonID), isDOMClickable: true))
        }
        if let link {
            nodes.append(BrowserDocumentNode(backendNodeID:4,role:"link",name:linkLabel,value:nil,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"4",linkURL:link,isDOMClickable:!linkPressUnsupported,isPressUnsupported:linkPressUnsupported))
        }
        if manyControls {
            for index in 10..<(10 + extraControlCount) {
                nodes.append(BrowserDocumentNode(backendNodeID: Int64(index), role: "button", name: "Extra control \(index)",
                    value: nil, isDisabled: false, isReadOnly: false, isIgnored: false,
                    nodeID: String(index), isDOMClickable: true))
            }
        }
        if buttonAfterControls, let index = nodes.firstIndex(where: { $0.backendNodeID == buttonID }) {
            nodes.append(nodes.remove(at: index))
        }
        let capturedOutscope = postCaptureScopeScenario == "post_capture_outscope_document"
        let capturedURL = capturedOutscope ? URL(string: "https://unrelated.example/PRIVATE_POST_CAPTURE_ROUTE")!
            : targets[target.targetID]?.url ?? target.url
        var observation=BrowserDocumentObservation(loaderID:generation,title:target.title,url:capturedURL,nodes:emptyObservation ? [] : nodes)
        observation.committedDocumentID = committedIdentityExposed ? committedDocumentID : nil
        observation.sourceName = observationSourceName
        observation.semanticReadiness = semanticReadiness
        if driftAfterCapture {
            targets[target.targetID] = BrowserTarget(targetID: target.targetID, instanceToken: target.instanceToken,
                title: target.title, url: URL(string: "http://localhost:8123/changed-after-capture")!)
        }
        if let scenario = postCaptureScopeScenario, !capturedOutscope {
            redirectOwnedTarget(to: URL(string: "https://unrelated.example/PRIVATE_POST_CAPTURE_ROUTE")!)
            if scenario != "post_capture_scope_permanent" {
                settleFreshReadURL = URL(string: "http://localhost:8123/settled-after-capture")!
            }
            if scenario == "post_capture_scope_twice" {
                afterInputScenario = "post_capture_scope_permanent"; postInputPending = true
            }
        }
        if holdPublicationAfterRead {
            holdPublicationAfterRead = false
            // Broker checks physical identity once after capture; the next
            // target lookup is the controller's final publication fence.
            targetChecksBeforeHold = 2
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
    func pressWithFeedback(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
                           permit: BrowserMutationPermit) async throws -> BrowserInputFeedback? {
        try await press(target: target, backendNodeID: backendNodeID, document: document, permit: permit)
        return invalidFieldOnPress ? .init(loaderID: document.loaderID, documentURL: document.url,
            fields: [.init(backendNodeID: 1, issues: [.valueMissing])], truncated: false,
            committedDocumentID: document.committedDocumentID) : nil
    }
    func setText(target:BrowserTarget,backendNodeID:Int64,text:String,document:BrowserDocumentObservation,permit:BrowserMutationPermit) async throws { try permit.commit { stats.fills += 1; field=text; didInput(target) } }
    func navigate(target:BrowserTarget,url:URL,permit:BrowserMutationPermit) async throws {
        try permit.commit { stats.navigations += 1; generation=UUID().uuidString; committedDocumentID=UUID(); targets[target.targetID]=BrowserTarget(targetID:target.targetID,instanceToken:target.instanceToken,title:target.title,url:url) }
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
    func showManyControls(count: Int = 100, buttonLast: Bool = false) {
        manyControls = true; extraControlCount = count; buttonAfterControls = buttonLast
    }
    func reloadDocument() { generation = UUID().uuidString }
    func holdNextRead() { holdRead = true }
    func configureAfterInput(_ scenario: String) { afterInputScenario = scenario }
    func waitUntilObservationHeld() async {
        if !observationHeld { await withCheckedContinuation { observationWaiters.append($0) } }
    }
    func resumeObservation() { observationContinuation?.resume(); observationContinuation = nil }
    func waitUntilFinalTargetHeld() async {
        if !finalTargetHeld { await withCheckedContinuation { finalTargetWaiters.append($0) } }
    }
    func resumeFinalTarget() { finalTargetContinuation?.resume(); finalTargetContinuation = nil }
    private func didInput(_ target: BrowserTarget) {
        guard let scenario = afterInputScenario else { return }
        switch scenario {
        case "redirect": redirectOwnedTarget(to: URL(string: "https://unrelated.example/PRIVATE_READ_ERROR")!)
        case "transient_scope":
            redirectOwnedTarget(to: URL(string: "https://unrelated.example/transient")!)
            settleFreshReadURL = URL(string: "http://localhost:8123/result")!
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
    func setLink(_ url: String, pressUnsupported: Bool = false, label: String = "Destination") {
        link = url; linkPressUnsupported = pressUnsupported; linkLabel = label
    }
    func disableButton() { buttonDisabled = true }
    func replaceButton() { buttonID = 99 }
    func replaceOwnedTarget() {
        for id in owned {
            guard let target = targets[id] else { continue }
            targets[id] = BrowserTarget(targetID:id,instanceToken:UUID().uuidString,title:target.title,
                                        url:target.url)
        }
    }
    func replaceOwnedTargetWithHumanIncarnation() {
        for id in Array(owned) {
            guard let target = targets[id] else { continue }
            targets[id] = BrowserTarget(targetID: id, instanceToken: UUID().uuidString,
                title: "Replacement user tab", url: target.url)
            owned.remove(id)
        }
    }
    func redirectOwnedTarget(to url: URL) {
        for id in owned {
            guard let target = targets[id] else { continue }
            targets[id] = BrowserTarget(targetID: id, instanceToken: target.instanceToken, title: target.title,
                                        url: url)
        }
    }
}
