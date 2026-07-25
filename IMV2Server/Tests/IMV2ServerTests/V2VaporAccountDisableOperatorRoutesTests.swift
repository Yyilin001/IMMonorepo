import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor account-disable operator routes")
struct V2VaporAccountDisableOperatorRoutesTests {
    @Test("account disable requires its dedicated credential and returns an audited no-store result")
    func authorizedDisable() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 14, count: 32).base64EncodedString()
        let service = AccountDisableRouteService()
        V2VaporAccountDisableOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), service: service
        ).register(on: app)
        let input = V2AccountDisableHTTPRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000981")!,
            userID: "00000000-0000-0000-0000-000000000982", reason: .credentialCompromise
        )

        try await app.testing().test(.POST, "internal/v2/accounts/disable", headers: ["Authorization": "Bearer \(token)"], beforeRequest: { request in
            try request.content.encode(input)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            var decoded: V2AccountDisableHTTPResponse?
            expectContent(V2AccountDisableHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.operationID == input.operationID)
            #expect(decoded?.outcome == "disabled")
            #expect(decoded?.disabledAtMilliseconds == 1_750_000_000_000)
        }
        let command = try #require(await service.receivedCommand())
        #expect(command.userID.rawValue == input.userID)
        #expect(command.operationID == input.operationID)
        #expect(command.reason == .credentialCompromise)
    }

    @Test("account disable refuses unauthenticated and malformed requests before calling the service")
    func rejectsUnauthenticatedOrMalformedRequest() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 15, count: 32).base64EncodedString()
        let service = AccountDisableRouteService()
        V2VaporAccountDisableOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), service: service
        ).register(on: app)
        let valid = V2AccountDisableHTTPRequest(operationID: UUID(), userID: "00000000-0000-0000-0000-000000000983", reason: .userRequested)
        try await app.testing().test(.POST, "internal/v2/accounts/disable", beforeRequest: { request in
            try request.content.encode(valid)
        }) { response async in
            #expect(response.status == .unauthorized)
        }
        let malformed = V2AccountDisableHTTPRequest(operationID: UUID(), userID: "not-a-uuid", reason: .userRequested)
        try await app.testing().test(.POST, "internal/v2/accounts/disable", headers: ["Authorization": "Bearer \(token)"], beforeRequest: { request in
            try request.content.encode(malformed)
        }) { response async in
            #expect(response.status == .badRequest)
        }
        #expect(await service.receivedCommand() == nil)
    }
}

private actor AccountDisableRouteService: V2AccountDisabling {
    private var command: V2AccountDisableCommand?

    func disable(_ command: V2AccountDisableCommand) -> V2AccountDisableOutcome {
        self.command = command
        return .disabled(disabledAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    func receivedCommand() -> V2AccountDisableCommand? { command }
}
