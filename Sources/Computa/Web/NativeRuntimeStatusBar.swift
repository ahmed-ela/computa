import AppKit
import SwiftUI

/// A native control surface outside the WebKit message bridge. Neither model
/// output nor JavaScript can enable Full access through a bridge action.
@MainActor
struct NativeRuntimeStatusBar: View {
    @Bindable var state: AppState
    @State private var approvalErrorPresented = false

    var body: some View {
        HStack(spacing: 10) {
            if state.approvalGateBlocksInteraction {
                // General Settings yields to approvals. Its gear can still open
                // the native access settings without covering the approval card.
                Menu {
                    NativeAccessModePicker(state: state)
                    Divider()
                    Text("Full access automatically approves waiting action requests.")
                } label: { settingsIcon }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Settings")
                .help("Access mode settings")
            } else {
                Button {
                    if state.presentSettings() { state.refreshAutomationPermissions() }
                } label: { settingsIcon }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .help("Settings")
            }

            if state.accessMode == .askEveryTime, !state.resolvingApprovalIDs.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Resolving approval…").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let error = state.automaticApprovalError {
                Button {
                    approvalErrorPresented.toggle()
                } label: {
                    Label("Action paused", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .disabled(state.approvalGateBlocksInteraction)
                .popover(isPresented: $approvalErrorPresented) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Action could not be approved").font(.headline)
                        Text(error).textSelection(.enabled)
                        Text("In Settings, choose Ask every time to review or decline this action.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(18)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer(minLength: 12)

            // Temporarily hide context usage from the status bar.
            // ContextUsageIndicator(state: state)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .lineLimit(1)
        .disabled(state.presentedSheet != nil)
        .onChange(of: state.approvalGateBlocksInteraction) { _, blocked in
            if blocked {
                approvalErrorPresented = false
            }
        }
        .onChange(of: state.presentedSheet) { _, sheet in
            if sheet != nil {
                approvalErrorPresented = false
            }
        }
        .onChange(of: state.automaticApprovalError) { _, value in
            if let value {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Action paused. \(value)",
                               .priority: NSAccessibilityPriorityLevel.high.rawValue])
            } else {
                approvalErrorPresented = false
            }
        }
    }

    private var settingsIcon: some View {
        Label("Settings", systemImage: "gearshape")
            .labelStyle(.iconOnly)
            .font(.system(size: 13))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

@MainActor
private struct NativeAccessModePicker: View {
    let state: AppState

    var body: some View {
        Picker("Access mode", selection: Binding(
            get: { state.accessMode },
            set: { state.setAccessMode($0) }
        )) {
            ForEach(AccessMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
    }
}

@MainActor
struct NativeAccessModeSettings: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Access mode").font(.headline)
            NativeAccessModePicker(state: state)
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(state.presentedSheet != .settings || state.approvalGateBlocksInteraction)
            Text("Full access automatically approves action requests and allows terminal commands and file operations outside the workspace, with network access. macOS permissions still apply.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Your choice is saved for new submissions. Running turns keep their execution permissions.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

@MainActor
private struct ContextUsageIndicator: View {
    let state: AppState
    @State private var contextPresented = false

    var body: some View {
        let taskID = state.selectedTaskID
        let usage = taskID.flatMap { state.contextUsageByTask[$0] }
        let compaction = taskID.flatMap { state.compactionStateByTask[$0] }
        let context = ContextIndicatorPresentation(usage: usage, compaction: compaction)

        Button { contextPresented.toggle() } label: {
            HStack(spacing: 7) {
                if compaction == .running {
                    ProgressView().controlSize(.mini)
                        .frame(width: 19, height: 19)
                        .accessibilityHidden(true)
                } else {
                    Gauge(value: context.fraction ?? 0, in: 0...1) {
                        Text("Context usage")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(context.needsAttention ? Color.orange : Color.secondary)
                    .scaleEffect(0.38)
                    .frame(width: 19, height: 19)
                    .opacity(context.fraction == nil ? 0.45 : 1)
                    .accessibilityHidden(true)
                }
                Text(context.label)
                    .font(.system(size: 11))
                    .monospacedDigit()
            }
            .foregroundStyle(context.needsAttention ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(state.approvalGateBlocksInteraction)
        .accessibilityLabel("Context usage")
        .accessibilityValue(context.accessibilityValue)
        .help(context.detail)
        .popover(isPresented: $contextPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Context window").font(.headline)
                Text(context.detail).textSelection(.enabled)
                Text("Automatic compaction keeps a shorter summary for the model; the conversation remains visible. Summaries can omit details.")
                    .foregroundStyle(.secondary)
                Text("Usage is the last measured model request, not lifetime token consumption. New input and tool results may add more.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(18)
            .frame(width: 330, alignment: .leading)
        }
        .onChange(of: state.selectedTaskID) { _, _ in contextPresented = false }
        .onChange(of: state.approvalGateBlocksInteraction || state.presentedSheet != nil) { _, blocked in
            if blocked { contextPresented = false }
        }
    }
}

/// Keep unavailable measurements visibly distinct from a measured empty window.
struct ContextIndicatorPresentation: Equatable {
    let fraction: Double?
    let label: String
    let detail: String
    let accessibilityValue: String
    let needsAttention: Bool

    init(usage: RuntimeContextUsage?, compaction: RuntimeCompactionState?) {
        if compaction == .running {
            fraction = nil
            label = "Compacting context…"
            detail = "The local runtime is summarizing the conversation. Queued messages wait until it finishes."
            accessibilityValue = "Compacting"
            needsAttention = false
            return
        }
        if case .failed(let message) = compaction {
            fraction = usage?.fractionUsed
            label = "Context needs attention"
            detail = "Compaction did not finish: \(message)"
            accessibilityValue = detail
            needsAttention = true
            return
        }
        fraction = usage?.fractionUsed
        needsAttention = (fraction ?? 0) >= 0.85
        if let usage, let window = usage.contextWindow, let fraction {
            let percent = Int((fraction * 100).rounded())
            label = "\(percent)% context"
            detail = "\(usage.usedTokens.formatted()) of \(window.formatted()) tokens used in the last model request. Automatic compaction is enabled."
            accessibilityValue = "\(percent) percent used; \(usage.usedTokens) of \(window) tokens"
        } else {
            label = "Context —"
            detail = compaction == .completed
                ? "Context was compacted. Usage will refresh after the next measured model request."
                : "Context usage is not available yet. It appears when the runtime reports a measured token count and context limit."
            accessibilityValue = "Usage not available"
        }
    }
}
