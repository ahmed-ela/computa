import Foundation
import XCTest
@testable import Computa

/// Replaces only model inference. Every reply names an actually offered tool;
/// the next request must retain its exact call and one matching real output.
/// No fixture assertion is allowed to become a fabricated model success.
actor WorkflowBenchmarkTransport: WebModelTransport {
    enum Scenario: Sendable { case workflow, deniedWrite, interruptedServer }
    struct Receipt: Sendable {
        var starts = 0
        var sends = 0
        var finishes = 0
        var cancels = 0
        var matchedOutputs = 0
        var requestModels = [String]()
        var stages = [String]()
        var readyToInterrupt = false
        var interruptedServerCall: ObservedToolResult?
        var interruptedServerReadiness: ObservedToolResult?
        var interruptedServerSession: Int?
        var readinessPolls = 0
        var serverReadinessPolls = 0
        var interactiveReadinessPolls = 0
        var observedWorkspace: String?
        var failure: String?
        var createdTokens = [String]()
        var closedTokens = [String]()
    }
    private enum Step: String, CaseIterable {
        case failingTests, patch, passingTests, diff, commitPush, serverStart,
             httpRequest, serverStop, interactiveStart, interactiveInput, commandFailure, retiredSession, final
    }
    private let fixture: WorkflowBenchmarkFixture
    private let scenario: Scenario
    private var token: String?
    private var documentGeneration: String?
    private var submitted = false
    private var reply = ""
    private var receiptValue = Receipt()
    private var pending: ExpectedCall?
    private var serverSession: Int?
    private var interactiveSession: Int?
    private var workflowStepIndex = 0
    private var readinessDeadlines = [String: ContinuousClock.Instant]()
    private var readinessPollCounts = [String: Int]()
    private var executionWorkspace: String?
    private var activeProvider: String?
    init(fixture: WorkflowBenchmarkFixture, scenario: Scenario) {
        self.fixture = fixture
        self.scenario = scenario
    }
    func receipt() -> Receipt { receiptValue }

    func request(operation: String, params: Data) throws -> Data {
        var result: [String: Any]
        do {
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
            if operation != "webProviderStart" {
                try WorkflowBenchmarkFailure.require(token != nil && input["sessionToken"] == token,
                    "An operation did not retain the exact active website lease")
            }
            switch operation {
            case "webProviderStart":
                activeProvider = input["provider"]
                try WorkflowBenchmarkFailure.require(token == nil, "A new website page started before the prior lease closed")
                let created = UUID().uuidString.lowercased()
                token = created
                documentGeneration = UUID().uuidString.lowercased()
                submitted = false
                receiptValue.createdTokens.append(created)
                receiptValue.starts += 1
                result = ["sessionToken": created, "state": "ready"]
            case "webProviderSend":
                try WorkflowBenchmarkFailure.require(!submitted, "A website lease submitted more than once")
                submitted = true
                let request = try InferenceRequest(params: params)
                receiptValue.requestModels.append(request.prepared.model)
                reply = try nextReply(request)
                receiptValue.sends += 1
                result = ["state": "running"]
            case "webProviderPoll":
                result = receiptValue.readyToInterrupt
                    ? ["state": "running"] : ["state": "complete", "text": reply]
            case "webProviderFinish":
                receiptValue.finishes += 1
                result = ["cleanup": "not_created"]
            case "webProviderCancel":
                receiptValue.cancels += 1
                result = ["cleanup": "not_created"]
            default: throw WorkflowBenchmarkFailure("Unexpected website operation: \(operation)")
            }
            if let token, let documentGeneration {
                result["sessionToken"] = token
                result["sequence"] = submitted ? 1 : 0
                result["modelProofContext"] = ["documentGeneration": documentGeneration,
                    "sequence": submitted ? 1 : 0, "baselineResponseCount": 0,
                    "responseCount": result["state"] as? String == "complete" ? 1 : 0,
                    "firstUserFingerprint": submitted ? String(repeating: "a", count: 64) : ""]
                if ["webProviderFinish", "webProviderCancel"].contains(operation) {
                    receiptValue.closedTokens.append(token)
                    self.token = nil
                    self.documentGeneration = nil
                }
            }
        } catch {
            receiptValue.failure = error.localizedDescription
            throw error
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(result, modelChoice: activeProvider == "chatgpt" ? syntheticChatGPTChoice : nil))
    }

    private func nextReply(_ request: InferenceRequest) throws -> String {
        if receiptValue.sends == 0 {
            let directory = try request.selectedWorkspace()
            try WorkflowBenchmarkFailure.require(directory == fixture.project.path,
                "The engine did not expose the selected per-task workspace")
            executionWorkspace = directory
            receiptValue.observedWorkspace = directory
        }
        let previousResult = try pending.map { try request.matchingOutput($0) }
        let previousOutput = previousResult?.output
        if pending != nil { receiptValue.matchedOutputs += 1 }
        switch scenario {
        case .workflow: return try workflowReply(request, previousOutput: previousOutput)
        case .deniedWrite:
            if receiptValue.sends == 0 {
                return try exec(request, stage: "denied_write",
                    command: "/usr/bin/touch 'denied-side-effect.txt'", elevated: true)
            }
            let output = try required(previousOutput)
            try WorkflowBenchmarkFailure.require(output.localizedCaseInsensitiveContains("rejected")
                || output.localizedCaseInsensitiveContains("denied") || output.localizedCaseInsensitiveContains("declined"),
                "A declined approval did not return a real rejection: \(output.prefix(500))")
            try WorkflowBenchmarkFailure.require(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("denied-side-effect.txt").path),
                "The declined command still wrote its side effect")
            receiptValue.stages.append("denial_verified")
            return #"{"type":"message","text":"DENIAL_BENCHMARK_OK"}"#
        case .interruptedServer:
            if receiptValue.sends == 0 { return try startServer(request) }
            let output = try required(previousOutput)
            if receiptValue.interruptedServerCall == nil {
                receiptValue.interruptedServerCall = previousResult
            }
            if let poll = try readinessPoll(request, output: output, marker: "SERVER_READY", session: &serverSession) {
                return poll
            }
            _ = try fixture.serverRecord()
            receiptValue.interruptedServerReadiness = previousResult
            receiptValue.interruptedServerSession = serverSession
            receiptValue.readyToInterrupt = true
            receiptValue.stages.append("interrupt_ready")
            return #"{"type":"message","text":"This response must never complete."}"#
        }
    }

    private func workflowReply(_ request: InferenceRequest, previousOutput: String?) throws -> String {
        guard workflowStepIndex < Step.allCases.count else { throw WorkflowBenchmarkFailure("Unexpected workflow replay") }
        let step = Step.allCases[workflowStepIndex]
        if step == .httpRequest,
           let poll = try readinessPoll(request, output: required(previousOutput), marker: "SERVER_READY", session: &serverSession) {
            return poll
        }
        if step == .interactiveInput,
           let poll = try readinessPoll(request, output: required(previousOutput), marker: "INTERACTIVE_READY", session: &interactiveSession) {
            return poll
        }
        receiptValue.stages.append(step.rawValue)
        workflowStepIndex += 1
        switch step {
        case .failingTests:
            return try exec(request, stage: step.rawValue, command: "/usr/bin/python3 -m unittest discover -s tests")
        case .patch:
            try expect(try required(previousOutput), contains: "FAILED (failures=1)", exit: 1)
            let name = try request.tool("apply_patch", custom: true)
            pending = .patch(name: name, input: fixture.patch)
            return try envelope(name: name, input: fixture.patch)
        case .passingTests:
            try expect(try required(previousOutput), contains: "Success. Updated the following files")
            return try exec(request, stage: step.rawValue,
                command: "/usr/bin/python3 -m compileall -q src tests && /usr/bin/python3 -m unittest discover -s tests")
        case .diff:
            try expect(try required(previousOutput), contains: "Ran 2 tests", exit: 0)
            return try exec(request, stage: step.rawValue,
                command: "/usr/bin/git --no-pager diff -- src/math_utils.py obsolete.txt && /usr/bin/git status --porcelain")
        case .commitPush:
            let output = try required(previousOutput)
            try expect(output, contains: "+    return sum(values)", exit: 0)
            try expect(output, contains: "M user-note.txt")
            // Explicit path list avoids staging the preserved pre-existing edit.
            return try exec(request, stage: step.rawValue,
                command: "/usr/bin/git add -- src/math_utils.py README.md obsolete.txt && /usr/bin/git commit -m 'Validate disposable workflow' && /usr/bin/git push origin HEAD:refs/heads/benchmark", elevated: true)
        case .serverStart:
            try expect(try required(previousOutput), contains: "HEAD -> benchmark", exit: 0)
            _ = try fixture.verifyCommittedOutcome()
            return try startServer(request)
        case .httpRequest:
            let output = try required(previousOutput)
            try expect(output, contains: "SERVER_READY")
            let record = try fixture.serverRecord()
            return try exec(request, stage: step.rawValue,
                command: "/usr/bin/curl --fail --silent --max-time 5 'http://127.0.0.1:\(record.port)/health'", elevated: true)
        case .serverStop:
            try expect(try required(previousOutput), contains: fixture.marker, exit: 0)
            return try stdin(request, session: requiredSession(serverSession), text: "\u{03}")
        case .interactiveStart:
            try expect(try required(previousOutput), contains: "SERVER_STOPPED", exit: 0)
            try fixture.verifyServerClosed()
            return try exec(request, stage: step.rawValue,
                command: "/usr/bin/python3 " + shellQuote(fixture.project.appendingPathComponent("interactive.py").path), tty: true)
        case .interactiveInput:
            let output = try required(previousOutput)
            try expect(output, contains: "INTERACTIVE_READY")
            return try stdin(request, session: requiredSession(interactiveSession), text: "composable\n")
        case .commandFailure:
            try expect(try required(previousOutput), contains: "INTERACTIVE_RESULT=composable", exit: 0)
            return try exec(request, stage: step.rawValue,
                command: "/usr/bin/printf 'EXPECTED_STDERR_FAILURE\\n' >&2\nexit 23")
        case .retiredSession:
            try expect(try required(previousOutput), contains: "EXPECTED_STDERR_FAILURE", exit: 23)
            return try stdin(request, session: requiredSession(interactiveSession), text: "")
        case .final:
            let output = try required(previousOutput)
            try WorkflowBenchmarkFailure.require(output.localizedCaseInsensitiveContains("unknown process")
                || output.localizedCaseInsensitiveContains("process not found") || output.localizedCaseInsensitiveContains("session not found"),
                "Input to a retired terminal session did not fail explicitly: \(output.prefix(500))")
            _ = try fixture.verifyCommittedOutcome()
            try fixture.verifyServerClosed()
            return #"{"type":"message","text":"WORKFLOW_BENCHMARK_OK"}"#
        }
    }

    private func startServer(_ request: InferenceRequest) throws -> String {
        try exec(request, stage: "server_start",
            command: "/usr/bin/python3 " + shellQuote(fixture.project.appendingPathComponent("server.py").path),
            tty: true, elevated: true)
    }

    /// A running session may yield before its first byte. Observe readiness by
    /// polling that exact session; never restart the command or send input early.
    private func readinessPoll(_ request: InferenceRequest, output: String, marker: String,
                               session: inout Int?) throws -> String? {
        try WorkflowBenchmarkFailure.require(!output.contains("Process exited with code"),
            "The owned session exited before readiness: \(output.prefix(700))")
        let observed = try sessionID(output)
        try WorkflowBenchmarkFailure.require(session == nil || session == observed,
            "Readiness output changed the owned session identity")
        session = observed
        if output.contains(marker) { return nil }
        let deadline = readinessDeadlines[marker] ?? ContinuousClock.now + .seconds(10)
        readinessDeadlines[marker] = deadline
        let count = readinessPollCounts[marker, default: 0]
        try WorkflowBenchmarkFailure.require(count < 6 && ContinuousClock.now < deadline,
            "The owned session did not produce \(marker) within its finite readiness budget")
        readinessPollCounts[marker] = count + 1
        receiptValue.readinessPolls += 1
        if marker == "SERVER_READY" { receiptValue.serverReadinessPolls += 1 }
        else { receiptValue.interactiveReadinessPolls += 1 }
        return try stdin(request, session: observed, text: "")
    }

    private func exec(_ request: InferenceRequest, stage: String, command: String,
                      tty: Bool = false, elevated: Bool = false) throws -> String {
        let name = try request.tool("exec_command")
        guard let executionWorkspace else { throw WorkflowBenchmarkFailure("No model-observed workspace is available") }
        var arguments: [String: Any] = ["cmd": command, "workdir": executionWorkspace,
            "yield_time_ms": tty ? 1000 : 10000, "max_output_tokens": 2000, "tty": tty]
        if elevated {
            arguments["sandbox_permissions"] = "require_escalated"
            arguments["justification"] = "Run the owned disposable \(stage) fixture; no user project or external endpoint is involved."
        }
        pending = .function(name: name, arguments: arguments)
        return try envelope(name: name, arguments: arguments)
    }

    private func stdin(_ request: InferenceRequest, session: Int, text: String) throws -> String {
        let name = try request.tool("write_stdin")
        let arguments: [String: Any] = ["session_id": session, "chars": text,
            "yield_time_ms": 1000, "max_output_tokens": 2000]
        pending = .function(name: name, arguments: arguments)
        return try envelope(name: name, arguments: arguments)
    }

    private func envelope(name: String, arguments: [String: Any]) throws -> String {
        try toolEnvelope(["name": name, "arguments": arguments])
    }
    private func envelope(name: String, input: String) throws -> String {
        try toolEnvelope(["name": name, "input": input])
    }
    static let toolProgress = "WORKFLOW_TOOL_PROGRESS"
    private func toolEnvelope(_ call: [String: Any]) throws -> String {
        var envelope: [String: Any] = ["type": "tool_calls", "calls": [call]]
        if case .workflow = scenario { envelope["commentary"] = Self.toolProgress }
        return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    }
    private func required(_ value: String?) throws -> String {
        guard let value else { throw WorkflowBenchmarkFailure("The continuation lacks a tool result") }
        return value
    }
    private func requiredSession(_ value: Int?) throws -> Int {
        guard let value else { throw WorkflowBenchmarkFailure("No observed terminal session is available") }
        return value
    }
    private func sessionID(_ output: String) throws -> Int {
        let expression = try NSRegularExpression(pattern: "(?:Process running with session ID|Session ID:)\\s*(\\d+)", options: .caseInsensitive)
        guard let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output), let id = Int(output[range]) else {
            throw WorkflowBenchmarkFailure("No real running-session ID in tool output: \(output.prefix(500))")
        }
        return id
    }
    private func expect(_ output: String, contains text: String, exit: Int? = nil) throws {
        try WorkflowBenchmarkFailure.require(output.contains(text), "Expected real tool result \(text); received \(output.prefix(700))")
        if let exit {
            try WorkflowBenchmarkFailure.require(output.contains("Process exited with code \(exit)"),
                "Expected actual exit \(exit); received \(output.prefix(700))")
        }
    }
    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum ExpectedCall {
    case function(name: String, arguments: [String: Any])
    case patch(name: String, input: String)
}

/// This is captured from the engine's continuation, not from the fixture reply.
/// Exact argument matching and a unique call-ID-matched output precede capture.
struct ObservedToolResult: Sendable {
    let callID: String
    let name: String
    let command: String?
    let workdir: String?
    let sessionID: Int?
    let output: String
}

struct InferenceRequest {
    let prepared: WebModelResponseCodec.Request
    let input: [[String: Any]]
    init(params: Data) throws {
        guard let parameters = try JSONSerialization.jsonObject(with: params) as? [String: Any],
              let prompt = parameters["prompt"] as? String,
              let start = prompt.range(of: "COMPLETE_RESPONSES_REQUEST_JSON:\n"),
              let end = prompt.range(of: "\nEND_COMPLETE_RESPONSES_REQUEST_JSON.", range: start.upperBound..<prompt.endIndex) else {
            throw WorkflowBenchmarkFailure("Complete Responses request is absent")
        }
        let data = Data(prompt[start.upperBound..<end.lowerBound].utf8)
        prepared = try WebModelResponseCodec.prepareRequest(data)
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = request["input"] as? [[String: Any]] else {
            throw WorkflowBenchmarkFailure("Native request input is not a message list")
        }
        self.input = input
    }
    func tool(_ base: String, custom: Bool = false) throws -> String {
        let names = prepared.offeredToolNames.filter { $0 == base || $0.hasSuffix("." + base) }
        guard names.count == 1, let name = names.first else { throw WorkflowBenchmarkFailure("The native request must offer one \(base) tool") }
        // The codec is the same validated schema projection used in production.
        try WorkflowBenchmarkFailure.require(prepared.customToolNames.contains(name) == custom,
            "The offered \(base) schema has the wrong custom/function type")
        return name
    }
    func selectedWorkspace() throws -> String {
        let contexts = input.filter { $0["role"] as? String == "user" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["text"] as? String }
            .filter { $0.hasPrefix("<environment_context>") }
        for text in contexts.reversed() {
            let reader = WorkspaceEnvironmentReader()
            let parser = XMLParser(data: Data(text.utf8))
            parser.delegate = reader
            guard parser.parse() else { throw WorkflowBenchmarkFailure("Engine environment context was not valid XML") }
            if let path = reader.primaryDirectories.last {
                try WorkflowBenchmarkFailure.require(reader.primaryDirectories.count == 1 && path.hasPrefix("/"),
                    "Engine environment context did not expose one absolute primary workspace")
                return path
            }
        }
        throw WorkflowBenchmarkFailure("The model request lacks engine environment context with its selected workspace")
    }
    func matchingOutput(_ expected: ExpectedCall) throws -> ObservedToolResult {
        let calls = input.filter { ["function_call", "custom_tool_call"].contains($0["type"] as? String ?? "") }
        let matches = calls.filter { call in
            switch expected {
            case .patch(let name, let value): return qualifiedName(call) == name && call["input"] as? String == value
            case .function(let name, let arguments):
                guard qualifiedName(call) == name, let raw = call["arguments"] as? String,
                      let actual = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary else { return false }
                return actual == arguments as NSDictionary
            }
        }
        // Repeated read-only polls can have identical arguments, but each has
        // its own call identity. Match only the latest call, never an older
        // output with the same arguments or a duplicated call ID.
        guard let call = matches.last, let latest = calls.last,
              let id = call["call_id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              latest["call_id"] as? String == id,
              calls.filter({ $0["call_id"] as? String == id }).count == 1 else {
            throw WorkflowBenchmarkFailure("The native continuation does not retain its exact offered tool call")
        }
        let results = input.filter { ["function_call_output", "custom_tool_call_output"].contains($0["type"] as? String ?? "") && $0["call_id"] as? String == id }
        guard results.count == 1 else { throw WorkflowBenchmarkFailure("The native call lacks one uniquely matching output") }
        let output: String
        if let text = results[0]["output"] as? String { output = text }
        else if let parts = results[0]["output"] as? [[String: Any]] {
            output = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else { throw WorkflowBenchmarkFailure("The native tool output has an unsupported shape") }
        let arguments: [String: Any]
        if case .function(_, let expectedArguments) = expected { arguments = expectedArguments }
        else { arguments = [:] }
        return ObservedToolResult(callID: id, name: qualifiedName(call),
            command: arguments["cmd"] as? String, workdir: arguments["workdir"] as? String,
            sessionID: arguments["session_id"] as? Int,
            output: output)
    }
    private func qualifiedName(_ call: [String: Any]) -> String {
        let name = call["name"] as? String ?? ""
        guard let namespace = call["namespace"] as? String, !namespace.isEmpty else { return name }
        return namespace + "." + name
    }
}

/// Decode only the engine's primary cwd, including XML-escaped path characters.
/// Fixture commands must use this observation rather than a setup-only path.
private final class WorkspaceEnvironmentReader: NSObject, XMLParserDelegate {
    private var path = [String]()
    private var primary = [Bool]()
    private var directory: String?
    private(set) var primaryDirectories = [String]()
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        if name == "environment" { primary.append(attributes["primary"] == "true") }
        if name == "cwd", path.first == "environment_context", primary.last != false { directory = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if directory != nil { directory? += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "cwd", let directory {
            primaryDirectories.append(directory)
            self.directory = nil
        }
        if name == "environment" { _ = primary.popLast() }
        _ = path.popLast()
    }
}
