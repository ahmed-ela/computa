import CryptoKit
import Foundation
import XCTest
@testable import Computa

final class GroqNativePermissionPresentationTests: XCTestCase {
    private typealias P = GroqNativePermissionPresentation
    private let sandbox = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is restricted."
    private func envelope(_ unit: String = P.fullSource, prefix: String? = nil, suffix: String = "") -> String {
        "<permissions instructions>\n" + (prefix ?? sandbox) + "\n" + unit + suffix + "</permissions instructions>"
    }
    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testExactNativeUnitReplacementRetainsEverySurroundingByteAndReversesExactly() throws {
        let prefix = "Unknown governing prefix café / cafe\u{301} 🙂\\quoted\n"
        let suffix = " The writable root is `/synthetic/root`.\n## Unknown current native suffix\nDO_NOT_CHANGE\n"
        let text = prefix + envelope(suffix: suffix) + "\nUnknown governing tail"
        let match = try XCTUnwrap(P.replacement(in: ["Other trusted instruction", text], enabled: true))
        XCTAssertEqual(match.partIndex, 1)
        let original = Data(text.utf8), full = Data(P.fullSource.utf8), compact = Data(P.compactSource.utf8)
        XCTAssertEqual(match.sourceUTF8, original)
        XCTAssertEqual(original.subdata(in: match.range), full)
        XCTAssertEqual(match.replacementUTF8, compact)
        var displayed = original; displayed.replaceSubrange(match.range, with: compact)
        XCTAssertEqual(displayed.subdata(in: 0..<match.range.lowerBound), original.subdata(in: 0..<match.range.lowerBound))
        let displayedTail = (match.range.lowerBound + compact.count)..<displayed.count
        XCTAssertEqual(displayed.subdata(in: displayedTail), original.subdata(in: match.range.upperBound..<original.count))
        displayed.replaceSubrange(match.range.lowerBound..<(match.range.lowerBound + compact.count), with: full)
        XCTAssertEqual(displayed, original, "Inverse substitution must restore every native byte")
    }

    func testDisabledForeignSplitAmbiguousAndUnknownVariantsRemainUnchanged() {
        let valid = envelope()
        XCTAssertNil(P.replacement(in: [valid], enabled: false))
        let changed = P.fullSource.replacingOccurrences(of: "Commands are run", with: "Commands can run")
        let variants = [[P.fullSource], [envelope(changed)], [envelope(String(P.fullSource.dropLast(2)))],
            [envelope(prefix: sandbox + " Unknown prefix")],
            [envelope(prefix: sandbox.replacingOccurrences(of: "restricted", with: "unknown"))],
            [valid, valid], [valid + valid], ["<permissions instructions>" + valid],
            [valid + "</permissions instructions>"], [envelope(P.fullSource + P.fullSource)],
            [String(valid.prefix(valid.count / 2)), String(valid.suffix(valid.count - valid.count / 2))]]
        for values in variants { XCTAssertNil(P.replacement(in: values, enabled: true)) }
        XCTAssertNil(P.replacement(in: Array(repeating: "inert", count: 129), enabled: true))
        XCTAssertNil(P.replacement(in: [String(repeating: "x", count: WebModelResponseCodec.maximumPromptBytes + 1)], enabled: true))
    }

    func testPinnedFullAndReviewedEquivalentTextCannotDriftAndRetainAllUniqueRuleGroups() {
        XCTAssertEqual(Data(P.fullSource.utf8).count, 3661)
        XCTAssertEqual(hash(Data(P.fullSource.utf8)), "85541a9738741407642b3c39bbe3781fbf8bb42f628d50e562c87738ab192b3a")
        XCTAssertEqual(Data(P.compactSource.utf8).count, 1915)
        XCTAssertEqual(hash(Data(P.compactSource.utf8)), "f306874f724edaa783a30df0593f228b6031e78a91c73502e51b6802482cbce2")
        let rules = ["user approval or an existing rule", "Evaluate every command segment independently", "(...)/$(...)",
            "Advanced forms", "not evaluated against rules", "sandbox_permissions=\"require_escalated\"",
            "justification to a short question", "user may persist", "likely sandbox-related network error",
            "DNS/host resolution", "registry/index access", "dependency download", "ALWAYS", "without messaging the user first",
            "privileged-directory writes", "GUI app launches", "destructive rm/git reset", "not explicitly requested",
            "Be judicious", "never circumvent approvals through other tools", "categorical, reasonably scoped", "rarely the whole command",
            "Avoid overly broad prefixes", "arbitrary-script", "heredoc/herestring", "Never provide prefix_rule for destructive"]
        for rule in rules { XCTAssertTrue(P.compactSource.contains(rule), rule) }
    }
}
