import Foundation

/// A declared function transports one native custom-tool string without
/// interpreting, compiling or changing the native text/grammar contract.
enum LiteralCustomToolTransport {
    enum Failure: Error { case invalidTool }
    static let inputDescription = "Literal native tool input. Follow the exact text or grammar contract in this function's description, including delimiters and newlines. Encode the contents once as this JSON string; do not add quoting, JSON, shell syntax or Markdown fences unless the native contract requires them."

    static func inputSchema(description: String, pattern: String? = nil) -> [String: Any] {
        var input: [String: Any] = ["type": "string", "description": description]
        if let pattern { input["pattern"] = pattern }
        return ["type": "object", "properties": ["input": input], "required": ["input"], "additionalProperties": false]
    }

    static func description(for definition: [String: Any]) throws -> String {
        let original = definition["description"] as? String ?? ""
        guard original.utf8.count <= 64_000 else { throw Failure.invalidTool }
        let format: [String: Any]
        if let supplied = definition["format"] {
            guard let value = supplied as? [String: Any] else { throw Failure.invalidTool }; format = value
        } else { format = ["type": "text"] }
        let contract: String
        switch format["type"] as? String {
        case "text":
            guard Set(format.keys) == ["type"] else { throw Failure.invalidTool }
            contract = "The native tool accepts raw text."
        case "grammar":
            guard Set(format.keys) == ["type", "syntax", "definition"], let syntax = format["syntax"] as? String,
                  ["lark", "regex"].contains(syntax), let grammar = format["definition"] as? String,
                  !grammar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  grammar.utf8.count <= 16_384 else { throw Failure.invalidTool }
            // Preserve the native contract verbatim. The gateway does not claim
            // to implement provider-side constrained decoding or a Lark parser.
            contract = "The decoded input string must satisfy this native \(syntax) grammar. Grammar definition (verbatim):\n\(grammar)"
        default: throw Failure.invalidTool
        }
        let description = original + "\n\nCustom tool transport: call this function with exactly one string argument named input. The JSON object is only the transport wrapper; the decoded input string is passed unchanged to the native custom tool. Any instruction above to use freeform input or not wrap it in JSON applies to that string's contents, not the transport object. Do not add another layer of JSON encoding inside input.\n" + contract
        guard description.utf8.count <= 64_000 else { throw Failure.invalidTool }
        return description
    }

    static func literalInput(in arguments: [String: Any]) -> String? {
        guard Set(arguments.keys) == ["input"] else { return nil }
        return arguments["input"] as? String
    }
}
