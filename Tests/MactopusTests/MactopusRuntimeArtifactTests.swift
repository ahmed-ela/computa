import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mactopus

/// Synthetic Mach-O-shaped bytes only. Nothing in these tests is executed.
final class MactopusRuntimeArtifactTests: XCTestCase {
    func testProductionConfigurationRequiresDedicatedBundledArtifactOrFailsClosed() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        guard case .bundled = configuration.executable else {
            return XCTFail("Production configuration must not select a fixture or installed-app executable.")
        }
        do {
            let resolved = try configuration.executable.resolve()
            XCTAssertEqual(resolved.url.lastPathComponent, "codex-app-server")
            XCTAssertEqual(resolved.url.deletingLastPathComponent().lastPathComponent, "AgentRuntime")
            XCTAssertFalse(resolved.url.path.contains("ChatGPT.app"))
            XCTAssertEqual(resolved.arguments, ["--listen", "stdio://"])
        } catch {
            // A source-only test checkout may intentionally have no packaged
            // binary yet. That must be an artifact error, never a fallback.
            XCTAssertTrue(error is MactopusRuntimeArtifact.ValidationError, error.localizedDescription)
        }
    }

    func testValidPinnedArtifactReturnsOnlyDedicatedExecutableAndStandaloneArguments() throws {
        try withFixture { fixture in
            let artifact = try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)
            XCTAssertEqual(artifact.executableURL, fixture.binary)
            XCTAssertEqual(artifact.launchArguments, ["--listen", "stdio://"])
            XCTAssertEqual(artifact.manifest.sourceCommit, MactopusRuntimeArtifact.sourceCommit)
            XCTAssertEqual(artifact.manifest.binarySHA256, digest(fixture.bytes))
            XCTAssertEqual(artifact.manifest.binarySize, fixture.bytes.count)
            XCTAssertEqual(artifact.manifest.schemaVersion, 1)
            XCTAssertEqual(artifact.manifest.capabilities, [])
            XCTAssertEqual(artifact.manifest.runtimeVersion, "heydash-1")
            XCTAssertFalse(artifact.executableURL.path.contains("ChatGPT.app"))
        }
    }

    func testLegacyManifestNeverInfersCapabilitiesFromRuntimeVersion() throws {
        try withFixture { fixture in
            var manifest = fixture.manifest
            manifest["runtimeVersion"] = "heydash-999-threadDynamicToolsV1"
            try fixture.writeManifest(manifest)
            let artifact = try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)
            XCTAssertEqual(artifact.manifest.capabilities, [])
        }
    }

    func testVersionTwoManifestAcceptsExplicitKnownCapabilities() throws {
        for names in [[], ["threadDynamicToolsV1"]] {
            try withFixture { fixture in
                var manifest = fixture.manifest
                manifest["schemaVersion"] = 2
                manifest["capabilities"] = names
                try fixture.writeManifest(manifest)
                let artifact = try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)
                let expected: Set<MactopusRuntimeArtifact.Capability> = names.isEmpty ? [] : [.threadDynamicToolsV1]
                XCTAssertEqual(artifact.manifest.schemaVersion, 2)
                XCTAssertEqual(artifact.manifest.capabilities, expected)
                XCTAssertEqual(artifact.manifest.binarySHA256, digest(fixture.bytes))
                XCTAssertEqual(artifact.executableURL, fixture.binary)
            }
        }
    }

    func testLegacyManifestRejectsAnyCapabilitiesField() throws {
        let values: [Any] = [[String](), ["threadDynamicToolsV1"], NSNull()]
        for value in values {
            try withFixture { fixture in
                var manifest = fixture.manifest
                manifest["capabilities"] = value
                try fixture.writeManifest(manifest)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
    }

    func testVersionTwoManifestRejectsMissingMalformedUnknownOrDuplicateCapabilities() throws {
        let changes: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "capabilities") },
            { $0["capabilities"] = NSNull() },
            { $0["capabilities"] = "threadDynamicToolsV1" },
            { $0["capabilities"] = ["threadDynamicToolsV1": true] },
            { $0["capabilities"] = [true] },
            { $0["capabilities"] = [1] },
            { $0["capabilities"] = [NSNull()] },
            { $0["capabilities"] = ["threadDynamicToolsV1", 1] as [Any] },
            { $0["capabilities"] = [""] },
            { $0["capabilities"] = ["threadDynamicToolsV2"] },
            { $0["capabilities"] = ["ThreadDynamicToolsV1"] },
            { $0["capabilities"] = ["threadDynamicToolsV1 "] },
            { $0["capabilities"] = ["threadDynamicToolsV1", "threadDynamicToolsV2"] },
            { $0["capabilities"] = ["threadDynamicToolsV1", "threadDynamicToolsV1"] },
            { $0["unrecognized"] = true },
            { $0.removeValue(forKey: "binarySHA256") },
        ]
        for change in changes {
            try withFixture { fixture in
                var manifest = fixture.manifest
                manifest["schemaVersion"] = 2
                manifest["capabilities"] = ["threadDynamicToolsV1"]
                change(&manifest)
                try fixture.writeManifest(manifest)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
    }

    func testUnknownManifestVersionsCannotDeclareCapabilities() throws {
        for version in [-1, 0, 3, Int.max] {
            try withFixture { fixture in
                var manifest = fixture.manifest
                manifest["schemaVersion"] = version
                manifest["capabilities"] = ["threadDynamicToolsV1"]
                try fixture.writeManifest(manifest)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
    }

    func testVersionTwoCapabilitiesDoNotBypassBinaryChecksumVerification() throws {
        try withFixture { fixture in
            var manifest = fixture.manifest
            manifest["schemaVersion"] = 2
            manifest["capabilities"] = ["threadDynamicToolsV1"]
            try fixture.writeManifest(manifest)
            var altered = fixture.bytes
            altered[altered.count - 1] ^= 0x01
            try altered.write(to: fixture.binary)
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .checksumMismatch)
            }
        }
    }

    func testStreamingDigestCoversBytesPastFirstChunk() throws {
        try withFixture { fixture in
            var large = fixture.bytes
            large.append(Data(repeating: 0xA7, count: 1_024 * 1_024 + 73))
            try fixture.replaceBinary(large)
            let artifact = try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)
            XCTAssertEqual(artifact.manifest.binarySHA256, digest(large))
            large[large.count - 1] ^= 0x01
            try large.write(to: fixture.binary)
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .checksumMismatch)
            }
        }
    }

    func testMissingDedicatedDirectoryFailsWithoutInstalledAppFallback() throws {
        try withFixture { fixture in
            let absentResources = fixture.root.appendingPathComponent("MissingResources", isDirectory: true)
            try FileManager.default.createDirectory(at: absentResources, withIntermediateDirectories: true)
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: absentResources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .resourcesUnavailable)
            }
        }
    }

    func testNonFileResourcesURLIsRejected() {
        XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: URL(string: "https://example.invalid/Resources")!))
    }

    func testMissingManifestOrExecutableFailsClosed() throws {
        for missingManifest in [true, false] {
            try withFixture { fixture in
                let missing = missingManifest ? fixture.manifestURL : fixture.binary
                try FileManager.default.removeItem(at: missing)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                    XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .unavailableFile(missing.path))
                }
            }
        }
    }

    func testUnknownMissingOrWrongTypedManifestFieldsAreRejected() throws {
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["binaryPath"] = "/Applications/ChatGPT.app/Contents/Resources/codex" },
            { $0.removeValue(forKey: "patchSHA256") },
            { $0["runtimeVersion"] = 1 },
            { $0["binarySize"] = "128" },
            { $0["schemaVersion"] = true },
            { $0["binarySize"] = true },
            { $0["binarySize"] = 128.5 },
            { $0["patchSHA256"] = NSNull() },
        ]
        for change in changes {
            try withFixture { fixture in
                var manifest = fixture.manifest
                change(&manifest)
                try fixture.writeManifest(manifest)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
    }

    func testUnpinnedSourceVersionOrPlatformCannotBeSelectedByManifest() throws {
        let invalid: [(String, Any)] = [
            ("sourceCommit", String(repeating: "a", count: 40)), ("schemaVersion", 3),
            ("platform", "linux"), ("architecture", "x86_64"), ("architecture", "universal"),
            ("executable", "codex"), ("executable", "../codex-app-server"),
            ("executable", "/Applications/ChatGPT.app/Contents/Resources/codex"),
            ("executable", "worker.js"), ("runtimeVersion", ""), ("runtimeVersion", "../runtime"),
            ("runtimeVersion", String(repeating: "v", count: 65)), ("runtimeVersion", "heydash-1\n"),
        ]
        for (key, value) in invalid {
            try withFixture { fixture in
                var manifest = fixture.manifest
                manifest[key] = value
                try fixture.writeManifest(manifest)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
    }

    func testMalformedOrPlaceholderHashesAreRejected() throws {
        for key in ["patchSHA256", "binarySHA256"] {
            for value in ["", "abcd", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "0", count: 64), String(repeating: "a", count: 64) + "\n"] {
                try withFixture { fixture in
                    var manifest = fixture.manifest
                    manifest[key] = value
                    try fixture.writeManifest(manifest)
                    XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
                }
            }
        }
    }

    func testMalformedAndOversizedManifestDataAreRejected() throws {
        for invalid in [Data(), Data("[]".utf8), Data("{broken".utf8), Data([0xff, 0xfe, 0xff]),
                        Data(repeating: 0x20, count: MactopusRuntimeArtifact.maximumManifestBytes + 1)] {
            try withFixture { fixture in
                try invalid.write(to: fixture.manifestURL)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
    }

    func testBinaryBoundsAndExactLengthAreRequired() throws {
        for size in [-1, 0, 31, MactopusRuntimeArtifact.maximumBinaryBytes + 1] {
            try withFixture { fixture in
                var manifest = fixture.manifest
                manifest["binarySize"] = size
                try fixture.writeManifest(manifest)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources))
            }
        }
        try withFixture { fixture in
            var manifest = fixture.manifest
            manifest["binarySize"] = fixture.bytes.count + 1
            try fixture.writeManifest(manifest)
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError,
                               .sizeMismatch(expected: fixture.bytes.count + 1, actual: Int64(fixture.bytes.count)))
            }
        }
    }

    func testNonExecutableRegularFileIsRejected() throws {
        try withFixture { fixture in
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.binary.path)
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .unsafeFile(fixture.binary.path))
            }
        }
    }

    func testSymlinkExecutableAndManifestAreRejectedEvenWhenTargetMatches() throws {
        for linkManifest in [false, true] {
            try withFixture { fixture in
                let path = linkManifest ? fixture.manifestURL : fixture.binary
                let target = fixture.root.appendingPathComponent("symlink-target")
                try FileManager.default.moveItem(at: path, to: target)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                    XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .unsafeFile(path.path))
                }
            }
        }
    }

    func testSymlinkAgentRuntimeDirectoryIsRejected() throws {
        try withFixture { fixture in
            let target = fixture.root.appendingPathComponent("other-runtime", isDirectory: true)
            try FileManager.default.moveItem(at: fixture.directory, to: target)
            try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: target)
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .unsafeFile(fixture.directory.path))
            }
        }
    }

    func testDirectoryAndFIFOAreRejectedWithoutBlockingReads() throws {
        for fifo in [false, true] {
            try withFixture { fixture in
                try FileManager.default.removeItem(at: fixture.binary)
                if fifo { XCTAssertEqual(mkfifo(fixture.binary.path, 0o700), 0) }
                else { try FileManager.default.createDirectory(at: fixture.binary, withIntermediateDirectories: false) }
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                    XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .unsafeFile(fixture.binary.path))
                }
            }
        }
    }

    func testDifferentArchitectureScriptLibraryAndImpossibleHeaderAreRejected() throws {
        for field in [0, 4, 12, 20] {
            try withFixture { fixture in
                var bytes = fixture.bytes
                let replacement: UInt32 = field == 0 ? 0xcafebabe : field == 4 ? 0x01000007 : field == 12 ? 6 : UInt32.max
                for index in 0..<4 { bytes[field + index] = UInt8(truncatingIfNeeded: replacement >> (8 * index)) }
                try fixture.replaceBinary(bytes)
                XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                    XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .invalidArchitecture)
                }
            }
        }
        try withFixture { fixture in
            try fixture.replaceBinary(Data(("#!/bin/sh\n" + String(repeating: "# synthetic only\n", count: 16)).utf8))
            XCTAssertThrowsError(try MactopusRuntimeArtifact.resolve(resourcesDirectory: fixture.resources)) {
                XCTAssertEqual($0 as? MactopusRuntimeArtifact.ValidationError, .invalidArchitecture)
            }
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try body(fixture)
    }

    private struct Fixture {
        let root: URL
        let resources: URL
        let directory: URL
        let binary: URL
        let manifestURL: URL
        let bytes: Data
        let manifest: [String: Any]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusArtifactTests-\(UUID().uuidString)", isDirectory: true)
            resources = root.appendingPathComponent("Resources", isDirectory: true)
            directory = resources.appendingPathComponent("AgentRuntime", isDirectory: true)
            binary = directory.appendingPathComponent("codex-app-server")
            manifestURL = directory.appendingPathComponent("manifest.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var header = Data(repeating: 0, count: 32)
            let fields: [(Int, UInt32)] = [(0, 0xfeedfacf), (4, 0x0100000c), (12, 2)]
            for (offset, value) in fields {
                for byte in 0..<4 { header[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
            }
            header.append(Data(repeating: 0x5A, count: 96))
            bytes = header
            manifest = ["schemaVersion": 1, "runtimeVersion": "heydash-1", "sourceCommit": MactopusRuntimeArtifact.sourceCommit,
                        "patchSHA256": String(repeating: "a", count: 64),
                        "binarySHA256": SHA256.hash(data: header).map { String(format: "%02x", $0) }.joined(),
                        "binarySize": header.count, "platform": "macos", "architecture": "arm64", "executable": "codex-app-server"]
            try bytes.write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            try writeManifest(manifest)
        }

        func writeManifest(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: manifestURL)
        }

        func replaceBinary(_ data: Data) throws {
            try data.write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            var updated = manifest
            updated["binarySize"] = data.count
            updated["binarySHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try writeManifest(updated)
        }
    }
}
