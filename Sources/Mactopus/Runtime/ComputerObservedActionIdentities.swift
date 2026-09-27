import Foundation

/// Bounded host-observed identities for correlating a stale action with its
/// successful replacement. This history never authorizes dispatch: callers
/// must still validate the current snapshot and target through the broker.
/// It retains no page text, values, URLs, or model-supplied identities.
struct ComputerObservedActionIdentities: Sendable {
    struct Element: Equatable, Sendable {
        let index: Int
        let backendNodeID: Int64
        let supportsSetText: Bool
    }

    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidTarget
        case capacityExceeded
        case invalidElement
        case duplicateIndex
        case conflictingSnapshot

        var errorDescription: String? {
            switch self {
            case .invalidTarget: "Observed action identities require a bounded target identity."
            case .capacityExceeded: "The observed snapshot has too many action identities."
            case .invalidElement: "Observed action identities require nonnegative indices and positive backend IDs."
            case .duplicateIndex: "An observed snapshot cannot map one element index to multiple identities."
            case .conflictingSnapshot: "A retained snapshot identity cannot be assigned different observed identities."
            }
        }
    }

    static let maximumSnapshots = 8
    static let maximumElements = 2_048
    private static let maximumTargetBytes = 1_024

    private struct Snapshot: Sendable {
        let targetID: String
        let id: UUID
        let elements: [Int: Element]
    }

    private var snapshots: [Snapshot] = []

    /// Only the runtime may supply these identities from an actual snapshot.
    /// Re-observing the same retained UUID is idempotent, not new progress or
    /// an opportunity to prolong its retention. Validation is atomic.
    mutating func record(targetID: String, snapshotID: UUID, elements: [Element]) throws {
        guard !targetID.isEmpty, targetID.utf8.count <= Self.maximumTargetBytes,
              !targetID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidTarget
        }
        guard elements.count <= Self.maximumElements else { throw Failure.capacityExceeded }
        var indexed: [Int: Element] = [:]
        for element in elements {
            guard element.index >= 0, element.backendNodeID > 0 else { throw Failure.invalidElement }
            guard indexed.updateValue(element, forKey: element.index) == nil else { throw Failure.duplicateIndex }
        }
        if let existing = snapshots.first(where: { $0.id == snapshotID }) {
            guard existing.targetID == targetID, existing.elements == indexed else { throw Failure.conflictingSnapshot }
            return
        }
        snapshots.append(Snapshot(targetID: targetID, id: snapshotID, elements: indexed))
        if snapshots.count > Self.maximumSnapshots { snapshots.removeFirst(snapshots.count - Self.maximumSnapshots) }
    }

    /// An invented UUID, an evicted snapshot, an unobserved index, or another
    /// target cannot acquire an identity. Use the current host target identity
    /// (including its connection/document generation), never one from the model.
    func lookup(currentTargetID: String, snapshotID: UUID, elementIndex: Int) -> Element? {
        guard elementIndex >= 0,
              let snapshot = snapshots.first(where: { $0.id == snapshotID && $0.targetID == currentTargetID }) else {
            return nil
        }
        return snapshot.elements[elementIndex]
    }
}
