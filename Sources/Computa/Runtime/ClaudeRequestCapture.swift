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
                      value["purpose"] as? String == purpose,
                      let nonce = canonicalID(value["nonce"]),
                      value["taskID"] as? String == context.taskID.uuidString.lowercased(),
                      value["turnID"] as? String == context.turnID.uuidString.lowercased(),
                      value["modelID"] as? String == context.modelID,
                      value["trigger"] as? String == "after_browser_tabs",
                      let expiryText = value["expiresAt"] as? String, expiryText.utf8.count == 24,
                      let expiry = timestampFormatter().date(from: expiryText),
                      timestampFormatter().string(from: expiry) == expiryText,
                      expiry > now, expiry.timeIntervalSince(now) <= maximumLifetime else { return nil }
                // Default-disabled and mismatched arms do not parse history,
                // re-encode the catalog or allocate a raw diagnostic payload.
                guard let canonical = String(data: request.continuationRequest, encoding: .utf8),
                      let callID = postBrowserTabsCallID(request.continuationRequest),
                      let catalogData = try? catalogEncoder().encode(request.toolCatalogDiagnostic),
                      let catalog = try? JSONSerialization.jsonObject(with: catalogData) else { return nil }
                // Monotonic elapsed time prevents an expiry extension while the
                // synchronous file claim/write is in flight, including clock changes.
                deadline = started + .milliseconds(Int64(expiry.timeIntervalSince(now) * 1_000))
                let record: [String: Any] = [
                    "schemaVersion": 1, "purpose": purpose, "stage": "pre_send",
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
                    "trigger": "after_browser_tabs", "triggerCallID": callID,
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
    private static func postBrowserTabsCallID(_ data: Data) -> String? {
        guard APIModelCorrectionJSON.isUnambiguous(data),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = value["input"] as? [[String: Any]], input.count >= 2,
              let output = input.last, output["type"] as? String == "function_call_output",
              let callID = output["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 256,
              output["output"] is String || output["output"] is [[String: Any]] else { return nil }
        let call = input[input.count - 2]
        guard call["type"] as? String == "function_call", call["name"] as? String == "browser_tabs",
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
