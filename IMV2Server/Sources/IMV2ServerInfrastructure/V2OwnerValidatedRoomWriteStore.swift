import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 单条房间写入请求及其专属房间归属。
///
/// 归属只属于这一条不可变命令；即使多个逻辑分片共用同一物理事务，也不共用归属。
public struct V2OwnerValidatedRoomWriteRequest: Sendable {
    /// 需要写入的房间请求。
    public let request: V2RoomWriteRequest
    /// 该请求所属房间的已选定归属。
    public let ownerRoute: V2RoomShardRoute

    /// 组合单条写入请求与其房间归属。
    ///
    /// - Parameters:
    ///   - request: 需要写入的房间请求。
    ///   - ownerRoute: 该请求所属房间的已选定归属。
    public init(request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute) {
        self.request = request
        self.ownerRoute = ownerRoute
    }
}

/// 生产路由必须实现的归属校验写入能力。
///
/// 这里刻意不提供默认实现：任何默认实现都可能悄悄丢弃调用方选定的路由代次。
public protocol V2OwnerValidatedRoomWriteStore: V2AtomicRoomWriteBatchStore {
    /// 按房间归属接受一条写入。
    ///
    /// - Parameters:
    ///   - request: 目标房间的写入请求。
    ///   - ownerRoute: 已选定的房间归属。
    /// - Returns: 发送结果。
    /// - Throws: 归属已变更、准入失败或持久化失败时抛出。
    func acceptOwnerValidated(
        request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute
    ) async throws -> V2SendMessageOutcome

    /// 在单个事务内按各自归属批量接受多条写入。
    ///
    /// - Parameter requests: 逐条携带归属的写入批次。
    /// - Returns: 与输入顺序对应的发送结果。
    /// - Throws: 任一条目的归属校验失败、准入失败或持久化失败时抛出；整批同时失败。
    func acceptAtomicallyOwnerValidated(
        requests: [V2OwnerValidatedRoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]
}
