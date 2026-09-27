import HTTPTypes
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Retired profile content endpoint")
struct V2VaporProfileViewRoutesTests {
    @Test("authenticated legacy clients receive a non-cacheable terminal response without content")
    func retiredEndpoint() async throws {
        let app = try await Application(.testing)
        do {
            V2VaporProfileViewRoutes(authenticator: ProfileRouteAuthenticator()).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/profile-views/batch", beforeSend: { request in
                    request.headers.bearerAuthorization = .init(token: "access-token")
                    request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000803"
                    // No new resource assembly or profile reader is installed.
                    // Even a malformed old request must not return profile data.
                    request.body = .init(string: "{invalid legacy request")
                })
                #expect(response.status == .gone)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect((try await response.body.string() ?? "").isEmpty)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("the retired route still enforces account credentials")
    func requiresAuthentication() async throws {
        let app = try await Application(.testing)
        do {
            V2VaporProfileViewRoutes(authenticator: ProfileRouteAuthenticator()).register(on: app)
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/profile-views/batch")
                #expect(response.status == .unauthorized)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }
}

private struct ProfileRouteAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        guard accessToken == "access-token" else { throw Abort(.unauthorized) }
        return .init(userID: try .init("00000000-0000-0000-0000-000000000801"), expiresAt: nil)
    }
}
