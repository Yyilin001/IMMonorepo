import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporPersonalPreferenceRecoveryRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let administration: V2RoomRefAdministrationClient
    public init(authenticator: any V2GatewayAuthenticator, administration: V2RoomRefAdministrationClient) {
        self.authenticator = authenticator
        self.administration = administration
    }
    public func register(on routes: RoutesBuilder) {
        routes.on(.post, "v2", "rooms", ":roomID", "personal-preferences", "operations", "recover", maxBodySize: "4kb")
        { request async throws -> Response in
            let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            let headers: HTTPFields = [.contentType: "application/json", .cacheControl: "no-store"]
            guard let raw = request.parameters.get("roomID"), let room = UUID(uuidString: raw),
                let bytes = try await request.body.collect(), bytes.count <= 4096
            else { throw Abort(.badRequest, headers: headers) }
            let value: V2PersonalPreferenceRecoveryRequest
            do {
                value = try await request.content.decode(V2PersonalPreferenceRecoveryRequest.self, using: JSONDecoder())
            } catch { throw Abort(.badRequest, headers: headers) }
            guard value.roomID.uuidValue == room else { throw Abort(.badRequest, headers: headers) }
            guard value.identity.accountID == identity.userID else { throw Abort(.forbidden, headers: headers) }
            do {
                let result = try await administration.recoverPersonalPreference(
                    actorUserID: identity.userID, request: value)
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(result)))
            } catch { throw Abort(.serviceUnavailable, headers: headers) }
        }
    }
}
