import Foundation
import XCTest
@testable import Computa

final class DeepSeekSavedConversationTests: XCTestCase {
    private let root = URL(string: "https://chat.deepseek.com/")!
    private let conversation = URL(string: "https://chat.deepseek.com/a/chat/s/11111111-abcd-4333-8444-555555555555")!

    func testOnlyExactDeepSeekRootAndCanonicalLowercaseUUIDAreRecognized() {
        XCTAssertEqual(SavedConversationRoute(root, policy: .deepseek), .fresh)
        XCTAssertEqual(SavedConversationRoute(conversation, policy: .deepseek)?.conversation, conversation.absoluteString)
        XCTAssertEqual(SavedConversationPolicy.deepseek.host, "chat.deepseek.com")
        XCTAssertEqual(SavedConversationPolicy.deepseek.cleanupInspectionKey, "savedCleanupInspection")
        for raw in ["http://chat.deepseek.com/", "https://chat.deepseek.com:443/", "https://user@chat.deepseek.com/",
                    "https://chat.deepseek.com/?", "https://chat.deepseek.com/#", "https://chat.deepseek.com/?incognito",
                    "https://chat.deepseek.com/a/chat/s/p1111111-2222-4333-8444-555555555555",
                    "https://chat.deepseek.com/chat/11111111-abcd-4333-8444-555555555555",
                    "https://chat.deepseek.com/c/11111111-abcd-4333-8444-555555555555",
                    "https://chat.qwen.ai/a/chat/s/11111111-abcd-4333-8444-555555555555",
                    conversation.absoluteString + "/", conversation.absoluteString + "?chat_enter_method=home",
                    conversation.absoluteString + "#fixture", conversation.absoluteString + "?",
                    conversation.absoluteString.replacingOccurrences(of: "abcd", with: "ABCD"),
                    conversation.absoluteString.replacingOccurrences(of: "11111111", with: "%311111111"),
                    "https://chat.deepseek.com.example.test/"] {
            XCTAssertNil(SavedConversationRoute(URL(string: raw)!, policy: .deepseek), raw)
        }
        for policy in [SavedConversationPolicy.kimi, .qwen] {
            XCTAssertNil(SavedConversationRoute(root, policy: policy))
            XCTAssertNil(SavedConversationRoute(conversation, policy: policy))
        }
    }

    func testMonotonicRouteObservationNeverSuppliesOwnershipOrDeletionAuthority() {
        var routes = SavedConversationRoutes(policy: .deepseek)
        XCTAssertTrue(routes.observe(root, submitted: false))
        XCTAssertFalse(routes.observe(conversation, submitted: false))
        XCTAssertTrue(routes.observe(root, submitted: true))
        XCTAssertTrue(routes.observe(conversation, submitted: true))
        XCTAssertTrue(routes.observe(conversation, submitted: true))
        XCTAssertNil(routes.provisional)
        XCTAssertFalse(routes.observe(root, submitted: true))
        let foreign = URL(string: conversation.absoluteString.replacingOccurrences(of: "11111111", with: "22221111"))!
        XCTAssertFalse(routes.observe(foreign, submitted: true))
        XCTAssertEqual(routes.canonical, conversation.absoluteString)
        // Existing full-body proof and the three separate deletion claims are
        // still required by transport. Route recognition grants neither.
        var deletion = SavedConversationDeletionProgress()
        XCTAssertFalse(deletion.deleted)
        XCTAssertEqual(deletion.claimNext(), .openMenu)
        XCTAssertEqual(deletion.claimNext(), .observe, "A missing callback cannot dispatch another menu click")
    }
    @MainActor func testNativeProviderUsesModeAPIAndSavedDeletionWithoutPublicAdmission() {
        let provider = EmbeddedWebModelTransport.Provider.deepseek
        XCTAssertTrue(provider.lifecycle == .savedConversationDelete)
        XCTAssertEqual(provider.savedConversationPolicy, .deepseek)
        XCTAssertEqual(provider.startURL, root)
        XCTAssertTrue(provider.acceptsUnboundStart(root))
        XCTAssertFalse(provider.acceptsUnboundStart(conversation))
        XCTAssertFalse(provider.acceptsTemporaryToggle(root))
        XCTAssertEqual(provider.selectionAdapterAction("discoverModels"), "discoverModes")
        XCTAssertEqual(provider.selectionAdapterAction("selectModel"), "selectMode")
        XCTAssertEqual(provider.selectionAdapterAction("verifyModel"), "verifyMode")
        XCTAssertEqual(provider.selectionAdapterAction("inspect"), "inspect")
        XCTAssertEqual(EmbeddedWebModelTransport.Provider.kimi.selectionAdapterAction("selectModel"), "selectModel")
        XCTAssertTrue(WebsiteModelCatalog.providers.contains("deepseek"))
        XCTAssertFalse(LocalModelCatalog.options.contains { $0.id.hasPrefix("browser/deepseek") })
    }

    func testExactModeIdentityRoundTripsDurableReceiptWhileAliasesAndBackendClaimsFail() throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            let receipt = WebsiteSessionCleanupReceipt(taskID: UUID().uuidString, threadID: UUID().uuidString,
                turnID: UUID().uuidString, runtimeGeneration: UUID(), outcome: .closed, provider: .deepseek,
                route: .embedded, modelID: choice.requestID, reason: .deleted, trigger: .inference,
                receiptSaved: true, inferenceID: UUID().uuidString, sessionToken: UUID().uuidString)
            XCTAssertTrue(receipt.isValid); XCTAssertTrue(receipt.isTransactionLinked)
            let bytes = try JSONEncoder().encode(receipt)
            XCTAssertEqual(try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: bytes), receipt)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            for bad in ["browser/deepseek", "browser/deepseek/mode/Chat", "browser/deepseek/choice/chat",
                        "browser/qwen/mode/chat", "browser/deepseek/mode/chat?search=true"] {
                var changed = object; changed["modelID"] = bad
                let decoded = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self,
                    from: JSONSerialization.data(withJSONObject: changed))
                XCTAssertFalse(decoded.isValid, bad)
            }
        }
        XCTAssertTrue(EmbeddedHumanVerificationStore.providers.contains("deepseek"))
    }
    @MainActor func testSavedHydrationRequiresExactBooleanNegativeShapeAndClosedNativeProvider() {
        let pending: [String: Any] = ["pending": true, "sessionLifecycle": "saved_conversation_delete",
            "temporary": false, "composer": false]
        for provider in EmbeddedWebModelTransport.Provider.allCases {
            XCTAssertEqual(EmbeddedWebModelTransport.isSavedInitialHydrationObservation(pending, provider: provider),
                [.kimi, .qwen, .deepseek].contains(provider))
        }
        for provider in [EmbeddedWebModelTransport.Provider.qwen, .deepseek] {
            for (key, value) in [("pending", 1 as Any), ("temporary", 0 as Any), ("composer", 0 as Any),
                ("pending", false as Any), ("temporary", true as Any), ("composer", true as Any),
                ("url", root.absoluteString as Any), ("modelEvidence", NSNull() as Any), ("modeEvidence", NSNull() as Any),
                ("text", "PRIVATE_CANARY" as Any), ("responseCount", 0 as Any)] {
                var changed = pending; changed[key] = value
                XCTAssertFalse(EmbeddedWebModelTransport.isSavedInitialHydrationObservation(changed, provider: provider), key)
            }
            for key in pending.keys {
                var missing = pending; missing.removeValue(forKey: key)
                XCTAssertFalse(EmbeddedWebModelTransport.isSavedInitialHydrationObservation(missing, provider: provider), key)
            }
        }
    }

}
