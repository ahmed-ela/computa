import Foundation

/// Admission state for an authenticated native tool loop, never website text.
/// Stored bytes are private in-memory context, not diagnostics or persistence.
struct WebsiteTurnContinuation: Sendable {
    enum Failure: String, LocalizedError, Equatable, Sendable {
        case invalidContext = "invalid_context"
        case invalidResponse = "invalid_response"
        case changedConfiguration = "changed_configuration"
        case changedHistory = "changed_history"
        case invalidToolOutputs = "invalid_tool_outputs"
        case invalidFollowUp = "invalid_follow_up"
        case contextLimitExceeded = "context_limit_exceeded"

        var errorDescription: String? {
            "The native website continuation could not be verified (\(rawValue)). No continuation prompt was submitted or replayed."
        }
    }

    private struct PendingCall: Sendable {
        let callID: Data
        let outputType: String
        let name: Data
        let namespace: Data?
    }

    private let configuration: Data
    private let previousInput: [Data]
    private let emittedOutput: [JSONValue]
    private let pendingCalls: [PendingCall]
    let pendingToolCallCount: Int

    /// Run before the first website Send as well as when admitting a follow-up.
    /// The existing codec validates provider options; this adds lossless JSON
    /// identity, duplicate-key rejection and finite history traversal bounds.
    static func validateRequest(_ request: WebModelResponseCodec.Request) throws {
        _ = try requestContext(request)
    }

    init(request: WebModelResponseCodec.Request, encodedResponse: Data) throws {
        let context = try Self.requestContext(request)
        let response = try Self.completedResponse(encodedResponse, streamed: request.stream)
        guard response["model"] == .text(request.model), response["status"] == .text("completed"),
              response["error"] == .null, let endTurn = response["end_turn"]?.boolean,
              let output = response["output"]?.array, !output.isEmpty, output.count <= 65 else {
            throw Failure.invalidResponse
        }
        var calls: [PendingCall] = []
        var identities = Set<Data>()
        var nativeOutput: [JSONValue] = []
        for (index, item) in output.enumerated() {
            guard let fields = item.object, let type = fields["type"]?.string,
                  let id = fields["id"]?.textBytes, !id.isEmpty,
                  identities.insert(id).inserted else { throw Failure.invalidResponse }
            switch type {
            case "message":
                guard index == 0, fields["role"] == .text("assistant"),
                      fields["phase"] == .text(endTurn ? "final_answer" : "commentary"),
                      !endTurn || output.count == 1 else { throw Failure.invalidResponse }
            case "function_call", "custom_tool_call":
                guard !endTurn, calls.count < 64,
                      let callID = fields["call_id"]?.textBytes, !callID.isEmpty,
                      let name = fields["name"]?.textBytes, !name.isEmpty,
                      !calls.contains(where: { $0.callID == callID }) else { throw Failure.invalidResponse }
                calls.append(.init(callID: callID, outputType: type == "function_call" ? "function_call_output" : "custom_tool_call_output",
                                   name: name, namespace: fields["namespace"]?.textBytes))
            default: throw Failure.invalidResponse
            }
            nativeOutput.append(try Self.nativeOutputItem(item))
        }
        guard endTurn ? calls.isEmpty : !calls.isEmpty else { throw Failure.invalidResponse }
        // A locally emitted call may not alias a historical call/result.
        for item in context.input {
            if let callID = item["call_id"]?.textBytes,
               calls.contains(where: { $0.callID == callID }) { throw Failure.invalidResponse }
        }
        configuration = context.configuration.encoded()
        previousInput = context.input.map { $0.encoded() }
        emittedOutput = nativeOutput
        pendingCalls = calls
        pendingToolCallCount = calls.count
    }

    /// Tool continuation is strictly append-only. A completed-final barrier
    /// admits only a new user message, which the server sends in a NEW website
    /// conversation. The full next request remains intact for either path.
    func validate(next request: WebModelResponseCodec.Request) throws {
        let next = try Self.requestContext(request)
        guard next.configuration.encoded() == configuration else { throw Failure.changedConfiguration }
        let prefixCount = previousInput.count + emittedOutput.count
        guard next.input.count > prefixCount,
              next.input.prefix(previousInput.count).map({ $0.encoded() }) == previousInput else {
            throw Failure.changedHistory
        }
        for (offset, expected) in emittedOutput.enumerated() {
            var actual = try Self.nativeOutputItem(next.input[previousInput.count + offset])
            // Pinned Core omits FunctionCall.id on external requests. Restore
            // only this locally emitted ID for comparison, never for history.
            // A supplied ID, all authority fields, and other item types remain exact.
            if expected["type"] == .text("function_call"), actual["type"] == .text("function_call"),
               actual["id"] == nil, var fields = actual.object {
                fields["id"] = expected["id"]
                actual = .object(fields)
            }
            guard actual.encoded() == expected.encoded() else { throw Failure.changedHistory }
        }
        let appended = Array(next.input.dropFirst(prefixCount))
        if pendingCalls.isEmpty {
            guard !appended.isEmpty, appended.allSatisfy(Self.isNewUserMessage) else { throw Failure.invalidFollowUp }
            return
        }
        guard appended.count == pendingCalls.count else { throw Failure.invalidToolOutputs }
        var received = Set<Data>()
        var itemIDs = Set(next.input.prefix(prefixCount).compactMap { $0["id"]?.textBytes })
        for item in appended {
            guard let fields = item.object,
                  let callID = fields["call_id"]?.textBytes,
                  let call = pendingCalls.first(where: { $0.callID == callID }),
                  Set(fields.keys).isSubset(of: Set((call.outputType == "function_call_output"
                      ? ["id", "type", "call_id", "output", "name", "namespace"]
                      : ["id", "type", "call_id", "output", "name"]).map { Data($0.utf8) })),
                  fields["type"] == .text(call.outputType), received.insert(callID).inserted,
                  fields["name"] == nil || fields["name"]?.textBytes == call.name,
                  fields["namespace"] == nil || (call.namespace != nil && fields["namespace"]?.textBytes == call.namespace),
                  let output = fields["output"], Self.isToolOutput(output) else { throw Failure.invalidToolOutputs }
            if let id = fields["id"] {
                guard let bytes = id.textBytes, Self.isNativeToolOutputID(bytes, type: call.outputType),
                      itemIDs.insert(bytes).inserted else { throw Failure.invalidToolOutputs }
            }
        }
        guard received.count == pendingCalls.count else { throw Failure.invalidToolOutputs }
    }

    private static func requestContext(_ request: WebModelResponseCodec.Request) throws -> (configuration: JSONValue, input: [JSONValue]) {
        guard request.continuationRequest.count <= WebModelResponseCodec.maximumPromptBytes else { throw Failure.contextLimitExceeded }
        var parser = JSONParser(request.continuationRequest)
        guard var object = try parser.parse().object,
              object["model"] == .text(request.model), let rawInput = object.removeValue(forKey: Data("input".utf8)) else {
            throw Failure.invalidContext
        }
        let input: [JSONValue]
        if let text = rawInput.textBytes {
            input = [.dictionary(["type": .text("message"), "role": .text("user"), "content": .array([.dictionary(["type": .text("input_text"), "text": .string(text)])])])]
        } else if let values = rawInput.array, values.allSatisfy({ $0.object != nil }) { input = values }
        else { throw Failure.invalidContext }
        guard input.count <= 1_024 else { throw Failure.contextLimitExceeded }
        return (.object(object), input)
    }

    /// These are exactly the pinned Core's serde omissions: Message and
    /// FunctionCall have no status field; OutputText has no annotations.
    /// CustomToolCall keeps status. Raw arguments and any supplied item IDs
    /// remain exact; validate(next:) separately admits the external projection's
    /// omission of a locally emitted FunctionCall.id.
    private static func nativeOutputItem(_ item: JSONValue) throws -> JSONValue {
        guard var fields = item.object, let type = fields["type"]?.string else { throw Failure.changedHistory }
        switch type {
        case "message":
            guard Set(fields.keys).isSubset(of: Set(["id", "type", "role", "status", "phase", "content"].map { Data($0.utf8) })),
                  fields["role"] == .text("assistant"),
                  [JSONValue.text("commentary"), .text("final_answer")].contains(fields["phase"] ?? .null),
                  let parts = fields["content"]?.array, !parts.isEmpty else { throw Failure.changedHistory }
            fields["content"] = .array(try parts.map { part in
                guard var value = part.object, Set(value.keys).isSubset(of: Set(["type", "text", "annotations"].map { Data($0.utf8) })),
                      value["type"] == .text("output_text"), value["text"]?.textBytes != nil else { throw Failure.changedHistory }
                if let annotations = value.removeValue(forKey: Data("annotations".utf8)), annotations != .array([]) { throw Failure.changedHistory }
                return .object(value)
            })
            if let status = fields.removeValue(forKey: Data("status".utf8)), status != .text("completed") { throw Failure.changedHistory }
        case "function_call", "custom_tool_call":
            let payload = type == "function_call" ? "arguments" : "input"
            guard Set(fields.keys).isSubset(of: Set(["id", "type", "status", "call_id", "name", "namespace", payload].map { Data($0.utf8) })),
                  fields["call_id"]?.textBytes != nil, fields["name"]?.textBytes != nil,
                  fields[payload]?.textBytes != nil,
                  fields["namespace"] == nil || fields["namespace"]?.textBytes != nil else { throw Failure.changedHistory }
            if type == "function_call", let status = fields.removeValue(forKey: Data("status".utf8)), status != .text("completed") { throw Failure.changedHistory }
            if type == "custom_tool_call", fields["status"] != .text("completed") { throw Failure.changedHistory }
        default: throw Failure.changedHistory
        }
        return .object(fields)
    }

    private static func isToolOutput(_ value: JSONValue) -> Bool {
        if value.textBytes != nil { return true }
        guard let parts = value.array else { return false }
        return parts.allSatisfy { part in
            guard let fields = part.object else { return false }
            return Set(fields.keys) == Set(["type", "text"].map { Data($0.utf8) }) && fields["type"] == .text("input_text") && fields["text"]?.textBytes != nil
        }
    }

    /// Core assigns these IDs when recording ResponseInputItem results into
    /// history (session/mod.rs). External FunctionCallOutput projection omits
    /// its record ID; this validates an ID only when one is supplied.
    /// They do not replace call_id authority. Once accepted, the entire result
    /// including this ID remains part of the immutable prefix for later rounds.
    private static func isNativeToolOutputID(_ bytes: Data, type: String) -> Bool {
        let prefix = type == "function_call_output" ? "fco_" : "ctco_"
        guard bytes.count == prefix.utf8.count + 36, let value = String(data: bytes, encoding: .utf8),
              value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        let uuidBytes = Array(suffix.utf8)
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix && uuidBytes[14] == 55 &&
            [56, 57, 97, 98].contains(uuidBytes[19])
    }

    private static func isNewUserMessage(_ item: JSONValue) -> Bool {
        guard let fields = item.object,
              Set(fields.keys).isSubset(of: Set(["id", "type", "role", "content"].map { Data($0.utf8) })),
              fields["type"] == .text("message"), fields["role"] == .text("user"),
              fields["id"] == nil || fields["id"]?.textBytes != nil,
              let content = fields["content"]?.array, !content.isEmpty else { return false }
        return content.allSatisfy { part in
            guard let fields = part.object, Set(fields.keys) == Set(["type", "text"].map { Data($0.utf8) }),
                  fields["type"] == .text("input_text"), let text = fields["text"]?.textBytes else { return false }
            return !text.isEmpty
        }
    }

    private static func completedResponse(_ data: Data, streamed: Bool) throws -> [Data: JSONValue] {
        guard data.count <= 1_024 * 1_024 else { throw Failure.contextLimitExceeded }
        if !streamed {
            var parser = JSONParser(data)
            guard let object = try parser.parse().object else { throw Failure.invalidResponse }
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidResponse }
        let records = text.components(separatedBy: "\n\n")
        guard records.count <= 520 else { throw Failure.contextLimitExceeded }
        var completed: [Data: JSONValue]?
        var sequence = 0
        var done = false
        for record in records where !record.isEmpty {
            if record == "data: [DONE]" {
                guard completed != nil, !done else { throw Failure.invalidResponse }
                done = true
                continue
            }
            guard !done, completed == nil else { throw Failure.invalidResponse }
            let lines = record.components(separatedBy: "\n")
            guard lines.count == 2, lines[0].hasPrefix("event: "), lines[1].hasPrefix("data: ") else { throw Failure.invalidResponse }
            var parser = JSONParser(Data(lines[1].dropFirst(6).utf8))
            guard let event = try parser.parse().object,
                  event["type"] == .text(String(lines[0].dropFirst(7))),
                  event["sequence_number"] == .number(JSONParser.canonicalNumber(String(sequence))) else { throw Failure.invalidResponse }
            if event["type"] == .text("response.completed") {
                guard let response = event["response"]?.object else { throw Failure.invalidResponse }
                completed = response
            }
            sequence += 1
        }
        guard done, let completed else { throw Failure.invalidResponse }
        return completed
    }
}

// Comparison never passes through Double or Foundation dictionary equality.
// Strings compare UTF-8 bytes; object keys compare decoded bytes; numbers use
// exact decimal coefficient/exponent normalization, without numeric rounding.
private indirect enum JSONValue: Equatable, Sendable {
    case object([Data: JSONValue]), array([JSONValue]), string(Data), number(String), bool(Bool), null
    static func text(_ value: String) -> Self { .string(Data(value.utf8)) }
    static func dictionary(_ value: [String: Self]) -> Self { .object(Dictionary(uniqueKeysWithValues: value.map { (Data($0.key.utf8), $0.value) })) }
    var object: [Data: Self]? { if case let .object(value) = self { value } else { nil } }
    var array: [Self]? { if case let .array(value) = self { value } else { nil } }
    var textBytes: Data? { if case let .string(value) = self { value } else { nil } }
    var string: String? { textBytes.flatMap { String(data: $0, encoding: .utf8) } }
    var boolean: Bool? { if case let .bool(value) = self { value } else { nil } }
    subscript(_ key: String) -> Self? { object?[Data(key.utf8)] }

    func encoded() -> Data {
        switch self {
        case let .object(value):
            var result = Data("{".utf8)
            for (index, key) in value.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }).enumerated() {
                if index > 0 { result.append(44) }
                result.append(Self.string(key).encoded()); result.append(58); result.append(value[key]!.encoded())
            }
            result.append(125); return result
        case let .array(value):
            var result = Data("[".utf8)
            for (index, item) in value.enumerated() { if index > 0 { result.append(44) }; result.append(item.encoded()) }
            result.append(93); return result
        case let .string(value):
            var result = Data([34]); let hex = Array("0123456789abcdef".utf8)
            for byte in value {
                if byte == 34 || byte == 92 { result.append(92); result.append(byte) }
                else if byte < 32 { result.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]]) }
                else { result.append(byte) }
            }
            result.append(34); return result
        case let .number(value): return Data(value.utf8)
        case let .bool(value): return Data((value ? "true" : "false").utf8)
        case .null: return Data("null".utf8)
        }
    }
}

private extension Dictionary where Key == Data, Value == JSONValue {
    subscript(_ key: String) -> JSONValue? {
        get { self[Data(key.utf8)] }
        set { self[Data(key.utf8)] = newValue }
    }
}

private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var nodes = 0
    init(_ data: Data) { bytes = Array(data) }

    mutating func parse() throws -> JSONValue {
        let value = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw WebsiteTurnContinuation.Failure.invalidContext }
        return value
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        nodes += 1
        guard depth <= 64, nodes <= 16_384 else { throw WebsiteTurnContinuation.Failure.contextLimitExceeded }
        whitespace()
        guard index < bytes.count else { throw WebsiteTurnContinuation.Failure.invalidContext }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var object: [Data: JSONValue] = [:]
            if consume(125) { return .object(object) }
            repeat {
                whitespace(); let key = try string(); whitespace()
                guard consume(58), object[key] == nil else { throw WebsiteTurnContinuation.Failure.invalidContext }
                object[key] = try value(depth: depth + 1); whitespace()
                if consume(125) { return .object(object) }
                guard consume(44) else { throw WebsiteTurnContinuation.Failure.invalidContext }
            } while true
        case 91:
            index += 1; whitespace(); var array: [JSONValue] = []
            if consume(93) { return .array(array) }
            repeat {
                array.append(try value(depth: depth + 1)); whitespace()
                if consume(93) { return .array(array) }
                guard consume(44) else { throw WebsiteTurnContinuation.Failure.invalidContext }
            } while true
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func string() throws -> Data {
        guard consume(34) else { throw WebsiteTurnContinuation.Failure.invalidContext }
        let start = index - 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                let token = Data(bytes[start..<index])
                guard let value = try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else { throw WebsiteTurnContinuation.Failure.invalidContext }
                return Data(value.utf8)
            }
            if byte == 92 {
                guard index < bytes.count else { throw WebsiteTurnContinuation.Failure.invalidContext }
                index += 1
            }
        }
        throw WebsiteTurnContinuation.Failure.invalidContext
    }

    private mutating func number() throws -> String {
        let start = index
        _ = consume(45)
        guard index < bytes.count else { throw WebsiteTurnContinuation.Failure.invalidContext }
        if consume(48) {
            guard index == bytes.count || !(48...57).contains(bytes[index]) else { throw WebsiteTurnContinuation.Failure.invalidContext }
        } else {
            guard (49...57).contains(bytes[index]) else { throw WebsiteTurnContinuation.Failure.invalidContext }
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }
        if consume(46) {
            let fraction = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard index > fraction else { throw WebsiteTurnContinuation.Failure.invalidContext }
        }
        if consume(101) || consume(69) {
            if !consume(45) { _ = consume(43) }
            let exponent = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard index > exponent else { throw WebsiteTurnContinuation.Failure.invalidContext }
        }
        guard index - start <= 128 else { throw WebsiteTurnContinuation.Failure.contextLimitExceeded }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        let exponent = token.lowercased().split(separator: "e", omittingEmptySubsequences: false).dropFirst().first
        if let exponent, (Int(exponent) == nil || !(-4_096...4_096).contains(Int(exponent)!)) { throw WebsiteTurnContinuation.Failure.contextLimitExceeded }
        return Self.canonicalNumber(token)
    }

    static func canonicalNumber(_ token: String) -> String {
        var value = token.lowercased()
        let negative = value.hasPrefix("-"); if negative { value.removeFirst() }
        let parts = value.split(separator: "e", omittingEmptySubsequences: false)
        var exponent = parts.count == 2 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        if mantissa.count == 2 { exponent -= mantissa[1].count }
        var digits = mantissa.joined()
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        while digits.last == "0" { digits.removeLast(); exponent += 1 }
        return (negative ? "-" : "") + digits + "e" + String(exponent)
    }

    private mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func consume(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
    private mutating func literal(_ value: String) throws {
        let token = Array(value.utf8)
        guard index + token.count <= bytes.count, Array(bytes[index..<index + token.count]) == token else { throw WebsiteTurnContinuation.Failure.invalidContext }
        index += token.count
    }
}
