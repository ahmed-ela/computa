import Foundation

struct AppServerWireTrace {
    enum Direction: String {
        case clientToServer = "client_to_server"
        case serverToClient = "server_to_client"
    }

    struct Message {
        let sequence: Int
        let direction: Direction
        let wireData: Data
        let object: [String: Any]

        var method: String? {
            object["method"] as? String
        }

        var identifier: String? {
            AppServerWireTrace.normalizedIdentifier(object["id"])
        }
    }

    let messages: [Message]
    let parseFailures: [String]

    static func load(_ url: URL) throws -> AppServerWireTrace {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TraceError.notUTF8(url.path)
        }

        var messages = [Message]()
        var parseFailures = [String]()
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let lineData = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sequence = (record["sequence"] as? NSNumber)?.intValue,
                  let rawDirection = record["direction"] as? String,
                  let direction = Direction(rawValue: rawDirection),
                  let encodedWire = record["wireBase64"] as? String,
                  let wireData = Data(base64Encoded: encodedWire),
                  wireData.last == 0x0A,
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(wireData.dropLast())
                  ) as? [String: Any]
            else {
                parseFailures.append("line \(offset + 1) was not a valid wire record")
                continue
            }
            messages.append(
                Message(
                    sequence: sequence,
                    direction: direction,
                    wireData: wireData,
                    object: object
                )
            )
        }

        return AppServerWireTrace(messages: messages, parseFailures: parseFailures)
    }

    static func normalizedIdentifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            return "integer:\(number.int64Value)"
        }
        if let string = value as? String {
            return "string:\(string)"
        }
        return nil
    }

    enum TraceError: LocalizedError {
        case notUTF8(String)

        var errorDescription: String? {
            switch self {
            case .notUTF8(let path):
                "The App Server wire trace at \(path) was not UTF-8 JSONL."
            }
        }
    }
}
