import Foundation
import XCTest
@testable import Computa

final class GroqBodyTokenCounterTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Example: Decodable {
            let name: String
            let text: String
            let tokens: Int
            let allowsUnicodeCategoryMismatch: Bool
        }
        struct Recipe: Decodable {
            let name: String
            let unit: String
            let repetitions: Int
            let tokens: Int
        }
        let cases: [Example]
        let recipes: [Recipe]
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func corpus() throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf:
            repository.appendingPathComponent("Tests/Fixtures/GroqBodyTokenParity.json")))
    }

    private func resource(_ name: String) throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent("Sources/Computa/Resources/Tokenizers/" + name))
    }

    private func encoder() throws -> GroqBodyTokenCounter.Encoder {
        try GroqBodyTokenCounter.Encoder(rankData: resource("o200k_base.tiktoken"),
                                        unicodeData: resource("o200k_unicode_categories.json"))
    }

    func testOrdinaryTextMatchesPinnedRustTokenizerCorpus() throws {
        let encoder = try encoder()
        let corpus = try corpus()
        XCTAssertEqual(corpus.cases.count, 90)
        for example in corpus.cases {
            do {
                let count = try encoder.tokenCount(example.text)
                XCTAssertEqual(count, example.tokens, example.name)
            } catch GroqBodyTokenCounter.Failure.unicodeCategoryMismatch {
                // A system ICU with different Unicode categories must refuse the
                // new-script case, rather than return an unverified estimate.
                XCTAssertTrue(example.allowsUnicodeCategoryMismatch, example.name)
            }
        }
    }

    func testLongPiecesHaveExactCountsWithoutTruncation() throws {
        let encoder = try encoder()
        for recipe in try corpus().recipes {
            let text = String(repeating: recipe.unit, count: recipe.repetitions)
            XCTAssertLessThanOrEqual(text.utf8.count, GroqBodyTokenCounter.maximumUTF8Bytes)
            XCTAssertEqual(try encoder.tokenCount(text), recipe.tokens, recipe.name)
        }
    }

    func testLiteralSpecialTokensAreOrdinaryTextAndNormalizationIsNotApplied() throws {
        let encoder = try encoder()
        XCTAssertGreaterThan(try encoder.tokenCount("<|endoftext|>"), 1)
        let cases = try corpus().cases
        for name in ["special-text", "accents", "controls", "long-s", "whitespace"] {
            let example = try XCTUnwrap(cases.first { $0.name == name })
            XCTAssertEqual(try encoder.tokenCount(example.text), example.tokens, name)
        }
    }

    func testMissingCorruptAndOversizedResourcesFailClosed() throws {
        XCTAssertThrowsError(try GroqBodyTokenCounter.loadRankData(from: nil)) {
            XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .resourceUnavailable)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try GroqBodyTokenCounter.loadRankData(from: directory.appendingPathComponent("missing"))) {
            XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .resourceUnavailable)
        }
        let path = directory.appendingPathComponent("ranks")
        let good = try resource("o200k_base.tiktoken")
        let unicode = try resource("o200k_unicode_categories.json")
        try good.write(to: path)
        XCTAssertEqual(try GroqBodyTokenCounter.loadRankData(from: path), good)
        for bytes in [good.dropLast(), good + Data([0])] {
            try Data(bytes).write(to: path)
            XCTAssertThrowsError(try GroqBodyTokenCounter.loadRankData(from: path)) {
                XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .invalidResource)
            }
        }
        var corrupt = good
        corrupt[0] ^= 1
        XCTAssertThrowsError(try GroqBodyTokenCounter.Encoder(rankData: corrupt, unicodeData: unicode)) {
            XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .invalidResource)
        }
        var wrongUnicode = unicode
        wrongUnicode[0] ^= 1
        XCTAssertThrowsError(try GroqBodyTokenCounter.Encoder(rankData: good, unicodeData: wrongUnicode)) {
            XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .invalidResource)
        }
    }

    func testUTF8LimitRejectsInsteadOfTruncating() throws {
        let encoder = try encoder()
        let text = String(repeating: "🙂", count: GroqBodyTokenCounter.maximumUTF8Bytes / 4 + 1)
        XCTAssertThrowsError(try encoder.tokenCount(text)) {
            XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .inputTooLarge)
        }
        XCTAssertThrowsError(try GroqBodyTokenCounter.tokenCount(text)) {
            XCTAssertEqual($0 as? GroqBodyTokenCounter.Failure, .inputTooLarge)
        }
    }

    func testBundledProductionEntryPointFindsPinnedResources() throws {
        XCTAssertEqual(try GroqBodyTokenCounter.tokenCount("Hello, world!"), 4)
    }

    func testCancelledCountDoesNotReturnAnEstimate() async throws {
        let encoder = try encoder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try encoder.tokenCount("hello")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return a count")
        } catch is CancellationError { }
    }
}
