import Testing
@testable import IMV2Core

struct SyncFenceTests {
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
