import Foundation
import XCTest
@testable import Macrouse

final class CompactionAssistantEvidenceTests: XCTestCase {
    func testShortActualReplyIsPreservedExactlyIncludingWhitespace() throws {
        let original = "\n\nKEY_SAVED  \n"
        let evidence = try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: original))
        XCTAssertEqual(evidence.text, original)
    }

    func testEmptyAndWhitespaceOnlyRepliesAreRejected() {
        for original in ["", " \t\r\n", "\u{2003}\u{00A0}\n"] {
            XCTAssertNil(CompactionAssistantEvidence(completedAssistantText: original))
        }
    }

    func testExactByteBoundaryStaysUnchanged() throws {
        for original in [String(repeating: "a", count: 2_048), String(repeating: "🙂", count: 512)] {
            XCTAssertEqual(original.utf8.count, 2_048)
            XCTAssertEqual(try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: original)).text, original)
        }
    }

    func testOversizedReplyUsesLabeledFirstAndLastPortionsWithinBudget() throws {
        let original = "FIRST_BOUNDARY" + String(repeating: "x", count: 4_096) + "LAST_BOUNDARY"
        let text = try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: original)).text
        XCTAssertTrue(text.hasPrefix("[Historical completed assistant reply; excerpt]\nFIRST_BOUNDARY"))
        XCTAssertTrue(text.contains("\n[... middle omitted ...]\n"))
        XCTAssertTrue(text.hasSuffix("LAST_BOUNDARY"))
        XCTAssertEqual(text.utf8.count, 2_048)
    }

    func testUnicodeExcerptsPreserveOriginalBytesWithoutReplacementCharacters() throws {
        for unit in ["🙂", "漢", "é", "e\u{301}", "👩🏽‍💻", "🇸🇩"] {
            let original = String(repeating: unit, count: 2_100)
            let text = try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: original)).text
            let header = "[Historical completed assistant reply; excerpt]\n"
            let pieces = text.dropFirst(header.count).components(separatedBy: "\n[... middle omitted ...]\n")
            XCTAssertEqual(pieces.count, 2)
            XCTAssertFalse(text.contains("\u{FFFD}"))
            XCTAssertLessThanOrEqual(text.utf8.count, 2_048)
            XCTAssertTrue(Array(original.utf8).starts(with: pieces[0].utf8))
            XCTAssertTrue(Array(original.utf8.reversed()).starts(with: pieces[1].utf8.reversed()))
        }
    }

    func testEveryBoundaryNearUTF8CapRemainsBoundedAndDeterministic() throws {
        for count in 2_040...2_060 {
            let original = String(repeating: "a", count: count) + "🙂尾"
            let one = try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: original))
            let two = try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: original))
            XCTAssertEqual(one, two)
            XCTAssertLessThanOrEqual(one.text.utf8.count, 2_048)
            if original.utf8.count <= 2_048 { XCTAssertEqual(one.text, original) }
        }
    }

    func testResponsesItemContainsOnlyAssistantOutputText() throws {
        let evidence = try XCTUnwrap(CompactionAssistantEvidence(completedAssistantText: "ACTUAL_REPLY"))
        let item = evidence.responseItem
        XCTAssertEqual(Set(item.keys), ["type", "role", "content"])
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "assistant")
        let content = try XCTUnwrap(item["content"] as? [[String: String]])
        XCTAssertEqual(content, [["type": "output_text", "text": "ACTUAL_REPLY"]])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(item))
    }

    func testHydrationUsesNewestCompletedUserTurnFromDescendingPage() throws {
        let response = page([turn("new", text: "NEW_REPLY"), turn("old", text: "OLD_REPLY")])
        XCTAssertEqual(try XCTUnwrap(hydrate(response)).text, "NEW_REPLY")
    }

    func testHydrationNeverSkipsNewerLargeReplyForOldShortReply() throws {
        let huge = "NEW_FIRST" + String(repeating: "n", count: 3_000) + "NEW_LAST"
        let evidence = try XCTUnwrap(hydrate(page([turn("new", text: huge), turn("old", text: "OLD_REPLY")])))
        XCTAssertTrue(evidence.text.contains("NEW_FIRST"))
        XCTAssertTrue(evidence.text.hasSuffix("NEW_LAST"))
        XCTAssertFalse(evidence.text.contains("OLD_REPLY"))
        XCTAssertLessThanOrEqual(evidence.text.utf8.count, 2_048)
    }

    func testHydrationLegacyThreadTurnsAreChronological() throws {
        let response: [String: Any] = ["result": ["thread": ["turns": [turn("old", text: "OLD"), turn("new", text: "NEW")]]]]
        XCTAssertEqual(try XCTUnwrap(hydrate(response)).text, "NEW")
    }

    func testExplicitPageTakesPrecedenceAndMalformedPageCannotFallBack() throws {
        var response = page([turn("page", text: "PAGE")])
        var result = try XCTUnwrap(response["result"] as? [String: Any])
        result["thread"] = ["turns": [turn("legacy", text: "STALE")]]
        response["result"] = result
        XCTAssertEqual(try XCTUnwrap(hydrate(response)).text, "PAGE")
        for invalid in ["bad", ["data": "bad"], ["data": []]] as [Any] {
            result["initialTurnsPage"] = invalid
            response["result"] = result
            XCTAssertNil(hydrate(response))
        }
    }

    func testHydrationRejectsFailedInterruptedAndActiveTurns() throws {
        for status in ["failed", "interrupted"] {
            var invalid = turn("bad", text: "UNFINISHED")
            invalid["status"] = status
            XCTAssertNil(hydrate(page([invalid])))
            XCTAssertEqual(try XCTUnwrap(hydrate(page([invalid, turn("old", text: "COMPLETED")]))).text, "COMPLETED")
        }
        var active = turn("active", text: "NOT_FINAL")
        active["status"] = "inProgress"
        XCTAssertNil(hydrate(page([active, turn("old", text: "OLD")])))
    }

    func testHydrationRejectsMalformedOrPartialCompletedTurns() {
        for (key, value) in [("id", ""), ("itemsView", "summary"), ("itemsView", "notLoaded"),
                             ("error", "failed"), ("items", "not items"), ("status", NSNull())] as [(String, Any)] {
            var invalid = turn("bad", text: "DO_NOT_TRUST")
            invalid[key] = value
            XCTAssertNil(hydrate(page([invalid, turn("old", text: "STALE")])), key)
        }
    }

    func testStandaloneCompactionSummaryIsNotAssistantEvidence() throws {
        let maintenance: [String: Any] = ["id": "compact", "status": "completed", "items": [
            ["id": "compaction", "type": "contextCompaction"],
            assistant("SUMMARY_NOT_REPLY"),
        ]]
        XCTAssertNil(hydrate(page([maintenance])))
        XCTAssertEqual(try XCTUnwrap(hydrate(page([maintenance, turn("real", text: "ACTUAL_REPLY")]))).text, "ACTUAL_REPLY")
    }

    func testSameTurnAutomaticCompactionAllowsOnlyLaterRealReply() throws {
        var automatic = turn("auto", text: "EARLIER_TEXT")
        automatic["items"] = [user(), assistant("OLD_BEFORE_COMPACTION"),
            ["id": "compaction", "type": "contextCompaction"], assistant("AFTER_COMPACTION")]
        XCTAssertEqual(try XCTUnwrap(hydrate(page([automatic]))).text, "AFTER_COMPACTION")
        automatic["items"] = [user(), assistant("OLD_BEFORE_COMPACTION"), ["id": "compaction", "type": "contextCompaction"]]
        XCTAssertNil(hydrate(page([automatic, turn("old", text: "STALE")])))
    }

    func testReasoningToolsCommentaryAndWhitespaceCannotBecomeFinalEvidence() throws {
        var newest = turn("new", text: "ACTUAL_FINAL")
        newest["items"] = [user(), assistant("ACTUAL_FINAL"),
            ["id": "r", "type": "reasoning", "text": "REASONING"],
            ["id": "t", "type": "dynamicToolCall", "text": "TOOL"],
            ["id": "c", "type": "agentMessage", "phase": "commentary", "text": "COMMENTARY"],
            assistant(" \n\t")]
        XCTAssertEqual(try XCTUnwrap(hydrate(page([newest]))).text, "ACTUAL_FINAL")
        newest["items"] = [user(), ["id": "r", "type": "reasoning", "text": "THINKING"], assistant(" \n")]
        XCTAssertNil(hydrate(page([newest, turn("old", text: "STALE")])))
    }

    func testFinalAnswerAndAbsentOrNullPhaseAreAccepted() throws {
        for phase in [nil, NSNull(), "final_answer"] as [Any?] {
            var item = assistant("FINAL")
            item["phase"] = phase
            var value = turn("turn", text: "unused")
            value["items"] = [user(), item]
            XCTAssertEqual(try XCTUnwrap(hydrate(page([value]))).text, "FINAL")
        }
    }

    func testRealUserMessageIsRequiredNotAnEmptyOrFabricatedMarker() {
        for invalidUser in [
            ["id": "u", "type": "userMessage", "content": []],
            ["id": "u", "type": "userMessage", "content": [["type": "text", "text": " \n"]]],
            ["id": "u", "type": "userMessage", "content": [["type": "unknown", "text": "fake"]]],
            ["id": "", "type": "userMessage", "content": [["type": "text", "text": "request"]]],
        ] as [[String: Any]] {
            var value = turn("turn", text: "unused")
            value["items"] = [invalidUser, assistant("NOT_A_USER_TURN")]
            XCTAssertNil(hydrate(page([value])))
        }
    }

    func testHydrationWindowIsBoundedRatherThanScanningForOldEvidence() {
        let maintenance: [String: Any] = ["id": "compact", "status": "completed", "items": [["id": "c", "type": "contextCompaction"]]]
        let tooOld = Array(repeating: maintenance, count: CompactionAssistantEvidence.maximumHydratedTurns) + [turn("old", text: "TOO_OLD")]
        XCTAssertNil(hydrate(page(tooOld)))
        XCTAssertNil(hydrate(["result": ["thread": ["turns": Array(tooOld.reversed())]]]))
    }

    func testMalformedEnvelopeAndServerErrorsFailClosed() {
        for response in [[:], ["result": "bad"], ["error": ["message": "failed"], "result": ["initialTurnsPage": ["data": [turn("t", text: "BAD")]]]]] as [[String: Any]] {
            XCTAssertNil(hydrate(response))
        }
    }

    private func hydrate(_ value: [String: Any]) -> CompactionAssistantEvidence? {
        CompactionAssistantEvidence.latestCompletedUserTurn(inResumeResponse: value)
    }

    private func page(_ turns: [[String: Any]]) -> [String: Any] {
        ["result": ["initialTurnsPage": ["data": turns]]]
    }

    private func turn(_ id: String, text: String) -> [String: Any] {
        ["id": id, "status": "completed", "itemsView": "full", "error": NSNull(), "items": [user(), assistant(text)]]
    }

    private func user() -> [String: Any] {
        ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Actual user request"]]]
    }

    private func assistant(_ text: String) -> [String: Any] {
        ["id": "assistant", "type": "agentMessage", "text": text]
    }
}
