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
