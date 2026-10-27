import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core

public enum V2ResourceDirectoryError: Error, Equatable, Sendable { case invalidCursor, notVisible, corruptResult }

/// Cursors bind a scan position to its user, room, filters and snapshot upper
/// bound. Each page still goes through the room's current visibility policy.
public struct V2RoomResourceDirectoryService: Sendable {
    private let authorization: V2ActorRoomMediaAuthorizationPort
    private let key: SymmetricKey

    public init(authorization: V2ActorRoomMediaAuthorizationPort, signingKey: Data) throws {
        guard signingKey.count >= 32 else { throw V2ResourceDirectoryError.invalidCursor }
        self.authorization = authorization
        key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("im-v2-room-resources-v1".utf8), using: SymmetricKey(data: signingKey))))
    }

    public func list(roomID: RoomID, actorUserID: UserID, query: V2RoomResourceQuery, now: Date = Date()) async throws -> V2RoomResourcePage {
        try Task.checkCancellation()
        let instant = now.timeIntervalSince1970
        guard instant.isFinite, instant >= 0, instant < 253_402_300_799 else { throw V2ResourceDirectoryError.invalidCursor }
        let position = try query.cursor.map { try decode($0, room: roomID, actor: actorUserID, query: query, now: instant) }
        let stripped = try V2RoomResourceQuery(category: query.category, limit: query.limit, before: query.before, after: query.after)
        let request = try V2ActorRoomResourceDirectoryWire(roomID: roomID, actorUserID: actorUserID, query: stripped,
            snapshotUpperRoomSequence: position?.upperBound, before: position?.before)
        guard let page = try await authorization.resourceDirectory(request, deadline: .now + .seconds(10)) else { throw V2ResourceDirectoryError.notVisible }
        try Task.checkCancellation()
        let cursor: String?
        if page.hasMore, let last = page.items.last {
            let value = Cursor(version: 1, room: roomID, actor: actorUserID, category: query.category,
                beforeDate: query.before, afterDate: query.after, upperBound: page.snapshotUpperRoomSequence,
                before: last.position, expiresAt: position?.expiresAt ?? instant + 3600)
            cursor = try encode(value)
        } else { cursor = nil }
        return try .init(items: page.items, snapshotUpperRoomSequence: page.snapshotUpperRoomSequence, nextCursor: cursor)
    }

    private func encode(_ value: Cursor) throws -> String {
        let payload = try JSONEncoder().encode(value)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        let cursor = payload.base64EncodedString() + "." + signature.base64EncodedString()
        guard cursor.utf8.count <= 4096 else { throw V2ResourceDirectoryError.invalidCursor }
        return cursor
    }

    private func decode(_ cursor: String, room: RoomID, actor: UserID, query: V2RoomResourceQuery, now: Double) throws -> Cursor {
        let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
        guard cursor.utf8.count <= 4096, parts.count == 2,
              let payload = Data(base64Encoded: String(parts[0])), let signature = Data(base64Encoded: String(parts[1])),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: key),
              let value = try? JSONDecoder().decode(Cursor.self, from: payload), value.version == 1,
              value.actor == actor, value.room == room, value.category == query.category,
              value.beforeDate == query.before, value.afterDate == query.after,
              value.upperBound <= UInt64(Int64.max), value.before.roomSequence <= value.upperBound,
              value.expiresAt.isFinite, value.expiresAt > now, value.expiresAt <= now + 3600 else { throw V2ResourceDirectoryError.invalidCursor }
        return value
    }

    private struct Cursor: Codable {
        let version: Int
        let room: RoomID
        let actor: UserID
        let category: V2ResourceCategory
        let beforeDate: Int64?
        let afterDate: Int64?
        let upperBound: UInt64
        let before: V2RoomResourcePosition
        let expiresAt: Double
    }
}
