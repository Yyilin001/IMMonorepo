import Foundation
import HTTPTypes
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import Vapor

public struct V2VaporRoomResourceDirectoryRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let service: V2RoomResourceDirectoryService
    public init(authenticator: any V2GatewayAuthenticator, service: V2RoomResourceDirectoryService) {
        self.authenticator = authenticator; self.service = service
    }
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "rooms", ":roomID", "resources", "query") { request async throws -> Response in
            let actor = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            guard let raw = request.parameters.get("roomID"), let roomID = try? RoomID(raw), roomID.uuidValue != nil else { throw Abort(.badRequest) }
            do {
                let query = try await request.content.decode(V2RoomResourceQuery.self, using: JSONDecoder())
                let page = try await service.list(roomID: roomID, actorUserID: actor.userID, query: query)
                var headers = HTTPFields()
                headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"; headers[.v2Pragma] = "no-cache"
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(page)))
            } catch is DecodingError { throw Abort(.badRequest)
            } catch is V2ResourceValidationError { throw Abort(.badRequest)
            } catch V2ResourceDirectoryError.invalidCursor { throw Abort(.badRequest)
            } catch V2ResourceDirectoryError.notVisible { throw Abort(.notFound)
            } catch { throw Abort(.serviceUnavailable) }
        }
    }
}
