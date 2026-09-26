import Foundation
import XCTest
@testable import Macrouse

final class RememberedChromeConnectionTests: XCTestCase {
    func testScopeRoundTripsAndForgettingRemovesOnlyItsPreference() throws {
        let preferences = isolatedTestPreferences()
        preferences.set("keep", forKey: "unrelated")
        let record = try RememberedChromeConnection(request: request())
        XCTAssertEqual(record.version, 1)
        XCTAssertEqual(record.bundleID, "com.google.Chrome")
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        try record.save(to: preferences)
        XCTAssertEqual(RememberedChromeConnection.load(from: preferences), record)
        RememberedChromeConnection.forget(in: preferences)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        XCTAssertNil(preferences.object(forKey: RememberedChromeConnection.preferenceKey))
        XCTAssertEqual(preferences.string(forKey: "unrelated"), "keep")
    }

    func testRecordContainsScopeOnlyAndNoConnectionSecrets() throws {
        let request = request(pid: 1234567)
        let record = try RememberedChromeConnection(request: request)
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "bundleID", "executablePath", "userDataDirectoryPath"])
        XCTAssertEqual(object["executablePath"] as? String, executable.path)
        XCTAssertEqual(object["userDataDirectoryPath"] as? String, profile.path)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(request.id.uuidString))
        XCTAssertFalse(text.contains("1234567"))
        for field in ["consent", "processIdentifier", "port", "webSocket", "session", "endpoint"] {
            XCTAssertNil(object[field])
        }
    }

    func testExactScopeMatchesWithFreshPIDButNotDifferentExecutableProfileOrBundle() throws {
        let record = try RememberedChromeConnection(request: request())
        XCTAssertTrue(record.matches(target(pid: 987)))
        XCTAssertFalse(record.matches(target(pid: 0)))
        XCTAssertFalse(record.matches(target(pid: -1)))
        XCTAssertFalse(record.matches(target(bundle: "com.google.Chrome.beta")))
        XCTAssertFalse(record.matches(target(executable: URL(fileURLWithPath: "/other/Google Chrome"))))
        XCTAssertFalse(record.matches(target(profile: URL(fileURLWithPath: "/fixture/other-profile"))))
        XCTAssertFalse(record.matches(target(executable: URL(string: "https://example.invalid/Google%20Chrome")!)))
        XCTAssertFalse(record.matches(target(profile: URL(fileURLWithPath: "/"))))
    }

    func testRequestStandardizesPathsWithoutReadingOrResolvingThem() throws {
        let record = try RememberedChromeConnection(request: request(
            executable: URL(fileURLWithPath: "/fixture/discard/../Google Chrome"),
            profile: URL(fileURLWithPath: "/fixture/discard/../never-read-profile")
        ))
        XCTAssertEqual(record.executablePath, "/fixture/Google Chrome")
        XCTAssertEqual(record.userDataDirectoryPath, "/fixture/never-read-profile")
        XCTAssertTrue(record.matches(target(executable: URL(fileURLWithPath: "/fixture/Google Chrome"),
                                            profile: URL(fileURLWithPath: "/fixture/never-read-profile"))))
    }

    func testUnapprovedRevokedAndInvalidRequestsCannotBeRemembered() throws {
        XCTAssertThrowsError(try RememberedChromeConnection(request: request(approved: false)))
        let revoked = request()
        revoked.consent.revoke()
        XCTAssertThrowsError(try RememberedChromeConnection(request: revoked))
        let invalid = [
            request(pid: 0), request(pid: -1), request(bundle: "org.chromium.Chromium"),
            request(executable: URL(fileURLWithPath: "/")),
            request(executable: URL(fileURLWithPath: "/fixture/not-chrome")),
            request(executable: URL(string: "https://example.invalid/Google%20Chrome")!),
            request(profile: URL(fileURLWithPath: "/")),
            request(profile: URL(string: "https://example.invalid/profile")!),
            request(profile: URL(string: "file://other-host/fixture/profile")!),
            request(profile: URL(fileURLWithPath: "/fixture/profile\n"))
        ]
        for value in invalid { XCTAssertThrowsError(try RememberedChromeConnection(request: value)) }
    }

    func testMalformedLegacyBooleanAndFuturePreferenceFailClosed() throws {
        let preferences = isolatedTestPreferences()
        let invalidValues: [Any] = [true, false, "true", 1, Data("not JSON".utf8), Data("true".utf8), Data("{}".utf8)]
        for value in invalidValues {
            preferences.set(value, forKey: RememberedChromeConnection.preferenceKey)
            XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        }
        let valid = try encodedObject()
        var mutations: [[String: Any]] = []
        for version: Any in [0, 2, true, "1"] {
            var object = valid; object["version"] = version; mutations.append(object)
        }
        for (key, value): (String, Any) in [
            ("bundleID", "com.google.Chrome.beta"),
            ("executablePath", "relative/Google Chrome"),
            ("executablePath", "/fixture/../Google Chrome"),
            ("executablePath", "/fixture/not-chrome"),
            ("userDataDirectoryPath", "/"),
            ("userDataDirectoryPath", "relative/profile"),
            ("userDataDirectoryPath", "/fixture/../profile"),
            ("userDataDirectoryPath", "/fixture/profile\u{0}"),
            ("processIdentifier", 123),
            ("consent", true)
        ] {
            var object = valid; object[key] = value; mutations.append(object)
        }
        var missing = valid; missing.removeValue(forKey: "bundleID"); mutations.append(missing)
        for object in mutations {
            preferences.set(try JSONSerialization.data(withJSONObject: object), forKey: RememberedChromeConnection.preferenceKey)
            XCTAssertNil(RememberedChromeConnection.load(from: preferences), "Rejected scope: \(object)")
        }
    }

    private let executable = URL(fileURLWithPath: "/fixture/Google Chrome.app/Contents/MacOS/Google Chrome")
    private let profile = URL(fileURLWithPath: "/fixture/never-read-profile")

    private func encodedObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(RememberedChromeConnection(request: request()))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func target(pid: Int32 = 123, bundle: String = "com.google.Chrome",
                        executable: URL? = nil, profile: URL? = nil) -> NativeChromeConnectionTarget {
        .init(application: .init(processIdentifier: pid, bundleIdentifier: bundle,
                                 executableURL: executable ?? self.executable),
              userDataDirectory: profile ?? self.profile)
    }

    private func request(pid: Int32 = 123, bundle: String = "com.google.Chrome",
                         executable: URL? = nil, profile: URL? = nil,
                         approved: Bool = true) -> ChromeConnectionRequest {
        let target = target(pid: pid, bundle: bundle, executable: executable, profile: profile)
        return .init(application: target.application, userDataDirectory: target.userDataDirectory,
                     consent: ChromeDebuggingConsent(approvedByUser: approved))
    }
}
