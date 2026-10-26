import Foundation

/// Presentation-only accounting for an already admitted JSON request. No
/// instruction, schema, string value, escape, number or key ordering is changed.
enum WebsitePromptProjection {
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
