import Foundation
import XCTest
@testable import Computa

extension XCTestCase {
    /// A fixture may exercise saved access choices without inheriting or
    /// overwriting the running application's user preferences.
    func isolatedTestPreferences(
        suiteName: String = "ComputaTests.Preferences.\(UUID().uuidString)"
    ) -> UserDefaults {
        let preferences = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return preferences
    }
}


extension AppState {
    /// Seed a registered tab for tests that exercise an already-open workspace.
    func createTask() {
        let draft = presentNewAgent()
        XCTAssertTrue(registerSubmittedTask(draft.id))
    }
}
