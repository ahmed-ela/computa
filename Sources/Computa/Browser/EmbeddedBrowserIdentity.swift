import Foundation
import WebKit

/// Browser compatibility identity for the system WebKit used by every embedded tab.
/// Keep WebKit's platform/engine prefix and add only corroborated product tokens.
enum EmbeddedBrowserIdentity {
    struct Product: Equatable, Sendable {
        let identifier: String
        let version: String
        let build: String

        init(identifier: String, version: String, build: String) {
            self.identifier = identifier
            self.version = version
            self.build = build
        }

        init?(bundle: Bundle?) {
            guard let bundle, let identifier = bundle.bundleIdentifier,
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
            self.init(identifier: identifier, version: version, build: build)
        }
    }

    @MainActor static let currentApplicationName: String = {
        // Use the installed system Safari, never whichever app Launch Services
        // happens to register as the user's browser. Both products must identify
        // the exact same engine build before adding Safari compatibility tokens.
        applicationName(safari: Product(bundle: Bundle(path: "/Applications/Safari.app")),
                        webKit: Product(bundle: Bundle(for: WKWebView.self)),
                        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }()

    static func applicationName(safari: Product?, webKit: Product?, appVersion: String?) -> String {
        let app = appVersion.flatMap { validVersion($0) ? "Computa/\($0)" : nil } ?? "Computa"
        guard let safari, let webKit,
              safari.identifier == "com.apple.Safari", webKit.identifier == "com.apple.WebKit",
              validVersion(safari.version), validVersion(safari.build), validVersion(webKit.build),
              safari.build == webKit.build else { return app }
        // 605.1.15 is WebKit's frozen compatibility token, not its actual engine
        // version. WebKit's macOS UA keeps that token in its unmodified prefix:
        // https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/mac/UserAgentMac.mm
        // The Version token comes from the installed, matching Safari release;
        // do not guess a newer release if Safari is missing or builds disagree.
        return "Version/\(safari.version) Safari/605.1.15 \(app)"
    }

    private static func validVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 48 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count <= 6 && components.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 8 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
}
