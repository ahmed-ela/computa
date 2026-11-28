import Foundation

/// An imported chat gets an independent ephemeral Codex session. The source
/// thread identifier is deliberately absent from this interface.
enum ImportedCodexReply {
    static func run(_ prompt: String, model: String, directory: URL, profile: URL) async throws -> RoutedConversationReply {
        guard let slug = InstalledCodexCLI.slug(model) else { throw InstalledCodexCLI.Failure.unavailable }
        let work = directory.appendingPathComponent("ImportedReplies/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let binary = try await InstalledCodexCLI.executable()
        var env = ProcessInfo.processInfo.environment.filter {
            ["HOME", "TMPDIR", "PATH", "LANG", "USER", "LOGNAME"].contains($0.key)
        }
        env["CODEX_HOME"] = profile.path
        let frames = AsyncStream<Data>.makeStream()
        let conn = try AgentCLIConnection(
            executable: binary,
            arguments: InstalledCodexCLI.arguments + [
                "-c", "features.shell_tool=false", "-c", "web_search=\"disabled\"",
            ], directory: work, environment: env, codexProtocol: true, onClose: { frames.continuation.finish() }
        ) { frames.continuation.yield($0) }
        defer { frames.continuation.finish() }
        func rpc(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
            let bytes = try JSONSerialization.data(withJSONObject: args)
            let data = try await conn.request(method, params: bytes, timeout: .seconds(30))
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentCLIError.protocolError("Unreadable Codex reply.")
            }
            return reply
        }
        do {
            _ = try await rpc(
                "initialize",
                ["clientInfo": ["name": "kolmogor_import", "version": "1"], "capabilities": ["experimentalApi": true]])
            try await conn.send(Data(#"{"method":"initialized"}"#.utf8))
            let start = try await rpc(
                "thread/start",
                [
                    "model": slug, "modelProvider": "openai", "allowProviderModelFallback": false,
                    "ephemeral": true, "cwd": work.path, "environments": [], "selectedCapabilityRoots": [],
                    "sandbox": "read-only", "approvalPolicy": "never",
                    "baseInstructions": "Reply to the user's conversation. Use no tools.",
                ])
            guard start["model"] as? String == slug, start["modelProvider"] as? String == "openai",
                let newThread = start["thread"] as? [String: Any], newThread["ephemeral"] as? Bool == true,
                let thread = newThread["id"] as? String
            else { throw InstalledCodexCLI.Failure.unavailable }
            let receipt = try await rpc(
                "turn/start", ["threadId": thread, "model": slug, "input": [["type": "text", "text": prompt]]])
            guard let turn = (receipt["turn"] as? [String: Any])?["id"] as? String else {
                throw CodexDesktopSidebarClient.Failure.deliveryUnconfirmed
            }
            let answer = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    var answers: [String] = []
                    for await data in frames.stream {
                        guard let msg = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let method = msg["method"] as? String, let params = msg["params"] as? [String: Any],
                            params["threadId"] as? String == thread
                        else { continue }
                        if method == "model/rerouted" || method == "model/reroute" { throw InstalledCodexCLI.Failure.unavailable }
                        if method == "item/completed", params["turnId"] as? String == turn,
                            let item = params["item"] as? [String: Any]
                        {
                            if item["type"] as? String == "agentMessage", item["phase"] as? String != "commentary",
                                let text = item["text"] as? String
                            {
                                answers.append(text)
                            } else if !["reasoning", "agentMessage", "userMessage"].contains(item["type"] as? String ?? "") {
                                throw AgentCLIError.unavailable("Codex requested a tool during a conversation-only reply.")
                            }
                        }
                        if method == "turn/completed", let end = params["turn"] as? [String: Any], end["id"] as? String == turn {
                            let text = answers.joined(separator: "\n")
                            guard end["status"] as? String == "completed",
                                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else { throw CodexDesktopSidebarClient.Failure.deliveryUnconfirmed }
                            return text
                        }
                    }
                    throw CodexDesktopSidebarClient.Failure.deliveryUnconfirmed
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(180))
                    throw CodexDesktopSidebarClient.Failure.deliveryUnconfirmed
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await conn.close()
            return RoutedConversationReply(session: thread, model: model, text: answer)
        } catch {
            await conn.close()
            throw error
        }
    }
}
