import Foundation
import XCTest
@testable import Computa

final class WebsiteFailureHistoryTests: XCTestCase {
    func testFiniteRejectedToolDiagnosisSurvivesRecreationWithoutReplyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCodecFailureHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WebsiteModelChoice(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B").modelID
        let task = UUID().uuidString, thread = UUID().uuidString
        let failures: [WebModelResponseCodec.Failure] = [.unknownTool("PRIVATE_TOOL_CANARY"), .emptyReply,
            .malformedEnvelope, .unsupportedCallFields, .argumentsMustBeObject, .customInputMustBeString, .invalidBrowserReadArguments]
        for failure in failures {
            let turn = UUID().uuidString
            let data = try WebModelServer.errorBody(for: failure)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("PRIVATE_TOOL_CANARY"))
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turn, modelID: model, diagnosticText: text))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            XCTAssertEqual(try WebsiteTurnFailureStore(directory: root).load(threadID: thread).last, record)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for mutation: [String: Any] in [["message": "PRIVATE_PAGE_CANARY"], ["retryable": false],
                                           ["tool": "exec_command"], ["required_action": "retry"], ["param": "input"]] {
                var changed = original, fields = try XCTUnwrap(original["error"] as? [String: Any])
                mutation.forEach { fields[$0.key] = $0.value }; changed["error"] = fields
                let altered = try JSONSerialization.data(withJSONObject: changed)
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: turn, modelID: model, diagnosticText: String(decoding: altered, as: UTF8.self)))
            }
        }
    }

    func testKimiUnsupportedLiteralResponseSurvivesStoreRecreationAndKeepsTheExactTurnFailed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaKimiFormatHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant").modelID
        let failure = EmbeddedWebModelTransport.Failure.responseFormatUnavailable
        XCTAssertFalse(failure.blocksProviderUntilRefresh)
        let data = try WebModelServer.errorBody(for: failure)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(fields["code"] as? String, "unsupported_website_response")
        XCTAssertEqual(fields["retryable"] as? Bool, false)
        XCTAssertEqual(fields["required_action"] as? String, "inspect_website")
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString.lowercased()
        let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
            turnID: turnID, modelID: model, diagnosticText: String(decoding: data, as: UTF8.self)))
        XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
        let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
        XCTAssertEqual(restored, [record])
        let saved = try XCTUnwrap(restored.first)
        XCTAssertEqual(saved.taskID, task.lowercased())
        XCTAssertEqual(saved.threadID, thread.lowercased())
        XCTAssertEqual(saved.modelID, model)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.entry.body.utf8))
            as? [String: Any])).isEqual(to: envelope))
        let previousTurn = UUID().uuidString.lowercased()
        let generic = "Generic engine error"
        let raw = try history([turn(previousTurn, status: "failed", error: ["message": "Earlier failure"]),
            turn(turnID, status: "failed", error: ["message": generic])])
        let failedTurns = Set(restored.map(\.turnID))
        var entries = try AppServerThreadHistoryContract.entries(from: raw, excludingAssistantTurns: failedTurns)
        let index = try XCTUnwrap(entries.firstIndex { $0.id == saved.entry.id })
        entries[index] = saved.entry
        XCTAssertEqual(entries.first { $0.id == "agent-error:" + previousTurn }?.body, "Earlier failure")
        XCTAssertEqual(entries.last?.body, saved.diagnosticText)
        XCTAssertFalse(entries.contains { $0.kind == .assistant && $0.turnID == turnID })
        XCTAssertFalse(entries.contains { $0.body == generic })
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: raw,
            rejectedTurns: failedTurns, failedTurns: failedTurns), .failed)
    }

    func testKimiUnsupportedLiteralHistoryRejectsAlteredMetadataAndOtherProviderEnvelopes() throws {
        let data = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.responseFormatUnavailable)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        let model = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant").modelID
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        func rejected(_ object: [String: Any], forModel selected: String? = nil) throws {
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: selected ?? model,
                diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
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
        for foreign in [syntheticChatGPTModelID, "browser/claude", "browser/gemini", "browser/groq", "api/cerebras/model/fixture"] {
            try rejected(envelope, forModel: foreign)
        }
        let chatGPT = try WebModelServer.errorBody(for: WebModelResponseCodec.Failure.unsupportedWebsiteResponse)
        try rejected(try XCTUnwrap(JSONSerialization.jsonObject(with: chatGPT) as? [String: Any]))
    }

    func testClaudeResponseBlockSurvivesStoreRecreationWithExactTurnAndFailedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaClaudeBlockedHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = EmbeddedWebModelTransport.Failure.responseBlocked(.claude)
        XCTAssertFalse(failure.blocksProviderUntilRefresh, "Saving a turn failure must not invent a provider-wide gate")
        let data = try WebModelServer.errorBody(for: failure)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(fields["code"] as? String, "website_response_blocked")
        XCTAssertEqual(fields["retryable"] as? Bool, false)
        XCTAssertEqual(fields["required_action"] as? String, "inspect_website")
        let models = ["browser/claude", WebsiteModelChoice(provider: "claude", key: "opus-5", label: "Opus 5").modelID]
        for model in models {
            let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString.lowercased()
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turnID, modelID: model, diagnosticText: String(decoding: data, as: UTF8.self)))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
            XCTAssertEqual(restored, [record])
            let saved = try XCTUnwrap(restored.first)
            XCTAssertEqual(saved.taskID, task.lowercased())
            XCTAssertEqual(saved.threadID, thread.lowercased())
            XCTAssertEqual(saved.modelID, model)
            XCTAssertEqual(saved.entry.id, "agent-error:" + turnID)
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.entry.body.utf8))
                as? [String: Any])).isEqual(to: envelope))

            // The engine's generic terminal error must be replaced only for the
            // matching saved turn. Prior failure evidence remains independent.
            let previousTurn = UUID().uuidString.lowercased()
            let generic = "We’re currently experiencing high demand, which may cause temporary errors."
            let raw = try history([turn(previousTurn, status: "failed", error: ["message": "Earlier failure"]),
                turn(turnID, status: "failed", error: ["message": generic, "codexErrorInfo": "internal_server_error"])])
            let failedTurns = Set(restored.map(\.turnID))
            var entries = try AppServerThreadHistoryContract.entries(from: raw, excludingAssistantTurns: failedTurns)
            let errorIndex = try XCTUnwrap(entries.firstIndex { $0.id == saved.entry.id })
            entries[errorIndex] = saved.entry
            XCTAssertEqual(entries.first { $0.id == "agent-error:" + previousTurn }?.body, "Earlier failure")
            XCTAssertEqual(entries.last?.body, saved.diagnosticText)
            XCTAssertFalse(entries.contains { $0.kind == .assistant && $0.turnID == turnID })
            XCTAssertFalse(entries.contains { $0.body == generic })
            XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: raw,
                rejectedTurns: failedTurns, failedTurns: failedTurns), .failed)
        }
    }

    func testClaudeResponseBlockHistoryRejectsAlteredMetadataOtherProvidersAndPageText() throws {
        let data = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.responseBlocked(.claude))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        func rejected(_ object: [String: Any], model: String = "browser/claude") throws {
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: model, diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
        }
        let mutations: [[String: Any]] = [["message": "PRIVATE_PAGE_CANARY"], ["retryable": true], ["retryable": 0],
            ["required_action": "retry_send"], ["code": "website_response_failed"], ["type": "server_error"],
            ["param": "input"], ["reason": "PRIVATE_PAGE_CANARY"], ["url": "https://private.invalid/PRIVATE_PAGE_CANARY"],
            ["prompt": "PRIVATE_PROMPT_CANARY"]]
        for mutation in mutations {
            var altered = envelope, alteredFields = fields
            mutation.forEach { alteredFields[$0.key] = $0.value }; altered["error"] = alteredFields
            try rejected(altered)
        }
        for key in fields.keys {
            var missing = envelope, missingFields = fields
            missingFields.removeValue(forKey: key); missing["error"] = missingFields
            try rejected(missing)
        }
        var extra = envelope; extra["pageText"] = "PRIVATE_PAGE_CANARY"
        try rejected(extra)
        for model in [syntheticChatGPTModelID, "browser/gemini", "browser/groq", "api/cerebras/model/fixture"] {
            try rejected(envelope, model: model)
        }
        for provider in [EmbeddedWebModelTransport.Provider.chatgpt, .gemini, .groq] {
            let foreign = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.responseBlocked(provider))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: foreign) as? [String: Any])
            try rejected(object, model: "browser/" + provider.rawValue)
        }
    }

    func testChatProductInspectionPreservesOnlyExactCurrentAndHistoricalFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatProduct-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = UUID().uuidString, thread = UUID().uuidString
        let model = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID
        func text(_ fields: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["error": fields],
                options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        func make(_ fields: [String: Any], for modelID: String) throws -> WebsiteTurnFailureStore.Record? {
            WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: UUID().uuidString,
                modelID: modelID, diagnosticText: try text(fields))
        }
        let generated = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.productModeUnverified)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: generated) as? [String: Any])
        let new = try XCTUnwrap(envelope["error"] as? [String: Any])
        let old = new.merging(["message": "ChatGPT normal Chat mode could not be verified. No response was accepted and no prompt was replayed. Refresh website models before retrying.",
            "required_action": "refresh_website_models"]) { _, prior in prior }
        let store = WebsiteTurnFailureStore(directory: directory)
        var saved: [WebsiteTurnFailureStore.Record] = []
        for fields in [old, new] {
            let record = try XCTUnwrap(try make(fields, for: model))
            XCTAssertEqual(record.diagnosticText, try text(fields))
            XCTAssertTrue(store.append(record))
            saved.append(record)
            XCTAssertNil(try make(fields, for: "browser/claude"))
            XCTAssertNil(try make(fields, for: "api/alibaba/model/fixture"))
            for edits: [String: Any] in [["retryable": true], ["retryable": 0], ["message": "PRIVATE_CANARY"],
                ["code": "invalid_product"], ["extra": "PRIVATE_CANARY"]] {
                XCTAssertNil(try make(fields.merging(edits) { _, v in v }, for: model))
            }
        }
        XCTAssertNil(try make(new.merging(["required_action": "refresh_website_models"]) { _, v in v }, for: model))
        XCTAssertNil(try make(old.merging(["required_action": "inspect_website"]) { _, v in v }, for: model))
        XCTAssertEqual(try WebsiteTurnFailureStore(directory: directory).load(threadID: thread), saved)
    }

    func testQuotaRecoveryMessageUsesAvailableRestartPathAndPreservesExactLegacyHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaQuotaHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID().uuidString, thread = UUID().uuidString
        var expectedRecords: [WebsiteTurnFailureStore.Record] = []
        for provider in [EmbeddedWebModelTransport.Provider.chatgpt, .claude, .gemini] {
            let failure = EmbeddedWebModelTransport.Failure.usageLimited(provider)
            XCTAssertTrue(failure.blocksProviderUntilRefresh, "Copy changes cannot grant automatic retries")
            XCTAssertEqual(failure.requiredAction, "wait_for_quota_reset")
            let body = try WebModelServer.errorBody(for: failure)
            let current = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let fields = try XCTUnwrap(current["error"] as? [String: Any])
            XCTAssertEqual(fields["message"] as? String,
                "\(provider.displayName)'s website usage limit has been reached. After your account's limit resets, restart Computa, then start a fresh task.")
            XCTAssertEqual(fields["code"] as? String, "website_usage_limit")
            XCTAssertEqual(fields["required_action"] as? String, "wait_for_quota_reset")
            XCTAssertEqual(fields["retryable"] as? Bool, false)
            var legacy = current, legacyFields = fields
            legacyFields["message"] = "\(provider.displayName)'s website usage limit has been reached. After your account's limit resets, refresh website models before retrying."
            legacy["error"] = legacyFields
            for envelope in [current, legacy] {
                let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope,
                    options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
                let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: UUID().uuidString, modelID: "browser/" + provider.rawValue, diagnosticText: text))
                XCTAssertEqual(record.diagnosticText, text, "Old history retains its exact original finite message")
                XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
                expectedRecords.append(record)
            }
        }
        XCTAssertEqual(try WebsiteTurnFailureStore(directory: root).load(threadID: thread), expectedRecords)
    }

    func testQuotaHistoryCompatibilityRejectsNearMissMessagesAndChangedEnvelopeFields() throws {
        let native = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.usageLimited(.claude))
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        var legacy = current, legacyFields = try XCTUnwrap(current["error"] as? [String: Any])
        legacyFields["message"] = "Claude's website usage limit has been reached. After your account's limit resets, refresh website models before retrying."
        legacy["error"] = legacyFields
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        func rejected(_ envelope: [String: Any], model: String = "browser/claude") throws {
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turn,
                modelID: model, diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)))
        }
        for envelope in [current, legacy] {
            let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
            let message = try XCTUnwrap(fields["message"] as? String)
            let mutations: [[String: Any]] = [["message": message + " "], ["message": message.replacingOccurrences(of: "Claude", with: "Gemini")],
                ["message": "Restart Computa to reset quota."], ["retryable": true], ["retryable": 0],
                ["required_action": "retry_send"], ["type": "server_error"], ["code": "internal_error"],
                ["param": "input"], ["pageText": "PRIVATE_PAGE_TEXT"]]
            for mutation in mutations {
                var altered = envelope, alteredFields = fields
                mutation.forEach { alteredFields[$0.key] = $0.value }
                altered["error"] = alteredFields
                try rejected(altered)
            }
            var extra = envelope; extra["extra"] = "unexpected"
            try rejected(extra)
            var missing = envelope, missingFields = fields; missingFields.removeValue(forKey: "param"); missing["error"] = missingFields
            try rejected(missing)
            try rejected(envelope, model: "browser/gemini")
        }
    }

    func testWebsiteTurnLimitSurvivesReloadWithPriorActionWarningAndExactFailureIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaWebsiteTurnLimit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let serverData = try WebModelServer.errorBody(for: WebModelServer.Failure.turnLimit)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: serverData) as? [String: Any])
        let error = try XCTUnwrap(expected["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "website_turn_limit")
        XCTAssertEqual(error["type"] as? String, "invalid_request")
        XCTAssertNil(error["retryable"], "Preserve the native envelope without inventing retry authority")
        XCTAssertNil(error["required_action"])
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("Earlier actions may have completed"))
        XCTAssertTrue(message.contains("Review their results before continuing"))
        XCTAssertFalse(message.contains("start a new task"))

        let task = UUID().uuidString, thread = UUID().uuidString
        let failures: [any Error] = [WebModelServer.Failure.turnLimit, EmbeddedWebModelTransport.Failure.turnLimit]
        for failure in failures {
            let native = try WebModelServer.errorBody(for: failure)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected), "Both budget boundaries must preserve the same warning")
            let turnID = UUID().uuidString.lowercased()
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turnID, modelID: syntheticChatGPTModelID, diagnosticText: String(decoding: native, as: UTF8.self)))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
            let saved = try XCTUnwrap(restored.first { $0.turnID == turnID })
            XCTAssertEqual(saved, record)
            XCTAssertEqual(saved.taskID, task.lowercased())
            XCTAssertEqual(saved.threadID, thread.lowercased())
            XCTAssertEqual(saved.entry.title, "Agent error")
            XCTAssertEqual(saved.entry.id, "agent-error:" + turnID)
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.entry.body.utf8)) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: persisted).isEqual(to: expected))
            let raw = try history([turn(turnID, status: "failed", error: ["message": "Generic engine failure"])])
            let entries = try AppServerThreadHistoryContract.entries(from: raw,
                excludingAssistantTurns: Set(restored.map(\.turnID)))
            XCTAssertEqual(entries.last?.id, saved.entry.id, "Reload must replace the exact engine error, never another turn")
            XCTAssertFalse(entries.contains { $0.kind == .assistant })
            XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: raw,
                rejectedTurns: Set(restored.map(\.turnID)), failedTurns: Set(restored.map(\.turnID))), .failed)
        }
    }

    func testWebsiteTurnLimitStoreRejectsChangedWarningsAndReplayMetadata() throws {
        let native = try WebModelServer.errorBody(for: WebModelServer.Failure.turnLimit)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        let mutations: [[String: Any]] = [["message": "PRIVATE_ACTION_RESULT"], ["retryable": false],
            ["retryable": true], ["retryable": 0], ["required_action": "retry_send"],
            ["type": "server_error"], ["code": "internal_error"], ["param": "input"],
            ["pageText": "PRIVATE_ACTION_RESULT"]]
        for mutation in mutations {
            var changed = original, error = try XCTUnwrap(original["error"] as? [String: Any])
            mutation.forEach { error[$0.key] = $0.value }; changed["error"] = error
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: syntheticChatGPTModelID,
                diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)))
        }
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
            modelID: "api/cerebras/model/fixture", diagnosticText: String(decoding: native, as: UTF8.self)))
    }

    func testUnsupportedChatGPTResponseSurvivesStoreRecreationWithExactHistoryReplacementIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaUnsupportedWebsiteReply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try WebModelServer.errorBody(for: WebModelResponseCodec.Failure.unsupportedWebsiteResponse)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unsupported_website_response")
        XCTAssertNil(error["retryable"], "Persist the exact existing native envelope without inventing retry authority")
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString.lowercased()
        let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
            turnID: turnID, modelID: syntheticChatGPTModelID, diagnosticText: String(decoding: native, as: UTF8.self)))
        XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
        let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
        XCTAssertEqual(restored, [record], "A fresh store must retain the exact local classification")
        let entry = try XCTUnwrap(restored.first?.entry)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(entry.body.utf8)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: persisted).isEqual(to: object))
        XCTAssertEqual(entry.turnID, turnID)
        XCTAssertEqual(entry.title, "Agent error")
        XCTAssertFalse(entry.body.contains("high demand"))

        // The runtime replaces the generic engine entry by this exact stable
        // identity after reloading the store; it must never target another turn.
        let generic = "We’re currently experiencing high demand, which may cause temporary errors."
        let raw = try history([turn(turnID, status: "failed", error: ["message": generic])])
        let entries = try AppServerThreadHistoryContract.entries(from: raw,
            excludingAssistantTurns: Set(restored.map(\.turnID)))
        XCTAssertEqual(entries.last?.id, entry.id)
        XCTAssertEqual(entries.last?.body, generic)
        XCTAssertFalse(entries.contains { $0.kind == .assistant })
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: raw,
            rejectedTurns: Set(restored.map(\.turnID)), failedTurns: Set(restored.map(\.turnID))), .failed)
    }

    func testUnsupportedChatGPTResponseStoreRejectsForgedTextRetryFieldsAndOtherProviders() throws {
        let native = try WebModelServer.errorBody(for: WebModelResponseCodec.Failure.unsupportedWebsiteResponse)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        for modelID in ["browser/gemini", "browser/claude", "api/cerebras/model/fixture"] {
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: modelID, diagnosticText: String(decoding: native, as: UTF8.self)))
        }
        let mutations: [[String: Any]] = [["message": "PRIVATE_PROVIDER_REPLY_CANARY"], ["retryable": false],
            ["retryable": true], ["retryable": 0], ["type": "server_error"], ["code": "internal_error"],
            ["required_action": "retry_send"], ["pageText": "PRIVATE_PROVIDER_REPLY_CANARY"], ["param": "input"]]
        for mutation in mutations {
            var changed = original, error = try XCTUnwrap(original["error"] as? [String: Any])
            mutation.forEach { error[$0.key] = $0.value }; changed["error"] = error
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: syntheticChatGPTModelID,
                diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)))
        }
    }

    func testNativeBrowserFailuresSurviveStoreRecreationWithExactTaskAndTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaBrowserStartupError-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID().uuidString, thread = UUID().uuidString
        var records: [WebsiteTurnFailureStore.Record] = []
        for failure in WebModelServer.NativeBrowserFailure.allCases {
            let data = try WebModelServer.errorBody(for: failure)
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: UUID().uuidString, modelID: syntheticChatGPTModelID, diagnosticText: String(decoding: data, as: UTF8.self)))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            records.append(record)
            for model in ["browser/gemini", "browser/claude"] {
                XCTAssertEqual(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: UUID().uuidString, modelID: model, diagnosticText: String(decoding: data, as: UTF8.self)) != nil,
                    !failure.requiresChatGPT, "Cookie preparation diagnostics belong only to ChatGPT")
            }
        }
        let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
        XCTAssertEqual(restored, records)
        for record in restored {
            XCTAssertEqual(record.taskID, task.lowercased())
            XCTAssertEqual(record.threadID, thread.lowercased())
            XCTAssertEqual(record.entry.turnID, record.turnID)
            XCTAssertEqual(record.entry.title, "Agent error")
            XCTAssertFalse(record.entry.body.contains("high demand"))
        }
    }

    func testNativeBrowserFailureStoreRejectsUnknownReasonsPrivateDataAndCrossFamilyClaims() throws {
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        for failure in [WebModelServer.NativeBrowserFailure.profileVerificationFailed, .tabClosed] {
            let data = try WebModelServer.errorBody(for: failure)
            let mutations: [[String: Any]] = [["reason": "PRIVATE_COOKIE_CANARY"], ["reason": 1],
                ["reason": failure.requiresChatGPT ? "tab_closed" : "verification_failed"],
                ["code": failure.requiresChatGPT ? "website_browser_session_failed" : "chatgpt_profile_preparation_failed"],
                ["message": "PRIVATE_COOKIE_CANARY"], ["retryable": 0], ["retryable": true],
                ["cookie_name": "PRIVATE_COOKIE_CANARY"], ["url": "https://private.invalid/PRIVATE_COOKIE_CANARY"],
                ["required_action": "retry_send"], ["cleanup": "not_created"]]
            for mutation in mutations {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var error = try XCTUnwrap(object["error"] as? [String: Any])
                mutation.forEach { error[$0.key] = $0.value }; object["error"] = error
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                    modelID: syntheticChatGPTModelID, diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
            }
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: "api/cerebras/model/fixture", diagnosticText: String(decoding: data, as: UTF8.self)))
        }
    }

    func testFixedModelAndCleanupFailuresSurviveStoreRecreationWithoutReplacingAnotherTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaFixedBrowserFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let failures: [any Error] = [EmbeddedWebModelTransport.Failure.pageUnavailable,
            EmbeddedWebModelTransport.Failure.modelUnverified, EmbeddedWebModelTransport.Failure.modelMismatch,
            EmbeddedWebModelTransport.Failure.editorFailure("composer_not_empty"),
            WebModelServer.Failure.modelUnverified, WebModelServer.Failure.modelMismatch, WebModelServer.Failure.cleanupFailed]
        let models = [syntheticChatGPTModelID, "browser/claude", "browser/gemini", "browser/groq",
            WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant").modelID,
            WebsiteModelChoice(provider: "qwen", key: "Qwen3.7-Plus", label: "Qwen3.7-Plus").modelID,
            "browser/deepseek/mode/chat"]
        for model in models {
            for failure in failures {
                let original = try WebModelServer.errorBody(for: failure)
                let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
                let thread = UUID().uuidString, turnID = UUID().uuidString.lowercased(), priorTurn = UUID().uuidString.lowercased()
                let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: UUID().uuidString,
                    threadID: thread, turnID: turnID, modelID: model, diagnosticText: String(decoding: original, as: UTF8.self)))
                XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
                let reloaded = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
                XCTAssertEqual(reloaded, [record])
                let generic = "We’re currently experiencing high demand, which may cause temporary errors."
                let raw = try history([turn(priorTurn, status: "failed", error: ["message": "Earlier failure"]),
                    turn(turnID, status: "failed", error: ["message": generic, "codexErrorInfo": "internal_server_error"])])
                let rejected = Set(reloaded.map(\.turnID))
                var entries = try AppServerThreadHistoryContract.entries(from: raw, excludingAssistantTurns: rejected)
                let index = try XCTUnwrap(entries.firstIndex { $0.id == record.entry.id })
                entries[index] = record.entry
                let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(entries[index].body.utf8)) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected))
                XCTAssertEqual(entries.first { $0.id == "agent-error:" + priorTurn }?.body, "Earlier failure")
                XCTAssertFalse(entries.contains { $0.kind == .assistant && $0.turnID == turnID })
                XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: raw,
                    rejectedTurns: rejected, failedTurns: rejected), .failed)
            }
        }
    }

    func testFixedBrowserFailurePersistenceRejectsUnknownProseExtraMetadataAndAPIModels() throws {
        let failures: [any Error] = [EmbeddedWebModelTransport.Failure.modelUnverified, WebModelServer.Failure.cleanupFailed]
        for failure in failures {
            let data = try WebModelServer.errorBody(for: failure)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let fields = try XCTUnwrap(original["error"] as? [String: Any])
            func rejected(_ object: [String: Any], model: String = "browser/deepseek/mode/chat") throws {
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: UUID().uuidString, threadID: UUID().uuidString,
                    turnID: UUID().uuidString, modelID: model,
                    diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
            }
            let mutations: [[String: Any]] = [["message": "PRIVATE_PAGE_TEXT"], ["retryable": true], ["retryable": false],
                ["reason": "PRIVATE_REASON"], ["required_action": "retry_send"], ["type": "server_error"], ["param": "input"]]
            for mutation in mutations {
                var changed = original, error = fields; mutation.forEach { error[$0.key] = $0.value }; changed["error"] = error
                try rejected(changed)
            }
            for key in fields.keys {
                var changed = original, error = fields; error.removeValue(forKey: key); changed["error"] = error
                try rejected(changed)
            }
            var changed = original; changed["pageText"] = "PRIVATE_PAGE_TEXT"; try rejected(changed)
            try rejected(original, model: "api/cerebras/model/fixture")
            try rejected(original, model: "browser/deepseek")
        }
        let privateError = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.editorFailure("PRIVATE_BODY"))
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: UUID().uuidString, threadID: UUID().uuidString,
            turnID: UUID().uuidString, modelID: syntheticChatGPTModelID, diagnosticText: String(decoding: privateError, as: UTF8.self)))
    }

    private func history(_ turns: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": turns]]]) }
    private func turn(_ id: String, status: String? = nil, error: Any = NSNull(), user: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["id": id, "startedAt": 100, "completedAt": 110, "error": error,
            "items": (user ? [["id": "user-" + id, "type": "userMessage", "content": [["type": "text", "text": "Original " + id]]]] : [])
                + [["id": "assistant-" + id, "type": "agentMessage", "text": "UNVERIFIED_CLAIM"]]]
        if let status { value["status"] = status }
        return value
    }

    func testSavedFailureRestoresOriginalEngineErrorAndFailedWithoutAssistantClaims() throws {
        let message = "We’re currently experiencing high demand, which may cause temporary errors."
        let data = try history([turn("failed", status: "failed", error: ["message": message, "codexErrorInfo": "internal_server_error"])])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data), .failed)
        let entries = try AppServerThreadHistoryContract.entries(from: data)
        XCTAssertEqual(entries.map(\.title), ["You", "Agent error"])
        XCTAssertEqual(entries.last?.body, message); XCTAssertEqual(entries.last?.turnID, "failed")
        XCTAssertFalse(entries.last!.body.contains("malformed_website_reply"), "A historical generic error cannot reconstruct an unpersisted native diagnostic")
    }

    func testNonNullErrorsCannotCertifyCompletionEvenWhenTheirTextIsMissingOrOversized() throws {
        let errors: [Any] = [["code": "failure"], ["message": ""], ["message": String(repeating: "X", count: 8_193)], "malformed error"]
        for error in errors {
            let data = try history([turn("failed", status: "completed", error: error)])
            XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data), .failed)
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

    func testExactWebsiteFailureRecordRestoresFailedWithoutRelabellingNativeStops() throws {
        let data = try history([turn("native-stop", status: "interrupted"), turn("website", status: "inProgress")])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data,
            rejectedTurns: ["native-stop", "website"], failedTurns: ["website"]), .failed)
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: data,
            rejectedTurns: ["native-stop", "website"], failedTurns: ["older-website"]), .waiting)
        let interrupted = try history([turn("native-stop", status: "interrupted", error: ["message": "Stopped"])])
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: interrupted,
            rejectedTurns: ["native-stop"]), .waiting)
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(from: interrupted), .waiting)
        XCTAssertEqual(try AppServerThreadHistoryContract.latestUserTurnStatus(
            from: history([turn("no-error-text", status: "failed")])), .failed)
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

    func testPageInspectionFailureRoundTripsItsExactNativeEnvelopeWithoutAddingRetryMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaInspectionError-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.pageUnavailable)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "browser_model_error")
        XCTAssertEqual(error["message"] as? String, EmbeddedWebModelTransport.Failure.pageUnavailable.localizedDescription)
        XCTAssertNil(error["retryable"])
        for modelID in [syntheticChatGPTModelID, "browser/gemini", "browser/claude"] {
            let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turnID, modelID: modelID, diagnosticText: String(decoding: native, as: UTF8.self)))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
            XCTAssertEqual(restored, [record])
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(restored[0].diagnosticText.utf8)) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: saved).isEqual(to: object))
            XCTAssertEqual(restored[0].entry.turnID, turnID.lowercased())
            XCTAssertFalse(restored[0].entry.body.contains("high demand"))
        }
    }

    func testPageInspectionStoreRejectsOtherGenericErrorsAndAnyChangedOrAdditionalFields() throws {
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        let native = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.pageUnavailable)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        let mutations: [[String: Any]] = [["message": "PRIVATE_PAGE_CANARY"], ["type": "server_error"],
            ["code": "internal_error"], ["param": "input"], ["required_action": "retry_send"],
            ["retryable": true], ["retryable": false], ["retryable": 0], ["retryable": NSNull()],
            ["pageText": "PRIVATE_PAGE_CANARY"]]
        var objects = try mutations.map { mutation -> [String: Any] in
            var object = original, error = try XCTUnwrap(original["error"] as? [String: Any])
            mutation.forEach { error[$0.key] = $0.value }; object["error"] = error
            return object
        }
        for key in ["message", "param"] {
            var object = original, error = try XCTUnwrap(original["error"] as? [String: Any])
            error.removeValue(forKey: key); object["error"] = error; objects.append(object)
        }
        var extra = original; extra["pageText"] = "PRIVATE_PAGE_CANARY"; objects.append(extra)
        for object in objects {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: syntheticChatGPTModelID, diagnosticText: text))
        }
        // Fixed model-verification envelopes are covered by the round-trip
        // matrix; unrelated generic failures and page-authored prose stay out.
        for failure in [EmbeddedWebModelTransport.Failure.staleSession, .responseInterrupted, .editorFailure("PRIVATE_PAGE_CANARY")] {
            let data = try WebModelServer.errorBody(for: failure)
            let error = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "browser_model_error")
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: syntheticChatGPTModelID, diagnosticText: String(decoding: data, as: UTF8.self)))
        }
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
            modelID: "api/cerebras/model/fixture", diagnosticText: String(decoding: native, as: UTF8.self)))
    }

    func testFiniteOwnershipReasonsSurviveStoreRecreationWithExactTurnAndModelIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaOwnershipError-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let reasons: [EmbeddedWebModelTransport.OwnershipReason] = [.documentGenerationBefore, .documentGenerationAfter,
            .routeBefore, .routeAfter, .unboundCleanup, .javaScriptDocument, .javaScriptConversation, .javaScriptOwner,
            .javaScriptUserCount, .javaScriptConversationIdentity, .javaScriptURL, .javaScriptConversationRoute,
            .javaScriptFirstUser, .javaScriptSubmission, .promotionFirstUser, .promotionTemporary]
        for modelID in [syntheticChatGPTModelID, "browser/gemini", "browser/claude"] {
            let task = UUID().uuidString, thread = UUID().uuidString
            var expected: [WebsiteTurnFailureStore.Record] = []
            for reason in reasons {
                let failure = EmbeddedWebModelTransport.Failure.ownershipFailure(reason)
                XCTAssertFalse(failure.blocksProviderUntilRefresh)
                let data = try WebModelServer.errorBody(for: failure)
                let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: UUID().uuidString, modelID: modelID, diagnosticText: String(decoding: data, as: UTF8.self)))
                XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
                expected.append(record)
            }
            let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
            XCTAssertEqual(restored, expected)
            for record in restored {
                XCTAssertEqual(record.taskID, task.lowercased()); XCTAssertEqual(record.threadID, thread.lowercased())
                XCTAssertEqual(record.modelID, modelID); XCTAssertEqual(record.entry.turnID, record.turnID)
                XCTAssertTrue(record.entry.body.contains("website_ownership_unverified"))
                XCTAssertFalse(record.entry.body.contains("high demand"))
            }
        }
    }

    func testOwnershipStoreRejectsForgedReasonMessageMetadataAndArbitraryErrors() throws {
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        let modelID = syntheticChatGPTModelID
        let data = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.ownershipFailure(.javaScriptFirstUser))
        let mutations: [[String: Any]] = [["ownership_reason": "PRIVATE_PAGE_CANARY"], ["ownership_reason": 1],
            ["ownership_reason": "route_after"], ["message": "PRIVATE_PAGE_CANARY"], ["retryable": 0],
            ["retryable": true], ["code": "browser_model_error"], ["required_action": "retry_send"],
            ["url": "https://private.invalid/PRIVATE_PAGE_CANARY"], ["prompt": "PRIVATE_PROMPT_CANARY"]]
        for mutation in mutations {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var error = try XCTUnwrap(object["error"] as? [String: Any])
            mutation.forEach { error[$0.key] = $0.value }; object["error"] = error
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: modelID, diagnosticText: text))
        }
        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var error = try XCTUnwrap(missing["error"] as? [String: Any]); error.removeValue(forKey: "ownership_reason"); missing["error"] = error
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID, modelID: modelID,
            diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: missing), as: UTF8.self)))
        let arbitrary = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "website_ownership_unverified first_user_message PRIVATE_PAGE_CANARY"])
        let arbitraryData = try WebModelServer.errorBody(for: arbitrary)
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID, modelID: modelID,
            diagnosticText: String(decoding: arbitraryData, as: UTF8.self)))
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID, modelID: "api/cerebras/model/fixture",
            diagnosticText: String(decoding: data, as: UTF8.self)))
    }

    func testContinuationFailurePersistsOnlyCanonicalGeminiNativeEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaContinuationError-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID().uuidString, thread = UUID().uuidString, turnID = UUID().uuidString
        let data = try WebModelServer.errorBody(for: WebsiteTurnContinuation.Failure.invalidToolOutputs)
        let text = String(decoding: data, as: UTF8.self)
        let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
            turnID: turnID, modelID: "browser/gemini", diagnosticText: text))
        XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
        XCTAssertEqual(try WebsiteTurnFailureStore(directory: root).load(threadID: thread), [record])
        for model in [syntheticChatGPTModelID, "browser/claude", "api/cerebras/model/fixture"] {
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: model, diagnosticText: text))
        }
        for mutation in [["reason": "private canary"], ["reason": "changed_history"],
                         ["message": "private canary"], ["retryable": true], ["prompt": "private canary"]] as [[String: Any]] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var error = try XCTUnwrap(object["error"] as? [String: Any]); mutation.forEach { error[$0.key] = $0.value }; object["error"] = error
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread, turnID: turnID,
                modelID: "browser/gemini", diagnosticText: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
        }
    }
}
