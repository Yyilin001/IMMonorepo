import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import Vapor

public struct V2VaporGroupCreationOperationRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let store: any V2GroupCreationOperationHandling
    public init(authenticator: any V2GatewayAuthenticator, store: any V2GroupCreationOperationHandling) { self.authenticator = authenticator; self.store = store }
    public func register(on routes: RoutesBuilder) {
        routes.on(.post,"v2","group-creation-operations","begin",maxBodySize:"4kb") { request async throws -> Response in
            let intent: V2GroupCreationIntent = try await decode(request)
            try await authorize(request, intent: intent)
            return try await respond { try await store.begin(intent, now: Date()) }
        }
        routes.on(.post,"v2","group-creation-operations","append",maxBodySize:"32kb") { request async throws -> Response in
            let input: V2GroupCreationAppendRequest = try await decode(request)
            try await authorize(request, intent: input.intent)
            return try await respond { try await store.append(input, now: Date()) }
        }
        routes.on(.post,"v2","group-creation-operations","finalize",maxBodySize:"4kb") { request async throws -> Response in
            let intent: V2GroupCreationIntent = try await decode(request)
            try await authorize(request, intent: intent)
            return try await respond { try await store.finalize(intent, now: Date(), deadline: ContinuousClock.now.advanced(by: .seconds(12))) }
        }
        routes.on(.post,"v2","group-creation-operations","operations","recover",maxBodySize:"4kb") { request async throws -> Response in
            let input: V2GroupCreationRecoveryRequest = try await decode(request)
            try await authorize(request, intent: input.intent)
            return try await respond { try await store.recover(input, now: Date()) }
        }
    }
    private func decode<T: Decodable>(_ request: Request) async throws -> T {
        do { return try await request.content.decode(T.self, using: JSONDecoder()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Abort(.badRequest,headers:[.cacheControl:"no-store"]) }
    }
    private func authorize(_ request: Request, intent: V2GroupCreationIntent) async throws {
        let actor = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
        guard actor.userID == intent.identity.accountID else { throw Abort(.forbidden,headers:[.cacheControl:"no-store"]) }
    }
    private func respond(_ operation: () async throws -> V2GroupCreationOperationResult) async throws -> Response {
        do {
            let value = try await operation()
            var headers: HTTPFields = [.cacheControl:"no-store",.contentType:"application/json"]
            var status: HTTPResponse.Status = .ok
            if case .deferred(let hint) = value {
                status = hint.reason == .rateLimited ? .tooManyRequests : .serviceUnavailable
                if let delay = hint.retryAfterMilliseconds { headers[.retryAfter] = String((delay+999)/1000) }
            }
            return .init(status: status,headers: headers,body:.init(data:try JSONEncoder().encode(value)))
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw Abort(.serviceUnavailable,headers:[.cacheControl:"no-store"]) }
    }
}
