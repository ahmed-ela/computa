import Foundation

struct RoutedConversationReply: Sendable {
    let session: String
    let model: String
    let text: String
}

actor RoutedACPResponse {
    private var session: String?
    private var connection: AgentCLIConnection?
    private var model: String?
    private var configID: String?
    private var modelChanged = false
    private var text = ""
    private var usedTool = false
    func attach(_ connection: AgentCLIConnection) { self.connection = connection }
    func expect(_ session: String, model: String, configID: String?) {
        self.session = session
        self.model = model
        self.configID = configID
    }

    func receive(_ frame: Data) async {
        guard let message = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let method = message["method"] as? String else { return }
        if let id = message["id"], let connection {
            let response: [String: Any]
            if method == "session/request_permission" {
                usedTool = true
                response = ["id": id, "jsonrpc": "2.0", "result": ["outcome": ["outcome": "cancelled"]]]
            } else {
                response = ["id": id, "jsonrpc": "2.0", "error": ["code": -32601, "message": "Unsupported in a conversation reply"]]
            }
            if let bytes = try? JSONSerialization.data(withJSONObject: response) { try? await connection.send(bytes) }
            return
        }
        guard method == "session/update", let session, let params = message["params"] as? [String: Any],
              params["sessionId"] as? String == session, let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "config_option_update":
            if let configID, let controls = update["configOptions"] as? [[String: Any]],
               let value = controls.first(where: { $0["id"] as? String == configID })?["currentValue"] as? String,
               value != model { modelChanged = true }
        case "tool_call", "tool_call_update": usedTool = true
        case "agent_message_chunk":
            if let part = update["content"] as? [String: Any], part["type"] as? String == "text", let chunk = part["text"] as? String { text += chunk }
        default: break
        }
    }

    func result() throws -> String {
        guard !modelChanged else { throw AgentCLIError.protocolError("The provider switched models during the reply.") }
        guard !usedTool else { throw AgentCLIError.unavailable("The provider requested a tool during a conversation-only reply.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentCLIError.protocolError("The provider returned an empty reply.") }
        return text
    }
}
