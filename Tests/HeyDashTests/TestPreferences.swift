import Foundation
import XCTest

extension XCTestCase {
    /// A fixture may exercise saved access choices without inheriting or
    /// overwriting the running application's user preferences.
    func isolatedTestPreferences(
        suiteName: String = "HeyDashTests.Preferences.\(UUID().uuidString)"
    ) -> UserDefaults {
        let preferences = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return preferences
    }
}
