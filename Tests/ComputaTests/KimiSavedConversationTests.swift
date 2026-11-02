import Foundation
import XCTest
@testable import Computa

final class KimiSavedConversationTests: XCTestCase {
    private let root = URL(string: "https://www.kimi.ai/")!
    private let canonical = URL(string: "https://www.kimi.ai/chat/11111111-abcd-4333-8444-555555555555")!
    private let provisional = URL(string: "https://www.kimi.ai/chat/p1111111-2222-4333-8444-555555555555?chat_enter_method=home")!
    private let id = UUID(), generation = UUID(), fingerprint = String(repeating: "a", count: 64)

    func testExactObservedRoutesDoNotInventConversationOwnership() {
        XCTAssertEqual(KimiSavedConversationRoute(root), .fresh)
        XCTAssertNil(KimiSavedConversationRoute(provisional)?.conversation)
        XCTAssertEqual(KimiSavedConversationRoute(canonical)?.conversation, canonical.absoluteString)
        XCTAssertEqual(KimiSavedConversationRoute(URL(string: canonical.absoluteString + "?chat_enter_method=home")!)?.conversation,
                       canonical.absoluteString)
        for raw in ["http://www.kimi.ai/", "https://kimi.ai/", "https://www.kimi.ai:443/", "https://user@www.kimi.ai/",
                    "https://www.kimi.ai/?chat_enter_method=home", "https://www.kimi.ai/?", root.absoluteString + "#",
                    canonical.absoluteString + "/", canonical.absoluteString + "?chat_enter_method=home&chat_enter_method=home",
                    canonical.absoluteString + "?chat_enter_method=work", canonical.absoluteString + "?private=canary",
                    canonical.absoluteString.replacingOccurrences(of: "11111111", with: "%311111111"),
                    canonical.absoluteString.replacingOccurrences(of: "abcd", with: "ABCD"),
                    "https://www.kimi.ai/chat/p-arbitrary", "https://www.kimi.ai.example.test/"] {
            XCTAssertNil(KimiSavedConversationRoute(URL(string: raw)!), raw)
        }
    }

    func testRouteSequenceAllowsOnlyOneMonotonicPromotionAfterSend() {
        var state = KimiSavedConversationRoutes()
        XCTAssertTrue(state.observe(root, submitted: false))
        XCTAssertFalse(state.observe(provisional, submitted: false))
        XCTAssertTrue(state.observe(root, submitted: true))
        XCTAssertTrue(state.observe(provisional, submitted: true))
        XCTAssertTrue(state.observe(provisional, submitted: true))
        XCTAssertFalse(state.observe(root, submitted: true))
        XCTAssertFalse(state.observe(URL(string: provisional.absoluteString.replacingOccurrences(of: "p111", with: "pabc"))!, submitted: true))
        XCTAssertTrue(state.observe(canonical, submitted: true))
        XCTAssertTrue(state.observe(canonical, submitted: true))
        XCTAssertFalse(state.observe(provisional, submitted: true))
        XCTAssertFalse(state.observe(URL(string: canonical.absoluteString + "?chat_enter_method=home")!, submitted: true))
        XCTAssertFalse(state.observe(URL(string: canonical.absoluteString.replacingOccurrences(of: "11111111", with: "22221111"))!, submitted: true))
    }

    func testDirectCanonicalPromotionIsAllowedButDoesNotAllowAnotherChat() {
        var state = KimiSavedConversationRoutes()
        XCTAssertTrue(state.observe(canonical, submitted: true))
        XCTAssertFalse(state.observe(root, submitted: true))
        XCTAssertFalse(state.observe(provisional, submitted: true))
    }

    func testDeletionStagesRequireReadinessAndEachMutationHasOneClaim() {
        var progress = KimiDeletionProgress()
        XCTAssertEqual(progress.claimNext(), .openMenu)
        XCTAssertEqual(progress.claimNext(), .observe)
        XCTAssertTrue(accept(&progress, proof(.menu)))
        XCTAssertEqual(progress.claimNext(), .observe)
        XCTAssertTrue(accept(&progress, proof(.menu, ready: true)))
        XCTAssertEqual(progress.claimNext(), .selectDelete)
        XCTAssertEqual(progress.claimNext(), .observe)
        XCTAssertTrue(accept(&progress, proof(.confirmation)))
        XCTAssertEqual(progress.claimNext(), .observe)
        XCTAssertTrue(accept(&progress, proof(.confirmation, ready: true)))
        XCTAssertEqual(progress.claimNext(), .confirmDelete)
        XCTAssertEqual(progress.claimNext(), .observe)
        XCTAssertTrue(accept(&progress, proof(.observing)))
        XCTAssertFalse(progress.deleted)
        XCTAssertTrue(accept(&progress, proof(.observing, deleted: true)))
        XCTAssertTrue(progress.deleted)
        XCTAssertEqual(progress.claimNext(), .observe)
        XCTAssertEqual(progress.claimed.count, 3)
    }

    func testUnacknowledgedMutationNeverBecomesAnotherDispatch() {
        var progress = KimiDeletionProgress()
        XCTAssertEqual(progress.claimNext(), .openMenu)
        for _ in 0..<4 { XCTAssertEqual(progress.claimNext(), .observe) }
        XCTAssertTrue(accept(&progress, proof(.menu, ready: true)))
        XCTAssertEqual(progress.claimNext(), .selectDelete)
        for _ in 0..<4 {
            XCTAssertTrue(accept(&progress, proof(.menu, ready: true)))
            XCTAssertEqual(progress.claimNext(), .observe)
        }
    }

    func testUnclaimedAcknowledgementsAndPhaseRollbackAreRejected() {
        var progress = KimiDeletionProgress()
        XCTAssertFalse(accept(&progress, proof(.menu)))
        XCTAssertEqual(progress.claimNext(), .openMenu)
        XCTAssertFalse(accept(&progress, proof(.confirmation)))
        XCTAssertFalse(accept(&progress, proof(.observing, deleted: true)))
        XCTAssertTrue(accept(&progress, proof(.menu, ready: true)))
        XCTAssertEqual(progress.claimNext(), .selectDelete)
        XCTAssertTrue(accept(&progress, proof(.confirmation, ready: true)))
        XCTAssertFalse(accept(&progress, proof(.menu)))
        XCTAssertEqual(progress.claimNext(), .confirmDelete)
        XCTAssertTrue(accept(&progress, proof(.observing, deleted: true)))
        XCTAssertFalse(accept(&progress, proof(.observing)))
    }

    func testDeletionProofRejectsForeignIdentityAndNumericBooleanAliases() {
        let mutations: [(String, Any)] = [
            ("id", UUID().uuidString), ("documentGeneration", UUID().uuidString), ("sequence", 2),
            ("sequence", true), ("firstUserFingerprint", String(repeating: "b", count: 64)),
            ("conversationURL", root.absoluteString), ("phase", "finished"),
            ("menuAcknowledged", 1), ("deleteAcknowledged", 0), ("confirmAcknowledged", 0),
            ("nextActionReady", 0), ("conversationDeleted", 0), ("remoteErasureVerified", 0),
            ("remoteErasureVerified", true), ("extra", "canary")]
        for (key, value) in mutations {
            var progress = KimiDeletionProgress(); _ = progress.claimNext()
            var changed = proof(.menu); changed[key] = value
            XCTAssertFalse(accept(&progress, changed), key)
            XCTAssertNil(progress.phase)
        }
        var progress = KimiDeletionProgress(); _ = progress.claimNext()
        var missing = proof(.menu); missing.removeValue(forKey: "conversationURL")
        XCTAssertFalse(accept(&progress, missing))
    }

    func testSubmissionAcknowledgementRequiresExactNativeDispatchBinding() {
        let owner = UUID().uuidString
        let value: [String: Any] = ["ownerToken": owner, "documentGeneration": generation.uuidString,
            "sequence": 1, "outboundFingerprint": fingerprint]
        XCTAssertTrue(KimiSubmissionAcknowledgement.matches(value, owner: owner, generation: generation, fingerprint: fingerprint))
        for (key, changed) in [("ownerToken", UUID().uuidString as Any), ("documentGeneration", UUID().uuidString as Any),
                               ("sequence", 2 as Any), ("sequence", true as Any), ("outboundFingerprint", "wrong" as Any),
                               ("extra", true as Any)] {
            var altered = value; altered[key] = changed
            XCTAssertFalse(KimiSubmissionAcknowledgement.matches(altered, owner: owner, generation: generation, fingerprint: fingerprint), key)
        }
        XCTAssertFalse(KimiSubmissionAcknowledgement.matches(nil, owner: owner, generation: generation, fingerprint: fingerprint))
    }

    func testKimiPilotAdmitsOnlyObservedInstantAndNeverAnImplicitDefault() throws {
        let choice = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant")
        XCTAssertTrue(choice.isValid); XCTAssertTrue(choice.isSelectable)
        XCTAssertEqual(WebsiteModelCatalog.choice(for: choice.modelID), choice)
        XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.modelID)?.choice, choice)
        XCTAssertTrue(WebsiteModelCatalog.providers.contains("kimi"))
        let placeholder = try XCTUnwrap(LocalModelCatalog.options.first { $0.id == LocalModelCatalog.kimiBrowserModelID })
        XCTAssertEqual(placeholder.available, false)
        XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: LocalModelCatalog.kimiBrowserModelID))
        XCTAssertEqual(WebsiteModelCatalog.option(for: choice).available, true)
        XCTAssertEqual(WebsiteModelCatalog.option(for: choice, available: false).available, false)
        for rejected in [WebsiteModelChoice(provider: "kimi", key: "k3d1-agent", label: "K3.1 Pro"),
                         WebsiteModelChoice(provider: "kimi", key: "k28-agent-preview", label: "K2.8 Preview"),
                         WebsiteModelChoice(provider: "kimi", key: "unobserved-key", label: "Instant"),
                         WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Different")] {
            XCTAssertTrue(rejected.isValid, "History retains the exact identity")
            XCTAssertFalse(rejected.isSelectable)
            XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: rejected.modelID))
            XCTAssertEqual(WebsiteModelCatalog.option(for: rejected).available, false)
        }
        XCTAssertNoThrow(try WebsiteModelCatalog.validateObserved([choice], provider: "kimi"))
        XCTAssertThrowsError(try WebsiteModelCatalog.validateObserved([
            WebsiteModelChoice(provider: "kimi", key: "k3d1-agent", label: "Thinking")], provider: "kimi"))
    }

    func testKimiCatalogRestorationAndSavingExcludeUnqualifiedAgentAndUnknownChoices() throws {
        let preferences = isolatedTestPreferences()
        let instant = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant")
        let unqualified = [WebsiteModelChoice(provider: "kimi", key: "k3d1-agent", label: "K3.1 Pro"),
                           WebsiteModelChoice(provider: "kimi", key: "k28-agent-preview", label: "K2.8 Preview"),
                           WebsiteModelChoice(provider: "kimi", key: "unknown", label: "Unobserved Model")]
        preferences.set(try JSONEncoder().encode([instant] + unqualified), forKey: WebsiteModelCatalog.preferenceKey)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [instant])
        WebsiteModelCatalog.save([instant] + unqualified, to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [instant])
        let stored = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        XCTAssertEqual(try JSONDecoder().decode([WebsiteModelChoice].self, from: stored), [instant])
        // Filtering cannot hide a malformed menu/cache, even when both copies
        // would otherwise be excluded from the public picker.
        preferences.set(try JSONEncoder().encode([instant, unqualified[0], unqualified[0]]), forKey: WebsiteModelCatalog.preferenceKey)
        XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
    }

    @MainActor func testKimiProviderDoesNotInheritTemporaryOrChatGPTLocalRouteAuthority() {
        let provider = EmbeddedWebModelTransport.Provider.kimi
        XCTAssertTrue(provider.lifecycle == .savedConversationDelete)
        XCTAssertEqual(provider.startURL, root)
        XCTAssertEqual(provider.host, "www.kimi.ai")
        XCTAssertTrue(provider.accepts(provisional.absoluteString))
        XCTAssertNil(provider.conversationURL(provisional.absoluteString))
        XCTAssertFalse(provider.isLocalConversation(provisional.absoluteString))
        XCTAssertFalse(provider.acceptsTemporaryToggle(root))
        XCTAssertFalse(provider.acceptsUnboundStart(provisional))
        XCTAssertTrue(provider.acceptsUnboundStart(root))
        XCTAssertFalse(provider.accepts("https://www.kimi.ai/?incognito"))
    }

    private func proof(_ phase: KimiDeletionProgress.Phase, ready: Bool = false, deleted: Bool = false) -> [String: Any] {
        ["id": id.uuidString, "documentGeneration": generation.uuidString, "sequence": 1,
         "firstUserFingerprint": fingerprint, "conversationURL": canonical.absoluteString, "phase": phase.rawValue,
         "menuAcknowledged": true, "deleteAcknowledged": phase != .menu, "confirmAcknowledged": phase == .observing,
         "nextActionReady": ready, "conversationDeleted": deleted, "remoteErasureVerified": false]
    }
    private func accept(_ progress: inout KimiDeletionProgress, _ value: [String: Any]) -> Bool {
        progress.accept(value, id: id, generation: generation, fingerprint: fingerprint, conversation: canonical.absoluteString)
    }
}
