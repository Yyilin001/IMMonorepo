import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 profile update routes")
struct V2VaporProfileUpdateRoutesTests {
    @Test("profile writes require credentials, retain the revision fence, and return no-store")
    func updatesProfile() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor = try UserID("00000000-0000-0000-0000-000000000811")
        let view = try updateFixtureProfile(userID: actor, revision: 2)
        let profiles = ProfileUpdateRouteStore(snapshot: view)
        V2VaporProfileUpdateRoutes(
            authenticator: ProfileUpdateRouteAuthenticator(userID: actor),
            profiles: .init(store: profiles, reader: profiles)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.put, to: "v2/profile/me", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000812"
            try request.content.encode(V2ProfileUpdateHTTPRequest(
                operationID: "00000000-0000-0000-0000-000000000813",
                expectedRevision: 1,
                patch: .init(displayName: .set("更新后名称")),
                firstSubmissionDeadlineMilliseconds: 4_000_000_000_000
            ))
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            let body = try await response.content.decode(V2ProfileUpdateResult.self)
            #expect(body.currentSnapshot?.publicIdentity?.displayName == "资料名称")
            #expect(body.receipt.outcome == .committed(revision: try #require(V2ProfileRevision(rawValue: 2)), visibilityRevision: try #require(V2ProfileRevision(rawValue: 2))))
        }
    }

    @Test("revision conflict returns an authoritative rejection receipt")
    func reportsConflict() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor = try UserID("00000000-0000-0000-0000-000000000821")
        let currentRevision = try #require(V2ProfileRevision(rawValue: 9))
        let profiles = ProfileUpdateRouteStore(snapshot: try updateFixtureProfile(userID: actor, revision: 9), rejection: .revisionConflict(current: currentRevision))
        V2VaporProfileUpdateRoutes(
            authenticator: ProfileUpdateRouteAuthenticator(userID: actor),
            profiles: .init(store: profiles, reader: profiles)
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.put, to: "v2/profile/me", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: "access-token")
            request.headers[HTTPField.Name("X-IM-Device-ID")!] = "00000000-0000-0000-0000-000000000822"
            try request.content.encode(V2ProfileUpdateHTTPRequest(
                operationID: "00000000-0000-0000-0000-000000000823",
                expectedRevision: 1,
                patch: .init(displayName: .set("冲突名称")),
                firstSubmissionDeadlineMilliseconds: 4_000_000_000_000
            ))
        })
            #expect(response.status == .ok)
            let body = try await response.content.decode(V2ProfileUpdateResult.self)
            #expect(body.receipt.outcome == .rejected(.revisionConflict(current: currentRevision)))
        }
    }
    @Test("own-profile reads and unresolved recovery use the Core wire contract with no-store")
    func readsAndRecovery() async throws {
        let app=try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor=UserID(uuid:UUID()), snapshot=try updateFixtureProfile(userID:actor,revision:3)
        let store=ProfileUpdateRouteStore(snapshot:snapshot)
        V2VaporProfileUpdateRoutes(authenticator:ProfileUpdateRouteAuthenticator(userID:actor),profiles:.init(store:store,reader:store)).register(on:app)
        try await app.testing { client in
            let read=try await client.send(.get,to:"v2/profile/me",beforeSend:{ request in
                request.headers.bearerAuthorization = .init(token:"access-token")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
            })
            #expect(try await read.content.decode(V2ProfileView.self) == snapshot)
            #expect(read.headers[.cacheControl] == "no-store")
            let fingerprint=try V2OperationFingerprint(kind:.profileUpdate,fields:[.init("field",.text("name"))])
            let recovery=try await client.send(.post,to:"v2/profile/me/operations/recover",beforeSend:{ request in
                request.headers.bearerAuthorization = .init(token:"access-token")
                request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                try request.content.encode(V2ProfileOperationRecoveryHTTPRequest(operationID:UUID().uuidString,fingerprint:fingerprint,action:.query))
            })
            #expect(recovery.status == .ok)
            #expect(recovery.headers[.cacheControl] == "no-store")
            #expect(try await recovery.content.decode(V2ProfileOperationRecoveryResult.self) == .unresolved)
        }
    }

}

private struct ProfileUpdateRouteAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        guard accessToken == "access-token" else { throw ProfileUpdateRouteTestError.denied }
        return .init(userID: userID, expiresAt: nil)
    }
}

private actor ProfileUpdateRouteStore: V2ProfileUpdateStore, V2OwnProfileReading {
    let snapshot: V2ProfileView
    let rejection: V2ProfileOperationRejection?
    init(snapshot: V2ProfileView, rejection: V2ProfileOperationRejection? = nil) { self.snapshot=snapshot; self.rejection=rejection }
    func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult {
        let outcome: V2ProfileOperationTerminalOutcome = rejection.map { .rejected($0) } ?? .committed(revision:snapshot.revision,visibilityRevision:snapshot.visibilityRevision)
        return try .init(receipt:.init(actorUserID:command.actorUserID,operationID:command.operationID,fingerprint:command.fingerprint,outcome:outcome,resolvedAtMilliseconds:1000),currentSnapshot:snapshot)
    }
    func recover(_ request:V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult { .unresolved }
    func currentProfile(for _:UserID) async throws -> V2ProfileView { snapshot }
}

private func updateFixtureProfile(userID: UserID, revision: UInt64) throws -> V2ProfileView {
    try .init(
        userID: userID,
        publicIdentity: .init(userID: userID, handle: .init("profile_user"), displayName: "资料名称", accountKind: .regular),
        avatar: nil,
        state: .active,
        revision: try #require(V2ProfileRevision(rawValue: revision)),
        visibilityRevision: try #require(V2ProfileRevision(rawValue: revision))
    )
}

private enum ProfileUpdateRouteTestError: Error { case denied }
