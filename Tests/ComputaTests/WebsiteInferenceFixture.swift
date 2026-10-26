import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Explicit synthetic provenance for standalone protocol tests. Native-engine
/// workflow tests use their actual task, thread, turn and runtime identities.
let websiteInferenceFixtureGeneration = UUID(uuidString: "10913cbc-442d-4d04-b1a5-b372df40c52c")!
let syntheticChatGPTChoice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")
let syntheticChatGPTModelID = syntheticChatGPTChoice.modelID

func syntheticWebsiteModelID(_ provider: String) -> String {
    provider == "chatgpt" ? syntheticChatGPTModelID : "browser/" + provider
}

func syntheticWebsiteChoice(provider: String, key: String, label: String) -> WebsiteModelChoice {
    guard provider == "chatgpt" else { return WebsiteModelChoice(provider: provider, key: key, label: label) }
    let power: WebsiteModelChoice.ChatGPTPower = key.contains("old") ? .instant : key.contains("new") ? .high : .medium
    return WebsiteModelChoice(provider: provider, key: power.modelKey, label: power.label)
}

func syntheticChatSelection(_ choice: WebsiteModelChoice) -> [String: Any]? {
    guard let power = choice.chatGPTPower else { return nil }
    return ["family": ["key": "GPT-6", "label": "GPT-6"],
            "power": ["key": power.rawValue, "label": power.label],
            "automaticFamily": ["policy": "highest_offered_plain_gpt", "offered": ["GPT-6", "GPT-5.5"]]]
}

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
    // Standalone protocol fixtures have no native controller. State-specific
    // tests replace this explicit synthetic binding; engine fixtures use Core.
    await server.setBrowserToolAvailabilityProvider { _ in .bound }
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
    private var providers: [String: String] = [:]
    private var sequences: [String: Int] = [:]
    private var baselines: [String: Int] = [:]
    private var completedCounts: [String: Int] = [:]
    private var submittedFingerprints: [String: String] = [:]
    private let defaultChatChoice: WebsiteModelChoice?
    private let defaultGeminiChoice: WebsiteModelChoice?
    private var hasExplicitChoice: [String: Bool] = [:]
    init(_ base: any WebModelTransport, defaultChatChoice: WebsiteModelChoice? = nil,
         defaultGeminiChoice: WebsiteModelChoice? = WebsiteModelChoice(provider: "gemini", key: "fixture-default-flash", label: "Fixture Default Flash")) {
        self.base = base
        self.defaultChatChoice = defaultChatChoice
        self.defaultGeminiChoice = defaultGeminiChoice
    }

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
            providers[token] = input["provider"]
            hasExplicitChoice[token] = input["modelChoice"] != nil
            sequences[token] = 0
            baselines[token] = 0
            completedCounts[token] = 0
        }
        let token = snapshot["sessionToken"] as? String ?? input["sessionToken"]
        if let token, operation == "webProviderSend", snapshot["state"] as? String == "running" {
            sequences[token, default: 0] += 1
            baselines[token] = completedCounts[token, default: 0]
            if let prompt = input["prompt"] {
                submittedFingerprints[token] = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        if let token, snapshot["state"] as? String == "complete" {
            completedCounts[token] = baselines[token, default: 0] + 1
        }
        // This synthetic transport explicitly attests only its own serialized
        // Send bytes. Real WebKit must independently verify the rendered body.
        if let token, ["gemini", "chatgpt"].contains(providers[token] ?? ""), snapshot["turnContinuationCapability"] == nil {
            snapshot["turnContinuationCapability"] = "per_submission_ownership_v1"
        }
        if ["ready", "running", "complete"].contains(snapshot["state"] as? String ?? ""),
           let token, providers[token] == "chatgpt", let choice = defaultChatChoice,
           snapshot["modelEvidence"] == nil, let context = syntheticChatSelection(choice) {
            // Explicit fixture configuration supplies a fixed synthetic menu,
            // never a substituted request ID or repaired contradictory proof.
            snapshot["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label],
                "source": "selected_model_indicator", "verification": "website_selection", "chatSelection": context]
        }
        if ["ready", "running", "complete"].contains(snapshot["state"] as? String ?? ""),
           let token, providers[token] == "gemini", hasExplicitChoice[token] == false,
           let choice = defaultGeminiChoice, snapshot["modelEvidence"] == nil {
            snapshot["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label],
                "source": "selected_model_indicator", "verification": "website_selection"]
        }
        if ["running", "complete"].contains(snapshot["state"] as? String ?? ""), let token {
            if snapshot["sessionToken"] == nil { snapshot["sessionToken"] = token }
            if snapshot["sequence"] == nil { snapshot["sequence"] = sequences[token, default: 1] }
            if snapshot["modelProofContext"] == nil {
                let fingerprint = SHA256.hash(data: Data(("synthetic-lease:" + token).utf8)).map { String(format: "%02x", $0) }.joined()
                snapshot["modelProofContext"] = ["documentGeneration": generations[token] ?? UUID().uuidString.lowercased(),
                    "sequence": sequences[token, default: 1], "baselineResponseCount": baselines[token, default: 0],
                    "responseCount": snapshot["state"] as? String == "complete" ? completedCounts[token, default: 1] : baselines[token, default: 0],
                    "firstUserFingerprint": fingerprint]
                if providers[token] == "gemini" || providers[token] == "chatgpt" {
                    var context = snapshot["modelProofContext"] as! [String: Any]
                    context["submittedPromptFingerprint"] = submittedFingerprints[token, default: ""]
                    snapshot["modelProofContext"] = context
                }
            }
        }
        if ["webProviderFinish", "webProviderCancel"].contains(operation),
           ["deleted", "not_created"].contains(snapshot["cleanup"] as? String ?? ""), let token {
            generations.removeValue(forKey: token)
            providers.removeValue(forKey: token)
            hasExplicitChoice.removeValue(forKey: token)
            sequences.removeValue(forKey: token)
            baselines.removeValue(forKey: token)
            completedCounts.removeValue(forKey: token)
            submittedFingerprints.removeValue(forKey: token)
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}
