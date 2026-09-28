import Foundation
import XCTest
@testable import Computa

/// Deterministic channel-contract tests, not a claim of trusted physical input
/// or successful DOM execution in a live browser.
final class BrowserCDPDocumentOperationsTests: XCTestCase {
    private func emptyFieldSteps(value: String? = nil, emptyIDs: [Int] = [17], truncated: Bool = false,
                                 role: String = "searchbox", editable: Bool = true,
                                 blocked: String? = nil) throws -> [DocumentChannelStep] {
        var steps = try DocumentOperationFixture.observationSteps()
        var properties: [[String: Any]] = [["name": "editable", "value": ["value": editable ? "plaintext" : "false"]]]
        if let blocked, blocked != "ignored" { properties.append(["name": blocked, "value": ["value": true]]) }
        var node: [String: Any] = ["backendDOMNodeId": 17, "role": ["value": role],
            "name": ["value": "Query"], "ignored": blocked == "ignored", "properties": properties]
        if let value { node["value"] = ["value": value] }
        steps[2] = try .reply("Accessibility.getFullAXTree", ["nodes": [node]])
        steps[3] = try .reply("DOMSnapshot.captureSnapshot", ["mactopusClickability": [
            "frameId": "main-frame", "documentURL": DocumentOperationFixture.url.absoluteString,
            "clickableBackendNodeIds": [], "pointerBackendNodeIds": [], "sourceNodeCount": 2,
            "sourceTruncated": truncated, "emptyTextValueBackendNodeIds": emptyIDs,
        ]])
        return steps
    }

    private func fieldSnapshot(_ document: BrowserDocumentObservation, binding: BrowserTabBinding) -> BrowserTabSnapshot {
        let node = document.nodes[0]
        return BrowserTabSnapshot(id: UUID(), tabHandle: binding.handle, documentEpoch: binding.documentEpoch,
            loaderID: document.loaderID, documentURL: document.url, elements: [
                BrowserTabElement(index: 0, backendNodeID: 17, role: "AXTextField", label: node.name, value: node.value,
                    isEnabled: !node.isDisabled, supportsPress: false, supportsSetText: true, semanticRole: node.role),
            ], formattedText: "fixture", evidenceDocument: document)
    }

    private func fieldBinding() -> BrowserTabBinding {
        BrowserTabBinding(handle: UUID(), taskKey: "fixture", browserGeneration: UUID(),
            targetID: DocumentOperationFixture.target.targetID, targetInstanceToken: DocumentOperationFixture.target.instanceToken,
            processIdentifier: 42, documentEpoch: UUID(), ownership: .borrowed, lifetime: BrowserTabLifetime())
    }

    func testExplicitEmptyFieldEvidenceCompilesDispatchesOnceAndVerifiesFreshValue() async throws {
        let operations = BrowserCDPDocumentOperations(), binding = fieldBinding()
        let initialChannel = ScriptedDocumentChannel(steps: try emptyFieldSteps())
        var before = try await operations.observe(target: DocumentOperationFixture.target, socket: initialChannel)
        XCTAssertEqual(before.nodes[0].value, "")
        let snapshot = fieldSnapshot(before, binding: binding)
        let compiled = try BrowserActionVerification.compile(action: .setText("Observed query"), elementIndex: 0,
            snapshot: snapshot, binding: binding)
        let plan = try XCTUnwrap(compiled)
        before.verificationPlan = plan
        let mutation = ScriptedDocumentChannel(steps: try emptyFieldSteps()
            + Array(DocumentOperationFixture.successSteps().dropFirst(DocumentOperationFixture.observationMethods.count)))
        try await operations.setText(target: DocumentOperationFixture.target, backendNodeID: 17, text: "Observed query",
            document: before, permit: BrowserMutationPermit(), socket: mutation)
        let mutationState = await mutation.state()
        XCTAssertEqual(mutationState.mutationEnqueues, 1)
        XCTAssertEqual(mutationState.requests.filter { $0.method == "Runtime.callFunctionOn" }.count, 1)
        let freshChannel = ScriptedDocumentChannel(steps: try emptyFieldSteps(value: "Observed query", emptyIDs: []))
        let after = try await operations.observe(target: DocumentOperationFixture.target, socket: freshChannel)
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: fieldSnapshot(after, binding: binding)).expectedValue, "Observed query")
        let readState = await initialChannel.state()
        XCTAssertEqual(readState.mutationEnqueues, 0)
        XCTAssertFalse(readState.requests.contains { $0.hasPermit })
    }

    func testMissingTruncatedProtectedAndIneligibleEmptyEvidenceRemainsUnavailable() async throws {
        let cases: [[DocumentChannelStep]] = try [emptyFieldSteps(emptyIDs: []), emptyFieldSteps(emptyIDs: [18]),
            emptyFieldSteps(truncated: true), emptyFieldSteps(role: "generic"), emptyFieldSteps(editable: false),
            emptyFieldSteps(blocked: "disabled"), emptyFieldSteps(blocked: "readonly"),
            emptyFieldSteps(blocked: "ignored"), emptyFieldSteps(blocked: "protected")]
        for steps in cases {
            let channel = ScriptedDocumentChannel(steps: steps)
            let observed = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
            XCTAssertNil(observed.nodes[0].value)
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 0)
        }
        let missing = ScriptedDocumentChannel(steps: try emptyFieldSteps(emptyIDs: []))
        let document = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: missing)
        let binding = fieldBinding()
        XCTAssertThrowsError(try BrowserActionVerification.compile(action: .setText("Query"), elementIndex: 0,
            snapshot: fieldSnapshot(document, binding: binding), binding: binding)) { error in
            XCTAssertEqual(error as? BrowserActionVerification.Failure, .baselineUnavailable)
        }
    }

    func testConflictingOrChangedEmptyBaselineRejectsBeforeMutation() async throws {
        let operations = BrowserCDPDocumentOperations()
        let conflict = ScriptedDocumentChannel(steps: try emptyFieldSteps(value: "Already changed"))
        do {
            _ = try await operations.observe(target: DocumentOperationFixture.target, socket: conflict)
            XCTFail("An AX/DOM value conflict must not create a synthetic baseline")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .elementChanged) }
        let beforeChannel = ScriptedDocumentChannel(steps: try emptyFieldSteps())
        let before = try await operations.observe(target: DocumentOperationFixture.target, socket: beforeChannel)
        let changed = ScriptedDocumentChannel(steps: try emptyFieldSteps(value: "Changed", emptyIDs: [])
            + [.reply("Runtime.releaseObjectGroup", [:])])
        do {
            try await operations.setText(target: DocumentOperationFixture.target, backendNodeID: 17, text: "Query",
                document: before, permit: BrowserMutationPermit(), socket: changed)
            XCTFail("Fresh preflight must preserve the exact observed empty baseline")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .elementChanged) }
        let state = await changed.state()
        XCTAssertEqual(state.mutationEnqueues, 0)
        XCTAssertFalse(state.requests.contains { $0.method == "DOM.resolveNode" })
    }

    func testFinalCDPBaselineRevalidationRejectsChangedResultBeforeMutation() async throws {
        let target = DocumentOperationFixture.target
        let binding = BrowserTabBinding(handle: UUID(), taskKey: "fixture", browserGeneration: UUID(),
            targetID: target.targetID, targetInstanceToken: target.instanceToken, processIdentifier: 42,
            documentEpoch: UUID(), ownership: .borrowed, lifetime: BrowserTabLifetime())
        let button = DocumentOperationFixture.node()
        func result(_ value: String) -> BrowserDocumentNode {
            BrowserDocumentNode(backendNodeID: 18, role: "StaticText", name: "Count", value: value,
                isDisabled: false, isReadOnly: true, isIgnored: false)
        }
        var document = DocumentOperationFixture.document(nodes: [button, result("0")])
        let snapshot = BrowserTabSnapshot(id: UUID(), tabHandle: binding.handle, documentEpoch: binding.documentEpoch,
            loaderID: document.loaderID, documentURL: document.url, elements: [
                BrowserTabElement(index: 0, backendNodeID: 17, role: "AXButton", label: button.name, value: nil,
                    isEnabled: true, supportsPress: true, supportsSetText: false, semanticRole: "button"),
                BrowserTabElement(index: 1, backendNodeID: 18, role: "AXStaticText", label: "Count", value: "0",
                    isEnabled: true, supportsPress: false, supportsSetText: false, semanticRole: "StaticText"),
            ], formattedText: "fixture", evidenceDocument: document)
        document.verificationPlan = try XCTUnwrap(BrowserActionVerification.compile(
            request: .init(kind: .value, elementIndex: 1, expected: "1"), action: .press,
            elementIndex: 0, snapshot: snapshot, binding: binding))
        let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.observationSteps(nodes: [button, result("1")])
            + [.reply("Runtime.releaseObjectGroup", [:])])
        do {
            try await BrowserCDPDocumentOperations().press(target: target, backendNodeID: 17, document: document,
                permit: BrowserMutationPermit(), socket: channel)
            XCTFail("Final baseline changed, even though the clicked button is unchanged")
        } catch let failure as BrowserActionVerification.Failure { XCTAssertEqual(failure, .baselineChanged) }
        let state = await channel.state()
        XCTAssertEqual(state.mutationEnqueues, 0)
        XCTAssertFalse(state.requests.contains { $0.method == "DOM.resolveNode" })
    }

    func testObservedEditableMetadataIsPreservedEvenForGenericRoles() async throws {
        for mode in ["absent", "false", "plaintext", "richtext", "boolean"] {
            var steps = try DocumentOperationFixture.observationSteps()
            let properties: [[String: Any]] = mode == "absent" ? [] : [[
                "name": "editable", "value": ["value": mode == "boolean" ? true : mode] as [String: Any],
            ]]
            steps[2] = try .reply("Accessibility.getFullAXTree", ["nodes": [[
                "backendDOMNodeId": 17, "role": ["value": "generic"], "name": ["value": "Observed content"],
                "properties": properties,
            ]]])
            let channel = ScriptedDocumentChannel(steps: steps)
            let observed = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
            XCTAssertEqual(observed.nodes[0].isEditable, ["plaintext", "richtext", "boolean"].contains(mode), mode)
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 0)
            XCTAssertFalse(state.requests.contains { $0.hasPermit })
        }
    }

    func testPointerAffordanceRequiresFocusableExactAXNode() async throws {
        for focusable in [false, true] {
            for pointer in [false, true] {
                var steps = try DocumentOperationFixture.observationSteps()
                steps[2] = try .reply("Accessibility.getFullAXTree", ["nodes": [
                    ["backendDOMNodeId": 17, "role": ["value": "row"], "name": ["value": "Fixture message"],
                     "properties": [["name": "focusable", "value": ["value": focusable]]]],
                    ["backendDOMNodeId": 18, "role": ["value": "StaticText"], "name": ["value": "Child label"]],
                ]])
                steps[3] = try .reply("DOMSnapshot.captureSnapshot", ["mactopusClickability": [
                    "frameId": "main-frame", "documentURL": DocumentOperationFixture.url.absoluteString,
                    "clickableBackendNodeIds": [], "pointerBackendNodeIds": pointer ? [17] : [],
                    "sourceTruncated": false, "sourceNodeCount": 2,
                ]])
                let channel = ScriptedDocumentChannel(steps: steps)
                let observed = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
                XCTAssertEqual(observed.nodes[0].isFocusablePointer, focusable && pointer)
                XCTAssertFalse(observed.nodes[0].isDOMClickable)
                XCTAssertFalse(observed.nodes[1].isFocusablePointer)
                let state = await channel.state()
                let request = try XCTUnwrap(state.requests.first { $0.method == "DOMSnapshot.captureSnapshot" })
                XCTAssertEqual(try DocumentOperationFixture.object(request.params)["computedStyles"] as? [String], BrowserDOMActionProjection.styles)
                XCTAssertFalse(request.hasPermit)
            }
        }
    }

    func testOlderExtensionPreservesSemanticObservationWithoutInventedCapabilities() async throws {
        var steps = try DocumentOperationFixture.observationSteps()
        steps[3] = DocumentChannelStep(method: "DOMSnapshot.captureSnapshot", response: .unsupported)
        let channel = ScriptedDocumentChannel(steps: steps)
        let result = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
        XCTAssertEqual(result, DocumentOperationFixture.document())
        XCTAssertFalse(result.nodes[0].isDOMClickable)
        XCTAssertFalse(result.nodes[0].isFocusablePointer)
    }

    func testRemovedBrowserClickEvidenceStopsBeforeMutation() async throws {
        let approved = BrowserDocumentNode(backendNodeID: 17, role: "row", name: "Fixture message", value: nil,
            isDisabled: false, isReadOnly: false, isIgnored: false, isDOMClickable: true)
        let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.observationSteps(nodes: [approved])
            + [.reply("Runtime.releaseObjectGroup", [:])])
        do {
            try await DocumentOperationFixture.run(.press, channel: channel, nodes: [approved])
            XCTFail("Lost clickability must be re-observed, not blindly dispatched")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .elementChanged) }
        let state = await channel.state()
        XCTAssertEqual(state.mutationEnqueues, 0)
        XCTAssertFalse(state.requests.contains { $0.method == "DOM.resolveNode" })
    }

    func testObservationParsesExactSemanticsAndBracketedFrame() async throws {
        let node = DocumentOperationFixture.node(role: "textbox", value: "Initial é", readOnly: true)
        let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.observationSteps(nodes: [node]))
        let observed = try await BrowserCDPDocumentOperations().observe(
            target: DocumentOperationFixture.target, socket: channel
        )
        XCTAssertEqual(observed, DocumentOperationFixture.document(nodes: [node]))
        let state = await channel.state()
        XCTAssertEqual(state.requests.map(\.method), DocumentOperationFixture.observationMethods)
        XCTAssertEqual(state.mutationEnqueues, 0)
        XCTAssertEqual(state.remainingSteps, 0)
        XCTAssertEqual(state.invalidations, 0)
        let tree = try XCTUnwrap(state.requests.first { $0.method == "Accessibility.getFullAXTree" })
        XCTAssertEqual(try DocumentOperationFixture.object(tree.params)["depth"] as? Int, 64)
    }

    func testObservationRetainsHierarchyLinkAndReportsMissingDescendants() async throws {
        let node = BrowserDocumentNode(
            backendNodeID: 17, role: "link", name: "Unknown card title", value: nil,
            isDisabled: false, isReadOnly: false, isIgnored: false,
            nodeID: "card-link", parentNodeID: "card", childNodeIDs: ["omitted-child"],
            linkURL: "https://example.test/read?entry=one"
        )
        let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.observationSteps(nodes: [node]))
        let observed = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
        XCTAssertEqual(observed.nodes, [node])
        XCTAssertTrue(observed.sourceTruncated)
        let state = await channel.state()
        XCTAssertEqual(state.mutationEnqueues, 0)
    }

    func testObservationFlagsDepthBoundaryAndBoundsWideCapture() async throws {
        for wide in [false, true] {
            let count = wide ? 12_002 : 66
            let nodes = (0 ..< count).map { index in
                BrowserDocumentNode(
                    backendNodeID: Int64(index + 1), role: "heading", name: "Title \(index)", value: nil,
                    isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "n\(index)",
                    parentNodeID: wide || index == 0 ? nil : "n\(index - 1)"
                )
            }
            let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.observationSteps(nodes: nodes))
            let observed = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
            XCTAssertEqual(observed.nodes.count, min(count, 12_000))
            XCTAssertTrue(observed.sourceTruncated)
        }
    }

    func testObservationPreservesExtensionWireTruncationMarker() async throws {
        var steps = try DocumentOperationFixture.observationSteps()
        steps[2] = try .reply("Accessibility.getFullAXTree", [
            "nodes": [], "macrouseSourceTruncated": true, "macrouseSourceNodeCount": 3000,
        ])
        let channel = ScriptedDocumentChannel(steps: steps)
        let observed = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
        XCTAssertTrue(observed.nodes.isEmpty)
        XCTAssertTrue(observed.sourceTruncated)
    }

    func testObservationRejectsFrameDrift() async throws {
        var steps = try DocumentOperationFixture.observationSteps()
        steps[4] = try .reply("Page.getFrameTree", DocumentOperationFixture.frame(loader: "new-loader"))
        let channel = ScriptedDocumentChannel(steps: steps)
        do {
            _ = try await BrowserCDPDocumentOperations().observe(target: DocumentOperationFixture.target, socket: channel)
            XCTFail("An observation spanning a different document must fail.")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .staleDocument) }
        let state = await channel.state()
        XCTAssertEqual(state.mutationEnqueues, 0)
        XCTAssertEqual(state.remainingSteps, 0)
    }

    func testSuccessfulPressUsesResolvedObjectExactContextAndOnePermit() async throws {
        let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.successSteps())
        try await DocumentOperationFixture.run(.press, channel: channel)
        let state = await channel.state()
        XCTAssertEqual(state.requests.map(\.method), DocumentOperationFixture.mutationMethods)
        XCTAssertEqual(state.mutationEnqueues, 1)
        XCTAssertEqual(state.remainingSteps, 0)
        XCTAssertEqual(state.invalidations, 0)
        let world = try request("Page.createIsolatedWorld", from: state)
        XCTAssertEqual(world["frameId"] as? String, "main-frame")
        XCTAssertNil(world["grantUniveralAccess"])
        let resolved = try request("DOM.resolveNode", from: state)
        XCTAssertEqual(resolved["backendNodeId"] as? Int, 17)
        XCTAssertEqual(resolved["executionContextId"] as? Int, 31)
        let call = try request("Runtime.callFunctionOn", from: state)
        XCTAssertEqual(call["objectId"] as? String, "exact-session-object")
        XCTAssertEqual((call["arguments"] as? [[String: String]])?.first?["value"], DocumentOperationFixture.url.absoluteString)
        XCTAssertEqual(call["userGesture"] as? Bool, true)
        XCTAssertEqual(call["returnByValue"] as? Bool, true)
        XCTAssertTrue((call["functionDeclaration"] as? String)?.contains("HTMLElement.prototype.click.call(this)") == true)
        XCTAssertEqual(state.requests.filter(\.hasPermit).map(\.method), ["Runtime.callFunctionOn"])
        try assertExactGroupCleanup(state)
    }

    func testSetTextPreservesUnicodeAsDataNotInterpolatedCode() async throws {
        let value = "é🧪 مرحبا\n\"quotes\" \\ backslash "
        let node = DocumentOperationFixture.node(role: "textbox", value: "Before")
        let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.successSteps(nodes: [node]))
        try await DocumentOperationFixture.run(.setText(value), channel: channel, nodes: [node])
        let state = await channel.state()
        let call = try request("Runtime.callFunctionOn", from: state)
        let arguments = try XCTUnwrap(call["arguments"] as? [[String: String]])
        XCTAssertEqual(arguments.map { $0["value"] }, [DocumentOperationFixture.url.absoluteString, value])
        XCTAssertFalse((call["functionDeclaration"] as? String)?.contains(value) == true)
        XCTAssertEqual(state.mutationEnqueues, 1)
        XCTAssertEqual(state.remainingSteps, 0)
        XCTAssertEqual(state.invalidations, 0)
        try assertExactGroupCleanup(state)
    }

    func testChangedSemanticFieldsRejectBeforeResolveOrMutation() async throws {
        let mismatches = [
            DocumentOperationFixture.node(name: "Different label"),
            DocumentOperationFixture.node(role: "link"),
            DocumentOperationFixture.node(value: "Changed value"),
            DocumentOperationFixture.node(disabled: true),
            DocumentOperationFixture.node(readOnly: true),
            DocumentOperationFixture.node(ignored: true),
        ]
        for node in mismatches {
            let steps = try DocumentOperationFixture.observationSteps(nodes: [node]) + [.reply("Runtime.releaseObjectGroup", [:])]
            let channel = ScriptedDocumentChannel(steps: steps)
            await expectBrokerError(.elementChanged, channel: channel)
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 0)
            XCTAssertFalse(state.requests.contains { $0.method == "DOM.resolveNode" })
            XCTAssertEqual(state.requests.filter { $0.method == "Runtime.releaseObjectGroup" }.count, 1)
            XCTAssertEqual(state.remainingSteps, 0)
            XCTAssertEqual(state.invalidations, 0)
        }
    }

    func testMissingOrDuplicateBackendNodeRejectsBeforeMutation() async throws {
        for nodes in [[], [DocumentOperationFixture.node(), DocumentOperationFixture.node()]] {
            let steps = try DocumentOperationFixture.observationSteps(nodes: nodes) + [.reply("Runtime.releaseObjectGroup", [:])]
            let channel = ScriptedDocumentChannel(steps: steps)
            await expectBrokerError(.elementNotFound, channel: channel)
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 0)
            XCTAssertEqual(state.remainingSteps, 0)
            XCTAssertFalse(state.requests.contains { $0.method == "DOM.resolveNode" })
        }
    }

    func testPostResolveFrameDriftReleasesOriginalGroupWithoutMutation() async throws {
        for changedFrame in [
            DocumentOperationFixture.frame(id: "replacement-frame"),
            DocumentOperationFixture.frame(loader: "replacement-loader"),
            DocumentOperationFixture.frame(fragment: "#different"),
        ] {
            var steps = try DocumentOperationFixture.preparationSteps()
            steps[8] = try .reply("Page.getFrameTree", changedFrame)
            steps.append(try .reply("Runtime.releaseObjectGroup", [:]))
            let channel = ScriptedDocumentChannel(steps: steps)
            await expectBrokerError(.staleDocument, channel: channel)
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 0)
            XCTAssertEqual(state.remainingSteps, 0)
            XCTAssertFalse(state.requests.contains { $0.method == "Runtime.callFunctionOn" })
            XCTAssertEqual(state.invalidations, 0)
            try assertExactGroupCleanup(state)
        }
    }

    func testMutationCommandErrorCleansUpAndNeverRetries() async throws {
        for action in [DocumentOperationFixture.Action.press, .setText("é🧪")] {
            let nodes: [BrowserDocumentNode]
            switch action {
            case .press: nodes = [DocumentOperationFixture.node()]
            case .setText: nodes = [DocumentOperationFixture.node(role: "textbox")]
            }
            let steps = try DocumentOperationFixture.preparationSteps(nodes: nodes) + [
                .failure("Runtime.callFunctionOn", .mutationFailed), .reply("Runtime.releaseObjectGroup", [:]),
            ]
            let channel = ScriptedDocumentChannel(steps: steps)
            do {
                try await DocumentOperationFixture.run(action, channel: channel, nodes: nodes)
                XCTFail("Injected command error must be preserved.")
            } catch let error as BrowserMutationFailure {
                XCTAssertEqual(error.dispatchState, .unknown)
                XCTAssertEqual(error.underlyingError as? DocumentChannelTestError, .mutationFailed)
                XCTAssertTrue(error.localizedDescription.contains("do not repeat"))
            }
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 1)
            XCTAssertEqual(state.requests.filter { $0.method == "Runtime.callFunctionOn" }.count, 1)
            XCTAssertEqual(state.remainingSteps, 0)
            XCTAssertEqual(state.invalidations, 0)
            try assertExactGroupCleanup(state)
        }
    }

    func testFalseAndExceptionMutationResultsCleanUpWithoutRetry() async throws {
        for result in [["result": ["value": false]], ["exceptionDetails": ["text": "fixture exception"]]] as [[String: Any]] {
            let steps = try DocumentOperationFixture.preparationSteps() + [
                .reply("Runtime.callFunctionOn", result), .reply("Runtime.releaseObjectGroup", [:]),
            ]
            let channel = ScriptedDocumentChannel(steps: steps)
            do {
                try await DocumentOperationFixture.run(.press, channel: channel)
                XCTFail("Rejected DOM result must not report success.")
            } catch {
                let brokerError: BrowserTabBrokerError?
                if result["exceptionDetails"] != nil {
                    let failure = try XCTUnwrap(error as? BrowserMutationFailure)
                    XCTAssertEqual(failure.dispatchState, .unknown)
                    brokerError = failure.underlyingError as? BrowserTabBrokerError
                } else {
                    brokerError = error as? BrowserTabBrokerError
                }
                guard case .mutationRejected = brokerError else { return XCTFail("Unexpected error: \(error)") }
            }
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, 1)
            XCTAssertEqual(state.remainingSteps, 0)
            try assertExactGroupCleanup(state)
        }
    }

    func testCancellationStillReleasesGroupOnUncancelledOriginalChannel() async throws {
        for afterEnqueue in [false, true] {
            var steps = try DocumentOperationFixture.preparationSteps()
            if afterEnqueue {
                steps.append(.cancel("Runtime.callFunctionOn"))
            } else {
                steps = Array(steps.prefix(8))
                steps.append(.cancel("Page.getFrameTree"))
            }
            steps.append(try .reply("Runtime.releaseObjectGroup", [:]))
            let channel = ScriptedDocumentChannel(steps: steps)
            let operation = Task { try await DocumentOperationFixture.run(.press, channel: channel) }
            do { try await operation.value; XCTFail("Expected cancellation.") }
            catch {
                if afterEnqueue {
                    let failure = try XCTUnwrap(error as? BrowserMutationFailure)
                    XCTAssertEqual(failure.dispatchState, .unknown)
                    XCTAssertTrue(failure.underlyingError is CancellationError)
                } else {
                    XCTAssertTrue(error is CancellationError)
                }
            }
            let state = await channel.state()
            XCTAssertEqual(state.mutationEnqueues, afterEnqueue ? 1 : 0)
            XCTAssertEqual(state.remainingSteps, 0)
            XCTAssertEqual(state.invalidations, 0)
            let cleanup = try XCTUnwrap(state.requests.last)
            XCTAssertEqual(cleanup.method, "Runtime.releaseObjectGroup")
            XCTAssertFalse(cleanup.wasCancelled, "Cleanup must not inherit the cancelled action task.")
            XCTAssertFalse(cleanup.hasPermit)
            try assertExactGroupCleanup(state)
        }
    }

    func testCleanupFailureInvalidatesOriginalChannelAndDoesNotReplayMutation() async throws {
        for mutationFails in [false, true] {
            let result: DocumentChannelStep
            if mutationFails {
                result = .failure("Runtime.callFunctionOn", .mutationFailed)
            } else {
                result = try .reply("Runtime.callFunctionOn", ["result": ["value": true]])
            }
            let channel = ScriptedDocumentChannel(steps: try DocumentOperationFixture.preparationSteps() + [
                result, .failure("Runtime.releaseObjectGroup", .cleanupFailed),
            ])
            let unrelated = ScriptedDocumentChannel(steps: [])
            do {
                try await DocumentOperationFixture.run(.press, channel: channel)
                XCTFail("Cleanup failure must invalidate the channel, not retry input.")
            } catch let error as BrowserMutationFailure {
                XCTAssertEqual(error.dispatchState, mutationFails ? .unknown : .dispatched)
                XCTAssertEqual(error.underlyingError as? DocumentChannelTestError, mutationFails ? .mutationFailed : .cleanupFailed)
            }
            let state = await channel.state()
            let otherState = await unrelated.state()
            XCTAssertEqual(state.invalidations, 1)
            XCTAssertEqual(state.mutationEnqueues, 1)
            XCTAssertEqual(state.requests.map(\.method), DocumentOperationFixture.mutationMethods)
            XCTAssertEqual(state.remainingSteps, 0)
            XCTAssertEqual(otherState.invalidations, 0)
            XCTAssertTrue(otherState.requests.isEmpty)
            try assertExactGroupCleanup(state)
        }
    }

    private func request(_ method: String, from state: DocumentChannelState) throws -> [String: Any] {
        let matches = state.requests.filter { $0.method == method }
        XCTAssertEqual(matches.count, 1)
        return try DocumentOperationFixture.object(XCTUnwrap(matches.first).params)
    }

    private func assertExactGroupCleanup(_ state: DocumentChannelState, file: StaticString = #filePath, line: UInt = #line) throws {
        let group = try XCTUnwrap(request("DOM.resolveNode", from: state)["objectGroup"] as? String)
        XCTAssertTrue(group.hasPrefix("heydash-mutation-"), file: file, line: line)
        XCTAssertEqual(try request("Runtime.releaseObjectGroup", from: state)["objectGroup"] as? String, group, file: file, line: line)
        XCTAssertEqual(state.requests.last?.method, "Runtime.releaseObjectGroup", file: file, line: line)
    }

    private func expectBrokerError(_ expected: BrowserTabBrokerError, channel: ScriptedDocumentChannel) async {
        do {
            try await DocumentOperationFixture.run(.press, channel: channel)
            XCTFail("Expected \(expected).")
        } catch {
            XCTAssertEqual(error as? BrowserTabBrokerError, expected)
        }
    }
}

private enum DocumentOperationFixture {
    enum Action: Sendable { case press, setText(String) }
    static let url = URL(string: "https://example.test/form#anchor")!
    static let target = BrowserTarget(
        targetID: "exact-target", instanceToken: "exact-incarnation", title: "Fixture",
        url: url, webSocketURL: nil
    )
    static let observationMethods = ["Page.getFrameTree", "Accessibility.enable", "Accessibility.getFullAXTree", "DOMSnapshot.captureSnapshot", "Page.getFrameTree"]
    static let mutationMethods = observationMethods + [
        "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Page.getFrameTree",
        "Runtime.callFunctionOn", "Runtime.releaseObjectGroup",
    ]

    static func node(
        role: String = "button", name: String = "Fixture action", value: String? = nil,
        disabled: Bool = false, readOnly: Bool = false, ignored: Bool = false
    ) -> BrowserDocumentNode {
        BrowserDocumentNode(
            backendNodeID: 17, role: role, name: name, value: value,
            isDisabled: disabled, isReadOnly: readOnly, isIgnored: ignored
        )
    }

    static func document(nodes: [BrowserDocumentNode]? = nil) -> BrowserDocumentObservation {
        BrowserDocumentObservation(loaderID: "document-loader", title: target.title, url: url, nodes: nodes ?? [node()])
    }

    static func frame(id: String = "main-frame", loader: String = "document-loader", fragment: String = "#anchor") -> [String: Any] {
        ["frameTree": ["frame": ["id": id, "loaderId": loader, "url": "https://example.test/form", "urlFragment": fragment]]]
    }

    static func observationSteps(nodes: [BrowserDocumentNode]? = nil) throws -> [DocumentChannelStep] {
        let rawNodes = (nodes ?? [node()]).map { node -> [String: Any] in
            var value: [String: Any] = [
                "backendDOMNodeId": node.backendNodeID!, "role": ["value": node.role],
                "name": ["value": node.name], "ignored": node.isIgnored,
                "properties": [
                    ["name": "disabled", "value": ["value": node.isDisabled]],
                    ["name": "readonly", "value": ["value": node.isReadOnly]],
                ],
            ]
            if let text = node.value { value["value"] = ["value": text] }
            if let nodeID = node.nodeID { value["nodeId"] = nodeID }
            if let parent = node.parentNodeID { value["parentId"] = parent }
            value["childIds"] = node.childNodeIDs
            if let link = node.linkURL {
                var properties = value["properties"] as! [[String: Any]]
                properties.append(["name": "url", "value": ["value": link]])
                value["properties"] = properties
            }
            return value
        }
        return try [
            .reply("Page.getFrameTree", frame()), .reply("Accessibility.enable", [:]),
            .reply("Accessibility.getFullAXTree", ["nodes": rawNodes]),
            .reply("DOMSnapshot.captureSnapshot", ["mactopusClickability": [
                "frameId": "main-frame", "documentURL": url.absoluteString,
                "clickableBackendNodeIds": [], "pointerBackendNodeIds": [],
                "sourceTruncated": false, "sourceNodeCount": 100,
            ]]),
            .reply("Page.getFrameTree", frame()),
        ]
    }

    static func preparationSteps(nodes: [BrowserDocumentNode]? = nil) throws -> [DocumentChannelStep] {
        try observationSteps(nodes: nodes) + [
            .reply("Page.getFrameTree", frame()), .reply("Page.createIsolatedWorld", ["executionContextId": 31]),
            .reply("DOM.resolveNode", ["object": ["objectId": "exact-session-object"]]),
            .reply("Page.getFrameTree", frame()),
        ]
    }

    static func successSteps(nodes: [BrowserDocumentNode]? = nil) throws -> [DocumentChannelStep] {
        try preparationSteps(nodes: nodes) + [
            .reply("Runtime.callFunctionOn", ["result": ["value": true]]), .reply("Runtime.releaseObjectGroup", [:]),
        ]
    }

    static func run(_ action: Action, channel: ScriptedDocumentChannel, nodes: [BrowserDocumentNode]? = nil) async throws {
        let operations = BrowserCDPDocumentOperations()
        switch action {
        case .press:
            try await operations.press(target: target, backendNodeID: 17, document: document(nodes: nodes), permit: BrowserMutationPermit(), socket: channel)
        case .setText(let text):
            try await operations.setText(target: target, backendNodeID: 17, text: text, document: document(nodes: nodes), permit: BrowserMutationPermit(), socket: channel)
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum DocumentChannelTestError: Error, Equatable, Sendable {
    case mutationFailed, cleanupFailed, invalidated, exhausted
    case unexpectedMethod(expected: String, actual: String)
}

private struct DocumentChannelStep: Sendable {
    enum Response: Sendable { case bytes(Data), failure(DocumentChannelTestError), cancel, unsupported }
    let method: String
    let response: Response

    static func reply(_ method: String, _ object: [String: Any]) throws -> Self {
        Self(method: method, response: .bytes(try JSONSerialization.data(withJSONObject: object)))
    }
    static func failure(_ method: String, _ error: DocumentChannelTestError) -> Self { Self(method: method, response: .failure(error)) }
    static func cancel(_ method: String) -> Self { Self(method: method, response: .cancel) }
}

private struct DocumentChannelRequest: Sendable {
    let method: String
    let params: Data
    let hasPermit: Bool
    let wasCancelled: Bool
}

private struct DocumentChannelState: Sendable {
    let requests: [DocumentChannelRequest]
    let mutationEnqueues: Int
    let invalidations: Int
    let remainingSteps: Int
}

private actor ScriptedDocumentChannel: BrowserDocumentChannel {
    private var steps: [DocumentChannelStep]
    private var requests: [DocumentChannelRequest] = []
    private var mutationEnqueues = 0
    private var invalidations = 0

    init(steps: [DocumentChannelStep]) { self.steps = steps }

    func request(method: String, params: Data, permit: BrowserMutationPermit?) async throws -> Data {
        requests.append(DocumentChannelRequest(method: method, params: params, hasPermit: permit != nil, wasCancelled: Task.isCancelled))
        try Task.checkCancellation()
        guard invalidations == 0 else { throw DocumentChannelTestError.invalidated }
        guard !steps.isEmpty else { throw DocumentChannelTestError.exhausted }
        let step = steps.removeFirst()
        guard step.method == method else { throw DocumentChannelTestError.unexpectedMethod(expected: step.method, actual: method) }
        if let permit { try permit.commit { mutationEnqueues += 1 } }
        switch step.response {
        case .unsupported: throw ChromeBridgeIPC.Failure.unsupportedCommand
        case .bytes(let data): return data
        case .failure(let error): throw error
        case .cancel:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
    }

    func invalidate() { invalidations += 1 }
    func state() -> DocumentChannelState {
        DocumentChannelState(requests: requests, mutationEnqueues: mutationEnqueues, invalidations: invalidations, remainingSteps: steps.count)
    }
}
