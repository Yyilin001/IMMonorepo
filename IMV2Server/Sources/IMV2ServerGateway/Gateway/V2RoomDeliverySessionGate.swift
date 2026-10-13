import Synchronization
import IMV2ActorContracts

/// Bound to the native peer lifecycle, shared by room and socket projections.
/// Retirement is irreversible; reopening requires a successor generation.
public final class V2RoomDeliverySessionGate: Sendable {
    public let session: V2RoomDeliverySession
    public let serviceID: String
    private let retired = Mutex(false)
    public init(session: V2RoomDeliverySession, serviceID: String) {
        self.session = session; self.serviceID = serviceID
    }
    public func isReady() -> Bool { retired.withLock { !$0 } }
    public func retire() { retired.withLock { $0 = true } }
}
