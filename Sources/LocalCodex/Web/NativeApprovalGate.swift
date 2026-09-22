import SwiftUI

struct NativeApprovalGate: View {
    let request: ActionApprovalRequest
    let remainingCount: Int
    let isResolving: Bool
    let resolve: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 30, height: 30)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(request.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(request.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !request.details.isEmpty {
                    DisclosureGroup("Request details") {
                        ScrollView {
                            Text(request.details)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                if remainingCount > 0 {
                    Text("\(remainingCount) more waiting")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Button("Decline") { resolve(false) }
                    .buttonStyle(.bordered)
                Button("Allow once") { resolve(true) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isResolving)
        }
        .padding(14)
        .frame(maxWidth: 650)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
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
