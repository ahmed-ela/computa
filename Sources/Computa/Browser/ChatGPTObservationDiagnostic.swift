import CoreFoundation
import CryptoKit
import Foundation

/// Optional synthetic measurements. Removing this field is unconditional;
/// accepting, rejecting or logging its contents never supplies page authority.
enum ChatGPTObservationDiagnostic {
    static let resultKey = "observationDiagnostic"
    enum Phase: String, Hashable { case early, firstText = "first_text", terminal }
    struct Snapshot {
        let data: Data
        let phase: Phase?
    }
    struct Log {
        let records: [String]
    }
    struct LogBudget {
        private var phases: Set<Phase> = []

        mutating func consume(_ snapshot: Snapshot,
                              binding: WebsiteBenchmarkCaptureLease.ObservationBinding,
                              sessionToken: String, sequence: Int) -> Log? {
            guard sequence == 1, let phase = snapshot.phase, phases.count < 3, !phases.contains(phase),
                  let session = UUID(uuidString: sessionToken),
                  session.uuidString.lowercased() == sessionToken.lowercased(),
                  !snapshot.data.isEmpty, snapshot.data.count <= 4_096 else { return nil }
            let chunks = stride(from: 0, to: snapshot.data.count, by: 512).map {
                snapshot.data.subdata(in: $0..<min($0 + 512, snapshot.data.count)).base64EncodedString()
            }
            guard (1...8).contains(chunks.count) else { return nil }
            let digest = SHA256.hash(data: snapshot.data).map { String(format: "%02x", $0) }.joined()
            let nonce = binding.nonce.uuidString.lowercased(), identifier = session.uuidString.lowercased()
            let ordinal = phases.count + 1
            let records = chunks.enumerated().map { index, chunk in
                "observationDiagnosticChunk version=1 nonce=\(nonce) sessionID=\(identifier) sequence=1 phase=\(phase.rawValue) snapshot=\(ordinal) part=\(index + 1) parts=\(chunks.count) sha256=\(digest) base64=\(chunk)"
            }
            guard records.allSatisfy({ $0.utf8.count <= 960 }) else { return nil }
            phases.insert(phase)
            return Log(records: records)
        }
    }

    static func remove(from observation: inout [String: Any],
                       binding: WebsiteBenchmarkCaptureLease.ObservationBinding?) -> Snapshot? {
        let raw = observation.removeValue(forKey: resultKey)
        guard let binding, let value = raw as? [String: Any] else { return nil }
        let fields: Set<String> = ["schemaVersion", "revision", "binding", "diagnosticOnly", "modelProofRequiredExternally",
            "installedUnixMs", "sendUnixMs", "ownClickAfterInstallMs", "invalidReason", "endedReason", "stopped", "expired",
            "sourceProbeSendObserved", "payloadBindingVerified", "sourceProbeCurrentComplete", "clickIsTrusted", "userCount",
            "assistantCount", "firstModernBodyAfterSendMs", "firstRawTextAfterSendMs", "firstRawTextUTF16Length",
            "firstRawTextCountClamped", "callbacks", "mutationCallbacks", "mutationRecords", "timerIntervals",
            "rafEarlyIntervals", "rafBodyIntervals", "visibilityFocus", "resourceSummary"]
        guard value.count == fields.count, Set(value.keys) == fields,
              integer(value["schemaVersion"], upper: 1) == 1, integer(value["revision"], upper: 1) == 1,
              boolean(value["diagnosticOnly"]) == true, boolean(value["modelProofRequiredExternally"]) == true,
              let supplied = value["binding"] as? [String: Any], supplied.count == 5,
              Set(supplied.keys) == ["schemaVersion", "nonce", "expectedSHA256", "expectedCanonicalSHA256", "expectedUTF8Bytes"],
              integer(supplied["schemaVersion"], upper: 1) == 1,
              supplied["nonce"] as? String == binding.nonce.uuidString.lowercased(),
              supplied["expectedSHA256"] as? String == binding.rawOutboundSHA,
              supplied["expectedCanonicalSHA256"] as? String == binding.canonicalOutboundSHA,
              integer(supplied["expectedUTF8Bytes"], upper: 180_200) == binding.utf8Bytes,
              (1...180_200).contains(binding.utf8Bytes),
              binding.rawOutboundSHA.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              binding.canonicalOutboundSHA.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let reason = value["invalidReason"] as? String,
              ["none", "document_or_origin_changed", "native_owner_changed", "physical_root_removed", "source_probe_changed",
               "source_probe_unreadable", "source_probe_invalid", "physical_count_invalid", "physical_root_changed",
               "modern_body_count_or_scope", "modern_body_removed", "modern_body_changed", "multiple_send_clicks",
               "not_fresh_at_send", "source_send_not_observed", "physical_lease_removed", "not_fresh_before_send"].contains(reason),
              let ended = value["endedReason"] as? String,
              ["none", "explicit_stop", "deadline", "pagehide", "invalid", "callback_budget", "record_budget"].contains(ended),
              let stopped = boolean(value["stopped"]), let expired = boolean(value["expired"]),
              stopped == (ended != "none"), expired == (ended == "deadline"),
              let sent = boolean(value["sourceProbeSendObserved"]),
              let payload = boolean(value["payloadBindingVerified"]),
              boolean(value["sourceProbeCurrentComplete"]) != nil,
              boolean(value["firstRawTextCountClamped"]) != nil,
              nullableBoolean(value["clickIsTrusted"]),
              integer(value["installedUnixMs"], upper: 9_007_199_254_740_991) != nil,
              nullableInteger(value["sendUnixMs"], upper: 9_007_199_254_740_991),
              integer(value["userCount"], upper: 1) != nil, integer(value["assistantCount"], upper: 1) != nil,
              integer(value["callbacks"], upper: 256) != nil, integer(value["mutationCallbacks"], upper: 128) != nil,
              integer(value["mutationRecords"], upper: 1_025) != nil,
              nullableInteger(value["firstRawTextUTF16Length"], upper: 220_001) else { return nil }
        for key in ["ownClickAfterInstallMs", "firstModernBodyAfterSendMs", "firstRawTextAfterSendMs"] {
            guard nullableNumber(value[key], lower: 0, upper: 15_000) else { return nil }
        }
        if sent {
            guard integer(value["sendUnixMs"], upper: 9_007_199_254_740_991) != nil,
                  !(value["ownClickAfterInstallMs"] is NSNull), boolean(value["clickIsTrusted"]) != nil else { return nil }
        } else {
            guard value["sendUnixMs"] is NSNull, value["ownClickAfterInstallMs"] is NSNull,
                  value["clickIsTrusted"] is NSNull, !payload else { return nil }
        }
        if payload {
            guard sent, reason == "none", integer(value["userCount"], upper: 1) == 1,
                  integer(value["assistantCount"], upper: 1) == 1 else { return nil }
        }
        let hasText = !(value["firstRawTextAfterSendMs"] is NSNull)
        guard hasText == !(value["firstRawTextUTF16Length"] is NSNull),
              !hasText || integer(value["firstRawTextUTF16Length"], upper: 220_001).map({ $0 > 0 }) == true,
              boolean(value["firstRawTextCountClamped"]) != true || integer(value["firstRawTextUTF16Length"], upper: 220_001) == 220_001,
              timingTuples(value["timerIntervals"], maximum: 12), timingTuples(value["rafEarlyIntervals"], maximum: 8),
              timingTuples(value["rafBodyIntervals"], maximum: 8), focusTuples(value["visibilityFocus"]),
              resourceSummary(value["resourceSummary"]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              !data.isEmpty, data.count <= 4_096, data.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        return Snapshot(data: data, phase: stopped ? .terminal : hasText ? .firstText : sent ? .early : nil)
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func number(_ raw: Any?, lower: Double = 0, upper: Double) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (lower...upper).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
    private static func integer(_ raw: Any?, upper: Int) -> Int? {
        guard let value = number(raw, upper: Double(upper)), value.rounded() == value else { return nil }
        return Int(value)
    }
    private static func nullableBoolean(_ raw: Any?) -> Bool { raw is NSNull || boolean(raw) != nil }
    private static func nullableInteger(_ raw: Any?, upper: Int) -> Bool { raw is NSNull || integer(raw, upper: upper) != nil }
    private static func nullableNumber(_ raw: Any?, lower: Double, upper: Double) -> Bool { raw is NSNull || number(raw, lower: lower, upper: upper) != nil }
    private static func timingTuples(_ raw: Any?, maximum: Int) -> Bool {
        guard let tuples = raw as? [[Any]], tuples.count <= maximum else { return false }
        var previous = 0.0
        for tuple in tuples {
            guard tuple.count == 2, let after = number(tuple[0], upper: 15_000), after >= previous,
                  number(tuple[1], upper: 15_000) != nil else { return false }
            previous = after
        }
        return true
    }
    private static func focusTuples(_ raw: Any?) -> Bool {
        guard let tuples = raw as? [[Any]], tuples.count <= 4 else { return false }
        var phases: Set<String> = []
        for tuple in tuples {
            guard tuple.count == 4, let phase = tuple[0] as? String, ["install", "send", "body", "end"].contains(phase),
                  phases.insert(phase).inserted, nullableNumber(tuple[1], lower: 0, upper: 15_000),
                  let visibility = tuple[2] as? String, ["visible", "hidden", "prerender", "unknown"].contains(visibility),
                  nullableBoolean(tuple[3]) else { return false }
        }
        return true
    }
    private static func resourceSummary(_ raw: Any?) -> Bool {
        if raw is NSNull { return true }
        guard let value = raw as? [String: Any], Set(value.keys) == ["scannedCount", "scanTruncated", "selectedCount", "selectedTruncated", "available", "entries"],
              let scanned = integer(value["scannedCount"], upper: 256), let selected = integer(value["selectedCount"], upper: 256), selected <= scanned,
              let scanTruncated = boolean(value["scanTruncated"]), !scanTruncated || scanned == 256,
              boolean(value["selectedTruncated"]) == (selected > 8), boolean(value["available"]) != nil,
              let entries = value["entries"] as? [[Any]], entries.count == min(selected, 8) else { return false }
        for entry in entries {
            guard entry.count == 6, nullableNumber(entry[0], lower: -15_000, upper: 15_000),
                  nullableNumber(entry[1], lower: 0, upper: 15_000), nullableNumber(entry[2], lower: 0, upper: 15_000),
                  entry[3...5].allSatisfy({ nullableInteger($0, upper: 1_073_741_824) }) else { return false }
            if let start = number(entry[0], lower: -15_000, upper: 15_000), let end = number(entry[1], upper: 15_000), end < max(0, start) { return false }
        }
        return true
    }
}
