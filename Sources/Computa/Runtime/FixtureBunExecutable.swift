#if DEBUG
import Foundation

/// Test-only interpreter discovery. Production launches its verified bundled
/// App Server and keeps the system-only PATH. Never search a fixture's working
/// directory or the parent's arbitrary PATH for executable programs.
enum FixtureBunExecutable {
    enum Failure: Error, LocalizedError {
        case unavailable
        case invalidExplicitPath

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Bun is required for TypeScript test fixtures. Install Bun, or set MACTOPUS_TEST_BUN to its absolute executable path."
            case .invalidExplicitPath:
                "MACTOPUS_TEST_BUN must name an absolute, regular, executable Bun binary that is not group/world writable."
            }
        }
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemCandidates: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin/bun"), URL(fileURLWithPath: "/usr/local/bin/bun")]
    ) throws -> URL {
        if let explicit = environment["MACTOPUS_TEST_BUN"] {
            guard explicit.hasPrefix("/"), !explicit.utf8.contains(0),
                  let executable = validated(URL(fileURLWithPath: explicit)) else {
                throw Failure.invalidExplicitPath
            }
            return executable
        }
        let candidates = [homeDirectory.appendingPathComponent(".bun/bin/bun")] + systemCandidates
        for candidate in candidates {
            if let executable = validated(candidate) { return executable }
        }
        throw Failure.unavailable
    }

    private static func validated(_ candidate: URL) -> URL? {
        let executable = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard executable.lastPathComponent == "bun",
              FileManager.default.isExecutableFile(atPath: executable.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0 else { return nil }
        return executable
    }
}
#endif
