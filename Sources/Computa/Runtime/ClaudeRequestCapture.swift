import CryptoKit
import Foundation

/// A private, explicitly armed diagnostic snapshot before one Claude Send.
/// This is not a submission receipt, a replay instruction or provider authority.
/// The arm is an operator convention, not authentication against the same UID.
enum ClaudeRequestCapture {
    static let directoryName = "ClaudeRequestDiagnostics-v1"
    static let purpose = "claude_post_browser_tabs_request_v1"
    static let maximumLifetime: TimeInterval = 600
    static let maximumRecordBytes = WebModelResponseCodec.maximumPromptBytes * 12 + 8_192

    private enum Trigger: String {
        case afterBrowserTabs = "after_browser_tabs"
        case afterBrowserFill = "after_browser_fill"

        var callName: String { self == .afterBrowserTabs ? "browser_tabs" : "browser_fill" }
        var purpose: String { "claude_post_\(callName)_request_v1" }
    }

    struct Context: Sendable {
        let taskID: UUID
        let threadID: UUID
        let turnID: UUID
        let runtimeGeneration: UUID
        let preparationID: UUID
        let inferenceID: UUID
        let sessionToken: UUID
        let modelID: String
    }

    @TaskLocal static var firstRequest: FirstRequestScope?
    static let firstRequestPurpose = "claude_synthetic_first_request_v2"
    static let firstRequestModel = WebsiteModelChoice(provider: "claude", key: "Opus 5", label: "Opus 5").modelID

    static func syntheticUserText(nonce: UUID) -> String {
        "Computa latency benchmark \(nonce.uuidString.lowercased()). Reply with exactly HI. Do not use tools."
    }

    /// Carries native metadata to the actual before-insert boundary. It grants
    /// no focus, page access, submission proof, response or replay capability.
    final class FirstRequestScope: @unchecked Sendable {
        private let directory: URL
        private let context: Context
        private let request: WebModelResponseCodec.Request
        private let serverPrompt: String
        private let lock = NSLock()
        private var active = true
        private var attempted = false

        init?(directory: URL?, context: Context, request: WebModelResponseCodec.Request, prompt: String,
              isNewThread: Bool, isMaintenance: Bool, isFirstInference: Bool) {
            guard !Task.isCancelled, isNewThread, !isMaintenance, isFirstInference, let directory,
                  context.modelID == firstRequestModel, request.model == context.modelID,
                  !prompt.isEmpty, prompt.utf8.count <= WebModelResponseCodec.maximumPromptBytes,
                  !request.continuationRequest.isEmpty,
                  request.continuationRequest.count <= WebModelResponseCodec.maximumPromptBytes else { return nil }
            self.directory = directory; self.context = context; self.request = request; serverPrompt = prompt
        }

        func revoke() { lock.withLock { active = false } }
        private var isCurrent: Bool { lock.withLock { active } }

        @discardableResult
        func capture(prompt: String, outbound: String, modelID: String, sessionToken: String,
                     documentGeneration: UUID, marker: String, nativeFirstFresh: Bool, now: Date = Date()) -> Bool {
            capture(prompt: prompt, outbound: outbound, modelID: modelID, sessionToken: sessionToken,
                documentGeneration: documentGeneration, marker: marker, nativeFirstFresh: nativeFirstFresh,
                now: now, beforeArmClaim: nil)
        }

        #if DEBUG
        func capture(prompt: String, outbound: String, modelID: String, sessionToken: String,
                     documentGeneration: UUID, marker: String, nativeFirstFresh: Bool, now: Date,
                     beforeArmClaimForTesting: @escaping @Sendable () -> Void) -> Bool {
            capture(prompt: prompt, outbound: outbound, modelID: modelID, sessionToken: sessionToken,
                documentGeneration: documentGeneration, marker: marker, nativeFirstFresh: nativeFirstFresh,
                now: now, beforeArmClaim: beforeArmClaimForTesting)
        }
        #endif

        private func capture(prompt: String, outbound: String, modelID: String, sessionToken: String,
                             documentGeneration: UUID, marker: String, nativeFirstFresh: Bool, now: Date,
                             beforeArmClaim: (@Sendable () -> Void)?) -> Bool {
            let started = ContinuousClock.now
            guard !Task.isCancelled, nativeFirstFresh, modelID == context.modelID,
                  UUID(uuidString: sessionToken) == context.sessionToken,
                  marker.utf8.count == 36, UUID(uuidString: marker) != nil,
                  prompt.utf8.elementsEqual(serverPrompt.utf8),
                  outbound.utf8.count <= WebsiteBenchmarkCaptureLease.maximumPayloadBytes,
                  outbound.utf8.elementsEqual((prompt + "\n\nComputa session marker: " + marker).utf8),
                  lock.withLock({
                      guard active, !attempted else { return false }
                      attempted = true; return true
                  }) else { return false }
            var deadline: ContinuousClock.Instant?
            return WebsitePrivateDiagnosticCapture.publish(directory: directory, outputName: "request.json",
                maximumArmBytes: 4_096, maximumRecordBytes: 2_000_000,
                makeRecord: { arm in
                    guard APIModelCorrectionJSON.isUnambiguous(arm),
                          let value = try? JSONSerialization.jsonObject(with: arm) as? [String: Any],
                          Set(value.keys) == ["schemaVersion", "purpose", "nonce", "taskID", "turnID", "modelID", "trigger", "expiresAt", "userPromptSHA256"],
                          ComputerToolArgumentContract.exactInt64(value["schemaVersion"]) == 2,
                          value["purpose"] as? String == firstRequestPurpose,
                          value["trigger"] as? String == "first_user_request",
                          let nonce = canonicalID(value["nonce"]),
                          value["taskID"] as? String == context.taskID.uuidString.lowercased(),
                          value["turnID"] as? String == context.turnID.uuidString.lowercased(),
                          value["modelID"] as? String == context.modelID,
                          let expiryText = value["expiresAt"] as? String, expiryText.utf8.count == 24,
                          let expiry = timestampFormatter().date(from: expiryText),
                          timestampFormatter().string(from: expiry) == expiryText,
                          expiry > now, expiry.timeIntervalSince(now) <= maximumLifetime else { return nil }
                    let expected = syntheticUserText(nonce: nonce)
                    guard value["userPromptSHA256"] as? String == sha256(Data(expected.utf8)),
                          WebsiteSyntheticFirstRequest.matches(request, expectedUserText: expected),
                          let canonical = String(data: request.continuationRequest, encoding: .utf8),
                          let catalogData = try? catalogEncoder().encode(request.toolCatalogDiagnostic),
                          let catalog = try? JSONSerialization.jsonObject(with: catalogData) else { return nil }
                    deadline = started + .milliseconds(Int64(expiry.timeIntervalSince(now) * 1_000))
                    let record: [String: Any] = [
                        "schemaVersion": 2, "purpose": firstRequestPurpose, "trigger": "first_user_request",
                        "stage": "before_insert", "submissionVerified": false, "automaticReplay": false,
                        "nonce": nonce.uuidString.lowercased(), "expiresAt": expiryText,
                        "capturedAt": timestampFormatter().string(from: now), "provider": "claude",
                        "taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(),
                        "turnID": context.turnID.uuidString.lowercased(), "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(),
                        "preparationID": context.preparationID.uuidString.lowercased(), "inferenceID": context.inferenceID.uuidString.lowercased(),
                        "sessionToken": context.sessionToken.uuidString.lowercased(), "modelID": context.modelID,
                        "documentGeneration": documentGeneration.uuidString.lowercased(), "marker": marker,
                        "userPromptSHA256": sha256(Data(expected.utf8)),
                        "canonicalRequest": canonical, "canonicalRequestSHA256": sha256(request.continuationRequest),
                        "canonicalRequestUTF8Bytes": request.continuationRequest.count,
                        "serverPrompt": prompt, "serverPromptSHA256": sha256(Data(prompt.utf8)), "serverPromptUTF8Bytes": prompt.utf8.count,
                        "outbound": outbound, "outboundSHA256": sha256(Data(outbound.utf8)),
                        "outboundCanonicalSHA256": EmbeddedWebModelTransport.outboundFingerprint(outbound),
                        "outboundUTF8Bytes": outbound.utf8.count, "outboundUTF16Count": outbound.utf16.count,
                        "toolCatalog": catalog, "toolCatalogSHA256": sha256(catalogData),
                    ]
                    return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
                }, isCurrent: { !Task.isCancelled && self.isCurrent && deadline.map { ContinuousClock.now < $0 } == true },
                beforeArmClaim: beforeArmClaim)
        }
    }

    @discardableResult
    static func capture(directory: URL?, context: Context, request: WebModelResponseCodec.Request,
                        prompt: String, now: Date = Date()) -> Bool {
        capture(directory: directory, context: context, request: request, prompt: prompt,
                now: now, beforeArmClaim: nil)
    }

    #if DEBUG
    static func capture(directory: URL?, context: Context, request: WebModelResponseCodec.Request,
                        prompt: String, now: Date, beforeArmClaimForTesting: @escaping @Sendable () -> Void) -> Bool {
        capture(directory: directory, context: context, request: request, prompt: prompt,
                now: now, beforeArmClaim: beforeArmClaimForTesting)
    }
    #endif

    private static func capture(directory: URL?, context: Context, request: WebModelResponseCodec.Request,
                                prompt: String, now: Date, beforeArmClaim: (@Sendable () -> Void)?) -> Bool {
        let started = ContinuousClock.now
        guard !Task.isCancelled, let directory, context.modelID == request.model,
              let selection = WebsiteModelCatalog.inferenceSelection(for: request.model),
              selection.provider == "claude", selection.choice != nil,
              request.model.utf8.count <= 2_048,
              !prompt.isEmpty, prompt.utf8.count <= WebModelResponseCodec.maximumPromptBytes,
              !request.continuationRequest.isEmpty,
              request.continuationRequest.count <= WebModelResponseCodec.maximumPromptBytes else { return false }
        var deadline: ContinuousClock.Instant?
        return WebsitePrivateDiagnosticCapture.publish(directory: directory, outputName: "request.json",
            maximumArmBytes: 4_096, maximumRecordBytes: maximumRecordBytes,
            makeRecord: { arm in
                guard APIModelCorrectionJSON.isUnambiguous(arm),
                      let value = try? JSONSerialization.jsonObject(with: arm) as? [String: Any],
                      Set(value.keys) == ["schemaVersion", "purpose", "nonce", "taskID", "turnID", "modelID", "trigger", "expiresAt"],
                      ComputerToolArgumentContract.exactInt64(value["schemaVersion"]) == 1,
                      let triggerText = value["trigger"] as? String,
                      let trigger = Trigger(rawValue: triggerText),
                      value["purpose"] as? String == trigger.purpose,
                      let nonce = canonicalID(value["nonce"]),
                      value["taskID"] as? String == context.taskID.uuidString.lowercased(),
                      value["turnID"] as? String == context.turnID.uuidString.lowercased(),
                      value["modelID"] as? String == context.modelID,
                      let expiryText = value["expiresAt"] as? String, expiryText.utf8.count == 24,
                      let expiry = timestampFormatter().date(from: expiryText),
                      timestampFormatter().string(from: expiry) == expiryText,
                      expiry > now, expiry.timeIntervalSince(now) <= maximumLifetime else { return nil }
                // Default-disabled and mismatched arms do not parse history,
                // re-encode the catalog or allocate a raw diagnostic payload.
                guard let canonical = String(data: request.continuationRequest, encoding: .utf8),
                      let callID = precedingCallID(request.continuationRequest, trigger: trigger),
                      let catalogData = try? catalogEncoder().encode(request.toolCatalogDiagnostic),
                      let catalog = try? JSONSerialization.jsonObject(with: catalogData) else { return nil }
                // Monotonic elapsed time prevents an expiry extension while the
                // synchronous file claim/write is in flight, including clock changes.
                deadline = started + .milliseconds(Int64(expiry.timeIntervalSince(now) * 1_000))
                let record: [String: Any] = [
                    "schemaVersion": 1, "purpose": trigger.purpose, "stage": "pre_send",
                    "submissionVerified": false, "automaticReplay": false,
                    "nonce": nonce.uuidString.lowercased(), "expiresAt": expiryText,
                    "capturedAt": timestampFormatter().string(from: now), "provider": "claude",
                    "taskID": context.taskID.uuidString.lowercased(),
                    "threadID": context.threadID.uuidString.lowercased(),
                    "turnID": context.turnID.uuidString.lowercased(),
                    "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(),
                    "preparationID": context.preparationID.uuidString.lowercased(),
                    "inferenceID": context.inferenceID.uuidString.lowercased(),
                    "sessionToken": context.sessionToken.uuidString.lowercased(), "modelID": context.modelID,
                    "trigger": trigger.rawValue, "triggerCallID": callID,
                    "canonicalRequest": canonical,
                    "canonicalRequestSHA256": sha256(request.continuationRequest),
                    "canonicalRequestUTF8Bytes": request.continuationRequest.count,
                    "prompt": prompt, "promptSHA256": sha256(Data(prompt.utf8)),
                    "promptUTF8Bytes": prompt.utf8.count, "toolCatalog": catalog,
                    "toolCatalogSHA256": sha256(catalogData),
                ]
                return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
            }, isCurrent: { !Task.isCancelled && deadline.map { ContinuousClock.now < $0 } == true },
            beforeArmClaim: beforeArmClaim)
    }

    /// Select only the immediate native call/output suffix. Historical mentions,
    /// duplicated call IDs, later input and parallel/intervening calls cannot
    /// claim the arm. This is diagnostic selection, never execution evidence.
    private static func precedingCallID(_ data: Data, trigger: Trigger) -> String? {
        guard APIModelCorrectionJSON.isUnambiguous(data),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = value["input"] as? [[String: Any]], input.count >= 2,
              let output = input.last, output["type"] as? String == "function_call_output",
              let callID = output["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 256,
              output["output"] is String || output["output"] is [[String: Any]] else { return nil }
        let call = input[input.count - 2]
        guard call["type"] as? String == "function_call", call["name"] as? String == trigger.callName,
              call["call_id"] as? String == callID,
              input.filter({ $0["call_id"] as? String == callID }).count == 2 else { return nil }
        return callID
    }

    private static func canonicalID(_ value: Any?) -> UUID? {
        guard let text = value as? String, let id = UUID(uuidString: text), text == id.uuidString.lowercased() else { return nil }
        return id
    }
    private static func catalogEncoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
