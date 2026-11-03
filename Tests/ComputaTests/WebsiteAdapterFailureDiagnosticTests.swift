import Darwin
import Foundation
import XCTest
@testable import Computa

final class WebsiteAdapterFailureDiagnosticTests: XCTestCase {
    private typealias D = WebsiteAdapterFailureDiagnostic

    func testThreeProviderPacketsAreFiniteAndOnlyMatchTheirOriginalFailure() throws {
        for provider in ["kimi", "qwen", "deepseek"] {
            let packet = WebsiteAdapterFailureFixture.packet(provider)
            let error = provider == "qwen" ? "conversation_changed" : "unsupported_response_format"
            let detail = provider == "kimi" ? "authored_source_markdown_count" : provider == "qwen" ? "first_user_message" : "authored_source"
            let safe = try XCTUnwrap(D.sanitize(packet, provider: provider, error: error, detail: detail))
            XCTAssertLessThan(safe.data.count, D.maximumPacketBytes)
            XCTAssertNil(D.sanitize(packet, provider: provider, error: "model_unverified", detail: detail))
            XCTAssertNil(D.sanitize(packet, provider: provider, error: error, detail: "other"))
            XCTAssertNil(D.sanitize(packet, provider: "claude", error: error, detail: detail))
        }
    }

    private var qwenAuthoredFailure: [String: Any] {
        ["version": 1, "provider": "qwen", "trigger": "authored_source", "stage": "paragraph", "reason": "tag", "count": 0]
    }

    func testQwenAuthoredSourceRejectsForeignOrImpossibleFieldsAndStripsEveryObservation() {
        func sanitized(_ value: [String: Any]) -> D.Packet? {
            D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source")
        }
        let valid = qwenAuthoredFailure
        XCTAssertNotNil(sanitized(valid))
        for (key, value) in [("stage", "PRIVATE_TAG"), ("reason", "PRIVATE_CLASS"), ("text", "PRIVATE_BODY"),
                             ("count", true), ("count", 0.5), ("count", 3), ("count", 1)] as [(String, Any)] {
            var bad = valid; bad[key] = value
            XCTAssertNil(sanitized(bad))
        }
        for (stage, reason, count) in [("flow", "count", 1), ("phase", "scope", 0), ("markdown", "count", 1),
                                      ("literal_contents", "count", 0), ("outside", "count", 2)] {
            var bad = valid; bad["stage"] = stage; bad["reason"] = reason; bad["count"] = count
            XCTAssertNil(sanitized(bad))
        }
        for action in ["inspect", "deleteConversation", "submit"] {
            var observed: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source", "adapterFailureStructure": valid]
            XCTAssertEqual(D.remove(from: &observed, provider: "qwen", action: action) != nil, action == "inspect")
            XCTAssertEqual(Set(observed.keys), ["error", "detail"])
        }
        XCTAssertNil(D.sanitize(valid, provider: "deepseek", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertNil(D.sanitize(valid, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
    }

    func testQwenInlineDiagnosticAcceptsOnlyFixedCategoriesAndZeroCount() {
        for reason in ["escape", "bidi", "decorated", "other", "escape_json"] {
            var packet = qwenAuthoredFailure
            packet["stage"] = "inline"
            packet["reason"] = reason
            func accepts(_ value: [String: Any]) -> Bool {
                D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source") != nil
            }
            XCTAssertTrue(accepts(packet))
            for (key, value) in [("reason", "private_class" as Any), ("count", 1), ("text", "private_text")] {
                var invalid = packet
                invalid[key] = value
                XCTAssertFalse(accepts(invalid))
            }
        }
    }

    func testQwenLongParagraphDiagnosticRequiresSaturatedCountAndClosedPrefixCategory() {
        for reason in ["escape", "bidi", "decorated", "other", "ordinary_prefix", "PRIVATE", "escape_json"] {
            for count in [0, 1, 2] {
                var packet = qwenAuthoredFailure
                packet["stage"] = "span_limit"
                packet["reason"] = reason
                packet["count"] = count
                let result = D.sanitize(packet, provider: "qwen", error: "unsupported_response_format", detail: "authored_source")
                XCTAssertEqual(result != nil, count == 2 && !["PRIVATE", "escape_json"].contains(reason))
            }
        }
    }

    func testQwenPhaseSetDiagnosticIsFixedAndRequiresMultiplePhases() {
        for reason in ["multiple_text_bearing", "one_text_others_empty", "all_empty", "media", "hidden", "other_content", "over_limit", "PRIVATE"] {
            for count in [0, 1, 2] {
                var packet = qwenAuthoredFailure
                packet["stage"] = "phase_set"
                packet["reason"] = reason
                packet["count"] = count
                XCTAssertEqual(D.sanitize(packet, provider: "qwen", error: "unsupported_response_format", detail: "authored_source") != nil,
                               count == 2 && reason != "PRIVATE")
            }
        }
    }

    func testQwenAuthoredSourcePublicationRequiresExactNamedSelectionAndDedicatedSingleBoundArm() throws {
        let packet = try XCTUnwrap(D.sanitize(qwenAuthoredFailure, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        let max = "Qwen3.8-Max", plus = "Qwen3.7-Plus"
        let maxPurpose = "synthetic_qwen_max_authored_source_v1", plusPurpose = "synthetic_qwen_plus_authored_source_v1"
        let cases = [(max, maxPurpose, "matching"), (plus, plusPurpose, "matching"),
                     (plus, maxPurpose, "wrong_purpose"), (max, plusPurpose, "wrong_purpose"),
                     (plus, plusPurpose, "foreign_model")]
        let failures = ["no_arm", "historical_arm", "first_user_failure", "foreign_turn", "unverified_model",
                        "revoked_generation", "wrong_sequence"]
        for (label, purpose, scenario) in cases + failures.map({ (plus, plusPurpose, $0) })
            + failures.map({ (max, maxPurpose, $0) }) {
            let f = try WebsiteAdapterFailureFixture()
            defer { f.cleanup() }
            let a = f.admission
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            let context = try XCTUnwrap(D.Context(admission: WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID,
                taskID: a.taskID, threadID: a.threadID, turnID: a.turnID, runtimeGeneration: a.runtimeGeneration,
                preparationID: a.preparationID, transportGeneration: a.transportGeneration, provider: "qwen", modelID: choice.modelID,
                parameters: Data(), adapterFailureDirectory: f.directory)))
            var arm = f.arm()
            arm["provider"] = "qwen"; arm["modelID"] = choice.modelID
            if scenario != "historical_arm" { arm["purpose"] = purpose }
            if scenario == "foreign_model" {
                arm["modelID"] = WebsiteModelChoice(provider: "qwen", key: max, label: max).modelID
            }
            if scenario == "foreign_turn" { arm["turnID"] = UUID().uuidString.lowercased() }
            if scenario != "no_arm" { try f.writeArm(arm) }
            let binding = D.Binding(sessionToken: f.binding.sessionToken, documentGeneration: f.binding.documentGeneration,
                sequence: scenario == "wrong_sequence" ? 2 : 1, previousFirstBodyBound: false, priorModelSelectionVerified: scenario != "unverified_model")
            let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
            if scenario == "revoked_generation" { publication.revoke() }
            let firstUserFailure = scenario == "first_user_failure"
            let error = firstUserFailure ? "conversation_changed" : "unsupported_response_format"
            let detail = firstUserFailure ? "first_user_message" : "authored_source"
            let selectedPacket = firstUserFailure
                ? try XCTUnwrap(D.sanitize(WebsiteAdapterFailureFixture.packet("qwen"), provider: "qwen", error: error, detail: detail))
                : packet
            func publish() -> Bool {
                publication.publish(directory: f.directory, context: context, binding: binding, packet: selectedPacket, error: error, detail: detail)
            }
            XCTAssertEqual(publish(), scenario == "matching", scenario)
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.outputURL.path), scenario == "matching", scenario)
            guard scenario == "matching" else {
                XCTAssertEqual(FileManager.default.fileExists(atPath: f.armURL.path), scenario != "no_arm", scenario)
                continue
            }
            XCTAssertFalse(publish())
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.outputURL)) as? [String: Any])
            XCTAssertEqual(record["purpose"] as? String, purpose)
            XCTAssertEqual(record["documentGeneration"] as? String, binding.documentGeneration.uuidString.lowercased())
            XCTAssertEqual(record["inferenceID"] as? String, context.inferenceID.uuidString.lowercased())
            XCTAssertEqual(record["automaticReplay"] as? Bool, false)
            XCTAssertEqual(record["responseAuthorityGranted"] as? Bool, false)
            XCTAssertEqual(record["currentFirstBodyProofGranted"] as? Bool, false)
            let finite = try XCTUnwrap(record["structure"] as? [String: Any])
            XCTAssertEqual(finite as NSDictionary, qwenAuthoredFailure as NSDictionary)
        }
    }

    func testRemovalIsUnconditionalAndNeverAddsProof() throws {
        for action in ["inspect", "submit", "deleteConversation"] {
            let packets: [Any] = [WebsiteAdapterFailureFixture.packet(), ["text": "PRIVATE_BODY"]]
            for packet in packets {
                var observed: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source", "adapterFailureStructure": packet]
                _ = D.remove(from: &observed, provider: "deepseek", action: action)
                XCTAssertEqual(Set(observed.keys), ["error", "detail"])
                XCTAssertNil(observed["text"]); XCTAssertNil(observed["firstUserFingerprint"])
            }
        }
    }

    func testUnknownKeysTextLabelsIDsAndNonBooleanNumbersAreRejected() {
        for key in ["text", "html", "url", "id", "modelEvidence", "firstUserFingerprint"] {
            var value = WebsiteAdapterFailureFixture.packet(); value[key] = "PRIVATE_VALUE"
            XCTAssertNil(sanitize(value))
        }
        for key in ["nodeLimitReached", "knownChromePresent", "knownReasoningPresent"] {
            var value = WebsiteAdapterFailureFixture.packet(); value[key] = 1
            XCTAssertNil(sanitize(value), key)
        }
        let invalidCounts: [Any] = [true, -1, 257, 1.5, "1"]
        for bad in invalidCounts {
            var value = WebsiteAdapterFailureFixture.packet(); value["nodeCount"] = bad
            XCTAssertNil(sanitize(value))
        }
        var value = WebsiteAdapterFailureFixture.packet(); value["predicate"] = "PRIVATE_LABEL"
        XCTAssertNil(sanitize(value))
    }

    func testTreeRejectsUnknownValuesInvalidAncestryDepthAndReasoningTraversal() {
        let fields: [(String, Any)] = [("tag", "PRIVATE_TAG"), ("category", "PRIVATE_CLASS"), ("parent", 0),
            ("depth", 1), ("visible", 1), ("elementChildCount", 258), ("unknownClassPresent", "false")]
        for (key, bad) in fields {
            var node = WebsiteAdapterFailureFixture.node(); node[key] = bad
            var value = WebsiteAdapterFailureFixture.packet(); value["tree"] = [node]
            XCTAssertNil(sanitize(value), key)
        }
        var first = WebsiteAdapterFailureFixture.node(); first["reasoningExcluded"] = true
        var second = WebsiteAdapterFailureFixture.node(); second["parent"] = 0; second["depth"] = 1
        var value = WebsiteAdapterFailureFixture.packet(); value["tree"] = [first, second]; value["nodeCount"] = 2
        XCTAssertNil(sanitize(value))
        first["reasoningExcluded"] = false; value["tree"] = [first, second]
        XCTAssertNotNil(sanitize(value))
        second["depth"] = 17; value["tree"] = [first, second]; XCTAssertNil(sanitize(value))
        value["tree"] = Array(repeating: first, count: 257); value["nodeCount"] = 257; XCTAssertNil(sanitize(value))
    }

    func testOverflowAndCandidatesAreBounded() {
        var value = WebsiteAdapterFailureFixture.packet("kimi")
        value["markdownCount"] = 32; value["markdownCountOverflow"] = true
        XCTAssertNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source_markdown_count"))
        value["markdownCount"] = 33
        XCTAssertNotNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source_markdown_count"))
        let candidate: [String: Any] = ["excludedReasoning": false, "visible": true, "ancestry": ["markdown", "content_box"], "ancestryTruncated": false]
        value["markdownCandidates"] = Array(repeating: candidate, count: 17)
        XCTAssertNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source_markdown_count"))
    }

    func testQwenComparisonCannotSmuggleTextOrClaimEqualityOrOverlap() {
        var packet = WebsiteAdapterFailureFixture.packet("qwen")
        var comparison = packet["comparison"] as! [String: Any]
        for (key, bad) in [("actualText", "PRIVATE_BODY" as Any), ("exactEqual", true), ("commonSuffixLength", 20)] {
            var altered = comparison; altered[key] = bad; packet["comparison"] = altered
            XCTAssertNil(D.sanitize(packet, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
        }
        comparison["comparisonComplete"] = false; comparison["actualUTF8Length"] = 540_601; comparison["expectedUTF8Length"] = 540_601
        comparison["commonPrefixLength"] = 0; comparison["mismatchCategory"] = "other"
        packet["comparison"] = comparison
        XCTAssertNotNil(D.sanitize(packet, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
        comparison["nfcEqual"] = true; packet["comparison"] = comparison
        XCTAssertNil(D.sanitize(packet, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
    }

    func testArmRequiresEveryExactIdentityAndRejectsUnknownDuplicateMalformedFields() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNotNil(D.validateArm(try f.armData(now: now), context: f.context, now: now))
        for key in ["taskID", "threadID", "turnID", "modelID", "provider", "purpose", "nonce"] {
            var value = f.arm(now: now); value[key] = "different"
            XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now), key)
        }
        var value = f.arm(now: now); value["schemaVersion"] = true
        XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now))
        value = f.arm(now: now); value["response"] = "PRIVATE_BODY"
        XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now))
        let duplicate = String(String(data: try f.armData(now: now), encoding: .utf8)!.dropLast()) + ",\"schemaVersion\":1}"
        XCTAssertNil(D.validateArm(Data(duplicate.utf8), context: f.context, now: now))
        for delta in [-1.0, 0.0, 601.0] {
            value = f.arm(now: now); value["expiresAt"] = D.formatter().string(from: now.addingTimeInterval(delta))
            XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now))
        }
    }

    func testContextRejectsForeignProviderInvalidModelAndNonCanonicalIDs() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        for field in ["provider", "model", "task"] {
            let a = f.admission
            let changed = WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID,
                taskID: field == "task" ? a.taskID.uppercased() : a.taskID, threadID: a.threadID, turnID: a.turnID,
                runtimeGeneration: a.runtimeGeneration, preparationID: a.preparationID, transportGeneration: a.transportGeneration,
                provider: field == "provider" ? "claude" : a.provider, modelID: field == "model" ? "not-a-model" : a.modelID, parameters: a.parameters)
            XCTAssertNil(D.Context(admission: changed))
        }
    }

    func testOneShotRecordUsesNativeSecondInferenceIdentityAndNoSourceValues() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        try f.writeArm()
        let second = f.admission(inferenceID: UUID())
        let context = try XCTUnwrap(D.Context(admission: second))
        let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
        XCTAssertTrue(publication.publish(directory: f.directory, context: context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.armURL.path))
        XCTAssertFalse(publication.publish(directory: f.directory, context: context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
        let bytes = try Data(contentsOf: f.outputURL)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(value["taskID"] as? String, f.context.taskID.uuidString.lowercased())
        XCTAssertEqual(value["inferenceID"] as? String, second.inferenceID.uuidString.lowercased())
        XCTAssertEqual(value["responseAuthorityGranted"] as? Bool, false)
        XCTAssertEqual(value["currentFirstBodyProofGranted"] as? Bool, false)
        XCTAssertEqual(value["submissionAcknowledged"] as? Bool, true)
        XCTAssertNil(value["text"]); XCTAssertNil(value["html"]); XCTAssertNil(value["url"])
        let mode = try FileManager.default.attributesOfItem(atPath: f.outputURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAbsentWrongArmRevokedAndExpiredPublicationLeaveNoRecord() throws {
        for scenario in ["absent", "wrong", "revoked", "expired"] {
            let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
            if scenario != "absent" {
                var arm = f.arm(); if scenario == "wrong" { arm["taskID"] = UUID().uuidString.lowercased() }
                try f.writeArm(arm)
            }
            let publication = WebsiteAdapterFailurePublication(deadline: .now + (scenario == "expired" ? .seconds(-1) : .seconds(5)))
            if scenario == "revoked" { publication.revoke() }
            XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path))
            if scenario != "absent" { XCTAssertTrue(FileManager.default.fileExists(atPath: f.armURL.path)) }
        }
    }

    func testRevocationImmediatelyBeforeCommitPreventsLateRecord() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }; try f.writeArm()
        let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
        XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source", beforeCommit: { publication.revoke() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.armURL.path))
    }

    func testRacedArmReplacementCannotAuthorizePublicationAndIsPreserved() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }; try f.writeArm()
        let armURL = f.armURL, moved = f.directory.appendingPathComponent("original-arm.json")
        var replacement = f.arm(); replacement["taskID"] = UUID().uuidString.lowercased()
        let bytes = try JSONSerialization.data(withJSONObject: replacement)
        let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
        XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source", beforeArmClaim: {
            try? FileManager.default.moveItem(at: armURL, to: moved)
            try? bytes.write(to: armURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armURL.path)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path))
        XCTAssertEqual(try Data(contentsOf: f.armURL), bytes)
    }

    func testPrivateModesSymlinksAndExistingOutputAreNotRepairedOrOverwritten() throws {
        for scenario in ["directory_mode", "arm_mode", "symlink", "existing"] {
            let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }; try f.writeArm()
            if scenario == "directory_mode" { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path) }
            if scenario == "arm_mode" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.armURL.path) }
            if scenario == "symlink" {
                let original = f.directory.appendingPathComponent("original.json")
                try FileManager.default.moveItem(at: f.armURL, to: original)
                try FileManager.default.createSymbolicLink(at: f.armURL, withDestinationURL: original)
            }
            if scenario == "existing" { try Data("preserve".utf8).write(to: f.outputURL) }
            let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
            XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
            if scenario == "existing" { XCTAssertEqual(try Data(contentsOf: f.outputURL), Data("preserve".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path)) }
        }
    }

    private func sanitize(_ value: [String: Any]) -> D.Packet? {
        D.sanitize(value, provider: "deepseek", error: "unsupported_response_format", detail: "authored_source")
    }
}

/// Shared with the synthetic WebKit transport check; never opens a provider.
struct WebsiteAdapterFailureFixture {
    let directory: URL
    let admission: WebModelStartAdmission
    let context: WebsiteAdapterFailureDiagnostic.Context
    let binding = WebsiteAdapterFailureDiagnostic.Binding(sessionToken: UUID(), documentGeneration: UUID(), sequence: 1, previousFirstBodyBound: false, priorModelSelectionVerified: true)
    var armURL: URL { directory.appendingPathComponent("arm.json") }
    var outputURL: URL { directory.appendingPathComponent("adapter-failure-structure.json") }
    init() throws {
        directory = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("adapter-structure-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let choice = WebsiteModeChoice(deepSeekMode: .chat)
        admission = WebModelStartAdmission(id: UUID(), inferenceID: UUID(), taskID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(), turnID: UUID().uuidString.lowercased(), runtimeGeneration: UUID(), preparationID: UUID(), transportGeneration: UUID(), provider: "deepseek", modelID: choice.requestID,
            parameters: try JSONSerialization.data(withJSONObject: ["provider": "deepseek", "modeChoice": choice.canonicalJSONString]), adapterFailureDirectory: directory)
        context = try XCTUnwrap(WebsiteAdapterFailureDiagnostic.Context(admission: admission))
    }
    func admission(inferenceID: UUID) -> WebModelStartAdmission {
        WebModelStartAdmission(id: UUID(), inferenceID: inferenceID, taskID: admission.taskID, threadID: admission.threadID, turnID: admission.turnID, runtimeGeneration: admission.runtimeGeneration, preparationID: admission.preparationID, transportGeneration: admission.transportGeneration, provider: admission.provider, modelID: admission.modelID, parameters: admission.parameters, adapterFailureDirectory: directory)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func arm(now: Date = Date()) -> [String: Any] {
        ["schemaVersion": 1, "purpose": WebsiteAdapterFailureDiagnostic.purpose, "nonce": UUID().uuidString.lowercased(),
         "taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(), "turnID": context.turnID.uuidString.lowercased(), "provider": context.provider, "modelID": context.modelID,
         "expiresAt": WebsiteAdapterFailureDiagnostic.formatter().string(from: now.addingTimeInterval(120))]
    }
    func armData(now: Date) throws -> Data { try JSONSerialization.data(withJSONObject: arm(now: now), options: .sortedKeys) }
    func writeArm(_ value: [String: Any]? = nil) throws {
        try JSONSerialization.data(withJSONObject: value ?? arm(), options: .sortedKeys).write(to: armURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armURL.path)
    }
    func safePacket() throws -> WebsiteAdapterFailureDiagnostic.Packet {
        try XCTUnwrap(WebsiteAdapterFailureDiagnostic.sanitize(Self.packet(), provider: "deepseek", error: "unsupported_response_format", detail: "authored_source"))
    }
    static func node(category: String = "final") -> [String: Any] {
        ["parent": -1, "depth": 0, "tag": "div", "category": category, "unknownClassPresent": false, "visible": true, "interactive": false, "elementChildCount": 0, "childCountOverflow": false, "reasoningExcluded": false]
    }
    static func packet(_ provider: String = "deepseek") -> [String: Any] {
        var value: [String: Any] = ["version": 1, "provider": provider, "nodeLimitReached": false, "nodeCount": 1]
        if provider == "kimi" {
            value.merge(["trigger": "authored_source_markdown_count", "tree": [node(category: "content_box")], "markdownCount": 0, "markdownCountOverflow": false, "excludedReasoningCount": 0, "excludedReasoningCountOverflow": false, "answerVisible": true, "boxVisible": true, "markdownCandidates": []] as [String: Any]) { _, new in new }
        } else if provider == "qwen" {
            value.merge(["trigger": "full_prompt_mismatch", "tree": [node(category: "user_container")], "directParagraphCount": 1, "visibleDirectParagraphCount": 1, "descendantParagraphCount": 1, "visibleDescendantParagraphCount": 1, "paragraphCountOverflow": false, "paragraphs": [],
                "comparison": ["comparisonComplete": true, "actualUTF16Length": 10, "expectedUTF16Length": 12, "actualUTF8Length": 10, "expectedUTF8Length": 12, "commonPrefixLength": 4, "commonSuffixLength": 0, "exactEqual": false, "lfDelta": 0, "crDelta": 0, "nbspDelta": 0, "nfcEqual": false, "crlfEqual": false, "trimEqual": false, "mismatchCategory": "internal"]] as [String: Any]) { _, new in new }
        } else {
            value.merge(["trigger": "authored_source", "tree": [node()], "predicate": "paragraph_shape", "finalCount": 1, "finalCountOverflow": false, "knownReasoningPresent": false, "knownReasoningExcluded": false, "knownChromePresent": false, "knownChromeTextExcluded": true] as [String: Any]) { _, new in new }
        }
        return value
    }
}
