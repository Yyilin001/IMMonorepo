import Testing
@testable import IMV2LoadGeneratorSupport

struct V2LoadCompletionPolicyTests {
    @Test func sendAcknowledgementAloneCannotCompleteReceiverMeasurement() {
        #expect(!V2LoadCompletionPolicy.receiverComplete(sent: 100, acknowledged: 100, observed: 99))
        #expect(!V2LoadCompletionPolicy.receiverComplete(sent: 100, acknowledged: 99, observed: 100))
        #expect(!V2LoadCompletionPolicy.receiverComplete(sent: 100, acknowledged: 100, observed: 101))
        #expect(V2LoadCompletionPolicy.receiverComplete(sent: 100, acknowledged: 100, observed: 100))
    }
    @Test func readinessIsAlwaysRequiredAndCursorProofFollowsWorkload() {
        #expect(!V2LoadCompletionPolicy.scopePassed(ready: false, requiresAppliedCursor: false, appliedCursor: 0, highWatermark: 2))
        #expect(V2LoadCompletionPolicy.scopePassed(ready: true, requiresAppliedCursor: false, appliedCursor: 0, highWatermark: 2))
        #expect(!V2LoadCompletionPolicy.scopePassed(ready: true, requiresAppliedCursor: true, appliedCursor: 1, highWatermark: 2))
        #expect(V2LoadCompletionPolicy.scopePassed(ready: true, requiresAppliedCursor: true, appliedCursor: 2, highWatermark: 2))
    }
    @Test func saturatedReceiptsRequestRecoveryWithoutInventingPeerProgress() throws {
        var tracker = V2LoadRoomAcceptedSequences(maximumPending: 2)
        _ = tracker.record(2, after: 0)
        _ = tracker.record(4, after: 0)
        guard case .recoveryRequired(let target) = tracker.record(6, after: 0) else {
            Issue.record("Expected bounded recovery instead of a transport error"); return
        }
        #expect(target == 6)
        #expect(tracker.pendingCount == 2)
        #expect(tracker.applied(through: 0).cursor == 0)
        #expect(tracker.applied(through: 1).cursor == 2)
        #expect(tracker.applied(through: 3).cursor == 4)
        #expect(tracker.applied(through: 5).cursor == 5) // dropped ACK was not fabricated
        #expect(tracker.applied(through: 6).cursor == 6)
        #expect(tracker.pendingCount == 0)
    }
}
