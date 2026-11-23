import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure

extension GatewayBackgroundWorkers {
    func startRealtimeWorkers(on workers: GatewayWorkerSupervisor) {
        let configuration = self.configuration
        let directRoomLogEventCache = self.directRoomLogEventCache
        let syncWakeCoalescer = self.syncWakeCoalescer

        if let forwardRuntime = durable?.delivery.forwardRuntime { _ = workers.start { await forwardRuntime.run() } }

        _ = workers.start {
            if let directRoomLogEventCache {
                await directRoomLogEventCache.run()
            }
        }
        _ = workers.start {
            if configuration.syncWakeCoalescingEnabled {
                await syncWakeCoalescer.run()
            }
        }
    }
}
