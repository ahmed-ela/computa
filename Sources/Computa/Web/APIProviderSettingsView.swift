import SwiftUI

@MainActor
struct APIProviderSettingsView: View {
    @Bindable var settings: APIProviderSettings
    var alibabaSetupID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var providerID = ""
    @State private var name = ""
    @State private var baseURL = ""
    @State private var wireAPI = APIProviderDefinition.WireAPI.chatCompletions
    @State private var key = ""
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(alibabaSetupID == nil ? "API providers" : "Connect Alibaba Model Studio").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(settings.isConnecting)
            }
            Text("Connect a provider to use its models with your existing task tools and access mode.")
                .foregroundStyle(.secondary)
            if alibabaSetupID == nil, !settings.providers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(settings.providers, id: \.id) { provider in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.name).font(.headline)
                                Text("\(provider.models.count) models").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { load(provider) }
                            Button("Remove", role: .destructive) {
                                Task { try? await settings.remove(providerID: provider.id) }
                            }
                        }
                    }
                }.disabled(!settings.canEditProviders)
                Divider()
            }
            if alibabaSetupID == nil {
                Button("Custom provider") {
                    providerID = "custom-" + UUID().uuidString.prefix(8).lowercased()
                    name = ""; baseURL = "https://"; wireAPI = .chatCompletions; key = ""; inputError = nil; settings.clearError()
                }.disabled(!settings.canEditProviders)
            }
            Form {
                if alibabaSetupID == nil {
                    TextField("Provider ID", text: $providerID)
                    TextField("Name", text: $name)
                    Picker("API format", selection: $wireAPI) {
                        Text("Chat Completions").tag(APIProviderDefinition.WireAPI.chatCompletions)
                        Text("Open Responses").tag(APIProviderDefinition.WireAPI.responses)
                    }
                }
                TextField(alibabaSetupID == nil ? "API base URL" : "Workspace API base URL", text: $baseURL)
                if alibabaSetupID != nil {
                    Text("Paste the OpenAI-compatible URL from your Model Studio workspace, ending in /compatible-mode/v1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField("API key", text: $key)
                Text("Keys stay in macOS Keychain. Leave the key blank to keep it when editing the same endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!settings.canEditProviders)
            if let error = inputError ?? settings.error { Text(error).foregroundStyle(.red).font(.callout).accessibilityLabel(error) }
            HStack {
                if settings.isConnecting { ProgressView().controlSize(.small); Text("Connecting and loading models…") }
                Spacer()
                Button("Connect and load models") { connect() }
                    .buttonStyle(.borderedProminent).disabled(!settings.canEditProviders)
            }
        }
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(settings.isConnecting)
        .onAppear {
            guard let id = alibabaSetupID else { return }
            if let existing = settings.providers.first(where: { $0.id == id && $0.isAlibabaModelStudioInference }) {
                load(existing)
            } else {
                providerID = id
                name = "Alibaba"
                settings.clearError()
            }
        }
        .onDisappear { key = "" }
    }
    private func load(_ definition: APIProviderDefinition) {
        providerID = definition.id; name = definition.name; baseURL = definition.baseURL.absoluteString
        wireAPI = definition.wireAPI; key = ""; inputError = nil; settings.clearError()
    }
    private func connect() {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            inputError = "Enter an API base URL."; return
        }
        let definition = APIProviderDefinition(id: providerID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: url, wireAPI: wireAPI, models: [])
        if alibabaSetupID != nil, !definition.isAlibabaModelStudioInference {
            inputError = "Enter your Alibaba Model Studio workspace endpoint."
            return
        }
        inputError = nil
        let supplied = key
        key = ""
        Task {
            do {
                try await settings.connect(definition, key: supplied)
                if alibabaSetupID != nil {
                    let connected = settings.providers.filter { $0.id == definition.id }
                    if APIProviderCatalog.options(for: connected).isEmpty {
                        inputError = "Connected. This workspace did not return a supported Qwen3.7 Flash model."
                    } else { dismiss() }
                }
            } catch { /* APIProviderSettings publishes the connection error. */ }
        }
    }
}
