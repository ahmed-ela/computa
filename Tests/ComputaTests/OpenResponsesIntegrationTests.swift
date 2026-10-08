import Foundation
import XCTest
@testable import Computa

/// Exercises the authenticated production HTTP boundary. Only the model
/// transport is synthetic; no provider account or running app is touched.
final class OpenResponsesIntegrationTests: XCTestCase {
    func testJSONAndSSEModesThroughHTTPAndOfficialSchema() async throws {
        let transport = OpenResponsesFixtureTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        let base = try await server.start()
        do {
            var artifacts: [[String: Any]] = []
            let root = try artifactRoot()
            for (name, stream) in [("default-json", Optional<Bool>.none), ("explicit-json", false), ("text-stream", true)] {
                var body: [String: Any] = ["model": "browser/chatgpt", "input": "Synthetic HTTP contract", "metadata": ["fixture": "open-responses"]]
                if let stream { body["stream"] = stream }
                let (data, response) = try await send(body, to: base, server: server)
                XCTAssertEqual(response.statusCode, 200)
                XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), stream == true ? "text/event-stream" : "application/json")
                if stream == true {
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))
                } else {
                    let resource = try object(data)
                    XCTAssertEqual(resource["object"] as? String, "response")
                    XCTAssertEqual(resource["status"] as? String, "completed")
                    XCTAssertTrue(resource["usage"] is NSNull)
                    XCTAssertEqual((resource["metadata"] as? [String: String])?["fixture"], "open-responses")
                }
                try export(data, name: name, kind: stream == true ? "sse" : "response", root: root, cases: &artifacts)
            }
            let function: [String: Any] = ["type": "function", "name": "get_weather", "parameters": ["type": "object"]]
            for stream in [false, true] {
                let (data, response) = try await send(["model": "browser/chatgpt", "input": "Parallel tool contract", "stream": stream,
                    "tools": [function], "tool_choice": "required", "parallel_tool_calls": true], to: base, server: server)
                XCTAssertEqual(response.statusCode, 200)
                try export(data, name: stream ? "function-stream" : "function-json", kind: stream ? "sse" : "response", root: root, cases: &artifacts)
            }
            let (custom, customResponse) = try await send(["model": "browser/chatgpt", "input": "Custom tool contract", "stream": true,
                "tools": [["type": "namespace", "name": "functions", "tools": [["type": "custom", "name": "apply_patch", "format": ["type": "text"]]]]],
                "tool_choice": "required"], to: base, server: server)
            XCTAssertEqual(customResponse.statusCode, 200)
            try export(custom, name: "codex-custom-stream", kind: "sse", profile: "codex-custom-tools", root: root, cases: &artifacts)
            let (error, errorResponse) = try await send(["model": "browser/chatgpt", "input": "Synthetic", "stream": "true"], to: base, server: server)
            XCTAssertEqual(errorResponse.statusCode, 400)
            try export(error, name: "request-error", kind: "error", root: root, cases: &artifacts)
            try JSONSerialization.data(withJSONObject: ["version": 1, "cases": artifacts], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("manifest.json"))
            let result = try await runConformance(["--artifacts", root.path])
            XCTAssertEqual(result.status, 0, result.output)
            print(result.output)
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testUpstreamAcceptanceTemplatesAgainstRealHTTPListener() async throws {
        let transport = OpenResponsesFixtureTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        let base = try await server.start()
        do {
            let taskID = UUID().uuidString.lowercased()
            _ = try await bindWebsiteInferenceFixtureTurn(server, taskID: taskID)
            let contextRoot = try artifactRoot()
            let contextURL = contextRoot.appendingPathComponent("official-fixture-headers.json")
            try JSONSerialization.data(withJSONObject: ["x-computa-task-id": taskID,
                "x-codex-turn-metadata": try websiteInferenceFixtureMetadata(taskID: taskID)], options: [.sortedKeys])
                .write(to: contextURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL.path)
            defer { try? FileManager.default.removeItem(at: contextURL) }
            let result = try await runConformance(["--official", "--base-url", base.absoluteString, "--model", "browser/chatgpt",
                "--fixture-headers", contextURL.path], token: server.bearerToken)
            XCTAssertEqual(result.status, 0, result.output)
            print(result.output)
            let sends = await transport.sendCount()
            // One upstream case is a local schema fixture and sends no HTTP.
            XCTAssertEqual(sends, 6)
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testUnsupportedRequestsAndSecurityFailBeforeTransport() async throws {
        let transport = OpenResponsesFixtureTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        let base = try await server.start()
        do {
            let invalid: [([String: Any], Int, String?)] = [
                (["model": "unknown/model", "input": "fixture"], 404, "model"),
                (["model": "browser/chatgpt", "input": "fixture", "store": true], 400, "store"),
                (["model": "browser/chatgpt", "input": "fixture", "background": true], 400, "background"),
                (["model": "browser/chatgpt", "input": "fixture", "temperature": 0.3], 400, "temperature"),
                (["model": "browser/chatgpt", "input": "fixture", "previous_response_id": "resp_fixture"], 400, "previous_response_id"),
                (["model": "browser/chatgpt", "input": [["type": "item_reference", "id": "msg_missing"]]], 400, "input.item_reference"),
                (["model": "browser/chatgpt", "input": "fixture", "tool_choice": "required"], 400, "tool_choice"),
            ]
            for (body, status, param) in invalid {
                let (data, response) = try await send(body, to: base, server: server)
                XCTAssertEqual(response.statusCode, status)
                let error = try XCTUnwrap(try object(data)["error"] as? [String: Any])
                XCTAssertEqual(error["param"] as? String, param)
                XCTAssertNotNil(error["code"])
            }
            for (headers, expected) in [(["Authorization": "Bearer invalid"], 401), (["Origin": "https://fixture.invalid"], 403), (["Content-Type": "text/plain"], 415)] {
                let (_, response) = try await send(["model": "browser/chatgpt", "input": "fixture"], to: base, server: server, headers: headers)
                XCTAssertEqual(response.statusCode, expected)
            }
            let sends = await transport.sendCount()
            let starts = await transport.startCount()
            XCTAssertEqual(sends, 0); XCTAssertEqual(starts, 0)
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testToolPolicyViolationDoesNotEmitItemsOrReplay() async throws {
        for policy in ["none", "required"] {
            let reply = policy == "none" ? #"{"type":"tool_calls","calls":[{"name":"get_weather","arguments":{}}]}"# : #"{"type":"message","text":"Synthetic"}"#
            let transport = OpenResponsesFixtureTransport(forcedReply: reply)
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
            let base = try await server.start()
            do {
                let (data, response) = try await send(["model": "browser/chatgpt", "input": "fixture", "stream": true, "tool_choice": policy,
                    "tools": [["type": "function", "name": "get_weather", "parameters": ["type": "object"]]]], to: base, server: server)
                XCTAssertEqual(response.statusCode, 500)
                let error = try XCTUnwrap(try object(data)["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "tool_choice_violation")
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("response.output_item"))
                let sends = await transport.sendCount()
                XCTAssertEqual(sends, 1)
                _ = await server.shutdown()
            } catch { _ = await server.shutdown(); throw error }
        }
    }

    private func send(_ body: [String: Any], to base: URL, server: WebModelServer, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let taskID = UUID().uuidString.lowercased()
        _ = try await bindWebsiteInferenceFixtureTurn(server, taskID: taskID)
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue(taskID, forHTTPHeaderField: "X-Computa-Task-ID")
        request.setValue(try websiteInferenceFixtureMetadata(taskID: taskID), forHTTPHeaderField: "x-codex-turn-metadata")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func artifactRoot() throws -> URL {
        let configured = ProcessInfo.processInfo.environment["COMPUTA_OPEN_RESPONSES_ARTIFACT_DIR"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ComputaOpenResponses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if configured == nil { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        return root
    }

    private func export(_ data: Data, name: String, kind: String, profile: String = "standard", root: URL, cases: inout [[String: Any]]) throws {
        let file = name + (kind == "sse" ? ".sse" : ".json")
        try data.write(to: root.appendingPathComponent(file))
        cases.append(["name": name, "file": file, "kind": kind, "profile": profile])
    }

    private func runConformance(_ arguments: [String], token: String? = nil) async throws -> (status: Int32, output: String) {
        let executable = try FixtureBunExecutable.resolve()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = [repo.appendingPathComponent("Scripts/open-responses-conformance.ts").path] + arguments
            process.currentDirectoryURL = repo
            var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR"].contains($0.key) }
            if let token { environment["COMPUTA_OPEN_RESPONSES_API_KEY"] = token }
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

private actor OpenResponsesFixtureTransport: WebModelTransport {
    private let forcedReply: String?
    private var replies: [String: String] = [:]
    private var sends = 0
    private var starts = 0
    init(forcedReply: String? = nil) { self.forcedReply = forcedReply }
    func sendCount() -> Int { sends }
    func startCount() -> Int { starts }

    func request(operation: String, params: Data) throws -> Data {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var response: [String: Any]
        switch operation {
        case "webProviderStart":
            starts += 1
            let token = UUID().uuidString; replies[token] = ""
            response = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            sends += 1
            let token = try XCTUnwrap(input["sessionToken"])
            let prompt = try XCTUnwrap(input["prompt"])
            let json = try XCTUnwrap(prompt.components(separatedBy: "COMPLETE_RESPONSES_REQUEST_JSON:\n").last?
                .components(separatedBy: "\nEND_COMPLETE_RESPONSES_REQUEST_JSON.").first)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let tools = request["tools"] as? [[String: Any]] ?? []
            if let forcedReply { replies[token] = forcedReply }
            else if tools.first?["type"] as? String == "namespace" {
                replies[token] = #"{"type":"tool_calls","calls":[{"name":"functions.apply_patch","input":"*** Begin Patch\n*** End Patch"}]}"#
            } else if !tools.isEmpty {
                let calls: [[String: Any]] = Array(repeating: ["name": "get_weather", "arguments": ["location": "San Francisco, CA"]], count: request["parallel_tool_calls"] as? Bool == true ? 2 : 1)
                replies[token] = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": calls]), as: UTF8.self)
            } else {
                replies[token] = #"{"type":"message","text":"Synthetic fixture response"}"#
            }
            response = ["state": "running"]
        case "webProviderPoll":
            let token = try XCTUnwrap(input["sessionToken"])
            response = ["state": "complete", "text": try XCTUnwrap(replies[token])]
        case "webProviderFinish", "webProviderCancel": response = ["cleanup": "not_created"]
        default: throw WebModelServer.Failure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(response))
    }
}
