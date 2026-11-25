import WebKit

enum BrowserPageZoomCommand {
    case zoomIn, zoomOut, actualSize

    private static let levels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    func scale(from current: CGFloat) -> CGFloat {
        switch self {
        case .zoomIn: Self.levels.first { $0 > current + 0.001 } ?? Self.levels[Self.levels.count - 1]
        case .zoomOut: Self.levels.last { $0 < current - 0.001 } ?? Self.levels[0]
        case .actualSize: 1
        }
    }
}

/// Only the visible desktop tab fits to the pane. WebKit's native zoom updates both
/// viewport dimensions, including those read by JavaScript to size an inner scroller.
@MainActor
final class EmbeddedBrowserPageFit: NSObject, WKScriptMessageHandler {
    private static let world = WKContentWorld.world(name: "computa.browser.page-fit")
    private let handler = "fit" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private weak var view: WKWebView?
    private var measurement = 0

    init(view: WKWebView) {
        self.view = view
        super.init()
        view.configuration.userContentController.add(self, contentWorld: Self.world, name: handler)
    }

    func observeDocument() {
        guard let view else { return }
        view.callAsyncJavaScript(Self.observeScript, arguments: ["handler": handler],
                                 in: nil, in: Self.world, completionHandler: nil)
        measure()
    }

    func stop() {
        guard let view else { return }
        self.view = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: handler, contentWorld: Self.world)
        view.callAsyncJavaScript("if (globalThis.fitOwner === handler) globalThis.stopPageFit()",
                                 arguments: ["handler": handler], in: nil, in: Self.world, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view, message.webView === view, message.frameInfo.isMainFrame else { return }
        measure()
    }

    private func measure() {
        guard let view, view.bounds.width >= 1 else { return }
        let width = view.bounds.width
        measurement += 1
        let current = measurement
        view.callAsyncJavaScript(Self.measureScript, arguments: ["paneWidth": width],
                                 in: nil, in: Self.world) { [weak self] result in
            guard let self, let view = self.view, measurement == current, abs(view.bounds.width - width) < 0.5,
                  case let .success(value) = result, let scale = value as? Double, scale.isFinite else { return }
            let zoom = min(1, max(0.45, scale))
            if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        }
    }

    private static let measureScript = """
    const root = document.documentElement, body = document.body;
    if (document.contentType !== 'text/html' || !root || !body || !innerWidth ||
        parseFloat(getComputedStyle(root).zoom) !== 1) return 1;
    const inverse = Math.max(1, innerWidth / paneWidth);
    const viewport = root.clientWidth / inverse;
    // Measure the page at its natural width even when WebKit is already zoomed out.
    // The calibration sheet exists only for this synchronous layout read, never for paint.
    let sheet;
    try {
        if (inverse > 1.001) {
            sheet = new CSSStyleSheet();
            sheet.insertRule(':root { zoom: ' + inverse + ' !important }');
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
        const content = Math.max(root.scrollWidth / inverse, body.scrollWidth);
        return viewport > 0 && content > viewport + 1 ? viewport / content : 1;
    } finally {
        if (sheet) document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
    }
    """

    private static let observeScript = """
    if (globalThis.fitOwner === handler) return;
    globalThis.stopPageFit?.();
    if (document.contentType !== 'text/html' || !document.documentElement) return;
    let timer, body;
    function schedule() {
        if (timer !== undefined) return;
        timer = setTimeout(() => {
            timer = undefined;
            if (body !== document.body) {
                if (body) sizes.unobserve(body);
                body = document.body;
                if (body) sizes.observe(body);
            }
            window.webkit.messageHandlers[handler].postMessage(null);
        }, 32);
    }
    const sizes = new ResizeObserver(schedule);
    sizes.observe(document.documentElement);
    const changes = new MutationObserver(schedule);
    changes.observe(document.documentElement, {subtree: true, childList: true, attributes: true, attributeFilter: ['style', 'class', 'hidden']});
    window.addEventListener('resize', schedule);
    document.addEventListener('load', schedule, true);
    function stop() {
        clearTimeout(timer);
        sizes.disconnect();
        changes.disconnect();
        window.removeEventListener('resize', schedule);
        window.removeEventListener('pagehide', stop);
        document.removeEventListener('load', schedule, true);
        delete globalThis.stopPageFit;
        delete globalThis.fitOwner;
    }
    globalThis.fitOwner = handler;
    globalThis.stopPageFit = stop;
    window.addEventListener('pagehide', stop);
    schedule();
    """
}
