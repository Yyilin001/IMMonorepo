import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 actor administration executor")
struct V2ActorAdministrationExecutorTests {
    private struct IdentityReader: V2MembershipIdentitySnapshotValidating {
        func snapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2MembershipIdentitySnapshot {
            .init(actorUserID: actorUserID, targetUserID: targetUserID,
                  actorIsActive: true, targetIsActive: true)
        }
    }

    @Test func commandIsBoundToGrantedRoomAndTrustedLaneIsClosed() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://invalid:invalid@127.0.0.1:1/unreachable", maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID())
        let actor = UserID(uuid: UUID())
        let token = V2RoomActivationToken(roomID: room,
            owner: try .init(shardID: "owner", epoch: 0), activationEpoch: try .init(1),
            host: .init(hostID: try .init("host"), incarnationID: UUID()))
        let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10,
            maxCommandsPerWindow: 10, retryAfterSeconds: 3))
        let executor = try V2RoomAdministrationDomainExecutor(database: resources.database(.psql),
            token: token, capacityProfile: profile, membershipIdentities: IdentityReader())
        let foreign = V2RoomAdministrationCommand.groupNickname(.init(roomID: otherRoom,
            actorUserID: actor, operationID: .init(uuid: UUID()), expectedRevision: nil, nickname: "Alice"))
        await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
            _ = try await executor.executeUser(foreign)
        }
        let trusted = V2RoomAdministrationCommand.trustedSafety(.init(roomID: room,
            operationID: .init(uuid: UUID()), action: .freezeRoom,
            messageID: nil, expectedMessageRevision: nil, reasonCode: "review"))
        await #expect(throws: V2ActorAdministrationWireError.trustedActionOnUserLane) {
            _ = try await executor.executeUser(trusted)
        }
        let query = V2RoomAdministrationQuery.groupNicknames(.init(roomID: otherRoom,
            actorUserID: actor, afterUserID: nil, limit: 10))
        await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
            _ = try await executor.execute(query)
        }
        try await resources.shutdown()
    }

    @Test func typedFailuresRoundTripWithoutStringFallback() throws {
        let failures: [V2ActorAdministrationFailureWire] = [
            .membership(.targetUnavailable), .groupCapability(.messageWithdrawn),
            .moderation(.actorNotAuthorized), .profile(.revisionConflict(current: 3)),
            .activation(.leaseExpired), .outcomeUnknown, .input(.invalidReasonCode)
        ]
        for failure in failures {
            let decoded = try JSONDecoder().decode(V2ActorAdministrationFailureWire.self,
                from: JSONEncoder().encode(failure))
            #expect(decoded == failure)
            let domain = try decoded.domainError()
            #expect(V2ActorAdministrationFailureWire(domainError: domain) == failure)
        }
        #expect(V2ActorAdministrationFailureWire(domainError: CancellationError()) == nil)
        #expect(throws: V2RevisionValidationError.outOfRange) {
            _ = try V2ActorAdministrationFailureWire.profile(.revisionConflict(current: UInt64.max)).domainError()
        }
    }
}
