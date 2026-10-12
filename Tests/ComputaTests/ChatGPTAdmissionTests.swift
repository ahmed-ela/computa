import Foundation
import XCTest
@testable import Computa

final class ChatGPTAdmissionTests: XCTestCase {
    private let medium = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")

    func testRuntimeRejectsHistoricalFamiliesAndImplicitChatDefault() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        for id in retiredIDs {
            XCTAssertNotNil(WebsiteModelCatalog.selection(for: id), "History must stay readable")
            XCTAssertThrowsError(try configuration.validateSelectedModel(id))
        }
        for power in WebsiteModelChoice.ChatGPTPower.allCases {
            let choice = WebsiteModelChoice(provider: "chatgpt", key: power.modelKey,
                label: power == .pro ? "GPT-6 Pro" : power.label)
            XCTAssertNoThrow(try configuration.validateSelectedModel(choice.modelID))
        }
    }

    func testServerRejectsRetiredChatBeforeAcquiringWebsiteLease() async throws {
        let transport = ChatPresetAdmissionTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        for id in retiredIDs {
            do {
                _ = try await server.fixtureInfer(request(id), taskID: "retired-chat")
                XCTFail("Retired or implicit Chat cannot start a website session")
            } catch { XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.invalidRequest.localizedDescription) }
        }
        let operations = await transport.operations()
        XCTAssertTrue(operations.isEmpty)
    }

    @MainActor
    func testEmbeddedTransportRejectsRetiredChatWithoutCreatingTab() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let transport = EmbeddedWebModelTransport(browser: browser)
        let before = browser.tabs.map(\.id)
        let oldChoices = [WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6"),
                          WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.6 Sol", label: "GPT-5.6 Sol")]
        var inputs: [[String: String]] = [["provider": "chatgpt"]]
        inputs += try oldChoices.map { ["provider": "chatgpt", "modelChoice": try XCTUnwrap($0.canonicalJSONString)] }
        for input in inputs {
            do {
                _ = try await transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: input))
                XCTFail("No tab may be created for an inadmissible selection")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
            XCTAssertEqual(browser.tabs.map(\.id), before)
        }
    }

    func testStableMediumIdentityCannotHideFamilyDriftWithinInference() async throws {
        for point in ["webProviderSend", "webProviderPoll"] {
            let transport = ChatPresetAdmissionTransport(driftAt: point)
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
            do {
                _ = try await server.fixtureInfer(request(medium.modelID), taskID: "family-drift")
                XCTFail("Both snapshots are individually valid, but a resolved family cannot change within one inference")
            } catch { XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.modelMismatch.localizedDescription) }
            let operations = await transport.operations()
            XCTAssertEqual(operations.filter { $0 == "webProviderSend" }.count, 1)
            XCTAssertEqual(operations.filter { $0 == "webProviderPoll" }.count, point == "webProviderPoll" ? 1 : 0)
            let cleanup = await server.fixtureFinish(taskID: "family-drift")
            XCTAssertTrue(cleanup.isEmpty)
        }
    }

    func testNewInferenceResolvesLatestAgainWithoutUpgradingSelectionEvidence() async throws {
        let pro = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "GPT-6 Pro")
        for preset in [medium, pro] {
            let transport = ChatPresetAdmissionTransport(advanceBetweenInferences: true)
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
            for family in ["GPT-6", "GPT-6.1"] {
                let bytes = try await server.fixtureInfer(request(preset.modelID), taskID: "new-family")
                let text = String(decoding: bytes, as: UTF8.self)
                XCTAssertTrue(text.contains(family))
                XCTAssertTrue(text.contains("website_selection"))
                XCTAssertFalse(text.contains("response_reported"), "Family-only selection is not backend power attribution")
            }
            let operations = await transport.operations()
            XCTAssertEqual(operations, Array(repeating: ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"], count: 2).flatMap { $0 })
        }
    }

    private var retiredIDs: [String] {
        ["browser/chatgpt", WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6").modelID,
         WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.6 Sol", label: "GPT-5.6 Sol").modelID,
         WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest").modelID]
    }

    private func request(_ model: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model, "input": "Synthetic admission contract", "stream": true])
    }
}

private actor ChatPresetAdmissionTransport: WebModelTransport {
    let driftAt: String?
    let advanceBetweenInferences: Bool
    private var ledger: [String] = []
    private var choice: WebsiteModelChoice?
    private var token: String?
    private var startCount = 0
    init(driftAt: String? = nil, advanceBetweenInferences: Bool = false) {
        self.driftAt = driftAt
        self.advanceBetweenInferences = advanceBetweenInferences
    }
    func operations() -> [String] { ledger }
    func request(operation: String, params: Data) throws -> Data {
        ledger.append(operation)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        if operation == "webProviderStart" {
            choice = try XCTUnwrap(WebsiteModelChoice.parse(try XCTUnwrap(input["modelChoice"])))
            startCount += 1
            token = UUID().uuidString
        } else { XCTAssertEqual(input["sessionToken"], token) }
        if ["webProviderFinish", "webProviderCancel"].contains(operation) {
            token = nil
            return try JSONSerialization.data(withJSONObject: ["cleanup": "not_created"])
        }
        let choice = try XCTUnwrap(choice)
        let family = operation == driftAt || advanceBetweenInferences && startCount > 1 ? "GPT-6.1" : "GPT-6"
        let power = try XCTUnwrap(choice.chatGPTPower)
        let evidence: [String: Any] = ["selected": ["key": choice.key, "label": choice.label],
            "verification": "website_selection", "source": "selected_model_indicator",
            "chatSelection": ["family": ["key": family, "label": family],
                "power": ["key": power.rawValue, "label": power.label],
                "automaticFamily": ["policy": "highest_offered_plain_gpt", "offered": ["GPT-5.5", family]]]]
        var snapshot: [String: Any] = ["state": operation == "webProviderStart" ? "ready" : operation == "webProviderSend" ? "running" : "complete",
            "modelEvidence": evidence,
            "productModeEvidence": ["product": "chatgpt", "mode": "chat", "source": "composer_mode_control", "temporaryTransition": "acknowledged"]]
        if operation == "webProviderStart" { snapshot["sessionToken"] = token }
        if operation == "webProviderPoll" { snapshot["text"] = #"{"type":"message","text":"Synthetic Chat preset reply"}"# }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}
