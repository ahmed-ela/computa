import Foundation
import XCTest
@testable import Computa

/// These checks distinguish selected UI identity, reported response identity and
/// request echo; a website label never becomes backend attestation by itself.
final class WebsiteModelEvidenceTests: XCTestCase {
    private let choice = WebsiteModelChoice(provider: "chatgpt", key: "fixture-fast", label: "Fixture Fast")
    private static let privateCanary = "PRIVATE_RAW_PROMPT_TOOL_AND_RESPONSE_CANARY"

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
            XCTAssertNil(response["metadata"], "Echoing a selected local ID is not website provenance")
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
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let transport = EvidenceExportTransport()
        let server = WebModelServer()
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(directory)
        for _ in 0..<2 { _ = try await server.infer(preparedData(choice), taskID: taskID) }
        let file = directory.appendingPathComponent(taskID + ".jsonl")
        let data = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Self.privateCanary))
        let rows = try jsonLines(data)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap { $0["phase"] as? String }, ["submission_verified", "complete", "submission_verified", "complete"])
        XCTAssertEqual(rows.compactMap { $0["sequence"] as? Int }, [1, 1, 2, 2])
        XCTAssertEqual(rows.compactMap { $0["baselineResponseCount"] as? Int }, [0, 0, 1, 1])
        XCTAssertEqual(rows.compactMap { $0["responseCount"] as? Int }, [0, 1, 1, 2])
        XCTAssertEqual(Set(rows.compactMap { $0["taskID"] as? String }), [taskID])
        XCTAssertEqual(Set(rows.compactMap { $0["modelID"] as? String }), [choice.modelID])
        XCTAssertEqual(Set(rows.compactMap { $0["sessionToken"] as? String }).count, 1)
        XCTAssertEqual(Set(rows.compactMap { $0["documentGeneration"] as? String }).count, 1)
        let inferenceIDs = rows.compactMap { $0["inferenceID"] as? String }
        XCTAssertEqual(inferenceIDs.count, 4)
        XCTAssertEqual(inferenceIDs[0], inferenceIDs[1]); XCTAssertEqual(inferenceIDs[2], inferenceIDs[3])
        XCTAssertNotEqual(inferenceIDs[0], inferenceIDs[2])
        for row in rows {
            XCTAssertEqual(row["schemaVersion"] as? Int, 1)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(row["inferenceID"] as? String)))
            XCTAssertNotNil(row["timestamp"] as? String)
            XCTAssertNoThrow(try WebsiteModelEvidence.parse(row["modelEvidence"], provider: choice.provider, expected: choice))
            XCTAssertNil(row["prompt"]); XCTAssertNil(row["text"]); XCTAssertNil(row["arguments"])
            XCTAssertNil(row["threadID"], "An unregistered fixture task cannot fabricate an App Server thread mapping")
        }
        XCTAssertNil(rows[0]["firstUserFingerprint"], "An unpromoted Send acknowledgment must not fabricate a fingerprint")
        XCTAssertEqual(rows[1]["firstUserFingerprint"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        let issues = await server.shutdown()
        XCTAssertTrue(issues.isEmpty)
    }

    func testActualThreadMappingDiffersFromLocalTaskAndNeverChangesTheTaskFilename() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        XCTAssertNotEqual(taskID, threadID)
        let server = WebModelServer()
        await server.configureEmbeddedTransport(EvidenceExportTransport())
        await server.configureEvidenceDirectory(directory)
        await server.registerEvidenceThread(taskID: taskID.uppercased(), threadID: threadID.uppercased())
        // Invalid later input must leave the independently registered mapping
        // intact instead of replacing it with a guessed or path-derived ID.
        await server.registerEvidenceThread(taskID: taskID, threadID: "../untrusted-thread")
        _ = try await server.infer(preparedData(choice), taskID: taskID)
        let rows = try jsonLines(Data(contentsOf: directory.appendingPathComponent(taskID + ".jsonl")))
        XCTAssertEqual(rows.count, 2)
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
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let server = WebModelServer()
        await server.configureEmbeddedTransport(EvidenceExportTransport(context: .fastResponseAtAcknowledgment))
        await server.configureEvidenceDirectory(directory)
        for _ in 0..<2 { _ = try await server.infer(preparedData(choice), taskID: taskID) }
        let rows = try jsonLines(Data(contentsOf: directory.appendingPathComponent(taskID + ".jsonl")))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap { $0["baselineResponseCount"] as? Int }, [0, 0, 1, 1])
        XCTAssertEqual(rows.compactMap { $0["responseCount"] as? Int }, [1, 1, 2, 2],
                       "A fast response must not rewrite the actual Send-acknowledgment count to its earlier baseline")
        XCTAssertEqual(rows[0]["firstUserFingerprint"] as? String, String(repeating: "a", count: 64))
        _ = await server.shutdown()
    }

    func testInvalidTaskOrContextCannotProduceASeeminglyOwnedSidecar() async throws {
        for scenario in [EvidenceExportContext.invalidGeneration, .invalidSequence(0), .invalidSequence(10_001)] {
            let root = try temporaryRoot()
            let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
            let server = WebModelServer()
            await server.configureEmbeddedTransport(EvidenceExportTransport(context: scenario))
            await server.configureEvidenceDirectory(directory)
            _ = try await server.infer(preparedData(choice), taskID: UUID().uuidString)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            _ = await server.shutdown()
        }
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        let server = WebModelServer()
        await server.configureEmbeddedTransport(EvidenceExportTransport())
        await server.configureEvidenceDirectory(directory)
        _ = try await server.infer(preparedData(choice), taskID: "../outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.jsonl").path))
        _ = await server.shutdown()
    }

    func testMalformedFingerprintAndNonIntegerCountsAreNotExportedAsPrivateProof() async throws {
        for context in [EvidenceExportContext.invalidFingerprint, .negativeCount, .booleanSequence, .booleanCount,
                        .missingBaseline, .nullBaseline, .negativeBaseline, .booleanBaseline, .fractionalBaseline, .oversizedBaseline] {
            let root = try temporaryRoot()
            let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
            let taskID = UUID().uuidString.lowercased()
            let server = WebModelServer()
            await server.configureEmbeddedTransport(EvidenceExportTransport(context: context))
            await server.configureEvidenceDirectory(directory)
            _ = try await server.infer(preparedData(choice), taskID: taskID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(taskID + ".jsonl").path),
                           "Malformed contextual fields cannot become provenance or arbitrary private-string exports")
            _ = await server.shutdown()
        }
    }

    func testExistingEvidenceDirectoryPermissionsArePrivateAndFileCapNeverOverwritesPriorEvidence() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let taskID = UUID().uuidString.lowercased()
        let server = WebModelServer()
        await server.configureEmbeddedTransport(EvidenceExportTransport())
        await server.configureEvidenceDirectory(directory)
        _ = try await server.infer(preparedData(choice), taskID: taskID)
        XCTAssertEqual(try permissions(directory), 0o700, "An existing directory must not leave private sidecar files publicly traversable")
        let file = directory.appendingPathComponent(taskID + ".jsonl")
        let full = Data(repeating: 0x78, count: 1_048_576)
        try full.write(to: file)
        _ = try await server.infer(preparedData(choice), taskID: taskID)
        XCTAssertEqual(try Data(contentsOf: file), full, "Bounds must preserve old evidence without truncating or rotating it into success")
        _ = await server.shutdown()
    }

    func testSymlinkedEvidenceFileCannotWriteIntoAnotherLocalFile() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taskID = UUID().uuidString.lowercased()
        let protected = root.appendingPathComponent("synthetic-protected.txt")
        let original = Data("synthetic untouched\n".utf8)
        try original.write(to: protected)
        let file = directory.appendingPathComponent(taskID + ".jsonl")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: protected)
        let server = WebModelServer()
        await server.configureEmbeddedTransport(EvidenceExportTransport())
        await server.configureEvidenceDirectory(directory)
        _ = try await server.infer(preparedData(choice), taskID: taskID)
        XCTAssertEqual(try Data(contentsOf: protected), original)
        XCTAssertTrue(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        _ = await server.shutdown()
    }

    private func selection(_ choice: WebsiteModelChoice, responseSource: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["selected": ["key": choice.key, "label": choice.label],
                                    "verification": responseSource == nil ? "website_selection" : "response_reported"]
        if let responseSource { value["response"] = ["key": choice.key, "label": choice.label, "source": responseSource] }
        return value
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

    private func preparedData(_ choice: WebsiteModelChoice) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": choice.modelID, "input": Self.privateCanary, "tools": [], "stream": true])
    }

    private func prepared(_ choice: WebsiteModelChoice) throws -> WebModelResponseCodec.Request {
        try WebModelResponseCodec.prepareRequest(preparedData(choice))
    }

    private func responses(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("data: ") }
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
    private let token = UUID().uuidString
    private let generation = UUID().uuidString
    private let context: EvidenceExportContext
    private var choice: WebsiteModelChoice?
    private var sequence = 0

    init(context: EvidenceExportContext = .valid) { self.context = context }

    func request(operation: String, params: Data) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        let response: [String: Any]
        if operation == "webProviderStart" {
            choice = try XCTUnwrap(WebsiteModelChoice.parse(try XCTUnwrap(object["modelChoice"])))
            response = snapshot("ready").merging(["sessionToken": token]) { _, value in value }
        } else {
            XCTAssertEqual(object["sessionToken"], token)
            switch operation {
            case "webProviderSend": sequence += 1; response = snapshot("running")
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
        var receipt: [String: Any] = ["documentGeneration": generation,
                                     "responseCount": state == "complete" ? sequence : max(0, sequence - 1),
                                     "baselineResponseCount": max(0, sequence - 1),
                                     "private": "PRIVATE_RAW_PROMPT_TOOL_AND_RESPONSE_CANARY"]
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
        return ["state": state, "sequence": exposedSequence,
                "modelEvidence": ["selected": selected, "verification": "website_selection"],
                "modelProofContext": receipt]
    }
}
