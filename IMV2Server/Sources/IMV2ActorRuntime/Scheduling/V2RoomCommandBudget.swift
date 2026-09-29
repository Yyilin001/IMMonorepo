import Foundation
import IMV2ActorContracts
import IMV2Core

/// 许可在排队、执行或等待对账期间持续占用容量。
/// 只有签发该许可的预算才能归还容量。
public struct V2RoomCommandPermit: Equatable, Sendable {
    public let roomID: RoomID
    /// 分发使用这些精确的不可变字节，不接受调用方另行提供且自行报告大小的载荷。
    /// Data 副本共享不可变存储。
    public let encodedRequest: Data
    public var byteCount: Int { encodedRequest.count }
    public let isReservation: Bool
    fileprivate let budgetID: UUID
    fileprivate let permitID: UUID
}



/// 房间和宿主准入不等待，避免过载产生另一条无界队列。
/// 激活实例持有每份许可，直至持久化结果完成。
public actor V2RoomCommandBudget {
    private let identity = UUID()
    private let configuration: V2RoomRuntimeConfiguration
    private var permits: [UUID: V2RoomCommandPermit] = [:]
    private var rooms: [RoomID: RoomUsage] = [:]
    private var totalBytes = 0
    private var reservationCount = 0
    private var peakCommandCount = 0
    private var peakByteCount = 0

    public init(configuration: V2RoomRuntimeConfiguration) {
        self.configuration = configuration
    }

    public func acquire(roomID: RoomID, encodedRequest: Data) throws -> V2RoomCommandPermit {
        try acquire(roomID: roomID, encodedRequest: encodedRequest, isReservation: false)
    }

    /// 预留屏障共用普通请求的数量与字节上限，
    /// 并有独立的宿主级并发上限；没有额外的无界等待队列。
    func acquireReservation(roomID: RoomID, encodedRequest: Data) throws -> V2RoomCommandPermit {
        try acquire(roomID: roomID, encodedRequest: encodedRequest, isReservation: true)
    }

    private func acquire(roomID: RoomID, encodedRequest: Data, isReservation: Bool) throws -> V2RoomCommandPermit {
        let byteCount = encodedRequest.count
        guard byteCount > 0, byteCount <= configuration.maximumRequestBytes else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let usage = rooms[roomID] ?? RoomUsage()
        guard (!isReservation || reservationCount < configuration.maximumConcurrentReservations),
              permits.count < configuration.maximumQueuedCommandsPerHost,
              usage.commandCount < configuration.maximumQueuedCommandsPerRoom,
              byteCount <= configuration.maximumQueuedBytesPerHost - totalBytes,
              byteCount <= configuration.maximumQueuedBytesPerRoom - usage.byteCount
        else { throw V2RoomCallFailure.notAccepted(.overloaded) }

        let permit = V2RoomCommandPermit(
            roomID: roomID, encodedRequest: encodedRequest, isReservation: isReservation,
            budgetID: identity, permitID: UUID()
        )
        permits[permit.permitID] = permit
        rooms[roomID] = RoomUsage(
            commandCount: usage.commandCount + 1, byteCount: usage.byteCount + byteCount
        )
        totalBytes += byteCount
        peakCommandCount = max(peakCommandCount, permits.count)
        peakByteCount = max(peakByteCount, totalBytes)
        if isReservation { reservationCount += 1 }
        return permit
    }

    /// 取消和完成可以安全地竞速。迟到的重复通知或其他宿主预算的许可
    /// 不能再次扣减容量。
    @discardableResult
    public func release(_ permit: V2RoomCommandPermit) -> Bool {
        guard permit.budgetID == identity,
              permits[permit.permitID] == permit,
              let usage = rooms[permit.roomID] else { return false }
        permits.removeValue(forKey: permit.permitID)
        totalBytes -= permit.byteCount
        if permit.isReservation { reservationCount -= 1 }
        if usage.commandCount == 1 {
            rooms.removeValue(forKey: permit.roomID)
        } else {
            rooms[permit.roomID] = RoomUsage(
                commandCount: usage.commandCount - 1,
                byteCount: usage.byteCount - permit.byteCount
            )
        }
        return true
    }

    public func snapshot() -> V2RoomCommandBudgetSnapshot {
        V2RoomCommandBudgetSnapshot(
            commandCount: permits.count, byteCount: totalBytes, roomCount: rooms.count,
            reservationCount: reservationCount,
            peakCommandCount: peakCommandCount, peakByteCount: peakByteCount
        )
    }

    private struct RoomUsage: Sendable {
        var commandCount = 0
        var byteCount = 0
    }
}
