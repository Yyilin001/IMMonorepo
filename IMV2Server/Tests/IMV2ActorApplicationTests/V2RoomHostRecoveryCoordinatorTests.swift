import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorApplication

@Suite("Host exclusion and database settlement ordering")
struct V2RoomHostRecoveryCoordinatorTests {
    private actor Trace {
        var events: [String] = []
        func append(_ value: String) { events.append(value) }
    }
    private enum Failure: Error { case unavailable }

    @Test("Partial registration permits untouched retired shards, never stale active owners")
    func partialRegistrationBoundary() {
        for existing in [false, true] {
            for retired in [false, true] {
                #expect(!V2RoomHostRecoveryCoordinator.permitsDifferentRegistration(
                    existingOperation: existing, registrationRetired: retired, hasReferences: true))
            }
        }
        #expect(V2RoomHostRecoveryCoordinator.permitsDifferentRegistration(
            existingOperation: false, registrationRetired: true, hasReferences: false))
        #expect(!V2RoomHostRecoveryCoordinator.permitsDifferentRegistration(
            existingOperation: false, registrationRetired: false, hasReferences: false))
        #expect(V2RoomHostRecoveryCoordinator.permitsDifferentRegistration(
            existingOperation: true, registrationRetired: false, hasReferences: false))
    }

    @Test("No proof before irreversible exclusion and complete database settlement")
    func recoveryProofFailClosed() async throws {
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let operation = UUID(), shards: Set<String> = ["a", "b"]
        let targets = ["a": "a", "b": "b"]
        let deadline = ContinuousClock.now + .seconds(5)
        let trace = Trace()
        let proof = try await V2RoomHostRecoveryCoordinator.prepareProof(host: host,
            operationID: operation, requiredShards: shards, shardDatabaseTargets: targets, availableDatabaseTargets: shards, deadline: deadline,
            exclude: { await trace.append("excluded") }, settle: { await trace.append($0) })
        #expect(await trace.events == ["excluded", "a", "b"])
        #expect(proof.host == host && proof.operationID == operation && proof.settledShardIDs == shards)

        let shared = Trace()
        _ = try await V2RoomHostRecoveryCoordinator.prepareProof(host: host,
            operationID: operation, requiredShards: shards, shardDatabaseTargets: ["a": "owner", "b": "owner"],
            availableDatabaseTargets: ["owner", "control"], deadline: deadline,
            exclude: { await shared.append("excluded") }, settle: { await shared.append($0) })
        #expect(await shared.events == ["excluded", "control", "owner"])

        let missing = Trace()
        await #expect(throws: V2RoomHostRecoveryError.incompleteDatabaseCoverage) {
            try await V2RoomHostRecoveryCoordinator.prepareProof(host: host,
                operationID: operation, requiredShards: shards, shardDatabaseTargets: targets, availableDatabaseTargets: ["a"], deadline: deadline,
                exclude: { await missing.append("excluded") }, settle: { await missing.append($0) })
        }
        #expect(await missing.events.isEmpty)

        let excluded = Trace()
        await #expect(throws: Failure.self) {
            try await V2RoomHostRecoveryCoordinator.prepareProof(host: host,
                operationID: operation, requiredShards: shards, shardDatabaseTargets: targets, availableDatabaseTargets: shards, deadline: deadline,
                exclude: { throw Failure.unavailable }, settle: { await excluded.append($0) })
        }
        #expect(await excluded.events.isEmpty)

        let partial = Trace()
        await #expect(throws: Failure.self) {
            try await V2RoomHostRecoveryCoordinator.prepareProof(host: host,
                operationID: operation, requiredShards: shards, shardDatabaseTargets: targets, availableDatabaseTargets: shards, deadline: deadline,
                exclude: { await partial.append("excluded") }, settle: {
                    await partial.append($0)
                    if $0 == "a" { throw Failure.unavailable }
                })
        }
        #expect(await partial.events == ["excluded", "a"])

        let expired = Trace()
        await #expect(throws: V2RoomHostRecoveryError.deadlineExceeded) {
            try await V2RoomHostRecoveryCoordinator.prepareProof(host: host,
                operationID: operation, requiredShards: shards, shardDatabaseTargets: targets, availableDatabaseTargets: shards, deadline: .now,
                exclude: { await expired.append("excluded") }, settle: { await expired.append($0) })
        }
        #expect(await expired.events.isEmpty)
    }
}
