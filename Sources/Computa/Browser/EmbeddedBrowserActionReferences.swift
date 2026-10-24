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
            return element.hasIdenticalActionSemantics(to: other.element)
                && Data(label.utf8) == Data(other.label.utf8)
        }
    }

    private struct Tombstone: Sendable { let kind: Kind; let snapshotID: UUID; let identity: String }
    private var current = [String: Target]()
    private var currentOrder = [String]()
    private var publishedPageID: UUID?
    private var sourceID: UUID?
    private var selectionID: UUID?
    private var bindingHandle: UUID?
    private var eligibleForFreshCarry = Set<UUID>()
    private var pendingCarryEligibility = Set<UUID>()
    private var retired = [String: Tombstone]()
    private var retiredOrder = [String]()
    static let maximumCurrent = 120 // Unchanged bound, shared across continuation pages.
    static let maximumRetired = 256

    mutating func retireCurrent() {
        for (token, target) in current { retire(token, target) }
        current.removeAll()
        currentOrder.removeAll()
        publishedPageID = nil; sourceID = nil; selectionID = nil; bindingHandle = nil
        eligibleForFreshCarry.removeAll(); pendingCarryEligibility.removeAll()
    }

    private mutating func retire(_ token: String, _ target: Target) {
        if retired[token] == nil { retiredOrder.append(token) }
        retired[token] = Tombstone(kind: target.kind, snapshotID: target.snapshotID, identity: target.intentIdentity)
        while retiredOrder.count > Self.maximumRetired {
            retired.removeValue(forKey: retiredOrder.removeFirst())
        }
    }

    /// Candidates are existing publication authority, never document lookups.
    /// A failed admitted read disables carry even when its transactional
    /// replacement preserved the old snapshot for immediate preflight.
    func freshReadCandidates(snapshot: BrowserTabSnapshot?) -> [BrowserPublishedActionWitness] {
        guard let snapshot, snapshot.id == publishedPageID,
              snapshot.readReceipt?.sourceID == sourceID, snapshot.actionSelectionID == selectionID else { return [] }
        return currentOrder.compactMap { token in
            guard let witness = current[token]?.witness, eligibleForFreshCarry.contains(witness.publicationID) else { return nil }
            return witness
        }
    }

    mutating func beginRead() {
        pendingCarryEligibility = eligibleForFreshCarry
        eligibleForFreshCarry.removeAll()
    }
    mutating func abortRead() { pendingCarryEligibility.removeAll() }

    /// Commit this value copy only with its complete bounded output. A fresh
    /// capture can corroborate old exposures; only actual emitted rows issue
    /// new references. Neither path renews an existing token's age or expiry.
    mutating func publish(snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) -> [Int: String] {
        guard let receipt = snapshot.readReceipt, receipt.id == snapshot.id,
              let selected = snapshot.actionSelectionID,
              let presentation = snapshot.presentation, presentation.snapshotID == snapshot.id else {
            retireCurrent(); return [:]
        }
        let continuing = snapshot.isActionContinuation && sourceID == receipt.sourceID
            && selectionID == selected && bindingHandle == binding.handle
        var next = continuing ? current : [:], nextOrder = continuing ? currentOrder : []
        var nextEligible = continuing ? pendingCarryEligibility.union(eligibleForFreshCarry) : Set<UUID>()
        if !continuing {
            for token in currentOrder {
                guard let old = current[token], let proof = snapshot.corroboratedActionWitnesses.first(where: {
                    $0.publicationID == old.witness.publicationID
                        && $0.authoritySourceID == receipt.sourceID && $0.authoritySelectionID == selected
                        && $0.bindingHandle == binding.handle && $0.targetInstanceToken == binding.targetInstanceToken
                }) else { continue }
                next[token] = Target(kind: old.kind, witness: proof)
                nextEligible.insert(proof.publicationID)
                nextOrder.append(token)
            }
        }
        var publications = [(index: Int, kind: Kind, token: String, target: Target)]()
        var protectedTokens = Set<String>()
        for row in presentation.rows {
            guard let element = snapshot.element(at: row.index), element.isEnabled,
                  let witness = snapshot.actionWitnesses[row.index], witness.snapshotID == snapshot.id,
                  witness.sourceID == receipt.sourceID, witness.selectionID == selected,
                  witness.bindingHandle == binding.handle, witness.targetInstanceToken == binding.targetInstanceToken,
                  witness.element == element else { continue }
            for kind in [Kind.click, .fill] {
                guard kind == .click ? element.supportsPress : element.supportsSetText else { continue }
                let target = Target(kind: kind, witness: witness)
                // Reuse only already retained/proven targets. An expired or
                // failed-read token cannot be revived by a later publication.
                let token = nextOrder.first { !protectedTokens.contains($0)
                    && next[$0]?.canRepublish(as: target) == true }
                    ?? kind.prefix + UUID().uuidString
                protectedTokens.insert(token)
                publications.append((row.index, kind, token, target))
            }
        }
        var suffixes = [Int: String]()
        for publication in publications {
            let token = publication.token
            if next[token] == nil {
                while next.count >= Self.maximumCurrent,
                      let oldestIndex = nextOrder.firstIndex(where: { !protectedTokens.contains($0) }) {
                    let oldest = nextOrder.remove(at: oldestIndex)
                    if let old = next.removeValue(forKey: oldest) { retire(oldest, old) }
                }
                guard next.count < Self.maximumCurrent else { continue }
                nextOrder.append(token)
                next[token] = publication.target
            }
            if let target = next[token] { nextEligible.insert(target.witness.publicationID) }
            suffixes[publication.index, default: ""] += " \(publication.kind.argument)=\"\(token)\""
        }
        for (token, target) in current where next[token] == nil { retire(token, target) }
        current = next
        currentOrder = nextOrder
        publishedPageID = snapshot.id; sourceID = receipt.sourceID
        selectionID = selected; bindingHandle = binding.handle
        eligibleForFreshCarry = nextEligible.intersection(Set(next.values.map { $0.witness.publicationID }))
        pendingCarryEligibility.removeAll()
        return suffixes
    }

    /// Membership is checked without re-resolving an approved target. A fresh
    /// publication may reuse the token, but cannot replace this frozen witness;
    /// FIFO eviction also revokes a prepared-but-not-dispatched action.
    func admits(_ prepared: Prepared, snapshot: BrowserTabSnapshot?) -> Bool {
        guard let target = prepared.target else { return false }
        return currentTarget(prepared.reference, snapshot: snapshot) == target
    }

    private func currentTarget(_ reference: String, snapshot: BrowserTabSnapshot?) -> Target? {
        guard let target = current[reference], let snapshot, snapshot.id == publishedPageID,
              snapshot.actionSelectionID == selectionID,
              snapshot.readReceipt?.sourceID == sourceID,
              target.witness.authoritySelectionID == selectionID,
              target.witness.authoritySourceID == sourceID else { return nil }
        return target
    }

    /// A synchronous catalog projection, never a capture or registry update.
    /// Keep issuance order and original deadlines, including prior pages and
    /// freshly corroborated exposures. Tombstones grant no offered reference.
    func exportCurrent(snapshot: BrowserTabSnapshot?, binding: BrowserTabBinding) -> EmbeddedBrowserCurrentActionReferences {
        guard let snapshot, snapshot.tabHandle == binding.handle,
              binding.handle == bindingHandle, snapshot.documentEpoch == binding.documentEpoch else { return .empty }
        var clicks = [String](), fills = [String]()
        for reference in currentOrder {
            guard let target = currentTarget(reference, snapshot: snapshot),
                  target.bindingHandle == binding.handle, target.instance == binding.targetInstanceToken,
                  target.epoch == binding.documentEpoch, target.loaderID == snapshot.loaderID,
                  target.url == snapshot.documentURL,
                  target.committedDocumentID == snapshot.evidenceDocument?.committedDocumentID,
                  target.element.isEnabled else { continue }
            do { try target.witness.checkCaptureAge() } catch { continue }
            switch target.kind {
            case .click where target.element.supportsPress: clicks.append(reference)
            case .fill where target.element.supportsSetText: fills.append(reference)
            default: continue
            }
        }
        return .init(clickReferences: clicks, fillReferences: fills)
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
