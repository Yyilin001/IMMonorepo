import IMV2Core
import IMV2ActorContracts

struct V2GatewayJournalReadyAuthorization: Sendable {
    let highWatermark: UInt64
    let permit: @Sendable (@Sendable () -> Void) -> Bool
}

/// Primary authentication-source control state; its version is independent of
/// the user's durable sync cursor and must never be substituted for a sync H.
public struct V2GatewayJournalUserBaselineProof: Sendable {
    public let source: V2RealtimeJournalSource
    public let fence: V2RealtimeJournalProjectionFence
    public let userID: UserID
    public let controlVersion: UInt64
    public init(source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
                userID: UserID, controlVersion: UInt64) {
        self.source = source; self.fence = fence; self.userID = userID; self.controlVersion = controlVersion
    }
}
