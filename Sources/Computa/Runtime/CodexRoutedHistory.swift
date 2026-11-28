import CryptoKit
import Foundation

/// Kolmogor owns these versioned records. Codex owns the thread and the native turn IDs.
struct CodexRoutedHistory {
    static let type = "com.kolmogor.conversation.v1"
    struct Attachment: Decodable, Sendable {
        let attachmentType: String
        let identityKey: String
        let payload: Record?
        enum CodingKeys: String, CodingKey { case attachmentType, identityKey, payload }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            attachmentType = try c.decode(String.self, forKey: .attachmentType)
            identityKey = try c.decode(String.self, forKey: .identityKey)
            payload = attachmentType == CodexRoutedHistory.type ? try c.decode(Record.self, forKey: .payload) : nil
        }
    }
    struct Record: Codable, Equatable, Sendable {
        let turn: UUID
        let kind: String
        var anchor: String?
        var previous: UUID?
        var model: String?
        var session: String?
        var digest: String?
        var count: Int?
        var bytes: Data?
    }
    struct Exchange: Codable, Sendable {
        let id: UUID
        let anchor: String
        let model: String
        let prompt: String
        var status: String
        var answer: String?
        var session: String?
    }
    struct Line: Codable, Sendable {
        let role: String
        let text: String
        let model: String?
    }
    static func parts(_ text: String, turn: UUID, role: String) -> ([(String, Record)], String) {
        let data = Data(text.utf8)
        // Codex limits a single attachment to 64 KiB, including JSON encoding.
        let parts = stride(from: 0, to: data.count, by: 36_000).enumerated().map { index, offset in
            let bytes = data.subdata(in: offset..<min(offset + 36_000, data.count))
            return (partKey(turn, role, index), Record(turn: turn, kind: role, bytes: bytes))
        }
        return (parts, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private static func partKey(_ id: UUID, _ role: String, _ index: Int) -> String {
        "\(id.uuidString)/\(role)/\(index)"
    }
    let records: [String: Record]
    init(_ attachments: [Attachment]) throws {
        var records: [String: Record] = [:]
        for a in attachments {
            guard let record = a.payload else { continue }
            guard records.updateValue(record, forKey: a.identityKey) == nil else { throw CodexDesktopSidebarClient.Failure.inconsistent }
        }
        self.records = records
    }
    static func slot(anchor: String, previous: UUID?) -> String {
        "next/" + (previous?.uuidString ?? "native/" + anchor)
    }
    private func content(_ record: Record, role: String) throws -> String {
        guard let count = record.count, count > 0, count <= records.count else { throw CodexDesktopSidebarClient.Failure.inconsistent }
        var data = Data()
        for index in 0..<count {
            guard let part = records[Self.partKey(record.turn, role, index)], part.turn == record.turn,
                  part.kind == role, let bytes = part.bytes else { throw CodexDesktopSidebarClient.Failure.inconsistent }
            data.append(bytes)
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.digest,
              let text = String(data: data, encoding: .utf8) else { throw CodexDesktopSidebarClient.Failure.inconsistent }
        return text
    }
    func exchanges(anchor: String) throws -> [Exchange] {
        var rows: [Exchange] = [], seen = Set<UUID>()
        while let start = records[Self.slot(anchor: anchor, previous: rows.last?.id)] {
            guard start.kind == "start", start.anchor == anchor, start.previous == rows.last?.id,
                  seen.insert(start.turn).inserted, let model = start.model else { throw CodexDesktopSidebarClient.Failure.inconsistent }
            var row = Exchange(id: start.turn, anchor: anchor, model: model, prompt: try content(start, role: "prompt"), status: "unconfirmed")
            if let end = records["end/" + start.turn.uuidString] {
                guard end.turn == start.turn, ["completed", "failed"].contains(end.kind), end.model == model else {
                    throw CodexDesktopSidebarClient.Failure.inconsistent
                }
                row.status = end.kind
                row.session = end.session
                row.answer = try content(end, role: "reply")
            }
            rows.append(row)
        }
        return rows
    }
}
