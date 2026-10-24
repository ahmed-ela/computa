import XCTest
import Darwin
@testable import Computa

#if DEBUG
/// Intercepts every request of this injected client. The engine-to-app request
/// still uses the real loopback API admission and Core steer implementation.
private final class SteerProviderProtocol: URLProtocol, @unchecked Sendable {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String: [Data]] = [:]
        func register(_ host: String) { lock.lock(); defer { lock.unlock() }; requests[host] = [] }
        func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; requests.removeValue(forKey: host) }
        func append(_ body: Data, host: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard requests[host] != nil else { return false }
            requests[host, default: []].append(body); return true
        }
        func snapshot(_ host: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return requests[host] ?? [] }
    }
    private static let store = Store()
    static func register(_ host: String) { store.register(host) }
    static func remove(_ host: String) { store.remove(host) }
    static func requests(_ host: String) -> [Data] { store.snapshot(host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host, request.httpMethod == "POST",
              url.path == "/v1/chat/completions" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        guard Self.store.append(body, host: host),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = Data(#"{"id":"steer-fixture","model":"fixture-model","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"fixture response"}}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct SteerCredentials: APIProviderCredentials {
    func key(for providerID: String) throws -> String? { "inert-test-credential" }
    func save(_ key: String, for providerID: String) throws { XCTFail("Steering must not modify credentials.") }
    func remove(for providerID: String) throws { XCTFail("Steering must not modify credentials.") }
}

@MainActor
final class RuntimeAPISteerTests: XCTestCase {
    @MainActor
    private final class Harness {
        let root: URL
        let host: String
        let taskID = UUID().uuidString
        let runtime: CodexAppServerRuntime
        let server: APIModelServer
        let modelID: String
        let original = "  Inspect only https://example.invalid.\nDo not send messages or change settings.  "

        init(mode: String = "accepted") async throws {
            try XCTSkipUnless((try? FixtureBunExecutable.resolve()) != nil,
                "The deterministic App Server fixture requires the installed Bun executable.")
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                .appendingPathComponent("ComputaAPISteer-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data(mode.utf8).write(to: root.appendingPathComponent("mode.txt"))
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/APISteerAppServer.ts")
            let fixture = root.appendingPathComponent("fixture.ts")
            try FileManager.default.copyItem(at: source, to: fixture)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            host = UUID().uuidString.lowercased() + ".steer-fixture.invalid"
            SteerProviderProtocol.register(host)
            let clientConfiguration = URLSessionConfiguration.ephemeral
            clientConfiguration.protocolClasses = [SteerProviderProtocol.self]
            server = APIModelServer(credentials: SteerCredentials(),
                client: APIProviderHTTPClient(configuration: clientConfiguration),
                capsules: try .init(key: Data(repeating: 3, count: 32)))
            let provider = APIProviderDefinition(id: "steer-fixture", name: "Steer fixture",
                baseURL: URL(string: "https://" + host + "/v1")!, wireAPI: .chatCompletions,
                models: [.init(id: "fixture-model", name: "Fixture")])
            modelID = APIProviderCatalog.appModelID(providerID: provider.id, modelID: provider.models[0].id)
            var configuration = CodexAppServerRuntime.Configuration.localQwen
            configuration.executable = .fixture(path: fixture.path)
            configuration.model = modelID
            configuration.workspacePath = root.path
            configuration.codexHomePath = root.path
            configuration.apiModelServerForTesting = server
            runtime = CodexAppServerRuntime(configuration: configuration)
            do {
                try await runtime.configureAPIProviders([provider])
                _ = try await runtime.loadTasks()
                try await runtime.submit(prompt: original, toTaskID: taskID, modelID: modelID, accessMode: .fullAccess)
                try await waitForFile("initial-response.json")
                XCTAssertEqual(try responseStatus("initial"), 200)
                XCTAssertEqual(requests.count, 1)
            } catch {
                await close()
                throw error
            }
        }

        var requests: [Data] { SteerProviderProtocol.requests(host) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        func release(_ index: Int) throws { try Data().write(to: file("release-\(index)")) }
        func messages(_ index: Int) throws -> [[String: Any]] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[index]) as? [String: Any])
            return try XCTUnwrap(body["messages"] as? [[String: Any]])
        }
        func responseStatus(_ name: String) throws -> Int {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file(name + "-response.json"))) as? [String: Any])
            return try XCTUnwrap(value["status"] as? Int)
        }
        func waitUntil(_ predicate: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if let error = try? String(contentsOf: file("fixture-error.txt"), encoding: .utf8) {
                    throw NSError(domain: "APISteerFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
                }
                if try await predicate() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw NSError(domain: "APISteerFixture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for deterministic steer fixture evidence."])
        }
        func waitForFile(_ name: String) async throws {
            try await waitUntil { FileManager.default.fileExists(atPath: self.file(name).path) }
        }
        func waitForAdmission() async throws {
            try await waitUntil { await self.server.userInputAdmissionIsWaitingForTesting(taskID: self.taskID) }
        }
        func close() async {
            _ = await runtime.shutdown()
            SteerProviderProtocol.remove(host)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSteerGatesNextInferenceBeforeAcknowledgmentAndPreservesOrderedUserInputs() async throws {
        let harness = try await Harness()
        do {
            let steers = ["  Only inspect the attachment title.\nKeep this read-only.  ",
                          "Actually report just the title length; preserve the earlier restrictions."]
            for (offset, steer) in steers.enumerated() {
                let index = offset + 1
                let pending = Task { try await harness.runtime.steer(prompt: steer, toTaskID: harness.taskID) }
                try await harness.waitForAdmission()
                XCTAssertEqual(harness.requests.count, index,
                    "Inference is already waiting at API admission, before the engine acknowledges this steer.")
                try harness.release(index)
                try await pending.value
                try await harness.waitForFile("steer-\(index)-finished")
                XCTAssertEqual(try harness.responseStatus("steer-\(index)"), 200)
                XCTAssertEqual(harness.requests.count, index + 1)
                let messages = try harness.messages(index)
                let reminders = Array(messages.suffix(index + 1))
                XCTAssertEqual(reminders.compactMap { $0["role"] as? String }, Array(repeating: "user", count: index + 1))
                XCTAssertEqual(reminders.compactMap { $0["content"] as? String }, [harness.original] + Array(steers.prefix(index)))
                XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("Historical summary: latest task was maintenance.") == true },
                    "Raw engine history must remain intact.")
                let developer = messages.filter { $0["role"] as? String == "developer" }.compactMap { $0["content"] as? String }.joined()
                XCTAssertFalse(developer.contains(steer), "User steering must never acquire developer authority.")
                let received = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                    harness.file("steer-\(index)-received.json"))) as? [String: Any])
                XCTAssertEqual((received["input"] as? [[String: String]])?.first?["text"], steer)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.file("interrupts.json").path))
            await harness.close()
        } catch { await harness.close(); throw error }
    }

    func testUncertainSteerAcknowledgmentRetiresContextWithoutDispatchingStaleReminder() async throws {
        let harness = try await Harness(mode: "malformed-ack")
        do {
            let pending = Task { try await harness.runtime.steer(prompt: "Do not continue; only report the current status.", toTaskID: harness.taskID) }
            try await harness.waitForAdmission()
            XCTAssertEqual(harness.requests.count, 1)
            try harness.release(1)
            do { try await pending.value; XCTFail("An acknowledgment for another turn must fail.") }
            catch { XCTAssertEqual(error as? AppServerSteerRequest.ValidationError, .invalidAcknowledgment) }
            try await harness.waitForFile("steer-1-finished")
            try await harness.waitForFile("after-interrupt-response.json")
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("steer-1"), 400)
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("after-interrupt"), 400)
            XCTAssertEqual(harness.requests.count, 1, "Neither the waiting request nor a later request may reach the provider with stale inputs.")
            let interrupts = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.file("interrupts.json")), options: [.fragmentsAllowed]) as? Int
            XCTAssertEqual(interrupts, 1)
            await harness.close()
        } catch { await harness.close(); throw error }
    }

    func testStopDuringPendingSteerRejectsLateAcknowledgmentWithoutRevivingContext() async throws {
        let harness = try await Harness()
        do {
            let pending = Task { try await harness.runtime.steer(prompt: "Read the title only.", toTaskID: harness.taskID) }
            try await harness.waitForAdmission()
            try await harness.runtime.interrupt(taskID: harness.taskID)
            try harness.release(1)
            do { try await pending.value; XCTFail("Stop must invalidate even a matching late acknowledgment.") } catch { }
            try await harness.waitForFile("steer-1-finished")
            try await harness.waitForFile("after-interrupt-response.json")
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("steer-1"), 400)
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("after-interrupt"), 400)
            XCTAssertEqual(harness.requests.count, 1)
            let interrupts = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.file("interrupts.json")), options: [.fragmentsAllowed]) as? Int
            XCTAssertEqual(interrupts, 1, "A late steer acknowledgment must not interrupt a retired or later turn again.")
            await harness.close()
        } catch { await harness.close(); throw error }
    }

    func testLostSteerAcknowledgmentTimesOutAndLaterReplyCannotRestoreContext() async throws {
        let harness = try await Harness(mode: "lost-ack")
        do {
            let started = ContinuousClock.now
            let pending = Task { try await harness.runtime.steer(prompt: "Only report status; do not take further actions.", toTaskID: harness.taskID) }
            try await harness.waitForAdmission()
            try harness.release(1)
            do { try await pending.value; XCTFail("A lost acknowledgment must not leave the native steer pending indefinitely.") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Runtime request timed out: turn/steer"), error.localizedDescription) }
            XCTAssertLessThan(started.duration(to: .now), .seconds(9), "The 5-second steer bound plus cleanup must remain finite.")
            try await harness.waitForFile("after-interrupt-response.json")
            try await harness.waitForFile("after-late-ack-response.json")
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("steer-1"), 400)
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("after-interrupt"), 400)
            XCTAssertGreaterThanOrEqual(try harness.responseStatus("after-late-ack"), 400)
            XCTAssertEqual(harness.requests.count, 1, "The late acknowledgment cannot reopen inference or dispatch stale user instructions.")
            let interrupts = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.file("interrupts.json")), options: [.fragmentsAllowed]) as? Int
            XCTAssertEqual(interrupts, 1)
            await harness.close()
        } catch { await harness.close(); throw error }
    }
}
#endif
