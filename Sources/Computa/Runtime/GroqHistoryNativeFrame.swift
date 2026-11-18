import Foundation

/// Exact field addresses only. The caller already authenticated this native
/// HTTP request and validated ordinary continuation. Parsed names do not prove
/// native issuance/completion or make a display descriptor eligible.
struct GroqHistoryNativeFrame: Sendable {
    enum Failure: Error, Equatable { case shape, duplicate, bounds, nonLiteralArguments }
    let history: GroqNativePublicationLedger.ValidatedHistory
    let olderCallIDs: [String]

    init(layout: GroqContextJSONLayout) throws {
        typealias K = GroqContextJSONLayout.ItemKind
        let calls = layout.items.filter { $0.kind == .functionCall || $0.kind == .customToolCall }
        let outputs = layout.items.filter { $0.kind == .functionCallOutput || $0.kind == .customToolCallOutput }
        var callMap: [String: GroqContextJSONLayout.Item] = [:]
        var outputMap: [String: GroqContextJSONLayout.Item] = [:]
        for call in calls {
            guard let id = call.callID, !id.isEmpty, id.utf8.count <= 512 else { throw Failure.shape }
            guard callMap.updateValue(call, forKey: id) == nil else { throw Failure.duplicate }
        }
        for output in outputs {
            guard let id = output.callID, let call = callMap[id], call.ordinal < output.ordinal,
                  output.kind == (call.kind == .functionCall ? K.functionCallOutput : K.customToolCallOutput),
                  output.name == nil || output.name == call.name,
                  output.namespace == nil || output.namespace == call.namespace else { throw Failure.shape }
            guard outputMap.updateValue(output, forKey: id) == nil else { throw Failure.duplicate }
        }
        let latestResult = outputs.last?.callID
        var pairs: [GroqNativePublicationLedger.HistoryPair] = []
        for call in calls {
            let kind: GroqNativePublicationLedger.Kind
            if call.kind == .functionCall, call.name == "exec_command" { kind = .execCommand }
            else if call.kind == .customToolCall, call.name == "apply_patch" { kind = .applyPatch }
            else { continue } // Browser/reader/unknown tools stay inline.
            guard call.namespace == nil || call.namespace == "functions" else { continue }
            guard let id = call.callID, let output = outputMap[id] else { continue } // Pending is not completion.
            guard let input = call.payload, let result = output.payload,
                  input.field == (kind == .execCommand ? .arguments : .input), result.field == .output,
                  let literal = input.literalUTF8 else { throw Failure.nonLiteralArguments }
            guard pairs.count < GroqNativePublicationLedger.maximumCalls else { throw Failure.bounds }
            pairs.append(.init(callID: id, kind: kind, name: try Self.name(call), namespace: call.namespace,
                argumentUTF8: literal, argumentValueRange: input.valueRange, outputValueRange: result.valueRange))
        }
        history = .init(sourceUTF8: layout.sourceUTF8, pairs: pairs)
        olderCallIDs = pairs.compactMap { $0.callID == latestResult ? nil : $0.callID }
    }

    private static func name(_ item: GroqContextJSONLayout.Item) throws -> String {
        guard let name = item.name else { throw Failure.shape }; return name
    }
}
