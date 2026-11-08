import CryptoKit
import Foundation

/// Alibaba Chat Completions supplies JSON arguments. Only the exact bundled
/// apply_patch tool opts into this representation. Native patch execution,
/// source matching, permission checks and tool results remain authoritative.
enum AlibabaPatchProjection: Sendable, Equatable {
    case local, environments

    static func matching(_ definition: [String: Any], namespace: String?) -> Self? {
        guard namespace == nil || namespace == "functions",
            Set(definition.keys) == ["type", "name", "description", "format"], definition["type"] as? String == "custom",
            definition["name"] as? String == "apply_patch",
            definition["description"] as? String
                == "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.",
            let format = definition["format"] as? [String: Any], Set(format.keys) == ["type", "syntax", "definition"],
            format["type"] as? String == "grammar", format["syntax"] as? String == "lark",
            let grammar = format["definition"] as? String, grammar.utf8.count <= 16_384
        else { return nil }
        // Exact bytes of core/assets/tools/apply_patch.lark and its environment
        // variant produced by core/src/tools/handlers/apply_patch_spec.rs.
        let hash = SHA256.hash(data: Data(grammar.utf8)).map { String(format: "%02x", $0) }.joined()
        switch hash {
        case "d6367f4826ed608c424b0a308f3d6163527df63c22513d089b91863552f8bfeb": return .local
        case "2c1d2069867f720f53f5c8e08100287d56c0b4818e2921067de5c6614fb7ca5e": return .environments
        default: return nil
        }
    }

    // One contract is supplied initially and in the existing single correction.
    // It describes provider arguments; native execution still receives literal
    // compiled input and retains its own grammar, permissions and source checks.
    static let argumentContract = """
        Supply one JSON arguments object. operations is an array of operation objects, even for one file; never a JSON-encoded array or patch string.
        An update uses update (observed absolute path), hunks (array), and each hunk's lines (array of strings). Each lines element is one source line: ASCII space (keep), + (add), or - (remove), then exact source characters including indentation. Blank source lines are " ", "+", or "-". No element may contain decoded CR, LF or NUL.
        For add, supply add and unprefixed lines. Delete uses delete. Only update may use move_to. An optional anchor is exact observed context; empty means unnamed; later hunks need an anchor. end_of_file is true only to anchor the last hunk at EOF.
        Computa emits native headers and @@ markers; do not add separate patch control records. Replace example paths/lines with observed source. Prior native custom calls remain original literal input in history, not examples of this function's JSON arguments.
        """

    static let updateExample = #"{"operations":[{"update":"/absolute/path/file.py","hunks":[{"lines":[" def f():","-    old()","+    new()"," "]}]}]}"#

    static let description = argumentContract + "\nExample update: " + updateExample
    static let argumentDirections = argumentContract + "\nExample update: " + updateExample + "\nThe native grammar checks below apply to the compiled patch; supply the JSON arguments object described above."

    private static let developerVariants: [Data: String] = {
        var result: [Data: String] = [:]
        for references in [false, true] {
            for browser in [false, true] {
                let original = ComputaAgentInstructions.developerInstructions(referenceTools: references, embeddedBrowserTools: browser)
                result[Data(original.utf8)] = ComputaAgentInstructions.developerInstructions(referenceTools: references,
                    embeddedBrowserTools: browser, compiledPatchInput: argumentDirections)
            }
        }
        return result
    }()

    static func projectedDeveloperText(_ text: String) -> String {
        developerVariants[Data(text.utf8)] ?? text
    }

    var schema: [String: Any] {
        func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        let line: [String: Any] = ["type": "string", "pattern": #"^[^\r\n\u0000]*$"#]
        let path: [String: Any] = ["type": "string", "minLength": 1, "pattern": #"^[^\r\n\u0000]+$"#]
        func nonemptyArray(of type: [String: Any]) -> [String: Any] { ["type": "array", "items": type, "minItems": 1] }
        let hunk = object(
            ["anchor": line, "lines": nonemptyArray(of: ["type": "string", "pattern": #"^[ +\-][^\r\n\u0000]*$"#,
                "description": "One source line with space/+/- prefix; preserve following indentation. Blank uses prefix alone. No CR/LF/NUL."])],
            ["lines"])
        let update = object(
            [
                "update": path, "move_to": path, "hunks": nonemptyArray(of: hunk),
                "end_of_file": ["type": "boolean", "enum": [true]],
            ], ["update", "hunks"])
        var operations = nonemptyArray(of: [
            "oneOf": [
                object(["add": path, "lines": nonemptyArray(of: line)], ["add", "lines"]),
                object(["delete": path], ["delete"]), update,
            ]
        ])
        operations["description"] = "An actual JSON array, not a JSON-encoded string. Follow the complete contract and example in the tool description."
        var fields: [String: Any] = ["operations": operations]
        if self == .environments { fields["environment_id"] = path }
        return object(fields, ["operations"])
    }

    /// The codec validates the exact schema before calling this function. Reject values
    /// that would be split or silently trimmed in the native Rust parser.
    func compile(_ value: [String: Any], byteLimit: Int) -> String? {
        func literal(_ value: String) -> Bool { !value.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 } }
        func header(_ value: String) -> Bool {
            !value.isEmpty && literal(value) && value.unicodeScalars.last?.properties.isWhitespace == false
        }
        var patch = "*** Begin Patch\n"
        if let environment = value["environment_id"] as? String {
            guard self == .environments, header(environment),
                environment.unicodeScalars.first?.properties.isWhitespace == false
            else { return nil }
            patch += "*** Environment ID: " + environment + "\n"
        }
        guard let operations = value["operations"] as? [[String: Any]], !operations.isEmpty else { return nil }
        for op in operations {
            if let path = op["add"] as? String {
                guard header(path), let source = op["lines"] as? [String], !source.isEmpty else { return nil }
                patch += "*** Add File: " + path + "\n"
                for line in source {
                    guard literal(line) else { return nil }
                    patch += "+" + line + "\n"
                }
            } else if let path = op["delete"] as? String {
                guard header(path) else { return nil }
                patch += "*** Delete File: " + path + "\n"
            } else {
                guard let path = op["update"] as? String, header(path),
                    let hunks = op["hunks"] as? [[String: Any]], !hunks.isEmpty
                else { return nil }
                patch += "*** Update File: " + path + "\n"
                if let move = op["move_to"] as? String {
                    guard header(move) else { return nil }
                    patch += "*** Move to: " + move + "\n"
                }
                for (index, hunk) in hunks.enumerated() {
                    if let anchor = hunk["anchor"] as? String {
                        guard anchor.isEmpty || header(anchor) else { return nil }
                        patch += (anchor.isEmpty ? "@@" : "@@ " + anchor) + "\n"
                    } else if index != 0 {
                        return nil
                    }
                    guard let source = hunk["lines"] as? [String], !source.isEmpty else { return nil }
                    for line in source {
                        guard literal(line), let byte = line.utf8.first, byte == 32 || byte == 43 || byte == 45 else {
                            return nil
                        }
                        patch += line + "\n"
                    }
                }
                if op["end_of_file"] as? Bool == true { patch += "*** End of File\n" }
            }
        }
        patch += "*** End Patch"
        return patch.utf8.count <= byteLimit ? patch : nil
    }
}
