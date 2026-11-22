import WebKit

/// The ordinary page loads its own icon with WebKit's network, profile and CORS rules.
/// Only a small, rasterized PNG crosses into Kolmogor's privileged interface.
enum BrowserFavicon {
    @MainActor
    static func read(in view: WKWebView) async -> Data? {
        let script = """
        const declared = [...document.querySelectorAll('link[rel~="icon" i], link[rel~="apple-touch-icon" i]')]
            .filter(link => !link.media || matchMedia(link.media).matches)
            .map(link => link.href);
        const candidates = declared.filter(href => /^(https?:|data:image\\/)/i.test(href));
        const fallback = new URL('/favicon.ico', location.href).href;
        const urls = [...new Set(candidates)].slice(0, 4);
        if (!declared.includes('data:,') && !urls.includes(fallback)) urls.push(fallback);
        for (const url of urls) {
            const image = new Image();
            image.crossOrigin = 'anonymous';
            const loaded = await new Promise(resolve => {
                const finish = value => {
                    clearTimeout(timer);
                    image.onload = image.onerror = null;
                    resolve(value);
                };
                const timer = setTimeout(() => finish(false), 1800);
                image.onload = () => finish(true);
                image.onerror = () => finish(false);
                image.src = url;
            });
            if (!loaded || !image.naturalWidth || !image.naturalHeight) continue;
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 32;
            const scale = 32 / Math.max(image.naturalWidth, image.naturalHeight);
            const w = image.naturalWidth * scale, h = image.naturalHeight * scale;
            try {
                canvas.getContext('2d').drawImage(image, (32-w)/2, (32-h)/2, w, h);
                return canvas.toDataURL('image/png').split(',')[1];
            } catch {}
        }
        return null;
        """
        guard let encoded = try? await view.callAsyncJavaScript(script, arguments: [:], in: nil,
            contentWorld: .defaultClient) as? String, encoded.utf8.count <= 10_000 else { return nil }
        return Data(base64Encoded: encoded)
    }
}
