import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

enum V2AccountRoomNotification: Equatable, Sendable {
    case changed(epoch: UUID, sequence: UInt64, roomID: RoomID, highWatermark: UInt64)
    case resyncRequired(epoch: UUID)

    func envelope() -> IMV2Envelope {
        var envelope = IMV2Envelope()
        switch self {
        case .changed(let epoch, let sequence, let roomID, let watermark):
            envelope.accountRoomChanged.connectionEpoch = epoch.uuidString.lowercased()
            envelope.accountRoomChanged.notificationSequence = sequence
            envelope.accountRoomChanged.roomID = roomID.rawValue
            envelope.accountRoomChanged.highWatermark = watermark
        case .resyncRequired(let epoch):
            envelope.accountRoomResyncRequired.connectionEpoch = epoch.uuidString.lowercased()
        }
        return envelope
    }
}

/// 连接持有的队列，不包含成员关系或授权缓存。
/// 调用方须为提交内容授权；提取出的帧无法投递时须停止连接。
/// 提取操作将帧的所有权转移给写者。
struct V2AccountRoomChangeBuffer: Sendable {
    let epoch: UUID
    private let maximumPendingRooms: Int
    private var pending: [RoomID: UInt64] = [:]
    private var order: [RoomID] = []
    private var offset = 0
    private var sequence: UInt64 = 0
    private var phase: Phase = .accepting

    private enum Phase: Sendable { case accepting, resyncPending, invalidated }

    init(epoch: UUID, maximumPendingRooms: Int = 4096) throws {
        guard maximumPendingRooms > 0 else { throw V2RoomRecoveryReadError.invalidRequest }
        self.epoch = epoch
        self.maximumPendingRooms = maximumPendingRooms
    }

    var pendingRoomCount: Int { pending.count }
    var hasOutput: Bool { phase == .resyncPending || !pending.isEmpty }
    var requiresRestart: Bool { phase != .accepting }

    /// 上限约束未发送的变更数量，不约束已加入的房间数量。
    mutating func offer(roomID: RoomID, highWatermark: UInt64) throws {
        guard roomID.uuidValue != nil, highWatermark <= UInt64(Int64.max) else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        guard phase == .accepting else { return }
        if let previous = pending[roomID] {
            pending[roomID] = max(previous, highWatermark)
            return
        }
        guard pending.count < maximumPendingRooms else {
            invalidate()
            return
        }
        pending[roomID] = highWatermark
        order.append(roomID)
    }

    /// 移除未发送的元数据，不分配线路序号。
    /// 同时移除其 FIFO 槽位，使之后重新加入的房间排在已待处理房间之后。
    mutating func revoke(roomID: RoomID) {
        guard pending.removeValue(forKey: roomID) != nil else { return }
        order = order.dropFirst(offset).filter { $0 != roomID }
        offset = 0
    }

    /// 消息代理缺口、授权结果不明和溢出共用明确的恢复边界。
    /// 此纪元不再发送变更帧。
    mutating func invalidate() {
        guard phase == .accepting else { return }
        phase = .resyncPending
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        offset = 0
    }

    mutating func next() -> V2AccountRoomNotification? {
        if phase == .resyncPending {
            phase = .invalidated
            return .resyncRequired(epoch: epoch)
        }
        guard phase == .accepting, offset < order.count else { return nil }
        guard sequence < UInt64.max else {
            invalidate()
            return next()
        }
        let roomID = order[offset]
        offset += 1
        let watermark = pending.removeValue(forKey: roomID)!
        // FIFO 顺序取决于首次待处理变更，热房间不能不断把冷房间挤到后面。
        // 以摊还成本压缩已消费的存储。
        if offset >= order.count / 2 {
            order.removeFirst(offset)
            offset = 0
        }
        sequence += 1
        return .changed(epoch: epoch, sequence: sequence, roomID: roomID, highWatermark: watermark)
    }
}
