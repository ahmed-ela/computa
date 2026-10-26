import Foundation
import XCTest
@testable import Computa

final class ComputerTaskScopeTests: XCTestCase {
    func testBackgroundBrowserOnlyRejectsNativeFallback() {
        for prompt in ["Use background browser tools only. Check my inbox.",
                       "Please use background-only Chrome to check my inbox.",
                       "Use Chrome tab tools only in the background."] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertTrue(scope.backgroundBrowserOnly, prompt)
            for tool in ["computer_v2_open", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_type",
                         "computer_v2_capture", "computer_v2_verify", "desktop_input"] {
                XCTAssertNotNil(scope.toolViolation(tool: tool), tool)
            }
            for tool in ["computer_v2_status", "computer_v2_apps", "browser_tabs", "browser_read"] {
                XCTAssertNil(scope.toolViolation(tool: tool), tool)
            }
        }
    }

    func testMentioningBackgroundOrNegatingItDoesNotCreateARestriction() {
        for prompt in ["Is background Chrome faster?", "Do not use background Chrome tools only.",
                       "Check Gmail using Chrome", "Open Chrome in the foreground."] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertFalse(scope.backgroundBrowserOnly, prompt)
            XCTAssertNil(scope.toolViolation(tool: "computer_v2_open"))
        }
    }

    func testGmailTaskRejectsDistractorSitesRegardlessOfTitleOrQueryText() throws {
        let scope = ComputerTaskScope(userPrompt: "check when my united flight is using gmail chrome")
        XCTAssertEqual(scope.targetConfidence, .recognizedService)
        XCTAssertNil(scope.candidateViolation(url: try url("https://mail.google.com/mail/u/0/#inbox"), title: "Inbox"))
        for raw in ["https://github.com/amebuilds/Computa", "https://chatgpt.com/c/123", "https://dash.cloudflare.com",
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

    func testTroubleshootingProductMentionsDoNotCreateExclusiveSiteRestrictions() throws {
        let reported = "Help me enable Chrome access through ChatGPT’s supported settings. Focus on read-only Terminal diagnostics to identify why “Local browser use is disabled in Work settings” appears. Find the documented setting or supported command, and explain any action I must perform myself. Don’t alter internal permission databases or override safety restrictions. This is a read-only troubleshooting request: do not change settings or configuration files; report your findings and the supported user steps."
        for prompt in [reported, "Why does ChatGPT refuse to act? Find its documentation.",
                       "Read ChatGPT documentation", "Read ChatGPT’s support article",
                       "Research how to use Gmail", "Find news on ChatGPT",
                       "Research changes in Outlook", "Explain GitHub permissions"] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertEqual(scope.targetConfidence, .unknown, prompt)
            XCTAssertFalse(scope.hasCandidateRestriction, prompt)
            XCTAssertNil(scope.siteViolation(url: try url("https://help.openai.com/")), prompt)
            XCTAssertNil(scope.siteViolation(url: try url("https://support.openai.com/")), prompt)
            XCTAssertFalse(scope.externalBrowserOnly, prompt)
        }
    }

    func testConcreteServiceDestinationsStillRejectOtherSites() throws {
        for prompt in ["Open ChatGPT", "Use only ChatGPT. Find its settings.",
                       "Can you open ChatGPT in the built-in browser?",
                       "In ChatGPT, read my last conversation.", "Read the page on ChatGPT"] {
            let scope = ComputerTaskScope(userPrompt: prompt)
            XCTAssertEqual(scope.targetConfidence, .recognizedService, prompt)
            XCTAssertNil(scope.siteViolation(url: try url("https://chatgpt.com/")), prompt)
            XCTAssertNotNil(scope.siteViolation(url: try url("https://help.openai.com/")), prompt)
        }
        let outlook = ComputerTaskScope(userPrompt: "Find the evidence packet sent by Uny to my Outlook account neh6vw. Use the built-in browser and tell me the attachment filename. Do not send, forward, download, or delete anything.")
        XCTAssertEqual(outlook.targetConfidence, .recognizedService)
        XCTAssertNil(outlook.siteViolation(url: try url("https://outlook.live.com/mail/")))
        XCTAssertNotNil(outlook.siteViolation(url: try url("https://example.com/")))
        let wikipedia = ComputerTaskScope(userPrompt: "Read the requested page on Wikipedia using the built-in browser.")
        XCTAssertEqual(wikipedia.targetConfidence, .recognizedService)
        XCTAssertNil(wikipedia.siteViolation(url: try url("https://en.wikipedia.org/wiki/Browser")))
        XCTAssertNotNil(wikipedia.siteViolation(url: try url("https://example.com/")))
    }

    func testDocumentationTopicPreservesAnExplicitDestination() throws {
        let scope = ComputerTaskScope(userPrompt: "Read ChatGPT documentation at https://help.openai.com/")
        XCTAssertEqual(scope.targetConfidence, .explicitURL)
        XCTAssertNil(scope.siteViolation(url: try url("https://help.openai.com/en/articles/123")))
        XCTAssertNotNil(scope.siteViolation(url: try url("https://chatgpt.com/")))
        XCTAssertNotNil(scope.siteViolation(url: try url("https://help.openai.com.attacker.test/")))
    }

    func testRejectedDestinationGuidesAuthorizedOpeningWithoutClaimingContentAbsence() throws {
        let scope = ComputerTaskScope(userPrompt: "Read my Outlook inbox")
        let diagnostic = try XCTUnwrap(scope.siteViolation(url: try url("https://example.com/")))
        XCTAssertTrue(diagnostic.contains("browser_open"))
        XCTAssertTrue(diagnostic.contains("when authorized by the request"))
        XCTAssertTrue(diagnostic.contains("A missing inventory tab does not prove"))
        XCTAssertFalse(diagnostic.contains("report that it was not found"))
    }

    func testTopicMentionDoesNotEraseExplicitTitleOrBrowserConstraints() throws {
        let title = ComputerTaskScope(userPrompt: "Read ChatGPT documentation in the tab titled \"Support article\".")
        XCTAssertEqual(title.targetConfidence, .exactTabTitle)
        XCTAssertNil(title.candidateViolation(url: try url("https://help.openai.com/"), title: "Support article"))
        XCTAssertNotNil(title.candidateViolation(url: try url("https://help.openai.com/"), title: "Unrelated"))
        let browser = ComputerTaskScope(userPrompt: "Use Chrome only. Research ChatGPT documentation.")
        XCTAssertEqual(browser.targetConfidence, .unknown)
        XCTAssertNotNil(browser.embeddedBrowserToolViolation())
    }

    func testOutlookScopeIncludesDedicatedMailHostsAndOnlyItsProductLandingPath() throws {
        let scope = ComputerTaskScope(userPrompt: "Read my Outlook inbox")
        for raw in [
            "https://outlook.live.com/mail/", "https://outlook.office.com/mail/",
            "https://outlook.office365.com/mail/", "https://outlook.cloud.microsoft/mail",
            "https://www.microsoft.com/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook?deeplink=%2Fmail%2F&sdf=0&sessionId=opaque",
            "https://www.microsoft.com/fr-fr/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook/",
            "https://www.microsoft.com/en/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook",
            "https://www.microsoft.com/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook",
        ] {
            XCTAssertNil(scope.siteViolation(url: try url(raw)), raw)
        }
        for raw in [
            "https://www.microsoft.com/", "https://www.microsoft.com/en-us/microsoft-365/",
            "https://www.microsoft.com/en-us/microsoft-365/outlook/another-product",
            "https://www.microsoft.com/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook/other",
            "https://www.microsoft.com.attacker.test/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook",
            "http://www.microsoft.com/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook",
            "https://www.microsoft.com:444/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook",
            "https://user:secret@www.microsoft.com/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook",
        ] {
            XCTAssertNotNil(scope.siteViolation(url: try url(raw)), raw)
        }
    }

    func testOutlookScopeAcceptsOnlyTheObservedSignInForwardLink() throws {
        let scope = ComputerTaskScope(userPrompt: "Read my Outlook inbox")
        for raw in [
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2F&sessionId=opaque",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2Finbox&sessionId=opaque",
            "https://go.microsoft.com/fwlink/p?LinkID=2125442",
            "https://go.microsoft.com:443/fwlink/p/?linkid=2125442&deeplink=mail%2F",
        ] {
            XCTAssertNil(scope.siteViolation(url: try url(raw)), raw)
        }
        for raw in [
            "https://go.microsoft.com/fwlink/p/", "https://go.microsoft.com/fwlink/p/?LinkID=1",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&LinkID=2125442",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&linkid=1",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=https%3A%2F%2Fattacker.test",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2Fother",
            "https://go.microsoft.com/fwlink/p/?LinkID=1&deeplink=mail%2Finbox",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2Finbox%2Fother",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2Finbox%3Fnext%3Dhttps%3A%2F%2Fattacker.test",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%252Finbox",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2Finbox&DEEPLink=mail%2Finbox",
            "https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2F&deeplink=mail%2F",
            "https://go.microsoft.com/fwlink/?LinkID=2125442", "https://go.microsoft.com/other?LinkID=2125442",
            "http://go.microsoft.com/fwlink/p/?LinkID=2125442", "https://go.microsoft.com:444/fwlink/p/?LinkID=2125442",
            "https://user@go.microsoft.com/fwlink/p/?LinkID=2125442",
        ] {
            XCTAssertNotNil(scope.siteViolation(url: try url(raw)), raw)
        }
    }

    func testOutlookAuthorizationRequiresAnExactKnownMailDestinationOrOutlookResource() throws {
        let scope = ComputerTaskScope(userPrompt: "Read my Outlook inbox")
        let authorization = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        for host in ["outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft"] {
            for path in ["/mail", "/mail/"] {
                var components = try XCTUnwrap(URLComponents(string: authorization))
                components.queryItems = [URLQueryItem(name: "redirect_uri", value: "https://" + host + path),
                                         URLQueryItem(name: "scope", value: "openid profile https://outlook.office.com/.default")]
                XCTAssertNil(scope.siteViolation(url: try XCTUnwrap(components.url)), host + path)
            }
        }
        for query in [
            "redirect_uri=https%3A%2F%2Foutlook.live.com%2Fmail%2F&scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "redirect_uri=https%3A%2F%2Foutlook.cloud.microsoft%2Fmail&scope=openid%20profile",
            "redirect_uri=https%3A%2F%2Foutlook.office.com%2Fmail%2F",
            "scope=openid%20https%3A%2F%2Foutlook.office.com%2F.default",
        ] {
            XCTAssertNil(scope.siteViolation(url: try url(authorization + "?" + query)), query)
        }
        for query in [
            "", "scope=openid%20profile", "redirect_uri=", "redirect_uri=https%3A%2F%2Fattacker.test%2Fmail%2F",
            "redirect_uri=https%3A%2F%2Foutlook.live.com.attacker.test%2Fmail%2F&scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "redirect_uri=http%3A%2F%2Foutlook.live.com%2Fmail%2F",
            "redirect_uri=https%3A%2F%2Foutlook.live.com%3A444%2Fmail%2F",
            "redirect_uri=https%3A%2F%2Foutlook.live.com%2Fmail%2Fother",
            "redirect_uri=https%3A%2F%2Foutlook.live.com%2Fmail%2F%3Fnext%3Dhttps%3A%2F%2Fattacker.test",
            "redirect_uri=https%3A%2F%2Foutlook.live.com%2Fmail%2F&REDIRECT_URI=https%3A%2F%2Foutlook.live.com%2Fmail%2F",
            "scope=https%3A%2F%2Foutlook.office.com%2F.default&SCOPE=openid",
        ] {
            XCTAssertNotNil(scope.siteViolation(url: try url(authorization + "?" + query)), query)
        }
        for raw in [
            "https://login.microsoftonline.com/other/oauth2/v2.0/authorize?scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "https://login.microsoftonline.com/common/other?scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "https://login.microsoftonline.com.attacker.test/common/oauth2/v2.0/authorize?scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "http://login.microsoftonline.com/common/oauth2/v2.0/authorize?scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "https://login.microsoftonline.com:444/common/oauth2/v2.0/authorize?scope=https%3A%2F%2Foutlook.office.com%2F.default",
            "https://user@login.microsoftonline.com/common/oauth2/v2.0/authorize?scope=https%3A%2F%2Foutlook.office.com%2F.default",
        ] {
            XCTAssertNotNil(scope.siteViolation(url: try url(raw)), raw)
        }
    }

    func testOutlookSupplementalRoutesDoNotExpandExplicitURLOrOtherServiceScopes() throws {
        let landing = try url("https://www.microsoft.com/en-us/microsoft-365/outlook/email-and-calendar-software-microsoft-outlook")
        let authorization = try url("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?redirect_uri=https%3A%2F%2Foutlook.live.com%2Fmail%2F")
        let forward = try url("https://go.microsoft.com/fwlink/p/?LinkID=2125442")
        let inboxForward = try url("https://go.microsoft.com/fwlink/p/?LinkID=2125442&deeplink=mail%2Finbox")
        let explicit = ComputerTaskScope(userPrompt: "Read Outlook at https://outlook.live.com/mail/")
        XCTAssertEqual(explicit.targetConfidence, .explicitURL)
        XCTAssertNil(explicit.siteViolation(url: try url("https://outlook.live.com/mail/")))
        for scope in [explicit, ComputerTaskScope(userPrompt: "Read Gmail")] {
            for destination in [landing, authorization, forward, inboxForward] {
                XCTAssertNotNil(scope.siteViolation(url: destination), destination.absoluteString)
            }
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
        let titleOnly = ComputerTaskScope(userPrompt: "In the existing tab titled “Computa Fixture”, read the totals.")
        XCTAssertEqual(titleOnly.targetConfidence, .exactTabTitle)
        XCTAssertNil(titleOnly.candidateViolation(url: try url("http://localhost:9999/"), title: "Computa Fixture"))
    }

    func testInventoryMatchReusesTheExistingExactCandidateRestriction() throws {
        let scope = ComputerTaskScope(userPrompt: "Inspect https://fixture.example:8123. Use tab titled \"Result\".")
        for (raw, title) in [("https://fixture.example:8123/view", "Result"),
                             ("https://fixture.example:8124/view", "Result"),
                             ("https://fixture.example.attacker.test:8123/view", "Result"),
                             ("https://fixture.example:8123/view", "Result archive")] {
            XCTAssertEqual(scope.candidateMatch(url: try url(raw), title: title),
                           scope.candidateViolation(url: try url(raw), title: title) == nil)
        }
        XCTAssertEqual(scope.candidateMatch(url: try url("https://fixture.example:8123/view"), title: "Result"), true)
        for prompt in ["Inspect a tab", "Compare https://one.example and https://two.example"] {
            let unrestricted = ComputerTaskScope(userPrompt: prompt)
            XCTAssertFalse(unrestricted.hasCandidateRestriction)
            XCTAssertNil(unrestricted.candidateMatch(url: try url("https://one.example"), title: "Result"))
        }
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











    private func url(_ value: String) throws -> URL { try XCTUnwrap(URL(string: value)) }
}
