import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime

/// One gateway-facing composition for all existing-room capabilities. Every
/// member uses the same directory and finite call budget; creation is a
/// separate control-domain coordinator because the room does not exist yet.
public struct V2GatewayRoomActorServices: Sendable {
    let messaging: V2RoomRefMessagingClient
    let administration: V2RoomRefAdministrationClient
    let queries: V2RoomRefQueryClient
    let receipts: V2RoomRefReadReceiptClient
    let eventLog: V2RoomRefGroupEventLogClient

    public init(directory: V2RoomDirectory, callTimeout: V2ActorMilliseconds,
                readReceiptControlStore: any V2ReadReceiptControlStore,
                directRoomLogEventCache: V2DirectRoomLogEventCache? = nil,
                maximumConcurrentRecoveryRooms: Int = 8,
                now: @escaping @Sendable () -> Date = Date.init) {
        messaging = .init(directory: directory, callTimeout: callTimeout)
        administration = .init(directory: directory, callTimeout: callTimeout.duration)
        let queries = V2RoomRefQueryClient(directory: directory,
            callTimeout: callTimeout.duration,
            maximumConcurrentRooms: maximumConcurrentRecoveryRooms)
        self.queries = queries
        receipts = .init(rooms: queries, control: readReceiptControlStore, now: now)
        eventLog = .init(rooms: queries, directRoomLogEventCache: directRoomLogEventCache)
    }
}

extension V2RoomRefReadReceiptClient {
    // The physical host owns receipt write admission and its SQL batcher.
    var managesForegroundWriteAdmission: Bool { true }
}
