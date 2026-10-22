import Foundation

/// Finite website operation failures shared by the embedded inference driver.
/// Raw webpage or transport messages never enter user-facing diagnostics.
enum WebsiteProviderFailure: Error, LocalizedError {
    case signInRequired
    case operation(Reason)

    static func from(errorCode: String?) -> Self? {
        if errorCode == "web_sign_in_required" { return .signInRequired }
        guard let errorCode, let reason = Reason(rawValue: errorCode) else { return nil }
        return .operation(reason)
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to the selected website in Computa's built-in browser, then retry."
        case .operation(let reason): "\(reason.message) (\(reason.rawValue))"
        }
    }

    enum Reason: String, CaseIterable, Sendable {
        case temporaryModeUnverified = "web_temporary_mode_unverified"
        case temporaryModeUnavailable = "web_temporary_mode_unavailable"
        case composerUnavailable = "web_composer_unavailable"
        case composerNotEmpty = "web_composer_not_empty"
        case promptNotInserted = "web_prompt_not_inserted"
        case sendUnavailable = "web_send_unavailable"
        case documentChanged = "web_document_changed"
        case invalidDocument = "web_invalid_document"
        case conversationChanged = "web_conversation_changed"
        case notFresh = "web_not_fresh"
        case notReady = "web_not_ready"
        case staleSession = "web_stale_session"
        case readyTimeout = "web_ready_timeout"
        case responseTimeout = "web_response_timeout"
        case responseInterrupted = "web_response_interrupted"
        case responseTooLarge = "web_response_too_large"
        case tabUnavailable = "web_tab_unavailable"
        case tabDetached = "web_tab_detached"
        case capacityExceeded = "web_capacity_exceeded"
        case sendFailed = "web_send_failed"
        case operationFailed = "web_operation_failed"
        case cleanupUnverified = "web_cleanup_unverified"
        case cleanupFailed = "web_cleanup_failed"

        var message: String {
            switch self {
            case .temporaryModeUnverified: "The website did not confirm its temporary chat mode."
            case .temporaryModeUnavailable: "The website's temporary chat control is unavailable."
            case .composerUnavailable: "The website composer could not receive text."
            case .composerNotEmpty: "The website composer already contains text."
            case .promptNotInserted: "The website composer did not contain the complete intended prompt."
            case .sendUnavailable: "The website's Send control is unavailable."
            case .documentChanged: "The website document changed or its ownership could not be verified."
            case .invalidDocument: "The website did not return an inspectable document."
            case .conversationChanged: "The website conversation no longer matches this task's owned session."
            case .notFresh: "The website opened a conversation that already contains messages."
            case .notReady: "The website session is not ready to receive another prompt."
            case .staleSession: "The website session's authority is no longer current."
            case .readyTimeout: "The website did not become ready before its deadline."
            case .responseTimeout: "The website response did not finish before its deadline."
            case .responseInterrupted: "The website response was interrupted and could not be used."
            case .responseTooLarge: "The website response exceeded the local transport limit."
            case .tabUnavailable: "The owned website tab is unavailable."
            case .tabDetached: "The owned website tab was closed or its automation was canceled."
            case .capacityExceeded: "Too many owned website sessions are still active."
            case .sendFailed: "The website prompt submission failed."
            case .operationFailed: "The selected website operation failed."
            case .cleanupUnverified: "The website session's ownership could not be verified during cleanup."
            case .cleanupFailed: "The temporary website session could not be closed."
            }
        }
    }

}
