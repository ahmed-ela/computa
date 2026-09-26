import Foundation
import XCTest
@testable import HeyDash

final class AgentRPCErrorTests: XCTestCase {
    func testStructuredConflictRetainsExactRevisionAndSchema() throws {
        let payload: [String: Any] = ["reason": "conflict", "current": ["revision": 7, "schemaSha256": "abc"]]
        let error = AgentRPCError(object: ["code": -32600, "message": "Changed", "data": payload])
        XCTAssertEqual(error.code, -32600)
        XCTAssertEqual(error.localizedDescription, "Changed")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(error.data)) as? NSDictionary, payload as NSDictionary)
    }

    func testMissingAndExplicitNullDataRemainDistinct() throws {
        XCTAssertNil(AgentRPCError(object: ["message": "missing"]).data)
        let error = AgentRPCError(object: ["message": "null", "data": NSNull()])
        XCTAssertTrue(try JSONSerialization.jsonObject(with: XCTUnwrap(error.data), options: .fragmentsAllowed) is NSNull)
    }

    func testScalarAndArrayPayloadsAreNotDiscarded() throws {
        let payloads: [Any] = ["details", 7, true, ["one", "two"]]
        for payload in payloads {
            let error = AgentRPCError(object: ["message": "test", "data": payload])
            let expected = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed, .sortedKeys])
            XCTAssertEqual(error.data, expected)
        }
    }

    func testMalformedCodesNeverBecomeAValidInteger() {
        let codes: [Any] = [true, "-32600", 1.5, Double.infinity, NSNull(), UInt64.max]
        for code in codes {
            XCTAssertNil(AgentRPCError(object: ["code": code]).code)
        }
        XCTAssertEqual(AgentRPCError(object: ["code": Int64.min]).code, Int64.min)
        XCTAssertEqual(AgentRPCError(object: ["code": Int64.max]).code, Int64.max)
        XCTAssertEqual(AgentRPCError(object: ["code": -32600.0]).code, -32600)
    }

    func testMalformedMessageKeepsTheExistingFallback() {
        XCTAssertEqual(AgentRPCError(object: ["message": 42]).localizedDescription,
                       "Codex App Server request failed.")
    }
}
