import Darwin
import Foundation
import XCTest
@testable import Computa

final class WebsiteBenchmarkCaptureTests: XCTestCase {
    func testUnarmedAndNonfreshScopesStayDormantWithoutChangingTheArm() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        XCTAssertNil(f.consume())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
        try f.arm()
        XCTAssertNil(f.consume(isNewThread: false)); XCTAssertNil(f.consume(isMaintenance: true))
        XCTAssertNil(f.consume(isFirstInference: false))
        XCTAssertNil(f.consume(request: try f.request(nonce: UUID())))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.armFile.path))
        XCTAssertNotNil(f.consume()); XCTAssertNil(f.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.armFile.path))
    }

    func testArmRejectsWrongSchemaNoncePurposeExpiryAndDuplicateKeys() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        let cases: [(String, Any)] = [("schemaVersion", true), ("schemaVersion", 2), ("purpose", "request_metadata_v1"),
            ("nonce", f.nonce.uuidString), ("nonce", UUID().uuidString.lowercased()),
            ("expiresAt", f.timestamp(f.now)), ("expiresAt", f.timestamp(f.now.addingTimeInterval(601))),
            ("expiresAt", "2033-05-18T03:33:20+00:00")]
        for (key, value) in cases {
            var fields = f.fields(); fields[key] = value; try f.arm(fields: fields)
            XCTAssertNil(f.consume(), key); XCTAssertTrue(FileManager.default.fileExists(atPath: f.armFile.path))
        }
        var extra = f.fields(); extra["unknown"] = "declined"; try f.arm(fields: extra); XCTAssertNil(f.consume())
        var missing = f.fields(); missing.removeValue(forKey: "nonce"); try f.arm(fields: missing); XCTAssertNil(f.consume())
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: f.fields()), as: UTF8.self)
        try f.writeArm(Data(("{\"schemaVersion\":1," + valid.dropFirst()).utf8)); XCTAssertNil(f.consume())
        try f.writeArm(Data(repeating: 32, count: 1_025)); XCTAssertNil(f.consume())
    }

    func testArmRejectsSymlinksHardlinksPermissionsAndDirectoryReplacement() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        try f.arm(); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.armFile.path)
        XCTAssertNil(f.consume())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.armFile.path)
        let hardlink = f.root.appendingPathComponent("linked-arm")
        XCTAssertEqual(link(f.armFile.path, hardlink.path), 0); XCTAssertNil(f.consume()); try FileManager.default.removeItem(at: hardlink)
        let symbolicDirectory = f.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: symbolicDirectory, withDestinationURL: f.directory)
        XCTAssertNil(f.consume(directory: symbolicDirectory))
        let moved = f.root.appendingPathComponent("original-arm")
        try FileManager.default.moveItem(at: f.armFile, to: moved)
        try FileManager.default.createSymbolicLink(at: f.armFile, withDestinationURL: moved)
        XCTAssertNil(f.consume()); try FileManager.default.removeItem(at: f.armFile)
        try f.arm(); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
        XCTAssertNil(f.consume())
    }

    func testSuccessfulCapturePreservesEveryOutboundByteAndNativeHashAndCannotOverwrite() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        let request = try f.request()
        try f.arm(); let lease = try XCTUnwrap(f.consume(request: request))
        XCTAssertNil(lease.observationBinding)
        let outbound = request.prompt + "\n\nComputa session marker: " + f.marker
        XCTAssertTrue(f.capture(lease, prompt: request.prompt, outbound: outbound))
        let savedBytes = try Data(contentsOf: f.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: savedBytes) as? [String: Any])
        let payload = try XCTUnwrap(record["payload"] as? String)
        XCTAssertEqual(Data(payload.utf8), Data(outbound.utf8))
        XCTAssertEqual(record["rawSHA256"] as? String, EmbeddedWebModelTransport.promptFingerprint(outbound))
        XCTAssertEqual(record["canonicalSHA256"] as? String, EmbeddedWebModelTransport.outboundFingerprint(outbound))
        XCTAssertEqual(record["utf8Bytes"] as? Int, outbound.utf8.count)
        XCTAssertEqual(record["utf16Count"] as? Int, outbound.utf16.count)
        XCTAssertEqual(record["taskID"] as? String, f.task.uuidString.lowercased())
        XCTAssertEqual(record["threadID"] as? String, f.thread.uuidString.lowercased())
        XCTAssertEqual(record["turnID"] as? String, f.turn.uuidString.lowercased())
        XCTAssertEqual(record["sessionToken"] as? String, f.session.uuidString.lowercased())
        XCTAssertEqual(record["documentGeneration"] as? String, f.generation.uuidString.lowercased())
        XCTAssertEqual(record["captureElapsedBoundary"] as? String, "record_preparation_before_atomic_write")
        XCTAssertTrue((0...600_000).contains(try XCTUnwrap(record["captureElapsedMs"] as? Int)))
        XCTAssertEqual(lease.observationBinding?.rawOutboundSHA, record["rawSHA256"] as? String)
        XCTAssertEqual(lease.observationBinding?.canonicalOutboundSHA, record["canonicalSHA256"] as? String)
        XCTAssertEqual(lease.observationBinding?.utf8Bytes, outbound.utf8.count)
        var info = stat(); XCTAssertEqual(lstat(f.output.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600); XCTAssertEqual(info.st_uid, geteuid()); XCTAssertEqual(info.st_nlink, 1)
        XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: outbound))
        XCTAssertEqual(try Data(contentsOf: f.output), savedBytes)
        try f.arm(); XCTAssertNil(f.consume(), "An existing immutable output cannot be replaced by rearming the same nonce")
    }

    func testWrongNativeModelPromptMarkerOrFreshnessCannotCapture() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        let request = try f.request()
        try f.arm(); let lease = try XCTUnwrap(f.consume(request: request))
        let outbound = request.prompt + "\n\nComputa session marker: " + f.marker
        XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: outbound, fresh: false))
        XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: outbound, model: "browser/chatgpt"))
        XCTAssertFalse(f.capture(lease, prompt: request.prompt + "other", outbound: outbound))
        XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: outbound + "other"))
        XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: String(repeating: "x", count: 180_001)))
        XCTAssertNil(lease.observationBinding); XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
        lease.revoke(); XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: outbound))
    }

    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
    func testNativeFocusBindingRequiresSavedCaptureAndPinsOneExactScope() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        try f.arm(); let request = try f.request(), lease = try XCTUnwrap(f.consume(request: request))
        let view = NSObject(), other = NSObject(), owner = f.session.uuidString
        XCTAssertNil(lease.bindNativeFocusDiagnostic(view: ObjectIdentifier(view), ownerToken: owner, generation: f.generation))
        XCTAssertTrue(f.capture(lease, prompt: request.prompt, outbound: request.prompt + "\n\nComputa session marker: " + f.marker))
        XCTAssertNil(lease.bindNativeFocusDiagnostic(view: ObjectIdentifier(view), ownerToken: UUID().uuidString, generation: f.generation))
        XCTAssertNil(lease.bindNativeFocusDiagnostic(view: ObjectIdentifier(view), ownerToken: owner, generation: UUID()))
        let binding = try XCTUnwrap(lease.bindNativeFocusDiagnostic(view: ObjectIdentifier(view), ownerToken: owner, generation: f.generation))
        XCTAssertEqual(binding.nonce, f.nonce)
        XCTAssertEqual(binding.ownerToken, owner)
        XCTAssertEqual(binding.generation, f.generation)
        XCTAssertNil(lease.bindNativeFocusDiagnostic(view: ObjectIdentifier(view), ownerToken: owner, generation: f.generation))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(other), ownerToken: owner, generation: f.generation,
            onRevocation: {}, action: { XCTFail("Foreign view cannot acquire focus"); return true }))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: UUID().uuidString, generation: f.generation,
            onRevocation: {}, action: { XCTFail("Foreign owner cannot acquire focus"); return true }))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: owner, generation: UUID(),
            onRevocation: {}, action: { XCTFail("Foreign document cannot acquire focus"); return true }))
        var acquisitions = 0
        XCTAssertTrue(binding.activate(view: ObjectIdentifier(view), ownerToken: owner, generation: f.generation,
            onRevocation: {}, action: { acquisitions += 1; return true }))
        XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: owner, generation: f.generation,
            onRevocation: {}, action: { acquisitions += 1; return true }))
        XCTAssertEqual(acquisitions, 1)
        lease.revoke()
    }

    func testNativeFocusBindingRejectsFailedRevokedExpiredAndCancelledCapture() async throws {
        for mode in ["publication_failed", "revoked", "expired", "cancelled"] {
            let f = try BenchmarkCaptureFixture(); defer { f.remove() }
            var fields = f.fields()
            if mode == "expired" { fields["expiresAt"] = f.timestamp(f.now.addingTimeInterval(0.2)) }
            try f.arm(fields: fields)
            let request = try f.request(), lease = try XCTUnwrap(f.consume(request: request))
            let view = NSObject(), identity = ObjectIdentifier(view), owner = f.session.uuidString
            if mode == "publication_failed" { try Data("existing immutable output".utf8).write(to: f.output) }
            XCTAssertEqual(f.capture(lease, prompt: request.prompt,
                outbound: request.prompt + "\n\nComputa session marker: " + f.marker), mode != "publication_failed")
            if mode == "revoked" { lease.revoke() }
            if mode == "expired" { try await Task.sleep(for: .milliseconds(250)) }
            if mode == "cancelled" {
                let attempt = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return lease.bindNativeFocusDiagnostic(view: identity, ownerToken: owner, generation: f.generation)
                }
                let binding = await attempt.value
                XCTAssertNil(binding)
            } else {
                XCTAssertNil(lease.bindNativeFocusDiagnostic(view: identity, ownerToken: owner, generation: f.generation), mode)
            }
            lease.revoke()
        }
    }

    func testNativeFocusFailureIsConsumedAndRevocationIsOnceOutsideTheCaptureLock() async throws {
        for succeeds in [false, true] {
            let f = try BenchmarkCaptureFixture(); defer { f.remove() }
            try f.arm(); let request = try f.request(), lease = try XCTUnwrap(f.consume(request: request))
            XCTAssertTrue(f.capture(lease, prompt: request.prompt, outbound: request.prompt + "\n\nComputa session marker: " + f.marker))
            let view = NSObject(), identity = ObjectIdentifier(view), owner = f.session.uuidString
            let binding = try XCTUnwrap(lease.bindNativeFocusDiagnostic(view: identity, ownerToken: owner, generation: f.generation))
            let callbacks = BenchmarkCaptureCount()
            XCTAssertEqual(binding.activate(view: identity, ownerToken: owner, generation: f.generation,
                onRevocation: {
                    _ = lease.observationBinding // Reenter the capture lock; callback must run outside it.
                    callbacks.increment()
                }, action: { succeeds }), succeeds)
            XCTAssertFalse(binding.activate(view: identity, ownerToken: owner, generation: f.generation,
                onRevocation: {}, action: { XCTFail("An attempted acquisition cannot replay"); return true }))
            let revoked = expectation(description: "Bounded revocation without capture-lock deadlock")
            DispatchQueue.global().async {
                binding.revoke(); lease.revoke(); binding.revoke()
                revoked.fulfill()
            }
            await fulfillment(of: [revoked], timeout: 1)
            XCTAssertEqual(callbacks.value, succeeds ? 1 : 0)
            XCTAssertNil(lease.bindNativeFocusDiagnostic(view: identity, ownerToken: owner, generation: f.generation))
        }
    }
    #endif

    func testConcurrentArmClaimsAreSingleUseAndAReplacementArmIsNeverCaptured() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        try f.arm(); let count = BenchmarkCaptureCount()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in if f.consume() != nil { count.increment() } }
        XCTAssertEqual(count.value, 1)
        try f.arm()
        let replacement = try JSONSerialization.data(withJSONObject: f.fields())
        let old = f.root.appendingPathComponent("old-arm")
        let lease = WebsiteBenchmarkCaptureLease.consume(directory: f.directory, request: try f.request(),
            taskID: f.task.uuidString.lowercased(), threadID: f.thread.uuidString.lowercased(), turnID: f.turn.uuidString.lowercased(),
            runtimeGeneration: f.runtime, preparationID: f.preparation, isNewThread: true, isMaintenance: false,
            isFirstInference: true, now: f.now, beforeArmClaimForTesting: {
                try! FileManager.default.moveItem(at: f.armFile, to: old); try! f.writeArm(replacement)
            })
        XCTAssertNil(lease); XCTAssertEqual(try Data(contentsOf: f.armFile), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    }

    func testPublicationRefusesRacedOutputAndNeverRetriesAfterFailure() throws {
        let f = try BenchmarkCaptureFixture(); defer { f.remove() }
        let request = try f.request()
        try f.arm(); let lease = try XCTUnwrap(f.consume(request: request))
        let outbound = request.prompt + "\n\nComputa session marker: " + f.marker
        let existing = Data("owned existing evidence".utf8)
        XCTAssertFalse(lease.capture(prompt: request.prompt, outbound: outbound, modelID: request.model,
            sessionToken: f.session.uuidString, generation: f.generation, marker: f.marker, nativeFirstFreshInstant: true,
            beforePublishForTesting: { try! existing.write(to: f.output) }))
        XCTAssertEqual(try Data(contentsOf: f.output), existing); XCTAssertNil(lease.observationBinding)
        try FileManager.default.removeItem(at: f.output)
        XCTAssertFalse(f.capture(lease, prompt: request.prompt, outbound: outbound), "A failed publication is still a consumed attempt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    }

    func testPublicationRefusesRevocationDirectorySwapAndNewHardlink() throws {
        for mode in ["revoke", "directory", "hardlink"] {
            let f = try BenchmarkCaptureFixture(); defer { f.remove() }
            let request = try f.request()
            try f.arm(); let lease = try XCTUnwrap(f.consume(request: request))
            let outbound = request.prompt + "\n\nComputa session marker: " + f.marker
            XCTAssertFalse(lease.capture(prompt: request.prompt, outbound: outbound, modelID: request.model,
                sessionToken: f.session.uuidString, generation: f.generation, marker: f.marker, nativeFirstFreshInstant: true,
                beforePublishForTesting: {
                    if mode == "revoke" { lease.revoke() }
                    else if mode == "directory" {
                        try! FileManager.default.moveItem(at: f.directory, to: f.root.appendingPathComponent("original-directory"))
                        try! FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    } else {
                        let temporary = try! FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
                            .first { $0.lastPathComponent.hasPrefix(".payload-") }!
                        XCTAssertEqual(link(temporary.path, f.root.appendingPathComponent("linked-payload").path), 0)
                    }
                }), mode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path)); XCTAssertNil(lease.observationBinding)
        }
    }
    func testSyntheticRequestAcceptsExactNativePolicyAsJoinedOrSeparateTextParts() throws {
        let environment = benchmarkMessage("user", benchmarkEnvironment)
        let policy = ComputaAgentInstructions.runtimeInteractionPolicy(externalChromeTools: false)
        let joined = benchmarkMessage("user", benchmarkText + "\n" + policy)
        var separate = benchmarkMessage("user", benchmarkText)
        separate["content"] = [["type": "input_text", "text": benchmarkText], ["type": "input_text", "text": policy]]
        for user in [joined, separate] {
            let original = try benchmarkRequest([benchmarkMessage("developer", "Native permissions"), environment, user])
            XCTAssertTrue(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(original, nonce: benchmarkNonce))
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: original.continuationRequest) as? [String: Any])
            XCTAssertEqual((raw["input"] as? [[String: Any]])?.last?["content"] as? [[String: String]], user["content"] as? [[String: String]])
        }
    }

    func testSyntheticRequestRejectsPolicyDriftExtraWhitespaceAndUnrecognizedParts() throws {
        let environment = benchmarkMessage("user", benchmarkEnvironment)
        let policy = ComputaAgentInstructions.runtimeInteractionPolicy(externalChromeTools: false)
        let wrongPolicies = [policy + " ", " " + policy, policy + "\n", policy + " extra user material",
            policy.replacingOccurrences(of: "No native activation", with: "Allow native activation"),
            ComputaAgentInstructions.runtimeInteractionPolicy(externalChromeTools: true)]
        for wrong in wrongPolicies {
            let joined = benchmarkMessage("user", benchmarkText + "\n" + wrong)
            var separate = benchmarkMessage("user", benchmarkText)
            separate["content"] = [["type": "input_text", "text": benchmarkText], ["type": "input_text", "text": wrong]]
            for user in [joined, separate] {
                XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([environment, user]), nonce: benchmarkNonce))
            }
        }
        for text in [benchmarkText + "\n\n" + policy, benchmarkText + " " + policy, benchmarkText + "\r\n" + policy] {
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([environment, benchmarkMessage("user", text)]), nonce: benchmarkNonce))
        }
        for values in [[policy, benchmarkText], [benchmarkText, policy, ""], [benchmarkText, policy, "private history"]] {
            var user = benchmarkMessage("user", benchmarkText)
            user["content"] = values.map { ["type": "input_text", "text": $0] }
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([environment, user]), nonce: benchmarkNonce))
        }
    }

    func testSharedRuntimePolicyPreservesTheCurrentNativeWireTextExactly() {
        let expected = "APP_RUNTIME_INTERACTION_POLICY: background_only. No native activation, focus theft or global input, including recovery. Use only offered native background AX or built-in browser UI operations. Offered browser navigation and observed sign-in/account controls remain allowed. Terminal/file operations follow the engine's separate permissions. Images are observation-only. Full Access does not elevate this host policy."
        XCTAssertTrue(ComputaAgentInstructions.runtimeInteractionPolicy(externalChromeTools: false).utf8.elementsEqual(expected.utf8))
        let chrome = expected.replacingOccurrences(of: "offered native background AX or built-in browser UI operations",
            with: "offered background AX, authorized Chrome, or built-in browser UI operations")
        XCTAssertTrue(ComputaAgentInstructions.runtimeInteractionPolicy(externalChromeTools: true).utf8.elementsEqual(chrome.utf8))
    }

    private let benchmarkNonce = UUID(uuidString: "cccccccc-1111-4222-8333-dddddddddddd")!
    private var benchmarkText: String {
        "Computa latency benchmark \(benchmarkNonce.uuidString.lowercased()). Reply with exactly HI. Do not use tools."
    }
    private var benchmarkEnvironment: String {
        "<environment_context>\n<cwd>/tmp/computa-empty-fixture</cwd>\n<shell>zsh</shell>\n<current_date>2026-10-18</current_date>\n<timezone>America/New_York</timezone>\n<filesystem><workspace_roots><root>/tmp/computa-empty-fixture</root></workspace_roots><permission_profile type=\"disabled\"><file_system type=\"unrestricted\" /></permission_profile></filesystem>\n</environment_context>"
    }
    private func benchmarkMessage(_ role: String, _ text: String) -> [String: Any] {
        ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
    }
    private func benchmarkRequest(_ input: [[String: Any]], model: String? = nil,
                                  extras: [String: Any] = [:]) throws -> WebModelResponseCodec.Request {
        var value: [String: Any] = ["model": model ?? WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID,
                                  "input": input, "instructions": "Synthetic native instruction prelude", "tools": []]
        for (key, item) in extras { value[key] = item }
        return try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    func testSyntheticRequestAdmitsExactEnvironmentAndNonceIncludingNativeDeveloperPrelude() throws {
        let env = benchmarkMessage("user", benchmarkEnvironment), user = benchmarkMessage("user", benchmarkText)
        XCTAssertTrue(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, user]), nonce: benchmarkNonce))
        XCTAssertTrue(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([
            benchmarkMessage("developer", "Native permissions"), benchmarkMessage("developer", "Native tool contract"), env, user]), nonce: benchmarkNonce))
    }
    func testSyntheticRequestRejectsAnyHistoryOrMisorderedPrelude() throws {
        let env = benchmarkMessage("user", benchmarkEnvironment), user = benchmarkMessage("user", benchmarkText)
        for input in [[benchmarkMessage("user", "earlier private message"), env, user],
                      [benchmarkMessage("assistant", "earlier answer"), env, user],
                      [benchmarkMessage("system", "extra system message"), env, user],
                      [env, benchmarkMessage("developer", "late prelude"), user],
                      [env, user, benchmarkMessage("user", "extra user")],
                      [["type": "function_call_output", "call_id": "call_prior", "output": "earlier result"], env, user]] {
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest(input), nonce: benchmarkNonce))
        }
    }
    func testSyntheticRequestRequiresByteExactNonceTextAndConcreteInstant() throws {
        let env = benchmarkMessage("user", benchmarkEnvironment)
        for text in [benchmarkText + "\n", " " + benchmarkText, benchmarkText.replacingOccurrences(of: benchmarkNonce.uuidString.lowercased(), with: benchmarkNonce.uuidString),
                     benchmarkText.replacingOccurrences(of: "exactly HI", with: "exactly hi"), "hi"] {
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, benchmarkMessage("user", text)]), nonce: benchmarkNonce))
        }
        let user = benchmarkMessage("user", benchmarkText)
        for model in ["browser/chatgpt", WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/high", label: "High").modelID] {
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, user], model: model), nonce: benchmarkNonce))
        }
        XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, user]), nonce: UUID()))
    }
    func testSyntheticRequestRejectsHiddenContentAndEnvelopeReferences() throws {
        let env = benchmarkMessage("user", benchmarkEnvironment), user = benchmarkMessage("user", benchmarkText)
        var extraPart = user; extraPart["content"] = [["type": "input_text", "text": benchmarkText], ["type": "input_text", "text": "hidden history"]]
        XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, extraPart]), nonce: benchmarkNonce))
        var unknown = user; unknown["private_history"] = "must not capture"
        XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, unknown]), nonce: benchmarkNonce))
        for key in ["conversation", "conversation_id", "response_id"] {
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([env, user], extras: [key: "retained"]), nonce: benchmarkNonce))
        }
        // prepareRequest already rejects non-null previous_response_id/media. Test
        // that layer's rejection as well; never rebuild a sanitized surrogate.
        XCTAssertThrowsError(try benchmarkRequest([env, user], extras: ["previous_response_id": "resp_prior"]))
        var media = user; media["content"] = [["type": "input_image", "image_url": "data:image/png;base64,AA=="]]
        XCTAssertThrowsError(try benchmarkRequest([env, media]))
    }
    func testEnvironmentValidationRejectsTagSpoofingAndMixedProse() throws {
        let user = benchmarkMessage("user", benchmarkText)
        for text in ["<environment_context>earlier user history</environment_context>", benchmarkEnvironment + "secret suffix",
                     "secret prefix" + benchmarkEnvironment,
                     benchmarkEnvironment.replacingOccurrences(of: "</environment_context>", with: "<user>secret</user></environment_context>"),
                     benchmarkEnvironment.replacingOccurrences(of: "<shell>zsh</shell>", with: "<shell>zsh</shell><shell>bash</shell>"),
                     "<!DOCTYPE environment_context [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>" + benchmarkEnvironment] {
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try benchmarkRequest([benchmarkMessage("user", text), user]), nonce: benchmarkNonce))
        }
    }
    func testSyntheticRequestRejectsDuplicateDecodedJSONKeysBeforeCapturingRawRequest() throws {
        let clean = try benchmarkRequest([benchmarkMessage("user", benchmarkEnvironment), benchmarkMessage("user", benchmarkText)])
        let original = String(decoding: clean.continuationRequest, as: UTF8.self)
        // Foundation accepts the last duplicate value. The helper must reject all
        // raw duplicate keys, including equivalent escaped key spellings.
        for raw in [original.replacingOccurrences(of: "\"instructions\":", with: "\"instructions\":\"private prior material\",\"instructions\":"),
                    original.replacingOccurrences(of: "\"instructions\":", with: "\"instru\\u0063tions\":\"private prior material\",\"instructions\":")] {
            let request = try WebModelResponseCodec.prepareRequest(Data(raw.utf8))
            XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(request, nonce: benchmarkNonce))
        }
    }
}

private final class BenchmarkCaptureFixture: Sendable {
    let root: URL, directory: URL
    let nonce = UUID(uuidString: "cccccccc-1111-4222-8333-dddddddddddd")!, task = UUID(), thread = UUID(), turn = UUID(), runtime = UUID(), preparation = UUID()
    let session = UUID(), generation = UUID(), marker = UUID().uuidString
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var armFile: URL { directory.appendingPathComponent("arm.json") }
    var output: URL { directory.appendingPathComponent("payload-" + nonce.uuidString.lowercased() + ".json") }
    init() throws {
        root = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("ComputaSyntheticCapture-" + UUID().uuidString)
        directory = root.appendingPathComponent("WebsiteBenchmarkDiagnostics-v1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func request(nonce other: UUID? = nil) throws -> WebModelResponseCodec.Request {
        let text = "Computa latency benchmark \((other ?? nonce).uuidString.lowercased()). Reply with exactly HI. Do not use tools."
            + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy(externalChromeTools: false)
        return try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: [
            "model": WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID,
            "instructions": "Synthetic native contract 🧭 e\u{0301}\r\n", "tools": [], "input": [
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context><cwd>/tmp/東京</cwd><shell>zsh</shell></environment_context>"]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]], options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    func fields() -> [String: Any] { ["schemaVersion": 1, "purpose": WebsiteBenchmarkCaptureLease.purpose,
        "nonce": nonce.uuidString.lowercased(), "expiresAt": timestamp(now.addingTimeInterval(60))] }
    func timestamp(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f.string(from: date)
    }
    func arm(fields: [String: Any]? = nil) throws { try writeArm(JSONSerialization.data(withJSONObject: fields ?? self.fields())) }
    func writeArm(_ data: Data) throws {
        try data.write(to: armFile); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armFile.path)
    }
    func consume(request: WebModelResponseCodec.Request? = nil, directory: URL? = nil,
        isNewThread: Bool = true, isMaintenance: Bool = false, isFirstInference: Bool = true) -> WebsiteBenchmarkCaptureLease? {
        guard let request = request ?? (try? self.request()) else { return nil }
        return WebsiteBenchmarkCaptureLease.consume(directory: directory ?? self.directory, request: request,
            taskID: task.uuidString.lowercased(), threadID: thread.uuidString.lowercased(), turnID: turn.uuidString.lowercased(),
            runtimeGeneration: runtime, preparationID: preparation, isNewThread: isNewThread,
            isMaintenance: isMaintenance, isFirstInference: isFirstInference, now: now)
    }
    func capture(_ lease: WebsiteBenchmarkCaptureLease, prompt: String, outbound: String,
        model: String? = nil, fresh: Bool = true) -> Bool {
        lease.capture(prompt: prompt, outbound: outbound, modelID: model ?? (try? request())?.model ?? "",
            sessionToken: session.uuidString, generation: generation, marker: marker, nativeFirstFreshInstant: fresh)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private final class BenchmarkCaptureCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

// Foundation can shorten /private/var back to the symlink /var even after
// resolvingSymlinksInPath(). The production capture deliberately rejects
// symlink ancestors, so positive fixtures must use the actual POSIX path.
func websiteBenchmarkTemporaryDirectory() throws -> URL {
    let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
