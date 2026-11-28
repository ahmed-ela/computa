import Foundation
import XCTest
@testable import Computa

final class CodexRoutedHistoryTests: XCTestCase {
    typealias History = CodexRoutedHistory

    private func attachment(_ key: String, _ record: History.Record) throws -> History.Attachment {
        struct Row: Encodable { let identityKey: String; let payload: History.Record; let attachmentType: String }
        let data = try JSONEncoder().encode(Row(identityKey: key, payload: record, attachmentType: History.type))
        return try JSONDecoder().decode(History.Attachment.self, from: data)
    }

    func testUTF8AcrossChunksAndStableOrderAcrossReopening() throws {
        let anchor = "original/lastItem", one = UUID(), two = UUID()
        let long = String(repeating: "行🙂", count: 11_400)
        var rows: [History.Attachment] = []
        func add(_ content: String, role: String, at key: String, record: History.Record) throws {
            let (parts, hash) = History.parts(content, turn: record.turn, role: role)
            var manifest = record
            manifest.count = parts.count
            manifest.digest = hash
            for (key, part) in parts {
                XCTAssertLessThan(try JSONEncoder().encode(part).count, 65_536)
                rows.append(try attachment(key, part))
            }
            rows.append(try attachment(key, manifest))
        }
        try add("first", role: "prompt", at: History.slot(anchor: anchor, previous: nil), record: .init(turn: one, kind: "start", anchor: anchor, model: "Gemini"))
        try add(long, role: "reply", at: "end/" + one.uuidString, record: .init(turn: one, kind: "completed", model: "Gemini", session: "A"))
        try add("second", role: "prompt", at: History.slot(anchor: anchor, previous: one), record: .init(turn: two, kind: "start", anchor: anchor, previous: one, model: "Claude"))
        // Another client's attachment may have an unrelated JSON payload.
        let other = Data(#"{"attachmentType":"different","identityKey":"test","payload":[1,2]}"#.utf8)
        rows.append(try JSONDecoder().decode(History.Attachment.self, from: other))
        let history = try History(rows.reversed())
        let result = try history.exchanges(anchor: anchor)
        XCTAssertEqual(result.map(\.id), [one, two])
        XCTAssertEqual(result.first?.answer, long)
        XCTAssertEqual(result.last?.status, "unconfirmed")
        XCTAssertTrue(try history.exchanges(anchor: "rolled-back/other").isEmpty)
        XCTAssertThrowsError(try History(Array(rows.dropFirst())).exchanges(anchor: anchor))
        XCTAssertThrowsError(try History(rows + [rows[0]]))
    }

    func testProviderModelChangeInvalidatesReceipt() async {
        let collector = RoutedACPResponse()
        await collector.expect("s", model: "chosen", configID: "model")
        await collector.receive(Data(#"{"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","currentValue":"other"}]}}}"#.utf8))
        do { _ = try await collector.result(); XCTFail("A changed model cannot receive attribution.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("switched models")) }
    }

    func testGuardedProviderSessionAndPermissionRequest() async throws {
        let collector = RoutedACPResponse()
        await collector.expect("selected", model: "chosen", configID: "model")
        func chunk(_ session: String, _ value: String) -> Data {
            Data(#"{"method":"session/update","params":{"sessionId":"\#(session)","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(value)"}}}}"#.utf8)
        }
        await collector.receive(chunk("other", "wrong"))
        await collector.receive(chunk("selected", "right"))
        let answer = try await collector.result()
        XCTAssertEqual(answer, "right")
        await collector.receive(Data(#"{"method":"session/update","params":{"sessionId":"selected","update":{"sessionUpdate":"tool_call"}}}"#.utf8))
        do { _ = try await collector.result(); XCTFail("Tool activity cannot establish a conversation-only completion.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("tool")) }
    }
}
