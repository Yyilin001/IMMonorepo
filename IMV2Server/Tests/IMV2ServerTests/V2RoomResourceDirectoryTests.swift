import Foundation
import HTTPTypes
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Authorized room resource directory")
struct V2RoomResourceDirectoryTests {
    private func item(room: RoomID, sequence: UInt64) throws -> V2RoomResourceItem {
        let media = MediaID(uuid: UUID())
        return try .init(messageID: .init(uuid: UUID()), messageRevision: 1,
            position: .init(roomSequence: sequence, ordinal: 0, mediaID: media), createdAt: 1000,
            descriptor: .init(key: .init(home: .room(room), mediaID: media), revision: 1,
                displayName: .init("test.jpg"), contentType: "image/jpeg", byteCount: 32,
                checksum: .init(value: String(repeating: "a", count: 64)), state: .ready))
    }

    @Test func cursorIsUserRoomFilterAndSnapshotBoundAndEveryPageReauthorizes() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID()), first = try item(room: room, sequence: 10)
        let boundary = DirectoryBoundary(result: .resourceDirectory(try .init(items: [first], snapshotUpperRoomSequence: 10, hasMore: true)))
        let service = try V2RoomResourceDirectoryService(authorization: .init(query: { query, _ in await boundary.read(query) }), signingKey: Data(repeating: 7, count: 32))
        let page = try await service.list(roomID: room, actorUserID: user, query: .init(category: .image, limit: 1), now: Date(timeIntervalSince1970: 100))
        let cursor = try #require(page.nextCursor)
        #expect(page.items == [first])
        for (targetRoom, targetUser, query) in [
            (RoomID(uuid: UUID()), user, try V2RoomResourceQuery(category: .image, cursor: cursor)),
            (room, UserID(uuid: UUID()), try V2RoomResourceQuery(category: .image, cursor: cursor)),
            (room, user, try V2RoomResourceQuery(category: .file, cursor: cursor)),
            (room, user, try V2RoomResourceQuery(category: .image, cursor: cursor, before: 1001)),
            (room, user, try V2RoomResourceQuery(category: .image, cursor: cursor + "x"))
        ] {
            await #expect(throws: V2ResourceDirectoryError.invalidCursor) {
                try await service.list(roomID: targetRoom, actorUserID: targetUser, query: query, now: Date(timeIntervalSince1970: 101))
            }
        }
        #expect(await boundary.calls.count == 1)
        await boundary.set(.notVisible)
        await #expect(throws: V2ResourceDirectoryError.notVisible) {
            try await service.list(roomID: room, actorUserID: user, query: .init(category: .image, cursor: cursor), now: Date(timeIntervalSince1970: 101))
        }
        #expect(await boundary.calls.count == 2)
        guard case .resourceDirectory(let wire) = await boundary.calls.last else { Issue.record("Missing room read"); return }
        #expect(wire.before == first.position && wire.snapshotUpperRoomSequence == 10)
        #expect(wire.query.cursor == nil)
        await #expect(throws: V2ResourceDirectoryError.invalidCursor) {
            try await service.list(roomID: room, actorUserID: user, query: .init(category: .image, cursor: cursor), now: Date(timeIntervalSince1970: 3701))
        }
        #expect(await boundary.calls.count == 2)
    }

    @Test func wrongHomeOrderAndChangedUpperBoundAreRejectedAtPort() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let wrong = try item(room: .init(uuid: UUID()), sequence: 10)
        let state = DirectoryBoundary(result: .resourceDirectory(try .init(items: [wrong], snapshotUpperRoomSequence: 10, hasMore: false)))
        let port = V2ActorRoomMediaAuthorizationPort(query: { query, _ in await state.read(query) })
        let request = try V2ActorRoomResourceDirectoryWire(roomID: room, actorUserID: user, query: .init(), snapshotUpperRoomSequence: nil, before: nil)
        await #expect(throws: (any Error).self) { try await port.resourceDirectory(request, deadline: .now + .seconds(1)) }
        let small = try item(room: room, sequence: 9), big = try item(room: room, sequence: 10)
        await state.set(.resourceDirectory(try .init(items: [small,big], snapshotUpperRoomSequence: 10, hasMore: false)))
        await #expect(throws: (any Error).self) { try await port.resourceDirectory(request, deadline: .now + .seconds(1)) }
    }

    @Test func routeAuthenticatesBeforeDecodeAndReturnsNoStoreMetadata() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let entry = try item(room: room, sequence: 10)
        let state = DirectoryBoundary(result: .resourceDirectory(try .init(items: [entry], snapshotUpperRoomSequence: 10, hasMore: false)))
        let service = try V2RoomResourceDirectoryService(authorization: .init(query: { query, _ in await state.read(query) }), signingKey: Data(repeating: 8, count: 32))
        let app = try await Application(.testing)
        do {
            V2VaporRoomResourceDirectoryRoutes(authenticator: DirectoryAuthentication(user: user), service: service).register(on: app)
            try await app.testing { client in
                let path = URI(string: "v2/rooms/\(room.rawValue)/resources/query")
                let anonymous = try await client.send(.post, to: path, beforeSend: { $0.body = .init(string: "{malformed") })
                #expect(anonymous.status == .unauthorized)
                #expect(await state.calls.isEmpty)
                let headers: HTTPFields = [.authorization: "Bearer fixture",HTTPField.Name("X-IM-Device-ID")!:device.rawValue]
                let malformed = try await client.send(.post, headers: headers, to: path, beforeSend: {
                    $0.headers[.contentType] = "application/json"; $0.body = .init(string: "{}")
                })
                #expect(malformed.status == .badRequest)
                #expect(await state.calls.isEmpty)
                let response = try await client.send(.post, headers: headers, to: path, beforeSend: {
                    try $0.content.encode(V2RoomResourceQuery(category: .image), using: JSONEncoder())
                })
                #expect(response.status == .ok && response.headers[.cacheControl] == "no-store")
                #expect(try await response.content.decode(V2RoomResourcePage.self).items == [entry])
                await state.set(.notVisible)
                let revoked = try await client.send(.post, headers: headers, to: path, beforeSend: {
                    try $0.content.encode(V2RoomResourceQuery(), using: JSONEncoder())
                })
                #expect(revoked.status == .notFound)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }
}

private actor DirectoryBoundary {
    var result: V2RoomMediaAuthorizationResult
    var calls: [V2RoomMediaAuthorizationQuery] = []
    init(result: V2RoomMediaAuthorizationResult) { self.result = result }
    func read(_ query: V2RoomMediaAuthorizationQuery) -> V2RoomMediaAuthorizationResult { calls.append(query); return result }
    func set(_ result: V2RoomMediaAuthorizationResult) { self.result = result }
}
private struct DirectoryAuthentication: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        guard accessToken == "fixture" else { throw V2GatewayAuthenticationError.unauthenticated }
        return .init(userID: user, expiresAt: nil)
    }
}
