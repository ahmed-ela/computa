import AppKit
import SwiftUI

/// A native control surface outside the WebKit message bridge. Neither model
/// output nor JavaScript can enable Full access through a bridge action.
@MainActor
struct NativeRuntimeStatusBar: View {
    @Bindable var state: AppState
    @State private var contextPresented = false
    @State private var approvalErrorPresented = false

    private var usage: RuntimeContextUsage? {
        state.selectedTaskID.flatMap { state.contextUsageByTask[$0] }
    }

    private var compaction: RuntimeCompactionState? {
        state.selectedTaskID.flatMap { state.compactionStateByTask[$0] }
    }

    private var context: ContextIndicatorPresentation {
        .init(usage: usage, compaction: compaction)
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Access mode", selection: Binding(
                    get: { state.accessMode },
                    set: { state.setAccessMode($0) }
                )) {
                    ForEach(AccessMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Divider()
                Text("Full access automatically approves app action requests.")
                Text("macOS permissions and tool validation still apply.")
                Text("Your choice is remembered when Computa relaunches.")
            } label: {
                Label(state.accessMode.label, systemImage: state.accessMode == .fullAccess
                    ? "bolt.shield" : "hand.raised")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Access mode")
            .accessibilityValue(state.accessMode.label)
            .help("Choose whether Computa asks before protected actions. This setting applies to all tasks and is remembered across launches.")

            NativeChromeConnectionControl(state: state)

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
                        Text("Switch to Ask every time to review or decline it. No automatic retry was made.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(18)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer(minLength: 12)

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
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(state.presentedSheet != nil)
        .onChange(of: state.selectedTaskID) { _, _ in contextPresented = false }
        .onChange(of: state.approvalGateBlocksInteraction) { _, blocked in
            if blocked {
                contextPresented = false
                approvalErrorPresented = false
            }
        }
        .onChange(of: state.presentedSheet) { _, sheet in
            if sheet != nil {
                contextPresented = false
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
