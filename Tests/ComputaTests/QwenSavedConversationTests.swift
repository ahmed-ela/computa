import Foundation
import XCTest
@testable import Computa

final class QwenSavedConversationTests: XCTestCase {
    private let root = URL(string: "https://chat.qwen.ai/")!
    private let conversation = URL(string: "https://chat.qwen.ai/c/11111111-abcd-4333-8444-555555555555")!

    func testQwenRecognizesOnlyExactRootAndCanonicalUUIDWithoutQueries() {
        XCTAssertEqual(SavedConversationRoute(root, policy: .qwen), .fresh)
        XCTAssertEqual(SavedConversationRoute(conversation, policy: .qwen)?.conversation, conversation.absoluteString)
        for raw in ["http://chat.qwen.ai/", "https://chat.qwen.ai:443/", "https://user@chat.qwen.ai/",
                    "https://chat.qwen.ai/?", "https://chat.qwen.ai/#", "https://chat.qwen.ai/?incognito",
                    "https://chat.qwen.ai/c/p1111111-2222-4333-8444-555555555555",
                    "https://chat.qwen.ai/chat/11111111-abcd-4333-8444-555555555555",
                    "https://www.kimi.ai/chat/11111111-abcd-4333-8444-555555555555",
                    conversation.absoluteString + "/", conversation.absoluteString + "?chat_enter_method=home",
                    conversation.absoluteString + "#fixture", conversation.absoluteString + "?",
                    conversation.absoluteString.replacingOccurrences(of: "abcd", with: "ABCD"),
                    conversation.absoluteString.replacingOccurrences(of: "11111111", with: "%311111111"),
                    "https://chat.qwen.ai.example.test/"] {
            XCTAssertNil(SavedConversationRoute(URL(string: raw)!, policy: .qwen), raw)
        }
        XCTAssertNil(SavedConversationRoute(root, policy: .kimi))
        XCTAssertNil(SavedConversationRoute(conversation, policy: .kimi))
    }

    func testQwenRouteObservationPinsOneConversationOnlyAfterSend() {
        var routes = SavedConversationRoutes(policy: .qwen)
        XCTAssertTrue(routes.observe(root, submitted: false))
        XCTAssertFalse(routes.observe(conversation, submitted: false))
        XCTAssertTrue(routes.observe(root, submitted: true))
        XCTAssertTrue(routes.observe(conversation, submitted: true))
        XCTAssertTrue(routes.observe(conversation, submitted: true))
        XCTAssertFalse(routes.observe(root, submitted: true))
        let other = URL(string: conversation.absoluteString.replacingOccurrences(of: "11111111", with: "22221111"))!
        XCTAssertFalse(routes.observe(other, submitted: true))
        XCTAssertEqual(routes.canonical, conversation.absoluteString)
    }

    @MainActor func testQwenDeclaresSavedDeletionWithoutBorrowingTemporaryOrProvisionalAuthority() {
        let provider = EmbeddedWebModelTransport.Provider.qwen
        XCTAssertTrue(provider.lifecycle == .savedConversationDelete)
        XCTAssertEqual(provider.savedConversationPolicy, .qwen)
        XCTAssertEqual(provider.startURL, root)
        XCTAssertEqual(provider.host, "chat.qwen.ai")
        XCTAssertTrue(provider.accepts(root.absoluteString))
        XCTAssertTrue(provider.accepts(conversation.absoluteString))
        XCTAssertTrue(provider.acceptsUnboundStart(root))
        XCTAssertFalse(provider.acceptsUnboundStart(conversation))
        XCTAssertFalse(provider.acceptsTemporaryToggle(root))
        XCTAssertFalse(provider.isLocalConversation(conversation.absoluteString))
        XCTAssertFalse(provider.accepts("https://chat.qwen.ai/c/local-chatgpt:fixture"))
        XCTAssertEqual(SavedConversationPolicy.kimi.cleanupInspectionKey, "kimiCleanupInspection")
        XCTAssertEqual(SavedConversationPolicy.qwen.cleanupInspectionKey, "savedCleanupInspection")
    }

    func testOnlyObservedPlusAndMaxEnterPilotWithoutASelectableDefault() throws {
        XCTAssertTrue(WebsiteModelCatalog.providers.contains("qwen"))
        XCTAssertEqual(LocalModelCatalog.options.first { $0.id == LocalModelCatalog.qwenBrowserModelID }?.available, false)
        for name in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let choice = WebsiteModelChoice(provider: "qwen", key: name, label: name)
            XCTAssertTrue(choice.isSelectable); XCTAssertTrue(choice.isObservedChoice)
            XCTAssertEqual(WebsiteModelCatalog.choice(for: choice.modelID), choice)
            XCTAssertNoThrow(try WebsiteModelCatalog.validateObserved([choice], provider: "qwen"))
            XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.modelID)?.choice, choice)
            XCTAssertEqual(WebsiteModelCatalog.option(for: choice).available, true)
        }
        for choice in [WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Omni-Flash", label: "Qwen3.8-Omni-Flash"),
                       WebsiteModelChoice(provider: "qwen", key: "qwen-plus", label: "Qwen3.7-Plus"),
                       WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Max", label: "Another model")] {
            XCTAssertTrue(choice.isValid)
            XCTAssertFalse(choice.isSelectable)
            XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: choice.modelID))
            XCTAssertThrowsError(try WebsiteModelCatalog.validateObserved([choice], provider: "qwen"))
        }
        XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: "browser/qwen"))
    }

    func testQwenReceiptAndCheckpointIdentityAreRegistered() throws {
        let choice = WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Max", label: "Qwen3.8-Max")
        let receipt = WebsiteSessionCleanupReceipt(taskID: UUID().uuidString, threadID: UUID().uuidString,
            turnID: UUID().uuidString, runtimeGeneration: UUID(), outcome: .closed, provider: .qwen,
            route: .embedded, modelID: choice.modelID, reason: .deleted, trigger: .inference,
            receiptSaved: true, inferenceID: UUID().uuidString, sessionToken: UUID().uuidString)
        XCTAssertTrue(receipt.isValid); XCTAssertTrue(receipt.isTransactionLinked)
        XCTAssertEqual(try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
        XCTAssertTrue(EmbeddedHumanVerificationStore.providers.contains("qwen"))
    }
}
