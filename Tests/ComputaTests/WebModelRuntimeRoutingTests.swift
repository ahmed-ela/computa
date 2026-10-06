import Foundation
import XCTest
@testable import Computa

/// Uses only the existing owned JSON-RPC fixture, not a website or a local model.
@MainActor
final class WebModelRuntimeRoutingTests: XCTestCase {
    func testChatGPTSubmissionRequiresAnEmbeddedTransportInsteadOfChrome() async throws {
        let runtime = try makeRuntime()
        do {
            try await runtime.submit(prompt: "Synthetic reply", toTaskID: "chatgpt", modelID: LocalModelCatalog.chatGPTBrowserModelID)
            XCTFail("The built-in model route must be explicitly configured")
        } catch {
            XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.embeddedRequired.localizedDescription)
        }
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
    }

    func testConfiguredChatGPTSubmissionDoesNotRequireChromeButOtherProvidersDo() async throws {
        let runtime = try makeRuntime()
        await runtime.configureEmbeddedWebModelTransport(InertEmbeddedTransport())
        do {
            for model in [LocalModelCatalog.geminiBrowserModelID, LocalModelCatalog.claudeBrowserModelID] {
                do {
                    try await runtime.submit(prompt: "Synthetic reply", toTaskID: model, modelID: model)
                    XCTFail("Gemini and Claude must still require Chrome")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("signed-in Chrome"))
                }
            }
            try await runtime.submit(prompt: "Synthetic reply", toTaskID: "chatgpt", modelID: LocalModelCatalog.chatGPTBrowserModelID)
            await runtime.disconnectChrome()
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func makeRuntime() throws -> CodexAppServerRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaEmbeddedModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StreamingAppServer.ts")
        let fixture = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: source, to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        try Data("phase-contract".utf8).write(to: root.appendingPathComponent("scenario"))
        try Data("release".utf8).write(to: root.appendingPathComponent("release-phase-text"))
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: fixture.path)
        configuration.codexHomePath = root.path
        configuration.workspacePath = root.path
        configuration.model = LocalModelCatalog.chatGPTBrowserModelID
        return CodexAppServerRuntime(configuration: configuration)
    }
}

private struct InertEmbeddedTransport: WebModelTransport {
    func request(operation: String, params: Data) async throws -> Data {
        // The JSON-RPC fixture does not perform inference. Endpoint and provider
        // admission are real; no browser operation is authorized by this test.
        throw WebModelServer.Failure.invalidRequest
    }
}
