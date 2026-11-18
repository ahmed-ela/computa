import Darwin
import Foundation
import XCTest
@testable import Computa

final class WebsiteAdapterFailureDiagnosticTests: XCTestCase {
    private typealias D = WebsiteAdapterFailureDiagnostic

    func testThreeProviderPacketsAreFiniteAndOnlyMatchTheirOriginalFailure() throws {
        for provider in ["kimi", "qwen", "deepseek"] {
            let packet = WebsiteAdapterFailureFixture.packet(provider)
            let error = provider == "qwen" ? "conversation_changed" : "unsupported_response_format"
            let detail = provider == "kimi" ? "authored_source_markdown_count" : provider == "qwen" ? "first_user_message" : "authored_source"
            let safe = try XCTUnwrap(D.sanitize(packet, provider: provider, error: error, detail: detail))
            XCTAssertLessThan(safe.data.count, D.maximumPacketBytes)
            XCTAssertNil(D.sanitize(packet, provider: provider, error: "model_unverified", detail: detail))
            XCTAssertNil(D.sanitize(packet, provider: provider, error: error, detail: "other"))
            XCTAssertNil(D.sanitize(packet, provider: "claude", error: error, detail: detail))
        }
    }

    private var qwenResponseContainerFailure: [String: Any] {
        let row: [String: Any] = ["visible": true, "id": "uuid", "loading": 0, "phase": 1, "footer": 1, "limited": false]
        return ["version": 1, "provider": "qwen", "trigger": "response_container_multiple", "total": 2, "displayed": 2,
                "emptyRootMode": false, "dual": true, "multi": false, "smrm": true, "cmrm": false,
                "ancestorLimited": false, "relation": "other", "idRelation": "different_uuid", "containers": [row, row]]
    }

    func testQwenResponseContainerDiagnosticKeepsTheOriginalOwnershipFailureAndClosedLog() throws {
        let original = qwenResponseContainerFailure
        for visible in [true, false] {
            var value = original
            value["displayed"] = visible ? 2 : 0
            value["containers"] = (original["containers"] as! [[String: Any]]).map { row in
                var changed = row; changed["visible"] = visible; return changed
            }
            var observation: [String: Any] = ["error": "document_changed", "detail": "response_container_multiple", "adapterFailureStructure": value]
            let packet = try XCTUnwrap(D.remove(from: &observation, provider: "qwen", action: "inspect"))
            XCTAssertEqual(observation as NSDictionary, ["error": "document_changed", "detail": "response_container_multiple"] as NSDictionary)
            let log = try XCTUnwrap(D.qwenResponseContainerLogFields(packet))
            XCTAssertLessThanOrEqual(log.utf8.count, 1_024)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(log.utf8)) as? NSDictionary, value as NSDictionary)
            XCTAssertNil(D.qwenAuthoredLogFields(packet))
        }
        let authored = try XCTUnwrap(D.sanitize(qwenAuthoredFailure, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertNil(D.qwenResponseContainerLogFields(authored))
        XCTAssertNotNil(D.qwenAuthoredLogFields(authored))
        for provider in ["kimi", "qwen", "deepseek"] {
            let value = WebsiteAdapterFailureFixture.packet(provider)
            let error = provider == "qwen" ? "conversation_changed" : "unsupported_response_format"
            let detail = provider == "kimi" ? "authored_source_markdown_count" : provider == "qwen" ? "first_user_message" : "authored_source"
            let packet = try XCTUnwrap(D.sanitize(value, provider: provider, error: error, detail: detail))
            XCTAssertNil(D.qwenResponseContainerLogFields(packet))
        }
    }

    func testQwenResponseContainerDiagnosticRejectsContentImpossibleCountsAndForeignErrors() {
        let valid = qwenResponseContainerFailure
        func accepts(_ value: [String: Any]) -> Bool {
            D.sanitize(value, provider: "qwen", error: "document_changed", detail: "response_container_multiple") != nil
        }
        XCTAssertTrue(accepts(valid))
        for (key, replacement) in [("total", true as Any), ("total", 1), ("total", 4), ("displayed", 1),
                                   ("displayed", 3), ("smrm", "true"), ("ancestorLimited", 0),
                                   ("relation", "PRIVATE_CLASS"), ("idRelation", "PRIVATE_UUID"),
                                   ("text", "PRIVATE_BODY"), ("containers", [] as [[String: Any]])] {
            var bad = valid; bad[key] = replacement; XCTAssertFalse(accepts(bad), key)
        }
        for (key, replacement) in [("id", "PRIVATE_UUID" as Any), ("loading", -1), ("phase", 4), ("footer", true),
                                   ("limited", "false"), ("visible", 1), ("text", "PRIVATE_BODY")] {
            var bad = valid, rows = valid["containers"] as! [[String: Any]]
            rows[0][key] = replacement; bad["containers"] = rows; XCTAssertFalse(accepts(bad), key)
        }
        var impossibleID = valid, rows = valid["containers"] as! [[String: Any]]
        rows[0]["id"] = "empty_prefix"; impossibleID["containers"] = rows
        XCTAssertFalse(accepts(impossibleID))
        var mixed = valid
        rows = valid["containers"] as! [[String: Any]]; rows[1]["visible"] = false
        mixed["displayed"] = 1; mixed["containers"] = rows
        XCTAssertFalse(accepts(mixed)); mixed["emptyRootMode"] = true; XCTAssertTrue(accepts(mixed))
        var limited = valid; limited["total"] = 3; limited["displayed"] = 3; limited["ancestorLimited"] = true
        XCTAssertTrue(accepts(limited))
        for action in ["submit", "deleteConversation"] {
            var observed: [String: Any] = ["error": "document_changed", "detail": "response_container_multiple", "adapterFailureStructure": valid]
            XCTAssertNil(D.remove(from: &observed, provider: "qwen", action: action))
            XCTAssertEqual(Set(observed.keys), ["error", "detail"])
        }
        for (provider, error, detail) in [("deepseek", "document_changed", "response_container_multiple"),
                                         ("qwen", "conversation_changed", "response_container_multiple"),
                                         ("qwen", "document_changed", "response_container"),
                                         ("qwen", "unsupported_response_format", "authored_source")] {
            XCTAssertNil(D.sanitize(valid, provider: provider, error: error, detail: detail))
        }
    }

    private func qwenOrdinaryContainerFailure(total: Int = 2, displayed: Int = 2,
                                              firstBodyBound: Bool = true, responseIdentityRetained: Bool = false) -> [String: Any] {
        let rows: [[String: Any]] = (0..<min(total, 2)).map { index in
            ["visible": index < displayed, "id": "uuid"]
        }
        return ["version": 1, "provider": "qwen", "trigger": "response_container", "total": total, "displayed": displayed,
                "rootVisible": true, "dual": false, "multi": false, "smrm": false, "cmrm": false, "ancestorLimited": false,
                "relation": total == 0 ? "none" : total == 1 ? "single" : "siblings",
                "idRelation": total >= 2 ? "same_uuid" : "other", "containers": rows,
                "firstBodyBound": firstBodyBound, "responseIdentityRetained": responseIdentityRetained]
    }

    func testQwenOrdinaryContainerFailureLogsOnlyFiniteRejectedCountsAndExistingStateFlags() throws {
        for (total, displayed) in [(0, 0), (1, 0), (2, 0), (2, 2), (3, 0), (3, 3)] {
            for retained in [false, true] {
                let value = qwenOrdinaryContainerFailure(total: total, displayed: displayed, responseIdentityRetained: retained)
                var observation: [String: Any] = ["error": "document_changed", "detail": "response_container", "adapterFailureStructure": value]
                let packet = try XCTUnwrap(D.remove(from: &observation, provider: "qwen", action: "inspect"))
                XCTAssertEqual(observation as NSDictionary, ["error": "document_changed", "detail": "response_container"] as NSDictionary)
                let log = try XCTUnwrap(D.qwenResponseContainerLogFields(packet))
                XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(log.utf8)) as? NSDictionary, value as NSDictionary)
                XCTAssertLessThanOrEqual(log.utf8.count, 1_024)
                XCTAssertNil(D.qwenAuthoredLogFields(packet))
            }
        }
        var unbound = qwenOrdinaryContainerFailure(total: 0, displayed: 0, firstBodyBound: false)
        XCTAssertNotNil(D.sanitize(unbound, provider: "qwen", error: "document_changed", detail: "response_container"))
        unbound.removeValue(forKey: "firstBodyBound")
        XCTAssertNil(D.sanitize(unbound, provider: "qwen", error: "document_changed", detail: "response_container"))
    }

    func testQwenOrdinaryContainerFailureRejectsSuccessShapesUnboundedValuesRawFieldsAndClaimedIdentities() {
        let valid = qwenOrdinaryContainerFailure()
        func accepts(_ value: [String: Any]) -> Bool {
            D.sanitize(value, provider: "qwen", error: "document_changed", detail: "response_container") != nil
        }
        XCTAssertTrue(accepts(valid))
        for (key, replacement) in [("total", true as Any), ("total", -1), ("total", 4), ("displayed", 1), ("displayed", 3),
                                   ("rootVisible", 1), ("smrm", "true"), ("firstBodyBound", 1), ("responseIdentityRetained", "false"),
                                   ("relation", "none"), ("idRelation", "PRIVATE_UUID"), ("text", "PRIVATE_BODY"),
                                   ("taskID", UUID().uuidString), ("sessionToken", UUID().uuidString), ("inferenceID", UUID().uuidString),
                                   ("documentGeneration", UUID().uuidString), ("containers", [] as [[String: Any]])] {
            var bad = valid; bad[key] = replacement; XCTAssertFalse(accepts(bad), key)
        }
        for (key, replacement) in [("id", "PRIVATE_UUID" as Any), ("visible", 1), ("text", "PRIVATE_BODY")] {
            var bad = valid, rows = valid["containers"] as! [[String: Any]]
            rows[0][key] = replacement; bad["containers"] = rows; XCTAssertFalse(accepts(bad), key)
        }
        var mismatchedID = valid, rows = valid["containers"] as! [[String: Any]]
        rows[0]["id"] = "missing"; mismatchedID["containers"] = rows; XCTAssertFalse(accepts(mismatchedID))
        var impossibleVisible = valid; impossibleVisible["displayed"] = 0; XCTAssertFalse(accepts(impossibleVisible))
        var impossibleEmpty = qwenOrdinaryContainerFailure(total: 0, displayed: 0)
        impossibleEmpty["smrm"] = true; XCTAssertFalse(accepts(impossibleEmpty))
        var incomplete = valid; incomplete.removeValue(forKey: "responseIdentityRetained"); XCTAssertFalse(accepts(incomplete))
    }

    func testQwenOrdinaryContainerFailureCannotCrossActionsProviderOrOriginalErrorDetail() {
        let value = qwenOrdinaryContainerFailure()
        for action in ["submit", "verifyModel", "deleteConversation"] {
            var observed: [String: Any] = ["error": "document_changed", "detail": "response_container", "adapterFailureStructure": value]
            XCTAssertNil(D.remove(from: &observed, provider: "qwen", action: action))
            XCTAssertEqual(Set(observed.keys), ["error", "detail"])
        }
        for (provider, error, detail) in [("deepseek", "document_changed", "response_container"),
                                         ("qwen", "conversation_changed", "response_container"),
                                         ("qwen", "document_changed", "response_container_multiple"),
                                         ("qwen", "unsupported_response_format", "authored_source")] {
            XCTAssertNil(D.sanitize(value, provider: provider, error: error, detail: detail))
        }
    }

    private var qwenAuthoredFailure: [String: Any] {
        ["version": 1, "provider": "qwen", "trigger": "authored_source", "stage": "paragraph", "reason": "tag", "count": 0]
    }

    func testQwenAuthoredSourceRejectsForeignOrImpossibleFieldsAndStripsEveryObservation() {
        func sanitized(_ value: [String: Any]) -> D.Packet? {
            D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source")
        }
        let valid = qwenAuthoredFailure
        XCTAssertNotNil(sanitized(valid))
        for (key, value) in [("stage", "PRIVATE_TAG"), ("reason", "PRIVATE_CLASS"), ("text", "PRIVATE_BODY"),
                             ("count", true), ("count", 0.5), ("count", 3), ("count", 1)] as [(String, Any)] {
            var bad = valid; bad[key] = value
            XCTAssertNil(sanitized(bad))
        }
        for (stage, reason, count) in [("flow", "count", 1), ("phase", "scope", 0), ("markdown", "count", 1),
                                      ("literal_contents", "count", 0), ("outside", "count", 2)] {
            var bad = valid; bad["stage"] = stage; bad["reason"] = reason; bad["count"] = count
            XCTAssertNil(sanitized(bad))
        }
        for action in ["inspect", "deleteConversation", "submit"] {
            var observed: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source", "adapterFailureStructure": valid]
            XCTAssertEqual(D.remove(from: &observed, provider: "qwen", action: action) != nil, action == "inspect")
            XCTAssertEqual(Set(observed.keys), ["error", "detail"])
        }
        XCTAssertNil(D.sanitize(valid, provider: "deepseek", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertNil(D.sanitize(valid, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
    }

    func testQwenCodePayloadFailureGatesAreFiniteAndPreserveTheOriginalFailure() throws {
        let reasons = [
            "code_candidate": ["custom_shape", "markdown_shape", "phase_shape", "pre_shape", "header_wrapper",
                               "header_shape", "language", "actions_shape", "body_classes", "body_tag", "body_attributes",
                               "body_visibility", "body_id", "body_empty", "body_children",
                               "plain_code_tag", "plain_code_attributes", "plain_code_visibility", "plain_code_shape",
                               "editor_tag", "editor_class", "editor_attributes", "editor_visibility", "body_geometry", "control_label", "control_shape",
                               "control_decoration", "collapse_state", "missing_copy", "ancestor_limit",
                               "ancestor_visibility", "ancestor_root"],
            "code_sample": ["channel_missing", "channel_shape", "candidate_changed", "candidate_missing",
                            "ancestor_limit", "synchronous_mutation", "result_missing", "result_multiple",
                            "result_invalid", "result_fields", "write_count", "write_invalid", "write_type",
                           "write_invalid_type", "write_invalid_size", "write_invalid_api",
                           "write_invalid_exec", "write_invalid_click", "write_invalid_hooks",
                           "write_invalid_resolve", "root_boundary",
                            "write_size", "utf8_roundtrip"]
        ]
        for (stage, values) in reasons {
            for reason in values {
                var value = qwenAuthoredFailure
                value["stage"] = stage; value["reason"] = reason
                let packet = try XCTUnwrap(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
                let log = try XCTUnwrap(D.qwenAuthoredLogFields(packet))
                XCTAssertLessThanOrEqual(log.utf8.count, 512)
                let logged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(log.utf8)) as? [String: Any])
                XCTAssertEqual(Set(logged.keys), ["version", "provider", "trigger", "stage", "reason", "count"])
                XCTAssertEqual(logged["stage"] as? String, stage)
                XCTAssertEqual(logged["reason"] as? String, reason)
                for (key, replacement) in [("reason", "PRIVATE_CONTENT" as Any), ("count", 1), ("count", true), ("text", "PRIVATE_CONTENT")] {
                    var bad = value; bad[key] = replacement
                    XCTAssertNil(D.sanitize(bad, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
                }
                var observation: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source", "adapterFailureStructure": value]
                XCTAssertNotNil(D.remove(from: &observation, provider: "qwen", action: "inspect"))
                XCTAssertEqual(observation["error"] as? String, "unsupported_response_format")
                XCTAssertEqual(observation["detail"] as? String, "authored_source")
                XCTAssertNil(observation["adapterFailureStructure"])
                XCTAssertNil(D.sanitize(value, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
            }
        }
    }

    func testQwenOrdinaryFailureLogExcludesOtherStructureKindsAndRetainsLegacyReasons() throws {
        for provider in ["kimi", "qwen", "deepseek"] {
            let value = WebsiteAdapterFailureFixture.packet(provider)
            let error = provider == "qwen" ? "conversation_changed" : "unsupported_response_format"
            let detail = provider == "kimi" ? "authored_source_markdown_count" : provider == "qwen" ? "first_user_message" : "authored_source"
            let packet = try XCTUnwrap(D.sanitize(value, provider: provider, error: error, detail: detail))
            XCTAssertNil(D.qwenAuthoredLogFields(packet))
        }
        let legacy = try XCTUnwrap(D.sanitize(qwenAuthoredFailure, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertNotNil(D.qwenAuthoredLogFields(legacy))
        var wrong = qwenAuthoredFailure
        wrong["stage"] = "code_sample"; wrong["reason"] = "body_empty"
        XCTAssertNil(D.sanitize(wrong, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
    }

    func testQwenInlineDiagnosticAcceptsOnlyFixedCategoriesAndZeroCount() {
        for reason in ["escape", "bidi", "decorated", "other", "escape_json"] {
            var packet = qwenAuthoredFailure
            packet["stage"] = "inline"
            packet["reason"] = reason
            func accepts(_ value: [String: Any]) -> Bool {
                D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source") != nil
            }
            XCTAssertTrue(accepts(packet))
            for (key, value) in [("reason", "private_class" as Any), ("count", 1), ("text", "private_text")] {
                var invalid = packet
                invalid[key] = value
                XCTAssertFalse(accepts(invalid))
            }
        }
    }

    func testQwenLongParagraphDiagnosticRequiresSaturatedCountAndClosedPrefixCategory() {
        for reason in ["escape", "bidi", "decorated", "other", "ordinary_prefix", "PRIVATE", "escape_json"] {
            for count in [0, 1, 2] {
                var packet = qwenAuthoredFailure
                packet["stage"] = "span_limit"
                packet["reason"] = reason
                packet["count"] = count
                let result = D.sanitize(packet, provider: "qwen", error: "unsupported_response_format", detail: "authored_source")
                XCTAssertEqual(result != nil, count == 2 && !["PRIVATE", "escape_json"].contains(reason))
            }
        }
    }

    func testQwenPhaseSetDiagnosticIsFixedAndRequiresMultiplePhases() {
        for reason in ["multiple_text_bearing", "one_text_others_empty", "all_empty", "media", "hidden", "other_content", "over_limit", "phase_count_limit", "child_count_limit", "node_visit_limit", "PRIVATE"] {
            for count in [0, 1, 2] {
                var packet = qwenAuthoredFailure
                packet["stage"] = "phase_set"
                packet["reason"] = reason
                packet["count"] = count
                XCTAssertEqual(D.sanitize(packet, provider: "qwen", error: "unsupported_response_format", detail: "authored_source") != nil,
                               count == 2 && reason != "PRIVATE")
            }
        }
    }

    func testQwenPhaseSetSampleLogsOnlyClosedBoundedCountsOnTheExistingRefusal() throws {
        var value = qwenAuthoredFailure
        value.merge(["stage": "phase_set", "reason": "phase_count_limit", "count": 2,
                     "phaseSet": qwenPhaseSetSample] as [String: Any]) { _, new in new }
        let packet = try XCTUnwrap(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertLessThanOrEqual(packet.data.count, 512)
        XCTAssertEqual(try XCTUnwrap(D.qwenAuthoredLogFields(packet)).data(using: .utf8), packet.data)
        for action in ["prepare", "submit", "deleteConversation"] {
            var observed = ["error": "unsupported_response_format", "detail": "authored_source", "adapterFailureStructure": value] as [String: Any]
            XCTAssertNil(D.remove(from: &observed, provider: "qwen", action: action))
            XCTAssertNil(observed["adapterFailureStructure"])
            XCTAssertEqual(observed["error"] as? String, "unsupported_response_format")
        }
        for (provider, error, detail) in [("qwen", "document_changed", "authored_source"),
                                          ("qwen", "unsupported_response_format", "response_container"),
                                          ("kimi", "unsupported_response_format", "authored_source")] {
            XCTAssertNil(D.sanitize(value, provider: provider, error: error, detail: detail))
        }
    }

    func testQwenPhaseSetSampleRejectsRawFieldsImpossibleTotalsAndWrongStages() {
        let mutations: [(String, Any)] = [("matched", 1), ("matched", 34), ("matchedOverflow", true),
                               ("sampled", 3), ("visible", 5), ("textBearing", 3), ("textBearingVisiblePhase", 3),
                               ("textBearingVisiblePhase", 1),
                               ("textUnknown", 1), ("physicallyEmpty", 3), ("singleWrapper", 3),
                               ("direct", -1), ("otherWrapper", "PRIVATE"), ("text", "PRIVATE"),
                               ("sessionToken", UUID().uuidString)]
        for (key, invalid) in mutations {
            var sample = qwenPhaseSetSample
            sample[key] = invalid
            var value = qwenAuthoredFailure
            value.merge(["stage": "phase_set", "reason": "phase_count_limit", "count": 2, "phaseSet": sample] as [String: Any]) { _, new in new }
            XCTAssertNil(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"), key)
        }
        for stage in ["paragraph", "phase", "code_sample"] {
            var value = qwenAuthoredFailure
            value["stage"] = stage
            value["phaseSet"] = qwenPhaseSetSample
            XCTAssertNil(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        }
        var sample = qwenPhaseSetSample
        sample["matched"] = 3; sample["sampled"] = 3; sample["singleWrapper"] = 3; sample["visible"] = 3
        sample["textEmpty"] = 1; sample["physicallyEmpty"] = 1
        var value = qwenAuthoredFailure
        value.merge(["stage": "phase_set", "reason": "phase_count_limit", "count": 2, "phaseSet": sample] as [String: Any]) { _, new in new }
        XCTAssertNil(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        value["reason"] = "multiple_text_bearing"
        XCTAssertNotNil(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
    }

    private var qwenPhaseSetSample: [String: Any] {
        ["matched": 4, "matchedOverflow": false, "sampled": 4, "visible": 4,
         "textBearing": 2, "textBearingVisiblePhase": 2, "textEmpty": 2, "textUnknown": 0, "physicallyEmpty": 1,
         "singleWrapper": 4, "direct": 0, "otherWrapper": 0]
    }

    func testQwenRawSourceDiagnosticLogsOnlyClosedStagesAndPartialBoundedCounts() throws {
        let stages = ["request", "target", "root", "conversation_nodes", "host_props", "element_tree",
            "message_keys", "message_identity", "message_state", "message_mode", "message_legacy_content",
            "message_empty_fields", "message_extra", "message_meta", "message_display", "message_timestamp",
            "feature_keys", "feature_values", "usage_shape", "phase_list", "phase_keys", "phase_kind", "phase_state",
            "phase_extra", "phase_tools", "phase_scalar", "answer_count", "answer_role", "answer_value",
            "renderer_input", "utf8", "source_stability"]
        let samples: [(Any, Any, Any)] = [(NSNull(), NSNull(), NSNull()), (0, false, NSNull()), (0, false, 0),
            (1, false, 1), (2, false, 0), (2, false, 2), (33, true, NSNull()), (33, true, 2)]
        for stage in stages {
            for kind in ["guard", "exception"] {
                for (count, overflow, answers) in samples {
                    let raw: [String: Any] = ["version": 1, "stage": stage, "kind": kind,
                        "phaseCount": count, "phaseOverflow": overflow, "answersSeen": answers]
                    var value = qwenAuthoredFailure; value["rawSource"] = raw
                    let packet = try XCTUnwrap(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
                    XCTAssertLessThanOrEqual(packet.data.count, 1_024)
                    let log = try XCTUnwrap(D.qwenAuthoredLogFields(packet))
                    XCTAssertEqual(Data(log.utf8), packet.data)
                    let logged = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.data) as? [String: Any])
                    XCTAssertEqual(logged as NSDictionary, value as NSDictionary)
                    XCTAssertEqual(Set(logged.keys), ["version", "provider", "trigger", "stage", "reason", "count", "rawSource"])
                }
            }
        }
        var combined = qwenAuthoredFailure
        combined.merge(["stage": "phase_set", "reason": "phase_count_limit", "count": 2, "phaseSet": qwenPhaseSetSample,
            "rawSource": ["version": 1, "stage": "message_legacy_content", "kind": "exception",
                          "phaseCount": 33, "phaseOverflow": true, "answersSeen": 2]] as [String: Any]) { _, new in new }
        let packet = try XCTUnwrap(D.sanitize(combined, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertLessThanOrEqual(packet.data.count, 1_024)
        XCTAssertNotNil(D.qwenAuthoredLogFields(packet))
        let legacy = try XCTUnwrap(D.sanitize(qwenAuthoredFailure, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertLessThanOrEqual(legacy.data.count, 512)
        XCTAssertEqual(try XCTUnwrap(D.qwenAuthoredLogFields(legacy)).data(using: .utf8), legacy.data)
    }

    func testQwenElementTreeSubguardsAreClosedFailureOnlyAndCannotClaimPhaseCounts() throws {
        let stages = ["element_tree_budget", "element_tree_depth", "element_tree_nodekind",
            "element_tree_array", "element_tree_elementshape", "element_tree_kind",
            "element_tree_props", "element_tree_message", "element_tree_editflags",
            "element_tree_children", "element_tree_message_set", "element_tree_nodekind_string",
            "element_tree_nodekind_number", "element_tree_nodekind_bigint", "element_tree_nodekind_symbol",
            "element_tree_nodekind_function", "element_tree_message_set_empty", "element_tree_message_set_multiple"]
        for stage in stages {
            for kind in ["guard", "exception"] {
                let raw: [String: Any] = ["version": 1, "stage": stage, "kind": kind,
                    "phaseCount": NSNull(), "phaseOverflow": NSNull(), "answersSeen": NSNull()]
                var value = qwenAuthoredFailure; value["rawSource"] = raw
                let packet = try XCTUnwrap(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
                XCTAssertLessThanOrEqual(packet.data.count, 1_024)
                XCTAssertEqual(D.qwenAuthoredLogFields(packet), String(decoding: packet.data, as: UTF8.self))
                for (key, invalid) in [("phaseCount", 0), ("phaseOverflow", false), ("answersSeen", 0),
                                       ("text", "PRIVATE_TEXT"), ("stage", stage + "_PRIVATE")] as [(String, Any)] {
                    var changed = raw; changed[key] = invalid
                    var bad = value; bad["rawSource"] = changed
                    XCTAssertNil(D.sanitize(bad, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"), key)
                }
                XCTAssertNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source"))
                XCTAssertNil(D.sanitize(value, provider: "qwen", error: "conversation_changed", detail: "response_scope"))
                let original: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source"]
                var observation = original; observation["adapterFailureStructure"] = value
                XCTAssertNotNil(D.remove(from: &observation, provider: "qwen", action: "inspect"))
                XCTAssertEqual(observation as NSDictionary, original as NSDictionary)
            }
        }
        // The historical coarse label and its original schema remain readable.
        var legacy = qwenAuthoredFailure
        legacy["rawSource"] = ["version": 1, "stage": "element_tree", "kind": "guard",
            "phaseCount": NSNull(), "phaseOverflow": NSNull(), "answersSeen": NSNull()] as [String: Any]
        XCTAssertNotNil(D.sanitize(legacy, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
    }

    func testQwenPhaseStateDiagnosticsStayClosedAndRequireKnownBoundedPhaseCounts() throws {
        let stages = [
            "phase_role_read", "phase_role_null", "phase_role_value_user",
            "phase_role_value_system", "phase_role_value_developer", "phase_role_value_tool",
            "phase_role_value_function", "phase_role_value_empty", "phase_role_value_other_string",
            "phase_role_type_undefined", "phase_role_type_boolean", "phase_role_type_number",
            "phase_role_type_bigint", "phase_role_type_symbol", "phase_role_type_function",
            "phase_role_type_object", "phase_status_read", "phase_status_null",
            "phase_status_value_waiting_input", "phase_status_value_error", "phase_status_value_pause",
            "phase_status_value_empty", "phase_status_value_other_string", "phase_status_type_undefined",
            "phase_status_type_boolean", "phase_status_type_number", "phase_status_type_bigint",
            "phase_status_type_symbol", "phase_status_type_function", "phase_status_type_object"]
        for stage in stages {
            for kind in ["guard", "exception"] {
                for (count, seen) in [(1, 0), (20, 1), (32, 2)] {
                    let raw: [String: Any] = ["version": 1, "stage": stage, "kind": kind,
                        "phaseCount": count, "phaseOverflow": false, "answersSeen": seen]
                    var value = qwenAuthoredFailure; value["rawSource"] = raw
                    let packet = try XCTUnwrap(D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
                    XCTAssertLessThanOrEqual(packet.data.count, 1_024)
                    XCTAssertEqual(D.qwenAuthoredLogFields(packet), String(decoding: packet.data, as: UTF8.self))
                    for (key, bad) in [("phaseCount", NSNull()), ("phaseCount", 0), ("phaseCount", 33),
                                       ("phaseCount", true), ("phaseOverflow", true), ("answersSeen", NSNull()),
                                       ("answersSeen", true), ("role", "PRIVATE_ROLE"), ("status", "PRIVATE_STATUS"),
                                       ("stage", stage + "_PRIVATE")] as [(String, Any)] {
                        var changed = raw; changed[key] = bad
                        var rejected = value; rejected["rawSource"] = changed
                        XCTAssertNil(D.sanitize(rejected, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"), key)
                    }
                    XCTAssertNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source"))
                    XCTAssertNil(D.sanitize(value, provider: "qwen", error: "conversation_changed", detail: "response_scope"))
                    let original: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source"]
                    var observation = original; observation["adapterFailureStructure"] = value
                    XCTAssertNotNil(D.remove(from: &observation, provider: "qwen", action: "inspect"))
                    XCTAssertEqual(observation as NSDictionary, original as NSDictionary)
                }
            }
        }
        var legacy = qwenAuthoredFailure
        legacy["rawSource"] = ["version": 1, "stage": "phase_state", "kind": "guard",
            "phaseCount": NSNull(), "phaseOverflow": NSNull(), "answersSeen": NSNull()] as [String: Any]
        XCTAssertNotNil(D.sanitize(legacy, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
    }

    func testQwenRawSourceDiagnosticRejectsUnknownContentTypesAndImpossibleCounts() {
        let raw: [String: Any] = ["version": 1, "stage": "phase_state", "kind": "guard",
            "phaseCount": 1, "phaseOverflow": false, "answersSeen": 1]
        func accepts(_ sample: Any) -> Bool {
            var value = qwenAuthoredFailure; value["rawSource"] = sample
            return D.sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source") != nil
        }
        let mutations: [(String, Any)] = [("version", true), ("version", 2), ("stage", "PRIVATE_STAGE"),
            ("kind", "PRIVATE_MESSAGE"), ("text", "PRIVATE_TEXT"), ("html", "PRIVATE_HTML"), ("url", "PRIVATE_URL"),
            ("id", UUID().uuidString), ("modelEvidence", [String: Any]()), ("responseAuthorityGranted", true),
            ("phaseCount", true), ("phaseCount", -1), ("phaseCount", 33), ("phaseCount", 34), ("phaseCount", 1.5), ("phaseCount", "1"),
            ("phaseCount", NSNull()), ("phaseOverflow", NSNull()), ("phaseOverflow", true), ("phaseOverflow", 0),
            ("answersSeen", true), ("answersSeen", -1), ("answersSeen", 2), ("answersSeen", 0.5), ("answersSeen", "1")]
        for (key, bad) in mutations {
            var sample = raw; sample[key] = bad
            XCTAssertFalse(accepts(sample), key)
        }
        for key in raw.keys {
            var sample = raw; sample.removeValue(forKey: key)
            XCTAssertFalse(accepts(sample), key)
        }
        for bad in [NSNull(), "PRIVATE_TEXT", [Any](), 1, true] as [Any] { XCTAssertFalse(accepts(bad)) }
        var unknown = raw
        unknown["phaseCount"] = NSNull(); unknown["phaseOverflow"] = NSNull(); unknown["answersSeen"] = 0
        XCTAssertFalse(accepts(unknown))
        unknown["answersSeen"] = NSNull(); unknown["phaseOverflow"] = false
        XCTAssertFalse(accepts(unknown))
        var saturated = raw
        saturated["phaseCount"] = 33; saturated["phaseOverflow"] = true; saturated["answersSeen"] = 3
        XCTAssertFalse(accepts(saturated))
    }

    func testQwenRawSourceDiagnosticIsStrippedWithoutChangingOrdinaryObservationOrFailure() {
        var value = qwenAuthoredFailure
        value["rawSource"] = ["version": 1, "stage": "request", "kind": "exception",
                              "phaseCount": NSNull(), "phaseOverflow": NSNull(), "answersSeen": NSNull()] as [String: Any]
        let originals: [[String: Any]] = [[:], ["text": "SYNTHETIC_ORDINARY_ANSWER", "ready": true],
            ["error": "unsupported_response_format", "detail": "authored_source"],
            ["error": "document_changed", "detail": "response_container"],
            ["error": "unsupported_response_format", "detail": "other"]]
        for provider in ["qwen", "kimi", "deepseek"] {
            for action in ["inspect", "submit", "deleteConversation"] {
                for original in originals {
                    var observed = original; observed["adapterFailureStructure"] = value
                    let packet = D.remove(from: &observed, provider: provider, action: action)
                    XCTAssertEqual(packet != nil, provider == "qwen" && action == "inspect"
                        && original["error"] as? String == "unsupported_response_format"
                        && original["detail"] as? String == "authored_source")
                    XCTAssertEqual(observed as NSDictionary, original as NSDictionary)
                    XCTAssertNil(observed["rawSource"])
                    XCTAssertNil(observed["responseAuthorityGranted"])
                    XCTAssertNil(observed["firstUserFingerprint"])
                }
            }
        }
    }

    func testQwenAuthoredSourcePublicationRequiresExactNamedSelectionAndDedicatedSingleBoundArm() throws {
        let packet = try XCTUnwrap(D.sanitize(qwenAuthoredFailure, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"))
        let max = "Qwen3.8-Max", plus = "Qwen3.7-Plus"
        let maxPurpose = "synthetic_qwen_max_authored_source_v1", plusPurpose = "synthetic_qwen_plus_authored_source_v1"
        let cases = [(max, maxPurpose, "matching"), (plus, plusPurpose, "matching"),
                     (plus, maxPurpose, "wrong_purpose"), (max, plusPurpose, "wrong_purpose"),
                     (plus, plusPurpose, "foreign_model")]
        let failures = ["no_arm", "historical_arm", "first_user_failure", "foreign_turn", "unverified_model",
                        "revoked_generation", "wrong_sequence"]
        for (label, purpose, scenario) in cases + failures.map({ (plus, plusPurpose, $0) })
            + failures.map({ (max, maxPurpose, $0) }) {
            let f = try WebsiteAdapterFailureFixture()
            defer { f.cleanup() }
            let a = f.admission
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            let context = try XCTUnwrap(D.Context(admission: WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID,
                taskID: a.taskID, threadID: a.threadID, turnID: a.turnID, runtimeGeneration: a.runtimeGeneration,
                preparationID: a.preparationID, transportGeneration: a.transportGeneration, provider: "qwen", modelID: choice.modelID,
                parameters: Data(), adapterFailureDirectory: f.directory)))
            var arm = f.arm()
            arm["provider"] = "qwen"; arm["modelID"] = choice.modelID
            if scenario != "historical_arm" { arm["purpose"] = purpose }
            if scenario == "foreign_model" {
                arm["modelID"] = WebsiteModelChoice(provider: "qwen", key: max, label: max).modelID
            }
            if scenario == "foreign_turn" { arm["turnID"] = UUID().uuidString.lowercased() }
            if scenario != "no_arm" { try f.writeArm(arm) }
            let binding = D.Binding(sessionToken: f.binding.sessionToken, documentGeneration: f.binding.documentGeneration,
                sequence: scenario == "wrong_sequence" ? 2 : 1, previousFirstBodyBound: false, priorModelSelectionVerified: scenario != "unverified_model")
            let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
            if scenario == "revoked_generation" { publication.revoke() }
            let firstUserFailure = scenario == "first_user_failure"
            let error = firstUserFailure ? "conversation_changed" : "unsupported_response_format"
            let detail = firstUserFailure ? "first_user_message" : "authored_source"
            let selectedPacket = firstUserFailure
                ? try XCTUnwrap(D.sanitize(WebsiteAdapterFailureFixture.packet("qwen"), provider: "qwen", error: error, detail: detail))
                : packet
            func publish() -> Bool {
                publication.publish(directory: f.directory, context: context, binding: binding, packet: selectedPacket, error: error, detail: detail)
            }
            XCTAssertEqual(publish(), scenario == "matching", scenario)
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.outputURL.path), scenario == "matching", scenario)
            guard scenario == "matching" else {
                XCTAssertEqual(FileManager.default.fileExists(atPath: f.armURL.path), scenario != "no_arm", scenario)
                continue
            }
            XCTAssertFalse(publish())
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.outputURL)) as? [String: Any])
            XCTAssertEqual(record["purpose"] as? String, purpose)
            XCTAssertEqual(record["documentGeneration"] as? String, binding.documentGeneration.uuidString.lowercased())
            XCTAssertEqual(record["inferenceID"] as? String, context.inferenceID.uuidString.lowercased())
            XCTAssertEqual(record["automaticReplay"] as? Bool, false)
            XCTAssertEqual(record["responseAuthorityGranted"] as? Bool, false)
            XCTAssertEqual(record["currentFirstBodyProofGranted"] as? Bool, false)
            let finite = try XCTUnwrap(record["structure"] as? [String: Any])
            XCTAssertEqual(finite as NSDictionary, qwenAuthoredFailure as NSDictionary)
        }
    }

    func testRemovalIsUnconditionalAndNeverAddsProof() throws {
        for action in ["inspect", "submit", "deleteConversation"] {
            let packets: [Any] = [WebsiteAdapterFailureFixture.packet(), ["text": "PRIVATE_BODY"]]
            for packet in packets {
                var observed: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source", "adapterFailureStructure": packet]
                _ = D.remove(from: &observed, provider: "deepseek", action: action)
                XCTAssertEqual(Set(observed.keys), ["error", "detail"])
                XCTAssertNil(observed["text"]); XCTAssertNil(observed["firstUserFingerprint"])
            }
        }
    }

    func testUnknownKeysTextLabelsIDsAndNonBooleanNumbersAreRejected() {
        for key in ["text", "html", "url", "id", "modelEvidence", "firstUserFingerprint"] {
            var value = WebsiteAdapterFailureFixture.packet(); value[key] = "PRIVATE_VALUE"
            XCTAssertNil(sanitize(value))
        }
        for key in ["nodeLimitReached", "knownChromePresent", "knownReasoningPresent"] {
            var value = WebsiteAdapterFailureFixture.packet(); value[key] = 1
            XCTAssertNil(sanitize(value), key)
        }
        let invalidCounts: [Any] = [true, -1, 257, 1.5, "1"]
        for bad in invalidCounts {
            var value = WebsiteAdapterFailureFixture.packet(); value["nodeCount"] = bad
            XCTAssertNil(sanitize(value))
        }
        var value = WebsiteAdapterFailureFixture.packet(); value["predicate"] = "PRIVATE_LABEL"
        XCTAssertNil(sanitize(value))
    }

    func testTreeRejectsUnknownValuesInvalidAncestryDepthAndReasoningTraversal() {
        let fields: [(String, Any)] = [("tag", "PRIVATE_TAG"), ("category", "PRIVATE_CLASS"), ("parent", 0),
            ("depth", 1), ("visible", 1), ("elementChildCount", 258), ("unknownClassPresent", "false")]
        for (key, bad) in fields {
            var node = WebsiteAdapterFailureFixture.node(); node[key] = bad
            var value = WebsiteAdapterFailureFixture.packet(); value["tree"] = [node]
            XCTAssertNil(sanitize(value), key)
        }
        var first = WebsiteAdapterFailureFixture.node(); first["reasoningExcluded"] = true
        var second = WebsiteAdapterFailureFixture.node(); second["parent"] = 0; second["depth"] = 1
        var value = WebsiteAdapterFailureFixture.packet(); value["tree"] = [first, second]; value["nodeCount"] = 2
        XCTAssertNil(sanitize(value))
        first["reasoningExcluded"] = false; value["tree"] = [first, second]
        XCTAssertNotNil(sanitize(value))
        second["depth"] = 17; value["tree"] = [first, second]; XCTAssertNil(sanitize(value))
        value["tree"] = Array(repeating: first, count: 257); value["nodeCount"] = 257; XCTAssertNil(sanitize(value))
    }

    func testOverflowAndCandidatesAreBounded() {
        var value = WebsiteAdapterFailureFixture.packet("kimi")
        value["markdownCount"] = 32; value["markdownCountOverflow"] = true
        XCTAssertNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source_markdown_count"))
        value["markdownCount"] = 33
        XCTAssertNotNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source_markdown_count"))
        let candidate: [String: Any] = ["excludedReasoning": false, "visible": true, "ancestry": ["markdown", "content_box"], "ancestryTruncated": false]
        value["markdownCandidates"] = Array(repeating: candidate, count: 17)
        XCTAssertNil(D.sanitize(value, provider: "kimi", error: "unsupported_response_format", detail: "authored_source_markdown_count"))
    }

    func testQwenComparisonCannotSmuggleTextOrClaimEqualityOrOverlap() {
        var packet = WebsiteAdapterFailureFixture.packet("qwen")
        var comparison = packet["comparison"] as! [String: Any]
        for (key, bad) in [("actualText", "PRIVATE_BODY" as Any), ("exactEqual", true), ("commonSuffixLength", 20)] {
            var altered = comparison; altered[key] = bad; packet["comparison"] = altered
            XCTAssertNil(D.sanitize(packet, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
        }
        comparison["comparisonComplete"] = false; comparison["actualUTF8Length"] = 540_601; comparison["expectedUTF8Length"] = 540_601
        comparison["commonPrefixLength"] = 0; comparison["mismatchCategory"] = "other"
        packet["comparison"] = comparison
        XCTAssertNotNil(D.sanitize(packet, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
        comparison["nfcEqual"] = true; packet["comparison"] = comparison
        XCTAssertNil(D.sanitize(packet, provider: "qwen", error: "conversation_changed", detail: "first_user_message"))
    }

    func testArmRequiresEveryExactIdentityAndRejectsUnknownDuplicateMalformedFields() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNotNil(D.validateArm(try f.armData(now: now), context: f.context, now: now))
        for key in ["taskID", "threadID", "turnID", "modelID", "provider", "purpose", "nonce"] {
            var value = f.arm(now: now); value[key] = "different"
            XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now), key)
        }
        var value = f.arm(now: now); value["schemaVersion"] = true
        XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now))
        value = f.arm(now: now); value["response"] = "PRIVATE_BODY"
        XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now))
        let duplicate = String(String(data: try f.armData(now: now), encoding: .utf8)!.dropLast()) + ",\"schemaVersion\":1}"
        XCTAssertNil(D.validateArm(Data(duplicate.utf8), context: f.context, now: now))
        for delta in [-1.0, 0.0, 601.0] {
            value = f.arm(now: now); value["expiresAt"] = D.formatter().string(from: now.addingTimeInterval(delta))
            XCTAssertNil(D.validateArm(try JSONSerialization.data(withJSONObject: value), context: f.context, now: now))
        }
    }

    func testGroqContextAttributesNativeIdentityWithoutAdmittingAnAdapterPacket() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        let a = f.admission, choice = GroqOwnedStatusLease.Profile.gptoss120b.choice
        let admission = WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID,
            taskID: a.taskID, threadID: a.threadID, turnID: a.turnID,
            runtimeGeneration: a.runtimeGeneration, preparationID: a.preparationID,
            transportGeneration: a.transportGeneration, provider: "groq", modelID: choice.modelID,
            parameters: try JSONSerialization.data(withJSONObject: ["provider": "groq", "modelChoice": choice.canonicalJSONString]),
            rejectedReplyDirectory: f.directory)
        let context = try XCTUnwrap(D.Context(admission: admission))
        XCTAssertEqual(context.taskID.uuidString.lowercased(), a.taskID)
        XCTAssertEqual(context.threadID.uuidString.lowercased(), a.threadID)
        XCTAssertEqual(context.turnID.uuidString.lowercased(), a.turnID)
        XCTAssertEqual(context.runtimeGeneration, a.runtimeGeneration)
        XCTAssertEqual(context.preparationID, a.preparationID)
        XCTAssertEqual(context.transportGeneration, a.transportGeneration)
        XCTAssertEqual(context.inferenceID, a.inferenceID)
        XCTAssertEqual(context.provider, "groq"); XCTAssertEqual(context.modelID, choice.modelID)
        for sourceProvider in ["kimi", "qwen", "deepseek", "groq"] {
            var packet = WebsiteAdapterFailureFixture.packet(sourceProvider)
            packet["provider"] = "groq"
            XCTAssertNil(D.sanitize(packet, provider: "groq", error: "unsupported_response_format", detail: "authored_source"))
            var observed: [String: Any] = ["error": "unsupported_response_format", "detail": "authored_source",
                "adapterFailureStructure": packet]
            XCTAssertNil(D.remove(from: &observed, provider: "groq", action: "inspect"))
            XCTAssertEqual(Set(observed.keys), ["error", "detail"])
            XCTAssertEqual(observed["error"] as? String, "unsupported_response_format")
            XCTAssertEqual(observed["detail"] as? String, "authored_source")
        }
        // Native attribution cannot make a sibling provider's model belong to Groq.
        let foreign = WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID,
            taskID: a.taskID, threadID: a.threadID, turnID: a.turnID,
            runtimeGeneration: a.runtimeGeneration, preparationID: a.preparationID,
            transportGeneration: a.transportGeneration, provider: "groq", modelID: a.modelID,
            parameters: a.parameters, rejectedReplyDirectory: f.directory)
        XCTAssertNil(D.Context(admission: foreign))
    }

    func testContextRejectsForeignProviderInvalidModelAndNonCanonicalIDs() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        for field in ["provider", "model", "task"] {
            let a = f.admission
            let changed = WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID,
                taskID: field == "task" ? a.taskID.uppercased() : a.taskID, threadID: a.threadID, turnID: a.turnID,
                runtimeGeneration: a.runtimeGeneration, preparationID: a.preparationID, transportGeneration: a.transportGeneration,
                provider: field == "provider" ? "claude" : a.provider, modelID: field == "model" ? "not-a-model" : a.modelID, parameters: a.parameters)
            XCTAssertNil(D.Context(admission: changed))
        }
    }

    func testOneShotRecordUsesNativeSecondInferenceIdentityAndNoSourceValues() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
        try f.writeArm()
        let second = f.admission(inferenceID: UUID())
        let context = try XCTUnwrap(D.Context(admission: second))
        let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
        XCTAssertTrue(publication.publish(directory: f.directory, context: context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.armURL.path))
        XCTAssertFalse(publication.publish(directory: f.directory, context: context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
        let bytes = try Data(contentsOf: f.outputURL)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(value["taskID"] as? String, f.context.taskID.uuidString.lowercased())
        XCTAssertEqual(value["inferenceID"] as? String, second.inferenceID.uuidString.lowercased())
        XCTAssertEqual(value["responseAuthorityGranted"] as? Bool, false)
        XCTAssertEqual(value["currentFirstBodyProofGranted"] as? Bool, false)
        XCTAssertEqual(value["submissionAcknowledged"] as? Bool, true)
        XCTAssertNil(value["text"]); XCTAssertNil(value["html"]); XCTAssertNil(value["url"])
        let mode = try FileManager.default.attributesOfItem(atPath: f.outputURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAbsentWrongArmRevokedAndExpiredPublicationLeaveNoRecord() throws {
        for scenario in ["absent", "wrong", "revoked", "expired"] {
            let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }
            if scenario != "absent" {
                var arm = f.arm(); if scenario == "wrong" { arm["taskID"] = UUID().uuidString.lowercased() }
                try f.writeArm(arm)
            }
            let publication = WebsiteAdapterFailurePublication(deadline: .now + (scenario == "expired" ? .seconds(-1) : .seconds(5)))
            if scenario == "revoked" { publication.revoke() }
            XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path))
            if scenario != "absent" { XCTAssertTrue(FileManager.default.fileExists(atPath: f.armURL.path)) }
        }
    }

    func testRevocationImmediatelyBeforeCommitPreventsLateRecord() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }; try f.writeArm()
        let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
        XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source", beforeCommit: { publication.revoke() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.armURL.path))
    }

    func testRacedArmReplacementCannotAuthorizePublicationAndIsPreserved() throws {
        let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }; try f.writeArm()
        let armURL = f.armURL, moved = f.directory.appendingPathComponent("original-arm.json")
        var replacement = f.arm(); replacement["taskID"] = UUID().uuidString.lowercased()
        let bytes = try JSONSerialization.data(withJSONObject: replacement)
        let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
        XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source", beforeArmClaim: {
            try? FileManager.default.moveItem(at: armURL, to: moved)
            try? bytes.write(to: armURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armURL.path)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path))
        XCTAssertEqual(try Data(contentsOf: f.armURL), bytes)
    }

    func testPrivateModesSymlinksAndExistingOutputAreNotRepairedOrOverwritten() throws {
        for scenario in ["directory_mode", "arm_mode", "symlink", "existing"] {
            let f = try WebsiteAdapterFailureFixture(); defer { f.cleanup() }; try f.writeArm()
            if scenario == "directory_mode" { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path) }
            if scenario == "arm_mode" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.armURL.path) }
            if scenario == "symlink" {
                let original = f.directory.appendingPathComponent("original.json")
                try FileManager.default.moveItem(at: f.armURL, to: original)
                try FileManager.default.createSymbolicLink(at: f.armURL, withDestinationURL: original)
            }
            if scenario == "existing" { try Data("preserve".utf8).write(to: f.outputURL) }
            let publication = WebsiteAdapterFailurePublication(deadline: .now + .seconds(5))
            XCTAssertFalse(publication.publish(directory: f.directory, context: f.context, binding: f.binding, packet: try f.safePacket(), error: "unsupported_response_format", detail: "authored_source"))
            if scenario == "existing" { XCTAssertEqual(try Data(contentsOf: f.outputURL), Data("preserve".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: f.outputURL.path)) }
        }
    }

    private func sanitize(_ value: [String: Any]) -> D.Packet? {
        D.sanitize(value, provider: "deepseek", error: "unsupported_response_format", detail: "authored_source")
    }
}

/// Shared with the synthetic WebKit transport check; never opens a provider.
struct WebsiteAdapterFailureFixture {
    let directory: URL
    let admission: WebModelStartAdmission
    let context: WebsiteAdapterFailureDiagnostic.Context
    let binding = WebsiteAdapterFailureDiagnostic.Binding(sessionToken: UUID(), documentGeneration: UUID(), sequence: 1, previousFirstBodyBound: false, priorModelSelectionVerified: true)
    var armURL: URL { directory.appendingPathComponent("arm.json") }
    var outputURL: URL { directory.appendingPathComponent("adapter-failure-structure.json") }
    init() throws {
        directory = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("adapter-structure-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let choice = WebsiteModeChoice(deepSeekMode: .chat)
        admission = WebModelStartAdmission(id: UUID(), inferenceID: UUID(), taskID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(), turnID: UUID().uuidString.lowercased(), runtimeGeneration: UUID(), preparationID: UUID(), transportGeneration: UUID(), provider: "deepseek", modelID: choice.requestID,
            parameters: try JSONSerialization.data(withJSONObject: ["provider": "deepseek", "modeChoice": choice.canonicalJSONString]), adapterFailureDirectory: directory)
        context = try XCTUnwrap(WebsiteAdapterFailureDiagnostic.Context(admission: admission))
    }
    func admission(inferenceID: UUID) -> WebModelStartAdmission {
        WebModelStartAdmission(id: UUID(), inferenceID: inferenceID, taskID: admission.taskID, threadID: admission.threadID, turnID: admission.turnID, runtimeGeneration: admission.runtimeGeneration, preparationID: admission.preparationID, transportGeneration: admission.transportGeneration, provider: admission.provider, modelID: admission.modelID, parameters: admission.parameters, adapterFailureDirectory: directory)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func arm(now: Date = Date()) -> [String: Any] {
        ["schemaVersion": 1, "purpose": WebsiteAdapterFailureDiagnostic.purpose, "nonce": UUID().uuidString.lowercased(),
         "taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(), "turnID": context.turnID.uuidString.lowercased(), "provider": context.provider, "modelID": context.modelID,
         "expiresAt": WebsiteAdapterFailureDiagnostic.formatter().string(from: now.addingTimeInterval(120))]
    }
    func armData(now: Date) throws -> Data { try JSONSerialization.data(withJSONObject: arm(now: now), options: .sortedKeys) }
    func writeArm(_ value: [String: Any]? = nil) throws {
        try JSONSerialization.data(withJSONObject: value ?? arm(), options: .sortedKeys).write(to: armURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armURL.path)
    }
    func safePacket() throws -> WebsiteAdapterFailureDiagnostic.Packet {
        try XCTUnwrap(WebsiteAdapterFailureDiagnostic.sanitize(Self.packet(), provider: "deepseek", error: "unsupported_response_format", detail: "authored_source"))
    }
    static func node(category: String = "final") -> [String: Any] {
        ["parent": -1, "depth": 0, "tag": "div", "category": category, "unknownClassPresent": false, "visible": true, "interactive": false, "elementChildCount": 0, "childCountOverflow": false, "reasoningExcluded": false]
    }
    static func packet(_ provider: String = "deepseek") -> [String: Any] {
        var value: [String: Any] = ["version": 1, "provider": provider, "nodeLimitReached": false, "nodeCount": 1]
        if provider == "kimi" {
            value.merge(["trigger": "authored_source_markdown_count", "tree": [node(category: "content_box")], "markdownCount": 0, "markdownCountOverflow": false, "excludedReasoningCount": 0, "excludedReasoningCountOverflow": false, "answerVisible": true, "boxVisible": true, "markdownCandidates": []] as [String: Any]) { _, new in new }
        } else if provider == "qwen" {
            value.merge(["trigger": "full_prompt_mismatch", "tree": [node(category: "user_container")], "directParagraphCount": 1, "visibleDirectParagraphCount": 1, "descendantParagraphCount": 1, "visibleDescendantParagraphCount": 1, "paragraphCountOverflow": false, "paragraphs": [],
                "comparison": ["comparisonComplete": true, "actualUTF16Length": 10, "expectedUTF16Length": 12, "actualUTF8Length": 10, "expectedUTF8Length": 12, "commonPrefixLength": 4, "commonSuffixLength": 0, "exactEqual": false, "lfDelta": 0, "crDelta": 0, "nbspDelta": 0, "nfcEqual": false, "crlfEqual": false, "trimEqual": false, "mismatchCategory": "internal"]] as [String: Any]) { _, new in new }
        } else {
            value.merge(["trigger": "authored_source", "tree": [node()], "predicate": "paragraph_shape", "finalCount": 1, "finalCountOverflow": false, "knownReasoningPresent": false, "knownReasoningExcluded": false, "knownChromePresent": false, "knownChromeTextExcluded": true] as [String: Any]) { _, new in new }
        }
        return value
    }
}
