@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Testing

struct V2InitializationPoolMetricsTests {
    @Test("initialization pool pressure distinguishes timeout from queue full using fixed labels")
    func poolRejectionReasons() {
        let snapshot = V2RuntimePressureMetricsSnapshot(
            databaseWork: .init(foregroundWrite: .empty, interactiveRead: .empty, sync: .empty),
            databasePools: .init(pools: [.init(poolClass: .initialization, eventLoopHandles: 1, connectionCeiling: 4)]),
            syncWake: .init(pendingUsers: 0, inFlightUsers: 0, coalescedNotifications: 0,
                deliveredNotifications: 0, droppedNotifications: 0),
            databaseLoans: .init(pools: [.init(poolClass: .initialization,
                ordinary: .init(inFlight: 4, queued: 3, rejected: 7, rejections: [.timedOut: 5, .queueFull: 2]),
                activation: .init(), sync: .init(), renewal: .init())]))
        let text = v2RenderPrometheusRuntimePressureMetrics(snapshot)
        #expect(text.contains("im_v2_database_pool_loan_queued{pool=\"initialization\",class=\"ordinary\"} 3"))
        #expect(text.contains("im_v2_database_pool_loan_rejected_total{pool=\"initialization\",class=\"ordinary\",reason=\"timeout\"} 5"))
        #expect(text.contains("im_v2_database_pool_loan_rejected_total{pool=\"initialization\",class=\"ordinary\",reason=\"queue_full\"} 2"))
        #expect(text.contains("im_v2_database_pool_loan_rejected_total{pool=\"initialization\",class=\"ordinary\",reason=\"cancelled\"} 0"))
    }
}
