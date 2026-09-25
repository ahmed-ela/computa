import XCTest
@testable import AutomationCore

final class ApprovedFocusHandoffTests: XCTestCase {
    func testRequiresContinuousExactFocus() {
        var handoff = ApprovedFocusHandoff()
        for _ in 0..<11 { XCTAssertEqual(handoff.observe(.focused, foreground: .target), .wait) }
        XCTAssertEqual(handoff.observe(.windowNotFocused, foreground: .target), .wait)
        for _ in 0..<11 { XCTAssertEqual(handoff.observe(.focused, foreground: .target), .wait) }
        XCTAssertEqual(handoff.observe(.focused, foreground: .target), .ready)
    }

    func testOwnApprovalHostCanBeRecoveredOnlyOnce() {
        var handoff = ApprovedFocusHandoff()
        XCTAssertEqual(handoff.observe(.focused, foreground: .target), .wait)
        XCTAssertEqual(handoff.observe(.applicationNotFocused, foreground: .approvalHost), .restoreOnce)
        XCTAssertEqual(handoff.observe(.applicationNotFocused, foreground: .approvalHost), .wait)
        for _ in 0..<11 { XCTAssertEqual(handoff.observe(.focused, foreground: .target), .wait) }
        XCTAssertEqual(handoff.observe(.focused, foreground: .target), .ready)
    }

    func testAnotherApplicationPermanentlyStopsHandoff() {
        for foreground in [ApprovedFocusHandoff.Foreground.other, .unknown] {
            var handoff = ApprovedFocusHandoff()
            XCTAssertEqual(handoff.observe(.applicationNotFocused, foreground: foreground), .stop)
            XCTAssertEqual(handoff.observe(.applicationNotFocused, foreground: .approvalHost), .stop)
            XCTAssertEqual(handoff.observe(.focused, foreground: .target), .stop)
        }
    }

    func testDisagreeingForegroundCannotBecomeReady() {
        var handoff = ApprovedFocusHandoff()
        XCTAssertEqual(handoff.observe(.focused, foreground: .approvalHost), .restoreOnce)
        for _ in 0..<79 { XCTAssertEqual(handoff.observe(.focused, foreground: .approvalHost), .wait) }
        XCTAssertEqual(handoff.observe(.focused, foreground: .target), .stop)
    }

    func testWindowChangeDoesNotAuthorizeAnotherRaiseOrInput() {
        var handoff = ApprovedFocusHandoff()
        for _ in 0..<80 { XCTAssertEqual(handoff.observe(.windowNotFocused, foreground: .target), .wait) }
        XCTAssertEqual(handoff.observe(.windowNotFocused, foreground: .target), .stop)
    }
}
