import AutomationCore
import Foundation

/// A browser-only adapter over the existing captured mutation path. Tokens
/// carry no target data and are never accepted as native computer references.
struct EmbeddedBrowserActionReferences: Sendable {
    enum Kind: String, Sendable {
        case click, fill
        var tool: String { "browser_" + rawValue }
        var argument: String { rawValue + "_ref" }
        var prefix: String { "b" + rawValue + "_" }
        init?(tool: String) { self.init(rawValue: String(tool.dropFirst("browser_".count))) }
    }

    enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidReference
        var errorDescription: String? {
            #"{"success":false,"error":{"code":"browser_action_reference_invalid","message":"No input was dispatched. This action reference is unknown, expired, from another turn, or for a different action kind."},"dispatched":false,"no_replay":true,"next":"Use only the intended current row's click_ref or fill_ref. Use browser_read on the bound page if needed. No target lookup, input replay, or recovery capture occurred."}"#
        }
    }

    struct Prepared: Sendable {
        let taskKey: String
        let contextID: UUID
        let kind: Kind
        let reference: String
        let text: String?
        let snapshotID: UUID
        let intentIdentity: String
        fileprivate let target: Target?

        var canonicalArguments: [String: Any]? {
            guard let target else { return nil }
            var result: [String: Any] = ["snapshot_id": snapshotID.uuidString,
                "element_index": target.element.index, "expected_role": target.element.role,
                "expected_label": target.label]
            if let text { result["text"] = text }
            return result
        }

        var witness: BrowserPublishedActionWitness? { target?.witness }

        func matches(taskKey: String, contextID: UUID, tool: String, arguments: [String: Any]) -> Bool {
            self.taskKey == taskKey && self.contextID == contextID && kind.tool == tool
                && arguments[kind.argument] as? String == reference
                && (arguments["text"] as? String).map { Data($0.utf8) } == text.map { Data($0.utf8) }
        }
    }

    fileprivate struct Target: Equatable, Sendable {
        let kind: Kind
        let witness: BrowserPublishedActionWitness
        var snapshotID: UUID { witness.snapshotID }
        var bindingHandle: UUID { witness.bindingHandle }
        var instance: String { witness.targetInstanceToken }
        var committedDocumentID: UUID? { witness.committedDocumentID }
        var loaderID: String { witness.loaderID }
        var epoch: UUID { witness.documentEpoch }
        var url: URL { witness.documentURL }
        var element: BrowserTabElement { witness.element }
        var label: String { witness.label }
        var exposures: [SemanticReadFieldExposure] { witness.exposures }

        var intentIdentity: String {
            // Native target incarnation survives rebinds. A new snapshot,
            // row number or opaque token cannot refund the input retry budget.
            "\(instance):\(committedDocumentID?.uuidString ?? "unknown"):\(loaderID):\(element.backendNodeID)"
        }

        func canRepublish(as other: Target) -> Bool {
            guard let document = committedDocumentID, document == other.committedDocumentID,
                  kind == other.kind, bindingHandle == other.bindingHandle, instance == other.instance,
                  loaderID == other.loaderID, epoch == other.epoch, url == other.url,
                  exposures == other.exposures else { return false }
            let a = element, b = other.element
            func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
            return a.backendNodeID == b.backendNodeID && a.nodeID == b.nodeID
                && a.parentNodeID == b.parentNodeID && a.childNodeIDs == b.childNodeIDs
                && bytes(a.role) == bytes(b.role) && bytes(a.semanticRole) == bytes(b.semanticRole)
                && bytes(a.label) == bytes(b.label) && bytes(a.value) == bytes(b.value)
                && bytes(a.linkURL) == bytes(b.linkURL) && bytes(label) == bytes(other.label)
                && a.isEnabled == b.isEnabled && a.supportsPress == b.supportsPress
                && a.supportsSetText == b.supportsSetText && a.isDOMClickable == b.isDOMClickable
                && a.isFocusablePointer == b.isFocusablePointer
                && a.constraintValidation == b.constraintValidation
        }
    }

    private struct Tombstone: Sendable { let kind: Kind; let snapshotID: UUID; let identity: String }
    private var current = [String: Target]()
    private var currentOrder = [String]()
    private var publishedPageID: UUID?
    private var sourceID: UUID?
    private var selectionID: UUID?
    private var bindingHandle: UUID?
    private var retired = [String: Tombstone]()
    private var retiredOrder = [String]()
    static let maximumCurrent = 120 // Unchanged bound, shared across continuation pages.
    static let maximumRetired = 256

    mutating func retireCurrent() {
        for (token, target) in current { retire(token, target) }
        current.removeAll()
        currentOrder.removeAll()
        publishedPageID = nil; sourceID = nil; selectionID = nil; bindingHandle = nil
    }

    private mutating func retire(_ token: String, _ target: Target) {
        if retired[token] == nil { retiredOrder.append(token) }
        retired[token] = Tombstone(kind: target.kind, snapshotID: target.snapshotID, identity: target.intentIdentity)
        while retiredOrder.count > Self.maximumRetired {
            retired.removeValue(forKey: retiredOrder.removeFirst())
        }
    }

    /// Call on a value copy, then commit only alongside its complete bounded
    /// output. Only emitted rows receive capabilities. Cursor continuation can
    /// retain earlier publications of this exact immutable selection, bounded
    /// by the same token cap; republishing never renews FIFO age or the witness.
    mutating func publish(snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) -> [Int: String] {
        guard let receipt = snapshot.readReceipt, receipt.id == snapshot.id,
              let selected = snapshot.actionSelectionID,
              let presentation = snapshot.presentation, presentation.snapshotID == snapshot.id else {
            retireCurrent(); return [:]
        }
        let continuing = snapshot.isActionContinuation && sourceID == receipt.sourceID
            && selectionID == selected && bindingHandle == binding.handle
        var next = continuing ? current : [:], nextOrder = continuing ? currentOrder : []
        var suffixes = [Int: String](), publishedTokens = Set<String>()
        for row in presentation.rows {
            guard let element = snapshot.element(at: row.index), element.isEnabled,
                  let witness = snapshot.actionWitnesses[row.index], witness.snapshotID == snapshot.id,
                  witness.sourceID == receipt.sourceID, witness.selectionID == selected,
                  witness.bindingHandle == binding.handle, witness.targetInstanceToken == binding.targetInstanceToken,
                  witness.element == element else { continue }
            for kind in [Kind.click, .fill] {
                guard kind == .click ? element.supportsPress : element.supportsSetText else { continue }
                let target = Target(kind: kind, witness: witness)
                let token = currentOrder.first { !publishedTokens.contains($0)
                    && current[$0]?.canRepublish(as: target) == true }
                    ?? kind.prefix + UUID().uuidString
                if next[token] == nil {
                    while next.count >= Self.maximumCurrent,
                          let oldestIndex = nextOrder.firstIndex(where: { !publishedTokens.contains($0) }) {
                        let oldest = nextOrder.remove(at: oldestIndex)
                        if let old = next.removeValue(forKey: oldest) { retire(oldest, old) }
                    }
                    guard next.count < Self.maximumCurrent else { continue }
                    nextOrder.append(token)
                }
                // An already published same-capture witness stays frozen even
                // if an identical fragment appears on a later continuation.
                if !continuing || next[token] == nil { next[token] = target }
                publishedTokens.insert(token)
                suffixes[row.index, default: ""] += " \(kind.argument)=\"\(token)\""
            }
        }
        for (token, target) in current where next[token] == nil { retire(token, target) }
        current = next
        currentOrder = nextOrder
        publishedPageID = snapshot.id; sourceID = receipt.sourceID
        selectionID = selected; bindingHandle = binding.handle
        return suffixes
    }

    /// Membership is checked without re-resolving an approved target. A fresh
    /// publication may reuse the token, but cannot replace this frozen witness;
    /// FIFO eviction also revokes a prepared-but-not-dispatched action.
    func admits(_ prepared: Prepared, snapshot: BrowserTabSnapshot?) -> Bool {
        guard let target = prepared.target, current[prepared.reference] == target,
              let snapshot, snapshot.id == publishedPageID,
              snapshot.actionSelectionID == selectionID,
              snapshot.readReceipt?.sourceID == sourceID,
              target.witness.selectionID == selectionID,
              target.witness.sourceID == sourceID else { return false }
        return true
    }

    func prepare(taskKey: String, contextID: UUID, tool: String, arguments: [String: Any],
                 snapshot: BrowserTabSnapshot?) throws -> Prepared {
        guard let kind = Kind(tool: tool), let token = arguments[kind.argument] as? String else { throw Failure.invalidReference }
        let text = arguments["text"] as? String
        if let target = current[token], target.kind == kind {
            let prepared = Prepared(taskKey: taskKey, contextID: contextID, kind: kind, reference: token, text: text,
                snapshotID: target.snapshotID, intentIdentity: target.intentIdentity,
                target: target)
            return admits(prepared, snapshot: snapshot) ? prepared : Prepared(
                taskKey: taskKey, contextID: contextID, kind: kind, reference: token, text: text,
                snapshotID: target.snapshotID, intentIdentity: target.intentIdentity, target: nil)
        }
        if let old = retired[token], old.kind == kind {
            return Prepared(taskKey: taskKey, contextID: contextID, kind: kind, reference: token, text: text,
                snapshotID: old.snapshotID, intentIdentity: old.identity, target: nil)
        }
        throw Failure.invalidReference
    }

    #if DEBUG
    var countsForTesting: (current: Int, retired: Int) { (current.count, retired.count) }
    #endif
}
