import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// A verified app-owned App Server artifact. The manifest detects packaging
/// mistakes and corruption; authenticity comes from the signed app bundle, not
/// from a replaceable manifest alone. This resolver never searches PATH,
/// environment variables, a model directory, or another installed application.
struct HeyDashRuntimeArtifact: Sendable {
    static let sourceCommit = "4607249e430dac1c961df4dc615beae88e33cec8"
    static let executableName = "codex-app-server"
    static let maximumManifestBytes = 16 * 1_024
    static let maximumBinaryBytes = 512 * 1_024 * 1_024

    enum Capability: String, Sendable, Hashable {
        case threadDynamicToolsV1
    }

    struct Manifest: Equatable, Sendable {
        let schemaVersion: Int
        let capabilities: Set<Capability>
        let runtimeVersion: String
        let sourceCommit: String
        let patchSHA256: String
        let binarySHA256: String
        let binarySize: Int
        let platform: String
        let architecture: String
        let executable: String
    }

    let executableURL: URL
    let manifest: Manifest
    let launchArguments = ["--listen", "stdio://"]

    enum ValidationError: LocalizedError, Equatable {
        case resourcesUnavailable
        case unsupportedHost
        case unavailableFile(String)
        case unsafeFile(String)
        case invalidManifest(String)
        case sizeMismatch(expected: Int, actual: Int64)
        case checksumMismatch
        case invalidArchitecture
        case changedDuringValidation

        var errorDescription: String? {
            let prefix = "HeyDash's dedicated Agent Runtime"
            switch self {
            case .resourcesUnavailable:
                return "\(prefix) is missing from the app's Resources/AgentRuntime folder. Rebuild or reinstall HeyDash."
            case .unsupportedHost:
                return "\(prefix) requires an Apple Silicon Mac (macOS arm64)."
            case .unavailableFile(let path):
                return "\(prefix) file is missing or unreadable: \(path). Rebuild or reinstall HeyDash."
            case .unsafeFile(let path):
                return "\(prefix) rejected an unsafe file: \(path). Expected a regular, non-symlink artifact with the required permissions."
            case .invalidManifest(let detail):
                return "\(prefix) manifest is invalid: \(detail). Rebuild or reinstall HeyDash."
            case .sizeMismatch(let expected, let actual):
                return "\(prefix) size does not match its manifest (expected \(expected), found \(actual) bytes)."
            case .checksumMismatch:
                return "\(prefix) SHA-256 does not match its manifest. Refusing to launch the altered runtime."
            case .invalidArchitecture:
                return "\(prefix) is not a thin macOS arm64 Mach-O executable."
            case .changedDuringValidation:
                return "\(prefix) changed while being verified. Refusing to launch it."
            }
        }
    }

    static func resolve() throws -> Self {
        #if SWIFT_PACKAGE
        return try resolve(in: .module)
        #else
        return try resolve(in: .main)
        #endif
    }

    static func resolve(in bundle: Bundle) throws -> Self {
        guard let resources = bundle.resourceURL else { throw ValidationError.resourcesUnavailable }
        return try resolve(resourcesDirectory: resources)
    }

    /// The caller supplies a trusted Resources directory, never a binary path.
    /// Kept internal for deterministic fixtures; production uses resolve().
    static func resolve(resourcesDirectory: URL) throws -> Self {
        #if !os(macOS) || !arch(arm64)
        throw ValidationError.unsupportedHost
        #else
        guard resourcesDirectory.isFileURL else { throw ValidationError.resourcesUnavailable }
        let directory = resourcesDirectory.appendingPathComponent("AgentRuntime", isDirectory: true)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else { throw ValidationError.resourcesUnavailable }
        guard directoryInfo.st_mode & S_IFMT == S_IFDIR else { throw ValidationError.unsafeFile(directory.path) }

        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        let (manifestFD, manifestInfo) = try openRegularFile(manifestURL, executable: false)
        defer { Darwin.close(manifestFD) }
        guard manifestInfo.st_size > 0, manifestInfo.st_size <= maximumManifestBytes else {
            throw ValidationError.invalidManifest("the file must be 1–\(maximumManifestBytes) bytes")
        }
        let manifestData = try readManifest(manifestFD)
        try requireUnchanged(manifestFD, before: manifestInfo)
        let manifest = try decodeManifest(manifestData)

        let executableURL = directory.appendingPathComponent(executableName, isDirectory: false)
        let (binaryFD, binaryInfo) = try openRegularFile(executableURL, executable: true)
        defer { Darwin.close(binaryFD) }
        guard binaryInfo.st_size == manifest.binarySize else {
            throw ValidationError.sizeMismatch(expected: manifest.binarySize, actual: binaryInfo.st_size)
        }
        var hash = SHA256(), header = Data(), total = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = try readBytes(binaryFD, into: &buffer)
            if count == 0 { break }
            total += count
            guard total <= manifest.binarySize else { throw ValidationError.changedDuringValidation }
            let chunk = Data(buffer.prefix(count))
            if header.count < 32 { header.append(chunk.prefix(32 - header.count)) }
            hash.update(data: chunk)
        }
        try requireUnchanged(binaryFD, before: binaryInfo)
        guard total == manifest.binarySize else { throw ValidationError.changedDuringValidation }
        guard isARM64Executable(header, binarySize: total) else { throw ValidationError.invalidArchitecture }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.binarySHA256 else { throw ValidationError.checksumMismatch }
        return Self(executableURL: executableURL, manifest: manifest)
        #endif
    }

    private static func decodeManifest(_ data: Data) throws -> Manifest {
        let baseFields: Set<String> = ["schemaVersion", "runtimeVersion", "sourceCommit", "patchSHA256", "binarySHA256", "binarySize", "platform", "architecture", "executable"]
        guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
            throw ValidationError.invalidManifest("unexpected, missing, or malformed fields")
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw ValidationError.invalidManifest("\(key) must be a string") }
            return value
        }
        func integer(_ key: String, minimum: Int, maximum: Int) throws -> Int {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
                  value.doubleValue >= Double(minimum), value.doubleValue <= Double(maximum) else {
                throw ValidationError.invalidManifest("\(key) is outside the supported integer range")
            }
            return value.intValue
        }
        let version = try integer("schemaVersion", minimum: 1, maximum: 2)
        let required = version == 1 ? baseFields : baseFields.union(["capabilities"])
        guard Set(object.keys) == required else {
            throw ValidationError.invalidManifest("unexpected, missing, or malformed fields")
        }
        let capabilities: Set<Capability>
        if version == 1 {
            capabilities = []
        } else {
            guard let names = object["capabilities"] as? [String] else {
                throw ValidationError.invalidManifest("capabilities must be an array of known capability names")
            }
            var parsed = Set<Capability>()
            for name in names {
                guard let capability = Capability(rawValue: name), parsed.insert(capability).inserted else {
                    throw ValidationError.invalidManifest("capabilities contains an unknown or duplicate name")
                }
            }
            capabilities = parsed
        }
        let runtimeVersion = try string("runtimeVersion")
        guard runtimeVersion.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\\z", options: .regularExpression) != nil else {
            throw ValidationError.invalidManifest("runtimeVersion must be a bounded version token")
        }
        let commit = try string("sourceCommit")
        guard commit == sourceCommit else { throw ValidationError.invalidManifest("the source commit is not the pinned HeyDash runtime source") }
        let patch = try string("patchSHA256"), binary = try string("binarySHA256")
        for (key, digest) in [("patchSHA256", patch), ("binarySHA256", binary)] {
            guard digest.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil,
                  digest != String(repeating: "0", count: 64) else {
                throw ValidationError.invalidManifest("\(key) must be a lowercase SHA-256 digest, not a placeholder")
            }
        }
        let size = try integer("binarySize", minimum: 32, maximum: maximumBinaryBytes)
        let platform = try string("platform"), architecture = try string("architecture"), executable = try string("executable")
        guard platform == "macos", architecture == "arm64", executable == executableName else {
            throw ValidationError.invalidManifest("only macos/arm64/codex-app-server is supported")
        }
        return Manifest(schemaVersion: version, capabilities: capabilities, runtimeVersion: runtimeVersion, sourceCommit: commit,
                        patchSHA256: patch, binarySHA256: binary, binarySize: size,
                        platform: platform, architecture: architecture, executable: executable)
    }

    private static func openRegularFile(_ url: URL, executable: Bool) throws -> (Int32, stat) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ValidationError.unsafeFile(url.path) }
            throw ValidationError.unavailableFile(url.path)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              !executable || (info.st_mode & 0o111 != 0 && access(url.path, X_OK) == 0) else {
            Darwin.close(descriptor)
            throw ValidationError.unsafeFile(url.path)
        }
        return (descriptor, info)
    }

    private static func readBytes(_ descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw ValidationError.changedDuringValidation
        }
    }

    private static func readManifest(_ descriptor: Int32) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: maximumManifestBytes + 1)
        while true {
            let count = try readBytes(descriptor, into: &buffer)
            if count == 0 { return data }
            guard data.count + count <= maximumManifestBytes else { throw ValidationError.invalidManifest("the manifest grew beyond its size limit") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func requireUnchanged(_ descriptor: Int32, before: stat) throws {
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ValidationError.changedDuringValidation
        }
    }

    private static func isARM64Executable(_ header: Data, binarySize: Int) -> Bool {
        guard header.count == 32 else { return false }
        func littleEndian32(at offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << UInt32(8 * $1) }
        }
        return littleEndian32(at: 0) == 0xfeedfacf // MH_MAGIC_64, little-endian
            && littleEndian32(at: 4) == 0x0100000c // CPU_TYPE_ARM64
            && littleEndian32(at: 12) == 2 // MH_EXECUTE, not a library or object
            && UInt64(littleEndian32(at: 20)) + 32 <= UInt64(binarySize)
    }
}
