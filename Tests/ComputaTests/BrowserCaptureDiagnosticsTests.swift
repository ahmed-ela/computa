import Foundation
import XCTest
@testable import Computa

final class BrowserCaptureDiagnosticsTests: XCTestCase {
    private func scheduling() -> [String: Any] {
        ["discoverySlots": 100, "panelProbes": 4, "partialPanels": 2,
         "controlsSeen": 6, "controlsVisible": 5, "controlsPrioritized": 4, "controlsEmitted": 3,
         "emittedByPriority": [1, 2, 3, 1], "pendingByPriority": [0, 0, 0, 10], "pendingClipped": false]
    }

    private func discovery() -> [String: Any] {
        ["panelsByState": [1, 2, 3, 4, 5], "prunedSubtrees": 10, "limitReached": false]
    }

    private func capture(scheduling: Any? = nil, discovery: Any? = nil) -> [String: Any] {
        var value: [String: Any] = ["stopReason": "byte_budget", "visited": 20, "emitted": 7,
            "estimatedBytes": 220_100, "visibilityState": "visible", "viewportWidth": 1_024, "viewportHeight": 768,
            "frames": 0, "shadowRoots": 0, "oversizedRoles": 0, "clippedFields": 0, "boxlessContents": 0]
        if let scheduling { value["scheduling"] = scheduling }
        if let discovery { value["discovery"] = discovery }
        return value
    }

    func testOptionalDiscoveryPreservesLegacyCaptureAndFiniteCounts() throws {
        let legacy = try BrowserCaptureDiagnostics.decode(capture(), emitted: 7, sourceTruncated: true)
        XCTAssertNil(legacy.discovery)
        let value = try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: discovery()),
            emitted: 7, sourceTruncated: true)
        XCTAssertEqual(value.discovery?.panelsByState, [1, 2, 3, 4, 5])
        XCTAssertEqual(value.discovery?.prunedSubtrees, 10)
        XCTAssertEqual(value.discovery?.limitReached, false)
        XCTAssertEqual(value.stopReason, legacy.stopReason)
        XCTAssertEqual(value.visited, legacy.visited)
        XCTAssertEqual(value.emitted, legacy.emitted)
        let roundTrip = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(BrowserCaptureDiagnostics.self, from: roundTrip), value)
    }

    func testDiscoveryRejectsUnknownPartialPrivateAndNonObjectPayloads() throws {
        for key in discovery().keys {
            var changed = discovery(); changed.removeValue(forKey: key)
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: changed), emitted: 7, sourceTruncated: true), key)
        }
        for key in ["text", "name", "value", "url", "nodeID", "owner", "extra"] {
            var changed = discovery(); changed[key] = "PRIVATE_CANARY"
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: changed), emitted: 7, sourceTruncated: true)) { error in
                XCTAssertFalse(String(describing: error).contains("PRIVATE_CANARY"))
            }
        }
        for malformed in [NSNull(), [], "PRIVATE_CANARY", true] as [Any] {
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: malformed), emitted: 7, sourceTruncated: true))
        }
    }

    func testDiscoveryRequiresFiveExactBoundedCountsAndBooleanLimitFlag() throws {
        for malformed in [[], [0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [true, 0, 0, 0, 0],
                          [false, 0, 0, 0, 0], [-1, 0, 0, 0, 0], [4_097, 0, 0, 0, 0],
                          [1.5, 0, 0, 0, 0], ["1", 0, 0, 0, 0], [NSNull(), 0, 0, 0, 0],
                          [Double.infinity, 0, 0, 0, 0], [Double.nan, 0, 0, 0, 0], NSNull()] as [Any] {
            var changed = discovery(); changed["panelsByState"] = malformed
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: changed), emitted: 7, sourceTruncated: true))
        }
        for malformed in [true, false, -1, 4_097, 1.5, "1", NSNull(), Double.infinity, Double.nan] as [Any] {
            var changed = discovery(); changed["prunedSubtrees"] = malformed
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: changed), emitted: 7, sourceTruncated: true))
        }
        for malformed in [0, 1, "false", NSNull()] as [Any] {
            var changed = discovery(); changed["limitReached"] = malformed
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: changed), emitted: 7, sourceTruncated: true))
        }
        var overBudget = discovery(); overBudget["panelsByState"] = [4_096, 1, 0, 0, 0]
        XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: overBudget), emitted: 7, sourceTruncated: true))
    }

    func testDiscoveryCountsAreBoundToExistingSharedTraversalSlots() throws {
        XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(discovery: discovery()), emitted: 7, sourceTruncated: true),
            "New discovery diagnostics require their existing scheduling counters; legacy captures without either remain valid")
        for (key, value) in [("panelsByState", [102, 0, 0, 0, 0] as Any), ("prunedSubtrees", 102 as Any), ("limitReached", true as Any)] {
            var changed = discovery(); changed[key] = value
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: changed), emitted: 7, sourceTruncated: true), key)
        }
        var rootInclusive = discovery()
        rootInclusive["panelsByState"] = [101, 0, 0, 0, 0]; rootInclusive["prunedSubtrees"] = 101
        XCTAssertNoThrow(try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling(), discovery: rootInclusive), emitted: 7, sourceTruncated: true))
        var limitReached = discovery(); limitReached["limitReached"] = true
        var schedule = scheduling(); schedule["discoverySlots"] = 4_096
        XCTAssertTrue(try XCTUnwrap(BrowserCaptureDiagnostics.decode(capture(scheduling: schedule, discovery: limitReached),
            emitted: 7, sourceTruncated: true).discovery).limitReached)
    }

    func testOptionalSchedulingPreservesLegacyCaptureAndFiniteCounts() throws {
        let legacy = try BrowserCaptureDiagnostics.decode(capture(), emitted: 7, sourceTruncated: true)
        XCTAssertNil(legacy.scheduling)
        let value = try BrowserCaptureDiagnostics.decode(capture(scheduling: scheduling()), emitted: 7, sourceTruncated: true)
        XCTAssertEqual(value.scheduling?.discoverySlots, 100)
        XCTAssertEqual(value.scheduling?.panelProbes, 4)
        XCTAssertEqual(value.scheduling?.partialPanels, 2)
        XCTAssertEqual(value.scheduling?.controlsSeen, 6)
        XCTAssertEqual(value.scheduling?.controlsVisible, 5)
        XCTAssertEqual(value.scheduling?.controlsPrioritized, 4)
        XCTAssertEqual(value.scheduling?.controlsEmitted, 3)
        XCTAssertEqual(value.scheduling?.emittedByPriority, [1, 2, 3, 1])
        XCTAssertEqual(value.scheduling?.pendingByPriority, [0, 0, 0, 10])
        XCTAssertEqual(value.scheduling?.pendingClipped, false)
        XCTAssertEqual(value.visited, legacy.visited)
        XCTAssertEqual(value.stopReason, legacy.stopReason)
        XCTAssertEqual(value.emitted, legacy.emitted)
    }

    func testSchedulingRejectsUnknownPartialAndPrivateFields() throws {
        for key in scheduling().keys {
            var value = scheduling(); value.removeValue(forKey: key)
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: value), emitted: 7, sourceTruncated: true), key)
        }
        for key in ["text", "name", "value", "url", "nodeID", "owner", "extra"] {
            var value = scheduling(); value[key] = "PRIVATE_CANARY"
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: value), emitted: 7, sourceTruncated: true)) { error in
                XCTAssertFalse(String(describing: error).contains("PRIVATE_CANARY"))
            }
        }
        for malformed in [NSNull(), [], "PRIVATE_CANARY", true] as [Any] {
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: malformed), emitted: 7, sourceTruncated: true))
        }
        var extra = capture(scheduling: scheduling()); extra["newDiagnostic"] = "PRIVATE_CANARY"
        XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(extra, emitted: 7, sourceTruncated: true))
    }

    func testSchedulingRequiresExactIntegerCountsAndBooleanFlag() throws {
        for key in ["discoverySlots", "panelProbes", "partialPanels", "controlsSeen", "controlsVisible", "controlsPrioritized", "controlsEmitted"] {
            let limit = key == "controlsEmitted" ? 3_000 : 4_096
            for malformed in [true, false, -1, limit + 1, 1.5, "1", NSNull(), Double.infinity, Double.nan] as [Any] {
                var value = scheduling(); value[key] = malformed
                XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: value), emitted: 7, sourceTruncated: true), key)
            }
        }
        for malformed in [0, 1, "false", NSNull()] as [Any] {
            var value = scheduling(); value["pendingClipped"] = malformed
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: value), emitted: 7, sourceTruncated: true))
        }
    }

    func testPriorityArraysAreFourBoundedIntegersAndAccountForEveryEmittedNode() throws {
        for key in ["emittedByPriority", "pendingByPriority"] {
            let limit = key == "emittedByPriority" ? 3_000 : 20_001
            for malformed in [[], [0, 0, 0], [0, 0, 0, 0, 0], [true, 0, 0, 0], [false, 0, 0, 0],
                              [-1, 0, 0, 0], [limit + 1, 0, 0, 0], [1.5, 0, 0, 0], ["1", 0, 0, 0], NSNull()] as [Any] {
                var value = scheduling(); value[key] = malformed
                XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: value), emitted: 7, sourceTruncated: true), key)
            }
        }
        var wrongSum = scheduling(); wrongSum["emittedByPriority"] = [1, 2, 3, 0]
        XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: wrongSum), emitted: 7, sourceTruncated: true))
        var clipped = scheduling(); clipped["pendingByPriority"] = [20_001, 0, 0, 0]; clipped["pendingClipped"] = true
        XCTAssertTrue(try XCTUnwrap(BrowserCaptureDiagnostics.decode(capture(scheduling: clipped), emitted: 7, sourceTruncated: true).scheduling).pendingClipped)
        clipped["pendingByPriority"] = [20_000, 0, 0, 0]
        XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: clipped), emitted: 7, sourceTruncated: true))
    }

    func testSchedulingEnforcesDiscoveryAdmissionAndEmissionSubsetInvariants() throws {
        for (key, value) in [("partialPanels", 5), ("controlsVisible", 7), ("controlsPrioritized", 6), ("controlsEmitted", 5)] {
            var changed = scheduling(); changed[key] = value
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: changed), emitted: 7, sourceTruncated: true), key)
        }
        var exceedsSource = scheduling()
        exceedsSource["controlsSeen"] = 8; exceedsSource["controlsVisible"] = 8
        exceedsSource["controlsPrioritized"] = 8; exceedsSource["controlsEmitted"] = 8
        XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(capture(scheduling: exceedsSource), emitted: 7, sourceTruncated: true))
    }

    func testMaximumFiniteSchedulingAndDiscoveryRecordFitsNativeLogBudget() throws {
        let schedule: [String: Any] = ["discoverySlots": 4_096, "panelProbes": 4_096, "partialPanels": 4_096,
            "controlsSeen": 4_096, "controlsVisible": 4_096, "controlsPrioritized": 4_096, "controlsEmitted": 3_000,
            "emittedByPriority": [1_000, 1_000, 1_000, 0], "pendingByPriority": [20_001, 20_001, 20_001, 20_001], "pendingClipped": false]
        let raw: [String: Any] = ["stopReason": "visited_limit", "visited": 20_001, "emitted": 3_000,
            "estimatedBytes": 1_000_000, "visibilityState": "prerender", "viewportWidth": 1_000_000, "viewportHeight": 1_000_000,
            "frames": 20_000, "shadowRoots": 20_000, "oversizedRoles": 20_000, "clippedFields": 20_000, "boxlessContents": 20_000,
            "scheduling": schedule,
            "discovery": ["panelsByState": [1_000, 1_000, 1_000, 1_000, 96], "prunedSubtrees": 4_096, "limitReached": false]]
        let diagnostics = try BrowserCaptureDiagnostics.decode(raw, emitted: 3_000, sourceTruncated: true)
        let record = BrowserCaptureLogRecord(tabID: UUID(), generation: UUID(), requestedReadiness: "semantic_content",
            readiness: "empty_at_deadline", capture: diagnostics, viewAttached: false, viewHasWindow: false,
            viewHidden: false, viewWidth: 1_000_000, viewHeight: 1_000_000)
        let captureBytes = try JSONEncoder().encode(diagnostics)
        let recordBytes = try JSONEncoder().encode(record)
        print("browserCaptureMaximumEncoding captureBytes=\(captureBytes.count) recordBytes=\(recordBytes.count)")
        XCTAssertGreaterThan(captureBytes.count, 512, "The enlarged diagnostic-only bound must cover the maximum finite schema")
        XCTAssertLessThanOrEqual(captureBytes.count, 768)
        XCTAssertLessThanOrEqual(recordBytes.count, 1_024, "Production must not silently drop the largest valid finite record")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: recordBytes) as? [String: Any])
        XCTAssertEqual(fields["kind"] as? String, "browser_capture_v1")
        XCTAssertEqual(Set(fields.keys), ["kind", "tabID", "generation", "requestedReadiness", "readiness", "capture",
                                         "viewAttached", "viewHasWindow", "viewHidden", "viewWidth", "viewHeight"])
    }
}
