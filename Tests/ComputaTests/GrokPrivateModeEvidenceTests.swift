import Foundation
import XCTest
@testable import Computa

final class GrokPrivateModeEvidenceTests: XCTestCase {
    private let owner = UUID().uuidString
    private let generation = UUID()
    private let fingerprint = String(repeating: "a", count: 64)

    private func packet(submitted: Bool = false) -> [String: Any] {
        ["version": 1, "source": submitted ? "submitted_private_provenance" : "current_private_control",
         "ownerToken": owner, "documentGeneration": generation.uuidString, "url": "https://grok.com/",
         "sequence": submitted ? 1 : 0, "enteredBeforeSend": true, "sendClaimed": submitted,
         "contradictoryModeObserved": false]
    }

    func testPrivateEvidenceRequiresClosedTypedOwnerGenerationAndRoot() throws {
        XCTAssertNotNil(GrokPrivateModeEvidence.parse(packet(), ownerToken: owner, generation: generation))
        XCTAssertNotNil(GrokPrivateModeEvidence.parse(packet(submitted: true), ownerToken: owner, generation: generation))
        XCTAssertNil(GrokPrivateModeEvidence.parse(packet(), ownerToken: UUID().uuidString, generation: generation))
        XCTAssertNil(GrokPrivateModeEvidence.parse(packet(), ownerToken: owner, generation: UUID()))
        for key in packet().keys {
            var missing = packet(); missing.removeValue(forKey: key)
            XCTAssertNil(GrokPrivateModeEvidence.parse(missing, ownerToken: owner, generation: generation), key)
        }
        let changes: [(String, Any)] = [("version", true), ("version", 1.5), ("version", "1"),
            ("sequence", false), ("sequence", 1), ("sendClaimed", 0), ("sendClaimed", true),
            ("enteredBeforeSend", 1), ("enteredBeforeSend", false), ("contradictoryModeObserved", 0),
            ("contradictoryModeObserved", true), ("source", "unknown"), ("extra", false),
            ("url", "https://grok.com/c/foreign"), ("url", "https://grok.com/?private=true"),
            ("url", "https://grok.com/#private"), ("url", "https://grok.com:443/")]
        for (key, value) in changes {
            var changed = packet(); changed[key] = value
            XCTAssertNil(GrokPrivateModeEvidence.parse(changed, ownerToken: owner, generation: generation), key)
        }
    }

    func testSubmittedProvenanceCannotCreateNativeSendAuthority() throws {
        let ready = try XCTUnwrap(GrokPrivateModeEvidence.parse(packet(), ownerToken: owner, generation: generation))
        let submitted = try XCTUnwrap(GrokPrivateModeEvidence.parse(packet(submitted: true), ownerToken: owner, generation: generation))
        XCTAssertNil(GrokPrivateSubmission(ready: submitted, outboundFingerprint: fingerprint))
        XCTAssertNil(GrokPrivateSubmission(ready: ready, outboundFingerprint: "short"))
        XCTAssertNil(GrokPrivateSubmission(ready: ready, outboundFingerprint: fingerprint + "\n"))
        var proof = try XCTUnwrap(GrokPrivateSubmission(ready: ready, outboundFingerprint: fingerprint))
        XCTAssertFalse(proof.accepts(submitted, sequence: 1))
        for (token, gen, url, hash) in [(UUID().uuidString, generation, "https://grok.com/", fingerprint),
            (owner, UUID(), "https://grok.com/", fingerprint), (owner, generation, "https://grok.com/c/foreign", fingerprint),
            (owner, generation, "https://grok.com/", String(repeating: "b", count: 64))] {
            XCTAssertFalse(proof.claim(ownerToken: token, generation: gen, url: url, outboundFingerprint: hash))
            XCTAssertFalse(proof.claimed)
        }
        XCTAssertTrue(proof.claim(ownerToken: owner, generation: generation, url: "https://grok.com/", outboundFingerprint: fingerprint))
        XCTAssertFalse(proof.claim(ownerToken: owner, generation: generation, url: "https://grok.com/", outboundFingerprint: fingerprint))
        XCTAssertTrue(proof.accepts(submitted, sequence: 1))
        XCTAssertFalse(proof.accepts(ready, sequence: 1))
        XCTAssertFalse(proof.accepts(submitted, sequence: 0))
        XCTAssertFalse(proof.accepts(submitted, sequence: 2))
        let foreignOwner = UUID().uuidString
        let foreign = try XCTUnwrap(GrokPrivateModeEvidence.parse(packet(submitted: true).merging(["ownerToken": foreignOwner]) { _, new in new },
            ownerToken: foreignOwner, generation: generation))
        XCTAssertFalse(proof.accepts(foreign, sequence: 1))
    }

    @MainActor
    func testInitialHydrationReceiptCarriesNoPositiveAuthority() {
        let value: [String: Any] = ["grokInitialHydrationPending": true, "pending": true, "composer": false]
        XCTAssertTrue(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(value))
        for key in value.keys {
            var missing = value; missing.removeValue(forKey: key)
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(missing))
            var number = value; number[key] = key == "composer" ? 0 : 1
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(number))
            var inverted = value; inverted[key] = key == "composer"
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(inverted))
        }
        for key in ["url", "temporary", "modelEvidence", "grokPrivateEvidence", "firstUserFingerprint", "text", "answerComplete"] {
            var extra = value; extra[key] = true
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(extra), key)
        }
    }

    @MainActor
    func testComposerDiagnosticOnlyRetainsClosedActionAndBranchNames() {
        let actions = ["inspect", "discoverModels", "selectModel", "verifyModel", "enableTemporary",
            "prepare", "insert", "sendReady", "submit", "stop"]
        let details = ["initial_editor_ambiguous", "initial_editor_invalid", "initial_action_ambiguous",
            "initial_action_invalid", "editor_missing", "editor_ambiguous", "editor_authored", "action_missing",
            "action_ambiguous", "action_authored", "action_invalid", "editor_not_fresh", "editor_hit_test"]
        for action in actions {
            for detail in details {
                XCTAssertEqual(EmbeddedWebModelTransport.grokComposerFailureDiagnostic(action: action, detail: detail),
                    "composer_unavailable; action=\(action); detail=\(detail)")
            }
            for detail: Any in ["private page contents", "https://grok.com/c/private", 42, ["editor_missing"], NSNull()] {
                XCTAssertEqual(EmbeddedWebModelTransport.grokComposerFailureDiagnostic(action: action, detail: detail),
                    "composer_unavailable; action=\(action); detail=unknown")
            }
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokComposerFailureDiagnostic(action: "unknown private action", detail: "editor_missing"))
    }

    @MainActor
    func testInitialEditorDiagnosticRejectsOpenFieldsAndKeepsOverlappingFailures() {
        let valid: [String: Any] = ["version": 1, "tag": "div", "editable": true, "role": true, "label": true,
            "connected": true, "rects": false, "displayNone": true, "visibilityHidden": false,
            "hiddenAncestor": true, "inertAncestor": false, "ariaHiddenAncestor": false, "disabled": false, "ariaDisabled": false]
        let reason = "initial_editor_no_rects"
        let rendered = EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(valid, action: "inspect", detail: reason)
        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.contains("rects=false displayNone=true") == true)
        XCTAssertTrue(rendered?.contains("hiddenAncestor=true") == true)
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(missing, action: "inspect", detail: reason), key)
        }
        for (key, value): (String, Any) in [("extra", "private text"), ("tag", "private DOM tag"), ("rects", 0),
            ("editable", "true"), ("version", true), ("version", 1.5)] {
            var invalid = valid; invalid[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(invalid, action: "inspect", detail: reason), key)
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(valid, action: "submit", detail: reason))
        XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(valid, action: "inspect", detail: "initial_editor_disabled"))
        var textarea = valid; textarea["tag"] = "textarea"
        XCTAssertNotNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(textarea, action: "inspect", detail: "initial_editor_tag_textarea"))
    }

    @MainActor
    func testUnexpectedGrokRouteDiagnosticDistinguishesLiteralRootAndClosedRouteShapes() throws {
        let uuid = "11111111-abcd-4333-8444-555555555555"
        let cases: [(String, [String])] = [
            ("https://grok.com/", ["literal=root_with_slash", "path=root", "segments=0", "query=absent"]),
            ("https://grok.com", ["literal=implicit_slash", "path=root", "segments=0"]),
            ("https://grok.com/?", ["literal=other", "query=empty"]),
            ("https://grok.com/?PRIVATE_KEY=PRIVATE_VALUE", ["literal=other", "query=present"]),
            ("https://grok.com/#PRIVATE_FRAGMENT", ["literal=other", "fragment=true"]),
            ("https://grok.com/c/" + uuid, ["path=saved_c", "segments=2", "tokenUUID=lower"]),
            ("https://grok.com/c/" + uuid.uppercased(), ["tokenUUID=upper"]),
            ("https://grok.com/c/" + uuid.replacingOccurrences(of: "abcd", with: "AbCd"), ["tokenUUID=mixed"]),
            ("https://grok.com/c/PRIVATE_TOKEN/PRIVATE_SUFFIX", ["path=saved_c", "segments=3plus", "tokenUUID=other"]),
            ("https://grok.com/c/", ["path=saved_c", "segments=1", "tokenUUID=absent"]),
            ("https://grok.com/PRIVATE_PATH", ["path=other", "segments=1", "tokenUUID=absent"]),
            ("http://grok.com/", ["scheme=http", "host=expected", "literal=other"]),
            ("private+scheme://grok.com/", ["scheme=other", "host=expected"]),
            ("https://PRIVATE_HOST.invalid/", ["host=other"]),
            ("https://grok.com:443/", ["port=https_default", "literal=other"]),
            ("https://grok.com:444/", ["port=other"]),
            ("https://PRIVATE_USER:PRIVATE_PASSWORD@grok.com/", ["userInfo=true"]),
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            let before = EmbeddedWebModelTransport.Provider.grok.accepts(raw)
            let result = EmbeddedWebModelTransport.unexpectedGrokRouteDiagnostic(url)
            for field in expected { XCTAssertTrue(result.split(separator: " ").contains(Substring(field)), field) }
            XCTAssertEqual(EmbeddedWebModelTransport.Provider.grok.accepts(raw), before)
            XCTAssertEqual(before, raw == "https://grok.com/", "Diagnostics never change exact-root admission")
            XCTAssertLessThanOrEqual(result.utf8.count, 256)
            for forbidden in ["PRIVATE", uuid, "grok.com", "https://", "http://", "abcd", "555555"] {
                XCTAssertFalse(result.contains(forbidden), forbidden)
            }
        }
    }

    @MainActor
    func testUnexpectedGrokRouteDiagnosticNeverRetainsPathQueryOrTokenData() throws {
        let schemas: [String: Set<String>] = ["scheme": ["absent", "https", "http", "other"],
            "host": ["absent", "expected", "other"], "port": ["absent", "https_default", "other"],
            "literal": ["absent", "root_with_slash", "implicit_slash", "other"], "userInfo": ["true", "false"],
            "path": ["absent", "root", "saved_c", "other"], "segments": ["0", "1", "2", "3plus"],
            "tokenUUID": ["absent", "lower", "upper", "mixed", "other", "oversized"],
            "query": ["absent", "empty", "present"], "fragment": ["true", "false"]]
        let inputs: [URL?] = [nil, URL(string: "https://grok.com/c/" + String(repeating: "X", count: 4096)),
            URL(string: "https://grok.com/c/%31%31%31%31%31%31%31%31-abcd-4333-8444-555555555555?SECRET_KEY=SECRET_VALUE#SECRET_FRAGMENT"),
            URL(string: "https://grok.com/SECRET_PATH/SECRET_SUBPATH?" + String(repeating: "SECRET", count: 1000))]
        for url in inputs {
            let result = EmbeddedWebModelTransport.unexpectedGrokRouteDiagnostic(url)
            let fields = Dictionary(uniqueKeysWithValues: result.split(separator: " ").map { field in
                let pair = field.split(separator: "=", maxSplits: 1); return (String(pair[0]), String(pair[1]))
            })
            XCTAssertEqual(Set(fields.keys), Set(schemas.keys))
            for (key, value) in fields { XCTAssertTrue(schemas[key]?.contains(value) == true) }
            XCTAssertLessThanOrEqual(result.utf8.count, 256)
            for forbidden in ["SECRET", String(repeating: "X", count: 32), "11111111", "%31", "grok.com"] {
                XCTAssertFalse(result.contains(forbidden))
            }
        }
        XCTAssertTrue(EmbeddedWebModelTransport.unexpectedGrokRouteDiagnostic(nil).contains("literal=absent"))
    }

    @MainActor
    func testOnlyExactPrivateRootIsAdmitted() {
        let provider = EmbeddedWebModelTransport.Provider.grok
        XCTAssertTrue(provider.lifecycle == .temporary)
        XCTAssertTrue(provider.accepts("https://grok.com/"))
        XCTAssertTrue(provider.acceptsUnboundStart(URL(string: "https://grok.com/")!))
        XCTAssertFalse(provider.acceptsTemporaryToggle(URL(string: "https://grok.com/")!))
        XCTAssertNil(provider.savedConversationPolicy)
        for url in ["https://grok.com", "https://grok.com:443/", "https://grok.com/?private=true",
            "https://grok.com/#private", "https://grok.com/c/123?rid=123", "https://www.grok.com/", "https://chat.groq.com/"] {
            XCTAssertFalse(provider.accepts(url), url)
            XCTAssertNil(provider.conversationURL(url), url)
        }
    }
}
