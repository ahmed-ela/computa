import Foundation
import XCTest

final class RolloutPrimitiveTraceTests: XCTestCase {
    func testParsesPersistedToolSchemaCallOutputAndAssistantMessage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RolloutPrimitiveTraceTests-\(UUID().uuidString)", isDirectory: true)
        let sessions = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026/09/22", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let records: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "dynamic_tools": [[
                        "type": "function",
                        "name": "computer",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "enum": ["permission_status"]],
                            ],
                        ],
                    ]],
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "function_call",
                    "name": "computer",
                    "call_id": "call_primitive",
                    "arguments": #"{"action":"permission_status","parameters":{}}"#,
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "function_call_output",
                    "call_id": "call_primitive",
                    "output": "{\"accessibility\":\"granted\"}",
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "PRIMITIVE_OK"]],
                ],
            ],
        ]
        let data = try records.reduce(into: Data()) { output, record in
            output.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            output.append(0x0A)
        }
        let rolloutURL = sessions.appendingPathComponent("rollout-test.jsonl")
        try data.write(to: rolloutURL, options: .atomic)

        let trace = try RolloutPrimitiveTrace.loadLatest(in: root.path)
        XCTAssertEqual(
            trace.rolloutURL.resolvingSymlinksInPath(),
            rolloutURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(trace.dynamicTools.first?["name"] as? String, "computer")
        XCTAssertEqual(trace.functionCalls.map(\.name), ["computer"])
        XCTAssertEqual(trace.functionCalls.map(\.action), ["permission_status"])
        XCTAssertEqual(trace.functionCalls.map(\.callID), ["call_primitive"])
        XCTAssertEqual(trace.functionCallOutputs.map(\.callID), ["call_primitive"])
        XCTAssertEqual(trace.output(for: "call_primitive") as? String, "{\"accessibility\":\"granted\"}")
        XCTAssertEqual(trace.assistantMessages, ["PRIMITIVE_OK"])
        XCTAssertTrue(trace.parseFailures.isEmpty)
    }
}
