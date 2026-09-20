import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Routed member directory")
struct V2RoutedRoomMembershipDirectoryTests {
    private let room = RoomID(uuid: UUID())
    private let user = UserID(uuid: UUID())

    @Test("selected owner supplies roles, control supplies identities, and hidden pages still advance", arguments: [false, true])
    func ownerAndControl(hidden: Bool) async throws {
        let page = V2RoomMemberCandidatePage(membershipRevision: 7, actorRole: .admin,
            entries: [.init(userID: user, role: .member)], nextCursor: "next")
        let owner = MemberOwner(page: page), fallback = MemberOwner(page: page)
        let identity = try V2PublicIdentity(userID: user, handle: .init("current_user"), displayName: "Current", accountKind: .regular)
        let profiles = MemberIdentities(values: hidden ? [:] : [user: identity])
        let router = try MemberRouter(epochs: [3, 3])
        let store = try V2RoutedRoomMembershipDirectoryStore(router: router, owners: ["owner": owner, "fallback": fallback], identities: profiles)
        let request = try V2RoomMembershipDirectoryRequest(roomID: room, actorUserID: user, cursor: nil, pageSize: 1)
        let result = try await store.list(request)
        #expect(result.actorRole == .admin && result.membershipRevision == 7)
        #expect(result.entries.map(\.publicIdentity) == (hidden ? [] : [identity]))
        #expect(result.nextCursor == "next")
        #expect(await owner.requests() == [request])
        #expect(await owner.validationCount() == 1)
        #expect(await profiles.requestedIDs() == [[user]])
        #expect(await fallback.requests().isEmpty)
        #expect(await router.readCount() == 2)
    }

    @Test("revocation, membership change and ownership changes never fall back", arguments: ["denied", "revoked", "revision", "epoch", "unknown"])
    func staleAndUnauthorized(stage: String) async throws {
        let page = V2RoomMemberCandidatePage(membershipRevision: 7, actorRole: .admin, entries: [], nextCursor: nil)
        let error: V2RoomMembershipDirectoryError? = stage == "revoked" ? .actorNotMember : (stage == "revision" ? .revisionConflict(currentRevision: 8) : nil)
        let owner = MemberOwner(page: page, denied: stage == "denied", validationError: error)
        let fallback = MemberOwner(page: page)
        let store = try V2RoutedRoomMembershipDirectoryStore(router: MemberRouter(epochs: stage == "epoch" ? [3, 4] : [3, 3]),
            owners: stage == "unknown" ? ["fallback": fallback] : ["owner": owner, "fallback": fallback], identities: MemberIdentities(values: [:]))
        let request = try V2RoomMembershipDirectoryRequest(roomID: room, actorUserID: user, cursor: nil, pageSize: 1)
        if stage == "unknown" {
            await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { try await store.list(request) }
        } else {
            let expected: V2RoomMembershipDirectoryError = stage == "epoch" ? .ownerChanged : (error ?? .actorNotMember)
            await #expect(throws: expected) { try await store.list(request) }
        }
        #expect(await fallback.requests().isEmpty)
    }

    @Test("unbounded and duplicate candidate pages are rejected before identity reads", arguments: ["count", "duplicate", "cursor", "revision"])
    func invalidOwnerPage(defect: String) async throws {
        let entries: [V2RoomMemberCandidate] = defect == "count" || defect == "duplicate"
            ? [.init(userID: user, role: .member), .init(userID: user, role: .member)] : []
        let page = V2RoomMemberCandidatePage(membershipRevision: defect == "revision" ? UInt64.max : 7, actorRole: .admin,
            entries: entries, nextCursor: defect == "cursor" ? "old" : nil)
        let profiles = MemberIdentities(values: [:])
        let store = try V2RoutedRoomMembershipDirectoryStore(router: MemberRouter(epochs: [3]), owners: ["owner": MemberOwner(page: page)], identities: profiles)
        let request = try V2RoomMembershipDirectoryRequest(roomID: room, actorUserID: user, cursor: "old", pageSize: defect == "duplicate" ? 2 : 1)
        await #expect(throws: V2RoomMembershipDirectoryError.corruptPersistenceState) { try await store.list(request) }
        #expect(await profiles.requestedIDs().isEmpty)
    }
}

private actor MemberRouter: V2RoomShardRouting {
    let routes: [V2RoomShardRoute]
    var index = 0
    init(epochs: [Int64]) throws { routes = try epochs.map { try .init(shardID: "owner", epoch: $0) } }
    func route(for _: RoomID) -> V2RoomShardRoute {
        defer { index += 1 }
        return routes[min(index, routes.count - 1)]
    }
    func readCount() -> Int { index }
}
private actor MemberOwner: V2RoomMemberCandidateReading {
    let page: V2RoomMemberCandidatePage
    let denied: Bool
    let validationError: V2RoomMembershipDirectoryError?
    var captured: [V2RoomMembershipDirectoryRequest] = []
    var validations = 0
    init(page: V2RoomMemberCandidatePage, denied: Bool = false, validationError: V2RoomMembershipDirectoryError? = nil) {
        self.page = page; self.denied = denied; self.validationError = validationError
    }
    func candidates(_ request: V2RoomMembershipDirectoryRequest, route: V2RoomShardRoute) throws -> V2RoomMemberCandidatePage {
        captured.append(request)
        if denied { throw V2RoomMembershipDirectoryError.actorNotMember }
        return page
    }
    func validate(_ request: V2RoomMembershipDirectoryRequest, route: V2RoomShardRoute, page: V2RoomMemberCandidatePage) throws {
        validations += 1
        if let validationError { throw validationError }
    }
    func requests() -> [V2RoomMembershipDirectoryRequest] { captured }
    func validationCount() -> Int { validations }
}
private actor MemberIdentities: V2MemberDirectoryIdentityReading {
    let values: [UserID: V2PublicIdentity]
    var requested: [[UserID]] = []
    init(values: [UserID: V2PublicIdentity]) { self.values = values }
    func identities(for users: [UserID]) -> [UserID: V2PublicIdentity] { requested.append(users); return values }
    func requestedIDs() -> [[UserID]] { requested }
}
