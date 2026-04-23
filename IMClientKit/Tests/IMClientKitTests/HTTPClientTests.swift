import Foundation
import Testing
@testable import IMClientKit

private struct TestMessage: Codable, Equatable, Sendable, APIResponseBody {
    let message: String
}

private struct ProtectedMessageEndpoint: AuthorizedEndpoint {
    typealias Response = TestMessage

    let baseRequestSpec = HTTPRequestSpec(path: "protected")
}

private struct PublicMessageEndpoint: Endpoint {
    typealias Response = TestMessage

    let requestSpec = HTTPRequestSpec(path: "public")
}

private struct CachedPublicMessageEndpoint: Endpoint {
    typealias Response = TestMessage

    let requestSpec = HTTPRequestSpec(path: "cached")
    let cachePolicy: RequestCachePolicy = .returnCacheDataDontLoad
}

@MainActor
struct HTTPClientTests {
    @Test func authorizedEndpointWithoutTokenFailsBeforeSending() async throws {
        let transport = MockHTTPTransport { _ in
            Issue.record("缺少 token 的受保护请求不应该进入 transport。")
            return HTTPFixtures.response(statusCode: 200)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.execute(ProtectedMessageEndpoint())
            Issue.record("预期抛出 unauthorized。")
        } catch let error as APIError {
            if case .unauthorized(let reason) = error {
                #expect(reason == "缺少访问令牌，请重新登录。")
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }

        let requests = await transport.requests()
        #expect(requests.isEmpty)
    }

    @Test func authorizedRequestInjectsBearerToken() async throws {
        let transport = MockHTTPTransport { request in
            let body = try HTTPFixtures.jsonBody(TestMessage(message: "ok"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return HTTPFixtures.response(statusCode: 200, body: body)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        let response = try await client.execute(ProtectedMessageEndpoint(), bearerToken: "test-token")
        #expect(response == TestMessage(message: "ok"))
    }

    @Test func mapsForbiddenStatus() async throws {
        let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "没有权限访问该资源。"))
        let transport = MockHTTPTransport { _ in
            HTTPFixtures.response(statusCode: 403, body: body)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.execute(PublicMessageEndpoint())
            Issue.record("预期抛出 forbidden。")
        } catch let error as APIError {
            if case .forbidden(let message) = error {
                #expect(message == "没有权限访问该资源。")
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }

    @Test func requestCachePolicyFlowsIntoURLRequest() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.cachePolicy == .returnCacheDataDontLoad)
            let body = try HTTPFixtures.jsonBody(TestMessage(message: "cached"))
            return HTTPFixtures.response(statusCode: 200, body: body)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        let response = try await client.execute(CachedPublicMessageEndpoint())
        #expect(response == TestMessage(message: "cached"))
    }

    @Test func mapsValidationStatus() async throws {
        let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "邮箱格式不正确。"))
        let transport = MockHTTPTransport { _ in
            HTTPFixtures.response(statusCode: 422, body: body)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.execute(PublicMessageEndpoint())
            Issue.record("预期抛出 validationFailed。")
        } catch let error as APIError {
            if case .validationFailed(let message) = error {
                #expect(message == "邮箱格式不正确。")
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }

    @Test func mapsPayloadTooLargeStatusAndPreservesSession() async throws {
        let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "上传文件过大。"))
        let transport = MockHTTPTransport { _ in
            HTTPFixtures.response(statusCode: 413, body: body)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.execute(PublicMessageEndpoint())
            Issue.record("预期抛出 payloadTooLarge。")
        } catch let error as APIError {
            if case .payloadTooLarge(let message) = error {
                #expect(message == "上传文件过大。")
                #expect(error.shouldPreserveSession)
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }

    @Test func mapsRateLimitedStatusWithRetryAfter() async throws {
        let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "请求过于频繁。"))
        let transport = MockHTTPTransport { _ in
            HTTPFixtures.response(
                statusCode: 429,
                headers: ["Retry-After": "12"],
                body: body
            )
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.execute(PublicMessageEndpoint())
            Issue.record("预期抛出 rateLimited。")
        } catch let error as APIError {
            if case .rateLimited(let retryAfter, let message) = error {
                #expect(retryAfter == 12)
                #expect(message == "请求过于频繁。")
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }

    @Test func mapsTimeoutError() async throws {
        let transport = MockHTTPTransport { _ in
            throw URLError(.timedOut)
        }
        let client = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.execute(PublicMessageEndpoint())
            Issue.record("预期抛出 timeout。")
        } catch let error as APIError {
            if case .timeout = error {
                #expect(error.shouldMarkServerOffline)
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }
}
