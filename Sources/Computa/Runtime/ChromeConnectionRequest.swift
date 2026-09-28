import Foundation

/// Native-host input, never a tool argument or a WebKit bridge message. Each
/// confirmation creates a fresh identity and non-persisted, revocable consent.
struct ChromeConnectionRequest: Sendable {
    let id: UUID
    let application: BorrowedChromeApplicationIdentity
    let userDataDirectory: URL
    let consent: ChromeDebuggingConsent
    let extensionAdmission: ExtensionChromeAdmission?

    init(
        id: UUID = UUID(),
        application: BorrowedChromeApplicationIdentity,
        userDataDirectory: URL,
        consent: ChromeDebuggingConsent,
        extensionAdmission: ExtensionChromeAdmission? = nil
    ) {
        self.id = id
        self.application = application
        self.userDataDirectory = userDataDirectory
        self.consent = consent
        self.extensionAdmission = extensionAdmission
    }
}

enum ChromeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(message: String)
}
