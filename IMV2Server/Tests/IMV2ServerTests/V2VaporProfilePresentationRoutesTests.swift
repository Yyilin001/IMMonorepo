import IMV2ServerApplication
import IMV2ServerContracts
import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor profile presentation routes")
struct V2VaporProfilePresentationRoutesTests {
    @Test("nickname lists never fall back to the raw manager without authorized profile assembly")
    func nicknameReadFailsClosed() async throws {
        let app = try await Application(.testing), actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let manager = PresentationRouteManager(nickname: try .init(roomID: room, userID: actor,
            groupNickname: "Must remain private", revision: #require(.init(rawValue: 1))))
        do {
            V2VaporProfilePresentationRoutes(authenticator: PresentationRouteAuthenticator(userID: actor),
                presentations: manager).register(on: app)
            try await app.testing { client in
                let path = "v2/profile-presentations/groups/\(room.rawValue)/nicknames"
                let response = try await client.send(.get, headers: authenticatedHeaders(), to: URI(string: path))
                #expect(response.status == .serviceUnavailable)
                #expect(try await response.body.string()?.contains("Must remain private") == false)
                for invalid in ["0", "101", "500", "abc", "1.5"] {
                    let result = try await client.send(.get, headers: authenticatedHeaders(), to: URI(string: path + "?limit=" + invalid))
                    #expect(result.status == .badRequest)
                }
            }
            #expect(await manager.nicknameReads == 0)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("contact aliases are scoped to the authenticated owner and disable caching")
    func contactAliasesUseAuthenticatedOwner() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
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

        try await app.testing { client in
            let response = try await client.send(.get, headers: authenticatedHeaders(), to: "v2/profile-presentations/contact-aliases?cursor=target&limit=20")
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            let body = try await response.body.string() ?? ""
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
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor = UserID(uuid: UUID())
        let room = RoomID(uuid: UUID())
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

        try await app.testing { client in
            let response = try await client.send(.put, headers: authenticatedHeaders(), to: URI(string: "v2/profile-presentations/groups/\(room.rawValue)/nickname"), beforeSend: { request in
            request.body = .init(data: try JSONEncoder().encode(V2GroupNicknameUpdateCommand(actorUserID: actor, roomID: room, operationID: GroupNicknameOperationID(uuid: UUID()), expectedRevision: .init(rawValue: 1), nickname: "值班", firstSubmissionDeadlineMilliseconds: 1000)))
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
        }
        let request = try #require(await manager.nicknameUpdateRequest())
        #expect(request.actor == actor)
        #expect(request.room == room)
        #expect(request.expectedRevision?.rawValue == 1)
        #expect(request.nickname == "值班")
    }

    @Test("single-target edit baselines and recovery use typed scoped contracts")
    func typedBaselinesAndRecovery() async throws {
        let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let app = try await Application(.testing)
        do {
            V2VaporProfilePresentationRoutes(authenticator: PresentationRouteAuthenticator(userID: actor),
                presentations: PresentationRouteManager()).register(on: app)
            try await app.testing { client in
                for path in ["v2/profile-presentations/contact-aliases/\(target.rawValue)",
                    "v2/profile-presentations/groups/\(room.rawValue)/nickname"] {
                    let response = try await client.send(.get, headers: authenticatedHeaders(), to: URI(string:path))
                    #expect(response.status == .ok && response.headers[.cacheControl] == "no-store")
                }
                let c = try V2ContactAliasUpdateCommand(ownerUserID: actor, targetUserID: target,
                    operationID: .init(uuid: UUID()), expectedRevision: nil, remarkName: nil,
                    firstSubmissionDeadlineMilliseconds: 1000)
                let request = try V2ContactAliasRecoveryRequest(identity:c.identity, fingerprint:c.fingerprint, action:.query)
                let response = try await client.send(.post, headers: authenticatedHeaders(),
                    to: URI(string:"v2/profile-presentations/contact-aliases/\(target.rawValue)/operations/recover"), beforeSend: { wire in
                        wire.body = .init(data:try JSONEncoder().encode(request))
                    })
                #expect(response.status == .ok && response.headers[.cacheControl] == "no-store")
                let mismatched = try await client.send(.post, headers:authenticatedHeaders(),
                    to:URI(string:"v2/profile-presentations/contact-aliases/\(actor.rawValue)/operations/recover"), beforeSend:{ wire in
                        wire.body = .init(data:try JSONEncoder().encode(request))
                    })
                #expect(mismatched.status == .forbidden)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("pagination and domain errors map to stable public statuses")
    func mapsValidationAndDomainErrors() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let owner = try UserID("owner")
        V2VaporProfilePresentationRoutes(
            authenticator: PresentationRouteAuthenticator(userID: owner),
            presentations: PresentationRouteManager(error: .forbidden)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.get, headers: authenticatedHeaders(), to: "v2/profile-presentations/contact-aliases?limit=501")
            #expect(response.status == .badRequest)
        }
        try await app.testing { client in
            let response = try await client.send(.get, headers: authenticatedHeaders(), to: "v2/profile-presentations/contact-aliases")
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
    private var aliasUpdates = 0
    private(set) var nicknameReads = 0
    func aliasUpdateCount() -> Int { aliasUpdates }

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
    func updateContactAlias(_ command: V2ContactAliasUpdateCommand) throws -> V2ContactAliasUpdateReceipt {
        aliasUpdates += 1
        if let error { throw error }
        return try .init(identity: command.identity, fingerprint: command.fingerprint, outcome: .committed(#require(alias)), resolvedAtMilliseconds: 1)
    }
    func contactAliasSnapshot(ownerUserID: UserID, targetUserID: UserID) throws -> V2ContactAliasSnapshot { if let error { throw error }; return try .init(ownerUserID: ownerUserID, targetUserID: targetUserID, value: alias) }
    func recoverContactAlias(_ request: V2ContactAliasRecoveryRequest) -> V2ContactAliasRecoveryResult { .unresolved }
    func groupNicknames(actorUserID _: UserID, roomID _: RoomID, afterUserID _: UserID?, limit _: Int) throws -> V2GroupNicknamePage {
        nicknameReads += 1
        if let error { throw error }
        return .init(values: nickname.map { [$0] } ?? [], nextCursor: nil)
    }
    func updateOwnGroupNickname(_ command: V2GroupNicknameUpdateCommand) throws -> V2GroupNicknameUpdateReceipt {
        if let error { throw error }
        nicknameUpdate = .init(actor: command.actorUserID, room: command.roomID, expectedRevision: command.expectedRevision, nickname: command.nickname)
        return try .init(identity: command.identity, fingerprint: command.fingerprint, outcome: .committed(#require(self.nickname)), resolvedAtMilliseconds: 1)
    }
    func ownGroupNicknameSnapshot(actorUserID: UserID, roomID: RoomID) throws -> V2GroupNicknameSnapshot { if let error { throw error }; return try .init(actorUserID: actorUserID, roomID: roomID, value: nickname) }
    func recoverGroupNickname(_ request: V2GroupNicknameRecoveryRequest) -> V2GroupNicknameRecoveryResult { .unresolved }
    func aliasListRequest() -> AliasListRequest? { aliasList }
    func nicknameUpdateRequest() -> NicknameUpdateRequest? { nicknameUpdate }
}

private struct PresentationRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) -> V2GatewayAuthentication {
        .init(userID: userID, expiresAt: nil)
    }
}

private func authenticatedHeaders() -> HTTPFields {
    [.authorization: "Bearer access-token", HTTPField.Name("X-IM-Device-ID")!: "device"]
}

private struct AliasMutationRequest: Content {
    let operationID: String
    let expectedRevision: UInt64?
    let remarkName: String?
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", expectedRevision = "expected_revision", remarkName = "remark_name"
    }
}
