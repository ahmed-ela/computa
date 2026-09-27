import Foundation
import XCTest
@testable import Mactopus

final class ComputerTaskScopeTests: XCTestCase {
    func testBackgroundOnlyIsExplicitAndIndependentOfModelActivationArguments() {
        for prompt in [
            "Use the background Chrome tab tools only. Check my Gmail.",
            "Please use background-only Chrome to check my inbox.",
            "Use Chrome tab tools only in the background.",
        ] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertTrue(scope.backgroundChromeOnly, prompt)
            for tool in ["computer_v2_open", "computer_v2_type", "computer_v2_keypress", "computer_v2_click",
                         "computer_v2_capture", "computer_v2_pointer", "computer_v2_ground_click", "computer",
                         "desktop_open_application", "desktop_input", "desktop_perform_action", "desktop_set_text"] {
                XCTAssertNotNil(scope.toolViolation(tool: tool, hasBorrowedBinding: true), tool)
            }
            for tool in ["computer_v2_status", "computer_v2_apps", "computer_v2_tabs", "computer_v2_bind_tab"] {
                XCTAssertNil(scope.toolViolation(tool: tool, hasBorrowedBinding: false), tool)
            }
            for tool in ["computer_v2_snapshot", "computer_v2_ax", "computer_v2_set_text", "computer_v2_verify"] {
                XCTAssertNotNil(scope.toolViolation(tool: tool, hasBorrowedBinding: false), tool)
                XCTAssertNil(scope.toolViolation(tool: tool, hasBorrowedBinding: true), tool)
            }
        }
    }

    func testMentioningBackgroundOrNegatingItDoesNotCreateARestriction() {
        for prompt in ["Is background Chrome faster?", "Do not use background Chrome tools only.",
                       "Check Gmail using Chrome", "Open Chrome in the foreground."] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertFalse(scope.backgroundChromeOnly, prompt)
            XCTAssertNil(scope.toolViolation(tool: "computer_v2_open", hasBorrowedBinding: false))
        }
    }

    func testGmailTaskRejectsDistractorSitesRegardlessOfTitleOrQueryText() throws {
        let scope = ComputerTaskScope(userPrompt: "check when my united flight is using gmail chrome")
        XCTAssertEqual(scope.targetConfidence, .recognizedService)
        XCTAssertNil(scope.candidateViolation(url: try url("https://mail.google.com/mail/u/0/#inbox"), title: "Inbox"))
        for raw in ["https://github.com/amebuilds/Mactopus", "https://chatgpt.com/c/123", "https://dash.cloudflare.com",
                    "https://mail.google.com.attacker.test/", "https://attacker.test/?url=https://mail.google.com",
                    "https://mail.google.com@attacker.test/"] {
            XCTAssertNotNil(scope.candidateViolation(url: try url(raw), title: "Gmail — flight search complete"), raw)
        }
    }

    func testKnownIdentityChecksAreNotGmailSpecific() throws {
        for (prompt, accepted) in [
            ("Read my Outlook inbox", "https://outlook.office.com/mail/"),
            ("Check my YouTube feed", "https://www.youtube.com/"),
            ("Read my GitHub issues", "https://github.com/issues"),
            ("Read my Google Calendar", "https://calendar.google.com/calendar/u/0/r"),
            ("Read Google Drive", "https://drive.google.com/drive/u/0/my-drive"),
            ("Read Google Docs", "https://docs.google.com/document/d/abc"),
        ] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertEqual(scope.targetConfidence, .recognizedService, prompt)
            XCTAssertNil(scope.candidateViolation(url: try url(accepted), title: "Anything"), prompt)
            XCTAssertNotNil(scope.candidateViolation(url: try url("https://example.com"), title: prompt), prompt)
        }
    }

    func testExplicitURLMatchesHostAndPortNotMisleadingSubstring() throws {
        let scope = ComputerTaskScope(userPrompt: "Inspect https://fixture.example:8123/search?q=flights.")
        XCTAssertEqual(scope.targetConfidence, .explicitURL)
        XCTAssertNil(scope.candidateViolation(url: try url("https://fixture.example:8123/results"), title: "Results"))
        XCTAssertNotNil(scope.candidateViolation(url: try url("https://fixture.example:8124/search"), title: "Results"))
        XCTAssertNotNil(scope.candidateViolation(url: try url("https://fixture.example.attacker.test:8123"), title: "Results"))
        XCTAssertNotNil(scope.candidateViolation(url: try url("https://user:password@fixture.example:8123"), title: "Results"))
    }

    func testExactTitleRequiresExactNormalizedTitleAndCannotOverrideKnownSite() throws {
        let scope = ComputerTaskScope(userPrompt: "In Gmail, use the tab titled \"Flight   Inbox\".")
        XCTAssertNil(scope.candidateViolation(url: try url("https://mail.google.com/mail/u/0/"), title: "flight inbox"))
        XCTAssertNotNil(scope.candidateViolation(url: try url("https://mail.google.com/mail/u/0/"), title: "Flight Inbox Archive"))
        XCTAssertNotNil(scope.candidateViolation(url: try url("https://github.com/"), title: "Flight Inbox"))
        XCTAssertNil(scope.siteViolation(url: try url("https://mail.google.com/mail/u/0/")))
        XCTAssertNotNil(scope.siteViolation(url: try url("https://github.com/")))
        let titleOnly = ComputerTaskScope(userPrompt: "In the existing tab titled “Mactopus Fixture”, read the totals.")
        XCTAssertEqual(titleOnly.targetConfidence, .exactTabTitle)
        XCTAssertNil(titleOnly.candidateViolation(url: try url("http://localhost:9999/"), title: "Mactopus Fixture"))
    }

    func testUnknownAndAmbiguousIntentIsNotPretendedToBeSemanticallyVerified() throws {
        let unknown = ComputerTaskScope(userPrompt: "Check my recent message.")
        XCTAssertEqual(unknown.targetConfidence, .unknown)
        XCTAssertNil(unknown.candidateViolation(url: try url("https://example.com"), title: "Message"))
        for prompt in ["Compare Gmail and Outlook", "Find YouTube links in Gmail", "Read Gmail at https://github.com",
                       "Compare https://one.example and https://two.example", "Compare tabs named \"One\" and tab named \"Two\""] {
            XCTAssertEqual(ComputerTaskScope(userPrompt: prompt).targetConfidence, .ambiguous, prompt)
        }
        XCTAssertEqual(ComputerTaskScope(userPrompt: "Do not use Gmail. Check Outlook.").targetConfidence, .recognizedService)
        XCTAssertNotNil(ComputerTaskScope(userPrompt: "Do not use Gmail. Check Outlook.")
            .candidateViolation(url: try url("https://mail.google.com/"), title: "Gmail"))
    }

    func testUntargetedContinuationPreservesBackgroundAndSiteRestrictionsWithoutAffirmativeWordList() throws {
        let previous = ComputerTaskScope(userPrompt: "Use the background Chrome tab tools only. Read Gmail.")
        for prompt in ["yes", "Read the next message too.", "What does that say?", "Show the remaining details."] {
            let current = ComputerTaskScope(userPrompt: prompt)
            XCTAssertEqual(current.targetConfidence, .unknown)
            let continued = current.preservingContinuationRestrictions(from: previous, hasRetainedTarget: true)
            XCTAssertTrue(continued.backgroundChromeOnly)
            XCTAssertEqual(continued.targetConfidence, .recognizedService)
            XCTAssertNotNil(continued.toolViolation(tool: "computer_v2_open", hasBorrowedBinding: true))
            XCTAssertNotNil(continued.toolViolation(tool: "computer_v2_keypress", hasBorrowedBinding: true))
            XCTAssertNil(continued.candidateViolation(url: try url("https://mail.google.com/mail/u/0/"), title: "Inbox"))
            XCTAssertNotNil(continued.candidateViolation(url: try url("https://github.com/"), title: "Gmail"))
        }
    }

    func testContinuationCannotInheritWithoutRetainedAuthorizedTargetOrPriorScope() {
        let previous = ComputerTaskScope(userPrompt: "Use the background Chrome tab tools only. Read Gmail.")
        let current = ComputerTaskScope(userPrompt: "yes")
        XCTAssertEqual(current.preservingContinuationRestrictions(from: previous, hasRetainedTarget: false), current)
        XCTAssertEqual(current.preservingContinuationRestrictions(from: nil, hasRetainedTarget: true), current)
    }

    func testNewExplicitOrAmbiguousTargetWinsInsteadOfSilentlyInheritingOldDestination() throws {
        let previous = ComputerTaskScope(userPrompt: "Use the background Chrome tab tools only. Read Gmail.")
        for prompt in ["Read Outlook.", "Inspect https://github.com/fixture/repository.",
                       "Use the tab titled \"Different tab\".", "Compare Gmail and Outlook."] {
            let current = ComputerTaskScope(userPrompt: prompt)
            XCTAssertNotEqual(current.targetConfidence, .unknown)
            XCTAssertEqual(current.preservingContinuationRestrictions(from: previous, hasRetainedTarget: true), current)
        }
        let changed = ComputerTaskScope(userPrompt: "Read Outlook.")
            .preservingContinuationRestrictions(from: previous, hasRetainedTarget: true)
        XCTAssertNotNil(changed.candidateViolation(url: try url("https://mail.google.com/"), title: "Outlook"))
    }

    func testContinuationPreservesNewlyExplicitStricterBackgroundConstraint() {
        let previous = ComputerTaskScope(userPrompt: "Read Gmail.")
        let current = ComputerTaskScope(userPrompt: "Use the background Chrome tab tools only. Read the next item.")
        XCTAssertFalse(previous.backgroundChromeOnly)
        let continued = current.preservingContinuationRestrictions(from: previous, hasRetainedTarget: true)
        XCTAssertTrue(continued.backgroundChromeOnly)
        XCTAssertEqual(continued.targetConfidence, .recognizedService)
        XCTAssertNotNil(continued.toolViolation(tool: "computer_v2_open", hasBorrowedBinding: true))
    }

    func testContinuationRetainsExactTitleRestrictionAlongsideKnownSite() throws {
        let previous = ComputerTaskScope(userPrompt: "In Gmail use the tab titled \"Personal Inbox\".")
        let continued = ComputerTaskScope(userPrompt: "Continue reading.")
            .preservingContinuationRestrictions(from: previous, hasRetainedTarget: true)
        XCTAssertNil(continued.candidateViolation(url: try url("https://mail.google.com/mail/u/0/"), title: "Personal Inbox"))
        XCTAssertNotNil(continued.candidateViolation(url: try url("https://mail.google.com/mail/u/1/"), title: "Work Inbox"))
    }

    private func url(_ value: String) throws -> URL { try XCTUnwrap(URL(string: value)) }
}
