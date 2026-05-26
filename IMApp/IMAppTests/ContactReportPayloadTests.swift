import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

struct ContactReportPayloadTests {
    @Test func sessionClientSubmitsUserReportPayload() async throws {
        let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let reportedUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        AuthResponseBody(
                            accessToken: "access-1",
                            expiresIn: 600,
                            refreshToken: "refresh-1",
                            refreshExpiresIn: 30 * 24 * 60 * 60,
                            user: AuthUser(id: userID, email: "me@example.com")
                        )
                    )
                )
            case ("POST", "/api/reports"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
                let payload = try JSONDecoder().decode(
                    ReportCreateRequestBody.self,
                    from: try #require(request.httpBody)
                )
                #expect(payload.targetType == "user")
                #expect(payload.targetID == reportedUserID.uuidString)
                #expect(payload.reason == "骚扰")
                #expect(payload.detail == "持续发送垃圾消息")

                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        ReportResponseBody(
                            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                            targetType: payload.targetType,
                            targetID: payload.targetID,
                            reporterUserID: userID,
                            conversationID: nil,
                            messageID: nil,
                            reason: payload.reason,
                            detail: payload.detail,
                            status: "pending",
                            handledNote: nil,
                            messageSnapshotJSON: nil,
                            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.path ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache()
        )

        _ = try await client.login(email: "me@example.com", password: "password123", device: nil)
        _ = try await client.createReport(
            targetType: "user",
            targetID: reportedUserID.uuidString,
            reason: "骚扰",
            detail: "持续发送垃圾消息"
        )
    }
}
