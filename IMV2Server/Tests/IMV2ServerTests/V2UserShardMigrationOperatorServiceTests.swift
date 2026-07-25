import Foundation
@testable import IMV2Server
import Testing

struct V2UserShardMigrationOperatorServiceTests {
    @Test("forwarding copy is idempotent, final verification is explicit, and in-flight work is fenced")
    func fencesAndReusesDurableState() async throws {
        let request = try V2UserShardMigrationPreparation(
            migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000971")!,
            userID: .init("00000000-0000-0000-0000-000000000972"),
            sourceBucket: "users-a", targetBucket: "users-b", sourceRouterEpoch: 4
        )
        let forwarding = record(request, phase: .forwarding)
        let forwardingStore = MigrationStoreFake(value: forwarding)
        let forwardingService = V2UserShardMigrationOperatorService(
            store: forwardingStore, executor: MigrationExecutorFake(result: forwarding)
        )
        let idempotent = try await forwardingService.prepareCopyAndVerify(request)
        #expect(idempotent.wasIdempotent)
        #expect(await forwardingStore.prepareCount == 1)

        let verified = record(request, phase: .verified)
        let finalService = V2UserShardMigrationOperatorService(
            store: MigrationStoreFake(value: forwarding), executor: MigrationExecutorFake(result: verified)
        )
        let finalized = try await finalService.verifyForwarding(migrationID: request.migrationID)
        #expect(!finalized.wasIdempotent)
        #expect(finalized.record.phase == .verified)
        let verifiedService = V2UserShardMigrationOperatorService(
            store: MigrationStoreFake(value: verified), executor: MigrationExecutorFake(result: verified)
        )
        #expect(try await verifiedService.verifyForwarding(migrationID: request.migrationID).wasIdempotent)

        let inFlightStore = MigrationStoreFake(value: record(request, phase: .copying))
        let inFlightService = V2UserShardMigrationOperatorService(
            store: inFlightStore, executor: MigrationExecutorFake(result: verified)
        )
        await #expect(throws: V2UserShardMigrationOperatorError.inProgress) {
            try await inFlightService.prepareCopyAndVerify(request)
        }
    }

    @Test("prepared migration invokes the single physical executor")
    func executesPreparedMigration() async throws {
        let request = try V2UserShardMigrationPreparation(
            migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000973")!,
            userID: .init("00000000-0000-0000-0000-000000000974"),
            sourceBucket: "users-a", targetBucket: "users-b", sourceRouterEpoch: 9
        )
        let forwarding = record(request, phase: .forwarding)
        let executor = MigrationExecutorFake(result: forwarding)
        let service = V2UserShardMigrationOperatorService(
            store: MigrationStoreFake(value: record(request, phase: .prepared)), executor: executor
        )
        let result = try await service.prepareCopyAndVerify(request)
        #expect(!result.wasIdempotent)
        #expect(await executor.migrationIDs == [request.migrationID])
    }

    private func record(_ request: V2UserShardMigrationPreparation, phase: V2UserShardMigrationPhase) -> V2UserShardMigrationRecord {
        .init(
            migrationID: request.migrationID, userID: request.userID, sourceBucket: request.sourceBucket,
            targetBucket: request.targetBucket, sourceRouterEpoch: request.sourceRouterEpoch, phase: phase,
            sourceFingerprint: phase == .verified ? "a" : nil, targetFingerprint: phase == .verified ? "a" : nil
        )
    }
}

private actor MigrationStoreFake: V2UserShardMigrationStoring {
    let value: V2UserShardMigrationRecord
    private(set) var prepareCount = 0

    init(value: V2UserShardMigrationRecord) { self.value = value }
    func prepare(_: V2UserShardMigrationPreparation, now _: Date) throws -> V2UserShardMigrationRecord { prepareCount += 1; return value }
    func load(migrationID _: UUID) throws -> V2UserShardMigrationRecord? { value }
    func advance(migrationID _: UUID, expectedPhase _: V2UserShardMigrationPhase, action _: V2UserShardMigrationAction, fingerprints _: (source: String, target: String)?, now _: Date) throws -> V2UserShardMigrationRecord { value }
    func fail(migrationID _: UUID, expectedPhase _: V2UserShardMigrationPhase, code _: V2UserShardMigrationFailureCode, now _: Date) throws -> V2UserShardMigrationRecord { value }
}

private actor MigrationExecutorFake: V2UserShardMigrationExecuting {
    let result: V2UserShardMigrationRecord
    private(set) var migrationIDs: [UUID] = []

    init(result: V2UserShardMigrationRecord) { self.result = result }
    func copyThenVerify(migrationID: UUID) -> V2UserShardMigrationRecord { migrationIDs.append(migrationID); return result }
    func verifyForwarding(migrationID: UUID) -> V2UserShardMigrationRecord { migrationIDs.append(migrationID); return result }
}
