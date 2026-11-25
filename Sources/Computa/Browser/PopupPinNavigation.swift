import Foundation

/// WebKit keeps the live opener relationship. A pin may capture a standalone GET page for the next launch.
enum PopupPinNavigation {
    case pending, get, response(URL), document(URL), signIn

    mutating func observe(_ url: URL?) {
        if EmbeddedBrowserURLPolicy.isSignInAddress(url) { self = .signIn }
    }

    mutating func request(_ request: URLRequest) {
        observe(request.url)
        if case .signIn = self { return }
        self = request.httpMethod == "GET" ? .get : .pending
    }

    mutating func receive(_ response: HTTPURLResponse) {
        observe(response.url)
        guard case .get = self, (200..<300).contains(response.statusCode),
              let url = EmbeddedBrowserURLPolicy.workspaceAddress(response.url) else { return }
        self = .response(url)
    }

    mutating func commit(_ url: URL?) {
        observe(url)
        guard case let .response(response) = self, let url,
              var location = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var resource = URLComponents(url: response, resolvingAgainstBaseURL: false) else { return }
        location.fragment = nil
        resource.fragment = nil
        if location == resource { self = .document(url) }
    }

    func address(_ current: URL?) -> URL? {
        guard case let .document(document) = self, let current,
              current.scheme == document.scheme, current.host == document.host, current.port == document.port,
              !EmbeddedBrowserURLPolicy.isSignInAddress(current) else { return nil }
        // Includes same-origin history.pushState and fragment changes within the committed document.
        return EmbeddedBrowserURLPolicy.workspaceAddress(current)
    }
}
