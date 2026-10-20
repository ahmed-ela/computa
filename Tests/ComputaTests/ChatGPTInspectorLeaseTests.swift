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

#if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
@MainActor
final class ChatGPTInspectorNativeFocusTests: XCTestCase {
    func testNativeFocusDiagnosticIsOptInAndPreservesTheExactLeasedDocumentAndHost() async throws {
        let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
        let otherID = try fixture.browser.createUnloadedModelTabForTesting()
        let other = try XCTUnwrap(fixture.browser.webView(for: otherID))
        let configuration = fixture.view.configuration
        let store = configuration.websiteDataStore
        let controller = configuration.userContentController
        let scripts = controller.userScripts.map(\.source)
        let generation = fixture.browser.documentGeneration(for: fixture.id)
        let url = fixture.view.url
        let frame = fixture.view.frame
        let keyWindow = NSApplication.shared.keyWindow
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        XCTAssertFalse(other.acceptsFirstResponder)
        XCTAssertFalse(fixture.browser.modelNativeFocusDiagnosticRequested)
        XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .idle)

        XCTAssertTrue(fixture.grant(try fixture.binding()))
        XCTAssertTrue(fixture.window.firstResponder === fixture.input)
        XCTAssertFalse(fixture.view.acceptsFirstResponder, "Inspector access alone must retain ordinary background focus policy")
        fixture.browser.revokeModelInspectorDiagnostic(tabID: fixture.id, ownerToken: fixture.token)

        fixture.browser.setModelNativeFocusDiagnosticRequested(true)
        let binding = try fixture.binding()
        XCTAssertFalse(fixture.browser.grantModelInspectorDiagnostic(binding, tabID: otherID, view: other,
            ownerToken: fixture.token, generation: try XCTUnwrap(fixture.browser.documentGeneration(for: otherID))))
        XCTAssertTrue(fixture.browser.modelNativeFocusDiagnosticRequested, "A foreign view must not consume the pending opt-in")
        XCTAssertTrue(fixture.grant(binding))
        XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .acquired)
        XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticTabID, fixture.id)
        XCTAssertFalse(fixture.browser.modelNativeFocusDiagnosticRequested)
        XCTAssertTrue(fixture.view.acceptsFirstResponder)
        XCTAssertTrue(fixture.ownsCurrentResponder)
        XCTAssertFalse(other.acceptsFirstResponder)
        XCTAssertFalse(other.isInspectable)

        fixture.browser.captureModelNativeFocus(tabID: fixture.id)
        fixture.browser.restoreModelNativeFocus(tabID: fixture.id)
        XCTAssertTrue(fixture.ownsCurrentResponder, "Ordinary adapter restoration must not end the explicitly leased diagnostic")
        XCTAssertTrue(fixture.view.configuration.websiteDataStore === store)
        XCTAssertTrue(fixture.view.configuration.userContentController === controller)
        XCTAssertEqual(controller.userScripts.map(\.source), scripts)
        XCTAssertEqual(fixture.browser.documentGeneration(for: fixture.id), generation)
        XCTAssertEqual(fixture.view.url, url)
        XCTAssertEqual(fixture.view.frame, frame)
        XCTAssertTrue(fixture.view.superview === fixture.host)
        XCTAssertTrue(fixture.view.window === fixture.window)
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow, "The fixture must never activate a real OS window")

        fixture.browser.cancelModelNativeFocusDiagnostic()
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID)
        XCTAssertTrue(fixture.window.firstResponder === fixture.input)
        XCTAssertTrue(fixture.view.isInspectable, "Cancelling focus must not invent a second inspector policy")
    }

    func testNativeFocusDiagnosticRejectsUnavailableWindowAndRollsBackFailedAcquisition() async throws {
        for failure in ["not_key", "hidden", "acquisition"] {
            let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
            if failure == "not_key" { fixture.window.diagnosticKeyWindow = false }
            if failure == "hidden" { fixture.view.isHidden = true }
            if failure == "acquisition" { fixture.window.rejectModelFocus = true }
            fixture.browser.setModelNativeFocusDiagnosticRequested(true)
            XCTAssertTrue(fixture.grant(try fixture.binding()), "Focus refusal must not alter the valid inspector lease")
            XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .rejected, failure)
            XCTAssertFalse(fixture.browser.modelNativeFocusDiagnosticRequested, failure)
            XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID, failure)
            XCTAssertFalse(fixture.view.acceptsFirstResponder, failure)
            XCTAssertTrue(fixture.window.firstResponder === fixture.input, "A failed acquisition must restore its displaced responder: \(failure)")
            XCTAssertEqual(fixture.window.modelFocusAttempts, failure == "acquisition" ? 1 : 0)
        }
    }

    func testNativeFocusDiagnosticNilResponderCannotReviveAnOlderCapturedDestination() async throws {
        let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
        fixture.browser.captureModelNativeFocus(tabID: fixture.id)
        _ = fixture.window.makeFirstResponder(nil)
        fixture.input.removeFromSuperview()
        fixture.window.reportNilResponder = true
        fixture.browser.setModelNativeFocusDiagnosticRequested(true)
        XCTAssertTrue(fixture.grant(try fixture.binding()))
        XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .rejected)
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        XCTAssertEqual(fixture.window.modelFocusAttempts, 0)
        fixture.browser.revokeModelInspectorDiagnostic(tabID: fixture.id, ownerToken: fixture.token)
        XCTAssertNil(fixture.input.window)
        XCTAssertNil(fixture.window.firstResponder)
        XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID)
    }

    func testNativeFocusDiagnosticRevocationsRestoreAndDoNotLeakToTheNextLease() async throws {
        for lifecycle in ["finished", "stop", "context", "expiry", "closed", "shutdown"] {
            let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
            fixture.browser.setModelNativeFocusDiagnosticRequested(true)
            XCTAssertTrue(fixture.grant(try fixture.binding(expiresIn: lifecycle == "expiry" ? 0.5 : 60)))
            XCTAssertTrue(fixture.ownsCurrentResponder, lifecycle)
            switch lifecycle {
            case "finished": fixture.browser.revokeModelInspectorDiagnostic(tabID: fixture.id, ownerToken: fixture.token)
            case "stop": fixture.browser.stop(tabID: fixture.id)
            case "context": try XCTUnwrap(fixture.lastLease).revoke()
            case "expiry": break
            case "closed": fixture.browser.closeTab(fixture.id)
            default: fixture.browser.shutdown()
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while fixture.browser.modelNativeFocusDiagnosticTabID != nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID, lifecycle)
            XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .restored, lifecycle)
            XCTAssertFalse(fixture.view.acceptsFirstResponder, lifecycle)
            XCTAssertFalse(fixture.view.isInspectable, lifecycle)
            XCTAssertTrue(fixture.window.firstResponder === fixture.input, lifecycle)
            XCTAssertFalse(fixture.browser.modelNativeFocusDiagnosticRequested, lifecycle)
            if lifecycle == "finished" {
                XCTAssertTrue(fixture.grant(try fixture.binding()))
                XCTAssertFalse(fixture.view.acceptsFirstResponder, "A later inspector lease needs a new focus opt-in")
                XCTAssertTrue(fixture.window.firstResponder === fixture.input)
            }
        }
    }

    func testNativeFocusDiagnosticRevocationRespectsNewerHumanDestination() async throws {
        let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
        fixture.browser.setModelNativeFocusDiagnosticRequested(true)
        XCTAssertTrue(fixture.grant(try fixture.binding()))
        let newer = NSTextView(frame: NSRect(x: 20, y: 60, width: 100, height: 20))
        fixture.host.addSubview(newer)
        XCTAssertTrue(fixture.window.makeFirstResponder(newer))
        fixture.browser.revokeModelInspectorDiagnostic(tabID: fixture.id, ownerToken: fixture.token)
        XCTAssertTrue(fixture.window.firstResponder === newer)
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID)
    }

    func testNativeFocusDiagnosticRevocationCannotRestoreADetachedOrMovedDestination() async throws {
        for moved in [false, true] {
            let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
            let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                       styleMask: [], backing: .buffered, defer: false)
            otherWindow.isReleasedWhenClosed = false
            defer { otherWindow.close() }
            fixture.browser.setModelNativeFocusDiagnosticRequested(true)
            XCTAssertTrue(fixture.grant(try fixture.binding()))
            fixture.input.removeFromSuperview()
            if moved { try XCTUnwrap(otherWindow.contentView).addSubview(fixture.input) }
            fixture.browser.revokeModelInspectorDiagnostic(tabID: fixture.id, ownerToken: fixture.token)
            XCTAssertFalse(fixture.ownsCurrentResponder, "Revocation must release the model even when its old destination is gone")
            XCTAssertFalse(fixture.view.acceptsFirstResponder)
            XCTAssertFalse(otherWindow.firstResponder === fixture.input)
            XCTAssertFalse(otherWindow.isKeyWindow)
            XCTAssertFalse(otherWindow.isVisible)
        }
    }

    func testNativeFocusDiagnosticEndsBeforeRenderHostRemovalOrReplacement() async throws {
        for replacement in [false, true] {
            let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
            let otherWindow = NativeFocusInspectorWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 800),
                                                         styleMask: [], backing: .buffered, defer: false)
            otherWindow.isReleasedWhenClosed = false
            defer { otherWindow.close() }
            let otherHost = NSView(frame: fixture.host.frame)
            let otherInput = NSTextView(frame: NSRect(x: 20, y: 20, width: 100, height: 20))
            otherWindow.contentView = otherHost
            otherHost.addSubview(otherInput)
            XCTAssertTrue(otherWindow.makeFirstResponder(otherInput))
            let generation = fixture.browser.documentGeneration(for: fixture.id)
            fixture.browser.setModelNativeFocusDiagnosticRequested(true)
            XCTAssertTrue(fixture.grant(try fixture.binding()))
            if replacement {
                fixture.browser.installModelRenderHost(otherHost)
                XCTAssertTrue(fixture.ownsCurrentResponder, "Installing another host must not disturb the designated active host")
            }
            var modelRemovals = 0
            fixture.host.beforeRemovingSubview = { subview in
                guard subview === fixture.view else { return }
                modelRemovals += 1
                XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID, "Session state must end before physical removal")
                XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .restored)
                XCTAssertFalse(fixture.view.acceptsFirstResponder)
                XCTAssertTrue(fixture.window.firstResponder === fixture.input)
            }
            fixture.browser.removeModelRenderHost(fixture.host)
            fixture.host.beforeRemovingSubview = nil
            XCTAssertEqual(modelRemovals, 1)
            XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID)
            XCTAssertFalse(fixture.view.acceptsFirstResponder)
            XCTAssertTrue(fixture.window.firstResponder === fixture.input)
            XCTAssertTrue(otherWindow.firstResponder === otherInput, "A moved page has no focus admission in the new window")
            XCTAssertEqual(fixture.browser.documentGeneration(for: fixture.id), generation)
            XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
            if replacement { XCTAssertTrue(fixture.view.superview === otherHost) }
            else { XCTAssertNil(fixture.view.superview) }
        }
    }

    func testNativeFocusDiagnosticEndsWhenItsExistingHostMovesBetweenWindows() async throws {
        let fixture = try await NativeFocusInspectorFixture(); defer { fixture.shutdown() }
        let otherWindow = NativeFocusInspectorWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 800),
                                                     styleMask: [], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let otherHost = NSView(frame: fixture.host.frame)
        let otherInput = NSTextView(frame: NSRect(x: 20, y: 20, width: 100, height: 20))
        otherWindow.contentView = otherHost
        otherHost.addSubview(otherInput)
        XCTAssertTrue(otherWindow.makeFirstResponder(otherInput))
        let generation = fixture.browser.documentGeneration(for: fixture.id)
        fixture.browser.setModelNativeFocusDiagnosticRequested(true)
        XCTAssertTrue(fixture.grant(try fixture.binding()))
        fixture.window.contentView = NSView(frame: fixture.host.frame)
        XCTAssertNil(fixture.browser.modelNativeFocusDiagnosticTabID)
        XCTAssertEqual(fixture.browser.modelNativeFocusDiagnosticDisposition, .restored)
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        otherHost.addSubview(fixture.host)
        XCTAssertTrue(fixture.view.window === otherWindow)
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        XCTAssertTrue(otherWindow.firstResponder === otherInput)
        XCTAssertEqual(fixture.browser.documentGeneration(for: fixture.id), generation)
    }
}

/// Simulates only AppKit's key-window eligibility check. No test orders,
/// activates, or makes an actual OS window key, or claims document.hasFocus().
@MainActor private final class NativeFocusInspectorWindow: NSWindow {
    var diagnosticKeyWindow = true
    var rejectModelFocus = false
    var reportNilResponder = false
    private(set) var modelFocusAttempts = 0
    override var isKeyWindow: Bool { diagnosticKeyWindow }
    override var firstResponder: NSResponder? { reportNilResponder ? nil : super.firstResponder }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is WKWebView {
            modelFocusAttempts += 1
            if rejectModelFocus {
                _ = super.makeFirstResponder(nil)
                return false
            }
        }
        return super.makeFirstResponder(responder)
    }
}

@MainActor private final class NativeFocusInspectorHost: NSView {
    var beforeRemovingSubview: ((NSView) -> Void)?
    override func willRemoveSubview(_ subview: NSView) {
        beforeRemovingSubview?(subview)
        super.willRemoveSubview(subview)
    }
}

@MainActor private final class NativeFocusInspectorFixture {
    let browser = EmbeddedBrowserSession(persistent: false)
    let window: NativeFocusInspectorWindow
    let host: NativeFocusInspectorHost
    let input = NSTextView(frame: NSRect(x: 20, y: 20, width: 100, height: 20))
    let id: UUID, humanID: UUID, view: WKWebView, token = UUID().uuidString
    var lastLease: ChatGPTInspectorLease?
    init() async throws {
        window = NativeFocusInspectorWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 800),
                                             styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NativeFocusInspectorHost()
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 800)
        window.contentView = host
        browser.installModelRenderHost(host)
        humanID = try browser.createTab()
        id = try browser.createUnloadedModelTabForTesting()
        view = try XCTUnwrap(browser.webView(for: id))
        do {
            host.addSubview(input)
            XCTAssertTrue(window.makeFirstResponder(input))
            view.loadHTMLString("<!doctype html><p id='native-focus-fixture'>local fixture</p>",
                                baseURL: URL(string: "https://chatgpt.com/"))
            let deadline = ContinuousClock.now + .seconds(10)
            var loaded = false
            while ContinuousClock.now < deadline {
                if !view.isLoading, view.url?.host == "chatgpt.com",
                   (try? await view.callAsyncJavaScript("return !!document.getElementById('native-focus-fixture');",
                       arguments: [:], in: nil, contentWorld: .page)) as? Bool == true {
                    loaded = true; break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(loaded, "Only local HTML with a ChatGPT base URL is loaded")
            try browser.installModelChangeSignal(tabID: id, ownerToken: token,
                world: WKContentWorld.world(name: "computa-native-focus-fixture"))
        } catch {
            browser.shutdown(); window.close(); throw error
        }
    }
    var ownsCurrentResponder: Bool {
        guard let current = window.firstResponder else { return false }
        return current === view || (current as? NSView)?.isDescendant(of: view) == true
    }
    func binding(expiresIn: TimeInterval = 60) throws -> ChatGPTInspectorLease.Binding {
        let arm = try InspectorArmFixture(); defer { arm.remove() }; try arm.arm(expiresIn: expiresIn)
        let lease = try XCTUnwrap(arm.consume()); lastLease = lease
        return try XCTUnwrap(lease.bind(view: ObjectIdentifier(view), ownerToken: token,
            generation: try XCTUnwrap(browser.documentGeneration(for: id))))
    }
    func grant(_ binding: ChatGPTInspectorLease.Binding) -> Bool {
        browser.grantModelInspectorDiagnostic(binding, tabID: id, view: view, ownerToken: token,
            generation: browser.documentGeneration(for: id) ?? UUID())
    }
    func shutdown() { browser.shutdown(); window.close() }
}
#endif

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
