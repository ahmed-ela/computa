import Foundation
import XCTest
@testable import Computa

final class BrowserConstraintValidationTests: XCTestCase {
    func testInvalidEventFeedbackDecoderRejectsMalformedUnknownAndSecureTargetsWithoutChangingDispatch() {
        let document = BrowserDocumentObservation(loaderID: "native-loader", title: "Form", url: URL(string: "http://localhost/form")!, nodes: [
            .init(backendNodeID: 1, role: "textbox", name: "Field", value: "", isDisabled: false, isReadOnly: false, isIgnored: false,
                  constraintValidation: .init(required: true, candidate: true, valid: false, issues: [.valueMissing])),
            .init(backendNodeID: 2, role: "textbox", name: "Secure", value: nil, isDisabled: true, isReadOnly: true, isIgnored: false),
        ])
        let field: [String: Any] = ["backendNodeID": 1, "issues": ["value_missing"]]
        let base: [String: Any] = ["fields": [field], "truncated": false]
        XCTAssertEqual(BrowserInputFeedback.decode(base, document: document)?.fields,
                       [.init(backendNodeID: 1, issues: [.valueMissing])])
        for bad in [nil, NSNull(), "bad", ["fields": [], "truncated": false],
                    ["fields": [field, field], "truncated": false],
                    ["fields": [field], "truncated": 1],
                    ["fields": [field], "truncated": false, "message": "PRIVATE"]] as [Any?] {
            XCTAssertNil(BrowserInputFeedback.decode(bad, document: document))
        }
        for changed in [
            ["backendNodeID": 2, "issues": ["value_missing"]],
            ["backendNodeID": 900, "issues": ["value_missing"]],
            ["backendNodeID": true, "issues": ["value_missing"]],
            ["backendNodeID": 1, "issues": ["unknown"]],
            ["backendNodeID": 1, "issues": ["value_missing", "value_missing"]],
            ["backendNodeID": 1, "issues": []],
            ["backendNodeID": 1, "issues": ["value_missing"], "value": "PRIVATE"],
        ] as [[String: Any]] {
            XCTAssertNil(BrowserInputFeedback.decode(["fields": [changed], "truncated": false], document: document))
        }
    }

    func testDecoderAllowsOnlyBoundedNativeConstraintState() throws {
        XCTAssertNil(try BrowserConstraintValidation.decode(nil))
        XCTAssertNil(try BrowserConstraintValidation.decode(NSNull()))
        let base: [String: Any] = ["required": true, "candidate": true, "valid": false, "issues": ["value_missing"]]
        XCTAssertEqual(try BrowserConstraintValidation.decode(base),
                       .init(required: true, candidate: true, valid: false, issues: [.valueMissing]))
        for (key, value) in [
            ("required", 1 as Any), ("candidate", "true" as Any), ("valid", true as Any),
            ("issues", ["value_missing", "value_missing"] as Any),
            ("issues", ["page_supplied_reason"] as Any),
            ("issues", Array(repeating: "value_missing", count: 11) as Any),
            ("validationMessage", "PRIVATE_VALIDATION_MESSAGE" as Any),
        ] {
            var malformed = base; malformed[key] = value
            XCTAssertThrowsError(try BrowserConstraintValidation.decode(malformed), key)
        }
        var missing = base; missing.removeValue(forKey: "required")
        XCTAssertThrowsError(try BrowserConstraintValidation.decode(missing))
        XCTAssertThrowsError(try BrowserConstraintValidation.decode("not an object"))
    }

    func testCompactRenderingDistinguishesNonCandidatesWithoutPageMessages() {
        XCTAssertEqual(BrowserConstraintValidation(required: false, candidate: true, valid: true, issues: []).formattedMetadata,
                       " constraint=valid")
        XCTAssertEqual(BrowserConstraintValidation(required: true, candidate: false, valid: false, issues: [.customError]).formattedMetadata,
                       " required=true constraint=not_candidate")
        let all = BrowserConstraintValidation(required: true, candidate: true, valid: false, issues: Array(BrowserConstraintValidation.Issue.allCases.reversed()))
        XCTAssertLessThan(all.formattedMetadata.utf8.count, 200)
        XCTAssertTrue(all.formattedMetadata.hasPrefix(" required=true constraint=invalid[value_missing,type_mismatch,"))
        XCTAssertFalse(all.formattedMetadata.contains("validationMessage"))
    }
}
