import Foundation

/// Remembers the exact native-user-approved Chrome scope, never a live
/// connection capability. Reconnection still requires a fresh process identity,
/// consent object, endpoint and runtime validation. No profile is read here.
struct RememberedChromeConnection: Codable, Equatable, Sendable {
    static let preferenceKey = "HeyDash.rememberedChromeConnection"

    let version: Int
    let bundleID: String
    let executablePath: String
    let userDataDirectoryPath: String

    init(request: ChromeConnectionRequest) throws {
        try request.consent.check()
        try self.init(application: request.application, userDataDirectory: request.userDataDirectory)
    }

    private init(application: BorrowedChromeApplicationIdentity, userDataDirectory: URL) throws {
        guard application.bundleIdentifier == "com.google.Chrome",
              application.processIdentifier > 0 else { throw ScopeError.invalidScope }
        let executable = try Self.validatedPath(application.executableURL)
        let directory = try Self.validatedPath(userDataDirectory)
        guard URL(fileURLWithPath: executable).lastPathComponent == "Google Chrome" else {
            throw ScopeError.invalidScope
        }
        version = 1
        bundleID = application.bundleIdentifier
        executablePath = executable
        userDataDirectoryPath = directory
    }

    static func load(from preferences: UserDefaults) -> Self? {
        guard let data = preferences.data(forKey: preferenceKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to preferences: UserDefaults) throws {
        preferences.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }

    static func forget(in preferences: UserDefaults) {
        preferences.removeObject(forKey: preferenceKey)
    }

    func matches(_ target: NativeChromeConnectionTarget) -> Bool {
        guard let current = try? Self(application: target.application, userDataDirectory: target.userDataDirectory) else {
            return false
        }
        return self == current
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(raw.allKeys.map(\.stringValue)) == expectedKeys else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unexpected remembered Chrome scope fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let bundleID = try values.decode(String.self, forKey: .bundleID)
        let executable = try values.decode(String.self, forKey: .executablePath)
        let directory = try values.decode(String.self, forKey: .userDataDirectoryPath)
        guard version == 1, executable.hasPrefix("/"), directory.hasPrefix("/") else {
            throw ScopeError.invalidScope
        }
        // A temporary positive PID validates only the serialized shape. It is
        // not retained and cannot be used to admit a live connection.
        try self.init(application: .init(processIdentifier: 1, bundleIdentifier: bundleID,
                                         executableURL: URL(fileURLWithPath: executable)),
                      userDataDirectory: URL(fileURLWithPath: directory))
        guard executablePath == executable, userDataDirectoryPath == directory else {
            throw ScopeError.invalidScope
        }
    }

    private static func validatedPath(_ url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/",
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { throw ScopeError.invalidScope }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/" else { throw ScopeError.invalidScope }
        for scalar in path.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { throw ScopeError.invalidScope }
        }
        return path
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, bundleID, executablePath, userDataDirectoryPath
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private enum ScopeError: Error { case invalidScope }
}
