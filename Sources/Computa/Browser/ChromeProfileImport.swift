import AppKit
import SwiftUI

@MainActor
enum ChromeProfileImport {
    typealias Profile = ChromeProfileLibrary.Profile
    typealias Categories = ChromeProfileLibrary.Categories
    struct Selection {
        let profile: Profile
        let categories: Categories
    }

    private struct PickerSheet: View {
        let profiles: [Profile]
        @State var profile: Profile
        @State var categories = Categories()
        @State var managerUnavailable = false
        let finish: (Selection?) -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import from Chrome").font(.title2.bold())
                Picker("Chrome profile", selection: $profile) {
                    ForEach(profiles) { Text($0.name).tag($0) }
                }
                Toggle("Browsing and search history", isOn: $categories.history)
                Toggle("Bookmarks", isOn: $categories.bookmarks)
                Toggle("Saved passwords from a Chrome export", isOn: $categories.passwords)
                if categories.passwords {
                    Text("In Chrome Password Manager → Settings, export passwords for this profile. You’ll choose the CSV next. Delete the export after importing.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Chrome Password Manager") {
                        managerUnavailable = !ChromeProfileImport.openPasswordManager(for: profile)
                    }
                    if managerUnavailable { Text("Open Password Manager in Chrome to export your passwords.").font(.callout) }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                    Button("Import") { finish(.init(profile: profile, categories: categories)) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!categories.history && !categories.bookmarks && !categories.passwords)
                }
            }.padding(22).frame(width: 400)
        }
    }

    private static func openPasswordManager(for profile: Profile) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let executable = Bundle(url: app)?.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--user-data-dir=" + profile.folder.deletingLastPathComponent().path,
                             "--profile-directory=" + profile.folder.lastPathComponent, "chrome://password-manager/settings"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); return true } catch { return false }
    }

    static func choose(in window: NSWindow, profiles: [Profile]) async -> Selection? {
        guard let first = profiles.first else { return nil }
        let sheet = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Import from Chrome"
        var result: Selection?
        let host = NSHostingController(rootView: PickerSheet(profiles: profiles, profile: first) { selection in
            result = selection
            window.endSheet(sheet)
        })
        sheet.contentViewController = host
        sheet.setContentSize(host.view.fittingSize)
        await window.beginSheet(sheet)
        return result
    }

    static func run(in window: NSWindow, state: AppState, root: URL = ChromeProfileLibrary.chromeRoot,
                    library: ChromeProfileLibrary, vault: BrowserSavedLogins,
                    chooseProfile: (NSWindow, [Profile]) async -> Selection? = choose,
                    chooseCSV: (NSWindow) async -> URL? = BrowserLoginControls.chooseCSV) async {
        func eligible() -> Bool { state.presentedSheet == .settings && !state.approvalGateBlocksInteraction }
        guard eligible(), !state.importingChromeProfile else { return }
        state.importingChromeProfile = true
        defer { state.importingChromeProfile = false }
        do {
            let profiles = try await Task.detached { try ChromeProfileLibrary.profiles(in: root) }.value
            guard eligible() else { return }
            guard !profiles.isEmpty else { state.chromeProfileImportStatus = "No Chrome profiles were found on this Mac."; return }
            guard let selection = await chooseProfile(window, profiles), eligible(), profiles.contains(selection.profile) else { return }
            var file: URL?
            if selection.categories.passwords {
                guard let chosen = await chooseCSV(window), eligible() else { return }
                file = chosen
            }
            let selectedFile = file
            let summary = try await Task.detached {
                let selected = selection.categories
                var parts: [String] = []
                if selected.history || selected.bookmarks {
                    let counts = try library.importPlaces(from: selection.profile, categories: selected)
                    parts.append(counts.summary(for: selected))
                }
                if let file = selectedFile {
                    do { parts.append(try vault.importCSV(at: file).summary) }
                    catch { parts.append((error as? BrowserSavedLogins.Failure ?? .file).localizedDescription) }
                }
                return parts.joined(separator: " ")
            }.value
            state.chromeProfileImportStatus = summary
        } catch {
            state.chromeProfileImportStatus = (error as? ChromeProfileLibrary.Failure ?? .read).localizedDescription
        }
    }
}
