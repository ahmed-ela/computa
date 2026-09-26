import SwiftUI

enum TaskStatus: String, CaseIterable, Sendable {
    case running
    case waiting
    case completed
    case draft

    var label: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .draft: "Draft"
        }
    }

}

enum TimelineEntryKind: String, Sendable {
    case user
    case assistant
    case reasoning
    case tool
    case system

    var label: String {
        switch self {
        case .user: "You"
        case .assistant: "Macrouse"
        case .reasoning: "Working"
        case .tool: "Tool"
        case .system: "System"
        }
    }

}

enum ToolRunStatus: String, Sendable {
    case running
    case succeeded
    case needsApproval
    case failed

    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .needsApproval: "Needs approval"
        case .failed: "Failed"
        }
    }

}

struct ToolEvent: Hashable, Sendable {
    var name: String
    var summary: String
    var status: ToolRunStatus
    var input: String
    var output: String?
    var duration: TimeInterval?
}

struct ActionApprovalRequest: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case command
        case fileChange
        case computerUse

    }

    let id: String
    let taskID: AgentTask.ID?
    let kind: Kind
    let title: String
    let summary: String
    let details: String
}

struct TimelineEntry: Identifiable, Hashable, Sendable {
    let id: String
    var kind: TimelineEntryKind
    var title: String
    var body: String
    var timestamp: Date
    var toolEvent: ToolEvent?

    init(
        id: String = UUID().uuidString,
        kind: TimelineEntryKind,
        title: String,
        body: String,
        timestamp: Date = .now,
        toolEvent: ToolEvent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.timestamp = timestamp
        self.toolEvent = toolEvent
    }
}

struct AgentTask: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var summary: String
    var status: TaskStatus
    var updatedAt: Date
    var workspace: String
    var model: String
    var branch: String?
    var entries: [TimelineEntry]

    init(
        id: String = UUID().uuidString,
        title: String,
        summary: String,
        status: TaskStatus,
        updatedAt: Date = .now,
        workspace: String,
        model: String,
        branch: String? = nil,
        entries: [TimelineEntry] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
        self.updatedAt = updatedAt
        self.workspace = workspace
        self.model = model
        self.branch = branch
        self.entries = entries
    }
}

/// Unsent, app-session-local follow-ups. They are not transcript messages until
/// dispatched, and cannot be edited or reordered while delivery is in flight.
struct QueuedPrompt: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, editing, sending, failed
    }

    let id: String
    var text: String
    var status: Status = .queued
    var error: String?

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

struct PromptReceipt: Equatable, Codable, Sendable {
    let id: String
    let taskID: String
    let accepted: Bool
    let revision: UInt64
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SheetDestination: String, Identifiable, Sendable {
    case settings

    var id: String { rawValue }
}
