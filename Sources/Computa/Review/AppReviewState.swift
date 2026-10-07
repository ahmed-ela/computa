import Foundation

/// Only the selected task's native review receipt is exposed to the WebUI.
struct AppReviewState: Codable, Equatable, Sendable {
    var taskID: String
    var scope: FileReviewScope
    var reference: String
    var loading: Bool = false
    var error: String?
    var snapshot: FileReviewSnapshot?
}
