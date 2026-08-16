import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// Authenticated exact-handle lookup. There is deliberately no list, prefix,
/// fuzzy, UUID, or bulk endpoint in this route family.
public struct V2VaporPublicIdentityRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let directory: any V2PublicIdentityAccountManaging

    public init(authenticator: any V2GatewayAuthenticator, directory: any V2PublicIdentityAccountManaging) {
        self.authenticator = authenticator
        self.directory = directory
    }

    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "public-identities", "resolve") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawHandle = request.query[String.self, at: "handle"], let handle = try? V2PublicHandle(rawHandle) else { throw Abort(.badRequest) }
            do {
                guard let result = try await directory.resolve(handle: handle, actorUserID: actor.userID) else { throw Abort(.notFound) }
                return try noStoreJSONResponse(.init(userID: result.userID.rawValue, handle: result.handle.rawValue, displayName: result.displayName, accountKind: result.accountKind))
            } catch let error as V2PublicIdentityDirectoryError {
                switch error {
                case .rateLimited(let retryAfterSeconds): return noStoreRetryAfterResponse(seconds: retryAfterSeconds)
                case .unavailable: throw Abort(.serviceUnavailable)
                }
            }
        }

        routes.get("v2", "public-identities", "me") { request async throws -> Response in
            let actor = try await authenticate(request)
            do {
                guard let result = try await directory.profile(for: actor.userID) else { throw Abort(.notFound) }
                return try noStoreJSONResponse(.init(userID: result.userID.rawValue, handle: result.handle.rawValue, displayName: result.displayName, accountKind: result.accountKind))
            } catch is Abort { throw Abort(.notFound) }
            catch { throw Abort(.serviceUnavailable) }
        }

    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        guard let accessToken = request.headers.bearerAuthorization?.token,
              let rawDeviceID = request.headers.first(name: "X-IM-Device-ID"),
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw Abort(.unauthorized) }
        do {
            let userID = try await authenticator.authenticateSession(accessToken: accessToken, deviceID: deviceID).userID
            return .init(userID: userID, deviceID: deviceID, capabilityProfile: "account-edge")
        } catch { throw Abort(.unauthorized) }
    }

    private func noStoreJSONResponse(_ result: V2PublicIdentityHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(result)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    private func noStoreRetryAfterResponse(seconds: Int) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        headers.replaceOrAdd(name: "Retry-After", value: String(seconds))
        return .init(status: .tooManyRequests, headers: headers)
    }
}

public struct V2PublicIdentityHTTPResponse: Content, Sendable {
    public let userID: String
    public let handle: String
    public let displayName: String
    public let accountKind: V2AccountKind
}
