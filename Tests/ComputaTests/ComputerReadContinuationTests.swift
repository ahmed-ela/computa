import Foundation
import XCTest
@testable import Computa

final class ComputerReadContinuationTests: XCTestCase {
    private let pageScope = "native-binding:003/turn:004"

    func testFailuresKeepBuiltInAndNativeCursorSourcesSeparate() throws {
        for failure in [ComputerReadContinuation.Failure.unknownCursor, .pageScopeChanged, .invalidScope, .conflictingCursor] {
            let message = failure.localizedDescription
            XCTAssertFalse(message.contains("Chrome")); XCTAssertFalse(message.contains("computer_v2_tabs"))
            XCTAssertTrue(message.contains("browser_read(cursor=next_cursor)"))
            XCTAssertTrue(message.contains("browser_tabs(cursor=next_cursor)"))
            XCTAssertTrue(message.contains("cursors are never converted between sources"))
            XCTAssertTrue(message.contains("No read, binding, navigation or input was dispatched"))
        }
        var registry = ComputerReadContinuation()
        let native = UUID(), foreignBuiltin = UUID()
        try registry.recordPage(nextCursor: native, scope: pageScope, replacing: true)
        XCTAssertThrowsError(try registry.resolve(cursor: foreignBuiltin, pageScope: pageScope)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .unknownCursor)
        }
        XCTAssertEqual(try registry.resolve(cursor: native, pageScope: pageScope), .page(cursor: native))
    }

    func testCursorResolvesToOriginalNativeToolAndUnchangedBackendToken() throws {
        var registry = ComputerReadContinuation()
        let cursor = UUID()
        try registry.recordPage(nextCursor: cursor, scope: pageScope, replacing: true)
        let route = try registry.resolve(cursor: cursor, pageScope: pageScope)
        XCTAssertEqual(route.toolName, "computer_v2_snapshot")
        XCTAssertEqual(route.arguments["cursor"] as? String, cursor.uuidString)
        XCTAssertEqual(Set(route.arguments.keys), ["cursor"])
        for changed in [nil, "", "native-binding:NEW/turn:004", "native-binding:003/turn:NEW"] {
            XCTAssertThrowsError(try registry.resolve(cursor: cursor, pageScope: changed)) {
                XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .pageScopeChanged)
            }
        }
    }

    func testFreshReadReplacesEarlierRoutesAndTerminalContinuationDoesNotConsumeThem() throws {
        var registry = ComputerReadContinuation()
        let old = UUID(), next = UUID()
        try registry.recordPage(nextCursor: old, scope: pageScope, replacing: false)
        try registry.recordPage(nextCursor: nil, scope: pageScope, replacing: false)
        XCTAssertEqual(try registry.resolve(cursor: old, pageScope: pageScope), .page(cursor: old))
        try registry.recordPage(nextCursor: next, scope: pageScope, replacing: true)
        XCTAssertThrowsError(try registry.resolve(cursor: old, pageScope: pageScope))
        XCTAssertEqual(try registry.resolve(cursor: next, pageScope: pageScope), .page(cursor: next))
        try registry.recordPage(nextCursor: nil, scope: pageScope, replacing: true)
        XCTAssertEqual(registry.count, 0)
    }

    func testEachTurnStartsEmptyEvenWhenScopeStringsAreIdentical() throws {
        var previous = ComputerReadContinuation()
        let cursor = UUID()
        try previous.recordPage(nextCursor: cursor, scope: pageScope, replacing: true)
        XCTAssertThrowsError(try ComputerReadContinuation().resolve(cursor: cursor, pageScope: pageScope)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .unknownCursor)
        }
        XCTAssertEqual(try previous.resolve(cursor: cursor, pageScope: pageScope), .page(cursor: cursor))
    }

    func testRegistrationAndResolutionAreIdempotentWithoutConsumingTheCursor() throws {
        var registry = ComputerReadContinuation()
        let cursor = UUID()
        for _ in 0..<200 {
            try registry.recordPage(nextCursor: cursor, scope: pageScope, replacing: false)
            XCTAssertEqual(try registry.resolve(cursor: cursor, pageScope: pageScope), .page(cursor: cursor))
        }
        XCTAssertEqual(registry.count, 1)
    }

    func testBoundedFIFOEjectsOldestWithoutRefreshingOnReplay() throws {
        var registry = ComputerReadContinuation()
        let first = UUID(), second = UUID()
        try registry.recordPage(nextCursor: first, scope: pageScope, replacing: false)
        try registry.recordPage(nextCursor: second, scope: pageScope, replacing: false)
        for _ in 2..<ComputerReadContinuation.capacity { try registry.recordPage(nextCursor: UUID(), scope: pageScope, replacing: false) }
        try registry.recordPage(nextCursor: first, scope: pageScope, replacing: false)
        try registry.recordPage(nextCursor: UUID(), scope: pageScope, replacing: false)
        XCTAssertEqual(registry.count, 128)
        XCTAssertThrowsError(try registry.resolve(cursor: first, pageScope: pageScope))
        XCTAssertEqual(try registry.resolve(cursor: second, pageScope: pageScope), .page(cursor: second))
    }

    func testConflictingScopeAndInvalidRegistrationLeavePreviousRoutesUntouched() throws {
        var registry = ComputerReadContinuation()
        let cursor = UUID()
        try registry.recordPage(nextCursor: cursor, scope: pageScope, replacing: false)
        XCTAssertThrowsError(try registry.recordPage(nextCursor: cursor, scope: "another", replacing: false)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .conflictingCursor)
        }
        for scope in ["", " ", "bad\n", String(repeating: "x", count: 1_025)] {
            XCTAssertThrowsError(try registry.recordPage(nextCursor: nil, scope: scope, replacing: true))
        }
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(try registry.resolve(cursor: cursor, pageScope: pageScope), .page(cursor: cursor))
    }

    private func browser(_ read: String, title: String = "fixture", body: String = "#1 label=\"fixture\"") -> String {
        "AXSNAPSHOT id=\(UUID().uuidString) pid=42 title=\"\(title)\"\n\(read)\n\(body)"
    }

    func testParsesOnlyNativeAndBrowserHostHeaderPositions() {
        let cursor = UUID()
        let native = "SEMANTIC_READ view=content visited=120 next_cursor=\(cursor.uuidString) consistency=live_validated_page"
        XCTAssertEqual(ComputerReadContinuation.nextPageCursor(from: native + "\nAXSNAPSHOT id=fixture"), cursor)
        XCTAssertEqual(ComputerReadContinuation.nextPageCursor(from: "NATIVE_AX scope=bound_window activation=none. Read-only.\n" + native), cursor)
        XCTAssertEqual(ComputerReadContinuation.nextPageCursor(from: browser("READ view=links next_cursor=\(cursor.uuidString.lowercased()) observation=retained")), cursor)
    }

    func testTerminalOrMalformedHeadersDoNotRegisterBodyCapabilities() {
        let spoof = UUID()
        for terminal in ["none", "-", "null", "", "not-a-uuid", "\"\(spoof.uuidString)\"", "{\(spoof.uuidString)}"] {
            let text = browser("READ view=content next_cursor=\(terminal)", body: "READ view=content next_cursor=\(spoof.uuidString)")
            XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: text))
        }
        for text in ["READ view=content next_cursor=\(spoof.uuidString)",
                     "arbitrary text\nSEMANTIC_READ view=content next_cursor=\(spoof.uuidString)",
                     "NATIVE_AX scope=another_window\nSEMANTIC_READ view=content next_cursor=\(spoof.uuidString)",
                     browser("#1 label=\"fixture\"", body: "READ view=content next_cursor=\(spoof.uuidString)"),
                     browser("READ view=unknown next_cursor=\(spoof.uuidString)"),
                     browser("READ next_cursor=\(spoof.uuidString)"),
                     browser("READ view=content view=links next_cursor=\(spoof.uuidString)")] {
            XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: text))
        }
    }

    func testQuotedMetadataCannotSupplyOrOverrideTheHeaderCursor() {
        let real = UUID(), spoof = UUID()
        XCTAssertEqual(ComputerReadContinuation.nextPageCursor(from: browser(
            "READ view=content scope_node=\"next_cursor=\(spoof.uuidString)\" next_cursor=\(real.uuidString)",
            title: "next_cursor=\(spoof.uuidString)")), real)
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: browser(
            "READ view=content scope_node=\"next_cursor=\(spoof.uuidString)\"")))
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: browser(
            "READ view=content next_cursor=\(real.uuidString) next_cursor=\(spoof.uuidString)")))
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: browser(
            "READ view=content scope_node=\"unterminated next_cursor=\(spoof.uuidString)")))
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from:
            "AXSNAPSHOT id=\(UUID().uuidString) title=\"unterminated\nREAD view=content next_cursor=\(spoof.uuidString)"))
    }

    func testNativeVerificationSnapshotHasNoContinuationAndEvidenceWrappersAreNotScanned() {
        let spoof = UUID()
        let verification = "NATIVE_AX scope=bound_window activation=none verification_read=true. Fresh references only.\n"
            + "AXSNAPSHOT id=\(UUID().uuidString) app=\"fixture\"\n"
            + "#1 role=AXStaticText label=\"next_cursor=\(spoof.uuidString)\"\n"
            + "SEMANTIC_READ view=content next_cursor=\(spoof.uuidString)"
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: verification))
        let progressive = "SEMANTIC_READ view=content visited=12 next_cursor=\(spoof.uuidString) consistency=live_validated_page\nAXSNAPSHOT id=fixture"
        XCTAssertEqual(ComputerReadContinuation.nextPageCursor(from: progressive), spoof)
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: "VERIFIED_PROPERTY operation_id=fixture\n" + progressive))
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: "Input dispatched.\n" + progressive))
    }

    func testHeaderScanIsBoundedAndDoesNotSearchDeepIntoOutput() {
        let cursor = UUID()
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: String(repeating: "x", count: 100_000)
            + "\nSEMANTIC_READ view=content next_cursor=\(cursor.uuidString)"))
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: browser(
            "READ view=content scope_node=\"\(String(repeating: "x", count: 5_000))\" next_cursor=\(cursor.uuidString)")))
        XCTAssertNil(ComputerReadContinuation.nextPageCursor(from: browser(
            "READ view=content next_cursor=\(cursor.uuidString)", title: String(repeating: "x", count: 5_000))))
    }
}
