import CryptoKit
import Foundation

/// Pure presentation/lookup values. The native owner authenticates each actual
/// HTTP frame and validates ordinary continuation BEFORE constructing this seed.
/// Only the server actor may install the chosen, budget-admitted Plan.snapshot.
struct GroqContextManifestProjector: Sendable {
    typealias Binding = GroqNativePublicationLedger.Binding
    typealias Layout = GroqContextJSONLayout
    static let label = "GROQ_CONTEXT_MANIFEST_V1"
    static let readerName = "computa_read_context"
    static let maximumBytes = 160 * 1_024
    static let maximumReferences = 1_024
    static let replacementMargin = 64

    enum Failure: String, Error, Equatable, LocalizedError {
        case binding, layout, publication, registration, stale, arguments, bounds
        case unknownReference, uncommittedLookup, duplicateCall, noSavings
        var errorDescription: String? {
            "Historical context could not be verified (\(rawValue)). No new historical reference was issued."
        }
    }
    struct ReaderAuthority: Sendable {
        fileprivate let owner: UUID
        fileprivate let binding: Binding
        fileprivate let nonce: UUID
        fileprivate let name: String
        fileprivate let registrationSHA256: String
    }
    struct IssuedLookupCall: Sendable {
        fileprivate let authority: ReaderAuthority
        fileprivate let sourceSHA256: String
        fileprivate let callID: String
        fileprivate let arguments: Data
    }
    struct PublicationTicket: Sendable {
        fileprivate let call: IssuedLookupCall
        fileprivate let revision: String
        fileprivate let response: Data
        fileprivate let next: Cursor?
        fileprivate let origins: [GroqNativePublicationLedger.LiteralField]
    }
    struct PublishedLookup: Sendable {
        fileprivate let ticket: PublicationTicket
    }
    struct ReadProposal: Sendable {
        let responseData: Data
        let publicationTicket: PublicationTicket
    }
    #if DEBUG
    /// Finite provenance of an already-built native presentation only. This
    /// contains no source hashes/values and is never an admission input.
    struct RevisionDiagnostics: Codable, Equatable, Sendable {
        let hadPrevious: Bool
        let lookupOnly: Bool
        let nativeConfigEqual: Bool?
        let selectedSchemasEqual: Bool?
        let candidatePolicyEqual: Bool?
        let previousItemCount: Int?
        let nativeItemCount: Int
        let appendedItems: Int?
        let appendedCalls: Int?
        let appendedOutputs: Int?
        let appendedOther: Int?
        let readerCalls: Int?
        let committedReaderPairs: Int
        let preserveRevision: Bool
        let countsSaturated: Bool
    }
    #endif

    struct Plan: Sendable {
        let renderedJSON: Data
        let snapshot: Snapshot
        let replacedFields: Int
        /// JSON bytes only. The existing production builder counts the entire
        /// final manifest contract/prompt with its unchanged tokenizer/limits.
        let savedJSONBytes: Int
        #if DEBUG
        var revisionDiagnostics: RevisionDiagnostics? = nil
        #endif
        var requiresManifestContract: Bool { replacedFields > 0 }
        func isCurrent() -> Bool { snapshot.isCurrent() }
    }
    struct Snapshot: Sendable {
        let contextRevision: String
        let nativeHTTPSourceSHA256: String
        let binding: Binding
        let contextNonce: UUID
        fileprivate let authority: ReaderAuthority
        fileprivate let configurationSHA256: String
        fileprivate let selectedSchemasSHA256: String
        fileprivate let candidatePolicySHA256: String
        fileprivate let anchorSHA256: String
        fileprivate let inputPrefix: Data
        fileprivate let itemCount: Int
        fileprivate let referencePayloads: [String: Stored]
        fileprivate let cursors: [String: Cursor]
        fileprivate let lookups: [String: LookupWitness]
        fileprivate let anchorField: GroqNativePublicationLedger.LiteralField?
        func isCurrent() -> Bool {
            referencePayloads.values.allSatisfy { $0.origins.allSatisfy { $0.isCurrent() } }
                && cursors.values.allSatisfy { $0.payload.origins.allSatisfy { $0.isCurrent() } }
        }
    }
    fileprivate struct Stored: Sendable {
        let reference: String
        let key: String
        let callID: String
        let name: String
        let kind: String
        let field: String
        let rawJSON: Data
        let origins: [GroqNativePublicationLedger.LiteralField]
        var sha256: String { GroqContextManifestProjector.sha(rawJSON) }
    }
    fileprivate struct Cursor: Sendable {
        let reference: String
        let payload: Stored
        let offset: Int
    }
    fileprivate struct LookupWitness: Sendable {
        let published: PublishedLookup
        let rawOutput: Data
    }
    private struct Field: Sendable {
        let key: String
        let callID: String
        let name: String
        let kind: String
        let field: Layout.PayloadField
        let itemOrdinal: Int
        let rawJSON: Data
        let origins: [GroqNativePublicationLedger.LiteralField]
    }
    private let binding: Binding
    private let nonce: UUID
    private let reader: ReaderAuthority
    private let native: Layout
    private let nativeSHA256: String
    private let configurationSHA256: String
    private let previous: Snapshot?
    private let keepLookupEpoch: Bool
    private let fields: [Field]
    private let lookups: [String: LookupWitness]
    private let newlyPublished: [PublishedLookup]
    private let anchorField: GroqNativePublicationLedger.LiteralField?
    #if DEBUG
    private let revisionSeed: RevisionDiagnostics
    #endif

    /// Native registration capability only, not evidence of thread/start itself.
    /// Root calls this only after the exact new-thread reader registration ACK.
    static func makeReaderAuthority(binding: Binding, contextNonce: UUID, registeredName: String,
        registrationSHA256: String) throws -> ReaderAuthority {
        guard [readerName, "functions." + readerName].contains(registeredName), isDigest(registrationSHA256) else {
            throw Failure.registration
        }
        return ReaderAuthority(owner: UUID(), binding: binding, nonce: contextNonce,
            name: registeredName, registrationSHA256: registrationSHA256)
    }

    /// Root invokes only for a currently offered reader call from its validated,
    /// actually encoded native response. No model JSON decoder creates this type.
    static func issueLookupCall(_ authority: ReaderAuthority, binding: Binding, contextNonce: UUID,
        nativeHTTPSourceSHA256: String, callID: String, qualifiedName: String, arguments: Data) throws -> IssuedLookupCall {
        guard authority.binding == binding, authority.nonce == contextNonce,
              authority.name == qualifiedName, validCallID(callID), isDigest(nativeHTTPSourceSHA256) else { throw Failure.binding }
        _ = try readArguments(arguments)
        return IssuedLookupCall(authority: authority, sourceSHA256: nativeHTTPSourceSHA256,
            callID: callID, arguments: arguments)
    }

    /// Invoke synchronously ONLY after the actual native RPC sendResponse write
    /// succeeds under Root's current owner/generation fences. A proposal/ticket
    /// alone cannot stabilize history or activate a pagination reference.
    static func commitLookupPublication(_ authority: ReaderAuthority, ticket: PublicationTicket,
        binding: Binding, contextNonce: UUID, responseData: Data) throws -> PublishedLookup {
        guard sameAuthority(authority, ticket.call.authority), authority.binding == binding,
              authority.nonce == contextNonce, ticket.response == responseData,
              ticket.origins.allSatisfy({ $0.isCurrent() }) else { throw Failure.publication }
        return PublishedLookup(ticket: ticket)
    }

    init(binding: Binding, contextNonce: UUID, nativeLayout: Layout,
        eligibleFields: [GroqNativePublicationLedger.LiteralField], previous: Snapshot?,
        publishedLookups: [PublishedLookup] = [], readerAuthority: ReaderAuthority) throws {
        guard readerAuthority.binding == binding, readerAuthority.nonce == contextNonce,
              nativeLayout.sourceUTF8.count <= Self.maximumBytes,
              try Self.modelMatches(nativeLayout, binding.scope.modelID),
              nativeLayout.sourceUTF8[nativeLayout.inputRange.lowerBound] == 91 else { throw Failure.binding }
        let sourceSHA = Self.sha(nativeLayout.sourceUTF8)
        let configuration = try Self.configurationDigest(nativeLayout)
        if let previous {
            guard previous.binding == binding, previous.contextNonce == contextNonce,
                  Self.sameAuthority(previous.authority, readerAuthority) else { throw Failure.binding }
        }
        if let first = eligibleFields.first {
            guard eligibleFields.allSatisfy({ $0.isSameEpoch(as: first) }),
                  previous?.anchorField.map({ $0.isSameEpoch(as: first) }) != false else { throw Failure.publication }
        }
        var selected: [Field] = [], keys = Set<String>()
        for literal in eligibleFields {
            guard literal.isCurrent(), literal.scope == binding.scope, literal.nativeHTTPSourceSHA256 == sourceSHA,
                  literal.byteCount == literal.rawJSONValue.count, literal.sha256 == Self.sha(literal.rawJSONValue) else {
                throw Failure.publication
            }
            let field: Layout.PayloadField = switch literal.field {
            case .arguments: .arguments
            case .input: .input
            case .output: .output
            }
            let item = try Self.item(nativeLayout, callID: literal.callID, field: field)
            let call = try Self.call(nativeLayout, callID: literal.callID)
            let expectedKind: Layout.ItemKind = literal.kind == .execCommand ? .functionCall : .customToolCall
            guard call.kind == expectedKind, call.name == literal.name, call.namespace == literal.namespace,
                  let payload = item.payload, payload.rawJSON == literal.rawJSONValue,
                  literal.valueRange == nil || literal.valueRange == payload.valueRange else { throw Failure.publication }
            let key = Self.fieldKey(literal.callID, field.rawValue)
            guard keys.insert(key).inserted else { throw Failure.publication }
            selected.append(Field(key: key, callID: literal.callID,
                name: Self.qualified(call), kind: literal.kind == .execCommand ? "function" : "custom",
                field: field, itemOrdinal: item.ordinal, rawJSON: payload.rawJSON, origins: [literal]))
        }
        var witnessed: [String: LookupWitness] = [:]
        if let previous {
            for (id, witness) in previous.lookups {
                if let item = try? Self.item(nativeLayout, callID: id, field: .output),
                   item.payload?.rawJSON == witness.rawOutput { witnessed[id] = witness }
            }
        }
        var seenLookups = Set<String>()
        for publication in publishedLookups {
            let ticket = publication.ticket, issued = ticket.call
            guard let previous, Self.sameAuthority(issued.authority, readerAuthority),
                  issued.sourceSHA256 == previous.nativeHTTPSourceSHA256,
                  ticket.revision == previous.contextRevision, ticket.origins.allSatisfy({ $0.isCurrent() }),
                  seenLookups.insert(issued.callID).inserted else {
                throw Failure.publication
            }
            let call = try Self.call(nativeLayout, callID: issued.callID)
            let output = try Self.item(nativeLayout, callID: issued.callID, field: .output)
            guard Self.qualified(call) == readerAuthority.name, call.kind == .functionCall,
                  call.payload?.literalUTF8 == issued.arguments, output.kind == .functionCallOutput,
                  output.payload?.literalUTF8 == ticket.response, let raw = output.payload?.rawJSON else {
                throw Failure.publication
            }
            witnessed[issued.callID] = LookupWitness(published: publication, rawOutput: raw)
        }
        var lookupOnly = false
        #if DEBUG
        var appendedCounts: (items: Int, calls: Int, outputs: Int, other: Int, readers: Int)? = nil
        #endif
        if let previous {
            guard try Self.hasExactInputPrefix(nativeLayout, previous: previous) else { throw Failure.layout }
            let appended = Array(nativeLayout.items.dropFirst(previous.itemCount))
            let calls = appended.filter { $0.kind == .functionCall }
            let outputs = appended.filter { $0.kind == .functionCallOutput }
            let readerCalls = calls.filter { Self.qualified($0) == readerAuthority.name }
            #if DEBUG
            appendedCounts = (appended.count, calls.count, outputs.count,
                appended.count - calls.count - outputs.count, readerCalls.count)
            #endif
            if !readerCalls.isEmpty {
                guard readerCalls.allSatisfy({ $0.callID.map(seenLookups.contains) == true }) else {
                    throw Failure.uncommittedLookup
                }
            }
            lookupOnly = previous.configurationSHA256 == configuration
                && !appended.isEmpty && appended.count == calls.count + outputs.count
                && calls.count == outputs.count && calls.count == seenLookups.count
                && calls.allSatisfy { $0.callID.map(seenLookups.contains) == true }
                && outputs.allSatisfy { $0.callID.map(seenLookups.contains) == true }
        }
        // Reader outputs require the native publication capability too. Merely
        // appearing under the registered name never makes a field eligible.
        for (id, witness) in witnessed {
            let output = try Self.item(nativeLayout, callID: id, field: .output)
            let key = Self.fieldKey(id, "output")
            guard keys.insert(key).inserted else { throw Failure.publication }
            selected.append(Field(key: key, callID: id, name: readerAuthority.name, kind: "lookup",
                field: .output, itemOrdinal: output.ordinal, rawJSON: witness.rawOutput,
                origins: witness.published.ticket.origins))
        }
        self.binding = binding; nonce = contextNonce; reader = readerAuthority; native = nativeLayout
        nativeSHA256 = sourceSHA; configurationSHA256 = configuration; self.previous = previous
        keepLookupEpoch = lookupOnly; fields = selected; lookups = witnessed
        newlyPublished = publishedLookups; anchorField = eligibleFields.first ?? previous?.anchorField
        #if DEBUG
        let counts = appendedCounts.map { [$0.items, $0.calls, $0.outputs, $0.other, $0.readers] } ?? []
        revisionSeed = RevisionDiagnostics(hadPrevious: previous != nil, lookupOnly: lookupOnly,
            nativeConfigEqual: previous.map { $0.configurationSHA256 == configuration },
            selectedSchemasEqual: nil, candidatePolicyEqual: nil,
            previousItemCount: previous.map { min($0.itemCount, 1_024) },
            nativeItemCount: min(nativeLayout.items.count, 1_024),
            appendedItems: appendedCounts.map { min($0.items, 1_024) },
            appendedCalls: appendedCounts.map { min($0.calls, 1_024) },
            appendedOutputs: appendedCounts.map { min($0.outputs, 1_024) },
            appendedOther: appendedCounts.map { min($0.other, 1_024) },
            readerCalls: appendedCounts.map { min($0.readers, 1_024) },
            committedReaderPairs: min(seenLookups.count, 1_024), preserveRevision: false,
            countsSaturated: (counts + [seenLookups.count, nativeLayout.items.count, previous?.itemCount ?? 0]).contains { $0 > 1_024 })
        #endif
    }

    func project(candidateLayout: Layout, fullSchemaSHA256: String, selectedSchemaSHA256: String) throws -> Plan {
        try render(candidateLayout, fullSchemaSHA256: fullSchemaSHA256,
            selectedSchemaSHA256: selectedSchemaSHA256, preview: false)
    }

    /// COUNT-ONLY host preview. The actual native frame must be an exact raw
    /// prefix of the host-created preview. Its new tail is always inline. No
    /// Snapshot/capability escapes this API; it cannot authorize an actual Send.
    func projectPreview(candidateLayout: Layout, hostPreviewLayout: Layout,
        fullSchemaSHA256: String, selectedSchemaSHA256: String) throws -> Data {
        guard try Self.configurationDigest(hostPreviewLayout) == configurationSHA256,
              try Self.hasExactInputPrefix(hostPreviewLayout, previousLayout: native),
              candidateLayout.items.count == hostPreviewLayout.items.count else { throw Failure.layout }
        for (source, displayed) in zip(hostPreviewLayout.items.dropFirst(native.items.count),
            candidateLayout.items.dropFirst(native.items.count)) {
            guard try hostPreviewLayout.rawBytes(in: source.wholeRange) == candidateLayout.rawBytes(in: displayed.wholeRange) else {
                throw Failure.layout
            }
        }
        // Only this count-only forecast treats the known host-created newest
        // result as latest. The actual project() path keeps native latest intact.
        let latest = hostPreviewLayout.items.last {
            $0.kind == .functionCallOutput || $0.kind == .customToolCallOutput
        }?.callID
        return try render(candidateLayout, fullSchemaSHA256: fullSchemaSHA256,
            selectedSchemaSHA256: selectedSchemaSHA256, preview: true, previewLatestCallID: latest).renderedJSON
    }

    private func render(_ candidate: Layout, fullSchemaSHA256: String,
        selectedSchemaSHA256: String, preview: Bool, previewLatestCallID: String? = nil) throws -> Plan {
        guard candidate.sourceUTF8.count <= Self.maximumBytes,
              try Self.modelMatches(candidate, binding.scope.modelID),
              preview ? candidate.items.count >= native.items.count : candidate.items.count == native.items.count,
              let fullRange = native.toolsRange, let selectedRange = candidate.toolsRange,
              Self.sha(try native.rawBytes(in: fullRange)) == fullSchemaSHA256,
              Self.sha(try candidate.rawBytes(in: selectedRange)) == selectedSchemaSHA256 else { throw Failure.layout }
        for (source, displayed) in zip(native.items, candidate.items) {
            guard source.kind == displayed.kind, source.role == displayed.role,
                  source.callID == displayed.callID, source.name == displayed.name,
                  source.namespace == displayed.namespace, source.recordID == displayed.recordID else { throw Failure.layout }
            if let sourcePayload = source.payload {
                guard sourcePayload.rawJSON == displayed.payload?.rawJSON else { throw Failure.layout }
            } else if source.role == "user" {
                guard try native.rawBytes(in: source.wholeRange) == candidate.rawBytes(in: displayed.wholeRange) else {
                    throw Failure.layout
                }
            }
        }
        let policy = try Self.policyDigest(candidate)
        let preserveRevision = keepLookupEpoch && previous?.selectedSchemasSHA256 == selectedSchemaSHA256
            && previous?.candidatePolicySHA256 == policy
        let anchor = keepLookupEpoch ? (previous?.anchorSHA256 ?? nativeSHA256) : nativeSHA256
        let revision = preserveRevision ? previous!.contextRevision : Self.sha(Self.join([
            Data(reader.owner.uuidString.utf8), Data(nonce.uuidString.utf8), Data(configurationSHA256.utf8),
            Data(anchor.utf8), Data(selectedSchemaSHA256.utf8), Data(policy.utf8)]))
        var payloads: [String: Stored] = preserveRevision ? previous!.referencePayloads : [:]
        var cursors: [String: Cursor] = preserveRevision ? previous!.cursors : [:]
        if preserveRevision {
            for publication in newlyPublished {
                if let next = publication.ticket.next { cursors[next.reference] = next }
            }
        }
        let latestCallID = preview ? previewLatestCallID
            : native.items.last(where: { $0.kind == .functionCallOutput || $0.kind == .customToolCallOutput })?.callID
        var replacements: [(Range<Int>, Data)] = []
        guard fields.allSatisfy({ $0.origins.allSatisfy { $0.isCurrent() } }) else { throw Failure.publication }
        for field in fields where field.callID != latestCallID {
            let item = try Self.item(candidate, callID: field.callID, field: field.field)
            guard item.ordinal < native.items.count, let payload = item.payload, payload.rawJSON == field.rawJSON,
                  !candidate.protectedRanges.contains(where: { $0.overlaps(payload.valueRange) }) else { throw Failure.layout }
            let ref = Self.referenceID(revision: revision, key: field.key, bytes: field.rawJSON)
            let stored = Stored(reference: ref, key: field.key, callID: field.callID,
                name: field.name, kind: field.kind, field: field.field.rawValue, rawJSON: field.rawJSON,
                origins: field.origins)
            // The unchanged containing item identifies the historical field.
            // Native Stored retains the full identity, bytes and SHA for reads;
            // none of that authority is reconstructed from this display token.
            var descriptorValue: [String: Any] = ["$computa_history": ref]
            // Preserve the failed outcome beside this opaque reference. A
            // successful reader of failure data is not itself a failed command.
            if field.kind == "function", field.origins.count == 1,
               let origin = field.origins.first, origin.callID == field.callID,
               let exit = origin.knownNonzeroExitCode {
                descriptorValue["status"] = "failed"; descriptorValue["exit_code"] = exit
                descriptorValue["historical_only"] = true; descriptorValue["action_authority"] = false
            }
            let descriptor = try Self.encode(descriptorValue)
            guard field.rawJSON.count > descriptor.count + Self.replacementMargin else { continue }
            guard payloads.count < Self.maximumReferences || payloads[ref] != nil else { throw Failure.bounds }
            payloads[ref] = stored; cursors[ref] = Cursor(reference: ref, payload: stored, offset: 0)
            replacements.append((payload.valueRange, descriptor))
        }
        replacements.sort { $0.0.lowerBound < $1.0.lowerBound }
        var result = Data(), offset = 0
        for (range, bytes) in replacements {
            guard range.lowerBound >= offset else { throw Failure.layout }
            result.append(candidate.sourceUTF8.subdata(in: offset..<range.lowerBound)); result.append(bytes)
            offset = range.upperBound
        }
        result.append(candidate.sourceUTF8.subdata(in: offset..<candidate.sourceUTF8.count))
        guard result.count <= candidate.sourceUTF8.count, result.count <= Self.maximumBytes else { throw Failure.noSavings }
        guard cursors.count <= Self.maximumReferences,
              payloads.values.reduce(0, { $0 + $1.rawJSON.count }) <= Self.maximumBytes else { throw Failure.bounds }
        let snapshot = Snapshot(contextRevision: revision, nativeHTTPSourceSHA256: nativeSHA256,
            binding: binding, contextNonce: nonce, authority: reader, configurationSHA256: configurationSHA256,
            selectedSchemasSHA256: selectedSchemaSHA256, candidatePolicySHA256: policy, anchorSHA256: anchor,
            inputPrefix: try Self.inputPrefix(native), itemCount: native.items.count,
            referencePayloads: payloads, cursors: cursors, lookups: lookups, anchorField: anchorField)
        let plan = Plan(renderedJSON: result, snapshot: snapshot, replacedFields: replacements.count,
            savedJSONBytes: candidate.sourceUTF8.count - result.count)
        #if DEBUG
        var observed = plan
        observed.revisionDiagnostics = RevisionDiagnostics(hadPrevious: revisionSeed.hadPrevious,
            lookupOnly: revisionSeed.lookupOnly, nativeConfigEqual: revisionSeed.nativeConfigEqual,
            selectedSchemasEqual: previous.map { $0.selectedSchemasSHA256 == selectedSchemaSHA256 },
            candidatePolicyEqual: previous.map { $0.candidatePolicySHA256 == policy },
            previousItemCount: revisionSeed.previousItemCount, nativeItemCount: revisionSeed.nativeItemCount,
            appendedItems: revisionSeed.appendedItems, appendedCalls: revisionSeed.appendedCalls,
            appendedOutputs: revisionSeed.appendedOutputs, appendedOther: revisionSeed.appendedOther,
            readerCalls: revisionSeed.readerCalls, committedReaderPairs: revisionSeed.committedReaderPairs,
            preserveRevision: preserveRevision, countsSaturated: revisionSeed.countsSaturated)
        return observed
        #else
        return plan
        #endif
    }

    static func prepareRead(_ snapshot: Snapshot, issued: IssuedLookupCall,
        maximumBytes: Int) throws -> ReadProposal {
        guard snapshot.isCurrent(), sameAuthority(snapshot.authority, issued.authority), snapshot.binding == issued.authority.binding,
              snapshot.contextNonce == issued.authority.nonce,
              snapshot.nativeHTTPSourceSHA256 == issued.sourceSHA256 else { throw Failure.binding }
        guard (64...4_096).contains(maximumBytes) else { throw Failure.bounds }
        guard snapshot.lookups[issued.callID] == nil else { throw Failure.duplicateCall }
        let ref = try readArguments(issued.arguments)
        guard let cursor = snapshot.cursors[ref], cursor.offset <= cursor.payload.rawJSON.count else { throw Failure.unknownReference }
        let payload = cursor.payload
        var end = min(payload.rawJSON.count, cursor.offset + maximumBytes)
        while end > cursor.offset, String(data: payload.rawJSON.subdata(in: cursor.offset..<end), encoding: .utf8) == nil { end -= 1 }
        guard end > cursor.offset else { throw Failure.bounds }
        let fragment = payload.rawJSON.subdata(in: cursor.offset..<end)
        let nextID = end < payload.rawJSON.count ? referenceID(revision: snapshot.contextRevision,
            key: payload.key + ":offset:" + String(end), bytes: payload.rawJSON) : nil
        let next = nextID.map { Cursor(reference: $0, payload: payload, offset: end) }
        let nextValue: Any = nextID.map { $0 as Any } ?? NSNull()
        let body = try encode(["context_revision": snapshot.contextRevision, "ref": ref,
            "source_call_id": payload.callID, "source_name": payload.name, "source_kind": payload.kind,
            "field": payload.field, "value_encoding": "json", "whole_bytes": payload.rawJSON.count,
            "whole_sha256": payload.sha256, "start_byte": cursor.offset, "end_byte": end,
            "utf8_fragment": String(decoding: fragment, as: UTF8.self), "next_ref": nextValue,
            "historical_only": true, "action_authority": false])
        return ReadProposal(responseData: body, publicationTicket: PublicationTicket(call: issued,
            revision: snapshot.contextRevision, response: body, next: next, origins: payload.origins))
    }

    private static func modelMatches(_ layout: Layout, _ expected: String) throws -> Bool {
        guard let field = layout.rootOtherMembers.first(where: { $0.key == "model" }),
              let value = try JSONSerialization.jsonObject(with: layout.rawBytes(in: field.valueRange), options: .fragmentsAllowed) as? String else { return false }
        return Data(value.utf8) == Data(expected.utf8)
    }
    private static func sameAuthority(_ a: ReaderAuthority, _ b: ReaderAuthority) -> Bool {
        a.owner == b.owner && a.binding == b.binding && a.nonce == b.nonce
            && a.name == b.name && a.registrationSHA256 == b.registrationSHA256
    }
    private static func call(_ layout: Layout, callID: String) throws -> Layout.Item {
        let found = layout.items.filter { $0.callID == callID && ($0.kind == .functionCall || $0.kind == .customToolCall) }
        guard found.count == 1, let result = found.first else { throw Failure.layout }; return result
    }
    private static func item(_ layout: Layout, callID: String, field: Layout.PayloadField) throws -> Layout.Item {
        let found = layout.items.filter { $0.callID == callID && $0.payload?.field == field }
        guard found.count == 1, let result = found.first else { throw Failure.layout }; return result
    }
    private static func qualified(_ item: Layout.Item) -> String {
        guard let name = item.name else { return "" }; return item.namespace.map { $0 + "." + name } ?? name
    }
    private static func fieldKey(_ callID: String, _ field: String) -> String { callID + ":" + field }
    private static func inputPrefix(_ layout: Layout) throws -> Data {
        guard layout.sourceUTF8[layout.inputRange.lowerBound] == 91 else { throw Failure.layout }
        let end = layout.items.last?.wholeRange.upperBound ?? layout.inputRange.lowerBound + 1
        return try layout.rawBytes(in: layout.inputRange.lowerBound..<end)
    }
    private static func hasExactInputPrefix(_ next: Layout, previous: Snapshot) throws -> Bool {
        guard next.items.count >= previous.itemCount, next.inputRange.lowerBound + previous.inputPrefix.count <= next.inputRange.upperBound else { return false }
        return try next.rawBytes(in: next.inputRange.lowerBound..<(next.inputRange.lowerBound + previous.inputPrefix.count)) == previous.inputPrefix
    }
    private static func hasExactInputPrefix(_ next: Layout, previousLayout: Layout) throws -> Bool {
        let prefix = try inputPrefix(previousLayout)
        guard next.items.count >= previousLayout.items.count, next.inputRange.lowerBound + prefix.count <= next.inputRange.upperBound else { return false }
        return try next.rawBytes(in: next.inputRange.lowerBound..<(next.inputRange.lowerBound + prefix.count)) == prefix
    }
    private static func configurationDigest(_ layout: Layout) throws -> String {
        // Native Core may reserialize an otherwise identical configuration.
        // Match ordinary continuation's strict value equivalence for this
        // digest only; source/prefix/payload and selected-policy guards stay raw.
        func value(_ range: Range<Int>) throws -> Data {
            try WebsiteTurnContinuation.canonicalValueDataForDigest(layout.rawBytes(in: range))
        }
        var parts: [Data] = []
        for member in layout.rootOtherMembers.sorted(by: { Data($0.key.utf8).lexicographicallyPrecedes(Data($1.key.utf8)) }) {
            parts += [Data(member.key.utf8), try value(member.valueRange)]
        }
        var policy: [Data] = []
        if let range = layout.instructionsRange { policy.append(try value(range)) }
        for item in layout.items where item.role == "system" || item.role == "developer" {
            policy.append(try value(item.wholeRange))
        }
        parts.append(join(policy))
        if let range = layout.toolsRange { parts.append(try value(range)) }
        for item in layout.items where item.role == "user" { parts.append(try value(item.wholeRange)) }
        return sha(join(parts))
    }
    private static func policyBytes(_ layout: Layout) throws -> Data {
        var parts: [Data] = []
        if let range = layout.instructionsRange { parts.append(try layout.rawBytes(in: range)) }
        for item in layout.items where item.role == "system" || item.role == "developer" { parts.append(try layout.rawBytes(in: item.wholeRange)) }
        return join(parts)
    }
    private static func policyDigest(_ layout: Layout) throws -> String { sha(try policyBytes(layout)) }
    private static func join(_ parts: [Data]) -> Data {
        var bytes = Data(); for part in parts { bytes.append(Data("\(part.count):".utf8)); bytes.append(part) }; return bytes
    }
    private static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func validCallID(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func referenceID(revision: String, key: String, bytes: Data) -> String {
        // Keep all 128 digest bits. The full internal revision, field key and
        // full payload SHA remain length-delimited inputs to the same digest.
        let hash = Data(SHA256.hash(data: join([Data(revision.utf8), Data(key.utf8), Data(sha(bytes).utf8)])).prefix(16))
        return base64URL(hash)
    }
    private static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func isReference(_ value: String) -> Bool {
        guard value.utf8.count == 22,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="),
              bytes.count == 16 else { return false }
        return base64URL(bytes) == value // Reject alternate padding-bit spellings.
    }
    private static func readArguments(_ data: Data) throws -> String {
        guard data.count <= 512, !data.contains(92), let text = String(data: data, encoding: .utf8) else { throw Failure.arguments }
        let whitespace = #"[ \t\r\n]*"#
        let pattern = "^" + whitespace + "\\{" + whitespace + #""ref""# + whitespace + ":" + whitespace
            + #""([A-Za-z0-9_-]{22})""# + whitespace + "\\}" + whitespace + "$"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw Failure.arguments }
        let ref = String(text[range])
        guard isReference(ref) else { throw Failure.arguments }
        return ref
    }
}
