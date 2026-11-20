import WebKit

/// A presentation-only stylesheet for the visible desktop tab. All measurements use the
/// top document's geometry. No page contents or messages cross into the native app.
@MainActor
enum EmbeddedBrowserPageFit {
    private static let world = WKContentWorld.world(name: "computa.browser.page-fit")

    static func start(in view: WKWebView) {
        view.evaluateJavaScript(startScript, in: nil, in: world, completionHandler: nil)
    }

    static func stop(in view: WKWebView) {
        view.evaluateJavaScript("globalThis.stopPageFit?.()", in: nil, in: world, completionHandler: nil)
    }

    private static let startScript = """
    (() => {
        if (globalThis.stopPageFit || document.contentType !== 'text/html') return;
        const root = document.documentElement;
        if (!root) return;
        let sheet, rule, observedBody, timer;
        const minimumScale = 0.45;
        function fit() {
            timer = undefined;
            const body = document.body;
            if (!body || !root.isConnected) return;
            if (body !== observedBody) {
                if (observedBody) sizes.unobserve(observedBody);
                sizes.observe(body);
                observedBody = body;
            }
            // Measure at the site's own scale and restore the fit before the next paint.
            // Otherwise the result of the previous fit becomes the input to the next one.
            if (sheet) sheet.disabled = true;
            const viewport = root.clientWidth;
            const content = Math.max(root.scrollWidth, body.scrollWidth);
            if (!viewport || content <= viewport + 1 || parseFloat(getComputedStyle(root).zoom) !== 1) return;
            if (!sheet) {
                sheet = new CSSStyleSheet();
                sheet.insertRule(':root {}');
                rule = sheet.cssRules[0];
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
            }
            rule.style.zoom = Math.max(minimumScale, viewport / content);
            sheet.disabled = false;
        }
        function schedule() {
            if (timer === undefined) timer = setTimeout(fit, 32);
        }
        const sizes = new ResizeObserver(schedule);
        sizes.observe(root);
        const changes = new MutationObserver(schedule);
        changes.observe(root, {subtree: true, childList: true, attributes: true, attributeFilter: ['style', 'class', 'hidden']});
        window.addEventListener('resize', schedule);
        document.addEventListener('load', schedule, true);
        function stop() {
            clearTimeout(timer);
            sizes.disconnect();
            changes.disconnect();
            window.removeEventListener('resize', schedule);
            window.removeEventListener('pagehide', stop);
            document.removeEventListener('load', schedule, true);
            if (sheet) document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
            delete globalThis.stopPageFit;
        }
        globalThis.stopPageFit = stop;
        window.addEventListener('pagehide', stop);
        fit();
    })()
    """
}
