import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Computa

final class ClaudeResponseStreamLeaseTests: XCTestCase {
    func testLegacyValidationEstablishesEligibilityBeforeItsFirstCheck() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        var validated = false, checksBeforeValidation = 0
        let record = Data("finite legacy diagnostic".utf8)
        XCTAssertTrue(WebsitePrivateDiagnosticCapture.publish(directory: f.directory, outputName: "request.json",
            maximumArmBytes: 4_096, maximumRecordBytes: 1_024, makeRecord: { _ in
                validated = true; return record
            }, isCurrent: {
                if !validated { checksBeforeValidation += 1 }
                return validated
            }))
        XCTAssertEqual(checksBeforeValidation, 0)
        XCTAssertFalse(f.exists(f.armFile))
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("request.json")), record)
    }

    func testConsumesExactlyOnceAndBindsEveryNativeContextField() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease())
        XCTAssertTrue(lease.isCurrent); XCTAssertFalse(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.outputURL))
        XCTAssertNil(f.lease()); XCTAssertTrue(lease.matches(context: f.context))
        XCTAssertEqual(lease.remainingMilliseconds, 60_000)
        for changed in 0...6 {
            let c = f.context
            let other = ClaudeResponseStreamDiagnostic.Context(taskID: changed == 0 ? UUID() : c.taskID,
                threadID: changed == 1 ? UUID() : c.threadID, turnID: changed == 2 ? UUID() : c.turnID,
                runtimeGeneration: changed == 3 ? UUID() : c.runtimeGeneration,
                preparationID: changed == 4 ? UUID() : c.preparationID, inferenceID: changed == 5 ? UUID() : c.inferenceID,
                modelID: changed == 6 ? "browser/claude" : c.modelID)
            XCTAssertFalse(lease.matches(context: other), "field \(changed)")
        }
        lease.revoke(); XCTAssertFalse(lease.isCurrent); XCTAssertFalse(lease.matches(context: f.context))
        XCTAssertEqual(lease.remainingMilliseconds, 0)
    }

    func testViewAndDocumentBindOnlyOnceWithExactOwnerToken() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease()), view = NSObject(), other = NSObject(), token = "ABCDEF12-3456-4789-ABCD-0123456789AB", generation = UUID()
        let id = ObjectIdentifier(view), otherID = ObjectIdentifier(other)
        XCTAssertFalse(lease.bind(view: id, ownerToken: token, generation: generation))
        XCTAssertTrue(lease.claim(view: id)); XCTAssertFalse(lease.claim(view: id)); XCTAssertFalse(lease.claim(view: otherID))
        XCTAssertFalse(lease.bind(view: otherID, ownerToken: token, generation: generation))
        XCTAssertFalse(lease.bind(view: id, ownerToken: "not-a-native-session", generation: generation))
        XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
        XCTAssertFalse(lease.bind(view: id, ownerToken: token, generation: generation))
        XCTAssertTrue(lease.matches(view: id, ownerToken: token, generation: generation))
        XCTAssertFalse(lease.matches(view: otherID, ownerToken: token, generation: generation))
        XCTAssertFalse(lease.matches(view: id, ownerToken: UUID().uuidString, generation: generation))
        XCTAssertFalse(lease.matches(view: id, ownerToken: token.lowercased(), generation: generation))
        XCTAssertFalse(lease.matches(view: id, ownerToken: token, generation: UUID()))
    }

    func testPreparedPromptUsesExactBytesAndExpiresWithLease() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease()), prompt = f.request.prompt
        XCTAssertTrue(lease.matchesPrompt(prompt))
        XCTAssertFalse(lease.matchesPrompt(prompt + " "))
        XCTAssertFalse(lease.matchesPrompt(prompt.replacingOccurrences(of: "Computa", with: "COMPUTA")))
        lease.revoke(); XCTAssertFalse(lease.matchesPrompt(prompt))
    }

    func testPersistProducesOnePrivateFiniteRecordWithExactNativeContext() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease()), view = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
        XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
        let snapshot = try f.snapshot()
        XCTAssertTrue(lease.persist(snapshot: snapshot, view: id, ownerToken: token, generation: generation))
        let data = try Data(contentsOf: f.outputURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["purpose"] as? String, ClaudeResponseStreamDiagnostic.purpose)
        XCTAssertEqual(object["evidenceClass"] as? String, "page_world_untrusted")
        XCTAssertEqual(object["instrumented"] as? Bool, true)
        XCTAssertEqual(object["taskID"] as? String, f.context.taskID.uuidString.lowercased())
        XCTAssertEqual(object["threadID"] as? String, f.context.threadID.uuidString.lowercased())
        XCTAssertEqual(object["turnID"] as? String, f.context.turnID.uuidString.lowercased())
        XCTAssertEqual(object["runtimeGeneration"] as? String, f.context.runtimeGeneration.uuidString.lowercased())
        XCTAssertEqual(object["preparationID"] as? String, f.context.preparationID.uuidString.lowercased())
        XCTAssertEqual(object["inferenceID"] as? String, f.context.inferenceID.uuidString.lowercased())
        XCTAssertEqual(object["modelID"] as? String, f.context.modelID)
        XCTAssertEqual(object["sessionToken"] as? String, token)
        XCTAssertEqual(object["documentGeneration"] as? String, generation.uuidString.lowercased())
        XCTAssertEqual(object["serverPromptUTF8Bytes"] as? Int, f.request.prompt.utf8.count)
        XCTAssertEqual(object["serverPromptSHA256"] as? String, f.hash(Data(f.request.prompt.utf8)))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(lease.expectedMarker))
        XCTAssertNil(object["serverPrompt"]); XCTAssertNil(object["responseText"]); XCTAssertNil(object["submissionVerified"])
        var info = stat(); XCTAssertEqual(lstat(f.outputURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600); XCTAssertEqual(info.st_uid, geteuid()); XCTAssertEqual(info.st_nlink, 1)
        XCTAssertFalse(lease.persist(snapshot: snapshot, view: id, ownerToken: token, generation: generation))
        XCTAssertEqual(try Data(contentsOf: f.outputURL), data)
    }

    func testWrongAndRevokedCallbacksCannotPublish() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease()), view = NSObject(), other = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
        XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
        let snapshot = try f.snapshot()
        XCTAssertFalse(lease.persist(snapshot: snapshot, view: ObjectIdentifier(other), ownerToken: token, generation: generation))
        XCTAssertFalse(lease.persist(snapshot: snapshot, view: id, ownerToken: UUID().uuidString, generation: generation))
        XCTAssertFalse(lease.persist(snapshot: snapshot, view: id, ownerToken: token, generation: UUID()))
        XCTAssertFalse(f.exists(f.outputURL))
        lease.revoke()
        XCTAssertFalse(lease.persist(snapshot: snapshot, view: id, ownerToken: token, generation: generation))
        XCTAssertFalse(f.exists(f.outputURL))
    }

    func testSnapshotIsRevalidatedAndFailedAttemptIsNotRetried() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease()), view = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
        XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
        let forged = ClaudeResponseStreamSnapshot(encodedData: Data(#"{"responseText":"PRIVATE_CANARY"}"#.utf8))
        XCTAssertFalse(lease.persist(snapshot: forged, view: id, ownerToken: token, generation: generation))
        XCTAssertFalse(lease.persist(snapshot: try f.snapshot(), view: id, ownerToken: token, generation: generation))
        XCTAssertFalse(f.exists(f.outputURL))
    }

    func testRevocationCanFinishWhileRecordWriteIsPaused() async throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let lease = try XCTUnwrap(f.lease()), view = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
        XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
        let entered = expectation(description: "write preparation"), finished = expectation(description: "worker finished")
        let revoked = expectation(description: "revocation does not wait for write"), gate = DispatchSemaphore(value: 0)
        let result = ClaudeLeaseTestValue<Bool>(), snapshot = try f.snapshot()
        DispatchQueue.global().async {
            let published = lease.persist(snapshot: snapshot, view: id, ownerToken: token, generation: generation,
                beforeRecordWriteForTesting: { entered.fulfill(); _ = gate.wait(timeout: .now() + 5) })
            result.set(published); finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        DispatchQueue.global().async { lease.revoke(); revoked.fulfill() }
        await fulfillment(of: [revoked], timeout: 1)
        gate.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(result.get(), false); XCTAssertFalse(f.exists(f.outputURL))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
    }

    func testCommitDeadlineRejectsLatePublicationWithoutWaitingForRevocationTimer() throws {
        for originalExpiresFirst in [false, true] {
            let f = try ClaudeResponseStreamLeaseFixture(lifetime: originalExpiresFirst ? 0.2 : 300)
            defer { f.cleanup() }
            let lease = try XCTUnwrap(f.lease()), view = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
            XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
            let deadline = ContinuousClock.now + .milliseconds(originalExpiresFirst ? 2_000 : 100)
            XCTAssertFalse(lease.persist(snapshot: try f.snapshot(), view: id, ownerToken: token, generation: generation,
                commitDeadline: deadline, beforeCommitForTesting: { Thread.sleep(forTimeInterval: 0.25) }))
            XCTAssertFalse(f.exists(f.outputURL))
            XCTAssertEqual(lease.isCurrent, !originalExpiresFirst, "No timer or explicit revocation is needed to enforce the smaller deadline")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
        }
    }

    func testFinalRevocationAndDirectoryReplacementPreventCommit() throws {
        for replace in [false, true] {
            let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
            let lease = try XCTUnwrap(f.lease()), view = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
            XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
            let old = f.root.appendingPathComponent("held-original")
            XCTAssertFalse(lease.persist(snapshot: try f.snapshot(), view: id, ownerToken: token, generation: generation,
                beforeCommitForTesting: {
                    if replace {
                        do {
                            try FileManager.default.moveItem(at: f.directory, to: old)
                            try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        } catch { XCTFail("Could not replace test directory: \(error)") }
                    } else { lease.revoke() }
                }))
            XCTAssertFalse(f.exists(f.outputURL)); XCTAssertFalse(f.exists(old.appendingPathComponent("response-metadata.json")))
            if replace { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty) }
        }
    }

    func testArmReplacementAtClaimIsPreservedAndDoesNotGrantLease() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let replacement = Data(#"{"purpose":"replacement-not-authorized"}"#.utf8)
        let result = ClaudeResponseStreamLease.consume(directory: f.directory, context: f.context, request: f.request,
            isNewThread: true, isMaintenance: false, isFirstInference: true, hasCorrectionTicket: false, now: f.now,
            beforeArmClaimForTesting: {
                do { try FileManager.default.removeItem(at: f.armFile); try f.write(replacement, to: f.armFile) }
                catch { XCTFail("Could not replace test arm: \(error)") }
            })
        XCTAssertNil(result); XCTAssertEqual(try Data(contentsOf: f.armFile), replacement); XCTAssertFalse(f.exists(f.outputURL))
    }

    func testOriginalExpiryIncludesTimeSpentClaimingAndNeverRenews() throws {
        let f = try ClaudeResponseStreamLeaseFixture(lifetime: 0.1); defer { f.cleanup() }
        let called = ClaudeLeaseTestValue<Bool>()
        let result = ClaudeResponseStreamLease.consume(directory: f.directory, context: f.context, request: f.request,
            isNewThread: true, isMaintenance: false, isFirstInference: true, hasCorrectionTicket: false, now: f.now,
            beforeArmClaimForTesting: { called.set(true); Thread.sleep(forTimeInterval: 0.15) })
        XCTAssertEqual(called.get(), true); XCTAssertNil(result); XCTAssertFalse(f.exists(f.outputURL))
        let next = try ClaudeResponseStreamLeaseFixture(lifetime: 0.2); defer { next.cleanup() }
        let lease = try XCTUnwrap(next.lease())
        XCTAssertGreaterThan(lease.remainingMilliseconds, 0); XCTAssertLessThanOrEqual(lease.remainingMilliseconds, 200)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertFalse(lease.isCurrent); XCTAssertEqual(lease.remainingMilliseconds, 0)
        XCTAssertFalse(lease.claim(view: ObjectIdentifier(NSObject())))
    }

    func testExistingOutputIsNeverOverwrittenAndNewArmRemainsUnconsumed() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let retained = Data("original diagnostic".utf8); try f.write(retained, to: f.outputURL)
        XCTAssertNil(f.lease()); XCTAssertTrue(f.exists(f.armFile))
        XCTAssertEqual(try Data(contentsOf: f.outputURL), retained)
        try FileManager.default.removeItem(at: f.outputURL)
        let lease = try XCTUnwrap(f.lease()), view = NSObject(), id = ObjectIdentifier(view), token = UUID().uuidString, generation = UUID()
        XCTAssertTrue(lease.claim(view: id)); XCTAssertTrue(lease.bind(view: id, ownerToken: token, generation: generation))
        XCTAssertFalse(lease.persist(snapshot: try f.snapshot(), view: id, ownerToken: token, generation: generation,
            beforeCommitForTesting: {
                do { try f.write(retained, to: f.outputURL) } catch { XCTFail("Could not create competing record: \(error)") }
            }))
        XCTAssertEqual(try Data(contentsOf: f.outputURL), retained)
    }

    func testPrivateArmRulesRejectSymlinksHardlinksAndPermissions() throws {
        for mode in ["directory_mode", "arm_mode", "arm_symlink", "arm_hardlink", "ancestor_symlink"] {
            let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
            var directory = f.directory
            switch mode {
            case "directory_mode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
            case "arm_mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.armFile.path)
            case "arm_symlink":
                let original = f.root.appendingPathComponent("original-arm")
                try FileManager.default.moveItem(at: f.armFile, to: original)
                try FileManager.default.createSymbolicLink(at: f.armFile, withDestinationURL: original)
            case "arm_hardlink": XCTAssertEqual(link(f.armFile.path, f.root.appendingPathComponent("link").path), 0)
            default:
                let alias = f.root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.directory)
                directory = alias
            }
            XCTAssertNil(ClaudeResponseStreamLease.consume(directory: directory, context: f.context, request: f.request,
                isNewThread: true, isMaintenance: false, isFirstInference: true, hasCorrectionTicket: false, now: f.now), mode)
            XCTAssertFalse(f.exists(f.outputURL), mode)
        }
    }

    func testConcurrentConsumersHaveOnlyOneWinner() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        let winners = ClaudeLeaseTestValue<[ClaudeResponseStreamLease]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            if let lease = f.lease() { winners.update { $0.append(lease) } }
        }
        XCTAssertEqual(winners.get()?.count, 1); XCTAssertFalse(f.exists(f.armFile))
    }

    func testDefaultOffScopeExclusionsAndTaskLocalDoNotCreateFiles() throws {
        let f = try ClaudeResponseStreamLeaseFixture(); defer { f.cleanup() }
        XCTAssertNil(ClaudeResponseStreamLease.consume(directory: nil, context: f.context, request: f.request,
            isNewThread: true, isMaintenance: false, isFirstInference: true, hasCorrectionTicket: false, now: f.now))
        for excluded in 0...3 {
            XCTAssertNil(ClaudeResponseStreamLease.consume(directory: f.directory, context: f.context, request: f.request,
                isNewThread: excluded != 0, isMaintenance: excluded == 1, isFirstInference: excluded != 2,
                hasCorrectionTicket: excluded == 3, now: f.now))
        }
        XCTAssertTrue(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.outputURL))
        let lease = try XCTUnwrap(f.lease())
        XCTAssertNil(ClaudeResponseStreamLease.current)
        ClaudeResponseStreamLease.$current.withValue(lease) { XCTAssertTrue(ClaudeResponseStreamLease.current === lease) }
        XCTAssertNil(ClaudeResponseStreamLease.current)
    }
}

/// Shared real-file fixture for native browser/transport diagnostic integration.
/// No production test bypass and no provider/network/GUI access are involved.
struct ClaudeResponseStreamLeaseFixture: Sendable {
    let root: URL, directory: URL, armFile: URL, outputURL: URL
    let context: ClaudeResponseStreamDiagnostic.Context
    let request: WebModelResponseCodec.Request
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let nonce = UUID()

    init(modelID: String = WebsiteModelChoice(provider: "claude", key: "Opus 3", label: "Opus 3").modelID,
         lifetime: TimeInterval = 300) throws {
        root = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("claude-stream-" + UUID().uuidString)
        directory = root.appendingPathComponent(ClaudeResponseStreamDiagnostic.directoryName)
        armFile = directory.appendingPathComponent("arm.json"); outputURL = directory.appendingPathComponent("response-metadata.json")
        context = .init(taskID: UUID(), threadID: UUID(), turnID: UUID(), runtimeGeneration: UUID(),
                        preparationID: UUID(), inferenceID: UUID(), modelID: modelID)
        let userText = ClaudeResponseStreamDiagnostic.syntheticUserText(nonce: nonce)
        func message(_ role: String, _ text: String) -> [String: Any] {
            ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        }
        let input = [message("developer", "Synthetic native policy"),
                     message("user", "<environment_context><cwd>/tmp/computa-empty-fixture</cwd><shell>zsh</shell></environment_context>"),
                     message("user", userText + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy())]
        request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: [
            "model": modelID, "input": input, "tools": [], "tool_choice": "auto", "parallel_tool_calls": false,
        ] as [String: Any], options: [.sortedKeys]))
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let arm: [String: Any] = ["schemaVersion": 1, "provider": "claude", "purpose": ClaudeResponseStreamDiagnostic.purpose,
            "nonce": nonce.uuidString.lowercased(), "modelID": modelID, "expiresAt": formatter.string(from: now.addingTimeInterval(lifetime)),
            "userPromptSHA256": SHA256.hash(data: Data(userText.utf8)).map { String(format: "%02x", $0) }.joined()]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(JSONSerialization.data(withJSONObject: arm, options: [.sortedKeys]), to: armFile)
    }
    func lease() -> ClaudeResponseStreamLease? {
        ClaudeResponseStreamLease.consume(directory: directory, context: context, request: request,
            isNewThread: true, isMaintenance: false, isFirstInference: true, hasCorrectionTicket: false, now: now)
    }
    func snapshot() throws -> ClaudeResponseStreamSnapshot {
        try ClaudeResponseStreamSnapshot.parse(JSONSerialization.data(withJSONObject: [
            "version": 1, "scope": "passive_synthetic_response_metadata_only", "phase": "terminal", "terminalReason": "stopped",
            "armed": false, "armUsed": false, "matchedCalls": 0, "status": NSNull(), "mime": NSNull(), "route": NSNull(),
            "bytesRead": 0, "eventCount": 0, "markerPresent": false, "readPending": false, "readCalls": 0, "lockReleased": false,
            "unterminatedEventDiscarded": false, "transitionCount": 0, "transitionReason": "none", "restore": "restored", "events": [],
        ] as [String: Any], options: [.sortedKeys]))
    }
    func write(_ bytes: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class ClaudeLeaseTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    init(_ value: Value? = nil) { self.value = value }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value? { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { if value != nil { body(&value!) } } }
}
