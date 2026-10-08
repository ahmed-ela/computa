import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Explicit synthetic provenance for standalone protocol tests. Native-engine
/// workflow tests use their actual task, thread, turn and runtime identities.
let websiteInferenceFixtureGeneration = UUID(uuidString: "10913cbc-442d-4d04-b1a5-b372df40c52c")!

func websiteInferenceFixtureTaskID(_ label: String) -> String {
    if let value = UUID(uuidString: label) { return value.uuidString.lowercased() }
    let digest = Array(SHA256.hash(data: Data(label.utf8)).prefix(16))
    let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    return uuid.uuidString.lowercased()
}

func makeWebsiteInferenceFixtureServer(testCase: XCTestCase, rejectedReplyDirectory: URL? = nil,
    storageDirectory: URL? = nil) async throws -> WebModelServer {
    let root = storageDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("computa-website-inference-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let server = WebModelServer(rejectedReplyDirectory: rejectedReplyDirectory)
    await server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
    await server.configureCleanupReceipts(directory: root.appendingPathComponent("cleanup"),
        runtimeGeneration: websiteInferenceFixtureGeneration) { _ in }
    testCase.addTeardownBlock {
        _ = await server.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    return server
}

@discardableResult
func bindWebsiteInferenceFixtureTurn(_ server: WebModelServer, taskID: String,
    threadID: String? = nil, turnID: String? = nil,
    runtimeGeneration: UUID = websiteInferenceFixtureGeneration, preparationID: UUID? = nil) async throws -> String {
    let task = websiteInferenceFixtureTaskID(taskID)
    let thread = threadID.map(websiteInferenceFixtureTaskID) ?? websiteInferenceFixtureTaskID(taskID + ":thread")
    let turn = turnID.map(websiteInferenceFixtureTaskID) ?? websiteInferenceFixtureTaskID(taskID + ":turn")
    let preparation = preparationID ?? UUID(uuidString: websiteInferenceFixtureTaskID(taskID + ":preparation"))!
    do {
        try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: runtimeGeneration, preparationID: preparation)
    } catch {
        try await server.prepareInferenceTurn(taskID: task, threadID: thread,
            runtimeGeneration: runtimeGeneration, preparationID: preparation)
        try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: runtimeGeneration, preparationID: preparation)
    }
    return task
}

func websiteInferenceFixtureMetadata(taskID: String, threadID: String? = nil, turnID: String? = nil) throws -> String {
    let thread = threadID.map(websiteInferenceFixtureTaskID) ?? websiteInferenceFixtureTaskID(taskID + ":thread")
    let turn = turnID.map(websiteInferenceFixtureTaskID) ?? websiteInferenceFixtureTaskID(taskID + ":turn")
    return String(decoding: try JSONSerialization.data(withJSONObject: ["thread_id": thread, "turn_id": turn],
        options: [.sortedKeys]), as: UTF8.self)
}

extension WebModelServer {
    func fixtureInfer(_ data: Data, taskID: String, threadID: String? = nil, turnID: String? = nil,
        runtimeGeneration: UUID = websiteInferenceFixtureGeneration, preparationID: UUID? = nil) async throws -> Data {
        let task = try await bindWebsiteInferenceFixtureTurn(self, taskID: taskID, threadID: threadID,
            turnID: turnID, runtimeGeneration: runtimeGeneration, preparationID: preparationID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["client_metadata"] = ["x-codex-turn-metadata": try websiteInferenceFixtureMetadata(taskID: taskID, threadID: threadID, turnID: turnID)]
        return try await infer(JSONSerialization.data(withJSONObject: object), taskID: task)
    }

    func fixtureFinish(taskID: String, runtimeGeneration: UUID? = nil) async -> [String] {
        await finish(taskID: websiteInferenceFixtureTaskID(taskID), runtimeGeneration: runtimeGeneration)
    }

    func fixtureCancel(taskID: String, runtimeGeneration: UUID? = nil) async -> [String] {
        await cancel(taskID: websiteInferenceFixtureTaskID(taskID), runtimeGeneration: runtimeGeneration)
    }
}

/// Adapts intentionally synthetic providers to the production lease protocol.
/// Supplied fields remain intact, including contradictory/malformed evidence.
/// Native-engine fixtures retain actual native turn binding. Only their
/// deliberately synthetic website provider is adapted; live WebKit is unchanged.
actor WebsiteInferenceFixtureTransport: WebModelTransport {
    private let base: any WebModelTransport
    private var generations: [String: String] = [:]
    init(_ base: any WebModelTransport) { self.base = base }

    func changeRevision(sessionToken: String) async throws -> UInt64? {
        try await base.changeRevision(sessionToken: sessionToken)
    }
    func waitForChange(sessionToken: String, after revision: UInt64, until deadline: ContinuousClock.Instant) async throws -> UInt64? {
        try await base.waitForChange(sessionToken: sessionToken, after: revision, until: deadline)
    }
    func request(operation: String, params: Data) async throws -> Data {
        let bytes = try await base.request(operation: operation, params: params)
        guard var snapshot = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let input = try JSONSerialization.jsonObject(with: params) as? [String: String] else { return bytes }
        if operation == "webProviderStart", let token = snapshot["sessionToken"] as? String {
            generations[token] = UUID().uuidString.lowercased()
        }
        let token = snapshot["sessionToken"] as? String ?? input["sessionToken"]
        if ["running", "complete"].contains(snapshot["state"] as? String ?? ""), let token {
            if snapshot["sessionToken"] == nil { snapshot["sessionToken"] = token }
            if snapshot["sequence"] == nil { snapshot["sequence"] = 1 }
            if snapshot["modelProofContext"] == nil {
                let fingerprint = SHA256.hash(data: Data(("synthetic-lease:" + token).utf8)).map { String(format: "%02x", $0) }.joined()
                snapshot["modelProofContext"] = ["documentGeneration": generations[token] ?? UUID().uuidString.lowercased(),
                    "sequence": 1, "baselineResponseCount": 0,
                    "responseCount": snapshot["state"] as? String == "complete" ? 1 : 0,
                    "firstUserFingerprint": fingerprint]
            }
        }
        if ["webProviderFinish", "webProviderCancel"].contains(operation),
           ["deleted", "not_created"].contains(snapshot["cleanup"] as? String ?? ""), let token {
            generations.removeValue(forKey: token)
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}
