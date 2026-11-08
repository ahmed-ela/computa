import Foundation
import XCTest
@testable import Computa

final class KimiComposerGuardDiagnosticTests: XCTestCase {
    private typealias D = WebsiteAdapterFailureDiagnostic
    private var value: [String: Any] {
        ["version": 1, "provider": "kimi", "trigger": "composer_not_empty", "stage": "initial_inspect",
         "serializedClass": "whitespace_only", "childCountCapped32": 4, "paragraphCountCapped32": 2,
         "brCountCapped32": 2, "unsupportedShapeCountCapped32": 0]
    }
    func testFinitePacketIsStrippedBeforeTheUnchangedPrimaryRejection() throws {
        for kind in ["empty", "whitespace_only", "nonwhitespace"] {
            var metadata = value; metadata["serializedClass"] = kind
            var observed: [String: Any] = ["error": "composer_not_empty", "composerGuardDiagnostic": metadata]
            let packet = try XCTUnwrap(D.removeComposerGuard(from: &observed, provider: "kimi", action: "inspect"))
            XCTAssertEqual(observed as NSDictionary, ["error": "composer_not_empty"] as NSDictionary)
            XCTAssertLessThanOrEqual(packet.data.count, 512)
        }
    }
    func testContentUnknownKeysInvalidCountsAndForeignErrorsAreDiagnosticOnly() {
        for (key, replacement) in [("draft", "PRIVATE_DRAFT" as Any), ("serializedClass", "PRIVATE_CLASS"),
                                   ("childCountCapped32", true), ("childCountCapped32", -1),
                                   ("childCountCapped32", 33), ("childCountCapped32", 1.5),
                                   ("paragraphCountCapped32", "2"), ("brCountCapped32", 3),
                                   ("version", false), ("provider", "qwen"), ("stage", "prepare")] {
            var raw = value; raw[key] = replacement
            XCTAssertNil(D.sanitizeComposerGuard(raw), key)
        }
        for (provider, action, primary) in [("qwen", "inspect", ["error": "composer_not_empty"]),
                                            ("kimi", "prepare", ["error": "composer_not_empty"]),
                                            ("kimi", "inspect", ["error": "composer_unavailable"]),
                                            ("kimi", "inspect", ["error": "composer_not_empty", "detail": "other"]),
                                            ("kimi", "inspect", ["composer": "true"])] {
            var observed: [String: Any] = primary; observed["composerGuardDiagnostic"] = value
            XCTAssertNil(D.removeComposerGuard(from: &observed, provider: provider, action: action))
            XCTAssertEqual(observed as NSDictionary, primary as NSDictionary)
        }
    }
    func testMissingNativeAttributionIsExplicitNullAndCannotBePIDOnlyCause() throws {
        let packet = try XCTUnwrap(D.sanitizeComposerGuard(value)), token = UUID(), generation = UUID()
        let text = try XCTUnwrap(D.composerGuardLog(packet, context: nil, sessionToken: token, documentGeneration: generation, sequence: 0))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertTrue(record["attribution"] is NSNull)
        XCTAssertEqual(record["sessionToken"] as? String, token.uuidString.lowercased())
        XCTAssertEqual(record["documentGeneration"] as? String, generation.uuidString.lowercased())
        XCTAssertEqual(record["diagnosticOnly"] as? Bool, true)
        XCTAssertNil(record["pid"]); XCTAssertNil(record["taskID"])
        XCTAssertLessThanOrEqual(text.utf8.count, 1_536)
        XCTAssertNil(D.composerGuardLog(packet, context: nil, sessionToken: token, documentGeneration: generation, sequence: 1))
    }
    func testAttributionUsesExistingNativeContextAndStillGrantsNoObservationProof() throws {
        let model = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant").modelID
        let admission = WebModelStartAdmission(id: UUID(), inferenceID: UUID(), taskID: UUID().uuidString.lowercased(),
            threadID: UUID().uuidString.lowercased(), turnID: UUID().uuidString.lowercased(), runtimeGeneration: UUID(),
            preparationID: UUID(), transportGeneration: UUID(), provider: "kimi", modelID: model, parameters: Data(), adapterFailureDirectory: nil)
        let context = try XCTUnwrap(D.Context(admission: admission)), packet = try XCTUnwrap(D.sanitizeComposerGuard(value))
        let text = try XCTUnwrap(D.composerGuardLog(packet, context: context, sessionToken: UUID(), documentGeneration: UUID(), sequence: 0))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let joined = try XCTUnwrap(record["attribution"] as? [String: String])
        XCTAssertEqual(joined["taskID"], admission.taskID)
        XCTAssertEqual(joined["threadID"], admission.threadID)
        XCTAssertEqual(joined["turnID"], admission.turnID)
        XCTAssertEqual(joined["inferenceID"], admission.inferenceID.uuidString.lowercased())
        XCTAssertEqual(Set(record.keys), ["version", "diagnosticOnly", "attribution", "sessionToken", "documentGeneration", "sequence", "metadata"])
        XCTAssertNil(record["modelEvidence"]); XCTAssertNil(record["cleanup"]); XCTAssertNil(record["authority"])
    }
}
