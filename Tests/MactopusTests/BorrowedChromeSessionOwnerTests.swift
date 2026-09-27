import Foundation
import XCTest
@testable import Mactopus

/// Inert protocol fixtures only. These do not authorize or access user Chrome.
final class BorrowedChromeSessionOwnerTests: XCTestCase {
    func testAdmissionRequiresConsentAndExactChromeApplicationLabel() throws {
        let transport = OwnerTestTransport()
        XCTAssertThrowsError(try BorrowedChromeSessionOwner(
            application: ownerTestApplication, transport: transport, consent: ChromeDebuggingConsent(), verifyIdentity: {}
        )) { XCTAssertEqual($0 as? ChromeDebuggingEndpointError, .consentRequired) }
        XCTAssertThrowsError(try BorrowedChromeSessionOwner(
            application: .init(processIdentifier: 42, bundleIdentifier: "other", executableURL: ownerTestApplication.executableURL),
            transport: transport, consent: ChromeDebuggingConsent(approvedByUser: true), verifyIdentity: {}
        )) { XCTAssertEqual($0 as? BorrowedChromeSessionOwnerError, .invalidApplication) }
    }

    func testPaginationIsCompleteBoundedAndDoesNotAttach() async throws {
        let fixture = try OwnerFixture(count: 63)
        let turn = try await fixture.turn()
        let first = try await fixture.owner.listTabs(turn: turn)
        let second = try await fixture.owner.listTabs(turn: turn, cursor: XCTUnwrap(first.nextCursor))
        let third = try await fixture.owner.listTabs(turn: turn, cursor: XCTUnwrap(second.nextCursor))
        XCTAssertEqual(first.items.count, 25)
        XCTAssertEqual(second.items.count, 25)
        XCTAssertEqual(third.items.count, 13)
        XCTAssertEqual(third.totalCount, 63)
        XCTAssertNil(third.nextCursor)
        XCTAssertEqual(Set((first.items + second.items + third.items).map(\.candidateToken)).count, 63)
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.lists, 1)
        XCTAssertEqual(counts.attaches, 0)
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testHostCandidateLookupRetainsExactIdentityAndOnlyPositiveAvailability() async throws {
        let fixture = try OwnerFixture()
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        await fixture.transport.setCandidates([
            .init(targetID: "free", title: "Duplicate", url: url, availability: .available),
            .init(targetID: "busy", title: "Duplicate", url: url, availability: .busy),
            .init(targetID: "unknown", title: "Duplicate", url: url),
        ])
        let turn = try await fixture.turn()
        let first = try await fixture.owner.listTabs(turn: turn, pageSize: 1)
        let token = try XCTUnwrap(first.items.first?.candidateToken)
        let selected = try await fixture.owner.observedCandidate(turn: turn, candidateToken: token)
        XCTAssertEqual(selected.targetID, "free")
        XCTAssertEqual(selected.availability, .available)
        XCTAssertEqual(first.items.first?.availability, .available)
        let available = try await fixture.owner.availableTargetIDs(turn: turn)
        XCTAssertEqual(available, ["free"])
        _ = try await fixture.owner.listTabs(turn: turn)
        do {
            _ = try await fixture.owner.observedCandidate(turn: turn, candidateToken: token)
            XCTFail("Refreshing inventory must invalidate the earlier opaque token.")
        } catch { XCTAssertEqual(error as? BorrowedChromeSessionOwnerError, .invalidCandidate) }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 0)
        await fixture.owner.disconnect()
    }

    func testByteBoundedPagesContinueAtFirstUnreturnedCandidateWithoutDuplicates() async throws {
        let fixture = try OwnerFixture()
        let candidates = try (0..<23).map { index in
            let prefix = "https://example.com/\(index)/"
            return BorrowedChromeTabCandidate(
                targetID: "target-\(index)",
                title: "Tab \(index) \"\\👋" + String(repeating: "\u{0001}", count: 1_000),
                url: try XCTUnwrap(URL(string: prefix + String(repeating: "a", count: 4_000 - prefix.utf8.count)))
            )
        }
        await fixture.transport.setCandidates(candidates)
        let turn = try await fixture.turn()
        var cursor: UUID?
        var tokens = [UUID]()
        var urls = [URL]()
        var reachedEnd = false
        for index in 0...candidates.count {
            let requestedSize = index % 2 == 0 ? 25 : 1
            let page = try await fixture.owner.listTabs(turn: turn, cursor: cursor, pageSize: requestedSize)
            XCTAssertFalse(page.items.isEmpty)
            XCTAssertLessThanOrEqual(page.items.count, requestedSize)
            if index == 0 { XCTAssertLessThan(page.items.count, requestedSize, "Byte budget must reduce the initial page.") }
            XCTAssertEqual(page.totalCount, candidates.count)
            let output = try BorrowedChromeInventoryPresentation.render(page)
            XCTAssertLessThanOrEqual(output.utf8.count, BorrowedChromeInventoryPresentation.maximumPageBytes)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            let rows = try XCTUnwrap(object["items"] as? [[String: Any]])
            XCTAssertEqual(rows.count, page.items.count)
            XCTAssertEqual(object["returned"] as? Int, page.items.count)
            for (item, row) in zip(page.items, rows) {
                XCTAssertEqual(row["candidate_token"] as? String, item.candidateToken.uuidString)
                XCTAssertEqual(row["url"] as? String, item.url.absoluteString)
                XCTAssertEqual(row["title_truncated"] as? Bool, true)
                XCTAssertLessThanOrEqual(try XCTUnwrap(row["title"] as? String).utf8.count, 200)
            }
            tokens += page.items.map(\.candidateToken)
            urls += page.items.map(\.url)
            cursor = page.nextCursor
            if cursor == nil { reachedEnd = true; break }
        }
        XCTAssertTrue(reachedEnd)
        XCTAssertEqual(tokens.count, candidates.count)
        XCTAssertEqual(Set(tokens).count, candidates.count)
        XCTAssertEqual(urls, candidates.map(\.url), "No candidate may be skipped when a row exceeds the remaining page budget.")
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.lists, 1)
        XCTAssertEqual(counts.attaches, 0)
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testByteBoundedCursorReplayUsesTheSameCompletePrefix() async throws {
        let fixture = try OwnerFixture()
        let prefix = "https://example.com/"
        let url = try XCTUnwrap(URL(string: prefix + String(repeating: "a", count: 4_000 - prefix.utf8.count)))
        await fixture.transport.setCandidates((0..<10).map { index in
            .init(targetID: "target-\(index)", title: String(repeating: "\u{0001}", count: 200), url: url)
        })
        let turn = try await fixture.turn()
        let first = try await fixture.owner.listTabs(turn: turn)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await fixture.owner.listTabs(turn: turn, cursor: cursor, pageSize: 100)
        let replay = try await fixture.owner.listTabs(turn: turn, cursor: cursor, pageSize: 100)
        XCTAssertEqual(second, replay)
        XCTAssertTrue(Set(first.items.map(\.candidateToken)).isDisjoint(with: second.items.map(\.candidateToken)))
        XCTAssertLessThanOrEqual(try BorrowedChromeInventoryPresentation.render(second).utf8.count, 12 * 1_024)
        await fixture.owner.disconnect()
    }

    func testOmittedURLAndTruncatedTitleRetainFullNativeBindingMetadata() async throws {
        let fixture = try OwnerFixture()
        let title = String(repeating: "👋\"\\\n", count: 1_000)
        let url = try XCTUnwrap(URL(string: "https://example.com/" + String(repeating: "x", count: 12_000)))
        await fixture.transport.setCandidates([.init(targetID: "exact-native-target", title: title, url: url)])
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.title, title)
        XCTAssertEqual(item.url, url)
        let output = try BorrowedChromeInventoryPresentation.render(page)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let row = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["title_truncated"] as? Bool, true)
        XCTAssertEqual(row["url_omitted"] as? Bool, true)
        XCTAssertNil(row["url"])
        let binding = try await fixture.owner.bind(turn: turn, candidateToken: item.candidateToken)
        XCTAssertEqual(binding.targetID, "exact-native-target")
        let observation = try await fixture.owner.snapshot(turn: turn, binding: binding)
        XCTAssertEqual(observation.snapshot.documentURL, url)
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 1)
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testEmptyInventoryCanBeRenderedAsATerminalPage() async throws {
        let fixture = try OwnerFixture(count: 0)
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertNoThrow(try BorrowedChromeInventoryPresentation.render(page))
        await fixture.owner.disconnect()
    }

    func testCandidatesAndCursorsCannotCrossTurnOrOwner() async throws {
        let fixture = try OwnerFixture(count: 26), other = try OwnerFixture()
        let a = try await fixture.turn(), b = try await fixture.turn("other")
        let page = try await fixture.owner.listTabs(turn: a)
        _ = try await fixture.owner.listTabs(turn: b)
        await expectOwnerError(.invalidCandidate) {
            _ = try await fixture.owner.bind(turn: b, candidateToken: page.items[0].candidateToken)
        }
        await expectOwnerError(.invalidCursor) {
            _ = try await fixture.owner.listTabs(turn: b, cursor: page.nextCursor)
        }
        await expectOwnerError(.invalidTurn) { _ = try await other.owner.listTabs(turn: a) }
        await fixture.owner.disconnect()
        await other.owner.disconnect()
    }

    func testRefreshingInventoryInvalidatesEveryPriorToken() async throws {
        let fixture = try OwnerFixture(count: 26)
        let turn = try await fixture.turn()
        let old = try await fixture.owner.listTabs(turn: turn)
        let fresh = try await fixture.owner.listTabs(turn: turn)
        XCTAssertNotEqual(old.items[0].candidateToken, fresh.items[0].candidateToken)
        await expectOwnerError(.invalidCandidate) {
            _ = try await fixture.owner.bind(turn: turn, candidateToken: old.items[0].candidateToken)
        }
        await expectOwnerError(.invalidCursor) { _ = try await fixture.owner.listTabs(turn: turn, cursor: old.nextCursor) }
        await fixture.owner.disconnect()
    }

    func testTurnRevocationInvalidatesTokensEvenWhenTaskAndTurnLabelsAreReused() async throws {
        let fixture = try OwnerFixture()
        let old = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: old)
        await fixture.owner.revoke(turn: old)
        let fresh = try await fixture.turn()
        _ = try await fixture.owner.listTabs(turn: fresh)
        await expectOwnerError(.invalidTurn) { _ = try await fixture.owner.listTabs(turn: old) }
        await expectOwnerError(.invalidCandidate) {
            _ = try await fixture.owner.bind(turn: fresh, candidateToken: page.items[0].candidateToken)
        }
        await fixture.owner.disconnect()
    }

    func testTaskTurnAndPageCapacitiesFailClosed() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        await expectOwnerBrokerError(.operationInProgress) { _ = try await fixture.turn() }
        for index in 1..<16 { _ = try await fixture.turn("task-\(index)") }
        await expectOwnerError(.capacityExceeded) { _ = try await fixture.turn("seventeenth") }
        for size in [0, -1, 101] {
            await expectOwnerError(.invalidPageSize) { _ = try await fixture.owner.listTabs(turn: turn, pageSize: size) }
        }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.lists, 0)
        await fixture.owner.disconnect()
    }

    func testOversizedInventoryIsRejectedRatherThanTruncated() async throws {
        let fixture = try OwnerFixture(count: 2_049)
        let turn = try await fixture.turn()
        await expectOwnerError(.capacityExceeded) { _ = try await fixture.owner.listTabs(turn: turn) }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 0)
        await fixture.owner.disconnect()
    }

    func testSharedMetadataBudgetRejectsThirdInventoryAndRecoversAfterRevoke() async throws {
        let fixture = try OwnerFixture(count: 30, title: String(repeating: "x", count: 16_000))
        let a = try await fixture.turn("a"), b = try await fixture.turn("b"), c = try await fixture.turn("c")
        _ = try await fixture.owner.listTabs(turn: a)
        _ = try await fixture.owner.listTabs(turn: b)
        await expectOwnerError(.capacityExceeded) { _ = try await fixture.owner.listTabs(turn: c) }
        await fixture.owner.revoke(turn: a)
        let page = try await fixture.owner.listTabs(turn: c)
        XCTAssertEqual(page.totalCount, 30)
        await fixture.owner.disconnect()
    }

    func testSharedTargetBudgetDoesNotMultiplyAcrossTasks() async throws {
        let fixture = try OwnerFixture(count: 1_025)
        let a = try await fixture.turn("a"), b = try await fixture.turn("b")
        _ = try await fixture.owner.listTabs(turn: a)
        await expectOwnerError(.capacityExceeded) { _ = try await fixture.owner.listTabs(turn: b) }
        await fixture.owner.disconnect()
    }

    func testMalformedInventoryCannotPublishCandidates() async throws {
        let fixtures: [[BorrowedChromeTabCandidate]] = [
            [ownerCandidate(0), ownerCandidate(0)],
            [.init(targetID: "a", title: String(repeating: "x", count: 16_385), url: URL(string: "https://example.com")!)],
            [.init(targetID: "a", title: "settings", url: URL(string: "chrome://settings")!)],
            [.init(targetID: "a/other", title: "invalid", url: URL(string: "https://example.com")!)]
        ]
        for candidates in fixtures {
            let fixture = try OwnerFixture()
            await fixture.transport.setCandidates(candidates)
            let turn = try await fixture.turn()
            await expectOwnerError(.invalidInventory) { _ = try await fixture.owner.listTabs(turn: turn) }
            await fixture.owner.disconnect()
        }
    }

    func testExactTokenSelectsOneOfIdenticalVisibleTabs() async throws {
        let fixture = try OwnerFixture(count: 2)
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        XCTAssertEqual(page.items[0].title, page.items[1].title)
        XCTAssertEqual(page.items[0].url, page.items[1].url)
        let binding = try await fixture.owner.bind(turn: turn, candidateToken: page.items[1].candidateToken)
        XCTAssertEqual(binding.targetID, "target-1")
        XCTAssertEqual(binding.ownership, .borrowed)
        let again = try await fixture.owner.bind(turn: turn, candidateToken: page.items[1].candidateToken)
        XCTAssertEqual(binding, again)
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 1)
        await fixture.owner.disconnect()
    }

    func testReservationPrecedesAttachAndLosingTaskNeverDetachesWinner() async throws {
        let fixture = try OwnerFixture()
        let a = try await fixture.turn("a"), b = try await fixture.turn("b")
        let pageA = try await fixture.owner.listTabs(turn: a), pageB = try await fixture.owner.listTabs(turn: b)
        await fixture.transport.onAttach {
            await expectOwnerBrokerError(.operationInProgress) {
                _ = try await fixture.owner.bind(turn: b, candidateToken: pageB.items[0].candidateToken)
            }
        }
        let binding = try await fixture.owner.bind(turn: a, candidateToken: pageA.items[0].candidateToken)
        XCTAssertNoThrow(try binding.lifetime.check())
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 1)
        XCTAssertEqual(counts.detaches, 0)
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testRebindingDetachesOnlyPreviousExactSession() async throws {
        let fixture = try OwnerFixture(count: 2)
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        let old = try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken)
        let fresh = try await fixture.owner.bind(turn: turn, candidateToken: page.items[1].candidateToken)
        XCTAssertThrowsError(try old.lifetime.check())
        XCTAssertNoThrow(try fresh.lifetime.check())
        let detached = await fixture.transport.detached
        XCTAssertEqual(detached.map(\.targetID), ["target-0"])
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testFailedObservationDetachesOnlyOwnAttachAndReleasesReservation() async throws {
        let fixture = try OwnerFixture()
        let a = try await fixture.turn("a"), b = try await fixture.turn("b")
        let pa = try await fixture.owner.listTabs(turn: a), pb = try await fixture.owner.listTabs(turn: b)
        await fixture.transport.onObserve { throw BrowserTabBrokerError.staleDocument }
        await expectOwnerBrokerError(.staleDocument) {
            _ = try await fixture.owner.bind(turn: a, candidateToken: pa.items[0].candidateToken)
        }
        let winner = try await fixture.owner.bind(turn: b, candidateToken: pb.items[0].candidateToken)
        XCTAssertNoThrow(try winner.lifetime.check())
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 2)
        XCTAssertEqual(counts.detaches, 1)
        await fixture.owner.disconnect()
    }

    func testCancellationAfterAttachDetachesExactSessionWithoutClosingUserResources() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        await fixture.transport.onAttach { withUnsafeCurrentTask { $0?.cancel() } }
        let attempt = Task { try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken) }
        do { _ = try await attempt.value; XCTFail("Cancelled attach must not publish a binding") }
        catch is CancellationError { }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 1)
        XCTAssertEqual(counts.forbidden, 0)
        XCTAssertEqual(counts.shutdowns, 0)
        await fixture.owner.disconnect()
    }

    func testTurnRevokedWhileAttachSuspendsCleansUpItsLateExactSession() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        await fixture.transport.onAttach { await fixture.owner.revoke(turn: turn) }
        await expectOwnerError(.invalidTurn) {
            _ = try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken)
        }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 1)
        XCTAssertEqual(counts.shutdowns, 0)
        await fixture.owner.disconnect()
    }

    func testRevocationDuringBindObservationCannotPublishOrDoubleDetach() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        await fixture.transport.onObserve { await fixture.owner.revoke(turn: turn) }
        do { _ = try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken); XCTFail("Must revoke") }
        catch { }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 1)
        XCTAssertEqual(counts.shutdowns, 0)
        await fixture.owner.disconnect()
    }

    func testDisconnectWhileAttachSuspendsCannotRepublishAHandle() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        await fixture.transport.onAttach { await fixture.owner.disconnect() }
        await expectOwnerError(.disconnected) {
            _ = try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken)
        }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
        XCTAssertEqual(counts.forbidden, 0)
    }

    func testObservedConnectionDeathInvalidatesCachedInventoryAndTurns() async throws {
        let fixture = try OwnerFixture(count: 26)
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        await fixture.transport.breakConnection()
        await expectOwnerBrokerError(.browserGenerationChanged) {
            _ = try await fixture.owner.listTabs(turn: turn, cursor: page.nextCursor)
        }
        XCTAssertThrowsError(try turn.lifetime.check())
        await expectOwnerError(.disconnected) { _ = try await fixture.turn("new") }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testAnnotatedBindTimeoutSurvivesCleanupAndRevokesStaleInventory() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let other = try await fixture.turn("other")
        let page = try await fixture.owner.listTabs(turn: turn)
        let failure = BorrowedChromeCommandTimeout(stage: .attachment, method: "Target.attachToTarget")
        await fixture.transport.onAttach {
            await fixture.transport.breakConnection()
            throw failure
        }
        do {
            _ = try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken)
            XCTFail("A timed-out attachment must not publish authority.")
        } catch let error as BorrowedChromeCommandTimeout {
            XCTAssertEqual(error, failure, "Cleanup must preserve the original safe command diagnostic.")
        }
        XCTAssertThrowsError(try turn.lifetime.check())
        XCTAssertThrowsError(try other.lifetime.check())
        XCTAssertThrowsError(try fixture.consent.check())
        await expectOwnerError(.disconnected) {
            _ = try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken)
        }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 1)
        XCTAssertEqual(counts.shutdowns, 1)
        XCTAssertEqual(counts.forbidden, 0)
    }

    func testRepeatedBindObservingDeadReaderRevokesAllCachedCapabilities() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let other = try await fixture.turn("other")
        let page = try await fixture.owner.listTabs(turn: turn)
        let token = page.items[0].candidateToken
        let binding = try await fixture.owner.bind(turn: turn, candidateToken: token)
        await fixture.transport.breakConnection()
        await expectOwnerBrokerError(.browserGenerationChanged) {
            _ = try await fixture.owner.bind(turn: turn, candidateToken: token)
        }
        XCTAssertThrowsError(try binding.lifetime.check())
        XCTAssertThrowsError(try turn.lifetime.check())
        XCTAssertThrowsError(try other.lifetime.check())
        XCTAssertThrowsError(try fixture.consent.check())
        await expectOwnerError(.disconnected) { _ = try await fixture.turn("new") }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.attaches, 1)
        XCTAssertEqual(counts.shutdowns, 1)
        XCTAssertEqual(counts.forbidden, 0)
    }

    func testConsentRevocationInvalidatesBoundCapabilityBeforeAnyMoreInput() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let observation = try await fixture.observation(turn)
        fixture.consent.revoke()
        do {
            try await fixture.owner.perform(turn: turn, binding: observation.binding,
                                            snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            XCTFail("Revoked consent must reject input")
        } catch { XCTAssertEqual(error as? ChromeDebuggingEndpointError, .consentRequired) }
        XCTAssertThrowsError(try observation.binding.lifetime.check())
        await fixture.owner.disconnect()
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.mutations, 0)
        XCTAssertEqual(counts.forbidden, 0)
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testSynchronousTurnRevocationImmediatelyRevokesChildMutationLifetime() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let observation = try await fixture.observation(turn)
        turn.lifetime.revoke()
        XCTAssertThrowsError(try observation.binding.lifetime.check())
        let permit = BrowserMutationPermit(lifetime: observation.binding.lifetime)
        XCTAssertThrowsError(try permit.commit { XCTFail("Revoked turn must not enqueue input") })
        await fixture.owner.revoke(turn: turn)
        await fixture.owner.disconnect()
    }

    func testDisconnectSynchronouslyRevokesOriginalConnectionConsent() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let observation = try await fixture.observation(turn)
        await fixture.owner.disconnect()
        XCTAssertThrowsError(try fixture.consent.check()) {
            XCTAssertEqual($0 as? ChromeDebuggingEndpointError, .consentRequired)
        }
        XCTAssertThrowsError(try turn.lifetime.check())
        XCTAssertThrowsError(try observation.binding.lifetime.check())
        await fixture.owner.disconnect()
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testForwardedSnapshotPressAndUnicodeTextRetainBrokerGuards() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        let first = try await fixture.observation(turn)
        try await fixture.owner.perform(turn: turn, binding: first.binding, snapshot: first.snapshot,
                                        elementIndex: 0, action: "AXPress")
        await expectOwnerBrokerError(.staleSnapshot) {
            try await fixture.owner.perform(turn: turn, binding: first.binding, snapshot: first.snapshot,
                                            elementIndex: 0, action: "AXPress")
        }
        let second = try await fixture.owner.snapshot(turn: turn, binding: first.binding)
        try await fixture.owner.setText(turn: turn, binding: second.binding, snapshot: second.snapshot,
                                        elementIndex: 1, text: "HDé7 東京 👋")
        let value = await fixture.transport.text
        XCTAssertEqual(value, "HDé7 東京 👋")
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.mutations, 2)
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testCrossTurnBindingCannotReachTransport() async throws {
        let fixture = try OwnerFixture()
        let a = try await fixture.turn("a"), b = try await fixture.turn("b")
        let observation = try await fixture.observation(a)
        await expectOwnerBrokerError(.handleMissing) {
            _ = try await fixture.owner.snapshot(turn: b, binding: observation.binding)
        }
        await fixture.owner.disconnect()
    }

    func testUncertainDetachDisconnectsRatherThanReusingTargetLease() async throws {
        let fixture = try OwnerFixture()
        let a = try await fixture.turn("a"), b = try await fixture.turn("b")
        let observation = try await fixture.observation(a)
        await fixture.transport.failNextDetach()
        await fixture.owner.revoke(turn: a)
        XCTAssertThrowsError(try observation.binding.lifetime.check())
        XCTAssertThrowsError(try b.lifetime.check())
        await expectOwnerError(.disconnected) { _ = try await fixture.owner.listTabs(turn: b) }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
        XCTAssertEqual(counts.forbidden, 0)
    }

    func testInventoryResultArrivingAfterRevocationCannotRestoreTokens() async throws {
        let fixture = try OwnerFixture()
        let turn = try await fixture.turn()
        await fixture.transport.onList { await fixture.owner.revoke(turn: turn) }
        await expectOwnerError(.invalidTurn) { _ = try await fixture.owner.listTabs(turn: turn) }
        let fresh = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: fresh)
        XCTAssertEqual(page.totalCount, 1)
        await fixture.owner.disconnect()
    }

    func testRuntimeRecoveryRevokesImmediatelyAndPreservesOnlyHealthyWire() async throws {
        let fixture = try OwnerFixture()
        let old = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: old)
        let binding = try await fixture.owner.bind(turn: old, candidateToken: page.items[0].candidateToken)
        let token = try fixture.owner.suspendForRuntimeRecovery()
        XCTAssertThrowsError(try old.lifetime.check())
        XCTAssertThrowsError(try binding.lifetime.check())
        XCTAssertNoThrow(try fixture.consent.check())
        await expectOwnerError(.runtimeRecoveryInProgress) { _ = try await fixture.turn("before-drain") }
        try await fixture.owner.quiesceForRuntimeRecovery(token, drainHostWork: {})
        await expectOwnerError(.runtimeRecoveryInProgress) { _ = try await fixture.turn("before-host-check") }
        try await fixture.owner.resumeAfterRuntimeRecovery(token)
        let fresh = try await fixture.turn()
        await expectOwnerError(.invalidTurn) { _ = try await fixture.owner.listTabs(turn: old) }
        _ = try await fixture.owner.listTabs(turn: fresh)
        await expectOwnerError(.invalidCandidate) {
            _ = try await fixture.owner.bind(turn: fresh, candidateToken: page.items[0].candidateToken)
        }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 1)
        XCTAssertEqual(counts.shutdowns, 0)
        XCTAssertEqual(counts.forbidden, 0)
        await fixture.owner.disconnect()
    }

    func testRuntimeRecoveryWaitsForLateAttachAndExactlyOneDetach() async throws {
        let fixture = try OwnerFixture(), gate = OwnerInventoryGate()
        let turn = try await fixture.turn()
        let page = try await fixture.owner.listTabs(turn: turn)
        await fixture.transport.onAttach { await gate.pause() }
        let attach = Task { try await fixture.owner.bind(turn: turn, candidateToken: page.items[0].candidateToken) }
        await gate.waitForArrival(1)
        let token = try fixture.owner.suspendForRuntimeRecovery()
        attach.cancel()
        let recovery = Task {
            try await fixture.owner.quiesceForRuntimeRecovery(token) { _ = await attach.result }
        }
        await fixture.owner.revoke(turn: turn)
        await expectOwnerError(.runtimeRecoveryInProgress) { _ = try await fixture.turn("pending-attach") }
        let whileAttaching = await fixture.transport.counts()
        XCTAssertEqual(whileAttaching.detaches, 0)
        await gate.resumeAll()
        try await recovery.value
        try await fixture.owner.resumeAfterRuntimeRecovery(token)
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 1)
        XCTAssertEqual(counts.shutdowns, 0)
        _ = try await fixture.turn("fresh")
        await fixture.owner.disconnect()
    }

    func testRuntimeRecoveryCannotForgetUndrainedOperations() async throws {
        let fixture = try OwnerFixture(), gate = OwnerInventoryGate()
        let turn = try await fixture.turn()
        await fixture.transport.onList { await gate.pause() }
        let inventory = Task { try await fixture.owner.listTabs(turn: turn) }
        await gate.waitForArrival(1)
        let token = try fixture.owner.suspendForRuntimeRecovery()
        await expectOwnerError(.runtimeRecoveryFailed) {
            try await fixture.owner.quiesceForRuntimeRecovery(token, drainHostWork: {})
        }
        await expectOwnerError(.disconnected) { _ = try await fixture.turn("not-reopened") }
        await gate.resumeAll()
        _ = await inventory.result
        await fixture.owner.disconnect()
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testRuntimeRecoveryTimeoutDoesNotWaitForeverForCancelledHostWork() async throws {
        let fixture = try OwnerFixture(), gate = OwnerInventoryGate()
        let token = try fixture.owner.suspendForRuntimeRecovery()
        let recovery = Task {
            try await fixture.owner.quiesceForRuntimeRecovery(token, timeout: .milliseconds(10)) {
                await gate.pause()
            }
        }
        await gate.waitForArrival(1)
        await expectOwnerError(.runtimeRecoveryFailed) { try await recovery.value }
        XCTAssertThrowsError(try fixture.consent.check())
        await expectOwnerError(.disconnected) { try await fixture.owner.resumeAfterRuntimeRecovery(token) }
        await gate.resumeAll()
        await fixture.owner.disconnect()
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testRuntimeRecoveryFailedDetachClosesInsteadOfReusingConnection() async throws {
        let fixture = try OwnerFixture()
        _ = try await fixture.observation(try await fixture.turn())
        await fixture.transport.failNextDetach()
        let token = try fixture.owner.suspendForRuntimeRecovery()
        await expectOwnerError(.runtimeRecoveryFailed) {
            try await fixture.owner.quiesceForRuntimeRecovery(token, drainHostWork: {})
        }
        await fixture.owner.disconnect()
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 1)
        XCTAssertEqual(counts.shutdowns, 1)
        XCTAssertEqual(counts.forbidden, 0)
    }

    func testExplicitDisconnectWhileRecoveryDrainsCannotBeReversedByLateCompletion() async throws {
        let fixture = try OwnerFixture(), gate = OwnerInventoryGate()
        let token = try fixture.owner.suspendForRuntimeRecovery()
        let recovery = Task {
            try await fixture.owner.quiesceForRuntimeRecovery(token) { await gate.pause() }
        }
        await gate.waitForArrival(1)
        await fixture.owner.disconnect()
        await gate.resumeAll()
        await expectOwnerError(.runtimeRecoveryFailed) { try await recovery.value }
        await expectOwnerError(.disconnected) { try await fixture.owner.resumeAfterRuntimeRecovery(token) }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testRuntimeRecoveryDoesNotRetainUnhealthyBrowserTransport() async throws {
        let fixture = try OwnerFixture()
        let token = try fixture.owner.suspendForRuntimeRecovery()
        await fixture.transport.breakConnection()
        await expectOwnerError(.runtimeRecoveryFailed) {
            try await fixture.owner.quiesceForRuntimeRecovery(token, drainHostWork: {})
        }
        await fixture.owner.disconnect()
        XCTAssertThrowsError(try fixture.consent.check())
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testRuntimeRecoveryCancellationFailsClosedWithoutRestoringOldLease() async throws {
        let fixture = try OwnerFixture(), gate = OwnerInventoryGate()
        let turn = try await fixture.turn()
        let token = try fixture.owner.suspendForRuntimeRecovery()
        let recovery = Task {
            try await fixture.owner.quiesceForRuntimeRecovery(token) { await gate.pause() }
        }
        await gate.waitForArrival(1)
        recovery.cancel()
        await expectOwnerError(.runtimeRecoveryFailed) { try await recovery.value }
        XCTAssertThrowsError(try turn.lifetime.check())
        XCTAssertThrowsError(try fixture.consent.check())
        await gate.resumeAll()
        await fixture.owner.disconnect()
    }

    func testRepeatedRuntimeRecoveriesRequireNewGenerationAndPreserveOneWire() async throws {
        let fixture = try OwnerFixture()
        var previous: UUID?
        for _ in 0..<5 {
            _ = try await fixture.observation(try await fixture.turn())
            let token = try fixture.owner.suspendForRuntimeRecovery()
            XCTAssertNotEqual(token, previous)
            XCTAssertEqual(try fixture.owner.suspendForRuntimeRecovery(), token)
            try await fixture.owner.quiesceForRuntimeRecovery(token, drainHostWork: {})
            if let previous {
                await expectOwnerError(.runtimeRecoveryFailed) {
                    try await fixture.owner.resumeAfterRuntimeRecovery(previous)
                }
            }
            try await fixture.owner.resumeAfterRuntimeRecovery(token)
            previous = token
        }
        let counts = await fixture.transport.counts()
        XCTAssertEqual(counts.detaches, 5)
        XCTAssertEqual(counts.shutdowns, 0)
        await fixture.owner.disconnect()
    }

    func testRevokedInflightInventoriesKeepBoundedSlotsUntilTheirRepliesArrive() async throws {
        let fixture = try OwnerFixture()
        let gate = OwnerInventoryGate()
        var attempts = [Task<BorrowedChromeInventoryPage, Error>]()
        for index in 0..<16 {
            let turn = try await fixture.turn("task-\(index)")
            await fixture.transport.onList { await gate.pause() }
            attempts.append(Task { try await fixture.owner.listTabs(turn: turn) })
            await gate.waitForArrival(index + 1)
            await fixture.owner.revoke(turn: turn)
        }
        await expectOwnerError(.capacityExceeded) { _ = try await fixture.turn("seventeenth") }
        await gate.resumeAll()
        for attempt in attempts {
            do { _ = try await attempt.value; XCTFail("Late inventory must not restore a revoked turn") }
            catch { XCTAssertEqual(error as? BorrowedChromeSessionOwnerError, .invalidTurn) }
        }
        let fresh = try await fixture.turn("after-completion")
        let page = try await fixture.owner.listTabs(turn: fresh)
        XCTAssertEqual(page.totalCount, 1)
        await fixture.owner.disconnect()
    }
}

private actor OwnerInventoryGate {
    private var arrivalCount = 0
    private var suspended = [CheckedContinuation<Void, Never>]()
    private var observers = [(Int, CheckedContinuation<Void, Never>)]()

    func pause() async {
        arrivalCount += 1
        let ready = observers.filter { $0.0 <= arrivalCount }
        observers.removeAll { $0.0 <= arrivalCount }
        for (_, continuation) in ready { continuation.resume() }
        await withCheckedContinuation { suspended.append($0) }
    }

    func waitForArrival(_ count: Int) async {
        guard arrivalCount < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func resumeAll() {
        let pending = suspended
        suspended.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private let ownerTestApplication = BorrowedChromeApplicationIdentity(
    processIdentifier: 42, bundleIdentifier: "com.google.Chrome",
    executableURL: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
)

private func ownerCandidate(_ index: Int, title: String = "Identical visible tab") -> BorrowedChromeTabCandidate {
    .init(targetID: "target-\(index)", title: title, url: URL(string: "https://example.com/fixture")!)
}

private struct OwnerFixture: Sendable {
    let owner: BorrowedChromeSessionOwner
    let transport: OwnerTestTransport
    let consent = ChromeDebuggingConsent(approvedByUser: true)

    init(count: Int = 1, title: String = "Identical visible tab") throws {
        transport = OwnerTestTransport(candidates: (0..<count).map { ownerCandidate($0, title: title) })
        owner = try BorrowedChromeSessionOwner(
            application: ownerTestApplication, transport: transport, consent: consent, verifyIdentity: {}
        )
    }

    func turn(_ taskKey: String = "task") async throws -> BorrowedChromeTurn {
        try await owner.beginTurn(taskKey: taskKey, turnID: "turn")
    }

    func observation(_ turn: BorrowedChromeTurn) async throws -> BrowserTabObservation {
        let page = try await owner.listTabs(turn: turn)
        let binding = try await owner.bind(turn: turn, candidateToken: page.items[0].candidateToken)
        return try await owner.snapshot(turn: turn, binding: binding)
    }
}

private actor OwnerTestTransport: BorrowedChromeSessionTransport {
    struct Counts: Sendable {
        let lists: Int
        let attaches: Int
        let detaches: Int
        let shutdowns: Int
        let forbidden: Int
        let mutations: Int
    }

    nonisolated let generation = UUID()
    private var candidates: [BorrowedChromeTabCandidate]
    private var targets = [String: BrowserTarget]()
    private var listCount = 0, attachCount = 0, shutdownCount = 0, forbiddenCount = 0, mutationCount = 0
    private var closed = false, detachFailure = false
    private var attachHook: (@Sendable () async throws -> Void)?
    private var observeHook: (@Sendable () async throws -> Void)?
    private var listHook: (@Sendable () async throws -> Void)?
    private(set) var detached = [BrowserTarget]()
    private(set) var text = ""

    init(candidates: [BorrowedChromeTabCandidate] = [ownerCandidate(0)]) { self.candidates = candidates }
    func setCandidates(_ candidates: [BorrowedChromeTabCandidate]) { self.candidates = candidates }
    func onAttach(_ hook: @escaping @Sendable () async throws -> Void) { attachHook = hook }
    func onObserve(_ hook: @escaping @Sendable () async throws -> Void) { observeHook = hook }
    func onList(_ hook: @escaping @Sendable () async throws -> Void) { listHook = hook }
    func breakConnection() { closed = true }
    func failNextDetach() { detachFailure = true }

    func counts() -> Counts {
        Counts(lists: listCount, attaches: attachCount, detaches: detached.count,
               shutdowns: shutdownCount, forbidden: forbiddenCount, mutations: mutationCount)
    }

    func validateConnection() throws {
        guard !closed else { throw BrowserTabBrokerError.browserGenerationChanged }
    }

    func listCandidates() async throws -> [BorrowedChromeTabCandidate] {
        try validateConnection()
        listCount += 1
        let hook = listHook
        listHook = nil
        try await hook?()
        return candidates
    }

    func attach(targetID: String) async throws -> BrowserTarget {
        try validateConnection()
        guard let candidate = candidates.first(where: { $0.targetID == targetID }) else {
            throw BrowserTabBrokerError.targetClosed
        }
        attachCount += 1
        let target = BrowserTarget(targetID: targetID, title: candidate.title, url: candidate.url,
            attachedSession: .init(connectionGeneration: generation, sessionID: UUID().uuidString, incarnation: UUID()))
        targets[targetID] = target
        let hook = attachHook
        attachHook = nil
        try await hook?()
        return target
    }

    func target(id: String) throws -> BrowserTarget? {
        try validateConnection()
        return targets[id]
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try validateConnection()
        let hook = observeHook
        observeHook = nil
        try await hook?()
        return BrowserDocumentObservation(loaderID: "loader", title: "Fixture", url: target.url, nodes: [
            .init(backendNodeID: 1, role: "button", name: "Increment", value: nil,
                  isDisabled: false, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 2, role: "textbox", name: "Text", value: text,
                  isDisabled: false, isReadOnly: false, isIgnored: false)
        ])
    }

    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
               permit: BrowserMutationPermit) throws {
        try validateConnection()
        try permit.commit { mutationCount += 1 }
    }

    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) throws {
        try validateConnection()
        try permit.commit { self.text = text; mutationCount += 1 }
    }

    func detach(target: BrowserTarget) throws {
        try validateConnection()
        guard targets[target.targetID]?.attachedSession == target.attachedSession else {
            throw BrowserTabBrokerError.targetReplaced
        }
        detached.append(target)
        if detachFailure { detachFailure = false; throw BrowserTabBrokerError.browserUnavailable("detach failed") }
        targets.removeValue(forKey: target.targetID)
    }

    func shutdown() {
        closed = true
        shutdownCount += 1
        targets.removeAll()
    }

    func createTarget(url: URL) throws -> BrowserTarget {
        forbiddenCount += 1
        throw BrowserTabBrokerError.ownershipMismatch
    }
    func activateTarget(id: String) throws {
        forbiddenCount += 1
        throw BrowserTabBrokerError.ownershipMismatch
    }
    func closeTarget(target: BrowserTarget) throws {
        forbiddenCount += 1
        throw BrowserTabBrokerError.ownershipMismatch
    }
}

private func expectOwnerError(
    _ expected: BorrowedChromeSessionOwnerError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void
) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? BorrowedChromeSessionOwnerError, expected, file: file, line: line) }
}

private func expectOwnerBrokerError(
    _ expected: BrowserTabBrokerError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void
) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? BrowserTabBrokerError, expected, file: file, line: line) }
}
