import Darwin
import Foundation
import XCTest
@testable import Computa

final class WebModelRejectedReplyCaptureTests: XCTestCase {
    func testMalformedReplyCapturesExactInputOnceWithoutDispatchOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), reply = "Rejected prose with JSON-looking text { and escaped \\\n🙂"
        try fixture.arm(task)
        let transport = RejectedReplyTransport(reply: reply)
        let server = WebModelServer(rejectedReplyDirectory: fixture.directory)
        await server.registerEvidenceThread(taskID: task.uuidString, threadID: thread.uuidString)
        await server.configureEmbeddedTransport(transport)
        await assertMalformed(server, task: task)
        let value = try fixture.record()
        XCTAssertEqual(value["replyText"] as? String, reply)
        XCTAssertEqual(value["taskID"] as? String, task.uuidString.lowercased())
        XCTAssertEqual(value["threadID"] as? String, thread.uuidString.lowercased())
        XCTAssertEqual(value["provider"] as? String, "claude")
        XCTAssertEqual(value["modelID"] as? String, "browser/claude")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(value["inferenceID"] as? String)))
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(value["sessionToken"] as? String)))
        XCTAssertEqual(value["automaticReplay"] as? Bool, false)
        let diagnostic = try XCTUnwrap(value["diagnostic"] as? [String: Any])
        XCTAssertEqual(diagnostic["reason"] as? String, "invalid_json")
        XCTAssertEqual(diagnostic["utf8Bytes"] as? Int, reply.utf8.count)
        let structure = try XCTUnwrap(value["codeStructure"] as? [String: Any])
        XCTAssertEqual(Set(structure.keys), ["preCount", "codeCount", "outsideTruncated", "literalCodeValidJSON",
                                               "literalCodeKnownEnvelopeType", "selectedExtraction", "extractionReason"])
        XCTAssertEqual(structure["selectedExtraction"] as? String, "rendered_fallback")
        let bytes = try Data(contentsOf: fixture.output)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("request-only-secret"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("metadata-content-secret"))
        XCTAssertEqual(try fixture.permissions(fixture.directory), 0o700)
        XCTAssertEqual(try fixture.permissions(fixture.output), 0o600)
        XCTAssertFalse(fixture.exists(fixture.armFile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["rejected-reply.json"])
        let firstOperations = await transport.operations()
        XCTAssertEqual(firstOperations.filter { $0 == "webProviderSend" }.count, 1)
        try FileManager.default.removeItem(at: fixture.output)
        await assertMalformed(server, task: task)
        XCTAssertFalse(fixture.exists(fixture.output), "An already-consumed arm cannot capture a later explicit inference")
        let secondOperations = await transport.operations()
        XCTAssertEqual(secondOperations.filter { $0 == "webProviderSend" }.count, 2)
        _ = await server.shutdown()
    }

    func testCaptureRemainsDisabledWithoutConfigurationAndForSuccessfulReplies() async throws {
        for configured in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(); try fixture.arm(task)
            let transport = RejectedReplyTransport(reply: configured ? #"{"type":"message","text":"OK"}"# : "invalid")
            let server = WebModelServer(rejectedReplyDirectory: configured ? fixture.directory : nil)
            await server.configureEmbeddedTransport(transport)
            if configured { _ = try await server.infer(request, taskID: task.uuidString) }
            else { await assertMalformed(server, task: task) }
            XCTAssertTrue(fixture.exists(fixture.armFile))
            XCTAssertFalse(fixture.exists(fixture.output))
            _ = await server.shutdown()
        }
    }

    func testArmIsExactTaskScopedAndRejectsMalformedOrExtendedInstructions() throws {
        let task = UUID()
        for arm in [Data("not JSON".utf8), try encoded(["taskID": "not-a-uuid"]),
                    try encoded(["taskID": UUID().uuidString]), try encoded(["taskID": task.uuidString, "captureAll": true]),
                    try encoded(["taskID": [task.uuidString]]), Data(repeating: 0x20, count: 513),
                    Data("{\"taskID\":\"\(UUID().uuidString)\",\"taskID\":\"\(task.uuidString)\"}".utf8)] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.writeArm(arm)
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
            XCTAssertTrue(fixture.exists(fixture.armFile))
            XCTAssertFalse(fixture.exists(fixture.output))
        }
    }

    func testUTF8LimitPreservesExactBoundaryAndRejectsOverflowBeforeConsumingArm() throws {
        let task = UUID()
        for size in [220_000, 220_001] {
            let fixture = try Fixture(); defer { fixture.remove() }; try fixture.arm(task)
            let reply = String(repeating: "🙂", count: 55_000) + (size == 220_001 ? "x" : "")
            XCTAssertEqual(reply.utf8.count, size)
            let result = WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task, reply: reply))
            XCTAssertEqual(result, size == 220_000)
            if result { XCTAssertEqual(try fixture.record()["replyText"] as? String, reply) }
            else { XCTAssertTrue(fixture.exists(fixture.armFile)); XCTAssertFalse(fixture.exists(fixture.output)) }
        }
    }

    func testUnsafeDirectoryAndArmPermissionsAreRejectedWithoutRepair() throws {
        let task = UUID()
        for (directoryMode, armMode) in [(0o755, 0o600), (0o700, 0o644), (0o700, 0o640), (0o700, 0o400)] {
            let fixture = try Fixture(); defer { fixture.remove() }; try fixture.arm(task)
            try FileManager.default.setAttributes([.posixPermissions: directoryMode], ofItemAtPath: fixture.directory.path)
            try FileManager.default.setAttributes([.posixPermissions: armMode], ofItemAtPath: fixture.armFile.path)
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
            XCTAssertEqual(try fixture.permissions(fixture.directory), directoryMode)
            XCTAssertEqual(try fixture.permissions(fixture.armFile), armMode)
            XCTAssertFalse(fixture.exists(fixture.output))
        }
    }

    func testMaximumEscapedReplyAndConcurrentCapturesPublishOneCompleteRecord() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(); try fixture.arm(task)
        let reply = String(repeating: "\u{0}", count: WebModelRejectedReplyCapture.maximumReplyBytes)
        let bytes = try record(task, reply: reply)
        XCTAssertGreaterThan(bytes.count, WebModelRejectedReplyCapture.maximumReplyBytes)
        let results = LockedCaptureResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.add(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: bytes))
        }
        XCTAssertEqual(results.successCount(), 1)
        XCTAssertEqual(try fixture.record()["replyText"] as? String, reply)
        XCTAssertEqual(try Data(contentsOf: fixture.output), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["rejected-reply.json"])
        XCTAssertFalse(fixture.exists(fixture.armFile))
    }

    func testSymlinkedDirectoryAncestorArmAndOutputAreRejected() throws {
        let task = UUID()
        for kind in ["directory", "ancestor", "arm", "output"] {
            let fixture = try Fixture(); defer { fixture.remove() }; try fixture.arm(task)
            var captureDirectory = fixture.directory
            let link = fixture.root.appendingPathComponent("linked")
            if kind == "directory" {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
                captureDirectory = link
            } else if kind == "ancestor" {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
                captureDirectory = link.appendingPathComponent("diagnostics")
            } else {
                let target = fixture.root.appendingPathComponent("external.json")
                try fixture.writeArm(try encoded(["taskID": task.uuidString]), to: target)
                let path = kind == "arm" ? fixture.armFile : fixture.output
                if kind == "arm" { try FileManager.default.removeItem(at: path) }
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            }
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: captureDirectory, taskID: task, record: try record(task)))
            XCTAssertTrue(fixture.exists(fixture.armFile))
            if kind == "arm" || kind == "output" {
                XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("external.json")), try encoded(["taskID": task.uuidString]))
            }
        }
    }

    func testHardLinkedArmAndNonRegularArmDoNotAuthorizeCaptureOrBlock() throws {
        let task = UUID()
        for kind in ["hardlink", "fifo", "directory"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            if kind == "hardlink" {
                try fixture.arm(task)
                XCTAssertEqual(link(fixture.armFile.path, fixture.root.appendingPathComponent("arm-alias").path), 0)
            } else if kind == "fifo" { XCTAssertEqual(mkfifo(fixture.armFile.path, 0o600), 0) }
            else { try FileManager.default.createDirectory(at: fixture.armFile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let start = ContinuousClock.now
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
            XCTAssertFalse(fixture.exists(fixture.output))
        }
    }

    func testExistingRecordAndAbsentDirectoryAreNeverReplacedOrCreated() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(); try fixture.arm(task)
        let prior = Data("previous private evidence".utf8)
        try fixture.writeArm(prior, to: fixture.output)
        XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
        XCTAssertEqual(try Data(contentsOf: fixture.output), prior)
        XCTAssertTrue(fixture.exists(fixture.armFile))
        let missing = fixture.root.appendingPathComponent("not-provisioned")
        XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: missing, taskID: task, record: try record(task)))
        XCTAssertFalse(fixture.exists(missing))
    }

    func testUnsafeCapturePreservesOriginalMalformedErrorAndOneSend() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(); try fixture.arm(task)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        let transport = RejectedReplyTransport(reply: "original invalid reply")
        let server = WebModelServer(rejectedReplyDirectory: fixture.directory)
        await server.configureEmbeddedTransport(transport)
        await assertMalformed(server, task: task)
        XCTAssertFalse(fixture.exists(fixture.output))
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { $0 == "webProviderSend" }.count, 1)
        _ = await server.shutdown()
    }

    func testArmReplacementDuringClaimIsPreservedAndCannotAuthorizeCapture() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), replacement = UUID(); try fixture.arm(task)
        let captured = WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task), beforeArmClaimForTesting: {
            do { try FileManager.default.removeItem(at: fixture.armFile); try fixture.arm(replacement) }
            catch { XCTFail("Could not establish deterministic arm replacement: \(error)") }
        })
        XCTAssertFalse(captured)
        XCTAssertFalse(fixture.exists(fixture.output))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.armFile)) as? [String: String])
        XCTAssertEqual(restored, ["taskID": replacement.uuidString.lowercased()])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["arm.json"])
    }

    func testSameInodeArmRewriteWithRestoredMtimeIsPreservedAndRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), replacement = UUID(); try fixture.arm(task)
        let replacementBytes = try encoded(["taskID": replacement.uuidString.lowercased()])
        let captured = WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task), beforeArmClaimForTesting: {
            let descriptor = open(fixture.armFile.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { XCTFail("Could not open deterministic same-inode rewrite"); return }
            defer { close(descriptor) }
            var original = stat()
            guard fstat(descriptor, &original) == 0 else { XCTFail("Could not inspect arm before rewriting"); return }
            XCTAssertEqual(ftruncate(descriptor, 0), 0)
            let count = replacementBytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            XCTAssertEqual(count, replacementBytes.count)
            let times = [original.st_atimespec, original.st_mtimespec]
            XCTAssertEqual(times.withUnsafeBufferPointer { futimens(descriptor, $0.baseAddress) }, 0)
        })
        XCTAssertFalse(captured)
        XCTAssertFalse(fixture.exists(fixture.output))
        XCTAssertEqual(try Data(contentsOf: fixture.armFile), replacementBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["arm.json"])
    }

    private var request: Data {
        Data(#"{"model":"browser/claude","input":"request-only-secret","tools":[],"stream":false}"#.utf8)
    }

    private func assertMalformed(_ server: WebModelServer, task: UUID) async {
        do { _ = try await server.infer(request, taskID: task.uuidString); XCTFail("A malformed reply must remain rejected") }
        catch {
            guard case let .malformedReply(diagnostic) = error as? WebModelServer.Failure else { XCTFail("Original malformed failure must survive capture: \(error)"); return }
            XCTAssertEqual(diagnostic.reason, .invalidJSON)
        }
    }

    private func encoded(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func record(_ task: UUID, reply: String = "invalid rejected text") throws -> Data {
        try encoded(["taskID": task.uuidString.lowercased(), "replyText": reply])
    }

    private struct Fixture {
        let root: URL
        var directory: URL { root.appendingPathComponent("diagnostics") }
        var armFile: URL { directory.appendingPathComponent("arm.json") }
        var output: URL { directory.appendingPathComponent("rejected-reply.json") }
        init() throws {
            // Foundation canonicalizes /private/var back to its /var alias on
            // macOS. Use the actual POSIX path to test the no-symlink contract.
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent("ComputaRejectedReply-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func arm(_ task: UUID) throws { try writeArm(JSONSerialization.data(withJSONObject: ["taskID": task.uuidString.lowercased()])) }
        func writeArm(_ bytes: Data, to url: URL? = nil) throws {
            let path = url ?? armFile
            guard FileManager.default.createFile(atPath: path.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        func permissions(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
        func record() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor RejectedReplyTransport: WebModelTransport {
    let reply: String
    private let token = UUID().uuidString
    private var calls: [String] = []
    init(reply: String) { self.reply = reply }
    func operations() -> [String] { calls }
    func request(operation: String, params: Data) async throws -> Data {
        calls.append(operation)
        var value: [String: Any] = ["sessionToken": token]
        switch operation {
        case "webProviderStart": value["state"] = "ready"
        case "webProviderSend": value["state"] = "running"
        case "webProviderPoll":
            value["state"] = "complete"; value["text"] = reply; value["sequence"] = 1
            value["completionEvidence"] = ["codeStructure": ["preCount": 0, "codeCount": 0, "outsideTruncated": false,
                "literalCodeValidJSON": NSNull(), "literalCodeKnownEnvelopeType": NSNull(), "selectedExtraction": "rendered_fallback",
                "extractionReason": "missing_pre", "codeTextLength": -1, "outsideTextLength": 220_002,
                "outsideNodes": [["text": "metadata-content-secret"]], "classes": ["metadata-content-secret"], "unknown": "metadata-content-secret"]]
        case "webProviderFinish", "webProviderCancel": value["state"] = "finished"; value["cleanup"] = "not_created"
        default: throw CocoaError(.featureUnsupported)
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

private final class LockedCaptureResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    func add(_ result: Bool) { lock.lock(); defer { lock.unlock() }; if result { successes += 1 } }
    func successCount() -> Int { lock.lock(); defer { lock.unlock() }; return successes }
}
