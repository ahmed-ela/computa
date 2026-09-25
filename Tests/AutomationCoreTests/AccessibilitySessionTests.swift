import ApplicationServices
import Foundation
import XCTest
@testable import AutomationCore

private final class FakeAccessibilityNode: NSObject {
    let identifier: String
    let role: String
    var title: String?
    var value: String?
    var url: String?
    var reportedIdentifier: String?
    var domIdentifier: String?
    var children: [FakeAccessibilityNode]
    var snapshotActions: [String]
    var currentActions: [String]
    var snapshotValueSettable: Bool
    var currentValueSettable: Bool
    var descriptionWasTruncated: Bool

    init(
        identifier: String,
        role: String = "AXGroup",
        title: String? = nil,
        value: String? = nil,
        children: [FakeAccessibilityNode] = [],
        actions: [String] = [],
        valueSettable: Bool = false,
        descriptionWasTruncated: Bool = false,
        url: String? = nil
    ) {
        self.identifier = identifier
        self.role = role
        self.title = title
        self.value = value
        self.url = url
        reportedIdentifier = identifier
        domIdentifier = nil
        self.children = children
        snapshotActions = actions
        currentActions = actions
        snapshotValueSettable = valueSettable
        currentValueSettable = valueSettable
        self.descriptionWasTruncated = descriptionWasTruncated
    }
}

private final class FakeAccessibilityTreeRuntime: AccessibilityTreeRuntime {
    var root: FakeAccessibilityNode
    var focusedProcessIdentifier: Int32?
    var focusedWindowNode: FakeAccessibilityNode?
    var applicationElementRequests = [Int32]()
    var focusedWindowRequests = [Int32]()
    var describedNodeIDs = [String]()
    var childRequests = [(nodeID: String, limit: Int)]()
    var supportedActionRequests = [String]()
    var valueSettableRequests = [String]()
    var performedActions = [(nodeID: String, action: String)]()
    var setValues = [(nodeID: String, value: AccessibilitySetValue)]()
    var beforeDescribe: ((FakeAccessibilityNode) throws -> Void)?

    init(root: FakeAccessibilityNode) {
        self.root = root
    }

    func applicationElement(processIdentifier: Int32) throws -> AccessibilityElementHandle {
        applicationElementRequests.append(processIdentifier)
        return AccessibilityElementHandle(root)
    }

    func applicationIsFrontmost(processIdentifier: Int32) throws -> Bool {
        focusedProcessIdentifier == processIdentifier
    }

    func focusedWindow(processIdentifier: Int32) throws -> AccessibilityElementHandle? {
        focusedWindowRequests.append(processIdentifier)
        return focusedWindowNode.map(AccessibilityElementHandle.init)
    }

    func describe(
        _ element: AccessibilityElementHandle,
        limits: AccessibilityTreeLimits
    ) throws -> AccessibilityElementDescription {
        let node = try node(from: element)
        describedNodeIDs.append(node.identifier)
        try beforeDescribe?(node)
        let linkURL = node.role == "AXLink"
            ? AccessibilityObservedLinkURL.validate(node.url as NSString?)
            : (value: nil, wasTruncated: false, identity: nil)
        return AccessibilityElementDescription(
            role: node.role,
            subrole: nil,
            title: node.title,
            elementDescription: nil,
            help: nil,
            identifier: node.reportedIdentifier,
            domIdentifier: node.domIdentifier,
            value: node.value,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            supportedActions: node.snapshotActions,
            isValueSettable: node.snapshotValueSettable,
            wasTruncated: node.descriptionWasTruncated || linkURL.wasTruncated,
            url: linkURL.value,
            urlIdentity: linkURL.identity
        )
    }

    func children(
        of element: AccessibilityElementHandle,
        limit: Int
    ) throws -> AccessibilityChildBatch {
        let node = try node(from: element)
        childRequests.append((node.identifier, limit))
        let boundedLimit = max(0, limit)
        return AccessibilityChildBatch(
            elements: node.children.prefix(boundedLimit).map(AccessibilityElementHandle.init),
            wasTruncated: node.children.count > boundedLimit
        )
    }

    func representsSameElement(
        _ lhs: AccessibilityElementHandle,
        _ rhs: AccessibilityElementHandle
    ) -> Bool {
        guard
            let left = lhs.storage as? FakeAccessibilityNode,
            let right = rhs.storage as? FakeAccessibilityNode
        else {
            return false
        }
        return left === right
    }

    func identityHash(for element: AccessibilityElementHandle) -> Int {
        guard let node = element.storage as? FakeAccessibilityNode else {
            return 0
        }
        return ObjectIdentifier(node).hashValue
    }

    func supportedActions(for element: AccessibilityElementHandle) throws -> [String] {
        let node = try node(from: element)
        supportedActionRequests.append(node.identifier)
        return node.currentActions
    }

    func perform(action: String, on element: AccessibilityElementHandle) throws {
        performedActions.append((try node(from: element).identifier, action))
    }

    func isValueSettable(on element: AccessibilityElementHandle) throws -> Bool {
        let node = try node(from: element)
        valueSettableRequests.append(node.identifier)
        return node.currentValueSettable
    }

    func set(value: AccessibilitySetValue, on element: AccessibilityElementHandle) throws {
        setValues.append((try node(from: element).identifier, value))
    }

    private func node(from handle: AccessibilityElementHandle) throws -> FakeAccessibilityNode {
        guard let node = handle.storage as? FakeAccessibilityNode else {
            throw AutomationError.unexpectedAttributeType(attribute: "FakeAccessibilityNode")
        }
        return node
    }
}

final class AccessibilitySessionTests: XCTestCase {
    private let target = AccessibilityApplicationTarget(
        processIdentifier: 4_242,
        bundleIdentifier: "example.fake",
        applicationName: "Fake App"
    )

    func testSnapshotUsesDeterministicPreorderIndicesAndRelationships() throws {
        let grandchild = FakeAccessibilityNode(identifier: "grandchild", role: "AXStaticText")
        let firstChild = FakeAccessibilityNode(
            identifier: "first",
            role: "AXGroup",
            children: [grandchild]
        )
        let secondChild = FakeAccessibilityNode(identifier: "second", role: "AXButton")
        let root = FakeAccessibilityNode(identifier: "root", children: [firstChild, secondChild])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)

        let first = try session.snapshot(limits: generousLimits())
        let second = try session.snapshot(limits: generousLimits())

        XCTAssertEqual(first.rootIndex, 0)
        XCTAssertEqual(first.elements.map(\.identifier), ["root", "first", "grandchild", "second"])
        XCTAssertEqual(second.elements.map(\.identifier), first.elements.map(\.identifier))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.elements.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(first.elements.map(\.parentIndex), [nil, 0, 1, 0])
        XCTAssertEqual(first.elements.map(\.childIndices), [[1, 3], [2], [], []])
        XCTAssertEqual(first.elements.map(\.depth), [0, 1, 2, 1])
        XCTAssertEqual(runtime.applicationElementRequests, [target.processIdentifier, target.processIdentifier])
    }

    func testSnapshotRetriesDetachedChildWithAnEntirelyFreshTraversalOfSameWindow() throws {
        let discarded = FakeAccessibilityNode(identifier: "discarded", role: "AXButton", actions: ["AXPress"])
        let detached = FakeAccessibilityNode(identifier: "detached")
        let replacement = FakeAccessibilityNode(identifier: "replacement", role: "AXButton", actions: ["AXPress"])
        let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [discarded, detached])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        runtime.beforeDescribe = { node in
            if node === detached {
                root.children = [replacement]
                throw AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.invalidUIElement.rawValue)
            }
        }
        let session = makeSession(runtime: runtime)

        let snapshot = try session.snapshot(limits: generousLimits())

        XCTAssertEqual(runtime.describedNodeIDs, ["window", "discarded", "detached", "window", "replacement"])
        XCTAssertEqual(snapshot.elements.map(\.identifier), ["window", "replacement"])
        XCTAssertEqual(snapshot.elements.map(\.index), [0, 1])
        XCTAssertEqual(snapshot.elements.map(\.childIndices), [[1], []])
        XCTAssertEqual(runtime.applicationElementRequests.count, 3)
        XCTAssertTrue(runtime.performedActions.isEmpty)
        try session.perform(.press, at: 1, in: snapshot)
        XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["replacement"])
    }

    func testSnapshotStopsAfterSecondDetachedChildError() throws {
        let child = FakeAccessibilityNode(identifier: "detached")
        let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [child])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let expected = AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.invalidUIElement.rawValue)
        runtime.beforeDescribe = { node in
            if node === child { throw expected }
        }

        XCTAssertThrowsError(try makeSession(runtime: runtime).snapshot()) {
            XCTAssertEqual($0 as? AutomationError, expected)
        }
        XCTAssertEqual(runtime.describedNodeIDs, ["window", "detached", "window", "detached"])
        XCTAssertEqual(runtime.applicationElementRequests.count, 2)
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testSnapshotDoesNotRetryOtherAccessibilityErrors() throws {
        for expected in [
            AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.cannotComplete.rawValue),
            .accessibilityFailure(operation: "read AXSubrole", code: AXError.apiDisabled.rawValue),
            .permissionNotGranted(.accessibility),
        ] {
            let child = FakeAccessibilityNode(identifier: "child")
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [child])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            runtime.beforeDescribe = { node in
                if node === child { throw expected }
            }

            XCTAssertThrowsError(try makeSession(runtime: runtime).snapshot()) {
                XCTAssertEqual($0 as? AutomationError, expected)
            }
            XCTAssertEqual(runtime.describedNodeIDs, ["window", "child"])
            XCTAssertEqual(runtime.applicationElementRequests.count, 1)
        }
    }

    func testSnapshotDoesNotRetryNonWindowOrUnidentifiedRoot() throws {
        for failureAtRoot in [false, true] {
            let child = FakeAccessibilityNode(identifier: "child")
            let root = FakeAccessibilityNode(
                identifier: "root", role: failureAtRoot ? "AXWindow" : "AXApplication", children: [child]
            )
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let expected = AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.invalidUIElement.rawValue)
            runtime.beforeDescribe = { node in
                if node === (failureAtRoot ? root : child) { throw expected }
            }

            XCTAssertThrowsError(try makeSession(runtime: runtime).snapshot()) {
                XCTAssertEqual($0 as? AutomationError, expected)
            }
            XCTAssertEqual(runtime.applicationElementRequests.count, 1)
            XCTAssertEqual(runtime.describedNodeIDs, failureAtRoot ? ["root"] : ["root", "child"])
        }
    }

    func testSnapshotRejectsRootChangeBeforeOrDuringRetry() throws {
        for changeBeforeRetry in [true, false] {
            let child = FakeAccessibilityNode(identifier: "child")
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [child])
            let otherRoot = FakeAccessibilityNode(identifier: "other", role: "AXWindow")
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            var childReads = 0
            runtime.beforeDescribe = { node in
                guard node === child else { return }
                childReads += 1
                if childReads == 1 {
                    if changeBeforeRetry { runtime.root = otherRoot }
                    throw AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.invalidUIElement.rawValue)
                }
                runtime.root = otherRoot
            }

            XCTAssertThrowsError(try makeSession(runtime: runtime).snapshot()) {
                XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
            }
            XCTAssertEqual(childReads, changeBeforeRetry ? 1 : 2)
            XCTAssertEqual(runtime.applicationElementRequests.count, changeBeforeRetry ? 2 : 3)
            XCTAssertTrue(runtime.performedActions.isEmpty)
        }
    }

    func testSnapshotRetryRechecksPermissionBeforeAndAfterSecondTraversal() throws {
        for revokeBeforeRetry in [true, false] {
            let child = FakeAccessibilityNode(identifier: "child")
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [child])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            var permissionGranted = true
            var childReads = 0
            runtime.beforeDescribe = { node in
                guard node === child else { return }
                childReads += 1
                if childReads == 1 {
                    if revokeBeforeRetry { permissionGranted = false }
                    throw AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.invalidUIElement.rawValue)
                }
                permissionGranted = false
            }
            let session = AccessibilitySession(target: target, runtime: runtime, accessibilityCheck: { permissionGranted })

            XCTAssertThrowsError(try session.snapshot()) {
                XCTAssertEqual($0 as? AutomationError, .permissionNotGranted(.accessibility))
            }
            XCTAssertEqual(childReads, revokeBeforeRetry ? 1 : 2)
            XCTAssertEqual(runtime.applicationElementRequests.count, revokeBeforeRetry ? 1 : 2)
        }
    }

    func testSnapshotRetryInvalidatesPreviousSnapshotOnSuccessAndFailure() throws {
        for retrySucceeds in [true, false] {
            let child = FakeAccessibilityNode(identifier: "child", role: "AXButton", actions: ["AXPress"])
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [child])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let previous = try session.snapshot()
            var childReads = 0
            runtime.beforeDescribe = { node in
                guard node === child else { return }
                childReads += 1
                if childReads == 1 || !retrySucceeds {
                    throw AutomationError.accessibilityFailure(operation: "read AXSubrole", code: AXError.invalidUIElement.rawValue)
                }
            }

            if retrySucceeds {
                let recovered = try session.snapshot()
                XCTAssertNotEqual(recovered.id, previous.id)
            } else {
                XCTAssertThrowsError(try session.snapshot())
            }
            XCTAssertThrowsError(try session.perform(.press, at: 1, in: previous)) {
                XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
            }
            XCTAssertTrue(runtime.performedActions.isEmpty)
        }
    }

    func testSnapshotStopsAtElementLimitAndMarksTruncation() throws {
        let root = FakeAccessibilityNode(
            identifier: "root",
            children: [
                FakeAccessibilityNode(identifier: "one"),
                FakeAccessibilityNode(identifier: "two"),
                FakeAccessibilityNode(identifier: "three"),
            ]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let limits = try AccessibilityTreeLimits(
            maxDepth: 4,
            maxElements: 2,
            maxChildrenPerElement: 10,
            maxActionsPerElement: 8,
            maxTextLength: 32
        )

        let snapshot = try session.snapshot(limits: limits)

        XCTAssertEqual(snapshot.elements.map(\.identifier), ["root", "one"])
        XCTAssertEqual(snapshot.elements[0].childIndices, [1])
        XCTAssertTrue(snapshot.wasTruncated)
    }

    func testSnapshotEnforcesDepthAndPerElementChildBounds() throws {
        let depthGrandchild = FakeAccessibilityNode(identifier: "depth-grandchild")
        let first = FakeAccessibilityNode(identifier: "first", children: [depthGrandchild])
        let root = FakeAccessibilityNode(
            identifier: "root",
            children: [
                first,
                FakeAccessibilityNode(identifier: "second"),
                FakeAccessibilityNode(identifier: "omitted-third"),
            ]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let limits = try AccessibilityTreeLimits(
            maxDepth: 1,
            maxElements: 20,
            maxChildrenPerElement: 2,
            maxActionsPerElement: 8,
            maxTextLength: 32
        )

        let snapshot = try session.snapshot(limits: limits)

        XCTAssertEqual(snapshot.elements.map(\.identifier), ["root", "first", "second"])
        XCTAssertEqual(snapshot.elements[0].childIndices, [1, 2])
        XCTAssertTrue(snapshot.wasTruncated)
        XCTAssertEqual(runtime.childRequests.map(\.nodeID), ["root", "first", "second"])
        XCTAssertEqual(runtime.childRequests.map(\.limit), [2, 0, 0])
    }

    func testAgentDefaultReachesChromeStyleWebControlAtDepthNine() throws {
        let button = FakeAccessibilityNode(
            identifier: "fixture-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        var root = button
        for depth in (0..<9).reversed() {
            root = FakeAccessibilityNode(
                identifier: "container-\(depth)",
                children: [root]
            )
        }
        let runtime = FakeAccessibilityTreeRuntime(root: root)

        let snapshot = try makeSession(runtime: runtime).snapshot()

        XCTAssertEqual(snapshot.elements.last?.depth, 9)
        XCTAssertEqual(snapshot.elements.last?.identifier, "fixture-button")
        XCTAssertEqual(snapshot.elements.last?.supportedActions, [SemanticAXAction.press.rawValue])
        XCTAssertFalse(snapshot.wasTruncated)
    }

    func testSnapshotSuppressesCyclesWithoutDuplicatingIndices() throws {
        let root = FakeAccessibilityNode(identifier: "root")
        let child = FakeAccessibilityNode(identifier: "child")
        root.children = [child]
        child.children = [root]
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)

        let snapshot = try session.snapshot(limits: generousLimits())

        XCTAssertEqual(snapshot.elements.map(\.identifier), ["root", "child"])
        XCTAssertEqual(snapshot.elements.map(\.childIndices), [[1], []])
        XCTAssertFalse(snapshot.wasTruncated)
    }

    func testPermissionFailureDoesNotCreateOrInspectApplicationElement() {
        let runtime = FakeAccessibilityTreeRuntime(root: FakeAccessibilityNode(identifier: "root"))
        let session = AccessibilitySession(
            target: target,
            runtime: runtime,
            accessibilityCheck: { false }
        )

        XCTAssertThrowsError(try session.snapshot()) { error in
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertTrue(runtime.applicationElementRequests.isEmpty)
        XCTAssertTrue(runtime.describedNodeIDs.isEmpty)
    }

    func testPerformRechecksCurrentSupportAndUsesExactSnapshotIndex() throws {
        let button = FakeAccessibilityNode(
            identifier: "button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        let runtime = FakeAccessibilityTreeRuntime(
            root: FakeAccessibilityNode(identifier: "root", children: [button])
        )
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())
        button.currentActions = []

        XCTAssertThrowsError(try session.perform(.press, at: 1, in: snapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .unsupportedAction(SemanticAXAction.press.rawValue))
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)

        button.currentActions = [SemanticAXAction.press.rawValue]
        let refreshedSnapshot = try session.snapshot(limits: generousLimits())
        try session.perform(.press, at: 1, in: refreshedSnapshot)

        XCTAssertEqual(runtime.supportedActionRequests, ["button", "button"])
        XCTAssertEqual(runtime.performedActions.count, 1)
        XCTAssertEqual(runtime.performedActions[0].nodeID, "button")
        XCTAssertEqual(runtime.performedActions[0].action, SemanticAXAction.press.rawValue)
        XCTAssertThrowsError(try session.perform(.press, at: 1, in: refreshedSnapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
    }

    func testFocusStateRequiresExpectedApplicationAndExactSnapshotWindow() throws {
        let root = FakeAccessibilityNode(identifier: "window", role: kAXWindowRole as String)
        let otherWindow = FakeAccessibilityNode(identifier: "other", role: kAXWindowRole as String)
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())

        runtime.focusedProcessIdentifier = 7
        runtime.focusedWindowNode = root
        XCTAssertEqual(try session.focusState(in: snapshot), .applicationNotFocused)

        runtime.focusedProcessIdentifier = target.processIdentifier
        runtime.focusedWindowNode = otherWindow
        XCTAssertEqual(try session.focusState(in: snapshot), .windowNotFocused)

        runtime.focusedWindowNode = root
        XCTAssertEqual(try session.focusState(in: snapshot), .focused)
        XCTAssertEqual(
            runtime.focusedWindowRequests,
            [target.processIdentifier, target.processIdentifier]
        )
    }

    func testNonWindowSnapshotNeedsNoWindowFocusPreparation() throws {
        let runtime = FakeAccessibilityTreeRuntime(
            root: FakeAccessibilityNode(identifier: "application", role: kAXApplicationRole as String)
        )
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())

        XCTAssertEqual(try session.focusState(in: snapshot), .notWindow)
        XCTAssertFalse(try session.raiseSnapshotWindow(in: snapshot))
        XCTAssertTrue(runtime.focusedWindowRequests.isEmpty)
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRaiseSnapshotWindowPreservesApprovedTargetSnapshot() throws {
        let button = FakeAccessibilityNode(
            identifier: "button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        let root = FakeAccessibilityNode(
            identifier: "window",
            role: kAXWindowRole as String,
            children: [button],
            actions: [kAXRaiseAction as String]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())

        XCTAssertTrue(try session.raiseSnapshotWindow(in: snapshot))
        try session.perform(.press, at: 1, in: snapshot)

        XCTAssertEqual(runtime.performedActions.count, 2)
        XCTAssertEqual(runtime.performedActions[0].nodeID, "window")
        XCTAssertEqual(runtime.performedActions[0].action, kAXRaiseAction as String)
        XCTAssertEqual(runtime.performedActions[1].nodeID, "button")
        XCTAssertEqual(runtime.performedActions[1].action, SemanticAXAction.press.rawValue)
    }

    func testRaiseSnapshotWindowFailsClosedWhenRaiseIsNoLongerSupported() throws {
        let root = FakeAccessibilityNode(
            identifier: "window",
            role: kAXWindowRole as String,
            actions: [kAXRaiseAction as String]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())
        root.currentActions = []

        XCTAssertThrowsError(try session.raiseSnapshotWindow(in: snapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .unsupportedAction(kAXRaiseAction as String))
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRebindsToUniqueCurrentElementInSameRoot() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = "verify"
        let root = FakeAccessibilityNode(
            identifier: "window",
            role: kAXWindowRole as String,
            children: [oldButton],
            actions: [kAXRaiseAction as String]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())
        let replacementButton = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacementButton.reportedIdentifier = "verify"
        root.children = [replacementButton]

        let refreshed = try session.refreshTarget(at: 1, in: approvedSnapshot)
        try session.perform(.press, at: refreshed.index, in: refreshed.snapshot)

        XCTAssertEqual(runtime.performedActions.count, 1)
        XCTAssertEqual(runtime.performedActions[0].nodeID, "replacement-button")
        XCTAssertTrue(runtime.supportedActionRequests.contains("replacement-button"))
    }

    func testRefreshTargetRebindsRecreatedControlWithinSameWebDocument() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = nil
        oldButton.domIdentifier = "verify"
        let document = FakeAccessibilityNode(
            identifier: "document",
            role: "AXWebArea",
            children: [oldButton]
        )
        let root = FakeAccessibilityNode(
            identifier: "window",
            role: kAXWindowRole as String,
            children: [document]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime, application: chromeTarget)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let replacementButton = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacementButton.reportedIdentifier = nil
        replacementButton.domIdentifier = "verify"
        document.children = [replacementButton]

        try session.refreshAndPerform(.press, at: 2, in: approvedSnapshot)

        XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["replacement-button"])
    }

    func testRefreshTargetRejectsSameDOMIdentifierInAnotherChromeTab() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = nil
        oldButton.domIdentifier = "verify"
        let approvedDocument = FakeAccessibilityNode(
            identifier: "approved-document",
            role: "AXWebArea",
            children: [oldButton]
        )
        let root = FakeAccessibilityNode(
            identifier: "window",
            role: kAXWindowRole as String,
            children: [approvedDocument]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime, application: chromeTarget)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let otherButton = FakeAccessibilityNode(
            identifier: "other-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        otherButton.reportedIdentifier = nil
        otherButton.domIdentifier = "verify"
        let otherDocument = FakeAccessibilityNode(
            identifier: "other-document",
            role: "AXWebArea",
            children: [otherButton]
        )
        approvedDocument.children = []
        root.children = [approvedDocument, otherDocument]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 2, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRejectsChromeLogicalRebindWithoutDocumentAncestor() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = nil
        oldButton.domIdentifier = "verify"
        let root = FakeAccessibilityNode(
            identifier: "window",
            role: kAXWindowRole as String,
            children: [oldButton]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime, application: chromeTarget)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let otherButton = FakeAccessibilityNode(
            identifier: "other-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        otherButton.reportedIdentifier = nil
        otherButton.domIdentifier = "verify"
        root.children = [otherButton]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRejectsChromeAXIdentifierWithoutDocumentAncestor() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = "verify"
        let root = FakeAccessibilityNode(identifier: "window", children: [oldButton])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime, application: chromeTarget)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let replacement = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacement.reportedIdentifier = "verify"
        root.children = [replacement]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRejectsLogicalRebindWhenApplicationIdentityIsUnknown() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = "verify"
        let root = FakeAccessibilityNode(identifier: "window", children: [oldButton])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let unknownApplication = AccessibilityApplicationTarget(processIdentifier: 4_242)
        let session = makeSession(runtime: runtime, application: unknownApplication)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let replacement = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacement.reportedIdentifier = "verify"
        root.children = [replacement]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRejectsDOMIdentifierWithoutDocumentWhenBundleIsUnknown() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = nil
        oldButton.domIdentifier = "verify"
        let root = FakeAccessibilityNode(identifier: "window", children: [oldButton])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let replacement = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacement.reportedIdentifier = nil
        replacement.domIdentifier = "verify"
        root.children = [replacement]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRejectsIdentifiersAtTextLengthCutoff() throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 2,
            maxElements: 10,
            maxChildrenPerElement: 5,
            maxActionsPerElement: 5,
            maxTextLength: 4
        )
        for identifierKind in ["AX", "DOM"] {
            let oldButton = FakeAccessibilityNode(
                identifier: "old-button",
                role: "AXButton",
                title: "test",
                actions: [SemanticAXAction.press.rawValue],
                descriptionWasTruncated: true
            )
            oldButton.reportedIdentifier = identifierKind == "AX" ? "veri" : nil
            oldButton.domIdentifier = identifierKind == "DOM" ? "veri" : nil
            let root = FakeAccessibilityNode(identifier: "window", children: [oldButton])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let approvedSnapshot = try session.snapshot(limits: limits)

            let replacement = FakeAccessibilityNode(
                identifier: "replacement-button",
                role: "AXButton",
                title: "test",
                actions: [SemanticAXAction.press.rawValue],
                descriptionWasTruncated: true
            )
            replacement.reportedIdentifier = oldButton.reportedIdentifier
            replacement.domIdentifier = oldButton.domIdentifier
            root.children = [replacement]

            XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
                error in
                XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
            }
            XCTAssertTrue(runtime.performedActions.isEmpty, identifierKind)
        }
    }

    func testRefreshTargetPrefersExactIdentityWithoutStableIdentifier() throws {
        let button = FakeAccessibilityNode(
            identifier: "button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        button.reportedIdentifier = nil
        let root = FakeAccessibilityNode(identifier: "window", children: [button])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        let refreshed = try session.refreshTarget(at: 1, in: approvedSnapshot)
        try session.perform(.press, at: refreshed.index, in: refreshed.snapshot)

        XCTAssertEqual(runtime.performedActions.count, 1)
        XCTAssertEqual(runtime.performedActions[0].nodeID, "button")
    }

    func testRefreshTargetRejectsLogicalMatchWhenDuplicateIsHiddenPastElementBound() throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 2,
            maxElements: 2,
            maxChildrenPerElement: 3,
            maxActionsPerElement: 5,
            maxTextLength: 100
        )
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = "verify"
        let root = FakeAccessibilityNode(identifier: "window", children: [oldButton])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: limits)
        XCTAssertFalse(approvedSnapshot.wasTruncated)

        let replacement = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacement.reportedIdentifier = "verify"
        let hiddenDuplicate = FakeAccessibilityNode(
            identifier: "hidden-duplicate",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        hiddenDuplicate.reportedIdentifier = "verify"
        root.children = [replacement, hiddenDuplicate]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertFalse(runtime.describedNodeIDs.contains("hidden-duplicate"))
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetRejectsLogicalMatchWhenApprovedTreeWasIncomplete() throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 2,
            maxElements: 2,
            maxChildrenPerElement: 3,
            maxActionsPerElement: 5,
            maxTextLength: 100
        )
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = "verify"
        let hiddenSibling = FakeAccessibilityNode(identifier: "hidden-sibling")
        let root = FakeAccessibilityNode(identifier: "window", children: [oldButton, hiddenSibling])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: limits)
        XCTAssertTrue(approvedSnapshot.wasTruncated)

        let replacement = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacement.reportedIdentifier = "verify"
        root.children = [replacement]

        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)) {
            error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetAllowsExactIdentityInIncompleteTrees() throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 2,
            maxElements: 2,
            maxChildrenPerElement: 3,
            maxActionsPerElement: 5,
            maxTextLength: 100
        )
        let button = FakeAccessibilityNode(
            identifier: "button",
            role: "AXButton",
            actions: [SemanticAXAction.press.rawValue]
        )
        let hiddenSibling = FakeAccessibilityNode(identifier: "hidden-sibling")
        let root = FakeAccessibilityNode(identifier: "window", children: [button, hiddenSibling])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: limits)
        XCTAssertTrue(approvedSnapshot.wasTruncated)

        try session.refreshAndPerform(.press, at: 1, in: approvedSnapshot)

        XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["button"])
    }

    func testRefreshTargetFailsClosedWhenRetainedIdentityDriftsBesideLookalike() throws {
        let originalButton = FakeAccessibilityNode(
            identifier: "original-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        originalButton.reportedIdentifier = nil
        originalButton.domIdentifier = "verify"
        let root = FakeAccessibilityNode(identifier: "window", children: [originalButton])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())

        originalButton.title = "Different action"
        let lookalike = FakeAccessibilityNode(
            identifier: "lookalike-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        lookalike.reportedIdentifier = nil
        lookalike.domIdentifier = "verify"
        root.children = [originalButton, lookalike]

        XCTAssertThrowsError(try session.refreshTarget(at: 1, in: approvedSnapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetFailsClosedWhenCurrentTargetIsMissing() throws {
        let button = FakeAccessibilityNode(
            identifier: "verify",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        let root = FakeAccessibilityNode(identifier: "window", children: [button])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())
        root.children = []

        XCTAssertThrowsError(try session.refreshTarget(at: 1, in: approvedSnapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetFailsClosedWhenCurrentTargetIsAmbiguous() throws {
        func fixtureButton() -> FakeAccessibilityNode {
            FakeAccessibilityNode(
                identifier: "verify",
                role: "AXButton",
                title: "Complete computer-use test",
                actions: [SemanticAXAction.press.rawValue]
            )
        }
        let root = FakeAccessibilityNode(identifier: "window", children: [fixtureButton()])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())
        root.children = [fixtureButton(), fixtureButton()]

        XCTAssertThrowsError(try session.refreshTarget(at: 1, in: approvedSnapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testRefreshTargetDoesNotFallBackToLabelWithoutStableIdentifier() throws {
        let oldButton = FakeAccessibilityNode(
            identifier: "old-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        oldButton.reportedIdentifier = nil
        let root = FakeAccessibilityNode(identifier: "window", children: [oldButton])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approvedSnapshot = try session.snapshot(limits: generousLimits())
        let replacement = FakeAccessibilityNode(
            identifier: "replacement-button",
            role: "AXButton",
            title: "Complete computer-use test",
            actions: [SemanticAXAction.press.rawValue]
        )
        replacement.reportedIdentifier = nil
        root.children = [replacement]

        XCTAssertThrowsError(try session.refreshTarget(at: 1, in: approvedSnapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testPerformRejectsActionNotAdvertisedBySnapshotWithoutRuntimeMutation() throws {
        let button = FakeAccessibilityNode(identifier: "button", role: "AXButton")
        button.currentActions = [SemanticAXAction.press.rawValue]
        let runtime = FakeAccessibilityTreeRuntime(root: button)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())

        XCTAssertThrowsError(try session.perform(.press, at: 0, in: snapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .unsupportedAction(SemanticAXAction.press.rawValue))
        }
        XCTAssertTrue(runtime.supportedActionRequests.isEmpty)
        XCTAssertTrue(runtime.performedActions.isEmpty)
        XCTAssertThrowsError(try session.perform(.press, at: 0, in: snapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
    }

    func testNewSnapshotInvalidatesEarlierSnapshotAndUnknownIndexIsRejected() throws {
        let runtime = FakeAccessibilityTreeRuntime(root: FakeAccessibilityNode(identifier: "root"))
        let session = makeSession(runtime: runtime)
        let first = try session.snapshot(limits: generousLimits())
        let second = try session.snapshot(limits: generousLimits())

        XCTAssertThrowsError(try session.perform(.press, at: 0, in: first)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertThrowsError(try session.perform(.press, at: 99, in: second)) { error in
            XCTAssertEqual(error as? AutomationError, .accessibilityElementIndexNotFound(99))
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testMutationRejectsTamperedSnapshotEvenWhenIdentifierMatches() throws {
        let root = FakeAccessibilityNode(
            identifier: "root",
            actions: [SemanticAXAction.press.rawValue]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())
        let tampered = AccessibilityTreeSnapshot(
            id: snapshot.id,
            application: snapshot.application,
            limits: snapshot.limits,
            rootIndex: snapshot.rootIndex,
            elements: [],
            wasTruncated: snapshot.wasTruncated
        )

        XCTAssertThrowsError(try session.perform(.press, at: 0, in: tampered)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
        XCTAssertTrue(runtime.supportedActionRequests.isEmpty)
        XCTAssertTrue(runtime.performedActions.isEmpty)

        try session.perform(.press, at: 0, in: snapshot)
        XCTAssertEqual(runtime.performedActions.count, 1)
    }

    func testMutationRechecksPermissionWithoutTouchingRuntimeAndInvalidatesSnapshot() throws {
        let root = FakeAccessibilityNode(
            identifier: "root",
            actions: [SemanticAXAction.press.rawValue]
        )
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        var permissionGranted = true
        let session = AccessibilitySession(
            target: target,
            runtime: runtime,
            accessibilityCheck: { permissionGranted }
        )
        let snapshot = try session.snapshot(limits: generousLimits())
        permissionGranted = false

        XCTAssertThrowsError(try session.perform(.press, at: 0, in: snapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertTrue(runtime.supportedActionRequests.isEmpty)
        XCTAssertTrue(runtime.performedActions.isEmpty)

        permissionGranted = true
        XCTAssertThrowsError(try session.perform(.press, at: 0, in: snapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
    }

    func testSetValueRechecksSettableStateUsesExactIndexAndInvalidatesSnapshot() throws {
        let field = FakeAccessibilityNode(
            identifier: "field",
            role: "AXTextField",
            valueSettable: true
        )
        let runtime = FakeAccessibilityTreeRuntime(
            root: FakeAccessibilityNode(identifier: "root", children: [field])
        )
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())
        field.currentValueSettable = false

        XCTAssertThrowsError(try session.setValue(.text("updated"), at: 1, in: snapshot)) { error in
            XCTAssertEqual(
                error as? AutomationError,
                .attributeNotSettable(kAXValueAttribute as String)
            )
        }
        XCTAssertTrue(runtime.setValues.isEmpty)

        field.currentValueSettable = true
        let refreshedSnapshot = try session.snapshot(limits: generousLimits())
        try session.setValue(.text("updated"), at: 1, in: refreshedSnapshot)

        XCTAssertEqual(runtime.valueSettableRequests, ["field", "field"])
        XCTAssertEqual(runtime.setValues.count, 1)
        XCTAssertEqual(runtime.setValues[0].nodeID, "field")
        XCTAssertEqual(runtime.setValues[0].value, .text("updated"))
        XCTAssertThrowsError(try session.setValue(.text("again"), at: 1, in: refreshedSnapshot)) { error in
            XCTAssertEqual(error as? AutomationError, .staleAccessibilitySnapshot)
        }
    }

    func testSetValueRejectsSnapshotUnsettableAndOverlongTextBeforeMutation() throws {
        let field = FakeAccessibilityNode(
            identifier: "field",
            role: "AXTextField",
            valueSettable: false
        )
        let runtime = FakeAccessibilityTreeRuntime(root: field)
        let session = makeSession(runtime: runtime)
        let limits = try AccessibilityTreeLimits(
            maxDepth: 1,
            maxElements: 5,
            maxChildrenPerElement: 5,
            maxActionsPerElement: 5,
            maxTextLength: 4
        )
        let first = try session.snapshot(limits: limits)

        XCTAssertThrowsError(try session.setValue(.text("okay"), at: 0, in: first)) { error in
            XCTAssertEqual(
                error as? AutomationError,
                .attributeNotSettable(kAXValueAttribute as String)
            )
        }
        XCTAssertTrue(runtime.valueSettableRequests.isEmpty)

        field.snapshotValueSettable = true
        let second = try session.snapshot(limits: limits)
        XCTAssertThrowsError(try session.setValue(.text("too long"), at: 0, in: second)) { error in
            XCTAssertEqual(error as? AutomationError, .accessibilityValueTooLong(maximum: 4, actual: 8))
        }
        XCTAssertTrue(runtime.setValues.isEmpty)
    }

    func testObservedLinkURLPreservesExactSpellingAndNativeCFURLValues() throws {
        for value in ["https://example.com/orders?filter=open#latest", "HTTP://EXAMPLE.COM:80/a%2fb?q=a%26b"] {
            XCTAssertEqual(AccessibilityObservedLinkURL.validated(value), value)
            let stringResult = AccessibilityObservedLinkURL.validate(value as NSString)
            XCTAssertEqual(stringResult.value, value)
            XCTAssertFalse(stringResult.wasTruncated)
        }
        let url = try XCTUnwrap(URL(string: "https://example.com/order?id=123"))
        let native = AccessibilityObservedLinkURL.validate(url as NSURL)
        XCTAssertEqual(native.value, url.absoluteString)
        XCTAssertFalse(native.wasTruncated)
        XCTAssertNil(AccessibilityObservedLinkURL.validate(nil).value)
        XCTAssertFalse(AccessibilityObservedLinkURL.validate(nil).wasTruncated)
        XCTAssertNil(AccessibilityObservedLinkURL.validate(nil).identity)
        XCTAssertTrue(AccessibilityObservedLinkURL.validate(NSNumber(value: 3)).wasTruncated)
        XCTAssertEqual(AccessibilityObservedLinkURL.validate(NSNumber(value: 3)).identity, .unverifiable)
    }

    func testObservedLinkURLRejectsUnsupportedCredentialsControlCharactersAndRepairs() {
        for value in ["", "/relative", "//example.com/orders", "file:///tmp/orders", "javascript:alert(1)",
                      "https://user:secret@example.com/orders", "https://user@example.com/orders", "https://@example.com/",
                      "https://example.com/a b", " https://example.com/", "https://example.com/\n",
                      "https://example.com/%0a", "https://example.com/%00", "https://example.com/%7F",
                      "https://example.com/\\other", "https://", "https://example.com/%invalid",
                      "https://example.com:70000/", "https://example.com:0/"] {
            XCTAssertNil(AccessibilityObservedLinkURL.validated(value), value)
            let result = AccessibilityObservedLinkURL.validate(value as NSString)
            XCTAssertNil(result.value, value)
            XCTAssertTrue(result.wasTruncated, value)
        }
    }

    func testObservedLinkURLBoundOmitsWholeDestinationAndCanBeTightened() {
        let prefix = "https://example.com/"
        let exact = prefix + String(repeating: "a", count: 2_048 - prefix.utf8.count)
        XCTAssertEqual(AccessibilityObservedLinkURL.validated(exact), exact)
        XCTAssertNil(AccessibilityObservedLinkURL.validated(exact + "b"))
        XCTAssertNil(AccessibilityObservedLinkURL.validated(exact + "b", maximumBytes: 4_096))
        XCTAssertNil(AccessibilityObservedLinkURL.validated(exact, maximumBytes: 512))
        XCTAssertTrue(AccessibilityObservedLinkURL.validate((exact + "b") as NSString).wasTruncated)
    }

    func testSnapshotCopiesOnlyExactObservedLinkDestinationsAndMarksOmissions() throws {
        let link = FakeAccessibilityNode(identifier: "link", role: "AXLink", title: "Order details",
                                         url: "https://example.com/order?exact=a%2fb")
        let nonLink = FakeAccessibilityNode(identifier: "button", role: "AXButton",
                                            url: "https://example.com/not-a-link")
        let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [link, nonLink])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())
        XCTAssertEqual(snapshot.elements[1].url, link.url)
        XCTAssertNil(snapshot.elements[2].url)
        XCTAssertFalse(snapshot.wasTruncated)
        link.url = "https://example.com/" + String(repeating: "x", count: 2_048)
        let omitted = try session.snapshot(limits: generousLimits())
        XCTAssertNil(omitted.elements[1].url)
        XCTAssertTrue(omitted.wasTruncated)
    }

    func testChangedLinkDestinationRejectsExactIdentityAndLogicalRebind() throws {
        let destinations = [
            ("https://example.com/original", "https://example.com/changed"),
            ("https://example.com/" + String(repeating: "a", count: 2_100),
             "https://example.com/" + String(repeating: "b", count: 2_100)),
            ("javascript:original()", "javascript:changed()"),
        ]
        for (originalURL, changedURL) in destinations {
          for recreate in [false, true] {
            let link = FakeAccessibilityNode(identifier: "link", role: "AXLink", title: "Order details",
                actions: [SemanticAXAction.press.rawValue], url: originalURL)
            link.domIdentifier = "stable-link"
            let document = FakeAccessibilityNode(identifier: "document", role: "AXWebArea", children: [link])
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [document])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime, application: chromeTarget)
            let approved = try session.snapshot(limits: generousLimits())
            if recreate {
                let replacement = FakeAccessibilityNode(identifier: "replacement", role: "AXLink", title: "Order details",
                    actions: [SemanticAXAction.press.rawValue], url: changedURL)
                replacement.reportedIdentifier = link.reportedIdentifier
                replacement.domIdentifier = link.domIdentifier
                document.children = [replacement]
            } else {
                link.url = changedURL
            }
            XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 2, in: approved)) {
                XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
            }
            XCTAssertTrue(runtime.performedActions.isEmpty)
          }
        }
    }

    func testUnchangedUnsupportedDestinationCanStillUseExactAXIdentity() throws {
        let link = FakeAccessibilityNode(identifier: "link", role: "AXLink", title: "Details",
            actions: [SemanticAXAction.press.rawValue], url: "javascript:void(0)")
        let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [link])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let approved = try session.snapshot(limits: generousLimits())
        XCTAssertNil(approved.elements[1].url)
        guard case .sha256? = approved.elements[1].urlIdentity else {
            return XCTFail("Unsupported bounded destinations still need exact local identity")
        }
        try session.refreshAndPerform(.press, at: 1, in: approved)
        XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["link"])
    }

    func testOverIdentityBudgetCannotApproveEvenUnchangedExactLink() throws {
        let prefix = "https://example.com/"
        let atLimit = prefix + String(repeating: "a", count: 8_192 - prefix.utf8.count)
        guard case .sha256? = AccessibilityObservedLinkURL.validate(atLimit as NSString).identity else {
            return XCTFail("Exact identity limit should remain hashable")
        }
        for value in [atLimit + "b", "https://example.com/" + String(repeating: "😀", count: 2_049)] {
            XCTAssertEqual(AccessibilityObservedLinkURL.validate(value as NSString).identity, .unverifiable)
            let link = FakeAccessibilityNode(identifier: "link", role: "AXLink",
                actions: [SemanticAXAction.press.rawValue], url: value)
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [link])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let approved = try session.snapshot(limits: generousLimits())
            XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: approved)) {
                XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
            }
            XCTAssertTrue(runtime.performedActions.isEmpty)
        }
    }

    func testAbsentDestinationLegacySnapshotStillRevalidates() throws {
        let link = FakeAccessibilityNode(identifier: "link", role: "AXLink", actions: [SemanticAXAction.press.rawValue])
        let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [link])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let snapshot = try session.snapshot(limits: generousLimits())
        let legacy = try JSONDecoder().decode(AccessibilityTreeSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(legacy.elements[1].url)
        XCTAssertNil(legacy.elements[1].urlIdentity)
        try session.refreshAndPerform(.press, at: 1, in: legacy)
        XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["link"])
    }

    func testUnchangedLinkDestinationAllowsSameDocumentLogicalRebind() throws {
        let link = FakeAccessibilityNode(identifier: "link", role: "AXLink", title: "Order details",
            actions: [SemanticAXAction.press.rawValue], url: "https://example.com/original")
        let document = FakeAccessibilityNode(identifier: "document", role: "AXWebArea", children: [link])
        let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [document])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime, application: chromeTarget)
        let approved = try session.snapshot(limits: generousLimits())
        let replacement = FakeAccessibilityNode(identifier: "replacement", role: "AXLink", title: "Order details",
            actions: [SemanticAXAction.press.rawValue], url: link.url)
        replacement.reportedIdentifier = link.reportedIdentifier
        document.children = [replacement]
        try session.refreshAndPerform(.press, at: 2, in: approved)
        XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["replacement"])
    }

    func testSnapshotURLCodableSupportsOlderMissingField() throws {
        let link = FakeAccessibilityNode(identifier: "link", role: "AXLink", url: "https://example.com/order")
        let snapshot = try makeSession(runtime: FakeAccessibilityTreeRuntime(root: link)).snapshot(limits: generousLimits())
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(AccessibilityTreeSnapshot.self, from: encoded), snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var elements = try XCTUnwrap(object["elements"] as? [[String: Any]])
        for index in elements.indices {
            elements[index].removeValue(forKey: "url")
            elements[index].removeValue(forKey: "urlIdentity")
        }
        object["elements"] = elements
        let legacy = try JSONDecoder().decode(AccessibilityTreeSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.elements[0].url)
        XCTAssertNil(legacy.elements[0].urlIdentity)
        XCTAssertEqual(legacy.elements[0].role, "AXLink")
    }

    func testDescriptionTruncationPropagatesToSnapshot() throws {
        let root = FakeAccessibilityNode(identifier: "root", descriptionWasTruncated: true)
        let runtime = FakeAccessibilityTreeRuntime(root: root)

        let snapshot = try makeSession(runtime: runtime).snapshot(limits: generousLimits())

        XCTAssertTrue(snapshot.wasTruncated)
    }

    func testLimitsRejectUnsafeValues() {
        XCTAssertThrowsError(try AccessibilityTreeLimits(maxDepth: 33)) { error in
            XCTAssertEqual(
                error as? AutomationError,
                .invalidAccessibilityTreeLimit(name: "maxDepth", value: 33)
            )
        }
        XCTAssertThrowsError(try AccessibilityTreeLimits(maxElements: 0))
        XCTAssertThrowsError(try AccessibilityTreeLimits(maxChildrenPerElement: 501))
        XCTAssertThrowsError(try AccessibilityTreeLimits(maxActionsPerElement: 129))
        XCTAssertThrowsError(try AccessibilityTreeLimits(maxTextLength: 4_097))
    }

    func testDecodedLimitsCannotBypassHardCaps() throws {
        let unsafeJSON = Data(
            """
            {
              "maxDepth": 8,
              "maxElements": 2001,
              "maxChildrenPerElement": 80,
              "maxActionsPerElement": 32,
              "maxTextLength": 1024
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(AccessibilityTreeLimits.self, from: unsafeJSON)) { error in
            XCTAssertEqual(
                error as? AutomationError,
                .invalidAccessibilityTreeLimit(name: "maxElements", value: 2_001)
            )
        }

        let expected = try generousLimits()
        let roundTripped = try JSONDecoder().decode(
            AccessibilityTreeLimits.self,
            from: JSONEncoder().encode(expected)
        )
        XCTAssertEqual(roundTripped, expected)
    }

    private var chromeTarget: AccessibilityApplicationTarget {
        AccessibilityApplicationTarget(
            processIdentifier: target.processIdentifier,
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome"
        )
    }

    private func makeSession(
        runtime: FakeAccessibilityTreeRuntime,
        application: AccessibilityApplicationTarget? = nil
    ) -> AccessibilitySession {
        AccessibilitySession(
            target: application ?? target,
            runtime: runtime,
            accessibilityCheck: { true }
        )
    }

    private func generousLimits() throws -> AccessibilityTreeLimits {
        try AccessibilityTreeLimits(
            maxDepth: 8,
            maxElements: 100,
            maxChildrenPerElement: 20,
            maxActionsPerElement: 20,
            maxTextLength: 100
        )
    }
}
