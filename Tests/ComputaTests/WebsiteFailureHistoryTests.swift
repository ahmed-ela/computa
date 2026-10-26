import Foundation
import XCTest
@testable import Computa

final class WebsiteFailureHistoryTests: XCTestCase {
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
        for failure in [EmbeddedWebModelTransport.Failure.staleSession, .responseInterrupted, .modelUnverified] {
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
