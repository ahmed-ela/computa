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
    var isSelected: Bool? = nil

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
            urlIdentity: linkURL.identity,
            isSelected: node.isSelected
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
    func testExactEvidenceIdentitySurvivesReorderingButNeverRebindsReplacementOrAnotherSession() throws {
        let one = FakeAccessibilityNode(identifier: "first", role: "AXRow", title: "Same label", actions: ["AXPress"])
        one.reportedIdentifier = nil; one.isSelected = false
        let two = FakeAccessibilityNode(identifier: "second", role: "AXRow", title: "Same label", actions: ["AXPress"])
        two.reportedIdentifier = nil
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [one, two])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let first = try session.snapshot(limits: generousLimits())
        let token = try XCTUnwrap(first.elements[1].evidenceIdentity)
        XCTAssertEqual(first.elements[1].isSelected, false)
        root.children = [two, one]; one.isSelected = true
        let reordered = try session.snapshot(limits: generousLimits())
        XCTAssertEqual(reordered.elements[2].evidenceIdentity, token)
        XCTAssertEqual(reordered.elements[2].isSelected, true)
        XCTAssertNotEqual(reordered.elements[1].evidenceIdentity, token)
        let replacement = FakeAccessibilityNode(identifier: "replacement", role: "AXRow", title: "Same label", actions: ["AXPress"])
        replacement.reportedIdentifier = nil
        root.children = [two, replacement]
        let replaced = try session.snapshot(limits: generousLimits())
        XCTAssertNotEqual(replaced.elements[2].evidenceIdentity, token)
        let otherSession = makeSession(runtime: runtime)
        XCTAssertNotEqual(try otherSession.snapshot(limits: generousLimits()).elements[2].evidenceIdentity,
                          replaced.elements[2].evidenceIdentity)
        let formatted = reordered.formattedForModel()
        XCTAssertTrue(formatted.contains("selected=1"))
        XCTAssertFalse(formatted.contains(token.uuidString), "Host identity must never be a model-facing action address")
    }

    func testSelectedStateChangingAcrossApprovalInvalidatesRefreshedAXDispatch() throws {
        let row = FakeAccessibilityNode(identifier: "row", role: "AXRow", actions: ["AXPress"])
        row.isSelected = false
        let runtime = FakeAccessibilityTreeRuntime(root: FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [row]))
        let session = makeSession(runtime: runtime)
        let before = try session.snapshot(limits: generousLimits())
        row.isSelected = true
        // The native background backend uses the approval-refresh API. The
        // lower-level perform API expects its caller to do that refresh.
        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: 1, in: before))
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

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

    func testDispatchGuardRunsOnceAfterFinalActionChecksIncludingRefresh() throws {
        for refresh in [false, true] {
            let button = FakeAccessibilityNode(identifier: "button", role: "AXButton", actions: [SemanticAXAction.press.rawValue])
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [button])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let approved = try session.snapshot(limits: generousLimits())
            var dispatchChecks = 0
            let beforeDispatch: () throws -> Void = {
                dispatchChecks += 1
                XCTAssertEqual(runtime.supportedActionRequests, ["button"])
                XCTAssertTrue(runtime.performedActions.isEmpty)
                XCTAssertEqual(runtime.applicationElementRequests.count, refresh ? 2 : 1)
            }
            if refresh {
                try session.refreshAndPerform(.press, at: 1, in: approved, beforeDispatch: beforeDispatch)
            } else {
                try session.perform(.press, at: 1, in: approved, beforeDispatch: beforeDispatch)
            }
            XCTAssertEqual(dispatchChecks, 1)
            XCTAssertEqual(runtime.performedActions.map(\.nodeID), ["button"])
        }
    }

    func testDispatchGuardRefusalNeverPerformsOrRetriesAnAction() throws {
        for refresh in [false, true] {
            let button = FakeAccessibilityNode(identifier: "button", role: "AXButton", actions: [SemanticAXAction.press.rawValue])
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [button])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let approved = try session.snapshot(limits: generousLimits())
            var dispatchChecks = 0
            let beforeDispatch: () throws -> Void = {
                dispatchChecks += 1
                throw AutomationError.staleAccessibilitySnapshot
            }
            XCTAssertThrowsError(try {
                if refresh {
                    try session.refreshAndPerform(.press, at: 1, in: approved, beforeDispatch: beforeDispatch)
                } else {
                    try session.perform(.press, at: 1, in: approved, beforeDispatch: beforeDispatch)
                }
            }()) { XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot) }
            XCTAssertEqual(dispatchChecks, 1)
            XCTAssertTrue(runtime.performedActions.isEmpty)
            XCTAssertThrowsError(try session.perform(.press, at: 1, in: approved)) {
                XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
            }
        }
    }

    func testDispatchGuardRunsOnceAfterValueChecksIncludingRefresh() throws {
        for refresh in [false, true] {
            let field = FakeAccessibilityNode(identifier: "field", role: "AXTextField", valueSettable: true)
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [field])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let approved = try session.snapshot(limits: generousLimits())
            var dispatchChecks = 0
            let beforeDispatch: () throws -> Void = {
                dispatchChecks += 1
                XCTAssertEqual(runtime.valueSettableRequests, ["field"])
                XCTAssertTrue(runtime.setValues.isEmpty)
                XCTAssertEqual(runtime.applicationElementRequests.count, refresh ? 2 : 1)
            }
            if refresh {
                try session.refreshAndSetValue(.text("fixture"), at: 1, in: approved, beforeDispatch: beforeDispatch)
            } else {
                try session.setValue(.text("fixture"), at: 1, in: approved, beforeDispatch: beforeDispatch)
            }
            XCTAssertEqual(dispatchChecks, 1)
            XCTAssertEqual(runtime.setValues.map(\.nodeID), ["field"])
        }
    }

    func testDispatchGuardRefusalNeverSetsOrRetriesAValue() throws {
        for refresh in [false, true] {
            let field = FakeAccessibilityNode(identifier: "field", role: "AXTextField", valueSettable: true)
            let root = FakeAccessibilityNode(identifier: "window", role: "AXWindow", children: [field])
            let runtime = FakeAccessibilityTreeRuntime(root: root)
            let session = makeSession(runtime: runtime)
            let approved = try session.snapshot(limits: generousLimits())
            var dispatchChecks = 0
            let beforeDispatch: () throws -> Void = {
                dispatchChecks += 1
                throw AutomationError.staleAccessibilitySnapshot
            }
            XCTAssertThrowsError(try {
                if refresh {
                    try session.refreshAndSetValue(.text("fixture"), at: 1, in: approved, beforeDispatch: beforeDispatch)
                } else {
                    try session.setValue(.text("fixture"), at: 1, in: approved, beforeDispatch: beforeDispatch)
                }
            }()) { XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot) }
            XCTAssertEqual(dispatchChecks, 1)
            XCTAssertTrue(runtime.setValues.isEmpty)
            XCTAssertThrowsError(try session.setValue(.text("fixture"), at: 1, in: approved)) {
                XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
            }
        }
    }

    func testDispatchGuardIsNotCalledWhenPriorCapabilityChecksFail() throws {
        let node = FakeAccessibilityNode(identifier: "readonly", role: "AXTextField")
        let runtime = FakeAccessibilityTreeRuntime(root: node)
        let session = makeSession(runtime: runtime)
        var checks = 0
        let actionSnapshot = try session.snapshot(limits: generousLimits())
        XCTAssertThrowsError(try session.perform(.press, at: 0, in: actionSnapshot, beforeDispatch: { checks += 1 }))
        let valueSnapshot = try session.snapshot(limits: generousLimits())
        XCTAssertThrowsError(try session.setValue(.text("fixture"), at: 0, in: valueSnapshot, beforeDispatch: { checks += 1 }))
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(runtime.performedActions.isEmpty)
        XCTAssertTrue(runtime.setValues.isEmpty)
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

    func testBrowserOverviewIsRejectedBeforeNativeObservation() throws {
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [
            FakeAccessibilityNode(identifier: "body", role: "AXStaticText", title: "Native body")
        ])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let applicationRequests = runtime.applicationElementRequests.count
        let descriptions = runtime.describedNodeIDs.count
        XCTAssertThrowsError(try session.read(read: .init(view: .overview))) { error in
            guard let semanticError = error as? SemanticReadError, case .unsupportedOverview = semanticError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("browser-only"))
        }
        XCTAssertEqual(runtime.applicationElementRequests.count, applicationRequests)
        XCTAssertEqual(runtime.describedNodeIDs.count, descriptions)
        XCTAssertTrue(runtime.performedActions.isEmpty)
        XCTAssertTrue(runtime.setValues.isEmpty)
        let content = try session.read(read: .init(view: .content))
        XCTAssertTrue(content.observation.text.contains("Native body"))
    }

    func testProgressiveHeadingsFindsUnknownTitleBelowThirtyTwoWrappers() throws {
        let title = FakeAccessibilityNode(identifier: "unknown", role: "AXStaticText", title: "An unfamiliar title")
        var child = FakeAccessibilityNode(identifier: "heading", role: "AXHeading", children: [title])
        for depth in 0..<40 { child = FakeAccessibilityNode(identifier: "wrapper-\(depth)", children: [child]) }
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [child])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        XCTAssertFalse(try session.snapshot().elements.contains { $0.title == "An unfamiliar title" })
        let read = try session.read(read: .init(view: .headings))
        XCTAssertTrue(read.observation.text.contains("An unfamiliar title"))
        XCTAssertTrue(read.observation.text.contains("source_truncated=0"))
        XCTAssertTrue(read.observation.text.contains("next_cursor=-"))
        XCTAssertEqual(read.observation.exposedElementIndices.count, 2)
        XCTAssertFalse(read.observation.text.contains("ancestry_truncated=1"))
        XCTAssertTrue(read.observation.text.contains("parent=41"))
    }

    func testProgressiveWideSourceAndOutputPagesNeverSkipOrDuplicateLinks() throws {
        let links = (0..<315).map { FakeAccessibilityNode(identifier: "link-\($0)", role: "AXLink", title: "Unknown article \($0)", actions: ["AXPress"], url: "https://example.com/article/\($0)") }
        let runtime = FakeAccessibilityTreeRuntime(root: FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: links))
        let session = makeSession(runtime: runtime)
        var read = try session.read(read: .init(view: .links), outputCharacterLimit: 2_500)
        var seen = Set<String>()
        var pages = 0
        while true {
            pages += 1
            XCTAssertLessThan(pages, 100)
            for index in read.observation.exposedElementIndices {
                let label = try XCTUnwrap(read.snapshot.element(at: index)?.title)
                XCTAssertTrue(seen.insert(label).inserted)
            }
            guard let cursor = semanticCursor(read.observation.text) else { break }
            read = try session.read(read: .init(cursor: cursor), outputCharacterLimit: 2_500)
        }
        XCTAssertEqual(seen.count, 315)
        XCTAssertTrue(seen.contains("Unknown article 314"))
        XCTAssertGreaterThan(pages, 2)
        XCTAssertFalse(read.snapshot.wasTruncated)
        XCTAssertTrue(runtime.childRequests.contains { $0.limit > 80 })
    }

    func testProgressiveCursorRejectsForeignReplayedChangedOptionsAndNavigation() throws {
        let children = (0..<100).map { FakeAccessibilityNode(identifier: "item-\($0)", role: "AXLink", title: "Article \($0)") }
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", title: "Original", children: children)
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        var first = try session.read(read: .init(view: .links), outputCharacterLimit: 1_800)
        let cursor = try XCTUnwrap(semanticCursor(first.observation.text))
        _ = try session.read(read: .init(cursor: cursor))
        XCTAssertThrowsError(try session.read(read: .init(cursor: cursor)))
        first = try session.read(read: .init(view: .links), outputCharacterLimit: 1_800)
        let foreignSession = makeSession(runtime: runtime)
        XCTAssertThrowsError(try foreignSession.read(read: .init(cursor: semanticCursor(first.observation.text))))
        XCTAssertThrowsError(try session.read(read: .init(view: .content, cursor: semanticCursor(first.observation.text))))
        first = try session.read(read: .init(view: .links), outputCharacterLimit: 1_800)
        root.title = "Different document"
        XCTAssertThrowsError(try session.read(read: .init(cursor: semanticCursor(first.observation.text))))
    }

    func testProgressiveCursorAcceptsRepeatedMatchingFiltersWithoutSkippingOrDuplicating() throws {
        for options in ["none", "view", "query", "both"] {
            let children = (0..<100).map {
                FakeAccessibilityNode(identifier: "item-\($0)", role: "AXLink", title: "Article \($0)")
            }
            let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root:
                FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: children)))
            var read = try session.read(read: .init(query: "Article", view: .links), outputCharacterLimit: 1_800)
            let firstCursor = try XCTUnwrap(semanticCursor(read.observation.text))
            var seen = Set<String>()
            var pages = 0
            while true {
                pages += 1
                guard pages < 100 else { XCTFail("Continuation made insufficient bounded progress"); break }
                XCTAssertTrue(read.observation.text.contains("view=links"))
                for index in read.observation.exposedElementIndices {
                    let label = try XCTUnwrap(read.snapshot.element(at: index)?.title)
                    XCTAssertTrue(seen.insert(label).inserted, "Duplicate \(label) for \(options)")
                }
                guard let cursor = semanticCursor(read.observation.text) else { break }
                read = try session.read(read: .init(
                    query: options == "query" || options == "both" ? "  Article\n" : nil,
                    view: options == "view" || options == "both" ? .links : nil,
                    cursor: cursor), outputCharacterLimit: 1_800)
            }
            XCTAssertEqual(seen.count, 100)
            XCTAssertGreaterThan(pages, 1)
            XCTAssertThrowsError(try session.read(read: .init(query: "Article", view: .links, cursor: firstCursor)))
        }
    }

    func testProgressiveCursorStillRejectsConflictingFiltersAndAddedSubtree() throws {
        for change in ["view", "query", "snapshot", "index", "subtree"] {
            let children = (0..<100).map {
                FakeAccessibilityNode(identifier: "item-\($0)", role: "AXLink", title: "Article \($0)")
            }
            let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root:
                FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: children)))
            let first = try session.read(read: .init(query: "Article", view: .links), outputCharacterLimit: 1_800)
            let cursor = try XCTUnwrap(semanticCursor(first.observation.text))
            let request = SemanticReadRequest(query: change == "query" ? "Different" : "Article",
                view: change == "view" ? .content : .links, cursor: cursor,
                snapshotID: change == "snapshot" || change == "subtree" ? first.snapshot.id : nil,
                elementIndex: change == "index" || change == "subtree" ? 1 : nil)
            XCTAssertThrowsError(try session.read(read: request)) { error in
                guard let semantic = error as? SemanticReadError, case .invalidRequest = semantic else {
                    return XCTFail("Expected conflicting continuation rejection, got \(error)")
                }
            }
        }
    }

    func testProgressiveSubtreeRequiresExposedCurrentAttachedElement() throws {
        let card = FakeAccessibilityNode(identifier: "card", role: "AXGroup", title: "Card", children: [
            FakeAccessibilityNode(identifier: "title", role: "AXHeading", title: "Unknown nested heading")
        ])
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [card])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        var initial = try session.read()
        let expanded = try session.read(read: .init(view: .headings, snapshotID: initial.snapshot.id, elementIndex: 1))
        XCTAssertTrue(expanded.observation.text.contains("Unknown nested heading"))
        XCTAssertThrowsError(try session.read(read: .init(snapshotID: initial.snapshot.id, elementIndex: 1)))
        initial = try session.read(read: .init(view: .headings))
        XCTAssertThrowsError(try session.read(read: .init(snapshotID: initial.snapshot.id, elementIndex: 1)))
        initial = try session.read()
        root.children = [] // the AX object still exists but is no longer attached
        XCTAssertThrowsError(try session.read(read: .init(snapshotID: initial.snapshot.id, elementIndex: 1)))
    }

    func testProgressiveCursorRejectsDetachedPendingNodesWithoutNavigation() throws {
        let children = (0..<100).map { FakeAccessibilityNode(identifier: "item-\($0)", role: "AXLink", title: "Article \($0)") }
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", title: "Same SPA", children: children)
        let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root: root))
        let read = try session.read(read: .init(view: .links), outputCharacterLimit: 1_800)
        root.children = Array(children.prefix(1))
        XCTAssertThrowsError(try session.read(read: .init(cursor: semanticCursor(read.observation.text))))
    }

    func testProgressiveNoMatchReportsCoverageWithoutInventingContent() throws {
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [
            FakeAccessibilityNode(identifier: "item", role: "AXHeading", title: "Unrelated heading")
        ])
        let result = try makeSession(runtime: FakeAccessibilityTreeRuntime(root: root)).read(read: .init(query: "video title", view: .content))
        XCTAssertTrue(result.observation.exposedElementIndices.isEmpty)
        XCTAssertTrue(result.observation.text.contains("query_status=no_matches_in_visited_source"))
        XCTAssertTrue(result.observation.text.contains("matched=0"))
        XCTAssertTrue(result.observation.text.contains("next_cursor=-"))
        XCTAssertFalse(result.observation.text.contains("Unrelated heading"))
    }

    func testProgressiveDeepActionRefreshesExactIdentityAndRejectsDetachedTarget() throws {
        let button = FakeAccessibilityNode(identifier: "button", role: "AXButton", title: "Confirm", actions: ["AXPress"])
        var child = button
        for depth in 0..<35 { child = FakeAccessibilityNode(identifier: "wrapper-\(depth)", children: [child]) }
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [child])
        let runtime = FakeAccessibilityTreeRuntime(root: root)
        let session = makeSession(runtime: runtime)
        let result = try session.read(read: .init(view: .content))
        let index = try XCTUnwrap(result.observation.exposedElementIndices.first)
        try session.refreshAndPerform(.press, at: index, in: result.snapshot)
        XCTAssertEqual(runtime.performedActions.count, 1)
        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: index, in: result.snapshot))
        let second = try session.read(read: .init(view: .content))
        root.children = []
        XCTAssertThrowsError(try session.refreshAndPerform(.press, at: index, in: second.snapshot))
        XCTAssertEqual(runtime.performedActions.count, 1)
    }

    func testProgressiveReadAdvertisesOnlyExecutableActionsAndRespectsBackgroundRaise() throws {
        let root = FakeAccessibilityNode(identifier: "root", role: "AXWindow", title: "Window", actions: ["AXRaise", "AXScrollToVisible", "AXPress", "FutureAXAction"])
        let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root: root))
        let read = try session.read(allowsRaise: false)
        XCTAssertTrue(read.observation.text.contains("AXPress"))
        XCTAssertFalse(read.observation.text.contains("AXRaise"))
        XCTAssertFalse(read.observation.text.contains("AXScrollToVisible"))
        XCTAssertFalse(read.observation.text.contains("FutureAXAction"))
    }

    func testProgressiveHardSourceCapIsExplicitAndDoesNotInventCompletion() throws {
        let children = (0..<2_050).map { FakeAccessibilityNode(identifier: "node-\($0)", role: "AXStaticText", title: "Text \($0)") }
        let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root:
            FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: children)))
        // A no-match query isolates source pagination from output pagination.
        var read = try session.read(read: .init(query: "not present"))
        var pages = 1
        while let cursor = semanticCursor(read.observation.text) {
            read = try session.read(read: .init(cursor: cursor))
            pages += 1
            XCTAssertLessThan(pages, 12)
        }
        XCTAssertEqual(read.snapshot.elements.count, 2_000)
        XCTAssertTrue(read.observation.text.contains("source_limit_reached=1"))
        XCTAssertTrue(read.observation.text.contains("source_truncated=1"))
        XCTAssertTrue(read.observation.text.contains("no_matches_in_visited_source"))
        XCTAssertTrue(read.observation.exposedElementIndices.isEmpty)
    }

    func testProgressiveReadReceiptsStayPageLocalAcrossContinuation() throws {
        let children = (0..<60).map {
            FakeAccessibilityNode(identifier: "fact-\($0)", role: "AXStaticText", title: "Observed document fact \($0)")
        }
        let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root:
            FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: children)))
        let first = try session.read(read: .init(view: .content), outputCharacterLimit: 1_800)
        let firstReceipt = try XCTUnwrap(first.observation.readReceipt)
        let cursor = try XCTUnwrap(semanticCursor(first.observation.text))
        let next = try session.read(read: .init(cursor: cursor), outputCharacterLimit: 1_800)
        let nextReceipt = try XCTUnwrap(next.observation.readReceipt)
        XCTAssertNotEqual(firstReceipt.id, nextReceipt.id)
        XCTAssertNotEqual(firstReceipt.sourceID, nextReceipt.sourceID)
        for read in [first, next] {
            let receipt = try XCTUnwrap(read.observation.readReceipt)
            XCTAssertEqual(receipt.consistency, .liveValidatedPage)
            XCTAssertEqual(receipt.id, read.snapshot.id)
            XCTAssertEqual(receipt.sourceID, read.snapshot.id)
            XCTAssertEqual(receipt.view, .content)
            XCTAssertNil(receipt.selectedElementCount)
            XCTAssertNil(receipt.selectedFieldCount)
            XCTAssertTrue(receipt.outputTruncated)
            XCTAssertTrue(receipt.exposures.allSatisfy {
                read.observation.exposedElementIndices.contains(Int($0.nodeID)!)
            })
        }
        XCTAssertTrue(Set(firstReceipt.exposures.map(\.nodeID)).isDisjoint(with: nextReceipt.exposures.map(\.nodeID)))
    }

    func testProgressiveReadReceiptKeepsClippedSourceTailsUnknown() throws {
        // Model the production AX description cap: only this 1,024-character
        // prefix exists in the source observation; the unknown tail is not read.
        let prefix = String(repeating: "x", count: 1_024)
        let leaf = FakeAccessibilityNode(identifier: "fact", role: "AXStaticText", title: prefix,
                                         descriptionWasTruncated: true)
        let session = makeSession(runtime: FakeAccessibilityTreeRuntime(root:
            FakeAccessibilityNode(identifier: "root", role: "AXWindow", children: [leaf])))
        let read = try session.read(read: .init(view: .content))
        let receipt = try XCTUnwrap(read.observation.readReceipt)
        let label = try XCTUnwrap(receipt.exposures.first { $0.nodeID == "1" && $0.field == .label })
        XCTAssertTrue(receipt.sourceTruncated)
        XCTAssertTrue(receipt.fieldTruncated)
        XCTAssertTrue(read.observation.text.contains("field_truncated=1"))
        XCTAssertEqual(label.totalUTF8, 1_024, "No fabricated original length beyond the captured prefix")
        XCTAssertEqual(label.endUTF8, 255, "Only actual body prefix before the ellipsis was exposed")
        XCTAssertNil(receipt.selectedFieldCount)
    }

    private func semanticCursor(_ text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("next_cursor=") }
            .map { String($0.dropFirst("next_cursor=".count)) }.flatMap { $0 == "-" ? nil : $0 }
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
