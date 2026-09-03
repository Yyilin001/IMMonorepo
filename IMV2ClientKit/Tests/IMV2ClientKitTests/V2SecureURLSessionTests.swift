import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import IMV2ClientKit
import Testing

@Suite("V2 secure URL session")
struct V2SecureURLSessionTests {
    @Test("sensitive transports do not share cookies, credentials, or cache")
    func isolatesAmbientHTTPState() {
        let session = V2SecureURLSession.make()
        let configuration = session.configuration
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(session.delegate != nil)
        session.invalidateAndCancel()
    }

    @Test("account requests reuse one pool and provider bytes remain isolated")
    func sharesOnlyWithinCredentialBoundary() {
        #expect(V2SecureURLSession.account === V2SecureURLSession.account)
        #expect(V2SecureURLSession.account !== V2SecureURLSession.mediaProvider)
        for session in [V2SecureURLSession.account, V2SecureURLSession.mediaProvider] {
            #expect(session.configuration.httpCookieStorage == nil)
            #expect(session.configuration.urlCredentialStorage == nil)
            #expect(session.configuration.urlCache == nil)
        }
    }

    @Test("JSON contract accepts parameters and structured JSON suffixes only")
    func validatesJSONContentType() throws {
        let url = try #require(URL(string: "https://account.invalid/response"))
        func response(_ contentType: String?) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: contentType.map { ["Content-Type": $0] }
            ))
        }
        #expect(V2HTTPContract.isJSON(try response("application/json; charset=utf-8")))
        #expect(V2HTTPContract.isJSON(try response("application/problem+json")))
        #expect(!V2HTTPContract.isJSON(try response("text/html")))
        #expect(!V2HTTPContract.isJSON(try response(nil)))
    }

    @Test("redirect policy never replays a sensitive request")
    func rejectsRedirects() throws {
        let sourceURL = try #require(URL(string: "https://account.invalid/login"))
        let targetURL = try #require(URL(string: "https://redirect.invalid/capture"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: sourceURL)
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": targetURL.absoluteString]
        ))
        var callbackWasCalled = false
        var followedRequest: URLRequest?

        V2RejectingRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: targetURL)
        ) { request in
            callbackWasCalled = true
            followedRequest = request
        }

        #expect(callbackWasCalled)
        #expect(followedRequest == nil)
    }
}
