import Darwin
import Foundation
import XCTest
@testable import Macrouse

/// Only unique disposable directories under XCTest's temporary location. These
/// tests do not inspect a Chrome profile or open any debugging connection.
final class ChromeDebuggingEndpointFileTests: XCTestCase {
    func testPermissionGuidanceNamesNarrowGrantAndDoesNotBlameDebugging() {
        let message = ChromeDebuggingEndpointError.accessDenied(operation: .openDirectory, code: EPERM).localizedDescription
        XCTAssertTrue(message.contains("Files & Folders"))
        XCTAssertTrue(message.contains("LocalCodex (or Macrouse) > Google Chrome"))
        XCTAssertTrue(message.contains("app-data directory"))
        XCTAssertTrue(message.contains("Full Disk Access is not required"))
        XCTAssertFalse(message.contains("Enable it in Chrome"))
        XCTAssertTrue(message.contains("No browser connection was made"))
    }

    func testPermissionErrorsAreNotMisreportedAsDisabledDebugging() {
        for operation in [ChromeDebuggingEndpointOperation.openDirectory, .openFile, .readFile] {
            for code in [EACCES, EPERM] {
                XCTAssertEqual(ChromeDebuggingEndpointFile.accessError(code, operation: operation),
                               .accessDenied(operation: operation, code: code))
            }
            XCTAssertEqual(ChromeDebuggingEndpointFile.accessError(ENOENT, operation: operation), .unavailable)
            XCTAssertEqual(ChromeDebuggingEndpointFile.accessError(ELOOP, operation: operation), .unavailable)
        }
    }

    func testUnreadableOwnedEndpointReportsAccessDeniedWithoutChangingPermission() throws {
        try XCTSkipIf(geteuid() == 0, "Root can read mode-zero files; this is a user-permission regression.")
        let fixture = try makeFixture()
        try fixture.write()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path) }
        expect(.accessDenied(operation: .openFile, code: EACCES)) { _ = try fixture.read() }
        XCTAssertEqual(try fixture.metadata().st_mode & 0o777, 0)
    }

    func testDefaultConsentRefusesBeforeDirectoryValidationOrMissingFileError() throws {
        let fixture = try makeFixture()
        let consent = ChromeDebuggingConsent()
        let directories = [
            URL(string: "https://example.invalid/not-a-profile")!,
            fixture.root.appendingPathComponent("missing-directory", isDirectory: true),
            fixture.directory,
        ]
        for directory in directories {
            expect(.consentRequired) {
                _ = try ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: directory, consent: consent)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        // Error precedence complements the source's first consent.check(); this
        // assertion alone is not an OS trace proving absence of all file reads.
    }

    func testStrictParserAcceptsCanonicalPortAndBrowserPathWithOptionalTerminalLF() throws {
        for port in ["1", "80", "65535"] {
            for suffix in ["", "\n"] {
                let endpoint = try ChromeDebuggingEndpointFile.parse(Data("\(port)\n/devtools/browser/ABC-xyz_012\(suffix)".utf8))
                XCTAssertEqual(endpoint.absoluteString, "ws://127.0.0.1:\(port)/devtools/browser/ABC-xyz_012")
                try URLSessionBrowserCDPWire.validate(endpoint: endpoint)
            }
        }
    }

    func testStrictParserRejectsInvalidPortsWhitespaceAndRecordShape() {
        let ports = ["", "0", "65536", "-1", "+80", "080", " 80", "80 ", "80\t", "8.0", "1e2", "８０"]
        for port in ports {
            expect(.invalidContents) {
                _ = try ChromeDebuggingEndpointFile.parse(Data("\(port)\n/devtools/browser/token".utf8))
            }
        }
        let records = [
            "", "80", "80\n", "\n80\n/devtools/browser/token",
            "80\r\n/devtools/browser/token\r\n", "80\n/devtools/browser/token\n\n",
            "80\n/devtools/browser/token\nextra", "80\n /devtools/browser/token",
            "80\n/devtools/browser/token ", "80\n/devtools/browser/token\t",
            "80\n/devtools/browser/token\0",
        ]
        for record in records {
            expect(.invalidContents) { _ = try ChromeDebuggingEndpointFile.parse(Data(record.utf8)) }
        }
    }

    func testStrictParserRejectsAlternateEndpointShapesTraversalAndEncoding() {
        let paths = [
            "/devtools/page/token", "/devtools/browser/", "devtools/browser/token",
            "/devtools/browser/../token", "/devtools/browser/a/../../token",
            "/devtools/browser/token?query=1", "/devtools/browser/token#fragment",
            "/devtools/browser/%74oken", "/devtools/browser/token%2Fextra",
            "//other.example/devtools/browser/token", "@other.example/devtools/browser/token",
            "/devtools/browser/token/extra", "/devtools/browser/é",
        ]
        for path in paths {
            expect(.invalidContents) {
                _ = try ChromeDebuggingEndpointFile.parse(Data("80\n\(path)".utf8))
            }
        }
    }

    func testParserRejectsInvalidUTF8AndOversizeInput() {
        for data in [Data(), Data([0xFF, 0xFE]), Data(repeating: 65, count: 1_025)] {
            expect(.invalidContents) { _ = try ChromeDebuggingEndpointFile.parse(data) }
        }
    }

    func testOwnedPrivateRegularFileReadsAndValidatesWithoutChangingBytes() throws {
        let fixture = try makeFixture()
        try fixture.write()
        let before = try fixture.metadata()
        XCTAssertEqual(before.st_uid, geteuid())
        XCTAssertEqual(before.st_mode & 0o777, 0o600)
        XCTAssertEqual(before.st_nlink, 1)
        let value = try fixture.read()
        XCTAssertEqual(value.endpoint.absoluteString, "ws://127.0.0.1:43123/devtools/browser/synthetic-token")
        try value.validate()
        try value.validate()
        XCTAssertEqual(try Data(contentsOf: fixture.file), EndpointFileFixture.contents)
        let after = try fixture.metadata()
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_mode, after.st_mode)
    }

    func testSameBytesFileReplacementInvalidatesStoredGeneration() throws {
        let fixture = try makeFixture()
        try fixture.write()
        let value = try fixture.read()
        let original = try fixture.metadata()
        // Keep the old inode alive, so allocator reuse cannot make the test flaky.
        try FileManager.default.moveItem(at: fixture.file, to: fixture.root.appendingPathComponent("retired-endpoint"))
        try fixture.write()
        let replacement = try fixture.metadata()
        XCTAssertNotEqual(original.st_ino, replacement.st_ino)
        XCTAssertEqual(try Data(contentsOf: fixture.file), EndpointFileFixture.contents)
        expect(.changed) { try value.validate() }
        try fixture.read().validate()
    }

    func testInPlaceContentOrModeChangeInvalidatesStoredGeneration() throws {
        for changeMode in [false, true] {
            let fixture = try makeFixture()
            try fixture.write()
            let value = try fixture.read()
            let original = try fixture.metadata()
            if changeMode {
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.file.path)
            } else {
                let file = try FileHandle(forWritingTo: fixture.file)
                defer { try? file.close() }
                try file.truncate(atOffset: 0)
                try file.write(contentsOf: Data("43124\n/devtools/browser/synthetic-token\n".utf8))
                try file.synchronize()
            }
            XCTAssertEqual(try fixture.metadata().st_ino, original.st_ino)
            expect(.changed) { try value.validate() }
        }
    }

    func testReplacingSelectedDirectoryInvalidatesOldAuthority() throws {
        let fixture = try makeFixture()
        try fixture.write()
        let value = try fixture.read()
        let originalFile = try fixture.metadata()
        let retired = fixture.root.appendingPathComponent("retired-directory", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.directory, to: retired)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: retired.appendingPathComponent("DevToolsActivePort"), to: fixture.file)
        XCTAssertEqual(try fixture.metadata().st_ino, originalFile.st_ino)
        XCTAssertEqual(try Data(contentsOf: fixture.file), EndpointFileFixture.contents)
        expect(.changed) { try value.validate() }
    }

    func testRevokedConsentPrecedesMissingFileOnValidationAndRead() throws {
        let fixture = try makeFixture()
        try fixture.write()
        let consent = ChromeDebuggingConsent(approvedByUser: true)
        let value = try fixture.read(consent: consent)
        consent.revoke()
        try FileManager.default.removeItem(at: fixture.file)
        expect(.consentRequired) { try value.validate() }
        expect(.consentRequired) { _ = try fixture.read(consent: consent) }
    }

    func testSymlinkEndpointAndSymlinkSelectedDirectoryAreRejected() throws {
        let fileFixture = try makeFixture()
        try fileFixture.write()
        let realFile = fileFixture.root.appendingPathComponent("actual-endpoint")
        try FileManager.default.moveItem(at: fileFixture.file, to: realFile)
        try FileManager.default.createSymbolicLink(at: fileFixture.file, withDestinationURL: realFile)
        expect(.unavailable) { _ = try fileFixture.read() }

        let directoryFixture = try makeFixture()
        try directoryFixture.write()
        let realDirectory = directoryFixture.root.appendingPathComponent("actual-directory", isDirectory: true)
        try FileManager.default.moveItem(at: directoryFixture.directory, to: realDirectory)
        try FileManager.default.createSymbolicLink(at: directoryFixture.directory, withDestinationURL: realDirectory)
        expect(.unavailable) { _ = try directoryFixture.read() }
    }

    func testHardLinkedEndpointIsRejected() throws {
        let fixture = try makeFixture()
        try fixture.write()
        try FileManager.default.linkItem(at: fixture.file, to: fixture.root.appendingPathComponent("second-hard-link"))
        XCTAssertEqual(try fixture.metadata().st_nlink, 2)
        expect(.unsafeFile) { _ = try fixture.read() }
    }

    func testFIFOEndpointIsRejectedWithoutWaitingForWriter() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(mkfifo(fixture.file.path, 0o600), 0)
        expect(.unsafeFile) { _ = try fixture.read() }
    }

    func testGroupOrWorldWritableFileAndDirectoryAreRejected() throws {
        for directory in [false, true] {
            for mode in [0o620, 0o602, 0o666] {
                let fixture = try makeFixture()
                try fixture.write()
                let path = directory ? fixture.directory.path : fixture.file.path
                // Directory needs owner traversal; retain it while adding the unsafe write bits.
                let permissions = directory ? mode | 0o100 : mode
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
                expect(.unsafeFile) { _ = try fixture.read() }
            }
        }
    }

    func testMissingEmptyOversizedAndMalformedFilesFailClosed() throws {
        let missing = try makeFixture()
        expect(.unavailable) { _ = try missing.read() }
        for bytes in [Data(), Data(repeating: 65, count: 1_025)] {
            let fixture = try makeFixture()
            try fixture.write(bytes)
            expect(.unsafeFile) { _ = try fixture.read() }
        }
        let malformed = try makeFixture()
        try malformed.write(Data("43123\n/devtools/page/not-browser\n".utf8))
        expect(.invalidContents) { _ = try malformed.read() }
    }

    func testNonlocalOrNonfileDirectoriesAreRejectedAfterConsent() {
        for raw in ["https://example.invalid/profile", "file://remote.example/profile", "file:///tmp/profile?query=1", "file:///tmp/profile#fragment"] {
            expect(.invalidDirectory) {
                _ = try ChromeDebuggingEndpointFile.read(
                    explicitlyApprovedUserDataDirectory: XCTUnwrap(URL(string: raw)),
                    consent: ChromeDebuggingConsent(approvedByUser: true)
                )
            }
        }
    }

    private func makeFixture() throws -> EndpointFileFixture {
        let fixture = try EndpointFileFixture()
        addTeardownBlock { try FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }

    private func expect(
        _ expected: ChromeDebuggingEndpointError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? ChromeDebuggingEndpointError, expected, file: file, line: line)
        }
    }
}

private struct EndpointFileFixture: Sendable {
    static let contents = Data("43123\n/devtools/browser/synthetic-token\n".utf8)
    let root: URL
    let directory: URL
    var file: URL { directory.appendingPathComponent("DevToolsActivePort") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacrouseEndpointFileTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        directory = root.appendingPathComponent("selected-data-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func write(_ bytes: Data = EndpointFileFixture.contents) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func read(consent: ChromeDebuggingConsent = ChromeDebuggingConsent(approvedByUser: true)) throws -> ChromeDebuggingEndpointFile {
        try ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: directory, consent: consent)
    }

    func metadata() throws -> stat {
        var value = stat()
        guard lstat(file.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return value
    }
}
