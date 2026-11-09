import Foundation

/// A lexical index of an already codec/continuation-validated request copy.
/// Native HTTP and website display copies must be parsed separately. Parsed
/// names/ranges never establish native completion or publication authority.
struct GroqContextJSONLayout: Sendable {
    enum Failure: Error, Equatable, Sendable { case unavailable }
    enum ItemKind: String, Equatable, Sendable {
        case message
        case functionCall = "function_call"
        case customToolCall = "custom_tool_call"
        case functionCallOutput = "function_call_output"
        case customToolCallOutput = "custom_tool_call_output"
        case other
    }
    enum PayloadField: String, Equatable, Sendable { case arguments, input, output }

    struct Member: Sendable {
        let key: String
        /// Key, colon, intervening whitespace and value, excluding commas.
        let wholeRange: Range<Int>
        let valueRange: Range<Int>
    }
    struct Payload: Sendable {
        let field: PayloadField
        let valueRange: Range<Int>
        let rawJSON: Data
        /// Only a JSON string has literal UTF-8. Arrays/objects are not joined,
        /// normalized or silently converted to text.
        let literalUTF8: Data?
    }
    struct Item: Sendable {
        let ordinal: Int
        let wholeRange: Range<Int>
        let kind: ItemKind
        let role: String?
        let callID: String?
        let name: String?
        let namespace: String?
        let recordID: String?
        let payload: Payload?
        let otherMembers: [Member]
    }

    let sourceUTF8: Data
    let rootRange: Range<Int>
    /// Framing/indexing only: protecting the whole input would prevent every
    /// field substitution. A string input instead has no candidate fields.
    let inputRange: Range<Int>
    let instructionsRange: Range<Int>?
    let toolsRange: Range<Int>?
    let rootOtherMembers: [Member]
    let items: [Item]
    /// Every source byte outside recognized call/output payload VALUES.
    /// A payload slot is only structural information. The native ledger must
    /// separately authorize completed exec/patch fields; browser/latest data
    /// and all other unselected slots must remain inline.
    let protectedRanges: [Range<Int>]

    func rawBytes(in range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= sourceUTF8.count else { throw Failure.unavailable }
        return sourceUTF8.subdata(in: range)
    }

    static func parse(_ sourceUTF8: Data) throws -> Self {
        guard sourceUTF8.count <= WebModelResponseCodec.maximumPromptBytes,
              (try? JSONSerialization.jsonObject(with: sourceUTF8)) is [String: Any] else {
            throw Failure.unavailable
        }
        var scanner = Scanner(bytes: Array(sourceUTF8))
        let root = try scanner.value([], depth: 0)
        scanner.whitespace()
        guard root.kind == .object, scanner.position == scanner.bytes.count,
              let input = scanner.rootMembers.first(where: { $0.member.key == "input" }),
              input.node.kind == .array || input.node.kind == .string,
              scanner.inputItems.count <= 1_024 else { throw Failure.unavailable }
        let source = Data(scanner.bytes)
        var items: [Item] = []
        for (ordinal, node) in scanner.inputItems.enumerated() {
            guard node.kind == .object else { throw Failure.unavailable }
            let members = scanner.itemMembers[ordinal] ?? []
            func text(_ key: String) throws -> String? {
                guard let field = members.first(where: { $0.member.key == key }) else { return nil }
                guard field.node.kind == .string else { throw Failure.unavailable }
                return try scanner.decoded(field.node.range)
            }
            let type = try text("type"), role = try text("role")
            let kind = type.flatMap { ItemKind(rawValue: $0) } ?? (type == nil && role != nil ? .message : .other)
            guard role == nil || kind == .message || kind == .other else { throw Failure.unavailable }
            let callID = try text("call_id"), name = try text("name"), namespace = try text("namespace"), recordID = try text("id")
            let field: PayloadField?
            switch kind {
            case .functionCall: field = .arguments
            case .customToolCall: field = .input
            case .functionCallOutput, .customToolCallOutput: field = .output
            case .message, .other: field = nil
            }
            let payload: Payload?
            if let field {
                guard let callID, !callID.isEmpty,
                      let value = members.first(where: { $0.member.key == field.rawValue }) else { throw Failure.unavailable }
                if kind == .functionCall || kind == .customToolCall {
                    guard let name, !name.isEmpty else { throw Failure.unavailable }
                }
                let raw = source.subdata(in: value.node.range)
                let literal = value.node.kind == .string ? Data(try scanner.decoded(value.node.range).utf8) : nil
                payload = Payload(field: field, valueRange: value.node.range, rawJSON: raw, literalUTF8: literal)
            } else { payload = nil }
            let known: Set<String>
            switch kind {
            case .message: known = ["type", "role", "id", "content", "phase", "status"]
            case .functionCall: known = ["type", "id", "call_id", "name", "namespace", "arguments", "status"]
            case .customToolCall: known = ["type", "id", "call_id", "name", "namespace", "input", "status"]
            case .functionCallOutput, .customToolCallOutput: known = ["type", "id", "call_id", "name", "namespace", "output"]
            case .other: known = []
            }
            items.append(Item(ordinal: ordinal, wholeRange: node.range, kind: kind, role: role,
                callID: callID, name: name, namespace: namespace, recordID: recordID, payload: payload,
                otherMembers: members.map(\.member).filter { !known.contains($0.key) }))
        }
        let fields = items.compactMap { $0.payload?.valueRange }.sorted { $0.lowerBound < $1.lowerBound }
        var protected: [Range<Int>] = [], cursor = 0
        for field in fields {
            guard field.lowerBound >= cursor, field.upperBound <= source.count else { throw Failure.unavailable }
            if cursor < field.lowerBound { protected.append(cursor..<field.lowerBound) }
            cursor = field.upperBound
        }
        if cursor < source.count { protected.append(cursor..<source.count) }
        let rootMembers = scanner.rootMembers.map(\.member)
        return Self(sourceUTF8: source, rootRange: root.range, inputRange: input.node.range,
            instructionsRange: rootMembers.first(where: { $0.key == "instructions" })?.valueRange,
            toolsRange: rootMembers.first(where: { $0.key == "tools" })?.valueRange,
            rootOtherMembers: rootMembers.filter { !["input", "instructions", "tools"].contains($0.key) },
            items: items, protectedRanges: protected)
    }

    // The lexical value/string/whitespace walk is taken from the current
    // groqTrustedNativeProjection scanner. It does not decode/re-encode values.
    // Added callbacks collect only root members, direct input items and their
    // members. Ordinary JSON validation above remains the grammar authority.
    private enum Path: Equatable { case key(String), index(Int) }
    private enum Kind: Equatable { case object, array, string, atom }
    private struct Node { let range: Range<Int>; let kind: Kind }
    private struct Field { let member: Member; let node: Node }
    private struct Scanner {
        let bytes: [UInt8]
        var position = 0
        var rootMembers: [Field] = []
        var inputItems: [Node] = []
        var itemMembers: [Int: [Field]] = [:]
        mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }
        mutating func stringRange() throws -> Range<Int> {
            guard position < bytes.count, bytes[position] == 34 else { throw Failure.unavailable }
            let start = position
            position += 1
            while position < bytes.count {
                if bytes[position] == 92 { position += 2 }
                else if bytes[position] == 34 { position += 1; return start..<position }
                else { position += 1 }
            }
            throw Failure.unavailable
        }
        func decoded(_ range: Range<Int>) throws -> String {
            guard let result = try JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) as? String
            else { throw Failure.unavailable }
            return result
        }
        func itemOrdinal(_ path: [Path]) -> Int? {
            guard path.count == 2, path[0] == .key("input"), case let .index(index) = path[1] else { return nil }
            return index
        }
        func selectsLayout(_ key: String, at path: [Path]) -> Bool {
            if path.isEmpty { return ["input", "instructions", "tools"].contains(key) }
            return itemOrdinal(path) != nil
                && ["type", "role", "id", "call_id", "name", "namespace", "arguments", "input", "output"].contains(key)
        }
        mutating func value(_ path: [Path], depth: Int) throws -> Node {
            guard depth <= 256 else { throw Failure.unavailable }
            whitespace()
            let start = position
            guard position < bytes.count else { throw Failure.unavailable }
            let kind: Kind
            switch bytes[position] {
            case 34:
                _ = try stringRange(); kind = .string
            case 123:
                kind = .object
                position += 1; whitespace()
                if position < bytes.count, bytes[position] == 125 { position += 1; break }
                var keys = Set<String>()
                while true {
                    whitespace()
                    let keyRange = try stringRange(), key = try decoded(keyRange)
                    guard keys.insert(key).inserted,
                          !selectsLayout(key, at: path) || !bytes[keyRange].contains(92) else { throw Failure.unavailable }
                    whitespace()
                    guard position < bytes.count, bytes[position] == 58 else { throw Failure.unavailable }
                    position += 1
                    let node = try value(path + [.key(key)], depth: depth + 1)
                    let field = Field(member: Member(key: key, wholeRange: keyRange.lowerBound..<node.range.upperBound,
                                                    valueRange: node.range), node: node)
                    if path.isEmpty { rootMembers.append(field) }
                    if let index = itemOrdinal(path) { itemMembers[index, default: []].append(field) }
                    whitespace()
                    guard position < bytes.count else { throw Failure.unavailable }
                    if bytes[position] == 125 { position += 1; break }
                    guard bytes[position] == 44 else { throw Failure.unavailable }
                    position += 1
                }
            case 91:
                kind = .array
                position += 1; whitespace()
                if position < bytes.count, bytes[position] == 93 { position += 1; break }
                var index = 0
                while true {
                    _ = try value(path + [.index(index)], depth: depth + 1); index += 1
                    whitespace()
                    guard position < bytes.count else { throw Failure.unavailable }
                    if bytes[position] == 93 { position += 1; break }
                    guard bytes[position] == 44 else { throw Failure.unavailable }
                    position += 1
                }
            default:
                kind = .atom
                while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                guard position > start else { throw Failure.unavailable }
            }
            let node = Node(range: start..<position, kind: kind)
            if itemOrdinal(path) != nil { inputItems.append(node) }
            return node
        }
    }
}
