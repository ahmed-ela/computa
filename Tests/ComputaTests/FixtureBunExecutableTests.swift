#if DEBUG
import Foundation
import XCTest
@testable import Computa

final class FixtureBunExecutableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaBunResolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func executable(_ relative: String = ".bun/bin/bun", permissions: Int = 0o700) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("inert executable fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    func testFindsCurrentUsersBunWithoutForwardingPATHOrHome() throws {
        let expected = try executable()
        let environment = ["HOME": "/untrusted", "PATH": "/untrusted/working-directory"]
        XCTAssertEqual(try FixtureBunExecutable.resolve(environment: environment, homeDirectory: root, systemCandidates: []), expected.resolvingSymlinksInPath())
        XCTAssertEqual(AgentRuntimeIsolation.environment(inheriting: environment, userHomePath: "/private/test", codexHomePath: "/private/test/agent")["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testSupportsCanonicalHomebrewSymlinkWithoutPATHSearch() throws {
        let binary = try executable("cellar/bun/1.3.5/bin/bun")
        let link = root.appendingPathComponent("brew/bun")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        XCTAssertEqual(try FixtureBunExecutable.resolve(environment: [:], homeDirectory: root, systemCandidates: [link]), binary.resolvingSymlinksInPath())
    }

    func testExplicitPathIsOptInAndDoesNotFallBackOnInvalidValue() throws {
        let binary = try executable("custom/bun")
        XCTAssertEqual(try FixtureBunExecutable.resolve(environment: ["MACTOPUS_TEST_BUN": binary.path], homeDirectory: root, systemCandidates: []), binary.resolvingSymlinksInPath())
        _ = try executable()
        for invalid in ["bun", "./bun", "/not-installed/bun", "", "/tmp/bun\0"] {
            XCTAssertThrowsError(try FixtureBunExecutable.resolve(environment: ["MACTOPUS_TEST_BUN": invalid], homeDirectory: root, systemCandidates: []))
        }
    }

    func testRefusesMissingNonExecutableAndWritableCandidates() throws {
        XCTAssertThrowsError(try FixtureBunExecutable.resolve(environment: ["PATH": root.path], homeDirectory: root, systemCandidates: []))
        let binary = try executable(permissions: 0o600)
        XCTAssertThrowsError(try FixtureBunExecutable.resolve(environment: [:], homeDirectory: root, systemCandidates: []))
        for permissions in [0o777, 0o775, 0o707] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: binary.path)
            XCTAssertThrowsError(try FixtureBunExecutable.resolve(environment: [:], homeDirectory: root, systemCandidates: []))
        }
    }

    func testNonTypeScriptFixtureStillUsesExplicitExecutable() throws {
        let result = try CodexAppServerRuntime.Configuration.Executable.fixture(path: "/not-executed").resolve()
        XCTAssertEqual(result.url.path, "/not-executed")
        XCTAssertEqual(result.arguments, ["--listen", "stdio://"])
        XCTAssertTrue(result.capabilities.isEmpty)
    }
}
#endif
