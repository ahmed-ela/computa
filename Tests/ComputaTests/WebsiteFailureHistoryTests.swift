import Foundation
import XCTest
@testable import Computa

final class WebsiteFailureHistoryTests: XCTestCase {
    private func history(_ turns: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": turns]]]) }
    private func turn(_ id: String, status: String? = nil, error: Any = NSNull(), user: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["id": id, "startedAt": 100, "completedAt": 110, "error": error,
            "items": (user ? [["id": "user-" + id, "type": "userMessage", "content": [["type": "text", "text": "Original " + id]]]] : [])
                + [["id": "assistant-" + id, "type": "agentMessage", "text": "UNVERIFIED_CLAIM"]]]
        if let status { value["status"] = status }
        return value
    }

    func testSavedFailureRestoresOriginalEngineErrorAndWaitingWithoutAssistantClaims() throws {
        let message = "We’re currently experiencing high demand, which may cause temporary errors."
        let data = try history([turn("failed", status: "failed", error: ["message": message, "codexErrorInfo": "internal_server_error"])])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data), .waiting)
        let entries = try AppServerThreadHistoryContract.entries(from: data)
        XCTAssertEqual(entries.map(\.title), ["You", "Agent error"])
        XCTAssertEqual(entries.last?.body, message); XCTAssertEqual(entries.last?.turnID, "failed")
        XCTAssertFalse(entries.last!.body.contains("malformed_website_reply"), "A historical generic error cannot reconstruct an unpersisted native diagnostic")
    }

    func testNonNullErrorsCannotCertifyCompletionEvenWhenTheirTextIsMissingOrOversized() throws {
        let errors: [Any] = [["code": "failure"], ["message": ""], ["message": String(repeating: "X", count: 8_193)], "malformed error"]
        for error in errors {
            let data = try history([turn("failed", status: "completed", error: error)])
            XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data), .waiting)
            XCTAssertTrue(try AppServerThreadHistoryContract.entries(from: data).allSatisfy { $0.kind == .user })
        }
    }

    func testActiveTransientErrorStaysRunningUntilAnExactDurableStopRecordExists() throws {
        let data = try history([turn("active", status: "inProgress", error: ["message": "Recoverable connection issue"])])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data), .running)
        XCTAssertFalse(try AppServerThreadHistoryContract.entries(from: data).contains { $0.title == "Agent error" })
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data, rejectedTurns: ["active"]), .waiting)
        XCTAssertFalse(try AppServerThreadHistoryContract.entries(from: data, excludingAssistantTurns: ["active"]).contains { $0.kind == .assistant })
    }

    func testLatestActualUserTurnSupersedesOlderFailureAndMaintenanceIsNotANewUserOutcome() throws {
        let data = try history([turn("old", status: "failed", error: ["message": "Old failure"]),
            turn("new", status: "completed"), turn("maintenance", status: "failed", error: ["message": "Maintenance failure"], user: false)])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data, rejectedTurns: ["old"]), .completed)
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnID(from: data), "new")
        let entries = try AppServerThreadHistoryContract.entries(from: data)
        XCTAssertFalse(entries.contains { $0.id == "assistant-old" })
        XCTAssertTrue(entries.contains { $0.id == "assistant-new" })
    }

    func testUnknownOutcomeAndMissingAssistantAreNotFailureEvidence() throws {
        let statuses: [String?] = [nil, "futureStatus"]
        for status in statuses {
            let data = try history([turn("unknown", status: status)])
            XCTAssertNil(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data))
            XCTAssertFalse(try AppServerThreadHistoryContract.entries(from: data).contains { $0.title == "Agent error" })
        }
        let interrupted = try history([turn("interrupted", status: "interrupted")])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: interrupted), .waiting)
        XCTAssertFalse(try AppServerThreadHistoryContract.entries(from: interrupted).contains { $0.kind == .assistant })
    }

    func testFiniteWebsiteStoreRoundTripsNativePayloadAndRejectsPageProseOrNumericBooleans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaWebsiteError-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try WebModelServer.errorBody(for: WebModelServer.Failure.malformedReply(.init(reason: .invalidJSON, utf8Bytes: 1_279, fenced: false)))
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
            modelID: "browser/claude", diagnosticText: String(decoding: native, as: UTF8.self)))
        let store = WebsiteTurnFailureStore(directory: root)
        XCTAssertTrue(store.append(record)); XCTAssertTrue(store.append(record))
        XCTAssertEqual(try store.load(threadID: thread), [record])
        XCTAssertTrue(record.entry.body.contains("invalid_json")); XCTAssertTrue(record.entry.body.contains("1279"))
        let mutations: [[String: Any]] = [["message": "PRIVATE_PROVIDER_PAGE_CANARY"], ["json_fenced": 0], ["retryable": 0], ["pageText": "PRIVATE_PROVIDER_PAGE_CANARY"], ["reason": "unknown"], ["reply_bytes": true]]
        for mutation in mutations {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
            var error = try XCTUnwrap(raw["error"] as? [String: Any]); mutation.forEach { error[$0.key] = $0.value }; raw["error"] = error
            let text = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID, modelID: "browser/claude", diagnosticText: text))
        }
        let file = root.appendingPathComponent(thread.lowercased() + ".json")
        let untouched = root.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: untouched); try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: untouched)
        XCTAssertFalse(store.append(record)); XCTAssertThrowsError(try store.load(threadID: thread))
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "untouched")
    }
}
