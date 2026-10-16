import Darwin
import Foundation
import XCTest
@testable import Computa

@MainActor final class ChatGPTCookieMaintenanceDiagnosticTests: XCTestCase {
    func testInspectIsSingleUseReadOnlyAndRetainsOnlyAggregates() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let request = try fixture.arm("inspect")
        let diagnostic = fixture.diagnostic(store)
        let result = await diagnostic.runIfArmed()
        XCTAssertEqual(result, .inspected, "Failure phase: \(diagnostic.lastFailurePhase?.rawValue ?? "none")"); XCTAssertEqual(store.deletes, 0); XCTAssertEqual(store.sets, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("arm.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("consumed-" + request.uuidString.lowercased() + ".json").path))
        let text = try String(contentsOf: fixture.receipt("inspect", request), encoding: .utf8)
        for secret in ["PRIVATE", "conv_key_", "history_off_", fixture.conversation.uuidString.lowercased()] { XCTAssertFalse(text.contains(secret)) }
        let counts = try fixture.counts(request)
        XCTAssertEqual(counts["cookieCount"] as? Int, 6); XCTAssertEqual(counts["selectedCount"] as? Int, 1)
        let second = await fixture.diagnostic(store).runIfArmed()
        XCTAssertEqual(second, .noArm); XCTAssertEqual(store.reads, 1)
    }

    func testArchiveRoundTripRefusesChangedTargetAndPreservesCurrentAuthAndProtectedKeys() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let inspect = try fixture.arm("inspect")
        let inspected = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(inspected, .inspected)
        let quarantine = try fixture.arm("quarantine", inspect: inspect, counts: fixture.counts(inspect))
        let quarantineDiagnostic = fixture.diagnostic(store)
        let quarantined = await quarantineDiagnostic.runIfArmed()
        XCTAssertEqual(quarantined, .quarantined, "Failure phase: \(quarantineDiagnostic.lastFailurePhase?.rawValue ?? "none")")
        XCTAssertEqual(store.deletes, 1); XCTAssertEqual(store.cookies.count, 5)
        XCTAssertEqual(store.cookies.filter { $0.name.hasPrefix("history_off_") }.count, 2)
        XCTAssertNotNil(store.cookies.first { $0.name == "conv_key_" + fixture.protected.uuidString.lowercased() })
        let archive = fixture.directory.appendingPathComponent("archives/" + quarantine.uuidString.lowercased() + "/cookies.archive")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store.replace(try fixture.cookie("auth", "PRIVATE_ROTATED_AUTH"))
        store.replace(try fixture.cookie("conv_key_" + fixture.conversation.uuidString.lowercased(), "PRIVATE_NEW_KEY"))
        _ = try fixture.arm("restore", archive: quarantine)
        let conflict = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(conflict, .refused)
        XCTAssertEqual(store.sets, 0)
        store.cookies.removeAll { $0.name == "conv_key_" + fixture.conversation.uuidString.lowercased() }
        _ = try fixture.arm("restore", archive: quarantine)
        let restored = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(restored, .restored)
        XCTAssertEqual(store.sets, 1)
        XCTAssertEqual(store.cookies.first { $0.name == "auth" }?.value, "PRIVATE_ROTATED_AUTH")
        let original = try XCTUnwrap(store.cookies.first { $0.name == "conv_key_" + fixture.conversation.uuidString.lowercased() })
        XCTAssertTrue(original.isHTTPOnly); XCTAssertTrue(original.isSecure)
        XCTAssertEqual(original.expiresDate, fixture.expiry)
        _ = try fixture.arm("restore", archive: quarantine)
        let again = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(again, .restored)
        XCTAssertEqual(store.sets, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testQuarantineRequiresPositiveInspectAndFreshExactCountsBeforeArchiveOrWrites() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let inspect = try fixture.arm("inspect")
        let inspected = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(inspected, .inspected)
        let counts = try fixture.counts(inspect)
        store.replace(try fixture.cookie("new_other", "PRIVATE_NEW_STATE"))
        _ = try fixture.arm("quarantine", inspect: inspect, counts: counts)
        let result = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(result, .refused)
        XCTAssertEqual(store.deletes, 0); XCTAssertEqual(store.sets, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("archives").path))
        _ = try fixture.arm("quarantine", inspect: UUID(), counts: counts.merging(["cookieCount": 7]) { _, new in new })
        let missing = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(missing, .refused)
        XCTAssertEqual(store.deletes, 0)
    }

    func testInvalidPrivateArmScopeExpiryPermissionsAndAmbiguityNeverReadStore() async throws {
        for mode in ["expired", "long", "profile", "permission", "duplicate"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let store = try fixture.store()
            var object = fixture.armObject("inspect", request: UUID())
            if mode == "expired" { object["expiresAt"] = fixture.timestamp(fixture.now.addingTimeInterval(-1)) }
            if mode == "long" { object["expiresAt"] = fixture.timestamp(fixture.now.addingTimeInterval(601)) }
            if mode == "profile" { object["profileID"] = UUID().uuidString.lowercased() }
            var data = try JSONSerialization.data(withJSONObject: object)
            if mode == "duplicate" { data = Data(("{\"mode\":\"inspect\"," + String(decoding: data, as: UTF8.self).dropFirst()).utf8) }
            try fixture.writeArm(data, permissions: mode == "permission" ? 0o644 : 0o600)
            let result = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(result, .refused, mode)
            XCTAssertEqual(store.reads, 0, mode); XCTAssertEqual(store.deletes, 0, mode)
        }
    }

    func testSymlinkAncestorCannotClaimArmOrReadStore() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try fixture.arm("inspect")
        let alias = fixture.home.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        let diagnostic = ChatGPTCookieMaintenanceDiagnostic(codexHome: alias, profileID: fixture.profile, store: store,
            isCurrentExclusive: { true }, protectedIDs: { [] }, contextIdentityMatchesExpected: { true }, now: { fixture.now })
        let outcome = await diagnostic.runIfArmed()
        XCTAssertEqual(outcome, .refused); XCTAssertEqual(diagnostic.lastFailurePhase, .armDirectory)
        XCTAssertEqual(store.reads, 0); XCTAssertEqual(store.deletes, 0); XCTAssertEqual(store.sets, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("arm.json").path))
    }

    func testQuarantineRejectsFalseAndNonBooleanPriorBundleAuthority() async throws {
        for invalid in [false as Any, "true" as Any] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let store = try fixture.store(), inspect = try fixture.arm("inspect")
            let inspected = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(inspected, .inspected)
            let path = fixture.receipt("inspect", inspect)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            object["bundleIdentifierMatchesExpected"] = invalid
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            _ = try fixture.arm("quarantine", inspect: inspect, counts: fixture.counts(inspect))
            let result = await fixture.diagnostic(store).runIfArmed(); XCTAssertEqual(result, .refused)
            XCTAssertEqual(store.deletes, 0); XCTAssertEqual(store.sets, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("archives").path))
        }
    }

    func testRevokedLeaseAfterReadDispatchCannotMutateOrPersistSuccess() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store(); store.holdReads = true
        let request = try fixture.arm("inspect")
        let current = LeaseFlag()
        let diagnostic = fixture.diagnostic(store, current: { current.value })
        let task = Task { @MainActor in await diagnostic.runIfArmed() }
        await waitUntil { !store.pendingReads.isEmpty }
        current.value = false; store.releaseReads()
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused); XCTAssertFalse(diagnostic.callbackInFlight)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt("inspect", request).path))
        XCTAssertEqual(store.deletes, 0)
    }

    func testDeleteDeadlineKeepsOperationHeldUntilActualCallbackAndStopsBatch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        // Unprotect the second pair so a timeout on the first deletion must not
        // dispatch the next one. No real cookie store participates in this test.
        let inspect = try fixture.arm("inspect")
        let inspected = await fixture.diagnostic(store, protection: []).runIfArmed(); XCTAssertEqual(inspected, .inspected)
        let request = try fixture.arm("quarantine", inspect: inspect, counts: fixture.counts(inspect))
        store.holdDeletes = true
        let diagnostic = fixture.diagnostic(store, protection: [], deadline: .milliseconds(20))
        var finished = false
        let task = Task { @MainActor in let value = await diagnostic.runIfArmed(); finished = true; return value }
        await waitUntil { !store.pendingDeletes.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished); XCTAssertTrue(diagnostic.callbackInFlight); XCTAssertTrue(diagnostic.callbackTimedOut)
        XCTAssertEqual(store.deletes, 1)
        store.releaseDeletes()
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused); XCTAssertTrue(finished); XCTAssertFalse(diagnostic.callbackInFlight)
        XCTAssertEqual(diagnostic.issuedMutations, 1); XCTAssertEqual(diagnostic.settledMutations, 1)
        XCTAssertEqual(store.deletes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("archives/" + request.uuidString.lowercased() + "/cookies.archive").path))
    }

    func testLateSynchronousCompletionCannotBeatUnscheduledDeadlineTimer() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try fixture.arm("inspect")
        store.synchronousReadDelayMicroseconds = 40_000
        let diagnostic = fixture.diagnostic(store, deadline: .milliseconds(10))
        let result = await diagnostic.runIfArmed()
        XCTAssertEqual(result, .refused); XCTAssertTrue(diagnostic.callbackTimedOut)
        XCTAssertFalse(diagnostic.callbackInFlight); XCTAssertEqual(store.deletes, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("The local fake cookie callback was not dispatched")
    }
}

@MainActor private final class Fixture {
    let home: URL, directory: URL, profile = UUID()
    // A fixed representable instant keeps this synthetic clock consistent with
    // the receipt's canonical millisecond timestamp without relaxing its gate.
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let conversation = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let protected = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    var expiry: Date { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 3_600) }
    init() throws {
        // Foundation may retain macOS's /var alias here. The production
        // no-follow boundary requires the real existing temporary root.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        home = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("cookie-maintenance-test-" + UUID().uuidString, isDirectory: true)
        directory = ChatGPTCookieMaintenanceDiagnostic.directory(codexHome: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func diagnostic(_ store: FakeStore, current: @escaping @MainActor () -> Bool = { true }, protection: Set<UUID>? = nil,
                    deadline: Duration = .seconds(5)) -> ChatGPTCookieMaintenanceDiagnostic {
        ChatGPTCookieMaintenanceDiagnostic(codexHome: home, profileID: profile, store: store, isCurrentExclusive: current,
            protectedIDs: { protection ?? [self.protected] }, contextIdentityMatchesExpected: { true },
            now: { self.now }, callbackDeadline: deadline)
    }
    func store() throws -> FakeStore {
        FakeStore(try [cookie("conv_key_" + conversation.uuidString.lowercased(), "PRIVATE_ENCRYPTION_KEY", persistent: true),
            cookie("history_off_" + conversation.uuidString.lowercased(), "1", persistent: true),
            cookie("conv_key_00000000-0000-4000-8000-000000000002", "PRIVATE_UNPAIRED"), cookie("auth", "PRIVATE_AUTH"),
            cookie("conv_key_" + protected.uuidString.lowercased(), "PRIVATE_PROTECTED"), cookie("history_off_" + protected.uuidString.lowercased(), "1")])
    }
    func cookie(_ name: String, _ value: String, persistent: Bool = false) throws -> HTTPCookie {
        if persistent {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": name + "=" + value + "; Path=/; Secure; HttpOnly; Expires=" + formatter.string(from: expiry)], for: URL(string: "https://chatgpt.com/")!).first)
        }
        return try XCTUnwrap(HTTPCookie(properties: [.domain: "chatgpt.com", .path: "/", .name: name, .value: value]))
    }
    func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return formatter.string(from: date)
    }
    func armObject(_ mode: String, request: UUID) -> [String: Any] {
        ["purpose": "cookie_maintenance_v1", "mode": mode, "requestID": request.uuidString.lowercased(),
            "profileID": profile.uuidString.lowercased(), "expiresAt": timestamp(now.addingTimeInterval(60))]
    }
    func arm(_ mode: String, inspect: UUID? = nil, counts: [String: Any]? = nil, archive: UUID? = nil) throws -> UUID {
        let request = UUID(); var object = armObject(mode, request: request)
        if let inspect { object["inspectRequestID"] = inspect.uuidString.lowercased() }
        if let counts { object["expectedCounts"] = counts }
        if let archive { object["archiveRequestID"] = archive.uuidString.lowercased() }
        try writeArm(JSONSerialization.data(withJSONObject: object), permissions: 0o600); return request
    }
    func writeArm(_ data: Data, permissions: Int) throws {
        let path = directory.appendingPathComponent("arm.json")
        try data.write(to: path); try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path.path)
    }
    func receipt(_ mode: String, _ request: UUID) -> URL { directory.appendingPathComponent(mode + "-" + request.uuidString.lowercased() + ".json") }
    func counts(_ request: UUID) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt("inspect", request))) as? [String: Any])
        return try XCTUnwrap(object["counts"] as? [String: Any])
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
}

@MainActor private final class LeaseFlag { var value = true }

@MainActor private final class FakeStore: ChatGPTCookieMaintenanceStore {
    var cookies: [HTTPCookie]
    var reads = 0, deletes = 0, sets = 0, holdReads = false, holdDeletes = false
    var synchronousReadDelayMicroseconds: useconds_t = 0
    var pendingReads: [@MainActor @Sendable ([HTTPCookie]) -> Void] = []
    var pendingDeletes: [@MainActor @Sendable () -> Void] = []
    init(_ cookies: [HTTPCookie]) { self.cookies = cookies }
    func read(_ completion: @escaping @MainActor @Sendable ([HTTPCookie]) -> Void) {
        reads += 1
        if synchronousReadDelayMicroseconds > 0 { usleep(synchronousReadDelayMicroseconds) }
        if holdReads { pendingReads.append(completion) } else { completion(cookies) }
    }
    func delete(_ cookie: HTTPCookie, completion: @escaping @MainActor @Sendable () -> Void) {
        deletes += 1
        let action: @MainActor @Sendable () -> Void = { self.cookies.removeAll { Self.same($0, cookie) }; completion() }
        if holdDeletes { pendingDeletes.append(action) } else { action() }
    }
    func set(_ cookie: HTTPCookie, completion: @escaping @MainActor @Sendable () -> Void) { sets += 1; replace(cookie); completion() }
    func replace(_ cookie: HTTPCookie) { cookies.removeAll { Self.same($0, cookie) }; cookies.append(cookie) }
    func releaseReads() { let values = pendingReads; pendingReads = []; values.forEach { $0(cookies) } }
    func releaseDeletes() { let values = pendingDeletes; pendingDeletes = []; values.forEach { $0() } }
    private static func same(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool { a.name == b.name && a.domain == b.domain && a.path == b.path }
}
