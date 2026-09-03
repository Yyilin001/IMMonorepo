import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor profile presentation routes")
struct V2VaporProfilePresentationRoutesTests {
    @Test("contact aliases are scoped to the authenticated owner and disable caching")
    func contactAliasesUseAuthenticatedOwner() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let owner = try UserID("owner")
        let target = try UserID("target")
        let alias = try V2ContactAlias(
            ownerUserID: owner,
            targetUserID: target,
            remarkName: "朋友",
            revision: try #require(.init(rawValue: 1))
        )
        let manager = PresentationRouteManager(alias: alias, nickname: nil)
        V2VaporProfilePresentationRoutes(
            authenticator: PresentationRouteAuthenticator(userID: owner),
            presentations: manager
        ).register(on: app)

        try await app.testing().test(.GET, "v2/profile-presentations/contact-aliases?cursor=target&limit=20", headers: authenticatedHeaders()) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
            #expect(body.contains("朋友"))
            #expect(body.contains("target"))
        }
        let request = try #require(await manager.aliasListRequest())
        #expect(request.owner == owner)
        #expect(request.cursor == target)
        #expect(request.limit == 20)
    }

    @Test("group nickname mutation cannot name another actor")
    func groupNicknameUsesAuthenticatedActor() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let actor = try UserID("actor")
        let room = try RoomID("room")
        let nickname = try V2GroupMemberPresentation(
            roomID: room,
            userID: actor,
            groupNickname: "值班",
            revision: try #require(.init(rawValue: 2))
        )
        let manager = PresentationRouteManager(alias: nil, nickname: nickname)
        V2VaporProfilePresentationRoutes(
            authenticator: PresentationRouteAuthenticator(userID: actor),
            presentations: manager
        ).register(on: app)

        try await app.testing().test(.PUT, "v2/profile-presentations/groups/room/nickname", headers: authenticatedHeaders(), beforeRequest: { request in
            try request.content.encode(NicknameMutationRequest(operationID: "operation", expectedRevision: 1, nickname: "值班"))
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
        }
        let request = try #require(await manager.nicknameUpdateRequest())
        #expect(request.actor == actor)
        #expect(request.room == room)
        #expect(request.expectedRevision?.rawValue == 1)
        #expect(request.nickname == "值班")
    }

    @Test("pagination and domain errors map to stable public statuses")
    func mapsValidationAndDomainErrors() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let owner = try UserID("owner")
        V2VaporProfilePresentationRoutes(
            authenticator: PresentationRouteAuthenticator(userID: owner),
            presentations: PresentationRouteManager(error: .forbidden)
        ).register(on: app)
        let tester = try app.testing()
        try await tester.test(.GET, "v2/profile-presentations/contact-aliases?limit=501", headers: authenticatedHeaders()) { response async in
            #expect(response.status == .badRequest)
        }
        try await tester.test(.GET, "v2/profile-presentations/contact-aliases", headers: authenticatedHeaders()) { response async in
            #expect(response.status == .forbidden)
        }
    }
}

private struct NicknameMutationRequest: Content {
    let operationID: String
    let expectedRevision: UInt64?
    let nickname: String?
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case expectedRevision = "expected_revision"
        case nickname
    }
}

private actor PresentationRouteManager: V2ProfilePresentationManaging {
    struct AliasListRequest: Sendable { let owner: UserID; let cursor: UserID?; let limit: Int }
    struct NicknameUpdateRequest: Sendable { let actor: UserID; let room: RoomID; let expectedRevision: V2ProfileRevision?; let nickname: String? }

    private let alias: V2ContactAlias?
    private let nickname: V2GroupMemberPresentation?
    private let error: V2ProfilePresentationError?
    private var aliasList: AliasListRequest?
    private var nicknameUpdate: NicknameUpdateRequest?

    init(alias: V2ContactAlias? = nil, nickname: V2GroupMemberPresentation? = nil, error: V2ProfilePresentationError? = nil) {
        self.alias = alias
        self.nickname = nickname
        self.error = error
    }
    func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) throws -> V2ContactAliasPage {
        if let error { throw error }
        aliasList = .init(owner: ownerUserID, cursor: afterTargetUserID, limit: limit)
        return .init(values: alias.map { [$0] } ?? [], nextCursor: afterTargetUserID)
    }
    func updateContactAlias(ownerUserID _: UserID, targetUserID _: UserID, operationID _: ContactAliasOperationID, expectedRevision _: V2ProfileRevision?, remarkName _: String?) throws -> V2ContactAlias {
        if let error { throw error }
        return try #require(alias)
    }
    func groupNicknames(actorUserID _: UserID, roomID _: RoomID, afterUserID _: UserID?, limit _: Int) throws -> V2GroupNicknamePage {
        if let error { throw error }
        return .init(values: nickname.map { [$0] } ?? [], nextCursor: nil)
    }
    func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID, operationID _: GroupNicknameOperationID, expectedRevision: V2ProfileRevision?, nickname: String?) throws -> V2GroupMemberPresentation {
        if let error { throw error }
        nicknameUpdate = .init(actor: actorUserID, room: roomID, expectedRevision: expectedRevision, nickname: nickname)
        return try #require(self.nickname)
    }
    func aliasListRequest() -> AliasListRequest? { aliasList }
    func nicknameUpdateRequest() -> NicknameUpdateRequest? { nicknameUpdate }
}

private struct PresentationRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) -> V2GatewayAuthentication {
        .init(userID: userID, expiresAt: nil)
    }
}

private func authenticatedHeaders() -> HTTPHeaders {
    ["Authorization": "Bearer access-token", "X-IM-Device-ID": "device"]
}
