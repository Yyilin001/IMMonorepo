import Foundation
import IMV2ActorContracts
@testable import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Room actor pressure observations")
struct V2RoomActorMetricsTests {
    @Test("caller-only metrics do not invent a zero-valued host")
    func callerOnly() {
        let value = V2RoomRuntimeMetricsSnapshot(host: nil, commands: nil,
            cachedLocations: 3, pendingResolutions: 1, activeResolutions: 1, resolutionWaiters: 2)
        let text = v2RoomActorMetricLines(value).joined(separator: "\n")
        #expect(text.contains("im_v2_room_actor_cached_locations 3"))
        #expect(text.contains("im_v2_room_actor_resolution_waiters 2"))
        #expect(!text.contains("active_rooms"))
        #expect(!text.contains("outstanding_commands"))
    }

    @Test("scraping after release preserves the process peak without retaining room identity")
    func releasedPermits() async throws {
        let budget = V2RoomCommandBudget(configuration: try .init())
        let permit = try await budget.acquire(roomID: RoomID("private-room"),
            encodedRequest: Data(repeating: 1, count: 32))
        #expect(await budget.release(permit))
        let state = await budget.snapshot()
        let value = V2RoomRuntimeMetricsSnapshot(host: .init(accepting: true,
            activeRooms: 2, pendingRooms: 3, activationWaiters: 4, restoringRooms: 1, retiringRooms: 1),
            commands: state, cachedLocations: 2, pendingResolutions: 0, activeResolutions: 0, resolutionWaiters: 0)
        let text = v2RoomActorMetricLines(value).joined(separator: "\n")
        #expect(text.contains("im_v2_room_actor_outstanding_commands 0"))
        #expect(text.contains("im_v2_room_actor_peak_outstanding_commands 1"))
        #expect(text.contains("im_v2_room_actor_peak_outstanding_bytes 32"))
        #expect(text.contains("im_v2_room_actor_active_rooms 2"))
        #expect(!text.contains("private-room"))
        #expect(!text.contains("{"))
        #expect(await budget.snapshot() == state)
    }
}
