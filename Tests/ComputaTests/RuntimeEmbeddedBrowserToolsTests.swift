@testable import AutomationCore
import Foundation
import XCTest
@testable import Computa

/// The production runtime's JSON-RPC, active-turn and native approval boundary
/// with an inert browser backend. No provider, Chrome, UI or network is used.
@MainActor
final class RuntimeEmbeddedBrowserToolsTests: XCTestCase {
    func testBuiltInToolsAreOfferedOnlyWhenConfiguredAndNeedNoChromeBinding() async throws {
        for configured in [false, true] {
            try await withHarness(configured: configured) { harness in
                try await harness.submit([["tool": "browser_tabs", "arguments": [:]]])
                try await self.waitFor { harness.rowCount == 1 && harness.audit.status == .completed }
                let offered = try harness.offeredNames()
                XCTAssertEqual(offered.intersection(EmbeddedBrowserTools.names), configured ? EmbeddedBrowserTools.names : [])
                let row = try XCTUnwrap(harness.rows().first)
                XCTAssertEqual(row["success"] as? Bool, configured)
                if configured {
                    XCTAssertTrue((row["text"] as? String)?.contains("computa_builtin") == true)
                    XCTAssertTrue((row["text"] as? String)?.contains(InertRuntimeBrowser.humanID) == true)
                }
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.inventories, configured ? 1 : 0)
                XCTAssertEqual(counts.activations, 0)
                XCTAssertEqual(counts.mutations, 0)
                XCTAssertTrue(harness.audit.approvals.isEmpty)
            }
        }
    }

    func testProductCatalogRemovesChromeAndRejectsRetainedCallsBeforeAnyInput() async throws {
        try await withHarness { harness in
            try await harness.submit([
                ["tool": "computer_v2_tabs", "arguments": [:]],
                ["tool": "computer_v2_bind_tab", "arguments": ["candidate_token": UUID().uuidString]],
                ["tool": "computer_v2_create_workspace", "arguments": ["candidate_token": UUID().uuidString]],
                ["tool": "computer_v2_follow_link", "arguments": ["snapshot_id": UUID().uuidString, "element_index": 0]],
                ["tool": "browser_tabs", "arguments": [:]],
            ])
            try await self.waitFor { harness.rowCount == 5 && harness.audit.status == .completed }
            let offered = try harness.offeredNames()
            XCTAssertTrue(offered.isDisjoint(with: Set(["computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_create_workspace", "computer_v2_follow_link", "computer_v2_follow"])))
            XCTAssertEqual(offered.intersection(EmbeddedBrowserTools.names), EmbeddedBrowserTools.names)
            let rows = try harness.rows()
            for row in rows.prefix(4) {
                XCTAssertEqual(row["success"] as? Bool, false)
                XCTAssertTrue((row["text"] as? String)?.contains("Unknown computer V2 tool") == true)
            }
            XCTAssertEqual(rows.last?["success"] as? Bool, true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.inventories, 1)
            XCTAssertEqual(counts.activations, 0)
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
            XCTAssertFalse(harness.audit.entries.contains { $0.title == "Outcome not verified" })
            XCTAssertTrue(harness.audit.entries.contains { $0.kind == .assistant && $0.body == "Fixture workflow finished." },
                          "Retired routes must not suppress a later supported result with fabricated action debt")
        }
    }

    func testRetiredToolDoesNotSuppressSuccessfulBuiltInReadAndFinal() async throws {
        for call in [
            ["tool": "computer_v2_tabs", "arguments": [:]],
            ["tool": "computer_v2_bind_tab", "arguments": ["candidate_token": UUID().uuidString]],
            ["tool": "computer_v2_follow", "arguments": ["link_ref": "retired"]],
        ] as [[String: Any]] {
            try await withHarness(approval: true) { harness in
                try await harness.submit([
                    call,
                    ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                    ["tool": "browser_read", "arguments": ["view": "all"]],
                    ["tool": "browser_close", "arguments": [:]],
                ])
                try await self.waitFor { harness.rowCount == 4 && harness.audit.status == .completed }
                let rows = try harness.rows()
                XCTAssertEqual(rows.first?["success"] as? Bool, false)
                let denial = try XCTUnwrap(rows.first?["text"] as? String)
                XCTAssertTrue(denial.contains("Unknown computer V2 tool"))
                XCTAssertFalse(denial.contains("ACTION_EVIDENCE"))
                XCTAssertFalse(denial.contains("operation="))
                XCTAssertTrue(rows.dropFirst().allSatisfy { $0["success"] as? Bool == true })
                XCTAssertTrue((rows[2]["text"] as? String)?.contains("United flight fixture") == true)
                XCTAssertFalse(harness.audit.entries.contains { $0.title == "Outcome not verified" })
                XCTAssertTrue(harness.audit.entries.contains { $0.kind == .assistant && $0.body == "Fixture workflow finished." })
                XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_close"])
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.created, 1)
                XCTAssertEqual(counts.ownedClosed, 1)
                XCTAssertEqual(counts.activations, 0)
                XCTAssertEqual(counts.mutations, 0)
                XCTAssertTrue(counts.humanIntact)
            }
        }
    }

    func testNativeStatusUnboundReadAndTurnGuidanceUseOnlyCurrentRoutes() async throws {
        try await withHarness { harness in
            try await harness.submit([
                ["tool": "computer_v2_status", "arguments": [:]],
                ["tool": "computer_v2_read_page", "arguments": [:]],
            ])
            try await self.waitFor { harness.rowCount == 2 && harness.audit.status == .waiting }
            let rows = try harness.rows()
            XCTAssertEqual(rows.first?["success"] as? Bool, true)
            XCTAssertEqual(rows.last?["success"] as? Bool, false)
            for row in rows {
                let text = try XCTUnwrap(row["text"] as? String)
                XCTAssertTrue(text.contains("computer_v2_open"))
                XCTAssertTrue(text.contains("browser_read"))
                XCTAssertFalse(text.contains("computer_v2_tabs"))
                XCTAssertFalse(text.contains("computer_v2_bind_tab"))
            }
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("turn-input.json"))) as? [[String: Any]])
            let policy = try XCTUnwrap(input.compactMap { $0["text"] as? String }.first { $0.hasPrefix("APP_RUNTIME_INTERACTION_POLICY:") })
            XCTAssertTrue(policy.contains("native background AX"))
            XCTAssertTrue(policy.contains("built-in browser"))
            XCTAssertFalse(policy.contains("authorized Chrome"))
        }
    }

    func testInvalidBuiltInMutationFailsBeforeApprovalAndPreservesValidTarget() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_click", "arguments": ["click_ref": "bclick_00000000-0000-4000-8000-000000000000"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@buttonClickRef", "text": "MUST_NOT_FILL"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "UA 123"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
            ])
            try await self.waitFor { harness.rowCount == 6 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, false, true, true])
            XCTAssertTrue((rows[2]["text"] as? String)?.contains("No input was dispatched") == true)
            XCTAssertTrue((rows[3]["text"] as? String)?.contains("No input was dispatched") == true)
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_fill"],
                           "Unoffered and wrong-kind references must fail before any approval request")
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.fills, 1)
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(counts.navigations, 0)
            XCTAssertTrue((rows.last?["text"] as? String)?.contains("UA 123") == true)
        }
    }

    func testLegacyBrowserTargetTupleDoesNotPromptOrDispatchAndPreservesCurrentRead() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_click", "arguments": ["snapshot_id": "@snapshot", "element_index": "@button",
                    "expected_role": "@buttonRole", "expected_label": "Sent"]],
                ["tool": "browser_click", "arguments": ["click_ref": "@buttonClickRef"]],
            ])
            try await self.waitFor { harness.rowCount == 4 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, true])
            let failure = try XCTUnwrap(rows[2]["text"] as? String)
            XCTAssertFalse(failure.isEmpty)
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_click"],
                           "A retired tuple must fail before approval, without consuming the current typed reference")
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.fills, 0)
            XCTAssertEqual(counts.navigations, 0)
        }
    }

    func testRetiredRouteAndBuiltInSuccessCannotEraseDispatchedNativeDebt() async throws {
        try await withHarness(approval: true) { harness in
            let native = PendingNativeSelectionBackend()
            let background = NativeBackgroundAccessibility(backend: native, foregroundProcessIdentifier: { 999 })
            try await harness.submit([
                ["tool": "computer_v2_snapshot", "arguments": [:]],
                ["tool": "computer_v2_ax", "arguments": ["snapshot_id": "@snapshot", "element_index": "@nativeRow", "ax_action": "AXPress"]],
                ["tool": "computer_v2_follow_link", "arguments": ["snapshot_id": UUID().uuidString, "element_index": 0]],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_close", "arguments": [:]],
            ], pauseForNativeBinding: true)
            try await self.waitFor { FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("native-binding-ready").path) }
            try await harness.runtime.installNativeBackgroundBindingForFixture(taskID: Harness.taskID,
                application: .init(processIdentifier: 123, bundleIdentifier: "com.example.pending-native-selection", localizedName: "Pending fixture"),
                background: background)
            try Data("continue".utf8).write(to: harness.root.appendingPathComponent("native-binding-continue"))
            try await self.waitFor { harness.rowCount == 6 && harness.audit.status == .waiting }
            let rows = try harness.rows()
            XCTAssertEqual(rows[1]["success"] as? Bool, true)
            XCTAssertTrue((rows[1]["text"] as? String)?.contains("VERIFICATION_PENDING") == true)
            XCTAssertEqual(native.actions, 1)
            XCTAssertEqual(native.postInputReads, 3)
            XCTAssertEqual(rows[2]["success"] as? Bool, false)
            let denied = try XCTUnwrap(rows[2]["text"] as? String)
            XCTAssertTrue(denied.contains("Unknown computer V2 tool"))
            XCTAssertTrue(denied.contains("operation=call-1-1 tool=computer_v2_ax dispatch=dispatched"))
            XCTAssertFalse(denied.contains("operation=call-1-2"), "The new rejected route is not another admitted action")
            XCTAssertTrue(rows.suffix(3).allSatisfy { $0["success"] as? Bool == true })
            XCTAssertEqual(harness.audit.entries.filter { $0.title == "Outcome not verified" }.count, 1)
            XCTAssertFalse(harness.audit.entries.contains { $0.kind == .assistant && $0.body == "Fixture workflow finished." })
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.created, 1)
            XCTAssertEqual(counts.ownedClosed, 1)
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertTrue(counts.humanIntact)
        }
    }

    func testLegacyPIDReadsTreatBrowsersAsOrdinaryNativeApps() async throws {
        for bundleID in ["com.example.native-pid-fixture", "com.google.Chrome"] {
            let process = LegacyPIDFixture(bundleID: bundleID, replacement: nil)
            try await withHarness(legacyPIDFixture: process) { harness in
                try await harness.submit([
                    ["tool": "desktop_snapshot_app", "arguments": ["pid": LegacyPIDFixture.processID]],
                    ["tool": "computer", "arguments": ["action": "snapshot", "parameters": ["process_id": LegacyPIDFixture.processID]]],
                ])
                try await self.waitFor { harness.rowCount == 2 && harness.audit.status == .completed }
                let rows = try harness.rows()
                XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == true })
                XCTAssertTrue(rows.allSatisfy { ($0["text"] as? String)?.contains("OWNED_NATIVE_PID_OBSERVATION") == true })
                let counts = await process.counts()
                XCTAssertEqual(counts.reads, 2)
                XCTAssertGreaterThanOrEqual(counts.lookups, 8, "Each read must revalidate its exact process generation before and after observation")
                XCTAssertTrue(harness.audit.approvals.isEmpty)
                XCTAssertFalse(harness.audit.entries.contains { $0.title == "Outcome not verified" })
            }
        }
    }

    func testLegacyPIDReuseAndNewLaunchAreRejectedBeforeNativeRead() async throws {
        for replacement in [LegacyPIDFixture.Replacement.chrome, .sameBundleNewLaunch, .unavailable] {
            for call in [
                ["tool": "desktop_snapshot_app", "arguments": ["process_id": LegacyPIDFixture.processID]],
                ["tool": "computer", "arguments": ["action": "snapshot", "parameters": ["process_id": LegacyPIDFixture.processID]]],
            ] as [[String: Any]] {
                let process = LegacyPIDFixture(bundleID: "com.example.native-pid-fixture", replacement: replacement)
                try await withHarness(legacyPIDFixture: process) { harness in
                    try await harness.submit([call])
                    try await self.waitFor { harness.rowCount == 1 && harness.audit.status == .waiting }
                    let row = try XCTUnwrap(harness.rows().first)
                    XCTAssertEqual(row["success"] as? Bool, false)
                    let text = try XCTUnwrap(row["text"] as? String)
                    XCTAssertTrue(text.contains(replacement == .unavailable ? "could not be verified" : "identity changed"))
                    XCTAssertFalse(text.contains("OWNED_NATIVE_PID_OBSERVATION"))
                    let counts = await process.counts()
                    XCTAssertEqual(counts.lookups, 2)
                    XCTAssertEqual(counts.reads, 0)
                    XCTAssertTrue(harness.audit.approvals.isEmpty)
                    XCTAssertFalse(harness.audit.entries.contains { $0.kind == .assistant && $0.body == "Fixture workflow finished." })
                }
            }
        }
    }

    func testLegacyIdentityLossAfterReadDiscardsObservationWithoutClaimingNoRead() async throws {
        for replacement in [LegacyPIDFixture.Replacement.sameBundleNewLaunch, .unavailable] {
            for call in [
                ["tool": "desktop_snapshot_app", "arguments": ["process_id": LegacyPIDFixture.processID]],
                ["tool": "computer", "arguments": ["action": "snapshot", "parameters": ["process_id": LegacyPIDFixture.processID]]],
            ] as [[String: Any]] {
                let process = LegacyPIDFixture(bundleID: "com.example.native-pid-fixture",
                    replacement: replacement, replaceAfterRead: true)
                try await withHarness(legacyPIDFixture: process) { harness in
                    try await harness.submit([call])
                    try await self.waitFor { harness.rowCount == 1 && harness.audit.status == .waiting }
                    let row = try XCTUnwrap(harness.rows().first)
                    XCTAssertEqual(row["success"] as? Bool, false)
                    let text = try XCTUnwrap(row["text"] as? String)
                    XCTAssertTrue(text.contains("after the read"))
                    XCTAssertTrue(text.contains("observation was discarded and not published"))
                    XCTAssertTrue(text.contains(replacement == .unavailable ? "could not be verified" : "identity changed"))
                    XCTAssertFalse(text.contains("No native read"))
                    XCTAssertFalse(text.contains("OWNED_NATIVE_PID_OBSERVATION"))
                    let counts = await process.counts()
                    XCTAssertEqual(counts.reads, 1, "The actual owned fixture read occurred; only its publication was denied")
                    XCTAssertTrue(harness.audit.approvals.isEmpty)
                    XCTAssertFalse(harness.audit.entries.contains { $0.kind == .assistant && $0.body == "Fixture workflow finished." })
                }
            }
        }
    }

    func testNativeReferenceInterfaceDoesNotRewriteDedicatedBuiltInBrowserOutput() async throws {
        try await withHarness { harness in
            try await harness.submit([
                ["tool": "computer_v2_read_page", "arguments": [:]],
                ["tool": "browser_tabs", "arguments": [:]],
            ])
            try await self.waitFor { harness.rowCount == 2 }
            let row = try XCTUnwrap(harness.rows().last)
            XCTAssertEqual(row["success"] as? Bool, true)
            let text = try XCTUnwrap(row["text"] as? String)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(json["browser"] as? String, "computa_builtin")
            XCTAssertEqual((json["tabs"] as? [[String: Any]])?.first?["tab_id"] as? String, InertRuntimeBrowser.humanID)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.activations, 0)
        }
    }

    func testApprovedOpenReadFillClickAndCompletionUseExactBackendAndCleanOnlyOwnedTab() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "UA 123"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_click", "arguments": ["click_ref": "@buttonClickRef"]],
                ["tool": "browser_read", "arguments": ["view": "content"]],
            ])
            try await self.waitFor { harness.rowCount == 6 && harness.audit.status == .completed }
            try await self.waitForAsync { await harness.backend.counts().ownedClosed == 1 }
            let rows = try harness.rows()
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == true })
            for (index, kind, label) in [(2, "fill", "Search flights"), (4, "click", "Find flight")] {
                let items = try XCTUnwrap(rows[index]["contentItems"] as? [[String: Any]])
                XCTAssertEqual(items.count, 2, "Separate items preserve the dispatch cue through native history compaction")
                let compact = try XCTUnwrap(items[0]["text"] as? String)
                XCTAssertLessThanOrEqual(compact.utf8.count, 128)
                let cue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(compact.utf8)) as? [String: Any])
                XCTAssertEqual(cue["kind"] as? String, kind)
                XCTAssertEqual(cue["label"] as? String, label)
                XCTAssertEqual(cue["partial"] as? Bool, false)
                XCTAssertEqual(cue["dispatched"] as? Bool, true)
                XCTAssertEqual(cue["outcome"] as? String, "unverified")
                XCTAssertEqual(Set(cue.keys), ["kind", "label", "partial", "dispatched", "outcome"])
                let observation = try XCTUnwrap(items[1]["text"] as? String)
                let full = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observation.utf8)) as? [String: Any])
                XCTAssertEqual(full["input_kind"] as? String, kind)
                XCTAssertEqual(full["result_verified"] as? Bool, false)
                XCTAssertEqual(full["no_replay"] as? Bool, true)
                let current = try XCTUnwrap(full["current_observation"] as? [String: Any])
                XCTAssertEqual(current["status"] as? String, "available")
                XCTAssertTrue((current["text"] as? String)?.contains("AXSNAPSHOT") == true)
            }
            for index in [0, 1, 3, 5] {
                XCTAssertEqual((rows[index]["contentItems"] as? [[String: Any]])?.count, 1,
                               "Reads and navigation do not receive a click/fill dispatch cue")
            }
            XCTAssertTrue((rows[3]["text"] as? String)?.contains("UA 123") == true)
            XCTAssertTrue((rows[5]["text"] as? String)?.contains("UA 123 departs at 14:35") == true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.created, 1)
            XCTAssertEqual(counts.fills, 1)
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.activations, 0)
            XCTAssertEqual(counts.humanCloseAttempts, 0)
            XCTAssertTrue(counts.humanIntact)
            XCTAssertEqual(harness.audit.approvals.map(\.kind), [.computerUse, .computerUse, .computerUse])
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_fill", "browser_click"])
            XCTAssertTrue(harness.audit.approvals[1].details.contains("Search flights"),
                          "Approval must describe the frozen target, not only its opaque reference")
            XCTAssertTrue(harness.audit.approvals[1].details.contains("UA 123"))
            XCTAssertTrue(harness.audit.approvals[2].details.contains("Find flight"))
            XCTAssertFalse(harness.audit.entries.contains { $0.toolEvent?.name.hasPrefix("computer_v2_") == true })
        }
    }

    func testCompletionWaitsForPhysicalTabDisposalAndSavesAutomaticProvenance() async throws {
        try await withHarness(approval: true) { harness in
            await harness.backend.holdNextClose()
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
            ])
            try await self.waitForAsync { await harness.backend.isCloseHeld() }
            XCTAssertEqual(harness.audit.status, .running, "Native completion cannot publish resources-settled completion before disposal")
            XCTAssertTrue(try harness.cleanupReceipts().isEmpty)
            XCTAssertFalse(harness.audit.entries.contains { $0.title == "Browser cleanup" })
            await harness.backend.resumeClose()
            try await self.waitFor { harness.audit.status == .completed }
            let receipts = try harness.cleanupReceipts()
            XCTAssertEqual(receipts.count, 1)
            let receipt = try XCTUnwrap(receipts.first)
            XCTAssertEqual(receipt.taskID, Harness.taskID)
            XCTAssertEqual(receipt.threadID, "embedded-browser-thread")
            XCTAssertEqual(receipt.turnID, "embedded-turn-1")
            XCTAssertTrue(receipt.report.isSettled)
            XCTAssertEqual(receipt.report.targets.count, 1)
            XCTAssertTrue(receipt.report.targets[0].closed)
            XCTAssertEqual(receipt.report.targets[0].trigger, .automatic)
            XCTAssertFalse(try harness.rows().contains { $0["tool"] as? String == "browser_close" })
            XCTAssertTrue(harness.audit.entries.contains { $0.title == "Browser cleanup" && $0.body.contains("not a model-issued browser_close") })
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.ownedClosed, 1)
            XCTAssertEqual(counts.humanCloseAttempts, 0)
            XCTAssertTrue(counts.humanIntact)
        }
    }

    func testExplicitCloseIsSavedOnceWithoutAutomaticCloseCredit() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_close", "arguments": [:]],
            ])
            try await self.waitFor { harness.audit.status == .completed }
            let receipts = try harness.cleanupReceipts()
            XCTAssertEqual(receipts.count, 1)
            let receipt = try XCTUnwrap(receipts.first)
            XCTAssertTrue(receipt.report.isSettled)
            XCTAssertEqual(receipt.report.targets.map(\.trigger), [.explicit])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.ownedClosed, 1)
            XCTAssertTrue(counts.humanIntact)
            XCTAssertTrue(harness.audit.entries.contains { $0.body.contains("model's browser_close") })
        }
    }

    func testFailedPhysicalCloseKeepsTerminalWaitingAndSavesUncertainty() async throws {
        try await withHarness(approval: true, allowsCleanupFailure: true) { harness in
            await harness.backend.failNextClose()
            try await harness.submit([["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]]])
            try await self.waitFor { harness.audit.status == .waiting }
            let receipts = try harness.cleanupReceipts()
            XCTAssertEqual(receipts.count, 1)
            let receipt = try XCTUnwrap(receipts.first)
            XCTAssertFalse(receipt.report.isSettled)
            XCTAssertEqual(receipt.report.targets.map(\.closed), [false])
            XCTAssertTrue(receipt.report.failures.contains(.ownedTargetCloseFailed))
            XCTAssertTrue(harness.audit.entries.contains { $0.title == "Browser cleanup unconfirmed" })
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.ownedClosed, 0)
            XCTAssertTrue(counts.humanIntact)
        }
    }

    func testCleanupPersistenceFailureCannotPublishCompletedOrRepeatPhysicalClose() async throws {
        try await withHarness(approval: true, allowsCleanupFailure: true) { harness in
            try Data("not a directory".utf8).write(to: harness.root.appendingPathComponent("EmbeddedBrowserCleanup-v1"))
            try await harness.submit([["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]]])
            try await self.waitFor { harness.audit.status == .waiting }
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.ownedClosed, 1)
            XCTAssertTrue(counts.humanIntact)
            XCTAssertTrue(harness.audit.entries.contains {
                $0.title == "Browser cleanup unconfirmed" && $0.body.contains("evidence could not be saved")
            })
        }
    }

    func testDecliningOpenAndFillNeverDispatchesBrowserInput() async throws {
        for mutation in ["browser_open", "browser_fill"] {
            try await withHarness(approval: false) { harness in
                let calls: [[String: Any]] = mutation == "browser_open"
                    ? [["tool": mutation, "arguments": ["url": "https://example.invalid/flight"]]]
                    : [
                        ["tool": "browser_tabs", "arguments": [:]],
                        ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                        ["tool": "browser_read", "arguments": ["view": "all"]],
                        ["tool": mutation, "arguments": ["fill_ref": "@fieldFillRef", "text": "MUST_NOT_FILL"]],
                    ]
                try await harness.submit(calls)
                try await self.waitFor { harness.rowCount == calls.count && harness.audit.status == .completed }
                let final = try XCTUnwrap(harness.rows().last)
                XCTAssertEqual(final["success"] as? Bool, false)
                XCTAssertTrue((final["text"] as? String)?.contains("declined") == true)
                let items = try XCTUnwrap(final["contentItems"] as? [[String: Any]])
                XCTAssertEqual(items.count, 1)
                XCTAssertFalse((items[0]["text"] as? String ?? "").contains("\"dispatched\":true"))
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.created, 0)
                XCTAssertEqual(counts.mutations, 0)
                XCTAssertTrue(counts.humanIntact)
                XCTAssertEqual(counts.humanCloseAttempts, 0)
                XCTAssertEqual(harness.audit.approvals.map(\.kind), [.computerUse])
                XCTAssertEqual(harness.audit.approvals.first?.summary, mutation)
            }
        }
    }

    func testStopRetiresPendingApprovalBeforeLateAcceptanceAndNextTurnIsUsable() async throws {
        try await withHarness { harness in
            try await harness.submit([["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]]], interruptProbe: true)
            try await self.waitFor { harness.audit.approvals.count == 1 }
            let approval = try XCTUnwrap(harness.audit.approvals.first)
            try await harness.runtime.interrupt(taskID: Harness.taskID)
            do {
                try await harness.runtime.resolveApproval(requestID: approval.id, approved: true)
                XCTFail("An approval from the stopped turn must be retired")
            } catch { XCTAssertTrue(error.localizedDescription.contains("no longer pending")) }
            let stopped = await harness.backend.counts()
            XCTAssertEqual(stopped.created, 0)
            let stopProbe = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("stop-window-result.json"))) as? [String: Any])
            XCTAssertEqual(stopProbe["success"] as? Bool, false,
                           "A correctly tagged call arriving after Stop but before terminal notification has no active browser authority")
            XCTAssertTrue(stopProbe["error"] is String || !(stopProbe["text"] as? String ?? "").isEmpty)
            XCTAssertEqual(harness.audit.approvals.count, 1, "The new call in the stopping turn cannot request another approval")
            harness.audit.status = nil
            try await harness.submit([["tool": "browser_tabs", "arguments": [:]]])
            try await self.waitFor { harness.audit.status == .completed && harness.rowCount == 1 }
            XCTAssertEqual(try harness.rows().last?["success"] as? Bool, true)
            XCTAssertEqual(harness.audit.approvals.count, 1)
            let continued = await harness.backend.counts()
            XCTAssertEqual(continued.mutations, 0)
        }
    }

    func testWrongMissingStaleAndForeignTurnRequestsNeverReachApprovalOrBackend() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "turn": "wrong"],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "turn": "missing"],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "turn": "previous"],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "foreignThread": true],
                ["tool": "browser_tabs", "arguments": [:]],
            ])
            try await self.waitFor { harness.rowCount == 5 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertTrue(rows.prefix(4).allSatisfy { $0["success"] as? Bool == false })
            XCTAssertTrue(rows.prefix(4).allSatisfy { ($0["error"] as? String)?.contains("active turn") == true })
            XCTAssertEqual(rows.last?["success"] as? Bool, true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.inventories, 1)
            XCTAssertEqual(counts.created, 0)
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
        }
    }

    func testThreeIdenticalInvalidURLsStopBeforeFourthInputAndFreshTurnStillWorks() async throws {
        try await withHarness(approval: true) { harness in
            let invalid: [String: Any] = ["tool": "browser_open", "arguments": ["url": "file:///MUST_NOT_OPEN"]]
            try await harness.submit([
                invalid, invalid, invalid,
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/MUST_NOT_OPEN"]],
            ])
            try await self.waitFor {
                harness.rowCount == 3 && harness.audit.status == .waiting
                    && harness.audit.entries.contains { $0.title == "Native action stopped" }
            }
            let rows = try harness.rows()
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == false })
            XCTAssertTrue((rows[0]["text"] as? String)?.contains("HTTP or HTTPS") == true)
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
            XCTAssertEqual(sent.count, 3, "The runtime must interrupt while the third failed call is outstanding, before the fixture sends its fourth input")
            XCTAssertTrue(sent.allSatisfy { $0["tool"] as? String == "browser_open" })
            let stopped = await harness.backend.counts()
            XCTAssertEqual(stopped.created, 0)
            XCTAssertEqual(stopped.inventories, 0)
            XCTAssertEqual(stopped.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)

            harness.audit.status = nil
            try await harness.submit([["tool": "browser_tabs", "arguments": [:]]])
            try await self.waitFor { harness.rowCount == 4 && harness.audit.status == .completed }
            XCTAssertEqual(try harness.rows().last?["success"] as? Bool, true)
            let continued = await harness.backend.counts()
            XCTAssertEqual(continued.inventories, 1)
            XCTAssertEqual(continued.created, 0)
            XCTAssertEqual(continued.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
        }
    }

    func testUnboundTurnGuidanceCanRecoverThroughApprovedOpenWithoutReplayingOldInput() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_click", "arguments": ["click_ref": "bclick_00000000-0000-4000-8000-000000000000"]],
                ["tool": "browser_read", "arguments": ["view": "overview"]],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "UA 123"]],
            ])
            try await self.waitFor { harness.rowCount == 5 && harness.audit.status == .completed }
            let rows = try harness.rows()
            for row in rows.prefix(2) {
                XCTAssertEqual(row["success"] as? Bool, false)
                let text = try XCTUnwrap(row["text"] as? String)
                XCTAssertTrue(text.contains("browser_binding_required"))
                XCTAssertTrue(text.contains("not a permission denial"))
                XCTAssertTrue(text.contains("browser_open"))
            }
            XCTAssertTrue(rows.dropFirst(2).allSatisfy { $0["success"] as? Bool == true })
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_fill"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.created, 1); XCTAssertEqual(counts.ownedClosed, 1)
            XCTAssertEqual(counts.mutations, 1); XCTAssertEqual(counts.activations, 0)
            XCTAssertFalse(harness.audit.entries.contains { $0.title == "Native action stopped" })
            XCTAssertTrue(harness.audit.entries.contains { $0.kind == .assistant && $0.body == "Fixture workflow finished." })
        }
    }

    func testTurnCompletionRetiresOldReferenceAndPreservesBoundHumanPage() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_tabs", "arguments": [:]],
                ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                ["tool": "browser_read", "arguments": ["view": "all"], "saveFillRef": "old_fill_ref"],
            ])
            try await self.waitFor { harness.rowCount == 3 && harness.audit.status == .completed }
            harness.audit.status = nil
            try await harness.submit([
                ["tool": "browser_tabs", "arguments": [:]],
                ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@old_fill_ref", "text": "MUST_NOT_FILL"]],
            ])
            try await self.waitFor { harness.rowCount == 7 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertTrue(rows.prefix(6).allSatisfy { $0["success"] as? Bool == true })
            XCTAssertEqual(rows[6]["success"] as? Bool, false)
            XCTAssertTrue((rows[6]["text"] as? String)?.contains("browser_action_reference_invalid") == true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertEqual(counts.humanCloseAttempts, 0)
            XCTAssertTrue(counts.humanIntact)
        }
    }

    func testStaleBrowserPreflightReturnsFailedReadRecoveryAndRequiresANewApprovedCall() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"], "saveFillRef": "old_fill_ref"],
                ["tool": "browser_read", "arguments": ["view": "content"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@old_fill_ref", "text": "MUST_NOT_FILL"], "captureRecovery": true],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "UA 123"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
            ])
            try await self.waitFor { harness.rowCount == 6 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, true, false, true, true])
            let failure = try XCTUnwrap(rows[3]["text"] as? String)
            XCTAssertTrue(failure.contains("stale_snapshot"))
            XCTAssertTrue(failure.contains("\"dispatched\":false"))
            XCTAssertTrue(failure.contains("\"status\":\"available\""))
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_fill"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.fills, 1); XCTAssertEqual(counts.presses, 0)
            XCTAssertTrue((rows.last?["text"] as? String)?.contains("UA 123") == true)
            XCTAssertFalse((rows.last?["text"] as? String)?.contains("MUST_NOT_FILL") == true)
        }
    }

    func testBrowserReadRecoveryDoesNotResetRepeatedFailureStopOrReplayInput() async throws {
        try await withHarness(approval: true) { harness in
            let stale: [String: Any] = ["tool": "browser_fill", "arguments": [
                "fill_ref": "@old_fill_ref", "text": "MUST_NOT_FILL",
            ]]
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"], "saveFillRef": "old_fill_ref"],
                ["tool": "browser_read", "arguments": ["view": "content"]],
                stale, stale, stale,
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "MUST_NOT_FILL_AFTER_STOP"]],
            ])
            try await self.waitFor {
                harness.rowCount == 6 && harness.audit.status == .waiting
                    && harness.audit.entries.contains { $0.title == "Native action stopped" }
            }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, true, false, false, false])
            XCTAssertTrue((rows[3]["text"] as? String)?.contains("\"status\":\"available\"") == true)
            XCTAssertTrue((rows[4]["text"] as? String)?.contains("\"status\":\"unavailable\"") == true)
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
            XCTAssertEqual(sent.count, 6, "The third unchanged failure must interrupt before another input request")
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.mutations, 0)
        }
    }

    func testNullFreshReadCannotRefundSameDocumentContinuationFailures() async throws {
        try await withHarness(approval: true) { harness in
            await harness.backend.enablePaginatedRead()
            let read: [String: Any] = ["tool": "browser_read", "arguments": ["cursor": NSNull(), "view": "all"]]
            let changed: [String: Any] = ["tool": "browser_read", "arguments": ["cursor": "@cursor", "view": "content"]]
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/search"]],
                read, changed, read, changed, read, changed,
                ["tool": "browser_click", "arguments": ["click_ref": "@buttonClickRef"]],
            ])
            try await self.waitFor { harness.rowCount == 7 && harness.audit.status == .waiting }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, true, false, true, false])
            XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" })
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertEqual(counts.ownedClosed, 1)
            XCTAssertTrue(counts.humanIntact)
        }
    }

    func testVerifiedNewBindingSeparatesReadFailuresWithoutRefundingRecoveryReads() async throws {
        try await withHarness(approval: true) { harness in
            await harness.backend.enablePaginatedRead()
            let read: [String: Any] = ["tool": "browser_read", "arguments": ["view": "all"]]
            let changed: [String: Any] = ["tool": "browser_read", "arguments": ["cursor": "@cursor", "view": "content"]]
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/search"]],
                read, changed, read, changed,
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/document"]],
                read, changed,
                ["tool": "browser_read", "arguments": ["view": "content"]],
            ])
            try await self.waitFor { harness.rowCount == 9 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, true, false, true, true, false, true])
            for index in [2, 4, 7] {
                let items = try XCTUnwrap(rows[index]["contentItems"] as? [[String: Any]])
                let recovery = try XCTUnwrap(items.compactMap { item -> [String: Any]? in
                    guard let text = item["text"] as? String else { return nil }
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                }.first { $0["current_observation"] != nil })
                XCTAssertEqual(recovery["dispatched"] as? Bool, false)
                XCTAssertEqual((recovery["current_observation"] as? [String: Any])?["status"] as? String, "available")
            }
            XCTAssertFalse(harness.audit.entries.contains { $0.title == "Native action stopped" })
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_open"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.created, 2); XCTAssertEqual(counts.ownedClosed, 2)
            XCTAssertEqual(counts.mutations, 0); XCTAssertTrue(counts.humanIntact)
        }
    }

    func testSameBindingNavigationChangesReadFailureScopeOnlyAfterCommittedObservation() async throws {
        for mode in ["commit", "same_document", "cancelled_provisional", "fail"] {
            try await withHarness(approval: true) { harness in
                await harness.backend.enablePaginatedRead()
                await harness.backend.configureNavigation(mode)
                let read: [String: Any] = ["tool": "browser_read", "arguments": ["view": "all"]]
                let changed: [String: Any] = ["tool": "browser_read", "arguments": ["cursor": "@cursor", "view": "content"]]
                var calls: [[String: Any]] = [
                    ["tool": "browser_open", "arguments": ["url": "https://example.invalid/search"]],
                    read, changed, read, changed,
                    ["tool": "browser_navigate", "arguments": ["url": "https://example.invalid/document"]],
                    read, changed,
                ]
                calls.append(mode == "commit"
                    ? ["tool": "browser_read", "arguments": ["view": "content"]]
                    : ["tool": "browser_open", "arguments": ["url": "https://example.invalid/MUST_NOT_OPEN"]])
                try await harness.submit(calls)
                if mode == "commit" {
                    try await self.waitFor { harness.rowCount == 9 && harness.audit.status == .completed }
                    XCTAssertFalse(harness.audit.entries.contains { $0.title == "Native action stopped" })
                    let rows = try harness.rows()
                    XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, true, false, true, true, false, true])
                    XCTAssertTrue((rows[7]["text"] as? String)?.contains("\"status\":\"available\"") == true)
                } else {
                    try await self.waitFor { harness.rowCount == 8 && harness.audit.status == .waiting }
                    XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" }, mode)
                    let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
                    XCTAssertEqual(sent.count, 8, "Uncommitted navigation cannot refund the third repeated failure")
                }
                XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_navigate"])
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.created, 1); XCTAssertEqual(counts.fills, 0); XCTAssertEqual(counts.presses, 0)
                XCTAssertEqual(counts.navigations, mode == "fail" ? 0 : 1)
            }
        }
    }

    func testSameBindingReadsNoOpBindAndFailedReplacementCannotRefundReadFailures() async throws {
        for transition in ["fresh_read", "already_bound", "invalid_replacement"] {
            try await withHarness(approval: true) { harness in
                await harness.backend.enablePaginatedRead()
                let read: [String: Any] = ["tool": "browser_read", "arguments": ["view": "all"]]
                let changed: [String: Any] = ["tool": "browser_read", "arguments": ["cursor": "@cursor", "view": "content"]]
                var calls: [[String: Any]] = [
                    ["tool": "browser_tabs", "arguments": [:]],
                    ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                    read, changed, read, changed,
                ]
                if transition == "already_bound" { calls.append(["tool": "browser_bind", "arguments": ["tab_id": "@human"]]) }
                if transition == "invalid_replacement" { calls.append(["tool": "browser_open", "arguments": ["url": "file:///MUST_NOT_OPEN"]]) }
                calls += [read, changed]
                let stopCount = calls.count
                calls.append(["tool": "browser_open", "arguments": ["url": "https://example.invalid/MUST_NOT_OPEN"]])
                try await harness.submit(calls)
                try await self.waitFor { harness.rowCount == stopCount && harness.audit.status == .waiting }
                XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" }, transition)
                let rows = try harness.rows()
                var expected = [true, true, true, false, true, false]
                if transition == "already_bound" { expected.append(true) }
                if transition == "invalid_replacement" { expected.append(false) }
                expected += [true, false]
                XCTAssertEqual(rows.map { $0["success"] as? Bool }, expected.map(Optional.some))
                XCTAssertEqual(rows.last?["tool"] as? String, "browser_read")
                XCTAssertEqual(rows.last?["success"] as? Bool, false)
                let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
                XCTAssertEqual(sent.count, stopCount, "Same-target third failure stops before a later action")
                XCTAssertTrue(harness.audit.approvals.isEmpty, "Inventory-backed binding and reads are read-only; invalid URLs never reach approval")
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.created, 0); XCTAssertEqual(counts.mutations, 0); XCTAssertTrue(counts.humanIntact)
            }
        }
    }

    func testDeclinedReplacementCannotRefundReadFailures() async throws {
        for transitionTool in ["browser_open", "browser_navigate"] {
            try await withHarness { harness in
                await harness.backend.enablePaginatedRead()
                let read: [String: Any] = ["tool": "browser_read", "arguments": ["view": "all"]]
                let changed: [String: Any] = ["tool": "browser_read", "arguments": ["cursor": "@cursor", "view": "content"]]
                try await harness.submit([
                    ["tool": "browser_open", "arguments": ["url": "https://example.invalid/search"]],
                    read, changed, read, changed,
                    ["tool": transitionTool, "arguments": ["url": "https://example.invalid/DECLINED"]],
                    read, changed,
                    ["tool": "browser_open", "arguments": ["url": "https://example.invalid/MUST_NOT_OPEN"]],
                ])
                try await self.waitFor { harness.audit.approvals.count == 1 }
                try await harness.runtime.resolveApproval(requestID: harness.audit.approvals[0].id, approved: true)
                try await self.waitFor { harness.audit.approvals.count == 2 }
                try await harness.runtime.resolveApproval(requestID: harness.audit.approvals[1].id, approved: false)
                try await self.waitFor { harness.rowCount == 8 && harness.audit.status == .waiting }
                XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" })
                let rows = try harness.rows()
                XCTAssertTrue((rows[5]["text"] as? String)?.contains("declined") == true)
                XCTAssertEqual(rows.last?["tool"] as? String, "browser_read")
                XCTAssertEqual(rows.last?["success"] as? Bool, false)
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.created, 1); XCTAssertEqual(counts.mutations, 0)
                XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", transitionTool])
            }
        }
    }

    func testSuccessfulNewBindingCannotRefundInvalidReferenceFailures() async throws {
        try await withHarness(approval: true) { harness in
            let read: [String: Any] = ["tool": "browser_read", "arguments": ["view": "all"]]
            let mismatch: [String: Any] = ["tool": "browser_click", "arguments": [
                "click_ref": "bclick_00000000-0000-4000-8000-000000000000",
            ]]
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/search"]],
                read, mismatch, mismatch,
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/document"]],
                read, mismatch,
                ["tool": "browser_click", "arguments": ["click_ref": "@buttonClickRef"]],
            ])
            try await self.waitFor { harness.rowCount == 7 && harness.audit.status == .waiting }
            XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" })
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_open"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.created, 2); XCTAssertEqual(counts.mutations, 0)
        }
    }

    func testSuccessfulCorrectedInputClearsOnlyPriorReferenceRoutingFailures() async throws {
        try await withHarness(approval: true) { harness in
            var calls: [[String: Any]] = [
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
            ]
            for index in 1...4 {
                calls.append(["tool": "browser_fill", "arguments": [
                    "fill_ref": "bfill_00000000-0000-4000-8000-00000000000\(index)",
                    "text": "MUST_NOT_FILL_\(index)",
                ]])
                calls.append(["tool": "browser_fill", "arguments": [
                    "fill_ref": "@fieldFillRef", "text": "UA \(120 + index)",
                ]])
            }
            try await harness.submit(calls)
            try await self.waitFor { harness.rowCount == 10 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool },
                           [true, true, false, true, false, true, false, true, false, true])
            XCTAssertFalse(harness.audit.entries.contains { $0.title == "Native action stopped" },
                           "Successful corrections must prevent unrelated routing errors accumulating into a false stop")
            XCTAssertEqual(harness.audit.approvals.map(\.summary),
                           ["browser_open", "browser_fill", "browser_fill", "browser_fill", "browser_fill"])
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.fills, 4); XCTAssertEqual(counts.presses, 0)
            XCTAssertTrue((rows.last?["text"] as? String)?.contains("UA 124") == true)
            XCTAssertFalse((rows.last?["text"] as? String)?.contains("MUST_NOT_FILL") == true)
        }
    }

    func testChangingUnknownReferencesAndFillTextCannotRefundRoutingFailures() async throws {
        try await withHarness(approval: true) { harness in
            let invalid = (1...3).map { index -> [String: Any] in
                ["tool": "browser_fill", "arguments": [
                    "fill_ref": "bfill_00000000-0000-4000-8000-00000000000\(index)",
                    "text": "MUST_NOT_FILL_\(index)",
                ]]
            }
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
            ] + invalid + [
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "MUST_NOT_FILL_AFTER_STOP"]],
            ])
            try await self.waitFor { harness.rowCount == 5 && harness.audit.status == .waiting }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, false, false])
            XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" })
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open"])
            let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
            XCTAssertEqual(requests.count, 5)
            XCTAssertEqual(Set(requests.compactMap { $0["reference"] as? String }).count, 3)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.mutations, 0)
        }
    }

    func testNewReferencesForTheSameTargetCannotRefundFailedInputAttempts() async throws {
        try await withHarness(approval: true) { harness in
            await harness.backend.failPresses(3)
            let read: [String: Any] = ["tool": "browser_read", "arguments": ["view": "all"]]
            let press: [String: Any] = ["tool": "browser_click", "arguments": ["click_ref": "@buttonClickRef"]]
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                read, press, read, press, read, press,
                read, press,
            ])
            try await self.waitFor { harness.rowCount == 7 && harness.audit.status == .waiting }
            let rows = try harness.rows()
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, false, true, false, true, false])
            XCTAssertTrue(harness.audit.entries.contains { $0.title == "Native action stopped" })
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_click", "browser_click", "browser_click"])
            let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
            XCTAssertEqual(requests.count, 7, "The third unchanged target failure must stop before another read/input")
            XCTAssertEqual(Set(requests.compactMap { $0["reference"] as? String }).count, 3,
                           "Each admitted input consumes its reference; newly issued tokens must retain the same failure intent")
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.mutations, 0, "The backend failed before committing any input")
        }
    }

    func testStopAndShutdownCloseOnlyTaskCreatedPages() async throws {
        for stop in [false, true] {
            try await withHarness(approval: true) { harness in
                try await harness.submit([["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]]], hold: true)
                try await self.waitFor { harness.rowCount == 1 }
                let opened = await harness.backend.counts()
                XCTAssertEqual(opened.created, 1)
                if stop { try await harness.runtime.interrupt(taskID: Harness.taskID) }
                else {
                    let shutdown = await harness.runtime.shutdown()
                    XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
                }
                try await self.waitForAsync { await harness.backend.counts().ownedClosed == 1 }
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.humanCloseAttempts, 0)
                XCTAssertTrue(counts.humanIntact)
                XCTAssertEqual(counts.activations, 0)
            }
        }
    }

    func testRetiredTurnDoesNotPublishLateDispatchCueOrObservation() async throws {
        try await withHarness(approval: true, allowsCleanupFailure: true) { harness in
            await harness.backend.holdNextPostInputObservation()
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_fill", "arguments": ["fill_ref": "@fieldFillRef", "text": "UA 123"]],
            ], hold: true)
            try await self.waitForAsync { await harness.backend.isPostInputObservationHeld() }
            XCTAssertEqual(harness.rowCount, 2, "The fill result remains unpublished while its fresh read is pending")
            let dispatched = await harness.backend.counts()
            XCTAssertEqual(dispatched.fills, 1)
            let stopping = Task { try await harness.runtime.interrupt(taskID: Harness.taskID) }
            try await self.waitForAsync { await harness.backend.counts().ownedClosed == 1 }
            await harness.backend.resumePostInputObservation()
            try await stopping.value
            // interrupt awaits the cancelled dynamic tool task, making this
            // assertion an ordering barrier after the late controller result.
            let rows = try harness.rows()
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, ["browser_open", "browser_read"])
            XCTAssertFalse(rows.contains { $0["tool"] as? String == "browser_fill" })
            let trace = try AppServerWireTrace.load(harness.root.appendingPathComponent("protocol.jsonl"))
            XCTAssertTrue(trace.parseFailures.isEmpty)
            XCTAssertFalse(trace.messages.contains {
                $0.direction == .clientToServer && $0.identifier == "string:request-1-2" && $0.object["result"] != nil
            }, "Neither the dispatch cue nor the full observation may publish to a retired turn")
            let finalCounts = await harness.backend.counts()
            XCTAssertEqual(finalCounts.fills, 1)
            XCTAssertEqual(finalCounts.ownedClosed, 1)
            XCTAssertTrue(finalCounts.humanIntact)
        }
    }

    func testFailedBrokerDispatchPublishesOnlyFailureWithoutCompactCue() async throws {
        try await withHarness(approval: true) { harness in
            await harness.backend.failNextPress()
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_click", "arguments": ["click_ref": "@buttonClickRef"]],
            ])
            try await self.waitFor { harness.rowCount == 3 && harness.audit.status == .completed }
            let last = try XCTUnwrap(harness.rows().last)
            XCTAssertEqual(last["success"] as? Bool, false)
            let items = try XCTUnwrap(last["contentItems"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            let error = try XCTUnwrap(items.first?["text"] as? String)
            XCTAssertTrue(error.contains("Synthetic press failed"))
            XCTAssertFalse(error.contains("\"dispatched\":true"))
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_click"])
        }
    }

    /// One admitted native press whose observed selection deliberately never
    /// changes. It exercises real dispatch/verification accounting, without AX
    /// access to a system app or a fabricated ledger insertion.
    private final class PendingNativeSelectionBackend: NativeBackgroundAccessibilityBackend {
        private let windowIdentity = UUID(), rowIdentity = UUID()
        private var capabilityValid = false
        private(set) var actions = 0, postInputReads = 0

        func isStillSelected() throws -> Bool { true }
        func snapshot(limits: AccessibilityTreeLimits) throws -> AccessibilityTreeSnapshot {
            if actions > 0 { postInputReads += 1 }
            capabilityValid = true
            let window = AccessibilityTreeElement(index: 0, parentIndex: nil, childIndices: [1], depth: 0,
                role: "AXWindow", subrole: nil, title: "Pending fixture", elementDescription: nil, help: nil,
                identifier: nil, domIdentifier: nil, value: nil, frame: nil, isEnabled: true, isFocused: false,
                supportedActions: [], isValueSettable: false, evidenceIdentity: windowIdentity)
            let row = AccessibilityTreeElement(index: 1, parentIndex: 0, childIndices: [], depth: 1,
                role: "AXRow", subrole: nil, title: "Pending native selection", elementDescription: nil, help: nil,
                identifier: nil, domIdentifier: nil, value: nil, frame: nil, isEnabled: true, isFocused: false,
                supportedActions: ["AXPress"], isValueSettable: false, isSelected: false, evidenceIdentity: rowIdentity)
            return AccessibilityTreeSnapshot(id: UUID(), application: .init(processIdentifier: 123,
                bundleIdentifier: "com.example.pending-native-selection", applicationName: "Pending fixture"),
                limits: limits, rootIndex: 0, elements: [window, row], wasTruncated: false)
        }
        func semanticRead(_ request: SemanticReadRequest, outputCharacterLimit: Int) throws -> AccessibilitySemanticReadResult {
            let captured = try snapshot(limits: .agentDefault)
            let observation = AccessibilitySnapshotTextFormatter(outputCharacterLimit: outputCharacterLimit,
                usesCompactElementLines: true, allowsRaise: false).formatObservation(captured)
            return AccessibilitySemanticReadResult(snapshot: captured, observation: observation)
        }
        func invalidateObservation() { capabilityValid = false }
        func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot,
                     beforeDispatch: () throws -> Void) throws {
            guard capabilityValid, action == .press, snapshot.element(at: index)?.evidenceIdentity == rowIdentity else {
                throw NativeBackgroundAccessibility.Failure.staleObservation
            }
            try beforeDispatch()
            actions += 1
        }
        func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot,
                      beforeDispatch: () throws -> Void) throws {
            throw NativeBackgroundAccessibility.Failure.staleObservation
        }
    }

    private actor LegacyPIDFixture {
        static let processID: Int32 = 42_424
        enum Replacement: Equatable, Sendable { case chrome, sameBundleNewLaunch, unavailable }
        struct Counts: Sendable { let lookups: Int; let reads: Int }
        private let identity: NativeToolProcessIdentity
        private let replacement: Replacement?
        private let replaceAfterRead: Bool
        private var lookups = 0, reads = 0

        init(bundleID: String, replacement: Replacement?, replaceAfterRead: Bool = false) {
            identity = NativeToolProcessIdentity(processIdentifier: Self.processID, bundleIdentifier: bundleID,
                launchDate: Date(timeIntervalSince1970: 1_700_000_000))
            self.replacement = replacement
            self.replaceAfterRead = replaceAfterRead
        }
        func resolve(_ processID: Int32) -> NativeToolProcessIdentity? {
            lookups += 1
            guard processID == Self.processID else { return nil }
            guard let replacement, (replaceAfterRead ? reads > 0 : lookups > 1) else { return identity }
            switch replacement {
            case .unavailable: return nil
            case .chrome, .sameBundleNewLaunch:
                return NativeToolProcessIdentity(processIdentifier: processID,
                    bundleIdentifier: replacement == .chrome ? "com.google.Chrome" : identity.bundleIdentifier,
                    launchDate: identity.launchDate.addingTimeInterval(1))
            }
        }
        func read(_ admitted: NativeToolProcessIdentity) throws -> String {
            guard admitted == identity else { throw NativeBackgroundAccessibility.Failure.targetChanged }
            reads += 1
            return "OWNED_NATIVE_PID_OBSERVATION"
        }
        func counts() -> Counts { Counts(lookups: lookups, reads: reads) }
    }

    @MainActor
    private final class Audit {
        var status: TaskStatus?
        var approvals = [ActionApprovalRequest]()
        var entries = [TimelineEntry]()
    }

    @MainActor
    private final class Harness {
        static let taskID = "embedded-browser-task"
        static let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let root: URL
        let runtime: CodexAppServerRuntime
        let backend = InertRuntimeBrowser()
        let audit = Audit()
        var events: Task<Void, Never>?

        init(configured: Bool, approval: Bool?, legacyPIDFixture: LegacyPIDFixture?) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaBrowserRuntime-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fixture = root.appendingPathComponent("fixture.ts")
            try Data(RuntimeEmbeddedBrowserToolsTests.fixture.utf8).write(to: fixture)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            var configuration = CodexAppServerRuntime.Configuration.localQwen
            configuration.executable = .fixture(path: fixture.path)
            configuration.codexHomePath = root.path
            configuration.workspacePath = root.path
            configuration.model = Self.modelID
            configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
            if let legacyPIDFixture {
                configuration.fixtureNativeProcessIdentity = { await legacyPIDFixture.resolve($0) }
                configuration.fixtureLegacyNativeSnapshot = { try await legacyPIDFixture.read($0) }
            }
            runtime = CodexAppServerRuntime(configuration: configuration)
            if configured { await runtime.configureEmbeddedBrowserTools(EmbeddedBrowserToolController(transport: backend)) }
            events = Task { @MainActor [runtime, audit] in
                for await event in runtime.events() {
                    switch event {
                    case .taskStatusChanged(let id, let status) where id == Self.taskID: audit.status = status
                    case .timelineEntryAppended(let id, let entry) where id == Self.taskID: audit.entries.append(entry)
                    case .approvalRequested(let request):
                        audit.approvals.append(request)
                        if let approval { try? await runtime.resolveApproval(requestID: request.id, approved: approval) }
                    default: break
                    }
                }
            }
            _ = try await runtime.loadTasks()
        }

        func submit(_ calls: [[String: Any]], hold: Bool = false, interruptProbe: Bool = false,
                    pauseForNativeBinding: Bool = false) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["calls": calls, "hold": hold,
                "interruptProbe": interruptProbe, "pauseForNativeBinding": pauseForNativeBinding], options: [.sortedKeys])
            try await runtime.submit(prompt: String(decoding: data, as: UTF8.self), toTaskID: Self.taskID, modelID: Self.modelID)
        }
        func rows() throws -> [[String: Any]] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results.json"))) as? [[String: Any]])
        }
        var rowCount: Int {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("results.json")),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let rows = object as? [[String: Any]] else { return 0 }
            return rows.count
        }
        func offeredNames() throws -> Set<String> {
            let specs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("specs.json"))) as? [[String: Any]])
            try CanonicalDynamicToolTestContract.validate(specs)
            return Set(specs.compactMap { $0["name"] as? String })
        }
        func cleanupReceipts() throws -> [EmbeddedBrowserCleanupReceipt] {
            let directory = root.appendingPathComponent("EmbeddedBrowserCleanup-v1", isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(EmbeddedBrowserCleanupReceipt.self, from: Data(contentsOf: $0)) }
        }
    }

    private func withHarness(configured: Bool = true, approval: Bool? = nil,
                             legacyPIDFixture: LegacyPIDFixture? = nil,
                             allowsCleanupFailure: Bool = false,
                             _ body: @MainActor (Harness) async throws -> Void) async throws {
        let harness = try await Harness(configured: configured, approval: approval,
            legacyPIDFixture: legacyPIDFixture)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        do {
            try await body(harness)
            let report = await harness.runtime.shutdown()
            harness.events?.cancel()
            if allowsCleanupFailure { XCTAssertFalse(report.succeeded) }
            else { XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; ")) }
        } catch {
            _ = await harness.runtime.shutdown()
            harness.events?.cancel()
            throw error
        }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        try await waitForAsync { predicate() }
    }
    private func waitForAsync(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "RuntimeEmbeddedBrowserToolsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for owned fixture evidence"])
    }

    nonisolated private static let fixture = #"""
    #!/usr/bin/env bun
    import { existsSync, writeFileSync } from 'node:fs';
    import { join } from 'node:path';
    import { createInterface } from 'node:readline';
    const root = process.env.CODEX_HOME;
    const threadId = 'embedded-browser-thread';
    const send = value => process.stdout.write(JSON.stringify(value) + '\n');
    const result = (id, value = {}) => send({id, result:value});
    const notify = (method, params) => send({method, params:{threadId, ...params}});
    const save = (name, value) => writeFileSync(join(root, name), JSON.stringify(value));
    const plainObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
    function canonicalToolError(specs) {
      if (!Array.isArray(specs) || specs.length === 0) return 'Invalid request: missing dynamic tools';
      const legacy = specs.some(spec => !plainObject(spec) || !Object.hasOwn(spec, 'type') || Object.hasOwn(spec, 'namespace') || Object.hasOwn(spec, 'exposeToContext'));
      const canonical = specs.some(spec => plainObject(spec) && Object.hasOwn(spec, 'type'));
      if (legacy && canonical) return 'Invalid request: dynamic tools must use either canonical or legacy format consistently';
      if (legacy) return 'Invalid request: this fixture requires canonical dynamic function tools';
      const names = new Set();
      const allowed = new Set(['type', 'name', 'description', 'inputSchema', 'deferLoading']);
      for (const spec of specs) {
        const schema = spec.inputSchema;
        if (spec.type !== 'function' || typeof spec.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(spec.name) || names.has(spec.name)
            || typeof spec.description !== 'string' || !spec.description.trim() || Object.keys(spec).some(key => !allowed.has(key))
            || (Object.hasOwn(spec, 'deferLoading') && typeof spec.deferLoading !== 'boolean')
            || !plainObject(schema) || schema.type !== 'object' || !plainObject(schema.properties) || schema.additionalProperties !== false
            || !Array.isArray(schema.required) || new Set(schema.required).size !== schema.required.length
            || schema.required.some(key => typeof key !== 'string' || !Object.hasOwn(schema.properties, key))) {
          return 'Invalid request: invalid canonical dynamic function tool definition';
        }
        names.add(spec.name);
      }
      return null;
    }
    const rows = [], refs = {}, requests = [];
    let turnCount = 0, turnId = '', step = 0, plan = {}, finished = true, interruptRequest;
    function complete(status = 'completed') {
      if (finished) return;
      finished = true;
      if (status === 'completed') {
        const item = {id:`answer-${turnCount}`, type:'agentMessage', phase:'final_answer', text:'Fixture workflow finished.'};
        notify('item/started', {turnId, item:{...item, text:''}});
        notify('item/agentMessage/delta', {turnId, itemId:item.id, delta:item.text});
        notify('item/completed', {turnId, item});
      }
      notify('turn/completed', {turn:{id:turnId, status, items:[], error:null}});
    }
    function next() {
      if (finished) return;
      if (step >= plan.calls.length) { if (!plan.hold) complete(); return; }
      const call = plan.calls[step], args = {};
      for (const [key,value] of Object.entries(call.arguments ?? {})) args[key] = typeof value === 'string' && value.startsWith('@') ? refs[value.slice(1)] : value;
      const params = {threadId:call.foreignThread ? 'foreign-thread' : threadId, turnId, callId:`call-${turnCount}-${step}`, tool:call.tool, arguments:args};
      if (call.turn === 'wrong') params.turnId = 'wrong-turn';
      if (call.turn === 'previous') params.turnId = `embedded-turn-${turnCount-1}`;
      if (call.turn === 'missing') delete params.turnId;
      requests.push({turnId, step, tool:call.tool, reference:args.click_ref ?? args.fill_ref}); save('requests.json', requests);
      send({id:`request-${turnCount}-${step}`, method:'item/tool/call', params});
    }
    function received(message) {
      if (message.id === 'stop-window-probe') {
        const text = (message.result?.contentItems ?? []).map(item => item.text ?? '').join('\n');
        save('stop-window-result.json', {success:message.result?.success === true, text, error:message.error?.message ?? null});
        result(interruptRequest); complete('interrupted'); return;
      }
      if (message.id !== `request-${turnCount}-${step}`) return;
      const text = (message.result?.contentItems ?? []).map(item => item.text ?? '').join('\n');
      rows.push({turnId, tool:plan.calls[step].tool, success:message.result?.success === true, contentItems:message.result?.contentItems ?? [], text, error:message.error?.message ?? null});
      save('results.json', rows);
      let observationText = message.result?.success ? text : null;
      if (!message.result?.success && plan.calls[step].captureRecovery) {
        for (const item of message.result?.contentItems ?? []) {
          try {
            const recovery = JSON.parse(item.text);
            if (recovery.success === false && recovery.dispatched === false && recovery.error?.code === 'stale_snapshot'
                && recovery.current_observation?.status === 'available') observationText = recovery.current_observation.text;
          } catch {}
        }
      }
      if (observationText) {
        for (const item of message.result?.contentItems ?? []) {
          try {
            const data = JSON.parse(item.text);
            if (data.tabs?.[0]?.tab_id) refs.human = data.tabs[0].tab_id;
            if (data.current_observation?.status === 'available') observationText = data.current_observation.text;
          } catch {}
        }
        const snapshot = observationText.match(/AXSNAPSHOT id=([A-Fa-f0-9-]{36})/);
        const readLine = observationText.split('\n').find(line => line.startsWith('READ '));
        const cursor = readLine?.match(/(?:^| )next_cursor=([A-Fa-f0-9-]{36})(?: |$)/);
        if (cursor) refs.cursor = cursor[1]; else delete refs.cursor;
        if (snapshot) {
          refs.snapshot = snapshot[1];
          if (plan.calls[step].saveSnapshot) refs[plan.calls[step].saveSnapshot] = snapshot[1];
          const field = observationText.split('\n').find(line => line.startsWith('#') && line.includes('label="Search flights"'));
          const button = observationText.split('\n').find(line => line.startsWith('#') && line.includes('label="Find flight"'));
          const heading = observationText.split('\n').find(line => line.startsWith('#') && line.includes('label="United flight fixture"'));
          const nativeRow = observationText.split('\n').find(line => line.startsWith('#') && line.includes('label="Pending native selection"'));
          // Copy action references only from the exact row returned by the runtime.
          // Retain row fields solely for the legacy-input rejection test.
          for (const [key, row] of Object.entries({field, button, heading})) {
            if (!row) continue;
            refs[key] = Number(row.match(/^#(\d+)/)[1]);
            refs[`${key}Role`] = JSON.parse(row.match(/role=("[^"]*")/)[1]);
            refs[`${key}Label`] = JSON.parse(row.match(/label=("[^"]*")/)[1]);
            for (const [field, suffix] of [['click_ref','ClickRef'], ['fill_ref','FillRef']]) {
              const match = row.match(new RegExp(`(?:^| )${field}="([A-Za-z0-9_-]+)"`));
              if (match) refs[`${key}${suffix}`] = match[1];
              else delete refs[`${key}${suffix}`];
            }
            if (key === 'field' && plan.calls[step].saveFillRef) {
              if (!refs.fieldFillRef) throw new Error('Fixture cannot save an unexposed fill reference');
              refs[plan.calls[step].saveFillRef] = refs.fieldFillRef;
            }
          }
          if (nativeRow) refs.nativeRow = Number(nativeRow.match(/^#(\d+)/)[1]);
        }
      }
      step++; setTimeout(next, 0);
    }
    createInterface({input:process.stdin}).on('line', line => {
      const message = JSON.parse(line);
      if (!Object.hasOwn(message, 'id')) return;
      if (!message.method) { received(message); return; }
      switch (message.method) {
        case 'initialize': result(message.id, {userAgent:'embedded-browser-runtime-fixture'}); break;
        case 'thread/list': result(message.id, {data:[], nextCursor:null}); break;
        case 'thread/start': {
          save('specs.json', message.params.dynamicTools);
          const error = canonicalToolError(message.params.dynamicTools);
          if (error) send({id:message.id, error:{code:-32600, message:error}});
          else result(message.id, {thread:{id:threadId, turns:[]}});
          break;
        }
        case 'thread/resume': result(message.id, {thread:{id:threadId, turns:[], status:{type:'idle'}}, initialTurnsPage:{data:[], nextCursor:null, hasMore:false}, model:'lmstudio-community/Qwen3.5-4B-MLX-4bit'}); break;
        case 'thread/name/set': case 'thread/inject_items': result(message.id); break;
        case 'turn/start':
          turnCount++; turnId = `embedded-turn-${turnCount}`; step = 0; finished = false;
          plan = JSON.parse(message.params.input[0].text);
          save('turn-input.json', message.params.input);
          result(message.id, {turn:{id:turnId, status:'inProgress', items:[]}});
          notify('turn/started', {turn:{id:turnId, status:'inProgress', items:[]}});
          if (plan.pauseForNativeBinding) {
            save('native-binding-ready', true);
            const admission = setInterval(() => {
              if (existsSync(join(root, 'native-binding-continue'))) { clearInterval(admission); next(); }
            }, 10);
          } else setTimeout(next, 10);
          break;
        case 'turn/interrupt':
          if (plan.interruptProbe) {
            interruptRequest = message.id;
            // Keep the original turn active on the wire until this correctly
            // tagged late call receives the host's refusal. Stop has already
            // retired its epoch, key and pending approvals before this RPC.
            send({id:'stop-window-probe', method:'item/tool/call', params:{threadId, turnId, callId:'stop-window-call', tool:'browser_open', arguments:{url:'https://example.invalid/MUST_NOT_OPEN'}}});
          } else { result(message.id); complete('interrupted'); }
          break;
        default: send({id:message.id, error:{code:-32601, message:`Unexpected embedded fixture method: ${message.method}`}});
      }
    }).on('close', () => process.exit(0));
    """#
}

/// Inspects the complete thread/start payload, including native and browser
/// tools together. Real-engine tests also require the pinned parser to accept it.
enum CanonicalDynamicToolTestContract {
    static func validate(_ specs: [[String: Any]]) throws {
        guard !specs.isEmpty else { throw invalid("No dynamic tools were offered") }
        let allowed: Set<String> = ["type", "name", "description", "inputSchema", "deferLoading"]
        var names = Set<String>()
        for (index, spec) in specs.enumerated() {
            guard spec["type"] as? String == "function",
                  Set(spec.keys).isSubset(of: allowed),
                  let name = spec["name"] as? String,
                  name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  names.insert(name).inserted,
                  let description = spec["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let schema = spec["inputSchema"] as? [String: Any],
                  schema["type"] as? String == "object",
                  schema["additionalProperties"] as? Bool == false,
                  let properties = schema["properties"] as? [String: Any],
                  let required = schema["required"] as? [String],
                  Set(required).count == required.count,
                  Set(required).isSubset(of: Set(properties.keys)),
                  spec["deferLoading"] == nil || spec["deferLoading"] is Bool
            else { throw invalid("Offered tool \(index) is not a canonical dynamic function definition") }
        }
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "CanonicalDynamicToolTestContract", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Shared only with native-engine contract tests; never a production backend.
actor InertRuntimeBrowser: EmbeddedBrowserControlBackend {
    static let humanID = "11111111-1111-4111-8111-111111111111"
    struct Counts: Sendable {
        var inventories = 0, created = 0, ownedClosed = 0, humanCloseAttempts = 0, activations = 0
        var fills = 0, presses = 0, navigations = 0
        var humanIntact = true
        var mutations: Int { fills + presses + navigations }
    }
    private var ledger = Counts()
    private var targets: [String: BrowserTarget] = [humanID: BrowserTarget(targetID: humanID, instanceToken: "human-incarnation", title: "User flight page", url: URL(string: "https://example.invalid/user")!)]
    private var owned = Set<String>()
    private var values = [String: String]()
    private var results = [String: String]()
    private var holdClose = false
    private var closeHeld = false
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var failClose = false
    private var failPress = false
    private var remainingPressFailures = 0
    private var paginatedRead = false
    private var committedDocuments: [String: UUID] = [humanID: UUID()]
    private var loaderGenerations = [String: UUID]()
    private var navigationMode = "commit"
    private var holdPostInputObservation = false
    private var postInputObservationHeld = false
    private var postInputObservationWaiter: CheckedContinuation<Void, Never>?

    func holdNextClose() { holdClose = true }
    func failNextClose() { failClose = true }
    func failNextPress() { failPress = true }
    func failPresses(_ count: Int) { remainingPressFailures = count }
    func enablePaginatedRead() { paginatedRead = true }
    func configureNavigation(_ mode: String) { navigationMode = mode }
    func isCloseHeld() -> Bool { closeHeld }
    func resumeClose() { closeWaiter?.resume(); closeWaiter = nil }
    func holdNextPostInputObservation() { holdPostInputObservation = true }
    func isPostInputObservationHeld() -> Bool { postInputObservationHeld }
    func resumePostInputObservation() { postInputObservationWaiter?.resume(); postInputObservationWaiter = nil }

    func counts() -> Counts {
        var result = ledger
        result.humanIntact = targets[Self.humanID]?.url.absoluteString == "https://example.invalid/user"
            && values[Self.humanID] == nil && results[Self.humanID] == nil
        return result
    }
    func humanTargets() -> [BrowserTarget] { ledger.inventories += 1; return Array(targets.values).sorted { $0.targetID < $1.targetID } }
    func createTarget(url: URL) -> BrowserTarget {
        ledger.created += 1
        let id = UUID().uuidString
        let target = BrowserTarget(targetID: id, instanceToken: UUID().uuidString, title: "Fixture flight", url: url)
        targets[id] = target; owned.insert(id); committedDocuments[id] = UUID(); return target
    }
    func target(id: String) -> BrowserTarget? { targets[id] }
    func activateTarget(id: String) { ledger.activations += 1 }
    func closeTarget(target: BrowserTarget) async throws {
        if holdClose {
            holdClose = false; closeHeld = true
            await withCheckedContinuation { closeWaiter = $0 }
            closeHeld = false
        }
        if failClose {
            failClose = false
            throw BrowserTabBrokerError.browserUnavailable("Synthetic close failed")
        }
        guard owned.remove(target.targetID) != nil else { ledger.humanCloseAttempts += 1; throw BrowserTabBrokerError.ownershipMismatch }
        ledger.ownedClosed += 1; targets.removeValue(forKey: target.targetID)
    }
    func closeOwnedTargets() -> [String] {
        for id in owned { targets.removeValue(forKey: id); ledger.ownedClosed += 1 }
        owned.removeAll(); return []
    }
    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        guard targets[target.targetID] == target else { throw BrowserTabBrokerError.targetClosed }
        if holdPostInputObservation, ledger.fills + ledger.presses > 0 {
            holdPostInputObservation = false
            postInputObservationHeld = true
            await withCheckedContinuation { postInputObservationWaiter = $0 }
            postInputObservationHeld = false
        }
        var nodes = [
            BrowserDocumentNode(backendNodeID: 1, role: "main", name: "Flight lookup", value: nil, isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "main", childNodeIDs: ["heading", "query", "find", "result"]),
            BrowserDocumentNode(backendNodeID: 2, role: "heading", name: "United flight fixture", value: nil, isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "heading", parentNodeID: "main"),
            BrowserDocumentNode(backendNodeID: 3, role: "textbox", name: "Search flights", value: values[target.targetID] ?? "", isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "query", parentNodeID: "main", isEditable: true),
            BrowserDocumentNode(backendNodeID: 4, role: "button", name: "Find flight", value: nil, isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "find", parentNodeID: "main", isDOMClickable: true),
            BrowserDocumentNode(backendNodeID: 5, role: "StaticText", name: results[target.targetID] ?? "Enter a flight number", value: nil, isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "result", parentNodeID: "main"),
        ]
        if paginatedRead {
            for index in 0..<40 {
                nodes.append(BrowserDocumentNode(backendNodeID: Int64(6 + index), role: "StaticText",
                    name: "Document paragraph \(index)", value: nil, isDisabled: false, isReadOnly: true,
                    isIgnored: false, nodeID: "paragraph-\(index)", parentNodeID: "main"))
            }
        }
        var document = BrowserDocumentObservation(loaderID: loaderGenerations[target.targetID]?.uuidString ?? "loader-" + target.instanceToken, title: target.title, url: target.url, nodes: nodes)
        document.committedDocumentID = committedDocuments[target.targetID]
        document.sourceName = "computa_webkit_dom"
        return document
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation, permit: BrowserMutationPermit) throws {
        guard backendNodeID == 4 else { throw BrowserTabBrokerError.elementNotFound }
        if failPress || remainingPressFailures > 0 {
            failPress = false
            remainingPressFailures = max(0, remainingPressFailures - 1)
            throw BrowserTabBrokerError.browserUnavailable("Synthetic press failed")
        }
        try permit.commit { ledger.presses += 1; results[target.targetID] = "UA 123 departs at 14:35" }
    }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation, permit: BrowserMutationPermit) throws {
        guard backendNodeID == 3 else { throw BrowserTabBrokerError.elementNotFound }
        try permit.commit { ledger.fills += 1; values[target.targetID] = text }
    }
    func navigate(target: BrowserTarget, url: URL, permit: BrowserMutationPermit) throws {
        if navigationMode == "fail" { throw BrowserTabBrokerError.browserUnavailable("Synthetic navigation failed before dispatch") }
        try permit.commit {
            ledger.navigations += 1
            if navigationMode != "same_document" { loaderGenerations[target.targetID] = UUID() }
            if navigationMode == "commit" { committedDocuments[target.targetID] = UUID() }
            // A cancelled provisional navigation advances native generation,
            // but neither the committed document nor its URL has changed.
            if navigationMode != "cancelled_provisional" {
                targets[target.targetID] = BrowserTarget(targetID: target.targetID, instanceToken: target.instanceToken, title: target.title, url: url)
            }
        }
    }
    func wait(target: BrowserTarget, text: String?, timeoutMS: Int) -> Bool { text.map { (results[target.targetID] ?? "").contains($0) } ?? true }
}
