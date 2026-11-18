import XCTest
@testable import Computa

@MainActor
final class WebsiteResponseChoiceReceiptTests: XCTestCase {
    private let candidate = "1aa55909-43ba-4c92-8e92-2800abbd0d72"
    private let first = "413e8269-7ba8-476b-84f3-c400e8bed55c"
    private let second = "bbf6615b-e58b-4059-a95c-0d711aa4b6ae"
    private let grant = "caf8aa04-4bac-438b-9280-a98703ec0bee"
    private let fingerprint = String(repeating: "a", count: 64)
    private let url = "https://chat.qwen.ai/c/b3669d48-0898-45f8-a25c-e33d50b21dea"

    private func metadata(_ state: String) -> [String: Any] {
        var value: [String: Any] = ["version": 1, "kind": "qwen_smrm", "policy": "first_observed_card_v1", "state": state,
            "candidate": candidate, "responseIDs": [first, second], "selectedResponseID": first, "firstUserFingerprint": fingerprint]
        if ["dispatched", "acknowledged"].contains(state) { value["grant"] = grant }
        return value
    }

    func testNativeResponseChoiceIdentityRequiresClosedOrderedPairAndSpentGrant() {
        for state in ["waiting", "ready", "dispatched", "acknowledged"] {
            let parsed = EmbeddedWebModelTransport.savedResponseChoiceObservation(metadata(state))
            XCTAssertEqual(parsed?.state, state)
            XCTAssertEqual(parsed?.identity.responseIDs, [first, second])
            XCTAssertEqual(parsed?.grant, ["dispatched", "acknowledged"].contains(state) ? grant : nil)
        }
        for mutation in ["version-bool", "version-two", "kind", "policy", "state", "candidate", "uppercase", "duplicate", "three", "chosen-second", "fingerprint", "extra", "unspent-grant", "missing-grant"] {
            var value = metadata(mutation == "missing-grant" ? "dispatched" : "ready")
            switch mutation {
            case "version-bool": value["version"] = true
            case "version-two": value["version"] = 2
            case "kind": value["kind"] = "cmrm"
            case "policy": value["policy"] = "best_response"
            case "state": value["state"] = "complete"
            case "candidate": value["candidate"] = "not-a-uuid"
            case "uppercase": value["responseIDs"] = [first.uppercased(), second]
            case "duplicate": value["responseIDs"] = [first, first]
            case "three": value["responseIDs"] = [first, second, candidate]
            case "chosen-second": value["selectedResponseID"] = second
            case "fingerprint": value["firstUserFingerprint"] = String(repeating: "A", count: 64)
            case "extra": value["text"] = "must not become evidence"
            case "unspent-grant": value["grant"] = grant
            case "missing-grant": value.removeValue(forKey: "grant")
            default: XCTFail()
            }
            XCTAssertNil(EmbeddedWebModelTransport.savedResponseChoiceObservation(value), mutation)
        }
    }

    func testPendingChoiceEnvelopeCannotPublishOrdinaryReplyOrFirstBodyAuthority() {
        let base: [String: Any] = ["savedResponseChoice": metadata("ready"), "modelEvidence": ["selected": ["key": "Qwen3.7-Plus", "label": "Qwen3.7-Plus"],
            "verification": "website_selection", "source": "model_picker_label"], "url": url,
            "sessionLifecycle": "saved_conversation_delete", "temporary": false]
        XCTAssertNotNil(EmbeddedWebModelTransport.savedResponseChoicePendingObservation(base, url: url, fingerprint: fingerprint))
        for field in ["text", "userCount", "responseCount", "firstUserVerified", "firstUserMarkerVerified", "answerComplete", "qwenCodePayload"] {
            var value = base; value[field] = true
            XCTAssertNil(EmbeddedWebModelTransport.savedResponseChoicePendingObservation(value, url: url, fingerprint: fingerprint), field)
        }
        for mutation in ["new-chat", "other-route", "fingerprint", "temporary-number", "temporary-true", "lifecycle", "acknowledged"] {
            var value = base
            if mutation == "new-chat" { value["url"] = "https://chat.qwen.ai/c/new-chat" }
            if mutation == "other-route" { value["url"] = "https://chat.qwen.ai/c/" + candidate }
            if mutation == "temporary-number" { value["temporary"] = 0 }
            if mutation == "temporary-true" { value["temporary"] = true }
            if mutation == "lifecycle" { value["sessionLifecycle"] = "temporary" }
            if mutation == "acknowledged" { value["savedResponseChoice"] = metadata("acknowledged") }
            XCTAssertNil(EmbeddedWebModelTransport.savedResponseChoicePendingObservation(value, url: url,
                fingerprint: mutation == "fingerprint" ? String(repeating: "0", count: 64) : fingerprint), mutation)
        }
    }

    func testFiniteActionReceiptContainsNoPromptIDsModelOrResponseAndCannotRegress() {
        for phase in WebsiteResponseChoiceReceipt.Phase.allCases {
            let receipt = WebsiteResponseChoiceReceipt(phase: phase)
            XCTAssertEqual(WebsiteResponseChoiceReceipt(receipt.dictionary), receipt)
            XCTAssertEqual(Set(receipt.dictionary.keys), ["version", "kind", "policy", "phase", "choiceSpent", "acknowledged", "noReplay"])
            for previous in WebsiteResponseChoiceReceipt.Phase.allCases {
                XCTAssertEqual(receipt.follows(.init(phase: previous)), phase.rank >= previous.rank)
            }
        }
        XCTAssertNil(EmbeddedWebModelTransport.savedResponseChoiceActionReceipt(spent: false, acknowledged: true))
        for mutation in ["numeric-bool", "missing", "extra", "other-policy", "unknown-phase", "ack-unspent", "replay"] {
            var value = WebsiteResponseChoiceReceipt(phase: .grantSpent).dictionary
            switch mutation {
            case "numeric-bool": value["choiceSpent"] = 1
            case "missing": value.removeValue(forKey: "noReplay")
            case "extra": value["responseID"] = first
            case "other-policy": value["policy"] = "pick_best"
            case "unknown-phase": value["phase"] = "complete"
            case "ack-unspent": value["acknowledged"] = true
            case "replay": value["noReplay"] = false
            default: XCTFail()
            }
            XCTAssertNil(WebsiteResponseChoiceReceipt(value), mutation)
        }
    }

    func testAcknowledgementMustValidateBeforeOrdinaryFirstUserAdoption() throws {
        let identity = try XCTUnwrap(EmbeddedWebModelTransport.savedResponseChoiceObservation(metadata("ready"))?.identity)
        let base: [String: Any] = ["savedResponseChoice": metadata("acknowledged"), "firstUserFingerprint": fingerprint,
            "firstUserVerified": true, "firstUserMarkerVerified": true, "userCount": 1, "responseCount": 1]
        XCTAssertTrue(EmbeddedWebModelTransport.validSavedResponseChoiceAcknowledgement(base, identity: identity, grant: grant))
        for variant in ["missing", "wrong-grant", "wrong-selected", "missing-fingerprint", "numeric-flag", "two-replies", "count-bool", "code-other", "code-malformed"] {
            var value = base
            var choice = metadata("acknowledged")
            switch variant {
            case "missing": value.removeValue(forKey: "savedResponseChoice")
            case "wrong-grant": choice["grant"] = candidate; value["savedResponseChoice"] = choice
            case "wrong-selected": choice["selectedResponseID"] = second; value["savedResponseChoice"] = choice
            case "missing-fingerprint": value.removeValue(forKey: "firstUserFingerprint")
            case "numeric-flag": value["firstUserVerified"] = 1
            case "two-replies": value["responseCount"] = 2
            case "count-bool": value["userCount"] = true
            case "code-other": value["qwenCodePayload"] = ["version": 1, "state": "pending", "candidate": candidate, "responseID": second]
            case "code-malformed": value["qwenCodePayload"] = ["responseID": first]
            default: XCTFail()
            }
            XCTAssertFalse(EmbeddedWebModelTransport.validSavedResponseChoiceAcknowledgement(value, identity: identity, grant: grant), variant)
        }
    }

    func testNativeMemoryStatusIsOnlyAnExactHistoricalActionBinding() throws {
        let token = UUID(), generation = UUID(), model = WebsiteModelChoice(provider: "qwen", key: "Qwen3.7-Plus", label: "Qwen3.7-Plus").modelID
        let status = WebsiteResponseChoiceStatus(sessionToken: token, documentGeneration: generation, modelID: model,
            sequence: 1, receipt: .init(phase: .grantSpent))
        XCTAssertTrue(status.matches(sessionToken: token.uuidString, documentGeneration: generation, modelID: model, sequence: 1, previous: .init(phase: .observed)))
        XCTAssertFalse(status.matches(sessionToken: UUID().uuidString, documentGeneration: generation, modelID: model, sequence: 1, previous: nil))
        XCTAssertFalse(status.matches(sessionToken: token.uuidString, documentGeneration: UUID(), modelID: model, sequence: 1, previous: nil))
        XCTAssertFalse(status.matches(sessionToken: token.uuidString, documentGeneration: generation, modelID: "foreign", sequence: 1, previous: nil))
        XCTAssertFalse(status.matches(sessionToken: token.uuidString, documentGeneration: generation, modelID: model, sequence: 2, previous: nil))
        XCTAssertFalse(status.matches(sessionToken: token.uuidString, documentGeneration: generation, modelID: model, sequence: 1, previous: .init(phase: .acknowledged)))
    }
}
