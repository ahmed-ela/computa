import Foundation
import XCTest
@testable import Computa

@MainActor
final class GroqRejectedRequestCaptureTests: XCTestCase {
    private typealias Capture = GroqRejectedRequestCapture
    private typealias C = WebModelResponseCodec
    private let failure = C.Failure.groqPromptBudgetExceeded(actualTokens: 6_001, maximumTokens: 6_000, reservedTokens: 2_000)

    func testMatchedCandidatePreservesExactCanonicalBytesNativeIdentityAndNoAuthority() throws {
        let f = try fixture(continuation: true)
        let scope = try XCTUnwrap(f.prepare())
        // This tests association and serialization, not a measured over-budget
        // prompt. The Server integration test supplies the actual counter result.
        XCTAssertTrue(scope.capture(failure: failure, candidate: f.request, candidateFailure: failure, isCurrent: { true }))
        let bytes = try Data(contentsOf: f.output), value = try f.record()
        XCTAssertEqual(value["version"] as? Int, 1)
        XCTAssertEqual(value["purpose"] as? String, Capture.purpose)
        XCTAssertEqual(value["nonce"] as? String, f.nonce.uuidString.lowercased())
        for (key, id) in [("taskID", f.context.taskID), ("threadID", f.context.threadID), ("turnID", f.context.turnID),
                          ("runtimeGeneration", f.context.runtimeGeneration), ("preparationID", f.context.preparationID),
                          ("transportGeneration", f.context.transportGeneration), ("inferenceID", f.context.inferenceID)] {
            XCTAssertEqual(value[key] as? String, id.uuidString.lowercased(), key)
        }
        XCTAssertEqual(value["modelID"] as? String, Capture.modelID)
        XCTAssertEqual(value["userPromptSHA256"] as? String, GroqOwnedStatusLease.digest(f.user))
        for key in ["submitted", "automaticReplay", "responseAuthority", "cleanupAuthority"] {
            XCTAssertEqual(value[key] as? Bool, false, key)
        }
        let encoded = try XCTUnwrap(value["canonicalRequestBase64"] as? String)
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: encoded)), f.request.continuationRequest)
        XCTAssertTrue(String(decoding: f.request.continuationRequest, as: UTF8.self).contains(#""decimal":1.00"#))
        XCTAssertTrue(String(decoding: f.request.continuationRequest, as: UTF8.self).contains(#""escaped":"\u0061"#))
        XCTAssertEqual(value["canonicalRequestBytes"] as? Int, f.request.continuationRequest.count)
        XCTAssertEqual(value["canonicalRequestSHA256"] as? String, digest(f.request.continuationRequest))
        XCTAssertEqual(value["candidateState"] as? String, "matched")
        XCTAssertEqual(value["displayedPrompt"] as? String, f.request.prompt)
        XCTAssertEqual(value["displayedPromptBytes"] as? Int, f.request.prompt.utf8.count)
        XCTAssertEqual(value["displayedPromptSHA256"] as? String, GroqOwnedStatusLease.digest(f.request.prompt))
        let statistics = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.request.promptStatistics)) as? NSDictionary
        XCTAssertEqual(try XCTUnwrap(value["statistics"] as? NSDictionary), try XCTUnwrap(statistics))
        XCTAssertEqual(try permissions(f.output), 0o600)
        XCTAssertFalse(f.exists(f.arm))
        XCTAssertFalse(scope.capture(failure: failure, candidate: f.request, candidateFailure: failure, isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: f.output), bytes)
    }

    func testPrepareRequiresExactPrivateArmNativeTaskAndControlled120BFixture() throws {
        for mode in ["no_arm", "nil_directory", "foreign_task", "foreign_thread", "foreign_turn", "wrong_context_model",
                     "wrong_request_model", "nonfixture", "hash", "purpose", "nonce", "uppercase_nonce", "uppercase_task",
                     "schema_bool", "missing_key", "extra_key", "duplicate_key", "public_arm", "public_directory", "oversized_arm"] {
            let f = try fixture(user: mode == "nonfixture" ? Self.user.replacingOccurrences(of: "\n", with: " ") : Self.user,
                                model: mode == "wrong_request_model" ? GroqOwnedStatusLease.Profile.gptoss20b.choice.modelID : Capture.modelID)
            var fields = f.fields()
            switch mode {
            case "foreign_task": fields["taskID"] = UUID().uuidString.lowercased()
            case "foreign_thread": fields["threadID"] = UUID().uuidString.lowercased()
            case "foreign_turn": fields["turnID"] = UUID().uuidString.lowercased()
            case "hash": fields["userPromptSHA256"] = GroqOwnedStatusLease.digest("another fixture")
            case "purpose": fields["purpose"] = GroqOwnedStatusLease.FixtureTurn.responseStreamTailPurpose
            case "nonce": fields["nonce"] = "not-a-uuid"
            case "uppercase_nonce": fields["nonce"] = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
            case "uppercase_task": fields["taskID"] = f.context.taskID.uuidString
            case "schema_bool": fields["schemaVersion"] = true
            case "missing_key": fields.removeValue(forKey: "threadID")
            case "extra_key": fields["headers"] = "not permitted"
            default: break
            }
            if mode == "duplicate_key" {
                let original = String(decoding: try encoded(fields), as: UTF8.self)
                try f.writeArm(Data(("{\"purpose\":\"foreign\"," + String(original.dropFirst())).utf8))
            } else if mode == "oversized_arm" {
                try f.writeArm(Data(repeating: 32, count: Capture.maximumArmBytes + 1))
            } else { try f.writeArm(try encoded(fields)) }
            if mode == "no_arm" { try FileManager.default.removeItem(at: f.arm) }
            if mode == "public_arm" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.arm.path) }
            if mode == "public_directory" { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path) }
            let armBefore = try? Data(contentsOf: f.arm)
            let context = mode == "wrong_context_model" ? f.contextWithModel(GroqOwnedStatusLease.Profile.gptoss20b.choice.modelID) : f.context
            XCTAssertNil(Capture.prepare(directory: mode == "nil_directory" ? nil : f.directory, context: context,
                request: f.request, now: f.now, isCurrent: { true }), mode)
            XCTAssertEqual(try? Data(contentsOf: f.arm), armBefore, mode)
            XCTAssertFalse(f.exists(f.output), mode)
        }
    }

    func testExpiryIsCanonicalBoundedAndContinuesToFencePreparedScope() async throws {
        let f = try fixture()
        let expiry = f.now.addingTimeInterval(600)
        try f.writeArm(try encoded(f.fields(expiresAt: expiry)))
        let bytes = try Data(contentsOf: f.arm)
        XCTAssertNil(Capture.prepare(directory: f.directory, context: f.context, request: f.request,
            now: expiry.addingTimeInterval(-600.001), isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: f.arm), bytes)
        XCTAssertNotNil(Capture.prepare(directory: f.directory, context: f.context, request: f.request,
            now: expiry.addingTimeInterval(-600), isCurrent: { true }))
        XCTAssertNil(Capture.prepare(directory: f.directory, context: f.context, request: f.request, now: expiry, isCurrent: { true }))
        for invalid in ["2027-01-15T08:00:00Z", "2027-01-15T08:00:00.000+00:00", "2027-02-30T08:00:00.000Z"] {
            var fields = f.fields(); fields["expiresAt"] = invalid
            try f.writeArm(try encoded(fields))
            XCTAssertNil(f.prepare(), invalid)
        }
        try f.writeArm(try encoded(f.fields(expiresAt: f.now.addingTimeInterval(0.05))))
        let short = try XCTUnwrap(f.prepare())
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(short.capture(failure: failure, candidate: f.request, candidateFailure: failure, isCurrent: { true }))
        XCTAssertFalse(f.exists(f.output))
        XCTAssertTrue(f.exists(f.arm))
    }

    func testCandidateAssociationNeverLabelsMissingOrDifferentRequestAsMatched() throws {
        for mode in ["unavailable", "failure_absent", "failure_differs", "canonical_differs", "model_differs"] {
            let f = try fixture(), scope = try XCTUnwrap(f.prepare())
            let candidate: C.Request?
            switch mode {
            case "unavailable": candidate = nil
            case "canonical_differs": candidate = try request(user: f.user, stream: true)
            case "model_differs": candidate = try request(user: f.user, model: GroqOwnedStatusLease.Profile.gptoss20b.choice.modelID)
            default: candidate = f.request
            }
            let candidateFailure: C.Failure? = mode == "failure_absent" ? nil :
                mode == "failure_differs" ? .groqPromptBudgetExceeded(actualTokens: 6_002, maximumTokens: 6_000, reservedTokens: 2_000) : failure
            XCTAssertTrue(scope.capture(failure: failure, candidate: candidate, candidateFailure: candidateFailure, isCurrent: { true }), mode)
            let value = try f.record()
            XCTAssertEqual(value["candidateState"] as? String, mode == "unavailable" ? "unavailable" : "mismatched", mode)
            for key in ["displayedPrompt", "displayedPromptBytes", "displayedPromptSHA256", "statistics"] { XCTAssertNil(value[key], mode + ":" + key) }
            XCTAssertEqual(value["canonicalRequestBase64"] as? String, f.request.continuationRequest.base64EncodedString(), mode)
        }
    }

    func testOnlyCoherentBudgetFailuresCanSpendAnArmAndEachCodeRetainsOriginalUnits() throws {
        let invalid: [C.Failure] = [.invalidRequest, .groqTokenCounterUnavailable, .unsupportedWebsiteResponse,
            .groqPromptBudgetExceeded(actualTokens: 6_000, maximumTokens: 6_000, reservedTokens: 2_000),
            .groqPromptBudgetExceeded(actualTokens: 6_001, maximumTokens: 5_999, reservedTokens: 2_000),
            .groqPromptBudgetExceeded(actualTokens: 6_001, maximumTokens: 6_000, reservedTokens: 1_999),
            .groqPromptByteBudgetExceeded(actualBytes: 6_000, maximumBytes: 6_000, reservedTokens: 2_000),
            .groqPromptByteBudgetExceeded(actualBytes: 6_001, maximumBytes: 6_000, reservedTokens: 1_999),
            .promptTooLarge(actualBytes: C.maximumPromptBytes, maximumBytes: C.maximumPromptBytes),
            .promptTooLarge(actualBytes: C.maximumPromptBytes + 1, maximumBytes: C.maximumPromptBytes - 1)]
        for rejection in invalid {
            let f = try fixture(), scope = try XCTUnwrap(f.prepare()), arm = try Data(contentsOf: f.arm)
            XCTAssertFalse(scope.capture(failure: rejection, candidate: f.request, candidateFailure: rejection, isCurrent: { true }))
            XCTAssertEqual(try Data(contentsOf: f.arm), arm)
            XCTAssertFalse(f.exists(f.output))
            XCTAssertTrue(scope.capture(failure: failure, candidate: nil, candidateFailure: nil, isCurrent: { true }), "A rejected failure cannot spend eligibility")
        }
        let variants: [(C.Failure, String, String, Int, String, Int)] = [
            (failure, "website_prompt_budget_exceeded", "bodyTokens", 6_001, "maximumBodyTokens", 6_000),
            (.groqPromptByteBudgetExceeded(actualBytes: 6_001, maximumBytes: 6_000, reservedTokens: 2_000),
             "website_prompt_byte_budget_exceeded", "bodyUTF8Bytes", 6_001, "maximumBodyUTF8Bytes", 6_000),
            (.promptTooLarge(actualBytes: C.maximumPromptBytes + 1, maximumBytes: C.maximumPromptBytes),
             "input_too_large", "actualBytes", C.maximumPromptBytes + 1, "maximumBytes", C.maximumPromptBytes)]
        for (rejection, code, actualKey, actual, maximumKey, maximum) in variants {
            let f = try fixture(), scope = try XCTUnwrap(f.prepare())
            XCTAssertTrue(scope.capture(failure: rejection, candidate: nil, candidateFailure: nil, isCurrent: { true }))
            let value = try f.record()
            XCTAssertEqual(value["failureCode"] as? String, code)
            XCTAssertEqual(value[actualKey] as? Int, actual)
            XCTAssertEqual(value[maximumKey] as? Int, maximum)
            XCTAssertEqual(value["reservedTokens"] as? Int, code == "input_too_large" ? nil : 2_000)
        }
    }

    func testNativeCurrentnessRevocationAndCancellationCannotPublishOrAuthorizeReplay() async throws {
        let f = try fixture(), arm = try Data(contentsOf: f.arm)
        XCTAssertNil(Capture.prepare(directory: f.directory, context: f.context, request: f.request, now: f.now, isCurrent: { false }))
        let scope = try XCTUnwrap(f.prepare())
        // Runtime/preparation/transport identities are native-owned, not arm
        // fields. The caller must reject retirement of that exact native scope.
        XCTAssertFalse(scope.capture(failure: failure, candidate: f.request, candidateFailure: failure, isCurrent: { false }))
        XCTAssertEqual(try Data(contentsOf: f.arm), arm)
        scope.revoke(); scope.revoke()
        XCTAssertFalse(scope.capture(failure: failure, candidate: f.request, candidateFailure: failure, isCurrent: { true }))
        let cancelledScope = try XCTUnwrap(f.prepare()), rejection = failure
        let cancelled = Task { @MainActor in
            let deniedPrepare = Capture.prepare(directory: f.directory, context: f.context, request: f.request, now: f.now, isCurrent: { true }) == nil
            let deniedCapture = !cancelledScope.capture(failure: rejection, candidate: f.request, candidateFailure: rejection, isCurrent: { true })
            return (Task.isCancelled, deniedPrepare, deniedCapture)
        }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertTrue(result.0); XCTAssertTrue(result.1); XCTAssertTrue(result.2)
        XCTAssertEqual(try Data(contentsOf: f.arm), arm)
        XCTAssertFalse(f.exists(f.output))
    }

    func testReplacedArmsExistingOutputsAndConcurrentScopesCannotOverwriteOrDoublePublish() async throws {
        let replaced = try fixture(), old = try XCTUnwrap(replaced.prepare())
        var replacement = replaced.fields(); replacement["nonce"] = UUID().uuidString.lowercased()
        let replacementBytes = try encoded(replacement)
        try replaced.writeArm(replacementBytes)
        XCTAssertFalse(old.capture(failure: failure, candidate: replaced.request, candidateFailure: failure, isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: replaced.arm), replacementBytes)
        XCTAssertFalse(replaced.exists(replaced.output))
        let occupied = try fixture(), waiting = try XCTUnwrap(occupied.prepare())
        let sentinel = Data("existing private output".utf8)
        try sentinel.write(to: occupied.output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: occupied.output.path)
        XCTAssertFalse(waiting.capture(failure: failure, candidate: occupied.request, candidateFailure: failure, isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: occupied.output), sentinel)
        XCTAssertNil(occupied.prepare())
        let racing = try fixture(), first = try XCTUnwrap(racing.prepare()), second = try XCTUnwrap(racing.prepare())
        let request = racing.request, rejection = failure
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for scope in [first, second] {
                group.addTask { scope.capture(failure: rejection, candidate: request, candidateFailure: rejection, isCurrent: { true }) }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let bytes = try Data(contentsOf: racing.output)
        XCTAssertEqual(try racing.record()["candidateState"] as? String, "matched")
        XCTAssertFalse(racing.exists(racing.arm))
        XCTAssertFalse(first.capture(failure: failure, candidate: request, candidateFailure: failure, isCurrent: { true }))
        XCTAssertFalse(second.capture(failure: failure, candidate: request, candidateFailure: failure, isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: racing.output), bytes)
    }

    func testPreparedOrdinalTwoPreservesExactAdmittedPromptCanonicalBytesAndNoAuthority() throws {
        let f = try fixture(continuation: true), request = try preparedRequest(f)
        try writePreparedArm(f)
        XCTAssertTrue(request.usesNativeGroqHistoryPresentation)
        XCTAssertNotNil(request.groqToolDiscoveryDiagnostic)
        XCTAssertNil(f.prepare(), "The rejected-budget purpose cannot borrow the prepared-prompt arm")
        let scope = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: f.directory, context: f.context,
            request: request, nativeInferenceOrdinal: 2, now: f.now, isCurrent: { true }))
        XCTAssertTrue(scope.capture(isCurrent: { true }))
        let bytes = try Data(contentsOf: f.output), value = try f.record()
        XCTAssertEqual(Set(value.keys), ["version", "purpose", "stage", "nativeInferenceOrdinal", "nonce", "taskID", "threadID", "turnID",
            "runtimeGeneration", "preparationID", "transportGeneration", "inferenceID", "modelID", "userPromptSHA256",
            "submitted", "providerWireAttested", "automaticReplay", "responseAuthority", "cleanupAuthority", "dispatchAuthority",
            "canonicalRequestBase64", "canonicalRequestBytes", "canonicalRequestSHA256", "displayedPrompt", "displayedPromptBytes",
            "displayedPromptSHA256", "statistics"])
        XCTAssertEqual(value["version"] as? Int, 1)
        XCTAssertEqual(value["purpose"] as? String, GroqPreparedPromptCapture.purpose)
        XCTAssertEqual(value["stage"] as? String, "native_prepared_prompt")
        XCTAssertEqual(value["nativeInferenceOrdinal"] as? Int, 2)
        XCTAssertEqual(value["nonce"] as? String, f.nonce.uuidString.lowercased())
        for (key, id) in [("taskID", f.context.taskID), ("threadID", f.context.threadID), ("turnID", f.context.turnID),
                          ("runtimeGeneration", f.context.runtimeGeneration), ("preparationID", f.context.preparationID),
                          ("transportGeneration", f.context.transportGeneration), ("inferenceID", f.context.inferenceID)] {
            XCTAssertEqual(value[key] as? String, id.uuidString.lowercased(), key)
        }
        XCTAssertEqual(value["modelID"] as? String, Capture.modelID)
        XCTAssertEqual(value["userPromptSHA256"] as? String, GroqOwnedStatusLease.digest(f.user))
        for key in ["submitted", "providerWireAttested", "automaticReplay", "responseAuthority", "cleanupAuthority", "dispatchAuthority"] {
            XCTAssertEqual(value[key] as? Bool, false, key)
        }
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(value["canonicalRequestBase64"] as? String)), request.continuationRequest)
        XCTAssertTrue(String(decoding: request.continuationRequest, as: UTF8.self).contains(#""decimal":1.00"#))
        XCTAssertTrue(String(decoding: request.continuationRequest, as: UTF8.self).contains(#""escaped":"\u0061""#))
        XCTAssertEqual(value["canonicalRequestBytes"] as? Int, request.continuationRequest.count)
        XCTAssertEqual(value["canonicalRequestSHA256"] as? String, digest(request.continuationRequest))
        XCTAssertEqual(value["displayedPrompt"] as? String, request.prompt)
        XCTAssertEqual(value["displayedPromptBytes"] as? Int, request.prompt.utf8.count)
        XCTAssertEqual(value["displayedPromptSHA256"] as? String, GroqOwnedStatusLease.digest(request.prompt))
        XCTAssertEqual(value["statistics"] as? NSDictionary, try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.promptStatistics)) as? NSDictionary)
        XCTAssertEqual(try permissions(f.output), 0o600); XCTAssertFalse(f.exists(f.arm))
        XCTAssertFalse(scope.capture(isCurrent: { true }))
        XCTAssertNil(GroqPreparedPromptCapture.prepare(directory: f.directory, context: f.context,
            request: request, nativeInferenceOrdinal: 2, now: f.now, isCurrent: { true }))
        XCTAssertEqual(try Data(contentsOf: f.output), bytes)
    }

    func testPreparedCaptureRequiresExactOrdinalPurposeNativeProfileUserAndScopeWithoutSpendingArm() throws {
        for mode in ["ordinal_zero", "ordinal_one", "ordinal_three", "ordinal_negative", "ordinal_max", "nil_directory", "no_arm",
                     "old_purpose", "foreign_task", "foreign_thread", "foreign_turn", "context_model", "request_model", "hash", "nonfixture",
                     "legacy", "no_projection", "no_reader", "no_loader", "duplicate", "extra_key", "missing_key", "expired", "over_ttl", "not_current"] {
            let f = try fixture(user: mode == "nonfixture" ? Self.user.replacingOccurrences(of: "\n", with: " ") : Self.user,
                model: mode == "request_model" ? GroqOwnedStatusLease.Profile.gptoss20b.choice.modelID : Capture.modelID)
            let request = try preparedRequest(f, compact: mode != "legacy", projection: mode != "no_projection",
                reader: mode != "no_reader", loader: mode != "no_loader")
            var fields = f.fields(); fields["purpose"] = GroqPreparedPromptCapture.purpose
            switch mode {
            case "old_purpose": fields["purpose"] = Capture.purpose
            case "foreign_task": fields["taskID"] = UUID().uuidString.lowercased()
            case "foreign_thread": fields["threadID"] = UUID().uuidString.lowercased()
            case "foreign_turn": fields["turnID"] = UUID().uuidString.lowercased()
            case "hash": fields["userPromptSHA256"] = GroqOwnedStatusLease.digest("another user")
            case "extra_key": fields["headers"] = "not permitted"
            case "missing_key": fields.removeValue(forKey: "threadID")
            case "expired": fields = f.fields(expiresAt: f.now); fields["purpose"] = GroqPreparedPromptCapture.purpose
            case "over_ttl": fields = f.fields(expiresAt: f.now.addingTimeInterval(600.001)); fields["purpose"] = GroqPreparedPromptCapture.purpose
            default: break
            }
            if mode == "duplicate" {
                let encodedFields = String(decoding: try encoded(fields), as: UTF8.self)
                try f.writeArm(Data(("{\"purpose\":\"foreign\"," + String(encodedFields.dropFirst())).utf8))
            } else { try f.writeArm(try encoded(fields)) }
            if mode == "no_arm" { try FileManager.default.removeItem(at: f.arm) }
            let arm = try? Data(contentsOf: f.arm)
            let ordinal = ["ordinal_zero": 0, "ordinal_one": 1, "ordinal_three": 3, "ordinal_negative": -1, "ordinal_max": Int.max][mode] ?? 2
            let context = mode == "context_model" ? f.contextWithModel(GroqOwnedStatusLease.Profile.gptoss20b.choice.modelID) : f.context
            XCTAssertNil(GroqPreparedPromptCapture.prepare(directory: mode == "nil_directory" ? nil : f.directory,
                context: context, request: request, nativeInferenceOrdinal: ordinal, now: f.now,
                isCurrent: { mode != "not_current" }), mode)
            XCTAssertEqual(try? Data(contentsOf: f.arm), arm, mode)
            XCTAssertFalse(f.exists(f.output), mode)
        }
        let boundary = try fixture(); try writePreparedArm(boundary, expiresAt: boundary.now.addingTimeInterval(600))
        XCTAssertNotNil(GroqPreparedPromptCapture.prepare(directory: boundary.directory, context: boundary.context,
            request: try preparedRequest(boundary), nativeInferenceOrdinal: 2, now: boundary.now, isCurrent: { true }))
    }

    func testPreparedScopeCurrentnessExpiryRevocationCancellationAndAtomicOutputRemainOneShot() async throws {
        let f = try fixture(); try writePreparedArm(f)
        let request = try preparedRequest(f), arm = try Data(contentsOf: f.arm)
        let scope = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: f.directory, context: f.context,
            request: request, nativeInferenceOrdinal: 2, now: f.now, isCurrent: { true }))
        XCTAssertFalse(scope.capture(isCurrent: { false })); XCTAssertEqual(try Data(contentsOf: f.arm), arm)
        scope.revoke(); scope.revoke(); XCTAssertFalse(scope.capture(isCurrent: { true }))
        let cancelledScope = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: f.directory, context: f.context,
            request: request, nativeInferenceOrdinal: 2, now: f.now, isCurrent: { true }))
        let cancelled = Task { @MainActor in
            let rejectedPrepare = GroqPreparedPromptCapture.prepare(directory: f.directory, context: f.context,
                request: request, nativeInferenceOrdinal: 2, now: f.now, isCurrent: { true }) == nil
            return (Task.isCancelled, rejectedPrepare, !cancelledScope.capture(isCurrent: { true }))
        }
        cancelled.cancel(); let cancelledResult = await cancelled.value
        XCTAssertTrue(cancelledResult.0); XCTAssertTrue(cancelledResult.1); XCTAssertTrue(cancelledResult.2)
        XCTAssertEqual(try Data(contentsOf: f.arm), arm); XCTAssertFalse(f.exists(f.output))
        let expiry = try fixture(); try writePreparedArm(expiry, expiresAt: expiry.now.addingTimeInterval(0.05))
        let expiring = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: expiry.directory, context: expiry.context,
            request: try preparedRequest(expiry), nativeInferenceOrdinal: 2, now: expiry.now, isCurrent: { true }))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(expiring.capture(isCurrent: { true })); XCTAssertTrue(expiry.exists(expiry.arm)); XCTAssertFalse(expiry.exists(expiry.output))
        let occupied = try fixture(); try writePreparedArm(occupied)
        let waiting = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: occupied.directory, context: occupied.context,
            request: try preparedRequest(occupied), nativeInferenceOrdinal: 2, now: occupied.now, isCurrent: { true }))
        let sentinel = Data("existing private output".utf8); try sentinel.write(to: occupied.output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: occupied.output.path)
        XCTAssertFalse(waiting.capture(isCurrent: { true })); XCTAssertEqual(try Data(contentsOf: occupied.output), sentinel)
        let replaced = try fixture(); try writePreparedArm(replaced)
        let old = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: replaced.directory, context: replaced.context,
            request: try preparedRequest(replaced), nativeInferenceOrdinal: 2, now: replaced.now, isCurrent: { true }))
        var changed = replaced.fields(); changed["purpose"] = GroqPreparedPromptCapture.purpose; changed["nonce"] = UUID().uuidString.lowercased()
        let changedBytes = try encoded(changed); try replaced.writeArm(changedBytes)
        XCTAssertFalse(old.capture(isCurrent: { true })); XCTAssertEqual(try Data(contentsOf: replaced.arm), changedBytes)
        XCTAssertFalse(replaced.exists(replaced.output))
        let racing = try fixture(); try writePreparedArm(racing)
        let racingRequest = try preparedRequest(racing)
        let first = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: racing.directory, context: racing.context,
            request: racingRequest, nativeInferenceOrdinal: 2, now: racing.now, isCurrent: { true }))
        let second = try XCTUnwrap(GroqPreparedPromptCapture.prepare(directory: racing.directory, context: racing.context,
            request: racingRequest, nativeInferenceOrdinal: 2, now: racing.now, isCurrent: { true }))
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for candidate in [first, second] { group.addTask { candidate.capture(isCurrent: { true }) } }
            var results: [Bool] = []; for await result in group { results.append(result) }; return results
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(try racing.record()["stage"] as? String, "native_prepared_prompt")
        XCTAssertFalse(racing.exists(racing.arm)); XCTAssertFalse(first.capture(isCurrent: { true })); XCTAssertFalse(second.capture(isCurrent: { true }))
    }

    private func writePreparedArm(_ fixture: Fixture, expiresAt: Date? = nil) throws {
        var fields = fixture.fields(expiresAt: expiresAt); fields["purpose"] = GroqPreparedPromptCapture.purpose
        try fixture.writeArm(try encoded(fields))
    }
    private func preparedRequest(_ fixture: Fixture, compact: Bool = true, projection: Bool = true,
                                 reader: Bool = true, loader: Bool = true) throws -> C.Request {
        let original = fixture.request.continuationRequest
        let layout = try GroqContextJSONLayout.parse(original), range = try XCTUnwrap(layout.toolsRange)
        var tools: [[String: Any]] = []
        for definition in (loader ? [GroqToolCatalog.specification] : []) + (reader ? [GroqHistoryTool.specification] : []) {
            var wire = definition; wire["parameters"] = wire.removeValue(forKey: "inputSchema"); tools.append(wire)
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        tools += try XCTUnwrap(root["tools"] as? [[String: Any]])
        var raw = original; raw.replaceSubrange(range, with: try encoded(tools))
        let initial = try C.prepareRequest(raw)
        guard projection, let seed = initial.groqToolCatalogSeed else { return try C.prepareRequest(raw, compactHistoryInventory: compact) }
        return try C.prepareRequest(raw, groqToolCatalogProjection: GroqToolCatalog.baseline(for: seed),
            groqDirectTools: .loadedOnly, compactHistoryInventory: compact)
    }

    private struct Fixture {
        let directory: URL, context: Capture.Context, request: C.Request, user: String, now: Date, nonce: UUID
        var arm: URL { directory.appendingPathComponent("arm.json") }
        var output: URL { directory.appendingPathComponent("request.json") }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func fields(expiresAt: Date? = nil) -> [String: Any] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            return ["schemaVersion": 1, "purpose": Capture.purpose, "nonce": nonce.uuidString.lowercased(),
                "taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(),
                "turnID": context.turnID.uuidString.lowercased(), "modelID": Capture.modelID,
                "userPromptSHA256": GroqOwnedStatusLease.digest(user), "expiresAt": formatter.string(from: expiresAt ?? now.addingTimeInterval(60))]
        }
        func writeArm(_ bytes: Data) throws {
            try bytes.write(to: arm)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: arm.path)
        }
        func prepare() -> Capture.Scope? { Capture.prepare(directory: directory, context: context, request: request, now: now, isCurrent: { true }) }
        func record() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]) }
        func contextWithModel(_ model: String) -> Capture.Context {
            .init(taskID: context.taskID, threadID: context.threadID, turnID: context.turnID, runtimeGeneration: context.runtimeGeneration,
                preparationID: context.preparationID, transportGeneration: context.transportGeneration, inferenceID: context.inferenceID, modelID: model)
        }
    }

    private func fixture(user suppliedUser: String? = nil, model: String = Capture.modelID, continuation: Bool = false) throws -> Fixture {
        let user = suppliedUser ?? Self.user
        let directory = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("groq-rejected-request-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let context = Capture.Context(taskID: UUID(uuidString: "01234567-89AB-4CDE-8FAB-0123456789AB")!, threadID: UUID(), turnID: UUID(),
            runtimeGeneration: UUID(), preparationID: UUID(), transportGeneration: UUID(), inferenceID: UUID(), modelID: Capture.modelID)
        let f = Fixture(directory: directory, context: context, request: try request(user: user, model: model, continuation: continuation),
            user: user, now: Date(timeIntervalSince1970: 1_800_000_000), nonce: UUID())
        try f.writeArm(try encoded(f.fields()))
        return f
    }
    private func request(user: String, model: String = Capture.modelID, stream: Bool = false, continuation: Bool = false) throws -> C.Request {
        func item(_ role: String, _ text: String) -> [String: Any] { ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]] }
        var input = [item("developer", "Synthetic policy"), item("user", "<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
            item("user", user + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy())]
        if continuation {
            input += [["type": "function_call", "call_id": "call_fixture", "name": "fixture_read", "arguments": #"{"path":"README"}"#],
                      ["type": "function_call_output", "call_id": "call_fixture", "output": "Synthetic read: \\ quoted é"]]
        }
        let base = try encoded(["model": model, "stream": stream, "input": input,
            "tools": [["type": "function", "name": "fixture_read", "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false]]]])
        let lexical = Data(("{\n\"retained_fixture_data\":{\"escaped\":\"\\u0061\",\"decimal\":1.00},\n" + String(decoding: base.dropFirst(), as: UTF8.self)).utf8)
        return try C.prepareRequest(lexical)
    }
    private func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func digest(_ data: Data) -> String { GroqOwnedStatusLease.digest(String(decoding: data, as: UTF8.self)) }
    private func permissions(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
    private static let user = """
    In /tmp/diagnostic/fixtures/cases/invoice-487-groq-gptoss120b-0123456789abcdef/coding, fix the invoice aggregation bug in reconcile.py according to its README. Keep the tests, sample data, and reference format unchanged. Run python3 -m unittest -v, then run python3 reconcile.py.

    Use the built-in browser to open http://127.0.0.1:50473/, enter the printed reference, and submit it once. Read the resulting receipt, then close the tab you opened. Use browser tools for the website; do not use terminal HTTP requests or inspect the fixture's control directory, server source, or receipt files.

    Return the test result, the reference, and the receipt shown by the page.
    """
}
