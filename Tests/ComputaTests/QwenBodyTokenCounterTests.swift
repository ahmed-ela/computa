import Foundation
import XCTest
@testable import Computa

final class QwenBodyTokenCounterTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent("Sources/Computa/Resources/Tokenizers/" + name)) }
    private func encoder() throws -> QwenBodyTokenCounter.Encoder {
        try .init(mergeData: data("qwen38_27b.bpe"), unicodeData: data("qwen38_unicode_categories.json"))
    }
    func testPinnedHuggingFaceOrdinaryTextParity() throws {
        struct Corpus: Decodable { struct Row: Decodable { let text: String; let count: Int; let nfc: String }; let rows: [Row] }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/QwenBodyTokenParity.json")))
        let counter = try encoder()
        XCTAssertEqual(corpus.rows.count, 598)
        for (index, row) in corpus.rows.enumerated() {
            XCTAssertEqual(row.text.precomposedStringWithCanonicalMapping, row.nfc, "NFC case \(index)")
            XCTAssertEqual(try counter.tokenCount(row.text), row.count, "BPE case \(index)")
        }
    }
    func testResourceBoundsAndHashesFailClosed() throws {
        let merge = try data("qwen38_27b.bpe"), unicode = try data("qwen38_unicode_categories.json")
        var changed = merge; changed[123] ^= 1
        for bad in [Data(merge.dropLast()), merge + Data([0]), changed] {
            XCTAssertThrowsError(try QwenBodyTokenCounter.Encoder(mergeData: bad, unicodeData: unicode))
        }
        var badUnicode = unicode; badUnicode[100] ^= 1
        XCTAssertThrowsError(try QwenBodyTokenCounter.Encoder(mergeData: merge, unicodeData: badUnicode))
        XCTAssertThrowsError(try GroqBodyTokenCounter.loadData(from: nil, expectedBytes: QwenBodyTokenCounter.mergeFileBytes))
    }
    func testBoundedInputsCancellationAndLiteralSpecialTokens() async throws {
        let counter = try encoder()
        XCTAssertThrowsError(try counter.tokenCount(String(repeating: "x", count: QwenBodyTokenCounter.maximumUTF8Bytes + 1)))
        XCTAssertGreaterThan(try counter.tokenCount("<|im_start|>"), 1)
        XCTAssertEqual(try counter.tokenCount("e\u{0301}"), try counter.tokenCount("é"))
        XCTAssertEqual(try QwenBodyTokenCounter.tokenCount("hi"), 1)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try counter.tokenCount("hi") }
        do { _ = try await task.value; XCTFail("Cancelled work must stop") } catch is CancellationError {}
    }
    func testModelSpecificAdmissionKeepsTheSameLimitAndUnknownByteFallback() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B").modelID
        XCTAssertTrue(WebModelResponseCodec.groqPromptBudgetUsesExactTokenizer(model: model))
        for count in [5_999, 6_000, 6_001] {
            let prompt = String(repeating: "1", count: count)
            XCTAssertEqual(try QwenBodyTokenCounter.tokenCount(prompt), count)
            if count <= 6_000 { XCTAssertEqual(try WebModelResponseCodec.validateGroqPromptBudget(model: model, prompt: prompt), count) }
            else { XCTAssertThrowsError(try WebModelResponseCodec.validateGroqPromptBudget(model: model, prompt: prompt)) {
                XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .groqPromptBudgetExceeded(actualTokens: 6_001, maximumTokens: 6_000, reservedTokens: 2_000))
            } }
        }
        let other = WebsiteModelChoice(provider: "groq", key: "qwen/unknown", label: "Other").modelID
        XCTAssertFalse(WebModelResponseCodec.groqPromptBudgetUsesExactTokenizer(model: other))
        XCTAssertThrowsError(try WebModelResponseCodec.validateGroqPromptBudget(model: other, prompt: String(repeating: "x", count: 6_001)))
        XCTAssertNil(try WebModelResponseCodec.validateGroqPromptBudget(model: "api/alibaba/model/other", prompt: "hi"))
    }
}
