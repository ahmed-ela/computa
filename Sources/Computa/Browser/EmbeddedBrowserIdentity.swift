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

    // Include the measured engine build as well as every advertised product
    // token. An engine update can retain the same Safari marketing version.
    @MainActor static var currentCacheIdentity: String {
        currentApplicationName + "\nWebKit/" + (Product(bundle: Bundle(for: WKWebView.self))?.build ?? "unknown")
    }

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

/// HTTP responses without `Vary: User-Agent` can retain HTML selected for the
/// previous browser identity. Migrate only this app-owned profile's HTTP caches
/// before admitting its first request. Cookies and all website storage survive.
@MainActor
final class EmbeddedBrowserCacheIdentity {
    typealias Removal = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    static let cacheDataTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
    static func defaultsKey(profileID: UUID) -> String {
        "Computa.EmbeddedBrowser.HTTPCacheIdentity.v1." + profileID.uuidString.lowercased()
    }

    private let defaults: UserDefaults
    private let key: String
    private let identity: String
    private let remove: Removal
    private let changes = EmbeddedModelChangeChannel(ownerToken: UUID().uuidString)
    private var started = false
    private var closed = false
    private(set) var ready: Bool

    init(profileID: UUID, identity: String, defaults: UserDefaults, remove: @escaping Removal) {
        self.defaults = defaults
        self.key = Self.defaultsKey(profileID: profileID)
        self.identity = identity
        self.remove = remove
        ready = defaults.string(forKey: key) == identity
    }

    convenience init(profileID: UUID, store: WKWebsiteDataStore, defaults: UserDefaults) {
        self.init(profileID: profileID, identity: EmbeddedBrowserIdentity.currentCacheIdentity, defaults: defaults) { completion in
            store.removeData(ofTypes: Self.cacheDataTypes, modifiedSince: .distantPast, completionHandler: completion)
        }
    }

    func wait(until deadline: ContinuousClock.Instant) async -> Bool {
        guard !closed, !Task.isCancelled, ContinuousClock.now < deadline else { return false }
        if ready { return true }
        if !started {
            started = true
            remove { [weak self] in
                guard let self, !self.closed else { return }
                // A timeout/cancelled caller never marks completion. The real
                // native callback can release later, freshly requested work.
                self.defaults.set(self.identity, forKey: self.key)
                self.ready = true
                self.changes.signal()
            }
        }
        do {
            while !closed, !Task.isCancelled, !ready, ContinuousClock.now < deadline {
                let revision = try changes.currentRevision()
                _ = try await changes.wait(after: revision, until: deadline)
            }
        } catch { return false }
        return !closed && !Task.isCancelled && ready && ContinuousClock.now < deadline
    }

    func close() {
        closed = true
        changes.close()
    }
}
