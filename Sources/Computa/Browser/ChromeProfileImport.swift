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

    private static func offerHistoryRetry(in window: NSWindow, summary: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Chrome is using its history database"
        alert.informativeText = summary
        alert.addButton(withTitle: "Retry History")
        alert.addButton(withTitle: "Done").keyEquivalent = "\u{1b}"
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func run(in window: NSWindow, state: AppState, root: URL = ChromeProfileLibrary.chromeRoot,
                    library: ChromeProfileLibrary, vault: BrowserSavedLogins,
                    chooseProfile: (NSWindow, [Profile]) async -> Selection? = choose,
                    chooseCSV: (NSWindow) async -> URL? = BrowserLoginControls.chooseCSV,
                    retryHistory: (NSWindow, String) async -> Bool = offerHistoryRetry) async {
        func eligible() -> Bool { state.presentedSheet == .settings && !state.approvalGateBlocksInteraction }
        guard eligible(), !state.importingChromeProfile else { return }
        state.importingChromeProfile = true
        state.chromeProfileImportStatus = nil
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
            state.chromeProfileImportStatus = "Importing the selected Chrome data…"
            let selectedFile = file
            let selected = selection.categories
            let (initialCounts, passwords) = try await Task.detached {
                let counts = try library.importPlaces(from: selection.profile, categories: selected)
                var passwords: String?
                if let file = selectedFile {
                    do { passwords = try vault.importCSV(at: file).summary }
                    catch { passwords = (error as? BrowserSavedLogins.Failure ?? .file).localizedDescription }
                }
                return (counts, passwords)
            }.value
            var counts = initialCounts
            while true {
                let places = counts.summary(for: selected)
                let summary = [places, passwords].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                state.chromeProfileImportStatus = summary
                guard counts.historyBusy, eligible(), await retryHistory(window, summary), eligible() else { return }
                // Chrome can retain the lock after its last window closes. Each retry is user initiated.
                do {
                    let history = try await Task.detached {
                        try library.importPlaces(from: selection.profile, categories: .init(history: true, bookmarks: false))
                    }.value
                    counts.history = history.history
                    counts.historyBusy = history.historyBusy
                } catch {
                    let saved = counts.summary(for: .init(history: false, bookmarks: selected.bookmarks))
                    let reason = (error as? ChromeProfileLibrary.Failure ?? .read).localizedDescription
                    state.chromeProfileImportStatus = [saved, passwords, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                    return
                }
            }
        } catch {
            state.chromeProfileImportStatus = (error as? ChromeProfileLibrary.Failure ?? .read).localizedDescription
        }
    }
}
