import Foundation
import XCTest
@testable import Mactopus

final class BrowserContinuationTargetTests: XCTestCase {
    private let connectionID = UUID()

    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    func testRequiresSameConnectionExactTargetAndOrigin() throws {
        let target = try XCTUnwrap(BrowserContinuationTarget(connectionID: connectionID,
            targetID: "original-tab", url: url("https://mail.example.test/inbox")))
        XCTAssertTrue(target.matches(connectionID: connectionID, targetID: "original-tab",
            url: try url("https://mail.example.test/inbox/message?q=flight#details")))
        XCTAssertFalse(target.matches(connectionID: UUID(), targetID: "original-tab",
            url: try url("https://mail.example.test/inbox")))
        XCTAssertFalse(target.matches(connectionID: connectionID, targetID: "different-tab",
            url: try url("https://mail.example.test/inbox")),
            "A tab with the same title, URL and site is not the previously observed exact target.")
    }

    func testChangedSchemeHostSubdomainOrPortCannotMatch() throws {
        let target = try XCTUnwrap(BrowserContinuationTarget(connectionID: connectionID,
            targetID: "tab", url: url("https://mail.example.test/inbox")))
        for text in ["http://mail.example.test/inbox", "https://other.example.test/inbox",
                     "https://example.test/inbox", "https://mail.example.test:8443/inbox"] {
            XCTAssertFalse(target.matches(connectionID: connectionID, targetID: "tab", url: try url(text)), text)
        }
    }

    func testDefaultPortsAndSchemeHostCaseNormalizeWithoutChangingTargetIdentity() throws {
        for pair in [("HTTPS://MAIL.example.test/inbox", "https://mail.example.test:443/message"),
                     ("HTTP://MAIL.example.test/inbox", "http://mail.example.test:80/message")] {
            let target = try XCTUnwrap(BrowserContinuationTarget(connectionID: connectionID,
                targetID: "tab", url: url(pair.0)))
            XCTAssertTrue(target.matches(connectionID: connectionID, targetID: "tab", url: try url(pair.1)))
            let explicit = try XCTUnwrap(BrowserContinuationTarget(connectionID: connectionID,
                targetID: "tab", url: url(pair.1)))
            XCTAssertEqual(target, explicit)
        }
    }

    func testUserInfoAndNonWebSchemesNeverBecomeRoutingHints() throws {
        let target = try XCTUnwrap(BrowserContinuationTarget(connectionID: connectionID,
            targetID: "tab", url: url("https://mail.example.test/inbox")))
        for text in ["https://user@mail.example.test/inbox", "https://user:secret@mail.example.test/inbox",
                     "file:///tmp/inbox.html", "chrome://settings", "about:blank", "data:text/plain,hello"] {
            let candidate = try url(text)
            XCTAssertNil(BrowserContinuationTarget(connectionID: connectionID, targetID: "tab", url: candidate), text)
            XCTAssertFalse(target.matches(connectionID: connectionID, targetID: "tab", url: candidate), text)
        }
    }
}
