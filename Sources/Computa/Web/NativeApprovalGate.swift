import SwiftUI

struct NativeApprovalGate: View {
    let request: ActionApprovalRequest
    let remainingCount: Int
    let isResolving: Bool
    let resolve: (Bool) -> Void
    @FocusState private var declineFocused: Bool
    @AccessibilityFocusState private var declineAccessibilityFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Approval required")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(request.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if remainingCount > 0 {
                    Text("\(remainingCount) more waiting")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.05), in: Capsule())
                }
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text("Requested action")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(request.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 68)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }

            if !request.details.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Exact request details")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(request.details)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 96)
                    .padding(10)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .padding(.top, 14)
            }

            Divider()
                .padding(.top, 16)
                .padding(.bottom, 12)

            HStack(spacing: 10) {
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Resolving approval…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Decline") { resolve(false) }
                    .buttonStyle(.bordered)
                    .focused($declineFocused)
                    .accessibilityFocused($declineAccessibilityFocused)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isResolving)
                Button("Allow once") { resolve(true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isResolving)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 28, y: 10)
        .onAppear {
            declineFocused = true
            declineAccessibilityFocused = true
        }
        .onChange(of: request) { _, _ in
            declineFocused = true
            declineAccessibilityFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Native action approval required")
    }

    private var iconName: String {
        switch request.kind {
        case .command: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .computerUse: "macwindow.and.cursorarrow"
        }
    }
}
