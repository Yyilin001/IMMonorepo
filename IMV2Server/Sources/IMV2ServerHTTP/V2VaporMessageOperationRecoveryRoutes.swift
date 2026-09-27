import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporMessageOperationRecoveryRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let messages: V2RoomRefMessagingClient
    public init(authenticator: any V2GatewayAuthenticator, messages: V2RoomRefMessagingClient) {
        self.authenticator = authenticator; self.messages = messages
    }
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "message-operations", "recover") { request async throws -> Response in
            let actor = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            do {
                let input = try await request.content.decode(V2MessageOperationRecoveryRequest.self, using: JSONDecoder())
                guard input.roomID.uuidValue != nil, input.clientMessageID.uuidValue != nil else { throw Abort(.badRequest) }
                let result = try await messages.recover(input, actorUserID: actor.userID)
                var headers = HTTPFields(); headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(result)))
            } catch is DecodingError { throw Abort(.badRequest)
            } catch is V2SendMessageFingerprintError { throw Abort(.badRequest)
            } catch let error as Abort { throw error
            } catch { throw Abort(.serviceUnavailable) }
        }
    }
}
