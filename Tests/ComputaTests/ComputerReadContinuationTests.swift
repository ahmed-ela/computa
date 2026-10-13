import Foundation
import XCTest
@testable import Computa

final class ComputerReadContinuationTests: XCTestCase {
    func testPolicyAwareFailuresKeepCursorSourcesSeparateAndNeverInventARoute() throws {
        let failures: [ComputerReadContinuation.Failure] = [.unknownCursor, .inventoryScopeChanged, .pageScopeChanged,
                                                            .invalidPageSize, .invalidScope, .conflictingCursor]
        for failure in failures {
            let message = failure.message(externalChromeTools: false)
            XCTAssertFalse(message.contains("Chrome")); XCTAssertFalse(message.contains("computer_v2_tabs"))
            XCTAssertTrue(message.contains("browser_read(cursor=next_cursor)"))
            XCTAssertTrue(message.contains("browser_tabs(cursor=next_cursor)"))
            XCTAssertTrue(message.contains("cursors are never converted between sources"))
            XCTAssertTrue(message.contains("No read, binding, navigation or input was dispatched"))
            XCTAssertEqual(failure.message(externalChromeTools: true), failure.localizedDescription)
        }
        var registry = ComputerReadContinuation()
        let native = UUID(), foreignBuiltin = UUID()
        try registry.recordPage(nextCursor: native, scope: "native-current", replacing: true)
        XCTAssertThrowsError(try registry.resolve(cursor: foreignBuiltin, inventoryScope: nil, pageScope: "native-current")) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .unknownCursor)
        }
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(try registry.resolve(cursor: native, inventoryScope: nil, pageScope: "native-current"), .page(cursor: native))
        XCTAssertThrowsError(try ComputerReadContinuation().resolve(cursor: native, inventoryScope: nil, pageScope: "native-current"))
    }
    private let inventoryScope = "connection:001/owner-turn:002"
    private let pageScope = "binding:003/document:004"

    func testMixedCursorsResolveToTheirOriginalToolAndUnchangedBackendToken() throws {
        var registry = ComputerReadContinuation()
        let inventory = UUID(), page = UUID()
        try registry.recordInventory(nextCursor: inventory, pageSize: 17, scope: inventoryScope, replacing: true)
        try registry.recordPage(nextCursor: page, scope: pageScope, replacing: true)
        let inventoryRoute = try registry.resolve(cursor: inventory, inventoryScope: inventoryScope, pageScope: pageScope)
        let pageRoute = try registry.resolve(cursor: page, inventoryScope: inventoryScope, pageScope: pageScope)
        XCTAssertEqual(inventoryRoute, .inventory(cursor: inventory, pageSize: 17))
        XCTAssertEqual(inventoryRoute.toolName, "computer_v2_tabs")
        XCTAssertEqual(inventoryRoute.arguments["cursor"] as? String, inventory.uuidString)
        XCTAssertEqual(inventoryRoute.arguments["page_size"] as? Int, 17)
        XCTAssertEqual(Set(inventoryRoute.arguments.keys), ["cursor", "page_size"])
        XCTAssertEqual(pageRoute, .page(cursor: page))
        XCTAssertEqual(pageRoute.toolName, "computer_v2_snapshot")
        XCTAssertEqual(pageRoute.arguments["cursor"] as? String, page.uuidString)
        XCTAssertEqual(Set(pageRoute.arguments.keys), ["cursor"])
    }

    func testInventoryDoesNotBorrowPageScopeAndPageDoesNotBorrowInventoryScope() throws {
        var registry = ComputerReadContinuation()
        let inventory = UUID(), page = UUID()
        try registry.recordInventory(nextCursor: inventory, pageSize: 25, scope: inventoryScope, replacing: false)
        try registry.recordPage(nextCursor: page, scope: pageScope, replacing: false)
        XCTAssertThrowsError(try registry.resolve(cursor: inventory, inventoryScope: nil, pageScope: inventoryScope)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .inventoryScopeChanged)
        }
        XCTAssertThrowsError(try registry.resolve(cursor: page, inventoryScope: pageScope, pageScope: nil)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .pageScopeChanged)
        }
        XCTAssertEqual(try registry.resolve(cursor: page, inventoryScope: "irrelevant", pageScope: pageScope), .page(cursor: page))
    }

    func testConnectionOwnerTurnBindingAndNativeEvidenceChangesRejectStaleScope() throws {
        var registry = ComputerReadContinuation()
        let inventory = UUID(), browser = UUID(), native = UUID()
        try registry.recordInventory(nextCursor: inventory, pageSize: 25, scope: inventoryScope, replacing: false)
        try registry.recordPage(nextCursor: browser, scope: pageScope, replacing: false)
        try registry.recordPage(nextCursor: native, scope: "native-evidence:005", replacing: false)
        for changed in ["connection:NEW/owner-turn:002", "connection:001/owner-turn:NEW", ""] {
            XCTAssertThrowsError(try registry.resolve(cursor: inventory, inventoryScope: changed, pageScope: pageScope))
        }
        for changed in ["binding:NEW/document:004", "binding:003/document:NEW", "native-evidence:005"] {
            XCTAssertThrowsError(try registry.resolve(cursor: browser, inventoryScope: inventoryScope, pageScope: changed))
        }
        XCTAssertThrowsError(try registry.resolve(cursor: native, inventoryScope: inventoryScope, pageScope: "native-evidence:NEW"))
    }

    func testReplacingOneSourceDoesNotDiscardTheOtherSource() throws {
        var registry = ComputerReadContinuation()
        let oldInventory = UUID(), newInventory = UUID(), oldPage = UUID(), newPage = UUID()
        try registry.recordInventory(nextCursor: oldInventory, pageSize: 25, scope: inventoryScope, replacing: false)
        try registry.recordPage(nextCursor: oldPage, scope: pageScope, replacing: false)
        try registry.recordInventory(nextCursor: newInventory, pageSize: 10, scope: inventoryScope, replacing: true)
        XCTAssertThrowsError(try registry.resolve(cursor: oldInventory, inventoryScope: inventoryScope, pageScope: pageScope))
        XCTAssertEqual(try registry.resolve(cursor: oldPage, inventoryScope: inventoryScope, pageScope: pageScope), .page(cursor: oldPage))
        try registry.recordPage(nextCursor: newPage, scope: pageScope, replacing: true)
        XCTAssertThrowsError(try registry.resolve(cursor: oldPage, inventoryScope: inventoryScope, pageScope: pageScope))
        XCTAssertEqual(try registry.resolve(cursor: newInventory, inventoryScope: inventoryScope, pageScope: pageScope), .inventory(cursor: newInventory, pageSize: 10))
        XCTAssertEqual(registry.count, 2)
    }

    func testTerminalNilDoesNotRevokeIdempotentReplayUnlessTheSourceIsReplaced() throws {
        var registry = ComputerReadContinuation()
        let inventory = UUID(), page = UUID()
        try registry.recordInventory(nextCursor: inventory, pageSize: 100, scope: inventoryScope, replacing: false)
        try registry.recordPage(nextCursor: page, scope: pageScope, replacing: false)
        try registry.recordInventory(nextCursor: nil, pageSize: 100, scope: inventoryScope, replacing: false)
        try registry.recordPage(nextCursor: nil, scope: pageScope, replacing: false)
        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(try registry.resolve(cursor: inventory, inventoryScope: inventoryScope, pageScope: nil), .inventory(cursor: inventory, pageSize: 100))
        XCTAssertEqual(try registry.resolve(cursor: page, inventoryScope: nil, pageScope: pageScope), .page(cursor: page))
        try registry.recordInventory(nextCursor: nil, pageSize: 100, scope: inventoryScope, replacing: true)
        XCTAssertThrowsError(try registry.resolve(cursor: inventory, inventoryScope: inventoryScope, pageScope: nil))
        XCTAssertEqual(registry.count, 1)
        try registry.recordPage(nextCursor: nil, scope: pageScope, replacing: true)
        XCTAssertEqual(registry.count, 0)
    }

    func testEachTurnStartsEmptyEvenWhenScopeStringsAreIdentical() throws {
        var previous = ComputerReadContinuation()
        let cursor = UUID()
        try previous.recordPage(nextCursor: cursor, scope: pageScope, replacing: true)
        let newTurn = ComputerReadContinuation()
        XCTAssertThrowsError(try newTurn.resolve(cursor: cursor, inventoryScope: inventoryScope, pageScope: pageScope)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .unknownCursor)
        }
        XCTAssertEqual(try previous.resolve(cursor: cursor, inventoryScope: nil, pageScope: pageScope), .page(cursor: cursor))
    }

    func testRegistrationAndResolutionAreIdempotentWithoutConsumingTheCursor() throws {
        var registry = ComputerReadContinuation()
        let cursor = UUID()
        for _ in 0..<200 {
            try registry.recordInventory(nextCursor: cursor, pageSize: 1, scope: inventoryScope, replacing: false)
            XCTAssertEqual(try registry.resolve(cursor: cursor, inventoryScope: inventoryScope, pageScope: nil), .inventory(cursor: cursor, pageSize: 1))
        }
        XCTAssertEqual(registry.count, 1)
    }

    func testBoundedFIFOEjectsOldestWithoutRefreshingOnReplay() throws {
        var registry = ComputerReadContinuation()
        let first = UUID(), second = UUID()
        try registry.recordPage(nextCursor: first, scope: pageScope, replacing: false)
        try registry.recordInventory(nextCursor: second, pageSize: 25, scope: inventoryScope, replacing: false)
        for _ in 2..<ComputerReadContinuation.capacity {
            try registry.recordPage(nextCursor: UUID(), scope: pageScope, replacing: false)
        }
        try registry.recordPage(nextCursor: first, scope: pageScope, replacing: false)
        XCTAssertEqual(registry.count, 128)
        try registry.recordPage(nextCursor: UUID(), scope: pageScope, replacing: false)
        XCTAssertEqual(registry.count, 128)
        XCTAssertThrowsError(try registry.resolve(cursor: first, inventoryScope: inventoryScope, pageScope: pageScope))
        XCTAssertEqual(try registry.resolve(cursor: second, inventoryScope: inventoryScope, pageScope: pageScope), .inventory(cursor: second, pageSize: 25))
    }

    func testConflictingHostUUIDCannotChangeSourceOrScopeAndReplayKeepsOriginalPageSize() throws {
        var registry = ComputerReadContinuation()
        let cursor = UUID()
        try registry.recordInventory(nextCursor: cursor, pageSize: 25, scope: inventoryScope, replacing: false)
        XCTAssertThrowsError(try registry.recordPage(nextCursor: cursor, scope: pageScope, replacing: true)) {
            XCTAssertEqual($0 as? ComputerReadContinuation.Failure, .conflictingCursor)
        }
        try registry.recordInventory(nextCursor: cursor, pageSize: 26, scope: inventoryScope, replacing: false)
        XCTAssertThrowsError(try registry.recordInventory(nextCursor: cursor, pageSize: 25, scope: "another", replacing: false))
        XCTAssertEqual(try registry.resolve(cursor: cursor, inventoryScope: inventoryScope, pageScope: nil), .inventory(cursor: cursor, pageSize: 25))
        XCTAssertEqual(registry.count, 1)
    }

    func testConflictingReplacementAndInvalidRegistrationLeavePreviousRoutesUntouched() throws {
        var registry = ComputerReadContinuation()
        let page = UUID(), inventory = UUID()
        try registry.recordPage(nextCursor: page, scope: pageScope, replacing: false)
        try registry.recordInventory(nextCursor: inventory, pageSize: 25, scope: inventoryScope, replacing: false)
        XCTAssertThrowsError(try registry.recordPage(nextCursor: inventory, scope: pageScope, replacing: true))
        for scope in ["", " ", "bad\n", String(repeating: "x", count: 1_025)] {
            XCTAssertThrowsError(try registry.recordPage(nextCursor: nil, scope: scope, replacing: true))
        }
        for pageSize in [0, 101, -1, Int.max] {
            XCTAssertThrowsError(try registry.recordInventory(nextCursor: nil, pageSize: pageSize, scope: inventoryScope, replacing: true))
        }
        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(try registry.resolve(cursor: page, inventoryScope: nil, pageScope: pageScope), .page(cursor: page))
    }

    func testDiagnosticsRequestFreshReadsWithoutInventingPermissionFailure() {
        for failure in [ComputerReadContinuation.Failure.unknownCursor, .inventoryScopeChanged, .pageScopeChanged,
                        .invalidPageSize, .invalidScope, .conflictingCursor] {
            let message = failure.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("computer_v2_tabs") || message.contains("computer_v2_snapshot"))
            XCTAssertFalse(message.contains("permission"))
            XCTAssertFalse(message.contains("approve"))
            XCTAssertFalse(message.contains("reconnect"))
        }
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
