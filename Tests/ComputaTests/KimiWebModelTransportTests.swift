import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class KimiWebModelTransportTests: XCTestCase {
    private let choice = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant")
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")

    func testDiscoveryExportsOnlyPlainChatInstantWithoutSendingOrDeleting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertEqual(choices, [choice], "The observed menu also contains two unqualified agent choices")
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testDiscoveryFromNestedK3VerifiesItsCheckedRowWithoutSelectingItOrExposingIt() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertEqual(choices, [choice])
        let state = try await evaluate(fixture.view, """
            return {label:document.querySelector('.current-model .name').textContent,
                checked:document.querySelector('[data-testid="model-more-option"]').getAttribute('aria-checked'),
                opens:kimiFixture.counters.moreOpens, closes:kimiFixture.counters.moreCloses,
                nestedSelections:kimiFixture.counters.moreSelections, selections:kimiFixture.counters.modelSelections};
            """) as? [String: Any]
        XCTAssertEqual(state?["label"] as? String, "K3")
        XCTAssertEqual(state?["checked"] as? String, "true")
        XCTAssertEqual(state?["opens"] as? Int, 1); XCTAssertEqual(state?["closes"] as? Int, 1)
        XCTAssertEqual(state?["nestedSelections"] as? Int, 0); XCTAssertEqual(state?["selections"] as? Int, 0)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testStalledNestedDiscoveryRetainsFiniteLastObservationBeforeClosingWithoutReplaying() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(3))
        var installed = false, terminalBeforeClose = false
        var records: [String] = []
        fixture.transport.setKimiDiscoveryProgressObserverForTesting { record in
            records.append(record)
            if record.hasPrefix("event=terminal "), let id = fixture.createdID {
                terminalBeforeClose = fixture.browser.webView(for: id) === fixture.view
            }
        }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "discoverModels", !installed {
                installed = true
                _ = try? await self.evaluate(fixture.view, """
                    window.fixtureMoreDispatches = 0;
                    document.getElementById('fixture-more-trigger').addEventListener('mouseover', event => {
                        window.fixtureMoreDispatches++;
                        event.stopImmediatePropagation();
                    }, true);
                    return true;
                    """)
            }
        }
        do {
            _ = try await fixture.transport.discoverModels(provider: "kimi")
            XCTFail("An unacknowledged submenu open cannot complete discovery")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .preparationDeadline)
        }
        XCTAssertTrue(installed); XCTAssertTrue(terminalBeforeClose)
        let terminal = records.filter { $0.hasPrefix("event=terminal ") }
        XCTAssertEqual(terminal.count, 1)
        XCTAssertTrue(terminal.first?.contains("reason=preparation_timeout lastObservation phase=moreOpening") == true)
        XCTAssertTrue(terminal.first?.contains("submenuClaimed=true submenuPresent=false submenuExpanded=false submenuCollapsed=true") == true)
        XCTAssertLessThanOrEqual(records.count, 13)
        XCTAssertEqual(Set(records).count, records.count)
        for privateValue in ["K3", "Instant", "kimi.com", "fixture-more", fixture.createdID?.uuidString ?? "not-an-id"] {
            XCTAssertFalse(records.joined().contains(privateValue))
        }
        let clicks = try await evaluate(fixture.view, "return window.fixtureMoreDispatches;") as? Int
        XCTAssertEqual(clicks, 1)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testDelayedLegacyMouseSubmenuAcknowledgementsDoNotReplayEntryOrExit() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var configured = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, """
                    kimiFixture.options.moreOpenDelayMs = 100;
                    kimiFixture.options.moreCloseDelayMs = 100; return true;
                    """)
            }
        }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertEqual(choices, [choice]); XCTAssertTrue(configured)
        let actions = try await evaluate(fixture.view,
            "return [kimiFixture.counters.moreOpens,kimiFixture.counters.moreCloses,kimiFixture.counters.moreClicks,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(actions, [1, 1, 0, 0])
        try await assertMoreBoundaryEvents(fixture)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testSmallLayoutShiftKeepsTheClaimedPointAndSelectsInstantWithoutRetargeting() async throws {
        for boundary in ["pointerover", "pointerout"] {
            let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
            var configured = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !configured {
                    configured = true
                    _ = try? await self.evaluate(fixture.view, """
                        const target = document.getElementById('fixture-more-trigger');
                        target.addEventListener('\(boundary)', () => { target.style.transform = 'translate(4px, 2px)'; }, {once:true});
                        return true;
                        """)
                }
            }
            let token = try await start(fixture)
            XCTAssertTrue(configured)
            try await assertMoreBoundaryEvents(fixture, requireCentered: false)
            let value = try await evaluate(fixture.view, "return kimiFixture.moreEvents;")
            let rows = try XCTUnwrap(value as? [[String: Any]])
            guard rows.count == 8 else { XCTFail("Expected exactly one entry and exit boundary"); continue }
            XCTAssertTrue(rows.contains { $0["centered"] as? Bool == false }, "The fixture must actually move the center")
            for offset in [0, 4] {
                let x = try XCTUnwrap(rows[offset]["clientX"] as? Double), y = try XCTUnwrap(rows[offset]["clientY"] as? Double)
                for index in offset..<(offset + 4) {
                    let mouse = index % 4 >= 2
                    let actualX = try XCTUnwrap(rows[index]["clientX"] as? Double)
                    let actualY = try XCTUnwrap(rows[index]["clientY"] as? Double)
                    XCTAssertTrue(actualX == x || mouse && actualX == floor(x))
                    XCTAssertTrue(actualY == y || mouse && actualY == floor(y))
                }
            }
            let actual = try await evaluate(fixture.view,
                "return [kimiFixture.counters.moreOpens,kimiFixture.counters.moreCloses,kimiFixture.counters.moreClicks,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
            XCTAssertEqual(actual, [1, 1, 0, 1, 0, 0])
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testClaimedPointOutsideOrOccludedStopsTheRemainingBoundaryWithoutRetargeting() async throws {
        for boundary in ["pointerover", "pointerout"] {
            for mutation in ["outside", "occluded"] {
                let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
                var configured = false
                fixture.transport.setBeforePageResultValidationForTesting { action in
                    if action == "inspect", !configured {
                        configured = true
                        _ = try? await self.evaluate(fixture.view, """
                            const target = document.getElementById('fixture-more-trigger');
                            target.addEventListener('\(boundary)', event => {
                                if ('\(mutation)' === 'outside') {
                                    target.style.transform = `translateX(${target.getBoundingClientRect().width + 1}px)`;
                                } else {
                                    target.style.transform = 'translate(4px, 2px)';
                                    const overlay = document.createElement('div');
                                    Object.assign(overlay.style, {position:'fixed',left:(event.clientX-1)+'px',top:(event.clientY-1)+'px',
                                        width:'2px',height:'2px',zIndex:'10000',background:'red'});
                                    document.body.append(overlay);
                                }
                            }, {once:true}); return true;
                            """)
                    }
                }
                do { _ = try await start(fixture); XCTFail("A lost fixed point must not grant readiness") }
                catch { }
                XCTAssertTrue(configured)
                let events = try await evaluate(fixture.view, "return kimiFixture.moreEvents.map(event => event.type);") as? [String]
                XCTAssertEqual(events, boundary == "pointerover" ? ["pointerover"]
                    : ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointerout"])
                let actual = try await evaluate(fixture.view,
                    "return [kimiFixture.counters.modelOpens,kimiFixture.counters.moreClicks,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
                XCTAssertEqual(actual, [1, 0, 0, 0, 0])
                XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)),
                    "The started session retains its owned view after failed readiness; cleanup is unconfirmed")
                XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
            }
        }
    }

    func testLegacyMouseRepresentationCannotEscapeOrOccludeTheClaimedPoint() async throws {
        for change in ["left", "top", "occluded"] {
            let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
            var configured = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !configured {
                    configured = true
                    _ = try? await self.evaluate(fixture.view, """
                        const target = document.getElementById('fixture-more-trigger');
                        target.style.transform = 'translate(0.25px, 0.25px)';
                        target.addEventListener('pointerover', event => {
                            const before = target.getBoundingClientRect();
                            if ('\(change)' === 'left') {
                                target.style.transform = `translate(${0.25 + Math.floor(event.clientX) + 0.125 - before.left}px,0.25px)`;
                            } else if ('\(change)' === 'top') {
                                target.style.transform = `translate(0.25px,${0.25 + Math.floor(event.clientY) + 0.125 - before.top}px)`;
                            } else {
                                const overlay = document.createElement('div');
                                Object.assign(overlay.style, {position:'fixed',left:(Math.floor(event.clientX)-0.125)+'px',
                                    top:(Math.floor(event.clientY)-0.125)+'px',width:'0.25px',height:'0.25px',zIndex:'10000',background:'red'});
                                document.body.append(overlay);
                            }
                            const rect = target.getBoundingClientRect();
                            const mouse = new MouseEvent('mousemove', {clientX:event.clientX,clientY:event.clientY});
                            const inside = (x,y) => x > rect.left && x < rect.right && y > rect.top && y < rect.bottom;
                            window.fixtureDeliveredPoint = {originalInside:inside(event.clientX,event.clientY),
                                deliveredInside:inside(mouse.clientX,mouse.clientY),
                                originalHit:target.contains(document.elementFromPoint(event.clientX,event.clientY)),
                                deliveredHit:target.contains(document.elementFromPoint(mouse.clientX,mouse.clientY)),
                                floored:mouse.clientX === Math.floor(event.clientX) && mouse.clientY === Math.floor(event.clientY)};
                        }, {once:true}); return true;
                        """)
                }
            }
            do { _ = try await start(fixture); XCTFail("The delivered mouse point cannot inherit the float point's proof") }
            catch { }
            XCTAssertTrue(configured)
            let evidence = try await evaluate(fixture.view, "return fixtureDeliveredPoint;") as? [String: Any]
            XCTAssertEqual(evidence?["originalInside"] as? Bool, true)
            XCTAssertEqual(evidence?["originalHit"] as? Bool, true)
            XCTAssertEqual(evidence?["floored"] as? Bool, true)
            let deliveredInside = try XCTUnwrap(evidence?["deliveredInside"] as? Bool)
            let deliveredHit = try XCTUnwrap(evidence?["deliveredHit"] as? Bool)
            XCTAssertEqual(deliveredInside, change == "occluded")
            // WebKit hit testing can include a fractional edge outside the DOM
            // rectangle. The explicit bounds check must reject it independently.
            if change == "occluded" { XCTAssertFalse(deliveredHit) }
            FileHandle.standardError.write(Data("KimiFixtureDeliveredPoint scope=\(change) deliveredInside=\(deliveredInside) deliveredHit=\(deliveredHit)\n".utf8))
            let events = try await evaluate(fixture.view, "return kimiFixture.moreEvents.map(event => event.type);") as? [String]
            XCTAssertEqual(events, ["pointerover", "pointerenter"])
            let actual = try await evaluate(fixture.view,
                "return [kimiFixture.counters.modelOpens,kimiFixture.counters.moreClicks,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
            XCTAssertEqual(actual, [1, 0, 0, 0, 0])
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)),
                    "The started session retains its owned view after failed readiness; cleanup is unconfirmed")
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testClaimedInstantOptionWaitsForCloseAndLabelThenReopensForVerification() async throws {
        for order in ["ariaFirst", "domFirst", "neither"] {
            let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
            var configured = false, observedPending = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !configured {
                    configured = true
                    _ = try? await self.evaluate(fixture.view, "kimiFixture.options.optionCloseOrder='\(order)'; kimiFixture.options.optionLabelLag=true; return true;")
                }
                guard action == "selectModel", !observedPending,
                    let state = try? await self.evaluate(fixture.view, "return kimiFixture.optionState();") as? [String: Any],
                    state["pending"] as? Bool == true else { return }
                observedPending = true
                XCTAssertEqual(state["visible"] as? Bool, order != "domFirst")
                XCTAssertEqual(state["expanded"] as? String, order == "ariaFirst" ? "false" : "true")
                XCTAssertEqual(state["targetLabel"] as? Bool, false)
                let counts = try? await self.evaluate(fixture.view,
                    "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelCloses,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
                XCTAssertEqual(counts, [1,0,1,0,0])
                _ = try? await self.evaluate(fixture.view, "setTimeout(() => kimiFixture.finishOptionClose(),100); return true;")
            }
            let token = try await start(fixture)
            XCTAssertTrue(configured); XCTAssertTrue(observedPending)
            let counts = try await evaluate(fixture.view,
                "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelCloses,kimiFixture.counters.modelSelections,kimiFixture.counters.moreOpens,kimiFixture.counters.moreCloses,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
            XCTAssertEqual(counts, [2,1,1,1,1,0,0])
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testPendingInstantOptionCannotAdoptReplacementOrReplayItsClick() async throws {
        for selector in ["#fixture-model-menu", "[data-moon-key=\"k28-instant\"]"] {
            let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
            var configured = false, replaced = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !configured {
                    configured = true
                    _ = try? await self.evaluate(fixture.view, "kimiFixture.options.optionCloseOrder='ariaFirst'; return true;")
                }
                guard action == "selectModel", !replaced,
                    let state = try? await self.evaluate(fixture.view, "return kimiFixture.optionState();") as? [String: Any],
                    state["pending"] as? Bool == true else { return }
                replaced = true
                _ = try? await self.evaluate(fixture.view, "const old=document.querySelector('\(selector)'); old.replaceWith(old.cloneNode(true)); return true;")
            }
            do { _ = try await start(fixture); XCTFail("A replacement cannot inherit the claimed option") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified) }
            XCTAssertTrue(configured); XCTAssertTrue(replaced)
            let counts = try await evaluate(fixture.view,
                "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelCloses,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
            XCTAssertEqual(counts, [1,0,1,0,0])
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testUnacknowledgedInstantOptionKeepsThePreparationDeadlineWithoutReplay() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
        var configured = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, "kimiFixture.options.optionCloseOrder='neither'; return true;")
            }
        }
        do { _ = try await start(fixture); XCTFail("A clicked option is not a completed selection") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline) }
        XCTAssertTrue(configured)
        let counts = try await evaluate(fixture.view,
            "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelCloses,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(counts, [1,0,1,0,0])
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testClaimedMenuClosesWaitForBothDOMAndARIAAcknowledgementsWithoutReplay() async throws {
        for (scope, order) in [("more", "ariaFirst"), ("more", "domFirst"), ("main", "ariaFirst"), ("main", "domFirst")] {
            let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
            var configured = false
            var observations: [String] = []
            fixture.transport.setKimiDiscoveryProgressObserverForTesting { observations.append($0) }
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !configured {
                    configured = true
                    _ = try? await self.evaluate(fixture.view, """
                        kimiFixture.options.\(scope)CloseOrder = '\(order)';
                        kimiFixture.options.closeAcknowledgementDelayMs = 250; return true;
                        """)
                }
            }
            let choices = try await fixture.transport.discoverModels(provider: "kimi")
            XCTAssertEqual(choices, [choice]); XCTAssertTrue(configured)
            let expected = scope == "more"
                ? ["phase=moreClosing", "submenuPresent=\(order == "ariaFirst")", "submenuExpanded=\(order == "domFirst")"]
                : ["phase=closing", "mainMenuPresent=\(order == "ariaFirst")", "mainExpanded=\(order == "domFirst")"]
            XCTAssertTrue(observations.contains { row in expected.allSatisfy { row.contains($0) } }, "\(scope) \(order)")
            let counts = try await evaluate(fixture.view,
                "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelCloses,kimiFixture.counters.moreOpens,kimiFixture.counters.moreCloses,kimiFixture.counters.modelSelections,kimiFixture.counters.sends];") as? [Int]
            XCTAssertEqual(counts, [1, 1, 1, 1, 0, 0])
            try await assertMoreBoundaryEvents(fixture)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testSameBoundarySequenceAlsoSupportsPointerOnlySubmenuListeners() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var configured = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, "kimiFixture.options.moreEventFamily = 'pointer'; return true;")
            }
        }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertEqual(choices, [choice]); XCTAssertTrue(configured)
        try await assertMoreBoundaryEvents(fixture)
        let counts = try await evaluate(fixture.view,
            "return [kimiFixture.counters.moreOpens,kimiFixture.counters.moreCloses,kimiFixture.counters.moreClicks,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(counts, [1, 1, 0, 0])
    }

    func testDefaultPreventionPreservesBoundarySequenceAndRequiresVerifiedSubmenu() async throws {
        for type in ["pointerover", "mouseover", "pointerout", "mouseout"] {
            let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
            var configured = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !configured {
                    configured = true
                    _ = try? await self.evaluate(fixture.view, """
                        document.getElementById('fixture-more-trigger').addEventListener('\(type)', event => {
                            event.preventDefault();
                        }, true); return true;
                        """)
                }
            }
            let choices = try await fixture.transport.discoverModels(provider: "kimi")
            XCTAssertTrue(configured); XCTAssertEqual(choices, [choice])
            try await assertMoreBoundaryEvents(fixture)
            let prevented = try await evaluate(fixture.view,
                "return kimiFixture.moreEvents.filter(event => event.prevented).map(event => event.type);") as? [String]
            XCTAssertEqual(prevented, [type])
            let counts = try await evaluate(fixture.view,
                "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelSelections,kimiFixture.counters.moreSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
            XCTAssertEqual(counts, [1, 0, 0, 0, 0])
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testPreventedBoundaryWithoutSubmenuAcknowledgementRemainsPendingUntilDeadlineWithoutReplay() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(3))
        var configured = false
        var records: [String] = []
        fixture.transport.setKimiDiscoveryProgressObserverForTesting { records.append($0) }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, """
                    kimiFixture.options.moreEventFamily = 'inert';
                    const target = document.getElementById('fixture-more-trigger');
                    for (const type of ['pointerover','pointerenter','mouseover','mouseenter'])
                        target.addEventListener(type, event => { event.preventDefault(); }, true);
                    return true;
                    """)
            }
        }
        do {
            _ = try await fixture.transport.discoverModels(provider: "kimi")
            XCTFail("Prevented but unacknowledged events establish no submenu proof")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .preparationDeadline)
        }
        XCTAssertTrue(configured)
        XCTAssertTrue(records.contains { $0.contains("reason=preparation_timeout lastObservation phase=moreOpening") })
        let events = try await evaluate(fixture.view, "return kimiFixture.moreEvents.map(event => event.type);") as? [String]
        XCTAssertEqual(events, ["pointerover", "pointerenter", "mouseover", "mouseenter"])
        let prevented = try await evaluate(fixture.view,
            "return kimiFixture.moreEvents.filter(event => event.prevented).map(event => event.type);") as? [String]
        XCTAssertEqual(prevented, ["pointerover", "mouseover"])
        let counts = try await evaluate(fixture.view,
            "return [kimiFixture.counters.modelOpens,kimiFixture.counters.moreOpens,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(counts, [1, 0, 0, 0, 0])
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testSameIDReplacementDuringBoundaryCannotReceiveItsRemainingEvents() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var configured = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, """
                    window.fixtureReplacementEvents = 0;
                    const target = document.getElementById('fixture-more-trigger');
                    target.addEventListener('pointerenter', () => {
                        const replacement = target.cloneNode(true);
                        for (const type of ['mouseover','mouseenter','pointerout','pointerleave','mouseout','mouseleave'])
                            replacement.addEventListener(type, () => { window.fixtureReplacementEvents++; });
                        target.replaceWith(replacement);
                    }, true); return true;
                    """)
            }
        }
        do { _ = try await fixture.transport.discoverModels(provider: "kimi"); XCTFail("Replacement cannot inherit a transition") }
        catch { }
        XCTAssertTrue(configured)
        let events = try await evaluate(fixture.view, "return kimiFixture.moreEvents.map(event => event.type);") as? [String]
        XCTAssertEqual(events, ["pointerover", "pointerenter"])
        let counts = try await evaluate(fixture.view,
            "return [fixtureReplacementEvents,kimiFixture.counters.modelOpens,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(counts, [0, 1, 0, 0, 0])
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testCheckedRowReplacementDuringExitStopsBeforeRemainingBoundaryEvents() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var configured = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, """
                    document.getElementById('fixture-more-trigger').addEventListener('pointerout', () => {
                        const row = document.querySelector('[data-testid="model-more-option"]');
                        row.replaceWith(row.cloneNode(true));
                    }, true); return true;
                    """)
            }
        }
        do { _ = try await fixture.transport.discoverModels(provider: "kimi"); XCTFail("Replaced checked row cannot retain menu proof") }
        catch { }
        XCTAssertTrue(configured)
        let events = try await evaluate(fixture.view, "return kimiFixture.moreEvents.map(event => event.type);") as? [String]
        XCTAssertEqual(events, ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointerout"])
        let counts = try await evaluate(fixture.view,
            "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelSelections,kimiFixture.counters.moreSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(counts, [1, 0, 0, 0, 0])
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testOwnerRevocationWithinBoundaryStopsBeforeLegacyEvents() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var configured = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !configured {
                configured = true
                _ = try? await self.evaluate(fixture.view, """
                    document.getElementById('fixture-more-trigger').addEventListener('pointerenter', () => {
                        globalThis.__computaModelOwner = 'revoked';
                    }, true); return true;
                    """, world: self.world)
            }
        }
        do { _ = try await fixture.transport.discoverModels(provider: "kimi"); XCTFail("Revoked owner cannot finish its transition") }
        catch { }
        XCTAssertTrue(configured)
        let events = try await evaluate(fixture.view, "return kimiFixture.moreEvents.map(event => event.type);") as? [String]
        XCTAssertEqual(events, ["pointerover", "pointerenter"])
        let counts = try await evaluate(fixture.view,
            "return [kimiFixture.counters.modelOpens,kimiFixture.counters.modelSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    private func assertMoreBoundaryEvents(_ fixture: Fixture, requireCentered: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await evaluate(fixture.view, "return kimiFixture.moreEvents;")
        let rows = try XCTUnwrap(value as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["type"] as? String }, ["pointerover", "pointerenter", "mouseover", "mouseenter",
            "pointerout", "pointerleave", "mouseout", "mouseleave"], file: file, line: line)
        for (index, row) in rows.enumerated() {
            for key in ["bubbles", "cancelable", "composed"] {
                XCTAssertEqual(row[key] as? Bool, index % 2 == 0, key, file: file, line: line)
            }
            for key in ["targetMatches", "relatedMatches", "deliveredHit"] + (requireCentered ? ["centered"] : []) {
                XCTAssertEqual(row[key] as? Bool, true,
                    "\(key) event=\(row["type"] ?? "missing") delivered=(\(row["clientX"] ?? "missing"),\(row["clientY"] ?? "missing")) center=(\(row["centerX"] ?? "missing"),\(row["centerY"] ?? "missing"))",
                    file: file, line: line)
            }
            XCTAssertEqual(row["trusted"] as? Bool, false, "No claim to trusted user input", file: file, line: line)
        }
    }

    func testInstantSelectionFromNestedK3ReopensForProofThenSendsAndDeletesOnce() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let selected = try await evaluate(fixture.view, """
            return {label:document.querySelector('.current-model .name').textContent,
                instant:document.querySelector('[data-moon-key="k28-instant"]').getAttribute('aria-checked'),
                nested:document.querySelector('[data-testid="model-more-option"]').getAttribute('aria-checked'),
                moreOpens:kimiFixture.counters.moreOpens, moreCloses:kimiFixture.counters.moreCloses,
                modelOpens:kimiFixture.counters.modelOpens, selections:kimiFixture.counters.modelSelections,
                nestedSelections:kimiFixture.counters.moreSelections};
            """) as? [String: Any]
        XCTAssertEqual(selected?["label"] as? String, "Instant")
        XCTAssertEqual(selected?["instant"] as? String, "true"); XCTAssertEqual(selected?["nested"] as? String, "false")
        XCTAssertEqual(selected?["moreOpens"] as? Int, 1); XCTAssertEqual(selected?["moreCloses"] as? Int, 1)
        XCTAssertEqual(selected?["modelOpens"] as? Int, 2)
        XCTAssertEqual(selected?["selections"] as? Int, 1); XCTAssertEqual(selected?["nestedSelections"] as? Int, 0)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic Instant task after nested model selection")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
    }

    func testNestedDiscoveryRejectsForeignSubmenuBindingWithoutModelChangeOrSend() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var changed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !changed {
                changed = true
                _ = try? await self.evaluate(fixture.view,
                    "document.getElementById('fixture-more-menu').setAttribute('aria-labelledby', 'foreign-trigger'); return true;")
            }
        }
        do { _ = try await fixture.transport.discoverModels(provider: "kimi"); XCTFail("A foreign submenu cannot supply model evidence") } catch { }
        XCTAssertTrue(changed)
        let actions = try await evaluate(fixture.view,
            "return [kimiFixture.counters.modelSelections,kimiFixture.counters.moreSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(actions, [0, 0, 0, 0])
    }

    func testDiscoveryWaitsForInitialControlsWithoutBindingOrDispatchingEarly() async throws {
        let fixture = try Fixture(initialControlsPending: true); defer { fixture.shutdown() }
        var sawUnhydratedRead = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !sawUnhydratedRead {
                sawUnhydratedRead = true
                let before = try? await self.evaluate(fixture.view, """
                    const result = {empty:!document.querySelector('.current-model,.chat-input-editor,.send-button-container'),
                        sends:kimiFixture.counters.sends, modelOpens:kimiFixture.counters.modelOpens,
                        inputs:kimiFixture.counters.beforeInput};
                    setTimeout(() => fixtureHydration.restore(), 100); return result;
                    """) as? [String: Any]
                XCTAssertEqual(before?["empty"] as? Bool, true)
                XCTAssertEqual(before?["sends"] as? Int, 0)
                XCTAssertEqual(before?["modelOpens"] as? Int, 0)
                XCTAssertEqual(before?["inputs"] as? Int, 0)
            }
        }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertTrue(sawUnhydratedRead)
        XCTAssertEqual(choices, [choice])
        let restored = try await evaluate(fixture.view, "return fixtureHydration.restored;") as? Bool
        XCTAssertEqual(restored, true)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testDiscoveryWakesWhenExistingEditorBecomesEditableWithoutChildMutation() async throws {
        let fixture = try Fixture(initialEditorAttributePending: true); defer { fixture.shutdown() }
        var sawPendingRead = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !sawPendingRead {
                sawPendingRead = true
                let before = try? await self.evaluate(fixture.view, """
                    const editor = document.querySelector('.chat-input-editor');
                    const result = {exists:!!editor, editable:editor.hasAttribute('contenteditable'),
                        sends:kimiFixture.counters.sends, modelOpens:kimiFixture.counters.modelOpens,
                        inputs:kimiFixture.counters.beforeInput};
                    setTimeout(() => fixtureHydration.restore(), 100); return result;
                    """) as? [String: Any]
                XCTAssertEqual(before?["exists"] as? Bool, true)
                XCTAssertEqual(before?["editable"] as? Bool, false)
                XCTAssertEqual(before?["sends"] as? Int, 0)
                XCTAssertEqual(before?["modelOpens"] as? Int, 0)
                XCTAssertEqual(before?["inputs"] as? Int, 0)
            }
        }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertTrue(sawPendingRead)
        XCTAssertEqual(choices, [choice])
        let restored = try await evaluate(fixture.view, "return fixtureHydration.restored;") as? Bool
        XCTAssertEqual(restored, true)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testMissingControlsAfterReadyCannotReenterInitialHydration() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "document.querySelector('.current-model').remove(); return true;")
        do {
            // Ready Poll is a cached native snapshot. Send's strict preparation
            // must re-read the bound controls before any editor mutation.
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic missing bound model controls")
            XCTFail("A bound model cannot reset into initial hydration")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .ownershipFailure(.javaScriptDocument))
        }
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        let insertions = try await evaluate(fixture.view, "return kimiFixture.counters.beforeInput;") as? Int
        XCTAssertEqual(insertions, 0)
    }

    func testServerReleasesKimiResponseOnlyWithItsNativeDurableDeletionReceipt() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaKimiReceipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = WebModelServer(), generation = UUID()
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        await server.configureEmbeddedTransport(fixture.transport)
        await server.configureEvidenceDirectory(directory.appendingPathComponent("evidence"))
        await server.configureCleanupReceipts(directory: directory, runtimeGeneration: generation) { _ in }
        do {
            let request = try JSONSerialization.data(withJSONObject: ["model": choice.modelID,
                "input": "Return the synthetic offline fixture reply.", "tools": []] as [String: Any])
            let response = try await server.fixtureInfer(request, taskID: task, threadID: thread, turnID: turn,
                runtimeGeneration: generation)
            XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("Offline Kimi fixture reply"))
            let receipts = await server.latestCleanupReceipts()
            XCTAssertEqual(receipts.count, 1)
            let receipt = try XCTUnwrap(receipts.first)
            XCTAssertTrue(receipt.isValid); XCTAssertTrue(receipt.isTransactionLinked); XCTAssertTrue(receipt.receiptSaved)
            XCTAssertEqual(receipt.provider, .kimi); XCTAssertEqual(receipt.route, .embedded)
            XCTAssertEqual(receipt.modelID, choice.modelID); XCTAssertEqual(receipt.reason, .deleted)
            XCTAssertEqual(receipt.outcome, .closed); XCTAssertEqual(receipt.trigger, .inference)
            XCTAssertEqual(receipt.taskID, task.lowercased()); XCTAssertEqual(receipt.threadID, thread.lowercased())
            XCTAssertEqual(receipt.turnID, turn.lowercased()); XCTAssertNotNil(receipt.sessionToken)
            XCTAssertEqual(receipt.runtimeGeneration, generation.uuidString.lowercased())
            XCTAssertEqual(WebsiteSessionCleanupStore(directory: directory).latest(), [receipt],
                           "A fresh store must recover the exact native lease after restart")
            let encoded = try JSONEncoder().encode(receipt)
            XCTAssertEqual(try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: encoded), receipt)
            let retried = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
            XCTAssertEqual(retried, receipt)
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
            _ = await server.shutdown()
        } catch {
            _ = await server.shutdown()
            throw error
        }
    }

    func testOneExactUnicodeSubmissionCompletesAndDeletesOnlyItsOwnedChat() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let prompt = "Synthetic café 👋\nActual \\ and \"quoted\" content"
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let prompts = try await evaluate(fixture.view, "return fixturePrompts;") as? [String]
        XCTAssertEqual(prompts?.count, 1)
        XCTAssertTrue(prompts?.first?.hasPrefix(prompt + "\n\nComputa session marker: ") == true)
        let finished = try await call(fixture, "webProviderFinish", token)
        let repeated = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        XCTAssertEqual(repeated["cleanup"] as? String, "deleted")
        XCTAssertEqual(finished["temporary"] as? Bool, false)
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testFullHarnessPromptPreservesCodeWhitespaceQuotesAndMarkupLiterally() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let parameters: [String: Any] = [
            "model": choice.modelID,
            "instructions": ComputaAgentInstructions.developerInstructions(embeddedBrowserTools: true),
            "input": "Use the browser, terminal and patch tools only with their actual schemas. This is an offline insertion fixture.",
            "tools": [
                ["type": "function", "name": "exec_command", "description": "Run a command in the fixture workspace",
                 "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]],
                ["type": "function", "name": "browser_open", "description": "Open an owned task tab",
                 "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"], "additionalProperties": false]],
                ["type": "custom", "name": "apply_patch", "format": ["type": "text"]],
            ]
        ]
        let prepared = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: parameters))
        let literal = "Straight \"double\" and 'single' quotes; -- dash; literal &amp; and <tag>.\n"
            + "  {\"indented\": \"two  spaces\", \"path\": \"C:\\fixture\"}\n"
            + "\tTab\tseparated; literal NBSP:\u{00a0}; café e\u{301} 👋\r\n"
            + "</script><script id=\"injected\">window.kimiFixtureInjected=true</script>\n\n"
        let prompt = prepared.prompt + "\n\nLiteral fixture block:\n" + literal
        XCTAssertGreaterThan(prompt.utf8.count, 4_000)
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        _ = try await wait(fixture, token, state: "complete")
        let capturedValue = try await evaluate(fixture.view, "return fixturePrompts;")
        let captured = try XCTUnwrap(capturedValue as? [String])
        XCTAssertEqual(captured.count, 1)
        let prefix = prompt + "\n\nComputa session marker: "
        XCTAssertTrue(captured[0].hasPrefix(prefix))
        XCTAssertNotNil(UUID(uuidString: String(captured[0].dropFirst(prefix.count))))
        let receipt = try await evaluate(fixture.view, "return {injected:window.kimiFixtureInjected===true || document.getElementById('injected')!==null};") as? [String: Any]
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        XCTAssertEqual(receipt?["injected"] as? Bool, false)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testOverflowClippedLongEditorKeepsExactPromptAndOneSend() async throws {
        for transformed in [false, true] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
            var geometry: [String: Any]?
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "insert" {
                    geometry = try? await self.installLongEditorClip(fixture, transformed: transformed, overlay: false)
                }
            }
            let prompt = String(repeating: "Synthetic long line with literal \"quotes\".\n", count: 600)
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            _ = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(geometry?["oldPointHitsEditor"] as? Bool, false, "Must reproduce the viewport-only false negative")
            XCTAssertEqual(geometry?["clipCenterHitsEditor"] as? Bool, true)
            XCTAssertEqual(geometry?["editorExceedsClip"] as? Bool, true)
            XCTAssertEqual(geometry?["sameEditor"] as? Bool, true)
            try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
            let prompts = try await evaluate(fixture.view, "return fixturePrompts;") as? [String]
            XCTAssertEqual(prompts?.count, 1)
            XCTAssertTrue(prompts?.first?.hasPrefix(prompt + "\n\nComputa session marker: ") == true)
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        }
    }

    func testOverlayOverClippedLongEditorPreventsSendWithoutReinsertion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var geometry: [String: Any]?
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "insert" { geometry = try? await self.installLongEditorClip(fixture, transformed: false, overlay: true) }
        }
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: String(repeating: "Synthetic long line.\n", count: 800))
            XCTFail("An actual overlay must prevent Send")
        } catch let failure as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(failure, .editorFailure("composer_unavailable"))
        }
        XCTAssertEqual(geometry?["oldPointHitsEditor"] as? Bool, false)
        XCTAssertEqual(geometry?["clipCenterHitsEditor"] as? Bool, false)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
    }

    private func installLongEditorClip(_ fixture: Fixture, transformed: Bool, overlay: Bool) async throws -> [String: Any] {
        let result = try await evaluate(fixture.view, """
            const editor = document.querySelector('.chat-input-editor'), clip = editor.parentElement;
            kimiFixture.settleInput();
            Object.assign(editor.style, {minHeight:'0',maxHeight:'none',height:'auto',width:'303px',padding:'0',border:'0',overflow:'visible',lineHeight:'18px'});
            Object.assign(clip.style, {position:'fixed',left:'36px',top:'208.5px',width:'303px',height:'170px',overflow:'auto',zIndex:'5',
              transform: '\(transformed ? "translate(11px,7px) scale(.9)" : "none")'});
            clip.scrollTop = clip.scrollHeight;
            const r = editor.getBoundingClientRect(), a = clip.getBoundingClientRect();
            if (\(overlay ? "true" : "false")) {
              const cover = document.createElement('div');
              Object.assign(cover.style,{position:'fixed',left:a.left+'px',top:a.top+'px',width:a.width+'px',height:a.height+'px',zIndex:'10000',background:'white'});
              document.body.append(cover);
            }
            const x = (Math.max(0,r.left)+Math.min(innerWidth,r.right))/2;
            const y = (Math.max(0,r.top)+Math.min(innerHeight,r.bottom))/2;
            return {oldPointHitsEditor:editor.contains(document.elementFromPoint(x,y)),
              clipCenterHitsEditor:editor.contains(document.elementFromPoint(a.left+a.width/2,a.top+a.height/2)),
              editorExceedsClip:r.height>a.height*20, sameEditor:editor===document.querySelector('.chat-input-editor')};
            """)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testDelayedLexicalCommitWaitsForExactReadbackWithoutReinserting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var insertions = 0, readinessReads = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "insert" { insertions += 1 }
            if action == "sendReady" {
                readinessReads += 1
                if readinessReads == 1 {
                    let before = try? await self.evaluate(fixture.view,
                        "return {empty:document.querySelector('.chat-input-editor').textContent === '', sends:kimiFixture.counters.sends};") as? [String: Any]
                    XCTAssertEqual(before?["empty"] as? Bool, true)
                    XCTAssertEqual(before?["sends"] as? Int, 0)
                    _ = try? await self.evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
                }
            }
        }
        let prompt = "Exact \"quotes\" and 'apostrophe'\n\n  spaces\tand\u{00a0}NBSP <tag> &amp;\n"
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        _ = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(insertions, 1); XCTAssertGreaterThanOrEqual(readinessReads, 2)
        let prompts = try await evaluate(fixture.view, "return fixturePrompts;") as? [String]
        XCTAssertEqual(prompts?.count, 1)
        XCTAssertTrue(prompts?.first?.hasPrefix(prompt + "\n\nComputa session marker: ") == true)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
    }

    func testControlledEditorBeforeInputDefaultComparisonPreservesExactEventPayload() async throws {
        for preventNativeInput in [false, true] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            _ = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.preventNativeInput = \(preventNativeInput ? "true" : "false"); return true;")
            let commandResult = try await evaluate(fixture.view, #"""
                const editor = document.querySelector('.chat-input-editor'); editor.focus();
                const payload = "Synthetic café 👋\nActual \\ and \"quoted\" content\n\n  spaces\tNBSP: <tag>&amp;\n";
                return document.execCommand('insertText', false, payload);
                """#, world: world)
            let observation = try await evaluate(fixture.view, #"""
                const editor = document.querySelector('.chat-input-editor');
                const payload = "Synthetic café 👋\nActual \\ and \"quoted\" content\n\n  spaces\tNBSP: <tag>&amp;\n";
                await new Promise(resolve => setTimeout(resolve, 30));
                return { preventNativeInput:kimiFixture.options.preventNativeInput,
                    exact:editor.textContent === payload, renderedLength:editor.textContent.length,
                    expectedLength:payload.length, inputEvents:kimiFixture.inputEvents,
                    beforeInput:kimiFixture.counters.beforeInput, inputs:kimiFixture.counters.input,
                    settlements:kimiFixture.counters.settlements, sends:kimiFixture.counters.sends };
                """#) as? [String: Any]
            var receipt = try XCTUnwrap(observation)
            receipt["returned"] = try XCTUnwrap(commandResult as? Bool)
            let encoded = try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
            XCTAssertLessThan(encoded.count, 8192)
            FileHandle.standardError.write(Data(("KimiControlledEditorEventComparison " + String(decoding: encoded, as: UTF8.self) + "\n").utf8))
            XCTAssertEqual(receipt["returned"] as? Bool, true)
            XCTAssertEqual(receipt["sends"] as? Int, 0)
            if preventNativeInput {
                XCTAssertEqual(receipt["exact"] as? Bool, true)
                XCTAssertEqual(receipt["beforeInput"] as? Int, 1)
                XCTAssertEqual(receipt["settlements"] as? Int, 1)
            }
        }
    }

    func testChangedLexicalCommitPreventsSendAndCannotReinsert() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; kimiFixture.options.lexicalWrongText = true; return true;")
        var released = false, insertions = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "insert" { insertions += 1 }
            if action == "sendReady", !released {
                released = true
                _ = try? await self.evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
            }
        }
        let prompt = "Synthetic wrong deferred input"
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            XCTFail("A changed nonempty editor must not reach Send")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .editorFailure("prompt_not_inserted"))
        }
        XCTAssertTrue(released)
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Input is never replayed") } catch { }
        XCTAssertEqual(insertions, 1)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
    }

    func testMissingLexicalCommitExpiresAndLateCommitCannotSendOrReinsert() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        let started = ContinuousClock.now, prompt = "Synthetic lost deferred input"
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            XCTFail("A dispatch receipt alone must not enable Send")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .editorFailure("send_unavailable"))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(6), "The read-only readiness wait stays bounded")
        try await assertInsertionCounts(fixture, settlements: 0, sends: 0)
        _ = try await evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Late input cannot reopen a failed Send") } catch { }
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
    }

    func testReplacedEditorDuringLexicalWaitCannotSendOrReinsert() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var replaced = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "sendReady", !replaced {
                replaced = true
                _ = try? await self.evaluate(fixture.view, """
                    const editor = document.querySelector('.chat-input-editor');
                    editor.replaceWith(editor.cloneNode(true)); kimiFixture.settleInput(); return true;
                    """)
            }
        }
        let prompt = "Synthetic displaced editor"
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("A replacement editor cannot inherit the insertion") } catch { }
        XCTAssertTrue(replaced)
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("A replacement editor cannot cause reinsertion") } catch { }
        try await assertInsertionCounts(fixture, settlements: 0, sends: 0)
    }

    func testCancelledLexicalWaitDoesNotSendAfterLateCommit() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var cancelled = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "sendReady", !cancelled {
                cancelled = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let prompt = "Synthetic cancelled deferred input"
        let sending = Task { try await self.call(fixture, "webProviderSend", token, prompt: prompt)["state"] as? String }
        do { _ = try await sending.value; XCTFail("Cancellation must stop Send") } catch { }
        XCTAssertTrue(cancelled)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        _ = try await evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Cancelled input is never replayed") } catch { }
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
    }

    func testProvisionalRouteCannotPublishAnswerAndCanonicalPromotionDoesNotResend() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic pending first body")
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        _ = try await evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testOptimisticEmptyFirstIDsRemainPendingUntilPhysicalReplacementAndCanonicalProof() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.optimisticUser = true; kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic optimistic identity")
        let initialShape = try await evaluate(fixture.view, """
            const root = document.querySelector('.chat-content-item-user');
            const body = root.querySelector('.user-content__text');
            return {emptyRootID:root.getAttribute('data-archer-id') === '',
              emptyTurnID:root.getAttribute('data-conversation-turn-id') === '',
              exactSend:body.textContent === fixturePrompts[0],
              answers:document.querySelectorAll('.chat-content-item-assistant').length};
            """) as? [String: Any]
        XCTAssertEqual(initialShape?["emptyRootID"] as? Bool, true)
        XCTAssertEqual(initialShape?["emptyTurnID"] as? Bool, true)
        XCTAssertEqual(initialShape?["exactSend"] as? Bool, true)
        XCTAssertEqual(initialShape?["answers"] as? Int, 0)
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        let pendingContext = try XCTUnwrap(pending["modelProofContext"] as? [String: Any])
        XCTAssertEqual(pendingContext["firstUserFingerprint"] as? String, "")
        XCTAssertEqual(pendingContext["responseCount"] as? Int, 0)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        let replaced = try await evaluate(fixture.view, "return kimiFixture.replaceOptimisticUser();") as? [String: Bool]
        XCTAssertEqual(replaced, ["previousDetached": true, "differentPhysicalRoot": true, "textPreserved": true])
        let provisional = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(provisional["state"] as? String, "running")
        XCTAssertEqual(provisional["text"] as? String, "")
        let provisionalContext = try XCTUnwrap(provisional["modelProofContext"] as? [String: Any])
        XCTAssertEqual(provisionalContext["firstUserFingerprint"] as? String, "")
        _ = try await evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let completeContext = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((completeContext["firstUserFingerprint"] as? String)?.count, 64)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testOptimisticAssistantRowCannotPublishBeforeCanonicalOwnership() async throws {
        try await verifyOptimisticAssistantRowCannotPublishBeforeCanonicalOwnership(remountPicker: false)
    }

    func testOptimisticAssistantRowRemountRetainsNegativePendingUntilCanonicalOwnership() async throws {
        try await verifyOptimisticAssistantRowCannotPublishBeforeCanonicalOwnership(remountPicker: true)
    }

    private func verifyOptimisticAssistantRowCannotPublishBeforeCanonicalOwnership(remountPicker: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.optimisticUser = true; kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic provisional assistant row")
        let previewPresent = try await evaluate(fixture.view, """
            const user = document.querySelector('.chat-content-item-user');
            const spacer = document.createElement('div');
            const preview = document.createElement('div');
            preview.className = 'chat-content-item chat-content-item-assistant';
            preview.textContent = 'Unverified provisional assistant text';
            user.after(spacer, preview);
            return preview.previousElementSibling === spacer && spacer.previousElementSibling === user && user.getAttribute('data-archer-id') === ''
              && user.getAttribute('data-conversation-turn-id') === '';
            """) as? Bool
        XCTAssertEqual(previewPresent, true)
        if remountPicker {
            let remounted = try await evaluate(fixture.view, """
                const previous = document.querySelector('.current-model');
                const replacement = previous.cloneNode(true);
                previous.replaceWith(replacement);
                return !previous.isConnected && replacement.isConnected;
                """) as? Bool
            XCTAssertEqual(remounted, true)
        }
        for _ in 0 ..< 2 {
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["state"] as? String, "running")
            XCTAssertEqual(pending["text"] as? String, "")
            let proof = try XCTUnwrap(pending["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["firstUserFingerprint"] as? String, "")
            XCTAssertEqual(proof["responseCount"] as? Int, 0)
        }
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        _ = try await evaluate(fixture.view, """
            document.querySelector('.chat-content-item-assistant').remove();
            kimiFixture.replaceOptimisticUser(); kimiFixture.canonicalize(); return true;
            """)
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        XCTAssertEqual(proof["responseCount"] as? Int, 1)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testInitialModelTriggerRemountRemainsPendingUntilExactCanonicalReplyAndDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.optimisticUser = true; kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic first model trigger replacement")
        let detached = try await evaluate(fixture.view, """
            const previous = document.querySelector('.current-model');
            const next = previous.cloneNode(true); previous.replaceWith(next);
            return !previous.isConnected && next.isConnected;
            """) as? Bool
        XCTAssertEqual(detached, true)
        for _ in 0 ..< 2 {
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["state"] as? String, "running")
            XCTAssertEqual(pending["text"] as? String, "")
            let context = try XCTUnwrap(pending["modelProofContext"] as? [String: Any])
            XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
            XCTAssertEqual(context["responseCount"] as? Int, 0)
        }
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        _ = try await evaluate(fixture.view, "kimiFixture.replaceOptimisticUser(); kimiFixture.canonicalize(); return true;")
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        XCTAssertEqual(proof["responseCount"] as? Int, 1)
        let selected = try WebsiteModelEvidence.parse(complete["modelEvidence"], provider: "kimi", expected: choice)
        XCTAssertEqual(selected.selected.key, choice.key)
        XCTAssertEqual(selected.selected.label, choice.label)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testSecondOrCanonicalModelTriggerRemountCannotRebindOrReplay() async throws {
        for phase in ["second", "canonical"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.optimisticUser = true; kimiFixture.options.holdProvisional = true; return true;")
            let prompt = "Synthetic forbidden model trigger replacement"
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            if phase == "second" {
                _ = try await evaluate(fixture.view, "const old = document.querySelector('.current-model'); old.replaceWith(old.cloneNode(true)); return true;")
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["state"] as? String, "running")
                XCTAssertEqual(pending["text"] as? String, "")
            } else {
                _ = try await evaluate(fixture.view, "kimiFixture.replaceOptimisticUser(); kimiFixture.canonicalize(); return true;")
            }
            _ = try await evaluate(fixture.view, "const old = document.querySelector('.current-model'); old.replaceWith(old.cloneNode(true)); return true;")
            do { _ = try await call(fixture, "webProviderPoll", token); XCTFail("A \(phase) remount cannot replace model proof") }
            catch let error as EmbeddedWebModelTransport.Failure { XCTAssertEqual(error, .modelUnverified) }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("A rejected remount cannot replay Send") }
            catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testOptimisticEmptyFirstIDsRejectCanonicalOrChangedEvidenceWithoutReplay() async throws {
        for mutation in ["canonical", "malformed", "prompt", "nestedBody", "model"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.optimisticUser = true; kimiFixture.options.holdProvisional = true; return true;")
            let prompt = "Synthetic negative optimistic identity"
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["state"] as? String, "running")
            XCTAssertEqual(pending["text"] as? String, "")
            _ = try await evaluate(fixture.view, """
                const root = document.querySelector('.chat-content-item-user');
                const body = root.querySelector('.user-content__text');
                if ('\(mutation)' === 'canonical') kimiFixture.canonicalize();
                if ('\(mutation)' === 'malformed') root.setAttribute('data-archer-id', 'not-an-id');
                if ('\(mutation)' === 'prompt') body.textContent += ' foreign edit';
                if ('\(mutation)' === 'nestedBody') { const nested = document.createElement('span'); nested.textContent = body.textContent; body.replaceChildren(nested); }
                if ('\(mutation)' === 'model') document.querySelector('.current-model .name').textContent = 'K3';
                return true;
                """)
            do { _ = try await call(fixture, "webProviderPoll", token); XCTFail("Changed optimistic evidence cannot establish ownership: \(mutation)") }
            catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Failed ownership cannot replay Send") }
            catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testOptimisticEmptyFirstIDsCannotReviveAfterDeadlineOrCancellation() async throws {
        for terminal in ["deadline", "cancel"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(1))
            let token = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.optimisticUser = true; kimiFixture.options.holdProvisional = true; return true;")
            let prompt = "Synthetic terminal optimistic identity"
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["state"] as? String, "running")
            XCTAssertEqual(pending["text"] as? String, "")
            if terminal == "deadline" {
                do { _ = try await wait(fixture, token, state: "complete"); XCTFail("Empty IDs must not extend the fixed response deadline") }
                catch let error as EmbeddedWebModelTransport.Failure { XCTAssertEqual(error, .deadline) }
            }
            let ended = try await call(fixture, terminal == "cancel" ? "webProviderCancel" : "webProviderFinish", token)
            XCTAssertEqual(ended["cleanup"] as? String, "failed")
            _ = try await evaluate(fixture.view, "kimiFixture.replaceOptimisticUser(); kimiFixture.canonicalize(); return true;")
            do {
                let late = try await call(fixture, "webProviderPoll", token)
                XCTAssertNotEqual(late["state"] as? String, "complete")
                XCTAssertEqual(late["text"] as? String, "")
            } catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
            do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("A terminal session cannot resend after IDs settle") }
            catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testDelayedDeletionStagesObserveUntilReadyWithoutRepeatingClicks() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.menuDelayMs = 120; kimiFixture.options.dialogDelayMs = 120; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic delayed cleanup")
        _ = try await wait(fixture, token, state: "complete")
        let first = Task { try await self.call(fixture, "webProviderFinish", token)["cleanup"] as? String }
        let second = Task { try await self.call(fixture, "webProviderCancel", token)["cleanup"] as? String }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, "deleted"); XCTAssertEqual(b, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testDetailedFirstUserFailureRetainsOwnershipCategoryAndCannotDeleteOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic body for exact ownership")
        _ = try await evaluate(fixture.view, """
            kimiFixture.canonicalize();
            const body = document.querySelector('.user-content .user-content__text');
            if (!body || !body.textContent.startsWith('Synthetic body')) throw new Error('Missing exact synthetic body');
            body.textContent = body.textContent.replace('Synthetic body', 'Different body');
            return true;
            """)
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("Changed full echo cannot become first-user ownership")
        } catch let error as EmbeddedWebModelTransport.Failure {
            guard case .ownershipFailure(.javaScriptFirstUser) = error else {
                XCTFail("A finite diagnostic must preserve first_user_message ownership classification"); return
            }
        }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testOneProvisionalRouteReturnResumesOrdinaryInspectionWithoutPublishing() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let (token, previous, generation) = try await startProvisionalFreshHop(fixture)
        let tab = try XCTUnwrap(fixture.createdID)
        var outcomes: [String] = [], inspectedRoutes: [URL?] = []
        var restoration: Task<Bool, Error>?
        fixture.transport.setKimiProvisionalRouteWaitObserverForTesting { record in
            outcomes.append(record)
            if record.hasSuffix(" outcome=waiting") {
                restoration = Task {
                    try await self.evaluate(fixture.view,
                        "history.replaceState({}, '', fixturePriorProvisionalURL); return true;") as? Bool == true
                }
            }
        }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect" { inspectedRoutes.append(fixture.view.url) }
        }
        defer {
            restoration?.cancel()
            fixture.transport.setKimiProvisionalRouteWaitObserverForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
        }
        let pending = try await call(fixture, "webProviderPoll", token)
        let restoring = try XCTUnwrap(restoration)
        let restored = try await restoring.value
        XCTAssertTrue(restored)
        XCTAssertEqual(outcomes, kimiRouteWaitRecords(token, generation, "returned"))
        XCTAssertEqual(inspectedRoutes, [previous])
        XCTAssertEqual(fixture.browser.documentGeneration(for: tab), generation)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        let context = try XCTUnwrap(pending["modelProofContext"] as? [String: Any])
        XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
        XCTAssertEqual(context["responseCount"] as? Int, 0)
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)

        _ = try await evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
        let completed = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertEqual(outcomes, kimiRouteWaitRecords(token, generation, "returned"))
    }

    func testFinishRevokesResumedProvisionalCallbackWithoutPublishingOrDeleting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let (token, previous, generation) = try await startProvisionalFreshHop(fixture)
        let tab = try XCTUnwrap(fixture.createdID)
        let expected = kimiRouteWaitRecords(token, generation, "returned")
        var outcomes: [String] = []
        var restoration: Task<Bool, Error>?
        var resumeInspection: CheckedContinuation<Void, Never>?
        fixture.transport.setKimiProvisionalRouteWaitObserverForTesting { record in
            outcomes.append(record)
            if record == expected[0] {
                restoration = Task {
                    try await self.evaluate(fixture.view,
                        "history.replaceState({}, '', fixturePriorProvisionalURL); return true;") as? Bool == true
                }
            }
        }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            // The original evaluation has returned. Hold only its callback so
            // Finish can perform its own inspection of the same document.
            guard action == "inspect", outcomes == expected, resumeInspection == nil else { return }
            await withCheckedContinuation { resumeInspection = $0 }
        }
        let poll = Task { try await self.call(fixture, "webProviderPoll", token)["state"] as? String }
        defer {
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            fixture.transport.setKimiProvisionalRouteWaitObserverForTesting(nil)
            poll.cancel(); restoration?.cancel()
            resumeInspection?.resume()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while resumeInspection == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let resume = try XCTUnwrap(resumeInspection, "The exact returned route must reach a real inspection callback")
        let restoring = try XCTUnwrap(restoration)
        let restored = try await restoring.value
        XCTAssertTrue(restored)
        XCTAssertEqual(outcomes, expected)
        XCTAssertEqual(fixture.view.url, previous)
        XCTAssertEqual(fixture.browser.documentGeneration(for: tab), generation)

        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: tab) === fixture.view)
        XCTAssertEqual(fixture.view.url, previous)
        XCTAssertEqual(fixture.browser.documentGeneration(for: tab), generation)
        resumeInspection = nil
        resume.resume()
        do {
            _ = try await poll.value
            XCTFail("The revoked callback must not return a snapshot")
        } catch let failure as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(failure, .staleSession)
        }
        XCTAssertEqual(outcomes, expected)
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testProvisionalRouteWaitRejectsChangedQueryAndNeverRenewsAfterReturn() async throws {
        for returnExactly in [false, true] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let (token, previous, generation) = try await startProvisionalFreshHop(fixture)
            var outcomes: [String] = [], inspectedRoutes: [URL?] = []
            var restoration: Task<Bool, Error>?
            fixture.transport.setKimiProvisionalRouteWaitObserverForTesting { record in
                outcomes.append(record)
                if record.hasSuffix(" outcome=waiting"), restoration == nil {
                    let change = returnExactly ? "" : #"url.search = url.search ? '' : '?chat_enter_method=home';"#
                    restoration = Task {
                        try await self.evaluate(fixture.view, """
                            const url = new URL(fixturePriorProvisionalURL);
                            \(change)
                            history.replaceState({}, '', url); return true;
                            """) as? Bool == true
                    }
                }
            }
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect" { inspectedRoutes.append(fixture.view.url) }
            }
            defer {
                restoration?.cancel()
                fixture.transport.setKimiProvisionalRouteWaitObserverForTesting(nil)
                fixture.transport.setBeforePageResultValidationForTesting(nil)
            }

            if returnExactly {
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["text"] as? String, "")
                _ = try await evaluate(fixture.view, "history.replaceState({}, '', '/'); return true;")
            }
            do {
                _ = try await call(fixture, "webProviderPoll", token)
                XCTFail("A different provisional URL or a second fresh hop cannot resume inspection")
            } catch let failure as EmbeddedWebModelTransport.Failure {
                XCTAssertEqual(failure, .ownershipFailure(.routeBefore))
            }
            let restoring = try XCTUnwrap(restoration)
            let restored = try await restoring.value
            XCTAssertTrue(restored)
            XCTAssertEqual(outcomes, kimiRouteWaitRecords(token, generation, returnExactly ? "returned" : "route_changed"))
            XCTAssertEqual(inspectedRoutes, returnExactly ? [previous] : [])
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        }
    }

    func testCancelledProvisionalRouteWaitDoesNotInspectOrAuthorizeCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let (token, _, generation) = try await startProvisionalFreshHop(fixture)
        var outcomes: [String] = [], inspections = 0
        var polling: Task<String?, Error>?
        fixture.transport.setKimiProvisionalRouteWaitObserverForTesting { record in
            outcomes.append(record)
            if record.hasSuffix(" outcome=waiting") { polling?.cancel() }
        }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect" { inspections += 1 }
        }
        defer {
            polling?.cancel()
            fixture.transport.setKimiProvisionalRouteWaitObserverForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
        }
        let poll = Task { try await self.call(fixture, "webProviderPoll", token)["state"] as? String }
        polling = poll
        do {
            _ = try await poll.value
            XCTFail("Cancellation must interrupt the negative route wait")
        } catch is CancellationError { }
        XCTAssertEqual(outcomes, kimiRouteWaitRecords(token, generation, "cancelled"))
        XCTAssertEqual(inspections, 0)
        let finished = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertEqual(inspections, 0)
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    private func startProvisionalFreshHop(_ fixture: Fixture) async throws -> (String, URL, UUID) {
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic provisional route return")
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        let tab = try XCTUnwrap(fixture.createdID)
        let generation = try XCTUnwrap(fixture.browser.documentGeneration(for: tab))
        let previous = try XCTUnwrap(fixture.view.url)
        _ = try await evaluate(fixture.view, """
            globalThis.fixturePriorProvisionalURL = location.href;
            history.replaceState({}, '', '/'); return true;
            """)
        XCTAssertEqual(fixture.view.url?.path, "/")
        return (token, previous, generation)
    }

    private func kimiRouteWaitRecords(_ token: String, _ generation: UUID, _ outcome: String) -> [String] {
        let prefix = "kimiProvisionalRouteWait version=1 provider=kimi session=\(token.lowercased())"
            + " generation=\(generation.uuidString.lowercased()) sequence=1 outcome="
        return [prefix + "waiting", prefix + outcome]
    }

    func testSameDocumentReturnFromProvisionalToFreshStopsBeforePageReadWithoutReplay() async throws {
        try await assertProvisionalToFreshRejection(afterAdapterEvaluation: false)
    }

    func testSameDocumentReturnFromProvisionalToFreshAfterPageReadRejectsWithoutReplay() async throws {
        try await assertProvisionalToFreshRejection(afterAdapterEvaluation: true)
    }

    private func assertProvisionalToFreshRejection(afterAdapterEvaluation: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic route guard fixture")
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        let tab = try XCTUnwrap(fixture.createdID)
        let generation = try XCTUnwrap(fixture.browser.documentGeneration(for: tab))
        let freshRoute = "history.replaceState({}, '', '/'); return true;"
        var diagnostics: [String] = [], outcomes: [String] = [], completedInspects = 0, changedInCallback = false
        fixture.transport.setKimiProvisionalRouteWaitObserverForTesting { outcomes.append($0) }
        fixture.transport.setKimiSavedRouteRejectionObserverForTesting { diagnostics.append($0) }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect" else { return }
            completedInspects += 1
            if afterAdapterEvaluation, completedInspects == 1 {
                let changed = try? await self.evaluate(fixture.view, freshRoute)
                changedInCallback = changed as? Bool == true
            }
        }
        if !afterAdapterEvaluation { _ = try await evaluate(fixture.view, freshRoute) }
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("Route regression must not release a response")
        } catch let failure as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(failure, .ownershipFailure(afterAdapterEvaluation ? .routeAfter : .routeBefore))
        }
        XCTAssertEqual(changedInCallback, afterAdapterEvaluation)
        let expectedCompletedInspects = afterAdapterEvaluation ? 1 : 0
        XCTAssertEqual(completedInspects, expectedCompletedInspects)
        XCTAssertEqual(fixture.browser.documentGeneration(for: tab), generation)
        func diagnostic(stage: String, action: String) -> String {
            "savedRouteRejection version=2 provider=kimi session=\(token.lowercased()) generation=\(generation.uuidString.lowercased())"
                + " sequence=1 stage=\(stage) action=\(action) reason=regressed_to_fresh"
                + " previousRoute=provisional attemptedRoute=fresh provisionalPinned=true canonicalPinned=false"
                + " generationBound=true submitted=true acknowledged=true pendingSubmission=true firstUserBound=false"
        }
        let pollDiagnostic = diagnostic(stage: afterAdapterEvaluation ? "after" : "before", action: "inspect")
        XCTAssertEqual(diagnostics, [pollDiagnostic])
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertEqual(diagnostics, [pollDiagnostic, diagnostic(stage: "before", action: "cleanup_inspect")])
        XCTAssertEqual(outcomes, afterAdapterEvaluation ? [] : kimiRouteWaitRecords(token, generation, "expired"))
        XCTAssertEqual(completedInspects, expectedCompletedInspects)
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    func testForeignCanonicalRouteCannotDeleteOrCloseItsOwnedView() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic wrong-route cleanup")
        _ = try await wait(fixture, token, state: "complete")
        _ = try await evaluate(fixture.view, "history.replaceState({}, '', '/chat/22221111-abcd-4333-8444-555555555555'); return true;")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testThrownSendCannotPublishAnswerDeleteOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, """
            const original = HTMLElement.prototype.click;
            HTMLElement.prototype.click = function() {
              const send = this.classList.contains('send-button-container');
              original.call(this);
              if (send) throw new Error('Fixture lost Send acknowledgement after dispatch');
            };
            return true;
            """, world: world)
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic uncertain Send")
            XCTFail("A thrown Send cannot be acknowledged")
        } catch { }
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("An unacknowledged Send cannot publish its answer")
        } catch { }
        let failed = try await call(fixture, "webProviderFinish", token)
        let retried = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed"); XCTAssertEqual(retried["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testThrownConfirmationCannotBecomeSuccessFromAnEmptyRootOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic lost confirmation acknowledgement")
        _ = try await wait(fixture, token, state: "complete")
        _ = try await evaluate(fixture.view, """
            const original = HTMLElement.prototype.click;
            HTMLElement.prototype.click = function() {
              const confirm = this.getAttribute('data-testid') === 'confirm-dialog-confirm';
              original.call(this);
              if (confirm) throw new Error('Fixture lost acknowledgement after dispatch');
            };
            return true;
            """, world: world)
        let failed = try await call(fixture, "webProviderFinish", token)
        let retried = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed"); XCTAssertEqual(retried["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testReasoningMarkdownIsNotAnotherFinalSourceAndExactReplyStillRequiresCompletion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic reasoning plus final literal response")
        let count = try await evaluate(fixture.view, """
            kimiFixture.canonicalize();
            const part = document.querySelector('.chat-content-item-assistant .toolcall-rollup__part');
            const thinking = document.createElement('div'); thinking.className = 'thinking-container';
            const container = document.createElement('div'); container.className = 'markdown-container';
            const markdown = document.createElement('div'); markdown.className = 'markdown';
            markdown.textContent = 'PRIVATE_REASONING_CANARY'; container.append(markdown); thinking.append(container); part.append(thinking);
            return document.querySelectorAll('.chat-content-item-assistant .markdown').length;
            """) as? Int
        XCTAssertEqual(count, 2)
        let running = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(running["state"] as? String, "running")
        _ = try await evaluate(fixture.view, "kimiFixture.completeResponse(); return true;")
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual(context["responseCount"] as? Int, 1)
        XCTAssertEqual((context["firstUserFingerprint"] as? String)?.count, 64)
        let selected = try WebsiteModelEvidence.parse(complete["modelEvidence"], provider: "kimi", expected: choice)
        XCTAssertEqual(selected.selected.key, choice.key)
        XCTAssertEqual(selected.selected.label, choice.label)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testReasoningLikeAuthoredContentAndAmbiguousFinalMarkdownCannotPublishOrReplay() async throws {
        for kind in ["unknown", "inside-final", "extra-final", "outside-prose"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.holdResponse = true; return true;")
            let prompt = "Synthetic rejected final source"
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            _ = try await evaluate(fixture.view, """
                kimiFixture.canonicalize();
                const final = document.querySelector('.chat-content-item-assistant .markdown');
                const part = document.querySelector('.chat-content-item-assistant .toolcall-rollup__part');
                const wrapper = document.createElement('div');
                wrapper.className = '\(kind)' === 'unknown' ? 'unknown-widget' : 'thinking-container';
                const markdown = document.createElement('div'); markdown.className = 'markdown'; markdown.textContent = 'PRIVATE_AUTHORED_CANARY';
                wrapper.append(markdown);
                if ('\(kind)' === 'inside-final') final.append(wrapper);
                else if ('\(kind)' === 'extra-final') final.parentElement.append(final.cloneNode(true));
                else if ('\(kind)' === 'outside-prose') { const p = document.createElement('p'); p.textContent = 'PRIVATE_AUTHORED_CANARY'; final.parentElement.append(p); }
                else part.append(wrapper);
                kimiFixture.completeResponse(); return true;
                """)
            do { _ = try await call(fixture, "webProviderPoll", token); XCTFail("Authored ambiguity must not publish a partial response") }
            catch let error as EmbeddedWebModelTransport.Failure { XCTAssertEqual(error, .responseFormatUnavailable) }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Format failure must not replay Send") }
            catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testFormatFailurePublishesNoPartialJSONButOwnedCleanupRemainsPossible() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic outside-prose reply")
        _ = try await evaluate(fixture.view, """
            kimiFixture.canonicalize();
            const prose = document.createElement('p'); prose.textContent = 'Outside authored prose must not be discarded.';
            document.querySelector('.markdown').append(prose); kimiFixture.completeResponse(); return true;
            """)
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("Outside prose must reject publication")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .responseFormatUnavailable)
        }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testMalformedReplyCleanupKeepsItsReadOnlyScopeAcrossCanonicalPromotion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic crossed-route malformed cleanup")
        _ = try await evaluate(fixture.view, """
            const prose = document.createElement('p'); prose.textContent = 'Outside authored prose.';
            document.querySelector('.markdown').append(prose); kimiFixture.completeResponse(); return true;
            """)
        // The provisional route has no response authority yet, even when its
        // rendered body is malformed. Cleanup must preserve its separate read
        // scope when this route promotes during the next observation.
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        var promote = true
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", promote {
                promote = false
                _ = try? await self.evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
            }
        }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertFalse(promote)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testCancellationDeletesTheExactBoundStreamingConversation() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic streaming cancellation")
        _ = try await evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
        let running = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(running["state"] as? String, "running")
        let finished = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testFreshOwnedPageClosesWithoutSendingOrDeleting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
    }

    private func start(_ fixture: Fixture) async throws -> String {
        let parameters = ["provider": "kimi", "modelChoice": try XCTUnwrap(choice.canonicalJSONString)]
        let data = try await fixture.transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: parameters))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(snapshot["sessionToken"] as? String)
        _ = try await wait(fixture, token, state: "ready")
        return token
    }
    private func call(_ fixture: Fixture, _ operation: String, _ token: String, prompt: String? = nil) async throws -> [String: Any] {
        var values = ["sessionToken": token]; if let prompt { values["prompt"] = prompt }
        do {
            let data = try await fixture.transport.request(operation: operation, params: JSONSerialization.data(withJSONObject: values))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch {
            // Preserve the original bounded failure before WebKit teardown can
            // replace its description with a deinitialization-state failure.
            let native = (error as? EmbeddedWebModelTransport.Failure).map { String(describing: $0) } ?? "other"
            FileHandle.standardError.write(Data("KimiFixtureOriginalError phase=\(operation) type=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code) native=\(native)\n".utf8))
            if operation == "webProviderSend", let shape = try? await evaluate(fixture.view, #"""
                const editor = document.querySelector('.chat-input-editor');
                const expected = globalThis.__computaKimiSavedSessionV1?.inserted?.prompt;
                if (!editor || typeof expected !== 'string') return {insertedPromptPresent:typeof expected === 'string'};
                const rendered = editor.innerText, text = editor.textContent;
                const paragraphs = [...editor.children], logical = paragraphs.map(node => node.textContent).join('\n');
                let mismatch = 0; while (mismatch < Math.min(logical.length, expected.length) && logical[mismatch] === expected[mismatch]) mismatch++;
                const logicalMatch = logical === expected;
                const tag = node => node.nodeType === 3 ? 'text' : ['P','DIV','BR','SPAN'].includes(node.tagName) ? node.tagName : 'other';
                const nodes = [...editor.childNodes].slice(0,16).map(node => ({tag:tag(node),
                    chars:(node.textContent||'').length, children:[...node.childNodes].slice(0,8).map(tag)}));
                return {expectedChars:expected.length, renderedChars:rendered.length, textChars:text.length,
                    logicalChars:logical.length, logicalMatch, logicalOnlyParagraphs:paragraphs.every(node=>node.tagName==='P'),
                    mismatchIndex:logicalMatch?-1:mismatch,
                    expectedCodePoint:logicalMatch?-1:expected.codePointAt(mismatch)??-1,
                    logicalCodePoint:logicalMatch?-1:logical.codePointAt(mismatch)??-1,
                    expectedNBSPs:(expected.match(/\u00a0/g)||[]).length, logicalNBSPs:(logical.match(/\u00a0/g)||[]).length,
                    spacesInsteadOfNBSPMatch:logical.replace(/\u00a0/g,' ')===expected,
                    exact:rendered===expected, oneTerminalLF:rendered===expected+'\n', twoTerminalLF:rendered===expected+'\n\n',
                    expectedNewlines:(expected.match(/\n/g)||[]).length, renderedNewlines:(rendered.match(/\n/g)||[]).length,
                    terminalNewlines:(rendered.match(/\n*$/)||[''])[0].length,
                    renderedWithoutTerminalNewlinesMatches:rendered.replace(/\n+$/,'')===expected,
                    textExact:text===expected, childCount:editor.childNodes.length, nodes};
                """#, world: world), let safe = try? JSONSerialization.data(withJSONObject: shape, options: .sortedKeys), safe.count <= 4096,
                let line = String(data: safe, encoding: .utf8) {
                FileHandle.standardError.write(Data(("KimiFixtureComposerShape " + line + "\n").utf8))
            }
            if operation == "webProviderSend", let events = try? await evaluate(fixture.view, "return kimiFixture.inputEvents;"),
               let encoded = try? JSONSerialization.data(withJSONObject: events, options: .sortedKeys), encoded.count <= 8192 {
                FileHandle.standardError.write(Data(("KimiFixtureInputEvents " + String(decoding: encoded, as: UTF8.self) + "\n").utf8))
            }
            throw error
        }
    }
    private func wait(_ fixture: Fixture, _ token: String, state: String) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            let revision = try await fixture.transport.changeRevision(sessionToken: token)
            let value = try await call(fixture, "webProviderPoll", token)
            if value["state"] as? String == state { return value }
            _ = try await fixture.transport.waitForChange(sessionToken: token, after: try XCTUnwrap(revision), until: deadline)
        }
        throw FixtureFailure.timeout
    }
    private func assertCounts(_ fixture: Fixture, sends: Int, headers: Int, selections: Int, confirmations: Int) async throws {
        let actual = try await evaluate(fixture.view, "return [kimiFixture.counters.sends, kimiFixture.counters.headerOpens, kimiFixture.counters.deleteSelections, kimiFixture.counters.confirmations];") as? [Int]
        XCTAssertEqual(actual, [sends, headers, selections, confirmations])
    }
    private func assertInsertionCounts(_ fixture: Fixture, settlements: Int, sends: Int) async throws {
        let value = try await evaluate(fixture.view,
            "return [kimiFixture.counters.beforeInput, kimiFixture.counters.input, kimiFixture.counters.settlements, kimiFixture.counters.earlySends, kimiFixture.counters.sends];") as? [Int]
        let actual = try XCTUnwrap(value)
        XCTAssertEqual(actual.count, 5)
        guard actual.count == 5 else { return }
        XCTAssertEqual(actual[0], 1, "Exactly one native insertion's beforeinput payload")
        XCTAssertEqual(actual[1], 0, "Cancelling the native edit prevents its substitution/input events")
        XCTAssertEqual(Array(actual[2...]), [settlements, 0, sends])
    }
    private func evaluate(_ view: WKWebView, _ source: String, world: WKContentWorld = .page) async throws -> Any {
        let completion = EmbeddedScriptResult()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            completion.setTimeout(Task {
                do { try await Task.sleep(for: .seconds(3)); completion.complete(.failure(FixtureFailure.timeout)) } catch { }
            })
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    do { completion.complete(.success(try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))) }
                    catch { completion.complete(.failure(error)) }
                case .failure(let error): completion.complete(.failure(error))
                }
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
    private enum FixtureFailure: Error { case timeout }
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    @MainActor private final class Fixture {
        let browser = EmbeddedBrowserSession(persistent: false)
        let window: Window
        let host: EmbeddedModelRenderContainer
        let humanID: UUID
        var transport: EmbeddedWebModelTransport!
        var createdID: UUID?
        private var retainedView: WKWebView?
        var view: WKWebView { retainedView! }
        init(initialControlsPending: Bool = false, initialEditorAttributePending: Bool = false, initialNestedModel: Bool = false) throws {
            window = Window(contentRect: NSRect(x: 20, y: 20, width: 1024, height: 768), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            host = EmbeddedModelRenderContainer(session: browser); host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            window.contentView = host; browser.installModelRenderHost(host); window.orderBack(nil)
            humanID = try browser.createTab()
            browser.webView(for: humanID)?.loadHTMLString("<p>Untouched human fixture</p>", baseURL: URL(string: "https://example.test/"))
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] url in
                let id = try self.browser.createUnloadedModelTabForTesting()
                let view = try XCTUnwrap(self.browser.webView(for: id)); view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
                self.createdID = id; self.retainedView = view
                let hydrationSetup = """
                    <script>(() => {
                      const controls = [...document.body.children].filter(node => node.tagName !== 'SCRIPT');
                      for (const node of controls) node.remove();
                      window.fixtureHydration = {restored:false, restore() {
                        if (this.restored) throw new Error('Fixture controls already restored');
                        this.restored = true;
                        for (const node of controls) document.body.append(node);
                      }};
                    })();</script>
                    """
                let attributeSetup = """
                    <script>(() => {
                      const editor = document.querySelector('.chat-input-editor');
                      editor.removeAttribute('contenteditable');
                      window.fixtureHydration = {restored:false, restore() {
                        if (this.restored) throw new Error('Fixture editor already restored');
                        this.restored = true;
                        editor.setAttribute('contenteditable', 'true');
                      }};
                    })();</script>
                    """
                let nestedSetup = initialNestedModel ? "<script>kimiFixture.selectNestedInitially();</script>" : ""
                let setup = nestedSetup + (initialControlsPending ? hydrationSetup : initialEditorAttributePending ? attributeSetup : "")
                let html = KimiFixturePage.html.replacingOccurrences(of: "</body>", with: setup + "</body>")
                view.loadHTMLString(html, baseURL: url)
                return id
            })
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}
