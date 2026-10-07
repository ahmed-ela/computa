import Foundation

enum FileReviewScope: String, Codable, CaseIterable, Hashable, Sendable {
    case lastTurn, unstaged, staged, branch, commit
}

enum FileReviewOperation: String, Codable, Hashable, Sendable {
    case stage, unstage, revert
}

struct FileReviewHunk: Codable, Hashable, Sendable {
    let id: String
    let header: String
    let oldStart: Int
    let newStart: Int
}

struct FileReviewFile: Codable, Hashable, Sendable {
    let id: String
    let path: String
    let previousPath: String?
    let status: String
    let diff: String
    let additions: Int
    let deletions: Int
    let binary: Bool
    let truncated: Bool
    let hunks: [FileReviewHunk]
}

struct FileReviewSnapshot: Codable, Hashable, Sendable {
    let id: String
    let workspace: String
    let scope: FileReviewScope
    let reference: String?
    let revision: String
    let files: [FileReviewFile]
    let canStage: Bool
    let canUnstage: Bool
    let canRevert: Bool
}

enum FileReviewError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case staleSnapshot
    case invalidSelection
    case unsupportedMutation
    case commandFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .commandFailed(let reason): reason
        case .staleSnapshot: "The files or Git index changed. Refresh the diff before changing it."
        case .invalidSelection: "That file or hunk is no longer available in this review."
        case .unsupportedMutation: "This change cannot be modified from this review."
        case .busy: "A file review operation is already in progress."
        }
    }
}
