import Foundation

enum SampleData {
    static let tasks: [AgentTask] = [
        AgentTask(
            title: "Build the local agent shell",
            summary: "Create the native task, transcript, composer, and inspector experience.",
            status: .running,
            updatedAt: .now.addingTimeInterval(-90),
            workspace: "~/Developer/HeyDash",
            model: "Qwen3.8-27B 4-bit",
            branch: "feature/app-shell",
            entries: [
                TimelineEntry(
                    kind: .user,
                    title: "You",
                    body: "Create a native macOS shell for a local coding agent with task history, a transcript, and an inspector.",
                    timestamp: .now.addingTimeInterval(-840)
                ),
                TimelineEntry(
                    kind: .reasoning,
                    title: "Planning the application surface",
                    body: "I’m separating root-owned session state from view-local presentation state and keeping the runtime behind a future typed client boundary.",
                    timestamp: .now.addingTimeInterval(-720)
                ),
                TimelineEntry(
                    kind: .tool,
                    title: "Inspect workspace",
                    body: "Read the package layout and available Swift toolchain.",
                    timestamp: .now.addingTimeInterval(-610),
                    toolEvent: ToolEvent(
                        name: "workspace.inspect",
                        summary: "Checked project files and compiler availability",
                        status: .succeeded,
                        input: "path: ~/Developer/HeyDash",
                        output: "Swift 6 toolchain available; workspace is ready.",
                        duration: 0.34
                    )
                ),
                TimelineEntry(
                    kind: .assistant,
                    title: "HeyDash",
                    body: "The application shell is taking shape. Next I’ll connect the composer to a replaceable local runtime client.",
                    timestamp: .now.addingTimeInterval(-120)
                )
            ]
        ),
        AgentTask(
            title: "Evaluate local model backends",
            summary: "Compare an MLX server with an OpenAI-compatible local endpoint.",
            status: .waiting,
            updatedAt: .now.addingTimeInterval(-3_600),
            workspace: "~/Developer/LocalRuntime",
            model: "Not selected",
            entries: [
                TimelineEntry(
                    kind: .system,
                    title: "Runtime disconnected",
                    body: "Choose and start a local inference provider before continuing.",
                    timestamp: .now.addingTimeInterval(-3_600)
                )
            ]
        ),
        AgentTask(
            title: "Prototype permission flow",
            summary: "Sketch explicit approval states for future computer-use actions.",
            status: .completed,
            updatedAt: .now.addingTimeInterval(-86_400),
            workspace: "~/Developer/HeyDash",
            model: "Design-only",
            entries: [
                TimelineEntry(
                    kind: .assistant,
                    title: "HeyDash",
                    body: "The proposed flow distinguishes read-only observation, reversible interaction, and privileged actions. No automation code was added.",
                    timestamp: .now.addingTimeInterval(-86_400)
                )
            ]
        )
    ]
}
