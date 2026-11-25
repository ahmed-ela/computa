import Foundation
import XCTest
@testable import Computa

final class PopupPinNavigationTests: XCTestCase {
    func testRequiresACommittedSuccessfulGetAndPreservesOrdinaryPaths() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/docs/login?client_id=42"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        var navigation = PopupPinNavigation.pending
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        navigation.request(request)
        navigation.receive(response)
        navigation.commit(url)
        XCTAssertNil(navigation.address(url))
        request.httpMethod = "GET"
        navigation.request(request)
        navigation.receive(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
        navigation.commit(url)
        XCTAssertNil(navigation.address(url))
        navigation.request(request)
        navigation.receive(response)
        XCTAssertNil(navigation.address(url))
        navigation.commit(url)
        let article = try XCTUnwrap(URL(string: "https://example.test/read?chapter=2#section"))
        XCTAssertEqual(navigation.address(article), article)
        XCTAssertNil(navigation.address(URL(string: "https://other.test/read")))
    }

    func testAuthenticationHopsCannotBecomePinsAfterALandingRedirect() throws {
        let landing = try XCTUnwrap(URL(string: "https://example.test/finished"))
        let ok = try XCTUnwrap(HTTPURLResponse(url: landing, statusCode: 200, httpVersion: nil, headerFields: nil))
        for suffix in ["/oauth2/authorize", "/signin/choose", "/auth/callback?code=abc", "/opaque-return?code=abc", "/?response_type=code",
                       "/?SAMLRequest=abc", "/#access_token=abc?fragment", "/#/callback?code=xyz&state=abc"] {
            var navigation = PopupPinNavigation.pending
            let url = try XCTUnwrap(URL(string: "https://example.test" + suffix))
            navigation.request(URLRequest(url: url))
            navigation.request(URLRequest(url: landing))
            navigation.receive(ok)
            navigation.commit(landing)
            XCTAssertNil(navigation.address(landing), suffix)
        }
    }
}
