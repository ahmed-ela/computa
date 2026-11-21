import Foundation

/// ACP session identifiers belong to the agent. The transcript and the task ID belong to Computa.
actor ProviderCLIChats {
    struct Record: Codable {
        var task: AgentTask
        var session: String
    }
    struct Turn {
        var id = UUID().uuidString
        var connection: AgentCLIConnection?
        var session: String?
        var answer = ""
        var tools: [String: TimelineEntry] = [:]
        var item = UUID().uuidString
        var acceptingUpdates = false
    }
    struct Permission {
        let taskID: String
        let turnID: String
        let rpcID: Data
        let allow: String?
        let deny: String?
    }

    let root: URL
    private let searchDirectories: [String]
    private let publish: @Sendable (AgentRuntimeEvent) -> Void
    private var records: [String: Record] = [:]
    private var directories: [String: String] = [:]
    private var active: [String: Turn] = [:]
    private var permissions: [String: Permission] = [:]
    private var discoveries: [UUID: AgentCLIConnection] = [:]
    private var shuttingDown = false

    init(root: URL, searchDirectories: [String] = ProviderCLI.directories(), publish: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.root = root
        self.searchDirectories = searchDirectories
        self.publish = publish
    }

    private func save(_ record: Record) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent(record.task.id + ".json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        records[record.task.id] = record
    }

    func load() throws -> [AgentTask] {
        if !FileManager.default.fileExists(atPath: root.path) { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            var row = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard row.task.id == file.deletingPathExtension().lastPathComponent, ProviderCLI(modelID: row.task.model) != nil,
                  active[row.task.id] == nil else { continue }
            if row.task.status == .running || row.task.status == .waiting {
                row.task.status = .failed
                row.task.entries.append(.init(kind: .system, title: "CLI session interrupted",
                    body: "Computa closed before the CLI confirmed this turn."))
                try save(row)
            } else { records[row.task.id] = row }
        }
        return records.values.map(\.task)
    }

    func setDirectory(_ path: String, for id: String) { directories[id] = path }

    private func check(_ id: String, _ turnID: String) throws {
        guard !shuttingDown, active[id]?.id == turnID else { throw AgentCLIError.cancelled }
    }

    private func rpc(_ conn: AgentCLIConnection, _ method: String, _ params: [String: Any],
                     timeout: Duration = .seconds(40)) async throws -> [String: Any] {
        let result = try await conn.request(method, params: JSONSerialization.data(withJSONObject: params), timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw AgentCLIError.protocolError("Invalid CLI response to " + method)
        }
        return object
    }

    private func connection(_ provider: ProviderCLI, directory: URL, handler: @escaping AgentCLIConnection.MessageHandler) throws -> AgentCLIConnection {
        guard let executable = ProviderCLI.locate(provider.executable, directories: searchDirectories) else { throw AgentCLIError.unavailable("Install " + provider.name + " to use this chat.") }
        var environment = AgentRuntimeIsolation.environment(inheriting: ProcessInfo.processInfo.environment,
            userHomePath: FileManager.default.homeDirectoryForCurrentUser.path, codexHomePath: root.path)
        environment.removeValue(forKey: "CODEX_HOME")
        environment["PATH"] = searchDirectories.joined(separator: ":")
        if provider == .claude {
            guard let claude = ProviderCLI.locate("claude", directories: searchDirectories) else { throw AgentCLIError.unavailable("Install Claude Code and run claude auth login.") }
            // Claude Code uses the macOS short user name to locate its Keychain login.
            environment["USER"] = NSUserName()
            environment["CLAUDE_CODE_EXECUTABLE"] = claude.path
        }
        // Pass only the credential intended for that provider, when explicitly supplied to Computa.
        let credential: String? = switch provider { case .deepseek: "DEEPSEEK_API_KEY"; case .gemini: "GEMINI_API_KEY"; default: nil }
        if let credential { environment[credential] = ProcessInfo.processInfo.environment[credential] }
        return try AgentCLIConnection(executable: executable, arguments: provider.arguments, directory: directory,
                                      environment: environment, handler: handler)
    }

    private func initialize(_ conn: AgentCLIConnection) async throws -> [String: Any] {
        let result = try await rpc(conn, "initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any](),
            "clientInfo": ["name": "computa", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"]])
        guard result["protocolVersion"] as? Int == 1 else { throw AgentCLIError.protocolError("Unsupported CLI protocol version.") }
        return result
    }

    func models(_ provider: ProviderCLI) async throws -> [LocalModelOption] {
        guard !shuttingDown else { throw AgentCLIError.cancelled }
        let directory = root.appendingPathComponent("Discovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let conn = try connection(provider, directory: directory) { _ in }
        let discovery = UUID()
        discoveries[discovery] = conn
        defer { discoveries.removeValue(forKey: discovery) }
        do {
            _ = try await initialize(conn)
            let config = try await rpc(conn, "session/new", ["cwd": directory.path, "mcpServers": [Any]()])
            var seen = Set<String>()
            let options = AgentCLIModels(session: config).entries.compactMap { row -> LocalModelOption? in
                let id = provider.route + "/model/" + row.id
                guard ProviderCLI.slug(id) != nil, seen.insert(id).inserted else { return nil }
                return LocalModelOption(id: id, label: provider.name + " / " + row.label, detail: row.id, highMemory: false)
            }
            await conn.close()
            return options
        } catch { await conn.close(); throw error }
    }

    func submit(_ prompt: String, id: String, provider: ProviderCLI, modelID: String) async throws {
        guard UUID(uuidString: id) != nil, !shuttingDown else { throw AgentCLIError.cancelled }
        guard active[id] == nil else { throw InstalledCodexCLI.Failure.busy }
        let saved = records[id]
        guard saved.map({ ProviderCLI(modelID: $0.task.model) == provider }) != false else { throw InstalledCodexCLI.Failure.differentRuntime }
        let directory: URL
        if let path = saved?.task.workspace ?? directories[id] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = root.appendingPathComponent("Workspaces/" + id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var turn = Turn()
        let turnID = turn.id
        let conn = try connection(provider, directory: directory) { [weak self] data in await self?.receive(data, id: id, turn: turnID) }
        turn.connection = conn
        active[id] = turn
        do {
            let initResult = try await initialize(conn)
            try check(id, turnID)
            var params: [String: Any] = ["cwd": directory.path, "mcpServers": [Any]()]
            let session: String
            let config: [String: Any]
            if let saved {
                guard (initResult["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool == true else {
                    throw AgentCLIError.unavailable(provider.name + " cannot resume this session. Start a new chat.")
                }
                params["sessionId"] = saved.session
                config = try await rpc(conn, "session/load", params)
                session = saved.session
            } else {
                config = try await rpc(conn, "session/new", params)
                guard let newID = config["sessionId"] as? String, !newID.isEmpty else {
                    throw AgentCLIError.protocolError("CLI omitted its session identifier.")
                }
                session = newID
            }
            try check(id, turnID)
            if let slug = ProviderCLI.slug(modelID) {
                let catalog = AgentCLIModels(session: config)
                guard catalog.entries.contains(where: { $0.id == slug }) else {
                    throw AgentCLIError.unavailable("The CLI no longer lists this model. Refresh its models and choose again.")
                }
                if let key = catalog.configID {
                    let changed = try await rpc(conn, "session/set_config_option", ["sessionId": session, "configId": key, "value": slug])
                    let controls = changed["configOptions"] as? [[String: Any]]
                    guard controls?.first(where: { $0["id"] as? String == key })?["currentValue"] as? String == slug else {
                        throw AgentCLIError.protocolError("The CLI did not confirm the selected model.")
                    }
                } else {
                    _ = try await rpc(conn, "session/set_model", ["sessionId": session, "modelId": slug])
                }
                try check(id, turnID)
            }
            var task = saved?.task ?? AgentTask(id: id, runtimeThreadID: id, title: String(prompt.prefix(72)),
                summary: prompt, status: .running, workspace: directory.path, model: modelID, entries: [])
            task.model = modelID
            task.status = .running
            task.updatedAt = .now
            task.entries.append(.init(kind: .user, title: "You", body: prompt))
            try save(Record(task: task, session: session))
            active[id]?.session = session
            active[id]?.acceptingUpdates = true
            publish(.taskThreadBound(taskID: id, threadID: id))
            publish(.taskStatusChanged(taskID: id, status: .running))
            Task { await self.run(prompt, id: id, turn: turnID, session: session, conn: conn) }
        } catch {
            if active[id]?.id == turnID { active.removeValue(forKey: id) }
            await conn.close()
            throw error
        }
    }

    private func run(_ prompt: String, id: String, turn: String, session: String, conn: AgentCLIConnection) async {
        do {
            let response = try await rpc(conn, "session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": prompt]]], timeout: .seconds(1800))
            try check(id, turn)
            guard response["stopReason"] as? String == "end_turn", let current = active[id],
                  !current.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentCLIError.protocolError("The CLI ended the turn without a completed answer.")
            }
            finish(id, turn: turn, entry: .init(id: current.item, kind: .assistant, title: "Computa",
                body: current.answer, assistantPhase: "final_answer"), status: .completed)
        } catch {
            finish(id, turn: turn, entry: .init(kind: .system, title: "CLI task failed",
                body: error.localizedDescription), status: .failed)
        }
        await conn.close()
    }

    private func finish(_ id: String, turn: String, entry: TimelineEntry, status: TaskStatus) {
        guard let current = active[id], current.id == turn, var row = records[id] else { return }
        active.removeValue(forKey: id)
        clearPermissions(id)
        row.task.updatedAt = .now
        row.task.status = status
        row.task.entries += current.tools.values.sorted { $0.timestamp < $1.timestamp }
        row.task.entries.append(entry)
        do { try save(row) }
        catch {
            publish(.timelineEntryAppended(taskID: id, entry: .init(kind: .system, title: "CLI transcript could not be saved", body: error.localizedDescription)))
            publish(.taskStatusChanged(taskID: id, status: .failed))
            return
        }
        publish(.timelineEntryAppended(taskID: id, entry: entry))
        if status == .completed { publish(.taskCompletionObserved(taskID: id, threadID: id, turnID: turn)) }
        publish(.taskStatusChanged(taskID: id, status: status))
    }

    private func clearPermissions(_ id: String) {
        for key in permissions.filter({ $0.value.taskID == id }).keys {
            permissions.removeValue(forKey: key)
            publish(.approvalResolved(requestID: key))
        }
    }

    private func receive(_ data: Data, id: String, turn: String) async {
        guard let current = active[id], current.id == turn, let conn = current.connection,
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = msg["method"] as? String else { return }
        let params = msg["params"] as? [String: Any] ?? [:]
        let owned = current.acceptingUpdates && current.session != nil && params["sessionId"] as? String == current.session
        if let rpcID = msg["id"] {
            guard method == "session/request_permission", owned, let choices = params["options"] as? [[String: Any]],
                  let rawID = try? JSONSerialization.data(withJSONObject: rpcID, options: .fragmentsAllowed) else {
                if let reply = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": rpcID, "error": ["code": -32601, "message": "Unsupported client operation"]]) { try? await conn.send(reply) }
                return
            }
            let key = "provider-cli/" + UUID().uuidString
            permissions[key] = Permission(taskID: id, turnID: turn, rpcID: rawID,
                allow: choices.first { $0["kind"] as? String == "allow_once" }?["optionId"] as? String,
                deny: choices.first { $0["kind"] as? String == "reject_once" }?["optionId"] as? String)
            let call = params["toolCall"] as? [String: Any]
            let title = call?["title"] as? String ?? "CLI tool request"
            let details = call?["rawInput"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .fragmentsAllowed]) }
            publish(.approvalRequested(.init(id: key, taskID: id, kind: call?["kind"] as? String == "edit" ? .fileChange : .command,
                title: title, summary: title, details: details.flatMap {String(data: $0, encoding: .utf8)} ?? title)))
            return
        }
        guard method == "session/update", owned, let u = params["update"] as? [String: Any] else { return }
        if ["tool_call", "tool_call_update"].contains(u["sessionUpdate"] as? String ?? ""),
           let toolID = u["toolCallId"] as? String, !toolID.isEmpty {
            let previous = current.tools[toolID]
            let title = u["title"] as? String ?? previous?.title ?? "CLI tool"
            let status: ToolRunStatus = switch u["status"] as? String {
            case "failed": .failed
            case "completed": .succeeded
            default: previous?.toolEvent?.status ?? .running
            }
            let entry = TimelineEntry(id: previous?.id ?? UUID().uuidString, kind: .tool, title: title,
                body: title, timestamp: previous?.timestamp ?? .now,
                toolEvent: .init(name: "providerTool", summary: title, status: status, input: "", output: nil, duration: nil),
                turnID: turn)
            active[id]?.tools[toolID] = entry
            publish(.timelineEntryAppended(taskID: id, entry: entry))
            return
        }
        guard u["sessionUpdate"] as? String == "agent_message_chunk", let content = u["content"] as? [String: Any],
              content["type"] as? String == "text", let text = content["text"] as? String else { return }
        active[id]?.answer.append(text)
        publish(.assistantMessageDelta(taskID: id, itemID: current.item, delta: text))
    }

    func approve(_ key: String, _ allowed: Bool) async throws {
        guard let p = permissions.removeValue(forKey: key), let turn = active[p.taskID], turn.id == p.turnID,
              let conn = turn.connection else { throw AgentCLIError.cancelled }
        let choice = allowed ? p.allow : p.deny
        let outcome = choice.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0",
            "id": try JSONSerialization.jsonObject(with: p.rpcID, options: .fragmentsAllowed), "result": ["outcome": outcome]])
        try await conn.send(data)
        publish(.approvalResolved(requestID: key))
    }

    func interrupt(_ id: String) async {
        guard let current = active[id] else { return }
        finish(id, turn: current.id, entry: .init(kind: .system, title: "CLI interrupted", body: "The task was stopped."), status: .failed)
        if active[id]?.id == current.id { active.removeValue(forKey: id) }
        await current.connection?.close()
    }

    func shutdown() async -> [String] {
        shuttingDown = true
        var issues: [String] = []
        for conn in Array(discoveries.values) { issues += await conn.close() }
        for (id, turn) in active {
            await interrupt(id)
            if let conn = turn.connection { issues += await conn.close() }
        }
        return issues
    }
}
