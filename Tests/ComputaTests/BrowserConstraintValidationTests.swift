import Foundation
import XCTest
@testable import Computa

final class BrowserConstraintValidationTests: XCTestCase {
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
