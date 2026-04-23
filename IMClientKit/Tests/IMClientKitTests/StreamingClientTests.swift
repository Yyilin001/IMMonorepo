import Foundation
import Testing
@testable import IMClientKit

private struct AuthorizedStreamEndpoint: AuthorizedStreamingEndpoint {
    let baseRequestSpec = HTTPRequestSpec(path: "stream")
}

struct StreamingClientTests {
    @Test func authorizedStreamInjectsBearerToken() async throws {
        let transport = MockStreamingTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stream-token")
            let stream = HTTPByteStream(
                bytes: AsyncThrowingStream { continuation in
                    for byte in Data("ok".utf8) {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                }
            )
            return (
                stream,
                HTTPURLResponse(
                    url: HTTPFixtures.baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let client = StreamingClient(baseURL: HTTPFixtures.baseURL, transport: transport)
        let connection = try await client.openStream(AuthorizedStreamEndpoint(), bearerToken: "stream-token")

        var collected = Data()
        for try await chunk in connection.chunks {
            collected.append(chunk)
        }

        #expect(String(data: collected, encoding: .utf8) == "ok")
    }

    @Test func mapsNonSuccessStreamResponse() async throws {
        let transport = MockStreamingTransport { _ in
            let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "请求过于频繁。"))
            let stream = HTTPByteStream(
                bytes: AsyncThrowingStream { continuation in
                    for byte in body {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                }
            )
            return (
                stream,
                HTTPURLResponse(
                    url: HTTPFixtures.baseURL,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "8"]
                )!
            )
        }

        let client = StreamingClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        do {
            _ = try await client.openStream(AuthorizedStreamEndpoint(), bearerToken: "stream-token")
            Issue.record("预期抛出 rateLimited。")
        } catch let error as APIError {
            if case .rateLimited(let retryAfter, let message) = error {
                #expect(retryAfter == 8)
                #expect(message == "请求过于频繁。")
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }
}
