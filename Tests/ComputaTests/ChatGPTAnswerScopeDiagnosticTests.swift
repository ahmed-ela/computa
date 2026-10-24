import Foundation
import XCTest
@testable import Computa

@MainActor
final class ChatGPTAnswerScopeDiagnosticTests: XCTestCase {
    private var valid: [String: Any] {
        ["kind": "chatgpt_answer_scope_v1", "rootPresent": true, "bodyPresent": true,
         "rootTextLength": 48, "bodyTextLength": 0, "rootChildren": 2, "bodyChildren": 0]
    }

    func testAnswerScopeProjectionPreservesOnlyExactFiniteMeasurements() throws {
        let encoded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(valid))
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(Set(projected.keys), Set(valid.keys))
        XCTAssertEqual(projected["kind"] as? String, "chatgpt_answer_scope_v1")
        XCTAssertEqual(projected["rootPresent"] as? Bool, true)
        XCTAssertEqual(projected["bodyPresent"] as? Bool, true)
        XCTAssertEqual(projected["rootTextLength"] as? Int, 48)
        XCTAssertEqual(projected["bodyTextLength"] as? Int, 0)
        XCTAssertEqual(projected["rootChildren"] as? Int, 2)
        XCTAssertEqual(projected["bodyChildren"] as? Int, 0)
        XCTAssertLessThanOrEqual(encoded.utf8.count, 512)
        XCTAssertEqual(encoded, EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(valid))
    }

    func testAnswerScopeBoundsAndAbsentElementsRemainFiniteFacts() throws {
        for present in [false, true] {
            for textLength in [0, 220_000, 220_001] {
                for children in [0, 1_000] {
                    let payload: [String: Any] = ["kind": "chatgpt_answer_scope_v1",
                        "rootPresent": present, "bodyPresent": present,
                        "rootTextLength": textLength, "bodyTextLength": textLength,
                        "rootChildren": children, "bodyChildren": children]
                    let encoded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(payload))
                    let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
                    XCTAssertEqual(projected["rootTextLength"] as? Int, textLength)
                    XCTAssertEqual(projected["bodyChildren"] as? Int, children)
                    XCTAssertEqual(projected["rootPresent"] as? Bool, present)
                    XCTAssertLessThanOrEqual(encoded.utf8.count, 512)
                }
            }
        }
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(nil))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(NSNull()))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic([]))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(missing), key)
        }
    }

    func testAnswerScopeRejectsCoercionNonfiniteFractionalAndOutOfRangeScalars() {
        for key in ["rootTextLength", "bodyTextLength", "rootChildren", "bodyChildren"] {
            let maximum = key.hasSuffix("Children") ? 1_000 : 220_001
            for raw: Any in [true, false, -1, maximum + 1, 0.5, Double.infinity, -Double.infinity,
                             Double.nan, "0", NSNull(), ["value": 1], [0]] {
                var bad = valid; bad[key] = raw
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(bad), key)
            }
        }
        for key in ["rootPresent", "bodyPresent"] {
            for raw: Any in [0, 1, "true", "false", NSNull(), [], ["value": true]] {
                var bad = valid; bad[key] = raw
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(bad), key)
            }
        }
        for raw: Any in ["chatgpt_answer_scope_v2", "PRIVATE_KIND", 1, true, NSNull()] {
            var bad = valid; bad["kind"] = raw
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(bad))
        }
    }

    func testAnswerScopeRejectsPrivateKeysAndDoesNotChangeExistingProgressProjection() throws {
        for key in ["text", "url", "className", "ownerToken", "prompt", "rootHTML", "nested"] {
            var bad = valid
            bad[key] = ["PRIVATE_CANARY": "https://private.invalid/?secret=PRIVATE_CANARY"]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(bad), key)
        }
        var replacedScalar = valid; replacedScalar["bodyTextLength"] = "PRIVATE_BODY_CANARY"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedAnswerScopeDiagnostic(replacedScalar))
        let observation: [String: Any] = ["responseCount": 1, "userCount": 1, "busy": false,
            "answerComplete": true, "responseLoadFailed": false, "text": "",
            "answerScopeDiagnostic": ["PRIVATE_CANARY": "PRIVATE_CONTENT"]]
        let progress = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(observation))
        XCTAssertNil(progress["answerScopeDiagnostic"])
        XCTAssertEqual(progress["answerComplete"] as? Bool, true)
        XCTAssertEqual(progress["textBytes"] as? Int, 0)
        let encoded = try JSONSerialization.data(withJSONObject: progress, options: .sortedKeys)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE"))
        XCTAssertLessThanOrEqual(encoded.count, 768)
    }
}
