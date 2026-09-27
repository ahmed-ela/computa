import AppKit
import AutomationCore
import SwiftUI
import XCTest
@testable import Mactopus

/// Offscreen rendering only. No orderFront/makeKey, Chrome enumeration, file
/// admission, native permission prompt, model request, or UI input is performed.
@MainActor
final class NativeChromeConnectionRenderTests: XCTestCase {
    func testChromeDisconnectMenuRemainsAccessibleDuringAskApproval() async throws {
        let state = makeState(runtime: ChromeControlRenderRuntime())
        addTeardownBlock { @MainActor in _ = await state.shutdownRuntime() }
        XCTAssertTrue(state.connectChrome(request()))
        for _ in 0..<100 where state.chromeConnectionState != .connected {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.chromeConnectionState, .connected)
        state.apply(.approvalRequested(.init(id: "inert-approval", taskID: nil, kind: .computerUse,
                                            title: "Approve fixture?", summary: "Test", details: "Test")))
        XCTAssertTrue(state.approvalGateBlocksInteraction)
        XCTAssertNil(state.presentedSheet, "Settings cannot disable the status bar during approval")
        XCTAssertFalse(state.canConnectChrome)

        let hosting = NSHostingView(rootView: NativeRuntimeStatusBar(state: state).disabled(false))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI's macOS Menu publishes its visible title to the AppKit
        // backing button here, not the separate accessibilityLabel modifier.
        // Inspect the real public control without depending on internal classes
        // or assuming an offscreen AX label behaves like a visible-window label.
        let menus = nativeButtons(in: hosting).filter { $0.title == "Chrome connected" }
        XCTAssertEqual(menus.count, 1)
        let menu = try XCTUnwrap(menus.first)
        XCTAssertTrue(menu.isEnabled, "A pending Ask approval must not disable Disconnect")

        // Negative control: prove this reads effective AppKit enablement,
        // including a disabled ancestor, rather than only AppState intent.
        hosting.rootView = NativeRuntimeStatusBar(state: state).disabled(true)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        let disabledMenus = nativeButtons(in: hosting).filter { $0.title == "Chrome connected" }
        XCTAssertEqual(disabledMenus.count, 1)
        let disabledMenu = try XCTUnwrap(disabledMenus.first)
        XCTAssertFalse(disabledMenu.isEnabled, "The negative control must detect a disabled ancestor")
        XCTAssertFalse(window.isVisible)
    }

    func testNativeStatusBarChromeConnectionStatesRenderOffscreen() async throws {
        let idle = makeState(runtime: ChromeControlRenderRuntime())
        let connected = makeState(runtime: ChromeControlRenderRuntime())
        let gate = ChromeControlRenderPause()
        let connecting = makeState(runtime: ChromeControlRenderRuntime(gate: gate))
        let denied = makeState(runtime: ChromeControlRenderRuntime())
        let busy = makeState(runtime: ChromeControlRenderRuntime())
        busy.setAccessMode(.fullAccess)
        busy.activeTurnTaskIDs.insert("inert-render-busy")
        let states = [idle, connected, connecting, denied, busy]
        addTeardownBlock { @MainActor in
            for state in states { state.disconnectChrome() }
            await gate.release()
            for state in states {
                let report = await state.shutdownRuntime()
                XCTAssertTrue(report.succeeded)
            }
        }

        XCTAssertTrue(connected.connectChrome(request()))
        XCTAssertTrue(connecting.connectChrome(request()))
        XCTAssertFalse(denied.connectChrome(request(approved: false)))
        await gate.waitUntilEntered()
        for _ in 0..<100 where connected.chromeConnectionState != .connected {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(connected.chromeConnectionState, .connected)
        XCTAssertEqual(connecting.chromeConnectionState, .connecting)
        XCTAssertFalse(busy.canConnectChrome)

        let root = ChromeControlRenderFixture(
            rows: zip(["Disconnected", "Connected", "Connecting", "Permission required", "Full access · task running"], states)
                .map { ChromeControlRenderRow(title: $0.0, state: $0.1) }
        )
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, .light))
        let size = NSSize(width: 800, height: 420)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible, "Rendering must not foreground a fixture window")
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertGreaterThan(png.count, 3_000, "Expected rendered controls rather than an empty bitmap")

        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HEYDASH_CHROME_CONTROL_RENDER_PATH"]
            ?? environment["TEST_RUNNER_HEYDASH_CHROME_CONTROL_RENDER_PATH"] {
            guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
                throw ChromeControlRenderError.invalidOutputPath
            }
            // Explicit new artifact only; never overwrite an existing file.
            try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            print("HEYDASH_CHROME_CONTROL_RENDER_WRITTEN \(path)")
        }

        connecting.disconnectChrome()
        await gate.release()
        for state in states {
            let report = await state.shutdownRuntime()
            XCTAssertTrue(report.succeeded)
        }
    }

    private func makeState(runtime: ChromeControlRenderRuntime) -> AppState {
        AppState(tasks: [], runtime: runtime, permissionClient: ChromeControlRenderPermissions(),
                 preferences: isolatedTestPreferences())
    }

    private func request(approved: Bool = true) -> ChromeConnectionRequest {
        .init(application: .init(processIdentifier: 123, bundleIdentifier: "com.google.Chrome",
                                 executableURL: URL(fileURLWithPath: "/inert-fixture/Google Chrome")),
              userDataDirectory: URL(fileURLWithPath: "/inert-fixture/never-read"),
              consent: ChromeDebuggingConsent(approvedByUser: approved))
    }

    /// Public AppKit subviews only. No AXUIElement connection to another
    /// process, private SwiftUI type dependency or accessibility action is used.
    private func nativeButtons(in root: NSView) -> [NSButton] {
        var pending = [root]
        var buttons: [NSButton] = []
        var visited = 0
        while let view = pending.popLast(), visited < 256 {
            visited += 1
            if let button = view as? NSButton { buttons.append(button) }
            pending.append(contentsOf: view.subviews)
        }
        return buttons
    }
}

private enum ChromeControlRenderError: Error { case invalidOutputPath }

private struct ChromeControlRenderRow: Identifiable {
    let title: String
    let state: AppState
    var id: String { title }
}

@MainActor
private struct ChromeControlRenderFixture: View {
    let rows: [ChromeControlRenderRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mactopus · native Chrome connection")
                .font(.headline)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    NativeRuntimeStatusBar(state: row.state)
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 800, height: 420, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct ChromeControlRenderPermissions: AutomationPermissionClient {
    func current() -> AutomationPermissionSnapshot { .init(accessibility: .notGranted, screenRecording: .notGranted) }
    func requestAccessibility() -> AutomationPermissionSnapshot { current() }
    func requestScreenRecording() -> AutomationPermissionSnapshot { current() }
}

private actor ChromeControlRenderRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Inert render fixture"
    private let gate: ChromeControlRenderPause?
    init(gate: ChromeControlRenderPause? = nil) { self.gate = gate }
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
    func connectChrome(_ request: ChromeConnectionRequest) async throws {
        try request.consent.check()
        await gate?.suspend()
    }
}

private actor ChromeControlRenderPause {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
