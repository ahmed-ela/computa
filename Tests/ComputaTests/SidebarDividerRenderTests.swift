import AppKit
import ScreenCaptureKit
import SwiftUI
import WebKit
import XCTest
@testable import Computa

@available(macOS 14.4, *)
final class SidebarDividerRenderTests: XCTestCase {
    @MainActor
    func testTitleBarStaysStillWhileSidebarDividerMovesBelowIt() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let agent = AgentTask(title: "Agent", summary: "", status: .draft, workspace: "", model: "fixture")
        let state = AppState(tasks: [agent], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        state.appearance = .light
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        func workspaceView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView, web.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil { return web }
            return view.subviews.lazy.compactMap(workspaceView).first
        }
        state.selectTask(agent.id)
        host.layoutSubtreeIfNeeded()
        let shell = try XCTUnwrap(workspaceView(host))
        // The first WebKit paint also configures the native title bar. Take its measurements after that.
        let ready = ContinuousClock.now + .seconds(5)
        let titleReady = """
            document.querySelector('.toolbar-title-block strong')?.textContent === 'Agent'
                && parseFloat(getComputedStyle(document.querySelector('.app-shell')).getPropertyValue('--window-controls-width')) > 0
            """
        while (try? await shell.evaluateJavaScript(titleReady)) as? Bool != true {
            guard ContinuousClock.now < ready else { return XCTFail("The agent title bar did not appear.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The chat title follows the transcript (measured during the transition in EmbeddedBrowserPaneStateTests).
        // Exclude its glyphs here so every pixel of the fixed chrome can be compared.
        _ = try await shell.evaluateJavaScript("document.querySelector('.toolbar-title-block').style.visibility = 'hidden'; true")
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        host.layoutSubtreeIfNeeded()
        let width = Int(window.frame.width)
        let height = try await shell.evaluateJavaScript("Math.round(document.querySelector('.task-toolbar').getBoundingClientRect().height) - 1")
        let barHeight = try XCTUnwrap(height as? Int)
        XCTAssertEqual(CGFloat(barHeight), window.frame.height - window.contentLayoutRect.maxY)
        let rect = CGRect(x: 0, y: 0, width: width, height: 90)
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.sourceRect = rect
        configuration.width = width
        configuration.height = Int(rect.height)

        func frame() async throws -> (header: Data, divider: Int?) {
            host.layoutSubtreeIfNeeded()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            // Convert the top of our own window to one brightness byte per point.
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: Int(rect.height),
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            bitmap.draw(image, in: rect)
            let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
            let row = pixels.advanced(by: (barHeight + 2) * width)
            let divider = (34..<240).first { x in Int(row[x]) + 8 < min(Int(row[x - 1]), Int(row[x + 1])) }
            return (Data(bytes: pixels, count: (barHeight + 1) * width), divider.map { $0 + 1 })
        }

        for kind in ["agent", "browser"] {
            if kind == "browser" { _ = state.newWorkspaceBrowserTab(url: try XCTUnwrap(URL(string: "about:blank"))) }
            let expanded = kind == "browser" ? 230 : 216
            // Wait for the actual expanded divider and a settled title bar before sampling the animation.
            var initial = try await frame()
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(60))
                let next = try await frame()
                if next.divider == expanded && initial.header == next.header { initial = next; break }
                initial = next
            }
            XCTAssertEqual(initial.divider, expanded, kind)
            for boundary in [44, expanded] {
                let seam = initial.header[(2 * width + boundary - 2)...(2 * width + boundary + 1)]
                XCTAssertLessThanOrEqual(Int(try XCTUnwrap(seam.max())) - Int(try XCTUnwrap(seam.min())), 2,
                                         "A vertical divider crosses the \(kind) title bar.")
            }
            for collapsed in [true, false] {
                state.isTaskSidebarCollapsed = collapsed
                let expected = collapsed ? 44 : expanded
                var observedWidths = Set<Int>()
                var fixedHeader = true
                let timeout = ContinuousClock.now + .seconds(2)
                repeat {
                    let next = try await frame()
                    fixedHeader = fixedHeader && next.header == initial.header
                    if let divider = next.divider { observedWidths.insert(divider) }
                    if next.divider == expected { break }
                } while ContinuousClock.now < timeout
                XCTAssertTrue(fixedHeader, "The \(kind) title bar moved while the divider swept through \(observedWidths.sorted()).")
                XCTAssertTrue(observedWidths.contains(expected), "Expected the divider below the header at \(expected). Saw \(observedWidths).")
            }
        }
    }
}
