import Foundation
import IMV2Core
import Testing
@testable import IMV2Server

struct V2UserShardMigrationTests {
    @Test("cutover requires verified copy and rollback ends at cleanup boundary")
    func enforcesMigrationOrdering() throws {
        #expect(throws: V2UserShardMigrationError.invalidTransition) {
            try V2UserShardMigrationStateMachine.transition(from: .prepared, by: .cutOver)
        }
        var phase: V2UserShardMigrationPhase = .prepared
        for action in [.beginCopy, .copySucceeded, .beginVerification, .verificationSucceeded, .forwardingVerificationSucceeded, .cutOver, .beginRetention] as [V2UserShardMigrationAction] {
            phase = try V2UserShardMigrationStateMachine.transition(from: phase, by: action)
        }
        #expect(try V2UserShardMigrationStateMachine.transition(from: phase, by: .rollback) == .rolledBack)
        #expect(throws: V2UserShardMigrationError.invalidTransition) {
            try V2UserShardMigrationStateMachine.transition(from: .completed, by: .rollback)
        }
    }

    @Test("durable coordinator fences each phase and retains only a bounded failure code")
    func durableCoordinatorPersistsVerifiedOrFailedState() async throws {
        let user = try UserID("00000000-0000-0000-0000-000000000992")
        let migration = V2UserShardMigrationRecord(
            migrationID: UUID(), userID: user, sourceBucket: "users-a", targetBucket: "users-b",
            sourceRouterEpoch: 2, phase: .prepared, sourceFingerprint: nil, targetFingerprint: nil
        )
        let store = MigrationStoreFake(record: migration)
        let coordinator = V2DurableUserShardMigrationCoordinator(
            store: store, copier: CopyFake(), verifier: VerifyFake(values: ("digest", "digest")),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let forwarding = try await coordinator.copyThenVerify(migrationID: migration.migrationID)
        #expect(forwarding.phase == .forwarding)
        let verified = try await coordinator.verifyForwarding(migrationID: migration.migrationID)
        #expect(verified.phase == .verified)
        #expect(verified.sourceFingerprint == "digest")
        #expect(verified.verifiedAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(verified.lastErrorCode == nil)

        let failedMigration = V2UserShardMigrationRecord(
            migrationID: UUID(), userID: try UserID("00000000-0000-0000-0000-000000000993"),
            sourceBucket: "users-a", targetBucket: "users-b", sourceRouterEpoch: 2,
            phase: .prepared, sourceFingerprint: nil, targetFingerprint: nil
        )
        let failedStore = MigrationStoreFake(record: failedMigration)
        await #expect(throws: V2UserShardMigrationVerificationError.fingerprintMismatch) {
            try await V2DurableUserShardMigrationCoordinator(
                store: failedStore, copier: CopyFake(), verifier: VerifyFake(values: ("left", "right"))
            ).copyThenVerify(migrationID: failedMigration.migrationID)
        }
        let failed = try #require(await failedStore.snapshot())
        #expect(failed.phase == .failed)
        #expect(failed.lastErrorCode == .fingerprintMismatch)
    }

    @Test("retention cleanup is lease-fenced and leaves a failed cleanup retryable")
    func retentionWorkerCompletesOnlyAfterCleanup() async throws {
        let record = V2UserShardMigrationRecord(
            migrationID: UUID(), userID: try UserID("00000000-0000-0000-0000-000000000994"),
            sourceBucket: "users-a", targetBucket: "users-b", sourceRouterEpoch: 3,
            phase: .retention, sourceFingerprint: "digest", targetFingerprint: "digest",
            verifiedAt: Date(timeIntervalSince1970: 1_750_000_000),
            retentionUntil: Date(timeIntervalSince1970: 1_750_000_010)
        )
        let clock = Date(timeIntervalSince1970: 1_750_000_020)
        let store = RetentionStoreFake(record: record)
        let report = try await V2UserShardMigrationRetentionWorker(
            store: store, cleaner: RetentionCleanerFake(), now: { clock }
        ).runOnce(limit: 1)
        #expect(report == .init(claimedCount: 1, completedCount: 1, failedCount: 0))
        #expect(await store.snapshot()?.phase == .completed)

        let failedStore = RetentionStoreFake(record: record)
        let failed = try await V2UserShardMigrationRetentionWorker(
            store: failedStore, cleaner: RetentionCleanerFake(shouldFail: true), now: { clock }
        ).runOnce(limit: 1)
        #expect(failed == .init(claimedCount: 1, completedCount: 0, failedCount: 1))
        #expect(await failedStore.snapshot()?.phase == .retention)
    }
}

private struct CopyFake: V2UserShardMigrationCopying { func copy(_: V2UserShardMigrationRecord) async throws {} }
private struct VerifyFake: V2UserShardMigrationVerifying {
    let values: (source: String, target: String)
    func fingerprints(for _: V2UserShardMigrationRecord) async throws -> (source: String, target: String) { values }
}

private actor MigrationStoreFake: V2UserShardMigrationStoring {
    private var value: V2UserShardMigrationRecord

    init(record: V2UserShardMigrationRecord) { value = record }

    func prepare(_: V2UserShardMigrationPreparation, now _: Date) async throws -> V2UserShardMigrationRecord { value }
    func load(migrationID: UUID) async throws -> V2UserShardMigrationRecord? {
        value.migrationID == migrationID ? value : nil
    }
    func load(userID: UserID) async throws -> V2UserShardMigrationRecord? {
        value.userID == userID ? value : nil
    }

    func advance(
        migrationID: UUID, expectedPhase: V2UserShardMigrationPhase, action: V2UserShardMigrationAction,
        fingerprints: (source: String, target: String)?, now: Date
    ) async throws -> V2UserShardMigrationRecord {
        guard value.migrationID == migrationID else { throw V2UserShardMigrationStoreError.recordNotFound }
        guard value.phase == expectedPhase else { throw V2UserShardMigrationStoreError.phaseConflict }
        let next = try V2UserShardMigrationStateMachine.transition(from: value.phase, by: action)
        value = .init(
            migrationID: value.migrationID, userID: value.userID, sourceBucket: value.sourceBucket, targetBucket: value.targetBucket,
            sourceRouterEpoch: value.sourceRouterEpoch, phase: next,
            sourceFingerprint: fingerprints?.source ?? value.sourceFingerprint,
            targetFingerprint: fingerprints?.target ?? value.targetFingerprint,
            verifiedAt: action == .verificationSucceeded ? now : value.verifiedAt
        )
        return value
    }

    func fail(
        migrationID: UUID, expectedPhase: V2UserShardMigrationPhase,
        code: V2UserShardMigrationFailureCode, now _: Date
    ) async throws -> V2UserShardMigrationRecord {
        guard value.migrationID == migrationID else { throw V2UserShardMigrationStoreError.recordNotFound }
        guard value.phase == expectedPhase else { throw V2UserShardMigrationStoreError.phaseConflict }
        value = .init(
            migrationID: value.migrationID, userID: value.userID, sourceBucket: value.sourceBucket, targetBucket: value.targetBucket,
            sourceRouterEpoch: value.sourceRouterEpoch,
            phase: try V2UserShardMigrationStateMachine.transition(from: value.phase, by: .fail),
            sourceFingerprint: value.sourceFingerprint, targetFingerprint: value.targetFingerprint,
            verifiedAt: value.verifiedAt, lastErrorCode: code
        )
        return value
    }

    func snapshot() -> V2UserShardMigrationRecord? { value }
}

private actor RetentionStoreFake: V2UserShardMigrationRetentionStoring {
    private var value: V2UserShardMigrationRecord
    private let token = UUID(uuidString: "00000000-0000-0000-0000-000000000995")!
    private var claimed = false

    init(record: V2UserShardMigrationRecord) { value = record }

    func claimExpiredRetention(now: Date, leaseDuration _: TimeInterval, limit: Int) async throws -> [V2UserShardMigrationRetentionLease] {
        guard limit > 0, !claimed, value.phase == .retention, value.retentionUntil! <= now else { return [] }
        claimed = true
        return [.init(record: value, claimToken: token)]
    }

    func completeRetention(_ lease: V2UserShardMigrationRetentionLease, now _: Date) async throws -> Bool {
        guard claimed, lease.claimToken == token, lease.record.migrationID == value.migrationID else { return false }
        value = .init(
            migrationID: value.migrationID, userID: value.userID, sourceBucket: value.sourceBucket, targetBucket: value.targetBucket,
            sourceRouterEpoch: value.sourceRouterEpoch, phase: .completed,
            sourceFingerprint: value.sourceFingerprint, targetFingerprint: value.targetFingerprint,
            verifiedAt: value.verifiedAt, lastErrorCode: value.lastErrorCode,
            cutoverOperationID: value.cutoverOperationID, retentionUntil: value.retentionUntil
        )
        return true
    }

    func snapshot() -> V2UserShardMigrationRecord? { value }
}

private struct RetentionCleanerFake: V2UserShardMigrationRetentionCleaning {
    let shouldFail: Bool
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    struct Failure: Error {}
    func cleanSource(for _: V2UserShardMigrationRecord) async throws {
        if shouldFail { throw Failure() }
    }
}
