import CryptoKit
import Foundation

/// Ordinary body-text counting for the pinned Qwen3.8-27B tokenizer. NFC is
/// applied only inside this counter; the outgoing request remains byte-identical.
/// Added special-token spellings remain ordinary text. No chat template, hidden
/// website input, output allowance or account quota is claimed by this count.
enum QwenBodyTokenCounter {
    static let maximumUTF8Bytes = 256 * 1_024
    static let mergeFileBytes = 2_972_084
    static let mergeFileSHA256 = "aa63aeccd2e3fb859f833668cab09e4dded9727ac39e2ba3f61473ab82c5c5d3"
    static let unicodeFileBytes = 17_798
    static let unicodeFileSHA256 = "d8e75a39fcbe309c6ea801446570b8a80b0067a14945e0c5d30d868cb1dcdac9"
    static let vocabularyCount = 248_044
    static let mergeCount = 247_587
    static let categoryPatterns = [#"\p{L}+"#, #"\p{M}+"#, #"\p{N}+"#, #"\s+"#]
    // The upstream case-insensitive contractions have these explicit Unicode
    // folds. Keeping them explicit avoids version-dependent ICU case folding.
    static let pattern = #"'[sSſ]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD]|[^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+|\p{N}| ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    enum Failure: Error, Equatable {
        case invalidResource, inputTooLarge, patternUnavailable, unmatchedText, unicodeCategoryMismatch
    }

    private static let bundledEncoder: Result<Encoder, any Error> = Result {
        try Encoder(mergeData: GroqBodyTokenCounter.loadData(from: resourceURL("qwen38_27b", "bpe"), expectedBytes: mergeFileBytes),
                    unicodeData: GroqBodyTokenCounter.loadData(from: resourceURL("qwen38_unicode_categories", "json"), expectedBytes: unicodeFileBytes))
    }

    static func tokenCount(_ text: String) throws -> Int {
        guard text.utf8.count <= maximumUTF8Bytes else { throw Failure.inputTooLarge }
        try Task.checkCancellation()
        return try bundledEncoder.get().tokenCount(text)
    }

    private static func resourceURL(_ name: String, _ ext: String) -> URL? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        return bundles.lazy.compactMap { $0.url(forResource: name, withExtension: ext, subdirectory: "Tokenizers") }.first
    }

    struct Encoder: Sendable {
        private struct Rule: Sendable { let rank: Int; let output: UInt32 }
        private let initial: [UInt32]
        private let rules: [UInt64: Rule]
        private let expression: NSRegularExpression
        private let unicode: UnicodeGuard

        init(mergeData: Data, unicodeData: Data) throws {
            guard mergeData.count == mergeFileBytes,
                  SHA256.hash(data: mergeData).map({ String(format: "%02x", $0) }).joined() == mergeFileSHA256 else { throw Failure.invalidResource }
            let bytes = Array(mergeData)
            guard bytes.prefix(8).elementsEqual(Array("CQWBPE1\0".utf8)) else { throw Failure.invalidResource }
            var offset = 8
            func next() -> UInt32 {
                defer { offset += 4 }
                return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
            }
            guard next() == vocabularyCount, next() == mergeCount else { throw Failure.invalidResource }
            let initial = (0..<256).map { _ in next() }
            guard Set(initial).count == 256, initial.allSatisfy({ $0 < vocabularyCount }) else { throw Failure.invalidResource }
            var rules: [UInt64: Rule] = [:], outputs = Set(initial)
            rules.reserveCapacity(mergeCount)
            for rank in 0..<mergeCount {
                let left = next(), right = next(), output = next()
                guard left < vocabularyCount, right < vocabularyCount, output < vocabularyCount,
                      outputs.insert(output).inserted,
                      rules.updateValue(Rule(rank: rank, output: output), forKey: Self.key(left, right)) == nil else { throw Failure.invalidResource }
            }
            guard offset == bytes.count else { throw Failure.invalidResource }
            self.initial = initial; self.rules = rules
            unicode = try UnicodeGuard(data: unicodeData)
            guard let expression = try? NSRegularExpression(pattern: pattern) else { throw Failure.patternUnavailable }
            self.expression = expression
        }

        func tokenCount(_ text: String) throws -> Int {
            guard text.utf8.count <= maximumUTF8Bytes else { throw Failure.inputTooLarge }
            try Task.checkCancellation()
            let normalized = text.precomposedStringWithCanonicalMapping
            guard normalized.utf8.count <= maximumUTF8Bytes else { throw Failure.inputTooLarge }
            try unicode.validate(text)
            try unicode.validate(normalized)
            if unicode.isWhitespace(normalized) {
                let bytes = Array(normalized.utf8)
                if let newline = bytes.lastIndex(where: { $0 == 10 || $0 == 13 }) {
                    return try countPiece(Array(bytes[...newline])) + countPiece(Array(bytes.dropFirst(newline + 1)))
                }
                return try countPiece(bytes)
            }
            let source = normalized as NSString
            var offset = 0, total = 0
            var failure: (any Error)?
            expression.enumerateMatches(in: normalized, range: NSRange(location: 0, length: source.length)) { match, _, stop in
                guard let match, match.range.location == offset, match.range.length > 0 else {
                    failure = Failure.unmatchedText; stop.pointee = true; return
                }
                do {
                    try Task.checkCancellation()
                    total += try countPiece(Array(source.substring(with: match.range).utf8))
                    offset = NSMaxRange(match.range)
                } catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            guard offset == source.length else { throw Failure.unmatchedText }
            return total
        }

        private static func key(_ left: UInt32, _ right: UInt32) -> UInt64 { UInt64(left) << 32 | UInt64(right) }

        /// Exact HF ranked-pair BPE, not a concatenated-vocabulary approximation.
        /// Some rules reference later-ranked products; every newly adjacent pair
        /// is reconsidered. Ties pick the leftmost pair. No input text is cached.
        private func countPiece(_ bytes: [UInt8]) throws -> Int {
            guard !bytes.isEmpty else { return 0 }
            var segments = bytes.indices.map { Segment(token: initial[Int(bytes[$0])], previous: $0 - 1, next: $0 + 1 < bytes.count ? $0 + 1 : -1) }
            var heap = PairHeap()
            func candidate(_ left: Int) -> Pair? {
                guard left >= 0, segments[left].alive else { return nil }
                let right = segments[left].next
                guard right >= 0, segments[right].alive, let rule = rules[Self.key(segments[left].token, segments[right].token)] else { return nil }
                return Pair(rank: rule.rank, output: rule.output, left: left, right: right,
                            leftVersion: segments[left].version, rightVersion: segments[right].version)
            }
            for index in bytes.indices {
                if index & 1_023 == 0 { try Task.checkCancellation() }
                if let pair = candidate(index) { heap.push(pair) }
            }
            var count = bytes.count, popped = 0
            while let pair = heap.pop() {
                popped += 1
                if popped & 1_023 == 0 { try Task.checkCancellation() }
                guard segments[pair.left].alive, segments[pair.right].alive,
                      segments[pair.left].next == pair.right,
                      segments[pair.left].version == pair.leftVersion,
                      segments[pair.right].version == pair.rightVersion else { continue }
                let next = segments[pair.right].next
                segments[pair.left].token = pair.output
                segments[pair.left].next = next
                segments[pair.left].version += 1
                segments[pair.right].alive = false
                segments[pair.right].version += 1
                if next >= 0 { segments[next].previous = pair.left }
                count -= 1
                if let pair = candidate(segments[pair.left].previous) { heap.push(pair) }
                if let pair = candidate(pair.left) { heap.push(pair) }
            }
            return count
        }
    }

    private struct Segment { var token: UInt32; var previous: Int; var next: Int; var version = 0; var alive = true }
    private struct Pair { let rank: Int; let output: UInt32; let left: Int; let right: Int; let leftVersion: Int; let rightVersion: Int }
    private struct PairHeap {
        var values: [Pair] = []
        func earlier(_ a: Pair, _ b: Pair) -> Bool { a.rank == b.rank ? a.left < b.left : a.rank < b.rank }
        mutating func push(_ value: Pair) {
            values.append(value); var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard earlier(values[index], values[parent]) else { break }
                values.swapAt(index, parent); index = parent
            }
        }
        mutating func pop() -> Pair? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]; values[0] = values.removeLast(); var index = 0
            while index * 2 + 1 < values.count {
                var child = index * 2 + 1
                if child + 1 < values.count, earlier(values[child + 1], values[child]) { child += 1 }
                guard earlier(values[child], values[index]) else { break }
                values.swapAt(index, child); index = child
            }
            return result
        }
    }

    private struct UnicodeGuard: Sendable {
        struct Reference: Decodable { let schemaVersion: Int; let patterns: [String]; let ranges: [[UInt32]] }
        let ranges: [[UInt32]]
        let expressions: [NSRegularExpression]
        init(data: Data) throws {
            guard data.count == unicodeFileBytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == unicodeFileSHA256,
                  let value = try? JSONDecoder().decode(Reference.self, from: data), value.schemaVersion == 1,
                  value.patterns == categoryPatterns, !value.ranges.isEmpty, value.ranges.count < 10_000 else { throw Failure.invalidResource }
            var previous: UInt32?
            for row in value.ranges {
                guard row.count == 3, row[0] <= row[1], row[1] <= 0x10ffff,
                      row[1] < 0xd800 || row[0] > 0xdfff, (1...4).contains(row[2]),
                      previous == nil || row[0] > previous! else { throw Failure.invalidResource }
                previous = row[1]
            }
            ranges = value.ranges
            do { expressions = try categoryPatterns.map { try NSRegularExpression(pattern: $0) } }
            catch { throw Failure.patternUnavailable }
        }
        func category(_ scalar: UInt32) -> Int? {
            var low = 0, high = ranges.count
            while low < high { let middle = (low + high) / 2; if ranges[middle][1] < scalar { low = middle + 1 } else { high = middle } }
            guard low < ranges.count, ranges[low][0] <= scalar else { return nil }
            return Int(ranges[low][2])
        }
        func isWhitespace(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { category($0.value) == 4 } }
        func validate(_ text: String) throws {
            guard !text.utf8.allSatisfy({ $0 < 128 }) else { return }
            var expected = [[NSRange]](repeating: [], count: 4), offset = 0
            for scalar in text.unicodeScalars {
                let length = scalar.value > 0xffff ? 2 : 1
                if let category = category(scalar.value) {
                    let index = category - 1
                    if let last = expected[index].last, NSMaxRange(last) == offset { expected[index][expected[index].count - 1].length += length }
                    else { expected[index].append(NSRange(location: offset, length: length)) }
                }
                offset += length
            }
            for (index, expression) in expressions.enumerated() {
                try Task.checkCancellation()
                var cursor = 0, mismatch = false
                expression.enumerateMatches(in: text, range: NSRange(location: 0, length: offset)) { match, _, stop in
                    guard let match, cursor < expected[index].count, match.range == expected[index][cursor] else { mismatch = true; stop.pointee = true; return }
                    cursor += 1
                }
                guard !mismatch, cursor == expected[index].count else { throw Failure.unicodeCategoryMismatch }
            }
        }
    }
}
