import Foundation
import XCTest
@testable import Computa

final class QwenWebsiteFailureHistoryTests: XCTestCase {
    func testExactNativeSourceFailurePersistsWithEachObservedWebsiteModelDuringPilotAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaQwenFormatHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = EmbeddedWebModelTransport.Failure.responseFormatUnavailable
        XCTAssertFalse(failure.blocksProviderUntilRefresh)
        let data = try WebModelServer.errorBody(for: failure)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(fields["code"] as? String, "unsupported_website_response")
        XCTAssertEqual(fields["retryable"] as? Bool, false)
        XCTAssertEqual(fields["required_action"] as? String, "inspect_website")
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let model = WebsiteModelChoice(provider: "qwen", key: label, label: label).modelID
            XCTAssertEqual(WebModelServer.provider(for: model), "qwen")
            XCTAssertNotNil(WebsiteModelCatalog.inferenceSelection(for: model), "Only the restricted pilot identities are admitted")
            let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turn, modelID: model, diagnosticText: String(decoding: data, as: UTF8.self)))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
            XCTAssertEqual(restored, [record])
            let saved = try XCTUnwrap(restored.first)
            XCTAssertEqual(saved.modelID, model)
            XCTAssertEqual(saved.taskID, task.lowercased())
            XCTAssertEqual(saved.threadID, thread.lowercased())
            XCTAssertEqual(saved.turnID, turn.lowercased())
            XCTAssertEqual(saved.entry.id, "agent-error:" + turn.lowercased())
            XCTAssertEqual(saved.entry.title, "Agent error")
            let savedEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.entry.body.utf8)) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: savedEnvelope).isEqual(to: envelope))
            XCTAssertEqual(try WebsiteTurnFailureStore(directory: root).load(threadID: UUID().uuidString), [])
        }
    }

    func testQwenFormatHistoryRejectsChangedFieldsPageProseAndOtherNativeEnvelopes() throws {
        let data = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.responseFormatUnavailable)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        let model = WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Max", label: "Qwen3.8-Max").modelID
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        func rejected(_ object: [String: Any], modelID: String? = nil) throws {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turn,
                modelID: modelID ?? model, diagnosticText: text))
        }
        let mutations: [[String: Any]] = [["message": "PRIVATE_PAGE_CANARY"], ["retryable": true], ["retryable": 0],
            ["required_action": "retry_send"], ["type": "server_error"], ["code": "browser_model_error"],
            ["param": "input"], ["pageText": "PRIVATE_PAGE_CANARY"]]
        for mutation in mutations {
            var changed = envelope, changedFields = fields
            mutation.forEach { changedFields[$0.key] = $0.value }; changed["error"] = changedFields
            try rejected(changed)
        }
        for key in fields.keys {
            var missing = envelope, missingFields = fields
            missingFields.removeValue(forKey: key); missing["error"] = missingFields
            try rejected(missing)
        }
        var extra = envelope; extra["pageText"] = "PRIVATE_PAGE_CANARY"; try rejected(extra)
        for foreign in ["browser/chatgpt", "browser/claude", "browser/gemini", "api/cerebras/model/fixture"] {
            try rejected(envelope, modelID: foreign)
        }
        let legacy = try WebModelServer.errorBody(for: WebModelResponseCodec.Failure.unsupportedWebsiteResponse)
        try rejected(try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any]))
    }
}
