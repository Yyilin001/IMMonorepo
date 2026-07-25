import Fluent
import Foundation
import IMV2Core
import IMV2Server
import SQLKit
import Vapor

public enum V2PublicIdentityDirectoryError: Error, Equatable, Sendable { case unavailable, rateLimited(retryAfterSeconds: Int) }

public protocol V2PublicIdentityDirectoryReading: Sendable {
    func resolve(handle: V2PublicHandle, actorUserID: UserID) async throws -> V2PublicIdentity?
}

/// Account-edge directory backed solely by public-profile data. A mutual block
/// resolves as nil, exactly like an absent handle.
public struct V2PostgresPublicIdentityDirectory: V2PublicIdentityDirectoryReading, Sendable {
    private let database: any Database
    private let policy: V2PublicIdentityLookupRateLimitPolicy
    private let now: @Sendable () -> Date

    public init(database: any Database, policy: V2PublicIdentityLookupRateLimitPolicy, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.policy = policy
        self.now = now
    }

    public func resolve(handle: V2PublicHandle, actorUserID: UserID) async throws -> V2PublicIdentity? {
        guard let actorUUID = UUID(uuidString: actorUserID.rawValue) else { throw V2PublicIdentityDirectoryError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PublicIdentityDirectoryError.unavailable }
            try await consumeLookupBudget(sql: sql, actorUserID: actorUUID)
            guard let row = try await sql.raw("""
                SELECT p.user_id, p.public_handle, p.display_name
                FROM im_v2.public_user_profiles p
                WHERE p.public_handle = \(bind: handle.rawValue)
                  AND NOT EXISTS (
                    SELECT 1 FROM im_v2.user_blocks b
                    WHERE (b.blocker_user_id = \(bind: actorUUID) AND b.blocked_user_id = p.user_id)
                       OR (b.blocker_user_id = p.user_id AND b.blocked_user_id = \(bind: actorUUID))
                  )
                """).first(decoding: PublicIdentityRow.self),
                let userID = try? UserID(row.userID.uuidString),
                let profile = try? V2PublicIdentity(userID: userID, handle: .init(row.handle), displayName: row.displayName)
            else { return nil }
            return profile
        }
    }

    private func consumeLookupBudget(sql: any SQLDatabase, actorUserID: UUID) async throws {
        let current = now()
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-public-identity-lookup:" + actorUserID.uuidString), 0))").run()
        guard let existing = try await sql.raw("SELECT window_started_at, query_count FROM im_v2.public_identity_lookup_rate_limits WHERE actor_user_id = \(bind: actorUserID)").first(decoding: LookupRateLimitRow.self) else {
            try await sql.raw("INSERT INTO im_v2.public_identity_lookup_rate_limits (actor_user_id, window_started_at, query_count, updated_at) VALUES (\(bind: actorUserID), \(bind: current), 1, \(bind: current))").run()
            return
        }
        let elapsed = current.timeIntervalSince(existing.windowStartedAt)
        if elapsed >= policy.window {
            try await sql.raw("UPDATE im_v2.public_identity_lookup_rate_limits SET window_started_at = \(bind: current), query_count = 1, updated_at = \(bind: current) WHERE actor_user_id = \(bind: actorUserID)").run()
            return
        }
        guard existing.queryCount < policy.maximumQueries else {
            throw V2PublicIdentityDirectoryError.rateLimited(retryAfterSeconds: max(1, Int(ceil(policy.window - elapsed))))
        }
        try await sql.raw("UPDATE im_v2.public_identity_lookup_rate_limits SET query_count = query_count + 1, updated_at = \(bind: current) WHERE actor_user_id = \(bind: actorUserID)").run()
    }
}

/// Authenticated exact-handle lookup. There is deliberately no list, prefix,
/// fuzzy, UUID, or bulk endpoint in this route family.
public struct V2VaporPublicIdentityRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let directory: any V2PublicIdentityDirectoryReading

    public init(authenticator: any V2GatewayAuthenticator, directory: any V2PublicIdentityDirectoryReading) {
        self.authenticator = authenticator
        self.directory = directory
    }

    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "public-identities", "resolve") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawHandle = request.query[String.self, at: "handle"], let handle = try? V2PublicHandle(rawHandle) else { throw Abort(.badRequest) }
            do {
                guard let result = try await directory.resolve(handle: handle, actorUserID: actor.userID) else { throw Abort(.notFound) }
                return try noStoreJSONResponse(.init(userID: result.userID.rawValue, handle: result.handle.rawValue, displayName: result.displayName))
            } catch let error as V2PublicIdentityDirectoryError {
                switch error {
                case .rateLimited(let retryAfterSeconds): return noStoreRetryAfterResponse(seconds: retryAfterSeconds)
                case .unavailable: throw Abort(.serviceUnavailable)
                }
            }
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        guard let accessToken = request.headers.bearerAuthorization?.token,
              let rawDeviceID = request.headers.first(name: "X-IM-Device-ID"),
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw Abort(.unauthorized) }
        do {
            let userID = try await authenticator.authenticate(accessToken: accessToken, deviceID: deviceID)
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
}

private struct PublicIdentityRow: Decodable {
    let userID: UUID
    let handle: String
    let displayName: String
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case handle = "public_handle"; case displayName = "display_name" }
}

private struct LookupRateLimitRow: Decodable {
    let windowStartedAt: Date
    let queryCount: Int
    enum CodingKeys: String, CodingKey { case windowStartedAt = "window_started_at"; case queryCount = "query_count" }
}
