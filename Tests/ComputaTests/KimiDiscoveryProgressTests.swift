import Foundation
import XCTest
@testable import Computa

@MainActor
final class KimiDiscoveryProgressTests: XCTestCase {
    private typealias Diagnostic = EmbeddedWebModelTransport.KimiDiscoveryProgressDiagnostic

    private func observation(phase: String = "moreOpening", bits: Int = 19) -> [String: Any] {
        let flags = ["mainMenuPresent", "mainExpanded", "mainCollapsed", "submenuClaimed",
                     "submenuPresent", "submenuExpanded", "submenuCollapsed"]
        var value: [String: Any] = ["phase": phase]
        for (index, flag) in flags.enumerated() { value[flag] = (bits & (1 << index)) != 0 }
        return value
    }

    func testOnlyExactFiniteShapeAndRealJSONBooleansAreAccepted() throws {
        for phase in Diagnostic.Phase.allCases {
            let data = try JSONSerialization.data(withJSONObject: observation(phase: phase.rawValue))
            let value = try JSONSerialization.jsonObject(with: data)
            XCTAssertEqual(Diagnostic(value)?.phase, phase)
        }
        let invalid: [Any] = [0, 1, "true", "false", NSNull(), [], ["private": "value"]]
        for bad in invalid {
            var value = observation(); value["submenuPresent"] = bad
            XCTAssertNil(Diagnostic(value))
        }
        var value = observation(); value["phase"] = "Private model label"
        XCTAssertNil(Diagnostic(value))
        value = observation(); value["pageText"] = "Synthetic private canary"
        XCTAssertNil(Diagnostic(value))
        value = observation(); value.removeValue(forKey: "mainMenuPresent")
        XCTAssertNil(Diagnostic(value))
        XCTAssertNil(Diagnostic(nil)); XCTAssertNil(Diagnostic([]))
    }

    func testDiagnosticIsRemovedBeforeValidationEvenWhenMalformedOrNotAdmitted() {
        for provider in [EmbeddedWebModelTransport.Provider.kimi, .claude] {
            for action in ["discoverModels", "selectModel", "inspect", "submit"] {
                var value: [String: Any] = ["discoveryProgressDiagnostic": observation(), "pending": true]
                let result = EmbeddedWebModelTransport.removeKimiDiscoveryProgressDiagnostic(
                    from: &value, provider: provider, action: action)
                XCTAssertEqual(result != nil, provider == .kimi && ["discoverModels", "selectModel"].contains(action))
                XCTAssertEqual(Set(value.keys), ["pending"])
                XCTAssertEqual(value["pending"] as? Bool, true)
            }
        }
        var value: [String: Any] = ["discoveryProgressDiagnostic": ["private": "Synthetic private canary"], "composer": false]
        XCTAssertNil(EmbeddedWebModelTransport.removeKimiDiscoveryProgressDiagnostic(from: &value, provider: .kimi, action: "discoverModels"))
        XCTAssertEqual(Set(value.keys), ["composer"])
    }

    func testBudgetDeduplicatesAllSeenStatesAndRetainsLatestAfterItsFixedLimit() throws {
        var budget = EmbeddedWebModelTransport.KimiDiscoveryProgressLogBudget()
        let first = try XCTUnwrap(Diagnostic(observation(bits: 0)))
        XCTAssertNotNil(budget.observe(first)); XCTAssertNil(budget.observe(first))
        for bits in 1..<12 {
            XCTAssertNotNil(budget.observe(try XCTUnwrap(Diagnostic(observation(bits: bits)))))
            XCTAssertNil(budget.observe(first), "Nonconsecutive duplicates do not consume another record")
        }
        XCTAssertNil(budget.observe(first), "Nonconsecutive duplicates do not renew the budget")
        let latest = try XCTUnwrap(Diagnostic(observation(phase: "moreClosing", bits: 127)))
        for _ in 0..<100 { XCTAssertNil(budget.observe(latest)) }
        XCTAssertEqual(budget.finish(), latest.logFields, "Final retained state survives a spent progress budget")
        XCTAssertNil(budget.finish()); XCTAssertNil(budget.observe(first))
        var empty = EmbeddedWebModelTransport.KimiDiscoveryProgressLogBudget()
        XCTAssertNil(empty.finish()); XCTAssertNil(empty.observe(first))
    }

    func testPreparationTimeoutDescribesSavedAndTemporarySessionsWithoutChangingItsFailure() {
        XCTAssertEqual(EmbeddedWebModelTransport.Failure.preparationDeadline.errorDescription,
            "The website did not prepare a verified chat session before the 45-second deadline. This website inference was not submitted.")
    }
}
