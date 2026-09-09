import Testing
@testable import IMV2Core

struct SyncFenceTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func positionPersistenceBounds(generation: UInt64, sequence: UInt64) throws {
        if generation == 0 || generation > UInt64(Int64.max) {
            #expect(throws: V2CoreError.invalidGeneration) { _ = try SyncPosition(generation: generation, sequence: sequence) }
        } else if sequence > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try SyncPosition(generation: generation, sequence: sequence) }
        } else {
            let position = try SyncPosition(generation: generation, sequence: sequence)
            #expect(position.generation == generation)
            #expect(position.sequence == sequence)
        }
    }

    @Test("opaque sync capabilities reject blank values")
    func opaqueCapabilitiesRejectBlankValues() {
        #expect(throws: V2CoreError.invalidIdentifier) { _ = try V2SyncToken(" ") }
        #expect(throws: V2CoreError.invalidIdentifier) { _ = try V2SyncReceipt("") }
    }
    @Test
    func matchingSnapshotAcknowledgementMovesOnlyThePendingGeneration() throws {
        var cursor = DeviceSyncCursor(readyAt: try SyncPosition(generation: 1, sequence: 8))
        let snapshot = PendingReset(
            snapshotID: try SnapshotID("snapshot-1"),
            basePosition: try SyncPosition(generation: 2, sequence: 42)
        )
        try cursor.beginReset(snapshot)

        let result = cursor.acknowledgeSnapshot(
            snapshotID: try SnapshotID("snapshot-1"),
            basePosition: try SyncPosition(generation: 2, sequence: 42)
        )

        #expect(result == .accepted(nextPosition: try SyncPosition(generation: 2, sequence: 42)))
        #expect(cursor.state == .ready(try SyncPosition(generation: 2, sequence: 42)))
    }

    @Test
    func staleSnapshotAcknowledgementCannotAdvanceCursor() throws {
        var cursor = DeviceSyncCursor(readyAt: try SyncPosition(generation: 1, sequence: 8))
        let pending = PendingReset(
            snapshotID: try SnapshotID("snapshot-2"),
            basePosition: try SyncPosition(generation: 2, sequence: 42)
        )
        try cursor.beginReset(pending)

        let result = cursor.acknowledgeSnapshot(
            snapshotID: try SnapshotID("old-snapshot"),
            basePosition: try SyncPosition(generation: 2, sequence: 42)
        )

        #expect(result == .rejected(.snapshotMismatch))
        #expect(cursor.state == .resetPending(pending))
    }
}
