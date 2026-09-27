import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Authorized nickname page HTTP", .serialized)
struct V2HTTPGroupNicknamePresentationClientTests {
    @Test("authorized page preserves cursor/denial distinctions and renders only its lease")
    func authorizedPage() async throws {
        let f = try NicknamePageFixture()
        let transport = NicknamePageHTTP(data: try f.body())
        let result = try await f.client(transport).read(roomID: f.room, limit: 3)
        #expect(result.userIDs == f.users && result.nextCursor == f.users.last)
        #expect(result.snapshot(for: f.users[0])?.presentation.groupMember?.groupNickname == "Name")
        #expect(result.snapshot(for: f.users[0])?.avatar == nil)
        #expect(result.unavailable == [f.users[1]] && result.retryable == [f.users[2]])
        #expect(result.snapshot(for: f.users[1]) == nil)
        let request = try #require(await transport.request)
        #expect(request.httpMethod == "GET" && request.url?.path.hasSuffix("/\(f.room.rawValue)/nicknames") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer nickname-token")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.url?.query == "limit=3")
    }

    @Test("another actor/device/room, stale cursor, oversized page and legacy payload fail closed",
          arguments: ["actor", "device", "room", "cursor", "count", "legacy"])
    func rejectsScope(scenario: String) async throws {
        let f = try NicknamePageFixture()
        let body = scenario == "legacy" ? Data("{\"nicknames\":[],\"next_cursor\":null}".utf8) : try f.body(
            actor: scenario == "actor" ? .init(uuid: UUID()) : nil,
            device: scenario == "device" ? .init(uuid: UUID()) : nil,
            room: scenario == "room" ? .init(uuid: UUID()) : nil)
        await #expect(throws: V2ProfilePresentationError.invalidResponse) {
            _ = try await f.client(NicknamePageHTTP(data: body)).read(roomID: f.room,
                afterUserID: scenario == "cursor" ? f.users[0] : nil, limit: scenario == "count" ? 2 : 3)
        }
    }

    @Test("elapsed network time cannot extend a page lease")
    func elapsedLease() async throws {
        let f = try NicknamePageFixture()
        let result = try await f.client(NicknamePageHTTP(data: f.body(ttl: 0.02), delay: .milliseconds(40)))
            .read(roomID: f.room, limit: 3)
        #expect(result.snapshot(for: f.users[0]) == nil)
        #expect(result.retryable == [f.users[0], f.users[2]] && result.unavailable == [f.users[1]])
    }

    @Test("invalid page sizes do no IO and rate limiting remains retryable")
    func limits() async throws {
        let f = try NicknamePageFixture(), transport = NicknamePageHTTP(data: Data())
        for limit in [0, 101, Int.max] {
            await #expect(throws: V2ProfilePresentationError.invalidResponse) {
                _ = try await f.client(transport).read(roomID: f.room, limit: limit)
            }
        }
        #expect(await transport.request == nil)
        await #expect(throws: V2ProfilePresentationError.throttled(retryAfter: 60)) {
            _ = try await f.client(NicknamePageHTTP(data: Data(), status: 429)).read(roomID: f.room)
        }
        for status in [401, 403] {
            await #expect(throws: V2ClientMediaTransferError.authorizationUnavailable) {
                _ = try await f.client(NicknamePageHTTP(data: Data(), status: status)).read(roomID: f.room)
            }
        }
    }
}

private struct NicknamePageFixture {
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
    let users = (0..<3).map { _ in UserID(uuid: UUID()) }.sorted { $0.rawValue < $1.rawValue }
    init() throws {}
    func body(actor: UserID? = nil, device: DeviceID? = nil, room: RoomID? = nil, ttl: TimeInterval = 60) throws -> Data {
        let room = room ?? self.room, now = Date(timeIntervalSince1970: 2_000_000_000)
        let revision = try #require(V2ProfileRevision(rawValue: 1))
        let view = try V2ProfileView(userID: users[0], publicIdentity: .init(userID: users[0], handle: .init("member"),
            displayName: "Public", accountKind: .regular), avatar: nil, state: .active, revision: revision, visibilityRevision: revision)
        let lease = try V2PresentationAccessLease(actorUserID: actor ?? self.actor, deviceID: device ?? self.device,
            key: .init(userID: users[0], context: .room(room)), profileRevision: revision, visibilityRevision: revision,
            contextRevision: 1, observedAt: now, validUntil: now.addingTimeInterval(ttl))
        let value = try V2AuthorizedProfilePresentation(view: view, lease: lease,
            groupMember: .init(roomID: room, userID: users[0], groupNickname: "Name", revision: revision))
        return try JSONEncoder().encode(V2GroupNicknamePresentationPageResponse(roomID: room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000, results: [.presentation(value, avatar: nil),
                .unavailable(.init(userID: users[1], context: .room(room))), .retryable(.init(userID: users[2], context: .room(room)))]),
            nextCursor: users.last))
    }
    func client(_ transport: NicknamePageHTTP) throws -> V2HTTPGroupNicknamePresentationClient {
        try .init(groupsEndpoint: #require(URL(string: "https://account.invalid/v2/profile-presentations/groups")),
            actorUserID: actor, credentials: NicknamePageCredentials(device: device), transport: transport)
    }
}
private struct NicknamePageCredentials: V2ClientMediaEdgeCredentialProvider {
    let device: DeviceID
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: "nickname-token", deviceID: device) }
}
private actor NicknamePageHTTP: V2ClientMediaEdgeHTTPTransport {
    let data: Data; let status: Int; let delay: Duration
    private(set) var request: URLRequest?
    init(data: Data, status: Int = 200, delay: Duration = .zero) { self.data = data; self.status = status; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        if delay > .zero { try await Task.sleep(for: delay) }
        let url = try #require(request.url)
        return (data, try #require(HTTPURLResponse(url: url, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json", "Retry-After": "120"])))
    }
}
