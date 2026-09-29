import Foundation
import XCTest
@testable import Computa

@MainActor
final class TemporaryChromeTabsGrantTests: XCTestCase {
    func testOldGrantsDoNotAuthorizeTemporaryTabs() {
        let preferences = isolatedTestPreferences()
        preferences.set(true, forKey: BrowserExtensionCoordinator.enabledKey)
        XCTAssertFalse(ChromeTemporaryTabsGrant.matches(preferences, installationID: "profile-a", token: "secret-a"))
        XCTAssertFalse(ChromeDebuggingConsent(approvedByUser: true).allowsTemporaryTabs)
        XCTAssertFalse(ChromeDebuggingConsent(allowsTemporaryTabs: true).allowsTemporaryTabs)
    }

    func testVersionedGrantIsBoundToPairingAndForgottenExplicitly() {
        let preferences = isolatedTestPreferences()
        ChromeTemporaryTabsGrant.save(preferences, installationID: "profile-a", token: "secret-a")
        XCTAssertTrue(ChromeTemporaryTabsGrant.matches(preferences, installationID: "profile-a", token: "secret-a"))
        XCTAssertFalse(ChromeTemporaryTabsGrant.matches(preferences, installationID: "profile-b", token: "secret-a"))
        XCTAssertFalse(ChromeTemporaryTabsGrant.matches(preferences, installationID: "profile-a", token: "secret-b"))
        XCTAssertFalse(String(describing: preferences.dictionary(forKey: ChromeTemporaryTabsGrant.key)).contains("secret-a"))
        var value = preferences.dictionary(forKey: ChromeTemporaryTabsGrant.key)!
        value["version"] = 2
        preferences.set(value, forKey: ChromeTemporaryTabsGrant.key)
        XCTAssertFalse(ChromeTemporaryTabsGrant.matches(preferences, installationID: "profile-a", token: "secret-a"))
        ChromeTemporaryTabsGrant.forget(preferences)
        XCTAssertNil(preferences.object(forKey: ChromeTemporaryTabsGrant.key))
    }

    func testRevocationAlsoRemovesTemporaryAuthority() throws {
        let consent = ChromeDebuggingConsent(approvedByUser: true, allowsTemporaryTabs: true)
        XCTAssertTrue(consent.allowsTemporaryTabs)
        try consent.check()
        consent.revoke()
        XCTAssertFalse(consent.allowsTemporaryTabs)
        XCTAssertThrowsError(try consent.check())
    }

    func testWorkspaceToolAcceptsOnlyObservedCandidateShape() throws {
        let name = "computer_v2_create_workspace"
        let token = UUID().uuidString
        let call = try ComputerV2ToolContract.validate(tool: name, arguments: ["candidate_token": token])
        XCTAssertEqual(call.tool, .createWorkspace)
        try ComputerInteractionPolicy.backgroundOnly.requireV2(call)
        for extra: [String: Any] in [["url": "https://guessed.test"], ["active": true],
            ["profile": "Other"], ["approved": true], ["close_user_tabs": true], ["targetID": "invented"]] {
            XCTAssertThrowsError(try ComputerV2ToolContract.validate(tool: name,
                arguments: ["candidate_token": token].merging(extra) { _, rhs in rhs }))
        }
        XCTAssertThrowsError(try ComputerV2ToolContract.validate(tool: name, arguments: [:]))
        XCTAssertThrowsError(try ComputerV2ToolContract.validate(tool: name, arguments: ["candidate_token": NSNull()]))
        let scope = ComputerTaskScope(userPrompt: "Use background Chrome tools only. Find the requested document.")
        XCTAssertNil(scope.toolViolation(tool: name, hasBorrowedBinding: false))
    }
}
