import ApplicationServices
import Foundation
import XCTest
@testable import AutomationCore

private final class FakeAccessibilityNode: NSObject {
    let identifier: String
    let role: String
    var title: String?
    var value: String?
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
        descriptionWasTruncated: Bool = false
    ) {
        self.identifier = identifier
        self.role = role
        self.title = title
        self.value = value
        self.children = children
        snapshotActions = actions
        currentActions = actions
        snapshotValueSettable = valueSettable
        currentValueSettable = valueSettable
        self.descriptionWasTruncated = descriptionWasTruncated
    }
}

private final class FakeAccessibilityTreeRuntime: AccessibilityTreeRuntime {
    let root: FakeAccessibilityNode
    var applicationElementRequests = [Int32]()
    var describedNodeIDs = [String]()
    var childRequests = [(nodeID: String, limit: Int)]()
    var supportedActionRequests = [String]()
    var valueSettableRequests = [String]()
    var performedActions = [(nodeID: String, action: String)]()
    var setValues = [(nodeID: String, value: AccessibilitySetValue)]()

    init(root: FakeAccessibilityNode) {
        self.root = root
    }

    func applicationElement(processIdentifier: Int32) throws -> AccessibilityElementHandle {
        applicationElementRequests.append(processIdentifier)
        return AccessibilityElementHandle(root)
    }

    func describe(
        _ element: AccessibilityElementHandle,
        limits: AccessibilityTreeLimits
    ) throws -> AccessibilityElementDescription {
        let node = try node(from: element)
        describedNodeIDs.append(node.identifier)
        return AccessibilityElementDescription(
            role: node.role,
            subrole: nil,
            title: node.title,
            elementDescription: nil,
            help: nil,
            identifier: node.identifier,
            value: node.value,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            supportedActions: node.snapshotActions,
            isValueSettable: node.snapshotValueSettable,
            wasTruncated: node.descriptionWasTruncated
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

    private func makeSession(runtime: FakeAccessibilityTreeRuntime) -> AccessibilitySession {
        AccessibilitySession(
            target: target,
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
