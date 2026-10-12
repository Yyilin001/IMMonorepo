import Foundation

/// Ownership and archive usage captured from one quorum-certified application
/// state. Capacity is operational information, never a takeover capability.
package struct V2ActorPlacementInspection: Sendable {
    package let snapshot: V2ActorPlacementSnapshot
    package let archiveUsage: V2PlacementArchiveCapacity.Usage
}

package protocol V2ActorPlacementInspectableLog: V2ActorPlacementLog {
    func inspect(deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementInspection
}
