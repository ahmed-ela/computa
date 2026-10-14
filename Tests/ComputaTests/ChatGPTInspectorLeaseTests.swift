import AppKit
import Darwin
import Foundation
import WebKit
import XCTest
@testable import Computa

final class ChatGPTInspectorLeaseTests: XCTestCase {
    func testAbsentArmDoesNotCreateAnythingAndValidArmPinsCurrentTurnOnce() throws {
        let fixture = try InspectorArmFixture(); defer { fixture.remove() }
        XCTAssertNil(fixture.consume())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        try fixture.arm()
        let lease = try XCTUnwrap(fixture.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.armFile.path))
        XCTAssertNil(fixture.consume())
        XCTAssertTrue(lease.matches(taskID: fixture.task, threadID: fixture.thread, turnID: fixture.turn))
        XCTAssertFalse(lease.matches(taskID: fixture.task, threadID: fixture.thread, turnID: UUID()))
        let view = NSObject(), token = UUID().uuidString, generation = UUID()
        let binding = try XCTUnwrap(lease.bind(view: ObjectIdentifier(view), ownerToken: token, generation: generation))
        XCTAssertNil(lease.bind(view: ObjectIdentifier(view), ownerToken: token, generation: generation))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(NSObject()), ownerToken: token, generation: generation, onRevocation: {}, action: { XCTFail() }))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: UUID().uuidString, generation: generation, onRevocation: {}, action: { XCTFail() }))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: token, generation: UUID(), onRevocation: {}, action: { XCTFail() }))
        var granted = false
        XCTAssertTrue(binding.activate(view: ObjectIdentifier(view), ownerToken: token, generation: generation, onRevocation: {}, action: { granted = true }))
        XCTAssertTrue(granted)
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: token, generation: generation, onRevocation: {}, action: { XCTFail() }))
        lease.revoke()
        XCTAssertFalse(lease.matches(taskID: fixture.task, threadID: fixture.thread, turnID: fixture.turn))
    }

    func testScopeExpiryAndDuplicateOrUnknownKeysCannotGrant() throws {
        let fixture = try InspectorArmFixture(); defer { fixture.remove() }
        let valid = fixture.fields()
        for (key, replacement) in [("taskID", UUID().uuidString.lowercased()), ("threadID", UUID().uuidString.lowercased()),
            ("provider", "gemini"), ("expiresAt", InspectorArmFixture.timestamp(Date().addingTimeInterval(-1))),
            ("expiresAt", InspectorArmFixture.timestamp(Date().addingTimeInterval(601))),
            ("expiresAt", "2026-10-14T00:00:00+00:00")] {
            var fields = valid; fields[key] = replacement
            try fixture.write(JSONSerialization.data(withJSONObject: fields))
            XCTAssertNil(fixture.consume(), key)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.armFile.path))
        }
        var unknown = valid; unknown["PRIVATE_UNEXPECTED_KEY"] = "PRIVATE_VALUE"
        try fixture.write(JSONSerialization.data(withJSONObject: unknown)); XCTAssertNil(fixture.consume())
        let text = String(decoding: try JSONSerialization.data(withJSONObject: valid), as: UTF8.self)
        try fixture.write(Data(("{\"provider\":\"chatgpt\"," + text.dropFirst()).utf8)); XCTAssertNil(fixture.consume())
        try fixture.write(Data(repeating: 32, count: 513)); XCTAssertNil(fixture.consume())
        var upper = valid; upper["taskID"] = fixture.task.uuidString.uppercased()
        try fixture.write(JSONSerialization.data(withJSONObject: upper)); XCTAssertNil(fixture.consume())
    }

    func testPrivateFileAndAncestorRequirementsRejectLinksModesAndDirectories() throws {
        let fixture = try InspectorArmFixture(); defer { fixture.remove() }
        try fixture.arm()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        XCTAssertNil(fixture.consume())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.armFile.path)
        let hardlink = fixture.root.appendingPathComponent("hardlink")
        XCTAssertEqual(link(fixture.armFile.path, hardlink.path), 0); XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: hardlink)
        let linkedDirectory = fixture.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.directory)
        XCTAssertNil(ChatGPTInspectorLease.consume(directory: linkedDirectory, taskID: fixture.task, threadID: fixture.thread, turnID: fixture.turn))
        let target = fixture.root.appendingPathComponent("private-target")
        try FileManager.default.moveItem(at: fixture.armFile, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.armFile, withDestinationURL: target)
        XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: fixture.armFile)
        try FileManager.default.createDirectory(at: fixture.armFile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o600])
        XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: fixture.armFile)
        try fixture.arm()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        XCTAssertNil(fixture.consume())
    }

    func testConcurrentConsumersHaveOneWinnerAndRevokedCapabilityCannotActivate() throws {
        let fixture = try InspectorArmFixture(); defer { fixture.remove() }
        try fixture.arm()
        let winners = InspectorLeaseRecorder()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let lease = fixture.consume() { winners.append(lease) }
        }
        XCTAssertEqual(winners.values.count, 1)
        let lease = try XCTUnwrap(winners.values.first)
        let view = NSObject(), generation = UUID(), token = UUID().uuidString
        let binding = try XCTUnwrap(lease.bind(view: ObjectIdentifier(view), ownerToken: token, generation: generation))
        lease.revoke()
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: token, generation: generation, onRevocation: {}, action: { XCTFail() }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
}

@MainActor
final class ChatGPTInspectorBrowserTests: XCTestCase {
    func testDefaultHumanAndToolPoliciesAndWrongViewOwnerProviderGenerationReject() throws {
        let fixture = try InspectorBrowserFixture(); defer { fixture.shutdown() }
        let humanID = try fixture.browser.createTab()
        let toolID = try fixture.browser.createToolTab(url: XCTUnwrap(URL(string: "about:blank")))
        let otherID = try fixture.browser.createUnloadedModelTabForTesting()
        XCTAssertFalse(fixture.view.isInspectable)
        XCTAssertFalse(fixture.browser.canInspect(tabID: fixture.id))
        XCTAssertThrowsError(try fixture.browser.setWebInspectorEnabled(true, for: fixture.id))
        for id in [humanID, toolID, otherID] {
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            let binding = try fixture.binding(view: view)
            XCTAssertFalse(fixture.browser.grantModelInspectorDiagnostic(binding, tabID: id, view: view,
                ownerToken: fixture.token, generation: try XCTUnwrap(fixture.browser.documentGeneration(for: id))))
            XCTAssertFalse(view.isInspectable)
        }
        for failure in ["owner", "generation", "origin", "view"] {
            let binding = try fixture.binding()
            if failure == "origin" { fixture.view.observedURL = URL(string: "https://gemini.google.com/") }
            let chosenView = failure == "view" ? try XCTUnwrap(fixture.browser.webView(for: humanID)) : fixture.view
            XCTAssertFalse(fixture.browser.grantModelInspectorDiagnostic(binding, tabID: fixture.id,
                view: chosenView,
                ownerToken: failure == "owner" ? UUID().uuidString : fixture.token,
                generation: failure == "generation" ? UUID() : fixture.generation))
            fixture.view.observedURL = URL(string: "https://chatgpt.com/?temporary-chat=true")
            XCTAssertFalse(fixture.view.isInspectable)
        }
    }

    func testGrantIsExactViewOnlyAndNavigationCloseShutdownRevokeWithoutHumanPolicyChanges() throws {
        for lifecycle in ["reload", "page_navigation", "closed", "shutdown"] {
            let fixture = try InspectorBrowserFixture(); defer { fixture.shutdown() }
            let humanID = try fixture.browser.createTab()
            let human = try XCTUnwrap(fixture.browser.webView(for: humanID))
            let binding = try fixture.binding()
            XCTAssertTrue(fixture.grant(binding))
            XCTAssertTrue(fixture.view.isInspectable)
            XCTAssertFalse(human.isInspectable)
            XCTAssertFalse(fixture.browser.canInspect(tabID: fixture.id))
            XCTAssertFalse(try XCTUnwrap(fixture.browser.tabs.first(where: { $0.id == fixture.id })).isWebInspectorEnabled)
            XCTAssertFalse(fixture.grant(binding))
            if lifecycle == "reload" { fixture.browser.reload(tabID: fixture.id) }
            else if lifecycle == "page_navigation" {
                let navigation = try XCTUnwrap(fixture.view.loadHTMLString("<p>Local replacement</p>", baseURL: nil))
                fixture.delegate.webView?(fixture.view, didStartProvisionalNavigation: navigation)
            } else if lifecycle == "closed" { fixture.browser.closeTab(fixture.id) }
            else { fixture.browser.shutdown() }
            XCTAssertFalse(fixture.view.isInspectable, lifecycle)
            XCTAssertFalse(fixture.grant(binding), "An old binding cannot revive a lease")
        }
    }

    func testNativeContextRevocationAndMonotonicExpiryDisableHeldView() async throws {
        for reason in ["context", "expiry"] {
            let fixture = try InspectorBrowserFixture(); defer { fixture.shutdown() }
            let binding = try fixture.binding(expiresIn: reason == "expiry" ? 0.5 : 60)
            XCTAssertTrue(fixture.grant(binding))
            if reason == "context" { try XCTUnwrap(fixture.lastLease).revoke() }
            let deadline = ContinuousClock.now + .seconds(3)
            while fixture.view.isInspectable && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(fixture.view.isInspectable, reason)
            XCTAssertFalse(fixture.grant(binding))
        }
    }
}

/// Shared local-only arm fixture. No provider or GUI activity.
final class InspectorArmFixture: @unchecked Sendable {
    let root: URL, directory: URL, armFile: URL
    let task = UUID(), thread = UUID(), turn = UUID()
    init() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent("computa-inspector-arm-" + UUID().uuidString)
        directory = root.appendingPathComponent("WebsiteInspectorDiagnostics-v1"); armFile = directory.appendingPathComponent("arm.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func fields(expiresIn: TimeInterval = 60) -> [String: String] {
        ["taskID": task.uuidString.lowercased(), "threadID": thread.uuidString.lowercased(), "provider": "chatgpt",
         "expiresAt": Self.timestamp(Date().addingTimeInterval(expiresIn))]
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return formatter.string(from: date)
    }
    func write(_ bytes: Data) throws {
        try bytes.write(to: armFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armFile.path)
    }
    func arm(expiresIn: TimeInterval = 60) throws { try write(JSONSerialization.data(withJSONObject: fields(expiresIn: expiresIn))) }
    func consume() -> ChatGPTInspectorLease? { ChatGPTInspectorLease.consume(directory: directory, taskID: task, threadID: thread, turnID: turn) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class InspectorLeaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: [ChatGPTInspectorLease] = []
    func append(_ value: ChatGPTInspectorLease) { lock.withLock { retained.append(value) } }
    var values: [ChatGPTInspectorLease] { lock.withLock { retained } }
}

@MainActor private final class InspectorBrowserFixture {
    final class View: WKWebView {
        var observedURL = URL(string: "https://chatgpt.com/?temporary-chat=true")
        override var url: URL? { observedURL }
    }
    let browser = EmbeddedBrowserSession(persistent: false)
    let id: UUID, view: View, delegate: any WKNavigationDelegate
    let token = UUID().uuidString
    var lastLease: ChatGPTInspectorLease?
    let generation: UUID
    init() throws {
        id = try browser.createUnloadedModelTabForTesting { View(frame: .zero, configuration: $0) }
        view = try XCTUnwrap(browser.webView(for: id) as? View)
        generation = try XCTUnwrap(browser.documentGeneration(for: id))
        delegate = try XCTUnwrap(view.navigationDelegate); view.navigationDelegate = nil
        try browser.installModelChangeSignal(tabID: id, ownerToken: token, world: WKContentWorld.world(name: "computa-inspector-fixture"))
    }
    func binding(view: WKWebView? = nil, expiresIn: TimeInterval = 60) throws -> ChatGPTInspectorLease.Binding {
        let arm = try InspectorArmFixture(); defer { arm.remove() }; try arm.arm(expiresIn: expiresIn)
        let lease = try XCTUnwrap(arm.consume()); lastLease = lease
        return try XCTUnwrap(lease.bind(view: ObjectIdentifier(view ?? self.view), ownerToken: token, generation: generation))
    }
    func grant(_ binding: ChatGPTInspectorLease.Binding) -> Bool {
        browser.grantModelInspectorDiagnostic(binding, tabID: id, view: view, ownerToken: token, generation: generation)
    }
    func shutdown() { browser.shutdown() }
}
