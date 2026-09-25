import Foundation
import XCTest
@testable import HeyDash

final class VisualGroundingDecisionTests: XCTestCase {
    func testValidAgreementDecisionPassesStrictValidation() throws {
        let request = makeRequest()
        let decision = try decode([
            "point": ["x": 100.5, "y": 200.25],
            "method_version": VisualGroundingDecision.methodVersion,
            "used_showui": false,
            "selected_pair": ["goclick", "gui_owl_2b"],
            "agreement_threshold_normalized_diagonal": 0.03,
            "initial_distance_normalized_diagonal": hypot(1.0, 0.5) / hypot(1280.0, 800.0),
            "selected_distance_normalized_diagonal": hypot(1.0, 0.5) / hypot(1280.0, 800.0),
            "model_points": [
                "goclick": ["x": 100, "y": 200],
                "gui_owl_2b": ["x": 101, "y": 200.5],
                "showui": NSNull(),
            ],
            "model_latency_ms": [
                "goclick": 108,
                "gui_owl_2b": 1_077,
                "showui": NSNull(),
            ],
            "latency_ms": 1_190,
            "image_width": 1280,
            "image_height": 800,
        ])

        XCTAssertNoThrow(try decision.validated(for: request))
    }

    func testShowUIEvidenceMustMatchRoutingFlag() throws {
        var object = validTieBreakObject()
        object["used_showui"] = false
        let decision = try decode(object)

        XCTAssertThrowsError(try decision.validated(for: makeRequest())) { error in
            XCTAssertEqual(
                error as? VisualGroundingError,
                .protocolViolation("ShowUI routing evidence is inconsistent")
            )
        }
    }

    func testOutOfBoundsNonfiniteAndWrongDimensionsFailClosed() throws {
        var cases = [validTieBreakObject(), validTieBreakObject(), validTieBreakObject()]
        cases[0]["point"] = ["x": 1280, "y": 100]
        cases[1]["latency_ms"] = -1
        cases[2]["image_width"] = 1279

        for object in cases {
            let decision = try decode(object)
            XCTAssertThrowsError(try decision.validated(for: makeRequest()))
        }
    }

    func testUnexpectedMethodPairAndThresholdFailClosed() throws {
        var cases = [validTieBreakObject(), validTieBreakObject(), validTieBreakObject()]
        cases[0]["method_version"] = "unreviewed-rule"
        cases[1]["selected_pair"] = ["goclick", "goclick"]
        cases[2]["agreement_threshold_normalized_diagonal"] = 0.04

        for object in cases {
            let decision = try decode(object)
            XCTAssertThrowsError(try decision.validated(for: makeRequest()))
        }
    }

    func testWorkerCannotInventAMidpointOrDistance() throws {
        var cases = [validTieBreakObject(), validTieBreakObject(), validTieBreakObject()]
        cases[0]["point"] = ["x": 500, "y": 500]
        cases[1]["selected_distance_normalized_diagonal"] = 0.000_001
        cases[2]["model_points"] = [
            "goclick": ["x": 50, "y": 50],
            "gui_owl_2b": ["x": 640, "y": 400],
            "showui": ["x": 1200, "y": 750],
        ]

        for object in cases {
            let decision = try decode(object)
            XCTAssertThrowsError(try decision.validated(for: makeRequest()))
        }
    }

    private func makeRequest() -> VisualGroundingRequest {
        VisualGroundingRequest(
            id: UUID(),
            png: Data([1, 2, 3]),
            width: 1280,
            height: 800,
            target: "Click Save"
        )
    }

    private func validTieBreakObject() -> [String: Any] {
        [
            "point": ["x": 105, "y": 104],
            "method_version": VisualGroundingDecision.methodVersion,
            "used_showui": true,
            "selected_pair": ["goclick", "showui"],
            "agreement_threshold_normalized_diagonal": 0.03,
            "initial_distance_normalized_diagonal": hypot(800.0, 600.0) / hypot(1280.0, 800.0),
            "selected_distance_normalized_diagonal": hypot(10.0, 8.0) / hypot(1280.0, 800.0),
            "model_points": [
                "goclick": ["x": 100, "y": 100],
                "gui_owl_2b": ["x": 900, "y": 700],
                "showui": ["x": 110, "y": 108],
            ],
            "model_latency_ms": [
                "goclick": 108,
                "gui_owl_2b": 1_077,
                "showui": 1_402,
            ],
            "latency_ms": 2_600,
            "image_width": 1280,
            "image_height": 800,
        ]
    }

    private func decode(_ object: [String: Any]) throws -> VisualGroundingDecision {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(VisualGroundingDecision.self, from: data)
    }
}
