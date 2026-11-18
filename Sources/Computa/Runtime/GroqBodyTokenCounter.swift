import CryptoKit
import Foundation

/// Pinned ordinary-text o200k_harmony body tokens. Website framing, hidden input
/// and output reservations are separate from this count and need their own allowance.
/// No string is normalized, truncated, or interpreted as a special token.
enum GroqBodyTokenCounter {
    static let maximumUTF8Bytes = 256 * 1_024
    static let rankFileBytes = 3_613_922
    static let rankFileSHA256 = "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d"
    static let rankCount = 199_998
    static let unicodeFileBytes = 35_159
    static let unicodeFileSHA256 = "86f2980973d70d7be8458a22ae8961633d353f77a6f6a548cdb5ea10eebaf282"
    static let categoryPatterns = [#"[\p{Lu}\p{Lt}]+"#, #"\p{Ll}+"#, #"[\p{Lm}\p{Lo}]+"#,
                                   #"\p{M}+"#, #"\p{N}+"#, #"\s+"#]

    // Pinned tiktoken 0.12.0 pattern, with its exhaustively checked contraction
    // case-fold sets written explicitly to avoid ICU case-fold version differences.
    static let pretokenizationPattern = [
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?:'[sSſ]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])?"#,
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?:'[sSſ]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])?"#,
        #"\p{N}{1,3}"#,
        #" ?[^\s\p{L}\p{N}]+[\r\n/]*"#,
        #"\s*[\r\n]+"#,
        #"\s+(?!\S)"#,
        #"\s+"#,
    ].joined(separator: "|")

    enum Failure: Error, Equatable {
        case resourceUnavailable
        case invalidResource
        case inputTooLarge
        case patternUnavailable
        case unmatchedText
        case unicodeCategoryMismatch
    }

    // One immutable vocabulary, with no cache of user input, pieces or results.
    private static let bundledEncoder: Result<Encoder, Failure> = {
        do {
            return .success(try Encoder(
                rankData: loadRankData(from: resourceURL(name: "o200k_base", extension: "tiktoken")),
                unicodeData: loadData(from: resourceURL(name: "o200k_unicode_categories", extension: "json"),
                                      expectedBytes: unicodeFileBytes)))
        }
        catch { return .failure((error as? Failure) ?? .resourceUnavailable) }
    }()

    static func tokenCount(_ text: String) throws -> Int {
        guard text.utf8.count <= maximumUTF8Bytes else { throw Failure.inputTooLarge }
        try Task.checkCancellation()
        return try bundledEncoder.get().tokenCount(text)
    }

    private static func resourceURL(name: String, extension fileExtension: String) -> URL? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        return bundles.lazy.compactMap {
            $0.url(forResource: name, withExtension: fileExtension, subdirectory: "Tokenizers")
        }.first
    }

    /// A bounded read is also used by the missing/corrupted-resource regressions.
    static func loadRankData(from url: URL?) throws -> Data {
        try loadData(from: url, expectedBytes: rankFileBytes)
    }

    static func loadData(from url: URL?, expectedBytes: Int) throws -> Data {
        guard let url, url.isFileURL, let file = try? FileHandle(forReadingFrom: url) else {
            throw Failure.resourceUnavailable
        }
        defer { try? file.close() }
        do {
            guard let bytes = try file.read(upToCount: expectedBytes + 1), bytes.count == expectedBytes else {
                throw Failure.invalidResource
            }
            let remainder = try file.read(upToCount: 1)
            guard remainder == nil || remainder?.isEmpty == true else { throw Failure.invalidResource }
            return bytes
        } catch { throw Failure.invalidResource }
    }

    struct Encoder: Sendable {
        private let ranks: [Data: Int]
        private let expression: NSRegularExpression
        private let unicodeGuard: UnicodeGuard

        init(rankData: Data, unicodeData: Data) throws {
            guard rankData.count == rankFileBytes,
                  SHA256.hash(data: rankData).map({ String(format: "%02x", $0) }).joined() == rankFileSHA256,
                  let source = String(data: rankData, encoding: .utf8) else { throw Failure.invalidResource }
            var ranks: [Data: Int] = [:]
            ranks.reserveCapacity(rankCount)
            var expectedRank = 0
            for line in source.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 2, let bytes = Data(base64Encoded: String(fields[0])),
                      !bytes.isEmpty, bytes.count <= 128, let rank = Int(fields[1]), rank == expectedRank,
                      ranks.updateValue(rank, forKey: bytes) == nil else { throw Failure.invalidResource }
                expectedRank += 1
            }
            guard source.last == "\n", expectedRank == rankCount,
                  (0...255).allSatisfy({ ranks[Data([UInt8($0)])] != nil }) else { throw Failure.invalidResource }
            self.ranks = ranks
            self.unicodeGuard = try UnicodeGuard(data: unicodeData)
            guard let expression = try? NSRegularExpression(pattern: GroqBodyTokenCounter.pretokenizationPattern) else {
                throw Failure.patternUnavailable
            }
            self.expression = expression
        }

        func tokenCount(_ text: String) throws -> Int {
            guard text.utf8.count <= maximumUTF8Bytes else { throw Failure.inputTooLarge }
            try Task.checkCancellation()
            try unicodeGuard.validate(text)
            if unicodeGuard.isEntirelyWhitespace(text) {
                // The pinned pattern takes all whitespace through the final
                // CR/LF, then the trailing whitespace. Avoid ICU backtracking
                // limits for a maximum-sized space-only input without changing
                // either piece or its BPE boundaries.
                let bytes = Array(text.utf8)
                if let newline = bytes.lastIndex(where: { $0 == 10 || $0 == 13 }) {
                    return try countPiece(Array(bytes[...newline])) + countPiece(Array(bytes.dropFirst(newline + 1)))
                }
                return try countPiece(bytes)
            }
            let source = text as NSString
            var offset = 0, total = 0
            var failure: (any Error)?
            expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { result, _, stop in
                guard let result, result.range.location == offset, result.range.length > 0 else {
                    failure = Failure.unmatchedText; stop.pointee = true; return
                }
                do {
                    try Task.checkCancellation()
                    let piece = Array(source.substring(with: result.range).utf8)
                    total += try countPiece(piece)
                    offset = NSMaxRange(result.range)
                } catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            guard offset == source.length else { throw Failure.unmatchedText }
            return total
        }

        /// Greedy adjacent byte-pair merges. Ties choose the leftmost pair, as in
        /// tiktoken. Each merge creates at most two heap entries; stale entries
        /// are discarded by node identity/version, so long pieces avoid O(n²).
        private func countPiece(_ bytes: [UInt8]) throws -> Int {
            if bytes.isEmpty { return 0 }
            if ranks[Data(bytes)] != nil { return 1 }
            var segments = bytes.indices.map { Segment(start: $0, end: $0 + 1,
                previous: $0 - 1, next: $0 + 1 < bytes.count ? $0 + 1 : -1) }
            var heap = PairHeap()
            func candidate(_ left: Int) -> Pair? {
                guard left >= 0, segments[left].alive else { return nil }
                let right = segments[left].next
                guard right >= 0, segments[right].alive,
                      segments[right].end - segments[left].start <= 128,
                      let rank = ranks[Data(bytes[segments[left].start..<segments[right].end])] else { return nil }
                return Pair(rank: rank, left: left, right: right,
                            leftVersion: segments[left].version, rightVersion: segments[right].version)
            }
            for index in bytes.indices {
                if (index & 1_023) == 0 { try Task.checkCancellation() }
                if let value = candidate(index) { heap.push(value) }
            }
            var count = bytes.count, popped = 0
            while let pair = heap.pop() {
                popped += 1
                if (popped & 1_023) == 0 { try Task.checkCancellation() }
                guard segments[pair.left].alive, segments[pair.right].alive,
                      segments[pair.left].next == pair.right,
                      segments[pair.left].version == pair.leftVersion,
                      segments[pair.right].version == pair.rightVersion else { continue }
                let next = segments[pair.right].next
                segments[pair.left].end = segments[pair.right].end
                segments[pair.left].next = next
                segments[pair.left].version += 1
                segments[pair.right].alive = false
                segments[pair.right].version += 1
                if next >= 0 { segments[next].previous = pair.left }
                count -= 1
                if let value = candidate(segments[pair.left].previous) { heap.push(value) }
                if let value = candidate(pair.left) { heap.push(value) }
            }
            return count
        }
    }

    /// The pinned tiktoken Rust kernel supplies these categories directly. ICU
    /// may use a different Unicode version: a mismatch fails closed instead of
    /// assuming that a newer script or unassigned scalar has the same boundary.
    private struct UnicodeGuard: Sendable {
        struct Reference: Decodable {
            let schemaVersion: Int
            let patterns: [String]
            let ranges: [[UInt32]]
            let contractionCaseFolds: [String: String]
        }
        let ranges: [[UInt32]]
        let expressions: [NSRegularExpression]

        init(data: Data) throws {
            guard data.count == unicodeFileBytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == unicodeFileSHA256,
                  let reference = try? JSONDecoder().decode(Reference.self, from: data),
                  reference.schemaVersion == 1, reference.patterns == categoryPatterns,
                  reference.contractionCaseFolds == ["s": "Ssſ", "t": "Tt", "r": "Rr", "e": "Ee",
                                                      "v": "Vv", "m": "Mm", "l": "Ll", "d": "Dd"],
                  !reference.ranges.isEmpty, reference.ranges.count <= 10_000 else { throw Failure.invalidResource }
            var previous: UInt32?
            for row in reference.ranges {
                guard row.count == 3, row[0] <= row[1], row[1] <= 0x10ffff,
                      row[1] < 0xd800 || row[0] > 0xdfff,
                      (1...6).contains(row[2]), previous == nil || row[0] > previous! else {
                    throw Failure.invalidResource
                }
                previous = row[1]
            }
            ranges = reference.ranges
            do { expressions = try categoryPatterns.map { try NSRegularExpression(pattern: $0) } }
            catch { throw Failure.patternUnavailable }
        }

        func validate(_ text: String) throws {
            guard !text.utf8.allSatisfy({ $0 < 128 }) else { return }
            var expected = [[NSRange]](repeating: [], count: categoryPatterns.count)
            var offset = 0, count = 0
            for scalar in text.unicodeScalars {
                count += 1
                if (count & 1_023) == 0 { try Task.checkCancellation() }
                let length = scalar.value > 0xffff ? 2 : 1
                if let category = category(scalar.value) {
                    let index = category - 1
                    if let last = expected[index].last, NSMaxRange(last) == offset {
                        expected[index][expected[index].count - 1].length += length
                    } else { expected[index].append(NSRange(location: offset, length: length)) }
                }
                offset += length
            }
            for (index, expression) in expressions.enumerated() {
                try Task.checkCancellation()
                var cursor = 0, mismatch = false
                expression.enumerateMatches(in: text, range: NSRange(location: 0, length: offset)) { match, _, stop in
                    guard let match, cursor < expected[index].count,
                          match.range == expected[index][cursor] else {
                        mismatch = true; stop.pointee = true; return
                    }
                    cursor += 1
                }
                guard !mismatch, cursor == expected[index].count else { throw Failure.unicodeCategoryMismatch }
            }
        }

        func isEntirelyWhitespace(_ text: String) -> Bool {
            text.unicodeScalars.allSatisfy { category($0.value) == 6 }
        }

        private func category(_ scalar: UInt32) -> Int? {
            var low = 0, high = ranges.count
            while low < high {
                let middle = low + (high - low) / 2
                if ranges[middle][1] < scalar { low = middle + 1 } else { high = middle }
            }
            guard low < ranges.count, ranges[low][0] <= scalar else { return nil }
            return Int(ranges[low][2])
        }
    }

    private struct Segment {
        let start: Int
        var end: Int
        var previous: Int
        var next: Int
        var version = 0
        var alive = true
    }

    private struct Pair {
        let rank: Int
        let left: Int
        let right: Int
        let leftVersion: Int
        let rightVersion: Int
        func precedes(_ other: Pair) -> Bool { rank == other.rank ? left < other.left : rank < other.rank }
    }

    private struct PairHeap {
        private var values: [Pair] = []
        mutating func push(_ value: Pair) {
            values.append(value)
            var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard values[child].precedes(values[parent]) else { break }
                values.swapAt(child, parent); child = parent
            }
        }
        mutating func pop() -> Pair? {
            guard !values.isEmpty else { return nil }
            let result = values[0], last = values.removeLast()
            if values.isEmpty { return result }
            values[0] = last
            var parent = 0
            while parent * 2 + 1 < values.count {
                let left = parent * 2 + 1, right = left + 1
                let child = right < values.count && values[right].precedes(values[left]) ? right : left
                guard values[child].precedes(values[parent]) else { break }
                values.swapAt(child, parent); parent = child
            }
            return result
        }
    }
}
