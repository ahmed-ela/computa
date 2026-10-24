import SwiftUI

@MainActor
struct APIProviderSettingsView: View {
    @Bindable var settings: APIProviderSettings
    @Environment(\.dismiss) private var dismiss
    @State private var providerID = "cerebras"
    @State private var name = "Cerebras"
    @State private var baseURL = "https://api.cerebras.ai/v1"
    @State private var wireAPI = APIProviderDefinition.WireAPI.chatCompletions
    @State private var key = ""
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("API providers").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(settings.isConnecting)
            }
            Text("Connect a provider to use its models with your existing task tools and access mode.")
                .foregroundStyle(.secondary)
            if !settings.providers.isEmpty {
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
            HStack {
                Button("Cerebras") { load(.cerebras) }
                Button("Custom provider") {
                    providerID = "custom-" + UUID().uuidString.prefix(8).lowercased()
                    name = ""; baseURL = "https://"; wireAPI = .chatCompletions; key = ""; inputError = nil; settings.clearError()
                }
            }.disabled(!settings.canEditProviders)
            Form {
                TextField("Provider ID", text: $providerID)
                TextField("Name", text: $name)
                TextField("API base URL", text: $baseURL)
                Picker("API format", selection: $wireAPI) {
                    Text("Chat Completions").tag(APIProviderDefinition.WireAPI.chatCompletions)
                    Text("Open Responses").tag(APIProviderDefinition.WireAPI.responses)
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
        inputError = nil
        let supplied = key
        key = ""
        Task { try? await settings.connect(definition, key: supplied) }
    }
}
