import Foundation
import XCTest
@testable import Computa

final class EmbeddedSubmissionOwnershipTests: XCTestCase {
    @MainActor
    func testSubmissionProofBindsTheExactRoundAndOutboundBody() {
        let first = EmbeddedWebModelTransport.outboundFingerprint("first\n\nComputa session marker: first")
        let second = EmbeddedWebModelTransport.outboundFingerprint("tool result\n\nComputa session marker: second")
        XCTAssertTrue(EmbeddedWebModelTransport.validSubmissionProof(["sequence": 2, "fingerprint": second], sequence: 2, fingerprint: second))
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(["sequence": 1, "fingerprint": first], sequence: 2, fingerprint: second))
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(["sequence": 2, "fingerprint": first], sequence: 2, fingerprint: second))
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(["sequence": 2, "fingerprint": second], sequence: 1, fingerprint: second))
    }

    @MainActor
    func testMalformedProofCannotSupplyCountsOrPrivateFields() {
        let fingerprint = String(repeating: "a", count: 64)
        let invalid: [Any] = [
            ["sequence": true, "fingerprint": fingerprint],
            ["sequence": 1.5, "fingerprint": fingerprint],
            ["sequence": "1", "fingerprint": fingerprint],
            ["sequence": 0, "fingerprint": fingerprint],
            ["sequence": 10_001, "fingerprint": fingerprint],
            ["sequence": 1, "fingerprint": fingerprint, "text": "private canary"],
            ["sequence": 1, "fingerprint": fingerprint.uppercased()],
            ["sequence": 1, "fingerprint": String(repeating: "z", count: 64)],
            ["sequence": 1, "fingerprint": ""],
            ["sequence": 1], NSNull(), [], "private canary",
        ]
        for value in invalid {
            XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(value, sequence: 1, fingerprint: fingerprint))
        }
    }

    @MainActor
    func testOutboundDigestUsesTheExistingECMAScriptNormalization() {
        let expected = "6d1cd254e0906da4d81d18113301c16b5b548e0af8faca9e9c428e5f75ccd014"
        XCTAssertEqual(EmbeddedWebModelTransport.outboundFingerprint("\u{FEFF}e\u{301}\r\nComputa session marker: example\u{00A0}"), expected)
        XCTAssertEqual(EmbeddedWebModelTransport.outboundFingerprint("é\nComputa session marker: example"), expected)
        XCTAssertNotEqual(EmbeddedWebModelTransport.outboundFingerprint("\u{0085}é\nComputa session marker: example"), expected,
                          "ECMAScript trim does not trim U+0085")
        XCTAssertNotEqual(EmbeddedWebModelTransport.outboundFingerprint("é\nComputa session marker: other"), expected)
    }

    @MainActor
    func testOriginalPromptDigestDoesNotNormalizeModelInput() {
        XCTAssertNotEqual(EmbeddedWebModelTransport.promptFingerprint("e\u{301}"), EmbeddedWebModelTransport.promptFingerprint("é"))
        XCTAssertNotEqual(EmbeddedWebModelTransport.promptFingerprint("raw\r\n"), EmbeddedWebModelTransport.promptFingerprint("raw\n"))
        XCTAssertNotEqual(EmbeddedWebModelTransport.promptFingerprint("value-1"), EmbeddedWebModelTransport.promptFingerprint("value‑1"))
    }

    @MainActor
    func testSubmissionDiagnosticsRejectPrivateValuesAndUnboundedMetadata() throws {
        let valid: [String: Any] = ["kind": "gemini_submission_v1", "stage": "begin_digest", "action": "insert",
            "phase": "insert_claimed", "requestedSequence": 1, "recordSequence": 1, "userCount": 0,
            "statePresent": true, "recordPresent": true, "stateRevoked": true, "ownerMatches": true,
            "documentMatches": true, "nonceMatches": true, "canonicalMatches": true, "suffixMatches": true,
            "contextMatches": false]
        let encoded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(valid))
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(roundTrip["stage"] as? String, "begin_digest")
        XCTAssertEqual(roundTrip["contextMatches"] as? Bool, false)
        XCTAssertLessThanOrEqual(encoded.utf8.count, 2_048)
        for (key, invalid) in [("stage", "PRIVATE CANARY"), ("action", "PRIVATE CANARY"), ("phase", "PRIVATE CANARY"),
                               ("ownerMatches", "PRIVATE CANARY"), ("userCount", "PRIVATE CANARY")] {
            var altered = valid; altered[key] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(altered))
        }
        for key in ["prompt", "nonce", "fingerprint", "url", "private"] {
            var altered = valid; altered[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(altered))
        }
        let invalidCounts: [Any] = [true, -1, 10_001, 1.5, "1"]
        for key in ["requestedSequence", "recordSequence", "userCount"] {
            for invalid in invalidCounts {
                var altered = valid; altered[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(altered))
            }
        }
        var missing = valid; missing.removeValue(forKey: "ownerMatches")
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(missing))
        var nullable = valid; nullable["requestedSequence"] = NSNull(); nullable["recordSequence"] = NSNull()
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(nullable))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDiagnostic(NSNull()))
    }

    @MainActor
    func testSubmissionBodyMeasurementsCannotPublishTextOrGainProofAuthority() throws {
        let valid: [String: Any] = ["kind": "gemini_submission_body_v1", "expectedLength": 67, "innerTextLength": 68,
            "textContentLength": 67, "expectedLines": 2, "innerTextLines": 3, "textContentLines": 2,
            "firstMismatchIndex": 5, "actualCategory": "linefeed", "expectedCategory": "space",
            "innerTextMatches": false, "textContentMatches": true, "literalDOMAvailable": true,
            "literalDOMMatches": true, "literalDOMLength": 67, "literalDOMUnavailableReason": "none",
            "nodeCount": 4, "maximumDepth": 1, "paragraphCount": 0, "brCount": 1, "textNodeCount": 2,
            "spanCount": 0, "bodyChildElements": 1]
        let encoded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(valid))
        XCTAssertLessThanOrEqual(encoded.utf8.count, 2_048)
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(projected["innerTextMatches"] as? Bool, false)
        XCTAssertEqual(projected["literalDOMMatches"] as? Bool, true)
        for key in ["text", "prompt", "marker", "fingerprint", "url"] {
            var altered = valid; altered[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(altered))
        }
        for key in ["actualCategory", "expectedCategory", "literalDOMUnavailableReason"] {
            var altered = valid; altered[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(altered))
        }
        let invalidMeasurements: [Any] = [true, -1, 180_202, 1.5, "1", NSNull()]
        for invalid in invalidMeasurements {
            var altered = valid; altered["innerTextLength"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(altered))
        }
        var unavailableMatch = valid; unavailableMatch["literalDOMAvailable"] = false
        unavailableMatch["literalDOMUnavailableReason"] = "hidden"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(unavailableMatch))
        var unknownCount = valid; unknownCount["nodeCount"] = 8_194
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(unknownCount))
        var unknownDepth = valid; unknownDepth["maximumDepth"] = 66
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(unknownDepth))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(NSNull()))
    }
}
