import Foundation
import XCTest
@testable import Mactopus

/// Real URLSession/WebSocket transport against an explicit loopback synthetic
/// peer. Not evidence of Chrome permissions, DOM outcomes, focus or model use.
final class BrowserCDPLoopbackLiveTests: XCTestCase {
    func testNativeWebSocketSessionRoundTripAndRedirectRefusal() async throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["HEYDASH_CDP_LOOPBACK_ENDPOINT"] ?? env["TEST_RUNNER_HEYDASH_CDP_LOOPBACK_ENDPOINT"]
        try XCTSkipUnless(raw != nil, "Start BrowserCDPLoopback.ts and supply its fresh explicit endpoint.")
        let endpoint = try XCTUnwrap(URL(string: XCTUnwrap(raw)))
        let wire = try URLSessionBrowserCDPWire(endpoint: endpoint)
        let connection = BrowserCDPConnection(wire: wire)
        let clock = ContinuousClock(), started = clock.now
        let attached = try await connection.command(
            method: "Target.attachToTarget", params: Data(#"{"targetId":"loopback-target","flatten":true}"#.utf8)
        )
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: attached) as? [String: Any])
        XCTAssertEqual(result["sessionId"] as? String, "loopback-session")
        let bytes = try await connection.command(
            method: "Runtime.callFunctionOn", params: Data(#"{"synthetic":true}"#.utf8),
            sessionID: "loopback-session", permit: BrowserMutationPermit()
        )
        let call = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual((call["result"] as? [String: Any])?["value"] as? String, "HDé7")
        var events = connection.events.makeAsyncIterator()
        let event = try await events.next()
        XCTAssertEqual(event?.method, "Runtime.syntheticEvent")
        XCTAssertEqual(event?.sessionID, "loopback-session")
        let elapsed = started.duration(to: clock.now)
        await connection.close()

        var components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        components.path = "/devtools/browser/redirect"
        let redirected = BrowserCDPConnection(wire: try URLSessionBrowserCDPWire(endpoint: XCTUnwrap(components.url)))
        do {
            _ = try await redirected.command(method: "Target.getTargets")
            XCTFail("A validated loopback endpoint may not redirect to another endpoint.")
        } catch let error as BrowserCDPConnectionError {
            XCTAssertEqual(error, .transportFailed)
        }
        await redirected.close()
        components.scheme = "http"
        components.path = "/state"
        let (stateData, _) = try await URLSession.shared.data(from: XCTUnwrap(components.url))
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["opened"] as? Int, 1)
        XCTAssertEqual(state["redirectDestinationHits"] as? Int, 0)
        let requests = try XCTUnwrap(state["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["Target.attachToTarget", "Runtime.callFunctionOn"])
        print("HEYDASH_CDP_WIRE_OK synthetic=true requests=2 unicode=HDé7 redirect_followed=false roundtrip=\(elapsed)")
    }
}
