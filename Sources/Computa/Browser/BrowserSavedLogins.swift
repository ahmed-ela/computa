import Foundation
import Security
import TabularData

/// Each exact HTTPS origin has a separate, local-only Keychain service. A password is never part of a UI snapshot.
struct BrowserSavedLogins: Sendable {
    static func forProfile(_ id: UUID) -> Self {
        Self(servicePrefix: "com.ahmedelamin.LocalCodex.browser-passwords.v1." + id.uuidString + ".")
    }
    let servicePrefix: String

    enum Failure: LocalizedError {
        case file, tooLarge, keychain, site, form, changed

        var errorDescription: String? {
            switch self {
            case .file: "Choose a Chrome password export with URL, username, and password columns."
            case .tooLarge: "Choose a CSV file under 16 MB with at most 10,000 logins."
            case .keychain: "Couldn’t access the local Keychain. Unlock it and try again."
            case .site: "There are no saved logins for this HTTPS site."
            case .form: "Open the site’s sign-in form and try again."
            case .changed: "The selected page changed. Use Fill Saved Login again on the intended page."
            }
        }
    }

    static func origin(for url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https",
              (try? EmbeddedBrowserURLPolicy.validate(url)) != nil,
              let host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
        return "https://" + host + port
    }

    struct ImportResult: Equatable, Sendable {
        var added = 0
        var existing = 0
        var skipped = 0
        var keychainFailure = false

        var summary: String {
            var parts = ["Imported \(added) saved \(added == 1 ? "login" : "logins")."]
            if existing > 0 { parts.append("\(existing) already saved.") }
            if skipped > 0 { parts.append("\(skipped) missing a password or supported HTTPS address.") }
            if keychainFailure { parts.append("Import stopped at a Keychain error. Unlock the Keychain and retry.") }
            return parts.joined(separator: " ")
        }
    }

    func importCSV(at file: URL) throws -> ImportResult {
        let limit = 16 * 1024 * 1024
        let frame: DataFrame
        do {
            guard file.isFileURL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { throw Failure.file }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: limit + 1) else { throw Failure.file }
            guard data.count <= limit else { throw Failure.tooLarge }
            let columns = ["url", "username", "password"]
            frame = try DataFrame(csvData: data, columns: columns, types: Dictionary(uniqueKeysWithValues: columns.map { ($0, CSVType.string) }),
                                  options: CSVReadingOptions(nilEncodings: []))
            guard Set(frame.columns.map(\.name)) == Set(columns) else { throw Failure.file }
            guard frame.rows.count <= 10_000 else { throw Failure.tooLarge }
        } catch let error as Failure { throw error }
        catch { throw Failure.file } // Parser errors can include cell contents.

        var result = ImportResult()
        for row in frame.rows {
            guard let address = row["url"] as? String, let origin = Self.origin(for: URL(string: address)),
                  let password = row["password"] as? String, !password.isEmpty else { result.skipped += 1; continue }
            var item = query(origin)
            item[kSecAttrAccount as String] = row["username"] as? String ?? ""
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "Kolmogor · " + origin
            switch SecItemAdd(item as CFDictionary, nil) {
            case errSecSuccess: result.added += 1
            case errSecDuplicateItem: result.existing += 1
            default: result.keychainFailure = true; return result
            }
        }
        return result
    }

    func accounts(for origin: String) throws -> [String] {
        var item = query(origin)
        item[kSecMatchLimit as String] = kSecMatchLimitAll
        item[kSecReturnAttributes as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let values = value as? [[String: Any]] else { throw Failure.keychain }
        return values.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func password(for account: String, at origin: String) throws -> String {
        var item = query(origin)
        item[kSecAttrAccount as String] = account
        item[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let password = String(data: data, encoding: .utf8) else { throw Failure.keychain }
        return password
    }

    private func query(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servicePrefix + origin,
         kSecAttrSynchronizable as String: false]
    }
}
