import Foundation
import XCTest
@testable import Computa

final class ClaudeRemountHostDiagnosticTests: XCTestCase {
    private let session = UUID(), tab = UUID(), generation = UUID()
    private let snapshot = "phases=model_proof active=false attached=true hidden=false window=true visible=true occluded=false width=1024 height=768 visibleWidth=900 visibleHeight=600 hostWidth=900 hostHeight=600"

    private func observation(action: String = "inspect", stage: String = "trigger_remount_timeout") -> [String: Any] {
        ["error": "model_unverified", "modelDiagnostic": ["kind": "model_picker_structure", "provider": "claude",
            "readStage": stage, "readContext": ["scope": "action_precheck", "action": action],
            "privatePageLabel": "PRIVATE_PAGE_CANARY"]]
    }

    private func record(_ observation: [String: Any]? = nil, action: String = "inspect", sequence: Int = 1,
                        sessionID: String? = nil, snapshot: (() throws -> String)? = nil) -> String? {
        ClaudeRemountHostDiagnostic.record(observation: observation ?? self.observation(action: action),
            action: action, sequence: sequence, sessionID: sessionID ?? session.uuidString,
            tabID: tab, generation: generation, snapshot: snapshot ?? { self.snapshot })
    }

    func testCorrelatesNativeIdentityAndProjectsOnlyFiniteHostFields() throws {
        let text = try XCTUnwrap(record(snapshot: { self.snapshot + " pageURL=https://private.invalid label=PRIVATE_NATIVE_CANARY" }))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["kind", "provider", "sessionID", "tabID", "generation", "action", "sequence", "stage", "host"])
        XCTAssertEqual(value["kind"] as? String, "claude_remount_host_v1")
        XCTAssertEqual(value["provider"] as? String, "claude")
        XCTAssertEqual(value["sessionID"] as? String, session.uuidString.lowercased())
        XCTAssertEqual(value["tabID"] as? String, tab.uuidString.lowercased())
        XCTAssertEqual(value["generation"] as? String, generation.uuidString.lowercased())
        XCTAssertEqual(value["action"] as? String, "inspect")
        XCTAssertEqual(value["sequence"] as? Int, 1)
        XCTAssertEqual(value["stage"] as? String, "trigger_remount_timeout")
        let host = try XCTUnwrap(value["host"] as? [String: Any])
        XCTAssertEqual(host as NSDictionary, ["attached": true, "hidden": false, "window": true,
            "visible": true, "occluded": false, "width": 1024, "height": 768, "visibleWidth": 900,
            "visibleHeight": 600, "hostWidth": 900, "hostHeight": 600] as NSDictionary)
        XCTAssertLessThanOrEqual(text.utf8.count, 1_024)
        for forbidden in ["PRIVATE_PAGE_CANARY", "PRIVATE_NATIVE_CANARY", "https://", "phases", "active"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testUnsupportedFailureOrContextNeverSamplesNativeHost() {
        var cases: [[String: Any]] = [["error": "model_unverified"], ["error": "conversation_changed"]]
        for (key, value) in [("kind", "other"), ("provider", "chatgpt"), ("readStage", "proof_observed")] {
            var item = observation(), diagnostic = item["modelDiagnostic"] as! [String: Any]
            diagnostic[key] = value; item["modelDiagnostic"] = diagnostic; cases.append(item)
        }
        for context in [["scope": "action_final_guard", "action": "inspect"],
                        ["scope": "action_precheck", "action": "verifyModel"]] {
            var item = observation(), diagnostic = item["modelDiagnostic"] as! [String: Any]
            diagnostic["readContext"] = context; item["modelDiagnostic"] = diagnostic; cases.append(item)
        }
        for item in cases {
            var sampled = false
            XCTAssertNil(record(item, snapshot: { sampled = true; return self.snapshot }))
            XCTAssertFalse(sampled)
        }
        for action in ["submit", "prepare", "stop", "cleanup", "PRIVATE_ACTION_CANARY"] {
            var sampled = false
            XCTAssertNil(record(action: action, snapshot: { sampled = true; return self.snapshot }))
            XCTAssertFalse(sampled)
        }
    }

    func testRejectsMalformedOrIncompleteNativeSnapshotWithoutPublishingPartialFacts() {
        let invalid = ["state=closed", snapshot + " width=1024", snapshot.replacingOccurrences(of: "hidden=false", with: "hidden=0"),
            snapshot.replacingOccurrences(of: "height=768", with: "height=PRIVATE_NATIVE_CANARY"),
            snapshot.replacingOccurrences(of: "width=1024", with: "width=-1"),
            snapshot.replacingOccurrences(of: "width=1024", with: "width=16385"),
            snapshot.replacingOccurrences(of: "width=1024", with: "width=01024"),
            snapshot.replacingOccurrences(of: "visibleHeight=600", with: "visibleHeight=NaN"),
            snapshot.replacingOccurrences(of: "hostHeight=600", with: ""), String(repeating: "x", count: 2_049)]
        for native in invalid { XCTAssertNil(record(snapshot: { native })) }
    }

    func testSnapshotFailureCannotEscapeDiagnosticPath() {
        enum FixtureFailure: Error { case unavailable }
        XCTAssertNil(record(snapshot: { throw FixtureFailure.unavailable }))
        XCTAssertNil(record(sequence: 0))
        XCTAssertNil(record(sequence: 1_001))
        XCTAssertNil(record(sessionID: "PRIVATE_SESSION_CANARY"))
    }

    func testRejectionAndVerifyModelRemainFiniteNegativeObservations() throws {
        var rejected = observation(action: "verifyModel", stage: "trigger_remount_rejected")
        rejected["error"] = "model_mismatch"
        let text = try XCTUnwrap(record(rejected, action: "verifyModel", sequence: 16))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(value["action"] as? String, "verifyModel")
        XCTAssertEqual(value["sequence"] as? Int, 16)
        XCTAssertEqual(value["stage"] as? String, "trigger_remount_rejected")
        XCTAssertNil(value["modelEvidence"])
        XCTAssertNil(value["text"])
    }
}
