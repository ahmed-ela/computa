import Foundation

/// Presentation-only projection/accounting for an already admitted JSON request.
/// Retained instructions, schemas, values, escapes and ordering are unchanged.
enum WebsitePromptProjection {
    /// These configure the native API transport/response, not website tasks.
    /// Validation and the canonical request remain owned by the caller.
    private static let apiOnlyFields: Set<String> = [
        "include", "reasoning", "client_metadata", "prompt_cache_key", "metadata", "safety_identifier",
        "stream", "stream_options", "store", "background", "service_tier",
    ]

    /// Remove only whole top-level members, retaining every other source slice.
    /// The caller already admitted a JSON object. Decode keys only: rebuilding
    /// values would alter numeric lexemes, escapes or duplicate foreign keys.
    static func omittingAPIOnlyTopLevelFields(_ source: String) -> String {
        let bytes = Array(source.utf8)
        guard let opening = bytes.firstIndex(of: 123), let closing = bytes.lastIndex(of: 125),
              opening < closing else { return source }
        var depth = 1, start = opening + 1
        var colon: Int?
        var inString = false, escaped = false, removed = false
        var retained: [Range<Int>] = []
        func record(end: Int) {
            guard let colon, start < colon,
                  let key = try? JSONSerialization.jsonObject(with: Data(bytes[start..<colon]), options: .fragmentsAllowed) as? String else { return }
            if apiOnlyFields.contains(key) { removed = true }
            else { retained.append(start..<end) }
        }
        for index in (opening + 1)...closing {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                if depth == 1 { record(end: index) }
                depth -= 1
            } else if depth == 1 && byte == 58 { colon = index }
            else if depth == 1 && byte == 44 {
                record(end: index); start = index + 1; colon = nil
            }
        }
        guard removed else { return source }
        var result = Array(bytes[...opening])
        for (index, range) in retained.enumerated() {
            if index > 0 { result.append(44) }
            result.append(contentsOf: bytes[range])
        }
        result.append(contentsOf: bytes[closing...])
        return String(decoding: result, as: UTF8.self)
    }

    enum InputAppendFailure: Error { case invalidInput }

    /// Append native-only preview items without decoding/re-encoding retained
    /// history. Every original member/number/string lexeme stays byte-identical.
    static func appendingInputItems(_ items: [[String: Any]], to source: Data) throws -> Data {
        let bytes = Array(source), whitespace: Set<UInt8> = [9, 10, 13, 32]
        guard !items.isEmpty, let object = try? JSONSerialization.jsonObject(with: source), object is [String: Any],
              let opening = bytes.firstIndex(of: 123), let closing = bytes.lastIndex(of: 125), opening < closing else {
            throw InputAppendFailure.invalidInput
        }
        var depth = 1, start = opening + 1, colon: Int?
        var inString = false, escaped = false, ranges: [Range<Int>] = []
        func record(end: Int) {
            guard let colon, start < colon,
                  let key = try? JSONSerialization.jsonObject(with: Data(bytes[start..<colon]), options: .fragmentsAllowed) as? String,
                  key == "input" else { return }
            var lower = colon + 1, upper = end
            while lower < upper, whitespace.contains(bytes[lower]) { lower += 1 }
            while lower < upper, whitespace.contains(bytes[upper - 1]) { upper -= 1 }
            if lower < upper { ranges.append(lower..<upper) }
        }
        for index in (opening + 1)...closing {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 { if depth == 1 { record(end: index) }; depth -= 1 }
            else if depth == 1 && byte == 58 { colon = index }
            else if depth == 1 && byte == 44 { record(end: index); start = index + 1; colon = nil }
        }
        guard ranges.count == 1, let input = ranges.first else { throw InputAppendFailure.invalidInput }
        let encoded = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes])
        let addition = encoded.dropFirst().dropLast() // Only new native items were encoded.
        if bytes[input.lowerBound] == 91, bytes[input.upperBound - 1] == 93 {
            let closing = input.upperBound - 1
            var result = Data(bytes[..<closing])
            if bytes[(input.lowerBound + 1)..<closing].contains(where: { !whitespace.contains($0) }) { result.append(44) }
            result.append(contentsOf: addition); result.append(contentsOf: bytes[closing...])
            return result
        }
        guard bytes[input.lowerBound] == 34, bytes[input.upperBound - 1] == 34 else { throw InputAppendFailure.invalidInput }
        var result = Data(bytes[..<input.lowerBound])
        result.append(contentsOf: #"[{"role":"user","content":"#.utf8)
        result.append(contentsOf: bytes[input]); result.append(contentsOf: "},".utf8)
        result.append(contentsOf: addition); result.append(93); result.append(contentsOf: bytes[input.upperBound...])
        return result
    }

    struct Components: Equatable, Sendable {
        let inputJSONBytes: Int
        let toolsJSONBytes: Int
        let instructionsJSONBytes: Int
        /// Includes all other entries plus the outer braces and commas.
        let otherJSONBytes: Int
    }

    struct Statistics: Codable, Equatable, Sendable {
        let originalRequestBytes: Int
        let sourceRequestBytes: Int
        let compactRequestBytes: Int
        let presentedRequestBytes: Int
        let outerContractBytes: Int
        let runtimeBytes: Int
        let requestContextBytes: Int
        let currentUserBytes: Int
        let responseContractBytes: Int
        let framingBytes: Int
        let finalPromptBytes: Int
        let inputJSONBytes: Int
        let toolsJSONBytes: Int
        let instructionsJSONBytes: Int
        let otherJSONBytes: Int

        var diagnostic: String {
            "originalRequestBytes=\(originalRequestBytes) sourceRequestBytes=\(sourceRequestBytes) compactRequestBytes=\(compactRequestBytes) presentedRequestBytes=\(presentedRequestBytes) outerContractBytes=\(outerContractBytes) runtimeBytes=\(runtimeBytes) requestContextBytes=\(requestContextBytes) currentUserBytes=\(currentUserBytes) responseContractBytes=\(responseContractBytes) framingBytes=\(framingBytes) finalPromptBytes=\(finalPromptBytes) inputJSONBytes=\(inputJSONBytes) toolsJSONBytes=\(toolsJSONBytes) instructionsJSONBytes=\(instructionsJSONBytes) otherJSONBytes=\(otherJSONBytes)"
        }
    }

    struct RequestJSON: Sendable {
        let json: String
        let sourceBytes: Int
        let components: Components

        func statistics(originalRequestBytes: Int, presentedRequestBytes: Int, runtimeBytes: Int,
                        requestContextBytes: Int, currentUserBytes: Int, responseContractBytes: Int,
                        finalPromptBytes: Int) -> Statistics {
            Statistics(originalRequestBytes: originalRequestBytes, sourceRequestBytes: sourceBytes,
                compactRequestBytes: json.utf8.count, presentedRequestBytes: presentedRequestBytes,
                outerContractBytes: finalPromptBytes - presentedRequestBytes,
                runtimeBytes: runtimeBytes, requestContextBytes: requestContextBytes, currentUserBytes: currentUserBytes,
                responseContractBytes: responseContractBytes,
                framingBytes: finalPromptBytes - presentedRequestBytes - runtimeBytes - requestContextBytes - currentUserBytes - responseContractBytes,
                finalPromptBytes: finalPromptBytes,
                inputJSONBytes: components.inputJSONBytes, toolsJSONBytes: components.toolsJSONBytes,
                instructionsJSONBytes: components.instructionsJSONBytes, otherJSONBytes: components.otherJSONBytes)
        }
    }

    /// The caller has already validated the complete JSON object and its size.
    /// Lexical compaction avoids a parse/reserialize changing number lexemes,
    /// duplicate keys, escape spellings, string whitespace or custom grammars.
    static func compactValidatedJSON(_ source: String) -> RequestJSON {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.utf8.count)
        var inString = false
        var escaped = false
        for byte in source.utf8 {
            if inString {
                bytes.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 {
                bytes.append(byte)
                inString = true
            } else if ![9, 10, 13, 32].contains(byte) {
                bytes.append(byte)
            }
        }
        return RequestJSON(json: String(decoding: bytes, as: UTF8.self), sourceBytes: source.utf8.count,
                           components: components(in: bytes))
    }

    private static func components(in bytes: [UInt8]) -> Components {
        var input = 0, tools = 0, instructions = 0
        var depth = 0, start = 1
        var colon: Int?
        var inString = false, escaped = false
        func record(end: Int) {
            guard let colon, start < colon, colon < end,
                  let key = try? JSONSerialization.jsonObject(with: Data(bytes[start..<colon]), options: .fragmentsAllowed) as? String else { return }
            let count = end - start
            switch key {
            case "input": input += count
            case "tools": tools += count
            case "instructions": instructions += count
            default: break
            }
        }
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                if depth == 1 { record(end: index) }
                depth -= 1
            } else if depth == 1 && byte == 58 { colon = index }
            else if depth == 1 && byte == 44 {
                record(end: index)
                start = index + 1
                colon = nil
            }
        }
        return Components(inputJSONBytes: input, toolsJSONBytes: tools, instructionsJSONBytes: instructions,
                          otherJSONBytes: bytes.count - input - tools - instructions)
    }
}
