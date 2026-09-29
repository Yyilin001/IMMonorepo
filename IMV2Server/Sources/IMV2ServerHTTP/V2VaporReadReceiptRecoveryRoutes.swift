import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporReadReceiptRecoveryRoutes:Sendable {
    private let authenticator:any V2GatewayAuthenticator
    private let queries:any V2ReadReceiptRecovering
    public init(authenticator:any V2GatewayAuthenticator,queries:any V2ReadReceiptRecovering) { self.authenticator=authenticator;self.queries=queries }
    public func register(on routes:RoutesBuilder) {
        routes.on(.post,"v2","rooms",":roomID","read-receipts","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let identity = try await request.v2AuthenticatedAccountIdentity(using:authenticator)
            let noStore:HTTPFields = [.cacheControl:"no-store"]
            guard let raw = request.parameters.get("roomID"),let room = UUID(uuidString:raw) else { throw Abort(.badRequest,headers:noStore) }
            let input:V2ReadReceiptRecoveryRequest
            do { input = try await request.content.decode(V2ReadReceiptRecoveryRequest.self,using:JSONDecoder()) }
            catch { throw Abort(.badRequest,headers:noStore) }
            guard input.command.actorUserID == identity.userID,input.command.roomID == RoomID(uuid:room) else { throw Abort(.forbidden,headers:noStore) }
            do {
                let result = try await queries.recoverReadReceipt(input)
                return .init(status:.ok,headers:[.cacheControl:"no-store",.contentType:"application/json"],body:.init(data:try JSONEncoder().encode(result)))
            } catch { throw Abort(.serviceUnavailable,headers:noStore) }
        }
    }
}
