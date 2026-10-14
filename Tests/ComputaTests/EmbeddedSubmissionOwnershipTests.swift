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
    func testSubmissionDigestDiagnosticsPreserveFailureFactsWithoutProofOrPrivateData() throws {
        let flags = ["stateSame", "stateRevoked", "recordRetained", "parentRequired", "parentIntact",
                     "remountRequired", "remountIntact", "contextMatches", "rootCountMatches", "rootsSame",
                     "firstRootSame", "currentRootSame", "rootConnected", "bodyConnected", "bodySame",
                     "payloadAvailable", "payloadWithinLimit", "bodyTextUnchanged", "bodyCanonicalMatches",
                     "priorIntact", "digestMatches"]
        var valid: [String: Any] = Dictionary(uniqueKeysWithValues: flags.map { ($0, true as Any) })
        valid["kind"] = "gemini_submission_digest_v1"; valid["projectedLength"] = 57_495
        valid["stateRevoked"] = false; valid["parentRequired"] = false; valid["remountRequired"] = false
        valid["bodyTextUnchanged"] = false; valid["bodyCanonicalMatches"] = false
        let encoded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(valid))
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(projected["stateRevoked"] as? Bool, false, "The diagnostic precedes the failure latch")
        XCTAssertEqual(projected["bodyTextUnchanged"] as? Bool, false)
        XCTAssertEqual(projected["rootConnected"] as? Bool, true)
        XCTAssertLessThanOrEqual(encoded.utf8.count, 960)
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(projected, sequence: 3, fingerprint: String(repeating: "a", count: 64)))
        let invalidFlags: [Any] = [1, "true", NSNull(), "PRIVATE CANARY"]
        for key in flags {
            for bad in invalidFlags {
                var changed = valid; changed[key] = bad
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(changed), key)
            }
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(missing), key)
        }
        let invalidLengths: [Any] = [true, -1, 180_202, 1.5, "1", NSNull()]
        for bad in invalidLengths {
            var changed = valid; changed["projectedLength"] = bad
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(changed))
        }
        for key in ["prompt", "nonce", "fingerprint", "url", "text"] {
            var changed = valid; changed[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(changed))
        }
        var wrongKind = valid; wrongKind["kind"] = "PRIVATE CANARY"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(wrongKind))
        for key in ["parentIntact", "remountIntact"] {
            var changed = valid; changed[key] = false
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(changed))
        }
        var unavailable = valid
        unavailable["payloadAvailable"] = false; unavailable["payloadWithinLimit"] = false; unavailable["projectedLength"] = 0
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(unavailable))
        unavailable["bodyCanonicalMatches"] = true
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(unavailable))
        var oversized = valid; oversized["payloadWithinLimit"] = false; oversized["projectedLength"] = 180_201
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(oversized))
        oversized["payloadWithinLimit"] = true
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(oversized))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionDigestDiagnostic(NSNull()))
    }

    @MainActor
    func testRetainedFirstSubmissionFailureLogsOriginalDigestAcrossRevokedReadWithoutPrivateData() throws {
        let flags = ["stateSame", "stateRevoked", "recordRetained", "parentRequired", "parentIntact",
                     "remountRequired", "remountIntact", "contextMatches", "rootCountMatches", "rootsSame",
                     "firstRootSame", "currentRootSame", "rootConnected", "bodyConnected", "bodySame",
                     "payloadAvailable", "payloadWithinLimit", "bodyTextUnchanged", "bodyCanonicalMatches",
                     "priorIntact", "digestMatches"]
        var digest: [String: Any] = Dictionary(uniqueKeysWithValues: flags.map { ($0, true as Any) })
        digest["kind"] = "gemini_submission_digest_v1"; digest["projectedLength"] = 51_758
        for key in ["stateRevoked", "parentRequired", "remountRequired", "rootsSame", "firstRootSame",
                    "currentRootSame", "rootConnected", "bodyConnected"] { digest[key] = false }
        let first: [String: Any] = ["firstFailureKind": "gemini_submission_first_failure_v1",
            "stage": "observe_digest", "action": "inspect", "sequence": 1, "digestDiagnostic": digest]
        let current: [String: Any] = ["kind": "gemini_submission_v1", "stage": "observe_state", "action": "inspect",
            "phase": "verified", "requestedSequence": 1, "recordSequence": 1, "userCount": 1,
            "statePresent": true, "recordPresent": true, "stateRevoked": true, "ownerMatches": true,
            "documentMatches": true, "nonceMatches": true, "canonicalMatches": false, "suffixMatches": true,
            "contextMatches": true]
        let records = try XCTUnwrap(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(first, current: current))
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertLessThanOrEqual(record.utf8.count, 960)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])
            XCTAssertEqual(value["firstFailureKind"] as? String, "gemini_submission_first_failure_v1")
            XCTAssertEqual(value["stage"] as? String, "observe_digest")
            XCTAssertEqual(value["sequence"] as? Int, 1)
            XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(value, sequence: 1, fingerprint: String(repeating: "a", count: 64)))
            for forbidden in ["nonce", "fingerprint", "url", "prompt", "PRIVATE"] { XCTAssertFalse(record.contains(forbidden)) }
        }
        let retained = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
        XCTAssertEqual(retained["stateRevoked"] as? Bool, false)
        XCTAssertEqual(retained["rootsSame"] as? Bool, false)
        XCTAssertEqual(retained["digestMatches"] as? Bool, true)
        for key in first.keys {
            var missing = first; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(missing, current: current))
            var privateValue = first; privateValue[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(privateValue, current: current))
        }
        for key in ["prompt", "url", "nonce", "fingerprint"] {
            var extra = first; extra[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(extra, current: current))
            var nested = digest; nested[key] = "PRIVATE CANARY"
            var invalid = first; invalid["digestDiagnostic"] = nested
            XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(invalid, current: current))
        }
        for bad in [true, -1, 0, 10_001, 1.5, "1"] as [Any] {
            var invalid = first; invalid["sequence"] = bad
            XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(invalid, current: current))
        }
        for key in ["requestedSequence", "recordSequence"] {
            var foreign = current; foreign[key] = 2
            XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(first, current: foreign))
        }
        var wrongStage = first; wrongStage["stage"] = "observe_body"
        XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(wrongStage, current: current))
        wrongStage["digestDiagnostic"] = NSNull()
        XCTAssertEqual(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(wrongStage, current: current)?.count, 1)
        var invalidDigest = digest; invalidDigest["stateRevoked"] = 1
        var invalid = first; invalid["digestDiagnostic"] = invalidDigest
        XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(invalid, current: current))
        XCTAssertNil(EmbeddedWebModelTransport.submissionFirstFailureDiagnosticRecords(first, current: NSNull()))
    }

    @MainActor
    func testSubmissionBodyMeasurementsCannotPublishTextOrGainProofAuthority() throws {
        let valid: [String: Any] = ["kind": "gemini_submission_body_v1", "expectedLength": 67, "innerTextLength": 68,
            "textContentLength": 67, "expectedLines": 2, "innerTextLines": 3, "textContentLines": 2,
            "firstMismatchIndex": 5, "actualCategory": "linefeed", "expectedCategory": "space",
            "innerTextMatches": false, "textContentMatches": true, "literalDOMAvailable": true,
            "innerTextContainsExpected": false, "textContentContainsExpected": true,
            "innerTextExpectedOffset": 180_201, "textContentExpectedOffset": 0,
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
        var contradictory = valid; contradictory["innerTextExpectedOffset"] = 1
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(contradictory))
        contradictory = valid; contradictory["textContentExpectedOffset"] = 180_201
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(contradictory))
        contradictory = valid; contradictory["textContentExpectedOffset"] = 1
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionBodyDiagnostic(contradictory))
    }

    @MainActor
    func testSubmissionStructureCanLocateExactBodyWithoutPublishingPrivateValues() throws {
        let privateValue = "private-canary"
        let shape: [String: Any] = ["tag": "span", "classes": ["ng-star-inserted", privateValue]]
        let child: [String: Any] = ["tag": privateValue, "classes": [privateValue], "path": [0],
            "childElements": 0, "controls": 0, "textLength": 42, "markerExact": false,
            "markerContained": true, "visible": true, "editable": false,
            "outboundInnerTextMatches": true, "outboundTextContentMatches": false]
        let diagnostic: [String: Any] = ["kind": "first_user_structure", "provider": "gemini", "reason": "submission_text",
            "descendantScope": "selected_body",
            "root": shape, "body": shape, "userCount": 1, "textLength": 42, "lineCount": 2,
            "markerOccurrences": 1, "controlDescendants": 0, "markerFinalLine": true,
            "submitted": true, "markerMatches": true, "descendants": [child], "text": privateValue]
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(diagnostic), provider: .gemini, expectedReason: "submission_text"))
        XCTAssertFalse(records.joined().contains(privateValue))
        XCTAssertTrue(records.joined().contains("\"outboundInnerTextMatches\":true"))
        XCTAssertTrue(records.joined().contains("\"descendantScope\":\"selected_body\""))
        XCTAssertTrue(records.joined().contains("\"tag\":\"other\""))
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(diagnostic, sequence: 1, fingerprint: String(repeating: "a", count: 64)))
        for reason in ["unrecognized"] {
            var invalid = diagnostic; invalid["reason"] = reason
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(invalid), provider: .gemini))
        }
        var bound = diagnostic; bound["reason"] = "first_bound"
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(bound), provider: .gemini))
        var invalidScope = diagnostic; invalidScope["descendantScope"] = privateValue
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(invalidScope), provider: .gemini))
        let headingFlags = ["headingSemantic", "absolutePosition", "onePixelBox", "overflowHidden", "rectClipped", "insetClipped"]
        var measuredChild = child; measuredChild["tag"] = "h2"
        for key in headingFlags { measuredChild[key] = key != "insetClipped" }
        var measured = diagnostic; measured["descendants"] = [measuredChild]
        let measuredRecords = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(measured), provider: .gemini))
        XCTAssertTrue(measuredRecords.joined().contains("\"headingSemantic\":true"))
        XCTAssertTrue(measuredRecords.joined().contains("\"tag\":\"h2\""))
        for key in headingFlags {
            var forgedChild = measuredChild; forgedChild[key] = 1
            var forged = measured; forged["descendants"] = [forgedChild]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
            forgedChild = measuredChild; forgedChild.removeValue(forKey: key)
            forged["descendants"] = [forgedChild]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        }
    }

    @MainActor
    func testQueryTemplateDiagnosticsAreBoundedPrivateAndCannotGrantSubmissionProof() throws {
        let valid: [String: Any] = ["kind": "gemini_query_template_v1", "expectedAvailable": true,
            "rowCount": 169, "brRowCount": 20, "textRowCount": 149, "directTextNodeMin": 3,
            "directTextNodeMax": 3, "allTextRowsSingleFrame": true, "rawWholeMatches": false,
            "singleFrameWholeMatches": true, "rawRowMatches": 20, "singleFrameRowMatches": 169,
            "leadingSpaceRows": 149, "trailingSpaceRows": 149, "selectedMode": "ascii_space_frame_v1"]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(valid))
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(valid, sequence: 1, fingerprint: String(repeating: "a", count: 64)))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(missing))
            var privateValue = valid; privateValue[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(privateValue))
        }
        for key in ["text", "prompt", "url", "fingerprint", "nonce"] {
            var leak = valid; leak[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(leak))
        }
        for key in ["rowCount", "brRowCount", "textRowCount", "directTextNodeMin", "directTextNodeMax",
                    "rawRowMatches", "singleFrameRowMatches", "leadingSpaceRows", "trailingSpaceRows"] {
            let invalidMeasurements: [Any] = [true, -1, 8_193, 1.5, "1", NSNull()]
            for invalid in invalidMeasurements {
                var changed = valid; changed[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(changed))
            }
        }
        for key in ["expectedAvailable", "allTextRowsSingleFrame", "rawWholeMatches", "singleFrameWholeMatches"] {
            var changed = valid; changed[key] = 1
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(changed))
        }
        let contradictions: [(String, Any)] = [("brRowCount", 21), ("directTextNodeMin", 4), ("rawRowMatches", 170),
                ("leadingSpaceRows", 150), ("trailingSpaceRows", 148), ("allTextRowsSingleFrame", false),
                ("expectedAvailable", false), ("rawWholeMatches", true), ("selectedMode", "unverified")]
        for (key, value) in contradictions {
            var changed = valid; changed[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQueryTemplateDiagnostic(changed))
        }
        let shape: [String: Any] = ["tag": "span", "classes": ["ng-star-inserted"]]
        var structure: [String: Any] = ["kind": "first_user_structure", "provider": "gemini", "reason": "first_bound",
            "descendantScope": "selected_body", "root": shape, "body": shape, "userCount": 1,
            "textLength": 51_758, "lineCount": 169, "markerOccurrences": 1, "controlDescendants": 0,
            "markerFinalLine": true, "submitted": true, "markerMatches": true, "descendants": [], "queryTemplate": valid]
        func encode() throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: structure), as: UTF8.self) }
        let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(), provider: .gemini))
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.last?.contains("gemini_query_template_v1") == true)
        XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 })
        structure["descendantScope"] = nil
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(), provider: .gemini))
        structure["descendantScope"] = "selected_body"; structure["provider"] = "chatgpt"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(), provider: .chatgpt))
    }

    @MainActor
    func testSubmissionNodeDiagnosticsDistinguishReplacedPointersWithoutPublishingIdentity() throws {
        let valid: [String: Any] = ["kind": "gemini_submission_nodes_v1", "cause": "physical_replaced",
            "rootSame": false, "bodySame": false, "oldRootConnected": false, "oldBodyConnected": false,
            "currentRootConnected": true, "currentBodyConnected": true, "remountCertificatePresent": false,
            "projectedCanonicalMatches": true]
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(valid))
        XCTAssertLessThanOrEqual(safe.utf8.count, 960)
        XCTAssertFalse(EmbeddedWebModelTransport.validSubmissionProof(valid, sequence: 1, fingerprint: String(repeating: "a", count: 64)))
        for key in valid.keys {
            var missing = valid; missing[key] = nil
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(missing))
            var arbitrary = valid; arbitrary[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(arbitrary))
            if !["kind", "cause"].contains(key) {
                arbitrary = valid; arbitrary[key] = 1
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(arbitrary))
            }
        }
        for key in ["root", "body", "text", "prompt", "marker", "fingerprint", "url"] {
            var privateValue = valid; privateValue[key] = "PRIVATE CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(privateValue))
        }
        var unchanged = valid; unchanged["rootSame"] = true; unchanged["bodySame"] = true
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(unchanged))
        var absent = valid; absent["cause"] = "body_missing"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(absent))
        absent["currentBodyConnected"] = false; absent["projectedCanonicalMatches"] = false
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(absent))
        var bodyOnly = valid; bodyOnly["rootSame"] = true; bodyOnly["oldRootConnected"] = true
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedSubmissionNodeDiagnostic(bodyOnly), "Measurements do not authorize recovery")
    }
}
