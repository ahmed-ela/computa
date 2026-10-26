import Foundation
@testable import Computa

/// Decode only the codec's exact presentation frame in synthetic transports.
/// Return the original JSON slice; never trim or parse/reserialize its bytes.
enum WebsiteRequestFixture {
    enum Failure: Error { case invalidFrame }

    static func range(in prompt: String, expectedModel: String? = nil) throws -> Range<String.Index> {
        let opening = "COMPLETE_RESPONSES_REQUEST_JSON:\n"
        let closing = "\nEND_COMPLETE_RESPONSES_REQUEST_JSON."
        guard let start = prompt.range(of: opening),
              prompt.range(of: opening, options: .backwards) == start,
              let end = prompt.range(of: closing, range: start.upperBound..<prompt.endIndex),
              prompt.range(of: closing, options: .backwards) == end else { throw Failure.invalidFrame }
        let frameRange = start.upperBound..<end.lowerBound
        let frame = prompt[frameRange]
        let fenced = frame.hasPrefix("```\n") && frame.hasSuffix("\n```") && frame.utf8.count >= 8
        let jsonRange = fenced
            ? prompt.index(frameRange.lowerBound, offsetBy: 4)..<prompt.index(frameRange.upperBound, offsetBy: -4)
            : frameRange
        guard let object = try? JSONSerialization.jsonObject(with: Data(prompt[jsonRange].utf8)) as? [String: Any],
              let model = object["model"] as? String,
              expectedModel == nil || expectedModel == model,
              fenced == (LocalModelCatalog.webProvider(for: model) == "chatgpt") else { throw Failure.invalidFrame }
        return jsonRange
    }

    static func json(in prompt: String, expectedModel: String? = nil) throws -> Data {
        Data(prompt[try range(in: prompt, expectedModel: expectedModel)].utf8)
    }
}
