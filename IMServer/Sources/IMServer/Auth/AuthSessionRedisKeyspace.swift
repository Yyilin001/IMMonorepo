import Foundation
@preconcurrency import RediStack

/// Cluster-safe auth cache keys. A session entry is validated against
/// independently routed user/global revisions, so user-wide invalidation no
/// longer needs a cross-slot scan and delete of every session cache entry.
enum AuthSessionRedisKeyspace {
    static let globalEpochKey = RedisKey("im:auth:session-cache:{global}:epoch")

    static func sessionKey(sessionID: UUID) -> RedisKey {
        RedisKey("im:auth:session:{\(sessionID.uuidString.lowercased())}")
    }

    static func userRevisionKey(userID: UUID) -> RedisKey {
        RedisKey("im:auth:user:{\(userID.uuidString.lowercased())}:session-cache-revision")
    }
}
