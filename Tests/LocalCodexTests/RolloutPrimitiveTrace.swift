import Foundation

struct RolloutPrimitiveTrace {
    struct FunctionCall {
        let callID: String
        let name: String
        let arguments: [String: Any]

        var action: String? {
            arguments["action"] as? String
        }

        var parameters: [String: Any] {
            arguments["parameters"] as? [String: Any] ?? [:]
        }
    }

    struct FunctionCallOutput {
        let callID: String
        let output: Any
    }

    let rolloutURL: URL
    let dynamicTools: [[String: Any]]
    let functionCalls: [FunctionCall]
    let functionCallOutputs: [FunctionCallOutput]
    let assistantMessages: [String]
    let parseFailures: [String]

    static func loadLatest(in codexHomePath: String) throws -> RolloutPrimitiveTrace {
        let sessionsURL = URL(fileURLWithPath: codexHomePath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw TraceError.noRollout(sessionsURL.path)
        }

        var candidates = [(url: URL, modifiedAt: Date)]()
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-")
            && url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }

        guard let rolloutURL = candidates.max(by: { $0.modifiedAt < $1.modifiedAt })?.url else {
            throw TraceError.noRollout(sessionsURL.path)
        }
        return try load(rolloutURL)
    }

    static func load(_ rolloutURL: URL) throws -> RolloutPrimitiveTrace {
        let data = try Data(contentsOf: rolloutURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TraceError.notUTF8(rolloutURL.path)
        }

        var dynamicTools = [[String: Any]]()
        var functionCalls = [FunctionCall]()
        var functionCallOutputs = [FunctionCallOutput]()
        var assistantMessages = [String]()
        var parseFailures = [String]()

        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let lineData = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let recordType = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any]
            else {
                parseFailures.append("line \(offset + 1) was not a rollout record")
                continue
            }

            if recordType == "session_meta" {
                if let tools = payload["dynamic_tools"] as? [[String: Any]] {
                    dynamicTools = tools
                }
                continue
            }

            guard recordType == "response_item", let itemType = payload["type"] as? String else {
                continue
            }

            switch itemType {
            case "function_call":
                guard let callID = payload["call_id"] as? String,
                      !callID.isEmpty,
                      let name = payload["name"] as? String,
                      let encodedArguments = payload["arguments"] as? String,
                      let argumentData = encodedArguments.data(using: .utf8),
                      let arguments = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any]
                else {
                    parseFailures.append("line \(offset + 1) had a malformed function_call")
                    continue
                }
                functionCalls.append(
                    FunctionCall(callID: callID, name: name, arguments: arguments)
                )

            case "function_call_output":
                guard let callID = payload["call_id"] as? String,
                      !callID.isEmpty,
                      let output = payload["output"]
                else {
                    parseFailures.append("line \(offset + 1) had a malformed function_call_output")
                    continue
                }
                functionCallOutputs.append(FunctionCallOutput(callID: callID, output: output))

            case "message":
                guard payload["role"] as? String == "assistant",
                      let content = payload["content"] as? [[String: Any]]
                else { continue }
                assistantMessages.append(contentsOf: content.compactMap { part in
                    guard part["type"] as? String == "output_text" else { return nil }
                    return part["text"] as? String
                })

            default:
                break
            }
        }

        return RolloutPrimitiveTrace(
            rolloutURL: rolloutURL,
            dynamicTools: dynamicTools,
            functionCalls: functionCalls,
            functionCallOutputs: functionCallOutputs,
            assistantMessages: assistantMessages,
            parseFailures: parseFailures
        )
    }

    func output(for callID: String) -> Any? {
        functionCallOutputs.first(where: { $0.callID == callID })?.output
    }

    enum TraceError: LocalizedError {
        case noRollout(String)
        case notUTF8(String)

        var errorDescription: String? {
            switch self {
            case .noRollout(let path):
                "No rollout JSONL was found under \(path)."
            case .notUTF8(let path):
                "The rollout at \(path) was not UTF-8 JSONL."
            }
        }
    }
}
