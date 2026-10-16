import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// These checks distinguish selected UI identity, reported response identity and
/// request echo; a website label never becomes backend attestation by itself.
final class WebsiteModelEvidenceTests: XCTestCase {
    private let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")
    private static let privateCanary = "PRIVATE_RAW_PROMPT_TOOL_AND_RESPONSE_CANARY"

    func testNormalChatProductProofRequiresExactControlsAndOwnedTemporaryTransition() throws {
        let initial: [String: String] = ["product": "chatgpt", "mode": "chat", "source": "composer_mode_control",
            "temporaryTransition": "not_requested"]
        let ready = initial.merging(["temporaryTransition": "acknowledged"]) { _, new in new }
        for raw in [initial, ready] {
            let parsed = try WebsiteProductModeEvidence.parse(raw)
            XCTAssertEqual(parsed.dictionary, raw)
        }
        XCTAssertThrowsError(try WebsiteProductModeEvidence.parse(initial, requireTemporary: true))
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(ready, requireTemporary: true))
        var invalid: [Any?] = [nil, NSNull(), [], "Chat", [:], ready.merging(["private": Self.privateCanary]) { _, new in new }]
        for (key, replacement) in [("product", "chatgpt_work"), ("mode", "work"), ("source", "model_picker_label"),
                                    ("temporaryTransition", "requested"), ("temporaryTransition", "acknowledged ")] {
            invalid.append(ready.merging([key: replacement]) { _, new in new })
            var missing = ready; missing.removeValue(forKey: key); invalid.append(missing)
        }
        invalid.append(["product": "chatgpt", "mode": "chat", "source": "composer_mode_control", "temporaryTransition": true])
        for raw in invalid { XCTAssertThrowsError(try WebsiteProductModeEvidence.parse(raw, requireTemporary: true)) }
    }

    func testProductFailureKeepsFiniteNonRetryableRecoveryAtHTTPBoundary() throws {
        for failure: any Error in [WebModelServer.Failure.productModeUnverified, EmbeddedWebModelTransport.Failure.productModeUnverified] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: WebModelServer.errorBody(for: failure)) as? [String: Any])
            let error = try XCTUnwrap(object["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "product_mode_unverified")
            XCTAssertEqual(error["retryable"] as? Bool, false)
            XCTAssertEqual(error["required_action"] as? String, "refresh_website_models")
            XCTAssertTrue(error["param"] is NSNull)
        }
    }

    func testEmbeddedServerRejectsMissingWorkAndUnacknowledgedProductAtEveryAdmissionBoundary() async throws {
        for point in ProductSnapshotPoint.allCases {
            for mutation in ProductSnapshotMutation.allCases {
                let transport = ProductEvidenceTransport(point: point, mutation: mutation)
                let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
                await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
                do {
                    _ = try await server.fixtureInfer(preparedData(choice), taskID: UUID().uuidString)
                    XCTFail("A matching model label cannot authorize an unverified product mode")
                } catch WebModelServer.Failure.productModeUnverified { }
                catch { XCTFail("Product mode must retain its finite failure: \(error)") }
                let count = await transport.sendCount()
                XCTAssertEqual(count, point == .ready ? 0 : 1, "No Send or response may be replayed after product rejection")
                _ = await server.shutdown()
            }
        }
    }

    func testEveryProviderSelectionOnlyProofPreservesItsExplicitWeakerLevel() throws {
        for provider in WebsiteModelCatalog.providers {
            let expected = WebsiteModelChoice(provider: provider, key: "fixture-fast", label: "Fixture Fast")
            let raw = selection(expected)
            let evidence = try WebsiteModelEvidence.parse(raw, provider: provider, expected: expected)
            XCTAssertEqual(evidence.selected.key, expected.key)
            XCTAssertEqual(evidence.selected.label, expected.label)
            XCTAssertEqual(evidence.verification, "website_selection")
            XCTAssertNil(evidence.response)
            XCTAssertNil(evidence.source)
            XCTAssertNil(evidence.dictionary["response"])
            XCTAssertNil(evidence.dictionary["backendVersion"])
            XCTAssertEqual(try WebsiteModelEvidence.parse(evidence.dictionary, provider: provider, expected: expected), evidence)
        }
    }

    func testFiniteResponseAndSelectionSourcesRemainDistinctAndRoundTrip() throws {
        let choice = WebsiteModelChoice(provider: "claude", key: "fixture-fast", label: "Fixture Fast")
        for responseSource in ["response_attribute", "response_label"] {
            for selectionSource in ["model_picker_label", "checked_model_option", "selected_model_indicator"] {
                var raw = selection(choice, responseSource: responseSource)
                raw["source"] = selectionSource
                let evidence = try WebsiteModelEvidence.parse(raw, provider: choice.provider, expected: choice)
                XCTAssertEqual(evidence.verification, "response_reported")
                XCTAssertEqual(evidence.response?.source, responseSource)
                XCTAssertEqual(evidence.source, selectionSource)
                XCTAssertEqual(try WebsiteModelEvidence.parse(evidence.dictionary, provider: choice.provider, expected: choice), evidence)
            }
        }
    }

    func testVerificationLevelCannotPromoteAbsentResponseOrHidePresentResponse() throws {
        var selectionClaim = selection(choice)
        selectionClaim["verification"] = "response_reported"
        assertFailure(selectionClaim, expected: .unverified)
        var hiddenResponse = selection(choice, responseSource: "response_label")
        hiddenResponse["verification"] = "website_selection"
        assertFailure(hiddenResponse, expected: .unverified)
        var nullResponse = selection(choice)
        nullResponse["response"] = NSNull()
        assertFailure(nullResponse, expected: .unverified)
        var unknown = selection(choice)
        unknown["verification"] = "backend_verified"
        assertFailure(unknown, expected: .unverified)
    }

    func testMatchingPickerCannotAuthorizeContradictoryResponseKeyOrLabel() throws {
        for field in ["key", "label"] {
            var raw = selection(choice, responseSource: "response_label")
            var response = try XCTUnwrap(raw["response"] as? [String: String])
            response[field] = "Different Valid Model"
            raw["response"] = response
            assertFailure(raw, expected: .mismatch)
        }
    }

    func testSelectedIdentityCannotBorrowExpectedLabelKeyOrAnotherProvider() {
        for other in [
            WebsiteModelChoice(provider: choice.provider, key: "different", label: choice.label),
            WebsiteModelChoice(provider: choice.provider, key: choice.key, label: "Different Valid Model"),
        ] {
            assertFailure(selection(other), expected: .mismatch)
        }
        let foreign = WebsiteModelChoice(provider: "gemini", key: choice.key, label: choice.label)
        assertFailure(selection(choice), provider: choice.provider, requested: foreign, expected: .mismatch)
        assertFailure(selection(choice), provider: "unknown", requested: nil, expected: .unverified)
    }

    func testProseUnknownFieldsAndMalformedTypesCannotSupplyModelProof() {
        let selected = ["key": choice.key, "label": choice.label]
        let invalid: [Any?] = [
            nil, NSNull(), "I am Fixture Fast", [], [:],
            ["selected": selected],
            ["selected": choice.label, "verification": "website_selection"],
            ["selected": ["key": 1, "label": choice.label], "verification": "website_selection"],
            ["selected": selected.merging(["private": Self.privateCanary]) { _, value in value }, "verification": "website_selection"],
            ["selected": selected, "verification": "website_selection", "assistantText": Self.privateCanary],
            ["selected": selected, "verification": "website_selection", "source": Self.privateCanary],
            ["selected": selected, "verification": "website_selection", "source": "focused_model_indicator"],
            ["selected": selected, "verification": "website_selection", "source": "selected_model_indicator\nPRIVATE"],
            ["selected": selected, "verification": "response_reported", "response": ["key": choice.key, "label": choice.label]],
            ["selected": selected, "verification": "response_reported", "response": ["key": choice.key, "label": choice.label, "source": "model_self_identification"]],
            ["selected": selected, "verification": "response_reported", "response": ["key": choice.key, "label": choice.label, "source": "response_label", "text": Self.privateCanary]],
        ]
        for raw in invalid { assertFailure(raw, expected: .unverified) }
    }

    func testEvidenceBoundsRejectControlsPaddingDecomposedUnicodeAndOversizedFields() {
        for invalid in ["", " padded", "padded ", "line\nbreak", "nul\0value", "e\u{301}", String(repeating: "é", count: 65)] {
            for field in ["key", "label"] {
                var raw = selection(choice)
                var identity = ["key": choice.key, "label": choice.label]
                identity[field] = invalid; raw["selected"] = identity
                assertFailure(raw, expected: .unverified)
                raw = selection(choice, responseSource: "response_attribute")
                var response = ["key": choice.key, "label": choice.label, "source": "response_attribute"]
                response[field] = invalid; raw["response"] = response
                assertFailure(raw, expected: .unverified)
            }
        }
    }

    func testStreamRequestModelIsAnEchoAndCannotInventIndependentWebsiteEvidence() throws {
        let request = try prepared(choice)
        let data = try WebModelResponseCodec.streamData(for: .message("fixture reply"), request: request, responseID: "resp_echo")
        for response in try responses(data) {
            XCTAssertEqual(response["model"] as? String, choice.modelID)
            let metadata = try XCTUnwrap(response["metadata"] as? [String: Any])
            XCTAssertNil(metadata["computa_website_model"], "Echoing a selected local ID is not website provenance")
            XCTAssertTrue(metadata.isEmpty)
            XCTAssertTrue(response["usage"] is NSNull)
        }
    }

    func testStreamCarriesIndependentProofWithoutReplacingRequestIdentityOrClaimingBackendVersion() throws {
        let request = try prepared(choice)
        let observed = WebsiteModelChoice(provider: choice.provider, key: "fixture-different", label: "Fixture Different")
        // The codec is a serializer: server admission checks equality. Retain an
        // independently parsed differing observation here to prove the model
        // echo cannot manufacture matching provenance metadata.
        let evidence = try WebsiteModelEvidence.parse(selection(observed, responseSource: "response_label"), provider: choice.provider)
        let data = try WebModelResponseCodec.streamData(for: .message("fixture reply"), request: request,
            responseID: "resp_independent", websiteModelEvidence: evidence)
        for response in try responses(data) {
            XCTAssertEqual(response["model"] as? String, choice.modelID)
            let metadata = try XCTUnwrap(response["metadata"] as? [String: Any])
            let raw = try XCTUnwrap(metadata["computa_website_model"] as? [String: Any])
            let selected = try XCTUnwrap(raw["selected"] as? [String: String])
            XCTAssertEqual(selected["key"], observed.key)
            XCTAssertEqual(raw["verification"] as? String, "response_reported")
            XCTAssertNil(raw["backendVersion"])
            XCTAssertEqual(try WebsiteModelEvidence.parse(raw, provider: choice.provider), evidence)
        }
    }

    func testRealServerSidecarPinsTwoInferencePairsAndNeverExportsPromptToolOrResponseText() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let transport = EvidenceExportTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(directory)
        var previous: Data?
        for _ in 0..<2 { previous = try await server.fixtureInfer(preparedData(choice, after: previous), taskID: taskID) }
        let file = evidenceFile(directory: directory, taskID: taskID)
        let data = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Self.privateCanary))
        let journal = try jsonLines(data)
        XCTAssertEqual(journal.count, 10)
        XCTAssertEqual(journal.compactMap { $0["phase"] as? String }, Array(repeating:
            ["start_requested", "started", "submission_verified", "complete", "release_verified"], count: 2).flatMap { $0 })
        let rows = journal.filter { ["submission_verified", "complete"].contains($0["phase"] as? String ?? "") }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap { $0["phase"] as? String }, ["submission_verified", "complete", "submission_verified", "complete"])
        XCTAssertEqual(rows.compactMap { $0["sequence"] as? Int }, [1, 1, 1, 1])
        XCTAssertEqual(rows.compactMap { $0["baselineResponseCount"] as? Int }, [0, 0, 0, 0])
        XCTAssertEqual(rows.compactMap { $0["responseCount"] as? Int }, [0, 1, 0, 1])
        XCTAssertEqual(Set(rows.compactMap { $0["taskID"] as? String }), [taskID])
        XCTAssertEqual(Set(rows.compactMap { $0["modelID"] as? String }), [choice.modelID])
        XCTAssertEqual(Set(rows.compactMap { $0["sessionToken"] as? String }).count, 2)
        XCTAssertEqual(Set(rows.compactMap { $0["documentGeneration"] as? String }).count, 2)
        let inferenceIDs = rows.compactMap { $0["inferenceID"] as? String }
        XCTAssertEqual(inferenceIDs.count, 4)
        XCTAssertEqual(inferenceIDs[0], inferenceIDs[1]); XCTAssertEqual(inferenceIDs[2], inferenceIDs[3])
        XCTAssertNotEqual(inferenceIDs[0], inferenceIDs[2])
        for row in rows {
            XCTAssertEqual(row["schemaVersion"] as? Int, 2)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(row["inferenceID"] as? String)))
            XCTAssertNotNil(row["timestamp"] as? String)
            XCTAssertNoThrow(try WebsiteModelEvidence.parse(row["modelEvidence"], provider: choice.provider, expected: choice))
            XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(row["productModeEvidence"], requireTemporary: true))
            XCTAssertNil(row["prompt"]); XCTAssertNil(row["text"]); XCTAssertNil(row["arguments"])
            XCTAssertEqual(row["threadID"] as? String, websiteInferenceFixtureTaskID(taskID + ":thread"))
            XCTAssertEqual(row["turnID"] as? String, websiteInferenceFixtureTaskID(taskID + ":turn"))
            XCTAssertEqual(row["runtimeGeneration"] as? String, websiteInferenceFixtureGeneration.uuidString.lowercased())
            XCTAssertEqual(row["transactionMode"] as? String, "temporary_conversation_per_inference")
        }
        XCTAssertEqual(rows[0]["firstUserFingerprint"] as? String, "", "An unpromoted Send acknowledgment must not fabricate a fingerprint")
        XCTAssertEqual(rows[1]["firstUserFingerprint"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        let issues = await server.shutdown()
        XCTAssertTrue(issues.isEmpty)
    }

    func testActualThreadMappingDiffersFromLocalTaskAndNeverChangesTheTaskFilename() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        XCTAssertNotEqual(taskID, threadID)
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
        await server.configureEmbeddedTransport(EvidenceExportTransport())
        await server.configureEvidenceDirectory(directory)
        try await bindWebsiteInferenceFixtureTurn(server, taskID: taskID, threadID: threadID)
        await server.registerEvidenceThread(taskID: taskID.uppercased(), threadID: threadID.uppercased())
        // Invalid later input must leave the independently registered mapping
        // intact instead of replacing it with a guessed or path-derived ID.
        await server.registerEvidenceThread(taskID: taskID, threadID: "../untrusted-thread")
        _ = try await server.fixtureInfer(preparedData(choice), taskID: taskID, threadID: threadID)
        let rows = try jsonLines(Data(contentsOf: evidenceFile(directory: directory, taskID: taskID)))
        XCTAssertEqual(rows.count, 5)
        for row in rows {
            XCTAssertEqual(row["taskID"] as? String, taskID)
            XCTAssertEqual(row["threadID"] as? String, threadID)
            XCTAssertNotEqual(row["taskID"] as? String, row["threadID"] as? String)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(threadID + ".jsonl").path))
        _ = await server.shutdown()
    }

    func testFastResponseAtAcknowledgmentExportsActualCountAndSeparatePresendBaseline() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
        await server.configureEmbeddedTransport(EvidenceExportTransport(context: .fastResponseAtAcknowledgment))
        await server.configureEvidenceDirectory(directory)
        var previous: Data?
        for _ in 0..<2 { previous = try await server.fixtureInfer(preparedData(choice, after: previous), taskID: taskID) }
        let rows = try jsonLines(Data(contentsOf: evidenceFile(directory: directory, taskID: taskID)))
            .filter { ["submission_verified", "complete"].contains($0["phase"] as? String ?? "") }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap { $0["baselineResponseCount"] as? Int }, [0, 0, 0, 0])
        XCTAssertEqual(rows.compactMap { $0["responseCount"] as? Int }, [1, 1, 1, 1],
                       "A fast response must not rewrite the actual Send-acknowledgment count to its earlier baseline")
        XCTAssertEqual(rows[0]["firstUserFingerprint"] as? String, String(repeating: "a", count: 64))
        _ = await server.shutdown()
    }

    func testInvalidTaskOrContextCannotProduceASeeminglyOwnedSidecar() async throws {
        for scenario in [EvidenceExportContext.invalidGeneration, .invalidSequence(0), .invalidSequence(10_001)] {
            let root = try temporaryRoot()
            let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
            let taskID = UUID().uuidString.lowercased()
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
            await server.configureEmbeddedTransport(EvidenceExportTransport(context: scenario))
            await server.configureEvidenceDirectory(directory)
            do {
                _ = try await server.fixtureInfer(preparedData(choice), taskID: taskID)
                XCTFail("Malformed contextual proof must fail before a response is released")
            } catch WebModelServer.Failure.invalidRequest { }
            let rows = try jsonLines(Data(contentsOf: evidenceFile(directory: directory, taskID: taskID)))
            XCTAssertEqual(rows.compactMap { $0["phase"] as? String }, ["start_requested", "started", "failed"])
            XCTAssertTrue(rows.allSatisfy { $0["modelProofContext"] == nil && $0["firstUserFingerprint"] == nil })
            _ = await server.shutdown()
        }
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
        let transport = EvidenceExportTransport()
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(directory)
        do {
            _ = try await server.infer(preparedData(choice), taskID: "../outside")
            XCTFail("An invalid task cannot acquire a website lease")
        } catch WebModelServer.Failure.inferenceContextRequired { }
        let starts = await transport.startCount()
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.jsonl").path))
        _ = await server.shutdown()
    }

    func testMalformedFingerprintAndNonIntegerCountsAreNotExportedAsPrivateProof() async throws {
        for context in [EvidenceExportContext.invalidFingerprint, .negativeCount, .booleanSequence, .booleanCount,
                        .missingBaseline, .nullBaseline, .negativeBaseline, .booleanBaseline, .fractionalBaseline, .oversizedBaseline] {
            let root = try temporaryRoot()
            let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
            let taskID = UUID().uuidString.lowercased()
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
            await server.configureEmbeddedTransport(EvidenceExportTransport(context: context))
            await server.configureEvidenceDirectory(directory)
            do {
                _ = try await server.fixtureInfer(preparedData(choice), taskID: taskID)
                XCTFail("Malformed contextual fields must fail before response release")
            } catch WebModelServer.Failure.invalidRequest { }
            let data = try Data(contentsOf: evidenceFile(directory: directory, taskID: taskID))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Self.privateCanary))
            let rows = try jsonLines(data)
            XCTAssertEqual(rows.compactMap { $0["phase"] as? String }, ["start_requested", "started", "failed"])
            XCTAssertTrue(rows.allSatisfy { $0["modelEvidence"] == nil && $0["firstUserFingerprint"] == nil },
                          "A bounded failure journal cannot promote malformed fields to proof")
            _ = await server.shutdown()
        }
    }

    func testExistingEvidenceDirectoryPermissionsArePrivateAndFileCapNeverOverwritesPriorEvidence() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let taskID = UUID().uuidString.lowercased()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
        let transport = EvidenceExportTransport()
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(directory)
        let first = try await server.fixtureInfer(preparedData(choice), taskID: taskID)
        XCTAssertEqual(try permissions(directory), 0o700, "An existing directory must not leave private sidecar files publicly traversable")
        let file = evidenceFile(directory: directory, taskID: taskID)
        let full = Data(repeating: 0x78, count: 33_554_432)
        try full.write(to: file)
        do {
            _ = try await server.fixtureInfer(preparedData(choice, after: first), taskID: taskID)
            XCTFail("A full journal must reject admission before opening another website session")
        } catch WebModelServer.Failure.persistenceRequired { }
        let starts = await transport.startCount()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(try Data(contentsOf: file), full, "Bounds must preserve old evidence without truncating or rotating it into success")
        _ = await server.shutdown()
    }

    func testSymlinkedEvidenceFileCannotWriteIntoAnotherLocalFile() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taskID = UUID().uuidString.lowercased()
        let protected = root.appendingPathComponent("synthetic-protected.txt")
        let original = Data("synthetic untouched\n".utf8)
        try original.write(to: protected)
        let file = evidenceFile(directory: directory, taskID: taskID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: protected)
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
        let transport = EvidenceExportTransport()
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(directory)
        do {
            _ = try await server.fixtureInfer(preparedData(choice), taskID: taskID)
            XCTFail("A symlinked journal must reject admission before opening a website")
        } catch WebModelServer.Failure.persistenceRequired { }
        let starts = await transport.startCount()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(try Data(contentsOf: protected), original)
        XCTAssertTrue(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        _ = await server.shutdown()
    }

    private func selection(_ choice: WebsiteModelChoice, responseSource: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["selected": ["key": choice.key, "label": choice.label],
                                    "verification": responseSource == nil ? "website_selection" : "response_reported"]
        if let responseSource { value["response"] = ["key": choice.key, "label": choice.label, "source": responseSource] }
        if let context = chatSelectionEvidenceFixture(choice) {
            value["source"] = "selected_model_indicator"
            value["chatSelection"] = context
        }
        return value
    }

    private func evidenceFile(directory: URL, taskID: String) -> URL {
        directory.appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(websiteInferenceFixtureTaskID(taskID), isDirectory: true)
            .appendingPathComponent(websiteInferenceFixtureTaskID(taskID + ":turn") + ".jsonl")
    }

    private func assertFailure(_ raw: Any?, provider: String? = nil, requested: WebsiteModelChoice? = nil,
                               expected: WebsiteModelEvidence.Failure, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try WebsiteModelEvidence.parse(raw, provider: provider ?? choice.provider, expected: requested ?? choice)
            XCTFail("Untrusted evidence was admitted", file: file, line: line)
        } catch let failure as WebsiteModelEvidence.Failure {
            switch (failure, expected) {
            case (.unverified, .unverified), (.mismatch, .mismatch): break
            default: XCTFail("Wrong finite proof failure: \(failure)", file: file, line: line)
            }
        } catch { XCTFail("Unexpected evidence error", file: file, line: line) }
    }

    private func preparedData(_ choice: WebsiteModelChoice, after previous: Data? = nil) throws -> Data {
        var input: [[String: Any]] = [["type": "message", "role": "user",
            "content": [["type": "input_text", "text": Self.privateCanary]]]]
        if let previous {
            let completed = try XCTUnwrap(responses(previous).last)
            input += try XCTUnwrap(completed["output"] as? [[String: Any]])
            input += [["type": "message", "role": "user", "content": [["type": "input_text", "text": Self.privateCanary]]]]
        }
        return try JSONSerialization.data(withJSONObject: ["model": choice.modelID, "input": input, "tools": [], "stream": true])
    }

    private func prepared(_ choice: WebsiteModelChoice) throws -> WebModelResponseCodec.Request {
        try WebModelResponseCodec.prepareRequest(preparedData(choice))
    }

    private func responses(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any] }
            .compactMap { $0["response"] as? [String: Any] }
    }

    private func jsonLines(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaWebsiteEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private enum EvidenceExportContext: Sendable {
    case valid, fastResponseAtAcknowledgment, invalidGeneration, invalidSequence(Int), invalidFingerprint
    case negativeCount, booleanSequence, booleanCount
    case missingBaseline, nullBaseline, negativeBaseline, booleanBaseline, fractionalBaseline, oversizedBaseline
}

/// Supplies independent snapshot metadata to the actual private sidecar path.
private actor EvidenceExportTransport: WebModelTransport {
    private var token = ""
    private var generation = ""
    private let context: EvidenceExportContext
    private var choice: WebsiteModelChoice?
    private var sequence = 0
    private var starts = 0
    private var submittedFingerprint = ""

    init(context: EvidenceExportContext = .valid) { self.context = context }
    func startCount() -> Int { starts }

    func request(operation: String, params: Data) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        let response: [String: Any]
        if operation == "webProviderStart" {
            token = UUID().uuidString.lowercased()
            generation = UUID().uuidString.lowercased()
            sequence = 0
            submittedFingerprint = ""
            starts += 1
            choice = try XCTUnwrap(WebsiteModelChoice.parse(try XCTUnwrap(object["modelChoice"])))
            response = snapshot("ready").merging(["sessionToken": token]) { _, value in value }
        } else {
            XCTAssertEqual(object["sessionToken"], token)
            switch operation {
            case "webProviderSend":
                sequence += 1
                submittedFingerprint = SHA256.hash(data: Data(try XCTUnwrap(object["prompt"]).utf8)).map { String(format: "%02x", $0) }.joined()
                response = snapshot("running")
            case "webProviderPoll":
                response = snapshot("complete").merging(["text": #"{"type":"message","text":"PRIVATE_RAW_PROMPT_TOOL_AND_RESPONSE_CANARY"}"#]) { _, value in value }
            case "webProviderFinish", "webProviderCancel": response = ["cleanup": "not_created"]
            default: throw WebModelServer.Failure.invalidRequest
            }
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func snapshot(_ state: String) -> [String: Any] {
        let selected = ["key": choice?.key ?? "invalid", "label": choice?.label ?? "invalid"]
        var receipt: [String: Any] = ["documentGeneration": generation, "sequence": sequence,
                                     "responseCount": state == "complete" ? sequence : max(0, sequence - 1),
                                     "baselineResponseCount": max(0, sequence - 1),
                                     "firstUserFingerprint": "", "submittedPromptFingerprint": submittedFingerprint, "private": "PRIVATE_RAW_PROMPT_TOOL_AND_RESPONSE_CANARY"]
        if state == "complete" || sequence > 1 { receipt["firstUserFingerprint"] = String(repeating: "a", count: 64) }
        var exposedSequence: Any = sequence
        switch context {
        case .valid: break
        case .fastResponseAtAcknowledgment:
            if state == "running" {
                receipt["responseCount"] = sequence
                receipt["firstUserFingerprint"] = String(repeating: "a", count: 64)
            }
        case .invalidGeneration: receipt["documentGeneration"] = "not-a-generation"
        case .invalidSequence(let value): exposedSequence = value
        case .invalidFingerprint: receipt["firstUserFingerprint"] = "PRIVATE_RAW_PROMPT_TOOL_AND_RESPONSE_CANARY"
        case .negativeCount: receipt["responseCount"] = -1
        case .booleanSequence: exposedSequence = true
        case .booleanCount: receipt["responseCount"] = true
        case .missingBaseline: receipt.removeValue(forKey: "baselineResponseCount")
        case .nullBaseline: receipt["baselineResponseCount"] = NSNull()
        case .negativeBaseline: receipt["baselineResponseCount"] = -1
        case .booleanBaseline: receipt["baselineResponseCount"] = true
        case .fractionalBaseline: receipt["baselineResponseCount"] = 0.5
        case .oversizedBaseline: receipt["baselineResponseCount"] = 10_001
        }
        var evidence: [String: Any] = ["selected": selected, "verification": "website_selection"]
        if let choice, let context = chatSelectionEvidenceFixture(choice) {
            evidence["source"] = "selected_model_indicator"; evidence["chatSelection"] = context
        }
        return ["state": state, "sessionToken": token, "sequence": exposedSequence,
                "turnContinuationCapability": "per_submission_ownership_v1",
                "modelEvidence": evidence,
                "modelProofContext": receipt,
                "productModeEvidence": ["product": "chatgpt", "mode": "chat", "source": "composer_mode_control", "temporaryTransition": "acknowledged"]]
    }
}

/// Synthetic loopback fixtures simulate a fully prepared normal Chat session.
/// Actual WebKit fixtures acquire this evidence through real DOM actions.
func syntheticPreparedWebsiteSnapshot(_ value: [String: Any], modelChoice: WebsiteModelChoice? = nil) -> [String: Any] {
    guard ["ready", "running", "complete"].contains(value["state"] as? String ?? "") else { return value }
    var snapshot = value.merging(["productModeEvidence": ["product": "chatgpt", "mode": "chat", "source": "composer_mode_control",
        "temporaryTransition": "acknowledged"]]) { _, simulated in simulated }
    if snapshot["modelEvidence"] == nil, let choice = modelChoice, let context = syntheticChatSelection(choice) {
        snapshot["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label],
            "source": "selected_model_indicator", "verification": "website_selection", "chatSelection": context]
    }
    return snapshot
}

private enum ProductSnapshotPoint: CaseIterable, Sendable { case ready, send, complete }
private enum ProductSnapshotMutation: CaseIterable, Sendable { case missing, work, unacknowledged, extraField }

/// Contradicts product mode independently of an otherwise matching model ID.
private actor ProductEvidenceTransport: WebModelTransport {
    private let token = UUID().uuidString
    private let point: ProductSnapshotPoint
    private let mutation: ProductSnapshotMutation
    private var sends = 0
    private var selected: [String: String] = [:]
    private var chatContext: [String: Any]?
    init(point: ProductSnapshotPoint, mutation: ProductSnapshotMutation) { self.point = point; self.mutation = mutation }
    func sendCount() -> Int { sends }
    func request(operation: String, params: Data) throws -> Data {
        var value: [String: Any]
        let current: ProductSnapshotPoint?
        switch operation {
        case "webProviderStart":
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
            let choice = try XCTUnwrap(WebsiteModelChoice.parse(try XCTUnwrap(input["modelChoice"])))
            selected = ["key": choice.key, "label": choice.label]
            chatContext = chatSelectionEvidenceFixture(choice)
            value = ["sessionToken": token, "state": "ready"]; current = .ready
        case "webProviderSend": sends += 1; value = ["state": "running"]; current = .send
        case "webProviderPoll": value = ["state": "complete", "text": #"{"type":"message","text":"OK"}"#]; current = .complete
        case "webProviderFinish", "webProviderCancel": value = ["cleanup": "not_created"]; current = nil
        default: throw WebModelServer.Failure.invalidRequest
        }
        if current != nil {
            var evidence: [String: Any] = ["selected": selected, "verification": "website_selection"]
            if let chatContext { evidence["source"] = "selected_model_indicator"; evidence["chatSelection"] = chatContext }
            value["modelEvidence"] = evidence
            var product = ["product": "chatgpt", "mode": "chat", "source": "composer_mode_control", "temporaryTransition": "acknowledged"]
            if current == point {
                switch mutation {
                case .missing: break
                case .work: product["mode"] = "work"
                case .unacknowledged: product["temporaryTransition"] = "not_requested"
                case .extraField: product["private"] = "PRIVATE_CANARY"
                }
            }
            if current != point || mutation != .missing { value["productModeEvidence"] = product }
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

private func chatSelectionEvidenceFixture(_ choice: WebsiteModelChoice) -> [String: Any]? {
    guard let power = choice.chatGPTPower else { return nil }
    return ["family": ["key": "GPT-6", "label": "GPT-6"],
            "power": ["key": power.rawValue, "label": power.label],
            "automaticFamily": ["policy": "highest_offered_plain_gpt", "offered": ["GPT-6", "GPT-5.5"]]]
}
