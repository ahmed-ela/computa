import Foundation
import XCTest

final class AppServerWireTraceTests: XCTestCase {
    func testDecodesExactNewlineDelimitedFramesInSequence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppServerWireTraceTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let wireObjects: [(String, [String: Any])] = [
            (
                "client_to_server",
                ["method": "thread/start", "id": 1, "params": ["dynamicTools": []]]
            ),
            (
                "server_to_client",
                [
                    "method": "item/tool/call",
                    "id": "request-1",
                    "params": [
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "callId": "call-1",
                        "tool": "computer",
                        "arguments": ["action": "permission_status", "parameters": [:]],
                    ],
                ]
            ),
        ]

        var traceData = Data()
        for (index, (direction, object)) in wireObjects.enumerated() {
            var wireData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            wireData.append(0x0A)
            let record: [String: Any] = [
                "sequence": index + 1,
                "direction": direction,
                "wireBase64": wireData.base64EncodedString(),
            ]
            traceData.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            traceData.append(0x0A)
        }
        try traceData.write(to: url, options: .atomic)

        let trace = try AppServerWireTrace.load(url)
        XCTAssertTrue(trace.parseFailures.isEmpty)
        XCTAssertEqual(trace.messages.map(\.sequence), [1, 2])
        XCTAssertEqual(trace.messages.map(\.direction.rawValue), wireObjects.map(\.0))
        XCTAssertEqual(trace.messages.map(\.method), ["thread/start", "item/tool/call"])
        XCTAssertEqual(trace.messages[0].identifier, "integer:1")
        XCTAssertEqual(trace.messages[1].identifier, "string:request-1")
        XCTAssertTrue(trace.messages.allSatisfy { $0.wireData.last == 0x0A })
    }
}
