import Foundation
import XCTest
@testable import Computa

/// Runs the real server and supplied WebKit fixture transport. No provider
/// evidence is injected: the adapter must prove it and delete its owned page.
@MainActor
func assertSavedProviderServerStream(transport: EmbeddedWebModelTransport,
    provider: WebsiteSessionCleanupReceipt.Provider, modelID: String,
    selection: WebsiteSelectionIntent, expectedText: String,
    file: StaticString = #filePath, line: UInt = #line) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaSavedProviderReceipt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = WebModelServer(), generation = UUID()
    let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
    await server.configureEmbeddedTransport(transport)
    await server.configureEvidenceDirectory(directory.appendingPathComponent("evidence"))
    await server.configureCleanupReceipts(directory: directory, runtimeGeneration: generation) { _ in }
    do {
        let request = try JSONSerialization.data(withJSONObject: ["model": modelID,
            "input": "Return the synthetic offline fixture reply.", "stream": true, "tools": []] as [String: Any])
        let response = try await server.fixtureInfer(request, taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: generation)
        let events = try String(decoding: response, as: UTF8.self).components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: {") }.map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
            }
        XCTAssertEqual(events.first?["type"] as? String, "response.created", file: file, line: line)
        XCTAssertEqual(events.last?["type"] as? String, "response.completed", file: file, line: line)
        let delta = events.filter { $0["type"] as? String == "response.output_text.delta" }
            .compactMap { $0["delta"] as? String }.joined()
        XCTAssertEqual(delta, expectedText, file: file, line: line)
        let responses = events.compactMap { $0["response"] as? [String: Any] }
        XCTAssertEqual(responses.count, 3, file: file, line: line)
        for item in responses {
            XCTAssertEqual(item["model"] as? String, modelID, file: file, line: line)
            let metadata = try XCTUnwrap(item["metadata"] as? [String: Any], file: file, line: line)
            switch selection {
            case .model(let expected):
                XCTAssertNil(metadata["computa_website_mode"], file: file, line: line)
                let proof = try WebsiteModelEvidence.parse(metadata["computa_website_model"],
                    provider: provider.rawValue, expected: expected)
                XCTAssertEqual(proof.selected, WebsiteModelEvidence.Identity(key: expected.key, label: expected.label), file: file, line: line)
            case .mode(let expected):
                XCTAssertNil(metadata["computa_website_model"], file: file, line: line)
                let proof = try WebsiteModeEvidence.parse(metadata["computa_website_mode"],
                    provider: provider.rawValue, expected: expected)
                XCTAssertEqual(proof.selected, expected, file: file, line: line)
                XCTAssertTrue(proof.dictionary["backendModel"] is NSNull, file: file, line: line)
                XCTAssertEqual(proof.dictionary["search"] as? Bool, false, file: file, line: line)
            }
        }
        let receipts = await server.latestCleanupReceipts()
        XCTAssertEqual(receipts.count, 1, file: file, line: line)
        let receipt = try XCTUnwrap(receipts.first, file: file, line: line)
        XCTAssertTrue(receipt.isValid && receipt.isTransactionLinked && receipt.receiptSaved, file: file, line: line)
        XCTAssertEqual(receipt.provider, provider, file: file, line: line)
        XCTAssertEqual(receipt.route, .embedded, file: file, line: line)
        XCTAssertEqual(receipt.modelID, modelID, file: file, line: line)
        XCTAssertEqual(receipt.reason, .deleted, file: file, line: line)
        XCTAssertEqual(receipt.outcome, .closed, file: file, line: line)
        XCTAssertEqual(receipt.trigger, .inference, file: file, line: line)
        XCTAssertEqual(receipt.taskID, task.lowercased(), file: file, line: line)
        XCTAssertEqual(receipt.threadID, thread.lowercased(), file: file, line: line)
        XCTAssertEqual(receipt.turnID, turn.lowercased(), file: file, line: line)
        XCTAssertEqual(receipt.runtimeGeneration, generation.uuidString.lowercased(), file: file, line: line)
        XCTAssertNotNil(receipt.inferenceID, file: file, line: line)
        XCTAssertNotNil(receipt.sessionToken, file: file, line: line)
        XCTAssertEqual(WebsiteSessionCleanupStore(directory: directory).latest(), [receipt],
            "A fresh store must recover the exact closed native lease before the response is usable", file: file, line: line)
        let repeated = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(repeated, receipt, file: file, line: line)
        _ = await server.shutdown()
    } catch {
        _ = await server.shutdown()
        throw error
    }
}
