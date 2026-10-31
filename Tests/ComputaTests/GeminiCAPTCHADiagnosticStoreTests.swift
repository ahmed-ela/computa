import Darwin
import Foundation
import XCTest
@testable import Computa

final class GeminiCAPTCHADiagnosticStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("incidents", isDirectory: true) }

    override func setUpWithError() throws {
        // Foundation can canonicalize /private/var back to the /var symlink.
        // The store intentionally rejects symlink ancestors, so use the actual
        // physical fixture directory instead of weakening its production checks.
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("ComputaGeminiIncidentStore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testPrivateDurableRoundTripAndImmutableDuplicate() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory), report = fixture()
        let file = try store.save(report), bytes = try Data(contentsOf: file)
        XCTAssertEqual(file.lastPathComponent, report.id.uuidString.lowercased() + ".json")
        XCTAssertEqual(bytes, try report.encodedData())
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(try GeminiCAPTCHADiagnosticStore(directory: directory).save(report), file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try names(), [file.lastPathComponent])
    }

    func testConflictingIncidentCannotReplaceFirstEvidence() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory), id = UUID()
        let first = fixture(id: id), file = try store.save(first), bytes = try Data(contentsOf: file)
        let changed = fixture(id: id, time: 2_000)
        XCTAssertNotEqual(try first.encodedData(), try changed.encodedData())
        XCTAssertThrowsError(try store.save(changed)) { XCTAssertEqual($0 as? GeminiCAPTCHADiagnosticStore.Failure, .conflict) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testRollingRetentionKeepsNewestSixteenAndCurrentReport() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory)
        var expected: [String] = []
        for index in 0..<18 {
            let report = fixture(time: Double(1_000 + index)), file = try store.save(report)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))], ofItemAtPath: file.path)
            expected.append(file.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: file), try report.encodedData())
        }
        XCTAssertEqual(Set(try names()), Set(expected.suffix(16)))
        XCTAssertLessThanOrEqual(try totalBytes(), GeminiCAPTCHADiagnosticStore.maximumDirectoryBytes)
    }

    func testFailureBeforePublicationPreservesOldEvidenceAndRemovesOnlyOwnStage() throws {
        let initial = try GeminiCAPTCHADiagnosticStore(directory: directory), first = fixture()
        let file = try initial.save(first), bytes = try Data(contentsOf: file)
        for stage in [GeminiCAPTCHADiagnosticStore.FaultPoint.beforeWrite, .beforePublish] {
            var failing = try GeminiCAPTCHADiagnosticStore(directory: directory)
            failing.faultForTesting = { point in
                if point == stage { throw CocoaError(.fileWriteOutOfSpace) }
            }
            XCTAssertThrowsError(try failing.save(fixture()))
            XCTAssertEqual(try names(), [file.lastPathComponent])
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testInterruptedPostPublicationRetentionRecoversWithoutRewritingIncident() throws {
        var store = try GeminiCAPTCHADiagnosticStore(directory: directory)
        for index in 0..<16 {
            let file = try store.save(fixture(time: Double(index + 1)))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: file.path)
        }
        let report = fixture(time: 2_000)
        store.faultForTesting = { point in if point == .afterPublish { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try store.save(report))
        XCTAssertEqual(try names().count, 17)
        let expected = directory.appendingPathComponent(report.id.uuidString.lowercased() + ".json")
        let original = try Data(contentsOf: expected)
        let recovered = try GeminiCAPTCHADiagnosticStore(directory: directory).save(report)
        XCTAssertEqual(recovered, expected)
        XCTAssertEqual(try Data(contentsOf: recovered), original)
        XCTAssertEqual(try names().count, 16)
    }

    func testPartialCrashStagesArePreservedAndBoundedRatherThanDeleted() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory)
        var orphans: [URL] = []
        for index in 0..<2 {
            let orphan = directory.appendingPathComponent(".gemini-captcha-" + UUID().uuidString.lowercased() + ".tmp")
            try privateWrite(Data(repeating: 123, count: index), to: orphan)
            orphans.append(orphan)
        }
        let saved = try store.save(fixture())
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        for (index, orphan) in orphans.enumerated() { XCTAssertEqual(try Data(contentsOf: orphan), Data(repeating: 123, count: index)) }
        let third = directory.appendingPathComponent(".gemini-captcha-" + UUID().uuidString.lowercased() + ".tmp")
        try privateWrite(Data(), to: third)
        let before = try names()
        XCTAssertThrowsError(try store.save(fixture())) { XCTAssertEqual($0 as? GeminiCAPTCHADiagnosticStore.Failure, .capacity) }
        XCTAssertEqual(try names(), before)
    }

    func testUnknownFileOrUnrelatedUUIDJSONIsNeverPruned() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory)
        let first = try store.save(fixture()), original = try Data(contentsOf: first)
        for name in ["keep-me.txt", UUID().uuidString.lowercased() + ".json"] {
            let unknown = directory.appendingPathComponent(name), bytes = Data(#"{"kind":"unrelated","private":"DO_NOT_DELETE"}"#.utf8)
            try privateWrite(bytes, to: unknown)
            XCTAssertThrowsError(try store.save(fixture()))
            XCTAssertEqual(try Data(contentsOf: unknown), bytes)
            XCTAssertEqual(try Data(contentsOf: first), original)
            try FileManager.default.removeItem(at: unknown)
        }
    }

    func testSymlinkHardlinkAndFIFORecordsCannotBeReadOrOverwritten() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory), report = fixture()
        let target = root.appendingPathComponent("unrelated"), bytes = Data("PRIVATE_UNRELATED".utf8)
        try privateWrite(bytes, to: target)
        let file = directory.appendingPathComponent(report.id.uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(report))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try store.save(report))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try store.save(report))
    }

    func testNonPrivateExistingDirectoryAndSymlinkAncestorsAreNotRepaired() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try GeminiCAPTCHADiagnosticStore(directory: directory))
        XCTAssertEqual(try mode(directory), 0o755)
        try FileManager.default.removeItem(at: directory)
        let actual = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: actual)
        XCTAssertThrowsError(try GeminiCAPTCHADiagnosticStore(directory: directory))
        XCTAssertThrowsError(try GeminiCAPTCHADiagnosticStore(directory: directory.appendingPathComponent("nested")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }

    func testNonPrivateReportIsNotChmoddedOrReplaced() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory), report = fixture()
        let file = try store.save(report), bytes = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.save(report))
        XCTAssertEqual(try mode(file), 0o644)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testDirectoryWriterContentionFailsWithoutBlockingOrWriting() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.save(fixture())) { XCTAssertEqual($0 as? GeminiCAPTCHADiagnosticStore.Failure, .busy) }
        XCTAssertTrue(try names().isEmpty)
    }

    func testOneMiBExistingBytesCannotEvictEvidenceToMakeStagingSpace() throws {
        let store = try GeminiCAPTCHADiagnosticStore(directory: directory)
        for index in 0..<16 {
            let report = fixture(time: Double(index + 1))
            var bytes = try report.encodedData()
            XCTAssertLessThan(bytes.count, GeminiCAPTCHADiagnosticStore.maximumReportBytes)
            // Legal whitespace exercises the storage byte cap independently of
            // the typed report's normally much smaller metadata projection.
            bytes.append(Data(repeating: 32, count: GeminiCAPTCHADiagnosticStore.maximumReportBytes - bytes.count))
            try privateWrite(bytes, to: directory.appendingPathComponent(report.id.uuidString.lowercased() + ".json"))
        }
        XCTAssertEqual(try totalBytes(), GeminiCAPTCHADiagnosticStore.maximumDirectoryBytes)
        let before = try names()
        XCTAssertThrowsError(try store.save(fixture())) { XCTAssertEqual($0 as? GeminiCAPTCHADiagnosticStore.Failure, .capacity) }
        XCTAssertEqual(try names(), before)
        XCTAssertEqual(try totalBytes(), GeminiCAPTCHADiagnosticStore.maximumDirectoryBytes)
    }

    private func fixture(id: UUID = UUID(), time: Double = 1_000) -> GeminiCAPTCHADiagnostic.Report {
        GeminiCAPTCHADiagnostic.Journal().report(tabID: UUID(), generation: UUID(), role: .model, trigger: .transport,
                                               now: Date(timeIntervalSince1970: time), cookieEvents: [], id: id)
    }

    private func privateWrite(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func mode(_ file: URL) throws -> Int {
        try XCTUnwrap((FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
    private func totalBytes() throws -> Int {
        try names().reduce(0) { try $0 + Data(contentsOf: directory.appendingPathComponent($1)).count }
    }
}
