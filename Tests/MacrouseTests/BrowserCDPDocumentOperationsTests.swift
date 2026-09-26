import Foundation
import XCTest
@testable import Macrouse

/// Deterministic channel-contract tests, not a claim of trusted physical input
/// or successful DOM execution in a live browser.
final class BrowserCDPDocumentOperationsTests: XCTestCase {
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
        XCTAssertEqual(try DocumentOperationFixture.object(tree.params)["depth"] as? Int, 16)
    }

    func testObservationRejectsFrameDrift() async throws {
        var steps = try DocumentOperationFixture.observationSteps()
        steps[3] = try .reply("Page.getFrameTree", DocumentOperationFixture.frame(loader: "new-loader"))
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
            steps[7] = try .reply("Page.getFrameTree", changedFrame)
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
            } catch let error as DocumentChannelTestError { XCTAssertEqual(error, .mutationFailed) }
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
            } catch let error as BrowserTabBrokerError {
                guard case .mutationRejected = error else { return XCTFail("Unexpected error: \(error)") }
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
                steps = Array(steps.prefix(7))
                steps.append(.cancel("Page.getFrameTree"))
            }
            steps.append(try .reply("Runtime.releaseObjectGroup", [:]))
            let channel = ScriptedDocumentChannel(steps: steps)
            let operation = Task { try await DocumentOperationFixture.run(.press, channel: channel) }
            do { try await operation.value; XCTFail("Expected cancellation.") } catch is CancellationError { }
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
            } catch let error as DocumentChannelTestError {
                XCTAssertEqual(error, mutationFails ? .mutationFailed : .cleanupFailed)
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
    static let observationMethods = ["Page.getFrameTree", "Accessibility.enable", "Accessibility.getFullAXTree", "Page.getFrameTree"]
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
            return value
        }
        return try [
            .reply("Page.getFrameTree", frame()), .reply("Accessibility.enable", [:]),
            .reply("Accessibility.getFullAXTree", ["nodes": rawNodes]), .reply("Page.getFrameTree", frame()),
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
    enum Response: Sendable { case bytes(Data), failure(DocumentChannelTestError), cancel }
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
