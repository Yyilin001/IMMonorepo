import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime

/// 面向网关的现有房间能力组合。所有成员共用同一目录和有限的调用预算；
/// 创建操作交由独立的控制域协调者处理，因为此时房间尚不存在。
public struct V2GatewayRoomActorServices: Sendable {
    let messaging: V2RoomRefMessagingClient
    public let administration: V2RoomRefAdministrationClient
    let queries: V2RoomRefQueryClient
    let receipts: V2RoomRefReadReceiptClient
    let eventLog: V2RoomRefGroupEventLogClient

    public init(directory: V2RoomDirectory, callTimeout: V2ActorMilliseconds,
                readReceiptControlStore: any V2ReadReceiptControlStore,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                directRoomLogEventCache: V2DirectRoomLogEventCache? = nil,
                maximumConcurrentRecoveryRooms: Int = 8,
                now: @escaping @Sendable () -> Date = Date.init) {
        messaging = .init(directory: directory, callTimeout: callTimeout)
        administration = .init(directory: directory, callTimeout: callTimeout.duration)
        let queries = V2RoomRefQueryClient(directory: directory,
            callTimeout: callTimeout.duration,
            maximumConcurrentRooms: maximumConcurrentRecoveryRooms)
        self.queries = queries
        receipts = .init(rooms: queries, control: readReceiptControlStore,
            databaseWorkAdmission: databaseWorkAdmission, now: now)
        eventLog = .init(rooms: queries, directRoomLogEventCache: directRoomLogEventCache)
    }
}
